pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import Quickshell.Services.Pipewire
import "../../../common/system"

// =============================================================================
// PlayerLevelTap.qml
//
// How loud the music is RIGHT NOW, relative to how loud it has been lately --
// so the viewfinder can throw more sparks on a beat than in a quiet passage,
// which is what the spec asks for and what MPD cannot tell anyone: the daemon
// reports a bitrate, not a waveform.
//
// It finds MPD's own PipeWire stream and reads its samples through
// `tools/player/audio_level_tap.py`, a small RMS reader.
//
// ---------------------------------------------------------------------------
// WHY THE STREAM IS FOUND AND RECORDED BY NAME, AND WHY `level` IS NORMALISED
// ---------------------------------------------------------------------------
//   1. THE STREAM IS MATCHED ON ITS NAME. MPD's node on this machine carries NO
//      `application.process.binary` and its `application.name` is "Music Player
//      Daemon" -- which does not contain "mpd". The only property that does is
//      `node.name`, "mpd.PipeWire", which PwNode publishes as `name` without
//      the node ever being bound (measured with pw-dump). Sinks are not excluded:
//      quickshell reports that same playback stream as isSink=true (logged live).
//
//   2. `pw-cat --record --target=<object id>` RECORDS SILENCE. PipeWire 1.6
//      resolves `--target` by node NAME or by `object.serial`, not by the
//      object id that `PwNode.id` hands out. Measured, same second, same
//      node: `--target=103` gives 0.0000 for every window of a playing track,
//      `--target=336` (its serial) and `--target=mpd.PipeWire` give the real
//      signal. A tap that is only given an int id can only ever record silence
//      from a stream on this PipeWire, so this file spawns its own recorder,
//      by NAME. One pw-cat, hard gated.
//
//   3. THE RAW RANGE IS NARROW. The raw RMS of a mastered track sits between
//      0.20 and 0.31 all song (measured over 50 s: p5 0.010, median 0.159, p95
//      0.305, max 0.385) and at 25% volume between 0.0004 and 0.005. A number
//      like that, handed to an emitter as 0..1, cannot make a beat visible
//      whatever the emitter does, and at low volume it cannot make anything
//      visible at all. So `level` is not the raw RMS: it is that RMS in dB
//      above a FLOOR taken from the recent past, so the quiet capture breathes
//      like the loud one.
//
// THE MEASUREMENT, in the order the numbers are made:
//
//   raw            the reader's RMS window (~64 ms, arriving at 15.6 Hz --
//                  pw-cat's own cadence; asking for a smaller latency or a
//                  higher rate does not move it, measured).
//   fast/slow      two exponential envelopes over `raw`, fast attack and slow
//                  release both, so a hit lands on the sample it happens and
//                  its tail is a fade rather than a cut. `fast` is for
//                  onsets, `slow` is the loudness of the passage.
//   floorDb        where `slow` has been lately, IN dB: falls quickly to a new
//                  quiet, creeps up slowly out of one. There is no ceiling --
//                  see `level`.
//   level          (dB(slow) - floorDb) / `spanDb`, clamped. In dB because a
//                  measure of loudness has to be SCALE-FREE (see `_step`):
//                  a volume change moves the floor and the signal together.
//   beatSeq        an ONSET, counted: a positive jump in `fast` bigger than
//                  `beatFluxRatio` times the running mean jump, no closer
//                  than `beatMinGapMs` to the last one. Measured on real
//                  playback that is 1.4 onsets a second on a loud track and
//                  1.0 on a quiet one, median gap 0.64 s.
//
// NO BPM. The Data tab's reader does get a BPM tag for many tracks, but a tempo
// grid does not fit these captures: at 15.6 Hz the onset times scatter with a
// standard deviation of ~0.46 s around their own median gap, which is nowhere
// near tight enough to phase-lock a grid to. A grid drifting against the music
// is worse than no grid, so the bursts are driven by the onsets themselves,
// which land on the beat when the music has one and simply stop when it does
// not.
//
// It is OFF by default and must be switched on by whoever opens the popup. The
// tap costs about 25 MB resident and a `bash -c 'pw-cat | python3'` pipeline
// per instance; taps spawned faster than they exit exhaust the session's file
// descriptors and take the desktop with them. One tap, gated hard, or none.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // PUBLIC API
    // ======================================================================
    // Nothing runs until this is true. The popup being open is the gate.
    property bool active: false

    // Which stream to listen to, as a token matched case-insensitively
    // against the node's name, description and nickname. "mpd" matches
    // "mpd.PipeWire"; see the header for why the application properties are
    // not what is matched.
    property string appToken: "mpd"
    // A test seam: this stream NAME is the target, found or not -- a sandbox has no PipeWire graph to find one in.
    property string forceTarget: ""

    // 0..1, how loud this moment is against the recent past. THIS is what a
    // spark emitter wants -- see the header for why the raw RMS is not.
    readonly property real level: root._intensity
    // The absolute smoothed RMS, 0..1, for anything measuring rather than
    // drawing (a probe, a meter that must read in real units).
    readonly property real raw: root._slow

    // An onset: `beatSeq` counts up once per detected beat and
    // `beatStrength` is how big that one was, 0..1. A host wires the counter
    // and reads the strength when it changes; nothing here decays, because a
    // beat is an EVENT and the decay belongs to whatever it drives.
    readonly property int beatSeq: root._beatSeq
    readonly property real beatStrength: root._beatStrength

    // ---- Envelopes, ms ---------------------------------------------------
    property int fastAttackMs: 20      // onset envelope: rises almost instantly
    property int fastReleaseMs: 140
    property int slowAttackMs: 90      // the passage's loudness
    property int slowReleaseMs: 420

    // ---- The running floor, in dB, ms ------------------------------------
    property int floorFallMs: 1500     // a new quiet is believed quickly
    property int floorRiseMs: 20000    // ...and left slowly
    // How far above the floor is "as loud as this gets", in dB. Music's own
    // dynamics inside a passage are 10-20 dB; at 14 the measured p75 of a
    // real track is 0.83 and its median 0.10, which is a signal that mostly
    // rests and rises on the loud moments rather than one that sits high.
    property real spanDb: 14
    // Below this there is nothing playing at all. Two ten-thousandths: a
    // stopped daemon reads EXACTLY 0.0000 and a track at 20% volume still
    // reads 0.002, so this separates silence from quiet without touching the
    // second.
    property real silenceLevel: 0.0002

    // ---- Onsets ----------------------------------------------------------
    property int fluxMeanMs: 1200      // window the "normal" jump is taken over
    // How much bigger than the running mean jump a jump has to be, and how
    // far apart two beats can be. Filmed as well as counted: at 2.5 and 380
    // a dense track fires 1.8 onsets a second, which with a burst on each is
    // a continuous shower rather than a beat. At 3.0 and 450 the same track
    // gives about 1.2 a second and the bursts read as hits; 600 ms of
    // refractory holds a dense track to about 1.1, which is where the bursts
    // stop merging into a stream.
    property real beatFluxRatio: 3.0
    property int beatMinGapMs: 600
    // And a jump smaller than this share of the current level is never a
    // beat, however quiet the recent past was -- the guard against a silent
    // passage's noise being normalised into a drum.
    property real beatMinJumpFraction: 0.02
    property real beatMinStrength: 0.15

    // ======================================================================
    // FINDING THE STREAM
    //
    // `Pipewire.nodes` is an ObjectModel: a QML binding does NOT recompute
    // when its contents change, and each `.values` access hands out fresh
    // wrappers, so an identity check fails every time. That is why the shell's
    // own PipewireService polls and compares, and why this does the same.
    //
    // Only `name`, `description` and `nickname` are read, and all three are
    // constant properties available without the node being bound -- so no
    // PwObjectTracker is needed. `properties` would need one and would tell us
    // nothing extra: the map has no `application.process.binary` to match on in
    // the first place.
    // ======================================================================
    property string _targetName: ""

    Timer {
        interval: 1500
        running: root.active
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            root._findTarget();
            // And the recovery: a recorder that died -- the stream went away
            // and came back, pw-cat lost its link -- is started again here
            // rather than never. Once every 1.5 s, which is far too slow to
            // be the fd storm the header warns about.
            if (root.active && root._targetName !== "" && !proc.running)
                root._syncProc();
        }
    }

    function _findTarget() {
        if (root.forceTarget !== "") {
            if (root._targetName !== root.forceTarget)
                root._targetName = root.forceTarget;
            return;
        }
        if (!Pipewire.ready) {
            root._targetName = "";
            return;
        }
        const token = root.appToken.toLowerCase();
        const nodes = Pipewire.nodes.values;
        for (let i = 0; i < nodes.length; ++i) {
            const n = nodes[i];
            // NOT `&& !n.isSink`. Quickshell reports MPD's playback stream as
            // isStream=true AND isSink=true -- a stream that feeds a sink
            // lives under it in the graph -- so excluding sinks excludes the
            // one node this component exists to find (logged:
            // name=mpd.PipeWire isStream=true isSink=true audio=y).
            if (!n || !n.audio || !n.isStream)
                continue;
            const name = n.name || "";
            const hay = (name + " " + (n.description || "") + " " + (n.nickname || "")).toLowerCase();
            if (hay.indexOf(token) >= 0 && root._safeName(name)) {
                if (root._targetName !== name)
                    root._targetName = name;
                return;
            }
        }
        if (root._targetName !== "")
            root._targetName = "";
    }

    // The name goes into a shell command, so it is only ever used when it is
    // made of the characters a PipeWire node name is made of. Anything else
    // is not quoted around -- it is refused.
    function _safeName(n) {
        return n.length > 0 && /^[A-Za-z0-9._:@+-]+$/.test(n);
    }

    on_TargetNameChanged: root._syncProc()
    onActiveChanged: {
        if (!root.active) {
            root._targetName = "";
            root._reset();
        }
        root._syncProc();
    }

    // ======================================================================
    // THE RECORDER
    // ======================================================================
    readonly property string _scriptPath: RepoRoot.dir + "/tools/player/audio_level_tap.py"

    // NEITHER `running` NOR `command` IS A BINDING, and that is the whole
    // reason this works. Bound, the two are updated in an order QML does not
    // promise: `running` can go true while `command` is still the placeholder
    // `["true"]`, which runs, exits within the millisecond, and -- because
    // Quickshell WRITES `running` false when a process exits -- destroys the
    // binding on it for good. The tap then sits there with a target, an active
    // flag, and no recorder, reporting 0.0000 for ever (measured: a target of
    // mpd.PipeWire and no recorder on every frame of a live run). Assigned in
    // one function instead, the command is always complete before the start.
    Process {
        id: proc
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function (line) {
                const v = parseFloat(line.split(" ")[0]);
                if (!isNaN(v)) root._step(Math.max(0, Math.min(1, v)), Date.now());
            }
        }
        onRunningChanged: if (!proc.running) root._reset()
    }

    function _syncProc() {
        proc.running = false;
        if (!root.active || root._targetName === "")
            return;
        // `setpriv --pdeathsig TERM` on the shell AND on each end of the pipe: a child does not die with quickshell unless told
        // to (CLAUDE.md), and a pipe's two ends are children of the shell, not of quickshell -- the shell's own pdeathsig
        // ends the shell, and each end's ends it when the shell is gone. Without them the pair outlives a killed shell for
        // hours (ppid 1, a PipeWire stream held).
        proc.command = [
            "setpriv", "--pdeathsig", "TERM", "--", "bash", "-c",
            "exec setpriv --pdeathsig TERM -- pw-cat --record --target=" + root._targetName
                + " --format=s16 --rate=8000 --channels=1 - 2>/dev/null"
                + " | exec setpriv --pdeathsig TERM -- python3 " + root._scriptPath
        ];
        proc.running = true;
    }

    // ======================================================================
    // THE MEASUREMENT
    //
    // One exponential per direction: dst += (target - dst) * (1 - exp(-dt/tau)),
    // which is frame-rate independent -- a 64 ms sample and a 200 ms watchdog
    // tick settle at the same speed in wall time rather than in samples.
    // ======================================================================
    property real _fast: 0
    property real _slow: 0
    property real _floorDb: -100
    property real _flux: 0           // running mean of the positive jump
    property real _prevFast: 0
    property real _intensity: 0
    property int _beatSeq: 0
    property real _beatStrength: 0
    property real _lastMs: 0
    property real _lastBeatMs: 0

    function _reset() {
        root._fast = 0; root._slow = 0; root._floorDb = -100;
        root._flux = 0; root._prevFast = 0; root._intensity = 0;
        root._beatStrength = 0; root._lastMs = 0;
    }

    // Level in dB, floored so a silent sample is a number rather than -inf.
    function _db(v) { return 20 * Math.log10(Math.max(v, 1e-5)); }

    function _lerpTau(cur, target, dt, tau) {
        return cur + (target - cur) * (1 - Math.exp(-dt / Math.max(1, tau)));
    }

    function _step(x, now) {
        // The first sample of a run SEEDS everything to itself. Left at zero
        // the floor is a hundred dB below the music and twenty seconds of
        // rise away from it, so a freshly opened tap would report a hard 1.000
        // for its first seconds and the rail would open with a shower. Seeded,
        // the floor IS the signal and the first frames read 0.
        if (root._lastMs === 0) {
            root._lastMs = now;
            root._fast = x; root._slow = x; root._floorDb = root._db(x);
            root._prevFast = x; root._flux = 0;
            root._intensity = 0;
            return;
        }
        const dt = Math.max(1, Math.min(500, now - root._lastMs));
        root._lastMs = now;

        root._fast = root._lerpTau(root._fast, x, dt, x > root._fast ? root.fastAttackMs : root.fastReleaseMs);
        root._slow = root._lerpTau(root._slow, x, dt, x > root._slow ? root.slowAttackMs : root.slowReleaseMs);

        // IN dB, AND WITH NO CEILING. A running ceiling in linear amplitude
        // keeps carrying the loud passage from before a volume change (its
        // decay is a fifteen-second exponential), so a run at 20% volume
        // reads 0.00-0.06 for as long as it lasts. dB above a floor needs no
        // ceiling at all -- a level change moves the floor and the signal
        // together, so the measure is SCALE-FREE by construction -- and the
        // floor is the one that falls fast. Measured on the real captures
        // spliced together, the 12 dB drop is recovered in 0.1 s, and the
        // loud and the quiet capture give the same distribution (mean 0.38
        // and 0.33).
        const d = root._db(root._slow);
        root._floorDb = root._lerpTau(root._floorDb, d, dt,
                                      d < root._floorDb ? root.floorFallMs : root.floorRiseMs);
        root._intensity = root._slow < root.silenceLevel
            ? 0
            : Math.max(0, Math.min(1, (d - root._floorDb) / Math.max(1, root.spanDb)));

        // The onset: how far `fast` JUMPED this sample, against how far it
        // normally jumps. A ratio to the running mean rather than to the level
        // itself, because a compressed master's level barely moves while its
        // transients still do.
        const jump = Math.max(0, root._fast - root._prevFast);
        root._prevFast = root._fast;
        const thr = Math.max(root._flux * root.beatFluxRatio,
                             root._slow * root.beatMinJumpFraction);
        if (root._slow >= root.silenceLevel && jump > thr
                && (now - root._lastBeatMs) > root.beatMinGapMs) {
            root._lastBeatMs = now;
            root._beatStrength = Math.max(root.beatMinStrength,
                                          Math.min(1, (jump / Math.max(1e-9, thr) - 1) / 2));
            root._beatSeq += 1;
        }
        root._flux = root._lerpTau(root._flux, jump, dt, root.fluxMeanMs);
    }

    // Samples stop arriving when the daemon pauses (the node stays, the audio
    // does not) and when the pipeline dies. Either way a frozen `level` would
    // leave the rail sparking at whatever it happened to be. This walks the
    // same step toward silence instead -- one code path, no second law.
    Timer {
        interval: 200
        running: proc.running
        repeat: true
        onTriggered: {
            const now = Date.now();
            if (root._lastMs !== 0 && now - root._lastMs > 200)
                root._step(0, now);
        }
    }
}
