pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// ShadowBox.qml
//
// A rounded box carved into its surface: a light bevel rim outside the edge,
// an inset shadow inside it, a flat background within. Content goes inside.
//
// Drawn by a fragment shader from a signed distance field (see
// shaders/shadow_box.frag), not by a Canvas painting ~25 concentric rings,
// which has three costs the shader does not:
//
//   - every repaint is CPU work, and with Cooperative rendering it runs on
//     the render thread inside the frame. A box wrapped round content that
//     resizes constantly repaints constantly.
//   - the result is a texture at the item's own resolution. Under a scale
//     transform it goes soft, and at fractional item sizes it is resampled
//     by a hair, which makes two boxes meant to share an edge disagree about
//     where that edge is. Ring strokes also over-accumulate on curved
//     corners, so a narrow tint looks stronger there than along a straight
//     edge.
//   - a freshly created canvas can be presented before its first paint has
//     landed.
//
// The shader evaluates per device pixel, so none of those apply, and a
// progress change is a uniform update rather than a repaint.
//
// `stepSize` is kept for compatibility and does nothing: there are no steps.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // PUBLIC API
    // ======================================================================

    // Sizes
    property real baseWidth: 100
    property real baseHeight: 100
    property real baseRadius: 10
    // Per-corner overrides. -1 means "use baseRadius". Allows asymmetric shapes
    // (e.g. the charge-limit-bar fill halves) while keeping backward compat.
    property real topLeftRadius: -1
    property real topRightRadius: -1
    property real bottomRightRadius: -1
    property real bottomLeftRadius: -1
    // If true, each corner radius is limited to width/2 or height/2
    property bool limitRadius: true
    // Smoothness profile: 1.0 is a standard arc, >1.0 approaches a squircle.
    // 0.55228 is the magic number for a circular bezier.
    property real curveProfile: 1.0

    // Colors
    property color surfaceColor: "#EAEDF5"       // Outside background
    property color bevelColor: "#EEF0F7"         // Outer peak of the bevel
    property color shadowColor: "#CED1D7"        // Deepest part of the shadow
    property color backgroundColor: "#E1E4EB"    // Inside main color

    // Depths
    property real bevelWidth: 2
    property real shadowWidth: 3

    // Stands proud of the surface instead of being carved into it. The
    // bands trade sides: the shadow falls OUTSIDE the edge as a drop shadow
    // (`shadowWidth` wide on the surface, strongest at the edge) and the
    // bevel becomes a highlight INSIDE it (`bevelWidth` wide, brightest at
    // the edge, easing into `backgroundColor`, which is then the plateau).
    // Same colours and easings as the carved box, so a field and a button
    // side by side read as one surface -- groove and plateau -- with the
    // spreads tuned separately, since shadow and highlight do not carry the
    // same strength in the world either. Progress tinting is a carved-box
    // thing and is ignored here.
    property bool raised: false

    // Raised only: blend the drop shadow to TRANSPARENT instead of to
    // `surfaceColor`. Alpha-compositing the same falloff over a ground that
    // IS surfaceColor is the same arithmetic -- src*s + surface*(1-s)
    // either way -- so a resting box is pixel-identical; the difference is
    // that anything sliding BENEATH the box shows through the falloff
    // instead of meeting an opaque surface-coloured apron (the sidebar's
    // burger over the expanding "New chat" button is the case in point).
    // Opt-in, because the opaque band is also what lets a raised box
    // sit on a ground that is NOT surfaceColor without showing it.
    property bool shadowToAlpha: false

    // Scale for density
    property real sizeScale: 1.0

    implicitWidth: baseWidth * sizeScale
    implicitHeight: baseHeight * sizeScale

    // Easings (CSS cubic-bezier format [x1, y1, x2, y2])
    property var bevelEasing: [0.15, 0.1, 0.25, 1.0]
    property var shadowEasing: [0.15, 0.60, 0.35, 1.0]

    // Quality. Kept for API compatibility; the shader has no steps.
    property real stepSize: 0.25

    // ======================================================================
    // SHADOW SHAPE
    //
    // The inset is described by three numbers, not one:
    //
    //   width    how far it reaches inward, in px.   -- geometry
    //   edge     how strong it is AT the very edge.  -- depth
    //   falloff  how that strength decays inward.    -- character
    //
    // Width and falloff are not the same control, which is worth stating
    // because they look alike from the outside. Width says where the shadow
    // stops; falloff says how it gets there. A wide shadow with a high
    // falloff still hugs the edge and clears the middle; a narrow one with a
    // low falloff is a flat band that stops abruptly.
    //
    // Falloff is an exponent on the remaining strength: 1 leaves the easing
    // curve alone, above 1 pulls the shadow tight against the edge, below 1
    // spreads it out and lets it linger.
    //
    // The defaults are the plain box's.
    // ======================================================================
    property real shadowEdgeAlpha: 1.0
    property real shadowFalloff:   1.0

    // ======================================================================
    // PROGRESS TINT  (opt-in; -1 leaves the box untinted)
    //
    // Colours the inset shadow from the LEFT up to a boundary, leaving the
    // rest at the normal shadow colour. The boundary sweeps left to right as
    // the fraction grows, so a container can report progress without
    // carrying a separate bar.
    //
    // Only the shadow is affected. The bevel, the background and the geometry
    // are the plain box's, which keeps this readable as the same object
    // rather than a differently-styled one.
    // ======================================================================
    property real  shadowProgress: -1
    property color shadowProgressColor: "#4480F4"

    // ---- A BAND INSTEAD OF A FILL ---------------------------------------
    //
    // Supply a SECOND fraction and the tint becomes a band: `shadowProgress`
    // is then its leading edge and this is its trailing one. Negative means
    // no tail: the fill above.
    //
    // It exists because a fill is a claim. A box reporting a real fraction --
    // a category's packages, a track's position -- fills, and the reading is
    // "this far". A box that only knows work is happening cannot fill: it
    // reaches the end and has to be cut back to nothing, which is a claim
    // that something restarted. The band crosses and leaves instead, which is
    // the classic indeterminate bar, and it says "still working" without ever
    // saying how far.
    //
    // The FLOOR (`shadowProgressMinPx`) belongs to the LEAD alone: at both
    // fractions 0 the band is exactly the parked idle mark this file has
    // always drawn, and the tail must be free to sit outside the left edge so
    // its own crossover never eats into that mark. Sweep.js is where the two
    // fractions come from.
    //
    // AND THE FLOOR IS THE RESTING STATE'S, NOT THE BAND'S. It is what a
    // PARKED box shows; a host that leaves it in place while a band is
    // running gets a wave born part-grown -- at every wrap the lead drops
    // from off the right end to the mark in ONE frame (26 px of colour in
    // 16 ms, measured) and then stands still there until the sweep catches
    // it up. A host that runs a band withdraws the floor once the first trip
    // is over, by passing 0 (not a new sentinel: `_floorX` below already
    // reads `> 0`), and does it AT THE WRAP, where the lead is at fraction 0
    // and nothing is painted on either side of the change.
    //
    // Which is the general law for everything below, because this file draws
    // one frame at a time and knows nothing of states: THE GEOMETRY AND THE
    // COLOUR MAY ONLY BE SWAPPED ON A FRAME WHERE THE INK IS ZERO. Where a
    // swap cannot be timed to a zero of its own -- a band stopping, a box
    // turning red -- the host takes the ink to zero first: one eased
    // fraction mixing `shadowProgressColor` toward `shadowColor` (Mix.js,
    // never a Behavior on a colour), the state swapped at 0, the fraction
    // back to 1. LlmTurn is the worked example.
    property real  shadowProgressTail: -1

    // The coloured region is never narrower than this many px (times
    // sizeScale), whatever the fraction says. This is the idle mark: a box
    // parked at zero still shows a constant-width sliver of its colour at
    // the left, the way the old accent stripe did -- and because it is in
    // px rather than a fraction of the width, it is the same mark in a wide
    // list and a narrow one. It is a RESTING-state element: see
    // `shadowProgressTail` for why a running band withdraws it.
    property real  shadowProgressMinPx: 0

    // ---- Idle and active shapes -----------------------------------------
    //
    // A box showing progress has two looks, and it moves between them as a
    // function of PROGRESS, never of time. Driving the blend on a timer would
    // decouple the look from the thing it describes -- the box would still be
    // relaxing after progress had stopped, and would lag behind a jump. On
    // progress the shape IS a readout, the same as the boundary position.
    //
    // THE DEFAULTS ARE THE SYSTEM UPDATE'S CATEGORY HEADER, as its mockup
    // (mockups/system_update.qml) hands them to this file: a host that sets
    // nothing but `shadowProgress` and its colour -- and the idle mark, if it
    // has one -- gets that look, not a thinner cousin of it. Defaults of
    // "whatever the plain box is" (the box's own depth, strength and falloff,
    // and a 1.5 px idle feather) would, on a carved card's 3 px inset, draw
    // the hue as a hard coloured LINE round the corner rather than a shade in
    // the carve, and every host that did not restate the header's numbers
    // would wear that line.
    //
    //   depth      7.5 parked, 7 under way. The hue only reads as a shade in
    //              the inset when it has room to fall off; at 3 px it is a
    //              line. It never goes SHALLOWER than the box's own inset:
    //              the tint is a colour on the carve, and a box that is
    //              carved deeper keeps its depth -- hence max(shadowWidth, n).
    //              A box that is carved SHALLOWER is deepened while it shows
    //              progress, all round, because the shader has one inset per
    //              box; a host that switches progress on and off (-1 <-> a
    //              fraction) therefore moves the carve at that switch and
    //              times it the way it times the colour (see
    //              `shadowProgressTail`) or restates these two.
    //   strength   0.55 of the box's own edge strength parked, all of it
    //              under way: a resting mark is a hint, a running one is the
    //              news. RELATIVE to `shadowEdgeAlpha`, so a host that asked
    //              for a fainter inset gets a proportionally fainter tint
    //              rather than having its choice overruled.
    //   falloff    0.9 of the box's own parked (the colour lingers a little
    //              further in), the box's own under way. Relative, likewise.
    //   feather    12 px both ways: the colour gives way to the grey as a
    //              glow, parked or moving, never as a cut.
    //
    // A BAND HAS NO PARKED SHAPE. With a tail (`shadowProgressTail` >= 0)
    // the parked depth, strength and falloff default to the under-way ones.
    // Those three are CARVE-WIDE -- they draw the grey inset all round the
    // box, not just the hue -- and a band's lead wraps from 1 back to 0 at
    // the end of every trip, so a carve that blended on the lead would jump
    // from the running shape to the parked one in that frame and ease back
    // over the next third of the trip: the whole inset pulsing once a trip.
    // The feathers blend as they do for a fill; they only shape the hue's two edges,
    // which at the wrap are both outside the box.
    //
    // Feathers are in px (times sizeScale), like the idle mark, for the same
    // reason: a fade that is a fraction of the width is tight in a narrow
    // list and loose in a wide one. The idle mark itself stays opt-in
    // (`shadowProgressMinPx` 0): whether a box HAS a resting mark is a fact
    // about the host, not a look.
    property real progressIdleFeatherPx:   12
    property real progressActiveFeatherPx: 12
    property real progressIdleWidth:       shadowProgressTail >= 0 ? progressActiveWidth
                                           : Math.max(shadowWidth, 7.5)
    property real progressActiveWidth:     Math.max(shadowWidth, 7)
    property real progressIdleEdgeAlpha:   shadowProgressTail >= 0 ? progressActiveEdgeAlpha
                                           : 0.55 * shadowEdgeAlpha
    property real progressActiveEdgeAlpha: shadowEdgeAlpha
    property real progressIdleFalloff:     shadowProgressTail >= 0 ? progressActiveFalloff
                                           : 0.9 * shadowFalloff
    property real progressActiveFalloff:   shadowFalloff
    // Progress at which the idle shape has fully given way to the active
    // one. The blend starts where the sweep leaves the idle mark.
    property real progressBlendEnd: 0.32

    readonly property bool _hasProgress: shadowProgress >= 0

    // Content alias
    default property alias content: container.data

    // ======================================================================
    // INTERNAL CALCS
    // ======================================================================
    readonly property real _bw: bevelWidth * sizeScale
    // Room outside the item for whatever band sits outside the edge.
    readonly property real _margin: (raised ? _sw : _bw) + 1
    readonly property real _effRadius: limitRadius ? Math.min(baseRadius * sizeScale, width/2, height/2) : baseRadius * sizeScale
    function _rFor(r) {
        const base = r >= 0 ? r * sizeScale : _effRadius;
        return limitRadius ? Math.min(base, width/2, height/2) : base;
    }
    readonly property real _rTL: _rFor(topLeftRadius)
    readonly property real _rTR: _rFor(topRightRadius)
    readonly property real _rBR: _rFor(bottomRightRadius)
    readonly property real _rBL: _rFor(bottomLeftRadius)

    // Corner exponent for the shader, matched to a cubic-bezier corner with
    // control handles at k = 0.55228 * curveProfile: the point where such a
    // curve crosses the 45-degree line sits at (4 + 3k) / 8 of the radius
    // from the corner's centre. A superellipse |x|^n + |y|^n = r^n crosses at
    // 2^(-1/n), so matching the two fixes n. curveProfile = 1
    // gives n = 2 to five decimals: an exact circle.
    // Capped at 64: by then the corner is already a square to within a
    // pixel, and the mapping otherwise runs away toward infinity as the
    // profile approaches the value where the bezier's midpoint reaches the
    // corner itself (about 2.4).
    readonly property real _cornerN: {
        if (Math.abs(curveProfile - 1.0) < 1e-3) return 2.0;
        const k = 0.55228 * curveProfile;
        const m = Math.max(0.05, Math.min(0.999, (4 + 3 * k) / 8));
        return Math.min(64, -1 / Math.log2(m));
    }

    // ---- progress geometry ----
    readonly property real _p: Math.max(0, Math.min(1, shadowProgress))
    readonly property real _idleHalf:   Math.max(0.25, progressIdleFeatherPx   * sizeScale)
    readonly property real _activeHalf: Math.max(0.25, progressActiveFeatherPx * sizeScale)
    // With no idle mark asked for, the floor sits one half-feather OUTSIDE
    // the box, where the sweep itself starts -- so progress 0 shows no
    // colour at all. Flooring at 0 instead would put the crossover's centre
    // on the edge and tint the first pixel and a half at half strength.
    readonly property real _floorX: shadowProgressMinPx > 0
        ? shadowProgressMinPx * sizeScale : -_idleHalf
    // Progress at which the fraction-driven boundary reaches the idle mark:
    // below it the mark holds the boundary in place, above it the sweep
    // takes over. The blend to the active shape starts here.
    readonly property real _pFloor: (_floorX + _idleHalf) / Math.max(1, width + 2 * _idleHalf)
    readonly property real _blend: !_hasProgress ? 0
        : Math.max(0, Math.min(1, (_p - _pFloor) / Math.max(0.0001, progressBlendEnd - _pFloor)))
    function _mix(a, b) { return a + (b - a) * _blend; }

    readonly property real _featherHalf: _mix(_idleHalf, _activeHalf)
    // The sweep runs from one half-feather BEFORE the left edge to one
    // half-feather PAST the right, so the crossover sits entirely outside
    // the box at both extremes: 0 shows no colour and 1 shows nothing else.
    readonly property real _boundaryX: Math.max(
        -_featherHalf + _p * (width + 2 * _featherHalf), _floorX)
    readonly property bool _hasTail: _hasProgress && shadowProgressTail >= 0
    // The same sweep, NOT floored: see `shadowProgressTail`.
    readonly property real _tailX:
        -_featherHalf + Math.max(0, Math.min(1, shadowProgressTail)) * (width + 2 * _featherHalf)

    readonly property real _sw: (_hasProgress
        ? _mix(progressIdleWidth, progressActiveWidth) : shadowWidth) * sizeScale
    readonly property real _edgeAlpha: _hasProgress
        ? _mix(progressIdleEdgeAlpha, progressActiveEdgeAlpha) : shadowEdgeAlpha
    readonly property real _falloff: Math.max(0.01, _hasProgress
        ? _mix(progressIdleFalloff, progressActiveFalloff) : shadowFalloff)

    ShaderEffect {
        id: fx
        anchors.fill: parent
        // Grown past the item so the bevel, which sits OUTSIDE the box's
        // edge, has room to draw -- plus one pixel for its antialiasing.
        anchors.margins: -root._margin
        fragmentShader: "shaders/shadow_box.frag.qsb"

        // Uniforms, by name. Padding and offsets come from the compiled
        // shader's reflection data, so the order here is immaterial.
        property real margin: root._margin
        property real boxW: root.width
        property real boxH: root.height
        property vector4d radii: Qt.vector4d(root._rTL, root._rTR, root._rBR, root._rBL)
        property real bevelWidth: root._bw
        property real shadowWidth: root._sw
        property real cornerN: root._cornerN
        property real edgeAlpha: root._edgeAlpha
        property real falloff: root._falloff

        property color surfaceColor: root.surfaceColor
        property color bevelColor: root.bevelColor
        property color shadowColor: root.shadowColor
        property color backgroundColor: root.backgroundColor
        property vector4d bevelEasing: Qt.vector4d(
            root.bevelEasing[0], root.bevelEasing[1], root.bevelEasing[2], root.bevelEasing[3])
        property vector4d shadowEasing: Qt.vector4d(
            root.shadowEasing[0], root.shadowEasing[1], root.shadowEasing[2], root.shadowEasing[3])

        property real hasProgress: root._hasProgress && !root.raised ? 1 : 0
        property real raised: root.raised ? 1 : 0
        property real shadowToAlpha: root.shadowToAlpha ? 1 : 0
        property real boundaryX: root._boundaryX
        property real featherHalf: root._featherHalf
        property color progressColor: root.shadowProgressColor
        property real hasTail: root._hasTail && !root.raised ? 1 : 0
        property real tailX: root._tailX
    }

    Item {
        id: container
        anchors.fill: parent
    }
}
