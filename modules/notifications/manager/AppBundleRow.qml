pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../parts"
import "../parts/ModelSync.js" as ModelSync

// =============================================================================
// AppBundleRow.qml -- one entry of a group: ONE app's notifications, newest
// first -- a single notification is a bundle of one (bundling by
// app, manager only: an app keeps ONE row whatever it holds, so a
// second notification of the app turns the row into a bundle IN PLACE: the
// head card takes the newest record and says "+1 more", nothing leaves and
// nothing is re-added).
//
// Folded, it is the newest card with "+N more from App" and a chevron; the
// chevron unfolds the rest under it in place, newest first. Every card is
// still its own notification: a swipe on the head acts on the newest alone
// and the next one becomes the head -- one verb, one meaning, everywhere.
//
// THE PILE. The head lies on the rest of the bundle, and when it goes the
// next card is there under it: while the head card is AWAY
// -- flying off after a delete, or standing in for a pin flight's clone
// (`suppressedUid`: the clone draws it) -- it keeps the record it showed, and
// a second card under it shows the next one. So
//   - a head deleted by a swipe flies off with ITS record on it, and the next
//     card is already there where it lay (flying the next record off would
//     leave the row blank);
//   - a head pinned away lifts off the next card (the clone swings back over
//     it, lifts and flies); the row keeps its card and its place;
//   - a record unpinned into its app's row as the head lands ON the card that
//     was there: until the clone lands, the row shows the pile as it was --
//     the card under it says what it said before (it does not count the head
//     flying in: counted, its "+1 more" would come at the commit, cut by the room),
//     and the head's room opens for it as the clone comes in, to the card the
//     clone lands as (the clone brings the "+1 more" and the chevron with it:
//     the manager's pin flight). A card under it taller than that is cut by
//     the room as it closes; the clone lands over the rest.
// When the head comes back (it landed, the flight is over) it takes the pile's
// top again and the card under it goes. The pile's room follows the card that
// is drawn (the head's, while it flies in): an EaseBox, so a step (the
// footnote gone with the head, or the head's room opening) eases instead of
// moving the popup's foot in one frame.
//
// AN OPEN BUNDLE IS A COLUMN, not a pile: its cards stand one under the
// other, so while its head is away the next card stands where the column puts
// it -- under the head's room, which closes as the head goes (pinned away on
// the flight's reveal, swiped off on the pile's own clock) and opens as it
// flies in (unpinned onto it, on the reveal). That card is the member it was
// (or will be) at the same place: its member's room is handed to the pile at
// once when it goes up and back when it comes down at the landing
// (EaseBox.carry), so the column never steps, and a head swiped off lets the
// next card take the head only once it has risen there (otherwise the
// member's slot would stand empty under the lifted clone -- or under the flying
// face -- while its card is drawn at the head's place; flown in, the card
// would be covered at the top and grow in again under the landed head).
//
// Unfolding and folding are THE LIST'S WAVE (an unfold follows like a group's,
// and the staggered exit holds while a group of notifications is expanded). Every
// member is a ManagerSlot of its own, in the TAIL of the entry's slot
// (`tailHost`: the head's slot, ManagerSlot), so an unfold hands the new members
// to the wave (they come in from the left on the stagger, the tail below the
// fold placed, the view following them at the list's foot like a group opened
// there), a fold hands them out, and an accordion or a Clear all that takes the
// whole row takes its head and its members as separate rows, each on its own
// step -- never the bundle as one block with its cards riding inside it. The
// bundle only says WHEN a member is born, leaves or comes back (`memberBorn` /
// `memberLeft` / `memberReturned`); the section decides what the wave does with
// it. A PIN FLIGHT owns the members it touches: the member it lifts is a hole
// that closes on the flight's reveal, a member that moved up to the head is
// not drawn twice, and a record unpinned into a FOLDED bundle opens it -- it
// lands on its own card, which a folded bundle does not draw.
// =============================================================================
Column {
    id: bundle

    property string uidList: ""              // newest first, "|"-joined (a ListModel
                                             // role may not hold an array)
    readonly property var uids: bundle.uidList === "" ? [] : bundle.uidList.split("|")
    property var service: null
    property var clock: null
    property Item overlayItem: null
    property GroupPalette groups: null
    property NotificationStyle style: null
    property real cardWidth: 396
    property color surfaceColor: Theme.surface
    property real gap: 6
    property bool open: false
    property bool highlighted: false          // the keyboard's highlight on the head
    property int presenceMs: 160
    // A step of a card's height eases over this (EaseBox).
    property int resizeMs: 260
    // The pin flight's key ("" none): the clone stands in for the card that
    // shows it -- and its share of the destination (`flightReveal`).
    property string suppressedUid: ""
    property real flightReveal: 1
    // function(uid, cardItem): the host flies a pin; null toggles in place.
    property var pinHandler: null
    // The list's side cut and fade, for every card of the bundle.
    property SideFade sideFade: null
    // uid -> true: the cards whose body is open in full (the manager's).
    property var expandedStore: null
    // The row is on its way out: a head that lands from a fly-off stays gone.
    property bool leaving: false
    // Where the members go: the entry's slot's tail (null: under the head, in
    // this Column). The entry's place in its section, for the members' order.
    property Item tailHost: null
    property int ownerIndex: 0
    // What the members' rows fade into at a moving edge, and how far (ManagerSlot).
    property real fogPx: 34
    // What an unfold opens under (the entry's slot) and where that header may
    // rise to (ListWave's `waveKeep` / `waveTopPx`).
    property Item keepItem: null
    property real followTopPx: -1
    // function(): the host takes the chevron (it hands the wave the members);
    // null opens and folds in place.
    property var toggleHandler: null

    // A member is born, leaves, comes back: the host decides how the list moves
    // it. `opening`: born because the bundle was just opened.
    signal memberBorn(var member, bool opening)
    signal memberLeft(var member)
    signal memberReturned(var member)
    // A member has collapsed (the host drops an entry whose members are gone).
    signal memberSettled()

    // Which way the head was swiped off (the slot keeps a flown card where it
    // is while the list's wave takes its room: ManagerSlot).
    readonly property int flownSign: headRow.flownSign

    spacing: 0

    // ---- the pile --------------------------------------------------------------------
    property string _headUid: ""
    property int _headMore: 0
    readonly property bool _away: (bundle.suppressedUid !== "" && bundle._headUid === bundle.suppressedUid)
        || headRow.flownSign !== 0
    readonly property string _underUid: {
        if (!bundle._away)
            return "";
        for (const u of bundle.uids)
            if (u !== bundle._headUid)
                return u;
        return "";
    }
    // The pile as drawn: under a head that is away, what is left of it.
    readonly property var _pile: bundle._underUid !== "" ? bundle.uids.filter(u => u !== bundle._headUid) : bundle.uids
    // The head is flying IN: the flight's record, in the pile (unpinned onto
    // it). Its room is the flight's destination.
    readonly property bool _incoming: bundle.suppressedUid !== "" && bundle._headUid === bundle.suppressedUid
        && bundle.uids.indexOf(bundle._headUid) >= 0
    // THE COLUMN (see the head): an open bundle whose head a flight has away.
    // The card under it stands at the foot of the pile's room. Handlers ask
    // `_isColumn()`, from the sources: inside the change that moves them the
    // binding may still be the previous generation's (CLAUDE.md).
    readonly property bool _column: bundle.open && bundle._underUid !== ""
        && (bundle.suppressedUid !== "" || headRow.flownSign !== 0)
    function _isColumn() {
        return bundle.open && bundle._underUid !== "" && (bundle.suppressedUid !== "" || headRow.flownSign !== 0);
    }
    // The flight is this bundle's: its record is here, or it is the head the
    // flight took away.
    readonly property bool _flightHere: bundle.suppressedUid !== ""
        && (bundle.uids.indexOf(bundle.suppressedUid) >= 0 || bundle._headUid === bundle.suppressedUid)

    function _syncHead() {
        const top = bundle.uids.length > 0 ? bundle.uids[0] : "";
        // An away head keeps its record while that record is gone from the
        // pile: it is flying off, or it is the flight's (pinned away). Read
        // from its sources, not from `_away`: this runs inside the change of
        // one of them, where that binding may still be the previous
        // generation's (CLAUDE.md).
        const away = (bundle.suppressedUid !== "" && bundle._headUid === bundle.suppressedUid) || headRow.flownSign !== 0;
        if (away && bundle.uids.indexOf(bundle._headUid) < 0)
            return;
        if (top !== bundle._headUid) {
            bundle._headUid = top;
            if (headRow.offset !== 0 || headRow.swiping)
                headRow.reset();
        }
        bundle._headMore = Math.max(0, bundle.uids.length - 1);
    }
    // The flown head has landed off the list: the next record is the head --
    // in a column once it has risen into the head's place.
    property bool _landWait: false
    function _headLanded() {
        if (headRow.flownSign === 0 || bundle.leaving)
            return;
        if (bundle._isColumn() && pileBox.easing) {
            bundle._landWait = true;
            return;
        }
        bundle._landWait = false;
        headRow.reset();
        bundle._syncHead();
    }
    Connections {
        target: pileBox
        function onEasingChanged() {
            if (!pileBox.easing && bundle._landWait)
                bundle._headLanded();
        }
    }

    EaseBox {
        id: pileBox
        ms: bundle.resizeMs
        groundColor: bundle.surfaceColor
        fogPx: bundle.fogPx
        // A step the flight makes (the footnote gone with the head lifted
        // off) is its hole: it closes as the flight's destination opens.
        driver: bundle._flightHere ? bundle.flightReveal : -1

        Item {
            id: pile
            width: bundle.cardWidth
            implicitHeight: !underLoader.item ? headRow.implicitHeight
                : bundle._column ? (bundle._incoming ? headRow.implicitHeight + bundle.gap : 0) + (underLoader.item as Item).implicitHeight
                : !bundle._incoming ? (underLoader.item as Item).implicitHeight
                : headRow.implicitHeight

            // Cut by the room only while it closes over a card taller than the
            // head flying in (the bevel's slack kept on the top and sides).
            Item {
                x: -pileBox.slack
                y: -pileBox.slack
                width: bundle.cardWidth + 2 * pileBox.slack
                height: pileBox.height + pileBox.slack
                clip: bundle._incoming && !!underLoader.item && (underLoader.item as Item).implicitHeight > pileBox.height + 0.5

                Loader {
                    id: underLoader
                    x: pileBox.slack
                    y: pileBox.slack + (bundle._column && item ? Math.max(0, pileBox.height - (item as Item).implicitHeight) : 0)
                    active: bundle._underUid !== ""
                    sourceComponent: Component {
                        NotificationRow {
                            uid: bundle._underUid
                            service: bundle.service
                            clock: bundle.clock
                            overlayItem: bundle.overlayItem
                            groups: bundle.groups
                            cardWidth: bundle.cardWidth
                            style: bundle.style
                            surfaceColor: bundle.surfaceColor
                            // The pile as it lies under the away head: a record
                            // flying in is not counted until it lands (the clone
                            // brings the line). In a column it keeps the face it
                            // had until the flight is over: a member's going up
                            // (it becomes the head at the landing), the head's
                            // going down.
                            bundleMore: bundle._column && !bundle._incoming ? 0 : Math.max(0, bundle._pile.length - 1)
                            bundleOpen: bundle.open
                            dragEnabled: false
                            sideFade: bundle.sideFade
                            expandedStore: bundle.expandedStore
                        }
                    }
                }
            }

            NotificationRow {
                id: headRow
                uid: bundle._headUid
                service: bundle.service
                clock: bundle.clock
                overlayItem: bundle.overlayItem
                groups: bundle.groups
                cardWidth: bundle.cardWidth
                style: bundle.style
                surfaceColor: bundle.surfaceColor
                highlighted: bundle.highlighted
                bundleMore: bundle._headMore
                bundleOpen: bundle.open
                bundleUids: bundle.uids
                pinHandler: bundle.pinHandler
                sideFade: bundle.sideFade
                expandedStore: bundle.expandedStore
                faceHidden: bundle.suppressedUid !== "" && bundle.suppressedUid === headRow.uid
                onBundleToggled: {
                    if (bundle.toggleHandler)
                        bundle.toggleHandler();
                    else
                        bundle.open = !bundle.open;
                }
                onLanded: dir => {
                    if (dir !== 0)
                        Qt.callLater(bundle._headLanded);
                }
            }
        }
    }

    ListModel {
        id: members
        // { key: uid, leaving }
    }
    // The column's card under the away head: at the landing of a head flown
    // in, it comes down to its member's place (`_handDown`, read by the member
    // built for it in this sync).
    property string _columnUnder: ""
    property string _handDown: ""
    property bool _wasOpen: false
    property bool _opening: false
    function _sync() {
        bundle._handDown = bundle._columnUnder !== "" && bundle._underUid !== bundle._columnUnder ? bundle._columnUnder : "";
        bundle._columnUnder = bundle._isColumn() ? bundle._underUid : "";
        // Members born because the bundle was just opened come in on the wave;
        // one born because a record joined an open bundle arrives in place.
        bundle._opening = bundle.open && !bundle._wasOpen;
        bundle._wasOpen = bundle.open;
        ModelSync.sync(members, bundle.open ? bundle._pile.slice(1) : [], null, true);
        bundle._opening = false;
        bundle._handDown = "";
    }
    property var _prevUids: []
    onUidsChanged: {
        const was = bundle._prevUids;
        bundle._prevUids = bundle.uids;
        // Unpinned into this bundle under its head while it is folded: open
        // it, so the record lands on its own card.
        const u = bundle.suppressedUid;
        if (u !== "" && !bundle.open && bundle.uids.indexOf(u) > 0 && was.indexOf(u) < 0)
            bundle.open = true;
        // A bundle that shrank to one folds: there is nothing left under the head.
        if (bundle.uids.length <= 1 && bundle.open)
            bundle.open = false;
        bundle._syncHead();
    }
    onSuppressedUidChanged: bundle._syncHead()
    on_PileChanged: bundle._sync()
    onOpenChanged: bundle._sync()
    Component.onCompleted: {
        bundle._prevUids = bundle.uids;
        bundle._syncHead();
        bundle._sync();
    }

    // One deferred drain for every member that has closed (Qt.callLater
    // keeps only the last arguments of a function called twice in a turn).
    property var _dropQueue: []
    function _dropLater(key) {
        bundle._dropQueue.push(key);
        Qt.callLater(bundle._drainDrops);
    }
    function _drainDrops() {
        const keys = bundle._dropQueue;
        bundle._dropQueue = [];
        for (const k of keys) {
            for (let i = 0; i < members.count; i++) {
                if (members.get(i).key === k && members.get(i).leaving) {
                    members.remove(i);
                    break;
                }
            }
        }
    }
    // Where the card that will show `uid` RESTS in the bundle, its top: the
    // head at 0, a member under the pile and the members before it. Summed,
    // not read off the member: one opening from nothing has no place in the
    // Column yet (a Column does not lay out a child of no height, CLAUDE.md),
    // and a flight landing on it would measure the stale one (a card too high).
    function restTopOf(uid) {
        if (headRow.uid === uid && bundle.uids.indexOf(uid) >= 0)
            return 0;
        let y = pileBox.target;
        for (let i = 0; i < members.count; i++) {
            const r = members.get(i);
            if (r.leaving)
                continue;
            if (r.key === uid)
                return y + bundle.gap;
            const c = bundle._cards[r.key];
            y += (c ? c.implicitHeight : 0) + bundle.gap;
        }
        return NaN;
    }
    // The card showing `uid` -- the head, or an unfolded member -- or null.
    // The head only while the record IS the pile's (an away head keeps a
    // record that has gone elsewhere).
    property var _cards: ({})
    function cardFor(uid) {
        if (uid === "")
            return null;
        if (headRow.uid === uid && bundle.uids.indexOf(uid) >= 0)
            return headRow;
        for (let i = 0; i < members.count; i++) {
            const r = members.get(i);
            if (r.key === uid && !r.leaving)
                return bundle._cards[uid] || null;
        }
        return null;
    }

    // The member slots now, in layout order (those on their way out too when
    // `withLeaving`).
    function memberSlots(withLeaving) {
        const out = [];
        for (let i = 0; i < memberRep.count; i++) {
            const m = memberRep.itemAt(i) as ManagerSlot;
            if (m && (withLeaving || !members.get(i).leaving))
                out.push(m);
        }
        return out;
    }
    // Every member is out of the list's sight (collapsed): the entry may go.
    function tailGone() {
        for (let i = 0; i < memberRep.count; i++) {
            const m = memberRep.itemAt(i) as ManagerSlot;
            if (m && m.rowState !== "collapsed")
                return false;
        }
        return true;
    }
    // Every member at once, no wave: "rest" or "collapsed".
    function setMembers(state) {
        for (const m of bundle.memberSlots(false)) {
            m.place();
            m.rowState = state;
        }
    }

    Repeater {
        id: memberRep
        parent: bundle.tailHost ? bundle.tailHost : bundle
        model: members
        ManagerSlot {
            id: member
            required property int index
            required property string key
            required property bool leaving
            // A pin flight's: the destination opening as the clone comes in,
            // or the hole it lifted a card out of, closing on the same share.
            property bool flightDest: false
            property bool hole: false
            // A member that moved up to the head is drawn there, not twice.
            readonly property bool promoted: member.leaving
                && (member.key === bundle._underUid || member.key === headRow.uid)
            width: bundle.cardWidth
            gapAbove: 0
            gapBelow: bundle.gap
            arriveMs: bundle.resizeMs
            presenceMs: bundle.presenceMs
            groundColor: bundle.surfaceColor
            fogPx: bundle.fogPx
            order: bundle.ownerIndex + (member.index + 1) / 1000
            waveKeep: bundle.keepItem
            waveTopPx: bundle.followTopPx
            reveal: member.flightDest ? bundle.flightReveal : member.hole ? 1 - bundle.flightReveal : 1

            EaseBox {
                id: cardBox
                ms: bundle.resizeMs
                groundColor: bundle.surfaceColor
                fogPx: bundle.fogPx

                NotificationRow {
                    id: card
                    uid: member.key
                    service: bundle.service
                    clock: bundle.clock
                    overlayItem: bundle.overlayItem
                    groups: bundle.groups
                    cardWidth: bundle.cardWidth
                    style: bundle.style
                    surfaceColor: bundle.surfaceColor
                    pinHandler: bundle.pinHandler
                    sideFade: bundle.sideFade
                    expandedStore: bundle.expandedStore
                    faceHidden: bundle.suppressedUid !== "" && bundle.suppressedUid === member.key
                    opacity: member.hole || member.promoted ? 0 : 1
                }
            }

            Component.onCompleted: {
                bundle._cards[member.key] = card;
                if (bundle.suppressedUid !== "" && bundle.suppressedUid === member.key) {
                    // The flight's destination: at rest, opened by the flight.
                    member.flightDest = true;
                    member.rowState = "rest";
                } else if (member.key === bundle._handDown) {
                    // Down from the column's pile, where it stood: its room
                    // comes with it, at once.
                    member.rowState = "rest";
                    pileBox.carry(-(cardBox.target + bundle.gap));
                } else {
                    bundle.memberBorn(member, bundle._opening);
                }
            }
            Component.onDestruction: {
                if (bundle._cards[member.key] === card)
                    delete bundle._cards[member.key];
            }
            onRowStateChanged: {
                if (member.rowState !== "collapsed")
                    return;
                if (member.leaving)
                    bundle._dropLater(member.key);
                bundle.memberSettled();
            }
            onLeavingChanged: {
                // (The pile's cards read here, not `promoted`: a binding on
                // the property this handler reports may not have run yet.)
                const up = member.key === bundle._underUid || member.key === headRow.uid;
                if (member.leaving && bundle._isColumn() && member.key === bundle._underUid) {
                    // Up into the column's pile, the card under the away head:
                    // it stands where it stood, its room handed to the pile.
                    pileBox.carry(member.implicitHeight);
                    member.rowState = "collapsed";
                    bundle._dropLater(member.key);
                } else if (member.leaving && bundle.suppressedUid !== "" && (member.key === bundle.suppressedUid || up)) {
                    // Lifted out by the flight, or moved up to the head under
                    // the lifted one: a hole on the flight's clock, dropped
                    // when it is over (a room closing on a clock of its own
                    // would pump the box between the lift and the landing).
                    member.hole = true;
                } else if (member.leaving) {
                    // Gone (deleted, folded away): the list's wave takes it.
                    bundle.memberLeft(member);
                    if (member.rowState === "collapsed")
                        bundle._dropLater(member.key);
                } else {
                    member.hole = false;
                    bundle.memberReturned(member);
                }
            }
            Connections {
                target: bundle
                function onSuppressedUidChanged() {
                    if (bundle.suppressedUid !== "")
                        return;
                    member.flightDest = false;
                    if (member.hole) {
                        member.rowState = "collapsed";
                        bundle._dropLater(member.key);
                    }
                }
            }
        }
    }
}
