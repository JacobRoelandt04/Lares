pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// LlmStore.qml
//
// Conversation persistence: one JSON document holding every saved chat, with
// the list of them exposed as a ListModel the sidebar can bind to directly.
//
// WHY ONE FILE AND NOT ONE PER CHAT. The sidebar needs title, model, time and
// message count for every conversation the moment it opens; with a file per
// chat that is 200 reads and a directory watch. One document is a single
// atomic read, and at the sizes involved (a long chat is tens of KB) the whole
// history is smaller than a single model's /api/show reply.
//
// TWO STORES, DELIBERATELY. The ListModel carries only what the sidebar draws;
// the message bodies live in a plain JS map keyed by conversation id. A
// ListModel of ListModels would make every transcript read go through
// `get(i).messages.get(j)`, and the transcript wants a plain array it can hand
// to a delegate. `messagesOf()` returns a COPY so that assigning it to a
// `property var` always emits a change — the same array object assigned twice
// signals nothing and the transcript would freeze mid-answer.
//
// WRITES ARE DEBOUNCED (~400 ms) AND COALESCED. A streaming answer must not
// touch the disk per token; LlmService commits the finished text once and
// calls flush(). FileView's atomicWrites means no reader ever sees a half
// file, and the watcher's echo of our own write is dropped by comparing
// against the exact string we last handed over — the idiom Theme.qml uses
// for the same reason.
//
// A MESSAGE IS WHATEVER THE SERVICE PUT IN IT. Messages are stored as the
// plain objects they arrive as and serialised whole, so a field added to a
// message (`title`, `category` and `titlePending` are such fields)
// round-trips with no change here. The ONE
// exception is `titlePending`: a title request that was in flight when the
// process died is not in flight any more, so ingest clears the flag rather
// than restoring a skeleton that would pulse forever.
//
// INCOGNITO IS AN ABSENCE, NOT A FLAG ON DISK. An incognito conversation is
// skipped by the serialiser, so it exists only in this process; a reload
// re-reads the file and the incognito rows are re-appended from memory
// afterwards, because they have no other home.
//
// THE FILE IS BOUNDED IN BYTES, NOT IN MESSAGES. Writing it is synchronous
// JSON on the UI thread, so its SIZE is a frame-time budget: measured, a
// 21.9 MiB store serialises in 295 ms -- eighteen dropped frames
// under any animation that happens to coincide with a save. Such a store can
// be 15.75 MiB of base64 in THREE COPIES of one 5.3 MiB photo, each the first
// message of a different conversation: `persistedImageMessages` never touches
// them, being a per-conversation rule (twenty-six conversations may each
// keep eight). So there is a second cap, `persistedPayloadBytes`, spent
// newest-first across the whole file; what does not fit is written as
// metadata with `payloadDropped`, which the transcript and the service already
// know how to say out loud. The source file is still at `path` on disk, so
// re-attaching it is what brings the pictures back.
//
// ONE PAYLOAD IS EXEMPT FROM BOTH CAPS: `thumbB64`, the loader's small JPEG
// preview of a picture, a pdf's page 1 or a video's first frame.
// It exists so a chip in the transcript still has a tip after the caps have
// taken the b64 and the pictures beside it, so a cap that could strip it
// would defeat it. _payloadSize does not weigh it and _stripOldPayloads does
// not remove it; a stripped attachment keeps its preview and gains
// `payloadDropped`. It is sized for that role -- measured 3.7-8.4 KB of
// base64 on real files, 12 KB the budget -- and a store of 200
// conversations each keeping two of them would carry under 5 MB of previews
// at the worst case, 65 ms of JSON at the 13.5 ms/MiB measured below.
//
// THE TOOL STATE -- remembered allowances, disabled tools, probe verdicts --
// LIVES IN A SECOND SIBLING, `<path minus .json>.tools.json`, by
// the same idiom as the ctx file below: atomic writes, our own echo dropped,
// watched so a hand edit applies live. It is one object
// and this file does not interpret it: LlmTools reads `toolState` and writes
// through setToolState(); a grant is about the machine, not a conversation,
// which is why it is beside the store and not inside a row.
//
// PER-MODEL CONTEXT STATE LIVES IN A SIBLING FILE, `<path minus .json>.ctx.json`
// -- derived from THIS store's file, not from the directory, so the mockup's
// store and the module's real one cannot share (and cross-pollute) one ctx
// file. It is configuration the ctx tuner writes ({ mode, manualValue,
// autoCache } per model tag), not history: writes are rare (a user gesture or
// a finished tuning run), so they go to disk immediately rather than through
// the history file's debounce -- a tuning run costs model loads, and losing
// its result to a crash would spend them again. Same atomic writes, same
// self-write echo counting. The store only KEEPS this state; what the values
// mean (clamps, fingerprints, defaults) is LlmService's business.
//
// THE MESSAGE QUEUE LIVES IN A FOURTH, `<path minus .json>.queue.json`:
// the messages the user sent while the model was busy and that wait for it
// ({ id, convId, text, model, at, incognito, attachments }, oldest first). It is
// a list the service reads and rewrites whole (`queue` / `setQueue`) -- running
// an entry is the service's business, and what a queued message MEANS (the
// conversation it joins, the model that answers it) is decided there. An
// incognito conversation's entries are memory only, like its history and its
// draft: a shell restart forgets them. A queued message is a gesture, not
// history, so it goes to disk at once; attachments ride whole (the same
// objects the history keeps), so a file queued before a restart is still
// there to be read after it.
//
// AND A THIRD SIBLING FOR PREFERENCES, `<path minus .json>.prefs.json`.
// The default model -- what a fresh module starts on -- is a per-user CHOICE
// and needs a home of its own (otherwise the module starts on whatever literal
// the host declares). It is deliberately a BAG
// (`{ version, defaultModel }`) rather than a file per preference, so the next
// one needs no fourth file, and it is NOT in the ctx file: `_normCtx` drops
// what it does not recognise, and that file is per-model context state rather
// than a global choice. Derived from THIS store's path like the other two, so
// the mockup's store gives `mockup_conversations.prefs.json` and can never
// write the module's real default. Written immediately (a gesture, not
// history) and watched, so a hand edit applies live.
// =============================================================================
Item {
    id: root

    // ---- Configuration -----------------------------------------------------
    // "" resolves to $XDG_STATE_HOME/lares/llm/conversations.json, falling
    // back to $HOME/.local/state. State, not config: it is machine-local
    // history, not something the user edits or tracks in git.
    property string path: ""
    property int    maxConversations: 200
    // How many of a conversation's NEWEST user messages keep their image
    // payloads on disk. Base64 dominates the file -- one screenshot is
    // hundreds of KB of base64, a pdf attachment carries four page renders --
    // so older messages are written without b64/images. The attachment row
    // itself stays (name, kind, peaks, textContent), so chips and tips still
    // render after a reload; what is lost, deliberately, is REGENERATING AN
    // ANCIENT TURN WITH ITS IMAGE -- the model would get the text alone.
    // Memory is never stripped; the cut exists only in what is written.
    property int    persistedImageMessages: 8
    // How many bytes of base64 the WHOLE FILE may carry, across every
    // conversation, handed out newest-first (`_serialize` walks conversations
    // newest-updated first, and `_stripOldPayloads` walks each one's user
    // messages newest-first). 2 MiB because the cost measured here is 13.5 ms
    // of JSON per MiB: 2 MiB of payload plus the prose is about 35 ms, and
    // 2 MiB still holds one whole pdf's extracted pictures (1.5 MiB for the
    // 29-picture deck) or a full-screen screenshot. The FIRST payload
    // the walk meets is kept whatever it weighs -- that is the turn just
    // taken, and regenerating it with its picture is the entire reason any
    // payload is kept at all.
    property int    persistedPayloadBytes: 2 * 1024 * 1024

    // ---- Read-only surface -------------------------------------------------
    readonly property bool loaded: root._loaded
    // Roles: convId, title, model, createdAt, updatedAt, incognito, pinned,
    //        renamed, messageCount, preview, icon. Ordered newest-updated
    //        first.
    readonly property alias conversations: _convs
    readonly property string lastError: root._lastError

    signal changed(string convId)

    // ---- Internal ----------------------------------------------------------
    property bool   _loaded: false
    property string _lastError: ""
    property var    _msgs: ({})             // convId -> [msg]
    property string _selfWriteText: ""      // our own write, to ignore the echo
    // How many of our own writes the watcher still owes us a notification for.
    //
    // One remembered string is not enough. Two writes in quick succession --
    // `flush()` after seeding a batch, then `flush()` again after one more
    // conversation -- leave `_selfWriteText` holding the SECOND text while the
    // FIRST notification is still in flight. That notification carries the
    // older file, matches nothing, and gets ingested as if a foreign editor had
    // written it: the conversation created between the two flushes is wiped out
    // of memory a fraction of a second after it appeared. Counting the writes
    // we owe ourselves closes that window. An external edit that lands inside
    // it is ignored rather than applied, which is the safe way round.
    property int    _pendingEchoes: 0
    property bool   _dirReady: false
    property bool   _ingesting: false

    readonly property string _path: root.path.length > 0 ? root.path : root._defaultPath()
    readonly property string _dir: root._path.substring(0, root._path.lastIndexOf("/"))

    function _defaultPath() {
        const state = Quickshell.env("XDG_STATE_HOME")
                   || (Quickshell.env("HOME") + "/.local/state");
        return state + "/lares/llm/conversations.json";
    }

    ListModel { id: _convs }

    // =========================================================================
    //  Public API
    // =========================================================================

    function create(model, incognito) {
        const id = root._newId();
        const now = Date.now();
        root._msgs[id] = [];
        // Title stays empty on purpose, and stays empty until the first answer
        // is written and named: an empty title is what makes the sidebar draw a
        // skeleton instead of guessing a word from the question.
        _convs.insert(0, {
            convId: id, title: "", model: model || "",
            createdAt: now, updatedAt: now,
            incognito: !!incognito, pinned: false,
            // `renamed` is the whole of the "unless the user renamed it" rule.
            // An empty title cannot carry it: the model writes the
            // title AFTER the first answer, so "" does not mean "nobody has
            // chosen one" -- it means "not yet". One flag, set in exactly one
            // place (setTitle), read in exactly one place (setAutoTitle).
            renamed: false,
            messageCount: 0, preview: "", icon: "", category: ""
        });
        if (!incognito) root._schedule();
        root.changed(id);
        return id;
    }

    function exists(convId) { return root._indexOf(convId) >= 0; }

    function messagesOf(convId) {
        const a = root._msgs[convId];
        return a ? a.slice() : [];
    }

    function appendMessage(convId, msg) {
        const a = root._msgs[convId];
        if (!a) return -1;
        const m = ({});
        for (const k in msg) m[k] = msg[k];
        if (m.at === undefined) m.at = Date.now();
        a.push(m);
        const idx = a.length - 1;
        root._touch(convId);
        root.changed(convId);
        return idx;
    }

    function patchMessage(convId, index, patch) {
        const a = root._msgs[convId];
        if (!a || index < 0 || index >= a.length) return;
        const m = a[index];
        for (const k in patch) m[k] = patch[k];
        root._touch(convId);
        root.changed(convId);
    }

    // Extra: the undo half of appendMessage. `regenerate`
    // and `editAndResend` both mean "this conversation now ends at message N",
    // and without it the service would have to rebuild the array behind the
    // store's back and the two would drift.
    function truncateTo(convId, count) {
        const a = root._msgs[convId];
        if (!a) return;
        if (count < 0) count = 0;
        if (count >= a.length) return;
        a.length = count;
        root._touch(convId);
        root.changed(convId);
    }

    // Extra: drop one message in place. `regenerate` needs exactly this and
    // not a truncate — a "switched model" note appended AFTER the answer is
    // still true after the answer is redone, and truncating would silently
    // erase the explanation of why the next answer is in a different ink.
    function removeMessage(convId, index) {
        const a = root._msgs[convId];
        if (!a || index < 0 || index >= a.length) return;
        a.splice(index, 1);
        root._touch(convId);
        root.changed(convId);
    }

    // The USER's rename. It latches `renamed`, and from then on the model's
    // own titles are ignored for this conversation.
    function setTitle(convId, title) {
        const row = root._indexOf(convId);
        if (row < 0) return;
        _convs.setProperty(row, "title", title || "");
        _convs.setProperty(row, "renamed", true);
        if (!_convs.get(row).incognito) root._schedule();
        root.changed(convId);
    }

    // Extra: the MODEL's title (or the word-trimming fallback). Refuses on a
    // conversation the user has named, so the caller never has to ask first
    // and the two paths cannot race.
    function setAutoTitle(convId, title) {
        const row = root._indexOf(convId);
        if (row < 0) return;
        if (_convs.get(row).renamed) return;
        _convs.setProperty(row, "title", title || "");
        if (!_convs.get(row).incognito) root._schedule();
        root.changed(convId);
    }

    // Extra: the sidebar's pin, and the trimmer's exemption.
    function setPinned(convId, pinned) {
        const row = root._indexOf(convId);
        if (row < 0) return;
        _convs.setProperty(row, "pinned", !!pinned);
        if (!_convs.get(row).incognito) root._schedule();
        root.changed(convId);
    }

    // The topic icon the first answer resolved to (LlmTopicIcons, via the
    // service). Written beside setAutoTitle, not inside it: an icon is not a
    // name, so a user's rename does not freeze it.
    function setCategory(convId, key) {
        const row = root._indexOf(convId);
        if (row < 0) return;
        _convs.setProperty(row, "category", key || "");
        const inc = _convs.get(row).incognito;
        if (!inc) root._schedule();
    }

    // A conversation made incognito (or not) AFTER it was created. Only an empty one: nothing is in it yet, so there is nothing
    // that was ever saved or that must be unsaved -- the top row's incognito button is offered on exactly those. Rewriting the
    // file is still asked for, because the row is now one the serialiser skips (or no longer skips).
    function setIncognito(convId, on) {
        const row = root._indexOf(convId);
        if (row < 0) return;
        const c = _convs.get(row);
        if (c.incognito === !!on) return;
        if ((root._msgs[convId] || []).length > 0) return;
        _convs.setProperty(row, "incognito", !!on);
        root._schedule();
        root.changed(convId);
    }

    function setIcon(convId, icon) {
        const row = root._indexOf(convId);
        if (row < 0) return;
        _convs.setProperty(row, "icon", icon || "");
        if (!_convs.get(row).incognito) root._schedule();
        root.changed(convId);
    }

    // Extra: read one conversation's header without walking the ListModel.
    function meta(convId) {
        const row = root._indexOf(convId);
        if (row < 0) return null;
        const c = _convs.get(row);
        return {
            convId: c.convId, title: c.title, model: c.model,
            createdAt: c.createdAt, updatedAt: c.updatedAt,
            incognito: c.incognito, pinned: c.pinned, renamed: c.renamed,
            messageCount: c.messageCount, preview: c.preview, icon: c.icon,
            category: c.category || "",
        };
    }

    // Extra: a model change is recorded per conversation, so reopening an old
    // chat reopens it on the model it was last answered with.
    function setModel(convId, model) {
        const row = root._indexOf(convId);
        if (row < 0) return;
        _convs.setProperty(row, "model", model || "");
        if (!_convs.get(row).incognito) root._schedule();
    }

    function remove(convId) {
        const row = root._indexOf(convId);
        if (row < 0) return;
        const wasSaved = !_convs.get(row).incognito;
        _convs.remove(row);
        delete root._msgs[convId];
        if (root._drafts[convId] !== undefined) {
            delete root._drafts[convId];
            _draftTimer.restart();
        }
        if (wasSaved) root._schedule();
        root.changed(convId);
    }

    // Title + body, case-insensitive, in the list's own order so the sidebar
    // can filter without re-sorting.
    function search(query) {
        const q = (query || "").toLowerCase();
        const out = [];
        if (q.length === 0) {
            for (let i = 0; i < _convs.count; i++) out.push(_convs.get(i).convId);
            return out;
        }
        for (let i = 0; i < _convs.count; i++) {
            const id = _convs.get(i).convId;
            if (root.matchCount(id, q) > 0) out.push(id);
        }
        return out;
    }

    function matchCount(convId, query) {
        const q = (query || "").toLowerCase();
        if (q.length === 0) return 0;
        const row = root._indexOf(convId);
        if (row < 0) return 0;
        let n = root._countIn((_convs.get(row).title || "").toLowerCase(), q);
        const a = root._msgs[convId] || [];
        for (let i = 0; i < a.length; i++)
            n += root._countIn((a[i].content || "").toLowerCase(), q);
        return n;
    }

    function _countIn(hay, needle) {
        let n = 0;
        let i = hay.indexOf(needle);
        while (i >= 0) { n++; i = hay.indexOf(needle, i + needle.length); }
        return n;
    }

    function flush() {
        _writeTimer.stop();
        root._write();
    }

    // =========================================================================
    //  Per-model context state (the ctx tuner's persistence)
    // =========================================================================

    signal ctxChanged(string model)

    property var    _ctx: ({})              // model tag -> { mode, manualValue, autoCache }
    property string _ctxSelfText: ""
    property int    _ctxEchoes: 0

    readonly property string _ctxPath:
        root._path.replace(/\.json$/, "") + ".ctx.json"

    // A COPY, like messagesOf: the caller may hold and mutate it freely.
    // null for a model no one has configured -- the service supplies the
    // default semantics, not this file.
    function ctxStateOf(model) {
        const e = root._ctx[model];
        if (!e) return null;
        return {
            mode: e.mode,
            manualValue: e.manualValue,
            autoCache: { value: e.autoCache.value, fingerprint: e.autoCache.fingerprint }
        };
    }

    function setCtxState(model, st) {
        if (!model) return;
        root._ctx[model] = root._normCtx(st);
        root._writeCtx();
        root.ctxChanged(model);
    }

    function _normCtx(st) {
        const s = st || ({});
        const c = s.autoCache || ({});
        return {
            mode: s.mode === "auto" ? "auto" : "manual",
            manualValue: Math.max(0, Math.round(s.manualValue || 0)),
            autoCache: {
                value: Math.max(0, Math.round(c.value || 0)),
                fingerprint: String(c.fingerprint || "")
            }
        };
    }

    FileView {
        id: _ctxFile
        path: root._ctxPath
        atomicWrites: true
        printErrors: false
        watchChanges: true
        onFileChanged: _ctxFile.reload()
        onLoaded: root._onCtxText(_ctxFile.text())
        onTextChanged: root._onCtxText(_ctxFile.text())
    }

    function _onCtxText(txt) {
        if (!txt || txt.length === 0) return;
        if (txt === root._ctxSelfText) {
            if (root._ctxEchoes > 0) root._ctxEchoes -= 1;
            return;
        }
        if (root._ctxEchoes > 0) { root._ctxEchoes -= 1; return; }
        let d;
        try { d = JSON.parse(txt); } catch (e) {
            root._lastError = "Context state at " + root._ctxPath + " is not valid JSON";
            return;
        }
        const src = (d && d.models) ? d.models : ({});
        const next = ({});
        const touched = [];
        for (const k in src) { next[k] = root._normCtx(src[k]); touched.push(k); }
        // A model REMOVED by an external edit changed too.
        for (const k in root._ctx) if (touched.indexOf(k) < 0) touched.push(k);
        root._ctx = next;
        for (let i = 0; i < touched.length; i++) root.ctxChanged(touched[i]);
    }

    function _writeCtx() {
        if (!root._dirReady) { _ctxRetryTimer.restart(); return; }
        const txt = JSON.stringify({ version: 1, models: root._ctx }, null, 1) + "\n";
        if (txt === root._ctxSelfText) return;
        root._ctxSelfText = txt;
        root._ctxEchoes += 1;
        _ctxFile.setText(txt);
    }

    Timer {
        id: _ctxRetryTimer
        interval: 250
        repeat: false
        onTriggered: root._writeCtx()
    }

    // =========================================================================
    //  Tool state (grants, disabled tools, probe verdicts) -- the second sibling
    // =========================================================================

    // `toolStateChanged` is this property's own change
    // signal: every path that changes the state assigns a NEW object.
    readonly property var toolState: root._toolState
    property var    _toolState: ({ version: 1, grants: [], disabled: [], probes: ({}) })
    property string _toolSelfText: ""
    property int    _toolEchoes: 0

    readonly property string _toolPath:
        root._path.replace(/\.json$/, "") + ".tools.json"

    function setToolState(obj) {
        root._toolState = root._normTool(obj);
        root._writeTool();
    }

    function _normTool(st) {
        const s = st || ({});
        const grants = [];
        const src = Array.isArray(s.grants) ? s.grants : [];
        for (let i = 0; i < src.length; i++) {
            const g = src[i];
            if (!g || typeof g.tool !== "string" || typeof g.key !== "string") continue;
            grants.push({ tool: g.tool, key: g.key, label: String(g.label || g.key),
                          at: Math.round(g.at || 0), uses: Math.max(0, Math.round(g.uses || 0)) });
        }
        const disabled = [];
        const ds = Array.isArray(s.disabled) ? s.disabled : [];
        for (let j = 0; j < ds.length; j++) if (typeof ds[j] === "string") disabled.push(ds[j]);
        const probes = ({});
        const ps = (s.probes && typeof s.probes === "object") ? s.probes : ({});
        for (const k in ps) if (ps[k] && typeof ps[k] === "object") probes[k] = ps[k];
        return { version: 1, grants: grants, disabled: disabled, probes: probes };
    }

    FileView {
        id: _toolFile
        path: root._toolPath
        atomicWrites: true
        printErrors: false
        watchChanges: true
        onFileChanged: _toolFile.reload()
        onLoaded: root._onToolText(_toolFile.text())
        onTextChanged: root._onToolText(_toolFile.text())
    }

    function _onToolText(txt) {
        if (!txt || txt.length === 0) return;
        if (txt === root._toolSelfText) {
            if (root._toolEchoes > 0) root._toolEchoes -= 1;
            return;
        }
        if (root._toolEchoes > 0) { root._toolEchoes -= 1; return; }
        let d;
        try { d = JSON.parse(txt); } catch (e) {
            root._lastError = "Tool state at " + root._toolPath + " is not valid JSON";
            return;
        }
        root._toolState = root._normTool(d);
    }

    function _writeTool() {
        if (!root._dirReady) { _toolRetryTimer.restart(); return; }
        const txt = JSON.stringify(root._toolState, null, 1) + "\n";
        if (txt === root._toolSelfText) return;
        root._toolSelfText = txt;
        root._toolEchoes += 1;
        _toolFile.setText(txt);
    }

    Timer {
        id: _toolRetryTimer
        interval: 250
        repeat: false
        onTriggered: root._writeTool()
    }

    // =========================================================================
    //  The message queue (the fourth sibling)
    // =========================================================================

    // Every setQueue assigns a NEW array, so this property is its own change signal.
    readonly property var queue: root._queue
    property var    _queue: []
    property bool   _queueLoaded: false

    readonly property string _queuePath:
        root._path.replace(/\.json$/, "") + ".queue.json"

    function setQueue(list) {
        root._queue = root._normQueue(list);
        root._writeQueue();
    }

    function _normQueue(list) {
        const out = [];
        const src = Array.isArray(list) ? list : [];
        for (let i = 0; i < src.length; i++) {
            const e = src[i];
            if (!e || typeof e.id !== "string" || e.id.length === 0) continue;
            out.push({
                id: e.id,
                convId: String(e.convId || ""),
                text: String(e.text || ""),
                model: String(e.model || ""),
                at: Math.round(e.at || 0),
                incognito: !!e.incognito,
                attachments: Array.isArray(e.attachments) ? JSON.parse(JSON.stringify(e.attachments)) : [],
                // A SPOKEN ask (LlmService.voiceAsk): where it was asked from. It runs hands-free when its turn comes.
                voice: (e.voice && typeof e.voice === "object")
                       ? { windowClass: String(e.voice.windowClass || ""), windowTitle: String(e.voice.windowTitle || ""),
                           cwd: String(e.voice.cwd || ""), at: Math.round(e.voice.at || 0) }
                       : null
            });
        }
        return out;
    }

    FileView {
        id: _queueFile
        path: root._queuePath
        atomicWrites: true
        printErrors: false
        onLoaded: root._onQueueText(_queueFile.text())
    }

    // Read once, at start: what the file holds goes in FRONT of what the
    // service has already queued (nothing, in practice; an entry queued in the
    // first milliseconds still keeps its place behind the older ones).
    function _onQueueText(txt) {
        if (root._queueLoaded) return;
        root._queueLoaded = true;
        if (!txt || txt.length === 0) return;
        let d;
        try { d = JSON.parse(txt); } catch (e) {
            root._lastError = "Queue at " + root._queuePath + " is not valid JSON";
            return;
        }
        const disk = root._normQueue(d && d.entries);
        if (disk.length === 0) return;
        const have = ({});
        for (let i = 0; i < root._queue.length; i++) have[root._queue[i].id] = true;
        root._queue = disk.filter(function (e) { return !have[e.id]; }).concat(root._queue);
        if (root._queueGrace) root._writeQueue();
    }

    // No write before the file has been read -- or has had its chance to be:
    // a file that does not exist never says so, which is what the grace is for.
    property bool _queueGrace: false
    Timer {
        interval: 300
        running: true
        repeat: false
        onTriggered: root._queueGrace = true
    }

    function _writeQueue() {
        if (!root._dirReady || !(root._queueLoaded || root._queueGrace)) { _queueRetryTimer.restart(); return; }
        const keep = [];
        for (let i = 0; i < root._queue.length; i++)
            if (!root._queue[i].incognito) keep.push(root._queue[i]);
        _queueFile.setText(JSON.stringify({ version: 1, entries: keep }, null, 1) + "\n");
    }

    Timer {
        id: _queueRetryTimer
        interval: 250
        repeat: false
        onTriggered: root._writeQueue()
    }

    // =========================================================================
    //  Preferences (the third sibling): the per-user choices that are not
    //  history and not per-model state.
    // =========================================================================

    signal prefsChanged()

    // "" = no default; a fresh module starts on the host's own literal.
    readonly property string defaultModel: root._prefs.defaultModel

    property var    _prefs: ({ version: 1, defaultModel: "" })
    property string _prefsSelfText: ""
    property int    _prefsEchoes: 0

    readonly property string _prefsPath:
        root._path.replace(/\.json$/, "") + ".prefs.json"

    // Stores exactly what it is given; "" is no default. The TOGGLE -- an id
    // that is already the default clearing it -- is LlmService's decision, so
    // that a hand edit of this file cannot be second-guessed by a rule that
    // lives here.
    function setDefaultModel(id) {
        const v = String(id || "");
        if (v === root._prefs.defaultModel) return;
        root._prefs = root._normPrefs({ defaultModel: v });
        root._writePrefs();
        root.prefsChanged();
    }

    function _normPrefs(pr) {
        const o = pr || ({});
        return { version: 1, defaultModel: String(o.defaultModel || "") };
    }

    // ---- Unsent prompts (the bag's `drafts`) --------------------------------
    // What is typed in the composer and not sent: convId -> text, and "" for the chat that does not exist yet (nothing is created
    // until the first ask). The popup writes it as the text changes -- in memory at once, to disk after `draftSaveMs` of quiet --
    // and reads it back when it is built, which is why a prompt outlives the popup (the engine destroys the content on close), a
    // rebuild, and the shell. An incognito conversation's draft is memory only, like the conversation. A plain object mutated in
    // place: nothing binds to it, the popup asks when it needs it.
    property int    draftSaveMs: 700
    property var    _drafts: ({})
    property bool   _draftsLoaded: false

    function draftOf(convId) {
        return String(root._drafts[convId || ""] || "");
    }

    function setDraft(convId, text) {
        const k = String(convId || "");
        const t = String(text || "");
        if ((root._drafts[k] || "") === t) return;
        if (t.length === 0) delete root._drafts[k];
        else root._drafts[k] = t;
        _draftTimer.restart();
    }

    // A draft changes hands with its conversation: an empty chat put away hands its prompt to "the chat that does not exist yet",
    // and the chat made next takes it from there. Nothing typed is ever dropped by a conversation going.
    function moveDraft(from, to) {
        const a = String(from || ""), b = String(to || "");
        if (a === b) return;
        const t = root._drafts[a];
        if (t === undefined) return;
        delete root._drafts[a];
        root._drafts[b] = t;
        _draftTimer.restart();
    }

    function flushDrafts() {
        _draftTimer.stop();
        root._writePrefs();
    }

    // What goes to disk: the "" draft and those of conversations that still exist and are not incognito.
    function _persistedDrafts() {
        const out = ({});
        for (const k in root._drafts) {
            if (k !== "") {
                const row = root._indexOf(k);
                // Before the history has loaded no chat is known yet: what the file holds for it is kept, not judged (a write in
                // that window must not erase the prompts of the chats still to be read).
                if (row < 0 ? root._loaded : _convs.get(row).incognito) continue;
            }
            out[k] = root._drafts[k];
        }
        return out;
    }

    function _loadDrafts(d) {
        if (root._draftsLoaded) return;
        root._draftsLoaded = true;
        const src = (d && d.drafts && typeof d.drafts === "object") ? d.drafts : ({});
        for (const k in src) {
            if (typeof src[k] === "string" && src[k].length > 0 && root._drafts[k] === undefined)
                root._drafts[k] = src[k];
        }
    }

    Timer {
        id: _draftTimer
        interval: Math.max(50, root.draftSaveMs)
        repeat: false
        onTriggered: root._writePrefs()
    }

    FileView {
        id: _prefsFile
        path: root._prefsPath
        atomicWrites: true
        printErrors: false
        watchChanges: true
        onFileChanged: _prefsFile.reload()
        onLoaded: root._onPrefsText(_prefsFile.text())
        onTextChanged: root._onPrefsText(_prefsFile.text())
    }

    function _onPrefsText(txt) {
        if (!txt || txt.length === 0) return;
        if (txt === root._prefsSelfText) {
            if (root._prefsEchoes > 0) root._prefsEchoes -= 1;
            return;
        }
        if (root._prefsEchoes > 0) { root._prefsEchoes -= 1; return; }
        let d;
        try { d = JSON.parse(txt); } catch (e) {
            root._lastError = "Preferences at " + root._prefsPath + " are not valid JSON";
            return;
        }
        root._prefs = root._normPrefs(d);
        root._loadDrafts(d);
        root.prefsChanged();
    }

    function _writePrefs() {
        if (!root._dirReady) { _prefsRetryTimer.restart(); return; }
        const txt = JSON.stringify(Object.assign({}, root._prefs, { drafts: root._persistedDrafts() }), null, 1) + "\n";
        if (txt === root._prefsSelfText) return;
        root._prefsSelfText = txt;
        root._prefsEchoes += 1;
        _prefsFile.setText(txt);
    }

    Timer {
        id: _prefsRetryTimer
        interval: 250
        repeat: false
        onTriggered: root._writePrefs()
    }

    // =========================================================================
    //  Bookkeeping
    // =========================================================================

    function _newId() {
        return "c" + Date.now().toString(36)
             + Math.floor(Math.random() * 0x10000).toString(36);
    }

    function _indexOf(convId) {
        for (let i = 0; i < _convs.count; i++)
            if (_convs.get(i).convId === convId) return i;
        return -1;
    }

    // Refresh a conversation's header from its messages and float it back to
    // its place in the newest-first order. `move` rather than a rebuild: a
    // rebuild would reset every delegate and kill the sidebar's row animations.
    function _touch(convId) {
        const row = root._indexOf(convId);
        if (row < 0) return;
        const a = root._msgs[convId] || [];
        const now = Date.now();
        _convs.setProperty(row, "messageCount", a.length);
        _convs.setProperty(row, "updatedAt", now);
        _convs.setProperty(row, "preview", root._previewOf(a));
        // updatedAt was just set to now, which is >= every other row's, so
        // newest-first puts this row at the top. No search needed.
        const saved = !_convs.get(row).incognito;
        if (row !== 0) _convs.move(row, 0, 1);
        if (saved) root._schedule();
    }

    function _previewOf(a) {
        for (let i = a.length - 1; i >= 0; i--) {
            const m = a[i];
            if (m.role === "note") continue;
            const t = (m.content || "").replace(/\s+/g, " ").trim();
            if (t.length > 0) return t.substring(0, 120);
        }
        return "";
    }

    // Oldest first, pinned never touched. An incognito conversation is not on
    // disk and does not count against the budget.
    function _trim() {
        let over = 0;
        for (let i = 0; i < _convs.count; i++)
            if (!_convs.get(i).incognito) over++;
        over -= root.maxConversations;
        if (over <= 0) return;
        for (let i = _convs.count - 1; i >= 0 && over > 0; i--) {
            const c = _convs.get(i);
            if (c.pinned || c.incognito) continue;
            delete root._msgs[c.convId];
            _convs.remove(i);
            over--;
        }
    }

    // =========================================================================
    //  Disk
    // =========================================================================

    FileView {
        id: _file
        path: root._path
        atomicWrites: true
        printErrors: false
        watchChanges: true
        onFileChanged: _file.reload()
        onLoaded: root._onText(_file.text())
        onTextChanged: root._onText(_file.text())
    }

    function _onText(txt) {
        // A mid-save read comes back empty or truncated; never clobber a loaded
        // history with nothing.
        if (!txt || txt.length === 0) { root._loaded = true; return; }
        if (txt === root._selfWriteText) {
            root._loaded = true;
            if (root._pendingEchoes > 0) root._pendingEchoes -= 1;
            return;
        }
        if (root._pendingEchoes > 0) {       // a stale echo of an earlier self-write
            root._pendingEchoes -= 1;
            return;
        }
        if (_writeTimer.running) return;     // our own change is still pending
        root._ingest(txt);
    }

    function _ingest(txt) {
        let d;
        try { d = JSON.parse(txt); } catch (e) {
            root._lastError = "Conversation history at " + root._path + " is not valid JSON";
            root._loaded = true;
            return;
        }
        const list = (d && d.conversations) ? d.conversations : [];

        // Incognito rows have no other copy anywhere; lift them out, rebuild
        // from disk, put them back.
        const keptRows = [];
        for (let i = 0; i < _convs.count; i++) {
            const c = _convs.get(i);
            if (!c.incognito) continue;
            keptRows.push({
                convId: c.convId, title: c.title, model: c.model,
                createdAt: c.createdAt, updatedAt: c.updatedAt,
                incognito: true, pinned: c.pinned, renamed: c.renamed,
                messageCount: c.messageCount, preview: c.preview, icon: c.icon,
                category: c.category || "",
            });
        }
        const keptMsgs = ({});
        for (let i = 0; i < keptRows.length; i++)
            keptMsgs[keptRows[i].convId] = root._msgs[keptRows[i].convId] || [];

        root._ingesting = true;
        _convs.clear();
        root._msgs = keptMsgs;

        const rows = [];
        for (let i = 0; i < list.length; i++) {
            const c = list[i];
            if (!c || !c.id) continue;
            // An empty conversation on disk is a crash artifact: nothing ever
            // writes one on purpose (the serialiser skips them), and restoring
            // it would put a blank "New conversation" row in the sidebar with
            // nothing behind it.
            if (!c.messages || c.messages.length === 0) continue;
            root._msgs[c.id] = root._settleMessages(c.messages || []);
            rows.push({
                convId: c.id,
                title: c.title || "",
                model: c.model || "",
                createdAt: c.createdAt || 0,
                updatedAt: c.updatedAt || c.createdAt || 0,
                incognito: false,
                pinned: !!c.pinned,
                renamed: !!c.renamed,
                messageCount: (c.messages || []).length,
                preview: root._previewOf(c.messages || []),
                icon: c.icon || "",
                category: c.category || ""
            });
        }
        for (let i = 0; i < keptRows.length; i++) rows.push(keptRows[i]);
        rows.sort(function (a, b) { return b.updatedAt - a.updatedAt; });
        for (let i = 0; i < rows.length; i++) _convs.append(rows[i]);

        root._ingesting = false;
        root._trim();
        root._loaded = true;
        root.changed("");
    }

    // Nothing that was IN FLIGHT when the file was written is in flight now.
    // A message left `pending` mid-stream keeps its half-answer (better than an
    // empty bubble), and a message left `titlePending` gets the flag cleared so
    // the header shows its title -- or its absence -- instead of a skeleton
    // that pulses for a request no process is waiting on. Mutated in place: the
    // array was just parsed out of JSON and nobody else holds it.
    function _settleMessages(a) {
        for (let i = 0; i < a.length; i++) {
            if (!a[i]) continue;
            if (a[i].titlePending) a[i].titlePending = false;
            if (a[i].pending) a[i].pending = false;
        }
        return a;
    }

    function _serialize() {
        const out = [];
        // The payload budget is spent as this loop runs, and `_convs` is
        // ordered newest-updated first, so it is the newest conversations
        // that keep their pictures.
        root._payloadLeft = root.persistedPayloadBytes;
        root._payloadFirst = true;
        for (let i = 0; i < _convs.count; i++) {
            const c = _convs.get(i);
            if (c.incognito) continue;          // never written, by definition
            // An empty conversation is not history -- it is a popup that was
            // opened and closed. It lives only in memory, and dies there (the
            // service prunes it; ingest catches the stragglers a crash leaves).
            if (c.messageCount === 0) continue;
            out.push({
                id: c.convId,
                title: c.title,
                model: c.model,
                createdAt: c.createdAt,
                updatedAt: c.updatedAt,
                pinned: c.pinned,
                renamed: c.renamed,
                icon: c.icon,
                // Written so that a row's colour survives the process (ingest reads it back).
                category: c.category || "",
                messages: root._stripOldPayloads(root._msgs[c.convId] || [])
            });
        }
        return JSON.stringify({ version: 1, conversations: out }, null, 1) + "\n";
    }

    // The running byte budget. Reset by _serialize, spent here as the walk
    // moves from the newest conversation to the oldest.
    property int    _payloadLeft: 0
    property bool   _payloadFirst: true

    // What one message's payload weighs: its own wire images plus every
    // attachment's b64 and pictures. Text is not counted -- the service caps
    // it at 48 KB a file, and it is 0.25 MiB of a whole real store. Nor
    // is `thumbB64`, by design (see the header): a message whose only
    // picture is its preview weighs nothing here, so it spends none of the
    // byte budget and, inside or outside the newest-N window, has nothing
    // for the strip to take -- the preview rides the copy either way.
    function _payloadSize(m) {
        let n = 0;
        const im = m.images || [];
        for (let i = 0; i < im.length; i++) n += im[i].length;
        // A screenshot a tool took rides on the assistant's entry;
        // its `thumbB64` is exempt like every other preview.
        const tc = m.toolCalls || [];
        for (let t = 0; t < tc.length; t++)
            if (tc[t] && tc[t].image) n += tc[t].image.length;
        const atts = m.attachments || [];
        for (let j = 0; j < atts.length; j++) {
            const t = atts[j];
            if (!t) continue;
            if (t.b64) n += t.b64.length;
            const ai = t.images || [];
            for (let k = 0; k < ai.length; k++) n += ai[k].length;
        }
        return n;
    }

    // The two payload caps, applied at WRITE time and never to the in-memory
    // copy: shallow-copied messages with `images` (the legacy baked wire copy)
    // and each attachment's `b64`/`images` removed -- every other key,
    // `thumbB64` included, rides the copy -- walking user messages
    // newest-first. A stripped attachment is marked `payloadDropped: true` so
    // a tip can say why there is no picture behind its preview.
    //
    // The tighter of the two wins: at most `persistedImageMessages`
    // payload-carrying user messages in one conversation, and at most
    // `persistedPayloadBytes` of base64 in the file as a whole.
    function _stripOldPayloads(a) {
        let userSeen = 0;
        let out = a;
        for (let i = a.length - 1; i >= 0; i--) {
            const m = a[i];
            if (!m) continue;
            if (m.role === "assistant") {
                // The tool screenshot's picture goes under the same caps as a
                // user message's; the preview stays and `imageDropped` says
                // why the full picture is not there.
                const size2 = root._payloadSize(m);
                if (size2 === 0) continue;
                userSeen++;
                if (userSeen <= root.persistedImageMessages
                        && (root._payloadFirst || size2 <= root._payloadLeft)) {
                    root._payloadFirst = false;
                    root._payloadLeft = Math.max(0, root._payloadLeft - size2);
                    continue;
                }
                if (out === a) out = a.slice();
                const c2 = ({});
                for (const k2 in m) c2[k2] = m[k2];
                c2.toolCalls = (m.toolCalls || []).map(function (t) {
                    if (!t || !t.image) return t;
                    const s2 = ({});
                    for (const k3 in t) if (k3 !== "image") s2[k3] = t[k3];
                    s2.imageDropped = true;
                    return s2;
                });
                out[i] = c2;
                continue;
            }
            if (m.role !== "user") continue;
            userSeen++;
            const size = root._payloadSize(m);
            if (size === 0) continue;           // nothing here to strip
            if (userSeen <= root.persistedImageMessages
                    && (root._payloadFirst || size <= root._payloadLeft)) {
                root._payloadFirst = false;
                root._payloadLeft = Math.max(0, root._payloadLeft - size);
                continue;
            }
            const atts = m.attachments || [];
            let hasAttPayload = false;
            for (let j = 0; j < atts.length; j++) {
                const t = atts[j];
                if (t && ((t.b64 && t.b64.length > 0)
                          || (t.images && t.images.length > 0))) {
                    hasAttPayload = true;
                    break;
                }
            }
            if (out === a) out = a.slice();     // copy-on-first-strip
            const c = ({});
            for (const k in m) if (k !== "images") c[k] = m[k];
            if (hasAttPayload) {
                const na = [];
                for (let j = 0; j < atts.length; j++) {
                    const t = atts[j];
                    if (!t) continue;
                    const s = ({});
                    for (const k in t)
                        if (k !== "b64" && k !== "images") s[k] = t[k];
                    if ((t.b64 && t.b64.length > 0)
                        || (t.images && t.images.length > 0))
                        s.payloadDropped = true;
                    na.push(s);
                }
                c.attachments = na;
            }
            out[i] = c;
        }
        return out;
    }

    Timer {
        id: _writeTimer
        interval: 400
        repeat: false
        onTriggered: root._write()
    }

    function _schedule() {
        if (root._ingesting) return;            // reacting to the file, not changing it
        _writeTimer.restart();
    }

    function _write() {
        if (!root._dirReady) {
            // mkdir is still in flight. Come back rather than writing into a
            // directory that does not exist.
            _writeTimer.restart();
            return;
        }
        root._trim();
        const txt = root._serialize();
        if (txt === root._selfWriteText) return;
        root._selfWriteText = txt;
        root._pendingEchoes += 1;
        _file.setText(txt);
    }

    Process {
        id: _mkdir
        command: ["mkdir", "-p", root._dir]
        running: false
    }
    Connections {
        target: _mkdir
        // A Connections handler rather than an inline onExited, for the reason
        // Theme.qml records: qmllint cannot see QProcess::ExitStatus and
        // warns on every inline one. The exit code is not interesting — mkdir
        // -p on an existing directory succeeds, and a real failure surfaces on
        // the write.
        function onExited() { root._dirReady = true; }
    }

    Component.onCompleted: {
        _mkdir.running = true;
        // FileView loads asynchronously; `loaded` flips in _onText. A file that
        // does not exist yet never fires onLoaded, so an empty history is
        // declared usable here and corrected if a read does arrive.
        _readyTimer.restart();
    }

    Timer {
        id: _readyTimer
        interval: 250
        repeat: false
        onTriggered: root._loaded = true
    }
}
