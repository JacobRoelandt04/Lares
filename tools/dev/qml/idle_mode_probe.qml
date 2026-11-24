pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell
import "modules/idle"
import "modules/common/system"

// tools/dev/qml/idle_mode_probe.qml -- what each idle mode does to the panel's dimming, on the MOCK IdleService (live: false: nothing is held,
// no program runs; the soft rules run on the same code with their steps recorded in `soft.log`, `setIdle()` standing for the compositor's idle
// monitors, `soft.content.simulate()` for a video, a fake FocusedScreen for the focus). tools/dev/idle_mode_probe.sh runs it. Prints IDLEM lines
// and "IDLEM RESULT PASS|FAIL".
//
// The rule under test: off and soft dim by the SAME engine (SoftIdle: 0.7 at dimAfter, 0.5 at deepAfter, ContentHold pausing it, the away rule, the
// resume on activity); off holds nothing (no Wayland inhibitor, no hard lock), so hypridle goes on to suspend; normal and hard dim nothing.
// IDLEM_MACHINE=desktop (the runner's second run, a /sys with no laptop panel): soft needs no brightness script there, and the EXTERNAL displays
// are dimmed (DdcDim is active and takes the engine's idle level); on the laptop they are not.
Window {
    id: win
    visible: true
    width: 80
    height: 40

    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        win.checks++;
        if (!ok)
            win.fails++;
        console.log("IDLEM " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    // a focus source that can be moved: the laptop panel and an external output
    QtObject {
        id: fakeFocus
        property string name: "eDP-1"
        property var monitors: [{ name: "eDP-1" }, { name: "DP-1" }]
    }

    IdleService {
        id: svc
        live: false
        focusSource: fakeFocus
        config: ({ awayAfter: 1 })
        // the rules under each mode, not the auto layer (a simulated video would otherwise put normal in force after 3 s:
        // tools/dev/idle_auto_probe.sh is that layer's)
        auto.onMs: 3600000
    }

    function lastStep(): string {
        const l = svc.soft.log;
        for (let i = l.length - 1; i >= 0; i--)
            if (l[i].event === "step")
                return l[i].arg;
        return "";
    }
    function steps(): int {
        let n = 0;
        for (const e of svc.soft.log)
            if (e.event === "step")
                n++;
        return n;
    }

    // ---- the sequence: each step acts, then waits for its condition (never a time), then judges ------------------------------------
    property int at: -1
    property int ticks: 0
    property bool acted: false
    property int mark: 0
    readonly property var seq: Quickshell.env("IDLEM_MACHINE") === "desktop" ? win.desktopSeq : win.laptopSeq
    readonly property var desktopSeq: [
        { act: () => { svc.softReason = "the brightness script is not there"; }, cond: () => PanelBacklight.scanned,
          then: () => win.check("a desktop: soft needs no script (it has no panel to dim)", svc.panelless && svc.softAvailable && svc.setMode("soft") && svc.mode === "soft", svc.panelless + " " + svc.softAvailable + " " + svc.mode) },
        { act: () => { svc.setMode("off"); svc.soft.setIdle(true, false); }, cond: () => svc.ddc.want === 1,
          then: () => win.check("a desktop: the external displays are dimmed at dimAfter", svc.ddc.active && svc.ddc.want === 1, svc.ddc.active + " " + svc.ddc.want) },
        { act: () => { svc.soft.setIdle(true, true); }, cond: () => svc.ddc.want === 2, then: () => win.check("a desktop: deep at deepAfter", svc.ddc.want === 2, svc.ddc.want) },
        { act: () => { svc.soft.content.simulate(true); }, cond: () => svc.ddc.want === 0, then: () => win.check("a desktop: a video gives it back", svc.ddc.want === 0, svc.ddc.want) },
        { act: () => { svc.soft.content.simulate(false); }, cond: () => svc.ddc.want === 2, then: () => win.check("a desktop: the video over, deep again", svc.ddc.want === 2, svc.ddc.want) },
        { act: () => { svc.setMode("normal"); }, cond: () => svc.ddc.want === 0, then: () => win.check("a desktop: normal dims nothing", svc.ddc.want === 0 && !svc.ddc.active, svc.ddc.want) },
        { act: () => { svc.setMode("off"); svc.config = { ddcDim: false }; }, wait: 5, then: () => win.check("a desktop: ddcDim false dims nothing", svc.ddc.want === 0 && !svc.ddc.active, svc.ddc.want) }
    ]
    readonly property var laptopSeq: [
        { act: () => {}, cond: () => PanelBacklight.scanned,
          then: () => win.check("a laptop: the external displays are not dimmed (no key)", !svc.ddc.active && !svc.panelless, svc.ddc.active + " " + svc.panelless) },
        { act: () => { svc.config = { awayAfter: 1, ddcDim: true }; }, wait: 3, then: () => win.check("a laptop: ddcDim true dims them too", svc.ddc.active, svc.ddc.active) },
        { act: () => { svc.config = { awayAfter: 1 }; }, wait: 3 },
        // ----- off and soft: the same dimming
        ...win.dimmingCase("off"),
        ...win.dimmingCase("soft"),
        // ----- the mode leaves while dimmed: the panel is given back
        { act: () => { svc.setMode("off"); svc.soft.setIdle(true, true); }, cond: () => svc.soft.level === 2 },
        { act: () => { svc.setMode("normal"); }, cond: () => svc.soft.level === 0,
          then: () => win.check("off -> normal while deep: the panel is given back (--resume), nothing holds it dim", win.lastStep() === "--resume" && svc.soft.level === 0, win.lastStep()) },
        // ----- normal and hard dim nothing, with the idleness at its deepest
        ...win.stillCase("normal"),
        ...win.stillCase("hard"),
        // ----- off where the dimming cannot run (no brightness script): nothing dims, nothing breaks
        { act: () => { svc.setMode("off"); svc.softReason = "the brightness script is not there"; win.mark = win.steps(); svc.soft.setIdle(true, true); }, wait: 10,
          then: () => win.check("off with soft unavailable: no dimming (the engine is off)", !svc.dims && !svc.soft.active && win.steps() === win.mark && svc.soft.level === 0, win.steps() + " " + win.mark) },
        { act: () => { svc.softReason = ""; svc.soft.setIdle(false, false); } , wait: 3 }
    ]

    // off | soft: the whole ladder
    function dimmingCase(m: string): var {
        const tag = m + ": ";
        return [
            { act: () => { svc.setMode(m); svc.soft.setIdle(false, false); }, wait: 3,
              then: () => {
                  win.check(tag + "the engine is on (dims, soft.active)", svc.dims && svc.soft.active, svc.dims + " " + svc.soft.active);
                  win.check(tag + (m === "off" ? "off holds NO Wayland inhibitor (normalHold false: hypridle may suspend) and no hard lock" : "soft holds the Wayland inhibitor (normalHold) and no hard lock"),
                            svc.normalHold === (m === "soft") && !svc.held && svc.log.length === 0, svc.normalHold + " " + svc.held + " " + svc.log.length);
              } },
            { act: () => { svc.soft.setIdle(true, false); }, cond: () => svc.soft.level === 1,
              then: () => win.check(tag + "after dimAfter the panel is dimmed (the `dim` step)", win.lastStep() === "dim", win.lastStep()) },
            { act: () => { svc.soft.setIdle(true, true); }, cond: () => svc.soft.level === 2,
              then: () => win.check(tag + "after deepAfter it is deep (the `deep` step), never dark: no --idle, no --pre-idle in any step", win.lastStep() === "deep" && win.noDark(), win.lastStep()) },
            { act: () => { svc.soft.content.simulate(true); }, cond: () => svc.soft.level === 0,
              then: () => win.check(tag + "a video (ContentHold) pauses the dimming: the panel is given back", win.lastStep() === "--resume", win.lastStep()) },
            { act: () => { svc.soft.content.simulate(false); }, cond: () => svc.soft.level === 2,
              then: () => win.check(tag + "... and the dimming comes back when the video ends (the idleness is still deep)", true, "") },
            { act: () => { svc.soft.setIdle(false, false); }, cond: () => svc.soft.level === 0,
              then: () => win.check(tag + "the first input gives the brightness back (--resume)", win.lastStep() === "--resume", win.lastStep()) },
            { act: () => { fakeFocus.name = "DP-1"; }, cond: () => svc.soft.awayDimmed && svc.soft.level === 1,
              then: () => win.check(tag + "the focus on an external output for awayAfter dims the panel (the attention rule)", svc.soft.away, "") },
            { act: () => { fakeFocus.name = "eDP-1"; }, cond: () => svc.soft.level === 0 }
        ];
    }
    // normal | hard: the idleness at its deepest changes nothing
    function stillCase(m: string): var {
        return [
            { act: () => { svc.setMode(m); win.mark = win.steps(); svc.soft.setIdle(true, true); }, wait: 10,
              then: () => win.check(m + ": nothing dims with the idleness at its deepest (no step, level 0, engine off)", !svc.dims && !svc.soft.active && win.steps() === win.mark && svc.soft.level === 0, win.steps() + " " + win.mark + " " + svc.soft.level) },
            { act: () => { svc.soft.setIdle(false, false); }, wait: 3,
              then: () => win.check(m + ": " + (m === "normal" ? "the Wayland inhibitor is held (normalHold) and no hard lock" : "the hard lock is held and no Wayland inhibitor"),
                                    m === "normal" ? (svc.normalHold && !svc.held) : (svc.held && !svc.normalHold), svc.normalHold + " " + svc.held) }
        ];
    }
    function noDark(): bool {
        for (const e of svc.soft.log)
            if (e.event === "step" && (e.arg === "--idle" || e.arg === "--pre-idle"))
                return false;
        return true;
    }

    function finish(): void {
        console.log("IDLEM RESULT " + (win.fails === 0 ? "PASS" : "FAIL") + " (" + (win.checks - win.fails) + "/" + win.checks + " checks)");
        Qt.quit();
    }

    Timer {
        interval: 20
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
            if (!ready && win.ticks < 150)
                return;
            if (!ready)
                win.check("step " + win.at + " reached its condition", false, "timed out");
            if (s.then)
                s.then();
            win.at++;
            win.acted = false;
            if (win.at >= win.seq.length)
                win.finish();
        }
    }
}
