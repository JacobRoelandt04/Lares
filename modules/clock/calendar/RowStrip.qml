pragma ComponentBehavior: Bound

import QtQuick
import "../../common/components/Mix.js" as Mix
import "../../common/theme"
import "../../common/components" as Common

// =============================================================================
// RowStrip.qml
//
// One of six horizontal week-row strips inside CalendarView. Owns a float
// cursor `monthPos` which is animated toward `targetMonthPos` (= the view's
// targetMonthKey). Three tiled MonthWeekRow delegates are positioned relative
// to `monthPos` at fixed integer offsets, so the strip behaves like an
// infinite carousel.
//
// Queue + variable speed + stagger:
//   Every retarget stops the in-flight animation and restarts it toward the
//   latest target with duration = slideDuration + staggerIndex·staggerMs.
//   The per-row duration is what preserves the stagger through a multi-click
//   burst — without it all six rows, once kicked, would retarget to the
//   same final target with the same remaining time and end up arriving
//   synchronously, losing the visible diagonal wave. With it, row 0 covers
//   any queued distance in slideDuration, row 5 in slideDuration + 5·staggerMs,
//   so row 5 genuinely lags row 0 throughout the burst and arrives last.
// =============================================================================
Item {
    id: strip

    // --- Inputs ---
    property int weekIndex: 0
    property int staggerIndex: 0
    property real targetMonthPos: 0
    property int weekStart: 1
    property date today: new Date()
    property var calendarData: null
    property var weekOffsetStore: null

    // --- Selector coupling (global selectionLayer → delegates) ---
    // targetMonthKey filters which delegate considers itself the "current"
    // month for selection hit-test. selectorAnimX/Y are the animated
    // position; selectorScale/Opacity drive the shared visual state.
    property int targetMonthKey: 0
    property real selectorAnimX: 0
    property real selectorAnimY: 0
    property real selectorScale: 1.0
    property real selectorBaseScale: 1.0
    property real selectorOpacity: 1.0
    property real selectorReboundScale: 1.0

    // --- Timing ---
    property int staggerMs: 55
    property int slideDuration: 420

    // --- Styling (pass-through) ---
    property real edgeFadeWidth: 34
    property color groundColor: Theme.surface

    property real cellSize: 64
    property real weekColWidth: 34
    property string fontFamily: "Audiowide"
    property real scaleAnimDuration: 300

    property color textColor:         Theme.textPrimary
    property color mutedColor:        Theme.textFaint
    property color fainterColor:      Mix.c(Theme.textFaint, Theme.surface, 0.5)
    property color weekNumColor:      Theme.textFaint
    property color todayFillColor:    Theme.border
    property color todayBevelColor:   Theme.bevel
    property color todayShadowColor:  Theme.shadowDeep
    property color selectedFillColor: Theme.accent
    property color selectedTextColor: Theme.textOnAccent
    property color weekOffsetAccentColor: Theme.accent
    property var usageTint: null
    property real usageTintF: 0
    property color usageTintColor: Theme.accent

    signal daySelected(var dateObj)

    readonly property real paneW: weekColWidth + cellSize * 7
    implicitWidth:  paneW
    implicitHeight: cellSize

    // --- Animation state ---
    // Initial binding is declarative for mount-time render; broken in
    // Component.onCompleted so that subsequent target changes must be
    // driven through monthPosAnim rather than snapping.
    property real monthPos: targetMonthPos
    property bool _initialised: false

    // Per-row animation duration = slideDuration + staggerIndex·staggerMs.
    // This is what preserves the stagger through a multi-click burst: the
    // top row's retargets all complete in slideDuration ms each, while
    // row 5's retargets take the full slideDuration + 5·staggerMs each. So
    // when a user spams › 5 times, row 0 reaches the final target in
    // slideDuration ms after the last click, and row 5 reaches it
    // slideDuration + 5·staggerMs ms after the last click — yielding a
    // genuine lag that you can see as a diagonal wave across the 6 rows
    // instead of all rows snapping together at the end of the burst.
    readonly property int _animDuration: slideDuration + staggerIndex * staggerMs

    NumberAnimation {
        id: monthPosAnim
        target: strip
        property: "monthPos"
        duration: strip._animDuration
        easing.type: Easing.OutCubic
        onStopped: {
            if (Math.abs(strip.monthPos - strip.targetMonthPos) < 0.001) {
                // Arrival. Emit signal for CalendarView's global selection
                // layer to re-show + rebound once all strips have arrived.
                strip.arrivedAtTarget();
            }
        }
    }

    signal arrivedAtTarget()

    onTargetMonthPosChanged: {
        if (!strip._initialised) return;
        // Retarget immediately. Duration is per-row (staggered); so even
        // though all six rows retarget at the same instant, rows further
        // down the stack run slower and lag behind visually.
        // A retarget in the same direction mid-flight continues the leg
        // (a burst of clicks is one run); a fresh start or a reversal
        // begins a new one where the row is now.
        const sameWay = Math.sign(strip.targetMonthPos - strip._legFrom)
            === Math.sign(monthPosAnim.to - strip._legFrom);
        if (!monthPosAnim.running || !sameWay)
            strip._legFrom = strip.monthPos;
        monthPosAnim.stop();
        monthPosAnim.to = strip.targetMonthPos;
        monthPosAnim.start();
    }

    // How far through its current run this row is, 0 -> 1: the one clock
    // of the edge fades below, so they exist only while the row moves.
    property real _legFrom: 0
    readonly property real _legFraction: {
        const span = strip.targetMonthPos - strip._legFrom;
        if (Math.abs(span) < 0.001)
            return 1;
        return Math.max(0, Math.min(1, (strip.monthPos - strip._legFrom) / span));
    }

    Component.onCompleted: {
        // Break the declarative binding so targetMonthPos changes no longer
        // snap monthPos — they go through the animation path instead.
        monthPos = targetMonthPos;
        _initialised = true;
    }

    // --- Tiled month-week rows ---
    readonly property int _center: Math.round(monthPos)
    // 3 tiles cover ±1 month around _center, which is exactly the range that
    // can be visible inside a paneW-wide viewport at any instant. Keeping the
    // tile count minimal keeps binding re-evaluation cheap during fast
    // scroll, when _center shifts once per half-month crossed.
    readonly property int _range: 1

    Repeater {
        id: tileRepeater
        model: strip._range * 2 + 1
        delegate: MonthWeekRow {
            id: tile
            required property int index

            monthKey: strip._center + (index - strip._range)

            weekIndex: strip.weekIndex
            weekStart: strip.weekStart
            today: strip.today
            calendarData: strip.calendarData
            weekOffsetStore: strip.weekOffsetStore
            cellSize: strip.cellSize
            weekColWidth: strip.weekColWidth
            fontFamily: strip.fontFamily
            scaleAnimDuration: strip.scaleAnimDuration

            targetMonthKey: strip.targetMonthKey
            selectorAnimX: strip.selectorAnimX
            selectorAnimY: strip.selectorAnimY
            selectorScale: strip.selectorScale
            selectorBaseScale: strip.selectorBaseScale
            selectorOpacity: strip.selectorOpacity
            selectorReboundScale: strip.selectorReboundScale

            textColor: strip.textColor
            mutedColor: strip.mutedColor
            fainterColor: strip.fainterColor
            weekNumColor: strip.weekNumColor
            todayFillColor: strip.todayFillColor
            todayBevelColor: strip.todayBevelColor
            todayShadowColor: strip.todayShadowColor
            selectedFillColor: strip.selectedFillColor
            selectedTextColor: strip.selectedTextColor
            weekOffsetAccentColor: strip.weekOffsetAccentColor
            usageTint: strip.usageTint
            usageTintF: strip.usageTintF
            usageTintColor: strip.usageTintColor

            x: (monthKey - strip.monthPos) * strip.paneW
            y: 0

            onDaySelected: (d) => strip.daySelected(d)
        }
    }

    // The grid's clip edges, dissolved while the row slides: the months
    // leaving and arriving fade into the ground instead of being cut by a
    // vertical line. Exact at rest.
    Common.SeamFade {
        z: 10
        edge: Qt.LeftEdge
        extent: strip._legFraction
        ground: strip.groundColor
        fadeHeight: strip.edgeFadeWidth
    }
    Common.SeamFade {
        z: 10
        edge: Qt.RightEdge
        extent: strip._legFraction
        ground: strip.groundColor
        fadeHeight: strip.edgeFadeWidth
    }
}
