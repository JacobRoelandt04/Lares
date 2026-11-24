pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"

// =============================================================================
// ChoiceBar.qml -- a one-of-few choice as the shell's TabSelector (carved track, a raised pill that stands in it), the aerial panels' look in the
// popup's tokens. The host holds the fact: a click asks (`chosen(key)`), the pill follows `current`. A `Binding` carries `current` in (the selector
// assigns its own `currentTab`, which would sever a plain binding). options: [{ key, label }].
// =============================================================================
TabSelector {
    id: bar

    property var options: []
    property string current: ""
    property real fontSize: 11

    signal chosen(string key)

    tabs: bar.options.map(o => ({ id: o.key, label: o.label }))
    swipeEnabled: false
    swipeSelfHandled: false
    fontPixelSize: bar.fontSize
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

    Binding {
        target: bar
        property: "currentTab"
        value: bar.current
    }
    onTabChanged: id => bar.chosen(id)
}
