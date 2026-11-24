pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "../glyphs"
import "WeatherGlyphParts.js" as Parts

// =============================================================================
// WeatherGlyph.qml
//
// A weather condition as a glyph, in one of TWO sets (WeatherGlyphSet.set, the weather config's temporary `glyphSet`):
//
//   "ink"     the drawn set, WeatherGlyphInk: solid Material-weight icons in `ink` with one accent part. No shader.
//   "carved"  the legacy set, described below: everything from "carved into the surface" on is about it, and the carve
//             knobs (`style`, bevelWidth ...), `renderScale` and `parts` mean nothing to the ink set.
//
// Both take the same condition (kind, intensity, night, shower, moonPhase, direction), `size` and `otherMode`, so a host
// names no set. The carved half goes when the user has approved the ink set.
//
// THE FLOURISH is the ink set's (WeatherInkPose.js): a host with a GlyphFlourish hands `posing` and `poseBeat` (its clock
// over its flourishMs) and runs it for `flourishBeats` beats -- 0 for the carved set, which has none.
//
// THE CARVED SET. A weather condition, carved into the surface. Every part of the glyph -- a
// sun's crown and its disc, a cloud, a drop, a flake, a bolt, a star -- is a
// shape pressed into the panel in ShadowBox's language: a light bevel rim
// OUTSIDE its edge, an inset shadow INSIDE it, a flat body. The body is the
// part's own colour from the references (a white cloud, a yellow disc
// on an orange crown, blue drops, an amber bolt; `Theme.weatherSunDisc` ..
// `weatherWindLine`), and the inset starts from that colour darkened by the
// theme's glyph shade (`Theme.weatherGlyphShade`, eased back toward the colour
// by `shadowTint`), so the carve reads as depth on a white cloud and on a
// yellow sun alike -- a deeper gold, not a grey smudge.
//
// One ShaderEffect per glyph, analytic distances, no textures, no layers
// (shaders/weather_glyph.frag). The composition -- which parts, where -- is
// WeatherGlyphParts.js, pure numbers; the shader resolves every colour from
// the theme, so a switch is a uniform update and nothing here is rebuilt.
//
// Draws NOTHING outside its parts: no ground, no plate. It sits over a card or
// over a moving backdrop alike, and the bevel is alpha-blended for the same
// reason.
//
// `size` is the glyph's square and its implicit size. `renderScale` is what a
// host MAGNIFIES the item by (a mockup stage's zoom); the shader measures its
// bands in device pixels from the screen-space derivative of its own (linear)
// coordinate, so the rim and the inset keep their device-pixel widths under
// any transform without being told, and a glyph is the same picture at every
// whole-pixel position. What renderScale decides is the composition: the device-pixel size
// below which the parts simplify (bigger and fewer drops, fewer crown points,
// one star, no flake branches) and the clamp on the inset's depth are both
// judged on size * renderScale, so a 24 px glyph on a 2.4x stage keeps the
// detail it can show there.
// =============================================================================
Item {
    id: root

    // ---- what to draw ------------------------------------------------------
    // Conditions: "clear" "partly" "cloudy" "fog" "rain" "sleet" "snow" "hail"
    // "thunder" (intensity 0..2, night, shower). Single parts: "sun" "moon"
    // "cloud" "drop" "flake" "bolt" "fogbank" "wind", and "arrow".
    property string kind: "clear"
    property int intensity: 1
    property bool night: false
    // A sun (or, at night, a crescent) peeking out behind a precipitating cloud.
    property bool shower: false
    // 0..1 cycle fraction (0.5 = full). Only the "moon" part draws the phase;
    // night condition glyphs draw the references' crescent whatever it is.
    property real moonPhase: 0.5
    // "arrow" only: meteorological degrees the wind blows FROM (0 = north).
    // The dart points where the air GOES, rotated direction + 180. null (or
    // not a finite number) draws a small carved dot: no direction is not a
    // direction.
    property var direction: null

    // ---- the flourish (header) ----------------------------------------------
    property bool posing: false
    property real poseBeat: 0
    readonly property real flourishBeats: setLoader.item && setLoader.item.flourishBeats !== undefined ? setLoader.item.flourishBeats : 0

    // ---- size --------------------------------------------------------------
    property real size: 48
    // The ink set's ink (the carved set has no ink): the bar's muted ink, of the other half under otherMode. A host on
    // its own clock (the bar button's hover) hands its own.
    property color ink: root._t(Theme.textMuted, "textMuted")
    property real renderScale: 1
    // Take every colour from the OTHER half of the theme: a glyph drawn on a
    // ground of the other mode (the weather hero's dark window or dark sky in
    // light mode) carves and colours itself as it would there.
    property bool otherMode: false
    function _t(c, token) {
        return root.otherMode ? (root._alt[token] || c) : c;
    }
    // The other half, HELD rather than bound: Theme.counterpart answers for the
    // new mode between a switch's ask and its commit while the tokens still
    // hold the old, and that is the frame the crossfade captures
    // (WeatherBackdrop._dark). Read when otherMode turns on and on every
    // `settled`; a glyph that never takes otherMode builds nothing.
    property var _alt: ({})
    function _refreshAlt() {
        if (!root.otherMode)
            return;
        const out = {};
        for (const k of ["textMuted", "bevel", "weatherGlyphShade", "panelSunk", "weatherSunDisc", "weatherSunCrown", "weatherMoon",
                         "weatherStar", "weatherCloudFront", "weatherCloudBack", "weatherDrop", "weatherFlake",
                         "weatherHail", "weatherBolt", "weatherFogBar", "weatherWindLine"])
            out[k] = Qt.color(Theme.counterpart(Theme[k].toString(), k));
        root._alt = out;
    }
    onOtherModeChanged: root._refreshAlt()
    Component.onCompleted: root._refreshAlt()
    Connections {
        target: Theme
        enabled: root.otherMode
        function onSettled() {
            root._refreshAlt();
        }
    }

    // ---- the carve (ShadowBox's language, plus the two tints) --------------
    // A host hands its whole carve in as ONE object (WeatherPopup.glyphStyle)
    // and a key it leaves out keeps the default written here, the one place the
    // defaults live. A knob assigned directly still wins over the style.
    property var style: ({})
    property real bevelWidth: root._styled("bevelWidth", 1.25)          // device px
    property real shadowWidth: root._styled("shadowWidth", 0.1)         // share of size, clamped to [1.5, 7] device px
    // The inset never reaches deeper than this share of a part's own inscribed
    // half-width, so a 2 px flake arm keeps its colour instead of being all
    // shadow, while a cloud carves the glyph's full depth.
    property real partShadowShare: root._styled("partShadowShare", 0.9)
    property real shadowTint: root._styled("shadowTint", 0)             // 0 = the colour times the shade, 1 = the colour (no inset)
    property real bodyTint: root._styled("bodyTint", 1)                 // 0 = Theme.panelSunk, 1 = the part's colour
    property real bevelAlpha: root._styled("bevelAlpha", 1)
    property real shadowEdgeAlpha: root._styled("shadowEdgeAlpha", 1.0)
    property real shadowFalloff: root._styled("shadowFalloff", 1.0)
    function _styled(key, fallback) {
        const s = root.style;
        return s && typeof s[key] === "number" ? s[key] : fallback;
    }

    // The composed part list, [type, cx, cy, s, p1, p2, p3, colour] each.
    // (The carved set's; the ink set composes its own, and none is composed for it here.)
    readonly property var parts: WeatherGlyphSet.carved ? Parts.compose(root.kind, root.intensity, root.night, root.shower,
                                                                         root.moonPhase, root.direction, root._devSize) : []

    // The ink set's accent: the part's weather colour by its token, of the other half under otherMode.
    function _accent(token) {
        switch (token) {
        case "weatherSunDisc":
            return root._t(Theme.weatherSunDisc, token);
        case "weatherMoon":
            return root._t(Theme.weatherMoon, token);
        case "weatherDrop":
            return root._t(Theme.weatherDrop, token);
        case "weatherFlake":
            return root._t(Theme.weatherFlake, token);
        case "weatherBolt":
            return root._t(Theme.weatherBolt, token);
        }
        return root.ink;
    }

    implicitWidth: root.size
    implicitHeight: root.size

    // ---- internal ----------------------------------------------------------
    readonly property real _scale: Math.max(root.renderScale, 0.01)
    readonly property real _devSize: root.size * root._scale
    readonly property real _shadowPx: Math.max(1.5, Math.min(7, root.shadowWidth * root._devSize))
    // Room outside the square for the rim (device px, so item px are that over
    // the scale) plus one pixel for its antialiasing.
    readonly property real _margin: Math.ceil(root.bevelWidth / root._scale) + 1

    function _pa(i) {
        const p = root.parts;
        return i < p.length ? Qt.vector4d(p[i][0], p[i][1], p[i][2], p[i][3]) : Qt.vector4d(0, 0, 0, 0);
    }
    function _pb(i) {
        const p = root.parts;
        return i < p.length ? Qt.vector4d(p[i][4], p[i][5], p[i][6], p[i][7]) : Qt.vector4d(0, 0, 0, 0);
    }

    Loader {
        id: setLoader
        anchors.fill: parent
        sourceComponent: WeatherGlyphSet.carved ? carvedSet : inkSet
    }
    Component {
        id: inkSet
        WeatherGlyphInk {
            id: inkGlyph
            kind: root.kind
            intensity: root.intensity
            night: root.night
            shower: root.shower
            moonPhase: root.moonPhase
            direction: root.direction
            size: root.size
            posing: root.posing
            poseBeat: root.poseBeat
            ink: root.ink
            accent: root._accent(inkGlyph.accentToken)
        }
    }
    Component {
        id: carvedSet
        Item {
    ShaderEffect {
        id: fx
        anchors.fill: parent
        anchors.margins: -root._margin
        fragmentShader: "shaders/weather_glyph.frag.qsb"

        property real size: root.size
        property real margin: root._margin
        property real partCount: root.parts.length

        property real bevelWidth: root.bevelWidth
        property real shadowWidth: root._shadowPx
        property real partShadowShare: root.partShadowShare
        property real bevelAlpha: root.bevelAlpha
        property real edgeAlpha: root.shadowEdgeAlpha
        property real falloff: Math.max(0.01, root.shadowFalloff)
        property real shadowTint: root.shadowTint
        property real bodyTint: root.bodyTint

        property color bevelColor: root._t(Theme.bevel, "bevel")
        property color shade: root._t(Theme.weatherGlyphShade, "weatherGlyphShade")
        property color panelSunk: root._t(Theme.panelSunk, "panelSunk")
        // In WeatherGlyphParts.js's colour order.
        property color col0: root._t(Theme.weatherSunDisc, "weatherSunDisc")
        property color col1: root._t(Theme.weatherSunCrown, "weatherSunCrown")
        property color col2: root._t(Theme.weatherMoon, "weatherMoon")
        property color col3: root._t(Theme.weatherStar, "weatherStar")
        property color col4: root._t(Theme.weatherCloudFront, "weatherCloudFront")
        property color col5: root._t(Theme.weatherCloudBack, "weatherCloudBack")
        property color col6: root._t(Theme.weatherDrop, "weatherDrop")
        property color col7: root._t(Theme.weatherFlake, "weatherFlake")
        property color col8: root._t(Theme.weatherHail, "weatherHail")
        property color col9: root._t(Theme.weatherBolt, "weatherBolt")
        property color col10: root._t(Theme.weatherFogBar, "weatherFogBar")
        property color col11: root._t(Theme.weatherWindLine, "weatherWindLine")
        // ShadowBox's easings.
        property vector4d bevelEasing: Qt.vector4d(0.15, 0.1, 0.25, 1.0)
        property vector4d shadowEasing: Qt.vector4d(0.15, 0.60, 0.35, 1.0)

        property vector4d pa0: root._pa(0)
        property vector4d pa1: root._pa(1)
        property vector4d pa2: root._pa(2)
        property vector4d pa3: root._pa(3)
        property vector4d pa4: root._pa(4)
        property vector4d pa5: root._pa(5)
        property vector4d pa6: root._pa(6)
        property vector4d pa7: root._pa(7)
        property vector4d pb0: root._pb(0)
        property vector4d pb1: root._pb(1)
        property vector4d pb2: root._pb(2)
        property vector4d pb3: root._pb(3)
        property vector4d pb4: root._pb(4)
        property vector4d pb5: root._pb(5)
        property vector4d pb6: root._pb(6)
        property vector4d pb7: root._pb(7)
    }
        }
    }
}
