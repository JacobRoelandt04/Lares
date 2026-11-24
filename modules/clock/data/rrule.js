.pragma library

// =============================================================================
// rrule.js — Pragmatic RFC 5545 recurrence expander
//
// expandRRule(ev, rangeStart, rangeEnd) -> [ occurrence, ... ]
//
// Where `ev` is one event object from ical.js and each occurrence has shape:
//
//   { uid, summary, description, location,
//     start: Date, end: Date, allDay: bool, calendarId }
//
// Supported subset:
//   FREQ = DAILY | WEEKLY | MONTHLY | YEARLY
//   INTERVAL = integer
//   COUNT    = integer
//   UNTIL    = date
//   BYDAY    = comma list for WEEKLY (MO/TU/.../SU)
//   EXDATE   = [Date, ...] exceptions
//
// Intentionally skipped (recorded on the rrule object by the parser but
// ignored during expansion): BYSETPOS, BYYEARDAY, BYWEEKNO, BYMONTH (as a
// filter), BYMONTHDAY, WKST shifts beyond Monday default.
// =============================================================================

const DAY_CODE = { SU: 0, MO: 1, TU: 2, WE: 3, TH: 4, FR: 5, SA: 6 };

const MAX_ITERS = 4000;

// A series is recurred in the clock it was written in (RFC 5545): a floating or TZID time in the machine's local wall
// clock, so 09:00 stays 09:00 over a DST change; a UTC one (DTSTART:...Z) at the same UTC time, so its local hour moves
// with the change. `_get` reads the fields of either (`get` or `getUTC`). A TZID other than the
// machine's is read as local (ical.js says so); a zone database would be needed to do better.
// tools/dev/dst_audit_cases.js C3-C5.
function _isUtc(ev) {
    return !!(ev.dtstart && ev.dtstart.isDate !== true && typeof ev.dtstart.raw === "string" && /Z$/.test(ev.dtstart.raw));
}
function _get(d, f, utc) { return utc ? d["getUTC" + f]() : d["get" + f](); }

function _sameDate(a, b, utc) {
    return _get(a, "FullYear", utc) === _get(b, "FullYear", utc)
        && _get(a, "Month", utc)    === _get(b, "Month", utc)
        && _get(a, "Date", utc)     === _get(b, "Date", utc);
}

function _isExcluded(ev, dt, utc) {
    let exdates = ev.exdates || [];
    for (let i = 0; i < exdates.length; i++) {
        if (_sameDate(exdates[i], dt, utc)) return true;
    }
    return false;
}

// The wall clock of an instant, read as if UTC: the length of a local-time event is a difference of these, not of the
// instants (22:00-08:00 is 10 wall hours, 9 elapsed on the night the clocks go forward).
function _wall(d) {
    return Date.UTC(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours(), d.getMinutes(), d.getSeconds(), d.getMilliseconds());
}
function _fromWall(w) {
    const u = new Date(w);
    return new Date(u.getUTCFullYear(), u.getUTCMonth(), u.getUTCDate(), u.getUTCHours(), u.getUTCMinutes(), u.getUTCSeconds(), u.getUTCMilliseconds());
}

function _occurrence(ev, startDt, durationMs, endDt) {
    // Normalise so consumers (AppointmentRow, etc.) always see string fields
    // even when the ICS omits them. Aligns field names with MockCalendarData
    // (`title` — not `summary`) so either source is a drop-in.
    return {
        uid: ev.uid || "",
        title: ev.summary || "",
        description: ev.description || "",
        location: ev.location || "",
        start: new Date(startDt),
        end: endDt ? endDt : new Date(startDt.getTime() + durationMs),
        allDay: ev.dtstart.isDate === true,
        calendarId: ev.calendarId || ""
    };
}

function expandRRule(ev, rangeStart, rangeEnd) {
    let out = [];
    if (!ev.dtstart || !ev.dtstart.value) return out;

    let duration = 3600000;   // fallback 1h if DTEND missing
    if (ev.dtend && ev.dtend.value) {
        duration = ev.dtend.value.getTime() - ev.dtstart.value.getTime();
        if (duration < 0) duration = 3600000;
    }

    // --- No RRULE: single occurrence ---
    if (!ev.rrule) {
        let s = ev.dtstart.value;
        let e = new Date(s.getTime() + duration);
        // Include if any overlap with range.
        if (e >= rangeStart && s <= rangeEnd) out.push(_occurrence(ev, s, duration));
        return out;
    }

    let rrule = ev.rrule;
    let freq = (rrule.freq || "").toUpperCase();
    let interval = Math.max(1, rrule.interval || 1);
    let count = rrule.count || null;
    let until = rrule.until || null;
    let start = new Date(ev.dtstart.value);
    const utc = _isUtc(ev);
    // a local-time series keeps its WALL length (see _wall); a UTC one its elapsed length
    const wallDur = !utc && ev.dtend && ev.dtend.value && duration >= 0 && ev.dtend.value.getTime() > ev.dtstart.value.getTime()
        ? _wall(ev.dtend.value) - _wall(ev.dtstart.value) : null;
    const endOf = function (dt) { return wallDur === null ? new Date(dt.getTime() + duration) : _fromWall(_wall(dt) + wallDur); };

    let produced = 0;
    let aborted = false;

    function emit(dt) {
        if (until && dt > until) { aborted = true; return; }
        if (count && produced >= count) { aborted = true; return; }
        produced++;
        if (_isExcluded(ev, dt, utc)) return;
        let occEnd = endOf(dt);
        // Include if overlaps with range
        if (occEnd < rangeStart) return;
        if (dt > rangeEnd) { aborted = true; return; }
        out.push(_occurrence(ev, dt, duration, occEnd));
    }

    // Every occurrence is built from the FIRST one by whole days/months/years in its own clock (never by stepping the
    // previous occurrence): a 02:30 series that meets the night the clocks go forward would otherwise stay at 03:30 for ever.
    const at = function (years, months, days) {
        return utc
            ? new Date(Date.UTC(start.getUTCFullYear() + years, start.getUTCMonth() + months, start.getUTCDate() + days,
                                start.getUTCHours(), start.getUTCMinutes(), start.getUTCSeconds(), start.getUTCMilliseconds()))
            : new Date(start.getFullYear() + years, start.getMonth() + months, start.getDate() + days,
                       start.getHours(), start.getMinutes(), start.getSeconds(), start.getMilliseconds());
    };

    if (freq === "DAILY") {
        for (let i = 0; i < MAX_ITERS && !aborted; i++) {
            const cur = at(0, 0, i * interval);
            emit(cur);
            if (aborted) break;
            if (at(0, 0, (i + 1) * interval) > rangeEnd && (!until || at(0, 0, (i + 1) * interval) > until)) break;
        }
    }
    else if (freq === "WEEKLY") {
        let bydays = rrule.byday && rrule.byday.length > 0
            ? rrule.byday.map(function(b){ return DAY_CODE[b.day]; })
            : [_get(start, "Day", utc)];

        // Align week-start to Monday of start's week (ignoring WKST nuance).
        const back = (_get(start, "Day", utc) + 6) % 7; // days since Monday

        for (let i = 0; i < MAX_ITERS && !aborted; i++) {
            for (let j = 0; j < 7 && !aborted; j++) {
                const d = at(0, 0, -back + 7 * interval * i + j);
                if (d < start) continue;
                if (bydays.indexOf(_get(d, "Day", utc)) === -1) continue;
                emit(d);
            }
            if (aborted) break;
            const next = at(0, 0, -back + 7 * interval * (i + 1));
            if (next > rangeEnd && (!until || next > until)) break;
        }
    }
    else if (freq === "MONTHLY") {
        for (let i = 0; i < MAX_ITERS && !aborted; i++) {
            emit(at(0, i * interval, 0));
            if (aborted) break;
            const next = at(0, (i + 1) * interval, 0);
            if (next > rangeEnd && (!until || next > until)) break;
        }
    }
    else if (freq === "YEARLY") {
        for (let i = 0; i < MAX_ITERS && !aborted; i++) {
            emit(at(i * interval, 0, 0));
            if (aborted) break;
            const next = at((i + 1) * interval, 0, 0);
            if (next > rangeEnd && (!until || next > until)) break;
        }
    }
    else {
        // Unknown FREQ — treat as single event.
        let s = start;
        if (s >= rangeStart && s <= rangeEnd) out.push(_occurrence(ev, s, duration));
    }

    return out;
}
