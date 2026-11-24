.pragma library

// =============================================================================
// WeatherGlyphParts.js
//
// kind -> the parts of a carved weather glyph. Pure: numbers in, an array of
// numbers out, nothing themed (the shader resolves every colour from a colour
// INDEX, so a composition never carries a colour that a theme switch would
// have to re-evaluate).
//
// A part is eight numbers, the two vec4 uniforms the shader takes for it:
//
//     [type, cx, cy, s,   p1, p2, p3, colour]
//
// in the unit square (y down) that WeatherGlyph's `size` scales. Types and
// colours are the shader's (shaders/weather_glyph.frag). Slot 0 is the BACK; a
// cloud that hides a sun comes after the sun. At most `maxParts`.
//
// The shapes and colours follow three reference sets (set1-3): the classic flat-bottomed cloud, WHITE
// in front with a GREY one of its own shape behind when the sky is heavy; the
// sun a saturated disc on a serrated crown; a fat crescent with five-pointed
// stars; the sun or moon peeking out from behind the cloud's top-right;
// teardrops of varied size for rain and slanted streaks for heavy rain; an
// amber zigzag bolt coming out from BEHIND the cloud between the drops;
// six-armed flakes; staggered rounded bars for fog; lines ending in curls for
// wind. Precipitation is scattered, never set out in level rows.
//
// SMALL GLYPHS. Below `smallPx` device pixels (the hourly strip's and daily
// list's 24 px) every precipitation part is drawn LARGER and there are fewer
// of them, the crown has fewer and longer points, the stars shrink to one and
// flakes lose their side branches: at 24 px a drop must stay a drop (3.6 px
// wide), not a speck, and drizzle / rain / heavy rain must still be three
// different pictures (two small drops / three drops / a grey sky and streaks).
// Night condition glyphs draw the references' crescent whatever the phase: the
// glyph says "night"; the `moon` part is the one that shows the phase (the
// sun-and-moon card, the moon tile), and a full moon in a condition glyph
// would read as a sun.
//
// SPACING. Every part draws a light rim OUTSIDE its edge (WeatherGlyph's
// `bevelWidth` device pixels plus the half-pixel seam feather), fixed in DEVICE
// pixels whatever the glyph's size, so two parts that come close fuse their
// rims into a light bridge, which reads as parts that almost overlap. So:
//   - SEPARATE objects (drops, streaks, flakes, pellets, the bolt among them;
//     stars, against everything; fog bars that share a row) keep two rims plus
//     half a pixel of clear ground between their edges: 4 px at the default
//     bevel;
//   - STACKED strokes (fog rows, wind lines) and a particle under its cloud keep
//     one rim: their rims may meet, but no rim lies on another part's body;
//   - LAYERED parts (the clouds, the sun's crown and disc, a sun or moon behind
//     a cloud, the bolt behind it) overlap by design.
// The rim is fixed in pixels and the layout in the unit square, so the rule
// binds at the SMALLEST size a composition is drawn at: 24 px for the small
// set, `smallPx` for the big one. Every composition keeps it at every device
// size from 24 to 160 px.
// =============================================================================

var T = { DISC: 0, CAPSULE: 1, CLOUD: 2, CROWN: 3, MOON: 4, DROP: 5, FLAKE: 6, BOLT: 7, CURL: 8,
          STAR: 9, CRESCENT: 10, ARROW: 11 };
var C = { SUN_DISC: 0, SUN_CROWN: 1, MOON: 2, STAR: 3, CLOUD: 4, CLOUD_BACK: 5, DROP: 6, FLAKE: 7,
          HAIL: 8, BOLT: 9, FOG: 10, WIND: 11 };

// The shader's slots. The fullest composition (a shower's crown and disc, the
// cloud and five drops) uses all eight; the slice at the end of compose() is a
// guard, no composition reaches it.
var maxParts = 8;

// Below this many DEVICE pixels the composition simplifies: the hourly strip,
// the daily list and the detail's strip draw at 24-26 px, the moon tile at 32
// (the moon part has no small form). 48 is where the big set's five drops,
// four flakes and four pellets first keep 4 px between them (SPACING above);
// between 40 and 48 they could not, and only a magnified mockup stage draws a
// condition glyph there.
var smallPx = 48;
// A flake whose arm is at least this many device pixels long grows side
// branches; a shorter arm has no room for them and reads as a blot.
var branchArmPx = 10;

// A thin feature is never thinner than this many device pixels across, or at
// 24 px a streak is a hair. Applied to radii, so half. A flake's six arms meet
// in the middle and read as a blot at that weight, so they take a finer floor.
var minThicknessPx = 2.2;
var minFlakeArmPx = 1.7;

function minRadius(r, devSize, floorPx) {
    return Math.max(r, 0.5 * (floorPx === undefined ? minThicknessPx : floorPx) / Math.max(devSize, 1));
}

function disc(cx, cy, r, colour) { return [T.DISC, cx, cy, r, 0, 0, 0, colour]; }
function capsule(ax, ay, bx, by, r, colour) { return [T.CAPSULE, ax, ay, r, bx, by, 0, colour]; }
// The grey cloud behind is the shader's second model (p1 = 1), so it is never
// the white one again.
function cloud(cx, cy, w, colour) {
    return [T.CLOUD, cx, cy, w, colour === C.CLOUD_BACK ? 1 : 0, 0, 0, colour];
}
function moon(cx, cy, r, phase) { return [T.MOON, cx, cy, r, clampPhase(phase), 0, 0, C.MOON]; }
function crescent(cx, cy, r, side) { return [T.CRESCENT, cx, cy, r, side, 0, 0, C.MOON]; }
function star(cx, cy, r) { return [T.STAR, cx, cy, r, 0, 0, 0, C.STAR]; }
function drop(cx, cy, w) { return [T.DROP, cx, cy, w, 0, 0, 0, C.DROP]; }
function flake(cx, cy, len, devSize) {
    return [T.FLAKE, cx, cy, len, devSize * len >= branchArmPx ? 0.36 : 0,
            minRadius(0.08 * len, devSize, minFlakeArmPx), 0, C.FLAKE];
}
function pellet(cx, cy, r) { return [T.DISC, cx, cy, r, 0, 0, 0, C.HAIL]; }
function bolt(cx, cy, h) { return [T.BOLT, cx, cy, h, 0, 0, 0, C.BOLT]; }
function curl(ax, ay, bx, by, r, R) { return [T.CURL, ax, ay, r, bx, by, R, C.WIND]; }
function arrow(cx, cy, s, angle) { return [T.ARROW, cx, cy, s, angle, 0, 0, C.WIND]; }

// The sun: a crown of points with the disc on it. Small suns take fewer, longer
// points so the serration survives 24 px.
function sun(cx, cy, R, devSize) {
    var small = devSize < smallPx;
    return [
        [T.CROWN, cx, cy, R, (small ? 0.70 : 0.80) * R, small ? 8 : 12, 0, C.SUN_CROWN],
        disc(cx, cy, (small ? 0.58 : 0.68) * R, C.SUN_DISC)
    ];
}

// The lit part of a disc vanishes at new moon; keep at least a slim crescent
// (cos(2 pi 0.12) = 0.73: the crescent is 0.27 r wide at its widest).
function clampPhase(f) {
    var p = f - Math.floor(f);
    return Math.min(0.88, Math.max(0.12, p));
}

// ---- skies ------------------------------------------------------------------
//
// Every precipitating glyph's front cloud has its foot in the same place, so
// the precipitation below it lines up from one kind to the next; what sits
// behind its top-right (nothing, a grey cloud, the sun, the moon) is the sky. A
// small glyph's cloud is a little smaller and its sun, moon and back cloud are
// larger, or they are a few pixels of colour at 24 px.
//
// A SMALL HEAVY SKY is posed differently. Behind a full-width front cloud the
// grey one shows only the strip of its outline that runs parallel to the
// front cloud's top-right -- dome, shallow saddle, bump -- and at 24 px that
// strip is a tilted grey pill, not a cloud. So under a small heavy sky the front
// cloud is narrower (its foot unchanged) and the back cloud stands clear of its
// shoulder, whole domes showing.
//
// The feet sit at 0.641 (big) and 0.632 (small): high enough that the scattered
// precipitation below keeps a rim's distance from the cloud (SPACING).
//
//                 front cloud (cx, cy, width)  front, heavy sky      back cloud          sun (R)             moon (r)
var skyBig =   { cloud: [0.46, 0.37, 0.86], heavy: [0.46, 0.37, 0.86], back: [0.66, 0.20, 0.56], sun: [0.72, 0.24, 0.22], moon: [0.72, 0.24, 0.21] };
var skySmall = { cloud: [0.44, 0.38, 0.80], heavy: [0.38, 0.41, 0.70], back: [0.68, 0.22, 0.60], sun: [0.72, 0.26, 0.25], moon: [0.73, 0.25, 0.24] };

// behind: "none" | "back" | "sun" | "moon". `under` goes between the sky and
// the front cloud: the bolt, which comes out from behind the cloud.
function sky(behind, devSize, under) {
    var k = devSize < smallPx ? skySmall : skyBig;
    var out = [];
    var front = k.cloud;
    if (behind === "back") {
        out.push(cloud(k.back[0], k.back[1], k.back[2], C.CLOUD_BACK));
        front = k.heavy;
    } else if (behind === "sun") {
        out = out.concat(sun(k.sun[0], k.sun[1], k.sun[2], devSize));
    } else if (behind === "moon") {
        out.push(crescent(k.moon[0], k.moon[1], k.moon[2], -1));
    }
    if (under) out.push(under);
    out.push(cloud(front[0], front[1], front[2], C.CLOUD));
    return out;
}

// What is behind the cloud: the peeking sun or moon for a shower, else a grey
// cloud for a heavy sky.
function behindFor(shower, night, heavy) {
    if (shower) return night ? "moon" : "sun";
    return heavy ? "back" : "none";
}

// ---- precipitation ------------------------------------------------------------
//
// Below the cloud's foot, scattered: no two particles on one level, no even
// pitch, sizes varied as in set3. Every position here is held to SPACING at the
// set's smallest size (24 px small, `smallPx` big).

function drops(intensity, small) {
    if (small) {
        if (intensity <= 0)
            return [drop(0.27, 0.86, 0.14), drop(0.60, 0.895, 0.14)];
        return [drop(0.12, 0.875, 0.155), drop(0.445, 0.90, 0.155), drop(0.77, 0.865, 0.155)];
    }
    if (intensity <= 0)
        return [drop(0.28, 0.80, 0.09), drop(0.48, 0.865, 0.09), drop(0.68, 0.815, 0.085)];
    return [drop(0.18, 0.785, 0.105), drop(0.485, 0.815, 0.115), drop(0.80, 0.78, 0.10),
            drop(0.33, 0.935, 0.09), drop(0.655, 0.93, 0.09)];
}

// A slanted streak, 0.28 across per unit down, placed by where its LINE
// crosses y 0.8: streaks of different lengths then stay evenly apart however
// their ends are staggered.
function streak(xAt08, top, bottom, r) {
    var y0 = top + r, y1 = bottom - r;
    return capsule(xAt08 + 0.28 * (0.8 - y0), y0, xAt08 - 0.28 * (y1 - 0.8), y1, r, C.DROP);
}

// Streaks of uneven length (set3's heavy rain): [x at y 0.8, top, bottom].
function streaks(small, devSize) {
    var r = minRadius(small ? 0.045 : 0.026, devSize);
    var s = small ? [[0.19, 0.71, 0.935], [0.46, 0.725, 0.97], [0.73, 0.715, 0.945]]
                  : [[0.21, 0.69, 0.955], [0.355, 0.73, 0.885], [0.50, 0.695, 0.965], [0.645, 0.725, 0.90], [0.79, 0.70, 0.945]];
    var out = [];
    for (var i = 0; i < s.length; i++)
        out.push(streak(s[i][0], s[i][1], s[i][2], r));
    return out;
}

function flakes(intensity, small, devSize) {
    if (small) {
        // Fewer, bigger flakes: six arms over 3 px long still leave gaps
        // between them at 24 px.
        if (intensity <= 0) return [flake(0.45, 0.848, 0.14, devSize)];
        if (intensity === 1) return [flake(0.235, 0.843, 0.135, devSize), flake(0.66, 0.852, 0.135, devSize)];
        return [flake(0.12, 0.84, 0.11, devSize), flake(0.49, 0.855, 0.11, devSize), flake(0.86, 0.835, 0.11, devSize)];
    }
    // Big flakes and small ones, as in set3: a big one grows branches once its
    // arm has the room (88 px), a small one stays a plain six-armed star.
    if (intensity <= 0)
        return [flake(0.33, 0.84, 0.12, devSize), flake(0.62, 0.775, 0.065, devSize)];
    if (intensity === 1)
        return [flake(0.19, 0.835, 0.12, devSize), flake(0.465, 0.77, 0.065, devSize), flake(0.74, 0.86, 0.12, devSize)];
    return [flake(0.095, 0.745, 0.06, devSize), flake(0.33, 0.865, 0.115, devSize),
            flake(0.575, 0.785, 0.06, devSize), flake(0.815, 0.835, 0.115, devSize)];
}

function sleetParts(intensity, small, devSize) {
    if (small)
        return [drop(0.24, 0.885, 0.155), flake(0.63, 0.845, 0.125, devSize)];
    if (intensity <= 1)
        return [drop(0.30, 0.855, 0.11), flake(0.61, 0.83, 0.09, devSize)];
    return [drop(0.20, 0.82, 0.10), flake(0.43, 0.875, 0.08, devSize),
            drop(0.65, 0.845, 0.10), flake(0.85, 0.865, 0.065, devSize)];
}

function pellets(withBolt, small) {
    if (small)
        return withBolt ? [pellet(0.11, 0.855, 0.08), pellet(0.88, 0.885, 0.08)]
                        : [pellet(0.13, 0.80, 0.08), pellet(0.46, 0.885, 0.08), pellet(0.785, 0.815, 0.08)];
    return withBolt ? [pellet(0.20, 0.80, 0.055), pellet(0.79, 0.795, 0.055), pellet(0.645, 0.935, 0.04)]
                    : [pellet(0.23, 0.785, 0.055), pellet(0.53, 0.845, 0.06), pellet(0.77, 0.795, 0.05),
                       pellet(0.36, 0.935, 0.035)];
}

// The bolt comes out from BEHIND the cloud's belly, its visible zigzag
// centred under the glyph.
function stormBolt(small) {
    return small ? bolt(0.52, 0.78, 0.42) : bolt(0.50, 0.77, 0.40);
}

// ---- fog and wind -------------------------------------------------------------

// Staggered rounded bars, some rows split in two (set3). Rows are stacked
// strokes; the two halves of a split row are separate bars (SPACING).
function fogBars(devSize) {
    if (devSize < smallPx) {
        var rs = minRadius(0.05, devSize);
        return [
            capsule(0.26, 0.23, 0.74, 0.23, rs, C.FOG),
            capsule(0.10, 0.41, 0.20, 0.41, rs, C.FOG),
            capsule(0.48, 0.41, 0.90, 0.41, rs, C.FOG),
            capsule(0.12, 0.59, 0.64, 0.59, rs, C.FOG),
            capsule(0.28, 0.77, 0.78, 0.77, rs, C.FOG)
        ];
    }
    var r = minRadius(0.04, devSize);
    return [
        capsule(0.28, 0.20, 0.72, 0.20, r, C.FOG),
        capsule(0.10, 0.35, 0.20, 0.35, r, C.FOG),
        capsule(0.38, 0.35, 0.90, 0.35, r, C.FOG),
        capsule(0.22, 0.50, 0.80, 0.50, r, C.FOG),
        capsule(0.10, 0.65, 0.60, 0.65, r, C.FOG),
        capsule(0.78, 0.65, 0.90, 0.65, r, C.FOG),
        capsule(0.28, 0.80, 0.72, 0.80, r, C.FOG)
    ];
}

// Three lines ending in curls: the top and middle curl up, the bottom one down.
function windCurls(devSize) {
    var r = minRadius(devSize < smallPx ? 0.05 : 0.036, devSize);
    return [
        curl(0.15, 0.35, 0.42, 0.35, r, -0.085),
        curl(0.06, 0.53, 0.80, 0.53, r, -0.125),
        curl(0.28, 0.71, 0.60, 0.71, r, 0.11)
    ];
}

// ---- compositions -----------------------------------------------------------

function compose(kind, intensity, night, shower, moonPhase, direction, devSize) {
    var small = devSize < smallPx;
    var parts = [];
    switch (kind) {
    case "clear":
        if (!night) {
            parts = sun(0.5, 0.5, 0.46, devSize);
        } else if (small) {
            parts.push(crescent(0.385, 0.62, 0.37, 1));
            parts.push(star(0.86, 0.14, 0.13));
        } else {
            parts.push(crescent(0.40, 0.61, 0.37, 1));
            parts.push(star(0.715, 0.175, 0.075));
            parts.push(star(0.875, 0.365, 0.11));
            parts.push(star(0.695, 0.63, 0.07));
        }
        break;
    case "sun":
        parts = sun(0.5, 0.5, 0.46, devSize);
        break;
    case "moon":
        parts.push(moon(0.50, 0.50, 0.40, moonPhase));
        break;
    case "partly":
        // The sun or moon low behind the cloud's shoulder, part of it.
        if (small) {
            if (night) parts.push(crescent(0.66, 0.37, 0.31, -1));
            else parts = sun(0.64, 0.40, 0.34, devSize);
            parts.push(cloud(0.42, 0.66, 0.78, C.CLOUD));
        } else {
            if (night) {
                parts.push(crescent(0.67, 0.37, 0.27, -1));
                parts.push(star(0.24, 0.24, 0.075));
            } else {
                parts = sun(0.66, 0.38, 0.29, devSize);
            }
            parts.push(cloud(0.46, 0.64, 0.88, C.CLOUD));
        }
        break;
    case "cloudy":
        // The grey cloud low behind the white one's shoulder, the two one
        // mass; its own model, so it is not the white one again.
        if (small) {
            parts.push(cloud(0.63, 0.35, 0.68, C.CLOUD_BACK));
            parts.push(cloud(0.40, 0.68, 0.76, C.CLOUD));
        } else {
            parts.push(cloud(0.66, 0.43, 0.62, C.CLOUD_BACK));
            parts.push(cloud(0.46, 0.64, 0.88, C.CLOUD));
        }
        break;
    case "cloud":
        parts.push(cloud(0.50, 0.50, 0.96, C.CLOUD));
        break;
    case "fog":
    case "fogbank":
        parts = fogBars(devSize);
        break;
    case "rain":
        parts = sky(behindFor(shower, night, intensity >= 2), devSize);
        parts = parts.concat(intensity >= 2 ? streaks(small, devSize) : drops(intensity, small));
        break;
    case "sleet":
        parts = sky(behindFor(shower, night, intensity >= 2), devSize);
        parts = parts.concat(sleetParts(intensity, small, devSize));
        break;
    case "snow":
        parts = sky(behindFor(shower, night, intensity >= 2), devSize);
        parts = parts.concat(flakes(intensity, small, devSize));
        break;
    case "hail":
        parts = sky(behindFor(shower, night, true), devSize, intensity >= 2 ? stormBolt(small) : null);
        parts = parts.concat(pellets(intensity >= 2, small));
        break;
    case "thunder":
        parts = sky(behindFor(shower, night, true), devSize, stormBolt(small));
        if (small) {
            parts.push(drop(0.125, 0.875, 0.15));
            if (intensity >= 2) parts.push(drop(0.87, 0.895, 0.15));
        } else {
            if (intensity >= 2) {
                // A heavy storm: streaks either side of the bolt.
                var sr = minRadius(0.026, devSize);
                parts.push(streak(0.067, 0.745, 0.875, sr));
                parts.push(streak(0.212, 0.70, 0.955, sr));
                parts.push(streak(0.741, 0.75, 0.96, sr));
                parts.push(streak(0.886, 0.745, 0.88, sr));
            } else {
                parts.push(drop(0.20, 0.835, 0.10));
                parts.push(drop(0.82, 0.87, 0.09));
            }
        }
        break;
    case "wind":
        parts = windCurls(devSize);
        break;
    case "arrow":
        if (typeof direction === "number" && isFinite(direction))
            parts.push(arrow(0.5, 0.5, 0.40, direction + 180));
        else
            parts.push(disc(0.5, 0.5, small ? 0.13 : 0.10, C.WIND));
        break;
    case "drop":
        parts.push(drop(0.50, 0.63, 0.40));
        break;
    case "flake":
        parts.push(flake(0.50, 0.50, 0.42, devSize));
        break;
    case "bolt":
        parts.push(bolt(0.50, 0.50, 0.88));
        break;
    default:
        parts.push(cloud(0.50, 0.50, 0.96, C.CLOUD));
        break;
    }
    return parts.slice(0, maxParts);
}
