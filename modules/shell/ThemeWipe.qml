pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import "../common/theme"
import "../common/components"

// =============================================================================
// ThemeWipe.qml -- THE LIVE CURTAIN, one screen's. (A prototype behind shell.jsonc `"theme": { "curtain": true, "curtainLive": true }`; ThemeControl runs
// the sequence, ShellScreen builds this for the length of a run, and at rest none of it exists.)
//
// WHAT IT IS FOR. The shell stays live through a theme switch -- the vinyl and the board keep moving, the OSD's opening is seen, a popup can
// open or close -- and changes palette by the SAME line as the curtain over the windows, exactly, even when the shell lags a
// frame or two.
//
// ONE WINDOW, SO ONE CLOCK. There is no curtain window. Everything is drawn in the shell's own full-screen surface (`lares-bar`, on Top: over every
// window, as the shell is), from bottom to top:
//
//     `under`    the desktop's still, cut by the line (curtain_under.frag)
//     body       the live shell, unchanged: the only live thing here, and new-palette from the commit on
//     `over`     the old shell's picture, over the desktop's still, cut by the same line (curtain_over.frag), and the sheet's shadow
//
// The two halves read one `progress` in one scene-graph sync, are rendered in one pass and reach the compositor in one commit. A lag of the shell
// is a lag of the line: the two cannot disagree, because there are not two of anything.
//
// THE STILL WITHOUT THE SHELL. An output capture holds the shell, a covered pixel holds nothing of what is under it, and Hyprland's own answers do not
// fit (Hyprland 0.57: `no_screen_share` on a layer blackens the layer's whole box, here the output; hyprland_workspace_image_capture_source_v1's `windows_only`
// is exact and takes 20 ms, but it has no wallpaper and needs a Wayland client of its own: Quickshell 0.3.2 has no such source). But the shell knows its own picture, so the capture can be UN-COMPOSITED: the
// compositor's frame is shot = shell + (1 - shell.a) * desktop, the shell's own picture of that frame (`shellThen`, taken just before the
// capture is asked for) is the shell term, and desktop = (shot - shell) / (1 - shell.a) is exact to a level wherever the shell does not cover it
// fully: under its shadow and its antialiased edges too, which is what keeps the first frame from stepping. Where the shell was opaque there is a HOLE
// in the still, filled from the still's own coarse mip levels (push-pull, `fillTex`): nobody sees that while the shell covers it, and if a popup leaves,
// what shows until the line arrives is a soft fill in the OLD desktop's colours. An exact fill is what the workspace capture would give, and costs a client.
//
// THE OLD SHELL. The window's ThemeCrossfade takes its picture as ever (`host.picture`), at the commit, but the old side of the line is that
// picture over the still and OPAQUE wherever the old shell had ink, so the new shell's edge and shadow do not count twice. Where it had no ink the live
// shell shows through: a popup opening, say. `shellNow` (the live shell, a texture only while the line runs) takes the picture away where the shell has left, and where
// the shell has ARRIVED since the picture it puts that ink on the old side in the old palette, by a map of the palette's axis (curtain_over.frag `inOldPalette`): exact on the surface,
// the text and every mix of the two, the hues kept. There is one live shell and it has one palette: anything that opens while the line runs is that map on the old side
// and itself on the new, so the line cuts it too. The theme OSD does not need it: it opens before the commit, in the old palette, and is in the picture. Islands are the
// crossfade's: a hole in the picture, a ghost cut by the same line (ThemeIsland.wipeEffect).
//
// A HOLE IS NOT A PLACE TO SHOW. The still knows nothing of what the shell covered, so where shell ink LEAVES the fill shows until the line comes: a soft patch in the shape of
// what left, which on a desktop with any detail reads as a compressed ghost of it. So what can wait, waits: an OSD or a toast that is
// out stays until the run ends (OsdOwner.held, ToastScheduler.curtain), and only the user's own close of a popup goes through it.
//
// THE FRAMES. Built at the run's start: a popup or an OSD card in motion is waited for, the shell's picture is taken (a place outside the window keeps it drawn), and only then does the
// capture get its source, so that the frame the compositor copies is the one just pictured; retried until the compositor has given one. Then the still goes on screen under the
// shell: identical to what it covers. `ready`, and ThemeControl changes the theme behind it. `engaged` (the reveal is about to start) puts the
// upper half up: its first frame takes the old picture, and the commit follows.
//
// A LOCK. `lares-bar` draws over the session lock, and a picture of the desktop must not: `visible` of both halves follows `locked` directly, whatever
// the run is doing. The window on a covered output (a fullscreen window over Top) has no wipe: ThemeControl gives that output the stand-alone
// curtain, ThemeCurtain, on Overlay, with no shell in it to match.
// =============================================================================
Item {
    id: wipe

    // ---- injected (ShellScreen, ThemeControl) -----------------------------------------------------------------
    required property var control
    required property Item shell
    required property Item under
    required property Item over
    required property var host
    required property var screen
    required property string outputName
    property bool locked: false
    // Ink of this window's shell is on its way (ShellScreen).
    property bool shellMoving: false
    property int motionWaitMs: 400

    // ---- the run's facts -----------------------------------------------------------------------------------
    readonly property real progress: wipe.control.curtainProgress
    readonly property real seed: wipe.control.curtainSeed
    readonly property real soft: 28
    readonly property string styleName: wipe.control.curtainStyleNow
    readonly property real styleIndex: wipe.styleName === "peel" ? 1 : wipe.styleName === "louvres" ? 2 : 0
    // The line's start in this window: the theme button, where the pointer was; the middle of the output when it is on another.
    readonly property real originX: wipe.control.curtainCursor && wipe.screen ? wipe.control.curtainCursor.x - wipe.screen.x : wipe.width / 2
    readonly property real originY: wipe.control.curtainCursor && wipe.screen ? wipe.control.curtainCursor.y - wipe.screen.y : wipe.height / 2
    // True from the moment the reveal asks for the commit until the run ends: the upper half is up, and it IS this window's picture.
    readonly property bool engaged: wipe.control.wipeEngaged

    // ---- what it says -----------------------------------------------------------------------------------------
    readonly property bool ready: wipe._phase === "ready"
    readonly property string failed: wipe._failed
    readonly property string phase: wipe._phase
    property int revealFrames: 0
    property real revealMaxGap: 0

    // A FadeColor's clock (a live thing inside an island has one colour at a time, so its colour goes as the line crosses it): 0 before the line reaches the
    // rect, 1 when it has passed all of it, in the window's item px. The inverse of curtain_reveal.glsl's fronts, with the same numbers.
    function localFade(x0: real, y0: real, x1: real, y1: real): real {
        const p = wipe.progress;
        const w = wipe.width, h = wipe.height, ox = wipe.originX, oy = wipe.originY;
        let a = 0, b = 1;
        if (wipe.styleName === "louvres") {
            const reach = Math.max(ox, w - ox, 1);
            const near = x0 <= ox && ox <= x1 ? 0 : Math.min(Math.abs(x0 - ox), Math.abs(x1 - ox));
            const far = Math.max(Math.abs(x0 - ox), Math.abs(x1 - ox));
            a = 0.5 * Math.min(1, near / reach);
            b = 0.5 * Math.min(1, far / reach) + 0.5;
        } else if (wipe.styleName === "peel") {
            const tx = w / 2 - ox, ty = h / 2 - oy;
            const tl = Math.hypot(tx, ty);
            const dl = Math.hypot(1, 0.35);
            const dx = tl < 8 ? 1 / dl : tx / tl, dy = tl < 8 ? 0.35 / dl : ty / tl;
            const along = (x, y) => x * dx + y * dy;
            const s0 = Math.min(along(0, 0), along(w, 0), along(0, h), along(w, h)) - 64;
            const s1 = Math.max(along(0, 0), along(w, 0), along(0, h), along(w, h)) + 40;
            const lo = Math.min(along(x0, y0), along(x1, y0), along(x0, y1), along(x1, y1));
            const hi = Math.max(along(x0, y0), along(x1, y0), along(x0, y1), along(x1, y1));
            a = (lo - s0) / (s1 - s0);
            b = (hi - s0) / (s1 - s0);
        } else {
            const reach = Math.hypot(Math.max(ox, w - ox), Math.max(oy, h - oy)) + 1;
            const f0 = -(wipe.soft + 5 + 0.06 * reach), f1 = 1.06 * reach + 36 + wipe.soft;
            const nx = Math.max(x0 - ox, 0, ox - x1), ny = Math.max(y0 - oy, 0, oy - y1);
            const fx = Math.max(Math.abs(x0 - ox), Math.abs(x1 - ox)), fy = Math.max(Math.abs(y0 - oy), Math.abs(y1 - oy));
            a = (Math.hypot(nx, ny) - f0) / (f1 - f0);
            b = (Math.hypot(fx, fy) - f0) / (f1 - f0);
        }
        return b > a ? Math.max(0, Math.min(1, (p - a) / (b - a))) : (p >= a ? 1 : 0);
    }

    anchors.fill: parent

    property string _phase: "capturing"
    property string _failed: ""
    property int _tries: 0
    property bool _asked: false
    property var _source: null
    property real _askedAt: Date.now()
    property bool _drawn: false
    readonly property real _dpr: wipe.Window.window && wipe.Window.window.devicePixelRatio > 0 ? wipe.Window.window.devicePixelRatio : 1
    readonly property size _texSize: Qt.size(Math.max(1, Math.round(wipe.width * wipe._dpr)), Math.max(1, Math.round(wipe.height * wipe._dpr)))

    function _log(msg: string): void {
        console.log("LARESCURTAIN " + wipe.outputName + " " + Date.now() + " " + msg);
    }

    Component.onDestruction: wipe._log("gone")
    Component.onCompleted: {
        wipe._log("armed (in the shell's window, " + wipe.width + "x" + wipe.height + ", ratio " + wipe._dpr + ")");
        wipe._afterSwaps(2, wipe._ask);
    }

    // ---- the capture ------------------------------------------------------------------------------------------
    // The shell's picture first: its grab lands in a frame that also goes to the compositor, and the capture asked for after that frame is of it.
    function _ask(): void {
        // the un-compositing takes the shell's picture and the compositor's frame as one moment, which they are for a shell at rest: a popup in the middle of
        // opening or closing moves between the two, so wait for it (a popup's motion is 300 ms; a run does not wait longer than that)
        if (wipe.shellMoving && Date.now() - wipe._askedAt < wipe.motionWaitMs) {
            retry.start();
            return;
        }
        wipe._tries++;
        wipe._asked = true;
        thenTex.scheduleUpdate();
        wipe._poke();
    }
    // (A ShaderEffectSource's first render says `scheduledUpdateCompleted` too, asked for or not: only the answer to an ask counts.)
    function _pictured(): void {
        if (!wipe._asked)
            return;
        wipe._asked = false;
        wipe._source = wipe.screen;
        cap.captureFrame();
        wipe._afterSwaps(2, wipe._arrived);
    }
    function _arrived(): void {
        if (!cap.hasContent) {
            if (wipe._tries >= 40) {
                wipe._failed = "no capture after " + wipe._tries + " tries";
                wipe._log("FAILED " + wipe._failed);
                return;
            }
            retry.start();
            return;
        }
        wipe._log("captured after " + wipe._tries + " ask(s) " + cap.width + "x" + cap.height);
        wipe._phase = "covering";
        shotTex.scheduleUpdate();
        fillTex.scheduleUpdate();
        wipe._drawn = true;
        wipe._afterSwaps(2, wipe._covered);
    }
    function _covered(): void {
        wipe._phase = "ready";
        wipe._log("ready (the still is on screen, under the shell)");
    }
    Timer {
        id: retry
        interval: 25
        onTriggered: wipe._ask()
    }

    // ---- frame accounting (ThemeCurtain's) ----------------------------------------------------------------------
    property int _swapWait: 0
    property var _swapFn: null
    function _afterSwaps(n: int, fn: var): void {
        wipe._swapWait = n;
        wipe._swapFn = fn;
        guard.restart();
        wipe._poke();
    }
    function _poke(): void {
        if (wipe.Window.window)
            wipe.Window.window.update();
    }
    property real _lastFrameAt: 0
    Connections {
        target: wipe.Window.window
        function onFrameSwapped() {
            if (wipe.progress > 0 && wipe.progress < 1) {
                const now = Date.now();
                if (wipe._lastFrameAt > 0)
                    wipe.revealMaxGap = Math.max(wipe.revealMaxGap, now - wipe._lastFrameAt);
                wipe._lastFrameAt = now;
                wipe.revealFrames++;
            }
            if (wipe._swapFn === null)
                return;
            if (wipe._swapWait > 0)
                wipe._swapWait--;
            if (wipe._swapWait > 0) {
                wipe._poke();
                return;
            }
            const fn = wipe._swapFn;
            wipe._swapFn = null;
            guard.stop();
            fn();
        }
    }
    StallTimer {
        id: guard
        interval: 400
        onTriggered: {
            const fn = wipe._swapFn;
            wipe._swapFn = null;
            wipe._log("WARN swap wait timed out in " + wipe._phase);
            if (fn)
                fn();
        }
    }

    // The old palette's two ends, for ink the old shell did not have.
    ThemeOld {
        id: oldPalette
    }

    // ---- the sources (nothing here is on screen) ------------------------------------------------------------------
    ScreencopyView {
        id: cap
        anchors.fill: parent
        // Set when the picture of the shell has been taken, not before: a ScreencopyView takes a frame of its own the moment it has a source, and a capture older than
        // that picture is the shell of another moment (a closing popup would stay in the still as a ghost).
        // qmllint disable incompatible-type
        captureSource: wipe._source
        // qmllint enable incompatible-type
        live: false
        paintCursor: false
        opacity: 0
    }
    // scale-ok: the window's own pixels, 1:1, whatever the shell's scale inside it (ThemeCrossfade's picture is taken the same way)
    ShaderEffectSource {
        id: shotTex
        anchors.fill: parent
        sourceItem: cap
        live: false
        visible: false
        smooth: false
        textureSize: wipe._texSize
    }
    // The shell's two pictures. A grab runs in the renderer's preprocess of a node that is drawn: a place outside the window keeps these drawn and
    // unseen, with or without a consumer (CLAUDE.md, A SHADEREFFECTSOURCE GRABS ITS SOURCE...).
    ShaderEffectSource {
        id: thenTex
        x: -4
        y: -4
        width: 1
        height: 1
        sourceItem: wipe.shell
        live: false
        recursive: false
        smooth: false
        format: ShaderEffectSource.RGBA8
        textureSize: wipe._texSize
        onScheduledUpdateCompleted: wipe._pictured()
    }
    ShaderEffectSource {
        id: nowTex
        x: -4
        y: -4
        width: 1
        height: 1
        sourceItem: wipe.shell
        live: wipe.engaged
        recursive: false
        smooth: false
        format: ShaderEffectSource.RGBA8
        textureSize: wipe._texSize
    }

    // The still with its holes, for the fill: a quarter size is plenty, its coarse levels are all that is read.
    ShaderEffect {
        id: deskFx
        anchors.fill: parent
        visible: false
        property var shot: shotTex
        property var shellThen: thenTex
        fragmentShader: "../common/components/shaders/curtain_desk.frag.qsb"
    }
    ShaderEffectSource {
        id: fillTex
        anchors.fill: parent
        sourceItem: deskFx
        live: false
        visible: false
        mipmap: true
        format: ShaderEffectSource.RGBA8
        textureSize: Qt.size(Math.max(1, Math.round(wipe._texSize.width / 4)), Math.max(1, Math.round(wipe._texSize.height / 4)))
    }

    // ---- the lower half: the desktop as it was, under the shell ---------------------------------------------------
    ShaderEffect {
        parent: wipe.under
        anchors.fill: parent
        visible: wipe._drawn && wipe.control.curtainArmed && !wipe.locked && wipe.progress < 1
        property var shot: shotTex
        property var shellThen: thenTex
        property var shotFill: fillTex
        property vector2d size: Qt.vector2d(width, height)
        property vector2d origin: Qt.vector2d(wipe.originX, wipe.originY)
        property real progress: wipe.progress
        property real soft: wipe.soft
        property real seed: wipe.seed
        property real style: wipe.styleIndex
        fragmentShader: "../common/components/shaders/curtain_under.frag.qsb"
    }

    // ---- the upper half: the old shell, cut by the same line --------------------------------------------------------
    ShaderEffect {
        parent: wipe.over
        anchors.fill: parent
        visible: wipe.engaged && wipe.control.wipeHasPicture && wipe.control.curtainArmed && !wipe.locked && wipe.progress < 1
        property var shot: shotTex
        property var shellThen: thenTex
        // (This quad is the consumer that makes the host's grab land, so it stays bound until the host has MISSED: Theme's 120 ms fallback, a cold first frame. A texture
        // that missed is an older switch's, and the shell as it stood at the capture is the old shell.)
        property var shellOld: wipe.host.missed ? thenTex : wipe.host.picture
        property var shellNow: nowTex
        property vector2d size: Qt.vector2d(width, height)
        property vector2d origin: Qt.vector2d(wipe.originX, wipe.originY)
        property real progress: wipe.progress
        property real soft: wipe.soft
        property real seed: wipe.seed
        property real style: wipe.styleIndex
        property real px1: 1 / wipe._dpr
        property color surfOld: oldPalette.map ? oldPalette.map.surface : Theme.surface
        property color inkOld: oldPalette.map ? oldPalette.map.textPrimary : Theme.textPrimary
        property color surfNew: Theme.surface
        property color inkNew: Theme.textPrimary
        property vector4d holeA: wipe.host._hA
        property vector4d holeB: wipe.host._hB
        property vector4d holeC: wipe.host._hC
        property vector4d holeD: wipe.host._hD
        property vector4d holeR: wipe.host._hR
        property vector4d holeH: wipe.host._hH
        fragmentShader: "../common/components/shaders/curtain_over.frag.qsb"
    }
}
