pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/components"
import "modules/common/flourish"
import "modules/shell"

// =============================================================================
// shell_options_probe.qml -- the hand-edited config files reach the shell: the REAL ShellFrame over mock services whose config/ holds the files
// tools/dev/shell_options_probe.sh wrote. One check per key that decides what the frame builds or how it answers; a key with rules of its own has
// its own probe (bar_clicks_probe, config_watch_probe, shell_layout_cases ...). Prints `SOPT ok|FAIL <check>` and `SOPT RESULT PASS|FAIL`.
// =============================================================================
ShellRoot {
    id: root

    property int checks: 0
    property int fails: 0
    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("SOPT " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }
    function same(name: string, got: var, want: var): void {
        root.check(name, JSON.stringify(got) === JSON.stringify(want), JSON.stringify(got) + " want " + JSON.stringify(want));
    }

    FloatingWindow {
        id: win
        implicitWidth: 2880
        implicitHeight: 1000
        visible: true
        color: "#808080"
        ShellServices {
            id: mockServices
            mode: "mock"
            windowless: true
        }
        ScaleRoot {
            factor: 1
            hostWidth: win.width
            hostHeight: win.height
            Loader {
                id: frameLoader
                anchors.fill: parent
                active: mockServices.ready
                sourceComponent: Component {
                    ShellFrame {
                        services: mockServices
                        screenName: "eDP-1"
                        renderScale: 1
                        frameScale: 1
                    }
                }
            }
        }
    }
    readonly property var frame: frameLoader.item
    readonly property var engine: root.frame ? root.frame.engine : null
    readonly property var s: mockServices

    // ---- the script: each step acts, then waits for its condition (polled), then judges ----
    property var steps: []
    property int at: 0
    property real since: 0
    property bool acted: false
    function step(name: string, act: var, ready: var, judge: var): void {
        root.steps.push({ name: name, act: act, ready: ready, judge: judge });
    }
    function popup(id: string): bool {
        return root.engine.popupOpen && root.engine.popupOwnerId === id && root.engine.thePopup.phase === "open";
    }
    function shut(): bool {
        return !root.engine.popupOpen && root.engine.thePopup.phase === "closed";
    }
    Timer {
        interval: 30
        repeat: true
        running: mockServices.settled
        onTriggered: {
            if (root.at >= root.steps.length) {
                console.log("SOPT RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks)");
                running = false;
                Qt.quit();
                return;
            }
            const st = root.steps[root.at];
            if (!root.acted) {
                root.acted = true;
                root.since = Date.now();
                st.act();
                return;
            }
            const ok = st.ready();
            if (!ok && Date.now() - root.since < 20000)
                return;
            if (!ok)
                root.check(st.name + ": it comes to that", false, "never; popup " + root.engine.popupOwnerId + " " + root.engine.thePopup.phase);
            else
                st.judge();
            root.acted = false;
            root.at++;
        }
    }

    Component.onCompleted: {
        const now = () => true;
        root.step("the files as the frame was built", () => {}, now, () => {
            const reel = root.frame.buttons.power;
            root.same("power.jsonc items: those, in that order, and Lock", reel.items.map(i => i.id), ["reboot", "sleep", "lock"]);
            root.same("power.jsonc rest: the ring stands on it", reel.reel.selectedItem.id, "sleep");
            root.check("power.jsonc leftClickFires", reel.leftClickActivates === true, "");
            root.same("power.jsonc commands", root.s.reelActions.commandOf("sleep"), ["systemctl", "hibernate"]);
            root.check("power.jsonc waitForFlourish", root.s.reelActions.waitForFlourish === false, "");
            root.same("workspaces.jsonc shown: their dots", root.frame.workspaces.workspaceList.map(w => w.id), [1, 2, 5]);
            root.check("shell.jsonc flourishes: the registry's switches", FlourishRegistry.hoverPlays === false && FlourishRegistry.keyPlays === false, "");
            root.same("shell.jsonc recorders", root.s.shareWatch.recorders, ["gpu-screen-recorder"]);
            root.same("idle.jsonc start, autoTell", [root.s.idle.selectedMode, root.frame.idleFollow.cinematic], ["normal", false]);
            root.same("idle.jsonc download, packages: the waits and the folder", [root.s.downloadWatch.minAgeMs, root.s.downloadWatch.dir, root.s.packageJobs.minAgeMs],
                [300000, (Quickshell.env("HOME") || "~") + "/Inbox", 0]);
            root.same("shell.jsonc shadow.auraEvents", root.s.shellConfig.auraEvents, { llm: 20, update: false, timer: true, screencast: true });
            const u = root.s.updates;
            root.same("system_update.jsonc check, run.flags", [u.pollIntervalMs, u.avail.aurEnabled, u.avail.flatpakEnabled, u.runCommand], [0, false, true, "yay -Syu --devel"]);
            root.same("system_update.jsonc view, list", [u.openView(), u.avail.groupMin, u.settings.list.open], ["normal", 0, ["all"]]);
            root.same("shell.jsonc clicks: the buttons of the mouse the catchers take", ["theme", "clock", "weather"].map(id => root.frame.barClicks.buttonsOf(id)),
                [Qt.RightButton, Qt.MiddleButton, Qt.NoButton]);
            const t = root.s.timers, cb = root.frame.buttons.clock;
            root.same("clock.jsonc timers: snooze, ring, the countdown's first time, the sound under do-not-disturb",
                [t.snoozeMs, t.ringMaxMs, t.defaultCountdownMs, t.countdown.setMs, t.soundUnderDnd], [240000, 5000, 120000, 120000, false]);
            root.same("clock.jsonc timers.sounds: a file that is not there plays the default, none plays nothing", t._soundPlays,
                { pomodoro: "none", countdown: "alarm-clock-elapsed.oga", alarm: "alarm-clock-elapsed.oga" });
            root.same("clock.jsonc seconds always: held out from the build (the groove's room taken once), the open tab, the wiki's side",
                [cb.forceSeconds, cb.secondsFraction, root.frame.owners.clock.openMode, root.frame.owners.clock.wikiSide], [true, 1, "timers", "far"]);
            const po = root.frame.owners.player;
            root.same("player.jsonc open, musicSparks, prevRestartSec, shuffle", [po.viewMode, po.levelTapEnabled, root.s.mpd.prevRestartSec, root.s.mpd.shuffleArtistGap],
                ["mini", false, 0, 1]);
            root.same("audio.jsonc pill: the tab each half opens", root.frame.owners.audio.halfOpens, ["playback", "playback"]);
        });
        // player.jsonc open.remember false: every open is the file's view, whatever the last one was left on
        root.step("player.jsonc open.remember: left on the player, opened again", () => {
            root.frame.owners.player.viewMode = "player";
            root.frame.owners.player.toggle();
        }, () => root.popup("player"), () => {
            root.check("player.jsonc open.remember false: the open is the file's view", root.frame.owners.player.viewMode === "mini", root.frame.owners.player.viewMode);
        });
        root.step("the player closes", () => root.engine.close(), () => root.shut(), () => {});
        root.step("clock.jsonc open timers: a click opens the timers", () => root.frame.owners.clock.toggle(), () => root.popup("clock"), () => {
            root.check("clock.jsonc open: the tab", root.frame.owners.clock.currentTab === "timers", root.frame.owners.clock.currentTab);
        });
        root.step("the clock closes", () => root.engine.close(), () => root.shut(), () => {});
        root.step("audio.jsonc pill: the microphone's half", () => root.frame.owners.audio.showHalf(1), () => root.popup("audio"), () => {
            const a = root.frame.owners.audio;
            root.check("audio.jsonc pill: the mic's half opens its tab and is the half showing", a.section === "playback" && a.activeHalf === 1,
                a.section + " " + a.activeHalf);
            const sinks = root.s.audio.rows.sinks.map(d => d.name);
            root.same("audio.jsonc hide: a hidden device goes, the default and one a stream plays on stay",
                ["HDMI1", "Speaker", "ACME"].map(w => sinks.some(n => n.indexOf(w) >= 0)), [false, true, true]);
        });
        root.step("the audio closes", () => root.engine.close(), () => root.shut(), () => {});
        // a click outside closes the popups it names
        root.step("clickAway: weather opens", () => root.frame.owners.weather.toggle(), () => root.popup("weather"), () => {
            root.check("clickAway: a popup it names takes the whole track as input", root.engine._catching.length === 1, String(root.engine._catching.length));
            const b = root.engine.thePopup.box;
            root.check("clickAway: a press inside the popup is not outside", root.engine._voidPress((b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2) === false && root.popup("weather"), "");
        });
        root.step("clickAway: a press outside", () => root.engine._voidPress(20, 900), () => root.shut(), () => {
            root.check("clickAway: it closes, and nothing is caught any more", root.engine._catching.length === 0, String(root.engine._catching.length));
        });
        root.step("clickAway: stocks opens", () => root.frame.owners.stocks.toggle(), () => root.popup("stocks"), () => {
            root.check("clickAway: a popup it does not name catches nothing", root.engine._catching.length === 0 && root.engine._voidPress(20, 900) === false && root.popup("stocks"), "");
        });
        root.step("stocks closes", () => root.engine.close(), () => root.shut(), () => {});
        // the outlets: the LLM out of the right bar's foot, the notes under their own button
        root.step("outlets: the notes open", () => root.frame.owners.notes.toggle(), () => root.popup("notes"), () => {
            const b = root.engine.thePopup.box, at = root.frame.buttons.notes.mapToItem(root.frame, 0, 0).x;
            root.check("outlets: \"top\" hangs from the module's own button", b.y0 >= 30 && b.y0 < 60 && b.x0 < at && b.x1 > at, JSON.stringify(b) + " button " + at);
        });
        root.step("the notes close", () => root.engine.close(), () => root.shut(), () => {});
        root.step("outlets: the LLM opens", () => root.frame.owners.llm.toggle(), () => root.popup("llm"), () => {
            const b = root.engine.thePopup.box;
            root.check("outlets: the right bar, at its foot", b.x1 > root.frame.width - 12 && b.x0 > root.frame.width / 2 && b.y1 > root.frame.height - 12, JSON.stringify(b));
        });
        root.step("the LLM closes", () => root.engine.close(), () => root.shut(), () => {});
        // weather.jsonc view (the mock's config is a literal: set here as the file would set it)
        root.step("weather.jsonc view never: opened, then left on detailed", () => {
            root.s.weather.config = Object.assign({}, root.s.weather.config, { view: { start: "normal", remember: "never" } });
            root.frame.owners.weather.toggle();
        }, () => root.popup("weather"), () => {
            const c = root.engine.thePopup.contentItem;
            root.check("weather.jsonc view.start: the open is on it", c.viewMode === "normal", c.viewMode);
            c.viewMode = "detailed";
        });
        root.step("weather closes", () => root.engine.close(), () => root.shut(), () => {});
        root.step("weather.jsonc view never: opened again", () => root.frame.owners.weather.toggle(), () => root.popup("weather"), () => {
            const c = root.engine.thePopup.contentItem;
            root.check("weather.jsonc view.remember never: every open is on start", c.viewMode === "normal" && root.frame.owners.weather.viewMode === "normal",
                c.viewMode + " " + root.frame.owners.weather.viewMode);
        });
        root.step("weather closes again", () => root.engine.close(), () => root.shut(), () => {});
    }
}
