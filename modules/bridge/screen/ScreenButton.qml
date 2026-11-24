pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"

// =============================================================================
// ScreenButton.qml -- the phone screen's raised button: RaisedButton in the theme's button tokens, standing on the screen's
// ground (`surfaceColor`), whole pixels wide, its drop shadow coverage rather than paint (so it can stand on a carved row
// without wiping the carve). The same dressing the clock's timers card gives it (TimerButton); the bridge's screen has its
// own because the ground it stands on is the display's, not a card's.
//
//   accent   the default answer (the accent plateau)
//   enabled  false: faint label, no press -- the host shows the reason beside it, never a dead button alone
// =============================================================================
RaisedButton {
    width: Math.ceil(implicitWidth)
    surfaceColor: Theme.listBox
    plateauColor: Theme.buttonPlateau
    plateauHoverColor: Theme.buttonPlateauHover
    bevelColor: Theme.buttonBevel
    shadowColor: Theme.buttonShadow
    accentColor: Theme.accent
    accentHoverColor: Theme.accentHover
    accentBevelColor: Theme.accentBevel
    shadowToAlpha: true
    radius: 9
}
