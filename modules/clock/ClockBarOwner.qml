pragma ComponentBehavior: Bound

import QtQuick

import "../common/components"
import "data"
import "../bar/workspaces"
import "data/timers.js" as T

// =============================================================================
// ClockBarOwner.qml -- the clock module's bar-side object (NetBtBarPair's
// pattern).
//
// NOT a drop-in: it lives in the bar, holds everything that must survive the
// popup closing, and hands thePopup a component. The engine empties its
// Loader once a popup has closed, so what lives here instead of in the
// content is exactly what must not die with it:
//
//   - the timers (TimerService): a countdown runs, a pomodoro advances and an
//     alarm rings with the popup closed; persisted, with the real notifier and
//     sound. A mockup or a probe hands its own in (`timerService`); the bar
//     leaves it null and the owner builds the real one;
//   - the popup's last tab, which the content hands back on every change and
//     gets again on every open (remembered across reopening, forgotten in
//     new system sessions: a property here lives as long as the shell does). open() takes it as it
//     stands; the bar's click (toggle()) first turns it into the tab to open
//     on -- clock.md "Default tab": the calendar, unless a timer is in
//     progress and the Timers tab is the one it was last left on, and the
//     Timers tab ONCE after a timer finished that nobody has looked at
//     (a second open is back to the rule). `finishedUnseen` is this screen's own bar's fact;
//   - the calendar's feeds (CalendarService), so a reopen does not refetch
//     and re-expand them; handed in the same way (`calendarService`);
//   - the link to the Workspaces groove: the fills the timers put in it, and
//     the dust when one finishes;
//   - the wiki (modules/wiki): its ONE WikiService, and the way in for a request
//     to open the card. The wiki has no bar button; its home is this popup's
//     Calendar tab (a tear-off under the appointments) and the full card is
//     the popup's secondary. `wikiService` is injected (a mockup or a probe
//     hands a WikiMock; the notification and launcher owners are handed this
//     owner's `wiki`); `wikiEnabled` builds the owner's OWN service when none
//     is injected, by URL, so this owner still loads if the wiki cannot. It is
//     OFF here: a host that wants the wiki turns it on, and
//     with it off and nothing injected no wiki object exists anywhere. A
//     request (`service.openRequested(tab)`, from a notification's click or
//     another host) opens the popup on the Calendar tab with the card out on
//     that tab; when the popup is already open the content moves the card.
//
// The clock's own button sits in Workspaces' clock split, so this item has
// no visual of its own: `anchorItem` is whatever the popup hangs from.
//
// SHELL-HOSTED (`shellHosted`, docs/contracts/shell.md section 4). The shell mounts one
// owner PER SCREEN while its services exist ONCE (ShellServices): every service is injected
// (a null one is a feature that is absent, never one built here), and nothing here writes a
// property of a service or listens to one of its unaddressed requests -- two screens' owners
// would write one flag by turns and the last writer would win. What the owner would have
// written is `sharedFlags` (the host ORs every screen's and writes the service), and a
// request (`wiki.openRequested`) reaches the focused screen's owner through `openWiki()`,
// routed by the host. The Workspaces fills and the burst on a finish stay: they are this
// screen's own bar. Off (the default), the owner is standalone: it builds the services nobody injected.
// =============================================================================
Item {
    id: owner

    // ---- the bar ------------------------------------------------------------
    property var engine: null                 // GooeyEngine
    property var bar: null                    // GooeyBar
    property string barId: ""
    property string ownerId: "clock"
    property Item anchorItem: null            // the clock button the popup hangs from

    // ---- what it owns -------------------------------------------------------
    property string currentTab: "calendar"
    // The tab a click opens on (clock.jsonc `open`, timers.js openTab): "auto" | "calendar" | "timers" | "last".
    property string openMode: "auto"
    property var calendarService: null
    readonly property var calendarData: owner.calendarService ?? ownCalendar.item
    // The Workspaces module the timers fill (null: none).
    property var workspaces: null

    // A mockup or a probe hands its service in; the bar leaves it null.
    property var timerService: null
    readonly property var timers: owner.timerService ?? ownTimers.item

    // ---- screentime (the popup's third tab) ---------------------------------
    // A mockup hands its ScreentimeMock in; the bar sets `screentimeEnabled`
    // and the owner keeps the real service (loaded by URL, the wiki's reason).
    // Neither: no third tab, nothing of modules/screentime is loaded.
    property var screentimeService: null
    property bool screentimeEnabled: false
    readonly property var screentime: owner.screentimeService ?? ownScreentime.item
    // The face the card showed last (0 bars | 1 hours | 2 span).
    property int screentimeFace: 0

    // ---- the wiki -----------------------------------------------------------
    property var wikiService: null
    property bool wikiEnabled: false
    readonly property var wiki: owner.wikiService ?? ownWiki.item
    // Where the card opens (ClockPopupContent's header) and its face.
    property string wikiSide: "end"
    property string wikiAnchor: "start"
    property string wikiFontFamily: "Inter"
    property bool wikiTearoff: true
    // The tab the next popup opens the card on (a request), taken once by the
    // content that is built.
    property string pendingWiki: ""

    readonly property bool popupMine: !!owner.engine && owner.engine.popupOpen
                                      && owner.engine.popupOwnerId === owner.ownerId

    // ---- the shell (CONTRACT section 4) --------------------------------------
    // True: the shell's one set of services is injected (`calendarService`, `timerService`,
    // `wikiService`, `screentimeService`); nothing is built here, written to a service or
    // listened to for a request. `sharedFlags` is what the bindings below would have written.
    property bool shellHosted: false
    readonly property var sharedFlags: ({
            wikiPopupOpen: owner.popupMine,
            timersAttended: owner.popupMine && owner.currentTab === "timers"
        })

    // The week's first day. On its own the owner reads calendars.jsonc itself; hosted, the
    // week start is the injected service's (one config for the whole shell).
    Loader {
        id: calendarConfigLoader
        active: !owner.shellHosted
        sourceComponent: Component {
            CalendarConfig {}
        }
    }
    // `var`: a Loader's item is a QObject to the linter, and weekStart is the config's own member.
    readonly property var _ownConfig: calendarConfigLoader.item
    readonly property int weekStart: {
        const c = owner.shellHosted ? (owner.calendarService ? owner.calendarService.config : null) : owner._ownConfig;
        return c && c.weekStart !== undefined ? c.weekStart : 1;
    }
    Loader {
        id: ownCalendar
        active: owner.calendarService === null && !owner.shellHosted
        sourceComponent: Component {
            CalendarService {
                config: calendarConfigLoader.item
            }
        }
    }
    // The timers ring, notify and persist: the owner builds them (with the notifier and the
    // sound that serve them, inside the service so they exist when its first look at the file
    // finds an alarm that went off) only when it is the bar's own and nothing was injected.
    Loader {
        id: ownTimers
        active: owner.timerService === null && !owner.shellHosted
        sourceComponent: Component {
            TimerService {
                persist: true
                notifier: ownNotifier
                sound: ownSound
                DesktopNotifier {
                    id: ownNotifier
                }
                SoundPlayer {
                    id: ownSound
                }
            }
        }
    }

    // The own wiki service, and the notifier it asks and reports through (the
    // stocks pattern; only when the service is ours: an injected one is handed
    // its notifier by whoever built it).
    Loader {
        id: ownWikiNotifier
        active: owner.wikiEnabled && owner.wikiService === null && !owner.shellHosted
        sourceComponent: Component {
            DesktopNotifier {
                appName: "Wiki"
                keys: owner.wiki && owner.wiki.notifyKeys ? owner.wiki.notifyKeys : []
            }
        }
    }
    Loader {
        id: ownScreentime
        active: owner.screentimeEnabled && owner.screentimeService === null && !owner.shellHosted
        source: Qt.resolvedUrl("../screentime/data/ScreentimeService.qml")
    }
    Loader {
        id: ownWiki
        active: owner.wikiEnabled && owner.wikiService === null && !owner.shellHosted
        source: Qt.resolvedUrl("../wiki/data/WikiService.qml")
    }
    // A Binding, not the service's `onLoaded`: two Loaders of one item do not complete
    // in the order they are declared, and the notifier's may not be there yet.
    Binding {
        target: ownWiki.item
        property: "notifier"
        value: ownWikiNotifier.item
        when: !!ownWiki.item && !!ownWikiNotifier.item
    }
    Binding {
        target: owner.wiki
        property: "popupOpen"
        value: owner.popupMine
        when: !owner.shellHosted && !!owner.wiki
    }
    Connections {
        target: owner.wiki
        enabled: !owner.shellHosted
        ignoreUnknownSignals: true
        function onOpenRequested(tab: string) {
            owner.openWiki(tab);
        }
    }

    // A timer finished and the Timers tab has not been shown since: the next open lands on it, once. Told by the service's `finished`
    // (not when the popup is already open on the Timers tab: it shows the finish itself), forgotten when the click that opens the tab
    // takes it, and when nothing rings any more (the timer was stopped, or its notification dismissed: nothing is left to look at).
    property bool finishedUnseen: false
    // ... and which timer it was (the latest, when several finished): the view of the Timers card the next open lands on.
    property string finishedKind: ""
    Connections {
        target: owner.timers
        ignoreUnknownSignals: true
        function onFinished(kind, info) {
            if (!(owner.popupMine && owner.currentTab === "timers")) {
                owner.finishedUnseen = true;
                owner.finishedKind = kind;
            }
        }
        function onRingingChanged() {
            if (owner.timers && Object.keys(owner.timers.ringing).length === 0) {
                owner.finishedUnseen = false;
                owner.finishedKind = "";
            }
        }
    }
    // WHICH VIEW OF THE TIMERS CARD to show (T.openView): decided at the bar's click, handed to the card as a REQUEST -- a new object
    // every click, so that asking for the same view twice is two requests, and one the card takes when it exists (a card is built when
    // first shown, a kept one has been put back on its first view). The popup's content never decides it: it is the owner's rule, as
    // the tab is.
    property var viewRequest: null
    property int _viewSerial: 0

    // Watched: the timers tab of an open popup shows a finish itself, so no
    // notification pops up over it (the sound still plays).
    Binding {
        target: owner.timers
        when: !owner.shellHosted && !!owner.timers
        property: "attended"
        value: owner.popupMine && owner.currentTab === "timers"
        restoreMode: Binding.RestoreBindingOrValue
    }

    // ---- the groove -----------------------------------------------------------
    Binding {
        target: owner.workspaces
        when: !!owner.workspaces && !!owner.timers
        property: "fills"
        value: owner.timers ? owner.timers.barFills : []
        restoreMode: Binding.RestoreBindingOrValue
    }
    Binding {
        target: owner.workspaces
        when: !!owner.workspaces && !!owner.timers && !!owner.timers.clock
        property: "fillClock"
        value: owner.timers ? owner.timers.clock : null
        restoreMode: Binding.RestoreBindingOrValue
    }
    // The break nudge: the shell's one BreakClock fills this screen's rail under the timers' fills (shell only: a standalone owner,
    // a mockup, shows none).
    Binding {
        target: owner.workspaces
        when: !!owner.workspaces && owner.shellHosted
        property: "breakSource"
        value: BreakClock
        restoreMode: Binding.RestoreBindingOrValue
    }
    Connections {
        target: owner.timers
        ignoreUnknownSignals: true
        function onFinished(kind, info) {
            if (!owner.workspaces)
                return;
            if (kind === "countdown")
                owner.workspaces.burst(-1, 0);
            else if (kind === "pomodoro")
                owner.workspaces.burst(info.phase === "long" ? -1 : info.session, info.phase === "focus" ? 1 : 2);
        }
    }

    // ---- the popup ------------------------------------------------------------
    // What thePopup loads: the drop-in, handed what lives here. Its tab is
    // written back on every change, so the next open starts where this one
    // ended.
    readonly property Component popupComponent: Component {
        ClockPopupContent {
            id: content
            timers: owner.timers
            calendarData: owner.calendarData
            weekStart: owner.weekStart
            currentTab: owner.currentTab
            onCurrentTabChanged: owner.currentTab = content.currentTab
            onCloseRequested: owner.engine.close()
            // The binding above dies at the content's own first assignment (a tab clicked in it); this does not: a content kept
            // parked between opens (recycle) is told the tab the OWNER chose for the open that adopts it (open()).
            Binding {
                target: content
                property: "currentTab"
                value: owner.currentTab
                restoreMode: Binding.RestoreNone
            }
            // The owner's choice of the Timers card's view (see `viewRequest`), taken by the card whenever it exists.
            Binding {
                target: content.timersCard
                property: "viewRequest"
                value: owner.viewRequest
                when: !!content.timersCard
                restoreMode: Binding.RestoreNone
            }
            wiki: owner.wiki
            wikiSide: owner.wikiSide
            wikiTearoffShown: owner.wikiTearoff
            wikiAnchor: owner.wikiAnchor
            wikiFontFamily: owner.wikiFontFamily
            screentime: owner.screentime
            screentimeFace: owner.screentimeFace
            onScreentimeFaceChanged: owner.screentimeFace = content.screentimeFace
            // A card asked for while the popup was closed (a notification's
            // click) comes out once the tear-off is placed.
            Component.onCompleted: {
                if (owner.pendingWiki !== "") {
                    const t = owner.pendingWiki;
                    owner.pendingWiki = "";
                    Qt.callLater(() => content.openWiki(t));
                }
            }
        }
    }

    // Hover intent: the pointer has rested on the button, so the content is built now, parked, for the click that follows
    // (GooeyEngine.prebuild: the click then adopts it and builds nothing).
    HoverIntent {
        target: owner.anchorItem
        armed: !!owner.engine && !owner.popupMine
        onIntent: owner.engine.prebuild(owner.ownerId, owner.popupComponent, { parked: true })
    }

    // The bar's click. Closes the popup when it is this owner's; otherwise opens it on the tab the user's rule gives (clock.md,
    // "Default tab"; `openMode` "auto"): the calendar, unless a timer is in progress AND the Timers tab is the one it was last left on. Decided here, at
    // the click, from what `currentTab` holds NOW -- the last tab shown -- and written back, so that what this open shows is what the
    // next one finds; a content built ahead of the click takes it through its binding. The rule is the CLICK's, not open()'s: a
    // request that names its tab (openWiki's calendar, a host that wants the Timers tab) sets `currentTab` and calls open(), and is not
    // overruled. With the rule in open(), an owner asked for the Timers tab with nothing running would come up on
    // the calendar and `timersAttended` would stay false.
    function toggle() {
        if (owner.popupMine) {
            owner.engine.close();
        } else {
            owner.currentTab = T.openTab(owner.currentTab, !!owner.timers && owner.timers.inProgress === true, owner.finishedUnseen, owner.openMode);
            // and which timer of that tab: the one that finished unseen, else the one started last (a pomodoro running, closed and
            // opened again is the pomodoro's view, not the countdown's)
            const view = owner.timers
                ? T.openView(owner.finishedUnseen ? owner.finishedKind : "", owner.timers.countdown, owner.timers.pomodoro, owner.timers.stopwatch, owner.timers.touched)
                : -1;
            owner.viewRequest = view >= 0 ? { view: view, serial: ++owner._viewSerial } : null;
            owner.finishedUnseen = false;
            owner.finishedKind = "";
            owner.open();
        }
    }

    // A ring's toast was clicked (`timers.openRequested`): the popup on the Timers tab, on the view of the timer that rang. An open popup
    // is moved to the tab; a shell's host calls this on the focused screen's owner, a bar's own owner hears the service itself.
    function openTimers(kind) {
        if (!owner.timers || !owner.engine || !owner.bar || !owner.anchorItem)
            return;
        const view = T.openView(kind, owner.timers.countdown, owner.timers.pomodoro, owner.timers.stopwatch, owner.timers.touched);
        owner.currentTab = "timers";
        owner.viewRequest = view >= 0 ? { view: view, serial: ++owner._viewSerial } : null;
        owner.finishedUnseen = false;
        owner.finishedKind = "";
        if (!owner.popupMine)
            owner.open();
    }
    Connections {
        target: owner.timers
        enabled: !owner.shellHosted
        ignoreUnknownSignals: true
        function onOpenRequested(kind: string) {
            owner.openTimers(kind);
        }
    }

    // Open the wiki's card on `tab` ("discover" | "deepen"): out of the open popup
    // (moved to the Calendar tab first), else out of a popup opened for it.
    function openWiki(tab) {
        if (!owner.wiki || !owner.engine || !owner.bar || !owner.anchorItem)
            return;
        const t = tab === "deepen" ? "deepen" : "discover";
        const content = owner.popupMine ? owner._clockContent() : null;
        if (content) {
            content.openWiki(t);
            return;
        }
        owner.currentTab = "calendar";
        owner.pendingWiki = t;
        if (!owner.popupMine)
            owner.open();
    }

    // The content on show when it is THE CLOCK'S: a popup that is another owner's, still on screen while the engine travels to this one
    // (the swap is a fade later), is not the one a request for the wiki's card is for -- asking `thePopup.contentItem` for an
    // `openWiki` alone would take the notification manager for it. The clock's content is the one with both halves of the card's contract.
    function _clockContent() {
        const c = owner.engine && owner.engine.thePopup ? owner.engine.thePopup.contentItem : null;
        return c && typeof c.openWiki === "function" && typeof c.closeWiki === "function" ? c : null;
    }

    // Opens the popup on `currentTab` as it stands -- the mechanism. The default-tab rule is toggle()'s, the click's.
    function open() {
        if (!owner.engine || !owner.bar || !owner.anchorItem)
            return;
        // Read at the moment of opening, not bound: a mapToItem in a binding
        // does not track the layout that moved it.
        const centre = owner.anchorItem.mapToItem(owner.bar, owner.anchorItem.width / 2, owner.anchorItem.height / 2).x;
        owner.engine.open(owner.ownerId, owner.barId, centre, null, null, false, owner.popupComponent, 1);
        // A card asked for while the popup was closed is taken at the build (the popup's Component.onCompleted); a content built
        // ahead of the click completed long before the ask, so it is handed over now -- or, when another owner's popup is still on
        // screen (the engine travels to this one and swaps the content a fade later), the moment the clock's content takes over.
        owner._handPendingWiki();
    }
    function _handPendingWiki() {
        if (owner.pendingWiki === "" || !owner.popupMine)
            return;
        const t = owner.pendingWiki, content = owner._clockContent();
        if (!content)
            return;
        owner.pendingWiki = "";
        Qt.callLater(() => content.openWiki(t));
    }
    // A content kept parked (recycled, prebuilt) is adopted without being built: its Component.onCompleted ran long ago and cannot
    // take the ask. The content is on show when `contentItem` changes to it.
    Connections {
        target: owner.engine ? owner.engine.thePopup : null
        ignoreUnknownSignals: true
        function onContentItemChanged() {
            owner._handPendingWiki();
        }
    }
}
