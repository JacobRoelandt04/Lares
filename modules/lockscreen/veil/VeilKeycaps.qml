pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"

// =============================================================================
// VeilKeycaps.qml -- lock veil "Keycaps".
//
// A field of raised keycaps in the material, softly lit. Slow waves press rows of them down
// and let them spring back; each key you type presses the caps outward from the password
// field in a ring, like a ripple on a keyboard; a wrong password tints a brisk ring with
// the error colour; the accepted one presses the caps in turn under a tint of ok.
// ONE shader (shaders/veil_keycaps.frag) draws it; the smooth fields (the waves, the
// pulses) are evaluated at the vertices of a GridMesh (veil_keycaps.vert), so no texture is
// re-grabbed per tick (one frame per tick).
//
//   presence  a front (squarish, like a keyboard's rectangle) travelling out from the
//             field: before it the screen is untouched; as it passes, caps rise out of the
//             surface with a little overshoot. The same over the bare ground at boot.
//
// A PURE FUNCTION OF THE HOST: no Timer, no animation; a resting host renders nothing.
// Colours are Theme tokens; `host.dark` lifts the highlight in the dark rendition.
// Lengths are item px (the shader takes them to device px by `renderScale`).
// =============================================================================
Item {
    id: root

    // `var`, not LockVeil: the lock loads a veil by URL (see VeilDimples).
    property var host: null

    // ---- the caps ---------------------------------------------------------------------------
    property real pitch: 80
    property real capFill: 0.84
    property real corner: 0.3        // corner radius, as a share of the cap's half size
    property real pressShrink: 0.2  // how much a fully pressed cap shrinks
    // ---- the waves ------------------------------------------------------------------------------
    property real wavelength: 900
    property real waveSpeed: 34
    property real waveAmp: 0.9       // press depth at a crest (0..1)
    property real waveAngle: 78      // degrees of the plane wave from the x axis (rows pressed in turn)
    // ---- the light ----------------------------------------------------------------------------------
    property real lightAngle: -2.111
    property real shadowDrop: 14
    property real shadowWidth: 14
    property real shadowGain: 0.9
    property real bevelWidth: 2.4
    property real bevelGain: 1.0
    // ---- grade ------------------------------------------------------------------------------------------
    property real overTint: 0.88
    property real gapTint: 0.6
    // ---- the entrance --------------------------------------------------------------------------------
    property real riseSpread: 4.5
    property real overshoot: 1.9
    property real originX: 0.5
    property real originY: 0.5
    // ---- pulses --------------------------------------------------------------------------------------------
    property real keyAmp: 1.6
    property real keySpeed: 520
    property real keySigma: 120
    property real keyLife: 3.0
    property real failAmp: 1.1
    property real failSpeed: 1000
    property real failSigma: 80
    property real failLife: 1.2
    property real okAmp: 0.9
    property real okSpeed: 2400
    property real okTintStrength: 0.8
    property real wakeAmp: 0.6
    property real wakeSpeed: 400
    property real wakeSigma: 220
    property real wakeLife: 2.4
    // ---- details: each a switch, off = without it ----------------------------
    property bool dish: true
    property real dishDepth: 1.0
    property bool legends: true
    property real legendGain: 1.0
    // ---- colours -----------------------------------------------------------------------------------------------
    property color capColor: Theme.surface
    property color floorColor: Theme.panelSunk
    property color midColor: Theme.border
    property color shadowColor: Theme.shadowDeep
    property color bevelColor: Theme.buttonBevel
    property color errorColor: Theme.errorStrong
    property color okColor: Theme.ok

    readonly property real _t: root.host ? root.host.time : 0
    readonly property real _dscale: root.host ? root.host.renderScale : 1
    readonly property real _pitchDev: Math.max(8, 2 * Math.round(root.pitch * root._k * root._dscale / 2))
    // lengths are given for a 1620 px high screen and scale with it
    readonly property real _k: Math.max(0.25, root.height / 1620)
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

    // THE CLEAR follows the accepted ring out, trailing the green coloration by ~2-3 keys (a key lights up green and shortly after it disappears): each cap
    // is half way down when the ring has passed it by `clearTrailKeys` keys, over `clearSink` s, at the ring's own speed and from its centre, so the two fronts never cross.
    // The ring crosses the farthest corner well inside the clear; whatever a very wide output has left at its end is gone with the presence.
    property real clearTrailKeys: 2.5
    property real clearSink: 0.07
    readonly property vector4d _clearFront: {
        const h = root.host;
        if (!h || h.okTime < 0)
            return Qt.vector4d(0, 0, 0, 0);
        const ok = h.pulses.find(p => p.kind === "ok" && p.t === h.okTime);
        const trail = root.clearTrailKeys * root.pitch * root._k / root.okSpeed;
        return ok ? Qt.vector4d(ok.x, ok.y, root._t - h.okTime - trail + root.clearSink / 2, root.clearSink) : Qt.vector4d(0, 0, 0, 0);
    }
    readonly property real _presence: root.host ? (root.host.clear >= 1 ? 0 : root.host.riseClock) : 1

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
    // the shader's squarish metric (x^4 + y^4)^(1/4), the farthest corner from the popup rect
    function _met(x, y) { return Math.pow(Math.pow(Math.abs(x), 4) + Math.pow(Math.abs(y), 4), 0.25); }
    function _out(cx, cy) {
        return root._met(Math.max(Math.abs(cx - root._rect.x) - root._rect.z, 0), Math.max(Math.abs(cy - root._rect.y) - root._rect.w, 0));
    }
    readonly property real _far: Math.max(root._out(0, 0), root._out(root.width, 0), root._out(0, root.height), root._out(root.width, root.height))

    function _c(c) { return Qt.vector4d(c.r, c.g, c.b, c.a); }

    ShaderEffect {
        id: fx
        anchors.fill: parent
        blending: true
        visible: root.host && (root.host.presence > 0 || root.host.opaque) && root.width > 0
        vertexShader: "../shaders/veil_keycaps.vert.qsb"
        fragmentShader: "../shaders/veil_keycaps.frag.qsb"
        mesh: GridMesh {
            resolution: Qt.size(Math.max(1, Math.ceil(root.width / root._step)), Math.max(1, Math.ceil(root.height / root._step)))
        }

        readonly property bool _dark: root.host ? root.host.dark : false
        property vector2d size: Qt.vector2d(root.width, root.height)
        readonly property real _k: 2 * Math.PI / root.wavelength

        property real dscale: root._dscale
        property real time: root._t
        // the front reads LINEAR time: the host's riseClock undoes the lock's OutCubic
        property real presence: root._presence
        property real opaque: root.host && root.host.opaque ? 1 : 0
        property vector2d origin: root._origin
        property vector4d rect: root._rect
        property vector4d detail: Qt.vector4d(root.dish ? root.dishDepth : 0, root.legends ? root.legendGain : 0, 0, 0)
        property vector4d clearFront: root._clearFront

        property vector4d grid: Qt.vector4d(root._pitchDev, root.capFill, root.corner, root.shadowWidth * root._k * root._dscale)
        property vector4d wave: Qt.vector4d(fx._k, fx._k * root.waveSpeed, root.waveAmp,
                                            root.waveAngle * root._rad + 0.2 * Math.sin(0.017 * root._t))
        property vector4d srcA: Qt.vector4d(root.width * (0.5 + 0.40 * Math.sin(0.071 * root._t + 0.3)),
                                            root.height * (0.5 + 0.36 * Math.cos(0.053 * root._t + 1.1)),
                                            root.shadowDrop * root._k * root._dscale, root.pressShrink)
        property vector4d light: Qt.vector4d(Math.cos(root.lightAngle), Math.sin(root.lightAngle),
                                             root.bevelWidth * root._k * root._dscale, root.riseSpread)
        property vector4d grade: Qt.vector4d(root.overTint, root.gapTint, root.shadowGain, root.bevelGain)
        property vector4d grade2: Qt.vector4d(fx._dark ? 1 : 0, root.overshoot, root._far, 0)

        property vector4d cCap: root._c(root.capColor)
        property vector4d cFloor: root._c(root.floorColor)
        property vector4d cMid: root._c(root.midColor)
        property vector4d cShadow: root._c(root.shadowColor)
        property vector4d cBevel: root._c(fx._dark ? Qt.tint(root.bevelColor, Qt.alpha(Theme.textPrimary, 0.14)) : root.bevelColor)
        property vector4d cError: root._c(root.errorColor)
        property vector4d cOk: root._c(root.okColor)

        property vector4d pk: Qt.vector4d(root.keyAmp, root.keySpeed, root.keySigma, root.keyLife)
        property vector4d pf: Qt.vector4d(root.failAmp, root.failSpeed, root.failSigma, root.failLife)
        property vector4d po: Qt.vector4d(root.okAmp, root.okSpeed, root._pv.n, root.okTintStrength)
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
