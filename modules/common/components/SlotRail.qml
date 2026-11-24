pragma ComponentBehavior: Bound

import QtQuick

import "../theme"

// =============================================================================
// SlotRail.qml -- a one-of-many choice as a thing: a carved groove (GrooveTrack) with a slot at every place the ball can rest, running from the first slot to the last and
// no further, and a ball that rolls from one to the other. The audio popup's default device (with the well that glides under the same row) and every radio group of a
// menu (MenuRows) are this.
//
//   stops        [{ key, y, top, height }] top to bottom, AS THEY ARE THIS FRAME: y is the slot's centre, top and height the row it stands for
//   currentKey   the stop the ball is in ("": none)
//   ballY, wellTop, wellHeight   read off for whoever draws under the rows; seated (a ball is drawn), moving, targetY
//   seat()       to the current stop at once: a menu opening is not a move
//
// ONE CLOCK. The only thing that animates is `_p`, from one stop to another, and everything is read against the live stops: a row growing above the current one carries the
// ball and the well in the same frame, with no second animation chasing it. The curve is an OutBack: the ball rolls a little past its slot and settles into it (`settle`, a
// share of the way, at most `settleMaxPx`, so a long way does not leave the slot); the well rides the same fraction and stops at the row. A move interrupted in the air
// starts again from where it was drawn. The first place is taken at once (no flight on open), and a stop that has gone has nothing to travel from.
//
// THE BALL IS THE SQUISHY ONE (SquishItem: the slider's and the workspaces' material). It stretches along its way and rings back round at the slot. What it is
// given to feel is the DISTANCE IT TRAVELLED, never its place: `_travel` adds up the ball's own steps while the glide runs, so a row growing above a stop
// carries the ball without a squish, and a ball seated by a menu opening (or a stop that has gone) is no move at all.
// =============================================================================
Item {
    id: rail

    property var stops: []
    property string currentKey: ""
    property color ground: Theme.listBox
    property real lineThickness: 4
    property real slotSize: 12
    property real ballSize: 8
    property int travelMs: 420
    property real settle: 0.05
    property real settleMaxPx: 2.5
    property color ballColor: Theme.accent
    property real ballShadowOpacity: 0.55
    property real ballShadowBlur: 8

    implicitWidth: groove.implicitWidth

    function _stopOf(key: string): var {
        const a = rail.stops;
        for (let i = 0; i < a.length; i++)
            if (a[i].key === key)
                return a[i];
        return null;
    }
    property string _fromKey: ""
    property string _toKey: ""
    property var _fromPlace: null                // where an interrupted move starts: a place, not a stop
    property real _p: 1                          // the clock, linear
    readonly property var _to: rail._stopOf(rail._toKey)
    readonly property var _from: rail._fromPlace !== null ? rail._fromPlace : rail._stopOf(rail._fromKey)
    readonly property bool seated: rail._to !== null
    readonly property bool moving: glide.running
    // OutBack's peak is 4 s^3 / (27 (s + 1)^2), which sqrt(peak / 0.1) x 1.70158 meets to a few per cent for a peak under 0.1.
    readonly property real _ball: {
        const a = rail._from, b = rail._to;
        const way = a !== null && b !== null ? Math.abs(b.y - a.y) : 0;
        const peak = way > 0 ? Math.min(rail.settle, rail.settleMaxPx / way) : 0;
        const s = 1.70158 * Math.sqrt(peak / 0.1);
        const u = rail._p - 1;
        return 1 + (s + 1) * u * u * u + s * u * u;
    }
    function _mix(field: string, t: real): real {
        const b = rail._to, a = rail._from;
        if (b === null)
            return 0;
        return a === null ? b[field] : a[field] + (b[field] - a[field]) * t;
    }
    readonly property real targetY: rail._to !== null ? rail._to.y : -1
    readonly property real ballY: rail._mix("y", rail._ball)
    readonly property real wellTop: rail._mix("top", Math.min(1, rail._ball))
    readonly property real wellHeight: rail._mix("height", Math.min(1, rail._ball))

    function seat(): void {
        glide.stop();
        rail._fromPlace = null;
        rail._fromKey = rail.currentKey;
        rail._toKey = rail.currentKey;
        rail._p = 1;
    }
    function _retarget(): void {
        const k = rail.currentKey;
        if (k === rail._toKey)
            return;
        if (rail._to === null || k === "") {
            rail.seat();
            return;
        }
        if (glide.running) {
            rail._fromPlace = { y: rail.ballY, top: rail.wellTop, height: rail.wellHeight };
            rail._fromKey = "";
        } else {
            rail._fromPlace = null;
            rail._fromKey = rail._toKey;
        }
        rail._p = 0;
        rail._toKey = k;
        glide.restart();
    }
    // what the ball is told it moved: its steps while the glide runs
    property real _travel: 0
    property real _lastBallY: 0
    onBallYChanged: {
        if (glide.running)
            rail._travel += rail.ballY - rail._lastBallY;
        rail._lastBallY = rail.ballY;
    }
    onCurrentKeyChanged: rail._retarget()
    Component.onCompleted: rail._retarget()
    NumberAnimation {
        id: glide
        target: rail
        property: "_p"
        from: 0
        to: 1
        duration: rail.travelMs
    }

    // ---- the groove: from the first slot to the last ---------------------------------------------------------------------------------
    readonly property real _first: rail.stops.length > 0 ? rail.stops[0].y : 0
    readonly property real _last: rail.stops.length > 0 ? rail.stops[rail.stops.length - 1].y : 0
    readonly property real _span: Math.max(1, rail._last - rail._first)
    GrooveTrack {
        id: groove
        objectName: "groove"
        orientation: "vertical"
        visible: rail.stops.length > 0
        readonly property real _pad: rail.slotSize / 2 + 3
        x: (rail.width - width) / 2
        y: rail._first - groove._pad
        width: implicitWidth
        height: rail._span + 2 * groove._pad
        edgePadding: groove._pad
        lineThickness: rail.lineThickness
        dotSize: rail.slotSize
        showFill: false
        // a vertical track reads 0 at its foot
        stops: rail.stops.map(s => 1 - (s.y - rail._first) / rail._span)
        surfaceColor: rail.ground
        grooveColor: Theme.headerBox
        grooveBevelColor: Theme.bevel
        grooveShadowColor: Theme.shadowDeep
    }
    SquishItem {
        id: ball
        objectName: "railBall"
        visible: rail.seated
        baseWidth: rail.ballSize
        baseHeight: rail.ballSize
        x: (rail.width - baseWidth) / 2
        y: rail.ballY - baseHeight / 2
        // the slider's own feel (GrooveSlider): a long stretch under speed, a very bouncy recovery
        trackX: 0
        trackY: rail._travel
        color: rail.ballColor
        shadowColor: rail.ballColor
        shadowOpacity: rail.ballShadowOpacity
        shadowBlur: rail.ballShadowBlur
        pressure: 0.0
        maxSquishRatio: 0.5
        recoverySpringStiffness: 2.4
        recoverySpringDamping: 0.14
        maxSpeedThreshold: 24.0
    }
}
