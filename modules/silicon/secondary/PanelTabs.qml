pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix

// =============================================================================
// PanelTabs.qml -- the shell's TabSelector in the panels' one dressing: carved into a card (its
// ground is the card's fill), and with the two things a settings panel needs that the selector does
// not do by itself.
//
//   NO SWIPE. A two-finger swipe across a power setting is not a request to change it, so the
//   selector's own swipe is off and nothing steps it by accident.
//
//   LOCKED. A selector the machine will not take (the energy preference while the governor is
//   performance, the charger's mode while its switch is off) keeps its place and says so: the pill
//   turns from the accent into a plateau of the surface's own, its word into the muted ink, and the
//   track dims a little -- the value stays READABLE, which a plain fade of the whole selector would not
//   leave (the accent's white word on a faded blue). One fraction (`offF`, eased 160 ms) carries all
//   of it; the colours are mixed from Theme tokens, never animated themselves.
//
// The host binds `currentTab` with a Binding element: the selector assigns its own `currentTab` on a
// click, which severs a plain binding.
// =============================================================================
TabSelector {
    id: panelTabs

    property SecondaryStyle look: null
    property bool locked: false
    readonly property real offF: panelTabs._off

    property real _off: panelTabs.locked ? 1 : 0
    Behavior on _off {
        NumberAnimation {
            duration: panelTabs.look ? panelTabs.look.fadeMs : 160
            easing.type: Easing.OutCubic
        }
    }

    enabled: !panelTabs.locked
    opacity: 1 - 0.25 * panelTabs._off
    swipeEnabled: false
    swipeSelfHandled: false
    fontFamily: panelTabs.look ? panelTabs.look.fontFamily : "Inter"
    fontPixelSize: panelTabs.look ? panelTabs.look.figureSize : 11

    trackSurfaceColor: Theme.listBox
    trackBevelColor: Theme.bevel
    trackShadowColor: Theme.border
    trackBackgroundColor: Theme.headerBox
    trackBevelWidth: 1
    pillSurfaceColor: Theme.headerBox
    pillBevelColor: Mix.c(Theme.accentBevel, Theme.buttonBevel, panelTabs._off)
    pillShadowColor: Theme.buttonShadow
    pillBackgroundColor: Mix.c(Theme.accent, Theme.buttonPlateau, panelTabs._off)
    textColor: Theme.textPrimary
    activeTextColor: Mix.c(Theme.textOnAccent, Theme.textMuted, panelTabs._off)
}
