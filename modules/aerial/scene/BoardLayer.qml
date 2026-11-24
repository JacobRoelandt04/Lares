import QtQuick

import "../../common/board"

// =============================================================================
// BoardLayer.qml -- one instance of aerial_board.frag, on the toolkit's layer scheme (BoardLayerBase: the cached layer, its hole, the live patches): the whole board
// (`cached`, a layer) or the same scene over a sub-rect only (a live patch over a moving part). The scene owns every number; this only turns them into the uniforms.
// =============================================================================
BoardLayerBase {
    id: fx

    property real cardTilt: 0          // rad: the card rises about its finger end
    property real screwLift: 0         // mm
    property real btnDown: 0           // mm the button's cap is pressed
    property real plugIn: 1            // 0 out .. 1 in
    property real dipWifi: 0           // 0 off .. 1 on
    property real dipBt: 0
    property bool cardAbsent: false    // the card is not drawn (a live patch draws it moving)
    property bool labelHole: true      // a hole where the live label is laid
    property vector4d coaxMain: Qt.vector4d(0.1, 0.1, 0.12, 1)
    property vector4d coaxAux: Qt.vector4d(0.5, 0.5, 0.55, 1)

    // The vertex stage is Qt's own, written out (aerial_board.vert): a pack with a 300 es variant for BOTH stages is what links this effect at GLSL ES 3.00 on an OpenGL ES context.
    vertexShader: Qt.resolvedUrl("../shaders/aerial_board.vert.qsb")
    fragmentShader: Qt.resolvedUrl("../shaders/aerial_board.frag.qsb")
    property vector4d motion: Qt.vector4d(fx.cardTilt, fx.screwLift, fx.btnDown, fx.plugIn)
    property vector4d parts: Qt.vector4d(fx.dipWifi, fx.dipBt, fx.cardAbsent ? 1 : 0, fx.labelHole ? 1 : 0)
    property vector4d palQ: fx.coaxMain
    property vector4d palR: fx.coaxAux
    // the engraved variants of the two unit labels (AerialGeometry SILK_VARIANTS: the index of each) and the radios' hues (the latches' emblems)
    property int ratesVariant: 1
    property int usageVariant: 0
    property vector4d silkVar: Qt.vector4d(fx.ratesVariant, fx.usageVariant, 0, 0)
    property vector4d hueWifi: Qt.vector4d(0.3, 0.7, 0.4, 1)
    property vector4d hueBt: Qt.vector4d(0.27, 0.5, 0.96, 1)
    // the silkscreen (tools/aerial/make_silk.py), a hidden child: an item built with no window of its own crashes quickshell, so it is not a free-standing property value
    property var silk: silkImage
    Image {
        id: silkImage
        source: Qt.resolvedUrl("assets/silk.png")
        visible: false
        smooth: true
        mipmap: true
    }
}
