.pragma library

// =============================================================================
// AudioModel.js -- the audio popup's facts, pure: what a `pactl -f json list` and a `pw-dump Node` say, joined with what the
// Pipewire binding says now, as the rows the five tabs draw; and whether a change that was asked for has taken. No QML, no
// process, no clock of its own: every function runs under node.
//
// WHAT JOINS WHAT. Three sources describe one thing with three numbers:
//   pactl `index`        is PipeWire's `object.serial`, NOT the node id (a stream's index 52 can be node 51). `pactl
//                        move-sink-input` wants the index.
//   the node id          is what `pw-cli destroy` wants, and what a link names.
//   `node.name`          joins a device across all of them, and across a restart of its node (a profile change makes new ids).
// So a stream's key is its serial and a device's key is its name; every id is read from the row, never carried across a refresh.
//
// WHERE A STREAM REALLY GOES is the LINK GRAPH, not pactl's `sink`: the line on the popup draws what the audio does. pactl's field is the
// fallback for a stream that has no link yet (a corked one).
// =============================================================================

// ---- figures ----------------------------------------------------------------------------------------------------------------

// Quickshell's `volume` is pactl's percent / 100; PulseAudio's cubic curve makes that 60 log10 dB.
function dB(v) {
    return v <= 0 ? -Infinity : 60 * Math.log(v) / Math.LN10;
}
function percentText(v) {
    return Math.round(v * 100) + " %";
}
function dbText(v) {
    const d = dB(v);
    if (d === -Infinity)
        return "-∞ dB";
    const r = Math.round(d * 10) / 10;
    return (r === 0 ? "0.0" : r.toFixed(1)) + " dB";
}
// The volume a pactl block says, per channel, in the channel order of the map: [fractions].
function volumesOf(vol) {
    const out = [];
    if (!vol)
        return out;
    for (const ch in vol) {
        const p = parseFloat(String(vol[ch].value_percent));
        out.push(isNaN(p) ? 0 : p / 100);
    }
    return out;
}
function channelsOf(vol) {
    return vol ? Object.keys(vol) : [];
}
// "front-left" -> "Front Left", the way pavucontrol prints a channel.
function channelLabel(ch) {
    return String(ch).split("-").map(s => s.length > 0 ? s.charAt(0).toUpperCase() + s.slice(1) : s).join(" ");
}
function average(a) {
    if (!a || a.length === 0)
        return 0;
    let s = 0;
    for (let i = 0; i < a.length; i++)
        s += a[i];
    return s / a.length;
}
// "12000 usec" -> 12 (ms)
function offsetMs(text) {
    const n = parseFloat(String(text));
    return isNaN(n) ? 0 : n / 1000;
}

// ---- what a device is ---------------------------------------------------------------------------------------------------------

// A device's class, for AudioGlyphs' table.
function deviceType(props, activePortType) {
    const p = props || {};
    const form = String(p["device.form_factor"] || "");
    const bus = String(p["device.bus"] || p["device.api"] || "");
    const icon = String(p["device.icon_name"] || "");
    const port = String(activePortType || "").toLowerCase();
    if (form === "headset" || port === "headset")
        return "headset";
    if (form === "headphone" || form === "headphones" || port === "headphones" || /headphone/.test(icon))
        return "headphone";
    if (form === "hands-free" || form === "handset")
        return "hands-free";
    if (form === "phone")
        return "phone";
    if (form === "portable")
        return "portable";
    if (form === "car")
        return "car";
    if (port === "hdmi" || /hdmi|video-display/.test(icon))
        return "hdmi";
    if (bus === "bluetooth" || /bluez/.test(bus))
        return "bluetooth";
    return "speaker";
}

function isMonitorSource(s) {
    return !!s && ((s.properties && s.properties["device.class"] === "monitor") || String(s.name).endsWith(".monitor"));
}
function hasFlag(o, f) {
    return !!o && !!o.flags && o.flags.indexOf(f) >= 0;
}

// A stream no application owns: pavucontrol's "Virtual Streams" (a loopback, a filter chain).
function streamIsVirtual(si) {
    const p = (si && si.properties) || {};
    return !p["application.name"] && !p["application.process.binary"] || !!p["pulse.module.id"] || p["node.virtual"] === "true";
}
// What the shell itself adds to the graph: its level meters and its test tone are not the user's streams.
function isOwnStream(props) {
    const p = props || {};
    return p["application.name"] === "Quickshell Peak Detect" || p["media.name"] === "lares-audio-test-tone";
}

// ---- the join --------------------------------------------------------------------------------------------------------------------

function _nodeIndex(nodes) {
    const byName = {}, bySerial = {}, byId = {};
    for (let i = 0; i < nodes.length; i++) {
        const n = nodes[i];
        if (!n)
            continue;
        byId[n.id] = n;
        if (n.name)
            byName[n.name] = n;
        const s = n.properties ? n.properties["object.serial"] : undefined;
        if (s !== undefined)
            bySerial[String(s)] = n;
    }
    return { byName: byName, bySerial: bySerial, byId: byId };
}

// [{ source: id, target: id }] -> { stream node id: [device node ids] }, both ways. A peak meter's link is not a route.
function _routes(links, idx) {
    const out = {};
    function add(a, b) {
        (out[a] = out[a] || []).push(b);
    }
    for (let i = 0; i < links.length; i++) {
        const l = links[i], s = idx.byId[l.source], t = idx.byId[l.target];
        if (s && isOwnStream(s.properties) || t && isOwnStream(t.properties))
            continue;
        add(l.source, l.target);
        add(l.target, l.source);
    }
    return out;
}

function _channels(raw, node) {
    return raw.volume ? channelsOf(raw.volume) : [];
}

function _portsOf(raw, card) {
    const out = [];
    const cp = card && card.ports ? card.ports : {};
    const list = (raw && raw.ports) || [];
    for (let i = 0; i < list.length; i++) {
        const p = list[i];
        const a = String(p.availability || "");
        out.push({
            name: p.name, description: p.description || p.name, type: p.type || "",
            available: a === "not available" ? false : a === "available" ? true : null,
            offsetMs: cp[p.name] ? offsetMs(cp[p.name].latency_offset) : 0
        });
    }
    return out;
}

function _device(raw, kind, ctx) {
    const props = raw.properties || {};
    const card = ctx.cardsByName[props["device.name"]] || null;
    const ports = _portsOf(raw, card);
    const active = raw.active_port || "";
    let activeOffset = 0, activeType = "";
    for (let i = 0; i < ports.length; i++)
        if (ports[i].name === active) {
            activeOffset = ports[i].offsetMs;
            activeType = ports[i].type;
        }
    const node = ctx.idx.byName[raw.name] || null;
    const label = ctx.labels && ctx.labels[kind + ":" + raw.name] ? ctx.labels[kind + ":" + raw.name] : "";
    const dump = ctx.dump[raw.name] || null;
    const monitor = kind === "source" && isMonitorSource(raw);
    const state = dump ? dump.state : String(raw.state || "").toLowerCase();
    const row = {
        key: "d:" + kind + ":" + raw.name, kind: kind, name: raw.name, serial: raw.index, node: node,
        id: node ? node.id : -1,
        description: label !== "" ? label : (raw.description || raw.name), originalDescription: raw.description || raw.name, renamed: label !== "",
        cardDescription: card && card.properties ? String(card.properties["device.description"] || "") : "", shortName: "", subtitle: "",
        type: deviceType(props, activeType), isMonitor: monitor, monitorOf: monitor ? (raw.monitor_source || "") : "",
        isHardware: hasFlag(raw, "HARDWARE"), digital: hasFlag(raw, "SET_FORMATS"), formats: raw.formats || [],
        muted: raw.mute === true, volumes: volumesOf(raw.volume), channels: _channels(raw, node),
        baseVolume: raw.base_volume ? parseFloat(String(raw.base_volume.value_percent)) / 100 : 1,
        canDecibel: hasFlag(raw, "DECIBEL_VOLUME"),
        ports: ports, activePort: active, activeOffsetMs: activeOffset, cardName: props["device.name"] || "",
        state: state, error: dump ? (dump.error || "") : "", isDefault: raw.name === (kind === "sink" ? ctx.defaultSink : ctx.defaultSource),
        streams: 0
    };
    return row;
}

function _stream(raw, kind, ctx, devices) {
    const props = raw.properties || {};
    const serial = raw.index;
    const node = ctx.idx.bySerial[String(serial)] || null;
    const peers = node ? (ctx.routes[node.id] || []) : [];
    let dev = null;
    for (let i = 0; i < peers.length && !dev; i++) {
        const pn = ctx.idx.byId[peers[i]];
        if (pn)
            for (let j = 0; j < devices.length; j++)
                if (devices[j].name === pn.name)
                    dev = devices[j];
    }
    const pactlIndex = kind === "playback" ? raw.sink : raw.source;
    let onLink = !!dev;
    if (!dev)
        for (let j = 0; j < devices.length; j++)
            if (devices[j].serial === pactlIndex)
                dev = devices[j];
    const title = String(props["media.name"] || "");
    const app = String(props["application.name"] || props["node.name"] || "Unknown");
    return {
        key: "s:" + serial, kind: kind, serial: serial, node: node, id: node ? node.id : -1,
        app: app, title: title === app ? "" : title, icon: String(props["application.icon_name"] || props["application.icon-name"] || ""),
        binary: String(props["application.process.binary"] || ""),
        isVirtual: streamIsVirtual(raw), corked: raw.corked === true,
        muted: raw.mute === true, volumes: volumesOf(raw.volume), channels: _channels(raw, node),
        device: dev ? dev.name : "", deviceDescription: dev ? dev.shortName : "", deviceType: dev ? dev.type : "speaker", linked: onLink,
        pinned: !!props["target.object"] && String(props["target.object"]) !== "-1"
    };
}

// ---- what a device is called ----------------------------------------------------------------------------------------------------
//
// THE REAL NAMES ARE LONG AND START WITH THE SAME WORDS: "Meteor Lake-P HD Audio Controller HDMI / DisplayPort 3 Output (Stereo)", four of them on this laptop, so a
// socket read "Meteor Lake-P HD..." four times. The card's name goes, because it tells them apart from nothing; it stays only where all that is left is a profile's
// generic words on the card's one device ("ACME AUDIO DAC PRO Analog Stereo" -> "ACME AUDIO DAC PRO"). "(Stereo)" and a trailing "Output" / "Input" say nothing either.
function shortName(description, cardText, siblings) {
    const text = String(description || "");
    const mon = /^Monitor of /.test(text);
    let s = mon ? text.slice(11) : text;
    if (cardText !== "" && s.indexOf(cardText) === 0) {
        const rest = s.slice(cardText.length).trim();
        s = rest !== "" && (siblings > 1 || !/^((Analog|Digital|Multichannel|Pro)\s*)?(Stereo|Mono|Surround.*|Audio)?$/.test(rest)) ? rest : cardText;
    }
    s = s.replace(/\s*\((Stereo|Mono)\)$/, "").replace(/\s+(Output|Input)$/, "");
    return (mon ? "Monitor of " : "") + s;
}
function _named(devices) {
    const count = {};
    for (let i = 0; i < devices.length; i++) {
        const c = devices[i].cardName;
        if (c !== "" && !devices[i].isMonitor)
            count[c] = (count[c] || 0) + 1;
    }
    for (let i = 0; i < devices.length; i++) {
        const d = devices[i];
        d.shortName = d.renamed ? d.description : shortName(d.originalDescription, d.cardDescription, count[d.cardName] || 0);
        d.subtitle = d.renamed ? d.originalDescription : d.cardDescription !== d.shortName ? d.cardDescription : "";
    }
    return devices;
}

function _card(raw, ctx) {
    const props = raw.properties || {};
    const profiles = [];
    const pr = raw.profiles || {};
    for (const name in pr) {
        const p = pr[name];
        profiles.push({ name: name, description: p.description || name, available: p.available !== false, sinks: p.sinks || 0, sources: p.sources || 0, priority: p.priority || 0 });
    }
    profiles.sort((a, b) => b.priority - a.priority);
    const codecs = ctx.codecs[raw.name] || null;
    return {
        key: "c:" + raw.name, kind: "card", name: raw.name, serial: raw.index,
        description: props["device.description"] || raw.name,
        type: deviceType(props, ""), isBluez: String(raw.name).indexOf("bluez") === 0 || props["device.api"] === "bluez5",
        profiles: profiles, activeProfile: raw.active_profile || "",
        codecs: codecs ? codecs.list : [], activeCodec: codecs ? codecs.active : ""
    };
}

// What the binding alone can say, in pactl's shape: the rows of a popup opened while the server does not answer pactl (no snapshot has ever landed). Volumes
// still go through the binding; ports, profiles and moves have nothing to work with and say so.
function _nodesSnapshot(nodes, links, idx) {
    const out = { sinks: [], sources: [], sink_inputs: [], source_outputs: [], cards: [] };
    const routes = _routes(links || [], idx);
    for (let i = 0; i < nodes.length; i++) {
        const n = nodes[i];
        if (!n || !n.properties || isOwnStream(n.properties))
            continue;
        const cls = String(n.properties["media.class"] || "");
        const serial = Number(n.properties["object.serial"]);
        const raw = { index: serial, name: n.name, description: n.description || n.name, properties: n.properties, flags: ["DECIBEL_VOLUME"], ports: [], active_port: "", formats: [], state: "" };
        if (cls.indexOf("Audio/Sink") === 0)
            out.sinks.push(raw);
        else if (cls.indexOf("Audio/Source") === 0)
            out.sources.push(raw);
        else if (cls === "Stream/Output/Audio")
            out.sink_inputs.push(Object.assign(raw, { sink: _peerSerial(n, routes, idx) }));
        else if (cls === "Stream/Input/Audio")
            out.source_outputs.push(Object.assign(raw, { source: _peerSerial(n, routes, idx) }));
    }
    return out;
}
function _peerSerial(n, routes, idx) {
    const p = (routes[n.id] || [])[0];
    const peer = p !== undefined ? idx.byId[p] : null;
    return peer && peer.properties ? Number(peer.properties["object.serial"]) : -1;
}

// `snap`    the JSON of `pactl -f json list`, parsed; null when none has landed (then the binding's nodes make the rows)
// `nodes`   the Pipewire nodes as the binding has them ({ id, name, properties })
// `links`   [{ source, target }] node ids
// `opts`    { defaultSink, defaultSource (names), dump: { name: { state, error } } (pw-dump), labels: { "sink:<name>": text },
//             codecs: { card: { list, active } }, roles: [role rows] }
// `opts.hide`: device names the lists leave out (audio.jsonc hide; `*` is any text), unless the device is the default or a stream is on it.
function _hidden(name, globs) {
    for (let i = 0; i < globs.length; i++) {
        const re = "^" + String(globs[i]).split("*").map(p => p.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*") + "$";
        if (new RegExp(re).test(name))
            return true;
    }
    return false;
}

function merge(snap, nodes, links, opts) {
    const o = opts || {};
    const idx = _nodeIndex(nodes || []);
    const ctx = {
        idx: idx, routes: _routes(links || [], idx), dump: o.dump || {}, labels: o.labels || {}, codecs: o.codecs || {},
        defaultSink: o.defaultSink || "", defaultSource: o.defaultSource || "", cardsByName: {}
    };
    const s = snap || _nodesSnapshot(nodes || [], links || [], idx);
    const cardsRaw = s.cards || [];
    for (let i = 0; i < cardsRaw.length; i++)
        ctx.cardsByName[cardsRaw[i].name] = cardsRaw[i];
    const sinks = _named((s.sinks || []).map(x => _device(x, "sink", ctx)));
    const sources = _named((s.sources || []).map(x => _device(x, "source", ctx)));
    const playback = (s.sink_inputs || []).filter(x => !isOwnStream(x.properties)).map(x => _stream(x, "playback", ctx, sinks));
    const recording = (s.source_outputs || []).filter(x => !isOwnStream(x.properties)).map(x => _stream(x, "recording", ctx, sources));
    for (let i = 0; i < playback.length; i++)
        for (let j = 0; j < sinks.length; j++)
            if (sinks[j].name === playback[i].device)
                sinks[j].streams++;
    for (let i = 0; i < recording.length; i++)
        for (let j = 0; j < sources.length; j++)
            if (sources[j].name === recording[i].device)
                sources[j].streams++;
    const hide = o.hide || [];
    const shown = d => hide.length === 0 || d.isDefault || d.streams > 0 || !_hidden(d.name, hide);
    return { sinks: sinks.filter(shown), sources: sources.filter(shown), playback: playback, recording: recording, cards: cardsRaw.map(x => _card(x, ctx)) };
}

// `pw-dump Node` -> { name: { state, error } }. Tolerant: a broken dump is no information.
function parseDump(text) {
    const out = {};
    let a = null;
    try {
        a = JSON.parse(text);
    } catch (e) {
        return out;
    }
    if (!Array.isArray(a))
        return out;
    for (let i = 0; i < a.length; i++) {
        const info = a[i] && a[i].info;
        if (!info || !info.props || !info.props["node.name"])
            continue;
        out[info.props["node.name"]] = { state: String(info.state || ""), error: info.error ? String(info.error) : "" };
    }
    return out;
}

// `pw-metadata -n route-settings` output -> the System Sounds row's facts, or null when the server keeps no such entry.
//   update: id:0 key:'restore.stream.Output/Audio.media.role:Notification' value:'{"mute":false, ...}' type:'Spa:String:JSON'
var EVENT_ROLE_KEY = "restore.stream.Output/Audio.media.role:Notification";
function parseRole(text) {
    const lines = String(text).split("\n");
    for (let i = 0; i < lines.length; i++) {
        const l = lines[i];
        if (l.indexOf("key:'" + EVENT_ROLE_KEY + "'") < 0)
            continue;
        const m = l.match(/value:'(.*)' type:/);
        if (!m)
            continue;
        try {
            const v = JSON.parse(m[1]);
            return { key: "r:event", kind: "role", app: "System Sounds", title: "", muted: v.mute === true, volumes: v.volumes || [], channels: (v.channels || []).map(channelFromShort) };
        } catch (e) {
            return null;
        }
    }
    return null;
}
var _SHORT = { FL: "front-left", FR: "front-right", MONO: "mono", FC: "front-center", RL: "rear-left", RR: "rear-right", SL: "side-left", SR: "side-right", LFE: "lfe" };
function channelFromShort(c) {
    return _SHORT[c] || String(c);
}
function roleValue(volumes, channels, muted) {
    const shortOf = {};
    for (const k in _SHORT)
        shortOf[_SHORT[k]] = k;
    return JSON.stringify({ mute: muted === true, volumes: volumes, channels: channels.map(c => shortOf[c] || c) });
}

// ---- the filters of the five tabs (pavucontrol's "Show:" boxes, its own words) -----------------------------------------------------

var FILTERS = {
    playback: ["All Streams", "Applications", "Virtual Streams"],
    recording: ["All Streams", "Applications", "Virtual Streams"],
    sinks: ["All Output Devices", "Hardware Output Devices", "Virtual Output Devices"],
    sources: ["All Input Devices", "All Except Monitors", "Hardware Input Devices", "Virtual Input Devices", "Monitors"]
};
// The default of each box, pavucontrol's.
var FILTER_DEFAULT = { playback: 1, recording: 1, sinks: 0, sources: 1 };

function applyFilter(section, rows, filter) {
    const f = filter;
    if (section === "playback" || section === "recording") {
        if (f === 1)
            return rows.filter(r => !r.isVirtual);
        if (f === 2)
            return rows.filter(r => r.isVirtual);
        return rows;
    }
    if (section === "sinks") {
        if (f === 1)
            return rows.filter(r => r.isHardware);
        if (f === 2)
            return rows.filter(r => !r.isHardware);
        return rows;
    }
    if (f === 1)
        return rows.filter(r => !r.isMonitor);
    if (f === 2)
        return rows.filter(r => r.isHardware && !r.isMonitor);
    if (f === 3)
        return rows.filter(r => !r.isHardware && !r.isMonitor);
    if (f === 4)
        return rows.filter(r => r.isMonitor);
    return rows;
}

// ---- the health of the backend --------------------------------------------------------------------------------------------------

// What a finished child means. `code` is the exit status, `stderr` what it said.
//   124  `timeout` ended it at its deadline; 137 or 9 `timeout -k` had to kill it (9: `timeout -k` signals its own process group, itself in it, so QProcess sees a
//        crash by signal 9, not an exit status): the server took the call and never answered
//   127  the program is not there
function verdict(code, stderr) {
    const e = String(stderr || "").trim();
    if (code === 0)
        return { ok: true };
    if (code === 124 || code === 137 || code === 9)
        return { ok: false, health: "hung", reason: "No answer in time: the sound server took the call and went silent." };
    if (code === 127 || code === 126)
        return { ok: false, health: "missing", reason: "The command is not installed." };
    if (/Connection refused|Connection failure|Host is down|can't connect/i.test(e))
        return { ok: false, health: "dead", reason: "The sound server is not running (" + firstLine(e) + ")." };
    return { ok: false, health: "error", reason: e !== "" ? firstLine(e) : "Failed with exit code " + code + "." };
}
function firstLine(t) {
    const s = String(t).split("\n")[0].trim();
    return s.replace(/^Failure:\s*/, "");
}

// `lares-audio-diag` prints one line: `wireplumber <state> <wchan>`, state "D" when the process sits in the kernel. What a hang is made of,
// as in a locked USB DAC: WirePlumber in D on usb_start_wait_urb.
function diagnose(line) {
    const parts = String(line).trim().split(/\s+/);
    if (parts.length < 2 || parts[1] === "-")
        return "WirePlumber is not running.";
    if (parts[1] === "D") {
        const w = parts[2] || "";
        if (/usb/.test(w))
            return "WirePlumber is stuck in the kernel on a USB device (" + w + "). A USB audio device has stopped answering: unplug it.";
        return "WirePlumber is stuck in the kernel" + (w !== "" && w !== "0" ? " (" + w + ")" : "") + ": a device has stopped answering.";
    }
    return "";
}

// ---- did it take? --------------------------------------------------------------------------------------------------------------------

// An intent: { kind, key, want, wantText?, fromText?, label } made when a change is asked for.
// `read(intent)` the state now: { gone: bool, have, haveText }.
// -> "ok" | "wait" | "gone"
function compare(kind, want, have, tol) {
    if (kind === "volume") {
        // never Array.isArray: an array that crossed a signal is a list wrapper on Qt 6.12 and answers false (CLAUDE.md)
        if (!want || !have || want.length === 0)
            return false;
        if (have.length !== want.length) {
            // a channel count that differs means the row changed under us: judge by the average
            return Math.abs(average(want) - average(have)) <= tol;
        }
        for (let i = 0; i < want.length; i++)
            if (Math.abs(want[i] - have[i]) > tol)
                return false;
        return true;
    }
    if (kind === "formats")
        return (want || []).slice().sort().join(",") === (have || []).slice().sort().join(",");
    return want === have;
}

// The row's sentence when a change did not take (the reader sees it under the control that was moved).
function refusedText(have) {
    return "Nothing is plugged in here: the default stays " + have + ".";
}

function failText(i, have) {
    const h = have === undefined || have === null || have === "" ? "nothing" : String(have);
    switch (i.kind) {
    case "volume":
        return "Did not take: asked for " + i.wantText + ", it holds " + h + ".";
    case "mute":
        return i.want ? "Did not mute: it is still sounding." : "Did not unmute: it is still muted.";
    case "default":
        return "Not the default: the default stays " + h + ".";
    case "move":
        return "Did not move to " + i.wantText + ": still on " + h + ".";
    case "port":
        return "The port did not change: still " + h + ".";
    case "profile":
        return "The profile did not change: still " + h + ".";
    case "offset":
        return "The offset did not take: it holds " + h + " ms.";
    case "formats":
        return "The formats did not change.";
    case "codec":
        return "The codec did not change: still " + h + ".";
    case "tone":
        return "The tone did not reach " + i.wantText + (h !== "nothing" ? ": it went to " + h + "." : ".");
    }
    return "Did not take.";
}

// A node name a person can read: "alsa_output.usb-ACME_AUDIO_DAC_PRO_000000000001-01.analog-stereo" -> "ACME AUDIO DAC PRO". For a device that is not here
// to give its own description.
function prettyNode(name) {
    let s = String(name).replace(/^alsa_(output|input)\./, "").replace(/^(usb|pci|platform)-/, "");
    s = s.split(".")[0].replace(/-\d+$/, "").replace(/_[0-9A-F]{8,}$/i, "");
    return s.replace(/[_-]+/g, " ").trim();
}

// ---- the sine of a patch line ----------------------------------------------------------------------------------------------------------

// ---- the patch line -------------------------------------------------------------------------------------------------------------

// A line's run from (x0, y0) to (x1, y1): the S it climbs, a cubic that leaves and lands level, sampled about every `step` px. `d` is the arc length so far: a wave runs ALONG
// the line, and it is laid along the normal (`nx`, `ny`), or a steep stretch would squash it into a thick stroke. -> { n, s, x, y, nx, ny, d, length }, arrays of n + 1.
function linePath(x0, y0, x1, y1, step) {
    const run = x1 - x0, rise = y1 - y0;
    const n = Math.max(2, Math.ceil((Math.abs(run) + Math.abs(rise)) / Math.max(1, step)));
    const p = { n: n, s: [], x: [], y: [], nx: [], ny: [], d: [], length: 0 };
    let dist = 0, px = x0, py = y0;
    for (let i = 0; i <= n; i++) {
        const s = i / n, m = 1 - s;
        const x = x0 + run * (1.5 * s * m + s * s * s), y = y0 + rise * (3 * m * s * s + s * s * s);
        const tx = run * (1.5 * (1 - 2 * s) + 3 * s * s), ty = rise * 6 * s * m;
        const len = Math.max(1e-6, Math.sqrt(tx * tx + ty * ty));
        dist += Math.sqrt((x - px) * (x - px) + (y - py) * (y - py));
        px = x;
        py = y;
        p.s.push(s);
        p.x.push(x);
        p.y.push(y);
        p.nx.push(-ty / len);
        p.ny.push(tx / len);
        p.d.push(dist);
    }
    p.length = dist;
    return p;
}
// The sine on a line, `d` px from where the sound comes in. It TRAVELS AWAY from there as `phase` grows, and it dies at both ends so a line always lands (`s` 0..1 along it).
function lineWave(amp, d, wavelength, phase, s) {
    return amp * Math.sin(2 * Math.PI * d / wavelength - phase) * Math.sin(Math.PI * s);
}
// THE LINE IS A DELAY LINE. `hist` is the level as it came in, newest first, one sample a beat; a beat carries the sound `stepPx` down the line, so the level `d` px
// along is the level that came in d / stepPx beats ago. A stop in the sound runs down the line after the last of it, and a start runs down it in front of the first.
function levelAlong(hist, d, stepPx) {
    if (!hist || hist.length === 0)
        return 0;
    const k = Math.max(0, d / Math.max(0.001, stepPx));
    const i = Math.floor(k);
    if (i >= hist.length - 1)
        return hist[hist.length - 1] || 0;
    const f = k - i;
    return hist[i] * (1 - f) + hist[i + 1] * f;
}

// ---- the list mirror ---------------------------------------------------------------------------------------------------------------------

// What a list must do to a ListModel of keys to become `want`: removes first (from the end), then inserts, then moves. Pure, so a reorder never
// rebuilds a delegate. -> [{ op: "remove", at } | { op: "insert", at, key } | { op: "move", from, to }]
function diffKeys(have, want) {
    const ops = [];
    const h = have.slice();
    for (let i = h.length - 1; i >= 0; i--)
        if (want.indexOf(h[i]) < 0) {
            ops.push({ op: "remove", at: i });
            h.splice(i, 1);
        }
    for (let i = 0; i < want.length; i++) {
        if (h[i] === want[i])
            continue;
        const at = h.indexOf(want[i]);
        if (at < 0) {
            ops.push({ op: "insert", at: i, key: want[i] });
            h.splice(i, 0, want[i]);
        } else {
            ops.push({ op: "move", from: at, to: i });
            h.splice(i, 0, h.splice(at, 1)[0]);
        }
    }
    return ops;
}
