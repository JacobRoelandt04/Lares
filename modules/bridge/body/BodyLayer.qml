import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/Lighting.js" as Lighting
import "BodyGeometry.js" as Geo

// =============================================================================
// BodyLayer.qml -- one instance of bridge_body.frag: a phone's body traced per pixel over the whole stage (the body,
// its keys, the glass, the hole the front face shows through, the shadow it casts). PhoneStage owns every number and
// every motion; this turns them into the shader's uniforms.
//
// ITS SIZE IS IN DEVICE PIXELS, whole ones: the stage hosts it in an item scaled back by the device scale, so the layer's
// texture is the item's own size, pixel for pixel, at any scale.
//
// AT REST IT IS A PICTURE. `cached` holds the effect as a layer: the body is traced again only when a uniform
// changes, never because something else in the window asked for a frame (a popup is drawn in its bar's window, and
// every frame that window draws would trace the phone again otherwise). While the body turns or the light follows
// the pointer the stage sets `cached` false and the effect is drawn straight into the window: a layer whose content
// changes every frame costs a second frame per frame.
//
// THE LIGHT is the shell's one (Lighting.js: an angle round the object, an elevation towards the eye, in a space
// whose y runs UP; the stage's runs down, so y is turned here and nowhere else). The room a mirror sees is the
// popup's own: its surface above, its deep shadow below -- the tokens themselves, so a theme switch re-traces the
// picture once at the commit, under the crossfade's still.
// =============================================================================
ShaderEffect {
    id: fx

    // Geo.layout()'s answer and the skin it was made from.
    property var lay: null
    property var sk: null
    // The pose: Geo.basis()'s axes, and the body's lift towards the viewer (px).
    property var axes: ({ ex: [1, 0, 0], ey: [0, 1, 0], ez: [0, 0, 1] })
    property real lift: 0
    property bool cached: true
    // How far each of the 4 key rows is pressed, 0..1.
    property var press: [0, 0, 0, 0]
    // The fan ring's light, 0..1.
    property real busy: 0

    // The lamps (angle round the body, 0 from the right and 90 from above; elevation towards the eye).
    property real keyAngleDeg: 118
    property real keyElevation: 0.55
    property real keyStrength: 1.0
    property real fillAngleDeg: -35
    property real fillElevation: 0.62
    property real fillStrength: 0.42
    // The long light the glass mirrors, and where the pointer has slid it (-1..1 each way, 0 its own place).
    property real stripAngleDeg: 100
    property real stripElevation: 0.80
    property real stripTiltDeg: 16
    property real stripHalfLength: 0.62
    property real stripStrength: 0.85
    property real stripSharpness: 90
    property real lightSlideX: 0
    property real lightSlideY: 0
    property real lightSlideReach: 0.32
    // A glint: the strip run out across the glass and back, 0..1..0 (the stage's free look says "ready" with it): how
    // far it runs and how much brighter it is at its peak.
    property real glint: 0
    property real glintReach: 0.55
    property real glintGain: 0.7
    // The two tall lights at the viewer's sides: a turning face catches one as a band across it.
    property real sideStrength: 1.9
    // The room.
    property color skyColor: Theme.surface
    property color groundColor: Theme.shadowDeep
    property real roomStrength: 0.92
    property real horizonSoftness: 0.38
    // The shadow on the popup's surface.
    property color shadowColor: Theme.shadowDeep
    property real shadowStrength: 0.42
    // Where the shadow of the body's middle falls at rest (px), how soft its edge is (px), and how high that middle stands over
    // the surface (px): together they are the light's slant, so a part that turns towards the viewer throws its shadow further
    // and a lifted body's shadow falls away, softer and fainter (the shader's `shadowDist`).
    property real shadowOffsetX: 0
    property real shadowOffsetY: 5
    property real shadowSoftness: 13
    property real shadowHeight: 26
    // The materials' feel.
    property real frameRoughness: 0.36
    property real frameMirror: 0.62
    property real glassReflectivity: 1.0
    property real displayGlare: 0.55
    // The back's ruled lines: how strongly a line and its neighbour differ in colour on the lined plate (each other
    // surface shows its lines at its own share of this: the grain texture's blue), and how far a groove's two flanks
    // lean apart (what smears a light across brushed and ruled surfaces).
    property real lineContrast: 0.15
    property real grooveLean: 0.30
    // The film printed under the back glass (line art, wordmark) stands this far over the plate (mm) and casts a shadow
    // on it, this dark, away from the light the pointer leads; in a ruled line's valley the shadow runs this much longer.
    property real filmHeightMm: 0.24
    property real filmShadow: 0.30
    property real filmValleyGain: 0.8
    // The seam the glass sits in, between it and the frame's rim, mm.
    property real seamMm: 0.16
    // tools/bridge/make_decor.py's own numbers: the depth the decor's deepest part lies under the glass (DEPTH_MAX,
    // mm), the frame's texels per mm (FRAME_PX) and the texels between its strips (GUTTER).
    property real decorDepthMm: 3.0
    property real framePx: 8
    property real frameGutter: 8
    // The skin's name: its textures are modules/bridge/assets/<name>_{albedo,relief,grain,surface,film,frame,frameRelief}.png.
    property string skinName: "generic"

    // The ROOT of this file: a literal path would resolve against the file that instantiates it, so the paths are
    // Qt.resolvedUrl; and `source` is declared for Qt's built-in shader, which samples it and which the effect can
    // hold before these bindings land.
    property var source: null
    vertexShader: Qt.resolvedUrl("../shaders/bridge_body.vert.qsb")
    fragmentShader: Qt.resolvedUrl("../shaders/bridge_body.frag.qsb")

    DeviceScale {
        id: dev
    }

    function _v4(a: var): vector4d {
        return Qt.vector4d(a[0], a[1], a[2], a[3]);
    }
    function _v3(a: var, w: real): vector4d {
        return Qt.vector4d(a[0], a[1], a[2], w);
    }
    // Lighting.js speaks with y up; the stage's y runs down.
    function _lamp(angleDeg: real, elevation: real, w: real): vector4d {
        const v = Lighting.dirOf(angleDeg, elevation);
        return Qt.vector4d(v.x, -v.y, v.z, w);
    }
    function _key(i: int): vector4d {
        const rows = fx._keys;
        const r = rows.length > i ? rows[i] : [0, 0, 0, 0];
        return Qt.vector4d(r[0], r[1], r[2], r[3]);
    }
    readonly property var _keys: fx.lay && fx.sk ? Geo.keys(fx.sk, fx.lay) : []
    readonly property var _skin: fx.sk || Geo.skin("generic")

    // The effect's own size is in DEVICE pixels (PhoneStage's host); the shader works in the stage's.
    property vector4d view: Qt.vector4d(fx.width / dev.value, fx.height / dev.value, dev.value, fx.lay ? fx.lay.camDist : 2000)
    property vector4d bodyA: fx.lay ? Qt.vector4d(fx.lay.cx, fx.lay.cy, fx.lay.halfW, fx.lay.halfH) : Qt.vector4d(0, 0, 1, 1)
    property vector4d bodyB: fx.lay ? Qt.vector4d(fx.lay.halfT, fx.lay.corner, fx.lay.edge, fx.lay.keyProud) : Qt.vector4d(1, 0, 0, 0)
    property vector4d dispA: fx.lay ? Qt.vector4d(fx.lay.display.w / 2, fx.lay.display.h / 2, fx.lay.display.r, fx.lift) : Qt.vector4d(1, 1, 0, 0)
    property vector4d backA: fx.lay ? Qt.vector4d(fx.lay.lip, fx.seamMm * fx.lay.ppm, fx.lay.ppm, fx.decorDepthMm) : Qt.vector4d(0, 1, 1, 0)
    property vector4d backB: fx.lay ? Qt.vector4d(fx.lay.fanX, fx.lay.fanY, fx.lay.slitHalf, fx.lay.slitH) : Qt.vector4d(0, 0, 0, 0)
    property vector4d patA: fx.lay ? Qt.vector4d(fx.lay.win[0], fx.lay.win[1], fx.lay.win[2], fx.lay.win[3]) : Qt.vector4d(0, 0, 0, 0)
    property vector4d patB: fx.lay ? Qt.vector4d(fx.lay.winR, fx.lay.finePitch, fx.lay.seamX, fx.lay.plateY) : Qt.vector4d(0, 0, 0, 0)
    property vector4d patC: fx.lay ? Qt.vector4d(fx.lay.platePitch, fx.lineContrast, fx.grooveLean, fx.lay.collar) : Qt.vector4d(0, 0, 0, 0)
    property vector4d patD: fx.lay ? Qt.vector4d(fx.lay.lens[0], fx.lay.lens[1], fx.lay.lens[2], fx.lay.lens[3]) : Qt.vector4d(0, 0, 0, 0)
    // the frame's atlas, as make_decor.py lays it out: four strips of the wall's length x the thickness, a gutter between
    property vector4d frameA: {
        const strip = Math.round(fx._skin.t * fx.framePx);
        const tall = 4 * strip + 3 * fx.frameGutter;
        return Qt.vector4d(Math.round(fx._skin.w * fx.framePx) / Math.round(fx._skin.h * fx.framePx), strip / tall, (strip + fx.frameGutter) / tall, 0.5 / tall);
    }
    property vector4d axX: fx._v3(fx.axes.ex, 0)
    property vector4d axY: fx._v3(fx.axes.ey, 0)
    property vector4d axZ: fx._v3(fx.axes.ez, 0)
    property vector4d keyA: fx._key(0)
    property vector4d keyB: fx._key(1)
    property vector4d keyC: fx._key(2)
    property vector4d keyD: fx._key(3)
    property vector4d pressA: Qt.vector4d(fx.press[0], fx.press[1], fx.press[2], fx.press[3])
    property vector4d lightA: fx._lamp(fx.keyAngleDeg, fx.keyElevation, fx.keyStrength)
    property vector4d lightB: fx._lamp(fx.fillAngleDeg, fx.fillElevation, fx.fillStrength)
    property vector4d stripA: {
        const v = Lighting.dirOf(fx.stripAngleDeg, fx.stripElevation);
        // the pointer slides the light across the room: to the side with x, up and down with y
        return Qt.vector4d(v.x + fx.lightSlideX * fx.lightSlideReach, -v.y + fx.lightSlideY * fx.lightSlideReach + fx.glint * fx.glintReach, v.z, fx.stripStrength * (1 + fx.glintGain * fx.glint));
    }
    property vector4d stripB: Qt.vector4d(Math.cos(fx.stripTiltDeg * Math.PI / 180), -Math.sin(fx.stripTiltDeg * Math.PI / 180), 0, fx.stripHalfLength)
    property vector4d skyC: Qt.vector4d(fx.skyColor.r, fx.skyColor.g, fx.skyColor.b, fx.roomStrength)
    property vector4d groundC: Qt.vector4d(fx.groundColor.r, fx.groundColor.g, fx.groundColor.b, fx.horizonSoftness)
    property vector4d shadowA: Qt.vector4d(fx.shadowColor.r, fx.shadowColor.g, fx.shadowColor.b, fx.shadowStrength)
    property vector4d shadowB: Qt.vector4d(fx.shadowOffsetX, fx.shadowOffsetY, fx.shadowSoftness, fx.shadowHeight)
    property vector4d frameC: fx._v3(fx._skin.frame, fx.frameRoughness)
    property vector4d backC: fx._v3(fx._skin.backBase, fx.sideStrength)
    property vector4d bezelC: fx._v3(fx._skin.bezel, fx.glassReflectivity)
    property vector4d accentC: Qt.vector4d(0, fx.lay ? fx.lay.fieldPitch : 0, fx.lay ? fx.lay.ringTurn : 1, fx.busy)
    property vector4d tune: Qt.vector4d(fx.displayGlare, fx.stripSharpness, fx.frameMirror, 1)
    property vector4d platA: fx.lay ? fx._v4(fx.lay.plateau) : Qt.vector4d(0, 0, 0, 0)
    property vector4d platB: fx.lay ? fx._v4(fx.lay.plateauB) : Qt.vector4d(0, 0, 0, 0)
    property vector4d ringA: fx.lay ? fx._v4(fx.lay.rings[0]) : Qt.vector4d(0, 0, 0, 0)
    property vector4d ringB: fx.lay ? fx._v4(fx.lay.rings[1]) : Qt.vector4d(0, 0, 0, 0)
    property vector4d ringC: fx.lay ? fx._v4(fx.lay.rings[2]) : Qt.vector4d(0, 0, 0, 0)
    property vector4d filmA: fx.lay ? Qt.vector4d(fx.filmHeightMm * fx.lay.ppm, fx.filmShadow, fx.filmValleyGain, 0) : Qt.vector4d(0, 0, 0, 0)

    // What lies under the back glass (tools/bridge/make_decor.py). Hidden children: an item built with no window
    // crashes quickshell, so they are not free-standing property values.
    property var decorAlbedo: albedoImage
    property var decorRelief: reliefImage
    property var decorGrain: grainImage
    property var decorSurface: surfaceImage
    property var frameAlbedo: frameImage
    property var frameRelief: frameReliefImage
    property var decorFilm: filmImage
    Image {
        id: albedoImage
        source: Qt.resolvedUrl("../assets/" + fx.skinName + "_albedo.png")
        visible: false
        smooth: true
        mipmap: true
    }
    Image {
        id: reliefImage
        source: Qt.resolvedUrl("../assets/" + fx.skinName + "_relief.png")
        visible: false
        smooth: true
        mipmap: true
    }
    Image {
        id: grainImage
        source: Qt.resolvedUrl("../assets/" + fx.skinName + "_grain.png")
        visible: false
        smooth: true
        mipmap: true
    }
    Image {
        id: surfaceImage
        source: Qt.resolvedUrl("../assets/" + fx.skinName + "_surface.png")
        visible: false
        smooth: true
        mipmap: true
    }
    Image {
        id: filmImage
        source: Qt.resolvedUrl("../assets/" + fx.skinName + "_film.png")
        visible: false
        smooth: true
        mipmap: true
    }
    // The frame's two are read WITHOUT mip levels (a wall is read inside a branch and on the silhouette, where the level
    // the GPU would pick is undefined: the cached body and the live one came out different).
    Image {
        id: frameImage
        source: Qt.resolvedUrl("../assets/" + fx.skinName + "_frame.png")
        visible: false
        smooth: true
    }
    Image {
        id: frameReliefImage
        source: Qt.resolvedUrl("../assets/" + fx.skinName + "_frameRelief.png")
        visible: false
        smooth: true
    }

    layer.enabled: fx.cached
    layer.textureSize: Qt.size(Math.round(fx.width), Math.round(fx.height))
    layer.smooth: false
}
