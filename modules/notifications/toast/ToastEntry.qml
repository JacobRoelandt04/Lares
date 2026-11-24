pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../parts"
import ".."

// =============================================================================
// ToastEntry.qml -- one notification in the toast stack: the card, on a
// SwipeVerbCard whose verbs are the toast's:
//   swipe RIGHT = file it into the manager (the tray is uncovered)
//   swipe LEFT  = delete it                (the bin is uncovered)
//   click       = the sender's default action, else its window focused
// A FIXED record has neither swipe nor click (`fixed`).
//
// The countdown is drawn, not kept: the ToastScheduler owns the deadline and
// expires the entry; this only mirrors `timing(uid)` as ONE stepped fraction
// (`timeLeft`, 1 -> 0) that the card shows in its inset, and stops it while
// the scheduler is frozen (hover, away, replying). A sticky entry has none.
// The drain ends at 0 ON the deadline (the scheduler's `expired` says so when
// its timer lands before the last step), and an entry that leaves the stack
// keeps its countdown where it stopped: the card flies off with the colour it
// had, never with the resting mark brought back under it.
//
// A DEADLINE IS ONLY SHOWN. A record that carries `deadlineMs` (a wall instant) and `deadlineTotalMs` (the span the drain runs
// over) is a toast whose time is somebody else's -- the MUX guard's, which puts Hybrid back at the helper's own instant. The
// drain follows the INSTANT, not the scheduler: it does not stand still for a hover, an idle user or a folded lane (it would show
// time the helper does not give), and the scheduler never sees it (the toast is sticky there, so nothing expires, is filed or is
// dropped when the drain reaches nothing). The same stepped drain, the same one-pixel steps; the source moves the instant with
// `update()`, and it stretches the span for a LATER instant (as the scheduler's thaw does) so that a drain never refills.
//
// A STICKY CRITICAL IS SHADED ACROSS. With no countdown to carry the group's
// colour, a sticky toast of critical urgency takes the critical colour (the
// palette's, whichever group the record is filed in: a shell source's battery
// warning is "System" in the manager and critical on the lane) and takes its
// resting sliver out over the whole carve -- the full-width shade a countdown
// starts with, held (`shadeAll`). The reach is ONE eased fraction (`_shade`,
// the toast's own enter clock, OutCubic), so a critical arriving floods in with
// its toast and one that is not sticky (a rule gave it a timeout) is the plain
// countdown.
// =============================================================================
SwipeVerbCard {
    id: entry

    property string uid: ""
    property var service: null
    property var clock: null
    property Item overlayItem: null
    property GroupPalette groups: null
    property NotificationStyle style: null
    property real cardWidth: entry.style ? entry.style.toastWidth : 360
    property color surfaceColor: Theme.surface

    // The record, re-read whenever the service says something changed, and
    // written only when it IS another record (NotificationRow's rule): the
    // store bumps its serial for every record it touches, and a binding that
    // re-read the record would re-assign every toast's on every bump -- the
    // whole card re-bound for nothing (100 writes for 20 updates of one toast
    // of five, 80 of them the same record; 20 more over 5 arrivals into a full
    // stack, none a change). Which record is shown is
    // kept as a FIELD of a plain object: a `var` property hands back another
    // wrapper than the object written into it, so comparing with `d` never
    // matches. A record deleted under the card (the swipe that deleted it, its
    // app closing it) is KEPT: the card shows its face while it flies off.
    property var d: null
    readonly property var _shown: ({ record: null })
    function _pull() {
        const r = entry.service && entry.uid !== "" ? entry.service.store.get(entry.uid) : null;
        if (r && r !== entry._shown.record) {
            entry._shown.record = r;
            entry.d = r;
        }
    }
    onUidChanged: entry._pull()
    onServiceChanged: entry._pull()
    Connections {
        target: entry.service
        ignoreUnknownSignals: true
        function onSerialChanged() {
            entry._pull();
        }
    }
    readonly property int flood: entry.service && entry.service.toasts && entry.service.toasts.serial >= 0
        ? (entry.service.toasts.floods[entry.uid] || 0) : 0
    readonly property bool replyOpen: face.replyOpen

    // A FIXED record (the source's own live UI, NotificationService) has no
    // verbs: a swipe only gives, a click does nothing.
    readonly property bool fixed: !!entry.d && entry.d.fixed === true
    // A live record (NotificationService, LIVE) hides both ways.
    readonly property bool live: !!entry.d && entry.d.live === true
    // Any other: what notifications.jsonc gives each side (toasts.swipe: "file" | "delete").
    readonly property var _swipe: entry.service && entry.service.config ? entry.service.config.toasts.swipe : ({ right: "file", left: "delete" })
    rightVerb: entry.fixed ? "" : (entry.live ? "hide" : entry._swipe.right)
    leftVerb: entry.fixed ? "" : (entry.live ? "hide" : entry._swipe.left)
    // The side a toast that files by itself goes to.
    readonly property int fileDir: entry.rightVerb !== "file" && entry.leftVerb === "file" ? -1 : 1
    // A KEPT record (a mounted drive's card): the delete swipe says no (SwipeVerbCard.refuse).
    readonly property bool _kept: !!entry.d && entry.d.kept === true
    rightRefuses: entry._kept && entry.rightVerb === "delete"
    leftRefuses: entry._kept && entry.leftVerb === "delete"
    groundColor: entry.surfaceColor
    radius: face.radius
    // The swipe's tuning, from the one style (the mockup's Swipe tab).
    commitFraction: entry.style ? entry.style.swipeCommitFraction : 0.4
    fadeFrom: entry.style ? entry.style.swipeFadeFrom : 0.45
    maxFraction: entry.style ? entry.style.swipeMaxFraction : 0.8
    flyMs: entry.style ? entry.style.swipeFlyMs : 260
    springMs: entry.style ? entry.style.swipeSpringMs : 260
    swingMs: entry.style ? entry.style.swipeSwingMs : 120
    flingPxPerS: entry.style ? entry.style.swipeFlingPxPerS : 900
    dragThreshold: entry.style ? entry.style.swipeDragThreshold : 6
    glyphSize: entry.style ? entry.style.swipeGlyphSize : 20
    glyphInset: entry.style ? entry.style.swipeGlyphInset : 12
    wellShadowWidth: entry.style ? entry.style.swipeWellShadowWidth : 4
    wellBevelWidth: entry.style ? entry.style.swipeWellBevelWidth : 1
    blockedGivePx: entry.style ? entry.style.swipeBlockedGivePx : 24

    implicitWidth: face.implicitWidth
    implicitHeight: face.implicitHeight

    NotificationCard {
        id: face
        d: entry.d
        service: entry.service
        clock: entry.clock
        overlayItem: entry.overlayItem
        style: entry.style
        cardWidth: entry.cardWidth
        groupColor: entry.groups && entry.d ? entry.groups.color(entry._alarm ? "critical" : entry.d.group) : Theme.accent
        countdown: entry._sticky ? -1 : entry.timeLeft
        shadeAll: entry._shade
        footnote: entry.flood > 0 ? "+" + entry.flood + " more from " + (entry.d ? entry.d.appName : "") : ""
        onReplyToggled: open => {
            if (entry.service && entry.service.toasts)
                entry.service.toasts.replying(open, entry.uid);
        }
    }

    onClicked: {
        if (entry.service && entry.uid !== "" && !entry.fixed)
            entry.service.activate(entry.uid);
    }

    // ---- the countdown ---------------------------------------------------------
    //
    // STEPPED, NOT ANIMATED. The drain is the only thing on the bar's window that
    // moves while a toast counts, and Qt Quick has no damage regions: every
    // frame it asks for repaints the whole engine surface. A NumberAnimation
    // asks for every frame (63 frames/s, 5.8 % of a thread, 17 GPU ms/s), so the
    // boundary moves in steps instead, each armed as ONE single-shot timer for
    // the instant the boundary reaches the next step -- the frames it costs are
    // the steps it takes, nothing between them.
    //
    // THE STEP IS A WHOLE NUMBER OF DEVICE PIXELS OF THE BOUNDARY'S OWN TRAVEL. ShadowBox moves the boundary from one half-feather
    // before the card's left edge to one half-feather past its right (-f + p * (width + 2 f)), so a fraction of the CARD'S WIDTH
    // (what this counted against until round 5) is 4.27 px for a "4 px" step and lands the boundary between pixels. A step is
    // `drainStepPx` (1: the gradient advances a pixel at a time) or, for a toast so short that a pixel falls due faster than the
    // 16 ms timer floor, the fewest whole pixels that the floor allows (`_stepPx`). The pixel is the device's: `renderScale`.
    // Measured against the shader's own pixels by tools/dev/toast_drain_probe.sh.
    property real timeLeft: 1
    property bool _sticky: true
    // A sticky critical (see the header): its shade across the carve, eased. Only once the
    // timing has been READ (`_read`): `_sticky` starts true before anybody has asked, and a
    // critical that counts down (a rule gave it a timeout) must never flash the full shade first.
    property bool _read: false
    readonly property bool _alarm: !!entry.d && entry.d.urgency === "critical" && entry._sticky && entry._read
    property real _shade: entry._alarm ? 1 : 0
    Behavior on _shade {
        NumberAnimation {
            duration: entry.style ? entry.style.enterMs : 260
            easing.type: Easing.OutCubic
        }
    }
    property real drainStepPx: entry.style ? entry.style.drainStepPx : 1
    property real _endAt: 0            // wall-clock ms the time runs out
    property real _totalMs: 0
    readonly property real _featherPx: entry.style ? entry.style.shadeFeatherPx : 12
    // device px the boundary travels end to end (ShadowBox._boundaryX), not fractional: a step is n / this
    readonly property real _sweepPx: Math.max(1, (entry.width + 2 * entry._featherPx) * (entry.style ? entry.style.renderScale : 1))
    // whole device px per step: the asked one, or more when a pixel falls due faster than the timer's 16 ms floor
    readonly property int _stepPx: Math.max(1, Math.round(entry.drainStepPx),
                                            entry._totalMs > 0 ? Math.ceil(16 / (entry._totalMs / entry._sweepPx)) : 1)
    // the fraction one step is
    readonly property real _q: entry._stepPx / entry._sweepPx
    function _step() {
        const left = Math.max(0, entry._endAt - Date.now());
        const frac = left / entry._totalMs;
        // Quantised to the step: the drawn fraction only ever changes on a step.
        const q = entry._q;
        entry.timeLeft = Math.min(1, Math.ceil(frac / q) * q);
        if (left <= 0)
            return;
        const nextFrac = entry.timeLeft - q;
        const waitMs = (frac - Math.max(0, nextFrac)) * entry._totalMs;
        stepper.interval = Math.max(16, Math.ceil(waitMs));
        stepper.restart();
    }
    Timer {
        id: stepper
        repeat: false
        onTriggered: entry._step()
    }
    // The record's own deadline (see the header), 0 when it has none; the key is the instant AND the span, either moving re-reads it.
    readonly property real _deadlineMs: !!entry.d && entry.d.deadlineMs > 0 && entry.d.deadlineTotalMs > 0 ? entry.d.deadlineMs : 0
    readonly property string _deadlineKey: entry._deadlineMs > 0 ? entry._deadlineMs + ":" + entry.d.deadlineTotalMs : ""
    function syncTiming() {
        const t = entry.service && entry.service.toasts && entry.uid !== ""
            ? entry.service.toasts.timing(entry.uid) : null;
        stepper.stop();
        if (entry._deadlineMs > 0) {
            // On the stack or not, frozen or not: the instant is what it is.
            entry._sticky = false;
            entry._read = true;
            entry._totalMs = entry.d.deadlineTotalMs;
            entry._endAt = entry._deadlineMs;
            entry._step();
            return;
        }
        // Off the stack (filed, deleted, its app closed it): the clock stops
        // where it is and the countdown keeps its state.
        if (!t)
            return;
        if (t.sticky || !(t.totalMs > 0)) {
            entry._sticky = true;
            entry._read = true;
            return;
        }
        entry._sticky = false;
        entry._read = true;
        entry._totalMs = t.totalMs;
        entry._endAt = Date.now() + Math.max(0, t.leftMs);
        if (entry.service.toasts.frozen) {
            // On the step, rounded up like `_step`: the fraction drawn while
            // frozen is the one the drain resumes from (a frozen read between
            // two steps would draw a sliver the thaw takes back).
            const q = entry._q;
            entry.timeLeft = Math.min(1, Math.ceil(Math.max(0, t.leftMs / t.totalMs) / q) * q);
            return;
        }
        entry._step();
    }
    Connections {
        target: entry.service ? entry.service.toasts : null
        ignoreUnknownSignals: true
        function onSerialChanged() {
            entry.syncTiming();
        }
        function onFrozenChanged() {
            entry.syncTiming();
        }
        // The deadline: the drain is at nothing, whichever timer came first.
        function onExpired(uid: string) {
            if (uid !== entry.uid || entry._sticky)
                return;
            stepper.stop();
            entry.timeLeft = 0;
        }
    }
    // A record that gained, moved or lost its deadline (a replace or an update puts a new record object here).
    on_DeadlineKeyChanged: entry.syncTiming()
    Component.onCompleted: {
        entry._pull();
        entry.syncTiming();
    }
}
