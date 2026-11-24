pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// LlmMockRun.qml
//
// A synthetic answer, for looking at the UI. Drop-in replacement for
// LlmBackend: same properties, same signals, same call shapes, no network.
//
//     LlmService { backend: mockRun }     // instead of the real one
//
// WHY IT EXISTS. Reviewing a chat interface against a real model is a poor way
// to do design work: a 26b answer takes minutes to arrive, a small model never
// produces a table or a code fence unless you beg it, and the interesting
// states (the load stall before the first token, a mid-stream failure, a
// thinking preamble) either never happen or flash past once. This produces all
// of them on demand, at a pace you set, from text that is fixed — so a render
// taken today is comparable with one taken last week.
//
// TWO SOURCES:
//   * `fixturePath` — an NDJSON capture of a real /api/chat stream
//     (mockups/fixtures/llm_stream_e4b.ndjson is 494 frames from gemma4:e4b,
//     thinking deltas included). This is what you use to check that the view
//     survives real model output.
//   * "" — the built-in canned answer below, which deliberately contains
//     EVERY markdown block kind the renderer claims to support. It is the
//     mockup's content when Ollama is not running, and it is the fixture for
//     "does the markdown view still lay all of this out correctly".
//
// IT FAKES THE CLASSIFIER TOO. `classify()` has the same signature and the
// same contract as the backend's — one callback, `null` on failure, never a
// throw — because the whole point of a mock backend is that the code above it
// takes the SAME path. A canned answer with no title and no category would
// leave the turn header, the sidebar skeleton and the category glyph untested
// in exactly the mockup that exists to test them. The category is derived from
// words in the question so the six colours are reachable by typing.
//
// IT FAKES THE CTX TUNER'S WIRE TOO. gpuInfo / serverVersion / ctxModelInfo /
// ctxVerifyLoad mirror the backend's tuner primitives with plausible numbers
// (a 16 GiB card, per-model KV geometry), so LlmService runs its REAL tuning
// algorithm offline -- the picker's Manual|Auto row exercises the same code
// path it ships with, on short timers instead of model loads. The fake
// card is 16 GiB so all three states are reachable: small and medium tune,
// large refuses (its weights cannot be resident), and a forced overshoot
// (tuneForceCandidate) genuinely fails verification and backs off, because
// the fake residency answer applies the same weights+KV arithmetic.
//
// AND THE VRAM BAR'S. LlmService.vramInfo reads `loaded` -- the fake /api/ps
// map below -- against gpuInfo's fake card, so the picker's bar is driven
// offline through the SAME code path it ships with rather than a second fake
// of its own: mock:small is resident at 2.0 GiB of the 16 GiB card (13%),
// the card itself has 3.4 GiB in use (21%), and the other two are not
// loaded, which is both of the states the bar has.
//
// IT FAKES TOOL CALLING TOO. `toolScript` is a list of rounds,
// `[{ readMs, thinking, text, gapMs, calls: [{ name, args }] }, ..., { text: "final" }]`,
// one consumed per send(): the round's thinking and text stream as any
// answer does, then its calls go out as `toolCall` signals just before
// `finished`, exactly where the real backend emits them (the tool_calls ride
// the last content frames of an Ollama stream). A send() after the script is
// spent answers with NOTHING -- the "no answer after the tool results" case
// the service must never commit as a blank turn. `probeTools()` answers from
// `probeVerdicts` by digest after `classifyMs`, so the picker's ring, dot and
// failed states are all reachable offline: mock:medium is proven, mock:large
// called the tool and ignored its result.
//
// AND THE ABORT HANDLES. `classify`, `probeTools` and
// `ctxVerifyLoad` return a handle (> 0) the way the real backend's do, and
// `abort(handle)` drops the matching pending callback and stops its timer --
// the real one kills the request on the server, and here there is no server,
// so what a probe can check is that the service ASKED: every abort lands in
// `abortCalls`. Each kind still keeps ONE pending callback (a second call
// replaces the first, whose handle then aborts nothing), which is a
// difference from the real backend, like the synchronous
// `cancel()`.
//
// AND THE RESIDENCY SURFACE. `warm()` takes the backend's
// `opts` and RECORDS every call in `warmCalls` instead of loading anything, so
// a probe can assert that a parked tool loop pinged the server, how often, and
// at which num_ctx -- the whole point of the hold being that the ping carries
// the turn's context size, or ollama reloads the model at its own default and
// throws the KV cache away. `lastByteAt` and `_emitted` mirror the backend's
// byte clock (`lastByteAt` and `_rxLen`; both count CHARACTERS: the backend those of the body lines it
// received, this one those it emitted), and
// `toolCallGapMs` reproduces the silence the real wire has while a model
// writes a tool call's arguments -- measured at 72.57 s with not one frame in
// it, which is what the service's quiet clock exists to name.
//
// PACING. Characters are emitted on a Timer, not frames replayed at their
// captured timestamps: a replay honouring 25 ms gaps would spend most of its
// life idle and would make the view look faster than it is. `speed` is a
// multiplier on a base rate, and for a fixture that base rate is DERIVED from
// the capture's own timestamps — so `speed: 1` on a fixture really is the pace
// the model wrote at, while `charsPerTick` sets the pace of the canned answer.
// =============================================================================
Item {
    id: root

    // ---- Configuration (contract) -----------------------------------------
    property string fixturePath: ""     // "" = the built-in canned answer
    property real   speed: 1.0          // 1 = the fixture's own timing
    property int    charsPerTick: 3     // base rate for the canned answer
    property int    tickMs: 16
    property bool   simulateLoadStall: false
    property int    loadStallMs: 1200
    property bool   failMidway: false   // arm the error path for a probe
    // The classifier's own knobs. `classifyMs` exists so the title skeleton is
    // visible for long enough to look at: the real thing takes ~0.4 s warm on
    // gemma4:e2b and a zero-delay mock would resolve before the first frame.
    property int    classifyMs: 500
    property bool   failClassify: false // arm the "no title came back" path
    // The tool probe's own delay. 0 = follow `classifyMs`; a separate
    // value is what lets a probe put a LATE classify
    // reply inside a live probe's window, an ordering that matters (a late
    // reply must not settle somebody else's slot).
    property int    probeMs: 0
    // A fixed answer for `classify`, instead of the word-derived one below.
    // A test that asserts a category and a glyph needs the classifier to say
    // a known thing rather than a plausible one.
    property var    classifyOverride: null
    // What the last classify was asked with, so a probe can prove the tool
    // summaries of a tool turn actually reached the request.
    property var    lastClassifyOpts: null
    // Tool rounds, consumed one per send(); empty = the canned answer.
    property var    toolScript: []
    // THE SILENCE A TOOL CALL IS WRITTEN IN. Measured on the real wire
    // (ornith-1.5:9b): while a model writes a call's arguments
    // ollama sends NOTHING -- 72.57 s between the last content delta and one
    // 13 193-byte frame carrying the whole `tool_calls` object beside
    // `done:true`. A round with `calls` therefore waits this long after its
    // text before emitting them, so the quiet clock and everything that reads
    // it can be driven offline. 0 = calls at once.
    property int    toolCallGapMs: 0
    // A round may carry its own timings: `readMs` of silence
    // BEFORE its first byte -- the model reading the prompt, which on the
    // real wire is the whole wait before a thinking round's first thinking
    // token -- and `gapMs`, which overrides `toolCallGapMs` for that round.
    property int    _roundReadMs: 0
    property int    _roundGapMs: 0
    // Probe verdicts by blob digest; a model absent here is "failed: no
    // answer", which is what the real backend returns for a model that never
    // replies.
    property var    probeVerdicts: ({
        "mock-medium-0001": { calledRight: true, usedResult: true, why: "" },
        "mock-large-0001":  { calledRight: true, usedResult: false, why: "ignored the result: 17*23 is 400" }
    })

    // Three fake models with different capabilities, so the picker's dots,
    // the vision affordance and the thinking drawer all have something to
    // render without a server.
    property var models: [
        { id: "mock:small", family: "mock", sizeBytes: 2147483648, quant: "Q4_K_M",
          paramSize: "3.1B", ctx: 32768, digest: "mock-small-0001", ple: false,
          arch: "mock", moe: false, expertCount: 0, expertUsed: 0,
          caps: { vision: false, tools: false, thinking: false, audio: false },
          loaded: true, sizeVram: 2147483648 },
        { id: "mock:medium", family: "mock", sizeBytes: 9608350718, quant: "Q4_K_M",
          paramSize: "8.0B", ctx: 131072, digest: "mock-medium-0001", ple: false,
          arch: "mock", moe: false, expertCount: 0, expertUsed: 0,
          caps: { vision: true, tools: true, thinking: true, audio: false },
          loaded: false, sizeVram: 0 },
        // ONE OF THE THREE IS A MIXTURE. Without it the MoE cell would be
        // empty in every mockup state and a layout could not be judged.
        // (The third state -- a model /api/show has not described yet, which
        // is `arch: ""` -- is what any model here looks like before this
        // array is read, and what the real backend seeds every row with.)
        { id: "mock:large", family: "mock", sizeBytes: 19868981791, quant: "Q4_K_M",
          paramSize: "31.3B", ctx: 262144, digest: "mock-large-0001", ple: false,
          arch: "mock-moe", moe: true, expertCount: 64, expertUsed: 4,
          caps: { vision: true, tools: true, thinking: true, audio: true },
          loaded: false, sizeVram: 0 }
    ]

    // ---- Live state (mirrors LlmBackend) -----------------------------------
    readonly property bool   busy: root._busy
    // The real backend's byte clock, mirrored: `_emitted` is this object's
    // idea of what came off the wire (characters, as the backend counts) and
    // every emission stamps the time. Without
    // these two the service's quiet clock could not be driven offline at all.
    readonly property real   lastByteAt: root._lastByteAt
    readonly property bool   modelsLoading: false
    readonly property bool   online: true
    readonly property string lastError: root._lastError
    // Writable: a mockup or a probe moves residency by assigning a new map (a model entirely in RAM is `sizeVram: 0, size > 0`).
    property var             loaded: ({
        "mock:small": { sizeVram: 2147483648, size: 2147483648, ctx: 32768, expiresAt: "" }
    })

    signal started()
    signal delta(string text)
    signal thinkingDelta(string text)
    signal toolCall(var call)
    signal finished(var stats)
    signal failed(string message)

    // ---- Internal ----------------------------------------------------------
    property bool   _busy: false
    property string _lastError: ""
    // The script is a flat list of [{ kind: "thinking"|"content", text }] in the
    // order the model produced them, so a capture that interleaves the two
    // replays interleaved rather than thinking-then-answer.
    property var    _script: []
    property int    _si: 0              // index into _script
    property int    _ci: 0              // character offset inside _script[_si]
    property int    _totalChars: 0
    property int    _emitted: 0
    property real   _lastByteAt: 0
    property real   _baseChars: 3       // chars per tick before `speed`
    property var    _stats: null
    property bool   _armedFail: false
    property bool   _sawFirstByte: false
    property bool   _scripted: false    // toolScript was ever non-empty this session
    property var    _roundCalls: []     // the calls the current round emits at its end
    property var    _lastMessages: []   // what the last send() was given (probes read it)
    property var    _lastOpts: null
    property int    _sends: 0

    // =========================================================================
    //  Commands (the LlmBackend surface)
    // =========================================================================

    function capsOf(id) {
        for (let i = 0; i < root.models.length; i++)
            if (root.models[i].id === id) return root.models[i].caps;
        return ({ vision: false, tools: false, thinking: false, audio: false });
    }

    function shortName(id) {
        if (!id) return "";
        const i = id.lastIndexOf(":");
        if (i < 0) return id;
        const tag = id.substring(i + 1);
        return (tag === "" || tag === "latest") ? id.substring(0, i) : tag;
    }

    // "25.8B" -> 25.8e9, "800M" -> 8e8, "620K" -> 6.2e5. Takes a model entry
    // from `models` (reads its `paramSize`) or the size string itself, and
    // returns 0 when there is nothing to parse -- the caller chooses its own
    // fallback (the picker falls back to sizeBytes). ONE parser, here: the
    // picker sorts by parameter count because quantisation makes gigabytes
    // lie about capability, and a second copy of this regex would drift.
    function paramCountOf(m) {
        const s = (typeof m === "string") ? m
                : ((m && m.paramSize) ? m.paramSize : "");
        const r = /^\s*(\d+(?:\.\d+)?)\s*([KMBT])\s*$/i.exec(s);
        if (!r) return 0;
        const mul = ({ K: 1e3, M: 1e6, B: 1e9, T: 1e12 });
        return parseFloat(r[1]) * mul[r[2].toUpperCase()];
    }

    // =========================================================================
    //  The fake classifier
    // =========================================================================

    // Keyword -> category. Not a model and not pretending to be one: it exists
    // so that typing "why does my python" into the mockup produces the `code`
    // glyph and typing "what should I cook" produces `other`, which is what a
    // person reviewing the colours needs. Order matters the same way the real
    // prompt's order does — the first hit wins.
    readonly property var _catWords: [
        { key: "code", words: ["code", "python", "rust", "javascript", "qml", "function",
                               "compile", "error", "api", "git", "bug", "class", "regex"] },
        { key: "system", words: ["linux", "arch", "pacman", "systemd", "shell", "bash",
                                 "kernel", "wayland", "hyprland", "driver", "gpu", "disk",
                                 "network", "install", "config"] },
        { key: "data", words: ["average", "mean", "median", "percent", "growth", "sum",
                               "statistic", "chart", "table", "dataset", "calculate",
                               "number", "probability"] },
        { key: "write", words: ["write", "rewrite", "draft", "translate", "edit",
                                "summarise", "summarize", "wording", "email", "commit message"] },
        { key: "explain", words: ["explain", "why", "how does", "what is", "history",
                                  "difference between", "concept", "meaning"] }
    ]

    // Same signature and same contract as LlmBackend.classify: cb once, null on
    // failure, never a throw, and a handle back for abort(). `opts` is
    // accepted and ignored — the prompt and the enum are the real backend's
    // business.
    function classify(model, question, answer, cb, opts) {
        root._clsCb = cb;
        root._clsQuestion = question || "";
        root._clsHandle = ++root._handleSeq;
        root.lastClassifyOpts = opts || null;
        _clsTimer.interval = Math.max(1, root.classifyMs);
        _clsTimer.restart();
        return root._clsHandle;
    }

    property var    _clsCb: null
    property string _clsQuestion: ""
    property int    _clsHandle: 0

    Timer {
        id: _clsTimer
        repeat: false
        onTriggered: {
            const cb = root._clsCb;
            root._clsCb = null;
            root._clsHandle = 0;
            if (!cb) return;
            if (root.failClassify) {
                // Exactly what the real one does when the server says no: one
                // null, no exception, and the caller falls back.
                try { cb(null); } catch (e) { }
                return;
            }
            try {
                if (root.classifyOverride) cb(root.classifyOverride);
                else cb({ title: root._mockTitle(root._clsQuestion),
                          category: root._mockCategory(root._clsQuestion) });
            } catch (e) { }
        }
    }

    function _mockCategory(q) {
        const t = (q || "").toLowerCase();
        for (let i = 0; i < root._catWords.length; i++) {
            const c = root._catWords[i];
            for (let j = 0; j < c.words.length; j++)
                if (t.indexOf(c.words[j]) >= 0) return c.key;
        }
        return "other";
    }

    // The first few words of the question, shaped like the model's own answer:
    // a noun phrase, sentence case, no trailing punctuation.
    function _mockTitle(q) {
        let t = (q || "").replace(/[`*_~#>]/g, "").replace(/\s+/g, " ").trim();
        if (t.length === 0) return "Mock exchange";
        const words = t.split(" ");
        // The question words that are pure interrogative carry no subject, so
        // the title would start with them and say nothing.
        while (words.length > 1 && ["why", "how", "what", "when", "where", "who",
                                    "do", "does", "is", "are", "can", "should",
                                    "i", "my", "the", "a"].indexOf(words[0].toLowerCase()) >= 0)
            words.shift();
        const keep = words.slice(0, 5);
        // ...and a cut that lands ON a filler word ("...a systemd unit that")
        // reads as a sentence someone gave up on. Drop it from the tail too.
        while (keep.length > 1 && ["that", "which", "and", "or", "of", "to",
                                   "in", "on", "for", "with", "a", "the"]
                                   .indexOf(keep[keep.length - 1].toLowerCase()) >= 0)
            keep.pop();
        t = keep.join(" ").replace(/[.,;:!?]+$/, "");
        return t.charAt(0).toUpperCase() + t.substring(1);
    }

    // The abort handles (mirrors LlmBackend.abort): every call with a real
    // handle is RECORDED, like warm's and unload's, and the matching pending
    // callback -- classify, probe or ctx verification -- is dropped with its
    // timer, so it never fires. An unknown or already-answered handle is
    // recorded and does nothing else, as on the real backend.
    property var abortCalls: []         // [handle]
    property int _handleSeq: 0
    function abort(handle) {
        if (!(handle > 0)) return;
        root.abortCalls = root.abortCalls.concat([handle]);
        if (handle === root._clsHandle) {
            _clsTimer.stop();
            root._clsCb = null;
            root._clsHandle = 0;
        }
        if (handle === root._probeHandle) {
            _probeTimer.stop();
            root._probeCb = null;
            root._probeHandle = 0;
        }
        if (handle === root._ctxVerifyHandle) {
            _ctxVerifyTimer.stop();
            root._ctxVerifyJob = null;
            root._ctxVerifyHandle = 0;
        }
    }

    function refreshModels() { root.modelsChanged(); }
    function refreshLoaded() { }
    // The residency surface, mirrored so LlmService.releaseModel, switchModel
    // and the parked-turn hold take the same path against the mock. Nothing
    // is loaded and nothing is evicted -- the calls are RECORDED instead, so
    // a probe can assert that the hold pinged, how often, and at which ctx.
    property var warmCalls: []          // [{ model, numCtx, at }]
    function warm(model, opts) {
        const o = opts || ({});
        root.warmCalls = root.warmCalls.concat([{ model: model || "",
                                                  numCtx: o.numCtx || 0,
                                                  at: Date.now() }]);
    }
    // Nothing is loaded here, so nothing is evicted -- the calls are
    // RECORDED, like warm's, so a probe can assert that a gesture reached the
    // server and that a refused one did not.
    property var unloadCalls: []        // [{ model, at }]
    function unload(model) {
        root.unloadCalls = root.unloadCalls.concat([{ model: model || "", at: Date.now() }]);
    }

    // =========================================================================
    //  The fake ctx-tuner wire (mirrors LlmBackend's tuner primitives)
    // =========================================================================

    // A 16 GiB card: big enough that small and medium auto-tune, small enough
    // that large's 19.9 GB of weights refuse -- every picker state reachable.
    readonly property int  gpuTotalMiB: 16384
    // Fake KV geometry per model, same shape ctxModelInfo returns for real.
    readonly property var _ctxTable: ({
        "mock:small": { blockCount: 28, kvHeads: 4, headDim: 128,
                        contextLength: 32768, paramCount: 3.1e9, plePerLayer: 0,
                        weightBytes: 2147483648, digest: "mock-small-0001" },
        "mock:medium": { blockCount: 36, kvHeads: 8, headDim: 128,
                         contextLength: 131072, paramCount: 8.0e9, plePerLayer: 0,
                         weightBytes: 9608350718, digest: "mock-medium-0001" },
        "mock:large": { blockCount: 48, kvHeads: 8, headDim: 160,
                        contextLength: 131072, paramCount: 31.3e9, plePerLayer: 0,
                        weightBytes: 19868981791, digest: "mock-large-0001" }
    })

    // Same contract as every fake here: cb once, never a throw. Instant.
    // The CARD's use -- mock:small's 2.0 GiB plus a plausible compositor and
    // compute graph, 3.4 GiB (21%) -- so the picker's bar has two distinct
    // fills offline, the model's inside the card's. Reported as `freeMiB`
    // with `usedMiB` agreeing, because the service takes the card's
    // occupancy as total - free (nvidia-smi's own `used` misses the driver's
    // reserved block) and a mock that reported only one of them would drift
    // from the real card's arithmetic.
    // `cardUp: false` is an installed nvidia-smi that did not answer (the card off, blocked, the driver not up): the service must not
    // take that for "no card" for good.
    property bool cardUp: true
    // No nvidia-smi at all (not "did not answer"): the service latches that one for good.
    property bool cardAbsent: false
    // How many times the service asked (a probe counts the re-asks).
    property int  gpuReads: 0
    function gpuInfo(cb) {
        root.gpuReads++;
        Qt.callLater(function () {
            try {
                if (!cb) return;
                if (root.cardAbsent)
                    cb({ ok: false });
                else if (!root.cardUp)
                    cb({ ok: false, unreachable: true });
                else
                    cb({ ok: true, totalMiB: root.gpuTotalMiB,
                         usedMiB: 3456, freeMiB: root.gpuTotalMiB - 3456 });
            } catch (e) { }
        });
    }

    function serverVersion(cb) {
        Qt.callLater(function () {
            try { if (cb) cb("mock-0.1"); } catch (e) { }
        });
    }

    function ctxModelInfo(model, cb) {
        Qt.callLater(function () {
            const t = root._ctxTable[model];
            try { if (cb) cb(t ? t : null); } catch (e) { }
        });
    }

    // A short timer, not Qt.callLater: `probing` should be VISIBLE in the
    // picker ("…"), the way the classifier's delay makes the title skeleton
    // visible. Residency applies the real arithmetic -- weights plus f16 KV
    // against the fake card -- so a forced overshoot genuinely fails and the
    // service's back-off runs offline.
    property var _ctxVerifyJob: null
    property int _ctxVerifyHandle: 0

    function ctxVerifyLoad(model, numCtx, cb) {
        root._ctxVerifyJob = { model: model, numCtx: numCtx, cb: cb };
        root._ctxVerifyHandle = ++root._handleSeq;
        _ctxVerifyTimer.restart();
        return root._ctxVerifyHandle;
    }

    Timer {
        id: _ctxVerifyTimer
        interval: 120
        repeat: false
        onTriggered: {
            const j = root._ctxVerifyJob;
            root._ctxVerifyJob = null;
            root._ctxVerifyHandle = 0;
            if (!j) return;
            const t = root._ctxTable[j.model];
            let r;
            if (!t) {
                r = { resident: false, sizeVram: 0, size: 0, ctx: 0,
                      error: "model \"" + j.model + "\" not found" };
            } else {
                const bpt = 2 * t.blockCount * t.kvHeads * t.headDim * 2;
                const size = t.weightBytes + j.numCtx * bpt;
                const fits = size <= root.gpuTotalMiB * 1048576;
                r = { resident: fits, sizeVram: fits ? size : Math.round(size * 0.7),
                      size: size, ctx: j.numCtx, error: "" };
            }
            try { if (j.cb) j.cb(r); } catch (e) { }
        }
    }

    function loadFixture(path) {
        root.fixturePath = path;
        root._buildScript();
    }

    // The arguments are accepted and ignored: what comes back is the script,
    // not an answer to the question. That is the point — the content is fixed.
    function send(model, messages, opts) {
        if (root._busy) return;
        root._sawFirstByte = false;     // per ROUND, like the wire's own first byte
        root._lastMessages = messages || [];
        root._lastOpts = opts || null;
        root._sends++;
        if (root.toolScript && root.toolScript.length > 0) {
            root._scripted = true;
            const round = root.toolScript[0];
            root.toolScript = root.toolScript.slice(1);
            root._roundCalls = (round && round.calls) ? round.calls.slice() : [];
            root._roundReadMs = (round && round.readMs > 0) ? round.readMs : 0;
            root._roundGapMs = (round && round.gapMs !== undefined) ? round.gapMs : root.toolCallGapMs;
            root._script = [];
            if (round && round.thinking) root._script.push({ kind: "thinking", text: String(round.thinking) });
            if (round && round.text) root._script.push({ kind: "content", text: String(round.text) });
            root._totalChars = 0;
            for (let i = 0; i < root._script.length; i++) root._totalChars += root._script[i].text.length;
            root._baseChars = root.charsPerTick;
            root._stats = root._syntheticStats(Math.max(1, root._totalChars));
        } else if (root._scripted) {
            // The script is spent: the model says nothing.
            root._roundReadMs = 0;
            root._roundGapMs = root.toolCallGapMs;
            root._roundCalls = [];
            root._script = [];
            root._totalChars = 0;
            root._stats = root._syntheticStats(1);
        } else {
            root._roundReadMs = 0;
            root._roundGapMs = root.toolCallGapMs;
            root._roundCalls = [];
            if (root._script.length === 0) root._buildScript();
        }
        root._si = 0;
        root._ci = 0;
        root._emitted = 0;
        root._lastByteAt = 0;
        root._lastError = "";
        root._armedFail = root.failMidway;
        root._busy = true;
        if (root.simulateLoadStall || root._roundReadMs > 0) {
            // The real thing sits silent here for 33-41 s on a cold 26b. The
            // point of simulating it is that `started()` has NOT fired yet, so
            // the view is in its waiting-for-the-model state, not its
            // streaming one. A round's `readMs` is the same silence for a
            // different reason: a loaded model reading a long prompt.
            _stallTimer.interval = root.simulateLoadStall ? root.loadStallMs : root._roundReadMs;
            _stallTimer.restart();
        } else {
            root._begin();
        }
    }

    function cancel() {
        if (!root._busy) return;
        _tick.stop();
        _stallTimer.stop();
        _gapTimer.stop();
        root._busy = false;
        // Same contract as LlmBackend: a cancel ends the turn normally, so the
        // caller keeps the text that arrived instead of painting an error.
        root.finished({
            promptTokens: 0, evalTokens: 0, totalMs: 0, loadMs: 0, evalMs: 0,
            tokensPerSecond: 0, doneReason: "cancelled"
        });
    }

    // =========================================================================
    //  Playback
    // =========================================================================

    Timer {
        id: _stallTimer
        repeat: false
        onTriggered: root._begin()
    }

    function _begin() {
        // A ROUND THAT SAYS NOTHING SAYS NOTHING AT ALL. Measured on the real
        // wire: when a model goes straight into a tool call with no prose in
        // front of it, ollama withholds even the HTTP response headers until
        // the call is finished -- 79.8 s in one run -- so the client gets no
        // `started` either, and a view that reads "generating and not started"
        // as "the model is loading" says so for the whole minute. The mock
        // reproduces that exactly when the round has a gap and no text.
        if (root._roundGapMs > 0 && root._roundCalls.length > 0 && root._scriptTextLength() === 0) {
            _gapTimer.interval = root._roundGapMs;
            _gapTimer.restart();
            return;
        }
        root._lastByteAt = Date.now();
        root._sawFirstByte = true;
        root.started();
        _tick.interval = Math.max(1, root.tickMs);
        _tick.restart();
    }

    // How many characters this round will stream before its calls.
    function _scriptTextLength() {
        let n = 0;
        for (let i = 0; i < root._script.length; i++)
            n += String(root._script[i].text || "").length;
        return n;
    }

    Timer {
        id: _tick
        repeat: true
        onTriggered: root._step()
    }

    function _step() {
        if (!root._busy) { _tick.stop(); return; }

        if (root._armedFail && root._emitted >= root._totalChars * 0.4) {
            _tick.stop();
            root._busy = false;
            root._armedFail = false;
            // Quoted from a real Ollama failure: an over-committed num_gpu
            // takes the llama-server process down with it.
            root._lastError = "llama-server process has terminated: "
                + "cudaMalloc failed: out of memory";
            root.failed(root._lastError);
            return;
        }

        let budget = Math.max(1, Math.round(root._baseChars * Math.max(0.01, root.speed)));
        while (budget > 0 && root._si < root._script.length) {
            const e = root._script[root._si];
            const take = Math.min(budget, e.text.length - root._ci);
            if (take > 0) {
                const s = e.text.substring(root._ci, root._ci + take);
                root._ci += take;
                root._emitted += take;
                budget -= take;
                root._lastByteAt = Date.now();
                if (e.kind === "thinking") root.thinkingDelta(s);
                else root.delta(s);
            }
            if (root._ci >= e.text.length) {
                root._si++;
                root._ci = 0;
            }
        }

        if (root._si >= root._script.length) {
            _tick.stop();
            // The round's calls go out just before the done frame, the way
            // Ollama's tool_calls ride the tail of a stream -- after
            // `toolCallGapMs` of complete silence when this round has any,
            // which is what the real wire does while the model writes them.
            if (root._roundCalls.length > 0 && root._roundGapMs > 0) {
                _gapTimer.interval = root._roundGapMs;
                _gapTimer.restart();
                return;
            }
            root._finishRound();
        }
    }

    Timer {
        id: _gapTimer
        repeat: false
        onTriggered: root._finishRound()
    }

    function _finishRound() {
        root._busy = false;
        // The one frame that ends a headerless round is still the round's
        // first byte, so `started` rides in front of it exactly once.
        if (!root._sawFirstByte) {
            root._sawFirstByte = true;
            root.started();
        }
        const calls = root._roundCalls;
        root._roundCalls = [];
        // One frame carries them all, and it is bytes: the clock moves here
        // and nowhere in the gap before it.
        if (calls.length > 0) root._lastByteAt = Date.now();
        for (let c = 0; c < calls.length; c++)
            root.toolCall({ id: calls[c].id || "", name: calls[c].name || "", args: calls[c].args || ({}) });
        root.finished(root._stats);
    }

    // =========================================================================
    //  The fake tool probe (mirrors LlmBackend.probeTools)
    // =========================================================================

    property var _probeCb: null
    property string _probeModel: ""
    property int _probeHandle: 0

    function probeTools(model, cb, opts) {
        root._probeCb = cb;
        root._probeModel = model;
        root._probeHandle = ++root._handleSeq;
        _probeTimer.interval = Math.max(1, root.probeMs > 0 ? root.probeMs : root.classifyMs);
        _probeTimer.restart();
        return root._probeHandle;
    }

    Timer {
        id: _probeTimer
        repeat: false
        onTriggered: {
            const cb = root._probeCb;
            root._probeCb = null;
            root._probeHandle = 0;
            if (!cb) return;
            let digest = "";
            for (let i = 0; i < root.models.length; i++)
                if (root.models[i].id === root._probeModel) digest = root.models[i].digest || "";
            const v = root.probeVerdicts[digest];
            try {
                cb(v ? { calledRight: !!v.calledRight, usedResult: !!v.usedResult, ms: root.classifyMs, why: v.why || "" }
                     : null);
            } catch (e) { }
        }
    }

    // =========================================================================
    //  Script construction
    // =========================================================================

    // blockLoading so `text()` is a synchronous read: send() may be the first
    // thing that ever touches the fixture, and a script that arrives one frame
    // later would have missed its own start.
    FileView {
        id: _fixture
        path: root.fixturePath
        blockLoading: true
        printErrors: false
    }

    function _buildScript() {
        if (root.fixturePath.length > 0) {
            let txt = "";
            try { txt = _fixture.text(); } catch (e) { txt = ""; }
            if (txt && txt.length > 0 && root._ingestNdjson(txt)) return;
            // A missing or unreadable fixture falls back to the canned answer
            // rather than to an empty screen that looks like a bug.
            root._lastError = "Fixture " + root.fixturePath + " could not be read; using the canned answer";
        }
        root._ingestCanned();
    }

    function _ingestNdjson(txt) {
        const lines = txt.split("\n");
        const script = [];
        let total = 0;
        let stats = null;
        let firstT = 0;
        let lastT = 0;
        // Runs of the same kind are merged: 494 one-token entries would make
        // the character walk below chase an array index per three characters.
        let cur = null;
        for (let i = 0; i < lines.length; i++) {
            const s = lines[i].trim();
            if (s.length === 0) continue;
            let f;
            try { f = JSON.parse(s); } catch (e) { continue; }
            const t = Date.parse(f.created_at || "");
            if (!isNaN(t)) {
                if (firstT === 0) firstT = t;
                lastT = t;
            }
            const m = f.message;
            if (m) {
                const pairs = [["thinking", m.thinking], ["content", m.content]];
                for (let p = 0; p < pairs.length; p++) {
                    const kind = pairs[p][0];
                    const text = pairs[p][1];
                    if (!text || text.length === 0) continue;
                    if (cur && cur.kind === kind) cur.text += text;
                    else { cur = { kind: kind, text: text }; script.push(cur); }
                    total += text.length;
                }
            }
            if (f.done === true) {
                const evalNs = f.eval_duration || 0;
                const n = f.eval_count || 0;
                stats = {
                    promptTokens: f.prompt_eval_count || 0,
                    evalTokens: n,
                    totalMs: (f.total_duration || 0) / 1e6,
                    loadMs: (f.load_duration || 0) / 1e6,
                    evalMs: evalNs / 1e6,
                    tokensPerSecond: evalNs > 0 ? (n / (evalNs / 1e9)) : 0,
                    doneReason: f.done_reason || "stop"
                };
            }
        }
        if (script.length === 0) return false;

        root._script = script;
        root._totalChars = total;
        root._stats = stats || root._syntheticStats(total);
        // The capture's own pace, expressed in this Timer's units. A capture
        // with no usable timestamps falls back to `charsPerTick`.
        const spanMs = lastT - firstT;
        root._baseChars = (spanMs > 0)
            ? Math.max(0.05, total / (spanMs / Math.max(1, root.tickMs)))
            : root.charsPerTick;
        return true;
    }

    function _ingestCanned() {
        root._script = [
            { kind: "thinking", text: root._cannedThinking },
            { kind: "content", text: root._cannedAnswer }
        ];
        root._totalChars = root._cannedThinking.length + root._cannedAnswer.length;
        root._baseChars = root.charsPerTick;
        root._stats = root._syntheticStats(root._totalChars);
    }

    // Tokens are not characters; ~4 characters per token is the usual ratio for
    // English prose and it is only ever shown as a footer figure.
    // HOW LONG THE MOCK PRETENDS PROMPT EVALUATION TOOK. Not decoration:
    // `LlmService._notePromptRate` derives a model's prompt rate from
    // totalMs - evalMs - loadMs, and the round deadline is derived from that
    // rate -- so a `totalMs` that left no room for the prompt half (the
    // generation time alone is smaller than loadMs) would teach the service
    // nothing and make the whole mechanism undrivable offline.
    // 300 ms against the fixed 90 prompt tokens is 300 tok/s.
    property int    promptEvalMs: 300

    function _syntheticStats(chars) {
        const n = Math.round(chars / 4);
        const ms = (root.tickMs / Math.max(0.01, root.speed))
                 * (chars / Math.max(1, root._baseChars));
        const load = root.simulateLoadStall ? root.loadStallMs : 120;
        return {
            promptTokens: 90,
            evalTokens: n,
            totalMs: ms + load + root.promptEvalMs,
            loadMs: load,
            evalMs: ms,
            tokensPerSecond: ms > 0 ? (n / (ms / 1000)) : 0,
            doneReason: "stop"
        };
    }

    Component.onCompleted: root._buildScript()

    // =========================================================================
    //  The canned answer
    //
    //  Every block kind the renderer claims: heading, paragraph, bullets with
    //  nesting, a numbered list, a task list, an aligned table, a blockquote,
    //  a fenced bash block, a fenced json block, a rule, a link, inline code,
    //  bold, italic and strikethrough. If the view can lay this out, it can lay
    //  out an answer.
    // =========================================================================
    readonly property string _cannedThinking: [
        "The user wants a tour of every block kind.",
        "Plan: open with a heading, then prose that carries the inline marks,",
        "then the two list flavours, a table with three alignments, a quote,",
        "one shell fence and one JSON fence, a rule, and a closing link.",
        "Keep it short enough to read at a glance."
    ].join(" ")

    readonly property string _cannedAnswer: [
        "## Rendering check",
        "",
        "Here is **every** block this view claims to render, in one answer.",
        "Inline marks: *italic*, **bold**, ~~struck~~, `inline_code(*not*_emphasis)`,",
        "and a [link with [brackets] inside](https://quickshell.org/docs/).",
        "",
        "### Lists",
        "",
        "- a bullet",
        "- a bullet with a nested list",
        "    - nested one level",
        "    - and a second",
        "- back to the top level",
        "",
        "1. first numbered item",
        "2. second numbered item",
        "3. third numbered item",
        "",
        "- [x] a finished task",
        "- [ ] an unfinished one",
        "",
        "### A table",
        "",
        "| Model | Params | Speed |",
        "|:------|-------:|:-----:|",
        "| e2b   |   5.1B | 35 t/s |",
        "| e4b   |   8.0B | 21 t/s |",
        "| 26b   |  25.8B | 4 t/s |",
        "",
        "> A blockquote, which is parsed as markdown itself, so it can carry",
        "> **bold** and `code` too.",
        "",
        "### Code",
        "",
        "```bash",
        "# warm the model without generating",
        "curl -s http://localhost:11434/api/chat \\",
        "  -d '{\"model\":\"gemma4:e2b\",\"messages\":[],\"keep_alive\":\"30m\"}'",
        "```",
        "",
        "```json",
        "{",
        "  \"model\": \"gemma4:e2b\",",
        "  \"stream\": true,",
        "  \"think\": true,",
        "  \"options\": { \"num_ctx\": 8192, \"num_gpu\": 99 }",
        "}",
        "```",
        "",
        "---",
        "",
        "That is the lot. See the [Quickshell docs](https://quickshell.org/docs/)",
        "for the types used above.",
        ""
    ].join("\n")
}
