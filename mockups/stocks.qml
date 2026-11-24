pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/common/mockup"
import "modules/common/theme"
import "modules/common/components"
import "modules/common/components/Mix.js" as Mix
import "modules/bar/gooey"
import "modules/stocks"
import "modules/stocks/data"

// =============================================================================
// mockups/stocks.qml -- the stocks popup mockup, on the REAL bar stocksEngine.
//
// A slice of the screen at 1:1: a GooeyEngine with a top bar carrying the
// stocks button (BAR=right: a right bar, the button stacked), thePopup the
// stocks content opens in, and the engine's secondary the detail opens in --
// the drop-in as it will run, with the secondary contract for real.
//
// THE DATA IS StocksMock: the captured fixtures under modules/stocks/data/fixtures/
// and modules/stocks/data/fixtures/portfolio.jsonc, the clock pinned to the capture, run through the
// same Portfolio.js the real service runs. "Live" on the Run page swaps in the
// real StocksService (Yahoo, CNBC, Eurostat) after a confirmation; it reads
// ~/.config/quickshell/config/stocks.jsonc (the example when there is none) and
// writes only a mockup-private state file.
//
// Env: SCENARIO=<mock scenario>  OPEN=0 (start closed)  DETAIL=SYM[:RANGE]
//      TAB=holdings|watchlist  SORT=value|day|total|name[:asc|desc]  SEARCH=<text>
//      REAL=1 (hold the real flip)  REALAT=<ms> (flip to real that long after
//      the start: a grab just after it catches the flash near its peak)
//      NOW=HH:MM (the session clock, CEST)  SUMRANGE=1D|5D|...|ALL (the summary)
//      SUMRANGEAT=<ms> (SUMRANGE picked that long after the start instead: a
//      grab just after it catches a first 5D still loading)
//      CLOSED=1 (the Closed section open and in view)  SORTMENU=1 (the sort menu open)
//      SCRUB=summary|detail[:f] (that chart held scrubbed at fraction f of its slots)
//      DSIDE=far|start|end  DANCHOR=row|start|centre|end  DSCALE=<x popup width>
//      DINSET=<px> (the Layout tab's detail placement, for a render)
//      BAR=top|right  LIVE=1 (arms Live; it still asks)  + the framework's GRAB
//      STAGE_GRAB=<png> (the stage alone, GRAB_MS after the start, then quit)  ZOOM
//
// Run it: tools/dev/sandbox.sh quickshell -p mockups/stocks.qml
// =============================================================================
MockupWindow {
    id: win

    moduleId: "stocks"
    title: "Stocks"
    stageLabel: "A section of the screen at 1:1 -- a " + win.barEdge + " bar, the stocks button, thePopup and its secondary"
    content: scene
    target: tun
    stageColor: "#1F2229"
    zoom: Number(Quickshell.env("ZOOM") || (win.barEdge === "right" ? 0.8 : 0.62))
    panelWidth: 460

    readonly property string barEdge: (Quickshell.env("BAR") || "top") === "right" ? "right" : "top"

    lists: ({
            layoutParams: win.layoutParams,
            chartParams: win.chartParams,
            stripParams: win.stripParams,
            logoParams: win.logoParams,
            barParams: win.barParams,
            stockColors: win.stockColors
        })
    themedLists: ["stockColors"]

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Layout",
            lists: ["layoutParams"],
            page: layoutPage
        },
        {
            name: "Chart",
            lists: ["chartParams"]
        },
        {
            name: "Strip",
            lists: ["stripParams"]
        },
        {
            name: "Logos",
            lists: ["logoParams"],
            page: logosPage
        },
        {
            name: "Colours",
            lists: ["stockColors"]
        },
        {
            name: "Bar",
            lists: ["barParams"]
        }
    ]

    // ---- Tunables (the panel's target; the owner and the button bind to them) -------------
    QtObject {
        id: tun
        property bool dressAudiowide: false
        property real popupWidth: 504
        property real listRows: 6
        property real rowHeight: 44
        property real detailSide: 2
        property real detailAnchor: 0
        property real detailWidthScale: 1
        property bool detailOverhang: false
        property real detailInset: 0
        property real detailMaxHeight: 960
        property real flashPeak: 0.22
        property real flashPad: 3
        property real summaryChartHeight: 96
        property real detailChartHeight: 180
        property real stripCycleMs: 4000
        property real stripRollMs: 420
        property real stripStaggerMs: 90
        property real stripHoverDwellMs: 400
        property real stripReleaseGraceMs: 250
        property real logoSize: 30
        property real detailLogoSize: 56
        property real iconAlong: 560
        property real sparkWidth: 22
        property real sparkHeight: 12
        property real barPixelSize: 11
        property real flourishStyle: 0
        property real flourishMs: 900
        property real flourishAmp: 2
        property real flourishHalf: 5
        property real arrowTravel: 5
        property real arrowSize: 4
        property real arrowAlpha: 0.6
    }

    // ---- the data: the mock, or (confirmed) the real service -------------------------------
    // The panel's placement numbers as the owner's words.
    readonly property var sideNames: ["far", "start", "end"]
    readonly property var anchorNames: ["row", "start", "centre", "end"]
    readonly property string detailSideName: win.sideNames[Math.max(0, Math.min(2, Math.round(tun.detailSide)))]
    readonly property string detailAnchorName: win.anchorNames[Math.max(0, Math.min(3, Math.round(tun.detailAnchor)))]
    // A detail beside the popup (a top bar's start / end) needs room on the
    // stage: the stage widens by it, and a start detail moves the button over.
    readonly property real _sideRoom: win.barEdge === "top" && win.detailSideName !== "far"
                                      ? Math.round(tun.popupWidth * tun.detailWidthScale) + 40 : 0

    property bool armedLive: (Quickshell.env("LIVE") || "") === "1"
    property bool live: false
    readonly property var svc: win.live && liveLoader.item ? liveLoader.item : mock

    DesktopNotifier {
        id: mockNotifier
        appName: "Stocks (mockup)"
        keys: win.svc && win.svc.alertKeys ? win.svc.alertKeys : []
    }
    StocksMock {
        id: mock
        dryRun: true
        notifier: mockNotifier
        scenario: Quickshell.env("SCENARIO") || "market-open"
        // MOCK_ANSWER_MS: how long a chart / the first 5D takes (the loading
        // skeleton can then be seen at rest).
        answerMs: Number(Quickshell.env("MOCK_ANSWER_MS") || 180)
    }
    // Loaded by URL so the mockup does not need the real service to exist
    // until Live is confirmed.
    Loader {
        id: liveLoader
        active: win.live
        source: win.live ? Qt.resolvedUrl("modules/stocks/data/StocksService.qml") : ""
        onLoaded: {
            const s = liveLoader.item;      // a StocksService, loaded by URL: the linter only knows a QObject
            // qmllint disable missing-property
            s.statePath = (Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state")) + "/lares/stocks-mockup/state.json";
            s.notifier = mockNotifier;
            // qmllint enable missing-property
        }
    }

    // =====================================================================
    //  THE STAGE
    // =====================================================================
    Item {
        id: scene
        implicitWidth: 1180 + win._sideRoom
        implicitHeight: win.barEdge === "right" ? 860 : 1380

        Rectangle {
            anchors.fill: parent
            color: win.stageColor
        }

        GooeyEngine {
            id: stocksEngine
            anchors.fill: parent
            renderScale: win.stage.zoom
            surfaceColor: Theme.surface
            barsList: [stocksBar]

            GooeyBar {
                id: stocksBar
                engine: stocksEngine
                barId: "bar"
                edge: win.barEdge
                rawPos: 0
                rawLen: win.barEdge === "right" ? stocksEngine.h : stocksEngine.w

                StocksBarButton {
                    id: stocksButton
                    objectName: "stocksBarButton"
                    x: Math.round((win.barEdge === "right" ? 300 : tun.iconAlong + (win.detailSideName === "start" ? win._sideRoom : 0)) - width / 2)
                    y: Math.round((stocksBar.height - height) / 2)
                    owner: ownerLoader.item
                    fontFamily: tun.dressAudiowide ? "Audiowide" : "Inter"
                    sparkWidth: tun.sparkWidth
                    sparkHeight: tun.sparkHeight
                    pixelSize: tun.barPixelSize
                    flourishStyle: ["both", "ripple", "arrow"][Math.round(tun.flourishStyle)]
                    flourishMs: tun.flourishMs
                    flourishAmp: tun.flourishAmp
                    flourishHalf: tun.flourishHalf
                    arrowTravel: tun.arrowTravel
                    arrowSize: tun.arrowSize
                    arrowAlpha: tun.arrowAlpha
                }
            }
        }

        Loader {
            id: ownerLoader
            sourceComponent: StocksBarOwner {
                engine: stocksEngine
                bar: stocksBar
                barId: "bar"
                anchorItem: stocksButton
                service: win.svc
                fontFamily: tun.dressAudiowide ? "Audiowide" : "Inter"
                popupWidth: tun.popupWidth
                listRows: tun.listRows
                rowHeight: tun.rowHeight
                logoSize: tun.logoSize
                summaryChartHeight: tun.summaryChartHeight
                detailSide: win.detailSideName
                detailAnchor: win.detailAnchorName
                detailWidthScale: tun.detailWidthScale
                detailOverhang: tun.detailOverhang
                detailInset: tun.detailInset
                detailMaxHeight: tun.detailMaxHeight
                detailChartHeight: tun.detailChartHeight
                detailLogoSize: tun.detailLogoSize
                stripCycleMs: tun.stripCycleMs
                stripRollMs: tun.stripRollMs
                stripStaggerMs: tun.stripStaggerMs
                stripHoverDwellMs: tun.stripHoverDwellMs
                stripReleaseGraceMs: tun.stripReleaseGraceMs
                flashPeak: tun.flashPeak
                flashPad: tun.flashPad
            }
            onLoaded: startTimer.start()
        }
    }

    // ---- STAGE_GRAB=<png>: the stage alone, GRAB_MS after the start, then quit ------------
    readonly property string stageGrab: Quickshell.env("STAGE_GRAB") || ""
    Timer {
        running: win.stageGrab !== ""
        interval: Number(Quickshell.env("GRAB_MS") || 2500)
        onTriggered: scene.grabToImage(r => {
            r.saveToFile(win.stageGrab);
            Qt.quit();
        })
    }

    // ---- the env, applied once the owner exists -------------------------------------------
    Timer {
        id: startTimer
        interval: 0
        onTriggered: win.applyEnv()
    }
    Timer {
        id: closedTimer
        interval: 450
        onTriggered: {
            if (win._popup)
                win._popup.showClosed();
        }
    }
    Timer {
        id: detailTimer
        interval: 450
        onTriggered: win.applyDetail()
    }
    Timer {
        id: sumRangeTimer
        interval: Number(Quickshell.env("SUMRANGEAT") || 0)
        onTriggered: win.svc.summaryRange = Quickshell.env("SUMRANGE") || "1M"
    }
    Timer {
        id: realAtTimer
        interval: Number(Quickshell.env("REALAT") || 0)
        onTriggered: win.svc.realHover("mockup", true)
    }
    // SORTMENU / SCRUB: once the popup (and a detail) are in place.
    Timer {
        id: poseTimer
        interval: Quickshell.env("DETAIL") ? 1500 : 700
        onTriggered: win.applyPose()
    }
    function _find(item, name) {
        if (!item)
            return null;
        if (item.objectName === name)
            return item;
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++) {
            const r = win._find(kids[i], name);
            if (r)
                return r;
        }
        return null;
    }
    function applyPose() {
        if ((Quickshell.env("SORTMENU") || "") === "1") {
            const ctl = win._find(win._popup, "stocksSortHeader");
            if (ctl)
                ctl.openMenu();
        }
        const scrub = (Quickshell.env("SCRUB") || "").split(":");
        if (scrub[0]) {
            const chart = scrub[0] === "detail" ? win._find(win._detail, "stockDetailChart") : win._find(win._popup, "summaryChart");
            const f = scrub[1] ? Number(scrub[1]) : 0.6;
            let n = 0;
            for (const x of chart ? chart.series : [])
                n = Math.max(n, x.values ? x.values.length : 0);
            if (chart && n > 0)
                chart.hoverIndex = Math.max(0, Math.min(n - 1, Math.round(f * (n - 1))));
        }
    }
    function applyEnv() {
        const s = win.svc;
        const tab = Quickshell.env("TAB") || "";
        if (tab === "holdings" || tab === "watchlist")
            s.tab = tab;
        const sort = (Quickshell.env("SORT") || "").split(":");
        if (["value", "day", "total", "name"].indexOf(sort[0]) >= 0)
            s.setSort(sort[0], sort[1] ? sort[1] === "asc" : null);
        const sumRange = Quickshell.env("SUMRANGE") || "";
        if (sumRange && Number(Quickshell.env("SUMRANGEAT") || 0) > 0)
            sumRangeTimer.start();
        else if (sumRange)
            s.summaryRange = sumRange;
        const dside = win.sideNames.indexOf(Quickshell.env("DSIDE") || "");
        if (dside >= 0)
            tun.detailSide = dside;
        const danchor = win.anchorNames.indexOf(Quickshell.env("DANCHOR") || "");
        if (danchor >= 0)
            tun.detailAnchor = danchor;
        if (Quickshell.env("DSCALE"))
            tun.detailWidthScale = Number(Quickshell.env("DSCALE"));
        if (Quickshell.env("DINSET"))
            tun.detailInset = Number(Quickshell.env("DINSET"));
        const now = Quickshell.env("NOW") || "";
        const m = /^(\d{1,2}):(\d{2})$/.exec(now);
        if (m)
            s.sessionClock = Math.max(0, Math.min(1, (Number(m[1]) * 60 + Number(m[2]) - 9 * 60) / (8.5 * 60)));
        const q = Quickshell.env("SEARCH") || "";
        if (q)
            s.setSearchQuery(q);
        if ((Quickshell.env("REAL") || "") === "1")
            s.realHover("mockup", true);
        if (Number(Quickshell.env("REALAT") || 0) > 0)
            realAtTimer.start();
        if ((Quickshell.env("OPEN") || "1") !== "0" && win._owner)
            win._owner.open();
        if ((Quickshell.env("CLOSED") || "") === "1")
            closedTimer.start();
        if (Quickshell.env("DETAIL"))
            detailTimer.start();
        if (Quickshell.env("SORTMENU") || Quickshell.env("SCRUB"))
            poseTimer.start();
    }
    function keyFor(sym) {
        const s = win.svc;
        if (s.position(sym))
            return { symbol: sym, from: (s.position(sym).shares > 0 ? "holding" : "closed") };
        if (s.isWatched(sym))
            return { symbol: sym, from: "watch" };
        const idx = s.indices || [];
        for (let i = 0; i < idx.length; i++)
            if (idx[i].symbol === sym)
                return { symbol: sym, from: "index" };
        return { symbol: sym, from: "search" };
    }
    function applyDetail() {
        const parts = (Quickshell.env("DETAIL") || "").split(":");
        if (!parts[0] || !win._popup)
            return;
        if (parts[1])
            win.svc.detailRange = parts[1];
        const key = win.keyFor(parts[0]);
        // Open it, never toggle it: a persistent detail may already be back.
        if (win._popup.secondaryOpen && win._popup.sameKey(win._popup.secondaryKey, key))
            return;
        win._popup.openDetail(key, win._popup.anchorFor(key));
    }

    // =====================================================================
    //  RUN PAGE
    // =====================================================================
    readonly property StocksBarOwner _owner: ownerLoader.item as StocksBarOwner
    readonly property var _popup: stocksEngine.thePopup && stocksEngine.popupOwnerId === "stocks" ? stocksEngine.thePopup.contentItem : null
    readonly property var _detail: stocksEngine.childPopup ? stocksEngine.childPopup.contentItem : null

    // Every symbol the popup can show a logo for (facts only: strings).
    readonly property var logoSymbols: {
        const s = win.svc;
        const out = [];
        const add = x => {
            if (x && out.indexOf(x) < 0)
                out.push(x);
        };
        const p = s.portfolio;
        if (p) {
            (p.holdings || []).forEach(h => add(h.symbol));
            (p.closed || []).forEach(h => add(h.symbol));
        }
        (s.watchlist || []).forEach(add);
        (s.indices || []).forEach(r => add(r.symbol));
        return out;
    }

    pages: [
        MockupPage {
            id: layoutPage

            TipGroup {
                title: "Where the detail opens"
                blurb: "The Detail group below, in words: which side of the popup the stock's detail grows from, what it is placed against along that side, and how it relates to the popup. A start or end detail on a top bar widens the stage by the detail's width so it stays in view (the button moves over for start)."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
                text: {
                    const p = win._popup;
                    const lines = [];
                    lines.push("side: " + win.detailSideName + "   anchor: " + win.detailAnchorName);
                    lines.push("width: " + tun.detailWidthScale.toFixed(2) + " x " + Math.round(tun.popupWidth) + " = " + Math.round(tun.popupWidth * tun.detailWidthScale) + " px"
                               + "   inset: " + Math.round(tun.detailInset) + " px");
                    if (p)
                        lines.push("overhang: " + (p.secondaryOverhang ? "on" : "off") + (tun.detailOverhang ? "" : " (automatic)"));
                    if (win._detail && win._detail.secondaryCutout !== undefined) {
                        const r = win._detail.secondaryCutout;
                        lines.push("cutout: " + Math.round(r.x) + "," + Math.round(r.y) + " " + Math.round(r.width) + " x " + Math.round(r.height));
                    }
                    return lines.join("\n");
                }
            }
        },
        MockupPage {
            id: logosPage

            TipGroup {
                title: "Gallery"
                blurb: "Every logo the popup can show, engraved at the row's size and the detail's, on the list-box ground they are cut into. A symbol Parqet does not know shows its monogram; an index its word-mark, or nothing under 44 px."
            }
            Flow {
                Layout.fillWidth: true
                spacing: 10
                Repeater {
                    model: win.logoSymbols
                    delegate: Rectangle {
                        id: tile
                        required property string modelData
                        width: 132
                        height: 96
                        radius: 10
                        color: Theme.listBox
                        // The rows' and the header's carve (StockRow, StockDetailHeader).
                        LogoRelief {
                            x: 10
                            y: 10
                            logoSize: tun.logoSize
                            surfaceColor: Theme.listBox
                            shadowColor: Theme.shadowDeep
                            bodyColor: Mix.c(Theme.panelSunk, Theme.border, Theme.mode === "dark" ? 0.5 : 1.0)
                            falloff: Theme.mode === "dark" ? 0.6 : 0.3
                            ambient: Theme.mode === "dark" ? 0.6 : 1.0
                            bevelWidth: 0.3
                            source: {
                                void win.svc.logoSerial;
                                return win.svc.logoFor(tile.modelData, tun.logoSize) || "";
                            }
                        }
                        LogoRelief {
                            x: tile.width - 10 - tun.detailLogoSize
                            y: 10
                            logoSize: tun.detailLogoSize
                            surfaceColor: Theme.listBox
                            shadowColor: Theme.shadowDeep
                            bodyColor: Mix.c(Theme.panelSunk, Theme.border, Theme.mode === "dark" ? 0.35 : 0.85)
                            falloff: Theme.mode === "dark" ? 0.8 : 0.4
                            ambient: Theme.mode === "dark" ? 0.5 : 1.0
                            bevelWidth: 0.2
                            source: {
                                void win.svc.logoSerial;
                                return win.svc.logoFor(tile.modelData, tun.detailLogoSize) || "";
                            }
                        }
                        Text {
                            x: 10
                            y: tile.height - height - 6
                            text: tile.modelData
                            color: Theme.textMuted
                            font.family: "Inter"
                            font.pixelSize: 11
                        }
                    }
                }
            }
        },
        MockupPage {
            id: runPage

            TipGroup {
                title: "The popup"
                blurb: "Open and close it the way the bar does, and choose what the data is."
            }
            TipRow {
                tip: "Open or close the popup, as a click on the stocks button in the bar does."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: win._owner && win._owner.popupMine ? "Close" : "Open"
                    onClicked: {
                        if (win._owner)
                            win._owner.toggle();
                    }
                }
                Button {
                    text: "Close detail"
                    enabled: !!win._popup && win._popup.secondaryOpen
                    onClicked: win._popup.closeDetail()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipGroup {
                title: "The flourish"
                blurb: "The bar button's hover flourish: a ripple along the line and an arrow off its tip; closed, a neutral wave through the dots. Its numbers are the Bar tab's Flourish group."
            }
            TipRow {
                tip: "Play the flourish as a hover does (the face it wears now: a gain, a loss or closed, held for the play)."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "Play flourish"
                    onClicked: stocksButton.flourish.play("panel")
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Which captured situation the mock plays: the capture itself (market-open), a closed or pre-market session, offline or rate-limited fetches, an empty or broken portfolio, a split, a dividend, an over-sell, an alert, or a first load that never answers."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "Scenario"
                }
                ComboBox {
                    Layout.fillWidth: true
                    model: mock.scenarios
                    currentIndex: Math.max(0, mock.scenarios.indexOf(mock.scenario))
                    onActivated: i => mock.scenario = mock.scenarios[i]
                }
            }
            TipRow {
                tip: "Where the captured European session is: 0 = 09:00, 1 = 17:30 CEST. Prices, sparklines and every figure follow it; past the capture the mock continues each price with a smooth deterministic walk."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "Session"
                }
                Slider {
                    Layout.fillWidth: true
                    from: 0
                    to: 1
                    value: mock.sessionClock < 0 ? 0.24 : mock.sessionClock
                    onMoved: mock.sessionClock = value
                }
            }
            TipRow {
                tip: "Open a stock's detail in the secondary, at a range -- what a click on its row does."
                Layout.fillWidth: true
                spacing: 8
                TextField {
                    id: detailSym
                    Layout.preferredWidth: 110
                    text: "ASML.AS"
                }
                ComboBox {
                    id: detailRange
                    Layout.preferredWidth: 80
                    model: ["1D", "5D", "1M", "6M", "YTD", "1Y", "5Y", "MAX"]
                }
                Button {
                    text: "Open detail"
                    enabled: !!win._popup
                    onClicked: {
                        win.svc.detailRange = detailRange.currentText;
                        const k = win.keyFor(detailSym.text);
                        win._popup.openDetail(k, win._popup.anchorFor(k));
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Hold the real (inflation-adjusted) flip on, as if a gain figure were hovered; every gain figure in the popup and the detail swaps with its label word."
                Layout.fillWidth: true
                spacing: 8
                Switch {
                    text: "Real figures"
                    onToggled: win.svc.realHover("mockup", checked)
                }
                Button {
                    text: "Fire alert"
                    onClicked: {
                        if (win.svc.fireTestAlert)
                            win.svc.fireTestAlert();
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Type into the search as the field would (the 300 ms debounce is the service's)."
                Layout.fillWidth: true
                spacing: 8
                TextField {
                    id: searchText
                    Layout.fillWidth: true
                    placeholderText: "search text"
                }
                Button {
                    text: "Search"
                    onClicked: win.svc.setSearchQuery(searchText.text)
                }
                Button {
                    text: "Clear"
                    onClicked: win.svc.clearSearch()
                }
            }
            TipRow {
                tip: "Swap the mock for the REAL service: live requests to Yahoo, CNBC and Eurostat, your ~/.config/quickshell/config/stocks.jsonc (the example if there is none), and a mockup-private state file. Arm, then confirm."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: win.live ? "Live" : (win.armedLive ? "Confirm: go live" : "Live...")
                    enabled: !win.live
                    onClicked: {
                        if (win.armedLive) {
                            if (win._owner)
                                win._owner.close();
                            win.live = true;
                        } else {
                            win.armedLive = true;
                        }
                    }
                }
                Button {
                    visible: win.armedLive || win.live
                    text: win.live ? "Back to the mock" : "Cancel"
                    onClicked: {
                        if (win._owner)
                            win._owner.close();
                        win.live = false;
                        win.armedLive = false;
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "State"
                blurb: "What the popup and the service believe right now."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
                text: {
                    const s = win.svc;
                    const p = win._popup;
                    const lines = [];
                    lines.push((win.live ? "LIVE" : "mock: " + mock.scenario) + (s.loading ? "   loading" : "") + (s.offline ? "   offline" : "") + (s.rateLimited ? "   rate-limited" : ""));
                    lines.push("tab: " + s.tab + "   sort: " + s.sortKey + (s.sortAscending ? " asc" : " desc") + (s.searchQuery ? "   search: " + s.searchQuery : "") + (s.showReal ? "   REAL" : ""));
                    lines.push("rows: " + s.holdingRows.count + " held, " + s.watchRows.count + " watched, " + s.closedRows.count + " closed, " + s.searchRows.count + " found");
                    if (p)
                        lines.push("popup: " + Math.round(p.implicitWidth) + " x " + Math.round(p.implicitHeight) + (p.secondaryOpen && p.secondaryKey ? "   detail: " + p.secondaryKey.symbol + " (" + p.secondaryKey.from + ")" : ""));
                    if (win._detail && win._detail.implicitHeight !== undefined)
                        lines.push("detail: " + Math.round(win._detail.implicitWidth) + " x " + Math.round(win._detail.implicitHeight));
                    lines.push("keyboard: " + stocksEngine.popupKeyboard);
                    return lines.join("\n");
                }
            }
        }
    ]

    // =====================================================================
    //  VALUES
    // =====================================================================
    readonly property var layoutParams: [
        {
            label: "Audiowide",
            prop: "dressAudiowide",
            group: "Type",
            blurb: "The face the popup is set in.",
            tip: "Dress the popup in Audiowide instead of Inter. Inter is the module default (CLAUDE.md); Audiowide has no tabular figures, so every figure sits in a slot sized by its template either way.",
            val: false
        },
        {
            label: "popup width",
            prop: "popupWidth",
            group: "Popup",
            blurb: "The main popup's size. It never resizes on a tab switch.",
            tip: "Width of the main popup. 504 = 480 of cards + 12 padding each side (the plan's default).",
            val: 504,
            from: 400,
            to: 640,
            step: 1
        },
        {
            label: "list rows",
            prop: "listRows",
            group: "Popup",
            tip: "How many rows tall the list is. Fixed, so Holdings, Watchlist, search and an empty list all keep the popup's height; 6 is the user's number.",
            val: 6,
            from: 3,
            to: 10,
            step: 1
        },
        {
            label: "row height",
            prop: "rowHeight",
            group: "Popup",
            tip: "Height of a two-line row. 44 holds a 30 px logo with 7 px of air above and below it.",
            val: 44,
            from: 36,
            to: 60,
            step: 1
        },
        {
            label: "detail anchor",
            prop: "detailAnchor",
            group: "Detail",
            blurb: "The stock's detail, in the engine's secondary popup: where it opens (the side is stocks.jsonc's look.secondarySide; DSIDE= sets it here) and how big.",
            tip: "What the detail is placed against, along the side it hangs from: 0 = the row (or index cell) that was clicked, 1 = its start flush with the popup's start, 2 = centred on the popup, 3 = its end flush with the popup's end. Below the popup that is its x, beside it its y. The clicked row is the default: the detail follows the finger.",
            val: 0,
            from: 0,
            to: 3,
            step: 1
        },
        {
            label: "detail width",
            prop: "detailWidthScale",
            group: "Detail",
            tip: "Width of the detail in popup widths. 1 = the popup's own width, so the two read as one column; wider than 1 turns overhang on by itself (the engine would otherwise centre a wider detail on the popup and ignore the anchor).",
            val: 1,
            from: 0.6,
            to: 1.6,
            step: 0.05
        },
        {
            label: "overhang",
            prop: "detailOverhang",
            group: "Detail",
            tip: "Let the detail hang past the popup's ends (kept on the screen between the edge bars), so an anchor near an end can place it off the popup's span. Off by default: a detail no longer than the popup stays within it. Always on while the detail is longer than the popup along its side.",
            val: false
        },
        {
            label: "inset",
            prop: "detailInset",
            group: "Detail",
            tip: "How far the detail reaches UNDER the popup, px (secondaryInset). The overlap is the popup's; the detail lays its body out past the cutout, on whichever side it hangs. 0: the two only touch.",
            val: 0,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "detail max height",
            prop: "detailMaxHeight",
            group: "Detail",
            tip: "The detail is as tall as its content (a static size: the transaction list has its own three-row viewport) and never grows past this; beyond it the whole body scrolls, as a last resort for a short screen. The default clears the tallest detail with a position. A cutout (inset) is added to it, so the visible part keeps this height.",
            val: 960,
            from: 400,
            to: 1200,
            step: 1
        },
        {
            label: "flash peak",
            prop: "flashPeak",
            group: "Real flash",
            blurb: "The pale pill behind every gain figure that flips when a gain figure is hovered (the service's realFlash clock: 1 at the flip, a quarter while real stays on, out on leave).",
            tip: "How far toward the accent the figure's ground goes at the flash's peak (0..1). 0.22 reads as a flash on both palettes without turning into a highlight; the hold is a quarter of it.",
            val: 0.22,
            from: 0,
            to: 0.6,
            step: 0.01
        },
        {
            label: "flash pad",
            prop: "flashPad",
            group: "Real flash",
            tip: "Air either side of the figure's ink inside the pill, px. 3: the pill hugs the figure without touching its neighbour's slot.",
            val: 3,
            from: 0,
            to: 8,
            step: 1
        }
    ]

    readonly property var chartParams: [
        {
            label: "summary chart",
            prop: "summaryChartHeight",
            group: "Charts",
            blurb: "The two charts' heights.",
            tip: "Height of the value-vs-invested chart in the summary card. 96 keeps the popup under 640 with six rows.",
            val: 96,
            from: 60,
            to: 180,
            step: 1
        },
        {
            label: "detail chart",
            prop: "detailChartHeight",
            group: "Charts",
            tip: "Height of the detail's price chart, volume at its foot.",
            val: 180,
            from: 120,
            to: 320,
            step: 1
        }
    ]

    readonly property var stripParams: [
        {
            label: "cycle",
            prop: "stripCycleMs",
            group: "Indices strip",
            blurb: "The three cells rolling through the config's indices.",
            tip: "How long a cell shows one index before it rolls to the next, ms. 4000 reads a figure comfortably without the strip feeling stuck.",
            val: 4000,
            from: 1500,
            to: 10000,
            step: 100
        },
        {
            label: "roll",
            prop: "stripRollMs",
            group: "Indices strip",
            tip: "Duration of one roll, ms. 420: long enough to read as a movement, short enough to be done before the eye lands.",
            val: 420,
            from: 150,
            to: 1000,
            step: 10
        },
        {
            label: "stagger",
            prop: "stripStaggerMs",
            group: "Indices strip",
            tip: "Delay between the three cells' rolls, ms, so they turn over as a ripple rather than as one block.",
            val: 90,
            from: 0,
            to: 400,
            step: 10
        },
        {
            label: "hover dwell",
            prop: "stripHoverDwellMs",
            group: "Indices strip",
            tip: "How long the pointer must rest on the strip before the cells snap to the biggest movers, ms. 400: a pointer crossing the strip on its way to the list does nothing (the user, round 2), one that stops to read gets the movers.",
            val: 400,
            from: 0,
            to: 1500,
            step: 10
        },
        {
            label: "release grace",
            prop: "stripReleaseGraceMs",
            group: "Indices strip",
            tip: "How long after the pointer leaves the strip the movers are let go, ms. 250: a hand that slips off an edge and comes straight back keeps the snap instead of setting the cells rolling.",
            val: 250,
            from: 0,
            to: 1500,
            step: 10
        }
    ]

    readonly property var logoParams: [
        {
            label: "row logo",
            prop: "logoSize",
            group: "Logos",
            blurb: "The engraved logos (the LLM module's relief bake).",
            tip: "Size of a row's engraved logo, px. 30 fills a 44 px row with room for its bevel.",
            val: 30,
            from: 20,
            to: 40,
            step: 1
        },
        {
            label: "detail logo",
            prop: "detailLogoSize",
            group: "Logos",
            tip: "Size of the detail's engraved logo, px -- the link to the stock's Yahoo page.",
            val: 56,
            from: 40,
            to: 80,
            step: 1
        }
    ]

    readonly property var barParams: [
        {
            label: "along",
            prop: "iconAlong",
            group: "Bar button",
            blurb: "The button in the bar: a sparkline of today's value and the day's percent.",
            tip: "Where the button sits along the top bar, px (the mockup's own placement).",
            val: 560,
            from: 100,
            to: 1000,
            step: 1
        },
        {
            label: "spark width",
            prop: "sparkWidth",
            group: "Bar button",
            tip: "Width of the bar's sparkline. 22 x 12 is the user's size: a trend, not a chart.",
            val: 22,
            from: 12,
            to: 48,
            step: 1
        },
        {
            label: "spark height",
            prop: "sparkHeight",
            group: "Bar button",
            tip: "Height of the bar's sparkline.",
            val: 12,
            from: 6,
            to: 24,
            step: 1
        },
        {
            label: "figure size",
            prop: "barPixelSize",
            group: "Bar button",
            tip: "Pixel size of the day's percent. 11 is the shell's figure size.",
            val: 11,
            from: 8,
            to: 16,
            step: 1
        },
        {
            label: "style",
            prop: "flourishStyle",
            group: "Flourish",
            blurb: "The hover flourish of the bar button (hover it, or Play on the Run tab).",
            tip: "What plays: both (the ripple, then the arrow off the tip: the default), the ripple alone, or the arrow alone. A closed face always gets the neutral wave through the dots.",
            val: 0,
            choices: ["both", "ripple", "arrow"],
            promote: { to: "StocksBarButton.flourishStyle", map: ["both", "ripple", "arrow"] }
        },
        {
            label: "ms",
            prop: "flourishMs",
            group: "Flourish",
            tip: "The play's length scale: 900 is the bar's usual beat and the pose's own timing (a live both-play is ~690 ms); more is slower.",
            val: 900,
            from: 300,
            to: 2400,
            step: 10
        },
        {
            label: "amplitude",
            prop: "flourishAmp",
            group: "Flourish",
            tip: "How high the ripple lifts the line (a loss dips by the same), px. 2 reads on a 12 px line without redrawing it.",
            val: 2,
            from: 0.5,
            to: 5,
            step: 0.1
        },
        {
            label: "lump width",
            prop: "flourishHalf",
            group: "Flourish",
            tip: "The ripple's half width, px (it ends at twice this). 5 is a quarter of the 22 px line.",
            val: 5,
            from: 2,
            to: 10,
            step: 0.5
        },
        {
            label: "arrow travel",
            prop: "arrowTravel",
            group: "Flourish",
            tip: "How far the arrow flies from the tip, px (up on a gain, down on a loss). Keep it in the face.",
            val: 5,
            from: 1,
            to: 10,
            step: 0.5
        },
        {
            label: "arrow size",
            prop: "arrowSize",
            group: "Flourish",
            tip: "The arrow's width, px (a plain triangle, no tail). It lives in the gap beside the line's tip, so past ~6 it reaches the figure.",
            val: 4,
            from: 2,
            to: 8,
            step: 0.5
        },
        {
            label: "arrow alpha",
            prop: "arrowAlpha",
            group: "Flourish",
            tip: "The arrow's ink at its most, a share of the line's colour: 0.6 keeps it a hint, never a second figure.",
            val: 0.6,
            from: 0.1,
            to: 1,
            step: 0.05
        }
    ]

    readonly property var stockColors: [
        {
            label: "gain",
            prop: "stockGain",
            group: "Stocks",
            blurb: "The module's four roles, themed (eva light shown).",
            tip: "A rise, a gain: the palette's OK green.",
            val: "#44C145"
        },
        {
            label: "loss",
            prop: "stockLoss",
            group: "Stocks",
            tip: "A fall, a loss: the palette's error red.",
            val: "#EC0000"
        },
        {
            label: "buy",
            prop: "stockBuy",
            group: "Stocks",
            tip: "A buy marker and a Buy in the transactions: the accent blue, NOT the gain green, which means something else.",
            val: "#4480F4"
        },
        {
            label: "sell",
            prop: "stockSell",
            group: "Stocks",
            tip: "A sell marker and a Sell: the warn orange, not the loss red.",
            val: "#F0AA0B"
        }
    ]
}
