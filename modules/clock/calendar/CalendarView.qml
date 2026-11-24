pragma ComponentBehavior: Bound

import QtQuick
import "../../common/components/Mix.js" as Mix
import "../../common/theme"
import QtQml
import "../../common/components" as Common

// =============================================================================
// CalendarView.qml
//
// 6 horizontally-sliding RowStrips stacked beneath a fixed weekday header.
// Each strip owns its own monthPos cursor and animates it toward the shared
// targetMonthKey, with per-row duration that scales as slideDuration +
// staggerIndex·staggerMs so the stagger wave stays visible even during
// rapid-fire multi-month bursts.
//
// A single global selectionLayer sits on top of the strips:
//   - At rest: visible, position drawn at selectedDate's cell in the six
//     visible weeks (a neighbouring month's day included).
//   - Click on a visible cell: position glides from old cell to new via the existing
//     longest-axis-first partition easing. Cells under the selector's sweeping
//     centre flip their day-number text colour continuously (selectorAnimX/Y
//     is passed down to delegates so covered-state tracks the animated
//     position, not just the final selectedDate).
//   - Cross-month click: selection layer hides (opacity → 0) while the strips
//     slide. Its target position snaps to the new cell while hidden. Once
//     ALL strips have arrived at the current target, opacity animates back
//     to 1 and a scale-0→1 OutBack rebound plays at the new cell — honoring
//     the "hidden until sliding done, then scale-up" contract, including
//     across multi-month bursts.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // PUBLIC API (unchanged shape)
    // ======================================================================
    property var calendarData: null

    property int viewYear:  (new Date()).getFullYear()
    property int viewMonth: (new Date()).getMonth()

    property date today: new Date()
    property date selectedDate: new Date()

    property int weekStart: 1

    property real cellSize: 64
    property real weekColWidth: 34
    property real headerHeight: 26
    property real selectionAnimDuration: 420
    property real scaleAnimDuration: 300
    property int slideDuration: 420
    property int staggerMs: 55
    // Width of the band that dissolves the week rows into the ground at the
    // grid's left and right edges while they slide (0 at rest).
    property real edgeFadeWidth: 34
    // Held with a month step (PgUp/PgDn here; the host's arrows and swipe
    // read it too), it steps a year instead.
    property int yearModifier: Qt.ControlModifier
    // The ground the grid sits on: what the edge fade dissolves into.
    property color surfaceColor: Theme.surface

    property color textColor:         Theme.textPrimary
    property color mutedColor:        Theme.textFaint
    property color fainterColor:      Mix.c(Theme.textFaint, Theme.surface, 0.5)
    property color weekNumColor:      Theme.textFaint
    property color todayFillColor:    Theme.border
    property color todayBevelColor:   Theme.bevel
    property color todayShadowColor:  Theme.shadowDeep
    property color selectedFillColor: Theme.accent
    // Screentime's usage tint, passed to every row (MonthWeekRow has the why).
    property var usageTint: null
    property real usageTintF: 0
    property color usageTintColor: Theme.accent
    property color selectedTextColor: Theme.textOnAccent
    property color weekOffsetAccentColor: Theme.accent

    property string fontFamily: "Audiowide"

    property var weekOffsetStore: null

    signal daySelected(var dateObj)

    // ======================================================================
    // LAYOUT
    // ======================================================================
    readonly property real _paneW: weekColWidth + cellSize * 7
    readonly property int targetMonthKey: viewYear * 12 + viewMonth
    // Dedupe target used by the strips. Parent callers that set viewMonth
    // and viewYear separately (e.g. Dec→Jan in stepMonths) produce a brief
    // phantom targetMonthKey between the two assignments; coalescing via
    // Qt.callLater hides that phantom from the strip animators so they
    // don't briefly animate backward.
    property int stableTargetKey: targetMonthKey
    property bool _targetFlushPending: false

    // True while any strip is still animating to catch up to stableTargetKey.
    // Drives selectionLayer's hide-during-slide behavior.
    property bool _slideActive: false

    // Motion-blur intensity driven by how far the strips still have to
    // travel: while _slideActive, a 60 Hz sampler polls each strip's
    // |monthPos − targetMonthPos| and scales the max into a 0…1 knob.
    // Only >1 month gaps produce any blur — single-month scrolls stay
    // crisp. Goes back to 0 when _slideActive flips false.
    property real _blurAmount: 0
    property real blurOnsetMonths: 0.8
    property real blurSpanMonths: 2.0

    Timer {
        id: blurTimer
        interval: 16
        repeat: true
        running: root._slideActive
        onTriggered: {
            let maxDist = 0;
            for (let i = 0; i < stripRepeater.count; i++) {
                let s = stripRepeater.itemAt(i) as RowStrip;
                if (!s) continue;
                let d = Math.abs(s.monthPos - s.targetMonthPos);
                if (d > maxDist) maxDist = d;
            }
            let a = (maxDist - root.blurOnsetMonths) / root.blurSpanMonths;
            root._blurAmount = Math.max(0, Math.min(1.0, a));
        }
    }

    implicitWidth:  _paneW
    implicitHeight: headerHeight + cellSize * 6

    // ======================================================================
    // WEEKDAY HEADER
    // ======================================================================
    readonly property var _weekdayInitials: {
        let base = ["S", "M", "T", "W", "T", "F", "S"];
        let out = [];
        for (let i = 0; i < 7; i++) out.push(base[(weekStart + i) % 7]);
        return out;
    }

    Row {
        id: headerRow
        x: root.weekColWidth
        y: 0
        height: root.headerHeight
        Repeater {
            model: root._weekdayInitials
            delegate: Item {
                id: wdCell
                required property int index
                required property string modelData
                width: root.cellSize
                height: root.headerHeight
                Text {
                    anchors.centerIn: parent
                    text: wdCell.modelData
                    color: root.mutedColor
                    font.pixelSize: 12
                    font.family: root.fontFamily
                    font.bold: true
                }
            }
        }
    }

    // ======================================================================
    // STRIPS AREA
    // ======================================================================
    Item {
        id: stripsArea
        x: 0
        y: root.headerHeight
        width: root._paneW
        height: root.cellSize * 6
        clip: true

        Repeater {
            id: stripRepeater
            model: 6
            delegate: RowStrip {
                id: rs
                required property int index

                x: 0
                y: index * root.cellSize
                width: root._paneW
                height: root.cellSize

                weekIndex: index
                staggerIndex: index
                staggerMs: root.staggerMs
                slideDuration: root.slideDuration
                targetMonthPos: root.stableTargetKey
                targetMonthKey: root.stableTargetKey

                selectorAnimX: selectionLayer.animX
                selectorAnimY: selectionLayer.animY
                selectorScale: selectionLayer._effectiveScale
                selectorBaseScale: selectionLayer._baseScale
                selectorOpacity: selectionLayer._effectiveOpacity
                selectorReboundScale: selectionLayer._reboundScale

                weekStart: root.weekStart
                today: root.today
                calendarData: root.calendarData
                weekOffsetStore: root.weekOffsetStore

                edgeFadeWidth: root.edgeFadeWidth
                groundColor: root.surfaceColor

                cellSize: root.cellSize
                weekColWidth: root.weekColWidth
                fontFamily: root.fontFamily
                scaleAnimDuration: root.scaleAnimDuration

                textColor: root.textColor
                mutedColor: root.mutedColor
                fainterColor: root.fainterColor
                weekNumColor: root.weekNumColor
                todayFillColor: root.todayFillColor
                todayBevelColor: root.todayBevelColor
                todayShadowColor: root.todayShadowColor
                selectedFillColor: root.selectedFillColor
                selectedTextColor: root.selectedTextColor
                weekOffsetAccentColor: root.weekOffsetAccentColor
                usageTint: root.usageTint
                usageTintF: root.usageTintF
                usageTintColor: root.usageTintColor

                onDaySelected: (d) => root.daySelected(d)
                onArrivedAtTarget: root._onStripArrived()
            }
        }
    }

    // Motion blur on the strips during rapid multi-month scrolls. The
    // effect only kicks in above blurOnsetMonths of remaining travel, so
    // a normal single-month click stays pixel-crisp.
    Common.MotionBlur {
        source: stripsArea
        amount: root._blurAmount
    }

    // ======================================================================
    // GLOBAL SELECTION STATE
    // ======================================================================
    // This Item owns the selector's shared animated state (position, scale,
    // opacity). It does not *render* the ShadowBox — each MonthWeekRow
    // draws its own slice at z=2 (between today and day cells), which gives
    // the correct z-order: text/dots/lines on top, selector in the middle,
    // today box underneath.
    Item {
        id: selectionLayer
        x: root.weekColWidth
        y: root.headerHeight
        width: root.cellSize * 7
        height: root.cellSize * 6

        // `_effectiveOpacity` is what per-row selectors consume. Behavior is
        // gated to only animate when *showing* — so when the user starts a
        // month change, _slideActive flips true and opacity snaps to 0
        // instantly; the targetX/Y snap that happens a moment later is
        // already invisible, so the selector doesn't appear to teleport.
        property real _effectiveOpacity: root._slideActive ? 0 : 1
        Behavior on _effectiveOpacity {
            enabled: !root._slideActive
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }

        // --- Target cell (in current viewMonth) ---
        readonly property date _firstOfMonth: new Date(root.viewYear, root.viewMonth, 1)
        readonly property int  _firstDow: _firstOfMonth.getDay()
        readonly property int  _leadingBlanks: ((_firstDow - root.weekStart) + 7) % 7

        // The selected day's cell anywhere in the six visible weeks, the
        // neighbouring months' days included: a click on 2 Oct while
        // September is shown moves the selector there like any other click.
        // Counted in UTC days, so a DST change inside the span cannot turn
        // 23 or 25 hours into a day off.
        function _targetCell() {
            let s = root.selectedDate;
            let days = Math.round((Date.UTC(s.getFullYear(), s.getMonth(), s.getDate())
                - Date.UTC(root.viewYear, root.viewMonth, 1)) / 86400000);
            let idx = _leadingBlanks + days;
            if (idx < 0 || idx >= 42) {
                // Not on screen (transient while the view catches up with a
                // keyboard move). Hold the last position; the slide hides
                // the selector and the rebound lands on the real cell.
                return { col: -1, row: -1 };
            }
            return { col: idx % 7, row: Math.floor(idx / 7) };
        }

        readonly property var _tc: _targetCell()
        property real targetX: 0
        property real targetY: 0

        on_TcChanged: {
            // Only update target when the selection resolves to a visible
            // cell. During the brief window where selectedDate is set but
            // the view hasn't caught up (or vice versa), keep the previous
            // target so the post-slide rebound lands somewhere sane.
            if (_tc.col >= 0) {
                selectionLayer.targetX = _tc.col * root.cellSize;
                selectionLayer.targetY = _tc.row * root.cellSize;
            }
        }

        // --- Longest-axis-first glide ---
        property real startX: 0
        property real startY: 0
        property real endX:   0
        property real endY:   0
        property real t: 1.0

        // --- Scale: smaller over today, OutBack rebound on arrival ---
        // _baseScale animates between 1.0 (regular cell) and a compressed
        // value when sitting on the today cell, so the selector visibly
        // nests inside the today fill without overlapping its border.
        // _reboundScale is the overshoot bounce on arrival (0→1.7→1).
        // _effectiveScale = _baseScale * _reboundScale drives the box's
        // visual size; _baseScale alone is exposed separately so the per-
        // row selector can compensate baseRadius (radius / scale stays
        // constant in pixel terms — see MonthWeekRow.selectorBox).
        readonly property bool _onToday: root._sameDay(root.selectedDate, root.today)
        readonly property real _targetBaseScale: _onToday ? 0.88 : 1.0
        property real _baseScale: _targetBaseScale
        property real _reboundScale: 1.0
        readonly property real _effectiveScale: _baseScale * _reboundScale

        Behavior on _baseScale {
            NumberAnimation { duration: root.scaleAnimDuration; easing.type: Easing.InOutCubic }
        }

        readonly property real _dx: endX - startX
        readonly property real _dy: endY - startY
        readonly property real _absX: Math.abs(_dx)
        readonly property real _absY: Math.abs(_dy)
        readonly property real _totalDist: _absX + _absY
        readonly property bool _xFirst: _absX >= _absY
        readonly property real _splitT: _totalDist > 0
            ? (_xFirst ? _absX : _absY) / _totalDist : 0

        readonly property real animX: {
            if (_totalDist <= 0.0001) return endX;
            if (_xFirst) {
                return t <= _splitT
                    ? startX + (_splitT > 0 ? (t / _splitT) * _dx : 0)
                    : endX;
            }
            return t > _splitT
                ? startX + ((t - _splitT) / (1 - _splitT)) * _dx
                : startX;
        }
        readonly property real animY: {
            if (_totalDist <= 0.0001) return endY;
            if (_xFirst) {
                return t > _splitT
                    ? startY + ((t - _splitT) / (1 - _splitT)) * _dy
                    : startY;
            }
            return t <= _splitT
                ? startY + (_splitT > 0 ? (t / _splitT) * _dy : 0)
                : endY;
        }

        Component.onCompleted: {
            startX = targetX; startY = targetY;
            endX   = targetX; endY   = targetY;
            t = 1.0;
        }

        onTargetXChanged: _onTargetChange()
        onTargetYChanged: _onTargetChange()

        function _onTargetChange() {
            if (root._slideActive) {
                // Snap quietly while hidden so the post-slide rebound reveals
                // the selector already at the new cell.
                posAnim.stop();
                startX = targetX;
                startY = targetY;
                endX   = targetX;
                endY   = targetY;
                t = 1.0;
            } else {
                _glide();
            }
        }

        function _glide() {
            let curX = animX, curY = animY;
            posAnim.stop();
            startX = curX;
            startY = curY;
            endX   = targetX;
            endY   = targetY;
            t = 0;
            posAnim.start();
        }

        function playRebound() {
            posAnim.stop();
            reboundScaleAnim.stop();
            startX = targetX;
            startY = targetY;
            endX   = targetX;
            endY   = targetY;
            t = 1.0;
            _reboundScale = 0;
            reboundScaleAnim.start();
        }

        NumberAnimation {
            id: posAnim
            target: selectionLayer
            property: "t"
            to: 1
            duration: root.selectionAnimDuration
            easing.type: Easing.InOutCubic
        }

        NumberAnimation {
            id: reboundScaleAnim
            target: selectionLayer
            property: "_reboundScale"
            from: 0
            to: 1
            duration: 520
            easing.type: Easing.OutBack
            easing.overshoot: 1.7
        }
    }

    // ======================================================================
    // MONTH-CHANGE HANDLING
    // ======================================================================
    property bool _initialised: false
    Component.onCompleted: _initialised = true

    onTargetMonthKeyChanged: {
        if (!_initialised) return;
        if (_targetFlushPending) return;
        _targetFlushPending = true;
        Qt.callLater(_flushTargetChange);
    }

    function _flushTargetChange() {
        _targetFlushPending = false;
        root.stableTargetKey = root.targetMonthKey;
        // Mark slide as active; clears when all six strips report arrival
        // at the final stable target. Multi-month bursts that retarget
        // mid-flight don't clear this — it only clears when every strip
        // is actually at the LATEST target position.
        root._slideActive = true;

        // A selection already inside the new month stays (a keyboard move
        // across the month's end, or a neighbouring-month day clicked
        // before stepping). Otherwise the month opens on today, or its 1st.
        if (selectedDate.getFullYear() === viewYear && selectedDate.getMonth() === viewMonth)
            return;
        let defaultDay;
        if (today.getFullYear() === viewYear && today.getMonth() === viewMonth) {
            defaultDay = new Date(today.getFullYear(), today.getMonth(), today.getDate());
        } else {
            defaultDay = new Date(viewYear, viewMonth, 1);
        }
        root.daySelected(defaultDay);
    }

    // Called from each RowStrip when its own monthPosAnim arrives at
    // targetMonthPos. Check whether all six have arrived; if so end the
    // slide and play the selection rebound.
    function _onStripArrived() {
        if (!_slideActive) return;
        for (let i = 0; i < stripRepeater.count; i++) {
            let s = stripRepeater.itemAt(i) as RowStrip;
            if (!s) continue;
            if (Math.abs(s.monthPos - s.targetMonthPos) > 0.001) return;
        }
        // All arrived.
        _slideActive = false;
        _blurAmount = 0;
        selectionLayer.playRebound();
    }

    function _sameDay(a, b) {
        return a && b
            && a.getFullYear() === b.getFullYear()
            && a.getMonth()    === b.getMonth()
            && a.getDate()     === b.getDate();
    }

    // ======================================================================
    // KEYBOARD NAV
    // ======================================================================
    // Called by whichever focus-owning parent routes key events at us
    // (ClockPopupContent wires this to its own Keys.onPressed). Arrow keys
    // move the selection by day/week; T jumps to today; PgUp/PgDn step the
    // view month (a year with `yearModifier`) without touching the selection.
    // The one month-stepping path: the host's arrows and swipe call it too.
    // Whether today's cell is among the six weeks on screen -- the
    // neighbouring months' days count, they are drawn -- and whether it is
    // the selection. The header's way back to today shows when neither holds.
    readonly property bool todayInView: {
        const t = root.today;
        const lead = ((new Date(root.viewYear, root.viewMonth, 1).getDay() - root.weekStart) + 7) % 7;
        const days = Math.round((Date.UTC(t.getFullYear(), t.getMonth(), t.getDate())
            - Date.UTC(root.viewYear, root.viewMonth, 1)) / 86400000);
        return lead + days >= 0 && lead + days < 42;
    }
    readonly property bool todaySelected: root._sameDay(root.selectedDate, root.today)
    // Select today and bring its month on screen (T, and the header's icon).
    function goToday() {
        const n = new Date();
        const d = new Date(n.getFullYear(), n.getMonth(), n.getDate());
        root.daySelected(d);
        if (d.getFullYear() !== root.viewYear || d.getMonth() !== root.viewMonth) {
            root.viewMonth = d.getMonth();
            root.viewYear = d.getFullYear();
        }
    }
    function stepMonths(n) {
        let total = viewYear * 12 + viewMonth + n;
        let ny = Math.floor(total / 12);
        viewYear = ny;
        viewMonth = total - ny * 12;
    }
    function monthsFor(modifiers) {
        return (modifiers & root.yearModifier) ? 12 : 1;
    }

    function handleKey(e) {
        let d = new Date(selectedDate);
        let moved = true;
        switch (e.key) {
            case Qt.Key_Left:     d.setDate(d.getDate() - 1); break;
            case Qt.Key_Right:    d.setDate(d.getDate() + 1); break;
            case Qt.Key_Up:       d.setDate(d.getDate() - 7); break;
            case Qt.Key_Down:     d.setDate(d.getDate() + 7); break;
            case Qt.Key_T:        goToday(); e.accepted = true; return;
            case Qt.Key_PageUp:   stepMonths(-monthsFor(e.modifiers)); e.accepted = true; return;
            case Qt.Key_PageDown: stepMonths(monthsFor(e.modifiers)); e.accepted = true; return;
            default: moved = false;
        }
        if (!moved) return;
        daySelected(d);
        if (d.getFullYear() !== viewYear || d.getMonth() !== viewMonth) {
            viewMonth = d.getMonth();
            viewYear = d.getFullYear();
        }
        e.accepted = true;
    }
}
