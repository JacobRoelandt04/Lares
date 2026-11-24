pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "modules/common/notify"
import "modules/common/components"
import "modules/session"
import "modules/shell"
import "modules/shell/ReelItems.js" as ReelItems

// SessionService on a STUB of tools/session/lares-session (a script that logs its argv and answers what the scenario's files
// say), and ReelActions' save step run for real through `sh`. No compositor, no window of the session, nothing restored.
// Prints SSP lines and one `SESSION_SERVICE RESULT PASS|FAIL`. Runner: tools/dev/session_service_probe.sh (it sets the env).
Item {
    id: root
    width: 10
    height: 10

    readonly property string work: Quickshell.env("SSP_WORK") || ""
    property var posts: []
    property var withdrawn: []
    // posts and withdraws in the order they came (the hand-over: one toast's place taken in the same turn)
    property var events: []
    property var fails: []
    property int checks: 0
    function check(id, ok, detail) {
        root.checks++;
        console.log("SSP " + id + ": " + (ok ? "ok" : "FAIL") + (detail ? "  " + detail : ""));
        if (!ok)
            root.fails.push(id);
    }
    function stubBus() {
        NotificationBus.service = ({
            post: spec => { root.posts.push(spec); root.events.push("post " + spec.key); return "uid"; },
            withdraw: (source, key) => { root.withdrawn.push(key); root.events.push("withdraw " + key); },
            attend: () => {}
        });
    }
    function logOf(name) {
        logView.path = "";
        logView.path = root.work + "/" + name + "/calls.log";
        logView.reload();
        return logView.text().trim().split("\n").filter(l => l !== "");
    }
    FileView { id: logView; blockLoading: true; blockAllReads: true; printErrors: false; watchChanges: false }

    DesktopNotifier { id: toastNotifier; appName: "Session"; keys: ["restore", "progress", "result", "spare"] }
    Component {
        id: svc
        SessionService {
            // (an id named `notifier` would read as the service's own member here)
            notifier: toastNotifier
            live: true
        }
    }
    function make(name, locked, shown) {
        return svc.createObject(root, { tool: root.work + "/" + name + "/lares-session", configPath: root.work + "/" + name + "/session.jsonc",
            locked: locked, shown: shown });
    }
    property var a: null
    property var g: null
    property var b: null
    property var c: null
    property var d: null
    property var e: null

    // The reel's table with the save step, run for real.
    ReelActions { id: reel; sessionTool: root.work + "/hang/lares-session" }
    ReelActions { id: reelOff }
    // power.jsonc's commands: the items it names run them (the ones that end the session still after the save), Lock never
    ReelActions {
        id: reelOwn
        sessionTool: root.work + "/hang/lares-session"
        commands: ({ sleep: ["systemctl", "hibernate"], hibernate: ["systemctl", "hibernate"], logout: ["uwsm", "stop"], lock: ["true"] })
    }
    Process { id: endProc; onExited: code => { root.endMs = Date.now() - root.endAt; root.endDone = true; } }
    property double endAt: 0
    property double endMs: -1
    property bool endDone: false

    // ---- steps: each waits for its own condition, on the wall clock (offscreen a QML Timer runs fast) -------------
    property var steps: []
    property int at: 0
    property double stepSince: 0
    function step(name, until, then, budgetMs) { root.steps.push({ name: name, until: until, then: then, budget: budgetMs || 8000 }); }
    Timer {
        id: tick
        interval: 40
        repeat: true
        onTriggered: {
            if (root.at >= root.steps.length) { tick.stop(); root.finish(); return; }
            const s = root.steps[root.at];
            if (root.stepSince === 0)
                root.stepSince = Date.now();
            let ok = false;
            try { ok = s.until(); } catch (err) { ok = false; }
            const late = Date.now() - root.stepSince > s.budget;
            if (!ok && !late)
                return;
            tick.stop();
            try {
                if (!ok)
                    root.check(s.name + " (waited " + s.budget + " ms)", false, "its condition never held");
                else
                    s.then();
            } catch (err) {
                root.check(s.name, false, "threw: " + err);
            }
            root.at++;
            root.stepSince = 0;
            tick.start();
        }
    }
    function postsOf(key) { return root.posts.filter(p => p.key === key); }

    Component.onCompleted: {
        if (root.work === "") { quit.start(); return; }       // smoked bare: nothing to drive
        root.stubBus();
        // A. off: nothing is asked of the tool, the reel's commands are the plain ones
        root.a = root.make("off", false, true);
        root.step("off", () => root.a._started, () => {
            root.check("off: no begin", root.logOf("off").length === 0 && root.a.phase === "off" && !root.a.watching, JSON.stringify(root.logOf("off")));
            root.check("off: no save step", root.a.endTool === "" && JSON.stringify(reelOff.commandOf("logout")) === JSON.stringify(["hyprctl", "dispatch", "hl.dsp.exit()"])
                       && JSON.stringify(reelOff.commandOf("reboot")) === JSON.stringify(["systemctl", "reboot"]), JSON.stringify(reelOff.commandOf("logout")));
            root.check("power.jsonc: an item's own command", JSON.stringify(reelOwn.commandOf("sleep")) === JSON.stringify(["systemctl", "hibernate"])
                       && JSON.stringify(reelOwn.commandOf("hibernate")) === JSON.stringify(["systemctl", "hibernate"]), JSON.stringify(reelOwn.commandOf("sleep")));
            root.check("power.jsonc: the save still comes first", reelOwn.commandOf("logout")[0] === "sh"
                       && JSON.stringify(reelOwn.commandOf("logout").slice(-2)) === JSON.stringify(["uwsm", "stop"]), JSON.stringify(reelOwn.commandOf("logout")));
            root.check("power.jsonc: a command left out is the item's own, hibernate has none, Lock takes none", JSON.stringify(reelOwn.commandOf("reboot").slice(-2)) === JSON.stringify(["systemctl", "reboot"])
                       && reelOff.commandOf("hibernate") === null && reelOwn.commandOf("lock").length === 6, JSON.stringify(reelOwn.commandOf("lock")));
            root.check("power.jsonc: the MUX restart is a reboot whatever the reel's runs", JSON.stringify(reelOwn.ownCommandOf("sleep")) === JSON.stringify(["systemctl", "suspend"]), "");
            const ids = l => l.map(x => x.id).join(" ");
            root.check("power.jsonc: the items in their order, Lock always there", ids(ReelItems.powerItems(["reboot", "sleep", "sleep", "x"])) === "reboot sleep lock"
                       && ids(ReelItems.powerItems([])) === ids(ReelItems.POWER), ids(ReelItems.powerItems(["reboot", "sleep", "sleep", "x"])));
            // B. a critical ask, born under the lock
            root.b = root.make("crit", true, true);
        });
        // (the watcher's own line lands a moment after its process is up)
        root.step("crit decided", () => root.b && root.b.phase === "asking" && root.b.watching && root.logOf("crit").length >= 2, () => {
            const log = root.logOf("crit");
            root.check("crit: begin, then the watcher", log.length >= 2 && log[0] === "begin" && log[1] === "watch", JSON.stringify(log));
            root.check("crit: no toast under the lock", root.postsOf("restore").length === 0, root.posts.length);
        });
        root.step("crit still locked", () => true, () => { root.b.shown = false; root.b.locked = false; });
        root.step("crit unlocked, not shown", () => true, () => {
            root.check("crit: no toast before the frame is on the glass", root.postsOf("restore").length === 0, root.posts.length);
            root.b.shown = true;
        });
        root.step("crit asked", () => root.postsOf("restore").length === 1, () => {
            const p = root.postsOf("restore")[0];
            root.check("crit: critical, sticky, two answers", p.urgency === "critical" && p.timeoutMs === -1
                       && JSON.stringify(p.actions.map(x => x.id)) === JSON.stringify(["restore", "discard"]), JSON.stringify([p.urgency, p.timeoutMs, p.actions]));
            root.check("crit: the cause and the windows are said", /Hyprland crashed at 14:02/.test(p.body) && /8 windows/.test(p.body) && /typed/.test(p.body), p.body);
            root.check("crit: a click on the card starts nothing", !p.actions.some(x => x.id === "default" || x.id === "open"), "");
            p.onAction("restore");
            const pr0 = root.postsOf("progress");
            root.check("crit: the click is answered at once, in the turn its ask goes", pr0.length === 1 && /Preparing the windows/.test(pr0[0].body)
                       && root.events.indexOf("withdraw restore") >= 0 && root.events.indexOf("withdraw restore") < root.events.indexOf("post progress"),
                       JSON.stringify(root.events));
        });
        root.step("crit restored", () => root.b.lastResult !== null && root.postsOf("result").length === 1, () => {
            const log = root.logOf("crit");
            root.check("crit: one restore", log.filter(l => l === "restore --json --progress").length === 1 && root.withdrawn.indexOf("restore") >= 0, JSON.stringify(log));
            const p = root.postsOf("result")[0];
            root.check("crit: what waits is told, low", p.urgency === "low" && /2 commands are typed and wait for Enter/.test(p.body) && /Postman/.test(p.body), p.body);
            root.check("crit: a slow app is said to be coming, not failed", /Windows is still starting: its window opens on workspace 4/.test(p.body), p.body);
            const pr = root.postsOf("progress");
            root.check("crit: the restore shows its steps in ONE changing toast", pr.length >= 2 && pr.every(x => x.live === true && x.timeoutMs === -1)
                       && pr.some(x => /3 of 8 windows are ready/.test(x.body) && /Waiting for Zen Browser, kitty/.test(x.body))
                       && pr.some(x => /7 of 8 windows are ready/.test(x.body)), JSON.stringify(pr.map(x => x.body)));
            root.check("crit: the progress toast goes with the result", root.withdrawn.indexOf("progress") >= 0, JSON.stringify(root.withdrawn));
            root.check("crit: the result takes the progress toast's place (posted, then the progress withdrawn)",
                       root.events.lastIndexOf("post result") >= 0 && root.events.lastIndexOf("post result") + 1 === root.events.indexOf("withdraw progress"),
                       JSON.stringify(root.events));
            root.check("crit: back at rest", root.b.phase === "idle", root.b.phase);
            // C. auto, under the lock: the restore runs at once, and a clean one says nothing
            root.posts = [];
            root.c = root.make("auto", true, false);
        });
        root.step("auto restored", () => root.c && root.c.lastResult !== null, () => {
            const log = root.logOf("auto");
            root.check("auto: restored under the lock", log.indexOf("restore --json --progress") > log.indexOf("begin") && log.indexOf("begin") === 0, JSON.stringify(log));
            root.check("auto: no progress toast under the lock", root.postsOf("progress").length === 0, root.postsOf("progress").length);
            root.check("auto: no confirmation under the lock", root.postsOf("result").length === 0, root.postsOf("result").length);
            root.check("auto: the owed focus waits for the unlock", log.indexOf("refocus") < 0, JSON.stringify(log));
            root.c.locked = false; root.c.shown = true;
        });
        root.step("auto refocused", () => root.logOf("auto").indexOf("refocus") >= 0, () => {
            root.check("auto: the focus is given at the unlock, once", root.logOf("auto").filter(l => l === "refocus").length === 1, JSON.stringify(root.logOf("auto")));
        });
        root.step("auto quiet", () => true, () => {
            // nothing needs the user: the status toast still ends with one quiet word, told when somebody can read it (the unlock)
            const pr = root.postsOf("result");
            root.check("auto: nothing needs the user, one quiet confirmation (told at the unlock, 6 s)", root.posts.length === 1 && pr.length === 1
                       && pr[0].urgency === "low" && pr[0].timeoutMs === 6000 && /^8 windows are back$/.test(pr[0].body) && pr[0].title === "Session restored"
                       && (pr[0].actions || []).length === 0, JSON.stringify(root.posts.map(p => [p.key, p.body, p.timeoutMs])));
            // D. an ask that is discarded
            root.d = root.make("ask", false, true);
        });
        root.step("ask posted", () => root.postsOf("restore").length === 1, () => {
            const p = root.postsOf("restore")[0];
            root.check("ask: normal urgency", p.urgency === "normal" && !/typed/.test(p.body), p.urgency + " " + p.body);
            p.onAction("discard");
        });
        root.step("ask discarded", () => root.logOf("ask").indexOf("answer discard") >= 0, () => {
            root.check("ask: discarded, nothing restored", root.logOf("ask").indexOf("restore --json --progress") < 0 && root.d.phase === "idle", JSON.stringify(root.logOf("ask")));
            // E. turned on in a running session: no decision of its own
            root.e = root.make("late", false, true);
        });
        root.step("late started", () => root.e && root.e._started, () => {
            root.check("late: off at the start", root.logOf("late").length === 0, JSON.stringify(root.logOf("late")));
            lateCfg.setText('{ "enabled": true }\n');
        });
        root.step("late on", () => root.e.enabled && root.e.watching && root.logOf("late").length >= 1, () => {
            const log = root.logOf("late");
            root.check("late: the watcher, no begin", log.indexOf("begin") < 0 && log.indexOf("watch") >= 0 && root.e.endTool !== "", JSON.stringify(log));
            // F. the reel's save step: a save that HANGS never keeps the session from ending
            const argv = reel._savedFirst("logout", ["touch", root.work + "/logged-out"]);
            root.check("save step: the reason and the item's command", argv[0] === "sh" && argv[4].endsWith("/hang/lares-session") && argv[5] === "logout"
                       && JSON.stringify(reel.commandOf("logout").slice(-3)) === JSON.stringify(["hyprctl", "dispatch", "hl.dsp.exit()"])
                       && JSON.stringify(reel.commandOf("sleep")) === JSON.stringify(["systemctl", "suspend"]), JSON.stringify(argv));
            root.endAt = Date.now();
            endProc.command = argv;
            endProc.running = true;
        });
        root.step("hang over", () => root.endDone, () => {
            const log = root.logOf("hang");
            root.check("save step: the save was asked first", log.length === 1 && log[0] === "end logout", JSON.stringify(log));
            root.check("save step: a hanging save does not keep the session", root.endMs >= 2500 && root.endMs < 6000, root.endMs + " ms");
            // G. a preset's load (modules/presets) while a login's ask waits: the same engine and toasts, its own words, the ask kept
            root.posts = [];
            root.events = [];
            root.withdrawn = [];
            root.g = root.make("preset", false, true);
        }, 16000);
        root.step("preset asked", () => root.g && root.postsOf("restore").length === 1, () => {
            root.check("preset: a load is taken while the ask waits", root.g.loadPreset("dev", "replace") === true, root.g.phase);
            const pr = root.postsOf("progress");
            root.check("preset: answered at once, under the preset's name", pr.length === 1 && pr[0].title === "Loading dev", JSON.stringify(pr.map(x => x.title)));
            root.check("preset: a second load while one runs is refused", root.g.loadPreset("work", "add") === false, "");
        });
        root.step("preset loaded", () => root.g.lastResult !== null && root.postsOf("result").length === 1, () => {
            const log = root.logOf("preset");
            root.check("preset: the tool's load, the mode as asked", log.indexOf("preset load dev --replace --json --progress") >= 0 && log.indexOf("answer discard") < 0
                       && log.filter(l => l.indexOf("restore") === 0).length === 0, JSON.stringify(log));
            const p = root.postsOf("result")[0];
            root.check("preset: the result is the preset's, a window that would not close is named", p.title === "dev is loaded" && /kitty: did not close/.test(p.body), p.title + " / " + p.body);
            root.check("preset: what was done, when nothing needs the user", root.g.confirmWords(root.g.lastResult) === "2 windows opened, 6 moved into place, 1 closed", root.g.confirmWords(root.g.lastResult));
            root.check("preset: the login's ask is still answerable after the load", root.g.phase === "asking" && root.withdrawn.indexOf("restore") < 0, root.g.phase);
        });
        // H. session.jsonc resultToast and presets.confirmReplace
        root.step("result toast", () => true, () => {
            const needy = root.g.lastResult, n0 = root.postsOf("result").length;
            root.g._cfg = Object.assign({}, root.g._cfg, { resultToast: "needs", presets: { confirmReplace: false } });
            root.g.restored({ restored: 3 });
            const plain = root.postsOf("result").length - n0;
            root.g.restored(needy);
            const told = root.postsOf("result").length - n0;
            root.g._cfg = Object.assign({}, root.g._cfg, { resultToast: "off" });
            root.g.restored(needy);
            const off = root.postsOf("result").length - n0;
            root.check("result toast: \"needs\" says only what needs the user, \"off\" nothing; confirmReplace false is read",
                       plain === 0 && told === 1 && off === 1 && root.g.confirmReplace === false, JSON.stringify([plain, told, off, root.g.confirmReplace]));
        });
    }
    FileView { id: lateCfg; path: root.work + "/late/session.jsonc"; blockWrites: true; printErrors: false; watchChanges: false }

    function finish() {
        console.log("SESSION_SERVICE RESULT " + (root.fails.length === 0 && root.checks > 0 ? "PASS" : "FAIL") + " (" + root.checks + " checks"
                    + (root.fails.length ? "; failed: " + root.fails.join(", ") : "") + ")");
        quit.start();
    }
    Timer { id: quit; interval: 50; onTriggered: Qt.quit() }
    Timer { running: root.work !== ""; interval: 100; onTriggered: tick.start() }
}
