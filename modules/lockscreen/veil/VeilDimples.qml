pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"

// =============================================================================
// VeilDimples.qml -- lock veil "Dimple field" (contract section 7).
//
// A pin-screen of tiny carved wells, lit like small carved ShadowBoxes, their
// depths following slow travelling waves: broad bands sweeping across and two
// radial waves from drifting sources. ONE shader (shaders/veil_dimples.frag) draws all of it; this file
// hands it the state.
//
// A PURE FUNCTION OF THE HOST: no Timer, no animation. The three sources'
// positions and the pulses' ages are computed from `host.time`, so a resting
// host renders nothing. Colours come from Theme; `host.dark` picks the dark
// rendition's bevel lift.
//
// Over the desktop the plateau is a translucent tint of the surface and the
// wells' floors are more transparent the deeper they are (the blurred desktop
// glows in them); at boot everything is opaque. Presence is the ENTRANCE's clock: a
// front rolls out from the popup (`originX/Y` when it is unknown) and each cell snaps in
// as it passes (see the entrance block below).
// =============================================================================
Item {
    id: root

    // `var`, not LockVeil: the lock loads a veil by URL, and a directory's
    // types resolve there only while some `import` names that directory
    // (LockSurface imports "../veil" for that); `var` keeps a veil loadable
    // either way.
    property var host: null

    // ---- the grid ---------------------------------------------------------------
    property real pitch: 24
    property real radius: 0.66
    property real minDepth: 0.04
    // ---- details (each a switch: 0 = off, reverting means setting it back to 0) -------------
    property real rimGlint: 1
    property real shadowWidth: 4.5
    property real bevelWidth: 1.5
    property real lightAngle: -2.36
    // ---- the waves ------------------------------------------------------------------
    property real wavelength: 700
    property real waveSpeed: 32
    property real waveContrast: 1.5
    // ---- grade ------------------------------------------------------------------------
    property real overTint: 0.78
    property real floorGlow: 0.62
    property real groundDepth: 0.2
    property real shadowGain: 1.0
    property real bevelGain: 1.0
    property real originX: 0.5
    property real originY: 0.28
    // ---- pulses --------------------------------------------------------------------------
    property real keyAmp: 1.4
    property real keySpeed: 560
    property real keySigma: 70
    property real keyLife: 3.0
    property real failAmp: 1.5
    property real failSpeed: 1000
    property real failSigma: 75
    property real failLife: 0.9
    // ---- the clear (the accepted password): a ring of pressure runs out of the popup and the pins lie flush behind it ----
    property real clearWidth: 0.1        // of the diagonal: how wide the ring is
    property real wakeAmp: 0.7
    property real wakeSpeed: 400
    property real wakeSigma: 210
    property real wakeLife: 2.4

    readonly property real _t: root.host ? root.host.time : 0
    // the pitch in device px: even, so wells and cell edges lie on whole pixels
    readonly property real _pitchDev: Math.max(8, 2 * Math.round(root.pitch / 2))

    readonly property var _kinds: ({ key: 1, fail: 2, wake: 4 })
    readonly property var _life: ({ 1: 4, 2: 2.5, 4: 6 })
    // Up to 32 are drawn (the host keeps 32). When more than `_cap` are alive the
    // oldest are FADED out, over `_fadeS`, from the moment the `_cap`-th newer
    // one arrives -- never cut: a pulse carries its weight in the fraction of its
    // kind (kind + 0.9 * (1 - weight)), which the vertex stage multiplies in.
    readonly property int _cap: 28
    readonly property real _fadeS: 0.25
    readonly property var _pv: {
        const now = root._t;
        const ps = root.host ? root.host.pulses : [];
        const alive = [];
        for (let i = ps.length - 1; i >= 0 && alive.length < 32; i--) {
            const k = root._kinds[ps[i].kind] || 0;
            const age = now - ps[i].t;
            if (k > 0 && age >= 0 && age < root._life[k])
                alive.push(i);
        }
        const out = [];
        for (let j = 0; j < alive.length; j++) {
            const p = ps[alive[j]];
            let w = 1;
            if (j >= root._cap) {
                const x = Math.max(0, Math.min(1, (now - ps[alive[j - root._cap]].t) / root._fadeS));
                w = 1 - x * x * (3 - 2 * x);
            }
            if (w > 0)
                out.push(Qt.vector4d(p.x, p.y, now - p.t, root._kinds[p.kind] + 0.9 * (1 - w)));
        }
        const n = out.length;
        // nothing alive: the same object every tick, so the 32 slots' bindings do not run again (a fresh one runs them all)
        if (n === 0)
            return root._pvNone;
        while (out.length < 32)
            out.push(Qt.vector4d(0, 0, 0, 0));
        return { v: out, n: n };
    }
    readonly property var _pvNone: {
        const v = [];
        for (let i = 0; i < 32; i++)
            v.push(Qt.vector4d(0, 0, 0, 0));
        return { v: v, n: 0 };
    }

    readonly property real _dscale: root.host ? root.host.renderScale : 1
    // the smooth fields are evaluated at the vertices of a GridMesh, one per `_step` (16) item px
    readonly property real _step: 16

    // where the entrance starts: the lock popup's rectangle when the host knows it (the front
    // leaves its EDGE, so it is on screen the moment presence leaves 0), else a point
    readonly property bool _hasRect: root.host && root.host.popupRect.width > 0
    readonly property vector2d _origin: root._hasRect
        ? Qt.vector2d(root.host.popupRect.x + root.host.popupRect.width / 2, root.host.popupRect.y + root.host.popupRect.height / 2)
        : Qt.vector2d(root.width * root.originX, root.height * root.originY)
    readonly property vector2d _half: root._hasRect ? Qt.vector2d(root.host.popupRect.width / 2, root.host.popupRect.height / 2) : Qt.vector2d(0, 0)

    // ---- the entrance -----------------------------------------------------------------
    // A front sweeps out from the origin (the popup) and a point goes from the desktop to
    // the finished veil as it passes: `frontWidth` (a fraction of the diagonal) is how much
    // of the screen that takes. The lock eases `presence` with OutCubic, so the front's
    // clock is its inverse (linear in real time, already moving ~100 ms in) and it reaches
    // the far corner when presence is 1 / `frontReach`: the rest of the rise is spent
    // finished, not waiting.
    property real frontWidth: 0.07
    property real frontReach: 1.6
    readonly property real _sweep: root.host ? root.host.riseClock : 1
    readonly property real _diag: Math.hypot(root.width, root.height)
    readonly property real _frontW: Math.max(1, root.frontWidth * root._diag)
    function _out(x, y) { return Math.hypot(Math.max(Math.abs(x - root._origin.x) - root._half.x, 0), Math.max(Math.abs(y - root._origin.y) - root._half.y, 0)); }
    readonly property real _reachPx: Math.max(root._out(0, 0), root._out(root.width, 0), root._out(0, root.height), root._out(root.width, root.height))
    // the front is on screen from the first frame: a ring 0.55 of its width beyond the popup's edge
    // is up within 20 ms of presence leaving 0, and the rest of the sweep follows
    readonly property real _f0: root._frontW * 0.55 * Math.min(1, root._sweep * 60)
    // THE CLEAR is a ring of release running OUT of the popup, the opposite way to the entrance: a pin
    // is a pin of a pin-screen, and what lets go of a screen of pins is a hand pressed flat on it. The
    // front's width is NEGATIVE (1 / -width), which turns the entrance's `pr` round: 0 inside the ring's
    // radius (the cell is flush, its tint gone and the desktop through), 1 beyond it (untouched), the
    // cell snapping as the ring passes it with the same overshoot the entrance has. The ring starts
    // one width inside the popup's edge so the first frame is the finished veil, and ends beyond the
    // farthest corner.
    readonly property real _clearEase: { const c = root.host ? root.host.clear : 0; return c * (2 - c); }
    readonly property real _clearW: Math.max(1, root.clearWidth * root._diag)
    readonly property vector4d _front: root._clearEase > 0
        ? Qt.vector4d(-root._clearW + root._clearEase * (root._reachPx + root._clearW), -1 / root._clearW, root._half.x, root._half.y)
        : Qt.vector4d(root._f0 + Math.min(1, root._sweep * root.frontReach) * (root._reachPx + root._frontW - root._f0), 1 / root._frontW, root._half.x, root._half.y)

    function _c(c) { return Qt.vector4d(c.r, c.g, c.b, c.a); }

    ShaderEffect {
        id: fx
        anchors.fill: parent
        blending: true
        visible: root.host && root.host.presence > 0 && root.width > 0
        vertexShader: "../shaders/veil_dimples.vert.qsb"
        fragmentShader: "../shaders/veil_dimples.frag.qsb"
        mesh: GridMesh {
            resolution: Qt.size(Math.max(1, Math.ceil(root.width / root._step)), Math.max(1, Math.ceil(root.height / root._step)))
        }

        readonly property bool _dark: root.host ? root.host.dark : false
        property vector2d size: Qt.vector2d(root.width, root.height)
        readonly property real _k: 2 * Math.PI / root.wavelength

        property real dscale: root._dscale
        property real time: root._t
        property real presence: root.host ? root.host.presence : 1
        property real opaque: root.host && root.host.opaque ? 1 : 0
        property vector2d origin: root._origin
        property vector4d wave: Qt.vector4d(fx._k, fx._k * root.waveSpeed, root.waveContrast, 0.55 + 0.25 * Math.sin(0.021 * root._t))
        property vector4d srcA: Qt.vector4d(root.width * (0.5 + 0.40 * Math.sin(0.071 * root._t + 0.3)),
                                            root.height * (0.5 + 0.36 * Math.cos(0.053 * root._t + 1.1)),
                                            root.width * (0.5 + 0.44 * Math.cos(0.047 * root._t + 2.0)),
                                            root.height * (0.5 + 0.40 * Math.sin(0.061 * root._t + 4.0)))

        property vector4d grid: Qt.vector4d(root._pitchDev, root.radius, root.minDepth, root.shadowWidth)
        property vector4d light: Qt.vector4d(Math.cos(root.lightAngle), Math.sin(root.lightAngle), root.bevelWidth, 0)
        property vector4d grade: Qt.vector4d(root.overTint, root.floorGlow, root.shadowGain, root.bevelGain)
        property vector4d front: root._front
        property vector4d grade2: Qt.vector4d(fx._dark ? 1 : 0, root.rimGlint, 0, 0)

        property vector4d cSurface: root._c(Qt.tint(Theme.surface, Qt.alpha(Theme.border, root.groundDepth)))
        property vector4d cFloor: root._c(Theme.panelSunk)
        property vector4d cMid: root._c(Theme.border)
        property vector4d cShadow: root._c(Theme.shadowDeep)
        property vector4d cBevel: root._c(fx._dark ? Qt.tint(Theme.bevel, Qt.alpha(Theme.textPrimary, 0.14)) : Theme.bevel)
        property vector4d cError: root._c(Theme.errorStrong)

        property vector4d pk: Qt.vector4d(root.keyAmp, root.keySpeed, root.keySigma, root.keyLife)
        property vector4d pf: Qt.vector4d(root.failAmp, root.failSpeed, root.failSigma, root.failLife)
        property vector4d po: Qt.vector4d(0, 0, root._pv.n, 0)
        property vector4d pw: Qt.vector4d(root.wakeAmp, root.wakeSpeed, root.wakeSigma, root.wakeLife)
        property vector4d p0: root._pv.v[0]
        property vector4d p1: root._pv.v[1]
        property vector4d p2: root._pv.v[2]
        property vector4d p3: root._pv.v[3]
        property vector4d p4: root._pv.v[4]
        property vector4d p5: root._pv.v[5]
        property vector4d p6: root._pv.v[6]
        property vector4d p7: root._pv.v[7]
        property vector4d p8: root._pv.v[8]
        property vector4d p9: root._pv.v[9]
        property vector4d p10: root._pv.v[10]
        property vector4d p11: root._pv.v[11]
        property vector4d p12: root._pv.v[12]
        property vector4d p13: root._pv.v[13]
        property vector4d p14: root._pv.v[14]
        property vector4d p15: root._pv.v[15]
        property vector4d p16: root._pv.v[16]
        property vector4d p17: root._pv.v[17]
        property vector4d p18: root._pv.v[18]
        property vector4d p19: root._pv.v[19]
        property vector4d p20: root._pv.v[20]
        property vector4d p21: root._pv.v[21]
        property vector4d p22: root._pv.v[22]
        property vector4d p23: root._pv.v[23]
        property vector4d p24: root._pv.v[24]
        property vector4d p25: root._pv.v[25]
        property vector4d p26: root._pv.v[26]
        property vector4d p27: root._pv.v[27]
        property vector4d p28: root._pv.v[28]
        property vector4d p29: root._pv.v[29]
        property vector4d p30: root._pv.v[30]
        property vector4d p31: root._pv.v[31]
    }
}
