pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

import Quickshell.Hyprland

import "../../common/components"
import "../../common/scroll"
import "../../common/scroll/HeldPointer.js" as Held
import "../../shell/scale"
import "../../shell/cursor"
import "../../shell/perf"

// =============================================================================
// ToastPillWindow.qml -- the toast stack's own window while the bars are hidden: a layer-shell surface on the Overlay layer at the
// screen's top right, taking input ONLY on the plate (the stack's cards are clicked, swiped and replied to; everything else on the
// screen passes through), transparent. It holds one ToastPill (the toasts get the OSD's pill while the bars are
// hidden). The window is as large as the largest stack plus the shadow's reach and never resizes (a resizing layer surface is a
// configure round trip per frame): the plate moves inside it.
//
// THE KEYBOARD. A reply typed into a toast asks the content for it (`keyboardFocusRequest`); the window maps it as the bar window
// does. A swipe under way holds the whole window as input (the cards leave the plate's rect sideways).
//
// THE SCALE: `scale.pills.toast` (the popups' ratio when it has none), as the OSD's pill; its own theme host (Theme commits once for
// every window with themed content).
// =============================================================================
PanelWindow {
    id: win
    FrameJournalHook { windowName: "toast-pill"; screenName: win._name }

    // the OSD's style (the pill's material and its margin): not the notifications' -- named so
    property var pillStyle: null
    readonly property var _sc: win.screen
    readonly property string _name: win._sc ? win._sc.name : ""
    property real renderScale: ShellScale.pillRender(win._name, "toast")
    readonly property real _ratio: ShellScale.pillRatio(win._name, "toast")
    readonly property real _k: ShellScale.frameScale(body, win._name) * win._ratio
    readonly property alias pill: toastPill
    // a live shell: a side-button swipe may move the real pointer (back)
    property bool live: false
    // The live curtain on this screen (OsdPillWindow has the reason)
    property var lineWipe: null

    // design px: the widest stack (a toast's width + its padding) and room for the five toasts' height, and the shadow's reach
    readonly property real _reach: 22
    readonly property real _designW: 460 + 2 * win._reach
    readonly property real _designH: 780 + win._reach
    readonly property int _marginTop: Math.round((win.pillStyle ? win.pillStyle.pillTop : 12) * win._k) - Math.round(win._reach * win._k)
    readonly property int _marginRight: Math.round(12 * win._k) - Math.round(win._reach * win._k)

    anchors {
        top: true
        right: true
    }
    // qmllint disable missing-property
    // (PanelWindow's `margins` is a value type the linter's Quickshell types do not describe; Quickshell reads it)
    margins {
        top: win._marginTop
        right: win._marginRight
    }
    // qmllint enable missing-property
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "toast-pill"
    WlrLayershell.keyboardFocus: toastPill.keyboard === "exclusive" ? WlrKeyboardFocus.Exclusive
        : toastPill.keyboard === "onDemand" ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    color: "transparent"
    implicitWidth: Math.ceil(win._designW * win._k)
    implicitHeight: Math.ceil(win._designH * win._k)
    visible: toastPill.showing
    mask: inputRegion
    Region {
        id: inputRegion
        Region { item: toastPill.showing ? toastPill.plate : null }
        Region { item: toastPill.gestureActive || sideSwipe.grabbing ? holdAll : null }
    }

    Item {
        id: body
        anchors.fill: parent
        ScaleRoot {
            id: scaled
            factor: win._k
            hostWidth: body.width
            hostHeight: body.height
            // the whole window, while a swipe holds it
            Item {
                id: holdAll
                width: scaled.width
                height: scaled.height
            }
            ToastPill {
                id: toastPill
                style: win.pillStyle
                x: Math.round(scaled.width - win._reach - width)
                y: Math.round(win._reach)
            }
        }
    }
    ThemeCrossfade {
        target: body
        anchors.fill: body
        lineWipe: win.lineWipe
        linePlace: Qt.rect((win.lineWipe ? win.lineWipe.width : win.width) - win.width - win._marginRight, win._marginTop, win.width, win.height)
    }
    // The mouse's side buttons as a two-finger swipe (a verb), as in the shell's own window.
    SideSwipe {
        id: sideSwipe
        holds: win.live
        onPointer: (what, dx, dy) => Hyprland.dispatch(Held.expr(what, dx, dy))
    }
    CursorCover {
        anchors.fill: parent
        hidden: sideSwipe.hiding
    }
}
