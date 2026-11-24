//@ pragma IconTheme Papirus
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

import "modules/common/mockup"
import "modules/common/system"
import "modules/common/theme"
import "modules/common/components"
import "modules/common/components/JsonComments.js" as JsonComments
import "modules/bar/gooey"
import "modules/notifications"
import "modules/notifications/parts"
import "modules/notifications/data"
import "modules/notifications/data/NotifyPolicy.js" as Policy
import "modules/notifications/sources"
import "modules/notifications/sources/SuddenMove.js" as Sudden
import "modules/notifications/sources/SourceGlyphs.js" as SourceGlyphs

// =============================================================================
// mockups/notifications.qml -- the notifications module on the REAL bar engine.
//
// RUN IT ONLY THROUGH tools/dev/notifications_mockup.sh (`run` on the desktop,
// `smoke`, `grab`): a private session bus and PRIVATE XDG dirs, so no run
// writes the user's history, theme state or notifications.jsonc. The Config
// tab WRITES notifications.jsonc -- the private one: it refuses whenever
// XDG_CONFIG_HOME is unset or is the user's own ~/.config.
//
// A 1:1 slice of the screen: a GooeyEngine with a top bar carrying the bell
// (NotificationsBarButton) and a stand-in module button whose popup the toasts
// meet; the manager opens as thePopup from the bell; the toast stack shows
//
//   LANE=stage   on a plain surface
//                hung under the top-right corner -- the drop-in on its own,
//                sized by its implicit size, the stage's 260 ms ease; it
//                closes (eases to nothing) on the frame the scheduler's
//                `shown` empties, as the owner closes the lane;
//   LANE=popup   as thePopup itself, grown 2D out of the corner (so the
//                manager and the toasts cannot both be up: a mockup compromise);
//   LANE=lane    (the default) in the engine's own lane (theNotification),
//                melting beside any thePopup it meets.
//
// THE SENDER. By default the service owns org.freedesktop.Notifications on a
// PRIVATE bus (tools/dev/notifications_mockup.sh starts the mockup under
// tools/dev/notifications_bus.sh) and the Run page sends its fixtures through
// tools/notifications/notify_client.py, exactly as an app would. INPROC=1 skips the bus:
// fixtures are FakeNotifications handed to `service.receive()`. LIVE=1 arms
// the real session bus behind a confirmation: tools/notifications/claim_name.sh
// stops mako (only mako) and the service takes the name, so real apps land
// here until the mockup quits (mako is D-Bus-activated again afterwards).
//
// THE PANEL. Every look and motion value is NotificationStyle's (one object,
// the owner hands it to the toast and the manager, they to every card, header,
// reader, fade and the bell), type and the countdown shade included; the
// popups' corner radius is the engine's `maxR` (Host); the group colours are
// the style's GroupPalette (Colours: a light and a dark row per group --
// "@<token>" follows the theme, the palette's own default; a hex overrides
// the group in that theme alone; Reset puts the token back); what the module DOES is notifications.jsonc (Config, every key:
// timeouts, toasts, history, images, holds, sounds, the app and source rules,
// the spot): the panel keeps the private file in step with its knobs -- only
// the keys the panel changed, merged over what the file held -- and the
// service hot-reloads it. The Config lists are FILE-BACKED (fileBackedLists):
// the file keeps them across runs, so Save to mockup leaves them out and their
// val: stays the code's default (R2E P1.2).
//
// SAVE AND PROFILES land in the real tree: tools/dev/notifications_mockup.sh runs
// this from a sandbox copy, and tools/dev/sandbox.sh hands the framework the real
// one (MOCKUP_REPO).
//
// Holds are driven by hand here (liveSignals false): the Run page toggles
// do-not-disturb, fullscreen, a screen share, the lock and idleness.
//
// The shell's icon theme: `//@ pragma IconTheme Papirus` (line 1), the
// launcher's theme -- without it the session resolves hicolor only
// (R2B-T finding 2). The assembled shell.qml should carry the same pragma.
//
// Env: LANE=stage|popup|lane  INPROC=1  LIVE=1  OPEN=manager  SEND=<fixture ids,...>
//      ACT="<verb>[:arg]@ms,..." (scripted steps, see act())
//      MOCKUP_REPO=<the real config> (tools/dev/sandbox.sh sets it: where saves go)
//      STAGE_GRAB=<png> GRAB_MS=<ms>  ZOOM
// =============================================================================
MockupWindow {
    id: win

    moduleId: "notifications"
    title: "Notifications"
    stageLabel: "A section of the screen at 1:1 -- a top bar, the bell, thePopup and the toast stack (" + win.laneMode + ")"
    content: scene
    target: style
    targets: ({
            hostParams: engine,
            bellFlourish: bell,
            groupColors: style.groups,
            serviceParams: svc,
            toastParams: svc.toasts,
            configParams: cfgKnobs
        })
    fileBackedLists: ({
            configParams: "notifications.jsonc"
        })
    stageColor: "#1F2229"
    zoom: Number(Quickshell.env("ZOOM") || 0.8)
    panelWidth: 460
    // The scene is a 1280 px slice of the screen: the default window left the
    // manager's right end (Clear all) under the panel (R2E I10.4).
    fitContent: true

    readonly property string laneMode: {
        const l = Quickshell.env("LANE") || "lane";
        return ["stage", "popup", "lane"].indexOf(l) >= 0 ? l : "lane";
    }
    readonly property bool inproc: (Quickshell.env("INPROC") || "") === "1"
    property bool armedLive: (Quickshell.env("LIVE") || "") === "1"
    property bool live: false

    lists: ({
            styleCard: win.styleCard,
            styleParams: win.styleParams,
            styleManager: win.styleManager,
            styleSwipe: win.styleSwipe,
            styleBell: win.styleBell,
            bellFlourish: win.bellFlourish,
            hostParams: win.hostParams,
            groupColors: win.groupColors,
            serviceParams: win.serviceParams,
            toastParams: win.toastParams,
            configParams: win.configParams
        })

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Card",
            subs: [
                { name: "Layout", lists: ["styleCard"], groups: ["Card", "Icon", "Text"] },
                { name: "Type", lists: ["styleCard"], groups: ["Type"] },
                { name: "Carve, countdown", lists: ["styleCard"], groups: ["Carve", "Countdown"] },
                { name: "Inside", lists: ["styleCard", "serviceParams"], groups: ["Inside", "Actions"] }
            ]
        },
        {
            name: "Toast",
            lists: ["styleParams", "toastParams"]
        },
        {
            name: "Manager",
            subs: [
                { name: "Layout", lists: ["styleManager"], groups: ["Layout"] },
                { name: "Title row", lists: ["styleManager"], groups: ["Title row"] },
                { name: "Headers", lists: ["styleManager"], groups: ["Group header"] },
                { name: "List", lists: ["styleManager"], groups: ["List", "Highlight"] },
                { name: "Motion", lists: ["styleManager"], groups: ["Motion"] },
                { name: "Pin flight", lists: ["styleManager"], groups: ["Pin flight"] }
            ]
        },
        {
            name: "Swipe",
            subs: [
                { name: "Card", lists: ["styleSwipe"], groups: ["Commit", "Motion", "Look"] },
                { name: "Fingers", lists: ["styleSwipe"], groups: ["Fingers"] },
                { name: "Side fades", lists: ["styleSwipe"], groups: ["Side fades"] }
            ]
        },
        {
            name: "Colours",
            lists: ["groupColors"]
        },
        {
            name: "Bell",
            lists: ["styleBell", "bellFlourish"]
        },
        {
            name: "Config",
            subs: [
                { name: "Timeouts", lists: ["configParams"], groups: ["Timeouts"] },
                { name: "Toasts", lists: ["configParams"], groups: ["Toasts"] },
                { name: "History", lists: ["configParams"], groups: ["History", "Away"] },
                { name: "Holds, spot", lists: ["configParams"], groups: ["Holds", "Spot"] },
                { name: "Sounds, rules", lists: ["configParams"], groups: ["Sounds", "Rules"] }
            ],
            page: configPage
        },
        {
            name: "Host",
            lists: ["hostParams"]
        }
    ]

    // ---- the service, the icons, the clock ------------------------------------------
    NotificationService {
        id: svc
        serverEnabled: !win.inproc
        liveSignals: false
    }
    // The shell's one sleep watcher is the Sleep singleton's (every
    // BoundaryClock's default). The relative times it drives are read only
    // while a card is on screen -- the manager, the toasts in the popup, the
    // lane or the stage -- so it runs only then: a hidden reader wakes for
    // nothing (R2E B4.2).
    BoundaryClock {
        id: clock
        active: owner.popupMine || owner.laneMine || stageHost.visible
    }
    // The look, handed to the owner; the panel writes into it.
    NotificationStyle {
        id: style
    }

    // What a probe needs of the scene (test_notifications_panel_probe.qml).
    readonly property var refs: ({
            svc: svc,
            engine: engine,
            owner: owner,
            clock: clock,
            style: style,
            knobs: cfgKnobs,
            bell: bell,
            stageHost: stageHost,
            stageLoader: stageLoader
        })

    // =====================================================================
    //  THE STAGE
    // =====================================================================
    Item {
        id: scene
        implicitWidth: 1280
        implicitHeight: 760

        Rectangle {
            anchors.fill: parent
            color: win.stageColor
        }

        GooeyEngine {
            id: engine
            anchors.fill: parent
            renderScale: win.stage ? win.stage.zoom : 1
            surfaceColor: Theme.surface
            barsList: [topBar, rightBar]

            GooeyBar {
                id: topBar
                engine: engine
                barId: "top"
                edge: "top"
                rawPos: 0
                rawLen: engine.w

                NotificationsBarButton {
                    id: bell
                    objectName: "notificationsBell"
                    x: Math.round(1000 - width / 2)
                    y: Math.round((topBar.height - height) / 2)
                    owner: owner
                }
                // A stand-in for any other module: its popup is what the
                // toasts meet (and melt beside, in the lane).
                Rectangle {
                    id: otherBtn
                    objectName: "otherButton"
                    width: 64
                    height: 22
                    radius: 6
                    x: Math.round(1150 - width / 2)
                    y: Math.round((topBar.height - height) / 2)
                    color: otherArea.containsMouse ? Theme.panelSunk : "transparent"
                    Text {
                        anchors.centerIn: parent
                        text: "module"
                        color: Theme.textMuted
                        font.family: owner.style.fontFamily
                        font.pixelSize: 11
                    }
                    MouseArea {
                        id: otherArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: engine.toggle("other", "top", 1150, null, null, false, otherComp, 0.5)
                    }
                }
            }
            GooeyBar {
                id: rightBar
                engine: engine
                barId: "right"
                edge: "right"
                rawPos: 0
                rawLen: engine.h * 0.55
            }
        }

        NotificationsBarOwner {
            id: owner
            engine: engine
            bar: topBar
            barId: "top"
            anchorItem: bell
            screenName: svc.laneScreen
            service: svc
            clock: clock
            style: style
            useLane: win.laneMode === "lane"
        }

        // ---- LANE=stage: the toast stack on a plain surface under the corner ----
        // It follows the owner's rule: open while the scheduler shows toasts
        // (and the manager is shut), and it CLOSES on the frame `shown`
        // empties -- the box eases to nothing over the stack's held height
        // while the last rows play their exits inside it (NotificationToast,
        // GOING EMPTY). It used to wait for the stack to report empty, and
        // then vanished at full height (R2B-T finding 6).
        Item {
            id: stageHost
            readonly property bool open: win.laneMode === "stage" && svc.toasts.shown.length > 0 && !svc.managerOpen
            readonly property var toast: stageLoader.item
            property real w: stageHost.toast ? stageHost.toast.implicitWidth : 0
            property real h: stageHost.open && stageHost.toast ? stageHost.toast.implicitHeight : 0
            Behavior on w {
                NumberAnimation {
                    duration: 260
                    easing.type: Easing.OutCubic
                }
            }
            Behavior on h {
                NumberAnimation {
                    duration: 260
                    easing.type: Easing.OutCubic
                }
            }
            visible: win.laneMode === "stage" && stageHost.h > 0.5
            x: Math.round(scene.width - rightBar.thickness - 12 - stageHost.w)
            y: Math.round(topBar.thickness + 12)
            width: stageHost.w
            height: stageHost.h
            clip: true

            Rectangle {
                anchors.fill: parent
                radius: 20
                color: Theme.surface
            }
            // Only on this lane: in the others a second stack would run its
            // own rows and countdowns for nothing.
            Loader {
                id: stageLoader
                active: win.laneMode === "stage"
                sourceComponent: NotificationToast {
                    service: svc
                    clock: clock
                    style: owner.style
                    overlayItem: scene
                }
            }
        }
    }

    Component {
        id: otherComp
        Item {
            implicitWidth: 300
            implicitHeight: 180
            Text {
                anchors.centerIn: parent
                text: "some other module's popup"
                color: Theme.textMuted
                font.family: owner.style.fontFamily
                font.pixelSize: 12
            }
        }
    }

    // ---- LANE=popup: the toast stack as thePopup, grown out of the corner -------------
    Connections {
        target: svc.toasts
        enabled: win.laneMode === "popup"
        function onSerialChanged() {
            const want = svc.toasts.shown.length > 0 && !svc.managerOpen;
            const mine = engine.popupOpen && engine.popupOwnerId === "notifications/toast";
            if (want && !mine && !engine.popupOpen)
                engine.open("notifications/toast", "top", engine.w - 200, null, null, true, owner.toastComponent, 0.5);
            else if (!want && mine)
                engine.close();
        }
    }

    // =====================================================================
    //  FIXTURES -- what real senders send, synthetic (the user gets few app
    //  notifications; the shapes are the apps' own: KDE Connect's inline
    //  reply, Signal's avatar as image-data, a screenshot's picture, ...)
    // =====================================================================
    readonly property var appFixtures: [
        { id: "signal", app: "Signal", entry: "signal", summary: "Anna",
          body: "Are we still on for tonight? I booked the table at eight, but I can move it if you're late.",
          image: "avatar_anna.png", actions: [{ id: "default", label: "Open" }, { id: "mark-read", label: "Mark read" }] },
        { id: "sms", app: "KDE Connect", entry: "org.kde.kdeconnect.daemon", summary: "Mum",
          body: "Call me when you land", actions: [{ id: "inline-reply", label: "Reply" }],
          hints: ["x-kde-reply-placeholder-text=string:Reply to Mum"] },
        { id: "vesktop", app: "Vesktop", entry: "vesktop", summary: "#general — Tom",
          body: "Look at this <a href=\"https://example.org\">build log</a>, the <b>third</b> run failed again" },
        { id: "shot", app: "swappy", entry: "swappy", summary: "Screenshot saved",
          body: "~/Pictures/Screenshots/2026-09-24_17-42.png", image: "screenshot.png",
          actions: [{ id: "default", label: "Open" }, { id: "edit", label: "Edit" }] },
        { id: "critical", app: "Steam", entry: "steam", summary: "Download stalled",
          body: "Cyberpunk 2077: disk write error, 23.4 GB left", urgency: 2 },
        { id: "low", app: "Zen Browser", entry: "zen", summary: "Download finished",
          body: "report-q3.pdf", urgency: 0 },
        // What real kitty sends (the user's history, R2B-T finding 1): its own
        // icon file as app_icon, no desktop-entry hint, a default action.
        { id: "kitty", app: "kitty", entry: "", icon: win.kittyIcon, summary: "Claude Code",
          body: "Claude is waiting for your input", actions: [{ id: "default", label: "default" }] },
        { id: "actions", app: "Thunderbird", entry: "", summary: "Meeting invitation",
          body: "Design review, Thursday 14:00–15:00, room 2.14",
          actions: [{ id: "accept", label: "Accept" }, { id: "tentative", label: "Maybe" },
                    { id: "decline", label: "Decline" }, { id: "propose", label: "Propose time" },
                    { id: "open", label: "Open" }] },
        { id: "progress", app: "KDE Connect", entry: "org.kde.kdeconnect.daemon", summary: "Receiving file",
          body: "IMG_2041.jpg from Pixel 8", value: 35 },
        // What NetworkManager's applet really sends (the user's history.json): a long source name, the
        // summary the source used to cut ("Connection Established"), the signal icon by theme NAME in the
        // image-path hint, and one long action.
        { id: "nm", app: "NetworkManager Applet", entry: "org.freedesktop.network-manager-applet", summary: "Connection Established",
          body: "You are now connected to the Wi-Fi network \u201chomenet-ABC12-AP\u201d.", imageName: "nm-signal-75",
          actions: [{ id: "app.enable-pref::disable-connected-notifications", label: "Don\u2019t show this message again" }] }
    ]
    readonly property var shellFixtures: [
        { id: "battery", source: "battery", title: "Battery at 8 %", body: "About 25 minutes left. Plug in, or hibernate now.",
          urgency: "critical", timeoutMs: -1, actions: [{ id: "hibernate", label: "Hibernate" }] },
        { id: "timer", source: "clock", appName: "Clock", title: "Timer done", body: "Tea — 4:00",
          urgency: "critical", actions: [{ id: "stop", label: "Stop" }, { id: "again", label: "Restart" }] },
        { id: "update", source: "update", appName: "System update", title: "42 updates waiting",
          body: "312 MiB · last update 9 days ago · linux-lts, mesa, zen-browser",
          urgency: "normal", actions: [{ id: "now", label: "Update now" }, { id: "later", label: "Later" }] },
        // The stocks cards carry the REAL body (StockMoveBody): the day so far, the move's span emphasised; the alert kinds the same.
        { id: "stocks", source: "stocks", appName: "Stocks", title: "ASML dropped 4.1% in 28 min",
          body: "Now 612.40 EUR, was 638.60 EUR · −2.05% today", urgency: "normal", icon: SourceGlyphs.stocksDown,
          bodyComponent: stockBody, bodyProps: { facts: win.stockFacts("sudden") },
          actions: [{ id: "open", label: "Open" }] },
        { id: "stocks-above", source: "stocks", appName: "Stocks", title: "ASML rose above 640.00 EUR",
          body: "Now 641.20 EUR, +0.40% today", urgency: "normal", icon: SourceGlyphs.stocksUp,
          bodyComponent: stockBody, bodyProps: { facts: win.stockFacts("above") },
          actions: [{ id: "open", label: "Open" }] }
    ]
    Component {
        id: stockBody
        StockMoveBody {}
    }
    // A stock's day for the stocks fixtures: 5-minute closes from 09:30 local, 3 h 25 min in, a quiet day and (sudden) a drop of the
    // last half hour; "above": the day creeping up through a level.
    function stockFacts(kind) {
        const start = new Date(2026, 10, 18, 9, 30).getTime(), nowMin = 205, prev = 638.6;
        const t = [], c = [];
        for (let m = 0; m <= 200; m += 5) {
            t.push(start + m * 60000);
            const quiet = prev * (1 + 0.004 * Math.sin(m / 17) + 0.0012 * Math.sin(m * 1.3) + (kind === "above" ? m / 205 * 0.006 : 0));
            c.push(kind === "sudden" && m >= 175 ? 638.6 * (1.003 - 0.043 * (m - 175) / 30) : quiet);
        }
        t.push(start + nowMin * 60000);
        c.push(kind === "above" ? 641.2 : 612.4);
        const q = { price: c[c.length - 1], timeMs: t[t.length - 1], prevClose: prev, spark: { t: t.slice(0, -1), c: c.slice(0, -1) },
                    session: { start: start, end: start + 390 * 60000 } };
        const now = t[t.length - 1];
        return kind === "sudden" ? Sudden.facts(q, { dir: "down", fromMs: start + 175 * 60000, toMs: now }, { pct: 3, minutes: 30 }, now)
                                 : Sudden.facts(q, null, null, now, { kind: "above", level: 640 });
    }
    // Distinct senders for the list scenarios (one manager row per app).
    readonly property var fillerApps: ["Calendar", "Mail", "Files", "Discord", "Spotify", "Weather", "Maps", "Notes",
        "Podcasts", "Books"]

    readonly property string fixtureDir: RepoRoot.dir + "/mockups/fixtures/notifications_ui"
    readonly property string kittyIcon: (Quickshell.env("HOME") || "") + "/.config/kitty/kitty.app.png"
    property int _fakeId: 1000
    property var _lastBusId: ({})           // fixture id -> the server id it got (replaces)
    Component {
        id: fakeComp
        FakeNotification {}
    }
    Process {
        id: sender
        property var queue: []
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const r = JSON.parse(this.text);
                    if (r && r.id && sender.current) {
                        const m = Object.assign({}, win._lastBusId);
                        m[sender.current] = r.id;
                        win._lastBusId = m;
                    }
                } catch (e) {}
            }
        }
        property string current: ""
        function push(fixId, argv) {
            sender.queue = sender.queue.concat([{ fixId: fixId, argv: argv }]);
            if (!sender.running)
                sender._next();
        }
        function _next() {
            if (sender.queue.length === 0)
                return;
            const job = sender.queue[0];
            sender.queue = sender.queue.slice(1);
            sender.current = job.fixId;
            sender.command = job.argv;
            sender.running = true;
        }
    }

    Connections {
        target: sender
        function onExited() {
            sender._next();
        }
    }

    function sendApp(fx, overrides) {
        const f = Object.assign({}, fx, overrides || {});
        if (win.inproc) {
            const hints = {};
            for (const h of f.hints || []) {
                const kv = h.split("=");
                hints[kv[0]] = kv.slice(1).join("=").replace(/^[a-z]+:/, "");
            }
            if (f.value !== undefined)
                hints.value = f.value;
            const fake = fakeComp.createObject(win, {
                id: ++win._fakeId, appName: f.app, appIcon: f.icon || "", desktopEntry: f.entry || "", summary: f.summary,
                body: f.body || "", urgency: f.urgency === undefined ? 1 : f.urgency,
                expireTimeout: -1, hints: hints,
                image: f.imageName ? "image://icon/" + f.imageName : (f.image ? "image://icon/" + win.fixtureDir + "/" + f.image : "")
            });
            (fake as FakeNotification).setActions(f.actions || []);
            svc.receive(fake);
            return;
        }
        const argv = ["python3", RepoRoot.dir + "/tools/notifications/notify_client.py", "send",
                      "--app", f.app, "--summary", f.summary, "--body", f.body || ""];
        if (f.icon)
            argv.push("--icon", f.icon);
        if (f.urgency !== undefined)
            argv.push("--urgency", String(f.urgency));
        if (f.entry)
            argv.push("--hint", "desktop-entry=string:" + f.entry);
        for (const h of f.hints || [])
            argv.push("--hint", h);
        if (f.value !== undefined)
            argv.push("--hint", "value=int:" + f.value);
        if (f.imageName)
            argv.push("--hint", "image-path=string:" + f.imageName);
        else if (f.image)
            argv.push("--hint", "image-path=string:" + win.fixtureDir + "/" + f.image);
        for (const a of f.actions || [])
            argv.push("--action", a.id + "=" + a.label);
        if (f.replaces)
            argv.push("--replaces", String(f.replaces));
        sender.push(f.id, argv);
    }
    function sendShell(fx) {
        svc.post({
            source: fx.source, key: fx.id, appName: fx.appName || "", title: fx.title, body: fx.body,
            urgency: fx.urgency, timeoutMs: fx.timeoutMs, actions: fx.actions,
            icon: fx.icon, bodyComponent: fx.bodyComponent, bodyProps: fx.bodyProps,
            onAction: id => console.log("SHELL-ACTION " + fx.id + " " + id)
        });
    }
    function sendById(id) {
        for (const f of win.appFixtures)
            if (f.id === id)
                return win.sendApp(f);
        for (const f of win.shellFixtures)
            if (f.id === id)
                return win.sendShell(f);
        console.warn("no fixture " + id);
    }
    function progressStep(v) {
        const f = win.appFixtures.find(x => x.id === "progress");
        const prev = win._lastBusId["progress"] || 0;
        win.sendApp(f, { value: v, replaces: prev });
    }
    // n notifications at one urgency (0 low, 1 normal), each from its own app:
    // no icon, no action (the kitty fixture is only the template's shape).
    function sendFillers(n, urgency) {
        const f = win.appFixtures.find(x => x.id === "kitty");
        const tag = urgency === 0 ? "low" : "normal";
        for (let k = 0; k < n; k++) {
            const app = win.fillerApps[k % win.fillerApps.length] + (urgency === 0 ? " (low)" : "");
            win.sendApp(f, { id: tag + k, app: app, entry: "", icon: "", actions: [], summary: app + ": " + tag + " " + (k + 1),
                             body: "A " + tag + " notification, row " + (k + 1) + " of " + n + ".", urgency: urgency });
        }
    }

    // ---- env, applied once everything exists ----------------------------------------------
    Timer {
        running: true
        interval: 400
        onTriggered: {
            const send = Quickshell.env("SEND") || "";
            if (send !== "") {
                const ids = send.split(",");
                for (let i = 0; i < ids.length; i++)
                    Qt.callLater(() => win.sendById(ids[i]));
            }
            if ((Quickshell.env("OPEN") || "") === "manager")
                openTimer.start();
        }
    }
    Timer {
        id: openTimer
        interval: 900
        onTriggered: owner.open()
    }
    // ACT="<verb>[:arg]@ms,..." -- scripted steps (the render states, the Run
    // page's scenarios: play() takes the same script):
    //   send:<id>  flood  allapps (every app fixture in a row: the Run tab's "all apps")
    //   fill:<n>  lows:<n>  wipe
    //   manager  open:<group>  toggle:<group>  clear:<group>  swipe:<group>  clearall  undo
    //   mpin:<n> (the open group's nth row, pinned by its swipe: the flight)  end (list to its foot)
    //   filter:<text>  dnd  hold:<fullscreen|screencast|locked|idle>  release:<same>
    //   module (the stand-in popup)  pin:<n>  file:<n>  remove:<n>  (n = nth toast, newest first)
    Component {
        id: actTimer
        Timer {
            property string step
            running: true
            onTriggered: {
                win.act(step);
                destroy();
            }
        }
    }
    function play(script) {
        const acts = String(script || "").split(",").filter(x => x.indexOf("@") > 0);
        for (const a of acts) {
            const at = a.lastIndexOf("@");
            actTimer.createObject(win, { step: a.substring(0, at), interval: Math.max(1, Number(a.substring(at + 1))) });
        }
    }
    Component.onCompleted: {
        win._configInit();
        win.play(Quickshell.env("ACT") || "");
    }
    // Items are found by their members, not by `as`: a type cast fails when
    // this file is created from another root (a probe) -- the two see the
    // module's files as distinct registrations.
    function _manager() {
        const c = engine.popupOpen && engine.popupOwnerId === owner.ownerId && engine.thePopup
            ? engine.thePopup.contentItem : null;
        return c && c.listWave !== undefined ? c : null;
    }
    // Every item under `item` (children, depth first) for which pred() holds.
    function findAll(item, pred) {
        const out = [];
        const walk = it => {
            if (!it)
                return;
            if (pred(it))
                out.push(it);
            for (let i = 0; i < it.children.length; i++)
                walk(it.children[i]);
        };
        walk(item);
        return out;
    }
    function _sectionOf(m, g) {
        const s = win.findAll(m, it => it.headerCard !== undefined && it.group === g);
        return s.length > 0 ? s[0] : null;
    }
    // A SwipeVerbCard's commit (the reader's notch): the card's own decision path.
    function _commit(card, dir) {
        if (card && typeof card.commit === "function")
            card.commit(dir);
    }
    function act(step) {
        const i = step.indexOf(":");
        const verb = i < 0 ? step : step.substring(0, i);
        const arg = i < 0 ? "" : step.substring(i + 1);
        const m = win._manager();
        const nth = n => svc.toasts.shown[Number(n)] || "";
        switch (verb) {
        case "send":
            win.sendById(arg);
            break;
        case "flood": {
            const f = win.appFixtures.find(x => x.id === "vesktop");
            for (let k = 0; k < 6; k++)
                win.sendApp(f, { summary: "#general — Tom (" + (k + 1) + ")" });
            break;
        }
        case "allapps":
            for (const f of win.appFixtures)
                win.sendApp(f);
            break;
        case "fill":
            win.sendFillers(Number(arg) || 6, 1);
            break;
        case "lows":
            win.sendFillers(Number(arg) || 8, 0);
            break;
        case "wipe":
            // Everything gone for good (no undo window): the empty manager.
            for (const d of svc.store.all())
                svc.remove(d.uid);
            break;
        case "manager":
            owner.toggle();
            break;
        case "open":
            if (m && !m.isOpen(arg))
                m.toggleGroup(arg);
            break;
        case "toggle":
            if (m) m.toggleGroup(arg);
            break;
        case "clear":
            if (m) m.clearGroup(arg);
            break;
        case "swipe": {
            // The header's own swipe (committed as the reader's notch does):
            // the header flies off and the group clears.
            const s = m ? win._sectionOf(m, arg) : null;
            win._commit(s ? s.headerCard : null, 1);
            break;
        }
        case "clearall":
            // Through the manager when it is up: its wave and its undo slot.
            if (m) m.clearAll();
            else svc.clearAll();
            break;
        case "undo":
            if (m) m.undo();
            break;
        case "mpin": {
            const s = m ? win._sectionOf(m, m.openGroup) : null;
            const rows = s ? s.rowItems() : [];
            const slot = rows[Number(arg) || 0];
            const b = slot ? slot.bodyItem : null;
            win._commit(b && b.uids.length > 0 ? b.cardFor(b.uids[0]) : null, 1);
            break;
        }
        case "end": {
            const v = m ? m.listWave.view : null;
            if (v)
                v.contentY = Math.max(0, v.contentHeight - v.height);
            break;
        }
        case "filter":
            if (m) m.filter = arg;
            break;
        case "dnd":
            svc.dnd = !svc.dnd;
            break;
        case "hold":
            svc.holds[arg] = true;
            break;
        case "release":
            svc.holds[arg] = false;
            break;
        case "module":
            engine.toggle("other", "top", 1150, null, null, false, otherComp, 0.5);
            break;
        case "pin":
            svc.togglePin(nth(arg));
            break;
        case "file":
            svc.file(nth(arg));
            break;
        case "remove":
            svc.remove(nth(arg));
            break;
        default:
            console.warn("ACT: unknown step " + step);
        }
    }
    readonly property string stageGrab: Quickshell.env("STAGE_GRAB") || ""
    Timer {
        running: win.stageGrab !== ""
        interval: Number(Quickshell.env("GRAB_MS") || 2500)
        onTriggered: scene.grabToImage(r => {
            r.saveToFile(win.stageGrab);
            Qt.quit();
        })
    }

    // The states, one script each: the Run page's buttons and a render of
    // a state play the same steps.
    readonly property string _fillAll: "send:signal@0,send:sms@60,send:vesktop@120,send:shot@180,send:actions@240,"
        + "send:critical@300,send:low@360,send:battery@420,send:update@480"
    readonly property var scenarios: [
        { name: "clear all + undo", short: "the exit wave, then Undo's wave back", script: win._fillAll + ",manager@1200,clearall@2400,undo@4400",
          tip: "Clear all plays the list's exit wave, top down, headers and cards alike; the popup is then the top row with Undo draining in the button. Undo (at +2 s) plays everything back in on the same wave." },
        { name: "swipe a group away", short: "Low leaves; \"Undo clear Low\" on top", script: win._fillAll + ",manager@1200,swipe:low@2400,undo@5400",
          tip: "Low's header is swiped (committed as a notch would): the group clears and leaves on the wave, and the top row's one undo slot reads \"Undo clear Low\" for the undo window. Undo at +3 s brings it back." },
        { name: "empty", short: "\"No notifications\", then Clear all returns", script: "wipe@0,manager@400,send:signal@2600",
          tip: "Every record removed for good (no undo window), then the manager: \"No notifications\", no Clear all, the toggle at the right end, the popup the top row. At +2.2 s a notification arrives and Clear all comes back, pushing the toggle aside on one clock." },
        { name: "pin flight", short: "a row flies to the top of Normal", script: "fill:5@0,send:signal@300,manager@1200,open:normal@2000,mpin:3@3000",
          tip: "Normal open with six rows; the fourth is pinned by its own swipe: a lifted clone flies to the top of the group while the hole it left closes and its new place opens (RowFlight). No row leaves or enters." },
        { name: "follow the foot", short: "Low opened at the foot, the list follows", script: "fill:6@0,lows:8@200,send:critical@400,send:update@500,manager@1400,open:normal@2200,end@3000,open:low@3800",
          tip: "Normal open with six rows, the list scrolled to its end, Low folded at the foot. Opening Low, the list rides its rows up until the header would pass under the top fade (list_animation.md, \"Expanding at the very bottom\")." },
        { name: "flood", short: "six from one app: three, then \"+N more\"", script: "flood@0",
          tip: "Six Vesktop messages at once: after three from one app inside the flood window the rest file silently, and the newest toast says \"+N more from Vesktop\"." },
        { name: "drain", short: "two toasts counting down to nothing", script: "send:vesktop@0,send:kitty@400",
          tip: "Two normal toasts counting down: the group colour fills the inset and drains to nothing at the deadline (8 s by default: Config > Timeouts), then the card files itself into the manager. Hover pauses both." },
        { name: "holds", short: "fullscreen holds; one summary after", script: "hold:fullscreen@0,send:signal@300,send:sms@500,send:critical@700,release:fullscreen@3500",
          tip: "A fullscreen window holds the toasts back: the critical still shows in full, the rest wait. At +3.5 s the window leaves and ONE summary toast brings the held ones back." }
    ]

    // =====================================================================
    //  THE CONFIG FILE (the Config tab's target)
    // =====================================================================
    // notifications.jsonc is what the module DOES, and it is a file, not
    // properties: these knobs mirror its keys, and every change the panel
    // makes is written to the PRIVATE file the service hot-reloads (only the
    // keys the panel changed, over whatever the file held: an `apps` rule, a
    // hand-written timeout). Written ONLY when XDG_CONFIG_HOME is a private
    // directory -- never the user's own ~/.config.
    QtObject {
        id: cfgKnobs
        // timeouts, ms; 0 here is "never" (the file's -1)
        property int timeoutsLow: 4000
        property int timeoutsNormal: 8000
        property int timeoutsCritical: 0
        property int timeoutsClampMin: 3000
        property int timeoutsClampMax: 60000
        // toasts
        property int toastsMax: 5
        property int toastsFloodCount: 3
        property int toastsFloodWindowMs: 10000
        property int toastsHoverResumeMinMs: 2000
        // history
        property int retentionCount: 200
        property int retentionDays: 7
        property int undoMs: 10000
        property int idleMs: 60000
        // holds
        property bool dndHoldFullscreen: true
        property bool dndHoldScreencast: true
        // JSON text (the rows validate it before it lands here)
        property string dndBreakthrough: "[\"clock\",\"auth\"]"
        property string soundsLow: "[]"
        property string soundsNormal: "[\"~/.local/share/sounds/notification.mp3\",\"/usr/share/sounds/notification.mp3\"]"
        property string soundsCritical: "[\"~/.local/share/sounds/notification-critical.mp3\",\"~/.local/share/sounds/notification.mp3\",\"/usr/share/sounds/notification.mp3\"]"
        property string appsRules: "{\"kitty\":{\"focusSuppress\":false},\"org.freedesktop.network-manager-applet\":{\"drop\":true},\"NetworkManager Applet\":{\"drop\":true},\"nm-applet\":{\"drop\":true},\"blueman\":{\"drop\":true},\"blueman-applet\":{\"drop\":true}}"
        property string sourcesRules: "{}"
        // the spot: an index into win.corners, one past them = along a bar,
        // the bar (an index into win.spotBars) and where along it (0..1)
        property int spotCorner: 0
        property int spotBar: 0
        property real spotAlong: 0.5
    }
    // The corners the mockup has bars for (a top bar and a right bar): a
    // corner with no bar on its first edge opens no lane. The spot's other
    // form, a point along a bar, is the last choice.
    readonly property var corners: ["top-right", "top-left", "right-top", "right-bottom"]
    readonly property var spotBars: ["top", "right"]
    // Knob -> file key. `kind`: "never0" a timeout whose 0 is the file's -1,
    // "bool", "int", "json" (the knob holds the key's value as JSON text),
    // "spot" (the whole `spot` object, from spotCorner / spotBar / spotAlong).
    readonly property var configKeys: [
        { knob: "timeoutsLow", path: ["timeouts", "low"], kind: "never0" },
        { knob: "timeoutsNormal", path: ["timeouts", "normal"], kind: "never0" },
        { knob: "timeoutsCritical", path: ["timeouts", "critical"], kind: "never0" },
        { knob: "timeoutsClampMin", path: ["timeouts", "clampMin"], kind: "int" },
        { knob: "timeoutsClampMax", path: ["timeouts", "clampMax"], kind: "int" },
        { knob: "toastsMax", path: ["toasts", "max"], kind: "int" },
        { knob: "toastsFloodCount", path: ["toasts", "floodCount"], kind: "int" },
        { knob: "toastsFloodWindowMs", path: ["toasts", "floodWindowMs"], kind: "int" },
        { knob: "toastsHoverResumeMinMs", path: ["toasts", "hoverResumeMinMs"], kind: "int" },
        { knob: "retentionCount", path: ["retention", "count"], kind: "int" },
        { knob: "retentionDays", path: ["retention", "days"], kind: "int" },
        { knob: "undoMs", path: ["undoMs"], kind: "int" },
        { knob: "idleMs", path: ["idleMs"], kind: "int" },
        { knob: "dndHoldFullscreen", path: ["dnd", "holdFullscreen"], kind: "bool" },
        { knob: "dndHoldScreencast", path: ["dnd", "holdScreencast"], kind: "bool" },
        { knob: "dndBreakthrough", path: ["dnd", "breakthroughSources"], kind: "json" },
        { knob: "soundsLow", path: ["sounds", "low"], kind: "json" },
        { knob: "soundsNormal", path: ["sounds", "normal"], kind: "json" },
        { knob: "soundsCritical", path: ["sounds", "critical"], kind: "json" },
        { knob: "appsRules", path: ["apps"], kind: "json" },
        { knob: "sourcesRules", path: ["sources"], kind: "json" },
        { knob: "spotCorner", path: ["spot"], kind: "spot" }
    ]
    // The knobs that are PART of another key's value (the spot's bar and
    // along): a change to one is a change to that key.
    readonly property var knobParts: ({
            spotBar: "spotCorner",
            spotAlong: "spotCorner"
        })
    // The file's value for a key; undefined = not writable (JSON the row
    // would have refused: it never reaches a knob through the panel).
    function toFileValue(kind, v) {
        if (kind === "never0")
            return v > 0 ? v : -1;
        if (kind === "bool")
            return !!v;
        if (kind === "json") {
            try {
                return JSON.parse(String(v));
            } catch (e) {
                return undefined;
            }
        }
        if (kind === "spot")
            return cfgKnobs.spotCorner >= win.corners.length
                ? { bar: win.spotBars[cfgKnobs.spotBar] || win.spotBars[0], along: Number(Number(cfgKnobs.spotAlong).toFixed(2)) }
                : { corner: win.corners[cfgKnobs.spotCorner] || win.corners[0] };
        return Number(v);
    }
    // A knob's value for a file value (for "spot": the corner choice; the
    // bar and along come with it, _spotKnobs).
    function toKnobValue(kind, v) {
        if (kind === "never0")
            return v > 0 ? v : 0;
        if (kind === "bool")
            return v !== false;
        if (kind === "json")
            return JSON.stringify(v);
        if (kind === "spot")
            return v && typeof v === "object" && v.bar !== undefined ? win.corners.length
                : Math.max(0, win.corners.indexOf(v && v.corner ? v.corner : ""));
        return Number(v);
    }
    function _spotKnobs(v) {
        cfgKnobs.spotCorner = win.toKnobValue("spot", v);
        if (v && typeof v === "object" && v.bar !== undefined) {
            cfgKnobs.spotBar = Math.max(0, win.spotBars.indexOf(String(v.bar)));
            cfgKnobs.spotAlong = Math.max(0, Math.min(1, Number(v.along) || 0));
        }
    }
    function _at(obj, path) {
        let o = obj;
        for (const p of path)
            o = o && typeof o === "object" ? o[p] : undefined;
        return o;
    }

    // Private: XDG_CONFIG_HOME is set and is not the user's own ~/.config.
    function _normPath(p) {
        return String(p || "").replace(/\/+/g, "/").replace(/\/$/, "");
    }
    readonly property string _xdgConfig: Quickshell.env("XDG_CONFIG_HOME") || ""
    readonly property bool configPrivate: win._xdgConfig !== ""
        && win._normPath(win._xdgConfig) !== win._normPath((Quickshell.env("HOME") || "") + "/.config")
    // The file the service reads, when it is private; "" (nothing) otherwise.
    readonly property string configFile: win.configPrivate ? svc.configPath : ""
    property string configStatus: ""
    property string configWritten: ""
    property int configWrites: 0
    property var _cfgBase: ({})
    property var _cfgDirty: ({})
    property bool _cfgReady: false

    ConfigFile {
        id: cfgFile
        path: win.configFile
        watchChanges: false
    }
    Process {
        id: cfgMkdir
        command: ["mkdir", "-p", win.configFile.replace(/\/[^/]*$/, "")]
    }
    Timer {
        id: cfgWriteTimer
        interval: 150
        onTriggered: win._configWrite()
    }
    // After the framework's own onCompleted (the val: defaults are in the
    // knobs): the knobs take what the file holds, so the panel shows what the
    // service runs on; then every change is a write.
    function _configInit() {
        if (!win.configPrivate) {
            win.configStatus = "not written: XDG_CONFIG_HOME is " + (win._xdgConfig === "" ? "unset" : "your own ~/.config")
                + " -- run tools/dev/notifications_mockup.sh";
            win._cfgReady = true;
            return;
        }
        cfgMkdir.running = true;
        const t = cfgFile.text() || "";
        let base = {};
        if (t.trim() !== "") {
            try {
                base = JSON.parse(JsonComments.strip(t));
            } catch (e) {
                base = null;
            }
        }
        if (!base || typeof base !== "object" || Array.isArray(base)) {
            win.configStatus = "not written: " + win.configFile + " does not parse (the panel will not overwrite it)";
            win._cfgBase = null;
            win._cfgReady = true;
            return;
        }
        win._cfgBase = base;
        const merged = Policy.merge(base);
        for (const e of win.configKeys) {
            const v = win._at(merged, e.path);
            if (v === undefined)
                continue;
            if (e.kind === "spot")
                win._spotKnobs(v);
            else
                cfgKnobs[e.knob] = win.toKnobValue(e.kind, v);
        }
        for (const key of win.configKeys.map(e => e.knob).concat(Object.keys(win.knobParts))) {
            const k = win.knobParts[key] || key;
            (cfgKnobs as QtObject)[key + "Changed"].connect(() => win._configTouched(k));
        }
        win.configStatus = "writes " + win.configFile;
        win._cfgReady = true;
    }
    function _configTouched(knob) {
        if (!win._cfgReady || !win.configPrivate || win._cfgBase === null)
            return;
        const d = Object.assign({}, win._cfgDirty);
        d[knob] = true;
        win._cfgDirty = d;
        cfgWriteTimer.restart();
    }
    // The file's object: what it held, with every key the panel changed set
    // -- or dropped when it is back at the code's default.
    function configObject() {
        const out = JSON.parse(JSON.stringify(win._cfgBase || {}));
        const defs = Policy.defaults();
        for (const e of win.configKeys) {
            if (!win._cfgDirty[e.knob])
                continue;
            const v = win.toFileValue(e.kind, cfgKnobs[e.knob]);
            if (v === undefined)
                continue;
            // By value: a rule object or a sound list is its JSON.
            const isDefault = JSON.stringify(win._at(defs, e.path)) === JSON.stringify(v);
            let o = out;
            for (let i = 0; i < e.path.length - 1; i++) {
                if (!o[e.path[i]] || typeof o[e.path[i]] !== "object")
                    o[e.path[i]] = {};
                o = o[e.path[i]];
            }
            const leaf = e.path[e.path.length - 1];
            if (isDefault)
                delete o[leaf];
            else
                o[leaf] = v;
            if (e.path.length > 1 && Object.keys(out[e.path[0]]).length === 0)
                delete out[e.path[0]];
        }
        return out;
    }
    function _configWrite() {
        if (!win.configPrivate || win._cfgBase === null)
            return;
        const text = JSON.stringify(win.configObject(), null, 2) + "\n";
        cfgFile.setText(text);
        win.configWritten = text;
        win.configWrites++;
    }

    // =====================================================================
    //  RUN PAGE
    // =====================================================================
    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Scenarios"
                blurb: "The round-2 states, each a short script on the live module (hover a row for what to watch)."
            }
            Repeater {
                model: win.scenarios.length
                TipRow {
                    id: scenRow
                    required property int index
                    readonly property var sc: win.scenarios[scenRow.index]
                    tip: scenRow.sc.tip
                    Layout.fillWidth: true
                    spacing: 6
                    Button {
                        Layout.preferredWidth: 150
                        text: scenRow.sc.name
                        onClicked: win.play(scenRow.sc.script)
                    }
                    Label {
                        Layout.fillWidth: true
                        text: scenRow.sc.short
                        elide: Text.ElideRight
                        color: "#6F6F72"
                        font.pixelSize: 12
                    }
                }
            }
            TipGroup {
                title: "Send"
                blurb: win.inproc ? "In-process: FakeNotifications into service.receive()."
                    : "Over D-Bus (the mockup's private bus unless Live): tools/notifications/notify_client.py, as an app would."
            }
            TipRow {
                tip: "One button per app fixture: a notification shaped like what that app really sends (Signal's avatar as image-data, KDE Connect's inline reply, a screenshot's picture ...), sent the way the blurb above says."
                Flow {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: win.appFixtures.map(f => f.id)
                        Button {
                            required property string modelData
                            text: modelData
                            onClicked: win.sendById(modelData)
                        }
                    }
                }
            }
            TipRow {
                tip: "A file transfer's progress hint (int:value), sent as a REPLACE of the same notification: the row updates in place and does not toast again (progress-only)."
                Layout.fillWidth: true
                spacing: 6
                Button {
                    text: "progress 70"
                    onClicked: win.progressStep(70)
                }
                Button {
                    text: "progress 100"
                    onClicked: win.progressStep(100)
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipGroup {
                title: "Shell sources"
                blurb: "service.post() -- what the shell's own modules raise (the System group)."
            }
            TipRow {
                tip: "One button per shell source: what the shell's own modules post through service.post() (a low battery, a finished timer ...), in the System group."
                Flow {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: win.shellFixtures.map(f => f.id)
                        Button {
                            required property string modelData
                            text: modelData
                            onClicked: win.sendById(modelData)
                        }
                    }
                }
            }
            TipRow {
                tip: "Bursts: six Vesktop messages at once (the flood rule collapses the rest after three), every app fixture in a row (the five-entry stack and its \"+N more\"), and six normal / eight low notifications from distinct apps (one manager row each: a long list)."
                Layout.fillWidth: true
                spacing: 6
                Button {
                    text: "flood x6"
                    onClicked: win.act("flood")
                }
                Button {
                    text: "all apps"
                    onClicked: win.act("allapps")
                }
                Button {
                    text: "6 normal"
                    onClicked: win.act("fill:6")
                }
                Button {
                    text: "8 low"
                    onClicked: win.act("lows:8")
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipGroup {
                title: "Holds"
                blurb: "Driven by hand here (liveSignals off)."
            }
            TipRow {
                tip: "Do not disturb: toasts stop (critical and the breakthrough sources still show), everything lands in the manager. Fullscreen / sharing / locked hold toasts and release them as one summary when they end (Config > Holds decides whether fullscreen and sharing hold at all)."
                Layout.fillWidth: true
                spacing: 6
                CheckBox {
                    text: "DND"
                    checked: svc.dnd
                    onToggled: svc.dnd = checked
                }
                CheckBox {
                    text: "fullscreen"
                    checked: svc.holds.fullscreen
                    onToggled: svc.holds.fullscreen = checked
                }
                CheckBox {
                    text: "sharing"
                    checked: svc.holds.screencast
                    onToggled: svc.holds.screencast = checked
                }
                CheckBox {
                    text: "locked"
                    checked: svc.holds.locked
                    onToggled: svc.holds.locked = checked
                }
                CheckBox {
                    text: "idle"
                    checked: svc.holds.idle
                    onToggled: svc.holds.idle = checked
                }
            }
            TipRow {
                tip: "Open the manager from the bell (as a click would), open the stand-in module's popup (the toasts melt beside it), or remove every notification for good (no undo window)."
                Layout.fillWidth: true
                spacing: 6
                Button {
                    text: "manager"
                    onClicked: owner.toggle()
                }
                Button {
                    text: "module popup"
                    onClicked: win.act("module")
                }
                Button {
                    text: "wipe"
                    onClicked: win.act("wipe")
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipGroup {
                title: "Live"
                blurb: "The real session bus: stops mako (only mako) for this run, so real apps land here."
            }
            TipRow {
                tip: "Only with LIVE=1 and on the user's own bus. Asks first. tools/notifications/claim_name.sh checks the name's owner is mako, TERMs that pid alone, waits for the name to free; mako is D-Bus-activated again by the next notification after the mockup quits."
                Layout.fillWidth: true
                spacing: 6
                Button {
                    text: win.live ? "live" : "go live..."
                    enabled: win.armedLive && !win.live
                    onClicked: liveConfirm.visible = true
                }
                Label {
                    id: liveConfirm
                    visible: false
                    text: "Stop mako and take the name?"
                }
                Button {
                    visible: liveConfirm.visible
                    text: "yes"
                    onClicked: {
                        liveConfirm.visible = false;
                        claim.running = true;
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "records " + (svc.serial >= 0 ? svc.store.all().length : 0)
                    + "   shown " + svc.toasts.shown.length + "   more " + svc.toasts.moreCount
                    + "   hold " + (svc.holdReason || "-") + "   dot " + (svc.dotGroup || "-")
                    + "   lane " + win.laneMode
                color: "#8A8A8C"
                font.pixelSize: 12
            }
        },
        MockupPage {
            id: configPage

            TipGroup {
                title: "The file"
                blurb: "notifications.jsonc, private to this run. The service re-reads it the moment it changes."
            }
            TipRow {
                tip: "Every change on this tab rewrites the private notifications.jsonc (only the keys the panel changed, merged over what the file held) and the service hot-reloads it. Nothing is written when XDG_CONFIG_HOME is unset or is your own ~/.config: run the mockup through tools/dev/notifications_mockup.sh."
                Layout.fillWidth: true
                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WrapAnywhere
                    text: win.configStatus + (svc.configError !== "" ? "\n" + svc.configError : "")
                    color: win.configPrivate && svc.configError === "" ? "#5D5D5F" : "#D20F39"
                    font.pixelSize: 12
                }
            }
            Label {
                Layout.fillWidth: true
                visible: win.configWritten !== ""
                wrapMode: Text.WrapAnywhere
                text: win.configWritten
                color: "#6F6F72"
                font.family: "monospace"
                font.pixelSize: 11
            }
            TipGroup {
                title: "Hear"
                blurb: "The sound an urgency makes with the lists above (Sounds): the first file that exists, or nothing."
            }
            TipRow {
                tip: "Plays what a notification of that urgency would play right now: the first file of its `sounds` list that exists (pw-play), nothing under DND or when none exists. The line beside says which file, or why it was silent. The sender's own sound hints and an app rule's `sound` come before the list on a real notification."
                Layout.fillWidth: true
                spacing: 6
                Repeater {
                    model: ["low", "normal", "critical"]
                    Button {
                        required property string modelData
                        text: modelData
                        onClicked: svc.sound.play({ urgency: modelData }, {})
                    }
                }
                Label {
                    Layout.fillWidth: true
                    elide: Text.ElideLeft
                    // The service keeps the last of each, not which came last.
                    text: (svc.sound.lastPlayed !== "" ? "last played " + svc.sound.lastPlayed : "")
                        + (svc.sound.lastSkipped !== "" ? "   last silence: " + svc.sound.lastSkipped : "")
                    color: "#6F6F72"
                    font.pixelSize: 12
                }
            }
        }
    ]
    Process {
        id: claim
        command: ["bash", RepoRoot.dir + "/tools/notifications/claim_name.sh"]
    }
    Connections {
        target: claim
        function onExited(code: int) {
            if (code === 0) {
                win.live = true;
                svc.serverEnabled = false;
                svc.serverEnabled = true;
            }
        }
    }

    // =====================================================================
    //  VALUES
    // =====================================================================
    readonly property var styleCard: [
        {
            label: "radius",
            prop: "cardRadius",
            group: "Card",
            blurb: "One notification, toast and manager alike.",
            tip: "Corner radius of the carved card. 14, the container radius, so a card meeting a container's corner shares its curve.",
            val: 14,
            from: 4,
            to: 24,
            step: 1
        },
        {
            label: "padding",
            prop: "cardPadding",
            group: "Card",
            tip: "Space inside the card, and where the text starts when there is no icon column. 12, the shell's card padding.",
            val: 12,
            from: 4,
            to: 24,
            step: 1
        },
        {
            label: "icon",
            prop: "iconSize",
            group: "Icon",
            blurb: "The theme's own icon, unprocessed; an avatar with the app's icon as a badge; or a shell glyph. No image, icon or glyph: no column.",
            tip: "The icon column. 40, the launcher's icon size, so an app looks the same here and there. Icons are rendered at the size they are seen at (never magnified).",
            val: 40,
            from: 24,
            to: 64,
            step: 2
        },
        {
            label: "icon gap",
            prop: "iconGap",
            group: "Icon",
            tip: "Space between the icon column and the text, and above a picture band. 10, a little under the card padding, so the icon reads as part of the text block.",
            val: 10,
            from: 4,
            to: 24,
            step: 1
        },
        {
            label: "badge",
            prop: "badgeSize",
            group: "Icon",
            tip: "The app's icon on an avatar's lower-right corner, so a contact's picture still names its app. 18, under half the avatar: the face stays readable.",
            val: 18,
            from: 10,
            to: 28,
            step: 1
        },
        {
            label: "glyph scale",
            prop: "glyphScale",
            group: "Icon",
            tip: "A shell source's glyph (battery, clock, update) as a share of the icon size. 1.0: a Material glyph's ink is 20/24 of its em, so at the icon size it fills the column the way a theme icon's artwork does.",
            val: 1,
            from: 0.5,
            to: 1.5,
            step: 0.05
        },
        {
            label: "body lines",
            prop: "maxLines",
            group: "Text",
            blurb: "How much of the body a card shows.",
            tip: "Lines of body before it is elided (the user's pick: 3). The manager's chevron opens the rest in place.",
            val: 3,
            from: 1,
            to: 8,
            step: 1
        },
        {
            label: "font",
            prop: "fontFamily",
            group: "Type",
            blurb: "The module's words: the card, the stack's foot, the manager's title row and headers.",
            tip: "The face of every word the module draws: cards, the stack's foot, the manager's title, headers and buttons. Inter, the module's own default (CLAUDE.md Type); the user dresses mockups in Audiowide -- type it here. A family that is not installed falls back to the system face.",
            val: "Inter",
            kind: "text"
        },
        {
            label: "summary",
            prop: "summarySize",
            group: "Type",
            tip: "The card's first line. 12, the shell's body size: the summary is bold at the size of the body, not bigger -- a card is a row of a list, not a headline.",
            val: 12,
            from: 8,
            to: 20,
            step: 1
        },
        {
            label: "body",
            prop: "bodySize",
            group: "Type",
            tip: "The body text. 12, the shell's body size.",
            val: 12,
            from: 8,
            to: 20,
            step: 1
        },
        {
            label: "meta",
            prop: "metaSize",
            group: "Type",
            tip: "The \"App · 3 min\" line: the app, its dot, the time, the pin glyph, and the width the time slot reserves (so the figure never jitters). 11, the shell's figures size.",
            val: 11,
            from: 7,
            to: 18,
            step: 1
        },
        {
            label: "footnote",
            prop: "footSize",
            group: "Type",
            tip: "The flood footnote under a card (\"+N more from <app>\"). 11, figures size: it is a count, not a sentence.",
            val: 11,
            from: 7,
            to: 18,
            step: 1
        },
        {
            label: "action label",
            prop: "actionTextSize",
            group: "Type",
            tip: "An action button's label (Open, Reply, Mark read). 11: a button under 12 px text stays quieter than the text it acts on.",
            val: 11,
            from: 7,
            to: 18,
            step: 1
        },
        {
            label: "bevel",
            prop: "cardBevelWidth",
            group: "Carve",
            blurb: "The card is carved into the popup (ShadowBox): an inset shadow inside the edge, a light bevel outside.",
            tip: "The light rim outside the card's carved edge. 1, the containers' bevel (CLAUDE.md Material: 3 / 1 on containers).",
            val: 1,
            from: 0,
            to: 4,
            step: 0.5
        },
        {
            label: "shadow",
            prop: "cardShadowWidth",
            group: "Carve",
            tip: "The inset shadow inside the card's edge. 3, the containers' carve. The group colour's shade is never drawn shallower than this.",
            val: 3,
            from: 0,
            to: 10,
            step: 0.5
        },
        {
            label: "idle mark",
            prop: "idleMarkPx",
            group: "Countdown",
            blurb: "The group's colour lives in the card's inset shadow.",
            tip: "Width of the group colour's sliver at the left of the inset at rest -- the row stripe's job, in the inset (ListSectionHeader's idle mark). A counting toast withdraws it: the colour fills the inset and drains to nothing at the deadline.",
            val: 12,
            from: 0,
            to: 30,
            step: 1
        },
        {
            label: "drain step",
            prop: "drainStepPx",
            group: "Countdown",
            tip: "The countdown drain moves in steps of this many whole device pixels of the shade's boundary, each one a frame of the whole bar surface (Qt Quick has no damage regions). 1 is the gradient advancing pixel by pixel (the default: 4 was visibly choppy); a toast so short that a pixel falls due faster than the 16 ms timer floor takes the fewest whole pixels the floor allows. A bigger step is fewer frames and a coarser drain. tools/dev/toast_drain_probe.sh measures the steps and the frames.",
            val: 1,
            from: 1,
            to: 12,
            step: 1
        },
        {
            label: "shade depth idle",
            prop: "shadeIdleWidth",
            group: "Countdown",
            tip: "How deep the group colour reaches into the carve at rest (the idle sliver's inset). 7.5, the system update header's resting depth (ShadowBox \"Idle and active shapes\" -- the look the user asked for); drawn at least as deep as the card's shadow.",
            val: 7.5,
            from: 0,
            to: 20,
            step: 0.5
        },
        {
            label: "shade depth active",
            prop: "shadeActiveWidth",
            group: "Countdown",
            tip: "How deep the colour reaches while a toast counts down. 7, the system update header's running depth.",
            val: 7,
            from: 0,
            to: 20,
            step: 0.5
        },
        {
            label: "shade feather",
            prop: "shadeFeatherPx",
            group: "Countdown",
            tip: "The feather of the colour's leading edge, at rest and counting alike: the drain's edge fades over this many px. 12 -- which is why a 4 px drain step still glides.",
            val: 12,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "shade edge idle",
            prop: "shadeIdleEdgeAlpha",
            group: "Countdown",
            tip: "The colour's strength at the carve's edge at rest. 0.55: the resting sliver is a mark, not a fill.",
            val: 0.55,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "shade edge active",
            prop: "shadeActiveEdgeAlpha",
            group: "Countdown",
            tip: "The colour's strength at the edge while counting down. 1: the countdown reads at a glance.",
            val: 1,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "shade falloff idle",
            prop: "shadeIdleFalloff",
            group: "Countdown",
            tip: "How fast the colour fades from the edge inward at rest (1 = the carve's own shadow falloff). 0.9: a touch softer than the shadow.",
            val: 0.9,
            from: 0.1,
            to: 3,
            step: 0.05
        },
        {
            label: "shade falloff active",
            prop: "shadeActiveFalloff",
            group: "Countdown",
            tip: "The same while counting down. 1, the carve's own falloff.",
            val: 1,
            from: 0.1,
            to: 3,
            step: 0.05
        },
        {
            label: "shade blend end",
            prop: "shadeBlendEnd",
            group: "Countdown",
            tip: "The countdown fraction by which the resting shape (depth, strength, falloff) has fully become the running one. 0.32, the system update header's blend: the change is over early and the drain itself reads clean.",
            val: 0.32,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "line gap",
            prop: "lineGap",
            group: "Inside",
            blurb: "Inside the card: the text column, the transfer rail, the picture band, the chevron.",
            tip: "Space between the text column's lines (summary, body, footnote, rail). 4: the lines read as one block.",
            val: 4,
            from: 0,
            to: 12,
            step: 1
        },
        {
            label: "summary gap",
            prop: "metaGap",
            group: "Inside",
            tip: "The least space between the summary and the \"App · 3 min\" block on its line; the summary elides before it. 8.",
            val: 8,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "meta item gap",
            prop: "metaItemGap",
            group: "Inside",
            tip: "Between the items of the \"App · 3 min\" line (name, dot, time, pin). 4.",
            val: 4,
            from: 0,
            to: 12,
            step: 1
        },
        {
            label: "app name cap",
            prop: "appNameMaxWidth",
            group: "Inside",
            tip: "The widest the app's name gets on that line before it elides. 110: a long name (\"KDE Connect\") yields to the summary instead of taking the line.",
            val: 110,
            from: 40,
            to: 240,
            step: 2
        },
        {
            label: "rail height",
            prop: "progressHeight",
            group: "Inside",
            tip: "The transfer rail (a sender's value hint, KDE Connect's file). 6, the shell's groove height.",
            val: 6,
            from: 2,
            to: 14,
            step: 1
        },
        {
            label: "picture radius",
            prop: "pictureRadius",
            group: "Inside",
            tip: "The corner of a picture band (a screenshot). 8: inside a 14 px card, 6 px nearer than the card's own curve -- the two curves nest.",
            val: 8,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "picture min height",
            prop: "pictureMinHeight",
            group: "Inside",
            tip: "The least height of a picture band (a screenshot). Between this and the picture height below the band follows the picture's own aspect ratio at the card's width; beyond them the picture is cropped at its middle, never stretched. 72: a 21:9 screenshot at a toast's width still reads as one.",
            val: 72,
            from: 40,
            to: 160,
            step: 2
        },
        {
            label: "picture height",
            prop: "pictureMaxHeight",
            group: "Inside",
            tip: "Tallest a picture band (a screenshot) may be, under the text, full width. Between the least above and this the band follows the picture's own aspect ratio; a taller picture is cropped at its middle. 160: the user's (a 16:9 screenshot at the manager's width fits whole; the card stays a notification, not a viewer).",
            val: 160,
            from: 60,
            to: 400,
            step: 10
        },
        {
            label: "chevron",
            prop: "expandChevronSize",
            group: "Inside",
            tip: "The chevron that unfolds an elided body in the manager. 11, figure-sized: it points, it does not announce.",
            val: 11,
            from: 6,
            to: 20,
            step: 1
        },
        {
            label: "chevron stroke",
            prop: "expandChevronStroke",
            group: "Inside",
            tip: "That chevron's stroke. 1.5, the shell's Chevron.",
            val: 1.5,
            from: 0.5,
            to: 4,
            step: 0.25
        },
        {
            label: "button height",
            prop: "actionHeight",
            group: "Actions",
            blurb: "The card's action buttons (raised, standing proud of the carved card) and the inline reply.",
            tip: "An action button's height. 30, RaisedButton's own: every raised button of the shell stands the same.",
            val: 30,
            from: 20,
            to: 44,
            step: 1
        },
        {
            label: "button gap",
            prop: "actionGap",
            group: "Actions",
            tip: "Between two action buttons. 6, the list row inset.",
            val: 6,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "inline buttons",
            prop: "maxInlineActions",
            group: "Actions",
            tip: "Buttons shown before the rest go under \"...\". 3: three words fit a 360 px toast; the inline reply takes one of the three.",
            val: 3,
            from: 1,
            to: 6,
            step: 1
        },
        {
            label: "button radius",
            prop: "actionRadius",
            group: "Actions",
            tip: "An action button's corner. 7, half the card's 14: a smaller box of the same material.",
            val: 7,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "button padding",
            prop: "actionPadX",
            group: "Actions",
            tip: "Space either side of a button's label. 10.",
            val: 10,
            from: 2,
            to: 24,
            step: 1
        },
        {
            label: "button shadow",
            prop: "cardButtonShadowWidth",
            group: "Actions",
            tip: "An action button's drop shadow: it stands proud of the card, and the shadow eases to alpha because the card slides over the well while it is swiped. 4, one under the shell's buttons' 5 (RaisedButton): a smaller box of the same material.",
            val: 4,
            from: 0,
            to: 10,
            step: 0.5
        },
        {
            label: "button least width",
            prop: "cardButtonMinWidth",
            group: "Actions",
            tip: "The narrowest an action button gets, so a one-word label (\"OK\") is still a button to hit. 40, where the shell's own buttons keep 64: three buttons fit a 360 px toast (inline buttons).",
            val: 40,
            from: 20,
            to: 120,
            step: 1
        },
        {
            label: "row padding",
            prop: "actionRowPadY",
            group: "Actions",
            tip: "Space above and below the button row, inside the text column. 2: the buttons' drop shadows are not flush with the body above.",
            val: 2,
            from: 0,
            to: 10,
            step: 1
        },
        {
            label: "reply height",
            prop: "replyFieldHeight",
            group: "Actions",
            tip: "The inline reply's field (KDE Connect's Reply). 28: a text line and its carve, a little under a button.",
            val: 28,
            from: 20,
            to: 44,
            step: 1
        }
    ]
    // The service's own constants (NotificationService): what an image is.
    readonly property var serviceParams: [
        {
            label: "avatar max",
            prop: "avatarMax",
            group: "Inside",
            blurb: "When an image is an avatar beside the text rather than a picture under it.",
            tip: "An image at most this many px on both sides and roughly square is an avatar beside the text; anything else is a picture band under it (NotificationService, NotifyPolicy.imageKind). 128: a contact photo, not a screenshot.",
            val: 128,
            from: 16,
            to: 512,
            step: 8
        }
    ]
    // The toast scheduler's constants (ToastScheduler).
    readonly property var toastParams: [
        {
            label: "expiry stagger ms",
            prop: "staggerMs",
            group: "Toast",
            blurb: "How a burst of toasts leaves.",
            tip: "Two toasts never expire closer together than this, so a burst leaves one by one (ToastScheduler). 300 ms.",
            val: 300,
            from: 0,
            to: 2000,
            step: 50,
            promote: { to: "ToastScheduler.staggerMs" }
        }
    ]
    readonly property var styleParams: [
        {
            label: "toast width",
            prop: "toastWidth",
            group: "Toast",
            blurb: "The stack of toasts (theNotification).",
            tip: "Width of every toast card. 360 is mako's 342 plus room for the icon column; the stack's own padding adds 12 per side.",
            val: 360,
            from: 260,
            to: 520,
            step: 2
        },
        {
            label: "padding",
            prop: "toastPadding",
            group: "Toast",
            tip: "Space between the stack's edge and its cards, the same on every side. 12, the shell's popup padding. A swiped card's side fade needs room: its short ramp runs from the lead to where a resting card begins, so the stack never lays out with less than 5 px of it in any row -- 10 at a 20 px corner, 11 at 32: a value below that lays out at that.",
            val: 12,
            from: 0,
            to: 32,
            step: 1
        },
        {
            label: "gap",
            prop: "toastGap",
            group: "Toast",
            tip: "Space between two cards. 6, the list row inset.",
            val: 6,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "row slack",
            prop: "toastRowSlack",
            group: "Toast",
            tip: "How far the rows' clip reaches above and below the cards. 2: a carved card draws its bevel 1 px outside itself, and a clip on that line would shear it (CLAUDE.md).",
            val: 2,
            from: 0,
            to: 8,
            step: 1
        },
        {
            label: "+N more size",
            prop: "stackFootSize",
            group: "Toast",
            tip: "The stack's \"+N more\" foot. 11, the shell's figures size: it is a count.",
            val: 11,
            from: 7,
            to: 18,
            step: 1
        },
        {
            label: "enter / close ms",
            prop: "enterMs",
            group: "Motion",
            blurb: "One clock per motion: a row's extent, with the host's own resize ease.",
            tip: "How long a card takes to open its slot or close it. 260 ms OutCubic, the shell's resize ease, so the card and the popup's box arrive together. The manager's single arrival grows its room on the same clock.",
            val: 260,
            from: 80,
            to: 800,
            step: 10
        },
        {
            label: "presence ms",
            prop: "presenceMs",
            group: "Motion",
            tip: "The fade of a card's presence (only presence fades; text swaps are instant). 160 ms, the shell's presence fade. The manager's arrival fades on it too.",
            val: 160,
            from: 60,
            to: 600,
            step: 10
        },
        {
            label: "+N more hover ms",
            prop: "footHoverMs",
            group: "Motion",
            tip: "The \"+N more\" foot's hover fade, faint to the accent: the words are the link, and nothing but that colour and the hand cursor announces it. 120 ms, the shell's short fade for an affordance (the bell's hover too).",
            val: 120,
            from: 0,
            to: 400,
            step: 10
        }
    ]
    readonly property var styleManager: [
        {
            label: "width",
            prop: "managerWidth",
            group: "Layout",
            blurb: "The list of every notification (thePopup).",
            tip: "Width of the manager popup; its cards are this less the padding on both sides. 420: a toast card (360) plus room for a group header's figures.",
            val: 420,
            from: 320,
            to: 640,
            step: 2
        },
        {
            label: "list height",
            prop: "maxListHeight",
            group: "Layout",
            tip: "Tallest the list grows before it scrolls. 560: about eight cards, and the popup stays under two thirds of a 1080 px screen.",
            val: 560,
            from: 200,
            to: 900,
            step: 10
        },
        {
            label: "padding",
            prop: "managerPadding",
            group: "Layout",
            tip: "Space round the top row and the list, the same on every side (measured 12 / 12 in the box the content gets). 12, the shell's popup padding. Under 8 with a 32 px corner the resting list's last card pokes ~2 px out of the rounded foot (R2E-MGR1's open question: stop the knob at 8, or round up only when the corner needs it).",
            val: 12,
            from: 4,
            to: 24,
            step: 1
        },
        {
            label: "group gap",
            prop: "sectionGap",
            group: "Layout",
            tip: "A group header's margin above and below its box: 12 between two groups (two margins), 6 from a header to its first card.",
            val: 6,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "row gap",
            prop: "rowGap",
            group: "Layout",
            tip: "Space under every card: 6 between two cards of a group, the list row inset. Each row carries its gap in its own room, so an arriving row brings its gap with it.",
            val: 6,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "button gap",
            prop: "buttonGap",
            group: "Layout",
            tip: "Between the do-not-disturb toggle and Clear all. 12, the popup padding: Clear all coming back pushes the toggle aside by its width plus exactly this.",
            val: 12,
            from: 0,
            to: 32,
            step: 1
        },
        {
            label: "title",
            prop: "managerTitle",
            group: "Title row",
            blurb: "The manager's top row: the title, do not disturb, Clear all / Undo, and the search the keyboard types into.",
            tip: "The title while the manager holds notifications. \"Notifications\" (the user's words, round 2).",
            val: "Notifications",
            kind: "text"
        },
        {
            label: "empty title",
            prop: "emptyTitle",
            group: "Title row",
            tip: "The title when there is nothing -- the only words an empty manager shows (the user's round 2: no separate empty text, and the popup is the top row).",
            val: "No notifications",
            kind: "text"
        },
        {
            label: "title size",
            prop: "managerTitleSize",
            group: "Title row",
            tip: "The title's size. 16, the shell's popup title (Type: title 16 bold).",
            val: 16,
            from: 10,
            to: 24,
            step: 1
        },
        {
            label: "dnd label",
            prop: "dndLabelSize",
            group: "Title row",
            tip: "The do-not-disturb label beside its toggle. 11, figures size: a caption, not a title.",
            val: 11,
            from: 7,
            to: 16,
            step: 1
        },
        {
            label: "search glyph",
            prop: "searchGlyphSize",
            group: "Title row",
            tip: "The search glyph that stands before a typed filter. 14: between the title and the label.",
            val: 14,
            from: 8,
            to: 24,
            step: 1
        },
        {
            label: "button label",
            prop: "headerButtonTextSize",
            group: "Title row",
            tip: "Clear all / Undo's label. 12, RaisedButton's own label size.",
            val: 12,
            from: 8,
            to: 16,
            step: 1
        },
        {
            label: "button height",
            prop: "headerButtonHeight",
            group: "Title row",
            tip: "Clear all / Undo's height. 30, RaisedButton's own: the top row's one button stands as every raised button does.",
            val: 30,
            from: 20,
            to: 44,
            step: 1
        },
        {
            label: "dnd label gap",
            prop: "dndLabelGap",
            group: "Title row",
            tip: "Between the do-not-disturb label's box and the toggle's. 10 leaves 6 empty pixel columns between the label's ink and the groove's (measured), the gap round 1 drew: GrooveToggle lost its 2 px of slack in round 2, so the old 8 would bring them to 4.",
            val: 10,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "title gap",
            prop: "titleGap",
            group: "Title row",
            tip: "The least space between the title and the do-not-disturb label; the title elides before it. 12, the popup padding.",
            val: 12,
            from: 0,
            to: 32,
            step: 1
        },
        {
            label: "search gap",
            prop: "searchGlyphGap",
            group: "Title row",
            tip: "Between the search glyph and the typed query. 6.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "header title",
            prop: "headerTitleSize",
            group: "Group header",
            blurb: "A group's header (Critical, System, Normal, Low): a carved box of the list, rounded like the cards (card radius).",
            tip: "The header's title. 14: between the cards' 12 and the popup's 16 title.",
            val: 14,
            from: 10,
            to: 20,
            step: 1
        },
        {
            label: "header subtitle",
            prop: "headerSubtitleSize",
            group: "Group header",
            tip: "Its \"3 · newest\" line. 11, figures size.",
            val: 11,
            from: 7,
            to: 16,
            step: 1
        },
        {
            label: "header chevron",
            prop: "headerChevronSize",
            group: "Group header",
            tip: "Its fold chevron. 14, the title's size.",
            val: 14,
            from: 8,
            to: 20,
            step: 1
        },
        {
            label: "box padding x",
            prop: "headerPadX",
            group: "Group header",
            tip: "The header box's padding left and right. 11 (Layout numbers: header box padding 11 x 8).",
            val: 11,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "box padding y",
            prop: "headerPadY",
            group: "Group header",
            tip: "The header box's padding above and below. 8 (Layout numbers: 11 x 8).",
            val: 8,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "scroll fade",
            prop: "listFadeHeight",
            group: "List",
            blurb: "The scrolling list (ScrollDressing).",
            tip: "The list's top and bottom scroll fades, and the long ramp of a card swiped sideways in the list (its side fade: \"just like most scrollable lists\"). 34, ScrollDressing's own: a row half under the fade reads as going on, not cut.",
            val: 34,
            from: 0,
            to: 80,
            step: 1
        },
        {
            label: "notch px",
            prop: "listScrollStep",
            group: "List",
            tip: "How far one wheel notch scrolls the list, in px. 120 = ScrollDressing's own speed (1.0): a notch is about two thirds of a card.",
            val: 120,
            from: 24,
            to: 480,
            step: 12
        },
        {
            label: "ring width",
            prop: "highlightWidth",
            group: "Highlight",
            blurb: "The keyboard's ring round the current card (arrows move it, Enter acts).",
            tip: "The ring's stroke. 1.5, the shell's hairline accent.",
            val: 1.5,
            from: 0.5,
            to: 4,
            step: 0.25
        },
        {
            label: "ring offset",
            prop: "highlightInset",
            group: "Highlight",
            tip: "How far outside the card the ring sits. 2: clear of the card's 1 px bevel.",
            val: 2,
            from: 0,
            to: 8,
            step: 0.5
        },
        {
            label: "ring strength",
            prop: "highlightAlpha",
            group: "Highlight",
            tip: "The ring's opacity. 0.8: the accent, a little under full, so it marks without outshouting a critical's colour.",
            val: 0.8,
            from: 0.1,
            to: 1,
            step: 0.05
        },
        {
            label: "ring ms",
            prop: "highlightMs",
            group: "Highlight",
            tip: "The ring's fade as the keyboard moves on. 120 ms: quick, but a fade and not a jump.",
            val: 120,
            from: 0,
            to: 400,
            step: 10
        },
        {
            label: "row ms",
            prop: "rowAnimMs",
            group: "Motion",
            blurb: "The list's wave (list_animation.md) and the manager's other clocks.",
            tip: "How long one row takes to slide in or out when a group opens or folds, and on Clear all / Undo. 240 ms, the shell's list rows.",
            val: 240,
            from: 80,
            to: 600,
            step: 10
        },
        {
            label: "stagger ms",
            prop: "staggerMs",
            group: "Motion",
            tip: "Delay between two rows of a wave. 55 ms, the shell's list stagger.",
            val: 55,
            from: 0,
            to: 150,
            step: 5
        },
        {
            label: "button ms",
            prop: "buttonMs",
            group: "Motion",
            tip: "Clear all coming back (and going): its width, the gap before it and its opacity on one clock. 260 ms, the resize ease.",
            val: 260,
            from: 80,
            to: 600,
            step: 10
        },
        {
            label: "follow the foot",
            prop: "followOpen",
            group: "Motion",
            tip: "Opening a group at the very bottom of a scrolled list scrolls with its rows until the header would pass under the top fade (list_animation.md, the user's rule). Off: the group opens below the fold.",
            val: true
        },
        {
            label: "settle frames",
            prop: "liveSettleFrames",
            group: "Motion",
            tip: "Still frames the content waits before it stops being live (while live, the engine follows its size frame by frame instead of easing to it). 2: a stepped ease can hold one frame still between two steps, never two.",
            val: 2,
            from: 1,
            to: 10,
            step: 1
        },
        {
            label: "lift ms",
            prop: "flightLiftMs",
            group: "Pin flight",
            blurb: "A pinned card flies to the top of its group (RowFlight): lift, travel, land.",
            tip: "The card rising off the list (scale up, shadow in). 160 ms: long enough to read as a lift before it moves.",
            val: 160,
            from: 40,
            to: 600,
            step: 10
        },
        {
            label: "travel ms",
            prop: "flightTravelMs",
            group: "Pin flight",
            tip: "The lifted card travelling to its new place (shorter hops are scaled down). 340 ms: RowFlight's tuned travel for a list of this density.",
            val: 340,
            from: 100,
            to: 1000,
            step: 10
        },
        {
            label: "land ms",
            prop: "flightLandMs",
            group: "Pin flight",
            tip: "The card settling into its place (scale and shadow back). 160 ms, the lift's mirror.",
            val: 160,
            from: 40,
            to: 600,
            step: 10
        },
        {
            label: "lift scale",
            prop: "flightLiftScale",
            group: "Pin flight",
            tip: "How much the lifted card grows. 1.03: enough to read as nearer, small enough that the text does not visibly resample. It eats the same 12 px padding as the shadow: at 1.03 a 396 px row already grows 5.9 px past its slot on each side, at 1.055 10.9 px and no shadow fits.",
            val: 1.03,
            from: 1,
            to: 1.1,
            step: 0.005
        },
        {
            label: "pre-move ms",
            prop: "flightPreMoveDelayMs",
            group: "Pin flight",
            tip: "The beat between the lift and the travel. 100 ms: the eye registers the lift as a step of its own.",
            val: 100,
            from: 0,
            to: 400,
            step: 10
        },
        {
            label: "pre-drop ms",
            prop: "flightPreDropDelayMs",
            group: "Pin flight",
            tip: "The beat between the travel and the landing. 100 ms, the pre-move's mirror.",
            val: 100,
            from: 0,
            to: 400,
            step: 10
        },
        {
            label: "shadow spread",
            prop: "flightShadowSpread",
            group: "Pin flight",
            tip: "How far the lifted card's shadow rect reaches past it at the sides (its drop scales with it). 1: with the blur, the shadow stays inside the manager's 12 px padding -- measured side 11, foot 7 (R2C-FIX; the rule is 1.03 x spread + blur <= 6). RowFlight's own 10 / 24 reached 41 px, past the popup's rounded corners.",
            val: 1,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "shadow blur",
            prop: "flightShadowBlur",
            group: "Pin flight",
            tip: "The lifted card's shadow blur (its radius, px). 4: with spread 1 the shadow ends inside the 12 px padding and still reads as height, not as an outline.",
            val: 4,
            from: 0,
            to: 32,
            step: 1
        }
    ]
    readonly property var styleSwipe: [
        {
            label: "commit at",
            prop: "swipeCommitFraction",
            group: "Commit",
            blurb: "SwipeVerbCard: every toast, manager row and group header.",
            tip: "How far past the card's width (a share of it) a release commits the verb. 0.4: far enough that a stray drag springs back, near enough to reach with one stroke.",
            val: 0.4,
            from: 0.15,
            to: 0.8,
            step: 0.01
        },
        {
            label: "max give",
            prop: "swipeMaxFraction",
            group: "Commit",
            tip: "Where the card's travel saturates past the commit line (a share of the width): the rest of the gesture reads as effort. 0.8: the verb's band is wide open, the card never fully leaves under the fingers.",
            val: 0.8,
            from: 0.4,
            to: 1,
            step: 0.01
        },
        {
            label: "fling px/s",
            prop: "swipeFlingPxPerS",
            group: "Commit",
            tip: "A release this fast the way the card is displaced commits even short of the line. 900 px/s: a flick, not a slow drag let go.",
            val: 900,
            from: 200,
            to: 3000,
            step: 50
        },
        {
            label: "drag threshold",
            prop: "swipeDragThreshold",
            group: "Commit",
            tip: "Pixels a left-button drag must travel before it is a swipe rather than a click. 6: under it a press is a click on the card or its buttons.",
            val: 6,
            from: 1,
            to: 20,
            step: 1
        },
        {
            label: "blocked give",
            prop: "swipeBlockedGivePx",
            group: "Commit",
            tip: "How far a card gives toward a side it has no verb for (a critical cannot be filed) before it springs back. 24: enough to feel the refusal, too little to read as a swipe.",
            val: 24,
            from: 0,
            to: 80,
            step: 1
        },
        {
            label: "fly ms",
            prop: "swipeFlyMs",
            group: "Motion",
            blurb: "The card's clocks: flying off, springing back, a pin's swing.",
            tip: "A whole width at the card's own speed: the fly-off, and the cap on how fast the drawn card chases the fingers. 260 ms, the resize ease.",
            val: 260,
            from: 80,
            to: 800,
            step: 10
        },
        {
            label: "spring ms",
            prop: "swipeSpringMs",
            group: "Motion",
            tip: "The card springing back when a release does not commit (and a pin's return). 260 ms OutCubic.",
            val: 260,
            from: 80,
            to: 800,
            step: 10
        },
        {
            label: "swing ms",
            prop: "swipeSwingMs",
            group: "Motion",
            tip: "A pin committed from short of the line swings out to the line before it springs back. 120 ms: a nod, not a second swipe.",
            val: 120,
            from: 40,
            to: 400,
            step: 10
        },
        {
            label: "fade from",
            prop: "swipeFadeFrom",
            group: "Look",
            blurb: "The face as it leaves, and the carved well with the verb's glyph that it uncovers.",
            tip: "On a side that flies off, the face stays opaque up to this share of the width and is gone at the whole width. 0.45: just past the commit line the card is already going.",
            val: 0.45,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "verb glyph",
            prop: "swipeGlyphSize",
            group: "Look",
            tip: "The verb's glyph in the uncovered well (file, delete, pin, clear). 20, the icon size of the bar's glyphs.",
            val: 20,
            from: 10,
            to: 32,
            step: 1
        },
        {
            label: "glyph inset",
            prop: "swipeGlyphInset",
            group: "Look",
            tip: "How far the glyph keeps from the well's edge while the band is still narrow. 12, the card padding.",
            val: 12,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "well shadow",
            prop: "swipeWellShadowWidth",
            group: "Look",
            tip: "The carved well's inset shadow: one step deeper than the card's own 3, so the uncovered band reads as below the card.",
            val: 4,
            from: 0,
            to: 10,
            step: 0.5
        },
        {
            label: "well bevel",
            prop: "swipeWellBevelWidth",
            group: "Look",
            tip: "The carved well's light rim. 1, the containers' bevel: the well is carved like a card.",
            val: 1,
            from: 0,
            to: 4,
            step: 0.5
        },
        {
            label: "units",
            prop: "swipeUnits",
            group: "Fingers",
            blurb: "SwipeVerbReader: the two-finger swipe over the stack and the list (a swipe is a wheel, gestures.md).",
            tip: "Wheel units of finger travel that carry a card to its commit line. 900: about the same hand motion as the view switcher's swipes.",
            val: 900,
            from: 200,
            to: 3000,
            step: 50
        },
        {
            label: "fling units/s",
            prop: "swipeFlingUnitsPerS",
            group: "Fingers",
            tip: "Finger speed at the lift that counts as a fling (converted to the card's fling px/s). 2600: a flick of the fingers commits, a slow lift does not.",
            val: 2600,
            from: 500,
            to: 8000,
            step: 100
        },
        {
            label: "pull-through",
            prop: "swipePullThrough",
            group: "Fingers",
            tip: "Fingers this many commit distances past the start commit at once, without waiting for the lift. 2.0: an unmistakable pull.",
            val: 2,
            from: 1,
            to: 4,
            step: 0.1
        },
        {
            label: "lift idle ms",
            prop: "swipeIdleMs",
            group: "Fingers",
            tip: "A touchpad lifts with a zero-delta wheel event; for one that never sends it, the gesture ends after this long without motion. 6000: long enough never to cut a slow swipe.",
            val: 6000,
            from: 500,
            to: 10000,
            step: 100
        },
        {
            label: "mouse idle ms",
            prop: "swipeMouseIdleMs",
            group: "Fingers",
            tip: "A mouse's tilt has no fingers to lift: its gesture ends after this long. 400: a 6 s latch would swallow the next tilt and strand a card half-swiped.",
            val: 400,
            from: 100,
            to: 2000,
            step: 50
        },
        {
            label: "sign",
            prop: "swipeSign",
            group: "Fingers",
            tip: "Which way is right in wheel units: 1 for natural scrolling (fingers moving right send +x here), -1 flips it. Still to be confirmed on the desktop.",
            val: 1,
            from: -1,
            to: 1,
            step: 2
        },
        {
            label: "clip inset",
            prop: "sideFadeInset",
            group: "Side fades",
            blurb: "SideFade: where a card swiped sideways is cut, and how it fades out before the cut. It paints nothing: the displaced card cuts and fades itself (SideCut), and a resting card is never touched.",
            tip: "The rows' clip line: straight, this far in from the popup's edge on both sides, a whole pixel (rounded), the same at every corner radius -- 2 at a 20 px corner and at 32. A displaced card is cut there in the straight rows; in a corner's rows the cut follows the rounded outline instead (corner margin). 2, SideFade's default: a pixel further in than the corner margin puts the cut, so in the straight rows a card's last column stays clear of the popup's rim.",
            val: 2,
            from: 0,
            to: 8,
            step: 1
        },
        {
            label: "rim",
            prop: "sideFadeRimPx",
            group: "Side fades",
            tip: "How far a resting card draws outside its own rect (its carved bevel lies 1 px out): the short ramp ends that far before where a resting card begins, so it lies over nothing a resting card draws and a swipe's first pixel changes a pixel's worth. The short ramp is the layout's: 7 px at a 12 px padding (padding - clip inset - lead - rim). 2.",
            val: 2,
            from: 0,
            to: 6,
            step: 1
        },
        {
            label: "lead",
            prop: "sideFadeLeadPx",
            group: "Side fades",
            tip: "Fully clear from the zero line in -- the clip line in a straight row, the rounded cut in a corner's rows -- so the column the cut runs through never shows the card; both ramps start after it. 1.",
            val: 1,
            from: 0,
            to: 4,
            step: 1
        },
        {
            label: "corner margin",
            prop: "sideFadeCornerMargin",
            group: "Side fades",
            tip: "How far inside the popup's rounded outline the cut lies: the outline shrunk by this, per pixel row, so a card pushed under a corner follows the curve. 1: the popup's own antialiased rim reaches about that far in (coverage 0.89 at 0.55 px inside a 20 px curve, whole from 0.9), so a displaced card never lands on it.",
            val: 1,
            from: 0,
            to: 4,
            step: 0.5
        },
        {
            label: "toast ramp",
            prop: "sideFadeLength",
            group: "Side fades",
            tip: "The toast stack's long ramp, from the lead in: a swiped card fades over this length, the more the further it is displaced (strength |offset| / length). The short ramp, from the lead to where a resting card begins, is what takes it to nothing at the cut; the long one lies over the card's own rest, so it can be as long as the list's fade: 34, ScrollDressing's. The manager's long ramp is its list's scroll fade (Manager, List).",
            val: 34,
            from: 8,
            to: 80,
            step: 1
        }
    ]
    readonly property var hostParams: [
        {
            label: "popup radius",
            prop: "maxR",
            group: "Engine",
            blurb: "The bar engine's own value (every popup's), here because a swiped card's side cut follows it.",
            tip: "The popups' resting corner radius (GooeyEngine maxR). The owner hands it to the toast stack (cornerRadius) and the manager (popupRadius): a displaced card's side cut and the manager's flight cut follow that curve per pixel row, and the stack's least padding grows with it (Toast, padding). The rows' clip line does not move (Swipe, Side fades, clip inset). 20, the engine's default.",
            val: 20,
            from: 8,
            to: 32,
            step: 1
        }
    ]
    readonly property var styleBell: [
        {
            label: "glyph",
            prop: "bellGlyphSize",
            group: "Bell",
            blurb: "The bar's bell (NotificationsBarButton): the glyph, coloured by the newest unseen group, and its padding. Its hover is the bar's one clock and hue (BarHues).",
            tip: "The bell glyph. 16, the bar's glyph size.",
            val: 16,
            from: 10,
            to: 28,
            step: 1
        },
        {
            label: "padding along",
            prop: "bellPadX",
            group: "Bell",
            tip: "Padding either side of the glyph along the bar. 8.",
            val: 8,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "padding across",
            prop: "bellPadY",
            group: "Bell",
            tip: "Padding across the bar. 4.",
            val: 4,
            from: 0,
            to: 12,
            step: 1
        }
    ]
    // The bell's flourish (NotificationsBarButton, BellPose.js): its switch and its length.
    readonly property var bellFlourish: [
        {
            label: "ring",
            prop: "flourishEnabled",
            group: "Flourish",
            blurb: "The bell RINGS: a quick, bouncy swing about its crown with the clapper hanging late behind it. It plays on every new notification -- under do not disturb, a share or fullscreen too -- and when the pointer comes onto the bell (once per entry). A notification while it rings re-strikes it: the swing lifts back to full where it stands, so a burst rings longer, never harder. Post a few from the Run tab to see it.",
            tip: "Off: the bell never moves; a new notification is its colour alone.",
            val: true
        },
        {
            label: "ring ms",
            prop: "flourishMs",
            group: "Flourish",
            tip: "How long one strike rings, ms: the swing dies inside it (four or five swings you can see, the first the widest) and a re-strike rings this long after itself. 900.",
            val: 900,
            from: 300,
            to: 2000,
            step: 10
        }
    ]
    readonly property var groupColors: [
        {
            label: "Critical",
            prop: "criticalLight",
            group: "Light theme",
            blurb: "Each group's colour in the light theme (the style's GroupPalette): the card's inset colour, the header's mark, the bell's dot. The two themes are set apart: a hex here changes this theme only, \"@<token>\" follows that theme token (the module's default), Reset puts the token back. The other theme's rows are in the other group; the theme on screen is the one the stage shows.",
            tip: "Critical in the light theme follows the theme's error (#EC0000 in light, #F14C4C in dark): a critical reads as an error at a glance (the user's pick). A hex gives it a colour of its own in the light theme only (the dark theme keeps its own row); @<token> follows another token. While the other theme is on screen the swatch shows what this row will be then.",
            themeMode: "light",
            val: "@error"
        },
        {
            label: "System",
            prop: "systemLight",
            group: "Light theme",
            tip: "System in the light theme follows the cyan category token (the system update's multilib colour, #00BEC4 in light): everything the shell raises. A hex gives it a colour of its own in the light theme only (the dark theme keeps its own row); @<token> follows another token. While the other theme is on screen the swatch shows what this row will be then.",
            themeMode: "light",
            val: "@catMultilib"
        },
        {
            label: "Normal",
            prop: "normalLight",
            group: "Light theme",
            tip: "Normal in the light theme follows the shell's accent: most notifications are normal, and the accent is the colour of \"yours\". A hex gives it a colour of its own in the light theme only (the dark theme keeps its own row); @<token> follows another token. While the other theme is on screen the swatch shows what this row will be then.",
            themeMode: "light",
            val: "@accent"
        },
        {
            label: "Low",
            prop: "lowLight",
            group: "Light theme",
            tip: "Low in the light theme follows the faint text colour: a low notification should recede. A hex gives it a colour of its own in the light theme only (the dark theme keeps its own row); @<token> follows another token. While the other theme is on screen the swatch shows what this row will be then.",
            themeMode: "light",
            val: "@textFaint"
        },
        {
            label: "Critical",
            prop: "criticalDark",
            group: "Dark theme",
            blurb: "Each group's colour in the dark theme (the style's GroupPalette): the card's inset colour, the header's mark, the bell's dot. The two themes are set apart: a hex here changes this theme only, \"@<token>\" follows that theme token (the module's default), Reset puts the token back. The other theme's rows are in the other group; the theme on screen is the one the stage shows.",
            tip: "Critical in the dark theme follows the theme's error (#EC0000 in light, #F14C4C in dark): a critical reads as an error at a glance (the user's pick). A hex gives it a colour of its own in the dark theme only (the light theme keeps its own row); @<token> follows another token. While the other theme is on screen the swatch shows what this row will be then.",
            themeMode: "dark",
            val: "@error"
        },
        {
            label: "System",
            prop: "systemDark",
            group: "Dark theme",
            tip: "System in the dark theme follows the cyan category token (the system update's multilib colour, #00BEC4 in light): everything the shell raises. A hex gives it a colour of its own in the dark theme only (the light theme keeps its own row); @<token> follows another token. While the other theme is on screen the swatch shows what this row will be then.",
            themeMode: "dark",
            val: "@catMultilib"
        },
        {
            label: "Normal",
            prop: "normalDark",
            group: "Dark theme",
            tip: "Normal in the dark theme follows the shell's accent: most notifications are normal, and the accent is the colour of \"yours\". A hex gives it a colour of its own in the dark theme only (the light theme keeps its own row); @<token> follows another token. While the other theme is on screen the swatch shows what this row will be then.",
            themeMode: "dark",
            val: "@accent"
        },
        {
            label: "Low",
            prop: "lowDark",
            group: "Dark theme",
            tip: "Low in the dark theme follows the faint text colour: a low notification should recede. A hex gives it a colour of its own in the dark theme only (the light theme keeps its own row); @<token> follows another token. While the other theme is on screen the swatch shows what this row will be then.",
            themeMode: "dark",
            val: "@textFaint"
        }
    ]
    readonly property var configParams: [
        {
            label: "low ms",
            prop: "timeoutsLow",
            group: "Timeouts",
            blurb: "notifications.jsonc `timeouts`: how long a toast stays, per urgency. 0 here is never (the file's -1).",
            tip: "A low toast's life. 4 s (the plan's pick): low is a glance.",
            val: 4000,
            from: 0,
            to: 30000,
            step: 500
        },
        {
            label: "normal ms",
            prop: "timeoutsNormal",
            group: "Timeouts",
            tip: "A normal toast's life. 8 s (the plan's pick): time to read three lines.",
            val: 8000,
            from: 0,
            to: 30000,
            step: 500
        },
        {
            label: "critical ms",
            prop: "timeoutsCritical",
            group: "Timeouts",
            tip: "A critical toast's life. 0 = never (sticky, the plan's pick): a critical waits for you.",
            val: 0,
            from: 0,
            to: 60000,
            step: 500
        },
        {
            label: "clamp min ms",
            prop: "timeoutsClampMin",
            group: "Timeouts",
            tip: "A sender's own timeout is honoured but never shorter than this. 3 s: an app asking for 500 ms still gets a readable toast.",
            val: 3000,
            from: 0,
            to: 30000,
            step: 500
        },
        {
            label: "clamp max ms",
            prop: "timeoutsClampMax",
            group: "Timeouts",
            tip: "...and never longer than this. 60 s: an app asking for ten minutes does not park a toast on the screen.",
            val: 60000,
            from: 5000,
            to: 300000,
            step: 5000
        },
        {
            label: "max toasts",
            prop: "toastsMax",
            group: "Toasts",
            blurb: "notifications.jsonc `toasts`.",
            tip: "Toasts shown at once; older ones file into the manager (\"+N more\"). 5, the plan's pick.",
            val: 5,
            from: 1,
            to: 10,
            step: 1
        },
        {
            label: "flood count",
            prop: "toastsFloodCount",
            group: "Toasts",
            tip: "More than this many from one app inside the flood window, and the rest file silently (\"<app> · +N more\"). 3.",
            val: 3,
            from: 1,
            to: 10,
            step: 1
        },
        {
            label: "flood window ms",
            prop: "toastsFloodWindowMs",
            group: "Toasts",
            tip: "The flood rule's window. 10 s: a chat burst, not a day's traffic.",
            val: 10000,
            from: 1000,
            to: 60000,
            step: 1000
        },
        {
            label: "hover resume ms",
            prop: "toastsHoverResumeMinMs",
            group: "Toasts",
            tip: "After a hover (or being away) a toast has at least this long left, so it never vanishes the moment the pointer leaves. 2 s.",
            val: 2000,
            from: 0,
            to: 10000,
            step: 250
        },
        {
            label: "keep count",
            prop: "retentionCount",
            group: "History",
            blurb: "notifications.jsonc `retention` and `undoMs`: what the manager keeps. Pins are never dropped; -1 (no limit) is a file-only value.",
            tip: "The newest this many records are kept. 200 (the plan's pick).",
            val: 200,
            from: 10,
            to: 1000,
            step: 10
        },
        {
            label: "keep days",
            prop: "retentionDays",
            group: "History",
            tip: "None older than this many days since its last update. 7 (the plan's pick): a week of history.",
            val: 7,
            from: 1,
            to: 60,
            step: 1
        },
        {
            label: "undo ms",
            prop: "undoMs",
            group: "History",
            tip: "How long Undo is offered after Clear all or a group's clear (the button drains through it). 10 s, the plan's pick.",
            val: 10000,
            from: 1000,
            to: 60000,
            step: 500
        },
        {
            label: "idle ms",
            prop: "idleMs",
            group: "Away",
            blurb: "notifications.jsonc `idleMs`.",
            tip: "No input for this long = you are away: the toasts' countdowns stop until you are back. 60 s. (The mockup's idleness is the Run page's checkbox; this is the desktop's idle monitor.)",
            val: 60000,
            from: 5000,
            to: 600000,
            step: 5000
        },
        {
            label: "hold fullscreen",
            prop: "dndHoldFullscreen",
            group: "Holds",
            blurb: "notifications.jsonc `dnd`.",
            tip: "While a window is fullscreen the toasts are held and come back as one summary when it ends (a critical still shows). On, the plan's pick.",
            val: true
        },
        {
            label: "hold screen share",
            prop: "dndHoldScreencast",
            group: "Holds",
            tip: "While the screen is shared or recorded the toasts are held (a critical shows in full). On, the plan's pick: nothing private lands on a shared screen.",
            val: true
        },
        {
            label: "breakthrough",
            prop: "dndBreakthrough",
            group: "Holds",
            tip: "The shell's sources that still toast under do not disturb (criticals always do): a JSON list of source ids -- clock, stocks, launcher, llm, battery, update, network, bluetooth, auth, notifications. [\"clock\", \"auth\"], the plan's pick: a timer and a password prompt are not interruptions you chose to mute.",
            val: "[\"clock\",\"auth\"]",
            kind: "json",
            shape: "strings"
        },
        {
            label: "spot",
            prop: "spotCorner",
            group: "Spot",
            blurb: "notifications.jsonc `spot`: where the toasts appear -- a screen corner, or a point along a bar.",
            tip: "The corner the stack hangs from (the corners this mockup has a bar for: the edge's bar first, then its end), or \"along a bar\": the point below. top-right, the default.",
            val: 0,
            choices: ["top-right", "top-left", "right-top", "right-bottom", "along a bar"]
        },
        {
            label: "bar",
            prop: "spotBar",
            group: "Spot",
            tip: "With \"along a bar\": the bar the stack hangs from (`spot.bar`, a bar id). This mockup has two, top and right.",
            val: 0,
            choices: ["top", "right"]
        },
        {
            label: "along",
            prop: "spotAlong",
            group: "Spot",
            tip: "With \"along a bar\": where along that bar, 0 its start, 1 its end (`spot.along`). 0.5, the middle.",
            val: 0.5,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "low",
            prop: "soundsLow",
            group: "Sounds",
            blurb: "notifications.jsonc `sounds`: per urgency a JSON list of files; the FIRST that exists plays (paths may start with ~/), none = silent, [] = mute. Hear one on the page below.",
            tip: "A low notification's sound. [] (the plan's pick): low is silent.",
            val: "[]",
            kind: "json",
            shape: "strings"
        },
        {
            label: "normal",
            prop: "soundsNormal",
            group: "Sounds",
            tip: "A normal notification's sound: the first of these that exists. The user's own file first, then the system's -- until one is added it is silent, as mako was.",
            val: "[\"~/.local/share/sounds/notification.mp3\",\"/usr/share/sounds/notification.mp3\"]",
            kind: "json",
            shape: "strings"
        },
        {
            label: "critical",
            prop: "soundsCritical",
            group: "Sounds",
            tip: "A critical notification's sound: its own file first, then the normal ones. A critical held at the lock screen still sounds.",
            val: "[\"~/.local/share/sounds/notification-critical.mp3\",\"~/.local/share/sounds/notification.mp3\",\"/usr/share/sounds/notification.mp3\"]",
            kind: "json",
            shape: "strings"
        },
        {
            label: "apps",
            prop: "appsRules",
            group: "Rules",
            blurb: "notifications.jsonc `apps` and `sources`: rules per app (its desktop entry or name, case-insensitive) and per shell source, as JSON objects. Keys: mute, urgency, group, timeoutMs, sound (a path or \"none\"), history, focusSuppress. A rule merges over the code's own key by key.",
            tip: "Per-app rules, e.g. {\"discord\": {\"urgency\": \"low\"}, \"spotify\": {\"mute\": true}}. The code's own: kitty's focusSuppress off (a terminal's notification shows while it is focused) and the network applets' posts dropped (nm-applet, Blueman: the OSD tells the network and the bluetooth news) -- removing a rule here leaves the code's in force (the merge keeps it); set {\"drop\": false} on one to bring it back.",
            val: "{\"kitty\":{\"focusSuppress\":false},\"org.freedesktop.network-manager-applet\":{\"drop\":true},\"NetworkManager Applet\":{\"drop\":true},\"nm-applet\":{\"drop\":true},\"blueman\":{\"drop\":true},\"blueman-applet\":{\"drop\":true}}",
            kind: "json",
            shape: "rules"
        },
        {
            label: "sources",
            prop: "sourcesRules",
            group: "Rules",
            tip: "The same keys for the shell's own sources: clock, stocks, launcher, llm, battery, update, network, bluetooth, auth, notifications -- e.g. {\"stocks\": {\"timeoutMs\": 12000}}. {} by default: every source chooses its own.",
            val: "{}",
            kind: "json",
            shape: "rules"
        }
    ]
}
