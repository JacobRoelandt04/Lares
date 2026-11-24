pragma ComponentBehavior: Bound

import QtQuick

import "../common/components"

// =============================================================================
// OsdPillFrame.qml -- everything of the pill's window but the window: OsdPillWindow fills itself with one, and a
// harness hosts the same frame in a plain window (tools/dev/osd_pill_probe.sh), so what is checked is what is shown.
//
//   style, renderScale    the OsdStyle; device px per design px (the pill's textures)
//   k                     the Item scale of the pill: design px -> this frame's px (the window's compositor px)
//   lineWipe, linePlace   the live curtain on this screen and this frame's place on it (ThemeCrossfade)
//   implicitWidth/Height  the window's size: OsdStyle.pillWindowExtent() (every kind's largest pill, the drop shadow's
//                         reach round it, the top margin) times k, in whole px
//   pill                  the OsdPill, centred at the top under `pillTop`, raised by its own `offsetY` (the ball)
//   ballZone, hideZone    the input the window takes, in this frame's px (Items, for Region { item }: they are this
//                         frame's own children at fixed places, so a Region follows them): the parked ball's hover area
//                         and the content's hide button. Neither has a size otherwise -- the pill is click-through.
//
// The ball is hovered here: a pointer that MOVED onto it (HoverArm: a window that maps or grows its region under a resting
// pointer gets an enter at once, which is no motion) asks the pill to `reveal()`, which asks its owner.
//
// THE THEME SWITCH. The window is one of its own, so it needs a crossfade host of its own (Theme waits for every window's
// host, then commits once): the pill sits in `body`, the host is its SIBLING above it and covers the whole body -- the pill
// moves inside the window and its drop shadow reaches past its rect, so the host's picture is the window's whole content
// area, not the pill.
// =============================================================================
Item {
    id: frame

    property var style: null
    property real renderScale: 1
    property real k: 1
    property var lineWipe: null
    property rect linePlace: Qt.rect(0, 0, 0, 0)

    readonly property alias pill: pillItem
    readonly property alias ballZone: ballZoneItem
    readonly property alias hideZone: hideZoneItem

    OsdStyle {
        id: ownStyle
    }
    readonly property var _style: frame.style ? frame.style : ownStyle
    readonly property var extent: frame._style.pillWindowExtent()

    implicitWidth: Math.ceil(frame.extent.w * frame.k)
    implicitHeight: Math.ceil(frame.extent.h * frame.k)

    Item {
        id: body
        anchors.fill: parent
        ScaleRoot {
            id: scaled
            factor: frame.k
            hostWidth: body.width
            hostHeight: body.height
            OsdPill {
                id: pillItem
                style: frame._style
                renderScale: frame.renderScale
                x: Math.round((scaled.width - width) / 2)
                y: Math.round(frame._style.pillTop + pillItem.offsetY)
            }
        }
    }
    ThemeCrossfade {
        target: body
        anchors.fill: body
        lineWipe: frame.lineWipe
        linePlace: frame.linePlace
    }

    // A rect in the pill's px, in this frame's: whole px, cut to the frame.
    function _zone(r: rect): rect {
        if (!(r.width > 0) || !(r.height > 0))
            return Qt.rect(0, 0, 0, 0);
        const x0 = Math.max(0, Math.floor((pillItem.x + r.x) * frame.k)), y0 = Math.max(0, Math.floor((pillItem.y + r.y) * frame.k));
        const x1 = Math.min(frame.width, Math.ceil((pillItem.x + r.x + r.width) * frame.k));
        const y1 = Math.min(frame.height, Math.ceil((pillItem.y + r.y + r.height) * frame.k));
        return x1 > x0 && y1 > y0 ? Qt.rect(x0, y0, x1 - x0, y1 - y0) : Qt.rect(0, 0, 0, 0);
    }
    readonly property rect _ball: frame._zone(pillItem.ballRect)
    readonly property rect _hide: frame._zone(pillItem.hideRect)
    Item {
        id: ballZoneItem
        x: frame._ball.x
        y: frame._ball.y
        width: frame._ball.width
        height: frame._ball.height
    }
    Item {
        id: hideZoneItem
        x: frame._hide.x
        y: frame._hide.y
        width: frame._hide.width
        height: frame._hide.height
    }
    HoverArm {
        id: ballArm
        target: ballZoneItem
        active: pillItem.ballParked
        // (a turn later: the reveal ends `active`, which `armed` reads -- written from its own change handler it is a binding loop)
        onArmedChanged: {
            if (ballArm.armed)
                Qt.callLater(pillItem.reveal);
        }
    }
}
