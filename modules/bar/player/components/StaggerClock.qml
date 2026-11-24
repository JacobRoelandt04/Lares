import QtQuick

// =============================================================================
// StaggerClock.qml -- the clock a list's wave is paced by.
//
// Every row of a wave waits `index x 55 ms`. On a wall-clock Timer, a frame that takes 400 ms (a shader
// linking, a decode landing) lets every timer that came due in it fire in ONE turn, so the rows behind it arrive
// together -- and so does the timer that puts the folded tail down, which is the same bug the list-animation
// notes describe, delivered by a stall instead of by a count. A wave runs through the popup's own opening,
// where a stall is likeliest, and this clock holds it.
//
// THIS CLOCK ONLY ADVANCES BY WHAT WAS DRAWN, and never by more than `maxStepMs` a frame. A stall holds the
// whole wave where it was and it resumes, staggered, from there: the rows already in the air finish on Qt's
// own animation clock (they have started), the rows that had not started wait their turn on this one.
//
// It runs only while something waits on it (`hold()` / `release()`): a FrameAnimation that runs makes every
// window of the process render at vsync (CLAUDE.md), so an idle list must hold none.
// =============================================================================
Item {
    id: clk
    visible: false
    // Milliseconds of drawn time since the clock was made.
    property real now: 0
    property int holds: 0
    property real maxStepMs: 25
    readonly property bool running: fa.running

    function hold() { clk.holds++; }
    function release() { clk.holds = Math.max(0, clk.holds - 1); }

    FrameAnimation {
        id: fa
        running: clk.holds > 0
        onTriggered: clk.now += Math.min(fa.frameTime * 1000, clk.maxStepMs)
    }
}
