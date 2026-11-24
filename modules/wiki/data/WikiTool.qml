pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../../common/system"

// =============================================================================
// WikiTool.qml -- the runner of tools/wiki/wiki.py: every network, text and
// model step of the module lives in that program; this file only starts it,
// feeds it, and turns its NDJSON into signals (CONTRACT.md, "tools/wiki/wiki.py").
//
//   load(url, tab, allowGenerate)     the rabbit hole: `entry` (provisional), then
//                                     maybe `upgrade`, then loadFinished
//   daily(day)                        On this day + the Picture of the day
//   saveNote(tab, id, root, folder)   a markdown note into the Notes module's folder
//   batch(tab, n, resume, stdin)      the long one: every event as batchEvent
//   cancelBatch()
//
// ONE PROCESS PER JOB KIND (load, daily, save, batch): a job of a kind that is
// still running is REPLACED by the newer (SIGTERM, then the newer starts once
// the old has exited; the old one's events are dropped from the moment it is
// replaced and it reports nothing) -- the reader who Ctrl+clicks two links has
// asked for the second. Different kinds run side by side.
//
// THE COMMAND. `command` is the program and its leading arguments, an ARRAY
// (["python3", <repo>/tools/wiki/wiki.py]); a probe points it at a stub. The
// argv is built from arrays and handed to the Process as an array -- no shell
// string exists anywhere, so a URL or a title with a quote in it is one argument.
// `setpriv --pdeathsig TERM --` goes in front: the child dies with the shell
// however the shell dies (CLAUDE.md). The secret (`jevKey` of config/wiki.jsonc)
// is read by the tool itself; nothing here forwards it: it is in no argv or environment.
//
// `env` is what the tool is told of the user's config, as environment variables
// on every job: WIKI_OLLAMA_URL, WIKI_JEV ("1" / "0"), WIKI_SOURCES (JSON of the
// source toggles). WIKI_HTTP_MAP and the like pass through from the shell's own.
//
// STDIN. Every job's stdin is opened, written (the payload, or nothing) and
// closed again: `stdinEnabled` true before the start, write() in onStarted,
// false -- that is the EOF. The Process default leaves stdin open for ever, and a
// child that reads it to the end would hang.
//
// EVENTS. SplitParser slices are not always lines in Quickshell 0.3.1 (an empty
// line that follows another in the same read is not emitted and the next slice
// starts with its "\n"), so every slice is split on "\n" again.
//
// RESULTS ARE CACHED for the session: a followed page (LRU 50, with its upgrade)
// and a day's extras. The tool has its own on-disk cache (live/, daily/); this
// one makes the second follow of a page this run free of a process.
// =============================================================================
Item {
    id: root

    property var command: ["python3", RepoRoot.dir + "/tools/wiki/wiki.py"]
    property var env: ({})
    property int cacheCap: 50

    readonly property bool loadBusy: loadRun.running
    readonly property bool dailyBusy: dailyRun.running
    readonly property bool saveBusy: saveRun.running
    readonly property bool batchBusy: batchRun.running
    readonly property int batchPid: batchRun.pid
    readonly property bool busy: root.loadBusy || root.dailyBusy || root.saveBusy || root.batchBusy

    signal entry(string tab, string url, var entry, bool provisional)
    signal upgrade(string tab, string url, string id, var intro)
    signal loadFinished(string tab, string url, int code, string error)
    signal dailyLoaded(var daily)
    signal dailyFinished(string day, int code, string error)
    signal saved(string tab, string id, string path, string key)
    signal saveFinished(string tab, string id, int code, string error)
    signal batchEvent(string tab, var ev)
    signal batchFinished(string tab, int code, string error)
    signal batchStarted(string tab)

    // -> "cached" when the answer was served from the session's cache, "started", or "refused"
    function load(url, tab, allowGenerate) {
        if (!/^https?:\/\/\S+$/.test(String(url))) return "refused";
        const key = tab + "|" + url + "|" + (allowGenerate ? 1 : 0);
        const hit = root._loadCache[key];
        if (hit) {
            root.entry(tab, url, hit.entry, hit.provisional);
            if (hit.upgrade) root.upgrade(tab, url, hit.upgrade.id, hit.upgrade.intro);
            root.loadFinished(tab, url, 0, "");
            return "cached";
        }
        const args = ["load", "--url", String(url), "--tab", tab];
        if (allowGenerate) args.push("--allow-generate");
        loadRun.start(args, "", { tab: tab, url: String(url), key: key });
        return "started";
    }

    function daily(day) {
        const hit = day ? root._dailyCache[day] : null;
        if (hit) {
            root.dailyLoaded(hit);
            root.dailyFinished(day, 0, "");
            return "cached";
        }
        dailyRun.start(day ? ["daily", "--day", day] : ["daily"], "", { day: day || "" });
        return "started";
    }

    function saveNote(tab, id, notesRoot, folder) {
        saveRun.start(["save-note", "--tab", tab, "--id", id, "--notes-root", notesRoot, "--folder", folder],
                      "", { tab: tab, id: id });
        return "started";
    }

    // stdin: the JSON text of the plan (a string; "" for a resume that needs none).
    function batch(tab, n, resume, stdin) {
        const args = ["batch", "--tab", tab, "--n", String(n)];
        if (resume) args.push("--resume");
        batchRun.start(args, stdin || "", { tab: tab });
        root.batchStarted(tab);
        return "started";
    }

    function cancelBatch() { batchRun.cancel(); }

    // ---- private -------------------------------------------------------------------
    property var _loadCache: ({})
    property var _loadOrder: []
    property var _dailyCache: ({})

    readonly property var _base: ["setpriv", "--pdeathsig", "TERM", "--"].concat(root.command)

    function _rememberLoad(key, value) {
        if (root._loadCache[key] === undefined) root._loadOrder.push(key);
        root._loadCache[key] = value;
        while (root._loadOrder.length > root.cacheCap)
            delete root._loadCache[root._loadOrder.shift()];
    }

    function _onLoad(ev, job) {
        if (ev.ev === "entry" && ev.entry) {
            root._rememberLoad(job.key, { entry: ev.entry, provisional: ev.provisional === true, upgrade: null });
            root.entry(job.tab, job.url, ev.entry, ev.provisional === true);
        } else if (ev.ev === "upgrade" && ev.intro) {
            const hit = root._loadCache[job.key];
            if (hit) hit.upgrade = { id: String(ev.id || ""), intro: ev.intro };
            root.upgrade(job.tab, job.url, String(ev.id || ""), ev.intro);
        }
    }

    function _onDaily(ev, job) {
        if (ev.ev !== "daily" || !ev.daily) return;
        if (job.day) root._dailyCache[job.day] = ev.daily;
        else if (ev.daily.day) root._dailyCache[ev.daily.day] = ev.daily;
        root.dailyLoaded(ev.daily);
    }

    function _onSave(ev, job) {
        if (ev.ev === "saved") root.saved(job.tab, job.id, String(ev.path || ""), String(ev.key || ""));
    }

    // One job kind: a Process, the replace rule, the NDJSON split, the EOF.
    component Runner: Item {
        id: run

        property var base: []
        property var extraEnv: ({})
        property var job: null
        // Events are delivered only while the job is the one that was asked for.
        property bool live: false
        property string errText: ""
        property string failReason: ""
        property var pending: null
        property string stdinText: ""
        readonly property bool running: proc.running
        readonly property int pid: proc.processId ? proc.processId : 0

        signal event(var ev, var job)
        signal finished(int code, string error, var job)

        function start(args, stdin, job) {
            if (proc.running) {
                run.pending = { args: args, stdin: stdin, job: job };
                run.live = false;
                proc.signal(15);
                return;
            }
            run._launch(args, stdin, job);
        }

        function cancel() {
            run.pending = null;
            if (proc.running) proc.signal(15);
        }

        function _launch(args, stdin, job) {
            run.job = job;
            run.errText = "";
            run.failReason = "";
            run.stdinText = stdin;
            run.live = true;
            proc.command = run.base.concat(args);
            proc.environment = run.extraEnv;
            proc.stdinEnabled = true;
            proc.running = true;
        }

        function _onOut(data) {
            if (!run.live) return;
            const parts = String(data).split("\n");
            for (let i = 0; i < parts.length; i++) {
                if (parts[i].length === 0) continue;
                let ev = null;
                try { ev = JSON.parse(parts[i]); } catch (e) { ev = null; }
                if (!ev || typeof ev.ev !== "string") continue;
                if (ev.ev === "fail" && ev.reason) run.failReason = String(ev.reason);
                if (ev.ev === "blocked" && ev.reason) run.failReason = String(ev.reason);
                run.event(ev, run.job);
            }
        }

        Process {
            id: proc
            running: false
            stdout: SplitParser { onRead: data => run._onOut(data) }
            stderr: SplitParser {
                onRead: data => {
                    const s = String(data).trim();
                    if (s.length) run.errText = s;
                }
            }
            onStarted: {
                proc.write(run.stdinText);
                proc.stdinEnabled = false;
            }
        }
        Connections {
            target: proc
            function onExited(code, status) {
                run.live = false;
                if (run.pending) {                    // replaced: the old job reports nothing
                    const p = run.pending;
                    run.pending = null;
                    run._launch(p.args, p.stdin, p.job);
                    return;
                }
                run.finished(code, run.failReason || run.errText, run.job);
            }
        }
    }

    Runner {
        id: loadRun
        base: root._base
        extraEnv: root.env
        onEvent: (ev, job) => root._onLoad(ev, job)
        onFinished: (code, error, job) => root.loadFinished(job.tab, job.url, code, error)
    }
    Runner {
        id: dailyRun
        base: root._base
        extraEnv: root.env
        onEvent: (ev, job) => root._onDaily(ev, job)
        onFinished: (code, error, job) => root.dailyFinished(job.day, code, error)
    }
    Runner {
        id: saveRun
        base: root._base
        extraEnv: root.env
        onEvent: (ev, job) => root._onSave(ev, job)
        onFinished: (code, error, job) => root.saveFinished(job.tab, job.id, code, error)
    }
    Runner {
        id: batchRun
        base: root._base
        extraEnv: root.env
        onEvent: (ev, job) => root.batchEvent(job.tab, ev)
        onFinished: (code, error, job) => root.batchFinished(job.tab, code, error)
    }
}
