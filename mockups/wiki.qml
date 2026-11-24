pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

import "modules/common/components"
import "modules/common/mockup"
import "modules/common/theme"
import "modules/bar/gooey"
import "modules/clock"
import "modules/clock/data"
import "modules/wiki"
import "modules/wiki/data"

// =============================================================================
// mockups/wiki.qml -- the wiki module's mockup, on the framework
// (modules/common/mockup/, contract in docs/contracts/mockup_framework.md).
//
// THE DATA IS WikiMock: eight hand-made entries (modules/wiki/data/fixtures/),
// the same card assembly as the real service, the clock pinned to 2026-09-30,
// and every ask recorded in `calls` (the Run tab reads them). Nothing here
// reads the network, the user's wiki state or the wiki.jsonc config.
//
// THREE SCENES (SCENE=card|compact|clock at launch, or the Run tab's scene box)
//
//   card     the drop-in WikiPopup at its own implicit size: the clock popup's
//            secondary, hero + title row + paragraph + tab dots. The default.
//   compact  WikiCompactCard's three variants and WikiTeaser side by side, each
//            at its real host's width and on its real host's ground: the
//            tear-off on the calendar panel (194), the wide card on a popup's
//            surface (396), the lock row on the lock band (440 x 92) and the
//            launcher's teaser line (380 x 18).
//   clock    the REAL engine (GooeyEngine, a top bar, ClockBarOwner) with the
//            mock injected as the owner's wikiService -- once ClockBarOwner
//            has those properties (stage 4A); until then the scene says so
//            and shows the clock popup alone.
//
// THE PANEL. Run (scenes, scenario, the asks a card makes, the call log),
// Card (WikiPopup's frame, then every WikiStyle number in twelve sub-tabs),
// Behaviour (the carousel, the reporting and the swipe), Compact (each variant its own sub-tab), Data (WikiMock's own
// timing knobs). The compact cards' `groundColor` is not on the panel: it is the
// HOST's to say (a colour the host paints under the card), so each cell binds
// the ground its real host has.
//
// Env (this file's own; the framework's GRAB / PANEL_* still apply):
//   SCENE=card|compact|clock   SCENARIO=<WikiMock scenario>   TAB=discover|deepen
//   VEIL=<pattern>             every card with no photograph shows this veil (default: each article its own)
//   FONT=<family>              the face of every card (the user dresses mockups in Audiowide)
//   STAGE_GRAB=<png>           the stage alone (the drop-in on its ground), GRAB_MS
//                              after the start, then quit   ZOOM=<x>  (grab at 1)
//   OPEN=1|wiki[:deepen]       scene clock: open the clock popup at the start, or ask for
//                              the wiki card the way a notification's click does
//   LIVE=1                     start on the REAL WikiService (see LIVE DATA below); the
//                              env is the confirmation, the Run tab's switch asks for one
//   LIVE_REPORT=<ms>           print one `WIKI-LIVE {json}` line that long after the start
//                              (the service, the pool, the cards, the batch) and quit
//
// Run it: tools/dev/wiki_mockup.sh run    (a private theme, config and state)
//         tools/dev/wiki_mockup.sh grab OUT.png
// =============================================================================
MockupWindow {
    id: win

    moduleId: "wiki"
    title: "Wiki"
    stageLabel: win.sceneName === "compact"
        ? "WikiCompactCard (tear-off, wide, lock) and WikiTeaser on their hosts' grounds"
        : win.sceneName === "clock"
            ? "The clock popup on the real engine, the wiki service injected"
            : "WikiPopup (drop-in for the clock popup's secondary)"
    content: win.sceneName === "compact" ? compactScene : (win.sceneName === "clock" ? clockScene : popup)
    // The engine clips a body to the box it animates; so does the stage.
    clipContent: true
    fitContent: true
    stageColor: win.sceneName === "clock" ? "#1F2229" : Theme.surface
    zoom: Number(Quickshell.env("ZOOM") || 1)
    panelWidth: 480
    target: popup
    targets: ({
            styleParams: popup.style,
            veilParams: popup.style.veil,
            mockParams: mock,
            tearoffParams: tearoffCard,
            wideParams: wideCard,
            lockParams: lockCard,
            teaserParams: teaser
        })

    lists: ({
            frameParams: win.frameParams,
            styleParams: win.styleParams,
            veilParams: win.veilParams,
            behaviourParams: win.behaviourParams,
            mockParams: win.mockParams,
            tearoffParams: win.tearoffParams,
            wideParams: win.wideParams,
            lockParams: win.lockParams,
            teaserParams: win.teaserParams
        })

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Card",
            subs: [
                {
                    name: "Frame",
                    lists: ["frameParams"]
                },
                {
                    name: "Column",
                    lists: ["styleParams"],
                    groups: ["Column", "Presence"]
                },
                {
                    name: "Type",
                    lists: ["styleParams"],
                    groups: ["Type"]
                },
                {
                    name: "Title row",
                    lists: ["styleParams"],
                    groups: ["Title row"]
                },
                {
                    name: "Marks",
                    lists: ["styleParams"],
                    groups: ["Marks"]
                },
                {
                    name: "Tips",
                    lists: ["styleParams"],
                    groups: ["Tips"]
                },
                {
                    name: "Well",
                    lists: ["styleParams"],
                    groups: ["Well"]
                },
                {
                    name: "Band",
                    lists: ["styleParams"],
                    groups: ["Band"]
                },
                {
                    name: "Buttons",
                    lists: ["styleParams"],
                    groups: ["Buttons"]
                },
                {
                    name: "Dots",
                    lists: ["styleParams"],
                    groups: ["Dots"]
                },
                {
                    name: "Chip",
                    lists: ["styleParams"],
                    groups: ["Chip"]
                },
                {
                    name: "Skeleton",
                    lists: ["styleParams"],
                    groups: ["Skeleton"]
                }
            ]
        },
        {
            name: "Veils",
            subs: [
                {
                    name: "Material",
                    lists: ["veilParams"],
                    groups: ["Clock", "Material", "Plate and thumb"]
                },
                {
                    name: "Contours",
                    lists: ["veilParams"],
                    groups: ["Contours"]
                },
                {
                    name: "Links",
                    lists: ["veilParams"],
                    groups: ["Links"]
                },
                {
                    name: "Ripples",
                    lists: ["veilParams"],
                    groups: ["Ripples"]
                },
                {
                    name: "Maze",
                    lists: ["veilParams"],
                    groups: ["Maze"]
                },
                {
                    name: "Cells",
                    lists: ["veilParams"],
                    groups: ["Cells"]
                }
            ]
        },
        {
            name: "Behaviour",
            lists: ["behaviourParams"]
        },
        {
            name: "Compact",
            subs: [
                {
                    name: "Tear-off",
                    lists: ["tearoffParams"]
                },
                {
                    name: "Wide",
                    lists: ["wideParams"]
                },
                {
                    name: "Lock",
                    lists: ["lockParams"]
                },
                {
                    name: "Teaser",
                    lists: ["teaserParams"]
                }
            ]
        },
        {
            name: "Data",
            lists: ["mockParams"]
        }
    ]

    // ---- the scene and what the env asks for ------------------------------------------------------------
    property string sceneName: {
        const s = Quickshell.env("SCENE") || "card";
        return s === "compact" || s === "clock" ? s : "card";
    }
    readonly property var sceneNames: ["card", "compact", "clock"]
    // What the hosts of the compact cards paint under them (each cell binds
    // its own; the ground is the host's to say, so it is not a panel row).
    readonly property color calendarPanelFill: Theme.panelSunk
    readonly property color lockBandFill: Theme.listBox

    // The Run tab's veil picker: "" = each article its own (the shell's rule). Env VEIL=<name> starts on one.
    property string veilOnly: Quickshell.env("VEIL") || ""
    Binding {
        target: popup.style.veil
        property: "only"
        value: win.veilOnly
    }

    // What the Run tab reports back.
    property string lastUrl: ""
    property string lastEvent: ""
    property string lastCompact: ""

    // ---- the data --------------------------------------------------------------------------------------------
    WikiMock {
        id: mock
        dryRun: !win.openReal
        scenario: Quickshell.env("SCENARIO") || "normal"
    }
    // A plain click on an intro link, and the source logo, open the browser
    // for real only when the Run tab says so (the live service always does).
    property bool openReal: false
    // What the service (the mock, or the live one) tells the Run tab.
    Connections {
        target: win.svc
        ignoreUnknownSignals: true
        function onUrlOpened(url) {
            win.lastUrl = url;
        }
        function onNoteSaved(tab, id, ok, keyOrError) {
            win.lastEvent = "noteSaved " + tab + " " + (ok ? "ok " : "FAILED ") + keyOrError;
        }
        function onOpenRequested(tab) {
            win.lastEvent = "openRequested " + tab;
        }
        function onRefillAsked(tab, left) {
            win.lastEvent = "refillAsked " + tab + " (" + left + " left)";
        }
        function onBatchFinished(tab, ok, failed) {
            win.lastEvent = "batchFinished " + tab + " ok " + ok + " failed " + failed;
        }
    }

    // ---- LIVE DATA (LIVE=1, or the Run tab's switch after its confirmation) ---------------------------------
    // The real WikiService in place of the mock, created ONLY while it is on
    // (by URL, so nothing of it loads until then): it reads the REAL pool
    // (index.json, entries/, img/ under the state dir), the real state.json
    // (seen, slots, interest, the refill latches -- and WRITES it), wiki.jsonc,
    // and the day's extras cache; a click on a source opens the real browser.
    // The service NEVER starts a batch by itself: when a tab's unseen count
    // reaches the ask threshold it posts a notification through the
    // DesktopNotifier below (app "Wiki", the service's own keys), and only the
    // user's answer to it starts one. Whatever the service asks of its tool
    // (a followed page, a saved note, today's On this day / Picture of the day
    // when they are not cached yet) is the user's own action or the one read
    // the confirmation names. One thing it does at its own start is to RESUME
    // a batch a progress file says was running; a mockup must not start one
    // either, so it refuses to go live while any progress file says so.
    readonly property string liveStateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/lares/wiki"
    readonly property string liveCacheDir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/lares/wiki"
    property bool live: false
    // The switch is on and the confirmation is up.
    property bool liveArmed: false
    property var liveInterrupted: []
    property string liveRefusal: ""
    readonly property var svc: win.live && liveLoader.item ? liveLoader.item : mock
    DesktopNotifier {
        id: liveNotifier
        appName: "Wiki"
        keys: win.svc && win.svc.notifyKeys ? win.svc.notifyKeys : []
    }
    Loader {
        id: liveLoader
        active: win.live
        source: win.live ? Qt.resolvedUrl("modules/wiki/data/WikiService.qml") : ""
        onLoaded: liveLoader.item.notifier = liveNotifier
    }
    // The clock scene's owner binds popupOpen itself; everywhere else the card
    // being on the stage is the popup being open.
    Binding {
        target: liveLoader.item
        property: "popupOpen"
        value: win.sceneName === "card"
        when: !!liveLoader.item && win.sceneName !== "clock"
    }
    // One FileView per file with a static path, read with reload().
    FileView {
        id: progDiscover
        path: win.liveStateDir + "/batch/discover.progress.json"
        blockAllReads: true
        printErrors: false
    }
    FileView {
        id: progDeepen
        path: win.liveStateDir + "/batch/deepen.progress.json"
        blockAllReads: true
        printErrors: false
    }
    // The tabs whose progress file says a batch is running (or was, when the
    // shell went down): the service would resume it the moment it starts.
    function interruptedBatches() {
        const out = [];
        const views = [["discover", progDiscover], ["deepen", progDeepen]];
        for (const v of views) {
            try {
                v[1].reload();
                const t = v[1].text();
                const p = t ? JSON.parse(t) : null;
                if (p && p.running === true)
                    out.push(v[0]);
            } catch (e) {
            }
        }
        return out;
    }
    function armLive() {
        win.liveInterrupted = win.interruptedBatches();
        win.liveRefusal = "";
        win.liveArmed = true;
    }
    function goLive() {
        win.liveInterrupted = win.interruptedBatches();
        win.liveArmed = false;
        if (win.liveInterrupted.length > 0) {
            win.liveRefusal = "live refused: a batch is running or was interrupted on " + win.liveInterrupted.join(" and ")
                + " (batch/<tab>.progress.json says running); the service would resume it at its start";
            console.log("WIKI-LIVE refused: " + win.liveRefusal);
            return false;
        }
        win.liveRefusal = "";
        win.live = true;
        return true;
    }
    function stopLive() {
        win.live = false;
        win.liveArmed = false;
    }
    // LIVE_REPORT=<ms>: one line of what the live (or mock) service serves, then quit.
    readonly property int liveReportMs: Number(Quickshell.env("LIVE_REPORT") || 0)
    function liveReport() {
        const s = win.svc;
        const c = t => {
            const k = s.card(t);
            return k ? k.id : "";
        };
        return {
            service: s === mock ? "mock" : "live",
            stateDir: s.stateDir !== undefined ? s.stateDir : "",
            cacheDir: s.cacheDir !== undefined ? s.cacheDir : "",
            ready: s.ready,
            day: s.day,
            unseen: { discover: s.unseen("discover"), deepen: s.unseen("deepen") },
            cards: { discover: c("discover"), deepen: c("deepen") },
            popupCard: popup.cardId,
            popupTitle: popup.card ? popup.card.title : "",
            batch: s.batch,
            lastError: s.lastError,
            offline: s.offline,
            refusal: win.liveRefusal
        };
    }
    Timer {
        running: win.liveReportMs > 0
        interval: win.liveReportMs
        onTriggered: {
            console.log("WIKI-LIVE " + JSON.stringify(win.liveReport()));
            Qt.quit();
        }
    }

    // =====================================================================
    //  THE DROP-IN CONTENT (scene card)
    // =====================================================================
    WikiPopup {
        id: popup
        visible: win.sceneName === "card"
        service: win.svc
        startTab: Quickshell.env("TAB") === "deepen" ? "deepen" : "discover"
        onCloseRequested: win.lastEvent = "closeRequested (Escape)"
    }

    // =====================================================================
    //  SCENE compact: each variant on its host's ground
    // =====================================================================
    Item {
        id: compactScene
        visible: win.sceneName === "compact"
        readonly property real m: 24
        readonly property real captionH: 18
        readonly property real gap: 14
        implicitWidth: compactScene.m * 2 + lockBand.width
        implicitHeight: teaserCell.y + teaserCell.height + compactScene.m

        // The tear-off stands on the calendar panel, under the appointments.
        Item {
            id: tearoffCell
            x: compactScene.m
            y: compactScene.m
            width: tearoffBand.width
            height: compactScene.captionH + tearoffBand.height
            Text {
                text: "tear-off  " + tearoffCard.width + " x " + tearoffCard.height + "  on the calendar panel"
                color: Theme.textMuted
                font.family: "Audiowide"
                font.pixelSize: 11
            }
            Rectangle {
                id: tearoffBand
                y: compactScene.captionH
                width: tearoffCard.width + 24
                height: tearoffCard.height + 24
                radius: 14
                color: win.calendarPanelFill
                WikiCompactCard {
                    id: tearoffCard
                    x: 12
                    y: 12
                    width: tearoffCard.implicitWidth
                    height: tearoffCard.implicitHeight
                    service: win.svc
                    variant: "tearoff"
                    groundColor: win.calendarPanelFill
                    onActivated: card => win.lastCompact = "tear-off: activated " + card.title
                    onOnThisDayActivated: follow => win.lastCompact = "tear-off: on this day, " + (follow ? "Ctrl+click follows" : "plain click opens")
                }
            }
        }
        // The wide card stands on the notification popup's surface (the stage's).
        Item {
            id: wideCell
            x: compactScene.m
            y: tearoffCell.y + tearoffCell.height + compactScene.gap
            width: lockBand.width
            height: compactScene.captionH + wideCard.height
            Text {
                text: "wide  " + wideCard.width + " x " + wideCard.height + "  on a popup's surface"
                color: Theme.textMuted
                font.family: "Audiowide"
                font.pixelSize: 11
            }
            WikiCompactCard {
                id: wideCard
                x: 12
                y: compactScene.captionH
                width: wideCard.implicitWidth
                height: wideCard.implicitHeight
                service: win.svc
                variant: "wide"
                groundColor: Theme.surface
                onActivated: card => win.lastCompact = "wide: activated " + card.title
                onOnThisDayActivated: follow => win.lastCompact = "wide: on this day, " + (follow ? "Ctrl+click follows" : "plain click opens")
            }
        }
        // The lock row stands on the lock band.
        Item {
            id: lockCell
            x: compactScene.m
            y: wideCell.y + wideCell.height + compactScene.gap
            width: lockBand.width
            height: compactScene.captionH + lockBand.height
            Text {
                text: "lock  " + lockCard.width + " x " + lockCard.height + "  on the lock band (not interactive)"
                color: Theme.textMuted
                font.family: "Audiowide"
                font.pixelSize: 11
            }
            Rectangle {
                id: lockBand
                y: compactScene.captionH
                width: lockCard.implicitWidth + 24
                height: lockCard.height + 24
                radius: 14
                color: win.lockBandFill
                WikiCompactCard {
                    id: lockCard
                    x: 12
                    y: 12
                    width: lockCard.implicitWidth
                    height: lockCard.implicitHeight
                    service: win.svc
                    variant: "lock"
                    groundColor: win.lockBandFill
                    onActivated: card => win.lastCompact = "lock: activated (it must not)"
                }
            }
        }
        // The teaser line, at the launcher's foot.
        Item {
            id: teaserCell
            x: compactScene.m
            y: lockCell.y + lockCell.height + compactScene.gap
            width: lockBand.width
            height: compactScene.captionH + teaser.height
            Text {
                text: "teaser  " + teaser.width + " x " + teaser.height + "  on the launcher's surface"
                color: Theme.textMuted
                font.family: "Audiowide"
                font.pixelSize: 11
            }
            WikiTeaser {
                id: teaser
                x: 12
                y: compactScene.captionH
                width: teaser.implicitWidth
                height: teaser.implicitHeight
                service: win.svc
                groundColor: Theme.surface
                onActivated: win.lastCompact = "teaser: activated"
            }
        }
    }

    // =====================================================================
    //  SCENE clock: the real engine and ClockBarOwner, the mock injected
    // =====================================================================
    Item {
        id: clockScene
        visible: win.sceneName === "clock"
        // The popup hangs from the button (x 420) and the card opens beside it, along the bar.
        implicitWidth: 1290
        implicitHeight: 620
        readonly property var _scene: clockLoader.item
        readonly property var owner: clockScene._scene ? clockScene._scene.owner : null
        // Whether ClockBarOwner takes the wiki service yet (stage 4A).
        readonly property bool supported: clockScene._scene ? clockScene._scene.supported : false

        Loader {
            id: clockLoader
            anchors.fill: parent
            active: win.sceneName === "clock"
            sourceComponent: clockComp
        }
    }
    Component {
        id: clockComp

        Item {
            id: clockRoot
            readonly property alias owner: clockOwner
            readonly property bool supported: ("wikiService" in clockOwner) && ("wikiEnabled" in clockOwner)

            Rectangle {
                anchors.fill: parent
                color: "#1F2229"
            }
            GooeyEngine {
                id: clockEngine
                anchors.fill: parent
                renderScale: win.stage.zoom
                surfaceColor: Theme.surface
                barsList: [clockBar]

                GooeyBar {
                    id: clockBar
                    engine: clockEngine
                    barId: "bar"
                    edge: "top"
                    rawPos: 0
                    rawLen: clockEngine.w

                    ClockBarButton {
                        id: clockButton
                        x: Math.round(420 - width / 2)
                        y: Math.round((clockBar.height - height) / 2)
                        onClicked: clockOwner.toggle()
                    }
                }
            }
            MockCalendarData {
                id: clockCalendar
            }
            // The mockup's own timers and a notifier that says nothing: the
            // live shell and a mockup must never both ring.
            QtObject {
                id: clockNotifier
                signal action(string key, string id)
                function notify(key, spec) {
                }
                function withdraw(key) {
                }
            }
            TimerService {
                id: clockTimers
                persist: false
                notifier: clockNotifier
            }
            ClockBarOwner {
                id: clockOwner
                engine: clockEngine
                bar: clockBar
                barId: "bar"
                anchorItem: clockButton
                calendarService: clockCalendar
                timerService: clockTimers
            }
            Text {
                visible: !clockRoot.supported
                anchors.horizontalCenter: parent.horizontalCenter
                y: 72
                width: parent.width - 96
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                color: "#F0AA0B"
                font.family: "Audiowide"
                font.pixelSize: 13
                text: "ClockBarOwner has no wikiService / wikiEnabled yet (stage 4A). The clock popup below is the owner as it is; the wiki is not wired into it."
            }
            // The service the owner hands the popup: the mock, or the live one.
            Binding {
                target: clockOwner
                property: "wikiService"
                value: win.svc
                when: clockRoot.supported
            }
            Component.onCompleted: {
                // The service first: with wikiEnabled on and none injected the
                // owner would build a real one of its own.
                if (clockRoot.supported) {
                    clockOwner.wikiService = win.svc;
                    clockOwner.wikiEnabled = true;
                }
                if ((Quickshell.env("OPEN") || "") !== "")
                    clockOpen.start();
            }
            // OPEN=1 opens the popup; OPEN=wiki[:discover|deepen] asks for the
            // card the way a notification's click does (service.requestOpen).
            Timer {
                id: clockOpen
                interval: 300
                onTriggered: {
                    const o = (Quickshell.env("OPEN") || "").split(":");
                    if (o[0] === "wiki")
                        win.svc.requestOpen(o[1] === "deepen" ? "deepen" : "discover");
                    else
                        clockOwner.open();
                }
            }
        }
    }

    // ---- STAGE_GRAB=<png>: the stage alone, GRAB_MS after the start, then quit --------------------------
    readonly property string stageGrab: Quickshell.env("STAGE_GRAB") || ""
    Timer {
        running: win.stageGrab !== ""
        interval: Number(Quickshell.env("GRAB_MS") || 2500)
        onTriggered: {
            // The stage's surface (opaque, at the content's own size): a
            // transparent item's fading pixels come back as saturated hues.
            const it = win.content.parent;
            it.grabToImage(r => {
                r.saveToFile(win.stageGrab);
                console.log("STAGE_GRAB saved " + win.stageGrab + " " + Math.round(it.width) + "x" + Math.round(it.height));
                Qt.quit();
            });
        }
    }

    Component.onCompleted: {
        // LIVE=1 is the user's yes (the Run tab's switch asks for one).
        if ((Quickshell.env("LIVE") || "") === "1")
            win.goLive();
        // The face of every card (the framework's own handler ran first, so
        // the panel's vals are already in and this shows as a * on them).
        const f = Quickshell.env("FONT") || "";
        if (f !== "") {
            popup.fontFamily = f;
            tearoffCard.fontFamily = f;
            wideCard.fontFamily = f;
            lockCard.fontFamily = f;
            teaser.fontFamily = f;
        }
    }

    // ---- helpers the Run tab uses --------------------------------------------------------------------------------
    // A scenario is applied by assigning it; the SAME one again is no change,
    // so a re-apply goes through another one first.
    function applyScenario(name) {
        if (mock.scenario === name)
            mock.scenario = name === "normal" ? "portrait" : "normal";
        mock.scenario = name;
    }
    function shortId(id) {
        return String(id).replace(/^en\.wikipedia\.org\//, "wp:").replace(/^wiki\.archlinux\.org\//, "arch:");
    }
    function callsText() {
        if (win.svc !== mock)
            return "(live: the real service keeps no call log; the card's own asks are the real ones)";
        const c = mock.calls;
        const rows = [];
        let shown = 0;
        for (let i = 0; i < c.length; i++) {
            if (c[i].fn === "shown")
                shown++;
            else
                rows.push(c[i].fn + (c[i].tab ? " " + c[i].tab : "") + (c[i].id ? " " + win.shortId(c[i].id) : ""));
        }
        return (rows.length > 0 ? rows.slice(-10).join("\n") : "(no asks yet)") + "\nshown() x" + shown + " in the last " + c.length;
    }
    function stateText() {
        const lines = [];
        const sv = win.svc;
        lines.push((sv === mock ? "scenario: " + mock.scenario : "LIVE service, ready " + sv.ready) + "   day: " + sv.day
                   + (sv.offline ? "   OFFLINE" : "") + (sv.busy ? "   busy" : ""));
        if (win.sceneName === "card") {
            lines.push("tab: " + popup.tab + "   " + (popup.card ? popup.card.title : "(no card)")
                       + (popup.loading ? "   loading" : "") + (popup.canBack ? "   trail: back to " + popup.parentTitle : ""));
            if (popup.card)
                lines.push("intro: " + popup.card.provenance + ", " + popup.card.words + " words   pictures: " + popup.card.images.length);
            lines.push("size: " + Math.round(popup.implicitWidth) + " x " + Math.round(popup.implicitHeight) + "   natural height " + popup.naturalHeight
                       + "   gesture " + (popup.swipeGestureActive ? "LIVE" : "idle"));
        } else if (win.sceneName === "compact") {
            lines.push("tear-off " + tearoffCard.width + " x " + tearoffCard.height + "   wide " + wideCard.width + " x " + wideCard.height
                       + "   lock " + lockCard.width + " x " + lockCard.height + "   teaser " + teaser.width + " x " + teaser.height);
        } else {
            lines.push("wiki wired into the clock owner: " + (clockScene.supported ? "yes" : "no (stage 4A)"));
        }
        lines.push("pool: " + sv.unseen("discover") + " discover / " + sv.unseen("deepen") + " deepen unseen"
                   + (sv.batch.running ? "   batch " + sv.batch.tab + " " + sv.batch.done + "/" + sv.batch.total : ""));
        if (sv.lastError)
            lines.push("last error: " + sv.lastError);
        if (win.lastUrl !== "")
            lines.push("last url: " + win.lastUrl);
        if (win.lastEvent !== "")
            lines.push("last event: " + win.lastEvent);
        if (win.lastCompact !== "")
            lines.push("compact: " + win.lastCompact);
        return lines.join("\n");
    }

    // =====================================================================
    //  THE MODULE'S OWN PANEL PAGE
    // =====================================================================
    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Scene"
                blurb: "What the stage holds. SCENE=card|compact|clock picks it at launch."
            }
            TipRow {
                tip: "card: the drop-in WikiPopup, the clock popup's secondary. compact: the three compact cards and the launcher teaser at their hosts' widths and on their hosts' grounds. clock: the real engine with a top bar and the clock owner, the mock injected as its wiki service (once the owner has the properties)."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "scene"
                }
                ComboBox {
                    objectName: "wikiRunScene"
                    Layout.preferredWidth: 120
                    model: win.sceneNames
                    currentIndex: win.sceneNames.indexOf(win.sceneName)
                    onActivated: win.sceneName = currentText
                }
                Button {
                    objectName: "wikiRunOpenClock"
                    visible: win.sceneName === "clock"
                    text: "Open the clock popup"
                    enabled: !!clockScene.owner
                    onClicked: clockScene.owner.open()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                visible: win.sceneName === "clock"
                tip: "Ask for the card the way a notification's click does: service.requestOpen(tab) says openRequested, the clock owner opens its popup on the Calendar tab with the card out beside it on that tab (or moves the card when the popup is open). Nothing else ever opens it."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "request the card"
                }
                Button {
                    objectName: "wikiRunRequestDiscover"
                    text: "Discover"
                    onClicked: win.svc.requestOpen("discover")
                }
                Button {
                    objectName: "wikiRunRequestDeepen"
                    text: "Deepen"
                    onClicked: win.svc.requestOpen("deepen")
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Live data"
                blurb: "The real WikiService in place of the mock, behind a confirmation."
            }
            TipRow {
                tip: "LIVE: the real WikiService replaces the mock. It reads your REAL pool (index.json, entries/, img/ under the state dir the readout names), your real state.json (seen, slots, interest, refill latches -- and writes it), wiki.jsonc and the day's extras cache, and a click on a source or a link opens your real browser. It never starts a batch by itself: when a tab is nearly used up it posts a notification (app Wiki) and only your answer starts one. With an empty pool the card shows its empty state and nothing is filled. Following a link, saving a note and today's On this day / Picture of the day (fetched once when not cached) are the only other things that reach the network or your disk, and each is your own action or named in the confirmation. Refused while a progress file says a batch is running or was interrupted: the service would resume it. Env: LIVE=1 (the env is the yes)."
                Layout.fillWidth: true
                spacing: 8
                Switch {
                    id: liveSwitch
                    objectName: "wikiRunLive"
                    onToggled: {
                        if (checked)
                            win.armLive();
                        else
                            win.stopLive();
                    }
                }
                Binding {
                    target: liveSwitch
                    property: "checked"
                    value: win.live || win.liveArmed
                }
                Label {
                    text: "live data"
                }
                Label {
                    visible: win.live
                    text: "LIVE"
                    color: "#EC0000"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                    font.bold: true
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            ColumnLayout {
                objectName: "wikiRunLiveConfirm"
                visible: win.liveArmed
                Layout.fillWidth: true
                spacing: 6
                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    color: "#5D5D5F"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                    text: "Go live? The card will show and WRITE your real wiki state under " + win.liveStateDir
                        + ". Refill asks come as notifications (app Wiki) and only your answer starts a batch. "
                        + "Today's On this day and Picture of the day are fetched once if they are not cached. "
                        + "If your shell runs the wiki service too, both write state.json and both ask."
                }
                Label {
                    Layout.fillWidth: true
                    visible: win.liveInterrupted.length > 0
                    wrapMode: Text.Wrap
                    color: "#EC0000"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                    text: "A batch is running or was interrupted on " + win.liveInterrupted.join(" and ")
                        + ": the service would resume it at its start, so live is refused until that is dealt with."
                }
                TipRow {
                    tip: "The confirmation's two answers. Go live puts the real WikiService in the mock's place, unless a progress file says a batch is running or was interrupted (then it is refused and says why); Cancel takes the question away and the mock stays."
                    spacing: 8
                    Button {
                        objectName: "wikiRunLiveGo"
                        text: "Go live"
                        enabled: win.liveInterrupted.length === 0
                        onClicked: win.goLive()
                    }
                    Button {
                        objectName: "wikiRunLiveCancel"
                        text: "Cancel"
                        onClicked: win.liveArmed = false
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                }
            }
            Label {
                objectName: "wikiRunLiveRefusal"
                Layout.fillWidth: true
                visible: win.liveRefusal !== ""
                wrapMode: Text.Wrap
                color: "#EC0000"
                font.family: "Audiowide"
                font.pixelSize: 12
                text: win.liveRefusal
            }
            TextEdit {
                // Selectable, so the paths can be copied.
                objectName: "wikiLiveReadout"
                Layout.fillWidth: true
                visible: win.live
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.WrapAnywhere
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
                text: {
                    const sv = liveLoader.item;
                    if (!sv)
                        return "live: starting";
                    const b = sv.batch;
                    return "live: WikiService " + (sv.ready ? "ready" : "starting") + (sv.offline ? "   OFFLINE" : "")
                        + "\nstate dir: " + sv.stateDir
                        + "\ncache dir: " + sv.cacheDir
                        + "\nconfig: " + sv.configPath
                        + "\nday: " + sv.day + "   pool unseen: " + sv.unseen("discover") + " discover / " + sv.unseen("deepen") + " deepen"
                        + "\nbatch: " + (b.running ? b.tab + " " + b.done + "/" + b.total : "idle")
                        + (b.blocked ? "   BLOCKED" : "") + "   last error: " + (sv.lastError || "none");
                }
            }

            TipGroup {
                title: "Data"
                blurb: "What the mock is showing (its scenario, entries, batch and clock; the rows here drive the mock only)."
            }
            TipRow {
                tip: "WikiMock puts both tabs in a named state. normal: a photo on Discover, the Arch relief on Deepen, a pool of 25 and 14 unseen. portrait: a portrait cropped around the upper third. cleaned: the longest pencil tip. generated: the sparkle and its tip, on a wide picture. noImage: the family glyph. empty: nothing to show. loading: the skeleton on both tabs. follow: a link followed at the start. pool5: five unseen per tab, the refill ask fires. offline: as normal, the service offline."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "scenario"
                }
                ComboBox {
                    objectName: "wikiRunScenario"
                    enabled: !win.live
                    Layout.preferredWidth: 130
                    model: mock.scenarios
                    currentIndex: mock.scenarios.indexOf(mock.scenario)
                    onActivated: win.applyScenario(currentText)
                }
                Button {
                    objectName: "wikiRunApplyAgain"
                    enabled: !win.live
                    text: "Apply again"
                    onClicked: win.applyScenario(mock.scenario)
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Which tab the card shows: what a two-finger swipe across the card does. The compact cards take the tab from their own Compact tab."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "tab"
                }
                Button {
                    objectName: "wikiRunTabDiscover"
                    text: "Discover"
                    highlighted: popup.tab === "discover"
                    onClicked: popup.showTab("discover")
                }
                Button {
                    objectName: "wikiRunTabDeepen"
                    text: "Deepen"
                    highlighted: popup.tab === "deepen"
                    onClicked: popup.showTab("deepen")
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Which veil an article with no photograph shows. 'by article' is the shell's rule: the pattern and its seed come from the article's id, so each article keeps its own. A pattern's name shows that one on every card, to look at it on any entry (scenario noImage has two entries with no picture; Systemd has a logo on a plate). Not saved: it is this window's only."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "veil"
                }
                ComboBox {
                    objectName: "wikiRunVeil"
                    Layout.fillWidth: true
                    model: ["by article", "contours", "links", "ripples", "maze", "cells"]
                    onActivated: i => win.veilOnly = i === 0 ? "" : model[i]
                }
            }
            TipRow {
                tip: "Put any of the eight hand-made entries on the current tab (mock.show): the way to see a long title, a portrait, a relief or a tips entry without picking the scenario for it."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "entry"
                }
                ComboBox {
                    id: entryBox
                    objectName: "wikiRunEntry"
                    enabled: !win.live
                    Layout.fillWidth: true
                    model: mock.entryIds[popup.tab]
                }
                Button {
                    objectName: "wikiRunShow"
                    enabled: !win.live
                    text: "Show"
                    onClicked: mock.show(popup.tab, entryBox.currentText)
                }
            }

            TipGroup {
                title: "Asks"
                blurb: "What the band's buttons and the paragraph's links tell the service, made from here on the card on show."
            }
            TipRow {
                tip: "next, more, less, knew and save on the current card, straight to the service -- the mock, or the real one while live, where save writes a real note and next marks the entry seen for good (the veil's own buttons latch after one click; these do not). In the mock next walks the tab's entries. The call log below shows each landing."
                Layout.fillWidth: true
                spacing: 6
                Button {
                    objectName: "wikiRunNext"
                    text: "next"
                    onClicked: win.svc.next(popup.tab)
                }
                Button {
                    objectName: "wikiRunMore"
                    text: "more"
                    onClicked: win.svc.more(popup.tab, popup.cardId)
                }
                Button {
                    objectName: "wikiRunLess"
                    text: "less"
                    onClicked: win.svc.less(popup.tab, popup.cardId)
                }
                Button {
                    objectName: "wikiRunKnew"
                    text: "knew"
                    onClicked: win.svc.knew(popup.tab, popup.cardId)
                }
                Button {
                    objectName: "wikiRunSave"
                    text: "save"
                    onClicked: win.svc.saveToNote(popup.tab, popup.cardId)
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Follow one of the current paragraph's links into the rabbit hole, as a Ctrl+click does: the card shows its skeleton, then the linked page (the chip appears at the hero's corner), then the model-written intro replaces the cleaned one. Back walks one step home."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "follow"
                }
                ComboBox {
                    id: linkBox
                    objectName: "wikiRunLink"
                    Layout.fillWidth: true
                    model: popup.card ? popup.card.introLinks.map(l => l.target) : []
                }
                Button {
                    objectName: "wikiRunFollow"
                    text: "Follow"
                    enabled: !!popup.card && popup.card.introLinks.length > 0
                    onClicked: win.svc.follow(popup.tab, popup.card.introLinks[Math.max(0, linkBox.currentIndex)])
                }
                Button {
                    objectName: "wikiRunBack"
                    text: "Back"
                    enabled: popup.canBack
                    onClicked: win.svc.back(popup.tab)
                }
            }
            TipRow {
                tip: "The On this day line follows its article the way a Ctrl+click on the tear-off's line does (mock.followOnThisDay): into the rabbit hole on Discover."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    objectName: "wikiRunOtd"
                    text: "Follow On this day"
                    onClicked: win.svc.followOnThisDay()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "A plain click on a link in the paragraph, and a click on the source logo, open the browser through the service. Off (the default) the mock only records the URL, which the state readout shows; on, it really opens it."
                Layout.fillWidth: true
                spacing: 8
                Switch {
                    objectName: "wikiRunOpenReal"
                    checked: win.openReal
                    onToggled: win.openReal = checked
                }
                Label {
                    text: "open links in the browser for real"
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Batch, time and the host"
                blurb: "What the shell around the card does."
            }
            TipRow {
                tip: "The MOCK's batch (off while live: a real one starts only from the refill notification's answer). Start the simulated batch (30 items, one every batch step; the finished batch adds 28 unseen entries and says batchFinished). It is what the refill notification starts in the shell."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    objectName: "wikiRunBatchDiscover"
                    enabled: !win.live
                    text: "Batch: Discover"
                    onClicked: mock.startBatch("discover")
                }
                Button {
                    objectName: "wikiRunBatchDeepen"
                    enabled: !win.live
                    text: "Batch: Deepen"
                    onClicked: mock.startBatch("deepen")
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The MOCK's clock (off while live: the service follows the wall). Pin the mock's clock one day on (nowMs + 24 h). The day key rolls at 04:00 local; the service picks a fresh entry for it and the On this day line changes with the date."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    objectName: "wikiRunDay"
                    enabled: !win.live
                    text: "Day rollover (+1 day)"
                    onClicked: mock.nowMs += 86400000
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "A cutout band along the card's top edge, as the engine hands a secondary that lies under its primary: the band is added to the implicit height, the card starts one padding past it, and naturalHeight stays the content's only."
                Layout.fillWidth: true
                spacing: 8
                Switch {
                    objectName: "wikiRunCutout"
                    checked: popup.secondaryCutout.height > 0
                    onToggled: popup.secondaryCutout = checked ? Qt.rect(0, 0, popup.cardWidth, 40) : Qt.rect(0, 0, 0, 0)
                }
                Label {
                    text: "cutout band, 40 px at the top"
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Toggle light and dark, the same shell-wide switch as the toolbar's (a snapshot crossfade). The palette is Theme's; nothing in the wiki module is a literal colour."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    objectName: "wikiRunTheme"
                    text: "Toggle light / dark"
                    onClicked: Theme.toggleMode()
                }
                Label {
                    text: Theme.mode
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "State"
                blurb: "What the card and the service believe right now."
            }
            Label {
                objectName: "wikiStateReadout"
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
                text: win.stateText()
            }

            TipGroup {
                title: "Calls"
                blurb: "The mock's record of every ask (the last ten, shown() folded into a count)."
            }
            Label {
                objectName: "wikiCallsReadout"
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
                text: win.callsText()
            }
        }
    ]

    // =====================================================================
    //  VALUES
    //
    // One array per component. `val` is this file's default for that
    // property (the component's own default, unless the file was saved with
    // other numbers): pushed into the target on load, restored by Reset,
    // compared against for the * marks, and rewritten by Save to mockup.
    // =====================================================================
    // WikiPopup's own frame.
    readonly property var frameParams: [
        {
            label: "card width",
            prop: "cardWidth",
            group: "Frame",
            blurb: "The popup's own geometry: what the card is sized from. The hero, the title row and the paragraph are all laid out at the width it leaves.",
            tip: "Width of the card without any cutout band. The hero is the card's inner width (this minus two paddings) at 16:9, so the whole height follows it: at the default 448 the hero is 238 px high. 448 is the width the module's contract fixes for the clock popup's secondary.",
            val: 448,
            from: 320,
            to: 640,
            step: 2
        },
        {
            label: "padding",
            prop: "padding",
            group: "Frame",
            tip: "Space between the card's edge and the hero, the title row and the paragraph, and the band at the foot where the tab dots live. 12 is the popup padding of the whole shell, so the space above equals the space below.",
            val: 12,
            from: 6,
            to: 24,
            step: 1
        },
        {
            label: "radius",
            prop: "radius",
            group: "Frame",
            tip: "Corner radius of the hero well and of the tab-title box that appears during a swipe. 14 is the shell's container radius: a box that meets a container's corner takes its curve.",
            val: 14,
            from: 6,
            to: 24,
            step: 1
        },
        {
            label: "font",
            prop: "fontFamily",
            group: "Frame",
            tip: "The face the card is set in. Inter is the module default; the user dresses mockups in Audiowide, which is wider and has no tabular figures, so titles and paragraphs re-wrap and the card's height follows. Type a family name.",
            val: "Inter",
            kind: "text"
        }
    ]

    // WikiVeilStyle: every number of the veils (what an article with no photograph shows).
    readonly property var veilParams: [
        {
            label: "fps",
            prop: "fps",
            group: "Clock",
            blurb: "One clock for whichever veil is on show: it runs only while the card is live, visible and the theme is not crossfading.",
            tip: "Frames a second while a veil is on show. Every tick is a frame of the whole bar window (two while the engine holds the card in its clip layer), and nothing in a veil moves more than a pixel or so a tick at 20, so more buys nothing you can see. A thumbnail never ticks.",
            val: 20,
            from: 5,
            to: 60,
            step: 1
        },
        {
            label: "speed",
            prop: "speed",
            group: "Clock",
            tip: "Veil seconds per second. 1 is the pace each pattern was tuned at (a contour line drifts about a pixel a second); 0 freezes every veil at its start, which is the thumbnail's picture.",
            val: 1,
            from: 0,
            to: 4,
            step: 0.05
        },
        {
            label: "relief",
            prop: "relief",
            group: "Material",
            blurb: "The one shading of all five veils: the card's own carve (floor, bevel, border, deep shadow), lit from above like a carved logo.",
            tip: "How strongly a slope is lit: at 1 a groove's steepest wall reaches the full shade. Lower flattens every veil toward the bare floor.",
            val: 1,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "lit gain",
            prop: "litGain",
            group: "Material",
            tip: "Strength of the wall that catches the light (the bevel tone).",
            val: 1,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "shadow gain",
            prop: "shadowGain",
            group: "Material",
            tip: "Strength of the shaded wall and of a cut's even shade.",
            val: 1,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "ambient",
            prop: "ambient",
            group: "Material",
            tip: "The share of a cut's shade that does not ask where the light is: it follows the depth alone. Without it a groove that runs along the light is not drawn at all; at 1 nothing is lit from anywhere.",
            val: 0.45,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "hue share",
            prop: "hueShare",
            group: "Material",
            tip: "How much of the family's hue is mixed into the DEEPEST shade only (a category's colour lives in the inset shadow). 0 is a veil with no colour at all.",
            val: 0.25,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "bevel lift",
            prop: "bevelLift",
            group: "Material",
            tip: "The lit wall's tone is the bevel carried this many times further from the floor: the bevel itself is a few levels off the floor, right for a rim and lost on a hairline.",
            val: 1.5,
            from: 0,
            to: 6,
            step: 0.1
        },
        {
            label: "bevel lift, dark",
            prop: "bevelLiftDark",
            group: "Material",
            tip: "... and this many times more on a dark floor (weighted by the floor's own lightness, no mode is read). A dark palette has no room under its surface, so there the lit walls carry the picture.",
            val: 2.5,
            from: 1,
            to: 8,
            step: 0.1
        },
        {
            label: "thumb zoom",
            prop: "thumbZoom",
            group: "Plate and thumb",
            blurb: "The small cards' still thumbnail, and the flat plate a subject's logo is carved on.",
            tip: "A thumbnail draws the middle of the article's picture at this scale (64 px of thumbnail at 0.6 show 107 px of the well).",
            val: 0.6,
            from: 0.3,
            to: 1,
            step: 0.05
        },
        {
            label: "plate fraction",
            prop: "plateFraction",
            group: "Plate and thumb",
            tip: "Radius of the flat plate under a subject's logo, as a share of the logo's size. 0.72 clears a square mark's corners.",
            val: 0.72,
            from: 0.5,
            to: 1.2,
            step: 0.02
        },
        {
            label: "plate fade",
            prop: "plateFade",
            group: "Plate and thumb",
            tip: "The px over which the pattern comes back outside the plate's ring.",
            val: 26,
            from: 0,
            to: 80,
            step: 2
        },
        {
            label: "wavelength",
            prop: "contourWave",
            group: "Contours",
            blurb: "The map of a country that is not there: engraved contour lines of a slow terrain over a faint hill shading.",
            tip: "The terrain's base wavelength in px: how large the hills are.",
            val: 190,
            from: 80,
            to: 400,
            step: 10
        },
        {
            label: "line spacing",
            prop: "contourSpacing",
            group: "Contours",
            tip: "Mean distance between two contour lines on an average slope.",
            val: 15,
            from: 6,
            to: 40,
            step: 1
        },
        {
            label: "line width",
            prop: "contourWidth",
            group: "Contours",
            tip: "Half-width of a contour's groove.",
            val: 2.2,
            from: 0.8,
            to: 5,
            step: 0.1
        },
        {
            label: "line depth",
            prop: "contourDepth",
            group: "Contours",
            tip: "How deep a contour is cut (with the width, it sets how steep its walls are).",
            val: 1.3,
            from: 0.2,
            to: 4,
            step: 0.1
        },
        {
            label: "warp",
            prop: "contourWarp",
            group: "Contours",
            tip: "How far the ground under the waves is bent, in px: 0 is four plane waves (regular), more is a more natural country.",
            val: 26,
            from: 0,
            to: 80,
            step: 2
        },
        {
            label: "hill shading",
            prop: "contourHill",
            group: "Contours",
            tip: "The terrain's own slope lit faintly under the lines, as a survey sheet shades its hills. 0 is lines alone.",
            val: 0.1,
            from: 0,
            to: 0.6,
            step: 0.02
        },
        {
            label: "heavy every",
            prop: "contourHeavy",
            group: "Contours",
            tip: "Every n-th contour is cut heavier (a map's index contour).",
            val: 5,
            from: 2,
            to: 10,
            step: 1
        },
        {
            label: "square",
            prop: "linkCell",
            group: "Links",
            blurb: "What a wiki is made of: wandering nodes, some joined by an engraved line that lets go when it is stretched.",
            tip: "One node lives in each square of this size.",
            val: 58,
            from: 30,
            to: 120,
            step: 2
        },
        {
            label: "line width",
            prop: "linkWidth",
            group: "Links",
            tip: "Half-width of a link's groove.",
            val: 1.8,
            from: 0.8,
            to: 4,
            step: 0.1
        },
        {
            label: "node radius",
            prop: "linkNode",
            group: "Links",
            tip: "Radius of a node's round well.",
            val: 4.5,
            from: 2,
            to: 10,
            step: 0.5
        },
        {
            label: "depth",
            prop: "linkDepth",
            group: "Links",
            tip: "How deep links and nodes are cut.",
            val: 1.2,
            from: 0.2,
            to: 4,
            step: 0.1
        },
        {
            label: "wander",
            prop: "linkWander",
            group: "Links",
            tip: "How far a node strays from its place, as a share of the square (under 0.3: a node stays in its own square).",
            val: 0.26,
            from: 0,
            to: 0.3,
            step: 0.01
        },
        {
            label: "joined share",
            prop: "linkShare",
            group: "Links",
            tip: "The share of neighbouring pairs that are joined at all.",
            val: 0.62,
            from: 0,
            to: 1,
            step: 0.02
        },
        {
            label: "wavelength",
            prop: "rippleWave",
            group: "Ripples",
            blurb: "Three slow wave sources and the pattern where their waves cross. No line is drawn: the surface rises and falls and the light does the rest.",
            tip: "Distance between two crests of the source in view.",
            val: 52,
            from: 20,
            to: 120,
            step: 2
        },
        {
            label: "height",
            prop: "rippleHeight",
            group: "Ripples",
            tip: "How high the waves stand: the picture's whole strength.",
            val: 4.5,
            from: 0.5,
            to: 12,
            step: 0.5
        },
        {
            label: "decay radius",
            prop: "rippleDecay",
            group: "Ripples",
            tip: "The distance over which a wave loses half its height.",
            val: 320,
            from: 60,
            to: 900,
            step: 20
        },
        {
            label: "crest",
            prop: "rippleCrest",
            group: "Ripples",
            tip: "Roundness of a crest: 0.05 is a sharp ridge, 0.5 a plain soft wave (which reads as a picture out of focus).",
            val: 0.14,
            from: 0.05,
            to: 0.5,
            step: 0.01
        },
        {
            label: "square",
            prop: "mazeCell",
            group: "Maze",
            blurb: "The one-line maze, engraved, with walls that swing: now and then one turns a quarter and a passage closes as another opens.",
            tip: "Side of one square of the maze; its wall runs corner to corner.",
            val: 30,
            from: 14,
            to: 64,
            step: 2
        },
        {
            label: "wall width",
            prop: "mazeWidth",
            group: "Maze",
            tip: "Half-width of a wall's groove.",
            val: 2.0,
            from: 0.8,
            to: 5,
            step: 0.1
        },
        {
            label: "wall depth",
            prop: "mazeDepth",
            group: "Maze",
            tip: "How deep a wall is cut.",
            val: 1.3,
            from: 0.2,
            to: 4,
            step: 0.1
        },
        {
            label: "swing",
            prop: "mazeSwingS",
            group: "Maze",
            tip: "Seconds one quarter turn takes.",
            val: 1.4,
            from: 0.3,
            to: 5,
            step: 0.1
        },
        {
            label: "turn every",
            prop: "mazeEveryS",
            group: "Maze",
            tip: "Mean seconds between two turns of ONE wall. With about a hundred walls in view, 120 is a turn somewhere a little under once a second.",
            val: 120,
            from: 20,
            to: 600,
            step: 10
        },
        {
            label: "square",
            prop: "cellSize",
            group: "Cells",
            blurb: "The floor cut into plateaus by seams, like dried clay or a pavement of cut stones, each drifting a little.",
            tip: "One plateau grows round a point in each square of this size.",
            val: 46,
            from: 20,
            to: 100,
            step: 2
        },
        {
            label: "shoulder",
            prop: "cellShoulder",
            group: "Cells",
            tip: "Width of a plateau's rounded edge.",
            val: 5,
            from: 1,
            to: 14,
            step: 0.5
        },
        {
            label: "seam",
            prop: "cellSeam",
            group: "Cells",
            tip: "Half-width of the flat seam between two plateaus.",
            val: 1.2,
            from: 0,
            to: 5,
            step: 0.1
        },
        {
            label: "height",
            prop: "cellHeight",
            group: "Cells",
            tip: "How high a plateau stands over its seam.",
            val: 2.2,
            from: 0.3,
            to: 6,
            step: 0.1
        },
        {
            label: "drift",
            prop: "cellDrift",
            group: "Cells",
            tip: "How far a plateau's point orbits, as a share of the square: the seams breathe by this much.",
            val: 0.16,
            from: 0,
            to: 0.3,
            step: 0.01
        },
        {
            label: "lean",
            prop: "cellLean",
            group: "Cells",
            tip: "Each plateau leans a little its own way, so the stones catch the light apart. 0 is flat tops.",
            val: 0.12,
            from: 0,
            to: 0.5,
            step: 0.01
        }
    ]

    // WikiStyle: every number of the card's look and motion.
    readonly property var styleParams: [
        {
            label: "hero ratio W",
            prop: "heroRatioW",
            group: "Column",
            blurb: "The vertical rhythm of the card: the hero's shape and the gaps between the three bands.",
            tip: "The hero's shape is W : H of the card's inner width, floored to a whole pixel (424 x 9/16 = 238 at the defaults). 16:9 is the shape the batch crops every picture to, so a photo is never re-cropped here.",
            val: 16,
            from: 1,
            to: 32,
            step: 1
        },
        {
            label: "hero ratio H",
            prop: "heroRatioH",
            group: "Column",
            tip: "The H of the hero's W : H (see hero ratio W). Raising it makes the hero taller and the whole card taller with it.",
            val: 9,
            from: 1,
            to: 32,
            step: 1
        },
        {
            label: "hero gap",
            prop: "heroGap",
            group: "Column",
            tip: "Space under the hero, before the title row. 12 is the popup padding, so this gap matches the one that surrounds the hero.",
            val: 12,
            from: 0,
            to: 32,
            step: 1
        },
        {
            label: "title gap",
            prop: "titleGap",
            group: "Column",
            tip: "Space between the title row and the paragraph. 8 keeps the title close enough to read as the paragraph's heading.",
            val: 8,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "empty intro lines",
            prop: "emptyIntroLines",
            group: "Column",
            tip: "What a tab with no entry reserves for its paragraph: the skeleton's lines and the empty text's slot. It makes a tab without an article size like one with one, so the popup does not resize when the first article lands.",
            val: 6,
            from: 1,
            to: 12,
            step: 1
        },
        {
            label: "presence",
            prop: "presenceMs",
            group: "Presence",
            blurb: "An entry's arrival and departure.",
            tip: "How long the entry (title row, paragraph, pictures) fades out while another is fetched and back in when it lands, and how long the skeleton takes to fade. 160 ms is the shell's presence fade: text swaps are instant, only presence fades.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "title size",
            prop: "titleSize",
            group: "Type",
            blurb: "Sizes and line heights. The line heights are fixed (FixedHeight), so a one-line and a two-line title differ by exactly one line.",
            tip: "Size of the title (bold). 16 is the shell's title size.",
            val: 16,
            from: 10,
            to: 28,
            step: 1
        },
        {
            label: "title line height",
            prop: "titleLineH",
            group: "Type",
            tip: "Fixed height of each of the title's (up to two) lines. The title row is as high as the taller of the logo and the title, and the tallest of both tabs sets the card's height.",
            val: 20,
            from: 12,
            to: 36,
            step: 1
        },
        {
            label: "body size",
            prop: "bodySize",
            group: "Type",
            tip: "Size of the paragraph. 13: one above the shell's body size (12), for reading -- the user's call (2026-11-08). The popup keeps its width and grows in height.",
            val: 13,
            from: 9,
            to: 18,
            step: 1
        },
        {
            label: "body line height",
            prop: "bodyLineH",
            group: "Type",
            tip: "Fixed height of each paragraph line. It is also the pitch of the skeleton's lines and the height of the mark's slot. 18 is about 1.4 x the body size, in whole pixels.",
            val: 18,
            from: 12,
            to: 28,
            step: 1
        },
        {
            label: "chip text size",
            prop: "chipTextSize",
            group: "Type",
            tip: "Size of the back chip's words and arrow. 11 is the shell's figure size.",
            val: 11,
            from: 8,
            to: 16,
            step: 1
        },
        {
            label: "logo size",
            prop: "logoSize",
            group: "Title row",
            blurb: "The row under the hero: the title, then the family glyph, an installed badge (Deepen) and the source logo, from the right edge inwards.",
            tip: "Size of the source logo at the row's end. The logo is the link to the article, carved as a relief; the carve is weak below about 24 px at 1x, so 28 keeps it legible. The skeleton's round mark follows it.",
            val: 28,
            from: 16,
            to: 48,
            step: 1
        },
        {
            label: "logo gap",
            prop: "logoGap",
            group: "Title row",
            tip: "Space between the title's right edge and the first icon. The title takes what the icons leave and wraps to two lines within it.",
            val: 12,
            from: 0,
            to: 32,
            step: 1
        },
        {
            label: "glyph size",
            prop: "glyphSize",
            group: "Title row",
            tip: "Size of the family's glyph (a Symbols Nerd Font mark in the family's hue). Its tip says why the article was picked.",
            val: 18,
            from: 10,
            to: 28,
            step: 1
        },
        {
            label: "glyph box",
            prop: "glyphBox",
            group: "Title row",
            tip: "The slot the family glyph is centred in, which is also its hover area.",
            val: 22,
            from: 12,
            to: 36,
            step: 1
        },
        {
            label: "badge size",
            prop: "badgeSize",
            group: "Title row",
            tip: "Size of the installed badge, shown on a Deepen entry whose package is installed. Its tip names the package.",
            val: 16,
            from: 10,
            to: 28,
            step: 1
        },
        {
            label: "badge box",
            prop: "badgeBox",
            group: "Title row",
            tip: "The slot the installed badge is centred in, which is also its hover area.",
            val: 20,
            from: 12,
            to: 32,
            step: 1
        },
        {
            label: "icon gap",
            prop: "iconGap",
            group: "Title row",
            tip: "Space between the icons: glyph, badge and logo.",
            val: 6,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "mark size",
            prop: "markSize",
            group: "Marks",
            blurb: "The mark at the paragraph's foot and the paragraph's links.",
            tip: "Size of the mark at the paragraph's foot: the sparkle on a model-written intro, the pencil on an edited one. An original intro carries none. Hover it for what it means.",
            val: 12,
            from: 8,
            to: 20,
            step: 1
        },
        {
            label: "mark box",
            prop: "markBox",
            group: "Marks",
            tip: "The room the last line keeps for the mark. The paragraph ends in non-breaking spaces this wide, which glue to the last word and wrap with it, so the mark never sits on a word and the measured block already includes it.",
            val: 16,
            from: 10,
            to: 32,
            step: 1
        },
        {
            label: "link fade",
            prop: "linkFadeMs",
            group: "Marks",
            tip: "How long the intro links' colour (one colour for all of them) takes to ease to its hover colour, and the mark's likewise. One fraction, so every link moves together.",
            val: 120,
            from: 0,
            to: 500,
            step: 10
        },
        {
            label: "wrap at",
            prop: "tipWrapChars",
            group: "Tips",
            blurb: "The tips over the marks, the glyph, the buttons and the picture.",
            tip: "The shared tip does not wrap, so a tip's words are broken into lines of at most this many characters. 72 turns the longest tip (the pencil's list of removed things) into a bubble of a few lines instead of one long one.",
            val: 72,
            from: 24,
            to: 120,
            step: 2
        },
        {
            label: "tip delay",
            prop: "tipDelayMs",
            group: "Tips",
            tip: "How long the pointer rests on a mark, glyph, badge, logo or band button before its tip shows. 350 ms is the delay of the panel's own tips.",
            val: 350,
            from: 0,
            to: 1500,
            step: 50
        },
        {
            label: "credit delay",
            prop: "creditDelayMs",
            group: "Tips",
            tip: "The picture's credit is a tip that comes after this long a rest over the picture. It is read once, not on every visit, and it gives way to the buttons' own tips while the pointer is on the veil.",
            val: 900,
            from: 0,
            to: 3000,
            step: 50
        },
        {
            label: "tip over picture",
            prop: "pictureTipOpacity",
            group: "Tips",
            tip: "Fill opacity of a tip that lies over the picture (a band button's, the credit's). The shared tip lets what is under it show through, which on a photograph is a reading problem, so these are nearly opaque.",
            val: 0.96,
            from: 0.5,
            to: 1,
            step: 0.02
        },
        {
            label: "well bevel",
            prop: "wellBevel",
            group: "Well",
            blurb: "The carved well the pictures sit in: cut into the surface like a container, with its inset shadow drawn over the picture so a photograph is sunk into the surface.",
            tip: "Width of the light bevel outside the hero well's carved edge. 1 is the containers' bevel.",
            val: 1,
            from: 0,
            to: 4,
            step: 0.5
        },
        {
            label: "well shadow",
            prop: "wellShadow",
            group: "Well",
            tip: "How far the inset shadow reaches into the well. 3 is the containers' shadow spread.",
            val: 3,
            from: 0,
            to: 10,
            step: 0.5
        },
        {
            label: "well falloff",
            prop: "wellFalloff",
            group: "Well",
            tip: "Shape of the inset shadow's fade: 1 is ShadowBox's own curve, higher is a longer soft tail.",
            val: 1,
            from: 0.2,
            to: 3,
            step: 0.1
        },
        {
            label: "well edge alpha",
            prop: "wellEdgeAlpha",
            group: "Well",
            tip: "How opaque the inset shadow is at the very edge over a picture. Over the bare floor the container's own shade is used, and over a photograph a deeper one: a light shadow on a light photograph is invisible.",
            val: 0.9,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "relief fraction",
            prop: "reliefFraction",
            group: "Well",
            tip: "Size of a subject's carved logo (systemd's mark on an ArchWiki page about it) as a fraction of the well's height, centred on its veil's flat plate.",
            val: 0.4,
            from: 0.1,
            to: 0.9,
            step: 0.05
        },
        {
            label: "band fade",
            prop: "bandFadeMs",
            group: "Band",
            blurb: "The band at the hero's foot whose buttons fade in while the pointer is on the hero (no tint over the picture: the buttons' shadows carry their contrast).",
            tip: "How long the band's buttons and the dots' strengthening take to fade in while the pointer is over the hero, and out when it leaves. One fraction drives all of them.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "band height",
            prop: "bandHeight",
            group: "Band",
            tip: "Height of the band. It is also the region where the picture's credit tip stays away (the buttons have tips of their own there); the pointer is tested against it by arithmetic, since a hover area stacked over the buttons would take their hover.",
            val: 52,
            from: 20,
            to: 120,
            step: 2
        },
        {
            label: "button width",
            prop: "buttonWidth",
            group: "Buttons",
            blurb: "The five raised buttons on the band. The shadow and bevel numbers also give the back chip its raise.",
            tip: "Width of a band button: more, less, knew (left) and save, next (right). They are raised, like every button in the shell.",
            val: 30,
            from: 20,
            to: 60,
            step: 1
        },
        {
            label: "button height",
            prop: "buttonHeight",
            group: "Buttons",
            tip: "Height of a band button. The dots are centred against it.",
            val: 26,
            from: 18,
            to: 48,
            step: 1
        },
        {
            label: "button gap",
            prop: "buttonGap",
            group: "Buttons",
            tip: "Space between neighbouring buttons in a group.",
            val: 6,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "button margin",
            prop: "buttonMargin",
            group: "Buttons",
            tip: "Distance of the button groups from the hero's edges (left, right and bottom). The dots are placed against the same margin.",
            val: 10,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "button radius",
            prop: "buttonRadius",
            group: "Buttons",
            tip: "Corner radius of a button.",
            val: 8,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "button shadow",
            prop: "buttonShadow",
            group: "Buttons",
            tip: "Spread of a button's drop shadow. 4 with a highlight of 1.5 is the shell's button raise; the shadow fades to alpha because the buttons stand over a picture, not over a fixed ground.",
            val: 4,
            from: 0,
            to: 10,
            step: 0.5
        },
        {
            label: "button bevel",
            prop: "buttonBevel",
            group: "Buttons",
            tip: "Spread of a button's highlight, inside its top edge.",
            val: 1.5,
            from: 0,
            to: 4,
            step: 0.5
        },
        {
            label: "button glyph size",
            prop: "buttonGlyphSize",
            group: "Buttons",
            tip: "Size of the glyph on a button (Symbols Nerd Font).",
            val: 12,
            from: 8,
            to: 22,
            step: 1
        },
        {
            label: "latch",
            prop: "latchMs",
            group: "Buttons",
            tip: "How long a button takes to take the accent once its choice is made (more, less, knew are told to the service once per entry; save holds it once the note is written), and how long a dot takes to take it when it becomes the current picture.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "dot size",
            prop: "dotSize",
            group: "Dots",
            blurb: "The carousel's dots, between the two button groups. Faint at rest behind a small pill; the pointer over the hero brings them to full strength.",
            tip: "Diameter of a carousel dot. They exist only when an entry has two or more pictures. The current one is the accent, the rest the muted text colour.",
            val: 6,
            from: 3,
            to: 12,
            step: 1
        },
        {
            label: "dot pitch",
            prop: "dotPitch",
            group: "Dots",
            tip: "Distance between dot centres, and the width of a dot's clickable box.",
            val: 12,
            from: 6,
            to: 30,
            step: 1
        },
        {
            label: "pill padding",
            prop: "dotPillPad",
            group: "Dots",
            tip: "How far the faint pill behind the dots reaches around them. The pill lets the dots read on any picture while the band is down, and fades out as the bail comes up.",
            val: 7,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "pill alpha",
            prop: "dotPillAlpha",
            group: "Dots",
            tip: "Opacity of the pill (the surface colour) at rest.",
            val: 0.55,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "rest opacity",
            prop: "dotRestOpacity",
            group: "Dots",
            tip: "How strong the dots are at rest, before the pointer arrives; the pointer over the hero raises them to full. 0.75 keeps them there without asking for attention.",
            val: 0.75,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "dot hit",
            prop: "dotHit",
            group: "Dots",
            tip: "Height of a dot's clickable box across the row, so a dot can be hit without aiming at 6 px.",
            val: 20,
            from: 8,
            to: 40,
            step: 1
        },
        {
            label: "chip height",
            prop: "chipHeight",
            group: "Chip",
            blurb: "The way home from a rabbit hole.",
            tip: "Height of the back chip, the raised '< Parent title' at the hero's top-left that appears only while there is a trail. A click walks one step back.",
            val: 26,
            from: 18,
            to: 44,
            step: 1
        },
        {
            label: "chip margin",
            prop: "chipMargin",
            group: "Chip",
            tip: "Distance of the chip from the hero's top and left edges.",
            val: 10,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "chip padding",
            prop: "chipPad",
            group: "Chip",
            tip: "Space inside the chip at each end.",
            val: 10,
            from: 4,
            to: 20,
            step: 1
        },
        {
            label: "chip gap",
            prop: "chipGap",
            group: "Chip",
            tip: "Space between the chip's arrow and the parent's title.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "chip max width",
            prop: "chipMaxWidth",
            group: "Chip",
            tip: "The chip is as wide as its words up to this, then the title is elided.",
            val: 240,
            from: 80,
            to: 400,
            step: 10
        },
        {
            label: "chip radius",
            prop: "chipRadius",
            group: "Chip",
            tip: "Corner radius of the chip. 8 matches the buttons.",
            val: 8,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "chip fade",
            prop: "chipFadeMs",
            group: "Chip",
            tip: "How long the chip takes to appear when a link is followed and to leave when it is walked back. The title it shows is held through the fade-out.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "pulse",
            prop: "skeletonPulse",
            group: "Skeleton",
            blurb: "The card while an entry is on its way: a block in the hero, two bars for the title and the paragraph's lines, on the same rectangles the real parts take, so the entry resolves in place.",
            tip: "Whether the skeleton's bars breathe (on geometry, never on a colour, on one shared clock). Off, the skeleton is one still picture, which is what a render or a fidelity grab wants. It also holds still while the theme crossfades.",
            val: true
        },
        {
            label: "bar height",
            prop: "skeletonBarHeight",
            group: "Skeleton",
            tip: "Height of a paragraph line's bar (the line pitch is the body line height).",
            val: 9,
            from: 4,
            to: 16,
            step: 1
        },
        {
            label: "title bar height",
            prop: "skeletonTitleBarHeight",
            group: "Skeleton",
            tip: "Height of each of the two title bars.",
            val: 10,
            from: 4,
            to: 18,
            step: 1
        },
        {
            label: "bar gap",
            prop: "skeletonBarGap",
            group: "Skeleton",
            tip: "Space between the two title bars.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "hero inset",
            prop: "skeletonHeroInset",
            group: "Skeleton",
            tip: "How far the hero's block sits inside the well's carve.",
            val: 8,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "hero radius",
            prop: "skeletonHeroRadius",
            group: "Skeleton",
            tip: "Corner radius of the hero's block.",
            val: 8,
            from: 0,
            to: 24,
            step: 1
        }
    ]

    // WikiPopup's timers, reporting, gesture and what a host tells it.
    readonly property var behaviourParams: [
        {
            label: "auto-advance",
            prop: "autoAdvanceMs",
            group: "Carousel",
            blurb: "The picture carousel in the hero.",
            tip: "How long a picture stays before the carousel slides to the next one (only an entry with two or more pictures has anything to advance to). It holds while the pointer is over the hero, while the secondary moves, while an entry loads and while the theme crossfades. 7 s is the plan's pace: long enough to look, short enough to notice there is more.",
            val: 7000,
            from: 1000,
            to: 20000,
            step: 250
        },
        {
            label: "slide",
            prop: "slideMs",
            group: "Carousel",
            tip: "Length of one slide: the outgoing picture leaves as the incoming one arrives, on one eased clock (OutCubic). 260 ms is the shell's resize ease.",
            val: 260,
            from: 60,
            to: 800,
            step: 10
        },
        {
            label: "report every",
            prop: "reportMs",
            group: "Reporting",
            blurb: "What the card tells the service about how long it was looked at (the pointer's dwell is wiki.jsonc's dwellMs).",
            tip: "How often service.shown(tab, id, cumulativeMs) is called while the card is on screen (visible, not moving, the window active, an entry showing). The service marks an entry seen once the cumulative time reaches its seen threshold (3 s). 1 s is the contract's rate: a timer that runs only then, so a hidden card ticks nothing.",
            val: 1000,
            from: 100,
            to: 5000,
            step: 100
        },
        {
            label: "gesture idle end",
            prop: "gestureIdleEndMs",
            group: "Gesture",
            blurb: "The two-finger swipe that switches tabs: which axis it is read on, how a touchpad's pixels are counted, and the detent that turns wheel units into a step.",
            tip: "How long without a wheel event ends a swipe when no zero-delta 'fingers lifted' event arrives. A touchpad sends that event and ends the gesture at once; a mouse never does, so this is what releases the gesture (and the hold the host keeps for it) after a mouse's tilt notch. 260 ms is a little over one notch repeat.",
            val: 260,
            from: 100,
            to: 1000,
            step: 10
        },
        {
            label: "pixel to angle",
            prop: "swipePixelToAngle",
            group: "Gesture",
            tip: "A wheel event that carries only a pixel delta is converted to wheel units at this factor before it reaches the detent (gestures.md's factor). Higher makes a touchpad step sooner.",
            val: 2.5,
            from: 1,
            to: 6,
            step: 0.1
        },
        {
            label: "axis lead",
            prop: "axisLead",
            group: "Gesture",
            tip: "How far one axis must lead the other, at a motion's first clear read, before the motion is taken as a sideways swipe (this card's) or a vertical scroll (left to whoever is under it). Two fingers are never one axis, so the lead is what keeps a vertical scroll's drift from switching tabs. The axis is then kept until the fingers lift.",
            val: 1.2,
            from: 1,
            to: 3,
            step: 0.05
        },
        {
            label: "notch threshold",
            prop: "notchThreshold",
            group: "Gesture",
            tip: "Wheel units that make one step for a mouse notch (an event with a whole notch of angle and no pixel delta): 120 is exactly one notch, so one notch is one tab. Above 120 a notch alone steps nothing. It is CardViewCycler's own number, read by its WheelStepper.",
            val: 120,
            from: 30,
            to: 480,
            step: 10
        },
        {
            label: "touchpad threshold",
            prop: "pixelThreshold",
            group: "Gesture",
            tip: "Wheel units that make one step for a touchpad: any event that carries a pixel delta (Wayland sends angle deltas too, so a stream of small ones must not count against the notch). 1000 is the view switcher's detent: a finger drift of a few millimetres is about 120 units, a real swipe thousands, and 60 events of 40 units make one tab.",
            val: 1000,
            from: 200,
            to: 3000,
            step: 50
        },
        {
            label: "step cooldown",
            prop: "stepCooldownMs",
            group: "Gesture",
            tip: "After a step the wheel is not read for this long and what it carries is dropped, so a fast flick moves one tab per pause instead of racing round (with two tabs a double step would land back where it started). 200 ms is the detent's own pause.",
            val: 200,
            from: 0,
            to: 800,
            step: 10
        },
        {
            label: "window active",
            prop: "windowActive",
            group: "Host contract",
            blurb: "What the engine (or any host) says about the card. In the bar these are driven by the engine; here you can put them by hand.",
            tip: "What a host that knows the shell is idle or locked tells the card. Off, nothing is reported: no seen time counts and no hover dwell fires, exactly as when the popup is hidden.",
            val: true
        },
        {
            label: "secondary moving",
            prop: "secondaryMoving",
            group: "Host contract",
            tip: "The engine says the secondary is opening, closing or travelling. The carousel holds and nothing is reported until it lands, so a picture never slides under a moving edge.",
            val: false
        }
    ]

    // WikiMock's own timing knobs (the Data tab).
    readonly property var mockParams: [
        {
            label: "follow delay",
            prop: "followDelayMs",
            group: "Rabbit hole",
            blurb: "What following a link in the paragraph (Ctrl+click) does in the mock.",
            tip: "How long a followed link takes to arrive. Until it does, the card shows its skeleton in place (the trail's chip appears when the page lands). The real tool takes a network round trip; 700 ms is long enough to look at the loading state without waiting.",
            val: 700,
            from: 0,
            to: 5000,
            step: 50
        },
        {
            label: "written intro delay",
            prop: "upgradeDelayMs",
            group: "Rabbit hole",
            tip: "After a followed page has landed with its cleaned paragraph, how long before the model-written intro replaces it (the sparkle mark). The real tool writes it in the background when the GPU is free; 1400 ms shows the swap without a long wait.",
            val: 1400,
            from: 0,
            to: 10000,
            step: 100
        },
        {
            label: "hold the page",
            prop: "followHold",
            group: "Rabbit hole",
            tip: "The followed page never arrives: the loading state stays on show, so the skeleton, the hero and the trail can be looked at for as long as needed. Switch it off and follow again to let the page land.",
            val: false
        },
        {
            label: "save answers after",
            prop: "answerMs",
            group: "Save",
            blurb: "The band's save button.",
            tip: "How long the mock takes to answer save-to-note. The save button holds the accent once the answer has landed and its tip then names the note.",
            val: 300,
            from: 0,
            to: 3000,
            step: 50
        },
        {
            label: "batch step",
            prop: "batchStepMs",
            group: "Batch",
            blurb: "The mock's batch (what the refill notification starts in the shell).",
            tip: "How long one item of a simulated batch takes (30 items; the finished batch adds 28 unseen entries). Start one from the Run buttons and read the batch line in the state readout.",
            val: 350,
            from: 50,
            to: 2000,
            step: 50
        },
        {
            label: "seen after",
            prop: "seenMs",
            group: "Seen",
            blurb: "When an entry counts as seen.",
            tip: "How much cumulative time READ in the wiki detail makes the mock mark an entry seen (a compact card on screen never does). The service's own threshold is 5 s; lower it to watch next() walk through the pool without waiting.",
            val: 5000,
            from: 500,
            to: 10000,
            step: 250
        }
    ]

    // WikiCompactCard, tear-off.
    readonly property var tearoffParams: [
        {
            label: "tab",
            prop: "tab",
            group: "Tear-off",
            blurb: "(Scene compact on the Run tab shows it.) The tear-off on the clock popup's calendar panel: a 194 px card (the panel's inner width) with the article's thumbnail, title, category glyph and, under them, one On this day line that is its own link. It stands on the calendar panel's fill.",
            tip: "Which tab's article the card shows: discover or deepen. Anything else shows nothing (an empty card).",
            val: "discover",
            kind: "text"
        },
        {
            label: "padding",
            prop: "padding",
            group: "Tear-off",
            tip: "The card's inset all round. The heights the contract fixes (tear-off 106, wide 84, lock 92) hold at 10: the height is two paddings plus the thumb (64, the lock's 72) plus, in the tear-off, the 8 px row gap and one 11 px line. ",
            val: 10,
            from: 4,
            to: 20,
            step: 1
        },
        {
            label: "radius",
            prop: "radius",
            group: "Tear-off",
            tip: "Corner radius of the carved card. The thumb keeps its own radius of 8, one padding in from the card's curve.",
            val: 12,
            from: 4,
            to: 20,
            step: 1
        },
        {
            label: "render scale",
            prop: "renderScale",
            group: "Tear-off",
            tip: "Device pixels per pixel of the host: the thumb is decoded at max(192, 2 x 64 x this) px, so it stays sharp on a magnified host. The mockup's zoom is a render transform and does not change it; set it to the zoom to see the sharper decode.",
            val: 1,
            from: 0.5,
            to: 4,
            step: 0.25
        },
        {
            label: "active",
            prop: "active",
            group: "Tear-off",
            tip: "Gates the card's only motion: the 160 ms fade of a landing card and of the on-this-day line, and the skeleton's breath. Off, everything shows at once and the skeleton stands still. It is also the default of `attended`, which is what counts the card toward seen: a card that is not active reports nothing.",
            val: true
        },
        {
            label: "collapse if empty",
            prop: "collapseWhenEmpty",
            group: "Tear-off",
            tip: "With nothing to show, take no room at all (height 0, face hidden) instead of a quiet 'No article yet' at full size. The lock screen's row uses it, so an empty pool does not leave a hole. Try it with the empty scenario.",
            val: false
        },
        {
            label: "font",
            prop: "fontFamily",
            group: "Tear-off",
            tip: "The face the card is set in. Inter is the module default. Heights are Inter's: the tear-off's line and the wide card's lines are measured from the face, so another family moves them by a pixel or two.",
            val: "Inter",
            kind: "text"
        }
    ]

    // WikiCompactCard, wide.
    readonly property var wideParams: [
        {
            label: "tab",
            prop: "tab",
            group: "Wide",
            blurb: "The wide card of the notification manager's empty state: 396 px, the same content on one row with the line under the title and the glyph at the end of the title's first line. It stands on the popup's surface.",
            tip: "Which tab's article the card shows: discover or deepen. Anything else shows nothing (an empty card).",
            val: "discover",
            kind: "text"
        },
        {
            label: "padding",
            prop: "padding",
            group: "Wide",
            tip: "The card's inset all round. The heights the contract fixes (tear-off 106, wide 84, lock 92) hold at 10: the height is two paddings plus the thumb (64, the lock's 72) plus, in the tear-off, the 8 px row gap and one 11 px line. Wide is 84 high: 2 x 10 + 64.",
            val: 10,
            from: 4,
            to: 20,
            step: 1
        },
        {
            label: "radius",
            prop: "radius",
            group: "Wide",
            tip: "Corner radius of the carved card. The thumb keeps its own radius of 8, one padding in from the card's curve.",
            val: 12,
            from: 4,
            to: 20,
            step: 1
        },
        {
            label: "render scale",
            prop: "renderScale",
            group: "Wide",
            tip: "Device pixels per pixel of the host: the thumb is decoded at max(192, 2 x 64 x this) px, so it stays sharp on a magnified host. The mockup's zoom is a render transform and does not change it; set it to the zoom to see the sharper decode.",
            val: 1,
            from: 0.5,
            to: 4,
            step: 0.25
        },
        {
            label: "active",
            prop: "active",
            group: "Wide",
            tip: "Gates the card's only motion: the 160 ms fade of a landing card and of the on-this-day line, and the skeleton's breath. Off, everything shows at once and the skeleton stands still. It is also the default of `attended`, which is what counts the card toward seen: a card that is not active reports nothing.",
            val: true
        },
        {
            label: "collapse if empty",
            prop: "collapseWhenEmpty",
            group: "Wide",
            tip: "With nothing to show, take no room at all (height 0, face hidden) instead of a quiet 'No article yet' at full size. The lock screen's row uses it, so an empty pool does not leave a hole. Try it with the empty scenario.",
            val: false
        },
        {
            label: "font",
            prop: "fontFamily",
            group: "Wide",
            tip: "The face the card is set in. Inter is the module default. Heights are Inter's: the tear-off's line and the wide card's lines are measured from the face, so another family moves them by a pixel or two.",
            val: "Inter",
            kind: "text"
        }
    ]

    // WikiCompactCard, lock.
    readonly property var lockParams: [
        {
            label: "padding",
            prop: "padding",
            group: "Lock",
            blurb: "The lock screen's row, 440 x 92: public, so no hover, no click, no tip, no why-text, no installed badge, and always Discover. It stands on the lock band's list-box fill.",
            tip: "The card's inset all round. The heights the contract fixes (tear-off 106, wide 84, lock 92) hold at 10: the height is two paddings plus the thumb (64, the lock's 72) plus, in the tear-off, the 8 px row gap and one 11 px line. The lock row is 92 high: 2 x 10 + 72.",
            val: 10,
            from: 4,
            to: 20,
            step: 1
        },
        {
            label: "radius",
            prop: "radius",
            group: "Lock",
            tip: "Corner radius of the carved card. The thumb keeps its own radius of 8, one padding in from the card's curve.",
            val: 12,
            from: 4,
            to: 20,
            step: 1
        },
        {
            label: "render scale",
            prop: "renderScale",
            group: "Lock",
            tip: "Device pixels per pixel of the host: the thumb is decoded at max(192, 2 x 72 x this) px, so it stays sharp on a magnified host. The mockup's zoom is a render transform and does not change it; set it to the zoom to see the sharper decode.",
            val: 1,
            from: 0.5,
            to: 4,
            step: 0.25
        },
        {
            label: "active",
            prop: "active",
            group: "Lock",
            tip: "Gates the card's only motion: the 160 ms fade of a landing card and of the on-this-day line, and the skeleton's breath. Off, everything shows at once and the skeleton stands still. It is also the default of `attended`, which is what counts the card toward seen: a card that is not active reports nothing.",
            val: true
        },
        {
            label: "collapse if empty",
            prop: "collapseWhenEmpty",
            group: "Lock",
            tip: "With nothing to show, take no room at all (height 0, face hidden) instead of a quiet 'No article yet' at full size. The lock screen's row uses it, so an empty pool does not leave a hole. Try it with the empty scenario.",
            val: false
        },
        {
            label: "font",
            prop: "fontFamily",
            group: "Lock",
            tip: "The face the card is set in. Inter is the module default. Heights are Inter's: the tear-off's line and the wide card's lines are measured from the face, so another family moves them by a pixel or two.",
            val: "Inter",
            kind: "text"
        }
    ]

    // WikiTeaser.
    readonly property var teaserParams: [
        {
            label: "active",
            prop: "active",
            group: "Teaser",
            blurb: "The line at the launcher's foot: '<glyph> Today: <title>', 18 px high whenever there is a service (card or not), so typing never resizes the popup. The whole line is the link. It stands on the launcher popup's surface.",
            tip: "Gates the teaser's one motion, the 160 ms fade of a card that lands. Off, it shows at once.",
            val: true
        },
        {
            label: "font",
            prop: "fontFamily",
            group: "Teaser",
            tip: "The face the line is set in. Inter is the module default.",
            val: "Inter",
            kind: "text"
        }
    ]
}
