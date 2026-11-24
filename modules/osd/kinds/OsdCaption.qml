pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix

// =============================================================================
// OsdCaption.qml -- the dictation's live words when they go to no field (round 5): a window take (fn+Ctrl+F10, the focused
// window's sound transcribed) and a voice ask (Alt+fn+F10, a question for the local model). The OSD hosts it as the kind
// "caption" (modules/dictation/DictationService.qml asks for it, renews it every second while the take runs and withdraws it
// when the take ends), so it hangs from the bar beside the user's popups, never in thePopup.
//
//   head   a glyph (closed captions for a window take, a speaking head for an ask) and what the take does now, muted:
//          "Transcribing Zen", "Waiting for sound from Zen", "Loading the speech model", "Ask the model"; at its far end
//          the HIDE button (the notes' compress glyph, faint, the accent under the pointer): `hideRequested()`, and the
//          owner tucks the card into its bar (or the pill into a ball) while the take runs on. It is the one control the
//          pill takes (`hideRect`, its hit area, which the pill's window lets through), so it answers whatever `interactive` says.
//   words  the last `captionLines` lines (`captionPLines` in the pill) of what was heard: the written sentences in the text
//          colour, the sentence being spoken after them muted (it may still change), one paragraph; older lines scroll up out of
//          a top fade (ScrollDressing: a fade is a distance from the end, so a short text has none). A swap is instant. With
//          nothing heard yet the hint stands there, faint.
//
// FIXED SIZE (OsdStyle.captionExtent): a fixed width and a fixed number of lines, so the card never resizes while words come in --
// on a bar, in the pill and on every update. In the pill (a capsule) the words keep clear of its rounded ends. Every line is `captionLineH` px (Text.FixedHeight), so the words scroll by whole
// lines on whole pixels. Payload: `caption: { mode: "source" | "ask", head, lines: [sentence...], live, hint }`.
// =============================================================================
Item {
    id: root

    property string kind: "caption"
    property string orientation: "h"
    property var payload: ({})
    property bool interactive: true
    property var style: null
    property real renderScale: 1

    signal hideRequested()
    // The hide button's hit area in this card's px (OsdContent maps it out to the pill's window).
    readonly property rect hideRect: Qt.rect(hideBtn.x - hideBtn.reach, hideBtn.y - hideBtn.reach,
                                             hideBtn.width + 2 * hideBtn.reach, hideBtn.height + 2 * hideBtn.reach)

    readonly property var c: root.payload && root.payload.caption ? root.payload.caption : ({})
    readonly property bool isPill: root.orientation === "pill"
    // The pill is a capsule (its radius half its height): the words stand clear of its rounded ends at their outer rows -- the
    // capsule's pad plus how far the curve reaches in at the content's top and bottom (`pad` from the edge).
    readonly property real padX: {
        if (!root.isPill)
            return root.style.pad;
        const r = root.style.captionExtent("pill").h / 2;
        const d = r - root.style.pad;
        return root.style.pillPad + Math.ceil(r - Math.sqrt(Math.max(0, r * r - d * d)));
    }
    readonly property int lineCount: root.isPill ? root.style.captionPLines : root.style.captionLines
    readonly property real lineH: root.style.captionLineH
    readonly property real headH: root.style.captionHeadH

    function _esc(t) {
        return String(t || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }
    readonly property string _said: (root.c.lines || []).map(String).filter(x => x.trim() !== "").join(" ")
    readonly property string _live: String(root.c.live || "").trim()
    // StyledText: the live words in the muted ink after the written ones, in one paragraph (one Text, so they wrap together)
    readonly property string _html: root._esc(root._said)
        + (root._live === "" ? "" : (root._said === "" ? "" : " ") + "<font color=\"" + Theme.textMuted + "\">" + root._esc(root._live) + "</font>")

    OsdGlyph {
        id: glyph
        osd: root.style
        x: Math.round(root.padX)
        y: Math.round(root.style.pad)
        glyph: root.c.mode === "ask" ? "\u{F05CB}" : "\u{F0DBD}"
        size: root.headH
        color: Theme.accent
    }
    Text {
        id: head
        x: Math.round(glyph.x + glyph.width + root.style.captionGap)
        y: glyph.y
        width: Math.max(0, hideBtn.x - root.style.captionGap - x)
        height: root.headH
        verticalAlignment: Text.AlignVCenter
        text: String(root.c.head || "")
        color: Theme.textMuted
        font.family: root.style.textFont
        font.pixelSize: root.style.captionHeadPx
        elide: Text.ElideRight
    }

    // THE HIDE BUTTON (the header): the notes' "back to the default size" button's look, centred on the head row by hand.
    Item {
        id: hideBtn
        objectName: "caption-hide"
        // the hit area reaches this far past the glyph's box on every side
        readonly property real reach: 4
        property real hf: hideArea.containsMouse ? 1 : 0
        Behavior on hf {
            NumberAnimation {
                duration: 120
                easing.type: Easing.OutCubic
            }
        }
        width: 16
        height: 16
        x: Math.round(root.width - root.padX - hideBtn.width)
        y: Math.round(root.style.pad + (root.headH - hideBtn.height) / 2)
        Text {
            anchors.centerIn: parent
            text: "\uF066"
            font.family: "Symbols Nerd Font"
            font.pixelSize: 12
            color: Mix.c(Theme.textFaint, Theme.accent, hideBtn.hf)
        }
        MouseArea {
            id: hideArea
            anchors.fill: parent
            anchors.margins: -hideBtn.reach
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.hideRequested()
        }
    }
    // (a child of the card, not of the button: a tip with no overlay is placed inside its parent)
    HoverTip {
        anchorItem: hideBtn
        side: "left"
        show: hideArea.containsMouse
        text: "Hide the transcript"
    }

    Item {
        id: area
        x: Math.round(root.padX)
        y: Math.round(root.style.pad + root.headH + root.style.captionGap)
        width: Math.max(0, Math.round(root.width - 2 * root.padX))
        height: root.lineCount * root.lineH

        Flickable {
            id: scroller
            anchors.fill: parent
            clip: true
            // the newest line at the foot; one reader of nothing (the card takes no wheel), so no fixup ever moves it
            interactive: false
            contentWidth: scroller.width
            contentHeight: body.height
            contentY: Math.max(0, scroller.contentHeight - scroller.height)
            Text {
                id: body
                width: scroller.width
                wrapMode: Text.Wrap
                textFormat: Text.StyledText
                lineHeightMode: Text.FixedHeight
                lineHeight: root.lineH
                text: root._html
                color: Theme.textPrimary
                font.family: root.style.textFont
                font.pixelSize: root.style.captionPx
            }
        }
        ScrollDressing {
            anchors.fill: scroller
            flick: scroller
            wheelEnabled: false
            ground: Theme.surface
            fadeHeight: root.lineH
        }
        Text {
            visible: root._said === "" && root._live === ""
            width: area.width
            height: root.lineH
            verticalAlignment: Text.AlignVCenter
            text: String(root.c.hint || "")
            color: Theme.textFaint
            font.family: root.style.textFont
            font.pixelSize: root.style.captionPx
            elide: Text.ElideRight
        }
    }
}
