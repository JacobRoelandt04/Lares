pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/icons"
import "../common/components/Mix.js" as Mix
import "data/ScreentimeModel.js" as Model

// =============================================================================
// ScreentimeAppRow.qml -- one app of the list: icon, name, DUR right-aligned
// in one Text (the font's own kerning: the figure changes once a minute and
// grows to the left, so nothing beside it moves), and a thin bar of its share (relative to the top row)
// in its hue. A click focuses the app (again = unfocus); the focus is a wash
// and an accent name, both on one eased fraction.
//
// The row holds FACTS ({app, secs, frac}); every colour is resolved here.
// =============================================================================
Item {
    id: row

    // {app, secs, frac, progs}
    property var d: null
    property var apps: null
    property var hueOf: null
    property bool focused: false
    property string fontFamily: "Inter"
    property real inset: 6
    property real iconSize: 22
    property real durSlot: 56
    property real barHeight: 3
    property int fadeMs: 160

    signal clicked(string cls)

    readonly property string cls: row.d ? row.d.app : ""
    readonly property var info: row.apps ? row.apps.app(row.cls) : null
    readonly property color hue: row.hueOf ? row.hueOf(row.cls) : Theme.accent

    readonly property real _textX: row.inset + row.iconSize + 8
    readonly property real _textW: Math.max(0, row.width - row.inset - row._textX - row.durSlot - 8)

    property real _focusF: row.focused ? 1 : 0
    Behavior on _focusF {
        NumberAnimation {
            duration: row.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    property real _hoverF: area.containsMouse ? 1 : 0
    Behavior on _hoverF {
        NumberAnimation {
            duration: row.fadeMs
            easing.type: Easing.OutCubic
        }
    }

    Rectangle {
        x: 2
        y: 1
        width: row.width - 4
        height: row.height - 2
        radius: 8
        color: Theme.panelSunk
        opacity: Math.max(row._focusF, row._hoverF * 0.5)
    }

    AppIcon {
        x: row.inset
        y: Math.round((row.height - row.iconSize) / 2)
        size: row.iconSize
        cls: row.cls
        appId: row.info ? row.info.desktopId : ""
        icon: row.info ? row.info.icon : ""
        kind: "app"
    }
    Text {
        id: name
        x: row._textX
        y: 5
        width: Math.min(Math.ceil(name.implicitWidth), row._textW)
        elide: Text.ElideRight
        text: row.info ? row.info.name : row.cls
        color: Mix.c(Theme.textPrimary, Theme.accent, row._focusF)
        font.family: row.fontFamily
        font.pixelSize: 12
    }
    // A terminal's programs, most time first (Model.rows): faint, beside the name, in what
    // room the name leaves.
    Text {
        readonly property real _x: row._textX + name.width + 8
        visible: text !== "" && width > 12
        x: _x
        y: name.y + name.baselineOffset - baselineOffset
        width: Math.max(0, row._textX + row._textW - _x)
        elide: Text.ElideRight
        text: row.d && row.d.progs ? row.d.progs.join(" · ") : ""
        color: Theme.textFaint
        font.family: row.fontFamily
        font.pixelSize: 11
    }
    Text {
        x: row.width - row.inset - row.durSlot
        y: 5
        width: row.durSlot
        horizontalAlignment: Text.AlignRight
        text: row.d ? Model.fmt(row.d.secs) : ""
        color: Theme.textMuted
        font.family: row.fontFamily
        font.pixelSize: 11
    }
    Rectangle {
        x: row._textX
        y: row.height - 8
        width: row.width - row.inset - row._textX
        height: row.barHeight
        radius: height / 2
        color: Theme.panelSunk
        Rectangle {
            width: row.d ? Math.max(row.barHeight, Math.round(parent.width * row.d.frac)) : 0
            height: parent.height
            radius: height / 2
            color: row.hue
        }
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.clicked(row.cls)
    }
}
