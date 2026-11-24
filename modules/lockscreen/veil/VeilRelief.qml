pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../../common/theme"
import "../../common/components"
import "../../common/components/JsonComments.js" as JsonComments
import "../../weather/data/Astro.js" as Astro

// =============================================================================
// VeilRelief.qml -- lock veil "Sunlit relief" (contract section 7).
//
// The eva surface becomes a low carved landscape of dune ridges, lit by the
// real sun (moon at night) for the local time and place. Drawn by ONE shader
// (shaders/veil_relief.frag) over the smooth fields evaluated at a coarse GridMesh's vertices that
// shaders/veil_relief.vert fills (the smooth noises and the pulses, one
// vertex per 16 px); this file only hands them the state.
//
// A PURE FUNCTION OF THE HOST. No Timer, no animation: `host.time` drives the
// drift, the pulses' ages and the light (re-read from the wall clock once per
// `lightRefreshS` veil seconds -- a binding that also depends on host.time, so
// a resting host renders nothing). Colours come from Theme; `host.dark` picks
// the dark rendition's gains.
//
// THE LIGHT. The screen is a map with SOUTH UP: the noon sun lights it from
// the top, the morning from the left, the evening from the right -- which is
// the shell's own light (carved boxes are lit from the top left). The sun's
// elevation sets how long the shadows are and how hard the contrast (a low
// sun rakes the terrain, a high one flattens it), golden hour warms the
// highlights. Under the horizon the moon lights it (its phase sets the
// power), cool and low, the veil darker and bluer.
//
// LOCATION: the default (else the first) location of weather.jsonc, read once;
// Brussels without one.
// =============================================================================
Item {
    id: root

    // `var`, not LockVeil: the lock loads a veil by URL, and a directory's
    // types resolve there only while some `import` names that directory
    // (LockSurface imports "../veil" for that); `var` keeps a veil loadable
    // either way.
    property var host: null

    // ---- terrain ------------------------------------------------------------
    property real amplitude: 90
    property real wavelength: 720
    property real windAngle: 0.42
    property real driftSpeed: 7
    property real crestPos: 0.76
    property real rippleAmp: 0.25
    property real rippleWavelength: 16
    // ---- details (each a switch: 0 = off, reverting means setting it back to 0) -------------
    property real glints: 1
    property real grain: 1
    property real rippleFade: 0.45
    property real rimStrength: 0.9
    property real warpTurns: 0.9
    property real envelopeDepth: 0.45
    // ---- light and grade --------------------------------------------------------
    property real hour: -1
    property real contrast: 1.8
    property real castStrength: 0.5
    property real overTint: 0.62
    property real shadowAlpha: 0.85
    property real lightAlpha: 0.8
    property real breath: 0.22
    property real vignette: 0.35
    property real groundDepth: 0.3
    property real darkLightGain: 1.0
    // ---- pulses -----------------------------------------------------------------------
    property real keyAmp: 26
    property real keySpeed: 520
    property real keySigma: 42
    property real keyLife: 2.0
    property real failAmp: 42
    property real failSpeed: 900
    property real failSigma: 52
    property real failLife: 0.5
    // ---- the clear (the accepted password): the dunes sink flat, far edges first, as the sun comes up ----
    property real clearFeather: 0.5      // of the diagonal: how soft the front is, so the whole terrain is going at once
    property real wakeAmp: 70
    property real wakeSpeed: 380
    property real wakeSigma: 200
    property real wakeLife: 2.2
    property real lightRefreshS: 10
    property real darkLift: 0.3
    property real originX: 0.5
    property real originY: 0.28

    // ---- place -----------------------------------------------------------------
    property real _lat: 50.85
    property real _lon: 4.35
    ConfigFile {
        id: cfg
        path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/quickshell/config/weather.jsonc"
        watchChanges: false
    }
    Component.onCompleted: {
        try {
            const j = JSON.parse(JsonComments.strip(cfg.text()));
            const ls = (j.locations || []).filter(l => typeof l.lat === "number" && typeof l.lon === "number");
            const l = ls.find(x => x.default) || ls[0];
            if (l) {
                root._lat = l.lat;
                root._lon = l.lon;
            }
        } catch (e) {}
        // a render's hook: pins the time of day without a panel
        const hv = Quickshell.env("VEIL_HOUR");
        if (hv !== null && hv !== undefined && hv !== "" && !isNaN(Number(hv)))
            root.hour = Number(hv);
    }

    // ---- the sky ------------------------------------------------------------------------
    function _ss(a, b, x) {
        const t = Math.max(0, Math.min(1, (x - a) / (b - a)));
        return t * t * (3 - 2 * t);
    }
    // toward-the-light vector on the south-up map
    function _vec(az, el) {
        const c = Math.cos(el);
        return [c * Math.sin(az), -c * Math.cos(az), Math.sin(el)];
    }
    function _sky(bucket, hourOv, lat, lon) {
        let ms = Date.now();
        if (hourOv >= 0) {
            const d = new Date();
            d.setHours(Math.floor(hourOv), Math.round((hourOv % 1) * 60), 0, 0);
            ms = d.getTime();
        }
        const D = Math.PI / 180;
        const sun = Astro.getPosition(ms, lat, lon);
        const moon = Astro.getMoonPosition(ms, lat, lon);
        const ill = Astro.getMoonIllumination(ms).fraction;
        const sa = sun.altitude / D;
        const day = root._ss(-4, 6, sa);
        const sv = root._vec(sun.azimuth, Math.max(sun.altitude, 3 * D));
        const mv = root._vec(moon.azimuth, Math.max(10 * D, Math.min(55 * D, moon.altitude)));
        let x = mv[0] + (sv[0] - mv[0]) * day, y = mv[1] + (sv[1] - mv[1]) * day, z = mv[2] + (sv[2] - mv[2]) * day;
        const n = Math.hypot(x, y, z) || 1;
        const sunPow = 0.6 + 0.4 * root._ss(0, 28, sa);
        const moonPow = (0.5 + 0.3 * ill) * (moon.altitude > 0 ? 1 : 0.7);
        return {
            l: Qt.vector4d(x / n, y / n, z / n, moonPow + (sunPow - moonPow) * day),
            night: 1 - day,
            warm: day * (1 - root._ss(3, 24, sa))
        };
    }
    readonly property var _sk: {
        const b = root.host ? Math.floor(root.host.time / Math.max(1, root.lightRefreshS)) : 0;
        return root._sky(b, root.hour, root._lat, root._lon);
    }

    // ---- pulses ---------------------------------------------------------------------------
    // Up to 32 are drawn (the host keeps 32). When more than `_cap` are alive the
    // oldest are FADED out, over `_fadeS`, from the moment the `_cap`-th newer
    // one arrives -- never cut: a pulse carries its weight in the fraction of its
    // kind (kind + 0.9 * (1 - weight)), which the vertex stage multiplies in.
    readonly property var _kinds: ({ key: 1, fail: 2, wake: 4 })
    readonly property var _life: ({ 1: 3.5, 2: 2.5, 4: 5 })
    readonly property int _cap: 28
    readonly property real _fadeS: 0.25
    readonly property var _pv: {
        const now = root.host ? root.host.time : 0;
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

    // the smooth fields are evaluated at the vertices of a GridMesh, one per `_step` px
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
    // THE CLEAR is the entrance run back, with a front fifty times as soft: ground behind the front is
    // dune, ahead flat, and the front comes in from the far corners to the popup, so the dunes sink first
    // where they are farthest from the shell and last beside it. The feather is so wide (half a diagonal)
    // that the whole screen is sinking at once, which reads as the terrain settling under the rising sun
    // rather than as a wave: the shading goes with the heights (no slope, no shadow, no cast), and the
    // tint that holds the veil over the desktop follows `pr` too, so the desktop comes back through it.
    readonly property real _clearEase: { const c = root.host ? root.host.clear : 0; return c * c * (3 - 2 * c); }
    readonly property real _clearW: Math.max(1, root.clearFeather * root._diag)
    readonly property vector4d _front: root._clearEase > 0
        ? Qt.vector4d((root._reachPx + root._clearW) * (1 - root._clearEase), 1 / root._clearW, root._half.x, root._half.y)
        : Qt.vector4d(root._f0 + Math.min(1, root._sweep * root.frontReach) * (root._reachPx + root._frontW - root._f0), 1 / root._frontW, root._half.x, root._half.y)

    function _c(c) { return Qt.vector4d(c.r, c.g, c.b, c.a); }

    ShaderEffect {
        id: fx
        anchors.fill: parent
        blending: true
        visible: root.host && root.host.presence > 0 && root.width > 0
        vertexShader: "../shaders/veil_relief.vert.qsb"
        fragmentShader: "../shaders/veil_relief.frag.qsb"
        mesh: GridMesh {
            resolution: Qt.size(Math.max(1, Math.ceil(root.width / root._step)), Math.max(1, Math.ceil(root.height / root._step)))
        }

        readonly property bool _dark: root.host ? root.host.dark : false

        property vector2d size: Qt.vector2d(root.width, root.height)
        property real time: root.host ? root.host.time : 0
        property real presence: root.host ? root.host.presence : 1
        property real opaque: root.host && root.host.opaque ? 1 : 0
        property vector2d origin: root._origin

        property vector4d terrain: Qt.vector4d(root.amplitude, root.wavelength, root.windAngle, root.driftSpeed)
        property vector4d detail: Qt.vector4d(root.rippleAmp, root.warpTurns, root.envelopeDepth, root.crestPos)
        property vector4d rip: Qt.vector4d(root.rippleWavelength, root.rippleFade, root.rimStrength, 0)
        property vector4d light: root._sk.l
        property vector4d sky: Qt.vector4d(root._sk.night, root._sk.warm, root.castStrength, root.contrast * (fx._dark ? root.darkLightGain : 1))
        property vector4d grade: Qt.vector4d(root.overTint, root.shadowAlpha, root.lightAlpha, root.vignette)
        property vector4d grade2: Qt.vector4d(root.breath, fx._dark ? 1 : 0, 1, root.grain)

        property vector4d cSurface: root._c(Qt.tint(Theme.surface, Qt.alpha(Theme.border, root.groundDepth * (fx._dark ? 0.35 : 1))))
        property vector4d cShadow: root._c(Theme.shadowDeep)
        property vector4d cBevel: root._c(fx._dark ? Qt.tint(Theme.bevel, Qt.alpha(Theme.textPrimary, root.darkLift)) : Theme.bevel)
        property vector4d cNight: root._c(Theme.weatherNight)
        property vector4d cWarm: root._c(Theme.weatherSunDisc)
        property vector4d cError: root._c(Theme.errorStrong)

        property vector4d po: Qt.vector4d(0, 0, root._pv.n, 0)
        property vector4d pk: Qt.vector4d(root.keyAmp, root.keySpeed, root.keySigma, root.keyLife)
        property vector4d pf: Qt.vector4d(root.failAmp, root.failSpeed, root.failSigma, root.failLife)
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

        // what the shader would otherwise compute per pixel from uniforms
        readonly property real _cosEl: Math.max(Math.hypot(root._sk.l.x, root._sk.l.y), 0.05)
        readonly property real _wx: Math.cos(root.windAngle)
        readonly property real _wy: Math.sin(root.windAngle)
        property vector4d geoA: Qt.vector4d(fx._wx, fx._wy, 1 / root.wavelength, 1 / root.rippleWavelength)
        property vector4d geoB: Qt.vector4d(root._sk.l.x / fx._cosEl, root._sk.l.y / fx._cosEl, root._sk.l.z / fx._cosEl,
                                            (root._sk.l.x * fx._wx + root._sk.l.y * fx._wy) / fx._cosEl / root.wavelength)
        property vector4d geoD: root._front
        property vector4d geoC: Qt.vector4d(1 / root.crestPos, 1 / (1 - root.crestPos), root.glints, 1 / Math.max(root.amplitude, 1))
    }
}
