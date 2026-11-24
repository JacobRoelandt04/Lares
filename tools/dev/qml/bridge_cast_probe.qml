pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io

import "modules/bridge"
import "modules/bridge/cast"
import "modules/bridge/data"
import "modules/bridge/screen"
import "modules/bridge/data/BridgeScenarios.js" as Scenarios

// =============================================================================
// bridge_cast_probe.qml -- CastSession + CastView (modules/bridge/cast/) on the REAL tools/bridge/lares-cast, behind a stub `adb` whose
// `shell` is a FAKE PHONE (tools/dev/stubs/bridge/fake_scrcpy_server.py: scrcpy 5.0.1's wire protocol, real H.264). Offscreen window,
// real synthetic input (QtTest). This file checks what the QML side sees (BCP a..h); the runner (bridge_cast_probe.sh) reads what the fake
// phone RECEIVED (touch / key / wheel bytes, RESET_VIDEO), the grabs this writes (the picture: not blank, moving, latency) and what is
// left behind, and prints `BRIDGE_CAST RESULT PASS|FAIL`. This prints `BCP RESULT PASS|FAIL (<n> checks)` for its own part.
// Smoked BARE (no BCP_WORK: no runner, so no stub adb) it starts NOTHING: `BCP skipped (no runner)` and a quit from a 0 ms Timer
// (it once started the user's real adb server).
// =============================================================================
Item {
    id: probe
    width: 10
    height: 10

    readonly property string work: Quickshell.env("BCP_WORK") || ""
    readonly property string serial: Quickshell.env("BCP_SERIAL") || "CASTSER"
    property int checks: 0
    property int fails: 0
    property int players: 0
    property int playersNow: 0
    property bool done: false

    function check(id: string, ok: bool, what: string): void {
        probe.checks++;
        if (!ok)
            probe.fails++;
        console.log("BCP " + (ok ? "ok  " : "FAIL ") + id + ": " + what);
    }
    function mark(name: string): void {
        console.log("BCP MARK " + name + " " + Date.now());
    }

    TestCase {
        id: tc
        name: "bcp"
        when: false
    }

    FileView {
        id: pauseFile
        path: probe.work + "/pause"
        printErrors: false
    }
    Process {
        id: unpause
        command: ["rm", "-f", probe.work + "/pause"]
    }
    Connections {
        target: view.videoSink
        function onVideoFrameChanged(): void {
            probe.frameCount++;
        }
    }
    FileView {
        id: rotFile
        path: probe.work + "/rotate"
        printErrors: false
    }

    Process {
        id: scan
        stdout: StdioCollector {
            id: scanOut
        }
    }

    Window {
        id: win
        visible: true
        width: 300
        height: 400
        color: "#202020"

        CastSession {
            id: cs
            serial: probe.serial
            audio: false
            onRecorded: ev => probe.recEv = ev
        }
        CastView {
            id: view
            anchors.fill: parent
            session: cs
        }
    }

    // ---- the cast PAGE's hold (h1-h3, r1-r2): the real CastPage on this session, a stand-in for the service's cast half
    // (BridgeService: castPhase "starting" while the session restarts, castHoldWhy "Resizing" until it is live again, "Reconnecting"
    // while an ended session is brought back, castUnlocking)
    QtObject {
        id: stubSvc
        property var castSession: cs
        property string castHoldWhy: ""
        readonly property bool castHolding: stubSvc.castHoldWhy !== ""
        property bool castUnlocking: false
        property bool castTurning: false
        readonly property string castPhase: stubSvc.castHoldWhy === "Reconnecting" ? "reconnecting" : (cs.state === "idle" ? "starting" : cs.state)
        readonly property string castReason: cs.reason
        readonly property string castMode: "mirror"
        property int holdReady: 0
        function castHoldReady(): void {
            stubSvc.holdReady++;
            if (stubSvc.castHoldWhy === "Resizing")
                cs.restart();
        }
        function castWantRoom(w: real, h: real, dpr: real): void {
        }
    }
    Connections {
        target: cs
        function onStateChanged(): void {
            if (cs.state === "live" && (stubSvc.castHoldWhy === "Resizing" || stubSvc.castHoldWhy === "Reconnecting"))
                stubSvc.castHoldWhy = "";
            else if (cs.state === "ended" && probe.reconnectStub)
                stubSvc.castHoldWhy = "Reconnecting";
        }
    }
    Window {
        id: pageWin
        visible: pageLoader.active
        width: 300
        height: 600
        color: "#202020"
        Loader {
            id: pageLoader
            anchors.fill: parent
            active: false
            sourceComponent: Component {
                CastPage {
                    service: stubSvc
                }
            }
        }
    }
    // ---- the input gate and the unlock trigger (l1-l7, u1): a CastView / CastPage on a SPY session (no phone: it records the calls the
    // view makes, and its lock / flow facts are the test's to set)
    QtObject {
        id: spy
        property string state: "live"
        property string url: ""
        property int videoWidth: 192
        property int videoHeight: 384
        property bool flowKnown: false
        property bool flowing: true
        property bool lockKnown: false
        property bool keyguard: false
        property bool awake: true
        property bool audio: false
        property var calls: []
        function touch(kind: string, x: real, y: real): void { spy.calls.push("touch " + kind + " " + Math.round(x) + "," + Math.round(y)); }
        function scroll(x: real, y: real, h: real, v: real): void { spy.calls.push("scroll"); }
        function key(name: string): void { spy.calls.push("key " + name); }
        function text(t: string): void { spy.calls.push("text " + t); }
        function wake(): void { spy.calls.push("wake"); }
        function keyframe(): void {}
        function screen(on: bool): void {}
    }
    property int spyUnlocks: 0
    Window {
        id: spyWin
        visible: true
        width: 300
        height: 400
        color: "#202020"
        CastView {
            id: spyView
            anchors.fill: parent
            session: spy
            onUnlockWanted: probe.spyUnlocks++
        }
    }
    QtObject {
        id: spySvc
        property var castSession: spy
        property string castPhase: "live"
        property string castReason: ""
        property string castMode: "mirror"
        property string castHoldWhy: ""
        property bool castHolding: false
        property bool castUnlocking: false
        property bool castTurning: false
        property var unlocks: []
        property var rooms: []
        // bridge.jsonc as the service hands it (undefined: a service with no settings, the page's defaults)
        property var settings: undefined
        function castUnlock(key: string): bool { spySvc.unlocks.push(key); return true; }
        property int woke: 0
        function castWoke(): void { spySvc.woke++; }
        function castHoldReady(): void {}
        function castWantRoom(w: real, h: real, dpr: real): void { spySvc.rooms.push([w, h, dpr]); }
    }
    Window {
        id: spyPageWin
        visible: true
        width: 300
        height: 600
        color: "#202020"
        CastPage {
            id: spyPage
            anchors.fill: parent
            service: spySvc
            dev: ({ key: "kdc:spy", can: { unlock: { ok: true, why: "", hint: "", via: "usb" } } })
        }
    }
    function spyReset(): void {
        spy.calls = [];
        probe.spyUnlocks = 0;
        spySvc.unlocks = [];
        spySvc.woke = 0;
    }
    function calls(): string {
        return JSON.stringify(spy.calls);
    }
    function textShown(root: var, words: string): bool {
        if (!root)
            return false;
        if (root.text !== undefined && String(root.text) === words && root.visible)
            return true;
        const k = root.children || [];
        for (let i = 0; i < k.length; i++)
            if (probe.textShown(k[i], words))
                return true;
        return false;
    }
    property bool reconnectStub: false
    property bool sawHeld: false
    property bool sawStarting: false
    property bool heldSaved: false
    Connections {
        target: pageWin
        function onAfterAnimating(): void {
            const pg = pageLoader.item as CastPage;
            if (!pg || (stubSvc.castHoldWhy !== "Resizing" && stubSvc.castHoldWhy !== "Reconnecting"))
                return;
            if (pg._holding && pg._holdF > 0.5)
                probe.sawHeld = true;
        }
    }

    // ---- V: the whole popup over a LIVE BridgeService (its tool a stub that answers castprep; its session is the real lares-cast on
    // the fake phone): what a free look and the opening turn do to the cast. Every frame is looked at.
    property BridgeService lookSvc: null
    property bool lookTurnsAtOpen: false
    Component {
        id: lookSvcComp
        BridgeService {}
    }
    FileView {
        id: watchFile
        path: probe.work + "/watch.in"
        blockWrites: true
        printErrors: false
    }
    FileView {
        id: dropFile
        path: probe.work + "/drop"
        printErrors: false
    }
    Window {
        id: lookWin
        visible: lookLoader.active
        width: 420
        height: 1240
        color: "#3a4a5a"
        Loader {
            id: lookLoader
            x: 40
            y: 48
            active: false
            sourceComponent: Component {
                BridgePopup {
                    service: probe.lookSvc
                    flipOnOpen: probe.lookTurnsAtOpen
                    lookFromMotion: false
                }
            }
        }
    }
    readonly property BridgePopup lookPopup: lookLoader.item as BridgePopup
    property CastView lookView: null
    // mutated in place (a counter bindings could read would be a dependency): frames drawn, of them without a picture, with the words,
    // with a hold; the stream's frames; the players that came and went; what the session was told
    property var seen: ({})
    function seenReset(): void {
        probe.seen = { drawn: 0, noPicture: 0, words: 0, held: 0, back: 0, stream: 0, streamBack: 0, players: 0, sources: 0, states: [], holds: [] };
        probe.seenReopens = probe.lookView ? probe.lookView.reopens : 0;
    }
    property int seenReopens: 0
    function seenLine(): string {
        return JSON.stringify(probe.seen) + " reopens " + (probe.lookView ? probe.lookView.reopens - probe.seenReopens : -1);
    }
    // the cast was left alone: the picture there in every frame, no words, one player, one session, no hold
    function untouched(): bool {
        const x = probe.seen;
        return x.drawn > 20 && x.noPicture === 0 && x.words === 0 && x.held === 0 && x.players === 0 && x.sources === 0 && x.states.length === 0 && x.holds.length === 0
            && probe.lookView !== null && probe.lookView.reopens === probe.seenReopens;
    }
    function findView(root: var): var {
        if (!root)
            return null;
        if ("pictureRect" in root && "hasPicture" in root)
            return root;
        const k = root.children || [];
        for (let i = 0; i < k.length; i++) {
            const v = probe.findView(k[i]);
            if (v)
                return v;
        }
        return null;
    }
    function lookPage(): CastPage {
        return probe.lookView ? probe.lookView.parent as CastPage : null;
    }
    Connections {
        target: lookWin
        function onAfterAnimating(): void {
            const x = probe.seen, v = probe.lookView, p = probe.lookPopup;
            if (!v || !p || x.drawn === undefined)
                return;
            x.drawn++;
            if (!v.hasPicture)
                x.noPicture++;
            if (probe.textShown(probe.lookPage(), "Starting"))
                x.words++;
            if (probe.lookPage()._holding)
                x.held++;
            if (!p.stage._frontShown)
                x.back++;
        }
    }
    Connections {
        target: probe.lookView ? probe.lookView.videoSink : null
        function onVideoFrameChanged(): void {
            if (probe.seen.stream === undefined)
                return;
            probe.seen.stream++;
            if (probe.lookPopup && !probe.lookPopup.stage._frontShown)
                probe.seen.streamBack++;
        }
    }
    Connections {
        target: probe.lookView ? probe.lookView.player : null
        function onSourceChanged(): void {
            if (probe.seen.sources !== undefined)
                probe.seen.sources++;
        }
    }
    Connections {
        target: probe.lookSvc ? probe.lookSvc.castSession : null
        function onClientChanged(connected: bool): void {
            if (probe.seen.players !== undefined)
                probe.seen.players++;
        }
        function onStateChanged(): void {
            if (probe.seen.states !== undefined)
                probe.seen.states.push(probe.lookSvc.castSession.state);
        }
    }
    Connections {
        target: probe.lookSvc
        function onCastHoldWhyChanged(): void {
            if (probe.seen.holds !== undefined)
                probe.seen.holds.push(probe.lookSvc.castHoldWhy);
        }
    }

    Connections {
        target: cs
        function onClientChanged(connected: bool): void {
            probe.playersNow += connected ? 1 : -1;
            if (connected)
                probe.players++;
        }
    }

    // ---- grabs: the picture, ten times a second, for the runner to read ---------------------------------------------------
    property int grabN: 0
    Timer {
        interval: 100
        running: true
        repeat: true
        onTriggered: {
            if (!view.hasPicture || probe.done)
                return;
            const t = Date.now();
            const r = view.pictureRect;
            const line = "BCP GRAB " + t + " " + r.x + " " + r.y + " " + r.width + " " + r.height + " " + cs.videoWidth + " " + cs.videoHeight;
            view.grabToImage(function (res) {
                res.saveToFile(probe.work + "/grabs/g" + t + ".png");
            });
            console.log(line);
        }
    }

    // ---- the sequencer ----------------------------------------------------------------------------------------------------
    // act(fn): run once. until(label, cond, ms, fatal): poll; a timeout is a failed check naming the thing (fatal: nothing after it
    // can mean anything, so the run ends there). keyClick / mouseClick run the event loop, so the driver is stopped around every step.
    property var steps: []
    property int at: 0
    property double t0: 0
    function act(fn: var): void {
        probe.steps.push({ kind: "do", fn: fn });
    }
    function until(label: string, cond: var, ms: int, fatal: bool, id: string): void {
        probe.steps.push({ kind: "until", label: label, fn: cond, ms: ms, fatal: fatal, id: id || "wait" });
    }
    function pause(ms: int): void {
        probe.steps.push({ kind: "pause", ms: ms });
    }
    function tick(): void {
        if (probe.done)
            return;
        if (probe.at >= probe.steps.length) {
            probe.finish();
            return;
        }
        const s = probe.steps[probe.at];
        if (s.kind === "do") {
            driver.stop();
            try {
                s.fn();
            } catch (e) {
                probe.check("run", false, "a step threw: " + e);
            }
            probe.at++;
            probe.t0 = 0;
            driver.start();
            return;
        }
        if (probe.t0 === 0)
            probe.t0 = Date.now();
        const el = Date.now() - probe.t0;
        if (s.kind === "pause") {
            if (el >= s.ms) {
                probe.at++;
                probe.t0 = 0;
            }
            return;
        }
        let ok = false;
        try {
            ok = !!s.fn();
        } catch (e) {
            ok = false;
        }
        if (ok) {
            probe.at++;
            probe.t0 = 0;
        } else if (el > s.ms) {
            probe.check(s.id, false, "timed out waiting for: " + s.label + " (" + s.ms + " ms)");
            if (s.fatal)
                probe.finish();
            else {
                probe.at++;
                probe.t0 = 0;
            }
        }
    }
    Timer {
        id: driver
        interval: 40
        running: false
        repeat: true
        onTriggered: probe.tick()
    }
    function finish(): void {
        if (probe.done)
            return;
        probe.done = true;
        driver.stop();
        console.log("BCP RESULT " + (probe.fails === 0 ? "PASS" : "FAIL") + " (" + probe.checks + " checks)");
        quitTimer.start();
    }
    Timer {
        id: bareQuit
        interval: 0
        onTriggered: Qt.quit()
    }
    Timer {
        id: quitTimer
        interval: 300
        onTriggered: Qt.quit()
    }
    // a tap at a point of the view
    function click(x: real, y: real): void {
        tc.mouseClick(win.contentItem, x, y);
    }

    Component.onCompleted: {
        // a bare smoke has no runner and so no stub adb: nothing is started (it once started the user's real adb server)
        if (probe.work === "") {
            console.log("BCP skipped (no runner)");
            bareQuit.start();
            return;
        }
        // A: it goes live and the picture comes
        probe.act(() => cs.start());
        probe.until("the session live", () => cs.state === "live", 15000, true, "a0");
        probe.act(() => {
            probe.check("a1", cs.url.indexOf("tcp://127.0.0.1:") === 0 && cs.videoWidth === 192 && cs.videoHeight === 384 && cs.deviceName === "FakePhone",
                        "live with the url, the phone's size and its name (" + cs.url + " " + cs.videoWidth + "x" + cs.videoHeight + " '" + cs.deviceName + "')");
            probe.mark("live");
            probe.liveAt = Date.now();
        });
        probe.until("a first frame (hasPicture)", () => view.hasPicture, 10000, true, "a2");
        probe.act(() => {
            const r = view.pictureRect;
            probe.check("a2", true, "a first frame was shown (hasPicture) " + (Date.now() - probe.liveAt) + " ms after live");
            probe.check("a3", Math.abs(r.x - 50) < 1.5 && Math.abs(r.y) < 1.5 && Math.abs(r.width - 200) < 1.5 && Math.abs(r.height - 400) < 1.5,
                        "the picture is drawn aspect-fit in the view: rect " + r.x + "," + r.y + " " + r.width + "x" + r.height + " (want 50,0 200x400)");
            probe.mark("picture");
        });
        probe.pause(1500);
        // B: the pointer: the letterbox is no touch, a tap on the picture is
        probe.act(() => {
            probe.click(10, 200);
            probe.click(150, 200);
        });
        probe.pause(300);
        // C: the keys
        probe.act(() => {
            win.requestActivate();
            view.forceActiveFocus();
            tc.keyClick(Qt.Key_Left);
            tc.keyClick(Qt.Key_Down);
            tc.keyClick(Qt.Key_Right);
            tc.keyClick(Qt.Key_Return);
            tc.keyClick("a");
            tc.keyClick(Qt.Key_Up);
        });
        probe.pause(300);
        // D: the wheel
        probe.act(() => tc.mouseWheel(win.contentItem, 150, 200, 0, 120));
        probe.pause(300);
        // E: a rotation
        probe.act(() => {
            probe.mark("rotate");
            rotFile.setText("go");
        });
        probe.until("the size event of the rotation", () => cs.videoWidth === 384 && cs.videoHeight === 192, 6000, true);
        probe.until("the picture re-fitted", () => view.pictureRect.width > view.pictureRect.height, 1500, false);
        probe.act(() => {
            const r = view.pictureRect;
            probe.check("e1", Math.abs(r.width - 300) < 1.5 && Math.abs(r.height - 150) < 1.5, "after the rotation the picture is " + r.width + "x" + r.height + " (want 300x150)");
            probe.mark("rotated");
        });
        probe.pause(1500);
        probe.act(() => probe.click(150, 200));
        probe.pause(300);
        // F: the popup closes and opens: the player goes, the next one gets a picture at once
        probe.act(() => {
            probe.check("f1", probe.players >= 1 && probe.playersNow === 1, "one player connected before the close (" + probe.players + " seen, " + probe.playersNow + " now)");
            probe.mark("closing");
            view.playing = false;
        });
        probe.until("the player to leave", () => probe.playersNow === 0, 5000, false);
        probe.act(() => probe.check("f2", !view.hasPicture, "a view that is not playing shows no picture"));
        probe.pause(600);
        probe.act(() => {
            probe.t0 = 0;
            probe.reopenAt = Date.now();
            probe.mark("reopen");
            view.playing = true;
        });
        probe.until("a picture again after the reopen", () => view.hasPicture, 6000, false);
        probe.act(() => {
            const dt = Date.now() - probe.reopenAt;
            probe.check("f3", view.hasPicture && dt <= 2000, "the picture is back " + dt + " ms after the popup opens (limit 2000)");
            console.log("BCP INFO reopen_ms=" + dt + " players=" + probe.players);
        });
        probe.pause(800);
        // I: a dark screen (the fake sends nothing): the tool says so, and the view does not open its player again over it
        probe.act(() => {
            probe.mark("dark");
            probe.reopensAt = view.reopens;
            pauseFile.setText("dark");
        });
        probe.until("the tool says no picture comes", () => cs.flowKnown && !cs.flowing, 5000, false, "i1");
        probe.pause(4500);
        probe.act(() => {
            probe.check("i1", cs.flowKnown && !cs.flowing && view.reopens === probe.reopensAt,
                        "a dark screen is told (flowing false) and the player is left alone (" + (view.reopens - probe.reopensAt) + " reopens)");
            unpause.running = true;
        });
        probe.until("the pictures come back", () => cs.flowing, 5000, false, "i2");
        probe.pause(800);
        // J: a player that shows nothing while the phone sends: it is opened again and the picture comes back
        // (the stand-in for whatever stuck the user's player: it is paused while the phone keeps sending)
        probe.act(() => {
            probe.reopensAt = view.reopens;
            view.player.pause();
        });
        probe.until("the player opened again", () => view.reopens > probe.reopensAt, 6000, false, "j1");
        probe.act(() => { probe.framesAt = probe.frameCount; });
        probe.until("new frames after the reopen", () => probe.frameCount > probe.framesAt + 5, 6000, false, "j1");
        probe.act(() => probe.check("j1", view.reopens === probe.reopensAt + 1 && probe.frameCount > probe.framesAt + 5,
                                    "a player that shows nothing while the phone sends is opened again, once, and shows the picture (" + (view.reopens - probe.reopensAt) + " reopens)"));
        // K: Desktop: a new display at the room's size (the runner reads its argv from the fake phone)
        probe.act(() => {
            cs.stop();
            cs.newDisplay = "608x1344";
        });
        probe.pause(1500);
        probe.act(() => cs.start());
        probe.until("the desktop live", () => cs.state === "live", 15000, false, "k1");
        probe.act(() => probe.check("k1", cs.videoWidth === 608 && cs.videoHeight === 1344, "a Desktop cast's picture is the new display's size (" + cs.videoWidth + "x" + cs.videoHeight + ")"));
        probe.act(() => {
            cs.stop();
            cs.newDisplay = "";
        });
        probe.pause(1500);
        // H: the cast page holds its last frame, blurred, through a resize's restart, and lets go on the new stream's first frame
        probe.act(() => cs.start());
        probe.until("live for the page", () => cs.state === "live", 15000, false, "h1");
        probe.act(() => { pageLoader.active = true; });
        probe.until("the page shows a picture", () => pageLoader.item && pageLoader.item.children.length > 0 && probe.pageView() && probe.pageView().hasPicture, 8000, false, "h1");
        probe.pause(600);
        probe.act(() => {
            probe.mark("hold");
            stubSvc.castHoldWhy = "Resizing";
        });
        probe.until("the page took its frame and told the service", () => stubSvc.holdReady > 0, 3000, false, "h1");
        probe.act(() => probe.check("h1", stubSvc.holdReady === 1, "the page takes its last frame and only then lets the restart go (castHoldReady " + stubSvc.holdReady + ")"));
        probe.until("the held picture over the restart", () => probe.sawHeld, 3000, false, "h2");
        // the picture of the hold (the runner judges it: p12)
        probe.act(() => {
            probe.mark("held");
            pageWin.contentItem.grabToImage(r => {
                r.saveToFile(probe.work + "/held.png");
                probe.heldSaved = true;
            });
        });
        probe.until("the grab of the held picture", () => probe.heldSaved, 3000, false, "h2");
        probe.act(() => probe.check("h2", probe.sawHeld && pageLoader.item._holdWhy === "Resizing", "while the stream restarts the page holds its last frame, blurred, under the title box, labelled with the why (held " + probe.sawHeld + ", '" + pageLoader.item._holdWhy + "')"));
        probe.until("the hold ends on the new stream", () => stubSvc.castHoldWhy === "" && pageLoader.item && !pageLoader.item._holding, 8000, false, "h3");
        probe.act(() => {
            probe.check("h3", !pageLoader.item._holding && probe.pageView().hasPicture, "the hold ends on the new stream's first frame");
        });
        // R: an ended session is a hold, "Reconnecting", with the last picture kept, and it ends on the new stream's first frame
        probe.act(() => {
            probe.sawHeld = false;
            probe.reconnectStub = true;
            // the tool says the phone closed the stream (the tool itself goes on: the stand-in for the service's restart is cs.restart)
            cs._onLine("{\"event\":\"ended\",\"reason\":\"the phone closed the stream\"}");
        });
        probe.until("the page holds through the end", () => pageLoader.item && pageLoader.item._holding && probe.sawHeld, 3000, false, "r1");
        probe.act(() => probe.check("r1", pageLoader.item._holdWhy === "Reconnecting" && probe.pageView().hasPicture && pageLoader.item._phase === "reconnecting",
                                    "an ended session holds its last picture as Reconnecting, never the words 'Starting' (why '" + pageLoader.item._holdWhy + "', phase " + pageLoader.item._phase + ", kept picture " + probe.pageView().hasPicture + ")"));
        probe.act(() => cs.restart());
        probe.until("the hold ends on the reconnected stream", () => stubSvc.castHoldWhy === "" && pageLoader.item && !pageLoader.item._holding, 10000, false, "r2");
        probe.act(() => {
            probe.reconnectStub = false;
            probe.check("r2", !pageLoader.item._holding && probe.pageView().hasPicture && cs.state === "live", "the Reconnecting hold ends on the new stream's first frame (state " + cs.state + ")");
        });
        probe.pause(800);
        // the page's wiring of the input: the host's hold, an unlock under way
        probe.act(() => {
            const v = probe.pageView();
            pageLoader.item.inputHeld = false;
            const a = v.inputHeld;
            pageLoader.item.inputHeld = true;
            const b = v.inputHeld;
            pageLoader.item.inputHeld = false;
            stubSvc.castUnlocking = true;
            const c = v.inputHeld;
            stubSvc.castUnlocking = false;
            probe.check("r3", a === false && b === true && c === true && v.inputHeld === false, "the picture is held while the host holds it (inputHeld) or an unlock is out (castUnlocking), and not otherwise");
            pageLoader.active = false;
            cs.stop();
        });
        probe.pause(1500);
        // L: the input gate and the unlock trigger, on a spy session
        probe.act(() => {
            spyWin.requestActivate();
            spyView.forceActiveFocus();
            probe.spyReset();
            spy.flowKnown = false;
            spy.lockKnown = false;
            spyView.canUnlock = true;
            spyView.inputHeld = false;
            tc.mousePress(spyWin.contentItem, 150, 200);
            spyView.inputHeld = true;      // the hold starts with a finger down: it is lifted where it was
            tc.mouseMove(spyWin.contentItem, 170, 220);
            tc.mouseRelease(spyWin.contentItem, 170, 220);
            tc.mouseClick(spyWin.contentItem, 150, 200);
            tc.keyClick(Qt.Key_Left);
            tc.keyClick("a");
            tc.mouseWheel(spyWin.contentItem, 150, 200, 0, 120);
        });
        probe.pause(200);
        probe.act(() => probe.check("l1", probe.calls() === JSON.stringify(["touch down 96,192", "touch up 96,192"]),
                                    "while the picture is held nothing goes to the phone, and a finger already down gets its up at once: " + probe.calls()));
        probe.act(() => {
            probe.spyReset();
            tc.keyClick(Qt.Key_Left);
            tc.keyClick("b");
        });
        probe.act(() => probe.check("l2", probe.calls() === "[]",
                                    "held: keys and text are not forwarded (" + probe.calls() + ")"));
        probe.act(() => {
            spyView.inputHeld = false;
            probe.spyReset();
            tc.keyClick(Qt.Key_Left);
        });
        probe.act(() => probe.check("l2b", probe.calls() === JSON.stringify(["key back"]), "not held: the key goes (the gate is not just deaf): " + probe.calls()));
        probe.act(() => {
            probe.spyReset();
            spyView.navKeys = { back: "F1", home: "", recents: "Right" };
            tc.keyClick(Qt.Key_F1);
            tc.keyClick(Qt.Key_Down);
            tc.keyClick(Qt.Key_Left);
        });
        probe.act(() => {
            probe.check("k1", probe.calls() === JSON.stringify(["key back", "key down", "key left"]),
                        "bridge.jsonc cast.keys: F1 is Back, and Down and Left (no nav key now) go to the phone as their arrows: " + probe.calls());
            spyView.navKeys = { back: "Left", home: "Down", recents: "Right" };
        });
        // a dark screen, a PIN that can be typed: the first press is swallowed, the screen woken, the unlock asked
        probe.act(() => {
            probe.spyReset();
            spy.flowKnown = true;
            spy.flowing = false;
            tc.mouseClick(spyWin.contentItem, 150, 200);
        });
        probe.act(() => probe.check("l3", probe.calls() === JSON.stringify(["wake"]) && probe.spyUnlocks === 1,
                                    "a press on a dark picture is swallowed, wakes the screen and asks the unlock: " + probe.calls() + " unlocks " + probe.spyUnlocks));
        probe.act(() => {
            probe.spyReset();
            tc.keyClick("x");
        });
        probe.act(() => probe.check("l4", probe.calls() === JSON.stringify(["wake"]) && probe.spyUnlocks === 1, "the first key on a dark picture is the trigger too, typed nowhere: " + probe.calls()));
        // a modifier alone is no key: Alt is the popup's free look, and a look wakes nothing
        probe.act(() => {
            probe.spyReset();
            tc.keyPress(Qt.Key_Alt);
            tc.keyRelease(Qt.Key_Alt);
        });
        probe.act(() => probe.check("l9", probe.calls() === "[]" && probe.spyUnlocks === 0, "Alt alone over a dark picture (the free look) wakes nothing and asks no unlock: " + probe.calls()));
        // the lock events beat the flow: awake and not flowing is a still screen, no trigger
        probe.act(() => {
            probe.spyReset();
            spy.lockKnown = true;
            spy.awake = true;
            spy.keyguard = false;
            tc.mouseClick(spyWin.contentItem, 150, 200);
        });
        probe.act(() => probe.check("l5", probe.calls() === JSON.stringify(["touch down 96,192", "touch up 96,192"]) && probe.spyUnlocks === 0,
                                    "an awake phone whose picture is merely still takes the touch: " + probe.calls()));
        // the lock screen: with a PIN to type it is the trigger; with none the user types it by hand
        probe.act(() => {
            probe.spyReset();
            spy.keyguard = true;
            tc.mouseClick(spyWin.contentItem, 150, 200);
        });
        probe.act(() => probe.check("l6", probe.calls() === JSON.stringify(["wake"]) && probe.spyUnlocks === 1, "a press on the lock screen with a PIN kept is the trigger: " + probe.calls()));
        probe.act(() => {
            probe.spyReset();
            spyView.canUnlock = false;
            tc.mouseClick(spyWin.contentItem, 150, 200);
        });
        probe.act(() => probe.check("l7", probe.calls() === JSON.stringify(["touch down 96,192", "touch up 96,192"]) && probe.spyUnlocks === 0,
                                    "on the lock screen with no PIN the touch goes through (the user types the PIN): " + probe.calls()));
        probe.act(() => {
            probe.spyReset();
            spy.awake = false;
            tc.mouseClick(spyWin.contentItem, 150, 200);
        });
        probe.act(() => probe.check("l8", probe.calls() === JSON.stringify(["wake"]) && probe.spyUnlocks === 0,
                                    "a dark screen that cannot be unlocked is only woken: " + probe.calls() + " unlocks " + probe.spyUnlocks));
        // the page: the words, the service's unlock, the room with its ratio
        probe.act(() => {
            probe.spyReset();
            spyView.canUnlock = false;
            spy.keyguard = false;
            spy.awake = false;
            spyPageWin.requestActivate();
        });
        probe.pause(300);
        probe.act(() => {
            probe.check("u1", spyPage._dark && probe.textShown(spyPage, "Screen off"), "a dark phone's page says 'Screen off' (dark " + spyPage._dark + ")");
            tc.mouseClick(spyPageWin.contentItem, 150, 300);
        });
        probe.act(() => probe.check("u2", probe.calls() === JSON.stringify(["wake"]) && JSON.stringify(spySvc.unlocks) === JSON.stringify(["kdc:spy"]) && spySvc.woke === 1,
                                    "the page asks the service to unlock the phone it shows, and says it woke it (it sleeps again at the cast's end): " + probe.calls() + " "
                                    + JSON.stringify(spySvc.unlocks) + " woke " + spySvc.woke));
        probe.act(() => {
            probe.spyReset();
            spySvc.castUnlocking = true;
            tc.mouseClick(spyPageWin.contentItem, 150, 300);
            tc.keyClick("z");
            spySvc.castUnlocking = false;
        });
        probe.act(() => probe.check("u3", probe.calls() === "[]" && spySvc.unlocks.length === 0, "while the unlock is out the page's picture takes nothing, no second trigger: " + probe.calls()));
        probe.act(() => {
            probe.spyReset();
            spySvc.settings = { cast: { unlock: "start", keys: { back: "Left", home: "Down", recents: "Right" } } };
            spy.keyguard = false;
            spy.awake = false;
            tc.mouseClick(spyPageWin.contentItem, 150, 300);
        });
        probe.act(() => {
            probe.check("u6", probe.calls() === JSON.stringify(["wake"]) && spySvc.unlocks.length === 0,
                        "bridge.jsonc cast.unlock \"start\": a touch of a dark picture wakes the phone and types no PIN: " + probe.calls() + " " + JSON.stringify(spySvc.unlocks));
            spySvc.settings = undefined;
        });
        probe.act(() => probe.check("u4", spySvc.rooms.length > 0 && spySvc.rooms[0][2] > 0, "the page reports its room with the window's ratio: " + JSON.stringify(spySvc.rooms[0])));
        // a Desktop: Android keeps the new display usable while the phone is locked or dark: its picture takes the click as a touch
        probe.act(() => {
            probe.spyReset();
            spySvc.castMode = "desktop";
            spy.keyguard = true;
            spy.awake = false;
        });
        probe.pause(100);
        probe.act(() => {
            probe.check("u5a", !spyPage._dark && !probe.textShown(spyPage, "Screen off"), "a Desktop's page never says 'Screen off' (dark " + spyPage._dark + ")");
            tc.mouseClick(spyPageWin.contentItem, 150, 300);
        });
        probe.act(() => {
            const c = JSON.parse(probe.calls());
            probe.check("u5", c.length === 2 && c[0].indexOf("touch down") === 0 && c[1].indexOf("touch up") === 0 && spySvc.unlocks.length === 0,
                        "a Desktop's picture of a locked, dark phone takes the click as a touch: no wake, no unlock: " + probe.calls() + " " + JSON.stringify(spySvc.unlocks));
            spySvc.castMode = "mirror";
        });
        // V: a free look while the cast runs (the user, 2026-11-22: "Starting" every time the phone was turned)
        probe.act(() => cs.stop());
        probe.pause(1500);
        probe.act(() => {
            const l = JSON.parse(Scenarios.lines("wired")[0]);
            watchFile.setText(JSON.stringify(l) + "\n");
            probe.lookSvc = lookSvcComp.createObject(probe, { live: true, toolPath: probe.work + "/lares-bridge", configPath: probe.work + "/none.jsonc" });
        });
        probe.until("the service's first line", () => probe.lookSvc.ready, 5000, false, "v0");
        probe.act(() => {
            probe.lookSvc.popupOpen = true;
            probe.lookSvc.page = "cast";
            probe.lookSvc.castStart(probe.lookSvc.currentKey, "mirror", false);
        });
        probe.until("the popup's cast live", () => probe.lookSvc.castPhase === "live", 15000, false, "v0");
        probe.act(() => { lookLoader.active = true; });
        probe.until("the cast page in the popup", () => (probe.lookView = probe.findView(probe.lookPopup) as CastView) !== null, 5000, false, "v0");
        probe.until("its picture", () => probe.lookView.hasPicture, 8000, false, "v0");
        probe.until("the phone at rest", () => probe.lookPopup.stage.atRest, 5000, false, "v0");
        // (the cast was started before the page could say its room: it restarts once at the page's size)
        probe.until("the cast at the page's size", () => probe.lookSvc.castSession.maxSize === 720 && probe.lookSvc.castPhase === "live" && !probe.lookPage()._holding, 8000, false, "v0");
        probe.pause(600);
        probe.act(() => {
            probe.check("v0", probe.lookSvc.castPhase === "live" && probe.lookView.hasPicture && !probe.lookPage()._holding, "the popup casts: " + probe.lookSvc.castPhase + ", room " + probe.lookSvc._castRoomW + "x" + probe.lookSvc._castRoomH + ", max-size " + probe.lookSvc.castSession.maxSize);
            probe.lookMax = probe.lookSvc.castSession.maxSize;
            probe.seenReset();
            probe.lookPopup.freeLookHold = true;
        });
        probe.until("the look held", () => probe.lookPopup.stage.lookHeld, 3000, false, "v1");
        // the hand: to the phone's back, where it stays a while, and on round to the front
        probe.act(() => {
            for (let i = 1; i <= 26; i++)
                probe.lookPopup.stage.lookBy(-10, i % 2 ? 3 : -3);
        });
        probe.pause(1600);
        probe.act(() => {
            probe.check("v1", probe.seen.back > 20 && probe.untouched(), "the phone's back toward the viewer for 1.6 s: the cast is left alone (" + probe.seenLine() + ")");
            probe.check("v2", probe.seen.streamBack > 20, "and its picture runs on behind it (" + probe.seen.streamBack + " frames of the stream while the back showed)");
            for (let i = 1; i <= 26; i++)
                probe.lookPopup.stage.lookBy(-10, 0);
        });
        probe.pause(500);
        probe.act(() => { probe.lookPopup.freeLookHold = false; });
        probe.until("the phone back at rest", () => !probe.lookPopup.stage.looking, 4000, false, "v3");
        probe.pause(1200);
        probe.act(() => probe.check("v3", probe.untouched() && probe.lookSvc.castSession.maxSize === probe.lookMax && probe.lookPopup.stage.face === "front",
                                    "a whole free look: no 'Starting', no reopen, no restart, the size asked of the phone unchanged (max-size " + probe.lookSvc.castSession.maxSize + "; " + probe.seenLine() + ")"));
        // a real change of the popup's size while the look runs waits for its end, then the mirror restarts once at the new bucket
        probe.act(() => {
            probe.seenReset();
            probe.lookPopup.freeLookHold = true;
        });
        probe.until("the look held again", () => probe.lookPopup.stage.lookHeld, 3000, false, "v4");
        probe.act(() => { probe.lookSvc.castScale = 1.5; });
        probe.pause(1600);
        probe.act(() => {
            probe.check("v4", probe.untouched() && probe.lookSvc.castSession.maxSize === probe.lookMax && probe.lookSvc._castSize() > probe.lookMax,
                        "a popup resized in a look: nothing restarts while the look runs (wants " + probe.lookSvc._castSize() + ", asked " + probe.lookSvc.castSession.maxSize + "; " + probe.seenLine() + ")");
            probe.lookPopup.freeLookHold = false;
        });
        probe.until("the restart at the new size", () => probe.lookSvc.castSession.maxSize > probe.lookMax && probe.lookSvc.castPhase === "live" && !probe.lookPage()._holding, 12000, false, "v5");
        probe.act(() => probe.check("v5", probe.seen.holds.join(",") === "Resizing," && probe.seen.words === 0 && probe.lookView.hasPicture,
                                    "after the look the mirror restarts once at the new size, held as 'Resizing', never 'Starting' (max-size " + probe.lookSvc.castSession.maxSize + "; " + probe.seenLine() + ")"));
        // the stream ends while the back faces the viewer: the hold it takes cannot grab a hidden face, and it ends with the new stream
        probe.pause(800);
        probe.act(() => {
            probe.seenReset();
            probe.lookPopup.freeLookHold = true;
        });
        probe.until("the look held once more", () => probe.lookPopup.stage.lookHeld, 3000, false, "v6");
        probe.act(() => {
            probe.lookPopup.stage.lookBy(-260 * probe.lookSvc.castScale, 0);
            dropFile.setText("drop");
        });
        probe.until("the stream lost", () => probe.seen.states.indexOf("ended") >= 0, 6000, false, "v6");
        probe.until("the stream back", () => probe.lookSvc.castPhase === "live" && probe.lookView.hasPicture && probe.seen.states.indexOf("live") >= 0, 15000, false, "v6");
        probe.pause(600);
        probe.act(() => {
            probe.check("v6", probe.seen.back > 20 && probe.lookSvc.castPhase === "live", "a stream that ends while the back shows is brought back behind it (" + probe.seenLine() + ")");
            probe.lookPopup.freeLookHold = false;
        });
        probe.until("at rest", () => !probe.lookPopup.stage.looking, 4000, false, "v7");
        probe.pause(800);
        probe.act(() => probe.check("v7", !probe.lookPage()._holding && probe.lookView.hasPicture && probe.seen.words === 0,
                                    "turned back, the live picture: no hold left over it (holding " + probe.lookPage()._holding + " '" + probe.lookPage()._holdWhy + "'; " + probe.seenLine() + ")"));
        // the popup opened over a running cast: its one opening turn shows the back for a moment, and the player is opened once
        probe.act(() => {
            probe.lookView = null;
            lookLoader.active = false;
        });
        probe.pause(800);
        probe.act(() => {
            probe.lookTurnsAtOpen = true;
            lookLoader.active = true;
            probe.lookView = probe.findView(probe.lookPopup) as CastView;
            probe.seenReset();
        });
        probe.until("the opening turn done and the picture there", () => probe.lookView && probe.lookView.hasPicture && probe.lookPopup.stage.atRest, 8000, false, "v8");
        probe.act(() => probe.check("v8", probe.seen.back > 0 && probe.seen.players === 1 && probe.seen.sources === 0 && probe.lookView.reopens === 0,
                                    "the popup's opening turn opens the player once (" + probe.seenLine() + ")"));
        probe.act(() => {
            probe.lookView = null;
            lookLoader.active = false;
            probe.lookSvc.castStop();
        });
        probe.pause(1500);
        // G: stop leaves nothing
        probe.until("the state idle", () => cs.state === "idle" && cs.url === "", 1000, false);
        probe.pause(1800);
        probe.act(() => {
            scan.command = ["python3", probe.work + "/scan.py", probe.serial];
            scan.running = true;
        });
        probe.until("the scan of leftovers", () => !scan.running && String(scanOut.text).length > 0, 6000, false);
        probe.act(() => probe.check("g1", String(scanOut.text).trim() === "0", "after stop() no lares-cast, no fake phone is left (scan says " + String(scanOut.text).trim() + ")"));
        // G2: a recording session (--record): after stop() the tool finishes the file and the session says where it went (the runner
        // ffprobes it: p13)
        probe.act(() => {
            probe.recEv = null;
            cs.record = probe.work + "/rec/cast.mp4";
            cs.start();
        });
        probe.until("live, recording", () => cs.state === "live", 15000, false);
        probe.pause(2500);
        probe.act(() => cs.stop());
        probe.until("the recording told", () => probe.recEv !== null, 20000, false, "g2");
        probe.act(() => {
            console.log("BCP INFO recorded " + JSON.stringify(probe.recEv));
            probe.check("g2", probe.recEv !== null && probe.recEv.path === probe.work + "/rec/cast.mp4" && cs.state === "idle",
                        "after stop() a recording session tells where its file went (the tool's `record` event, told after the quit): " + JSON.stringify(probe.recEv));
            cs.record = "";
        });
        // H: started again and left running: the runner then checks that the quit of its parent took it along
        probe.act(() => cs.start());
        probe.until("live again", () => cs.state === "live", 15000, true);
        probe.act(() => probe.mark("end"));
        driver.start();
    }
    function pageView(): var {
        const pg = pageLoader.item as Item;
        if (!pg)
            return null;
        for (let i = 0; i < pg.children.length; i++)
            if ("hasPicture" in pg.children[i])
                return pg.children[i];
        return null;
    }
    property double reopenAt: 0
    property int reopensAt: 0
    property int lookMax: 0
    property int framesAt: 0
    property int frameCount: 0
    property double liveAt: 0
    property var recEv: null
}
