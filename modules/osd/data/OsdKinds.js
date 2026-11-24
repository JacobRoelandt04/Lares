.pragma library

// =============================================================================
// OsdKinds.js -- the OSD's pure half: the kind table, the perceptual step, the
// volume boost gate, the request queue's rules, and the diffs that turn a
// service's rows into events. No Qt in here: it loads under node.
//
// KINDS (CONTRACT section 0). A USER kind comes from a key or an action and
// pre-empts at once; an EVENT kind comes from the system and is queued. `power`
// is silicon's (the CPU profile, the GPU mode and the charge limit changed outside
// its popup, and what the MUX flow has to tell): an event kind that carries its own
// glyph, title, detail and the name of a Theme token for the glyph's colour. Every
// kind is `{ id, user, defaultMs, priority }`: `defaultMs` is what an EVENT kind
// shows for when neither the request nor osd.jsonc's `kinds.<kind>.ms` names a time (a
// USER kind takes the config's `dismissMs`). `priority` orders event
// kinds when a host has to pick; the queue itself is FIFO. `caption` is the
// dictation's (round 5: a window take's or a voice ask's live words, kinds/
// OsdCaption.qml): an event kind its service renews every second while the take
// runs (in place: one card, its words swapped) and withdraws (OsdService.withdraw)
// when the take ends; anything else that comes takes the slot like over any event,
// and the next renewal brings the words back.
//
// THE STEP IS PERCEIVED, NOT LINEAR. A backlight's raw value is a linear
// duty cycle and the eye is not linear: on a 400-step panel one raw step at
// the dim end is a visible jump and 5 % of raw at the top is invisible. A key
// climbs a LADDER of rungs (twenty at 5 %) laid along the curve
// raw = max * (rung / rungs) ^ gamma: the dim end gets fine raw steps, the
// bright end coarse ones, every press moves the same PERCEIVED amount -- and
// the OSD shows the RUNG (5 % per press), not the raw percentage.
//
// THE ENDS. The bottom rung is the TRUE minimum level (floorRaw, 1) and a
// held key stops there; true 0 (the panel off) is a FRESH press at the bottom,
// like volume's boost gate, downwards.
//
// THE BOOST GATE. Held and pressed are different gestures. A key held from
// 70 % runs up to 100 % and stops there (the repeat must not shoot through
// 100 into an ear-splitting boost); a FRESH press that begins at 100 % or more
// is the user asking for boost, and the whole gesture, repeats included, may
// go up to boostMax.
// =============================================================================

var KINDS = [
    { id: "volume",     user: true,  defaultMs: 2000, priority: 10 },
    { id: "mic",        user: true,  defaultMs: 2000, priority: 10 },
    { id: "brightness", user: true,  defaultMs: 2000, priority: 10 },
    { id: "kbd",        user: true,  defaultMs: 2000, priority: 10 },
    { id: "lockkeys",   user: true,  defaultMs: 2000, priority: 10 },
    { id: "layout",     user: true,  defaultMs: 2000, priority: 10 },
    { id: "theme",      user: true,  defaultMs: 2000, priority: 10 },
    { id: "track",      user: false, defaultMs: 3500, priority: 2 },
    { id: "bluetooth",  user: false, defaultMs: 3000, priority: 4 },
    { id: "network",    user: false, defaultMs: 3000, priority: 3 },
    { id: "vpn",        user: false, defaultMs: 3000, priority: 3 },
    // aerial's two: the tunnel the module raised by itself on a Public network, and a Bluetooth device's battery at 20 % / 10 %
    { id: "autoTunnel", user: false, defaultMs: 3500, priority: 3 },
    { id: "btLow",      user: false, defaultMs: 3500, priority: 4 },
    { id: "capture",    user: false, defaultMs: 3500, priority: 5 },
    { id: "battery",    user: false, defaultMs: 4000, priority: 6 },
    { id: "power",      user: false, defaultMs: 3000, priority: 5 },
    { id: "caption",    user: false, defaultMs: 3000, priority: 7 },
    { id: "generic",    user: false, defaultMs: 3500, priority: 1 }
];

function kindIds() {
    return KINDS.map(function (k) { return k.id; });
}

function kindInfo(id) {
    for (var i = 0; i < KINDS.length; i++)
        if (KINDS[i].id === id)
            return KINDS[i];
    return null;
}

function isKind(id) {
    return kindInfo(id) !== null;
}

function isUserKind(id) {
    var k = kindInfo(id);
    return k !== null && k.user;
}

// Whether a request is the answer to something the user just did (osd.jsonc `fullscreen: "keys"` shows these alone): a user kind, a
// request that says so, a media key's track card, a capture, the dictation's words (its take is the user's).
function byUser(req) {
    return isUserKind(req.kind) || req.user === true || req.kind === "capture" || req.kind === "caption"
        || (req.kind === "track" && eventOf(req) === "key");
}

// The events a kind can be narrowed to (osd.jsonc `kinds.<kind>.events`); a kind that is not here has none.
var EVENTS = {
    volume: ["key", "external", "device"],
    mic: ["key", "external", "device"],
    track: ["key", "change"],
    network: ["connected", "lost", "failed", "wired"],
    vpn: ["up", "down"],
    bluetooth: ["connected", "disconnected"],
    battery: ["low", "full"],
    capture: ["shot", "rec-start", "rec-stop", "copied"]
};

// Which of its kind's events a request is, "" for one that is none of them (always shown). `req.event` is the source's own word where
// the facts do not say it (another default device; a cover that landed on a key's card).
function eventOf(req) {
    var w = "";
    if (typeof req.event === "string")
        w = req.event;
    else if (req.kind === "volume" || req.kind === "mic")
        w = req.source;
    else if (req.kind === "track")
        w = req.source === "key" ? "key" : req.source === "external" ? "change" : "";
    else if (req.kind === "network")
        w = !req.net ? "" : req.net.via === "wired" ? "wired" : req.net.state;
    else if (req.kind === "vpn")
        w = req.vpn ? req.vpn.state : "";
    else if (req.kind === "bluetooth")
        w = req.bt ? req.bt.state : "";
    else if (req.kind === "battery")
        w = req.battery ? req.battery.event : "";
    else if (req.kind === "capture")
        w = req.capture ? req.capture.what : "";
    return EVENTS[req.kind] !== undefined && EVENTS[req.kind].indexOf(w) >= 0 ? w : "";
}

// The key a kind's request carries when the caller names none (CONTRACT
// section 0: volume "out", mic "in"; one instance of any other kind).
function defaultKey(kind) {
    if (kind === "volume") return "out";
    if (kind === "mic") return "in";
    return kind;
}

// -----------------------------------------------------------------------------
// The brightness ladder
// -----------------------------------------------------------------------------

function _clamp(v, lo, hi) {
    return Math.max(lo, Math.min(hi, v));
}

// `o` = { gamma, step, fineStep, floorRaw } (OsdConfig's brightness); a field that is not there takes the
// default. One reading of the numbers, so the rungs, the figure and the keys cannot disagree.
function _ladderSteps(o) {
    var st = o && o.step > 0 ? o.step : 0.05;
    return Math.max(1, Math.round(1 / st));
}

// The rungs a key climbs: the raw value at positions 0 .. N (N = 1 / step: twenty at 5 %).
//   rung 0   true 0, the panel off
//   rung 1   `floorRaw`: the TRUE minimum level, the dimmest the panel shows (true brightness level 1,
//            to read a screen in the dark and spare an OLED). The curve alone would put rung 1 at max * step^gamma:
//            1 on a 400-step panel, 48 on a 19 200-step one -- the bottom rung is the floor on both
//   rung i   round(max * (i / N) ^ gamma), the perceptual curve (strictly climbing where the panel has room)
//   rung N   max
// floorRaw 0 asks for no stop at the bottom: rung 1 is the curve's and a plain press reaches 0.
function brightnessRungs(max, gamma, step, floorRaw) {
    var m = Math.max(1, Math.round(max));
    var g = gamma === undefined || !(gamma > 0) ? 2 : gamma;
    var n = _ladderSteps({ step: step });
    var fl = floorRaw === undefined ? 1 : Math.max(0, Math.round(floorRaw));
    var rungs = [0];
    for (var i = 1; i <= n; i++) {
        var v = Math.round(m * Math.pow(i / n, g));
        if (i === 1 && fl >= 1)
            v = Math.min(fl, m);
        v = Math.max(v, rungs[i - 1] + 1);
        rungs.push(Math.min(v, m));
    }
    rungs[n] = m;
    return rungs;
}

function _rungsOf(max, o) {
    return brightnessRungs(max, o ? o.gamma : undefined, o ? o.step : undefined, o ? o.floorRaw : undefined);
}

// A raw value as a position on the ladder: whole at a rung, fractional (linear) between two (0 .. N).
function brightnessPos(raw, rungs) {
    var n = rungs.length - 1;
    if (!(raw > rungs[0]))
        return 0;
    if (raw >= rungs[n])
        return n;
    for (var i = 0; i < n; i++) {
        if (raw < rungs[i + 1]) {
            var span = rungs[i + 1] - rungs[i];
            return span > 0 ? i + (raw - rungs[i]) / span : i;
        }
    }
    return n;
}

// A position back to a raw value.
function brightnessRawAt(pos, rungs) {
    var n = rungs.length - 1;
    var p = _clamp(pos, 0, n);
    var i = Math.min(n - 1, Math.floor(p + 1e-9));
    return Math.round(rungs[i] + (p - i) * (rungs[i + 1] - rungs[i]));
}

// The brightness AS THE OSD SHOWS IT, 0 .. 1: the rung over N -- 5 points per press whatever the raw numbers do
// (a constant change whatever the slider's step count; the accurate percentage is not needed). The ball and the figure both read it.
function brightnessLevel(raw, max, o) {
    var rungs = _rungsOf(max, o);
    return brightnessPos(_clamp(Math.round(raw), 0, rungs[rungs.length - 1]), rungs) / (rungs.length - 1);
}

// The raw value for a level on the slider (a drag, 0 .. 1). A drag never blacks the screen -- true 0 is the key's,
// a second press -- unless floorRaw is 0.
function brightnessFromLevel(level, max, o) {
    var rungs = _rungsOf(max, o);
    var raw = brightnessRawAt(_clamp(level, 0, 1) * (rungs.length - 1), rungs);
    return o && o.floorRaw === 0 ? raw : Math.max(rungs[1], raw);
}

// THE ZERO GATE. Held and pressed are different gestures. A key held from 70 % runs down to the bottom rung and
// stops there (the repeat must not shoot through into a black screen); a FRESH press that begins at the bottom
// rung -- or under it -- is the user asking for true 0, and the gesture may go to it. Decided at the press and
// kept for its repeats: a held key that reaches the bottom does not decide again.
function brightnessZeroOpens(raw, max, dir, o) {
    if (!(dir < 0) || (o && o.floorRaw === 0))
        return false;
    return Math.round(raw) <= _rungsOf(max, o)[1];
}

// One key press. raw: the current raw value; max: its maximum; dir: +1 | -1; fine: the Shift step, a fraction of
// a rung (fineStep / step) -- the coarse step lands on the next rung in the direction, from a rung or from
// anywhere between two (hypridle's dim, a script: the key is then back on the ladder); `zero`: the gesture opened
// true 0 (brightnessZeroOpens at its press). Returns the new raw value, always an integer in [0, max].
function brightnessStep(raw, max, dir, fine, o, zero) {
    var rungs = _rungsOf(max, o);
    var n = rungs.length - 1;
    var m = rungs[n];
    var fs = o && o.fineStep > 0 ? o.fineStep : 0.01;
    var r = _clamp(Math.round(raw), 0, m);
    var d = dir < 0 ? -1 : 1;
    var pos = brightnessPos(r, rungs);
    var np;
    if (fine)
        np = pos + d * fs * n;
    else
        np = d > 0 ? Math.floor(pos + 1e-9) + 1 : Math.ceil(pos - 1e-9) - 1;
    var out = brightnessRawAt(_clamp(np, 0, n), rungs);
    // One press always moves: at the dim end a fine step can round to where it started.
    if (d > 0 && out <= r)
        out = Math.min(m, r + 1);
    if (d < 0 && out >= r)
        out = Math.max(0, r - 1);
    if (d < 0 && !(o && o.floorRaw === 0) && !zero) {
        out = Math.max(rungs[1], out);
        // Already at or under the bottom rung (an external write): a key down never raises it.
        if (out > r)
            out = r;
    }
    return out;
}

// -----------------------------------------------------------------------------
// The boost gate
// -----------------------------------------------------------------------------

function newBoostState() {
    return { cap: 1.0 };
}

// verb: "press" (a fresh key-down) | "repeat" (the repeat timer's step) |
// "release". value: the volume now (0..boostMax). Returns the new state with
// `cap`, the highest value this gesture may reach: a press that starts at 1.0
// or more (an epsilon under it counts: 0.999 is "at 100 %") opens the boost
// for the gesture, any other press caps it at 1.0, a repeat keeps what the
// press decided, a release resets.
function boostGate(state, verb, value, boostMax) {
    var bm = boostMax === undefined ? 1.5 : boostMax;
    var cap = state && state.cap !== undefined ? state.cap : 1.0;
    if (verb === "press")
        cap = value >= 0.999 ? bm : 1.0;
    else if (verb === "release")
        cap = 1.0;
    // A value that is already above the cap (set by an app, or by the slider)
    // is never pulled down by a step UP: the cap bounds what a key adds.
    return { cap: Math.max(cap, 0) };
}

// The next volume for a key step: `dir` +1 | -1, `step` linear (0.02).
// Going up is bounded by the gate's cap (and never lowers a value already
// above it); going down is bounded by 0.
function volumeStep(state, value, dir, step, boostMax) {
    var bm = boostMax === undefined ? 1.5 : boostMax;
    var cap = Math.min(state && state.cap !== undefined ? state.cap : 1.0, bm);
    var v;
    if (dir > 0) {
        v = Math.min(value + step, cap);
        if (v < value)
            v = value;
    } else {
        v = Math.max(0, value - step);
    }
    // Float dust (0.1 + 0.02 * 3): the figure is whole hundredths.
    return Math.round(v * 1000) / 1000;
}

// -----------------------------------------------------------------------------
// What an open module says for itself
// -----------------------------------------------------------------------------

// The now-playing card does not come out over the player: the player IS the song, so the card
// stays away while the player module is open in any way (mini, normal, normal + sidepanel)
// and appears only when that module is closed. `flags` is what the shell knows about open
// modules ({ playerOpen }, OsdService's); a host that knows nothing passes none and
// nothing is held back. Only the OSD's own surface asks: a kind routed to a desktop
// notification is another surface and stays.
//
// NOR WHILE THE SESSION IS LOCKED: the lock's own card already says what plays, so the OSD's would be redundant, and `flags.locked` (the shell's lock owner,
// bound onto OsdService.locked like playerOpen) holds the now-playing card back too -- the media key's as well.
function suppressedBy(req, flags) {
    return !!req && !!flags && (flags.playerOpen === true || flags.locked === true) && req.kind === "track";
}

// -----------------------------------------------------------------------------
// The queue (event kinds): FIFO, one entry per kind+key, capped
// -----------------------------------------------------------------------------

function coalesceKey(req) {
    return String(req.kind) + ":" + String(req.key === undefined ? "" : req.key);
}

// Adds `req`; an entry with the same kind+key is REPLACED where it stands
// (the newest facts, the oldest place), otherwise it joins the tail; past
// `cap` the OLDEST entries are dropped. Returns a new array.
function queuePush(queue, req, cap) {
    var q = (queue || []).slice();
    var k = coalesceKey(req);
    var at = -1;
    for (var i = 0; i < q.length; i++)
        if (coalesceKey(q[i]) === k) { at = i; break; }
    if (at >= 0)
        q[at] = req;
    else
        q.push(req);
    var c = cap === undefined ? 3 : Math.max(1, cap);
    while (q.length > c)
        q.shift();
    return q;
}

// { head, rest } of a queue; head is null when it is empty.
function queueShift(queue) {
    var q = queue || [];
    return { head: q.length > 0 ? q[0] : null, rest: q.slice(1) };
}

// -----------------------------------------------------------------------------
// Diffs: rows in, events out
// -----------------------------------------------------------------------------

function _byId(rows) {
    var m = {};
    for (var i = 0; i < (rows || []).length; i++)
        if (rows[i])
            m[rows[i].id] = rows[i];
    return m;
}

function _btEvent(row, state) {
    var bat = row.batteryAvailable ? Math.round(row.batteryPct) : -1;
    return {
        id: row.id,
        name: row.name || "",
        icon: row.icon || "",
        battery: bat,
        state: state
    };
}

// What the diffs below read: bt rows (`{id, name, icon, connected, batteryPct, batteryAvailable}`)
// before and after: a device that BECAME connected, or became disconnected, or
// vanished while connected. Pairing, trusting, renaming and a battery change
// say nothing. Returns [{ id, name, icon, battery (-1 when unknown), state }].
function diffBt(prevRows, rows) {
    var before = _byId(prevRows);
    var now = _byId(rows);
    var out = [];
    var i, id;
    for (i = 0; i < (rows || []).length; i++) {
        var r = rows[i];
        if (!r)
            continue;
        var was = before[r.id] ? !!before[r.id].connected : false;
        if (r.connected && !was)
            out.push(_btEvent(r, "connected"));
        else if (!r.connected && was)
            out.push(_btEvent(r, "disconnected"));
    }
    for (id in before)
        if (!now[id] && before[id].connected)
            out.push(_btEvent(before[id], "disconnected"));
    return out;
}

// The AerialService's Bluetooth devices (`bt.devices`) as those rows: a row per device the service knows (the rings), `batteryPct`
// its figure (-1 = none reported).
function btRowsOf(bt) {
    var devs = bt && bt.devices ? bt.devices : [];
    var out = [];
    for (var i = 0; i < devs.length; i++) {
        var d = devs[i];
        if (!d)
            continue;
        out.push({ id: d.address, name: d.name || "", icon: iconOfKind(d.kind), connected: !!d.connected,
                   batteryPct: typeof d.battery === "number" && d.battery >= 0 ? d.battery : 0, batteryAvailable: typeof d.battery === "number" && d.battery >= 0 });
    }
    return out;
}

// the freedesktop icon name a Bluetooth device kind carries on the card (the card draws a Bluetooth glyph for any; the name is the request's own)
function iconOfKind(kind) {
    switch (kind) {
    case "earbuds": case "headset": return "audio-headset";
    case "speaker": return "audio-speakers";
    case "phone": return "phone";
    case "computer": return "computer";
    case "mouse": return "input-mouse";
    case "keyboard": return "input-keyboard";
    case "gamepad": return "input-gaming";
    case "watch": return "smartwatch";
    }
    return "bluetooth";
}

// The AerialService's facts as the NetModel-shaped reading `diffNet` takes -- { networks: [{ id, ssid, connected, signal 0..1, failReason }],
// vpns: [{ id, name, up }], devices: [{ kind: "wired", name, connected, networkName }] } -- from `wifi`, `wired` and `proton`. `failReason` is
// the service's own words (`Net.failReason`), only for a network whose state is "failed" ("needsSecret" is the popup's password field, no
// failure); the VPN is Proton's one tunnel, named by its server.
function netModelOf(facts) {
    var f = facts || {};
    var nets = f.wifi && f.wifi.networks ? f.wifi.networks : [];
    var networks = [];
    for (var i = 0; i < nets.length; i++) {
        var n = nets[i];
        if (!n)
            continue;
        networks.push({ id: n.key, ssid: n.ssid || "", connected: !!n.connected, signal: (Number(n.signal) || 0) / 100,
                        failReason: n.state === "failed" ? (n.failReason || "Connection failed") : "" });
    }
    var jacks = f.wired && f.wired.jacks ? f.wired.jacks : [];
    var devices = [];
    for (var j = 0; j < jacks.length; j++)
        if (jacks[j])
            devices.push({ kind: "wired", name: jacks[j].iface || ("wired" + j), connected: !!jacks[j].connected, networkName: "" });
    var p = f.proton || {};
    var vpns = [];
    if (p.installed !== false && (p.state === "up" || p.state === "connecting" || p.state === "disconnecting" || p.server))
        vpns.push({ id: "proton", name: p.server && p.server.name ? p.server.name : "Proton VPN", up: p.state === "up" });
    return { networks: networks, vpns: vpns, devices: devices };
}

// The connected wifi network of a NetModel `model`: { ssid, signal 0..100 } or
// null.
function wifiOf(model) {
    var nets = model && model.networks ? model.networks : [];
    for (var i = 0; i < nets.length; i++)
        if (nets[i] && nets[i].connected)
            return { ssid: nets[i].ssid || "", signal: Math.round(100 * (Number(nets[i].signal) || 0)) };
    return null;
}

// The wired devices of a NetModel `model` by device name: { name (what the card calls it), connected }. A wired
// device carries ONE profile on itself (`networkName`, "Wired connection 1"); with none it is called "Ethernet".
function wiredOf(model) {
    var devs = model && model.devices ? model.devices : [];
    var out = {};
    for (var i = 0; i < devs.length; i++)
        if (devs[i] && devs[i].kind === "wired")
            out[devs[i].name || ("wired" + i)] = { name: devs[i].networkName || "Ethernet", connected: !!devs[i].connected };
    return out;
}

// The Wi-Fi networks of a NetModel `model` that carry a connection FAILURE the user should be told: by network id,
// { ssid, reasonId }. "needsecret" is not one -- the popup opens its password field for it.
function failuresOf(model) {
    var nets = model && model.networks ? model.networks : [];
    var out = {};
    for (var i = 0; i < nets.length; i++) {
        var n = nets[i];
        if (n && n.failReason && n.failReason !== "needsecret")
            out[n.id !== undefined ? n.id : (n.ssid || "")] = { ssid: n.ssid || "", reasonId: String(n.failReason) };
    }
    return out;
}

// NetModel before and after: wifi connected / lost / FAILED to connect, a wired link up / down, and VPN up / down. `prev`
// null (the first build) says nothing. Returns
// [{ kind: "network", net: { ssid, signal, state[, via: "wired"][, reasonId] } }, { kind: "vpn", vpn: { name, state } }].
// A Wi-Fi event carries no `via` (the card's default is Wi-Fi); a wired one says `via: "wired"`, `signal: 0`; a failure is
// state "failed" with the reason (the service's words: `reasonId` carries them) -- the NetSource puts them on the card.
function diffNet(prev, model) {
    var out = [];
    if (!prev || !model)
        return out;
    var a = wifiOf(prev), b = wifiOf(model);
    if (b && (!a || a.ssid !== b.ssid))
        out.push({ kind: "network", net: { ssid: b.ssid, signal: b.signal, state: "connected" } });
    else if (a && !b)
        out.push({ kind: "network", net: { ssid: a.ssid, signal: 0, state: "lost" } });

    // an attempt that FAILED: the network's failure reason appeared (or changed) since the last reading
    var failedBefore = failuresOf(prev);
    var failedNow = failuresOf(model);
    var fid;
    for (fid in failedNow)
        if (!failedBefore[fid] || failedBefore[fid].reasonId !== failedNow[fid].reasonId)
            out.push({ kind: "network", net: { ssid: failedNow[fid].ssid, signal: 0, state: "failed", reasonId: failedNow[fid].reasonId } });

    // a cable: the device's link came up, or went (a device that vanished while connected went with it)
    var wasWired = wiredOf(prev);
    var nowWired = wiredOf(model);
    var dev;
    for (dev in nowWired) {
        var wasUp = wasWired[dev] ? wasWired[dev].connected : false;
        if (nowWired[dev].connected && !wasUp)
            out.push({ kind: "network", net: { ssid: nowWired[dev].name, signal: 0, state: "connected", via: "wired" } });
        else if (!nowWired[dev].connected && wasUp)
            out.push({ kind: "network", net: { ssid: wasWired[dev].name, signal: 0, state: "lost", via: "wired" } });
    }
    for (dev in wasWired)
        if (!nowWired[dev] && wasWired[dev].connected)
            out.push({ kind: "network", net: { ssid: wasWired[dev].name, signal: 0, state: "lost", via: "wired" } });

    var before = _byId(prev.vpns);
    var now = _byId(model.vpns);
    var id;
    for (id in now) {
        var up = !!now[id].up;
        var was = before[id] ? !!before[id].up : false;
        // a switch to another server while up is a connection too, told with the NEW server's name
        if (up && (!was || (before[id].name || "") !== (now[id].name || "")))
            out.push({ kind: "vpn", vpn: { name: now[id].name || "", state: "up" } });
        else if (!up && was)
            out.push({ kind: "vpn", vpn: { name: now[id].name || "", state: "down" } });
    }
    for (id in before)
        if (!now[id] && before[id].up)
            out.push({ kind: "vpn", vpn: { name: before[id].name || "", state: "down" } });
    return out;
}

// -----------------------------------------------------------------------------
// Keyboard layout
// -----------------------------------------------------------------------------

// Hyprland's `activelayout>>KEYBOARD,LAYOUT NAME`: the keyboard's name has no
// comma, the layout name may. Returns { keyboard, layout } or null.
function parseActiveLayout(data) {
    var s = String(data === undefined || data === null ? "" : data);
    var i = s.indexOf(",");
    if (i <= 0)
        return null;
    var layout = s.substring(i + 1);
    if (layout.length === 0)
        return null;
    return { keyboard: s.substring(0, i), layout: layout };
}

// The short code shown for a layout name: the config's table first, then
// "English (US)" -> "US", then the first two letters ("Belgian" -> "BE").
function layoutCode(name, codes) {
    var n = String(name === undefined || name === null ? "" : name);
    if (codes && codes[n] !== undefined && String(codes[n]).length > 0)
        return String(codes[n]);
    var m = /\(([^)]+)\)\s*$/.exec(n);
    if (m)
        return m[1].toUpperCase();
    var letters = n.replace(/[^A-Za-z]/g, "");
    return letters.length > 0 ? letters.substring(0, 2).toUpperCase() : "??";
}

// -----------------------------------------------------------------------------
// hyprctl getoption
// -----------------------------------------------------------------------------

// `hyprctl getoption input:repeat_delay` prints "int: 600\nset: false".
function parseIntOption(text) {
    var m = /^\s*int:\s*(-?\d+)/m.exec(String(text === undefined || text === null ? "" : text));
    return m ? parseInt(m[1], 10) : -1;
}

// -----------------------------------------------------------------------------
// osd.jsonc (CONTRACT section 9): the defaults and the merge
// -----------------------------------------------------------------------------

var ROUTES = ["osd", "notification", "off"];

function defaultConfig() {
    var kinds = {};
    for (var i = 0; i < KINDS.length; i++)
        kinds[KINDS[i].id] = { route: KINDS[i].id === "generic" ? "off" : "osd", ms: 0 };
    // THE BATTERY (one route per fact). The OSD's card says 15 % ("low") and the pack reaching its charge limit
    // ("full"); the notification source (modules/notifications/sources, "battery") speaks at 8 % and 3 % with Hibernate, and
    // for a runaway drain, and does not say 15 % or "Charged to 80 %" by default (its `levels` / `limitReached`).
    return {
        spot: { bar: "right", along: 0.5 },
        screen: "focused",
        fullscreen: "pill",
        dismissMs: 2000,
        resumeMinMs: 800,
        queueCap: 3,
        repeat: { delayMs: "auto", rateHz: "auto" },
        volume: { step: 0.02, boostMax: 1.5 },
        mic: { step: 0.05 },
        // device "" = the panel's own (PanelBacklight: the backlight of the GPU that drives the eDP); a name here overrides it
        brightness: { device: "", step: 0.05, fineStep: 0.01, gamma: 2.0, floorRaw: 1, target: "pointer" },
        media: { keys: "mpd" },
        capture: { dir: "~/Pictures/Screenshots", name: "shot-%Y%m%d-%H%M%S.png", copy: true, openCommand: ["xdg-open", "{path}"],
                   editCommand: [], click: "edit" },
        kbd: { device: "asus::kbd_backlight" },
        // the keys the lock keys card shows, in order
        lockkeys: { keys: ["caps", "num"] },
        layout: { keyboard: "main", codes: { "English (US)": "US", "Belgian": "BE" } },
        kinds: kinds
    };
}

function _num(v, lo, hi, dflt) {
    var n = Number(v);
    if (v === null || v === undefined || v === "" || typeof v === "boolean" || !isFinite(n) || n < lo || n > hi)
        return dflt;
    return n;
}

function _int(v, lo, hi, dflt) {
    var n = _num(v, lo, hi, NaN);
    return isFinite(n) && Math.floor(n) === n ? n : dflt;
}

function _str(v, dflt) {
    return typeof v === "string" && v.length > 0 ? v : dflt;
}

function _word(v, words, dflt) {
    return words.indexOf(v) >= 0 ? v : dflt;
}

// A command: a list of words, none of them empty at its head. Empty is an answer only where the default is.
function _argv(v, dflt) {
    if (!Array.isArray(v) || !v.every(function (w) { return typeof w === "string"; }))
        return dflt;
    return (v.length === 0 ? dflt.length === 0 : v[0].length > 0) ? v.slice() : dflt;
}

function _obj(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v) ? v : {};
}

// "auto" or a whole number in range.
function _autoOr(v, lo, hi, dflt) {
    if (v === "auto")
        return "auto";
    return _int(v, lo, hi, dflt);
}

// `obj` is the parsed osd.jsonc (any shape); every key is optional and a bad
// value falls back to its default: a typo in one key never costs the others.
function mergeConfig(obj) {
    var o = _obj(obj), d = defaultConfig();
    var out = d;

    var sp = _obj(o.spot);
    if (typeof sp.corner === "string" && sp.corner.length > 0)
        out.spot = { corner: sp.corner };
    else if (sp.bar !== undefined || sp.along !== undefined)
        out.spot = { bar: _str(sp.bar, d.spot.bar), along: _num(sp.along, 0, 1, d.spot.along) };

    out.screen = _str(o.screen, d.screen);
    out.fullscreen = _word(o.fullscreen, ["pill", "keys", "suppress"], d.fullscreen);
    out.dismissMs = _int(o.dismissMs, 200, 600000, d.dismissMs);
    out.resumeMinMs = _int(o.resumeMinMs, 0, 600000, d.resumeMinMs);
    out.queueCap = _int(o.queueCap, 1, 20, d.queueCap);

    var rp = _obj(o.repeat);
    out.repeat = { delayMs: _autoOr(rp.delayMs, 50, 5000, "auto"), rateHz: _autoOr(rp.rateHz, 1, 200, "auto") };

    var vo = _obj(o.volume);
    out.volume = { step: _num(vo.step, 0.001, 0.5, d.volume.step), boostMax: _num(vo.boostMax, 1, 3, d.volume.boostMax) };
    out.mic = { step: _num(_obj(o.mic).step, 0.001, 0.5, d.mic.step) };

    var br = _obj(o.brightness);
    out.brightness = {
        device: _str(br.device, d.brightness.device),
        step: _num(br.step, 0.001, 0.5, d.brightness.step),
        fineStep: _num(br.fineStep, 0.001, 0.5, d.brightness.fineStep),
        gamma: _num(br.gamma, 0.5, 4, d.brightness.gamma),
        floorRaw: _int(br.floorRaw, 0, 1000, d.brightness.floorRaw),
        target: _word(br.target, ["pointer", "focused", "panel"], d.brightness.target)
    };
    out.media = { keys: _word(_obj(o.media).keys, ["mpd", "auto"], d.media.keys) };
    // (dir, name and copy are shot.sh's: it reads the file itself)
    var ca = _obj(o.capture);
    out.capture = {
        dir: _str(ca.dir, d.capture.dir),
        name: typeof ca.name === "string" && /^[^\/]+\.png$/.test(ca.name) ? ca.name : d.capture.name,
        copy: typeof ca.copy === "boolean" ? ca.copy : d.capture.copy,
        openCommand: _argv(ca.openCommand, d.capture.openCommand),
        editCommand: _argv(ca.editCommand, d.capture.editCommand),
        click: _word(ca.click, ["edit", "open", "none"], d.capture.click)
    };
    // ("" is an answer too: this machine has no keyboard light, and nothing watches for one)
    out.kbd = { device: _obj(o.kbd).device === "" ? "" : _str(_obj(o.kbd).device, d.kbd.device) };
    // a list of "caps" / "num", each once; anything else (or nothing left) is the default pair
    var lk = _obj(o.lockkeys).keys, lkeys = [];
    if (lk && typeof lk.length === "number" && typeof lk !== "string")
        for (var li = 0; li < lk.length; li++)
            if ((lk[li] === "caps" || lk[li] === "num") && lkeys.indexOf(lk[li]) < 0)
                lkeys.push(lk[li]);
    out.lockkeys = { keys: lkeys.length > 0 ? lkeys : d.lockkeys.keys };

    var ly = _obj(o.layout), codes = d.layout.codes, uc = _obj(ly.codes);
    for (var name in uc)
        if (typeof uc[name] === "string" && uc[name].length > 0)
            codes[name] = uc[name];
    out.layout = { keyboard: _str(ly.keyboard, d.layout.keyboard), codes: codes };

    var uk = _obj(o.kinds);
    for (var id in out.kinds) {
        var k = _obj(uk[id]);
        out.kinds[id] = {
            route: _word(k.route, ROUTES, out.kinds[id].route),
            ms: _int(k.ms, 0, 600000, 0)
        };
        if (EVENTS[id] !== undefined && Array.isArray(k.events))
            out.kinds[id].events = k.events.filter(function (w) { return EVENTS[id].indexOf(w) >= 0; });
    }
    return out;
}

// -----------------------------------------------------------------------------
// The payload (CONTRACT section 1): its shape check, a plausible sample per kind,
// and the words a "notification" route says
// -----------------------------------------------------------------------------

var DEVICE_TYPES = ["speaker", "headphone", "headset", "hdmi", "bluetooth", "mic", "display"];

function _is(v, t) {
    return typeof v === t;
}

function _isInt(v) {
    return _is(v, "number") && isFinite(v) && Math.floor(v) === v;
}

function _oneOf(v, list) {
    return list.indexOf(v) >= 0;
}

// The problems of a request that has been through OsdService.show (a CONTRACT
// section 1 payload): [] when it is well-formed. A kind's own object is
// required for that kind; fields a kind does not use are not looked at.
function payloadProblems(req) {
    var p = [];
    if (!req || typeof req !== "object")
        return ["not an object"];
    if (!isKind(req.kind))
        return ["kind " + JSON.stringify(req.kind) + " is not a kind"];
    var k = req.kind;
    if (!_is(req.key, "string") || req.key.length === 0) p.push("key");
    if (!_isInt(req.serial) || req.serial < 1) p.push("serial");
    if (!_is(req.source, "string") || req.source.length === 0) p.push("source");
    if (!_is(req.user, "boolean")) p.push("user");
    if (!_is(req.ms, "number") || req.ms < 0) p.push("ms");

    if (k === "volume" || k === "mic" || k === "brightness") {
        if (!_is(req.max, "number") || req.max < 1) p.push("max");
        if (!_is(req.value, "number") || req.value < 0 || req.value > Math.max(1, req.max || 1) + 1e-9) p.push("value");
        if (!_is(req.muted, "boolean")) p.push("muted");
        if (req.muteFlip !== undefined && !_is(req.muteFlip, "boolean")) p.push("muteFlip");
        if (!_is(req.boost, "boolean")) p.push("boost");
        if (!req.device || !_oneOf(req.device.type, DEVICE_TYPES) || !_is(req.device.name, "string")) p.push("device");
    } else if (k === "kbd") {
        if (!_isInt(req.stops) || req.stops < 2) p.push("stops");
        if (!_isInt(req.stop) || req.stop < 0 || req.stop >= (req.stops || 0)) p.push("stop");
    } else if (k === "lockkeys") {
        if (!req.keys || !_is(req.keys.caps, "boolean") || !_is(req.keys.num, "boolean")) p.push("keys");
        if (!_oneOf(req.changed, ["caps", "num", ""])) p.push("changed");
    } else if (k === "layout") {
        if (!req.layout || !_is(req.layout.code, "string") || !_is(req.layout.name, "string")) p.push("layout");
    } else if (k === "theme") {
        if (!req.theme || !_is(req.theme.name, "string") || !_oneOf(req.theme.mode, ["light", "dark"])) p.push("theme");
    } else if (k === "track") {
        var t = req.track;
        if (!t || !_is(t.title, "string") || !_is(t.artist, "string") || !_is(t.album, "string") || !_is(t.art, "string")
                || !_oneOf(t.state, ["play", "pause", "stop"]) || !_oneOf(t.action, ["next", "prev", "toggle", "stop", ""])) p.push("track");
    } else if (k === "bluetooth") {
        var b = req.bt;
        if (!b || !_is(b.name, "string") || !_is(b.icon, "string") || !_is(b.battery, "number")
                || b.battery < -1 || b.battery > 100 || !_oneOf(b.state, ["connected", "disconnected"])) p.push("bt");
    } else if (k === "network") {
        var n = req.net;
        if (!n || !_is(n.ssid, "string") || !_is(n.signal, "number") || n.signal < 0 || n.signal > 100
                || !_oneOf(n.state, ["connected", "lost", "failed"])
                || (n.via !== undefined && !_oneOf(n.via, ["wifi", "wired"]))
                || (n.reason !== undefined && !_is(n.reason, "string"))) p.push("net");
    } else if (k === "vpn") {
        var v = req.vpn;
        if (!v || !_is(v.name, "string") || !_oneOf(v.state, ["up", "down"])) p.push("vpn");
    } else if (k === "autoTunnel") {
        var t2 = req.tunnel;
        if (!t2 || !_is(t2.country, "string")) p.push("tunnel");
    } else if (k === "btLow") {
        var l = req.bt;
        if (!l || !_is(l.name, "string") || !_is(l.icon, "string") || !_is(l.battery, "number") || l.battery < 0 || l.battery > 100) p.push("bt");
    } else if (k === "capture") {
        var c = req.capture;
        if (!c || !_oneOf(c.what, ["shot", "rec-start", "rec-stop", "copied"]) || !_is(c.path, "string")
                || !_is(c.thumb, "string") || !_is(c.copied, "boolean") || !_is(c.label, "string")) p.push("capture");
    } else if (k === "battery") {
        var q = req.battery;
        if (!q || !_isInt(q.percent) || q.percent < 0 || q.percent > 100 || !_oneOf(q.event, ["low", "full"])) p.push("battery");
    } else if (k === "power") {
        // a title is required (a pill that says nothing is no event); the token is "" (the accent) or a Theme token's
        // NAME -- whether the theme has it is for the theme's own file to say (silicon's data cases check theirs)
        if (!_is(req.glyph, "string") || !_is(req.title, "string") || req.title.length === 0 || !_is(req.detail, "string")
                || !_is(req.colorToken, "string") || !/^([A-Za-z][A-Za-z0-9]*)?$/.test(req.colorToken)) p.push("power");
    } else if (k === "generic") {
        if (!_is(req.glyph, "string") || !_is(req.title, "string") || !_is(req.detail, "string") || !_is(req.colorToken, "string")) p.push("generic");
    }
    return p;
}

// A plausible request of each kind (the IPC `test`, the mockup's buttons).
function sampleRequest(kind) {
    switch (kind) {
    case "volume":
        return { kind: "volume", key: "out", value: 0.42, max: 1, muted: false, boost: false, device: { type: "headphone", name: "Headset X4" } };
    case "mic":
        return { kind: "mic", key: "in", value: 0.6, max: 1, muted: true, boost: false, device: { type: "mic", name: "Built-in Microphone" } };
    case "brightness":
        return { kind: "brightness", key: "brightness", value: 0.55, max: 1, muted: false, boost: false, device: { type: "display", name: "intel_backlight" } };
    case "kbd":
        return { kind: "kbd", key: "kbd", stop: 2, stops: 4 };
    case "lockkeys":
        return { kind: "lockkeys", key: "lockkeys", keys: { caps: true, num: true }, changed: "caps" };
    case "layout":
        return { kind: "layout", key: "layout", layout: { code: "BE", name: "Belgian" } };
    case "theme":
        return { kind: "theme", key: "theme", theme: { name: "eva", mode: "dark" } };
    case "track":
        return { kind: "track", key: "track", track: { title: "Teardrop", artist: "Massive Attack", album: "Mezzanine", art: "", state: "play", action: "next" } };
    case "bluetooth":
        return { kind: "bluetooth", key: "/org/bluez/hci0/dev_AA", bt: { name: "Headset X4", icon: "audio-headset", battery: 82, state: "connected" } };
    case "network":
        return { kind: "network", key: "network", net: { ssid: "Home", signal: 74, state: "connected" } };
    case "vpn":
        return { kind: "vpn", key: "vpn", vpn: { name: "ProtonVPN NL", state: "up" } };
    case "autoTunnel":
        return { kind: "autoTunnel", key: "autoTunnel", tunnel: { country: "NL" } };
    case "btLow":
        return { kind: "btLow", key: "/org/bluez/hci0/dev_AA", bt: { name: "Headset X4", icon: "audio-headset", battery: 20 } };
    case "capture":
        return { kind: "capture", key: "shot", capture: { what: "shot", path: "", thumb: "", copied: true, label: "" } };
    case "battery":
        return { kind: "battery", key: "battery", battery: { percent: 15, event: "low" } };
    case "power":
        return { kind: "power", key: "silicon-profile", glyph: "\u{F140B}", title: "Performance", detail: "Power profile", colorToken: "profilePerformance" };
    case "generic":
        return { kind: "generic", key: "generic", glyph: "\u{F0026}", title: "Hello", detail: "A third-party event", colorToken: "" };
    case "caption":
        return { kind: "caption", key: "dictation", ms: 6000, caption: { mode: "source", head: "Transcribing Zen", live: "and that is why the river runs",
                 lines: ["The town was built on the old trade road.", "Its market drew people from three valleys away,", "and the bridge was the only way across."] } };
    }
    return null;
}

// What a "notification" route posts: { title, body }.
function notificationText(req) {
    var pct = function (v) { return Math.round(100 * (Number(v) || 0)) + " %"; };
    var dev = req.device && req.device.name ? req.device.name : "";
    switch (req.kind) {
    case "volume":
        return { title: "Volume", body: (req.muted ? "Muted" : pct(req.value)) + (dev ? " · " + dev : "") };
    case "mic":
        return { title: "Microphone", body: req.muted ? "Muted" : pct(req.value) };
    case "brightness":
        return { title: "Brightness", body: pct(req.value) };
    case "kbd":
        return { title: "Keyboard light", body: req.stop === 0 ? "Off" : req.stop + " / " + ((req.stops || 4) - 1) };
    case "lockkeys":
        if (req.changed === "num")
            return { title: "Num lock", body: req.keys && req.keys.num ? "On" : "Off" };
        return { title: "Caps lock", body: req.keys && req.keys.caps ? "On" : "Off" };
    case "layout":
        return { title: "Keyboard layout", body: req.layout ? req.layout.name : "" };
    case "theme":
        return { title: "Theme", body: req.theme ? String(req.theme.name).replace(/-/g, " ") + " " + req.theme.mode : "" };   // dashes shown as spaces
    case "track": {
        var t = req.track || {};
        return { title: t.title || "", body: [t.artist, t.album].filter(function (x) { return !!x; }).join(" — ") };
    }
    case "bluetooth": {
        var b = req.bt || {};
        var up = b.state === "connected";
        return { title: b.name || "Bluetooth", body: (up ? "Connected" : "Disconnected") + (up && b.battery >= 0 ? " · " + b.battery + " %" : "") };
    }
    case "network": {
        var n = req.net || {};
        if (n.via === "wired")
            return { title: "Ethernet", body: n.state === "connected" ? "Connected to " + n.ssid : "Disconnected from " + n.ssid };
        if (n.state === "failed")
            return { title: "Wi-Fi", body: (n.reason || "Connection failed") + (n.ssid ? " · " + n.ssid : "") };
        return n.state === "lost" ? { title: "Wi-Fi", body: "Connection lost" } : { title: "Wi-Fi", body: "Connected to " + n.ssid };
    }
    case "vpn": {
        var v = req.vpn || {};
        return { title: v.name || "VPN", body: v.state === "up" ? "Connected" : "Disconnected" };
    }
    case "autoTunnel":
        return { title: "VPN", body: "Public network: tunnel raised" + (req.tunnel && req.tunnel.country ? " via " + req.tunnel.country : "") };
    case "btLow": {
        var lb = req.bt || {};
        return { title: lb.name || "Bluetooth", body: "Battery low · " + Math.round(lb.battery) + " %" };
    }
    case "capture": {
        var c = req.capture || {};
        if (c.what === "rec-start") return { title: "Recording", body: "Started" };
        if (c.what === "rec-stop") return { title: "Recording", body: "Saved" + (c.path ? " · " + c.path : "") };
        if (c.what === "copied") return { title: "Copied", body: c.label || "" };
        return { title: "Screenshot", body: c.copied ? "Saved and copied" : "Saved" + (c.path ? " · " + c.path : "") };
    }
    case "battery": {
        var q = req.battery || {};
        return { title: q.event === "full" ? "Battery full" : "Battery low", body: q.percent + " %" };
    }
    case "power":
    case "generic":
        return { title: req.title || "", body: req.detail || "" };
    }
    return { title: req.kind, body: "" };
}
