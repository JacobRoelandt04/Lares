.pragma library

// =============================================================================
// DownloadRules.js -- DownloadWatch's rules, with no Qt in them: which file names are a download in progress, and how an event of
// the download folder moves the state.
//
// A DOWNLOAD IS A PARTIAL FILE THAT STILL GROWS. The names a downloader leaves while it works:
//   *.part        Firefox, Zen and every Gecko browser; yt-dlp (and its `*.part-FragN` pieces); curl / wget with a -part suffix
//   *.crdownload  Chromium family
//   *.download    Safari-style and several download managers
//   *.aria2       aria2's control file, beside the data file it names (the data file is preallocated and written in place: its
//                 own MODIFY events count while the control file stands)
//   *.ytdl        yt-dlp's fragment bookkeeping, rewritten per fragment
// The name WITHOUT the suffix is the download's key. The state is { act: { key: lastActivityMs }, markers: { key: true } }:
// `act` is when each download last showed life (a create or a write; a rename or a delete ends it at once), `markers` the
// control files that stand (aria2's), plus `start`: when the current unbroken run of life began (a write after a stall of `stallMs`
// or more begins a new run). A download counts only once its run is `minAgeMs` old (DownloadWatch.minAgeMs says why).
// =============================================================================

var PART = /\.(part|crdownload|download)$|\.part-Frag\d+$/;
var MARKER = /\.(aria2|ytdl)$/;

// { kind: "part" | "marker" | "", key } for a file name.
function classify(name) {
    var n = String(name || "");
    if (n === "")
        return { kind: "", key: "" };
    if (PART.test(n))
        return { kind: "part", key: n.replace(PART, "") };
    if (MARKER.test(n))
        return { kind: "marker", key: n.replace(MARKER, "") };
    return { kind: "", key: "" };
}

function newState() {
    return { act: {}, start: {}, markers: {} };
}

// A sign of life for `key` at nowMs: the age starts at the first one, and again after a stall of stallMs or more.
function touch(state, key, nowMs, stallMs) {
    var a = state.act[key];
    if (a === undefined || nowMs - a >= stallMs)
        state.start[key] = nowMs;
    state.act[key] = nowMs;
}

// One line of `inotifywait --format '%e %f'`: "MODIFY name.part", "MOVED_FROM x.crdownload", "CREATE,ISDIR sub". Returns true when
// the state changed in a way that can change the answer (a first activity, or an end).
function apply(state, line, nowMs, stallMs) {
    var s = String(line || "");
    var sp = s.indexOf(" ");
    if (sp < 0)
        return false;
    var ev = s.substring(0, sp);
    var name = s.substring(sp + 1);
    if (ev.indexOf("ISDIR") >= 0)
        return false;
    var c = classify(name);
    var ends = ev.indexOf("DELETE") >= 0 || ev.indexOf("MOVED_FROM") >= 0;
    var lives = ev.indexOf("CREATE") >= 0 || ev.indexOf("MODIFY") >= 0 || ev.indexOf("MOVED_TO") >= 0;
    if (c.kind === "") {
        // The data file of a download with a control file: its writes are the growth.
        if (lives && state.markers[name] === true && ev.indexOf("MOVED_TO") < 0) {
            var was = state.act[name] !== undefined && state.act[name] !== null;
            touch(state, name, nowMs, stallMs);
            return !was;
        }
        if (ends && state.markers[name] === true) {
            delete state.act[name];
            delete state.start[name];
            return true;
        }
        return false;
    }
    if (ends) {
        var had = state.act[c.key] !== undefined;
        delete state.act[c.key];
        delete state.start[c.key];
        if (c.kind === "marker")
            delete state.markers[c.key];
        return had;
    }
    if (!lives)
        return false;
    if (c.kind === "marker")
        state.markers[c.key] = true;
    var before = state.act[c.key] !== undefined;
    touch(state, c.key, nowMs, stallMs);
    return !before;
}

// The downloads that have shown life within stallMs of now AND whose unbroken run is minAgeMs old, oldest activity first.
function growing(state, nowMs, stallMs, minAgeMs) {
    var out = [];
    for (var k in state.act)
        if (nowMs - state.act[k] < stallMs && nowMs - state.start[k] >= minAgeMs)
            out.push({ key: k, at: state.act[k] });
    out.sort(function (a, b) { return a.at - b.at; });
    return out.map(function (e) { return e.key; });
}

// When the answer can next change on its own (ms from now; 0 when nothing can): for each download still showing life, the instant it
// comes of age while it is young (a stall before that changes nothing: it only moves that instant, and the timer's wake re-reads), and
// its stall once it counts.
function untilChange(state, nowMs, stallMs, minAgeMs) {
    var best = 0;
    for (var k in state.act) {
        if (nowMs - state.act[k] >= stallMs)
            continue;
        var left = nowMs - state.start[k] >= minAgeMs ? state.act[k] + stallMs - nowMs : state.start[k] + minAgeMs - nowMs;
        if (left > 0 && (best === 0 || left < best))
            best = left;
    }
    return best;
}

// Forget the entries long past their stall (a download that was abandoned with its partial file standing).
function prune(state, nowMs, stallMs) {
    for (var k in state.act)
        if (nowMs - state.act[k] >= stallMs * 6) {
            delete state.act[k];
            delete state.start[k];
        }
}
