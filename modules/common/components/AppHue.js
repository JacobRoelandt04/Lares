// =============================================================================
// AppHue.js
//
// What colour an app IS: sampled from its icon, once (IconColours.qml draws the icon small and hands the pixels to sample() below;
// the answer is kept here, per image source, for the whole session). One rule for every place that colours an app: screentime's rows,
// ribbon segments and focused bars.
//
// The rule: an icon's colour is its strongest colour; one with no colour at all (grey, white, black)
// takes the host's FALLBACK hue -- as much of it as the icon lacks hue of its own.
//
// Colours come in as QML colour values (r, g, b, a in 0..1). Pure arithmetic on those fields, so a shared library context will do.
// =============================================================================
.pragma library

function chroma(c) {
    return Math.max(c.r, c.g, c.b) - Math.min(c.r, c.g, c.b);
}

// How much of a colour is hue: 0 for grey / white / black, 1 from a chroma of 0.22.
function hueWeight(c) {
    return Math.max(0, Math.min(1, (chroma(c) - 0.06) / 0.16));
}

// How much of the fallback a colourless icon takes, given the plate's and the
// strongest colour's hue weights: as much hue as it lacks. No fallback
// (transparent) -> 0.
function fallbackWeight(hP, hS, fallback) {
    return fallback && fallback.a > 0 ? 1 - Math.max(hP, hS) : 0;
}

// The icon's colour where it has none of its own to give: its strongest, or
// the fallback when the fallback weighs more than the strongest's own hue.
function strongHue(strong, fallback, hS, fbW) {
    return fbW > hS ? fallback : strong;
}

// One app's colour from its sampled colour (null: the icon has none): the rule above in one call.
function appColour(strong, fallback) {
    if (!strong)
        return fallback;
    const hS = hueWeight(strong);
    return strongHue(strong, fallback, hS, fallbackWeight(hS, hS, fallback));
}

// ---- the sample -----------------------------------------------------------------------------------------------------------
// The icon's strongest colour from its pixels (RGBA bytes, any length): every pixel that is mostly opaque and has some chroma
// votes for the 30-degree hue bucket it falls in, with a weight of chroma squared times alpha (a saturated stroke outweighs a
// pale wash); the colour is the weighted mean of the winning bucket. null when nothing has chroma (a grey or white icon).
var MIN_CHROMA = 0.12;
function sample(d) {
    const sw = [], sr = [], sg = [], sb = [];
    for (let k = 0; k < 12; k++) { sw.push(0); sr.push(0); sg.push(0); sb.push(0); }
    for (let i = 0; i + 3 < d.length; i += 4) {
        const a = d[i + 3] / 255;
        if (a < 0.5)
            continue;
        const r = d[i] / 255, g = d[i + 1] / 255, b = d[i + 2] / 255;
        const mx = Math.max(r, g, b), mn = Math.min(r, g, b), c = mx - mn;
        if (c < MIN_CHROMA)
            continue;
        let h;
        if (mx === r)
            h = ((g - b) / c + 6) % 6;
        else if (mx === g)
            h = (b - r) / c + 2;
        else
            h = (r - g) / c + 4;
        const k = Math.min(11, Math.floor(h * 2));
        const w = c * c * a;
        sw[k] += w; sr[k] += r * w; sg[k] += g * w; sb[k] += b * w;
    }
    let best = -1;
    for (let k = 0; k < 12; k++)
        if (sw[k] > 0 && (best < 0 || sw[k] > sw[best]))
            best = k;
    if (best < 0)
        return null;
    return { r: sr[best] / sw[best], g: sg[best] / sw[best], b: sb[best] / sw[best], a: 1 };
}

// ---- what has been sampled, per image source, for the session ------------------------------------------------------------
var _seen = {};
function known(url) { return _seen[url] !== undefined; }
// a sampled colour, or null for an icon without one (known() tells the two apart from "not sampled yet")
function colourFor(url) { return _seen[url] === undefined ? null : _seen[url]; }
function remember(url, colour) { _seen[url] = colour; }

// A stable index in [0, n) for a string (FNV-1a): an app with no desktop entry
// and no bake still gets the same palette hue in every session.
function hashIndex(s, n) {
    let h = 0x811c9dc5;
    const str = String(s);
    for (let i = 0; i < str.length; i++) {
        h ^= str.charCodeAt(i);
        h = Math.imul(h, 0x01000193) >>> 0;
    }
    return n > 0 ? h % n : 0;
}
