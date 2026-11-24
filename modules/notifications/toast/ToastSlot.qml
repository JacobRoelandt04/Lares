pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../parts"
import ".."

// =============================================================================
// ToastSlot.qml -- one row of the toast stack: the entry, and the room it
// takes. The slot's height is its entry's height (plus the gap, carried on the
// side away from the bar) times ONE extent, eased on the stack's clock, so the
// rows around it and the host's box move together.
//
//   enter    extent 0 -> 1 and presence 0 -> 1: THE ARRIVAL. The card stands at
//            its resting place from the first frame and FADES IN there
//            (presence) while its room opens; it is neither slid in nor
//            revealed from the bar's side by a clip of its own (that was a
//            curtain coming down inside a box that, in a hand-over, hardly
//            moves: "the new toast appears from top to bottom"). What hides
//            it at first is what really covers that place: the host's box
//            edge while the box grows, and the rows next to it that are still
//            moving away. The card is a child of the slot with no clip, painted
//            below the row that follows it in the column (a later sibling), so
//            a neighbour that moves away UNCOVERS the newcomer and the newcomer
//            never paints over it. With the bar at the bottom the newest row is
//            the last, no neighbour lies over its place, and the card follows
//            its slot (a row under a leaving one is carried up by that one's
//            closing room, as before).
//   leave    `leaving` flips when the uid left the stack. HOW it leaves is
//            decided once the event that took it out has finished (`decide`,
//            a 0 ms timer): the service takes a uid off the stack FIRST and
//            only then deletes its record, so in the leaving change itself a
//            deleted record is still in the store and every exit would read as a
//            filing (a toast its app closed would fly off right, uncovering the
//            tray). So:
//              a swipe          already flew the card (its commit said which way);
//              still in store   it went to the manager -- a timeout, "+N more",
//                               a filing: it flies off right, as filed;
//              gone             its app closed it, it was deleted or clicked
//                               (consumed): it fades where it is (presence).
//   room     closes once the card HAS GONE -- a flown card on its landing, a
//            faded one at the end of its fade -- never on a timer of its own
//            (closed a fixed pause after the commit, a slow fly would have
//            the next toast slide up over the card still flying and its well,
//            and the card would be destroyed before it landed). `collapsing` is
//            when: from there the stack's height leaves the row out, so the
//            host's box and this room shrink on the same clock from the same
//            frame. Then `gone(uid)` asks the stack to drop the row.
//   hand-over a row that arrives while another row's card is still on its way out
//            WAITS (`waiting`: its room held at nothing, out of the stack's
//            height) and is that row's `heir`: when the leaving row's room
//            starts to close, the heir's room starts to open in the same turn,
//            both on one clock, and the host's box goes once from the old size
//            to the new (NotificationToast, THE HAND-OVER). `arrived()` and
//            `leavingStarted()` let the stack pair them; `hold()` turns a
//            fresh arrival (opened in this very turn, not yet moved) into an
//            heir when the row it replaces is marked leaving after it.
// =============================================================================
Item {
    id: slot

    required property int index
    required property string uid
    required property bool leaving

    property var service: null
    property var clock: null
    property Item overlayItem: null
    property NotificationStyle style: null
    property GroupPalette groups: null
    property color surfaceColor: Theme.surface
    property bool newestAtBottom: false
    // The stack's side cut (NotificationToast, THE ROWS' CLIP).
    property SideFade sideFade: null

    readonly property real gap: slot.style ? slot.style.toastGap : 6
    readonly property int enterMs: slot.style ? slot.style.enterMs : 260
    readonly property int presenceMs: slot.style ? slot.style.presenceMs : 160
    readonly property real entryHeight: entry.implicitHeight
    readonly property bool replyOpen: entry.replyOpen
    // The card, for the stack's gesture reader.
    readonly property SwipeVerbCard card: entry

    signal gone(string uid)
    // For the stack's hand-over: a row was made (it may set `waiting` in its handler), a row started to leave.
    signal arrived()
    signal leavingStarted()

    property real extent: 0
    property real presence: 0
    property int exitDir: 0          // +1 / -1 the side it flew off, 0 faded in place
    property bool collapsing: false  // the room is closing (the card has gone)
    // A flown card has landed (probes read it too).
    property bool landed: false
    // THE HAND-OVER: held at nothing until the row it replaces starts to close its room (out of the stack's height).
    property bool waiting: false
    // The row waiting for this one's room to start closing (a ToastSlot; a var: the type's own file).
    property var heir: null
    // With an heir waiting, the room starts to close once the card is THIS far out by its drawn extent (exitFraction):
    // an OutCubic fade is at presence 0.1 after 86 of its 160 ms, and waiting out the clock left the box standing
    // empty for ~60 ms before the newcomer came in (CLAUDE.md: a rule is timed on the drawn extent, not the clock).
    // A row that leaves with nobody waiting closes its room when the card has gone, as before.
    property real handoverShare: 0.9

    height: Math.round((entry.implicitHeight + slot.gap) * slot.extent)
    // The height the room has at extent 1, and what the stack's clip counts of this row (THE ROWS' CLIP, NotificationToast): an
    // arriving row counts whole from its first frame, so the clip never cuts the card standing at its place; a row whose room
    // is closing, or has not opened yet (an heir), counts what it draws.
    readonly property real restHeight: Math.round(entry.implicitHeight + slot.gap)
    readonly property real clipHeight: slot.collapsing || slot.waiting ? slot.height : slot.restHeight

    // HOW FAR THE EXIT HAS GONE, 0..1, read off the exit's own motion (the
    // stack's top fog follows it, NotificationToast): the share of the way a
    // flown card has travelled (SwipeVerbCard's fly-off goes to the width and
    // its radius), a faded one's 1 - presence. Both are OutCubic, so the share
    // is 1 - (1 - t)^3 of the exit's time and runs ahead of it: it is high
    // while the card is still there to be seen, which a fraction linear in time
    // is not (a quarter of the way through, the card has crossed 58 % of its
    // distance and is nearly out of the box). 0 for a row that is not leaving.
    readonly property real exitFraction: {
        if (!slot.leaving)
            return 0;
        const p = slot.exitDir === 0 ? 1 - slot.presence
            : Math.abs(entry.offset) / Math.max(1, slot.width + entry.radius);
        return Math.max(0, Math.min(1, p));
    }

    // The card: at its place whatever the room is (it overflows the slot while the room is small, and nothing here clips it).
    ToastEntry {
        id: entry
        y: slot.newestAtBottom ? slot.gap : 0
        width: slot.width
        uid: slot.uid
        service: slot.service
        clock: slot.clock
        overlayItem: slot.overlayItem
        groups: slot.groups
        style: slot.style
        sideFade: slot.sideFade
        cardWidth: slot.width
        surfaceColor: slot.surfaceColor
        opacity: slot.presence
        onCommitted: dir => {
            if (entry.fixed)
                return;
            slot.exitDir = dir;
            if (!slot.service)
                return;
            const verb = dir > 0 ? entry.rightVerb : entry.leftVerb;
            if (verb === "hide")
                slot.service.hide(slot.uid);
            else if (verb === "file")
                slot.service.file(slot.uid);
            else
                slot.service.remove(slot.uid);
        }
        onLanded: dir => {
            if (dir === 0)
                return;
            slot.landed = true;
            if (slot.leaving && !decide.running)
                slot._collapse();
        }
    }

    onExitFractionChanged: {
        if (slot.heir && slot.leaving && !slot.collapsing && slot.exitFraction >= slot.handoverShare)
            slot._collapse();
    }
    Component.onCompleted: {
        slot.arrived();
        if (!slot.waiting)
            enter.start();
    }
    onLeavingChanged: {
        if (slot.leaving) {
            slot.leavingStarted();
            decide.start();
        }
    }
    // Opened in this very turn and not moved yet: a first tick moves both off 0.
    function isFresh(): bool {
        return enter.running && slot.extent === 0 && slot.presence === 0 && !slot.waiting && !slot.leaving;
    }
    // A fresh arrival becomes an heir (the row it replaces was marked leaving after it, in the same turn).
    function hold(): void {
        enter.stop();
        slot.extent = 0;
        slot.presence = 0;
        slot.waiting = true;
    }
    // The room opens now (an heir, released by its row's close; never a row that left while it waited).
    function open(): void {
        if (slot.leaving)
            return;
        slot.waiting = false;
        enter.start();
    }
    // A room already closing goes on the clock of an arrival that starts now: what is left of it closes over the
    // arrival's own time, so every room of the stack eases from the same frame on the same curve as the host's box.
    function resyncClose(): void {
        if (!shrink.running)
            return;
        shrink.stop();
        shrink.start();
    }
    Timer {
        id: decide
        interval: 0
        onTriggered: slot._leave()
    }
    function _leave() {
        // An heir that leaves before its turn never showed: its room is nothing, it goes now.
        if (slot.waiting) {
            slot._collapse();
            return;
        }
        if (slot.exitDir === 0 && !entry.swiping && !entry.fixed && slot.service && slot.service.store.get(slot.uid)) {
            slot.exitDir = entry.fileDir;
            entry.flyOff(entry.fileDir, entry.live ? "hide" : "file");
        }
        if (slot.exitDir === 0) {
            enter.stop();
            fadeOut.start();
        } else if (slot.landed) {
            slot._collapse();
        }
    }
    function _collapse() {
        if (slot.collapsing)
            return;
        enter.stop();
        slot.collapsing = true;
    }

    ParallelAnimation {
        id: enter
        NumberAnimation {
            target: slot
            property: "extent"
            to: 1
            duration: slot.enterMs
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: slot
            property: "presence"
            to: 1
            duration: slot.presenceMs
            easing.type: Easing.OutCubic
        }
    }
    NumberAnimation {
        id: fadeOut
        target: slot
        property: "presence"
        to: 0
        duration: slot.presenceMs
        easing.type: Easing.OutCubic
        onFinished: slot._collapse()
    }
    // The room's close is its OWN animation, started from the `collapsing`
    // change: the stack's height drops on that change and the host starts its
    // box's resize clock in the same turn, and a clock started in a tick first
    // moves on the next one -- a close carried on inside another running
    // animation moves a tick earlier, and the room would lead the box by one frame
    // (34 px of a 70 px shrink on a 50 ms frame).
    //
    // `gone` comes from the shrink's finished handler. The lane closes on the
    // frame its last entry leaves and unloads the stack at the end of that
    // close, so a row may still be leaving when it is destroyed: the unload
    // cuts its exit, and nothing is left to drop (an exit ending in the very
    // tick the close ends must leave the log clean).
    onCollapsingChanged: {
        if (!slot.collapsing)
            return;
        shrink.start();
        // THE HAND-OVER: the heir's room opens in this turn, on the same clock as this one's close.
        const h = slot.heir;
        slot.heir = null;
        if (h && h.waiting)
            h.open();
    }
    NumberAnimation {
        id: shrink
        target: slot
        property: "extent"
        to: 0
        duration: slot.enterMs
        easing.type: Easing.OutCubic
        onFinished: slot.gone(slot.uid)
    }
}
