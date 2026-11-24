import QtQuick

// =============================================================================
// GlowLayerBase.qml -- the toolkit's live-light layer scheme: ONE ShaderEffect over the whole scene, NOT a layer (it changes with every tick while the clock
// runs and costs one cheap sample a pixel). The pulse trains' amplitude (`pulse`: the idle ladder's live layer, 0 = steady light only), the glow's tuning
// (`glowTuneA`) and the camera / palette uniforms every board shader shares are here; a scene's own GlowLayer (silicon's) derives from this, names its pack and
// adds the uniforms its glow shader reads (its phases, its cores, its figures). The scene owns every number; this only turns them into the shader's uniforms.
// =============================================================================
ShaderEffect {
    id: fx

    property int family: 0
    property bool dark: false
    property real renderScale: 1
    property real pxPerMm: 3.4
    property real originX: 0
    property real originY: 0
    property var lightDir: [0.2, 0.9, 0.4]
    property real pulse: 1                // 0..1 the pulse trains along the traces (the idle ladder's live: 0 = steady light only)
    property var colours2: []             // the board's second palette (the glow reads the memory hue)
    property vector4d glowTuneA: Qt.vector4d(1, 0.12, 26, 5)

    // The ROOT of this file: a literal path would resolve against the file that instantiates it, so a deriving layer names its pack with a Qt.resolvedUrl, and

    // `source` is declared for Qt's built-in shader, which samples it and which the effect can hold before that binding lands.

    property var source: null

    property vector4d view: Qt.vector4d(fx.width, fx.height, fx.pxPerMm, fx.family)
    property vector4d frame: Qt.vector4d(fx.originX, fx.originY, 0, fx.dark ? 1 : 0)
    property vector4d light: Qt.vector4d(fx.lightDir[0], fx.lightDir[1], fx.lightDir[2], 0)
    property vector4d quad: Qt.vector4d(fx.x, fx.y, 1, fx.renderScale)
    property vector4d palI: fx.colours2[0] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palJ: fx.colours2[1] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palK: fx.colours2[2] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palL: fx.colours2[3] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palM: fx.colours2[4] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palN: fx.colours2[5] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palO: fx.colours2[6] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palP: fx.colours2[7] || Qt.vector4d(1, 0, 1, 1)
    property vector4d r3s2A: fx.colours2[8] || Qt.vector4d(1, 0, 1, 1)         // the smoked glass over the displays' window (the second palette's slot 8)
    property vector4d glowA: fx.glowTuneA
    property vector4d glowB: Qt.vector4d(0, 0, fx.pulse, 0)           // z: the pulse trains' amplitude (a scene's event speed is its own constant)
}
