pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"

// =============================================================================
// ClipHeader.qml -- the row above the shelf.
//
//   search    a CarvedSearchField, left, takes what the chips and the right-hand text leave
//   chips     All / Text / Image / Link / Pinned on a TabSelector (the filter)
//   marks     "N picked", in the accent, while cards are marked (Ctrl+Space); it fades out
//             still saying the last count
//   count     how many cards the shelf shows, in a fixed right-aligned slot
//   undo      an UndoDrainButton after a delete: the window drains in the
//             button's own shading, then it is gone (`armUndo()`)
//
// The header holds NO state of its own about the clipboard: the popup says
// what to show (`count`, `marksCount`, `filter`) and hears what the user did
// (`queryEdited`, `filterPicked`, `undoClicked`, `searchEscaped`). The search
// text is the popup's `query`: `setQuery()` puts it into the field without
// cutting any binding (the field's own `text` is its edit's, CLAUDE.md).
//
// Every figure keeps its own fixed-width slot, so nothing jitters as a number
// changes; the undo button and the marks fade in and out (160 ms), and their
// slots open and close on the same fraction, the search field and the chips
// giving way, so the line never carries dead space. Nothing crossfades two
// layouts.
// =============================================================================
Item {
    id: header

    property string fontFamily: "Inter"
    property int bodySize: 12
    // "all" | "text" | "image" | "link" | "pinned"
    property string filter: "all"
    property int count: 0
    // How many cards the history holds, and whether a chip or the search narrows the shelf to `count`.
    property int total: 0
    property bool narrowed: false
    property int marksCount: 0
    property int undoMs: 8000
    property int presenceMs: 160
    // The ground the search field is carved into.
    property color surfaceColor: Theme.surface
    property real gap: 12
    property real chipsWidth: 330
    property real countWidth: 64
    property real marksWidth: 76
    property real searchMinWidth: 120

    readonly property alias searchField: search
    readonly property bool undoing: undo.undoing

    signal queryEdited(string text)
    signal filterPicked(string id)
    signal searchEscaped
    signal undoClicked

    implicitHeight: 32

    // The marks label's last non-zero count (a change handler: it must not be a binding the label's own
    // fade-out could read as 0).
    onMarksCountChanged: {
        if (header.marksCount > 0)
            marksText.held = header.marksCount;
    }
    Component.onCompleted: {
        if (header.marksCount > 0)
            marksText.held = header.marksCount;
    }

    function setQuery(t) {
        if (search.text !== t)
            search.text = t;
    }
    function armUndo() {
        undo.arm();
    }

    // ---- the line, right to left ---------------------------------------------------
    // The count sits flush right in a slot of its own. Undo and the marks take room only while they are
    // shown: each slot's width is its width x its presence fraction (the one clock that fades it), so the
    // search field -- which takes whatever the chips and the right-hand text leave -- gives up exactly
    // that much, and a header with nothing picked has no dead space between the chips and the count.
    // Whole pixels (a carved field's edges must not sit on halves).
    readonly property real _undoW: Math.ceil(undo.implicitWidth)
    readonly property real _undoSlot: Math.round((header._undoW + header.gap) * undo.f)
    readonly property real _marksSlot: Math.round((header.marksWidth + header.gap) * marksText.f)
    readonly property real _countX: header.width - header.countWidth
    // Where the chips end: the left edge of everything shown on the right, less a gap.
    readonly property real _chipsRight: header._countX - header.gap - header._undoSlot - header._marksSlot
    readonly property real _chipsX: Math.max(header.searchMinWidth + header.gap, header._chipsRight - header.chipsWidth)

    CarvedSearchField {
        id: search
        objectName: "clipSearch"
        x: 0
        y: 0
        width: header._chipsX - header.gap
        height: header.height
        placeholder: "Search clipboard"
        fontFamily: header.fontFamily
        pixelSize: header.bodySize
        surfaceColor: header.surfaceColor
        onEdited: t => header.queryEdited(t)
        onEscaped: header.searchEscaped()
    }

    TabSelector {
        id: chips
        objectName: "clipChips"
        x: header._chipsX
        y: 0
        width: header.chipsWidth
        height: header.height
        trackSurfaceColor: header.surfaceColor
        fontFamily: header.fontFamily
        fontPixelSize: header.bodySize
        tabs: [
            {
                id: "all",
                label: "All"
            },
            {
                id: "text",
                label: "Text"
            },
            {
                id: "image",
                label: "Image"
            },
            {
                id: "link",
                label: "Link"
            },
            {
                id: "pinned",
                label: "Pinned"
            }
        ]
        onTabChanged: id => header.filterPicked(id)
    }
    // The selector writes its own currentTab on a click, which would cut a
    // plain binding for good (CLAUDE.md): the truth is a Binding element.
    Binding {
        target: chips
        property: "currentTab"
        value: header.filter
    }

    Text {
        id: marksText
        objectName: "clipMarks"
        x: header._countX - header._undoSlot - header.gap - header.marksWidth
        width: header.marksWidth
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        // The last count that was above zero: the label that fades out when the last mark goes still says
        // what it said ("1 picked"), never "0 picked".
        text: marksText.held > 0 ? marksText.held + " picked" : ""
        font.family: header.fontFamily
        font.pixelSize: header.bodySize
        font.bold: true
        color: Theme.accent
        property int held: 0
        property real f: header.marksCount > 0 ? 1 : 0
        Behavior on f {
            NumberAnimation {
                duration: header.presenceMs
                easing.type: Easing.OutCubic
            }
        }
        opacity: marksText.f
        visible: marksText.f > 0
    }

    Text {
        id: countText
        objectName: "clipCount"
        x: header._countX
        width: header.countWidth
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        // Nothing on an empty shelf: "Nothing copied yet" already says it.
        // narrowed, the shell's own count against a total ("3 / 18", as DownloadStats writes one): it fits the slot "18 cards" has
        text: header.count === 0 ? "" : header.narrowed ? header.count + " / " + header.total : header.count + (header.count === 1 ? " card" : " cards")
        font.family: header.fontFamily
        font.pixelSize: header.bodySize
        color: Theme.textMuted
    }

    UndoDrainButton {
        id: undo
        objectName: "clipUndo"
        x: header._countX - header.gap - header._undoW
        anchors.verticalCenter: parent.verticalCenter
        height: header.height - 4
        text: "Undo"
        undoText: "Undo"
        drainMs: header.undoMs
        surfaceColor: header.surfaceColor
        fontFamily: header.fontFamily
        fontPixelSize: header.bodySize
        // Present only while the window runs.
        property real f: undo.undoing ? 1 : 0
        Behavior on f {
            NumberAnimation {
                duration: header.presenceMs
                easing.type: Easing.OutCubic
            }
        }
        opacity: undo.f
        visible: undo.f > 0
        enabled: undo.undoing
        onUndoClicked: header.undoClicked()
    }
}
