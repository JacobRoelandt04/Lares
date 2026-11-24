import QtQuick

import "../../common/theme"
import "../../common/components"

// PanoButton.qml -- a RaisedButton in the shell's tokens (RaisedButton's own defaults are the light theme's hexes).
RaisedButton {
    id: btn

    property color ground: Theme.surface

    radius: 8
    fontPixelSize: 12
    bold: true
    horizontalPadding: 12
    minWidth: 52
    shadowWidth: 4
    surfaceColor: btn.ground
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
    implicitHeight: 28
}
