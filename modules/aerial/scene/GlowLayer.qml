import QtQuick

import "../../common/board"

// =============================================================================
// GlowLayer.qml -- aerial_glow.frag over the whole scene: the board's live light, on the toolkit's glow scheme (GlowLayerBase: not a layer, the camera and palette
// uniforms). The aerial part: the LEDs' intensities and colours, the lit segments, the beacon's ring, the button and the lens. NOT a layer: a light is never inside a cached
// layer (it changes with the readings and the clock); the scene only keeps it on while something is lit.
// =============================================================================
GlowLayerBase {
    id: fx

    property real cardTilt: 0
    property real screwLift: 0
    property real btnDown: 0
    property real plugIn: 1
    property real dipWifi: 0
    property real dipBt: 0

    // 8 LEDs: 0 beacon, 1 jack green, 2 jack amber, 3..7 the pads' (LINK ADDR GATEWAY DNS NET); intensity 0..1 and colour 0 off, 1 ok, 2 warn, 3 error, 4 accent
    property var intensity: [0, 0, 0, 0, 0, 0, 0, 0]
    property var colour: [1, 1, 1, 1, 1, 1, 1, 1]
    property color okColour: "#44C145"
    property color warnColour: "#F0AA0B"
    property color errorColour: "#EC0000"
    property color accentColour: "#4480F4"
    property color segColour: "#4480F4"
    property vector4d figRates: Qt.vector4d(11, 11, 11, 11)       // seg7.glsl's cell codes
    property vector4d figUsage: Qt.vector4d(11, 11, 11, 11)
    property real beaconRing: 0       // the ring's radius fraction (time left), 0 = none
    property real beaconStrength: 0
    property real btnLit: 0
    property real lensLit: 0
    property real power: 1            // the entrance 0..1
    property real time: 0
    property real pulseSpeed: 6        // mm/s the trains run along the copper (slow: the user wants them dimmed)
    property real pulseSpacing: 19     // mm between two pulses of one route
    property real pulseWidth: 1.5
    property real pulseBase: 0.0       // the copper's steady light

    function _i(k) {
        return fx.intensity.length > k ? fx.intensity[k] : 0;
    }
    function _k(k) {
        return fx.colour.length > k ? fx.colour[k] : 1;
    }
    function _v(c) {
        return Qt.vector4d(c.r, c.g, c.b, 1);
    }

    vertexShader: Qt.resolvedUrl("../shaders/aerial_glow.vert.qsb")
    fragmentShader: Qt.resolvedUrl("../shaders/aerial_glow.frag.qsb")
    property vector4d motion: Qt.vector4d(fx.cardTilt, fx.screwLift, fx.btnDown, fx.plugIn)
    property vector4d parts: Qt.vector4d(fx.dipWifi, fx.dipBt, 0, 0)
    property vector4d ledI0: Qt.vector4d(fx._i(0), fx._i(1), fx._i(2), fx._i(3))
    property vector4d ledI1: Qt.vector4d(fx._i(4), fx._i(5), fx._i(6), fx._i(7))
    property vector4d ledK0: Qt.vector4d(fx._k(0), fx._k(1), fx._k(2), fx._k(3))
    property vector4d ledK1: Qt.vector4d(fx._k(4), fx._k(5), fx._k(6), fx._k(7))
    property vector4d colOk: fx._v(fx.okColour)
    property vector4d colWarn: fx._v(fx.warnColour)
    property vector4d colErr: fx._v(fx.errorColour)
    property vector4d colAccent: fx._v(fx.accentColour)
    property vector4d colSeg: fx._v(fx.segColour)
    property vector4d figA: fx.figRates
    property vector4d figB: fx.figUsage
    property vector4d beacon: Qt.vector4d(fx.beaconRing, fx.beaconStrength, 0, 0)
    glowTuneA: Qt.vector4d(1, fx.pulseBase, fx.pulseSpacing, fx.pulseWidth)
    glowB: Qt.vector4d(0, fx.pulseSpeed, fx.pulse, 0)
    property vector4d live: Qt.vector4d(fx.btnLit, fx.lensLit, fx.power, fx.time)
}
