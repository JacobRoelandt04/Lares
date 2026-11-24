pragma ComponentBehavior: Bound

import QtQuick

import "EdgeResize.js" as ER

// =============================================================================
// PopupEdgeResize.qml -- resize a bar popup by its free edges, like a window.
//
// Three edges are free (the two along the bar and the far one) plus the two
// far corners; the edge the popup hangs from is not. Each grip is its own
// thin MouseArea inside the popup's padding, never one area over the whole
// content: a hover area stacked over content takes the hover of the links and
// tiles under it (CLAUDE.md). Nothing is drawn -- the pointer says
// it: a resize cursor over a grip.
//
// The grabbed edge follows the pointer and the OPPOSITE edge stays put
// (Hyprland's feel), so the popup may drift off its icon:
// the result is a size and an along-bar `shift` from the icon, kept inside
// the room the host reports (GooeyEngine `hostRoom`). The pointer is read in
// SCENE coordinates -- the grabbed edge moves the grip itself -- and divided
// by the scene scale (a mockup's zoom). The new size is applied straight from
// the pointer event: the engine lays a live content out once per frame in
// that frame's polish, however many events wrote to it, so the box lands in
// the frame the pointer moved in. (Applying from a FrameAnimation would put it a
// frame behind -- animations advance after polish: the host box
// one step behind the content on some frames.)
//
// THE WALL (the engine rests a box that stops 0 < gap < snap short of a side
// bar flush against it, by MOVING it): a drag released with its DRAGGED edge
// in that zone of a wall takes the gap as a resize -- that edge eases onto the
// wall on the resize clock (snapMs, OutCubic), the held edge still, `active`
// through the ease so the host follows it frame by frame -- and the host then
// finds the box flush and moves nothing (EdgeResize.wallSnap; the walls come
// in hostRoom). A drag caught mid-snap starts from where the snap got to.
//
//   resized(w, h, shift)    live, while dragging and while a snap eases (the
//                           host follows it exactly: the content sets
//                           liveResizeActive from `active`)
//   committed(w, h, shift)  on release, BEFORE `active` drops -- persist this
//                           one; with a snap it is the size the snap ends on,
//                           so a popup closed mid-snap keeps it
//
// TWO OPTIONS (off by default; the bridge's cast takes both). `symmetric`: a
// resize grows about the centre and never moves the popup (no wall snap
// either: that is a one-sided resize). `moveWidth` > 0: the middle of the far
// edge, `moveWidth` along and `moveDepth` deep, is a MOVE grip instead (an
// open hand, a closed one while held): the popup slides along the bar keeping
// its size -- a move is deliberate, never a side effect of a resize (the
// user's review 2026-11-19: a corner drag walked the popup to the centre
// island). The far edge's resize band stays on either side of it.
// =============================================================================
Item {
    id: rz

    property var hostRoom: null
    property string edge: rz.hostRoom && rz.hostRoom.edge ? rz.hostRoom.edge : "top"
    property real curW: rz.width
    property real curH: rz.height
    property real curShift: 0
    property real minW: 300
    property real minH: 280
    property real band: 8
    property real corner: 16
    property bool symmetric: false
    property real moveWidth: 0
    property real moveDepth: 0
    readonly property bool moving: rz._grip !== null && rz._grip.move === true
    // The snap onto a wall eases on the engine's resize clock (GooeyEngine
    // resizeMs, OutCubic).
    property int snapMs: 260
    readonly property bool active: rz._grip !== null || rz._snapping

    signal resized(real w, real h, real shift)
    signal committed(real w, real h, real shift)

    property var _grip: null
    property var _start: null
    property point _s0: Qt.point(0, 0)
    property point _s: Qt.point(0, 0)
    property real _scale: 1
    property var _last: null
    // The snap: { from, to } (EdgeResize results) while it eases.
    property bool _snapping: false
    property var _snap: null

    readonly property bool _vertical: rz.edge === "left" || rz.edge === "right"

    function _cursor(name) {
        switch (name) {
        case "ver":
            return Qt.SizeVerCursor;
        case "hor":
            return Qt.SizeHorCursor;
        case "bdiag":
            return Qt.SizeBDiagCursor;
        case "fdiag":
            return Qt.SizeFDiagCursor;
        }
        return Qt.ArrowCursor;
    }

    // A grip's rect in (along, out-from-face) space, mapped to local x/y.
    function _rect(g) {
        const A = rz._vertical ? rz.height : rz.width;
        const O = rz._vertical ? rz.width : rz.height;
        const b = rz.band, c = rz.corner;
        let a0, a1, o0, o1;
        const mw = Math.min(rz.moveWidth, A - 2 * c);
        if (g.move === true) {
            a0 = (A - mw) / 2;
            a1 = a0 + mw;
            o0 = O - Math.max(b, rz.moveDepth);
            o1 = O;
        } else if (g.out === 1 && g.along === 0 && g.part !== undefined) {
            // the far edge on one side of the move grip
            a0 = g.part === "lo" ? c : (A + mw) / 2;
            a1 = g.part === "lo" ? (A - mw) / 2 : A - c;
            o0 = O - b;
            o1 = O;
        } else if (g.out === 1 && g.along !== 0) {
            a0 = g.along < 0 ? 0 : A - c;
            a1 = a0 + c;
            o0 = O - c;
            o1 = O;
        } else if (g.out === 1) {
            a0 = c;
            a1 = A - c;
            o0 = O - b;
            o1 = O;
        } else {
            a0 = g.along < 0 ? 0 : A - b;
            a1 = a0 + b;
            o0 = b;
            o1 = O - c;
        }
        const w = a1 - a0, h = o1 - o0;
        switch (rz.edge) {
        case "bottom":
            return Qt.rect(a0, rz.height - o1, w, h);
        case "left":
            return Qt.rect(o0, a0, h, w);
        case "right":
            return Qt.rect(rz.width - o1, a0, h, w);
        }
        return Qt.rect(a0, o0, w, h);
    }

    function _begin(g, area, mx, my) {
        const s = area.mapToItem(null, mx, my);
        const one = rz.mapToItem(null, 1, 0), zero = rz.mapToItem(null, 0, 0);
        rz._scale = Math.max(0.01, Math.hypot(one.x - zero.x, one.y - zero.y));
        const room = rz.hostRoom;
        const r = rz._snapping && rz._last ? rz._last.r : null;
        if (r) {
            // Caught mid-snap: from the box the snap last wrote (the room is
            // the box as last laid out, which may be a step behind it).
            rz._start = {
                along: r.along,
                out: r.out,
                a0: r.a0,
                a1: r.a1
            };
        } else {
            const along = rz._vertical ? rz.curH : rz.curW;
            const out = rz._vertical ? rz.curW : rz.curH;
            rz._start = {
                along: along,
                out: out,
                a0: room && room.a0 !== undefined ? room.a0 : -along / 2 + rz.curShift,
                a1: room && room.a1 !== undefined ? room.a1 : along / 2 + rz.curShift
            };
        }
        rz._s0 = Qt.point(s.x, s.y);
        rz._s = rz._s0;
        rz._last = null;
        rz._grip = g;
        rz._stopSnap();
    }

    // A result of EdgeResize as the popup's w, h and shift, handed on unless
    // it is the last one again.
    function _emit(r) {
        const w = Math.round(rz._vertical ? r.out : r.along);
        const h = Math.round(rz._vertical ? r.along : r.out);
        const l = rz._last;
        if (l && l.w === w && l.h === h && l.shift === r.shift)
            return;
        rz._last = {
            w: w,
            h: h,
            shift: r.shift,
            r: r
        };
        rz.resized(w, h, r.shift);
    }

    function _step() {
        if (!rz._grip)
            return;
        const dx = (rz._s.x - rz._s0.x) / rz._scale;
        const dy = (rz._s.y - rz._s0.y) / rz._scale;
        const room = rz.hostRoom || {
            center: 0
        };
        if (rz._grip.move === true) {
            rz._emit(ER.move(rz._start, rz._vertical ? dy : dx, room));
            return;
        }
        rz._emit(ER.apply(rz._grip, rz._start, dx, dy, rz.edge, room, {
            minAlong: rz._vertical ? rz.minH : rz.minW,
            minOut: rz._vertical ? rz.minW : rz.minH,
            symmetric: rz.symmetric
        }));
    }

    function _end() {
        if (!rz._grip)
            return;
        rz._step();
        const l = rz._last;
        // A drag ended by its grip going away (the view changed) does not snap.
        const to = l && rz.enabled && !rz.symmetric ? ER.wallSnap(rz._grip, rz._start, l.r, rz.hostRoom) : null;
        if (to) {
            rz.committed(Math.round(rz._vertical ? to.out : to.along), Math.round(rz._vertical ? to.along : to.out), to.shift);
            rz._snap = {
                from: l.r,
                to: to,
                center: rz.hostRoom.center
            };
            // Still active: the snap takes over from the drag.
            rz._snapping = true;
            rz._grip = null;
            snapClock.f = 0;
            snapAnim.restart();
            return;
        }
        if (l)
            rz.committed(l.w, l.h, l.shift);
        rz._grip = null;
    }

    // One frame of the snap: the dragged edge on its way to the wall, whole
    // pixels until it lands exactly on it; the held edge is the same number
    // in both ends, so it does not move.
    function _snapStep() {
        const s = rz._snap;
        if (!rz._snapping || !s)
            return;
        const f = snapClock.f;
        const a0 = f >= 1 ? s.to.a0 : Math.round(s.from.a0 + (s.to.a0 - s.from.a0) * f);
        const a1 = f >= 1 ? s.to.a1 : Math.round(s.from.a1 + (s.to.a1 - s.from.a1) * f);
        rz._emit({
            along: a1 - a0,
            out: s.to.out,
            shift: (a0 + a1) / 2 - s.center,
            a0: a0,
            a1: a1
        });
    }
    function _stopSnap() {
        snapAnim.stop();
        rz._snap = null;
        rz._snapping = false;
    }

    // Disabled under a snap (the view changed: a back began): the snap stops
    // where it is -- what it ends on is persisted already, and it must not go
    // on writing a size for a page no longer on show. (A drag under way ends
    // through its grip's onCanceled when the grips go.)
    onEnabledChanged: {
        if (!rz.enabled)
            rz._stopSnap();
    }

    QtObject {
        id: snapClock
        property real f: 0
        onFChanged: rz._snapStep()
    }
    NumberAnimation {
        id: snapAnim
        target: snapClock
        property: "f"
        from: 0
        to: 1
        duration: rz.snapMs
        easing.type: Easing.OutCubic
        onFinished: rz._stopSnap()
    }

    Repeater {
        model: !rz.enabled ? [] : (rz.moveWidth > 0 ? [
            {
                along: -1,
                out: 0
            },
            {
                along: 1,
                out: 0
            },
            {
                along: 0,
                out: 1,
                part: "lo"
            },
            {
                along: 0,
                out: 1,
                part: "hi"
            },
            {
                along: -1,
                out: 1
            },
            {
                along: 1,
                out: 1
            },
            {
                along: 0,
                out: 0,
                move: true
            }
        ] : [
            {
                along: -1,
                out: 0
            },
            {
                along: 1,
                out: 0
            },
            {
                along: 0,
                out: 1
            },
            {
                along: -1,
                out: 1
            },
            {
                along: 1,
                out: 1
            }
        ])
        delegate: MouseArea {
            id: grip
            required property var modelData
            readonly property rect r: rz.width > 0 && rz.height > 0 ? rz._rect(grip.modelData) : Qt.rect(0, 0, 0, 0)
            x: grip.r.x
            y: grip.r.y
            width: grip.r.width
            height: grip.r.height
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton
            cursorShape: grip.modelData.move === true ? (grip.pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor) : rz._cursor(ER.cursorFor(grip.modelData, rz.edge))
            preventStealing: true
            onPressed: m => rz._begin(grip.modelData, grip, m.x, m.y)
            onPositionChanged: m => {
                if (grip.pressed) {
                    const s = grip.mapToItem(null, m.x, m.y);
                    rz._s = Qt.point(s.x, s.y);
                    rz._step();
                }
            }
            onReleased: rz._end()
            onCanceled: rz._end()
        }
    }
}
