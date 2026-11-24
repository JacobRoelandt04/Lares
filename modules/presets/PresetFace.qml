pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/icons"
import "PresetFaceLayout.js" as FaceLayout

// =============================================================================
// PresetFace.qml -- a preset drawn small: one mini screen per workspace that has windows, side by side and all at one scale, each tiled as
// Hyprland tiled it (the saved `at` / `size`, scaled onto the screen, every edge on a whole pixel), an app icon in each tile. A tabbed group
// is ONE tile with a tab strip along its top, a segment per tab and the shown one in the accent (a LOCKED group's in the locked tab's
// colour, `Theme.hyprBorderLocked`, as Hyprland's own tab bar shows the lock). A floating window stands over the tiles,
// a fullscreen one fills its screen. The workspace's name sits under its screen; the special workspace is a small badge at the strip's end.
// Too many workspaces for the width: the screens shrink to `screenMinWidth`, then the strip ends in "+N".
//
//   face        the tool's FACE (docs/contracts/session.md, "Presets"): { monitors: [{name, w, h}], workspaces: [{key, name, special,
//               monitor, windows: [{class, title, at, size, floating, fullscreen, pinned, group}]}] }
//   style       PresetsStyle
//   appLookup   AppLookup (class -> desktop entry, for the icon); null: the class is the icon's only name
//   ground      what the face stands on (the card's fill): the screens' carve runs from it (CLAUDE.md, A CARVED ITEM'S surfaceColor)
//
// Facts only in the Repeaters' models (the plan is numbers and names, never a colour: a themed colour in a model rebuilds every delegate
// on every frame of a theme fade). The plan is PresetFaceLayout.js, pure: a probe reads the same numbers.
// =============================================================================
Item {
    id: root

    property var face: null
    property PresetsStyle style: PresetsStyle {}
    property var appLookup: null
    property color ground: Theme.surface

    implicitWidth: 256
    implicitHeight: root.style.faceHeight

    readonly property var plan: FaceLayout.plan(root.face, Math.round(root.width), Math.round(root.height), root.style)

    function _icon(cls: string): var {
        const info = root.appLookup && cls !== "" ? root.appLookup.app(cls) : null;
        return info || ({ desktopId: "", icon: "" });
    }

    Repeater {
        model: root.plan.screens
        Item {
            id: scr
            required property var modelData
            x: scr.modelData.x
            y: scr.modelData.y
            width: scr.modelData.w
            height: scr.modelData.h + root.style.labelGap + root.style.labelSize + 2

            ShadowBox {
                id: well
                width: scr.modelData.w
                height: scr.modelData.h
                baseRadius: root.style.screenRadius
                surfaceColor: root.ground
                backgroundColor: Theme.listBox
                bevelColor: Theme.bevel
                shadowColor: Theme.border
                bevelWidth: 1
                shadowWidth: 2
            }
            Repeater {
                model: scr.modelData.tiles
                Item {
                    id: tile
                    required property var modelData
                    readonly property var t: tile.modelData
                    x: tile.t.x
                    y: tile.t.y
                    width: tile.t.w
                    height: tile.t.h
                    z: tile.t.z

                    Rectangle {
                        anchors.fill: parent
                        radius: root.style.tileRadius
                        color: Theme.surface
                        border.width: 1
                        border.color: tile.t.floating ? Theme.shadowDeep : Theme.border
                    }
                    // a group: a segment per tab along the top, the one on show in the accent (locked: the locked tab's colour)
                    Row {
                        visible: tile.t.tabs > 1 && tile.t.w >= tile.t.tabs * 3 + 2
                        x: 2
                        y: 2
                        spacing: 1
                        Repeater {
                            model: tile.t.tabs
                            Rectangle {
                                required property int index
                                width: Math.max(1, Math.floor((tile.t.w - 4 - (tile.t.tabs - 1)) / tile.t.tabs))
                                height: root.style.tabStrip
                                radius: 1
                                color: index !== tile.t.activeTab ? Theme.border : (tile.t.locked ? Theme.hyprBorderLocked : Theme.accent)
                            }
                        }
                    }
                    AppIcon {
                        readonly property var info: root._icon(tile.t.cls)
                        visible: tile.t.icon > 0
                        size: Math.max(1, tile.t.icon)
                        x: Math.round((tile.t.w - tile.t.icon) / 2)
                        y: Math.round((tile.t.h + tile.t.top - tile.t.icon) / 2)
                        cls: tile.t.cls
                        appId: info.desktopId || ""
                        icon: info.icon || ""
                        kind: "app"
                        archFallback: true
                    }
                }
            }
            Text {
                y: scr.modelData.h + root.style.labelGap
                width: scr.modelData.w
                horizontalAlignment: Text.AlignHCenter
                text: scr.modelData.label
                color: Theme.textFaint
                font.family: "Inter"
                font.pixelSize: root.style.labelSize
                elide: Text.ElideRight
            }
        }
    }

    // more workspaces than the width holds
    Item {
        visible: root.plan.more > 0
        x: root.plan.moreX
        y: root.plan.moreY
        width: root.plan.moreW
        height: root.plan.moreH
        Text {
            anchors.fill: parent
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: "+" + root.plan.more
            color: Theme.textMuted
            font.family: "Inter"
            font.pixelSize: 12
            font.bold: true
        }
    }

    // the special workspace: a small carved badge with its windows' icons, and the four-pointed star under it
    Item {
        id: badge
        visible: root.plan.special.length > 0
        x: root.plan.badgeX
        y: root.plan.badgeY
        width: root.plan.badgeW
        height: root.plan.badgeH + root.style.labelGap + root.style.labelSize + 2
        ShadowBox {
            width: root.plan.badgeW
            height: root.plan.badgeH
            baseRadius: root.style.screenRadius
            surfaceColor: root.ground
            backgroundColor: Theme.listBox
            bevelColor: Theme.bevel
            shadowColor: Theme.border
            bevelWidth: 1
            shadowWidth: 2
        }
        Column {
            x: Math.round((root.plan.badgeW - root.plan.badgeIcon) / 2)
            y: Math.round((root.plan.badgeH - (root.plan.special.length * (root.plan.badgeIcon + 3) - 3)) / 2)
            spacing: 3
            Repeater {
                model: root.plan.special
                AppIcon {
                    id: sp
                    required property var modelData
                    readonly property var info: root._icon(sp.modelData)
                    size: Math.max(1, root.plan.badgeIcon)
                    cls: sp.modelData
                    appId: sp.info.desktopId || ""
                    icon: sp.info.icon || ""
                    kind: "app"
                    archFallback: true
                }
            }
        }
        Text {
            y: root.plan.badgeH + root.style.labelGap
            width: root.plan.badgeW
            horizontalAlignment: Text.AlignHCenter
            text: String.fromCodePoint(0xF0AE2)
            color: Theme.textFaint
            font.family: "Symbols Nerd Font"
            font.pixelSize: root.style.labelSize
        }
    }
}
