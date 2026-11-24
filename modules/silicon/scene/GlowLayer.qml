import QtQuick

import "../../common/board"

// =============================================================================
// GlowLayer.qml -- silicon_glow.frag over the whole scene: the board's live light, on the toolkit's glow scheme (GlowLayerBase: not a layer, the camera and
// palette uniforms, the pulse amplitude). The silicon part: its phases, cores, figures and colours.
// The scene owns every number; this only turns them into the shader's uniforms.
// =============================================================================
GlowLayerBase {
    id: fx

    property real pkgTurn: 0              // rad
    property real pkgLift: 0              // mm
    property real cardLift: 0
    property real cardDissolve: 0
    property real plugIn: 1
    property real lever: 0

    property var cores: []            // 16 loads 0..1
    property real igpuBusy: 0
    property real dgpuAwake: 0
    property real fill: 0.8
    property real flowW: 0
    property real cpuPhase: 0
    property real gpuPhase: 0
    property real flowPhase: 0
    property real time: 0
    property real powerOn: 1
    property real eventAge: -1
    property int eventKind: 0
    // the charge limit's lock: the pieces of its one fraction (MotionScripts.lockPose); the glow dims the 4th cell by `lockDim` and
    // sees the lock bar as paint that lets through what it has not yet faded in over
    property real lockBar: 0
    property real lockShackle: 0
    property real lockDim: 0
    property real lockAlpha: 0
    // the 7-segment displays' figures: one vec4 of four cell codes each (Figures.js), in SceneGeometry.SEG7's order
    property vector4d figA: Qt.vector4d(11, 11, 11, 11)
    property vector4d figB: Qt.vector4d(11, 11, 11, 11)
    property vector4d figC: Qt.vector4d(11, 11, 11, 11)
    property vector4d figD: Qt.vector4d(11, 11, 11, 11)
    property vector4d figE: Qt.vector4d(11, 11, 11, 11)
    property vector4d figF: Qt.vector4d(11, 11, 11, 11)
    property vector4d figG: Qt.vector4d(11, 11, 11, 11)
    // the memory and the display: the RAM's chips fill with `ramUsed`; the display's light on the traces is the iGPU's, or the dGPU's when
    // `displayDgpu` is 1 (dGPU-only)
    property real ramUsed: 0
    property real displayDgpu: 0
    property color cpuColour: "#4480F4"
    property color gpuColour: "#4480F4"
    property color chargeColour: "#44C145"
    property color eventColour: "#44C145"

    function _c(i) {
        return fx.cores.length > i ? fx.cores[i] : 0;
    }
    function _v(c) {
        return Qt.vector4d(c.r, c.g, c.b, 1);
    }

    fragmentShader: Qt.resolvedUrl("../shaders/silicon_glow.frag.qsb")
    property vector4d motion: Qt.vector4d(fx.pkgTurn, 0, fx.pkgLift, 0)
    property vector4d parts: Qt.vector4d(fx.cardLift, fx.cardDissolve, fx.plugIn, fx.lever)
    property vector4d coresA: Qt.vector4d(fx._c(0), fx._c(1), fx._c(2), fx._c(3))
    property vector4d coresB: Qt.vector4d(fx._c(4), fx._c(5), fx._c(6), fx._c(7))
    property vector4d coresC: Qt.vector4d(fx._c(8), fx._c(9), fx._c(10), fx._c(11))
    property vector4d coresD: Qt.vector4d(fx._c(12), fx._c(13), fx._c(14), fx._c(15))
    property vector4d live: Qt.vector4d(fx.igpuBusy, fx.dgpuAwake, fx.fill, fx.flowW)
    property vector4d phases: Qt.vector4d(fx.cpuPhase, fx.gpuPhase, fx.flowPhase, fx.time)
    property vector4d power: Qt.vector4d(fx.powerOn, fx.eventAge, fx.eventKind, 0)
    property vector4d lockP: Qt.vector4d(fx.lockBar, fx.lockShackle, fx.lockDim, fx.lockAlpha)
    property vector2d memP: Qt.vector2d(fx.ramUsed, fx.displayDgpu)
    property vector4d colCpu: fx._v(fx.cpuColour)
    property vector4d colGpu: fx._v(fx.gpuColour)
    property vector4d colCharge: fx._v(fx.chargeColour)
    property vector4d colEvent: fx._v(fx.eventColour)
}
