.pragma library
.import "WeatherInkParts.js" as P
.import "WeatherInkCompose.js" as C
.import "GlyphOutline.js" as O

// =============================================================================
// WeatherInkPose.js -- the ink weather icons' flourishes (feedback/weather.md "Flourish"): every icon moves as what it shows.
// Pure functions of the flourish's one clock, in BEATS (x = GlyphFlourish.t / the host's flourishMs; a beat is the bar's
// usual flourish, 900 ms):
//
//   time(key)        how many beats the icon's flourish runs (the host's GlyphFlourish.ms is flourishMs * time)
//   beats(kind, ..)  the same from a condition, and for the two icons that are not compositions: the moon by phase (it rocks:
//                    moonAngle) and the wind arrow (it draws back and darts: arrowNudge; with no direction its dot swells:
//                    dotPulse) -- WeatherGlyphInk moves those as whole items
//   paths(key, x)    { ink, inkMove, accent, accentMove, token }: the icon at beat x as SVG paths in grid units (y down).
//                    The parts that stand still keep their strings for the whole run (nothing re-tessellates them).
//
// The bar's flourishes are snappy (a strike, an OutBack, a quick decay); the sky is not, so each part takes the bar's curves
// at the pace of the thing it is -- what falls and strikes is quick, what drifts runs longer on the same eases:
//
//   sun        winds back a touch and turns a quarter (two rays on: the same sun again) with an overshoot, its rays reaching
//              out on the way round; behind a cloud it only turns
//   moon       rocks on its back, twice, dying away; its stars wink out and pop back one after the other
//              behind a cloud it dips out of sight and comes back up with a bounce
//   cloud      takes a breath (a quick swell from its foot) and sways; two clouds part and close again, the far one sliding
//              out from behind the near one
//   drop       lets go: falls away shrinking, then a new one swells from its point under the cloud (streaks the same, along
//              their slant), one after the other
//   flake      melts to a seed and GROWS again, a crystal: its three axes shoot out one after the other, each past its length
//              and back, while it dips and sways a little
//   stone      hops, lands with a squash and bounces back up to where it hangs
//   bolt       is drawn up toward the cloud (it shrinks to its top, never out of sight), strikes back down past its length and
//              shivers still; the cloud's cut follows it; rain under it starts after
//   fog        its rows slide past each other, odd rows one way and even the other, and settle
//   wind       each line's STRAIGHT part is pulled short and shot back out past its length; the hook rides on its end, its
//              shape untouched
//
// EVERY MOTION IS ZERO AT ITS FIRST AND LAST INSTANT, so the swap with the icon at rest shows nothing. A part that another
// part covers is not moved here: the generator baked it along its motion (P.FRAMES) and this file picks the frame.
// Coordinates are the outlines': y UP, angles counter-clockwise.
// =============================================================================

var RAD = Math.PI / 180;

// The motions' numbers (beats, grid units, degrees). `look` overrides a member (a tuning pass, a probe).
var DEFAULTS = {
    sunWind: 10, sunTurn: 90, sunBack: 1.7, sunReach: 0.12,
    moonRock: 14, moonSwings: 1.5, moonBeats: 1.5, starGap: 0.3, starBeats: 0.6,
    dipBeats: 1.6, dipBack: 1.8,
    cloudBeats: 1.8, cloudSway: 1.0, cloudBreath: 0.1, partFront: 1.1, partBack: 1.0, backBeats: 1.3, backSlide: 1.2,
    dropFall: 3.0, dropBeats: 0.62, dropGap: 0.12, dropBack: 2.0, afterBolt: 0.5,
    flakeSeed: 0.12, flakeBack: 2.2, flakeBeats: 1.2, flakeGap: 0.1, flakeDip: 0.5, flakeSway: 0.3,
    stoneHop: 1.2, stoneBeats: 0.8, stoneGap: 0.1, stoneSquash: 0.2,
    boltUp: 0.45, boltBack: 1.4, boltShake: 0.4,
    arrowBeats: 0.8, arrowBack: 1.2, arrowDart: 2.0, dotBeats: 0.6, dotSwell: 0.35,
    fogSlide: 1.3, fogBeats: 2.0,
    windPull: 3.0, windBack: 2.0, windBeats: 0.75, windGap: 0.14
};

function _look(look) {
    if (!look)
        return DEFAULTS;
    const l = {};
    for (const k in DEFAULTS)
        l[k] = look[k] !== undefined ? Number(look[k]) : DEFAULTS[k];
    return l;
}

// a push out and a small swing back, 0 at both ends, 1 at its furthest (the clouds' slide)
function _sway(u) {
    return O.smooth(0, 0.18, u) * (1 - u) * Math.sin(1.5 * Math.PI * u) / 0.69;
}

// ---- how long each part runs (beats) -------------------------------------------------------------------------------------
function _delay(key) {
    return key.indexOf("thunder") === 0 ? DEFAULTS.afterBolt : 0;
}
function _end(e, key, l) {
    const a = e[3];
    switch (e[2]) {
    case "sun":
    case "sunCut":
    case "bolt":
    case "cloudBolt":
        return 1;
    case "moon":
        return l.moonBeats;
    case "sparkle":
        return 0.15 + l.starGap * a[2] + l.starBeats;
    case "moonCut":
        return l.dipBeats;
    case "cloudFree":
    case "cloudFront":
    case "cloudPart":
        return l.cloudBeats;
    case "cloudBack":
        return l.backBeats;
    case "drop":
        return _delay(key) + l.dropGap * a[4] + l.dropBeats;
    case "flake":
        return l.flakeGap * a[2] + l.flakeBeats;
    case "stone":
        return l.stoneGap * a[3] + l.stoneBeats;
    case "bar":
        return l.fogBeats;
    case "curl":
        return l.windGap * a[4] + l.windBeats;
    }
    return 0;
}
var _times = {};
function time(key) {
    let t = _times[key];
    if (t === undefined) {
        t = 0;
        const comp = P.COMPS[key] || [];
        for (let i = 0; i < comp.length; ++i)
            t = Math.max(t, _end(comp[i], key, DEFAULTS));
        _times[key] = t;
    }
    return t;
}

function beats(kind, intensity, night, shower, directed) {
    if (kind === "moon")
        return DEFAULTS.moonBeats;
    if (kind === "arrow")
        return directed ? DEFAULTS.arrowBeats : DEFAULTS.dotBeats;
    return time(C.key(kind, intensity, night, shower));
}

// ---- the motions (exported: a probe reads the numbers) -------------------------------------------------------------------
// the wind arrow along its own heading (units; below zero is back): draws back, darts, springs home
function arrowNudge(x, look) {
    const l = _look(look), u = O.clamp01(x / l.arrowBeats);
    if (u < 0.25)
        return -l.arrowBack * O.outQuad(u / 0.25);
    if (u < 0.45)
        return -l.arrowBack + (l.arrowBack + l.arrowDart) * O.outCubic(O.seg(u, 0.25, 0.45));
    return l.arrowDart * (1 - O.outBack(O.seg(u, 0.45, 1), 1.7));
}
// the dot of "no direction": a swell
function dotPulse(x, look) {
    const l = _look(look), u = O.clamp01(x / l.dotBeats);
    return 1 + l.dotSwell * Math.sin(Math.PI * u) * (1 - u);
}
// the bolt's size about its top: drawn up, then struck back down past its length
function boltSize(x, l) {
    const u = O.clamp01(x);
    if (u < 0.24)
        return 1 - (1 - l.boltUp) * O.inOutQuad(u / 0.24);
    return l.boltUp + (1 - l.boltUp) * O.outBack(O.seg(u, 0.24, 0.62), l.boltBack);
}
// the sun's angle at beat x (deg, counter-clockwise: it winds back, then turns clockwise)
function sunAngle(x, l) {
    const u = O.clamp01(x);
    if (u < 0.16)
        return l.sunWind * O.outQuad(u / 0.16);
    return l.sunWind - (l.sunWind + l.sunTurn) * O.outBack(O.seg(u, 0.16, 1), l.sunBack);
}
function moonAngle(x, l) {
    const u = O.clamp01(x / l.moonBeats);
    return l.moonRock * O.smooth(0, 0.12, u) * (1 - u) * Math.exp(-1.2 * u) * Math.sin(2 * Math.PI * l.moonSwings * u);
}
// how far a moon behind a cloud has dipped (units down; below zero while it bounces back up)
function moonDip(x, dip, l) {
    const u = O.clamp01(x / l.dipBeats);
    if (u < 0.38)
        return dip * O.inOutQuad(u / 0.38);
    if (u < 0.5)
        return dip;
    return dip * (1 - O.outBack(O.seg(u, 0.5, 1), l.dipBack));
}
function _frame(name, value) {
    const f = P.FRAMES[name];
    const i = Math.max(0, Math.min(f[2].length - 1, Math.round((value - f[0]) / f[1])));
    return f[2][i];
}
function _emit(pid, fn) {
    return pid === "" ? "" : O.emit(P.PARTS[pid], fn, 1, 0, P.UNITS);
}
function _about(cx, cy, sx, sy, dx, dy) {
    return function (x, y) {
        return [cx + (x - cx) * sx + dx, cy + (y - cy) * sy + dy];
    };
}

// one part at beat x: its path, or null when it does not move in this icon
function _part(e, key, x, l) {
    const pid = e[0], a = e[3];
    switch (e[2]) {
    case "sun": {
        const th = sunAngle(x, l) * RAD, u = O.clamp01(x);
        const reach = 1 + l.sunReach * Math.sin(Math.PI * O.seg(u, 0.16, 0.7));
        const cx = a[0], cy = a[1], r2 = 1.5625 * a[2] * a[2];
        return _emit(pid, function (px, py) {
            const dx = px - cx, dy = py - cy;
            // a ray's points stand out from the disc: they reach, the disc does not
            const s = dx * dx + dy * dy > r2 ? reach : 1;
            return O.turn(cx + dx * s, cy + dy * s, cx, cy, th);
        });
    }
    case "sunCut": {
        // the frames are the sun turned CLOCKWISE (the generator draws y down), 0 .. 45 deg, and it repeats there
        const turn = -sunAngle(x, l);
        return C.part(_frame(e[4], ((turn % 45) + 45) % 45 % 45));
    }
    case "moon":
        return _emit(pid, function (px, py) {
            return O.turn(px, py, a[0], a[1], moonAngle(x, l) * RAD);
        });
    case "sparkle": {
        const v = O.seg(x, 0.15 + l.starGap * a[2], 0.15 + l.starGap * a[2] + l.starBeats);
        if (v <= 0 || v >= 1)
            return C.part(pid);
        const s = v < 0.35 ? 1 - O.inQuad(v / 0.35) : O.outBack((v - 0.35) / 0.65, 2.2);
        if (s < 0.03)
            return "";
        const th = -90 * RAD * O.inOutQuad(v);
        return _emit(pid, function (px, py) {
            const q = O.turn(px, py, a[0], a[1], th);
            return [a[0] + (q[0] - a[0]) * s, a[1] + (q[1] - a[1]) * s];
        });
    }
    case "moonCut":
        return C.part(_frame(e[4], moonDip(x, a[0], l)));
    case "cloudFree": {
        const u = O.clamp01(x / l.cloudBeats);
        const b = Math.sin(Math.PI * O.seg(u, 0, 0.3));
        const dx = l.cloudSway * O.smooth(0, 0.15, u) * (1 - u) * Math.sin(2.5 * Math.PI * u);
        return _emit(pid, _about(a[0], a[1], 1 + 0.4 * l.cloudBreath * b, 1 + l.cloudBreath * b, dx, 0));
    }
    case "cloudFront": {
        const w = _sway(O.clamp01(x / l.cloudBeats));
        return _emit(pid, _about(0, 0, 1, 1, -l.partFront * w, 0));
    }
    case "cloudPart": {
        // the frame is how far apart the two stand; it is drawn with the front cloud, so it slides with it
        const w = _sway(O.clamp01(x / l.cloudBeats));
        return _emit(_frame(e[4], (l.partFront + l.partBack) * w), _about(0, 0, 1, 1, -l.partFront * w, 0));
    }
    case "cloudBack":
        return C.part(_frame(e[4], l.backSlide * _sway(O.clamp01(x / l.backBeats))));
    case "drop": {
        const t0 = _delay(key) + l.dropGap * a[4];
        const v = O.seg(x, t0, t0 + l.dropBeats);
        if (v <= 0 || v >= 1)
            return C.part(pid);
        if (v < 0.4) {
            // lets go: along its own slant, shrinking about its belly
            const p = O.inQuad(v / 0.4), s = 1 - p;
            if (s < 0.03)
                return "";
            const lx = a[2] - a[0], ly = a[3] - a[1], ln = Math.sqrt(lx * lx + ly * ly) || 1;
            return _emit(pid, _about(a[2], a[3], s, s, l.dropFall * p * lx / ln, l.dropFall * p * ly / ln));
        }
        const s = O.outBack((v - 0.4) / 0.6, l.dropBack);
        if (s < 0.03)
            return "";
        return _emit(pid, _about(a[0], a[1], s, s, 0, 0));
    }
    case "flake": {
        const v = O.seg(x, l.flakeGap * a[2], l.flakeGap * a[2] + l.flakeBeats);
        if (v <= 0 || v >= 1)
            return C.part(pid);
        // how long each of the three axes is (1 = its own length): all melt to a seed, then grow one axis after the other
        const melt = 1 - (1 - l.flakeSeed) * O.inQuad(O.seg(v, 0, 0.26));
        const g = [0, 0, 0];
        for (let i = 0; i < 3; ++i)
            g[i] = v < 0.3 + 0.12 * i ? melt : l.flakeSeed + (1 - l.flakeSeed) * O.outBack(O.seg(v, 0.3 + 0.12 * i, 0.62 + 0.12 * i), l.flakeBack);
        const dx = l.flakeSway * Math.sin(2 * Math.PI * v), dy = -l.flakeDip * Math.sin(Math.PI * v);
        const cx = a[0], cy = a[1], hub = a[3];
        return _emit(pid, function (px, py) {
            // the arm this point is on (arms stand at 30, 90, 150 ... deg; opposite arms are one axis), and how far along it
            const rx = px - cx, ry = py - cy;
            const k = ((Math.round((Math.atan2(ry, rx) / RAD - 30) / 60) % 6) + 6) % 6;
            const ux = Math.cos((30 + 60 * k) * RAD), uy = Math.sin((30 + 60 * k) * RAD);
            const along = rx * ux + ry * uy;
            if (along <= hub)
                return [px + dx, py + dy];
            const grow = (along - hub) * (g[k % 3] - 1);
            return [px + grow * ux + dx, py + grow * uy + dy];
        });
    }
    case "stone": {
        const v = O.seg(x, l.stoneGap * a[3], l.stoneGap * a[3] + l.stoneBeats);
        if (v <= 0 || v >= 1)
            return C.part(pid);
        const floor = 0.75 + a[2], top = a[1] + l.stoneHop;
        let y;
        if (v < 0.25)
            y = a[1] + l.stoneHop * O.outQuad(v / 0.25);
        else if (v < 0.58)
            y = top + (floor - top) * O.inQuad(O.seg(v, 0.25, 0.58));
        else
            y = floor + (a[1] - floor) * O.outQuad(O.seg(v, 0.58, 1));
        const q = Math.sin(Math.PI * O.seg(v, 0.5, 0.68));
        // squashed onto its own foot
        return _emit(pid, _about(a[0], a[1] - a[2], 1 + l.stoneSquash * q, 1 - l.stoneSquash * q, 0, y - a[1]));
    }
    case "bolt": {
        const u = O.clamp01(x);
        if (u <= 0 || u >= 1)
            return C.part(pid);
        const s = boltSize(x, l), w = O.seg(u, 0.4, 1);
        const dx = l.boltShake * Math.exp(-4 * w) * (1 - w) * Math.sin(2 * Math.PI * 2.6 * w);
        return _emit(pid, _about(a[0], a[1], s, s, dx, 0));
    }
    case "cloudBolt":
        // cut round the bolt at the size it has now (baked: the cloud is behind it)
        return C.part(_frame(e[4], boltSize(x, l)));
    case "bar": {
        const u = O.clamp01(x / l.fogBeats);
        const dir = a[0] % 2 ? -1 : 1;
        const dx = dir * l.fogSlide * O.smooth(0, 0.15, u) * (1 - u) * Math.sin(2 * Math.PI * (u - 0.05 * a[0]));
        return _emit(pid, _about(0, 0, 1, 1, dx, 0));
    }
    case "curl": {
        const v = O.seg(x, l.windGap * a[4], l.windGap * a[4] + l.windBeats);
        if (v <= 0 || v >= 1)
            return C.part(pid);
        // how far the line's end stands from where it rests (units; below zero is short)
        const len = a[1] - a[0], pull = Math.min(l.windPull, 0.45 * len);
        const end = -pull * (v < 0.3 ? O.outQuad(v / 0.3) : 1 - O.outBack((v - 0.3) / 0.7, l.windBack));
        const x0 = a[0], x1 = a[1], y0 = a[2], band = a[3] + 0.06, k = (len + end) / len;
        return _emit(pid, function (px, py) {
            // the straight part stretches between its two ends; the hook (everything off the line) rides on the end
            if (px <= x1 + 0.01 && Math.abs(py - y0) <= band)
                return [px <= x0 ? px : x0 + (px - x0) * k, py];
            return [px + end, py];
        });
    }
    }
    return null;
}

// the parts of `key` that stand still through its flourish, as the two fills' strings (kept: the same strings every frame)
var _still = {};
function _stillOf(key, comp) {
    let s = _still[key];
    if (s === undefined) {
        s = { ink: "", accent: "" };
        for (let i = 0; i < comp.length; ++i) {
            if (_end(comp[i], key, DEFAULTS) > 0)
                continue;
            if (comp[i][1] === "ink")
                s.ink += C.part(comp[i][0]);
            else
                s.accent += C.part(comp[i][0]);
        }
        _still[key] = s;
    }
    return s;
}

function paths(key, x, look) {
    const comp = P.COMPS[key] || P.COMPS["cloud"];
    const l = _look(look);
    const st = _stillOf(key, comp);
    const out = { ink: st.ink, accent: st.accent, inkMove: "", accentMove: "", token: "" };
    for (let i = 0; i < comp.length; ++i) {
        const e = comp[i];
        if (e[1] !== "ink")
            out.token = e[1];
        const d = _part(e, key, x, l);
        if (d === null)
            continue;
        if (e[1] === "ink")
            out.inkMove += d;
        else
            out.accentMove += d;
    }
    return out;
}
