import QtQuick

// =============================================================================
// BoardLayerBase.qml -- the board shader's layer SCHEME, the toolkit's: ONE ShaderEffect that is either the whole board (`cached`, a layer: the picture is
// rendered again only when a uniform changes, never per clock tick) minus its `hole`, or the same scene over a sub-rect only (a LIVE PATCH over the part that
// moves, which fills the board's hole and renders again while the part moves; the scene places it and sets offsetX/Y to where it sits).
// A scene's own BoardLayer (silicon's) derives from this: it names the shader packs, adds the uniforms its board shader reads (its motion, its figures,
// its glyph atlas and silkscreen) and nothing of the scheme. The scene owns every number; this only turns them into the shader's uniforms.
//
// The uniform block every board shader of a scene has the first half of (a template in its src says the rest): view (w, h, px per mm, family), frame
// (origin x y, patch kind, dark), light (direction, shadow strength), quad (offset x y, samples per axis, renderScale), palA .. palH (the family's colours),
// tuneA / tuneB, palI .. palP + r3s2A (the second palette). Patch kinds: `patch` (a sub-rect of the scene: its edge is not the scene's, so the ground does
// not fade there) and `cardPatch` (a second live part's rect: the board holds that part where it stood).
// =============================================================================
ShaderEffect {
    id: fx

    property int family: 0
    property bool dark: false
    property bool cached: true
    property vector4d hole: Qt.vector4d(0, 0, 0, 0)    // scene px x0 y0 x1 y1 the board leaves transparent (the patch's rect); zero size = none
    property bool patch: false        // a sub-rect of the scene (the CPU patch): its edge is not the scene's, so the ground does not fade there
    property bool cardPatch: false    // ... or what the moving CARD can change (the board holds the card where it stood)
    property real renderScale: 1
    property int samplesPerAxis: 2

    // the camera: px per mm and the board origin, in SCENE px; this item's offset in the scene
    property real pxPerMm: 3.4
    property real originX: 0
    property real originY: 0
    property real offsetX: fx.x
    property real offsetY: fx.y

    property var lightDir: [0.2, 0.9, 0.4]
    property real shadowStrength: 0.6
    property var colours: []
    property var colours2: []         // the second palette (palI .. palP)
    property vector4d tune: Qt.vector4d(0, 0, 0, 0)

    // The ROOT of this file: a literal path would resolve against the file that instantiates it, so a deriving layer names its packs with a Qt.resolvedUrl, and

    // `source` is declared for Qt's built-in shader, which samples it and which the effect can hold before that binding lands.

    property var source: null

    property vector4d view: Qt.vector4d(fx.width, fx.height, fx.pxPerMm, fx.family)
    property vector4d frame: Qt.vector4d(fx.originX, fx.originY, fx.cardPatch ? 2 : fx.patch ? 1 : 0, fx.dark ? 1 : 0)
    property vector4d light: Qt.vector4d(fx.lightDir[0], fx.lightDir[1], fx.lightDir[2], fx.shadowStrength)
    property vector4d quad: Qt.vector4d(fx.offsetX, fx.offsetY, fx.samplesPerAxis, fx.renderScale)
    property vector4d palA: fx.colours[0] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palB: fx.colours[1] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palC: fx.colours[2] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palD: fx.colours[3] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palE: fx.colours[4] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palF: fx.colours[5] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palG: fx.colours[6] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palH: fx.colours[7] || Qt.vector4d(1, 0, 1, 1)
    property vector4d tuneA: fx.tune
    property vector4d tuneB: Qt.vector4d(0, 0, 0, 0)
    property vector4d palI: fx.colours2[0] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palJ: fx.colours2[1] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palK: fx.colours2[2] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palL: fx.colours2[3] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palM: fx.colours2[4] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palN: fx.colours2[5] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palO: fx.colours2[6] || Qt.vector4d(1, 0, 1, 1)
    property vector4d palP: fx.colours2[7] || Qt.vector4d(1, 0, 1, 1)
    property vector4d r3s2A: fx.colours2[8] || Qt.vector4d(1, 0, 1, 1)         // the smoked glass over the displays' window (the second palette's slot 8)

    layer.enabled: fx.cached
    layer.textureSize: Qt.size(Math.ceil(fx.width * fx.renderScale), Math.ceil(fx.height * fx.renderScale))
    layer.smooth: true
}
