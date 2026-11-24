pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell

import "modules/wiki/data"

// tools/dev/qml/wiki_ask_probe.qml -- the wiki's refill ask: its two buttons and what each path does (tools/dev/wiki_ask_probe.sh runs it in a
// sandbox copy). The REAL WikiService on a private state dir (an empty pool: both tabs ask at the start), a recording notifier stand-in, the
// wiki's own clock pinned (`pinClock`: the probe moves it), and the tool a stub that only logs its arguments. Prints `WASK ok|FAIL <check>` and
// `WASK RESULT PASS|FAIL (<n>/<n> checks)`.
Window {
    id: win
    visible: true
    width: 80
    height: 40

    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        win.checks++;
        if (!ok)
            win.fails++;
        console.log("WASK " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    readonly property string dir: Quickshell.env("WASK_DIR") || ""

    QtObject {
        id: notifier
        signal action(string key, string id)
        property var posts: []
        function notify(key: string, spec: var): void {
            notifier.posts = notifier.posts.concat([{ key: key, spec: spec }]);
        }
        function asks(tab: string): var {
            return notifier.posts.filter(p => p.key === "refill-" + tab);
        }
    }

    property var opened: []
    WikiService {
        id: svc
        stateDir: win.dir + "/state"
        cacheDir: win.dir + "/cache"
        configPath: win.dir + "/wiki.jsonc"
        command: ["sh", "-c", 'echo "$*" >> "$WASK_DIR/tool.log"; case "$1" in batch) sleep 20;; esac', "stub"]
        notifier: notifier
        pinClock: true
        nowMs: 1800000000000
        onOpenRequested: tab => win.opened = win.opened.concat([tab])
    }

    readonly property real h: 3600000
    function toolBatches(): int {
        const x = new XMLHttpRequest();
        x.open("GET", "file://" + win.dir + "/tool.log", false);
        try {
            x.send();
        } catch (e) {
            return 0;
        }
        return (x.responseText || "").split("\n").filter(l => l.indexOf("batch ") === 0).length;
    }

    function stateFile(): string {
        const x = new XMLHttpRequest();
        x.open("GET", "file://" + win.dir + "/state/state.json", false);
        try {
            x.send();
        } catch (e) {
            return "";
        }
        return x.responseText || "";
    }

    property real t0: 0
    property int idx: -1
    property var cur: null
    property var mark: ({})

    property var steps: [
        { name: "wiki.jsonc families: a subject switched off leaves the picks' and the batches' config, the others stay", after: 0,
          check: () => { const ids = svc._tabCfg("discover").families.map(f => f.id); return svc.config.families.people === false && ids.indexOf("people") < 0 && ids.indexOf("history") >= 0; },
          detail: () => JSON.stringify(svc._tabCfg("discover").families.map(f => f.id)) },
        { name: "the ask is posted at the start, for both tabs", until: () => notifier.asks("discover").length === 1 && notifier.asks("deepen").length === 1, within: 5000, detail: () => JSON.stringify(notifier.posts.map(p => p.key)) },
        { name: "the card has a body click and two buttons: Process 30 now, Later", after: 0,
          check: () => { const a = notifier.asks("discover")[0].spec.actions; return a.length === 3 && a[0].id === "default" && a[1].id === "process" && a[1].label === "Process 30 now" && a[2].id === "later" && a[2].label === "Later"; },
          detail: () => JSON.stringify(notifier.asks("discover")[0].spec.actions) },
        { name: "(settle)", ms: 300 },

        { name: "a body click opens the wiki on the tab and starts nothing", act: () => { win.opened = []; notifier.action("refill-discover", "default"); }, after: 150,
          check: () => JSON.stringify(win.opened) === '["discover"]' && !svc.batch.running && !svc.batchPending && svc.askState.discover.answered === false && svc.askState.discover.later === false,
          detail: () => JSON.stringify(win.opened) + " running " + svc.batch.running + " " + JSON.stringify(svc.askState.discover) },

        { name: "Later closes the ask: deferred, not answered, nothing started", act: () => { win.mark.at = svc.nowMs; win.opened = []; notifier.action("refill-discover", "later"); }, after: 150,
          check: () => svc.askState.discover.later === true && svc.askState.discover.answered === false && svc.askState.discover.at === win.mark.at && !svc.batch.running && win.opened.length === 0,
          detail: () => JSON.stringify(svc.askState.discover) },
        { name: "Later is in state.json (it survives a restart)", after: 600, check: () => { const o = JSON.parse(win.stateFile() || "{}"); return !!o.ask && !!o.ask.discover && o.ask.discover.later === true; }, detail: () => win.stateFile().substring(0, 300) },
        { name: "Later pressed again on the deferred ask changes nothing (its 24 h are not pushed on)", act: () => { svc.nowMs = win.mark.at + win.h; notifier.action("refill-discover", "later"); }, after: 150,
          check: () => svc.askState.discover.at === win.mark.at && svc.askState.discover.later === true, detail: () => JSON.stringify(svc.askState.discover) },
        { name: "Process on the deferred ask's old card starts nothing, it opens the wiki", act: () => { win.opened = []; notifier.action("refill-discover", "process"); }, after: 150,
          check: () => !svc.batch.running && JSON.stringify(win.opened) === '["discover"]' && svc.askState.discover.later === true, detail: () => JSON.stringify(win.opened) + " " + svc.batch.running },

        { name: "Later is not re-posted at a restart (the start's repost skips it, the other tab's unanswered ask comes again)",
          act: () => { win.mark.n = notifier.asks("discover").length; win.mark.d = notifier.asks("deepen").length; svc._askedNow = ({}); svc._repostAsks(); }, after: 100,
          check: () => notifier.asks("discover").length === win.mark.n && notifier.asks("deepen").length === win.mark.d + 1,
          detail: () => "discover " + notifier.asks("discover").length + " (was " + win.mark.n + "), deepen " + notifier.asks("deepen").length + " (was " + win.mark.d + ")" },
        { name: "the ask is silent before 24 h", act: () => { svc.nowMs = win.mark.at + 24 * win.h - 1000; svc._evalRefill(); }, after: 100,
          check: () => notifier.asks("discover").length === win.mark.n && svc.askState.discover.later === true, detail: () => notifier.asks("discover").length + " " + JSON.stringify(svc.askState.discover) },
        { name: "the ask comes again after 24 h", act: () => { svc.nowMs = win.mark.at + 24 * win.h + 1000; svc._evalRefill(); }, after: 100,
          check: () => notifier.asks("discover").length === win.mark.n + 1 && svc.askState.discover.later === false && svc.askState.discover.answered === false, detail: () => notifier.asks("discover").length + " " + JSON.stringify(svc.askState.discover) },

        // the ask is open again: Process starts the batch; the cards of it are stale from then on
        { name: "Process now starts the batch (the tab's, 30 items, the ask answered, ONE tool run)", act: () => notifier.action("refill-discover", "process"),
          until: () => svc.batch.running === true && svc.batch.tab === "discover" && svc.askState.discover.answered === true && svc.batch.total === 30 && win.toolBatches() === 1, within: 3000,
          detail: () => JSON.stringify(svc.batch) + " " + JSON.stringify(svc.askState.discover) + " tool runs " + win.toolBatches() },
        { name: "a stale card's Process starts nothing (it opens the wiki)", act: () => { win.opened = []; notifier.action("refill-discover", "process"); notifier.action("refill-deepen", "process"); }, after: 300,
          check: () => win.toolBatches() === 1 && svc.batch.tab === "discover" && JSON.stringify(win.opened) === '["discover","deepen"]' && svc.askState.deepen.answered === false,
          detail: () => "tool runs " + win.toolBatches() + " opened " + JSON.stringify(win.opened) + " " + JSON.stringify(svc.askState.deepen) },
        { name: "a stale card's Later does nothing harmful (the answered ask stays answered)", act: () => { win.opened = []; notifier.action("refill-discover", "later"); notifier.action("refill-deepen", "later"); }, after: 300,
          check: () => svc.askState.discover.answered === true && svc.askState.discover.later === false && svc.askState.deepen.later === false && win.toolBatches() === 1 && win.opened.length === 0,
          detail: () => JSON.stringify(svc.askState) },

        // SEEN (the user, 2026-11-12): only READING in the wiki detail makes an article seen -- 5 s, per tab; a card on screen anywhere
        // else (shown) never does, however long.
        { name: "a card on screen elsewhere never makes its article seen (shown, 60 s)", act: () => { svc.shown("discover", "wseen-glance", 60000); }, after: 600,
          check: () => { const o = JSON.parse(win.stateFile() || "{}"); return !!o.seen && o.seen["wseen-glance"] === undefined; }, detail: () => JSON.stringify((JSON.parse(win.stateFile() || "{}")).seen) },
        { name: "read in the detail under 5 s is not seen; at 5 s it is", act: () => { svc.read("discover", "wseen-read", 4000); win.mark.early = (JSON.parse(win.stateFile() || "{}").seen || {})["wseen-read"]; svc.read("discover", "wseen-read", 5000); }, after: 600,
          check: () => { const o = JSON.parse(win.stateFile() || "{}"); return win.mark.early === undefined && typeof o.seen["wseen-read"] === "number"; }, detail: () => "early " + win.mark.early + " " + JSON.stringify((JSON.parse(win.stateFile() || "{}")).seen) },
        { name: "each tab on its own: Discover read leaves Deepen's article unseen", act: () => { svc.read("discover", "wseen-disc", 6000); svc.shown("deepen", "wseen-deep", 6000); }, after: 600,
          check: () => { const o = JSON.parse(win.stateFile() || "{}"); return typeof o.seen["wseen-disc"] === "number" && o.seen["wseen-deep"] === undefined; }, detail: () => JSON.stringify((JSON.parse(win.stateFile() || "{}")).seen) }
    ]

    function next(): void {
        win.idx++;
        if (win.idx >= win.steps.length) {
            console.log("WASK RESULT " + (win.fails === 0 ? "PASS" : "FAIL") + " (" + (win.checks - win.fails) + "/" + win.checks + " checks)");
            Qt.callLater(Qt.quit);
            return;
        }
        win.cur = win.steps[win.idx];
        if (win.cur.act)
            win.cur.act();
        win.t0 = Date.now();
        poll.restart();
    }
    Timer {
        id: poll
        interval: 20
        repeat: true
        onTriggered: {
            const s = win.cur;
            const el = Date.now() - win.t0;
            if (s.until) {
                if (s.until()) {
                    poll.stop();
                    win.check(s.name, true, "");
                    win.next();
                } else if (el > s.within) {
                    poll.stop();
                    win.check(s.name, false, "not within " + s.within + " ms: " + (s.detail ? s.detail() : ""));
                    win.next();
                }
            } else if (s.check) {
                if (el >= s.after) {
                    poll.stop();
                    win.check(s.name, !!s.check(), s.detail ? s.detail() : "");
                    win.next();
                }
            } else if (el >= (s.ms || 0)) {
                poll.stop();
                win.next();
            }
        }
    }
    // A bare load (tools/dev/smoke.sh, no runner) has no WASK_DIR: it drives nothing -- no stub tool, no file reads -- and quits.
    Timer {
        interval: 1500
        running: win.dir !== ""
        onTriggered: win.next()
    }
    Timer {
        interval: 0
        running: win.dir === ""
        onTriggered: {
            console.log("WASK bare load: nothing driven (run tools/dev/wiki_ask_probe.sh)");
            Qt.quit();
        }
    }
    Timer {
        interval: 60000
        running: win.dir !== ""
        onTriggered: {
            console.log("WASK FAIL the probe did not finish (step " + win.idx + ")");
            console.log("WASK RESULT FAIL (timeout)");
            Qt.quit();
        }
    }
}
