import QtQuick

// =============================================================================
// MotionBlur.qml
//
// Directional motion blur via a custom fragment shader (shaders/motion_blur.
// frag.qsb). Captures the source item into an offscreen texture, then samples
// it N times along `direction` with a triangular weight centred on the real
// position — produces a streak along the direction of motion rather than an
// isotropic Gaussian.
//
// Usage:
//
//   Item { id: content; ... }
//   MotionBlur {
//       source: content
//       amount: <0..1 velocity signal>
//       direction: Qt.vector2d(1, 0)   // horizontal streak
//   }
//
// `source` and `direction` both default-fit the common horizontal-scroll
// use case. When `amount <= threshold` the shader is bypassed and the
// source renders directly so the effect pipeline is idle at rest.
//
// The shader taps 15 samples, so this is not free — keep `amount` bound to
// a heuristic that only ramps up while something is actually moving.
// =============================================================================
Item {
    id: root

    // Device px per design px here (the nearest ScaleRoot's, else the window's).
    DeviceScale {
        id: dev
    }

    // --- Public API ---
    property Item source: null
    property real amount: 0
    property real threshold: 0.02
    property vector2d direction: Qt.vector2d(1, 0)

    anchors.fill: source

    readonly property bool _active: root.source !== null
                                    && root.amount > root.threshold

    // Source-texture capture. Hidden only while the blur is active, so
    // the original renders in place when nothing needs to smear.
    // `live: root._active` instead of `live: true` avoids a real perf
    // cost — at rest a live source is re-rendered into an offscreen
    // texture every frame even though `visible:false` and the blur
    // ShaderEffect is inactive. With many MotionBlur sites in a popup
    // (one per Flickable) that compounds into mode-switch / resize
    // stutter. The shader-active path still gets a fresh texture per
    // frame; the rest path costs nothing.
    ShaderEffectSource {
        id: srcTex
        anchors.fill: parent
        sourceItem: root.source
        live: root._active
        hideSource: root._active
        visible: false
        textureSize: dev.texSize(srcTex.width, srcTex.height)
    }

    // Blur pass. Reads from `srcTex` into the shader's `src` sampler,
    // samples along `direction`, writes the averaged result to the
    // scene. Visible only while active; when not, source renders
    // directly (no shader pipeline cost).
    ShaderEffect {
        anchors.fill: parent
        visible: root._active

        property variant src: srcTex
        property real amount: root.amount
        property vector2d dir: root.direction

        fragmentShader: "shaders/motion_blur.frag.qsb"
    }
}
