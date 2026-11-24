import QtQuick

import "../../common/board"

// =============================================================================
// BoardLayer.qml -- one instance of silicon_board.frag, on the toolkit's layer scheme (BoardLayerBase: the cached layer, its hole, the live patches):
// the whole board (`cached`, a layer) minus its `hole`, or the same scene over a sub-rect only (the patch over the CPU zone, which fills the board's hole and
// renders again while the package lifts and turns; the scene places it and sets offsetX/Y to where it sits).
// The scene owns every number; this only turns them into the shader's uniforms.
// =============================================================================
BoardLayerBase {
    id: fx

    // motion
    property real pkgTurn: 0          // rad: the CPU package's turn
    property real pkgLift: 0          // mm
    property real cardLift: 0         // mm
    property real cardDissolve: 0     // 0..1
    property real plugIn: 1           // 0 out .. 1 in
    property real hdmiIn: 0           // the HDMI cable in the card's port, 0 out (faded) .. 1 seated
    property real lever: 0            // 0 "80" .. 1 "100"

    property vector4d r3s1Latch: Qt.vector4d(0.15, 0.16, 0.21, 1)     // the display connector's flip-lock bar (SiliconStyle.latch)

    // the charge limit's lock: the pieces of its one fraction (MotionScripts.lockPose)
    property real lockBar: 0          // the bar's slide: 0 waiting out .. 1 home
    property real lockShackle: 0      // mm the shackle stands above its shut place
    property real lockDim: 0          // how far the 4th cell is dimmed
    property real lockAlpha: 0        // how much of the lock is there
    // the printed figures: each four cell codes in ONE number (Figures.code4), so a watts tick that changes none of them does not
    // touch this cached layer; the time display's printed label (0 none)
    property real condCode: 0
    property real cycCode: 0
    property int timeLabel: 0

    // The vertex stage is Qt's own, written out (silicon_board.vert): a pack with a 300 es variant for BOTH stages is what links this effect at GLSL ES 3.00 on an
    // OpenGL ES context (dGPU-only mode); with Qt's built-in vertex shader it linked at 1.00 and the board drew nothing.
    vertexShader: Qt.resolvedUrl("../shaders/silicon_board.vert.qsb")
    fragmentShader: Qt.resolvedUrl("../shaders/silicon_board.frag.qsb")
    property vector4d motion: Qt.vector4d(fx.pkgTurn, fx.hdmiIn, fx.pkgLift, 0)
    property vector4d parts: Qt.vector4d(fx.cardLift, fx.cardDissolve, fx.plugIn, fx.lever)
    property vector4d lockP: Qt.vector4d(fx.lockBar, fx.lockShackle, fx.lockDim, fx.lockAlpha)
    property vector4d figT: Qt.vector4d(fx.timeLabel, 0, 0, 0)
    property vector4d txtA: fx._unpack(fx.condCode)
    property vector4d txtB: fx._unpack(fx.cycCode)

    function _unpack(c: real): vector4d {
        return Qt.vector4d(c % 16, Math.floor(c / 16) % 16, Math.floor(c / 256) % 16, Math.floor(c / 4096) % 16);
    }

    // the glyph atlas (tools/silicon/make_glyphs.py): the printed figures' digits and the time label's three texts
    property var glyphs: glyphImage
    Image {
        id: glyphImage
        source: Qt.resolvedUrl("../assets/silk_glyphs.png")
        visible: false
        smooth: true
        mipmap: true
    }

    // the board-space silkscreen mask (tools/silicon/make_silkscreen.py), a hidden child: an item
    // built with no window of its own crashes quickshell, so it is not a free-standing property value
    property var silk: silkImage
    Image {
        id: silkImage
        source: Qt.resolvedUrl("../assets/silkscreen.png")
        visible: false
        smooth: true
        mipmap: true
    }
}
