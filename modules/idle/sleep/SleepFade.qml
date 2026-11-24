pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../../common/components"
import "../../common/system"
import "../LidRules.js" as Lid
import "SleepRules.js" as Rules
// the brightness keys' own perceived curve: the fall and the climb are even in how bright the panel LOOKS
import "../../osd/data/OsdKinds.js" as Osd

// =============================================================================
// SleepFade.qml -- the screen falls asleep before the machine does, and wakes after it (docs/idle.md
// has the sequence, the facts and the why).
// ONE per shell (IdleService holds it).
//
//   the inhibitor           the shell holds a logind sleep DELAY inhibitor while it lives (a child that holds it, killed to release), so
//                           a sleep waits for it -- at most logind's InhibitDelayMaxUSec (5 s here), read once.
//   PrepareForSleep(true)   no inhibitor held -> NOTHING is done (the sleep did not wait: no work in its entry window). Else it waits for
//                           the lock to be up and its veil done appearing (LockState veilAt, or lockedAt + veilLeadMs), then FALLS: the
//                           veil (SleepVeil, every output) goes from awake to asleep while the panel goes from its level to 0 along the
//                           brightness keys' perceived ladder -- then releases. The release is never later than the deadline (the cap
//                           less `marginMs`): a late lock, or none, starts the fall at deadline - fall at the latest, a fall that cannot
//                           finish is stopped (`stopGraceMs` before the deadline, after its current write: no straggler lands later).
//   PrepareForSleep(false)  the inhibitor is taken again. A suspend-lab campaign in progress (campaignFile "status": "running") is left
//                           alone: no write at all. Else the panel is put to 0 first (the kernel may have lit it on its own at resume),
//                           each veil captures its output clear, and the panel climbs back from 0 to the level it had while the veil wakes
//                           at the same pace. NOTHING CLIMBS BEFORE THE SCREEN IS BACK: the capture counts the veil window's own presented
//                           frames, so its answer IS the first frames of the resume, and the climb waits for it for up to `wakeWaitMs` (a
//                           shorter wait gives up inside a resume's stall and spends the climb on a screen nobody sees).
//                           A stall DURING the climb is taken out of its clock. A key typed takes the
//                           blur off within `focusMs`; the vignette and the light keep their pace. The lock going away (phase unlocking, or
//                           not locked) skips the rest: one write of the level, the veil drops at once.
//                           A sleep that fails at once (the resume mid-fall) climbs back from where the fall was.
//   the guard               sleep_guard.py, started at the fall (BEFORE the release: the entry window starts nothing), told "go" at the
//                           release, killed at every resume: `stuckS` s of monotonic time after "go" it gives the level back if the panel
//                           still reads 0 -- the hang while ENTERING suspend (no sleep happened: "stuck") or a resume nobody heard ("slept",
//                           and the veil then wakes).
//   the lid (hard idle)     IdleService hands LidDim's climb in: lidWake(ms) plays the same wake on the panel's output only (LidDim writes
//                           the light; the fade only draws).
//
// THE LEVEL TO GIVE BACK is ONE value, the brightness the user had: what the panel reads, or -- when SoftIdle dimmed it first (the idle modes off and
// soft dim at 2 and 3 minutes, and hypridle's suspend comes at 4) -- the number SoftIdle saved in the brightness script's state file BEFORE it
// dimmed (`settings.stateFile`), which is the panel's value a --resume would give back. Read at the sleep: the panel then reads the DEEP value, and a
// climb to that was the 50 % the user saw. When the climb has given the level back (or a key took over), `gaveBack` tells SoftIdle, whose own
// level and state file then agree with the panel (IdleService wires it).
//
// THE PANEL: `device` BY NAME, through `brightnessctl -c backlight -d <device>` -- PanelBacklight's answer, the backlight of the GPU that drives
// the eDP (Hybrid: intel_backlight, never a stray nvidia_0: the strongest correlate of the machine's suspend hangs is a program poking the
// dGPU at suspend time; dGPU-only: nvidia_0). A machine with no such device fades the veil alone. WHERE 0 IS NOT BLACK (`zeroIsBlack` false:
// nvidia_0) the backlight still falls and rises, and the veil dims the panel's picture itself as well (selfDims), so the fall ends black.
// THE LID HOLD (`lidHold`): LidDim's 0 on such a panel is lit, so the veil holds the panel's output black (phase "lidhold", p = 1, panel
// only, no picture) for as long as the lid is shut in hard idle; the lid's wake takes over from it. Every brightness step is ONE bash that reads the panel before each write: a value it did not leave there is a key's
// (the user's) and wins ("kept"). What it left there is what it WROTE (sysfs `brightness` reads back the value set): a read after the
// write would take a key pressed in that instant for its own. A step is stopped by a signal it traps (USR1: finish, USR2: halt) and acts on after its current call,
// never killed mid-write -- a killed bash leaves its brightnessctl to land a write after whatever comes next.
//
// THE CLOCK. `progress` (0 awake .. 1 asleep) is the veil's one clock, driven by a FrameAnimation from the WALL clock (the steps keep wall
// time; a Timer runs on the animation clock, fast offscreen and still in a stall). The deadlines are wall-clock beats too.
//
// `recordFile` -- the level a fall took, written by the fall's bash before its first write, removed when the light is back: a shell that
// dies between the two gives it back at its next start (if the panel still reads 0). $XDG_RUNTIME_DIR: a reboot clears it, and
// systemd-backlight restores the panel then.
// NOT LIVE (a mock shell, every probe that does not arm it): nothing is held, run or written; `log` says what would have been.
// =============================================================================
Item {
    id: root

    property bool live: false
    // IdleConfig.parse's settings (sleepFade, sleepFadeTimeS, sleepFallTimeS, sleepClimbTimeS, sleepFadeStrength, panel, brightnessctl)
    property var settings: ({})
    // the shell's one SleepWatcher (a probe hands one of its own). Not live, the singleton is not even asked for: a mock shell or a probe
    // of the idle service must not start the system-bus monitor it makes on first use
    property var watcher: root.live ? Sleep.watcher : null
    // LockOwner, or a stand-in: `locked`, `lockState` { phase, lockedAt, veilAt?, dots }. null: no lock is known (the fall starts at the
    // latest moment)
    property var lock: null
    // the OSD's brightness curve ({ gamma, step, floorRaw }); undefined: OsdKinds' defaults
    property var ladder: undefined
    // build the per-output veil windows (SleepVeils.qml). false for a harness without a layer-shell backend (offscreen)
    property bool windows: true

    // the panel's backlight (PanelBacklight); a probe names its fake
    property string device: PanelBacklight.device
    // raw 0 turns the panel black (false: the veil draws the dark itself over the panel as well)
    property bool zeroIsBlack: PanelBacklight.zeroIsBlack
    property int marginMs: 700
    property int stopGraceMs: 200
    property int veilLeadMs: 1000
    property int stuckS: 20
    property int stepMs: 40
    property int focusMs: 300
    property int captureWaitMs: 400
    // a wake's capture (the first presented frames of the resume): the longest wait in the dark before the climb goes without it. A session that never comes back gets its
    // light back by then
    property int wakeWaitMs: 4000
    // this long with no frame presented, during a wake, is a stall: it is not counted
    property int stallMs: 100
    property string campaignFile: "/var/lib/suspend-lab/campaign.json"
    property string recordFile: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/" + Quickshell.env("UID")) + "/lares-sleep-fade.json"
    // the delay inhibitor's holder: it prints "held" once logind has granted the lock, and holds it until it is killed
    property var inhibitCommand: ["setpriv", "--pdeathsig", "TERM", "--", "systemd-inhibit", "--what=sleep", "--mode=delay", "--who=lares",
        "--why=The screen dims before the machine sleeps (the shell's sleep fade)",
        "setpriv", "--pdeathsig", "TERM", "--", "sh", "-c", "echo held; exec sleep infinity"]
    // logind's cap on a delay inhibitor (read once; "t <usec>")
    property var capCommand: ["busctl", "--system", "get-property", "org.freedesktop.login1", "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager", "InhibitDelayMaxUSec"]
    property var guardCommand: ["python3", "-I", RepoRoot.dir + "/modules/idle/sleep/sleep_guard.py"]
    // a probe's stand-in for the guard's two clocks (a file holding boottime - monotonic); "" = the real clocks
    property string guardClock: ""

    readonly property bool on: root.settings.sleepFade !== false
    readonly property real strength: typeof root.settings.sleepFadeStrength === "number" ? root.settings.sleepFadeStrength : 1
    // what the veil draws of the dream: the strength, less what a key typed during the climb took off it
    readonly property real dream: root.strength * root._focusK
    // The two ways are timed apart: the fall into sleep and the
    // climb out of it. A settings object with only the one time (sleepFadeTimeS, the key that was there first) gives it to both.
    readonly property int fallMs: root._timeMs(root.settings.sleepFallTimeS)
    readonly property int climbMs: root._timeMs(root.settings.sleepClimbTimeS)
    function _timeMs(own: var): int {
        const s = typeof own === "number" ? own : (typeof root.settings.sleepFadeTimeS === "number" ? root.settings.sleepFadeTimeS : 1.5);
        return Math.round(s * 1000);
    }
    readonly property string brightnessctl: root.settings.brightnessctl || "brightnessctl"
    readonly property string panelPrefix: root.settings.panel || "eDP"

    // "rest" | "waiting" (the sleep is coming, the veil not done) | "falling" | "asleep" (released) | "waking" (resumed: the panel to 0,
    // the captures) | "rising" | "stuck" (the guard gave the light back over a machine that never slept) | "lidhold" | "lidwake" | "lidrise"
    readonly property string phase: root._phase
    readonly property real progress: root._p
    // "all" (a sleep) | "panel" (the lid)
    readonly property string mode: root._mode
    // the veil windows are wanted (mapped); `drawing` false: a CLEAR capture is being taken (the veils that can, draw nothing)
    readonly property bool shown: (root.strength > 0 || root._phase === "lidhold") && root._phase !== "rest" && root._phase !== "stuck"
    readonly property bool drawing: root._drawing
    // bumped when every covered veil must capture its output now; each answers captured(name, ok) while `capturing`
    readonly property int captureSerial: root._captureSerial
    readonly property bool capturing: root._capturing
    // moves the veil's dither, one value per fade
    readonly property real seed: root._seed
    readonly property bool held: root._held
    // the panel's light is ours to write (the read found `device`)
    readonly property bool backlightOurs: root._ours
    // the level to give back (-1 unknown) and logind's cap
    readonly property int saved: root._saved
    // The panel has been given back its level (the climb landed, a key took over, the unlock skipped the rest, the guard lit it) and the
    // level came from SoftIdle's saved value: SoftIdle forgets its dimming (SoftIdle.panelGivenBack).
    signal gaveBack
    readonly property int capMs: root._capMs
    readonly property var veilWindows: veilLoader.item ? veilLoader.item.instances : []
    // [{ event, at, result?, value? }], oldest first, the last 200
    readonly property var log: root._log

    function covers(name: string): bool {
        return Rules.covers(root._mode, name, root.panelPrefix);
    }
    function selfDims(name: string): bool {
        return Rules.selfDims(name, root.panelPrefix, root._ours && root.zeroIsBlack);
    }

    // ---- the lid (IdleService wires LidDim's climb here) -----------------------------------------------------------------------
    // LidDim put the panel at 0 and 0 is not black there (zeroIsBlack false): hold the panel's output black, or let go (on = false)
    function lidHold(on: bool): void {
        if (!on) {
            if (root._phase === "lidhold") {
                root._note({ event: "lidhold", result: "off" });
                root._toRest();
            }
            return;
        }
        const p = root._phase;
        if (!root.on || (p !== "rest" && p !== "stuck" && p !== "lidwake" && p !== "lidrise"))
            return;
        // (a climb the lid closing again stopped: the veil is rising over a panel that is back at 0)
        clock.stop();
        root._note({ event: "lidhold", result: "on" });
        root._mode = "panel";
        root._ours = true;
        root._seed = Math.random();
        root._capturing = false;
        root._drawing = true;
        root._wantVeils(true);
        root._phase = "lidhold";
        root._setP(1);
    }
    function lidWake(ms: int): void {
        if (!root.on || ms < 100 || (root._phase !== "rest" && root._phase !== "stuck" && root._phase !== "lidhold"))
            return;
        root._note({ event: "lidwake", value: ms });
        root._mode = "panel";
        // LidDim climbs only a panel its engage found: the light under this veil is the backlight's
        root._ours = true;
        root._seed = Math.random();
        root._wakeMs = ms;
        root._wantVeils();
        root._phase = "lidwake";
        root._setP(1);
        beat.start();
        root._askCapture(true);
    }
    function lidEnd(result: string): void {
        if (root._phase !== "lidwake" && root._phase !== "lidrise")
            return;
        root._note({ event: "lidend", result: result });
        // a key during the climb: the user's light, and the picture comes into focus with it (at once if it is not even shown yet)
        if (result === "kept" && root._phase === "lidrise")
            root._focus();
        else if (result !== "restored")
            root._toRest();
    }

    // ---- what a veil window says ------------------------------------------------------------------------------------------------
    function presented(): void {
        root._presentedAt = Date.now();
    }
    function captured(name: string, ok: bool): void {
        if (!root._capturing)
            return;
        root._captureAnswers[name] = ok;
        root._note({ event: "captured", result: name, value: ok ? 1 : 0 });
        const want = root._coveredWindows();
        for (let i = 0; i < want.length; i++)
            if (!(want[i] in root._captureAnswers))
                return;
        root._captureDone();
    }

    // ---- state ------------------------------------------------------------------------------------------------------------------
    property string _phase: "rest"
    property string _mode: "all"
    property real _p: 0
    property bool _drawing: true
    property int _captureSerial: 0
    property bool _capturing: false
    property var _captureAnswers: ({})
    property real _captureAt: 0
    property real _seed: 0
    property bool _held: false
    property bool _released: false
    property bool _ours: false
    // the level to give back, and where the fall starts (the panel as read: a sleep that comes during a wake falls from where the climb
    // was, and still gives back the level it had)
    property int _saved: -1
    // the level to give back is SoftIdle's saved brightness (the state file existed at the sleep): the give-back is told to SoftIdle
    property bool _fromState: false
    property int _fallFrom: -1
    property int _max: 1
    property int _capMs: 5000
    property real _t0: 0
    property real _deadline: 0
    property int _fallLen: 0
    property int _wakeMs: 0
    property bool _fallDone: false
    property bool _readDone: false
    property bool _skipPending: false
    // a step asked to stop: what runs once it has (or once the grace is over), and since when
    property var _afterStop: null
    property var _stopping: null
    property real _stopAt: 0
    property var _log: []

    // the progress clock: from -> to over ms, wall time
    property real _from: 0
    property real _to: 0
    property real _clockT0: 0
    property int _clockMs: 0
    property real _clockLast: 0
    // the veil windows' last presented frame since the clock started (0: none yet: no veil is mapped, or the first is on its way)
    property real _presentedAt: 0
    // 1 .. 0 over focusMs from the key that asked (0: nobody asked)
    property real _focusK: 1
    property real _focusAt: 0

    function _note(e: var): void {
        e.at = Date.now();
        const next = root._log.concat([e]);
        root._log = next.length > 200 ? next.slice(next.length - 200) : next;
        if (root.live)
            console.log("SleepFade: " + e.event + (e.result !== undefined ? " " + e.result : "") + (e.value !== undefined ? " " + e.value : ""));
    }
    function _setP(v: real): void {
        clock.stop();
        root._p = Math.max(0, Math.min(1, v));
    }
    function _run(from: real, to: real, ms: int): void {
        root._from = from;
        root._to = to;
        root._clockT0 = Date.now();
        root._clockLast = root._clockT0;
        root._presentedAt = 0;
        root._clockMs = Math.max(1, ms);
        root._p = from;
        clock.start();
    }
    FrameAnimation {
        id: clock
        onTriggered: {
            const now = Date.now();
            // a wake's stall is the screen's, not the climb's: while no frame is being presented its time is not counted (this clock ticks on, Qt's animation timer does
            // not wait for the compositor). A fall keeps the wall clock: it has a deadline
            if (root._to < root._from && root._presentedAt > 0 && now - root._presentedAt > root.stallMs)
                root._clockT0 += now - root._clockLast;
            root._clockLast = now;
            if (root._focusAt > 0)
                root._focusK = Math.max(0, 1 - (now - root._focusAt) / Math.max(1, root.focusMs));
            const t = Math.min(1, (now - root._clockT0) / root._clockMs);
            root._p = root._from + (root._to - root._from) * t;
            if (t >= 1) {
                clock.stop();
                root._clockEnded();
            }
        }
    }
    function _clockEnded(): void {
        if (root._phase === "falling") {
            if (root._fallDone)
                root._release("fell");
        } else if (root._phase === "rising" || root._phase === "lidrise") {
            root._toRest();
        }
    }

    // ---- the inhibitor ----------------------------------------------------------------------------------------------------------
    SupervisedStream {
        id: holder
        enabled: root.live && root.on && !root._released
        command: root.inhibitCommand
        what: "SleepFade: the sleep delay inhibitor"
        onLine: text => {
            if (String(text).trim() === "held") {
                root._held = true;
                root._note({ event: "held" });
            }
        }
        onExited: (code, expected) => {
            root._held = false;
            root._note({ event: "unheld", result: expected ? "released" : "exit " + code });
        }
    }

    // logind's cap, once
    Process {
        id: capRead
        stdout: StdioCollector {
            onStreamFinished: {
                const ms = Rules.parseCap(this.text);
                if (ms > 0)
                    root._capMs = ms;
            }
        }
    }

    // ---- the beat: the fall's start, the release's deadline, the waits, on the wall clock -------------------------------------------
    Timer {
        id: beat
        interval: 25
        repeat: true
        onTriggered: root._tick()
    }
    function _tick(): void {
        const now = Date.now();
        // a step that was asked to stop: killed after the grace, forgotten after twice that (a call that hangs must not hold the release)
        if (root._afterStop !== null && now - root._stopAt >= root.stopGraceMs) {
            if (root._stopping && root._stopping.running)
                root._stopping.running = false;
            if (now - root._stopAt >= 2 * root.stopGraceMs)
                root._stopped("grace");
        }
        if (root._phase === "waiting") {
            if ((root._readDone && now >= Rules.fallStart(now, root._veilAt(), root._deadline - root.stopGraceMs, root.fallMs)) || now >= root._deadline - root.stopGraceMs)
                root._fall();
        } else if (root._phase === "falling") {
            if (now >= root._deadline - root.stopGraceMs && root._afterStop === null)
                root._stop(fallStep, 10, () => root._release("deadline"));
            else if (root._capturing && now - root._captureAt >= root.captureWaitMs)
                root._captureDone();
        } else if (root._phase === "waking") {
            if (root._capturing && now - root._captureAt >= root.wakeWaitMs)
                root._captureDone();
        } else if (root._phase === "lidwake") {
            if (root._capturing && now - root._captureAt >= root.captureWaitMs)
                root._captureDone();
        } else if (root._afterStop === null) {
            beat.stop();
        }
    }

    // Ask a running step to stop (signal 10 = USR1: finish, 12 = USR2: halt) and run `then` once it has; a step that is not running is
    // stopped already.
    function _stop(step: var, sig: int, then: var): void {
        if (!step.running) {
            then();
            return;
        }
        root._stopping = step;
        root._afterStop = then;
        root._stopAt = Date.now();
        step.signal(sig);
        beat.start();
    }
    function _stopped(why: string): void {
        const then = root._afterStop;
        root._afterStop = null;
        root._stopping = null;
        if (then) {
            if (why === "grace")
                root._note({ event: "stopgrace" });
            then();
        }
    }

    // ---- the sleep --------------------------------------------------------------------------------------------------------------
    Connections {
        target: root.watcher
        function onAboutToSleep() {
            root._sleep();
        }
        function onResumed() {
            root._resume("signal");
        }
    }
    Connections {
        target: root.lock ? root.lock.lockState : null
        ignoreUnknownSignals: true
        function onPhaseChanged() {
            root._tick();
            root._lockMoved();
        }
        function onDotsChanged() {
            if (root._phase === "rising")
                root._focus();
        }
    }
    Connections {
        target: root.lock
        ignoreUnknownSignals: true
        function onLockedChanged() {
            root._lockMoved();
        }
    }
    function _veilAt(): real {
        return root.lock ? Rules.veilDoneAt(root.lock.lockState, root.veilLeadMs) : NaN;
    }

    function _sleep(): void {
        if (!root.on)
            return;
        // a lid wake in the middle is over: the machine is going
        if (root._phase === "lidwake" || root._phase === "lidrise" || root._phase === "lidhold")
            root._toRest();
        if (root.live && !root._held) {
            root._note({ event: "sleep", result: "unheld" });
            return;
        }
        // a sleep during a wake: the climb halts, the veil falls from where it is, the level to give back stays the one it was
        const midWake = root._phase === "waking" || root._phase === "rising";
        const keep = midWake ? root._saved : -1;
        root._t0 = Date.now();
        root._deadline = Rules.deadline(root._t0, root._capMs, root.marginMs);
        root._mode = "all";
        root._fallDone = false;
        root._readDone = false;
        root._skipPending = false;
        root._saved = -1;
        root._fallFrom = -1;
        root._seed = Math.random();
        root._note({ event: "sleep", result: "waiting", value: root._deadline - root._t0 });
        root._phase = "waiting";
        root._setP(midWake ? root._p : 0);
        root._drawing = true;
        root._capturing = false;
        root._wantVeils();
        beat.start();
        root._stop(riseStep.running ? riseStep : wakeStep, 12, () => root._read(keep));
    }

    // the panel's level and maximum, read while the lock comes up
    function _read(keep: int): void {
        if (!root.live) {
            root._ours = true;
            root._fallFrom = 300;
            root._saved = keep > 0 ? keep : 300;
            root._max = 400;
            root._readDone = true;
            root._note({ event: "read", result: "mock" });
            root._tick();
            return;
        }
        root._keep = keep;
        readStep.command = ["bash", "-c",
            "[ -n \"$2\" ] || { echo nodevice; exit 0; }\n"
            + "v=$(\"$1\" -c backlight -d \"$2\" g 2>/dev/null) || { echo nodevice; exit 0; }\n"
            + "case \"$v\" in ''|*[!0-9]*) echo nodevice; exit 0;; esac\n"
            + "m=$(\"$1\" -c backlight -d \"$2\" m 2>/dev/null)\n"
            + "case \"$m\" in ''|*[!0-9]*) m=$v;; esac\n"
            + "s=$(cat \"$3\" 2>/dev/null); case \"$s\" in ''|*[!0-9]*) s=-;; esac\n"
            + "echo \"level $v $m $s\"", "sleep-read", root.brightnessctl, root.device, root.stateFile];
        readStep.running = true;
    }
    property int _keep: -1
    // the brightness script's state file (IdleConfig.parse always has it; a harness's settings without one read nothing)
    readonly property string stateFile: root.settings.stateFile || ""
    function _gaveBack(): void {
        if (!root._fromState)
            return;
        root._fromState = false;
        root._note({ event: "gaveback", value: root._saved });
        root.gaveBack();
    }
    Process {
        id: readStep
        stdout: StdioCollector {
            onStreamFinished: {
                const l = Rules.parseLevel(this.text.trim());
                root._ours = l.ok;
                root._fallFrom = l.ok ? l.saved : -1;
                root._saved = l.ok ? (root._keep > 0 ? root._keep : l.given) : -1;
                root._fromState = l.ok && l.state >= 0;
                root._max = l.ok ? l.max : 1;
                root._readDone = true;
                root._note({ event: "read", result: l.ok ? "level" : "nodevice", value: root._saved });
                root._tick();
            }
        }
    }

    function _fall(): void {
        if (root._phase !== "waiting")
            return;
        root._phase = "falling";
        root._fallLen = Rules.fallLength(Date.now(), root._deadline - root.stopGraceMs, root.fallMs);
        root._note({ event: "fall", value: root._fallLen });
        if (root._fallLen <= 0) {
            // no room left before logind's cap (a lock that never came, a cap smaller than the margin): release now, lit
            root._setP(1);
            root._release("nocap");
            return;
        }
        // the guard first: it reads its clocks before anything is dark
        if (root.live && root._ours && root._saved > 0)
            root._startGuard();
        // A picture of the output only of a LOCKED output: with no lock up (a late lock, none at all) the picture would be the desktop,
        // and the veil -- above the lock once it comes -- would show it over the lock for the whole fall. Then the lids and the light alone.
        const st = root.lock ? root.lock.lockState : null;
        if (st !== null && st.phase === "locked") {
            root._askCapture(false);
        } else {
            root._note({ event: "nopicture", result: "no lock up" });
            root._capturing = true;
            root._captureDone();
        }
    }
    // the stills are in (or the wait is over): the clock and the light go together, over what is left before the deadline NOW (the
    // capture takes some of it: a late veil and a slow capture cut the deadline under a fall planned at its start)
    function _fallGo(): void {
        root._fallLen = Rules.fallLength(Date.now(), root._deadline - root.stopGraceMs, root.fallMs);
        if (root._fallLen <= 0) {
            root._setP(1);
            root._release("nocap");
            return;
        }
        root._run(root._p, 1, Math.round(root._fallLen * (1 - root._p)));
        if (root.live && root._ours && root._fallFrom > 0) {
            const plan = Rules.fallPlan(Osd, root._fallFrom, root._max, root.ladder, Math.round(root._fallLen * (1 - root._p)), root.stepMs);
            fallStep.command = ["bash", "-c",
                "B=$1; D=$2; rec=$3; v0=$4; mx=$5; dt=$6; sv=$7; shift 7\n"
                + "stop=0; trap 'stop=1' USR1\n"
                + "printf '{\"device\":\"%s\",\"saved\":%s,\"max\":%s}\\n' \"$D\" \"$sv\" \"$mx\" > \"$rec.tmp\" && mv -f \"$rec.tmp\" \"$rec\"\n"
                + "last=$v0; i=0; t0=${EPOCHREALTIME/[.,]/}\n"
                + "for r in \"$@\"; do\n"
                + "  [ $stop = 1 ] && { echo stopped; exit 0; }\n"
                + "  i=$((i + 1))\n"
                + "  cur=$(\"$B\" -c backlight -d \"$D\" g 2>/dev/null) || { [ $stop = 1 ] && { echo stopped; exit 0; }; echo fail; exit 0; }\n"
                + "  [ \"$cur\" = \"$last\" ] || { echo \"kept $cur\"; exit 0; }\n"
                + "  [ $stop = 1 ] && { echo stopped; exit 0; }\n"
                + "  \"$B\" -c backlight -d \"$D\" set \"$r\" >/dev/null 2>&1 || { echo fail; exit 0; }\n"
                + "  last=$r\n"
                + "  [ \"$r\" = 0 ] || { w=$((t0 + i * dt - ${EPOCHREALTIME/[.,]/})); [ \"$w\" -le 0 ] || { sleep \"$((w / 1000000)).$(printf %06d $((w % 1000000)))\" >/dev/null 2>&1 & wait $!; }; }\n"
                + "done\n"
                + "echo fell",
                "sleep-fall", root.brightnessctl, root.device, root.recordFile, String(root._fallFrom), String(root._max),
                String(Math.round(plan.sleepS * 1e6)), String(root._saved)].concat(plan.raws.map(String));
            fallStep.running = true;
        } else {
            root._fallDone = true;
            if (!root.live)
                root._note({ event: "fallstep", result: "mock" });
        }
    }
    Process {
        id: fallStep
        stdout: StdioCollector {
            onStreamFinished: {
                root._note({ event: "fallstep", result: this.text.trim().split("\n")[0] || "fail" });
                root._fallDone = true;
                if (root._stopping === fallStep)
                    root._stopped("step");
                else if (root._phase === "falling" && !clock.running)
                    root._release("fell");
            }
        }
    }

    function _release(why: string): void {
        if (root._phase !== "falling")
            return;
        root._setP(1);
        root._capturing = false;
        root._released = true;
        root._phase = "asleep";
        root._note({ event: "release", result: why, value: Date.now() - root._t0 });
        // nothing is STARTED from here on: the guard was started at the fall and only hears a line
        if (guard.running)
            guard.write("go\n");
    }

    // ---- the guard --------------------------------------------------------------------------------------------------------------
    function _startGuard(): void {
        if (guard.running)
            guard.running = false;
        const args = ["brightnessctl=" + root.brightnessctl, "device=" + root.device, "saved=" + root._saved, "stuck=" + root.stuckS];
        if (root.guardClock !== "")
            args.push("clock=" + root.guardClock);
        guard.command = root.guardCommand.concat(args);
        guard.stdinEnabled = true;
        guard.running = true;
    }
    Process {
        id: guard
        stdout: SplitParser {
            onRead: data => {
                const parts = String(data).split("\n");
                for (let i = 0; i < parts.length; i++) {
                    const l = parts[i].trim();
                    if (l !== "")
                        root._guardSaid(l);
                }
            }
        }
    }
    function _guardSaid(l: string): void {
        root._note({ event: "guard", result: l });
        const w = l.split(" ");
        if (w[0] === "slept" && root._phase === "asleep") {
            // the machine slept and woke and nobody said so (the monitor was down): wake now -- the light is back already
            root._resume("guard");
            root._gaveBack();
        } else if (w[0] === "stuck" && root._phase === "asleep") {
            root._phase = "stuck";
            root._gaveBack();
        }
    }

    // ---- the wake ---------------------------------------------------------------------------------------------------------------
    function _resume(why: string): void {
        if (root._phase === "rest" || root._phase === "lidwake" || root._phase === "lidrise" || root._phase === "lidhold")
            return;
        const from = root._phase;
        root._released = false;
        if (guard.running && why !== "guard")
            guard.running = false;
        root._capturing = false;
        root._skipPending = false;
        // the guard gave the level back itself: nothing to climb
        if (why === "guard")
            root._ours = false;
        root._note({ event: "resume", result: why, value: from });
        root._mode = "all";
        root._phase = "waking";
        beat.start();
        if (from === "waiting" || from === "falling") {
            // the sleep failed at once: the fall halts after its current write, and the climb starts from where it was, on the fall's
            // own stills, at the share of the pace that is left
            root._wakeMs = Math.round(root.climbMs * root._p);
            root._setP(root._p);
            root._stop(fallStep, 10, () => {
                root._capturing = true;
                root._captureDone();
            });
            return;
        }
        // from asleep (or a stuck entry the guard lit again): the whole climb, from 0
        root._wakeMs = root.climbMs;
        root._setP(1);
        if (root.live && root._ours && root._saved > 0) {
            // the campaign is the lab's; else the panel goes to 0 BEFORE anything is captured (the kernel may have lit it at resume:
            // a capture with the veil clear would flash the live screen at that light)
            wakeStep.command = ["bash", "-c",
                "if [ -n \"$4\" ] && [ -r \"$4\" ] && python3 -I -c 'import json, sys\ntry:\n    sys.exit(0 if json.load(open(sys.argv[1])).get(\"status\") == \"running\" else 1)\nexcept Exception:\n    sys.exit(1)' \"$4\"; then rm -f \"$3\"; echo campaign; exit 0; fi\n"
                + "cur=$(\"$1\" -c backlight -d \"$2\" g 2>/dev/null) || { echo fail; exit 0; }\n"
                + "[ \"$cur\" = 0 ] || \"$1\" -c backlight -d \"$2\" set 0 >/dev/null 2>&1 || { echo fail; exit 0; }\n"
                + "echo \"dark $cur\"",
                "sleep-wake", root.brightnessctl, root.device, root.recordFile, root.campaignFile];
            wakeStep.running = true;
        } else {
            if (!root.live)
                root._note({ event: "wakestep", result: "mock" });
            root._askCapture(true);
        }
    }
    Process {
        id: wakeStep
        stdout: StdioCollector {
            onStreamFinished: {
                const r = this.text.trim().split("\n")[0] || "fail";
                root._note({ event: "wakestep", result: r });
                if (root._stopping === wakeStep) {
                    root._stopped("step");
                    return;
                }
                if (root._phase !== "waking")
                    return;
                if (r === "campaign") {
                    // the lab keeps the panel dark: no write, and nothing of ours stays up over it
                    root._toRest();
                    return;
                }
                if (r === "fail")
                    root._ours = false;
                if (root._skipPending) {
                    root._skip();
                    return;
                }
                root._askCapture(true);
            }
        }
    }

    function _riseGo(): void {
        const ms = root._wakeMs;
        root._phase = "rising";
        root._run(root._p, 0, ms);
        if (root.live && root._ours && root._saved > 0) {
            const plan = Lid.rampPlan(Osd, root._saved, root._max, root.ladder, Math.max(1, ms), root.stepMs);
            riseStep.command = ["bash", "-c",
                "B=$1; D=$2; rec=$3; full=$4; dt=$5; shift 5\n"
                + "skip=0; halt=0; trap 'skip=1' USR1; trap 'halt=1' USR2\n"
                + "last=$(\"$B\" -c backlight -d \"$D\" g 2>/dev/null) || { echo fail; exit 0; }\n"
                + "fin() {\n"
                + "  [ $halt = 1 ] && { echo halted; exit 0; }\n"
                + "  cur=$(\"$B\" -c backlight -d \"$D\" g 2>/dev/null) || { echo fail; exit 0; }\n"
                + "  [ \"$cur\" = \"$last\" ] || { rm -f \"$rec\"; echo \"kept $cur\"; exit 0; }\n"
                + "  \"$B\" -c backlight -d \"$D\" set \"$full\" >/dev/null 2>&1 || { echo fail; exit 0; }\n"
                + "  rm -f \"$rec\"; echo \"skipped $full\"; exit 0\n"
                + "}\n"
                + "i=0; t0=${EPOCHREALTIME/[.,]/}\n"
                + "for r in \"$@\"; do\n"
                + "  { [ $skip = 1 ] || [ $halt = 1 ]; } && fin\n"
                + "  [ \"$r\" -le \"$last\" ] && continue\n"
                + "  i=$((i + 1))\n"
                + "  cur=$(\"$B\" -c backlight -d \"$D\" g 2>/dev/null) || { echo fail; exit 0; }\n"
                + "  [ \"$cur\" = \"$last\" ] || { rm -f \"$rec\"; echo \"kept $cur\"; exit 0; }\n"
                + "  { [ $skip = 1 ] || [ $halt = 1 ]; } && fin\n"
                + "  \"$B\" -c backlight -d \"$D\" set \"$r\" >/dev/null 2>&1 || { echo fail; exit 0; }\n"
                + "  last=$r\n"
                + "  [ \"$r\" = \"$full\" ] || { w=$((t0 + i * dt - ${EPOCHREALTIME/[.,]/})); [ \"$w\" -le 0 ] || { sleep \"$((w / 1000000)).$(printf %06d $((w % 1000000)))\" >/dev/null 2>&1 & wait $!; }; }\n"
                + "done\n"
                + "rm -f \"$rec\"; echo \"risen $last\"",
                "sleep-rise", root.brightnessctl, root.device, root.recordFile, String(root._saved),
                String(Math.round(plan.sleepS * 1e6))].concat(plan.raws.map(String));
            riseStep.running = true;
        } else if (!root.live) {
            root._note({ event: "risestep", result: "mock" });
        }
    }
    Process {
        id: riseStep
        stdout: StdioCollector {
            onStreamFinished: {
                const r = this.text.trim().split("\n")[0] || "fail";
                root._note({ event: "risestep", result: r });
                if (root._stopping === riseStep) {
                    root._stopped("step");
                    return;
                }
                // a key during the climb is the user's light: the picture comes into focus with it
                if (r.split(" ")[0] === "kept")
                    root._focus();
                // the panel is the user's again (the level, or the value a key put there): SoftIdle lets go of what it saved
                if (["risen", "skipped", "kept"].indexOf(r.split(" ")[0]) >= 0)
                    root._gaveBack();
            }
        }
    }

    // a key typed (or pressed on the brightness keys): the blur goes within focusMs. The vignette keeps its pace: it hides nothing in the middle of the screen, and a
    // key must not end the wake (a key, or the brightness the compositor puts back, would collapse the veil to nothing)
    function _focus(): void {
        if ((root._phase !== "rising" && root._phase !== "lidrise") || root._p <= 0 || root._focusAt > 0)
            return;
        root._focusAt = Date.now();
    }

    // the lock going away while it wakes skips the rest: the level at once, the veil gone
    function _lockMoved(): void {
        if (root._phase !== "rising" && root._phase !== "waking")
            return;
        const st = root.lock ? root.lock.lockState : null;
        const gone = !root.lock || root.lock.locked === false || (st !== null && st.phase === "unlocking");
        if (!gone)
            return;
        root._note({ event: "skip", value: root._saved });
        if (riseStep.running)
            riseStep.signal(10);   // it writes the level itself, after its current call
        else if (wakeStep.running)
            root._skipPending = true;   // the panel is going to 0 first; the level once it is there
        else
            root._skip();
        if (!root._skipPending)
            root._toRest();
    }
    function _skip(): void {
        if (root.live && root._ours && root._saved > 0) {
            skipStep.command = ["bash", "-c",
                "cur=$(\"$1\" -c backlight -d \"$2\" g 2>/dev/null) || { echo fail; exit 0; }\n"
                + "[ \"$cur\" -lt \"$4\" ] 2>/dev/null && { \"$1\" -c backlight -d \"$2\" set \"$4\" >/dev/null 2>&1 || { echo fail; exit 0; }; }\n"
                + "rm -f \"$3\"; echo \"skipped $4\"",
                "sleep-skip", root.brightnessctl, root.device, root.recordFile, String(root._saved)];
            skipStep.running = true;
        }
        root._skipPending = false;
        root._toRest();
    }
    Process {
        id: skipStep
        stdout: StdioCollector {
            onStreamFinished: {
            const r = this.text.trim().split("\n")[0] || "fail";
            root._note({ event: "skipstep", result: r });
            if (r.split(" ")[0] === "skipped")
                root._gaveBack();
        }
        }
    }

    function _toRest(): void {
        // (live, the steps above say it when the panel is written; a mock has no step)
        if (!root.live && (root._phase === "rising" || root._phase === "waking"))
            root._gaveBack();
        clock.stop();
        root._capturing = false;
        root._p = 0;
        root._focusAt = 0;
        root._focusK = 1;
        root._drawing = true;
        root._phase = "rest";
        root._note({ event: "rest" });
    }

    // ---- the capture ------------------------------------------------------------------------------------------------------------
    function _coveredWindows(): var {
        const out = [];
        const list = root.veilWindows || [];
        for (let i = 0; i < list.length; i++) {
            const n = list[i] ? list[i].outputName : "";
            if (n !== "" && root.covers(n))
                out.push(n);
        }
        return out;
    }
    // clear: the veils draw nothing while they capture (a wake: what is under them is the screen to wake to, and the panel is dark)
    function _askCapture(clear: bool): void {
        root._capturing = true;
        if (root.strength <= 0 || !root.windows || root._coveredWindows().length === 0) {
            root._captureDone();
            return;
        }
        root._captureAnswers = ({});
        root._captureAt = Date.now();
        root._drawing = !clear;
        root._captureSerial++;
        beat.start();
    }
    function _captureDone(): void {
        if (!root._capturing)
            return;
        root._capturing = false;
        root._drawing = true;
        if (root._phase === "falling") {
            root._fallGo();
        } else if (root._phase === "lidwake") {
            root._phase = "lidrise";
            root._run(1, 0, root._wakeMs);
        } else if (root._phase === "waking") {
            root._riseGo();
        }
    }

    // ---- the windows ------------------------------------------------------------------------------------------------------------
    // A file of its own behind a LazyLoader whose source is set by hand the first time it is wanted (ThemeControl's curtain pattern:
    // a PanelWindow cannot be loaded without a layer-shell backend, and a LazyLoader compiles its source the moment it is set).
    LazyLoader {
        id: veilLoader
        active: false
    }
    function _wantVeils(force: bool): void {
        if (!root.windows || (root.strength <= 0 && !force))
            return;
        if (veilLoader.source.toString() === "")
            veilLoader.source = Qt.resolvedUrl("SleepVeils.qml");
        veilLoader.active = true;
    }
    Binding {
        target: veilLoader.item
        property: "fade"
        value: root
        when: veilLoader.item !== null
    }

    // ---- the start --------------------------------------------------------------------------------------------------------------
    // a fall that a dead shell left behind: the light back, if the panel still reads the fade's 0
    Process {
        id: bootStep
        stdout: StdioCollector {
            onStreamFinished: {
                const r = this.text.trim();
                if (r !== "none")
                    root._note({ event: "boot", result: r });
            }
        }
    }
    Component.onCompleted: {
        if (!root.live || !root.on)
            return;
        capRead.command = root.capCommand;
        capRead.running = true;
        bootStep.command = ["bash", "-c",
            "[ -r \"$3\" ] || { echo none; exit 0; }\n"
            + "s=$(grep -o '\"saved\":[0-9]*' \"$3\" | cut -d: -f2); rm -f \"$3\"\n"
            + "case \"$s\" in ''|*[!0-9]*|0) echo nothing; exit 0;; esac\n"
            + "cur=$(\"$1\" -c backlight -d \"$2\" g 2>/dev/null) || { echo fail; exit 0; }\n"
            + "[ \"$cur\" = 0 ] || { echo \"kept $cur\"; exit 0; }\n"
            + "\"$1\" -c backlight -d \"$2\" set \"$s\" >/dev/null 2>&1 && echo \"restored $s\" || echo fail",
            "sleep-boot", root.brightnessctl, root.device, root.recordFile];
        bootStep.running = true;
    }
}
