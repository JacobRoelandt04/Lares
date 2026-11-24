pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import "../theme"

// =============================================================================
// ThemeBar -- the theme controls of the stage toolbar.
//
// Which theme the shell is wearing is a property of the VIEW, like the zoom
// and the frame counter it sits beside: it is not a value of the module on
// the stage, so it is not on a tab, not in the module's profiles and not in
// its `val:` defaults. Every mockup gets these controls for free by being a
// MockupWindow.
//
//   mode  a two-segment pill; the live half is filled. One click flips it.
//   pair  the theme pair on screen, cycling on click; disabled -- with a tip
//         that says why -- while only one pair is on disk.
//   fade  the ONE crossfade clock every themed colour rides, shell-wide:
//         its duration and its easing.
//
// Painted with dev-chrome literals, never with Theme's own tokens. The panel
// has to stay readable while the theme being edited is broken, and it must
// never be mistaken for the content on the stage.
// =============================================================================
RowLayout {
    id: themeBar

    spacing: 12

    // Six curves, not Easing's forty. A colour crossfade wants symmetric ease
    // (InOut*) or a soft landing (Out*); anything that overshoots sends a
    // colour past its target and reads as a flash, and Bezier/Bounce/Elastic
    // are all overshoot. Linear is kept because it is the honest baseline.
    readonly property var curveNames: ["Linear", "InOutQuad", "InOutCubic", "OutCubic", "InOutSine", "OutQuint"]
    readonly property var curveTypes: [Easing.Linear, Easing.InOutQuad, Easing.InOutCubic, Easing.OutCubic, Easing.InOutSine, Easing.OutQuint]
    // A curve set from elsewhere that is not in the six shows as the default
    // rather than as a blank box.
    function curveIndexOf(t) {
        const i = themeBar.curveTypes.indexOf(t);
        return i < 0 ? 1 : i;
    }

    readonly property bool canCycle: (Theme.pairs || []).length > 1

    // ---- mode -------------------------------------------------------------
    TipRow {
        Layout.fillWidth: false
        tip: "Light or dark half of the theme pair on screen. One click flips it: the choice is written to ~/.config/theme/state.json, so the rest of the desktop follows the same switch. Every themed colour crosses over together on one clock -- its length and curve are the two controls to the right. A view setting, global to the whole shell, not a value of this module."
            + (Theme.lastError ? "\n\nTheme error: " + Theme.lastError : "")

        Label {
            text: "theme"
            // The only place a broken theme file can announce itself: the
            // shell keeps its shipped defaults and renders normally, so
            // without this the failure is invisible.
            color: Theme.lastError ? "#D20F39" : "#8A8A8C"
            font.family: "Audiowide"
            font.pixelSize: 14
        }

        Rectangle {
            id: modePill

            // Both halves take the width of the wider word, measured rather
            // than laid out, so the knob is exactly half the pill and the
            // control does not change width when the mode flips.
            TextMetrics {
                id: mLight
                font.family: "Audiowide"
                font.pixelSize: 13
                text: "light"
            }
            TextMetrics {
                id: mDark
                font: mLight.font
                text: "dark"
            }
            readonly property real segW: Math.ceil(Math.max(mLight.width, mDark.width)) + 22
            readonly property bool isDark: Theme.mode === "dark"

            implicitWidth: modePill.segW * 2 + 6
            implicitHeight: 30
            radius: height / 2
            color: "#EAEDF5"
            border.color: "#CED1D7"
            border.width: 1

            Rectangle {
                id: modeKnob
                x: modePill.isDark ? modePill.width - 3 - modeKnob.width : 3
                y: 3
                width: modePill.segW
                height: modePill.height - 6
                radius: height / 2
                color: "#4480F4"
                // Deliberately the theme's own fade, so the knob and the
                // colours it commands move as one gesture -- and so the
                // duration and curve chosen below can be felt, not just read.
                Behavior on x {
                    NumberAnimation {
                        duration: Theme.fadeMs
                        easing.type: Theme.fadeEasing
                    }
                }
            }

            Label {
                x: 3
                width: modePill.segW
                height: modePill.height
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: "light"
                color: !modePill.isDark ? "#EAEDF5" : modeHover.hovered ? "#4480F4" : "#5D5D5F"
                font: mLight.font
                Behavior on color {
                    ColorAnimation {
                        duration: 120
                    }
                }
            }
            Label {
                x: 3 + modePill.segW
                width: modePill.segW
                height: modePill.height
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: "dark"
                color: modePill.isDark ? "#EAEDF5" : modeHover.hovered ? "#4480F4" : "#5D5D5F"
                font: mLight.font
                Behavior on color {
                    ColorAnimation {
                        duration: 120
                    }
                }
            }

            HoverHandler {
                id: modeHover
                cursorShape: Qt.PointingHandCursor
            }
            // The whole pill toggles: aiming at the half that is not lit is a
            // second decision for a control that only has one.
            TapHandler {
                onTapped: Theme.toggleMode()
            }
        }
    }

    // ---- pair -------------------------------------------------------------
    TipRow {
        Layout.fillWidth: false
        tip: themeBar.canCycle
            ? "The theme pair on screen: " + Theme.themeName + ". Click to cycle to the next of the " + Theme.pairs.length + " pairs in " + Theme.themesDir + ", keeping the current light/dark mode. Global, like the mode beside it."
            : "The theme pair on screen: " + (Theme.themeName || "none") + ". Disabled because it is the only pair on disk -- there is nothing to cycle to. Drop another <name>.json into " + Theme.themesDir + " and this starts cycling."

        Rectangle {
            id: pairPill

            implicitWidth: pairLabel.implicitWidth + 22
            implicitHeight: 30
            radius: height / 2
            // MockupTabPill's shape and palette; the disabled state is the
            // faint text and the bevel-weight border, so it reads as switched
            // off next to the mode pill rather than merely unhovered.
            color: !themeBar.canCycle ? "#EAEDF5" : pairHover.hovered ? "#E1E4EB" : "#EAEDF5"
            border.color: themeBar.canCycle ? "#CED1D7" : "#DCDFE6"
            border.width: 1
            Behavior on color {
                ColorAnimation {
                    duration: 120
                }
            }

            Label {
                id: pairLabel
                anchors.centerIn: parent
                text: Theme.themeName ? Theme.themeName.replace(/-/g, " ") : "—"   // shown with its dashes as spaces
                color: !themeBar.canCycle ? "#B8BBC2" : pairHover.hovered ? "#4480F4" : "#5D5D5F"
                font.family: "Audiowide"
                font.pixelSize: 14
                Behavior on color {
                    ColorAnimation {
                        duration: 120
                    }
                }
            }

            HoverHandler {
                id: pairHover
                enabled: themeBar.canCycle
                cursorShape: Qt.PointingHandCursor
            }
            TapHandler {
                enabled: themeBar.canCycle
                onTapped: {
                    const all = Theme.pairs;
                    const i = all.indexOf(Theme.themeName);
                    Theme.setTheme(all[(i + 1) % all.length]);
                }
            }
        }
    }

    // ---- the one crossfade clock -----------------------------------------
    TipRow {
        Layout.fillWidth: false
        tip: "How long every themed colour in the shell takes to cross from the old theme to the new one. One clock drives all of them, so nothing arrives early. GLOBAL: a shell-wide view setting, not a property of the module on the stage, so it is in neither the module's profiles nor its Save to mockup. 420 ms is long enough to read as a change of light and short enough not to feel like waiting; 0 switches instantly."

        Label {
            text: "fade"
            color: "#8A8A8C"
            font.family: "Audiowide"
            font.pixelSize: 14
        }
        Slider {
            Layout.preferredWidth: 110
            from: 0
            to: 2000
            stepSize: 10
            value: Theme.fadeMs
            onMoved: Theme.fadeMs = value
        }
        Label {
            // Its own fixed slot: a figure that resizes its row makes the
            // control jump under the pointer that is dragging it.
            text: Theme.fadeMs + " ms"
            color: "#5D5D5F"
            font.family: "Audiowide"
            font.pixelSize: 14
            Layout.preferredWidth: 62
            horizontalAlignment: Text.AlignRight
        }
    }

    TipRow {
        Layout.fillWidth: false
        tip: "Easing of that same crossfade clock. GLOBAL, like the duration beside it. InOutQuad is the default: it leaves and arrives softly and never overshoots, and a colour that overshoots its target reads as a flash rather than a fade. The list is the six curves worth using on a colour, not all forty."

        ComboBox {
            id: curveBox
            Layout.preferredWidth: 150
            font.family: "Audiowide"
            font.pixelSize: 13
            model: themeBar.curveNames
            onActivated: index => Theme.fadeEasing = themeBar.curveTypes[index]
            // Set imperatively, never bound: ComboBox writes currentIndex
            // itself on every activation, and that write would destroy a
            // binding permanently. The Connections keeps it honest if the
            // curve is changed from anywhere else.
            Component.onCompleted: curveBox.currentIndex = themeBar.curveIndexOf(Theme.fadeEasing)
            Connections {
                target: Theme
                function onFadeEasingChanged() {
                    curveBox.currentIndex = themeBar.curveIndexOf(Theme.fadeEasing);
                }
            }
        }
    }
}
