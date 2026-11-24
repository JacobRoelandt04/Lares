pragma ComponentBehavior: Bound

import QtQuick
import "../../common/notify"
import "ClipboardModel.js" as Model
import "ClipTransforms.js" as Trans

// =============================================================================
// ClipboardMock.qml -- the clipboard service without a watcher, a store or a
// compositor.
//
// The SAME members as ClipboardService (docs/contracts/clipboard.md,
// "Service API"): the content takes ONE `service` and nothing
// above it changes when the mock is swapped for the real one. Ranking, the
// event reducer, the pick-order join and the transforms are the very
// functions the real service runs (ClipboardModel.js, ClipTransforms.js).
//
//   entries   ListModel, newest first. Roles `key` (the record id) and `rec`,
//             a QtObject { property var d } kept by POINTER (the launcher's and
//             the notifications' mirror): `rec.d` is the record; a bump or an
//             update REPLACES `d`, a reorder is a ListModel move, and `serial`
//             is bumped on every write -- the only thing a binding can watch
//             for a move.
//   secrets   [{ key, mime, reason, source, t, expiresAt }] -- never the bytes
//
// The mock's own knobs (nothing in the contract):
//   feed(kind)       a new copy: "text" "code" "link" "colour" "image" "files"
//                    "secret" (app-sealed) "heuristic" (detector-sealed)
//   fire(state)      "nil" | "clear" | "empty": every one drops the sealed
//                    copies (dropOnSourceClear); only "nil" re-offers the top
//                    entry (`reoffers` counts them), as the real service does
//   setLocked(b)     a lock drops the sealed copies (dropOnLock); the notifications' holds.locked calls it, as the real
//                    service follows the same holds
//   setScreencast(b) `hidden` follows it
//   ttlS             a sealed copy's life (default 120 s, as the config)
//   lastPaste        { keys, mode, text, joined, via, pasteKey } of the last
//                    paste(); nothing touches a clipboard
// =============================================================================
QtObject {
    id: root

    // ---- the contract's surface --------------------------------------------
    readonly property ListModel entries: rows
    property int serial: 0
    property var secrets: []
    readonly property bool hidden: root.screencast
    property bool ready: false
    property string error: ""
    property var origin: ({ address: "0x55d0c2a1b2c0", cls: "firefox" })
    property int undoWindowMs: 8000
    property bool openOverFullscreen: true
    property var prefs: Model.PREFS
    // Written by the owner: true while the popup is open (the real service
    // sends the paste key only after it turns false; nothing here uses it).
    property bool hostOpen: false
    // Where thumbs and blobs live (the real service's resolved state dir). The mock's is the repo's
    // fixtures/ (thumbs/ there holds a few real, tiny WebP thumbnails cut the way the store cuts them).
    property string stateDir: String(Qt.resolvedUrl("fixtures")).replace(/^file:\/\//, "")

    // ---- the mock's own ----------------------------------------------------
    property real ttlS: 120
    property bool locked: false
    property bool screencast: false
    // The notifications' holds, as the real service reads them (ClipboardService.holds): a LOCKED session drops the sealed copies.
    // A mockup has none (no service on the bus): `setLocked` is its own switch.
    property var holds: NotificationBus.service ? NotificationBus.service.holds : null
    readonly property bool _heldLocked: !!root.holds && root.holds.locked === true
    on_HeldLockedChanged: root.setLocked(root._heldLocked)
    property int reoffers: 0
    property string lastState: ""
    property var lastPaste: null
    property var pasteKeys: ({
            "default": "CTRL,V",
            "classes": {
                "kitty": "CTRL SHIFT,V",
                "foot": "CTRL SHIFT,V",
                "Alacritty": "CTRL SHIFT,V",
                "org.wezfurlong.wezterm": "CTRL SHIFT,V",
                "com.mitchellh.ghostty": "CTRL SHIFT,V"
            }
        })

    property var _state: Model.newState()
    property var _secretText: ({})
    property var _removed: []
    property int _n: 0
    property double _t0: Date.now()

    // ------------------------------------------------------------- the model
    property ListModel _rows: ListModel {
        id: rows
    }

    property Component _recComp: Component {
        id: recComp
        QtObject {
            property var d: ({})
        }
    }

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

    // The tool's event, as the real service would receive it.
    function _event(ev) {
        const r = Model.applyEvent(root._state, ev);
        if (r.changed)
            root._mirror(r.ops);
        return r.changed;
    }

    // ------------------------------------------------------------- records
    function _id(s) {
        let a = 0x811c9dc5, b = 0x01000193;
        for (let i = 0; i < s.length; i++) {
            a = Math.imul(a ^ s.charCodeAt(i), 0x01000193) >>> 0;
            b = Math.imul(b + s.charCodeAt(i), 0x85ebca6b) >>> 0;
        }
        return ("00000000" + a.toString(16)).slice(-8) + ("00000000" + b.toString(16)).slice(-8);
    }

    function _src(cls, title) {
        return { cls: cls, title: title, address: "0x55d0c2a1" + ("0000" + (cls.length * 777).toString(16)).slice(-4) };
    }

    function _make(kind, text, agoS, o) {
        const x = o || {};
        const now = Date.now();
        const bytes = text.length;
        const last = now - agoS * 1000;
        return {
            id: root._id(kind + ":" + text + ":" + (x.w || 0) + "x" + (x.h || 0) + ":" + (x.bytes || 0)),
            kind: kind,
            mime: kind === "image" ? "image/png" : (kind === "files" ? "text/uri-list" : "text/plain;charset=utf-8"),
            types: kind === "image" ? ["image/png"] : (kind === "files" ? ["text/uri-list"] : ["text/plain;charset=utf-8", "text/plain", "UTF8_STRING"]),
            text: text,
            truncated: x.truncated === true,
            blob: kind === "image" || x.truncated === true ? "blob.bin" : null,
            thumb: x.thumb === undefined ? null : x.thumb,
            bytes: x.bytes !== undefined ? x.bytes : bytes,
            lines: text.length === 0 ? 0 : text.split("\n").length,
            w: x.w || 0,
            h: x.h || 0,
            source: x.source || root._src("firefox", "Mozilla Firefox"),
            via: x.via || "copy",
            first: last,
            last: last,
            uses: x.uses || 1,
            pinned: x.pinned === true,
            title: x.title || ""
        };
    }

    // The image fixtures: real thumbnails in fixtures/thumbs/ (the store's own format, WebP, 320 px) and the
    // size of the picture they stand for.
    readonly property var _pics: [
        { thumb: "fx-light.webp", w: 1440, h: 810, bytes: 482113 },
        { thumb: "fx-dark.webp", w: 1440, h: 810, bytes: 455920 },
        { thumb: "fx-wall0.webp", w: 3840, h: 2160, bytes: 1210334 },
        { thumb: "fx-wall1.webp", w: 3840, h: 2160, bytes: 2390112 },
        { thumb: "fx-wall2.webp", w: 3840, h: 2096, bytes: 2810447 }
    ]

    function _fixtures() {
        const kitty = root._src("kitty", "user@host: ~/.config/quickshell");
        const code = root._src("code", "ClipboardModel.js");
        const long = "The clipboard keeps what you copied, so that a later paste does not depend on the window you copied from still being open. ".repeat(14).trim();
        return [
            root._make("text", "See you at the station at 18:40, platform 3.", 20),
            root._make("link", "https://www.youtube.com/watch?v=dQw4w9WgXcQ&utm_source=newsletter&utm_medium=email&fbclid=IwAR0abc#t=43", 90, { source: root._src("firefox", "Mozilla Firefox") }),
            root._make("code", "function bump(state, id) {\n    const at = state.order.indexOf(id);\n    state.order.splice(at, 1);\n    state.order.unshift(id);\n}", 300, { source: code }),
            root._make("colour", "#4480F4", 540, { source: root._src("gimp", "Colors") }),
            root._make("colour", "rgb(236, 237, 245)", 700, { source: root._src("gimp", "Colors") }),
            root._make("image", "", 900, Object.assign({ source: root._src("grim", "screenshot") }, root._pics[0])),
            root._make("files", "file:///home/user/Documents/Tax%202025.pdf\nfile:///home/user/Pictures/holiday.jpg", 1500, { source: root._src("thunar", "Documents") }),
            root._make("text", "user@example.com", 2400, { pinned: true, title: "My email", uses: 14 }),
            root._make("text", "git log --oneline --graph --all -n 20", 3600, { source: kitty, uses: 3 }),
            root._make("link", "https://quickshell.org/docs/v0.3.1/types/Quickshell.Io/Process/", 5400),
            root._make("code", "{\"version\":1,\"entries\":[{\"id\":\"a1b2\",\"kind\":\"text\"}]}", 7200, { source: code }),
            root._make("text", long, 9000, { truncated: false, source: root._src("obsidian", "Notes")}),
            root._make("text", "Dear Sir or Madam,\n\nI am writing to ask about the invoice dated 2 October.\n\nKind regards,\nSam", 20000),
            root._make("image", "", 4500, Object.assign({ source: root._src("grim", "screenshot") }, root._pics[1])),
            root._make("image", "", 12000, Object.assign({ source: root._src("firefox", "Mozilla Firefox") }, root._pics[3])),
            // Past the thumbnail limit: the store kept the blob and dropped the thumb, the card shows its placeholder.
            root._make("image", "", 30000, { w: 640, h: 640, bytes: 91012, source: root._src("firefox", "Mozilla Firefox") }),
            root._make("link", "https://archlinux.org/packages/?sort=&q=wl-clipboard", 90000, { pinned: true, title: "wl-clipboard package", source: root._src("firefox", "Mozilla Firefox") }),
            root._make("text", "TODO: ask about the lockscreen camera", 200000, { source: root._src("obsidian", "Notes") })
        ];
    }

    // ------------------------------------------------------------- feed / fire
    function feed(kind) {
        const n = ++root._n;
        const src = root._src("firefox", "Mozilla Firefox");
        if (kind === "secret" || kind === "heuristic") {
            root._addSecret(kind === "secret" ? "Correct-Horse-Battery-" + n : "ghp_" + root._id("tok" + n) + "ABCD" + n,
                            kind === "secret" ? "app" : "heuristic",
                            kind === "secret" ? root._src("Proton Pass", "Proton Pass") : root._src("kitty", "user@host"));
            return;
        }
        let rec = null;
        if (kind === "text")
            rec = root._make("text", "A fresh copy, number " + n + ": the quick brown fox.", 0, { source: src });
        else if (kind === "code")
            rec = root._make("code", "const total = items.reduce((a, b) => a + b, " + n + ");", 0, { source: root._src("code", "main.js") });
        else if (kind === "link")
            rec = root._make("link", "https://example.com/article/" + n + "?utm_source=feed&utm_campaign=c" + n + "&id=" + n, 0, { source: src });
        else if (kind === "colour")
            rec = root._make("colour", "#" + ("000000" + ((n * 2654435) % 0xFFFFFF).toString(16)).slice(-6).toUpperCase(), 0, { source: root._src("gimp", "Colors") });
        else if (kind === "image")
            rec = root._make("image", "", 0, Object.assign({ source: root._src("grim", "screenshot") }, root._pics[n % root._pics.length], { bytes: 100000 + n }));
        else if (kind === "files")
            rec = root._make("files", "file:///home/user/Downloads/file-" + n + ".zip", 0, { source: root._src("thunar", "Downloads") });
        if (rec === null) {
            root.error = "feed: unknown kind '" + kind + "'";
            return;
        }
        root._copied(rec);
    }

    // What the tool does with a copy: a known id is a bump, a new one an add.
    function _copied(rec) {
        const known = root._state.byId[rec.id];
        if (known !== undefined)
            root._event({ ev: "bump", id: rec.id, last: rec.last, uses: known.uses + 1 });
        else
            root._event({ ev: "add", entry: rec });
    }

    function fire(state) {
        root.lastState = state;
        if (state !== "nil" && state !== "clear" && state !== "empty")
            return;
        root._setSecrets([]);
        if (state === "nil" && root._state.order.length > 0) {
            const top = root._state.byId[root._state.order[0]];
            root.reoffers++;
            root._event({ ev: "bump", id: top.id, last: Date.now(), uses: top.uses });
        }
        root.serial++;
    }

    function setLocked(on) {
        root.locked = on;
        if (on)
            root._setSecrets([]);
    }

    function setScreencast(on) {
        root.screencast = on;
    }

    // ------------------------------------------------------------- secrets
    function _addSecret(bytes, reason, source) {
        const now = Date.now();
        const key = "s" + (++root._n);
        root._secretText[key] = bytes;
        root._setSecrets(root.secrets.concat([{
                    key: key,
                    mime: "text/plain;charset=utf-8",
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

    // A PEEK only: the held text of one sealed copy. The caller keeps it while
    // the peek lasts and clears it after (CONTRACT.md "Service API").
    function revealSecret(key) {
        const t = root._secretText[key];
        return t === undefined ? "" : t;
    }

    function dropSecret(key) {
        root._setSecrets(root.secrets.filter(s => s.key !== key));
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

    // `seal`: a stored entry becomes a sealed copy (its bytes leave the list).
    function seal(id) {
        const rec = root._state.byId[id];
        if (rec === undefined)
            return;
        root._addSecret(rec.text, "manual", rec.source);
        root._event({ ev: "remove", ids: [id], why: "seal" });
    }

    // `keep`: a sealed copy the user decided to keep becomes an ordinary entry.
    function keep(secretKey) {
        const text = root._secretText[secretKey];
        if (text === undefined)
            return;
        const sec = root.secrets.filter(s => s.key === secretKey)[0];
        root.dropSecret(secretKey);
        root._copied(root._make("text", text, 0, { source: sec ? sec.source : undefined }));
    }

    // ------------------------------------------------------------- the verbs
    function pin(id, on) {
        const rec = root._state.byId[id];
        if (rec === undefined)
            return;
        root._event({ ev: "update", entry: Object.assign({}, rec, { pinned: on === true }) });
    }

    function rename(id, title) {
        const rec = root._state.byId[id];
        if (rec === undefined)
            return;
        root._event({ ev: "update", entry: Object.assign({}, rec, { title: String(title) }) });
    }

    function remove(id) {
        const rec = root._state.byId[id];
        if (rec === undefined)
            return;
        root._removed = root._removed.concat([rec]);
        root._event({ ev: "remove", ids: [id], why: "delete" });
    }

    function undoRemove() {
        if (root._removed.length === 0)
            return;
        const rec = root._removed[root._removed.length - 1];
        root._removed = root._removed.slice(0, -1);
        root._event({ ev: "add", entry: rec });
    }

    function transforms(id) {
        const rec = root._state.byId[id];
        return rec === undefined ? [] : Trans.available(rec);
    }

    function transform(id, name) {
        const rec = root._state.byId[id];
        return rec === undefined ? "" : Trans.apply(name, rec.text);
    }

    // `keys` are record ids or secret keys in pick order. Nothing touches a
    // clipboard: the call is recorded in `lastPaste`, and what the real tool
    // would echo back (a bump, or an add for text that is new) is applied.
    function paste(keys, opts) {
        const o = opts || {};
        const texts = [];
        for (let i = 0; i < keys.length; i++) {
            const rec = root._state.byId[keys[i]];
            if (rec !== undefined)
                texts.push(rec.text);
            else if (root._secretText[keys[i]] !== undefined)
                texts.push(root._secretText[keys[i]]);
        }
        const joined = Model.join(texts, o.joiner);
        const override = o.text !== undefined && o.text !== null;
        root.lastPaste = {
            keys: keys.slice(),
            mode: o.mode === "copy" ? "copy" : "paste",
            text: override ? o.text : "",
            joined: joined,
            via: o.via || (keys.length > 1 ? "join" : "copy"),
            pasteKey: Model.pasteKeyFor(root.origin ? root.origin.cls : "", root.pasteKeys)
        };
        const now = Date.now();
        if (override || keys.length > 1) {
            const text = override ? o.text : joined;
            const src = root._state.byId[keys[0]] ? root._state.byId[keys[0]].source : undefined;
            root._copied(Object.assign(root._make("text", text, 0, { source: src }), { via: root.lastPaste.via, last: now }));
        } else if (keys.length === 1 && root._state.byId[keys[0]] !== undefined) {
            const rec = root._state.byId[keys[0]];
            root._event({ ev: "bump", id: rec.id, last: now, uses: rec.uses + 1 });
        }
    }

    Component.onCompleted: {
        const fx = root._fixtures().sort((a, b) => b.last - a.last);
        const r = Model.reset(root._state, fx);
        for (let i = 0; i < r.order.length; i++)
            rows.append({ key: r.order[i], rec: recComp.createObject(root, { d: r.byId[r.order[i]] }) });
        root.serial++;
        root.ready = true;
    }
}
