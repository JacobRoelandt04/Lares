.pragma library
.import "../bar/gooey/GooeyGeometry.js" as Geo

// =============================================================================
// FlourishPose.js -- where the confirm flourish is at every moment, with no Qt
// in it: ConfirmFlourish asks it for a pose, hands the pose's box and corners
// to the engine's flourish slot and the pose itself to FlourishFace, which
// draws it. One pose per frame, one object: the body and the face read the
// same generation (CLAUDE.md).
//
// Every phase is a function of its own fraction (0..1, eased here with the
// engine's easings, Geo.ease) between a pose it STARTS from -- captured when
// it begins, so a skip ahead starts from wherever the flourish is -- and one
// it ends on:
//
//   lift     row -> the card at the launcher's face: the row's box compacts
//            into the card (the face's morph, m, rides this fraction: icon
//            from the row's left to centre-top, title from beside it to
//            below it, centred), its corners the card's and its foot still
//            neckInset inside the launcher's free face at the end. The box's
//            far side travels on m and its SHAPE leads (the card's height by
//            mid-lift), and in the card the title drops below the icon's line
//            before either moves across (LIFT_* below): on one straight lerp
//            the title slid through the icon and out of the box's growing foot
//   rise     the THROW's way up: to the apex (restPose: out of the launcher and well clear of it); the icon grows ip0 -> ip1 and the card with it, the FOOT moving (a growth that
//            moved the centre would bring the foot back to the launcher). The NECK (neck() below) is
//            drawn between the card and the launcher while the card is PULLED out (it speeds up, as a
//            pulled strand does), snaps at detachFrac of the travel, and from there the card flies
//            free, slowed by gravity to zero speed AT the apex (riseE)
//   fall     the way down, the same gravity: from the apex, where the card has no speed at all, to the
//            launcher's anchor, down on a quadratic (it speeds up all the way) and across at a constant
//            pace; while it falls the card closes round the icon's centre into a circle (the icon and the
//            title stay where they are: the outline culls the title, with a feather that is widest
//            halfway and gone at either end; what a circle round the icon still holds of the title's
//            tallest glyphs fades over the ball's last part) -- the ball's foot touches the bar's face
//            at the end. There is NO REST between the two: the moment of zero momentum at the apex, as when a ball is
//            thrown upwards, is the visual clarity a pause would try to create. One parabola, one gravity (throwOf). The card stays whole while it hangs at the apex (the
//            ball starts a share of the way into the fall): the hang is when it is read
//   sink     into the bar, shrinking; the flourish closes when its top is a
//            merge radius under the face (from there it changes no pixel)
//
// Coordinates: the engine's (px). `u` runs along the bar, `v` out of it from
// its free face (positive away from the bar), whatever edge the bar is on;
// the card's content is laid out on the screen's axes (the icon above the
// title) on every edge.
//
// A pose: { box {x0,y0,x1,y1}, radii [[rx,ry] x4 (tl,tr,br,bl)], ip (icon
// px), icon {x,y} (its top-left), title {x,y} (the title's top-left), m (the
// face's morph), feather (the outline's cull feather, px), titleA (the
// title's presence), wellBox (the row's box WHOLE while it lifts: where the
// face draws the fading well and marks -- `box` is cut to the list's
// viewport, see rowPose) }.
// =============================================================================

function lerp(a, b, t) {
    return a + (b - a) * t;
}

function clamp01(x) {
    return Math.max(0, Math.min(1, x));
}

function smooth(e0, e1, x) {
    const t = clamp01((x - e0) / (e1 - e0));
    return t * t * (3 - 2 * t);
}

function ease(index, t, overshoot) {
    return Geo.ease(Math.round(index), clamp01(t), overshoot);
}

// ---- The throw's own curve --------------------------------------------------------------------------
// The rise's eased fraction e (0 at the launcher's face, 1 at the apex) at the fraction f of its clock: PULLED, then FREE.
//   f <= a   the strand pulls the card out at a growing pace, e = f^2 / a, so the thread thins the way a pulled strand does,
//            slowly and then all at once; a is detachFrac, and the pinch is exactly the end of it (the travel there is a)
//   f > a    the strand has snapped, the card flies free under gravity: e = a + 2 (f - a) - (f - a)^2 / (1 - a), which
//            leaves the pinch at the speed the pull reached (2 per unit f on both sides: no jump) and slows at a constant
//            rate to ZERO speed at f = 1 -- the apex -- where it has also come exactly to e = 1. That agreement is why the
//            pull's share IS detachFrac: there is no separate stretch share, no sag past the rest and no easing index.
function riseE(ctx, f) {
    const a = Math.max(0.05, Math.min(0.95, ctx.dims.detachFrac));
    if (f <= a)
        return f * f / a;
    const w = f - a;
    return a + 2 * w - w * w / (1 - a);
}

// ---- The bar's axes ---------------------------------------------------------------------------
// axis { edge, face }: the bar's edge and its free face (engine px on the
// normal's screen axis).
function vertical(axis) {
    return axis.edge === "top" || axis.edge === "bottom";
}

// (u, v) -> engine x, y.
function toXY(axis, u, v) {
    switch (axis.edge) {
    case "top":
        return { x: u, y: axis.face + v };
    case "left":
        return { x: axis.face + v, y: u };
    case "right":
        return { x: axis.face - v, y: u };
    default:
        return { x: u, y: axis.face - v };
    }
}

function toUV(axis, x, y) {
    switch (axis.edge) {
    case "top":
        return { u: x, v: y - axis.face };
    case "left":
        return { u: y, v: x - axis.face };
    case "right":
        return { u: y, v: axis.face - x };
    default:
        return { u: x, v: axis.face - y };
    }
}

// The box of screen size w x h whose centre along the bar is cu and whose
// FOOT (the side facing the bar) is footV out of it.
function boxAt(axis, cu, footV, w, h) {
    switch (axis.edge) {
    case "top":
        return { x0: cu - w / 2, y0: axis.face + footV, x1: cu + w / 2, y1: axis.face + footV + h };
    case "left":
        return { x0: axis.face + footV, y0: cu - h / 2, x1: axis.face + footV + w, y1: cu + h / 2 };
    case "right":
        return { x0: axis.face - footV - w, y0: cu - h / 2, x1: axis.face - footV, y1: cu + h / 2 };
    default:
        return { x0: cu - w / 2, y0: axis.face - footV - h, x1: cu + w / 2, y1: axis.face - footV };
    }
}

// A box's foot (its side facing the bar), v.
function footOf(axis, b) {
    switch (axis.edge) {
    case "top":
        return b.y0 - axis.face;
    case "left":
        return b.x0 - axis.face;
    case "right":
        return axis.face - b.x1;
    default:
        return axis.face - b.y1;
    }
}

// Its extent along the normal.
function outExtent(axis, b) {
    return vertical(axis) ? b.y1 - b.y0 : b.x1 - b.x0;
}

function lerpBox(a, b, t) {
    return { x0: lerp(a.x0, b.x0, t), y0: lerp(a.y0, b.y0, t), x1: lerp(a.x1, b.x1, t), y1: lerp(a.y1, b.y1, t) };
}

function radiiAll(r) {
    return [[r, r], [r, r], [r, r], [r, r]];
}

function lerpRadii(a, b, t) {
    const out = [];
    for (let i = 0; i < 4; i++)
        out.push([lerp(a[i][0], b[i][0], t), lerp(a[i][1], b[i][1], t)]);
    return out;
}

function lerpPt(a, b, t) {
    return { x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t) };
}

// ---- The card -----------------------------------------------------------------------------------
// ctx.dims: { ip0, ip1, pad, titleGap, titleW, titleH, radius, slack,
// wellRadius, rowIcon {x,y}, rowTitle {x,y}, neckInset, restClear,
// ballMargin, bevelPx, sinkShrink, mergeK, cullFeather, and the
// neck's: detachFrac, qStart, qPinch, rUFrac, rLFrac, kA, kB, kMid, kJoin }.
function cardW(d, ip) {
    return Math.max(d.titleW, ip) + 2 * d.pad;
}

function cardH(d, ip) {
    return d.pad + ip + d.titleGap + d.titleH + d.pad;
}

// The card's content on the screen's axes: the icon centred at the top, the
// title centred under it.
function contentOf(d, b, ip) {
    const cx = (b.x0 + b.x1) / 2;
    return {
        icon: { x: cx - ip / 2, y: b.y0 + d.pad },
        title: { x: cx - d.titleW / 2, y: b.y0 + d.pad + ip + d.titleGap }
    };
}

// The ball's radius round an icon of `ip`: the plate's rounded-square corner
// reaches 0.616 ip from its centre (plateRadius 0.22), its lit rim bevelPx
// past that, and a margin of surface.
function ballR(d, ip) {
    return Math.ceil(0.616 * ip + d.bevelPx + d.ballMargin);
}

// ---- The poses a flourish passes through (all from ctx, fixed at the capture) -------------------
// ctx: { axis, row {x0,y0,x1,y1}, view {x0,y0,x1,y1} (the list's viewport:
// its clip), hostV (the launcher's free face, v), screenCentreV, farV (what
// stands across from the bar, v: restPose), anchorU, dims }.
//
// The row's box: its cell grown by the well's slack -- and CUT to the list's
// viewport, `whole` aside. A row the list's clip shows only in part is the
// flourish only where it is shown (the growing box reveals the rest as it
// lifts; drawn whole it would put the hidden half over the header on the first
// frame). A cut side is square (the clip it stands for is) and lies one
// device pixel past the viewport's edge: the content clip's feather runs a
// pixel inward from half a pixel inside the outline, so its first full row
// is the scissor's first row and its last empty one the scissor's first
// hidden one (bar_structure.md, the content clip).
function rowBox(ctx, whole) {
    const d = ctx.dims, r = ctx.row, v = ctx.view;
    const b = { x0: r.x0 - d.slack, y0: r.y0 - d.slack, x1: r.x1 + d.slack, y1: r.y1 + d.slack };
    const radii = radiiAll(d.wellRadius + d.slack);
    if (whole || !v)
        return { box: b, radii: radii };
    const px = d.px || 1;
    // Sides x0, y0, x1, y1; the corners tl, tr, br, bl each touch two.
    const cut = [b.x0 < v.x0 - 0.01, b.y0 < v.y0 - 0.01, b.x1 > v.x1 + 0.01, b.y1 > v.y1 + 0.01];
    if (cut[0])
        b.x0 = v.x0 - px;
    if (cut[1])
        b.y0 = v.y0 - px;
    if (cut[2])
        b.x1 = v.x1 + px;
    if (cut[3])
        b.y1 = v.y1 + px;
    const touch = [[0, 1], [2, 1], [2, 3], [0, 3]];
    for (let i = 0; i < 4; i++)
        if (cut[touch[i][0]] || cut[touch[i][1]])
            radii[i] = [0, 0];
    return { box: b, radii: radii };
}

function rowPose(ctx, whole) {
    const d = ctx.dims, r = ctx.row;
    const rb = rowBox(ctx, whole);
    return {
        box: rb.box,
        radii: rb.radii,
        ip: d.ip0,
        icon: { x: r.x0 + d.rowIcon.x, y: r.y0 + d.rowIcon.y },
        title: { x: r.x0 + d.rowTitle.x, y: r.y0 + d.rowTitle.y },
        m: 0,
        feather: 0,
        titleA: 1,
        wellBox: rowBox(ctx, true).box
    };
}

function rowCentreU(ctx) {
    const r = ctx.row;
    return vertical(ctx.axis) ? (r.x0 + r.x1) / 2 : (r.y0 + r.y1) / 2;
}

// The card at the launcher's face, its foot at footV (v): the lift's end and
// the rise's start.
function cardAt(ctx, footV) {
    const d = ctx.dims;
    const b = boxAt(ctx.axis, rowCentreU(ctx), footV, cardW(d, d.ip0), cardH(d, d.ip0));
    const c = contentOf(d, b, d.ip0);
    return {
        box: b,
        radii: radiiAll(d.radius),
        ip: d.ip0,
        icon: c.icon,
        title: c.title,
        m: 1,
        feather: 0,
        titleA: 1
    };
}

// Where the lift ends and the rise starts: the foot neckInset inside the face.
function emergePose(ctx) {
    return cardAt(ctx, ctx.hostV - ctx.dims.neckInset);
}

// The apex (the rise's end): the card's centre on the screen's centre along the normal, moved
// restOffset further out (negative: back towards the bar), unless that leaves
// less than restClear between the launcher's face and its foot (a tall launcher: 9 rows at 1296 design px, where the
// clearance is what decides how far the card is thrown), and never past what stands across from its bar (a padding short of it: ctx.farV,
// the free face of the bar on the far edge, or the far edge itself; a launcher that fills a small screen, the mockup). Whole pixels.
function restPose(ctx) {
    const d = ctx.dims, ax = ctx.axis;
    const w = cardW(d, d.ip1), h = cardH(d, d.ip1);
    const footV = Math.min(Math.max(ctx.screenCentreV - h / 2 + (d.restOffset || 0), ctx.hostV + d.restClear), ctx.farV - h - d.pad);
    const b0 = boxAt(ax, rowCentreU(ctx), footV, w, h);
    const b = { x0: Math.round(b0.x0), y0: Math.round(b0.y0), x1: Math.round(b0.x0) + Math.round(w), y1: Math.round(b0.y0) + Math.round(h) };
    const c = contentOf(d, b, d.ip1);
    return {
        box: b,
        radii: radiiAll(d.radius),
        ip: d.ip1,
        icon: { x: Math.round(c.icon.x), y: Math.round(c.icon.y) },
        title: { x: Math.round(c.title.x), y: Math.round(c.title.y) },
        m: 1,
        feather: 0,
        titleA: 1
    };
}

// ---- Phases ---------------------------------------------------------------------------------------
function blend(a, b, t) {
    return {
        box: lerpBox(a.box, b.box, t),
        radii: lerpRadii(a.radii, b.radii, t),
        ip: lerp(a.ip, b.ip, t),
        icon: lerpPt(a.icon, b.icon, t),
        title: lerpPt(a.title, b.title, t),
        m: lerp(a.m, b.m, t),
        feather: lerp(a.feather, b.feather, t),
        titleA: lerp(a.titleA, b.titleA, t),
        wellBox: lerpBox(a.wellBox || a.box, b.wellBox || b.box, t)
    };
}

// The lift's sub-ranges of its one fraction m (the morph's choreography, not
// tunables): the card's shape (its extent along the normal and its corners)
// by LIFT_SHAPE, the title's drop below the icon's line over LIFT_DROP, and
// the sideways moves of both over LIFT_ACROSS -- so the title has cleared the
// icon's bottom before the two pass each other, and the card is already deep
// enough to hold the dropped title above its rounding foot.
var LIFT_SHAPE = [0, 0.5];
var LIFT_DROP = [0.05, 0.55];
var LIFT_ACROSS = [0.35, 1];

function alongExtent(axis, b) {
    return vertical(axis) ? b.x1 - b.x0 : b.y1 - b.y0;
}

function centreAlong(axis, b) {
    return vertical(axis) ? (b.x0 + b.x1) / 2 : (b.y0 + b.y1) / 2;
}

// The lift from the row `a` (its box whole, or cut to the viewport).
function liftFrom(ctx, a, m) {
    const ax = ctx.axis, vert = vertical(ax);
    const z = emergePose(ctx);
    const sh = smooth(LIFT_SHAPE[0], LIFT_SHAPE[1], m);
    const sd = smooth(LIFT_DROP[0], LIFT_DROP[1], m);
    const sa = smooth(LIFT_ACROSS[0], LIFT_ACROSS[1], m);
    // The far side travels, the extent out of the bar leads, the width goes
    // with the travel.
    const far = lerp(footOf(ax, a.box) + outExtent(ax, a.box), footOf(ax, z.box) + outExtent(ax, z.box), m);
    const ext = lerp(outExtent(ax, a.box), outExtent(ax, z.box), sh);
    const along = lerp(alongExtent(ax, a.box), alongExtent(ax, z.box), m);
    // A cut row's box is off the row's centre along the bar; the card is on it.
    const cu = lerp(centreAlong(ax, a.box), rowCentreU(ctx), m);
    const b = boxAt(ax, cu, far - ext, vert ? along : ext, vert ? ext : along);
    // The content in the box's own frame (its top-left), on the screen's axes.
    const rel = (p, box) => ({ x: p.x - box.x0, y: p.y - box.y0 });
    const ai = rel(a.icon, a.box), zi = rel(z.icon, z.box);
    const at = rel(a.title, a.box), zt = rel(z.title, z.box);
    // Across and down in screen terms: for a side bar the title's drop is
    // still down the screen.
    const icon = { x: b.x0 + lerp(ai.x, zi.x, sa), y: b.y0 + lerp(ai.y, zi.y, m) };
    const title = { x: b.x0 + lerp(at.x, zt.x, sa), y: b.y0 + lerp(at.y, zt.y, sd) };
    return {
        box: b,
        radii: lerpRadii(a.radii, z.radii, sh),
        ip: a.ip,
        icon: icon,
        title: title,
        m: m,
        feather: 0,
        titleA: 1
    };
}

// The lift: the content and the well from the row WHOLE (their moves are
// the row's, however much of it the list showed), the body from the row as
// shown -- the two meet at the card, where nothing is cut any more.
function lift(ctx, m) {
    const whole = rowPose(ctx, true), cut = rowPose(ctx, false);
    const p = liftFrom(ctx, whole, m);
    p.wellBox = p.box;
    if (JSON.stringify(cut.box) !== JSON.stringify(whole.box) || JSON.stringify(cut.radii) !== JSON.stringify(whole.radii)) {
        const q = liftFrom(ctx, cut, m);
        p.box = q.box;
        p.radii = q.radii;
    }
    return p;
}

// The foot moves and the card grows away from the bar; `uf` (0..1) is the throw's share of the way across the bar, which the
// card drifts at a constant pace from the row's centre to the anchor.
function rise(ctx, e, uf) {
    const d = ctx.dims, ax = ctx.axis;
    const a = emergePose(ctx), z = restPose(ctx);
    const ip = lerp(d.ip0, d.ip1, e);
    const w = lerp(a.box.x1 - a.box.x0, z.box.x1 - z.box.x0, e);
    const h = lerp(a.box.y1 - a.box.y0, z.box.y1 - z.box.y0, e);
    const footV = lerp(footOf(ax, a.box), footOf(ax, z.box), e);
    const zc = toUV(ax, (z.box.x0 + z.box.x1) / 2, (z.box.y0 + z.box.y1) / 2);
    const cu = lerp(rowCentreU(ctx), ctx.anchorU, uf || 0) + (zc.u - rowCentreU(ctx)) * e;
    const b = boxAt(ax, cu, footV, w, h);
    const c = contentOf(d, b, ip);
    // The apex's content is on whole pixels: the rounding comes in with the
    // rise, so its last frame is the apex's own.
    const zc0 = contentOf(d, z.box, d.ip1);
    return {
        box: b,
        radii: lerpRadii(a.radii, z.radii, e),
        ip: ip,
        icon: { x: c.icon.x + (z.icon.x - zc0.icon.x) * e, y: c.icon.y + (z.icon.y - zc0.icon.y) * e },
        title: { x: c.title.x + (z.title.x - zc0.title.x) * e, y: c.title.y + (z.title.y - zc0.title.y) * e },
        m: 1,
        feather: 0,
        titleA: 1
    };
}

// The ball round the icon of `from`, where it is.
function ballTarget(ctx, from) {
    const d = ctx.dims;
    const R = ballR(d, from.ip);
    const cx = from.icon.x + from.ip / 2, cy = from.icon.y + from.ip / 2;
    return {
        box: { x0: cx - R, y0: cy - R, x1: cx + R, y1: cy + R },
        radii: radiiAll(R),
        ip: from.ip,
        icon: from.icon,
        title: from.title,
        m: from.m,
        feather: 0,
        titleA: 0
    };
}

// The fade of what the circle still holds of the title (BALL_TITLE_FADE of
// the ball's fraction).
var BALL_TITLE_FADE = [0.55, 1];

function ball(ctx, from, e) {
    const p = blend(from, ballTarget(ctx, from), e);
    p.feather = ctx.dims.cullFeather * Math.sin(Math.PI * clamp01(e));
    p.titleA = from.titleA * (1 - smooth(BALL_TITLE_FADE[0], BALL_TITLE_FADE[1], e));
    return p;
}

// A pose moved by (dx, dy), everything with it.
function shifted(p, dx, dy) {
    return {
        box: { x0: p.box.x0 + dx, y0: p.box.y0 + dy, x1: p.box.x1 + dx, y1: p.box.y1 + dy },
        radii: p.radii,
        ip: p.ip,
        icon: { x: p.icon.x + dx, y: p.icon.y + dy },
        title: { x: p.title.x + dx, y: p.title.y + dy },
        m: p.m,
        feather: p.feather,
        titleA: p.titleA,
        wellBox: p.wellBox ? { x0: p.wellBox.x0 + dx, y0: p.wellBox.y0 + dy, x1: p.wellBox.x1 + dx, y1: p.wellBox.y1 + dy } : undefined
    };
}

function centreUV(ctx, p) {
    return toUV(ctx.axis, (p.box.x0 + p.box.x1) / 2, (p.box.y0 + p.box.y1) / 2);
}

// Where the icon's centre is, along (u) and out of (v) the bar.
function iconCentreUV(ctx, p) {
    return toUV(ctx.axis, p.icon.x + p.ip / 2, p.icon.y + p.ip / 2);
}

// THE THROW: its numbers, all of them from ONE gravity (d.gravity, px/s^2) and the geometry. The coast covers the share 1 - a of
// the climb H (the icon centre's) under gravity, so it lasts sqrt(2 (1 - a) H / g); riseE gives the pull the same share of the clock
// as of the distance, so the rise's whole clock is that over 1 - a, sqrt(2 H / ((1 - a) g)); the fall is the same gravity from the apex's
// zero speed down the distance D to the ball's contact, sqrt(2 D / g). What a person sees of it: gravity alone says how long the card is
// slow (under a speed s for 2 s / g, within e px of the apex for 2 sqrt(2 e / g)) and the distances say how fast it goes (launch
// sqrt(2 g (1 - a) H), landing sqrt(2 g D)), so more hang and more speed is a lower gravity and a higher apex, and the cost is the
// clock (FlourishPresets.js, THE HANG). Nothing here reads the launcher's close, and no phase has a length
// of its own: a gravity derived from a tuned rise of 420 ms beside a detach share of 0.95 would come to ~24 500 px/s^2, a
// fall of 0.3 s. A tall launcher only shortens the climb.
// -> { H, D, g (px per ms squared), riseMs, downMs, launch (px/ms: off the strand), land (px/ms: at the contact) }.
function throwOf(ctx) {
    const d = ctx.dims;
    const a = Math.max(0.05, Math.min(0.95, d.detachFrac));
    const z = restPose(ctx), e0 = emergePose(ctx);
    const H = Math.max(1, iconCentreUV(ctx, z).v - iconCentreUV(ctx, e0).v);
    const D = Math.max(1, iconCentreUV(ctx, z).v - ballR(d, z.ip));
    const g = Math.max(1, d.gravity) / 1e6;
    return { H: H, D: D, g: g, riseMs: Math.sqrt(2 * H / ((1 - a) * g)), downMs: Math.sqrt(2 * D / g), launch: Math.sqrt(2 * g * (1 - a) * H), land: Math.sqrt(2 * g * D) };
}

// The way down: the icon's centre falls to the ball's radius (its foot on the bar's face) on eDown (the share of the
// distance gone: f^2 for gravity) and moves across to the anchor on eAcross, while the card closes round it on eBall.
function fall(ctx, from, eDown, eAcross, eBall) {
    const q = ball(ctx, from, eBall);
    const ic = iconCentreUV(ctx, from);
    const R = ballR(ctx.dims, from.ip);
    const c0 = toXY(ctx.axis, ic.u, ic.v);
    const c = toXY(ctx.axis, lerp(ic.u, ctx.anchorU, eAcross), lerp(ic.v, R, eDown));
    return shifted(q, c.x - c0.x, c.y - c0.y);
}

// Into the bar, shrinking; at e = 1 its top is a merge radius under the face.
function sink(ctx, from, e) {
    const d = ctx.dims;
    const c = centreUV(ctx, from);
    const R = outExtent(ctx.axis, from.box) / 2;
    const s = lerp(1, d.sinkShrink, e);
    const r = R * s;
    const v = lerp(c.v, -(R * d.sinkShrink + d.mergeK + 1), e);
    const xy = toXY(ctx.axis, c.u, v);
    const ip = from.ip * s;
    const ix = from.icon.x + from.ip / 2 - (from.box.x0 + from.box.x1) / 2;
    const iy = from.icon.y + from.ip / 2 - (from.box.y0 + from.box.y1) / 2;
    return {
        box: { x0: xy.x - r, y0: xy.y - r, x1: xy.x + r, y1: xy.y + r },
        radii: radiiAll(r),
        ip: ip,
        icon: { x: xy.x + ix * s - ip / 2, y: xy.y + iy * s - ip / 2 },
        title: { x: from.title.x + (xy.x - (from.box.x0 + from.box.x1) / 2), y: from.title.y + (xy.y - (from.box.y0 + from.box.y1) / 2) },
        m: from.m,
        feather: 0,
        titleA: from.titleA
    };
}

// The launcher's free face: the gap between it and the card's foot (v px;
// negative while the foot is inside the launcher).
function gapOf(ctx, p) {
    return footOf(ctx.axis, p.box) - ctx.hostV;
}

// ---- The neck --------------------------------------------------------------------------------------
// The bridge between the card and the closing launcher, as the engine's
// setFlourishNeck takes it (gooey_field.frag, THE NECK): two uneven capsules on
// the card's axis, each from inside its body to the WAIST point M, which sits
// midFrac of the way from the card's foot to the launcher's face -- the
// meeting is in the middle whatever the curves on either side. It is POSED,
// not a product of the gap: the card and the launcher are never blended with
// each other, only each with the neck -- EXCEPT while the card comes out of the
// launcher (below).
//
//   emergence      from the lift's first frame the neck is on. While the card's
//                  foot is still inside the launcher the capsules lie inside the
//                  union and their blend radii are nil, so the picture is the
//                  card and the launcher joined by ONE blend, kJoin, which
//                  grows with the card's protrusion p past the launcher's face,
//                  k = emergeK p / (p + emergeGrowPx) -- a smooth-min of k reaches 0.78 k along the face; measured on a real
//                  popup coming out of a bar: the fillet runs 24 / 28 / 31 / 33 px along the face
//                  at 5 / 10 / 20 / 40 px out, and k = 45 p / (p + 2.3) reads those. At the first pixel it already has a curve. As the foot clears the face the
//                  blend gives way over emergeFadePx to the neck's own: the
//                  capsules' radii come in (deploy, 0..1) and kJoin falls to
//                  d.kJoin -- one continuous flow from the emerging card's
//                  fillets into the neck's wide curves.
//   card side      the wide end A is rUFrac of the card's width in radius (held
//                  so the arm's flank is at least kA + 1 px inside the card's
//                  walls where it crosses the card's foot: a swollen side is a
//                  chin), its circle's far point a blend radius (kA) inside the
//                  foot; the shader keeps the capsule only from that point on
//                  (neckArm), so what lies in the card is never blended with
//                  its other edges, and the retracted capsule is wholly inside
//                  it, kA from the foot (no nub when the neck goes: the
//                  drop changes no pixel)
//   launcher side  the same, rLFrac of the launcher's width, a kB inside its face
//   waist          both tips have radius q, which runs from qStart to qPinch
//                  over the first detachFrac of the card's travel, and each tip
//                  passes M by NECK_OVERLAP of q: two convex ends that CROSS,
//                  which kMid rounds, are a waist; two that only touched at M
//                  would be a bead on the neck
//   the pinch      at detachFrac of the travel (travel(): the card's gap from
//                  the capture's face over its gap at rest) the launcher's close
//                  is let go and the tips retract, each into its own body, their
//                  radius growing to neckBulbPx (a recoiling strand balls up),
//                  until they lie wholly beyond the cut of
//                  their arms -- a snapped strand, in o.r (0..1) over
//                  neckRetractMs, on the neckRetractEasing curve. The tips cross at M and
//                  part at M.
//
// o: { faceV (the launcher's free face NOW, v), hostW (its width along the
// bar), r (0..1: the retraction), heldFaceV (the face at the PINCH: set from the
// pinch on, absent before) }.
//
// AFTER THE PINCH THE TWO HALVES ARE TWO THINGS. Everything on the card's side of the
// strand -- the waist point M, the arm's length, the stub's tip it retracts from, the
// deploy -- is measured against heldFaceV, the face where the strand parted, so the freed card and its stub move with
// nothing the launcher does; the launcher's own half (its capsule, its tip) is carried
// by the LIVE face. Reading the live face for the card's half would be a "wireless pull":
// as the launcher closed, M would run away with it and the card's stub would be stretched after it,
// so the launcher's movement would influence the detached card.
var NECK_OVERLAP = 0.6;
// The retraction's own beats, as shares of its LINEAR time (o.r), never of the eased travel: the
// waist's blend is gone by RET_WAIST and the tips ball up over RET_BULB0..RET_BULB1 (the shares of a
// 160 ms OutCubic), so a long retraction is the same rounded bulb sinking back, slower.
var RET_WAIST = 0.035;
var RET_BULB0 = 0.035;
var RET_BULB1 = 0.11;
var RET_LEAD = 0.8;

// The card's travel from the launcher's face to its rest, 0..1 (ctx.restGap,
// the rest's gap from the capture's face, is fixed when the flourish starts).
function travel(ctx, p) {
    return clamp01(gapOf(ctx, p) / Math.max(1, ctx.restGap));
}

function restGapOf(ctx) {
    return footOf(ctx.axis, restPose(ctx).box) - ctx.hostV;
}

// How far the card's far side stands past the launcher's face (px, v).
function protrusion(ctx, p, faceV) {
    return footOf(ctx.axis, p.box) + outExtent(ctx.axis, p.box) - faceV;
}

// The half width of the card-side arm's cone `t` along its axis from the wide
// end: wide circle ra, tip circle rb, centres h apart (sdUnevenCapsule's
// tangent line).
function coneHalf(ra, rb, h, t) {
    const b = Math.max(-0.999, Math.min(0.999, (ra - rb) / Math.max(h, 1e-3)));
    return Math.max(0, (ra - b * t) / Math.sqrt(1 - b * b));
}

// The wide radius that keeps the arm's cone inside `limit` (its half width)
// at the card's foot, t = rU + kA along the axis; `len(rU)` is the capsule's
// length for that radius.
function armRadius(rWant, q, kA, limit, len) {
    const ok = r => coneHalf(r, q, len(r), r + kA) <= limit;
    if (ok(rWant))
        return rWant;
    let lo = 0, hi = rWant;
    for (let i = 0; i < 24; i++) {
        const mid = (lo + hi) / 2;
        if (ok(mid))
            lo = mid;
        else
            hi = mid;
    }
    return Math.max(1, lo);
}

function neck(ctx, p, o) {
    const d = ctx.dims, ax = ctx.axis;
    const f = footOf(ax, p.box);
    const cu = centreUV(ctx, p).u;
    const held = o.heldFaceV !== undefined && o.heldFaceV !== null && isFinite(o.heldFaceV);
    // The face the card's half is measured against: where the strand parted, once it has.
    const faceC = held ? o.heldFaceV : o.faceV;
    const gap = f - faceC;
    // The neck's own blends come in as the foot clears the face; the emerging
    // card's one blend (kEm) grows with the protrusion and gives way to d.kJoin.
    const dep = d.emergeFadePx > 0 ? smooth(0, d.emergeFadePx, gap) : (gap > 0 ? 1 : 0);
    const prot = Math.max(0, protrusion(ctx, p, faceC));
    const kEm = d.emergeK * prot / (prot + Math.max(0.01, d.emergeGrowPx));
    const sa = clamp01(travel(ctx, p) / Math.max(0.01, d.detachFrac));
    // The arm's flank must stay a blend radius clear of the card's walls where
    // it crosses the foot: the waist's radius gives way on a narrow card.
    const half = alongExtent(ax, p.box) / 2;
    const limit = Math.max(2, half - d.kA - 1);
    const q = Math.min(lerp(d.qStart, d.qPinch, sa), limit);
    // The tips' overlap goes as the pinch comes: at it they only touch, so the
    // strand parts as soon as the tips do.
    const ov = q * NECK_OVERLAP * (1 - sa * sa);
    const kk = k => Math.max(0.5, k * dep);
    const kJ = Math.max(0.5, lerp(kEm, d.kJoin, dep));
    const rL = d.rLFrac * o.hostW;
    const mv = f - d.midFrac * gap;
    // The wide circle itself, not only the flank where it crosses the foot,
    // stays kA + 1 inside the walls (rU <= limit): the shader blends the arm
    // with the card across kA, and a circle nearer a wall than that swells the
    // card's lower sides along its whole height (the tiny title's chin: rlr's
    // 0.4 x 2 half = 29 px circle in a card whose limit is 12).
    const rU = armRadius(Math.min(d.rUFrac * 2 * half, limit), q, d.kA, limit, r => r + d.kA + d.midFrac * gap + ov);
    const av = f + rU + d.kA, lv = o.faceV - rL - d.kB;
    // The launcher's tip leaves the waist M with the launcher: M as it stood at the pinch, carried by how far the face has moved since.
    const carry = o.faceV - faceC;
    const rl = clamp01(o.r);
    // The first RET_LEAD of it is an OutCubic whatever the curve: a snapped strand's tips part at the
    // pinch (an ease-in would hold them together and the pinch would show late), then the set curve.
    const rr = lerp(ease(1, rl), ease(d.retractEase, rl), smooth(0, RET_LEAD, rl));
    const pt = v => {
        const c = toXY(ax, cu, v);
        return { x: c.x, y: c.y };
    };
    // A snapped strand recoils and balls up: each tip's radius grows from the
    // pinch's q to the bulb (d.bulb) as soon as the tips have parted (RET_BULB0:
    // a growing tip before that would hold them together), so a stub is a
    // rounded nub sinking back into its body, never a cone with a point.
    const qq = lerp(q, Math.min(d.bulb, limit), smooth(RET_BULB0, RET_BULB1, rl));
    return {
        a: pt(av),
        mu: pt(lerp(mv - ov, av - rU + qq, rr)),
        l: pt(lv),
        ml: pt(lerp(mv + ov + carry, lv + rL - qq, rr)),
        rA: rU,
        qU: qq,
        rL: rL,
        qL: qq,
        kA: kk(d.kA),
        kB: kk(d.kB),
        // The waist's blend is gone as the tips start to part (it would hold them).
        kMid: kk(d.kMid) * (1 - Math.min(1, rl / RET_WAIST)) + 0.5 * Math.min(1, rl / RET_WAIST),
        kJoin: kJ
    };
}
