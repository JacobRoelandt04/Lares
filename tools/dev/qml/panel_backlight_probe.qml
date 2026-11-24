pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import "modules/common/system"
import "modules/idle"
import "modules/idle/sleep"
import "modules/idle/IdleConfig.js" as Cfg
import "modules/idle/SoftRules.js" as SoftRules
import "modules/osd/data"
import "modules/osd/data/sources"

// tools/dev/qml/panel_backlight_probe.qml -- the panel's backlight is ONE answer (PanelBacklight) and every consumer takes it (round 12).
// tools/dev/panel_backlight_probe.sh runs it once per fixture tree (LARES_SYSFS_ROOT: Hybrid, Hybrid with a stray nvidia_0, dGPU-only,
// nothing, and the eDP driver unreadable) with a stub brightnessctl over the same tree (PB_SYS) that FAILS any call without -d.
//   EXPECT_DEV / EXPECT_MAX / EXPECT_ZERO   what PanelBacklight must answer for this tree ("" = not ready)
// Consumers, for a tree that has a device: the OSD (its service's backlight source takes the device; a key writes THAT device through
// brightnessctl -d and, where 0 is not black, never writes 0; the ladder is right at max 100), SoftRules' argv (names the device in
// every brightnessctl call), LidDim + SleepFade (the lid closed writes 0 on that device and, where 0 is not black, the veil holds the
// panel black until the lid opens; the climb gives the full value back).
// Prints `PB ok|FAIL <check>` and `PB RESULT PASS|FAIL (<n>/<n> checks)`.
Window {
    id: win
    visible: true
    width: 80
    height: 40

    readonly property string sys: Quickshell.env("PB_SYS") || ""
    readonly property string wantDev: Quickshell.env("EXPECT_DEV") || ""
    readonly property int wantMax: parseInt(Quickshell.env("EXPECT_MAX") || "0")
    readonly property bool wantZero: (Quickshell.env("EXPECT_ZERO") || "1") === "1"
    readonly property string stubs: Quickshell.env("STUBS") || ""
    readonly property bool hasDev: win.wantDev !== ""

    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        win.checks++;
        if (!ok)
            win.fails++;
        console.log("PB " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    // ---- the fake panel, read through the stub's own files ---------------------------------------------------------------------
    FileView {
        id: devFile
        path: win.sys + "/class/backlight/" + win.wantDev + "/brightness"
        blockAllReads: true
        printErrors: false
    }
    FileView {
        id: callsFile
        path: win.sys + "/calls"
        blockAllReads: true
        printErrors: false
    }
    function raw(): int {
        if (!win.hasDev)
            return -1;
        devFile.reload();
        return parseInt(String(devFile.text()).trim());
    }
    function calls(): string {
        callsFile.reload();
        try {
            return String(callsFile.text());
        } catch (e) {
            return "";
        }
    }
    Process {
        id: writer
        stdinEnabled: false
    }
    function setRaw(v: int): void {
        writer.command = ["bash", "-c", "echo " + v + " > \"$1\"", "w", win.sys + "/class/backlight/" + win.wantDev + "/brightness"];
        writer.running = true;
    }

    // ---- the consumers ------------------------------------------------------------------------------------------------------
    // the OSD's service, not live (nothing runs): the device its backlight source was handed
    OsdService {
        id: osd
        live: false
        registerOnBus: false
    }
    // the source as the service builds it, live, on the fixture tree (the stub brightnessctl is first on PATH)
    BacklightSource {
        id: key
        live: true
        sysfsRoot: win.sys + "/class/backlight"
        device: PanelBacklight.device
        zeroOpens: PanelBacklight.zeroBlackOf(key.device)
    }

    readonly property var settings: Cfg.parse({ stateFile: win.sys + "/state", script: "/nonexistent", awayAfter: 0 }, "/nonexistent")
    SoftIdle {
        id: soft
        live: false
        settings: win.settings
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
        captureWaitMs: 150
        capCommand: ["echo", "t 1500000"]
        inhibitCommand: ["sh", "-c", "echo held; exec sleep infinity"]
        campaignFile: win.sys + "/no-campaign.json"
        recordFile: win.sys + "/sleep-fade.json"
    }
    LidDim {
        id: lid
        live: true
        active: true
        restoreMs: 300
        veil: fade
        onClimbEnded: result => fade.lidEnd(result)
        onClimbing: ms => fade.lidWake(ms)
    }

    // ---- the sequence ------------------------------------------------------------------------------------------------------
    property int at: -1
    property int ticks: 0
    property bool acted: false
    property int mark: 0

    function pressDown(n: int): void {
        // one press and its repeats: a held key (the zero gate is decided at the press, from far above the floor)
        key.adjust(-1, false, "press");
        for (let i = 0; i < n; i++)
            key.adjust(-1, false, "repeat");
        key.adjust(-1, false, "release");
    }

    readonly property var seq: [
        { act: () => {}, cond: () => PanelBacklight.ready || win.ticks > 100 || (!win.hasDev && win.ticks > 30),
          then: () => {
              win.check("PanelBacklight answers " + (win.hasDev ? win.wantDev : "nothing") + " [" + PanelBacklight.device + " max " + PanelBacklight.max + " driver " + PanelBacklight.driver + "]",
                        PanelBacklight.device === win.wantDev && PanelBacklight.ready === win.hasDev && (!win.hasDev || PanelBacklight.max === win.wantMax), PanelBacklight.why);
              if (win.hasDev)
                  win.check("zeroIsBlack is " + win.wantZero, PanelBacklight.zeroIsBlack === win.wantZero, String(PanelBacklight.zeroIsBlack));
          } },
        { act: () => {}, wait: 3, then: () => {
              win.check("the OSD service's backlight source takes the device", osd.sources.backlight.device === win.wantDev, osd.sources.backlight.device);
              win.check("the OSD source's zero gate follows zeroIsBlack", !win.hasDev || osd.sources.backlight.zeroOpens === win.wantZero, String(osd.sources.backlight.zeroOpens));
              const rd = SoftRules.argvOf("dim", soft._rs);
              const st = SoftRules.setArgv(soft._rs, 100, 50);
              win.check("SoftRules' read step names the device in every brightnessctl call (-c backlight -d \"$3\", argv carries " + win.wantDev + ")",
                        soft.device === win.wantDev && rd[rd.length - 1] === win.wantDev && rd[2].indexOf('-c backlight -d "$3" g') >= 0 && rd[2].indexOf('-c backlight -d "$3" m') >= 0, rd[2]);
              win.check("SoftRules' set step names the device (-c backlight -d \"$5\", argv carries " + win.wantDev + ")",
                        st[st.length - 1] === win.wantDev && st[2].indexOf('-c backlight -d "$5" set') >= 0, st[2]);
              if (!win.hasDev)
                  win.check("no device: every consumer is as it is with none (the keys do nothing, soft's argv names none)", key.adjust(-1, false, "press") === false && soft.device === "", "");
          } },
        // ----- the OSD's keys: from full, one press down is one rung (5 points at max 100 is 95), written to THIS device
        { act: () => { if (win.hasDev) { win.setRaw(win.wantMax); } }, wait: 6 },
        { act: () => { if (win.hasDev) { key.adjust(-1, false, "press"); key.adjust(-1, false, "release"); } }, wait: 14,
          then: () => {
              if (!win.hasDev) return;
              win.check("an OSD key wrote the panel's device (" + win.wantDev + ") through brightnessctl -d, one rung down", win.raw() < win.wantMax && win.calls().indexOf("-d " + win.wantDev + " set") >= 0, win.raw() + " calls " + win.calls().slice(-120));
              if (win.wantMax === 100)
                  win.check("the ladder at max 100: one press from 100 lands on a rung below it (floorRaw 1 = 1 %)", win.raw() >= 80 && win.raw() < 100, String(win.raw()));
          } },
        { act: () => { if (win.hasDev) win.pressDown(60); }, wait: 30,
          then: () => {
              if (!win.hasDev) return;
              win.check("a held key stops at the floor (raw 1), never lower", win.raw() === 1, String(win.raw()));
          } },
        { act: () => { if (win.hasDev) { key.adjust(-1, false, "press"); key.adjust(-1, false, "release"); } }, wait: 14,
          then: () => {
              if (!win.hasDev) return;
              if (win.wantZero)
                  win.check("a FRESH press at the floor goes to true 0 where 0 is black", win.raw() === 0, String(win.raw()));
              else
                  win.check("where 0 is NOT black a fresh press at the floor never writes 0", win.raw() === 1, String(win.raw()));
              win.check("no brightnessctl call anywhere was bare", win.calls().indexOf("BARE") < 0, win.calls().slice(-200));
          } },
        // ----- the lid: closed in hard idle puts the panel at 0 on THIS device; where 0 is lit the veil holds the panel black
        { act: () => { if (win.hasDev) win.setRaw(win.wantMax === 100 ? 60 : 300); }, wait: 6 },
        { act: () => { if (win.hasDev) { win.mark = lid.log.length; lid.lidClosed = true; } }, cond: () => !win.hasDev || lid.log.length > win.mark,
          then: () => {
              if (!win.hasDev) return;
              win.check("LidDim engaged on " + win.wantDev + ": the panel reads 0", lid.log[lid.log.length - 1].result === "saved" && win.raw() === 0, JSON.stringify(lid.log[lid.log.length - 1]) + " raw " + win.raw());
              if (win.wantZero)
                  win.check("0 is black here: no veil hold is asked", fade.phase === "rest", fade.phase);
              else
                  win.check("0 is NOT black here: the sleep veil HOLDS the panel's output black (phase lidhold, progress 1, the veil dims the picture itself)",
                            fade.phase === "lidhold" && fade.progress === 1 && fade.selfDims("eDP-1") && fade.shown, fade.phase + " p " + fade.progress);
          } },
        { act: () => {}, wait: 12,
          then: () => { if (win.hasDev && !win.wantZero) win.check("the hold stands while the lid is shut", fade.phase === "lidhold" && win.raw() === 0, fade.phase + " raw " + win.raw()); } },
        { act: () => { if (win.hasDev) { win.mark = lid.log.length; lid.lidClosed = false; } }, cond: () => !win.hasDev || (lid.log.length > win.mark && fade.phase === "rest"),
          then: () => {
              if (!win.hasDev) return;
              const full = win.wantMax === 100 ? 60 : 300;
              win.check("the lid opening climbs back to the full value on " + win.wantDev, lid.log[lid.log.length - 1].result === "restored" && win.raw() === full, JSON.stringify(lid.log[lid.log.length - 1]) + " raw " + win.raw());
              win.check("... and the veil is gone (rest)", fade.phase === "rest", fade.phase);
              win.check("no brightnessctl call anywhere was bare", win.calls().indexOf("BARE") < 0, win.calls().slice(-200));
          } }
    ]

    function finish(): void {
        console.log("PB RESULT " + (win.fails === 0 ? "PASS" : "FAIL") + " (" + (win.checks - win.fails) + "/" + win.checks + " checks)");
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
                win.check("step " + win.at + " reached its condition", false, "timed out (lid phase " + fade.phase + ", raw " + win.raw() + ")");
            if (s.then)
                s.then();
            win.at++;
            win.acted = false;
            if (win.at >= win.seq.length)
                win.finish();
        }
    }
}
