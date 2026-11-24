pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/float"

// =============================================================================
// PresetsPopup.qml -- the desktop presets' drop-in (docs/presets.md): a grid of cards, one per saved desktop (PresetCard: its name, its
// face, Load and Add), and last the card that saves the desktop as it is now (PresetNewCard). Right click on a card: Save over, Rename,
// Delete (the shell's FloatingMenu; Delete leaves the card a few seconds with an Undo).
//
//   service        PresetsService: the rows (`presets`, `current`) and every verb. Injected; null: an empty popup
//   appLookup      AppLookup (a window class -> its desktop entry, for the icons); null: the class names the icon
//   motionRunning  the owner's word that this popup is on screen; `parked` is the engine's. Either false: the clock stops
//   closeRequested()  a load was asked: the windows are about to move under the popup, the owner closes it
//
//   boxWidth       the live box the host eases to this content's size, when the host lays the content out at its own size instead (PanoramaTabs);
//                  by default this item's own width
//
// A DROP-IN (CLAUDE.md, Drop-in rule): it sizes itself (implicitWidth / implicitHeight: `columns` cards across -- as many as there are cards, so
// the save card alone is one column wide -- up to `maxRows` rows, then it scrolls), assumes nothing of its host and builds no service. It is the Presets tab of the displays' popup (modules/panorama/popup/PanoramaTabs.qml)
// as it is; a load asked from a card ends in `closeRequested()`, which is how the host knows one began.
//
// ONE CLOCK: a FloatClock steps every card (the theme popup's float); it stops when the popup is parked or hidden, and holds through a theme
// crossfade (nothing here moves on its own under the old picture).
//
// THE KEYS (HoverArm): the keyboard is the popup's once the pointer has MOVED onto it. Arrows move the hand across the cards, Enter on a preset
// is its Load (the confirm included), on the last card it goes to the name field. Escape (the shell's bind, `handleEscape`): closes the menu,
// then a rename, then a confirm, and only then the popup.
// =============================================================================
Item {
    id: root

    property var service: null
    property var appLookup: null
    property PresetsStyle style: PresetsStyle {}
    property string fontFamily: "Inter"
    property real renderScale: 1
    property bool motionRunning: true
    property bool parked: false
    property real boxWidth: root.width

    signal closeRequested()

    readonly property var rows: root.service ? root.service.presets : []
    readonly property int cells: root.rows.length + 1
    readonly property int columns: root.style.columnsFor(root.cells)
    readonly property int gridRows: Math.ceil(root.cells / root.columns)
    readonly property int shownRows: Math.max(1, Math.min(root.gridRows, root.style.maxRows))
    readonly property bool _scrolls: root.gridRows > root.style.maxRows
    readonly property real cardHeight: Math.ceil(2 * root.style.cardPadding + root.style.titleSize + 6 + root.style.titleGap + root.style.faceHeight + root.style.footGap + root.style.buttonHeight)

    implicitWidth: root.style.widthFor(root.cells)
    implicitHeight: Math.ceil(2 * root.style.padding + root.shownRows * root.cardHeight + (root.shownRows - 1) * root.style.cardGap)

    // THE COLUMNS CHANGE while the popup is on show (the first preset saved, the last one gone): `implicitWidth` steps and the host eases its
    // box there. Until the box arrives the first column stands at its left edge and the last at its right one (one column: the right), so the
    // saved card and the save card part from one place as the popup widens, meet in it as it narrows, and the box never cuts a card. The box's
    // clock is the only one. `_from`: the width the popup is leaving, 0 with no change under way -- an open or a tab switch reveals the grid at rest.
    property real _from: 0
    property real _asked: 0
    readonly property bool _onShow: root.visible && !root.parked
    readonly property real _box: root._from <= 0 ? root.implicitWidth
        : Math.max(Math.min(root._from, root.implicitWidth), Math.min(Math.max(root._from, root.implicitWidth), root.boxWidth))
    readonly property bool _arrived: Math.abs(root.boxWidth - root.implicitWidth) < 0.5
    onImplicitWidthChanged: {
        const was = root._asked;
        root._asked = root.implicitWidth;
        root._from = was > 0 && root._onShow && Math.abs(root.boxWidth - root.implicitWidth) >= 0.5 ? was : 0;
    }
    on_ArrivedChanged: if (root._arrived) root._from = 0
    on_OnShowChanged: if (!root._onShow) root._from = 0
    function cellX(i: int): real {
        const span = root._box - 2 * root.style.padding - root.style.cardWidth;
        const along = root.columns > 1 ? (i % root.columns) / (root.columns - 1) : 1;
        return (root.width - root._box) / 2 + root.style.padding + span * along;
    }
    function cellY(i: int): real {
        return root.style.padding + Math.floor(i / root.columns) * (root.cardHeight + root.style.cardGap);
    }

    // ---- the engine's contract --------------------------------------------------------------------------------------------------------------------
    HoverArm {
        id: arm
        target: root
        active: root.visible && !root.parked
    }
    readonly property bool keysArmed: arm.armed
    readonly property bool typing: renameField.hasFocus || (!!newCard.item && (newCard.item as PresetNewCard).field.hasFocus)
    readonly property string keyboardFocusRequest: arm.armed || root.typing ? "exclusive" : "none"
    onKeysArmedChanged: if (root.keysArmed && !root.typing) root.forceActiveFocus()

    function handleEscape(): bool {
        if (menu.open) {
            menu.open = false;
            return true;
        }
        if (root._renameFor !== "") {
            root._endRename(false);
            return true;
        }
        for (let i = 0; i < cardRepeater.count; i++) {
            const c = cardRepeater.itemAt(i) as PresetCard;
            if (c && c.confirming) {
                c.cancelConfirm();
                return true;
            }
        }
        return false;
    }

    // ---- the clock ---------------------------------------------------------------------------------------------------------------------------------
    readonly property bool clockOn: root.motionRunning && !root.parked && root.visible
    readonly property alias floatClock: cardClock
    FloatClock {
        id: cardClock
        running: root.clockOn
        // every tick is a frame of the whole window: it ticked every frame while open; the slow sway needs 20 a second (as the displays' tiles)
        restHz: 20
        style: root.style
    }

    // ---- the hand ------------------------------------------------------------------------------------------------------------------------------------
    // the cell the pointer or the keys are on (-1: none); the last cell is the new card
    property int hand: -1
    function _move(dx: int, dy: int): void {
        if (root.hand < 0) {
            root.hand = 0;
        } else {
            let i = root.hand + dx + dy * root.columns;
            root.hand = Math.max(0, Math.min(root.cells - 1, i));
        }
        root._reveal(root.hand);
    }
    function _reveal(i: int): void {
        const y = root.cellY(i);
        if (y - root.style.padding < list.contentY)
            list.contentY = Math.max(0, y - root.style.padding);
        else if (y + root.cardHeight + root.style.padding > list.contentY + list.height)
            list.contentY = y + root.cardHeight + root.style.padding - list.height;
    }
    focus: true
    Keys.onPressed: e => {
        if (e.key === Qt.Key_Left)
            root._move(-1, 0);
        else if (e.key === Qt.Key_Right)
            root._move(1, 0);
        else if (e.key === Qt.Key_Up)
            root._move(0, -1);
        else if (e.key === Qt.Key_Down)
            root._move(0, 1);
        else if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && root.hand >= 0) {
            if (root.hand < root.rows.length) {
                const c = cardRepeater.itemAt(root.hand) as PresetCard;
                if (c)
                    c.askLoad();
            } else if (newCard.item) {
                (newCard.item as PresetNewCard).field.forceFocus();
            }
        } else
            return;
        e.accepted = true;
    }

    // ---- the loads ------------------------------------------------------------------------------------------------------------------------------------
    function load(name: string, mode: string): void {
        if (!root.service)
            return;
        root.service.load(name, mode);
        root.closeRequested();
    }

    // ---- the grid --------------------------------------------------------------------------------------------------------------------------------------
    Flickable {
        id: list
        anchors.fill: parent
        interactive: false
        clip: root._scrolls
        contentWidth: width
        contentHeight: 2 * root.style.padding + root.gridRows * root.cardHeight + (root.gridRows - 1) * root.style.cardGap

        Repeater {
            id: cardRepeater
            model: root.rows
            PresetCard {
                id: pc
                required property var modelData
                required property int index
                x: root.cellX(pc.index)
                y: root.cellY(pc.index)
                style: root.style
                row: pc.modelData
                clock: cardClock
                seed: 11 + pc.index * 7
                order: pc.index
                current: root.hand === pc.index
                appLookup: root.appLookup
                fontFamily: root.fontFamily
                service: root.service
                onLoadAsked: mode => root.load(pc.row.name, mode)
                onMenuAsked: (mx, my) => root._openMenu(pc.row.name, pc, mx, my)
                onHoverEntered: root.hand = pc.index
                onHoverLeft: {
                    if (root.hand === pc.index)
                        root.hand = -1;
                }
            }
        }
        Loader {
            id: newCard
            x: root.cellX(root.rows.length)
            y: root.cellY(root.rows.length)
            sourceComponent: Component {
                PresetNewCard {
                    style: root.style
                    clock: cardClock
                    order: root.rows.length
                    current: root.hand === root.rows.length
                    appLookup: root.appLookup
                    fontFamily: root.fontFamily
                    service: root.service
                    onHoverEntered: root.hand = root.rows.length
                    onHoverLeft: {
                        if (root.hand === root.rows.length)
                            root.hand = -1;
                    }
                }
            }
        }
    }
    ScrollDressing {
        anchors.fill: parent
        flick: list
        visible: root._scrolls
        wheelEnabled: root._scrolls
        ground: Theme.surface
    }

    // ---- floating things: the menu and the rename field --------------------------------------------------------------------------------------------
    Item {
        id: overlay
        objectName: "presetsOverlay"
        anchors.fill: parent
        z: 1000
    }
    property string _menuFor: ""
    function _openMenu(name: string, card: Item, mx: real, my: real): void {
        root._menuFor = name;
        menu.rows = [
            { id: "over", label: "Save this desktop here", confirm: "Replace?" },
            { id: "rename", label: "Rename" },
            { separator: true },
            { id: "delete", label: "Delete", danger: true }
        ];
        const p = card.mapToItem(overlay, mx, my);
        menu.openAt(p.x, p.y);
    }
    FloatingMenu {
        id: menu
        objectName: "presetsMenu"
        overlayItem: overlay
        fontFamily: root.fontFamily
        menuWidth: 190
        onTriggered: id => {
            const name = root._menuFor;
            if (!root.service || name === "")
                return;
            if (id === "over")
                root.service.save(name, true, (ok, reason) => {
                    if (!ok)
                        console.warn("PresetsPopup: save over " + name + ": " + reason);
                });
            else if (id === "rename")
                root._startRename(name);
            else if (id === "delete")
                root.service.remove(name);
        }
    }

    property string _renameFor: ""
    function _startRename(name: string): void {
        const i = root.rows.findIndex(r => r.name === name);
        const c = i >= 0 ? cardRepeater.itemAt(i) as PresetCard : null;
        if (!c)
            return;
        const r = c.titleRect;
        const p = c.mapToItem(overlay, r.x, r.y);
        renameField.x = Math.round(p.x - 4);
        renameField.y = Math.round(p.y - 2);
        renameField.width = Math.round(r.width * 0.66);
        root._renameFor = name;
        renameField.text = name;
        renameField.forceFocus();
    }
    function _endRename(commit: bool): void {
        const old = root._renameFor;
        if (old === "")
            return;
        if (!commit || !root.service) {
            root._renameFor = "";
            root.forceActiveFocus();
            return;
        }
        root.service.rename(old, renameField.text.trim(), (ok, reason) => {
            if (ok) {
                root._renameFor = "";
                root.forceActiveFocus();
            } else {
                renameShake.play();
                renameField.forceFocus();
            }
        });
    }
    Shake {
        id: renameShake
        objectName: "presetRenameShake"
        amplitude: root.style.shakePx
    }
    CarvedSearchField {
        id: renameField
        objectName: "presetRename"
        parent: overlay
        visible: root._renameFor !== ""
        height: root.style.titleSize + 10
        placeholder: "Name"
        glyph: ""
        escapeClears: false
        fontFamily: root.fontFamily
        surfaceColor: Theme.surface
        transform: Translate {
            x: renameShake.offset
        }
        onEscaped: Qt.callLater(() => root._endRename(false))
        onHasFocusChanged: {
            if (!renameField.hasFocus && root._renameFor !== "" && !renameShake.running)
                root._endRename(false);
        }
        Keys.onReturnPressed: root._endRename(true)
        Keys.onEnterPressed: root._endRename(true)
    }
}
