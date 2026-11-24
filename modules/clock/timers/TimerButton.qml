import QtQuick

import "../../common/components"
import "../../common/theme"

// The timers card's button: RaisedButton on the card's own ground, in the
// theme's button tokens, whole pixels wide (a width that is a sum of glyph
// advances puts the next label off the pixel grid). Its drop shadow is
// COVERAGE, not paint: an opaque shadow is mixed toward `surfaceColor`, and
// over anything that is not exactly that colour -- a selected alarm row's
// carved inset -- it painted a flat apron that wiped the carve out.
RaisedButton {
    width: Math.ceil(implicitWidth)
    fontFamily: "Audiowide"
    fontPixelSize: 12
    surfaceColor: Theme.listBox
    plateauColor: Theme.buttonPlateau
    plateauHoverColor: Theme.buttonPlateauHover
    bevelColor: Theme.buttonBevel
    shadowColor: Theme.buttonShadow
    accentColor: Theme.accent
    accentHoverColor: Theme.accentHover
    accentBevelColor: Theme.accentBevel
    shadowToAlpha: true
}
