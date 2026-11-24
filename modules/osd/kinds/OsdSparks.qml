pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/particles"

// =============================================================================
// OsdSparks.qml -- the calm sparks a ball (or the head of a fill) sheds while a
// level moves: volume, mic and brightness, on the card and on the pill.
//
// The keyboard light's rail (PhaseRail) throws sparks at 0.1 px/ms with trails of
// eight points; these are not as speedy and stretched. THESE ARE THE SILICON BAR BUTTON'S CHARGE BURST
// (a very subtle count, size and shape): a few round dots of 1.5-2.4 px that keep their size and fade, never
// a trail, and at most `sparkPool` alive at once. Each is thrown in a direction of its own, within a cone
// (`sparkSpreadDeg`) round "straight back along the head's way", fast enough to read as flying off, not as a
// dotted line left behind by the ball. Every number is OsdStyle's (`spark*`), tuned on the
// mockup's Sparks group.
//
// WHY NOT THE GrooveSlider's OWN. Its slide sparks need the ball to cross 0.7 px
// per ms, which a drag does and a key step never does (a 2 % step is ~4 px over
// 120 ms: 0.03 px/ms), so a key moved the ball in silence. This one takes the
// DISTANCE the head travelled since its last call, so a step of any size sheds
// a few. OsdLevel hands the slider's own sparks the drag (`eased.direct`) and
// this the rest, so nothing sheds twice.
//
// A host calls `shed(x, y, dx, dy)` from the change of the displayed value, with
// the head's place in THIS item's frame and the way it went since the last call;
// the sparks leave backwards, scattered. The system is as big as the card and
// fades over its last `edgeFade` px, because the engine clips the content to the
// card's outline and a spark cut in half is the first thing a clip shows.
// The system has no particle alive at rest (`hasParticles` is false): nothing asks for a frame.
// =============================================================================
Item {
    id: root

    // OsdStyle (the `spark*` numbers); the host hands it over, as every kind's
    property var style: null
    property color color: Theme.accent
    // Where a spark must be gone: the card's own edges.
    property real edgeFade: 14

    // `dx`, `dy`: how far the head went since the last call, in px of this frame.
    // What the head's travel has earned but not yet shed (a fraction of a spark carries to the next change).
    readonly property var _carry: ({ v: 0 })
    function shed(x, y, dx, dy) {
        const dist = Math.sqrt(dx * dx + dy * dy);
        if (dist < 0.05 || !root.style)
            return;
        const st = root.style;
        root._carry.v += dist * st.sparkPerPx;
        let n = Math.min(st.sparkMaxPerStep, Math.floor(root._carry.v));
        root._carry.v -= Math.floor(root._carry.v);
        // a movement out of stillness always sheds its first spark (a tap of a few px has earned a fraction of one), the rest are budgeted
        if (n < 1 && !ps.hasParticles)
            n = 1;
        if (n < 1)
            return;
        // straight back along the head's way; each spark leaves at a random angle within the cone either side of it
        const back = Math.atan2(-dy, -dx);
        const spread = st.sparkSpreadDeg * Math.PI / 180;
        const cs = root.color.toString();
        for (let i = 0; i < n; i++) {
            const ang = back + (Math.random() * 2 - 1) * spread;
            const speed = st.sparkSpeed * (0.5 + Math.random());
            const size = st.sparkSizeMin + Math.random() * (st.sparkSizeMax - st.sparkSizeMin);
            ps.emit({
                x: x,
                y: y,
                vx: Math.cos(ang) * speed,
                vy: Math.sin(ang) * speed,
                lifetime: st.sparkLifeMs + Math.random() * st.sparkLifeMs,
                maxHistory: st.sparkTrail,
                sizeStart: size,
                sizeEnd: size,
                colorStart: cs,
                colorEnd: "transparent",
                drag: st.sparkDrag
            }, 1);
        }
    }

    ParticleSystem {
        id: ps
        anchors.fill: parent
        maxParticles: root.style ? root.style.sparkPool : 14
        fadeLeft: root.edgeFade
        fadeRight: root.edgeFade
        fadeTop: root.edgeFade
        fadeBottom: root.edgeFade
    }
}
