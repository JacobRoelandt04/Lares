pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix
import "../../common/float"
import ".."

// =============================================================================
// DisplayTile.qml -- one display on the canvas: a plain, to-scale CARVED tile (decision 14) with its label (port + model), the figures
// in fixed slots (W x H on the left, @ Hz and the scale below), and a laptop mark on the panel's own tile.
//
//   selected   the accent inset (the side popup is on this one)
//   lifted     picked up: the carved tile fades to a RAISED one (one fraction, one clock)
//   ghost      the mirror's shadow behind the laptop's tile: dimmer, not draggable, still clickable
//   chip       a display that is off, parked under the canvas: label and "off", the same tile smaller
//   cast       a TV that is being cast to: the cast mark (md-cast) where the laptop's mark would be
//   note       one muted line under the label (the laptop's "Mirrored on HDMI · Sony TV"), shown with the figures
//
// Where it is drawn is its TileCarry's (x / y / width / height follow `carry`); the canvas moves it. The pointer is reported in
// the canvas's own coordinates: pressedAt / movedTo / releasedAt (a click is a press and a release with no travel, the canvas decides).
//
// THE FLOAT: the face is a FloatCard on the popup's one FloatClock (the theme popup's Balatro float: dealt in on open, a slow sway, a lean towards
// the pointer), and while that clock runs the face is HELD AS ONE TEXTURE (a mipmapped layer, `faceScale` times the glass: the sway then moves a
// quad, not the boxes and text -- PresetCard's rule). The input is declared BESIDE the FloatCard, on the tile's resting rect, so the hit area is
// stable however the card sways. A ghost and a chip are dealt in but do not sway; the carried tile follows the hand, translucent (`dragOpacity`).
// =============================================================================
Item {
    id: tile

    property string name: ""
    property string label: ""
    property string sizeText: ""
    property string rateText: ""
    property string scaleText: ""
    property string note: ""
    property bool internal: false
    property bool selected: false
    property bool lifted: false
    property bool ghost: false
    property bool chip: false
    property bool cast: false                       // a cast display (a TV): a small cast mark in the corner
    property color ground: Theme.listBox
    property string fontFamily: "Inter"
    property PanoramaStyle style: PanoramaStyle {}
    property FloatClock clock: null
    property int order: 0
    property int seed: 1

    readonly property alias carry: carrier
    readonly property bool hovered: area.containsMouse
    readonly property bool pressed: area.pressed

    signal pressedAt(real cx, real cy)
    signal movedTo(real cx, real cy)
    signal releasedAt(real cx, real cy)

    x: carrier.cx
    y: carrier.cy
    width: carrier.cw
    height: carrier.ch

    TileCarry {
        id: carrier
    }

    // the two fractions of the look: picked up, and chosen
    property real _lift: tile.lifted ? 1 : 0
    Behavior on _lift {
        NumberAnimation {
            duration: tile.style.liftMs
            easing.type: Easing.OutCubic
        }
    }
    property real _sel: tile.selected ? 1 : 0
    Behavior on _sel {
        NumberAnimation {
            duration: tile.style.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    property real _hover: tile.hovered && !tile.ghost ? 1 : 0
    Behavior on _hover {
        NumberAnimation {
            duration: 120
            easing.type: Easing.OutCubic
        }
    }

    opacity: tile.ghost ? tile.style.ghostOpacity : 1 - tile._lift * (1 - tile.style.dragOpacity)

    property real _px: 0
    property real _py: 0

    // the details show only on a tile tall enough to hold them: present or not (a presence fade), never half drawn; a carried tile shows only
    // its frame and its name, so the tile under it stays readable
    property real _detailF: !tile.chip && !tile.ghost && !tile.lifted && tile.height >= tile.style.tileDetailMinH ? 1 : 0
    Behavior on _detailF {
        NumberAnimation {
            duration: tile.style.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    readonly property real _pad: tile.chip ? 8 : tile.style.tilePadding

    DeviceScale {
        id: dev
    }

    FloatCard {
        id: card
        anchors.fill: parent
        clock: tile.clock
        style: tile.clock ? tile.style.floatStyle : null
        seed: tile.seed
        order: tile.order
        floats: !tile.ghost && !tile.chip
        tilting: tile.hovered && !tile.lifted && !tile.ghost && !tile.chip
        pointerX: tile._px
        pointerY: tile._py

        // ONE held texture: the face and the room the carve's bevel and the raised shadow are drawn into outside the tile's rect
        Item {
            id: held
            readonly property real m: Math.ceil(Math.max(tile.style.tileLiftShadow, tile.style.tileShadow, 2)) + 2
            x: -held.m
            y: -held.m
            width: tile.width + 2 * held.m
            height: tile.height + 2 * held.m
            layer.enabled: !!tile.clock && tile.clock.layers
            layer.smooth: true
            layer.mipmap: true
            layer.textureSize: Qt.size(Math.ceil(held.width * dev.value * tile.style.faceScale), Math.ceil(held.height * dev.value * tile.style.faceScale))

            Item {
                id: face
                x: held.m
                y: held.m
                width: tile.width
                height: tile.height

                    ShadowBox {
                        id: carved
                        anchors.fill: parent
                        baseRadius: tile.style.tileRadius
                        bevelWidth: tile.style.tileBevel
                        shadowWidth: tile.style.tileShadow
                        surfaceColor: tile.ground
                        backgroundColor: Mix.c(Theme.panelSunk, Theme.surface, tile._hover * 0.5)
                        bevelColor: Theme.bevel
                        shadowColor: Mix.c(Theme.border, Theme.accent, tile._sel)
                        opacity: 1 - tile._lift
                    }
                    ShadowBox {
                        anchors.fill: parent
                        raised: true
                        baseRadius: tile.style.tileRadius
                        bevelWidth: 1.5
                        shadowWidth: tile.style.tileLiftShadow
                        surfaceColor: tile.ground
                        backgroundColor: Theme.buttonPlateau
                        bevelColor: Theme.buttonBevel
                        shadowColor: Theme.buttonShadow
                        shadowToAlpha: true
                        opacity: tile._lift
                    }

                    Text {
                        id: labelText
                        x: tile._pad
                        y: tile.chip ? Math.round((tile.height - height) / 2) : tile._pad
                        width: tile.width - 2 * tile._pad - (tile.internal || tile.cast ? 20 : 0) - (tile.chip ? offText.width + 6 : 0)
                        elide: Text.ElideRight
                        text: tile.label
                        color: Theme.textPrimary
                        font.family: tile.fontFamily
                        font.pixelSize: tile.style.tileLabelSize
                        font.bold: true
                        // a ghost shows only its card: the laptop's tile in front says who mirrors it
                        opacity: tile.width > 56 && !tile.ghost ? 1 : 0
                    }
                    Text {
                        id: noteText
                        x: tile._pad
                        y: labelText.y + labelText.height + 2
                        width: tile.width - 2 * tile._pad
                        elide: Text.ElideRight
                        text: tile.note
                        color: Theme.textMuted
                        font.family: tile.fontFamily
                        font.pixelSize: tile.style.figureSize
                        opacity: tile._detailF
                        visible: !tile.chip && tile.note !== ""
                    }
                    Text {
                        id: offText
                        visible: tile.chip
                        anchors.right: parent.right
                        anchors.rightMargin: tile._pad
                        y: Math.round((tile.height - height) / 2)
                        text: "off"
                        color: Theme.textFaint
                        font.family: tile.fontFamily
                        font.pixelSize: tile.style.figureSize
                    }

                    // the figures, each in a slot of its own: the size on the left, the rate and the scale on the next line
                    Text {
                        id: sizeT
                        x: tile._pad
                        y: tile.height - tile._pad - sizeT.height - rateT.height - 1
                        text: tile.sizeText
                        color: Theme.textMuted
                        font.family: tile.fontFamily
                        font.pixelSize: tile.style.figureSize
                        opacity: tile._detailF
                        visible: !tile.chip
                    }
                    Text {
                        id: rateT
                        x: tile._pad
                        y: tile.height - tile._pad - rateT.height
                        text: tile.rateText
                        color: Theme.textMuted
                        font.family: tile.fontFamily
                        font.pixelSize: tile.style.figureSize
                        opacity: tile._detailF
                        visible: !tile.chip
                    }
                    Text {
                        id: scaleT
                        x: tile.width - tile._pad - scaleT.width
                        y: rateT.y
                        text: tile.scaleText
                        color: Theme.textMuted
                        font.family: tile.fontFamily
                        font.pixelSize: tile.style.figureSize
                        opacity: tile._detailF
                        visible: !tile.chip
                    }

                    // a cast display carries the cast mark
                    Text {
                        visible: tile.cast && !tile.chip
                        x: tile.width - tile._pad - width
                        y: tile._pad
                        text: String.fromCodePoint(0xF0118)
                        color: Theme.textMuted
                        font.family: "Symbols Nerd Font"
                        font.pixelSize: tile.style.castMarkSize
                        opacity: tile.width > 56 ? 1 : 0
                    }

                    // the panel's own tile carries a small laptop: a lid and a base
                    Item {
                        visible: tile.internal && !tile.chip
                        x: tile.width - tile._pad - 16
                        y: tile._pad + 1
                        width: 16
                        height: 12
                        opacity: tile.width > 56 ? 1 : 0
                        Rectangle {
                            x: 2
                            width: 12
                            height: 9
                            radius: 2
                            color: "transparent"
                            border.width: 1.5
                            border.color: Theme.textMuted
                        }
                        Rectangle {
                            y: 10
                            width: 16
                            height: 2
                            radius: 1
                            color: Theme.textMuted
                        }
                    }
            }
        }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: tile.ghost || tile.chip ? Qt.PointingHandCursor : (area.pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
        preventStealing: true
        onPressed: mouse => {
            const p = area.mapToItem(tile.parent, mouse.x, mouse.y);
            tile.pressedAt(p.x, p.y);
        }
        onPositionChanged: mouse => {
            tile._px = Math.max(-1, Math.min(1, mouse.x / Math.max(1, tile.width) * 2 - 1));
            tile._py = Math.max(-1, Math.min(1, mouse.y / Math.max(1, tile.height) * 2 - 1));
            if (!area.pressed)
                return;
            const p = area.mapToItem(tile.parent, mouse.x, mouse.y);
            tile.movedTo(p.x, p.y);
        }
        onReleased: mouse => {
            const p = area.mapToItem(tile.parent, mouse.x, mouse.y);
            tile.releasedAt(p.x, p.y);
        }
    }
}
