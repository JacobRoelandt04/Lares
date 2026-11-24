pragma ComponentBehavior: Bound

import QtQuick

import "../theme"
import "Mix.js" as Mix

// =============================================================================
// MenuRows.qml -- the rows of a carved menu: FloatingMenu's column, taken out so
// a menu that is not a right-click popup (the tray's, in the engine's secondary)
// is made of the same rows.
//
// It draws rows and hears the pointer; everything a menu DECIDES stays with the
// host: which row is highlighted by the keys (`keyIndex`), which asks "Delete?
// Yes No" in place (`confirming`), what a click does (`activated`). FloatingMenu
// is the model of a host (keys, confirm, keepOpen, dismissal).
//
// Rows are FACTS, never colours (a Repeater's model is compared by value: a
// themed colour in it rebuilds every delegate on every frame of a theme fade --
// CLAUDE.md):
//   { id, label, danger: bool, confirm: "Delete?" }  a row that asks first
//   { id: "swatches" }                                a row of colour dots
//   { separator: true }
//   { id, label, disabled: true }                     faint, no hover, no click
// and, for the tray's menus:
//   icon: url                a 16 px icon in front of the label, drawn as INK (TrayInk,
//                            the label's own colour: faint on a disabled row, the
//                            accent on hover): dbusmenu icons are mostly *-symbolic
//                            glyphs that vanish on the dark theme or white pixmaps
//                            that vanish on the light one. `iconMode: "colour"` draws
//                            them as the app drew them
//   check: "checkbox", checked: bool
//                            a small carved box, an accent plateau with a tick
//                            when checked
//   check: "radio", checked: bool
//                            a run of radio rows is ONE choice, drawn as one thing
//                            down the leading column: a SlotRail, a slot at each
//                            row and a ball in the one that is checked
//                            A row has AT MOST ONE leading glyph: with both a check
//                            and an icon the check wins and the icon is dropped (a
//                            menu item that is a switch is not also a picture).
//   submenu: true            a trailing chevron: the row opens another menu
//   back: true               a leading chevron, pointing back: the way out of a
//                            submenu (its label is the submenu's name)
// `rows` is an array OF those, or a ListModel whose single role holds a record
// with a `d` property (the tray's TrayMenuModel: rows are mirrored, never
// rebuilt from an array); the delegate reads `row = modelData.d ?? modelData`.
//
// THE LEADING COLUMN takes 0 px unless SOME row in the list has a glyph: a menu
// without icons or checks has no indent. When one row
// has an icon or a check, every label is indented by the ONE column they share,
// rows with no glyph included, so the labels line up. The column is a 16 px slot
// (the icon's size) and a 6 px gap, and every glyph is CENTRED in the slot: a
// 14 px check box, a 16 px icon and a rail's groove all stand on the same centre
// x.
//
// THE RAIL OUTLIVES THE ROWS' FACTS. The delegates are made per row of a COUNT, not
// per value of the array: a Repeater on an array rebuilds every delegate when one
// `checked` changes (CLAUDE.md), and a row under the pointer would lose its hover with it.
// A new array of the same length re-reads its rows in place. The rails stand beside
// the rows, one per run, and read their stops from the rows' KINDS, so a pick moves
// a ball and rebuilds nothing. `pickedId` puts the ball on a row before the row's
// facts say so: a menu of a snapshot, which closes when the ball has landed.
//
// THE SUBMENU CHEVRON's room on the right is taken from the label of the rows
// that HAVE a chevron only: a label keeps clear of its own, and a long one
// elsewhere in the menu keeps the room (nm-applet's "Connect to Hidden Wi-Fi
// Network...").
//
// The `back` row is its own: its chevron sits in front of its own label only.
//
// SIGNALS
//   activated(row, index)   a pickable row was clicked (a confirm row too: the
//                           host answers by setting `confirming`)
//   answered(id, yes)       the in-place Yes / No
//   swatchPicked(key)
//   hoveredIndexChanged(i)  the pointer's pickable row (-1: none), for a host that
//                           shows something about it (the tray's label)
// =============================================================================
Item {
    id: list

    property var rows: []
    property int keyIndex: -1
    property string confirming: ""
    property string fontFamily: "Inter"
    property int fontPixelSize: 12
    property real rowHeight: 26
    property int hoverMs: 120
    property var swatches: []
    property var swatchColor: null
    property string currentSwatch: ""
    // The ground the carved boxes sit on (the menu's own fill).
    property color ground: Theme.listBox
    // For the icons' decode size.
    property real renderScale: 1
    // "ink" (default): an icon is its alpha in the label's colour; "colour": as drawn.
    property string iconMode: "ink"
    // The radio row picked and not yet in the rows' facts (a FloatingMenu's, for the ball's way).
    property string pickedId: ""
    property int railMs: 280

    signal activated(var row, int index)
    signal answered(string id, bool yes)
    signal swatchPicked(string key)
    signal hoveredIndexChanged(int index)

    // The pointer's row now (-1: none).
    readonly property int hovered: list._hov
    property int _hov: -1
    on_HovChanged: list.hoveredIndexChanged(list._hov)
    function _hover(i, on) {
        if (on)
            list._hov = i;
        else if (list._hov === i)
            list._hov = -1;
    }

    implicitWidth: col.implicitWidth
    implicitHeight: list.naturalHeight
    // What the rows add up to, from their KINDS (a separator is 9 px, every other
    // row `rowHeight`) -- not from the live layout, which a host that places this
    // menu by its height must not wait for (the engine's secondary writes the
    // size back). Equal to implicitHeight.
    readonly property real naturalHeight: {
        list._serial;
        const n = rep.count;
        let h = 0;
        for (let i = 0; i < n; i++) {
            const it = rep.itemAt(i);
            h += list._flag(it, "sep") ? 9 : list.rowHeight;
        }
        return h;
    }

    // ---- the optional columns: wanted by any row ------------------------------------
    property int _serial: 0
    function _flag(it, prop) {
        return !!it && !!it[prop];
    }
    function _any(prop) {
        list._serial;
        const n = rep.count;
        for (let i = 0; i < n; i++) {
            const it = rep.itemAt(i);
            if (it && it[prop])
                return true;
        }
        return false;
    }
    readonly property bool _anyLead: list._any("hasLead")
    // The leading column: the glyph slot (the icon's size) and its gap to the
    // label; and the trailing chevron's room.
    readonly property real _slot: 16
    readonly property real _leadGap: 6
    readonly property real _leadCol: list._anyLead ? list._slot + list._leadGap : 0
    readonly property real _subCol: 18

    // ---- the rows, an array or a model ----------------------------------------------
    readonly property bool _isModel: !!list.rows && list.rows.length === undefined
    function _rowAt(i: int): var {
        if (!list._isModel)
            return list.rows[i];
        const it = rep.itemAt(i);
        return it ? it.row : null;
    }

    // ---- the one-of-many runs: one rail each ----------------------------------------
    readonly property var _runs: {
        void list._serial;
        const out = [];
        let cur = null;
        let y = 0;
        const n = list._isModel ? rep.count : (list.rows ? list.rows.length : 0);
        for (let i = 0; i < n; i++) {
            const r = list._rowAt(i);
            const h = r && r.separator ? 9 : list.rowHeight;
            if (r && r.check === "radio") {
                if (!cur) {
                    cur = { stops: [], current: "" };
                    out.push(cur);
                }
                const key = String(r.id);
                cur.stops.push({ key: key, y: y + h / 2, top: y, height: h });
                if (r.checked)
                    cur.current = key;
            } else {
                cur = null;
            }
            y += h;
        }
        for (const g of out)
            if (g.stops.some(s => s.key === list.pickedId))
                g.current = list.pickedId;
        return out;
    }
    // A menu opening is not a move.
    function seatRails(): void {
        for (let i = 0; i < railRep.count; i++)
            (railRep.itemAt(i) as SlotRail).seat();
    }
    Repeater {
        id: railRep
        model: list._runs.length
        delegate: SlotRail {
            required property int index
            readonly property var run: list._runs[index] || null
            objectName: "menuRail"
            x: 8 + (list._slot - width) / 2
            width: implicitWidth
            height: list.height
            stops: run ? run.stops : []
            currentKey: run ? run.current : ""
            ground: list.ground
            travelMs: list.railMs
        }
    }

    Column {
        id: col
        objectName: "menuColumn"
        width: list.width
        Repeater {
            id: rep
            model: list._isModel ? list.rows : (list.rows ? list.rows.length : 0)
            onItemAdded: list._serial++
            onItemRemoved: list._serial++
            delegate: Item {
                id: rowItem
                required property var modelData
                required property int index
                // (a shorter array reaches a row before the count takes it away)
                readonly property var row: list._isModel ? (rowItem.modelData.d !== undefined ? rowItem.modelData.d : rowItem.modelData) : (list.rows[rowItem.index] || ({}))
                readonly property bool sep: !!rowItem.row && !!rowItem.row.separator
                readonly property bool isSwatches: !!rowItem.row && rowItem.row.id === "swatches"
                readonly property bool asking: list.confirming !== "" && !!rowItem.row && list.confirming === rowItem.row.id
                readonly property bool off: !!rowItem.row && !!rowItem.row.disabled
                readonly property bool isBack: !!rowItem.row && !!rowItem.row.back
                readonly property bool hasIcon: !!rowItem.row && !rowItem.row.separator && !!rowItem.row.icon
                readonly property bool isRadio: !!rowItem.row && rowItem.row.check === "radio"
                readonly property bool hasCheck: rowItem.isRadio || (!!rowItem.row && rowItem.row.check === "checkbox")
                // The one leading glyph a row has: the check wins over the icon.
                readonly property bool hasLead: rowItem.hasCheck || rowItem.hasIcon
                readonly property bool showIcon: rowItem.hasIcon && !rowItem.hasCheck
                readonly property bool hasSub: !!rowItem.row && !!rowItem.row.submenu
                readonly property bool plain: !rowItem.sep && !rowItem.isSwatches && !rowItem.asking
                width: col.width
                height: rowItem.sep ? 9 : list.rowHeight
                property real hoverF: (rowArea.containsMouse || list.keyIndex === rowItem.index) && !rowItem.isSwatches && !rowItem.asking ? 1 : 0
                Behavior on hoverF {
                    NumberAnimation {
                        duration: list.hoverMs
                        easing.type: Easing.OutCubic
                    }
                }
                readonly property color textColor: rowItem.off ? Theme.textFaint
                    : Mix.c(rowItem.row.danger ? Theme.error : Theme.textPrimary,
                            rowItem.row.danger ? Theme.errorStrong : Theme.accent, rowItem.hoverF)

                Rectangle {
                    visible: rowItem.sep
                    x: 4
                    width: parent.width - 8
                    y: 4
                    height: 1
                    color: Theme.border
                }

                // The row's leading glyph, in front of the label: the way back,
                // or the check or the icon -- the last two centred in the one slot.
                Chevron {
                    id: backMark
                    visible: rowItem.plain && rowItem.isBack
                    x: 8
                    y: Math.round((parent.height - height) / 2)
                    size: 11
                    thickness: 1.6
                    rotation: 90
                    color: rowItem.off ? Theme.textFaint : Mix.c(Theme.textMuted, Theme.accent, rowItem.hoverF)
                }
                MenuCheck {
                    objectName: "menuLeadCheck"
                    visible: rowItem.plain && rowItem.hasCheck && !rowItem.isRadio
                    x: 8 + (list._slot - width) / 2
                    y: Math.round((parent.height - height) / 2)
                    checked: !!rowItem.row.checked
                    dim: rowItem.off
                }
                // Only the rows that have one build the icon.
                Loader {
                    active: rowItem.plain && rowItem.showIcon
                    x: 8 + (list._slot - width) / 2
                    y: Math.round((parent.height - 16) / 2)
                    width: 16
                    height: 16
                    sourceComponent: TrayInk {
                        objectName: "menuLeadIcon"
                        source: rowItem.row.icon
                        size: 16
                        mode: list.iconMode
                        ink: rowItem.textColor
                        renderScale: list.renderScale
                        opacity: rowItem.off && list.iconMode === "colour" ? 0.5 : 1
                    }
                }

                // A plain row, or its confirmation in place.
                Text {
                    visible: rowItem.plain
                    x: 8 + list._leadCol + (rowItem.isBack ? backMark.width + 6 : 0)
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 16 - list._leadCol - (rowItem.hasSub ? list._subCol : 0) - (rowItem.isBack ? backMark.width + 6 : 0)
                    elide: Text.ElideRight
                    text: rowItem.row.label || ""
                    font.family: list.fontFamily
                    font.pixelSize: list.fontPixelSize
                    color: rowItem.textColor
                }
                Chevron {
                    visible: rowItem.plain && rowItem.hasSub
                    x: parent.width - 8 - width
                    y: Math.round((parent.height - height) / 2)
                    size: 11
                    thickness: 1.6
                    rotation: -90
                    color: rowItem.off ? Theme.textFaint : Mix.c(Theme.textMuted, Theme.accent, rowItem.hoverF)
                }
                MouseArea {
                    id: rowArea
                    anchors.fill: parent
                    enabled: rowItem.plain && !rowItem.off
                    hoverEnabled: true
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onContainsMouseChanged: list._hover(rowItem.index, rowArea.containsMouse)
                    onClicked: list.activated(rowItem.row, rowItem.index)
                }

                // The question at the row's left edge where a plain row's label stands, the answers FLUSH RIGHT
                // at the same inset (not right after the question). Placed by x: a pair of opposing anchors would replace the Row's width.
                Text {
                    visible: rowItem.asking
                    x: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: rowItem.row.confirm || ""
                    font.family: list.fontFamily
                    font.pixelSize: list.fontPixelSize
                    color: Theme.textPrimary
                }
                Row {
                    visible: rowItem.asking
                    x: parent.width - 8 - width
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 14
                    Repeater {
                        model: ["Yes", "No"]
                        delegate: Text {
                            id: answer
                            required property string modelData
                            property real hf: answerArea.containsMouse ? 1 : 0
                            Behavior on hf {
                                NumberAnimation {
                                    duration: list.hoverMs
                                    easing.type: Easing.OutCubic
                                }
                            }
                            text: answer.modelData
                            font.family: list.fontFamily
                            font.pixelSize: list.fontPixelSize
                            font.bold: answer.modelData === "Yes"
                            color: answer.modelData === "Yes" ? Mix.c(Theme.error, Theme.errorStrong, answer.hf) : Mix.c(Theme.textMuted, Theme.accent, answer.hf)
                            MouseArea {
                                id: answerArea
                                anchors.fill: parent
                                anchors.margins: -4
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: list.answered(rowItem.row.id, answer.modelData === "Yes")
                            }
                        }
                    }
                }

                Row {
                    visible: rowItem.isSwatches
                    x: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Repeater {
                        model: rowItem.isSwatches ? list.swatches : []
                        delegate: Item {
                            id: dot
                            required property string modelData
                            width: 16
                            height: 16
                            Rectangle {
                                anchors.fill: parent
                                radius: 8
                                color: list.swatchColor ? list.swatchColor(dot.modelData) : Theme.surface
                                border.width: dot.modelData === "" ? 1 : 0
                                border.color: Theme.border
                            }
                            Rectangle {
                                visible: list.currentSwatch === dot.modelData || dotArea.containsMouse
                                anchors.centerIn: parent
                                width: 22
                                height: 22
                                radius: 11
                                color: "transparent"
                                border.width: 1.5
                                border.color: list.currentSwatch === dot.modelData ? Theme.accent : Theme.textFaint
                            }
                            MouseArea {
                                id: dotArea
                                anchors.fill: parent
                                anchors.margins: -3
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: list.swatchPicked(dot.modelData)
                            }
                        }
                    }
                }
            }
        }
    }

    // A check box: carved into the menu, an accent plateau with a tick when it is
    // on. The fraction eases; the colours do not.
    component MenuCheck: Item {
        id: mark
        property bool checked: false
        property bool dim: false
        property real onF: mark.checked ? 1 : 0
        Behavior on onF {
            NumberAnimation {
                duration: list.hoverMs
                easing.type: Easing.OutCubic
            }
        }
        width: 14
        height: 14
        opacity: mark.dim ? 0.5 : 1

        ShadowBox {
            anchors.fill: parent
            baseWidth: 14
            baseHeight: 14
            baseRadius: 4
            surfaceColor: list.ground
            backgroundColor: Theme.panelSunk
            bevelColor: Theme.bevel
            shadowColor: Theme.border
            bevelWidth: 1
            shadowWidth: 2
        }
        // The plateau: the tick's square.
        Rectangle {
            visible: mark.onF > 0.01
            x: 2
            y: 2
            width: 10
            height: width
            radius: 2.5
            color: Theme.accent
            opacity: mark.onF
        }
        Item {
            visible: mark.onF > 0.01
            x: 2
            y: 2
            width: 10
            height: 10
            opacity: mark.onF
            Rectangle {
                x: 1.9
                y: 4.8
                width: 3.6
                height: 1.6
                radius: 0.8
                rotation: 45
                color: Theme.textOnAccent
            }
            Rectangle {
                x: 2.6
                y: 4.2
                width: 6.2
                height: 1.6
                radius: 0.8
                rotation: -52
                color: Theme.textOnAccent
            }
        }
    }
}
