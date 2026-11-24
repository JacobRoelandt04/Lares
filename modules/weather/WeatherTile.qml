pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "../common/float"

// =============================================================================
// WeatherTile.qml -- one carved tile of the niche-metric grid.
//
// The frame every tile shares: a carved box (radius 10, listBox fill, 12 px
// padding, the popup's card carve), the title at the top in muted 11 px, a
// body the host fills, and the link behaviour -- the plateau washes toward
// panelSunk under the pointer, the hand says so, a click opens the metric's
// detail for today ({ metric, dayIndex: 0, hourIndex: null, from: "tile" });
// the open tile's plateau takes the headerBox shade (a tile is already
// carved, so the shade alone reads as "sunk further"). With
// no model the title and two bars are drawn as silhouettes where the figure
// and its line will be.
//
// WeatherTiles owns the ten of them and hands every knob down; nothing here
// is tuned on its own.
//
// A tile FLOATS (WeatherPopup, THE FLOAT): the box and everything on it are a
// FloatCard on the popup's clock, `cell` its seed and its place in the deal
// (after the hero, the strip and the list). The pointer's area is ON the card,
// so a click lands where the tile is drawn; the lift under the pointer grows
// the card past its sway, so the pointer does not slip off its edge.
// =============================================================================
Item {
    id: tile

    property var popup: null
    // Which of the ten (WeatherTiles' order): the tile's own sway and its turn in the deal.
    property int cell: 0
    property string metric: ""
    property string title: ""
    property real radius: 10
    property real padding: 12
    property int titleSize: 11
    property string fontFamily: "Inter"
    property real hoverGroundAlpha: 0.6
    property int hoverMs: 120
    property bool skeleton: false
    property bool skeletonPulse: true
    property int fadeMs: 160

    default property alias content: body.data
    // The floating card (its pose, for a probe), and whether its face is held as a texture
    readonly property alias card: card
    readonly property bool faceHeld: face.layer.enabled
    readonly property real bodyWidth: body.width
    readonly property real bodyHeight: body.height
    readonly property var key: ({ metric: tile.metric, dayIndex: 0, hourIndex: null, from: "tile" })
    readonly property bool active: {
        const k = tile.popup ? tile.popup.activeKey : null;
        return !!k && k.from === "tile" && k.metric === tile.metric;
    }
    readonly property real _bevelW: tile.popup ? tile.popup.cardBevelWidth : 1
    readonly property real _shadowW: tile.popup ? tile.popup.cardShadowWidth : 3
    readonly property real _falloff: tile.popup ? tile.popup.cardShadowFalloff : 1
    // the pointer came onto the tile and moved, or clicked it (its glyph, if it has one, flourishes: WeatherTiles)
    signal picked()
    // (the pointer's rule: one per entry, once it moves, in the window's frame)
    property var _entry: null
    property real hoverF: area.containsMouse ? 1 : 0
    Behavior on hoverF {
        NumberAnimation { duration: tile.hoverMs; easing.type: Easing.OutCubic }
    }

    FontMetrics {
        id: fmTitle
        font.family: tile.fontFamily
        font.pixelSize: tile.titleSize
    }
    readonly property real _titleH: Math.ceil(fmTitle.height)
    // How far below its box's top the title's letters start (the face's ascent
    // over the ink). The title is raised by it, so the tile's first ink sits
    // on the padding line, as every card's does (placed by its box the
    // title's ink would be 14 px from the tile's edge against
    // 12 at the side). A method call captures nothing, so the font is read
    // first: that read is the dependency.
    readonly property real _titleInkTop: {
        const f = fmTitle.font;
        return Math.max(0, Math.round((tile._titleH - fmTitle.height) / 2 + fmTitle.ascent
                                      + fmTitle.tightBoundingRect("HAbdfhklt").y));
    }
    readonly property real _titleY: tile.padding - tile._titleInkTop

    DeviceScale {
        id: dev
    }
    FloatCard {
        id: card
        anchors.fill: parent
        clock: tile.popup && tile.popup.cardFloat ? tile.popup.floatClock : null
        style: tile.popup ? tile.popup.floatStyle : null
        seed: 101 + tile.cell
        order: 3 + tile.cell
        // A turn moves the corners by half the width times the angle: the moon's double-wide tile turns half as far, so every tile's
        // corners travel about as far as a 240 px card's (the theme popup's, where the deal was tuned).
        dealTurnSign: ((3 + tile.cell) % 2 === 0 ? 1 : -1) * Math.min(1, 240 / Math.max(1, tile.width))
        lifted: area.containsMouse
        tilting: area.containsMouse
        pointerX: Math.max(-1, Math.min(1, area.mouseX / Math.max(1, card.width) * 2 - 1))
        pointerY: Math.max(-1, Math.min(1, area.mouseY / Math.max(1, card.height) * 2 - 1))

        ShadowBox {
            anchors.fill: parent
            baseRadius: tile.radius
            surfaceColor: Theme.surface
            bevelColor: tile.popup ? tile.popup.cardBevelColor : Theme.bevel
            shadowColor: Theme.border
            shadowFalloff: tile._falloff
            // The wash is the plateau's own colour, so the inset shadow ramps
            // into it rather than being painted over.
            backgroundColor: tile.active ? Theme.headerBox : Mix.c(Theme.listBox, Theme.panelSunk, tile.hoverF * tile.hoverGroundAlpha)
            bevelWidth: tile._bevelW
            shadowWidth: tile._shadowW

            // The face (title, figures, glyphs, skeleton) held as one texture while the float runs (FloatClock.layers): the float moves a
            // quad, the face is drawn again only when it changes. The carve under it is the box's own shader, drawn directly.
            Item {
                id: face
                anchors.fill: parent
                layer.enabled: !!tile.popup && tile.popup.cardFloat && tile.popup.floatClock.layers
                layer.smooth: true
                layer.mipmap: true
                layer.textureSize: Qt.size(Math.ceil(face.width * dev.value * 2), Math.ceil(face.height * dev.value * 2))

                Text {
                    id: titleText
                    x: tile.padding
                    y: tile._titleY
                    width: parent.width - 2 * tile.padding
                    height: tile._titleH
                    text: tile.title
                    elide: Text.ElideRight
                    color: Theme.textMuted
                    font.family: tile.fontFamily
                    font.pixelSize: tile.titleSize
                    verticalAlignment: Text.AlignVCenter
                    opacity: tile.skeleton ? 0 : 1
                    visible: opacity > 0
                    Behavior on opacity {
                        NumberAnimation { duration: tile.fadeMs; easing.type: Easing.OutCubic }
                    }
                }

                Item {
                    id: body
                    x: tile.padding
                    y: tile._titleY + tile._titleH + 4
                    width: parent.width - 2 * tile.padding
                    height: parent.height - y - tile.padding
                    opacity: tile.skeleton ? 0 : 1
                    visible: opacity > 0
                    Behavior on opacity {
                        NumberAnimation { duration: tile.fadeMs; easing.type: Easing.OutCubic }
                    }
                }

                Item {
                    anchors.fill: parent
                    anchors.margins: tile.padding
                    opacity: tile.skeleton ? 1 : 0
                    visible: opacity > 0
                    Behavior on opacity {
                        NumberAnimation { duration: tile.fadeMs; easing.type: Easing.OutCubic }
                    }
                    SkeletonBar {
                        x: 0
                        y: (tile._titleH - height) / 2 - tile._titleInkTop
                        width: 56
                        height: 7
                        pulse: tile.skeletonPulse
                        pulseTravel: 2
                        barColor: Theme.headerBox
                        groundColor: Theme.listBox
                    }
                    SkeletonBar {
                        x: 0
                        y: tile._titleH + 4 + 4 - tile._titleInkTop
                        width: 64
                        height: 12
                        pulse: tile.skeletonPulse
                        pulseTravel: 2
                        pulsePhaseMs: 150
                        barColor: Theme.headerBox
                        groundColor: Theme.listBox
                    }
                    SkeletonBar {
                        x: 0
                        y: tile._titleH + 4 + 4 + 12 + 6 - tile._titleInkTop
                        width: 88
                        height: 7
                        pulse: tile.skeletonPulse
                        pulseTravel: 2
                        pulsePhaseMs: 300
                        barColor: Theme.headerBox
                        groundColor: Theme.listBox
                    }
                }
            }
        }

        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: {
                const p = area.mapToItem(null, area.mouseX, area.mouseY);
                tile._entry = area.containsMouse ? [p.x, p.y] : null;
            }
            onPositionChanged: {
                if (!tile._entry)
                    return;
                const p = area.mapToItem(null, area.mouseX, area.mouseY);
                if (Math.abs(p.x - tile._entry[0]) + Math.abs(p.y - tile._entry[1]) < 1)
                    return;
                tile._entry = null;
                tile.picked();
            }
            // The detail grows out of the tile's resting middle (the root's, not the card's: a sway is not a place).
            onClicked: {
                tile.picked();
                if (tile.popup)
                    tile.popup.openDetail(tile.key, tile.mapToItem(tile.popup, tile.width / 2, tile.height / 2));
            }
        }
    }
}
