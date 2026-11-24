import QtQuick

// =============================================================================
// WikiStyle.qml -- every number of the wiki card's look and motion, in ONE
// object the popup holds and hands down to its parts (WikiHero, WikiCarousel,
// WikiTitleRow, WikiIntro, WikiTrail, WikiSkeleton); the veils' numbers are an
// object of their own inside it (`veil`: WikiVeilStyle). The mockup's panel writes
// here. What is NOT here: the popup's own `cardWidth` / `padding` / `radius`,
// the carousel's `autoAdvanceMs` / `slideMs` and the `dwellMs` (WikiPopup's
// contract), and every colour (a colour is a Theme token; the parts resolve
// them, and the category hue is `Theme[card.hueToken]`).
//
// The defaults are CLAUDE.md's layout numbers: popup padding 12 (the popup's),
// container radius 14 (the hero well takes it), figures 11, body 12, title 16.
// Every length is a whole pixel unless a comment says why.
// =============================================================================
QtObject {
    // ---- the column ------------------------------------------------------------
    // The hero's shape: `heroRatioW : heroRatioH` of the inner width, floored to
    // a whole pixel (424 -> 238).
    property real heroRatioW: 16
    property real heroRatioH: 9
    // Under the hero, and between the title row and the intro.
    property real heroGap: 12
    property real titleGap: 8
    // What an entry-less tab reserves for its intro (the skeleton's lines and
    // the empty line's slot), so a tab with no card sizes like a real one.
    property int emptyIntroLines: 6

    // ---- type ---------------------------------------------------------------------
    property int titleSize: 16
    property real titleLineH: 20
    // The paragraph is read, not scanned: one size above the shell's body (12), the user's call (2026-11-08); the popup keeps its
    // width and grows in height. The line pitch keeps ~1.4 x the size, in whole pixels (a fractional pitch rasters lines at y.5).
    property int bodySize: 13
    property real bodyLineH: 18
    property int chipTextSize: 11

    // ---- the title row --------------------------------------------------------------
    // The source logo is the link; the carve is weak below ~24 px at 1x.
    property real logoSize: 28
    property real logoGap: 12
    property int glyphSize: 18
    property real glyphBox: 22
    property int badgeSize: 16
    property real badgeBox: 20
    property real iconGap: 6
    // The mark (sparkle / pencil) at the intro's foot, and the room the last line
    // keeps for it (non-breaking spaces, so it never sits on a word).
    property int markSize: 12
    property real markBox: 16
    // A tip is one bubble that HoverTip does not wrap: the words are broken here,
    // at this many characters (about 370 px at the tip's size).
    property int tipWrapChars: 72
    // How long the pointer rests on a mark, a glyph or a button before its tip.
    property int tipDelayMs: 350
    // A tip over a picture is nearly opaque: the shared tip's fill lets what is
    // under it show through, which on a photograph is a reading problem.
    property real pictureTipOpacity: 0.96
    // The image credit takes longer: it is read once, not every visit.
    property int creditDelayMs: 900
    // The intro's links: the hover fade of their colour.
    property int linkFadeMs: 120

    // The entry's presence: it fades out while another is fetched, and in when it lands.
    property int presenceMs: 160

    // ---- the hero well -----------------------------------------------------------------
    // Carved like a container (3 / 1); a photo is sunk into it, so the inset
    // reads over the picture.
    property real wellBevel: 1
    property real wellShadow: 3
    property real wellFalloff: 1
    // How opaque the inset shadow is at the very edge over a picture.
    property real wellEdgeAlpha: 0.9
    // A subject's carved logo, as a fraction of the well's height.
    property real reliefFraction: 0.40
    // The veils: what an article with no photograph shows (WikiVeil), every number of them.
    property WikiVeilStyle veil: WikiVeilStyle {}

    // ---- the button band (its buttons fade in while the pointer is over the hero) -----
    property int bandFadeMs: 160
    property real bandHeight: 52
    property real buttonWidth: 30
    property real buttonHeight: 26
    property real buttonGap: 6
    property real buttonMargin: 10
    property real buttonRadius: 8
    property real buttonShadow: 4
    property real buttonBevel: 1.5
    property int buttonGlyphSize: 12
    property int latchMs: 160

    // ---- the carousel dots ---------------------------------------------------------------
    property real dotSize: 6
    property real dotPitch: 12
    // The faint pill behind them at rest, and how strong the dots are there.
    property real dotPillPad: 7
    property real dotPillAlpha: 0.55
    property real dotRestOpacity: 0.75
    // Each dot's clickable box across (along it is the pitch).
    property real dotHit: 20

    // ---- the back chip (a rabbit hole's way home) -------------------------------------------
    property real chipHeight: 26
    property real chipMargin: 10
    property real chipPad: 10
    property real chipGap: 6
    property real chipMaxWidth: 240
    property real chipRadius: 8
    property int chipFadeMs: 160

    // ---- the skeleton ------------------------------------------------------------------------
    property bool skeletonPulse: true
    property real skeletonBarHeight: 9
    property real skeletonTitleBarHeight: 10
    property real skeletonBarGap: 6
    property real skeletonHeroInset: 8
    property real skeletonHeroRadius: 8

    // `text` broken at spaces into lines of at most `tipWrapChars` characters.
    function wrapTip(text) {
        const words = String(text || "").split(" ");
        let out = "", line = "";
        for (let i = 0; i < words.length; i++) {
            if (line !== "" && line.length + 1 + words[i].length > tipWrapChars) {
                out += line + "\n";
                line = words[i];
            } else {
                line = line === "" ? words[i] : line + " " + words[i];
            }
        }
        return out + line;
    }
}
