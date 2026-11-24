pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

import "../common/components"
import "../shell/scale"
import "../shell/cursor"
import "../shell/perf"

// =============================================================================
// AuthPillWindow.qml -- the auth card over a fullscreen window.
//
// The bar's engine window is on the Top layer, so a toast is under a
// fullscreen client (and NotificationHolds holds it there). The request still
// has to be answerable, so AuthOwner presents the same AuthCard here: a
// layer-shell surface on the Overlay layer (the OSD pill's precedent), top
// centre, transparent, spanning the output.
//
//   mask            the pill's box -- or the whole output while the card is
//                   sticky with the pointer off it (`card.catchAll`): the
//                   click elsewhere lands on this surface and releases the
//                   keyboard instead of reaching nobody (measured)
//   keyboardFocus   Exclusive while the card is armed (the pointer MOVED onto
//                   it, or a key latched it), None otherwise; Hyprland gives
//                   the keyboard back to the previous client by itself
//
// The surface never resizes: the pill moves inside it. The owner makes one for
// the screen it shows the request on.
//
// THE SCALE. The pill sits under a ScaleRoot, laid out in DESIGN px as the bar window's frame is: k = the configured
// scale over THIS window's pixel ratio (ShellScale) times the POPUP ratio (shell.jsonc `scale.popup`): the card is a popup's content (the
// lane's, in the engine), so over a fullscreen window it is the size it is there. The window itself stays output-sized; the mask's box
// region maps through the transform, the whole-output one is in the window's own px.
//
// THE THEME SWITCH. A window of its own needs a crossfade host of its own (Theme
// waits for every window's host and commits once): the pill sits in `body`, the
// host is its SIBLING above it and covers the whole body -- the pill's shadow
// reaches past its box, so the picture is the window's whole content area. The
// window exists only while a request is shown over a fullscreen window, and so
// does the host's texture (one output's worth).
// =============================================================================
PanelWindow {
    id: win
    FrameJournalHook { windowName: "auth-pill"; screenName: win._name }

    // The AuthOwner that shows this window: the request, its buffer, the
    // privacy rule and the sizes are all read from it.
    property var host: null
    property real boxTop: 56
    property string fontFamily: "Inter"
    readonly property alias pill: pillItem
    readonly property var card: pillItem.card
    screen: win.host ? win.host.pillScreen : null
    // (a var: qmllint does not know QuickshellScreenInfo's `name`)
    readonly property var _sc: win.screen
    readonly property string _name: win._sc ? win._sc.name : ""
    // the popup ratio on the frame, and the Item scale of the pill's root: configured / this window's pixel ratio, x the ratio
    readonly property real _ratio: ShellScale.ratio(win._name, "popup")
    readonly property real _k: ShellScale.frameScale(body, win._name) * win._ratio

    anchors {
        top: true
        left: true
        right: true
        bottom: true
    }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "auth-pill"
    WlrLayershell.keyboardFocus: win.card.keyboardRequest === "exclusive" ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    color: "transparent"
    mask: win.card.catchAll ? wholeOutput : boxRegion

    Region {
        id: boxRegion
        item: pillItem
    }
    Region {
        id: wholeOutput
        x: 0
        y: 0
        width: win.width
        height: win.height
    }

    Item {
        id: body
        anchors.fill: parent
        ScaleRoot {
            id: scaled
            factor: win._k
            hostWidth: body.width
            hostHeight: body.height
            AuthPill {
                id: pillItem
                x: Math.round((scaled.width - width) / 2)
                y: Math.round(win.boxTop)
                broker: win.host ? win.host.broker : null
                requestId: win.host ? win.host.pillId : ""
                buffer: win.host ? win.host.bufferOf(win.host.pillId) : null
                privacy: win.host
                look: win.host ? win.host.look : null
                fontFamily: win.fontFamily
            }
        }
    }
    ThemeCrossfade {
        target: body
        anchors.fill: body
    }
    CursorCover {
        anchors.fill: parent
    }
}
