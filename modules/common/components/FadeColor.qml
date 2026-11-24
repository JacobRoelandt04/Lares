pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "Mix.js" as Mix

// =============================================================================
// FadeColor.qml -- a theme token that goes from the OLD palette to the new on the
// crossfade's own clock, for the length of the fade, in an item that stays live.
//
//     FadeColor { id: sky; token: "surface" }       // ... skyColor: sky.value
//
// WHY. A theme switch writes every token ONCE behind a still picture of the frame
// before and fades that picture out (Theme.fadeProgress, one clock). A thing that
// is cut out of the picture to keep moving (ThemeIsland) has to bring its own old
// colours to meet the new, or it would snap to the new palette at the commit while
// everything round it fades. This is that: the colour the picture would have shown
// of it, `mix(old, new, fadeProgress)`.
//
// THE OLD COLOUR is the token as it stood when the switch was ASKED (Theme.aboutToSwitch:
// the tokens are written later, at the commit). A switch that lands in the middle of a
// fade starts from what was on screen, not from the token (which is the previous
// switch's target): the progress the previous fade had reached is kept at its reset.
//
// ONE CLOCK, NO BEHAVIOR. The value is a function of Theme.fadeProgress and nothing
// else; outside a crossfade it IS Theme.tokenOf(token) (so a lerped switch with no
// picture host, and every frame at rest, are exactly the token's own binding).
// =============================================================================
QtObject {
    id: fc

    property string token: "surface"
    // Off: the token itself, always. A colour mixes only where the thing it paints is LIVE through a hole in the picture (its island is armed):
    // anywhere else the picture is the fade, and a colour that fades too would lag it.
    property bool active: true
    // THE LIVE CURTAIN (ThemeWipe): the item this colour paints. Under the curtain's line the whole screen does not fade: this colour goes while the line
    // crosses that item, not over the whole reveal. Unset, or with no line running: Theme.fadeProgress, the plain fade.
    property Item place: null
    function _clock(): real {
        const p = Theme.fadeProgress;
        const w = fc.place ? Theme.wipeFor(fc.place) : null;
        if (!w)
            return p;
        const a = fc.place.mapToItem(null, 0, 0);
        const b = fc.place.mapToItem(null, fc.place.width, fc.place.height);
        return w.localFade(Math.min(a.x, b.x), Math.min(a.y, b.y), Math.max(a.x, b.x), Math.max(a.y, b.y));
    }
    readonly property color value: fc.active && fc._haveOld && Theme.crossfading
        ? Mix.c(fc._old, Theme.tokenOf(fc.token), fc._clock())
        : Theme.tokenOf(fc.token)

    property color _old: "transparent"
    property bool _haveOld: false
    // The progress the fade last reached before a new ask reset it.
    property real _prev: 0
    property real _peak: 0

    property Connections _theme: Connections {
        target: Theme
        function onFadeProgressChanged() {
            const p = Theme.fadeProgress;
            if (p < fc._prev)
                fc._peak = fc._prev;
            fc._prev = p;
        }
        function onAboutToSwitch() {
            const now = Theme.tokenOf(fc.token);
            fc._old = fc._haveOld ? Mix.c(fc._old, now, fc._peak) : now;
            fc._peak = 0;
            fc._haveOld = true;
        }
        function onCrossfadingChanged() {
            if (!Theme.crossfading) {
                fc._haveOld = false;
                fc._peak = 0;
            }
        }
    }
}
