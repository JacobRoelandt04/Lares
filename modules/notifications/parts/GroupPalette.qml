pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components/Mix.js" as Mix
import "../../common/theme"

// The four groups' colours: Critical = error, System = the cyan category
// token, Normal = accent, Low = faint -- and, per theme, each group's
// colour is its own in the light and in the dark theme:
// `criticalLight`, `criticalDark`, ... Every one is an overridable property
// whose default is a BINDING to its Theme token, so an untouched palette is
// exactly the token in whichever mode is on screen. A host overrides ONE
// mode's colour and the other keeps following its token; bind an override
// to a token too (a literal keeps its hex through a switch -- which is what
// an override means, but not what a default does).
//
// The mockup's panel writes these properties (its `groupColors` list, a
// light and a dark row per group): "@<token>" binds one to that token, a hex
// overrides that group in that mode alone, Reset puts the token's binding
// back (MockupRegistry._assign). Resolved where they are used, never put in
// a model (CLAUDE.md: a Repeater model may never hold a themed colour).
//
// WHICH MODE, AND HOW IT SWITCHES. The theme has one clock and the palette
// rides it; there is no Behavior here.
//  - A host with a crossfade picture (Theme.crossfading) writes the tokens
//    ONCE behind a still of the old frame. The palette answers for the mode
//    the tokens are in, held in `_dark` (read at creation and on every
//    `settled`, as WeatherBackdrop holds its dark half): Theme.mode flips at
//    the ask, before the picture is taken, and reading it live would paint
//    the new mode's override into the picture that must be the old frame.
//  - Without one, the tokens glide from the ask to the fade's end on
//    Theme.fadeProgress. A group's colour then glides on the same fraction
//    between the override of the mode the tokens left and the override of the
//    mode they are heading to (Mix.js): a token-bound default is the same
//    lerping token on both sides, so it is not eased twice, and a hex
//    override meets the other mode's colour on the theme's own curve instead
//    of jumping at the end.
QtObject {
    id: palette

    property color criticalLight: Theme.error
    property color criticalDark: Theme.error
    property color systemLight: Theme.catMultilib
    property color systemDark: Theme.catMultilib
    property color normalLight: Theme.accent
    property color normalDark: Theme.accent
    property color lowLight: Theme.textFaint
    property color lowDark: Theme.textFaint

    // The mode the tokens are in, held (see above).
    property bool _dark: false
    readonly property Connections _settled: Connections {
        target: Theme
        function onSettled() {
            palette._dark = Theme.mode === "dark";
        }
    }
    Component.onCompleted: palette._dark = Theme.mode === "dark"    // held from here on, not bound

    function _in(group: string, dark: bool): color {
        switch (group) {
        case "critical":
            return dark ? palette.criticalDark : palette.criticalLight;
        case "system":
            return dark ? palette.systemDark : palette.systemLight;
        case "low":
            return dark ? palette.lowDark : palette.lowLight;
        default:
            return dark ? palette.normalDark : palette.normalLight;
        }
    }
    function color(group: string): color {
        const rest = palette._dark;
        const heading = Theme.mode === "dark";
        if (Theme.crossfading || heading === rest)
            return palette._in(group, rest);
        return Mix.c(palette._in(group, rest), palette._in(group, heading), Theme.fadeProgress);
    }
    function title(group: string): string {
        switch (group) {
        case "critical":
            return "Critical";
        case "system":
            return "System";
        case "low":
            return "Low";
        default:
            return "Normal";
        }
    }
}
