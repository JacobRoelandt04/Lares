pragma ComponentBehavior: Bound

import QtQuick
import "../common/components" as Common
import "../common/theme"
import "calendar"
import "data"
import "data/timers.js" as T
import "timers"
import "../common/scroll"

// =============================================================================
// ClockPopupContent.qml
//
// Drop-in popup content for the Clock module. Top-level layout:
//
//   ┌─────────────────────────────────────────────┐
//   │             [ Calendar | Timers ]            │  tab selector
//   ├─────────────────────────────────────────────┤
//   │   CalendarView          │  AppointmentList  │  (active = calendar)
//   │   MonthHeader ▸                             │
//   │                         │                   │
//   │                                              │  (active = timers)
//   │            Timers — placeholder              │
//   └─────────────────────────────────────────────┘
//
// Mockup: mockups/clock.qml puts this on the mockup
// framework's stage at its own implicit size, as thePopup will; it owns all
// its state, so it plugs into the bar unchanged.
// =============================================================================
Item {
    id: root

    // Accept keyboard focus so CalendarView.handleKey can respond to
    // arrow/T/PgUp/PgDn. Routed from here because only the popup knows
    // which tab is active — calendar keys should no-op while on Timers.
    focus: true
    Keys.onPressed: (e) => {
        // Screentime's usage tint: only while the key is HELD, on the calendar.
        if (e.key === root.usageTintKey && root.currentTab === "calendar" && root.screentime) {
            if (!e.isAutoRepeat)
                root._tintHeld = true;
            e.accepted = true;
            return;
        }
        if (root.currentTab === "calendar") cal.handleKey(e);
        else if (root.currentTab === "screentime" && root._stCard) root._stCard.handleKey(e);
    }
    // Any click inside the popup reclaims focus, so keys still work after
    // the user has poked a sibling widget (test harness controls panel,
    // etc.). Passive handler — doesn't swallow the tap.
    TapHandler {
        onTapped: root.forceActiveFocus()
    }

    // Inject-able so the real service can swap in without touching this tree.
    // In tests, this is a MockCalendarData instance.
    property var calendarData: _defaultMock

    // Persisted tab selection (across popup open/close within a session).
    property string currentTab: "calendar"

    // The timers' state (TimerService). It lives OUTSIDE the popup -- the
    // clock's bar-side owner hands it in -- because thePopup's Loader
    // destroys this content on every close. Left null, the popup keeps an
    // in-memory service of its own, so it still works standalone.
    property var timers: null
    readonly property var _timers: root.timers ? root.timers : (ownTimers.item ? ownTimers.item : null)
    Loader {
        id: ownTimers
        active: root.timers === null
        sourceComponent: Component {
            TimerService {
                persist: false
            }
        }
    }
    // THE TIMERS TAB'S CARD IS BUILT WHEN FIRST SHOWN (a hidden tab costs nothing to open -- the card is
    // about half of this popup's visual items and the calendar is what opens). Latched: once shown it stays, with its state. null
    // until then. `eagerTimers` builds it at once, for a host that tunes it (the mockup's panel).
    property bool eagerTimers: false
    readonly property TimersCard timersCard: tmLoader.item as TimersCard

    property int weekStart: 1

    // ---- SCREENTIME (modules/screentime): the third tab --------------------
    // `screentime` is the ScreentimeService (or a ScreentimeMock) the clock's
    // bar-side owner keeps; null (the default) means NO third tab and nothing
    // of modules/screentime is loaded -- the clock's own gates, which copy
    // only common/ and clock/, keep running. The card is loaded BY URL (the
    // wiki's reason, CLAUDE.md) and lazily, on the tab's first show.
    //   screentimeWidth  the card's width, fixed before it loads so the tab's
    //                    width is known while the card is still a URL
    //   screentimeFace   the face it shows (0 bars | 1 hours | 2 span), written
    //                    back so the owner can remember it across opens
    property var screentime: null
    // Held on the calendar, this key tints every day by its screen time (the
    // share of the heaviest shown day). T is the calendar's "today".
    property int usageTintKey: Qt.Key_S
    property int usageTintFadeMs: 160
    property real screentimeWidth: 420
    property int screentimeFace: 0
    readonly property var _stCard: stLoader.item

    // The tint: held -> one eased fraction; the map is facts, read from the
    // service's cache (a getter: it never asks; the press asks once).
    property bool _tintHeld: false
    property real _tintF: root._tintHeld ? 1 : 0
    Behavior on _tintF {
        NumberAnimation {
            duration: root.usageTintFadeMs
            easing.type: Easing.OutCubic
        }
    }
    Keys.onReleased: (e) => {
        if (e.key === root.usageTintKey && !e.isAutoRepeat)
            root._tintHeld = false;
    }
    onActiveFocusChanged: if (!root.activeFocus) root._tintHeld = false
    // The six shown weeks, padded to whole weeks either side of the month.
    readonly property var _tintSpan: {
        const first = new Date(cal.viewYear, cal.viewMonth, 1);
        const a = new Date(first.getFullYear(), first.getMonth(), 1 - 7);
        const b = new Date(first.getFullYear(), first.getMonth(), 1 + 42);
        return { from: Qt.formatDate(a, "yyyy-MM-dd"), to: Qt.formatDate(b, "yyyy-MM-dd") };
    }
    on_TintHeldChanged: {
        if (root._tintHeld && root.screentime)
            root.screentime.loadRange(root._tintSpan.from, root._tintSpan.to);
    }
    readonly property var _tintMap: {
        if (!root.screentime || root._tintF <= 0)
            return null;
        const _s = root.screentime.serial;
        const r = root.screentime.range(root._tintSpan.from, root._tintSpan.to);
        if (!r)
            return null;
        let max = 0;
        for (const k in r)
            max = Math.max(max, r[k]);
        if (max <= 0)
            return null;
        const out = {};
        for (const k in r)
            out[k] = r[k] / max;
        return out;
    }

    // Default fallback so the component works standalone with no external data.
    MockCalendarData { id: _defaultMock }

    // Persistent per-year week-1 anchor (click a week number to rebase).
    WeekOffsetStore { id: weekOffsets }

    // Persistent per-calendar show/hide preferences. The header in the
    // appointment-list panel exposes a UI for toggling; the store mirrors
    // its hidden-id list down into the data source so events filter at the
    // source (caches re-bust uniformly + AppointmentList silent-syncs).
    CalendarVisibilityStore { id: visStore }
    Binding {
        target: root.calendarData
        property: "hiddenCalendarIds"
        value: visStore.hiddenList
        when: !!root.calendarData && !root.parked
    }

    // Selected day shared between calendar grid and appointment list.
    property date selectedDate: new Date()

    // Layout numbers. Every edge and the gap under the tab row take
    // `padding`; the calendar's own geometry (cellSize, weekColWidth) sizes
    // the left column, so the popup's implicit size follows it instead of
    // clipping or leaving a hole when the grid is retuned.
    property real padding: 12
    property real tabWidth: 280
    property real tabHeight: 34
    property real listWidth: 222
    property real monthHeaderGap: 4
    // Accumulated horizontal |angleDelta| that steps one month.
    property int swipeThreshold: 800
    // Held with any month step -- the header's chevrons, a swipe over the
    // month, PgUp/PgDn -- it steps a year instead.
    property int yearModifier: Qt.ControlModifier
    // A touchpad that reports only pixels is scaled into wheel units by this.
    property real swipePixelToAngle: 2.5
    // Fallback end of a gesture for a device that never sends the zero-delta
    // event of the fingers lifting.
    property int gestureIdleEndMs: 260

    // Each tab has its own width: the calendar as its grid and list need,
    // the timers a SQUARE card as tall as the calendar's content. The height
    // is the calendar's either way, so a tab switch only moves the sides.
    readonly property real _contentHeight: cal.implicitHeight + monthHeaderGap + header.implicitHeight
    readonly property real _calendarWidth: padding * 3 + cal.implicitWidth + listWidth
    readonly property real _timersWidth: padding * 2 + root._contentHeight
    readonly property real _screentimeWidth: padding * 2 + root.screentimeWidth
    implicitWidth: root.currentTab === "timers" ? root._timersWidth
                 : root.currentTab === "screentime" ? root._screentimeWidth : root._calendarWidth
    implicitHeight: padding * 3 + tabHeight + root._contentHeight
    // THE SIZE THE NEXT OPEN ASKS FOR (GooeyEngine `_rememberSize` reads these when a content has them). The owner reopens on the calendar
    // unless a timer is in progress (ClockBarOwner.toggle), so a popup closed on its Timers tab -- 478 wide, the calendar's 740 -- is not
    // what the trip back should aim at: the box would fly at the narrow size for the first part of the trip and then turn round.
    readonly property real restImplicitWidth: root._calendarWidth
    readonly property real restImplicitHeight: root.implicitHeight

    // ---- the swipe-hold contract (docs/contracts/gestures.md §4) -------------
    // A sideways swipe switches tabs, and the tabs are different widths: the
    // popup changes size under the fingers. While a gesture lives, the host
    // keeps its input at least the size of the wider tab, and hands this
    // content the wheels that land outside it (gestureWheel).
    readonly property bool swipeGestureActive: root._gestureActive
    readonly property real gestureHoldWidth: Math.max(root._calendarWidth, root._timersWidth,
                                                      root.screentime ? root._screentimeWidth : 0)
    readonly property real gestureHoldHeight: root.implicitHeight

    // ---- the keyboard (the engine's content contract) -----------------------------------
    // This popup reads keys: the calendar's arrows, PgUp / PgDn and T, the held S, and the
    // alarm label's TextField on the Timers tab. A layer surface hands a client nothing
    // without a request (a toplevel window does, which is why the mockup never needed one).
    // It is opened by a click on the bar, with the pointer resting on the layer, so OnDemand
    // is right: no pulse, no grab -- keys follow the pointer, as windows do.
    readonly property string keyboardFocusRequest: "onDemand"

    // The inner components, for a host (or the mockup's panel) that tunes
    // them directly.
    readonly property alias calendar: cal
    readonly property alias monthHeader: header
    readonly property alias appointments: apptList

    // ======================================================================
    // MONTH NAVIGATION — the header's arrows, the swipe and any host call
    // go through these.
    // ======================================================================
    function stepMonth(months) {
        cal.stepMonths(months);
    }
    function gotoMonth(y, m) {
        cal.viewYear = y;
        cal.viewMonth = m;
    }

    // --- Dynamic RRULE expansion window (TODO M1) -----------------------
    // Push a view-centred expansion window to the calendar data source
    // whenever the viewed month changes, so recurring-event occurrences
    // stay materialised for whatever month the user scrolls to. ±6 months
    // around the current viewMonth is a comfortable buffer (one full
    // calendar month view is 42 days ≈ 1.5 months). Mock data source
    // ignores this (no setViewWindow).
    function _adjustExpansionWindow() {
        if (!calendarData || typeof calendarData.setViewWindow !== "function")
            return;
        // ±12 months so a rapid multi-month scroll doesn't sail off the edge
        // of the materialised-events window and show empty grids as it flies
        // past. RRULE expansion is one-shot per feed, cheap on idle CPU.
        let start = new Date(cal.viewYear, cal.viewMonth - 12, 1);
        let end = new Date(cal.viewYear, cal.viewMonth + 13, 0);
        calendarData.setViewWindow(start, end);
    }
    Connections {
        target: cal
        function onViewMonthChanged() { root._adjustExpansionWindow(); }
        function onViewYearChanged()  { root._adjustExpansionWindow(); }
    }
    // The engine's: true while this content was built AHEAD of a click and is held hidden (GooeyEngine.prebuild), built WITH it (the owner passes `{ parked: true }`). Taking the keyboard is the one thing the build did that must not
    // happen while parked -- it would take it from whoever has it -- so it happens when the engine hands the content over.
    //
    // PARKED means quiet (the contract): the list's first slide is held, the wiki tear-off and the timers card are not "active", the
    // service is not asked to re-expand its window, and nothing is written to it. What was held happens when the engine hands the
    // content over.
    property bool parked: false
    // The clock's button grows on hover, and a build in the hover is a freeze in that motion (a lag spike on expand), so this content is
    // never given up for another popup's and is kept after the prewarm (GooeyEngine, THE PARKED CONTENT).
    readonly property bool parkPinned: true
    onParkedChanged: {
        if (root.parked) {
            root._holdEvents();
            return;
        }
        root.forceActiveFocus();
        root._adjustExpansionWindow();
        root._openedTurn();
    }
    Component.onCompleted: {
        root._eventsHeld = true;
        if (!root.parked) {
            root._adjustExpansionWindow();
            root.forceActiveFocus();
            root._openedTurn();
        }
    }

    // ---- THE EVENTS WAIT FOR THE POPUP ------------------------------
    // The day's events slide in staggered, and with the data in the cache that would begin the moment the content is built -- while the
    // popup is still growing and fading its content in, so the first two rows would slide in before anyone could see them. The list's
    // first slide is held (`startHeld`) while the content is parked and until the popup has GROWN to its own size (the engine
    // hands this content the animated box as its width and height), at most `eventsHoldMaxMs`. It is held only for the data that
    // is already there: a slow fetch lands after the release, and its slide starts with no wait of this kind (nothing could be
    // shown before it, and the fetch was wait enough).
    property int eventsHoldMaxMs: 900
    // Starts false and is set from `Component.onCompleted`: bound true from the first moment, the list's own first
    // look at its feed landed inside a binding evaluation that wrote the feed's day cache ("Binding loop detected for
    // _currentEventCount" -- by the mock, whose cache is a var property written on first use)
    property bool _eventsHeld: false
    // Unparked, and the engine has had a moment to size the box (a content handed over reads its parked size for a frame).
    property bool _opened: false
    readonly property bool _grown: root.width >= root.implicitWidth - 1 && root.height >= root.implicitHeight - 1
    function _checkRelease() {
        if (root._eventsHeld && !root.parked && root._opened && root._grown)
            root._eventsHeld = false;
    }
    function _holdEvents() {
        root._eventsHeld = true;
        root._opened = false;
        openedTimer.stop();
        holdMaxTimer.stop();
    }
    function _openedTurn() {
        openedTimer.restart();
        holdMaxTimer.restart();
    }
    onWidthChanged: root._checkRelease()
    onHeightChanged: root._checkRelease()
    Timer {
        id: openedTimer
        interval: 60
        onTriggered: {
            root._opened = true;
            root._checkRelease();
        }
    }
    Timer {
        id: holdMaxTimer
        interval: root.eventsHoldMaxMs
        onTriggered: {
            root._opened = true;
            root._eventsHeld = false;
        }
    }

    // ---- a kept content is what a fresh open expects --------------------------------------------------
    // Called by the engine when it keeps this content parked after it was shown and closed (and only then: a content without it is
    // thrown away). Secondaries, dates, scroll -- and the first slide of the day's events, which plays again. The TAB is not here:
    // it is the OWNER's rule at the bar's click (ClockBarOwner.toggle), told to this content through its binding, so that what
    // the user last left on is remembered by the owner whatever this reset does.
    function recycle() {
        root.closeWiki();
        root.secondaryKey = null;
        root._wikiShown = "discover";
        root._tintHeld = false;
        root._endGesture();
        // the dates: today, selected, and its month in view
        root.selectedDate = new Date();
        cal.today = new Date();
        cal.goToday();
        // the timers card back on its first view (nothing to do while it has never been shown)
        if (root.timersCard)
            root.timersCard.showView(0);
        // the list scrolled to its top, empty, and waiting for its first slide again
        apptList.reset();
        root._holdEvents();
    }

    // ======================================================================
    // THE WIKI (modules/wiki): a tear-off at the foot of the appointment panel,
    // and the full card as this popup's SECONDARY.
    //
    // `wiki` is the WikiService (or a WikiMock) the clock's bar-side owner keeps
    // alive across closes. With none, nothing here exists: no card is loaded, the
    // list keeps its room (`footReserve` 0), nothing reads the wiki module. Its
    // two types are loaded BY URL and only when there is a service, so this file
    // loads where modules/wiki is not (the clock's own gates copy only common/ and
    // clock/) and where it fails to compile.
    //
    //   the tear-off   WikiCompactCard "tearoff" on the panel's fill, one panel
    //                  margin from the sides and the foot; a click on it toggles
    //                  the secondary, a click on its On-this-day line does the
    //                  same, and Ctrl+click on the line opens it (never closes) and
    //                  follows that day's article inside it
    //   the secondary  WikiPopup, opened through the engine's content contract
    //                  (the stocks detail's shape): `openWiki(tab)` / `closeWiki()`;
    //                  `secondaryKey` is { wiki: "card", tab }, and a new key while
    //                  it is out slides and swaps. A tab switch to Timers closes it
    //                  (the tear-off it hung from is gone), the popup closing does
    //                  not touch `secondaryOpen` (the engine closes the child, this
    //                  content goes with the popup).
    //
    //   wikiSide     "end" (beside the popup, along the bar) | "start" | "far"
    //   wikiAnchor   "link" centred on the tear-off | "start" | "centre" | "end"
    //                (along the side it hangs from, as StocksPopup's detailAnchor)
    //   wikiOverhang may hang past the popup's ends; always on when the card is
    //                longer than the popup along that side (the engine would
    //                otherwise centre it on the popup)
    //
    // `secondaryPersistent` is the engine's TIMING only: a card asked for while the
    // popup is still growing (a notification's click opens both) is held back until
    // the popup is nearly out. Nothing is remembered; nothing opens by itself.
    // The card's height decides the overhang through its `naturalHeight`, which the
    // engine cannot move (its live height includes the cutout the engine writes).
    // ======================================================================
    property var wiki: null
    property string wikiSide: "end"
    property string wikiAnchor: "start"
    property bool wikiOverhang: false
    property string wikiFontFamily: "Inter"
    // The tear-off on the calendar (wiki.jsonc show.calendar). Off, the card itself still opens (openWiki: a notification's click).
    property bool wikiTearoffShown: true

    readonly property alias wikiTearoff: tearoff
    // The tear-off's place on the panel: the panel's own side margin, and the
    // same at the foot; the list ends a gap above it.
    readonly property real _tearFoot: apptList.sideInset
    readonly property real _tearGap: 8
    // `var`: a Loader's item is a QObject to the linter, and these are the wiki's own members.
    readonly property var _tearItem: tearoff.item
    readonly property real _tearH: root._tearItem ? Math.ceil(root._tearItem.implicitHeight) : 0
    readonly property real _wikiReserve: root._tearH > 0 ? root._tearH + root._tearGap + root._tearFoot - apptList.bodyFoot : 0

    // ---- the engine's secondary contract ------------------------------------
    property bool secondaryOpen: false
    // The wiki card opened an article in the browser: the reader has left for it, so the card AND this popup close (the
    // OWNER closes the engine's popup: ClockBarOwner `onCloseRequested`).
    signal closeRequested
    property var secondaryKey: null
    readonly property point secondaryAnchor: root._wikiAnchorPoint(root.wikiAnchor)
    readonly property string secondarySide: root.wikiSide
    readonly property bool secondaryOverhang: root.wikiOverhang || root._wikiLonger
    readonly property real secondaryInset: 0
    readonly property bool secondaryPersistent: true
    // The card's root is loaded by URL, so the engine's half of the contract lives on
    // this Loader, which forwards it: the engine writes `secondaryKey` /
    // `secondaryCutout` / `secondaryMoving` and reads the size and the gesture's.
    property Component secondaryComponent: Component {
        Loader {
            id: card
            property var secondaryKey: null
            property rect secondaryCutout: Qt.rect(0, 0, 0, 0)
            property bool secondaryMoving: false
            readonly property var face: card.item
            readonly property bool swipeGestureActive: !!card.face && card.face.swipeGestureActive === true
            readonly property real gestureHoldWidth: card.face ? card.face.gestureHoldWidth : 0
            readonly property real gestureHoldHeight: card.face ? card.face.gestureHoldHeight : 0
            function gestureWheel(ev) {
                return !!card.face && card.face.gestureWheel(ev) === true;
            }
            source: Qt.resolvedUrl("../wiki/WikiPopup.qml")
            onLoaded: {
                card.face.fontFamily = root.wikiFontFamily;
                card.face.service = root.wiki;
                card.face.showTab(root._wikiShown);
                root._wikiH = card.face.naturalHeight;
                root._wikiW = card.face.cardWidth;
            }
            Binding {
                target: card.item
                property: "secondaryKey"
                value: card.secondaryKey
                when: !!card.item
            }
            Binding {
                target: card.item
                property: "secondaryCutout"
                value: card.secondaryCutout
                when: !!card.item
            }
            Binding {
                target: card.item
                property: "secondaryMoving"
                value: card.secondaryMoving
                when: !!card.item
            }
            Connections {
                target: card.item
                ignoreUnknownSignals: true
                function onCloseRequested() {
                    root.closeWiki();
                }
                function onArticleOpened() {
                    root.closeWiki();
                    root.closeRequested();
                }
                function onNaturalHeightChanged() {
                    root._wikiH = card.face.naturalHeight;
                }
                function onTabChanged() {
                    root._wikiShown = card.face.tab;
                }
            }
        }
    }

    // Where the card sits on its side: the tear-off's centre in this item's
    // coordinates, summed from the geometry that places it (a mapToItem in a binding
    // does not track the layout that moved it, and one read when the card opens, in
    // the frame the content is built, reads a layout that is not there yet), and the
    // card's size along each side (its content-only height beside the popup).
    readonly property point _wikiLink: Qt.point(contentArea.x + calendarTab.x + tearoff.x + tearoff.width / 2,
                                                contentArea.y + calendarTab.y + tearoff.y + tearoff.height / 2)
    property real _wikiH: 480
    property real _wikiW: 448
    // The tab the card shows or is about to (a swipe inside it moves it too).
    property string _wikiShown: "discover"
    readonly property bool _wikiBeside: root.wikiSide === "start" || root.wikiSide === "end"
    readonly property bool _wikiLonger: root._wikiBeside ? root._wikiH > root.implicitHeight + 0.5
                                                         : root._wikiW > root.implicitWidth + 0.5
    function _wikiAnchorPoint(mode) {
        const pw = root.implicitWidth, ph = root.implicitHeight;
        const cw = root._wikiW, ch = root._wikiH;
        switch (mode) {
        case "start":
            return Qt.point(cw / 2, ch / 2);
        case "centre":
            return Qt.point(pw / 2, ph / 2);
        case "end":
            return Qt.point(pw - cw / 2, ph - ch / 2);
        default:
            return root._wikiLink;
        }
    }

    // Open the card on a tab (the calendar's, where its tear-off is). Already out
    // on that tab it is left alone; out on the other it slides to this one.
    function openWiki(tab) {
        if (!root.wiki)
            return;
        const t = tab === "deepen" ? "deepen" : "discover";
        if (root.currentTab !== "calendar")
            root.currentTab = "calendar";
        if (root.secondaryOpen && root._wikiShown === t)
            return;
        root._wikiShown = t;
        root.secondaryKey = { wiki: "card", tab: t };
        root.secondaryOpen = true;
    }
    function closeWiki() {
        root.secondaryOpen = false;
    }
    // Escape's step back (GooeyEngine.stepBack, asked only under shell.jsonc `"escape": "detail"`): the detail goes; true when one was open
    function stepBack(): bool {
        const was = root.secondaryOpen;
        root.closeWiki();
        return was;
    }
    function toggleWiki(tab) {
        if (root.secondaryOpen)
            root.closeWiki();
        else
            root.openWiki(tab);
    }
    function _otdClicked(follow) {
        if (!root.wiki)
            return;
        if (!follow) {
            root.toggleWiki("discover");
            return;
        }
        root.openWiki("discover");
        root.wiki.followOnThisDay();
    }

    // What the card hung from is on the calendar tab only.
    onCurrentTabChanged: {
        // The usage tint lives on the calendar while its key is held.
        root._tintHeld = false;
        if (root.currentTab !== "calendar")
            root.closeWiki();
    }
    onWikiChanged: {
        if (!root.wiki)
            root.closeWiki();
    }

    // ======================================================================
    // TAB SELECTOR
    // ======================================================================
    Common.TabSelector {
        id: tabSel
        anchors.top: parent.top
        anchors.topMargin: root.padding
        anchors.horizontalCenter: parent.horizontalCenter
        // `tabWidth` is the two-tab selector's; a third tab widens it by a slot.
        width: root.screentime ? Math.round(root.tabWidth * 1.5) : root.tabWidth
        height: root.tabHeight
        tabs: root.screentime
            ? [{ id: "calendar", label: "Calendar" }, { id: "timers", label: "Timers" }, { id: "screentime", label: "Screen" }]
            : [{ id: "calendar", label: "Calendar" }, { id: "timers", label: "Timers" }]
        onTabChanged: (id) => { root.currentTab = id; }
        // The popup-wide gesture area below feeds it: a swipe is aimed at
        // the popup, not at this small target.
        swipeSelfHandled: false
    }

    // The selector assigns its own currentTab when a swipe or a click steps
    // it, and a plain `currentTab: root.currentTab` binding dies at that
    // assignment: every later change from outside (the host restoring the
    // last tab) would never reach it, and the next swipe would step from the
    // wrong tab. A Binding element re-applies whenever the value changes.
    Binding {
        target: tabSel
        property: "currentTab"
        value: root.currentTab
    }

    // ======================================================================
    // CONTENT AREA (switches on currentTab)
    // ======================================================================
    Item {
        id: contentArea
        anchors.top: tabSel.bottom
        anchors.topMargin: root.padding
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: root.padding
        anchors.rightMargin: root.padding
        anchors.bottomMargin: root.padding

        // -------------------- CALENDAR TAB --------------------
        Item {
            id: calendarTab
            // Its own width, not the popup's: while the popup grows back
            // from the narrower timers tab, the growing edge reveals the list
            // instead of squeezing it.
            x: 0
            y: 0
            width: cal.implicitWidth + root.padding + root.listWidth
            height: parent.height
            visible: root.currentTab === "calendar"

            CalendarView {
                id: cal
                anchors.top: parent.top
                anchors.left: parent.left
                calendarData: root.calendarData
                weekStart: root.weekStart
                selectedDate: root.selectedDate
                weekOffsetStore: weekOffsets
                yearModifier: root.yearModifier
                usageTint: root._tintMap
                usageTintF: root._tintMap ? root._tintF : 0
                usageTintColor: Theme.accent
                onDaySelected: (d) => { root.selectedDate = d; }
            }

            MonthHeader {
                id: header
                anchors.top: cal.bottom
                anchors.topMargin: root.monthHeaderGap
                anchors.left: cal.left
                width: cal.width
                viewYear: cal.viewYear
                viewMonth: cal.viewMonth
                yearModifier: root.yearModifier
                todayShown: !cal.todayInView && !cal.todaySelected
                onStep: (months) => root.stepMonth(months)
                onReturnToToday: cal.goToday()
            }

            AppointmentList {
                id: apptList
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.left: cal.right
                anchors.leftMargin: root.padding
                anchors.right: parent.right
                calendarData: root.calendarData
                visibilityStore: visStore
                day: root.selectedDate
                // Suppress full ListModel rebuild while the calendar grid
                // is mid-slide — the selector is hidden during the slide
                // anyway, so intermediate day changes from a rapid burst
                // are invisible. We rebuild once on settle.
                slideActive: cal._slideActive
                backgroundColor: Theme.panelSunk
                footReserve: root._wikiReserve
                startHeld: root._eventsHeld
            }

            // The wiki's tear-off (see THE WIKI): by URL, only with a service.
            Loader {
                id: tearoff
                objectName: "wikiTearoff"
                active: root.wiki !== null && root.wikiTearoffShown
                source: Qt.resolvedUrl("../wiki/WikiCompactCard.qml")
                x: apptList.x + apptList.sideInset
                width: root.listWidth - 2 * apptList.sideInset
                height: root._tearH
                y: apptList.y + apptList.height - root._tearFoot - height
                z: 20
                onLoaded: {
                    // The card is loaded by URL (the clock's own gates snapshot only common + clock): the linter
                    // knows the loader's item as a bare QObject.
                    // qmllint disable missing-property
                    tearoff.item.variant = "tearoff";
                    tearoff.item.tab = "discover";
                    // qmllint enable missing-property
                }
                Binding {
                    target: tearoff.item
                    property: "service"
                    value: root.wiki
                    when: !!tearoff.item
                }
                Binding {
                    target: tearoff.item
                    property: "groundColor"
                    value: apptList.backgroundColor
                    when: !!tearoff.item
                }
                Binding {
                    target: tearoff.item
                    property: "fontFamily"
                    value: root.wikiFontFamily
                    when: !!tearoff.item
                }
                // Its one motion (the presence fade, the skeleton's breath) and its
                // seen-count run only while the calendar is the tab on show.
                Binding {
                    target: tearoff.item
                    property: "active"
                    value: calendarTab.visible && !root.parked
                    when: !!tearoff.item
                }
                Connections {
                    target: tearoff.item
                    ignoreUnknownSignals: true
                    function onActivated(card) {
                        root.toggleWiki("discover");
                    }
                    function onOnThisDayActivated(follow: bool) {
                        root._otdClicked(follow);
                    }
                }
            }
        }

        // -------------------- TIMERS TAB --------------------
        // Built when first shown (see `timersCard`), then kept. The card's CONTENT is square, centred by hand on whole pixels; its
        // CARVED BOX is as wide as the room the popup has round it (`boxWidth`): coming from the much wider calendar the container
        // starts wide and narrows to the square as the popup does, and from the Screen tab it starts at that tab's width -- it
        // closes in with the transition instead of standing still while the walls come in round it.
        property bool _tmShown: false
        Loader {
            id: tmLoader
            active: root.eagerTimers || root.currentTab === "timers" || contentArea._tmShown
            width: root._contentHeight
            height: root._contentHeight
            x: Math.round((parent.width - width) / 2)
            y: 0
            visible: root.currentTab === "timers"
            onVisibleChanged: if (visible) contentArea._tmShown = true
            sourceComponent: Component {
                TimersCard {
                    side: root._contentHeight
                    boxWidth: Math.max(width, contentArea.width)
                    active: tmLoader.visible && !root.parked
                    timers: root._timers
                    // A list reads the wheel only while a gesture is its own: one
                    // that began elsewhere on the card must not scroll it on the way.
                    listWheelEnabled: !root._gestureActive || root._gestureOwner === "list"
                }
            }
        }

        // -------------------- SCREENTIME TAB --------------------
        // Only with a service, and only once the tab has been shown (latched:
        // switching away keeps the card and its morph state).
        property bool _stShown: false
        Loader {
            id: stLoader
            objectName: "screentimeCard"
            active: root.screentime !== null && (contentArea._stShown || root.currentTab === "screentime")
            source: Qt.resolvedUrl("../screentime/ScreentimeCard.qml")
            width: root.screentimeWidth
            height: parent.height
            x: Math.round((parent.width - width) / 2)
            y: 0
            visible: root.currentTab === "screentime"
            onVisibleChanged: if (visible) contentArea._stShown = true
            onLoaded: {
                contentArea._stShown = true;
                root._stCard.face = root.screentimeFace;
            }
            Binding { target: stLoader.item; property: "service"; value: root.screentime; when: !!stLoader.item }
            Binding { target: stLoader.item; property: "hostHeight"; value: root._contentHeight; when: !!stLoader.item }
            Binding {
                target: stLoader.item
                property: "listWheelEnabled"
                value: !root._gestureActive || root._gestureOwner === "stlist"
                when: !!stLoader.item
            }
            Connections {
                target: stLoader.item
                ignoreUnknownSignals: true
                function onFaceChanged() {
                    root.screentimeFace = root._stCard.face;
                }
            }
        }
    }
    // The service subscribes to focus pushes only while the card is on show
    // (CONTRACT §9: `live` is the host's). The service outlives this popup.
    Binding {
        target: root.screentime
        property: "live"
        value: stLoader.visible && !!stLoader.item
        when: !!root.screentime
    }
    Component.onDestruction: {
        if (root.screentime)
            root.screentime.live = false;
    }

    // ======================================================================
    // TWO-FINGER SWIPE (docs/contracts/gestures.md)
    //
    // One area over the whole popup hears every wheel and never accepts it,
    // so the lists underneath still scroll. A gesture is given to ONE owner
    // where it begins. SIDEWAYS: over the month (the grid and the month line
    // under it) it steps the month -- a year with `yearModifier` -- and
    // anywhere else it moves the tab selector (on the Screen tab, over the
    // faces card it steps the week, and up / down cycles the faces). UP / DOWN, on the Timers tab:
    // over the dial while it can be wound it winds it, over a duration it
    // sets it, over a list that scrolls the list has it, and anywhere else
    // on the card it cycles the card's views. The axis is picked once one
    // leads and kept until the fingers lift.
    // ======================================================================
    property bool _gestureActive: false
    // "month" | "tabs" | on the timers card: "dial" | "field" | "list" | "card"
    // | on the screentime card: "week" (the faces card) | "stlist" (its list)
    property string _gestureOwner: ""
    property var _gestureTarget: null
    property string _gestureAxis: ""         // "" until one axis leads
    property real _monthAccum: 0

    function _overMonth(px, py) {
        if (!calendarTab.visible)
            return false;
        const p = cal.mapToItem(root, 0, 0);
        const bottom = header.mapToItem(root, 0, header.height).y;
        return px >= p.x && px < p.x + cal.width && py >= p.y && py < bottom;
    }

    function _endGesture() {
        gestureIdleTimer.stop();
        if (root._gestureOwner !== "month" && root._gestureOwner !== "")
            tabSel.applySwipe(0);
        if (root._gestureOwner === "card" && root.timersCard)
            root.timersCard.endCycle();
        else if (root._gestureOwner === "week" && root._stCard)
            root._stCard.endGesture();
        else if (root._gestureOwner === "field" && root._gestureTarget)
            root._gestureTarget.endWheel();
        root._gestureActive = false;
        root._gestureOwner = "";
        root._gestureTarget = null;
        root._gestureAxis = "";
        root._monthAccum = 0;
    }

    Timer {
        id: gestureIdleTimer
        interval: root.gestureIdleEndMs
        onTriggered: root._endGesture()
    }

    // One wheel event (WheelHub's), in THIS item's coordinates (px, py). The
    // area below and gestureWheel() both land here.
    function _wheel(px, py, ev) {
        const ad = ev.angleDelta, pd = ev.pixelDelta, modifiers = ev.modifiers;
        const mouse = ev.device === "wheel";
        // Each axis in angle units. `xPixels`/`yPixels` say the DEVICE reports
        // pixels -- a touchpad, which on Wayland sends angle deltas too, so
        // an angle delta alone does not say it is a mouse (CLAUDE.md).
        const xPixels = pd.x !== 0;
        const yPixels = pd.y !== 0;
        const dx = ad.x !== 0 ? ad.x : pd.x * root.swipePixelToAngle;
        const dy = ad.y !== 0 ? ad.y : pd.y * root.swipePixelToAngle;
        // Zero on both axes is the touchpad's scroll-end: the fingers
        // left the surface. That, not the timer, ends a gesture.
        if (dx === 0 && dy === 0) {
            root._endGesture();
            return;
        }
        gestureIdleTimer.restart();
        if (!root._gestureActive) {
            // The owner FIRST: the next line grows the area about the
            // popup's centre, and (px, py) are from before that.
            if (tmLoader.visible && root.timersCard) {
                const o = root.timersCard.ownerAt(px - tmLoader.x - contentArea.x, py - tmLoader.y - contentArea.y);
                root._gestureOwner = o.kind;
                root._gestureTarget = o.target;
            } else if (stLoader.visible) {
                // The faces card owns a swipe begun over it (sideways steps
                // the week, up/down cycles the faces); a list that scrolls
                // owns its own; anywhere else a sideways swipe moves the tabs.
                const k = root._stCard ? root._stCard.ownerAt(px - stLoader.x - contentArea.x, py - stLoader.y - contentArea.y) : "";
                root._gestureOwner = k === "week" ? "week" : k === "list" ? "stlist" : "tabs";
            } else {
                root._gestureOwner = root._overMonth(px, py) ? "month" : "tabs";
            }
            root._gestureActive = true;
            root._gestureAxis = "";
            root._monthAccum = 0;
        }
        if (root._gestureAxis === "") {
            if (Math.abs(dx) > Math.abs(dy) * 1.2)
                root._gestureAxis = "x";
            else if (Math.abs(dy) > Math.abs(dx) * 1.2)
                root._gestureAxis = "y";
        }
        if (root._gestureAxis === "y" && dy !== 0) {
            if (root._gestureOwner === "dial" && root.timersCard)
                root.timersCard.windBy(dy, yPixels, modifiers);
            else if (root._gestureOwner === "field" && root._gestureTarget)
                root._gestureTarget.wheel(dy, yPixels, modifiers);
            else if (root._gestureOwner === "card" && root.timersCard)
                // Fingers up, the dots' bead goes up: the previous view. (A mouse rolled down: the next one.)
                root.timersCard.cycleBy(mouse ? 120 * ev.steps : dy, yPixels);
            else if (root._gestureOwner === "week" && root._stCard)
                root._stCard.cycleFacesBy(mouse ? 120 * ev.steps : dy, yPixels);
            else if (root._gestureOwner === "month" && mouse && ev.steps !== 0)
                // a mouse over the month: a notch is a month (it has no sideways of its own)
                root.stepMonth(ev.steps * cal.monthsFor(modifiers));
        }
        if (root._gestureAxis === "x" && dx !== 0) {
            if (root._gestureOwner === "week" && root._stCard) {
                root._stCard.stepWeekBy(mouse ? 120 * ev.steps : dx, xPixels);
            } else if (root._gestureOwner !== "month") {
                if (mouse)
                    tabSel.applySteps(ev.steps);
                else
                    tabSel.applySwipe(dx);
            } else if (mouse) {
                if (ev.steps !== 0)
                    root.stepMonth(ev.steps * cal.monthsFor(modifiers));
            } else {
                root._monthAccum += dx;
                if (Math.abs(root._monthAccum) >= root.swipeThreshold) {
                    const dir = root._monthAccum < 0 ? 1 : -1;
                    root.stepMonth(dir * cal.monthsFor(modifiers));
                    root._monthAccum = 0;
                }
            }
        }
    }

    // A wheel the HOST forwards while a gesture lives (it landed outside this
    // content: a tab switch made the popup narrower under the fingers). A
    // forwarded wheel never starts a gesture. Returns whether it was used.
    function gestureWheel(ev) {
        if (!root._gestureActive || !ev)
            return false;
        root._wheel(ev.x, ev.y, ev);
        return true;
    }

    WheelArea {
        id: swipeArea
        // Grown about the popup's centre while a gesture lives, so a tab
        // that is narrower keeps hearing the rest of the swipe.
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        width: root._gestureActive ? Math.max(root.width, root.gestureHoldWidth) : root.width
        height: root._gestureActive ? Math.max(root.height, root.gestureHoldHeight) : root.height
        z: 200

        turned: wheel => {
            root._wheel(swipeArea.x + wheel.x, swipeArea.y + wheel.y, wheel);
            wheel.accepted = false;
        }
    }
}
