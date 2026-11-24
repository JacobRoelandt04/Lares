pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"
import "../../../common/components"
import "../../../common/components/Lighting.js" as Lighting

// =============================================================================
// Turntable.qml
//
// The platter the record is played on: what fills the stage when there is no
// record, and what the record sits on when there is. It is not a 3D object and
// does not try to be one -- it is a GUI element in the shell's own material,
// carved into whatever it lies on the way every other container is, wearing the
// two marks that make a circle read as a turntable rather than as a hole: the
// strobe dots around its rim and the spindle at its centre. (No tonearm: it
// would have to lie across the record, and the record is the thing we are
// looking at.)
//
// THE SPINDLE IS A CIRCLE, because the camera is straight above it. The record
// beside it is drawn from directly above, and a rod drawn in elevation -- a
// little rod standing up the screen -- would put two projections in one
// picture, which reads as a mistake. What is drawn is what a straight-down
// camera sees: the machined top of the pin (shaders/pin_top.frag: a domed circle of turned metal, anisotropic
// around its own axis) and the pin's SHADOW lying away from it across the mat.
// The shadow is what says there is a rod there; the circle only says where.
//
// THE SPINDLE IS DRAWN TWICE, from two instances of this file:
//
//   pinFrontOnly: false   the platter, the pin's shadow on it, and the cap,
//                         BEHIND the record
//   pinFrontOnly: true    the cap only, IN FRONT of the record, and only while
//                         the record's plane is below the cap
//
// which is what puts the pin THROUGH the hole. Two instances rather than one
// item whose z flips, because the record is a sibling drawn between them and no
// single item can be on both sides of it. The front copy casts no shadow: its
// shadow falls on the platter, which is behind the record, not on it.
//
// The cap is drawn at its own radius, unmagnified. The record is drawn through
// a pinhole camera and grows as it rises, but the pin only ever stands a
// fifteenth of a radius off the platter, which is under 3% of magnification --
// less than the antialiasing on a circle four pixels across.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // PUBLIC API
    // ======================================================================
    property real platterSize: 200       // the platter's diameter in px
    // How far the spindle stands above the platter. Used for the SHADOW's
    // length and for the record's approach: nothing draws the pin's length,
    // because from above there is no length to draw.
    property real pinLength: 10.2
    property real pinRadius: 2.5         // the spindle's own radius
    // How high the record floats above the platter. Everything the pin does in
    // response to the record -- which side of it the cap is drawn on, and how
    // much the record shades it -- comes from this one number.
    property real recordHeightPx: 0
    property bool pinFrontOnly: false

    // Colours. Everything the platter is made of is a theme token -- an
    // eva-light hex left in a component's default is exactly how a dark theme
    // breaks -- and the SPINDLE is the one deliberate exception, argued for
    // where it is declared.
    //
    // The platter is the shell's HEADER BOX -- the one fill in the palette that
    // is "a shade darker than the box it sits in", with its own bevel and its
    // own deeper shadow. That is what a platter is: a well sunk into the card,
    // deeper than an ordinary container, and it is the only triple in the
    // palette that reads as one at both modes without inventing a colour.
    property color surfaceColor: Theme.listBox     // what the platter is carved INTO
    property color platterColor: Theme.headerBox
    property color bevelColor: Theme.headerBoxBevel
    property color shadowColor: Theme.headerBoxShadow
    // The mat's ring and the strobe dots are ENGRAVED marks, not printed ones,
    // so they take the divider colour: darker than what they are cut into in
    // both modes, where a text colour would be darker in one and lighter in the
    // other and the platter would change character with the theme.
    property color markColor: Theme.border         // strobe dots and the mat's ring
    // THE SPINDLE IS CHROME, AND CHROME IS NOT A THEME TOKEN. These three are
    // the only colours in this file that do not come from the palette, and that
    // is the whole point of them: a pin that changes shade with the theme reads
    // as a pin made of whatever the shell is made of, and the one part of a
    // turntable that is unmistakably a MACHINED PART should look the same in a
    // bright room and a dark one, the way the real thing does.
    //
    // It is a ramp of three rather than one colour because chrome is a MIRROR:
    // what you see on it is the room, so its dark half is the room's floor, its
    // middle is the metal seen edge-on, and its light half is the room's sky --
    // and the distance between those is exactly what separates chrome from
    // aluminium, which is flat grey at every angle. The dark end is a cool grey
    // and never black (a mirror facing a floor still sees a lit floor), the
    // light end is off-white and never pure white (so the specular arcs still
    // have somewhere to go above it).
    //
    // What follows the theme is the SHADOW this thing lays on the mat,
    // below: that falls on a themed surface and is not the pin's own colour.
    property color pinColor: "#AFB5BC"        // the metal itself
    property color pinLitColor: "#F4F7FA"     // the room's sky, in a mirror
    property color pinShadeColor: "#3C424B"   // and its floor

    // The mat's ring, across, as a fraction of the platter across. 0.86 is
    // where a record's grooves end -- the same radius the sleeve carries the
    // record's impression at, so the three objects agree about the record.
    property real matRingFrac: 0.86
    property int strobeDots: 36
    property real strobeRingFrac: 0.955

    // ======================================================================
    // THE SPINDLE'S MATERIAL
    // ======================================================================
    // Machined metal is anisotropic: the marks left by the lathe run AROUND
    // the axis it was turned on, so its highlight is two opposed arcs lying
    // along the light's own azimuth rather than one round blob. `along` is the
    // sharp direction (around the circle) and `across` the smeared one
    // (radially) -- the same pair, and the same meaning, as the record's
    // grooves, because it is the same law with a smaller radius.
    //
    // The marks a lathe leaves are NOT drawn as geometry. A turned face carries
    // them at a pitch of tens across its radius, and this cap ships three
    // pixels across: band-limiting them correctly (which is what a shader must
    // do) fades them to their own mean, which is nothing. An amplitude knob for
    // them is worth 0.67 of a level at radius 26 and 0.00 at the radius the
    // spindle ships at, so there are no knobs for them. What DOES read is the
    // anisotropy they leave in the BRDF -- worth 23 levels of 255 on a 6 px cap
    // -- and that is what these two are.
    property real pinCapDome: 0.22       // cap height, as a fraction of its radius
    property real pinBrushAlong: 0.14
    property real pinBrushAcross: 0.30
    // The cap is shaded as ONE TONE on the chrome ramp above -- `pinShadeColor`
    // below, `pinColor` at rest, `pinLitColor` at the top -- rather than as a
    // reflectance multiplying a room colour. A reflectance SQUARES its own
    // colour, so against a dark palette a near-black plateau squared would come
    // out darker than the mat the spindle stands on (10-19 of 255 against a
    // platter at 40), and the pin would read as a hole punched in it. A ramp
    // between three fixed tones cannot do that under any palette, which is what
    // lets the ramp be chrome's own instead of the shell's.
    property real pinNeutral: 0.5        // the tone with no room and no lamp
                                         // (0.5 is the chrome body itself)
    property real pinEnv: 0.85           // how far the room swings it
    property real pinSpec: 1.1           // how far the highlight pushes it up

    // ======================================================================
    // THE SPINDLE'S SHADOW ON THE PLATTER
    //
    // Softer the further it is from the pin, harder at its foot -- because a
    // shadow's penumbra is set by the distance between the point casting it and
    // the surface catching it, and the pin's base is ON the platter while its
    // tip is a whole pin length up. `penGrow` is the penumbra at the tip per px
    // of that height; `penBase` is what is left at the foot, which is a contact
    // and therefore nearly sharp.
    // ======================================================================
    property real pinShadowStrength: 0.5
    property real pinPenumbraBase: 0.6
    property real pinPenumbraGrow: 0.20
    property real pinShadowFade: 0.45

    // ======================================================================
    // THE RECORD'S SHADE ON THE SPINDLE
    //
    // A record hanging just above the spindle occludes almost the whole sky the
    // cap can see, so the cap goes flat and dark long before anything with an
    // outline touches it. It is at its darkest when the record's underside is
    // level with the top of the pin, fades in over `pinDarkenRange` px of
    // approach above that, and dies within `pinDarkenRelease` px of the record
    // descending past it -- which is the moment the pin comes back out through
    // the hole and can see the room again. That release is deliberately a few
    // frames: it is the one cue that says the pin was ever there.
    // ======================================================================
    // How far DOWN the material's ramp the shade pulls the cap. `pinNeutral` is
    // where it rests, so 0.5 is exactly the distance from the plateau to the
    // button shadow: at the one instant the record's underside is level with
    // the top of the pin, the cap wears the shell's own deepest tone, and
    // nowhere else in the drop does it reach it.
    property real pinDarkenStrength: 0.50
    property real pinDarkenRange: root.pinLength * 2.5
    property real pinDarkenRelease: root.pinLength * 0.45

    // The key light, built exactly the way the record's is (Lighting.js) and
    // defaulting to the same numbers, so the pin and the record are lit by one
    // lamp without anything having to wire them together. A host that moves the
    // record's key light moves this one with it.
    property real lightAngleDeg: 122
    property real lightElevation: 0.52
    property vector3d lightDir: Lighting.dirOf(root.lightAngleDeg, root.lightElevation)

    implicitWidth: root.platterSize
    implicitHeight: root.platterSize

    // How far the record's plane sits above the top of the pin. Negative means
    // the pin is through the hole and standing proud of the record.
    readonly property real _gap: root.recordHeightPx - root.pinLength

    // QML has no smoothstep, and the shade's two ramps are the only easing in
    // this file.
    function _smoothStep(a, b, x) {
        const t = Math.max(0, Math.min(1, (x - a) / Math.max(b - a, 1e-6)));
        return t * t * (3 - 2 * t);
    }

    // How much of the room the record overhead is taking away from the cap:
    // full when its underside is level with the top of the pin, ramped in over
    // `pinDarkenRange` px of approach above that, and released within
    // `pinDarkenRelease` px of the record descending past it. Public because
    // both copies of the spindle read it and a panel wants to see it move.
    readonly property real recordShade: root.pinDarkenStrength
        * (1 - root._smoothStep(0, Math.max(root.pinDarkenRange, 0.01), Math.max(root._gap, 0)))
        * (1 - root._smoothStep(0, Math.max(root.pinDarkenRelease, 0.01), Math.max(-root._gap, 0)))
    // The front copy exists only while the cap is above the record's plane.
    readonly property bool _capInFront: root._gap < 0

    // How far the shadow's tip lands from the spindle, and therefore how much
    // room the pin's item needs around itself.
    // The clamp is the shader's own cutoff (pin_top.frag stops at 0.10), so the
    // item always contains the shadow it is asked to draw.
    readonly property real _shadowReach: root.pinLength
        * Math.hypot(root.lightDir.x, root.lightDir.y) / Math.max(root.lightDir.z, 0.10)
    readonly property real _pinHalf: root.pinFrontOnly
        ? root.pinRadius + 2
        : root.pinRadius + root._shadowReach + root.pinPenumbraBase + root.pinPenumbraGrow * root.pinLength + 2

    // ======================================================================
    // THE PLATTER
    // ======================================================================
    ShadowBox {
        id: well
        anchors.centerIn: parent
        visible: !root.pinFrontOnly
        baseWidth: root.platterSize
        baseHeight: root.platterSize
        // A circle: limitRadius caps the radius at half the side, so this is
        // the same carved edge every container in the shell has, closed on
        // itself.
        baseRadius: root.platterSize
        surfaceColor: root.surfaceColor
        backgroundColor: root.platterColor
        bevelColor: root.bevelColor
        shadowColor: root.shadowColor
        bevelWidth: 1
        // Deeper than a list box's 3: a platter is a well, and at this radius
        // a three-pixel inset on a circle reads as a smudge rather than a
        // carve.
        shadowWidth: 6

        // The mat's ring.
        Rectangle {
            anchors.centerIn: parent
            width: root.platterSize * root.matRingFrac
            height: width
            radius: width / 2
            color: "transparent"
            border.width: 1
            border.color: root.markColor
            opacity: 0.9
            antialiasing: true
        }

        // The strobe dots. The one mark that says "turntable" at a glance, and
        // the only reason the platter is not just a sunk circle.
        Repeater {
            // Built only for the instance that draws the platter: the front
            // copy is one small cap and has no business carrying 36 items.
            model: root.pinFrontOnly ? 0 : root.strobeDots
            delegate: Rectangle {
                id: dot
                required property int index
                readonly property real a: dot.index / Math.max(1, root.strobeDots) * 2 * Math.PI
                readonly property real rr: root.platterSize * 0.5 * root.strobeRingFrac
                width: Math.max(1.6, root.platterSize * 0.009)
                height: width
                radius: width / 2
                antialiasing: true
                color: root.markColor
                opacity: 0.85
                x: well.width / 2 + Math.cos(dot.a) * dot.rr - width / 2
                y: well.height / 2 + Math.sin(dot.a) * dot.rr - height / 2
            }
        }
    }

    // ======================================================================
    // THE SPINDLE
    // ======================================================================
    ShaderEffect {
        id: pin
        anchors.centerIn: parent
        width: root._pinHalf * 2
        height: width
        visible: root.pinRadius > 0.25 && (!root.pinFrontOnly || root._capInFront)
        fragmentShader: "shaders/pin_top.frag.qsb"
        blending: true

        property vector2d res: Qt.vector2d(Math.max(1, pin.width), Math.max(1, pin.height))
        property real pinR: root.pinRadius
        property real pinH: root.pinLength
        property real capDome: root.pinCapDome
        property real brushAlong: root.pinBrushAlong
        property real brushAcross: root.pinBrushAcross
        property real metalSpec: root.pinSpec
        property real envStrength: root.pinEnv
        property real neutral: root.pinNeutral

        property real shade: root.recordShade

        property real castShadow: root.pinFrontOnly ? 0 : 1
        property real shadowStrength: root.pinShadowStrength
        property real penBase: root.pinPenumbraBase
        property real penGrow: root.pinPenumbraGrow
        property real shadowFade: root.pinShadowFade

        property vector4d lightDir: Qt.vector4d(root.lightDir.x, root.lightDir.y, root.lightDir.z, 0)
        property color metalColor: root.pinColor
        property color litColor: root.pinLitColor
        property color shadeColor: root.pinShadeColor
        property color shadowColor: root.shadowColor
    }
}
