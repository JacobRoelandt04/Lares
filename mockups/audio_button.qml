pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import "modules/bar/audio"
import "modules/common/mockup"

// =============================================================================
// mockups/audio_button.qml -- the bar's audio button, AudioBarButton: one pill, the output device on one half, the
// microphone on the other.
//
// The stage holds the pill as the bar's top island carries it (horizontal) and the same pill on a vertical bar,
// both showing one fake state the Run tab drives: the output device's type, the volumes and the mutes, which half the
// audio popup is showing. The pills answer the pointer as the shell's do, minus the volume control behind them
// (VolumeParity owns what a click and a wheel DO): a right click mutes that half here, a wheel moves its volume 2 %
// a notch, a left click is logged where the shell opens the audio popup. No PipeWire is touched.
//
// Save writes AudioBarButton's own defaults (the size the bar slot asks for, the glyph size) and AudioGlyphs' level
// thresholds; the shell mounts the button with neither set, so it follows them.
//
//   quickshell -p mockups/audio_button.qml
// =============================================================================
MockupWindow {
    id: win

    moduleId: "audio_button"
    title: "Audio bar button mockup"
    stageLabel: "AudioBarButton: horizontal (the bar's) and vertical"
    content: strip
    target: pill
    targets: ({
            glyphParams: pill.glyphs
        })
    zoom: 3

    lists: ({
            buttonParams: win.buttonParams,
            glyphParams: win.glyphParams
        })

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Button",
            lists: ["buttonParams", "glyphParams"]
        }
    ]

    // ---- the fake state both pills show --------------------------------------
    QtObject {
        id: fake
        property string device: "speaker"
        property real volume: 0.2
        property bool outMuted: false
        property real micVolume: 0.45
        property bool inMuted: false
        property string lastClick: "(none)"
        function clamp(v: real): real {
            return Math.max(0, Math.min(1.5, v));
        }
        function click(which: string, index: int, button: int): void {
            if (button === Qt.RightButton) {
                if (index === 0)
                    fake.outMuted = !fake.outMuted;
                else
                    fake.inMuted = !fake.inMuted;
            } else {
                fake.lastClick = which + ": the " + (index === 0 ? "output" : "input") + " half (the shell opens the audio popup on it)";
            }
        }
        function wheel(index: int, units: real): void {
            const d = units > 0 ? 0.02 : -0.02;
            if (index === 0)
                fake.volume = fake.clamp(fake.volume + d);
            else
                fake.micVolume = fake.clamp(fake.micVolume + d);
        }
    }

    // ---- the drop-in content: the pill on each kind of bar ----------------------
    Item {
        id: strip

        readonly property real pad: 12
        readonly property real gap: 22
        implicitWidth: Math.ceil(pill.implicitWidth + vPill.implicitWidth) + strip.gap + 2 * strip.pad
        implicitHeight: Math.ceil(Math.max(pill.implicitHeight, vPill.implicitHeight)) + 2 * strip.pad

        AudioBarButton {
            id: pill
            x: strip.pad
            y: Math.round((strip.height - height) / 2)
            width: implicitWidth
            height: implicitHeight
            orientation: "horizontal"
            outputDeviceType: fake.device
            outputVolume: fake.volume
            outputMuted: fake.outMuted
            inputVolume: fake.micVolume
            inputMuted: fake.inMuted
            onHalfClicked: (index, button) => fake.click("horizontal", index, button)
            onWheeled: (index, units, fromPixels) => fake.wheel(index, units)
        }
        AudioBarButton {
            id: vPill
            x: Math.round(pill.x + pill.width + strip.gap)
            y: Math.round((strip.height - height) / 2)
            width: implicitWidth
            height: implicitHeight
            orientation: "vertical"
            halfLength: pill.halfLength
            thickness: pill.thickness
            iconPixelSize: pill.iconPixelSize
            pointerCursor: pill.pointerCursor
            outputDeviceType: fake.device
            outputVolume: fake.volume
            outputMuted: fake.outMuted
            inputVolume: fake.micVolume
            inputMuted: fake.inMuted
            onHalfClicked: (index, button) => fake.click("vertical", index, button)
            onWheeled: (index, units, fromPixels) => fake.wheel(index, units)
        }
    }
    // The vertical pill reads the same glyph table as the horizontal one: the thresholds the panel sets reach both.
    Binding {
        target: vPill.glyphs
        property: "levelLowMax"
        value: pill.glyphs.levelLowMax
    }
    Binding {
        target: vPill.glyphs
        property: "levelMedMax"
        value: pill.glyphs.levelMedMax
    }

    // =====================================================================
    //  THE RUN PAGE
    // =====================================================================
    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Scenarios"
                blurb: "What the sound system says: the device the output goes to, the two volumes and mutes. VolumeParity hands the real ones to the button in the shell."
            }
            TipRow {
                tip: "The output device's type, which picks the output half's glyph (AudioGlyphs): the speaker by level, a headphone, a headset, hands-free, a phone, a portable speaker, a car, HDMI, bluetooth."
                Layout.fillWidth: true
                Label {
                    text: "device"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                ComboBox {
                    Layout.fillWidth: true
                    model: ["speaker", "headphone", "headset", "hands-free", "phone", "portable", "car", "hdmi", "bluetooth"]
                    currentIndex: Math.max(0, model.indexOf(fake.device))
                    onActivated: fake.device = currentText
                }
            }
            TipRow {
                tip: "The output volume, 0 to 1.5 (past 1 is the boost). The speaker's glyph steps at the Button tab's thresholds: no wave below the first, one wave up to the second, two above."
                Layout.fillWidth: true
                Label {
                    text: "output"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Slider {
                    Layout.fillWidth: true
                    from: 0
                    to: 1.5
                    stepSize: 0.01
                    value: fake.volume
                    onMoved: fake.volume = value
                }
                CheckBox {
                    text: "muted"
                    checked: fake.outMuted
                    onToggled: fake.outMuted = checked
                }
            }
            TipRow {
                tip: "The microphone's volume and mute. Its glyph is the microphone at every level, crossed out when muted."
                Layout.fillWidth: true
                Label {
                    text: "input"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Slider {
                    Layout.fillWidth: true
                    from: 0
                    to: 1.5
                    stepSize: 0.01
                    value: fake.micVolume
                    onMoved: fake.micVolume = value
                }
                CheckBox {
                    text: "muted"
                    checked: fake.inMuted
                    onToggled: fake.inMuted = checked
                }
            }
            TipGroup {
                title: "State"
                blurb: "What the pills report: the last left click and the half under the pointer."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "last click: " + fake.lastClick + "\nhovered half: horizontal " + pill.hoverIndex + ", vertical " + vPill.hoverIndex
                      + "   output " + Math.round(fake.volume * 100) + " %   input " + Math.round(fake.micVolume * 100) + " %"
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
            }
        }
    ]

    readonly property var buttonParams: [
        {
            label: "half length px",
            prop: "halfLength",
            group: "Pill",
            blurb: "The pill the two halves share, sized as the network pair's so the two stand alike in the bar.",
            tip: "Length of one half along the bar, px: the pill is two of them long. 26 is the network pair's half, and the bar slot asks the button for its size.",
            val: 26,
            from: 16,
            to: 48,
            step: 1
        },
        {
            label: "thickness px",
            prop: "thickness",
            group: "Pill",
            tip: "The pill's size across the bar, px. 26 is the network pair's, which leaves 7 px of the 40 px island above and below.",
            val: 26,
            from: 16,
            to: 40,
            step: 1
        },
        {
            label: "glyph px",
            prop: "iconPixelSize",
            group: "Glyphs",
            blurb: "The two glyphs, drawn in Symbols Nerd Font.",
            tip: "Pixel size of both glyphs. 15 sits inside the 26 px pill with room for the carve.",
            val: 15,
            from: 8,
            to: 24,
            step: 1
        },
        {
            label: "hand cursor",
            prop: "pointerCursor",
            group: "Glyphs",
            tip: "On: the pointer becomes the hand over the pill, the shell's one sign that something can be clicked.",
            val: true
        }
    ]

    readonly property var glyphParams: [
        {
            label: "silent below",
            prop: "levelLowMax",
            group: "Speaker levels",
            blurb: "Where the speaker's glyph steps from no wave to one wave to two (the other device types keep one glyph).",
            tip: "The volume, 0 to 1, BELOW which the speaker shows its quiet glyph (no wave). 0.005 is half a percent, where the figure reads 0 %, so any sound at all shows a wave.",
            val: 0.005,
            from: 0,
            to: 1,
            step: 0.005
        },
        {
            label: "one wave up to",
            prop: "levelMedMax",
            group: "Speaker levels",
            tip: "The volume up to which it shows one wave; above it, two (and the boost range stays at two). 0.5 is half the bar.",
            val: 0.5,
            from: 0,
            to: 1.5,
            step: 0.01
        }
    ]
}
