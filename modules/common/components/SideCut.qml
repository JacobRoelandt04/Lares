pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// SideCut.qml -- the effect a DISPLACED row is drawn through under a SideFade
// (shaders/side_cut.frag): cut to the host's outline per pixel row, and faded
// out on the side it moves to before that cut. Used as a `layer.effect` by the
// two things that draw a row off its rest:
//
//   SwipeVerbCard   its face, while it is displaced (THE LIST)
//   RowFlight       its clone, while it comes back from a moved face
//
// The host's half -- the outline, the clip lines, the ramps' lengths -- is
// BOUND from `fade`, so a host whose outline changes (a toast stack resizing
// under a held card) re-cuts on that change, not on the next frame something
// else happens to draw. The item's half is in the SideFade's frame and is
// sampled by the user once per frame (mapToItem in a binding does not
// re-evaluate when an ancestor moves):
//
//   layerRect   the layered item's rect (x, y, w, h)
//   rest        the rect the row RESTS in: the short ramp ends where a resting
//               row begins, so it lies over nothing a resting row draws
//   disp        the displacement from that rest (+ = right)
//   cardRadius  the row's corner radius (its resting edge in a corner's rows)
//   aa          one device pixel: the cut's inward feather
// =============================================================================
ShaderEffect {
    id: cut

    property SideFade fade: null
    property vector4d layerRect: Qt.vector4d(0, 0, 0, 0)
    property vector4d rest: Qt.vector4d(0, 0, 0, 0)
    property real disp: 0
    property real cardRadius: 0
    property real aa: 1

    readonly property var _ol: cut.fade ? cut.fade.outline : null
    property vector4d box: cut._ol ? Qt.vector4d(cut._ol.x, cut._ol.y, cut._ol.w, cut._ol.h) : Qt.vector4d(0, 0, 0, 0)
    property vector4d radii: cut._ol && cut._ol.radii
        ? Qt.vector4d(cut._ol.radii[0], cut._ol.radii[1], cut._ol.radii[2], cut._ol.radii[3])
        : Qt.vector4d(0, 0, 0, 0)
    property point lines: cut.fade
        ? Qt.point(cut.fade.clipInset, cut.fade.width - cut.fade.clipInset)
        : Qt.point(-1e6, 1e6)
    property point sides: Qt.point(cut.fade && cut.fade.leftBand ? 1 : 0, cut.fade && cut.fade.rightBand ? 1 : 0)
    property real margin: cut.fade ? cut.fade.cornerMargin : 1
    property real lead: cut.fade ? cut.fade.leadPx : 1
    property real rimPx: cut.fade ? cut.fade.rimPx : 2
    property real fadeLen: cut.fade ? cut.fade.fadeLength : 34

    // The ROOT of this file: a literal path would resolve against the file that instantiates it, so the path is a Qt.resolvedUrl, and

    // `source` is declared for Qt's built-in shader, which samples it and which the effect can hold before that binding lands.

    property var source: null

    fragmentShader: Qt.resolvedUrl("shaders/side_cut.frag.qsb")
}
