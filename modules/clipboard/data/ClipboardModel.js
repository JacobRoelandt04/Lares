.pragma library

.import "../../common/components/FuzzyMatch.js" as Fuzzy

// =============================================================================
// ClipboardModel.js -- the clipboard's orders and event reducer, pure.
//
// A RECORD is the store's (docs/contracts/clipboard.md "Record"): { id,
// kind, text, title, pinned, last, uses, source: { cls, title, address }, ... }.
// Nothing here holds a Qt object, so node can run it.
//
//   PREFS                          the popup's own keys of clipboard.jsonc and their defaults
//   rank(records, query, filter, pinnedFirst)   ordered array of records
//       filter "all"    everything
//              "text"   text, code and colour
//              "link"   link
//              "image"  image
//              "pinned" the pinned ones, of any kind
//       (files show under "all" and "pinned" only)
//       no query: pinned first (`pinnedFirst` false: where their time puts them), then `last` descending
//       a query: FuzzyMatch.bestScore over [title, text (first 2 KB), source.cls]
//       weighted 1 / 0.6 / 0.35; best score first, and among EQUAL scores the
//       pinned one (unless `pinnedFirst` is false), then the newer
//   newState() / reset(state, entries) / applyEvent(state, ev)
//       a plain { order: [ids], byId: {} } state, newest first, and the
//       reducer over the tool's add / bump / update / remove events. It
//       mutates the state and returns { changed, ops }, `ops` being the
//       ListModel calls that mirror the change, in order:
//         { op: "insert", index, rec } { op: "set", index, rec }
//         { op: "move", from, to }     { op: "remove", index, id }
//       A record is REPLACED on bump / update (never edited in place), so a
//       mirror that hands `rec` to a QtObject's `d` emits a change.
//   join(texts, joiner)            pick-order join; joiner defaults to "\n"
//   pasteKeyFor(cls, pasteKeys)    "CTRL SHIFT,V" for a terminal, else the default
//   secretView(secret)             what a secret shows: always 8 dots
// =============================================================================

var PREFS = { enter: "paste", joiner: "\n", copyOnClose: true, pinnedFirst: true, openOn: "all" };
var TEXT_INDEX_CHARS = 2048;
var W_TITLE = 1;
var W_TEXT = 0.6;
var W_SOURCE = 0.35;
var SECRET_DOTS = 8;
var DEFAULT_PASTE_KEY = "CTRL,V";

function _passes(rec, filter) {
    switch (filter) {
    case "text":
        return rec.kind === "text" || rec.kind === "code" || rec.kind === "colour";
    case "link":
        return rec.kind === "link";
    case "image":
        return rec.kind === "image";
    case "pinned":
        return rec.pinned === true;
    default:
        return true;
    }
}

function _byPin(a, b) {
    return (b.pinned === true ? 1 : 0) - (a.pinned === true ? 1 : 0) || _byRecency(a, b);
}

function _byRecency(a, b) {
    const la = a.last || 0, lb = b.last || 0;
    if (la !== lb)
        return lb - la;
    return a.id < b.id ? -1 : (a.id > b.id ? 1 : 0);
}

function rank(records, query, filter, pinnedFirst) {
    const before = pinnedFirst === false ? _byRecency : _byPin;
    const f = filter || "all";
    const q = String(query === undefined || query === null ? "" : query).trim();
    const recs = [];
    for (let i = 0; i < records.length; i++)
        if (_passes(records[i], f))
            recs.push(records[i]);
    if (q.length === 0)
        return recs.sort(before);

    const ws = [W_TITLE, W_TEXT, W_SOURCE];
    const hits = [];
    for (let i = 0; i < recs.length; i++) {
        const r = recs[i];
        const fields = [r.title || "", String(r.text || "").slice(0, TEXT_INDEX_CHARS),
                        (r.source && r.source.cls) || ""];
        const sc = Fuzzy.bestScore(q, fields, ws);     // the score only: a ranking needs no matched positions
        if (sc !== null)
            hits.push({ score: sc, rec: r });
    }
    hits.sort(function (a, b) {
        if (a.score !== b.score)
            return b.score - a.score;
        return before(a.rec, b.rec);
    });
    return hits.map(function (h) {
        return h.rec;
    });
}

// ------------------------------------------------------------------- reducer

function newState() {
    return { order: [], byId: {} };
}

// Load the index (newest first, as the tool wrote it).
function reset(state, entries) {
    state.order = [];
    state.byId = {};
    for (let i = 0; i < entries.length; i++) {
        const e = entries[i];
        if (!e || typeof e.id !== "string" || state.byId[e.id] !== undefined)
            continue;
        state.byId[e.id] = e;
        state.order.push(e.id);
    }
    return state;
}

// Where a record of this `last` belongs: before the first that is not newer.
function _slot(state, rec, skipId) {
    for (let i = 0; i < state.order.length; i++) {
        const id = state.order[i];
        if (id === skipId)
            continue;
        if ((state.byId[id].last || 0) <= (rec.last || 0))
            return i;
    }
    return state.order.length;
}

function _copy(o) {
    const c = {};
    for (const k in o)
        c[k] = o[k];
    return c;
}

function applyEvent(state, ev) {
    const none = { changed: false, ops: [] };
    if (!ev || typeof ev !== "object")
        return none;
    const ops = [];
    if (ev.ev === "add" && ev.entry && typeof ev.entry.id === "string") {
        const rec = _copy(ev.entry);
        const had = state.byId[rec.id] !== undefined;
        if (had) {
            // An add of a known id is the tool contradicting itself: take the
            // newer facts and put it where its `last` says.
            const from = state.order.indexOf(rec.id);
            state.byId[rec.id] = rec;
            ops.push({ op: "set", index: from, rec: rec });
            state.order.splice(from, 1);
            const to = _slot(state, rec, rec.id);
            state.order.splice(to, 0, rec.id);
            if (to !== from)
                ops.push({ op: "move", from: from, to: to });
        } else {
            const at = _slot(state, rec, null);
            state.byId[rec.id] = rec;
            state.order.splice(at, 0, rec.id);
            ops.push({ op: "insert", index: at, rec: rec });
        }
    } else if (ev.ev === "bump" && state.byId[ev.id] !== undefined) {
        const old = state.byId[ev.id];
        const rec = _copy(old);
        rec.last = ev.last;
        rec.uses = ev.uses;
        const from = state.order.indexOf(ev.id);
        state.byId[ev.id] = rec;
        ops.push({ op: "set", index: from, rec: rec });
        state.order.splice(from, 1);
        const to = _slot(state, rec, ev.id);
        state.order.splice(to, 0, ev.id);
        if (to !== from)
            ops.push({ op: "move", from: from, to: to });
    } else if (ev.ev === "update" && ev.entry && state.byId[ev.entry.id] !== undefined) {
        const rec = _copy(ev.entry);
        const at = state.order.indexOf(rec.id);
        state.byId[rec.id] = rec;
        ops.push({ op: "set", index: at, rec: rec });
    } else if (ev.ev === "remove" && Array.isArray(ev.ids)) {
        for (let i = 0; i < ev.ids.length; i++) {
            const id = ev.ids[i];
            const at = state.order.indexOf(id);
            if (at < 0)
                continue;
            state.order.splice(at, 1);
            delete state.byId[id];
            ops.push({ op: "remove", index: at, id: id });
        }
    }
    return ops.length === 0 ? none : { changed: true, ops: ops };
}

// --------------------------------------------------------------------- misc

function join(texts, joiner) {
    const j = joiner === undefined || joiner === null ? "\n" : String(joiner);
    return (texts || []).join(j);
}

function pasteKeyFor(cls, pasteKeys) {
    const pk = pasteKeys || {};
    const def = typeof pk.default === "string" && pk.default.length > 0 ? pk.default : DEFAULT_PASTE_KEY;
    const classes = pk.classes || {};
    const c = String(cls || "");
    if (c.length === 0)
        return def;
    if (typeof classes[c] === "string")
        return classes[c];
    const lc = c.toLowerCase();
    for (const k in classes)
        if (k.toLowerCase() === lc)
            return classes[k];
    return def;
}

// A sealed copy shows eight dots, whatever it holds: no length, no hash, no
// byte of the secret reaches the view.
function secretView(secret) {
    const s = secret || {};
    let mask = "";
    for (let i = 0; i < SECRET_DOTS; i++)
        mask += String.fromCharCode(0x2022);
    return {
        dots: SECRET_DOTS,
        mask: mask,
        reason: s.reason || "",
        mime: s.mime || "",
        source: s.source || null
    };
}
