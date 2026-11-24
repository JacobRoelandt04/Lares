pragma ComponentBehavior: Bound

import QtQuick
import QtQml

// =============================================================================
// CalendarService.qml
//
// Drop-in replacement for MockCalendarData — same surface as far as the UI
// (CalendarView, AppointmentList) is concerned:
//
//   - calendars : [{ id, name, color }]
//   - events    : [ occurrence, ... ]        // aggregated across all feeds
//   - getEventsForDay(date) -> [occurrence]
//   - countForDay(date)    -> int
//   - calendarById(id)     -> calendar | null
//
// Internally it instantiates one CalendarFeed per config entry; each feed
// manages its own disk cache, network fetch, parse, and RRULE expansion.
// Emits `changed` whenever the aggregated event list changes.
// =============================================================================
Item {
    id: root

    // --- Injected CalendarConfig instance ---
    property var config: null

    // --- Aggregated outputs ---
    property var events: []
    property bool loading: false
    property string lastError: ""
    // [{name, reason}] per calendar whose last fetch failed; the other calendars' events stay in `events`.
    property var failedFeeds: []

    // Calendar IDs to filter out of the published `events` array. Driven
    // by CalendarVisibilityStore via ClockPopupContent. Toggling re-runs
    // _recompute, which refilters, busts caches, and bumps _revision.
    property var hiddenCalendarIds: []
    onHiddenCalendarIdsChanged: _recompute()

    // Bumped on every events change so per-cell marks-layout bindings in
    // MonthWeekRow have a reactive dep to refresh on (function-call
    // bindings don't otherwise carry through cache invalidation).
    property int _revision: 0

    // Calendars list (for colour lookup) comes directly from config entries.
    readonly property var calendars: config ? config.entries : []

    signal changed()

    // ======================================================================
    // Feed instantiator — one CalendarFeed per config entry. Feeds are
    // non-visual Items; Instantiator tracks them as QObjects.
    // ======================================================================
    Instantiator {
        id: feedHolder
        model: root.config ? root.config.entries : []
        delegate: CalendarFeed {
            id: feed
            required property var modelData
            calendarEntry: modelData
            // Events actually changed → heavy rebuild is justified.
            onEventsChanged: root._recompute()
            // Loading / error state updates are cheap; no reason to rebuild
            // the full aggregate events array (and fire `changed`, which
            // drives the AppointmentList silent sync). Keep them isolated.
            onLoadingChanged: root._updateMeta()
            onLastErrorChanged: root._updateMeta()
        }
        onObjectAdded:  (i, obj) => root._recompute()
        onObjectRemoved: (i, obj) => root._recompute()
    }

    function _updateMeta() {
        let anyLoading = false;
        let lastErr = "";
        for (let i = 0; i < feedHolder.count; i++) {
            let f = feedHolder.objectAt(i);
            if (!f) continue;
            if (f.loading) anyLoading = true;
            if (f.lastError) lastErr = f.lastError;
        }
        root.loading = anyLoading;
        root.lastError = lastErr;
        // the calendars whose feed failed and holds nothing newer than its cache (cleared when the feed loads again)
        const failed = [];
        for (let i = 0; i < feedHolder.count; i++) {
            const f = feedHolder.objectAt(i);
            if (f && f.lastError)
                failed.push({ name: f.calendarEntry && f.calendarEntry.name ? f.calendarEntry.name : "calendar", reason: f.lastError });
        }
        if (JSON.stringify(failed) !== JSON.stringify(root.failedFeeds))
            root.failedFeeds = failed;
    }

    function _recompute() {
        let all = [];
        for (let i = 0; i < feedHolder.count; i++) {
            let f = feedHolder.objectAt(i);
            if (!f) continue;
            let evs = f.events;
            for (let j = 0; j < evs.length; j++) all.push(evs[j]);
        }
        let hidden = root.hiddenCalendarIds;
        if (hidden && hidden.length > 0) {
            let h = {};
            for (let i = 0; i < hidden.length; i++) h[hidden[i]] = true;
            let filtered = [];
            for (let i = 0; i < all.length; i++) {
                if (!h[all[i].calendarId]) filtered.push(all[i]);
            }
            all = filtered;
        }
        root.events = all;
        root._dayCache = {};    // invalidate per-day cache on event change
        root._slotCache = {};   // and the month slot-lane map cache
        root._marksCache = {};  // and the per-cell marks layout cache
        root._revision++;       // wake up function-call bindings
        _updateMeta();
        root.changed();
    }

    // Per-day lookup cache. `getEventsForDay` is called tens of thousands of
    // times per frame during rapid calendar scrolling (a dozen visible weeks
    // × 7 day cells × multi-day line resolution), and without memoization
    // every call linearly scans the full events array. With cache the first
    // call for a day builds the list, all subsequent calls are O(1).
    property var _dayCache: ({})

    // ======================================================================
    // Public query helpers — identical shape to MockCalendarData.
    // ======================================================================
    function _dayOnly(d) {
        return new Date(d.getFullYear(), d.getMonth(), d.getDate());
    }

    function _endDayEffective(e) {
        if (!e || !e.end) return e.start;
        let end = e.end;
        if (end.getHours() === 0 && end.getMinutes() === 0 && end.getSeconds() === 0) {
            return new Date(end.getTime() - 1);
        }
        return end;
    }

    function _dayKeyOf(d) {
        return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate();
    }

    // Lazy-attach precomputed numeric day bounds + ms to an event so the
    // scan loop skips per-event `new Date()` allocations. Same pattern as
    // MockCalendarData._ensureKeys; safe to mutate because feeds don't
    // reuse event objects across refreshes (new array → new objects).
    function _ensureKeys(e) {
        if (e._startKey !== undefined) return;
        let s = _dayOnly(e.start);
        let f = _dayOnly(_endDayEffective(e));
        e._startKey = _dayKeyOf(s);
        e._endKey   = _dayKeyOf(f);
        e._startMs  = s.getTime();
        e._endMs    = f.getTime();
    }

    function getEventsForDay(date) {
        if (!date) return [];
        let dayKey = date.getFullYear() * 10000
                   + (date.getMonth() + 1) * 100
                   + date.getDate();
        let cached = _dayCache[dayKey];
        if (cached !== undefined) return cached;
        let result = _computeEventsForDay(date);
        _dayCache[dayKey] = result;
        return result;
    }

    function _computeEventsForDay(date) {
        let queryKey = _dayKeyOf(date);
        let queryMs  = _dayOnly(date).getTime();
        let out = [];
        for (let i = 0; i < events.length; i++) {
            let e = events[i];
            _ensureKeys(e);
            if (queryKey < e._startKey || queryKey > e._endKey) continue;

            let totalDays = Math.round((e._endMs - e._startMs) / 86400000) + 1;
            let dayIndex  = Math.round((queryMs - e._startMs) / 86400000);

            out.push({
                uid: e.uid,
                title: e.title,
                description: e.description,
                location: e.location,
                start: e.start,
                end: e.end,
                allDay: e.allDay,
                calendarId: e.calendarId,
                totalDays: totalDays,
                dayIndex: dayIndex
            });
        }
        out.sort(function(a, b) {
            let aMulti = a.totalDays > 1;
            let bMulti = b.totalDays > 1;
            if (aMulti !== bMulti) return aMulti ? -1 : 1;
            if (a.allDay !== b.allDay) return a.allDay ? -1 : 1;
            return a.start - b.start;
        });
        return out;
    }

    function countForDay(date) {
        return getEventsForDay(date).length;
    }

    // Multi-day slot-lane map for a month view — mirror of the mock's
    // implementation so both data sources expose the same UI hook. Cached
    // per (year, month); invalidated whenever the aggregated events
    // change (see _recompute above).
    property var _slotCache: ({})

    function getMultiDaySlots(year, month) {
        let key = year * 100 + month;
        let cached = _slotCache[key];
        if (cached !== undefined) return cached;
        let result = _computeMultiDaySlots(year, month);
        _slotCache[key] = result;
        return result;
    }

    function _computeMultiDaySlots(year, month) {
        let firstDow = new Date(year, month, 1).getDay();
        let leadingBlanks = ((firstDow - 1) + 7) % 7;
        let seen = {};
        let events = [];
        for (let r = 0; r < 6; r++) {
            for (let c = 0; c < 7; c++) {
                let dayOffset = r * 7 + c - leadingBlanks;
                let d = new Date(year, month, 1 + dayOffset);
                let evs = getEventsForDay(d);
                for (let i = 0; i < evs.length; i++) {
                    let e = evs[i];
                    if (!e.totalDays || e.totalDays <= 1) continue;
                    if (seen[e.uid]) continue;
                    seen[e.uid] = true;
                    _ensureKeys(e);
                    events.push({
                        uid: e.uid,
                        rawMs: e.start.getTime(),
                        startKey: e._startKey,
                        endKey:   e._endKey
                    });
                }
            }
        }
        events.sort(function(a, b) {
            if (a.rawMs !== b.rawMs) return b.rawMs - a.rawMs;
            return b.endKey - a.endKey;
        });
        let lanes = [[], [], []];
        let rowMap = {};
        for (let i = 0; i < events.length; i++) {
            let ev = events[i];
            let placed = -1;
            for (let li = 0; li < 3; li++) {
                let conflict = false;
                for (let j = 0; j < lanes[li].length; j++) {
                    let other = lanes[li][j];
                    if (other.endKey < ev.startKey || other.startKey > ev.endKey) continue;
                    conflict = true;
                    break;
                }
                if (!conflict) {
                    lanes[li].push(ev);
                    placed = li;
                    break;
                }
            }
            rowMap[ev.uid] = placed < 0 ? -1 : (2 - placed);
        }
        return rowMap;
    }

    // Per-cell marks layout cache — mirror of MockCalendarData.
    property var _marksCache: ({})

    function getMarksLayout(date, viewYear, viewMonth) {
        let dayKey = _dayKeyOf(date);
        let ck = dayKey * 10000 + viewYear * 100 + viewMonth;
        let cached = _marksCache[ck];
        if (cached !== undefined) return cached;
        let result = _computeMarksLayout(
            getEventsForDay(date), getMultiDaySlots(viewYear, viewMonth));
        _marksCache[ck] = result;
        return result;
    }

    function _computeMarksLayout(dayEvents, slotMap) {
        let multi = [];
        let single = [];
        for (let i = 0; i < dayEvents.length; i++) {
            let e = dayEvents[i];
            if (e.totalDays && e.totalDays > 1) {
                let rr = slotMap[e.uid];
                if (rr === undefined || rr < 0) continue;
                multi.push({ev: e, row: rr});
            } else {
                single.push(e);
            }
        }
        single.sort(function(a, b) { return a.start - b.start; });

        let rows = [null, null, null];
        for (let i = 0; i < multi.length; i++) {
            let rr = multi[i].row;
            if (rows[rr]) continue;
            rows[rr] = { kind: "line", ev: multi[i].ev, truncated: false,
                         extraDot: null, extraPlus: false };
        }
        let linesUsed = (rows[0] ? 1 : 0) + (rows[1] ? 1 : 0) + (rows[2] ? 1 : 0);
        if (linesUsed === 3 && single.length > 0 && rows[0].kind === "line") {
            rows[0].truncated = true;
            if (single.length === 1) rows[0].extraDot = single[0];
            else rows[0].extraPlus = true;
            single = [];
        }
        let idx = 0;
        for (let i = 0; i < 3; i++) {
            if (rows[i]) continue;
            let remaining = single.length - idx;
            let count = Math.min(3, remaining);
            let events = [];
            for (let j = 0; j < count; j++) events.push(single[idx + j]);
            rows[i] = { kind: "dots", count: count, events: events };
            idx += count;
        }
        let extras = single.length - idx;
        if (extras > 0) {
            for (let i = 2; i >= 0; i--) {
                let rr = rows[i];
                if (rr && rr.kind === "dots" && rr.count > 0) {
                    rr.events[rr.count - 1] = { overflow: true, calendarId: "" };
                    break;
                }
            }
        }
        return rows;
    }

    function calendarById(id) {
        let cals = calendars;
        for (let i = 0; i < cals.length; i++) {
            if (cals[i].id === id) return cals[i];
        }
        return null;
    }

    // Force a round-trip fetch on every feed.
    function refresh() {
        for (let i = 0; i < feedHolder.count; i++) {
            let f = feedHolder.objectAt(i);
            if (f) f.refresh();
        }
    }

    // Dynamic expansion window — when the user navigates far from today,
    // the caller (ClockPopupContent) calls this with a window centred on
    // the viewed month so recurring events remain materialised for the
    // visible grid. CalendarFeed re-expands whenever its expandStart /
    // expandEnd change, so setting the same values is a no-op.
    function setViewWindow(start, end) {
        for (let i = 0; i < feedHolder.count; i++) {
            let f = feedHolder.objectAt(i);
            if (f) {
                f.expandStart = start;
                f.expandEnd = end;
            }
        }
    }
}
