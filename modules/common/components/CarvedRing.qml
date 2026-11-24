import QtQuick

import "../theme"

// =============================================================================
// CarvedRing.qml -- the Workspaces groove bent into a circle, as a shader
// (shaders/carved_ring.frag has the bands and the geometry).
//
// A shader and not CarvedPath.js on a Canvas because this ring MOVES: its
// four arcs open and close, its fills follow a finger winding it and morph
// between views, all at frame rate -- a canvas would repaint and upload a
// texture on the GUI thread every frame, and go soft under a zoom.
//
// Geometry is the groove's: `lineThickness` and `sizeScale` as Workspaces
// takes them, so the two read as the same carve side by side. Fills: two
// tones, four slots each, as angles in degrees clockwise from 12 o'clock;
// a slot's END is a convex head `fillHeadBulge` deep.
// =============================================================================
ShaderEffect {
    id: ring

    // ---- Geometry ----------------------------------------------------------
    property real radius: 80                  // centreline radius, px
    property real lineThickness: 6
    property real sizeScale: 1.5
    property real grooveShadowWidth: 3
    property real grooveBevelWidth: 2
    // Gap between the four arcs, degrees; 0 is one unbroken ring.
    property real gapDeg: 0

    // ---- Colours (the groove's) --------------------------------------------
    property color surfaceColor: Theme.surface
    property color grooveBevelColor: Theme.bevel
    property color grooveShadowColor: Theme.border
    property color grooveColor: Theme.panelSunk
    property var grooveGradientEasing: [0.15, 0.60, 0.35, 1]
    property var grooveBevelEasing: [0.15, 0.1, 0.25, 1.0]

    // ---- Fills -------------------------------------------------------------
    property color fillA: Theme.timerRun
    property color fillB: Theme.timerBreak
    property real fillShadowDarken: 1.35
    property real fillHeadBulge: 1.0
    // Where a fill comes round to its own start, the two ends join as a
    // liquid would over this many px (a smooth union), before the ring closes.
    property real fillMergePx: 3 * ring.halfLine
    // How far the rim outside the carve reaches from the ground towards the
    // bevel colour. 1 is the Workspaces groove's; less is a subtler rim.
    property real grooveBevelStrength: 1
    // [s0, s1, s2, s3] start and end angles per tone; end <= start is empty.
    property var aStarts: [0, 0, 0, 0]
    property var aEnds: [0, 0, 0, 0]
    property var bStarts: [0, 0, 0, 0]
    property var bEnds: [0, 0, 0, 0]

    // ---- Derived -----------------------------------------------------------
    readonly property real halfLine: lineThickness * sizeScale / 2
    readonly property real bevelPx: grooveBevelWidth * sizeScale
    readonly property real shadowPx: grooveShadowWidth * sizeScale
    // The carve's outer extent from the centre.
    readonly property real outerRadius: radius + halfLine + bevelPx

    // Even, so the centre lies on a pixel corner as the groove's centreline
    // does: the two sample the carve at the same phase.
    implicitWidth: 2 * Math.ceil(ring.outerRadius) + 2
    implicitHeight: implicitWidth

    // ---- Shader uniforms ---------------------------------------------------
    readonly property real itemW: width
    readonly property real itemH: height
    readonly property real ringRadius: radius
    readonly property real halfWidth: halfLine
    readonly property real bevelWidth: bevelPx
    readonly property real shadowWidth: shadowPx
    readonly property real bulge: fillHeadBulge
    readonly property real mergeK: fillMergePx
    readonly property real bevelStrength: grooveBevelStrength
    readonly property color bevelColor: grooveBevelColor
    readonly property color shadowColor: grooveShadowColor
    readonly property color coreColor: grooveColor
    readonly property vector4d bevelEasing: Qt.vector4d(grooveBevelEasing[0], grooveBevelEasing[1], grooveBevelEasing[2], grooveBevelEasing[3])
    readonly property vector4d shadowEasing: Qt.vector4d(grooveGradientEasing[0], grooveGradientEasing[1], grooveGradientEasing[2], grooveGradientEasing[3])
    readonly property color aCore: fillA
    readonly property color aShadow: Qt.darker(fillA, fillShadowDarken)
    readonly property color bCore: fillB
    readonly property color bShadow: Qt.darker(fillB, fillShadowDarken)
    readonly property vector4d aStart: Qt.vector4d(aStarts[0], aStarts[1], aStarts[2], aStarts[3])
    readonly property vector4d aEnd: Qt.vector4d(aEnds[0], aEnds[1], aEnds[2], aEnds[3])
    readonly property vector4d bStart: Qt.vector4d(bStarts[0], bStarts[1], bStarts[2], bStarts[3])
    readonly property vector4d bEnd: Qt.vector4d(bEnds[0], bEnds[1], bEnds[2], bEnds[3])

    // The ROOT of this file: a literal path would resolve against the file that instantiates it, so the path is a Qt.resolvedUrl, and

    // `source` is declared for Qt's built-in shader, which samples it and which the effect can hold before that binding lands.

    property var source: null

    fragmentShader: Qt.resolvedUrl("shaders/carved_ring.frag.qsb")
}
