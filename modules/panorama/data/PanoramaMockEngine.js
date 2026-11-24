.pragma library
.import "PanoramaModel.js" as M
.import "PanoramaStaging.js" as Staging

// =============================================================================
// PanoramaMockEngine.js -- the mock's Hyprland + engine, pure: a fake list of outputs the rules of PanoramaModel are run on.
// PanoramaMock.qml owns the clock (plug, trial, verify, guard) and calls these between its timers. A state S is
//   { outs, data, drm, gpuMode, since: { name: ms }, ddc: { name: value }, failNext, log: [] }
// and every function mutates it the way the real engine would mutate the compositor: `apply` sends each output its resolved
// spec (the fake Hyprland takes it), `verify` reads the outputs back through PanoramaModel.verify.
// =============================================================================

function copy(o) {
    return JSON.parse(JSON.stringify(o));
}

function log(S, now, line) {
    var d = new Date(now), p = function (n) { return (n < 10 ? "0" : "") + n; };
    S.log.push(p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds()) + " " + line);
    if (S.log.length > 40) S.log.shift();
}

function outByName(S, name) {
    for (var i = 0; i < S.outs.length; i++) if (S.outs[i].name === name) return S.outs[i];
    return null;
}

// the fake engine's cast displays (engine.lua "Cast displays"): a table name -> identity, the lowest free LARES-CAST-<n>, the output made /
// removed here and then applied like any plug. `S.cast` is { map: { name: ident } }.
function castName(S, ident) {
    var map = S.cast.map;
    for (var n in map) if (map[n] === ident) return n;
    for (var i = 1; ; i++) {
        var nm = "LARES-CAST-" + i;
        if (!map[nm] && !outByName(S, nm)) return nm;
    }
}

function castFixture(name, ident) {
    return { name: name, description: "", make: "", model: "", serial: "", id: 50, enabled: true, width: 1920, height: 1080, refresh: 60,
             x: 0, y: 0, scale: 1, transform: 0, mirrorOf: "", physW: 0, physH: 0, modes: [{ w: 1920, h: 1080, r: 60, preferred: true }],
             backend: "headless", hdr: false, bt2020: false, vrrCapable: false, vrr: 0, bitdepth: 8, cm: "srgb", sdrbrightness: 1,
             sdrsaturation: 1, driver: "", castId: ident };
}

function internalOf(S) {
    for (var i = 0; i < S.outs.length; i++) if (M.isInternal(S.outs[i].name)) return S.outs[i];
    return null;
}

// the fake Hyprland taking one complete rule
function _take(S, o, spec) {
    // (a cast output is never off and never a mirror: M.specOn / M.specMirror)
    if (!M.specOn(o.name, spec)) { o.enabled = false; return; }
    o.enabled = true;
    var m = M.specMode(spec, o);
    if (m) { o.width = m.w; o.height = m.h; o.refresh = m.r; }
    if (spec.scale !== "auto" && spec.scale > 0 && m) o.scale = M.snapScale(spec.scale, m.w, m.h);
    o.x = spec.position[0]; o.y = spec.position[1];
    o.transform = spec.transform || 0;
    o.mirrorOf = M.specMirror(o.name, spec);
    o.vrr = spec.vrr; o.bitdepth = spec.bitdepth; o.cm = spec.cm;
    o.sdrbrightness = spec.sdrbrightness; o.sdrsaturation = spec.sdrsaturation;
}

// panorama.apply: bind placeholders, resolve, send a rule to every output whose liveDiff says it differs.
// -> { plan, bound, sent: [name] }
function apply(S, now, why) {
    var b = M.bindPlaceholders(S.data, S.outs);
    if (b.bound.length) {
        S.data = b.data;
        for (var i = 0; i < b.bound.length; i++) log(S, now, "bound " + b.bound[i].from + " -> " + b.bound[i].to);
    }
    var plan = M.resolve(S.outs, S.data), sent = [];
    var names = Object.keys(plan.specs);
    for (var pass = 0; pass < 2; pass++) {               // mirrors last
        for (var j = 0; j < names.length; j++) {
            var sp = plan.specs[names[j]], o = outByName(S, names[j]);
            if ((sp.mirror !== "") !== (pass === 1) || !o || M.liveDiff(o, sp) === "") continue;
            _take(S, o, sp);
            sent.push(names[j]);
        }
    }
    log(S, now, "apply(" + why + "): " + (sent.length ? sent.join(", ") : "nothing to send") + (plan.unknown.length ? "; unknown " + plan.unknown.length : ""));
    return { plan: plan, bound: b.bound, sent: sent };
}

// the safety rule of monitor.removed: nothing enabled -> the internal panel is switched back on
function safety(S, now) {
    var any = S.outs.some(function (o) { return o.enabled !== false && !M.isIgnored(o.name); });
    var lap = internalOf(S);
    if (!any && lap) { lap.enabled = true; log(S, now, "safety: the laptop panel is back on"); }
}

// the service's _autoName: the laptop first, then left to right
function autoName(S, labels) {
    var present = S.outs.filter(function (o) { return !M.isIgnored(o.name); });
    present.sort(function (a, b) {
        var ia = M.isInternal(a.name), ib = M.isInternal(b.name);
        return ia !== ib ? (ia ? -1 : 1) : (a.x - b.x);
    });
    return present.map(function (o) { return labels[o.name]; }).join(" + ");
}

// A set the data has no setup for is saved as the engine grew it (the never-seen default stands), with display records.
function grow(S, plan, now) {
    var labels = M.labels(S.outs), fresh = [];
    for (var i = 0; i < S.outs.length; i++) {
        var o = S.outs[i];
        if (M.isIgnored(o.name)) continue;
        var id = plan.ids[o.name];
        if (!S.data.displays[id]) {
            S.data.displays[id] = { label: labels[o.name], custom: false, internal: M.isInternal(o.name), port: o.name, placeholder: false };
            fresh.push(o.name);
        }
    }
    if (!S.data.setups[plan.setKey]) {
        var outs = {};
        for (var n in plan.specs) {
            var sp = copy(plan.specs[n]);
            sp.mirror = sp.mirror !== "";
            outs[plan.ids[n]] = sp;
        }
        S.data.setups[plan.setKey] = { name: autoName(S, labels), custom: false, used: Math.floor(now / 1000), outputs: outs };
    }
    return fresh;
}

// ---- reading ---------------------------------------------------------------------------------------------------------------------

function displays(S) {
    var present = S.outs.filter(function (o) { return !M.isIgnored(o.name); });
    var labels = M.labels(present), ids = M.identities(present), res = [];
    var lapName = internalOf(S) ? internalOf(S).name : "";
    for (var i = 0; i < present.length; i++) {
        var o = copy(present[i]), n = o.name;
        o.ident = ids[n]; o.label = labels[n]; o.internal = M.isInternal(n); o.kind = M.portKind(n, o.driver);
        var dl = o.driver === "evdi";
        o.ddc = { capable: !o.internal && !dl && !!(o.physW > 0), value: S.ddc[n] !== undefined ? S.ddc[n] : 60, max: 100, busy: false };
        o.mirrorOf = o.mirrorOf || "";
        o.cast = M.isCast(n);
        if (o.cast) o.ddc.capable = false;
        o._lap = lapName;
        res.push(o);
    }
    res.sort(function (a, b) { return a.internal === b.internal ? (a.name < b.name ? -1 : 1) : (a.internal ? -1 : 1); });
    return res;
}

function setupsList(S, setKey) {
    var res = [], keys = Object.keys(S.data.setups || {});
    var labelsOf = function (key) {
        return key.split(" + ").map(function (id) { var d = S.data.displays[id]; return d ? d.label : id; });
    };
    for (var i = 0; i < keys.length; i++) {
        var st = S.data.setups[keys[i]];
        res.push({ key: keys[i], name: st.name || labelsOf(keys[i]).join(" + "), custom: !!st.custom, used: st.used || 0, live: keys[i] === setKey, labels: labelsOf(keys[i]) });
    }
    res.sort(function (a, b) { return a.live !== b.live ? (a.live ? -1 : 1) : (b.used - a.used); });
    return res;
}

function diagnostics(S, plan, verdict, now) {
    var conns = S.drm.connectors.slice(0);
    var since = {};
    for (var n in S.since) since[n] = S.since[n];
    return M.diagnose({ now: now, outputs: S.outs, plan: plan, drm: S.drm, gpuMode: S.gpuMode, verdict: verdict || "", connectedSince: since });
}

// ---- staging ---------------------------------------------------------------------------------------------------------------------

// the data a staged edit would make (the setup for the live set, mirror kept as the stored bool, the split)
function candidate(S, plan, staged, stagedSplit, now) {
    var d = copy(S.data);
    var st = d.setups[plan.setKey] || { name: "", custom: false, outputs: {} };
    st.name = st.custom ? st.name : autoName(S, M.labels(S.outs));
    st.used = Math.floor(now / 1000);
    st.outputs = {};
    for (var n in staged) {
        var sp = copy(staged[n]);
        sp.mirror = !!sp.mirror;
        st.outputs[plan.ids[n]] = sp;
    }
    d.setups[plan.setKey] = st;
    if (stagedSplit) d.split = Staging.splitForStore(d.split, staged, stagedSplit, S.outs);
    return d;
}

function failOne(S) {          // the fake hardware refuses the first mode of an enabled, non-mirroring output
    for (var i = 0; i < S.outs.length; i++) {
        var o = S.outs[i];
        if (o.enabled !== false && !o.mirrorOf && !M.isIgnored(o.name)) { o.width = o.width - 16; return o.name; }
    }
    return "";
}
