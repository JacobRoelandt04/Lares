pragma ComponentBehavior: Bound

import QtQuick
import "../../common/components/Mix.js" as Mix
import "../../common/theme"
import QtQuick.Shapes
import "../../common/components" as Common
import ".."
import "EventIn.js" as EventIn

// =============================================================================
// AppointmentRow.qml
//
// Renders one event occurrence in the day's side panel. Supports single-day
// and multi-day events.
//
// Single-day layout matrix (collapsed / expanded × minimal / detailed):
//
//   Minimal  (no description or location):
//     collapsed:   HH:MM            [pill:dur] … title …
//     expanded:    HH:MM            [pill:dur]
//                    │
//                  HH:MM
//                  … title …
//
//   Detailed (has description and/or location):
//     collapsed:   HH:MM — HH:MM    [pill:dur] … title …
//     expanded:    HH:MM            [pill:dur]
//                    │
//                  HH:MM
//                  … title …
//                  [ details card ]
//
// Multi-day layout:
//
//   Pill shows dayIndex/totalDays (e.g. "0/3" on first day of a 3-day event).
//
//   First day (dayIndex === 0), timed:
//     collapsed:   HH:MM — DD MMM HH:MM  [pill:0/3] … title
//     expanded:    HH:MM                  [pill:0/3]
//                    │
//                  DD MMM HH:MM
//                  … title … / details
//
//   Non-first day: no times rendered. Pill still visible (day counter),
//   title still visible.
//
//   All-day multi-day: no times even on first day (allDay semantics).
//
// Pill X anchoring (the "cohesive" look):
//   Anchor positions derive from a hidden `timeMetric` Text sized to the
//   widest possible "HH:MM" string — so every row computes the SAME anchor
//   regardless of the specific time digits it renders. The pill never jitters
//   between rows by a sub-pixel Audiowide kerning difference.
//
//   - stackedPillX         : widest-time-block width + pillGap (used in expanded
//                            state, and for non-first multi-day rows)
//   - inlineDetailedPillX  : start + gap + endSlot + gap + end + pillGap
//                            (used while collapsed for every row that shows an
//                            end time inline: a detailed row, a timed multi-day
//                            first day)
//   Pill X is animated so such rows glide from inline → stacked on expand.
//
// THE PILL NEVER LEAVES ITS CONTAINER: a first day's "12:00 — 7 Jul 12:00" can be as wide as the row,
// and the pill, which stands after the text, would be pushed past the row's edge and culled ("1/4" cut at the right).
// The pill keeps the row's right edge as its limit; the END text yields -- it elides to the room
// between the dash and the pill (`endTime.width`). The pill's own width is never touched.
//
// THE EXPANDED CARD'S `in <time>` LINE sits in
// the same container as the description and `at`, under them, in their style: how long until
// the event begins (EventIn.js: "in 2 h 15 min"), or, once it began, "started 20 min ago" /
// "ended 3 h ago" / "ended 2 days ago" (never a date or a time of day). An all-day event has none. A row with no description and no place still
// opens its card for it (`_hasBody`). It ticks on the list's ONE BoundaryClock: the row asks
// for the instant its words change, while it is open, and the clock follows a suspend.
// =============================================================================
Item {
    id: row

    property var ev: null
    property var calendarData: null
    property bool showTime: true
    property bool expanded: false
    property string fontFamily: "Audiowide"
    // The wall clock, epoch ms, from the list's ONE BoundaryClock (0: no clock -- the stripe stays whole). It moves on the
    // minute boundaries somebody is showing and never in a binding of its own (CLAUDE.md: Date.now() in a binding captures nothing).
    property real nowMs: 0
    // That clock (a BoundaryClock): an open row asks it for the instant its `in <time>` words change. null: nothing ticks.
    property var clock: null

    property color textColor:    Theme.textPrimary
    property color mutedColor:   Theme.textFaint
    property color fainterColor: Mix.c(Theme.textFaint, Theme.surface, 0.5)

    property int  animDuration: 240
    property int  animEasing: Easing.InOutCubic
    // Fraction of the expansion that must elapse before the revealed details
    // start fading in. Without the hold the text appears before there is room
    // for it, which reads as it arriving early.
    property real textRevealStart: 0.35

    readonly property var _cal: ev && calendarData
        ? calendarData.calendarById(ev.calendarId) : null
    readonly property bool _hasDetails:
        !!(ev && (ev.description || ev.location))
    // The `in <time>` line: { label, text, nextMs } or null (all day, or no clock to count from).
    function _inNow() {
        if (!row.ev || !row.ev.start || row.nowMs <= 0)
            return null;
        return EventIn.line(row.ev.start.getTime(), row.ev.end ? row.ev.end.getTime() : NaN, row.ev.allDay === true, row.nowMs);
    }
    readonly property var _in: row._inNow()
    readonly property bool _hasIn: row._in !== null
    // Something to open: a description, a place, or the time to go.
    readonly property bool _hasBody: row._hasDetails || row._hasIn
    // Asked from the handlers below, which read `nowMs` itself: a handler runs before the bindings that follow its property.
    function _askClock() {
        if (!row.clock || !row.expanded)
            return;
        const l = row._inNow();
        if (l !== null)
            row.clock.request(l.nextMs);
    }
    onNowMsChanged: row._askClock()
    onExpandedChanged: {
        // the list's clock may be minutes behind the wall (it moves only on a boundary somebody asked for): an instant already past
        // is due, and the clock publishes the wall on its next tick
        if (row.expanded && row.clock)
            row.clock.request(0);
        row._askClock();
    }
    readonly property color _accentColor: _cal ? _cal.color : Theme.textPrimary

    // Multi-day state
    readonly property bool _isMultiDay: !!(ev && ev.totalDays && ev.totalDays > 1)
    readonly property bool _isFirstDay: _isMultiDay && ev && ev.dayIndex === 0
    readonly property bool _isAllDay: !!(ev && ev.allDay)

    // Should the time block render any time glyphs at all on this day?
    readonly property bool _showTimes:
        showTime
        && !_isAllDay
        && (!_isMultiDay || _isFirstDay)

    // End-time visibility (within timeBlock):
    //  - multi-day first day timed: always (with date)
    //  - single-day detailed: inline always, stacked when expanded
    //  - single-day minimal: only when expanded
    readonly property bool _showEnd:
        _showTimes && (
            _isMultiDay
            ? _isFirstDay
            : (_hasDetails || expanded)
        )

    readonly property bool _stackedTime: expanded

    readonly property bool _pillVisible:
        !!ev && (_isMultiDay || !_isAllDay)

    readonly property real _detailsTarget:
        expanded && _hasBody ? detailsCol.implicitHeight + 16 : 0

    // Unified 0 → 1 expand fraction — animated in lock-step with every
    // expand-triggered value so X, Y, width, height, text-block geometry,
    // and the duration pill's base anchor all lerp together with no
    // Behavior-on-binding cascade lag. A pill x that flipped its target
    // property DISCRETELY on expand, with its own Behavior chasing the
    // continuously-changing binding from endTime.x, would produce a ~250ms
    // "pill waits for everything else" lag.
    property real _expandFraction: expanded ? 1 : 0
    Behavior on _expandFraction {
        NumberAnimation { duration: row.animDuration; easing.type: row.animEasing }
    }

    implicitHeight: baseCol.implicitHeight + detailsClip.height + 10

    readonly property int _padLeft: 12
    readonly property int _titleSize: 14
    readonly property int _metaSize: 12

    readonly property real _inlineGap: 4
    readonly property real _endSlotPad: 10
    readonly property real _stackedGap: 14
    readonly property real _pillGap: 10

    // Hidden width-metric for time text — every row uses this so anchor X's
    // are identical across rows regardless of digit kerning.
    Text {
        id: timeMetric
        visible: false
        text: "23:59"
        font.pixelSize: row._metaSize
        font.family: row.fontFamily
    }
    Text {
        id: dateTimeMetric
        visible: false
        text: "30 Sep 23:59"
        font.pixelSize: row._metaSize
        font.family: row.fontFamily
    }

    readonly property real _timeW: timeMetric.implicitWidth
    readonly property real _dateTimeW: dateTimeMetric.implicitWidth
    readonly property real _inlineEndW:
        (_isMultiDay && _isFirstDay) ? _dateTimeW : _timeW
    // The end time is inline (beside the start) while collapsed: a detailed row, a timed multi-day first day.
    readonly property bool _endInlineCollapsed:
        _showTimes && (_isMultiDay ? _isFirstDay : _hasDetails)
    // The widest of the stacked block (the metric, so every multi-day row agrees): the pill stands after it once expanded.
    readonly property real _stackW: Math.max(_timeW, _inlineEndW)

    // Three anchor classes:
    //   _leftAlignedX       — for rows with no time text (non-first multi-day,
    //                         all-day multi-day, etc.). Pill hugs the left.
    //   _detailedCollapsedX — detailed rows while collapsed (inline layout).
    //   _baseX              — everything else (minimal rows always, any row
    //                         while expanded, non-first multi-day rows).
    readonly property real _leftAlignedX: 0
    readonly property real _detailedCollapsedX:
        _timeW + _inlineGap + _endSlotPad + _inlineGap + _inlineEndW + _pillGap
    readonly property real _baseX:
        _timeW + (_stackW - _timeW) * _expandFraction + _pillGap

    // --- Coloured left stripe (tracks implicit height) ---
    //
    // THE STRIPE IS THE TIME LEFT. Of an event that is on today the stripe is erased
    // from the top as the event goes by -- what is still coloured is the time remaining -- and an event of today that is over
    // stays burned out. Events of other days (days before today have no progress to show, days after have not begun) keep the
    // whole colour. It is a fraction of the stripe's length, so an expanded row, whose stripe is longer, erases the same share.
    //
    // The occurrence's own day is read from the event (its first day plus the dayIndex), not from what the list shows, so a row
    // sliding out under a day change keeps its own answer. An all-day event has no time to run out: whole. A multi-day event runs
    // from its start to its end across its days: on today's row the share is the whole event's.
    readonly property real _dayStartMs: {
        if (!row.ev || !row.ev.start)
            return 0;
        const d = new Date(row.ev.start.getFullYear(), row.ev.start.getMonth(), row.ev.start.getDate() + (row.ev.dayIndex || 0));
        return d.getTime();
    }
    readonly property real _todayStartMs: {
        if (row.nowMs <= 0)
            return 0;
        const n = new Date(row.nowMs);
        return new Date(n.getFullYear(), n.getMonth(), n.getDate()).getTime();
    }
    // The share of the stripe that is still coloured: 1 whole, 0 burned out.
    readonly property real _remaining: {
        if (!row.ev || !row.ev.start || !row.ev.end || row.ev.allDay || row.nowMs <= 0 || row._dayStartMs !== row._todayStartMs)
            return 1;
        const s = row.ev.start.getTime(), e = row.ev.end.getTime();
        if (row.nowMs <= s)
            return 1;
        if (row.nowMs >= e)
            return 0;
        return (e - row.nowMs) / (e - s);
    }
    ProgressStripe {
        id: stripe
        objectName: "apptStripe"
        x: 0
        y: 4
        width: 3
        height: row.implicitHeight - 8
        color: row._accentColor
        fill: row._remaining
        fromBottom: true
    }

    Column {
        id: baseCol
        x: row._padLeft
        y: 4
        width: row.width - row._padLeft
        spacing: 3

        Item {
            id: metaRow
            visible: row._pillVisible
            width: parent.width
            height: Math.max(
                row._showTimes ? timeBlock.height : 0,
                durationPill.visible ? durationPill.height : 0)

            Item {
                id: timeBlock
                x: 0
                y: 0
                visible: row._showTimes
                opacity: visible ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: row.animDuration; easing.type: row.animEasing } }

                readonly property real lineH: startTime.implicitHeight
                // stacked, the two lines are centred on each other in the wider one's width (a "7 Jul 12:00" under a "12:00"
                // began left of the block and over the stripe); inline, the end follows the start
                readonly property real _stackedW: Math.max(startTime.implicitWidth, endTime.implicitWidth)
                readonly property real _sX: row._stackedTime ? (_stackedW - startTime.implicitWidth) / 2 : 0
                readonly property real _eX: row._stackedTime
                    ? (_stackedW - endTime.implicitWidth) / 2
                    : (startTime.implicitWidth + row._inlineGap + row._endSlotPad + row._inlineGap)
                readonly property real _eY: row._stackedTime
                    ? (lineH + row._stackedGap)
                    : 0

                width: row._stackedTime
                    ? timeBlock._stackedW
                    : (startTime.implicitWidth + (row._showEnd
                        ? (row._inlineGap + row._endSlotPad + row._inlineGap + endTime.width)
                        : 0))
                height: row._stackedTime
                    ? (2 * lineH + row._stackedGap)
                    : lineH

                Behavior on width  { NumberAnimation { duration: row.animDuration; easing.type: row.animEasing } }
                Behavior on height { NumberAnimation { duration: row.animDuration; easing.type: row.animEasing } }

                Text {
                    id: startTime
                    objectName: "apptStart"
                    text: row.ev && row._showTimes ? row._fmtTime(row.ev.start) : ""
                    color: row.mutedColor
                    font.pixelSize: row._metaSize
                    font.family: row.fontFamily
                    x: timeBlock._sX
                    y: 0
                    Behavior on x { NumberAnimation { duration: row.animDuration; easing.type: row.animEasing } }
                }

                Text {
                    id: endTime
                    objectName: "apptEnd"
                    visible: row._showEnd
                    opacity: visible ? 1 : 0
                    text: row.ev
                        ? (row._isMultiDay
                            ? row._fmtDateTime(row.ev.end)
                            : row._fmtTime(row.ev.end))
                        : ""
                    color: row.mutedColor
                    font.pixelSize: row._metaSize
                    font.family: row.fontFamily
                    // THE END YIELDS to the pill: inline it takes what is left between the dash and the pill (the pill stands
                    // where it fits or at the row's edge, never past it), and elides. The room is read from the pill's place and
                    // the text's own advance (`endMetrics`): the pill's place reads the full advance, never this width.
                    elide: Text.ElideRight
                    width: row._stackedTime ? endMetrics.advanceWidth
                        : Math.max(0, Math.min(endMetrics.advanceWidth, durationPill.x - durationPill._overlapSafety - x))
                    x: timeBlock._eX
                    y: timeBlock._eY
                    Behavior on x { NumberAnimation { duration: row.animDuration; easing.type: row.animEasing } }
                    Behavior on y { NumberAnimation { duration: row.animDuration; easing.type: row.animEasing } }
                    Behavior on opacity { NumberAnimation { duration: row.animDuration; easing.type: row.animEasing } }
                }

                // AA separator line between start- and end-time centres.
                Shape {
                    id: sepShape
                    anchors.fill: parent
                    antialiasing: true
                    preferredRendererType: Shape.CurveRenderer
                    opacity: row._showEnd ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: row.animDuration; easing.type: row.animEasing } }

                    readonly property real smallGap: 3
                    readonly property real sCX: startTime.x + startTime.implicitWidth / 2
                    readonly property real sCY: startTime.y + startTime.implicitHeight / 2
                    readonly property real eCX: endTime.x + endTime.width / 2
                    readonly property real eCY: endTime.y + endTime.implicitHeight / 2
                    readonly property real _dx: eCX - sCX
                    readonly property real _dy: eCY - sCY
                    readonly property real _len: Math.sqrt(_dx * _dx + _dy * _dy)
                    readonly property real _ux: _len > 0.01 ? _dx / _len : 0
                    readonly property real _uy: _len > 0.01 ? _dy / _len : 0
                    readonly property real sPad:
                        Math.abs(_ux) * (startTime.implicitWidth / 2)
                      + Math.abs(_uy) * (startTime.implicitHeight / 2)
                      + smallGap
                    readonly property real ePad:
                        Math.abs(_ux) * (endTime.width / 2)
                      + Math.abs(_uy) * (endTime.implicitHeight / 2)
                      + smallGap
                    readonly property real p1x: sCX + _ux * sPad
                    readonly property real p1y: sCY + _uy * sPad
                    readonly property real p2x: eCX - _ux * ePad
                    readonly property real p2y: eCY - _uy * ePad

                    ShapePath {
                        strokeColor: row.mutedColor
                        strokeWidth: 1.25
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        joinStyle: ShapePath.RoundJoin
                        startX: sepShape.p1x
                        startY: sepShape.p1y
                        PathLine {
                            x: sepShape.p2x
                            y: sepShape.p2y
                        }
                    }
                }
            }

            // --- Duration pill ---
            Rectangle {
                id: durationPill
                objectName: "apptPill"
                visible: row._pillVisible
                height: durationText.implicitHeight + 4
                width: durationText.implicitWidth + 12
                radius: height / 2

                // _baseTarget lerps smoothly from _detailedCollapsedX (collapsed)
                // to _baseX (expanded) via _expandFraction, so the pill's X
                // moves in lock-step with the rest of the expansion. No
                // Behavior on pill.x — the binding itself is already smooth.
                readonly property real _baseTarget:
                    !row._showTimes
                        ? row._leftAlignedX
                        : (row._endInlineCollapsed
                            ? (row._detailedCollapsedX * (1 - row._expandFraction)
                                + row._baseX * row._expandFraction)
                            : row._baseX)

                readonly property real _overlapSafety: 6
                readonly property real _textRight:
                    row._showTimes
                        ? (timeBlock.x + (row._showEnd
                            ? (endTime.x + endMetrics.advanceWidth)
                            : startTime.implicitWidth))
                        : 0
                // Overlap nudge only acts for detailed rows (where the end
                // text really can extend far enough to clash with the pill,
                // e.g. a multi-day first-day's "DD MMM HH:MM"). For minimal
                // rows the pill stays vertically locked on expand, and the
                // X never shifts — end-time's in-flight x from 56 to 0 must
                // not drag the pill rightward mid-expansion.
                readonly property real _overlapOffset:
                    row._endInlineCollapsed
                        ? Math.max(0, _textRight + _overlapSafety - _baseTarget)
                        : 0

                // The row's right edge is the limit: past it the pill is culled (see the header). What yields is the end text.
                x: Math.max(0, Math.min(_baseTarget + _overlapOffset, metaRow.width - width))

                anchors.verticalCenter: parent.verticalCenter

                color: Qt.rgba(row._accentColor.r, row._accentColor.g, row._accentColor.b, 0.16)
                border.color: Qt.rgba(row._accentColor.r, row._accentColor.g, row._accentColor.b, 0.35)
                border.width: 1

                Text {
                    id: durationText
                    anchors.centerIn: parent
                    text: row.ev
                        ? (row._isMultiDay
                            ? ((row.ev.dayIndex + 1) + "/" + row.ev.totalDays)
                            : row._fmtDuration(row.ev.start, row.ev.end))
                        : ""
                    color: row._accentColor
                    font.pixelSize: row._metaSize - 2
                    font.family: row.fontFamily
                    font.bold: true
                }
            }
        }

        // Title. Its width reserves 14 px for the "has details" chevron
        // (below, on the row itself) so the two never overlap.
        Item {
            width: parent.width
            implicitHeight: titleText.implicitHeight

            Text {
                id: titleText
                text: row.ev ? row.ev.title : ""
                color: row.textColor
                font.pixelSize: row._titleSize
                font.family: row.fontFamily
                font.bold: true
                wrapMode: Text.Wrap
                anchors.left: parent.left
                anchors.top: parent.top
                width: parent.width - (row._hasBody ? 14 : 0)
            }

        }
    }

    // The "has details" chevron, turning over as the row opens. It is pinned
    // to the ROW, not to the title: expanding stacks the times and pushes the
    // title down, and a chevron riding on the title would move with every frame
    // of that. It sits at the right edge, level with where the title's first
    // line is while the row is collapsed -- a place computed from the
    // collapsed metrics, so it never moves.
    readonly property real _collapsedMetaH: row._pillVisible
        ? Math.max(row._showTimes ? timeBlock.lineH : 0, durationPill.visible ? durationPill.height : 0)
        : 0
    Common.Chevron {
        id: expandIndicator
        objectName: "apptChevron"
        visible: row._hasBody
        x: Math.round(row.width - width)
        y: Math.round(baseCol.y + row._collapsedMetaH + (row._pillVisible ? baseCol.spacing : 0)
                      + (titleMetrics.height - height) / 2)
        color: Qt.rgba(row._accentColor.r, row._accentColor.g, row._accentColor.b, 0.75)
        rotation: row._expandFraction * 180
    }
    FontMetrics {
        id: titleMetrics
        font: titleText.font
    }

    TextMetrics {
        id: endMetrics
        text: row.ev ? (row._isMultiDay ? row._fmtDateTime(row.ev.end) : row._fmtTime(row.ev.end)) : ""
        font.pixelSize: row._metaSize
        font.family: row.fontFamily
    }

    Item {
        id: detailsClip
        x: row._padLeft
        anchors.top: baseCol.bottom
        anchors.topMargin: 4
        width: row.width - row._padLeft - 4
        height: row._detailsTarget
        clip: true
        opacity: Math.max(0, Math.min(1,
            (row._expandFraction - row.textRevealStart) / (1 - row.textRevealStart)))

        Behavior on height {
            NumberAnimation { duration: row.animDuration; easing.type: row.animEasing }
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: 3
            radius: 8
            color: Qt.rgba(row._accentColor.r, row._accentColor.g, row._accentColor.b, 0.08)
            border.color: Qt.rgba(row._accentColor.r, row._accentColor.g, row._accentColor.b, 0.22)
            border.width: 1
            visible: row._hasBody
        }

        Column {
            id: detailsCol
            width: parent.width - 20
            x: 10
            y: 8
            spacing: 6

            Row {
                visible: !!(row.ev && row.ev.description)
                width: parent.width
                spacing: 6
                Rectangle {
                    width: 3; height: 3; radius: 1
                    color: row._accentColor
                    anchors.verticalCenter: descText.verticalCenter
                }
                Text {
                    id: descText
                    text: row.ev ? row.ev.description : ""
                    color: row.mutedColor
                    font.pixelSize: 12
                    font.family: row.fontFamily
                    wrapMode: Text.Wrap
                    width: parent.width - 9
                }
            }

            Row {
                visible: !!(row.ev && row.ev.location)
                width: parent.width
                spacing: 6
                Text {
                    text: "at"
                    color: row._accentColor
                    font.pixelSize: 11
                    font.family: row.fontFamily
                    font.italic: true
                    anchors.verticalCenter: locText.verticalCenter
                }
                Text {
                    id: locText
                    text: row.ev ? row.ev.location : ""
                    color: row.fainterColor
                    font.pixelSize: 12
                    font.family: row.fontFamily
                    font.italic: true
                    wrapMode: Text.Wrap
                    width: parent.width - 24
                }
            }

            // How long until it begins ("in 2 h 15 min"), or since it began / ended: the `at` row's own style, under it,
            // and there with no place too. None for an all-day event (`_hasIn`).
            Row {
                visible: row._hasIn
                width: parent.width
                spacing: 6
                Text {
                    text: row._in ? row._in.label : ""
                    color: row._accentColor
                    font.pixelSize: 11
                    font.family: row.fontFamily
                    font.italic: true
                    anchors.verticalCenter: inText.verticalCenter
                }
                Text {
                    id: inText
                    objectName: "apptIn"
                    text: row._in ? row._in.text : ""
                    color: row.fainterColor
                    font.pixelSize: 12
                    font.family: row.fontFamily
                    font.italic: true
                }
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: row.expanded = !row.expanded
    }

    // ======================================================================
    // Formatters
    // ======================================================================
    function _fmtTime(d) {
        if (!d) return "";
        let h = d.getHours(), m = d.getMinutes();
        return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m;
    }
    function _fmtDateTime(d) {
        if (!d) return "";
        let months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
        return d.getDate() + " " + months[d.getMonth()] + " " + _fmtTime(d);
    }
    function _fmtDuration(start, end) {
        if (!start || !end) return "";
        let ms = end.getTime() - start.getTime();
        if (ms <= 0) return "";
        let mins = Math.round(ms / 60000);
        if (mins < 60) return mins + "m";
        let h = Math.floor(mins / 60);
        let m = mins % 60;
        return m === 0 ? h + "h" : h + "h " + m + "m";
    }
}
