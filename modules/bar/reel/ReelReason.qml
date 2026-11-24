pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"

// =============================================================================
// ReelReason.qml -- WHY the idle mode is what it is: the side popup the idle reel's strip puts out when the auto layer holds the
// mode (the engine's REEL CHILD, opened by ReelFollow). The user's words: "just like the tray tooltip, popping out to the right
// with text describing the thing it is" -- so it is the tray label's look: the cause in words, bold, ONE line. The mode it put in
// force is not said (the user: "only the reason why it was engaged ... the subtitle is an explanation of what mode is active, but I
// know this"): the reel beside it shows the mode.
//
//   secondaryKey   the cause -- the ENGINE's, assigned while this content is faded out, so a cause that changes while it is out
//                  swaps its words unseen (the engine's slide and fade), never under the reader's eyes
//   owner          the ReelFollow that opened it: told when the pointer is on it (the reading pause holds while it is)
//
// ITS SIZE IS ITS OWN, from TextMetrics of the words it shows (never read back from the box the engine gives it: CLAUDE.md, a
// width read back into what sizes it loops through the engine). ITS HEIGHT IS EVEN: the engine centres it on the 3rd icon's middle,
// a whole pixel, so an even height puts both edges -- and the line inside -- on whole pixels (CLAUDE.md, a box's edges must be whole
// pixels, not its centre). The line sits at the rounded middle: the padding above and below is `padY` within the line box's own
// fraction (7 and 6.5 at Inter 12, against 7 and 7.5 for the odd height the plain sum would give).
// =============================================================================
Item {
    id: tip

    // ---- what the engine writes ---------------------------------------------
    property var secondaryKey: null
    property rect secondaryCutout: Qt.rect(0, 0, 0, 0)
    property bool secondaryMoving: false

    property var owner: null
    property IconReelStyle style: null

    readonly property string cause: typeof tip.secondaryKey === "string" ? tip.secondaryKey : ""

    readonly property string family: tip.style ? tip.style.reasonFamily : "Inter"
    readonly property real padX: tip.style ? tip.style.reasonPadX : 12
    readonly property real padY: tip.style ? tip.style.reasonPadY : 7
    readonly property int titleSize: tip.style ? tip.style.reasonTitleSize : 12

    // (+1: a bold face lays out a pixel wider than its metrics say, the tray label's same allowance)
    implicitWidth: Math.ceil(causeMetrics.advanceWidth + 1) + 2 * tip.padX
    // the nearest even height to padY + the line + padY (header: whole edges about a whole middle)
    implicitHeight: 2 * Math.round(tip.padY + causeLine.height / 2)

    TextMetrics {
        id: causeMetrics
        font.family: tip.family
        font.pixelSize: tip.titleSize
        font.bold: true
        text: tip.cause
    }
    FontMetrics {
        id: causeLine
        font.family: tip.family
        font.pixelSize: tip.titleSize
        font.bold: true
    }

    // The reading pause holds while the pointer is on the words (ReelFollow). Told on the way out too: a content the engine destroys
    // while the pointer is on it must not leave the strip held open.
    HoverHandler {
        id: hover
    }
    readonly property bool hovered: hover.hovered
    onHoveredChanged: {
        if (tip.owner)
            tip.owner.reasonHovered(tip.hovered);
    }
    Component.onDestruction: {
        if (tip.owner && tip.hovered)
            tip.owner.reasonHovered(false);
    }

    // the line at the rounded middle of the content's own height (never the box's: the engine's box eases)
    Text {
        objectName: "reelReasonCause"
        x: tip.padX
        y: Math.round((tip.implicitHeight - causeLine.height) / 2)
        width: Math.max(0, tip.width - 2 * tip.padX)
        text: tip.cause
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: BarText.ink
        font.family: tip.family
        font.pixelSize: tip.titleSize
        font.bold: true
    }
}
