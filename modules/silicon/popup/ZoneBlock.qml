pragma ComponentBehavior: Bound

import QtQuick
import QtQml

import "../../common/components"

// =============================================================================
// ZoneBlock.qml -- a zone's name plate: its caption, its arrows and, for a zone that has them, its figures.
//
//        ‹   Balanced   ›        the caption's head (what the zone IS), the arrows flank it
//        3.42 GHz · 38 %         the figures (a child of this block, in fixed slots) -- only the GPU's, only while its card is awake
//           tweaked              the caption's tail, muted; the zone's ERROR takes this row, in the error colour
//
// A BUNCH, ANCHORED AT ITS FOOT. The plate is as tall as the rows it has right now and the host places its FOOT, not its
// top (the plate hugs the top edge of its hologram), so a row that comes pushes everything above it UP: a tail appearing under the head
// moves the head up by its own height, never down into the hologram. Nothing is reserved: a plate without a tail ends at its head.
//
// ONE MOVE, TWO CLOCKS. The layout moves by the shell's resize easing (`slideMs`, 260 ms OutCubic): a row's SLOT grows and shrinks as a
// fraction (`_te`, `_fe`, whole pixels each frame); the row's PRESENCE fades by the shell's presence time (`fadeMs`,
// 160 ms) -- text swaps are instant. Each slot clips its row and the row sits at the slot's FOOT, so it appears where it will stay and the
// head rides on top of it as it opens; a closing slot takes the row with it and nothing ever lies on another row (the tail never slides through
// half-faded figures: the figures' slot ends where the tail's begins).
//
// The words come from the data layer (`vm.caption.<zone>` and its `*Error`): they are split at the first " · " into a head and a tail,
// nothing else is parsed -- except that words with no " · " that are too wide to be a name (a sentence: "Power profiles need the
// silicon helper ...") are the TAIL, muted, with no head. The words that were up stay up while their presence fades out: the head's and the
// tail's each (a tail that goes keeps its words until it is gone), and the whole plate's when the caption goes altogether.
//
// The arrows (ZoneChevron) are present only while the pointer is in the zone (`hovered`) and only where there is a step that way
// (`canPrev` / `canNext`): absent at an end, no looping. The plate's width is fixed, so the arrows hold still whatever the caption says; a
// tail wider than the plate is elided, and its full words are a hover tip (or `tip`, when the host has something better to say there).
// =============================================================================
Item {
    id: root

    // ---- in ----
    property string caption: ""
    property string error: ""
    property bool chevrons: true
    property bool canPrev: false
    property bool canNext: false
    property bool hovered: false
    property Item overlayItem: null           // where the tip floats (the popup's overlay layer)
    property string tip: ""                   // words for the tail's hover tip (else the tail itself, when it is cut)
    property string fontFamily: "Inter"
    property int headSize: 16
    property int tailSize: 12
    property int figureSize: 11
    property bool figuresShown: false         // the zone has its figures row now (the GPU's, while its card is awake): the row's slot opens
    property real plateWidth: 240             // the tail's and the figures' room
    property real arrowSpan: 190              // the arrows' centres, apart: wide enough for the longest head
    property int fadeMs: 160                  // a presence fades (CLAUDE.md: text swaps are instant, only presence fades)
    property int slideMs: 260                 // the layout moves (CLAUDE.md: resize eases 260 ms OutCubic)

    // The figures go here (their slot's foot); the plate's width and the row's height are theirs to fill.
    default property alias figures: figuresBox.data
    readonly property alias figuresBox: figuresBox

    signal step(int dir)

    // ---- for the probes ----
    readonly property bool sentence: root._sentenceNow
    readonly property real presence: root._p                  // the whole plate's

    readonly property real _figGap: 2             // the name -> the figures
    readonly property real _tailGap: 4            // what is above the tail -> the tail
    readonly property real _headH: Math.ceil(fmHead.height)
    readonly property real _figH: Math.ceil(fmFig.height)
    readonly property real _tailH: Math.ceil(fmTail.height)

    implicitWidth: root.plateWidth
    implicitHeight: root._headH + figuresSlot.height + tailSlot.height

    FontMetrics {
        id: fmHead
        font.family: root.fontFamily
        font.pixelSize: root.headSize
        font.bold: true
    }
    FontMetrics {
        id: fmTail
        font.family: root.fontFamily
        font.pixelSize: root.tailSize
    }
    FontMetrics {
        id: fmFig
        font.family: root.fontFamily
        font.pixelSize: root.figureSize
    }

    // ---- the words, as the facts have them now ----
    readonly property bool _on: root.caption !== "" || root.error !== ""
    function _headOf(w) {
        const i = w.indexOf(" · ");
        return i < 0 ? w : w.substring(0, i);
    }
    function _tailOf(w) {
        const i = w.indexOf(" · ");
        return i < 0 ? "" : w.substring(i + 3);
    }
    readonly property string _headNow: root._headOf(root.caption)
    readonly property string _tailOwn: root.error !== "" ? root.error : root._tailOf(root.caption)     // the caption's tail, or the error that takes its row
    TextMetrics {
        id: tmHead
        font.family: root.fontFamily
        font.pixelSize: root.headSize
        font.bold: true
        text: root._headNow
    }
    readonly property bool _sentenceNow: root._on && root._tailOwn === "" && tmHead.advanceWidth > root.arrowSpan - root._arrowW
    readonly property string _headRowNow: root._sentenceNow ? "" : root._headNow
    readonly property string _tailRowNow: root._sentenceNow ? root._headNow : root._tailOwn
    readonly property bool _errNow: root.error !== ""

    // ---- ... and the words that stay up while a presence fades out ----
    // The head's and the tail's rows each keep the last words they had: the whole plate's going keeps both, a tail's going keeps the tail's. `RestoreNone`: a
    // Binding that lets go leaves the property where it was (the default would put back what it held before the Binding came).
    property string _headRow: ""
    property string _tailRow: ""
    property bool _errRow: false
    Binding {
        target: root
        property: "_headRow"
        value: root._headRowNow
        when: root._on
        restoreMode: Binding.RestoreNone
    }
    Binding {
        target: root
        property: "_tailRow"
        value: root._tailRowNow
        when: root._tailRowNow !== ""
        restoreMode: Binding.RestoreNone
    }
    Binding {
        target: root
        property: "_errRow"
        value: root._errNow
        when: root._tailRowNow !== ""
        restoreMode: Binding.RestoreNone
    }

    // ---- the clocks: the plate's presence, the tail's presence, and the slots' extents ----
    property real _p: root._on ? 1 : 0
    Behavior on _p {
        NumberAnimation {
            duration: root.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    readonly property bool _tailWanted: root._on && root._tailRowNow !== ""
    property real _tp: root._tailWanted ? 1 : 0
    Behavior on _tp {
        NumberAnimation {
            duration: root.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    property real _te: root._tailWanted ? 1 : 0
    Behavior on _te {
        NumberAnimation {
            duration: root.slideMs
            easing.type: Easing.OutCubic
        }
    }
    property real _fe: root.figuresShown ? 1 : 0
    Behavior on _fe {
        NumberAnimation {
            duration: root.slideMs
            easing.type: Easing.OutCubic
        }
    }

    // ---- row 1: the head, the arrows ----
    readonly property real _arrowW: 28
    // FadeColors: what is live inside the board's island hole carries its own old colours to the new (SiliconIsland)
    property bool islandArmed: false
    FadeColor { id: headFade; token: "textPrimary"; active: root.islandArmed; place: root }
    FadeColor { id: mutedFade; token: "textMuted"; active: root.islandArmed; place: root }
    FadeColor { id: errFade; token: "error"; active: root.islandArmed; place: root }
    Text {
        id: head
        x: Math.round((root.plateWidth - width) / 2)
        y: 0
        width: root.arrowSpan - root._arrowW
        height: root._headH
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        text: root._headRow
        color: headFade.value
        font.family: root.fontFamily
        font.pixelSize: root.headSize
        font.bold: true
        opacity: root._p
    }
    ZoneChevron {
        id: prevMark
        x: Math.round((root.plateWidth - root.arrowSpan - width) / 2)
        y: Math.round((root._headH - height) / 2)
        dir: -1
        islandArmed: root.islandArmed
        available: root.chevrons && root.canPrev
        hovered: root.hovered
        onClicked: root.step(-1)
    }
    ZoneChevron {
        id: nextMark
        x: Math.round((root.plateWidth + root.arrowSpan - width) / 2)
        y: Math.round((root._headH - height) / 2)
        dir: 1
        islandArmed: root.islandArmed
        available: root.chevrons && root.canNext
        hovered: root.hovered
        onClicked: root.step(1)
    }

    // ---- row 2: the figures (their slot opens while the zone has them; the row sits at the slot's foot) ----
    Item {
        id: figuresSlot
        x: 0
        y: root._headH
        width: root.plateWidth
        height: Math.round((root._figGap + root._figH) * root._fe)
        clip: true
        Item {
            id: figuresBox
            x: 0
            y: figuresSlot.height - root._figH
            width: root.plateWidth
            height: root._figH
        }
    }

    // ---- row 3: the tail, or the error (the last row; its slot is open while there are words for it) ----
    Item {
        id: tailSlot
        x: 0
        y: figuresSlot.y + figuresSlot.height
        width: root.plateWidth
        height: Math.round((root._tailGap + root._tailH) * root._te)
        clip: true
        Text {
            id: tail
            x: 0
            y: tailSlot.height - root._tailH
            width: root.plateWidth
            height: root._tailH
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            text: root._tailRow
            color: root._errRow ? errFade.value : mutedFade.value
            font.family: root.fontFamily
            font.pixelSize: root.tailSize
            opacity: root._p * root._tp
        }
    }
    // the whole tail, when it does not fit
    MouseArea {
        id: tailHover
        x: 0
        y: tailSlot.y + tail.y
        width: tail.width
        height: tail.height
        enabled: tail.truncated || root.tip !== ""
        acceptedButtons: Qt.NoButton
        cursorShape: undefined   // clicks pass through: the cursor is what lies under it (a MouseArea owns an Arrow)
        hoverEnabled: true
    }
    HoverTip {
        show: tailHover.containsMouse && (tail.truncated || root.tip !== "")
        anchorItem: tail
        overlayItem: root.overlayItem
        text: root.tip !== "" ? root.tip : root._tailRow
        side: "below"
        fontFamily: root.fontFamily
    }
}
