import QtQuick

// =============================================================================
// AudioReveal.qml -- a part of a row that comes and goes. Its height is a fraction on ONE clock, a whole number of px every frame, and whatever stands on the row's
// height (the rows below, the ball, a line's start) follows in the same frame because nothing else animates: the content is revealed, clipped, as the part opens, and fades
// with it. `naturalHeight` includes the part's own gap above it: a positioner's `spacing` would land on one frame (CLAUDE.md, "the layout's own spacing").
// =============================================================================
Item {
    id: reveal

    property bool shown: false
    property real naturalHeight: 0
    property int durationMs: 260

    property real f: reveal.shown ? 1 : 0
    Behavior on f {
        NumberAnimation {
            duration: reveal.durationMs
            easing.type: Easing.OutCubic
        }
    }
    // Test the fraction, never the flag: a hidden ancestor's `visible` would collapse a layout that is only hidden (CLAUDE.md, "A HIDDEN SUBTREE LIES ABOUT ITS HEIGHT").
    visible: reveal.f > 0
    height: Math.round(reveal.naturalHeight * reveal.f)
    clip: reveal.f < 1
    opacity: reveal.f
}
