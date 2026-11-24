pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// ThemeCardFace.qml -- a mini desktop in one mode of one pair: its ground, the shell's three islands and slim bars, a terminal in the ANSI colours and an app over it.
// Rectangles in the pair's own colours (`colors`: data, ThemePairs, never tokens), so a pair that is not in force draws as itself. A still picture: the card holds it as
// one texture.
// =============================================================================
Item {
    id: face

    required property var colors
    property real radius: 14

    // A slot's height as a share of the card, whole pixels: the mock must not shimmer at rest.
    readonly property real _bar: Math.round(face.height * 0.065)
    readonly property real _slim: Math.max(2, Math.round(face.height * 0.016))
    readonly property real _win: Math.round(face.height * 0.03)

    // THE GROUND: the pair's sunk surface towards its accent. This is the card, never the wallpaper: at this size a photograph is a smear behind the windows, and the gradient
    // says which mode of which pair this is from the palette alone.
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop {
                position: 0
                color: face.colors.panelSunk
            }
            GradientStop {
                position: 1
                color: Qt.tint(face.colors.panelSunk, Qt.alpha(face.colors.accent, 0.35))
            }
        }
    }

    // ---- the slim bars: a ring whose top runs off the card, so the islands hang from the edge with the ground between them --------------------------
    Rectangle {
        x: 0
        y: -face._bar
        width: face.width
        height: face.height + face._bar
        radius: face.radius
        color: "transparent"
        border.color: face.colors.surface
        border.width: face._slim
    }

    // ---- the islands -----------------------------------------------------------------------------------------------------------------------------
    component Island: Rectangle {
        height: face._bar
        color: face.colors.surface
        bottomLeftRadius: Math.round(face._bar * 0.45)
        bottomRightRadius: Math.round(face._bar * 0.45)
    }
    component Dot: Rectangle {
        width: 3
        height: 3
        radius: 1.5
    }
    Island {
        id: left
        x: Math.round(face.width * 0.035)
        width: Math.round(face.width * 0.34)
        Row {
            x: 5
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3
            Repeater {
                model: ["textMuted", "textMuted", "accent", "textMuted", "textMuted"]
                Dot {
                    required property string modelData
                    color: face.colors[modelData]
                }
            }
        }
        Rectangle {
            x: Math.round(parent.width * 0.52)
            anchors.verticalCenter: parent.verticalCenter
            width: Math.round(parent.width * 0.38)
            height: 2
            radius: 1
            color: face.colors.textFaint
        }
    }
    Island {
        x: Math.round((face.width - width) / 2)
        width: Math.round(face.width * 0.2)
        Rectangle {
            anchors.centerIn: parent
            width: Math.round(parent.width * 0.5)
            height: 2
            radius: 1
            color: face.colors.textPrimary
        }
    }
    Island {
        x: face.width - width - Math.round(face.width * 0.035)
        width: Math.round(face.width * 0.26)
        Row {
            anchors.right: parent.right
            anchors.rightMargin: 5
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3
            Repeater {
                model: ["textMuted", "ok", "accent", "warn", "textMuted"]
                Dot {
                    required property string modelData
                    color: face.colors[modelData]
                }
            }
        }
    }

    // ---- the windows: a terminal and an app over it, with the ground around them: this is its card, and the windows only say whose --------------------------
    component Window: Rectangle {
        property bool focused: false
        radius: face._win
        color: face.colors.surface
        border.width: 1
        border.color: focused ? face.colors.hyprBorderActive : face.colors.hyprBorderInactive
    }
    component Line: Rectangle {
        height: 2
        radius: 1
    }

    // the terminal: the prompt's accent, then lines of output in the ANSI colours
    Window {
        id: term
        x: Math.round(face.width * 0.075)
        y: Math.round(face.height * 0.19)
        width: Math.round(face.width * 0.5)
        height: Math.round(face.height * 0.62)
        color: face.colors.terminalBg
        Column {
            x: 6
            y: 6
            spacing: Math.max(2, Math.round((term.height - 12) / 8 - 2))
            Repeater {
                // [ colour key, share of the width ]: facts, resolved by the delegate
                model: [["accent", 0.42], ["terminalFg", 0.72], ["ansiGreen", 0.6], ["ansiYellow", 0.34], ["ansiBlue", 0.5], ["ansiMagenta", 0.66], ["ansiCyan", 0.28], ["ansiRed", 0.46]]
                Line {
                    required property var modelData
                    width: Math.round((term.width - 12) * modelData[1])
                    color: face.colors[modelData[0]]
                }
            }
        }
    }
    // an app over it, focused: a header, a carved list, the status colours
    Rectangle {
        x: app.x
        y: app.y + 2
        width: app.width
        height: app.height + 1
        radius: app.radius + 1
        color: Qt.alpha(face.colors.shadowDeep, 0.55)
    }
    Window {
        id: app
        focused: true
        x: Math.round(face.width * 0.5)
        y: Math.round(face.height * 0.36)
        width: Math.round(face.width * 0.42)
        height: Math.round(face.height * 0.53)
        Rectangle {
            x: 5
            y: 5
            width: app.width - 10
            height: 9
            radius: 3
            color: face.colors.headerBox
            Line {
                x: 4
                anchors.verticalCenter: parent.verticalCenter
                width: Math.round(parent.width * 0.5)
                color: face.colors.textPrimary
            }
        }
        Rectangle {
            x: 5
            y: 17
            width: app.width - 10
            height: Math.round((app.height - 22) * 0.56)
            radius: 3
            color: face.colors.listBox
            Column {
                x: 4
                anchors.verticalCenter: parent.verticalCenter
                spacing: 3
                Repeater {
                    model: [0.7, 0.45]
                    Line {
                        required property real modelData
                        required property int index
                        width: Math.round((app.width - 18) * modelData)
                        color: index === 0 ? face.colors.accent : face.colors.textMuted
                    }
                }
            }
        }
        Row {
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 5
            spacing: 3
            Repeater {
                model: ["ok", "warn", "error", "accent"]
                Rectangle {
                    required property string modelData
                    width: 6
                    height: 6
                    radius: 3
                    color: face.colors[modelData]
                }
            }
        }
    }
}
