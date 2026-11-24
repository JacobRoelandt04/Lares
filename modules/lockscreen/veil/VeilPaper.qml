pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"

// =============================================================================
// VeilPaper.qml -- PAPER LAYERS, a lock veil (contract section 7).
//
// Four sheets of the shell's own material, cut along the soft contour lines of one
// smooth field (each at a level of its own, so the stack never crosses itself) and laid
// one over the next on a deep bed, with real drop shadows between them.
//
// THE CASCADE. The lowest sheet drifts, and every sheet above rides on the one beneath it,
// swaying against it by a little of its own: a sheet's offset is its parent's plus a sway
// that never exceeds `_sway`. Two contours of one field, `levelStep` apart, are at least
// levelStep / max|grad f| apart (_gapBound: the field's steepest slope is a property of its
// seven waves, _gradUnit), so a sheet whose offset strays from its parent's by less than
// that bound minus `sheetMargin` stays inside its parent with the margin to spare, however
// long the veil runs. Everything else that moves an edge is charged to the same budget:
// a ripple's swell is held under `swellCap` (veil_paper.vert), a fail's rattle between two
// sheets under `rattleLayer`, and a wake lowers every level alike. What is left is the sway.
// Each sheet is drawn as the shell draws a raised box: a shadow on what lies below, a
// bevel along the edges that face the light (above and to the left), the plateau between,
// deeper toward the bed.
//
//   keys      a ripple travels out of the field through the stack, the top sheet first and
//             each lower one a moment later: a sheet's face is shaded by the swell going
//             under it and its edge pushes out with it (sixteen at once; past that the
//             oldest fades out over `crowdFade` rather than being cut)
//   fail      the sheets rattle against each other and take the error tint, then settle
//   ok        the sheets peel away, the top one first (the lock holds the veil ~600 ms, so it
//             reads in the hold and the lowest sheets go on moving through the fade)
//   wake      the stack lifts and the edges swell, once
//   presence  the sheets are LAID DOWN: the peel played backwards. A front sweeps out of the
//             popup and the bar and lays the bed; then each sheet grows in turn, the lowest
//             first and the top one last, from the peaks of its contour outward
//   opaque    boot: the bed is there whole from the first frame (the screen goes from the tty's black straight to
//             the veil's floor, never a front over black), and the sheets, opaque, grow on it as above
//   the shell  only where the lock says it is: the bar and the popup's rects as the shell sends them, and nothing
//             while it has sent none (a boot lock before the shell has started, a regular lock before its popup
//             opens) -- no guessed silhouette, no shadow of one. The entrance's front then leaves the bar, or the top
//             centre. The popup's silhouette follows its live rect (it opens out of the bar and retracts into it); the
//             shadow the shell casts on the top sheet comes in on one clock as the shell ARRIVES (`_attach`, OutCubic
//             over `attachSeconds` of veil time) and goes with it at once. A shell there in the veil's first moments
//             was there from the start (no clock).
//
// A pure function of `host` (time, speed, presence, pulses, opaque, dark): no clock of its
// own, so a resting host renders nothing. One ShaderEffect, no texture to re-grab: the
// fields are evaluated at the vertices of a GridMesh (shaders/veil_paper.vert) and rebuilt
// between them per pixel (shaders/veil_paper.frag).
// =============================================================================
Item {
    id: root

    // `var`, not LockVeil: the lock loads a veil by URL, and a directory's
    // types resolve there only while some `import` names that directory
    // (LockSurface imports "../veil" for that); `var` keeps a veil loadable
    // either way.
    property var host: null

    // ---- where the shell is: the lock's rects, and only those (see "the shell" above) ----
    readonly property bool _hasStone: !!root.host && root.host.popupRect.width > 0 && root.host.popupRect.height > 0
    readonly property bool _hasBar: !!root.host && root.host.barRect.width > 0 && root.host.barRect.height > 0
    // With no popup a point at the bar's foot (inside the bar's own distance: it adds nothing), with no bar either the top
    // centre: where the entrance's front starts, never a silhouette (its radius is 0 and nothing casts a shadow then).
    readonly property rect stoneRect: root._hasStone ? root.host.popupRect
        : root._hasBar ? Qt.rect(root.host.barRect.x + root.host.barRect.width / 2, root.host.barRect.y + root.host.barRect.height, 0, 0)
        : Qt.rect(root.width / 2, 0, 0, 0)
    property real stoneRadius: 28
    readonly property rect barRect: root._hasBar ? root.host.barRect : Qt.rect(root.width / 2, 0, 0, 0)
    property real barRadius: 20
    // Veil seconds the shell's shadow takes to come in when the shell arrives.
    property real attachSeconds: 0.6

    // ---- the sheets ----
    // The field is evaluated once to every `fieldCell` DEVICE pixels, in the vertex stage.
    property real fieldCell: 16
    property real patternScale: 1.35
    property real levelBase: -0.95
    property real levelStep: 0.62
    property real sheetAlpha: 0.74
    property real sheetAlphaDark: 0.78
    property real bedAlpha: 0.62
    property real bedAlphaDark: 0.66
    property real bedTone: 0.9
    property real depthTone: 0.55
    // ---- drift: the lowest sheet's, which every sheet above rides on (THE CASCADE) ----
    property real driftSpeed: 5
    property real driftAngle: 0.35
    // How far a sheet sways against the one beneath it, px at 1620 high (held under the budget: `_sway`), and the
    // seconds of one sway.
    property real swayReach: 14
    property real swayPeriod: 70
    // The least distance between a sheet's edge and the edge of the one beneath it, px at 1620 high.
    property real sheetMargin: 12
    // ---- light ----
    property real shadowSpread: 38
    property real shadowStrength: 0.5
    property real shadowDrop: 14
    property real bevelWidth: 3
    property real bevelStrength: 0.9
    property real darkBevel: 2.2
    property real faceGain: 2.4
    property real darkFaceGain: 2.4
    property real liftGain: 1.3
    property real stoneShadow: 0.7
    // ---- pulses ----
    property real keyHeight: 8
    property real keySpeed: 520
    property real keyWidth: 70
    property real keyCycles: 1.9
    property real keyLife: 3.4
    property real layerDelay: 0.16
    property real edgeSwell: 1.3
    // The most a ripple pushes a sheet's edge out or in, px at 1620 high (THE CASCADE's budget).
    property real swellCap: 6
    property real crowdFade: 0.3
    property real rattle: 14
    // A fail's rattle of each sheet against the one beneath it, px at 1620 high, on top of the whole stack's `rattle`.
    property real rattleLayer: 4
    property real failLife: 1.8
    property real failTint: 1
    property real okSeconds: 1.2
    property real wakeSeconds: 3.5
    property real wakeLift: 0.8
    property real wakeSwell: 0.22
    // ---- the peel (an accepted password) and the entrance, which is the same motion played backwards ----
    // Sheet j (0 = lowest) starts peeling at (3 - j) * peelStagger of the way through and takes
    // peelSpan of it: the top sheet first, the lowest last; backwards, the lowest comes first.
    property real peelStagger: 0.14
    property real peelSpan: 0.5

    // ---- colours (the shell's tokens) ----
    property color surfaceColor: Theme.surface
    property color deepColor: Theme.border
    property color highlightColor: Theme.buttonBevel
    property color shadowColor: Theme.shadowDeep
    property color errorColor: Theme.errorTint

    // ---- what the host says ----
    readonly property real _t: root.host ? root.host.time : 0
    readonly property real _presence: root.host ? root.host.presence : 1
    // The lock's ease undone by the host: linear in real time, so a front moves at one speed.
    readonly property real _rise: root.host ? root.host.riseClock : 1
    readonly property bool _opaque: root.host ? root.host.opaque : false
    readonly property bool _dark: root.host ? root.host.dark : false

    // ---- the shell arriving (see "the shell" above): the shadow's share, a pure function of veil time and the last flip ----
    readonly property bool _shellThere: root._hasStone || root._hasBar
    property real _attachFrom: 1
    property real _attachTo: 1
    property real _attachAt: -1e9
    function _attachAtTime(t) {
        if (root._attachTo < 1)
            return 0;
        const x = Math.max(0, Math.min(1, (t - root._attachAt) / Math.max(0.05, root.attachSeconds)));
        return root._attachFrom + (1 - root._attachFrom) * (1 - Math.pow(1 - x, 3));
    }
    readonly property real _attach: root._shellThere ? root._attachAtTime(root._t) : 0
    // (the host's time is read itself, never through _t: a handler runs before the bindings on what changed)
    on_ShellThereChanged: {
        const t = root.host ? root.host.time : 0;
        // The lock hands the rects over a turn after the veil is built: a shell there in the first moments, before any
        // flip, was there from the start.
        if (root._shellThere && root._attachAt < -1e8 && t < 0.3) {
            root._attachFrom = 1;
            root._attachTo = 1;
            return;
        }
        root._attachFrom = root._shellThere ? 0 : 1;
        root._attachTo = root._shellThere ? 1 : 0;
        root._attachAt = t;
    }
    Component.onCompleted: {
        root._attachFrom = root._shellThere ? 1 : 0;
        root._attachTo = root._attachFrom;
    }
    readonly property real _unit: root.height / 1620
    readonly property real _scale: root.host ? Math.max(0.25, root.host.renderScale) : 1
    // A GridMesh indexes its vertices with 16 bits: a larger screen takes a coarser grid.
    readonly property real _cell: Math.max(root.fieldCell, Math.sqrt(root.width * root.height * root._scale * root._scale / 60000))
    // Sixteen ripples are drawn; the newest twelve whole, four more on their way out.
    readonly property int _slots: 16
    readonly property int _full: 12
    readonly property var _fx: root._compute(root._t, root.host ? root.host.pulses : [])

    function _smooth(a, b, x) {
        const t = Math.max(0, Math.min(1, (x - a) / (b - a)));
        return t * t * (3 - 2 * t);
    }

    // What the pulses ask of the stack right now. A key's slot is one of `_slots`; the newest
    // `_full` are whole, an older one fades over `crowdFade` from the moment the key that
    // crowded it out arrived, and only then loses its slot (never cut). Pulses whose time lies
    // ahead of the clock (a seek backwards) count for nothing.
    function _compute(t, pulses) {
        const out = { keys: [], failEnv: 0, failPhase: 0, okX: 0, wakeEnv: 0 };
        let seenFail = false, seenOk = false, seenWake = false;
        const keys = [];
        for (let i = (pulses ? pulses.length : 0) - 1; i >= 0; i--) {
            const p = pulses[i];
            const age = t - p.t;
            if (age < 0)
                continue;
            if (p.kind === "key") {
                if (age < root.keyLife)
                    keys.push(p);
            } else if (p.kind === "fail" && !seenFail && age < root.failLife) {
                seenFail = true;
                out.failEnv = Math.min(1, age / 0.08) * Math.exp(-age / 0.55) * (1 - root._smooth(0.7 * root.failLife, root.failLife, age));
                out.failPhase = 2 * Math.PI * 6 * age;
            } else if (p.kind === "ok" && !seenOk) {
                seenOk = true;
                out.okX = Math.min(1, age / Math.max(0.1, root.okSeconds));
            } else if (p.kind === "wake" && !seenWake && age < root.wakeSeconds) {
                seenWake = true;
                out.wakeEnv = 0.5 - 0.5 * Math.cos(2 * Math.PI * age / root.wakeSeconds);
            }
        }
        for (let j = 0; j < keys.length && out.keys.length < root._slots; j++) {
            const p = keys[j];
            let w = 1;
            if (j >= root._full)
                w = 1 - root._smooth(0, Math.max(0.05, root.crowdFade), t - keys[j - root._full].t);
            if (w <= 0)
                continue;
            const x = (t - p.t) / root.keyLife;
            w *= 1 - root._smooth(0.4, 1, x);
            if (w > 0)
                out.keys.push(Qt.vector4d(p.x, p.y, t - p.t, w));
        }
        return out;
    }
    // What the slots and the plateaus read of `_fx`, each on its own: a key array that is the same empty one while none
    // lives, and the fail's envelope as a number (it notifies only when it changes), so the sixteen slots and the five
    // plateau colours do not run again every tick (a fresh `_fx` runs them all).
    readonly property var _keys: root._fx.keys.length > 0 ? root._fx.keys : root._noKeys
    readonly property var _noKeys: []
    readonly property real _failEnv: root._fx.failEnv
    function _key(i) {
        const k = root._keys;
        return i < k.length ? k[i] : Qt.vector4d(0, 0, 0, 0);
    }

    // THE CASCADE's budget, px at 1620 high. The field's steepest slope, per px at pattern scale 1: the most
    // |grad f| can reach, max over directions e of NORM * sum(a_i k_i |cos(angle_i - e)|) for the seven waves of
    // veil_paper.vert (tools/dev/lockveil_paper_check.py works it out again from the shader and fails when this differs).
    readonly property real _gradUnit: 0.0191854
    readonly property real _gapBound: root.levelStep * root.patternScale / root._gradUnit
    readonly property real _sway: Math.max(0, Math.min(root.swayReach,
        root._gapBound - root.sheetMargin - 2 * root.swellCap - 1.06 * root.rattleLayer))
    // Sheet j's sway against sheet j - 1 (j = 1..3): out and back along an axis that turns slowly, so it is 0 at t = 0
    // (the stack starts as one field) and never longer than `_sway`.
    readonly property var _swayRate: [1, 1.37, 0.83]
    readonly property var _swayAxis: [0.6, 2.4, 4.4]
    readonly property var _swayTurn: [0.011, -0.017, 0.023]
    function _swayOf(j, t) {
        const i = j - 1;
        const s = root._sway * root._unit * Math.sin(2 * Math.PI * t * root._swayRate[i] / Math.max(1, root.swayPeriod));
        const a = root._swayAxis[i] + root._swayTurn[i] * t;
        return [Math.cos(a) * s, Math.sin(a) * s];
    }
    // Where each sheet's field is sampled from. The lowest: the drift, and on a failed attempt the whole stack's
    // rattle against the bed. Each one above: the one beneath it, plus its sway and its own small rattle against it.
    readonly property var _off: {
        const t = root._t, f = root._fx, u = root._unit, o = [];
        let x = Math.cos(root.driftAngle) * root.driftSpeed * u * t, y = Math.sin(root.driftAngle) * root.driftSpeed * u * t;
        if (f.failEnv > 0) {
            x += Math.sin(f.failPhase) * root.rattle * u * f.failEnv;
            y += 0.35 * Math.cos(f.failPhase * 0.8) * root.rattle * u * f.failEnv;
        }
        o.push([x, y]);
        for (let j = 1; j < 4; j++) {
            const s = root._swayOf(j, t);
            x += s[0];
            y += s[1];
            if (f.failEnv > 0) {
                const sg = (j % 2 === 0) ? 1 : -1;
                x += sg * Math.sin(f.failPhase + 1.7 * j) * root.rattleLayer * u * f.failEnv;
                y += 0.35 * Math.cos(f.failPhase * 0.8 + 2.3 * j) * root.rattleLayer * u * f.failEnv;
            }
            o.push([x, y]);
        }
        return o;
    }
    // The level each sheet is cut at: the stack's own, swollen by a wake, and raised until it is
    // gone by the peel. An accepted password plays the peel forwards (the top sheet goes first);
    // the entrance plays it backwards, 1 - riseClock, so the bed is laid and then each sheet
    // in turn from the lowest to the top.
    readonly property real _peelX: root._fx.okX > 0 ? root._fx.okX : (root._rise < 1 ? 1 - root._rise : 0)
    readonly property var _lev: {
        const f = root._fx, l = [], x = root._peelX;
        for (let j = 0; j < 4; j++) {
            let v = root.levelBase + root.levelStep * j;
            // every level alike: a wake swells the stack and takes nothing from the gaps (THE CASCADE)
            v -= root.wakeSwell * f.wakeEnv * 0.9;
            const a = (3 - j) * root.peelStagger;
            v += 3.2 * root._smooth(a, a + root.peelSpan, x);
            l.push(v);
        }
        return l;
    }
    // The bed's entrance front: how far out of the shell (px) it has got, in the first half of
    // the rise; it ends beyond the farthest corner.
    readonly property real _reach: {
        const W = root.width, H = root.height, s = root.stoneRect, b = root.barRect;
        function bd(x, y, r) {
            const dx = Math.max(r.x - x, 0, x - r.x - r.width), dy = Math.max(r.y - y, 0, y - r.y - r.height);
            return Math.hypot(dx, dy);
        }
        let m = 0;
        for (const c of [[0, 0], [W, 0], [0, H], [W, H]])
            m = Math.max(m, Math.min(bd(c[0], c[1], s), bd(c[0], c[1], b)));
        return m + 60 * root._unit;
    }
    // At boot the bed is whole from the first frame (no front: see `opaque` above).
    readonly property real _bedFront: root._opaque ? 1e6 : Math.min(1, root._rise * 2) * root._reach

    // A sheet's plateau: the surface, toward the deep tone by `tone`, a little toward the error tint on a fail.
    function _plateau(tone) {
        const a = root.surfaceColor, b = root.deepColor, e = root.errorColor, k = root._failEnv * root.failTint * 0.16;
        const m = (x, y, f) => x + (y - x) * f;
        return Qt.rgba(m(m(a.r, b.r, tone), e.r, k), m(m(a.g, b.g, tone), e.g, k), m(m(a.b, b.b, tone), e.b, k), 1);
    }

    ShaderEffect {
        id: fx
        anchors.fill: parent
        visible: root._opaque || root._presence > 0.001
        blending: true
        vertexShader: "../shaders/veil_paper.vert.qsb"
        fragmentShader: "../shaders/veil_paper.frag.qsb"
        mesh: GridMesh {
            resolution: Qt.size(Math.max(2, Math.ceil(root.width * root._scale / root._cell) + 1), Math.max(2, Math.ceil(root.height * root._scale / root._cell) + 1))
        }

        property vector2d size: Qt.vector2d(root.width, root.height)
        property vector4d off01: Qt.vector4d(root._off[0][0], root._off[0][1], root._off[1][0], root._off[1][1])
        property vector4d off23: Qt.vector4d(root._off[2][0], root._off[2][1], root._off[3][0], root._off[3][1])
        property vector4d lev: Qt.vector4d(root._lev[0], root._lev[1], root._lev[2], root._lev[3])
        property vector4d geo: Qt.vector4d(170 * root._unit, root._unit, 0.2, root.edgeSwell)
        property vector4d pk: Qt.vector4d(root.keySpeed, root.keyWidth, root.keyHeight, root.keyCycles)
        property vector4d pk2: Qt.vector4d(root.layerDelay, root.patternScale, root.swellCap * root._unit, 0)
        property vector4d shell: Qt.vector4d(root.stoneRect.x, root.stoneRect.y, root.stoneRect.x + root.stoneRect.width, root.stoneRect.y + root.stoneRect.height)
        // The bar continues above the item so its top corners are never met.
        property vector4d bar: Qt.vector4d(root.barRect.x, Math.min(root.barRect.y, 0) - 400, root.barRect.x + root.barRect.width, root.barRect.y + root.barRect.height)
        // (a radius never larger than the box: a popup opening out of its bar starts smaller than its corners)
        property vector4d rad: Qt.vector4d(root._hasStone ? Math.min(root.stoneRadius, root.stoneRect.width / 2, root.stoneRect.height / 2) : 0,
                                           root._hasBar ? Math.min(root.barRadius, root.barRect.width / 2, root.barRect.height / 2) : 0, 0, 0)
        property vector4d prs: Qt.vector4d(root._presence, root._opaque ? 1 : 0, 0, 0)
        property vector4d frontBed: Qt.vector4d(root._bedFront, 0, 0, 0)
        property vector4d look1: Qt.vector4d(root.shadowSpread, root.shadowStrength, root.shadowDrop, root.bevelWidth)
        property vector4d look2: Qt.vector4d(root.bevelStrength * (root._dark ? root.darkBevel : 1), root._dark ? root.darkFaceGain : root.faceGain, root.liftGain, root.stoneShadow * root._attach)
        property vector4d alphas: Qt.vector4d(root._dark ? root.bedAlphaDark : root.bedAlpha, root._dark ? root.sheetAlphaDark : root.sheetAlpha, 0, 0)
        property color colB: root._plateau(root.bedTone)
        property color col1: root._plateau(root.depthTone)
        property color col2: root._plateau(root.depthTone * 0.66)
        property color col3: root._plateau(root.depthTone * 0.33)
        property color col4: root._plateau(0)
        property vector4d fxv: Qt.vector4d(root._fx.failEnv * root.failTint, root._fx.wakeEnv * root.wakeLift, 0, 0)
        property color cSurf: root.surfaceColor
        property color cDeep: root.deepColor
        property color cHi: root.highlightColor
        property color cLo: root.shadowColor
        property color cErr: root.errorColor
        property color cShc: Qt.tint(root.shadowColor, Qt.alpha(root.errorColor, root._failEnv * root.failTint * 0.2))
        property real pulCount: root._keys.length
        property vector4d pul0: root._key(0)
        property vector4d pul1: root._key(1)
        property vector4d pul2: root._key(2)
        property vector4d pul3: root._key(3)
        property vector4d pul4: root._key(4)
        property vector4d pul5: root._key(5)
        property vector4d pul6: root._key(6)
        property vector4d pul7: root._key(7)
        property vector4d pul8: root._key(8)
        property vector4d pul9: root._key(9)
        property vector4d pul10: root._key(10)
        property vector4d pul11: root._key(11)
        property vector4d pul12: root._key(12)
        property vector4d pul13: root._key(13)
        property vector4d pul14: root._key(14)
        property vector4d pul15: root._key(15)
    }
}
