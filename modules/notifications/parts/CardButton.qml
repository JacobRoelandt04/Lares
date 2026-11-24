pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"

// A RaisedButton dressed from Theme tokens for a notification card: it stands
// on the card's fill, and its shadow eases to alpha because the card it sits
// on slides over a well while it is swiped (CLAUDE.md: a raised box over a
// ground that is not fixed). Whole-pixel width so a row of them keeps every
// label on the pixel grid. Its size, corner, label size, shadow and least
// width are the module's NotificationStyle (`style`); each default is the
// value drawn when no style is given.
RaisedButton {
    id: cb

    property NotificationStyle style: null

    width: Math.ceil(implicitWidth)
    implicitHeight: cb.style ? cb.style.actionHeight : 30
    fontPixelSize: cb.style ? cb.style.actionTextSize : 11
    bold: false
    horizontalPadding: cb.style ? cb.style.actionPadX : 10
    minWidth: cb.style ? cb.style.cardButtonMinWidth : 40
    radius: cb.style ? cb.style.actionRadius : 7
    shadowWidth: cb.style ? cb.style.cardButtonShadowWidth : 4
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
