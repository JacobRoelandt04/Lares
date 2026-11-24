pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "parts"
import "../common/components"
import "../common/components/BarSpot.js" as BarSpot


// =============================================================================
// NotificationsBarOwner.qml -- the notifications module on ONE screen's bar.
//
// The service is one per shell (it owns org.freedesktop.Notifications); this
// owner is one per screen and does the two things that happen on a screen:
//
//   the manager   in thePopup, hung from the bell (`anchorItem`): toggle() /
//                 open() / close(), and the service's open/close requests
//                 (IPC, "+N more", a held-summary toast) when they name this
//                 screen (or none). A pointer that rests on the bell builds it
//                 ahead of the click (HoverIntent -> engine.prebuild, the
//                 content honouring `parked`);
//   the lane      theNotification, the toast stack: open on THIS screen while
//                 the scheduler shows toasts, the service's `laneScreen` is
//                 this screen and the manager is not open (opening the
//                 manager folds the toasts away -- they are rows in it
//                 already). It closes on the frame the scheduler's `shown`
//                 empties: the stack holds its height while its last rows play
//                 their exits inside the closing box (NotificationToast, GOING
//                 EMPTY); a swipe that empties it mid-gesture closes it at
//                 once too, and only the close's end waits for the fingers
//                 (the engine's closeLane).
//
// The engine holds ONE lane request, and this owner keeps it equal to what it
// wants (`_syncLane`, on every change of laneWanted): asked for while wanted and
// not held, withdrawn while held and not wanted. Asking by the lane's STATE
// instead (open, mine) would miss two cases: a toast arriving while the lane is
// closing under a swipe finds it still open and asks for nothing, and the lane
// then closes for good under toasts that time out unseen; and a toast that
// leaves while the lane is blocked leaves its request behind, which opens an
// empty lane the moment there is room.
//
// `laneWanted` reads nothing the lane's own open or close changes: the
// engine's laneOpen / laneOwnerId flip INSIDE openLane() / closeLane(), and a
// binding that read them would re-enter itself from its own change handler (a
// "Binding loop detected for property laneWanted").
//
// A mockup without the engine's lane hosts the toast content
// itself; `useLane: false` keeps this owner off the engine's lane API.
//
// SHELL-HOSTED (`shellHosted`, CONTRACT section 4). One owner per screen on the shell's ONE
// service: the owner then writes no property of the service. `sharedFlags.managerOpen` is
// what its Binding would have written -- the host sets `service.managerOpen` to the OR over
// its screens -- and the lane's "wanted and not out" goes to the service as a REPORT
// (`reportLaneUnseen(screenName, unseen)`: the service blocks the scheduler's clocks while any
// screen says yes). An unaddressed `openManagerRequested("")` opens the manager on the lane's
// screen only, not on every screen; a screen-addressed one opens it on that screen.
// =============================================================================
Item {
    id: owner

    property var engine: null
    property var bar: null
    property string barId: ""
    property string ownerId: "notifications"
    property Item anchorItem: null
    property string screenName: ""
    // The shell's mode (see the header): no write of any service property.
    property bool shellHosted: false
    // The bars are hidden (the shell's toggle): the stack has no bar to hang from, so it is a floating pill (toast/ToastPill, the host's
    // pill window) -- the lane is not asked for, the pill is. Both are the host's: with null / false the owner has no pill and uses the lane.
    property var pill: null
    property bool barsHidden: false
    property var service: null
    property var clock: null
    // The wiki's service, by injection (the clock owner builds the shell's one):
    // an empty manager shows today's Discover as a card. This owner never
    // builds one; null (the default) is a manager with no card.
    property var wiki: null

    // What the contents are built with: one style object, handed down to every
    // card (the mockup's panel writes into it).
    // A host may hand its own (a mockup's panel writes into it).
    property NotificationStyle style: NotificationStyle {}
    // A device pixel of the drain's step: the engine's renderScale, which is DEVICE px per design px (the shell's configured scale; a
    // mockup's stage zoom). Not times the attached Screen's ratio: the shell's frame already absorbs the window's.
    Binding {
        target: owner.style
        property: "renderScale"
        value: owner.engine && owner.engine.renderScale ? owner.engine.renderScale : 1
    }
    property bool useLane: true
    // Where the stack stands, from notifications.jsonc's `spot` (null: no bar
    // for it, no lane): { barId, local, alongAt, corner2D, corner, key }.
    readonly property var lanePlace: BarSpot.placeOf(
        owner.service && owner.service.config ? owner.service.config.spot : null,
        owner.engine ? owner.engine.barsList : null)

    readonly property bool popupMine: !!owner.engine && owner.engine.popupOpen
        && owner.engine.popupOwnerId === owner.ownerId
    readonly property string laneOwnerId: owner.ownerId + "/toast"
    readonly property bool laneMine: !!owner.engine && !!owner.engine.laneOpen
        && owner.engine.laneOwnerId === owner.laneOwnerId

    property bool _openedByKeyboard: false

    // What this owner would have written on the service (shell-hosted: the host ORs them).
    readonly property var sharedFlags: ({ managerOpen: owner.popupMine })

    Binding {
        target: owner.service
        property: "managerOpen"
        value: true
        when: !owner.shellHosted && !!owner.service && owner.popupMine
        restoreMode: Binding.RestoreBindingOrValue
    }

    Connections {
        target: owner.service
        ignoreUnknownSignals: true
        function onOpenManagerRequested(screenName: string) {
            // Addressed: that screen's owner. Unaddressed (""): one owner alone -- today's
            // single-screen host opens whatever it is; a shell's owners answer for ONE screen
            // only (the service's managerScreen), or every screen would open a manager.
            const mine = owner.shellHosted
                ? (screenName === "" ? owner.service.managerScreen === owner.screenName : screenName === owner.screenName)
                : (screenName === "" || screenName === owner.screenName);
            if (mine) {
                owner._openedByKeyboard = true;
                owner.open();
            }
        }
        function onCloseManagerRequested() {
            owner.close();
        }
    }

    readonly property Component managerComponent: Component {
        NotificationManagerPopup {
            service: owner.service
            clock: owner.clock
            wiki: owner.wiki
            style: owner.style
            openedByKeyboard: owner._openedByKeyboard
            popupRadius: owner.engine && owner.engine.maxR > 0 ? owner.engine.maxR : 20
            // The corners as the engine draws them (a corner beside a bar's
            // end is the fillet into the bar, rounder than maxR): the side
            // cut and the pin flight's cut follow them.
            cornerRadii: owner.engine ? owner.engine.popupCornerRadii : null
        }
    }

    // Where along the bar the item stands. A GooeyBar's frame is ROTATED with its edge (x runs
    // along the bar, y inward, whatever edge it is on -- GooeyBar), so the item mapped into the
    // bar is already in that frame and x is the answer on every edge (y would put the
    // bell's manager that far off along a left or right bar).
    function _alongOf(item) {
        return item.mapToItem(owner.bar, item.width / 2, item.height / 2).x;
    }
    function toggle() {
        if (owner.popupMine)
            owner.close();
        else {
            owner._openedByKeyboard = false;
            owner.open();
        }
    }
    function open() {
        if (!owner.engine || !owner.bar || !owner.anchorItem || owner.popupMine)
            return;
        owner.engine.open(owner.ownerId, owner.barId, owner._alongOf(owner.anchorItem), null, null, false,
                          owner.managerComponent, 1);
    }
    function close() {
        if (owner.popupMine)
            owner.engine.close();
    }
    // HOVER INTENT. The pointer has rested ~80 ms on the bell: the engine builds the
    // manager into its parked place, so the click finds it built and adopts it -- nothing is built in the
    // click's frame. The content is built WITH `parked: true` (an initial property: NotificationManagerPopup
    // runs nothing, asks the service for nothing and takes no key while it is parked) and the engine writes
    // `parked` from then on. Armed while the manager is not open, so a close under a resting pointer builds
    // the next one; a key-opened manager has no pointer and never asks. A host whose engine has no `prebuild`
    // (a mockup's stand-in) is asked nothing. Nothing is handed over at the build that the open must decide
    // later: `openedByKeyboard` is a live binding to this owner, read when the content is adopted.
    HoverIntent {
        target: owner.anchorItem
        enabled: !!owner.anchorItem && !!owner.service
        armed: !!owner.engine && typeof owner.engine.prebuild === "function" && !owner.popupMine
        onIntent: owner.engine.prebuild(owner.ownerId, owner.managerComponent, { parked: true })
    }

    // ---- the lane -------------------------------------------------------------------
    readonly property Component toastComponent: Component {
        NotificationToast {
            service: owner.service
            clock: owner.clock
            style: owner.style
            cornerRadius: owner.engine && owner.engine.maxR > 0 ? owner.engine.maxR : 20
        }
    }
    readonly property int _shownCount: owner.service && owner.service.toasts && owner.service.toasts.shown
        ? owner.service.toasts.shown.length : 0
    readonly property bool pillMode: owner.barsHidden && !!owner.pill
    readonly property bool _stackWanted: owner.useLane && !!owner.service
        && owner.service.laneScreen === owner.screenName && !owner.service.managerOpen
        && owner._shownCount > 0
    readonly property bool laneWanted: owner._stackWanted && !owner.pillMode
    readonly property bool pillWanted: owner._stackWanted && owner.pillMode
    Binding {
        target: owner.pill
        property: "contentComponent"
        value: owner.toastComponent
        when: !!owner.pill
    }
    Binding {
        target: owner.pill
        property: "cornerRadius"
        value: owner.engine && owner.engine.maxR > 0 ? owner.engine.maxR : 20
        when: !!owner.pill
    }
    Binding {
        target: owner.pill
        property: "present"
        value: owner.pillWanted
        when: !!owner.pill
    }

    // THE SPOT: a screen corner or a point along a bar, placed by BarSpot.placeOf
    // (common/components/BarSpot.js, where the rule is written out).
    // The place the engine holds a request for (its `key`), so a spot that
    // moves while the lane is asked for is asked again, and only then.
    property string _askedKey: ""
    function _askLane() {
        const p = owner.lanePlace;
        if (!p)
            return;
        owner._askedKey = p.key;
        owner.engine.openLane(owner.laneOwnerId, p.barId, p.local, null, null, p.corner2D, owner.toastComponent, 0.5,
                              p.alongAt);
    }
    function _syncLane() {
        if (!owner.engine || !owner.engine.openLane)
            return;
        const asked = owner.engine.laneRequestOwner === owner.laneOwnerId;
        if (owner.laneWanted && !asked)
            owner._askLane();
        else if (!owner.laneWanted && asked)
            owner.engine.closeLane();
    }
    onLaneWantedChanged: owner._syncLane()
    // The spot moved (the config, a bar) while the lane is asked for: it goes
    // there -- along its bar it glides, to another bar it folds in and opens
    // there (the engine's hop). And the other way round: a lane wanted
    // while there is no place to stand it (the first turns after a start,
    // before this screen's bars have registered with the engine) is
    // never asked for -- the place appearing is the moment to ask.
    onLanePlaceChanged: {
        if (!owner.lanePlace || !owner.engine)
            return;
        if (owner.engine.laneRequestOwner !== owner.laneOwnerId)
            owner._syncLane();
        else if (owner.lanePlace.key !== owner._askedKey)
            owner._askLane();
    }

    // No room beside thePopup: the engine folds the lane away and waits, and
    // the bell says toasts are held.
    readonly property bool laneHeld: owner.useLane && !!owner.engine && !!owner.engine.laneBlocked
        && owner.laneWanted
    // THE STACK'S CLOCKS STOP WHILE IT IS NOT OUT. Wanted and not out on the
    // screen -- no room beside thePopup (laneHeld), a hop folding in on one
    // bar before it opens on the next, a hop asked for under a live swipe
    // waiting for the fingers to lift, a popup
    // still passing where it will open -- and a toast counts down unseen: one
    // that arrives during a held hop would be on screen for 2 of its 8 s (the
    // reader's idle end comes 6 s after the last wheel). Settled once
    // per turn: this owner asks for the lane inside laneWanted's own change,
    // so "wanted and not out" is true for an instant at every arrival, and
    // every freeze and thaw moves each live deadline (ToastScheduler: a thaw
    // grants the resume minimum). Read-only for hosts.
    readonly property bool _laneUnseenNow: owner.useLane && owner.laneWanted && !owner.laneMine
    property bool laneUnseen: false
    on_LaneUnseenNowChanged: Qt.callLater(owner._settleUnseen)
    function _settleUnseen() {
        owner.laneUnseen = owner._laneUnseenNow;
    }
    Binding {
        target: owner.service ? owner.service.toasts : null
        property: "blocked"
        value: owner.laneUnseen
        when: !owner.shellHosted && !!owner.service && owner.useLane
    }
    // Shell-hosted: the same fact as a report, one per screen (the service ORs them).
    onLaneUnseenChanged: owner._reportUnseen()
    function _reportUnseen() {
        if (owner.shellHosted && owner.service && owner.useLane)
            owner.service.reportLaneUnseen(owner.screenName, owner.laneUnseen);
    }
    Component.onDestruction: {
        if (owner.shellHosted && owner.service)
            owner.service.reportLaneUnseen(owner.screenName, false);
    }

    Component.onCompleted: {
        // Quickshell scans the desktop entries lazily, from the first lookup,
        // and that lookup answers null: start the scan with the shell, so the
        // first toast's icon (EntryIcon) is not the one that waits for it.
        DesktopEntries.byId("");
        owner._syncLane();
    }
}
