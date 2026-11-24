.pragma library
.import "GlyphOutline.js" as O

// =============================================================================
// GlyphSignal.js -- the motions the SIGNAL glyphs share (the audio pill's and the networking pill's: AudioPose.js, NetPose.js).
//
// Their family: EACH GIVES ITS SIGNAL ONCE. The thing that sends kicks (`thump`) and, only while it is really ON, throws one wave
// (`wave`) that flies off and thins to nothing; what is off or muted makes the same start and nothing comes out. So the motion
// never says more than the glyph's state does, and the wave is never a second copy of a real one: it is a crescent (pointed
// ends, thinner than any real wave), it never rests, and it is ink the glyph does not have -- gone at both ends of the clock.
//
// What is NOT a signal is never drawn as one: a muted speaker lets out a PUFF (`clump`: one little cloud of a few unequal lobes
// -- air, not sound), and the plane's speed is WIND (`streak`: straight lines behind it). Neither is an arc about a source, so
// neither can be read as a wave.
//
// Everything is a pure function of the flourish's clock (ms) and zero at its first and last instant.
// =============================================================================

// 0 -> 1 -> 0 across 0..1, 0 outside
function bump(x) {
    return x <= 0 || x >= 1 ? 0 : Math.sin(Math.PI * x);
}

// A kick: out hard (its peak, 1, about a fifth of a period in), back past rest, a small second swing, still by `life`.
function thump(t, life, periodMs, decayMs) {
    if (t <= 0 || t >= life)
        return 0;
    const w = 2 * Math.PI / periodMs;
    // the peak of e^(-t/d) sin(w t), so the kick's size is the caller's number
    const tp = Math.atan(w * decayMs) / w;
    const peak = Math.exp(-tp / decayMs) * Math.sin(w * tp);
    return Math.exp(-t / decayMs) * Math.sin(w * t) * (1 - t / life) / peak;
}

// The thrown wave `x` (0..1) through its flight: a crescent about (cx, cy) opening toward `dir` (radians, font space), its
// middle from radius r0 out by `travel` (fast, then slowing), `half` radians to each tip, its thickness up to w0 within the
// first sixth and down to nothing at the end. One contour (GlyphOutline segments), or null while there is none.
function wave(x, cx, cy, dir, r0, travel, half, w0) {
    if (x <= 0 || x >= 1)
        return null;
    const r = r0 + travel * O.outCubic(x);
    const w = w0 * Math.min(1, x * 6) * (1 - x);
    const n = 8, outer = [], inner = [];
    for (let i = 0; i <= n; ++i) {
        const f = -1 + 2 * i / n;
        // pointed tips: the thickness falls to nothing at each end
        const h = 0.5 * w * Math.sqrt(Math.max(0, 1 - f * f));
        const a = dir + f * half;
        outer.push([cx + (r + h) * Math.cos(a), cy + (r + h) * Math.sin(a)]);
        if (i > 0 && i < n)
            inner.push([cx + (r - h) * Math.cos(a), cy + (r - h) * Math.sin(a)]);
    }
    return O.polygon(outer.concat(inner.reverse()));
}

// the wave's greatest thickness at flight share x (what a probe holds against a real wave's)
function waveWidth(x, w0) {
    return x <= 0 || x >= 1 ? 0 : w0 * Math.min(1, x * 6) * (1 - x);
}

// A spring let go with a kick: it stands at `from` when t = 0 (held there: a build-up), swings out to about `peak` the other
// way and rings down to nothing by `life`. `from` at t <= 0, 0 from `life` on.
function sprung(t, life, from, peak, periodMs, decayMs) {
    if (t <= 0)
        return from;
    if (t >= life)
        return 0;
    return from * Math.exp(-t / decayMs) * Math.cos(2 * Math.PI * t / periodMs) * (1 - t / life) + peak * thump(t, life, periodMs, decayMs);
}

// a bell: 1 at x = 0, gone (under a hundredth) three widths out
function lump(x) {
    return Math.exp(-0.5 * x * x);
}

// A CLUMP: the outline of a union of discs ([[cx, cy, r], ...], font units) -- what a PUFF is made of (a cloud is a few unequal
// lobes run into each other: ONE outline, with a crease where two meet). Returns one closed contour per separate clump (a
// pose that wants one cloud keeps its discs overlapping), each a run of arcs joined at the creases -- never two contours
// that touch or cross, which the curve renderer resolves wrongly (PosedGlyph); a gap three discs close round is filled.
// Lumpy from every side: never an arc about a source, so never a wave.
function clump(discs) {
    const TAU = 2 * Math.PI;
    const arcs = [];
    for (let i = 0; i < discs.length; ++i) {
        const x = discs[i][0], y = discs[i][1], r = discs[i][2];
        if (!(r > 0))
            continue;
        // the stretches of this disc's rim that lie inside another disc: [from, to], radians, to > from
        const cover = [];
        let gone = false;
        for (let j = 0; j < discs.length && !gone; ++j) {
            const rj = discs[j][2];
            if (j === i || !(rj > 0))
                continue;
            const dx = discs[j][0] - x, dy = discs[j][1] - y, d = Math.sqrt(dx * dx + dy * dy);
            if (d + r <= rj) {
                // wholly inside j (of two discs that coincide the first stays)
                gone = d + r < rj || j < i;
            } else if (d < r + rj && d + rj > r) {
                const mid = Math.atan2(dy, dx), half = Math.acos((d * d + r * r - rj * rj) / (2 * d * r));
                let a = (mid - half) % TAU;
                if (a < 0)
                    a += TAU;
                cover.push([a, a + 2 * half]);
            }
        }
        if (gone)
            continue;
        if (cover.length === 0) {
            arcs.push({ x: x, y: y, r: r, a: 0, b: TAU, whole: true });
            continue;
        }
        // the covered stretches merged, and what lies between two of them is rim that shows
        cover.sort((p, q) => p[0] - q[0]);
        const merged = [cover[0].slice()];
        for (let k = 1; k < cover.length; ++k) {
            const last = merged[merged.length - 1];
            if (cover[k][0] <= last[1])
                last[1] = Math.max(last[1], cover[k][1]);
            else
                merged.push(cover[k].slice());
        }
        // the last one may run on round past the first
        const reach = merged[merged.length - 1][1] - TAU;
        while (merged.length > 1 && merged[0][0] <= reach) {
            merged[merged.length - 1][1] = Math.max(merged[merged.length - 1][1], merged[0][1] + TAU);
            merged.shift();
        }
        if (merged.length === 1 && merged[0][1] - merged[0][0] >= TAU)
            continue;
        for (let k = 0; k < merged.length; ++k) {
            const a = merged[k][1], next = merged[(k + 1) % merged.length][0];
            arcs.push({ x: x, y: y, r: r, a: a, b: next + (next < a ? TAU : 0), whole: false });
        }
    }
    const at = (c, a) => [c.x + c.r * Math.cos(a), c.y + c.r * Math.sin(a)];
    const out = [];
    for (let i = 0; i < arcs.length; ++i) {
        if (arcs[i].used)
            continue;
        // walk the outline: where one arc ends on another disc's rim, that disc's arc starts
        const pts = [];
        let c = arcs[i], area = 0;
        for (let guard = 0; c && !c.used && guard <= arcs.length; ++guard) {
            c.used = true;
            const n = Math.max(2, Math.ceil((c.b - c.a) / 0.26));
            for (let k = 0; k < n; ++k)
                pts.push(at(c, c.a + (c.b - c.a) * k / n));
            if (c.whole)
                break;
            const end = at(c, c.b);
            let best = null, bd = 1e18;
            for (let j = 0; j < arcs.length; ++j) {
                if (arcs[j].whole || (arcs[j].used && j !== i))
                    continue;
                const q = at(arcs[j], arcs[j].a), dd = (q[0] - end[0]) * (q[0] - end[0]) + (q[1] - end[1]) * (q[1] - end[1]);
                if (dd < bd) {
                    bd = dd;
                    best = arcs[j];
                }
            }
            c = best;
        }
        for (let k = 0; k < pts.length; ++k) {
            const p = pts[k], q = pts[(k + 1) % pts.length];
            area += p[0] * q[1] - q[0] * p[1];
        }
        // counter-clockwise is an outline; the other way round is a gap the discs close round: filled
        if (pts.length >= 3 && area > 0)
            out.push(O.polygon(pts));
    }
    return out;
}

// WIND: a streak along y from its head at x0 back to its tail at x1 (x1 < x0): `w` thick just behind the head and drawn out
// to a point at the tail -- a dart, straight, with the way it flies in its shape. One contour, or null.
function streak(x0, x1, y, w) {
    if (w <= 0 || x0 - x1 <= 0)
        return null;
    const q = Math.min((x0 - x1) / 4, 1.2 * w), h = 0.5 * w;
    return O.polygon([[x1, y], [x0 - q, y - h], [x0, y], [x0 - q, y + h]]);
}

// a part scaled by (sx, sy) about (cx, cy)
function scaled(cx, cy, sx, sy) {
    return function (x, y) {
        return [cx + (x - cx) * sx, cy + (y - cy) * sy];
    };
}

// the glyph's key in a parts table: its codepoint in hex
function key(text) {
    return text && text.length > 0 ? text.codePointAt(0).toString(16) : "";
}
