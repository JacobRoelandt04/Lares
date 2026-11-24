pragma ComponentBehavior: Bound

import QtQuick
import "../../../bar/audio/data"
import "../../../common/components"
import "../OsdKinds.js" as Kinds

// =============================================================================
// AudioSource.qml -- volume and mic: the keys that change them, and the apps
// that change them behind the shell's back.
//
//   adjust(which, dir, phase)   a key step; which "out" | "in", dir +1 | -1,
//                               phase "press" | "repeat" | "release"
//   toggleMute(which)           the mute key
//   setValue(which, v)          a drag on the OSD's slider (no request: the
//                               content already shows where the ball is)
//   toggleBoost()               the OSD's boost switch (volume only)
//   quiet(ms)                   swallow external changes for a while (a
//                               script that is about to set the volume itself)
//   signal request(var req)     one partial CONTRACT section 1 request
//
// WHAT SHOWS. A key step always. From outside: another program changing the
// default sink's or source's volume or mute, and the default sink SWITCHING
// (the same `volume` kind with the new device's type and name, so the card
// stays in place). What never shows: start-up. The first reading of a device
// is the baseline, and a switch inside `warmupMs` of the last baseline (the
// default flapping while Pipewire settles, a Bluetooth profile change) only
// re-baselines.
//
// OUR OWN WRITE ECHOES. Setting a node's volume comes back as a change
// signal; the state is updated BEFORE the write, so the echo equals what is
// held and says nothing, and a short quiet window after each write absorbs the
// rounding Pipewire does.
//
// `live: false` creates no Pipewire object and writes nothing: the state is
// whatever simulate*() last said, and a key step moves that state and emits the
// same request. ONE code path -- the observers and the key handlers do not know
// which they have. `backend` hands in the shell's own PipewireService.
// =============================================================================
Item {
    id: root

    property bool live: true
    property var backend: null
    property real step: 0.02
    property real micStep: 0.05
    property real boostMax: 1.5
    property int warmupMs: 1500
    // After one of our own writes, external changes are not reported for this long.
    property int echoQuietMs: 300

    signal request(var req)

    // ---- state ---------------------------------------------------------------
    // { id, vol, muted, name, type } or null before the first reading.
    readonly property var out: root._out
    readonly property var inp: root._in

    property var _out: null
    property var _in: null
    property bool _boostOn: false
    property double _guardUntil: 0
    property double _quietUntil: 0
    property var _gate: ({ out: Kinds.newBoostState(), inp: Kinds.newBoostState() })
    // The mute state of the last request said for each node (the first reading before any): a request whose `muted` differs says
    // `muteFlip`, so the card plays the ball's change of lanes however the mute came (the bar icon, the key, the card's own drag, an app).
    property var _saidMuted: ({ out: undefined, in: undefined })

    function quiet(ms) {
        root._quietUntil = Math.max(root._quietUntil, Date.now() + Math.max(0, ms));
    }

    function _now() {
        return Date.now();
    }

    // ---- observers (live signals and simulate*() both end here) ---------------
    function _observeOut(id, vol, muted, name, type) {
        const prev = root._out;
        const now = root._now();
        root._out = { id: id, vol: vol, muted: muted, name: name, type: type };
        if (prev === null) {
            root._saidMuted.out = muted;
            root._guardUntil = now + root.warmupMs;
            return;
        }
        if (prev.id !== id) {
            const settling = now < root._guardUntil;
            root._guardUntil = now + root.warmupMs;
            if (!settling)
                root._emit("out", "external", "device");
            return;
        }
        if (now < root._guardUntil || now < root._quietUntil)
            return;
        if (Math.abs(prev.vol - vol) > 0.004 || prev.muted !== muted)
            root._emit("out", "external");
    }

    function _observeIn(id, vol, muted, name) {
        const prev = root._in;
        const now = root._now();
        root._in = { id: id, vol: vol, muted: muted, name: name, type: "mic" };
        if (prev === null) {
            root._saidMuted.in = muted;
            return;
        }
        if (prev.id !== id) {
            // A new default source is not a mic event of the user's making.
            return;
        }
        if (now < root._guardUntil || now < root._quietUntil)
            return;
        if (Math.abs(prev.vol - vol) > 0.004 || prev.muted !== muted)
            root._emit("in", "external");
    }

    // ---- requests -------------------------------------------------------------
    function _boostEffective() {
        return root._boostOn || (root._out !== null && root._out.vol > 1.0005);
    }

    // (`event`: OsdKinds.eventOf's word where the source is not it)
    function _emit(which, source, event) {
        const s = which === "out" ? root._out : root._in;
        if (s === null)
            return;
        const out = which === "out";
        const boost = out && root._boostEffective();
        const prevMuted = root._saidMuted[which];
        root._saidMuted[which] = s.muted;
        root.request({
            kind: out ? "volume" : "mic",
            key: out ? "out" : "in",
            source: source,
            event: event || source,
            value: Math.max(0, Math.min(boost ? root.boostMax : 1, s.vol)),
            max: boost ? root.boostMax : 1,
            muted: s.muted,
            muteFlip: prevMuted !== undefined && prevMuted !== s.muted,
            boost: boost,
            device: { type: s.type, name: s.name }
        });
    }

    // ---- key actions ----------------------------------------------------------
    function adjust(which, dir, phase) {
        const out = which === "out";
        const s = out ? root._out : root._in;
        if (s === null)
            return false;
        const gk = out ? "out" : "inp";
        const bm = out ? root.boostMax : 1.0;
        const g = Kinds.boostGate(root._gate[gk], phase, s.vol, bm);
        root._gate[gk] = g;
        if (phase === "release")
            return true;
        const v = Kinds.volumeStep(g, s.vol, dir, out ? root.step : root.micStep, bm);
        // A raise unmutes (a muted bar that moves is a lie), a lower leaves it.
        const unmute = dir > 0 && s.muted;
        root._write(which, v, unmute ? false : null);
        root._emit(which, "key");
        return true;
    }

    function toggleMute(which) {
        const s = which === "out" ? root._out : root._in;
        if (s === null)
            return false;
        root._write(which, null, !s.muted);
        root._emit(which, "key");
        return true;
    }

    function setValue(which, v) {
        const s = which === "out" ? root._out : root._in;
        if (s === null)
            return;
        const cap = which === "out" && root._boostEffective() ? root.boostMax : 1;
        root._write(which, Math.max(0, Math.min(cap, v)), null);
    }

    function toggleBoost() {
        const s = root._out;
        if (s === null)
            return false;
        if (root._boostEffective()) {
            root._boostOn = false;
            if (s.vol > 1)
                root._write("out", 1, null);
        } else {
            root._boostOn = true;
        }
        root._emit("out", "key");
        return true;
    }

    // v / muted: null = leave. The state moves first, then the node.
    function _write(which, v, muted) {
        const out = which === "out";
        const s = out ? root._out : root._in;
        const n = { id: s.id, vol: v === null ? s.vol : v, muted: muted === null ? s.muted : muted, name: s.name, type: s.type };
        if (out)
            root._out = n;
        else
            root._in = n;
        root.quiet(root.echoQuietMs);
        if (!root.live)
            return;
        const pw = root._pw;
        const node = pw ? (out ? pw.defaultSink : pw.defaultSource) : null;
        if (!node || !node.audio)
            return;
        if (v !== null)
            pw.setVolume(node, v);
        if (muted !== null)
            pw.setMuted(node, muted);
    }

    // ---- the live half --------------------------------------------------------
    // THE FALLBACK. A source with no backend can build a service of its own (a PipewireService). SHELL-HOSTED
    // (CONTRACT section 4): the backend is the shell's one PipewireService, injected, and a null one means the
    // feature is ABSENT -- a hosted source never builds a service of its own -- said once in the log,
    // because it is a wiring fault, not a state.
    property bool shellHosted: false
    // How many services this source has built for itself (a probe reads it; nothing binds to it).
    property int builds: 0
    Component.onCompleted: {
        if (root.shellHosted && root.live && root.backend === null)
            console.warn("OsdService: shell-hosted but the audio source got no backend; it stays absent (it does not build its own PipewireService)");
    }

    Loader {
        id: pwLoader
        active: root.live && root.backend === null && !root.shellHosted
        sourceComponent: PipewireService {}
        onLoaded: root.builds++
    }
    readonly property var _pw: root.backend !== null ? root.backend : pwLoader.item

    readonly property var _sinkNode: root.live && root._pw ? root._pw.defaultSink : null
    readonly property var _sourceNode: root.live && root._pw ? root._pw.defaultSource : null

    AudioGlyphs {
        id: glyphs
    }

    function _sample() {
        if (!root.live || !root._pw || !root._pw.ready)
            return;
        const sink = root._sinkNode, src = root._sourceNode;
        if (sink && sink.audio && isFinite(sink.audio.volume))
            root._observeOut(String(sink.id), sink.audio.volume, sink.audio.muted === true,
                             sink.description || sink.nickname || sink.name || "", glyphs.deviceType(sink));
        if (src && src.audio && isFinite(src.audio.volume))
            root._observeIn(String(src.id), src.audio.volume, src.audio.muted === true,
                            src.description || src.nickname || src.name || "");
    }

    on_SinkNodeChanged: root._sample()
    on_SourceNodeChanged: root._sample()
    Connections {
        target: root._pw
        ignoreUnknownSignals: true
        function onReadyChanged() { root._sample(); }
    }
    Connections {
        target: root._sinkNode ? root._sinkNode.audio : null
        ignoreUnknownSignals: true
        function onVolumeChanged() { root._sample(); }
        function onMutedChanged() { root._sample(); }
    }
    Connections {
        target: root._sourceNode ? root._sourceNode.audio : null
        ignoreUnknownSignals: true
        function onVolumeChanged() { root._sample(); }
        function onMutedChanged() { root._sample(); }
    }

    // ---- simulation (live: false) ---------------------------------------------
    // The first reading: the baseline, and the start of the warm-up.
    function simulateReady(outVol, outMuted, outName, outType, inVol, inMuted) {
        root._observeOut("sim-sink", outVol, outMuted, outName, outType);
        root._observeIn("sim-source", inVol, inMuted, "Built-in Microphone");
    }
    // An app changed the default sink's volume / mute.
    function simulateOut(vol, muted) {
        const s = root._out;
        root._observeOut(s.id, vol, muted, s.name, s.type);
    }
    function simulateIn(vol, muted) {
        const s = root._in;
        root._observeIn(s.id, vol, muted, s.name);
    }
    // The default sink switched to another device.
    function simulateSink(type, name, vol, muted) {
        root._observeOut("sim-sink-" + name, vol, muted, name, type);
    }
}
