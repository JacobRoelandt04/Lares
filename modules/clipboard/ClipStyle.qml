import QtQuick

// =============================================================================
// ClipStyle.qml -- every number of the clipboard shelf, in one object.
//
// The popup owns one and hands it to the shelf (`ClipShelf.style`); its panel
// writes it through MockupRegistry. Defaults are the shelf's own (STAGE3.md);
// the sizes land on their panel steps (whole pixels, whole milliseconds).
// =============================================================================
QtObject {
    // The popup is this many cards wide (cards and the gaps between them, then the popup's own padding),
    // and narrower only where the bar leaves less room.
    property int shelfCards: 4
    // One card.
    property int cardWidth: 184
    property int cardHeight: 148
    // Between cards.
    property int cardGap: 10
    // A card's corners.
    property int cardRadius: 10
    // Inside a card.
    property int cardPadding: 12
    // Lines a text face / a code face shows.
    property int textLines: 5
    property int codeLines: 6
    // "lift": the focused card stands proud (raised ShadowBox).
    // "well": the launcher's gliding carved well under it.
    property string focusStyle: "lift"
    // How far "lift" raises the focused card.
    property int liftPx: 4
    // The focus mark's glide / lift.
    property int focusMs: 160
    // A new copy's slide in while the popup is open.
    property int insertMs: 260
    // Presence fades.
    property int presenceMs: 160
    // The digit (Alt held) and pick-order (marks) badges.
    property int badgeSize: 18
    // A sealed card's countdown ring.
    property int ringSize: 22
    // "crop" or "fit" for image thumbs.
    property string thumbFit: "crop"
}
