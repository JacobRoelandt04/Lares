pragma ComponentBehavior: Bound

import QtQuick

import "../common/system"
import "../common/theme"
import "../common/components"
import "WikiGlyphs.js" as Glyphs

// =============================================================================
// WikiTitleRow.qml -- what the entry is called, what kind of thing it is, and
// the way to its source.
//
//   Title, up to two lines (16 bold, elided)     [family glyph] [package] [logo]
//
//   * the family glyph is a Symbols Nerd Font mark in the family's hue
//     (`Theme[card.hueToken]`, resolved HERE: a card carries facts, never a
//     colour); its tip is `service.whyText(card)` -- "Physics . you open 40 % .
//     picked 1 in 9";
//   * the package glyph shows only for an installed Deepen entry
//     (`card.installed === true`), tip "Installed: <package>";
//   * the source logo IS the link (LogoLink): a plain click opens the source in
//     the browser (`service.openSource`); its tip says where.
//
// SIZE. `naturalHeight` is the taller of the logo and the title as laid out
// (one line or two); the host takes the MAX over both tabs' rows and hands it
// back as this item's `height`, so the row is the same height on either tab
// and a swipe moves nothing. Title and icons are centred in that slot (a blank
// slot centres what remains). Everything is placed on whole pixels.
// =============================================================================
Item {
    id: root

    property var card: null
    property var service: null
    property string tab: ""
    property WikiStyle style: WikiStyle {}
    property string fontFamily: "Inter"
    property Item overlayItem: null
    property bool interactive: true

    // The logo was clicked and the source opened in the browser (`service.openSource` has been called).
    signal sourceOpened

    readonly property bool hasCard: root.card !== null && root.card !== undefined
    readonly property bool _installed: root.hasCard && root.card.installed === true
    readonly property string _logo: root.hasCard && root.card.source ? (root.card.source.logo || "") : ""
    readonly property real naturalHeight: Math.max(root.style.logoSize, Math.ceil(title.implicitHeight))
    implicitHeight: root.naturalHeight

    // The icons, from the right edge inwards; the title takes what is left.
    readonly property real _logoX: root.width - root.style.logoSize
    readonly property real _badgeX: (root._logo !== "" ? root._logoX - root.style.iconGap : root.width) - root.style.badgeBox
    readonly property real _glyphX: (root._installed ? root._badgeX : (root._logo !== "" ? root._logoX : root.width))
                                    - (root._installed || root._logo !== "" ? root.style.iconGap : 0) - root.style.glyphBox
    readonly property real _titleW: Math.max(0, Math.floor(root._glyphX - root.style.logoGap))

    function _hue(token) {
        const c = Theme[token];
        return c !== undefined ? c : Theme.textMuted;
    }

    Text {
        id: title
        objectName: "wikiTitleText"
        x: 0
        y: Math.round((root.height - Math.ceil(title.implicitHeight)) / 2)
        width: root._titleW
        visible: root.hasCard
        text: root.hasCard ? root.card.title : ""
        maximumLineCount: 2
        wrapMode: Text.Wrap
        elide: Text.ElideRight
        lineHeightMode: Text.FixedHeight
        lineHeight: root.style.titleLineH
        color: Theme.textPrimary
        font.family: root.fontFamily
        font.pixelSize: root.style.titleSize
        font.bold: true
    }

    // ---- the family glyph, its hue and its "why" -------------------------------------------
    Text {
        id: familyGlyph
        objectName: "wikiFamilyGlyph"
        visible: root.hasCard && root.card.glyph !== ""
        x: Math.round(root._glyphX)
        y: Math.round((root.height - height) / 2)
        width: root.style.glyphBox
        height: root.style.glyphBox
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: root.hasCard ? root.card.glyph : ""
        color: root.hasCard ? root._hue(root.card.hueToken) : Theme.textMuted
        font.family: Glyphs.FONT_FAMILY
        font.pixelSize: root.style.glyphSize

        HoverHandler {
            id: familyHover
            enabled: root.interactive
        }
    }
    HoverTip {
        anchorItem: familyGlyph
        overlayItem: root.overlayItem
        show: familyHover.hovered && root.interactive && familyGlyph.visible
        delayMs: root.style.tipDelayMs
        fontFamily: root.fontFamily
        text: root.service && root.hasCard ? root.style.wrapTip(root.service.whyText(root.card)) : ""
    }

    // ---- installed ------------------------------------------------------------------------------
    Text {
        id: badge
        objectName: "wikiBadge"
        visible: root._installed
        x: Math.round(root._badgeX)
        y: Math.round((root.height - height) / 2)
        width: root.style.badgeBox
        height: root.style.badgeBox
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: Glyphs.markChar("installed")
        color: Theme.ok
        font.family: Glyphs.FONT_FAMILY
        font.pixelSize: root.style.badgeSize

        HoverHandler {
            id: badgeHover
            enabled: root.interactive
        }
    }
    HoverTip {
        anchorItem: badge
        overlayItem: root.overlayItem
        show: badgeHover.hovered && root.interactive && badge.visible
        delayMs: root.style.tipDelayMs
        fontFamily: root.fontFamily
        text: root.hasCard ? "Installed: " + (root.card.installedPkg || root.card.title) : ""
    }

    // ---- the source: the logo is the link -----------------------------------------------------------
    LogoLink {
        id: logoLink
        objectName: "wikiLogoLink"
        visible: root._logo !== ""
        x: Math.round(root._logoX)
        y: Math.round((root.height - root.style.logoSize) / 2)
        logoSize: root.style.logoSize
        // Cut into the bare popup surface, not into a card.
        surfaceColor: Theme.surface
        enabled: root.interactive
        source: root._logo !== "" ? "file://" + RepoRoot.dir + "/" + root._logo : ""
        onClicked: {
            if (root.service && root.hasCard) {
                root.service.openSource(root.tab, root.card.id);
                root.sourceOpened();
            }
        }
    }
    HoverTip {
        anchorItem: logoLink
        overlayItem: root.overlayItem
        show: logoLink.hovered && logoLink.visible
        delayMs: root.style.tipDelayMs
        fontFamily: root.fontFamily
        text: root.hasCard ? "Open on " + root.card.source.name : ""
    }
}
