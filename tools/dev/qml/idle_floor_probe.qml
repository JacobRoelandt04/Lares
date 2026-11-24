pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import "modules/idle"
import "modules/idle/IdleAutoRules.js" as Rules
import "modules/shell/ReelItems.js" as ReelItems

// tools/dev/qml/idle_floor_probe.qml -- the idle FLOOR on the MOCK IdleService (live: false): whatever an auto cause asks for is a floor under
// the user's mode. tools/dev/idle_floor_probe.sh runs it ("IDLEF" lines, "IDLEF RESULT PASS|FAIL").
//   1 the cases the user named (hard + a soft cause; off + a normal cause: plain below the floor refused, at or above taken, Ctrl below taken)
//   2 a FUZZ of causes coming and going, user picks (plain, Ctrl) and ends, with the invariant read at EVERY change of the mode in force:
//     the mode in force is never under the user's mode (a transient there would drop the hard lock for an instant -- and the lid with it)
//   3 idle.jsonc's `auto` (a cause asks for another mode, or none) and `start` (a mode, or "last": the mode left in this Hyprland session,
//     from a file in the state dir keyed by the instance signature; another session's file is no "last")
//   4 idle.jsonc's `items` (the modes on offer): a pick of one left out is refused, a start on one goes to the nearest offered BELOW, a
//     cause asking for one gets the nearest offered ABOVE (none above: the highest), and the idle reel shows exactly the offered ones
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
        console.log("IDLEF " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    IdleService {
        id: svc
        live: false
        auto.onMs: 20
        auto.offMs: 40
    }

    // ---- the invariant, at every change of the mode in force and of the user's
    property var dips: []
    property int changes: 0
    function watch(): void {
        win.changes++;
        if (Rules.rank(svc.mode) < Rules.rank(svc.selectedMode) && win.dips.length < 5)
            win.dips.push(svc.selectedMode + " -> mode '" + svc.mode + "' (auto '" + svc.auto.mode + "')");
    }
    Connections {
        target: svc
        function onModeChanged(): void { win.watch(); }
        function onSelectedModeChanged(): void { win.watch(); }
    }
    Connections {
        target: svc.auto
        function onModeChanged(): void { win.watch(); }
    }

    property int refusals: 0
    Connections {
        target: svc
        function onRefused(mode: string, reason: string): void { win.refusals++; }
    }

    // a tiny seeded generator, so a failure replays
    property real _seed: 12345
    function rnd(): real {
        win._seed = (win._seed * 1664525 + 1013904223) % 4294967296;
        return win._seed / 4294967296;
    }
    readonly property var causes: ["llm", "timer", "update", "music", "share"]
    readonly property var modes: ["off", "soft", "normal", "hard"]

    property int at: -1
    property int ticks: 0
    property bool acted: false
    property var mark: ({})
    readonly property var seq: [
        // ---- the user's cases
        { act: () => { svc.setMode("hard"); svc.auto.llm = true; }, cond: () => svc.auto.mode === "soft",
          then: () => {
              win.check("hard + a soft cause: hard stays in force, the cause is no raise", svc.mode === "hard" && svc.selectedMode === "hard" && !svc.autoActive, svc.mode + " sel " + svc.selectedMode);
              win.check("the floor is the cause's mode (soft) while it holds", svc.floorMode === "soft", svc.floorMode);
          } },
        { act: () => { svc.auto.llm = false; }, cond: () => svc.auto.mode === "",
          then: () => win.check("... and when the cause ends the user's hard is still the user's and in force", svc.mode === "hard" && svc.selectedMode === "hard" && svc.floorMode === "", svc.mode + " sel " + svc.selectedMode) },
        { act: () => { svc.setMode("off"); svc.auto.share = true; }, cond: () => svc.auto.mode === "normal",
          then: () => {
              win.check("off + a normal cause: normal is in force, off is still the user's", svc.mode === "normal" && svc.selectedMode === "off" && svc.autoActive, svc.mode + " sel " + svc.selectedMode);
              win.mark = { refused: win.refusals };
              win.check("a plain pick of soft (under the floor) is refused", svc.setMode("soft") === false && svc.selectedMode === "off", svc.selectedMode);
              win.check("... and says why (refused: the cause)", win.refusals === win.mark.refused + 1, win.refusals + " vs " + win.mark.refused);
              win.check("a plain pick of off is refused too", svc.setMode("off") === false, "");
              win.check("a plain pick of hard (above the floor) is taken: the user's mode, the cause set nothing aside", svc.setMode("hard") === true && svc.selectedMode === "hard" && svc.mode === "hard" && svc.floorMode === "normal", svc.selectedMode + " " + svc.mode + " floor " + svc.floorMode);
              win.check("a plain pick of normal (the floor itself) is taken", svc.setMode("normal") === true && svc.selectedMode === "normal" && svc.mode === "normal", svc.selectedMode);
              win.check("a Ctrl pick of off (under the floor) is taken: the cause is set aside", svc.setMode("off", true) === true && svc.selectedMode === "off" && svc.mode === "off" && svc.auto.overridden, svc.selectedMode + " " + svc.mode);
          } },
        { act: () => { svc.auto.share = false; }, cond: () => !svc.auto.counted.share,
          then: () => win.check("the cause ends: the mode in force is the user's (off)", svc.mode === "off" && svc.selectedMode === "off" && svc.floorMode === "", svc.mode + " sel " + svc.selectedMode) },
        // ---- idle.jsonc `auto`: the chat asks for normal, the player for nothing
        { act: () => { svc.setMode("off"); svc.config = { auto: { llm: "normal", music: "off" } }; svc.auto.llm = true; svc.auto.music = true; },
          cond: () => svc.auto.counted.llm,
          then: () => win.check("auto.llm \"normal\": the chat raises the mode to normal (its table mode is soft)", svc.auto.mode === "normal" && svc.mode === "normal", svc.auto.mode) },
        { act: () => { svc.auto.llm = false; }, cond: () => !svc.auto.counted.llm,
          then: () => win.check("auto.music \"off\": the player playing raises nothing", svc.auto.mode === "" && svc.mode === "off" && svc.floorMode === "", "auto '" + svc.auto.mode + "'") },
        { act: () => { svc.config = {}; }, wait: 3,
          then: () => { win.check("no `auto`: the player is soft again (read hot)", svc.auto.mode === "soft", svc.auto.mode); svc.auto.music = false; } },
        { act: () => {}, cond: () => svc.auto.mode === "", then: () => {} },
        // ---- idle.jsonc `start`
        { act: () => {
              const a = starter.createObject(win, { config: { start: "normal" } });
              win.check("start \"normal\": the service starts in normal", a.selectedMode === "normal" && a.mode === "normal", a.selectedMode);
              a.destroy();
              const b = starter.createObject(win, { configReady: false, config: { start: "hard" } });
              win.check("... not before the config has landed", b.selectedMode === "off", b.selectedMode);
              b.configReady = true;
              win.check("... and once it has", b.selectedMode === "hard", b.selectedMode);
              b.destroy();
              const c = starter.createObject(win, { config: { start: "last" }, stateDir: win.dir });
              win.check("start \"last\" with nothing written: off", c.selectedMode === "off", c.selectedMode);
              c.setMode("normal");
              c.destroy();
          }, wait: 2,
          then: () => {
              const d = starter.createObject(win, { config: { start: "last" }, stateDir: win.dir });
              win.check("start \"last\": a restarted service takes the mode left in this session (normal)", d.selectedMode === "normal", d.selectedMode);
              d.destroy();
              stale.setText(JSON.stringify({ session: "another-login", mode: "hard" }) + "\n");
          } },
        { act: () => {}, wait: 2,
          then: () => {
              const e = starter.createObject(win, { config: { start: "last" }, stateDir: win.dir });
              win.check("start \"last\": another session's mode is not taken (off)", e.selectedMode === "off", e.selectedMode);
              e.destroy();
          } },
        // ---- idle.jsonc `items`
        { act: () => {
              win.check("items: the service offers what idle.jsonc names, off always, in the ladder's order (off soft normal)", svcA.offered.join(" ") === "off soft normal", svcA.offered.join(" "));
              win.check("items: the idle reel shows exactly those", ReelItems.idleItems(svcA.offered).map(i => i.id).join(" ") === "off soft normal", ReelItems.idleItems(svcA.offered).map(i => i.id).join(" "));
              win.check("items: a start on a mode left out goes to the nearest offered below it (hard -> normal)", svcA.selectedMode === "normal" && svcA.mode === "normal", svcA.selectedMode);
              win.check("items: ... and with none between, to off (soft -> off)", svcB.selectedMode === "off", svcB.selectedMode);
              win.mark = { refused: win.refusals };
              win.check("items: a pick of a mode left out is refused (hard)", svcA.setMode("hard") === false && svcA.selectedMode === "normal", svcA.selectedMode);
              win.check("items: a pick of an offered mode is taken (soft)", svcA.setMode("soft") === true && svcA.selectedMode === "soft", svcA.selectedMode);
              svcA.setMode("off");
              svcA.auto.llm = true;
              svcB.auto.update = true;
          }, cond: () => svcA.auto.counted.llm && svcB.auto.counted.update,
          then: () => {
              win.check("items: a cause asking for a mode left out with none above it gets the highest offered (hard -> normal)", svcA.mode === "normal" && svcA.floorMode === "normal" && svcA.autoActive, svcA.mode + " floor " + svcA.floorMode);
              win.check("items: a cause asking for a mode left out gets the nearest offered above it (soft -> normal)", svcB.mode === "normal" && svcB.floorMode === "normal", svcB.mode + " floor " + svcB.floorMode);
              svcA.auto.llm = false;
              svcB.auto.update = false;
          } },
        // ---- the fuzz
        { act: () => { win.mark = { n: 0 }; fuzz.start(); }, cond: () => win.mark.n >= 400,
          then: () => {
              fuzz.stop();
              win.check("fuzz: the mode in force was never under the user's mode, at any of " + win.changes + " changes", win.dips.length === 0, win.dips.join("; "));
              win.check("fuzz: it exercised the floor (some plain picks refused, some taken)", win.fz.refused > 10 && win.fz.taken > 10, JSON.stringify(win.fz));
          } }
    ]
    property var fz: ({ refused: 0, taken: 0 })
    // a private state dir (the runner's)
    readonly property string dir: Quickshell.env("IDLEF_DIR") || ""
    // idle.jsonc `items`: two services, each with the modes it offers from its start
    IdleService {
        id: svcA
        live: false
        auto.onMs: 20
        auto.offMs: 40
        config: ({ items: ["normal", "soft"], start: "hard", auto: { llm: "hard" } })
    }
    IdleService {
        id: svcB
        live: false
        auto.onMs: 20
        auto.offMs: 40
        config: ({ items: ["hard", "normal"], start: "soft" })
    }
    Component {
        id: starter
        IdleService {
            live: false
        }
    }
    FileView {
        id: stale
        path: win.dir !== "" ? win.dir + "/idle-mode.json" : ""
        printErrors: false
        atomicWrites: true
    }
    Timer {
        id: fuzz
        interval: 8
        repeat: true
        onTriggered: {
            win.mark.n++;
            const r = win.rnd();
            if (r < 0.4) {
                const c = win.causes[Math.floor(win.rnd() * win.causes.length)];
                svc.auto[c] = !svc.auto[c];
            } else {
                const m = win.modes[Math.floor(win.rnd() * 4)];
                const ctrl = win.rnd() < 0.2;
                const floorBefore = svc.floorMode;
                const ok = svc.setMode(m, ctrl);
                const under = floorBefore !== "" && Rules.rank(m) < Rules.rank(floorBefore) && !ctrl;
                if (ok === under)
                    win.check("a pick of " + m + (ctrl ? " with Ctrl" : "") + " under floor '" + floorBefore + "' " + (under ? "is refused" : "is taken"), false, "returned " + ok);
                if (under) win.fz.refused++; else win.fz.taken++;
            }
        }
    }

    function finish(): void {
        console.log("IDLEF RESULT " + (win.fails === 0 ? "PASS" : "FAIL") + " (" + (win.checks - win.fails) + "/" + win.checks + " checks)");
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
            if (!ready && win.ticks < 400)
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
