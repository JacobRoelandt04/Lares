.pragma library
.import "PanoramaModel.js" as M
.import "PanoramaLayout.js" as L

// =============================================================================
// PanoramaStaging.js -- the popup's staged edit, pure: ONE copy of the rules for PanoramaService (live) and PanoramaMock (the twin the
// UI probes run on), so the mock cannot differ from the service where an edit is staged (round 2: the mock had seeded the split another
// way, refused what the service let through, and cleared what the service kept).
//
// A staged edit is { <output name>: SPEC with `mirror` as a bool } (the shape the popup edits); the split is { "1".."4": <display identity> }.
//   copy(o)                                 a deep copy
//   internalName(outs)                      the laptop panel's connector name ("" none)
//   stagedFrom(plan)                        the resolved specs as a staged edit
//   splitIdents(plan)                       the resolved split by IDENTITY, complete for every workspace that has a place
//   resolved(staged, outs)                  the staged specs with `mirror` as the name it resolves to (the rects' and the split's input)
//   relationsOf(staged, outs)               PanoramaLayout.relationsOf of the staged layout: an opaque map, name -> how it hangs on its neighbour
//   patchSpec(staged, name, patch, outs, relations)   -> { staged, sizes }: one tile's patch, the layout re-placed from `relations` when it
//                                           changed the tile's size
//   isDirty(staged, split, plan)            the edit differs from what is in force (specs, or the split against the RESOLVED split)
//   toggleSplit(split, ws, ident, plan)     workspace `ws` onto `ident`; a click on the one it is on gives it back to the internal display
//   castQuality(q, d)                       a cast display's quality: what was stored, the rest from `d` (panorama.jsonc castQuality)
//   splitForStore(docSplit, staged, split, outs)   what the data keeps of the split: only what differs from the defaults, unless that
//                                           would not reproduce the edit (then the whole map)
//   resetEdit(outs)                         the default arrangement of this set as if it had never been seen: { staged, split }
//   CAST_STANDIN, castStandIn(ident, internal), withStandIn(outs, ident)
//                                           a cast that MIRRORS has no output (CastKeeper): the display record that stands in for the TV, so
//                                           the canvas, the detail and the set's key know it. Never a real name (the engine counts from 1)
//   castMirrorStored(outs, doc, ident)      the TV's stored setup, for the displays there are, says it mirrors the laptop
//   castSetup(doc, plan, ident, autoName, nowS, change)   a copy of `doc` whose setup of the live set (made from the plan when there is none)
//                                           has `change(spec)` applied to the TV's spec; null when the TV is not in the set
// =============================================================================

function copy(o) {
    return JSON.parse(JSON.stringify(o));
}

function internalName(outs) {
    for (var i = 0; i < outs.length; i++)
        if (M.isInternal(outs[i].name) && !M.isIgnored(outs[i].name)) return outs[i].name;
    return "";
}

function stagedFrom(plan) {
    var st = {};
    for (var n in plan.specs) {
        var sp = copy(plan.specs[n]);
        sp.mirror = sp.mirror !== "";
        st[n] = sp;
    }
    return st;
}

function splitIdents(plan) {
    var res = {};
    for (var i = 0; i < M.WORKSPACES.length; i++) {
        var w = M.WORKSPACES[i];
        if (plan.split[w] !== undefined) res[w] = plan.ids[plan.split[w]];
    }
    return res;
}

function resolved(staged, outs) {
    var internal = internalName(outs), res = {};
    for (var n in staged) {
        var sp = copy(staged[n]);
        sp.mirror = sp.mirror && internal !== "" && n !== internal && staged[internal] && staged[internal].enabled ? internal : "";
        res[n] = sp;
    }
    return res;
}

function _rects(staged, outs) {
    return L.rectsOf(resolved(staged, outs), outs);
}

function relationsOf(staged, outs) {
    return L.relationsOf(_rects(staged, outs), internalName(outs));
}

function _place(s, outs, relations) {
    var internal = internalName(outs), rects = _rects(s, outs);
    var anchored = L.relayout(rects, relations || {}, internal);
    for (var i = 0; i < anchored.length; i++)
        s[anchored[i].name].position = [anchored[i].x, anchored[i].y];
}

function patchSpec(staged, name, patch, outs, relations) {
    if (!staged[name]) return { staged: staged, sizes: false };
    var s = copy(staged), internal = internalName(outs), out = null, sizes = false;
    for (var i = 0; i < outs.length; i++) if (outs[i].name === name) { out = outs[i]; break; }
    for (var k in patch) {
        // the last display on stays on (the engine's safety rule would switch it back anyway)
        if (k === "enabled" && !patch.enabled) {
            var others = Object.keys(s).filter(function (n) { return n !== name && s[n].enabled && !s[n].mirror; });
            if (!others.length) continue;
        }
        // a mirror is of the laptop panel only, and only while it is on (decision 24)
        if (k === "mirror" && patch.mirror && (name === internal || internal === "" || !s[internal] || !s[internal].enabled)) continue;
        if (["mode", "scale", "transform", "enabled", "mirror"].indexOf(k) >= 0 && JSON.stringify(s[name][k]) !== JSON.stringify(patch[k]))
            sizes = true;
        s[name][k] = k === "position" ? [patch.position[0], patch.position[1]] : patch[k];
    }
    if (patch.mode !== undefined && typeof s[name].scale === "number" && out) {
        var m = M.specMode(s[name], out);
        if (m) s[name].scale = M.snapScale(s[name].scale, m.w, m.h);
    }
    if (sizes) _place(s, outs, relations);
    return { staged: s, sizes: sizes };
}

function _same(a, b) {
    return JSON.stringify(a || {}) === JSON.stringify(b || {});
}

function isDirty(staged, split, plan) {
    if (staged === null || staged === undefined) return false;
    for (var name in staged) {
        var live = plan.specs[name];
        if (!live) return true;
        var a = copy(live);
        a.mirror = a.mirror !== "";
        if (M.specChanges(a, staged[name]).length > 0) return true;
    }
    return !_same(split, splitIdents(plan));
}

function toggleSplit(split, ws, ident, plan) {
    var before = copy(split || splitIdents(plan)), sp = copy(before);
    // EVERY DISPLAY THAT SHOWS WORKSPACES KEEPS ONE (the user's rule, 2026-11-23): a display left with none shows a fifth workspace of
    // Hyprland's own. A click that would take a display's last one changes nothing.
    var keeps = function (res) {
        var had = {}, has = {}, w;
        for (w in before) had[before[w]] = true;
        for (w in res) has[res[w]] = true;
        for (var id in had) if (!has[id]) return before;
        return res;
    };
    if (sp[ws] !== ident) {
        sp[ws] = ident;
        return keeps(sp);
    }
    // already there: back to the internal display, else to the first other one that shows a workspace
    var home = "", internal = "";
    for (var n in plan.specs)
        if (M.isInternal(n) && plan.specs[n].enabled && !plan.specs[n].mirror) internal = plan.ids[n];
    if (internal !== "" && internal !== ident) home = internal;
    else for (var w in sp) if (sp[w] !== ident && home === "") home = sp[w];
    if (home !== "") sp[ws] = home;
    return keeps(sp);
}

function _present(outs) {
    var present = outs.filter(function (o) { return !M.isIgnored(o.name); });
    present.sort(function (a, b) { return M._byteLess(a.name, b.name); });
    return present;
}

function _splitOfData(split, staged, outs) {
    var present = _present(outs), ids = M.identities(present), specs = resolved(staged, outs), internal = null;
    for (var i = 0; i < present.length; i++) if (M.isInternal(present[i].name)) { internal = present[i]; break; }
    var byName = M.splitOf({ split: split }, present, ids, specs, internal), res = {};
    for (var w in byName) res[w] = ids[byName[w]];
    return res;
}

function splitForStore(docSplit, staged, split, outs) {
    var want = split || {}, base = copy(docSplit || {}), defaults = _splitOfData({}, staged, outs);
    var minimal = copy(base);
    for (var w in want) {
        if (want[w] === defaults[w]) delete minimal[w];
        else minimal[w] = want[w];
    }
    var got = _splitOfData(minimal, staged, outs), ok = true;
    for (var v in want) if (got[v] !== want[v]) ok = false;
    if (ok) return minimal;
    var full = copy(base);
    for (var x in want) full[x] = want[x];
    return full;
}

function resetEdit(outs) {
    var plan = M.resolve(outs, { v: 1, displays: {}, setups: {}, split: {} });
    return { staged: stagedFrom(plan), split: splitIdents(plan) };
}

var CAST_STANDIN = M.CAST_STANDIN;
function castStandIn(ident, internal) {
    return { name: CAST_STANDIN, description: "", make: "", model: "", serial: "", id: -1, enabled: true, width: 1920, height: 1080,
             refresh: 60, x: 0, y: 0, scale: 1, transform: 0, mirrorOf: internal, physW: 0, physH: 0,
             modes: [{ w: 1920, h: 1080, r: 60, preferred: true }], backend: "headless", hdr: false, bt2020: false, vrrCapable: false,
             vrr: 0, bitdepth: 8, cm: "srgb", sdrbrightness: 1, sdrsaturation: 1, driver: "", castId: ident, standIn: true };
}
function withStandIn(outs, ident) {
    // (the cast's own output, when it is still listed on its way out, is not shown beside its stand-in)
    var res = (outs || []).filter(function (o) { return o.name !== CAST_STANDIN && !(ident && o.castId === ident); }), internal = internalName(res);
    if (ident && internal !== "") res.push(castStandIn(ident, internal));
    return res;
}
function castMirrorStored(outs, doc, ident) {
    var all = withStandIn(outs, ident);
    var sp = M.resolve(all, doc).specs[CAST_STANDIN];
    return !!sp && sp.mirror !== "";
}
function castSetup(doc, plan, ident, autoName, nowS, change) {
    var d = copy(doc || {});
    d.v = 1;
    d.displays = d.displays || {};
    d.setups = d.setups || {};
    var st = d.setups[plan.setKey];
    if (!st) {
        var outs = {};
        for (var n in plan.specs) {
            var sp = copy(plan.specs[n]);
            sp.mirror = sp.mirror !== "";
            outs[plan.ids[n]] = sp;
        }
        st = { name: autoName, custom: false, used: nowS, outputs: outs };
        d.setups[plan.setKey] = st;
    }
    if (!st.outputs[ident]) return null;
    change(st.outputs[ident]);
    return d;
}

// A cast display's quality: what its setup stored, each missing field from `d` (panorama.jsonc castQuality, a TV not set up yet). The service,
// its mock and the keeper all ask here.
var CAST_QUALITY = { res: "1920x1080", fps: 30, bitrate: "8M", audio: true };
function castQuality(q, d) {
    var s = q && typeof q === "object" ? q : {}, f = d && typeof d === "object" ? d : CAST_QUALITY;
    return { res: s.res || f.res || CAST_QUALITY.res, fps: Number(s.fps) > 0 ? Number(s.fps) : (Number(f.fps) > 0 ? Number(f.fps) : CAST_QUALITY.fps),
             bitrate: s.bitrate || f.bitrate || CAST_QUALITY.bitrate, audio: s.audio === undefined ? f.audio !== false : s.audio !== false };
}
