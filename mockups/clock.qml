pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/common/mockup"
import "modules/clock"
import "modules/clock/data"
import "modules/common/components"
import "modules/common/theme"
import "modules/bar/workspaces"
// The Screen tab's card is loaded BY URL from the clock, and a file loaded by
// URL resolves its own directory's types only while some import names that
// directory (CLAUDE.md, the wiki's trap). The clock's gates run their own
// probe files, never this one, so the import costs them nothing; the bar's
// assembly imports it the same way.
import "modules/screentime" as ScreentimeDir

// =============================================================================
// mockups/clock.qml -- the clock popup and its bar button, on the mockup
// framework (modules/common/mockup/, contract in
// docs/contracts/mockup_framework.md).
//
// The stage holds ClockPopupContent alone, at its own implicit size: the
// drop-in for thePopup. The bar button is not popup content, so it is shown
// on the Button tab, horizontal and vertical side by side, beside its values.
//
// Two data sources:
//   MockCalendarData  hardcoded, April 2026 scenarios (the Run tab's jumps)
//   CalendarService   calendars.jsonc -> ICS feeds, disk-cached
// The real service is the default whenever calendars.jsonc lists a calendar.
//
// Env (this file's own; the framework's GRAB / PANEL_* still apply):
//   DATA=mock|real   the source at load (a render wants mock: fixed data)
//   TAB=calendar|timers   the popup's tab at load
//   FAILED=1         (mock data) the Work calendar's feed failed: the list's "Could not load" note
//
//   quickshell -p mockups/clock.qml
//   tools/dev/mockup_grab.sh mockups/clock.qml --list
// =============================================================================
MockupWindow {
    id: win

    moduleId: "clock"
    title: "Clock mockup"
    stageLabel: "ClockPopupContent (drop-in for thePopup)"
    // The tabs are different widths: the stage cuts the content to its
    // easing box as the bar's engine does, so a tab switch shows what the
    // bar will while the popup grows.
    clipContent: true
    content: popup
    target: popup
    targets: ({
            calendarParams: popup.calendar,
            headerParams: popup.monthHeader,
            listParams: popup.appointments,
            barHParams: hBtn,
            barVParams: vBtn,
            timersParams: popup.timersCard,
            barFillParams: barPreview
        })

    lists: ({
            layoutParams: win.layoutParams,
            calendarParams: win.calendarParams,
            headerParams: win.headerParams,
            listParams: win.listParams,
            barHParams: win.barHParams,
            barVParams: win.barVParams,
            timersParams: win.timersParams,
            barFillParams: win.barFillParams
        })

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Layout",
            lists: ["layoutParams"]
        },
        {
            name: "Calendar",
            lists: ["calendarParams"]
        },
        {
            name: "Month",
            lists: ["headerParams"]
        },
        {
            name: "List",
            lists: ["listParams"]
        },
        {
            name: "Timers",
            lists: ["timersParams"],
            page: timersPage
        },
        {
            name: "Button",
            lists: ["barHParams", "barVParams"],
            page: buttonPage
        },
        {
            name: "Bar",
            lists: ["barFillParams"],
            page: barPage
        }
    ]

    // =====================================================================
    //  DATA
    // =====================================================================
    MockCalendarData {
        id: mockData
        failedFeeds: (Quickshell.env("FAILED") ?? "") === "1" ? [{ name: "Work", reason: "curl exit 6" }] : []
    }
    CalendarConfig {
        id: realConfig
    }
    CalendarService {
        id: realService
        config: realConfig
    }

    // ---- The timers ------------------------------------------------------
    // The mockup's own clock (the Timers tab can run it 600x or jump it
    // like a suspend), its own service in memory only, and a notifier that
    // writes to the Timers tab instead of the desktop: the live shell and a
    // mockup must never both ring. Real notify-send and sound are opt-in.
    TimerClock {
        id: timerClock
    }
    property bool realNotify: false
    property bool realSound: false
    ListModel {
        id: noteLog
    }
    property var lastNote: null
    QtObject {
        id: logNotifier
        signal action(string key, string id)
        function notify(key, spec) {
            win.lastNote = { key: key, actions: spec.actions || [] };
            noteLog.insert(0, { line: Qt.formatTime(new Date(timerClock.now()), "HH:mm:ss") + "  " + key + ": " + spec.title + " \u2014 " + spec.body });
            while (noteLog.count > 6)
                noteLog.remove(6);
        }
        function withdraw(key) {
            if (win.lastNote && win.lastNote.key === key)
                win.lastNote = null;
        }
    }
    DesktopNotifier {
        id: realNotifier
    }
    SoundPlayer {
        id: realSound
    }
    TimerService {
        id: timerSvc
        clock: timerClock
        persist: false
        notifier: win.realNotify ? realNotifier : logNotifier
        sound: win.realSound ? realSound : null
    }

    // The bar's dust when something finishes, as the bar-side owner will do it.
    Connections {
        target: timerSvc
        function onFinished(kind, info) {
            if (kind === "countdown")
                barPreview.burst(-1, 0);
            else if (kind === "pomodoro")
                barPreview.burst(info.phase === "long" ? -1 : info.session, info.phase === "focus" ? 1 : 2);
        }
    }

    readonly property string _envData: Quickshell.env("DATA") ?? ""
    // A binding until a Run-tab button assigns it: follows calendars.jsonc
    // appearing or vanishing, then keeps what the user picked.
    property string dataSource: win._envData === "mock" || win._envData === "real" ? win._envData : (realConfig.available ? "real" : "mock")
    readonly property var activeData: win.dataSource === "real" ? realService : mockData

    // "config" takes calendars.jsonc's weekStart (Monday unless it says
    // otherwise); the other two override it.
    property string weekStartMode: "config"

    // The Screen tab (modules/screentime) on a ScreentimeMock: loaded BY URL
    // and only when switched on (SCREENTIME=1 or the Run tab), so the clock's
    // own gates, which copy only common/ and clock/, never meet it.
    property bool screentimeOn: (Quickshell.env("SCREENTIME") ?? "") === "1"
    Loader {
        id: stMock
        active: win.screentimeOn
        source: Qt.resolvedUrl("modules/screentime/data/ScreentimeMock.qml")
    }

    Component.onCompleted: {
        const tab = Quickshell.env("TAB") ?? "";
        if (tab === "calendar" || tab === "timers" || (tab === "screentime" && win.screentimeOn))
            popup.currentTab = tab;
    }

    function jumpTo(y, m, d) {
        popup.selectedDate = new Date(y, m, d);
        popup.gotoMonth(y, m);
    }

    // =====================================================================
    //  THE DROP-IN CONTENT
    // =====================================================================
    ClockPopupContent {
        id: popup
        // the panel's Timers tab tunes the card, which a drop-in builds only when its tab is first shown
        eagerTimers: true
        calendarData: win.activeData
        weekStart: win.weekStartMode === "monday" ? 1 : win.weekStartMode === "sunday" ? 0 : realConfig.weekStart
        timers: timerSvc
        screentime: win.screentimeOn && stMock.item ? stMock.item : null
    }

    // =====================================================================
    //  PAGES
    // =====================================================================
    pages: [
        MockupPage {
            id: timersPage

            TipGroup {
                title: "Time"
                blurb: "The timers run on the mockup's own clock."
            }
            TipRow {
                tip: "How fast the mockup's clock runs. At 60x a 25-minute session takes 25 seconds and the ring and the bar can be watched filling; 600x runs a whole pomodoro cycle in about four minutes. Everything is on this clock -- the card, the service and the Bar tab's groove -- so they stay in step."
                Label {
                    text: "Speed"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Repeater {
                    model: [1, 10, 60, 600]
                    delegate: Button {
                        required property int modelData
                        text: modelData + "x"
                        checkable: true
                        checked: timerClock.scale === modelData
                        onClicked: timerClock.scale = modelData
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Moves the clock on at once, the way a suspend does: whatever should have happened in between happens on the next evaluation and is LATE -- silent, a notification saying when. +8 h is the case the service probe gates: a countdown that ended hours ago, an alarm missed."
                Repeater {
                    model: [{ l: "+1 min", ms: 60000 }, { l: "+10 min", ms: 600000 }, { l: "+1 h", ms: 3600000 }, { l: "+8 h", ms: 28800000 }]
                    delegate: Button {
                        required property var modelData
                        text: modelData.l
                        Layout.fillWidth: true
                        onClicked: timerClock.jump(modelData.ms)
                    }
                }
            }

            TipGroup {
                title: "Scenarios"
                blurb: "A state to look at, set in one click."
            }
            TipRow {
                tip: "Timer: 25 minutes, 10 already run. Pomodoro: session 2's break under way, session 1 done. Alarm: one set a minute from now (the clock's minute), to see it ring. Laps: a running stopwatch with three laps."
                Button {
                    text: "Timer"
                    Layout.fillWidth: true
                    onClicked: {
                        const now = timerClock.now();
                        timerSvc.countdown = { state: "running", setMs: 1500000, totalMs: 1500000, startedAt: now - 600000,
                                               endsAt: now + 900000, remainMs: 900000, doneAt: 0 };
                        timerSvc._changed();
                        popup.currentTab = "timers";
                        popup.timersCard.showView(0);
                    }
                }
                Button {
                    text: "Pomodoro"
                    Layout.fillWidth: true
                    onClicked: {
                        const now = timerClock.now();
                        timerSvc.pomodoro = { state: "running", phase: "short", session: 1, phaseMs: timerSvc.shortMs,
                                              startedAt: now - 120000, endsAt: now + timerSvc.shortMs - 120000, remainMs: timerSvc.shortMs - 120000,
                                              pieces: [{ focus: 1, brk: 1 }, { focus: 1, brk: 0 }, { focus: 0, brk: 0 }, { focus: 0, brk: 0 }], next: null };
                        timerSvc._changed();
                        popup.currentTab = "timers";
                        popup.timersCard.showView(1);
                    }
                }
                Button {
                    text: "Alarm"
                    Layout.fillWidth: true
                    onClicked: {
                        const d = new Date(timerClock.now() + 60000);
                        timerSvc.addAlarm(d.getHours(), d.getMinutes(), "Mockup", 0);
                        popup.currentTab = "timers";
                        popup.timersCard.showView(3);
                    }
                }
                Button {
                    text: "Laps"
                    Layout.fillWidth: true
                    onClicked: {
                        timerSvc.swReset();
                        timerSvc.stopwatch = { state: "running", startedAt: timerClock.now() - 83400, accumMs: 0 };
                        timerSvc.laps.append({ n: 1, lapMs: 24100, totalMs: 24100 });
                        timerSvc.laps.insert(0, { n: 2, lapMs: 31800, totalMs: 55900 });
                        timerSvc.laps.insert(0, { n: 3, lapMs: 19500, totalMs: 75400 });
                        timerSvc._changed();
                        popup.currentTab = "timers";
                        popup.timersCard.showView(2);
                    }
                }
            }

            TipGroup {
                title: "What would reach the desktop"
                blurb: "Notifications are logged here unless the real ones are switched on."
            }
            TipRow {
                tip: "Off (the default), a finished timer, a pomodoro phase or an alarm is written to the log below and nothing leaves the mockup. On, it goes out through notify-send exactly as the bar's own clock will send it, with its buttons -- and the live shell, if it has timers running, is a separate service: the two do not share state."
                Switch {
                    checked: win.realNotify
                    onToggled: win.realNotify = checked
                }
                Label {
                    text: "Real notifications"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Switch {
                    checked: win.realSound
                    onToggled: win.realSound = checked
                }
                Label {
                    text: "Sound"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The buttons of the last logged notification, as a click on the real one would press them: Stop, Snooze, Restart, Start break ..."
                Repeater {
                    model: win.lastNote ? win.lastNote.actions : []
                    delegate: Button {
                        required property var modelData
                        text: modelData.label
                        onClicked: logNotifier.action(win.lastNote.key, modelData.id)
                    }
                }
                Label {
                    visible: !win.lastNote || win.lastNote.actions.length === 0
                    text: "no buttons pending"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            Repeater {
                model: noteLog
                delegate: Label {
                    required property string line
                    Layout.fillWidth: true
                    text: line
                    wrapMode: Text.WordWrap
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 11
                }
            }
        },
        MockupPage {
            id: barPage

            TipGroup {
                title: "The groove"
                blurb: "Workspaces, fed by the same service as the card."
            }
            TipRow {
                tip: "The Workspaces module as a bar carries it, its fills given by the timers' barFills on the mockup's clock: a countdown fills the whole bar along its length; a pomodoro fills the four pieces round the clock one session each, every one left to right (left line, the lower track -- the ball's own path --, the upper track, right line), a break refills its piece in the lighter tone, and the long break drains them all. Run a scenario on the Timers tab and speed the clock up to watch it."
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 120
                    radius: 14
                    color: Theme.surface
                    Workspaces {
                        id: barPreview
                        anchors.fill: parent
                        anchors.margins: 12
                        allWorkspaces: []
                        activeWorkspaceId: 1
                        fills: timerSvc.barFills
                        fillClock: timerClock
                    }
                }
            }
        },
        MockupPage {
            id: runPage

            TipGroup {
                title: "Data"
                blurb: "What the calendar is fed."
            }

            TipRow {
                tip: "Where the events come from. mock is MockCalendarData: fixed April 2026 scenarios (9 dots, overflow, all-day, multi-day), the ones the jumps below land on. real is CalendarService reading calendars.jsonc and fetching each Proton share link; it is the default whenever calendars.jsonc lists a calendar, and it is read-only, so nothing here touches the calendars themselves."
                Label {
                    text: "Source"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Button {
                    text: "mock"
                    checkable: true
                    checked: win.dataSource === "mock"
                    onClicked: win.dataSource = "mock"
                }
                Button {
                    text: "real"
                    checkable: true
                    enabled: realConfig.available
                    checked: win.dataSource === "real"
                    onClicked: win.dataSource = "real"
                }
                Button {
                    text: "Refresh feeds"
                    enabled: win.dataSource === "real"
                    onClicked: realService.refresh()
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipRow {
                tip: "The popup's third tab, Screen time (modules/screentime), fed by a ScreentimeMock: seeded synthetic weeks. Off (the default), the popup is what the bar shows without a screentime service -- two tabs, nothing of modules/screentime loaded. Its own mockup, mockups/screentime.qml, has the card's every knob and the live simulation."
                CheckBox {
                    text: "Screen tab (mock)"
                    checked: win.screentimeOn
                    onToggled: {
                        if (!checked && popup.currentTab === "screentime")
                            popup.currentTab = "calendar";
                        win.screentimeOn = checked;
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipRow {
                tip: "What the real source is doing: how many calendars calendars.jsonc lists, whether a fetch is running, and the last error of either the config or a feed. The mock source has none of this."
                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: {
                        if (!realConfig.available)
                            return realConfig.lastError.length > 0 ? "Config error: " + realConfig.lastError : "No calendars.json -- real is unavailable";
                        let s = realConfig.entries.length + " calendar(s) in calendars.json";
                        if (win.dataSource !== "real")
                            return s;
                        if (realService.loading)
                            return s + " -- fetching...";
                        if (realService.lastError.length > 0)
                            return s + " -- last error: " + realService.lastError;
                        return s + " -- " + realService.events.length + " events";
                    }
                    color: realConfig.lastError.length > 0 || realService.lastError.length > 0 ? "#EC0000" : "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                }
            }

            TipRow {
                tip: "First day of the week, which orders the weekday initials and the week rows. config takes calendars.jsonc's weekStart (Monday when it says nothing, the ISO week the week numbers follow); Monday and Sunday override it for this session."
                Label {
                    text: "Week starts"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Repeater {
                    model: ["config", "monday", "sunday"]
                    delegate: Button {
                        required property string modelData
                        text: modelData
                        checkable: true
                        checked: win.weekStartMode === modelData
                        onClicked: win.weekStartMode = modelData
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Navigate"
                blurb: "The same calls the popup's own arrows, swipe and keys make."
            }

            TipRow {
                tip: "Which of the popup's two tabs is showing. The popup keeps it in currentTab; thePopup's Loader recreates the content on every open, so remembering it across opens is the host's job."
                Label {
                    text: "Tab"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Repeater {
                    model: ["calendar", "timers"]
                    delegate: Button {
                        required property string modelData
                        text: modelData
                        checkable: true
                        checked: popup.currentTab === modelData
                        onClicked: popup.currentTab = modelData
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipRow {
                tip: "Steps the viewed month through stepMonth(), the path the header's chevrons, the swipe and PgUp/PgDn take: the six week rows slide with their stagger, and a burst of clicks queues a multi-month run (with motion blur past the onset). The year buttons are the same step with Ctrl held. Today selects today and goes to its month, like the T key."
                Button {
                    text: "<< year"
                    Layout.fillWidth: true
                    onClicked: popup.stepMonth(-12)
                }
                Button {
                    text: "< prev"
                    Layout.fillWidth: true
                    onClicked: popup.stepMonth(-1)
                }
                Button {
                    text: "today"
                    Layout.fillWidth: true
                    onClicked: {
                        const n = new Date();
                        win.jumpTo(n.getFullYear(), n.getMonth(), n.getDate());
                    }
                }
                Button {
                    text: "next >"
                    Layout.fillWidth: true
                    onClicked: popup.stepMonth(1)
                }
                Button {
                    text: "year >>"
                    Layout.fillWidth: true
                    onClicked: popup.stepMonth(12)
                }
            }

            TipRow {
                tip: "Days of the mock data that exercise one case each: the mock's own today (Apr 23), nine dots (Apr 14), more than nine -- the ninth dot becomes a plus (Apr 15), and an all-day event (Apr 9). They select the day on the real source too, where they show whatever is on it."
                Repeater {
                    model: [
                        {
                            label: "Apr 23",
                            d: 23
                        },
                        {
                            label: "9 dots",
                            d: 14
                        },
                        {
                            label: "overflow",
                            d: 15
                        },
                        {
                            label: "all-day",
                            d: 9
                        }
                    ]
                    delegate: Button {
                        required property var modelData
                        text: modelData.label
                        Layout.fillWidth: true
                        onClicked: win.jumpTo(2026, 3, modelData.d)
                    }
                }
            }

            TipGroup {
                title: "State"
                blurb: "What the popup holds right now."
            }

            Label {
                Layout.fillWidth: true
                text: "selected " + Qt.formatDate(popup.selectedDate, "yyyy-MM-dd") + "   events " + win.activeData.countForDay(popup.selectedDate) + "\nviewing " + popup.calendar.viewYear + "-" + String(popup.calendar.viewMonth + 1).padStart(2, "0") + "   size " + popup.implicitWidth.toFixed(0) + " x " + popup.implicitHeight.toFixed(0)
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
                lineHeight: 1.3
            }
        },
        MockupPage {
            id: buttonPage

            TipGroup {
                title: "Preview"
                blurb: "ClockBarButton as a horizontal and a vertical bar carry it."
            }

            TipRow {
                tip: "The bar button in both orientations. Horizontal is one line, 12:34; vertical stacks the hour over the minutes, both upright, because rotated text is not an option in a vertical bar. In the bar it sits in the Workspaces split inside a gooey button; here it is the text alone on the bar's surface."
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 110
                    color: Theme.panelSunk
                    radius: 14
                    ClockBarButton {
                        id: hBtn
                        anchors.centerIn: parent
                        orientation: "horizontal"
                        forceSeconds: win.holdSeconds
                        overrideDate: win.freezeClock ? win._frozenAt : null
                    }
                }
                Rectangle {
                    Layout.preferredWidth: 90
                    Layout.preferredHeight: 110
                    color: Theme.panelSunk
                    radius: 14
                    ClockBarButton {
                        id: vBtn
                        anchors.centerIn: parent
                        orientation: "vertical"
                        overrideDate: win.freezeClock ? win._frozenAt : null
                    }
                }
            }

            TipRow {
                tip: "Holds the seconds out on the horizontal preview as if the pointer were on it. In the bar the pointer does it: hovering the clock brings the seconds in on its right, the hours and minutes give way, and the Workspaces assembly widens the clock's slot (the dots on either side move out) by the room they take. Here the preview is the text alone, so only the figures move."
                Switch {
                    checked: win.holdSeconds
                    onToggled: win.holdSeconds = checked
                }
                Label {
                    text: "Hold the seconds out"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipRow {
                tip: "Freezes both previews at 12:34 through the button's overrideDate, for renders that must match run to run. Off, they follow the system clock at minute precision, as the bar does."
                Switch {
                    checked: win.freezeClock
                    onToggled: win.freezeClock = checked
                }
                Label {
                    text: "Freeze at 12:34"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Item {
                    Layout.fillWidth: true
                }
            }
        }
    ]

    property bool freezeClock: false
    property bool holdSeconds: false
    readonly property date _frozenAt: new Date(2026, 3, 23, 12, 34)

    // =====================================================================
    //  VALUES
    // =====================================================================
    readonly property var layoutParams: [
        {
            label: "padding",
            prop: "padding",
            group: "Layout",
            blurb: "The popup's frame: its edges, the tab row and the two columns.",
            tip: "Space on every edge of the popup, under the tab row, and between the calendar and the appointment list. 12 is the shell's popup padding, so the space above equals the space below.",
            val: 12,
            from: 0,
            to: 32,
            step: 1
        },
        {
            label: "list width",
            prop: "listWidth",
            group: "Layout",
            tip: "Width of the appointment list beside the calendar. The popup's width is the calendar's own width plus this plus three paddings; 222 is what the popup's original 740 px left for it.",
            val: 222,
            from: 160,
            to: 400,
            step: 1
        },
        {
            label: "month header gap",
            prop: "monthHeaderGap",
            group: "Layout",
            tip: "Space between the last week row and the month / year line under the grid. 4, because the header's 40 px box already centres its text with air of its own.",
            val: 4,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "tab width",
            prop: "tabWidth",
            group: "Tab row",
            blurb: "The Calendar / Timers selector across the top.",
            tip: "Width of the Calendar / Timers selector, centred at the top. 280 gives each of the two labels room at Audiowide without the pill running to the popup's edges.",
            val: 280,
            from: 160,
            to: 500,
            step: 1
        },
        {
            label: "tab height",
            prop: "tabHeight",
            group: "Tab row",
            tip: "Height of the tab selector's track. 34 matches the other popups' tab rows.",
            val: 34,
            from: 24,
            to: 48,
            step: 1
        },
        {
            label: "swipe threshold",
            prop: "swipeThreshold",
            group: "Swipe",
            blurb: "The two-finger side-swipe over the grid.",
            tip: "Horizontal wheel travel (angleDelta units) a side-swipe that begins over the month -- the grid or the month line -- accumulates before it steps one month (a year with Ctrl held). A swipe that begins anywhere else moves the Calendar / Timers selector instead. 800 is one deliberate swipe on the touchpad and never a drift of a vertical scroll.",
            val: 800,
            from: 200,
            to: 2000,
            step: 50
        }
    ]

    readonly property var calendarParams: [
        {
            label: "cell size",
            prop: "cellSize",
            group: "Grid",
            blurb: "The month grid: seven columns, six week rows.",
            tip: "Side of one day cell, which is also the size of the today and selected squares. The grid is 7 x 6 of these, so this sizes the whole left column and, through it, the popup. 64 fits three rows of three dots under the number.",
            val: 64,
            from: 40,
            to: 96,
            step: 1
        },
        {
            label: "week column",
            prop: "weekColWidth",
            group: "Grid",
            tip: "Width of the week-number column in front of each row. 34 holds a two-digit week number, or a negative one after rebasing, at its smaller size.",
            val: 34,
            from: 20,
            to: 60,
            step: 1
        },
        {
            label: "weekday row",
            prop: "headerHeight",
            group: "Grid",
            tip: "Height of the weekday-initials row above the grid. 26 is one line of the initials with a little air under it.",
            val: 26,
            from: 16,
            to: 44,
            step: 1
        },
        {
            label: "glide ms",
            prop: "selectionAnimDuration",
            group: "Selector",
            blurb: "The coloured square that marks the selected day.",
            tip: "Duration of the selected-day square's glide to a new day in the same month: the longer axis first, then the shorter, one easing curve over the whole path. 420 is long enough to read the path, short enough not to wait on it.",
            val: 420,
            from: 0,
            to: 1200,
            step: 10
        },
        {
            label: "scale ms",
            prop: "scaleAnimDuration",
            group: "Selector",
            tip: "Duration of the square's scale changes: shrinking to 0.92 while it sits on today, so today's deeper ring shows round it, and scaling in on day 1 after a month change. 300 is quick enough not to trail the glide.",
            val: 300,
            from: 0,
            to: 1000,
            step: 10
        },
        {
            label: "slide ms",
            prop: "slideDuration",
            group: "Month slide",
            blurb: "The week rows sliding sideways on a month change.",
            tip: "Duration of one week row's horizontal slide to the next month. Each lower row adds the stagger on top, so the whole grid takes this plus five staggers.",
            val: 420,
            from: 100,
            to: 1200,
            step: 10
        },
        {
            label: "stagger ms",
            prop: "staggerMs",
            group: "Month slide",
            tip: "Delay between one week row and the next starting their slide, top down. 55 makes the wave visible without the last row lagging a beat behind.",
            val: 55,
            from: 0,
            to: 200,
            step: 1
        },
        {
            label: "edge fade",
            prop: "edgeFadeWidth",
            group: "Month slide",
            tip: "Width of the band at the grid's left and right edges that dissolves the sliding week rows into the ground, so a month leaving or arriving is never cut by a vertical line. It rides each row's own slide (0 at rest, full mid-run), so the edge is exact when nothing moves. 34 is the scroll fade the lists use.",
            val: 34,
            from: 0,
            to: 80,
            step: 1
        },
        {
            label: "blur onset",
            prop: "blurOnsetMonths",
            group: "Motion blur",
            blurb: "Blur on a multi-month run, by how far the rows still have to travel.",
            tip: "Months of travel left below which the grid stays sharp. 0.8 keeps a single-month step crisp and blurs only a queued run of several.",
            val: 0.8,
            from: 0,
            to: 3,
            step: 0.1
        },
        {
            label: "blur span",
            prop: "blurSpanMonths",
            group: "Motion blur",
            tip: "Months of travel over the onset at which the blur reaches full strength. 2 ramps it in over a two-month run instead of switching it on.",
            val: 2.0,
            from: 0.5,
            to: 6,
            step: 0.1
        }
    ]

    readonly property var headerParams: [
        {
            label: "label size",
            prop: "monthLabelPxSize",
            group: "Label",
            blurb: "The month and year under the grid.",
            tip: "Pixel size of the month name and the year. 16 is the shell's title size, which is what this line is.",
            val: 16,
            from: 10,
            to: 24,
            step: 1
        }
    ]

    readonly property var listParams: [
        {
            label: "row ms",
            prop: "animDuration",
            group: "Row motion",
            blurb: "Rows leaving right and arriving from the left on a day change.",
            tip: "Duration of one appointment row's slide out or in, and of a row's expand. 240 is the shell's short motion.",
            val: 240,
            from: 0,
            to: 800,
            step: 10
        },
        {
            label: "stagger ms",
            prop: "animStaggerMs",
            group: "Row motion",
            tip: "Delay between one row and the next, top down. 55, the same as the grid's week rows, so a day change and a month change share a rhythm.",
            val: 55,
            from: 0,
            to: 200,
            step: 1
        },
        {
            label: "seam depth",
            prop: "seamFadeHeight",
            group: "Calendars panel",
            blurb: "The panel the header's chevron opens over the list.",
            tip: "Depth of the dissolve on each side of the panel's moving edge while it opens or closes: the panel's rows fade into the ground above it and the appointments fade in below it, so no line sweeps across their text. Only there while the edge moves. 42 is the LLM folds' seam, the same component.",
            val: 42,
            from: 0,
            to: 80,
            step: 1
        },
        {
            label: "load debounce ms",
            prop: "initialDebounceMs",
            group: "Loading",
            blurb: "The first fill, while several feeds' caches arrive.",
            tip: "Quiet time after the last feed's cache arrived before the list fills the first time. Several calendars land within a few ms of each other; 80 turns them into one fill instead of one per feed.",
            val: 80,
            from: 0,
            to: 400,
            step: 5
        }
    ]

    readonly property var barHParams: [
        {
            label: "horizontal size",
            prop: "horizontalPixelSize",
            group: "Horizontal",
            blurb: "12:34 on one line.",
            tip: "Pixel size of the time in a horizontal bar. 18 fills a bar's height without touching its rim.",
            val: 18,
            from: 10,
            to: 28,
            step: 1
        },
        {
            label: "roll ms",
            prop: "rollMs",
            group: "Roll",
            blurb: "A figure that changes rolls: each minute, and each second while the seconds are shown.",
            tip: "How long one digit's roll takes: the old figure rises out and fades over the first half, the new one rises in over the second. 320 is long enough to read as a roll and short enough that the seconds' roll is done well before the next tick.",
            val: 320,
            from: 100,
            to: 900,
            step: 10
        },
        {
            label: "roll stagger ms",
            prop: "rollStaggerMs",
            group: "Roll",
            tip: "The step of the carry: when several digits change at once (12:59 -> 13:00) the units go first and each one to the left starts this much later, as an odometer carries. 50 keeps the whole carry inside one roll and a half.",
            val: 50,
            from: 0,
            to: 200,
            step: 5
        }
    ]

    readonly property var barVParams: [
        {
            label: "vertical size",
            prop: "verticalPixelSize",
            group: "Vertical",
            blurb: "The hour stacked over the minutes, upright.",
            tip: "Pixel size of the hour and the minutes in a vertical bar. 16, a notch under the horizontal size, because two lines have to fit a bar's width.",
            val: 16,
            from: 10,
            to: 28,
            step: 1
        },
        {
            label: "line spacing",
            prop: "verticalLineSpacing",
            group: "Vertical",
            tip: "Gap between the hour and the minutes. 2 keeps them one figure without the digits touching.",
            val: 2,
            from: 0,
            to: 10,
            step: 0.5
        }
    ]

    readonly property var timersParams: [
        {
            label: "dial radius",
            prop: "dialRadius",
            group: "Dial",
            blurb: "The ring, centred in the square card on every view.",
            tip: "Radius of the ring's centreline, px. 127 leaves the figures and the main action room inside, and the corners and the band under it room for the controls and the lists.",
            val: 127,
            from: 90,
            to: 170,
            step: 1
        },
        {
            label: "groove scale",
            prop: "dialSizeScale",
            group: "Dial",
            tip: "The ring's groove is the Workspaces groove (6 px line) at this scale. 2 makes it a touch heavier than the bar's 1.5, as a dial this size wants.",
            val: 2,
            from: 1,
            to: 3,
            step: 0.1
        },
        {
            label: "pomodoro gap",
            prop: "pomodoroGapDeg",
            group: "Dial",
            tip: "Gap between the pomodoro's four arcs, degrees. Session 1 is the top arc, then clockwise. 14 separates them clearly without shortening them much.",
            val: 14,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "head bulge",
            prop: "fillHeadBulge",
            group: "Fill",
            blurb: "The fills on the ring.",
            tip: "How far both ends of a fill bulge, as a fraction of the half-line: 1 is a semicircle, a capsule's end (the bar's fill, the LLM VRAM bar); 0 a straight cut.",
            val: 1,
            from: 0,
            to: 1.5,
            step: 0.05
        },
        {
            label: "merge px",
            prop: "fillMergePx",
            group: "Fill",
            tip: "Where a fill comes round to its own start, its two ends join as a liquid would over this distance: they reach for each other and a neck forms before the ring closes. 18 (three half-lines) starts the neck about 4 degrees before a full turn.",
            val: 18,
            from: 0,
            to: 48,
            step: 1
        },
        {
            label: "rim strength",
            prop: "ringBevelStrength",
            group: "Fill",
            tip: "How far the light rim outside the ring's carve reaches from the card's ground towards the bevel colour. 0.6: subtler than the bar's groove (1), a hint of an edge rather than a band.",
            val: 0.6,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "sticky edges",
            prop: "stickyDeg",
            group: "Winding",
            blurb: "Setting a time by turning the ring. The first turn: 0-1 min, 1-10, 10-30, 30-60 a quarter; then an hour a turn.",
            tip: "Degrees either side of each quarter's edge (1:00, 10:00, 30:00, each hour and quarter-hour after) where the time holds at the edge's value, so the round numbers are easy to land on. Nothing snaps outside them. 3 is felt, not seen.",
            val: 3,
            from: 0,
            to: 10,
            step: 0.5
        },
        {
            label: "shift ms / px",
            prop: "precisionMsPerPx",
            group: "Winding",
            tip: "With Shift held, the time moves this many ms per px the hand travels along the ring, whatever the quarter: 1000 is a second a pixel, for the exact second.",
            val: 1000,
            from: 100,
            to: 5000,
            step: 100
        },
        {
            label: "wheel step",
            prop: "wheelStepDeg",
            group: "Winding",
            tip: "Degrees a wheel notch over the ring turns the hand, so the wheel follows the dial's own scale (6 degrees: a few seconds in the first quarter, two minutes in the fourth). Shift is a second a notch.",
            val: 6,
            from: 1,
            to: 30,
            step: 1
        },
        {
            label: "Ctrl wheel step",
            prop: "wheelCtrlStepDeg",
            group: "Winding",
            tip: "Degrees a notch turns the hand with Ctrl held: 30, a third of a quarter.",
            val: 30,
            from: 5,
            to: 90,
            step: 1
        },
        {
            label: "alarm detent",
            prop: "alarmDetentMin",
            group: "Winding",
            tip: "Minutes per detent when dragging an alarm round the 24-hour dial. 5: a drag is for the rough time, the wheel (a minute a notch) for the exact one.",
            val: 5,
            from: 1,
            to: 15,
            step: 1
        },
        {
            label: "touchpad units",
            prop: "windPixelUnits",
            group: "Winding",
            tip: "Two-finger travel (wheel units) per wheel step when winding with the touchpad. 150 is a short, deliberate slide per step; a mouse notch is always exactly one.",
            val: 150,
            from: 50,
            to: 400,
            step: 10
        },
        {
            label: "field touchpad units",
            prop: "fieldPixelUnits",
            group: "Winding",
            tip: "Two-finger travel (wheel units) per minute on a pomodoro duration (focus, break, long). 1000, the shell's detent (the view switcher's): at 150 or 500 one slide runs away with the minutes. A mouse notch is always one minute, Ctrl five.",
            val: 1000,
            from: 100,
            to: 3000,
            step: 25
        },
        {
            label: "field cooldown ms",
            prop: "fieldCooldownMs",
            group: "Winding",
            tip: "After a duration steps a minute, the touchpad is not heard for this long (WheelStepper's cooldown): one long slide moves minute by minute instead of racing. 200 -- the view switcher's.",
            val: 200,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "switch ms",
            prop: "transitionMs",
            group: "Motion",
            blurb: "Between views: the ring morphs, the controls hand over at the midpoint.",
            tip: "Duration of a view switch. 320, a little longer than the weather cards' 260, because the ring has further to go (arcs open, fills slide round).",
            val: 320,
            from: 100,
            to: 800,
            step: 10
        },
        {
            label: "settle ms",
            prop: "settleMs",
            group: "Motion",
            tip: "After a drag, the ring's fill settles onto the time the figures already show. 120 is a click into place, not a glide.",
            val: 120,
            from: 0,
            to: 400,
            step: 10
        }
    ]

    readonly property var barFillParams: [
        {
            label: "head bulge",
            prop: "fillHeadBulge",
            group: "Fill",
            blurb: "The timers' fill in the Workspaces groove.",
            tip: "Depth of the fill's convex end, as a fraction of the half-line. 1 is a semicircle -- a capsule's end, the VRAM bar's -- which at a full piece is exactly the groove's own round cap.",
            val: 1,
            from: 0,
            to: 1.5,
            step: 0.05
        },
        {
            label: "shadow darken",
            prop: "fillShadowDarken",
            group: "Fill",
            tip: "The fill colours ONLY the groove's inset shadow (the rail's background stays as it is, as a notification toast shows its time left); the shadow is the tone darkened by this. 1.35, between the update rail's 1.4 core and a flat fill.",
            val: 1.35,
            from: 1,
            to: 2,
            step: 0.05
        },
        {
            label: "strength",
            prop: "fillStrength",
            group: "Fill",
            tip: "How loudly the fill's colour shows in the rail's inset: 1 is the tone's shade as it is, 0 the groove's own inset (no fill at all), between those the groove's shadow turned that share of the way toward it. 0.5: the full shade is too loud for a bar that is always on screen, half of it is read without pulling the eye.",
            val: 0.5,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "inset reach",
            prop: "fillShadowWiden",
            group: "Fill",
            tip: "How far into the groove the fill's colour reaches, as a multiple of the groove's own inset. 1 is the inset exactly as carved: colour at the edge only, nothing widened. Above 1 the colour is stretched toward the line's middle, smoothly, so the fill reads more at a glance; turn it up only if the inset alone proves too faint.",
            val: 1,
            from: 1,
            to: 3,
            step: 0.1
        },
        {
            label: "quantum px",
            prop: "fillQuantumPx",
            group: "Repaint",
            blurb: "The bar shares a window with every popup: each repaint redraws it all.",
            tip: "A moving fill repaints once its end has moved this far. 0.5 px keeps the motion smooth to the eye; a 25-minute session then repaints about every 5 seconds.",
            val: 0.5,
            from: 0.25,
            to: 4,
            step: 0.25
        },
        {
            label: "max Hz",
            prop: "fillMaxHz",
            group: "Repaint",
            tip: "Never more repaints than this per second, however fast a fill moves (a 1-minute timer would ask for 15). 10 is smooth enough for a bar and a tenth of a frame budget.",
            val: 10,
            from: 1,
            to: 60,
            step: 1
        }
    ]
}
