pragma ComponentBehavior: Bound

import QtQuick
import "../../../common/theme"
import "../../../common/components"

// =============================================================================
// LlmQueueStrip.qml
//
// What is waiting to be asked (the message queue). A message sent while
// the model is busy waits in the service's queue and runs, in order, when the
// server is free; this is the box that says so, between the transcript and the
// composer, so a queued message is never a silent one.
//
// One carved box (a list of the shell's own kind), one row per waiting message,
// oldest first: its place, what was typed, and the MODEL that will answer it --
// the picker's choice when it was queued -- with the conversation it joins when
// that is not the one in front of the user. Three rows show; the rest are a
// count. The box is absent when nothing waits, and its height is ONE eased
// fraction (the shell's 260 ms OutCubic), so a message queued while another is
// answered slides the composer up rather than jumping it.
//
// THE POINTER IS THE AFFORDANCE. A row lights on hover; a click takes the
// message BACK into the composer (text, files and model) to be edited and sent
// again; a right click moves it to the front of the queue; the cross at the
// row's end -- present only while the row is hovered -- removes it. No glyph
// stands there at rest.
//
// The rows are facts (`id`, `text`, `model`, `where`): a Repeater's model may
// never hold a themed colour, so the delegates resolve every colour themselves.
// =============================================================================
Item {
    id: root

    // [{ id, text, model, where }] oldest first; `where` is "" for the
    // conversation in front of the user, else "new chat" or "in <title>".
    property var entries: []
    property int maxRows: 3
    // Room for the model tag / the place tag, as a share of the row's width.
    property real modelShare: 0.3

    property string fontFamily: "Inter"
    property int    fontPixelSize: 12
    property int    figureSize: 10
    property real   radius: 10
    property real   padding: 8
    property real   rowHeight: 22
    property int    resizeMs: 260
    property int    fadeMs: 160
    property Item   overlayItem: null

    property color surfaceColor: Theme.surface        // the ground the box sits on
    property color boxColor: Theme.listBox
    property color bevelColor: Theme.bevel
    property color shadowColor: Theme.border
    property color primaryText: Theme.textPrimary
    property color mutedText: Theme.textMuted
    property color faintText: Theme.textFaint
    property color accent: Theme.accent
    property color tipSurfaceColor: Theme.surface

    signal removeRequested(string id)
    signal takeBackRequested(string id)
    signal promoteRequested(string id)

    // ---- Geometry: the whole box is one fraction ------------------------------
    readonly property int count: root.entries ? root.entries.length : 0
    readonly property int shownRows: Math.min(root.maxRows, root.count)
    readonly property int hiddenRows: Math.max(0, root.count - root.shownRows)
    // The height the box wants at full presence, in whole pixels.
    readonly property int fullHeight: root.count === 0 ? 0
        : Math.round(root.padding * 2 + root.shownRows * root.rowHeight + (root.hiddenRows > 0 ? root.rowHeight : 0))
    property real shownHeight: root.fullHeight
    Behavior on shownHeight { NumberAnimation { duration: root.resizeMs; easing.type: Easing.OutCubic } }
    // 0 when nothing waits, 1 when the box is complete: what a host's gap follows.
    readonly property real presence: root.fullHeight > 0 ? Math.max(0, Math.min(1, root.shownHeight / root.fullHeight))
                                                         : Math.max(0, Math.min(1, root.shownHeight / Math.max(1, root.lastFull)))
    // The last height the box had, so the closing fraction has something to divide by.
    property int lastFull: 0
    onFullHeightChanged: if (root.fullHeight > 0) root.lastFull = root.fullHeight

    implicitWidth: 0
    implicitHeight: Math.round(root.shownHeight)
    visible: root.implicitHeight > 0

    ShadowBox {
        anchors.fill: parent
        baseRadius: root.radius
        surfaceColor: root.surfaceColor
        backgroundColor: root.boxColor
        bevelColor: root.bevelColor
        shadowColor: root.shadowColor
        bevelWidth: 1
        shadowWidth: 3
        opacity: root.presence
    }

    FontMetrics {
        id: figFm
        font.family: root.fontFamily
        font.pixelSize: root.figureSize
    }
    // The place figure ("3") has a slot as wide as the widest it can be.
    readonly property real _placeSlotW: Math.ceil(figFm.advanceWidth("00"))

    Column {
        x: root.padding
        y: root.padding
        width: root.width - root.padding * 2
        opacity: root.presence

        Repeater {
            model: root.entries ? root.entries.slice(0, root.maxRows) : []
            delegate: Item {
                id: row
                required property var modelData
                required property int index
                width: parent ? parent.width : 0
                height: root.rowHeight
                readonly property bool hot: rowHover.hovered || xHover.hovered

                // A wash on the hovered row: a fraction, not a colour animation.
                property real _hotF: row.hot ? 1 : 0
                Behavior on _hotF { NumberAnimation { duration: root.fadeMs; easing.type: Easing.OutCubic } }

                Text {
                    id: placeText
                    anchors.verticalCenter: parent.verticalCenter
                    width: root._placeSlotW
                    text: String(row.index + 1)
                    color: root.faintText
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                }
                // The tags on the right: [where] [model], then the cross's slot.
                Text {
                    id: crossText
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 16
                    horizontalAlignment: Text.AlignRight
                    text: ""
                    color: root.mutedText
                    opacity: row._hotF
                    font.family: "Symbols Nerd Font"
                    font.pixelSize: root.figureSize
                }
                Text {
                    id: modelText
                    anchors.right: crossText.left
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(Math.ceil(modelMetrics.advanceWidth), row.width * root.modelShare)
                    horizontalAlignment: Text.AlignRight
                    text: String(row.modelData.model || "")
                    color: root.mutedText
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                    elide: Text.ElideRight
                }
                // Widths come from metrics, never from the drawn Text.
                TextMetrics {
                    id: modelMetrics
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                    text: String(row.modelData.model || "")
                }
                TextMetrics {
                    id: whereMetrics
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                    text: String(row.modelData.where || "")
                }
                Text {
                    id: whereText
                    anchors.right: modelText.left
                    anchors.rightMargin: String(row.modelData.where || "").length > 0 ? 8 : 0
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(Math.ceil(whereMetrics.advanceWidth), row.width * root.modelShare)
                    horizontalAlignment: Text.AlignRight
                    text: String(row.modelData.where || "")
                    color: root.faintText
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                    elide: Text.ElideRight
                }
                Text {
                    id: bodyText
                    x: placeText.width + 6
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, whereText.x - x - 8)
                    text: String(row.modelData.text || "").replace(/\s+/g, " ")
                    color: row.hot ? root.primaryText : root.mutedText
                    font.family: root.fontFamily
                    font.pixelSize: root.fontPixelSize
                    elide: Text.ElideRight
                }

                // The row: a click takes it back, a right click moves it first.
                MouseArea {
                    id: rowArea
                    anchors.fill: parent
                    anchors.rightMargin: 22
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: mouse => {
                        if (mouse.button === Qt.RightButton) root.promoteRequested(String(row.modelData.id));
                        else root.takeBackRequested(String(row.modelData.id));
                    }
                }
                HoverHandler { id: rowHover }
                // The cross: its own hit area, at the row's end.
                MouseArea {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 22
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.removeRequested(String(row.modelData.id))
                    HoverHandler { id: xHover }
                }
                HoverTip {
                    show: rowHover.hovered && !xHover.hovered
                    delayMs: 500
                    anchorItem: row
                    overlayItem: root.overlayItem
                    text: row.index === 0
                          ? "Next. Click to edit it in the composer."
                          : "Click to edit it in the composer. Right click runs it next."
                    fontFamily: root.fontFamily
                    surfaceColor: root.tipSurfaceColor
                    bevelColor: root.bevelColor
                    shadowColor: root.shadowColor
                    textColor: root.primaryText
                }
            }
        }
        Item {
            width: parent.width
            height: root.hiddenRows > 0 ? root.rowHeight : 0
            visible: root.hiddenRows > 0
            Text {
                x: root._placeSlotW + 6
                anchors.verticalCenter: parent.verticalCenter
                text: "+" + root.hiddenRows + " more queued"
                color: root.faintText
                font.family: root.fontFamily
                font.pixelSize: root.figureSize
            }
        }
    }

}
