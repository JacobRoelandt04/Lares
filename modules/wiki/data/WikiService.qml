pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "Interest.js" as Interest
import "WikiPool.js" as Pool
import "../../common/components"
import "../../common/system"

// =============================================================================
// WikiService.qml -- the wiki module's data layer: the pool on disk, the day's
// pick per tab, what the reader does with it, and the ask to fill the pool up.
//
// The contract is docs/contracts/wiki.md ("QML surfaces");
// WikiMock has the same members. The pure decisions are Interest.js (what the
// reader likes: discounted Thompson sampling), WikiPool.js (the day, the slots,
// the refill latch) and WikiCardModel.js (the card); the getters are
// WikiViewModel's. This file decides WHEN to do what and keeps the state.
//
// WHO WRITES WHAT (CONTRACT.md "Paths")
//   the tool  (tools/wiki/wiki.py)   index.json, entries/, img/, batch/, the caches
//   this file (through WikiState)    state.json -- the only writer
//   the reader                       wiki.jsonc (WikiConfig reads it, never writes)
//
// THE DAY. It rolls at `rolloverHour` (04:00) LOCAL: `day` is Pool.dayKey(nowMs).
// A BoundaryClock wakes the service at the next 04:00 of the WALL clock and
// re-arms itself for the one after (it also re-reads the wall on a resume from
// suspend, and at least once a minute, so a stepped clock is found too). A day
// that ends with the article unseen carries it over; a seen one is replaced by
// a fresh Thompson pick, seeded by (day, tab, pick number): the same pool and
// the same history give the same pick, a probe can rely on it, and the reader's
// "next" is one more pick of the same day. `nowMs` is the wiki's clock: the
// wall, refreshed at every ask, unless `pinClock` holds it (probes, the mock).
//
// SEEN. `shown(tab, id, visibleMs)` is told the CUMULATIVE time a card has
// been fully on screen, unlocked and not idle (the service takes the largest
// figure per id: it decides `quick_next`); it never makes an article seen.
// Only READING does (the user, 2026-11-12: the compact card in the manager made
// articles seen without a look): `read(tab, id, readMs)` comes from the wiki
// detail the user opened (WikiPopup, the clock's secondary) with its cumulative
// time on that tab's article, and at `seenMs` (5 s) the article is seen for
// good: it is in state.seen, its slot notes it, a `seen` event goes to the
// interest engine (an exposure), and the pool's unseen count drops. Each tab is
// its own: Discover read and Deepen never opened replaces Discover's alone.
// "next" before `quickNextMs` is a `quick_next` (weak negative).
//
// THE ASK. After every change of an unseen count each tab runs
// Pool.needsRefill: when it says ask, ONE notification per tab
// ("Only 5 Discover entries left — process 30 new ones now?") with two buttons,
// "Process 30 now" (`process`) and "Later" (`later`); a body click (`default`)
// only opens the wiki on the tab. The latch is in state, so an evaluation of the
// same numbers is silent, and an ask nobody answered is posted again after a
// reload -- but not one put off with "Later", which comes back after 24 h
// (`later` in the latch, Pool.reaskMs). Answering starts a batch: the plan is
// Interest.planBatch over the tab (every plan item a fresh Thompson sample),
// the recent titles the reader opened go along, and progress is ONE
// notification (key `progress`) updated in place.
//
// THE GPU IS NOBODY'S CHORE. A batch writes intros with the local model on the dGPU, which Integrated and Smart keep
// blocked and which ollama may have started without. Before the batch the service asks OllamaGpu (modules/common/system,
// holder "wiki"; the shell's ONE, injected as `sharedGpu` -- the LLM chat holds the same card) for the card -- Hybrid, the card awake, ollama restarted if it came up blind (the
// polkit rule the user installs once: tools/wiki/polkit/) -- shows what it is doing in the progress notification, starts the
// batch, and after it puts the mode back unless the user moved it meanwhile. Nothing to drive (`silicon` null, no cardwire:
// the mock, a probe) = the batch starts and the tool's own guard decides.
//
// THE NOTIFIER is injected (`notifier`, the stocks pattern): a DesktopNotifier
// whose `keys` list `notifyKeys` (each has a slot of its own, so the two asks and
// the progress do not replace each other). Null = silent.
//
// GETTERS NEVER ASK (they read WikiViewModel, which reads `serial` first);
// asks are called from handlers.
// =============================================================================
Item {
    id: root

    // ---- status ---------------------------------------------------------------------
    property bool popupOpen: false
    property real nowMs: Date.now()
    // Hold nowMs where it is (a probe): the wall clock no longer moves it.
    property bool pinClock: false
    readonly property bool ready: root._ready
    readonly property bool offline: root._offline
    readonly property bool busy: runner.busy || batcher.running
    readonly property string lastError: root._lastError
    readonly property string day: root._day
    readonly property int serial: vm.serial
    readonly property var daily: vm.daily
    readonly property var batch: batcher.status
    // The refill latches, { discover, deepen }: { latchedAt, at, answered, later } (the probes and the mockup read them)
    readonly property var askState: st.ask
    // A batch is asked for and waits for the dGPU (it has not started: `batch.running` is false); the idle auto layer counts it
    readonly property bool batchPending: root._gpuJob !== null
    readonly property var config: cfg.config

    property string configPath:
        (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/quickshell/config/wiki.jsonc"
    property string stateDir:
        (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/lares/wiki"
    property string cacheDir:
        (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/lares/wiki"
    // The tool: an ARRAY, ["python3", <shellDir>/tools/wiki/wiki.py] by default.
    property alias command: runner.command
    property bool dryRun: false
    property var notifier: null
    // The shell's silicon service (SiliconService | SiliconMock): the GPU mode is asked of it. Null = not driven. Read by the
    // service's OWN helper only (a standalone service, a probe); with `sharedGpu` it is the shell's helper's silicon.
    property var silicon: null
    // The shell's one OllamaGpu (ShellServices). Null = this service builds its own, over `silicon`.
    property var sharedGpu: null
    // The helper in use, and for a probe the commands of the own one (OllamaGpu has the machine's).
    readonly property var gpu: root.sharedGpu ? root.sharedGpu : ownGpu
    // The notification keys this service uses; the owner's DesktopNotifier lists them.
    readonly property var notifyKeys: ["refill-discover", "refill-deepen", "progress"]

    signal updated()
    signal openRequested(string tab)
    signal noteSaved(string tab, string id, bool ok, string keyOrError)
    signal refillAsked(string tab, int left)
    signal batchFinished(string tab, int ok, int failed)
    signal urlOpened(string url)

    // ---- getters (read only, never ask) ------------------------------------------------
    function card(tab) { return vm.card(tab); }
    function trail(tab) { return vm.trail(tab); }
    function canBack(tab) { return vm.canBack(tab); }
    function unseen(tab) { return vm.unseen(tab) - root._offUnseen(tab); }
    function loading(tab) { return vm.loading(tab); }
    function whyText(card) { return vm.whyText(card); }

    // ---- asks -----------------------------------------------------------------------------
    // The day's article of each tab: kept while it is the day's or unseen, else a new pick.
    function ensureSlots() {
        for (let i = 0; i < st.tabs.length; i++)
            root._ensureSlot(st.tabs[i]);
    }

    function shown(tab, id, visibleMs) {
        root._now();
        if (!id || !(visibleMs > 0)) return;
        if (!(root._visible[id] >= visibleMs)) root._visible[id] = visibleMs;
    }

    function read(tab, id, readMs) {
        root.shown(tab, id, readMs);
        if (!id || st.seen[id] || !Pool.seenDue(readMs, { seenMs: cfg.config.seenMs })) return;
        root._markSeen(tab, id, readMs, true);
    }

    function hoverDwell(tab, id, ms) {
        root._now();
        if (!id || !(ms >= cfg.config.dwellMs) || root._dwelled[id]) return;
        root._dwelled[id] = true;
        root._event(tab, id, "dwell");
    }

    // A new pick, never the card on show. Nothing to show = nothing changes.
    function next(tab) {
        root._now();
        const slot = st.slots[tab];
        const pick = Pool.nextFor(tab, root._rowsOf(tab), st.seen, st.interest[tab], root._tabCfg(tab),
                                  root.nowMs, root._rng(tab), null, slot ? slot.id : null);
        if (!pick.id) return false;
        if (slot && slot.id) {
            if ((root._visible[slot.id] || 0) < cfg.config.quickNextMs) root._event(tab, slot.id, "quick_next");
            if (!st.seen[slot.id]) {
                st.markSeen(slot.id, root.nowMs);        // skipped is done: no re-presentation
                vm.setSeen(st.seen);
            }
        }
        // A page still on its way for the article being left is forgotten: landing late it would push the NEW article onto the trail
        // and show the old one's rabbit hole on every reader (the late `entry` finds no follow and is dropped).
        root._follows[tab] = null;
        if (!root._takeSlot(tab, { day: root._day, id: pick.id, shownMs: 0, why: pick.why })) {
            root._ensureSlot(tab);
        }
        root._syncLoading();
        root._afterCounts();
        root.updated();
        return true;
    }

    // THE BUTTONS ARE A CHOICE, NOT AN EVENT: a choice is reversible for the instance of a
    // misclick, and at the turnover time it gets processed and is then irreversible. A press is kept
    // per card in state.choices: More and Less are ONE choice (the other switches it, the same again undoes it), "I
    // knew this" is its own switch. `interest` hears nothing until the day rolls over (_commitChoices), so what the
    // reader presses today does not steer today's picks and can still be taken back. `choiceOf` is what the buttons
    // show; it reads `choiceSerial`, which every press bumps.
    property int choiceSerial: 0
    function choiceOf(tab, id) {
        void root.choiceSerial;
        const c = st.choices[tab + "|" + id];
        return { more: !!c && c.taste === "more", less: !!c && c.taste === "less", knew: !!c && c.knew === true };
    }
    function more(tab, id) { root._press(tab, id, "more"); }
    function less(tab, id) { root._press(tab, id, "less"); }
    function knew(tab, id) { root._press(tab, id, "knew"); }
    function _press(tab, id, kind) {
        root._now();
        const key = tab + "|" + id;
        const facts = root._facts(tab, id);
        const old = st.choices[key];
        if (!facts && !old) return;
        const c = old ? Object.assign({}, old) : Object.assign({ taste: "", knew: false, day: root._day }, facts);
        if (kind === "knew") c.knew = !c.knew;
        else c.taste = c.taste === kind ? "" : kind;
        c.at = Math.round(root.nowMs);
        st.setChoice(key, c.taste === "" && !c.knew ? null : c);
        root.choiceSerial++;
    }
    // The pending choices of a day gone by become interest events, once, at the turnover (and at a start that finds
    // some of an earlier day).
    function _commitChoices() {
        if (!st.loaded) return;
        for (const key in st.choices) {
            const c = st.choices[key];
            if (c.day === root._day) continue;
            const tab = key.substring(0, key.indexOf("|"));
            const base = { f: c.f, t: c.t, at: c.at };
            if (typeof c.band === "number") base.band = c.band;
            if (c.taste !== "") st.record(tab, Object.assign({ k: c.taste }, base));
            if (c.knew) st.record(tab, Object.assign({ k: "knew" }, base));
            st.setChoice(key, null);
            root.choiceSerial++;
        }
    }

    function openSource(tab, id) {
        root._now();
        const c = vm.cardFor(tab, id);
        const url = c ? c.source.url : "";
        if (!/^https?:\/\/\S+$/.test(url)) return;
        root._event(tab, id, "open");
        st.noteOpened(id, c.title, root.nowMs);
        if (!st.seen[id]) root._markSeen(tab, id, root._visible[id] || 0, false);
        if (!root.dryRun) Qt.openUrlExternally(url);
        root.urlOpened(url);
    }

    // A plain click on a link in the intro: open it in the browser. Reading on from
    // the card is interest in its topic, so it counts as a follow for the interest
    // model (the rabbit hole's Ctrl+click records the same kind).
    function openLink(tab, id, url) {
        root._now();
        if (!/^https?:\/\/\S+$/.test(String(url))) return;
        if (vm.cardFor(tab, id)) root._event(tab, id, "follow");
        if (!root.dryRun) Qt.openUrlExternally(url);
        root.urlOpened(String(url));
    }

    // The rabbit hole. `link` is one of the card's introLinks ({url, target, ...}).
    function follow(tab, link) {
        root._now();
        const url = link && typeof link.url === "string" ? link.url : "";
        if (!/^https?:\/\/\S+$/.test(url)) return;
        const from = vm.card(tab);
        if (!from) return;
        // One page load runs at a time (a new one replaces the running one): the
        // other tab's follow, if it was still on its way, is over.
        for (const other of st.tabs) {
            if (other !== tab && root._follows[other]) {
                root._follows[other] = null;
            }
        }
        root._event(tab, from.id, "follow");
        root._follows[tab] = { url: url, parentTitle: from.title, landed: false };
        runner.load(url, tab, true);
        root._syncLoading();
    }

    function followOnThisDay() {
        const o = vm.daily ? vm.daily.otd : null;
        if (o && o.url) root.follow("discover", { url: o.url, target: o.title || "" });
    }

    function back(tab) {
        root._follows[tab] = null;
        vm.back(tab);
        root._syncLoading();
        root.updated();
    }

    // The card is closed: the trails go, a page still on its way is forgotten.
    function closeCard() {
        root._follows = ({});
        vm.closeCard();
        root._syncLoading();
        root.updated();
    }

    function saveToNote(tab, id) {
        root._now();
        const c = vm.cardFor(tab, id);
        if (!c) {
            root.noteSaved(tab, id, false, "no such card");
            return;
        }
        if (runner.saveBusy) {
            root.noteSaved(tab, id, false, "another note is being saved");
            return;
        }
        root._saves[tab + "|" + id] = { done: false };
        runner.saveNote(tab, id, root._expand(cfg.config.notesRoot), cfg.config.notesFolder);
    }

    function startBatch(tab) {
        root._now();
        const n = cfg.config.batchSize;
        const plan = Interest.planBatch(st.interest[tab], root._tabCfg(tab), n, root.nowMs, root._rng(tab));
        if (plan.length === 0) {
            root._toolError = "nothing to plan for " + root._label(tab) + " (every source of the tab is off)";
            root.updated();
            return;
        }
        const recent = [];
        for (let i = st.opened.length - 1; i >= 0 && recent.length < 10; i--) recent.push(st.opened[i].title);
        const job = { tab: tab, n: n, payload: { plan: plan, recent: recent, n: n, sources: cfg.config.sources } };
        // A batch already running holds the card (this one queues behind it); the GPU is asked for once, by the first.
        if (!root.gpu.drivable || batcher.running || root._gpuJob) {
            root._launch(job);
            return;
        }
        root._gpuJob = job;
        root.gpu.acquire("wiki");
    }

    property var _gpuJob: null
    function _launch(job) {
        batcher.start(job.tab, job.n, job.payload);
        root._syncLoading();
    }

    // The GPU's moments are the progress notification's words, and its failure is a batch that was refused (the card, not the
    // machine, is what is missing): paused with the reason, nothing else started.
    Connections {
        target: root.gpu
        function onPhaseChanged() { root._postGpuStep(); }
        function onReadyFor(holder) {
            if (holder !== "wiki")
                return;
            const job = root._gpuJob;
            root._gpuJob = null;
            if (job)
                root._launch(job);
        }
        function onFailedFor(holder, why) {
            if (holder !== "wiki")
                return;
            const job = root._gpuJob;
            root._gpuJob = null;
            if (!job)
                return;
            root._toolError = why;
            root._postProgress(true, { tab: job.tab, ok: 0, failed: 0, generated: 0, blocked: true, offline: false, code: 1, error: why });
            root.batchFinished(job.tab, 0, 0);
            root.updated();
        }
    }
    function _postGpuStep() {
        const say = root.gpu.sayOf(root.gpu.phase);
        if (!root.notifier || !root._gpuJob || say === "") return;
        root.notifier.notify("progress", { live: true, title: "Wiki · " + root._label(root._gpuJob.tab), body: "Getting ready — " + say + "…",
                                           urgency: "low", timeoutMs: 0, actions: [{ id: "default", label: "Open" }] });
    }
    // The batch is over (and nothing queued behind it): the mode before it goes back.
    function _afterBatchGpu() {
        if (!batcher.running)
            root.gpu.release("wiki");
    }

    function refresh() {
        root._now();
        indexFile.reload();
        root._dayCheck();
        root.ensureSlots();
        root._evalRefill();
        root._loadDaily();
        root.updated();
    }

    function requestOpen(tab) { root.openRequested(tab); }

    // ==========================================================================================
    // Private
    // ==========================================================================================
    property bool _ready: false
    property bool _indexRead: false
    property string _indexRaw: ""
    property string _day: ""
    property bool _offline: false
    property string _toolError: ""
    property real _nextRollover: 0
    property var _pickN: ({})
    property var _visible: ({})          // id -> the largest visible ms reported
    property var _dwelled: ({})
    property var _follows: ({})          // tab -> { url, parentTitle, landed } while a page is on its way
    property var _saves: ({})            // "tab|id" -> { done } while a note is being written
    property bool _progressDirty: false
    property var _askedNow: ({})         // tab -> true once this run has posted its ask
    property bool _asksArmed: false      // false until the tree has completed (see `startup`)
    readonly property string _lastError: {
        const parts = [cfg.lastError, root._toolError];
        return parts.filter(function (x) { return x; }).join("; ");
    }
    readonly property var _toolEnv: ({
        WIKI_OLLAMA_URL: cfg.config.ollamaUrl,
        WIKI_JEV: cfg.config.jev ? "1" : "0",
        WIKI_SOURCES: JSON.stringify(cfg.config.sources),
        WIKI_JEV_CAP_USD: String(cfg.config.jevCapUsd),
        WIKI_MODEL_WRITE: cfg.config.models.write,
        WIKI_MODEL_JUDGE: cfg.config.models.judge
    })

    WikiConfig { id: cfg; configPath: root.configPath }
    WikiState { id: st; statePath: root.stateDir + "/state.json" }
    WikiViewModel { id: vm; stateDir: root.stateDir }
    WikiTool { id: runner; env: root._toolEnv }
    WikiBatch { id: batcher; tool: runner; stateDir: root.stateDir }
    // Standalone only (the shell injects its one). Live: it is handed a silicon only by a host that means the machine.
    OllamaGpu { id: ownGpu; silicon: root.sharedGpu ? null : root.silicon; live: true; ollamaUrl: cfg.config.ollamaUrl }
    // Not gated by a host that hides: the day rolls whatever is on screen.
    BoundaryClock { id: clock; active: true }

    FileView {
        id: indexFile
        path: root.stateDir + "/index.json"
        blockLoading: true
        printErrors: false
        watchChanges: false
        onLoaded: root._readIndex(indexFile.text())
        onTextChanged: root._readIndex(indexFile.text())
    }
    // A reload() of a loaded FileView lands a moment later than the call: the
    // new bytes arrive through onLoaded / onTextChanged, and equal bytes are
    // not news (_readIndex compares them).
    Timer {
        id: indexSlow
        interval: 5 * 60000
        repeat: true
        running: true
        onTriggered: indexFile.reload()
    }
    Timer {
        id: indexSoon
        interval: 250
        onTriggered: indexFile.reload()
    }
    // The asks of the start wait for the tree: the notifier's slots (a Repeater) may
    // not have been built when this component completes, and a post to a slot that
    // is not there is lost without a word.
    Timer {
        id: startup
        interval: 0
        onTriggered: {
            root._asksArmed = true;
            root._evalRefill();
            root._repostAsks();
        }
    }
    Timer {
        id: progressTimer
        interval: 1200
        onTriggered: {
            if (root._progressDirty) {
                root._progressDirty = false;
                root._postProgress(false);
                progressTimer.restart();
            }
        }
    }

    // ---- clock and day --------------------------------------------------------------------
    function _now() {
        if (!root.pinClock) root.nowMs = Date.now();
        return root.nowMs;
    }
    onNowMsChanged: root._dayCheck()
    onPopupOpenChanged: {
        if (!root.popupOpen) return;
        root._now();
        indexFile.reload();
        root._dayCheck();
        root._loadDaily();
    }

    Connections {
        target: clock
        function onNowChanged() {
            if (!root.pinClock) root.nowMs = clock.now;
            root._rearm();
        }
    }

    // The instant the wiki day rolls on a date: the FIRST instant of it whose local clock reads `h`:00 or later, the one
    // Pool.dayKey flips on. A constructor's answer is not it on a change day -- an hour the clocks skip is moved BACKWARDS by
    // the engine (02:00 -> 01:00, an hour before dayKey flips), a repeated one lands on its second pass (an hour after) --
    // so the neighbourhood is scanned by the minute. tools/dev/dst_audit_cases.js G2.
    function _rolloverMs(y, m, d, h) {
        const c = new Date(y, m, d, h, 0, 0, 0).getTime();
        for (let t = c - 3 * 3600000; t <= c + 3 * 3600000; t += 60000) {
            const x = new Date(t);
            if (x.getFullYear() === y && x.getMonth() === m && x.getDate() === d && x.getHours() * 60 + x.getMinutes() >= h * 60)
                return t;
        }
        return c;
    }
    // The next `rolloverHour`:00 after `wallMs`, local time.
    function _nextAfter(wallMs) {
        const h = cfg.config.rolloverHour;
        const d = new Date(wallMs);
        let t = root._rolloverMs(d.getFullYear(), d.getMonth(), d.getDate(), h);
        if (t <= wallMs) {
            const n = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1, 12);
            t = root._rolloverMs(n.getFullYear(), n.getMonth(), n.getDate(), h);
        }
        return t;
    }
    // Armed from the WALL clock, never from a pinned nowMs (a past instant would
    // be due at once, and re-asked at once).
    function _rearm() {
        root._nextRollover = root._nextAfter(Date.now());
        clock.request(root._nextRollover);
    }

    function _dayCheck() {
        const d = Pool.dayKey(root.nowMs, cfg.config.rolloverHour);
        if (d === root._day) return;
        const first = root._day === "";
        root._day = d;
        root._pickN = ({});
        root._commitChoices();
        if (first) return;
        root.ensureSlots();
        root._loadDaily();
        root._afterCounts();
        root.updated();
    }

    // ---- the index ---------------------------------------------------------------------------
    function _readIndex(txt) {
        if (!txt || txt === root._indexRaw) return;
        if (!vm.ingestIndex(txt)) return;
        root._indexRaw = txt;
        root._indexRead = true;
        root._afterIndex();
    }

    function _afterIndex() {
        vm.setSeen(st.seen);
        root.ensureSlots();
        root._evalRefill();
        root._syncLoading();
        root.updated();
    }

    // ---- slots -----------------------------------------------------------------------------------
    function _hash(s) {
        let h = 2166136261;
        for (let i = 0; i < s.length; i++) {
            h ^= s.charCodeAt(i);
            h = Math.imul(h, 16777619);
        }
        return h >>> 0;
    }
    function _rng(tab) {
        const n = (root._pickN[tab] || 0) + 1;
        root._pickN[tab] = n;
        return Interest.seeded(root._hash(root._day + "|" + tab + "|" + n));
    }

    // The tab's pool as the picks see it: a subject switched off (wiki.jsonc families) is never picked, its entries stay.
    function _rowsOf(tab) {
        const off = cfg.config.families;
        const rows = vm.rows(tab);
        return Object.keys(off).length === 0 ? rows : rows.filter(function (r) { return off[r.family] !== false; });
    }
    // Of the unseen entries, those of a subject switched off: they will never be shown, so the refill ask does not count them.
    function _offUnseen(tab) {
        const off = cfg.config.families;
        if (Object.keys(off).length === 0) return 0;
        return Pool.unseen(vm.rows(tab), st.seen).filter(function (r) { return off[r.family] === false; }).length;
    }

    // The tab's interest config, with the families of switched-off sources and subjects left out.
    function _tabCfg(tab) {
        vm.ensureFamilies();
        const c = Interest.tabConfig(vm.families, tab);
        const s = cfg.config.sources;
        const on = function (f) {
            if (tab === "discover") return s.wikipedia;
            switch (f.id) {
            case "arch-installed":
            case "arch-discovery": return s.arch;
            case "arch-tips": return s.arch && s.archTips;
            case "wikipedia-cs": return s.wikipedia;
            case "other-wikis": return s.gentoo || s.kernel || s.freedesktop;
            default: return true;
            }
        };
        const off = cfg.config.families;
        c.families = c.families.filter(function (f) { return on(f) && off[f.id] !== false; });
        return c;
    }

    // Put `slot` on the tab if its entry can be read.
    function _takeSlot(tab, slot) {
        if (!vm.showSlot(tab, slot.id, slot.why)) return false;
        st.setSlot(tab, slot);
        return true;
    }

    function _ensureSlot(tab) {
        const cur = Pool.rollSlot(st.slots[tab], root._day, st.seen);
        if (cur.id) {
            const shown = vm.slotOf(tab);
            if (!shown || shown.id !== cur.id || !vm.card(tab)) {
                if (!vm.showSlot(tab, cur.id, cur.why)) {
                    st.setSlot(tab, null);                   // its entry is gone: a new pick
                    root._pick(tab);
                    return;
                }
            }
            const old = st.slots[tab];
            if (!old || old.day !== cur.day || old.id !== cur.id) st.setSlot(tab, cur);
            return;
        }
        root._pick(tab);
    }

    // A fresh pick from the unseen pool; an entry that cannot be read is skipped for good.
    function _pick(tab) {
        for (let attempt = 0; attempt < 3; attempt++) {
            const pick = Pool.pickForSlot(tab, root._rowsOf(tab), st.seen, st.interest[tab], root._tabCfg(tab),
                                          root.nowMs, root._rng(tab), null);
            if (!pick.id) break;
            if (root._takeSlot(tab, { day: root._day, id: pick.id, shownMs: 0, why: pick.why })) return;
            st.markSeen(pick.id, root.nowMs);
            vm.setSeen(st.seen);
        }
        if (st.slots[tab]) st.setSlot(tab, null);
        vm.clearSlot(tab);
    }

    // ---- what the reader does ----------------------------------------------------------------------
    function _markSeen(tab, id, visibleMs, exposure) {
        if (!st.markSeen(id, root.nowMs)) return;
        vm.setSeen(st.seen);
        const slot = st.slots[tab];
        if (slot && slot.id === id) st.setSlot(tab, { day: slot.day, id: slot.id, shownMs: visibleMs, why: slot.why });
        if (exposure && vm.rowOf(tab, id)) root._event(tab, id, "seen");
        root._afterCounts();
        root.updated();
    }

    // One interest event for what is on `tab` (its family, topic and, for a pool
    // row, the popularity band the reader's taste is learned from).
    function _facts(tab, id) {
        const c = vm.cardFor(tab, id);
        const row = vm.rowOf(tab, id);
        const fam = c && c.family ? c.family : (row ? row.family : "");
        if (!fam) return null;
        const f = { f: fam, t: c && c.topic ? c.topic : (row ? row.topic : "") };
        if (row && typeof row.popularityBand === "number") f.band = row.popularityBand;
        return f;
    }
    function _event(tab, id, kind) {
        const f = root._facts(tab, id);
        if (!f) return false;
        st.record(tab, Object.assign({ k: kind, at: Math.round(root.nowMs) }, f));
        return true;
    }

    // ---- refill -------------------------------------------------------------------------------------
    function _label(tab) { return tab === "deepen" ? "Deepen" : "Discover"; }

    function _evalRefill() {
        if (!root._asksArmed || !root._indexRead || !st.loaded) return;
        for (let i = 0; i < st.tabs.length; i++) {
            const tab = st.tabs[i];
            if (batcher.running && batcher.status.tab === tab) continue;      // a batch is filling it
            const n = root.unseen(tab);
            const r = Pool.needsRefill(n, st.ask[tab], root.nowMs, { askAt: cfg.config.askAt, reaskMs: cfg.config.askAgainHours * 3600000 });
            if (JSON.stringify(r.latch) !== JSON.stringify(st.ask[tab])) st.setAsk(tab, r.latch);
            if (r.ask) root._postAsk(tab, n);
        }
    }

    function _postAsk(tab, n) {
        const size = cfg.config.batchSize;
        const what = root._label(tab);
        const body = n === 0 ? "No " + what + " entries yet — process " + size + " now?"
                             : "Only " + n + " " + what + (n === 1 ? " entry" : " entries") + " left — process " + size + " new ones now?";
        if (root.notifier)
            root.notifier.notify("refill-" + tab, {
                title: "Wiki", body: body, urgency: "low",
                // `default` is the body click (it draws no button): it opens the wiki; the two buttons answer.
                actions: [{ id: "default", label: "Open" }, { id: "process", label: "Process " + size + " now" }, { id: "later", label: "Later" }],
                timeoutMs: 0
            });
        root._askedNow[tab] = true;
        root.refillAsked(tab, n);
    }

    // At shell start: an ask nobody answered is on screen no more -- say it again.
    function _repostAsks() {
        for (let i = 0; i < st.tabs.length; i++) {
            const tab = st.tabs[i];
            const a = st.ask[tab];
            const n = root.unseen(tab);
            if (!root._askedNow[tab] && typeof a.latchedAt === "number" && !a.answered && !a.later && n <= cfg.config.askAt)
                root._postAsk(tab, n);
        }
    }

    function _afterCounts() { root._evalRefill(); }

    Connections {
        target: root.notifier
        ignoreUnknownSignals: true
        function onAction(key, id) {
            if (key === "progress") {
                root.requestOpen(batcher.status.tab || "discover");
                return;
            }
            if (key.indexOf("refill-") !== 0) return;
            const tab = key.substring(7);
            if (st.tabs.indexOf(tab) < 0) return;
            root._now();
            // A BODY CLICK (`default`) only opens the wiki on the tab: starting a GPU batch from a click on the card was the
            // unintuitive part. The two buttons answer: "process" starts the batch, "later" closes the ask for 24 h.
            if (id !== "process" && id !== "later") {
                root.requestOpen(tab);
                return;
            }
            // A STALE CARD starts nothing (a click on another original
            // 'fetch 30?' notification would just refetch). Cards of an ask outlive the ask -- the same words were posted again
            // at every start, and a card stays in the manager after the batch it asked for -- and the key says which tab,
            // not which card. The ask is OPEN while its latch is set, unanswered and not deferred; a button of any card of a
            // closed ask (a batch ran for it, or is running, it was put off, or the pool has refilled since) starts nothing:
            // "Process" only opens the wiki on the tab, "Later" does nothing (it must not re-open an answered ask or push a
            // deferred one's 24 h on).
            const a = st.ask[tab];
            const open = !!a && typeof a.latchedAt === "number" && a.answered !== true && a.later !== true && !batcher.running;
            if (!open) {
                if (id === "process")
                    root.requestOpen(tab);
                return;
            }
            if (id === "later") {
                st.setAsk(tab, Pool.refillLater(a, root.unseen(tab), root.nowMs));
                return;
            }
            st.setAsk(tab, Pool.refillAnswered(st.ask[tab], root.unseen(tab), root.nowMs));
            root.startBatch(tab);
        }
    }

    // ---- the batch --------------------------------------------------------------------------------------
    Connections {
        target: batcher
        function onItemDone(tab, row) { indexSoon.restart(); }
        function onProgressed() {
            root._syncBatchState();
            root._syncLoading();
            if (!batcher.status.running) return;
            if (progressTimer.running) {
                root._progressDirty = true;
            } else {
                root._postProgress(false);
                progressTimer.start();
            }
        }
        function onFinished(tab, result) {
            progressTimer.stop();
            root._progressDirty = false;
            indexSoon.stop();
            indexFile.reload();
            if (result.offline) root._offline = true;
            else if (result.code === 0) root._offline = false;
            root._toolError = result.error;
            if (result.jev) st.addJev(result.jev.tokens, result.jev.calls);
            root._postProgress(true, result);
            root.batchFinished(tab, result.ok, result.failed);
            root._afterCounts();
            root.updated();
            Qt.callLater(root._afterBatchGpu);
        }
    }
    Connections {
        target: runner
        function onBatchPidChanged() { root._syncBatchState(); }
        function onEntry(tab, url, entry, provisional) { root._onEntry(tab, url, root._plain(entry)); }
        function onUpgrade(tab, url, id, intro) { vm.upgradeIntro(id, root._plain(intro)); root.updated(); }
        function onLoadFinished(tab, url, code, error) { root._onLoadFinished(tab, url, code, error); }
        function onDailyLoaded(daily) {
            vm.ingestDaily(daily);
            // A week's Picture of the day may have become its own Discover entry: the
            // tool added it to the index, so read the index again.
            if (daily && daily.potd && daily.potd.entryId) indexSoon.restart();
            root.updated();
        }
        function onDailyFinished(day, code, error) {
            if (code === 4) root._offline = true;
            else if (code === 0) root._offline = false;
            else root._toolError = error || "the day's extras could not be fetched";
        }
        function onSaved(tab, id, path, key) {
            const s = root._saves[tab + "|" + id];
            if (s) s.done = true;
            root.noteSaved(tab, id, true, key || path);
        }
        function onSaveFinished(tab, id, code, error) {
            const k = tab + "|" + id;
            const s = root._saves[k];
            delete root._saves[k];
            if (s && !s.done) root.noteSaved(tab, id, false, error || "the note could not be written");
        }
    }

    function _syncBatchState() {
        const b = batcher.status;
        const want = { running: b.running, tab: b.running ? b.tab : null, pid: b.running ? runner.batchPid : 0 };
        const have = st.batch;
        if (have.running === want.running && have.tab === want.tab && have.pid === want.pid) return;
        st.setBatch(want);
    }

    function _postProgress(final, result) {
        if (!root.notifier) return;
        const b = batcher.status;
        const tab = final ? result.tab : b.tab;
        const title = "Wiki · " + root._label(tab);
        let body;
        if (!final) {
            const verbs = { candidates: "picking candidates", score: "judging", fetch: "reading", intro: "writing intros",
                            images: "fetching images", write: "saving" };
            const verb = verbs[b.stage] || "working";
            body = b.done + " / " + b.total + " — " + verb + " " + (b.title ? b.title : "…");
        } else if (result.blocked) {
            body = "Paused: " + (result.error || "the GPU is busy") + ". Try again when it is free.";
        } else if (result.offline) {
            body = "No network: nothing more was added (" + result.ok + " so far).";
        } else if (result.code !== 0 && result.ok === 0) {
            body = "Stopped: " + (result.error || "the tool failed") + ".";
        } else {
            body = "Added " + result.ok + (result.generated > 0 ? " (" + result.generated + " written ✦)" : "")
                 + (result.failed > 0 ? ", " + result.failed + " failed" : "");
        }
        // An action keeps the notify-send backend's waiter alive, which is what lets
        // the next post CLOSE this one (in place); the in-process bus replaces it
        // by its key either way. A click opens the popup on the tab. While the batch runs the toast is LIVE (the
        // user may hide it into the manager and bring it back: NotificationService); its result is an ordinary one.
        root.notifier.notify("progress", { live: !final, title: title, body: body, urgency: "low", timeoutMs: final ? 10000 : 0,
                                           actions: [{ id: "default", label: "Open" }] });
    }

    // ---- the rabbit hole ------------------------------------------------------------------------------------
    // What WikiTool's signals carry arrives with its lists (images, intro.links, intro.stripped) as list
    // WRAPPERS on Qt 6.12 -- Array.isArray false -- and WikiCardModel's guards would empty them (a followed
    // page would show no links, no photo). A JSON round trip makes real arrays of it (CLAUDE.md, "A NESTED ARRAY
    // CROSSING A SIGNAL").
    function _plain(v) {
        return v === undefined || v === null ? v : JSON.parse(JSON.stringify(v));
    }

    function _onEntry(tab, url, entry) {
        const f = root._follows[tab];
        if (!f || f.url !== url) return;
        f.landed = true;
        vm.showFollowed(tab, entry, f.parentTitle);
        root._syncLoading();
        root.updated();
    }

    function _onLoadFinished(tab, url, code, error) {
        const f = root._follows[tab];
        if (!f || f.url !== url) return;
        root._follows[tab] = null;
        if (!f.landed) {
            root._toolError = error || "the page could not be loaded";
            if (code === 4) root._offline = true;
        } else {
            root._toolError = "";
            root._offline = false;
        }
        root._syncLoading();
        root.updated();
    }

    // A tab is loading until the index has been read, while a page is on its way
    // (until the provisional entry lands: the written intro that may follow is a
    // swap, not a wait), and while a batch that is filling an empty tab runs.
    function _syncLoading() {
        for (let i = 0; i < st.tabs.length; i++) {
            const tab = st.tabs[i];
            const f = root._follows[tab];
            const filling = batcher.running && batcher.status.tab === tab && !vm.card(tab);
            vm.setLoading(tab, !root._indexRead || (!!f && !f.landed) || filling);
        }
    }

    // ---- the day's extras (On this day, the Picture of the day) ---------------------------------------------
    function _loadDaily() {
        const d = vm.daily;
        if (d && d.day === root._day) return;
        const disk = vm.readJson(root.cacheDir + "/daily/" + root._day + ".json");
        if (disk && disk.day === root._day) {
            vm.ingestDaily(disk);
            return;
        }
        runner.daily(root._day);
    }

    function _expand(p) {
        return String(p).replace(/^~(?=\/|$)/, Quickshell.env("HOME") || "");
    }

    // ---- start ----------------------------------------------------------------------------------------------------
    // A hot-reloaded wiki.jsonc: the rollover hour may have moved.
    Connections {
        target: cfg
        function onConfigChanged() {
            if (!root._ready) return;
            root._rearm();
            root._dayCheck();
        }
    }

    Component.onCompleted: {
        // A parent's onCompleted runs BEFORE its children's: read what the start needs.
        cfg.ensureLoaded();
        st.ensureLoaded();
        vm.ensureFamilies();
        root._now();
        root._day = Pool.dayKey(root.nowMs, cfg.config.rolloverHour);
        root._commitChoices();
        root._rearm();
        root._readIndex(indexFile.text());
        // A fresh install has no index at all: the pool is empty, and that is a state.
        if (!root._indexRead) {
            root._indexRead = true;
            root._afterIndex();
        }
        root._loadDaily();
        startup.start();
        const recent = [];
        for (let i = st.opened.length - 1; i >= 0 && recent.length < 10; i--) recent.push(st.opened[i].title);
        batcher.resumeInterrupted(st.batch.pid, recent);
        root._ready = true;
        root.updated();
    }
}
