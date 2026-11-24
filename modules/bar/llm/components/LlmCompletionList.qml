pragma ComponentBehavior: Bound

import QtQuick
import "../../../common/theme"
import "../../../common/components"
import "../../../common/components/Mix.js" as Mix

// =============================================================================
// LlmCompletionList.qml
//
// What the second Tab shows: the paths still possible, in the prompt's own
// groove. It is `ls` in a carved box -- column-major, the way a
// shell fills a screen, so the eye reads down a column and the alphabet runs
// the way it does in a terminal.
//
// IT IS NOT A MENU. Nothing here takes focus and nothing here is selected: the
// caret stays in the prompt, typing narrows the list, Tab completes and Escape
// closes it. A row is a text that acts -- hover fades it to the accent, the
// pointer turns into a hand, a click completes that entry -- which is the
// shell's rule for an affordance: the pointer announces it, nothing else does.
//
// WHY IT LIVES INSIDE THE COMPOSER AND NOT IN THE OVERLAY. Every floating
// thing in this module snapshots its anchor when it opens (mapToItem is not
// reactive), and the composer's top edge MOVES for 260 ms whenever the field
// gains a line -- which is exactly what typing a long path does -- so a
// floating list would drift off the box it belongs to. In the groove it needs
// no dismiss layer, no Escape shortcut of its own, and no overlay reparenting
// to be clickable.
//
// THE HEIGHT IS THE HOST'S, LATCHED. `rowSlots` is set once by the Tab that
// opened the list, and narrowing the matches re-fills those rows without
// re-easing the box: a reserved slot keeps its height (the shell's rule), so
// the composer grows once and shrinks once per completion instead of breathing
// on every keystroke. Anything past the slots scrolls, on the shell's one
// notch (ScrollDressing) and with its edge fade.
//
// FIGURES IN A FIXED SLOT: the match count sits in a slot measured from the
// widest thing it can say, so the header does not move while the list
// narrows.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // PUBLIC API
    // ======================================================================
    // [{ name, isDir }] -- LlmPathComplete.decide()'s rows, in the model's
    // own order (FolderListModel sorts by name).
    property var    rows: []
    // The directory being completed, for the header line.
    property string dir: ""
    // The most rows the list may take before it scrolls inside itself.
    property int    maxRows: 6
    // The most entries DRAWN. A directory with five thousand matches is a
    // typing mistake, not a list: the count line still tells the truth, and
    // the answer is another character, not another screen.
    property int    maxEntries: 120
    // The latched height, in rows. 0 = size to the content (a harness).
    property int    rowSlots: 0

    property string fontFamily: "Inter"
    property string monoFamily: "Consolas"
    property int    fontPixelSize: 11
    property int    figureSize: 10
    property real   radius: 10
    property real   padding: 8
    property real   gap: 6
    property real   colGap: 16
    property real   fadeHeight: 24
    property real   scrollSpeed: 1.0
    property int    hoverMs: 120

    // ---- Palette ----
    property color surfaceColor: Theme.panelSunk     // the groove it is carved into
    property color fillColor: Theme.headerBox        // its own fill
    property color bevelColor: Theme.bevel
    property color shadowColor: Theme.border
    property color primaryText: Theme.textPrimary
    property color mutedText: Theme.textMuted
    property color faintText: Theme.textFaint
    property color accent: Theme.accent

    // The row the pointer chose.
    signal chosen(string name, bool isDir)

    // ---- What the host needs to latch -------------------------------------
    readonly property int columns: Math.max(1, Math.floor(root._availW / root._colW))
    readonly property int totalRows: Math.max(1, Math.ceil(root._shown.length / root.columns))
    readonly property int neededRows: Math.max(1, Math.min(root.maxRows, root.totalRows))

    // ======================================================================
    // GEOMETRY
    // ======================================================================
    readonly property var _shown: {
        const r = root.rows || [];
        return r.length > root.maxEntries ? r.slice(0, root.maxEntries) : r;
    }
    readonly property int _count: root.rows ? root.rows.length : 0
    readonly property bool _truncated: root._count > root._shown.length
    readonly property real _availW: Math.max(1, root.width - root.padding * 2)
    readonly property real _rowH: Math.round(monoFm.height)
    readonly property int  _slots: root.rowSlots > 0 ? root.rowSlots : root.neededRows
    // The widest name drawn, plus the gutter between columns -- `ls`'s own
    // arithmetic, measured with FontMetrics rather than read back off a Text
    // (reading a Text's width into what sizes it is the binding loop).
    readonly property real _colW: {
        const rs = root._shown;
        let w = 0;
        for (let i = 0; i < rs.length; i++) {
            const a = monoFm.advanceWidth(String(rs[i].name) + (rs[i].isDir ? "/" : ""));
            if (a > w)
                w = a;
        }
        return Math.min(root._availW, Math.ceil(w) + root.colGap);
    }

    implicitWidth: 0
    implicitHeight: Math.round(root.padding * 2 + headerRow.height + root.gap + root._slots * root._rowH)

    FontMetrics {
        id: monoFm
        font.family: root.monoFamily
        font.pixelSize: root.fontPixelSize
    }
    FontMetrics {
        id: figFm
        font.family: root.fontFamily
        font.pixelSize: root.figureSize
    }
    readonly property real _countSlotW: Math.ceil(Math.max(
        figFm.advanceWidth("0000 matches"),
        figFm.advanceWidth("first 000 of 00000")))
    readonly property string _countText: root._truncated
        ? "first " + root._shown.length + " of " + root._count
        : root._count + (root._count === 1 ? " match" : " matches")

    // ======================================================================
    // THE BOX
    // ======================================================================
    ShadowBox {
        anchors.fill: parent
        baseRadius: root.radius
        surfaceColor: root.surfaceColor
        backgroundColor: root.fillColor
        bevelColor: root.bevelColor
        shadowColor: root.shadowColor
        bevelWidth: 1
        shadowWidth: 3
    }

    // ---- The header: which directory, and how many -------------------------
    Item {
        id: headerRow
        x: root.padding
        y: root.padding
        width: root._availW
        height: Math.max(dirText.implicitHeight, countText.implicitHeight)

        // ELIDED FROM THE LEFT: the tail of a path is what identifies it.
        Text {
            id: dirText
            x: 0
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, parent.width - root._countSlotW - root.gap)
            text: root.dir + (root.dir.endsWith("/") ? "" : "/")
            color: root.mutedText
            font.family: root.monoFamily
            font.pixelSize: root.fontPixelSize
            elide: Text.ElideLeft
        }
        Text {
            id: countText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: root._countSlotW
            horizontalAlignment: Text.AlignRight
            text: root._countText
            color: root.faintText
            font.family: root.fontFamily
            font.pixelSize: root.figureSize
        }
    }

    // ---- The entries, column-major ----------------------------------------
    Item {
        id: body
        x: root.padding
        y: Math.round(root.padding + headerRow.height + root.gap)
        width: root._availW
        height: Math.max(0, root.height - y - root.padding)
        clip: true

        Flickable {
            id: listFlick
            objectName: "llmCompletionFlick"
            anchors.fill: parent
            contentWidth: width
            contentHeight: grid.height
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            interactive: contentHeight > height + 0.5

            Grid {
                id: grid
                // Only `rows` is set: with TopToBottom the grid fills each
                // column to that many entries and starts the next one, which
                // is exactly how a shell lays out a listing.
                flow: Grid.TopToBottom
                rows: root.totalRows
                width: parent.width

                Repeater {
                    model: root._shown

                    Item {
                        id: entry
                        required property var modelData
                        readonly property string name: String(entry.modelData ? entry.modelData.name : "")
                        readonly property bool isDir: !!(entry.modelData && entry.modelData.isDir)
                        width: root._colW
                        height: root._rowH

                        property real _hoverF: entryArea.containsMouse ? 1 : 0
                        Behavior on _hoverF { NumberAnimation { duration: root.hoverMs; easing.type: Easing.OutCubic } }

                        Text {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            text: entry.name + (entry.isDir ? "/" : "")
                            color: Mix.c(root.primaryText, root.accent, entry._hoverF)
                            font.family: root.monoFamily
                            font.pixelSize: root.fontPixelSize
                            font.bold: false
                            elide: Text.ElideRight
                        }
                        MouseArea {
                            id: entryArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.chosen(entry.name, entry.isDir)
                        }
                    }
                }
            }
        }

        // The shell's one notch and its edge fade, as a sibling of the
        // Flickable (a child would be reparented into the content and scroll
        // away with it).
        ScrollDressing {
            flick: listFlick
            ground: root.fillColor
            fadeHeight: Math.min(root.fadeHeight, body.height / 4)
            scrollSpeed: root.scrollSpeed
        }
    }
}
