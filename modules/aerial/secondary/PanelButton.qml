import QtQuick

import "../../common/theme"
import "../../common/components"

// =============================================================================
// PanelButton.qml -- the raised button of the aerial panels: 28 px high, 12 px of padding. It stands on a card by default (`ground`
// is the card's fill, which the button's drop shadow and rim run into -- CLAUDE.md: a ShadowBox's surfaceColor is the GROUND it
// sits on); `accent` is the default answer.
// =============================================================================
RaisedButton {
    property PanelStyle look: null
    property color ground: Theme.listBox

    height: 28
    minWidth: 0
    horizontalPadding: 12
    fontFamily: look ? look.fontFamily : "Inter"
    fontPixelSize: (look ? look.figureSize : 11) + 1
    surfaceColor: ground
    plateauColor: Theme.buttonPlateau
    plateauHoverColor: Theme.buttonPlateauHover
    bevelColor: Theme.buttonBevel
    shadowColor: Theme.buttonShadow
    accentColor: Theme.accent
    accentHoverColor: Theme.accentHover
    accentBevelColor: Theme.accentBevel
    accentTextColor: Theme.textOnAccent
    textColor: Theme.textPrimary
    faintTextColor: Theme.textFaint
}
