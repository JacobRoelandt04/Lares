pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/float"

// =============================================================================
// ThemeCard.qml -- one mode of one pair: a mini desktop that floats, tilts towards the pointer and, clicked, applies that mode of that pair.
//
//   colors             the pair's data (ThemePairs); a click says `picked()`
//   active             the shell is in this pair and mode: the card wears its own accent as a ring, and that is the only mark
//   current            the hand is on it (the pointer, or the keys): it lifts
//   clock              the popup's FloatClock: the card is a FloatCard on it (modules/common/float). Nothing here runs a clock of its own
//
// THE MOTION IS ON THE PICTURE, THE INPUT IS NOT. The MouseArea stays on the card's resting rect, so a card that sways never moves out from under the pointer and the
// tilt never chases itself. The face is one held texture (a layer, at `faceScale` x the glass): thirty Rectangles of 2 px under a slow rotation shimmer, a texture
// sampled with mipmaps does not, and a frame of the float costs a quad per card however much is drawn on it. Its rounded edge is cut per device pixel
// (shaders/theme_card.frag), because the tilt turns it.
// =============================================================================
Item {
    id: card

    required property ThemeStyle style
    required property var colors
    required property int seed
    property FloatClock clock: null
    property bool active: false
    property bool current: false
    // The popup is a theme island: the one themed thing here, the shadow, goes old -> new by the line. Everything else on a card is the pair's own.
    property bool islandArmed: false
    // the deal's order in the popup
    property int order: 0

    signal picked()
    signal hoverEntered()
    signal hoverLeft()

    width: card.style.cardWidth
    height: card.style.cardHeight

    // ---- the pose: the FloatCard's, one step of the clock old ------------------------------------------------------------------------------------
    property real _px: 0
    property real _py: 0
    // Where a strand leaves the card: the middle of its side, at the pose.
    readonly property real sideY: card.y + card.height / 2 + body.poseY
    readonly property real rightX: card.x + card.width + body.poseX
    readonly property real leftX: card.x + body.poseX

    FloatCard {
        id: body
        anchors.fill: parent
        clock: card.clock
        style: card.style
        seed: card.seed
        order: card.order
        lifted: card.current
        tilting: hover.containsMouse && card.current
        pointerX: card._px
        pointerY: card._py

        FadeColor {
            id: shadowFade
            token: "shadowDeep"
            active: card.islandArmed
            place: card
        }
        ShadowBox {
            anchors.fill: parent
            baseRadius: card.style.cardRadius
            raised: true
            shadowToAlpha: true
            surfaceColor: Theme.surface
            backgroundColor: card.colors.surface
            bevelColor: card.colors.surface
            shadowColor: shadowFade.value
            bevelWidth: 1
            shadowWidth: card.style.shadowWidth
        }

        DeviceScale {
            id: dev
        }
        // One texture: the face and the ring, with a margin the edge's antialiasing can land in.
        Item {
            id: held
            readonly property real m: 2
            x: -held.m
            y: -held.m
            width: card.width + 2 * held.m
            height: card.height + 2 * held.m
            layer.enabled: true
            layer.smooth: true
            layer.mipmap: true
            layer.textureSize: Qt.size(Math.ceil(held.width * dev.value * card.style.faceScale), Math.ceil(held.height * dev.value * card.style.faceScale))
            layer.effect: ShaderEffect {
                property real boxW: held.width
                property real boxH: held.height
                property real radius: card.style.cardRadius
                property real inset: held.m
                fragmentShader: "shaders/theme_card.frag.qsb"
            }
            ThemeCardFace {
                x: held.m
                y: held.m
                width: card.width
                height: card.height
                colors: card.colors
                radius: card.style.cardRadius
            }
            Rectangle {
                x: held.m
                y: held.m
                width: card.width
                height: card.height
                radius: card.style.cardRadius
                visible: card.active
                color: "transparent"
                border.width: 2
                border.color: card.colors.accent
            }
        }
    }

    MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: card.active ? Qt.ArrowCursor : Qt.PointingHandCursor
        onPositionChanged: mouse => {
            card._px = Math.max(-1, Math.min(1, mouse.x / card.width * 2 - 1));
            card._py = Math.max(-1, Math.min(1, mouse.y / card.height * 2 - 1));
            if (!card.current)
                card.hoverEntered();
        }
        onContainsMouseChanged: {
            if (hover.containsMouse)
                card.hoverEntered();
            else
                card.hoverLeft();
        }
        onClicked: {
            body.kick(card.style.clickKick);
            card.picked();
        }
    }
}
