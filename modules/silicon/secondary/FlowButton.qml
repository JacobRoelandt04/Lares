import QtQuick

import "../../common/theme"
import "../../common/components"

// =============================================================================
// FlowButton.qml -- the raised button of the dialogs that are secondaries (MuxPanel, ConfirmPanel): 28 px
// high, 12 px of padding, standing on the popup's own surface (the dialogs have no card of their own, so
// the ground is `Theme.surface`, as the tuning panel's "Reset to profile" stands). `accent` is the default answer.
// =============================================================================
RaisedButton {
    height: 28
    minWidth: 0
    horizontalPadding: 12
    surfaceColor: Theme.surface
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
