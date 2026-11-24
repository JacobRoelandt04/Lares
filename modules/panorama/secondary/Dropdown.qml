pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../popup"
import ".."

// =============================================================================
// Dropdown.qml -- a choice with many options: a RaisedButton with the shell's Chevron, opening a FloatingMenu (the presets' and the tray's
// menu: radio rows, the ball rolls to the pick) at the button's foot, in the host's `overlay` layer (a menu painted outside a clipping
// ancestor gets no input there). The host holds the fact; a pick asks (`chosen(key)`).
//   options  [{ key, label }]   shown: the first `maxRows` (the host orders them best first), and the current one is always among them
//   open     the menu is up (Escape closes it first: `close()` from the host's handleEscape)
// =============================================================================
Item {
    id: root

    property var options: []
    property string current: ""
    property string fontFamily: "Inter"
    property Item overlay: null
    property PanoramaStyle style: PanoramaStyle {}
    readonly property bool open: menu.open

    signal chosen(string key)

    implicitHeight: root.style.segHeight
    implicitWidth: 160

    readonly property string currentLabel: {
        const o = root.options.find(x => x.key === root.current);
        return o ? o.label : "";
    }
    readonly property var _rows: {
        const cap = Math.max(1, Math.round(root.style.menuMaxRows));
        let list = root.options.slice(0, cap);
        if (!list.some(o => o.key === root.current)) {
            const cur = root.options.find(o => o.key === root.current);
            if (cur)
                list = list.slice(0, cap - 1).concat([cur]);
        }
        return list.map(o => ({ id: o.key, label: o.label, check: "radio", checked: o.key === root.current }));
    }

    function close(): void {
        menu.open = false;
    }
    function openMenu(): void {
        if (menu.open) {
            menu.open = false;
            return;
        }
        if (root.options.length < 2 || !root.overlay)
            return;
        const p = button.mapToItem(root.overlay, 0, button.height + 4);
        menu.menuWidth = Math.round(button.width);
        menu.openAt(p.x, p.y);
    }

    Text {
        visible: root.options.length < 2
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        elide: Text.ElideRight
        text: root.currentLabel
        color: Theme.textPrimary
        font.family: root.fontFamily
        font.pixelSize: 12
    }
    PanoButton {
        id: button
        visible: root.options.length > 1
        anchors.fill: parent
        ground: Theme.surface
        text: root.currentLabel
        fontFamily: root.fontFamily
        horizontalPadding: 28
        onClicked: root.openMenu()
    }
    Chevron {
        x: Math.round(button.width - width - 12)
        y: Math.round((button.height - height) / 2)
        size: 13
        color: Theme.textMuted
        rotation: menu.open ? 180 : 0
        visible: root.options.length > 1
    }

    FloatingMenu {
        id: menu
        objectName: "dropdownMenu"
        overlayItem: root.overlay
        fontFamily: root.fontFamily
        rowHeight: root.style.menuRow
        rows: root._rows
        onTriggered: id => root.chosen(id)
    }
}
