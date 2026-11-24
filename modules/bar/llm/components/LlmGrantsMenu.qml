pragma ComponentBehavior: Bound

import QtQuick
import "../../../common/theme"
import "../../../common/components"
import "../../../common/components/Mix.js" as Mix

// =============================================================================
// LlmGrantsMenu.qml
//
// The remembered allowances, behind the wrench: a
// right-click on the composer's tools button opens this small carved panel
// ABOVE it, listing every rule the user has written with "Always allow …",
// grouped under the tool that will use it, each with the times it has been
// used and a × that forgets it, then "Revoke all".
//
// IT MUST SAY WHAT IT IS WHEN IT IS EMPTY. A panel
// whose empty state is one faint line, with no title and nothing that says
// what would ever put a line in it, reads as a stub. So the empty state
// TEACHES: what an allowance is, which button writes one, and how long it
// lasts.
//
// GROUPED BY TOOL, AND THE KEY IS THE WHOLE POINT. A rule covers exactly the
// key it names -- `git status` and not `git`, one host and not a domain (a
// subdomain is a separate host, and one host rule covers every page on it,
// http and https alike). So the tool's name is a section header printed once
// rather than a column repeated on every row, which also leaves the label the ~90 px
// such a column would eat -- at the default width a real
// fetch_url rule would elide to "fetches from quicksh…" with it.
//
// THE MATERIAL IS LlmPdfMenu's: the same carved panel (fill `fieldColor`
// over the list box), the same padding and radius, the same divider, the
// same dismissals -- an outside click on a full-bleed layer one z below the
// panel, Escape through a window Shortcut (the panel takes no focus; the
// prompt or the confirmation keeps it), and the composer being put away. It
// floats in the host's `overlayItem` for the reason every floating thing
// here does: an item painted outside an ancestor's bounds receives no input
// there. With no overlay it falls back to its parent -- fine for a harness,
// wrong in a popup.
//
// IT HAS A CEILING. `run_command` writes one rule per pipeline segment,
// so a week of use is double figures and an unbounded panel would grow with them,
// off the top of the popup. The rules scroll inside a capped body
// on the shell's one notch and with its edge fade (ScrollDressing), while the
// title, "Revoke all" and the registry's rejection line stay put -- a list
// that scrolls must not take its own controls with it.
//
// FIGURES IN FIXED SLOTS: the rule count beside the title and the use count
// on each row sit in slots measured from the widest value they can hold, so
// nothing moves when a rule is forgotten.
//
// The menu emits; it never edits. `revoked(tool, key)` and `revokeAll()` go
// up through the composer to the host, which calls `tools.forget` /
// `tools.forgetAll`; the rows follow `grants` when the service's list
// changes, so a row is gone when the grant is, not when the × was clicked.
//
// Every colour is a property with a `Theme.<token>` default; nothing here
// animates a colour -- the ×'s hover eases a fraction and Mix.js blends.
// Presence fades 160 ms; everything else is instant.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // PUBLIC API
    // ======================================================================
    property bool   open: false
    // The wrench: the panel opens above it, left-aligned with it.
    property Item   anchorItem: null
    property Item   overlayItem: null
    // [{ tool, key, label, at, uses }]
    property var    grants: []
    // [{ file, name, action, reason }] -- the registry's load rejections.
    property var    errors: []

    signal revoked(string tool, string key)
    signal revokeAll()

    property string fontFamily: "Inter"
    property real   menuWidth: 300
    // The ceiling on the whole panel; the rules scroll under it. Clamped
    // again by the room actually above (or below) the wrench.
    property real   maxHeight: 320
    property real   padding: 10
    property real   radius: 10
    property real   gap: 6            // between the panel and the wrench
    property real   rowHeight: 22
    property real   indent: 10        // a rule under its tool's name
    property real   dividerGap: 6
    property int    fontPixelSize: 11
    property int    figurePixelSize: 10
    property int    fadeMs: 160
    property int    hoverMs: 120
    // The shell's one scroll notch and its edge band.
    property real   scrollSpeed: 1.0
    property real   fadeHeight: 24

    // ---- Palette ----
    property color surfaceColor: Theme.listBox      // what the panel floats over
    property color fieldColor: Theme.panelSunk      // the panel's fill
    property color bevelColor: Theme.bevel
    property color shadowColor: Theme.border
    property color primaryText: Theme.textPrimary
    property color mutedText: Theme.textMuted
    property color faintText: Theme.textFaint
    property color accent: Theme.accent
    property color tipSurfaceColor: Theme.surface

    // ======================================================================
    // STATE
    // ======================================================================
    readonly property var _rows: root.grants ? root.grants : []
    // Grouped by tool, tools alphabetical, newest rule first inside a tool.
    readonly property var _groups: {
        const by = {}, order = [];
        const rs = root._rows;
        for (let i = 0; i < rs.length; i++) {
            const g = rs[i];
            if (!g)
                continue;
            const t = String(g.tool || "");
            if (by[t] === undefined) {
                by[t] = [];
                order.push(t);
            }
            by[t].push(g);
        }
        order.sort();
        const out = [];
        for (let k = 0; k < order.length; k++) {
            const list = by[order[k]].slice();
            list.sort((a, b) => (Number(b.at) || 0) - (Number(a.at) || 0));
            out.push({ tool: order[k], rules: list });
        }
        return out;
    }
    readonly property int _errorCount: root.errors ? root.errors.length : 0
    readonly property string _errorLine: root._errorCount === 0 ? ""
        : root._errorCount + (root._errorCount === 1 ? " tool entry rejected" : " tool entries rejected")
          + " — see the Tools tab"

    FontMetrics {
        id: figFm
        font.family: root.fontFamily
        font.pixelSize: root.figurePixelSize
    }
    readonly property real _usesSlotW: Math.ceil(figFm.advanceWidth("000 uses"))
    readonly property real _countSlotW: Math.ceil(figFm.advanceWidth("00 rules"))
    readonly property real _xSlotW: 16

    function _uses(n) {
        const u = Math.max(0, Number(n) || 0);
        return u === 1 ? "1 use" : u + " uses";
    }
    function _when(at) {
        const t = Number(at) || 0;
        return t > 0 ? new Date(t).toLocaleString(Qt.locale(), "d MMM yyyy hh:mm") : "unknown";
    }

    // ======================================================================
    // PLACEMENT
    // ======================================================================
    readonly property Item _floatHost: root.overlayItem ? root.overlayItem
                                     : (root.parent ? root.parent : root)
    property rect _anchor: Qt.rect(0, 0, 0, 0)
    onOpenChanged: {
        if (root.open) {
            const a = root.anchorItem;
            const h = root._floatHost;
            if (a && h) {
                const p = a.mapToItem(h, 0, 0);
                root._anchor = Qt.rect(p.x, p.y, a.width, a.height);
            }
        }
    }
    // The room the panel actually has, on whichever side it will open. The
    // anchor is a SNAPSHOT (mapToItem is not reactive), so this cannot chase
    // the panel's own height.
    readonly property real _roomAbove: Math.max(0, root._anchor.y - root.gap - 2)
    readonly property real _roomBelow: Math.max(0, (root._floatHost ? root._floatHost.height : 0)
                                                - root._anchor.y - root._anchor.height - root.gap - 2)
    readonly property real _limit: Math.min(root.maxHeight, Math.max(root._roomAbove, root._roomBelow))

    // Dismiss layer, one z below the panel: a click anywhere else shuts it -- and goes on to whatever it was aimed at.
    LlmDismissLayer {
        parent: root._floatHost
        anchors.fill: parent
        open: root.open
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onDismissed: root.open = false
    }

    Shortcut {
        sequence: "Escape"
        enabled: root.open
        onActivated: root.open = false
    }

    // A text that acts: hover fades faint→accent and the hand cursor says
    // the rest. Nothing announces the affordance but the pointer.
    component LinkText: Item {
        id: link
        property string text: ""
        property color restColor: root.mutedText
        property int pixelSize: root.fontPixelSize
        property alias horizontalAlignment: linkLabel.horizontalAlignment
        signal clicked()
        implicitWidth: linkLabel.implicitWidth
        implicitHeight: linkLabel.implicitHeight
        property real _hoverF: linkArea.containsMouse ? 1 : 0
        Behavior on _hoverF { NumberAnimation { duration: root.hoverMs; easing.type: Easing.OutCubic } }
        Text {
            id: linkLabel
            anchors.fill: parent
            verticalAlignment: Text.AlignVCenter
            text: link.text
            color: Mix.c(link.restColor, root.accent, link._hoverF)
            font.family: root.fontFamily
            font.pixelSize: link.pixelSize
            font.bold: false
        }
        MouseArea {
            id: linkArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: link.clicked()
        }
    }

    // A faint line of the empty state's explanation.
    component TeachLine: Text {
        color: root.faintText
        font.family: root.fontFamily
        font.pixelSize: root.fontPixelSize
        wrapMode: Text.Wrap
    }

    // ======================================================================
    // THE PANEL
    // ======================================================================
    // The row the pointer is on, for the one tip: its exact key and when it
    // was allowed. One tip, anchored to whichever row asked for it, rather
    // than a tip per row -- the rows are a Repeater and the tip is not.
    property Item _tipRow: null
    property string _tipText: ""

    Item {
        id: panel
        parent: root._floatHost
        z: 300
        width: root.menuWidth
        height: Math.round(root._fixedH + root._bodyH)
        // Left-aligned with the wrench, clamped inside the host; above it,
        // or below when there is no room above.
        x: Math.round(Math.max(2, Math.min(parent.width - width - 2, root._anchor.x)))
        y: Math.round(root._anchor.y - height - root.gap >= 2
                      ? root._anchor.y - height - root.gap
                      : root._anchor.y + root._anchor.height + root.gap)

        opacity: root.open ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: root.fadeMs; easing.type: Easing.OutCubic } }

        ShadowBox {
            anchors.fill: parent
            baseRadius: root.radius
            surfaceColor: root.surfaceColor
            backgroundColor: root.fieldColor
            bevelColor: root.bevelColor
            shadowColor: root.shadowColor
            bevelWidth: 1
            shadowWidth: 3
        }

        // ---- The title: what this is, and how many rules stand ------------
        Item {
            id: titleRow
            x: root.padding
            y: root.padding
            width: panel.width - root.padding * 2
            height: root.rowHeight

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, parent.width - root._countSlotW - 8)
                text: "Remembered allowances"
                color: root.primaryText
                font.family: root.fontFamily
                font.pixelSize: root.fontPixelSize
                elide: Text.ElideRight
            }
            Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: root._countSlotW
                horizontalAlignment: Text.AlignRight
                text: root._rows.length === 0 ? ""
                      : root._rows.length + (root._rows.length === 1 ? " rule" : " rules")
                color: root.faintText
                font.family: root.fontFamily
                font.pixelSize: root.figurePixelSize
            }
        }

        // ---- The body: the rules, or what one is --------------------------
        Item {
            id: bodyBox
            x: root.padding
            y: Math.round(root.padding + titleRow.height)
            width: panel.width - root.padding * 2
            height: Math.round(root._bodyH)
            clip: true

            Flickable {
                id: bodyFlick
                objectName: "llmGrantsFlick"
                anchors.fill: parent
                contentWidth: width
                contentHeight: bodyColumn.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                interactive: contentHeight > height + 0.5

                Column {
                    id: bodyColumn
                    width: bodyBox.width
                    spacing: 0

                    // ---- Empty state: what an allowance IS ----------------
                    Item {
                        width: bodyColumn.width
                        height: visible ? teach.implicitHeight + root.dividerGap : 0
                        visible: root._rows.length === 0
                        Column {
                            id: teach
                            width: parent.width
                            spacing: 4
                            TeachLine {
                                width: teach.width
                                text: "Nothing remembered yet."
                            }
                            TeachLine {
                                width: teach.width
                                text: "When a tool wants to act, the prompt asks: Run, Don't run, "
                                      + "or Always allow — with the exact rule printed on that third button."
                            }
                            TeachLine {
                                width: teach.width
                                text: "That button writes the rule here, and it stands in every conversation "
                                      + "until you revoke it. A rule covers exactly the key it names, and nothing else."
                            }
                        }
                    }

                    // ---- The rules, grouped under their tool ---------------
                    Repeater {
                        model: root._groups
                        Column {
                            id: group
                            required property var modelData
                            width: bodyColumn.width
                            spacing: 0

                            Text {
                                width: group.width
                                height: root.rowHeight
                                verticalAlignment: Text.AlignVCenter
                                text: String(group.modelData.tool)
                                color: root.faintText
                                font.family: root.fontFamily
                                font.pixelSize: root.figurePixelSize
                                elide: Text.ElideRight
                            }

                            Repeater {
                                model: group.modelData.rules
                                Item {
                                    id: ruleRow
                                    required property var modelData
                                    readonly property string tool: String(group.modelData.tool)
                                    readonly property string key: String(ruleRow.modelData && ruleRow.modelData.key
                                                                         ? ruleRow.modelData.key : "")
                                    readonly property string label: String(ruleRow.modelData && ruleRow.modelData.label
                                                                           ? ruleRow.modelData.label : ruleRow.key)
                                    width: group.width
                                    height: root.rowHeight

                                    Text {
                                        x: root.indent
                                        width: Math.max(0, usesText.x - x - 8)
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: ruleRow.label
                                        color: root.primaryText
                                        font.family: root.fontFamily
                                        font.pixelSize: root.fontPixelSize
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        id: usesText
                                        x: ruleRow.width - root._xSlotW - 8 - root._usesSlotW
                                        width: root._usesSlotW
                                        anchors.verticalCenter: parent.verticalCenter
                                        horizontalAlignment: Text.AlignRight
                                        text: root._uses(ruleRow.modelData ? ruleRow.modelData.uses : 0)
                                        color: root.mutedText
                                        font.family: root.fontFamily
                                        font.pixelSize: root.figurePixelSize
                                    }
                                    // The × forgets THIS rule.
                                    LinkText {
                                        objectName: "llmGrantForget"
                                        x: ruleRow.width - root._xSlotW
                                        width: root._xSlotW
                                        height: ruleRow.height
                                        text: "×"
                                        horizontalAlignment: Text.AlignHCenter
                                        restColor: root.mutedText
                                        pixelSize: root.fontPixelSize + 2
                                        onClicked: root.revoked(ruleRow.tool, ruleRow.key)
                                    }
                                    // The exact key and the day it was
                                    // allowed, on hover: the row shows the
                                    // policy's words, the tip shows the
                                    // string the rule actually matches on.
                                    HoverHandler {
                                        onHoveredChanged: {
                                            if (hovered) {
                                                root._tipRow = ruleRow;
                                                root._tipText = "key  " + ruleRow.key + "\nallowed  "
                                                    + root._when(ruleRow.modelData ? ruleRow.modelData.at : 0);
                                            } else if (root._tipRow === ruleRow) {
                                                root._tipRow = null;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // The wheel and the two bands, as a SIBLING of the Flickable.
            ScrollDressing {
                objectName: "llmGrantsDressing"
                flick: bodyFlick
                ground: root.fieldColor
                scrollSpeed: root.scrollSpeed
                fadeHeight: Math.min(root.fadeHeight, bodyBox.height / 4)
            }
        }

        // ---- Divider + Revoke all, only with something to revoke ----------
        Item {
            id: dividerBox
            x: root.padding
            y: Math.round(bodyBox.y + bodyBox.height)
            width: panel.width - root.padding * 2
            height: visible ? root.dividerGap * 2 + 1 : 0
            visible: root._rows.length > 0
            Rectangle {
                width: parent.width
                anchors.verticalCenter: parent.verticalCenter
                height: 1
                color: root.shadowColor
            }
        }
        LinkText {
            id: revokeAllLink
            objectName: "llmGrantsRevokeAll"
            x: root.padding
            y: Math.round(dividerBox.y + dividerBox.height)
            width: panel.width - root.padding * 2
            height: visible ? root.rowHeight : 0
            visible: root._rows.length > 0
            text: "Revoke all"
            restColor: root.primaryText
            onClicked: root.revokeAll()
        }

        // ---- The registry's rejections, faint, last -----------------------
        Text {
            x: root.padding
            y: Math.round(revokeAllLink.y + revokeAllLink.height)
            width: panel.width - root.padding * 2
            height: visible ? root.rowHeight : 0
            verticalAlignment: Text.AlignVCenter
            visible: root._errorCount > 0
            text: root._errorLine
            color: root.faintText
            font.family: root.fontFamily
            font.pixelSize: root.figurePixelSize
            elide: Text.ElideRight
        }
    }

    // Everything that is NOT the scrolling body: the panel's height is this
    // plus whatever the body is allowed.
    readonly property real _fixedH: root.padding * 2 + root.rowHeight
        + (root._rows.length > 0 ? root.dividerGap * 2 + 1 + root.rowHeight : 0)
        + (root._errorCount > 0 ? root.rowHeight : 0)
    readonly property real _bodyH: Math.max(root.rowHeight,
        Math.min(bodyColumn.implicitHeight, Math.max(root.rowHeight * 2, root._limit - root._fixedH)))

    HoverTip {
        show: root._tipRow !== null && root.open
        anchorItem: root._tipRow ? root._tipRow : panel
        overlayItem: root.overlayItem
        text: root._tipText
        fontFamily: root.fontFamily
        surfaceColor: root.tipSurfaceColor
        bevelColor: root.bevelColor
        shadowColor: root.shadowColor
        textColor: root.primaryText
    }
}
