.pragma library

// =============================================================================
// SpeedDisplay.js -- what the two segment displays say while a speed test is asked, runs and is over. Pure: no Qt, held by tools/dev/aerial_life_probe.sh (every word it engraves is a baked variant).
//
// The 7-segment alphabet has the ten digits, the minus, `d` and `h` (modules/common/board/Figures.js): no "RUN?". So the DISPLAY blinks what it can say -- the
// cap in MB it would spend, in the cells the rates use (`d` + the figure) -- and the words ("Run a 200 MB test? Click again.", the refusal's reason) are a tag
// beside the display (`askText`). While it runs the rates display shows the live Mb/s with a phase mark in the first cell (`d` down, `h` up, `d - - -` while the
// latency is measured: the facts already do that); the usage display shows latency and jitter ("23.04": 23 ms, 04 ms). Over, the rates hold the download and
// then the upload, a second and a half each; both go back to their facts at the next open.
//
//   shown(speed, openedAtMs)        true while the test is the display's business: asked, running, or finished in THIS open
//   blinkOn(nowMs, periodMs)        the blink's phase
//   askText(speed, capMB, confirmed)  (confirmed: the refused test's confirming click is made)
//   engraving(speed, capMB, confirmed)  the question as the board's engraving beside the rates display ("RUN? 200 MB", "PUBLIC - RUN?"); "" when none is asked
//   units(speed, base, F, sinceDoneMs)  the engraved units while the test drives the displays ({ rates, usage })
//   ratesCells(speed, capMB, base, nowMs, F, sinceDoneMs)   the four cells of the rates display (the facts' own while not shown)
//   usageCells(speed, base, F)      the four cells of the usage display
// =============================================================================

var RUNNING = { latency: true, down: true, up: true };

function shown(speed, openedAtMs) {
    if (!speed)
        return false;
    var st = speed.state;
    if (st === "armed" || RUNNING[st] === true)
        return true;
    if ((st === "done" || st === "failed") && speed.result && speed.result.atMs > openedAtMs)
        return true;
    return false;
}

function askText(speed, capMB, confirmed) {
    if (!speed || speed.state !== "armed")
        return "";
    var mb = Math.round(capMB || 0);
    var cost = mb > 0 ? "about " + mb + " MB" : "some data";
    if (speed.refused !== "" && confirmed === true)
        return "Click once more to run it.";
    if (speed.refused === "public")
        return "This network is public: a speed test spends " + cost + ". Click again to confirm.";
    if (speed.refused === "metered")
        return "This network is metered: a speed test spends " + cost + ". Click again to confirm.";
    return "Run a speed test? It spends " + cost + ". Click again.";
}

// What the board's engraving beside the rates display says while the question stands (the silk is text, so it can use all the letters the cells cannot): the cap, or the
// refusal's reason; "" when nothing is asked (the engraving is then the plain `RATE - <unit>`).
function engraving(speed, capMB, confirmed) {
    if (!speed || speed.state !== "armed")
        return "";
    // (one of AerialGeometry SILK_VARIANTS.rates: the board's lettering is baked, so the words are fixed; the cap's FIGURE blinks on the display beside it, `d200`)
    if (speed.refused !== "" && confirmed === true)
        return "SURE? - MB";
    if (speed.refused === "public")
        return "PUBLIC NET?";
    if (speed.refused === "metered")
        return "METERED?";
    return "RUN? - MB";
}

// The units engraved beside the two displays while the test is the displays' business: Mb/s (or kb/s, Gb/s: the figure's own) while it runs and for the result shown,
// `ms` on the usage display while it shows latency and jitter. Armed, failed or not shown: the facts' own.
function units(speed, base, F, sinceDoneMs) {
    var out = { rates: base.rates, usage: base.usage };
    if (!speed)
        return out;
    var st = speed.state;
    if (st === "latency")
        out.rates = "Mb/s";
    else if (st === "down" || st === "up")
        out.rates = F.ratesUnit(speed.liveMbps || 0, true);
    else if (st === "done" && speed.result) {
        var since = sinceDoneMs > 0 ? sinceDoneMs : 0;
        var showUp = since < 9000 && Math.floor(since / 1500) % 2 === 1;
        out.rates = F.ratesUnit(showUp ? speed.result.upMbps : speed.result.downMbps, true);
    }
    if (st === "latency" || st === "down" || st === "up" || st === "done")
        out.usage = "ms";
    return out;
}

function blinkOn(nowMs, periodMs) {
    var p = periodMs > 0 ? periodMs : 700;
    return Math.floor(nowMs / p) % 2 === 0;
}

// the cap as the rates' cells: `d` then the MB figure, right-aligned (200 -> d 2 0 0; 1500 -> d - - - is never asked: the cap is at most 999 here)
function capCells(capMB, F) {
    var mb = Math.max(0, Math.min(999, Math.round(capMB || 0)));
    var h = Math.floor(mb / 100), t = Math.floor((mb % 100) / 10), u = mb % 10;
    return [F.D, h > 0 ? h : F.BLANK, h > 0 || t > 0 ? t : F.BLANK, u];
}

function ratesCells(speed, capMB, base, nowMs, F, sinceDoneMs) {
    if (!speed)
        return base;
    if (speed.state === "armed") {
        // blinking: a refused network blinks faster, and dark half the time reads as a question
        var fast = speed.refused !== "";
        return blinkOn(nowMs, fast ? 350 : 700) ? capCells(capMB, F) : [F.BLANK, F.BLANK, F.BLANK, F.BLANK];
    }
    if (speed.state === "latency")
        return [F.D, F.MINUS, F.MINUS, F.MINUS];
    if (speed.state === "down" || speed.state === "up")
        return base;                       // the facts' own: the live figure with `d` / `h` in the first cell
    if (speed.state === "done" && speed.result) {
        // down, then up, a second and a half each, for the first nine seconds; then it holds the download
        var since = sinceDoneMs > 0 ? sinceDoneMs : 0;
        var showUp = since < 9000 && Math.floor(since / 1500) % 2 === 1;
        return F.ratesCells(showUp ? speed.result.upMbps : speed.result.downMbps, true, showUp ? 13 : F.D);
    }
    if (speed.state === "failed")
        return [F.MINUS, F.MINUS, F.MINUS, F.MINUS];
    return base;
}

function usageCells(speed, base, F) {
    if (!speed)
        return base;
    var st = speed.state;
    if (st !== "latency" && st !== "down" && st !== "up" && st !== "done")
        return base;
    var r = speed.result;
    if (!r)
        return [F.MINUS, F.MINUS, F.MINUS, F.MINUS];
    var lat = Math.max(0, Math.min(99, Math.round(r.latencyMs || 0)));
    var jit = Math.max(0, Math.min(99, Math.round(r.jitterMs || 0)));
    return [Math.floor(lat / 10), (lat % 10) + F.DP, Math.floor(jit / 10), jit % 10];
}
