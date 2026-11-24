pragma ComponentBehavior: Bound

import QtQuick

import "../theme"
import "Mix.js" as Mix

// =============================================================================
// SortControl.qml -- the sort order as a label ("Name \u2191"), and the menu it
// opens. The notes grid's header made general: the launcher sorts with the
// same one.
//
//   modes        [{ id, label, directional: bool, caption: "…" }] -- `caption`
//                (optional) is what the LABEL says when it differs from the
//                menu row (notes: the row "Custom", the label "Custom order")
//   mode, ascending   the order in effect (the host's; this only asks)
//   extraRows    [{ id, label, checked: bool }] -- after a separator below
//                the direction (the launcher's "Columns" toggle); a pick
//                emits extraTriggered(id)
//   sortRequested(mode, ascending)   a mode row keeps the direction, the
//                direction row flips it. The mode already in effect asks for
//                nothing: a pick of it is not a sort
//   openMenu()   what a click on the label does (Tab-cycling hosts can call
//                it too); menuOpen, closeMenu() for a host's Escape, handleKey(e)
//                for a host whose keys reach it
//
// The menu is a FloatingMenu in `overlayItem` (anything floating lives in the
// popup's overlay, or it takes no clicks outside its ancestors -- CLAUDE.md):
// the modes as a radio group (a rail down the menu's leading column, the ball
// rolling to the mode picked), then -- when any mode has a direction -- the
// direction, grey under a mode that has none, then the extra rows as check
// boxes. The marks stand in MenuRows' one leading column, so a mark never moves
// a label and every label of the menu stands on one line, the direction's too.
// It stays open for a second pick (`keepOpen`) and goes when the pointer leaves
// after one. Rows are FACTS (labels and flags), never colours.
//
// Nothing announces the label as a button but the pointer: muted, a short
// fade to the accent on hover, the hand cursor. Its implicit size is the
// label's; a host that gives it a taller box keeps the text centred in it.
// =============================================================================
Item {
    id: ctl

    property Item overlayItem: null
    property var modes: []
    property string mode: ""
    property bool ascending: true
    property var extraRows: []
    property string fontFamily: "Inter"
    property int fontPixelSize: 11
    property real menuWidth: 150
    // Where the menu opens, from the label's bottom-left corner: by default it
    // hangs from the label's right edge (the label stands at its header's right).
    property real menuDx: ctl.width - ctl.menuWidth
    property real menuDy: 4

    signal sortRequested(string mode, bool ascending)
    signal extraTriggered(string id)

    readonly property var _current: ctl.modes.find(m => m.id === ctl.mode) || null
    readonly property string label: {
        if (!ctl.mode)
            return "";
        const c = ctl._current;
        const directional = c ? !!c.directional : true;
        return (c ? (c.caption || c.label) : ctl.mode) + (directional ? (ctl.ascending ? " \u2191" : " \u2193") : "");
    }

    implicitWidth: labelText.implicitWidth
    implicitHeight: labelText.implicitHeight

    function openMenu() {
        const p = ctl.mapToItem(ctl.overlayItem, 0, ctl.height);
        menu.openAt(p.x + ctl.menuDx, p.y + ctl.menuDy);
    }
    // A host's Escape (the shell's key goes to the popup, past the menu's own Shortcut).
    readonly property bool menuOpen: menu.open
    function closeMenu() {
        menu.open = false;
    }
    function handleKey(e) {
        return menu.handleKey(e);
    }

    property real _hf: area.containsMouse ? 1 : 0
    Behavior on _hf {
        NumberAnimation {
            duration: 120
            easing.type: Easing.OutCubic
        }
    }

    Text {
        id: labelText
        anchors.verticalCenter: parent.verticalCenter
        text: ctl.label
        font.family: ctl.fontFamily
        font.pixelSize: ctl.fontPixelSize
        color: Mix.c(Theme.textMuted, Theme.accent, ctl._hf)
    }
    MouseArea {
        id: area
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: ctl.openMenu()
    }

    FloatingMenu {
        id: menu
        overlayItem: ctl.overlayItem
        fontFamily: ctl.fontFamily
        menuWidth: ctl.menuWidth
        keepOpen: true
        rows: {
            const rows = ctl.modes.map(m => ({
                        id: "mode:" + m.id,
                        label: m.label,
                        check: "radio",
                        checked: m.id === ctl.mode
                    }));
            if (ctl.modes.some(m => !!m.directional)) {
                const c = ctl._current;
                rows.push({
                    separator: true
                });
                rows.push({
                    id: "dir",
                    label: ctl.ascending ? "Ascending \u2191" : "Descending \u2193",
                    disabled: !!c && !c.directional
                });
            }
            if (ctl.extraRows.length > 0) {
                rows.push({
                    separator: true
                });
                for (const x of ctl.extraRows)
                    rows.push({
                        id: "extra:" + x.id,
                        label: x.label,
                        check: "checkbox",
                        checked: !!x.checked
                    });
            }
            return rows;
        }
        onTriggered: id => {
            if (id === "dir")
                ctl.sortRequested(ctl.mode, !ctl.ascending);
            else if (id.indexOf("mode:") === 0) {
                const m = id.substring(5);
                if (m !== ctl.mode)
                    ctl.sortRequested(m, ctl.ascending);
            }
            else if (id.indexOf("extra:") === 0)
                ctl.extraTriggered(id.substring(6));
        }
    }
}
