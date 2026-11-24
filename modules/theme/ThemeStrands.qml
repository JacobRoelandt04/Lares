pragma ComponentBehavior: Bound

import QtQuick

import "data/StrandWaves.js" as Strands

// =============================================================================
// ThemeStrands.qml -- the sine strands between a pair's two cards, one ShaderEffect (shaders/theme_strands.frag): three waves pinched to nothing at both ends, flowing on the
// popup's one clock. a and b are the two ends in this item's own pixels; the colours are the pair's data, light card's accent -> a mid hue -> dark card's accent.
//
// NO TWO INSTANCES ARE ALIKE, AND NO HOST HAS TO SEE TO IT. An instance takes the next number from StrandWaves as it is built and its waves come from that number: their own phases
// and a little of their own speed and wave number (StrandWaves.strandWaves). Those are constants of the instance, so the phase stays integrated: `flow` is the popup's one clock
// and each strand turns at a fixed rate of it, and the pinch is the shader's, a function of the place along the strand alone, whatever the waves.
// =============================================================================
ShaderEffect {
    id: fx

    required property ThemeStyle style
    required property var lightColors
    required property var darkColors
    property real flow: 0

    property real ax: 0
    property real ay: 0
    property real bx: 0
    property real by: 0

    readonly property int instance: Strands.nextStrand()
    readonly property var waves: Strands.strandWaves(fx.instance)

    readonly property real boxW: fx.width
    readonly property real boxH: fx.height
    readonly property real endWidth: fx.style.strandEndWidth
    readonly property vector4d s1: Qt.vector4d(fx.style.strand1Amp, fx.style.strand1Wave * fx.waves.wave[0], fx.style.strand1Flow * fx.waves.speed[0], fx.style.strand1Width)
    readonly property vector4d s2: Qt.vector4d(fx.style.strand2Amp, fx.style.strand2Wave * fx.waves.wave[1], fx.style.strand2Flow * fx.waves.speed[1], fx.style.strand2Width)
    readonly property vector4d s3: Qt.vector4d(fx.style.strand3Amp, fx.style.strand3Wave * fx.waves.wave[2], fx.style.strand3Flow * fx.waves.speed[2], fx.style.strand3Width)
    readonly property vector4d phases: Qt.vector4d(fx.waves.phase[0], fx.waves.phase[1], fx.waves.phase[2], 0)
    readonly property vector4d alphas: Qt.vector4d(fx.style.strand1Alpha, fx.style.strand2Alpha, fx.style.strand3Alpha, 0)
    readonly property color colA: fx.lightColors.accent
    readonly property color colB: fx.darkColors.accent
    readonly property color mid1: fx.lightColors.ansiMagenta
    readonly property color mid2: fx.lightColors.ansiCyan
    readonly property color mid3: fx.darkColors.ok

    blending: true
    // The ROOT of this file: a literal path would resolve against the file that instantiates it, so the path is a Qt.resolvedUrl, and
    // `source` is declared for Qt's built-in shader, which samples it and which the effect can hold before that binding lands.
    property var source: null
    fragmentShader: Qt.resolvedUrl("shaders/theme_strands.frag.qsb")
}
