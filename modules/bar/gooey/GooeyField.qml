pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "../../common/theme"
import "GooeyGeometry.js" as Geo
import "GooeyRipple.js" as Ripple

// =============================================================================
// GooeyField.qml -- the bars and their popups drawn as ONE surface.
//
// Hand it bodies, get a single antialiased shape in which every body melts into
// its neighbours: a popup grows out of a bar through S-curves, a second popup
// grows out of the first, a popup leaving a bar pulls a flare after it that
// settles back. It knows nothing about bars, popups or their animation --
// GooeyEngine moves the boxes and hands them over every frame, and a mockup can
// hand it two boxes by hand.
//
//     GooeyField {
//         anchors.fill: parent
//         bodies: [ { id: "bar", x0: 0, y0: 0, x1: 800, y1: 40, r: 20, mobile: false },
//                   { id: "pop", x0: 200, y0: 40, x1: 500, y1: 300, r: 20 } ]
//     }
//
// A body is { id, x0, y0, x1, y1, rx, ry (or r), mobile, stick } in this
// item's coordinates. `mobile` bodies are the ones that may be drawn stretched to
// meet a nearby face (bars are not mobile). `stick` is the box a popup is open
// at, which its joins resist following; see
// GooeyGeometry.js for what every rule does and why.
//
// TINTS. `tints: [{ body: <index into bodies>, color }]` gives up to three
// bodies a colour of their own over `color` (an alpha below 1 lays it over the
// surface colour; alpha 0 is no tint). The colour is POURED across a join, over
// `tintBlend` px on each side of it, along the field's own distances
// (shaders/gooey_field.frag, "TINT"); a body's interior deeper than that is
// exactly its colour, the rest exactly `color`. With no tint the field draws
// the plain untinted surface. Separate from `bodies` so a
// colour that changes (a content easing its tint, a theme switch) costs a few
// uniforms and not the shape.
//
// THE SMOOTH GROUP. `smoothMask` (bit i: bodies[i]) and `smoothK` (px): the
// flagged bodies leave the hard union and blend with EACH OTHER by a quadratic
// smooth-min of radius smoothK -- the metaball neck: two of them a gap g apart
// are joined for g < smoothK / 2, the neck thinning to nothing at exactly
// smoothK / 2 where a face curves away (two FLAT faces make a membrane as wide
// as they are, which tears whole at k/2: bar_structure.md) -- and the group
// joins everything else by the hard min. It is a
// field relation only: fieldShape snaps, fillets and seams as usual.
// Fewer than two bits among the bodies, or smoothK <= 0: the same bytes as
// without it.
//
// THE RIPPLE. `rippleBody` (an index into bodies; -1 off) has its `rippleFace`
// (0 top, 1 bottom, 2 left, 3 right) displaced by GooeyRipple.js's height field
// at `rippleTime` (s since the first impact): a bulge and up to three impact
// sources `rippleSource0..2` = (s along the face, start offset t0 in s,
// amplitude A in px, unused), with their reflections in the bar's ends, under
// the globals in `rippleParams` (GooeyRipple.DEFAULTS). Troughs remove the bar's
// own material, which no union term could. The field is exactly the plain field
// again from rippleParams.Tend on (the window takes h to 0 there), and while it
// runs it draws one more band of tiles over the crests' reach. `ripple` says
// what it is drawing (for probes and for the host's joins: Ripple.height /
// slope with ripple.params).
//
// THE NECK. `neck` (null off) is an explicit bridge between two bodies, drawn
// INSTEAD of the smooth group while it is set: { sideA, sideB (indices into
// bodies: the card, the launcher), a, mu, l, ml ({x, y}: the two capsules' wide
// ends and their tips at the waist), rA, qU, rL, qL (their radii), kA, kB, kMid,
// kJoin (the blend radii) } -- shaders/gooey_field.frag, THE NECK. The ripple is
// dropped while it is drawn (they share their lanes). A neck whose bodies are
// not both drawn is not drawn. Its tile is both capsules' box grown by the
// largest radius's reach.
//
// BATCH. Every property above re-lays the field out on its own change; a host
// that changes several at once (the engine's layout: the bodies, the group and
// the ripple together) wraps the writes in `batch(fn)` and the field is laid out
// ONCE, when fn returns, with all of them.
//
// THE SHELL'S EDGE. A SHADOW under everything the field draws and a BORDER round it
// (shaders/gooey_field.frag, THE SHELL'S EDGE): both are the field's own signed distance read a second
// way, so they follow every body in motion -- popups opening and travelling, the flourish's card, the
// droplets, the ripples, the lane, the OSD -- with no knowledge of any of them. `shadowReach` (px; 0 is
// off), `shadowStrength`, `shadowSpread`, `shadowSoftness` and `shadowColor` make a halo -- one band of the same thickness all
// round the outline (no drop-shadow offset) -- and
// the shadow; `borderWidth` (px; 0 is off) and `borderColor` a ring just outside the surface. With both
// off the field draws the surface alone. The shadow is drawn from TILES of its own, in
// the first half of the tile list (the shape's are in the second, drawn after them): the ring of the shape's
// tiles grown by the reach, less what lies deep inside a body -- the shape covers that, and evaluating it
// again would be the cost of the whole popup for nothing.
//
// THE SHAPE TAP. `shapeTap` (null: none) is an item whose `feed(out)` is called at the end of every shape the field draws, with
// what GooeyGeometry returned for it (`bodies`, `fillets`, `seams`, as drawn): a second pass over the SAME numbers of the same
// frame (ReelCast: the reel's ring and halo over a popup). The field reads nothing back.
//
// The shape is decided in GooeyGeometry.js (pure) and drawn by
// shaders/gooey_field.{vert,frag}; this file carries numbers between them and
// keeps the one piece of state the shape has: how far each join has settled
// (a join that lets go relaxes over `settleMs` instead of snapping).
// =============================================================================
Item {
    id: field

    property color color: Theme.surface
    property var bodies: []
    property var tints: []
    // How far a tint reaches past a join into its neighbour, and as far again
    // into itself (px).
    property real tintBlend: 20

    // ---- The joins -------------------------------------------------
    // The largest a fillet gets along the face it runs on.
    property real blendRadius: 20
    // A mobile face within this of a facing face is drawn fully against it.
    property real attachDistance: 12
    // ...and from there it lets go gradually, completely at this distance; a
    // popup this far past a bar's end still pulls a flare out of it.
    property real snapDistance: 50
    // How much a join resists following its popup's side while the popup opens
    // and closes: 0 moves the fillet rigidly with the side, 1 keeps its tip on
    // the bar where the popup will be open and stretches the fillet instead.
    property real stickiness: 0.75
    // The longest a stretched fillet gets beyond its normal size.
    property real stretchMax: 60
    // How much of that stretch also runs down the popup's side.
    property real sideStretch: 1
    // How long a join takes to let go once its popup has left (0: at once).
    property int settleMs: 160
    // An end of a popup within this many px of its bar's end is drawn flush
    // with it, letting go by twice that.
    property real flushSnap: 3

    // Debug: draw the whole union as one tile (the A/B for the tiling), and
    // tint each tile so the decomposition can be seen.
    property bool forceSingleTile: false
    property bool showTiles: false

    // ---- THE SHELL'S EDGE (header). 0 is off. -------------------------------------
    // How far past the edge the shadow reaches (px), its alpha at the edge, and its colour (the colour's own alpha is not used:
    // the strength is the alpha).
    property real shadowReach: 0
    property real shadowStrength: 0.3
    // Its SPREAD (px: the shape it falls from grown by it, shrunk below 0) and SOFTNESS (0 .. 1: 1 falls over the whole reach,
    // less holds the ink whole nearer the edge and falls over the outer part only). 0 and 1 draw the plain fall.
    property real shadowSpread: 0
    property real shadowSoftness: 1
    property color shadowColor: Theme.shellShadow
    // The ring just outside the surface (px) and its colour: the waybar's, a ring DARKER than the surface in the light theme
    // and LIGHTER in the dark one. The theme says which (Theme.shellBorder: border in light, buttonBevel in dark -- `border` is the
    // dark theme's carved-inset edge, darker than the surface, the wrong way round for a rim that has to stand out from a dark window).
    property color borderColor: Theme.shellBorder
    property real borderWidth: 0
    // The radius (px) over which the shadow's union of the bodies is smooth (a smooth-min, the group's: gooey_field.frag
    // groupBit): concave corners and narrow gaps round off and darken, as a blurred shadow does. A smooth group of
    // the host's own that is out (smoothMask) keeps its own radius.
    property real shadowBlend: 20
    // Debug: false draws the shadow's tiles whole, with nothing cut out of their middle (the A/B for the cut:
    // the picture must not change).
    property bool shadowCut: true
    // A LEVER for hosts that do not ask (the gates, the perf runs of mockups that know nothing of the
    // edge): GOOEY_SHADOW=<reach>,<strength>[,<spread>,<softness>] and GOOEY_BORDER=<width> in the
    // environment stand in for the properties above while those are 0.
    // Unset, they are nothing.
    readonly property var _lever: {
        const sh = String(Quickshell.env("GOOEY_SHADOW") || "").split(",").map(Number);
        const bw = Number(Quickshell.env("GOOEY_BORDER") || "0");
        return { reach: sh[0] > 0 ? sh[0] : 0, strength: sh.length > 1 && sh[1] >= 0 ? sh[1] : 0.3,
                 spread: sh[2] || 0, soft: sh.length > 3 && sh[3] > 0 ? Math.min(1, sh[3]) : 1,
                 bw: bw > 0 ? bw : 0 };
    }
    // What is drawn: the properties, else the lever.
    readonly property real _reach: field.shadowReach > 0 ? field.shadowReach : field._lever.reach
    readonly property real _strength: field.shadowReach > 0 ? field.shadowStrength : field._lever.strength
    readonly property real _spread: field.shadowReach > 0 ? field.shadowSpread : field._lever.spread
    readonly property real _softness: Math.max(0.001, Math.min(1, field.shadowReach > 0 ? field.shadowSoftness : field._lever.soft))
    readonly property real _bw: field.borderWidth > 0 ? field.borderWidth : field._lever.bw
    // The halo is drawn when the shadow is on or an aura is out (the aura's tiles and smooth union are the shadow's), and its tiles
    // reach as far as the farther of the two.
    readonly property bool _shadowOn: field._reach > 0 && field._strength > 0
    readonly property bool _haloOn: field._shadowOn || field.auraReach > 0
    // (The aura's reach breathes to 1.3 of itself, gooey_field.frag: the tiles must hold the farthest it goes, or the shadow's rectangles cut it.)
    readonly property real _haloReach: Math.max(field._shadowOn ? field._reach : 0, field.auraReach > 0 ? 1.3 * (field.auraReach + field._bw) : 0)

    // ---- THE AURA (gooey_field.frag, THE AURA): the halo lit with hues flowing round the outline. A host that plays one sets these;
    // at rest every one reads as it does here and the field draws no aura.
    //   auraLevel   0 .. 1, the envelope times the strength (0: no aura, the shader does not enter its branch)
    //   auraTime    seconds, the host's one clock (the waves travel and the noise drifts with it)
    //   auraReach   px past the surface the halo reaches; > 0 gives the shadow tiles even with the shadow off (the aura is then its
    //               own halo), and rides the same smooth union of the bodies. 0 at rest: the tiles are the shadow's own.
    //   auraColors  four colours round the cycle
    //   auraGroups  [the island group's, the rest's] ink shown, 0 .. 1 each: [1, 1] both, [1, 0] the island group alone, [0, 1] the rest
    //               alone, and between while the engine eases a group handed over (GooeyEngine._auraGroups)
    //   auraBodies  the indices (into `bodies`) of the island group; auraChainBodies of the chain, the largest popup outside it
    //   auraRef     { a, b, c } each loop's rectangle and middle, { x0, y0, x1, y1, cx, cy } (GooeyAura.groups): the island group's, the frame's, the chain's
    //   auraCycles  [a, b, c] whole waves round each loop's rectangle (the frame's is read here; a and c reach the shader in auraJoins)
    //   auraJoins   [a, c] the island group's and the chain's hue lanes (gooey_field.frag, THE JOIN; GooeyAura.joinVec): [s_a, +-share, U_a, U_b],
    //               a plain loop [0, 1, 0, its cycles]
    property real auraLevel: 0
    property real auraTime: 0
    property real auraReach: 0
    property var auraColors: []
    property var auraGroups: [1, 1]
    property var auraBodies: []
    property var auraChainBodies: []
    property var auraRef: null
    property var auraCycles: [2, 4, 1]
    property var auraJoins: [[0, 1, 0, 2], [0, 1, 0, 1]]

    // THE SHAPE TAP (header).
    property var shapeTap: null

    // THE INK (shell.jsonc workarounds.visibleInk; GooeyInk): while `inkWanted` every update keeps the tiles it handed the shader --
    // the shadow's and the shape's, the only places the field writes a pixel -- as `inkTiles` { ring, shape, n } (field px, the lists
    // themselves, no copy) and bumps `inkSerial`. Off (the default) nothing is kept.
    property bool inkWanted: false
    property var inkTiles: null
    property int inkSerial: 0
    // how far past a body's box the field can write a pixel: the halo (shadow or aura, at its farthest breath), the ring, the tiles' margin
    readonly property real inkReach: field._haloReach + field._bw + field._tileMargin

    // THE SMOOTH GROUP (header).
    property int smoothMask: 0
    property real smoothK: 0
    property var neck: null

    // THE RIPPLE (header). Every property here re-lays the field out except
    // rippleTime, which only re-reduces the lanes (and re-lays out when the
    // ripple starts or ends).
    property int rippleBody: -1
    property int rippleFace: 0
    property real rippleTime: 0
    property vector4d rippleSource0: Qt.vector4d(0, 0, 0, 0)
    property vector4d rippleSource1: Qt.vector4d(0, 0, 0, 0)
    property vector4d rippleSource2: Qt.vector4d(0, 0, 0, 0)
    property var rippleParams: ({})
    // { active, body, params, frame, band }: what the last update drew (frame,
    // the lanes' reduction at rippleTime, is refreshed in place per rippleTime;
    // a host evaluates the face with Ripple.height(s, t, ripple.params)).
    readonly property var ripple: field._ripple
    // How many tiles the ripple's band and the group's necks added to the
    // shape's own (-1: over the budget, the union re-cut instead).
    readonly property int extraTiles: field._extraTiles

    // What it draws: past this the LAST bodies are cut and the field warns once. The engine keeps its
    // lane and OSD within it (GooeyEngine: THE BUDGET); a host of its own counts for itself.
    readonly property int maxBodies: 12
    readonly property int maxFillets: 24
    readonly property int maxSeams: 24
    readonly property int maxTiles: 48
    // ...and the same again for the shadow's tiles, in front of them (the list has maxTiles + maxShadowTiles).
    readonly property int maxShadowTiles: 48

    readonly property int tileCount: field._tileCount
    // The shadow's tiles (the first of the list; 0 with no shadow) and the pixels both kinds cover:
    // what the fragment shader is run on, the cost of the edge.
    readonly property real shapeArea: field._shapeArea
    readonly property real shadowArea: field._shadowArea
    readonly property int bodyCount: field._bodyCount
    readonly property int filletCount: field._filletCount
    // The corners the field is drawing, per body: ellipse semi-axes { ex, ey }
    // and centre insets { ix, iy }, each [tl, tr, br, bl], plus the box as
    // DRAWN { x0, y0, x1, y1 } (snapping may move a face). A plain rounded
    // corner has ix == ex and iy == ey.
    readonly property var cornerRadii: field._radii
    // Every fillet and seam, as drawn (for probes).
    readonly property var fillets: field._fillets
    readonly property var seams: field._seams
    // Whether a join is still settling (the field is asking for frames).
    readonly property bool settling: relax.running

    property int _tileCount: 0
    property int _shadowTileCount: 0
    property real _shapeArea: 0
    property real _shadowArea: 0
    property int _bodyCount: 0
    property int _filletCount: 0
    property int _skyFillets: 0
    property int _filletTotal: 0
    property int _seamTotal: 0
    property var _radii: []
    property var _fillets: []
    property var _seams: []
    property var _state: ({})
    // The void flares (GooeyGeometry.js) drawn at the last shape: "<upper id>|<lower id>|<axis>|void<dir>".
    function voidKeys() {
        return Object.keys(field._state.void || {});
    }
    property real _lastMs: 0
    property bool _warned: false
    // THE UNIFORM WRITES. What each of the shader's vec4 slots last held, how
    // many of each kind the last update used, and the slot names made once. A
    // uniform write is a trip through the property system and a change signal:
    // writing all ~200 slots on every update is a third of a layout (0.32 of
    // 0.94 ms, measured under a live resize), for slots that mostly have not
    // changed (the bars) or that the shaders never read (past the counts --
    // gooey_field.frag/.vert read a slot only below its count). So only the slots
    // below max(this count, the last one) are visited -- the last one's, to
    // clear what was used before -- and only a value that changed is written.
    property var _written: ({})
    property var _used: ({ b: 0, f: 0, s: 0, t: 0, ts: 0 })
    // Which shader slot each body went into (the rippling body goes to slot 0,
    // where the shader evaluates it, the rest keep their order behind it), the
    // fillet bleeds' x / y (g<i>.xy) and the values of the PACKED LANES
    // (g<i>.zw: the group's and the ripple's numbers, fx.packNames).
    property var _slotOf: []
    property var _gxy: []
    property var _lanes: ({})
    // The neck as drawn (neck, if both its bodies are), null off.
    property var _neckNow: null
    property var _ripple: ({ active: false, body: -1, params: null, frame: null, band: null })
    property int _extraTiles: 0
    // BATCH (header): how deep the batches are, and what they deferred.
    property int _defer: 0
    property bool _dirty: false
    property bool _dirtyRipple: false
    readonly property var _names: {
        const mk = (p, n) => Array.from({ length: n }, (_, i) => p + i);
        return { b: mk("b", field.maxBodies), x: mk("x", field.maxBodies), y: mk("y", field.maxBodies),
                 u: mk("u", field.maxBodies), v: mk("v", field.maxBodies),
                 f: mk("f", field.maxFillets), k: mk("k", field.maxFillets), g: mk("g", field.maxFillets),
                 s: mk("s", field.maxSeams), t: mk("t", field.maxTiles + field.maxShadowTiles) };
    }

    onBodiesChanged: field._update()
    onTintsChanged: field._updateTints()
    onTintBlendChanged: field._updateTints()
    onBlendRadiusChanged: field._update()
    onAttachDistanceChanged: field._update()
    onSnapDistanceChanged: field._update()
    onStickinessChanged: field._update()
    onStretchMaxChanged: field._update()
    onSideStretchChanged: field._update()
    onSettleMsChanged: field._update()
    onFlushSnapChanged: field._update()
    onForceSingleTileChanged: field._update()
    onSmoothMaskChanged: field._update()
    onSmoothKChanged: field._update()
    onNeckChanged: field._update()
    onRippleBodyChanged: field._update()
    onRippleFaceChanged: field._update()
    onRippleParamsChanged: field._update()
    onRippleSource0Changed: field._update()
    onRippleSource1Changed: field._update()
    onRippleSource2Changed: field._update()
    onRippleTimeChanged: field._updateRipple()
    onWidthChanged: field._update()
    onHeightChanged: field._update()
    on_HaloReachChanged: field._update()
    on_HaloOnChanged: field._update()
    on_ReachChanged: field._update()
    on_StrengthChanged: field._update()
    on_BwChanged: field._update()
    on_SpreadChanged: field._update()
    on_SoftnessChanged: field._updateEdge()
    onShadowBlendChanged: field._update()
    onShadowColorChanged: field._updateEdge()
    onBorderColorChanged: field._updateEdge()
    Component.onCompleted: {
        field._update();
        field._updateTints();
    }

    // Runs only while a join is settling: every frame it re-evaluates the shape
    // with the time that passed, and it stops itself when nothing is left.
    FrameAnimation {
        id: relax
        running: false
        onTriggered: field._update()
    }

    // BATCH (header): the writes fn makes are laid out once, when it returns.
    function batch(fn) {
        field._defer++;
        try {
            fn();
        } finally {
            field._defer--;
        }
        if (field._defer > 0)
            return;
        if (field._dirty) {
            field._dirty = false;
            field._dirtyRipple = false;
            field._update();
        } else if (field._dirtyRipple) {
            field._dirtyRipple = false;
            field._updateRipple();
        }
    }

    function _update() {
        if (field._defer > 0) {
            field._dirty = true;
            return;
        }
        const src = field.bodies || [];
        if (src.length > field.maxBodies && !field._warned) {
            field._warned = true;
            console.warn("GooeyField: " + src.length + " bodies, drawing the first " + field.maxBodies);
        }
        const now = Date.now();
        const dt = field._lastMs > 0 ? Math.min(100, now - field._lastMs) : 0;
        field._lastMs = now;

        const out = Geo.fieldShape(src.slice(0, field.maxBodies), {
            blendRadius: field.blendRadius,
            attachDistance: field.attachDistance,
            snapDistance: field.snapDistance,
            stickiness: field.stickiness,
            stretchMax: field.stretchMax,
            sideStretch: field.sideStretch,
            settleMs: field.settleMs,
            flushSnap: field.flushSnap,
            skyOutset: field._bw,
            maxFillets: field.maxFillets,
            maxSeams: field.maxSeams,
            maxTiles: field.maxTiles,
            clip: { x0: 0, y0: 0, x1: field.width, y1: field.height },
            forceSingleTile: field.forceSingleTile
        }, field._state, dt);
        field._state = out.state;
        // THE SKY in the shadow (gooey_field.frag, THE SHELL'S EDGE): a shadow tile evaluates the first `sky` fillets, so with a
        // shadow the sky's go first. The geometry kept them all already (fieldShape cut to maxFillets), and the order of a min()
        // changes no drawn pixel; with no shadow the list is the geometry's, untouched.
        let sky = 0;
        if (field._haloOn) {
            const isSky = f => String(f.key).indexOf("sky:") >= 0;
            const fl = out.fillets.slice(0, field.maxFillets);
            out.fillets = fl.filter(isSky).concat(fl.filter(f => !isSky(f)));
            sky = fl.filter(isSky).length;
        }
        field._skyFillets = sky;

        const N = field._names, used = field._used;
        const n = out.bodies.length;
        // THE RIPPLE: the rippling body into slot 0, the rest behind it in order.
        const rp = field._rippleParamsFor(out.bodies, n);
        const nk = field._neckOf(out.bodies, n);
        field._neckNow = nk;
        const rOn = nk === null && rp !== null && Ripple.active(rp, field.rippleTime);
        const order = rOn ? [field.rippleBody] : [];
        for (let j = 0; j < n; j++)
            if (!rOn || j !== field.rippleBody)
                order.push(j);
        const slotOf = [];
        for (let k = 0; k < order.length; k++)
            slotOf[order[k]] = k;
        const permChanged = slotOf.length !== field._slotOf.length || slotOf.some((v, j) => field._slotOf[j] !== v);
        field._slotOf = slotOf;
        for (let i = 0; i < Math.min(field.maxBodies, Math.max(n, used.b)); i++) {
            const b = i < n ? out.bodies[order[i]] : null;
            // A body with no area draws nothing (GooeyGeometry.js: `solid`); a
            // point far off the field is the shader's "nothing" for a body.
            if (b && b.solid)
                field._put(N.b[i], b.x0, b.y0, b.x1, b.y1);
            else
                field._put(N.b[i], -1e5, -1e5, -1e5, -1e5);
            if (b) {
                field._put(N.x[i], b.ex[0], b.ex[1], b.ex[2], b.ex[3]);
                field._put(N.y[i], b.ey[0], b.ey[1], b.ey[2], b.ey[3]);
                field._put(N.u[i], b.ix[0], b.ix[1], b.ix[2], b.ix[3]);
                field._put(N.v[i], b.iy[0], b.iy[1], b.iy[2], b.iy[3]);
            } else {
                field._put(N.x[i], 0, 0, 0, 0);
                field._put(N.y[i], 0, 0, 0, 0);
                field._put(N.u[i], 0, 0, 0, 0);
                field._put(N.v[i], 0, 0, 0, 0);
            }
        }
        const nf = Math.min(out.fillets.length, field.maxFillets);
        for (let i = 0; i < Math.max(nf, used.f); i++) {
            const f = i < nf ? out.fillets[i] : null;
            if (f) {
                field._put(N.f[i], f.vx, f.vy, f.ex, f.ey);
                field._put(N.k[i], f.kx, f.ky, f.krx, f.kry);
                field._gxy[i] = [f.bx, f.by];
            } else {
                field._put(N.f[i], 0, 0, 0, 0);
                field._put(N.k[i], 0, 0, 0, 0);
                field._gxy[i] = [0, 0];
            }
            // Past the packed lanes a bleed is all there is in g<i>.
            if (i >= fx.packNames.length)
                field._writeG(i);
        }
        const ns = Math.min(out.seams.length, field.maxSeams);
        for (let i = 0; i < Math.max(ns, used.s); i++) {
            const s = i < ns ? out.seams[i] : null;
            if (s)
                field._put(N.s[i], s.x0, s.y0, s.x1, s.y1);
            else
                field._put(N.s[i], 0, 0, 0, 0);
        }
        // The shape's tiles cover each primitive's box grown by the antialiasing
        // (fieldShape). Two things here draw outside that: the RIPPLE's crests
        // (a band across the bar, as far past its face as a crest can reach) and
        // the SMOOTH GROUP's necks (smin never lies more than k/4 below the hard
        // min, so the group's shape lies within k/4 of its bodies: each group
        // body's box grown by that). Their union, less what the shape's own
        // tiles cover -- a pixel two tiles draw is drawn twice -- is appended.
        const clip = { x0: 0, y0: 0, x1: field.width, y1: field.height };
        const extra = [];
        let band = null;
        if (rOn) {
            band = field._rippleBand(out.bodies[field.rippleBody], rp);
            if (band)
                extra.push(band);
        }
        const grp = field._groupOf(n);
        const reach = field.smoothK / 4 + 4.5;
        for (const j of grp) {
            const b = out.bodies[j];
            if (b.solid)
                extra.push({ x0: b.x0 - reach, y0: b.y0 - reach, x1: b.x1 + reach, y1: b.y1 + reach });
        }
        if (nk) {
            const m = Math.max(nk.kA, nk.kB, nk.kMid, nk.kJoin) / 4 + 4.5;
            const x0 = Math.min(nk.a.x - nk.rA, nk.mu.x - nk.qU, nk.l.x - nk.rL, nk.ml.x - nk.qL) - m;
            const y0 = Math.min(nk.a.y - nk.rA, nk.mu.y - nk.qU, nk.l.y - nk.rL, nk.ml.y - nk.qL) - m;
            const x1 = Math.max(nk.a.x + nk.rA, nk.mu.x + nk.qU, nk.l.x + nk.rL, nk.ml.x + nk.qL) + m;
            const y1 = Math.max(nk.a.y + nk.rA, nk.mu.y + nk.qU, nk.l.y + nk.rL, nk.ml.y + nk.qL) + m;
            extra.push({ x0: x0, y0: y0, x1: x1, y1: y1 });
            // The junction of the two bodies: the card's width plus kJoin on each
            // side, over the face +- kJoin (the two boxes each grown by kJoin and
            // overlapped). The join's fillet reaches that far past the card's
            // walls, beyond both the bodies' own tiles and the capsules' box.
            const A = out.bodies[nk.sideA], B = out.bodies[nk.sideB], g = nk.kJoin + 4.5;
            const ox0 = Math.max(A.x0 - g, B.x0 - g), oy0 = Math.max(A.y0 - g, B.y0 - g);
            const ox1 = Math.min(A.x1 + g, B.x1 + g), oy1 = Math.min(A.y1 + g, B.y1 + g);
            if (ox1 > ox0 && oy1 > oy0)
                extra.push({ x0: ox0, y0: oy0, x1: ox1, y1: oy1 });
        }
        let tl = out.tiles, extraTiles = 0;
        if (extra.length) {
            const add = [];
            for (const r of Geo.tiles(extra, clip, 4 * field.maxTiles))
                for (const t of field._minusTiles(out.tiles, r))
                    add.push(t);
            if (out.tiles.length + add.length <= field.maxTiles) {
                tl = out.tiles.concat(add);
                extraTiles = add.length;
            } else {
                tl = Geo.tiles(out.tiles.concat(extra), clip, field.maxTiles);
                extraTiles = -1;
            }
        }
        // THE SHELL'S EDGE (header). A border wider than the tiles reach past a box grows them (the union of boxes
        // grown by 4.5, grown by the rest, is the union of the boxes grown by all of it); the shadow's own tiles go
        // in front of the shape's. With both off nothing here runs and the list is the shape's alone.
        const bw = field._bw, on = field._haloOn;
        if (bw + 1.5 > field._tileMargin)
            tl = field._grown(tl, bw + 1.5 - field._tileMargin, clip);
        let ring = [];
        if (on) {
            const skip = {};
            if (rOn)
                skip[field.rippleBody] = true;
            for (const j of grp)
                skip[j] = true;
            if (nk) {
                skip[nk.sideA] = true;
                skip[nk.sideB] = true;
            }
            ring = field._shadowTilesOf(tl, field._innerRects(out.bodies, skip), clip);
        }
        // The shadow's tiles are slots 0 .. maxShadowTiles - 1 and the shape's the slots after them, a fixed split: a
        // shadow tile that comes or goes moves no other tile's numbers.
        const nt = Math.min(tl.length, field.maxTiles);
        const nr = ring.length;
        const base = field.maxShadowTiles;
        for (let i = 0; i < Math.max(nr, used.ts); i++) {
            const t = i < nr ? ring[i] : null;
            if (t)
                field._put(N.t[i], t.x0, t.y0, t.x1, t.y1);
            else
                field._put(N.t[i], 0, 0, 0, 0);
        }
        for (let i = 0; i < Math.max(nt, used.t); i++) {
            const t = i < nt ? tl[i] : null;
            if (t)
                field._put(N.t[base + i], t.x0, t.y0, t.x1, t.y1);
            else
                field._put(N.t[base + i], 0, 0, 0, 0);
        }
        field._used = { b: n, f: nf, s: ns, t: nt, ts: nr };

        field._bodyCount = n;
        field._filletCount = Math.min(out.fillets.length, field.maxFillets);
        field._filletTotal = out.fillets.length + out.droppedFillets;
        field._seamTotal = out.seams.length + out.droppedSeams;
        field._tileCount = nt;
        field._shadowTileCount = ring.length;
        field._shapeArea = field._areaOf(tl, nt);
        field._shadowArea = field._areaOf(ring, ring.length);
        fx.shadowTiles = ring.length;
        field._updateEdge();
        if (field.auraReach > 0)
            field._updateAura();
        field._radii = out.bodies.map(b => ({ ex: b.ex, ey: b.ey, ix: b.ix, iy: b.iy,
                                              x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1 }));
        field._fillets = out.fillets;
        field._seams = out.seams;
        fx.seamCount = Math.min(out.seams.length, field.maxSeams);
        field._extraTiles = extraTiles;
        field._ripple = { active: rOn, body: rOn ? field.rippleBody : -1, params: rp, frame: null, band: band };
        field._writeLanes();
        if (permChanged)
            field._updateTints();
        if (field.shapeTap)
            field.shapeTap.feed(out);
        if (field.inkWanted) {
            field.inkTiles = { ring: ring, shape: tl, n: nt, ripple: rOn, neck: nk !== null };
            field.inkSerial++;
        }

        if (out.settling && field.settleMs > 0)
            relax.running = true;
        else if (relax.running)
            relax.running = false;
    }

    // ---- THE SHELL'S EDGE: tiles and ink (header) --------------------------------------------------
    // How far fieldShape's tiles reach past a primitive's box: 3 + GooeyGeometry's BLEED.
    readonly property real _tileMargin: 4.5

    function _areaOf(tiles, n) {
        let a = 0;
        for (let i = 0; i < n; i++)
            a += (tiles[i].x1 - tiles[i].x0) * (tiles[i].y1 - tiles[i].y0);
        return a;
    }

    // Tiles grown by g on every side, as the disjoint tiles of their union.
    function _grown(tiles, g, clip) {
        return Geo.tiles(tiles.map(t => ({ x0: t.x0 - g, y0: t.y0 - g, x1: t.x1 + g, y1: t.y1 + g })), clip, field.maxTiles);
    }

    // The boxes of the bodies that are whole inside whatever else the field does: the box less the corner
    // cuts (gooey_field.frag cornerCut: a corner cuts inside its ix x iy rectangle, and nothing when min(ex, ey)
    // or min(ix, iy) is under TINY) and 2 px of antialiasing. `skip` (body index -> true) leaves out the bodies
    // that lose material to the field (the ripple's troughs).
    function _innerRects(bodies, skip) {
        const out = [];
        for (let j = 0; j < bodies.length; j++) {
            const b = bodies[j];
            if (!b.solid || skip[j])
                continue;
            let mx = 0, my = 0;
            for (let c = 0; c < 4; c++)
                if (Math.min(b.ex[c], b.ey[c]) >= 0.05 && Math.min(b.ix[c], b.iy[c]) >= 0.05) {
                    mx = Math.max(mx, b.ix[c]);
                    my = Math.max(my, b.iy[c]);
                }
            const r = { x0: b.x0 + mx + 2, y0: b.y0 + my + 2, x1: b.x1 - mx - 2, y1: b.y1 - my - 2 };
            if (r.x1 > r.x0 && r.y1 > r.y0)
                out.push(r);
        }
        return out;
    }

    // The shadow's tiles: the shape's tiles grown by the reach, the spread and the ring (and a pixel of ramp),
    // less `inner`. Over the budget the cut is dropped, not the shadow: the tiles then cover what the shape
    // covers too, which costs fill rate and nothing else.
    function _shadowTilesOf(shape, inner, clip) {
        const R = field._haloReach + Math.max(0, field._spread) + field._bw + 1;
        const cover = Geo.tiles(shape.map(t => ({ x0: t.x0 - R, y0: t.y0 - R, x1: t.x1 + R, y1: t.y1 + R })),
                                clip, field.maxShadowTiles);
        if (inner.length === 0 || !field.shadowCut)
            return cover;
        // Each inner rect out of every piece it touches, as up to four pieces that share their edges' numbers (the tiles' rule).
        let ring = cover;
        for (const r of inner) {
            const next = [];
            for (const g of ring) {
                if (r.x0 >= g.x1 || r.x1 <= g.x0 || r.y0 >= g.y1 || r.y1 <= g.y0) {
                    next.push(g);
                    continue;
                }
                if (r.y0 > g.y0)
                    next.push({ x0: g.x0, y0: g.y0, x1: g.x1, y1: r.y0 });
                if (r.y1 < g.y1)
                    next.push({ x0: g.x0, y0: r.y1, x1: g.x1, y1: g.y1 });
                const y0 = Math.max(g.y0, r.y0), y1 = Math.min(g.y1, r.y1);
                if (r.x0 > g.x0)
                    next.push({ x0: g.x0, y0: y0, x1: r.x0, y1: y1 });
                if (r.x1 < g.x1)
                    next.push({ x0: r.x1, y0: y0, x1: g.x1, y1: y1 });
            }
            ring = next;
        }
        return ring.length <= field.maxShadowTiles ? ring : cover;
    }

    // The ink the vertex shader hands the tiles (gooey_field.vert): the shadow's colour with its strength as the
    // alpha, the border's colour, and (offset x, offset y, the shadow's reach -- from the surface's edge, so the
    // border sits on the shadow, not in front of its first px -- and the border's width).
    function _updateEdge() {
        const on = field._shadowOn, c = field.shadowColor;
        fx.shadowColor = on ? Qt.rgba(c.r, c.g, c.b, field._strength) : Qt.rgba(0, 0, 0, 0);
        fx.borderColor = field._bw > 0 ? field.borderColor : Qt.rgba(0, 0, 0, 0);
        // (The fall of a shadow that is off is a ramp of no ink; its reach only has to be above 0 where an aura draws on its tiles.)
        const au = field.auraReach > 0 ? field.auraReach + field._bw : 0;
        fx.shadowParam = Qt.vector4d(au, 0, on ? field._reach + field._bw : au, field._bw);
        fx.shadowShape = Qt.vector4d(field._spread, field._softness, field.auraReach > 0 ? field.auraLevel : 0, field.auraTime);
    }

    // The aura's palette, rectangles and group mask (the level and time ride _updateEdge's lanes). The mask is in SLOT bits, like the
    // smooth group's. Called when an aura property changes and after every layout (the slots move); with no aura it writes the
    // zeros the block starts with.
    function _updateAura() {
        const on = field.auraReach > 0;
        const cs = field.auraColors, z = Qt.vector4d(0, 0, 0, 0);
        const maskOf = list => {
            let m = 0;
            if (on)
                for (const j of list)
                    if (j < field._slotOf.length)
                        m |= 1 << field._slotOf[j];
            return m;
        };
        const mask = maskOf(field.auraBodies);
        const col = i => {
            const c = on && cs && i < cs.length ? cs[i] : null;
            return c ? [c.r, c.g, c.b] : [0, 0, 0];
        };
        const c0 = col(0), c1 = col(1), c2 = col(2), c3 = col(3), cy = field.auraCycles;
        const gr = field.auraGroups || [1, 1];
        fx.auraC0 = on ? Qt.vector4d(c0[0], c0[1], c0[2], gr[0]) : z;
        fx.auraC1 = on ? Qt.vector4d(c1[0], c1[1], c1[2], gr[1]) : z;
        fx.auraC2 = on ? Qt.vector4d(c2[0], c2[1], c2[2], cy[1]) : z;
        fx.auraC3 = on ? Qt.vector4d(c3[0], c3[1], c3[2], mask) : z;
        const ref = on ? field.auraRef : null, ra = ref ? ref.a : null, rb = ref ? ref.b : null, rc = ref ? ref.c : null;
        const box = r => r ? Qt.vector4d(r.x0, r.y0, r.x1, r.y1) : z;
        fx.auraRect = box(ra);
        fx.auraFrame = box(rb);
        fx.auraChain = box(rc);
        fx.auraMid = Qt.vector4d(ra ? ra.cx : 0, ra ? ra.cy : 0, rb ? rb.cx : 0, rb ? rb.cy : 0);
        fx.auraChainMid = rc ? Qt.vector4d(rc.cx, rc.cy, 0, maskOf(field.auraChainBodies)) : z;
        const jv = i => {
            const j = on && field.auraJoins ? field.auraJoins[i] : null;
            return j ? Qt.vector4d(j[0], j[1], j[2], j[3]) : z;
        };
        fx.auraJoinA = jv(0);
        fx.auraJoinC = jv(1);
        field._updateEdge();
    }
    onAuraLevelChanged: field._updateEdge()
    onAuraTimeChanged: field._updateEdge()
    onAuraReachChanged: field._updateAura()
    onAuraColorsChanged: field._updateAura()
    // (a group handed over changes these on every frame of its ease: the two lanes alone)
    onAuraGroupsChanged: {
        if (field.auraReach <= 0)
            return;
        const cs = field.auraColors, gr = field.auraGroups || [1, 1];
        const c = i => cs && i < cs.length ? [cs[i].r, cs[i].g, cs[i].b] : [0, 0, 0];
        const c0 = c(0), c1 = c(1);
        fx.auraC0 = Qt.vector4d(c0[0], c0[1], c0[2], gr[0]);
        fx.auraC1 = Qt.vector4d(c1[0], c1[1], c1[2], gr[1]);
    }
    onAuraBodiesChanged: field._updateAura()
    onAuraChainBodiesChanged: field._updateAura()
    onAuraRefChanged: field._updateAura()
    onAuraJoinsChanged: field._updateAura()
    onAuraCyclesChanged: field._updateAura()

    function _put(name, a, b, c, d) {
        const o = field._written[name];
        if (o && o[0] === a && o[1] === b && o[2] === c && o[3] === d)
            return;
        field._written[name] = [a, b, c, d];
        fx[name] = Qt.vector4d(a, b, c, d);
    }

    // g<i> = (the fillet bleed's x, y, the lanes packed in z, w).
    function _writeG(i) {
        const xy = field._gxy[i] || [0, 0];
        const nm = i < fx.packNames.length ? fx.packNames[i] : null;
        const L = field._lanes;
        field._put(field._names.g[i], xy[0], xy[1], nm ? (L[nm[0]] || 0) : 0, nm ? (L[nm[1]] || 0) : 0);
    }

    // The packed lanes from the current state: the group's mask in SLOT bits
    // (only when it has two bodies and a radius), and the ripple's frame at
    // rippleTime (all 0 when it is off, which is the shader's "off").
    function _writeLanes() {
        const L = {};
        const grp = field._groupOf(field._bodyCount);
        if (grp.length) {
            let m = 0;
            for (const j of grp)
                m |= 1 << field._slotOf[j];
            L.smoothMask = m;
            L.smoothK = field.smoothK;
        } else if (field._haloOn) {
            L.smoothK = field.shadowBlend;
        }
        const R = field._ripple;
        if (R.active) {
            const p = R.params, fr = Ripple.frame(p, field.rippleTime);
            R.frame = fr;
            L.rippleMode = 1 + p.face;
            L.rippleCrest = p.crest;
            L.rippleOrders = p.orders;
            L.rippleFloor = p.floor;
            for (let k = 0; k < Ripple.MAX_SOURCES; k++) {
                const v = fr.src[k];
                L["rippleSrc" + k + "q"] = v[0];
                L["rippleSrc" + k + "r"] = v[1];
                L["rippleSrc" + k + "a"] = v[2];
                L["rippleSrc" + k + "p"] = v[3];
            }
            L.rippleInvSigma = fr.invSigma;
            L.rippleK = fr.k;
            L.rippleA2 = fr.a2;
            L.rippleBulgeAt = fr.bulge[0];
            L.rippleBulgeAmp = fr.bulge[1];
            L.rippleBulgeInv = fr.bulge[2];
        }
        const nk = field._neckNow;
        if (nk) {
            // Both bodies, each alone in its accumulator; k only has to be > 0.
            L.smoothMask = (1 << field._slotOf[nk.sideA]) | (1 << field._slotOf[nk.sideB]);
            L.smoothK = 1;
            const v = { neckB: field._slotOf[nk.sideB] + 1, neckAx: nk.a.x, neckAy: nk.a.y, neckMux: nk.mu.x, neckMuy: nk.mu.y,
                        neckLx: nk.l.x, neckLy: nk.l.y, neckMlx: nk.ml.x, neckMly: nk.ml.y,
                        neckRA: nk.rA, neckQU: nk.qU, neckRL: nk.rL, neckQL: nk.qL,
                        neckKA: nk.kA, neckKB: nk.kB, neckKMid: nk.kMid, neckKJoin: nk.kJoin };
            for (const nl of fx.neckLanes)
                L[nl[1]] = v[nl[0]];
        }
        field._lanes = L;
        for (let i = 0; i < fx.packNames.length; i++)
            field._writeG(i);
    }

    // rippleTime moved: the lanes only, unless the ripple starts or ends there
    // (then the slots, the band and the lanes).
    function _updateRipple() {
        if (field._defer > 0) {
            field._dirtyRipple = true;
            return;
        }
        const p = field._ripple.params;
        const on = field._neckNow === null && p !== null && Ripple.active(p, field.rippleTime);
        if (on !== field._ripple.active)
            field._update();
        else if (on)
            field._writeLanes();
    }

    // The neck (header) when both its bodies are drawn, with every radius and
    // blend radius a number (a blend radius under half a pixel is that: smin
    // divides by it), else null.
    function _neckOf(bodies, n) {
        const k = field.neck;
        if (!k || !(k.sideA >= 0 && k.sideA < n && k.sideB >= 0 && k.sideB < n && k.sideA !== k.sideB)
                || !bodies[k.sideA].solid || !bodies[k.sideB].solid)
            return null;
        const num = v => Number(v) || 0;
        const kk = v => Math.max(0.5, num(v));
        const pt = q => ({ x: num(q.x), y: num(q.y) });
        return { sideA: k.sideA, sideB: k.sideB, a: pt(k.a), mu: pt(k.mu), l: pt(k.l), ml: pt(k.ml),
                 rA: Math.max(0, num(k.rA)), qU: Math.max(0, num(k.qU)), rL: Math.max(0, num(k.rL)), qL: Math.max(0, num(k.qL)),
                 kA: kk(k.kA), kB: kk(k.kB), kMid: kk(k.kMid), kJoin: kk(k.kJoin) };
    }

    function _rippleParamsFor(bodies, n) {
        const r = field.rippleBody, face = field.rippleFace;
        if (!(r >= 0 && r < n) || !bodies[r].solid || !(face >= 0 && face <= 3))
            return null;
        return Ripple.params(field.rippleParams, Ripple.geometry(bodies[r], face),
                             [field.rippleSource0, field.rippleSource1, field.rippleSource2]);
    }

    // The band the crests can reach: the bar's span along the face, from the
    // crest bound past the face to the bar's far side, grown by the tiles' own
    // margin (GooeyGeometry.js: 3 + BLEED) and clipped to the field.
    function _rippleBand(b, p) {
        const M = 4.5, c = p.crest;
        const r = [{ x0: b.x0 - M, y0: b.y0 - c - M, x1: b.x1 + M, y1: b.y1 + M },
                   { x0: b.x0 - M, y0: b.y0 - M, x1: b.x1 + M, y1: b.y1 + c + M },
                   { x0: b.x0 - c - M, y0: b.y0 - M, x1: b.x1 + M, y1: b.y1 + M },
                   { x0: b.x0 - M, y0: b.y0 - M, x1: b.x1 + c + M, y1: b.y1 + M }][p.face];
        const x0 = Math.max(0, r.x0), y0 = Math.max(0, r.y0);
        const x1 = Math.min(field.width, r.x1), y1 = Math.min(field.height, r.y1);
        return x1 > x0 && y1 > y0 ? { x0: x0, y0: y0, x1: x1, y1: y1 } : null;
    }

    // The bodies (indices into bodies) the smooth group blends: only when it
    // has two of them and a radius, which is also when the shader is told.
    function _groupOf(n) {
        const out = [];
        for (let j = 0; j < n && j < field.maxBodies; j++)
            if (field.smoothMask & (1 << j))
                out.push(j);
        return out.length >= 2 && field.smoothK > 0 ? out : [];
    }

    // `band` less the union of `tiles` (disjoint rects), as disjoint rects: a
    // sweep over y at every tile edge inside the band, the free x-intervals of
    // each slab, slabs with the same intervals merged. The shared edges are the
    // tiles' own numbers, so the rasteriser hands each pixel to one of them.
    function _minusTiles(tiles, band) {
        const ys = [band.y0, band.y1];
        for (const t of tiles) {
            if (t.y0 > band.y0 && t.y0 < band.y1)
                ys.push(t.y0);
            if (t.y1 > band.y0 && t.y1 < band.y1)
                ys.push(t.y1);
        }
        ys.sort((a, b) => a - b);
        const slabs = [];
        for (let e = 0; e + 1 < ys.length; e++) {
            const ya = ys[e], yb = ys[e + 1];
            if (!(yb > ya))
                continue;
            const iv = [];
            for (const t of tiles)
                if (t.y0 <= ya && t.y1 >= yb && t.x1 > band.x0 && t.x0 < band.x1)
                    iv.push([Math.max(band.x0, t.x0), Math.min(band.x1, t.x1)]);
            iv.sort((a, b) => a[0] - b[0]);
            const free = [];
            let x = band.x0;
            for (const v of iv) {
                if (v[0] > x)
                    free.push([x, v[0]]);
                x = Math.max(x, v[1]);
            }
            if (x < band.x1)
                free.push([x, band.x1]);
            const last = slabs.length ? slabs[slabs.length - 1] : null;
            if (last && last.y1 === ya && last.free.length === free.length
                    && last.free.every((f, k) => f[0] === free[k][0] && f[1] === free[k][1]))
                last.y1 = yb;
            else
                slabs.push({ y0: ya, y1: yb, free: free });
        }
        const out = [];
        for (const sl of slabs)
            for (const f of sl.free)
                out.push({ x0: f[0], y0: sl.y0, x1: f[1], y1: sl.y1 });
        return out;
    }

    function _updateTints() {
        const ids = [-1, -1, -1];
        const cols = ["transparent", "transparent", "transparent"];
        const used = [];
        let k = 0;
        const list = field.tints || [];
        for (let i = 0; i < list.length && k < 3; i++) {
            const t = list[i];
            const b = t ? Number(t.body) : -1;
            if (!(b >= 0 && b < field.maxBodies) || !t.color || !(t.color.a > 0) || used.indexOf(b) >= 0)
                continue;
            // The shader's slot for that body (the rippling body is in slot 0).
            ids[k] = b < field._slotOf.length ? field._slotOf[b] : b;
            used.push(b);
            cols[k] = t.color;
            k++;
        }
        fx.tintIdA = ids[0];
        fx.tintIdB = ids[1];
        fx.tintIdC = ids[2];
        fx.tintA = cols[0];
        fx.tintB = cols[1];
        fx.tintC = cols[2];
        fx.tintReach = Math.max(0.5, field.tintBlend);
    }

    ShaderEffect {
        id: fx
        anchors.fill: parent
        // One column, 4*96-1 rows (the shadow's 48 tiles and the shape's 48): see
        // gooey_field.vert for how the rows become tiles.
        mesh: GridMesh {
            resolution: Qt.size(1, 383)
        }
        vertexShader: "shaders/gooey_field.vert.qsb"
        fragmentShader: "shaders/gooey_field.frag.qsb"

        property color fieldColor: field.color
        property real bodyCount: field._bodyCount
        // n + the sky's fillets / 64 (THE SKY in the shadow, layout): the shape's int(x + 0.5) reads n, a shadow tile the fraction.
        property real filletCount: field._filletCount + field._skyFillets / 64
        property real seamCount: 0
        property real tileCount: field._tileCount
        property real showTiles: field.showTiles ? 1 : 0

        // @@PROPS-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)
        property vector4d b0
        property vector4d b1
        property vector4d b2
        property vector4d b3
        property vector4d b4
        property vector4d b5
        property vector4d b6
        property vector4d b7
        property vector4d b8
        property vector4d b9
        property vector4d b10
        property vector4d b11
        property vector4d x0
        property vector4d x1
        property vector4d x2
        property vector4d x3
        property vector4d x4
        property vector4d x5
        property vector4d x6
        property vector4d x7
        property vector4d x8
        property vector4d x9
        property vector4d x10
        property vector4d x11
        property vector4d y0
        property vector4d y1
        property vector4d y2
        property vector4d y3
        property vector4d y4
        property vector4d y5
        property vector4d y6
        property vector4d y7
        property vector4d y8
        property vector4d y9
        property vector4d y10
        property vector4d y11
        property vector4d u0
        property vector4d u1
        property vector4d u2
        property vector4d u3
        property vector4d u4
        property vector4d u5
        property vector4d u6
        property vector4d u7
        property vector4d u8
        property vector4d u9
        property vector4d u10
        property vector4d u11
        property vector4d v0
        property vector4d v1
        property vector4d v2
        property vector4d v3
        property vector4d v4
        property vector4d v5
        property vector4d v6
        property vector4d v7
        property vector4d v8
        property vector4d v9
        property vector4d v10
        property vector4d v11
        property vector4d f0
        property vector4d f1
        property vector4d f2
        property vector4d f3
        property vector4d f4
        property vector4d f5
        property vector4d f6
        property vector4d f7
        property vector4d f8
        property vector4d f9
        property vector4d f10
        property vector4d f11
        property vector4d f12
        property vector4d f13
        property vector4d f14
        property vector4d f15
        property vector4d f16
        property vector4d f17
        property vector4d f18
        property vector4d f19
        property vector4d f20
        property vector4d f21
        property vector4d f22
        property vector4d f23
        property vector4d k0
        property vector4d k1
        property vector4d k2
        property vector4d k3
        property vector4d k4
        property vector4d k5
        property vector4d k6
        property vector4d k7
        property vector4d k8
        property vector4d k9
        property vector4d k10
        property vector4d k11
        property vector4d k12
        property vector4d k13
        property vector4d k14
        property vector4d k15
        property vector4d k16
        property vector4d k17
        property vector4d k18
        property vector4d k19
        property vector4d k20
        property vector4d k21
        property vector4d k22
        property vector4d k23
        property vector4d g0
        property vector4d g1
        property vector4d g2
        property vector4d g3
        property vector4d g4
        property vector4d g5
        property vector4d g6
        property vector4d g7
        property vector4d g8
        property vector4d g9
        property vector4d g10
        property vector4d g11
        property vector4d g12
        property vector4d g13
        property vector4d g14
        property vector4d g15
        property vector4d g16
        property vector4d g17
        property vector4d g18
        property vector4d g19
        property vector4d g20
        property vector4d g21
        property vector4d g22
        property vector4d g23
        property vector4d s0
        property vector4d s1
        property vector4d s2
        property vector4d s3
        property vector4d s4
        property vector4d s5
        property vector4d s6
        property vector4d s7
        property vector4d s8
        property vector4d s9
        property vector4d s10
        property vector4d s11
        property vector4d s12
        property vector4d s13
        property vector4d s14
        property vector4d s15
        property vector4d s16
        property vector4d s17
        property vector4d s18
        property vector4d s19
        property vector4d s20
        property vector4d s21
        property vector4d s22
        property vector4d s23
        property vector4d t0
        property vector4d t1
        property vector4d t2
        property vector4d t3
        property vector4d t4
        property vector4d t5
        property vector4d t6
        property vector4d t7
        property vector4d t8
        property vector4d t9
        property vector4d t10
        property vector4d t11
        property vector4d t12
        property vector4d t13
        property vector4d t14
        property vector4d t15
        property vector4d t16
        property vector4d t17
        property vector4d t18
        property vector4d t19
        property vector4d t20
        property vector4d t21
        property vector4d t22
        property vector4d t23
        property vector4d t24
        property vector4d t25
        property vector4d t26
        property vector4d t27
        property vector4d t28
        property vector4d t29
        property vector4d t30
        property vector4d t31
        property vector4d t32
        property vector4d t33
        property vector4d t34
        property vector4d t35
        property vector4d t36
        property vector4d t37
        property vector4d t38
        property vector4d t39
        property vector4d t40
        property vector4d t41
        property vector4d t42
        property vector4d t43
        property vector4d t44
        property vector4d t45
        property vector4d t46
        property vector4d t47
        property vector4d t48
        property vector4d t49
        property vector4d t50
        property vector4d t51
        property vector4d t52
        property vector4d t53
        property vector4d t54
        property vector4d t55
        property vector4d t56
        property vector4d t57
        property vector4d t58
        property vector4d t59
        property vector4d t60
        property vector4d t61
        property vector4d t62
        property vector4d t63
        property vector4d t64
        property vector4d t65
        property vector4d t66
        property vector4d t67
        property vector4d t68
        property vector4d t69
        property vector4d t70
        property vector4d t71
        property vector4d t72
        property vector4d t73
        property vector4d t74
        property vector4d t75
        property vector4d t76
        property vector4d t77
        property vector4d t78
        property vector4d t79
        property vector4d t80
        property vector4d t81
        property vector4d t82
        property vector4d t83
        property vector4d t84
        property vector4d t85
        property vector4d t86
        property vector4d t87
        property vector4d t88
        property vector4d t89
        property vector4d t90
        property vector4d t91
        property vector4d t92
        property vector4d t93
        property vector4d t94
        property vector4d t95
        property real tintIdA: -1
        property real tintIdB: -1
        property real tintIdC: -1
        property color tintA: "transparent"
        property color tintB: "transparent"
        property color tintC: "transparent"
        property real tintReach: 1
        property vector4d auraC0
        property vector4d auraC1
        property vector4d auraC2
        property vector4d auraC3
        property vector4d auraRect
        property vector4d auraFrame
        property vector4d auraChain
        property vector4d auraMid
        property vector4d auraChainMid
        property vector4d auraJoinA
        property vector4d auraJoinC
        property real shadowTiles: 0
        property color shadowColor: "transparent"
        property color borderColor: "transparent"
        property vector4d shadowParam
        property vector4d shadowShape: Qt.vector4d(0, 1, 0, 0)
        readonly property var packNames: [["smoothMask", "smoothK"], ["rippleMode", "rippleCrest"], ["rippleOrders", "rippleFloor"], ["rippleSrc0q", "rippleSrc0r"], ["rippleSrc0a", "rippleSrc0p"], ["rippleSrc1q", "rippleSrc1r"], ["rippleSrc1a", "rippleSrc1p"], ["rippleSrc2q", "rippleSrc2r"], ["rippleSrc2a", "rippleSrc2p"], ["rippleInvSigma", "rippleK"], ["rippleA2", "rippleBulgeAt"], ["rippleBulgeAmp", "rippleBulgeInv"]]
        readonly property var neckLanes: [["neckB", "rippleCrest"], ["neckAx", "rippleOrders"], ["neckAy", "rippleFloor"], ["neckMux", "rippleSrc0q"], ["neckMuy", "rippleSrc0r"], ["neckLx", "rippleSrc0a"], ["neckLy", "rippleSrc0p"], ["neckMlx", "rippleSrc1q"], ["neckMly", "rippleSrc1r"], ["neckRA", "rippleSrc1a"], ["neckQU", "rippleSrc1p"], ["neckRL", "rippleSrc2q"], ["neckQL", "rippleSrc2r"], ["neckKA", "rippleSrc2a"], ["neckKB", "rippleSrc2p"], ["neckKMid", "rippleInvSigma"], ["neckKJoin", "rippleK"]]
        // @@PROPS-END
    }
}
