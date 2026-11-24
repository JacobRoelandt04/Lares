pragma ComponentBehavior: Bound

import QtQuick

import "SourceGlyphs.js" as G
import "CalendarReminders.js" as Cal

// =============================================================================
// CalendarNotifier.qml -- an appointment is about to start (source "calendar"; SOURCES.md, "Later sources").
//
// `leadMin` minutes (one lead or several) before an appointment of the clock's calendar (CalendarService.events: the occurrences
// its feeds expanded; `calendars` narrows them), a card: its title, "In 10 min . 14:30-15:00 . Room 3", Open calendar (the clock
// popup). Said once per occurrence and lead -- the event and its start, so a weekly event is a new reminder each week -- and
// remembered in sources.json, so a restart inside the lead does not say it again. An all-day one is told at `allDayAt` of its day
// (by default not at all); one that began more than a minute ago is not (the machine was asleep: it is no longer about to
// start); one that begins in under the lead is told at once, with the minutes it really has left. The moment is a WALL deadline on the shell's one BoundaryClock, so it follows a
// suspend; a change in the calendar (a feed refreshed, an event moved or removed) looks again. `calendar` is injected
// (null: this source is off).
// =============================================================================
SourceBase {
    id: src

    sourceId: "calendar"
    appName: "Calendar"
    glyph: G.calendar
    keys: ["cal"]

    // The CalendarService (or its mock): `events`, `changed`.
    property var calendar: null
    ready: !!src.calendar

    // The clock (the probes' seam).
    property var nowFn: function () { return Date.now(); }

    function _look() {
        if (!src.active)
            return;
        const now = src.nowFn();
        // leadMin, allDayAt, calendars; and each calendar's own `remind` of calendars.jsonc (true: as leadMin says)
        const opts = Object.assign({}, src.settings, { remind: src._remindOf(src.calendar.calendars) });
        const events = src.calendar.events;
        const st = src.host.state.get("calendar");
        const reminded = st.reminded || {};
        const due = Cal.due(events, now, opts, reminded);
        for (const r of due) {
            src._say(r, now);
            for (const m of r.marks)
                reminded[m] = r.untilMs;
        }
        if (due.length > 0)
            src.host.state.put("calendar", { reminded: Cal.prune(reminded, now) });
        const at = Cal.nextAt(events, now, opts, reminded);
        if (at > 0)
            src.host.clock.request(at);
    }

    function _remindOf(calendars) {
        const out = {};
        for (const c of calendars || [])
            if (c && (c.remind === false || typeof c.remind === "number"))
                out[c.id] = c.remind;
        return out;
    }

    function _say(r, now) {
        const t = Cal.text(r, now);
        src.post(r.key, {
            title: t.title, body: t.body, urgency: "normal", timeoutMs: src.settings.timeoutMs,
            actions: [{ id: "open", label: "Open calendar", run: () => src.host.open("clock") }],
            onDefault: () => src.host.open("clock")
        });
    }

    Connections {
        target: src.host ? src.host.clock : null
        function onNowChanged() {
            src._look();
        }
    }
    Connections {
        target: src.calendar
        ignoreUnknownSignals: true
        function onChanged() {
            src._look();
        }
    }
    onActivated: src._look()
}
