pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"
import "../../../common/components"
import "SnapshotWords.js" as Words

// =============================================================================
// SnapshotRow.qml -- one snapshot's card on the snapshots page: carved, one material with the rest.
//
//   shut    title, when, size                                  (every card but the open one)
//   open    + what the update changed (the notable packages, from -> to; a click unfolds EVERY changed package inside the card),
//           + Undo / Keep / Delete and the one line the undo's plan gives
//
// Two fractions drive every height: `openF` (the card opens) and `listF` (its package list unfolds); the drawn height is
// head + openF * body + openF * listF * list, so nothing is laid out under content that changes height. `targetHeight` is the same sum
// at the fractions' TARGETS: the page asks the engine for that one, which the animation cannot run ahead of.
//
// The row is a plain object (`row`) the service replaces on a refresh; the delegate lives on (the model keeps it by identity).
// =============================================================================
Item {
    id: card

    property var row: null
    property var plan: null              // the service's undoPlans[short]
    property bool open: false
    property bool runActive: false
    property bool busy: false            // an action of the service's is out
    property real nowMs: Date.now()
    property string fontFamily: "Inter"
    property real cardRadius: 10
    property real pad: 12
    property int openMs: 260
    property int listCap: 300
    property real rowH: 17

    signal toggled()
    signal undoRequested()
    signal keepRequested(bool on)
    signal deleteRequested()
    signal wantsPlan()
    // The card's target height changed: the page sums them.
    signal targetChanged(real h)

    readonly property bool _has: !!card.row
    readonly property var _changed: card._has ? card.row.changed : []
    readonly property var _notable: card._has ? card.row.notable : []
    // what the list unfolds to: every changed package the notable lines above do not already say
    readonly property var _rest: {
        const names = {};
        for (const n of card._notable) names[n.name] = true;
        return card._changed.filter(c => !names[c.name]);
    }
    readonly property int _more: card._rest.length
    readonly property real _inner: card.width - 2 * card.pad
    property bool listOpen: false

    readonly property real headH: card.pad + 18 + 3 + 15 + card.pad
    readonly property real _planH: Math.ceil(planText.implicitHeight)
    // what an undo does is said while it can be done (and while that is being worked out, so the card does not grow under the pointer)
    readonly property bool _says: !card.runActive && (!card.plan || card.plan.state === "loading" || Words.undoable(card.plan))
    readonly property real _sayH: card._says ? Math.ceil(sayText.implicitHeight) + 2 : 0
    readonly property real _listGap: card._notable.length + card._more > 0 ? 8 : 6
    readonly property real bodyH: (card._has && card.row.unfinished ? 18 : 0)
        + card._notable.length * card.rowH + (card._more > 0 ? card.rowH : 0)
        + card._listGap + 30 + 6 + card._planH + card._sayH + 4
    readonly property real listH: Math.min(card._rest.length, card.listCap) * 16 + (card._rest.length > card.listCap ? 16 : 0) + 4
    readonly property real targetHeight: card.headH + (card.open ? card.bodyH + (card.listOpen ? card.listH : 0) : 0)

    property real openF: card.open ? 1 : 0
    Behavior on openF { NumberAnimation { duration: card.openMs; easing.type: Easing.OutCubic } }
    property real listF: card.open && card.listOpen ? 1 : 0
    Behavior on listF { NumberAnimation { duration: card.openMs; easing.type: Easing.OutCubic } }

    height: Math.round(card.headH + card.openF * card.bodyH + card.openF * card.listF * card.listH)
    onTargetHeightChanged: card.targetChanged(card.targetHeight)
    Component.onCompleted: {
        card.targetChanged(card.targetHeight);
        if (card.open) card.wantsPlan();
    }
    Component.onDestruction: card.targetChanged(0)
    onOpenChanged: {
        if (card.open) card.wantsPlan();
        else card.listOpen = false;
    }

    // the mockup's panel and the page read the card's words from here
    readonly property var _when: card._has ? Words.whenText(card.row.timeMs, card.nowMs) : ({ text: "", nextMs: -1 })
    signal wakeAt(real ms)
    on_WhenChanged: card.wakeAt(card._when.nextMs)

    ShadowBox {
        anchors.fill: parent
        baseRadius: card.cardRadius
        surfaceColor: Theme.surface
        backgroundColor: Theme.listBox
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        bevelWidth: 1
        shadowWidth: 3
    }

    Item {
        id: clipBox
        anchors.fill: parent
        anchors.margins: 2
        clip: true

        // ---- head: the whole head toggles ---------------------------------------------------------------------
        Item {
            id: head
            x: card.pad - 2
            y: card.pad - 2
            width: card._inner
            height: 18 + 3 + 15

            Text {
                id: titleText
                anchors.left: parent.left
                anchors.right: marks.left
                anchors.rightMargin: 8
                height: 18
                verticalAlignment: Text.AlignVCenter
                text: card._has ? card.row.title : ""
                elide: Text.ElideRight
                color: Theme.textPrimary
                font.family: card.fontFamily
                font.pixelSize: 12
                font.bold: true
            }
            Row {
                id: marks
                anchors.right: parent.right
                height: 18
                spacing: 4
                Repeater {
                    model: card._has ? [card.row.keep ? "kept" : "", card.row.offsite ? "Proton" : ""].filter(s => s !== "") : []
                    delegate: Rectangle {
                        id: mark
                        required property string modelData
                        height: 14
                        y: 2
                        width: Math.ceil(markText.implicitWidth) + 10
                        radius: 7
                        color: Theme.headerBox
                        Text {
                            id: markText
                            anchors.centerIn: parent
                            text: mark.modelData
                            color: Theme.textMuted
                            font.family: card.fontFamily
                            font.pixelSize: 10
                        }
                    }
                }
            }
            Text {
                id: whenText
                y: 21
                height: 15
                text: card._when.text
                color: Theme.textMuted
                font.family: card.fontFamily
                font.pixelSize: 11
            }
            Text {
                y: 21
                height: 15
                anchors.right: parent.right
                text: card._has ? Words.sizeText(card.row.addedBytes) : ""
                color: Theme.textFaint
                font.family: card.fontFamily
                font.pixelSize: 11
            }
            MouseArea {
                anchors.fill: parent
                onClicked: card.toggled()
            }
        }

        // ---- body ------------------------------------------------------------------------------------------------
        Item {
            id: body
            x: card.pad - 2
            y: card.headH - card.pad + 4 - 2
            width: card._inner
            height: card.bodyH
            opacity: card.openF
            visible: card.openF > 0.001

            Text {
                id: unfinishedText
                visible: card._has && card.row.unfinished
                height: visible ? 18 : 0
                width: parent.width
                text: "Update did not finish"
                color: Theme.error
                font.family: card.fontFamily
                font.pixelSize: 11
                font.bold: true
            }
            Column {
                id: notableCol
                y: unfinishedText.height
                width: parent.width
                Repeater {
                    model: card._notable
                    delegate: Item {
                        id: nrow
                        required property var modelData
                        width: notableCol.width
                        height: card.rowH
                        Text {
                            anchors.left: parent.left
                            anchors.right: ver.left
                            anchors.rightMargin: 8
                            height: parent.height
                            verticalAlignment: Text.AlignVCenter
                            text: nrow.modelData.name
                            elide: Text.ElideRight
                            color: Theme.textPrimary
                            font.family: card.fontFamily
                            font.pixelSize: 11
                        }
                        Text {
                            id: ver
                            anchors.right: parent.right
                            height: parent.height
                            verticalAlignment: Text.AlignVCenter
                            width: Math.min(Math.ceil(implicitWidth), parent.width * 0.6)
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideLeft
                            text: nrow.modelData.from && nrow.modelData.to ? nrow.modelData.from + " → " + nrow.modelData.to
                                : (nrow.modelData.to ? "new " + nrow.modelData.to : (nrow.modelData.from ? "removed" : ""))
                            color: Theme.textMuted
                            font.family: card.fontFamily
                            font.pixelSize: 11
                        }
                    }
                }
                Item {
                    visible: card._more > 0
                    width: notableCol.width
                    height: visible ? card.rowH : 0
                    Text {
                        height: parent.height
                        verticalAlignment: Text.AlignVCenter
                        text: card.listOpen ? "fewer" : (card._notable.length === 0 ? card._more + (card._more === 1 ? " package changed" : " packages changed") : "and " + card._more + " more")
                        color: Theme.accent
                        font.family: card.fontFamily
                        font.pixelSize: 11
                    }
                }
            }
            // a click on the list unfolds every changed package
            MouseArea {
                x: 0
                y: unfinishedText.height
                width: parent.width
                height: notableCol.height
                enabled: card._more > 0
                onClicked: card.listOpen = !card.listOpen
            }

            // ---- the unfolded list: every changed package, under a fraction ---------------------------------------
            Item {
                id: listBox
                y: unfinishedText.height + notableCol.height
                width: parent.width
                height: card.listH * card.listF
                clip: true
                opacity: card.listF
                visible: card.listF > 0.001
                Loader {
                    active: card.listF > 0.001 || card.listOpen
                    sourceComponent: Column {
                        width: listBox.width
                        Repeater {
                            model: Math.min(card._rest.length, card.listCap)
                            delegate: Item {
                                id: crow
                                required property int index
                                readonly property var c: card._rest[crow.index]
                                width: listBox.width
                                height: 16
                                Text {
                                    anchors.left: parent.left
                                    anchors.right: cv.left
                                    anchors.rightMargin: 8
                                    height: parent.height
                                    verticalAlignment: Text.AlignVCenter
                                    text: crow.c.name
                                    elide: Text.ElideRight
                                    color: Theme.textMuted
                                    font.family: card.fontFamily
                                    font.pixelSize: 11
                                }
                                Text {
                                    id: cv
                                    anchors.right: parent.right
                                    height: parent.height
                                    verticalAlignment: Text.AlignVCenter
                                    width: Math.min(Math.ceil(implicitWidth), parent.width * 0.55)
                                    horizontalAlignment: Text.AlignRight
                                    elide: Text.ElideLeft
                                    text: crow.c.from && crow.c.to ? crow.c.from + " → " + crow.c.to : (crow.c.to ? "new " + crow.c.to : "removed")
                                    color: Theme.textFaint
                                    font.family: card.fontFamily
                                    font.pixelSize: 11
                                }
                            }
                        }
                        Text {
                            visible: card._rest.length > card.listCap
                            height: visible ? 16 : 0
                            text: "and " + (card._rest.length - card.listCap) + " more"
                            color: Theme.textFaint
                            font.family: card.fontFamily
                            font.pixelSize: 11
                        }
                    }
                }
            }

            // ---- the buttons and the plan, hung under the list ----------------------------------------------------
            Item {
                id: foot
                y: listBox.y + listBox.height + card._listGap
                width: parent.width
                height: 30 + 6 + card._planH + card._sayH
                Row {
                    id: buttons
                    spacing: 8
                    height: 30
                    RaisedButton {
                        id: undoBtn
                        objectName: "undoButton"
                        text: "Undo"
                        height: 30
                        width: Math.ceil(implicitWidth)
                        fontFamily: card.fontFamily
                        surfaceColor: Theme.listBox
                        enabled: !card.runActive && !card.busy && Words.undoable(card.plan)
                        onClicked: card.undoRequested()
                    }
                    RaisedButton {
                        objectName: "keepButton"
                        text: card._has && card.row.keep ? "Don't keep" : "Keep"
                        height: 30
                        width: Math.ceil(implicitWidth)
                        fontFamily: card.fontFamily
                        surfaceColor: Theme.listBox
                        enabled: !card.busy
                        onClicked: card.keepRequested(!(card._has && card.row.keep))
                    }
                }
                // away from the two that take nothing
                RaisedButton {
                    objectName: "deleteButton"
                    anchors.right: parent.right
                    visible: card._has && !card.row.keep
                    text: "Delete"
                    height: 30
                    width: Math.ceil(implicitWidth)
                    fontFamily: card.fontFamily
                    surfaceColor: Theme.listBox
                    enabled: !card.busy && !card.runActive
                    onClicked: card.deleteRequested()
                }
                Text {
                    id: planText
                    objectName: "planLine"
                    y: 36
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: card.runActive ? "An update is running." : Words.planLine(card.plan)
                    color: Theme.textMuted
                    font.family: card.fontFamily
                    font.pixelSize: 11
                }
                Text {
                    id: sayText
                    visible: card._says
                    y: 36 + card._planH + 2
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: Words.UNDO_SENTENCE
                    color: Theme.textFaint
                    font.family: card.fontFamily
                    font.pixelSize: 11
                }
            }
        }
    }
}
