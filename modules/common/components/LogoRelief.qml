pragma ComponentBehavior: Bound

import QtQuick
import "../theme"

// =============================================================================
// LogoRelief.qml
//
// A logo carved into the surface it sits on, with the shell's own bevel and
// inset shadow following the logo's real contour.
//
// COST
// ----
// One `Image` (a texture provider -- no render pass) and one `ShaderEffect`:
// a single textured quad, one texture fetch per fragment. Nothing is
// recomputed when nothing changes; a theme switch writes four colour uniforms
// and re-renders the quad, and does not touch the texture at all.
//
// The expensive half of "a carve that follows a contour" -- the distance
// transform, its gradient, and the island rule that keeps a thin stroke from
// being swallowed by its own shadow -- is done ONCE, offline, by
// tools/bake_logo_relief.py, and committed as the texture in assets/logos/.
// See shaders/logo_relief.frag for what the three channels carry.
//
// This is deliberately not a blur-based carve. Blurring the icon into a mask
// and estimating distance from the blur's own gradient is fine for a 16 px
// glyph with an even stroke and wrong for a logo: past
// about one blur radius the estimate saturates, so a mark with both a solid
// body and a hairline gets a correct carve on the body and a flat dark smear
// on the hairline. The baked field has no such horizon, and it costs a render
// pass less at runtime.
//
// USE
//     LlmModelLogos { id: logos }
//     LogoRelief {
//         source: logos.assetFor(selectedModel)
//         logoSize: 170
//     }
// `source` empty or unloadable -> the item reports zero size, is invisible,
// and draws nothing, so a model with no mark simply has no logo and a Column
// closes back up around it.
//
// PRESENCE
// A change of `source` after creation does not pop. `presence` is ONE eased
// fraction, 0 = absent, 1 = shown: the item's opacity IS it, and a host that
// lays anything out around the mark reads the same fraction for its slot
// (LlmTranscript's empty state: the two lines translate on `presence` while
// the image fades on it). A swap from one mark to another is instant, as a
// text swap is. The first arrival is instant too.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // PUBLIC API
    // ======================================================================

    // The baked texture (opaque RGB). Empty is legal and means "no mark".
    property url source

    // How wide the MARK is on screen, in px. That IS the item's size: the
    // baked texture is a little larger, because the bake leaves a margin round
    // the mark for the outer bevel to live in, and the shader is grown past
    // the item by exactly that margin -- the same arrangement ShadowBox uses
    // to draw a bevel outside its own edge.
    //
    // Sizing by the mark rather than by the texture is what makes 170 mean the
    // same thing for every asset, and what makes a gap under the logo in a
    // Column the gap a reader actually sees.
    property real logoSize: 170
    // The fraction of the baked texture the mark occupies. MUST match the
    // bake: 1 - 2 * (bake_logo_relief.py --pad), which the script prints.
    property real markFraction: 0.82

    // Colours. Defaults are the carved-into-a-list-box case, which is where
    // the empty state lives; a host on a different ground overrides
    // `surfaceColor` to that ground.
    property color surfaceColor: Theme.listBox     // the ground it is cut into
    property color bevelColor: Theme.bevel         // rim outside, lit wall inside
    property color shadowColor: Theme.border       // deepest part of the inset
    property color bodyColor: Theme.panelSunk      // the floor of the carve

    // Carve depth, as a fraction of what was baked. 1 uses the bake; below 1
    // narrows the inset exactly (the ramp is remapped); above 1 clamps, since
    // no distance beyond the baked band was stored.
    property real depthScale: 1.0
    // Outer bevel width, as a fraction of the carve depth: the rim is a hint,
    // the inset is the statement. 0.15 of an 11 px wall is a 1.5 px rim, which is the container
    // ShadowBox's own bevel against its 3 px inset, so the mark and the box it
    // sits in carry the same rim.
    property real bevelWidth: 0.15

    // The inset's shape, ShadowBox's numbers: how strong it is at the edge,
    // and how fast that decays inward. Falloff 1 IS the box's curve: the wall is
    // within a level of the floor 5 px in (7 at 0.6, a shadow that takes too long
    // to fade; measured, qwen, light mode) and still reads as carved, not outlined.
    property real edgeAlpha: 1.0
    property real falloff: 1.0

    // How much of the inset is isotropic (the box's own band) rather than lit
    // from a direction. 1 is exactly ShadowBox's rim all the way round, which
    // reads as an outline; 0 is pure lambert, which loses the contour where a
    // wall runs along the light. The default keeps the contour legible and
    // still reads as relief.
    property real ambient: 0.42
    // Strength of the lit wall relative to the shadowed one. Light and shadow
    // do not carry the same weight in the world either -- ShadowBox tunes the
    // same asymmetry through its two spreads.
    property real highlightGain: 0.85
    // Degrees clockwise from straight up. The shell's light comes from above.
    property real lightAngle: 0

    property var bevelEasing: [0.15, 0.1, 0.25, 1.0]
    property var shadowEasing: [0.15, 0.60, 0.35, 1.0]

    // True once the texture is up and the relief is actually being drawn.
    readonly property bool ready: tex.status === Image.Ready

    // ---- Presence: ONE clock for arriving and leaving --------------------
    //
    // 0 = no mark, 1 = the mark, eased between them over `presenceMs` with
    // the shell's resize easing (OutCubic): a mark arriving IS the empty
    // state resizing. The item's OPACITY is this fraction, and a host that
    // lays anything out around the mark reads the same fraction for its
    // slot, so the text's translation and the image's fade are one motion
    // by construction and cannot drift or be tuned apart -- one property,
    // two readers. Never a Behavior per consumer.
    //
    // Three things make it a fade rather than a pop:
    //   - the texture is HELD while the mark leaves: `_shown` keeps the last
    //     real source, so the quad has something to fade out;
    //   - a swap from one mark to another is instant, as a text swap is:
    //     presence stays 1 and the texture is replaced synchronously, so no
    //     frame is drawn without a mark (see the Image below);
    //   - the FIRST arrival is instant: a popup that opens on a model with a
    //     mark shows it, it does not watch it fade in. Only a change after
    //     creation animates.
    readonly property real presence: root._presence
    property int presenceMs: 260

    // The last real source: what the quad shows, held through a fade-out.
    property url _shown
    // A mark should be showing: there is a source, and it loaded.
    readonly property bool _wanted:
        root.source.toString().length > 0 && tex.status === Image.Ready
    property real _presence: root._wanted ? 1 : 0
    property bool _live: false
    Behavior on _presence {
        // Off until the initial state has landed (creation is instant), and
        // off when there is nothing to fade: a source that failed to load
        // has no texture, and fading a blank quad is a longer pop.
        enabled: root._live && tex.status === Image.Ready
        NumberAnimation { duration: root.presenceMs; easing.type: Easing.OutCubic }
    }
    onSourceChanged: if (root.source.toString().length > 0) root._shown = root.source
    Component.onCompleted: {
        if (root.source.toString().length > 0) root._shown = root.source;
        // After the initial bindings have settled, not during them.
        Qt.callLater(function () { root._live = true; });
    }

    // No mark -> no item: zero size AND invisible, so a Column or Row gives it
    // neither height nor spacing and the layout closes back up around it once
    // the fade is done. This is the graceful fallback for a model whose vendor
    // has no mark.
    readonly property bool _drawn: root._wanted || root._presence > 0
    // Room outside the item for the part of the texture that is margin.
    readonly property real _margin:
        0.5 * root.logoSize * (1.0 / Math.max(0.05, root.markFraction) - 1.0)
    implicitWidth: root._drawn ? root.logoSize : 0
    implicitHeight: root._drawn ? root.logoSize : 0
    visible: root._drawn
    opacity: root._presence

    // ======================================================================

    // A plain Image is a texture provider: the scene graph uploads the PNG
    // once and hands the sampler its texture. No ShaderEffectSource, so there
    // is no second render target and no per-frame pass -- which is the whole
    // reason the hard work was baked.
    Image {
        id: tex
        source: root._shown
        visible: false
        // Minified when the plate is smaller than the bake, so it needs the
        // mip chain; both ramps and the normal are continuous across the
        // contour precisely so that averaging them is safe.
        mipmap: true
        smooth: true
        // Synchronous, deliberately. An asynchronous swap leaves the Image
        // with NO texture for at least one frame (its node is dropped while
        // the load is in flight, and the shader then samples nothing), which
        // is a blank frame between two marks -- a pop. A 320 px PNG decodes
        // in about a millisecond, once per mark, and that is the whole cost
        // of a swap that is instant, as a text swap is.
        asynchronous: false
        cache: true
    }

    ShaderEffect {
        anchors.fill: parent
        // Grown past the item so the baked margin -- and the bevel rim inside
        // it, which sits OUTSIDE the mark's edge -- has somewhere to draw.
        anchors.margins: -root._margin
        fragmentShader: "shaders/logo_relief.frag.qsb"

        property Image src: tex

        property real depthScale: root.depthScale
        property real bevelWidth: root.bevelWidth
        property real edgeAlpha: root.edgeAlpha
        property real falloff: root.falloff
        property real ambient: root.ambient
        property real highlightGain: root.highlightGain
        property real lightAngle: root.lightAngle

        property color surfaceColor: root.surfaceColor
        property color bevelColor: root.bevelColor
        property color shadowColor: root.shadowColor
        property color bodyColor: root.bodyColor

        property vector4d bevelEasing: Qt.vector4d(
            root.bevelEasing[0], root.bevelEasing[1], root.bevelEasing[2], root.bevelEasing[3])
        property vector4d shadowEasing: Qt.vector4d(
            root.shadowEasing[0], root.shadowEasing[1], root.shadowEasing[2], root.shadowEasing[3])
    }
}
