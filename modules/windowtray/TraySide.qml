pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"

// =============================================================================
// TraySide.qml -- a level of the reel slot's chain beside the tray strip (GooeyEngine: THE REEL'S CHAIN, the child chain of
// the strip): the NAME LABEL of the hovered icon or that item's MENU (level 0, the engine's first level), or one of the menu's
// SUBMENUS (level 1, the second; level 2, the third). A card over whatever popup is under it: the engine paints its ground there
// (THE GROUND). One component; what it is comes from the key the engine assigns
// (`secondaryKey`, a primitive string):
//
//   "label"                          the hovered item's name and status line
//   "menu:<item>:<level>:<slot>"     a menu: level 0 the item's own, with its
//                                    name as a head row; a deeper level one of
//                                    its submenus, rows only. `slot` says which
//                                    of that level's two models it draws
//
// The engine assigns the key ONLY while this content is faded out, so a view
// changes unseen and nothing is rebuilt: the label fades into the menu (its box
// grows from the edge it is anchored at -- the engine's secondaryAnchorAt -- one
// clock, nothing translating); another item's menu, or
// another submenu in the same level, loads into that level's hidden model and
// swaps in. Moving the label from icon to icon keeps the key: the engine SLIDES
// the box and the words swap at once.
//
// A SUBMENU IS THE NEXT LEVEL'S POPUP: a submenu opens out of
// the menu as the menu opens out of the strip. This content speaks the engine's
// contract for its own child: a submenu row clicked here opens the level below,
// beside that row, its first row level with it. The owner holds every level's
// state and models; a level's model is never let go while a level below it is
// out (the submenu's entries belong to it: let go, the submenu would empty at rest).
//
// THE SIZES ARE THE OWNER'S, computed from facts (the words' measured widths,
// the rows' kinds), never read back from this box -- the engine writes this
// content's size, and a placement taken from it would loop through the engine
// (CLAUDE.md).
//
// It performs nothing: a pick goes to the owner, which answers once (the model
// does: a fading menu still takes clicks).
// =============================================================================
Item {
    id: side

    // ---- what the engine writes ---------------------------------------------
    property var secondaryKey: null
    property rect secondaryCutout: Qt.rect(0, 0, 0, 0)
    property bool secondaryMoving: false

    property var owner: null
    property var style: null

    readonly property string keyText: typeof side.secondaryKey === "string" ? side.secondaryKey : ""
    readonly property bool isMenu: side.keyText.indexOf("menu:") === 0
    // From the key's text through a function: a handler of keyText's change
    // runs before a binding on it has followed (CLAUDE.md), and a stale level 0
    // made the tertiary level 0's `sideItem` -- cleared to null when it closed.
    function _part(k, fromEnd) {
        if (k.indexOf("menu:") !== 0)
            return 0;
        const p = k.split(":");
        return Number(p[p.length - fromEnd]);
    }
    readonly property int level: side._part(side.keyText, 2)
    readonly property int slot: side._part(side.keyText, 1)
    readonly property var menuModel: side.isMenu && side.owner ? side.owner.menuModelOf(side.level, side.slot) : null
    readonly property bool hasHead: side.isMenu && side.level === 0

    implicitWidth: !side.owner ? 0 : side.isMenu ? side.owner.menuWidth : side.owner.labelW
    implicitHeight: !side.owner ? 0 : side.isMenu ? side.owner.menuHeightOf(side.level, side.slot) : side.owner.labelH

    // ---- the engine's contract for the level below (a submenu) -----------------------
    readonly property int _below: side.level + 1
    property Component secondaryComponent: side.owner ? side.owner.sideComponent : null
    property bool secondaryOpen: side.isMenu && !!side.owner && side.owner.levelOpen[side._below] === true
    property point secondaryAnchor: Qt.point(side.width, side.owner ? side.owner.levelAnchor[side._below] || 0 : 0)
    property string secondarySide: side.owner ? side.owner.subSide : "end"
    property bool secondaryOverhang: true
    // Held with its first row level with the row that opened it (anchor point 0),
    // but OPENED about its own centre, and never from less than one row's menu:
    // a one-row submenu has its whole height from the first frame and only slides
    // out of this one (it must not grow from a point above its row).
    property real secondaryAnchorAt: 0
    property real secondaryOpenAt: 0.5
    property real secondaryOpenMin: side.style ? side.style.menuRowHeight + 2 * side.style.menuPad : 38
    property real secondaryWidthFrom: 0
    property var secondaryChildKey: side.owner ? side.owner.levelKey[side._below] || "" : ""

    readonly property bool hovered: hover.hovered
    HoverHandler {
        id: hover
    }
    onHoveredChanged: {
        if (side.owner)
            side.owner.setSideHover(side.level, side.hovered);
    }

    readonly property string fontFamily: side.style ? side.style.titleFamily : "Inter"
    readonly property real padX: side.style ? side.style.labelPadX : 12
    readonly property real padY: side.style ? side.style.labelPadY : 7

    // ---- the label -----------------------------------------------------------
    Column {
        id: label
        visible: !side.isMenu
        x: side.padX
        // the lines at the rounded middle of the label's own height (the box's eases while it opens)
        y: side.owner ? Math.round((side.owner.labelH - label.implicitHeight) / 2) : side.padY
        width: side.width - 2 * side.padX
        Text {
            width: label.width
            horizontalAlignment: side.owner ? side.owner.labelAlign : Text.AlignLeft
            text: side.owner ? side.owner.labelName : ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: Theme.textPrimary
            font.family: side.fontFamily
            font.pixelSize: side.style ? side.style.labelNameSize : 12
            font.bold: true
        }
        Text {
            visible: text !== ""
            width: label.width
            horizontalAlignment: side.owner ? side.owner.labelAlign : Text.AlignLeft
            text: side.owner ? side.owner.labelStatus : ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: Theme.textMuted
            font.family: side.fontFamily
            font.pixelSize: side.style ? side.style.labelStatusSize : 11
        }
    }

    // ---- a menu --------------------------------------------------------------
    Item {
        id: menu
        visible: side.isMenu
        readonly property real pad: side.style ? side.style.menuPad : 6
        x: menu.pad
        y: menu.pad
        width: side.width - 2 * menu.pad
        height: side.height - 2 * menu.pad

        // The head (level 0 only): the item's name, where the label stood --
        // the owner anchors the menu at the label's own edge.
        Item {
            id: head
            visible: side.hasHead
            width: menu.width
            height: side.hasHead && side.style ? side.style.menuHeadHeight : 0
            Text {
                id: headName
                x: side.padX - menu.pad
                width: Math.min(implicitWidth, head.width - x)
                anchors.verticalCenter: parent.verticalCenter
                text: side.owner ? side.owner.menuTitle : ""
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: Theme.textPrimary
                font.family: side.fontFamily
                font.pixelSize: side.style ? side.style.labelNameSize : 12
                font.bold: true
            }
            Text {
                x: headName.x + headName.width + 8
                width: Math.max(0, head.width - x - 4)
                anchors.verticalCenter: parent.verticalCenter
                visible: width > 12 && text !== ""
                text: side.owner ? side.owner.menuStatus : ""
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: Theme.textMuted
                font.family: side.fontFamily
                font.pixelSize: side.style ? side.style.labelStatusSize : 11
            }
        }
        Rectangle {
            visible: side.hasHead
            x: 4
            y: head.height + 4
            width: menu.width - 8
            height: 1
            color: Theme.border
        }
        // The rows scroll when the menu is taller than the room the owner gave
        // it (nm-applet with a street full of networks): the shell's one
        // scroll engine and its edge fades (ScrollDressing).
        Flickable {
            id: rowsFlick
            y: side.hasHead ? head.height + 9 : 0
            width: menu.width
            height: Math.max(0, menu.height - y)
            clip: true
            interactive: false
            contentWidth: width
            contentHeight: rows.implicitHeight
            MenuRows {
                id: rows
                width: menu.width
                rows: side.menuModel ? side.menuModel.rows : []
                fontFamily: side.fontFamily
                fontPixelSize: side.style ? side.style.menuFontSize : 11
                rowHeight: side.style ? side.style.menuRowHeight : 26
                keyIndex: side.owner && side.owner.keyLevel === side.level ? side.owner.keyIndex : -1
                ground: Theme.surface
                renderScale: side.owner ? side.owner.renderScale : 1
                onActivated: (row, index) => {
                    if (side.owner)
                        side.owner.menuPick(side.level, side.slot, index, row, side.rowTop(index));
                }
            }
        }
        ScrollDressing {
            anchors.fill: rowsFlick
            flick: rowsFlick
            ground: Theme.surface
            fadeHeight: 18
        }
        Text {
            visible: side.menuModel !== null && side.menuModel.empty
            y: rowsFlick.y
            x: side.padX - menu.pad
            height: side.style ? side.style.menuRowHeight : 26
            verticalAlignment: Text.AlignVCenter
            text: "Nothing to show"
            color: Theme.textFaint
            font.family: side.fontFamily
            font.pixelSize: side.style ? side.style.menuFontSize : 11
        }
    }

    // Where row `i` starts in THIS content's coordinates, as drawn now (the
    // scroll included): a submenu opens with its first row level with it.
    function rowTop(i) {
        if (!side.owner)
            return 0;
        return menu.pad + rowsFlick.y + side.owner.menuRowTop(side.level, side.slot, i) - rowsFlick.contentY;
    }

    // The keyboard's row stays in view.
    Connections {
        target: side.owner
        function onKeyIndexChanged() {
            const i = side.owner.keyIndex;
            if (!side.isMenu || side.owner.keyLevel !== side.level || i < 0 || rowsFlick.contentHeight <= rowsFlick.height)
                return;
            const top = side.owner.menuRowTop(side.level, side.slot, i);
            const h = side.style ? side.style.menuRowHeight : 26;
            if (top < rowsFlick.contentY)
                rowsFlick.contentY = top;
            else if (top + h > rowsFlick.contentY + rowsFlick.height)
                rowsFlick.contentY = top + h - rowsFlick.height;
        }
    }

    // Level 0 (the label and the item's menu) is the owner's `sideItem`. Known
    // only once the engine has assigned the key: a deeper level is created, and
    // completes, before its key says what it is.
    onKeyTextChanged: {
        if (side.owner && side.keyText !== "" && side._part(side.keyText, 2) === 0)
            side.owner.sideItem = side;
    }
    Component.onDestruction: {
        if (!side.owner)
            return;
        side.owner.setSideHover(side.level, false);
        if (side.owner.sideItem === side)
            side.owner.sideItem = null;
    }
}
