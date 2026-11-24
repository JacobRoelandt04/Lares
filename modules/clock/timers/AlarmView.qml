pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls

import "../../common/components"
import "../../common/components/Mix.js" as Mix
import "../../common/theme"
import ".."
import "format.js" as Fmt

// The alarm view: + (top-right) adds one, the alarms in the band under the
// ring -- a time, its days, its toggle. A click on a row selects it (the dial
// then winds ITS time) and opens its label and Delete; a click on it again
// lets go. The days are clickable on every row. While an alarm rings, Stop
// and Snooze sit inside the ring.
TimerView {
    id: view

    // The alarm being edited (its id), or "". The card reads it.
    property string selected: ""
    readonly property var dayLetters: ["M", "T", "W", "T", "F", "S", "S"]
    readonly property var ringing: view.timers ? view.timers.ringing.alarm : null
    // Room round the rows inside the list's clip. A row keeps its raised
    // parts (toggle, Delete, their shadows) 8 px inside its own rect, so the
    // only ink past it is a selected row's bevel, 1 px. Two pixels keep that,
    // and keep the fades' opaque ends out of the card's rounded corners --
    // the full shadow reach (6) puts the foot band's square end over them.
    readonly property real listSlack: 2
    listViewport: alarmFlick

    PlusButton {
        x: Math.round(view.side - view.padding - width - 4)
        y: Math.round(view.padding + 4)
        onClicked: {
            const d = new Date(view.timers.now() + 3600000);
            view.selected = view.timers.addAlarm(d.getHours(), 0, "", 0);
        }
    }

    Row {
        visible: !!view.ringing
        spacing: 8
        x: Math.round(view.cx - width / 2)
        y: view.innerY
        TimerButton {
            accent: true
            text: "Stop"
            onClicked: view.timers.dismiss("alarm")
        }
        TimerButton {
            text: "Snooze"
            visible: !!view.ringing && !view.ringing.missed
            onClicked: view.timers.snooze()
        }
    }

    // The list's clip is grown by `listSlack` on every side and the rows are
    // inset by it.
    Flickable {
        id: alarmFlick
        x: Math.round(view.padding - view.listSlack)
        y: Math.round(view.bandTop - view.listSlack)
        width: Math.round(view.side - 2 * view.padding + 2 * view.listSlack)
        height: Math.max(0, view.bandBottom - view.bandTop + 2 * view.listSlack)
        clip: true
        interactive: false
        contentWidth: width
        contentHeight: alarmCol.implicitHeight + 2 * view.listSlack

        Column {
            id: alarmCol
            x: view.listSlack
            y: view.listSlack
            width: alarmFlick.width - 2 * view.listSlack
            spacing: 4
            Repeater {
                model: view.timers ? view.timers.alarms : null
                delegate: Item {
                    id: row
                    // The roles through `model`: a role named `enabled` as a
                    // required property would BE Item.enabled, and a disabled
                    // alarm would disable its own row -- toggle included.
                    required property var model
                    readonly property string aid: row.model.aid
                    readonly property int hour: row.model.hour
                    readonly property int minute: row.model.minute
                    readonly property string label: row.model.label
                    readonly property int days: row.model.days
                    readonly property bool on: row.model.enabled
                    readonly property bool isSel: view.selected === row.aid
                    width: alarmCol.width
                    height: row.isSel ? 62 : 30

                    ShadowBox {
                        anchors.fill: parent
                        baseWidth: width
                        baseHeight: height
                        baseRadius: 10
                        visible: row.isSel
                        surfaceColor: Theme.listBox
                        backgroundColor: Theme.headerBox
                        bevelColor: Theme.headerBoxBevel
                        shadowColor: Theme.headerBoxShadow
                        bevelWidth: 1
                        shadowWidth: 3
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: view.selected = row.isSel ? "" : row.aid
                    }
                    // The time's ink follows the toggle, on its clock.
                    DigitCells {
                        x: 8
                        y: 5
                        text: Fmt.clock(row.hour, row.minute)
                        fontFamily: view.fontFamily
                        pixelSize: 17
                        color: Mix.c(Theme.textFaint, Theme.textPrimary, toggle.position)
                    }
                    Row {
                        x: 84
                        y: 7
                        spacing: 2
                        Repeater {
                            model: 7
                            delegate: Item {
                                id: day
                                required property int index
                                // Monday first; the bit is Date.getDay()'s.
                                readonly property int bit: 1 << ((day.index + 1) % 7)
                                readonly property bool lit: (row.days & day.bit) !== 0
                                property real hoverF: dayHit.containsMouse ? 1 : 0
                                Behavior on hoverF {
                                    NumberAnimation {
                                        duration: 160
                                        easing.type: Easing.OutCubic
                                    }
                                }
                                width: 16
                                height: 16
                                Rectangle {
                                    anchors.fill: parent
                                    radius: 5
                                    color: Theme.headerBox
                                    opacity: day.hoverF
                                }
                                Text {
                                    anchors.centerIn: parent
                                    text: view.dayLetters[day.index]
                                    color: day.lit ? Mix.c(Theme.accent, Theme.accentHover, day.hoverF)
                                                   : Mix.c(Theme.textFaint, Theme.textMuted, day.hoverF)
                                    font.family: view.fontFamily
                                    font.pixelSize: 11
                                    font.bold: day.lit
                                }
                                MouseArea {
                                    id: dayHit
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: view.timers.updateAlarm(row.aid, { days: row.days ^ day.bit })
                                }
                            }
                        }
                    }
                    Text {
                        visible: !row.isSel && row.label.length > 0
                        x: 84 + 7 * 18 + 8
                        y: 8
                        width: Math.max(0, toggle.x - x - 8)
                        elide: Text.ElideRight
                        text: row.label
                        color: Theme.textMuted
                        font.family: view.fontFamily
                        font.pixelSize: 11
                    }
                    // No day lit and no label: the alarm rings once.
                    Text {
                        visible: !row.isSel && row.label.length === 0 && row.days === 0
                        x: 84 + 7 * 18 + 8
                        y: 8
                        text: "once"
                        color: Theme.textFaint
                        font.family: view.fontFamily
                        font.pixelSize: 11
                    }
                    GrooveToggle {
                        id: toggle
                        x: Math.round(row.width - width - 8)
                        y: 6
                        surfaceColor: row.isSel ? Theme.headerBox : Theme.listBox
                        checked: row.on
                        onToggled: on => view.timers.setAlarmEnabled(row.aid, on)
                    }
                    // Selected: the label to edit, and removal.
                    TextField {
                        id: labelField
                        Keys.forwardTo: [labelKeys]
                        EditKeys {
                            id: labelKeys
                            target: labelField
                            selectAll: true          // a name field: Ctrl+A selects all, as the shell's other name fields
                        }
                        visible: row.isSel
                        x: 8
                        y: 32
                        width: row.width - 16 - delBtn.width - 8
                        height: 24
                        leftPadding: 8
                        text: row.label
                        placeholderText: "Label"
                        font.family: view.fontFamily
                        font.pixelSize: 12
                        color: Theme.textPrimary
                        placeholderTextColor: Theme.textFaint
                        background: ShadowBox {
                            baseWidth: parent.width
                            baseHeight: parent.height
                            baseRadius: 7
                            surfaceColor: Theme.headerBox
                            backgroundColor: Theme.panelSunk
                            bevelColor: Theme.bevel
                            shadowColor: Theme.border
                            bevelWidth: 1
                            shadowWidth: 2.5
                        }
                        onEditingFinished: view.timers.updateAlarm(row.aid, { label: text })
                    }
                    TimerButton {
                        id: delBtn
                        visible: row.isSel
                        x: Math.round(row.width - width - 8)
                        y: 31
                        height: 26
                        text: "Delete"
                        surfaceColor: Theme.headerBox
                        onClicked: {
                            view.selected = "";
                            view.timers.removeAlarm(row.aid);
                        }
                    }
                }
            }
        }
    }
    ScrollDressing {
        anchors.fill: alarmFlick
        flick: alarmFlick
        wheelEnabled: view.listWheelEnabled
        ground: Theme.listBox
        fadeHeight: 18
        // The content ends in `listSlack` of empty room: a band is fully on
        // by the time a row reaches the clip, so none is cut under part cover.
        rampLength: view.listSlack
    }
}
