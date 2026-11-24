pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Wayland

import "FlourishConfig.js" as Cfg

// =============================================================================
// FlourishScheduler.qml -- THE RANDOM FLOURISHES, one screen's: now and then one of the bar's glyphs plays its flourish by itself.
//
// An OLED care (docs/oledcare.md): a glyph that moves now and then is not a still picture burnt in, and it looks alive. ONE per
// screen (ShellFrame); the glyphs take turns through the registry's one shuffle bag (FlourishRegistry.draw), so every glyph that
// may play gets its turn before any plays twice, on every screen together.
//
//   WHEN    a single-shot wait, drawn evenly from the mode's range (`settings.idleEveryS` while idle, `activeEveryS` while someone
//           works), re-armed after every turn (a play or a skip) and whenever the mode changes. IDLE is no input for `idleAfterS`
//           (60 s), read from an IdleMonitor that ignores inhibitors (a video's inhibitor keeps the screen on; it does not mean
//           someone is at the keyboard). Off (`settings.idle` / `active` false, or the OLED care off: `on`): nothing is armed.
//   WHAT    the pool is every registered flourish under `scope` (this screen's frame) that the config lets in and that is on show
//           (a reel's item only while it is in the bar's cell), drawn from the bag; it plays through its DEMO path (`demo()`), the
//           motion a hover plays. A reel's item never through its fire (ReelFlourishes.demo).
//   NOT     while `blocked` says why not (the host's word: a popup or the reel's strip out on this screen, a fullscreen window, the
//           theme's crossfade, the session locked, the bars away) or a flourish already plays here: that turn is skipped and the next
//           wait drawn -- never played the moment the reason ends, which would look like an answer to the popup closing.
//
// Logged: `LARESFLOURISH play <group.glyph> idle|active`. A probe pins the idleness (`forceIdle`) and calls `turn()` for a turn now.
// =============================================================================
QtObject {
    id: sch

    // the screen's frame: the flourishes under it are this scheduler's
    property Item scope: null
    // the session's own idleness: an IdleMonitor (off in a mock: `forceIdle` stands in)
    property bool live: false
    property int idleAfterS: 60
    // a probe pins the idleness: true / false; null follows the monitor
    property var forceIdle: null
    // FlourishConfig.parse() of the config's `oled.flourishes`
    property var settings: Cfg.parse(undefined)
    // the OLED care is on
    property bool on: true
    // why a turn now would be skipped ("" = nothing holds it)
    property string blocked: ""
    // a turn's number source (a probe pins it); 0..1
    property var random: Math.random

    readonly property bool idle: sch.forceIdle !== null && sch.forceIdle !== undefined ? sch.forceIdle === true : sch._monitor.isIdle
    readonly property string mode: sch.idle ? "idle" : "active"
    readonly property bool armed: sch.on && (sch.idle ? sch.settings.idle : sch.settings.active)
    // the wait armed now, ms (0 when nothing is)
    readonly property int nextMs: sch._next
    // what the last turn did: "play <key>" | "skip <why>" | "none" (nothing could play)
    property string lastTurn: ""
    property int plays: 0

    signal played(string key, string mode)

    // A turn now: the gates, the bag, the demo. Returns the key played ("" for none).
    function turn(): string {
        if (!sch.armed) {
            sch.lastTurn = "skip off";
            return "";
        }
        if (sch.blocked !== "") {
            sch.lastTurn = "skip " + sch.blocked;
            return "";
        }
        const mine = FlourishRegistry.entriesUnder(sch.scope);
        if (mine.some(e => e.playing)) {
            sch.lastTurn = "skip playing";
            return "";
        }
        const byKey = {};
        const pool = [];
        for (const e of mine) {
            const k = FlourishRegistry.keyOf(e);
            if (k === "" || e.shown === false || byKey[k] || !Cfg.enabled(sch.settings, e.group, e.glyph, e.decorative))
                continue;
            byKey[k] = e;
            pool.push(k);
        }
        let playable = pool.slice();
        for (let n = 0; n < pool.length; n++) {
            const k = FlourishRegistry.draw(pool, playable);
            if (k === "")
                break;
            if (byKey[k].demo()) {
                sch.plays++;
                sch.lastTurn = "play " + k;
                console.log("LARESFLOURISH play " + k + " " + sch.mode);
                sch.played(k, sch.mode);
                return k;
            }
            // it could not play just now (an archive in a run, a padlock held shut): the next one
            playable = playable.filter(x => x !== k);
        }
        sch.lastTurn = "none";
        return "";
    }

    function _arm(): void {
        sch._timer.stop();
        if (!sch.armed) {
            sch._next = 0;
            return;
        }
        sch._next = Cfg.waitMs(sch.settings, sch.idle, sch.random());
        sch._timer.interval = Math.max(1, sch._next);
        sch._timer.start();
    }

    property int _next: 0
    onArmedChanged: sch._arm()
    onModeChanged: sch._arm()
    onSettingsChanged: sch._arm()
    Component.onCompleted: sch._arm()

    property Timer _timer: Timer {
        repeat: false
        onTriggered: {
            sch.turn();
            sch._arm();
        }
    }
    property IdleMonitor _monitor: IdleMonitor {
        enabled: sch.live && (sch.forceIdle === null || sch.forceIdle === undefined)
        timeout: Math.max(1, sch.idleAfterS)
        respectInhibitors: false
    }
}
