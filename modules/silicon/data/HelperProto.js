.pragma library

// =============================================================================
// HelperProto.js -- silicon's side of the root helper's wire format (v1):
// docs/contracts/silicon_helper_protocol.md.
// Pure functions, no Qt: intents -> argument lists, the helper's JSON -> plain values,
// `results` -> refusals with their `why`. The helper itself (helpers/silicon_helper/) is written against the same document; nothing here reads its code.
//
//   statusArgv(prefix)                    `silicon-helper status` (unprivileged, direct)
//   applyArgv(prefix, patch)              `apply profile= governor= epp= turbo= max_perf_pct= pl1_w= pl2_w=`
//   chargeLimitArgv(prefix, 80|100)       `set-charge-limit`
//   setBootArgv / muxRequestArgv / muxCancelArgv / muxPromptShownArgv / muxConfirmArgv
//   applyWords(patch)                     the `key=value` arguments of a patch, as apply / set-boot take them
//   parseBootSet(text)                    the helper's stored boot set (boot.json) -> { ok, apply, chargeLimit } | { ok: false, why }
//   sameApply(apply, words)               does a stored `apply` hold exactly these arguments
//   parseStatus(text)                     -> { ok, proto, status } | { ok: false, why }
//   parseWrite(text, exit, stderr)        -> { ok, exit, results, status, why }
//   refusals(results)                     -> [{ knob, want, got, code, why }]
//   refusalText(list)                     the words a caption shows
//   mismatches(patch, results)            what was asked and did not come back
//   validatePatch(patch, status)          the helper's own rules, asked locally first
//   changedKnobs(prev, cur)               what moved between two statuses
//
// A PATCH is { profile, epp, turbo, governor, maxPerfPct, pl1W, pl2W }, any subset; a cap may be
// the word "firmware" (back to the ceiling the firmware set).
//
// `prefix` is the helper's command line: ["pkexec", "/usr/local/libexec/silicon-helper"] for a
// write, the bare binary for `status`, either followed by test-mode flags in a probe. The
// protocol allows nothing else to reach the helper: no stdin, no environment, no config file.
// =============================================================================

var PROTO = 1;

// The knobs an apply can carry, in the order the helper applies them (profile -> governor -> EPP
// -> turbo -> max_perf_pct -> caps) and the argument name each takes.
var APPLY_ORDER = ["profile", "governor", "epp", "turbo", "maxPerfPct", "pl1W", "pl2W"];
var ARG_NAMES = {
    profile: "profile", governor: "governor", epp: "epp", turbo: "turbo",
    maxPerfPct: "max_perf_pct", pl1W: "pl1_w", pl2W: "pl2_w"
};

function _watts(v) {
    return v === "firmware" ? "firmware" : String(Math.round(v));
}

function _applyArgs(patch) {
    var out = [];
    for (var i = 0; i < APPLY_ORDER.length; i++) {
        var k = APPLY_ORDER[i];
        if (!patch || patch[k] === undefined || patch[k] === null)
            continue;
        var v = patch[k];
        if (k === "turbo")
            v = (v === true || v === 1 || v === "1") ? "1" : "0";
        else if (k === "pl1W" || k === "pl2W")
            v = _watts(v);
        else
            v = String(v);
        out.push(ARG_NAMES[k] + "=" + v);
    }
    return out;
}

function statusArgv(prefix) {
    return (prefix || []).concat(["status"]);
}

function applyArgv(prefix, patch) {
    return (prefix || []).concat(["apply"], _applyArgs(patch));
}

function setBootArgv(prefix, patch) {
    return (prefix || []).concat(["set-boot"], _applyArgs(patch));
}

function applyWords(patch) {
    return _applyArgs(patch);
}

// --- the boot set ----------------------------------------------------------------------------
// What `set-boot` stored and silicon-boot.service applies early in every boot: the helper's own file
// (/var/lib/silicon/boot.json, 0644 -- what its unprivileged `status` reads too; status does not report it)
//   { "version": 1, "apply": { "<apply argument>": "<value as it was typed>" }, "chargeLimit": 80 | 100 | null }
// "" (no file) is nothing stored. -> { ok: true, apply, chargeLimit } | { ok: false, why }
function parseBootSet(text) {
    var s = String(text === undefined || text === null ? "" : text).trim();
    if (s === "")
        return { ok: true, apply: {}, chargeLimit: null };
    var o = null;
    try {
        o = JSON.parse(s);
    } catch (e) {
        return { ok: false, why: "the boot set is not JSON" };
    }
    if (!o || typeof o !== "object" || Array.isArray(o) || o.version !== 1 || !o.apply || typeof o.apply !== "object" || Array.isArray(o.apply))
        return { ok: false, why: "the boot set is not understood" };
    var apply = {};
    var keys = Object.keys(o.apply);
    for (var i = 0; i < keys.length; i++) {
        if (typeof o.apply[keys[i]] !== "string")
            return { ok: false, why: "the boot set is not understood" };
        apply[keys[i]] = o.apply[keys[i]];
    }
    return { ok: true, apply: apply, chargeLimit: typeof o.chargeLimit === "number" ? o.chargeLimit : null };
}

// A stored `apply` (parseBootSet) holds exactly `words` (applyWords): the same arguments, the same values as typed.
function sameApply(apply, words) {
    var keys = Object.keys(apply || {});
    if (keys.length !== words.length)
        return false;
    for (var i = 0; i < words.length; i++) {
        var at = words[i].indexOf("=");
        if (at < 0 || apply[words[i].substring(0, at)] !== words[i].substring(at + 1))
            return false;
    }
    return true;
}

function chargeLimitArgv(prefix, pct) {
    return (prefix || []).concat(["set-charge-limit", String(pct)]);
}

function muxRequestArgv(prefix, want) {
    return (prefix || []).concat(["mux-request", want === "dgpu" ? "dgpu" : "hybrid"]);
}

function muxCancelArgv(prefix) { return (prefix || []).concat(["mux-cancel"]); }
function muxPromptShownArgv(prefix) { return (prefix || []).concat(["mux-prompt-shown"]); }
function muxConfirmArgv(prefix) { return (prefix || []).concat(["mux-confirm"]); }

// --- reading the answer ---------------------------------------------------------------------

// ONE JSON object on stdout, then a newline; anything else is noise (diagnostics go to stderr).
function parseOutput(text) {
    var s = String(text === undefined || text === null ? "" : text).trim();
    if (s === "")
        return { ok: false, why: "no answer" };
    var o = null;
    try {
        o = JSON.parse(s);
    } catch (e) {
        var lines = s.split("\n");
        for (var i = lines.length - 1; i >= 0 && o === null; i--) {
            try {
                o = JSON.parse(lines[i]);
            } catch (e2) {
                o = null;
            }
        }
    }
    if (!o || typeof o !== "object" || Array.isArray(o))
        return { ok: false, why: "the helper's answer is not a JSON object: " + s.slice(0, 80) };
    return { ok: true, obj: o };
}

// A status with every part present, so the data layer never tests for existence twice.
function normaliseStatus(st) {
    var s = st && typeof st === "object" ? st : {};
    var f = s.features || {};
    var L = s.lists || {};
    var lim = s.limits || {};
    var pk = s.prechecks || {};
    var mx = s.mux || {};
    return {
        features: {
            profile: f.profile === true, epp: f.epp === true, turbo: f.turbo === true,
            governor: f.governor === true, maxPerfPct: f.maxPerfPct === true, caps: f.caps === true,
            chargeLimit: f.chargeLimit === true, mux: f.mux === true
        },
        values: s.values && typeof s.values === "object" ? s.values : {},
        lists: {
            profiles: Array.isArray(L.profiles) ? L.profiles.slice() : [],
            epps: Array.isArray(L.epps) ? L.epps.slice() : [],
            governors: Array.isArray(L.governors) ? L.governors.slice() : []
        },
        limits: {
            capFloorW: typeof lim.capFloorW === "number" ? lim.capFloorW : null,
            capCeilW: lim.capCeilW && typeof lim.capCeilW === "object"
                      && typeof lim.capCeilW.pl1 === "number" && typeof lim.capCeilW.pl2 === "number"
                      ? { pl1: lim.capCeilW.pl1, pl2: lim.capCeilW.pl2 } : null,
            maxPerfPct: lim.maxPerfPct && typeof lim.maxPerfPct.min === "number" && typeof lim.maxPerfPct.max === "number"
                        ? { min: lim.maxPerfPct.min, max: lim.maxPerfPct.max } : null,
            eppLocked: lim.eppLocked === true
        },
        paths: s.paths && typeof s.paths === "object" ? s.paths : {},
        prechecks: { mux: pk.mux && typeof pk.mux === "object" ? { ok: pk.mux.ok !== false, why: String(pk.mux.why || "") } : { ok: true, why: "" } },
        mux: {
            stored: mx.stored === undefined ? null : mx.stored,
            wiringNow: mx.wiringNow === undefined ? null : mx.wiringNow,
            record: mx.record && typeof mx.record === "object" ? mx.record : null
        },
        boot: s.boot && typeof s.boot === "object" ? s.boot : {}
    };
}

// `silicon-helper status` -> { ok, proto, status } | { ok: false, why }
function parseStatus(text) {
    var p = parseOutput(text);
    if (!p.ok)
        return p;
    var o = p.obj;
    if (o.ok === false)
        return { ok: false, why: String(o.why || o.error || "the helper reported an error") };
    if (o.proto !== undefined && o.proto !== PROTO)
        return { ok: false, why: "the helper speaks protocol " + o.proto + ", this shell speaks " + PROTO };
    if (!o.status || typeof o.status !== "object")
        return { ok: false, why: "the helper's answer has no status" };
    return { ok: true, proto: o.proto === undefined ? PROTO : o.proto, status: normaliseStatus(o.status) };
}

// What an exit code means when the helper said nothing readable (pkexec's own codes included).
function describeExit(code, stderr) {
    var err = String(stderr === undefined || stderr === null ? "" : stderr).trim().split("\n")[0];
    var m = {
        1: "a write failed or read back wrong",
        2: "the helper refused the request",
        3: "the helper could not read the machine's state",
        4: "the helper refused to run in test mode as root",
        126: "authorisation was refused (is the polkit rule installed?)",
        127: "the silicon helper is not installed"
    };
    var base = m[code] !== undefined ? m[code] : "the helper exited with " + code;
    return err !== "" && code !== 0 ? base + " (" + err + ")" : base;
}

// A write's answer -> { ok, exit, results, status, why }. ok means exit 0 AND every result ok.
function parseWrite(text, exit, stderr) {
    var p = parseOutput(text);
    if (!p.ok)
        return { ok: false, exit: exit, results: [], status: null, why: describeExit(exit, stderr) };
    var o = p.obj;
    var results = Array.isArray(o.results) ? o.results.filter(function (r) { return r && typeof r === "object"; }) : [];
    var status = o.status && typeof o.status === "object" ? normaliseStatus(o.status) : null;
    var allOk = results.every(function (r) { return r.ok === true && (r.code === undefined || r.code === "ok"); });
    var ok = exit === 0 && o.ok !== false && allOk;
    var why = "";
    if (!ok) {
        var bad = refusals(results);
        why = bad.length > 0 ? refusalText(bad) : (typeof o.why === "string" && o.why !== "" ? o.why : describeExit(exit, stderr));
    }
    return { ok: ok, exit: exit, results: results, status: status, why: why };
}

// Every result that did not come back ok, as { knob, want, got, code, why }. A refusal that is
// dropped here is a write that fails with no word on screen.
function refusals(results) {
    var out = [];
    var r = Array.isArray(results) ? results : [];
    for (var i = 0; i < r.length; i++) {
        if (r[i].ok === true && (r[i].code === undefined || r[i].code === "ok"))
            continue;
        out.push({
            knob: String(r[i].knob || ""), want: r[i].want === undefined ? null : r[i].want,
            got: r[i].got === undefined ? null : r[i].got,
            code: String(r[i].code || "io"), why: String(r[i].why || "")
        });
    }
    return out;
}

// A caption starts with a capital -- unless it starts with a NAME (a unit, a command, a path), which is case-sensitive:
// "silicon-mux.service is not active, so ..." stays as the helper wrote it, not "Silicon-mux.service".
function _cap(s) {
    if (s.length === 0 || /[-._\/]/.test(s.split(" ")[0]))
        return s;
    return s.charAt(0).toUpperCase() + s.slice(1);
}

// The words a caption shows for refusals: one reason as it is, several joined with "; ".
function refusalText(list) {
    if (!list || list.length === 0)
        return "";
    var parts = list.map(function (b) {
        return b.why !== "" ? b.why : (b.knob !== "" ? b.knob + ": " + b.code : b.code);
    });
    var seen = {};
    parts = parts.filter(function (p) { return seen[p] ? false : (seen[p] = true); });
    return _cap(parts.join("; "));
}

function _same(a, b) {
    if (a === b)
        return true;
    var norm = function (x) {
        if (x === true || x === "true" || x === "1" || x === 1)
            return 1;
        if (x === false || x === "false" || x === "0" || x === 0)
            return 0;
        if (typeof x === "string" && /^-?\d+(\.\d+)?$/.test(x))
            return Number(x);
        return x;
    };
    var na = norm(a), nb = norm(b);
    if (na === nb)
        return true;
    return typeof na !== "string" && typeof nb !== "string" && na !== null && nb !== null && Number(na) === Number(nb);
}

// What was asked and did not come back: a knob with no answer, one that refused, or one whose
// read-back (`got`) is not the value asked for. [{ knob, want, got, why }]. `patch` is any
// { knob: want }: the apply knobs first in the helper's order, then the others (chargeLimit).
function mismatches(patch, results) {
    var out = [];
    var res = Array.isArray(results) ? results : [];
    var keys = APPLY_ORDER.filter(function (k) { return patch && patch[k] !== undefined && patch[k] !== null; })
        .concat(Object.keys(patch || {}).filter(function (k) {
            return APPLY_ORDER.indexOf(k) < 0 && patch[k] !== undefined && patch[k] !== null;
        }));
    for (var i = 0; i < keys.length; i++) {
        var k = keys[i];
        var r = null;
        for (var j = 0; j < res.length; j++) {
            if (res[j].knob === k)
                r = res[j];
        }
        if (r === null) {
            out.push({ knob: k, want: patch[k], got: null, why: "the helper did not answer for " + k });
            continue;
        }
        if (r.ok !== true || (r.code !== undefined && r.code !== "ok")) {
            out.push({ knob: k, want: patch[k], got: r.got === undefined ? null : r.got, why: String(r.why || r.code || "refused") });
            continue;
        }
        // "firmware" reads back as the ceiling's number: the helper's own `ok` stands for it.
        if (patch[k] !== "firmware" && r.got !== undefined && r.got !== null && !_same(r.got, patch[k]))
            out.push({ knob: k, want: patch[k], got: r.got, why: k + " reads back " + r.got + ", not " + patch[k] });
    }
    return out;
}

// --- the helper's own rules, asked locally first ------------------------------------------
// -> { ok: true } | { ok: false, knob, code: "refused"|"absent"|"locked", why }.
// A patch the helper would refuse is refused here, in one frame, with the same words, instead of
// after a pkexec round trip; the helper still validates everything (this is a courtesy).
function validatePatch(patch, status) {
    if (!status)
        return { ok: false, knob: "", code: "absent", why: "The silicon helper is not available" };
    var f = status.features, L = status.lists, lim = status.limits, v = status.values;
    var fail = function (knob, code, why) { return { ok: false, knob: knob, code: code, why: why }; };
    var has = function (k) { return patch[k] !== undefined && patch[k] !== null; };
    if (has("profile")) {
        if (!f.profile)
            return fail("profile", "absent", "Power profiles are not available on this kernel");
        if (L.profiles.indexOf(patch.profile) < 0)
            return fail("profile", "refused", "Unknown profile " + patch.profile);
    }
    if (has("governor")) {
        if (!f.governor)
            return fail("governor", "absent", "The CPU governor cannot be set on this kernel");
        if (L.governors.indexOf(patch.governor) < 0)
            return fail("governor", "refused", "Unknown governor " + patch.governor);
    }
    if (has("epp")) {
        if (!f.epp)
            return fail("epp", "absent", "Energy preference is not available on this kernel");
        if (L.epps.indexOf(patch.epp) < 0)
            return fail("epp", "refused", "Unknown energy preference " + patch.epp);
        var governorAfter = has("governor") ? patch.governor : v.governor;
        var locked = has("governor") ? patch.governor === "performance" : (lim.eppLocked || v.governor === "performance");
        if (locked)
            return fail("epp", "locked", "Energy preference is fixed while the governor is " + (governorAfter || "performance"));
    }
    if (has("turbo")) {
        if (!f.turbo)
            return fail("turbo", "absent", "Turbo cannot be switched on this kernel");
        if (typeof patch.turbo !== "boolean")
            return fail("turbo", "refused", "Turbo is on or off");
    }
    if (has("maxPerfPct")) {
        if (!f.maxPerfPct)
            return fail("maxPerfPct", "absent", "The maximum performance cannot be set on this kernel");
        var mp = lim.maxPerfPct;
        if (typeof patch.maxPerfPct !== "number" || patch.maxPerfPct !== Math.floor(patch.maxPerfPct)
                || (mp && (patch.maxPerfPct < mp.min || patch.maxPerfPct > mp.max)))
            return fail("maxPerfPct", "refused", "Maximum performance is " + (mp ? mp.min + " to " + mp.max : "a whole number") + " %");
    }
    var caps = [["pl1W", "pl1", "PL1"], ["pl2W", "pl2", "PL2"]];
    for (var c = 0; c < caps.length; c++) {
        var key = caps[c][0];
        if (!has(key))
            continue;
        if (!f.caps || lim.capCeilW === null || lim.capFloorW === null)
            return fail(key, "absent", f.caps ? "The firmware's limits are not recorded yet" : "Power caps are not available on this machine");
        if (patch[key] === "firmware")
            continue;
        var w = patch[key];
        if (typeof w !== "number" || !isFinite(w))
            return fail(key, "refused", caps[c][2] + " is a number of watts");
        if (w > lim.capCeilW[caps[c][1]])
            return fail(key, "refused", "Above the firmware's " + lim.capCeilW[caps[c][1]] + " W");
        if (w < lim.capFloorW)
            return fail(key, "refused", "Below the " + lim.capFloorW + " W floor");
    }
    if (has("pl1W") || has("pl2W")) {
        var cur = v.caps || {};
        var ceil = lim.capCeilW;
        var at = function (key, curKey, ceilKey) {
            if (has(key))
                return patch[key] === "firmware" ? (ceil ? ceil[ceilKey] : null) : patch[key];
            return typeof cur[curKey] === "number" ? cur[curKey] : null;
        };
        var p1 = at("pl1W", "pl1W", "pl1"), p2 = at("pl2W", "pl2W", "pl2");
        if (p1 !== null && p2 !== null && p1 > p2)
            return fail(has("pl1W") ? "pl1W" : "pl2W", "refused", "PL1 cannot be above PL2");
    }
    return { ok: true };
}

// What moved between two statuses' values: ["profile", "epp", ...] (the intent's knob names).
// A status that is missing on either side moves nothing.
function changedKnobs(prev, cur) {
    if (!prev || !cur)
        return [];
    var a = prev.values || {}, b = cur.values || {};
    var out = [];
    var simple = ["profile", "epp", "turbo", "governor", "maxPerfPct", "chargeLimit"];
    for (var i = 0; i < simple.length; i++) {
        if (a[simple[i]] !== undefined && b[simple[i]] !== undefined && !_same(a[simple[i]], b[simple[i]]))
            out.push(simple[i]);
    }
    var ca = a.caps || {}, cb = b.caps || {};
    if (typeof ca.pl1W === "number" && typeof cb.pl1W === "number" && ca.pl1W !== cb.pl1W)
        out.push("pl1W");
    if (typeof ca.pl2W === "number" && typeof cb.pl2W === "number" && ca.pl2W !== cb.pl2W)
        out.push("pl2W");
    return out;
}
