import QtQuick

// =============================================================================
// WikiVeilStyle.qml -- every number of the wiki veils (WikiVeil.qml), in ONE
// object WikiStyle holds as `veil` and the mockup's panel writes. Lengths are
// item px at zoom 1 (the full card's well); a thumbnail draws the same picture
// at `thumbZoom`. No colour is here: a veil's tones are Theme tokens.
//
// `params(name)` is what a pattern's shader gets as p0 / p1 (the order is the
// shader's header's).
// =============================================================================
QtObject {
    id: style

    // "" in the shell: every article has its own veil. A pattern's name shows that one for
    // every article (the mockup's panel, to look at one pattern on any card).
    property string only: ""

    // ---- the clock ----------------------------------------------------------------
    // Frames a second while a veil is on show. Every tick is a frame of the whole
    // window -- two, while the engine holds the card in its clip layer, which it does
    // at rest whenever the card is TALLER than the clock popup it hangs beside (the
    // corner past the popup's foot is drawn rounder than a resting one, so the cut
    // stays; tools/dev/wiki_veil_cost.sh: 24 ticks, 48 frames) -- and nothing in a veil
    // moves more than a pixel or so a tick at 20.
    property real fps: 20
    // Veil seconds per second: 1 is the pace each pattern was tuned at.
    property real speed: 1

    // ---- the material -----------------------------------------------------------------
    // How strongly a slope is lit (1 = a groove's steepest wall reaches the full shade).
    property real relief: 1
    property real litGain: 1
    property real shadowGain: 1
    // The family's hue in the DEEPEST shade only.
    property real hueShare: 0.25
    // The share of a wall's shade that does not ask where the light is.
    property real ambient: 0.45
    // The lit wall's tone: the bevel, carried this many times further from the well's floor
    // (the bevel itself is a few levels off the floor: right for a rim, lost on a hairline).
    property real bevelLift: 1.5
    // ... and that many times more on a dark floor (by the floor's own lightness): a dark
    // palette has no room under its surface, so there the lit walls carry the picture.
    property real bevelLiftDark: 2.5

    // ---- the thumbnail and the plate ---------------------------------------------------
    property real thumbZoom: 0.6
    // The flat plate a subject's logo is carved on: its radius as a share of the
    // logo's size, and the px over which the pattern comes back round it.
    property real plateFraction: 0.72
    property real plateFade: 26

    // ---- contours ------------------------------------------------------------------------
    property real contourWave: 190
    property real contourSpacing: 15
    property real contourWidth: 2.2
    property real contourDepth: 1.3
    property real contourWarp: 26
    property real contourHill: 0.1
    property real contourHeavy: 5

    // ---- maze ----------------------------------------------------------------------------
    property real mazeCell: 30
    property real mazeWidth: 2.0
    property real mazeDepth: 1.3
    property real mazeSwingS: 1.4
    property real mazeEveryS: 120

    // ---- cells -----------------------------------------------------------------------------
    property real cellSize: 46
    property real cellShoulder: 5
    property real cellSeam: 1.2
    property real cellHeight: 2.2
    property real cellDrift: 0.16
    property real cellLean: 0.12

    // ---- links -----------------------------------------------------------------------------
    property real linkCell: 58
    property real linkWidth: 1.8
    property real linkNode: 4.5
    property real linkDepth: 1.2
    property real linkWander: 0.26
    property real linkShare: 0.62

    // ---- ripples ---------------------------------------------------------------------------
    property real rippleWave: 52
    property real rippleHeight: 4.5
    property real rippleDecay: 320
    property real rippleCrest: 0.14

    function params(name: string): var {
        if (name === "contours")
            return [Qt.vector4d(style.contourWave, style.contourSpacing, style.contourWidth, style.contourDepth),
                    Qt.vector4d(1, style.contourWarp, style.contourHill, style.contourHeavy)];
        if (name === "maze")
            return [Qt.vector4d(style.mazeCell, style.mazeWidth, style.mazeDepth, style.mazeSwingS),
                    Qt.vector4d(1, style.mazeEveryS, 0, 0)];
        if (name === "cells")
            return [Qt.vector4d(style.cellSize, style.cellShoulder, style.cellSeam, style.cellHeight),
                    Qt.vector4d(1, style.cellDrift, style.cellLean, 0)];
        if (name === "links")
            return [Qt.vector4d(style.linkCell, style.linkWidth, style.linkNode, style.linkDepth),
                    Qt.vector4d(1, style.linkWander, style.linkShare, 0)];
        return [Qt.vector4d(style.rippleWave, style.rippleHeight, style.rippleDecay, 0), Qt.vector4d(1, style.rippleCrest, 0, 0)];
    }
}
