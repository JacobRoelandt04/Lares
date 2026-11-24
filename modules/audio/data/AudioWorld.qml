pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// AudioWorld.qml -- a sound system that does not exist, for the mockup, the shell's mock mode and the popup's probes.
//
// It stands where two real things stand: it IS `pipewire` (the members AudioService reads of PipewireService: nodes, the default, the link graph) and
// it IS `machine` (`exec(argv, done)`: what `pactl`, `pw-dump`, `pw-metadata` and `pw-cli` would answer, with the same exit codes and the same
// stderr, in the JSON pactl really prints). So AudioService runs unchanged on it, deadlines and read-back included: a fake hang is a callback that
// never comes, a fake refusal is exit 1 and pactl's own "Failure: No such entity". Nothing here can reach a process or a device.
//
// THE FAULTS, one switch each (the mockup's Faults tab, the probes):
//   hang         every call to the server stays unanswered until it is cleared (the user's locked DAC)
//   dead         the server is gone: exit 1 "Connection refused"; `ready` false
//   missing      pactl is not installed: exit 127
//   ignoreMove   a move exits 0 and does nothing        refuseMove   a move exits 1
//   ignorePort   a port exits 0 and does nothing        refusePort   a port exits 1
//   ignoreProfile, refuseProfile                        the same for a profile
//   ignoreVolume a volume write is swallowed            ignoreDefault  the default does not change
//   toneElsewhere  a test tone lands on the first sink, whatever was asked
//   ackMs        how late every answer comes
// and `removeDevice(name)`, `addStream(...)`, `removeStream(serial)`, `setNodeError(name, text)` for what changes under a gesture.
// =============================================================================
Item {
    id: root

    // ---- the faults ----------------------------------------------------------------------------------------------------------------
    property bool hang: false
    property bool dead: false
    property bool missing: false
    property bool ignoreMove: false
    property bool refuseMove: false
    property bool ignorePort: false
    property bool refusePort: false
    property bool ignoreProfile: false
    property bool refuseProfile: false
    property bool ignoreVolume: false
    property bool ignoreDefault: false
    property bool toneElsewhere: false
    property int ackMs: 25

    // ---- PipewireService's members ------------------------------------------------------------------------------------------------
    readonly property bool ready: !root.dead
    property var defaultSink: null
    property var defaultSource: null
    property var trackedAudioNodes: []
    property var linkPairs: []
    property bool linksWanted: false

    // A probe reads what was asked of the machine: ["pactl move-sink-input 12 x", ...]
    property var log: []
    property var _waiting: []               // the answers a hang holds back
    property var _toneDone: null
    property string _toneTarget: ""
    property int _serial: 100

    component AudioState: QtObject {
        id: state
        property var volumes: [0.5, 0.5]
        property var channels: [0, 1]
        property bool muted: false
        readonly property real volume: {
            let s = 0;
            for (let i = 0; i < state.volumes.length; i++)
                s += state.volumes[i];
            return state.volumes.length > 0 ? s / state.volumes.length : 0;
        }
    }
    component WorldNode: QtObject {
        id: node
        property int id: 0
        property string name: ""
        property string description: ""
        property bool isSink: false
        property bool isStream: false
        property var properties: ({})
        property real level: 0              // the fake peak, 0..1
        property AudioState audio: AudioState {}
    }
    Component {
        id: nodeComp
        WorldNode {}
    }

    // The facts behind the JSON. A record: { raw fields as pactl prints them, node }.
    property var _sinks: []
    property var _sources: []
    property var _inputs: []
    property var _outputs: []
    property var _cards: []
    property var _dumps: ({})

    function _node(name: string, desc: string, sink: bool, stream: bool, vols: var, props: var): var {
        root._serial += 2;
        const p = Object.assign({ "object.serial": String(root._serial + 1) }, props || {});
        const n = nodeComp.createObject(root, { id: root._serial, name: name, description: desc, isSink: sink, isStream: stream, properties: p });
        n.audio.volumes = vols;
        n.audio.channels = vols.map((v, i) => i);
        return n;
    }
    function _refreshNodes(): void {
        const a = [];
        for (const l of [root._sinks, root._sources, root._inputs, root._outputs])
            for (let i = 0; i < l.length; i++)
                if (l[i].node)
                    a.push(l[i].node);
        root.trackedAudioNodes = a;
    }
    function _relink(): void {
        const out = [];
        for (const r of root._inputs) {
            const s = root._sinks.filter(x => x.index === r.sink)[0];
            if (s && r.node && s.node)
                out.push({ source: r.node.id, target: s.node.id });
        }
        for (const r of root._outputs) {
            const s = root._sources.filter(x => x.index === r.source)[0];
            if (s && r.node && s.node)
                out.push({ source: s.node.id, target: r.node.id });
        }
        root.linkPairs = out;
    }

    function _vol(vs: var, names: var): var {
        const out = {};
        for (let i = 0; i < vs.length; i++)
            out[names[i]] = { value: Math.round(vs[i] * 65536), value_percent: Math.round(vs[i] * 100) + "%", db: "0 dB" };
        return out;
    }
    function _addSink(name: string, desc: string, props: var, ports: var, active: string, flags: var): var {
        const fl = flags || ["HARDWARE", "HW_MUTE_CTRL", "HW_VOLUME_CTRL", "DECIBEL_VOLUME", "LATENCY"];
        const p = Object.assign({ "device.description": desc, "media.class": "Audio/Sink" }, props);
        const n = root._node(name, desc, true, false, [0.62, 0.62], p);
        const rec = { index: Number(p["object.serial"] || n.properties["object.serial"]), state: "SUSPENDED", name: name, description: desc, flags: fl, properties: n.properties,
                      mute: false, volume: null, base_volume: { value_percent: "100%" }, ports: ports || [], active_port: active || "", formats: ["pcm"], monitor_source: name + ".monitor", node: n };
        root._sinks = root._sinks.concat([rec]);
        // the monitor is a source with no node of its own, as on a real server
        root._sources = root._sources.concat([{ index: rec.index + 1000, state: "SUSPENDED", name: name + ".monitor", description: "Monitor of " + desc, flags: ["DECIBEL_VOLUME", "LATENCY"],
                                                properties: { "device.class": "monitor", "device.description": "Monitor of " + desc }, mute: false, volume: root._vol([1, 1], ["front-left", "front-right"]),
                                                base_volume: { value_percent: "100%" }, ports: [], active_port: "", formats: ["pcm"], monitor_source: name, node: null }]);
        return n;
    }
    function _addSource(name: string, desc: string, props: var, ports: var, active: string): var {
        const p = Object.assign({ "device.description": desc, "media.class": "Audio/Source" }, props);
        const n = root._node(name, desc, false, false, [0.8, 0.8], p);
        root._sources = root._sources.concat([{ index: Number(n.properties["object.serial"]), state: "SUSPENDED", name: name, description: desc, flags: ["HARDWARE", "DECIBEL_VOLUME", "LATENCY"],
                                                properties: n.properties, mute: false, volume: null, base_volume: { value_percent: "100%" }, ports: ports || [], active_port: active || "", formats: ["pcm"], monitor_source: "", node: n }]);
        return n;
    }
    function addStream(app: string, title: string, sinkName: string, level: real): int {
        const s = root._sinks.filter(x => x.name === sinkName)[0];
        const props = { "application.name": app, "media.name": title, "application.process.binary": app.toLowerCase(), "media.class": "Stream/Output/Audio" };
        const n = root._node(app.toLowerCase(), app, true, true, [0.8, 0.8], props);
        n.level = level;
        const idx = Number(n.properties["object.serial"]);
        root._inputs = root._inputs.concat([{ index: idx, sink: s ? s.index : -1, corked: false, mute: false, volume: null, properties: n.properties, flags: [], node: n }]);
        root._changed();
        return idx;
    }
    function addRecording(app: string, title: string, sourceName: string, level: real): int {
        const s = root._sources.filter(x => x.name === sourceName)[0];
        const props = { "application.name": app, "media.name": title, "media.class": "Stream/Input/Audio" };
        const n = root._node(app.toLowerCase(), app, false, true, [1, 1], props);
        n.level = level;
        const idx = Number(n.properties["object.serial"]);
        root._outputs = root._outputs.concat([{ index: idx, source: s ? s.index : -1, corked: false, mute: false, volume: null, properties: n.properties, flags: [], node: n }]);
        root._changed();
        return idx;
    }
    function removeStream(serial: int): void {
        root._inputs = root._inputs.filter(r => r.index !== serial);
        root._outputs = root._outputs.filter(r => r.index !== serial);
        root._changed();
    }
    function removeDevice(name: string): void {
        const s = root._sinks.filter(x => x.name === name)[0];
        root._sinks = root._sinks.filter(x => x.name !== name);
        root._sources = root._sources.filter(x => x.name !== name && x.name !== name + ".monitor");
        if (s) {
            const first = root._sinks[0];
            for (const r of root._inputs)
                if (r.sink === s.index)
                    r.sink = first ? first.index : -1;
            if (root.defaultSink === s.node)
                root.defaultSink = first ? first.node : null;
        }
        root._changed();
    }
    function setNodeError(name: string, text: string): void {
        const d = Object.assign({}, root._dumps);
        if (text === "")
            delete d[name];
        else
            d[name] = { state: "error", error: text };
        root._dumps = d;
        root.changed();
    }
    // Every stream paused or playing again: a level monitor reads nothing from a corked stream.
    function setPaused(paused: bool): void {
        for (const r of root._inputs.concat(root._outputs))
            r.corked = paused;
        root._changed();
    }
    function setLevel(name: string, v: real): void {
        for (const n of root.trackedAudioNodes)
            if (n.name === name)
                n.level = v;
    }
    // The AudioPeak stand-in reads this.
    function levelOf(node: var): real {
        return node && node.level !== undefined ? node.level : 0;
    }
    signal changed
    function _changed(): void {
        root._refreshNodes();
        root._relink();
        root.changed();
    }

    // A world exists before anything asks it anything: a service told "open" at load can reach `exec` ahead of the host's own start-up.
    property bool rich: true
    property bool _built: false
    function ensureBuilt(): void {
        if (!root._built)
            root.build(root.rich);
    }
    function build(rich: bool): void {
        root._built = true;
        root._sinks = [];
        root._sources = [];
        root._inputs = [];
        root._outputs = [];
        root._cards = [];
        const P = (n, d, t, a) => ({ name: n, description: d, type: t, priority: 100, availability: a });
        const speakers = root._addSink("alsa_output.pci-0000_00_1f.3.HiFi__Speaker__sink", "Meteor Lake-P HD Audio Controller Speaker", { "device.name": "alsa_card.pci-0000_00_1f.3", "device.icon_name": "audio-speakers", "device.api": "alsa" },
            [P("[Out] Speaker", "Speaker", "Speaker", "availability unknown")], "[Out] Speaker");
        const mic = root._addSource("alsa_input.pci-0000_00_1f.3.HiFi__Mic1__source", "Meteor Lake-P HD Audio Controller Digital Microphone", { "device.name": "alsa_card.pci-0000_00_1f.3", "device.api": "alsa" },
            [P("[In] Mic1", "Digital Microphone", "Mic", "availability unknown")], "[In] Mic1");
        root.defaultSink = speakers;
        root.defaultSource = mic;
        const hiFi = { "off": { description: "Off", sinks: 0, sources: 0, priority: 0, available: true },
                       "HiFi (Mic1, Mic2, Speaker)": { description: "Play HiFi quality Music (Speaker)", sinks: 2, sources: 2, priority: 10200, available: true },
                       "HiFi (Headphones, Mic1, Mic2)": { description: "Play HiFi quality Music (Headphones)", sinks: 2, sources: 2, priority: 10300, available: false },
                       "pro-audio": { description: "Pro Audio", sinks: 5, sources: 2, priority: 1, available: true } };
        root._cards = [{ index: 47, name: "alsa_card.pci-0000_00_1f.3", properties: { "device.description": "Meteor Lake-P HD Audio Controller", "device.name": "alsa_card.pci-0000_00_1f.3", "device.bus": "pci" },
                         profiles: hiFi, active_profile: "HiFi (Mic1, Mic2, Speaker)",
                         ports: { "[Out] Speaker": { latency_offset: "0 usec" }, "[In] Mic1": { latency_offset: "0 usec" } } }];
        if (rich) {
            const dac = "alsa_output.usb-ACME_AUDIO_DAC_PRO-01.analog-stereo";
            root._addSink(dac, "ACME AUDIO DAC PRO Analog Stereo", { "device.name": "alsa_card.usb-ACME_AUDIO_DAC_PRO-01", "device.bus": "usb", "device.icon_name": "audio-headphones", "device.form_factor": "headphone", "device.api": "alsa" },
                [P("analog-output-headphones", "Headphones", "Headphones", "available"), P("analog-output-lineout", "Line Out", "Line", "not available")], "analog-output-headphones");
            root._addSink("alsa_output.pci-0000_00_1f.3.HiFi__HDMI1__sink", "Meteor Lake-P HD Audio Controller HDMI / DisplayPort 1 Output (Stereo)", { "device.name": "alsa_card.pci-0000_00_1f.3", "device.icon_name": "video-display", "device.api": "alsa" },
                [P("[Out] HDMI1", "HDMI / DisplayPort 1 Output", "HDMI", "not available")], "[Out] HDMI1", ["HARDWARE", "DECIBEL_VOLUME", "LATENCY", "SET_FORMATS"]);
            root._addSink("effect_input.eq", "Equalizer", { "node.virtual": "true" }, [], "", ["DECIBEL_VOLUME", "LATENCY"]);
            root._addSource("alsa_input.usb-ACME_AUDIO_DAC_PRO-01.analog-stereo", "ACME AUDIO DAC PRO Analog Stereo", { "device.name": "alsa_card.usb-ACME_AUDIO_DAC_PRO-01", "device.bus": "usb", "device.api": "alsa" },
                [P("analog-input-mic", "Microphone", "Mic", "not available")], "analog-input-mic");
            root._cards = root._cards.concat([{ index: 48, name: "alsa_card.usb-ACME_AUDIO_DAC_PRO-01", properties: { "device.description": "ACME AUDIO DAC PRO", "device.name": "alsa_card.usb-ACME_AUDIO_DAC_PRO-01", "device.bus": "usb", "device.form_factor": "headphone" },
                                                profiles: { "off": { description: "Off", sinks: 0, sources: 0, priority: 0, available: true }, "output:analog-stereo+input:analog-stereo": { description: "Analog Stereo Duplex", sinks: 1, sources: 1, priority: 6565, available: true }, "output:iec958-stereo": { description: "Digital Stereo (IEC958) Output", sinks: 1, sources: 0, priority: 5500, available: false } },
                                                active_profile: "output:analog-stereo+input:analog-stereo", ports: { "analog-output-headphones": { latency_offset: "0 usec" }, "analog-output-lineout": { latency_offset: "0 usec" } } },
                                              { index: 49, name: "bluez_card.AC_12_2F_00_11_22", properties: { "device.description": "Headset X4", "device.api": "bluez5", "device.bus": "bluetooth", "device.form_factor": "headset" },
                                                profiles: { "off": { description: "Off", sinks: 0, sources: 0, priority: 0, available: true }, "a2dp-sink": { description: "High Fidelity Playback (A2DP Sink)", sinks: 1, sources: 0, priority: 40, available: true }, "headset-head-unit": { description: "Headset Head Unit (HSP/HFP)", sinks: 1, sources: 1, priority: 30, available: true } },
                                                active_profile: "a2dp-sink", ports: {} }]);
        }
        root._refreshNodes();
        if (rich) {
            root.addStream("Firefox", "Lo-fi beats to refactor to", root._sinks[0].name, 0.42);
            root.addStream("Music Player Daemon", "Boards of Canada - Dayvan Cowboy", root._sinks[1].name, 0.66);
            root.addStream("Discord", "Voice call", root._sinks[0].name, 0.0);
            root.addRecording("Discord", "Voice call", root._sources.filter(s => s.node)[0].name, 0.34);
        }
        root._changed();
    }

    // ---- PipewireService's write helpers -------------------------------------------------------------------------------------------
    function setVolumes(node: var, volumes: var): void {
        if (!node || root.ignoreVolume)
            return;
        const a = [];
        for (let i = 0; i < volumes.length; i++)
            a.push(volumes[i]);
        lateTimer.later(() => {
            node.audio.volumes = a;
        });
    }
    function setVolume(node: var, v: real): void {
        if (node)
            root.setVolumes(node, node.audio.volumes.map(() => v));
    }
    function setMuted(node: var, m: bool): void {
        if (node && !root.ignoreVolume)
            lateTimer.later(() => {
                node.audio.muted = m;
            });
    }
    function toggleMute(node: var): void {
        if (node)
            root.setMuted(node, !node.audio.muted);
    }
    function setDefaultSink(node: var): void {
        if (!root.ignoreDefault)
            lateTimer.later(() => {
                root.defaultSink = node;
            });
    }
    function setDefaultSource(node: var): void {
        if (!root.ignoreDefault)
            lateTimer.later(() => {
                root.defaultSource = node;
            });
    }
    function linkTargetOf(mediaName: string): string {
        return root._toneTarget;
    }

    QtObject {
        id: lateTimer
        function later(f: var): void {
            const t = Qt.createQmlObject("import QtQuick; Timer { repeat: false }", root);
            t.interval = Math.max(1, root.ackMs);
            t.triggered.connect(() => {
                t.destroy();
                f();
            });
            t.start();
        }
    }

    // ---- the machine -----------------------------------------------------------------------------------------------------------------
    function exec(argv: var, done: var): void {
        root.ensureBuilt();
        const words = [];
        for (let i = 0; i < argv.length; i++)
            words.push(String(argv[i]));
        root.log = root.log.concat([words.join(" ")]);
        const answer = (c, o, e) => lateTimer.later(() => done(c, o || "", e || ""));
        if (words[0] === "pw-play") {
            root._playTone(words, done);
            return;
        }
        if (root.missing && words[0] === "pactl") {
            answer(127, "", "");
            return;
        }
        if (root.dead) {
            answer(1, "", words[0] === "pactl" ? "Connection failure: Connection refused\n" : "can't connect: Host is down\n");
            return;
        }
        if (root.hang && words[0] !== "pw-dump" && words[0].indexOf("lares-audio-diag") < 0) {
            root._waiting = root._waiting.concat([done]);    // what `timeout` makes of it when the hang ends: the call died, its effect never happened
            return;
        }
        if (words[0].indexOf("lares-audio-diag") >= 0) {
            answer(0, "wireplumber D usb_start_wait_urb\n", "");
            return;
        }
        if (words[0] === "pw-dump") {
            const a = [];
            for (const n in root._dumps)
                a.push({ info: { state: root._dumps[n].state, error: root._dumps[n].error, props: { "node.name": n } } });
            answer(0, JSON.stringify(a), "");
            return;
        }
        if (words[0] === "sh" && words.join(" ").indexOf("pw-metadata") >= 0) {
            answer(0, "update: id:0 key:'default.audio.sink' value:'{\"name\":\"" + (root.defaultSink ? root.defaultSink.name : "") + "\"}' type:'Spa:String:JSON'\n"
                   + "update: id:0 key:'restore.stream.Output/Audio.media.role:Notification' value:'{\"mute\":false, \"volumes\":[0.7, 0.7], \"channels\":[\"FL\", \"FR\"]}' type:'Spa:String:JSON'\n", "");
            return;
        }
        if (words[0] === "sh" && words.join(" ").indexOf("list-codecs") >= 0) {
            answer(0, '[{"name":"6","description":"LDAC"},{"name":"3","description":"AAC"},{"name":"1","description":"SBC"}]\n"' + root._codec + '"\n', "");
            return;
        }
        if (words[0] === "pw-cli" || words[0] === "pw-metadata") {
            if (words[1] === "destroy")
                root.removeStream(Number(root._serialOfId(Number(words[2]))));
            answer(0, "", "");
            return;
        }
        if (words[0] !== "pactl") {
            answer(127, "", "");
            return;
        }
        if (words[1] === "-f") {
            answer(0, root._snapshotText(), "");
            return;
        }
        const r = root._apply(words);
        answer(r.c, "", r.e);
    }
    property string _codec: "6"
    function _serialOfId(id: int): int {
        for (const l of [root._inputs, root._outputs])
            for (const r of l)
                if (r.node && r.node.id === id)
                    return r.index;
        return -1;
    }
    readonly property var _noEntity: ({ c: 1, e: "Failure: No such entity\n" })

    function _apply(w: var): var {
        const verb = w[1];
        const OK = { c: 0, e: "" };
        if (verb === "move-sink-input" || verb === "move-source-output") {
            if (root.refuseMove)
                return root._noEntity;
            if (root.ignoreMove)
                return OK;
            const inp = verb === "move-sink-input";
            const rec = (inp ? root._inputs : root._outputs).filter(r => r.index === Number(w[2]))[0];
            const dev = (inp ? root._sinks : root._sources).filter(d => d.name === w[3])[0];
            if (!rec || !dev)
                return root._noEntity;
            if (inp)
                rec.sink = dev.index;
            else
                rec.source = dev.index;
            lateTimer.later(() => root._changed());
            return OK;
        }
        if (verb === "set-sink-port" || verb === "set-source-port") {
            if (root.refusePort)
                return root._noEntity;
            if (root.ignorePort)
                return OK;
            const dev = (verb === "set-sink-port" ? root._sinks : root._sources).filter(d => d.name === w[2])[0];
            if (!dev)
                return root._noEntity;
            dev.active_port = w[3];
            lateTimer.later(() => root.changed());
            return OK;
        }
        if (verb === "set-card-profile") {
            if (root.refuseProfile)
                return root._noEntity;
            if (root.ignoreProfile)
                return OK;
            const c = root._cards.filter(x => x.name === w[2])[0];
            if (!c)
                return root._noEntity;
            c.active_profile = w[3];
            lateTimer.later(() => root.changed());
            return OK;
        }
        if (verb === "set-port-latency-offset") {
            const c = root._cards.filter(x => x.name === w[2])[0];
            if (!c || !c.ports[w[3]])
                return root._noEntity;
            c.ports[w[3]].latency_offset = w[4] + " usec";
            lateTimer.later(() => root.changed());
            return OK;
        }
        if (verb === "set-sink-formats") {
            const s = root._sinks.filter(x => x.index === Number(w[2]))[0];
            if (s)
                s.formats = w[3].split(";").filter(f => f !== "");
            lateTimer.later(() => root.changed());
            return OK;
        }
        if (verb === "send-message") {
            root._codec = JSON.parse(w[4]);
            lateTimer.later(() => root.changed());
            return OK;
        }
        if (verb === "set-sink-volume" || verb === "set-source-volume") {
            const list = verb === "set-sink-volume" ? root._sinks : root._sources;
            const d = list.filter(x => x.name === w[2])[0];
            if (d && !d.node && !root.ignoreVolume)
                d.volume = root._vol(w.slice(3).map(x => parseFloat(x) / 100), Object.keys(d.volume));
            lateTimer.later(() => root.changed());
            return OK;
        }
        if (verb === "set-default-sink") {
            const d = root._sinks.filter(x => x.name === w[2])[0];
            if (!d)
                return root._noEntity;
            if (!root.ignoreDefault)
                root.defaultSink = d.node;
            return OK;
        }
        return OK;
    }
    onHangChanged: {
        if (root.hang)
            return;
        const w = root._waiting;
        root._waiting = [];
        for (let i = 0; i < w.length; i++)
            w[i](124, "", "");
    }

    function _liveFields(r: var): var {
        const out = {};
        for (const k in r)
            if (k !== "node")
                out[k] = r[k];
        if (r.node) {
            const names = r.node.audio.volumes.length === 1 ? ["mono"] : ["front-left", "front-right"];
            out.volume = root._vol(r.node.audio.volumes, names);
            out.mute = r.node.audio.muted;
        }
        return out;
    }
    function _snapshotText(): string {
        return JSON.stringify({
            sinks: root._sinks.map(root._liveFields), sources: root._sources.map(root._liveFields),
            sink_inputs: root._inputs.map(root._liveFields), source_outputs: root._outputs.map(root._liveFields),
            cards: root._cards, modules: [], clients: [], samples: []
        });
    }

    function _playTone(w: var, done: var): void {
        const target = String(w[1]).replace("--target=", "");
        if (root._sinks.filter(s => s.name === target).length === 0) {
            lateTimer.later(() => done(1, "", "stream node 51 error: defined target not found\n"));
            return;
        }
        root._toneTarget = root.toneElsewhere && root._sinks.length > 0 ? root._sinks[0].name : target;
        root._toneDone = done;
        const t = Qt.createQmlObject("import QtQuick; Timer { repeat: false }", root);
        t.interval = 2600;
        t.triggered.connect(() => {
            t.destroy();
            root.stopTone();
        });
        t.start();
    }
    function stopTone(): void {
        const d = root._toneDone;
        root._toneDone = null;
        root._toneTarget = "";
        if (d)
            d(0, "", "");
    }
}
