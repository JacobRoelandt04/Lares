pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import "modules/common/system"
import "modules/idle"
import "modules/idle/sleep"
import "modules/idle/IdleConfig.js" as Cfg
import "modules/idle/SoftRules.js" as Rules

// tools/dev/qml/sleep_dim_probe.qml -- an idle SUSPEND after SoftIdle's dimming gives back the brightness the panel had BEFORE the dimming
// (feedback/general.md "Screen brightness after resume from idle suspend"). tools/dev/sleep_dim_probe.sh runs it in a sandbox copy with
// stubs: a `brightnessctl` over a fake backlight directory (FAKE: brightness / max_brightness) and a brightness script whose --resume is
// the user's (the state file read, set, removed). Nothing of the machine is read or written; the delay inhibitor is `echo held; sleep`.
//
// The pieces are the REAL ones, live, in the shell's own wiring (IdleService hands SleepFade's settings to both and listens to it):
// SoftIdle (its dim and deep steps and its --resume run the stub programs; `setIdle()` stands for the compositor's idle monitors) and
// SleepFade (PrepareForSleep is a fake watcher's signal; no veil windows). The panel is read from the FAKE after every step.
//
//   dim -> deep -> sleep fall -> resume climb  with the monitors silent, and with the activity heard BEFORE the climb (the key that woke the
//   machine), and AFTER it; a brightness key during the climb; a plain suspend (no dimming) and a dimmed panel the user set by hand;
//   and no suspend at all (the dimming gives the brightness back at the first input, as it always did).
// Prints `SDIM ok|FAIL <check>` and `SDIM RESULT PASS|FAIL (<n>/<n> checks)`.
Window {
    id: win
    visible: true
    width: 80
    height: 40

    readonly property string fake: Quickshell.env("FAKE") || ""
    readonly property string stateFile: Quickshell.env("STATE") || ""
    readonly property string stubs: Quickshell.env("STUBS") || ""
    readonly property int full: 400

    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        win.checks++;
        if (!ok)
            win.fails++;
        console.log("SDIM " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    // ---- the fake panel and the state file ------------------------------------------------------------------------------------
    FileView {
        id: panelFile
        path: win.fake + "/brightness"
        blockAllReads: true
        printErrors: false
    }
    FileView {
        id: stateView
        path: win.stateFile
        blockAllReads: true
        printErrors: false
    }
    function panel(): int {
        panelFile.reload();
        return parseInt(String(panelFile.text()).trim());
    }
    // the state file's number; -1 when there is none
    function saved(): int {
        stateView.reload();
        try {
            const t = String(stateView.text()).trim();
            return /^[0-9]+$/.test(t) ? parseInt(t) : -1;
        } catch (e) {
            return -1;
        }
    }
    Process {
        id: writer
        stdinEnabled: false
    }
    // the user's hand on the brightness keys, or the test's reset: the program writes the file (a Process, so the sandbox's HOME stays out of it)
    function setPanel(v: int): void {
        writer.command = ["bash", "-c", "echo " + v + " > \"$1\"", "w", win.fake + "/brightness"];
        writer.running = true;
    }
    FileView {
        id: devicesFile
        path: win.fake + "/devices"
        blockAllReads: true
        printErrors: false
    }
    // the device of every call the stub saw ("dev=nvidia_0", "dev=BARE")
    function devices(): var {
        devicesFile.reload();
        return String(devicesFile.text()).split("\n").filter(l => l !== "").map(l => l.split(" ")[0]);
    }
    function dropState(): void {
        writer.command = ["rm", "-f", win.stateFile];
        writer.running = true;
    }

    // ---- the pieces ---------------------------------------------------------------------------------------------------------
    readonly property var settings: Cfg.parse({
        stateFile: win.stateFile,
        script: win.stubs + "/brightness.sh",
        brightnessctl: win.stubs + "/brightnessctl",
        sleepFadeTime: 0.6,
        awayAfter: 0
    }, "/nonexistent")

    SoftIdle {
        id: soft
        live: true
        active: true
        settings: win.settings
    }
    // the content question is not the subject (no dbus-monitor, no hyprctl): nothing holds the screen
    Binding {
        target: soft.content
        property: "live"
        value: false
    }

    // the shell's own wiring, mock (nothing runs): the sleep fade's give-back reaches the rules (IdleService)
    IdleService {
        id: svc
        live: false
    }

    QtObject {
        id: fakeWatcher
        signal aboutToSleep
        signal resumed
    }
    SleepFade {
        id: fade
        live: true
        windows: false
        settings: win.settings
        watcher: fakeWatcher
        marginMs: 100
        capCommand: ["echo", "t 1500000"]
        inhibitCommand: ["sh", "-c", "echo held; exec sleep infinity"]
        campaignFile: win.stubs + "/no-campaign.json"
        recordFile: win.stubs + "/sleep-fade.json"
        onGaveBack: soft.panelGivenBack()
    }
    function wiredToSoft(): bool {
        const n = svc.soft.log.length;
        svc.sleep.gaveBack();
        const l = svc.soft.log;
        return l.length > n && l[l.length - 1].event === "given";
    }

    // ---- the sequence ------------------------------------------------------------------------------------------------------
    property int at: -1
    property int ticks: 0
    property bool acted: false
    property int mark: 0
    property int dimmedPanel: -1

    // the monitors report dimAfter, deepAfter; the panel is deep (a quarter of full on the default curve)
    function dimDeep(): var {
        return [
            { act: () => { win.setPanel(win.full); win.dropState(); soft.setIdle(false, false); }, wait: 4 },
            { act: () => { soft.setIdle(true, false); }, cond: () => soft.level === 1 },
            { act: () => { soft.setIdle(true, true); }, cond: () => soft.level === 2,
              then: () => {
                  win.dimmedPanel = win.panel();
                  win.check("[setup] deep: the panel is dimmed and the full value is saved", win.dimmedPanel > 0 && win.dimmedPanel < win.full / 2 && win.saved() === win.full, win.dimmedPanel + " saved " + win.saved());
              } }
        ];
    }
    function sleep(): var {
        return [
            { act: () => { fakeWatcher.aboutToSleep(); }, cond: () => fade.phase === "asleep",
              then: () => win.check("[setup] the fall: the panel is dark when the machine sleeps", win.panel() === 0, String(win.panel())) }
        ];
    }
    function wake(): var {
        return [
            { act: () => { fakeWatcher.resumed(); }, cond: () => fade.phase === "rest" }
        ];
    }
    // after a give-back: the panel, the rules' level and the state file agree
    function agree(tag: string, want: int): void {
        win.check(tag + "the climb lands on " + want + " (what the panel was before the dimming)", win.panel() === want, String(win.panel()));
        win.check(tag + "SoftIdle agrees: level 0, no step pending, no state file left", soft.level === 0 && win.saved() === -1, "level " + soft.level + " saved " + win.saved());
    }
    // and the next idleness dims from that value, saving it (not the dimmed one)
    function nextDim(tag: string, want: int): var {
        return [
            { act: () => { win.mark = soft.log.length; soft.setIdle(true, false); }, cond: () => soft.level === 1,
              then: () => win.check(tag + "the next dim saves " + want + " and dims from it (no second step, no stale level)", win.saved() === want && win.panel() < want && win.panel() > 0, "saved " + win.saved() + " panel " + win.panel()) },
            { act: () => { soft.setIdle(false, false); }, cond: () => soft.level === 0,
              then: () => win.check(tag + "... and the first input gives " + want + " back", win.panel() === want && win.saved() === -1, win.panel() + " saved " + win.saved()) }
        ];
    }

    readonly property var seq: [
        // ----- the machine is in dGPU-only mode (a fixture tree): the panel's device is nvidia_0, named in every call below
        { act: () => {}, cond: () => PanelBacklight.ready && soft.device === "nvidia_0" && fade.device === "nvidia_0",
          then: () => {
              win.check("PanelBacklight names nvidia_0 for SoftIdle and the sleep fade (dGPU-only tree)", PanelBacklight.device === "nvidia_0" && soft.device === "nvidia_0" && fade.device === "nvidia_0", PanelBacklight.device + " / " + soft.device + " / " + fade.device)
              const rd = Rules.argvOf("dim", soft._rs);
              win.check("SoftRules names the panel: its read step carries -d nvidia_0", rd[rd.length - 1] === "nvidia_0" && rd[2].indexOf('-c backlight -d "$3" g') >= 0, rd[2]);
              // a rule that names no device would only time out the steps below, minutes later: end the run here
              if (win.fails > 0) { win.finish(); win.at = win.seq.length; }
          } },
        // ----- THE USER'S CASE: dim, deep, hypridle's suspend, nobody touches anything before the climb
        ...win.dimDeep(),
        ...win.sleep(),
        ...win.wake(),
        { act: () => {}, wait: 8, then: () => win.agree("silent monitors: ", win.full) },
        ...win.nextDim("silent monitors: ", win.full),

        // ----- the key that woke the machine reaches SoftIdle first: its --resume gives the full value while the panel is dark
        ...win.dimDeep(),
        ...win.sleep(),
        { act: () => { soft.setIdle(false, false); }, cond: () => soft.level === 0 && win.panel() === win.full },
        ...win.wake(),
        { act: () => {}, wait: 8, then: () => win.agree("activity before the climb: ", win.full) },

        // ----- the activity is heard after the climb
        ...win.dimDeep(),
        ...win.sleep(),
        ...win.wake(),
        { act: () => { soft.setIdle(false, false); }, wait: 10, then: () => win.agree("activity after the climb: ", win.full) },

        // ----- a brightness key during the climb wins, and SoftIdle lets go of what it saved
        ...win.dimDeep(),
        ...win.sleep(),
        { act: () => { fakeWatcher.resumed(); }, cond: () => fade.phase === "rising" && win.panel() > 0 },
        { act: () => { win.setPanel(250); }, cond: () => fade.phase === "rest",
          then: () => {
              win.check("a key during the climb wins: the panel stays where the key put it", win.panel() === 250, String(win.panel()));
              win.check("... and SoftIdle holds no saved value for it (level 0, no state file)", soft.level === 0 && win.saved() === -1, "level " + soft.level + " saved " + win.saved());
          } },

        // ----- a plain suspend: nothing was dimmed, nothing is saved: the panel's own value comes back
        { act: () => { win.setPanel(330); win.dropState(); soft.setIdle(false, false); }, wait: 4 },
        ...win.sleep(),
        ...win.wake(),
        { act: () => {}, wait: 8, then: () => win.agree("no dimming first: ", 330) },

        // ----- no suspend at all: the dimming gives the brightness back at the first input (as it always did)
        ...win.dimDeep(),
        { act: () => { soft.setIdle(false, false); }, cond: () => soft.level === 0,
          then: () => win.check("no suspend: the first input gives the full value back", win.panel() === win.full && win.saved() === -1, win.panel() + " saved " + win.saved()) },

        // ----- the shell's wiring: IdleService hands the sleep fade's give-back to SoftIdle
        { act: () => {}, wait: 2, then: () => {
              const seen = win.devices();
              win.check("every brightnessctl call of SoftIdle and the sleep fade named nvidia_0 (none bare, none another)", seen.length > 0 && seen.every(l => l === "dev=nvidia_0"), JSON.stringify(seen.filter(l => l !== "dev=nvidia_0")));
          } },
        { act: () => {}, wait: 2, then: () => win.check("IdleService wires the sleep fade's give-back to SoftIdle", win.wiredToSoft(), "no `given` in the rules' log") }
    ]

    function finish(): void {
        console.log("SDIM RESULT " + (win.fails === 0 ? "PASS" : "FAIL") + " (" + (win.checks - win.fails) + "/" + win.checks + " checks)");
        Qt.quit();
    }

    Timer {
        interval: 25
        repeat: true
        running: true
        onTriggered: {
            if (win.at >= win.seq.length) return;
            if (win.at < 0) { win.at = 0; win.acted = false; }
            const s = win.seq[win.at];
            if (!win.acted) {
                win.acted = true;
                win.ticks = 0;
                s.act();
                return;
            }
            win.ticks++;
            const ready = s.cond ? s.cond() : win.ticks >= (s.wait || 1);
            if (!ready && win.ticks < 400)
                return;
            if (!ready)
                win.check("step " + win.at + " reached its condition", false, "timed out (phase " + fade.phase + ", level " + soft.level + ", panel " + win.panel() + ")");
            if (s.then)
                s.then();
            win.at++;
            win.acted = false;
            if (win.at >= win.seq.length)
                win.finish();
        }
    }
}
