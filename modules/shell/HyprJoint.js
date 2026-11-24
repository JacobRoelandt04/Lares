.pragma library

// =============================================================================
// HyprJoint.js -- what `hyprctl -j getoption` says about the corners of Hyprland's windows, and the joint the bars draw to nest them,
// as pure functions. No Qt in here.
//
// THE JOINT. The corner where an island meets a side bar -- the joint a tiled window's rounded corner sits in -- is the
// field's fillet of `blendRadius`, the SAME fillet a popup makes with the bar it hangs from. A bar's presence ramps over 2 px
// (GooeyGeometry BAR_PRESENCE), so every joint of the shell is one circle of blendRadius (a ramp over 8 px would draw a 6 px outlet's
// joint at 16.875 of a blendRadius of 20, and a popup's at 20), and it is the window's: a Hyprland window with
// `decoration:rounding = r` and a border of b is drawn with an outline of radius (r + b) x Hyprland's scale in device px, about a centre
// that far inside the border's outer corner (14 + 3 at scale 1.25: a fitted 21.24 about (21.18, 21.18), rms 0.06 px, measured in the
// nested Hyprland 0.57; `decoration:rounding = 0` is a square corner whatever the border). The nest is not concentric (the window touches the side bar and stands `gaps_out` under the island): the window's outline is
// the joint's outline moved DOWN by gaps_out, the same circle, so the crescent between them is `gaps_out` thick measured straight down along
// the whole arc and tapers to nothing at the side bar. The fit is the RADII being equal, and the radius of a window's outline is rounding + border_size.
//
// THE SHELL'S OWN BORDER (shell.jsonc `border`, a ring OUTSIDE the surface) sits between the joint and the window: the ring's outer edge is the
// joint's arc offset by its width w, so the window's corner nests against a circle of radius (joint - w), concentric with the joint when the
// window touches the ring (Hyprland's gaps_out 0 with the bars reserving their border: HyprReserve) and the same circle moved down by
// gaps_out when it does not. The joint is therefore
//
//   joint = rounding + border_size + w         the radius of the joint on the glass, compositor px (w = the ring's width in compositor px)
//
// and it is one number in Hyprland's units -- the shell asks Hyprland for `rounding` and `border_size` (READ ONLY, `hyprctl -j getoption`, at start
// and when its config reloads: HyprJoint.qml; ShellConfig's `jointRounding` / `jointBorder` can name either) -- in COMPOSITOR px (the windows do not grow with the
// shell's scale, so neither does the joint):
//
//   outer = rounding + border_size                 the radius of a window's outline, px
//   blendRadius = (outer + overlap) / k + w        for a frame drawn k times larger, w the ring's width in the frame's px (it is drawn in them,
//                                                  on whole compositor px: ringWidth), overlap what THE OVERLAP (below) reaches into the window:
//                                                  0.34 x sqrt(outer) and never over half the border, 1.4 px at 14 + 3
//
// (The joint is drawn at the outline's own radius, never smaller. Read as COVERAGE -- a bare window's corner against the background -- the
// outline is 13.09, 17.11 and 23.13 px of equivalent radius for 10, 14 and 20 + 3: Hyprland's outline IS rounding + border_size, and a ring
// 0.5 px smaller than it would leave the background showing between the two along every arc, a gap that gets a bit wider around the curves.
// The best the two antialiased edges can do is the 0.2 px of background they bleed at the joint's own radius.)
//
// THE NUMBER FOR THE USER'S HYPRLAND. With `general:border_size = 3` and the shell's 3 px ring, Hyprland's rounding 14 makes a joint of 14 + 3 + 3
// and THE OVERLAP's 1.4: 21.4 at a frame of 1 (the laptop: shell scale 1.25 on Hyprland's 1.25) and 17.92 at a frame of 1.25 (the external
// screen: Hyprland's 1, the ring 4 compositor px). A frame that cannot ask Hyprland (a mock run, a mockup) assumes 14 and 3.
//
//   parseOption(text)                       one `hyprctl -j getoption <name>` answer -> { value, kind } | null
//                                           {"int": 14}, {"float": 2.000000}, {"css": "6 6 6 6"} (a list's first number), {"custom": "6"}
//   read(rounding, border, power, over)     the three answers' texts (or null) and the shell.jsonc overrides -> the numbers
//   blendFor(outer, frameScale, ring, border)   the blendRadius, in the frame's px, whose joint nests a window outline of `outer` behind a ring of
//                                           `ring` (overlapFor(outer, border) px past it along the arc: THE OVERLAP, below)
//   overlapFor(outer, border)               THE OVERLAP for an outline of `outer` whose border is `border` wide, compositor px
//   ringWidth(w, k)                         the ring's width on WHOLE compositor px (frame px): what the field draws and the reserve ends at
//   edgeFix(reserve, thick, ring, k, dpr, width, height, border)
//                                           per edge, the frame px the field draws that edge's bars thicker by so the ring ends on the DEVICE px
//                                           Hyprland draws the window's border from (THE DEVICE EDGE, below); 0 at every edge when dpr is 1
//   DEFAULT_ROUNDING, DEFAULT_BORDER        what the shell draws before it has asked: 14 and 3
//
// WHAT ELSE IN THE SHELL IS MEANT TO MATCH HYPRLAND:
//   the outlet bars' thickness, ShellLayout.SLIM = 6 compositor px, written in, not asked: the outlets RESERVE their own
//       room (6 + the border) and Hyprland's `general:gaps_out` is meant to be 0, so the window's gap to the island is `gaps_out` and nothing else.
//   `decoration:rounding_power` is read for the record: the joint is a circle (power 2, Hyprland's default and the user's), and a squircle
//       (3 and up) is not followed -- the field's fillet is a circle, so following one is the engine's work (a superellipse joint in
//       GooeyGeometry and the field shader), not a number here.
//   nothing else: the islands' and popups' corners (maxR) are the shell's own; the optional edge ring (shell.jsonc `border`, 3 px) is the waybar's inset, not
//   Hyprland's border; hyprlock's rounding (the lock's pill) meets no window.
// =============================================================================

var DEFAULT_ROUNDING = 14;
var DEFAULT_BORDER = 3;
var DEFAULT_POWER = 2;
// A number out of 0 .. MAX_PX is not a corner (a typo, an option that is not what it says): the default. ShellLayout.jointOf clamps shell.jsonc's to the same.
var MAX_PX = 64;

function _num(v) {
    if (typeof v === "number")
        return isFinite(v) ? v : null;
    if (typeof v === "string" && v.trim() !== "") {
        const n = Number(v);
        return isFinite(n) ? n : null;
    }
    return null;
}

// One `hyprctl -j getoption` answer. A value that is a list of CSS-style numbers is its first; a word that is no number ("no such option")
// is null. `kind` says which member it came from.
function parseOption(text) {
    if (typeof text !== "string")
        return null;
    let o = null;
    try {
        o = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (!o || typeof o !== "object")
        return null;
    for (const kind of ["int", "float"]) {
        if (o[kind] !== undefined) {
            const n = _num(o[kind]);
            return n === null ? null : { value: n, kind: kind };
        }
    }
    for (const kind of ["css", "custom", "str"]) {
        if (typeof o[kind] === "string") {
            const first = o[kind].trim().split(/\s+/)[0];
            const n = _num(first);
            return n === null ? null : { value: n, kind: kind };
        }
    }
    return null;
}

function _px(v, d) {
    const n = _num(v);
    return n !== null && n >= 0 && n <= MAX_PX ? n : d;
}

// The numbers from the texts of the three answers (null where hyprctl said nothing) and shell.jsonc's overrides ({ rounding, border }: a number
// wins over what Hyprland says, null or missing asks it). `read` is true when Hyprland told us at least one of the two numbers.
function read(rounding, border, power, over) {
    const r = parseOption(rounding), b = parseOption(border), p = parseOption(power);
    const o = over && typeof over === "object" ? over : {};
    const ov = x => (x === null || x === undefined ? null : _num(x));
    const orr = ov(o.rounding), ob = ov(o.border);
    const rounding_ = orr !== null && orr >= 0 && orr <= MAX_PX ? orr : _px(r ? r.value : null, DEFAULT_ROUNDING);
    const border_ = ob !== null && ob >= 0 && ob <= MAX_PX ? ob : _px(b ? b.value : null, DEFAULT_BORDER);
    const power_ = p && p.value > 0 && p.value <= 16 ? p.value : DEFAULT_POWER;
    return {
        rounding: rounding_,
        border: border_,
        power: power_,
        // a window with no rounding has SQUARE corners, border and all: there is no arc to nest, whatever the border's width
        outer: rounding_ > 0 ? rounding_ + border_ : 0,
        read: !!r || !!b
    };
}

// THE OVERLAP. Drawn at
// the window's own radius the joint's arc and the window's are ONE curve, and two antialiased edges on one curve do not sum to one: the shell
// (a layer above the window) covers a fraction a of an edge pixel, the window 1 - a under it, and a(1 - a) of the wallpaper shows through -- a
// quarter at worst, a dotted dark line round every corner. The shell is above the window, so the cure is the shell's edge reaching INTO the
// window's along the arc and nowhere else: the joint is drawn a little LARGER than the window's outline. Its arc keeps the window's tangent
// lines (the straights are untouched, on whole px as before) and lies inside the window's arc by (sqrt 2 - 1) x the overlap at 45 degrees,
// tapering to nothing at the straights.
//
// JUST ENOUGH. What the overlap buys is at the arc's two shallow ends, and what it costs is at its middle. The seam is worst where the
// window's arc has left its straight by half a device px (s = rho (1 - cos phi) = 0.5, at phi ~ 1 / sqrt(rho): 12 degrees for a radius of
// 21 device px), and there a joint v larger reaches only ~ v x phi = v / sqrt(rho) into the window; at 45 degrees it reaches 0.41 v, which
// is the window's BORDER under the shell's ring. So the overlap grows with the root of the radius -- OVERLAP_K x sqrt(outer) -- and no
// faster: 2.5 px (the number until round 8) laid the ring over 1.16 more of the border's 4 device px than no overlap does at the user's 14 + 3 on Hyprland's 1.25, a
// border visibly thinner round every corner where it is not the ring's colour (the user's active border is green).
// Measured in the nested Hyprland at 14 + 3 on Hyprland's scale 1.25, per ray through the corner, device px (tools/dev/shell_joint_probe.sh:
// the wallpaper's share is the difference of one state shot over black and over white, exact):
//     overlap   wallpaper, worst ray / mean     border left at the arc's middle (of 4; 3.9 with no shell)
//     0         0.23 / 0.112                    3.70
//     0.5       0.16 / 0.056                    3.57
//     1.4       0.085 / 0.015                   3.10     <- OVERLAP_K 0.34
//     2.5       0.03 / 0.004                    2.54
// At 1.4 no ray shows a tenth of a pixel of wallpaper (the worst single pixel is 13 % wallpaper, at the arc's ends where the two edges
// part), and the ring takes 0.6 device px of the border where 2.5 took 1.16. On Hyprland's scale 1 (the external screen) the same joint
// reads 0.11 px at worst and 2.36 of the border's 3.
// A THIN BORDER IS NOT SPENT ON THE SEAM: the overlap is never over OVERLAP_BORDER of the border's width (a 1 px border under a 1.4 px
// overlap showed 0.14 .. 0.34 of its pixel at the arc's middle: a border that stops at every corner). Half the border caps a 1 px border's
// overlap at 0.5 and a 2 px one's at 1; the user's 3 is not capped (1.5 > 1.4). The seam is then what a smaller overlap leaves (the table).
var OVERLAP_K = 0.34;
var OVERLAP_BORDER = 0.5;
function overlapFor(outer, border) {
    const o = _num(outer) === null ? 0 : outer;
    if (!(o > 0))
        return 0;
    const v = OVERLAP_K * Math.sqrt(o);
    const b = _num(border);
    return b !== null && b >= 0 ? Math.min(v, OVERLAP_BORDER * b) : v;
}

// The blendRadius, in the frame's px, of the joint that nests a window outline of radius `outer` (compositor px) behind a ring of `ring` frame px, in a
// frame drawn `frameScale` times larger: the field draws the joint as a circle of blendRadius in the frame's px, the frame magnifies it by
// frameScale, and the ring is drawn in the frame's px (it grows with the frame, so the window's side of it is `outer` on the glass), plus THE OVERLAP
// for a rounded window. Never below the ring (square windows: a joint as big as the ring is thick, no overlap -- a square corner has no arc to
// leave a seam on). At Hyprland's 14 + 3, a frame of 1 and a 3 px ring it is 21.4.
function blendFor(outer, frameScale, ring, border) {
    const k = Math.max(0.01, frameScale > 0 ? frameScale : 1);
    const w = ringWidth(ring, k);
    const o = Math.max(0, _num(outer) === null ? 0 : outer);
    return (o + overlapFor(o, border)) / k + w;
}

// THE RING ON WHOLE COMPOSITOR PIXELS.
// The ring is drawn in the frame's px and an exclusive zone is a whole number of compositor px, so a 3 px ring in a frame of 1.25 (3.75) behind a
// reserve of 10 leaves 0.25 px of background between the ring's edge and the window's border, straight along every edge. The ring is drawn as many
// WHOLE compositor px as the configured width is nearest to (3.75 -> 4, never under 1): every drawn edge of the shell is then a whole pixel and
// the reserve is exactly it. `w` is the configured width in the frame's px, `k` the frame's scale (compositor px per frame px); answers frame px.
function ringWidth(w, k) {
    if (!(_num(w) !== null && w > 0))
        return 0;
    const kk = Math.max(0.01, k > 0 ? k : 1);
    return Math.max(1, Math.round(w * kk)) / kk;
}

// THE DEVICE EDGE. An exclusive zone is whole COMPOSITOR px, and under Hyprland's own scale a compositor px is `dpr`
// device px: a reserve of 43 is 53.75 device px. Hyprland does not draw the window's border there: it ROUNDS the window's surface box to whole
// device px and draws the border round it, its thickness rounded too (CHyprBorderDecoration, renderBorder: std::round of each), so the border's
// outer edge is round((reserve + border) x dpr) - round(border x dpr) from the screen's edge. In the nested env, with 3 px borders:
// at 1.25 the top's 53.75 is drawn from 54 (round(57.5) - round(3.75)) and the sides' 11.25 from 11; at 1.5 the
// top's 55.5 from 55 (round(60) - round(4.5)) and the sides' 13.5 from 13. The shell's ring ends where the frame puts it: 53.75 at the top at
// 1.25 (a quarter px of background between it and the border), 54.5 at 1.5 (half a px). So each edge's bars are drawn `fix` frame
// px thicker (or thinner) than their own number, to end the ring exactly where Hyprland starts the window: the bar's FACE moves, nothing else (the
// reserve, the bars' rects, what hangs from them stay where they are). At dpr 1 every rounding is of a whole number and every fix is 0 (the ring
// is on whole compositor px: ringWidth). A fix is at most the reserve's own rounding: under a compositor px and the device px Hyprland's two roundings move it by (at 1.25:
// +0.25 device px at the top, -0.25 at the sides; at 1.5 +0.5 and -0.5); anything more is no edge of the shell's (a reserve that is not the bars'
// own) and is left.
//   reserve   { top, right, bottom, left }: the exclusive zones, compositor px (ShellLayout.windowReserve); 0 = no window rests on that edge
//   thick     { top, right, bottom, left }: the bars' own thickness on each edge (their reserve), frame px -- the ring is drawn outside it
//   ring      the ring's width, frame px (ringWidth); k the frame's scale (compositor px per frame px); dpr device px per compositor px
//   width, height   the screen in compositor px (the far edges are rounded where they stand: (width - reserve - border) x dpr)
//   border    Hyprland's `general:border_size`, compositor px (HyprJoint.qml's reading; DEFAULT_BORDER when it is not a number)
// Answers { top, right, bottom, left } in frame px.
function edgeFix(reserve, thick, ring, k, dpr, width, height, border) {
    const out = { top: 0, right: 0, bottom: 0, left: 0 };
    const kk = Math.max(0.01, k > 0 ? k : 1), d = dpr > 0 ? dpr : 1;
    const g = kk * d;
    const w = Math.max(0, _num(ring) === null ? 0 : ring);
    const r = reserve || {}, t = thick || {};
    const b = _num(border) !== null && border >= 0 ? border : DEFAULT_BORDER;
    const bd = Math.round(b * d);
    for (const e of ["top", "right", "bottom", "left"]) {
        const n = _num(r[e]);
        if (n === null || !(n > 0))
            continue;
        const far = e === "right" || e === "bottom";
        const size = _num(far ? (e === "right" ? width : height) : 0);
        if (far && !(size > 0))
            continue;
        // the device px Hyprland's border starts at, counted from this edge of the screen: the surface's edge rounded, less the border's
        // rounded thickness
        const dev = far ? Math.round(size * d) - (Math.round((size - n - b) * d) + bd) : Math.round((n + b) * d) - bd;
        const fix = dev / g - (Math.max(0, _num(t[e]) === null ? 0 : t[e]) + w);
        // the reserve's rounding only: a reserve that is not the bars' own (a thickness the host did not say) is no edge to meet
        out[e] = Math.abs(fix) * g > 1e-6 && Math.abs(fix) * g <= d + 0.5 + 1e-6 ? fix : 0;
    }
    return out;
}
