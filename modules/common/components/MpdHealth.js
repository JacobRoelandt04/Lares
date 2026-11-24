.pragma library

// =============================================================================
// MpdHealth.js -- what is wrong with the music, in plain words. Pure: facts in,
// one diagnosis out. MpdHealth.qml gathers the facts and acts; this file only
// decides, so every cause and every sentence is a node-testable case.
//
// THE REAL CASE: a USB DAC locked at the hardware level,
// PipeWire logged `alsa_output.usb-ACME... suspended -> error`, wireplumber sat in
// state D (uninterruptible kernel sleep) on usb_start_wait_urb, and mpd said it was playing
// while pause/play reset the position to 0:00 and no sound came. mpd was fine. Nothing a
// player could restart would have helped, and a blind `systemctl restart wireplumber` waits
// on the D-state process for the stop timeout: so the diagnosis names WHICH layer is
// broken and offers a button only for the causes a button can cure.
//
// THE SIGNALS (what MpdHealth.qml measures):
//   down      the command socket has been down longer than the grace
//   stuck     a command has been in flight longer than the deadline (mpd does not answer)
//   error     mpd's own `status.error` (fresh, and the player is not simply playing on)
//   stalled   state is play and the daemon's OWN position has not moved for `stallMs`
//             (never the interpolated one: the interpolation hides exactly this)
// and one read-only look at the audio path (tools/player/audio_diagnose.py):
//   pw           how pw-dump answered: ok | timeout | missing | error
//   sinks        [{ name, desc, state, error, default }]  (state: running idle suspended error)
//   procs        { mpd: ["S"], wireplumber: ["D"], pipewire: [...] }  kernel state letters
//   wchan        { wireplumber: "usb_start_wait_urb" }
//
// THE ORDER OF CAUSES is the order of what can be fixed from where: mpd gone or unreachable
// first (nothing else can be verified), then the hardware and the audio server (root causes of
// every other symptom), then mpd's own output. A button exists only where it can work:
//   mpd-down         Start mpd
//   mpd-unreachable  Restart mpd            (running, refuses connections)
//   mpd-unresponsive Restart mpd            (running, not answering)
//   mpd-stuck        none                   (state D: it cannot be killed; the device is the cure)
//   device-error     Restart audio session  (sink in error, wireplumber alive)
//   device-hung      none                   (wireplumber/pipewire in D: re-plug the device)
//   server-hung      Restart audio          (pw-dump timed out, pipewire alive)
//   no-sink          none                   (nothing to play to)
//   output-error     Try again              (mpd's own words)
//   output-stuck     Reopen the output
// =============================================================================

var STALL_MS = 6000;
var STALL_EPS = 0.25;      // seconds of position that count as "moved"

// ---- the stall window ------------------------------------------------------
// win: { t, el, id, still } of the previous sample (null at first).
// sample: { t (ms), elapsed (s), songid, state }.
// `still` is how long the daemon's own position has stood still, in ms, while it said play.
// The reference position stays where the stillness began, so a trickle of 0.1 s per sample
// (a decoder that crawls) adds up to a move at the third sample instead of resetting each time.
function stallStep(win, sample) {
    if (!sample)
        return { t: 0, el: 0, id: -1, still: 0 };
    if (sample.state !== "play" || !win || win.id !== sample.songid)
        return { t: sample.t, el: sample.elapsed, id: sample.songid, still: 0 };
    var moved = Math.abs(sample.elapsed - win.el) >= STALL_EPS;
    if (moved)
        return { t: sample.t, el: sample.elapsed, id: sample.songid, still: 0 };
    return { t: sample.t, el: win.el, id: sample.songid, still: win.still + Math.max(0, sample.t - win.t) };
}
function isStalled(win, stallMs) {
    return !!win && win.still >= (stallMs > 0 ? stallMs : STALL_MS);
}

function _sinkWords(sink) {
    if (!sink) return "the audio device";
    return sink.desc || sink.name || "the audio device";
}
function _anyD(procs, name) {
    var l = procs && procs[name];
    if (!l) return false;
    for (var i = 0; i < l.length; i++) if (l[i] === "D") return true;
    return false;
}
function _alive(procs, name) {
    var l = procs && procs[name];
    return !!l && l.length > 0;
}
function _defaultSink(probe) {
    var s = probe.sinks || [];
    for (var i = 0; i < s.length; i++) if (s[i].default) return s[i];
    return null;
}
// The sink that matters: the default one; with no default, an errored one if any.
function _errorSink(probe) {
    var d = _defaultSink(probe);
    if (d) return d.state === "error" ? d : null;
    var s = probe.sinks || [];
    for (var i = 0; i < s.length; i++) if (s[i].state === "error") return s[i];
    return null;
}
function _wchan(p) {
    var w = p.wchan || {};
    var k = w.wireplumber || w.pipewire || w.mpd || "";
    return k ? " (" + k + ")" : "";
}
function _stuckHint(p) {
    var d = _defaultSink(p);
    return d ? "Unplug " + _sinkWords(d) + " and plug it in again." : "Unplug the USB audio device you used last and plug it in again.";
}

function _d(kind, severity, title, words, hint, action, device) {
    return { kind: kind, severity: severity, title: title, words: words, hint: hint || "",
             action: action || null, needsProbe: false, device: device || "" };
}

var OK = { kind: "ok", severity: "", title: "", words: "", hint: "", action: null, needsProbe: false, device: "" };
var CHECKING = { kind: "checking", severity: "warn", title: "Checking the audio",
                 words: "Something is not right; looking at what.", hint: "", action: null, needsProbe: true, device: "" };

// f: { down, stuck, error, stalled, errorText, probe (object|null) }
function diagnose(f) {
    if (!f.down && !f.stuck && !f.error && !f.stalled) return OK;
    var p = f.probe;
    if (!p) return CHECKING;
    var procs = p.procs || {};

    // 1. mpd itself
    if (f.down) {
        if (_anyD(procs, "mpd"))
            return _d("mpd-stuck", "error", "mpd is stuck",
                      "mpd is waiting on the sound device and cannot be stopped from here.", _stuckHint(p));
        if (_alive(procs, "mpd"))
            return _d("mpd-unreachable", "error", "mpd is not answering", "mpd is running but refuses connections.", "",
                      { id: "restart-mpd", label: "Restart mpd" });
        return _d("mpd-down", "error", "mpd is not running", "The player has no music daemon to talk to.", "",
                  { id: "start-mpd", label: "Start mpd" });
    }

    // 2. the hardware and the audio server: the root of every other symptom
    var bad = _errorSink(p);
    var wpD = _anyD(procs, "wireplumber") || _anyD(procs, "pipewire") || _anyD(procs, "pipewire-pulse");
    if (bad || wpD) {
        var dev = _sinkWords(bad || _defaultSink(p));
        if (wpD)
            return _d("device-hung", "error", bad ? dev + " is locked up" : "The audio system is stuck",
                      "The audio session manager is waiting on the hardware" + _wchan(p) + " and cannot be restarted.",
                      bad ? "Unplug " + dev + " and plug it in again." : _stuckHint(p), null, dev);
        return _d("device-error", "error", dev + " stopped answering",
                  "The audio server reports an error on this output, so nothing can be played to it.", "",
                  { id: "restart-audio", label: "Restart audio session" }, dev);
    }
    if (p.pw === "timeout")
        return _d("server-hung", "error", "The audio server is not answering",
                  "PipeWire did not reply in time, so the music has nowhere to go.", "",
                  { id: "restart-audio-server", label: "Restart audio" });
    if (p.pw === "ok" && (p.sinks || []).length === 0)
        return _d("no-sink", "error", "No audio output", "The audio server has no device to play to.",
                  "Plug in or switch on an output.");

    // 3. mpd's own side
    if (f.stuck) {
        if (_anyD(procs, "mpd"))
            return _d("mpd-stuck", "error", "mpd is stuck",
                      "mpd is waiting on the sound device and cannot be stopped from here.", _stuckHint(p));
        return _d("mpd-unresponsive", "error", "mpd stopped answering", "mpd is running but does not answer commands.", "",
                  { id: "restart-mpd", label: "Restart mpd" });
    }
    if (f.error)
        return _d("output-error", "error", "Playback failed", f.errorText || "mpd reported an error.", "",
                  { id: "retry-output", label: "Try again" });
    return _d("output-stuck", "warn", "Nothing is playing",
              "mpd says it is playing but the position has stopped moving.", "",
              { id: "retry-output", label: "Reopen the output" });
}

// The audio_diagnose.py output (a JSON string) -> the probe object, or a probe that says it failed.
function parseProbe(text) {
    try {
        var o = JSON.parse(String(text || ""));
        if (o && typeof o === "object") {
            if (!o.sinks) o.sinks = [];
            if (!o.procs) o.procs = {};
            return o;
        }
    } catch (e) { }
    return { pw: "error", sinks: [], procs: {}, wchan: {} };
}

// Whether a probe holds the audio path healthy enough to play: the server answers, a default
// sink exists and is not in error, and nothing is in uninterruptible sleep. Used while waiting
// for a restarted session manager to bring the device back.
function audioPathUp(p) {
    if (!p || p.pw !== "ok") return false;
    var procs = p.procs || {};
    if (_anyD(procs, "wireplumber") || _anyD(procs, "pipewire") || _anyD(procs, "pipewire-pulse")) return false;
    var d = _defaultSink(p);
    return !!d && d.state !== "error";
}
