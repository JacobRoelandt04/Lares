pragma ComponentBehavior: Bound

import QtQuick

import "../system"

// =============================================================================
// BoundaryClock.qml
//
// ONE clock for every relative time on screen that ticks only on the
// boundaries somebody is showing. A list of "now" / "4 min" / "2 h" labels
// does not need a timer per row, or a timer every second: each reader binds
// its text to `now` and asks for the instant its text would change, and ONE
// single-shot Timer fires at the earliest of those.
//
//   now              epoch ms, updated only when a requested boundary is
//                    reached. Bind to it: `RelTime.format(ms, clock.now)`.
//   request(atMs)    wake me at atMs. -1 (RelTime's "this text is final")
//                    and anything that is not a finite number are IGNORED. An
//                    instant already PAST, or now, is DUE: `now` is published
//                    on the clock's next tick (see below).
//   refresh()        re-read the wall clock NOW: publish `now` if the earliest
//                    request is due, else re-arm for what is left. The timer
//                    calls it on every wake; call it when the wall clock moved
//                    under a sleeping timer.
//   sleepWatcher     the SleepWatcher whose resumed() calls refresh(). By
//                    default the shell's one, `Sleep.watcher`: every clock
//                    follows a suspend with no wiring by its host, and the
//                    shell runs one monitor however many clocks exist. A host
//                    that hands in its own watcher (a probe), or null (follow
//                    none), never creates the shared one.
//   active           the clock runs. By default it runs while the item it is
//                    declared in is on screen -- that item's EFFECTIVE
//                    visibility, false whenever it or any ancestor is hidden
//                    -- so a clock inside a popup, a list or a card stops
//                    with it and no host wires anything. False DROPS the
//                    armed boundary and ignores every request, so a hidden
//                    host does not wake: its readers stop asking when they
//                    hide, but a boundary asked for before the hide would
//                    wake the clock anyway, once per clock per hide (`now`
//                    would move while nothing is on screen and a frame would
//                    be presented for it; a host-by-host `active:` binding
//                    would leave every host without one still waking). Back
//                    on, `now` is published on the next tick, so every reader
//                    re-reads the wall and asks again. A host may bind something narrower (the
//                    notifications mockup: "a card is on screen"). A clock
//                    with no parent item -- a property value, a Scope's child
//                    -- has nothing to follow and always runs.
//
// AN ITEM THAT IS NEVER DRAWN. The clock is an Item only so that it has a
// parent item to follow; it is `visible: false`, zero-sized, and a positioner
// or a Layout skips it, so it takes no slot and no spacing wherever it is
// declared. Being an Item, it sits in its host's `children` (not `resources`).
//
// THE READER'S HALF. When `now` changes every request is cleared, and every
// reader re-requests its next boundary from the text it now shows, which is
// what a binding does anyway:
//
//   readonly property var rel: RelTime.format(record.arrivedMs, clock.now)
//   onRelChanged: clock.request(rel.nextMs)       // and once on completion
//
// So a request later than the one armed is not stored: the earlier fire makes
// its reader ask again. With nothing requested there is no timer running and
// nothing ticks -- an open list of week-old entries costs nothing at all.
//
// WHY A PAST REQUEST PUBLISHES. `now` is the instant of the LAST publish, so a
// reader created long after it formats its text from a stale `now`, and the
// boundary it asks for can already be behind the wall ("now" for an entry 61 s
// old, due at -1 s). Ignored, that request arms nothing and the text freezes
// until some other reader's boundary happens to move `now`. So a past instant
// is simply the earliest due: the one timer is armed for 1 ms, and refresh()
// publishes the wall. NEVER published inside request(): readers ask from
// their reading's change handler, so an inline `now` write lands inside that
// reader's own binding update (binding loops, measured on LlmTurn). Deferred,
// it also coalesces: a list building fifty rows, each asking from
// `Component.onCompleted`, makes ONE publish, not fifty re-evaluations of
// every row mid-construction.
//
// WHY THE CHECKS ON WAKING. The Timer runs on Qt Quick's animation clock,
// stepped per frame, which can lead the wall clock by a few percent (measured
// offscreen: 240 ms of animation in 224 ms of wall) -- so a wake can arrive
// before its boundary, and `now` would then be published a hair early and
// every "59 s" would still say "now". And its interval is an int, so a
// boundary months away (RelTime's "d MMM HH:mm" gains its year at the next 1
// January) cannot be armed in one go. Both are the same case: on a wake with
// nothing due yet, re-arm for what is left -- capped at `maxSleepMs` -- and
// publish NOTHING.
//
// WHY REFRESH ON RESUME. That timer runs on CLOCK_MONOTONIC, which stands
// still while the machine is suspended: a boundary 3 min off when the lid
// closed is still 3 min off, by the timer, when it opens two hours later, so
// "3 min" would read on for three more minutes. A resume is the one moment the
// wall clock is known to have jumped under the timer; refresh() then
// publishes what is due and re-arms the rest from the wall (`sleepWatcher`,
// SleepWatcher.qml, modules/common/system/Sleep.qml).
//
// A WALL STEP WITH NO RESUME. The wall can also jump with nobody saying so --
// NTP stepping it, a `date -s`, or a resume the watcher missed while its
// monitor was restarting -- and the armed boundary is then behind the wall
// while the timer still holds its old monotonic interval: measured, "due
// -307.5 s from the wall, timer armed 3295689 ms" after a +1 h step, every
// later request dropped as later than the armed one, and every reader's text
// stale until that timer. Two things find such a step:
//   - a request that finds the armed boundary already BEHIND the wall re-arms
//     at once (1 ms): it is due, and the timer that should have said so is
//     reckoning on a clock the wall has left -- any reader asking (one built
//     after the step, one whose words came back on screen) wakes the lot;
//   - the timer never sleeps longer than `maxSleepMs`, a MINUTE, and every
//     wake re-reads the wall (refresh), so a step nobody asks about is
//     published within a minute of it. A clock with nothing requested still
//     runs no timer at all; an armed one wakes once a minute at most, and
//     only while it is `active` -- by default, while its host is on screen.
// =============================================================================
Item {
    id: root

    // Never drawn, never laid out (AN ITEM THAT IS NEVER DRAWN, above).
    visible: false

    readonly property double now: root._now
    // The longest single sleep: a minute. Every wake re-reads the wall, so
    // this is also how late a wall step nobody asks about is published (A
    // WALL STEP WITH NO RESUME, above); it costs an armed clock one wake a
    // minute while its boundary is further off, and nothing unarmed.
    property int maxSleepMs: 60000
    property var sleepWatcher: Sleep.watcher
    property bool active: root.parent ? root.parent.visible : true

    function request(atMs) {
        if (!root.active || typeof atMs !== "number" || !isFinite(atMs) || atMs === -1)
            return;
        // Clamped so that `_due`'s own "nothing" (-1) stays unambiguous.
        const t = Math.max(0, atMs);
        const wall = Date.now();
        if (root._due >= 0 && t >= root._due) {
            // Later than the armed one -- which the wall may already have
            // passed with the timer none the wiser (a wall step): due now.
            if (root._due <= wall)
                root._arm(wall);
            return;
        }
        root._due = t;
        root._arm(wall);
    }

    function refresh() {
        if (!root.active || root._due < 0)
            return;
        const wall = Date.now();
        if (wall < root._due) {
            root._arm(wall);
            return;
        }
        // Cleared BEFORE `now` moves: the readers re-request from inside the
        // change, and must find nothing armed.
        root._due = -1;
        root._timer.stop();
        root._now = wall;
    }

    property double _now: Date.now()
    // The earliest requested boundary, -1 when nothing is requested.
    property double _due: -1

    property Timer _timer: Timer {
        repeat: false
        onTriggered: root.refresh()
    }
    property Connections _resume: Connections {
        target: root.sleepWatcher
        function onResumed() {
            root.refresh();
        }
    }
    // Off: nothing armed, nothing wakes. On again: a boundary at 0 is due, so
    // the next tick publishes the wall and every reader asks afresh (never
    // published here: the flip can land inside a reader's own update).
    // Not while the clock is being built: the default binding lands then as a
    // change from the property's own `false`, and a clock that new has nothing
    // armed and `now` at the wall -- answering it would publish once for every
    // clock created on screen, with nobody asking.
    property bool _built: false
    Component.onCompleted: root._built = true
    onActiveChanged: {
        if (!root._built)
            return;
        if (root.active) {
            root._due = 0;
            root._arm(Date.now());
        } else {
            root._due = -1;
            root._timer.stop();
        }
    }

    function _arm(wall) {
        const cap = Math.max(1, Math.min(root.maxSleepMs, 2147483647));
        root._timer.interval = Math.max(1, Math.min(cap, Math.ceil(root._due - wall)));
        root._timer.restart();
    }
}
