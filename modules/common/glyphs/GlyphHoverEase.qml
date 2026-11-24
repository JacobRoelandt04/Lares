import QtQuick

// =============================================================================
// GlyphHoverEase.qml -- THE ONE HOVER CLOCK of the bar's glyphs: `Behavior on hoverF { GlyphHoverEase {} }`.
//
// Every bar glyph eases its hover fraction (0 -> 1 under the pointer, and the popup-is-ours fraction where a button has one) on
// this animation, so the whole bar answers the pointer alike and one number tunes it (BarHues.hoverMs / hoverEasing). The colour
// itself is never animated: the fraction is, and the host mixes its themed colours by it (Mix.js).
// =============================================================================
NumberAnimation {
    duration: BarHues.hoverMs
    easing.type: BarHues.hoverEasing
}
