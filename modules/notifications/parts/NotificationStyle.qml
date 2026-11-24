pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// NotificationStyle.qml -- every tunable of the notifications module's look
// and motion, in ONE object the owner holds and hands down to the toast and
// the manager (and they to every card, header, reader and fade). The mockup's
// panel writes here; the defaults are the shell's layout numbers (CLAUDE.md
// "Layout numbers": padding 12, card padding 12, container radius 14, list
// row inset 6) and the numbers each part was built and gated with.
//
// What is NOT here, and where it lives instead:
//   the popups' corner radius   the engine's `maxR` (the owner hands it to the
//                               toast's cornerRadius and the manager's
//                               popupRadius: the clip lines must follow the
//                               outline the engine draws, never a second copy)
//   what an image is (avatar     the service's `avatarMax`, and the toasts'
//   or picture), the toasts'    expiry stagger the scheduler's `staggerMs`
//   expiry stagger              (NotificationService, ToastScheduler)
//   what the module DOES        notifications.jsonc (timeouts, toasts, history,
//                               holds, the spot): NotificationConfig
//   SideFade's short ramp       the layout: it runs from the cut to where a
//                               resting row begins (SideCut's `rest`), so in a
//                               straight row it is the padding (`toastPadding`
//                               / `managerPadding`) less `sideFadeInset`,
//                               `sideFadeLeadPx` and `sideFadeRimPx`: 7 px at
//                               12 (the long ramp is here: `sideFadeLength`,
//                               the manager's `listFadeHeight`)
//   the group headers' radius   `cardRadius`: a header is a box of the same list
//
// EVERY DEFAULT IS THE VALUE THE PARTS DRAW WITH when no style is given: a host
// that sets nothing renders pixel for pixel the same. Each part's own no-style
// fallback is these defaults token for token, the mockup's `val`s are these
// defaults, and a property nothing reads is removed.
// =============================================================================
QtObject {
    // ---- type ------------------------------------------------------------------
    property string fontFamily: "Inter"
    // The card: summary, body, the "App · 3 min" line (and its pin glyph), the
    // flood footnote, the action buttons' labels.
    property int summarySize: 12
    property int bodySize: 12
    property int metaSize: 11
    property int footSize: 11
    property int actionTextSize: 11
    // The toast stack's "+N more" foot.
    property int stackFootSize: 11
    // The manager: a group header's title, its "3 · newest" line, its chevron;
    // the popup's title, the do-not-disturb label, the search glyph, the Clear
    // all / Undo label.
    property int headerTitleSize: 14
    property int headerSubtitleSize: 11
    property int headerChevronSize: 14
    property int managerTitleSize: 16
    property int dndLabelSize: 11
    property int searchGlyphSize: 14
    property int headerButtonTextSize: 12

    // ---- the card (toast and manager alike) ------------------------------------
    property real cardRadius: 14
    property real cardPadding: 12
    property int iconSize: 40
    property real iconGap: 10
    // The app's icon on an avatar's corner.
    property int badgeSize: 18
    // A shell glyph's pixel size as a share of iconSize (1.0: a Material
    // glyph's ink, 20/24 of its em, fills the column the way a theme icon does).
    property real glyphScale: 1.0
    property int maxLines: 3
    property real idleMarkPx: 12
    // The card's carve (a container's: inset 3, bevel 1 -- CLAUDE.md Material).
    property real cardBevelWidth: 1
    property real cardShadowWidth: 3
    // The group colour in the carve (ShadowBox's progress tint): its depth,
    // strength and falloff at rest (the idle sliver) and while a toast counts
    // down, the feather of its edge, and the countdown fraction by which the
    // resting shape has fully given way to the running one. The system update
    // header's look (ShadowBox.qml "Idle and active shapes"). A depth under the
    // card's own carve is drawn at the carve (the tint never makes it
    // shallower): hosts pass max(cardShadowWidth, shade...Width).
    property real shadeActiveWidth: 7
    property real shadeIdleWidth: 7.5
    property real shadeFeatherPx: 12
    property real shadeActiveEdgeAlpha: 1.0
    property real shadeIdleEdgeAlpha: 0.55
    property real shadeActiveFalloff: 1.0
    property real shadeIdleFalloff: 0.9
    property real shadeBlendEnd: 0.32
    // Inside the card: the gap between the text column's lines, the summary to
    // the "App · 3 min" block and between its items, the app name's cap, the
    // progress rail, the action buttons (height, gap, how many before "...",
    // corner, side padding, the row's padding above and below), the reply
    // field, the picture band's corner and the body's expand chevron.
    property real lineGap: 4
    property real metaGap: 8
    property real metaItemGap: 4
    property real appNameMaxWidth: 110
    property real progressHeight: 6
    property real actionHeight: 30
    property real actionGap: 6
    property int maxInlineActions: 3
    property real actionRadius: 7
    property real actionPadX: 10
    property real actionRowPadY: 2
    // An action button's drop shadow (it stands proud of the card) and its
    // least width.
    property real cardButtonShadowWidth: 4
    property real cardButtonMinWidth: 40
    property real replyFieldHeight: 28
    property real pictureRadius: 8
    // A picture band's least height (its greatest is `pictureMaxHeight`, after it): between the two it
    // follows the picture's aspect ratio at the card's width; a very wide picture is cropped at its middle to
    // the least, a tall one to the greatest.
    property real pictureMinHeight: 72
    // ... and its greatest: a taller picture is cropped at its middle. 160: a 16:9 screenshot at the manager's width fits whole, and the
    // card stays a notification, not a viewer.
    property real pictureMaxHeight: 160
    property real expandChevronSize: 11
    property real expandChevronStroke: 1.5
    // The countdown drain moves in steps of this many WHOLE device px of the shade's boundary (see ToastEntry): 1 is the gradient
    // advancing a pixel at a time; a toast so short that a pixel falls due faster than the timer's 16 ms floor takes the fewest whole
    // pixels the floor allows. (Round 4 and before: 4, counted against the card's width, i.e. 4.27 px steps, ~14 a second: choppy.)
    property real drainStepPx: 1
    // The host's zoom (a mockup stage, a scaled bar) times the screen's scale:
    // a drain step is a DEVICE px, icons are rendered at the size they are seen
    // at. The owner binds it; not a panel value.
    property real renderScale: 1

    // ---- the toast stack (theNotification) -------------------------------------
    property real toastWidth: 360
    property real toastPadding: 12
    property real toastGap: 6
    // The rows' clip above and below the cards (a carved card's bevel).
    property real toastRowSlack: 2
    property int enterMs: 260
    property int presenceMs: 160
    // The "+N more" foot's hover fade (faint to the accent).
    property int footHoverMs: 120

    // ---- the manager (thePopup) ------------------------------------------------
    property real managerWidth: 420
    property real maxListHeight: 560
    property real managerPadding: 12
    // A header's margin above and below its box: 12 between two groups, 6
    // from a header to its first card.
    property real sectionGap: 6
    // Under every card: 6 between two cards of a group.
    property real rowGap: 6
    // Between the do-not-disturb toggle and Clear all.
    property real buttonGap: 12
    // The title row: the words the title takes, the Clear all / Undo button's
    // height, the do-not-disturb label's gap to its toggle, the title's gap to
    // that label, and the search glyph's gap to the query. The label's gap is
    // to the toggle's BOX, which is its groove (GrooveToggle has no slack): 10
    // keeps the label's ink 6 px from the toggle's.
    property string managerTitle: "Notifications"
    property string emptyTitle: "No notifications"
    property real headerButtonHeight: 30
    property real dndLabelGap: 10
    property real titleGap: 12
    property real searchGlyphGap: 6
    // A group header's box padding (ListSectionHeader's 11 x 8; its radius is
    // `cardRadius`).
    property real headerPadX: 11
    property real headerPadY: 8
    // The list: its top and bottom scroll fades, and one wheel notch in px
    // (ScrollDressing: scrollSpeed = listScrollStep / 120).
    property real listFadeHeight: 34
    property real listScrollStep: 120
    // The keyboard's highlight ring round a card: its stroke, how far outside
    // the card, its strength and its fade.
    property real highlightWidth: 1.5
    property real highlightInset: 2
    property real highlightAlpha: 0.8
    property int highlightMs: 120
    property int rowAnimMs: 240
    property int staggerMs: 55
    // Clear all coming and going (presence and width, one clock).
    property int buttonMs: 260
    // The list follows a group opened at its foot (list_animation.md).
    property bool followOpen: true
    // Still frames before the content stops being live (the engine follows
    // the content frame by frame while it is).
    property int liveSettleFrames: 2
    // The pin flight (RowFlight).
    property int flightLiftMs: 160
    property int flightTravelMs: 340
    property int flightLandMs: 160
    property real flightLiftScale: 1.03
    property int flightPreMoveDelayMs: 100
    property int flightPreDropDelayMs: 100
    // The lifted clone's shadow: how far its rect reaches past the clone at
    // the sides, and its blur. 1 / 4 fits inside the manager's 12 px
    // padding at liftScale 1.03 on its 396 px rows (side 11, foot 7, head 5;
    // the rule is 1.03 * spread + blur <= 6, the row's own lift
    // growth being the other 5.94 px). RowFlight's own 10 / 24 reaches 41 px.
    property real flightShadowSpread: 1
    property real flightShadowBlur: 4

    // ---- the bell (NotificationsBarButton) ------------------------------------
    // Its glyph and its padding along and across the bar (no hover plate, no dot:
    // the bar's one glyph style, the unread colour on the glyph itself, the hover
    // on the bar's one clock, BarHues).
    property real bellGlyphSize: 16
    property real bellPadX: 8
    property real bellPadY: 4

    // ---- the swipe (every card: toasts, manager rows, group headers) -----------
    // SwipeVerbCard
    property real swipeCommitFraction: 0.4
    property real swipeFadeFrom: 0.45
    property real swipeMaxFraction: 0.8
    property int swipeFlyMs: 260
    property int swipeSpringMs: 260
    property int swipeSwingMs: 120
    property real swipeFlingPxPerS: 900
    property real swipeDragThreshold: 6
    property real swipeGlyphSize: 20
    property real swipeGlyphInset: 12
    property real swipeWellShadowWidth: 4
    property real swipeWellBevelWidth: 1
    // How far a card with no verb that way gives before it springs back.
    property real swipeBlockedGivePx: 24
    // SwipeVerbReader (two fingers)
    property real swipeUnits: 900
    property real swipeFlingUnitsPerS: 2600
    property real swipePullThrough: 2.0
    property int swipeIdleMs: 6000
    property int swipeMouseIdleMs: 400
    property real swipeSign: 1
    // SideFade (the rows' side clip and its fade)
    property real sideFadeInset: 2
    property real sideFadeRimPx: 2
    property real sideFadeLeadPx: 1
    property real sideFadeCornerMargin: 1
    // The toast stack's long ramp (SideFade.fadeLength); the manager's is its
    // list's scroll fade, `listFadeHeight`.
    property real sideFadeLength: 34

    // ---- the group colours -----------------------------------------------------
    // One palette for the toast and the manager: a host overrides a group's
    // colour here, once, and per theme (`criticalLight` / `criticalDark` ...).
    // Its defaults are bindings to Theme tokens, so a theme switch keeps
    // working. The mockup's panel writes these properties, a light and a dark
    // row per group: "@<token>" binds one to that token, a hex overrides that
    // group in that mode alone, Reset puts the token's binding back
    // (GroupPalette).
    property GroupPalette groups: GroupPalette {}
}
