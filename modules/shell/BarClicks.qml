pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// BarClicks.qml -- what a right or middle click on a bar button does when shell.jsonc `clicks` says so: { "clock": { "right": ["xdg-open",
// "https://..."], "middle": "timer" } }. One per frame.
//
// A button's own clicks are the button's (theme's mode, player's play / pause, the volume's mute, the bell's do-not-disturb); ModuleSlot lays a
// catcher over the button for the clicks the file names, and only for those. A click is "none", "popup", one of the button's words (below;
// specs/shell.js CLICKS has the same table) or a command, run detached by the shell's CommandRunner. Nothing while the session is locked: the
// catcher is not there then.
// =============================================================================
QtObject {
    id: root

    required property var frame
    // the volume pill (VolumeParity), which knows which half a point is on
    property var volume: null

    readonly property var services: root.frame.services
    readonly property var table: root.services.shellConfig.clicks

    // What `which` ("right" | "middle") on that module's button is told to do; undefined = as the button has it.
    function actionOf(id: string, which: string): var {
        const e = root.table ? root.table[id] : undefined;
        return e ? e[which] : undefined;
    }

    // The buttons the catcher takes from that module's button.
    function buttonsOf(id: string): int {
        if (root.services.lock.locked)
            return Qt.NoButton;
        return (root.actionOf(id, "right") !== undefined ? Qt.RightButton : Qt.NoButton)
            | (root.actionOf(id, "middle") !== undefined ? Qt.MiddleButton : Qt.NoButton);
    }

    // `item`: whose coordinates x and y are.
    function click(id: string, button: int, item: Item, x: real, y: real): void {
        const a = root.actionOf(id, button === Qt.RightButton ? "right" : "middle");
        if (a === undefined || a === "none" || root.services.lock.locked)
            return;
        if (typeof a !== "string")
            root.services.commands.run(a, { detached: true });
        else if (a === "popup")
            root._popup(id);
        else
            root._word(id + "." + a, item, x, y);
    }

    function _popup(id: string): void {
        const o = root.frame.owners[id === "volume" ? "audio" : id];
        if (o && o.toggle)
            o.toggle();
    }

    function _word(word: string, item: Item, x: real, y: real): void {
        const s = root.services;
        const o = root.frame.owners;
        switch (word) {
        case "theme.mode": s.themeControl.click(); break;
        case "theme.next": s.themeControl.next(); break;
        case "notes.new": o.notes.openNew(); break;
        case "llm.new": o.llm.openNew(); break;
        case "weather.refresh": if (s.weather) s.weather.refresh(); break;
        case "weather.nextPlace":
            if (s.weather && s.weather.locations.length > 1)
                s.weather.selectLocation((s.weather.locationIndex + 1) % s.weather.locations.length);
            break;
        case "clock.timer": root._timer(); break;
        case "clock.timers": o.clock.openTimers(""); break;
        case "clock.wiki": o.clock.openWiki("discover"); break;
        case "stocks.refresh": if (s.stocks) s.stocks.refresh(); break;
        case "player.toggle": if (s.mpd) s.mpd.toggle(); break;
        case "player.next": if (s.mpd) s.mpd.next(); break;
        case "player.prev": if (s.mpd) s.mpd.prev(); break;
        case "player.stop": if (s.mpd) s.mpd.stop(); break;
        case "volume.mute": {
            const p = item.mapToItem(root.volume, x, y);
            root.volume.click(root.volume.halfAt(p.x, p.y), Qt.RightButton);
            break;
        }
        case "aerial.vpn":
            if (s.aerial && s.aerial.proton.state === "down")
                s.aerial.vpnConnect({});
            else if (s.aerial)
                s.aerial.vpnDisconnect();
            break;
        case "aerial.airplane": if (s.aerial) s.aerial.setAirplane(!s.aerial.airplane.on); break;
        case "bridge.mirror": if (s.bridge) s.bridge.mirror(s.bridge.currentKey, {}); break;
        case "bridge.shot": if (s.bridge) s.bridge.shot(s.bridge.currentKey); break;
        case "bridge.clip": if (s.bridge) s.bridge.clip(s.bridge.currentKey); break;
        case "panorama.displays":
        case "panorama.presets": o.panorama.openOn(word.substring(9)); break;
        case "silicon.nextProfile": if (s.silicon) s.silicon.stepProfile(1); break;
        case "update.check": if (s.updates && s.updates.avail) s.updates.avail.refresh(); break;
        case "notifications.dnd": if (s.notifications) s.notifications.dnd = !s.notifications.dnd; break;
        case "notifications.clear": if (s.notifications) s.notifications.clearAll(); break;
        }
    }

    // The timer in progress that was started last: pause, or on again. None in progress: the timers tab.
    function _timer(): void {
        const t = root.services.timers;
        if (!t)
            return;
        const live = [];
        if (t.countdown.state === "running" || t.countdown.state === "paused")
            live.push({ at: t.touched.countdown, run: t.countdown.state === "running", go: () => t.resume(), stop: () => t.pause() });
        if (t.pomodoro.state === "running" || t.pomodoro.state === "paused" || t.pomodoro.state === "waiting")
            live.push({ at: t.touched.pomodoro, run: t.pomodoro.state === "running",
                        go: () => t.pomodoro.state === "waiting" ? t.pomoStart() : t.pomoResume(), stop: () => t.pomoPause() });
        if (t.stopwatch.state === "running" || t.stopwatch.state === "paused")
            live.push({ at: t.touched.stopwatch, run: t.stopwatch.state === "running", go: () => t.swStart(), stop: () => t.swPause() });
        if (live.length === 0) {
            root.frame.owners.clock.openTimers("");
            return;
        }
        live.sort((a, b) => b.at - a.at);
        if (live[0].run)
            live[0].stop();
        else
            live[0].go();
    }
}
