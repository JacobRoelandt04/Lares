pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "data/AudioModel.js" as Model

// =============================================================================
// AudioPatchBay.qml -- the lines of the Playback and Recording tabs, laid over the two boxes: a line from each stream to the device it REALLY goes to (the link graph, not
// what was asked for: the line is the read-back you can see). It starts ON the row, at the row's end, and ends ON the socket: nothing hides it.
//
// THE LINE (feature a) is three stacked sines, broad and faint, mid, thin and clear, laid across an S curve instead of a
// straight run, because here a line has to climb from a row to a socket. It dies at both ends so it always lands.
//
// THE LINE IS A DELAY LINE, AND THE SOUND RUNS DOWN IT FROM WHERE IT COMES FROM. Each line keeps the level as it came in, one sample a beat, and the level at a point of
// the line is the level that came in as long ago as the sound takes to get there (`lineSpeed`), so the waves, their depth and their colour all travel away from the source at
// one speed: from the row to the device on Playback, from the device to the row on Recording. A stream that stops leaves the last of its sound running down the line and the
// calm follows it: when the last of it lands the line is a flat, thin, quiet S, the state that says no audio is coming, and the sound's return is the same thing played
// forward. There is no switch between two looks, and nothing is frozen. Silence paints nothing. A wave lies along the line's normal, measured by its arc, so it keeps its
// shape on a steep climb.
//
// THE MARKER TRAVELS (feature c). A line's far end is a ball, and when a stream moves the ball goes down the sockets and the line follows it, on one clock (`_t`), read against
// the sockets as they stand. Several streams on one device fan out on its socket, so each can be taken. A ball is a handle: dragged onto a socket it asks for a move, clicked
// it offers the devices. Whether the stream moved is the service's read-back; the ball goes where the graph says.
//
// `section` "playback" | "recording". `list` is the AudioList, `sockets` the AudioSockets; this item covers both.
// =============================================================================
Item {
    id: bay

    property string section: "playback"
    property var list: null
    property var sockets: null
    property real socketsX: 0                                            // where the sockets stand in this item's frame: the Loader's place, not the item's
    property var service: null
    property AudioStyle style: AudioStyle {}
    property bool shown: false

    readonly property bool _reversed: bay.section === "recording"       // the sound comes in at the device
    readonly property bool _lines: bay.style.linesEnabled
    // A line's two ends, in this item's frame.
    readonly property real x0: bay.list && bay.sockets ? bay.list.x + bay.list.rowRight : 0
    readonly property real x1: bay.sockets ? bay.socketsX + bay.sockets.cellLeft : 0
    // How far the sound gets in a beat, and how many beats a line has to remember.
    readonly property real stepPx: bay.style.lineSpeed * bay.style.levelBeatMs / 1000
    readonly property int _histLength: Math.ceil((canvas.width + bay.height) / bay.stepPx) + 3
    // Fixed however the gap breathes: the canvas is never resized, only drawn on.
    readonly property real canvasLeft: bay.width - bay.style.socketColumn - bay.style.gapSounding - bay.style.rowGap - 1 - bay.style.portSize

    // ---- the sound ------------------------------------------------------------------------------------------------------------------------
    // True from the first level until `gapHoldMs` after the last of it has landed: this is what opens the room for the waves (AudioPopup).
    property bool sounding: false
    // Some sound is still on a line: the beat must not stop before the last of it has landed.
    property bool flowing: false
    readonly property int lineCount: endModel.count
    Timer {
        id: soundHold
        interval: bay.style.gapHoldMs
        onTriggered: bay.sounding = false
    }
    // Off the screen nothing is carried on: a tab comes back quiet, and its first level (a beat or two away) says what the room is.
    onShownChanged: {
        if (bay.shown)
            return;
        bay.sounding = false;
        bay.flowing = false;
        soundHold.stop();
        for (let i = 0; i < ends.count; i++) {
            const e = bay._end(i);
            if (e)
                e.quiet();
        }
    }

    function _end(i: int): var {
        return ends.itemAt(i);
    }

    // ---- what repaints --------------------------------------------------------------------------------------------------------------------
    function poke(): void {
        canvas.requestPaint();
    }
    Connections {
        target: bay.list
        function onGeometrySerialChanged() {
            canvas.requestPaint();
        }
    }
    // A theme switch repaints once, at the commit.
    readonly property color _a: bay.style.lineColor
    readonly property color _b: bay.style.lineIdleColor
    on_AChanged: canvas.requestPaint()
    on_BChanged: canvas.requestPaint()
    onX0Changed: canvas.requestPaint()

    ScaledCanvas {
        id: canvas
        objectName: "patchCanvas"
        x: bay.canvasLeft
        y: 0
        width: bay.x1 + bay.style.ballSize - bay.canvasLeft
        height: bay.height
        visible: bay._lines
        renderStrategy: Canvas.Immediate
        onDraw: (ctx, w, h) => bay._paint(ctx, w, h)
    }

    // The line's two looks are one: `f` 0..1 is how much sound is at this point of the line.
    function _soundOf(level: real): real {
        return Math.min(1, level * bay.style.lineColorGain);
    }
    // A line's run, kept until an end of it moves.
    function _pathOf(e: var, xa: real, y0: real, xb: real, y1: real): var {
        const p = e.path;
        if (p && p.xa === xa && p.y0 === y0 && p.xb === xb && p.y1 === y1)
            return p;
        const q = Model.linePath(xa, y0, xb, y1, bay.style.lineStep);
        q.xa = xa;
        q.y0 = y0;
        q.xb = xb;
        q.y1 = y1;
        e.path = q;
        return q;
    }

    // A probe reads it: what repainted, and when.
    property int paints: 0
    function _paint(ctx: var, w: real, h: real): void {
        bay.paints++;
        const s = bay.style;
        ctx.lineCap = "round";
        ctx.lineJoin = "round";
        const top = bay.list.y, foot = top + bay.list.height, ox = canvas.x;
        const xa = bay.x0 - ox;
        const rev = bay._reversed;
        for (let i = 0; i < ends.count; i++) {
            const e = bay._end(i);
            if (!e || !e.drawn)
                continue;
            const y0 = e.startY;
            e.paintedY = y0;
            // a row scrolled out of the box takes its line with it
            const edge = Math.min(y0 - top, foot - y0);
            const row = bay.list.rowItem(e.rowKey);
            const alpha = Math.max(0, Math.min(1, edge / 34)) * e.focusF * (row ? row.present : 0);
            if (alpha <= 0)
                continue;
            const xb = (e.dragging ? e.dragX : bay.x1) - ox, y1 = e.endY, run = xb - xa;
            let plug = 0;
            if (!e.alive) {
                // calm: one thin line in the quiet colour
                ctx.beginPath();
                ctx.lineWidth = s.lineThickC;
                ctx.globalAlpha = s.lineCalmAlpha * alpha;
                ctx.strokeStyle = s.lineIdleColor;
                ctx.moveTo(xa, y0);
                ctx.bezierCurveTo(xa + run / 2, y0, xb - run / 2, y1, xb, y1);
                ctx.stroke();
            } else {
                const p = bay._pathOf(e, xa, y0, xb, y1), n = p.n, len = p.length;
                e.lineLength = len;
                // how much sound is at each point of the line: the waves' depth and, below, the colour read the same numbers
                const lvl = [];
                for (let j = 0; j <= n; j++)
                    lvl.push(Model.levelAlong(e.hist, rev ? len - p.d[j] : p.d[j], bay.stepPx));
                plug = bay._soundOf(lvl[0]);
                ctx.globalAlpha = alpha;
                for (let l = 0; l < 3; l++) {
                    // thick and faint, mid, thin and clear; the thin one is the calm line where the sound has not reached
                    const thick = l === 0 ? s.lineThickA : l === 1 ? s.lineThickB : s.lineThickC;
                    const a1 = l === 0 ? s.lineAlphaA : l === 1 ? s.lineAlphaB : s.lineAlphaC;
                    const a0 = l === 2 ? s.lineCalmAlpha : 0;
                    const k = 1 + l * 0.4, lambda = s.lineWavelength / k, depth = s.lineAmp * (1 - l * 0.335), phase = e.phase * k + l * 2;
                    const g = ctx.createLinearGradient(xa, 0, xb, 0);
                    for (let c = 0; c <= 8; c++) {
                        const j = Math.round(c / 8 * n);
                        const f = bay._soundOf(lvl[j]);
                        const col = Mix.c(s.lineIdleColor, s.lineColor, f);
                        g.addColorStop((p.x[j] - xa) / Math.max(1, run), Qt.rgba(col.r, col.g, col.b, a0 + (a1 - a0) * f));
                    }
                    ctx.beginPath();
                    ctx.lineWidth = thick;
                    ctx.strokeStyle = g;
                    for (let j = 0; j <= n; j++) {
                        const o = Model.lineWave(depth * lvl[j], rev ? len - p.d[j] : p.d[j], lambda, phase, p.s[j]);
                        if (j === 0)
                            ctx.moveTo(p.x[j] + p.nx[j] * o, p.y[j] + p.ny[j] * o);
                        else
                            ctx.lineTo(p.x[j] + p.nx[j] * o, p.y[j] + p.ny[j] * o);
                    }
                    ctx.stroke();
                }
            }
            // the plug on the row
            ctx.globalAlpha = alpha;
            ctx.fillStyle = Mix.c(s.lineIdleColor, s.lineColor, plug);
            ctx.beginPath();
            ctx.arc(xa, y0, s.portSize / 2, 0, 2 * Math.PI);
            ctx.fill();
        }
        ctx.globalAlpha = 1;
    }

    // Several streams on one device fan out on its socket: every ball can be taken.
    readonly property var _fans: {
        void bay.service.rowsSerial;
        const out = {};
        const keys = bay.list ? bay.list.keys : [];
        for (const k of keys) {
            const r = bay.service.rowOf(k);
            if (r && r.device) {
                out[r.device] = out[r.device] || [];
                out[r.device].push(k);
            }
        }
        return out;
    }
    function _fanOffset(device: string, key: string): real {
        const a = bay._fans[device] || [];
        const n = a.length, i = a.indexOf(key);
        if (n < 2 || i < 0)
            return 0;
        const room = Math.max(bay.style.ballSize, bay.sockets.cellHeight - 2 * bay.style.ballSize);
        const spread = Math.min(bay.style.ballSize + 4, room / (n - 1));
        return (i - (n - 1) / 2) * spread;
    }

    // One per stream shown: the ball, its clock, the drag.
    ListModel {
        id: endModel
    }
    readonly property var streamKeys: bay.list ? bay.list.standingKeys.filter(k => k.indexOf("s:") === 0) : []
    onStreamKeysChanged: {
        const have = [];
        for (let i = 0; i < endModel.count; i++)
            have.push(endModel.get(i).rowKey);
        for (const op of Model.diffKeys(have, bay.streamKeys)) {
            if (op.op === "remove")
                endModel.remove(op.at);
            else if (op.op === "insert")
                endModel.insert(op.at, { rowKey: op.key });
            else
                endModel.move(op.from, op.to, 1);
        }
    }
    Repeater {
        id: ends
        model: endModel
        delegate: Item {
            id: end
            required property string rowKey
            anchors.fill: parent
            visible: bay._lines
            objectName: "end:" + end.rowKey
            // A stream that went keeps its line for as long as its row closes.
            property var _kept: null
            readonly property var stream: {
                void bay.service.rowsSerial;
                const r = bay.service.rowOf(end.rowKey);
                return r ? r : end._kept;
            }
            onStreamChanged: {
                if (end.stream)
                    end._kept = end.stream;
            }
            readonly property int socket: end.stream && bay.sockets ? bay.sockets.socketIndex(end.stream.device) : -1
            readonly property bool drawn: end.socket >= 0 || end.dragging
            readonly property real startY: {
                void bay.list.geometrySerial;
                return bay.list.y + bay.list.plugY(end.rowKey);
            }

            // The level as it came in, newest first (mutated in place: nothing binds to it). `alive`: some of it is still on the line.
            property var hist: []
            property bool alive: false
            property int silentBeats: 0            // since the last level
            property real phase: 0
            property real endF: 0                  // how much sound is at the ball
            property var path: null                // the line's run, kept until an end of it moves
            property real paintedY: 0              // where the last paint put the line's start: a probe holds it to the row
            property real lineLength: 0
            function quiet(): void {
                end.hist.length = 0;
                end.alive = false;
                end.endF = 0;
                bay.poke();
            }

            // The pointer's on a row or a socket: its lines stay, the others step back.
            readonly property bool dimmed: {
                const hk = bay.list ? bay.list.hoveredKey : "";
                const hn = bay.sockets ? bay.sockets.hoveredName : "";
                return hk.indexOf("s:") === 0 && hk !== end.rowKey || hn !== "" && !!end.stream && hn !== end.stream.device;
            }
            property real focusF: end.dimmed ? bay.style.lineDim : 1
            Behavior on focusF {
                NumberAnimation {
                    duration: 120
                    easing.type: Easing.OutCubic
                }
            }
            onFocusFChanged: bay.poke()

            // THE ONE CLOCK: the ball's place, from one object so the socket and the fan are never two generations. A socket that moves carries the ball in the same
            // frame; only a change of place flies. `_flight` is written once, so nothing ever reads a target from one write and a distance from another.
            readonly property var _place: {
                if (end.socket < 0 || !bay.sockets)
                    return null;
                const fan = bay._fanOffset(end.stream.device, end.rowKey);
                return { id: end.stream.device + "/" + fan, y: bay.sockets.socketCentre(end.socket) + fan };
            }
            property var _flight: null              // { id, y (the place), away (how far from it the flight starts) }
            property real _t: 1
            readonly property real targetY: end._flight ? end._flight.y : -1
            readonly property real endY: end.dragging ? end.dragY : end._flight ? end._flight.y + end._flight.away * (1 - end._t) : 0
            on_PlaceChanged: {
                const p = end._place, was = end._flight;
                if (p === null)
                    return;
                if (was === null)
                    end._flight = { id: p.id, y: p.y, away: 0 };
                else if (p.id === was.id)
                    end._flight = { id: p.id, y: p.y, away: was.away };
                else if (end.dragging)
                    end._flight = { id: p.id, y: p.y, away: 0 };
                else
                    end._flyFrom(end.endY);
            }
            Component.onCompleted: {
                if (end._place !== null)
                    end._flight = { id: end._place.id, y: end._place.y, away: 0 };
            }
            function _flyFrom(y: real): void {
                const p = end._place;
                if (p === null)
                    return;
                end._t = 0;
                end._flight = { id: p.id, y: p.y, away: y - p.y };
                fly.restart();
            }
            onEndYChanged: bay.poke()
            NumberAnimation {
                id: fly
                target: end
                property: "_t"
                from: 0
                to: 1
                duration: bay.style.travelMs
                easing.type: Easing.OutCubic
            }

            // ---- by hand ------------------------------------------------------------------------------------------------------
            property bool dragging: false
            property real dragX: 0
            property real dragY: 0
            property bool _moved: false
            Rectangle {
                id: ball
                objectName: "lineBall"
                visible: end.drawn
                readonly property bool lifted: grip.containsMouse || end.dragging
                width: bay.style.ballSize
                height: width
                radius: width / 2
                x: (end.dragging ? end.dragX : bay.x1) - width / 2
                y: end.endY - height / 2
                scale: ball.lifted ? 1.3 : 1
                Behavior on scale {
                    NumberAnimation {
                        duration: 120
                        easing.type: Easing.OutCubic
                    }
                }
                color: Mix.c(bay.style.lineIdleColor, bay.style.lineColor, Math.max(end.endF, ball.lifted ? 1 : 0))
            }
            MouseArea {
                id: grip
                objectName: "lineGrip"
                x: bay.x1 - 12
                y: end.endY - 9
                width: 24
                height: 18
                visible: end.drawn && !!end.stream && bay.service.canCall
                hoverEnabled: true
                cursorShape: end.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                preventStealing: true
                onPressed: mouse => {
                    fly.stop();
                    end.dragY = end.endY;
                    end.dragX = bay.x1;
                    end._moved = false;
                    end.dragging = true;
                }
                onPositionChanged: mouse => {
                    if (!end.dragging)
                        return;
                    const p = grip.mapToItem(bay, mouse.x, mouse.y);
                    end._moved = end._moved || Math.abs(p.x - bay.x1) > 4 || Math.abs(p.y - end.targetY) > 4;
                    end.dragX = Math.max(bay.x0, Math.min(bay.x1, p.x));
                    end.dragY = Math.max(0, Math.min(bay.height, p.y));
                    bay.sockets.dropName = bay._dropName(end.stream, p.x, p.y);
                }
                onReleased: mouse => {
                    const p = grip.mapToItem(bay, mouse.x, mouse.y);
                    const moved = end._moved, y = end.dragY;
                    bay.sockets.dropName = "";
                    end.dragging = false;
                    end._flyFrom(y);
                    if (!moved) {
                        const r = bay.list.rowItem(end.rowKey);
                        if (r)
                            r.openDeviceChoice(ball);
                        return;
                    }
                    bay.dropped(end.stream, p.y);
                }
                onCanceled: {
                    bay.sockets.dropName = "";
                    end.dragging = false;
                    end._flyFrom(end.dragY);
                }
            }
        }
    }
    // The device a line hanging at this point would land on: over the sockets, and not the one it is on.
    function _dropName(stream: var, x: real, y: real): string {
        if (x < bay.x1 - 40)
            return "";
        const name = bay.sockets.socketNameAt(y);
        return !!stream && name === stream.device ? "" : name;
    }
    // A line let go at height y: over a socket it is a move, anywhere else nothing was asked. Public so a probe proves the drop without a pointer.
    function dropped(stream: var, y: real): void {
        const name = bay.sockets.socketNameAt(y);
        if (name !== "" && stream)
            bay.service.moveStream(stream, name);
    }

    // The popup's one beat: what came in joins each line, and everything on it moves on.
    function beat(): bool {
        let moved = false, heard = false, onLine = false;
        const n = bay._histLength;
        const flow = 2 * Math.PI * bay.stepPx / bay.style.lineWavelength;
        for (let i = 0; i < ends.count; i++) {
            const e = bay._end(i);
            if (!e)
                continue;
            const r = bay.list.rowItem(e.rowKey);
            const lvl = r ? r.flow : 0;
            const h = e.hist;
            h.unshift(lvl);
            if (h.length > n)
                h.length = n;
            e.silentBeats = lvl > 0 ? 0 : e.silentBeats + 1;
            onLine = onLine || lvl > 0;
            // still on the line: the last of it has not landed. The line's own length says when (`stepPx` a beat).
            const some = e.silentBeats * bay.stepPx <= e.lineLength + bay.stepPx;
            const wasAlive = e.alive;
            if (lvl > 0 || (some && wasAlive)) {
                e.alive = true;
                heard = true;
                moved = true;
                onLine = true;
                e.phase = (e.phase + flow) % (2 * Math.PI * 1024);
                const f = bay._soundOf(Model.levelAlong(h, bay._reversed ? 0 : e.lineLength, bay.stepPx));
                if (f !== e.endF)
                    e.endF = f;
            } else if (wasAlive) {
                e.alive = false;
                e.endF = 0;
                moved = true;
            }
        }
        bay.flowing = onLine;
        if (heard) {
            bay.sounding = true;
            soundHold.restart();
        }
        if (moved)
            canvas.requestPaint();
        return moved;
    }
}
