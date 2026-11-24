// =============================================================================
// Mix.js
//
// Linear interpolation between two colours by an eased fraction.
//
// This is how EVERY colour crossfade in the shell is done, and the reason is
// the theme. `Behavior on color` cannot tell a state change from the colour
// moving underneath it: under a live light/dark switch it sees the theme's
// crossfade as a stream of state changes and chases each one with a tail of
// its own, so whatever it paints arrives after everything else on screen --
// the stripe finishing a quarter-second after the card it sits in.
//
// Driving a FRACTION instead keeps both ends live. At rest the fraction is 0
// or 1 and the value IS one of the themed colours, so the theme reaches it
// with no clock in between; during a state change both endpoints are still
// themed colours, so a switch mid-transition stays in step too. One clock per
// motion, and the motion is the state change, not the colour.
//
// Not a `.pragma library`: `Qt.rgba` lives on the QML global object, which a
// shared library context does not have.
// =============================================================================

// `a` and `b` are colors, `f` is 0..1. Alpha is interpolated with the rest.
function c(a, b, f) {
    if (!(f > 0))
        return a;
    if (f >= 1)
        return b;
    return Qt.rgba(a.r + (b.r - a.r) * f,
                   a.g + (b.g - a.g) * f,
                   a.b + (b.b - a.b) * f,
                   a.a + (b.a - a.a) * f);
}

// Three-way: `rest` unless `f1` lifts it toward `c1`, and `f2` toward `c2` on
// top of that. Written out because the nested call reads badly inline, and
// because most of the shell's colour choices are exactly this shape -- a
// resting colour with one or two state overrides.
function c3(rest, c1, f1, c2, f2) {
    return c(c(rest, c1, f1), c2, f2);
}

// =============================================================================
// A GROUND-INDEPENDENT CARVE
//
// A carved box drawn in opaque colours only reads as carved on the ground its
// colours were picked against: on a darker ground (a highlighted row, an open
// tile) the same opaque fill is LIGHTER than what surrounds it and the groove
// turns into a light pill. So a box that sits on a ground that changes takes
// its colours as a TRANSLUCENT shade instead, with the alpha solved so that
// over the reference ground the result is exactly the opaque colour it
// replaces: `carve(listBox, panelSunk, shadowDeep)` is shadowDeep at the alpha
// that turns listBox into panelSunk. Over any other ground the same alpha
// darkens (or, with a light shade, lightens) by the same share of the way to
// the shade, so the depth goes wherever the ground goes.
// =============================================================================

// Relative luminance of a colour's channels (Rec. 709 weights, no gamma: the
// solve below only needs a monotone measure).
function lum(col) {
    return 0.2126 * col.r + 0.7152 * col.g + 0.0722 * col.b;
}

// The alpha at which `shade` over `ground` has the luminance of `target`,
// clamped to 0..1 (0 when the shade cannot move the ground at all).
function carveAlpha(ground, target, shade) {
    const d = lum(ground) - lum(shade);
    return Math.abs(d) < 1e-4 ? 0 : Math.max(0, Math.min(1, (lum(ground) - lum(target)) / d));
}

// `shade` at that alpha: the translucent stand-in for `target` over `ground`.
function carve(ground, target, shade) {
    return Qt.rgba(shade.r, shade.g, shade.b, carveAlpha(ground, target, shade));
}

// `src` composited over an opaque `dst` (straight alpha in, opaque out).
function over(src, dst) {
    const a = src.a;
    return Qt.rgba(src.r * a + dst.r * (1 - a), src.g * a + dst.g * (1 - a), src.b * a + dst.b * (1 - a), 1);
}

// The OPAQUE colour of `target`'s depth carved into `ground`: what
// carve(reference, target, shade) looks like over `ground`. Where a fill has
// to stay opaque (text sits on it, or a hue is mixed in after), this is the
// carve resolved against the ground the box really sits on.
function sunk(reference, target, shade, ground) {
    return over(carve(reference, target, shade), ground);
}
