pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../osd"

// =============================================================================
// ToastPill.qml -- the toast stack while the bars are hidden: there is no bar for it to melt back into, so it
// gets a pill like the OSD's.
//
// The stack's own content (NotificationToast, handed in by its owner as `contentComponent`: the lane's, with the service, the clock
// and the style it has there) in a floating plate of the OSD pill's material -- a raised ShadowBox whose shadow blends to alpha, since it
// floats over whatever is on the screen. Nothing is attached to anything: the content has no host room (every corner is a corner).
//
//   present   the owner's wish: the stack is wanted here (a toast is shown on this screen). It FADES in and out (160 ms, the shell's
//             presence) -- a plate is not born from a dot as a one-line OSD is, a stack has height to show -- and the plate's height
//             EASES to the stack's (260 ms OutCubic: the resize rule), the content's rows easing their own rooms on the same clock.
//   the content is built while the pill is up or fading, and destroyed when it is gone (a toast stack that is not shown runs nothing).
//
// `plate` is what the window's input region is (ToastPillWindow); `gestureActive` and `keyboard` are the content's contract read through.
// =============================================================================
Item {
    id: root

    property Component contentComponent: null
    property bool present: false
    // The host's resting radius (the engine's maxR, as the lane's content is given it).
    property real cornerRadius: 20
    // The OSD's style: the pill's material (shadow, bevel).
    property var style: null
    readonly property var _style: root.style ? root.style : ownStyle
    OsdStyle {
        id: ownStyle
    }

    // 0 .. 1: the presence.
    property real _f: 0
    readonly property bool showing: root.present || root._f > 0.001
    readonly property alias plate: plateBox
    // (the content's own members: it is the toast stack, which declares them -- the Loader's item is typed as an Item)
    readonly property var _c: ld.item
    readonly property Item _it: ld.item as Item
    readonly property bool gestureActive: root._c ? root._c["swipeGestureActive"] === true : false
    readonly property string keyboard: root._c && root._c["keyboardFocusRequest"] ? String(root._c["keyboardFocusRequest"]) : "none"
    // The stack's width and the plate's height now.
    readonly property real contentW: root._it ? root._it.implicitWidth : 0
    readonly property real _target: root._it ? root._it.implicitHeight : 0
    property real _h: 0

    implicitWidth: Math.ceil(root.contentW)
    implicitHeight: Math.round(root._h)
    visible: root.showing

    on_TargetChanged: {
        if (root._f < 0.01 || !root.present) {
            grow.stop();
            root._h = root._target;
        } else {
            // (`to` is a binding on the same property: it follows after this handler, so it is written here)
            grow.stop();
            grow.to = root._target;
            grow.start();
        }
    }
    NumberAnimation {
        id: grow
        target: root
        property: "_h"
        duration: 260
        easing.type: Easing.OutCubic
    }

    onPresentChanged: {
        fade.stop();
        fade.to = root.present ? 1 : 0;
        fade.start();
    }
    NumberAnimation {
        id: fade
        target: root
        property: "_f"
        duration: 160
        easing.type: Easing.OutCubic
    }

    Item {
        id: lift
        width: root.implicitWidth
        height: root.implicitHeight
        // a settle of a few px on arrival: the plate comes down into its place
        y: Math.round((1 - root._f) * -8)
        opacity: root._f

        ShadowBox {
            id: plateBox
            width: lift.width
            height: lift.height
            raised: true
            shadowToAlpha: true
            baseRadius: root.cornerRadius
            surfaceColor: Theme.surface
            bevelColor: Theme.bevel
            shadowColor: Theme.shadowDeep
            backgroundColor: Theme.surface
            bevelWidth: root._style.pillBevel
            shadowWidth: root._style.pillShadow
            shadowEdgeAlpha: root._style.pillShadowAlpha
        }
        Item {
            id: clipBox
            width: lift.width
            height: lift.height
            clip: true
            Loader {
                id: ld
                active: root.showing
                sourceComponent: root.contentComponent
                width: root.contentW
                height: root._target
            }
        }
    }
}
