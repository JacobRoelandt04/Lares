#!/usr/bin/env node
// Daylight saving across the shell's wall-clock code, table-tested under node (PD stream EDGE, phase 1).
//
//   node tools/dev/dst_audit_cases.js            must end DST-AUDIT RESULT PASS (phase 2's goal; today it lists FINDINGs, exit 1)
//   node tools/dev/dst_audit_cases.js --audit    prints every case, exits 0 whatever it found (the phase-1 table)
//   node tools/dev/dst_audit_cases.js --arm      proves the harness can fail: a deliberately wrong expectation is a FINDING
//
// The machine's zone and clock are not touched: the run sets process.env.TZ itself (Europe/Brussels, the user's; DST_TZ
// overrides for an A/B) before any Date exists, and every expected value comes from Intl.DateTimeFormat in that zone (an
// oracle that is not shell code) or from the instant the case builds. The system clock is never read for a verdict: each
// case hands the code its own `now`.
//
// The shell's `.pragma library` files are loaded the osd_js_cases way: the pragma is stripped, `.import "X.js" as Y` becomes
// a load of that file into Y, the rest is evaluated in a vm context. A QML function (WeatherService.brusselsDateKey,
// LlmSidebar._dateGroupOf, WikiService._nextAfter) is cut out of its .qml by name, so the case runs the shipped text; an
// INLINE expression that cannot be cut out (TimersCard's alarm caption) is mirrored with an anchor that fails the case when
// the .qml line it mirrors changes.
//
// TWO ENGINES. Node's V8 and the shell's QV4 disagree about a local time the spring-forward skips (V8 moves it forward to
// 03:30, QV4 BACKWARDS to 01:30; CLAUDE.md measured it) and may about a repeated one, so everything that constructs a local
// time inside a transition hour runs in QV4: this file writes a small QML harness to the temp dir, runs it with
// /usr/lib/qt6/bin/qml (offscreen, no window, no Quickshell, the same TZ) and judges its answers here.
//
// Every verdict line: `DST <id> ok` or `DST <id> FINDING [low|medium|high] <what goes wrong>`.
process.env.TZ = process.env.DST_TZ || "Europe/Brussels";
const fs = require("fs");
const os = require("os");
const path = require("path");
const vm = require("vm");
const cp = require("child_process");

const ROOT = path.join(__dirname, "..", "..");
const MOD = process.env.DST_MOD || path.join(ROOT, "modules");        // DST_MOD: a sandbox copy with a fault put back (the ARMs)
const args = process.argv.slice(2);
const AUDIT = args.includes("--audit");
const ARM = args.includes("--arm");
const QML = process.env.DST_QML || "/usr/lib/qt6/bin/qml";

// ------------------------------------------------------------------------------------------------ loading
const cache = {};
function loadLib(file) {
    file = path.resolve(file);
    if (cache[file]) return cache[file];
    let src = fs.readFileSync(file, "utf8");
    src = src.replace(/^\.pragma library.*$/m, "");
    src = src.replace(/^\.import\s+"([^"]+)"\s+as\s+(\w+)\s*$/gm, (m, rel, name) =>
        "var " + name + " = __load(" + JSON.stringify(path.resolve(path.dirname(file), rel)) + ");");
    const ctx = { __load: loadLib, console: console, Date: Date, Math: Math, JSON: JSON, Number: Number, String: String,
                  Object: Object, Array: Array, isFinite: isFinite, isNaN: isNaN, parseInt: parseInt, parseFloat: parseFloat,
                  RegExp: RegExp, Error: Error };
    vm.createContext(ctx);
    vm.runInContext(src, ctx, { filename: file });
    cache[file] = ctx;
    return ctx;
}
const lib = (rel) => loadLib(path.join(MOD, rel));

// The text of a function cut out of a .qml by name (any indent), QML-only names rewritten by `replace`.
function qmlFunctionText(rel, name, replace) {
    const text = fs.readFileSync(path.join(MOD, rel), "utf8");
    const m = new RegExp("^( *)function " + name + "\\(([^)]*)\\)[^{]*\\{", "m").exec(text);
    if (!m) throw new Error("function " + name + " not found in " + rel);
    const rest = text.slice(m.index);
    const end = new RegExp("^" + m[1] + "\\}", "m").exec(rest.slice(1));
    let body = rest.slice(0, end.index + 1 + end[0].length).replace(/^ */, "");
    for (const [a, b] of (replace || [])) body = body.split(a).join(b);
    return body;
}
// The function, evaluated in V8 with `globals` in scope (fine for code with no transition-hour local times).
function qmlFunction(rel, name, replace, globals) {
    const ctx = Object.assign({ Date: Date, Math: Math }, globals || {});
    vm.createContext(ctx);
    vm.runInContext(qmlFunctionText(rel, name, replace), ctx);
    return ctx[name];
}
function mirrorAnchor(rel, needle) {
    return fs.readFileSync(path.join(MOD, rel), "utf8").includes(needle);
}

// ------------------------------------------------------------------------------------------------ oracle
const BRU = new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/Brussels", hourCycle: "h23", year: "numeric", month: "2-digit",
    day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" });
function bru(ms) {
    const o = {};
    for (const p of BRU.formatToParts(new Date(ms))) o[p.type] = p.value;
    return { y: +o.year, mo: +o.month, d: +o.day, h: +o.hour, mi: +o.minute, key: o.year + "-" + o.month + "-" + o.day, hm: o.hour + ":" + o.minute };
}
const U = (y, mo, d, h, mi) => Date.UTC(y, mo - 1, d, h || 0, mi || 0, 0);
const H = 3600000, DAY = 86400000;
const p2 = (n) => (n < 10 ? "0" : "") + n;
// The changes this run reasons about (Europe/Brussels is CET +1 / CEST +2; the EU rule moves at 01:00 UTC).
const SPRING26 = U(2026, 3, 29, 1), FALL26 = U(2026, 10, 25, 1), SPRING27 = U(2027, 3, 28, 1);

// ------------------------------------------------------------------------------------------------ verdicts
// A section that throws (a function the code under test no longer has, a malformed answer) is a FINDING, not the end of the run.
function run(name, fn) {
    try { fn(); } catch (e) { check("X-" + name, "high", false, "section '" + name + "' threw: " + (e && e.message)); }
}
let findings = 0, cases = 0;
const QUIET = args.includes("--arms");
function check(id, sev, ok, detail) {
    cases++;
    if (QUIET) { if (!ok) findings++; return; }
    if (ok) {
        console.log("DST " + id + " ok" + (detail && AUDIT ? "  (" + detail + ")" : ""));
    } else {
        findings++;
        console.log("DST " + id + " FINDING [" + sev + "] " + detail);
    }
}

// ================================================================================================ WEATHER
// Open-Meteo labels EVERY timestamp of a response at ONE offset, `utc_offset_seconds`, the zone's offset at the REQUEST
// instant. Measured 2026-11-06 against the live forecast and archive endpoints (timezone=Europe/Brussels, today CET): the
// sunrise labels of 1 Jul, 10 Aug and 24 Oct -- summer days all -- are CET clock times (the sun's altitude at label minus 1 h
// is -0.83 deg on all three, at label minus 2 h -7 to -10 deg), utc_offset_seconds is 3600 for every window, and the
// hourly arrays hold exactly 24 entries on 29 Mar and 25 Oct (labels 00:00..23:00, including the 02:00 that 29 Mar does not
// have). The September fixture (requested in CEST, offset 7200) reads as CEST throughout. WeatherModel.js assumes instead
// that the labels follow the Brussels rule per timestamp: the same until a window crosses a change, wrong by an hour on the
// far side of it when it does (the 16 days before each change).
function weatherScenario(requestUtc, firstDayUtc, nDays) {
    const WM = lib("weather/data/WeatherModel.js"), Astro = lib("weather/data/Astro.js");
    const frame = WM.brusselsOffset(requestUtc);                // what the API reports, in seconds
    const lat = 50.85, lon = 4.35;
    const label = (trueMs) => { const d = new Date(trueMs + frame * 1000);
        return d.getUTCFullYear() + "-" + p2(d.getUTCMonth() + 1) + "-" + p2(d.getUTCDate()) + "T" + p2(d.getUTCHours()) + ":" + p2(d.getUTCMinutes()); };
    const t0 = firstDayUtc - frame * 1000;                      // frame midnight of the first day, as a true instant
    const time = [], temp = [], isDay = [], dtime = [], rise = [], set = [], truth = { rise: [], set: [] };
    for (let i = 0; i < nDays * 24; i++) {
        const t = t0 + i * H;
        time.push(label(t)); temp.push(i);                      // the figure is the hour's index: its true instant is t0 + i h
        isDay.push(Astro.sunAltitudeDeg(t, lat, lon) > -0.833 ? 1 : 0);
    }
    for (let d = 0; d < nDays; d++) {
        const a = t0 + d * DAY;
        const c = Astro.crossings((ms) => Astro.sunAltitudeDeg(ms, lat, lon), a, a + DAY, -0.833, 5);
        const up = c.find((x) => x.rising), dn = c.find((x) => !x.rising);
        dtime.push(label(a).slice(0, 10)); rise.push(label(up.ms)); set.push(label(dn.ms));
        truth.rise.push(up.ms); truth.set.push(dn.ms);
    }
    const forecast = { latitude: lat, longitude: lon, utc_offset_seconds: frame, timezone: "Europe/Brussels",
        hourly: { time: time, temperature_2m: temp, is_day: isDay, weather_code: time.map(() => 1) },
        daily: { time: dtime, sunrise: rise, sunset: set } };
    return { WM, forecast, truth, t0 };
}

run("weather", function () {
    const scenarios = [
        ["W1-fall", "requested 2026-10-20 12:00 CEST (offset 7200), window 20-28 Oct crosses the 25 Oct change", U(2026, 10, 20, 10), U(2026, 10, 20), U(2026, 10, 24, 20)],
        ["W1-spring", "requested 2027-03-20 12:00 CET (offset 3600), window 20-28 Mar crosses the 28 Mar change", U(2027, 3, 20, 11), U(2027, 3, 20), U(2027, 3, 27, 20)],
        ["W1-control", "requested 2026-11-06 (offset 3600), no change in the window -- the user's regime today", U(2026, 11, 6, 10), U(2026, 11, 6), U(2026, 11, 6, 10)]
    ];
    for (const [id, what, req, firstDay, now] of scenarios) {
        const s = weatherScenario(req, firstDay, 9);
        const m = s.WM.normalise({ forecast: s.forecast, nowMs: now, config: {} });
        const F = s.WM.format({});
        const all = m.hoursToday.concat(m.hourly);
        let wrongHours = 0, first = null;
        for (const h of all) {
            const tru = s.t0 + h.temp * H;                      // temp is the hour's index
            if (Math.abs(tru - h.timeMs) > 1) { wrongHours++; if (!first) first = { shows: F.time(h.timeMs), off: (h.timeMs - tru) / H }; }
        }
        check(id + "/hours", "medium", wrongHours === 0,
            wrongHours + " of " + all.length + " hourly entries sit at the wrong instant" + (first ? " (the first shows " + first.shows + ", " + first.off + " h off)" : "") + " -- " + what);
        let wrongSun = 0, ex = null;
        for (let d = 0; d < m.daily.length; d++) {
            for (const [got, tru] of [[m.daily[d].sunriseMs, s.truth.rise[d]], [m.daily[d].sunsetMs, s.truth.set[d]]]) {
                if (Math.abs(got - tru) > 90000) { wrongSun++; if (!ex) ex = { day: bru(tru).key, shows: F.time(got), real: bru(tru).hm }; }
            }
        }
        check(id + "/sun", "medium", wrongSun === 0,
            wrongSun + " of " + (m.daily.length * 2) + " sunrise/sunset times an hour off" + (ex ? " (" + ex.day + " shows " + ex.shows + ", the sun crosses the horizon at " + ex.real + ")" : "") + " -- " + what);
    }
});

// A cached response is raw JSON with its own `utc_offset_seconds`: read back after the change (days later, offline) it must
// parse exactly as when it arrived -- nothing about "now" may re-label it.
run("weatherCache", function () {
    const s = weatherScenario(U(2026, 10, 20, 10), U(2026, 10, 20), 9);
    const back = JSON.parse(JSON.stringify({ savedAtMs: 1, data: s.forecast })).data;
    const m = s.WM.normalise({ forecast: back, nowMs: U(2026, 10, 26, 11), config: {} });
    const all = m.hoursToday.concat(m.hourly);
    const wrong = all.filter((h) => Math.abs(s.t0 + h.temp * H - h.timeMs) > 1).length;
    check("W1-cache", "medium", all.length > 40 && wrong === 0, wrong + " of " + all.length + " hours wrong when the response of 20 Oct is read back on 26 Oct from the cache file's JSON");
});

// What the fix must not break: the DAY an hour belongs to is the day of its instant (Brussels rule), so on a window that
// crosses a change the per-date counts are 24 except the change day (23/25), the daily rows keep their own dates, and an
// air-quality response labelled at its OWN offset still lands on the forecast's hours.
run("weatherDays", function () {
    for (const [id, req, first, nDays, changeKey, nChange] of [
        ["W1-days-fall", U(2026, 10, 20, 10), U(2026, 10, 20), 9, "2026-10-25", 25],
        ["W1-days-spring", U(2027, 3, 20, 11), U(2027, 3, 20), 9, "2027-03-28", 23]]) {
        const s = weatherScenario(req, first, nDays);
        const aqOff = s.forecast.utc_offset_seconds === 7200 ? 3600 : 7200;           // a different frame than the forecast's
        const aqLabel = (t) => { const d = new Date(t + aqOff * 1000); return d.getUTCFullYear() + "-" + p2(d.getUTCMonth() + 1) + "-" + p2(d.getUTCDate()) + "T" + p2(d.getUTCHours()) + ":00"; };
        const aq = { utc_offset_seconds: aqOff, hourly: { time: s.forecast.hourly.time.map((_, i) => aqLabel(s.t0 + i * H)), european_aqi: s.forecast.hourly.time.map(() => 20), pm2_5: s.forecast.hourly.time.map((_, i) => i) } };       // the hour's index: a row on the wrong hour shows
        const m = s.WM.normalise({ forecast: s.forecast, airQuality: aq, nowMs: first + 2 * DAY, config: {} });
        const all = m.hoursToday.concat(m.hourly);
        const counts = {};
        for (const h of all) { const k = bru(h.timeMs).key; counts[k] = (counts[k] || 0) + 1; }
        const missingAq = all.filter((h) => !h.aq || h.aq.pm25 !== h.temp).length;
        const dayBad = m.daily.filter((d, i) => bru(d.dateMs).key !== s.forecast.daily.time[i] || bru(d.dateMs).hm !== "00:00").length;
        const full = Object.keys(counts).filter((k) => k > bru(all[0].timeMs).key && k < bru(all[all.length - 1].timeMs).key);
        const badCount = full.filter((k) => counts[k] !== (k === changeKey ? nChange : 24));
        // the daily row's own hour tally is the date's real hours (what `complete` and the aggregates read)
        const badTotal = m.daily.filter((d) => full.indexOf(bru(d.dateMs).key) >= 0 && d.hours.total !== counts[bru(d.dateMs).key]).length;
        check(id, "medium", missingAq === 0 && dayBad === 0 && badCount.length === 0 && badTotal === 0,
            "hours without their OWN air-quality row " + missingAq + " (AQ labelled at +" + aqOff / 3600 + "), daily rows off their date " + dayBad + ", daily rows whose hour tally is not their date's " + badTotal + ", dates with the wrong hour count " + JSON.stringify(badCount.map((k) => k + ":" + counts[k])));
    }
});

// The day grid on the two days of the year that do not have 24 hours. The model here is the CORRECT one (true instants, one
// entry per real hour), so this isolates the grid. The grid is the WALL CLOCK in 24 slots (WeatherSeries.slotOf): the hour
// a spring change skips is an empty slot, the hour a fall change repeats shows its later reading, labels are 00..23 and
// no slot holds another date's hour.
run("weatherGrid", function () {
    const WM = lib("weather/data/WeatherModel.js"), WS = lib("weather/data/WeatherSeries.js");
    const F = WM.format({});
    const want24 = []; for (let i = 0; i < 24; i++) want24.push(p2(i));
    for (const [id, dayKey, nReal, startUtcOfDay, wantEmpty, slot2, nowUtc, what] of [
        ["W2-fall-grid", "2026-10-25", 25, U(2026, 10, 24, 22), [], 3, U(2026, 10, 25, 1, 30), "25-hour day (slot 2 shows the later 02:00, hour index 3)"],
        ["W2-spring-grid", "2026-03-29", 23, U(2026, 3, 28, 23), [2], null, U(2026, 3, 29, 1, 30), "23-hour day (slot 2 is the skipped hour)"]]) {
        const hourly = [];
        for (let i = 0; i < nReal + 3; i++) hourly.push({ timeMs: startUtcOfDay + i * H, temp: i < nReal ? i : 100 + i });
        const day = { dateMs: WM.parseLocal(dayKey + "T00:00", null) };
        const slots = WS.hoursOfDay({ hourly: hourly, hoursToday: [] }, day), labels = WS.labelsOf(day, F);
        const empty = slots.map((s, i) => s ? -1 : i).filter((i) => i >= 0);
        const foreign = slots.filter((s) => s && s.temp >= 100).length;      // the next day's hours standing in this day's grid
        const inOrder = slots.every((s, i) => !s || WM.localParts(s.timeMs).hour === i);
        const nowIdx = WS.nowIndexOf({ current: { timeMs: nowUtc }, hourly: hourly }, day);
        const ok = JSON.stringify(empty) === JSON.stringify(wantEmpty) && foreign === 0 && inOrder && labels.join(" ") === want24.join(" ")
                   && (slot2 === null || (slots[2] && slots[2].temp === slot2)) && nowIdx === (slot2 === null ? 3 : 2);
        check(id, "low", ok, what + ": empty slots " + JSON.stringify(empty) + " (want " + JSON.stringify(wantEmpty) + "), next-day hours in it " + foreign
            + ", hours in their own slot " + inOrder + ", slot 2 holds " + (slots[2] ? slots[2].temp : "nothing") + ", now at " + nowIdx + ", axis " + labels.join(" "));
    }
    // the sun/moon chart samples the same slots: the skipped hour is a gap, not a duplicate of the hour before
    const model = { location: { lat: 50.85, lon: 4.35 }, hourly: [], hoursToday: [], daily: [], current: null };
    const spring = WS.forDay({ location: model.location, hourly: [], hoursToday: [], daily: [{ dateMs: WM.parseLocal("2026-03-29T00:00", null) }], current: null }, "sunMoon", 0, F, {});
    const sunSeries = spring && spring.series && spring.series[0] ? spring.series[0].values : null;
    check("W2-sunmoon-gap", "low", !!sunSeries && sunSeries.length === 24 && sunSeries[2] === null && sunSeries.filter((v) => v === null).length === 1,
        "sun curve of 29 Mar: " + (sunSeries ? sunSeries.slice(0, 4).join(",") + " (24 samples, nulls " + sunSeries.filter((v) => v === null).length + ")" : "no series"));
});

// WeatherService.brusselsDateKey (the 60 s tick's "today") and the model's dateKey against the oracle.
run("weatherToday", function () {
    const WM = lib("weather/data/WeatherModel.js");
    const brusselsDateKey = qmlFunction("weather/data/WeatherService.qml", "brusselsDateKey");
    let bad = 0, first = null, n = 0;
    for (const T of [SPRING26, FALL26, SPRING27]) {
        for (let t = T - 30 * H; t <= T + 30 * H; t += 10 * 60000) {
            n++;
            const want = bru(t).key;
            if (brusselsDateKey(t) !== want || WM.dateKey(t) !== want) { bad++; if (!first) first = new Date(t).toISOString(); }
        }
    }
    check("W3-todaykey", "medium", bad === 0, bad + " of " + n + " instants around the three changes give another date than the oracle (first " + first + ")");
});

// ================================================================================================ RELATIVE TIMES
// RelTime.format / EventIn.line promise that nextMs is the first millisecond the text reads differently (never earlier,
// never later). Walked across the changes for several stamps: elapsed-time forms hold, nothing sleeps through a change.
run("relTimes", function () {
    const R = lib("common/components/RelTime.js"), E = lib("clock/calendar/EventIn.js");
    let walks = 0, bad = [];
    const stamps = [U(2026, 3, 27, 22, 30), U(2026, 3, 29, 0, 59), U(2026, 3, 29, 1, 30), U(2026, 10, 24, 21, 30),
                    U(2026, 10, 25, 0, 30), U(2026, 10, 25, 1, 30), U(2027, 3, 27, 20, 0)];
    for (const ms of stamps) {
        for (const opts of [undefined, { weekday: false, year: false, justNow: "just now", suffix: " ago" }, { dates: false }]) {
            let now = ms + 1000, r = R.format(ms, now, opts), guard = 0;
            walks++;
            while (r.nextMs !== -1 && guard++ < 400 && now < ms + 3 * 366 * DAY) {
                const before = R.format(ms, r.nextMs - 1, opts), at = R.format(ms, r.nextMs, opts);
                if (before.text !== r.text) { bad.push("early " + new Date(ms).toISOString() + " " + JSON.stringify(opts)); break; }
                if (at.text === r.text) { bad.push("late " + new Date(ms).toISOString() + " " + JSON.stringify(opts)); break; }
                now = r.nextMs; r = at;
            }
        }
    }
    check("R1-reltime-boundaries", "low", bad.length === 0, walks + " walks; " + bad.slice(0, 3).join("; "));
    bad = []; walks = 0;
    for (const [start, from] of [[U(2026, 3, 30, 7), U(2026, 3, 26, 5)], [U(2026, 10, 26, 8), U(2026, 10, 22, 5)], [U(2026, 3, 29, 9), U(2026, 3, 29, 0)]]) {
        let now = from, l = E.line(start, start + H, false, now), guard = 0;
        walks++;
        while (l && l.nextMs > 0 && guard++ < 5000 && now < start + 3 * DAY) {
            const b = E.line(start, start + H, false, l.nextMs - 1), a = E.line(start, start + H, false, l.nextMs);
            if (!b || b.text !== l.text) { bad.push("early " + new Date(l.nextMs).toISOString()); break; }
            if (!a || a.text === l.text) { bad.push("late " + new Date(l.nextMs).toISOString()); break; }
            now = l.nextMs; l = a;
        }
    }
    check("R2-eventin-boundaries", "low", bad.length === 0, walks + " walks; " + bad.slice(0, 3).join("; "));
});

// ================================================================================================ CALENDAR FEEDS (recurrence)
run("recurrence", function () {
    const RR = lib("clock/data/rrule.js");
    const ev = (rrule, startMs, endMs, raw) => ({ uid: "x", dtstart: { value: new Date(startMs), isDate: false, raw: raw }, dtend: { value: new Date(endMs) }, rrule: rrule });
    // the user's feeds: DTSTART;TZID=Europe/Brussels (the machine's zone) -> wall-clock recurrence is right
    const wk = RR.expandRRule(ev({ freq: "WEEKLY", interval: 1, byday: [{ day: "SU" }] }, U(2026, 3, 22, 8), U(2026, 3, 22, 9)), new Date(U(2026, 3, 1)), new Date(U(2026, 4, 15)));
    check("C3-weekly-local", "low", wk.length > 3 && wk.every((o) => bru(o.start.getTime()).hm === "09:00"), "weekly 09:00 local keeps 09:00 over 29 Mar: " + wk.map((o) => bru(o.start.getTime()).hm).join(" "));
    // a DTSTART:...Z + RRULE series: RFC 5545 recurs it at the same UTC time; rrule.js recurs wall time
    const utc = RR.expandRRule(ev({ freq: "DAILY", interval: 1 }, U(2026, 3, 27, 8), U(2026, 3, 27, 9), "20260327T080000Z"), new Date(U(2026, 3, 26)), new Date(U(2026, 3, 31)));
    const hrs = utc.map((o) => o.start.getUTCHours());
    check("C4-utc-recurrence", "low", hrs.every((h) => h === 8),
        "a DTSTART:...Z + RRULE series stays at 08:00Z in RFC 5545; rrule.js keeps the local wall time, so its UTC hours read " + hrs.join(",") + " (the user's feeds hold no such series; a TZID zone other than the machine's is the same shape)");
    // a series at 02:30 local meets the night the clocks go forward: it must be back at 02:30 the day after (a series
    // stepped from the previous occurrence stays at the gap's 03:30 for ever)
    const gapSeries = RR.expandRRule(ev({ freq: "DAILY", interval: 1 }, U(2026, 3, 26, 1, 30), U(2026, 3, 26, 2, 30)), new Date(U(2026, 3, 26)), new Date(U(2026, 4, 3)));
    const after = gapSeries.filter((o) => bru(o.start.getTime()).key > "2026-03-29").map((o) => bru(o.start.getTime()).hm);
    check("C6-gap-series", "low", after.length >= 3 && after.every((h) => h === "02:30"), "daily 02:30 local, days after the 29 Mar gap read " + after.join(","));
    const wkGap = RR.expandRRule(ev({ freq: "WEEKLY", interval: 1, byday: [{ day: "SU" }] }, U(2026, 3, 22, 1, 30), U(2026, 3, 22, 2, 30)), new Date(U(2026, 3, 1)), new Date(U(2026, 4, 30)));
    const wkAfter = wkGap.filter((o) => bru(o.start.getTime()).key > "2026-03-29").map((o) => bru(o.start.getTime()).hm);
    check("C6-gap-weekly", "low", wkAfter.length >= 3 && wkAfter.every((h) => h === "02:30"), "weekly Sunday 02:30 local, the Sundays after the gap read " + wkAfter.join(","));
    // an overnight event repeated over the change keeps the first instance's ELAPSED length, not its wall length
    const ov = RR.expandRRule(ev({ freq: "DAILY", interval: 1 }, U(2026, 3, 27, 21), U(2026, 3, 28, 7)), new Date(U(2026, 3, 27)), new Date(U(2026, 3, 30)));
    const night = ov.find((o) => bru(o.start.getTime()).key === "2026-03-28");
    check("C5-overnight-end", "low", !!night && bru(night.end.getTime()).hm === "08:00",
        "22:00-08:00 (CET wall) repeated over the change: the night of 28/29 Mar ends at " + (night ? bru(night.end.getTime()).hm : "?") + " (a 10 h elapsed length is 9 h of wall)");
});

// ================================================================================================ SCREENTIME (the JS reader; the daemon has its own DST tests)
run("screentime", function () {
    const M = lib("screentime/data/ScreentimeModel.js");
    const cfg = M.cfgOf({ dayStartHour: 4 }, M.localTz);
    const sp = M.dayBounds("2026-03-28", cfg), fl = M.dayBounds("2026-10-24", cfg), nm = M.dayBounds("2026-11-06", cfg);
    check("S1-day-length", "low", sp.end - sp.start === 23 * H && fl.end - fl.start === 25 * H && nm.end - nm.start === 24 * H,
        "logical days: spring " + (sp.end - sp.start) / H + " h, fall " + (fl.end - fl.start) / H + " h, normal " + (nm.end - nm.start) / H + " h");
    const s = U(2026, 10, 24, 22, 30), e = U(2026, 10, 25, 3, 0);
    const parts = M.splitHours(s, e, cfg), sum = parts.reduce((a, p) => a + p[1], 0);
    check("S2-split-conserves", "low", sum === e - s && parts.every((p) => p[0] >= 0 && p[0] < 24), "sum " + sum / 60000 + " min of " + (e - s) / 60000 + " min across the repeated hour");
    check("S3-dayof-night", "low", M.dayOf(U(2026, 10, 25, 1, 30), cfg) === "2026-10-24" && M.dayOf(U(2026, 3, 29, 1, 30), cfg) === "2026-03-28" && M.dayOf(U(2026, 3, 29, 2, 30), cfg) === "2026-03-29",
        "03:30 of both change nights belongs to the day before, 04:30 CEST of 29 Mar to the 29th");
    // a day that starts in the transition hours (dayStartHour is configurable 0-23 in the daemon): the daemon takes the
    // FIRST occurrence of a repeated hour and moves a skipped one forward (cal.rs)
    const want = { "2:fall": U(2026, 10, 25, 0), "3:fall": U(2026, 10, 25, 2), "2:spring": U(2026, 3, 29, 1), "3:spring": U(2026, 3, 29, 1) };
    const bad = [];
    for (const h of [2, 3]) {
        const c = M.cfgOf({ dayStartHour: h }, M.localTz);
        for (const [k, date] of [["fall", "2026-10-25"], ["spring", "2026-03-29"]]) {
            const got = M.dayBounds(date, c).start;
            if (got !== want[h + ":" + k]) bad.push("dayStartHour " + h + " on the " + k + " day starts " + new Date(got).toISOString() + ", the daemon's rule gives " + new Date(want[h + ":" + k]).toISOString());
        }
    }
    check("S4-daystart-in-transition", "low", bad.length === 0, bad.join("; ") + " (default 4 is clear of the change)");
});

// ================================================================================================ STOCKS
run("stocks", function () {
    const MK = lib("stocks/data/Markets.js");
    const quote = (startUtc, endUtc, gmt, tz) => ({ symbol: "X", type: "EQUITY", price: 100, gmtoffset: gmt, tz: tz, session: { start: startUtc, end: endUtc, preStart: startUtc - 5.5 * H, postEnd: endUtc + 4 * H } });
    // NY changes on Sunday 8 Mar 2026; Brussels is still on CET until 29 Mar (the weeks the two zones disagree)
    const fri = quote(U(2026, 3, 6, 14, 30), U(2026, 3, 6, 21), -18000, "America/New_York");
    const now = U(2026, 3, 9, 13, 0), realOpen = U(2026, 3, 9, 13, 30);          // Monday 09:00 EDT, 30 min before the bell
    const d = MK.nextFetchDelay({ quotes: { X: fri }, nowMs: now, lastFetchMs: U(2026, 3, 7, 6), popupOpen: false, openMs: 60000, closedMs: 300000 });
    check("K1-nextopen-us-spring", "low", d <= realOpen - now,
        "NYSE, session of Fri 6 Mar, asked Mon 9 Mar 09:00 EDT: the idle wake is predicted " + d / 60000 + " min ahead, the bell is " + (realOpen - now) / 60000 + " min ahead (24 h steps over a US change put the open an hour late)");
    const eu = quote(U(2026, 10, 23, 7), U(2026, 10, 23, 15, 30), 7200, "Europe/Amsterdam");       // Euronext Fri 23 Oct (CEST); Mon 26 Oct is CET: the bell is 08:00Z
    const n2 = U(2026, 10, 26, 6, 30), open2 = U(2026, 10, 26, 8);
    const d2 = MK.nextFetchDelay({ quotes: { X: eu }, nowMs: n2, lastFetchMs: U(2026, 10, 24, 6), popupOpen: false, openMs: 60000, closedMs: 300000 });
    check("K2-nextopen-eu-fall", "low", d2 === open2 - n2,
        "Euronext, session of Fri 23 Oct, asked Mon 26 Oct 07:30 CET: predicted " + d2 / 60000 + " min ahead, the bell is " + (open2 - n2) / 60000 + " min ahead (stepped in the exchange's own clock: the bell itself)");
    // Friday's 1d spark (includePrePost) placed against MONDAY's session across NY's change
    const mon = quote(U(2026, 3, 9, 13, 30), U(2026, 3, 9, 20), -14400, "America/New_York");
    const pts = [[U(2026, 3, 6, 13, 30), "pre"], [U(2026, 3, 6, 14, 30), "regular"], [U(2026, 3, 6, 20, 55), "regular"], [U(2026, 3, 6, 21, 0), "post"]];
    const sp = MK.splitSessions(mon, pts.map((p) => p[0]), pts.map(() => 1), U(2026, 3, 9, 12));   // read on Monday 08:00 EDT
    const got = (ms) => sp.pre.t.includes(ms) ? "pre" : sp.post.t.includes(ms) ? "post" : "regular";
    const wrong = pts.filter((p) => got(p[0]) !== p[1]).map((p) => new Date(p[0]).toISOString().slice(11, 16) + "Z is " + got(p[0]) + ", want " + p[1]);
    check("K3-split-other-regime", "low", wrong.length === 0, "Friday's bars against Monday's session across NY's change: " + wrong.join("; "));
});

// Markets.offsetAt (the exchange's clock away from the response) against Intl for the zones it knows, every hour of
// 2026-2027, seen from a read made in winter and one made in summer. The Sunday-night hours around a US/AU/NZ change are
// allowed to differ (the rule is taken at the current offset; no market is open then).
run("exchangeClock", function () {
    const MK = lib("stocks/data/Markets.js");
    const fmts = {};
    const offOf = (tz, ms) => { const f = fmts[tz] || (fmts[tz] = new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" }));
        const o = {}; for (const x of f.formatToParts(new Date(ms))) o[x.type] = x.value;
        return (Date.UTC(+o.year, +o.month - 1, +o.day, +o.hour, +o.minute, +o.second) - Math.floor(ms / 1000) * 1000) / 1000; };
    const bad = []; let n = 0;
    for (const tz of ["America/New_York", "America/Toronto", "Europe/Amsterdam", "Europe/London", "Europe/Zurich", "Australia/Sydney", "Pacific/Auckland", "Asia/Tokyo", "Europe/Istanbul"]) {
        for (const ref of [U(2026, 1, 15, 12), U(2026, 7, 15, 12)]) {
            const q = { tz: tz, gmtoffset: offOf(tz, ref) };
            let wrong = 0, first = null;
            for (let t = U(2026, 1, 1); t < U(2028, 1, 1); t += 60 * 60000) {
                n++;
                if (MK.offsetAt(q, t, ref) !== offOf(tz, t)) {
                    const wd = new Date(t + offOf(tz, t) * 1000).getUTCDay(), hr = new Date(t + offOf(tz, t) * 1000).getUTCHours();
                    if (wd === 0 && hr < 4) continue;            // Sunday small hours around a change: no market open
                    wrong++; if (!first) first = new Date(t).toISOString();
                }
            }
            if (wrong) bad.push(tz + " read " + new Date(ref).toISOString().slice(0, 10) + ": " + wrong + " instants wrong, first " + first);
        }
    }
    check("K4-exchange-clock", "low", bad.length === 0, n + " instants; " + bad.join("; "));
});

// ================================================================================================ LISTS THAT GROUP BY DAY
run("grouping", function () {
    const files = "bar/llm/components/LlmSidebar.qml";
    const root = { _todayStart: 0 };
    const dayStart = qmlFunction(files, "_dayStart");
    const grp = qmlFunction(files, "_dateGroupOf", [], { root: root });
    const group = (now, ms) => { root._todayStart = dayStart(now); return grp(ms); };
    const cases = [["Mon 30 Mar (after the spring change): Sat 28 Mar 23:30 CET is 2 days back", U(2026, 3, 30, 10), U(2026, 3, 28, 22, 30), 2],
                   ["Mon 26 Oct (after the fall change): Sun 25 Oct 00:30 CEST is yesterday", U(2026, 10, 26, 10), U(2026, 10, 24, 22, 30), 1]];
    const bad = cases.filter(([, now, ms, want]) => group(now, ms) !== want).map(([w, now, ms, want]) => w + " -> group " + group(now, ms) + " (0 today, 1 yesterday, 2 previous 7 days, 3 older)");
    check("G1-llm-groups", "low", bad.length === 0, bad.join("; "));
});

// ================================================================================================ QV4 (the shell's own engine)
// Everything that builds a local time inside a transition hour. The harness is generated here so it runs the SHIPPED text.
function qv4() {
    const caption = mirrorAnchor("clock/timers/TimersCard.qml", "at = new Date(at.getTime() + 86400000);");
    const nextAfter = qmlFunctionText("wiki/data/WikiService.qml", "_nextAfter", [["cfg.config.rolloverHour", "__rh"], ["root._rolloverMs", "top.rolloverMs"]]);
    const rolloverMs = qmlFunctionText("wiki/data/WikiService.qml", "_rolloverMs").replace("function _rolloverMs", "function rolloverMs");
    const scrub = qmlFunctionText("stocks/StockDetailHeader.qml", "scrubText");
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "dst-qv4-"));
    const abs = (rel) => JSON.stringify("file://" + path.join(MOD, rel));
    const qml = `import QtQml
import ${abs("clock/data/timers.js")} as Timers
import ${abs("stocks/data/Markets.js")} as Markets
QtObject {
    id: top
    property var head: QtObject {
        id: head
        property string range: "1D"
        property var q: null
        function _num(v) { return typeof v === "number" && isFinite(v); }
        ${scrub}
    }
    property string nowTag: ""
    function emit(id, v) { console.log("QV4 " + id + " " + JSON.stringify(v)); }
    ${rolloverMs}
    function nextAfter(wallMs, __rh) { ${nextAfter.replace(/^function _nextAfter\(wallMs\) \{/, "").replace(/\}\s*$/, "")} }
    function caption(hh, mm, now) { let at = new Date(now); at.setHours(hh, mm, 0, 0); if (at.getTime() <= now) at = new Date(at.getTime() + 86400000); return at.getTime(); }
    property var timer: Timer {
        running: true; interval: 0
        onTriggered: {
            top.emit("raw-gap", new Date(2026, 2, 29, 2, 30).getTime());
            top.emit("raw-repeat", new Date(2026, 9, 25, 2, 30).getTime());
            top.emit("raw-gap-set", (function () { const d = new Date(2026, 2, 29, 12); d.setHours(2, 30, 0, 0); return d.getTime(); })());
            top.emit("raw-repeat-set", (function () { const d = new Date(2026, 9, 25, 12); d.setHours(2, 30, 0, 0); return d.getTime(); })());
            const alarms = JSON.parse(top.alarmsJson), froms = JSON.parse(top.fromsJson);
            for (let i = 0; i < alarms.length; i++)
                top.emit("alarm-" + i, Timers.nextOccurrence(alarms[i], froms[i]));
            for (const c of JSON.parse(top.captionsJson))
                top.emit("caption-" + c.id, top.caption(c.hh, c.mm, c.now));
            for (const h of [4, 2, 3]) {
                top.emit("rollover-spring-" + h, top.nextAfter(${U(2026, 3, 28, 12)}, h));
                top.emit("rollover-fall-" + h, top.nextAfter(${U(2026, 10, 24, 12)}, h));
            }
            for (const c of JSON.parse(top.scrubsJson)) {
                top.head.range = c.range; top.head.q = c.q;
                top.emit("scrub-" + c.id, top.head.scrubText(c.t, c.read));
            }
            Qt.quit();
        }
    }
    property string scrubsJson: ""
    property string alarmsJson: ""
    property string fromsJson: ""
    property string captionsJson: ""
}
`;
    return { qml, dir, caption };
}

run("engine", function () {
    const T = lib("clock/data/timers.js");
    const alarmCases = [
        ["C1-spring-gap", { hour: 2, minute: 30, days: 0 }, U(2026, 3, 28, 22), (t) => t === U(2026, 3, 29, 1, 30), "02:30 on 29 Mar does not exist: it must ring at 03:30 CEST (01:30Z)"],
        ["C1-fall-repeat", { hour: 2, minute: 30, days: 0 }, U(2026, 10, 24, 22), (t) => t === U(2026, 10, 25, 0, 30) || t === U(2026, 10, 25, 1, 30), "02:30 of the repeated hour rings (QV4 takes the second, 01:30Z)"],
        ["C1-fall-once", { hour: 2, minute: 30, days: 0 }, U(2026, 10, 25, 1, 31), (t) => bru(t).key === "2026-10-26" && bru(t).hm === "02:30", "after it rang, 02:30 does not ring again in the same night"],
        ["C1-daily-spring", { hour: 7, minute: 0, days: 127 }, U(2026, 3, 28, 12), (t) => bru(t).key === "2026-03-29" && bru(t).hm === "07:00", "07:00 stays 07:00 local over the change"],
        ["C1-daily-fall", { hour: 7, minute: 0, days: 127 }, U(2026, 10, 24, 12), (t) => bru(t).key === "2026-10-25" && bru(t).hm === "07:00", "07:00 stays 07:00 local over the change"],
        ["C1-sunday-spring", { hour: 1, minute: 30, days: 1 }, U(2026, 3, 22, 12), (t) => t === U(2026, 3, 29, 0, 30), "Sunday 01:30 (the hour before the gap)"],
        ["C1-sunday-fall-next", { hour: 3, minute: 30, days: 1 }, U(2026, 10, 25, 2, 31), (t) => bru(t).key === "2026-11-01" && bru(t).hm === "03:30", "Sunday 03:30 rang on the change day (02:30Z); the next is 1 Nov"]
    ];
    const capCases = [["spring-evening", 7, 0, U(2026, 3, 28, 22)], ["fall-evening", 7, 0, U(2026, 10, 24, 21)], ["spring-gap", 2, 30, U(2026, 3, 28, 22)], ["fall-3am", 3, 0, U(2026, 10, 24, 21)]];
    if (!fs.existsSync(QML)) { check("E0-engine", "high", false, "no " + QML + ": the QV4 cases did not run"); return; }
    const h = qv4();
    let qml = h.qml;
    const nyq = { gmtoffset: -14400, tz: "America/New_York" }, nyq5 = { gmtoffset: -18000, tz: "America/New_York" };
    const scrubCases = [
        { id: "ny-open-1d", read: U(2026, 3, 9, 12), range: "1D", q: nyq, t: U(2026, 3, 9, 13, 30), want: "09:30 UTC-4" },
        { id: "ny-friday-bar", read: U(2026, 3, 9, 12), range: "1D", q: nyq, t: U(2026, 3, 6, 14, 30), want: "09:30 UTC-5" },
        { id: "ny-winter-1d", read: U(2026, 11, 6, 12), range: "1D", q: nyq5, t: U(2026, 11, 6, 14, 30), want: "09:30 UTC-5" },
        { id: "ams-open-1d", read: U(2026, 11, 6, 12), range: "1D", q: { gmtoffset: 3600, tz: "Europe/Amsterdam" }, t: U(2026, 11, 6, 8), want: "09:00" },
        { id: "ams-friday-before-fall", read: U(2026, 11, 6, 12), range: "1D", q: { gmtoffset: 3600, tz: "Europe/Amsterdam" }, t: U(2026, 10, 23, 7), want: "09:00" },
        { id: "tokyo-1d", read: U(2026, 11, 6, 12), range: "1D", q: { gmtoffset: 32400, tz: "Asia/Tokyo" }, t: U(2026, 11, 6, 0), want: "09:00 UTC+9" },
        { id: "mumbai-1d", read: U(2026, 11, 6, 12), range: "1D", q: { gmtoffset: 19800, tz: "Asia/Kolkata" }, t: U(2026, 11, 6, 4), want: "09:30 UTC+5:30" },
        { id: "ny-1y", read: U(2026, 11, 6, 12), range: "1Y", q: nyq5, t: U(2026, 11, 6, 3), want: "5 Nov 2026" }
    ];
    qml = qml.replace('property string scrubsJson: ""', "property string scrubsJson: " + JSON.stringify(JSON.stringify(scrubCases)));
    qml = qml.replace('property string alarmsJson: ""', "property string alarmsJson: " + JSON.stringify(JSON.stringify(alarmCases.map((c) => c[1]))))
             .replace('property string fromsJson: ""', "property string fromsJson: " + JSON.stringify(JSON.stringify(alarmCases.map((c) => c[2]))))
             .replace('property string captionsJson: ""', "property string captionsJson: " + JSON.stringify(JSON.stringify(capCases.map((c) => ({ id: c[0], hh: c[1], mm: c[2], now: c[3] })))));
    const file = path.join(h.dir, "dst_qv4.qml");
    fs.writeFileSync(file, qml);
    const r = cp.spawnSync(QML, [file], { env: Object.assign({}, process.env, { QT_QPA_PLATFORM: "offscreen", QT_FORCE_STDERR_LOGGING: "1", QT_QPA_PLATFORMTHEME: "", TZ: process.env.TZ }), encoding: "utf8", timeout: 30000 });
    if (process.env.DST_KEEP) console.log("kept " + file); else fs.rmSync(h.dir, { recursive: true, force: true });
    const out = {};
    for (const line of ((r.stdout || "") + (r.stderr || "")).split("\n")) {
        const m = /QV4 (\S+) (.*)$/.exec(line);
        if (m) out[m[1]] = JSON.parse(m[2]);
    }
    if (out["raw-gap"] === undefined) { check("E0-engine", "high", false, "the QV4 harness gave no answer: " + ((r.stderr || "").split("\n").slice(0, 4).join(" | ") || "status " + r.status)); return; }
    const iso = (t) => new Date(t).toISOString();
    // facts, for the table (no verdict): how QV4 resolves the two awkward local times
    check("E1-qv4-gap-resolution", "low", true, "new Date(2026,2,29,2,30) -> " + iso(out["raw-gap"]) + " (" + bru(out["raw-gap"]).hm + "); setHours(2,30) on that day -> " + iso(out["raw-gap-set"]) + " (" + bru(out["raw-gap-set"]).hm + ")");
    check("E2-qv4-repeat-resolution", "low", true, "new Date(2026,9,25,2,30) -> " + iso(out["raw-repeat"]) + " (first occurrence is 00:30Z); setHours(2,30) -> " + iso(out["raw-repeat-set"]));
    alarmCases.forEach((c, i) => {
        const t = out["alarm-" + i];
        check(c[0], "medium", c[3](t), c[4] + (c[3](t) ? "" : "; got " + (t < 0 ? "none" : iso(t) + " = " + bru(t).key + " " + bru(t).hm)));
    });
    const bad = [];
    for (const c of capCases) {
        const want = T.nextOccurrence({ hour: c[1], minute: c[2], days: 0 }, c[3]), got = out["caption-" + c[0]];
        if (want !== got) bad.push(c[0] + ": the face counts to " + bru(got).hm + " " + bru(got).key + " but the alarm rings " + bru(want).hm + " " + bru(want).key + " (" + (got - want) / H + " h)");
    }
    // fixed shape: the caption counts to T.nextOccurrence (the alarm's own rule), and no 24 h addition is left in the card
    const card = fs.readFileSync(path.join(MOD, "clock/timers/TimersCard.qml"), "utf8");
    const usesRule = card.includes("T.nextOccurrence({ hour: hh, minute: mm, days: 0 }, now)");
    check("C2-alarm-caption", "low", usesRule && !h.caption,
        h.caption ? "TimersCard.qml still adds 24 h of elapsed time to today's alarm time: " + bad.join("; ")
                  : (usesRule ? "the caption counts to T.nextOccurrence" : "ANCHOR LOST (neither the 24 h sum nor T.nextOccurrence is in TimersCard.qml; re-aim this case)"));
    // the stock detail's scrub readout: the exchange's clock, tagged on 1D when it is not this machine's
    const badS = scrubCases.filter((c) => out["scrub-" + c.id] !== c.want).map((c) => c.id + ": '" + out["scrub-" + c.id] + "' want '" + c.want + "'");
    check("K5-scrub-readout", "low", badS.length === 0, badS.join("; "));
    // the wiki's rollover timer against the day key it must flip
    const Pool = lib("wiki/data/WikiPool.js");
    const badW = [];
    for (const h2 of [4, 2, 3]) {
        for (const [k, day0, day1] of [["spring", "2026-03-28", "2026-03-29"]]) {
            const f = out["rollover-" + k + "-" + h2];
            if (Pool.dayKey(f, h2) !== day1 || Pool.dayKey(f - 1, h2) !== day0)
                badW.push("rolloverHour " + h2 + ", " + k + ": the timer fires at " + bru(f).hm + " " + bru(f).key + " but dayKey flips " + Pool.dayKey(f - 1, h2) + " -> " + Pool.dayKey(f, h2));
        }
        const f2 = out["rollover-fall-" + h2];
        if (Pool.dayKey(f2, h2) !== "2026-10-25" || Pool.dayKey(f2 - 1, h2) !== "2026-10-24")
            badW.push("rolloverHour " + h2 + ", fall: the timer fires at " + bru(f2).hm + " " + bru(f2).key + " but dayKey flips " + Pool.dayKey(f2 - 1, h2) + " -> " + Pool.dayKey(f2, h2));
    }
    check("G2-wiki-rollover", "low", badW.length === 0, badW.join("; ") + " (the default 4 is clear of the change; the config allows 0-12)");
});

// ================================================================================================ NOTIFICATIONS
run("quiet-hours", function () {
    const D = lib("notifications/data/DayTimes.js"), N = ["22:30-07:00"];
    const iso = (ms) => ms < 0 ? "none" : new Date(ms).toISOString().slice(5, 16);
    const say = (h, t) => { const l = D.last(h, t); return (D.inside(h, t) ? "on" : "off") + " last " + (l ? iso(l.at) + (l.on ? " on" : " off") : "none") + " next " + iso(D.next(h, t)); };
    const is = (id, h, t, want) => check(id, "medium", say(h, t) === want, say(h, t) + ", wanted " + want);
    is("N1-night", N, U(2026, 11, 22, 22), "on last 11-22T21:30 on next 11-23T06:00");
    is("N1-noon", N, U(2026, 11, 22, 11), "off last 11-22T06:00 off next 11-22T21:30");
    is("N1-edges", N, U(2026, 11, 22, 21, 30), "on last 11-22T21:30 on next 11-23T06:00");
    is("N1-none", [], U(2026, 11, 22, 22), "off last none next none");
    is("N1-day", ["13:00-14:00"], U(2026, 11, 22, 12, 15), "on last 11-22T12:00 on next 11-22T13:00");
    is("N2-spring", N, U(2026, 3, 28, 22), "on last 03-28T21:30 on next 03-29T05:00");
    is("N2-fall", N, U(2026, 10, 24, 22), "on last 10-24T20:30 on next 10-25T06:00");
    is("N3-skipped", ["02:30-06:00"], U(2026, 3, 29, 0), "off last 03-28T05:00 off next 03-29T01:00");
    is("N3-repeated", ["02:30-06:00"], U(2026, 10, 25, 1, 15), "on last 10-25T00:30 on next 10-25T05:00");
    is("N3-repeated-end", ["22:30-02:30"], U(2026, 10, 25, 1, 15), "off last 10-25T00:30 off next 10-25T21:30");
    is("N4-merged", ["22:00-02:00", "01:00-07:00"], U(2026, 11, 22, 22), "on last 11-22T21:00 on next 11-23T06:00");
    is("N4-nothing", ["07:00-07:00", "25:00-07:00", "x"], U(2026, 11, 22, 22), "off last none next none");

    const C = lib("notifications/sources/CalendarReminders.js");
    const ev = [{ uid: "a", title: "A", start: new Date(U(2026, 11, 22, 13)), end: new Date(U(2026, 11, 22, 14)), allDay: false, calendarId: "w" },
                { uid: "d", title: "D", start: new Date(2026, 9, 25), end: new Date(2026, 9, 26), allDay: true, calendarId: "p" }];
    const opts = { leadMin: [60, 10], allDayAt: "09:00", calendars: [] };
    const said = {}, at = (t, o) => { const d = C.due(ev, t, o || opts, said); d.forEach((r) => r.marks.forEach((m) => { said[m] = r.untilMs; })); return d.map((r) => C.text(r, t).body).join("|"); };
    const got = [at(U(2026, 11, 22, 12)), at(U(2026, 11, 22, 12, 1)), iso(C.nextAt(ev, U(2026, 11, 22, 12, 1), opts, said)), at(U(2026, 11, 22, 12, 50)), at(U(2026, 11, 22, 12, 55))];
    check("N5-leads", "medium", JSON.stringify(got) === JSON.stringify(["In 60 min · 14:00–15:00", "", "11-22T12:50", "In 10 min · 14:00–15:00", ""]), JSON.stringify(got));
    const one = { leadMin: [10], allDayAt: "", calendars: [] }, plain = {};
    plain[C.keyOf(ev[0])] = U(2026, 11, 22, 13);
    check("N5-old-mark", "low", C.due(ev, U(2026, 11, 22, 12, 55), one, plain).length === 0 && C.due(ev, U(2026, 11, 22, 12, 55), one, {}).length === 1, "a reminder an earlier shell said is said again");
    check("N5-together", "low", C.due(ev, U(2026, 11, 22, 12, 55), opts, {}).map((r) => r.marks.length).join() === "2", "two leads due at once are not one reminder");
    check("N5-calendars", "low", C.due(ev, U(2026, 11, 22, 12, 55), { leadMin: [10], allDayAt: "", calendars: ["p"] }, {}).length === 0, "calendars is not read");
    const day = [U(2026, 10, 25, 7, 59), U(2026, 10, 25, 8), U(2026, 10, 25, 22, 59), U(2026, 10, 25, 23)].map((t) => C.due(ev, t, opts, {}).length).join();
    check("N6-all-day", "medium", day === "0,1,1,0" && iso(C.nextAt(ev, U(2026, 10, 25, 1), opts, {})) === "10-25T08:00", "an all-day appointment of the 25-hour day is due at " + day);
    // calendars.jsonc calendars[].remind: false says none of that calendar's appointments (all-day ones too), minutes are its one lead
    const own = (r) => Object.assign({}, opts, { remind: r });
    const off = [U(2026, 11, 22, 12), U(2026, 11, 22, 12, 50), U(2026, 10, 25, 8)].map((t) => C.due(ev, t, own({ w: false, p: false }), {}).length).join();
    const lead = [U(2026, 11, 22, 12), U(2026, 11, 22, 12, 30)].map((t) => C.due(ev, t, own({ w: 30 }), {}).map((r) => C.text(r, t).body).join("|"));
    check("N7-remind", "medium", off === "0,0,0" && JSON.stringify(lead) === JSON.stringify(["", "In 30 min · 14:00–15:00"])
          && iso(C.nextAt(ev, U(2026, 11, 22, 12), own({ w: 30 }), {})) === "11-22T12:30", "a calendar's own remind is not read: " + off + " " + JSON.stringify(lead));
});

// ================================================================================================ the clock popup's tab (clock.jsonc `open`)
run("clockOpen", function () {
    const T = lib("clock/data/timers.js");
    const tabs = [["calendar", false, false], ["timers", false, false], ["timers", true, false], ["calendar", true, true]];
    const got = {};
    for (const mode of ["auto", "calendar", "timers", "last"])
        got[mode] = tabs.map((c) => T.openTab(c[0], c[1], c[2], mode)).join();
    const want = { auto: "calendar,calendar,timers,timers", calendar: "calendar,calendar,calendar,timers",
                   timers: "timers,timers,timers,timers", last: "calendar,timers,timers,timers" };
    check("C7-open-tab", "medium", JSON.stringify(got) === JSON.stringify(want), "openTab per mode: " + JSON.stringify(got));
});

// ================================================================================================ ARMS
// `--arms`: for each fixed finding, the fault is PUT BACK in a sandbox copy of modules/ (one anchored text replacement in
// the copy; the tree is never touched) and the cases that must turn red are named. Each arm demands its own needles as
// FINDING lines (a crash of the section counts as a finding too, so an arm cannot pass by breaking the harness), and the
// clean run must be green first. An anchor that no longer matches fails the sweep.
if (args.includes("--arms")) {
    const ARMS = [
        ["weather-rule", "weather/data/WeatherModel.js", [["const tzOff = offsetOf(forecast);", "const tzOff = (forecast && forecast.timezone && forecast.timezone !== \"Europe/Brussels\") ? offsetOf(forecast) : null;"]], ["W1-fall/hours", "W1-fall/sun", "W1-spring/hours", "W1-spring/sun"]],
        ["weather-label-date", "weather/data/WeatherModel.js", [["const key = iso ? (brussels && ms !== null ? dateKey(ms) : iso.slice(0, 10)) : null;", "const key = iso ? iso.slice(0, 10) : null;"]], ["W1-days-fall", "W1-days-spring"]],
        ["weather-aq-frame", "weather/data/WeatherModel.js", [["const aqOff = offsetOf(airQuality) !== null ? offsetOf(airQuality) : tzOff;", "const aqOff = tzOff;"]], ["W1-days-fall", "W1-days-spring"]],
        ["weather-grid", "weather/data/WeatherSeries.js", [["const i = slotOf(day, h.timeMs);\n        if (i >= 0)", "const i = Math.round((h.timeMs - day.dateMs) / HOUR_MS);\n        if (i >= 0 && i < 24)"]], ["W2-fall-grid", "W2-spring-grid"]],
        ["weather-labels", "weather/data/WeatherSeries.js", [["out.push(F.hour(Date.UTC(2021, 0, 15, i - 1)));", "out.push(F.hour(day.dateMs + i * HOUR_MS));"]], ["W2-fall-grid", "W2-spring-grid"]],
        ["alarm-caption", "clock/timers/TimersCard.qml", [["const at = T.nextOccurrence({ hour: hh, minute: mm, days: 0 }, now);\n            return { figure: Fmt.clock(hh, mm), caption: Fmt.until(at - now) };", "let at = new Date(now); at.setHours(hh, mm, 0, 0); if (at.getTime() <= now) at = new Date(at.getTime() + 86400000);\n            return { figure: Fmt.clock(hh, mm), caption: Fmt.until(at.getTime() - now) };"]], ["C2-alarm-caption"]],
        ["rrule-utc", "clock/data/rrule.js", [["const utc = _isUtc(ev);", "const utc = false;"]], ["C4-utc-recurrence"]],
        ["rrule-wall-length", "clock/data/rrule.js", [["const endOf = function (dt) { return wallDur === null", "const endOf = function (dt) { return true || wallDur === null"]], ["C5-overnight-end"]],
        ["rrule-drift", "clock/data/rrule.js", [["    if (freq === \"DAILY\") {", "    let cur0 = null;\n    if (freq === \"DAILY\") {"], ["const cur = at(0, 0, i * interval);", "cur0 = cur0 ? new Date(cur0.getFullYear(), cur0.getMonth(), cur0.getDate() + interval, cur0.getHours(), cur0.getMinutes()) : at(0, 0, 0); const cur = cur0;"]], ["C6-gap-series"]],
        ["llm-groups", "bar/llm/components/LlmSidebar.qml", [["if (ms >= midnight(1)) return 1;", "if (ms >= root._todayStart - 86400000) return 1;"], ["if (ms >= midnight(6)) return 2;", "if (ms >= root._todayStart - 6 * 86400000) return 2;"]], ["G1-llm-groups"]],
        ["stocks-clock", "stocks/data/Markets.js", [["if (!rule || !isFinite(ms) || !isFinite(refMs))", "if (true)"]], ["K1-nextopen-us-spring", "K3-split-other-regime", "K4-exchange-clock", "K5-scrub-readout"]],
        ["stocks-scrub", "stocks/StockDetailHeader.qml", [["const off = Markets.offsetAt(q, t, readMs > 0 ? readMs : Date.now());", "const off = -new Date(t).getTimezoneOffset() * 60;"]], ["K5-scrub-readout"]],
        ["wiki-rollover", "wiki/data/WikiService.qml", [["let t = root._rolloverMs(d.getFullYear(), d.getMonth(), d.getDate(), h);", "let t = new Date(d.getFullYear(), d.getMonth(), d.getDate(), h, 0, 0, 0).getTime();"], ["t = root._rolloverMs(n.getFullYear(), n.getMonth(), n.getDate(), h);", "t = new Date(n.getFullYear(), n.getMonth(), n.getDate(), h, 0, 0, 0).getTime();"]], ["G2-wiki-rollover"]],
        ["quiet-naive", "notifications/data/DayTimes.js", [["for (var k = -60; k <= 60; k += 30) {", "for (var k = 0; k < 0; k += 30) {"]], ["N2-spring", "N2-fall", "N6-all-day"]],
        ["quiet-nomerge", "notifications/data/DayTimes.js", [["if (top && list[j].from <= top.to)", "if (false)"]], ["N4-merged"]],
        ["cal-onelead", "notifications/sources/CalendarReminders.js", [["at.push({ mark: k + \"#\" + leads[j],", "at.push({ mark: k,"]], ["N5-leads"]],
        ["cal-remind", "notifications/sources/CalendarReminders.js", [["var own = opts.remind ? opts.remind[e.calendarId] : undefined;", "var own;"]], ["N7-remind"]],
        ["clock-open-mode", "clock/data/timers.js", [["    if (mode === \"calendar\" || mode === \"timers\")", "    if (false)"]], ["C7-open-tab"]],
        ["screentime-first-pass", "screentime/data/ScreentimeModel.js", [["(best === null || t < best)", "(best === null || t > best)"]], ["S4-daystart-in-transition"]]
    ];
    const copy = fs.mkdtempSync(path.join(os.tmpdir(), "dst-arms-"));
    fs.cpSync(MOD, copy, { recursive: true });
    const runCopy = () => cp.spawnSync(process.execPath, [__filename, "--audit"], { env: Object.assign({}, process.env, { DST_MOD: copy }), encoding: "utf8", timeout: 120000 }).stdout || "";
    let bad = 0;
    const clean = runCopy();
    if (!/DST-AUDIT RESULT PASS/.test(clean)) { console.log("DST-AUDIT ARMS: the clean copy is not green"); bad++; }
    for (const [name, file, edits, needles] of ARMS) {
        const orig = fs.readFileSync(path.join(MOD, file), "utf8");
        let t = orig, ok = true;
        for (const [a, b] of edits) {
            if (t.split(a).length !== 2) { console.log("ARM " + name + ": ANCHOR LOST in " + file + " (" + a.slice(0, 50) + ")"); ok = false; bad++; break; }
            t = t.replace(a, () => b);
        }
        if (!ok) continue;
        fs.writeFileSync(path.join(copy, file), t);
        const out = runCopy();
        fs.writeFileSync(path.join(copy, file), orig);
        const missed = needles.filter((n) => !new RegExp("DST " + n.replace(/[/]/g, "\\/") + " FINDING").test(out));
        console.log("ARM " + name + ": " + (missed.length ? "DID NOT BITE on " + missed.join(", ") : "red on " + needles.join(", ")));
        if (missed.length) bad++;
    }
    fs.rmSync(copy, { recursive: true, force: true });
    console.log("DST-AUDIT ARMS " + (bad === 0 ? "PASS" : "FAIL (" + bad + ")"));
    process.exit(bad === 0 ? 0 : 1);
}

// ================================================================================================ harness self-check
if (ARM) {
    const before = findings;
    check("ARM-wrong-expectation", "none", false, "deliberate");
    console.log(findings > before ? "DST-AUDIT ARM PASS (a failing expectation is a FINDING and the run exits 1)" : "DST-AUDIT ARM FAIL");
    process.exit(findings > before ? 0 : 1);
}
console.log("DST-AUDIT " + cases + " cases, " + findings + " findings, TZ " + process.env.TZ);
console.log("DST-AUDIT RESULT " + (findings === 0 ? "PASS" : "FAIL (" + findings + " findings)"));
process.exit(AUDIT || findings === 0 ? 0 : 1);
