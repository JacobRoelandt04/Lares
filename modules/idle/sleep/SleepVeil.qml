pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

// =============================================================================
// SleepVeil.qml -- ONE OUTPUT'S SLEEP VEIL: a layer-shell window over the whole output that holds one capture of it and draws the
// screen falling asleep / waking over everything (SleepVeilEffect). SleepFade runs the sequence; this is the window. (SLEEP.md)
//
// WHAT IT IS. A PanelWindow on the OVERLAY layer, namespace `lares-bar` ON PURPOSE: the veil may be drawn exactly where the bars may -- above
// the Lares lock and only that lock (lares-lock sets the namespace's above_lock rule at every launch and back to 0 when it ends, so over
// hyprlock it is under the lock), and never faded in or out by the compositor (the namespace's no_anim rule). Mapped later than the bar
// window and on a higher layer, it is over the bars, the lock's popup and the lock. An EMPTY input region and no keyboard: the lock (or
// whatever is under it) keeps the keys and the pointer the whole time. Mapped only while a fade covers this output; at rest there is no
// surface and the capture machinery is unloaded.
//
// THE CAPTURE (SleepFade.captureSerial). Each ask builds a FRESH ScreencopyView (a used one already `hasContent`, so a new frame could
// not be told from the old), asks the compositor for one frame after two presented frames of this window, retries until a frame is there
// (the compositor needs a moment), copies it through a mipmapped ShaderEffectSource (a ScreencopyView fed straight into a
// shader reads black) and JUDGES THE COPY before it is a picture (SleepCapture.check, PictureProbe): an EMPTY copy -- all transparent or
// all black, which the veil would draw as a black screen over the fall and the wake -- is asked again with a fresh view, up to
// three copies, and then the veil goes on WITHOUT a picture (the vignette and the light over the live screen), logging
// `LARESSLEEP <out> <ms> picture empty (<n>)` for each. A copy with ink answers `fade.captured(name, ok)`. While the fade asks for a CLEAR capture (a
// wake: the panel is dark) this window draws nothing, so the picture is the screen to wake to -- except on an output the veil dims ITSELF
// (an external screen, a panel that is not ours): that output is LIT, a clear frame would flash the live screen, so it keeps the picture
// it already holds and answers at once. An answer that comes after the fade stopped waiting is ignored: the veil goes on without a
// picture rather than have one pop in mid-fade.
// =============================================================================
PanelWindow {
    id: win

    property var fade: null

    // qmllint disable missing-property
    // (Screen.name is Quickshell's, absent from the linter's description of QuickshellScreenInfo)
    readonly property string outputName: win.screen ? win.screen.name : ""
    // qmllint enable missing-property
    readonly property bool covered: !!win.fade && win.fade.shown && win.fade.covers(win.outputName)
    readonly property bool dimsItself: !!win.fade && win.fade.selfDims(win.outputName)
    // this window draws nothing while it takes a clear capture
    readonly property bool clear: !!win.fade && !win.fade.drawing && !win.dimsItself

    visible: win.covered
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "lares-bar"
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
    mask: Region {}

    // how many copies may come out empty before the veil goes on without a picture
    readonly property int _emptyAsks: 3

    property bool _pictureOk: false
    property int _tries: 0
    property int _empty: 0
    property int _gen: 0
    property bool _asking: false

    function _log(msg: string): void {
        console.log("LARESSLEEP " + win.outputName + " " + Date.now() + " " + msg);
    }

    Connections {
        target: win.fade
        function onCaptureSerialChanged() {
            win._begin();
        }
    }
    onCoveredChanged: {
        if (!win.covered) {
            win._asking = false;
            win._pictureOk = false;
            win._swapFn = null;
            // the capture goes with the fade: the next fade builds its first view at its first ask, like the first fade of the
            // process (a generation left above 0 built a view the moment the veil mapped -- a screencopy of the unlocked desktop at
            // every sleep but the first, while the lock takes its own picture of the output)
            win._gen = 0;
        }
    }

    function _begin(): void {
        if (!win.covered)
            return;
        if (win.fade.drawing === false && win.dimsItself) {
            // a lit output keeps the picture it has (no clear frame over a lit screen)
            win.fade.captured(win.outputName, win._pictureOk);
            return;
        }
        win._pictureOk = false;
        win._tries = 0;
        win._empty = 0;
        win._asking = true;
        win._gen++;
        win._afterSwaps(2, win._ask);
    }
    function _ask(): void {
        if (!win._asking)
            return;
        win._tries++;
        const cap = capLoader.item as SleepCapture;
        if (cap)
            cap.capture();
        win._afterSwaps(2, win._arrived);
    }
    function _arrived(): void {
        if (!win._asking)
            return;
        const cap = capLoader.item as SleepCapture;
        if (!cap || !cap.hasContent) {
            if (win._tries >= 12) {
                win._asking = false;
                win._log("no capture after " + win._tries + " tries");
                win.fade.captured(win.outputName, false);
                return;
            }
            retry.start();
            return;
        }
        cap.copy();
        cap.check();
    }
    Connections {
        target: capLoader.item
        ignoreUnknownSignals: true
        function onChecked(verdict: string, inked: int, samples: int) {
            win._checked(verdict, inked, samples);
        }
    }
    function _checked(verdict: string, inked: int, samples: int): void {
        if (!win._asking)
            return;
        if (verdict === "empty") {
            win._empty++;
            win._log("picture empty (" + win._empty + ")");
            if (win._empty < win._emptyAsks) {
                // a fresh view, as every ask of a fade starts with
                win._gen++;
                win._afterSwaps(2, win._ask);
                return;
            }
            win._asking = false;
            win._log("no picture: " + win._empty + " copies came out empty; the veil goes on without one");
            win.fade.captured(win.outputName, false);
            return;
        }
        if (verdict !== "ink")
            win._log("picture not checked (" + verdict + "): kept");
        win._done();
    }
    function _done(): void {
        if (!win._asking)
            return;
        win._asking = false;
        // a late answer is no answer: the fade went on without this picture
        win._pictureOk = win.fade.capturing;
        win._log("captured after " + win._tries + " ask(s)" + (win._pictureOk ? "" : " (late, unused)"));
        win.fade.captured(win.outputName, win._pictureOk);
    }
    Timer {
        id: retry
        interval: 30
        onTriggered: win._ask()
    }

    // ---- presented frames of THIS window (DesktopLayer's / the curtain's accounting) -----------------------------------------------
    property int _swapWait: 0
    property var _swapFn: null
    readonly property var _scene: stage.Window.window
    function _afterSwaps(n: int, fn: var): void {
        win._swapWait = n;
        win._swapFn = fn;
        if (win._scene)
            win._scene.update();
    }
    Connections {
        target: win._scene
        function onFrameSwapped() {
            if (win.fade)
                win.fade.presented();
            if (win._swapFn === null)
                return;
            if (--win._swapWait > 0) {
                win._scene.update();
                return;
            }
            const fn = win._swapFn;
            win._swapFn = null;
            fn();
        }
    }

    Item {
        id: stage
        anchors.fill: parent

        // a fresh capture per ask: the two components are the same, and switching between them (`_gen` odd / even) builds a new one;
        // unloaded at rest, its texture with it
        Loader {
            id: capLoader
            anchors.fill: parent
            active: win.covered && win._gen > 0
            sourceComponent: win._gen % 2 === 1 ? capOdd : capEven
        }
        Component {
            id: capOdd
            SleepCapture {
                output: win.screen
            }
        }
        Component {
            id: capEven
            SleepCapture {
                output: win.screen
            }
        }

        SleepVeilEffect {
            anchors.fill: parent
            visible: win.covered && !win.clear
            picture: win._pictureOk && capLoader.item ? (capLoader.item as SleepCapture).texture : null
            dimsItself: win.dimsItself
            renderScale: win.devicePixelRatio > 0 ? win.devicePixelRatio : 1
            progress: win.fade ? win.fade.progress : 0
            strength: win.fade ? win.fade.dream : 0
            seed: win.fade ? win.fade.seed : 0
        }
    }
}
