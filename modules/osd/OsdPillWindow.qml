pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

import "../shell/scale"
import "../shell/cursor"
import "../shell/perf"

// =============================================================================
// OsdPillWindow.qml -- the pill's own window: a layer-shell surface on the
// Overlay layer (above a fullscreen window), anchored to the top edge (so the
// compositor centres it), taking no space (`exclusionMode: Ignore`), no keyboard
// focus, and NO POINTER but where the pill asks for it: its input region is the
// frame's two zones -- the caption's hide button while the card is out, the parked
// ball's hover area while it is hidden -- so every click anywhere else goes through
// to what is below. Transparent; it holds one OsdPillFrame (the pill and all of
// the above), which a harness can host in a plain window. The final assembly makes
// one per screen.
//
// The window is as wide as the widest pill of every kind plus the drop shadow's
// reach, as tall as the tallest (OsdStyle.pillWindowExtent): the pill moves inside
// it, the surface never resizes (a resizing layer surface is a configure round trip
// per frame).
//
// THE SCALE (shell.jsonc `scale.pills.osd`, the popups' ratio when it has none). The pill is laid out in DESIGN px under a ScaleRoot, as the bar window's frame is: k = the configured
// scale over THIS window's pixel ratio (ShellScale) times the POPUP ratio (shell.jsonc `scale.popup`), so the window is the design size x k
// in compositor px and a design px is `configured x ratio` device px at any Hyprland scale. The OSD is a popup's content wherever it is
// shown: in the engine's OSD slot it sits under the popup ratio, and in this window -- over a fullscreen window -- it must be the same
// size, or it changes size as it moves. `renderScale` (device px per
// design px) is ShellScale's "popup" one unless the host gives one.
//
// THE THEME SWITCH: the frame holds the crossfade host (OsdPillFrame). A window
// that is not shown declines the switch, so a hidden pill holds nothing up.
// =============================================================================
PanelWindow {
    id: win
    FrameJournalHook { windowName: "osd-pill"; screenName: win._name }

    // An exposed window of its own only while the pill shows (one exposed window is what keeps the process's animations on vsync: ShellScreen, ONE EXPOSED WINDOW), or
    // while its host asks: `keepMapped`, the bar window covered by a fullscreen window.
    property bool keepMapped: false
    visible: frame.pill.showing || win.keepMapped

    property var style: null
    // (a var: qmllint does not know QuickshellScreenInfo's `name`)
    readonly property var _sc: win.screen
    readonly property string _name: win._sc ? win._sc.name : ""
    // device px per design px: what the pill's textures are made at (the global x the popup ratio, as the engine's OSD slot has it)
    property real renderScale: ShellScale.pillRender(win._name, "osd")
    // the popup ratio on the frame, and the Item scale of the pill's root: configured / this window's pixel ratio, x the ratio
    readonly property real _ratio: ShellScale.pillRatio(win._name, "osd")
    readonly property real _k: ShellScale.frameScale(frame, win._name) * win._ratio
    readonly property alias pill: frame.pill
    // where the window takes input (the frame's zones, in this window's px)
    readonly property alias hideZone: frame.hideZone
    readonly property alias ballZone: frame.ballZone
    // The live curtain on this screen: this window is over the shell's, so outside its pictures, and cut by the same line (ThemeCrossfade), from its place on the screen.
    property var lineWipe: null

    anchors {
        top: true
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "osd-pill"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    color: "transparent"
    // (zones with no size add nothing: with neither, the region is empty and the window click-through)
    mask: Region {
        Region { item: frame.ballZone }
        Region { item: frame.hideZone }
    }

    implicitWidth: frame.implicitWidth
    implicitHeight: frame.implicitHeight

    OsdPillFrame {
        id: frame
        anchors.fill: parent
        style: win.style
        renderScale: win.renderScale
        k: win._k
        lineWipe: win.lineWipe
        // (anchored to the top edge: the compositor centres it)
        linePlace: Qt.rect(((win.lineWipe ? win.lineWipe.width : win.width) - win.width) / 2, 0, win.width, win.height)
    }
    CursorCover {
        anchors.fill: parent
    }
}
