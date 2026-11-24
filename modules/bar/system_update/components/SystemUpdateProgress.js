.pragma library

// =============================================================================
// SystemUpdateProgress.js -- how far through the WHOLE RUN a system update is, as one number.
//
// The rail in the popup shows where the run is (its notches) and how far through the current notch it
// is; the bar's button wants a single figure for the run. A run is
// not one kind of work: it syncs and resolves (seconds, and the user's own reading time), fetches the
// AUR sources, downloads the official packages (bytes), installs them (a count), runs hooks, and
// builds and installs the AUR ones. Each step's own progress is honest (a byte count, a package count)
// but a bar that gave every step a fifth would sit on "download" for a quarter of an hour of a
// 6 GiB update and fly through a 140 MiB one. So every step is WEIGHTED BY WHAT THE RUN'S OWN PLAN
// SAYS about it -- the parser knows the counts and the download size -- and the figure is the weight of
// the steps behind plus the share of the current one.
//
// PURE: no Qt. The state object it is handed is
// the caller's (SystemUpdateRunProgress.qml keeps one per run) and it only ever moves FORWARD: the step
// index, each step's own fraction, and the figure are high-water marks -- a plan that firms up (the
// table, the AUR count) can move a step's weight, but the bar never goes back (the same rule as the rail).
//
// THE WEIGHTS are estimates, in seconds, of how long each kind of work takes on this machine class;
// only their RATIOS matter. They are calibrated on a real run that has all of them
// (525 official + 13 AUR packages, 6.4 GiB; sync 10 s, resolve 106 (a person reading
// the list), AUR sources 891, download 732, install 618, hooks 273, AUR builds and install 416 --
// 3049 s). Change them HERE, in one place.
// =============================================================================

var WEIGHTS = {
    sync: 8,
    resolve: 8,
    // per AUR package: its sources fetched (a real run: 891 s for 13, nearly all of it three
    // big -bin downloads) ...
    sourcesPerPkg: 45,
    // ... official download: MiB per second the whole run is assumed to pull ...
    downloadMiBPerSec: 6,
    // ... and when the table has not been read yet: the size of an average package in the transaction
    avgPkgMiB: 12,
    // install: a fixed beat for the pre-transaction hooks, and per package
    installFixed: 4,
    installPerPkg: 1.2,
    // post-transaction hooks: fixed, and per official package (DKMS, the initramfs and the caches
    // scale with what changed)
    hooksFixed: 12,
    hooksPerPkg: 0.35,
    // per AUR package: build and install
    aurPerPkg: 25,
    // the snapshot the pre-transaction hook takes before a large update (restic: the first one on this
    // machine took ~9 minutes, the later ones read the changes only -- 25 s is a later one)
    snapshot: 25
};

var STEPS = ["sync", "resolve", "sources", "download", "snapshot", "install", "hooks", "aur"];

// A fresh state for a new run.
function newState() {
    return { key: "", within: {}, fraction: 0 };
}

// The plan, from the snapshot: which steps this run has, and the weight (seconds) of each.
//   S.hasAur            the run has AUR work (the upgrade list named an AUR package)
//   S.aurCount          how many
//   S.packages          every package of the upgrade list, AUR included (":: N packages to upgrade/install")
//   S.totalDownloadBytes  pacman's "Total Download Size", once its table has been read (0 until then)
//   S.hasSnapshot       the run has a snapshot step (the rule asked for one, or the hook spoke): only then
//                       does the plan carry it, so a run without one is the figure it always was
//   S.kind              "update" (default) | "undo": an undo has no sync and no download (pacman -U)
function plan(S) {
    var aurN = Math.max(0, S.aurCount || 0);
    var hasAur = aurN > 0;
    var official = Math.max(0, (S.packages || 0) - aurN);
    var mib = S.totalDownloadBytes > 0 ? S.totalDownloadBytes / 1048576 : official * WEIGHTS.avgPkgMiB;
    var w = {};
    var undo = S.kind === "undo";
    if (!undo) w.sync = WEIGHTS.sync;
    w.resolve = WEIGHTS.resolve;
    if (hasAur) w.sources = Math.max(1, aurN) * WEIGHTS.sourcesPerPkg;
    if (!undo) w.download = Math.max(1, mib / WEIGHTS.downloadMiBPerSec);
    if (S.hasSnapshot) w.snapshot = WEIGHTS.snapshot;
    w.install = WEIGHTS.installFixed + official * WEIGHTS.installPerPkg;
    w.hooks = WEIGHTS.hooksFixed + official * WEIGHTS.hooksPerPkg;
    if (hasAur) w.aur = Math.max(1, aurN) * WEIGHTS.aurPerPkg;
    var order = [];
    for (var i = 0; i < STEPS.length; i++)
        if (w[STEPS[i]] !== undefined) order.push(STEPS[i]);
    return { weights: w, order: order };
}

// The step the parser's phase belongs to (the popup's own mapping, minus its prompt rule: the
// high-water index makes the wait at pacman's question harmless here).
function stepOf(S) {
    var phase = S.phase || "INITIAL";
    switch (phase) {
    case "INITIAL":
        return S.kind === "undo" ? "resolve" : "sync";
    case "DB_SYNC_1": case "DB_SYNC_2": case "AUR_SEARCH":
        return "sync";
    case "UPGRADE_LIST": case "GROUPED_SUMMARY": case "PKGBUILD_CACHE": case "SRCINFO_PARSE":
    case "PROMPT_EXCLUDE": case "PROMPT_CLEANBUILD": case "PROMPT_DIFFS": case "PROMPT_EDIT_PKGBUILD":
        return "resolve";
    case "AUR_SRC_FETCH":
        return S.aurCount > 0 ? "sources" : "resolve";
    case "AUR_BUILD_LOOP": case "AUR_INSTALL":
        return "aur";
    }
    switch (S.subPhase || "") {
    case "L0_RESOLVE": case "L1_TABLE": return "resolve";
    case "L2_DOWNLOAD": return "download";
    // the snapshot hook is the first pre-transaction hook: until it has said it is through, the pre-hooks
    // are its step (the popup's rail does the same)
    // (and the integrity checks before them: the notch holds the ball through the verification, like the popup's)
    case "L3_INTEGRITY": case "L4_PREHOOKS":
        if (S.hasSnapshot && (S.snapshotState === "" || S.snapshotState === "running" || S.snapshotState === "failed")) return "snapshot";
        return "install";
    case "N3_INTEGRITY": case "L5_CHANGES": case "N5_CHANGES":
        return "install";
    case "L6_POSTHOOKS": case "N6_POSTHOOKS": return "hooks";
    }
    return "resolve";
}

function _clamp01(x) {
    return x < 0 ? 0 : x > 1 ? 1 : x;
}

// How far through ITS OWN step the run is (0..1), from the counters the parser keeps. A step with nothing
// countable (sync, resolve) is 0 until the next one begins.
function stepFraction(step, S) {
    switch (step) {
    case "sources":
        if (!(S.aurCount > 0)) return 0;
        return _clamp01(((S.aurSourcesDone || 0) + (S.sourceFetchPct >= 0 ? S.sourceFetchPct / 100 : 0)) / S.aurCount);
    case "download":
        if (S.downloadPct >= 0) return _clamp01(S.downloadPct / 100);
        if (S.downloadsTotal > 0) return _clamp01(S.downloadsDone / S.downloadsTotal);
        return 0;
    case "install": {
        // the pre-transaction hooks take the first tenth, the package changes the rest (the popup's rail
        // does the same, so the two never disagree about the groove)
        var PRE = 0.1;
        if (S.subPhase === "L4_PREHOOKS")
            return S.hooksTotal > 0 ? PRE * _clamp01(S.hooksDone / S.hooksTotal) : 0;
        if (S.subPhase === "L5_CHANGES" || S.subPhase === "N5_CHANGES")
            return S.installsTotal > 0 ? PRE + (1 - PRE) * _clamp01(S.installsDone / S.installsTotal) : PRE;
        if (S.subPhase === "L3_INTEGRITY" || S.subPhase === "N3_INTEGRITY") return 0;
        return 0;
    }
    case "snapshot":
        return _clamp01(S.snapshotProgress >= 0 ? S.snapshotProgress : 0);
    case "hooks":
        return S.hooksTotal > 0 ? _clamp01(S.hooksDone / S.hooksTotal) : 0;
    case "aur": {
        // the builds are four fifths, pacman's second transaction the rest
        var BUILD = 0.8;
        if (S.phase === "AUR_INSTALL") {
            var tx = 0;
            if (S.subPhase === "N5_CHANGES")
                tx = S.installsTotal > 0 ? 0.8 * _clamp01(S.installsDone / S.installsTotal) : 0;
            else if (S.subPhase === "N6_POSTHOOKS")
                tx = 0.8 + 0.2 * (S.hooksTotal > 0 ? _clamp01(S.hooksDone / S.hooksTotal) : 0);
            return BUILD + (1 - BUILD) * tx;
        }
        return S.aurCount > 0 ? BUILD * _clamp01((S.aurBuildsDone || 0) / S.aurCount) : 0;
    }
    }
    return 0;
}

// One reading of the run. Returns the state, moved forward: `fraction` (0..1) is the high-water figure,
// `key` the furthest step reached. The high-water mark is held BY KEY: the plan grows while the run goes
// (the AUR packages are found in the upgrade list, after the run is already past Sync), and an index
// into a plan that has just gained a step is another step -- the popup's rail would shoot to Install on it.
//   S.phase COMPLETE (and exitCode 0)  the run is over and clean: 1. A failed run holds where it stopped.
function advance(state, S) {
    var p = plan(S);
    var rawKey = stepOf(S);
    var rank = function (k) { return STEPS.indexOf(k); };
    // a raw step the plan has no step for (AUR work named late) keeps the furthest one reached
    if (p.weights[rawKey] !== undefined && rank(rawKey) > rank(state.key))
        state.key = rawKey;
    var cur = state.key !== "" ? state.key : p.order[0];
    var within = state.within[cur] || 0;
    if (rawKey === cur) within = Math.max(within, stepFraction(cur, S));
    state.within[cur] = within;
    var total = 0, done = 0;
    for (var i = 0; i < p.order.length; i++) {
        var w = p.weights[p.order[i]];
        total += w;
        if (rank(p.order[i]) < rank(cur)) done += w;
    }
    var curW = p.weights[cur] !== undefined ? p.weights[cur] : 0;
    var f = total > 0 ? (done + curW * within) / total : 0;
    var complete = S.phase === "COMPLETE" || S.phase === "DONE";
    if (complete && (S.exitCode === undefined || S.exitCode === 0))
        f = 1;
    else if (f >= 1)
        f = 0.99;       // a figure that has not reached the end stops short of it: 100 is "complete" and nothing else
    if (f > state.fraction)
        state.fraction = f;
    return state;
}

// The whole-percent figure for a state: floor, so 99.9 % is still 99 and a run is 100 only when it is.
function percent(state) {
    return Math.max(0, Math.min(100, Math.floor(state.fraction * 100 + 1e-9)));
}

// What the phase mark beside the figure shows: the popup's own glyph rule for the card ("download" for the
// syncs, the download and the source fetch; "cog" for builds and hooks; "disk" for writing packages),
// then the states that outrank it.
function markKind(S) {
    if (S.awaiting) return "ask";
    if (S.failing) return "fail";
    var phase = S.phase || "INITIAL";
    var sub = S.subPhase || "";
    if (sub === "L2_DOWNLOAD") return "download";
    if (phase === "AUR_SRC_FETCH") return "download";
    if (phase === "DB_SYNC_1" || phase === "DB_SYNC_2" || phase === "AUR_SEARCH") return "download";
    if (phase === "AUR_BUILD_LOOP") return "cog";
    if (sub === "L4_PREHOOKS" || sub === "L6_POSTHOOKS" || sub === "N6_POSTHOOKS") return "cog";
    if (sub === "L5_CHANGES" || sub === "N5_CHANGES" || phase === "OFFICIAL_INSTALL" || phase === "AUR_INSTALL")
        return "disk";
    return "download";
}
