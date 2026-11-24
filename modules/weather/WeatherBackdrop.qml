pragma ComponentBehavior: Bound

import QtQuick
import "../common/theme"
import "../common/particles"

// =============================================================================
// WeatherBackdrop.qml -- the hero card's always-moving background.
//
// One ShaderEffect fills the card -- to its true edge, under the card's
// carve (WeatherHero stacks the two) -- and draws the condition. Everything
// in the shader is a function of (pixel, time), so a frame costs one uniform
// write and a quad.
//
// TWO STYLES. `style` "v2" (default) is shaders/weather_backdrop_v2
// .frag: ONE scene whose stages -- sky tint, sun glare and shafts, moon,
// stars and the milky way, cumulus rows or an overcast sheet in perspective,
// rain curtains, fog banks, falling particles in depth layers, drops on the
// glass, air on its streamlines, sheet lightning and the strike -- are mixed
// per kind by a RECIPE computed here (`_recipe`: a few vec4s of amounts, and
// the layer counts the shader loops over). The design note, the references
// and each stage's reasoning are in that file's header. "v1" is
// shaders/weather_backdrop.frag, one flat field per kind, kept selectable for
// comparison until the bar is deployed.
//
//     WeatherBackdrop {
//         anchors.fill: card
//         kind: "rain"; intensity: 1; night: false
//         windKmh: 12; windDir: 280        // slants the streaks (a right-blowing wind slants right)
//         running: visible && popupOpen    // the host's gate; Theme.crossfading is honoured here
//         ambientHz: 30                    // the Timer's rate
//         strength: 1.0                    // scales every alpha
//         cornerRadius: 14                 // optional: round the effect's own corners
//     }
//
// THE CLOCK. `running` gates a Timer at `ambientHz`; each tick writes `time`
// (seconds, wrapped every 3600 s so the float stays precise) and the effect
// asks for exactly one frame. Not a FrameAnimation: that takes every frame
// the display can present. The Timer only runs while running && visible &&
// sized && strength > 0 && !Theme.crossfading -- a theme crossfade is a still
// picture of the frame before, and anything that keeps moving under it draws
// twice. At rest or off nothing here asks for a frame (0 frames/s).
//
// THUNDER. A second Timer fires at random 8-25 s intervals, reseeds the bolt
// and runs a short flicker on `flash` -- ONE eased fraction; the shader lifts
// the card by it and draws the bolt at that opacity (v2 also lights the cloud
// around the bolt's root, and flickers sheet lightning inside the deck on its
// own, statelessly, between strikes). The flicker is the only thing here that
// animates on Qt's clock, ~600 ms per strike.
//
// CONTRAST. Every hue reaches the shader as vec4(rgb, gain) with gain =
// 0.24 / |luma(hue) - luma(groundColor)| clamped to [0.15, 1]: the same
// alpha reads the same against a light card and a dark one (and a sky the
// backdrop paints itself). v2 then holds its scene under a tone limiter
// (`toneKnee`, `toneCap`) and lays its point lights -- star cores, glints --
// over it under `sparkCap`.
//
// LIGHT MODE IS A SKY: v2 paints the kind's sky as
// its ground and draws on it; see the section below. `groundColor` and
// `darkGround` tell the host what its text is read against.
// The contrast bounds: the 5x5 mean (the area bound)
// of the luminance change <= 0.12 (what the figures are read against), the
// raw peak (the point bound) <= 0.25 (a point). Theme tokens only; nothing here is a literal.
//
// PRECIPITATION RENDERER A/B. `precipRenderer` is "shader" (default) or
// "canvas": the canvas path drops the shader's streaks and drives the shell's
// CPU ParticleSystem instead -- one emitter Timer at ambientHz, particles
// updated and painted by the system's own 16 ms Timer + Canvas. Measured
// (420x200 card, offscreen+rhi, basic loop, Arc MTL):
//
//     rain  shader   0.70 % of a thread   30.4 frames/s   1.85 GPU ms/s
//     rain  canvas   6.50 %              126.0 frames/s   8.36 GPU ms/s
//     snow  shader   0.80 %               30.4 frames/s   1.83 GPU ms/s
//     snow  canvas   8.60 %              125.7 frames/s   8.45 GPU ms/s
//
// The shader wins by ~9x CPU and ~4.5x GPU: a stateless field costs one
// uniform write per tick whatever the intensity, while the particle system
// simulates every drop in JS and rasterises the canvas on every one of its
// own 16 ms ticks (which the basic loop then presents at ~126 frames/s). The
// canvas stays as the fallback for a machine with no usable GPU --
// the software scenegraph draws a ShaderEffect as nothing at all.
// =============================================================================
Item {
    id: root

    // ---- The contract (CONTRACTS.md section 4) ----------------------------
    property string kind: "clear"
    property int intensity: 1
    property bool night: false
    property real windKmh: 0
    property real windDir: 0
    property bool running: true
    property real ambientHz: 30
    property real strength: 1.0
    readonly property bool ticking: tick.running
    readonly property int tickCount: root._ticks

    // ---- Beyond it --------------------------------------------------------
    // Rounds the effect's own corners, feathered inward over one device
    // pixel (a host that clips its content leaves this at 0). WeatherHero
    // grows the effect past its card's edge and rounds it at radius + bleed.
    property real cornerRadius: 0
    // "shader" | "canvas" -- see the header.
    property string precipRenderer: "shader"
    // "v2" (default) | "v1": which scene draws the kind -- see the header.
    property string style: "v2"
    // v2's tone limiter: the luminance change against the card passes as it
    // is up to `toneKnee` and is eased into `toneCap` above it, so no recipe
    // can stack enough ink to fight the figures (the area bound is
    // 0.12; the cap sits a hair under it).
    property real toneKnee: 0.07
    property real toneCap: 0.11
    // v2's point lights (star cores, glints, a flake's heart on the dark
    // card) are laid over the limited scene under their own, higher ceiling:
    // held to the area bound a star is a grey dot (the point bound is
    // 0.25).
    property real sparkCap: 0.24

    // ---- Light mode is a sky -------------------------------------
    // On the light card white can brighten by .08, and what the dark card
    // draws as light -- the pollen, most stars, the strike -- would be lost. So in
    // light mode v2 paints the kind's SKY as its ground, opaque, to its own
    // rounded rect (`cornerRadius`), and draws the scene on it: a tint well
    // under the surface by day (soft blue, grey-blue, pale mist), dusk indigo
    // at night and slate in a storm. On a dark sky the scene is drawn from
    // the theme's dark half, exactly as on the dark card; on a light one the
    // dark card's point lights come in, since white has room there. Dark
    // mode and v1 draw no ground.
    //
    // The ground the text is read against: the sky, or the listBox v2 draws
    // over in dark mode (and whenever it paints nothing).
    readonly property color groundColor: root._sky ? root._skyGround : Theme.listBox
    // True when that ground is dark enough that the hero's text, figures and
    // glyph carve must take the DARK palette: a night or storm sky. Never in
    // dark mode: the text is the dark palette there already.
    readonly property bool darkGround: root._sky && root._luma(root._skyGround) < 0.5

    readonly property bool _themeDark: root._luma(Theme.listBox) < 0.5
    readonly property bool _drawn: root.visible && root.strength > 0 && root.width > 0 && root.height > 0
    // The sky is painted: light mode, v2, and only while the effect draws at
    // all (hidden, unsized, strength 0 -- a ground not painted is not the
    // ground).
    readonly property bool _sky: !root._themeDark && root.style !== "v1" && root._drawn
    // The scene is drawn in the theme's dark half: in dark mode, and on a
    // night or storm sky in light mode.
    readonly property bool _darkScene: root._themeDark || root.darkGround

    // THE DARK HALF, copied when the palette settles. Theme.counterpart is
    // only right while the tokens and its map agree: between a switch's ask
    // and its commit the map already answers for the NEW mode while the
    // tokens still hold the old, and that is exactly the frame the crossfade
    // captures -- a bound counterpart would paint a night sky from the light
    // half in it. So the dark values are read at creation and on every
    // `settled` (the commit, a live token edit, a theme file load), and held
    // in between.
    property var _dark: root._darkNow()
    function _darkNow() {
        const inDark = Theme.mode === "dark";
        const alt = function (c, key) {
            return inDark ? c : Qt.color(Theme.counterpart(c.toString(), key));
        };
        return {
            listBox: alt(Theme.listBox, "listBox"),
            shadowDeep: alt(Theme.shadowDeep, "shadowDeep"),
            weatherSunDisc: alt(Theme.weatherSunDisc, "weatherSunDisc"),
            weatherSun: alt(Theme.weatherSun, "weatherSun"),
            weatherCloudFront: alt(Theme.weatherCloudFront, "weatherCloudFront"),
            weatherCloud: alt(Theme.weatherCloud, "weatherCloud"),
            weatherCloudBack: alt(Theme.weatherCloudBack, "weatherCloudBack"),
            weatherRain: alt(Theme.weatherRain, "weatherRain"),
            weatherSnow: alt(Theme.weatherSnow, "weatherSnow"),
            weatherHail: alt(Theme.weatherHail, "weatherHail"),
            weatherFog: alt(Theme.weatherFog, "weatherFog"),
            weatherNight: alt(Theme.weatherNight, "weatherNight"),
            weatherStar: alt(Theme.weatherStar, "weatherStar"),
            weatherWindLine: alt(Theme.weatherWindLine, "weatherWindLine")
        };
    }
    Connections {
        target: Theme
        function onSettled() {
            root._dark = root._darkNow();
        }
    }
    Component.onCompleted: root._dark = root._darkNow()    // held from here on, not bound
    // A token in the palette the scene is drawn in. `c` is the Theme read
    // (the binding's dependency), `key` its name in the dark half.
    function _pal(c, key) {
        return root._darkScene && !root._themeDark ? root._dark[key] : c;
    }

    // The sky per kind: day kinds a tint well under the
    // light card (blue, grey-blue, pale mist), night kinds and the storm a
    // tint of the dark card (dusk indigo, slate). The day grounds stay at
    // luma .75-.83 and the dark ones at .24-.28: between the two neither
    // half of the palette's text keeps its contrast (textPrimary 3.4-4.4:1
    // on the day grounds, the dark half's 4.5-5.3:1 on the night ones,
    // against 5.4 and 6.9 on the cards).
    readonly property color _skyGround: {
        const lb = Theme.listBox, dk = root._dark.listBox;
        const mix = function (a, b, f) {
            return Qt.rgba(a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f, 1);
        };
        if (root.kind === "thunder")
            return mix(dk, Theme.weatherCloud, 0.3);
        if (root.night) {
            switch (root.kind) {
            case "clear": case "partly": return mix(dk, Theme.weatherNight, 0.18);
            case "fog": return mix(dk, Theme.weatherFog, 0.24);
            default: return mix(dk, Theme.weatherCloud, 0.22);
            }
        }
        switch (root.kind) {
        case "clear": return mix(lb, Theme.weatherRain, 0.2);
        case "partly": return mix(mix(lb, Theme.weatherRain, 0.16), Theme.weatherCloud, 0.12);
        case "cloudy": return mix(lb, Theme.weatherCloud, 0.34);
        case "fog": return mix(lb, Theme.weatherFog, 0.3);
        case "snow": case "sleet": return mix(mix(lb, Theme.weatherCloudBack, 0.5), Theme.weatherSnow, 0.06);
        case "wind": return mix(mix(lb, Theme.weatherRain, 0.1), Theme.weatherCloud, 0.25);
        default: return mix(mix(lb, Theme.weatherCloud, 0.4), Theme.weatherRain, 0.03);   // rain, hail
        }
    }

    // The shader's clock, seconds. Written by the Timer while ticking; a
    // harness pins it (with running false) for a deterministic frame.
    property real time: 0
    // The lightning's fraction, 0..1. Driven by the flicker while ticking; a
    // harness pins it the same way.
    property real flash: 0

    property int _ticks: 0
    property real _flashSeed: 0.5

    readonly property int _mode: {
        switch (root.kind) {
        case "partly": return 1;
        case "cloudy": return 2;
        case "fog": return 3;
        case "rain": return 4;
        case "sleet": return 5;
        case "snow": return 6;
        case "hail": return 7;
        case "thunder": return 8;
        case "wind": return 9;
        default: return 0;
        }
    }
    readonly property bool _isPrecip: root._mode >= 4 && root._mode <= 8
    // Meteorological `windDir` is where the wind comes FROM; the card's x axis
    // points east, so the wind's push along it is -sin(dir): +1 blows right.
    readonly property real _blowX: -Math.sin(root.windDir * Math.PI / 180)
    // dx per px of fall. 30 km/h slants rain ~25 degrees; snow, being light,
    // about twice that.
    readonly property real _rainSlant: root._blowX * root.windKmh * 0.016
    readonly property real _snowSlant: root._blowX * root.windKmh * 0.03
    // The air streaks' speed, px/s, signed. A wind from due north or south
    // has no x to blow along; it blows right by convention rather than
    // standing still.
    readonly property real _windPx: (Math.abs(root._blowX) < 0.3 ? 1 : (root._blowX < 0 ? -1 : 1))
                                    * (50 + root.windKmh * 4)

    function _luma(c) {
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    }
    // Against the ground the scene is drawn on (the listBox, or the ground
    // a light treatment paints).
    function _gain(c) {
        const d = Math.abs(root._luma(c) - root._luma(root.groundColor));
        return Math.max(0.15, Math.min(1.0, 0.24 / Math.max(0.06, d)));
    }
    function _hue(c) {
        return Qt.vector4d(c.r, c.g, c.b, root._gain(c));
    }
    // v1's bolt: whichever of the storm hue and white stands out more against
    // the card (the storm's purple on a light card, white on a dark one).
    function _boltHue() {
        const base = root._luma(Theme.listBox);
        const storm = Theme.weatherStorm;
        const pale = Qt.rgba(1, 1, 1, 1);
        const c = Math.abs(root._luma(storm) - base) > Math.abs(1 - base) ? storm : pale;
        return Qt.vector4d(c.r, c.g, c.b, 1);
    }
    // THE NEUTRAL STORM: a slate deck and a white bolt with a
    // blue-white glow in both themes; the storm's violet stays in the glyph.
    // The slate is the cloud's own blue-grey.
    readonly property color _slate: root._pal(Theme.weatherCloud, "weatherCloud")
    // The bolt's glow, blue-white, at full gain (the strike is exempt from
    // the contrast bound: the flash is meant to lift the card); the shader
    // draws its core white.
    readonly property vector4d _boltGlow: {
        const b = root._pal(Theme.weatherRain, "weatherRain");
        return Qt.vector4d(1 - 0.25 * (1 - b.r), 1 - 0.25 * (1 - b.g), 1 - 0.25 * (1 - b.b), 1);
    }

    ShaderEffect {
        id: fx
        anchors.fill: parent
        visible: root.style === "v1" && root.strength > 0 && root.width > 0 && root.height > 0
        blending: true
        fragmentShader: "shaders/weather_backdrop.frag.qsb"

        property vector4d cSun: root._hue(Theme.weatherSun)
        property vector4d cCloud: root._hue(Theme.weatherCloud)
        property vector4d cRain: root._hue(Theme.weatherRain)
        property vector4d cSnow: root._hue(Theme.weatherSnow)
        property vector4d cStorm: root._hue(Theme.weatherStorm)
        property vector4d cFog: root._hue(Theme.weatherFog)
        property vector4d cNight: root._hue(Theme.weatherNight)
        property vector4d cFlash: root._hue(Qt.rgba(1, 1, 1, 1))
        property vector4d cBolt: root._boltHue()
        property vector2d size: Qt.vector2d(root.width, root.height)
        property vector2d slant: Qt.vector2d(root._rainSlant, root._snowSlant)
        property real mode: root._mode
        property real time: root.time
        property real intensity: Math.max(0, Math.min(2, root.intensity))
        property real strength: root.strength
        property real night: root.night ? 1 : 0
        property real flash: root.flash
        property real flashSeed: root._flashSeed
        property real precipOn: root.precipRenderer === "canvas" ? 0 : 1
        property real windSpeed: root._windPx
        property real cornerRadius: root.cornerRadius
    }

    // ---- v2: one scene, the kind's recipe --------------------------------------
    ShaderEffect {
        id: fx2
        anchors.fill: parent
        visible: root.style !== "v1" && root.strength > 0 && root.width > 0 && root.height > 0
        blending: true
        fragmentShader: "shaders/weather_backdrop_v2.frag.qsb"

        property vector4d cSun: root._hue(root._pal(Theme.weatherSunDisc, "weatherSunDisc"))
        property vector4d cGlow: root._hue(root._pal(Theme.weatherSun, "weatherSun"))
        property vector4d cLight: root._hue(root._pal(Theme.weatherCloudFront, "weatherCloudFront"))
        property vector4d cCloud: root._hue(root._pal(Theme.weatherCloud, "weatherCloud"))
        property vector4d cShade: root._hue(root._pal(Theme.weatherCloudBack, "weatherCloudBack"))
        property vector4d cRain: root._hue(root._pal(Theme.weatherRain, "weatherRain"))
        property vector4d cSnow: root._hue(root._pal(Theme.weatherSnow, "weatherSnow"))
        property vector4d cHail: root._hue(root._pal(Theme.weatherHail, "weatherHail"))
        property vector4d cStorm: root._hue(root._slate)
        property vector4d cFog: root._hue(root._pal(Theme.weatherFog, "weatherFog"))
        property vector4d cNight: root._hue(root._pal(Theme.weatherNight, "weatherNight"))
        property vector4d cStar: root._hue(root._pal(Theme.weatherStar, "weatherStar"))
        property vector4d cBolt: root._boltGlow
        property vector4d cDeep: root._hue(root._pal(Theme.shadowDeep, "shadowDeep"))
        property vector4d cCard: root._hue(root.groundColor)
        property vector4d cWind: root._hue(root._pal(Theme.weatherWindLine, "weatherWindLine"))
        // The sky, painted under the scene in light mode.
        property vector4d ground: {
            const g = root._skyGround;
            return Qt.vector4d(g.r, g.g, g.b, root._sky ? 1 : 0);
        }
        // A light sky: the dark card's point lights are drawn on it.
        property real lightRoom: root._sky && !root.darkGround ? 1 : 0
        property vector4d sky: root._recipe.sky
        property vector4d deck: root._recipe.deck
        property vector4d deck2: root._recipe.deck2
        property vector4d precip: root._recipe.precip
        property vector4d extra: root._recipe.extra
        property vector4d extra2: root._recipe.extra2
        property vector4d deck3: root._recipe.deck3
        property vector4d loops: root._recipe.loops
        property vector4d loops2: root._recipe.loops2
        // fbm octaves: cloud shape, a sheet's light sample, milky way and
        // fog. Uniforms and not constants so each fbm stays a loop (one copy
        // of its noise) instead of being unrolled once per octave.
        property vector4d octaves: Qt.vector4d(4, 2, 3, 0)
        property vector2d size: Qt.vector2d(root.width, root.height)
        property vector2d slant: Qt.vector2d(root._rainSlant, root._snowSlant)
        property real time: root.time
        property real strength: root.strength
        property real flash: root.flash
        property real flashSeed: root._flashSeed
        property real precipOn: root.precipRenderer === "canvas" ? 0 : 1
        property real windSpeed: root._windPx
        property real cornerRadius: root.cornerRadius
        property real dark: root._darkScene ? 1 : 0
        property real toneKnee: root.toneKnee
        property real toneCap: root.toneCap
        property real sparkCap: root.sparkCap
    }

    // The v2 recipe: how much of each stage the kind draws (the shader's
    // uniform block names each field). k is the intensity 0..2; `drift` is
    // the clouds' px/s, signed with the wind.
    readonly property var _recipe: {
        const k = Math.max(0, Math.min(2, root.intensity));
        const n = root.night;
        const drift = (root._windPx < 0 ? -1 : 1) * (3 + root.windKmh * 0.12);
        const v = Qt.vector4d;
        const r = {
            sky: v(0, 0, 0, 0), deck: v(0, 0, 0, 0), deck2: v(0, 110, drift, 0),
            precip: v(0, 0, 0, 0), extra: v(0, 0, 0, 0), extra2: v(0, 0, 0, 0), deck3: v(0, 0, 0, 0)
        };
        switch (root.kind) {
        case "clear":
            r.sky = n ? v(0, 1, 1, 1) : v(1, 0, 0, 0);
            r.extra2 = n ? v(0, 0, 0, 0) : v(0, 0, 1, 0);
            break;
        case "partly":
            r.sky = n ? v(0, 0.8, 0.7, 0) : v(0.8, 0, 0, 0);
            r.deck = v(0.56, n ? 0.2 : 0, 0, 0.02);
            r.deck2 = v(1, 110, drift, 0);
            r.deck3 = v(2, 0, 0, 0);
            break;
        case "cloudy":
            r.deck = v(0.8, n ? 0.5 : 0.3, 0, 0.02);
            r.deck2 = v(1, 110, drift, 0.10);
            r.deck3 = v(0, 0.45, 0, 0);
            break;
        case "fog":
            r.deck2 = v(0, 110, drift, 0.04);
            r.extra = v(0, 1, 0, 0);
            break;
        case "rain":
            r.deck = v(0.85, 0.5 + 0.15 * k, 0.42, 0.03);
            r.deck2 = v(1, 110, drift, 0.08);
            r.precip = v(k === 0 ? 0.45 : (k === 1 ? 0.75 : 1.0), 0, 0, 0);
            r.extra = v(0.5 + 0.25 * k, 0, 0, 0);
            r.extra2 = v(0.5 * k, 0.6 + 0.2 * k, 0, 0);
            r.deck3 = v(0, 0.45, 0, 0);
            break;
        case "sleet":
            r.deck = v(0.85, 0.45, 0.42, 0.03);
            r.deck2 = v(1, 110, drift, 0.08);
            r.precip = v(0.5, 0, 0, 0.7 + 0.15 * k);
            r.extra = v(0.6, 0, 0, 0);
            r.extra2 = v(0.2, 0.5, 0, 0);
            r.deck3 = v(0, 0.45, 0, 0);
            break;
        case "snow":
            r.deck = v(0.8, 0.15, 0.36, 0.02);
            r.deck2 = v(1, 120, drift, 0.06);
            r.precip = v(0, 0.5 + 0.35 * k, 0, 0);
            r.extra2 = v(0.25 * k, 0, 0, 0);
            r.deck3 = v(0, 0.45, 0, 0);
            break;
        case "hail":
            r.deck = v(0.9, 0.65, 0.45, 0.04);
            r.deck2 = v(1, 110, drift, 0.10);
            r.precip = v(0.3, 0, 0.7 + 0.15 * k, 0);
            r.extra2 = v(0, 0.6, 0, 0);
            r.deck3 = v(0, 0.45, 0, 0);
            break;
        case "thunder":
            r.deck = v(0.95, 0.95, 0.58, 0.06);
            r.deck2 = v(1, 120, drift, 0.07);
            r.precip = v(0.85 + 0.1 * k, 0, 0, 0);
            r.extra = v(0.7, 0, 0, 1);
            r.extra2 = v(0.4, 1, 0, 0);
            r.deck3 = v(0, 0.45, 0, 0);
            break;
        case "wind":
            r.deck = v(0.4, 0.1, 0, 0.05);
            r.deck2 = v(0.8, 90, drift * 4, 0);
            r.deck3 = v(2, 0, 0, 0);
            r.extra = v(0, 0, 1, 0);
            break;
        }
        // The layer counts the shader loops over (uniform bounds keep one
        // copy of each loop body): cloud layers, star layers, the particle
        // layers [first, end) -- 0-1 motes, 2-4 rain, 5-8 snow, 9-10 hail --
        // fog banks, air layers, bolt channels.
        const snowy = r.precip.y > 0 || r.precip.w > 0;
        const pFirst = r.extra2.z > 0 ? 0 : (r.precip.x > 0 ? 2 : (snowy ? 5 : 9));
        const pEnd = r.precip.z > 0 ? 11 : (snowy ? 9 : (r.precip.x > 0 ? 5 : (r.extra2.z > 0 ? 2 : 0)));
        r.loops = v(r.deck.x > 0 ? (r.deck2.x > 0 ? 2 : 1) : 0, r.sky.z > 0 ? 3 : 0, pFirst, Math.max(pFirst, pEnd));
        r.loops2 = v(r.extra.y > 0 ? 3 : 0, r.extra.z > 0 ? 2 : 0, r.extra.w > 0 ? 2 : 0, 0);
        return r;
    }

    Timer {
        id: tick
        interval: Math.max(8, Math.round(1000 / Math.max(1, root.ambientHz)))
        repeat: true
        running: root.running && root.visible && root.width > 0 && root.height > 0
                 && root.strength > 0 && !Theme.crossfading
        onTriggered: {
            root.time = (Date.now() % 3600000) / 1000;
            root._ticks++;
        }
        onRunningChanged: {
            if (!tick.running && flicker.running) {
                flicker.stop();
                root.flash = 0;
            }
        }
    }

    // ---- Lightning ---------------------------------------------------------
    Timer {
        id: strike
        running: tick.running && root.kind === "thunder"
        interval: 8000
        repeat: true
        onRunningChanged: if (strike.running) strike.interval = strike._next()
        onTriggered: {
            root._flashSeed = Math.random();
            strike.interval = strike._next();
            flicker.restart();
        }
        function _next() {
            return 8000 + Math.round(Math.random() * 17000);
        }
    }
    SequentialAnimation {
        id: flicker
        NumberAnimation { target: root; property: "flash"; to: 1.0; duration: 50; easing.type: Easing.OutQuad }
        NumberAnimation { target: root; property: "flash"; to: 0.2; duration: 90 }
        NumberAnimation { target: root; property: "flash"; to: 0.75; duration: 50 }
        NumberAnimation { target: root; property: "flash"; to: 0.0; duration: 420; easing.type: Easing.InQuad }
    }

    // ---- The canvas precipitation (the A/B's other arm) ---------------------
    // A canvas has no rounded mask, so it keeps inside the square the rounded
    // corners leave whole: inset r(1 - 1/sqrt 2) on every side.
    Loader {
        id: canvasPrecip
        readonly property real inset: root.cornerRadius * (1 - Math.SQRT1_2)
        x: canvasPrecip.inset
        y: canvasPrecip.inset
        width: Math.max(0, root.width - 2 * canvasPrecip.inset)
        height: Math.max(0, root.height - 2 * canvasPrecip.inset)
        active: root.precipRenderer === "canvas" && root._isPrecip
        sourceComponent: Component {
            Item {
                id: cp
                readonly property bool rainy: root.kind === "rain" || root.kind === "sleet" || root.kind === "thunder"
                readonly property bool snowy: root.kind === "snow" || root.kind === "sleet"
                readonly property real thin: root.kind === "sleet" ? 0.55 : 1
                readonly property real k: root.kind === "thunder" ? Math.max(1, root.intensity) : root.intensity
                property real _carryRain: 0
                property real _carrySnow: 0

                function _colour(c, a) {
                    return Qt.rgba(c.r, c.g, c.b, a * root._gain(c) * root.strength).toString();
                }

                ParticleSystem {
                    id: ps
                    anchors.fill: parent
                    maxParticles: 600
                    running: tick.running
                }

                Timer {
                    interval: tick.interval
                    repeat: true
                    running: tick.running
                    onTriggered: {
                        const dt = interval / 1000;
                        const w = cp.width, h = cp.height;
                        if (cp.rainy) {
                            cp._carryRain += (40 + 60 * cp.k) * cp.thin * dt;
                            const n = Math.floor(cp._carryRain);
                            cp._carryRain -= n;
                            const slack = Math.abs(root._rainSlant) * (h + 16);
                            const colour = cp._colour(root._pal(Theme.weatherRain, "weatherRain"), 0.40);
                            for (let i = 0; i < n; i++) {
                                const vy = (240 + 70 * cp.k) * (0.8 + 0.4 * Math.random());
                                ps.emit({
                                    x: -slack + Math.random() * (w + 2 * slack), y: -6,
                                    vx: vy * root._rainSlant, vy: vy,
                                    lifetime: (h + 16) / vy * 1000,
                                    maxHistory: 4, sizeStart: 1, sizeEnd: 1,
                                    colorStart: colour, colorEnd: colour
                                }, 1);
                            }
                        }
                        if (cp.snowy) {
                            cp._carrySnow += (25 + 15 * cp.k) * cp.thin * dt;
                            const n = Math.floor(cp._carrySnow);
                            cp._carrySnow -= n;
                            const slack = Math.abs(root._snowSlant) * (h + 16);
                            const colour = cp._colour(root._pal(Theme.weatherSnow, "weatherSnow"), 0.42);
                            for (let i = 0; i < n; i++) {
                                const vy = (20 + 9 * cp.k) * (0.7 + 0.6 * Math.random());
                                const s = 1.6 + Math.random() * 1.6;
                                ps.emit({
                                    x: -slack + Math.random() * (w + 2 * slack), y: -4,
                                    vx: vy * root._snowSlant, vy: vy,
                                    lifetime: (h + 12) / vy * 1000,
                                    maxHistory: 1, sizeStart: s, sizeEnd: s,
                                    colorStart: colour, colorEnd: colour
                                }, 1);
                            }
                        }
                    }
                }
            }
        }
    }
}
