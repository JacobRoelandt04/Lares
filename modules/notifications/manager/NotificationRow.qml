pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../parts"
import ".."

// =============================================================================
// NotificationRow.qml -- one notification in the manager: the card on a
// SwipeVerbCard with the MANAGER's verbs:
//   swipe RIGHT = pin / unpin  (the card springs back; the row FLIES to its
//                              new place, RowFlight -- the manager's pinHandler)
//   swipe LEFT  = delete       (the card flies off; the row closes)
//                              (which side is which: notifications.jsonc manager.swipe)
//   click       = the sender's default action, else its window focused
//   chevron     = the body in full, in place (only when it was clipped)
//
// The row is a card of an AppBundleRow inside a ManagerSlot: the manager owns
// the wave, and a deleted row's slot closes on the list's clock while its card
// flies off.
// =============================================================================
SwipeVerbCard {
    id: row

    property string uid: ""
    property var service: null
    property var clock: null
    property Item overlayItem: null
    property GroupPalette groups: null
    property NotificationStyle style: null
    property real cardWidth: 396
    property color surfaceColor: Theme.surface
    property string footnote: ""
    property bool highlighted: false          // the keyboard's carved highlight
    // A bundle's head (AppBundleRow): the chevron opens the bundle instead of
    // the body, and the footnote counts what is folded under it.
    property int bundleMore: 0
    property bool bundleOpen: false
    // The uids of the app's whole bundle, newest first (the head only: what its delete takes).
    property var bundleUids: []
    signal bundleToggled()

    // THE DELETE VERB. A folded bundle's head ("+N more from App") stands for the whole app, so deleting it deletes
    // them all; one is deleted by unfolding the bundle first, where every card is its own. The swipe and the manager's Delete key both come here.
    function deleteAction() {
        if (!row.service)
            return;
        if (row.live) {                          // a hidden live record (NotificationService, LIVE): its verbs bring it back
            row.service.unhide(row.uid);
            return;
        }
        if (row.bundleMore > 0 && !row.bundleOpen && row.bundleUids.length > 1) {
            let refused = false;
            for (const u of row.bundleUids)
                if (!row.service.remove(u))
                    refused = true;
            if (refused)
                row.refuse(-1);
        } else if (!row.service.remove(row.uid) && row.kept) {
            row.refuse(-1);
        }
    }
    // function(uid, cardItem): the host flies the pin (RowFlight); null
    // toggles it in place.
    property var pinHandler: null

    // The record, re-read whenever the service says something changed, and
    // written only when it IS another record: the store bumps its serial once
    // per record it touches, and a binding re-assigning the same record would
    // notify every card of the list each time -- the whole card re-bound per
    // bump (an Undo of 13 rows: 103 record changes, 14 ms of its first frame).
    // Which record is shown is remembered as a FIELD of a plain
    // object: a `var` property hands back another wrapper than the object
    // written into it (d === store.get(uid) is false right after the
    // write), so comparing with `d` itself never matches. A record deleted
    // under the card (the swipe that deleted it, its app closing it) is KEPT:
    // the card shows its face while it flies off.
    property var d: null
    readonly property var _shown: ({ record: null })
    function _pull() {
        const r = row.service && row.uid !== "" ? row.service.store.get(row.uid) : null;
        if (r && r !== row._shown.record) {
            row._shown.record = r;
            row.d = r;
        }
    }
    onUidChanged: {
        row._pull();
        row._restoreExpanded();
    }
    onServiceChanged: row._pull()
    Connections {
        target: row.service
        ignoreUnknownSignals: true
        function onSerialChanged() {
            row._pull();
        }
    }
    Component.onCompleted: {
        row._pull();
        row._restoreExpanded();
    }
    // The body opened in full. Kept by the record in the manager's store
    // (`expandedStore`, uid -> true), not by this card: a pin re-keys the row
    // (a new card at the top of the group) and the flight lands on it, and
    // the user's expansion must land with it.
    property bool expanded: false
    property var expandedStore: null
    function _restoreExpanded() {
        const st = row.expandedStore;
        const want = !!st && row.uid !== "" && st[row.uid] === true;
        if (row.expanded !== want)
            row.expanded = want;
    }
    onExpandedChanged: {
        const st = row.expandedStore;
        if (!st || row.uid === "" || row.bundleMore > 0)
            return;
        if (row.expanded)
            st[row.uid] = true;
        else
            delete st[row.uid];
    }

    // A hidden live record (NotificationService, LIVE) has one verb both ways: back out as a toast.
    readonly property bool live: !!row.d && row.d.live === true
    readonly property var _swipe: row.service && row.service.config ? row.service.config.manager.swipe : ({ right: "pin", left: "delete" })
    function _verb(word: string): string {
        return row.live ? "unhide" : word === "delete" ? "delete" : row.d && row.d.pinned ? "unpin" : "pin";
    }
    rightVerb: row._verb(row._swipe.right)
    leftVerb: row._verb(row._swipe.left)
    rightFliesOff: row.live || row.rightVerb === "delete"
    leftFliesOff: row.live || row.leftVerb === "delete"
    // A KEPT record (a mounted drive's card) cannot be deleted: the swipe says no with the shared shake.
    readonly property bool kept: !!row.d && row.d.kept === true
    rightRefuses: row.kept && row.rightVerb === "delete"
    leftRefuses: row.kept && row.leftVerb === "delete"
    groundColor: row.surfaceColor
    radius: face.radius
    // The swipe's tuning, from the one style (the mockup's Swipe tab).
    commitFraction: row.style ? row.style.swipeCommitFraction : 0.4
    fadeFrom: row.style ? row.style.swipeFadeFrom : 0.45
    maxFraction: row.style ? row.style.swipeMaxFraction : 0.8
    flyMs: row.style ? row.style.swipeFlyMs : 260
    springMs: row.style ? row.style.swipeSpringMs : 260
    swingMs: row.style ? row.style.swipeSwingMs : 120
    flingPxPerS: row.style ? row.style.swipeFlingPxPerS : 900
    dragThreshold: row.style ? row.style.swipeDragThreshold : 6
    glyphSize: row.style ? row.style.swipeGlyphSize : 20
    glyphInset: row.style ? row.style.swipeGlyphInset : 12
    wellShadowWidth: row.style ? row.style.swipeWellShadowWidth : 4
    wellBevelWidth: row.style ? row.style.swipeWellBevelWidth : 1
    blockedGivePx: row.style ? row.style.swipeBlockedGivePx : 24

    implicitWidth: face.implicitWidth
    implicitHeight: face.implicitHeight

    // The face as it is drawn, for the pin flight's clone: it lifts off as
    // this card and lands as the card it flies to (otherwise a bundle
    // head's "+1 more" line and its chevron would come and go in one frame).
    readonly property string shownFootnote: face.footnote
    readonly property bool chevronShown: face.expandable && (face.chevronAlways || face.truncated || face.expanded)
    readonly property bool faceExpanded: face.expanded

    // The card reads its whole look from the one style (sizes, gaps, carve),
    // so the panel's card rows reach the manager as the toasts.
    NotificationCard {
        id: face
        d: row.d
        service: row.service
        clock: row.clock
        overlayItem: row.overlayItem
        style: row.style
        cardWidth: row.cardWidth
        groupColor: row.groups && row.d ? row.groups.color(row.d.group) : Theme.accent
        countdown: -1
        expandable: true
        chevronAlways: row.bundleMore > 0
        expanded: row.bundleMore > 0 ? row.bundleOpen : row.expanded
        footnote: row.bundleMore > 0 && !row.bundleOpen
            ? "+" + row.bundleMore + " more from " + (row.d ? row.d.appName : "") : row.footnote
        onExpandToggled: {
            if (row.bundleMore > 0)
                row.bundleToggled();
            else
                row.expanded = !row.expanded;
        }
    }

    // The keyboard's highlight: a carved accent rim round the card, one
    // eased presence fraction (never a colour Behavior).
    readonly property real _hlInset: row.style ? row.style.highlightInset : 2
    property real _hl: row.highlighted ? 1 : 0
    Behavior on _hl {
        NumberAnimation {
            duration: row.style ? row.style.highlightMs : 120
            easing.type: Easing.OutCubic
        }
    }
    Rectangle {
        anchors.fill: parent
        anchors.margins: -row._hlInset
        radius: face.radius + row._hlInset
        color: "transparent"
        border.width: row.style ? row.style.highlightWidth : 1.5
        border.color: Theme.accent
        opacity: row._hl * (row.style ? row.style.highlightAlpha : 0.8)
        visible: row._hl > 0.001
    }

    onClicked: {
        if (row.service && row.uid !== "")
            row.service.activate(row.uid);
    }
    onCommitted: dir => {
        if (!row.service)
            return;
        if (row.live) {
            row.service.unhide(row.uid);
            return;
        }
        if ((dir > 0 ? row.rightVerb : row.leftVerb) === "delete")
            row.deleteAction();
        else if (row.pinHandler)
            row.pinHandler(row.uid, row);
        else
            row.service.togglePin(row.uid);
    }
}
