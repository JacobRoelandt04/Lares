#!/usr/bin/env node
// SuddenMove.js, table-tested under node: the window and the extremes (evaluate), the move's span (fromMs / toMs), the body's
// `facts` (the whole day, the axis, the span) and `merge` (the 1-minute points of the span in place of the 5-minute ones).
// The cases are tools/dev/fixtures/stock_notif/*.json (quotes in minutes from the session's open, written by make_cases.py).
//
//   node tools/dev/sudden_move_cases.js           ends with `SUDDEN_MOVE RESULT PASS|FAIL`
//   node tools/dev/sudden_move_cases.js --arm     proves the cases can fail (a wrong merge): must end FAIL
//
// The pragma-library files are loaded the dst_audit_cases way (`.import "X.js" as Y` becomes a load into Y).
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const ROOT = path.join(__dirname, "..", "..");
const ARM = process.argv.includes("--arm");
const cache = {};
function load(file) {
    file = path.resolve(file);
    if (cache[file]) return cache[file];
    let src = fs.readFileSync(file, "utf8").replace(/^\.pragma library.*$/m, "");
    src = src.replace(/^\.import\s+"([^"]+)"\s+as\s+(\w+)\s*$/gm, (m, rel, name) =>
        "var " + name + " = __load(" + JSON.stringify(path.resolve(path.dirname(file), rel)) + ");");
    const ctx = { __load: load, Math, JSON, Number, String, Object, Array, isFinite, isNaN, Date, RegExp, parseFloat };
    vm.createContext(ctx);
    vm.runInContext(src, ctx, { filename: file });
    return (cache[file] = ctx);
}
const S = load(path.join(ROOT, "modules/notifications/sources/SuddenMove.js"));
// --arm: a merge that only appends the fine points (the 5-minute ones of the span kept, nothing sorted): the cases must see it.
if (ARM) S.merge = (day, fine) => ({ t: day.t.concat(fine && fine.t ? fine.t : []), c: day.c.concat(fine && fine.c ? fine.c : []) });
const dir = path.join(ROOT, "tools/dev/fixtures/stock_notif");
const MIN = 60000;
const BASE = Date.UTC(2026, 10, 18, 14, 30);            // an open: 09:30 New York

const Cases = load(path.join(dir, "cases.js"));
const quoteOf = c => Cases.quoteOf(c, BASE);
const load1 = n => JSON.parse(fs.readFileSync(path.join(dir, n + ".json"), "utf8"));

let fails = 0, checks = 0;
function check(name, ok, detail) {
    checks++;
    if (!ok) fails++;
    console.log("SUDDEN " + (ok ? "ok   " : "FAIL ") + name + (ok ? "" : "  -- " + detail));
}
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// ---------------------------------------------------------------- evaluate: the window, the extremes, the span
const cases = {};
["a_drop_late", "b_jump_morning", "c_jump_after_open", "d_thin_gaps"].forEach(n => cases[n] = load1(n));
const params = { pct: 3, minutes: 30 };
const want = { a_drop_late: ["down"], b_jump_morning: ["up"], c_jump_after_open: ["up"], d_thin_gaps: ["up"] };
for (const n in cases) {
    const c = cases[n], q = quoteOf(c), now = q.timeMs;
    const mv = S.evaluate(q, params, now);
    const m = want[n][0] === "up" ? mv.up : mv.down;
    const other = want[n][0] === "up" ? mv.down : mv.up;
    check(n + ": the move is found in its direction only", !!m && !other, JSON.stringify(mv));
    if (!m) continue;
    check(n + ": the span runs from the window's extreme to now", m.fromMs >= now - 30 * MIN && m.toMs === now && m.fromMs < m.toMs,
          "from " + (m.fromMs - BASE) / MIN + " to " + (m.toMs - BASE) / MIN);
    const win = q.spark.c.filter((v, i) => q.spark.t[i] >= now - 30 * MIN);
    check(n + ": from is the extreme close of the window (the low of a jump, the high of a drop)", m.from === (want[n][0] === "up" ? Math.min.apply(null, win) : Math.max.apply(null, win)),
          m.from + " in " + JSON.stringify(win));
    check(n + ": from / to are the close and the live price", m.from === q.spark.c[q.spark.t.indexOf(m.fromMs)] && m.to === c.live,
          m.from + " " + m.to);
    check(n + ": the move keeps what the words need (pct, minutes) and carries no window values", m.pct >= 3 && m.minutes >= 1 && m.values === undefined,
          JSON.stringify(Object.keys(m)));
}

// ---------------------------------------------------------------- facts: the whole day
for (const n in cases) {
    const c = cases[n], q = quoteOf(c), now = q.timeMs;
    const mv = S.evaluate(q, params, now), m = mv.up || mv.down;
    const f = S.facts(q, m, params, now);
    const dayPts = c.bars.length + 1;
    check(n + ": facts hold the whole day (" + dayPts + " points: every bar, then the live price)",
          f.t.length === dayPts && f.c.length === dayPts && f.t[f.t.length - 1] === q.timeMs && f.c[f.c.length - 1] === c.live,
          f.t.length + " points");
    check(n + ": facts: kind, dir, axis, baseline, span", f.kind === "sudden" && f.dir === m.dir && f.sessionStart === BASE && f.nowMs === now
          && f.prevClose === c.prevClose && f.fromMs === m.fromMs && f.toMs === m.toMs && f.minSpanPct === 6 && f.level === null, JSON.stringify(f, (k, v) => k === "t" || k === "c" ? undefined : v));
    check(n + ": facts copy the quote's arrays", f.t !== q.spark.t && f.c !== q.spark.c, "shared");
}
// a quote whose last bar already is the live price: one point, not two
{
    const q = quoteOf(cases.a_drop_late);
    q.spark.t.push(q.timeMs); q.spark.c.push(1);
    const f = S.facts(q, null, null, q.timeMs, { kind: "dayMove" });
    check("facts: the live price replaces a last bar of the same instant", f.t.length === q.spark.t.length && f.c[f.c.length - 1] === q.price, f.t.length);
}
// alert kinds
for (const n of ["e_above", "f_below", "g_daymove"]) {
    const c = load1(n), q = quoteOf(c);
    const f = S.facts(q, null, null, q.timeMs, { kind: c.kind, level: c.kind === "dayMove" ? null : c.level });
    check(n + ": an alert's facts (kind, level, 2 % least span, no span, day sign)", f.kind === c.kind && f.level === (c.kind === "dayMove" ? null : c.level)
          && f.minSpanPct === 2 && f.fromMs === null && f.toMs === null && f.dir === (c.live < c.prevClose ? "down" : "up")
          && f.t.length === c.bars.length + 1, JSON.stringify(f, (k, v) => k === "t" || k === "c" ? undefined : v));
}

// ---------------------------------------------------------------- merge
const day = { t: [0, 5, 10, 15, 20, 25, 30].map(m => BASE + m * MIN), c: [10, 11, 12, 13, 14, 15, 16] };
const fine = (a, b) => { const t = [], c = []; for (let m = a; m <= b; m++) { t.push(BASE + m * MIN); c.push(100 + m); } return { t, c }; };
let r = S.merge(day, fine(10, 30), BASE + 15 * MIN, BASE + 30 * MIN);
check("merge: outside the span stays 5-minute, inside is 1-minute", eq(r.t.filter(t => t < BASE + 15 * MIN).map(t => (t - BASE) / MIN), [0, 5, 10])
      && r.t.filter(t => t >= BASE + 15 * MIN).length === 16, JSON.stringify(r.t.map(t => (t - BASE) / MIN)));
check("merge: sorted by time, no duplicates", r.t.every((t, i) => i === 0 || t > r.t[i - 1]), "unsorted");
check("merge: the live price stays the last point", r.t[r.t.length - 1] === day.t[6] && r.c[r.c.length - 1] === 16, r.c[r.c.length - 1]);
check("merge: the 5-minute points inside the span are replaced, not kept beside", !r.t.some((t, i) => t === BASE + 20 * MIN && r.c[i] === 14), "kept");
r = S.merge(day, { t: [], c: [] }, BASE + 15 * MIN, BASE + 30 * MIN);
check("merge: an empty fine answer returns the day", eq(r, day), JSON.stringify(r));
r = S.merge(day, null, BASE + 15 * MIN, BASE + 30 * MIN);
check("merge: no fine answer returns the day (a copy)", eq(r, day) && r.t !== day.t, "");
const gappy = { t: [16, 17, 25, 26].map(m => BASE + m * MIN), c: [1, 2, 3, 4] };
r = S.merge(day, gappy, BASE + 15 * MIN, BASE + 30 * MIN);
check("merge: a fine answer with gaps keeps its gaps", eq(r.t.filter(t => t > BASE + 15 * MIN && t < BASE + 30 * MIN).map(t => (t - BASE) / MIN), [16, 17, 25, 26]), JSON.stringify(r.t.map(t => (t - BASE) / MIN)));
const beyond = fine(10, 40);
r = S.merge(day, beyond, BASE + 15 * MIN, BASE + 30 * MIN);
check("merge: fine points past the live price are dropped", r.t[r.t.length - 1] === BASE + 30 * MIN && r.c[r.c.length - 1] === 16, JSON.stringify(r.t.slice(-2)));
const unsorted = { t: [20, 18, 22].map(m => BASE + m * MIN), c: [1, 2, 3] };
r = S.merge(day, unsorted, BASE + 15 * MIN, BASE + 30 * MIN);
check("merge: an unsorted fine answer is sorted", r.t.every((t, i) => i === 0 || t > r.t[i - 1]), JSON.stringify(r.t));
const outside = fine(0, 12);
r = S.merge(day, outside, BASE + 15 * MIN, BASE + 30 * MIN);
check("merge: a fine answer wholly outside the span changes nothing", eq(r, day), JSON.stringify(r.t));
check("merge: the inputs are not touched", day.t.length === 7 && day.c[6] === 16, "");

console.log("SUDDEN_MOVE RESULT " + (fails === 0 ? "PASS" : "FAIL") + " (" + (checks - fails) + "/" + checks + " checks)");
process.exit(fails === 0 ? 0 : 1);
