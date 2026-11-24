pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"

// =============================================================================
// FrameJournalHook -- one window's frame watch for the FrameJournal (docs/agent_added_files_and_folders/
// perf_pass/JOURNAL.md has the design, the measurements and the patterns per platform).
//
// MOUNT IT with one line in any window that draws (it finds its window through its own Window.window, so it goes anywhere in
// the window's item tree; it draws nothing and takes no input):
//
//     FrameJournalHook { windowName: "bar"; screenName: win.outputName; engine: screenFrame.engine; frame: screenFrame }
//     FrameJournalHook { windowName: "osd-pill"; screenName: win._name }
//
//   windowName   what the window is ("bar", "osd-pill", "toast-pill", "auth-pill", a probe's own)
//   screenName   the output it is on
//   engine       a GooeyEngine (optional): its bodies' phases are the popups' context and their starts the transitions timed
//   frame        a ShellFrame (optional): the island moves and the bars toggle, and its services' focus changes
//
// WHAT IT WATCHES. Two signals of its QQuickWindow, both seen on the GUI thread: `afterAnimating` ("a": the GUI thread has
// polished the next frame and hands it to the render thread; emitted directly) and `frameSwapped` ("s": the render thread has
// presented it; emitted on the render thread and QUEUED to the GUI thread, so its time is when the GUI thread got to it). Each
// handler writes its time into a ring (48 events); the swap handler measures the interval since the last swap and restarts the
// HEARTBEAT (a single-shot Timer of 1.25 periods). Nothing else happens on a frame that came on time. At rest no frame is drawn:
// neither handler runs and no timer is armed (the heartbeat fires once after a run's last frame).
//
// A MISSED FRAME. A swap interval longer than max(1.5, 1 + 5 ms) display periods whose previous interval was part of a run
// (<= 40 ms: the window was rendering continuously) is a candidate. On a vsync-paced platform (Wayland) the period is the
// DISPLAY's: the mode of the window's run intervals (no QML type says an output's refresh rate); off one it is the window's own
// cadence. The shape of the gap gives its class:
//
//   gui       the GUI thread was busy: no polish until late in the gap, and the heartbeat could not fire on time (a handler, a
//             build, a layout, a GC; or a thread starved of a CPU)
//   gui-tick  (vsync-paced) the polish came on time, then the GUI thread was busy before the next frame: two swaps are delivered
//             at once after the gap (the animation tick, a handler between frames)
//   wait      the polish came on time and the swap late: the render thread (sync, render, a pipeline linked at a first draw, an
//             upload) or the compositor's frame callback
//   free      no polish until late, but the GUI thread was free (the heartbeat fired on time): nothing was asked to be drawn --
//             a new run beginning after a rest, which is not a stutter -- or the compositor held the frame callback. On a
//             vsync-paced platform a free gap is recorded only while a motion this window knows of spans it (a body opening,
//             closing or moving, the theme's fade, the islands, the bars); the rest are counted in the summary's histograms
//             (`idleGap`: how long the rests were; `idleWait`: how long the first frame after one took from polish to present)
//
// Each record keeps the event ring around the gap (`ev`: the 16 events up to the late swap, `after`: those of the three swaps
// after it, in ms from the late swap: "a-9,s-8,...,S0"), the popups' state at the late swap (`ctx`), the transitions of the two
// seconds before it (`tr`), the heartbeat's delay (`hb`). A miss inside a record that is still collecting joins it (`gaps`: one
// slow stretch, one record). A single short gap whose next swap came within 0.6 periods (a late DELIVERY that caught up at once:
// the frame itself was on time) is dropped and counted as `jitter`.
//
// A LATE FIRST FRAME. A transition that starts a motion (a body opening, closing or moving, the theme fading, the islands moving,
// the bars toggling, a FrameJournal.mark(.., true)) times the first swap after it; later than 2.5 periods and 20 ms is a "latency"
// record (the first frame of an open is where a build, a first draw or a decode is paid).
//
// tools/dev/perf/frame_journal_report.py reads what a day wrote.
// =============================================================================
Item {
    id: hook

    property string windowName: "window"
    property string screenName: ""
    property var engine: null
    property var frame: null
    // false: the window is not watched (its handlers are disconnected); the probe's cost measurement alternates it
    property bool watching: true
    // gaps shorter than this are never candidates (0: the cadence alone decides); a probe's ARM blinds the hook with it
    property real minGapMs: 0
    // the start of a new run on a vsync-paced platform is not recorded (below); a probe turns the rule off to see the raw patterns
    property bool idleRule: true
    // the heartbeat (below) restarted at every swap; a probe turns it off to price it (every gap then reads as a busy GUI thread)
    property bool heartbeatOn: true

    visible: false
    width: 0
    height: 0

    readonly property var _win: hook.Window.window
    readonly property bool active: FrameJournal.enabled && hook.watching && hook._win !== null
    // a candidate is collecting the swaps after it (a probe reads it: nothing is armed at rest)
    readonly property bool collecting: postTimer.running

    // The window's counters and the watch's state: one JS object mutated in place, so a frame writes no QML property (a probe
    // reads it; nothing binds to it).
    readonly property var watch: hook._s
    property var _s: hook._fresh()
    property var _bodies: []
    property var _links: []

    function _fresh(): var {
        return {
            ring: new Float64Array(96), ri: 0,          // 48 events: [time, kind] (kind 1 = polish "a", 2 = swap "s")
            lastS: 0, firstA: 0, lastA: 0, nA: 0,       // the last swap; the first and last polish since it, and how many
            lastFrame: 0,
            dts: new Float64Array(8), di: 0, warm: false,
            hist: new Float64Array(42), decay: 0,       // the run intervals by whole ms (paced platforms: the display's period)
            p: 8, pd: 1e9, ref: 8, thr: 12,             // the cadence; the display's period (paced platforms); the reference
            run: 0, frames: 0, runs: 0, stutters: 0, missed: 0, idle: 0, jitter: 0, cadence: 0, lats: 0, worst: 0,
            hbAt: 0, hbMs: 10,                          // the heartbeat's last firing, its interval
            idleGap: [0, 0, 0, 0, 0, 0, 0],             // the rests between runs: < 50, 100, 250, 500, 1000, 5000 ms, more
            idleWait: [0, 0, 0, 0, 0, 0, 0],            // the first frame after a rest, polish to swap: < 2, 4, 8, 16, 32, 64 ms, more
            fadeAt: 0, islandsAt: 0, barsAt: 0, titleAt: 0, phaseAt: [], // when the motions the window knows of began
            lenKey: "",                                 // the island lengths last seen (a re-evaluation that moves nothing is no motion)
            cur: null, curAt: 0, post: 0,               // a candidate collecting the swaps after it
            pendT: 0, pendL: "",                        // a transition waiting for its first frame
            tr: [],                                     // the transitions: [time, label], newest last
            paced: Qt.platform.pluginName === "wayland",
            born: Date.now()
        };
    }

    Connections {
        target: hook.active ? hook._win : null
        function onAfterAnimating() {
            const s = hook._s;
            const t = Date.now();
            const i = s.ri;
            s.ring[i] = t;
            s.ring[i + 1] = 1;
            s.ri = i === 94 ? 0 : i + 2;
            if (s.nA === 0)
                s.firstA = t;
            s.lastA = t;
            s.nA++;
        }
        function onFrameSwapped() {
            const s = hook._s;
            const t = Date.now();
            const i = s.ri;
            s.ring[i] = t;
            s.ring[i + 1] = 2;
            s.ri = i === 94 ? 0 : i + 2;
            const dt = t - s.lastS;
            const nA = s.nA;
            const prevS = s.lastS;
            const prevRun = s.run;
            s.lastS = t;
            s.nA = 0;
            s.frames++;
            s.lastFrame = t;
            if (hook.heartbeatOn)
                heartbeat.restart();
            if (s.post > 0 && --s.post === 0)
                hook._finish();
            if (s.pendT > 0)
                hook._firstFrame(t);
            if (dt <= 40) {
                s.dts[s.di] = dt;
                s.hist[dt]++;
                s.di = (s.di + 1) & 7;
                if (s.di === 0)
                    hook._period();
                if (prevRun === 0) {
                    s.runs++;
                    FrameJournal.runStarted();
                }
                s.run = prevRun + 1;
            } else {
                s.run = 0;
            }
            if (dt > s.thr && prevRun > 0 && s.warm && dt > hook.minGapMs)
                hook._gap(t, dt, nA, prevS, i, prevRun);
        }
    }

    // A FROZEN OR REMAPPED WINDOW ENDS ITS RUN: `updatesEnabled` false (a fullscreen or maximized window covers it) and a map / unmap draw
    // nothing for as long as they last, so the note waiting for a first frame ("osd:closing", 8 s later) and the interval to the first
    // frame after it are no frame's (the artefacts of the first journal: "osd:closing 485 ms / 8 s", a 37-minute "miss").
    function _windowEnded(): void {
        const s = hook._s;
        s.pendT = 0;
        s.run = 0;
        s.lastS = 0;
        s.nA = 0;
    }
    Connections {
        target: hook.active ? hook._win : null
        ignoreUnknownSignals: true
        function onUpdatesEnabledChanged() {
            hook._windowEnded();
        }
        function onVisibleChanged() {
            hook._windowEnded();
        }
    }

    // The cadence: the median of the last eight run intervals (two swaps delivered in one millisecond are not a cadence).
    function _period(): void {
        const s = hook._s;
        const v = [];
        for (let k = 0; k < 8; k++)
            if (s.dts[k] >= 3)
                v.push(s.dts[k]);
        if (v.length < 4)
            return;
        v.sort((x, y) => x - y);
        const m = v.length & 1 ? v[(v.length - 1) / 2] : (v[v.length / 2 - 1] + v[v.length / 2]) / 2;
        s.p = m;
        // On a vsync-paced platform a miss is measured against the DISPLAY's period (below), so a whole run
        // that is slow -- every frame costing two periods -- is missed frames and not a new normal; a deliberately slower cadence
        // (a 16 ms timer on a 120 Hz panel) is not, because its polish comes late in every interval (the idle rule below). Off a
        // compositor there is no display period to trust: the window's own cadence is the reference.
        // The display's period is the MODE of the run intervals (no QML type says the output's refresh rate): their
        // whole-ms histogram, the three bins around its peak averaged (8 and 9 ms at 120 Hz give 8.33), halved every 4096 frames
        // so it follows an output that changes. Delivery jitter and the odd slower animation do not move a mode.
        if (s.paced) {
            let best = -1;
            let bestN = 0;
            // (from 6 ms: a GUI thread busy in polish gets its queued swaps in pairs, 4 + 13 ms over and over, and a run that opens a session that way would take 3.9 ms for the
            // display's period and call a clean 120 Hz run 240 misses in 1000)
            for (let k = 6; k <= 40; k++) {
                const n = s.hist[k - 1] + s.hist[k] + s.hist[k + 1];
                if (n > bestN) {
                    bestN = n;
                    best = k;
                }
            }
            if (bestN >= 24)
                s.pd = ((best - 1) * s.hist[best - 1] + best * s.hist[best] + (best + 1) * s.hist[best + 1]) / bestN;
            if (++s.decay >= 512) {
                s.decay = 0;
                for (let k = 0; k < 42; k++)
                    s.hist[k] *= 0.5;
            }
        }
        s.ref = s.paced && s.pd < 1e8 ? s.pd : m;
        s.thr = Math.max(1.5 * s.ref, s.ref + 5);
        s.warm = true;
        const hbMs = Math.max(5, Math.round(1.25 * s.ref));
        if (hbMs !== s.hbMs) {
            s.hbMs = hbMs;
            heartbeat.interval = hbMs;
        }
    }

    // A candidate: the swap at `t` came `dt` ms after the last one (at `prevS`), with `nA` polishes between, after a run of `run`
    // intervals; `ri` is its slot in the ring.
    function _gap(t: double, dt: double, nA: int, prevS: double, ri: int, run: int): void {
        const s = hook._s;
        // the GUI thread polished late in the gap (or never)
        const late = nA > 0 && (s.firstA - prevS) >= 0.5 * dt;
        // the GUI thread was FREE early in the gap: the heartbeat, restarted at the last swap, fired on time. On time measured against the GAP: a heartbeat 17 ms after the last
        // frame of a run would call a 20.9 s rest, ended by the clock's minute, a busy GUI thread (the six longest `gui` records of a day, 507 ms to 20.9 s, were all that).
        const free = s.hbAt > prevS && s.hbAt - prevS <= Math.max(s.hbMs + 6, 0.25 * dt);
        const cls = nA === 0 ? "gui" : !late ? "wait" : free ? "free" : "gui";
        // Free and nothing polished: the window had stopped asking for frames -- a new run begins, nothing was missed -- or the
        // compositor's frame callback came late. Off a compositor every candidate is kept; on one, a free gap is kept only while a
        // motion this window knows of (a body's open, close or move, the theme's fade, the islands, the bars) spans it, and the
        // rest go to the summary's histograms: how long the rests were, and how long the first frame after one took to present.
        if (cls === "free" && s.paced && hook.idleRule && !hook._motionSpans(prevS)) {
            s.idle++;
            s.idleGap[dt < 50 ? 0 : dt < 100 ? 1 : dt < 250 ? 2 : dt < 500 ? 3 : dt < 1000 ? 4 : dt < 5000 ? 5 : 6]++;
            const w = t - s.firstA;
            s.idleWait[w < 2 ? 0 : w < 4 ? 1 : w < 8 ? 2 : w < 16 ? 3 : w < 32 ? 4 : w < 64 ? 5 : 6]++;
            return;
        }
        // A gap of seconds in which the GUI thread was free is a rest (a frozen or covered window, a lock), never frames missed: it goes to
        // the summary's histogram like every rest. A GUI thread that was BUSY for seconds is a real stall and stays.
        if (cls === "free" && dt > 5000) {
            s.idle++;
            s.idleGap[6]++;
            return;
        }
        const miss = Math.max(1, Math.round(dt / s.ref) - 1);
        const c = s.cur;
        if (c && s.post > 0) {
            // the record before this one is still collecting: one slow stretch, one record ([ms after its first miss, gap, cls])
            c.gaps.push([Math.round(t - c.t), dt, cls]);
            c.miss += miss;
            c.last = t;
            if (dt > c.worst)
                c.worst = dt;
            s.curAt = ri;
            s.post = 3;
            postTimer.restart();
            return;
        }
        if (c)
            hook._finish();
        s.cur = {
            k: "stutter", t: t, w: hook.windowName, scr: hook.screenName,
            gap: dt, worst: dt, ref: s.ref, p: s.p, miss: miss, nA: nA, cls: cls, hb: s.hbAt > prevS ? Math.round(s.hbAt - prevS) : -1,
            run: run, ev: hook._ringText(ri, t, 16), ctx: hook._context(), tr: hook._recent(t), gaps: [], last: t
        };
        s.curAt = ri;
        s.post = 3;
        postTimer.restart();
    }

    // The candidate is complete (three more swaps, or the timer): drop a late delivery that caught up, keep the rest.
    function _finish(): void {
        const s = hook._s;
        const e = s.cur;
        s.cur = null;
        s.post = 0;
        postTimer.stop();
        if (!e)
            return;
        const after = hook._ringAfter(s.curAt, e.last);
        e.after = after.text;
        const single = e.gaps.length === 0;
        // a late DELIVERY that caught up at once: the frame itself was on time
        if (single && after.firstSwap >= 0 && after.firstSwap < 0.6 * e.ref && e.gap < 2.2 * e.ref) {
            s.jitter++;
            return;
        }
        // "wait" then two swaps delivered at once, on a vsync-paced platform: the GUI thread polished on time, then was busy (the
        // animation tick, a handler) while the frame in flight was presented, and the next frame waited for it. (Off a compositor
        // nothing paces the render thread and two frames can follow any stall at once.)
        if (e.cls === "wait" && s.paced && after.firstSwap >= 0 && after.firstSwap <= 2)
            e.cls = "gui-tick";
        // off a compositor: the window's cadence changed (the next interval is as long as this one), nothing was missed
        if (single && !s.paced && after.firstSwap >= 0.7 * e.gap) {
            s.cadence++;
            return;
        }
        if (single)
            delete e.gaps;
        if (e.last === e.t)
            delete e.last;
        s.stutters++;
        s.missed += e.miss;
        if (e.worst > s.worst)
            s.worst = e.worst;
        FrameJournal.record(e);
    }
    Timer {
        id: postTimer
        interval: 300
        onTriggered: hook._finish()
    }
    // THE HEARTBEAT: restarted at every swap, so it fires only when a swap is overdue -- and only if the GUI thread is free to run
    // it. A gap in which it fired on time had a free GUI thread; one in which it could not, a busy one (or a blocked one: a GUI
    // thread waiting for the render thread cannot run it either, which the polish's timing tells apart). It fires once after the
    // last frame of a run, and then nothing runs: at rest it costs nothing.
    Timer {
        id: heartbeat
        interval: 10
        onTriggered: hook._s.hbAt = Date.now()
    }

    // A motion this window knows of was running before `prevS` and still is: a free gap inside it is a late frame, not a rest.
    function _motionSpans(prevS: double): bool {
        const s = hook._s;
        for (let i = 0; i < hook._bodies.length; i++) {
            const ph = hook._bodies[i].phase;
            if ((ph === "opening" || ph === "closing" || ph === "moving") && s.phaseAt[i] > 0 && s.phaseAt[i] < prevS)
                return true;
        }
        if (Theme.crossfading && s.fadeAt > 0 && s.fadeAt < prevS)
            return true;
        const f = hook.frame;
        if (f && f.lenT < 1 && s.islandsAt > 0 && s.islandsAt < prevS)
            return true;
        if (f && f.hideT > 0 && f.hideT < 1 && s.barsAt > 0 && s.barsAt < prevS)
            return true;
        // the title's morph (TextMorph, 220 ms) outlasts the island move (180 ms), and a morph that changes no width (a terminal's spinner) moves no island
        if (s.titleAt > 0 && s.titleAt < prevS && prevS - s.titleAt < 260)
            return true;
        return false;
    }

    // The `n` events up to ring slot `ri` (the late swap, "S0"), oldest first, in ms from `t`.
    function _ringText(ri: int, t: double, n: int): string {
        const s = hook._s;
        const out = [];
        let j = ri;
        for (let k = 0; k < n; k++) {
            const tt = s.ring[j];
            const kind = s.ring[j + 1];
            if (kind === 0)
                break;
            out.push((j === ri ? "S" : kind === 1 ? "a" : "s") + Math.round(tt - t));
            j = j === 0 ? 94 : j - 2;
        }
        return out.reverse().join(",");
    }

    // The events written after ring slot `ri`, and how soon the first swap came.
    function _ringAfter(ri: int, t: double): var {
        const s = hook._s;
        const out = [];
        let first = -1;
        let j = ri === 94 ? 0 : ri + 2;
        for (let k = 0; k < 47 && j !== s.ri; k++) {
            const kind = s.ring[j + 1];
            const d = Math.round(s.ring[j] - t);
            if (kind === 2 && first < 0)
                first = d;
            out.push((kind === 1 ? "a" : "s") + d);
            j = j === 94 ? 0 : j + 2;
        }
        return { text: out.join(","), firstSwap: first };
    }

    // What the window was doing (read at the late swap: after the gap).
    function _context(): var {
        const c = {};
        const en = hook.engine;
        if (en) {
            const slots = [];
            for (let i = 0; i < hook._bodies.length; i++) {
                const b = hook._bodies[i];
                if (b.phase === "closed")
                    continue;
                const row = [hook._slotName(b), b.ownerId, b.phase, Math.round(b.t * 100) / 100];
                if (b.travelling)
                    row.push("trav");
                if (b.swapping)
                    row.push("swap");
                if (b.contentLayered)
                    row.push("layer");
                slots.push(row);
            }
            if (slots.length > 0)
                c.slots = slots;
            if (en.prewarming)
                c.prewarm = 1;
            if (en.parkedOwnerId)
                c.park = en.parkedOwnerId;
        }
        if (Theme.crossfading)
            c.fade = 1;
        const f = hook.frame;
        if (f) {
            if (f.lenT < 1)
                c.islands = Math.round(f.lenT * 100) / 100;
            if (f.hideT > 0 && f.hideT < 1)
                c.bars = Math.round(f.hideT * 100) / 100;
        }
        if (hook._s.titleAt > 0 && Date.now() - hook._s.titleAt < 400)
            c.title = 1;
        c.up = Math.round((Date.now() - FrameJournal.startedAt) / 1000);
        return c;
    }
    function _slotName(b: var): string {
        const en = hook.engine;
        if (!en)
            return "?";
        if (b === en.thePopup)
            return "pri";
        const ch = en.childPopups;
        for (let i = 0; ch && i < ch.length; i++)
            if (ch[i] === b)
                return "ch" + (i + 1);
        if (b === en.theLane)
            return "lane";
        if (b === en.theOsd)
            return "osd";
        if (b === en.theReel)
            return "reel";
        if (b === en.theFlourish)
            return "flourish";
        return "spare";
    }

    // The transitions of the last two seconds before `t`: [label, ms before t].
    function _recent(t: double): var {
        const out = [];
        const tr = hook._s.tr;
        for (let i = 0; i < tr.length; i++)
            if (t - tr[i][0] <= 2000)
                out.push([tr[i][1], Math.round(tr[i][0] - t)]);
        return out;
    }

    // A transition (the bodies' phases, the theme, the islands, a FrameJournal.mark): noted, and with `timed` its first frame timed.
    function note(label: string, timed: bool): void {
        const s = hook._s;
        const t = Date.now();
        s.tr.push([t, label]);
        if (s.tr.length > 12)
            s.tr.shift();
        if (timed && hook.active) {
            s.pendT = t;
            s.pendL = label;
        }
    }
    function _firstFrame(t: double): void {
        const s = hook._s;
        const lat = t - s.pendT;
        const label = s.pendL;
        s.pendT = 0;
        if (lat <= Math.max(20, 2.5 * s.ref, hook.minGapMs))
            return;
        s.lats++;
        FrameJournal.record({
            k: "latency", t: t, w: hook.windowName, scr: hook.screenName, lat: lat, what: label, ref: s.ref,
            ev: hook._ringText(s.ri === 0 ? 94 : s.ri - 2, t, 10), ctx: hook._context()
        });
    }

    function lastFrameAt(): double {
        return hook._s.lastFrame;
    }
    // What this window drew and missed since it was mounted (a flush writes one per window).
    function summary(): var {
        const s = hook._s;
        return { k: "sum", t: Date.now(), w: hook.windowName, scr: hook.screenName, since: s.born, frames: s.frames, runs: s.runs,
                 stutters: s.stutters, missed: s.missed, idle: s.idle, jitter: s.jitter, cadence: s.cadence, lats: s.lats, worst: s.worst,
                 p: s.p, ref: s.ref, paced: s.paced, idleGap: s.idleGap.slice(), idleWait: s.idleWait.slice() };
    }

    // ---- the transitions' sources: rare signals, nothing at rest ---------------------------------------------------------------
    function _attach(): void {
        hook._detach();
        const en = hook.engine;
        if (!en)
            return;
        // The engine's bodies are its children's children (the host layer's): found once, by their shape.
        const found = [];
        const walk = (it, depth) => {
            const kids = it.children;
            for (let i = 0; kids && i < kids.length; i++) {
                const c = kids[i];
                if (c && ("phase" in c) && ("ownerId" in c) && ("travelling" in c))
                    found.push(c);
                else if (c && depth < 2)
                    walk(c, depth + 1);
            }
        };
        walk(en, 0);
        hook._bodies = found;
        hook._s.phaseAt = found.map(() => 0);
        for (let i = 0; i < found.length; i++) {
            const b = found[i];
            const fn = () => {
                const ph = b.phase;
                hook._s.phaseAt[i] = Date.now();
                hook.note(hook._slotName(b) + ":" + ph + ":" + b.ownerId, ph === "opening" || ph === "closing" || ph === "moving");
            };
            b.phaseChanged.connect(fn);
            hook._links.push([b, fn]);
        }
    }
    function _detach(): void {
        for (let i = 0; i < hook._links.length; i++) {
            const l = hook._links[i];
            try {
                l[0].phaseChanged.disconnect(l[1]);
            } catch (e) {}
        }
        hook._links = [];
        hook._bodies = [];
    }
    onEngineChanged: hook._attach()

    Connections {
        target: hook.engine
        ignoreUnknownSignals: true
        function onPrewarmingChanged() {
            hook.note(hook.engine.prewarming ? "prewarm:on" : "prewarm:off", false);
        }
        function onParkedOwnerIdChanged() {
            hook.note("park:" + hook.engine.parkedOwnerId, false);
        }
    }
    Connections {
        target: Theme
        function onCrossfadingChanged() {
            if (Theme.crossfading)
                hook._s.fadeAt = Date.now();
            hook.note(Theme.crossfading ? "theme:fade" : "theme:settled", Theme.crossfading);
        }
    }
    Connections {
        target: hook.frame
        ignoreUnknownSignals: true
        function onLengthsTargetChanged() {
            // the binding re-evaluates under a fullscreen video and says the same lengths: only a target that differs is a move
            const k = JSON.stringify(hook.frame.lengthsTarget);
            if (k === hook._s.lenKey)
                return;
            hook._s.lenKey = k;
            hook._s.islandsAt = Date.now();
            hook.note("islands", true);
        }
        function onBarsGoneChanged() {
            hook._s.barsAt = Date.now();
            hook.note(hook.frame.barsGone ? "bars:away" : "bars:back", true);
        }
    }
    // The title's morph is a motion the hook knows: a changed title text starts 260 ms of "title" (the morph's 220 ms and a frame's slack)
    Connections {
        target: hook.frame && hook.frame.buttons ? hook.frame.buttons.windowtray : null
        ignoreUnknownSignals: true
        function onTitleTextChanged() {
            hook._s.titleAt = Date.now();
            hook.note("title", false);
        }
    }
    Connections {
        target: hook.frame && hook.frame.services ? hook.frame.services.focus : null
        ignoreUnknownSignals: true
        function onChanged() {
            hook.note("focus", false);
        }
    }

    // Said once, when the watch starts: which window, how many popup bodies it follows, where the misses go (the shell's log
    // answers "is the journal on?").
    property bool _announced: false
    function _announce(): void {
        if (!hook.active || hook._announced)
            return;
        hook._announced = true;
        console.log("FRAMEJOURNAL " + hook.windowName + (hook.screenName ? " " + hook.screenName : "") + ": watching"
                    + (hook.engine ? " (" + hook._bodies.length + " popup bodies)" : "") + "; misses go to " + FrameJournal.path);
    }
    // A watch that resumes starts afresh: the interval since the last frame it saw is not the window's (nor a miss).
    onActiveChanged: {
        hook._s.run = 0;
        hook._s.lastS = 0;
        hook._s.nA = 0;
        hook._announce();
    }

    Component.onCompleted: {
        FrameJournal.register(hook);
        hook._attach();
        hook._announce();
    }
    Component.onDestruction: {
        FrameJournal.unregister(hook);
        hook._detach();
    }
}
