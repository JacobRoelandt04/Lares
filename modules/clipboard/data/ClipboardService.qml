pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../../common/components"
import "../../common/components/JsonComments.js" as JsonComments
import "../../common/notify"
import "../../common/system"
import "ClipboardModel.js" as Model
import "ClipTransforms.js" as Trans

// =============================================================================
// ClipboardService.qml -- the clipboard history, live.
//
// The content talks to the members of CONTRACT.md's "Service API" and nothing
// else; ClipboardMock has the same members, so a mockup swaps one for the other.
//
// ONE WRITER. The store (index.json, blobs/, thumbs/) is written only by
// tools/clipboard/clip.py. The shell starts its watcher,
//     setpriv --pdeathsig TERM -- wl-paste --watch python3 clip.py ingest
// on a SupervisedStream, and every change on the clipboard comes back as ONE
// NDJSON event line on that stream. index.json is read once, at start (and after
// an import); from then on the events are the state. One-shot commands (pin,
// rename, keep, seal, delete, tag, prune) are their own processes and answer with
// the same events, applied by the same function.
//
// SECRETS never touch disk or argv. A sealed copy reaches the shell only as the
// base64 inside a `secret` event on the watcher's pipe; its text is held in a
// private map (`_secretText`), the public `secrets` list carries no bytes, and
// it goes back to the clipboard through wl-copy's STDIN with --sensitive. It is
// dropped at its expiry, at a lock (holds.locked), and when the source clears
// the clipboard (nil / clear / empty). Nothing here logs an event line.
//
// PASTE. wl-copy takes the bytes; the clipboard event
// that carries them back is our echo (a `tag` follows for an edit / transform
// / join, matched by its text, `_tagWait`). The key
// goes out only when the popup has let go of the keyboard (`hostOpen` false),
// `pasteDelayMs` later, and only if the active window is still the origin.
// WHAT IT WAITS FOR is wl-copy's own exit, not the echo: wl-copy forks into the
// background once the compositor has the selection, so its parent exiting 0 IS
// "the clipboard holds it" (`copied`). The echo takes the tool's whole ingest -- a
// python start, three programs, the store's lock -- and a key sent only
// after it would paste when the popup's close animation had finished.
// So the key follows the keyboard's release by the delay
// and one hyprctl, well inside the close:
// Wayland offers the clipboard only to the FOCUSED client, so a key sent to any
// other window pastes nothing. While the popup is up the active toplevel already
// IS the origin (a layer surface is not a toplevel), which is why hostOpen is
// needed at all. `hl.dsp.send_shortcut` first, `wtype` when it fails.
//
// SURVIVE CLOSE. On Wayland the clipboard empties when the app that owns it
// quits. Two compositors, two signals:
//   sway sends `nil` -- for `wl-copy --clear` as well, so the entry is offered
//     again only when the clipboard held exactly it, its source window is gone,
//     and it is not the watcher's first event (the watch fires once at start);
//   Hyprland 0.56 sends NOTHING (no nil for a dead source, none for --clear):
//     the clipboard is simply empty. Its `closewindow` for the held entry's
//     source window is the signal, and `wl-paste --list-types` must then find
//     the clipboard empty -- asked a few times, because the window can close a
//     moment before its process lets go of the clipboard, and an app that
//     closes one window of several still owns it.
// A secret is never re-offered.
//
// RESTORE AT START. A Wayland clipboard dies with its owner, so a fresh session
// starts with nothing on it and the last thing copied pastes as nothing until
// the user opens the shelf and picks it again. At start, once the
// index is read, `restoreLast()` asks `wl-paste --list-types`; an EMPTY
// clipboard gets the newest entry (never a sealed copy: those are RAM only);
// one that holds anything is left alone, so a shell restart in a running
// session never replaces what the user has copied since.
// =============================================================================
QtObject {
    id: root

    // ---- the contract's surface --------------------------------------------
    readonly property ListModel entries: rows
    property int serial: 0
    property var secrets: []
    readonly property bool hidden: !!root.holds && root.holds.screencast === true
    property bool ready: false
    property string error: ""
    property var origin: null
    property bool hostOpen: false
    readonly property string stateDir: root._stateDir

    // ---- wiring (a probe overrides these) ----------------------------------
    property bool enabled: true
    property string python: "python3"
    property string toolPath: RepoRoot.dir + "/tools/clipboard/clip.py"
    // "" = the tool's own rule (CLIP_STATE, XDG_STATE_HOME, ~/.local/state).
    property string stateOverride: ""
    property string configOverride: ""
    // The lock / screencast holds the notifications already read (one watcher,
    // not two). A probe hands in its own { locked, screencast }.
    property var holds: NotificationBus.service ? NotificationBus.service.holds : null
    // false: Hyprland is never touched; the active window and the toplevels
    // come from the two fakes below.
    property bool live: true
    property string fakeActiveAddress: ""
    property var fakeAddresses: []
    // How long a delete can be undone: the header offers Undo for exactly this long.
    property int undoWindowMs: Math.round(root._cfg(["undoSec"], 8) * 1000)
    // Offer the newest entry when the clipboard is empty at start (RESTORE AT START). A probe that
    // counts the watcher's first events turns it off.
    property bool restoreOnStart: root._cfg(["restoreAtStart"], true)

    // Diagnostics a probe reads.
    property int reoffers: 0
    property int restores: 0
    property string lastDispatch: ""

    // ---- config (clip.py config: the only source of defaults; asked again when the file changes) ---------
    property var config: ({})
    readonly property real ttlS: root._cfg(["secrets", "ttlS"], 120)
    readonly property var pasteKeys: root._cfg(["pasteKeys"], {})
    readonly property bool openOverFullscreen: root._cfg(["openOverFullscreen"], true)
    // What the popup does with them (Model.PREFS names the keys).
    readonly property var prefs: {
        const o = {};
        for (const k in Model.PREFS)
            o[k] = root._cfg([k], Model.PREFS[k]);
        return o;
    }

    function _cfg(path, def) {
        let o = root.config;
        for (let i = 0; i < path.length; i++) {
            if (o === null || typeof o !== "object" || !(path[i] in o))
                return def;
            o = o[path[i]];
        }
        return o === undefined || o === null ? def : o;
    }

    // ---- private state -----------------------------------------------------
    property string _stateDir: ""
    property bool _watching: false
    property bool _firstEvent: true
    // What the clipboard holds as far as the events say: an entry id, "secret", or "".
    property string _held: ""
    property var _state: Model.newState()
    property var _secretText: ({})
    property int _n: 0
    property var _removed: []         // [{ rec }] removed from the view, not yet from disk
    property var _pending: null       // the paste in flight (waiting for its key)
    property var _tagWait: null       // { text, tag, until }: the echo of an edit / transform / join, to be tagged
    property string _lastErrorShown: ""

    property ListModel _rows: ListModel {
        id: rows
    }
    property Component _recComp: Component {
        id: recComp
        QtObject {
            property var d: ({})
        }
    }

    // ---- events ------------------------------------------------------------
    function _mirror(ops) {
        for (let i = 0; i < ops.length; i++) {
            const o = ops[i];
            if (o.op === "insert")
                rows.insert(o.index, { key: o.rec.id, rec: recComp.createObject(root, { d: o.rec }) });
            else if (o.op === "set")
                rows.get(o.index).rec.d = o.rec;
            else if (o.op === "move")
                rows.move(o.from, o.to, 1);
            else if (o.op === "remove")
                rows.remove(o.index, 1);
        }
        root.serial++;
    }

    function _apply(ev) {
        const r = Model.applyEvent(root._state, ev);
        if (r.changed)
            root._mirror(r.ops);
    }

    function _onLine(text, fromWatcher) {
        if (String(text).trim() === "")
            return;
        let ev = null;
        try {
            ev = JSON.parse(text);
        } catch (e) {
            root._fail("the tool printed a line that is not JSON");     // never the line itself
            return;
        }
        if (!ev || typeof ev.ev !== "string")
            return;
        const first = fromWatcher && root._firstEvent;
        if (fromWatcher)
            root._firstEvent = false;
        switch (ev.ev) {
        case "add":
        case "bump":
            if (fromWatcher)
                root._held = ev.ev === "add" ? String(ev.entry.id) : String(ev.id);
            root._unremoveOnCopy(ev);
            root._apply(ev);
            if (fromWatcher)
                root._echo(ev);
            break;
        case "update":
        case "remove":
            root._apply(ev);
            break;
        case "secret":
            if (fromWatcher)
                root._held = "secret";
            root._onSecret(ev);
            if (fromWatcher)
                root._echo(ev);
            break;
        case "nil":
            root._sourceCleared();
            if (!first)
                root._maybeReoffer();
            root._held = "";
            break;
        case "clear":
        case "empty":
            root._sourceCleared();
            root._held = "";
            break;
        case "error":
            root._fail(String(ev.msg || "the tool failed"));
            break;
        case "import":
            root._loadIndex();
            break;
        case "config":
            root._applyConfig(ev);
            break;
        case "skip":
            if (fromWatcher && ev.why === "ignored")
                root._held = "";        // an ignored app's copy is on the clipboard: none of ours to put back
            break;
        default:
            break;
        }
    }

    function _fail(msg) {
        root.error = msg;
        if (msg !== root._lastErrorShown) {
            root._lastErrorShown = msg;
            console.warn("ClipboardService: " + msg);
        }
    }

    // ---- start -------------------------------------------------------------
    function _env() {
        const e = {};
        if (root.stateOverride !== "")
            e.CLIP_STATE = root.stateOverride;
        if (root.configOverride !== "")
            e.CLIP_CONFIG = root.configOverride;
        return e;
    }

    function _applyConfig(ev) {
        root.config = ev.config || {};
        if (root._stateDir === "") {
            root._stateDir = String(ev.stateDir || "");
            root._loadIndex();
            root._watching = true;
            root._tool(["prune"], "");
            root.ready = true;
            if (root.restoreOnStart)
                root.restoreLast();
        }
    }

    readonly property string _configPath: root.configOverride !== "" ? root.configOverride
        : (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/quickshell/config/clipboard.jsonc"
    property ConfigFile _file: ConfigFile {
        id: configFile
        path: root._configPath
        watchChanges: root.enabled
        onLoaded: root._fileRead()
        onLoadFailed: root._fileRead()
    }
    property string _fileText: ""
    property bool _fileSeen: false
    // A change of the file: the tool says what it comes to. A text that does not parse keeps what stands.
    function _fileRead() {
        const t = configFile.text();
        const changed = root._fileSeen && t !== root._fileText;
        root._fileSeen = true;
        root._fileText = t;
        if (!changed || root._stateDir === "")
            return;
        try {
            if (t.trim() !== "")
                JSON.parse(JsonComments.strip(t));
        } catch (e) {
            return;
        }
        root._tool(["config"], "");
    }

    property FileView _index: FileView {
        id: indexFile
        path: root._stateDir === "" ? "" : root._stateDir + "/index.json"
        blockLoading: true
        blockAllReads: true
        printErrors: false
        watchChanges: false
    }

    function _loadIndex() {
        indexFile.reload();
        const text = indexFile.text();
        let entries = [];
        if (text && text.trim() !== "") {
            try {
                const doc = JSON.parse(text);
                entries = Array.isArray(doc.entries) ? doc.entries : [];
            } catch (e) {
                root._fail("index.json is unreadable; the tool keeps a .corrupt copy at its next write");
            }
        }
        const r = Model.reset(root._state, entries);
        rows.clear();
        for (let i = 0; i < r.order.length; i++)
            rows.append({ key: r.order[i], rec: recComp.createObject(root, { d: r.byId[r.order[i]] }) });
        root.serial++;
    }

    property SupervisedStream _watcher: SupervisedStream {
        enabled: root.enabled && root._watching
        what: "ClipboardService: the clipboard watcher"
        command: {
            const env = root._env();
            const pre = ["setpriv", "--pdeathsig", "TERM", "--"];
            const vars = Object.keys(env).map(k => k + "=" + env[k]);
            return pre.concat(vars.length > 0 ? ["env"].concat(vars) : [])
                      .concat(["wl-paste", "--watch", root.python, root.toolPath, "ingest"]);
        }
        onLine: text => root._onLine(text, true)
        onExited: (code, expected) => root._firstEvent = true
    }

    // ---- processes ---------------------------------------------------------
    property Component _procComp: Component {
        id: procComp
        Process {
            id: proc
            property string feedText: ""
            property var onEventLine: null
            property var onDone: null
            stdout: SplitParser {
                onRead: data => {
                    const parts = String(data).split("\n");
                    for (let i = 0; i < parts.length; i++)
                        if (proc.onEventLine)
                            proc.onEventLine(parts[i]);
                }
            }
            onStarted: {
                if (proc.feedText !== "") {
                    proc.write(proc.feedText);
                    proc.feedText = "";
                }
                proc.stdinEnabled = false;          // the EOF (CLAUDE.md: a child reading stdin hangs without it)
            }
            // A Connections handler rather than an inline onExited: qmllint cannot
            // see QProcess::ExitStatus (Theme.qml does the same).
            property Connections _exit: Connections {
                target: proc
                function onExited(code) {
                    if (proc.onDone)
                        proc.onDone(code);
                    proc.destroy();
                }
            }
        }
    }

    function _spawn(command, feedText, onEventLine, onDone) {
        const p = procComp.createObject(root, {
            command: command,
            environment: root._env(),
            feedText: feedText || "",
            onEventLine: onEventLine || null,
            onDone: onDone || null
        });
        p.stdinEnabled = true;
        p.running = true;
        return p;
    }

    function _tool(args, feedText) {
        return root._spawn([root.python, root.toolPath].concat(args), feedText,
                           line => root._onLine(line, false), null);
    }

    // ---- secrets -----------------------------------------------------------
    function _onSecret(ev) {
        const text = Trans.utf8FromBase64(ev.b64 || "");
        if (text === null || text === "")
            return;         // not text: nothing the shell can hold or paste back faithfully
        for (const k in root._secretText)
            if (root._secretText[k] === text)
                return;     // our own paste of it coming back, or the same copy twice
        root._addSecret(text, String(ev.mime || "text/plain;charset=utf-8"), String(ev.reason || "hint"),
                        ev.source || { cls: "", title: "" });
    }

    function _addSecret(text, mime, reason, source) {
        const now = Date.now();
        const key = "s" + (++root._n);
        root._secretText[key] = text;
        root._setSecrets(root.secrets.concat([{
                    key: key,
                    mime: mime,
                    reason: reason,
                    source: source,
                    t: now,
                    expiresAt: now + root.ttlS * 1000
                }]));
    }

    function _setSecrets(list) {
        const keep = {};
        for (let i = 0; i < list.length; i++)
            keep[list[i].key] = true;
        for (const k in root._secretText)
            if (keep[k] !== true)
                delete root._secretText[k];
        root.secrets = list;
        root.serial++;
        root._rearm();
    }

    function _rearm() {
        if (root.secrets.length === 0) {
            expiry.stop();
            return;
        }
        let next = root.secrets[0].expiresAt;
        for (let i = 1; i < root.secrets.length; i++)
            next = Math.min(next, root.secrets[i].expiresAt);
        expiry.interval = Math.max(1, next - Date.now());
        expiry.restart();
    }

    property Timer _expiry: Timer {
        id: expiry
        repeat: false
        onTriggered: {
            const now = Date.now();
            root._setSecrets(root.secrets.filter(s => s.expiresAt > now));
        }
    }

    function _sourceCleared() {
        if (root._cfg(["secrets", "dropOnSourceClear"], true) && root.secrets.length > 0)
            root._setSecrets([]);
    }

    readonly property bool _locked: !!root.holds && root.holds.locked === true
    on_LockedChanged: {
        if (root._locked && root._cfg(["secrets", "dropOnLock"], true) && root.secrets.length > 0)
            root._setSecrets([]);
    }

    function dropSecret(key) {
        root._setSecrets(root.secrets.filter(s => s.key !== key));
    }

    function revealSecret(key) {
        const t = root._secretText[key];
        return t === undefined ? "" : t;
    }

    // An entry becomes a sealed copy: its text is taken BEFORE the tool deletes it.
    function seal(id) {
        const rec = root._state.byId[id];
        if (rec === undefined || !root._isPlainText(rec))
            return;
        root._addSecret(rec.text, "text/plain;charset=utf-8", "manual", rec.source || { cls: "", title: "" });
        root._tool(["seal", id], "");
    }

    // A sealed copy the user decided is not a secret: stored like any copy.
    function keep(secretKey) {
        const text = root._secretText[secretKey];
        if (text === undefined)
            return;
        const sec = root.secrets.filter(s => s.key === secretKey)[0];
        const src = sec && sec.source ? sec.source : { cls: "", title: "" };
        root.dropSecret(secretKey);
        root._tool(["keep", "--mime", "text/plain;charset=utf-8", "--source-cls", String(src.cls || ""),
                    "--source-title", String(src.title || ""), "--via", "copy"], text);
    }

    // ---- the verbs ---------------------------------------------------------
    function pin(id, on) {
        if (root._state.byId[id] !== undefined)
            root._tool([on === true ? "pin" : "unpin", id], "");
    }

    function rename(id, title) {
        if (root._state.byId[id] !== undefined)
            root._tool(["rename", id, String(title)], "");
    }

    // Removed from the view at once, from disk when the undo window has passed
    // (or the popup closed): the tool's delete takes the blob with it.
    function remove(id) {
        const rec = root._state.byId[id];
        if (rec === undefined)
            return;
        root._removed = root._removed.concat([{ rec: rec }]);
        root._apply({ ev: "remove", ids: [id], why: "delete" });
        commitTimer.interval = root.undoWindowMs;
        commitTimer.restart();
    }

    function undoRemove() {
        if (root._removed.length === 0)
            return;
        const last = root._removed[root._removed.length - 1];
        root._removed = root._removed.slice(0, -1);
        root._apply({ ev: "add", entry: last.rec });
    }

    function _commitRemovals() {
        commitTimer.stop();
        const ids = root._removed.map(r => r.rec.id);
        root._removed = [];
        if (ids.length > 0)
            root._tool(["delete"].concat(ids), "");
    }

    // A copy of something whose removal is still pending brings it back.
    function _unremoveOnCopy(ev) {
        const id = ev.ev === "add" ? String(ev.entry.id) : String(ev.id);
        const at = root._removed.findIndex(r => r.rec.id === id);
        if (at < 0)
            return;
        const rec = root._removed[at].rec;
        root._removed = root._removed.filter((r, i) => i !== at);
        if (ev.ev === "bump")
            root._apply({ ev: "add", entry: Object.assign({}, rec, { last: ev.last, uses: ev.uses }) });
    }

    property Timer _commitTimer: Timer {
        id: commitTimer
        repeat: false
        onTriggered: root._commitRemovals()
    }

    onHostOpenChanged: {
        // The paste in flight starts its delay at the release itself, not at the next 30 ms tick.
        if (!root.hostOpen && root._pending !== null && root._pending.closedAt === 0)
            root._pending.closedAt = Date.now();
        if (!root.hostOpen && root._removed.length > 0)
            root._commitRemovals();
    }

    function transforms(id) {
        const rec = root._state.byId[id];
        return rec === undefined ? [] : Trans.available(rec);
    }

    function transform(id, name) {
        const rec = root._state.byId[id];
        return rec === undefined ? "" : Trans.apply(name, rec.text);
    }

    // ---- paste ---------------------------------------------------------------
    function _isPlainText(rec) {
        return (rec.kind === "text" || rec.kind === "code" || rec.kind === "link" || rec.kind === "colour")
               && rec.truncated !== true;
    }

    // What goes on the clipboard for `keys`: { text, sensitive } or { file, mime }, or null.
    function _payload(keys, o) {
        let sensitive = false;
        for (let i = 0; i < keys.length; i++)
            if (root._secretText[keys[i]] !== undefined)
                sensitive = true;
        if (o.text !== undefined && o.text !== null)
            return { text: String(o.text), sensitive: sensitive };
        if (keys.length === 1) {
            const k = keys[0];
            if (root._secretText[k] !== undefined)
                return { text: root._secretText[k], sensitive: true };
            const rec = root._state.byId[k];
            if (rec === undefined)
                return null;
            if (root._isPlainText(rec))
                return { text: rec.text, sensitive: false };
            if (!rec.blob || root._stateDir === "")
                return null;
            const textKind = rec.kind === "text" || rec.kind === "code" || rec.kind === "link" || rec.kind === "colour";
            return { file: root._stateDir + "/blobs/" + rec.blob, mime: textKind ? "" : String(rec.mime) };
        }
        const texts = [];
        for (let i = 0; i < keys.length; i++) {
            const k = keys[i];
            if (root._secretText[k] !== undefined)
                texts.push(root._secretText[k]);
            else if (root._state.byId[k] !== undefined && root._isPlainText(root._state.byId[k]))
                texts.push(root._state.byId[k].text);
        }
        return texts.length === 0 ? null : { text: Model.join(texts, o.joiner), sensitive: sensitive };
    }

    function _copyCommand(p) {
        if (p.file !== undefined)
            return p.mime === "" ? ["sh", "-c", "exec wl-copy < \"$1\"", "sh", p.file]
                                 : ["sh", "-c", "exec wl-copy --type \"$1\" < \"$2\"", "sh", p.mime, p.file];
        return p.sensitive ? ["wl-copy", "--sensitive"] : ["wl-copy"];
    }

    function paste(keys, opts) {
        const o = opts || {};
        const p = root._payload(keys || [], o);
        if (p === null)
            return;
        const via = o.via || ((keys || []).length > 1 ? "join" : "copy");
        const pend = {
            mode: o.mode === "copy" ? "copy" : "paste",
            tag: (via === "edit" || via === "transform" || via === "join") ? via : "",
            origin: root.origin ? { address: root._addr(root.origin.address), cls: String(root.origin.cls || "") } : null,
            started: Date.now(),
            // wl-copy has exited 0: the compositor holds the selection (see PASTE)
            copied: false,
            // when the popup let go of the keyboard (0 while it holds it)
            closedAt: root.hostOpen ? 0 : Date.now(),
            asking: false
        };
        root._pending = pend;
        // The tag waits for the echo on its own, not on the key: the key does not wait for the echo.
        root._tagWait = pend.tag === "" ? null : {
            text: p.text !== undefined ? String(p.text) : null,
            tag: pend.tag,
            until: Date.now() + 5000
        };
        root._spawn(root._copyCommand(p), p.text !== undefined ? p.text : "", null, code => {
            if (code !== 0) {
                if (root._pending === pend)
                    root._pending = null;
                root._fail("wl-copy failed (" + code + ")");
            } else {
                pend.copied = true;
            }
        });
        pasteTick.start();
    }

    // The echo of an edit / transform / join is the `add` that CARRIES ITS TEXT: a paste is tagged
    // `via edit` / `transform` / `join` so the card says where it came from. Order alone is not enough --
    // the previous paste's late echo can arrive after the next one began (the key does not wait for it).
    function _echo(ev) {
        const t = root._tagWait;
        if (t === null || ev.ev !== "add")
            return;
        if (Date.now() > t.until) {
            root._tagWait = null;
            return;
        }
        const rec = ev.entry;
        if (t.text !== null && !(rec.truncated === true ? t.text.indexOf(rec.text) === 0 : rec.text === t.text))
            return;                             // another copy's event: not ours
        root._tagWait = null;
        root._tool(["tag", String(rec.id), t.tag], "");
    }

    function _addr(a) {
        const s = String(a || "").toLowerCase();
        if (s === "")
            return "";
        return s.indexOf("0x") === 0 ? s : "0x" + s;
    }

    // The focused window, asked of Hyprland at the moment the key would go out -- one authoritative read,
    // not a cached property. (An address alone names a window only while it lives: Hyprland reuses a
    // closed window's address for the next one.)
    function _askActive(done) {
        if (!root.live) {
            done(root._addr(root.fakeActiveAddress));
            return;
        }
        let text = "";
        root._spawn(["hyprctl", "-j", "activewindow"], "", line => text += line, code => {
            let addr = "";
            try {
                addr = code === 0 ? root._addr(JSON.parse(text).address) : "";
            } catch (e) {
                addr = "";
            }
            done(addr);
        });
    }

    function _addressAlive(addr) {
        if (!root.live)
            return (root.fakeAddresses || []).map(x => root._addr(x)).indexOf(addr) >= 0;
        const list = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (let i = 0; i < list.length; i++)
            if (root._addr(list[i].address) === addr)
                return true;
        return false;
    }

    // Lua is built from config words: only letters, digits, space and _ pass.
    function _shortcutExpr(spec, addr) {
        const at = spec.lastIndexOf(",");
        const mods = (at < 0 ? "" : spec.slice(0, at)).replace(/[^A-Za-z0-9_ ]/g, "").trim();
        let key = (at < 0 ? spec : spec.slice(at + 1)).replace(/[^A-Za-z0-9_]/g, "");
        if (key.length === 1)
            key = key.toLowerCase();          // an xkb keysym name: "v", not "V" (0.md)
        return { mods: mods, key: key,
                 expr: "hl.dsp.send_shortcut({ mods = \"" + mods + "\", key = \"" + key
                       + "\", window = \"address:" + addr.replace(/[^0-9a-fx]/g, "") + "\" })" };
    }

    function _send(p) {
        const sc = root._shortcutExpr(Model.pasteKeyFor(p.origin.cls, root.pasteKeys), p.origin.address);
        root.lastDispatch = sc.expr;
        let answer = "";
        root._spawn(["hyprctl", "dispatch", sc.expr], "", line => {
            if (line.trim() !== "")
                answer = line.trim();
        }, code => {
            if (code === 0 && answer === "ok")
                return;
            // send_shortcut refused (no such key in the keymap, an old Hyprland): type it.
            const m = sc.mods.split(/\s+/).filter(x => x !== "").map(x => ({ CTRL: "ctrl", CONTROL: "ctrl", SHIFT: "shift",
                                                                             ALT: "alt", SUPER: "logo" })[x.toUpperCase()] || "");
            let cmd = ["wtype"];
            m.forEach(x => { if (x !== "") cmd = cmd.concat(["-M", x]); });
            cmd.push(sc.key);
            m.slice().reverse().forEach(x => { if (x !== "") cmd = cmd.concat(["-m", x]); });
            root.lastDispatch = cmd.join(" ");
            root._spawn(cmd, "", null, null);
        });
    }

    property Timer _pasteTick: Timer {
        id: pasteTick
        interval: 30
        repeat: true
        onTriggered: {
            const p = root._pending;
            const now = Date.now();
            if (p === null) {
                pasteTick.stop();
                return;
            }
            const waited = now - p.started;
            if (!p.copied && waited < 1500)
                return;                         // the clipboard does not hold it yet
            if (p.mode !== "paste" || p.origin === null || p.origin.address === "") {
                root._pending = null;
                return;
            }
            if (root.hostOpen) {
                p.closedAt = 0;
                if (waited > 15000)
                    root._pending = null;       // the popup stayed open: nothing to paste into
                return;
            }
            if (p.closedAt === 0)
                p.closedAt = now;
            if (now - p.closedAt < root._cfg(["pasteDelayMs"], 120))
                return;
            if (p.asking)
                return;
            p.asking = true;
            root._askActive(addr => {
                p.asking = false;
                if (root._pending !== p)
                    return;                     // replaced, or given up, meanwhile
                if (addr !== p.origin.address) {
                    if (Date.now() - p.closedAt > 1000)
                        root._pending = null;   // focus went elsewhere: the clipboard holds it, no key
                    return;
                }
                root._pending = null;
                root._send(p);
            });
        }
    }

    // ---- survive close -----------------------------------------------------
    // The entry the clipboard holds as far as the events say, and the window it
    // came from; null when it holds a secret, nothing, or something unknown.
    function _heldEntry() {
        if (!root._cfg(["reofferOnClose"], true) || root._pending !== null)
            return null;
        const rec = root._held === "" || root._held === "secret" ? undefined : root._state.byId[root._held];
        if (rec === undefined)
            return null;
        const addr = root._addr(rec.source ? rec.source.address : "");
        return addr === "" ? null : { rec: rec, addr: addr };
    }

    // An entry onto the clipboard with no paste behind it. False when it cannot be (a secret, an
    // entry with nothing to put back).
    function _offer(rec) {
        const p = root._payload([rec.id], {});
        if (p === null || p.sensitive)
            return false;
        root._spawn(root._copyCommand(p), p.text !== undefined ? p.text : "", null, null);
        return true;
    }

    function _reoffer(rec) {
        if (root._offer(rec))
            root.reoffers++;
    }

    // RESTORE AT START: the newest entry goes back on an EMPTY clipboard. The check is the clipboard's
    // own answer, taken now; a copy that arrived meanwhile (`_held`) wins over it.
    function restoreLast() {
        const id = root._state.order.length > 0 ? root._state.order[0] : "";
        if (id === "")
            return;
        let types = 0;
        root._spawn(["wl-paste", "--list-types"], "", line => {
            if (line.trim() !== "")
                types++;
        }, code => {
            if (code === 0 && types > 0)
                return;                         // it holds something: not ours to replace
            const rec = root._state.byId[id];
            if (rec === undefined || root._held !== "" || root._state.order[0] !== id)
                return;                         // something else was copied, or the entry went, meanwhile
            if (root._offer(rec))
                root.restores++;
        });
    }

    // sway: `nil` -- the clipboard is empty; it was a closed app only if the window is gone.
    function _maybeReoffer() {
        const h = root._heldEntry();
        if (h !== null && root._state.order[0] === h.rec.id && !root._addressAlive(h.addr))
            root._reoffer(h.rec);
    }

    // Hyprland: a window closed. If it was the held entry's source and the clipboard is now empty, the
    // app took it with it.
    function windowClosed(address) {
        const h = root._heldEntry();
        if (h === null || root._addr(String(address).split(",")[0]) !== h.addr)
            return;
        root._askEmpty(h.rec.id, [150, 600, 1500], 0);
    }

    function _askEmpty(id, delays, i) {
        if (i >= delays.length)
            return;
        root._later(delays[i] - (i > 0 ? delays[i - 1] : 0), () => {
            if (root._held !== id)
                return;                         // something else was copied meanwhile
            let types = 0;
            root._spawn(["wl-paste", "--list-types"], "", line => {
                if (line.trim() !== "")
                    types++;
            }, code => {
                if (root._held !== id)
                    return;
                if (code !== 0 || types === 0)
                    root._reoffer(root._state.byId[id]);
                else
                    root._askEmpty(id, delays, i + 1);
            });
        });
    }

    property Component _laterComp: Component {
        id: laterComp
        Timer {
            id: later
            property var fn: null
            repeat: false
            running: true
            onTriggered: {
                if (later.fn)
                    later.fn();
                later.destroy();
            }
        }
    }
    function _later(ms, fn) {
        laterComp.createObject(root, { interval: Math.max(0, ms), fn: fn });
    }

    property Connections _hyprEvents: Connections {
        target: root.live ? Hyprland : null
        function onRawEvent(event) {
            if (event.name === "closewindow")
                root.windowClosed(event.data);
        }
    }

    // ---- housekeeping --------------------------------------------------------
    property Timer _pruneTimer: Timer {
        interval: 6 * 3600 * 1000
        repeat: true
        running: root.ready && root.enabled
        onTriggered: root._tool(["prune"], "")
    }

    function _start() {
        // wl-paste is checked first: a Process whose program is missing emits nothing (CLAUDE.md).
        root._spawn(["sh", "-c", "command -v wl-paste >/dev/null 2>&1 || { echo NOWLPASTE; exit 9; }; exec \"$0\" \"$1\" config",
                     root.python, root.toolPath], "", line => {
            if (line.trim() === "NOWLPASTE")
                root._fail("wl-paste is not installed (wl-clipboard)");
            else
                root._onLine(line, false);
        }, code => {
            if (code !== 0 && code !== 9)
                root._fail("clip.py config failed (" + code + ")");
        });
    }

    Component.onCompleted: {
        if (root.enabled)
            root._start();
    }
}
