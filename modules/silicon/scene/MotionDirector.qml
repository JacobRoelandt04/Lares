pragma ComponentBehavior: Bound

import QtQuick

import "MotionScripts.js" as Motion
import "../../common/theme"

// =============================================================================
// MotionDirector.qml -- from the data layer's facts and targets to the scene's state.
//
// The scene (SiliconScene) only DRAWS what its properties say. This turns what the machine is doing
// into those properties, once per frame (SiliconClock calls `tick(dt)`), playing the curves of
// MotionScripts.js for every transition, so the popup does what the films of
// MotionScripts.js show. Nothing here is drawn and nothing here talks to the machine: it reads the view
// model's members (SiliconService and SiliconMock are the same) and writes the scene's.
//
// THE TRUTH WINS. The scene aims at the view model's TARGETS (`profileTarget`, `gpuModeTarget`,
// `chargeLimitTarget`): a target moves the moment the user asks, which is when the scene starts to move,
// and it is the fact again as soon as the write lands. A write that is refused or does not read back
// drops its target, so the scene's own aim goes back to the fact and the motion PLAYS THE WAY BACK. At
// rest the scene shows exactly what the facts say; opening the popup (`snap()`) jumps to them with no
// motion at all.
//
// ONE SNAPSHOT PER FRAME. The view model's targets and facts are written in several statements (a
// write's end drops the intent before the facts are rebuilt), so a handler that reacts to one of them
// reads a half-written state that looks real. Everything is therefore read ONCE, at the top of the tick,
// after every cascade of the previous frame has finished. Only the battery's events (discrete, never
// half-written) arrive as signals, and are queued for the next tick.
//
// ONE CLOCK PER MOTION. Each motion is a pure function of its own time (MotionScripts.js) and this holds
// its play-head: forward, held (the card waiting for the apps that still use it) or backward. The values
// that follow the sensors (core loads, the fill, the flow, the card's wakefulness) are eased, never
// stepped, with one time constant each.
//
//   CPU     lift1 / lift2 / liftDown, for any pair (`Motion.liftTurn`); a second step asked while one is
//           in the air carries it on toward the further profile -- ONE lift, ONE longer turn -- and a
//           step back to where it started rewinds it. Anything else (a step the other way) rewinds first
//           and then plays the new one. The hologram's de-rez rides inside the lift. The profiles are a
//           CYCLE: Performance -> Quiet is one half turn on (clockwise, in the swipe's direction) and
//           Quiet -> Performance one half turn back, neither over Balanced (`Motion.stepQuarters`): the
//           package's position is in unwrapped quarters while it moves and the profile's index at rest.
//   GPU     TWO motions, played apart: the card's PLACE (cardOut / cardIn: out of its slot for Integrated
//           and back for a mode) follows only "is the target Integrated", and the hologram's LOOK (derezGpu
//           between two modes) follows the mode asked for. A step asked in the air therefore never turns the
//           card that is coming round: Integrated -> Smart -> Hybrid goes on seating it, and the look is
//           decided as late as it can be -- while none of the hologram is drawn it simply IS the mode asked for,
//           once it is, another mode is a de-rez, and on a card leaving for Integrated it is the LAST mode asked
//           (Hybrid -> Smart -> Integrated takes Smart's hologram out). While apps still use the dGPU the
//           card's way out waits half-seated (`holdAt`) until they have exited. The card's wakefulness is the
//           FACT (the films' own dimming and lighting are theirs: a dGPU that sleeps stays dark through a switch).
//   battery the plug slides in and out with the mains, the DIP lever follows the charge limit, the fill
//           and the flow follow the pack, and an event (full, low, charge start / stop) starts the
//           board-wide pulse (`eventAge`). The charge limit's LOCK (the bar across the 4th cell, its padlock) is ONE
//           fraction that follows the lever: it starts when the lever has landed at "80" and runs back the moment the
//           lever leaves it (MotionScripts.lockPose draws every piece from it).
//
// WHAT THE CLOCK AND THE POPUP LEAN ON:
//   the entrance   with `entranceEnabled` the scene starts dark (`power` 0) and `powerOn()` plays the entrance
//                  film's own power curve into it (traces from the pack, the chips, the holograms flicker on);
//                  a harness leaves `entranceEnabled` false and the board is simply on (the director then never
//                  writes `power`, so a gate can still set it by hand)
//   the zones      a zone without its daemon never powers on: `cpuZone` follows the helper, `gpuZone` cardwire,
//                  each eased over the entrance's own span, and the scene keeps that zone's hologram and sparks
//                  at the lower of it and `power`
//   the MUX breath `muxBreath` is the amplitude the GPU hologram's breath is eased in and out at while a MUX
//                  request waits for its restart
//   the moments    `cardLatched` / `leverFlipped` / `plugMoved` are emitted by the motions as they reach the
//                  point a sound marks, ONCE per crossing and never by `snap()` (it replaces the state, it does
//                  not play): the latch lets go LATCH_AT s into the card's way out and takes hold where the way
//                  back crosses it again, or where the way in ends; the lever passes the middle of its travel;
//                  the plug lands or leaves the jack
//   `animating`    whether something will change by ITSELF (a motion in the air, not one that waits for the
//                  apps; the power-on; a ramp): the clock may not park while it is true
//   `watchKey`     the discrete facts that start a motion or change the look: the popup touches the idle ladder
//                  when it changes, because a halted clock plays none of them
// =============================================================================
Item {
    id: root

    visible: false

    // ---- in ----
    property var vm: null                 // a SiliconService or a SiliconMock
    property var scene: null              // the SiliconScene it drives

    // Moments a sound marks (SiliconSounds listens; CONTRACT section 11): the card's latch as it seats
    // (true) or lets go (false), the DIP lever passing its middle (the limit it now shows), the plug
    // landing in the jack (true) or leaving it. Emitted by the motions as they reach that point -- once per
    // crossing, never for a motion that did not get there, never by the fact and never by `snap()` -- so a
    // sound is never ahead of what is drawn.
    signal cardLatched(bool seated)
    signal leverFlipped(bool limitOn)
    signal plugMoved(bool plugged)

    // The power-on entrance: the owner sets it (a mockup's harness leaves it off and the board is simply on).
    property bool entranceEnabled: false

    // ---- tuning (the mockup's Motion tab) ----
    property real speed: 1                // x the films' own time (the motions only)
    property real rewindSpeed: 1          // the way back, x the films' time
    property real holdAt: 0.55            // s into the card's way out where it waits for the apps that still use it
    property real bridgeS: 0.2            // a carried-on motion's lift settles into its new curve over this
    property real coresS: 0.3             // time constants of the eased values, s
    property real fillS: 0.8
    property real flowS: 0.4
    property real awakeS: 0.35
    property real tweakS: 0.35
    property real eventS: 4.0             // how long a battery event's age runs: the pulse (55 mm/s) is gone at 220 mm, 4.0 s, and the passive trains are back with it (tools/dev/silicon_event_walk.js PULSE)
    property real lockSeconds: 0.34       // how long the charge limit's lock takes to engage / release, s (= MotionScripts.LOCK_SECONDS, which its own films use; a literal here: the mockup's wiring check reads the defaults it compares as numbers)

    // ---- out (the popup reads these to hold its own work; the probes read all of them) ----
    readonly property bool moving: root._cpuMoving || root._gpuMoving || root._miscMoving
    // something will change by ITSELF: a motion in the air (a card that waits for the apps that use the dGPU
    // does not: it stays where it is until they exit, which is a fact the popup wakes the clock for), the
    // power-on, a zone or the breath on its way. The clock parks only when this is false.
    readonly property bool animating: root._animating
    readonly property real entrancePower: root._entPower
    readonly property bool entranceDone: root._entT >= Motion.entranceDuration()
    readonly property bool entranceRunning: root._entPlaying
    readonly property int cpuDir: root._cpuDir

    property bool _cpuMoving: false
    property bool _gpuMoving: false
    property bool _miscMoving: false
    property bool _animating: false
    property real _cpuT: 0
    property int _cpuDir: 1
    property real _gpuT: 0
    property string _gpuKind: ""

    // ---- what a battery event is, to the scene ----
    readonly property var _eventKinds: ({ full: 0, chargeDone: 0, low: 1, chargeStart: 2, chargeStop: 3 })
    property int _evKind: 2
    readonly property var _eventColours: [Theme.batteryCharge, Theme.batteryLow, Theme.batteryCharge, Theme.batteryDrain]
    // a Binding, not an assignment: the scene's colour must keep following the theme
    Binding {
        target: root.scene
        property: "eventColour"
        value: root._eventColours[root._evKind]
        when: root.scene !== null
    }

    Connections {
        target: root.vm
        ignoreUnknownSignals: true
        function onBatteryEvent(kind) {
            root._pendingEvent = String(kind);
        }
    }
    property string _pendingEvent: ""

    // ======================================================================================
    // The tick
    // ======================================================================================
    property bool _ready: false
    property var _s: null

    function _fresh() {
        return {
            cpu: { rest: 1, active: false, from: 0, to: 0, t: 0, dir: 1, bridge: null },
            gpu: { out: false, card: { active: false, kind: "", t: 0, dir: 1, held: false }, mode: 2, last: 2, derez: { active: false, to: 0, t: 0, dir: 1 } },
            load: 0, igpu: 0, tweak: 0, cores: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            awake: 0, util: 0, fill: 0, flow: 0, plug: 1, lever: 0, lock: 0, hdmi: 0,
            cpuZone: 1, gpuZone: 1, breath: 0,
            evAge: -1, evKind: 2
        };
    }

    function _clamp01(v) {
        return v < 0 ? 0 : (v > 1 ? 1 : v);
    }
    function _num(v, dflt) {
        return typeof v === "number" && isFinite(v) ? v : dflt;
    }
    // x moves toward `to` with time constant `tau`; close enough is there (a value must come to rest)
    function _ease(x, to, dt, tau) {
        const d = to - x;
        if (Math.abs(d) < 1e-4)
            return to;
        return x + d * (1 - Math.exp(-dt / Math.max(1e-3, tau)));
    }
    // x moves toward `to` at a constant rate: one `seconds` for the whole 0 .. 1 travel
    function _approach(x, to, dt, seconds) {
        const d = to - x;
        const st = dt / Math.max(1e-3, seconds);
        return Math.abs(d) <= st ? to : x + (d > 0 ? st : -st);
    }

    // How many apps the card waits for on its way out. In dGPU-only wiring the compositor itself holds the card: the way out waits for the
    // restart, not for apps. And a card that is ASLEEP is holding nobody up, whatever the last list said: the list is read on a beat, and a
    // card that goes down between two reads would stand half-seated, with the ladder awake and the clock running, until the next one.
    function _waitFor(gpu) {
        return gpu.wiring === "dgpu" || gpu.awake !== true ? 0 : (gpu.holders || []).length;
    }

    // Everything the scene follows, read once.
    function _sample() {
        const vm = root.vm;
        const cpu = vm.cpu || {}, gpu = vm.gpu || {}, bat = vm.battery || {};
        const src = vm.cores || [];
        const cores = [];
        for (let i = 0; i < 16; i++)
            cores.push(i < src.length ? root._clamp01(root._num(src[i].load, 0)) : 0);
        return {
            profile: Math.max(0, Math.min(2, root._num(vm.profileTarget, 1))),
            tweaked: cpu.tweaked === true,
            load: root._clamp01(root._num(cpu.loadPct, 0) / 100),
            cores: cores,
            igpu: root._clamp01(root._num(vm.igpu ? vm.igpu.busy : 0, 0)),
            gpuStep: Math.max(0, Math.min(3, root._num(vm.gpuModeTarget, 2))),
            awake: gpu.awake === true,
            util: root._clamp01(root._num(gpu.util, 0) / 100),
            // in dGPU-only wiring the compositor itself holds the card: the way out waits for the restart, not for apps
            holders: root._waitFor(gpu),
            pct: root._clamp01(root._num(bat.pct, 0) / 100),
            watts: root._num(bat.wattsReal, 0),
            ac: bat.ac === true,
            hdmi: !!vm.display && vm.display.hdmi === true,
            limit: root._num(vm.chargeLimitTarget, 100),
            // a zone without its daemon never powers on; a MUX request waits for its restart
            cpuOn: !!vm.helper && vm.helper.ok === true,
            gpuOn: gpu.present === true,
            muxPending: !!gpu.mux && gpu.mux.pending === true
        };
    }

    // The discrete facts that start a motion or change the look (the popup touches the idle ladder when this
    // changes: a halted clock plays none of them). The sensors that move all the time -- loads, clocks,
    // the pack's charge -- are not in it: they are shown while the clock runs and read by the plates always.
    readonly property string watchKey: {
        const vm = root.vm;
        if (!vm)
            return "";
        const cpu = vm.cpu || {}, gpu = vm.gpu || {}, bat = vm.battery || {};
        return [vm.profileTarget, vm.gpuModeTarget, vm.chargeLimitTarget, vm.profileIndex, vm.gpuMode, gpu.dState, bat.ac, bat.limitOn,
                root._waitFor(gpu) > 0, cpu.tweaked === true, !!gpu.mux && gpu.mux.pending === true,
                !!vm.helper && vm.helper.ok === true, gpu.present === true, !!vm.display && vm.display.hdmi === true].join("|");
    }

    // ---- the entrance ----
    property real _entT: 0                // s into the power-on: 0 = dark, the film's own end = on
    property bool _entPlaying: false
    readonly property real _entPower: Motion.entrancePower(root._entT)

    // The popup becomes shown: a power-on that finished starts again from dark; one cut short stays where it
    // is and carries on when the popup is out (`powerOn`). Call it BEFORE `snap()`.
    function opening() {
        if (root._entT >= Motion.entranceDuration())
            root._entT = 0;
        root._entPlaying = false;
    }
    // The popup is mostly out (the popup's rule: openProgress >= 0.6): the power-on plays into `scene.power`
    // from the power it has, which is none on a fresh popup. Asked again while it plays it is a no-op. It runs
    // whether or not `entranceEnabled` is set (a handler may run before that binding has followed); the scene's
    // `power` is only ever WRITTEN while it is.
    function powerOn() {
        if (root._entT < Motion.entranceDuration())
            root._entPlaying = true;
    }

    // Jump to the facts: no motion. The popup calls it when it opens (a popup opened on Performance must
    // not play a lift from whatever the scene last showed).
    function snap() {
        if (!root.vm || !root.scene)
            return;
        const f = root._sample();
        const s = root._fresh();
        s.cpu.rest = f.profile;
        s.gpu.out = f.gpuStep === 0;
        s.gpu.mode = f.gpuStep > 0 ? f.gpuStep : 2;
        s.gpu.last = s.gpu.mode;
        s.load = f.load;
        s.igpu = f.igpu;
        s.tweak = f.tweaked ? 1 : 0;
        s.cores = f.cores.slice();
        s.awake = f.awake ? 1 : 0;
        s.util = f.util;
        s.fill = f.pct;
        s.flow = f.watts;
        s.plug = f.ac ? 1 : 0;
        s.hdmi = root._hdmiWanted(f, s.gpu) ? 1 : 0;
        s.lever = f.limit >= 100 ? 1 : 0;
        s.lock = f.limit >= 100 ? 0 : 1;
        s.cpuZone = f.cpuOn ? 1 : 0;
        s.gpuZone = f.gpuOn ? 1 : 0;
        s.breath = f.muxPending ? 1 : 0;
        root._s = s;
        root._pendingEvent = "";
        root._ready = true;
        root._write(f);
    }

    function tick(dt) {
        if (!root.vm || !root.scene)
            return;
        if (!root._ready) {
            root.snap();
            return;
        }
        const f = root._sample();
        const s = root._s;
        root._stepCpu(s.cpu, f.profile, dt * root.speed, dt);
        root._stepGpu(s.gpu, f.gpuStep, f.holders, dt * root.speed, s.hdmi > 0);
        s.load = root._ease(s.load, f.load, dt, root.coresS);
        s.igpu = root._ease(s.igpu, f.igpu, dt, root.coresS);
        for (let i = 0; i < 16; i++)
            s.cores[i] = root._ease(s.cores[i], f.cores[i], dt, root.coresS);
        s.tweak = root._approach(s.tweak, f.tweaked ? 1 : 0, dt, root.tweakS);
        s.awake = root._ease(s.awake, f.awake ? 1 : 0, dt, root.awakeS);
        s.util = root._ease(s.util, f.util, dt, root.coresS);
        s.fill = root._ease(s.fill, f.pct, dt, root.fillS);
        s.flow = root._ease(s.flow, f.watts, dt, root.flowS);
        // the plug and the lever: where they were, so the moment a sound marks (landing, leaving, passing the
        // middle) is the one the motion itself reaches in THIS frame
        const plug0 = s.plug, lever0 = s.lever;
        s.plug = root._approach(s.plug, f.ac ? 1 : 0, dt, Motion.PLUG_SECONDS);
        s.lever = root._approach(s.lever, f.limit >= 100 ? 1 : 0, dt, Motion.LEVER_SECONDS);
        // the HDMI cable: in while a display is on the card's port and the card sits in its slot; out BEFORE the card leaves
        s.hdmi = root._approach(s.hdmi, root._hdmiWanted(f, s.gpu) ? 1 : 0, dt, Motion.HDMI_SECONDS);
        if (plug0 < 1 && s.plug >= 1)
            root.plugMoved(true);
        else if (plug0 >= 1 && s.plug < 1)
            root.plugMoved(false);
        if (lever0 < Motion.LEVER_MIDDLE && s.lever >= Motion.LEVER_MIDDLE)
            root.leverFlipped(false);               // toward "100": the limit is now off
        else if (lever0 >= Motion.LEVER_MIDDLE && s.lever < Motion.LEVER_MIDDLE)
            root.leverFlipped(true);                // back toward "80": the limit is on
        // the lock: engaged once the lever has LANDED at "80", released the moment it leaves it (so the way back starts with the lever)
        s.lock = root._approach(s.lock, s.lever <= 0 ? 1 : 0, dt, root.lockSeconds);
        // a zone's daemon comes or goes; the MUX breath comes in and out
        s.cpuZone = root._approach(s.cpuZone, f.cpuOn ? 1 : 0, dt * root.speed, Motion.ZONE_SECONDS);
        s.gpuZone = root._approach(s.gpuZone, f.gpuOn ? 1 : 0, dt * root.speed, Motion.ZONE_SECONDS);
        s.breath = root._approach(s.breath, f.muxPending ? 1 : 0, dt, Motion.BREATH_SECONDS);
        // the power-on plays the entrance film's own curve
        if (root._entPlaying) {
            root._entT = Math.min(Motion.entranceDuration(), root._entT + dt * root.speed);
            if (root._entT >= Motion.entranceDuration())
                root._entPlaying = false;
        }
        // a battery event: queued by the signal, started here, its age runs on the clock
        if (root._pendingEvent !== "") {
            const k = root._eventKinds[root._pendingEvent];
            root._pendingEvent = "";
            if (k !== undefined) {
                s.evKind = k;
                s.evAge = 0;
                root._evKind = k;
            }
        } else if (s.evAge >= 0) {
            s.evAge += dt;
            if (s.evAge >= root.eventS)
                s.evAge = -1;
        }
        root._write(f);
    }

    // ======================================================================================
    // The package
    // ======================================================================================
    // `m` is the CPU's motion record; `target` the profile the scene is aimed at.
    function _stepCpu(m, target, dt, realDt) {
        if (!m.active) {
            if (target !== m.rest) {
                m.active = true;
                m.from = m.rest;
                // the profiles are a cycle: the step past an end carries on round (a half turn that never
                // passes over Balanced), so `to` is a position in unwrapped quarters, not the profile's index
                m.to = m.rest + Motion.stepQuarters(m.rest, target);
                m.t = 0;
                m.dir = 1;
                m.bridge = null;
            }
        } else {
            root._retargetCpu(m, target);
        }
        if (!m.active)
            return;
        m.t += m.dir * dt * (m.dir < 0 ? root.rewindSpeed : 1);
        if (m.bridge)
            m.bridge.age += realDt;
        if (m.bridge && m.bridge.age >= root.bridgeS)
            m.bridge = null;
        if (m.dir > 0 && m.t >= Motion.liftTurnDuration(m.from, m.to)) {
            m.rest = Motion.reduceQ(m.to);
            m.active = false;
            m.bridge = null;
        } else if (m.dir < 0 && m.t <= 0) {
            m.rest = Motion.reduceQ(m.from);
            m.active = false;
            m.bridge = null;
        }
    }

    // The target changed while the package is in the air.
    //
    // `m.from` / `m.to` are positions in unwrapped quarters and `c` the profile asked for: the step to it is
    // taken from where the package is going (`m.to`), which puts it at `cq` -- on round the same way, or back.
    function _retargetCpu(m, c) {
        if (m.dir > 0) {
            if (c === Motion.reduceQ(m.to))
                return;
            if (c === Motion.reduceQ(m.from)) {
                m.dir = -1;                          // the way back
                return;
            }
            const cq = m.to + Motion.stepQuarters(Motion.reduceQ(m.to), c);
            if ((cq - m.from) * (m.to - m.from) > 0 && Math.abs(cq - m.from) > Math.abs(m.to - m.from)) {
                const now = Motion.liftTurn(m.t, m.from, m.to);
                // Past nine tenths of its de-rez the hologram shows the profile it is turning to, and the
                // package is within half a degree of it: the step asked is the next one's own, from where
                // the package now stands, and it rises again from the height it has -- nothing pops. (Carried
                // on from earlier, the hologram would fall back to a mixture of the first and the last.)
                if (now.cpuDerez >= 0.9) {
                    m.from = m.to;
                    m.to = cq;
                    m.t = Motion.liftTimeAtRise(now.pkgRise);
                    m.bridge = null;
                    return;
                }
                // further the same way: one lift, one longer turn. The new curve is entered where its
                // quarter turn equals the one the package has now; its lift differs a little, and that
                // difference decays over `bridgeS` instead of jumping.
                const t2 = Motion.liftTimeAtQuarter(now.pkgQuarter, m.from, cq);
                const t = t2 === null ? m.t : t2;
                const next = Motion.liftTurn(t, m.from, cq);
                m.bridge = { rise: now.pkgRise - next.pkgRise, age: 0 };
                m.t = t;
                m.to = cq;
                return;
            }
            m.dir = -1;                              // anything else: back to rest first, then the new step
        } else {
            if (c === Motion.reduceQ(m.to))
                m.dir = 1;                           // asked again: forward from where the rewind has got to
        }
    }

    // ======================================================================================
    // The card
    // ======================================================================================
    // Two motions, played apart. The card's PLACE -- out of its slot (Integrated) or seated (a mode) -- is `g.out` at rest
    // and `g.card`, a play-head of cardOut / cardIn, in the air; it follows ONE wish, "is the target Integrated", so a step between
    // two modes never touches it and a step to or from Integrated plays the same motion on or back. The hologram's LOOK is `g.mode`,
    // the mode whose picture it shows, and `g.derez`, a play-head of derezGpu between it and another mode. The look follows the
    // mode asked for -- or, while the card is on its way out, the LAST one asked for (`g.last`): the hologram that leaves is the
    // one the user chose, not the one they chose before it.
    function _cardDuration(kind) {
        return kind === "out" ? Motion.cardOutDuration() : Motion.cardInDuration();
    }

    // The cable is wanted in while the fact says so and the card is in its slot and staying: not while it is on its way out, not while it
    // is gone and not until it has seated (a de-rez between two seated modes does not move it).
    function _hdmiWanted(f, g) {
        return f.hdmi && f.gpuStep !== 0 && !g.out && !g.card.active;
    }

    // `cableOut`: the HDMI cable is not out yet -- the card's way OUT waits for it (the cable unplugs before the lift and the scatter).
    function _stepGpu(g, target, holders, dt, cableOut) {
        if (target > 0)
            g.last = target;
        root._stepCard(g, target === 0, holders, dt, cableOut);
        root._stepLook(g, target > 0 ? target : g.last, dt);
    }

    function _stepCard(g, wantOut, holders, dt, cableOut) {
        const m = g.card;
        if (!m.active) {
            if (wantOut === g.out || (wantOut && cableOut))
                return;
            m.active = true;
            m.kind = wantOut ? "out" : "in";
            m.t = 0;
            m.dir = 1;
        } else {
            m.dir = (m.kind === "out") === wantOut ? 1 : -1;     // on toward the place asked for; back the way it came when that changed
        }
        let t = m.t + m.dir * dt * (m.dir < 0 ? root.rewindSpeed : 1);
        // the card is unlatched and waits while apps still use the dGPU: cardwire blocks only NEW opens,
        // so Integrated is chosen and the card does not leave until the last of them has exited
        if (m.kind === "out" && m.dir > 0 && holders > 0)
            t = Math.min(t, Math.max(m.t, root.holdAt));
        // the beam is drawn in the colour of the scene's mode (Integrated's): it may not rise while the hologram changes its look,
        // so the card waits at the edge of the beam until the de-rez has landed
        if (g.derez.active) {
            if (m.kind === "out" && m.dir > 0)
                t = Math.min(t, Math.max(m.t, Motion.BEAM_OUT_AT));
            else if (m.kind === "in" && m.dir < 0)
                t = Math.max(t, Math.min(m.t, Motion.BEAM_IN_AT));
        }
        const t0 = m.t;
        m.t = t;
        m.held = m.kind === "out" && m.dir > 0 && holders > 0 && t >= root.holdAt - 1e-9;
        // the latch: lets go as the way out gets LATCH_AT in, takes hold again where the way back crosses it
        // (a card that never got that far never unlatched, and says nothing when it is called back)
        if (m.kind === "out") {
            if (t0 < Motion.LATCH_AT && t >= Motion.LATCH_AT)
                root.cardLatched(false);
            else if (t0 >= Motion.LATCH_AT && t < Motion.LATCH_AT)
                root.cardLatched(true);
        }
        if (m.dir > 0 && m.t >= root._cardDuration(m.kind)) {
            g.out = m.kind === "out";
            m.active = false;
            if (m.kind === "in")
                root.cardLatched(true);              // the card seats: the way in ends on the latch
        } else if (m.dir < 0 && m.t <= 0) {
            g.out = m.kind === "in";
            m.active = false;
        }
    }

    // How much of the card the scene shows now: the pose the card is in (the scripts', or resting seated / out)
    function _cardPose(g) {
        const m = g.card;
        if (m.active) {
            const t = Math.max(0, Math.min(m.t, root._cardDuration(m.kind)));
            return m.kind === "out" ? Motion.cardOutAt(t, g.mode) : Motion.cardInAt(t, g.mode);
        }
        return g.out ? { cardLift: Motion.CARD_OUT_MM, cardDissolve: 1, beam: 1 } : { cardLift: 0, cardDissolve: 0, beam: 0 };
    }

    // The hologram's look follows `want`, the mode asked for. Where none of the hologram is drawn it just is that mode; where some of
    // it is, another mode is a de-rez, which, once started, lands or goes back to where it began like any motion: asked for its own
    // mode again it goes on, for the mode it came from it plays back, for a third one it goes on to the nearer end first (nothing
    // of it shows before its first tenth of a second, so there it is simply aimed anew) and the next de-rez starts from there. It
    // never starts while any of the beam is drawn (see _stepCard).
    function _stepLook(g, want, dt) {
        const d = g.derez;
        if (d.active) {
            const shown = Motion.derezGpuAt(d.t, g.mode, d.to).gpuDerez;
            if (want === d.to) {
                d.dir = 1;
            } else if (want === g.mode) {
                d.dir = -1;
            } else if (shown <= 0) {
                d.to = want;
                d.dir = 1;
            } else {
                d.dir = shown < 0.5 ? -1 : 1;
            }
            d.t += d.dir * dt * (d.dir < 0 ? root.rewindSpeed : 1);
            if (d.dir > 0 && d.t >= Motion.derezGpuDuration()) {
                g.mode = d.to;
                d.active = false;
            } else if (d.dir < 0 && d.t <= 0) {
                d.active = false;
            }
        }
        if (d.active || want === g.mode)
            return;
        const pose = root._cardPose(g);
        if (Motion.holoUnseen(pose)) {
            g.mode = want;
        } else if (pose.beam <= 0) {
            d.active = true;
            d.to = want;
            d.t = 0;
            d.dir = 1;
        }
    }

    // ======================================================================================
    // Into the scene
    // ======================================================================================
    function _same(a, b) {
        for (let i = 0; i < 16; i++) {
            if (Math.abs(a[i] - b[i]) > 1e-4)
                return false;
        }
        return true;
    }

    property var _lastCores: []

    function _write(f) {
        const sc = root.scene, s = root._s;
        // ---- CPU ----
        const c = s.cpu;
        if (c.active) {
            const st = Motion.liftTurn(Math.max(0, Math.min(c.t, Motion.liftTurnDuration(c.from, c.to))), c.from, c.to);
            let rise = st.pkgRise;
            if (c.bridge)
                rise += c.bridge.rise * (1 - Motion.easeInOutCubic(c.bridge.age / root.bridgeS));
            sc.pkgRise = Math.max(0, Math.min(1, rise));
            sc.pkgQuarter = st.pkgQuarter;
            sc.profile = st.profile;
            sc.cpuNextProfile = st.cpuNextProfile;
            sc.cpuDerez = st.cpuDerez;
        } else {
            sc.pkgRise = 0;
            sc.pkgQuarter = c.rest;
            sc.profile = c.rest;
            sc.cpuNextProfile = -1;
            sc.cpuDerez = 0;
        }
        sc.tweak = s.tweak;
        sc.cpuLoad = s.load;
        sc.igpuBusy = s.igpu;
        if (root._lastCores.length !== 16 || !root._same(root._lastCores, s.cores)) {
            root._lastCores = s.cores.slice();
            sc.cores = root._lastCores;
        }
        // ---- GPU ----
        // The card's place from its pose; the hologram's look from the mode and the de-rez. Where any of the beam is drawn the scene's
        // mode is Integrated (it colours the beam), and the look rides in the de-rez's slots (Integrated, next = the look, derez 1):
        // the same picture, in the same colour, as (the look, no next, derez 0) -- so nothing changes where the beam comes or goes.
        const g = s.gpu;
        const pose = root._cardPose(g);
        sc.cardLift = pose.cardLift;
        sc.cardDissolve = pose.cardDissolve;
        sc.beam = pose.beam;
        if (g.out && !g.card.active) {
            sc.gpuMode = 0;
            sc.gpuNextMode = -1;
            sc.gpuDerez = 0;
        } else if (pose.beam > 0) {
            sc.gpuMode = 0;
            sc.gpuNextMode = g.mode;
            sc.gpuDerez = 1;
        } else if (g.derez.active) {
            const st = Motion.derezGpuAt(g.derez.t, g.mode, g.derez.to);
            sc.gpuMode = st.gpuMode;
            sc.gpuNextMode = st.gpuNextMode;
            sc.gpuDerez = st.gpuDerez;
        } else {
            sc.gpuMode = g.mode;
            sc.gpuNextMode = -1;
            sc.gpuDerez = 0;
        }
        sc.dgpuAwake = s.awake;
        sc.gpuUtil = s.util;
        // ---- battery ----
        sc.fill = s.fill;
        sc.flowW = s.flow;
        sc.plugIn = Motion.plugPose(s.plug);
        sc.hdmiIn = Motion.plugPose(s.hdmi);
        sc.lever = Motion.leverPose(s.lever);
        sc.lock = s.lock;
        sc.eventKind = s.evKind;
        sc.eventAge = s.evAge;
        // ---- the zones, the MUX breath, the power-on ----
        sc.cpuZone = s.cpuZone;
        sc.gpuZone = s.gpuZone;
        sc.muxBreath = s.breath;
        if (root.entranceEnabled)
            sc.power = root._entPower;
        // ---- what the popup may ask ----
        root._cpuMoving = c.active;
        root._cpuT = c.t;
        root._cpuDir = c.dir;
        root._gpuMoving = g.card.active || g.derez.active;
        root._gpuT = g.card.active ? g.card.t : g.derez.t;
        root._gpuKind = g.card.active ? g.card.kind : (g.derez.active ? "derez" : "");
        root._miscMoving = s.evAge >= 0 || s.plug > 0 && s.plug < 1 || s.hdmi > 0 && s.hdmi < 1 || s.lever > 0 && s.lever < 1 || s.lock > 0 && s.lock < 1;
        // ---- whether anything will change by itself (the clock parks only when nothing will) ----
        const zonesMoving = s.cpuZone !== (f.cpuOn ? 1 : 0) || s.gpuZone !== (f.gpuOn ? 1 : 0) || s.breath !== (f.muxPending ? 1 : 0);
        root._animating = c.active || (g.card.active && !g.card.held) || g.derez.active || root._miscMoving || root._entPlaying || zonesMoving;
    }
}
