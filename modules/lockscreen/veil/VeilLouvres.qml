pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"

// =============================================================================
// VeilLouvres.qml -- lock veil "Louvres".
//
// The surface as rows of slats, like a kinetic facade or a venetian blind. A slow wave turns
// them so the light rolls across the screen in bands. A key sends a turning wave out from the
// password field; a wrong password flutters them; the accepted password lines them all up.
// ONE shader (shaders/veil_louvres.frag) draws it; the smooth fields (the wave, the pulses)
// are evaluated at the vertices of a GridMesh (veil_louvres.vert) so a texture never has to
// be re-grabbed per tick (one frame per tick).
//
//   presence  a front travelling out from the field: slats the front has not reached lie
//             edge-on and invisible; as it passes each turns (with a little overshoot) to
//             the angle the wave gave it. The same over the bare ground at boot.
//
// A PURE FUNCTION OF THE HOST: no Timer, no animation; a resting host renders nothing.
// Colours are Theme tokens; `host.dark` lifts the highlight in the dark rendition.
// Lengths are item px (the shader takes them to device px by `renderScale`).
// =============================================================================
Item {
    id: root

    // `var`, not LockVeil: the lock loads a veil by URL (see VeilDimples).
    property var host: null

    // ---- the slats ----------------------------------------------------------------------
    property real pitch: 40
    property real slatFill: 0.9
    property real curve: 20          // degrees of normal across a slat: its convexity
    // ---- the wave -------------------------------------------------------------------------
    property real wavelength: 900
    property real waveSpeed: 40
    property real tilt: 55           // degrees at the wave's crest
    property real stagger: 5          // degrees: each slat out of step with its neighbour
    property real waveAngle: 28      // degrees of the plane wave from the x axis
    // ---- the light ---------------------------------------------------------------------------
    property real lightAngle: -2.111
    property real elevation: 40      // degrees of the light from the screen normal
    property real shadowWidth: 11
    property real shadowGain: 1.0
    property real bevelWidth: 1.6
    property real bevelGain: 1.0
    // ---- grade ---------------------------------------------------------------------------------
    property real overTint: 0.86
    property real gapTint: 0.55
    // ---- the entrance ----------------------------------------------------------------------
    property real riseSpread: 4.5
    property real overshoot: 1.7
    property real originX: 0.5
    property real originY: 0.5
    // ---- pulses --------------------------------------------------------------------------------------
    property real keyAmp: 60         // degrees
    property real keySpeed: 520
    property real keySigma: 100
    property real keyLife: 3.0
    property real failFlutter: 30    // degrees
    property real failSpeed: 1000
    property real failSigma: 130
    property real failLife: 1.5
    property real flutterHz: 7
    property real flutterLag: 0.02   // rad per item px along a slat
    property real okAngle: 38        // degrees
    property real okSpeed: 2400
    property real wakeAmp: 18        // degrees
    property real wakeSpeed: 400
    property real wakeSigma: 230
    property real wakeLife: 2.4
    // ---- details: each a switch, off = without it ----------------------------
    property bool edgeGlint: true
    property real glintGain: 1.0
    property bool gloss: true
    property real glossGain: 1.0
    // ---- colours ----------------------------------------------------------------------------------------
    property color slatColor: Theme.surface
    property color floorColor: Theme.panelSunk
    property color midColor: Theme.border
    property color shadowColor: Theme.shadowDeep
    property color bevelColor: Theme.buttonBevel
    property color errorColor: Theme.errorStrong

    readonly property real _t: root.host ? root.host.time : 0
    readonly property real _dscale: root.host ? root.host.renderScale : 1
    readonly property real _pitchDev: Math.max(8, 2 * Math.round(root.pitch * root._dscale / 2))
    readonly property real _rad: Math.PI / 180
    // the smooth fields are evaluated at the vertices of a GridMesh, one per `_step` item px
    readonly property real _step: 24

    readonly property var _kinds: ({ key: 1, fail: 2, ok: 3, wake: 4 })
    // a pulse is dropped once its envelope (decay constant `life`) is ~4 % of what it was
    readonly property var _life: ({ 1: root.keyLife * 3.2, 2: root.failLife * 3.2, 3: 5, 4: root.wakeLife * 3.2 })
    // Up to 32 are drawn (the host keeps 32). When more than `_cap` are alive the oldest are
    // FADED out, over `_fadeS`, from the moment the `_cap`-th newer one arrives -- never cut:
    // a pulse carries its weight in the fraction of its kind (kind + 0.9 * (1 - weight)).
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

    // THE CLEAR: the accepted password lines every slat up (the front at `okSpeed`), and then the blind is
    // drawn: the slats turn edge-on again, row by row from the bottom of the screen up to the bar the popup
    // went into (veil_louvres.frag, THE CLEAR). `clearDelay` of the clear goes by before the first row turns.
    property real clearDelay: 0.15
    readonly property real _clearBack: { const c = root.host ? root.host.clear : 0; return Math.max(0, Math.min(1, (c - root.clearDelay) / (0.95 - root.clearDelay))); }

    // where the entrance starts: the lock popup's password field when the host knows it
    readonly property vector2d _origin: root.host && root.host.popupRect.width > 0
        ? Qt.vector2d(root.host.popupRect.x + root.host.popupRect.width / 2, root.host.popupRect.y + root.host.popupRect.height * 0.62)
        : Qt.vector2d(root.width * root.originX, root.height * root.originY)

    // the popup's rect (centre, half extent); the entrance's front leaves its OUTLINE, so it is
    // visible from the first frame of the rise (a point where the host knows no popup)
    readonly property vector4d _rect: root.host && root.host.popupRect.width > 0
        ? Qt.vector4d(root.host.popupRect.x + root.host.popupRect.width / 2, root.host.popupRect.y + root.host.popupRect.height / 2,
                      root.host.popupRect.width / 2, root.host.popupRect.height / 2)
        : Qt.vector4d(root._origin.x, root._origin.y, 0, 0)
    function _out(cx, cy) {
        return Math.hypot(Math.max(Math.abs(cx - root._rect.x) - root._rect.z, 0), Math.max(Math.abs(cy - root._rect.y) - root._rect.w, 0));
    }
    readonly property real _far: Math.max(root._out(0, 0), root._out(root.width, 0), root._out(0, root.height), root._out(root.width, root.height))

    function _c(c) { return Qt.vector4d(c.r, c.g, c.b, c.a); }

    ShaderEffect {
        id: fx
        anchors.fill: parent
        blending: true
        visible: root.host && (root.host.presence > 0 || root.host.opaque) && root.width > 0
        vertexShader: "../shaders/veil_louvres.vert.qsb"
        fragmentShader: "../shaders/veil_louvres.frag.qsb"
        mesh: GridMesh {
            resolution: Qt.size(Math.max(1, Math.ceil(root.width / root._step)), Math.max(1, Math.ceil(root.height / root._step)))
        }

        readonly property bool _dark: root.host ? root.host.dark : false
        property vector2d size: Qt.vector2d(root.width, root.height)
        readonly property real _k: 2 * Math.PI / root.wavelength

        property real dscale: root._dscale
        property real time: root._t
        // the front reads LINEAR time: the host's riseClock undoes the lock's OutCubic
        property real presence: root.host ? root.host.riseClock : 1
        property real opaque: root.host && root.host.opaque ? 1 : 0
        property vector2d origin: root._origin
        property vector4d rect: root._rect
        property vector4d detail: Qt.vector4d(root.edgeGlint ? root.glintGain : 0, root.gloss ? root.glossGain : 0, 0, 0)

        property vector4d grid: Qt.vector4d(root._pitchDev, root.slatFill, root.curve * root._rad, root.shadowWidth * root._dscale)
        property vector4d wave: Qt.vector4d(fx._k, fx._k * root.waveSpeed, root.tilt * root._rad,
                                            root.waveAngle * root._rad + 0.25 * Math.sin(0.019 * root._t))
        property vector4d srcA: Qt.vector4d(root.width * (0.5 + 0.40 * Math.sin(0.071 * root._t + 0.3)),
                                            root.height * (0.5 + 0.36 * Math.cos(0.053 * root._t + 1.1)), root.stagger * root._rad, root._far)
        property vector4d light: Qt.vector4d(Math.cos(root.lightAngle), Math.sin(root.lightAngle),
                                             Math.sin(root.elevation * root._rad), Math.cos(root.elevation * root._rad))
        property vector4d grade: Qt.vector4d(root.overTint, root.gapTint, root.shadowGain, root.bevelGain)
        property vector4d grade2: Qt.vector4d(fx._dark ? 1 : 0, root.bevelWidth * root._dscale, root.riseSpread, root.okAngle * root._rad)
        property vector4d flut: Qt.vector4d(root.failFlutter * root._rad, 2 * Math.PI * root.flutterHz, root.flutterLag, root.overshoot)

        property vector4d cSlat: root._c(root.slatColor)
        property vector4d cFloor: root._c(root.floorColor)
        property vector4d cMid: root._c(root.midColor)
        property vector4d cShadow: root._c(root.shadowColor)
        property vector4d cBevel: root._c(fx._dark ? Qt.tint(root.bevelColor, Qt.alpha(Theme.textPrimary, 0.14)) : root.bevelColor)
        property vector4d cError: root._c(root.errorColor)

        property vector4d pk: Qt.vector4d(root.keyAmp * root._rad, root.keySpeed, root.keySigma, root.keyLife)
        property vector4d pf: Qt.vector4d(0, root.failSpeed, root.failSigma, root.failLife)
        property vector4d po: Qt.vector4d(1, root.okSpeed, root._pv.n, root._clearBack)
        property vector4d pw: Qt.vector4d(root.wakeAmp * root._rad, root.wakeSpeed, root.wakeSigma, root.wakeLife)
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
