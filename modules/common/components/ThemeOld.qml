pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "Mix.js" as Mix

// =============================================================================
// ThemeOld.qml -- the WHOLE palette as it stood when a theme switch was asked, held for the length of the fade.
//
//     ThemeOld { id: old; enabled: island.live }     // old.map["surface"], old.dark: null / false outside a fade
//
// FadeColor holds one token's old value and mixes it; this holds ALL of them (and the mode), for an island that
// draws a second copy of itself in the old palette and fades that copy out over the live one (silicon's board:
// its shaders branch on dark and light, so their colours cannot be mixed -- two scenes are). The map is taken at
// Theme.aboutToSwitch, when the tokens are still the old ones (they are written at the commit), and is null from the end of
// the fade (Theme.crossfading false) until the next ask.
//
// THE MODE has already changed at the ask (Theme.setMode writes it before it asks), so the old mode is the one
// the last change of `mode` replaced -- unless this switch did not change it (a pair of themes of one mode).
//
// A switch asked in the middle of a fade starts from what was on screen: the map of the fade before, mixed
// toward the tokens by the progress it had reached (kept at its reset, as FadeColor does), and the mode of whichever end of that
// fade was the larger share.
// =============================================================================
QtObject {
    id: old

    // Off: nothing is taken at an ask (a host that is not going to use it pays nothing).
    property bool enabled: true

    readonly property var map: old._map
    readonly property bool dark: old._dark

    property var _map: null
    property bool _dark: false
    property real _prev: 0
    property real _peak: 0
    // Plain values, set once: a binding to Theme.mode would follow it BEFORE the handler below ran and `_before` would be the new mode.
    property string _cur: ""
    property string _before: ""
    property bool _modeMoved: false
    Component.onCompleted: {
        old._cur = Theme.mode;
        old._before = Theme.mode;
    }

    property Connections _theme: Connections {
        target: Theme
        function onModeChanged() {
            old._before = old._cur;
            old._cur = Theme.mode;
            old._modeMoved = true;
        }
        function onFadeProgressChanged() {
            const p = Theme.fadeProgress;
            if (p < old._prev)
                old._peak = old._prev;
            old._prev = p;
        }
        function onAboutToSwitch() {
            const wasMode = old._modeMoved ? old._before : old._cur;
            old._modeMoved = false;
            if (!old.enabled)
                return;
            const names = Theme.tokenNames;
            const prev = old._map;
            const peak = old._peak;
            const m = {};
            for (let i = 0; i < names.length; i++) {
                const now = Theme.tokenOf(names[i]);
                m[names[i]] = prev ? Mix.c(prev[names[i]], now, peak) : now;
            }
            old._dark = prev ? (peak < 0.5 ? old._dark : wasMode === "dark") : wasMode === "dark";
            old._peak = 0;
            old._map = m;
        }
        function onCrossfadingChanged() {
            if (!Theme.crossfading) {
                old._map = null;
                old._peak = 0;
            }
        }
    }
}
