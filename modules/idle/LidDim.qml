pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "LidRules.js" as Rules
// the OSD's own brightness curve (brightnessRungs / brightnessPos / brightnessRawAt): the restore climbs it evenly in how bright it LOOKS
import "../osd/data/OsdKinds.js" as Osd
import "../common/system"

// =============================================================================
// LidDim.qml -- the lid closed in HARD idle puts the panel at 0: a lit screen inside a closed lid is never wanted, whatever the mode
// (an OLED, where 0 is off).
//
// Hard idle is a `handle-lid-switch` inhibitor, so logind does nothing when the lid closes and the panel would stay lit inside a closed
// lid. In every other mode logind (or hypridle) already decides what a closed lid does, and this does nothing.
//
//   want = the lid is closed AND the mode is hard         (a state, not an event: applying hard under a closed lid, or leaving it
//                                                           under one, takes the same two paths as closing and opening)
//   engage   save the panel's raw value, set 0          -- if it was already 0 there is nothing to give back
//   release  read the panel; if it still reads 0 (our 0) give the saved value back, anything else is the USER'S: a brightness key
//            pressed under the lid (the OSD steps up from 0 as it always does: that is the user's override) wins,
//            and opening the lid does not take it from them. THE GIVING BACK IS A RAMP (`restoreMs`, 2.5 s: a slow return to the
//            original brightness on opening reads as more cinematic): the panel climbs from 0 to the saved value
//            along the brightness keys' perceived curve, evenly in how bright it looks (LidRules.rampPlan), one write per ~40 ms from a
//            single bash. Before every write the loop reads the panel and stops if it is not where the loop left it -- the value it
//            WROTE (sysfs reads back the value set; reading it again after the write would take a key pressed in that instant for the loop's
//            own): a key pressed during the climb is the user's and wins at once ("kept"). The lid closing again during the climb stops it
//            (the bash is ended) and the next engage keeps the FULL value saved, not the half-lit one the panel reads then.
//
// THE PANEL ONLY: `brightnessctl -c backlight -d <device>` -- PanelBacklight's device BY NAME (the backlight of the GPU that drives the eDP:
// intel_backlight in Hybrid, nvidia_0 in dGPU-only): brightnessctl without -d takes the first backlight it finds, which can be the dGPU's
// when it is not the panel's (a poke of the dGPU; the strongest correlate of the machine's suspend hangs, docs/idle.md). No such device:
// every step fails and says so, nothing else is written.
// WHERE 0 IS NOT BLACK (PanelBacklight.zeroIsBlack false: nvidia_0) the engage still writes 0 -- the device's lowest -- and asks the sleep veil to
// HOLD the panel's output black (`veil.lidHold(true)`, SleepFade) for as long as the lid is shut; the release hands over to the veil's wake
// (the climb) or lets the hold go when nothing climbs. IdleService sets `veil: sleepFader`. The keyboard's light (class leds) is left as it is.
// THE CLIMB IS ANNOUNCED: `climbing(ms)` when the release has found our 0 and starts to climb, `climbEnded(result)` when it is over -- the
// sleep veil (SleepFade.lidWake) wakes the panel's picture at the same pace.
// ONE STEP AT A TIME, each a single `bash` (read and write in one process, so a key between the two is a window of milliseconds), and
// the state is re-judged when a step ends: a lid closed and opened again while the engage runs ends released.
// NOT LIVE (the mock mode of the whole shell): nothing runs; each step is recorded in `log` with result "mock".
// What it cannot do: a shell that dies under a closed lid in hard idle leaves the panel at 0 (its saved value is in memory); the lid
// opening gives nothing back then, and a brightness key does.
// =============================================================================
Item {
    id: root

    property bool live: false
    // hard idle is the applied mode (IdleService)
    property bool active: false
    // the lid: LidWatcher's `closed` (a probe feeds it)
    property bool lidClosed: false
    property string brightnessctl: "brightnessctl"
    // the panel's backlight, by name (never the first one brightnessctl finds)
    property string device: PanelBacklight.device
    // 0 turns the panel black (false: the veil is asked to hold it dark)
    property bool zeroIsBlack: PanelBacklight.zeroIsBlack
    // the sleep fade (SleepFade: lidHold). null: no hold is asked
    property var veil: null
    // How long the restore takes, ms (0: one write, at once), and the OSD's brightness curve numbers ({ gamma, step, floorRaw }; anything
    // missing takes OsdKinds' default) the ramp climbs.
    property int restoreMs: 2500
    property var ladder: undefined
    // How often the ramp writes the panel, ms.
    readonly property int stepMs: 40

    // [{ event: "engage" | "release", result, value?, ms }], oldest first, the last 100. Results: engage "saved" (value = the panel's
    // raw value, now 0) | "already0" | "fail" | "mock"; release "restored" (value) | "kept" (value = what the panel reads: not ours) |
    // "nothing" (there was nothing saved) | "aborted" (the lid closed again during the climb) | "fail" | "mock".
    readonly property var log: root._log
    // The lid is shut on a panel we put at 0.
    readonly property bool engaged: root._engaged

    readonly property bool want: root.active && root.lidClosed

    // the climb started (the panel read our 0) and takes `ms`; the release step's result when it is over
    signal climbing(int ms)
    signal climbEnded(string result)

    property bool _engaged: false
    property int _saved: -1
    property int _max: 1
    // the full value of a climb that was stopped by the lid closing again: the next engage saves THIS, not the half-lit panel
    property int _keep: -1
    property bool _ramping: false
    property bool _busy: false
    property var _log: []

    function _note(e: var): void {
        e.ms = Date.now();
        const next = root._log.concat([e]);
        root._log = next.length > 100 ? next.slice(next.length - 100) : next;
    }

    onWantChanged: root._judge()
    Component.onCompleted: root._judge()

    function _judge(): void {
        if (root._busy) {
            // the lid closed again (or hard was applied again) during the climb: end it, the engage follows when it is gone
            if (root.want && root._ramping && !root._aborting) {
                root._aborting = true;
                step.running = false;
            }
            return;
        }
        if (root.want && !root._engaged) {
            root._engaged = true;
            root._saved = -1;
            root._start("engage", "[ -n \"$2\" ] || { echo fail; exit 0; }\n"
                + "v=$(\"$1\" -c backlight -d \"$2\" g 2>/dev/null) || { echo fail; exit 0; }\n"
                + "case \"$v\" in ''|*[!0-9]*) echo fail; exit 0;; esac\n"
                + "m=$(\"$1\" -c backlight -d \"$2\" m 2>/dev/null)\n"
                + "if [ \"$v\" -gt 0 ]; then \"$1\" -c backlight -d \"$2\" set 0 >/dev/null 2>&1 && echo \"saved $v $m\" || echo fail; else echo already0; fi", []);
        } else if (!root.want && root._engaged) {
            root._engaged = false;
            if (root._saved < 0) {
                root._note({ event: "release", result: "nothing" });
                if (root.veil)
                    root.veil.lidHold(false);
                return;
            }
            // the climb: one bash, reading the panel before every write (what is not where the loop left it is the user's)
            const plan = Rules.rampPlan(Osd, root._saved, root._max, root.ladder, root.restoreMs, root.stepMs);
            root._start("release", "B=$1; D=$2; v=$(\"$B\" -c backlight -d \"$D\" g 2>/dev/null) || { echo fail; exit 0; }\n"
                + "[ \"$v\" = 0 ] || { echo \"kept $v\"; exit 0; }\n"
                + "echo climb\n"
                + "last=0; dt=$3; full=$4; shift 4; i=0; t0=${EPOCHREALTIME/[.,]/}\n"
                + "for r in \"$@\"; do\n"
                + "  i=$((i + 1))\n"
                + "  cur=$(\"$B\" -c backlight -d \"$D\" g 2>/dev/null) || { echo fail; exit 0; }\n"
                + "  [ \"$cur\" = \"$last\" ] || { echo \"kept $cur\"; exit 0; }\n"
                + "  \"$B\" -c backlight -d \"$D\" set \"$r\" >/dev/null 2>&1 || { echo fail; exit 0; }\n"
                + "  last=$r\n"
                + "  [ \"$r\" = \"$full\" ] || { w=$((t0 + i * dt - ${EPOCHREALTIME/[.,]/})); [ \"$w\" -le 0 ] || sleep \"$((w / 1000000)).$(printf %06d $((w % 1000000)))\"; }\n"
                + "done\n"
                + "echo \"restored $full\"", [String(Math.round(plan.sleepS * 1e6)), String(root._saved)].concat(plan.raws.map(String)));
        }
    }

    function _start(event: string, script: string, args: var): void {
        if (!root.live) {
            root._saved = event === "engage" ? 1 : root._saved;
            root._note({ event: event, result: "mock" });
            Qt.callLater(root._judge);
            return;
        }
        root._busy = true;
        root._event = event;
        root._ramping = event === "release";
        root._aborting = false;
        step.command = ["bash", "-c", script, "lid-dim", root.brightnessctl, root.device].concat(args);
        root._lines = [];
        step.running = true;
    }

    property string _event: ""
    property bool _aborting: false
    property var _lines: []

    // the step's result: its first line that is not "climb" (the SplitParser below keeps those)
    function _done(text: string): void {
        const t = (String(text).split("\n")[0] || "").trim().split(" ");
        let result = t[0] || "fail";
        const value = t.length > 1 ? parseInt(t[1]) : undefined;
        if (root._aborting) {
            // the climb was ended by the lid closing again: the full value is still the one to give back
            result = "aborted";
            root._keep = root._saved;
        } else if (root._event === "engage" && result === "saved") {
            root._saved = root._keep > 0 ? root._keep : value;
            root._keep = -1;
            const mx = t.length > 2 ? parseInt(t[2]) : NaN;
            root._max = mx >= 1 ? mx : Math.max(1, root._saved);
        } else if (root._event === "release" && (result === "restored" || result === "kept")) {
            root._keep = -1;
        }
        root._ramping = false;
        root._aborting = false;
        // the hold: a panel at 0 that is lit there (or already at the user's 0) is held black until the lid opens
        if (root._event === "engage" && (result === "saved" || result === "already0") && root.veil && !root.zeroIsBlack)
            root.veil.lidHold(true);
        else if (root._event === "release" && !root._climbed && root.veil)
            root.veil.lidHold(false);
        const e = { event: root._event, result: result };
        if (value !== undefined && isFinite(value))
            e.value = value;
        root._note(e);
        if (root._event === "release" && root._climbed)
            root.climbEnded(result);
        root._climbed = false;
        if (result === "fail")
            console.log("LidDim: the " + root._event + " step failed (" + root.brightnessctl + ")");
        root._busy = false;
        root._judge();
    }

    // the step's lines: "climb" is said the moment the release starts climbing (the veil follows it), the result when it is over
    property bool _climbed: false
    Process {
        id: step
        stdout: SplitParser {
            onRead: data => {
                const parts = String(data).split("\n");
                for (let i = 0; i < parts.length; i++) {
                    const l = parts[i].trim();
                    if (l === "climb") {
                        root._climbed = true;
                        root.climbing(root.restoreMs);
                    } else if (l !== "") {
                        root._lines.push(l);
                    }
                }
            }
        }
        onExited: root._done(root._lines.join("\n"))
    }
}
