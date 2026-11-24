pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"
import "../../../common/components"
import "SnapshotWords.js" as Words

// =============================================================================
// SnapshotsPage.qml -- the system update popup's secondary: the snapshots, newest first (docs/contracts/snapshots.md section 11).
//
//   service        the SnapshotService (or null)
//   fontFamily     the popup's face
//   runActive      an update is running: an undo cannot start
//   naturalHeight  what the page asks for (content only: the engine's cutout band is not in it)
//   implicitWidth  likewise
//   undoRequested(short)  the user chose to undo the update the snapshot `short` was taken before (the host starts the run)
//
// A drop-in: it reads the service and owns no work that outlives it (the undo plans, the busy state and the pending jobs are the
// service's). One card is open at a time; the newest opens by itself until the user picks another (or shuts it).
// =============================================================================
Item {
    id: root

    property var service: null
    property string fontFamily: "Inter"
    property bool runActive: false
    // Assigned by the engine while a content is faded out; unused here.
    property var secondaryKey: null

    // ---- the look (every one on the mockup's panel) ------------------------------------------------------------
    property real pageWidth: 380
    property real maxHeight: 560
    property real padding: 12
    property real cardGap: 8
    property real headGap: 12            // the head's last line to the first card: what stands between the last card and the foot
    property real peek: 38               // a list that goes on is cut inside a card, never between two: at least its title shows
    property real cardRadius: 10
    property int openMs: 260
    property real fadeHeight: 16

    readonly property var _rows: root.service && root.service.rows ? root.service.rows : []
    readonly property int _serial: root.service ? root.service.rowsSerial : 0
    readonly property string _phase: root.service ? root.service.phase : "unknown"
    readonly property bool _ready: root._phase === "ready"
    readonly property bool _busy: !!root.service && root.service.busy === true
    readonly property bool _creating: root._busy && root.service.busyKind === "create"

    // which card is open: "" = the newest (the default), "-" = none
    property string pick: ""
    readonly property string openShort: {
        if (root.pick === "-") return "";
        for (let i = 0; i < root._rows.length; i++)
            if (root._rows[i].short === root.pick) return root.pick;
        return root._rows.length > 0 ? root._rows[0].short : "";
    }

    BoundaryClock {
        id: clock
    }
    readonly property real nowMs: clock.now

    signal undoRequested(string short)
    // the cards, for a probe that proves a refresh keeps them (delegate identity)
    readonly property alias cards: cardsRepeater

    // ---- the words under the title ------------------------------------------------------------------------------
    readonly property string _summary: !root._ready ? ""
        : (root._rows.length === 0 ? "" : Words.summaryLine(root._rows, root.service.repoBytes))
    readonly property var _off: root.service && root._ready
        ? Words.offsiteLine(root.service.offsite, root.service.offsiteEnabled, root.nowMs, root.service.onBattery)
        : ({ text: "", figure: "", fraction: -1, nextMs: -1, tone: "" })
    on_OffChanged: clock.request(root._off.nextMs)
    readonly property string _error: root.service ? String(root.service.lastError) : ""
    readonly property string _empty: root._phase === "ready" ? (root._rows.length === 0 ? "No snapshots yet. One is taken before a big update." : "")
        : Words.NOT_SET_UP

    // ---- size ---------------------------------------------------------------------------------------------------
    property var _targets: ({})
    property real _targetSum: 0
    property int _targetSerial: 0
    function noteHeight(short: string, h: real): void {
        const t = root._targets;
        if (h > 0) t[short] = h;
        else delete t[short];
        let sum = 0, n = 0;
        for (let i = 0; i < root._rows.length; i++) {
            const v = t[root._rows[i].short];
            if (v !== undefined) { sum += v; n++; }
        }
        root._targetSum = sum + Math.max(0, n - 1) * root.cardGap;
        root._targetSerial++;
    }
    // Where a list that does not fit in `room` is cut: the lowest place that lies inside a card, below its title and above its foot. Cut in
    // the gap between two cards (or at a card's last pixels, under the fade) it reads as the end of the list.
    function _cutAt(room: real): real {
        let y = 0, best = -1;
        for (let i = 0; i < root._rows.length; i++) {
            const h = root._targets[root._rows[i].short];
            if (h === undefined) continue;
            const cut = Math.min(room, y + h - 10);
            if (cut >= y + root.peek) best = cut;
            y += h + root.cardGap;
            if (y > room) break;
        }
        return best > 0 ? best : room;
    }
    on_RowsChanged: root.noteHeight("", 0)
    readonly property real _headH: head.height
    readonly property real _bodyWant: root._rows.length > 0 ? root._targetSum : (root._empty.length > 0 ? emptyText.implicitHeight : 0)
    readonly property real _chrome: 2 * root.padding + root._headH + (root._bodyWant > 0 ? root.headGap : 0)
    readonly property real naturalHeight: Math.ceil(root._chrome + (root._chrome + root._bodyWant <= root.maxHeight ? root._bodyWant
        : (root._targetSerial, root._cutAt(root.maxHeight - root._chrome))))
    implicitWidth: root.pageWidth
    implicitHeight: root.naturalHeight

    // A progress groove: carved like the rest, the accent inside it.
    component Groove: Item {
        id: groove
        property real fraction: -1
        property real shown: Math.max(0, Math.min(1, groove.fraction))
        Behavior on shown { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        visible: groove.fraction >= 0
        width: parent ? parent.width : 0
        height: groove.visible ? 10 : 0
        ShadowBox {
            id: track
            y: 2
            width: parent.width
            height: 8
            baseRadius: 4
            surfaceColor: Theme.surface
            backgroundColor: Theme.listBox
            bevelColor: Theme.bevel
            shadowColor: Theme.border
            bevelWidth: 1
            shadowWidth: 2
        }
        Rectangle {
            x: 2
            y: track.y + 2
            width: groove.shown > 0 ? Math.max(height, (parent.width - 4) * groove.shown) : 0
            height: 4
            radius: 2
            color: Theme.accent
        }
    }

    // ---- head -----------------------------------------------------------------------------------------------------
    Column {
        id: head
        x: root.padding
        y: root.padding
        width: root.width - 2 * root.padding
        spacing: 3

        Item {
            width: parent.width
            height: root._ready ? 30 : 20
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Snapshots"
                color: Theme.textPrimary
                font.family: root.fontFamily
                font.pixelSize: 16
                font.bold: true
            }
            RaisedButton {
                anchors.right: parent.right
                visible: root._ready
                height: 28
                width: Math.ceil(implicitWidth)
                text: root._creating ? "Taking one..." : "Snapshot now"
                fontFamily: root.fontFamily
                surfaceColor: Theme.surface
                enabled: root._ready && !root._busy && !root.runActive
                onClicked: root.service.create()
            }
        }
        Text {
            visible: text.length > 0
            width: parent.width
            height: visible ? 15 : 0
            text: root._creating ? (root.service.createProgress >= 0 ? "Taking a snapshot, " + Math.round(root.service.createProgress * 100) + " %" : "Taking a snapshot...")
                : root._summary
            elide: Text.ElideRight
            color: Theme.textMuted
            font.family: root.fontFamily
            font.pixelSize: 11
        }
        Groove {
            fraction: root._creating ? root.service.createProgress : -1
        }
        Item {
            visible: root._off.text.length > 0
            width: parent.width
            height: visible ? Math.max(15, Math.ceil(offText.implicitHeight)) : 0
            Text {
                id: offText
                objectName: "offsiteLine"
                // wrapped at the width the page ASKS for: its height is part of what the page asks, and the live box follows that
                width: root.pageWidth - 2 * root.padding - (root._off.figure.length > 0 ? Math.ceil(offFigure.implicitWidth) + 8 : 0)
                text: root._off.text
                wrapMode: Text.WordWrap
                maximumLineCount: 4
                elide: Text.ElideRight
                color: root._off.tone === "bad" ? Theme.error : Theme.textMuted
                font.family: root.fontFamily
                font.pixelSize: 11
            }
            // the total stands still at the right edge; the first figure grows away from it
            Text {
                id: offFigure
                anchors.right: parent.right
                text: root._off.figure
                color: Theme.textMuted
                font.family: root.fontFamily
                font.pixelSize: 11
            }
        }
        Groove {
            fraction: root._off.fraction
        }
        Text {
            visible: text.length > 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: root._error
            color: Theme.error
            font.family: root.fontFamily
            font.pixelSize: 11
        }
    }

    Text {
        id: emptyText
        visible: root._rows.length === 0 && text.length > 0
        x: root.padding
        y: root.padding + head.height + root.headGap
        width: root.width - 2 * root.padding
        wrapMode: Text.WordWrap
        text: root._empty
        color: Theme.textMuted
        font.family: root.fontFamily
        font.pixelSize: 12
    }

    // ---- the cards ----------------------------------------------------------------------------------------------
    // The flick reaches 3 px past the cards on each side: a carved box draws its bevel outside its rect.
    Flickable {
        id: cardFlick
        x: root.padding - 3
        y: root.padding + head.height + root.headGap - 3
        width: root.width - 2 * root.padding + 6
        height: Math.max(0, root.height - y - root.padding + 3)
        visible: root._rows.length > 0
        clip: true
        interactive: false
        contentWidth: width
        contentHeight: cards.height + 6

        Column {
            id: cards
            x: 3
            y: 3
            width: cardFlick.width - 6
            spacing: root.cardGap
            Repeater {
                id: cardsRepeater
                model: root.service ? root.service.model : null
                delegate: SnapshotRow {
                    id: card
                    required property string short
                    width: cards.width
                    row: root.service.rowOf(card.short, root._serial)
                    plan: root.service.undoPlans[card.short] ?? null
                    open: root.openShort === card.short
                    runActive: root.runActive
                    busy: root._busy
                    nowMs: root.nowMs
                    fontFamily: root.fontFamily
                    cardRadius: root.cardRadius
                    openMs: root.openMs
                    onToggled: root.pick = card.open ? "-" : card.short
                    onWantsPlan: root.service.planUndo(card.short)
                    onTargetChanged: h => root.noteHeight(card.short, h)
                    onWakeAt: ms => clock.request(ms)
                    onUndoRequested: root.undoRequested(card.short)
                    onKeepRequested: on => root.service.keep(card.short, on)
                    onDeleteRequested: root.service.remove(card.short)
                }
            }
        }
    }
    ScrollDressing {
        anchors.fill: cardFlick
        flick: cardFlick
        ground: Theme.surface
        fadeHeight: root.fadeHeight
    }

    // the page opens on a fresh read; the service coalesces it
    Component.onCompleted: if (root.service) {
        root.service.refresh();
        root.service.look();
    }
}
