pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "NetGlyphParts.js" as Parts

// =============================================================================
// NetGlyph.qml
//
// A network function, drawn as the UNIVERSAL SYMBOL FOR IT BUILT AS A PHYSICAL
// OBJECT: a port, a fan of solid arcs, a padlock whose shackle is a cable,
// rings pushed out of a core, a domed button, the bluetooth rune machined into
// a badge, or the ghost of a socket a bay has no hardware for. Every part's
// body is its own MATERIAL from the theme's `net*` tokens.
//
// The wired port is the one real component drawn as itself, because a port
// already IS the sign for a wired network rather than a picture of one.
// NetGlyphParts.js says what each is and why.
//
// THESE ICONS ARE NOT CARVED. The rest of the shell is cut INTO its surface
// (ShadowBox: a light bevel outside an edge, an inset shadow inside it),
// but an inset inside every contact, every arc and every lens comes out
// muddy. A socket is LIFTED: it stands
// ON the plate, one light for the whole set, each part throwing a soft contact
// shadow on whatever is behind it, a bright rim only where an edge faces the
// light, a gentle shade where it faces away. `preset` picks the treatment and
// "carved" is kept only so a sheet can show the two side by side.
//
// One ShaderEffect per socket, analytic distances, no textures, no layers
// (shaders/net_glyph.frag). The composition -- which parts, where -- is
// NetGlyphParts.js, pure numbers; the shader resolves every colour from the
// theme, so a switch is a uniform update and nothing here is rebuilt.
//
// Draws NOTHING outside its parts but the shadow they throw: no ground, no
// plate. It sits on the faceplate's own carved card.
//
// A LIT LAMP IS ITS OWN INSTANCE. `kind: "lamp"` is one disc, placed over a
// socket's dead lens by the plate (`Parts.lampsOf(kind)` says where). It is
// separate because a part drawn over it would shade it, and because
// an activity lamp blinks: a uniform changing several times a second would
// repaint every pixel the socket covers instead of the eight the lamp does
// (CLAUDE.md, the weather backdrop's lesson).
//
// `size` is the socket's square and its implicit size. `renderScale` is what a
// host MAGNIFIES the item by (a mockup stage's zoom); the shader measures its
// edges by OFFSET SILHOUETTE in unit-square units -- it asks the shape whether
// a point a fixed distance toward the light is still inside it -- so a socket
// is the same picture at every whole-pixel position. What renderScale
// decides is the composition: the device-pixel size below which a jack's comb
// halves its contacts is judged on size * renderScale.
// =============================================================================
Item {
    id: root

    // ---- what to draw ------------------------------------------------------
    // "wired" "wifi" "vpn" "hotspot" "master" "bt" "blank" "lamp"
    property string kind: "wired"

    // "wifi": how far up the meter it reads. The dot is 1 and each arc one
    // more, so 0 is a dead fan and 4 is full.
    property int level: 0
    // "wifi": "on" | "off" (the fan unlit, a bar struck across it) | "blocked"
    // (that bar in the warning colour: the hardware switch). Not `state` -- QQuickItem owns that name.
    property string radio: "on"
    // "vpn": 1 shut, 0 open. Ease it and the cable really lifts out of the
    // lock, so arming is one number and not a second picture.
    property real shut: 0
    // "vpn": whether there is any profile to turn at all.
    property bool present: true
    // "hotspot"/"bt": whether it is lit. "master": whether the button is
    // pressed in.
    property bool on: false
    property bool down: false
    // "blank": the socket this empty bay stands in for, drawn as its ghost.
    property string ghost: "wired"
    // Which colour slot the lit parts take: `lampColor` (10) or
    // `lampAltColor` (11).
    property int colourSlot: 10

    // ---- size --------------------------------------------------------------
    property real size: 44
    property real renderScale: 1

    // ---- how it is shaded --------------------------------------------------
    // `preset` picks a coherent set of numbers; `style` overrides any of them
    // by key; a knob assigned directly still wins over both. The three lifted
    // presets are the same object under different lights -- they are meant to
    // be compared on one sheet, not mixed within a plate.
    //
    //   "carved"  ShadowBox's language, what the rest of the shell is made of.
    //             Kept for comparison only: a socket is a stack of small
    //             parts, and an inset inside every contact, arc and lens came
    //             out muddy.
    //   "lifted"  the object stands on the plate: a soft contact shadow, a
    //             gentle lit edge, a body that brightens toward the light.
    //   "crisp"   the same, harder: a tighter shadow, a bright rim, a
    //             specular band and a thin contour.
    //   "flat"    material and one soft shadow, nothing else.
    property string preset: "lifted"

    // A host hands its whole treatment in as ONE object and a key it leaves
    // out keeps the preset's value. A knob assigned directly still wins.
    property var style: ({})
    // ---- the carved model's own knobs (preset "carved" only) --------------
    property real bevelWidth: root._styled("bevelWidth", 1.25)          // device px
    property real shadowWidth: root._styled("shadowWidth", 0.11)        // share of size, clamped to [1.5, 7] device px
    // The inset never reaches deeper than this share of a part's own inscribed
    // half-width, so a 1.6 px contact keeps its gold instead of being all
    // shadow, while a metal face carves the full depth.
    property real partShadowShare: root._styled("partShadowShare", 0.9)
    property real shadowTint: root._styled("shadowTint", 0)             // 0 = the colour times the shade, 1 = the colour
    property real bodyTint: root._styled("bodyTint", 1)                 // 0 = Theme.panelSunk, 1 = the part's material
    property real bevelAlpha: root._styled("bevelAlpha", 1)
    property real shadowEdgeAlpha: root._styled("shadowEdgeAlpha", 1.0)
    property real shadowFalloff: root._styled("shadowFalloff", 1.0)
    // How far an RJ45's latch tab stands off the shell's top edge, as a share
    // of the shell's half-height. It is the one number that makes the
    // silhouette an ethernet port rather than a rectangle.
    property real tabRise: root._styled("tabRise", 0.45)
    function _styled(key, fallback) {
        const s = root.style;
        if (s && typeof s[key] === "number")
            return s[key];
        const pr = root._presets[root.preset];
        if (pr && typeof pr[key] === "number")
            return pr[key];
        return fallback;
    }

    // Unit-square distances throughout: a shadow and a rim belong to the
    // object, so they grow with the socket instead of staying N pixels wide.
    readonly property var _presets: ({
        carved: { shadeMode: 0 },
        lifted: {
            shadeMode: 1,
            lightX: -0.7071, lightY: -0.7071,
            dropDist: 0.020, dropSoft: 0.030, dropAlpha: 0.30,
            rimWidth: 0.018, rimAlpha: 0.55,
            shadeWidth: 0.022, shadeAlpha: 0.22,
            gradStrength: 0.06,
            glossAlpha: 0, outlineAlpha: 0
        },
        crisp: {
            shadeMode: 1,
            lightX: -0.7071, lightY: -0.7071,
            dropDist: 0.016, dropSoft: 0.018, dropAlpha: 0.38,
            rimWidth: 0.014, rimAlpha: 0.80,
            shadeWidth: 0.018, shadeAlpha: 0.30,
            gradStrength: 0.10,
            glossStart: 0.55, glossEnd: 0.95, glossAlpha: 0.25,
            outlineWidth: 0.010, outlineAlpha: 0.25
        },
        flat: {
            shadeMode: 1,
            lightX: -0.7071, lightY: -0.7071,
            dropDist: 0.022, dropSoft: 0.034, dropAlpha: 0.26,
            rimAlpha: 0, shadeAlpha: 0, gradStrength: 0,
            glossAlpha: 0, outlineAlpha: 0
        }
    })

    // ---- the lifted knobs, all resolvable through preset / style ----------
    property real shadeMode: root._styled("shadeMode", 1)
    property real lightX: root._styled("lightX", -0.7071)
    property real lightY: root._styled("lightY", -0.7071)
    property real dropDist: root._styled("dropDist", 0.020)
    property real dropSoft: root._styled("dropSoft", 0.030)
    property real dropAlpha: root._styled("dropAlpha", 0.30)
    property real rimWidth: root._styled("rimWidth", 0.018)
    property real rimAlpha: root._styled("rimAlpha", 0.55)
    property real shadeWidth: root._styled("shadeWidth", 0.022)
    property real shadeAlpha: root._styled("shadeAlpha", 0.22)
    property real gradStrength: root._styled("gradStrength", 0.06)
    property real glossStart: root._styled("glossStart", 0.55)
    property real glossEnd: root._styled("glossEnd", 0.95)
    property real glossAlpha: root._styled("glossAlpha", 0)
    property real outlineWidth: root._styled("outlineWidth", 0.010)
    property real outlineAlpha: root._styled("outlineAlpha", 0)

    property color dropColor: Theme.shadowDeep
    property color rimColor: Theme.netRim
    property color shadeColor: Theme.netShade
    property color outlineColor: Theme.border

    // ---- the lamps' colours ------------------------------------------------
    // Colour slots 10 and 11 are the instance's, so one socket can light green
    // and its neighbour amber without a thirteenth uniform.
    property color lampColor: Theme.netLampLink
    property color lampAltColor: Theme.netLampAct
    // What a blanking plate is made of: the fill of the card it covers, handed
    // in by the host the way SeamFade takes its ground. A cover is a separate
    // piece screwed OVER the bay, so it is a shade off the card it sits on:
    // at the card's own colour a lifted cover is nothing but its own
    // highlight, which reads as a pane of white glass. The host passes the
    // card's neighbour shade; this is the default pair.
    property color plateColor: Theme.headerBox

    // The composed part list, [type, cx, cy, s, p1, p2, p3, colour] each.
    readonly property var parts: Parts.compose(root.kind, {
        level: root.level,
        radio: root.radio,
        shut: root.shut,
        present: root.present,
        on: root.on,
        down: root.down,
        ghost: root.ghost,
        colour: root.colourSlot
    }, root._devSize)

    // Where this kind's lamps sit, in the unit square: the plate places a lamp
    // quad by these rather than repeating the numbers.
    readonly property var lamps: Parts.lampsOf(root.kind)

    implicitWidth: root.size
    implicitHeight: root.size

    // ---- internal ----------------------------------------------------------
    readonly property real _scale: Math.max(root.renderScale, 0.01)
    readonly property real _devSize: root.size * root._scale
    readonly property real _shadowPx: Math.max(1.5, Math.min(7, root.shadowWidth * root._devSize))
    // Room outside the square: the rim in device px (item px are that over the
    // scale), or -- once the object is lifted -- the shadow it throws, which is
    // measured in unit-square units and so scales with the socket; plus one
    // pixel for antialiasing.
    readonly property real _margin: Math.ceil(Math.max(
        root.bevelWidth / root._scale,
        root.shadeMode >= 0.5 ? (root.dropDist + root.dropSoft) * root.size : 0)) + 1

    function _pa(i) {
        const p = root.parts;
        return i < p.length ? Qt.vector4d(p[i][0], p[i][1], p[i][2], p[i][3]) : Qt.vector4d(0, 0, 0, 0);
    }
    function _pb(i) {
        const p = root.parts;
        return i < p.length ? Qt.vector4d(p[i][4], p[i][5], p[i][6], p[i][7]) : Qt.vector4d(0, 0, 0, 0);
    }

    ShaderEffect {
        id: fx
        anchors.fill: parent
        anchors.margins: -root._margin
        fragmentShader: "shaders/net_glyph.frag.qsb"

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
        property real tabRise: root.tabRise

        property real shadeMode: root.shadeMode
        property real lightX: root.lightX
        property real lightY: root.lightY
        property real dropDist: root.dropDist
        property real dropSoft: root.dropSoft
        property real dropAlpha: root.dropAlpha
        property real rimWidth: root.rimWidth
        property real rimAlpha: root.rimAlpha
        property real shadeWidth: root.shadeWidth
        property real shadeAlpha: root.shadeAlpha
        property real gradStrength: root.gradStrength
        property real glossStart: root.glossStart
        property real glossEnd: root.glossEnd
        property real glossAlpha: root.glossAlpha
        property real outlineWidth: root.outlineWidth
        property real outlineAlpha: root.outlineAlpha

        property color dropColor: root.dropColor
        property color rimColor: root.rimColor
        property color shadeColor: root.shadeColor
        property color outlineColor: root.outlineColor

        property color bevelColor: Theme.bevel
        property color shade: Theme.netGlyphShade
        property color panelSunk: Theme.panelSunk
        // In NetGlyphParts.js's colour order.
        property color col0: Theme.netShell
        property color col1: Theme.netShellDark
        property color col2: Theme.netContact
        property color col3: Theme.netLampOff
        property color col4: Theme.netPcb
        property color col5: Theme.netTrace
        property color col6: Theme.netBrass
        property color col7: Theme.netBezel
        property color col8: Theme.netLampWarn
        property color col9: root.plateColor
        property color col10: root.lampColor
        property color col11: root.lampAltColor
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
