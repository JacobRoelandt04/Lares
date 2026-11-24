pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/common/mockup"
import "modules/common/scroll"
import "modules/common/theme"
import "modules/screentime"
import "modules/screentime/data"

// =============================================================================
// mockups/screentime.qml -- the screentime card (the clock popup's third tab) on
// the mockup framework, over the synthetic ScreentimeMock.
//
// The stage holds ScreentimeCard alone at its own implicit size (454 px tall,
// the clock's content height) and a stage-level swipe router that does what the
// clock's does for this tab: it asks `card.ownerAt()` where a two-finger
// gesture began, sends sideways motion over the faces card to `stepWeekBy` and
// vertical motion to `cycleFacesBy`, and ends on the zero-delta wheel (or an
// idle timer for devices that never send one). Keys: Left/Right weeks, Up/Down
// faces, Esc clears the day, then the app.
//
// Env (this file's own; the framework's GRAB / GRAB_MS still apply), for
// renders and probes -- applied once, 700 ms after load:
//   ST_FACE=0|1|2     the face      ST_BACK=<n>     step n weeks back
//   ST_DAY=<0..6>     select a day  ST_FOCUS=<cls>  focus an app
//   ST_ABSENT=1       no daemon     ST_PIN=<t>      pin the last morph at t
//
//   quickshell -p mockups/screentime.qml
// =============================================================================
MockupWindow {
    id: win

    moduleId: "screentime"
    title: "Screentime mockup"
    stageLabel: "ScreentimeCard (drop-in for the clock's third tab)"
    content: stageItem
    stageColor: Theme.surface
    target: card
    targets: ({
            chartParams: card.barsFace,
            heatParams: card.heatFace,
            spanParams: card.spanFace,
            statsParams: card.statsStrip,
            ribbonParams: card.ribbonStrip,
            listParams: card.appList
        })

    lists: ({
            layoutParams: win.layoutParams,
            chartParams: win.chartParams,
            heatParams: win.heatParams,
            spanParams: win.spanParams,
            statsParams: win.statsParams,
            ribbonParams: win.ribbonParams,
            listParams: win.listParams
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
            name: "Chart",
            lists: ["chartParams"]
        },
        {
            name: "Hours",
            lists: ["heatParams"]
        },
        {
            name: "Span",
            lists: ["spanParams"]
        },
        {
            name: "Stats",
            lists: ["statsParams"]
        },
        {
            name: "Ribbon",
            lists: ["ribbonParams"]
        },
        {
            name: "List",
            lists: ["listParams"]
        }
    ]

    // =====================================================================
    //  THE DROP-IN CONTENT
    // =====================================================================
    Item {
        id: stageItem

        implicitWidth: card.implicitWidth
        implicitHeight: card.implicitHeight

        ScreentimeMock {
            id: mock
        }
        Binding {
            target: mock
            property: "live"
            // The stage always shows the card: a session that lasts as long as the
            // source is chosen (one snapshot; Refetch takes another).
            value: win.dataSource === "mock"
        }
        // The installed daemon, READ ONLY (the service only queries: state,
        // week, day, range -- it never feeds). Created only while the
        // Run tab's source is Live, so a mock run dials nothing.
        LazyLoader {
            id: realLoader
            active: win.dataSource === "live"
            ScreentimeService {
                socketPath: win._envSocket !== "" ? win._envSocket : Quickshell.env("XDG_RUNTIME_DIR") + "/screentime/screentimed.sock"
                live: true
            }
        }

        ScreentimeCard {
            id: card
            anchors.fill: parent
            service: win.dataSource === "live" ? realLoader.item : mock
            focus: true
            Keys.onPressed: e => card.handleKey(e)
        }

        // ---- The clock's swipe router, for this tab -------------------------
        property bool _active: false
        property string _owner: ""
        property string _axis: ""

        function _end() {
            idleEnd.stop();
            if (stageItem._owner === "week")
                card.endGesture();
            stageItem._active = false;
            stageItem._owner = "";
            stageItem._axis = "";
        }
        function _wheel(ev) {
            const px = ev.x, py = ev.y, ad = ev.angleDelta, pd = ev.pixelDelta;
            // a mouse: a notch over the faces card is a face, a sideways one a week
            if (ev.device === "wheel") {
                if (card.ownerAt(px, py) === "week") {
                    if (ad.x !== 0)
                        card.stepWeekBy(120 * ev.steps, false);
                    else
                        card.cycleFacesBy(120 * ev.steps, false);
                }
                return;
            }
            const xPixels = pd.x !== 0, yPixels = pd.y !== 0;
            const dx = ad.x !== 0 ? ad.x : pd.x * 3, dy = ad.y !== 0 ? ad.y : pd.y * 3;
            if (dx === 0 && dy === 0) {
                stageItem._end();
                return;
            }
            idleEnd.restart();
            if (!stageItem._active) {
                stageItem._owner = card.ownerAt(px, py);
                stageItem._active = true;
                stageItem._axis = "";
            }
            if (stageItem._axis === "") {
                if (Math.abs(dx) > Math.abs(dy) * 1.2)
                    stageItem._axis = "x";
                else if (Math.abs(dy) > Math.abs(dx) * 1.2)
                    stageItem._axis = "y";
            }
            if (stageItem._owner !== "week")
                return;
            if (stageItem._axis === "x" && dx !== 0)
                card.stepWeekBy(dx, xPixels);
            else if (stageItem._axis === "y" && dy !== 0)
                card.cycleFacesBy(dy, yPixels);
        }
        Timer {
            id: idleEnd
            interval: 260
            onTriggered: stageItem._end()
        }
        WheelArea {
            anchors.fill: parent
            z: 200
            turned: wheel => {
                stageItem._wheel(wheel);
                wheel.accepted = false;
            }
        }
        // A card that holds the keys: a click on bare surface takes them.
        TapHandler {
            onTapped: card.forceActiveFocus()
        }
    }

    // ---- the data source -----------------------------------------------------
    // "mock" (the seeded synthetic weeks and the Live session levers) or "live"
    // (the installed screentimed, read only). ST_SOURCE=live picks it at start,
    // ST_SOCKET points it at another socket.
    property string dataSource: (Quickshell.env("ST_SOURCE") || "mock") === "live" ? "live" : "mock"
    readonly property string _envSocket: Quickshell.env("ST_SOCKET") || ""
    readonly property var _service: card.service

    // ---- env-driven stills ----------------------------------------------------
    readonly property string _envFace: Quickshell.env("ST_FACE") || ""
    readonly property int _envBack: Number(Quickshell.env("ST_BACK") || 0)
    readonly property string _envDay: Quickshell.env("ST_DAY") || ""
    readonly property string _envFocus: Quickshell.env("ST_FOCUS") || ""
    readonly property bool _envAbsent: (Quickshell.env("ST_ABSENT") || "") === "1"
    readonly property string _envPin: Quickshell.env("ST_PIN") || ""
    Timer {
        interval: 700
        running: win._envFace !== "" || win._envBack > 0 || win._envDay !== "" || win._envFocus !== "" || win._envAbsent || win._envPin !== ""
        onTriggered: {
            if (win._envFace !== "")
                card.face = Number(win._envFace);
            if (win._envAbsent)
                mock.simAbsent(true);
            if (win._envFocus !== "")
                card.focusApp(win._envFocus);
            if (win._envBack > 0)
                card.stepWeek(-win._envBack);
            if (win._envDay !== "")
                dayTimer.start();
            if (win._envPin !== "")
                pinTimer.start();
        }
    }
    // A day is picked in the week the card shows once the step has landed.
    Timer {
        id: dayTimer
        interval: 500
        onTriggered: card.selectDay(Number(win._envDay))
    }
    Timer {
        id: pinTimer
        interval: 120
        onTriggered: card.pinMorph(Number(win._envPin))
    }

    // =====================================================================
    //  THE RUN PAGE
    // =====================================================================
    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Data"
                blurb: "Mock: seeded synthetic weeks you can drive below. Live: your own recorded history from the installed screentimed, read only."
            }
            TipRow {
                tip: "Where the card's data comes from. Live asks the installed daemon over its socket ($XDG_RUNTIME_DIR/screentime/screentimed.sock) and only ever reads: it sends queries, never an idle, lock or sleep feed, so your record is untouched. Switching starts the card again at the source's current week. Refetch (debug): the card takes ONE snapshot per session and nothing on it updates while it is shown; Refetch takes another now -- the state and every week and day already shown, each replaced where it stands."
                Button {
                    text: "Mock"
                    highlighted: win.dataSource === "mock"
                    onClicked: win.dataSource = "mock"
                }
                Button {
                    text: "Live"
                    highlighted: win.dataSource === "live"
                    onClicked: win.dataSource = "live"
                }
                Button {
                    text: "Refetch"
                    enabled: !!win._service
                    onClicked: win._service.refresh()
                }
                Label {
                    Layout.fillWidth: true
                    text: win._service ? win._service.status : "starting"
                    color: win._service && win._service.status === "ok" ? Theme.ok : Theme.textMuted
                    elide: Text.ElideRight
                }
            }

            TipGroup {
                title: "Week"
                blurb: "The shown week is one motion: the bars, the hours grid and the span bars all move on the chart's clock."
            }
            TipRow {
                tip: "Step the week back or forward. The next week stops at the current one: a step into the future does nothing. A week that is not loaded yet is asked for and shown when it arrives."
                Button {
                    text: "‹ Week"
                    onClicked: card.stepWeek(-1)
                }
                Button {
                    text: "Week ›"
                    onClicked: card.stepWeek(1)
                }
                Button {
                    text: "Back 3"
                    onClicked: card.stepWeek(-3)
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Pick a day (0 = the week's first). Its histogram opens under the stats and the list and the stats take that day; picking the same day again, or Clear, closes it."
                Label {
                    text: "Day"
                    color: Theme.textMuted
                }
                Repeater {
                    model: 7
                    Button {
                        required property int index
                        text: String(index)
                        implicitWidth: 34
                        onClicked: card.selectDay(index)
                    }
                }
                Button {
                    text: "Clear"
                    onClicked: {
                        if (card.selectedDay >= 0)
                            card.selectDay(card.selectedDay);
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Focus an app of the visible list: the bars show its days in its hue over the faint total, the hours and the span show its own. The same as clicking its row; choosing it again unfocuses."
                Label {
                    text: "Focus"
                    color: Theme.textMuted
                }
                ComboBox {
                    id: focusBox
                    Layout.fillWidth: true
                    model: card.appList.rows.map(r => r.app)
                    onActivated: card.focusApp(currentText)
                }
                Button {
                    text: "None"
                    onClicked: {
                        if (card.focused !== "")
                            card.focusApp(card.focused);
                    }
                }
            }
            TipRow {
                tip: "Hold the last week step or app focus at one point of its clock (0 = where it started, 1 = landed). Every face reads the same fraction, so the three always agree."
                Label {
                    text: "Pin morph"
                    color: Theme.textMuted
                }
                Slider {
                    id: pinSlider
                    Layout.fillWidth: true
                    from: 0
                    to: 1
                    value: 1
                    onMoved: card.pinMorph(value)
                }
            }

            TipGroup {
                title: "Live session"
                blurb: "The mock's own levers: what the daemon would be told. The card shows one snapshot a session, so a lever's effect appears on the next Refetch. Off while the source is Live."
            }
            TipRow {
                enabled: win.dataSource === "mock"
                tip: "Switch the focused app, as a window focus change would."
                Button {
                    text: "kitty"
                    onClicked: mock.simSwitch("kitty", "eDP-1")
                }
                Button {
                    text: "zen"
                    onClicked: mock.simSwitch("zen", "eDP-1")
                }
                Button {
                    text: "steam"
                    onClicked: mock.simSwitch("steam", "eDP-1")
                }
                Button {
                    text: "Desktop"
                    onClicked: mock.simSwitch("~desktop", "eDP-1")
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                enabled: win.dataSource === "mock"
                tip: "Idle: no input for 120 s (the tail of the day is cut back, as the daemon backdates), then input again."
                Button {
                    text: "Idle 120"
                    onClicked: mock.simIdle(120)
                }
                Button {
                    text: "Active"
                    onClicked: mock.simActive()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                enabled: win.dataSource === "mock"
                tip: "Lock and unlock, sleep and wake: each ends the session and the figure stops counting while away."
                Button {
                    text: "Lock"
                    onClicked: mock.simLock()
                }
                Button {
                    text: "Unlock"
                    onClicked: mock.simUnlock()
                }
                Button {
                    text: "Sleep"
                    onClicked: mock.simSleep()
                }
                Button {
                    text: "Wake"
                    onClicked: mock.simWake()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                enabled: win.dataSource === "mock"
                tip: "No daemon: status absent, the card says so and shows no figures. Off brings it back."
                Switch {
                    id: absentSwitch
                    text: "Daemon absent"
                    onToggled: mock.simAbsent(checked)
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                enabled: win.dataSource === "mock"
                tip: "Move the mock's clock an hour forward (it can cross the day start and roll the day) or back to real time."
                Button {
                    text: "+1 h"
                    onClicked: mock.setClockOffset(mock.clockOffsetMs + 3600000)
                }
                Button {
                    text: "Real time"
                    onClicked: mock.setClockOffset(0)
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            Label {
                Layout.fillWidth: true
                text: win.dataSource + "   week " + card.weekKey + "   day " + card.selectedDay + "   focus " + (card.focused || "-") + "   status " + (win._service ? win._service.status : "-")
                color: Theme.textFaint
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }
        }
    ]

    // =====================================================================
    //  VALUES
    // =====================================================================
    readonly property var layoutParams: [
        {
            label: "card width",
            prop: "cardWidth",
            group: "Card",
            blurb: "The card's own size: its width is fixed, its height is the host's.",
            tip: "The card's width. 420 holds the header, three stats slots and an app row with a DUR slot without eliding a name; the clock's other tabs are 454 and 420 wide.",
            val: 420,
            from: 360,
            to: 520,
            step: 2
        },
        {
            label: "host height",
            prop: "hostHeight",
            group: "Card",
            tip: "The height the host gives the card. 454 is the clock popup's content height, which is what the list's room is judged against.",
            val: 454,
            from: 380,
            to: 560,
            step: 2
        },
        {
            label: "padding",
            prop: "padding",
            group: "Card",
            tip: "Space between the card's edge and its contents. 12 everywhere in the shell.",
            val: 12,
            from: 4,
            to: 24,
            step: 1
        },
        {
            label: "gap",
            prop: "gap",
            group: "Card",
            tip: "Space between the header, the faces, the stats, the day's histogram and the list. 8 keeps the stack inside 454 with about five list rows.",
            val: 8,
            from: 2,
            to: 20,
            step: 1
        },
        {
            label: "corner radius",
            prop: "radius",
            group: "Card",
            tip: "Radius of the faces card, which the face switcher's title box takes too. 14 is the shell's container radius.",
            val: 14,
            from: 6,
            to: 24,
            step: 1
        },
        {
            label: "faces height",
            prop: "facesHeight",
            group: "Rows",
            blurb: "The header, the stats strip and the day's histogram take their content's height; the faces card is set here.",
            tip: "The carved card the three faces share. 170 gives the bars a plot about 110 px tall and the hours grid seven 14 px rows.",
            val: 170,
            from: 110,
            to: 260,
            step: 2
        },
        {
            label: "narrowest column",
            prop: "minColumnPx",
            group: "Ribbon slot",
            blurb: "A selected day opens a histogram of it; the list below hangs from its foot.",
            tip: "The day's slot is the shortest of 5/10/15/20/30/60 min whose columns are at least this wide. 5 px keeps a 1 px gap readable between columns; wider means coarser slots.",
            val: 5,
            from: 3,
            to: 16,
            step: 1
        },
        {
            label: "coloured apps",
            prop: "dayLayers",
            group: "Ribbon slot",
            tip: "How many of the day's apps keep their own hue in the histogram; the rest share one faint layer. 5 matches the rows the list shows at a glance. At most 5 (the pool has 6 layers).",
            val: 5,
            from: 1,
            to: 5,
            step: 1
        },
        {
            label: "ribbon ms",
            prop: "ribbonMs",
            group: "Ribbon slot",
            tip: "How long the ribbon's slot takes to open and close. 260 ms OutCubic is the shell's resize.",
            val: 260,
            from: 0,
            to: 800,
            step: 10
        }
    ]

    readonly property var chartParams: [
        {
            label: "ghost alpha",
            prop: "ghostAlpha",
            group: "Bars",
            blurb: "The Days face's two bar series: the faint total behind, the focus in front.",
            tip: "How strong the faint total bars are behind a focused app's bars, so the app's share reads against the day. With no app focused the ghost is off: the totals are the focus.",
            val: 0.22,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "bar alpha",
            prop: "barAlpha",
            group: "Bars",
            tip: "The focus bars' opacity. 0.85 keeps the grid readable through the bar and stays clear of the surface.",
            val: 0.85,
            from: 0.2,
            to: 1,
            step: 0.01
        },
        {
            label: "y max floor (h)",
            prop: "yMaxFloor",
            group: "Bars",
            tip: "The axis never tops below this many hours, so a light week is drawn against three hours (whole-hour ticks), not stretched to its biggest bar.",
            val: 3,
            from: 1,
            to: 8,
            step: 1
        },
        {
            label: "plot padding",
            prop: "chartPadding",
            group: "Bars",
            tip: "The chart's own padding inside its box; the card offsets the chart by it so the ink sits one card padding from the edge.",
            val: 6,
            from: 2,
            to: 16,
            step: 1
        },
        {
            label: "morph ms",
            prop: "morphMs",
            group: "Motion",
            blurb: "The one clock of a week step and an app focus.",
            tip: "The morph's duration, for the bars, the hours grid and the span bars together: they all read the chart's progress. 260 ms OutCubic is the shell's resize.",
            val: 260,
            from: 0,
            to: 1200,
            step: 10
        }
    ]

    readonly property var heatParams: [
        {
            label: "cell gap",
            prop: "cellGap",
            group: "Cells",
            blurb: "The Hours face: 7 days by 24 hours.",
            tip: "Space between cells. 2 px keeps 24 columns inside a 372 px face at 12 px a cell.",
            val: 2,
            from: 0,
            to: 6,
            step: 1
        },
        {
            label: "cell radius",
            prop: "cellRadius",
            group: "Cells",
            tip: "Corner radius of a cell. 3 reads as a tile; half the cell height is a pill.",
            val: 3,
            from: 0,
            to: 8,
            step: 1
        },
        {
            label: "floor fraction",
            prop: "floorFraction",
            group: "Cells",
            tip: "The share of the hue a cell with any time at all is drawn at, so a few minutes still read against an empty cell.",
            val: 0.12,
            from: 0,
            to: 0.5,
            step: 0.01
        },
        {
            label: "label size",
            prop: "labelSize",
            group: "Labels",
            blurb: "The day and hour labels.",
            tip: "The day and hour labels' pixel size.",
            val: 10,
            from: 8,
            to: 14,
            step: 1
        }
    ]

    readonly property var spanParams: [
        {
            label: "bar width",
            prop: "barWidth",
            group: "Bars",
            blurb: "The Span face: first to last activity of each day.",
            tip: "Width of a day's bar. About two thirds of a column (53 px) reads as a bar, not a line.",
            val: 14,
            from: 4,
            to: 40,
            step: 1
        },
        {
            label: "bar alpha",
            prop: "barAlpha",
            group: "Bars",
            tip: "The bars' opacity.",
            val: 0.85,
            from: 0.2,
            to: 1,
            step: 0.01
        },
        {
            label: "label size",
            prop: "labelSize",
            group: "Labels",
            blurb: "The hour and day labels.",
            tip: "The hour and day labels' pixel size.",
            val: 10,
            from: 8,
            to: 14,
            step: 1
        }
    ]

    readonly property var statsParams: [
        {
            label: "side column",
            prop: "sideSlot",
            group: "Columns",
            blurb: "Switches / h flush left, the longest stretch centred, pickups flush right: the edges are the boxes' above and below.",
            tip: "The room each side column keeps; the centre column (the longest stretch's DUR and app) takes the rest and elides the app's name past it.",
            val: 96,
            from: 60,
            to: 140,
            step: 2
        },
        {
            label: "caption size",
            prop: "captionSize",
            group: "Type",
            blurb: "The sizes of the captions and figures.",
            tip: "The captions' pixel size.",
            val: 10,
            from: 8,
            to: 13,
            step: 1
        },
        {
            label: "figure size",
            prop: "figureSize",
            group: "Type",
            tip: "The figures' pixel size (bold; the longest stretch's app name is the same size, regular).",
            val: 12,
            from: 10,
            to: 16,
            step: 1
        }
    ]

    readonly property var ribbonParams: [
        {
            label: "strip height",
            prop: "stripHeight",
            group: "Strip",
            blurb: "A selected day as a histogram: equal slots, each column the share of it spent active, stacked by app.",
            tip: "Height of the carved groove the columns stand in. A full column is the groove minus its inset on both sides.",
            val: 30,
            from: 16,
            to: 48,
            step: 1
        },
        {
            label: "inset",
            prop: "inset",
            group: "Strip",
            tip: "Space between the groove's edge and the columns, so the carve's bevel stays visible around them.",
            val: 3,
            from: 0,
            to: 6,
            step: 1
        },
        {
            label: "column gap",
            prop: "columnGap",
            group: "Strip",
            tip: "Space between two columns (dropped when the columns are under 4 px wide). 1 px keeps neighbouring slots apart without thinning them.",
            val: 1,
            from: 0,
            to: 3,
            step: 1
        },
        {
            label: "label spacing",
            prop: "tickMinPx",
            group: "Labels",
            blurb: "The hour labels along the ribbon.",
            tip: "Hour labels stand every 1, 2, 3, 4, 6 or 12 hours: the fewest hours whose labels are at least this far apart (px between centres). 56 fits an HH:mm label with room either side.",
            val: 56,
            from: 36,
            to: 120,
            step: 2
        },
        {
            label: "label size",
            prop: "labelSize",
            group: "Labels",
            tip: "The hour labels' pixel size.",
            val: 10,
            from: 8,
            to: 14,
            step: 1
        }
    ]

    readonly property var listParams: [
        {
            label: "row height",
            prop: "rowHeight",
            group: "Rows",
            blurb: "The app list: one row per app, most used first.",
            tip: "Height of a row: the name over a thin share bar. 32 shows five rows in 454 px with no ribbon.",
            val: 32,
            from: 26,
            to: 48,
            step: 1
        },
        {
            label: "inset",
            prop: "inset",
            group: "Rows",
            tip: "Space between the list box's edge and its rows. 6 is the shell's list-row inset.",
            val: 6,
            from: 2,
            to: 14,
            step: 1
        },
        {
            label: "swap fade ms",
            prop: "fadeMs",
            group: "Motion",
            blurb: "What happens when the list's scope changes.",
            tip: "When another week or day is shown the new rows are in at once and the list's presence fades in over this long. Text swaps are instant; only presence fades.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        }
    ]
}
