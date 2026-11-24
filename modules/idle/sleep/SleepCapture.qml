pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

import "../../common/components"

// =============================================================================
// SleepCapture.qml -- one capture of an output for the sleep veil (SleepVeil): a ScreencopyView asked for ONE frame (`live: false`),
// copied through a mipmapped ShaderEffectSource (a ScreencopyView fed straight into a shader reads black: CLAUDE.md, the lock's
// DesktopLayer; the veil's defocus reads the mip chain). Built fresh for every capture and destroyed with the veil's fade, so the
// output-sized texture and its mips (~25 MB at 2880 x 1620) are held only while a fade runs.
//
//   output       the ShellScreen to capture
//   capture()    ask the compositor for a frame (it may need asking again: `hasContent` says when one is there)
//   copy()       take that frame into `texture`, the texture provider the veil samples
//   check()      does the copy hold anything? `checked(verdict, inked, samples)` follows a frame or two later (PictureProbe: "ink",
//                "empty" -- all transparent or all black -- or "unknown"). The check's own pass is what brings the copy in, so the texture
//                judged is the texture the veil then draws.
// =============================================================================
Item {
    id: root

    property var output: null
    readonly property bool hasContent: cap.hasContent
    readonly property alias texture: tex

    signal checked(string verdict, int inked, int samples)

    function capture(): void {
        cap.captureFrame();
    }
    function copy(): void {
        tex.scheduleUpdate();
    }
    function check(): void {
        probe.judge();
    }

    ScreencopyView {
        id: cap
        anchors.fill: parent
        // qmllint disable incompatible-type
        captureSource: root.output
        // qmllint enable incompatible-type
        live: false
        paintCursor: false
        opacity: 0
    }
    // scale-ok: the veil is a window of its own, never under the shell's magnifying transform; the capture is the output's own pixels
    ShaderEffectSource {
        id: tex
        anchors.fill: parent
        sourceItem: cap
        live: false
        mipmap: true
        visible: false
    }
    PictureProbe {
        id: probe
        source: tex
        // qmllint disable missing-property
        // (Screen.name is Quickshell's, absent from the linter's description of QuickshellScreenInfo)
        file: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/lares-sleep-picture-" + (root.output ? root.output.name : "none") + ".xpm"
        // qmllint enable missing-property
        onJudged: (verdict, inked, samples) => root.checked(verdict, inked, samples)
    }
}
