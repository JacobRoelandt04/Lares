.pragma library
.import "WeatherInkParts.js" as P
.import "GlyphOutline.js" as O

// =============================================================================
// WeatherInkCompose.js -- condition -> the ink weather icon's two paths.
//
// The icons themselves are drawn by tools/dev/weather_ink_parts.py (WeatherInkParts.js: parts as contours on a 24-unit
// grid, compositions as lists of [part, role]). This file picks the composition for a condition and writes it as SVG paths
// in the grid's own units (y down), which WeatherGlyphInk scales to its size: `ink` (every part in the glyph's ink) and
// `accent` (the icon's ONE coloured part, `token` its theme token, "" when the icon has none).
//
// A sky that rains, snows or storms is one of four (the generator's `sky`): plain, a sun or a crescent behind the cloud (a
// shower, by day or night), or a second cloud behind it (heavy; hail and thunder always, as in the carved set).
// Two icons are computed here, not generated: the moon by phase and nothing else needs a parameter.
// =============================================================================

var UNITS = P.UNITS;
var _cache = {};

function key(kind, intensity, night, shower) {
    switch (kind) {
    case "clear":
        return night ? "clear|n" : "clear|d";
    case "sun":
        return "clear|d";
    case "partly":
        return night ? "partly|n" : "partly|d";
    case "cloudy":
    case "fog":
    case "wind":
        return kind;
    case "fogbank":
        return "fog";
    case "rain":
    case "sleet":
    case "snow":
    case "hail":
    case "thunder": {
        const n = Math.max(0, Math.min(2, Math.round(Number(intensity) || 0)));
        const heavy = kind === "hail" || kind === "thunder" || n >= 2;
        const sky = shower ? (night ? "moon" : "sun") : (heavy ? "heavy" : "plain");
        return kind + "|" + n + "|" + sky;
    }
    default:
        return "cloud";
    }
}

// a part's outline at rest as an SVG path in grid units (y down); "" for no part
var _parts = {};
function part(pid) {
    if (pid === "")
        return "";
    let d = _parts[pid];
    if (d === undefined)
        d = _parts[pid] = O.emit(P.PARTS[pid], O.same, 1, 0, P.UNITS);
    return d;
}

// { ink, accent, token } for a composition key
function paths(k) {
    let hit = _cache[k];
    if (hit)
        return hit;
    const comp = P.COMPS[k] || P.COMPS["cloud"];
    hit = { ink: "", accent: "", token: "" };
    for (let i = 0; i < comp.length; ++i) {
        const d = part(comp[i][0]);
        if (comp[i][1] === "ink") {
            hit.ink += d;
        } else {
            hit.accent += d;
            hit.token = comp[i][1];
        }
    }
    _cache[k] = hit;
    return hit;
}

// The moon by phase (0..1 over the cycle, 0.5 full; waxing is lit on the right): the lit part inside a thin ring of ink,
// so a slim crescent still reads as a moon. A new moon keeps a sliver (cos 0.73, the carved set's floor).
function moon(phase) {
    let f = Number(phase);
    if (!isFinite(f))
        f = 0.5;
    f = f - Math.floor(f);
    const waxing = f <= 0.5;
    const c = Math.min(0.73, Math.cos(2 * Math.PI * f));
    const cx = 12, cy = 12, r = 7.3, R = 10.4, Ri = 9.3;
    const rx = (Math.abs(c) * r).toFixed(3);
    const outer = waxing ? 1 : 0;
    // the terminator from the foot back to the top: through the lit side for a crescent, through the dark side when gibbous
    const term = (c > 0) === waxing ? 0 : 1;
    const lit = "M " + cx + " " + (cy - r) + " A " + r + " " + r + " 0 0 " + outer + " " + cx + " " + (cy + r)
        + " A " + rx + " " + r + " 0 0 " + term + " " + cx + " " + (cy - r) + " Z ";
    const ring = "M " + cx + " " + (cy - R) + " A " + R + " " + R + " 0 1 1 " + cx + " " + (cy + R)
        + " A " + R + " " + R + " 0 1 1 " + cx + " " + (cy - R) + " Z "
        + "M " + cx + " " + (cy - Ri) + " A " + Ri + " " + Ri + " 0 1 0 " + cx + " " + (cy + Ri)
        + " A " + Ri + " " + Ri + " 0 1 0 " + cx + " " + (cy - Ri) + " Z ";
    return { ink: ring, accent: lit, token: "weatherMoon" };
}
