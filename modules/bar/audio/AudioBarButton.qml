pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/glyphs"
import "../../common/components"
import "../../common/components/Mix.js" as Mix
import "parts/AudioPose.js" as Pose
import "../../common/scroll"

// =============================================================================
// AudioBarButton.qml
//
// Combined output + input audio button for the bar. One pill-shaped ShadowBox houses two halves: the output device on
// one side, the microphone on the other. Orientation flips the layout (Row for horizontal bars, Column for vertical
// bars). It is the bar's volume control: the shell wires it through VolumeParity (modules/shell), which owns what a
// click and a wheel DO; this item draws and reports.
//
//   output half     the glyph of the device by type (speaker / headphone / headset / hdmi / bluetooth ...), the speaker's
//                   by level (low / medium / high)
//   input half      the microphone
//   on / muted      ONE SHAPE EITHER WAY: a live half wears its ON hue (BarHues `speakerOn` / `micOn`, neighbours on the
//                   hue circle, as the network pair's are), a muted half the muted ink. No crossed glyph: the colour says it
//   hover           ONLY THE POINTER IS ANNOUNCED, AND ON THE CARVED PILL, as every pill of the bar does (silicon's rule:
//                   SiliconBarFace, AerialBarButton, SystemUpdateIcon): the pointer on either half eases the pill's own fill
//                   one shade deeper (`hoverF`, one fraction on the bar's one hover clock, mixed with Mix.js -- never a Behavior
//                   on a colour). The glyphs take no hover colour (the user, 2026-11-24: "could it not all be like aerial?")
//   flourish        each half has one, the pill's SOUND CHECK (parts/AudioPose.js): the speaker thumps and throws one wave
//                   (one that makes no sound -- muted, or at no volume -- lets out a puff), the microphone's capsule is
//                   tossed, turns over and is caught (the thud picked up as two marks), headphones squeeze, burst and
//                   spring back, any other device nods. It plays when the pointer comes onto ITS half and moves
//                   (GlyphFlourish's rule, fed from the one hit area) and at random with the OLED care (group `audio`,
//                   glyphs `speaker` and `mic`); a muted half makes the start and no sound comes out
//
// What it reports -- the shape the shell's other bar controls use:
//   halfClicked(index, button)    index 0 = the output, 1 = the input; the Qt button
//   wheeled(index, units, fromPixels)
//                                 the wheel as the HAND's gesture: `units` are angle units (a mouse notch is 120; a
//                                 touchpad's pixel delta counts 2.5 of them), positive for UP in the hand's sense --
//                                 the wheel rolled away from the user, the fingers moved up -- whatever natural scrolling
//                                 did to the deltas (Qt says it flipped them with `inverted`; Hyprland never does, so the host
//                                 also says what the compositor flips: `touchpadNatural` / `mouseNatural`). `fromPixels` marks a
//                                 touchpad: a pixel delta rode with the event, and on Wayland a touchpad sends angle
//                                 deltas too, so the angle alone does not tell.
//   wheelEnded()                  the fingers lifting (a zero delta)
// The host counts the wheel into steps (VolumeParity: a detent, from a goal); a bar button cannot know what a step is.
//
// Glyph selection is AudioGlyphs (common/components): data-driven slots so a later CSV/icon-pack mapping can replace
// defaults without code changes. Default speaker glyph swaps between low/medium/high based on volume; other device types
// use a single glyph regardless of level. The bar asks it for the UNMUTED glyph always (the OSD and the popup, which share
// the table, still draw the crossed ones).
// =============================================================================
Item {
    id: root

    // ---- Orientation ----
    property string orientation: "horizontal"   // "horizontal" | "vertical"
    readonly property bool _horizontal: root.orientation === "horizontal"

    // ---- State (the host drives it) ----
    property string outputDeviceType: "speaker"
        // "speaker" | "headphone" | "headset" | "hands-free" | "phone"
        // | "portable" | "car" | "hdmi" | "bluetooth"
    property real outputVolume: 0.5             // 0..1.5 (1.5 = boost cap)
    property bool outputMuted: false
    property real inputVolume: 0.5
    property bool inputMuted: false

    // ---- Glyphs ----
    // The table (slots, level thresholds, device types) is AudioGlyphs.
    readonly property AudioGlyphs glyphs: AudioGlyphs { }

    // ---- Geometry: the networking pair's pill, so the two stand alike in the bar ----
    property real halfLength: 26
    property real thickness: 26
    property int iconPixelSize: 15

    property bool pointerCursor: true

    // The compositor flips the deltas of this kind of device (Hyprland's natural_scroll): a flipped delta is un-flipped here, once, with
    // or without Qt's own `inverted` (the host reads the setting; NaturalScroll). A touchpad is the event with a pixel delta.
    property bool touchpadNatural: false
    property bool mouseNatural: false

    // ---- Signals ----
    signal halfClicked(int index, int button)
    signal wheeled(int index, real units, bool fromPixels)
    signal wheelEnded

    implicitWidth: root._horizontal ? 2 * root.halfLength : root.thickness
    implicitHeight: root._horizontal ? root.thickness : 2 * root.halfLength

    // The half the pointer is on, -1 when it is off the pill.
    readonly property int hoverIndex: hit.hoverIndex

    // The rect of half `i` in this item's coordinates (a probe clicks on it).
    function halfRect(i: int): rect {
        const w = root._horizontal ? root.width / 2 : root.width;
        const h = root._horizontal ? root.height : root.height / 2;
        return Qt.rect(root._horizontal ? i * w : 0, root._horizontal ? 0 : i * h, w, h);
    }

    // ---- The pointer: one fraction on the bar's one hover clock; the pill's carved fill mixes by it (the pill is one button) ----
    property real hoverF: hit.hoverIndex >= 0 ? 1 : 0
    Behavior on hoverF { GlyphHoverEase {} }
    // silicon's depths (SiliconBarFace): hover is 0.4 of a step from the fill toward `border`, the edge goes to `shadowDeep`
    readonly property real hoverDepth: 0.4
    readonly property color pillFill: Mix.c(Theme.listBox, Theme.border, root.hoverDepth * root.hoverF)
    readonly property color pillEdge: Mix.c(Theme.border, Theme.shadowDeep, root.hoverF)

    // ---- Chrome: one pill, the bar's carved pill (silicon's, aerial's) ----
    ShadowBox {
        id: chrome
        anchors.fill: parent
        // Pill: corners = half the short axis.
        baseRadius: Math.min(width, height) * 0.5
        bevelWidth: 0                       // no lit rim outside the edge, as silicon's pill
        shadowWidth: 2.5
        surfaceColor: "transparent"
        backgroundColor: root.pillFill
        bevelColor: Theme.bevel
        shadowColor: root.pillEdge
    }

    // On: the half's hue comes and goes on the shell's presence fade (160 ms).
    property real _onOut: root.outputMuted ? 0 : 1
    property real _onIn: root.inputMuted ? 0 : 1
    Behavior on _onOut { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on _onIn { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

    component Half: Item {
        id: half
        property int index: 0
        property string glyph: ""
        property real onF: 1
        property color onColor: Theme.textMuted
        // The glyph the half is PLACED by, "" to centre the glyph shown. A speaker's three glyphs (no wave, one, two) differ in width, so
        // centring each would slide the speaker's body as a wave comes and goes: the speaker is placed as its widest (two waves) would
        // be and every level is drawn from that left edge, so the body stays and the waves grow outward.
        property string pinGlyph: ""
        readonly property rect r: root.halfRect(half.index)
        x: half.r.x
        y: half.r.y
        width: half.r.width
        height: half.r.height

        TextMetrics {
            id: pinMetrics
            font.family: "Symbols Nerd Font"
            font.pixelSize: root.iconPixelSize
            font.bold: false
            text: half.pinGlyph
        }
        // The flourish (the header): its clock, and the half's glyph posed on it. `live` is the half being on.
        property bool live: true
        property string flourishName: ""
        readonly property alias flourish: check
        readonly property alias glyphItem: posed
        GlyphFlourish {
            id: check
            group: "audio"
            glyph: half.flourishName
            decorative: true
            host: half
            armed: root.flourishEnabled && Pose.has(half.glyph)
            ms: Pose.life(half.glyph, half.live)
            overlap: "ignore"
        }
        // the glyph posed on the clock: its parts, and each part's share of the ink (a puff fades)
        readonly property var pose: check.playing
            ? Pose.pose(half.glyph, check.t, check.ms, half.live, null, posed.pixelSize, posed.origin.x, posed.origin.y) : null
        // The plain Text at rest (PosedGlyph); the speaker keeps its pinned left edge in every pose (the cone grows from it).
        PosedGlyph {
            id: posed
            // by hand where pinned: the anchor rounds its offset, and the body must stand on one whole pixel at every level
            x: half.pinGlyph !== "" ? Math.round((half.width - pinMetrics.advanceWidth) / 2) : Math.round((half.width - width) / 2)
            anchors.verticalCenter: parent.verticalCenter
            text: half.glyph
            pixelSize: root.iconPixelSize
            // never faint: a muted half is the muted ink, a live one its hue (the pointer is told by the pill, not the glyph)
            color: Mix.c(Theme.textMuted, half.onColor, half.onF)
            posing: check.playing
            parts: half.pose ? half.pose.parts : []
            shades: half.pose ? half.pose.shades : []
        }
    }

    Half {
        id: outHalf
        index: 0
        glyph: root.glyphs.outputGlyph(root.outputDeviceType, root.outputVolume, false)
        pinGlyph: root.outputDeviceType === "speaker" ? root.glyphs.outputGlyphSpeakerHigh : ""
        onF: root._onOut
        onColor: BarHues.speakerOn
        live: !root.outputMuted
        flourishName: "speaker"
    }
    Half {
        id: inHalf
        index: 1
        glyph: root.glyphs.inputGlyphAt(root.inputVolume, false)
        onF: root._onIn
        onColor: BarHues.micOn
        live: !root.inputMuted
        flourishName: "mic"
    }

    // ---- The flourishes (the header) ----
    property bool flourishEnabled: true
    readonly property GlyphFlourish outputFlourish: outHalf.flourish
    readonly property GlyphFlourish inputFlourish: inHalf.flourish
    // the glyph items (a probe reads their parts)
    readonly property PosedGlyph outputGlyphItem: outHalf.glyphItem
    readonly property PosedGlyph inputGlyphItem: inHalf.glyphItem
    // The pointer's rule per half, from the one area: where the pointer is in the WINDOW, and which half it is on.
    function _pointer(index: int, x: real, y: real): void {
        const p = hit.mapToItem(null, x, y);
        outHalf.flourish.pointerAt(index === 0, p.x, p.y);
        inHalf.flourish.pointerAt(index === 1, p.x, p.y);
    }

    // Which half a point of this item is on.
    function halfAt(x: real, y: real): int {
        return hit._half(x, y);
    }

    // ---- Hit handler (sits above both halves to claim all pointer events) ----
    WheelArea {
        id: hit
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        cursorShape: root.pointerCursor ? Qt.PointingHandCursor : Qt.ArrowCursor

        property int hoverIndex: -1
        // Which half a point is on: arithmetic, not hit-testing, so neither half can steal the other's hover.
        function _half(x: real, y: real): int {
            return (root._horizontal ? x >= root.width / 2 : y >= root.height / 2) ? 1 : 0;
        }
        onPositionChanged: mouse => {
            hit.hoverIndex = hit.containsMouse ? hit._half(mouse.x, mouse.y) : -1;
            root._pointer(hit.hoverIndex, mouse.x, mouse.y);
        }
        onContainsMouseChanged: {
            if (!hit.containsMouse)
                hit.hoverIndex = -1;
            // an entry with no motion yet: the half under the pointer is where it came in
            root._pointer(hit.containsMouse ? hit._half(hit.mouseX, hit.mouseY) : -1, hit.mouseX, hit.mouseY);
        }
        onClicked: mouse => root.halfClicked(hit._half(mouse.x, mouse.y), mouse.button)
        turned: wheel => root._readWheel(wheel.x, wheel.y, wheel.angleDelta, wheel.pixelDelta, wheel.inverted)
    }

    // One wheel event, read as the hand's gesture (the header). The MouseArea's handler is the only caller but a probe's:
    // a QtTest wheel carries no pixel delta and is never inverted, so a touchpad is fed through here. The half comes from
    // where the event landed, not from the hover state: a wheel over a half the pointer has not been seen to enter (it
    // arrived with the event) is still that half's.
    readonly property real pixelToAngle: 2.5
    function _readWheel(x: real, y: real, angle: point, pixel: point, inverted: bool): void {
        if (angle.x === 0 && angle.y === 0 && pixel.x === 0 && pixel.y === 0) {
            root.wheelEnded();
            return;
        }
        if (angle.y === 0 && pixel.y === 0)
            return;                                  // sideways: not the volume's
        const flipped = inverted || (pixel.y !== 0 ? root.touchpadNatural : root.mouseNatural);
        const units = (angle.y !== 0 ? angle.y : pixel.y * root.pixelToAngle) * (flipped ? -1 : 1);
        root.wheeled(hit._half(x, y), units, pixel.y !== 0);
    }

}
