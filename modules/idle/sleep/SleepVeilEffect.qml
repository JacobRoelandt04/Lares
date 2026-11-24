pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// SleepVeilEffect.qml -- the veil's one pass (shaders/sleep_veil.frag): the screen falling asleep at `progress` 1,
// awake at 0. `picture` is a texture provider holding the output's own picture (a ShaderEffectSource of a capture, MIPMAPPED: the
// defocus reads the mip chain), or null: the vignette and the light alone. At progress 0 the pass outputs nothing at all, so a veil shown at
// 0 (a pre-warm: the pipeline is linked at the first draw in each window) changes no pixel.
//
// The shader works in device px (`renderScale` = device px per item px), so the defocus and the dither are the same at any scale. The
// uniforms are the properties of the same names (progress, strength, seed, size, still, selfDim, src).
// =============================================================================
ShaderEffect {
    id: fx

    // ---- what the host sets ----
    property var picture: null
    // the veil dims this output itself (no backlight of ours under it)
    property bool dimsItself: false
    property real renderScale: 1
    property real progress: 0
    property real strength: 1
    property real seed: 0

    // ---- the uniforms ----
    property vector2d size: Qt.vector2d(Math.max(1, fx.width * fx.renderScale), Math.max(1, fx.height * fx.renderScale))
    property real still: fx.picture ? 1 : 0
    property real selfDim: fx.dimsItself ? 1 : 0
    // the sampler: the picture, or a 1 px stand-in the shader never reads (still = 0)
    property var src: fx.picture ? fx.picture : blank

    // The ROOT of this file: a literal path would resolve against the file that instantiates it, so the path is a Qt.resolvedUrl, and

    // `source` is declared for Qt's built-in shader, which samples it and which the effect can hold before that binding lands.

    property var source: null

    fragmentShader: Qt.resolvedUrl("shaders/sleep_veil.frag.qsb")
    // scale-ok: a 1 px stand-in for the sampler when there is no picture; the shader never reads it (still = 0)
    ShaderEffectSource {
        id: blank
        width: 1
        height: 1
        sourceItem: Item {
            width: 1
            height: 1
        }
        live: false
        visible: false
    }
}
