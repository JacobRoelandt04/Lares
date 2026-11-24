pragma ComponentBehavior: Bound

import QtQuick
import "../../common/components/Mix.js" as Mix
import "../../common/theme"
import "../../common/components" as Common

// =============================================================================
// MonthWeekRow.qml
//
// One week (7 days) of one month, plus its week-number cell on the left.
// Self-contained: today-marker, selection-marker, multi-day-line lanes are
// all rendered inside this single row.
//
// RowStrip tiles several of these horizontally — one per month at a fixed
// x offset — and slides the whole tile-set by animating its monthPos cursor.
// Because today/selection markers live INSIDE each row, they ride naturally
// along with their row as it slides; no separate overlay layer is required.
//
// Multi-day line lane consistency (same UID always sits on the same lane
// across every week it spans) is preserved by computing the slot map from
// the full 6×7 month — each of the 6 MonthWeekRow instances for a given
// month runs the same deterministic algorithm over the same memoized
// getEventsForDay results, so lanes match without coordination.
// =============================================================================
Item {
    id: row

    // --- Inputs ---
    property int monthKey: 0   // year * 12 + month (0..11)
    property int weekIndex: 0  // 0..5
    property int weekStart: 1
    property date today: new Date()
    property var calendarData: null
    property var weekOffsetStore: null

    // --- Selection input ---
    // The selector ShadowBox itself is rendered INSIDE this row (at a z
    // between today and day cells), so day-number text, dots and multi-day
    // lines paint on top of it. State is driven from CalendarView's
    // selectionLayer which owns the single shared animator.
    property int targetMonthKey: 0
    // Animated position in selectionLayer-local coordinates (0..cellSize·7
    // horizontally, 0..cellSize·6 vertically — origin at the top-left of
    // the 7×6 day grid, ignoring the week-number column).
    property real selectorAnimX: 0
    property real selectorAnimY: 0
    // Scale + opacity are global (owned by selectionLayer); each row's
    // selector just reads them so the 6 rows that share target month render
    // a consistent box.
    property real selectorScale: 1.0
    // Base scale (no rebound) — used for radius compensation so the
    // rendered corner radius stays constant in screen pixels even when
    // the selector is shrunk over today. Rebound bounce intentionally
    // does NOT factor in: the corners shouldn't bounce with the box.
    property real selectorBaseScale: 1.0
    property real selectorOpacity: 1.0
    // Rebound scale separately exposed so the selector's *label* can fade in
    // lock-step with the rebound growth without itself scaling. Passed
    // through from CalendarView.selectionLayer._reboundScale; 1.0 at rest.
    property real selectorReboundScale: 1.0

    // --- Styling ---
    property real cellSize: 64
    property real weekColWidth: 34
    property string fontFamily: "Audiowide"
    property real scaleAnimDuration: 300

    property color textColor:         Theme.textPrimary
    property color mutedColor:        Theme.textFaint
    property color fainterColor:      Mix.c(Theme.textFaint, Theme.surface, 0.5)
    property color weekNumColor:      Theme.textFaint
    property color todaySurfaceColor: Theme.surface
    property color todayFillColor:    Theme.border
    property color todayBevelColor:   Theme.bevel
    property color todayShadowColor:  Theme.shadowDeep
    property color selectedFillColor: Theme.accent
    property color selectedTextColor: Theme.textOnAccent
    property color weekOffsetAccentColor: Theme.accent
    // Screentime's usage tint (ClockPopupContent shows it while its key is
    // held): `usageTint` maps "YYYY-MM-DD" -> the day's share of the heaviest
    // shown day (0..1, facts only), `usageTintF` is the held fraction (one
    // clock, eased by the host), the colour the host's themed accent.
    property var usageTint: null
    property real usageTintF: 0
    property color usageTintColor: Theme.accent

    signal daySelected(var dateObj)

    implicitWidth:  weekColWidth + cellSize * 7
    implicitHeight: cellSize
    // Clip so the selector's cross-week slice (when it straddles a week
    // boundary during glide) only draws within this row's bounds — the
    // neighbouring row renders its own slice the same way.
    clip: true

    // ======================================================================
    // GRID MATH
    // ======================================================================
    readonly property int year:  Math.floor(monthKey / 12)
    readonly property int month: monthKey - year * 12

    readonly property date _firstOfMonth: new Date(year, month, 1)
    readonly property int  _firstDow: _firstOfMonth.getDay()
    readonly property int  _leadingBlanks: ((_firstDow - weekStart) + 7) % 7

    function cellDate(col) {
        let dayOffset = weekIndex * 7 + col - _leadingBlanks;
        return new Date(year, month, 1 + dayOffset);
    }

    function _sameDay(a, b) {
        return a && b
            && a.getFullYear() === b.getFullYear()
            && a.getMonth()    === b.getMonth()
            && a.getDate()     === b.getDate();
    }

    function _dayStatus(d) {
        let now = new Date(row.today.getFullYear(), row.today.getMonth(), row.today.getDate());
        let v = new Date(d.getFullYear(), d.getMonth(), d.getDate());
        if (v < now) return "before";
        if (v > now) return "after";
        return "same";
    }

    function _isoWeek(d) {
        let dt = new Date(d.getFullYear(), d.getMonth(), d.getDate());
        dt.setDate(dt.getDate() + 3 - (dt.getDay() + 6) % 7);
        let w1 = new Date(dt.getFullYear(), 0, 4);
        return 1 + Math.round(((dt - w1) / 86400000 - 3 + (w1.getDay() + 6) % 7) / 7);
    }

    // --- Today column lookup (relative to THIS week) ---
    readonly property int _todayCol: {
        if (today.getFullYear() !== year || today.getMonth() !== month) return -1;
        let idx = _leadingBlanks + today.getDate() - 1;
        if (Math.floor(idx / 7) !== weekIndex) return -1;
        return idx % 7;
    }

    // Marks layout (dots / multi-day lines for a day square) is fully
    // delegated to the data source, which caches the result per
    // (dayKey, viewYear, viewMonth): a hash lookup in the common case, not a
    // computation per cell on every month re-centring.

    // ======================================================================
    // TODAY BOX (only rendered if today falls in this week)
    // ======================================================================
    Common.ShadowBox {
        visible: row._todayCol >= 0
        x: row.weekColWidth + row._todayCol * row.cellSize + 3
        y: 3
        baseWidth: row.cellSize - 6
        baseHeight: row.cellSize - 6
        baseRadius: 12
        surfaceColor: row.todaySurfaceColor
        backgroundColor: row.todayFillColor
        bevelColor: row.todayBevelColor
        shadowColor: row.todayShadowColor
        bevelWidth: 2
        shadowWidth: 10
        z: 0
    }

    // ======================================================================
    // USAGE TINT (z=0.5: over the today box, under the day numbers)
    // ======================================================================
    Repeater {
        model: row.usageTintF > 0 && row.usageTint ? 7 : 0
        delegate: Rectangle {
            id: tintCell
            required property int index
            readonly property date _cd: row.cellDate(tintCell.index)
            readonly property real _f: row.usageTint[Qt.formatDate(tintCell._cd, "yyyy-MM-dd")] ?? 0
            visible: tintCell._f > 0
            x: row.weekColWidth + tintCell.index * row.cellSize + 3
            y: 3
            width: row.cellSize - 6
            height: row.cellSize - 6
            radius: 12
            color: row.usageTintColor
            opacity: row.usageTintF * (0.10 + 0.45 * tintCell._f)
            z: 0.5
        }
    }

    // ======================================================================
    // DAY-NUMBER TEXT LAYER (z=1, BELOW selector)
    // ======================================================================
    // Rendered as a separate layer under the selector so the selector's
    // opaque fill naturally covers the regular-colour number when it's
    // at full scale — no need for covered-based colour flipping to hide
    // it. The selector's own inner text (rendered as a child of the
    // selector ShadowBox at z=2) provides the selected-colour version on
    // top of the selector.
    Repeater {
        model: 7
        delegate: Text {
            id: dayText
            required property int index
            readonly property date _cd: row.cellDate(dayText.index)
            readonly property bool _inMonth: _cd.getMonth() === row.month
            readonly property bool _isToday: row._sameDay(_cd, row.today)
            x: row.weekColWidth + dayText.index * row.cellSize
                + (row.cellSize - implicitWidth) / 2
            y: 10
            z: 1
            text: _cd.getDate()
            font.pixelSize: 15
            font.family: row.fontFamily
            font.bold: _isToday
            color: !_inMonth ? row.fainterColor : row.textColor
        }
    }

    // ======================================================================
    // SELECTOR (z=2; only visible inside target month)
    // ======================================================================
    // Selector box carries no child text — the label is rendered as a
    // sibling below so it can fade in lock-step with the selector while
    // keeping its own scale untouched (selector may compress on today or
    // overshoot on rebound, but the number stays 1:1).
    Common.ShadowBox {
        id: selectorBox
        visible: row.monthKey === row.targetMonthKey && row.selectorOpacity > 0.001
        x: row.weekColWidth + row.selectorAnimX + 3
        y: row.selectorAnimY - row.weekIndex * row.cellSize + 3
        baseWidth: row.cellSize - 6
        baseHeight: row.cellSize - 6
        // Concentric-corner radius: the today box outside has radius 12.
        // When the selector compresses to scale s, each side insets by
        // (cellW * (1-s) / 2). For the selector's corner curve to trace a
        // line parallel to today's corner (i.e. look like a clean inset),
        // the selector's RENDERED radius must equal `12 - inset`. Because
        // Item.scale scales the painted radius uniformly, divide by s to
        // get the baseRadius that lands at that rendered value.
        // (rebound multiplier is excluded — bouncing the curvature too
        // would smear the shape, not just its size.)
        baseRadius: {
            let s = Math.max(0.001, row.selectorBaseScale);
            let cellW = row.cellSize - 6;
            return (12 - cellW * (1 - s) / 2) / s;
        }
        surfaceColor: row.todaySurfaceColor
        bevelColor: Qt.lighter(row.selectedFillColor, 1.18)
        shadowColor: Qt.darker(row.selectedFillColor, 1.4)
        backgroundColor: row.selectedFillColor
        bevelWidth: 1.5
        shadowWidth: 2
        transformOrigin: Item.Center
        scale: row.selectorScale
        opacity: row.selectorOpacity
        z: 2
    }

    // The cell the selector's animated centre currently sits over, in this
    // row's month. During a same-month glide the label swaps to match each
    // cell it sweeps; at rest it matches the text underneath exactly.
    readonly property int _selCol:
        Math.max(0, Math.min(6, Math.round(selectorAnimX / cellSize)))
    readonly property int _selRow:
        Math.max(0, Math.min(5, Math.round(selectorAnimY / cellSize)))
    readonly property date _selCoveredDate: {
        let dayOffset = _selRow * 7 + _selCol - _leadingBlanks;
        return new Date(year, month, 1 + dayOffset);
    }

    // Selector label — row-level sibling of the selector box, z=2 declared
    // AFTER the box so it paints on top. Not a child of the box, so its
    // size is independent of selectorScale (which compresses to 0.86 on
    // today and overshoots 1.7 during rebound). Opacity modulates with
    // both the hide-during-slide path (selectorOpacity) and the rebound
    // growth (selectorReboundScale), so it materialises alongside the box
    // but never shrinks with it. Row `clip: true` handles cross-week slice
    // the same way it does for the box.
    Text {
        visible: row.monthKey === row.targetMonthKey && row.selectorOpacity > 0.001
        x: row.weekColWidth + row.selectorAnimX + (row.cellSize - implicitWidth) / 2
        y: row.selectorAnimY - row.weekIndex * row.cellSize + 10
        z: 2
        text: row._selCoveredDate.getDate()
        font.pixelSize: 15
        font.family: row.fontFamily
        font.bold: row._sameDay(row._selCoveredDate, row.today)
        color: row.selectedTextColor
        opacity: row.selectorOpacity * Math.min(1, row.selectorReboundScale)
    }

    // ======================================================================
    // WEEK-NUMBER CELL
    // ======================================================================
    Item {
        id: wkCell
        x: 0
        y: 0
        width: row.weekColWidth
        height: row.cellSize
        z: 1

        readonly property date _firstCellDate:
            new Date(row.year, row.month, 1 - row._leadingBlanks + row.weekIndex * 7)
        readonly property int realWeek: row._isoWeek(_firstCellDate)
        readonly property int cellYear: _firstCellDate.getFullYear()
        readonly property var display: row.weekOffsetStore
            ? row.weekOffsetStore.displayedFor(cellYear, realWeek)
            : ({ value: realWeek, offset: false, real: realWeek })

        // The week number shares the day figures' ink centre (they sit at y 10, high in the cell to leave room for the marks below),
        // not the cell's middle: both baselines from their own metrics, each figure's centre half a cap height above its baseline.
        FontMetrics { id: dayMetrics; font.family: row.fontFamily; font.pixelSize: 15 }
        FontMetrics { id: weekMetrics; font.family: row.fontFamily; font.pixelSize: 12 }

        Column {
            x: (parent.width - width) / 2
            y: Math.round(10 + dayMetrics.ascent - dayMetrics.capitalHeight / 2
                          + weekMetrics.capitalHeight / 2 - weekMetrics.ascent)
            spacing: 0

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: wkCell.display.value
                font.pixelSize: 12
                font.family: row.fontFamily
                font.bold: wkCell.display.offset
                color: wkCell.display.offset
                    ? row.weekOffsetAccentColor
                    : row.weekNumColor
                opacity: wkCell.display.offset ? 1.0 : 0.8
            }

            Text {
                visible: wkCell.display.offset
                anchors.horizontalCenter: parent.horizontalCenter
                text: wkCell.display.real
                font.pixelSize: 8
                font.family: row.fontFamily
                color: row.weekNumColor
                opacity: 0.55
            }
        }

        MouseArea {
            anchors.fill: parent
            enabled: !!row.weekOffsetStore
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: row.weekOffsetStore.toggleOffset(wkCell.cellYear, wkCell.realWeek)
        }
    }

    // ======================================================================
    // 7 DAY CELLS
    // ======================================================================
    Repeater {
        model: 7
        delegate: Item {
            id: cell
            required property int index
            readonly property int col: cell.index
            readonly property date cellDate: row.cellDate(cell.col)
            readonly property bool inMonth: cell.cellDate.getMonth() === row.month
            readonly property bool isToday: row._sameDay(cell.cellDate, row.today)
            readonly property string dayStatus: row._dayStatus(cell.cellDate)
            // `covered` drives the "+" mark's colour flip. Only the target
            // month's tile can match (its neighbouring-month days included,
            // since the selector goes there too), and only while the global
            // selector's animated position is over this cell's midpoint.
            readonly property bool covered: {
                if (row.monthKey !== row.targetMonthKey) return false;
                // selectionLayer-local coords: x=0 at day-col 0, y=0 at week 0.
                let cellCX = cell.col * row.cellSize + row.cellSize / 2;
                let cellCY = row.weekIndex * row.cellSize + row.cellSize / 2;
                let selCX  = row.selectorAnimX + row.cellSize / 2;
                let selCY  = row.selectorAnimY + row.cellSize / 2;
                return Math.abs(cellCX - selCX) < row.cellSize / 2
                    && Math.abs(cellCY - selCY) < row.cellSize / 2;
            }

            x: row.weekColWidth + cell.col * row.cellSize
            y: 0
            width: row.cellSize
            height: row.cellSize
            z: 3

            // Day-number text is rendered in a separate z=1 layer above
            // so the selector at z=2 naturally covers it at the selected
            // cell. The cell itself carries only marks and the mouse
            // area at z=3.

            Item {
                id: marksArea
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 5
                height: 21

                readonly property real dotSize: 5
                readonly property real dotGap: 3
                readonly property real rowPitch: 7
                readonly property real rowWidth: 3 * dotSize + 2 * dotGap
                readonly property real rowLeftX: (width - rowWidth) / 2
                readonly property real lineH: dotSize + 2

                // The leading `_revision` read establishes a reactive dep
                // on the data source's revision counter. getMarksLayout is a
                // function call (no automatic dep tracking through it), and
                // its result is cached at source — so without this read,
                // bindings here wouldn't re-fire on visibility-toggle cache
                // invalidations and the grid would still paint hidden-cal
                // marks until the next viewMonth change.
                readonly property var layout: {
                    if (!row.calendarData)
                        return [];
                    const revision = row.calendarData._revision;
                    return revision >= 0
                        ? row.calendarData.getMarksLayout(cell.cellDate, row.year, row.month)
                        : [];
                }

                readonly property real cellOpacity:
                    !cell.inMonth ? 0.35
                    : cell.dayStatus === "before" ? 0.55 : 1.0

                Repeater {
                    model: 3
                    delegate: Item {
                        id: rowSlot
                        required property int index
                        readonly property var rd: marksArea.layout[index]
                        width: marksArea.width
                        height: marksArea.rowPitch
                        y: rowSlot.index * marksArea.rowPitch

                        Common.ShadowBox {
                            visible: !!(rowSlot.rd && rowSlot.rd.kind === "line")
                            readonly property var _ev: rowSlot.rd && rowSlot.rd.ev
                                ? rowSlot.rd.ev : null
                            readonly property bool _truncated: !!(rowSlot.rd && rowSlot.rd.truncated)
                            readonly property var _cal: _ev && row.calendarData
                                ? row.calendarData.calendarById(_ev.calendarId) : null
                            readonly property color _accent: _cal ? _cal.color : row.textColor

                            baseWidth: _truncated
                                ? (2 * marksArea.dotSize + marksArea.dotGap)
                                : marksArea.rowWidth
                            baseHeight: marksArea.lineH
                            baseRadius: marksArea.lineH
                            limitRadius: true
                            x: marksArea.rowLeftX
                                + (_truncated ? (marksArea.rowWidth - baseWidth) : 0)
                            y: (marksArea.rowPitch - baseHeight) / 2
                            surfaceColor: "transparent"
                            backgroundColor: _accent
                            bevelColor: Qt.darker(_accent, 1.8)
                            shadowColor: Qt.darker(_accent, 2.8)
                            bevelWidth: 0.5
                            shadowWidth: 2
                            stepSize: 1.0
                            curveProfile: 1.0
                            opacity: marksArea.cellOpacity
                        }

                        Item {
                            id: extraSlot
                            visible: !!(rowSlot.rd && rowSlot.rd.kind === "line"
                                && rowSlot.rd.truncated)
                            width: marksArea.dotSize + 1
                            height: marksArea.dotSize + 1
                            x: marksArea.rowLeftX
                            y: (marksArea.rowPitch - height) / 2

                            readonly property bool _isPlus: !!(rowSlot.rd && rowSlot.rd.extraPlus)
                            readonly property var _ev: rowSlot.rd ? rowSlot.rd.extraDot : null
                            readonly property var _cal: _ev && row.calendarData
                                ? row.calendarData.calendarById(_ev.calendarId) : null
                            readonly property color _dotColor: _cal ? _cal.color : row.textColor

                            opacity: marksArea.cellOpacity

                            Rectangle {
                                visible: !extraSlot._isPlus
                                x: 0.5; y: 1
                                width: marksArea.dotSize
                                height: marksArea.dotSize
                                radius: marksArea.dotSize / 2
                                color: "#000000"
                                opacity: 0.35
                            }
                            Rectangle {
                                x: 0; y: 0
                                width: marksArea.dotSize
                                height: marksArea.dotSize
                                radius: marksArea.dotSize / 2
                                color: extraSlot._isPlus ? "transparent" : extraSlot._dotColor

                                Text {
                                    visible: extraSlot._isPlus
                                    anchors.centerIn: parent
                                    text: "+"
                                    color: cell.covered ? row.selectedTextColor : row.textColor
                                    font.pixelSize: 10
                                    font.family: row.fontFamily
                                    font.bold: true
                                }
                            }
                        }

                        Repeater {
                            model: rowSlot.rd && rowSlot.rd.kind === "dots"
                                ? rowSlot.rd.count : 0
                            delegate: Item {
                                id: dot
                                required property int index
                                readonly property int _rowCount:
                                    rowSlot.rd ? rowSlot.rd.count : 0
                                readonly property var ev:
                                    rowSlot.rd ? rowSlot.rd.events[dot.index] : null
                                readonly property bool isOverflowSlot:
                                    !!(ev && ev.overflow)
                                readonly property var cal:
                                    ev && !isOverflowSlot && row.calendarData
                                        ? row.calendarData.calendarById(ev.calendarId)
                                        : null

                                readonly property real _thisRowW:
                                    _rowCount * marksArea.dotSize
                                    + (_rowCount - 1) * marksArea.dotGap
                                readonly property real _rowX:
                                    (marksArea.width - _thisRowW) / 2

                                width: marksArea.dotSize + 1
                                height: marksArea.dotSize + 1
                                x: _rowX + dot.index * (marksArea.dotSize + marksArea.dotGap)
                                y: (marksArea.rowPitch - height) / 2

                                property bool _ready: false
                                opacity: _ready ? marksArea.cellOpacity : 0
                                Component.onCompleted: _ready = true
                                Behavior on opacity {
                                    NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                                }

                                Rectangle {
                                    visible: !dot.isOverflowSlot
                                    x: 0.5; y: 1
                                    width: marksArea.dotSize
                                    height: marksArea.dotSize
                                    radius: marksArea.dotSize / 2
                                    color: "#000000"
                                    opacity: 0.35
                                }
                                Rectangle {
                                    x: 0; y: 0
                                    width: marksArea.dotSize
                                    height: marksArea.dotSize
                                    radius: marksArea.dotSize / 2
                                    color: dot.isOverflowSlot
                                        ? "transparent"
                                        : (dot.cal ? dot.cal.color : Theme.textPrimary)

                                    Text {
                                        visible: dot.isOverflowSlot
                                        anchors.centerIn: parent
                                        text: "+"
                                        color: cell.covered ? row.selectedTextColor : row.textColor
                                        font.pixelSize: 10
                                        font.family: row.fontFamily
                                        font.bold: true
                                    }
                                }
                            }
                        }
                    }
                }
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: row.daySelected(cell.cellDate)
            }
        }
    }
}
