pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// SwapCurtain.qml -- what the engine's swap of a secondary does (fade out, change what it shows, fade in), held by the content itself, so a part of
// it can stay in view: a content with `secondarySwapsInPlace` (GooeyEngine's contract) binds `opacity: curtain.shown` on everything but the chart it
// is about to morph, and calls
//
//     curtain.swap(() => <show the new thing>)     // out, the change at the bottom, back in
//
// Same clocks as the engine's fade (80 ms out, 120 in). A swap asked for during one goes down from where it is and the last change asked for is
// the one that happens; `stop()` puts everything back in view and drops the change (a key that came the engine's way, hidden).
// =============================================================================
Item {
    id: curtain

    // 1 in view, 0 at the bottom: the one clock everything it covers reads.
    property real shown: 1
    property int outMs: 80
    property int inMs: 120
    property var _change: null

    function swap(change) {
        curtain._change = change;
        clock.stop();
        clock.from = curtain.shown;
        clock.to = 0;
        clock.duration = Math.max(1, curtain.outMs * curtain.shown);
        clock.start();
    }
    function stop() {
        clock.stop();
        curtain._change = null;
        curtain.shown = 1;
    }

    NumberAnimation {
        id: clock
        target: curtain
        property: "shown"
        easing.type: Easing.Linear
        onFinished: {
            const c = curtain._change;
            if (!c)
                return;
            curtain._change = null;
            c();
            clock.from = 0;
            clock.to = 1;
            clock.duration = curtain.inMs;
            clock.start();
        }
    }
}
