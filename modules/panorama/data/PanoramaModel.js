.pragma library

// =============================================================================
// PanoramaModel.js -- Panorama's data rules, pure (no Qt; loads under node with the pragma line cut).
//
// THE TWIN. tools/panorama/engine.lua runs the same rules inside Hyprland (identity, set key, scale snap, physical scale,
// placement, split, resolve, liveMatches, verify, bindPlaceholders). Both are held to ONE case table,
// tools/dev/panorama_cases.json (node: tools/dev/panorama_cases.js, lua: tools/dev/panorama_cases.lua). A change to a rule
// starts in the table. docs/contracts/panorama.md has the schemas; docs/agent_added_files_and_folders/panorama/FACTS.md the
// Hyprland facts the rules rest on (F5: the scale snap, F9: positions are always explicit, F10: mirrorOf is an id).
//
// AN OUTPUT (what every function takes; FocusedScreen.outputs and the engine's Lua build the same record):
//   { name, description, make, model, serial, id, enabled, width, height, refresh, x, y, scale, transform,
//     mirrorOf ("" | source NAME: the reader resolves Hyprland's id), physW, physH (mm), modes: [{w, h, r, preferred}],
//     backend, hdr, bt2020, vrrCapable, vrr, bitdepth, cm, sdrbrightness, sdrsaturation, driver ("" | i915 | nvidia | evdi ...) }
// A SPEC (what one output should be; the store's per-output record; what hl.monitor gets):
//   { enabled, mode ("WxH@R" | "preferred"), position: [x, y], scale (number | "auto"), transform (0-3), mirror (bool: of the
//     internal panel), vrr (0 | 1 | 2), bitdepth (8 | 10), cm ("srgb" | "wide" | "hdr" | ...), sdrbrightness, sdrsaturation }
// THE DATA (setups.json, and the table embedded in panorama.lua):
//   { v: 1, displays: { <id>: { label, custom, internal, port, placeholder } },
//     setups: { <setKey>: { name, custom, used, outputs: { <id>: SPEC } } }, split: { "1".."4": <id> } }
// =============================================================================

var VERSION = 1;
var IGNORED = ["LARESLOCK-HOP", "FALLBACK"];
var WORKSPACES = ["1", "2", "3", "4"];
var SCALE_MIN = 1.0;                // the user's floor (decision 30): the physical match never goes below 1
var SCALE_MAX = 3.0;
var PPMM_MIN = 2.5, PPMM_MAX = 14;  // px per mm a real panel has; outside: a TV, a projector, a lie -> "auto"
var DIAG_MIN = 250, DIAG_MAX = 1100;// mm (10" .. 43")
var REFRESH_TOL = 0.5;              // Hz: 59.94 is 60
var SCALE_TOL = 0.001;

var PORT_LABELS = { laptop: "Laptop", hdmi: "HDMI", usbc: "USB-C", displaylink: "DisplayLink", dvi: "DVI", vga: "VGA",
                    virtual: "Virtual", cast: "Cast", other: "Display" };
// A CAST DISPLAY is a Hyprland headless output the engine makes for one TV (docs/contracts/panorama.md section 10): named
// LARES-CAST-<n>, identified as `cast:<device id>` (the engine's name -> identity table: the output itself says nothing about the TV).
var CAST_MODE = "1920x1080@60";

function isIgnored(name) {
    return IGNORED.indexOf(String(name || "")) >= 0;
}

function isCast(name) {
    return /^LARES-CAST-[0-9]+$/.test(String(name || ""));
}

// A CAST OUTPUT IS NEVER SWITCHED OFF AND NEVER A MIRROR while it exists (docs/contracts/panorama.md section 10): an output that is
// disabled or mirrors cannot be removed (`hyprctl output remove`: "output not found") and one disabled as it is born takes every client
// that was binding it down. A cast that mirrors has NO output (the stream takes the internal one); `mirror` in its spec is the keeper's to read.
// (CAST_STANDIN is no output: the display record the shell stands in for a TV that mirrors, PanoramaStaging.castStandIn. It IS a mirror.)
var CAST_STANDIN = "LARES-CAST-0";
function specOn(name, spec) {
    return !!spec.enabled || isCast(name);
}
function specMirror(name, spec) {
    if (isCast(name) && name !== CAST_STANDIN) return "";
    return spec.mirror || "";
}

function isInternal(name) {
    return /^(eDP|LVDS|DSI)-/.test(String(name || ""));
}

function _r(v) {               // Hyprland's rounding (std::round on positives; floor(x + 0.5) in both languages)
    return Math.floor(v + 0.5);
}

function _trim(s) {
    return String(s === undefined || s === null ? "" : s).replace(/[ \t\r\n]+/g, " ").replace(/^ | $/g, "");
}

// ---- Identity ---------------------------------------------------------------------------------------------------------

// The identity of one output among those present. The description (make model serial, from the EDID) when there is one;
// `headless:<name>` for Hyprland's headless outputs (the test env); `port:<name>` when the description is empty; and
// `<desc> @<name>` when another present output has the same description (two identical monitors with no serial).
function identityOf(out, all) {
    var d = _trim(out.description);
    if (out.castId)
        return out.castId;
    if (out.backend === "headless")
        return "headless:" + out.name;
    if (d === "")
        return "port:" + out.name;
    var twins = 0;
    for (var i = 0; i < (all || []).length; i++) {
        var o = all[i];
        if (!isIgnored(o.name) && o.backend !== "headless" && _trim(o.description) === d)
            twins++;
    }
    return twins > 1 ? d + " @" + out.name : d;
}

// name -> id for every output that counts (ignored outputs never count).
function identities(outs) {
    var m = {};
    for (var i = 0; i < outs.length; i++) {
        if (!isIgnored(outs[i].name))
            m[outs[i].name] = identityOf(outs[i], outs);
    }
    return m;
}

function _byteLess(a, b) {     // code-unit order, the same in Lua's own comparator (never localeCompare, never strcoll)
    return a < b ? -1 : (a > b ? 1 : 0);
}

function setKeyOf(ids) {
    var c = ids.slice(0);
    c.sort(_byteLess);
    return c.join(" + ");
}

function setOf(outs) {
    var ids = identities(outs), list = [];
    for (var n in ids)
        list.push(ids[n]);
    return setKeyOf(list);
}

// ---- Names ------------------------------------------------------------------------------------------------------------

function portKind(name, driver) {
    var n = String(name || "");
    if (isInternal(n)) return "laptop";
    if (/^HDMI-/.test(n)) return "hdmi";
    if (/^DP-/.test(n)) return "usbc";
    if (/^DVI-/.test(n)) return (driver === "evdi" || !driver) ? "displaylink" : "dvi";
    if (/^VGA-/.test(n)) return "vga";
    if (isCast(n)) return "cast";
    if (/^(HEADLESS|LOCK|WAYLAND)-/.test(n)) return "virtual";
    return "other";
}

function _isHexish(s) {
    return /^0x[0-9a-fA-F]+$/.test(s) || /^[0-9a-fA-F]{4,}$/.test(s);
}

// The model the display calls itself: Hyprland's `model`, else the description without make and serial. "" when it says
// nothing useful (a hex product code, as the eDP's "0x4180").
function modelName(out) {
    var m = _trim(out.model);
    if (m !== "" && !_isHexish(m))
        return m;
    var d = _trim(out.description), mk = _trim(out.make), sr = _trim(out.serial);
    if (mk !== "" && d.indexOf(mk) === 0) d = _trim(d.slice(mk.length));
    if (sr !== "" && d.length >= sr.length && d.slice(d.length - sr.length) === sr) d = _trim(d.slice(0, d.length - sr.length));
    if (d !== "" && !_isHexish(d))
        return d;
    return mk !== "" && !_isHexish(mk) ? mk : "";
}

// "Laptop" | "HDMI · Sony TV" | "DisplayLink" (decision 29: port + model). `labels` overrides PORT_LABELS per kind.
function labelOf(out, labels) {
    var kind = portKind(out.name, out.driver);
    var port = (labels && labels[kind]) || PORT_LABELS[kind];
    if (kind === "laptop")
        return port;
    var model = modelName(out);
    return model !== "" ? port + " · " + model : port;
}

// Labels for every present output, a numeral added to a label two outputs share ("HDMI · Sony TV 2").
function labels(outs, portLabels) {
    var res = {}, seen = {}, list = outs.filter(function (o) { return !isIgnored(o.name); });
    list.sort(function (a, b) { return _byteLess(a.name, b.name); });
    for (var i = 0; i < list.length; i++) {
        var l = labelOf(list[i], portLabels);
        seen[l] = (seen[l] || 0) + 1;
        res[list[i].name] = seen[l] > 1 ? l + " " + seen[l] : l;
    }
    return res;
}

// ---- Scale ------------------------------------------------------------------------------------------------------------

function _validK(k, w, h) {
    return k > 0 && (120 * w) % k === 0 && (120 * h) % k === 0;
}

// What Hyprland makes of a scale for a mode (FACT F5): k/120 with k dividing 120*W and 120*H, the nearest, ties upward.
function snapScale(s, w, h) {
    if (!(w > 0 && h > 0) || !(s > 0))
        return s;
    var k0 = _r(s * 120);
    for (var i = 0; i <= 2000; i++) {
        if (_validK(k0 + i, w, h)) return (k0 + i) / 120;
        if (k0 - i > 0 && _validK(k0 - i, w, h)) return (k0 - i) / 120;
    }
    return s;
}

// The scales the picker offers for a mode: every valid k/120 in [SCALE_MIN, SCALE_MAX] whose logical size is a whole
// number both ways (FACT F5's rule), ascending.
function scaleChoices(w, h) {
    var res = [];
    for (var k = _r(SCALE_MIN * 120); k <= _r(SCALE_MAX * 120); k++) {
        if (_validK(k, w, h))
            res.push(k / 120);
    }
    return res;
}

function _plausible(out) {
    if (!(out.physW > 0 && out.physH > 0 && out.width > 0)) return false;
    var ppmm = out.width / out.physW, diag = Math.sqrt(out.physW * out.physW + out.physH * out.physH);
    return ppmm >= PPMM_MIN && ppmm <= PPMM_MAX && diag >= DIAG_MIN && diag <= DIAG_MAX;
}

// Decision 30: the scale that shows things at the laptop's physical size, never below 1, snapped for the mode (w x h).
// "auto" (Hyprland's own PPI rule) when either size is implausible or there is no laptop to match.
function physicalScale(ext, w, h, laptop) {
    if (!laptop || !_plausible(laptop) || !_plausible(ext))
        return "auto";
    var lapLogical = laptop.width / laptop.physW / (laptop.scale > 0 ? laptop.scale : 1);
    var s = (w / ext.physW) / lapLogical;
    s = Math.max(SCALE_MIN, Math.min(SCALE_MAX, s));
    var snapped = snapScale(s, w, h);
    return snapped < SCALE_MIN ? snapScale(SCALE_MIN, w, h) : snapped;
}

// ---- Modes and sizes --------------------------------------------------------------------------------------------------

function parseMode(mode) {
    var m = /^(\d+)x(\d+)(?:@([0-9.]+))?/.exec(String(mode || ""));
    return m ? { w: +m[1], h: +m[2], r: m[3] ? +m[3] : 0 } : null;
}

function modeString(w, h, r) {
    return w + "x" + h + "@" + (Math.round(r * 100) / 100);
}

function preferredMode(out) {
    var ms = out.modes || [];
    for (var i = 0; i < ms.length; i++)
        if (ms[i].preferred) return ms[i];
    return ms.length ? ms[0] : (out.width > 0 ? { w: out.width, h: out.height, r: out.refresh } : null);
}

// The preferred size at its fastest refresh: what a never-seen display gets on a machine with NO internal panel (a desktop's monitor often
// prefers 60 Hz in its EDID). Beside a laptop the preferred mode stands.
function fastestMode(out) {
    var best = preferredMode(out), ms = out.modes || [];
    for (var i = 0; best && i < ms.length; i++)
        if (ms[i].w === best.w && ms[i].h === best.h && ms[i].r > best.r) best = ms[i];
    return best;
}

// The mode a spec asks for, as numbers (the preferred one for "preferred").
function specMode(spec, out) {
    if (spec.mode === "preferred" || !spec.mode) return preferredMode(out);
    return parseMode(spec.mode);
}

// The scale a spec asks for, as a number (an "auto" reads the live one: Hyprland chose it).
function specScale(spec, out, m) {
    if (spec.scale === "auto" || !(spec.scale > 0))
        return out.scale > 0 ? out.scale : 1;
    return m ? snapScale(spec.scale, m.w, m.h) : spec.scale;
}

// Logical size in compositor coordinates: mode / scale, swapped for a quarter turn (transforms 1 3 5 7).
function logicalSize(w, h, scale, transform) {
    var lw = _r(w / scale), lh = _r(h / scale);
    return (transform % 2) === 1 ? { w: lh, h: lw } : { w: lw, h: lh };
}

function rectOf(spec, out) {
    var m = specMode(spec, out) || { w: out.width, h: out.height };
    var sz = logicalSize(m.w, m.h, specScale(spec, out, m), spec.transform || 0);
    return { x: spec.position[0], y: spec.position[1], w: sz.w, h: sz.h };
}

// ---- Placement ----------------------------------------------------------------------------------------------------------

// Decision 3: above the anchor (the laptop), centred on its middle, sitting on top of whatever already stands in that column.
function defaultPosition(size, anchor, placed) {
    var cx = anchor.x + anchor.w / 2;
    var x = _r(cx - size.w / 2);
    var top = anchor.y;
    for (var i = 0; i < placed.length; i++) {
        var p = placed[i];
        var overlapX = p.x < x + size.w && x < p.x + p.w;
        if (overlapX && p.y < top)
            top = p.y;
    }
    return [x, top - size.h];
}

// ---- Specs ------------------------------------------------------------------------------------------------------------

function defaultSpec() {
    return { enabled: true, mode: "preferred", position: [0, 0], scale: "auto", transform: 0, mirror: false, vrr: 0,
             bitdepth: 8, cm: "srgb", sdrbrightness: 1, sdrsaturation: 1 };
}

function _copySpec(s) {
    var d = defaultSpec();
    for (var k in d) {
        if (s && s[k] !== undefined)
            d[k] = (k === "position") ? [s.position[0], s.position[1]] : s[k];
    }
    // a cast display's stream quality rides on its spec (never present on any other)
    if (s && s.cast)
        d.cast = JSON.parse(JSON.stringify(s.cast));
    return d;
}

// The settings of a known display that do not depend on its neighbours (mode, scale, rotation, colour, VRR), from the most
// recently used setup that has it (ties: the smaller set key). Null for a display no setup has.
function knownSettings(data, id) {
    var best = null, bestUsed = -1, bestKey = null;
    var keys = Object.keys(data.setups || {}).sort(_byteLess);
    for (var i = 0; i < keys.length; i++) {
        var st = data.setups[keys[i]], o = st.outputs && st.outputs[id];
        if (!o) continue;
        var used = st.used || 0;
        if (used > bestUsed) { best = o; bestUsed = used; bestKey = keys[i]; }
    }
    return best ? _copySpec(best) : null;
}

// The largest saved setup whose set is inside `ids` (the base a new combination grows from); ties: most recently used,
// then the smaller key.
function baseSetup(data, ids) {
    var have = {};
    for (var i = 0; i < ids.length; i++) have[ids[i]] = true;
    var best = null, bestN = -1, bestUsed = -1;
    var keys = Object.keys(data.setups || {}).sort(_byteLess);
    for (var j = 0; j < keys.length; j++) {
        var parts = keys[j].split(" + "), inside = true;
        for (var k = 0; k < parts.length; k++)
            if (!have[parts[k]]) { inside = false; break; }
        if (!inside) continue;
        var used = data.setups[keys[j]].used || 0;
        if (parts.length > bestN || (parts.length === bestN && used > bestUsed)) {
            best = keys[j]; bestN = parts.length; bestUsed = used;
        }
    }
    return best;
}

// Import placeholders (`port:DVI-I-1`, `placeholder: true`) take the identity of the first real display seen on their port.
// Returns { data: <a new data>, bound: [{ from, to }] }. The input is never changed.
function bindPlaceholders(data, outs) {
    var d = JSON.parse(JSON.stringify(data || {}));
    d.displays = d.displays || {}; d.setups = d.setups || {}; d.split = d.split || {};
    var ids = identities(outs), bound = [];
    for (var name in ids) {
        var ph = "port:" + name, id = ids[name];
        if (id === ph || !d.displays[ph] || !d.displays[ph].placeholder || d.displays[id])
            continue;
        var rec = d.displays[ph];
        delete d.displays[ph];
        rec.placeholder = false;
        d.displays[id] = rec;
        var newSetups = {};
        Object.keys(d.setups).forEach(function (k) {
            var st = d.setups[k];
            if (st.outputs && st.outputs[ph]) { st.outputs[id] = st.outputs[ph]; delete st.outputs[ph]; }
            var nk = setKeyOf(k.split(" + ").map(function (p) { return p === ph ? id : p; }));
            newSetups[nk] = st;
        });
        d.setups = newSetups;
        for (var w in d.split)
            if (d.split[w] === ph) d.split[w] = id;
        bound.push({ from: ph, to: id });
    }
    return { data: d, bound: bound };
}

// ---- Resolve ----------------------------------------------------------------------------------------------------------

// What every present output should be, and where the workspaces live.
//   outs  every output Hyprland lists (`monitors all`), ignored ones included (they are skipped here)
//   data  the store
// -> { setKey, kind: "setup" | "grown" | "default", base, name, specs: { <name>: SPEC with mirror as a NAME ("" | name) },
//      unknown: [ids no display record has], split: { "1".."4": name }, ids: { name: id } }
function resolve(outs, dataIn) {
    var data = dataIn || { displays: {}, setups: {}, split: {} };
    var present = outs.filter(function (o) { return !isIgnored(o.name); });
    present.sort(function (a, b) { return _byteLess(a.name, b.name); });
    var ids = identities(present), idList = [], byId = {};
    for (var i = 0; i < present.length; i++) { idList.push(ids[present[i].name]); byId[ids[present[i].name]] = present[i]; }
    var key = setKeyOf(idList);
    var setup = (data.setups || {})[key];
    var res = { setKey: key, kind: setup ? "setup" : "default", base: setup ? key : null, name: setup ? setup.name : "",
                specs: {}, unknown: [], split: {}, ids: ids };
    var internal = null;
    for (var a = 0; a < present.length; a++) if (isInternal(present[a].name)) { internal = present[a]; break; }

    var specById = {};
    if (setup) {
        for (var b = 0; b < idList.length; b++)
            specById[idList[b]] = _copySpec(setup.outputs[idList[b]]);
    } else {
        var baseKey = baseSetup(data, idList);
        if (baseKey) {
            res.kind = "grown"; res.base = baseKey;
            var base = data.setups[baseKey];
            for (var c in base.outputs) {
                specById[c] = _copySpec(base.outputs[c]);
                // A SET THAT GROWS STARTS WITH ITS EXTERNALS ON: a base's "off" was said of another set, and carried over it darkens a
                // display nobody switched off here (the laptop's own off -- "only external" -- is kept)
                if (byId[c] && !isInternal(byId[c].name)) specById[c].enabled = true;
            }
        }
    }
    for (var u = 0; u < idList.length; u++)
        if (!(data.displays || {})[idList[u]]) res.unknown.push(idList[u]);

    // Displays the base does not place: their own settings from another setup, else the never-seen default, placed above.
    var placed = [];
    for (var p = 0; p < present.length; p++) {
        var sid = ids[present[p].name];
        if (specById[sid] && specById[sid].enabled && !specById[sid].mirror)
            placed.push(rectOf(specById[sid], present[p]));
    }
    var anchorOut = internal && specById[ids[internal.name]] && specById[ids[internal.name]].enabled ? internal : null;
    var anchor = anchorOut ? rectOf(specById[ids[anchorOut.name]], anchorOut) : (placed.length ? placed[0] : null);
    if (internal && !specById[ids[internal.name]]) {
        // A never-seen internal panel keeps what it is (its 10-bit, its refresh): only its place is set.
        var si = knownSettings(data, ids[internal.name]) || specFromLive(internal, internal.name);
        si.enabled = true; si.mirror = false; si.position = [0, 0];
        specById[ids[internal.name]] = si;
        anchor = rectOf(si, internal);
        placed.push(anchor);
    }
    for (var q = 0; q < present.length; q++) {
        var o = present[q], id = ids[o.name];
        if (specById[id]) continue;
        var spec = knownSettings(data, id);
        if (!spec) {
            spec = defaultSpec();
            if (isCast(o.name)) {
                spec.mode = CAST_MODE;
                spec.scale = 1;
            } else {
                var pm = preferredMode(o), fm = fastestMode(o);
                spec.scale = pm ? physicalScale(o, pm.w, pm.h, internal) : "auto";
                if (!internal && fm && fm.r > pm.r) spec.mode = modeString(fm.w, fm.h, fm.r);
            }
        }
        spec.enabled = true; spec.mirror = false;
        var r = rectOf({ mode: spec.mode, scale: spec.scale, transform: spec.transform, position: [0, 0] }, o);
        if (!anchor) {
            spec.position = [0, 0];
            anchor = { x: 0, y: 0, w: r.w, h: r.h };
        } else {
            spec.position = defaultPosition(r, anchor, placed);
        }
        placed.push({ x: spec.position[0], y: spec.position[1], w: r.w, h: r.h });
        specById[id] = spec;
    }

    // The safety rule: never a layout with nothing enabled.
    var anyOn = false;
    for (var e in specById) if (specById[e].enabled) { anyOn = true; break; }
    if (!anyOn && present.length) {
        var first = internal || present[0];
        specById[ids[first.name]].enabled = true;
    }
    // Mirror means "of the internal panel" (decision 24); without an enabled internal it is dropped.
    var internalOn = internal && specById[ids[internal.name]].enabled;
    for (var n = 0; n < present.length; n++) {
        var s2 = _copySpec(specById[ids[present[n].name]]);
        var mir = s2.mirror && internalOn && present[n] !== internal ? internal.name : "";
        s2.mirror = mir;
        res.specs[present[n].name] = s2;
    }
    res.split = splitOf(data, present, ids, res.specs, internal);
    return res;
}

// Decisions 12 and 31. Each workspace goes to the display the split names, when it is present, on and not mirroring.
// Otherwise workspaces 1-2 go to the laptop (else the first screen on), and 3-4 to the first external that holds none yet
// (else the first external, else the laptop's side). Externals are taken left to right, then top to bottom.
function splitOf(data, present, ids, specs, internal) {
    var shown = [], byId = {};
    for (var i = 0; i < present.length; i++) {
        var s = specs[present[i].name];
        if (specOn(present[i].name, s) && specMirror(present[i].name, s) === "") { shown.push(present[i]); byId[ids[present[i].name]] = present[i].name; }
    }
    var res = {};
    if (!shown.length) return res;
    // a cast display is an external like any other (alone it takes 3 and 4), the real ones pick first
    var externals = shown.filter(function (o) { return o !== internal; });
    externals.sort(function (a, b) {
        if (isCast(a.name) !== isCast(b.name)) return isCast(a.name) ? 1 : -1;
        var pa = specs[a.name].position, pb = specs[b.name].position;
        return pa[0] !== pb[0] ? pa[0] - pb[0] : (pa[1] !== pb[1] ? pa[1] - pb[1] : _byteLess(a.name, b.name));
    });
    var home = (internal && specs[internal.name].enabled && !specs[internal.name].mirror) ? internal.name : shown[0].name;
    // with no internal panel at all the home display is one of the externals, and not "the external" that takes 3-4
    if (!internal)
        externals = externals.filter(function (o) { return o.name !== home; });
    var held = {}, w;
    var split = (data && data.split) || {};
    for (var j = 0; j < WORKSPACES.length; j++) {
        w = WORKSPACES[j];
        var nm = split[w] !== undefined ? byId[split[w]] : undefined;
        if (nm) { res[w] = nm; held[nm] = true; }
    }
    for (var k = 0; k < WORKSPACES.length; k++) {
        w = WORKSPACES[k];
        if (res[w]) continue;
        if (+w <= 2) { res[w] = home; continue; }
        if (!externals.length) { res[w] = home; continue; }
        var pick = null;
        for (var x = 0; x < externals.length; x++)
            if (!held[externals[x].name]) { pick = externals[x].name; break; }
        res[w] = pick || externals[0].name;
        held[res[w]] = true;
    }
    return res;
}

// ---- Comparing --------------------------------------------------------------------------------------------------------

// 8 | 10, or 0 when the reader cannot tell (Hyprland's Lua has no bit-depth field: liveDiff then skips it, or every plug would
// re-send the 10-bit panel's rule).
function bitdepthOf(out) {
    if (out.bitdepth > 0) return out.bitdepth;
    if (out.currentFormat === undefined || out.currentFormat === null || out.currentFormat === "") return 0;
    return /2101010|16161616/.test(String(out.currentFormat)) ? 10 : 8;
}

// The live output already is what the spec asks (the engine sends a rule only where this is false: no needless modeset).
// "auto" scale matches whatever Hyprland chose. Returns "" when equal, else the first field that differs.
function liveDiff(out, spec) {
    var enabled = out.enabled !== false;
    if (!specOn(out.name, spec)) return enabled ? "enabled" : "";
    if (!enabled) return "enabled";
    var mir = specMirror(out.name, spec);
    if ((out.mirrorOf || "") !== mir) return "mirror";
    if (mir !== "") return "";          // a mirror's own mode, place and scale do not show
    var m = specMode(spec, out);
    if (m && (out.width !== m.w || out.height !== m.h)) return "mode";
    if (m && m.r > 0 && Math.abs(out.refresh - m.r) > REFRESH_TOL) return "refresh";
    if (spec.scale !== "auto" && Math.abs(out.scale - specScale(spec, out, m)) > SCALE_TOL) return "scale";
    if (out.x !== spec.position[0] || out.y !== spec.position[1]) return "position";
    if ((out.transform || 0) !== (spec.transform || 0)) return "transform";
    if (out.vrr !== undefined && (+out.vrr || 0) !== (+spec.vrr || 0) && out.vrrCapable) return "vrr";
    var bd = bitdepthOf(out);
    if (bd !== 0 && bd !== (spec.bitdepth || 8)) return "bitdepth";
    if (out.cm !== undefined && String(out.cm) !== String(spec.cm || "srgb")) return "cm";
    return "";
}

// After a trial: every planned output is there and is what was asked. -> { ok, what: "" | "<name>:<field>" | "<name>:gone" }
function verify(outs, plan) {
    var by = {};
    for (var i = 0; i < outs.length; i++) by[outs[i].name] = outs[i];
    var names = Object.keys(plan.specs).sort(_byteLess);
    for (var j = 0; j < names.length; j++) {
        var o = by[names[j]];
        if (!o) return { ok: false, what: names[j] + ":gone" };
        var d = liveDiff(o, plan.specs[names[j]]);
        if (d !== "" && d !== "vrr" && d !== "cm" && d !== "bitdepth")
            return { ok: false, what: names[j] + ":" + d };
    }
    return { ok: true, what: "" };
}

// The live state of an output as a spec (the popup's staged edits start here).
function specFromLive(out, internalName) {
    var s = defaultSpec();
    s.enabled = out.enabled !== false;
    s.mode = out.width > 0 ? modeString(out.width, out.height, out.refresh) : "preferred";
    s.position = [out.x, out.y];
    s.scale = out.scale > 0 ? out.scale : 1;
    s.transform = (out.transform || 0) % 4;
    s.mirror = !!(out.mirrorOf && out.mirrorOf === internalName);
    s.vrr = +out.vrr || 0;
    s.bitdepth = bitdepthOf(out) || 8;
    s.cm = out.cm || "srgb";
    s.sdrbrightness = out.sdrbrightness > 0 ? out.sdrbrightness : 1;
    s.sdrsaturation = out.sdrsaturation > 0 ? out.sdrsaturation : 1;
    return s;
}

// What changed between two specs, field names in a fixed order.
function specChanges(a, b) {
    var res = [], keys = ["enabled", "mode", "position", "scale", "transform", "mirror", "vrr", "bitdepth", "cm",
                          "sdrbrightness", "sdrsaturation", "cast"];
    for (var i = 0; i < keys.length; i++) {
        var k = keys[i];
        var x = a[k], y = b[k];
        if (k === "position") { if (x[0] !== y[0] || x[1] !== y[1]) res.push(k); }
        else if (k === "cast") { if (JSON.stringify(x || null) !== JSON.stringify(y || null)) res.push(k); }
        else if (typeof x === "number" && typeof y === "number") { if (Math.abs(x - y) > SCALE_TOL) res.push(k); }
        else if (x !== y) res.push(k);
    }
    return res;
}

// ---- Lua -------------------------------------------------------------------------------------------------------------

function _luaStr(s) {
    return '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n") + '"';
}

// The hl.monitor table for one output (complete: FACT F1, a partial rule merges with stale fields).
function luaRule(name, spec) {
    var parts = ["output = " + _luaStr(name)];
    if (!specOn(name, spec))
        return "{ " + parts.concat(["disabled = true"]).join(", ") + " }";
    parts.push("disabled = false");
    parts.push("mode = " + _luaStr(spec.mode || "preferred"));
    parts.push("position = " + _luaStr(spec.position[0] + "x" + spec.position[1]));
    parts.push("scale = " + (spec.scale === "auto" ? '"auto"' : String(spec.scale)));
    parts.push("transform = " + (spec.transform || 0));
    parts.push("mirror = " + _luaStr(specMirror(name, spec)));
    parts.push("vrr = " + (spec.vrr || 0));
    parts.push("bitdepth = " + (spec.bitdepth || 8));
    parts.push("cm = " + _luaStr(spec.cm || "srgb"));
    parts.push("sdrbrightness = " + (spec.sdrbrightness || 1));
    parts.push("sdrsaturation = " + (spec.sdrsaturation || 1));
    return "{ " + parts.join(", ") + " }";
}

// ---- Diagnostics --------------------------------------------------------------------------------------------------------

// Decision 23. facts: { now, outputs, plan (resolve's, or null), drm: { connectors: [{ name, driver, status }],
//   displayLinkUsb: bool, displayLinkSince: ms, evdiLoaded, displayLinkActive }, gpuMode, verdict, connectedSince: { name: ms } }
// -> [{ id, kind, severity: "info" | "warn" | "error", title, body, command, action, output }]
function diagnose(facts) {
    var res = [], f = facts || {}, drm = f.drm || {}, now = f.now || 0;
    var conns = drm.connectors || [];
    var hasEvdi = conns.some(function (c) { return c.driver === "evdi"; });
    var evdiShown = conns.some(function (c) { return c.driver === "evdi" && c.status === "connected"; });
    if (drm.displayLinkUsb && now - (drm.displayLinkSince || now) >= 8000) {
        if (!drm.displayLinkActive)
            res.push({ id: "dl-service", kind: "displaylink", severity: "warn", title: "DisplayLink dock, no picture",
                       body: "The DisplayLink service is not running.",
                       command: "sudo systemctl enable --now displaylink.service", action: "", output: "" });
        else if (!drm.evdiLoaded && !hasEvdi)
            res.push({ id: "dl-evdi", kind: "displaylink", severity: "warn", title: "DisplayLink dock, no picture",
                       body: "The evdi kernel module is not loaded.", command: "sudo modprobe evdi", action: "", output: "" });
        else if (hasEvdi && !evdiShown)
            res.push({ id: "dl-nodisplay", kind: "displaylink", severity: "info", title: "DisplayLink dock",
                       body: "No display is connected to the dock.", command: "", action: "", output: "" });
    }
    var outs = f.outputs || [], byName = {};
    for (var i = 0; i < outs.length; i++) byName[outs[i].name] = outs[i];
    for (var j = 0; j < conns.length; j++) {
        var c = conns[j];
        if (c.status !== "connected" || isIgnored(c.name)) continue;
        var o = byName[c.name];
        var askedOff = f.plan && f.plan.specs && f.plan.specs[c.name] && !f.plan.specs[c.name].enabled;
        var since = (f.connectedSince || {})[c.name];
        if ((!o || o.enabled === false) && !askedOff && since !== undefined && now - since >= 3000)
            res.push({ id: "off-" + c.name, kind: "connected-off", severity: "warn", title: "A display is connected but off",
                       body: labelOf({ name: c.name, driver: c.driver }) + " is plugged in, but the desktop does not use it.",
                       command: "", action: "enable", output: c.name });
        // switched off in this setup: no fault, but said, with the way back (it was a parked chip and not a word)
        else if (o && o.enabled === false && askedOff)
            res.push({ id: "setoff-" + c.name, kind: "setup-off", severity: "info", title: "A display is switched off",
                       body: labelOf({ name: c.name, driver: c.driver }) + " is off in this setup.",
                       command: "", action: "enable", output: c.name });
    }
    if (f.verdict && String(f.verdict).indexOf("failed:") === 0)
        res.push({ id: "mode-failed", kind: "mode-failed", severity: "error", title: "The new settings did not take",
                   body: "The display reported something else (" + String(f.verdict).slice(7) + "); the old settings are back.",
                   command: "", action: "", output: "" });
    if (f.gpuMode === "integrated")
        res.push({ id: "hdmi-nvidia", kind: "hdmi-integrated", severity: "info", title: "HDMI is off",
                   body: "The HDMI port is wired to the NVIDIA card, which Integrated mode switches off.",
                   command: "", action: "", output: "" });
    return res;
}
