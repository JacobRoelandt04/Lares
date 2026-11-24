pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

// =============================================================================
// ThemeCurtain.qml -- ONE SCREEN'S CURTAIN: a layer-shell window that holds a picture of the output as it was, and lets the new
// desktop through as a shader takes the picture away. (A PROTOTYPE behind shell.jsonc `"theme": { "curtain": true }`, off by
// default; ThemeControl runs the sequence, this is the window.)
//
// WHAT IT IS. A PanelWindow on the OVERLAY layer over the whole output (`exclusionMode: Ignore`), namespace `lares-curtain` (the
// compositor must not fade it: ThemeControl installs the `no_anim` layer rule before it maps one), transparent, with
//   - an EMPTY INPUT REGION and no keyboard: every click, key and wheel goes to the real windows under it. The curtain takes no
//     input, which is the whole answer to interacting during the transition (ThemeControl fast-forwards it instead);
//   - a ScreencopyView of the output (one frame, `live: false`), copied through a ShaderEffectSource (a ScreencopyView fed straight
//     into a shader reads black: CLAUDE.md, lockscreen DesktopLayer);
//   - a ShaderEffect that draws that picture with an alpha that follows `progress` through one of three reveal shaders
//     (modules/common/components/shaders/curtain_*.frag: radial, peel, louvres). The shader outputs the picture where
//     it still covers and NOTHING where it has opened, so the live desktop under the window shows there: the curtain never needs to
//     sample the desktop beneath itself, which it cannot.
//
// With `curtainLive` (ThemeWipe) this window is the curtain only of an output whose shell is covered by a fullscreen window: there is no shell in
// it to keep alive or to match.
//
// THE FRAMES. `armed` maps the window (clear, nothing drawn). The capture is asked for and retried until the compositor has a
// frame to give ("Cannot capture frame, as no recording context is ready"), the ShaderEffectSource copies it, and two presented
// frames later the picture is drawn at progress 0 -- identical to what is under it, so nothing moves -- and two more later `ready`
// is said: the picture is ON SCREEN. Only then may ThemeControl change the theme. Waits count presented frames of THIS window
// (frameSwapped, with window.update() to make sure some come), never milliseconds alone (DesktopLayer's rule).
//
// `phase`: "off" -> "capturing" -> "covering" -> "ready" -> (progress runs) -> "off". `failed` names why a capture gave up.
// =============================================================================
PanelWindow {
    id: win

    // ---- injected by ThemeControl -----------------------------------------------------------------------------
    property bool armed: false
    // "radial" | "peel" | "louvres"
    property string style: "radial"
    // 0 = the old picture covers the output, 1 = gone. One clock, ThemeControl's.
    property real progress: 0
    // The reveal's start, in this window's px (the theme button, where the pointer was); NaN = the middle of the output.
    property real originX: NaN
    property real originY: NaN
    // The shader's feather (px) and the noise seed.
    property real soft: 28
    property real seed: 0

    // ---- what it says -----------------------------------------------------------------------------------------
    readonly property string phase: win._phase
    readonly property string failed: win._failed
    // The picture is on screen and the window is ready for the theme to change.
    readonly property bool ready: win._phase === "ready"
    signal failedCapture(string why)

    visible: win.armed
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "lares-curtain"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }
    color: "transparent"
    surfaceFormat.opaque: false
    // an empty region: the pointer, the keys and the wheel go through to what is below
    mask: emptyRegion
    Region {
        id: emptyRegion
    }

    property string _phase: "off"
    property string _failed: ""
    property int _tries: 0
    property bool _drawn: false

    // qmllint disable missing-property
    // (Screen.name is Quickshell's, absent from the linter's description of QuickshellScreenInfo)
    readonly property string outputName: win.screen ? win.screen.name : "?"
    function _log(msg: string): void {
        console.log("LARESCURTAIN " + win.outputName + " " + Date.now() + " " + msg);
    }

    onArmedChanged: {
        if (win.armed) {
            win._phase = "capturing";
            win._failed = "";
            win._tries = 0;
            win._drawn = false;
            win._afterSwaps(2, win._ask);
            win._log("armed");
        } else {
            win._phase = "off";
            win._drawn = false;
            win._swapFn = null;
            guard.stop();
            retry.stop();
        }
    }

    // ---- the capture ------------------------------------------------------------------------------------------
    // A ScreencopyView needs a moment after its source is set before it can capture, so the ask is retried until a frame is there.
    function _ask(): void {
        if (!win.armed)
            return;
        win._tries++;
        cap.captureFrame();
        win._afterSwaps(2, win._arrived);
    }
    function _arrived(): void {
        if (!win.armed)
            return;
        if (!cap.hasContent) {
            if (win._tries >= 40) {
                win._failed = "no capture after " + win._tries + " tries";
                win._phase = "off";
                win._log("FAILED " + win._failed);
                win.failedCapture(win._failed);
                return;
            }
            retry.start();
            return;
        }
        win._log("captured after " + win._tries + " ask(s) " + cap.width + "x" + cap.height);
        win._phase = "covering";
        tex.scheduleUpdate();
        win._afterSwaps(2, win._covering);
    }
    function _covering(): void {
        if (!win.armed)
            return;
        // the picture goes on screen at progress 0: identical to what lies beneath it
        win._drawn = true;
        win._afterSwaps(2, win._covered);
    }
    function _covered(): void {
        if (!win.armed)
            return;
        win._phase = "ready";
        win._log("ready (the picture is on screen)");
    }
    Timer {
        id: retry
        interval: 25
        onTriggered: win._ask()
    }

    // ---- frame accounting (DesktopLayer's) ---------------------------------------------------------------------
    property int _swapWait: 0
    property var _swapFn: null
    function _afterSwaps(n: int, fn: var): void {
        win._swapWait = n;
        win._swapFn = fn;
        guard.restart();
        win._poke();
    }
    // the window's own scene (a PanelWindow is a Quickshell type; update() and frameSwapped are QQuickWindow's)
    readonly property var _scene: stage.Window.window
    function _poke(): void {
        if (win._scene)
            win._scene.update();
    }
    // THE REVEAL'S PACE: the frames this window presented while the picture was opening, and the longest gap between two
    // (ThemeControl logs them at the end of a run; a probe reads them).
    property int revealFrames: 0
    property real revealMaxGap: 0
    property real _lastFrameAt: 0
    onProgressChanged: {
        if (win.progress <= 0) {
            win.revealFrames = 0;
            win.revealMaxGap = 0;
            win._lastFrameAt = 0;
        }
    }
    Connections {
        target: win._scene
        function onFrameSwapped() {
            if (win.progress > 0 && win.progress < 1) {
                const now = Date.now();
                if (win._lastFrameAt > 0)
                    win.revealMaxGap = Math.max(win.revealMaxGap, now - win._lastFrameAt);
                win._lastFrameAt = now;
                win.revealFrames++;
            }
            if (win._swapFn === null)
                return;
            if (win._swapWait > 0)
                win._swapWait--;
            if (win._swapWait > 0) {
                win._poke();
                return;
            }
            const fn = win._swapFn;
            win._swapFn = null;
            guard.stop();
            fn();
        }
    }
    // qmllint enable missing-property
    // a window that presents nothing must not hold the switch for ever: go on, and say so
    StallTimer {
        id: guard
        interval: 400
        onTriggered: {
            const fn = win._swapFn;
            win._swapFn = null;
            win._log("WARN swap wait timed out in " + win._phase);
            if (fn)
                fn();
        }
    }

    // ---- what is drawn ----------------------------------------------------------------------------------------
    Item {
        id: stage
        anchors.fill: parent

        ScreencopyView {
            id: cap
            anchors.fill: parent
            // qmllint disable incompatible-type
            captureSource: win.screen
            // qmllint enable incompatible-type
            live: false
            paintCursor: false
            opacity: 0
        }
        // scale-ok: the curtain is a window of its own, never under the shell's magnifying transform; the capture is the output's own pixels
        ShaderEffectSource {
            id: tex
            anchors.fill: parent
            sourceItem: cap
            live: false
            visible: false
        }

        ShaderEffect {
            id: fx
            anchors.fill: parent
            visible: win._drawn && win.progress < 1
            property var src: tex
            // The path is computed, so it is a binding: until it lands the effect may hold Qt's built-in shader, which samples `source`.
            property var source: null
            property vector2d size: Qt.vector2d(fx.width, fx.height)
            property vector2d origin: Qt.vector2d(isNaN(win.originX) ? fx.width * 0.5 : win.originX, isNaN(win.originY) ? fx.height * 0.5 : win.originY)
            property real progress: win.progress
            property real soft: win.soft
            property real seed: win.seed
            fragmentShader: Qt.resolvedUrl("../common/components/shaders/curtain_" + win.style + ".frag.qsb")
        }
    }
}
