pragma ComponentBehavior: Bound

import QtQuick

import "../common/components"
import "../common/theme"

// =============================================================================
// AuthPill.qml -- the auth card on its own raised box: what AuthPillWindow puts
// on the Overlay layer over a fullscreen window, and what a mockup stands in
// for that window with. The box is the card plus a padding on every side; its
// size is its own (width/height), the drop shadow lies outside it.
//
// It eases in (presence only) when it appears. Whatever the pointer must be
// over to arm the card is this whole box (`armTarget`), not just the card.
// =============================================================================
Item {
    id: pill

    property var broker: null
    property string requestId: ""
    property PasswordBuffer buffer: null
    property var privacy: null
    property var look: null
    property real boxWidth: 380
    property real padding: 12
    property real radius: 14
    property string fontFamily: "Inter"
    readonly property alias card: card

    width: pill.boxWidth
    height: Math.ceil(card.implicitHeight + 2 * pill.padding)

    property real _in: 0
    Behavior on _in {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }
    Component.onCompleted: pill._in = 1
    opacity: pill._in

    ShadowBox {
        anchors.fill: parent
        raised: true
        shadowToAlpha: true
        baseRadius: pill.radius
        surfaceColor: "transparent"
        backgroundColor: Theme.surface
        bevelColor: Theme.bevel
        shadowColor: Theme.shadowDeep
        bevelWidth: 1.5
        shadowWidth: 8
    }

    AuthCard {
        id: card
        x: pill.padding
        y: pill.padding
        width: pill.width - 2 * pill.padding
        broker: pill.broker
        requestId: pill.requestId
        buffer: pill.buffer
        privacy: pill.privacy
        look: pill.look
        showHeader: true
        armTarget: pill
        ground: Theme.surface
        fontFamily: pill.fontFamily
        fieldHeight: pill.look ? pill.look.pillFieldHeight : 44
        fieldRadius: pill.look ? pill.look.pillFieldRadius : 22
        dotSize: pill.look ? pill.look.pillDotSize : 9
        glyphSize: pill.look ? pill.look.pillGlyphSize : 28
    }
}
