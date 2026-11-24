pragma ComponentBehavior: Bound

import QtQuick

import "../theme"

// =============================================================================
// FloatingMenu.qml -- a small carved menu that opens at a point.
//
// The material and the dismissals of LlmGrantsMenu / LlmPdfMenu, made
// general for a right-click menu: a carved panel floating in the host's
// `overlayItem` (anything painted outside an ancestor's bounds gets no input
// there -- CLAUDE.md), a full-bleed layer one z below it that shuts it on any
// outside click, Escape through a Shortcut, placement clamped inside the
// host and flipped when there is no room below.
//
// The rows themselves are MenuRows (shared with the tray's menu, which is not
// a floating popup); what stays here is what a menu DECIDES: the keys, the
// confirm, keepOpen, the dismissals. Rows are FACTS, never colours (a Repeater's
// model is compared by value; a themed colour in it rebuilds every delegate on
// every frame of a theme fade -- CLAUDE.md):
//   { id, label, danger: bool, confirm: "Delete?" } -- a row that asks first:
//        a click turns it into "<confirm>  Yes  No" in place (the LLM
//        sidebar's inline confirm); Yes emits triggered(id)
//   { id: "swatches" } -- a row of colour dots from `swatches` (keys), whose
//        colours the host resolves with `swatchColor(key)`; a dot emits
//        swatchPicked(key); `currentSwatch` gets a ring
//   { separator: true }
//   { id, label, disabled: true } -- shown faint, takes no hover or click
//   icon / check ("checkbox"|"radio") + checked / submenu / back -- see
//        MenuRows: a menu that uses none of them draws plain rows
//
// A PICK OF A RADIO ROW IS ANSWERED BY THE BALL: it rolls to the row's slot (MenuRows, SlotRail) at
// once, whatever the row's facts say yet (a host's rows may be a snapshot), `triggered` goes out at
// once, and the menu stays for the way: it starts to fade `radioHoldMs` after the click, when the
// ball is all but home. A pick of the row that is already checked closes as any other.
//
// `keepOpen`: a pick does not close the menu (a sort menu, where the user may
// pick a mode and then flip the direction); once something has been picked,
// the pointer LEAVING the panel closes it. Before a pick, leaving does not.
//
// The keyboard is opt-in: a host whose keys reach it while the menu is open
// hands each one to `handleKey(event)` (true when it used it). Up / Down move a
// highlight over the rows that can be picked -- the hover fade, so pointer and
// keys look the same -- and Enter picks it; a confirm row asks first, and
// Enter then answers Yes. Rows swapped in place by the host (a submenu) start
// highlighted on their first row once the keys are in use. A host that never
// calls it sees no change.
// Nothing announces an affordance but the pointer: a short fade to the
// accent (or the error colour on a danger row) and the hand cursor.
// =============================================================================
Item {
    id: menu

    property Item overlayItem: null
    property bool open: false
    // Where it opens, in overlayItem coordinates.
    property real atX: 0
    property real atY: 0
    property var rows: []
    property var swatches: []
    property var swatchColor: null
    property string currentSwatch: ""
    property string fontFamily: "Inter"
    property int fontPixelSize: 12
    property real menuWidth: 176
    property real padding: 6
    property real rowHeight: 26
    // How a row's icon is drawn: "ink" (the label's colour) or "colour" (see MenuRows).
    property string iconMode: "ink"
    property real radius: 10
    property int fadeMs: 160
    property int hoverMs: 120
    property bool keepOpen: false
    property bool _picked: false
    property int railMs: 280
    property int radioHoldMs: 230
    property string _radioPick: ""

    signal triggered(string id)
    signal swatchPicked(string key)

    property string _confirming: ""
    onOpenChanged: {
        if (!menu.open)
            menu._confirming = "";
        menu._picked = false;
        menu.keyIndex = -1;
        menu._keyed = false;
    }

    function openAt(x, y) {
        radioHold.stop();
        menu._radioPick = "";
        menu.atX = x;
        menu.atY = y;
        menu._confirming = "";
        menu.open = true;
        list.seatRails();
    }
    Timer {
        id: radioHold
        interval: menu.radioHoldMs
        onTriggered: menu.open = false
    }

    // ---- the keyboard (opt-in) ------------------------------------------------
    property int keyIndex: -1
    property bool _keyed: false
    // Rows swapped in place start on their first row; the same row re-read (a sort's mark moved) keeps the highlight.
    property string _keyId: ""
    onKeyIndexChanged: menu._keyId = menu.keyIndex >= 0 && menu.rows[menu.keyIndex] ? String(menu.rows[menu.keyIndex].id) : ""
    onRowsChanged: {
        if (!menu._keyed) {
            menu.keyIndex = -1;
            return;
        }
        const same = menu.rows.findIndex(r => String(r.id) === menu._keyId);
        menu.keyIndex = same >= 0 ? same : menu._step(-1, 1);
    }

    function _pickable(r) {
        return !!r && !r.separator && r.id !== "swatches" && !r.disabled;
    }
    // The next pickable row from `from` in direction `dir`, wrapping; -1 when none.
    function _step(from, dir) {
        const n = menu.rows.length;
        let i = from;
        for (let t = 0; t < n; t++) {
            i = i < 0 ? (dir > 0 ? 0 : n - 1) : (i + dir + n) % n;
            if (menu._pickable(menu.rows[i]))
                return i;
        }
        return -1;
    }
    function _activate(r) {
        if (radioHold.running)
            return;
        if (r.confirm) {
            menu._confirming = r.id;
            return;
        }
        if (menu.keepOpen) {
            menu._picked = true;
        } else if (r.check === "radio" && !r.checked) {
            menu._radioPick = String(r.id);
            radioHold.restart();
        } else {
            menu.open = false;
        }
        menu.triggered(r.id);
    }
    function handleKey(e) {
        if (!menu.open)
            return false;
        const k = e.key;
        if (k === Qt.Key_Down || k === Qt.Key_Up) {
            menu._keyed = true;
            menu._confirming = "";
            menu.keyIndex = menu._step(menu.keyIndex, k === Qt.Key_Down ? 1 : -1);
            return true;
        }
        if (k === Qt.Key_Return || k === Qt.Key_Enter) {
            const r = menu.keyIndex >= 0 ? menu.rows[menu.keyIndex] : null;
            if (!menu._pickable(r))
                return true;
            menu._keyed = true;
            if (menu._confirming === r.id) {
                menu.open = false;
                menu.triggered(r.id);
            } else {
                menu._activate(r);
            }
            return true;
        }
        if (k === Qt.Key_Escape) {
            if (menu._confirming !== "")
                menu._confirming = "";
            else
                menu.open = false;
            return true;
        }
        return false;
    }

    readonly property Item _host: menu.overlayItem ? menu.overlayItem : (menu.parent ? menu.parent : menu)

    MouseArea {
        parent: menu._host
        z: 299
        visible: menu.open
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onPressed: menu.open = false
    }

    Shortcut {
        sequence: "Escape"
        enabled: menu.open
        onActivated: menu.open = false
    }

    Item {
        id: panel
        parent: menu._host
        z: 300
        // Wide enough for the swatch row when there is one.
        width: Math.max(menu.menuWidth, menu.rows.some(r => r.id === "swatches") ? menu.swatches.length * 22 + 2 * menu.padding + 16 : 0)
        height: list.implicitHeight + 2 * menu.padding
        x: Math.round(Math.max(4, Math.min(parent.width - width - 4, menu.atX)))
        y: Math.round(menu.atY + height + 4 <= parent.height ? menu.atY : Math.max(4, menu.atY - height))
        opacity: menu.open ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: menu.fadeMs
                easing.type: Easing.OutCubic
            }
        }

        // Clicks inside the panel stay inside.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
        }
        HoverHandler {
            id: panelHover
            onHoveredChanged: {
                if (!panelHover.hovered && menu.open && menu.keepOpen && menu._picked)
                    menu.open = false;
            }
        }

        ShadowBox {
            anchors.fill: parent
            baseWidth: panel.width
            baseHeight: panel.height
            baseRadius: menu.radius
            // Floats over tiles and text: the bevel eases to alpha, not to
            // an apron of surface colour.
            surfaceColor: "transparent"
            backgroundColor: Theme.listBox
            bevelColor: Theme.bevel
            shadowColor: Theme.border
            bevelWidth: 1
            shadowWidth: 3
        }

        MenuRows {
            id: list
            objectName: "menuRows"
            x: menu.padding
            y: menu.padding
            width: panel.width - 2 * menu.padding
            rows: menu.rows
            keyIndex: menu.keyIndex
            confirming: menu._confirming
            fontFamily: menu.fontFamily
            fontPixelSize: menu.fontPixelSize
            rowHeight: menu.rowHeight
            hoverMs: menu.hoverMs
            iconMode: menu.iconMode
            pickedId: menu._radioPick
            railMs: menu.railMs
            swatches: menu.swatches
            swatchColor: menu.swatchColor
            currentSwatch: menu.currentSwatch
            onActivated: row => menu._activate(row)
            onAnswered: (id, yes) => {
                if (yes) {
                    menu.open = false;
                    menu.triggered(id);
                } else {
                    menu._confirming = "";
                }
            }
            onSwatchPicked: key => {
                menu.open = false;
                menu.swatchPicked(key);
            }
        }
    }
}
