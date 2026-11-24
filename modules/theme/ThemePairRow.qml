pragma ComponentBehavior: Bound

import QtQuick

import "../common/components"
import "../common/float"

// =============================================================================
// ThemePairRow.qml -- one pair: its light card and its dark card, the strands between them, its name above the strands. A theme with one mode has one card and no strands.
// `islandArmed`: the popup is a theme island (ThemePopup), and what is themed here goes old -> new by the line: the name, here; a card's shadow, there.
// =============================================================================
Item {
    id: row

    required property ThemeStyle style
    required property var entry
    required property int rowIndex
    property FloatClock clock: null
    property real flow: 0
    property string fontFamily: "Inter"
    // the keys of the card the hand is on and of the card in force, "<name>:<mode>"
    property string currentKey: ""
    property string activeKey: ""
    property bool islandArmed: false

    signal picked(string name, string mode)
    signal hoverEntered(string key)
    signal hoverLeft(string key)

    readonly property bool hasLight: row.entry.modes.indexOf("light") >= 0
    readonly property bool hasDark: row.entry.modes.indexOf("dark") >= 0
    // A theme of one mode: the card that is not shown has the shown one's colours, so that nothing reads a colour that is not there.
    readonly property var _light: row.hasLight ? row.entry.light : row.entry.dark
    readonly property var _dark: row.hasDark ? row.entry.dark : row.entry.light

    implicitWidth: 2 * row.style.cardWidth + row.style.strandGap
    implicitHeight: row.style.cardHeight

    ThemeStrands {
        id: strands
        visible: row.hasLight && row.hasDark
        style: row.style
        lightColors: row._light
        darkColors: row._dark
        flow: row.flow
        readonly property real pad: Math.max(row.style.strand1Amp, row.style.strand2Amp, row.style.strand3Amp) + row.style.strand1Width + row.style.dealRise
        x: lightCard.x + lightCard.width - row.style.strandTuck - 4
        y: -strands.pad
        width: row.style.strandGap + 2 * row.style.strandTuck + 8
        height: row.height + 2 * strands.pad
        ax: lightCard.rightX - row.style.strandTuck - strands.x
        ay: lightCard.sideY - strands.y
        bx: darkCard.leftX + row.style.strandTuck - strands.x
        by: darkCard.sideY - strands.y
    }

    Text {
        id: label
        x: lightCard.x + lightCard.width
        y: Math.round(row.height / 2 - row.style.labelRise - height / 2)
        width: row.style.strandGap
        horizontalAlignment: Text.AlignHCenter
        visible: strands.visible
        text: String(row.entry.name).replace(/-/g, " ")   // a name is shown with its dashes as spaces (themectl shown_name)
        color: labelFade.value
        font.family: row.fontFamily
        font.pixelSize: row.style.labelSize
        elide: Text.ElideRight
    }
    FadeColor {
        id: labelFade
        token: "textMuted"
        active: row.islandArmed
        place: label
    }

    ThemeCard {
        id: lightCard
        visible: row.hasLight
        style: row.style
        colors: row._light
        seed: 2 * row.rowIndex + 1
        clock: row.clock
        order: 2 * row.rowIndex
        islandArmed: row.islandArmed
        active: row.activeKey === row.entry.name + ":light"
        current: row.currentKey === row.entry.name + ":light"
        onPicked: row.picked(row.entry.name, "light")
        onHoverEntered: row.hoverEntered(row.entry.name + ":light")
        onHoverLeft: row.hoverLeft(row.entry.name + ":light")
    }
    ThemeCard {
        id: darkCard
        visible: row.hasDark
        x: row.width - width
        style: row.style
        colors: row._dark
        seed: 2 * row.rowIndex + 2
        clock: row.clock
        order: 2 * row.rowIndex + 1
        islandArmed: row.islandArmed
        active: row.activeKey === row.entry.name + ":dark"
        current: row.currentKey === row.entry.name + ":dark"
        onPicked: row.picked(row.entry.name, "dark")
        onHoverEntered: row.hoverEntered(row.entry.name + ":dark")
        onHoverLeft: row.hoverLeft(row.entry.name + ":dark")
    }
}
