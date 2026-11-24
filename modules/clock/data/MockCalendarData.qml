pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// MockCalendarData.qml
//
// Hardcoded stand-in for CalendarService (which fetches ICS from
// proton share links and parses them). Exposes the same interface the real
// service does:
//   - calendars: [{ id, name, color }]
//   - events:    [{ uid, calendarId, title, description, location,
//                   start: Date, end: Date, allDay: bool }]
//   - getEventsForDay(dateObj) -> [event]  (sorted, all-day first)
//   - countForDay(dateObj)     -> int
//
// Events are seeded around 2026-04-23 so every
// mockup scenario is covered: empty days, single-dot, full-grid (9 dots),
// overflow (+), multi-calendar mixes, all-day, cross-month spillover.
// =============================================================================
Item {
    id: root

    // Public model — list-shape matches what the real service will expose.
    readonly property var calendars: [
        { id: "personal", name: "Personal", color: "#1E66F5" },
        { id: "work",     name: "Work",     color: "#40A02B" },
        { id: "family",   name: "Family",   color: "#EA76CB" },
        { id: "misc",     name: "Misc",     color: "#FE640B" }
    ]

    // Calendar IDs to filter out of the published `events` array. Driven by
    // CalendarVisibilityStore via ClockPopupContent; default empty (= show
    // every calendar). Mutating this triggers the events binding to re-eval,
    // which busts caches + bumps _revision so all dependent UI refreshes.
    // [{name, reason}] of the calendars that failed to load (the real service's `failedFeeds`; mockups/clock.qml FAILED=1)
    property var failedFeeds: []

    property var hiddenCalendarIds: []

    // Bumped on every events change so per-cell marks-layout bindings in
    // MonthWeekRow have a reactive dependency to refresh on (function-call
    // bindings don't otherwise carry through cache invalidation).
    property int _revision: 0

    // Mirror of CalendarService.changed — emitted on every events refresh so
    // AppointmentList's silent-sync path fires uniformly across data sources.
    signal changed()

    readonly property var _allEvents: _buildEvents()
    readonly property var events: _filterByVisibility(_allEvents, hiddenCalendarIds)

    function _filterByVisibility(all, hidden) {
        if (!hidden || hidden.length === 0) return all;
        let h = {};
        for (let i = 0; i < hidden.length; i++) h[hidden[i]] = true;
        let out = [];
        for (let i = 0; i < all.length; i++) {
            if (!h[all[i].calendarId]) out.push(all[i]);
        }
        return out;
    }

    onEventsChanged: {
        _dayCache = {};
        _slotCache = {};
        _marksCache = {};
        _revision++;
        changed();
    }

    // ------------------------------------------------------------------
    // Query helpers — future CalendarService will expose the exact same
    // signatures so CalendarView can bind without rewrites.
    // ------------------------------------------------------------------
    function _dayOnly(d) {
        return new Date(d.getFullYear(), d.getMonth(), d.getDate());
    }

    // Treat end-at-midnight as end-of-previous-day (standard ICS convention,
    // Proton uses this for events that "end on day X") so single-day events
    // aren't accidentally classed as two-day events.
    function _endDayEffective(e) {
        if (!e || !e.end) return e.start;
        let end = e.end;
        if (end.getHours() === 0 && end.getMinutes() === 0 && end.getSeconds() === 0) {
            return new Date(end.getTime() - 1);
        }
        return end;
    }

    // Numeric day key (y*10000 + m*100 + d) used by the hot path to avoid
    // allocating Date objects for every event/query comparison.
    function _dayKeyOf(d) {
        return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate();
    }

    // Ensure an event carries precomputed numeric day bounds + ms. Attached
    // lazily the first time we scan the event, cached on the event itself,
    // so rebuilding the event list automatically refreshes (new objects).
    function _ensureKeys(e) {
        if (e._startKey !== undefined) return;
        let s = _dayOnly(e.start);
        let f = _dayOnly(_endDayEffective(e));
        e._startKey = _dayKeyOf(s);
        e._endKey   = _dayKeyOf(f);
        e._startMs  = s.getTime();
        e._endMs    = f.getTime();
    }

    // Per-day lookup cache. Identical pattern to CalendarService: during a
    // month slide, getEventsForDay is hit hundreds of times per frame
    // (18 MonthWeekRow tiles × 42 cells for slot scan + per-cell dayEvents
    // binding), so memoising the second-and-later call for each unique day
    // turns O(N·events) into O(1).
    property var _dayCache: ({})

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

    // Multi-day slot-lane map for a month view. Each
    // MonthWeekRow would otherwise recompute this independently (6× per month, with 42
    // getEventsForDay calls each). The result is deterministic per
    // (year, month) — the 42-day scan window always covers every event
    // whose visible row exists in that month — so caching at data-source
    // level keeps all 6 rows of one month sharing a single computation.
    property var _slotCache: ({})

    // Per-cell marks layout cache. Key is compound (dayKey, viewYear,
    // viewMonth) because an event that spans a month boundary can sit in
    // a different lane of the slot map depending on which month's 42-day
    // view is doing the lane-packing — so the cache mustn't collapse
    // e.g. "April 1 viewed in April" with "April 1 viewed in March".
    property var _marksCache: ({})

    function getMultiDaySlots(year, month) {
        let key = year * 100 + month;
        let cached = _slotCache[key];
        if (cached !== undefined) return cached;
        let result = _computeMultiDaySlots(year, month);
        _slotCache[key] = result;
        return result;
    }

    // The slot-lane result is invariant of weekStart (it keys on event
    // uid→lane-index, derived from calendar-day sort), so the 42-cell
    // walk starts from a fixed Monday-anchored grid here for consistency
    // regardless of caller's weekStart.
    function _computeMultiDaySlots(year, month) {
        let firstDow = new Date(year, month, 1).getDay();
        let leadingBlanks = ((firstDow - 1) + 7) % 7;   // Mon-anchored
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

    // Per-cell marks layout (dots/lines rendered in a day square) —
    // function of that day's events + the slot map for the month the
    // cell is being viewed inside. Same caching semantics as the others.
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
        for (let i = 0; i < calendars.length; i++) {
            if (calendars[i].id === id) return calendars[i];
        }
        return null;
    }

    // ------------------------------------------------------------------
    // Private: construct mock event set. Pure JS, single call on creation.
    // ------------------------------------------------------------------
    function _ev(uid, calId, title, y, mo, d, startH, startM, durMin, allDay, desc, loc) {
        let s = new Date(y, mo, d, startH || 0, startM || 0, 0);
        let e = new Date(s.getTime() + (durMin || 60) * 60000);
        return {
            uid: uid, calendarId: calId, title: title,
            description: desc || "", location: loc || "",
            start: s, end: e, allDay: !!allDay
        };
    }

    function _buildEvents() {
        let Y = 2026, M = 3; // April
        let list = [];

        // --- Cross-month spillover (March) ---
        list.push(_ev("m1", "work",     "Quarterly planning",    Y, M-1, 30,  9, 30, 90, false, "Q2 roadmap review", "HQ / Room 4"));
        list.push(_ev("m2", "personal", "Dentist",               Y, M-1, 30, 16,  0, 45, false, "Cleaning", "Dr. Peeters"));

        // --- April 2 (Thu) — multi-calendar mix ---
        list.push(_ev("a1", "work",     "Standup",               Y, M,  2,  9,  0, 15, false, "", ""));
        list.push(_ev("a2", "work",     "Client call — Acme",    Y, M,  2, 11,  0, 60, false, "Renewal discussion", "Meet link"));
        list.push(_ev("a3", "family",   "Lunch with mom",        Y, M,  2, 12, 30, 75, false, "", "Café Central"));
        list.push(_ev("a4", "personal", "Gym",                   Y, M,  2, 18, 30, 60, false, "Leg day", "Basic-Fit"));

        // --- April 7 (Tue) — single personal ---
        list.push(_ev("a5", "personal", "Haircut",               Y, M,  7, 15,  0, 30, false, "", "Barbershop"));

        // --- April 9 (Thu) — all-day conference ---
        list.push(_ev("a6", "work",     "DevCon 2026",           Y, M,  9,  0,  0,  0, true,  "Full-day conference", "Antwerp Expo"));
        list.push(_ev("a7", "personal", "Drinks w/ Sam",         Y, M,  9, 20,  0, 90, false, "", "De Kroeg"));

        // --- April 14 (Tue) — exactly 9 events (max visible dots) ---
        for (let i = 0; i < 9; i++) {
            let cal = ["work", "personal", "family", "misc"][i % 4];
            list.push(_ev("b" + i, cal, "Slot " + (i+1), Y, M, 14, 8 + i, 0, 45, false, "", ""));
        }

        // --- April 15 (Wed) — 11 events (overflow "+") ---
        for (let i = 0; i < 11; i++) {
            let cal = ["work", "misc", "personal", "family"][i % 4];
            list.push(_ev("c" + i, cal, "Task " + (i+1), Y, M, 15, 7 + i, 0, 30, false, "", ""));
        }

        // --- April 17 (Fri) — single dot ---
        list.push(_ev("a8", "misc", "Car inspection", Y, M, 17, 10,  0, 60, false, "", "Garage Delta"));

        // --- April 21 (Tue) — all-day vacation start ---
        list.push(_ev("a9", "personal", "Vacation begins",       Y, M, 21,  0,  0,  0, true, "Out of office", ""));

        // --- April 23 (Thu) — TODAY, mixed ---
        list.push(_ev("t1", "work",     "1:1 with manager",      Y, M, 23, 10,  0, 30, false, "", "Office"));
        list.push(_ev("t2", "family",   "Dinner at home",        Y, M, 23, 19,  0, 90, false, "Pasta night", ""));

        // --- April 27 (Mon) — recurring-looking standup ---
        list.push(_ev("a10", "work", "Standup", Y, M, 27, 9, 0, 15, false, "", ""));

        // --- April 30 (Thu) — end-of-month review ---
        list.push(_ev("a11", "work", "Budget review", Y, M, 30, 14, 0, 60, false, "Q1 actuals vs forecast", "Boardroom"));

        // --- May 4 (Mon) — cross-month next ---
        list.push(_ev("n1", "personal", "Optometrist", Y, M+1, 4, 11, 0, 30, false, "", ""));

        // --- Multi-day events (to exercise spanning rendering) ---
        // Apr 5–6: overnight hackathon (timed, 14h, spans 2 calendar days)
        list.push(_ev("md1", "misc", "Overnight hackathon", Y, M, 5, 20, 0, 60*14, false, "24h creative jam", "Antwerp"));

        // Apr 10–13: weekend trip (timed, 62h, spans 4 calendar days)
        list.push(_ev("md2", "personal", "Weekend trip", Y, M, 10, 18, 0, 60*62, false, "Away for the weekend", "Brugge"));

        // Apr 17–23: family vacation (all-day, 7 days)
        list.push(_ev("md3", "family", "Family vacation", Y, M, 17, 0, 0, 60*24*7, true, "Beach trip", "Spain"));

        // Apr 20–22: tech summit (timed, 58h, spans 3 calendar days)
        list.push(_ev("md4", "work", "Tech Summit", Y, M, 20, 9, 0, 60*58, false, "Industry conference", "Brussels"));

        return list;
    }
}
