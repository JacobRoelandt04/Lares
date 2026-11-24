pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// LlmBackend.qml
//
// The vendor seam. Everything that knows an LLM server's wire format lives in
// this file and nowhere else; the rest of the module speaks only in
// `send()/delta()/finished()`. Swapping Ollama for llama.cpp, vLLM or a hosted
// API is a change to `_buildBody` and `_consumeFrame`, not to the popup.
//
// THE TOOL WIRE. `send()` passes `opts.tools` through, and `_ollamaBody` copies
// a turn's own history through as well -- an assistant message's `tool_calls`,
// a tool message's `tool_name` and `tool_call_id` -- instead of rebuilding
// every message as {role, content, images}. granite's template reads only the tool
// message's `content` (so LlmService names the tool on its first line);
// gemma4's is rendered natively by Ollama; both get the full shape. The
// OpenAI surface gets the same history with the arguments as a JSON string
// and an id synthesised when absent. `probeTools()` is the one request this
// file makes about tools on its own: two non-streaming calls, the classify
// pattern, that ask a model to call the calculator and then to read its
// result -- what the picker's "proven" dot means.
//
// TRANSPORT: curl for every request the module MAY ABANDON, Qt's
// XMLHttpRequest for the rest.
//   * CurlRequest.qml -- one `curl` child per request, streamed line by line,
//     killable -- carries the generation (`send`), `classify`, both steps of
//     `probeTools` and the tuner's verification load in `ctxVerifyLoad`:
//     everything a stop, a round deadline, a dropped title, a probe's
//     deadline or an aborted tune walks away from. Killing the child closes
//     its socket, and the server's request ends with it (see "WHAT OLLAMA
//     DOES"). The XHR cannot do that: `abort()` detaches the callbacks and
//     deletes the reply, and the socket stays open until the PROCESS exits
//     (measured against a server that reports its peer's
//     disconnect: abort(), abort() + dropping the reference + gc(), and
//     "Connection: close" then abort() all left it streaming). Through XHR
//     every stop would be a stop of the LISTENING only: the answer would run
//     to its end on the server, and a stopped cold load would land anyway and
//     have to be polled for and evicted by LlmService.
//   * XHR stays for what nobody walks away from and what loads or generates
//     nothing long: /api/tags, /api/show, /api/ps, /api/version, /v1/models,
//     `warm`, `unload`, and the private `_get` / `_post` / `_request` under
//     them. It is ~7 ms faster per request (warm, 30 alternating runs: first
//     line 38.5 ms through curl, first data 31.8 ms through XHR -- curl's own
//     start and a fresh connection each time) and forks nothing, which
//     matters for the /api/ps read LlmService repeats every 2 s while the
//     VRAM figure is on screen.
//   * Every live CurlRequest is held in `_reqs` (nothing may collect one
//     mid-flight: a destroyed Process SIGKILLs its child, i.e. a disconnect
//     nobody asked for), and classify / probeTools / ctxVerifyLoad return a
//     HANDLE, so `abort(handle)` ends that request on the server and
//     guarantees its callback never fires. Nothing here times anything out,
//     on either transport: when to walk away is LlmService's call, the only
//     object that knows whose round it is, which model is answering, how big
//     the prompt was and what phase the turn is in.
//
// WHAT QT'S XHR DOES NOT HAVE, for the requests that use it (Qt 6.11,
// measured):
//   * no `timeout`, no `onprogress`, no `addEventListener` — only
//     `onreadystatechange`.
//   * reading `.status` before `readyState >= 2` THROWS. Every read is guarded.
//   * `abort()` called from inside `onreadystatechange` re-enters the handler
//     with readyState 4 and the remainder of the outer call never runs.
//     Nothing on XHR is abandoned, so nothing here calls it.
//   * an exception thrown inside `onreadystatechange` is printed as
//     `WARN scene: ... Error:` and the REST OF THE CALLBACK SILENTLY DIES —
//     a reply that never arrives, with no error anywhere. Every handler body
//     is therefore wrapped in try/catch, the CurlRequest ones included.
//
// WHAT OLLAMA DOES, measured on this machine:
//   * `POST /api/chat` streams NDJSON, one object per line, ending with a
//     `{"done":true,...}` frame carrying nanosecond durations.
//   * `POST /v1/chat/completions` streams SSE and carries thinking in a
//     NON-STANDARD `choices[].delta.reasoning`. Both are supported because the
//     OpenAI path is what a non-Ollama server will speak.
//   * `GET /api/tags` UNDER-REPORTS capabilities: it says gemma4:e2b is
//     completion/tools/thinking; `POST /api/show` on the same model says
//     vision and audio as well. Tags is the fast list, show is the truth, so
//     the list is published immediately from tags and each model's caps are
//     patched in as its show call lands. A failed show degrades to what tags
//     said — never to a crash and never to an empty picker.
//   * Ollama ends a request when its HTTP client disconnects, in every phase
//     (ollama 0.34.2, measured through CurlRequest): mid-answer
//     the request's context is finished within 1 ms of the kill, on
//     /api/chat and on /v1/chat/completions alike (gin logs a 200); in
//     prompt evaluation llama-server stops at the next 512-token batch
//     (gin 500) and the model, already loaded, STAYS resident; during a cold
//     load it logs "client connection closed before llama-server finished
//     loading, aborting load" 30-80 ms after the kill (gin 499) and the card
//     is free inside 0.5 s -- a kill that lands before llama-server has even
//     been started is noticed the moment it starts (0.8 s later on
//     granite4.2:3b), before anything reaches the card; a request still
//     QUEUED behind another is dropped at the kill ("aborting chat request
//     due to client closing the connection", gin 500) and never evaluated.
//     So `cancel()` ends the request ON THE SERVER. It does not evict a
//     model that had finished loading: a stop kills the request, not the
//     model.
//   * "Keep answering while the popup is closed" is therefore an OWNERSHIP
//     rule, not a flag, and a load-bearing one: this object must be created
//     by the module outside the popup's component tree, and closing the popup
//     must mean `visible: false`, never destroying it. A destroyed backend
//     takes its CurlRequests with it, Quickshell SIGKILLs their children, and
//     the server abandons the answer. So does a quickshell that dies, by a
//     signal or a crash: the kernel TERMs each curl child with its parent
//     (CurlRequest, "A quickshell that DIES").
//   * A cold 26b load stalls 33-41 s before the first byte. `started()` fires
//     on the first body line, not on send, so the caller can show that wait
//     as a real state instead of pretending tokens are coming.
//
// Item, not QtObject: it owns Timers.
// =============================================================================
Item {
    id: root

    // ---- Configuration -----------------------------------------------------
    property string baseUrl: "http://localhost:11434"
    property string protocol: "ollama"      // "ollama" | "openai"
    // Ollama only. A safety net, not the residency mechanism: the service
    // unloads explicitly (unload/releaseModel/switchModel), and this catches
    // whatever slips past that -- a crash, a kill, a popup that never hides.
    // 10m is "loaded while the conversation is open", not "parked all day".
    property string keepAlive: "10m"
    // Whether a model that can think does: true | false | { "<model>": bool } (a model it does not name thinks).
    property var    think: true
    property real   temperature: -1         // < 0 -> omit
    // The GLOBAL ctx override, kept as a dormant knob. The service passes a
    // per-model value in opts.numCtx on every request and THAT wins; this only
    // applies to a caller that passes none. 0 -> omit, which Ollama silently
    // treats as 4096 -- the whole reason the service always sends one.
    property int    numCtx: 0
    property int    numGpu: -1              // < 0 -> omit (ollama only)

    // ---- Live state --------------------------------------------------------
    readonly property bool   busy: root._busy
    readonly property bool   modelsLoading: root._modelsLoading
    readonly property bool   online: root._online
    readonly property string lastError: root._lastError
    //   [{ id, family, sizeBytes, quant, paramSize, ctx, digest, ple,
    //      arch, moe, expertCount, expertUsed,
    //      caps: { vision, tools, thinking, audio }, loaded, sizeVram }]
    //   `arch` is /api/show's `general.architecture` and it is also the
    //   KNOWN-NESS of the three fields beside it: "" until that model's
    //   /api/show lands, because `expertCount: 0` cannot tell a dense model
    //   from one nobody has described yet. MoE is per MODEL, not per
    //   brand -- measured here, gemma4:26b has 128 experts and gemma4:31b has
    //   none -- so it is read, never guessed from a name.
    //   `digest` is the blob digest from /api/tags (the ctx tuner's cache
    //   fingerprint). `ple` is true once /api/show reports per-layer input
    //   embeddings (gemma e-series): for those the blob on disk says NOTHING
    //   about VRAM (measured: e2b is a 7.16 GB blob and 1.6 GiB resident), so
    //   size-based spill heuristics must not touch them.
    readonly property var    models: root._models
    //   /api/ps: { name: { sizeVram, size, ctx, expiresAt } }
    readonly property var    loaded: root._loaded
    // The last generation request's body, verbatim, for forensics (the live
    // tool probe logs it). Never read by the module itself.
    property string _lastBody: ""

    // WHEN THE STREAM LAST DELIVERED ANYTHING (`lastByteAt`), and how much this
    // request has delivered in total (`_rxLen`). Not a token count and not a
    // delta count: a frame whose content the parsers drop still moved bytes,
    // and the one state that matters here is "is anything arriving at all".
    // Stamped on every body line curl hands over (it runs with `-N`, so a line
    // arrives when the server wrote it, not when a pipe buffer filled). The
    // total is CHARACTERS of body lines plus one per newline, and a character
    // is what the mock counts too.
    //
    // WHY IT EXISTS. While a model writes a tool call's ARGUMENTS, ollama
    // sends nothing -- not a frame, not a byte -- and then delivers the whole
    // `tool_calls` object in the final frame beside `done:true`. Measured
    // on ornith-1.5:9b writing a 11 983-character file: the last
    // content delta landed at t=13.38 s and the next byte of any kind at
    // t=85.95 s, one 13 193-byte frame. The OpenAI surface buffers the same
    // way (28.56 s of silence, then one 5 588-byte SSE chunk). So there is no
    // incremental delivery to watch and no richer honest signal than TIME
    // SINCE THE LAST BYTE -- which is what LlmService turns into its one
    // quiet clock. 0 means nothing has arrived on this request yet.
    readonly property real lastByteAt: root._lastByteAt
    property real   _lastByteAt: 0

    // ---- Stream ------------------------------------------------------------
    signal started()
    signal delta(string text)
    signal thinkingDelta(string text)
    signal toolCall(var call)               // { id, name, args }
    signal finished(var stats)
    //   { promptTokens, evalTokens, totalMs, loadMs, evalMs, tokensPerSecond, doneReason }
    signal failed(string message)

    // ---- Internal state ----------------------------------------------------
    property bool   _busy: false
    property bool   _modelsLoading: false
    property bool   _online: false
    property string _lastError: ""
    property var    _models: []
    property var    _loaded: ({})
    property var    _capsById: ({})

    // THE generation's CurlRequest, and the only thing a stream handler
    // trusts: every line and every exit asks `req === root._req` first.
    // cancel(), _fail() and a settled turn null it, so the tail of a request
    // that is no longer THE request -- its last lines, its exit -- touches
    // nothing, however the calls re-entered in between.
    property var    _req: null
    property int    _rxLen: 0               // characters of body lines (+1 per newline)
    property bool   _sawFirstByte: false
    property real   _sendAt: 0              // wall clock, for the openai path's stats
    property string _sseBuf: ""             // an SSE event's `data:` payload until it is whole
    // The first 16 KiB of the body, for a non-2xx reply's message: the
    // OpenAI surface's error body is JSON, not an SSE `data:` line, so the
    // stream parser never sees it.
    property string _bodyHead: ""

    // Every CurlRequest alive (the generation's included). Held so nothing
    // collects one mid-flight -- a destroyed Process SIGKILLs its child, a
    // disconnect nobody asked for -- and released (destroyed) on its `done`.
    property var    _reqs: []
    // The one-shot jobs by handle (classify, probeTools, ctxVerifyLoad):
    // { req } -- the CurlRequest of the step in flight, null between steps.
    // A job leaves the table when its callback fires or when it is aborted,
    // and a continuation that finds its job gone does nothing.
    property var    _jobs: ({})
    property int    _handleSeq: 0

    // Every metadata XHR in flight (/api/tags, /api/show, /api/ps, warm,
    // version, the ps read after a tuner's load). An ARRAY, not one slot: Qt
    // collects an XHR no JS reference holds, and the ctx tuner's ps read
    // overlapping the startup show queue is exactly the overlap one
    // remembered slot loses.
    property var    _metaXhrs: []
    property var    _showQueue: []          // model ids still to describe
    property int    _metaGen: 0

    // =========================================================================
    //  Model metadata
    // =========================================================================

    // Caps for a model id, always an object — a picker must never have to test
    // for undefined before drawing a dot.
    function capsOf(id) {
        const c = root._capsById[id];
        return c ? c : ({ vision: false, tools: false, thinking: false, audio: false });
    }

    function wantsThink(id) {
        const t = root.think;
        return t && typeof t === "object" ? t[id] !== false : t !== false;
    }

    // "gemma4:26b" -> "26b". A `:latest` tag says nothing, so the name half
    // wins there ("gemma4-26b-tuned:latest" -> "gemma4-26b-tuned").
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
    //  Commands
    // =========================================================================

    function refreshModels() {
        root._metaGen++;
        root._modelsLoading = true;
        if (root.protocol === "openai")
            root._get("/v1/models", root._onOpenAiModels);
        else
            root._get("/api/tags", root._onTags);
    }

    function refreshLoaded() {
        // /api/ps is Ollama-only; the OpenAI surface has no equivalent, and an
        // empty map is the honest answer rather than a fabricated one.
        if (root.protocol === "openai") return;
        root._get("/api/ps", root._onPs);
    }

    // Load a model into VRAM without generating, and push its expiry out.
    // Ollama treats a chat request with no messages as exactly that.
    //
    // `opts.numCtx` IS NOT OPTIONAL IN PRACTICE.
    // num_ctx is a LOAD parameter: a ping sent WITHOUT one asks for the
    // model at ollama's own default 4096, so a model already resident at
    // 8192 is RELOADED and the conversation's KV prefix cache dies with the
    // runner. Measured on granite4.2:3b with a 2904-token prompt:
    // ping with no options -> the next real request paid load 2.37 s +
    // prompt_eval 0.75 s; the same ping carrying the turn's own num_ctx ->
    // load 0.00 s, prompt_eval 0.01 s, twice in a row, expiry pushed both
    // times. So a caller holding a model must send the ctx it holds it at.
    function warm(model, opts) {
        if (!model || root.protocol === "openai") return;
        const o = opts || ({});
        const body = { model: model, messages: [], stream: false, keep_alive: root.keepAlive };
        const wnc = (o.numCtx !== undefined && o.numCtx > 0) ? o.numCtx : root.numCtx;
        if (wnc > 0) body.options = { num_ctx: wnc };
        root._post("/api/chat", JSON.stringify(body),
                   function (_ok, _txt) { root.refreshLoaded(); });
    }

    // The reverse: evict a model from VRAM now. Same empty-messages request
    // with `keep_alive: 0` -- verified against ollama 0.33.2: the
    // reply carries `done_reason: "unload"` and /api/ps is empty afterwards.
    // The OpenAI surface has no unload; there this is a no-op, and the server
    // ages the model out on its own schedule.
    function unload(model) {
        if (!model || root.protocol === "openai") return;
        root._post("/api/chat",
                   JSON.stringify({ model: model, messages: [], stream: false, keep_alive: 0 }),
                   function (_ok, _txt) { root.refreshLoaded(); });
    }

    // messages: [{ role: "user"|"assistant"|"system", content, images: [b64] }]
    // opts:     { think, tools, images, format, numCtx }   (all optional)
    // opts.numCtx > 0 is the per-model context size and beats the global
    // `numCtx` -- num_ctx is a LOAD parameter, so the service sends the same
    // value on every request for a model or Ollama would reload it.
    function send(model, messages, opts) {
        if (root._busy) {
            root.failed("A generation is already in flight");
            return;
        }
        const o = opts || ({});
        const msgs = root._withImages(messages || [], o.images);
        let body;
        try {
            body = root._buildBody(model, msgs, o);
        } catch (e) {
            root._fail("Could not build the request: " + e);
            return;
        }

        root._lastBody = body;
        root._rxLen = 0;
        root._lastByteAt = 0;
        root._sseBuf = "";
        root._bodyHead = "";
        root._sawFirstByte = false;
        root._lastError = "";
        root._busy = true;
        root._sendAt = Date.now();

        const path = root.protocol === "openai" ? "/v1/chat/completions" : "/api/chat";
        const req = root._curl(path, body);
        root._req = req;
        req.line.connect(function (text) { root._onGenLine(req, text); });
        req.done.connect(function (r) { root._onGenDone(req, r); });
        req.begin();
    }

    // Ends the generation ON THE SERVER: the curl child is killed now, its
    // socket closes, and ollama abandons whatever phase the request was in
    // (see the header). Not one more line of it is heard from here on. The
    // turn itself settles ONE TICK LATER, through `_cancelTimer` -- the
    // service's removeTurn drops the live exchange before it calls stop()
    // and relies on `finished` arriving after that.
    function cancel() {
        if (!root._busy) return;
        const req = root._req;
        root._req = null;
        if (req) req.kill();                // the socket closes; the server stops
        _cancelTimer.restart();
    }

    // Ends a classify / probeTools / ctxVerifyLoad request ON THE SERVER, by
    // the handle the call returned (for a probe, whichever of its two steps
    // is in flight; the second is then never sent). Its callback never fires
    // afterwards. A no-op for 0, an unknown handle, or one that has already
    // answered.
    function abort(handle) {
        const job = root._jobs[handle];
        if (!job) return;
        delete root._jobs[handle];
        if (job.req) job.req.kill();
    }


    // =========================================================================
    //  Classification
    //
    //  One non-streaming request that asks the model to NAME and FILE the
    //  exchange it has just finished. Deliberately the SAME model: a second
    //  one would load a second set of weights, and on an 8 GB card that is the
    //  difference between an instant title and a thirty-second stall.
    //  Deliberately AFTER the answer, never beside it, for the same reason.
    //
    //  Structured output here is not a prompt trick. Ollama takes a JSON Schema
    //  in `format` and constrains the sampler to it, so `category` can only
    //  ever be one of the keys the caller passed; the OpenAI surface does the
    //  same through `response_format: { type: "json_schema" }`. Measured on
    //  gemma4:e2b: 0.32-0.41 s warm per exchange, and 11 of 12 test
    //  questions filed where a person would file them.
    //
    //  IT MAY NEVER BREAK A TURN. Its own request (never the generation's),
    //  it does not touch `_busy`, every path is wrapped, and EVERY failure --
    //  transport, HTTP status, a body that is not JSON, JSON of the wrong
    //  shape -- comes back as `cb(null)`. The caller's fallback is what the
    //  user sees; an exception never is.
    //
    //  IT IS ABANDONED ONLY BY ITS CALLER. The returned handle is what
    //  `abort()` takes; nothing here times a title out. LlmService's own
    //  deadline deliberately does NOT abort it (a late title still lands on
    //  its message); a job the service drops for good does.
    // =========================================================================

    // The prompt used when the caller supplies none. It names no categories on
    // purpose: the taxonomy lives on LlmService, and a second copy of it in
    // this file would drift the first time a category's wording changed.
    readonly property string _classifyFallbackPrompt:
        "Name and file the exchange below. Reply with JSON only: a `title` of at "
      + "most six words naming the subject of the question, and a `category`."

    // classify(model, question, answer, cb [, opts])
    //   cb({ title, category }) on success, cb(null) on ANY failure.
    //   opts (all optional): { prompt: <system prompt>,
    //                          categories: [key],   -> the schema's enum
    //                          toolSummaries: [line], -> what the turn RAN
    //                          temperature: <real> }
    // With no `categories` the schema constrains only the TYPE and the caller
    // must validate the string it gets back.
    // Returns the request's handle for abort(), or 0 when nothing was sent
    // (no model, a body that could not be built -- cb(null) has already run).
    function classify(model, question, answer, cb, opts) {
        // Every exit goes through this, so there is exactly one place where a
        // caller's own throw can be caught and dropped.
        const done = function (v) { try { if (cb) cb(v); } catch (e) { } };
        if (!model) { done(null); return 0; }
        const o = opts || ({});
        let body;
        try {
            body = root._classifyBody(model, question || "", answer || "", o);
        } catch (e) {
            done(null);
            return 0;
        }
        const path = root.protocol === "openai" ? "/v1/chat/completions" : "/api/chat";
        const h = root._newJob();
        root._jobPost(h, path, body, function (r, txt) {
            root._endJob(h);
            try {
                if (r.httpStatus < 200 || r.httpStatus >= 300) { done(null); return; }
                done(root._parseClassify(txt));
            } catch (e) {
                // Same swallowing rule as the stream: a throw in here is
                // printed as a warning and the rest of the callback dies, so
                // without this the caller would wait for a reply forever.
                done(null);
            }
        });
        return h;
    }

    function _classifyBody(model, question, answer, o) {
        const prompt = (o.prompt && o.prompt.length > 0)
            ? o.prompt : root._classifyFallbackPrompt;
        // Both halves are cut hard. The first paragraphs already say what the
        // exchange is about, and re-sending a 30 KB answer would cost more
        // prompt evaluation than writing it did. The ANSWER window is 700
        // characters: measured, the answer half was ~300 of an 806-token
        // classify request and the first paragraph is what names the
        // exchange, so the room saved pays for the tool lines below without
        // making the request slower for the models that already miss the
        // deadline.
        //
        // AND A TOOL TURN IS WHAT IT DID. The three calls that ARE a turn --
        // "run `mkdir -p ~/Desktop/test`", "write ~/Desktop/test/script.py" --
        // live on the assistant message, never in its content, so a
        // classifier sent question+answer alone cannot see them and files the
        // turn by the instruction that opened it. Six lines, ~40 tokens.
        let user = "QUESTION:\n" + question.substring(0, 1200)
                 + "\n\nANSWER:\n" + answer.substring(0, 700);
        if (o.toolSummaries && o.toolSummaries.length > 0) {
            const ts = [];
            for (let i = 0; i < o.toolSummaries.length && ts.length < 6; i++) {
                const line = String(o.toolSummaries[i] || "").replace(/\s+/g, " ").trim();
                if (line.length > 0) ts.push(line.substring(0, 120));
            }
            if (ts.length > 0) user += "\n\nTOOLS RUN:\n" + ts.join("\n");
        }
        const cat = { type: "string" };
        // Bracket form: `enum` is a reserved word and a dotted assignment to it
        // is not portable across JS engines.
        if (o.categories && o.categories.length > 0) cat["enum"] = o.categories;
        const props = { title: { type: "string" }, category: cat };
        const required = ["title", "category"];
        const msgs = [{ role: "system", content: prompt },
                      { role: "user", content: user }];
        // Zero temperature: the same exchange must file the same way twice, or
        // a retitle would look like the module changing its mind.
        const temp = (o.temperature === undefined) ? 0 : o.temperature;

        if (root.protocol === "openai") {
            return JSON.stringify({
                model: model, messages: msgs, stream: false, temperature: temp,
                // Ollama's OpenAI surface thinks by DEFAULT on a model that
                // can, and burns ~300 reasoning tokens on a two-field answer
                // without this. Verified: with
                // reasoning_effort "none" the reply carries no `reasoning`.
                reasoning_effort: "none",
                response_format: {
                    type: "json_schema",
                    json_schema: {
                        name: "exchange_label",
                        strict: true,
                        schema: {
                            type: "object", properties: props,
                            required: required, additionalProperties: false
                        }
                    }
                }
            });
        }

        const body = {
            model: model, messages: msgs, stream: false,
            keep_alive: root.keepAlive,
            format: { type: "object", properties: props, required: required },
            options: { temperature: temp }
        };
        // Same guard a generation uses: `think` is only sent to a model that
        // has the capability, because one without it answers with a 400. Here
        // it is always FALSE -- a reasoning preamble for a six-word title is
        // pure latency.
        if (root.capsOf(model).thinking) body.think = false;
        // The SAME effective ctx the generation used (the caller passes it):
        // a classify that omitted num_ctx after an ask that sent one would
        // make Ollama reload the model for a six-word title.
        const cnc = (o.numCtx !== undefined && o.numCtx > 0) ? o.numCtx : root.numCtx;
        if (cnc > 0) body.options.num_ctx = cnc;
        if (root.numGpu >= 0) body.options.num_gpu = root.numGpu;
        return JSON.stringify(body);
    }

    // Two layers of JSON: the transport's frame, then the model's own reply
    // inside `content`. Either can be malformed and neither may throw.
    function _parseClassify(txt) {
        let d;
        try { d = JSON.parse(txt); } catch (e) { return null; }
        if (!d) return null;
        let content = "";
        if (root.protocol === "openai") {
            const ch = (d.choices && d.choices.length > 0) ? d.choices[0] : null;
            content = (ch && ch.message && ch.message.content) ? ch.message.content : "";
        } else {
            content = (d.message && d.message.content) ? d.message.content : "";
        }
        if (!content) return null;
        let v = null;
        try {
            v = JSON.parse(content);
        } catch (e) {
            // A server without schema support hands back the JSON inside a
            // fence or a sentence. Take the outermost braces rather than
            // failing on output that is nearly right.
            const a = content.indexOf("{");
            const b = content.lastIndexOf("}");
            if (a < 0 || b <= a) return null;
            try { v = JSON.parse(content.substring(a, b + 1)); } catch (e2) { return null; }
        }
        if (!v || typeof v.title !== "string" || typeof v.category !== "string")
            return null;
        return { title: v.title, category: v.category };
    }

    // =========================================================================
    //  The tool probe: can this model call a tool and read
    //  its result? Two non-streaming requests, the classify pattern: every
    //  failure is cb(null), nothing here throws or touches `_busy`, and the
    //  returned handle is what abort() takes -- it kills whichever request is
    //  in flight, and request B is then never sent (a probe that went on
    //  to B from A's reply after the service had given up on it would leave
    //  the model resident for the whole keep-alive when it timed out during
    //  a cold load). Request A offers ONE definition (the calculator)
    //  and asks for 17*23; `calledRight` is a tool_call named calculator
    //  carrying a string expression. Request B replays that call with the
    //  result the real runner would produce; `usedResult` is 391 in the reply.
    //  THINKING STAYS ON for a model that has it. Measured on
    //  gemma4:e4b (ollama 0.33.3, temperature 0, the same replay body):
    //  `think:false` answered "391" twice and "<|tool_response>" twice -- the
    //  template's no-thinking path after a tool message is not stable --
    //  while `think:true` answered "391" every time. The thinking tokens
    //  count against num_predict, so the budget is 320, not 64.
    // =========================================================================

    readonly property var _probeCalcWire: ({ type: "function", "function": {
        name: "calculator",
        description: "Evaluate one arithmetic expression exactly. Use it for any calculation.",
        parameters: { type: "object", properties: { expression: { type: "string", description: "the expression, e.g. 17*23" } }, required: ["expression"] } } })

    // probeTools(model, cb [, opts]) -> cb({ calledRight, usedResult, ms, why }) | cb(null)
    //   opts: { tools: [wire definition], numCtx }
    // Returns the probe's handle for abort(), or 0 when nothing was sent.
    function probeTools(model, cb, opts) {
        const done = function (v) { try { if (cb) cb(v); } catch (e) { } };
        if (!model) { done(null); return 0; }
        const o = opts || ({});
        const tools = (o.tools && o.tools.length > 0) ? o.tools : [root._probeCalcWire];
        const t0 = Date.now();
        const question = { role: "user", content: "What is 17*23? Use the calculator tool." };
        const h = root._newJob();
        let over = false;
        const finish = function (v) {
            if (over) return;
            over = true;
            root._endJob(h);
            done(v);
        };
        // A throw inside a step is a failed probe, never a probe that hangs.
        const guard = function (step) {
            return function (reply) {
                try { step(reply); } catch (e) { finish(null); }
            };
        };
        // Request B: did it READ the result?
        const readBack = function (b) {
            if (!b) { finish({ calledRight: true, usedResult: false, ms: Date.now() - t0, why: "no reply after the result" }); return; }
            const bm = b.message || ({});
            const txt = String(bm.content || "");
            const used = txt.indexOf("391") >= 0;
            finish({ calledRight: true, usedResult: used, ms: Date.now() - t0,
                     why: used ? "" : ("ignored the result: " + txt.substring(0, 80).replace(/\s+/g, " ")) });
        };
        // Request A: did it CALL the calculator, and right?
        const call = function (a) {
            if (!a) { finish(null); return; }
            const m = a.message || ({});
            const tcs = m.tool_calls || [];
            const tc = tcs.length > 0 ? tcs[0] : null;
            const fn = tc ? (tc["function"] || ({})) : ({});
            let args = fn.arguments;
            if (typeof args === "string") { try { args = JSON.parse(args); } catch (e) { args = ({}); } }
            const expr = (args && args.expression !== undefined) ? args.expression : undefined;
            const calledRight = !!tc && fn.name === "calculator"
                              && (typeof expr === "string" || typeof expr === "number");
            if (!calledRight) {
                finish({ calledRight: false, usedResult: false, ms: Date.now() - t0,
                         why: tc ? ("called " + (fn.name || "?") + " with " + JSON.stringify(args || {}))
                                 : ("answered without calling: " + String(m.content || "").substring(0, 80).replace(/\s+/g, " ")) });
                return;
            }
            const id = tc.id ? String(tc.id) : "t1_0";
            const replay = [
                question,
                { role: "assistant", content: m.content || "",
                  tool_calls: [{ id: id, type: "function", "function": { name: "calculator", arguments: args || ({}) } }] },
                { role: "tool", tool_name: "calculator", tool_call_id: id,
                  content: "calculator result:\n391\n(1 line, 0.0 s, exit 0)" }
            ];
            root._probePost(h, model, replay, tools, o, guard(readBack));
        };
        root._probePost(h, model, [question], tools, o, guard(call));
        return root._jobs[h] ? h : 0;
    }

    // One step of the probe, on job `h`: cb(reply folded to the ollama shape)
    // or cb(null) on any failure; never after the job was aborted.
    function _probePost(h, model, messages, tools, o, cb) {
        let body;
        try {
            if (root.protocol === "openai") {
                const bo = JSON.parse(root._openAiBody(model, messages, { tools: tools }));
                bo.stream = false;
                bo.max_tokens = 64;
                bo.reasoning_effort = "none";
                delete bo.stream_options;
                body = JSON.stringify(bo);
            } else {
                const thinks = root.capsOf(model).thinking;
                const bb = JSON.parse(root._ollamaBody(model, messages, { tools: tools, numCtx: o.numCtx, think: thinks }));
                bb.stream = false;
                bb.options = bb.options || ({});
                bb.options.num_predict = thinks ? 320 : 64;
                bb.options.temperature = 0;
                body = JSON.stringify(bb);
            }
        } catch (e) { cb(null); return; }
        const path = root.protocol === "openai" ? "/v1/chat/completions" : "/api/chat";
        root._jobPost(h, path, body, function (r, txt) {
            let d = null;
            try {
                if (r.httpStatus >= 200 && r.httpStatus < 300) d = JSON.parse(txt);
                if (d && root.protocol === "openai") {
                    // Fold the OpenAI reply into the ollama shape the caller reads.
                    const ch = (d.choices && d.choices.length > 0) ? d.choices[0] : null;
                    d = { message: ch ? (ch.message || ({})) : ({}) };
                }
            } catch (e2) {
                d = null;
            }
            cb(d);
        });
    }

    // =========================================================================
    //  Request bodies
    // =========================================================================

    // Attach opts.images to the last user message when the caller passed them
    // separately, so both call shapes work.
    function _withImages(messages, images) {
        if (!images || images.length === 0) return messages;
        const out = messages.slice();
        for (let i = out.length - 1; i >= 0; i--) {
            if (out[i].role === "user") {
                const m = {};
                for (const k in out[i]) m[k] = out[i][k];
                m.images = (m.images || []).concat(images);
                out[i] = m;
                break;
            }
        }
        return out;
    }

    function _buildBody(model, messages, o) {
        return root.protocol === "openai"
            ? root._openAiBody(model, messages, o)
            : root._ollamaBody(model, messages, o);
    }

    function _ollamaBody(model, messages, o) {
        const msgs = [];
        for (let i = 0; i < messages.length; i++) {
            const m = messages[i];
            const e = { role: m.role, content: m.content || "" };
            // Ollama takes raw base64 with NO `data:` prefix — a prefixed
            // string is accepted and then decodes to garbage.
            if (m.images && m.images.length > 0)
                e.images = m.images.map(root._stripDataUrl);
            // The tool wire: an assistant's calls ride as
            // `tool_calls`, a result as `role:"tool"` with the name and the
            // id -- granite's template reads only `content`, gemma4's is
            // rendered natively by Ollama; both are sent.
            if (m.tool_calls && m.tool_calls.length > 0) e.tool_calls = m.tool_calls;
            if (m.role === "tool") {
                if (m.tool_name) e.tool_name = m.tool_name;
                if (m.tool_call_id) e.tool_call_id = m.tool_call_id;
            }
            msgs.push(e);
        }
        const body = {
            model: model,
            messages: msgs,
            stream: true,
            keep_alive: root.keepAlive
        };
        // `think` is only sent to a model that has the capability: a model
        // without it answers a think request with a 400, which would read to
        // the user as "the model is broken". To one that has it the answer is said either way: left out, Ollama thinks.
        const wantThink = (o.think === undefined) ? root.wantsThink(model) : o.think;
        if (root.capsOf(model).thinking)
            body.think = !!wantThink;

        const options = {};
        // Per-model beats global: the service computes one stable value per
        // model (manual or tuned) and rides it on every ask.
        const nc = (o.numCtx !== undefined && o.numCtx > 0) ? o.numCtx : root.numCtx;
        if (nc > 0) options.num_ctx = nc;
        if (root.numGpu >= 0) options.num_gpu = root.numGpu;
        if (root.temperature >= 0) options.temperature = root.temperature;
        if (Object.keys(options).length > 0) body.options = options;

        if (o.tools && o.tools.length > 0) body.tools = o.tools;
        if (o.format) body.format = o.format;
        return JSON.stringify(body);
    }

    function _openAiBody(model, messages, o) {
        const msgs = [];
        for (let i = 0; i < messages.length; i++) {
            const m = messages[i];
            if (m.role === "tool") {
                msgs.push({ role: "tool", tool_call_id: m.tool_call_id || "", content: m.content || "" });
                continue;
            }
            if (m.role === "assistant" && m.tool_calls && m.tool_calls.length > 0) {
                // The OpenAI shape wants the arguments as a JSON STRING and
                // an id on every call; one is synthesised when absent.
                msgs.push({
                    role: "assistant", content: m.content || "",
                    tool_calls: m.tool_calls.map(function (tc, k) {
                        const fn = tc["function"] || ({});
                        const args = (typeof fn.arguments === "string") ? fn.arguments : JSON.stringify(fn.arguments || ({}));
                        return { id: tc.id ? String(tc.id) : ("call_" + i + "_" + k), type: "function",
                                 "function": { name: fn.name || "", arguments: args } };
                    })
                });
                continue;
            }
            if (m.images && m.images.length > 0) {
                const parts = [{ type: "text", text: m.content || "" }];
                for (let j = 0; j < m.images.length; j++) {
                    parts.push({
                        type: "image_url",
                        image_url: { url: root._asDataUrl(m.images[j]) }
                    });
                }
                msgs.push({ role: m.role, content: parts });
            } else {
                msgs.push({ role: m.role, content: m.content || "" });
            }
        }
        const body = {
            model: model,
            messages: msgs,
            stream: true,
            // Without this the final SSE frame carries no usage block and the
            // footer would have no token count to show.
            stream_options: { include_usage: true }
        };
        if (root.temperature >= 0) body.temperature = root.temperature;
        // The OpenAI surface thinks unless told not to (see `classify`).
        if (root.capsOf(model).thinking && !root.wantsThink(model)) body.reasoning_effort = "none";
        if (o.tools && o.tools.length > 0) body.tools = o.tools;
        if (o.format === "json") body.response_format = { type: "json_object" };
        return JSON.stringify(body);
    }

    function _stripDataUrl(s) {
        if (!s) return "";
        const i = s.indexOf("base64,");
        return i >= 0 ? s.substring(i + 7) : s;
    }

    function _asDataUrl(s) {
        return (s && s.indexOf("data:") === 0) ? s : ("data:image/png;base64," + s);
    }

    // =========================================================================
    //  The generation's stream
    // =========================================================================

    // One CurlRequest per send(), created here and held in `_reqs` until its
    // `done`, when it is destroyed (deferred -- `destroy()` inside its own
    // signal is safe).
    Component {
        id: _curlC
        CurlRequest {}
    }

    function _curl(path, body) {
        const req = _curlC.createObject(root, { url: root.baseUrl + path, body: body });
        root._reqs.push(req);
        return req;
    }

    function _release(req) {
        const i = root._reqs.indexOf(req);
        if (i >= 0) root._reqs.splice(i, 1);
        req.destroy();
    }

    // Every body line of the generation, whole and in order: CurlRequest's
    // SplitParser decodes complete lines only, so a JSON object split across
    // two TCP reads -- the normal case -- never reaches a parser in halves,
    // and a character split across them never becomes U+FFFD.
    //
    // RE-ENTRANCY. A done frame emits `finished`, and the service's handler
    // sends the next tool round from INSIDE it -- a new `_req` before this
    // call has returned. So `req === root._req` is asked on every line, again
    // after `started()` (whose handler may cancel), and by `_onGenDone`: the
    // old child's tail can never reach the new round.
    function _onGenLine(req, text) {
        if (req !== root._req) return;
        try {
            root._rxLen += text.length + 1;
            root._lastByteAt = Date.now();
            if (root._bodyHead.length < 16384) root._bodyHead += text + "\n";
            if (!root._sawFirstByte) {
                root._sawFirstByte = true;
                root._online = true;
                // Only now is the model actually generating. Everything before
                // this was the load stall.
                root.started();
                if (req !== root._req) return;
            }
            if (root.protocol === "openai") root._consumeSseLine(text);
            else root._consumeNdjsonLine(text);
        } catch (e) {
            if (req === root._req) root._fail("Stream handler failed: " + e);
        }
    }

    function _consumeNdjsonLine(line) {
        const s = line.trim();
        if (s.length === 0) return;
        let f;
        try {
            f = JSON.parse(s);
        } catch (e) {
            // A line cut short (the server closed mid-frame: curl exits 18
            // and the exit says so) or one that is not JSON at all.
            return;
        }
        root._consumeFrame(f);
    }

    // SSE: `data: {json}` lines, a blank line ends the event, `data: [DONE]`
    // ends the stream. Ollama sends one JSON per data line, but the spec allows
    // an event's payload to span several, so they are joined.
    //
    // AN EVENT IS DISPATCHED THE MOMENT ITS PAYLOAD IS WHOLE, not on the
    // blank line after it. SplitParser hands over an empty line that ends a
    // read only with the NEXT read (CurlRequest's header), and Ollama writes
    // each event as one `data: {...}\n\n` -- so waiting for the blank line
    // would put every delta one event late: the last token before a tool call's
    // silence (28.56 s on the OpenAI surface, see `lastByteAt`) unseen for
    // all of it, and lost outright to a stop inside that silence. A payload
    // that does not parse yet waits for its next `data:` line; the blank
    // line then finds the buffer empty, or ends a payload that never parsed.
    function _consumeSseLine(line) {
        if (line.length === 0) { root._sseDispatch(true); return; }
        if (line.indexOf("data:") !== 0) return;      // `event:`/`id:`/comment
        let d = line.substring(5);
        if (d.charAt(0) === " ") d = d.substring(1);
        root._sseBuf += d;
        root._sseDispatch(false);
    }

    // "[DONE]", or JSON that parses to an object (a proper prefix of one
    // never does, so a payload split over data lines is not cut short). At
    // the event's end (`atEnd`) whatever is left is dropped, parsed or not.
    // The buffer is emptied BEFORE the frame is consumed: a done frame emits
    // `finished`, whose handler may already have sent the next round.
    function _sseDispatch(atEnd) {
        const payload = root._sseBuf;
        if (payload === "[DONE]") { root._sseBuf = ""; root._openAiDone(); return; }
        let f = null;
        try { f = JSON.parse(payload); } catch (e) { /* not whole yet */ }
        const whole = f !== null && typeof f === "object";
        if (!whole && !atEnd) return;
        root._sseBuf = "";
        if (whole) root._consumeOpenAiFrame(f);
    }

    // ---- Ollama NDJSON ----
    function _consumeFrame(f) {
        // A 200 response can still carry an error frame mid-stream (this is how
        // a num_gpu overshoot surfaces once the header is already out).
        if (f.error) { root._fail(String(f.error)); return; }

        const m = f.message;
        if (m) {
            if (m.thinking && m.thinking.length > 0) root.thinkingDelta(m.thinking);
            if (m.content && m.content.length > 0) root.delta(m.content);
            if (m.tool_calls) {
                for (let i = 0; i < m.tool_calls.length; i++) {
                    const tc = m.tool_calls[i];
                    const fn = tc.function || ({});
                    root.toolCall({ id: tc.id || "", name: fn.name || "", args: fn.arguments || ({}) });
                }
            }
        }
        if (f.done === true) root._succeed(root._ollamaStats(f));
    }

    function _ollamaStats(f) {
        const evalNs = f.eval_duration || 0;
        const n = f.eval_count || 0;
        return {
            promptTokens: f.prompt_eval_count || 0,
            evalTokens: n,
            totalMs: (f.total_duration || 0) / 1e6,
            loadMs: (f.load_duration || 0) / 1e6,
            evalMs: evalNs / 1e6,
            tokensPerSecond: evalNs > 0 ? (n / (evalNs / 1e9)) : 0,
            doneReason: f.done_reason || "stop",
            // WHO ANSWERED, from the server's own mouth. Ollama echoes the
            // model on every frame; the service stamps the finished message
            // with this rather than with whatever the picker says by the time
            // the stream ends. The OpenAI surface reports none, and there the
            // service falls back to what it sent.
            model: f.model || ""
        };
    }

    // ---- OpenAI SSE ----
    property var _oaUsage: null
    property string _oaFinish: ""

    function _consumeOpenAiFrame(f) {
        if (f.error) {
            const e = f.error;
            root._fail(String(e.message || e));
            return;
        }
        if (f.usage) root._oaUsage = f.usage;
        const ch = f.choices;
        if (!ch || ch.length === 0) return;
        const c = ch[0];
        const d = c.delta || ({});
        // Ollama's OpenAI surface puts reasoning in a non-standard field; other
        // servers use one of the other two spellings. All are optional.
        const think = d.reasoning || d.reasoning_content || d.thinking;
        if (think && think.length > 0) root.thinkingDelta(think);
        if (d.content && d.content.length > 0) root.delta(d.content);
        if (d.tool_calls) {
            for (let i = 0; i < d.tool_calls.length; i++) {
                const tc = d.tool_calls[i];
                const fn = tc.function || ({});
                let args = fn.arguments;
                if (typeof args === "string") {
                    try { args = JSON.parse(args); } catch (e) { /* leave as text */ }
                }
                root.toolCall({ id: tc.id || "", name: fn.name || "", args: args || ({}) });
            }
        }
        if (c.finish_reason) root._oaFinish = c.finish_reason;
    }

    function _openAiDone() {
        const u = root._oaUsage || ({});
        const ms = Date.now() - root._sendAt;
        const n = u.completion_tokens || 0;
        root._succeed({
            promptTokens: u.prompt_tokens || 0,
            evalTokens: n,
            totalMs: ms,
            loadMs: 0,
            evalMs: ms,
            tokensPerSecond: ms > 0 ? (n / (ms / 1000)) : 0,
            doneReason: root._oaFinish || "stop"
        });
    }

    // ---- Completion / failure ----

    // The generation's child has exited. A done frame, an error frame, a
    // cancel or a stream-handler failure has settled the turn already in
    // every normal case; what is left to settle here is an ending the stream
    // itself never announced, mapped onto the messages the user sees:
    //   curl never ran                 -> "Could not run curl ..."
    //   a signal we did not send       -> "The response ended ..."
    //   exit 6/7/28, or no response
    //   and no body (HTTP 000: refused,
    //   curl 52's empty reply, a reset
    //   before any response)           -> "Cannot reach ..." (and offline)
    //   HTTP >= 300 with no error frame-> the body's `error`, else "HTTP n"
    //   2xx without a done frame (curl
    //   18, or 56 after the headers,
    //   or a clean exit)               -> "The response ended ..."
    function _onGenDone(req, r) {
        root._release(req);
        if (r.killed) return;               // ours: cancel() or _fail() settled it
        if (req !== root._req) return;      // an older request's exit
        root._req = null;
        if (!root._busy) return;
        if (r.startFailed) {
            root._fail("Could not run curl — is it installed?");
            return;
        }
        if (r.signalled) {
            root._fail("The response ended before the model finished");
            return;
        }
        if (r.exitCode === 6 || r.exitCode === 7 || r.exitCode === 28
                || (r.httpStatus === 0 && !root._sawFirstByte)) {
            root._online = false;
            root._fail("Could not reach " + root.baseUrl + " — is the model server running?");
            return;
        }
        if (r.httpStatus >= 300 || (r.httpStatus > 0 && r.httpStatus < 200)) {
            let msg = "HTTP " + r.httpStatus;
            try {
                // Ollama's errors are worth quoting verbatim: a num_gpu
                // overshoot says exactly which allocation failed. (Its native
                // error body is an error FRAME and failed the turn above
                // already; this is the OpenAI surface's `{error:{message}}`.)
                const body = JSON.parse(root._bodyHead);
                const e = body ? body.error : null;
                if (e) msg = String(e.message || e);
            } catch (e2) { /* not JSON; the status line is all we have */ }
            root._fail(msg);
            return;
        }
        // 2xx but the stream ended without a done frame: a truncated body.
        root._fail("The response ended before the model finished");
    }

    // `_req` is null here only when a handler of this same frame cancelled
    // (a delta handler calling cancel() on the frame that also says done):
    // the cancel owns the ending then, and a second `finished` must not
    // precede the one `_cancelTimer` is about to emit.
    function _succeed(stats) {
        if (!root._busy || root._req === null) return;
        root._settle();
        root.finished(stats);
    }

    // Also ends the request on the server: an error frame mid-stream, or a
    // handler that threw, is the end of this answer, and what the server
    // would still write after `failed()` must not reach the view as deltas.
    function _fail(msg) {
        root._lastError = msg;
        const live = root._req;
        root._req = null;
        if (live) live.kill();
        if (root._busy) root._settle();
        root.failed(msg);
    }

    function _settle() {
        root._busy = false;
        root._req = null;
        root._oaUsage = null;
        root._oaFinish = "";
    }

    // A cancel is a normal end of turn, not an error: the caller keeps the text
    // that did arrive. Reporting it through failed() would paint a red strip on
    // an answer the user chose to stop. The request is already dead (cancel()
    // killed it); this only settles the turn, one tick late on purpose.
    Timer {
        id: _cancelTimer
        interval: 0
        repeat: false
        onTriggered: {
            root._settle();
            root.finished({
                promptTokens: 0, evalTokens: 0, totalMs: Date.now() - root._sendAt,
                loadMs: 0, evalMs: 0, tokensPerSecond: 0, doneReason: "cancelled"
            });
        }
    }

    // =========================================================================
    //  Context-tuner primitives
    //
    //  Three wire facts the service's ctx auto-tuner needs, and nothing more:
    //  the algorithm (reserve, caps, back-off) lives on LlmService, ONCE --
    //  these only translate Ollama's endpoints, so LlmMockRun can fake the
    //  wire and the service takes the same path offline. All Ollama-only;
    //  every failure is a null/failed callback, never a throw. Measured facts
    //  they rely on (ollama 0.33.2):
    //    * options.num_ctx on an empty-messages load IS honoured (/api/ps
    //      reports it as context_length) -- and silently CLAMPED to the
    //      model's trained context_length.
    //    * /api/ps `size` counts weights + KV but NOT the compute graph
    //      (e4b at 131072: ps says 3.36 GB, nvidia-smi says 6.4 GiB) -- which
    //      is why the tuner keeps a reserve and verifies instead of trusting
    //      arithmetic.
    // =========================================================================

    // One non-streaming /api/version read. cb("" ) on any failure.
    function serverVersion(cb) {
        const done = function (v) { try { if (cb) cb(v); } catch (e) { } };
        if (root.protocol === "openai") { done(""); return; }
        root._get("/api/version", function (ok, txt) {
            if (!ok) { done(""); return; }
            let d;
            try { d = JSON.parse(txt); } catch (e) { done(""); return; }
            done((d && d.version) ? String(d.version) : "");
        });
    }

    // The KV-cache geometry of one model, from /api/show. Keys are namespaced
    // by architecture ("gemma4.block_count"), so they are read via
    // general.architecture -- a plain suffix match would also hit the
    // ".audio."/".vision." submodel keys. head_count_kv missing or null means
    // multi-head attention: every head keeps KV.
    //   cb({ blockCount, kvHeads, headDim, contextLength, paramCount,
    //        plePerLayer, weightBytes, digest })  or cb(null).
    function ctxModelInfo(model, cb) {
        const done = function (v) { try { if (cb) cb(v); } catch (e) { } };
        if (!model || root.protocol === "openai") { done(null); return; }
        root._post("/api/show", JSON.stringify({ model: model }), function (ok, txt) {
            if (!ok) { done(null); return; }
            let d;
            try { d = JSON.parse(txt); } catch (e) { done(null); return; }
            if (!d) { done(null); return; }
            const info = d.model_info || ({});
            const arch = info["general.architecture"] || "";
            const iv = function (key, fb) {
                const v = info[arch + "." + key];
                return (typeof v === "number" && v > 0) ? v : fb;
            };
            const heads = iv("attention.head_count", 0);
            const emb = iv("embedding_length", 0);
            let paramCount = (typeof info["general.parameter_count"] === "number")
                ? info["general.parameter_count"] : 0;
            const det = d.details || ({});
            if (paramCount <= 0) paramCount = root.paramCountOf(det.parameter_size || "");
            let weightBytes = 0;
            let digest = "";
            for (let i = 0; i < root._models.length; i++) {
                if (root._models[i].id !== model) continue;
                weightBytes = root._models[i].sizeBytes || 0;
                digest = root._models[i].digest || "";
                break;
            }
            done({
                blockCount: iv("block_count", 0),
                kvHeads: iv("attention.head_count_kv", heads),
                headDim: iv("attention.key_length",
                            (heads > 0 && emb > 0) ? Math.round(emb / heads) : 0),
                contextLength: iv("context_length", 0),
                paramCount: paramCount,
                plePerLayer: iv("embedding_length_per_layer_input", 0),
                weightBytes: weightBytes,
                digest: digest
            });
        });
    }

    // Load `model` at `numCtx` (empty messages, the normal keep_alive) and
    // report what /api/ps says about it afterwards. The residency criterion is
    // the caller's: this only carries the numbers. `loaded` is refreshed as a
    // side effect, so the picker's dots stay truthful through a tuning run.
    //   cb({ resident, sizeVram, size, ctx, error })  or cb(null) off-protocol.
    // The LOAD goes through curl and the handle it returns is what abort()
    // takes: an ask that aborts the tuner ends the tuner's load on the server
    // instead of paying for it and then reloading at the ask's own num_ctx.
    // The /api/ps read after it stays on XHR (it loads nothing); an abort
    // while it is in flight drops the callback, and the fresh map still
    // lands in `loaded`, since it is simply true. 0 when nothing was sent.
    function ctxVerifyLoad(model, numCtx, cb) {
        const done = function (v) { try { if (cb) cb(v); } catch (e) { } };
        if (!model || root.protocol === "openai") { done(null); return 0; }
        const n = Math.max(1, Math.round(numCtx || 0));
        const body = JSON.stringify({ model: model, messages: [], stream: false,
                                      keep_alive: root.keepAlive,
                                      options: { num_ctx: n } });
        const h = root._newJob();
        const job = root._jobs[h];
        root._jobPost(h, "/api/chat", body, function (r, txt) {
            const ok = r.httpStatus >= 200 && r.httpStatus < 300;
            if (ok) root._online = true;
            else if (r.httpStatus === 0) root._online = false;
            if (!ok) {
                root._endJob(h);
                // A cudaMalloc overshoot is a hard 500 whose body names the
                // failed allocation; quote it.
                let msg = "Could not load the model";
                try {
                    const b = JSON.parse(txt);
                    if (b && b.error) msg = String(b.error);
                } catch (e) { /* not JSON */ }
                done({ resident: false, sizeVram: 0, size: 0, ctx: 0, error: msg });
                return;
            }
            root._get("/api/ps", function (ok2, txt2) {
                if (ok2) root._onPs(true, txt2);
                if (root._jobs[h] !== job) return;      // aborted while ps was out
                root._endJob(h);
                const l = ok2 ? root._loaded[model] : null;
                if (!l) {
                    done({ resident: false, sizeVram: 0, size: 0, ctx: 0,
                           error: ok2 ? "not loaded after the load request"
                                      : "/api/ps unreachable" });
                    return;
                }
                done({ resident: l.size > 0 && l.sizeVram === l.size,
                       sizeVram: l.sizeVram, size: l.size, ctx: l.ctx,
                       error: "" });
            });
        });
        return h;
    }

    // =========================================================================
    //  One-shot requests on curl (classify, the probe's steps, the tuner's load)
    //
    //  A JOB is what a handle names: one entry in `_jobs` for as long as its
    //  caller may still be answered. `_jobPost` sends one request for it and
    //  calls back with every body line joined by "\n" -- unless the job was
    //  aborted, in which case its request was killed and nothing is called.
    //  The caller ends the job (`_endJob`) when it answers its own caller.
    // =========================================================================

    function _newJob() {
        const h = ++root._handleSeq;
        root._jobs[h] = { req: null };
        return h;
    }

    function _endJob(h) { delete root._jobs[h]; }

    // cb(r, text): r is CurlRequest's done record (r.httpStatus 0 = no
    // response at all). Nothing is sent for a job that no longer exists.
    function _jobPost(h, path, body, cb) {
        const job = root._jobs[h];
        if (!job) return;
        const req = root._curl(path, body);
        job.req = req;
        const parts = [];
        req.line.connect(function (t) { parts.push(t); });
        req.done.connect(function (r) {
            root._release(req);
            if (job.req === req) job.req = null;
            if (r.killed || root._jobs[h] !== job) return;
            cb(r, parts.join("\n"));
        });
        req.begin();
    }

    function _endsWith(s, suffix) {
        return s.length >= suffix.length
            && s.lastIndexOf(suffix) === s.length - suffix.length;
    }

    // =========================================================================
    //  Metadata requests (tags / show / ps / warm)
    // =========================================================================

    function _get(path, cb) { root._request("GET", path, null, cb); }
    function _post(path, body, cb) { root._request("POST", path, body, cb); }

    // One-shot, non-streaming, on XHR: the metadata requests nothing ever
    // walks away from (see TRANSPORT in the header). Separate from the
    // generation's request, so a model refresh never disturbs an answer.
    function _request(method, path, body, cb) {
        const xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            try {
                if (xhr.readyState !== XMLHttpRequest.DONE) return;
                const held = root._metaXhrs.indexOf(xhr);
                if (held >= 0) root._metaXhrs.splice(held, 1);
                let status = 0;
                try { status = xhr.status; } catch (e) { status = 0; }
                let txt = "";
                try { txt = xhr.responseText; } catch (e) { txt = ""; }
                if (status >= 200 && status < 300) {
                    root._online = true;
                    cb(true, txt);
                } else {
                    if (status === 0) root._online = false;
                    cb(false, txt);
                }
            } catch (e) {
                // Same swallowing rule as the stream: without this the callback
                // would vanish and modelsLoading would stick on forever.
                root._modelsLoading = false;
                root._lastError = "Request to " + path + " failed: " + e;
            }
        };
        xhr.open(method, root.baseUrl + path);
        if (body !== null) xhr.setRequestHeader("Content-Type", "application/json");
        xhr.send(body);
        root._metaXhrs.push(xhr);
    }

    function _onTags(ok, txt) {
        if (!ok) {
            root._modelsLoading = false;
            root._lastError = "Could not list models at " + root.baseUrl;
            root._models = [];
            return;
        }
        let d;
        try { d = JSON.parse(txt); } catch (e) {
            root._modelsLoading = false;
            root._lastError = "Model list was not JSON";
            return;
        }
        const list = (d && d.models) ? d.models : [];
        const out = [];
        const caps = ({});
        for (let i = 0; i < list.length; i++) {
            const m = list[i];
            const det = m.details || ({});
            const id = m.model || m.name;
            // Tags' capabilities are a floor, not the truth — /api/show
            // upgrades them. Seeding from tags means the picker is usable in
            // the frame after the list arrives instead of after five more
            // round trips. WHAT IS ALREADY KNOWN IS NEVER LOWERED: the popup
            // calls refreshModels() every time it opens, and a seed that
            // dropped `thinking` back to false for the second or two until
            // /api/show lands is a request sent WITHOUT think -- an answer
            // with no thinking to show, from a model that thinks. The show
            // that follows this list refreshes every entry anyway.
            caps[id] = root._capsById[id] ? root._capsById[id]
                     : root._capsFrom(m.capabilities);
            out.push({
                id: id,
                family: det.family || "",
                sizeBytes: m.size || 0,
                quant: det.quantization_level || "",
                paramSize: det.parameter_size || "",
                ctx: 0,
                digest: m.digest || "",
                ple: false,
                arch: "", moe: false, expertCount: 0, expertUsed: 0,
                caps: caps[id],
                loaded: false,
                sizeVram: 0
            });
        }
        root._capsById = caps;
        root._models = out;
        root._showQueue = out.map(function (m) { return m.id; });
        root._nextShow();
        root.refreshLoaded();
    }

    function _capsFrom(arr) {
        const a = arr || [];
        return {
            vision: a.indexOf("vision") >= 0,
            tools: a.indexOf("tools") >= 0,
            thinking: a.indexOf("thinking") >= 0,
            audio: a.indexOf("audio") >= 0
        };
    }

    // Sequential, not parallel: each /api/show reply is ~150 KB of JSON (2012
    // tensor descriptors for gemma4:e2b) and five of them at once would put a
    // ~800 KB parse on one frame.
    function _nextShow() {
        if (root._showQueue.length === 0) {
            root._modelsLoading = false;
            return;
        }
        const gen = root._metaGen;
        const id = root._showQueue[0];
        root._showQueue = root._showQueue.slice(1);
        root._post("/api/show", JSON.stringify({ model: id }), function (ok, txt) {
            if (gen !== root._metaGen) return;      // a newer refresh superseded us
            if (ok) root._applyShow(id, txt);
            root._nextShow();
        });
    }

    function _applyShow(id, txt) {
        let d;
        try { d = JSON.parse(txt); } catch (e) { return; }
        if (!d) return;
        const caps = root._capsFrom(d.capabilities);
        // The context length key is namespaced by architecture
        // ("gemma4.context_length"), so it is found by suffix, not by name.
        // Same walk finds the per-layer-embedding marker that identifies the
        // e-series (VRAM footprint unrelated to blob size).
        // ...and the same walk finds the mixture-of-experts fact, which
        // costs no extra request: `<arch>.expert_count` is present only on an
        // MoE model. The suffix is unambiguous -- ".expert_used_count" and
        // ".expert_shared_feed_forward_length" do not end with it.
        let ctx = 0;
        let ple = 0;
        let experts = 0;
        let used = 0;
        const info = d.model_info || ({});
        for (const k in info) {
            if (k.length > 15 && k.lastIndexOf(".context_length") === k.length - 15)
                ctx = info[k] || 0;
            else if (root._endsWith(k, ".embedding_length_per_layer_input"))
                ple = info[k] || 0;
            else if (root._endsWith(k, ".expert_count"))
                experts = info[k] || 0;
            else if (root._endsWith(k, ".expert_used_count"))
                used = info[k] || 0;
        }
        const arch = String(info["general.architecture"] || "");
        const nextCaps = ({});
        for (const c in root._capsById) nextCaps[c] = root._capsById[c];
        nextCaps[id] = caps;
        root._capsById = nextCaps;

        const next = root._models.slice();
        for (let i = 0; i < next.length; i++) {
            if (next[i].id !== id) continue;
            const e = ({});
            for (const k2 in next[i]) e[k2] = next[i][k2];
            e.caps = caps;
            if (ctx > 0) e.ctx = ctx;
            e.ple = ple > 0;
            e.arch = arch;
            e.moe = experts > 0;
            e.expertCount = experts;
            e.expertUsed = used;
            const det = d.details || ({});
            if (!e.paramSize && det.parameter_size) e.paramSize = det.parameter_size;
            if (!e.quant && det.quantization_level) e.quant = det.quantization_level;
            next[i] = e;
            break;
        }
        root._models = next;
    }

    // Whether a fresh ps read says anything new about residency.
    // `expiresAt` is deliberately NOT compared: the keepAlive clock moves on
    // every touch of a model, nothing reads it, and treating it as a change
    // would defeat the point of asking.
    function _sameResidency(map) {
        const old = root._loaded;
        for (const k in map) {
            const a = map[k];
            const b = old[k];
            if (!b || b.sizeVram !== a.sizeVram || b.size !== a.size
                    || b.ctx !== a.ctx) return false;
        }
        for (const k2 in old) if (!map[k2]) return false;
        return true;
    }

    function _onPs(ok, txt) {
        if (!ok) return;
        let d;
        try { d = JSON.parse(txt); } catch (e) { return; }
        const list = (d && d.models) ? d.models : [];
        const map = ({});
        for (let i = 0; i < list.length; i++) {
            const m = list[i];
            map[m.model || m.name] = {
                sizeVram: m.size_vram || 0,
                size: m.size || 0,
                ctx: m.context_length || 0,
                expiresAt: m.expires_at || ""
            };
        }
        // ps is read after every load, every eviction and every finished turn
        // -- and every couple of seconds while the picker's VRAM bar is on
        // screen. Writing these two unconditionally would emit
        // loadedChanged and modelsChanged on that cadence, and modelsChanged
        // rebuilds the picker's sorted row list. So a read that says nothing
        // new changes nothing. The two are tested SEPARATELY: a fresh
        // /api/tags rebuilds `_models` with every row's `loaded` back at
        // false, and that has to be repaired from a ps map that did not
        // itself move.
        if (!root._sameResidency(map)) root._loaded = map;

        const next = root._models.slice();
        let moved = false;
        for (let i = 0; i < next.length; i++) {
            const info = map[next[i].id];
            const isLoaded = !!info;
            const vram = info ? info.sizeVram : 0;
            if (next[i].loaded === isLoaded && next[i].sizeVram === vram) continue;
            const e = ({});
            for (const k in next[i]) e[k] = next[i][k];
            e.loaded = isLoaded;
            e.sizeVram = vram;
            next[i] = e;
            moved = true;
        }
        if (moved) root._models = next;
    }

    // The OpenAI surface lists ids and nothing else — no size, no quantisation,
    // no capabilities. Everything unknown stays at its neutral value rather
    // than being guessed at.
    function _onOpenAiModels(ok, txt) {
        root._modelsLoading = false;
        if (!ok) {
            root._lastError = "Could not list models at " + root.baseUrl;
            root._models = [];
            return;
        }
        let d;
        try { d = JSON.parse(txt); } catch (e) { return; }
        const list = (d && d.data) ? d.data : [];
        const out = [];
        const caps = ({});
        for (let i = 0; i < list.length; i++) {
            const id = list[i].id;
            caps[id] = { vision: false, tools: false, thinking: false, audio: false };
            out.push({
                id: id, family: "", sizeBytes: 0, quant: "", paramSize: "",
                ctx: 0, digest: "", ple: false,
                arch: "", moe: false, expertCount: 0, expertUsed: 0,
                caps: caps[id], loaded: false, sizeVram: 0
            });
        }
        root._capsById = caps;
        root._models = out;
    }
}
