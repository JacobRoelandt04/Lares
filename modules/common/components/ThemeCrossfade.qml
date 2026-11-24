pragma ComponentBehavior: Bound

import QtQuick
import "../theme"

// =============================================================================
// ThemeCrossfade.qml
//
// A PICTURE OF THE OLD PALETTE, FADED OUT OVER THE NEW ONE. Registers itself as
// one of Theme's crossfade hosts, so a light/dark switch stops lerping every
// token in the scene for 420 ms and instead writes the tokens ONCE behind a
// still image of the frame before, then fades that image on Theme's own clock.
//
// ONE PER WINDOW. A window that draws themed content has its own: every screen's
// bar window, the OSD pill, the auth pill. Theme asks all the hosts, waits until
// each has taken its picture (or said it cannot: no size, window not shown) and
// writes the tokens once, so every window fades its own old frame on the one
// clock (Theme.registerHost / hostReady). A window without a
// host CUTS at the commit while the others fade.
//
// WHY. The per-token lerp is one clock, but the bindings on it are one per
// token per item, and a popup of five thousand items pays 33-88 ms a
// frame for the fade (measured) -- seven stepping frames where the
// system update, a tenth the size, runs at 120. That cost is proportional to
// the scene. A picture makes it a constant: one textured quad per frame, whatever
// is under it. RAM for CPU, which is the shell's own rule for a low power
// draw -- the texture is the size of the window and lives for the next switch.
//
// THE FRAMES, exactly, because a picture shown one frame early is a flash:
//   N     Theme asks (`aboutToSwitch`); this schedules the capture. Not shown.
//   N+1   the capture renders the target as it still is: the OLD palette.
//   N+2   `scheduledUpdateCompleted`: the picture is SHOWN at opacity 1 and the
//         tokens are committed in the same frame (with several hosts: in the
//         frame the LAST one's picture is taken) -- the heavy frame, every
//         binding once plus the documents re-baking on `settled`. The screen
//         keeps N+1 until it is done; nothing steps, because nothing moves.
//   N+3.. `fadeProgress` runs 0 -> 1 over fadeMs and the picture's opacity is
//         1 - that. One clock, Theme's, and the quad is all it drives here.
//
//     ThemeCrossfade { target: body; anchors.fill: body }   // a SIBLING of body
//
// ISLANDS (ThemeIsland.qml): a moving thing that opted in has its shape CUT OUT of the picture, so it keeps moving under
// the fade and shows through the hole with its own colours going old -> new (FadeColor) on Theme's clock. A host with
// no armed island draws the picture whole, through the same quad. With one, the picture is drawn by
// `holey` (theme_hole.frag: the same texture times a mask) and the plain quad is left at opacity 0 -- its capture is
// done by then, the texture lives in the ShaderEffectSource.
//
// It must be a sibling, never a child, of what it captures: a child would be
// in its own picture.
// =============================================================================
Item {
    id: crossfade

    property Item target: null
    // THE LIVE CURTAIN (modules/shell/ThemeWipe.qml, null without it). While it is engaged it draws this host's picture, cut by its line, and neither
    // quad here does; the capture, the commit and the holes are this file's. `wipe` itself is the consumer that makes the capture land.
    property var wipe: null
    readonly property bool wiping: !!crossfade.wipe && crossfade.wipe.engaged
    readonly property alias picture: pic
    // A WINDOW OVER THE SHELL'S (the OSD's pill, the toasts'): the live curtain of its screen and where this window stands on that screen, in the wipe's px. The window is not in
    // the wipe's pictures, so this host keeps its own and, instead of fading it, cuts it by the same line (curtain_ghost.frag) and the live window by the other side of that line
    // (curtain_rest.frag: a new shadow under an old edge would count twice).
    property var lineWipe: null
    property rect linePlace: Qt.rect(0, 0, 0, 0)
    // (From the ask, as `wiping`: the quad is the consumer the grab lands through, its first frame is the grab's own, and a picture drawn over the window it is a picture of counts
    // every shadow pixel twice.)
    readonly property bool lineCutting: !!crossfade.lineWipe && crossfade.lineWipe.engaged && crossfade.active && !crossfade._missed
    // The WINDOW's pixel ratio: the capture is of the window, in its device px (the attached Screen's is the integer wl_output scale at a
    // fractional Hyprland scale: a texture 1.33 times too large to resample).
    readonly property real _dpr: crossfade.Window.window && crossfade.Window.window.devicePixelRatio > 0 ? crossfade.Window.window.devicePixelRatio : 1
    // The source is only ever rendered on a scheduled update, never live.
    readonly property bool active: Theme.crossfading

    // True from the frame the capture landed until the fade is over. The
    // picture is DRAWN only then; a stale texture from the last switch is
    // never on screen. Public, so a probe can time the capture.
    readonly property bool captured: crossfade._captured
    readonly property bool missed: crossfade._missed
    property bool _captured: false
    // The first grab of a session costs 31 ms against 9 for every later one
    // (measured: the layer's renderer and its pipelines are built on it), so
    // the picture is taken once, a second after the host comes up, and thrown
    // away. Its texture then lives for the next switch. RAM for the switch's
    // time, which is the shell's rule.
    property bool _warming: false
    Timer {
        interval: 1000
        running: true
        onTriggered: {
            if (!crossfade.target || crossfade.width <= 0 || crossfade.height <= 0 || crossfade.active)
                return;
            crossfade._warming = true;
            pic.scheduleUpdate();
        }
    }

    z: 100000
    // NEVER hide it to schedule a capture. A ShaderEffectSource grabs its
    // source in the renderer's preprocess pass, and preprocess is skipped for
    // any node in a blocked subtree: `visible: false` and `opacity: 0` both
    // block (measured, both: six idle frames, then Theme's fallback committed
    // with no picture at all). So the quad is at opacity 1 from the ask: in
    // the capture frame the grab runs BEFORE the draw, and the picture it
    // draws is the target's own pixels of that frame. At rest it is opacity 0,
    // which is exactly what makes it free -- blocked means never preprocessed.
    visible: true

    ShaderEffectSource {
        id: pic
        anchors.fill: parent
        sourceItem: crossfade.target
        live: false
        recursive: false
        hideSource: false
        mipmap: false
        smooth: false
        format: ShaderEffectSource.RGBA8
        // Pixel-exact: the texture is the target at the scale it is seen at,
        // so nothing is resampled (CLAUDE.md, the layer law).
        textureSize: Qt.size(Math.max(1, Math.round(crossfade.width * crossfade._dpr)),
                             Math.max(1, Math.round(crossfade.height * crossfade._dpr)))
        // Opaque while the picture is the truth of the screen: the whole of
        // a switch, and the one warming frame (whose grab is that frame's own
        // pixels, drawn back over themselves). A host whose picture was not
        // taken by the commit draws NOTHING for the fade: its texture is an
        // earlier switch's, and the live window already has the new palette.
        opacity: crossfade.wiping || crossfade.lineCutting ? 0 : crossfade.active ? (crossfade._missed || crossfade.cutting ? 0 : 1 - Theme.fadeProgress) : (crossfade._warming ? 1 : 0)
        onScheduledUpdateCompleted: {
            if (crossfade._warming) {
                crossfade._warming = false;
                return;
            }
            crossfade._captured = true;
            Theme.hostReady(crossfade);
        }
    }

    // ---- islands --------------------------------------------------------------
    // The window this host is the picture of: a ThemeIsland registers with the host of ITS window.
    readonly property var hostWindow: crossfade.Window.window
    property var _islands: []
    property int _armedCount: 0
    // The hole mode: a picture is on screen and an island is armed. Public so a probe can read it.
    readonly property bool cutting: crossfade.active && crossfade._captured && !crossfade._missed && crossfade._armedCount > 0
    function registerIsland(island) {
        if (crossfade._islands.indexOf(island) < 0)
            crossfade._islands = crossfade._islands.concat([island]);
        crossfade.recount();
    }
    function unregisterIsland(island) {
        crossfade._islands = crossfade._islands.filter(x => x !== island);
        crossfade.recount();
    }
    function recount() {
        let n = 0;
        for (let i = 0; i < crossfade._islands.length; i++)
            if (crossfade._islands[i]._armed)
                n++;
        crossfade._armedCount = n;
    }
    // The holes, in this item's units: four at most (the rest are not cut). All zero unless `cutting`: the wipe's upper half reads these raw, and a hole left over from a run
    // with an island would cut the OLD picture at that island's place on the screen in every later run, wherever a popup then stands.
    property vector4d _hA: Qt.vector4d(0, 0, 0, 0)
    property vector4d _hB: Qt.vector4d(0, 0, 0, 0)
    property vector4d _hC: Qt.vector4d(0, 0, 0, 0)
    property vector4d _hD: Qt.vector4d(0, 0, 0, 0)
    property vector4d _hR: Qt.vector4d(0, 0, 0, 0)
    property vector4d _hH: Qt.vector4d(0, 0, 0, 0)
    function _refreshHoles() {
        const v = [Qt.vector4d(0, 0, 0, 0), Qt.vector4d(0, 0, 0, 0), Qt.vector4d(0, 0, 0, 0), Qt.vector4d(0, 0, 0, 0)];
        const r = [0, 0, 0, 0];
        const hd = [0, 0, 0, 0];
        let n = 0;
        for (let i = 0; crossfade.cutting && i < crossfade._islands.length && n < 4; i++) {
            const isl = crossfade._islands[i];
            if (!isl._armed)
                continue;
            const h = isl.holeIn(crossfade, crossfade._dpr);
            v[n] = Qt.vector4d(h.cx, h.cy, h.hx, h.hy);
            r[n] = h.r;
            hd[n] = h.hard ? 1 : 0;
            n++;
        }
        crossfade._hA = v[0];
        crossfade._hB = v[1];
        crossfade._hC = v[2];
        crossfade._hD = v[3];
        crossfade._hR = Qt.vector4d(r[0], r[1], r[2], r[3]);
        crossfade._hH = Qt.vector4d(hd[0], hd[1], hd[2], hd[3]);
    }
    onCuttingChanged: crossfade._refreshHoles()
    // The holes follow their islands every frame while the picture is cut (the popup may move, an island may resize).
    FrameAnimation {
        running: crossfade.cutting
        onTriggered: crossfade._refreshHoles()
    }
    ShaderEffect {
        id: holey
        anchors.fill: parent
        visible: crossfade.cutting && !crossfade.wiping && !crossfade.lineCutting
        opacity: 1 - Theme.fadeProgress
        property var src: pic
        property real boxW: holey.width
        property real boxH: holey.height
        property real px: 1 / crossfade._dpr
        property vector4d holeA: crossfade._hA
        property vector4d holeB: crossfade._hB
        property vector4d holeC: crossfade._hC
        property vector4d holeD: crossfade._hD
        property vector4d holeR: crossfade._hR
        property vector4d holeH: crossfade._hH
        fragmentShader: "shaders/theme_hole.frag.qsb"
    }

    ShaderEffect {
        id: lineNew
        anchors.fill: parent
        visible: crossfade.lineCutting
        readonly property var w: crossfade.lineWipe
        property var source: ShaderEffectSource {
            sourceItem: crossfade.lineCutting ? crossfade.target : null
            hideSource: true
            live: true
            recursive: false
            smooth: false
            format: ShaderEffectSource.RGBA8
            textureSize: pic.textureSize
        }
        property vector2d size: lineCut.size
        property vector2d origin: lineCut.origin
        property real progress: lineCut.progress
        property real soft: lineCut.soft
        property real seed: lineCut.seed
        property real style: lineCut.style
        property vector4d place: lineCut.place
        fragmentShader: "shaders/curtain_rest.frag.qsb"
    }
    ShaderEffect {
        id: lineCut
        anchors.fill: parent
        visible: crossfade.lineCutting
        readonly property var w: crossfade.lineWipe
        property var source: pic
        property vector2d size: lineCut.w ? Qt.vector2d(lineCut.w.width, lineCut.w.height) : Qt.vector2d(1, 1)
        property vector2d origin: lineCut.w ? Qt.vector2d(lineCut.w.originX, lineCut.w.originY) : Qt.vector2d(0, 0)
        property real progress: lineCut.w ? lineCut.w.progress : 1
        property real soft: lineCut.w ? lineCut.w.soft : 1
        property real seed: lineCut.w ? lineCut.w.seed : 0
        property real style: lineCut.w ? lineCut.w.styleIndex : 0
        property vector4d place: Qt.vector4d(crossfade.linePlace.x, crossfade.linePlace.y, crossfade.linePlace.width, crossfade.linePlace.height)
        fragmentShader: "shaders/curtain_ghost.frag.qsb"
    }

    Connections {
        target: Theme
        function onAboutToSwitch() {
            crossfade._missed = false;      // a new ask is a new chance
            if (!crossfade.target || crossfade.width <= 0 || crossfade.height <= 0
                    || !crossfade.Window.window || !crossfade.Window.window.visible) {
                Theme.hostReady(crossfade);      // no picture to take: nobody waits for this host
                return;
            }
            crossfade._captured = false;
            crossfade._warming = false;    // a switch outranks a warm-up in flight
            pic.scheduleUpdate();
        }
        // The palette is final. A host that was asked and has no picture by now (the
        // 120 ms fallback committed without it, or it cannot take one) shows nothing.
        function onSettled() {
            if (crossfade.active && !crossfade._captured)
                crossfade._missed = true;
        }
    }
    property bool _missed: false
    onActiveChanged: if (!crossfade.active) {
        crossfade._captured = false;
        crossfade._missed = false;
    }

    // A host that joins in the middle of a switch was never asked: it has no picture of the old palette.
    Component.onCompleted: {
        Theme.registerHost(crossfade);
        if (Theme.crossfading)
            crossfade._missed = true;
    }
    Component.onDestruction: Theme.unregisterHost(crossfade)
}
