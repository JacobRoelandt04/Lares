import QtQuick

import "../../common/theme"
import "../../common/components"

// =============================================================================
// PanelTabs.qml -- the pages of ONE panel as the shell's TabSelector (the user's "no tabs" is about the main popup; a detail panel's
// pages are fine): carved on the popup's surface, the pill an accent plateau. Swipes are off (the panel's own scroller owns the wheel).
// =============================================================================
TabSelector {
    id: tabsel

    property PanelStyle look: null

    swipeEnabled: false
    swipeSelfHandled: false
    fontFamily: tabsel.look ? tabsel.look.fontFamily : "Inter"
    fontPixelSize: tabsel.look ? tabsel.look.figureSize : 11
    slotPaddingAlong: 8

    trackSurfaceColor: Theme.surface
    trackBevelColor: Theme.bevel
    trackShadowColor: Theme.border
    trackBackgroundColor: Theme.headerBox
    trackBevelWidth: 1
    pillSurfaceColor: Theme.headerBox
    pillBevelColor: Theme.accentBevel
    pillShadowColor: Theme.buttonShadow
    pillBackgroundColor: Theme.accent
    textColor: Theme.textPrimary
    activeTextColor: Theme.textOnAccent
    trackRadiusOverride: 10
}
