pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"

// A RaisedButton dressed from Theme tokens for a preset card: it stands on the card's fill, its shadow eases to alpha (the card floats over
// the popup's ground). `danger`: the accent plate in the error tone (Load's "Close N windows?"). Whole-pixel width, the label on the grid.
RaisedButton {
    id: pb

    property bool danger: false

    radius: 8
    fontPixelSize: 12
    bold: false
    horizontalPadding: 10
    minWidth: 40
    shadowWidth: 4
    surfaceColor: Theme.surface
    plateauColor: Theme.buttonPlateau
    plateauHoverColor: Theme.buttonPlateauHover
    bevelColor: Theme.buttonBevel
    shadowColor: Theme.buttonShadow
    accentColor: pb.danger ? Theme.error : Theme.accent
    accentHoverColor: pb.danger ? Theme.errorStrong : Theme.accentHover
    accentBevelColor: pb.danger ? Theme.errorTint : Theme.accentBevel
    shadowToAlpha: true
}
