pragma ComponentBehavior: Bound

import QtQuick
import "../../common/components/Mix.js" as Mix
import "../../common/theme"
import QtQml.Models
import "../../common/components" as Common

// =============================================================================
// AppointmentList.qml
//
// Side panel for the selected day. Header (weekday + date subtitle) is
// pinned; everything below scrolls inside a Flickable. On day change, rows
// slide OUT to the right (top-to-bottom stagger) while the new day's rows
// simultaneously slide IN from the left (same stagger) — so there is no
// wait-and-see delay when swapping between two populated days. Both
// trajectories are clipped to the scroll area (never visually leak out over
// the calendar grid).
//
// Section headers ("All day" / "Schedule") are intentionally absent here:
// each row already carries enough signal (time glyphs vs no-time, pill
// content, stripe color) that headers were redundant, and they'd need their
// own slide choreography to participate cleanly in the stagger. Sort order
// (multi-day → all-day single → timed single, per getEventsForDay) still
// groups them naturally.
// =============================================================================
Item {
    id: root

    property var calendarData: null
    property date day: new Date()

    // CalendarVisibilityStore — drives the per-calendar show/hide UI in the
    // expandable header. Toggling a calendar there mutates the store's
    // hiddenList; ClockPopupContent fans that down into calendarData where
    // the actual event filtering happens (cache bust + revision bump). This
    // panel only needs the store to render the checkbox state.
    property var visibilityStore: null

    // When the calendar is mid-slide, rapid intermediate `day` changes
    // (one per retarget in a burst) would each trigger a full ListModel
    // teardown + rebuild + delegate churn. Gating the rebuild on this
    // flag lets the caller (ClockPopupContent → cal._slideActive) suppress
    // intermediate rebuilds and fire only once the slide settles on the
    // final day — visually nothing to see while the selector is hidden
    // anyway, and the burst cost drops from N rebuilds to 1.
    property bool slideActive: false

    // Header expansion (calendar visibility panel). Slides a panel down
    // OVER the appointment area when the header is clicked. Independent
    // of day-changes; persists across day swaps within a session.
    property bool _headerExpanded: false
    property real _headerExtent: _headerExpanded ? 1 : 0
    Behavior on _headerExtent {
        NumberAnimation { duration: 240; easing.type: Easing.InOutCubic }
    }

    property color textColor:     Theme.textPrimary
    property color mutedColor:    Theme.textFaint
    property color fainterColor:  Mix.c(Theme.textFaint, Theme.surface, 0.5)

    property color surfaceColor:    Theme.surface
    property color backgroundColor: Theme.panelSunk
    property color bevelColor:      Theme.bevel
    property color shadowColor:     Theme.shadowDeep

    property string fontFamily: "Audiowide"

    // The panel's own margins, for a host that puts something of its own on it
    // (the wiki's tear-off stands on the same 14 px sides).
    readonly property real sideInset: 14
    readonly property real bodyFoot: 10
    // Room the host keeps at the panel's foot beyond `bodyFoot`: the scroll
    // area, its fades and the visibility overlay all end above it. 0 reserves
    // nothing.
    property real footReserve: 0

    property int animDuration: 240
    property int animStaggerMs: 55
    // Depth of the dissolve on each side of the visibility panel's moving
    // edge (SeamFade's band, as the LLM folds use it).
    property real seamFadeHeight: 42

    implicitWidth: 260
    implicitHeight: 420

    function _weekday(d) {
        return ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"][d.getDay()];
    }
    function _monthDay(d) {
        return ["January","February","March","April","May","June",
                "July","August","September","October","November","December"][d.getMonth()]
            + " " + d.getDate();
    }

    // ------------------------------------------------------------------
    // Panel ShadowBox
    // ------------------------------------------------------------------
    Common.ShadowBox {
        id: panel
        anchors.fill: parent
        baseWidth: width
        baseHeight: height
        baseRadius: 16
        surfaceColor: root.surfaceColor
        backgroundColor: root.backgroundColor
        bevelColor: root.bevelColor
        shadowColor: root.shadowColor
        bevelWidth: 2
        shadowWidth: 6
    }

    // ------------------------------------------------------------------
    // Header (pinned). Click anywhere on the header to toggle the
    // calendar-visibility panel (overlays the appointment area). Chevron
    // affordance is identical to the per-row expand cue in AppointmentRow,
    // and rotates 180° as the panel opens.
    // ------------------------------------------------------------------
    Column {
        id: headerBlock
        x: 14
        y: 12
        width: parent.width - 28 - 18    // reserve space for chevron
        spacing: -2

        Text {
            text: root._weekday(root.day)
            color: root.textColor
            font.pixelSize: 22
            font.family: root.fontFamily
            font.bold: true
            width: parent.width
            elide: Text.ElideRight
        }
        Text {
            text: root._monthDay(root.day)
            color: root.mutedColor
            font.pixelSize: 13
            font.family: root.fontFamily
            width: parent.width
        }
    }

    Common.Chevron {
        id: headerChevron
        x: Math.round(parent.width - 14 - width)
        y: Math.round(headerBlock.y + (headerBlock.height - height) / 2)
        color: root.mutedColor
        rotation: root._headerExtent * 180
    }

    MouseArea {
        id: headerClickArea
        x: 14
        y: headerBlock.y - 4
        width: parent.width - 28
        height: headerBlock.height + 8
        cursorShape: Qt.PointingHandCursor
        onClicked: root._headerExpanded = !root._headerExpanded
        z: 5    // above the headerBlock children but below the overlay
    }

    Rectangle {
        id: separator
        x: 14
        width: parent.width - 28
        anchors.top: headerBlock.bottom
        anchors.topMargin: 8
        height: 1
        color: root.fainterColor
        opacity: 0.4
    }

    // ------------------------------------------------------------------
    // Scrollable body
    // ------------------------------------------------------------------
    Flickable {
        id: scrollArea
        x: root.sideInset
        anchors.top: separator.bottom
        anchors.topMargin: 6
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.bodyFoot + root.footReserve
        width: parent.width - 2 * root.sideInset
        clip: true
        // ONE reader of the wheel, the shell's feel (modules/common/scroll): a
        // Flickable that is interactive reads it too, at Qt's own speed.
        interactive: false
        boundsBehavior: Flickable.StopAtBounds

        contentWidth: width
        contentHeight: listCol.implicitHeight

        Column {
            id: listCol
            width: scrollArea.width
            // Spacing lives inside each AnimatedAppointmentRow wrapper
            // (virtualSpacing) so collapsing a leaving row also collapses
            // its spacing contribution. With Column.spacing > 0 a collapsed
            // row would still reserve its 6 px, producing a visible step at the
            // end of the slide-up drift.
            spacing: 0

            // No `move` Transition. Column re-lays out its children frame-
            // by-frame as implicitHeights change; this gives rows-below-an-
            // expanding-row their y updates immediately, instead of chasing
            // a 240ms Transition that re-targets every frame the expanding
            // row's height grows. Leaving rows collapse their height via a
            // Behavior on implicitHeight (gated to rowState==="leaving"),
            // which the Column's frame-by-frame layout then smoothly
            // propagates upward to the entering rows.

            Repeater {
                id: rowRepeater
                model: listModel
                delegate: AnimatedAppointmentRow {
                    required property int index
                    required property var model
                    width: listCol.width
                    evData: model.evData
                    rowState: model.rowState
                    staggerIdx: model.staggerIdx
                    calendarData: root.calendarData
                    fontFamily: root.fontFamily
                    nowMs: root.nowMs
                    clock: eventClock
                    animDuration: root.animDuration
                    staggerMs: root.animStaggerMs
                }
            }

            // Empty state — fades with scroll fades handled naturally.
            Text {
                visible: root._currentEventCount === 0 && listModel.count === 0
                width: parent.width
                text: "No appointments"
                // the shell's empty words: upright body text in the faint ink (the only italic 13 px one was this)
                color: root.mutedColor
                font.pixelSize: 12
                font.family: root.fontFamily
                horizontalAlignment: Text.AlignHCenter
                topPadding: 24
            }

            // A feed that failed is said, not left looking like an empty calendar; the other calendars' events stay above.
            // The collapse is the wrapper's (the condition, never `visible`): a height bound on the Text itself to its own
            // implicitHeight looped ("Binding loop detected for property height", found by tools/dev/calendar_failed_probe.qml).
            Item {
                id: failedLine
                readonly property var _failed: root.calendarData && root.calendarData.failedFeeds ? root.calendarData.failedFeeds : []
                visible: failedLine._failed.length > 0
                width: parent.width
                height: failedLine._failed.length > 0 ? failedText.implicitHeight : 0
                Text {
                    id: failedText
                    width: parent.width
                    topPadding: 10
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                    color: Theme.warn
                    font.pixelSize: 12
                    font.family: root.fontFamily
                    text: {
                        const names = [];
                        let offline = false;
                        for (const f of failedLine._failed) {
                            names.push(f.name);
                            offline = offline || /curl exit/.test(f.reason);
                        }
                        return "Could not load " + names.join(", ") + (offline ? " (no connection)" : " (the feed could not be read)");
                    }
                }
            }
        }
    }

    // A glide or a coast is under way in the list or in the calendars panel (a probe waits for it).
    readonly property bool scrolling: listDressing.moving || visDressing.moving

    // ------------------------------------------------------------------
    // The shell's scroll dressing: the one feel (a notch glides, the fingers
    // follow and coast after the lift; a reader above the list taking no
    // button and no hover, so the rows keep theirs) and the two edge fades,
    // each as far on as the content runs past its end, sealed to the clip's
    // device pixels (ScrollDressing).
    // ------------------------------------------------------------------
    Common.ScrollDressing {
        id: listDressing
        anchors.fill: scrollArea
        flick: scrollArea
        ground: root.backgroundColor
        fadeHeight: 16
    }

    // ------------------------------------------------------------------
    // Calendar-visibility overlay
    //
    // Covers the appointment scroll area when the header is expanded.
    // Background matches the panel surface so the appointments behind
    // are masked, never bleeding through. Inner Flickable hosts a
    // checkbox row per imported calendar; long lists scroll with the
    // same top/bottom fades as the appointment list.
    // ------------------------------------------------------------------
    Item {
        id: visOverlay
        x: scrollArea.x
        y: scrollArea.y
        width: scrollArea.width
        height: root._headerExtent * scrollArea.height
        clip: true
        visible: height > 0.5
        z: 10

        Rectangle {
            anchors.fill: parent
            color: root.backgroundColor
        }

        Flickable {
            id: visFlick
            anchors.fill: parent
            clip: true
            interactive: false      // the wheel has one reader: visDressing, below
            boundsBehavior: Flickable.StopAtBounds
            contentWidth: width
            contentHeight: visCol.implicitHeight

            Column {
                id: visCol
                width: visFlick.width
                topPadding: 4
                spacing: 0

                Repeater {
                    model: root.calendarData ? root.calendarData.calendars : []
                    delegate: Item {
                        id: calRow
                        required property var modelData
                        required property int index
                        width: visCol.width
                        height: 36

                        // Bind directly to hiddenList (not isHidden(): function
                        // calls don't establish QML deps). The inline scan is
                        // cheap — only fires when hiddenList changes.
                        readonly property bool _hidden: {
                            if (!root.visibilityStore) return false;
                            let h = root.visibilityStore.hiddenList;
                            for (let i = 0; i < h.length; i++) {
                                if (h[i] === calRow.modelData.id) return true;
                            }
                            return false;
                        }
                        readonly property color _calColor:
                            calRow.modelData && calRow.modelData.color
                                ? calRow.modelData.color
                                : root.textColor

                        Rectangle {
                            id: checkBox
                            x: 6
                            anchors.verticalCenter: parent.verticalCenter
                            width: 18
                            height: 18
                            radius: 5
                            // The fill comes and goes as a FRACTION: a colour
                            // Behavior would also chase the theme's crossfade.
                            property real _fillF: calRow._hidden ? 0 : 1
                            Behavior on _fillF { NumberAnimation { duration: 160 } }
                            color: Qt.rgba(calRow._calColor.r, calRow._calColor.g, calRow._calColor.b,
                                           calRow._calColor.a * checkBox._fillF)
                            border.color: calRow._calColor
                            border.width: 2

                            Text {
                                visible: !calRow._hidden
                                anchors.centerIn: parent
                                text: "✓"
                                color: "#FFFFFF"
                                font.pixelSize: 12
                                font.family: root.fontFamily
                                font.bold: true
                            }
                        }

                        Text {
                            x: checkBox.x + checkBox.width + 10
                            anchors.verticalCenter: parent.verticalCenter
                            text: calRow.modelData.name || ""
                            color: root.textColor
                            font.pixelSize: 13
                            font.family: root.fontFamily
                            opacity: calRow._hidden ? 0.55 : 1.0
                            Behavior on opacity { NumberAnimation { duration: 160 } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (root.visibilityStore)
                                    root.visibilityStore.toggle(calRow.modelData.id);
                            }
                        }
                    }
                }

                // Bottom separator — sits at end of the calendar list so the
                // expanded content is visually bracketed by two rules (the
                // pinned top separator + this one). Lives inside visCol so
                // its y always tracks the content's tail edge: short list →
                // visible at content end with mask continuing below; long
                // list (overflow) → scrolls in with the content. The mask
                // Rectangle behind still extends to the overlay floor either
                // way, so appointments stay fully hidden.
                Item { width: visCol.width; height: 6 }
                Rectangle {
                    width: visCol.width
                    height: 1
                    color: root.fainterColor
                    opacity: 0.4
                }
            }
        }

        // The panel's own side of its moving edge: its rows dissolve into
        // the ground as they reach it, instead of being cut by the clip.
        Common.SeamFade {
            extent: root._headerExtent
            ground: root.backgroundColor
            fadeHeight: root.seamFadeHeight
        }

        // The calendars' own dressing (the wheel's one reader, the fades), over the seam's fade as the bands were.
        Common.ScrollDressing {
            id: visDressing
            anchors.fill: visFlick
            flick: visFlick
            ground: root.backgroundColor
            fadeHeight: 16
        }

    }

    // The appointments' side of the same edge: under the panel's foot they
    // fade in from the ground, so the edge sweeping down over them is a
    // dissolve on both sides rather than a line cutting their text. Clipped
    // to the list, so the band never paints past the list's own foot.
    Item {
        x: scrollArea.x
        y: visOverlay.y + visOverlay.height
        width: scrollArea.width
        height: Math.max(0, Math.min(root.seamFadeHeight, scrollArea.y + scrollArea.height - y))
        clip: true
        z: 10
        visible: visOverlay.visible && height > 0

        Common.SeamFade {
            edge: Qt.TopEdge
            extent: root._headerExtent
            ground: root.backgroundColor
            fadeHeight: root.seamFadeHeight
        }
    }

    // ==================================================================
    // THE EVENTS' TIME LEFT. The rows' stripes are gauges (AppointmentRow): this
    // list owns the ONE clock they read, a BoundaryClock that wakes only when something on show can change -- the start of an
    // event not yet begun, the next minute while one is in progress, midnight for a later day's rows (which are today's from then
    // on) -- and never when every row on show is over or a day other than today's. It runs while the list is on screen.
    // ==================================================================
    readonly property real nowMs: eventClock.now
    Common.BoundaryClock {
        id: eventClock
    }
    function _askEventClock() {
        const now = eventClock.now;
        const n = new Date(now);
        const today = new Date(n.getFullYear(), n.getMonth(), n.getDate()).getTime();
        let next = Infinity;
        for (let i = 0; i < listModel.count; i++) {
            const ev = listModel.get(i).evData;
            if (!ev || !ev.start || !ev.end || ev.allDay)
                continue;
            const day = new Date(ev.start.getFullYear(), ev.start.getMonth(), ev.start.getDate() + (ev.dayIndex || 0)).getTime();
            if (day < today)
                continue;
            if (day > today) {
                next = Math.min(next, day);
                continue;
            }
            const s = ev.start.getTime(), e = ev.end.getTime();
            if (now < s)
                next = Math.min(next, s);
            else if (now < e)
                next = Math.min(next, Math.floor(now / 60000) * 60000 + 60000);
        }
        if (isFinite(next))
            eventClock.request(next);
    }
    // Asked again whenever the clock publishes (the reader's half of the BoundaryClock's protocol) and whenever the rows change.
    Connections {
        target: eventClock
        function onNowChanged() {
            root._askEventClock();
        }
    }
    Connections {
        target: listModel
        function onCountChanged() {
            Qt.callLater(root._askEventClock);
        }
    }

    // ==================================================================
    // TRANSITION MACHINERY
    // ==================================================================
    // listModel is the single source of truth for currently-displayed rows.
    // Day change:
    //   1. Mark every existing row as "leaving" with staggerIdx = its current
    //      list position (top leaves first).
    //   2. Append each new event as a new row in "entering" state with its
    //      own top-down staggerIdx.
    //   3. Schedule cleanup: after all leave animations complete, remove the
    //      now-offscreen "leaving" rows. Separately, mark surviving
    //      "entering" rows as "rest" once they've reached home.
    // Both animations share one stagger cadence, so a full set of old rows
    // sliding out overlaps in time with a full set of new rows sliding in.
    // ==================================================================
    ListModel { id: listModel }

    readonly property int _currentEventCount: {
        if (!root.calendarData)
            return 0;
        // Read first: the revision is the dependency the call below cannot
        // establish (a function call captures nothing).
        const revision = root.calendarData._revision;
        return revision >= 0 ? root.calendarData.getEventsForDay(root.day).length : 0;
    }

    // Total time a stagger-sequence takes: (count-1)*stagger + duration + slack.
    function _sequenceMs(count) {
        if (count <= 0) return 0;
        return (count - 1) * animStaggerMs + animDuration + 40;
    }

    function _currentEvents() {
        return calendarData ? calendarData.getEventsForDay(day) : [];
    }

    // ==================================================================
    // STATE MACHINE
    //
    // Initial slide is DEBOUNCED: we don't fire the first animated slide
    // the instant one feed's events arrive — we restart a settle-timer on
    // every `changed` emission and fire only once things have been quiet
    // for `initialDebounceMs`. This guarantees that when N feeds' caches
    // all parse within a tight window (typical: all within a few ms of
    // each other on startup), the initial slide animates ONCE with the
    // merged set — no second feed's events popping in silently after.
    //
    //   _populated = false : listModel has never been populated. We're
    //                        waiting for cache loads to settle.
    //   _populated = true  : initial slide has played. Day changes
    //                        animate; data refreshes silent-sync.
    // ==================================================================
    property bool _populated: false
    property int initialDebounceMs: 80
    // The host holds the first slide (the content is parked, or the popup is still growing: the first rows would slide in before
    // they can be seen). Released, a slide waiting for it starts at once; data that
    // arrives AFTER the release (a slow fetch: nothing could be shown before it) starts its slide with no wait of this kind.
    property bool startHeld: false
    // The settle-timer is armed only while the start is not held: a held list (a parked content) runs no timer at all.
    function _kickInitial() {
        if (!root.startHeld)
            initialDebounceTimer.restart();
    }
    onStartHeldChanged: {
        if (!root.startHeld && !root._populated)
            root._kickInitial();
    }
    // Back to what a fresh build is: empty and waiting for its first slide, which plays again (a content kept parked between opens).
    function reset() {
        syncCoalesceTimer.stop();
        cleanupTimer.stop();
        enterRestTimer.stop();
        root._syncPending = false;
        root._dayChangesInSlide = 0;
        listModel.clear();
        root._populated = false;
        scrollArea.contentY = 0;
        root._kickInitial();
    }

    Component.onCompleted: root._kickInitial()
    onCalendarDataChanged: {
        _populated = false;
        root._kickInitial();
    }

    // Day-change coalescing. A single slide (one cross-month click) fires
    // onDayChanged once — we still apply it immediately, so the list
    // animates concurrently with the calendar slide.
    // Rapid bursts fire it multiple times per slide: the first change
    // still runs concurrently, but subsequent ones are dropped and
    // replayed once the slide settles against the FINAL day. That way
    // the list doesn't churn through 3–4 intermediate days' worth of
    // ListModel rebuilds and delegate instantiations mid-burst.
    property int _dayChangesInSlide: 0

    onDayChanged: {
        if (slideActive && _dayChangesInSlide > 0) {
            // Middle of a burst — wait for settle; `day` property already
            // holds the latest value.
            _dayChangesInSlide++;
            return;
        }
        if (slideActive) _dayChangesInSlide = 1;
        _applyExternalDayChange();
    }

    onSlideActiveChanged: {
        if (!slideActive) {
            if (_dayChangesInSlide > 1) _applyExternalDayChange();
            _dayChangesInSlide = 0;
        }
    }

    function _applyExternalDayChange() {
        syncCoalesceTimer.stop();
        initialDebounceTimer.stop();
        if (_populated) {
            _applyDayChange(false);
        } else {
            if (root.startHeld)
                return;
            let events = _currentEvents();
            if (events.length > 0) {
                _applyDayChange(true);
                _populated = true;
            }
        }
    }

    // Fires once cache arrivals have stopped for `initialDebounceMs`. If
    // the aggregate events is non-empty at that point, kick the initial
    // slide. If still empty, stay dormant — the next `calendarData.changed`
    // (e.g. curl completing) will restart the timer.
    Timer {
        id: initialDebounceTimer
        interval: root.initialDebounceMs
        repeat: false
        onTriggered: {
            if (root._populated || root.startHeld) return;
            if (cleanupTimer.running || enterRestTimer.running) return;
            let events = root._currentEvents();
            if (events.length === 0) return;
            root._applyDayChange(true);
            root._populated = true;
        }
    }

    Connections {
        target: root.calendarData
        ignoreUnknownSignals: true
        function onChanged() {
            if (!root._populated) {
                // Still waiting for initial — any new data reset the
                // settle-timer so multiple feeds can all contribute.
                root._kickInitial();
                return;
            }
            syncCoalesceTimer.restart();
        }
    }

    // Debounce — CalendarFeed emits events / loading / fetched all through
    // CalendarService.changed on a single refresh. Without coalescing, each
    // would trigger its own silent sync.
    //
    // If a silent sync fires while a slide animation is running (most
    // commonly: a second feed's cache finishes parsing AFTER the initial
    // slide for the first feed has already started), we can't clobber the
    // animation mid-flight. Instead we set _syncPending = true and let
    // cleanupTimer / enterRestTimer re-trigger the sync once the animation
    // settles — so late-arriving events end up in the list even if they
    // came in during the initial slide.
    property bool _syncPending: false

    Timer {
        id: syncCoalesceTimer
        interval: 40
        repeat: false
        onTriggered: {
            if (cleanupTimer.running || enterRestTimer.running) {
                root._syncPending = true;
                return;
            }
            root._syncSilent();
            root._syncPending = false;
        }
    }

    function _flushPendingSync() {
        if (!root._syncPending) return;
        if (cleanupTimer.running || enterRestTimer.running) return;
        root._syncPending = false;
        _syncSilent();
    }

    // Silent (no animation) replacement of listModel contents — used for
    // every CalendarService.changed AFTER the initial slide, so refreshes
    // never trigger animations.
    function _syncSilent() {
        let events = _currentEvents();
        listModel.clear();
        for (let i = 0; i < events.length; i++) {
            listModel.append({
                evData: events[i],
                rowState: "rest",
                staggerIdx: i
            });
        }
    }

    function _applyDayChange(isInitial) {
        let newEvents = _currentEvents();

        if (isInitial) {
            listModel.clear();
            for (let i = 0; i < newEvents.length; i++) {
                listModel.append({
                    evData: newEvents[i],
                    rowState: "entering",
                    staggerIdx: i
                });
            }
            enterRestTimer.interval = _sequenceMs(newEvents.length);
            enterRestTimer.restart();
            return;
        }

        let leaveCount = 0;
        for (let i = 0; i < listModel.count; i++) {
            let item = listModel.get(i);
            if (item.rowState === "leaving") { leaveCount++; continue; }
            listModel.setProperty(i, "rowState", "leaving");
            listModel.setProperty(i, "staggerIdx", leaveCount);
            leaveCount++;
        }
        for (let i = 0; i < newEvents.length; i++) {
            listModel.append({
                evData: newEvents[i],
                rowState: "entering",
                staggerIdx: i
            });
        }
        // Cleanup waits for:
        //   (a) every leaving row's slide to finish
        //       ((leaveCount-1) * stagger + animDuration)
        //   (b) PLUS every leaving row's height to collapse afterwards
        //       (animDuration extra) — without this, cleanup would remove rows
        //       while their collapse is mid-animation and remaining rows
        //       would teleport up instead of continuously drifting.
        cleanupTimer.interval = _sequenceMs(leaveCount) + animDuration;
        cleanupTimer.restart();
        enterRestTimer.interval = _sequenceMs(newEvents.length);
        enterRestTimer.restart();
    }

    Timer {
        id: cleanupTimer
        repeat: false
        onTriggered: {
            for (let i = listModel.count - 1; i >= 0; i--) {
                if (listModel.get(i).rowState === "leaving") listModel.remove(i);
            }
            root._flushPendingSync();
        }
    }

    Timer {
        id: enterRestTimer
        repeat: false
        onTriggered: {
            for (let i = 0; i < listModel.count; i++) {
                if (listModel.get(i).rowState === "entering") {
                    listModel.setProperty(i, "rowState", "rest");
                }
            }
            root._flushPendingSync();
        }
    }
}
