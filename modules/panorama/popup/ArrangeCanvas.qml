pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/float"
import "../data/PanoramaModel.js" as M
import "../data/PanoramaLayout.js" as L
import ".."

// =============================================================================
// ArrangeCanvas.qml -- the arrangement card (decisions 14, 15, 16, 24): a carved card with every enabled display as a to-scale tile.
//
//   a press and a release on a tile   `selectRequested(name)` (the popup opens the side popup for it)
//   a press on the card's floor        `selectRequested("")`
//   a carried tile                     lifts (carved -> raised), FOLLOWS THE HAND, translucent; the place it would take is an accent outline
//                                      drawn above every tile. The place is decided from the POINTER (PanoramaLayout.dropByPointer): the tile
//                                      under it is cut by its diagonals into four triangles -> the side the carried tile attaches to, the
//                                      pointer's place along that side (thirds) -> start / centre / end; outside every tile, the nearest one
//   the release                        the same rule at the release point (touches, overlaps nothing, keeps the layout connected), the layout
//                                      normalised so the laptop stands at 0,0, `service.stageMove` for each tile that moved, and the
//                                      tile eases to its place on ONE clock (TileCarry)
//   a mirroring display                a ghost behind the laptop's tile (not draggable), a display that is off a chip in the parked row
//   a rest on a tile                   `service.setIdentify(name)` after panorama.jsonc identifyDelayMs, cleared on leaving
//
// A GAP between the tiles is drawn only (`tileGap`): every tile's drawn rect is inset by half of it on every side, so the logical edges still
// touch and the picture stays centred and symmetric. The tiles float on ONE FloatClock (restHz 20); a carried tile calms the clock, so the others
// stop floating and come to rest while it is in the hand.
//
// The layout is fitted to the card with room round it (`slackFrac`) so a tile can be carried past its edge; the fit is HELD while one
// is carried (a layout that rescaled under the fingers would move the thing being dragged). Nothing here animates a height: the card's
// `implicitHeight` steps and the engine eases the popup.
// =============================================================================
Item {
    id: root

    property var service: null
    property PanoramaStyle style: PanoramaStyle {}
    property string fontFamily: "Inter"
    property string selected: ""
    property color ground: Theme.listBox
    property color cardSurface: Theme.surface
    property bool floatRunning: true                // the host's word that the card is on screen (not parked): the float stops with it
    readonly property alias floatClock: tilesClock

    signal selectRequested(string name)

    // ---- the facts, read once ---------------------------------------------------------------------------------------------------------------
    readonly property var _outs: root.service && root.service.displays ? root.service.displays : []
    readonly property var _specs: {
        const s = root.service;
        if (!s)
            return {};
        if (s.staged)
            return s.staged;
        return s.plan && s.plan.specs ? s.plan.specs : {};
    }

    function _mirrorNote(outs: var, specs: var, lap: var): string {
        const on = outs.filter(o => o !== lap && specs[o.name] && specs[o.name].enabled && specs[o.name].mirror).map(o => o.label);
        return on.length ? "Mirrored on " + on.join(", ") : "";
    }

    function _num(v: real): string {
        return String(Math.round(v * 1000) / 1000);
    }

    // [{ name, kind: "tile" | "ghost" | "chip", label, sizeText, rateText, scaleText, internal, note, rect: {x,y,w,h} }]
    // `note` is the laptop tile's "Mirrored on <display>": a mirror has no place of its own on the canvas, so the tile it shows says so
    readonly property var _tiles: {
        const res = [], outs = root._outs, specs = root._specs;
        const lap = outs.find(o => o.internal && specs[o.name] && specs[o.name].enabled);
        for (const o of outs) {
            const sp = specs[o.name];
            if (!sp)
                continue;
            const m = M.specMode(sp, o) || { w: o.width, h: o.height, r: o.refresh };
            const r = sp.enabled ? M.rectOf(sp, o) : { x: 0, y: 0, w: 0, h: 0 };
            const sc = M.specScale(sp, o, m);
            // while a cast is being made (the output exists, the stream is not up) the TV is still a chip, not a tile
            if (o.cast && root._castHold)
                continue;
            res.push({ name: o.name, cast: !!o.cast, kind: !sp.enabled ? "chip" : (sp.mirror && lap ? "ghost" : "tile"), label: o.label, internal: !!o.internal,
                       sizeText: m.w + " × " + m.h, rateText: "@ " + root._num(m.r) + " Hz", scaleText: "×" + root._num(sc),
                       note: o === lap ? root._mirrorNote(outs, specs, lap) : "",
                       rect: r });
        }
        return res;
    }
    readonly property var _byName: {
        const m = {};
        for (const t of root._tiles)
            m[t.name] = t;
        return m;
    }
    readonly property var _lapTile: root._tiles.find(t => t.internal && t.kind === "tile") || null
    property var _names: []
    function _syncNames(): void {
        const n = root._tiles.map(t => t.name);
        if (JSON.stringify(n) !== JSON.stringify(root._names))
            root._names = n;
    }
    on_TilesChanged: root._syncNames()
    Component.onCompleted: {
        root._syncNames();
        tilesClock.restartDeal();
    }

    readonly property var _chips: root._tiles.filter(t => t.kind === "chip")

    // ---- cast chips: a capable TV not being cast waits in the parked row (CastChip). Off (no `castEnabled`): none of this exists ----
    readonly property bool _castHold: !!root.service && (root.service.castPhase === "opening" || root.service.castPhase === "starting")
    readonly property var _castDevs: {
        const s = root.service;
        if (!s || !s.castEnabled)
            return [];
        const up = ["streaming", "restarting", "stopping"].indexOf(s.castPhase) >= 0;
        return (s.castDevices || []).filter(d => d.capable && !(up && d.id === s.castActiveDevice)).map(d => ({ id: d.id, name: d.name }));
    }
    // the chips' ids, kept by value so a chip (its confirm step) is never rebuilt by a re-read of the list
    property var _castIds: []
    function _syncCast(): void {
        const n = root._castDevs.map(d => d.id);
        if (JSON.stringify(n) !== JSON.stringify(root._castIds))
            root._castIds = n;
    }
    on_CastDevsChanged: root._syncCast()
    function _castName(id: string): string {
        const d = root._castDevs.find(x => x.id === id);
        return d ? d.name : id;
    }
    // the parked row's room: the chips of displays that are off, and the cast chips' confirm step (reserved while a TV is listed)
    readonly property real _rowH: root._castIds.length > 0 ? Math.max(root.style.parkedHeight, root.style.castRowHeight) : (root._chips.length > 0 ? root.style.parkedHeight : 0)
    function _castSlot(i: int): rect {
        return Qt.rect(root.style.canvasPad + root._chips.length * (root.style.chipWidth + root.style.chipGap) + i * (root.style.castChipWidth + root.style.chipGap),
                       root.stageHeight + Math.round((root._rowH - root.style.chipHeight) / 2), root.style.castChipWidth, root.style.chipHeight);
    }
    readonly property rect _castRow: Qt.rect(root.style.canvasPad, root.stageHeight + 8, Math.max(0, root.width - 2 * root.style.canvasPad), Math.max(0, root._rowH - 16))
    // Escape puts a chip's confirm step back
    function cancelCast(): bool {
        let any = false;
        for (let i = 0; i < castChips.count; i++) {
            const c = castChips.itemAt(i);
            if (c && c.confirming) {
                c.cancel();
                any = true;
            }
        }
        return any;
    }

    // the parked row's line fades (a presence); the card's height is the step
    property real _parkedF: root._rowH > 0 ? 1 : 0
    Behavior on _parkedF {
        NumberAnimation {
            duration: root.style.fadeMs
            easing.type: Easing.OutCubic
        }
    }

    // ONE clock for the tiles' float; calm while one is in the hand
    FloatClock {
        id: tilesClock
        running: root.floatRunning && root.visible
        restHz: root.style.floatRestHz
        calm: root._dragged
        style: root.style.floatStyle
    }
    onFloatRunningChanged: if (root.floatRunning) tilesClock.restartDeal()
    function _seedOf(name: string): int {
        let h = 7;
        for (let i = 0; i < name.length; i++)
            h = (h * 31 + name.charCodeAt(i)) % 100003;
        return 1 + h;
    }
    // THE SCALE leaves room for any two displays side by side: a tile is carried with its centre inside the card, so a scale at
    // which the two widest tiles do not fit next to each other is one at which a display cannot be placed beside another (the
    // ultrawide could not go to the laptop's right). It is the card's inner width over the two widest tiles, never above `maxScale`.
    readonly property real _scaleCap: {
        const ws = root._tiles.filter(t => t.kind === "tile").map(t => t.rect.w).sort((a, b) => b - a);
        const pair = (ws[0] || 0) + (ws[1] || 0);
        const inner = Math.max(1, root.width - 2 * root.style.canvasPad);
        return pair > 0 ? Math.min(root.style.maxScale, inner / pair) : root.style.maxScale;
    }
    // THE HEIGHT follows the shape of the LIVE arrangement at that scale (never the staged one: a drag must not resize the popup under
    // the fingers): a wide desk keeps the minimum, a stack of three gets the room to show its figures, up to the maximum. Whole pixels;
    // the engine eases the popup's resize.
    readonly property real stageHeight: {
        const s = root.service, specs = s && s.plan && s.plan.specs ? s.plan.specs : {};
        const rects = [];
        for (const o of root._outs) {
            const sp = specs[o.name];
            if (sp && sp.enabled && !sp.mirror && !(o.cast && root._castHold))
                rects.push(M.rectOf(sp, o));
        }
        const lo = root.style.canvasHeight, hi = Math.max(lo, root.style.canvasMaxHeight);
        if (!rects.length || root.width <= 0)
            return lo;
        const b = L.bounds(rects), slack = Math.max(b.w, b.h) * root.style.slackFrac;
        const inner = root.width - 2 * root.style.canvasPad;
        const scale = Math.min(root._scaleCap, inner / Math.max(1, b.w + 2 * slack));
        const h = (b.h + 2 * slack) * scale + 2 * root.style.canvasPad;
        return Math.round(Math.max(lo, Math.min(hi, h)));
    }

    implicitHeight: Math.ceil(root.stageHeight + root._rowH)

    // ---- the fit -------------------------------------------------------------------------------------------------------------------------
    readonly property var _fitLive: {
        const rects = root._tiles.filter(t => t.kind === "tile").map(t => t.rect);
        const b = L.bounds(rects);
        const slack = Math.max(b.w, b.h) * root.style.slackFrac;
        const box = { x: b.x - slack, y: b.y - slack, w: b.w + 2 * slack, h: b.h + 2 * slack };
        return L.fitCanvas(rects.length ? [box] : [], root.width, root.stageHeight, root.style.canvasPad, root._scaleCap);
    }
    property var _fitHeld: null
    readonly property var fit: root._fitHeld || root._fitLive

    // a logical rect as drawn: scaled, on whole pixels, inset by half the gap on every side (the picture stays centred and symmetric)
    function _screenRect(x: real, y: real, w: real, h: real): rect {
        const f = root.fit, s = f.scale, g = root.style.tileGap / 2;
        const x0 = Math.round(x * s + f.ox), y0 = Math.round(y * s + f.oy);
        const x1 = Math.round((x + w) * s + f.ox), y1 = Math.round((y + h) * s + f.oy);
        const gx = x1 - x0 > 4 * g ? g : 0, gy = y1 - y0 > 4 * g ? g : 0;
        return Qt.rect(x0 + gx, y0 + gy, x1 - x0 - 2 * gx, y1 - y0 - 2 * gy);
    }

    // an outline that would leave the card is drawn as the part inside it, 3 px in so its line shows (the layout re-fits after the drop)
    function _inField(r: rect): rect {
        const m = 3, x0 = Math.max(r.x, m), y0 = Math.max(r.y, m);
        return Qt.rect(x0, y0, Math.max(0, Math.min(r.x + r.width, root.width - m) - x0), Math.max(0, Math.min(r.y + r.height, root.stageHeight - m) - y0));
    }

    function _restOf(t: var): rect {
        if (t.kind === "chip") {
            const i = root._chips.findIndex(c => c.name === t.name);
            return Qt.rect(root.style.canvasPad + i * (root.style.chipWidth + root.style.chipGap),
                           root.stageHeight + Math.round((root._rowH - root.style.chipHeight) / 2), root.style.chipWidth, root.style.chipHeight);
        }
        let r = t.rect, off = 0;
        if (t.kind === "ghost" && root._lapTile) {
            r = root._lapTile.rect;
            off = root.style.ghostOffset;
        }
        const sr = root._screenRect(r.x, r.y, r.w, r.h);
        return Qt.rect(sr.x + off, sr.y + off, sr.width, sr.height);
    }
    // where the facts put a display's tile (the popup anchors the side popup on it, never on the drawn, swaying card)
    function restRect(name: string): rect {
        const t = root._byName[name];
        return t ? root._restOf(t) : Qt.rect(0, 0, 0, 0);
    }

    // ---- the card ------------------------------------------------------------------------------------------------------------------------
    ShadowBox {
        anchors.fill: parent
        baseRadius: root.style.cardRadius
        bevelWidth: 1
        shadowWidth: 3
        surfaceColor: root.cardSurface
        backgroundColor: root.ground
        bevelColor: Theme.bevel
        shadowColor: Theme.border
    }

    MouseArea {
        anchors.fill: parent
        onPressed: root.selectRequested("")
    }

    // the line between the canvas and the parked row
    Rectangle {
        x: root.style.canvasPad
        y: root.stageHeight
        width: root.width - 2 * root.style.canvasPad
        height: 1
        color: Theme.border
        opacity: root._parkedF
    }

    property real _dragF: root._drag !== "" && root._dragged ? 1 : 0
    Behavior on _dragF {
        NumberAnimation {
            duration: root.style.fadeMs
            easing.type: Easing.OutCubic
        }
    }

    // The tiles and the outline stand in a field cut to the card: a tile carried past the card's edge (or an outline that would reach past it) is
    // cut there, never drawn over the popup's padding. The card's own bevel is a sibling outside this clip.
    Item {
        id: field
        anchors.fill: parent
        clip: true

        // where a carried tile would land: ABOVE every tile (the carried one included), so it is seen under the hand
        Rectangle {
            id: preview
            objectName: "dropOutline"
            property rect at: Qt.rect(0, 0, 0, 0)
            x: preview.at.x
            y: preview.at.y
            width: preview.at.width
            height: preview.at.height
            z: 10
            radius: root.style.tileRadius
            color: "transparent"
            border.width: root.style.outlineWidth
            border.color: Theme.accent
            opacity: root.style.outlineOpacity * root._dragF
            visible: root._dragF > 0.01
        }

        Repeater {
            id: tiles
            model: root._names
            delegate: DisplayTile {
                id: dt
                required property string modelData
                required property int index
                readonly property var t: root._byName[dt.modelData]
                readonly property rect rest: dt.t ? root._restOf(dt.t) : Qt.rect(0, 0, 0, 0)
                name: dt.modelData
                label: dt.t ? dt.t.label : ""
                sizeText: dt.t ? dt.t.sizeText : ""
                rateText: dt.t ? dt.t.rateText : ""
                scaleText: dt.t ? dt.t.scaleText : ""
                internal: dt.t ? dt.t.internal : false
                cast: dt.t ? dt.t.cast : false
                note: dt.t ? dt.t.note : ""
                ghost: dt.t ? dt.t.kind === "ghost" : false
                chip: dt.t ? dt.t.kind === "chip" : false
                selected: root.selected === dt.modelData
                lifted: root._drag === dt.modelData && root._dragged
                clock: tilesClock
                order: dt.index
                seed: root._seedOf(dt.modelData)
                ground: root.ground
                fontFamily: root.fontFamily
                style: root.style
                z: dt.lifted ? 3 : (dt.ghost ? 0 : (dt.internal ? 1.5 : 1))
                visible: dt.t !== undefined && dt.t !== null && (dt.rest.width > 0)

                Component.onCompleted: dt.carry.place(dt.rest.x, dt.rest.y, dt.rest.width, dt.rest.height)
                onRestChanged: {
                    if (root._drag === dt.modelData && root._dragged)
                        return;
                    dt.carry.moveTo(dt.rest.x, dt.rest.y, dt.rest.width, dt.rest.height, root.style.dropEaseMs);
                }
                onPressedAt: (cx, cy) => root._pressed(dt.modelData, cx, cy)
                onMovedTo: (cx, cy) => root._moved(dt.modelData, cx, cy)
                onReleasedAt: (cx, cy) => root._released(dt.modelData, cx, cy)
                onHoveredChanged: root._hoverChanged(dt.modelData, dt.hovered)
            }
        }

        // the TVs the scan found (CastChip): above the tiles, in the parked row
        Repeater {
            id: castChips
            model: root._castIds
            delegate: CastChip {
                id: cc
                required property string modelData
                required property int index
                z: cc.confirming ? 5 : 2
                service: root.service
                style: root.style
                fontFamily: root.fontFamily
                ground: root.ground
                deviceId: cc.modelData
                deviceName: root._castName(cc.modelData)
                slot: root._castSlot(cc.index)
                row: root._castRow
            }
        }
    }

    function tileItem(name: string): var {
        for (let i = 0; i < tiles.count; i++) {
            const it = tiles.itemAt(i);
            if (it && it.name === name)
                return it;
        }
        return null;
    }

    // ---- identify --------------------------------------------------------------------------------------------------------------------------
    property string _hoverName: ""
    function _hoverChanged(name: string, on: bool): void {
        if (on) {
            root._hoverName = name;
            identifyTimer.restart();
        } else if (root._hoverName === name) {
            root._hoverName = "";
            identifyTimer.stop();
            if (root.service && root.service.identify === name)
                root.service.setIdentify("");
        }
    }
    Timer {
        id: identifyTimer
        // panorama.jsonc identifyDelayMs (the service's settings; 250 for a host with none)
        interval: root.service && root.service.settings ? root.service.settings.identifyDelayMs : 250
        onTriggered: if (root.service && root.service.identify !== root._hoverName) root.service.setIdentify(root._hoverName)
    }
    Component.onDestruction: if (root.service && root.service.identify !== "") root.service.setIdentify("")

    // ---- the drag --------------------------------------------------------------------------------------------------------------------------
    property string _drag: ""                      // the tile under the pointer's press ("" none)
    property bool _dragged: false                  // ... and it has travelled past the slop
    property real _px: 0
    property real _py: 0
    property real _gx: 0                           // the pointer's place inside the tile at the press
    property real _gy: 0
    property var _originLogical: null              // where the tile stood, logical px
    property var _dropAt: null                     // the place the pointer has picked (dropByPointer's answer), logical px

    function _logicalOf(cx: real, cy: real): point {
        const f = root.fit;
        return Qt.point((cx - f.ox) / f.scale, (cy - f.oy) / f.scale);
    }

    function _others(name: string): var {
        return root._tiles.filter(t => t.kind === "tile" && t.name !== name).map(t => ({ name: t.name, x: t.rect.x, y: t.rect.y, w: t.rect.w, h: t.rect.h }));
    }

    // the place the pointer at (cx, cy) picks for the tile `name` (the pointer is held inside the stage: the card keeps the tile in sight)
    function _pick(name: string, cx: real, cy: real): var {
        const t = root._byName[name];
        const px = Math.max(0, Math.min(root.width, cx)), py = Math.max(0, Math.min(root.stageHeight, cy));
        const p = root._logicalOf(px, py);
        return L.dropByPointer({ name: name, w: t.rect.w, h: t.rect.h }, root._others(name), p.x, p.y, root._originLogical);
    }

    function _pressed(name: string, cx: real, cy: real): void {
        const it = root.tileItem(name), t = root._byName[name];
        root._drag = name;
        root._dragged = false;
        root._px = cx;
        root._py = cy;
        if (!it || !t)
            return;
        root._gx = cx - it.carry.cx;
        root._gy = cy - it.carry.cy;
    }

    function _moved(name: string, cx: real, cy: real): void {
        const t = root._byName[name], it = root.tileItem(name);
        if (root._drag !== name || !t || !it || t.kind !== "tile")
            return;
        if (!root._dragged) {
            if (Math.hypot(cx - root._px, cy - root._py) < root.style.dragSlop)
                return;
            root._dragged = true;
            root._fitHeld = root._fitLive;
            root._originLogical = { x: t.rect.x, y: t.rect.y };
            if (root.service && root.service.identify !== "")
                root.service.setIdentify("");
            identifyTimer.stop();
        }
        // the card follows the hand 1:1 ...
        const px = Math.max(0, Math.min(root.width, cx)), py = Math.max(0, Math.min(root.stageHeight, cy));
        // (kept inside the card: the tile is never carried past its edge)
        it.carry.follow(Math.max(0, Math.min(root.width - it.carry.tw, px - root._gx)), Math.max(0, Math.min(root.stageHeight - it.carry.th, py - root._gy)));
        // ... and the outline is the place the POINTER picks
        const drop = root._pick(name, cx, cy);
        root._dropAt = drop;
        preview.at = root._inField(root._screenRect(drop.x, drop.y, t.rect.w, t.rect.h));
    }

    function _released(name: string, cx: real, cy: real): void {
        const was = root._drag === name && root._dragged;
        const it = root.tileItem(name), t = root._byName[name];
        if (root._drag === name && !root._dragged) {
            root._drag = "";
            root.selectRequested(name);
            return;
        }
        if (!was || !it || !t) {
            root._drag = "";
            return;
        }
        const drop = root._pick(name, cx, cy), others = root._others(name);
        const all = others.concat([{ name: name, x: drop.x, y: drop.y, w: t.rect.w, h: t.rect.h }]);
        const lap = root._lapTile ? root._lapTile.name : "";
        const placed = L.normalise(all, lap);
        root._drag = "";
        root._dragged = false;
        root._dropAt = null;
        root._fitHeld = null;
        const svc = root.service;
        for (const p of placed) {
            const cur = root._byName[p.name];
            if (cur && (cur.rect.x !== p.x || cur.rect.y !== p.y) && svc)
                svc.stageMove(p.name, p.x, p.y);
        }
        // the tile goes to the place the facts now give it, from where it is drawn, even when the drop changed nothing
        const rt = root._restOf(root._byName[name]);
        it.carry.moveTo(rt.x, rt.y, rt.width, rt.height, root.style.dropEaseMs);
        root.selectRequested(name);
    }
}
