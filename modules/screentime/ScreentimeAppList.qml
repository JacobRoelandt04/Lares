pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"

// =============================================================================
// ScreentimeAppList.qml -- the apps of the shown week (or day), most used
// first, in a carved box under ScrollDressing.
//
// Rows are facts ({app, secs, frac}); one fixed-count Repeater (the count is
// the model), every delegate reads its row. A change of SCOPE (another week,
// another day) puts the new rows in at once and fades the list's presence in
// over 160 ms from nothing -- text swaps are instant, only presence fades; the
// scroll goes back to the top. (ListWave's staggered swap is not used here.)
//
// This box owns its wheel (ScrollDressing), so the host asks `canScroll`
// before giving it a gesture and turns `listWheelEnabled` off for one that
// belongs to something else.
// =============================================================================
Item {
    id: list

    property var rows: []
    // Anything that changes when the list's scope does (a week key, a day).
    property string scopeKey: ""
    property var apps: null
    property var hueOf: null
    property string focused: ""
    property string fontFamily: "Inter"
    property bool listWheelEnabled: true
    property real rowHeight: 32
    property real inset: 6
    property real radius: 14
    property int fadeMs: 160
    property string emptyText: ""

    signal rowClicked(string cls)

    readonly property bool canScroll: listFlick.contentHeight > listFlick.height + 0.5
    readonly property alias flickable: listFlick

    property real _presence: 1
    NumberAnimation {
        id: swapIn
        target: list
        property: "_presence"
        from: 0
        to: 1
        duration: list.fadeMs
        easing.type: Easing.OutCubic
    }
    onScopeKeyChanged: {
        listFlick.contentY = 0;
        swapIn.restart();
    }

    ShadowBox {
        anchors.fill: parent
        baseRadius: list.radius
        surfaceColor: Theme.surface
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        backgroundColor: Theme.listBox
        bevelWidth: 1
        shadowWidth: 3
    }
    Flickable {
        id: listFlick
        x: list.inset
        y: list.inset
        width: list.width - 2 * list.inset
        height: list.height - 2 * list.inset
        contentWidth: width
        contentHeight: list.rows.length * list.rowHeight
        clip: true
        interactive: false
        boundsBehavior: Flickable.StopAtBounds
        opacity: list._presence
        Repeater {
            model: list.rows.length
            ScreentimeAppRow {
                id: r
                required property int index
                y: r.index * list.rowHeight
                width: listFlick.width
                height: list.rowHeight
                d: list.rows[r.index]
                apps: list.apps
                hueOf: list.hueOf
                fontFamily: list.fontFamily
                focused: r.d ? r.d.app === list.focused : false
                onClicked: cls => list.rowClicked(cls)
            }
        }
    }
    ScrollDressing {
        anchors.fill: listFlick
        flick: listFlick
        wheelEnabled: list.listWheelEnabled
        ground: Theme.listBox
        fadeHeight: 18
        rampLength: list.inset + 12
    }
    Text {
        anchors.centerIn: parent
        visible: list.rows.length === 0 && list.emptyText !== ""
        text: list.emptyText
        color: Theme.textFaint
        font.family: list.fontFamily
        font.pixelSize: 12
    }
}
