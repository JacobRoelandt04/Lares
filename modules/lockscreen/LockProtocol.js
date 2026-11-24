.pragma library
// =============================================================================
// LockProtocol.js -- the one wire format between the lock process and the
// shell (contract: docs/contracts/lockscreen.md, section 3).
//
// One JSON object per line over a unix socket. The SHELL listens (LockOwner,
// always), the LOCK connects (ShellLink, retrying). The lock sends its state;
// the shell sends back only what helps it DRAW (where its popup is shown, the
// rects to mask out of the step-down captures) and when its retract is done.
//
// SECURITY. Nothing parsed here can unlock anything: the lock's only unlock
// path is AuthController on PamResult.Success. `retracted` merely lets the
// release happen before its 600 ms cap. Everything a peer sends is untrusted
// and validated field by field; anything unexpected is dropped, not thrown.
// =============================================================================

var VERSION = 1;
var MAX_LINE = 65536;
var MAX_DOTS = 512;

var PHASES = ["locking", "locked", "unlocking"];
var AUTH = ["idle", "checking", "failed", "ok"];
var FACE = ["absent", "idle", "scanning", "ok", "failed", "dark", "busy", "unavailable", "misconfigured"];
// Why the face is where it is (LockState.faceReason); "" = nothing more to say.
var FACE_REASON = ["", "nomatch", "dark", "camera", "lid", "nomodel", "error", "stall", "timeout", "input",
                   "workaround", "device", "config", "pam"];

// Every LockState field and its JS type. Enumerated strings are checked
// against their list in applyState.
var FIELDS = {
    phase: "string",
    boot: "boolean",
    lockedAt: "number",
    dots: "number",
    caps: "boolean",
    auth: "string",
    failCount: "number",
    authMessage: "string",
    face: "string",
    faceMessage: "string",
    faceReason: "string",
    awake: "boolean",
    veilAt: "number"
};
var ENUMS = { phase: PHASES, auth: AUTH, face: FACE, faceReason: FACE_REASON };

// <runtime>/lares-lock/<display>.sock. Keyed by the Wayland display so
// two environments (a test env beside the real session) never share a path:
// a SocketServer deletes an existing socket file when it starts listening.
function socketDir(runtimeDir) {
    return String(runtimeDir) + "/lares-lock";
}
function socketPath(runtimeDir, waylandDisplay) {
    var d = String(waylandDisplay || "wayland-0");
    d = d.substring(d.lastIndexOf("/") + 1).replace(/[^A-Za-z0-9._-]/g, "_");
    return socketDir(runtimeDir) + "/" + d + ".sock";
}

// ---- builders (each returns ONE line, without the newline) -----------------
function hello() {
    return JSON.stringify({ t: "hello", v: VERSION });
}
function snapshot(state) {
    var s = {};
    for (var k in FIELDS)
        s[k] = state[k];
    return s;
}
function stateLine(state) {
    return JSON.stringify({ t: "state", s: snapshot(state) });
}
function bye() {
    return JSON.stringify({ t: "bye" });
}
function shown(screens) {
    return JSON.stringify({ t: "shown", screens: (screens || []).map(String) });
}
// `rects`: every surface of the shell's on that screen (what a capture leaves out). `bar` and `popup` NAME the two the veil
// reads -- the bar the popup hangs from and the popup itself (null: none) -- because a guess by shape fails with islands: an
// island is no full-edge strip, and a retracting popup grows smaller than one. A shell that names neither (the
// fakes, an older shell) leaves the lock to its guess.
function hints(screen, rects, bar, popup) {
    return JSON.stringify({ t: "hints", screen: String(screen), rects: rects || [], bar: bar || null, popup: popup || null });
}
function retracted() {
    return JSON.stringify({ t: "retracted" });
}
// Where, on one screen, the popup's password field is (screen-local logical
// px): the lock starts key pulses there.
function targets(screen, field) {
    return JSON.stringify({ t: "targets", screen: String(screen), field: field || null });
}

function cleanRect(r) {
    if (Array.isArray(r) && r.length === 4 && r.every(function (v) { return typeof v === "number" && isFinite(v); }))
        return [r[0], r[1], Math.max(0, r[2]), Math.max(0, r[3])];
    return null;
}

// ---- parsing ------------------------------------------------------------------
// parse(line) -> { ok: true, msg } | { ok: false, why }
// `msg` is a fresh, validated object: only known fields, right types.
function parse(line) {
    var text = String(line);
    if (text.length === 0)
        return { ok: false, why: "empty" };
    if (text.length > MAX_LINE)
        return { ok: false, why: "too long" };
    var o;
    try {
        o = JSON.parse(text);
    } catch (e) {
        return { ok: false, why: "not json" };
    }
    if (o === null || typeof o !== "object" || Array.isArray(o) || typeof o.t !== "string")
        return { ok: false, why: "no type" };
    switch (o.t) {
    case "hello":
        if (o.v !== VERSION)
            return { ok: false, why: "version" };
        return { ok: true, msg: { t: "hello", v: VERSION } };
    case "bye":
    case "retracted":
        return { ok: true, msg: { t: o.t } };
    case "state":
        if (o.s === null || typeof o.s !== "object" || Array.isArray(o.s))
            return { ok: false, why: "state without s" };
        return { ok: true, msg: { t: "state", s: cleanState(o.s) } };
    case "shown":
        if (!Array.isArray(o.screens))
            return { ok: false, why: "shown without screens" };
        return { ok: true, msg: { t: "shown", screens: o.screens.filter(function (x) { return typeof x === "string"; }).slice(0, 16) } };
    case "targets":
        if (typeof o.screen !== "string")
            return { ok: false, why: "bad targets" };
        return { ok: true, msg: { t: "targets", screen: o.screen, field: cleanRect(o.field) } };
    case "hints":
        if (typeof o.screen !== "string" || !Array.isArray(o.rects))
            return { ok: false, why: "bad hints" };
        var rects = [];
        for (var i = 0; i < o.rects.length && rects.length < 64; i++) {
            var r = o.rects[i];
            if (Array.isArray(r) && r.length === 4 && r.every(function (v) { return typeof v === "number" && isFinite(v); }))
                rects.push([r[0], r[1], Math.max(0, r[2]), Math.max(0, r[3])]);
        }
        var named = o.bar !== undefined || o.popup !== undefined;
        var msg = { t: "hints", screen: o.screen, rects: rects };
        if (named) {
            msg.bar = cleanRect(o.bar);
            msg.popup = cleanRect(o.popup);
        }
        return { ok: true, msg: msg };
    }
    return { ok: false, why: "unknown type" };
}

// Only the known fields, each of the right type and (for enums) value.
function cleanState(s) {
    var out = {};
    for (var k in FIELDS) {
        if (!(k in s) || typeof s[k] !== FIELDS[k])
            continue;
        var v = s[k];
        if (ENUMS[k] && ENUMS[k].indexOf(v) < 0)
            continue;
        if (FIELDS[k] === "number" && !isFinite(v))
            continue;
        if (k === "dots")
            v = Math.max(0, Math.min(MAX_DOTS, Math.round(v)));
        if (k === "failCount")
            v = Math.max(0, Math.round(v));
        if (FIELDS[k] === "string" && v.length > 512)
            v = v.substring(0, 512);
        out[k] = v;
    }
    return out;
}

// Write a cleaned state into a LockState. Writes only what differs, so a
// mirror's bindings re-run for real changes only.
function applyState(target, clean) {
    for (var k in clean) {
        if (target[k] !== clean[k])
            target[k] = clean[k];
    }
}
