pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "data/WikiCardModel.js" as Card
import "WikiGlyphs.js" as Glyphs

// =============================================================================
// WikiIntro.qml -- the entry's one paragraph.
//
// ONE block of StyledText at body size, built by `introSegments` (every link is
// `<a href="N">`, N the index in `card.introLinks`; the intro's own newlines are
// `<br>` already). A PLAIN click on a link
// says `linkOpened(link)` (the popup opens it in the browser), a CTRL+click
// says `linkFollowed(link)` (the popup follows it into the rabbit hole).
//
//   * The text has no mouse of its own (`enabled: false`): Text takes the press
//     of a link and would cancel the handlers' tap. Two TapHandlers on THIS
//     item, told apart by `acceptedModifiers`, read `linkAt` at the tap.
//   * The hand cursor is a HoverHandler on this item too -- an ANCESTOR of the
//     text: a hover handler stacked over a link would take the link's hover.
//   * Links are the accent; the hover is ONE fraction that eases their colour
//     to the hover accent (`linkColor` is one colour for all of them).
//
// THE MARKS. A generated intro carries the sparkle, an edited (cleaned) one the
// pencil, small at the foot of the block on the right, with a tip that says
// what it means (`markTips`). An original intro carries nothing. The room for
// the mark is kept IN the text: the paragraph ends in non-breaking spaces, which
// glue to the last word and wrap with it, so the mark never sits on a word and
// the measure of the block already includes it.
//
// SIZE. `implicitHeight` is the block's own (whole pixels); a tab with no card
// reserves `emptyIntroLines` lines, so a tab without an entry sizes like one
// with. The host gives the item its width and any taller slot; the text is
// top-aligned in it, the empty line centred.
//
// THE EMPTY POOL'S BUTTON. With no card and `offerProcess` (the host says a batch
// could start: none runs or waits, the network is up), a raised "Process
// articles" stands under the empty words and says `processRequested()`; the two
// are centred together as one block in the reserved lines (symmetric room).
// =============================================================================
Item {
    id: root

    property var card: null
    property string tab: ""
    property WikiStyle style: WikiStyle {}
    property string fontFamily: "Inter"
    property Item overlayItem: null
    // False while loading or moving: no hover, no taps.
    property bool interactive: true
    property string emptyText: "No articles yet — the pool is being filled"
    property bool offerProcess: false

    signal linkOpened(var link)
    signal linkFollowed(var link)
    signal processRequested()

    readonly property bool hasCard: root.card !== null && root.card !== undefined
    readonly property var _tips: Card.markTips(root.card)
    readonly property string markKind: root._tips.generated !== "" ? "generated" : root._tips.edited !== "" ? "edited" : ""
    readonly property string markTip: root._tips.generated !== "" ? root._tips.generated : root._tips.edited
    readonly property int _padN: root.markKind !== "" && nbsp.advanceWidth > 0
        ? Math.ceil(root.style.markBox / nbsp.advanceWidth) : 0
    readonly property string _html: root.hasCard
        ? Card.introSegments(root.card.intro, root.card.introLinks) + "&nbsp;".repeat(root._padN)
        : ""
    // The block's own height, whole pixels.
    readonly property real textHeight: root.hasCard ? Math.ceil(body.implicitHeight)
                                       : root.style.emptyIntroLines * root.style.bodyLineH
    implicitHeight: root.textHeight

    // The link under the pointer, as an index into card.introLinks (-1: none).
    function _linkAt(p) {
        if (!root.hasCard)
            return -1;
        const n = parseInt(body.linkAt(p.x - body.x, p.y - body.y));
        return isFinite(n) && n >= 0 && n < root.card.introLinks.length ? n : -1;
    }
    readonly property int hoveredLink: root.interactive && hover.hovered ? root._linkAt(hover.point.position) : -1

    property real linkHoverF: root.hoveredLink >= 0 ? 1 : 0
    Behavior on linkHoverF {
        NumberAnimation {
            duration: root.style.linkFadeMs
            easing.type: Easing.OutCubic
        }
    }

    TextMetrics {
        id: nbsp
        font.family: root.fontFamily
        font.pixelSize: root.style.bodySize
        text: " "
    }

    Text {
        id: body
        objectName: "wikiIntroText"
        x: 0
        y: 0
        width: root.width
        visible: root.hasCard
        // No mouse of its own: see the header.
        enabled: false
        text: root._html
        textFormat: Text.StyledText
        wrapMode: Text.Wrap
        lineHeightMode: Text.FixedHeight
        lineHeight: root.style.bodyLineH
        color: Theme.textPrimary
        linkColor: Mix.c(Theme.accent, Theme.accentHover, root.linkHoverF)
        font.family: root.fontFamily
        font.pixelSize: root.style.bodySize
    }

    // the empty words and, when offered, the button under them: one block, centred
    readonly property bool _offerShown: !root.hasCard && root.offerProcess && root.emptyText !== ""
    readonly property real _emptyBlockH: empty.height + (root._offerShown ? root.style.heroGap + processBtn.height : 0)
    Text {
        id: empty
        visible: !root.hasCard && root.emptyText !== ""
        x: 0
        y: Math.round((root.height - root._emptyBlockH) / 2)
        width: root.width
        horizontalAlignment: Text.AlignHCenter
        text: root.emptyText
        wrapMode: Text.Wrap
        color: Theme.textFaint
        font.family: root.fontFamily
        font.pixelSize: root.style.bodySize
    }

    RaisedButton {
        id: processBtn
        objectName: "wikiProcessButton"
        visible: root._offerShown
        x: Math.round((root.width - width) / 2)
        y: empty.y + empty.height + root.style.heroGap
        implicitHeight: root.style.buttonHeight
        text: "Process articles"
        accent: true
        fontFamily: root.fontFamily
        surfaceColor: Theme.surface
        onClicked: root.processRequested()
    }

    // ---- the mark ---------------------------------------------------------------------
    property real markHoverF: markHover.hovered ? 1 : 0
    Behavior on markHoverF {
        NumberAnimation {
            duration: root.style.linkFadeMs
            easing.type: Easing.OutCubic
        }
    }
    Item {
        id: markSlot
        objectName: "wikiMark"
        visible: root.markKind !== "" && root.hasCard
        width: root.style.markBox
        height: root.style.bodyLineH
        x: root.width - width
        y: root.textHeight - height

        Text {
            anchors.centerIn: parent
            text: Glyphs.markChar(root.markKind)
            color: Mix.c(Theme.textFaint, Theme.textMuted, root.markHoverF)
            font.family: Glyphs.FONT_FAMILY
            font.pixelSize: root.style.markSize
        }
        HoverHandler {
            id: markHover
            enabled: root.interactive
        }
    }
    HoverTip {
        anchorItem: markSlot
        overlayItem: root.overlayItem
        show: markHover.hovered && root.interactive && markSlot.visible
        delayMs: root.style.tipDelayMs
        fontFamily: root.fontFamily
        text: root.style.wrapTip(root.markTip)
    }

    // ---- the pointer -----------------------------------------------------------------------
    HoverHandler {
        id: hover
        enabled: root.interactive
        cursorShape: root.hoveredLink >= 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
    }
    TapHandler {
        acceptedModifiers: Qt.NoModifier
        acceptedButtons: Qt.LeftButton
        enabled: root.interactive
        onTapped: eventPoint => {
            const i = root._linkAt(eventPoint.position);
            if (i >= 0)
                root.linkOpened(root.card.introLinks[i]);
        }
    }
    TapHandler {
        acceptedModifiers: Qt.ControlModifier
        acceptedButtons: Qt.LeftButton
        enabled: root.interactive
        onTapped: eventPoint => {
            const i = root._linkAt(eventPoint.position);
            if (i >= 0)
                root.linkFollowed(root.card.introLinks[i]);
        }
    }
}
