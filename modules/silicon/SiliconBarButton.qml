pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/glyphs"
import "../common/components/Mix.js" as Mix
import "bar"
import "data/PowerMath.js" as Pm

// =============================================================================
// SiliconBarButton.qml -- silicon in the bar: the battery (percentage, the charge in the state's
// colour; with the charge limit on the track is scaled to it), the CPU profile as a tiny glyph in its hue, and the GPU's mode as a glyph of the same size on the
// figure's other side (bar/SiliconBarGpu.qml: a glyph per mode, lit in use, faded idle, BREATHING while a MUX switch is pending).
// Click only. Battery events play one simple coloured
// pulse (`pulse(kind)`); every battery event (`burstKinds`) also throws a burst of sparks (SiliconBarSparks: slow, high
// drag, round, shimmering as they die, each with its own phase and frequency).
//
// The face (bar/SiliconBarFace.qml) is ONE carved pill, as the audio and network buttons are: the
// profile glyph, the figure and the GPU's glyph in a row, and under them a thin carved track with
// the charge lying in it, scaled to the limit while that is on (no mark). On a side bar (`vertical`) the same
// four things stack in a narrow capsule. The face is laid out in the SCREEN frame and this item
// counter-rotates it against its bar (`barRotation`, the Stocks button's rule), so the figure and
// the glyph stand upright on every edge. The item's own size is in the BAR's frame, like every bar
// button: implicitWidth runs along the bar.
//
// What the owner binds: percent, charging, plugged, limitOn, profile, tweaked,
// gpuMode, gpuInUse, muxPending, gpuKnown, active (the popup is ours: a fact the button keeps and draws
// nothing for), vertical, barRotation.
//
// EACH GLYPH PLAYS ITS OWN FLOURISH, for a pointer on THAT glyph (feedback/silicon.md "GPU mode icon redesign"): the one
// MouseArea here (the click, the hand cursor, the pill's shade) tells both flourish clocks where the pointer is, and the face
// says which glyph's zone that is (`_pointer`, the audio and network pills' rule). The figure and the track play nothing.
//
// ONLY THE POINTER IS ANNOUNCED. At rest, and while the popup is open with the pointer
// elsewhere, the button is its carved pill and nothing else: no plate round it, no lit rim on its
// edge. Hovering eases the pill's own sunk fill one shade deeper (`hoverF`, on the bar's one hover clock, which
// the face turns into the fill and the track's groove); the hand cursor is the rest of the invitation. The
// glyph keeps its profile's hue: that hue IS the state, and the pill's shade is the hover.
//
// NOTHING ANIMATES A COLOUR. Hover, the charge's state, the GPU glyph's light and the breath are eased
// FRACTIONS mixed into themed colours (Mix.js), so at rest every value IS a Theme token and a
// light/dark switch reaches it with no clock in between.
// =============================================================================
Item {
    id: btn

    // ---- the facts ----
    property real percent: 50              // 0..100
    property bool charging: false
    property bool plugged: false           // AC online (charging, full, or held at the limit)
    property bool limitOn: false           // the charge limit is active: the track fills at `limitPercent`, eased
    property real limitPercent: 80
    property int lowAt: 15                 // the charge that counts as low, of what the limit leaves (silicon.jsonc battery.lowAt)
    property int profile: 1                // 0 Quiet, 1 Balanced, 2 Performance
    property bool tweaked: false
    property int gpuMode: 2                // 0 Integrated, 1 Smart, 2 Hybrid, 3 dGPU-only
    property bool gpuInUse: false          // the card is working (`gpu.inUse`), not merely awake
    property bool muxPending: false
    // The GPU mode is a fact (cardwire and the helper have both answered). Before that the GPU's glyph is not drawn and sits still: a guess
    // (the Hybrid fallback) shown for the first seconds of a boot is a wrong glyph, and the mode arriving would be a flourish.
    property bool gpuKnown: true

    // ---- the host ----
    property bool vertical: false          // a side bar: the face stacks
    property real barRotation: 0           // the bar frame's rotation (0, 90, 180, 270): the face counters it
    property bool active: false            // the popup is open and ours (the owner's fact; nothing is drawn for it)
    readonly property bool hovered: area.containsMouse
    signal clicked()

    // ---- the look ----
    property string fontFamily: "Inter"
    property int padAlong: 6
    property int padAcross: 3

    // ---- time (a harness freezes these and writes the two fractions itself) ----
    property bool liveMotion: true
    property real pulseProgress: 1         // 0 just fired .. 1 spent
    property string pulseKind: "full"      // full | chargeStart | chargeDone (green), low | chargeStop (red)
    // LONG AND SLOW, so a pulse is seen: the ring and the groove's tint run `pulseMs`, the colour's fade `colourMs` (below), and the sparks live
    // 2.0-3.2 s (the drag brings each to a crawl, so they linger).
    property int pulseMs: 1600
    // The events that also throw sparks (SiliconBarSparks): EVERY charge event the pill pulses for, in the pulse's own colour -- the plug-in and
    // a full pack green, the unplug (chargeStop) and the low-charge crossing red. A burst replaces a live one, so two events in a row never stack.
    property var burstKinds: ["chargeStart", "chargeDone", "full", "low", "chargeStop"]
    // How long each spark lives, ms (a draw between the two; SiliconSparks.js DEFAULTS are these numbers).
    property int sparkLifeMin: 2000
    property int sparkLifeMax: 3200
    property real breathPhase: 0           // 0..1 around one breath
    property int breathMs: 2400

    // ---- the flourishes (the profile glyph's: bar/SiliconBarFlourish.qml; the GPU glyph's: bar/SiliconBarGpu.qml; `flourishEnabled` arms both) ----
    property bool flourishEnabled: true
    // the part on the CPU's load (a heavy session starts / clears, the load swings); the rest is the profile's and the pointer's
    property bool flourishLoad: true
    // one flourish: the bolt's and the bulb's length; every other glyph runs its own share of it (SiliconGlyphPose / SiliconGpuPose `time`)
    property int flourishMs: 900
    // how long the load has to stand heavy / calm to count (ms): a session, not a spike
    property int flourishHoldMs: 8000
    // the CPU's load 0..1, reading by reading (the owner binds it from the service)
    property real cpuLoad: 0
    // `profile` and `gpuMode` are bound at creation: nothing flourishes for the first value
    property bool _facts: false
    Component.onCompleted: btn._facts = true
    onProfileChanged: if (btn._facts) faceItem.flourishItem.play("profile")
    // The pointer's rule per glyph, from the one area: where the pointer is in the WINDOW, and which glyph's zone of the face it
    // is in (the face stands counter-rotated in this item: the mapping covers it). Coming onto a glyph is its entry, the first
    // motion after it plays that glyph's flourish, once (GlyphFlourish.pointerAt).
    function _pointer(inside: bool, x: real, y: real): void {
        const w = area.mapToItem(null, x, y);
        const f = area.mapToItem(faceItem, x, y);
        const zone = inside ? faceItem.zoneAt(f.x, f.y) : -1;
        faceItem.flourishItem.glyphClock.pointerAt(zone === 0, w.x, w.y);
        faceItem.gpuItem.flourishClock.pointerAt(zone === 1, w.x, w.y);
    }
    // the OLED care's name for the profile glyph's (FlourishRegistry; the GPU glyph's is "silicon.gpu"): each says something
    // changed, so it plays at random only when switched on
    Binding {
        target: faceItem.flourishItem ? faceItem.flourishItem.glyphClock : null
        property: "group"
        value: "silicon"
    }

    // ---- the GPU's glyph (bar/SiliconBarGpu.qml has what each does) ----
    property bool gpuFlourish: true
    property real gpuFadeAlpha: 0.42
    property int gpuLitMs: 420

    // ---- derived: what the face draws ----
    readonly property var hues: SiliconBarHues {}
    readonly property color profileHue: btn.hues.profile(btn.profile)
    readonly property color tweakHue: btn.hues.tweak

    property real breathF: btn.muxPending ? 1 : 0
    Behavior on breathF {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }
    readonly property real breath: 0.5 - 0.5 * Math.cos(2 * Math.PI * btn.breathPhase)

    // The charge's colour is the state: low (not on AC) red, charging or full-on-AC green, on AC
    // but neither the idle blue, otherwise the text's own ink. Three eased fractions, the first
    // that is up wins; at rest it is exactly one token.
    readonly property bool _low: btn.percent <= Pm.lowLine({ limitPct: btn.limitOn ? btn.limitPercent : 100, lowChargeThreshold: btn.lowAt }) && !btn.plugged && !btn.charging
    readonly property bool _full: btn.percent >= 95 || (btn.limitOn && btn.percent >= btn.limitPercent - 1)
    readonly property bool _green: !btn._low && (btn.charging || (btn.plugged && btn._full))
    readonly property bool _idle: !btn._low && !btn._green && btn.plugged
    // ONE slow fade, the same both ways. A short fade (160 ms OutCubic, 144 ms of animation clock) reads as a switch: the colour is mostly
    // there after 90 ms. Only the plug-in carries a green bloom (the ring and the groove's tint, `pulseMs`, and the sparks) that makes it
    // read as a fade; an unplug's ring is red and the grey it returns to would be a plain switch. InOutQuad is symmetric: the
    // colour leaves as gently as it arrives, and `colourMs` is about the length of the pulse it travels with.
    property int colourMs: 1400
    property real lowF: btn._low ? 1 : 0
    property real greenF: btn._green ? 1 : 0
    property real idleF: btn._idle ? 1 : 0
    Behavior on lowF {
        NumberAnimation {
            duration: btn.colourMs
            easing.type: Easing.InOutQuad
        }
    }
    Behavior on greenF {
        NumberAnimation {
            duration: btn.colourMs
            easing.type: Easing.InOutQuad
        }
    }
    Behavior on idleF {
        NumberAnimation {
            duration: btn.colourMs
            easing.type: Easing.InOutQuad
        }
    }
    readonly property color fillColour: Mix.c(Mix.c(Mix.c(BarText.ink, Theme.batteryIdle, btn.idleF),
                                                     Theme.batteryCharge, btn.greenF),
                                              Theme.batteryLow, btn.lowF)

    readonly property color pulseColour: btn.pulseKind === "low" || btn.pulseKind === "chargeStop"
        ? Theme.batteryLow : Theme.batteryCharge

    // Hover is one eased fraction on the bar's one hover clock: the face mixes the pill's sunk fill, and the groove in it, by it.
    property real hoverF: btn.hovered ? 1 : 0
    Behavior on hoverF {
        GlyphHoverEase {}
    }

    // the face (a geometry probe reads its parts) and the charge burst over it (a harness pins its clock)
    readonly property SiliconBarFace face: faceItem
    readonly property SiliconBarSparks sparks: sparksItem

    // ---- size: the face is in the screen frame, the item in the bar's ----
    readonly property real _fw: faceItem.implicitWidth
    readonly property real _fh: faceItem.implicitHeight
    implicitWidth: Math.ceil(btn.vertical ? btn._fh : btn._fw) + 2 * btn.padAlong
    implicitHeight: Math.ceil(btn.vertical ? btn._fw : btn._fh) + 2 * btn.padAcross

    function pulse(kind) {
        btn.pulseKind = kind || "full";
        if (btn.liveMotion) {
            pulseAnim.restart();
            if (btn.burstKinds.indexOf(btn.pulseKind) >= 0)
                sparksItem.burst();
        }
    }

    NumberAnimation {
        id: pulseAnim
        target: btn
        property: "pulseProgress"
        from: 0
        to: 1
        duration: btn.pulseMs
        easing.type: Easing.Linear
    }

    // The breath is stepped (15 steps a second): the engine has no damage regions, so every
    // tick of a smooth animation would redraw the whole bar window for one small glyph.
    Timer {
        interval: 66
        repeat: true
        running: btn.muxPending && btn.liveMotion
        onTriggered: btn.breathPhase = (btn.breathPhase + interval / btn.breathMs) % 1
    }

    // the face stands in the screen frame: centred on whole pixels, counter-rotated against the bar
    SiliconBarFace {
        id: faceItem
        host: btn
        width: faceItem.implicitWidth
        height: faceItem.implicitHeight
        x: Math.round((btn.width - faceItem.width) / 2)
        y: Math.round((btn.height - faceItem.height) / 2)
        rotation: -btn.barRotation
        transformOrigin: Item.Center
    }

    // the sparks stand in the face's own frame (screen frame, counter-rotated with it), over the pill and past its edge
    SiliconBarSparks {
        id: sparksItem
        x: faceItem.x
        y: faceItem.y
        width: faceItem.width
        height: faceItem.height
        rotation: faceItem.rotation
        transformOrigin: Item.Center
        live: btn.liveMotion
        color: btn.pulseColour
        look: ({ lifeMin: btn.sparkLifeMin, lifeMax: btn.sparkLifeMax })
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
        onPositionChanged: mouse => btn._pointer(area.containsMouse, mouse.x, mouse.y)
        // an entry with no motion yet: the glyph under the pointer is where it came in
        onContainsMouseChanged: btn._pointer(area.containsMouse, area.mouseX, area.mouseY)
    }
}
