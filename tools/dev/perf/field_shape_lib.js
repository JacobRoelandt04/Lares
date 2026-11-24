.pragma library
// field_shape_lib.js -- the field-shape differential's engine-neutral half: the same file runs in node (field_shape_replay.js strips the
// pragma and evals it) and in QV4 (tools/dev/perf/field_shape_qv4.qml.in imports it), so identity and timing are judged by one code.
//
// A corpus is field_shape_record.sh's: one GooeyGeometry.fieldShape() call a line, { cls, f, q, t, dt, params, src, state? }, numbers
// JSON cannot carry written as {"$n": "-0" | "NaN" | "Inf" | "-Inf"}. A replay carries each field's (`f`) state from call to call, as
// GooeyField does (`field._state = out.state`), and takes the recorded state where the record has one.
//
//   decode(text)        a record (or any JSON of the corpus), its special numbers restored
//   canon(value)        THE identity: JSON with every special number marked ({"$n": ..}), undefined marked ({"$u": 1}), keys in
//                       insertion order -- two values are identical when their canon strings are
//   identity(lines, fsA, fsB, log)   every call through both, chained per field; compares, per call, the whole output (shape and new
//                       state) and the inputs after the call (src, params, the state handed in: neither may mutate them differently).
//                       Returns { calls, diffs, first } -- `first` describes the first differing call
//   prepare(lines)      the records decoded once, for timing
//   bench(recs, fs)     one pass over prepared records, chained per field; returns the ms it took

function decode(text) {
    return JSON.parse(text, (k, v) => {
        if (v !== null && typeof v === "object" && !Array.isArray(v) && typeof v.$n === "string" && Object.keys(v).length === 1)
            return v.$n === "-0" ? -0 : v.$n === "NaN" ? NaN : v.$n === "Inf" ? Infinity : -Infinity;
        return v;
    });
}

function canon(value) {
    return JSON.stringify(value, (k, v) => {
        if (v === undefined)
            return { $u: 1 };
        if (typeof v === "number" && (v !== v || v === Infinity || v === -Infinity || (v === 0 && 1 / v < 0)))
            return { $n: v !== v ? "NaN" : v === 0 ? "-0" : v > 0 ? "Inf" : "-Inf" };
        return v;
    });
}

// Where two canon strings first differ, with some context.
function firstDiff(a, b) {
    let i = 0;
    const n = Math.min(a.length, b.length);
    while (i < n && a.charCodeAt(i) === b.charCodeAt(i))
        i++;
    const s = Math.max(0, i - 120);
    return { at: i, a: a.slice(s, i + 80), b: b.slice(s, i + 80) };
}

function identity(lines, fsA, fsB, log) {
    const lastA = {}, lastB = {};
    let calls = 0, diffs = 0, first = null;
    for (let n = 0; n < lines.length; n++) {
        const line = lines[n];
        if (!line)
            continue;
        const ra = decode(line), rb = decode(line);
        const stA = ra.state !== undefined ? ra.state : (lastA[ra.f] !== undefined ? lastA[ra.f] : {});
        const stB = rb.state !== undefined ? rb.state : (lastB[rb.f] !== undefined ? lastB[rb.f] : {});
        let oa, ob, ea = null, eb = null;
        try { oa = fsA(ra.src, ra.params, stA, ra.dt); } catch (e) { ea = String(e); }
        try { ob = fsB(rb.src, rb.params, stB, rb.dt); } catch (e) { eb = String(e); }
        calls++;
        const parts = [["error", canon(ea), canon(eb)]];
        if (ea === null && eb === null) {
            parts.push(["output", canon(oa), canon(ob)]);
            parts.push(["src after", canon(ra.src), canon(rb.src)]);
            parts.push(["params after", canon(ra.params), canon(rb.params)]);
            parts.push(["state in after", canon(stA), canon(stB)]);
        }
        let bad = null;
        for (const p of parts)
            if (p[1] !== p[2]) {
                bad = p;
                break;
            }
        if (bad) {
            diffs++;
            if (!first)
                first = { line: n, cls: ra.cls, f: ra.f, q: ra.q, what: bad[0], diff: firstDiff(bad[1], bad[2]) };
        }
        if (oa)
            lastA[ra.f] = oa.state;
        if (ob)
            lastB[rb.f] = ob.state;
    }
    return { calls: calls, diffs: diffs, first: first };
}

function prepare(lines) {
    const out = [];
    for (const line of lines)
        if (line) {
            const r = decode(line);
            out.push({ cls: r.cls, f: r.f, src: r.src, params: r.params, state: r.state !== undefined ? r.state : null, dt: r.dt });
        }
    return out;
}

function bench(recs, fs) {
    const last = {};
    const t0 = Date.now();
    for (let n = 0; n < recs.length; n++) {
        const r = recs[n];
        const st = r.state !== null ? r.state : (last[r.f] !== undefined ? last[r.f] : {});
        last[r.f] = fs(r.src, r.params, st, r.dt).state;
    }
    return Date.now() - t0;
}

// The median and the spread (min .. max) of a list of numbers.
function stats(xs) {
    const s = xs.slice().sort((a, b) => a - b);
    const m = s.length % 2 ? s[(s.length - 1) / 2] : 0.5 * (s[s.length / 2 - 1] + s[s.length / 2]);
    return { median: m, min: s[0], max: s[s.length - 1] };
}
