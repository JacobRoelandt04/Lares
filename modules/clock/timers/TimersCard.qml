pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"
import "../../common/theme"
import "../data/timers.js" as T
import "dial.js" as Dial
import "format.js" as Fmt

// =============================================================================
// TimersCard.qml -- the clock popup's Timers tab: ONE square carved card
// holding the timer, the pomodoro, the stopwatch and the alarms, switched
// the way the weather cards switch their views (CardViewCycler's dots and
// title, a two-finger swipe, one ViewBlend clock) -- no second tab row.
//
// The dial is the Workspaces groove bent into a ring, centred on every view.
// Inside it, under the figures, the main action and a row of icon actions
// under that are the CARD's: one element each across the timer, the pomodoro
// and the stopwatch, moved and resized on the one clock as the view changes.
// Each view places the rest round the ring (TimerView): a control beside the
// title, the bottom corners, or the band under the ring for a list. Between
// views the ring MORPHS on the one clock -- arcs open and close, fills slide,
// ticks and marks come and go -- while the leaving view's own controls go out
// over the first half and the arriving view's come in over the second: never
// two layouts at once.
//
// TIME IS SET BY WINDING the ring like a kitchen timer (dial.js has the
// scale): the first turn a quarter per order of magnitude -- 0-1 min, 1-10,
// 10-30, 30-60 -- sticky at each quarter's edge, then an hour a turn; the
// hand's angle rounded to its quarter's step, Shift a second per px moved.
// Each full turn stays as a full ring in its colour and the next grows over
// it in the next (Theme.timerCycle). Running, the fill unwinds at a
// constant pace from where it was set back to 12.
//
// The state lives in `timers` (TimerService), outside the popup. The card
// reads no wheel itself: the popup's one reader asks ownerAt() where a
// gesture began and hands it windBy() / cycleBy().
// =============================================================================
Item {
    id: card

    property var timers: null
    property string fontFamily: "Audiowide"
    // The tab is showing: only then does the display clock tick.
    property bool active: true
    property bool listWheelEnabled: true

    // ---- Layout ------------------------------------------------------------
    // The card is square: the host sizes it `side` x `side`.
    property real side: 454
    // The width of the CARVED BOX, centred on the card: the content (the dial, the views) is the square, but a host whose popup is
    // changing size round the card gives the box the room the popup has, so that the container comes in with the transition --
    // wide from the calendar's width, narrowing to the square as the popup does (the container must not stand static
    // coming from the much wider popup tab). Default: the card's own width.
    property real boxWidth: card.width
    property real padding: 12
    property real radius: 14
    property real dialRadius: 127
    property real dialLineThickness: 6
    property real dialSizeScale: 2
    // ---- The ring's material -------------------------------------------------
    property real fillHeadBulge: 1.0
    property real fillMergePx: 18
    // The rim outside the carve, subtler than the bar's: it fades from the
    // card's ground over its whole width instead of reaching the bevel colour
    // at once.
    property real ringBevelStrength: 0.6
    property var ringBevelEasing: [0.45, 0.0, 0.8, 0.6]
    // ---- Motion ------------------------------------------------------------
    property int transitionMs: 320
    property real pomodoroGapDeg: 14
    // ---- Winding -----------------------------------------------------------
    property real stickyDeg: 3              // each quarter edge's plateau, either side
    property real wheelStepDeg: 6           // a wheel notch over the ring
    property real wheelCtrlStepDeg: 30      // with Ctrl
    property real precisionMsPerPx: 1000    // Shift: ms per px of hand along the ring
    property real alarmDetentMin: 5         // by drag, on the 24 h dial
    property real windPixelUnits: 150       // touchpad travel per wheel step
    property real fieldPixelUnits: 1000     // touchpad travel per minute on a pomodoro duration
    property int fieldCooldownMs: 200       // and the pause after each minute
    property int settleMs: 120

    implicitWidth: card.side
    implicitHeight: card.side

    // THE OWNER'S CHOICE OF VIEW ({ view, serial }: a new object per ask; null for none): the card shows that view. It is taken once, when it arrives: a card that has only just been built, or
    // is not on show, goes there AT ONCE (the view's blend is put at its end: no morph to play while the popup opens, nothing to
    // see anyway), one that is on show is moved to it the way a swipe would.
    property var viewRequest: null
    property bool _settled: false
    Component.onCompleted: Qt.callLater(() => card._settled = true)
    onViewRequestChanged: {
        const r = card.viewRequest;
        if (!r || r.view < 0 || r.view >= card.views.length)
            return;
        card.showView(r.view);
        if (!card._settled || !card.active)
            blend.pin(1);
    }

    readonly property var views: [
        { id: "timer", label: "Timer" },
        { id: "pomodoro", label: "Pomodoro" },
        { id: "stopwatch", label: "Stopwatch" },
        { id: "alarm", label: "Alarms" }
    ]
    readonly property int viewIndex: cycler.currentIndex
    readonly property int shownView: blend.toView

    function cycleBy(units, fromPixels) {
        cycler.feed(units, fromPixels);
    }
    function endCycle() {
        cycler.end();
    }
    // Straight to a view (no title box), and -- for renders and probes --
    // the view blend held at a fraction of its switch.
    function showView(i) {
        cycler.currentIndex = i;
    }
    function pinTransition(t) {
        blend.pin(t);
    }

    // ---- Geometry every view shares ---------------------------------------
    readonly property real cx: Math.round(card.width / 2)
    readonly property real cy: Math.round(card.height / 2)
    readonly property real halfLine: card.dialLineThickness * card.dialSizeScale / 2
    readonly property real ringOuter: card.dialRadius + card.halfLine + 2 * card.dialSizeScale
    readonly property real innerRadius: card.dialRadius - card.halfLine - 2 * card.dialSizeScale - 16
    // Degrees the fill reaches past an arc's end to cover its round cap.
    readonly property real capDeg: card.halfLine / card.dialRadius * 180 / Math.PI

    // ---- The display clock -------------------------------------------------
    // One clock for everything the card shows moving, and it ticks only when
    // something on the SHOWN view is about to change: a countdown's or a
    // phase's next SECOND (its exact boundary -- a repeating tick at a ring-
    // derived interval would change the figure on a beat, three quick seconds and
    // then a pause) or half a pixel of its ring, whichever is first; every
    // frame for a running stopwatch (hundredths); the next minute on the
    // alarm dial; nothing at all otherwise.
    property real now: Date.now()
    function _now() {
        return card.timers ? card.timers.now() : Date.now();
    }
    // Real ms until the next tick; 0 = every frame; -1 = nothing moves.
    function _nextTick(now) {
        if (!card.active || !card.timers)
            return -1;
        const t = card.timers;
        const pxPerDeg = Math.PI / 180 * card.dialRadius;
        const toReal = ms => t.clock ? t.clock.realDelay(ms) : ms;
        // Until a countdown shown in whole seconds (rounded up) changes.
        const untilSecond = left => left - (Math.ceil(left / 1000) - 1) * 1000 + 1;
        const v = blend.toView;
        if (v === 0 && t.countdown.state === "running") {
            const left = Math.max(0, t.countdown.endsAt - now);
            const total = Math.max(1, t.countdown.totalMs);
            const pxPerMs = Dial.angleOfMs(total, card.stickyDeg) / total * pxPerDeg;
            return toReal(Math.min(untilSecond(left), 0.5 / Math.max(1e-9, pxPerMs)));
        }
        if (v === 1 && t.pomodoro.state === "running") {
            const left = Math.max(0, t.pomodoro.endsAt - now);
            const pxPerMs = 2 * Math.PI * card.dialRadius / 4 / Math.max(1, t.pomodoro.phaseMs);
            return toReal(Math.min(untilSecond(left), 0.5 / pxPerMs));
        }
        if (v === 2 && t.stopwatch.state === "running")
            return 0;
        if (v === 3)
            return toReal(60000 - now % 60000 + 5);
        return -1;
    }
    function _schedule() {
        card.now = card._now();
        const d = card._nextTick(card.now);
        frameTick.running = d === 0;
        if (d > 0) {
            tick.interval = Math.max(1, Math.ceil(d));
            tick.restart();
        } else {
            tick.stop();
        }
    }
    // What the schedule depends on; any change reschedules.
    readonly property var _scheduleKey: [card.active, blend.toView,
        card.timers ? card.timers.countdown : null, card.timers ? card.timers.pomodoro : null,
        card.timers ? card.timers.stopwatch : null, card.timers && card.timers.clock ? card.timers.clock.scale : 1]
    on_ScheduleKeyChanged: card._schedule()
    Timer {
        id: tick
        repeat: false
        onTriggered: card._schedule()
    }
    FrameAnimation {
        id: frameTick
        running: false
        onTriggered: card.now = card._now()
    }

    // Something finished: dust off where it filled -- the countdown's ring,
    // the pomodoro phase's arc (the long break: the whole ring), round an
    // alarm's mark.
    Connections {
        target: card.timers
        ignoreUnknownSignals: true
        function onFinished(kind, info) {
            if (!card.visible)
                return;
            if (kind === "countdown") {
                dial.burst(0, 360, Theme.timerRun);
            } else if (kind === "pomodoro") {
                const half = 45 - card.pomodoroGapDeg / 2;
                if (info.phase === "long") {
                    dial.burst(0, 360, Theme.timerBreak);
                } else {
                    const s0 = card._mids[info.session] - half - card.capDeg;
                    dial.burst(s0, s0 + 2 * half + 2 * card.capDeg, info.phase === "focus" ? Theme.timerFocus : Theme.timerBreak);
                }
            } else if (kind === "alarm") {
                const d = new Date(info.at);
                const a = (d.getHours() * 60 + d.getMinutes()) / 1440 * 360;
                dial.burst(a - 12, a + 12, Theme.accent);
            }
        }
    }

    ViewBlend {
        id: blend
        count: card.views.length
        target: card.viewIndex
        durationMs: card.transitionMs
    }

    // ---- The card ----------------------------------------------------------
    ShadowBox {
        x: Math.round((card.width - card.boxWidth) / 2)
        y: 0
        width: card.boxWidth
        height: card.height
        baseWidth: width
        baseHeight: height
        baseRadius: card.radius
        surfaceColor: Theme.surface
        backgroundColor: Theme.listBox
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        bevelWidth: 1
        shadowWidth: 3
    }

    // ---- The ring, per view ------------------------------------------------
    // Each view's ring as numbers; the frame blends them by the view weights.
    // Pomodoro sessions, clockwise from the top.
    readonly property var _mids: [0, 90, 180, 270]

    function _dep() {
    }
    function _empty(anchor) {
        return [anchor, anchor];
    }
    // A fill of `theta` degrees, any number of turns: the turn it is on grows
    // in its colour over the full ring of the turn before, so a completed
    // turn never goes back to empty.
    function _revolutions(s, theta, palette) {
        const rev = Math.floor(theta / 360 + 1e-9);
        const rem = Math.max(0, theta - rev * 360);
        const n = palette.length;
        s.colB = palette[rev % n];
        s.b[0] = [0, rem];
        if (rev >= 1) {
            s.colA = palette[(rev - 1) % n];
            s.a[0] = [0, 360];
        } else {
            s.colA = s.colB;
        }
    }
    // The timer's wound angle: the hand while it winds, the set time at
    // rest, and running, the set angle unwound at a constant pace.
    function _timerAngle(now) {
        const c = card.timers.countdown;
        if (card._windPreview >= 0 && card._windView === 0)
            return card._windPreview;
        if (c.state === "running" || c.state === "paused") {
            const total = Math.max(1, c.totalMs);
            return Dial.angleOfMs(total, card.stickyDeg) * T.countdownRemaining(c, now) / total;
        }
        if (c.state === "done")
            return 0;
        return Dial.angleOfMs(c.setMs, card.stickyDeg);
    }
    function _specOf(v, now) {
        const t = card.timers;
        const s = { gap: 0, a: [], b: [], colA: Theme.timerRun, colB: Theme.timerRun,
                    even: 1, odd: 0, hours: 0, marks: 0, hand: 0, handAngle: 0 };
        for (let i = 0; i < 4; i++) {
            s.a.push(card._empty(0));
            s.b.push(card._empty(0));
        }
        if (!t)
            return s;
        if (v === 0) {
            card._revolutions(s, card._timerAngle(now), Theme.timerCycle);
        } else if (v === 1) {
            const p = t.pomodoro;
            s.gap = card.pomodoroGapDeg;
            s.colA = Theme.timerFocus;
            s.colB = Theme.timerBreak;
            s.even = 0;
            const half = 45 - s.gap / 2;
            const span = 2 * half + 2 * card.capDeg;
            const focusF = p.pieces.map(x => x.focus), brkF = p.pieces.map(x => x.brk);
            if (p.state === "running" || p.state === "paused") {
                const left = p.state === "running" ? Math.max(0, p.endsAt - now) : p.remainMs;
                const prog = 1 - left / Math.max(1, p.phaseMs);
                if (p.phase === "focus")
                    focusF[p.session] = prog;
                else if (p.phase === "short")
                    brkF[p.session] = prog;
                else
                    for (let i = 0; i < 4; i++) {
                        focusF[i] *= 1 - prog;
                        brkF[i] *= 1 - prog;
                    }
            }
            for (let i = 0; i < 4; i++) {
                const s0 = card._mids[i] - half - card.capDeg;
                s.a[i] = [s0, s0 + focusF[i] * span];
                s.b[i] = [s0, s0 + brkF[i] * span];
            }
        } else if (v === 2) {
            // A turn a minute, each minute over the full ring of the last.
            card._revolutions(s, T.stopwatchElapsed(t.stopwatch, now) / 60000 * 360, Theme.timerCycle);
            s.marks = 1;
        } else {
            const d = new Date(now);
            const nowA = (d.getHours() * 60 + d.getMinutes() + d.getSeconds() / 60) / 1440 * 360;
            s.colA = Theme.accent;
            s.colB = Theme.accent;
            s.even = 1;
            s.odd = 1;
            s.hours = 1;
            s.hand = 1;
            s.handAngle = nowA;
            s.marks = 1;
            const tgt = card._alarmTarget();
            if (tgt >= 0) {
                let a = tgt / 1440 * 360;
                while (a <= nowA)
                    a += 360;
                s.a[0] = [nowA, a];
            } else {
                s.a[0] = card._empty(nowA);
            }
        }
        return s;
    }

    // Minutes of the day the alarm dial points at: the alarm being edited
    // (or wound), else the next one to ring; -1 for none.
    function _alarmTarget() {
        const t = card.timers;
        if (card._windPreview >= 0 && card._windView === 3)
            return card._windPreview;
        const i = alarmView.selected !== "" ? t._alarmIndex(alarmView.selected) : -1;
        if (i >= 0) {
            const a = t.alarms.get(i);
            return a.hour * 60 + a.minute;
        }
        if (t.nextAlarm) {
            const d = new Date(t.nextAlarm.at);
            return d.getHours() * 60 + d.getMinutes();
        }
        return -1;
    }

    // Marks on the rim: the stopwatch's last laps, the alarms. Facts only.
    function _marksOf(v) {
        const t = card.timers;
        const out = [];
        if (!t)
            return out;
        if (v === 2) {
            for (let i = 0; i < Math.min(6, t.laps.count); i++)
                out.push({ angle: (t.laps.get(i).totalMs % 60000) / 60000 * 360, strong: i === 0 });
        } else if (v === 3) {
            for (let i = 0; i < t.alarms.count; i++) {
                const a = t.alarms.get(i);
                if (!a.enabled && a.aid !== alarmView.selected)
                    continue;
                const strong = a.aid === alarmView.selected || (t.nextAlarm && t.nextAlarm.id === a.aid && alarmView.selected === "");
                out.push({ angle: (a.hour * 60 + a.minute) / 1440 * 360, strong: strong });
            }
        }
        return out;
    }

    // ONE object per change: every reader of the frame sees one generation.
    readonly property var _frame: {
        const w = blend.weights;
        const now = card.now;
        const t = card.timers;
        // Dependencies the functions below read through calls: read here,
        // so a change re-runs the frame.
        if (t)
            card._dep(t.countdown, t.pomodoro, t.stopwatch, t.alarmSerial, t.laps.count, t.nextAlarm);
        card._dep(card._windPreview, card._windView, alarmView.selected, Theme.timerCycle);
        const specs = [];
        for (let v = 0; v < 4; v++)
            specs.push(w[v] > 0 ? card._specOf(v, now) : null);
        const mix = fn => blend.mix(v => fn(specs[v]));
        const mixC = fn => blend.mixColor(v => specs[v] ? fn(specs[v]) : null);
        const slots = (key, i, j) => mix(s => s[key][i][j]);
        return {
            gap: mix(s => s.gap),
            colA: mixC(s => s.colA),
            colB: mixC(s => s.colB),
            aS: [0, 1, 2, 3].map(i => slots("a", i, 0)),
            aE: [0, 1, 2, 3].map(i => slots("a", i, 1)),
            bS: [0, 1, 2, 3].map(i => slots("b", i, 0)),
            bE: [0, 1, 2, 3].map(i => slots("b", i, 1)),
            even: mix(s => s.even),
            odd: mix(s => s.odd),
            hours: mix(s => s.hours),
            marksP: mix(s => s.marks),
            hand: mix(s => s.hand),
            handAngle: specs[3] ? specs[3].handAngle : 0,
            marks: card._marksOf(blend.toView)
        };
    }

    // ---- The figures -------------------------------------------------------
    // The SHOWN view's own words; a switch swaps them at once.
    readonly property var _words: {
        const t = card.timers;
        const now = card.now;
        if (!t)
            return { figure: "", caption: "" };
        card._dep(t.countdown, t.pomodoro, t.stopwatch, t.alarmSerial, t.nextAlarm, card._windPreview, alarmView.selected);
        switch (blend.toView) {
        case 0: {
            const c = t.countdown;
            if (c.state === "idle")
                return { figure: Fmt.countdown(c.setMs), caption: "" };
            const left = T.countdownRemaining(c, now);
            const cap = c.state === "running" ? "ends " + Fmt.clockOf(c.endsAt)
                : c.state === "paused" ? "paused" : c.state === "done" ? "done" : "";
            return { figure: Fmt.countdown(left), caption: cap };
        }
        case 1: {
            const p = t.pomodoro;
            const left = p.state === "running" ? Math.max(0, p.endsAt - now) : t.pomoRemainingMs();
            const cap = p.state === "idle" ? "4 × " + Fmt.minutes(t.focusMs)
                : p.state === "waiting" ? (p.next && p.next.phase === "focus" ? "focus next" : "break next")
                : (p.phase === "focus" ? "focus " + (p.session + 1) + " of 4" : p.phase === "long" ? "long break" : "break")
                  + (p.state === "paused" ? ", paused" : "");
            return { figure: Fmt.countdown(left), caption: cap };
        }
        case 2: {
            const e = T.stopwatchElapsed(t.stopwatch, now);
            return { figure: Fmt.stopwatch(e), caption: t.laps.count > 0 ? "lap " + (t.laps.count + 1) : "" };
        }
        default: {
            const tgt = card._alarmTarget();
            if (tgt < 0)
                return { figure: "--:--", caption: "no alarm" };
            const hh = Math.floor(tgt / 60) % 24, mm = Math.round(tgt % 60);
            // The instant the alarm will ring (the service's own rule), not "today's time, or +24 h": a day is 23 or
            // 25 h across a DST change and the caption would be an hour off.
            const at = T.nextOccurrence({ hour: hh, minute: mm, days: 0 }, now);
            return { figure: Fmt.clock(hh, mm), caption: Fmt.until(at - now) };
        }
        }
    }

    // ---- Winding -----------------------------------------------------------
    // What the ring shows while a hand winds it -- degrees for the timer,
    // minutes of the day for an alarm -- and on which view; -1 when nobody is.
    property real _windPreview: -1
    property int _windView: -1
    property real _windMs: 0
    property real _windBase: 0
    property real _windAccum: 0
    property real _windPx: 0

    readonly property bool windable: {
        const t = card.timers;
        if (!t)
            return false;
        if (blend.toView === 0)
            return t.countdown.state === "idle" || t.countdown.state === "done";
        if (blend.toView === 3)
            return alarmView.selected !== "";
        return false;
    }

    function _clamp(v, lo, hi) {
        return Math.max(lo, Math.min(hi, v));
    }

    function _windStart() {
        settle.stop();
        const t = card.timers;
        card._windAccum = 0;
        card._windView = card.shownView;
        if (card.shownView === 0) {
            if (t.countdown.state === "done")
                t.dismiss("countdown");
            card._windMs = t.countdown.setMs;
            card._windPreview = Dial.angleOfMs(card._windMs, card.stickyDeg);
        } else {
            card._windBase = card._alarmTarget();
            card._windPreview = card._windBase;
        }
    }
    function _wound(deltaDeg, modifiers) {
        const t = card.timers;
        if (card._windView === 0) {
            let ms;
            if (modifiers & Qt.ShiftModifier) {
                // Precise: a second per px the hand moves along the ring; the
                // fill shows that time, not the hand.
                const px = deltaDeg * Math.PI / 180 * card.dialRadius;
                card._windMs = card._clamp(card._windMs + px * card.precisionMsPerPx, 0, Dial.MAX_MS);
                card._windPreview = Dial.angleOfMs(card._windMs, card.stickyDeg);
                ms = Math.round(card._windMs / 1000) * 1000;
            } else {
                // Clamped at both stops, so turning back answers at once.
                card._windPreview = card._clamp(card._windPreview + deltaDeg, 0, Dial.maxAngle(card.stickyDeg));
                card._windMs = Dial.msOfAngle(card._windPreview, card.stickyDeg);
                ms = Dial.quantize(card._windMs);
            }
            if (ms !== t.countdown.setMs)
                t.setCountdown(ms);
        } else if (card._windView === 3) {
            card._windAccum += deltaDeg;
            let m = card._windBase + card._windAccum / 360 * 1440;
            m = ((m % 1440) + 1440) % 1440;
            card._windPreview = m;
            const snapped = (Math.round(m / card.alarmDetentMin) * card.alarmDetentMin) % 1440;
            card._setAlarmMinutes(snapped);
        }
    }
    function _windEnd() {
        if (card._windPreview < 0)
            return;
        // The fill settles onto the time the figures already show.
        const t = card.timers;
        settle.from = card._windPreview;
        settle.to = card._windView === 0 ? Dial.angleOfMs(t.countdown.setMs, card.stickyDeg) : card._alarmTarget();
        if (card._windView === 3 && Math.abs(settle.to - settle.from) > 720)
            settle.to += settle.to < settle.from ? 1440 : -1440;
        settle.restart();
    }
    NumberAnimation {
        id: settle
        target: card
        property: "_windPreview"
        duration: card.settleMs
        easing.type: Easing.OutCubic
        onStopped: {
            card._windPreview = -1;
            card._windView = -1;
        }
    }
    function _setAlarmMinutes(m) {
        const t = card.timers;
        const i = t._alarmIndex(alarmView.selected);
        if (i < 0)
            return;
        const a = t.alarms.get(i);
        const h = Math.floor(m / 60), mm = m % 60;
        if (a.hour !== h || a.minute !== mm)
            t.updateAlarm(alarmView.selected, { hour: h, minute: mm });
    }

    // The wheel over the ring: a notch turns the hand `wheelStepDeg` (Ctrl
    // `wheelCtrlStepDeg`), so it follows the dial's own scale; Shift is a
    // second a notch. On the alarm dial: a minute a notch, Ctrl an hour.
    function windBy(units, fromPixels, modifiers) {
        let steps = 0;
        if (fromPixels) {
            card._windPx += units;
            while (Math.abs(card._windPx) >= card.windPixelUnits) {
                steps += card._windPx > 0 ? 1 : -1;
                card._windPx -= (card._windPx > 0 ? 1 : -1) * card.windPixelUnits;
            }
        } else {
            steps = units > 0 ? 1 : (units < 0 ? -1 : 0);
        }
        if (steps === 0 || !card.windable)
            return;
        const t = card.timers;
        const ctrl = (modifiers & Qt.ControlModifier) !== 0;
        if (card.shownView === 0) {
            if (t.countdown.state === "done")
                t.dismiss("countdown");
            const cur = t.countdown.setMs;
            let ms;
            if (modifiers & Qt.ShiftModifier) {
                ms = cur + steps * 1000;
            } else {
                const deg = Dial.angleOfMs(cur, card.stickyDeg) + steps * (ctrl ? card.wheelCtrlStepDeg : card.wheelStepDeg);
                ms = Dial.quantize(Dial.msOfAngle(Math.max(0, deg), card.stickyDeg));
                // Never a dead notch: at least one step of the quarter.
                if (ms === cur)
                    ms = Dial.quantize(cur + steps * Dial.stepOf(cur + (steps > 0 ? 0 : -1)));
            }
            t.setCountdown(card._clamp(ms, 0, Dial.MAX_MS));
        } else {
            const size = ctrl ? 60 : 1;
            const cur = card._alarmTarget();
            card._setAlarmMinutes((((cur + steps * size) % 1440) + 1440) % 1440);
        }
    }

    // ---- Where a gesture begins -------------------------------------------
    // "dial" (the groove, while it can be wound), "field" (a duration),
    // "list" (a list that scrolls), or "card".
    function ownerAt(px, py) {
        const r = Math.hypot(px - card.cx, py - card.cy);
        if (card.windable && Math.abs(r - card.dialRadius) <= card.halfLine + 2 * card.dialSizeScale + dial.grabSlack)
            return { kind: "dial", target: null };
        const view = card._views[card.shownView];
        if (view) {
            const f = view.fieldAt(px, py);
            if (f)
                return { kind: "field", target: f };
            const vp = view.listViewport;
            if (vp) {
                const lq = vp.mapFromItem(card, px, py);
                if (lq.x >= 0 && lq.y >= 0 && lq.x < vp.width && lq.y < vp.height && vp.contentHeight > vp.height)
                    return { kind: "list", target: vp };
            }
        }
        return { kind: "card", target: null };
    }
    readonly property var _views: [countdownView, pomodoroView, stopwatchView, alarmView]
    // For probes: where the dial and the views are.
    readonly property var panels: card._views

    // ---- The dial ----------------------------------------------------------
    TimerDial {
        id: dial
        width: implicitWidth
        height: implicitHeight
        x: card.cx - width / 2
        y: card.cy - height / 2
        radius: card.dialRadius
        lineThickness: card.dialLineThickness
        sizeScale: card.dialSizeScale
        fontFamily: card.fontFamily
        fillHeadBulge: card.fillHeadBulge
        fillMergePx: card.fillMergePx
        bevelStrength: card.ringBevelStrength
        bevelEasing: card.ringBevelEasing
        gapDeg: card._frame.gap
        fillA: card._frame.colA
        fillB: card._frame.colB
        aStarts: card._frame.aS
        aEnds: card._frame.aE
        bStarts: card._frame.bS
        bEnds: card._frame.bE
        evenTicks: card._frame.even
        oddTicks: card._frame.odd
        hourLabels: card._frame.hours
        marks: card._frame.marks
        marksShown: card._frame.marksP
        handAngle: card._frame.handAngle
        handShown: card._frame.hand
        figure: card._words.figure
        caption: card._words.caption
        figureOffsetY: -34
        windable: card.windable
        onWindStarted: card._windStart()
        onWound: (d, mods) => card._wound(d, mods)
        onWindEnded: card._windEnd()
    }

    // The view's name, top-left; it swaps at once.
    Text {
        x: Math.round(card.padding + 2)
        y: Math.round(card.padding + 2)
        text: card.views[blend.toView].label
        color: Theme.textPrimary
        font.family: card.fontFamily
        font.pixelSize: 16
        font.bold: true
    }

    // ---- The views ---------------------------------------------------------
    // Each view's own half of a switch: gone by the midpoint, back over the
    // second half.
    function _presence(v) {
        return Math.max(0, 2 * blend.weights[v] - 1);
    }
    CountdownView {
        id: countdownView
        timers: card.timers
        fontFamily: card.fontFamily
        presence: card._presence(0)
        current: blend.toView === 0
        side: card.side
        padding: card.padding
        cx: card.cx
        cy: card.cy
        ringOuter: card.ringOuter
        innerRadius: card.innerRadius
    }
    PomodoroView {
        id: pomodoroView
        timers: card.timers
        fontFamily: card.fontFamily
        presence: card._presence(1)
        current: blend.toView === 1
        fieldPixelUnits: card.fieldPixelUnits
        fieldCooldownMs: card.fieldCooldownMs
        side: card.side
        padding: card.padding
        cx: card.cx
        cy: card.cy
        ringOuter: card.ringOuter
        innerRadius: card.innerRadius
    }
    StopwatchView {
        id: stopwatchView
        timers: card.timers
        fontFamily: card.fontFamily
        presence: card._presence(2)
        current: blend.toView === 2
        listWheelEnabled: card.listWheelEnabled
        side: card.side
        padding: card.padding
        cx: card.cx
        cy: card.cy
        ringOuter: card.ringOuter
        innerRadius: card.innerRadius
    }
    AlarmView {
        id: alarmView
        timers: card.timers
        fontFamily: card.fontFamily
        presence: card._presence(3)
        current: blend.toView === 3
        listWheelEnabled: card.listWheelEnabled
        side: card.side
        padding: card.padding
        cx: card.cx
        cy: card.cy
        ringOuter: card.ringOuter
        innerRadius: card.innerRadius
    }

    // ---- The actions the views share ---------------------------------------
    // The main action and the icon row under it are ONE element each across
    // the timer (0), the pomodoro (1) and the stopwatch (2): a switch among
    // those moves and resizes them on the blend's clock and swaps their words
    // and glyphs at once -- nothing goes out and comes back. The row is
    // [Reset] on the timer, [Skip, Reset] on the pomodoro, [Lap, Reset] on
    // the stopwatch: the lead icon slides out from under Reset as the row
    // grows. The alarms have none of them (their Stop / Snooze is their own),
    // so there they go and come as a view's own controls do.
    // Every view has the same geometry; the shared controls take it from one.
    readonly property real actionY: countdownView.innerY
    readonly property real iconRowY: countdownView.iconY
    readonly property real iconSize: 30
    readonly property real iconGap: 10
    // A number over the views that HAVE an element, weighted and normalised:
    // leaving for a view without it, the element holds where it was.
    function _mixOver(has, fn) {
        const w = blend.weights;
        let s = 0, n = 0;
        for (let v = 0; v < w.length; v++) {
            if (w[v] > 0 && has(v)) {
                s += w[v] * fn(v);
                n += w[v];
            }
        }
        return n > 0 ? s / n : fn(0);
    }
    // An element's presence: the views that have it, by the view rule --
    // gone by a switch's midpoint, back over its second half.
    function _presenceOver(has) {
        const w = blend.weights;
        let p = 0;
        for (let v = 0; v < w.length; v++) {
            if (has(v))
                p += w[v];
        }
        return Math.max(0, 2 * p - 1);
    }
    readonly property var _hasAction: v => v <= 2
    readonly property var _hasLead: v => v === 1 || v === 2
    // The main action's words on each view (the alarms have none).
    readonly property var _actionTexts: {
        const t = card.timers;
        if (!t)
            return ["Start", "Start", "Start", ""];
        const c = t.countdown, p = t.pomodoro, s = t.stopwatch;
        return [
            t.ringing.countdown ? "Stop" : c.state === "running" ? "Pause" : c.state === "paused" ? "Resume" : "Start",
            p.state === "idle" ? "Start" : p.state === "running" ? "Pause" : p.state === "paused" ? "Resume"
                : p.next && p.next.phase === "focus" ? "Start focus" : "Start break",
            s.state === "running" ? "Pause" : s.state === "paused" ? "Resume" : "Start",
            ""
        ];
    }
    // Each view's label measured in the button's face: the width eases
    // between them while the word swaps at once.
    TextMetrics {
        id: actionM0
        font.family: primaryAction.fontFamily
        font.pixelSize: primaryAction.fontPixelSize
        font.bold: primaryAction.bold
        text: card._actionTexts[0]
    }
    TextMetrics {
        id: actionM1
        font: actionM0.font
        text: card._actionTexts[1]
    }
    TextMetrics {
        id: actionM2
        font: actionM0.font
        text: card._actionTexts[2]
    }
    function _actionWidth(v) {
        const m = [actionM0, actionM1, actionM2][v];
        return Math.max(primaryAction.minWidth, Math.ceil(m.advanceWidth) + 2 * primaryAction.horizontalPadding);
    }
    TimerButton {
        id: primaryAction
        objectName: "timersPrimary"
        accent: true
        readonly property real presence: card._presenceOver(card._hasAction)
        width: Math.round(card._mixOver(card._hasAction, v => card._actionWidth(v)))
        x: Math.round(card.cx - width / 2)
        y: card.actionY
        opacity: primaryAction.presence * primaryAction.presence
        visible: primaryAction.presence > 0.001
        text: blend.textOf(card._actionTexts, card._hasAction)
        enabled: {
            const t = card.timers;
            if (!t)
                return false;
            switch (blend.toView) {
            case 0:
                return !!t.ringing.countdown || t.countdown.state === "running" || t.countdown.state === "paused" || t.countdown.setMs > 0;
            case 1:
            case 2:
                return true;
            default:
                return false;
            }
        }
        onClicked: {
            const t = card.timers;
            switch (blend.toView) {
            case 0:
                if (t.ringing.countdown)
                    t.dismiss("countdown");
                else if (t.countdown.state === "running")
                    t.pause();
                else if (t.countdown.state === "paused")
                    t.resume();
                else
                    t.start();
                break;
            case 1:
                if (t.pomodoro.state === "running")
                    t.pomoPause();
                else
                    t.pomoStart();
                break;
            case 2:
                if (t.stopwatch.state === "running")
                    t.swPause();
                else
                    t.swStart();
                break;
            }
        }
    }
    // The lead icon (Skip, Lap) under Reset in the stacking order: on the
    // timer it sits exactly under Reset, so the row's growth is Reset
    // sliding right while the lead slides out left from beneath it.
    TimerIconButton {
        id: leadIcon
        objectName: "timersLeadIcon"
        readonly property real presence: card._presenceOver(card._hasLead)
        x: Math.round(card._mixOver(card._hasAction, v => v === 0 ? card.cx - card.iconSize / 2
                                                                  : card.cx - card.iconSize - card.iconGap / 2))
        y: card.iconRowY
        opacity: leadIcon.presence * leadIcon.presence
        visible: leadIcon.presence > 0.001
        glyph: blend.textOf(["", "\u{F04AD}", "\u{F023B}", ""], card._hasLead)   // md-skip_next, md-flag
        confirm: blend.toView === 1
        enabled: {
            const t = card.timers;
            if (!t)
                return false;
            if (blend.toView === 1)
                return t.pomodoro.state === "running" || t.pomodoro.state === "paused";
            if (blend.toView === 2)
                return t.stopwatch.state === "running";
            return false;
        }
        onActivated: blend.toView === 1 ? card.timers.pomoSkip() : card.timers.swLap()
    }
    TimerIconButton {
        id: resetIcon
        objectName: "timersResetIcon"
        readonly property real presence: card._presenceOver(card._hasAction)
        x: Math.round(card._mixOver(card._hasAction, v => v === 0 ? card.cx - card.iconSize / 2 : card.cx + card.iconGap / 2))
        y: card.iconRowY
        opacity: resetIcon.presence * resetIcon.presence
        visible: resetIcon.presence > 0.001
        glyph: "\u{F0709}"                 // md-restart
        // Throwing a pomodoro away takes two clicks; the others one.
        confirm: blend.toView === 1
        enabled: {
            const t = card.timers;
            if (!t)
                return false;
            switch (blend.toView) {
            case 0:
                return t.countdown.state !== "idle";
            case 1:
                return t.pomodoro.state !== "idle";
            case 2:
                return t.stopwatch.state !== "idle" || t.laps.count > 0;
            default:
                return false;
            }
        }
        onActivated: {
            const t = card.timers;
            if (blend.toView === 0)
                t.reset();
            else if (blend.toView === 1)
                t.pomoReset();
            else if (blend.toView === 2)
                t.swReset();
        }
    }

    CardViewCycler {
        id: cycler
        anchors.fill: parent
        views: card.views
        orientation: "vertical"
        radius: card.radius
        fontFamily: card.fontFamily
        groundColor: Theme.listBox
    }
}
