.pragma library

// =============================================================================
// SleepRules.js -- the pure half of the sleep fade (SleepFade.qml): the fall's plan on the brightness keys' perceived ladder, the
// budget logind leaves it, when it may start, what a campaign file says, and the veil's per-screen facts. No Qt in here: node runs it;
// OsdKinds.js is handed in as `Osd` (LidRules.rampPlan's pattern), never imported.
// =============================================================================

// THE FALL (the mirror of LidRules.rampPlan, which is the climb): the panel goes from `saved` to 0 EVENLY IN HOW BRIGHT IT LOOKS -- the
// ladder position (OsdKinds.brightnessPos, gamma 2 by default) falls in equal steps, one write per `stepMs` over `ms`. The raws are
// strictly falling, below `saved`, and the last one is 0.
// -> { raws: [raw...], sleepS: seconds between writes }. A panel at 0 (or below 1) has nothing to fall: { raws: [], sleepS: 0 }.
// `ms` <= 0 is one write of 0, at once.
function fallPlan(Osd, saved, max, ladder, ms, stepMs) {
    var full = Math.round(Number(saved));
    if (!(full > 0))
        return { raws: [], sleepS: 0 };
    var m = Math.max(1, Math.round(Number(max)));
    full = Math.min(full, m);
    var o = ladder || {};
    var rungs = Osd.brightnessRungs(m, o.gamma, o.step, o.floorRaw);
    var start = Osd.brightnessPos(full, rungs);
    var n = ms > 0 ? Math.max(2, Math.round(ms / Math.max(1, stepMs))) : 1;
    var raws = [];
    for (var i = 1; i <= n; i++) {
        var r = i === n ? 0 : Osd.brightnessRawAt(start * (n - i) / n, rungs);
        r = Math.max(0, Math.min(full - 1, r));
        if (raws.length === 0 ? r < full : r < raws[raws.length - 1])
            raws.push(r);
    }
    if (raws.length === 0 || raws[raws.length - 1] !== 0)
        raws.push(0);
    return { raws: raws, sleepS: ms > 0 ? Math.round(ms / raws.length) / 1000 : 0 };
}

// THE BUDGET. logind waits for a delay inhibitor at most `capMs` (InhibitDelayMaxUSec) from the moment it sent PrepareForSleep(true);
// `t0` is when the shell heard it, a little later. The release is due `marginMs` before the cap (the kill, logind noticing the closed
// fd, the clock skew), and never later. -> the wall-clock deadline (ms).
function deadline(t0, capMs, marginMs) {
    var cap = capMs > 0 ? capMs : 5000;
    return t0 + Math.max(0, cap - Math.max(0, marginMs));
}

// When the fall starts: the moment the veil is done (`veilAt`, ms; NaN or 0 = not known yet), but never later than the deadline less the
// fall it wants -- a lock that is late, or none at all, does not cost the fade. -> ms.
function fallStart(now, veilAt, deadlineMs, fallMs) {
    var latest = deadlineMs - Math.max(0, fallMs);
    if (veilAt > 0 && isFinite(veilAt))
        return Math.max(now, Math.min(veilAt, latest));
    return Math.max(now, latest);
}

// How long the fall runs when it starts at `now`: what it wants, cut to what is left before the deadline. 0: no room, release at once.
function fallLength(now, deadlineMs, fallMs) {
    return Math.max(0, Math.min(Math.max(0, fallMs), deadlineMs - now));
}

// When the lock's veil is (or will be) done appearing, from what the shell mirrors of the lock (LockOwner.lockState):
//   veilAt > 0     the lock's own word: ms since epoch the veil had risen on every surface
//   veilAt 0       a lock that says it, and has not yet: not done (the deadline still starts the fall)
//   veilAt -1 / no such field   a lock that does not say (older than the field): lockedAt + leadMs -- the lock confirmed (secure) plus
//                  the blur-in's start and most of the veil's rise (1200 ms OutCubic: 97 % at 0.69 of it, ~1 s with the lead)
// A lock that is not locked (yet) has no veil: NaN. `state` may be null.
function veilDoneAt(state, leadMs) {
    if (!state || state.phase !== "locked")
        return NaN;
    if (typeof state.veilAt === "number" && state.veilAt > 0)
        return state.veilAt;
    if (state.veilAt === 0)
        return NaN;
    if (typeof state.lockedAt === "number" && state.lockedAt > 0)
        return state.lockedAt + Math.max(0, leadMs);
    return NaN;
}

// The suspend lab's campaign file (/var/lib/suspend-lab/campaign.json): a run is ACTIVE when its "status" is "running". Anything that
// does not parse is no campaign.
function campaignRunning(text) {
    try {
        var o = JSON.parse(String(text));
        return o !== null && typeof o === "object" && o.status === "running";
    } catch (e) {
        return false;
    }
}

// Does an output take part? `mode` "all" (a sleep: every output goes dark) or "panel" (the lid: the laptop panel only, an output whose
// name starts with `panelPrefix`). LARESLOCK-HOP (the lock's own headless output) never does.
function covers(mode, name, panelPrefix) {
    var n = String(name || "");
    if (n === "" || n === "LARESLOCK-HOP")
        return false;
    if (mode === "panel")
        return panelPrefix !== "" && n.indexOf(panelPrefix) === 0;
    return mode === "all";
}

// Does the veil dim this output itself? Only where the backlight does not: an output that is not the panel (an external screen), or the
// panel when its backlight is not ours to write (dGPU mode: no intel_backlight).
function selfDims(name, panelPrefix, backlightOurs) {
    var isPanel = panelPrefix !== "" && String(name || "").indexOf(panelPrefix) === 0;
    return !(isPanel && backlightOurs);
}

// The read step's "level <v> <m> <s>" line (or "nodevice") -> { ok, saved, max, state, given }. `saved` is the panel as it reads now, `max` its maximum, `state` the
// number in the brightness script's state file (-1 when there is none: the third word is `-`, or missing), and `given` THE LEVEL TO GIVE BACK:
// the state file's number when it is above what the panel reads now (SoftIdle dimmed the panel and saved the brightness it had BEFORE; the
// panel reads the dimmed value), else what the panel reads. Never above `max`. -1/-1/-1/-1 when the line does not parse.
function parseLevel(line) {
    var m = /^level (\d+) (\d+)(?: (\d+|-))?\s*$/.exec(String(line));
    if (!m)
        return { ok: false, saved: -1, max: -1, state: -1, given: -1 };
    var now = parseInt(m[1]);
    var mx = parseInt(m[2]);
    mx = mx >= 1 ? mx : 1;
    var st = m[3] === undefined || m[3] === "-" ? -1 : parseInt(m[3]);
    return { ok: true, saved: now, max: mx, state: st, given: st > now ? Math.min(st, mx) : now };
}

// `busctl get-property ... InhibitDelayMaxUSec` -> ms, or 0 when it does not parse ("t 5000000" -> 5000).
function parseCap(text) {
    var m = /^t (\d+)\s*$/.exec(String(text).trim());
    return m ? Math.round(parseInt(m[1]) / 1000) : 0;
}
