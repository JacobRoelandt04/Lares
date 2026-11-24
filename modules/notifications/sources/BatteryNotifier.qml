pragma ComponentBehavior: Bound

import QtQuick

import "SourceGlyphs.js" as G
import "BatteryLevels.js" as Levels

// =============================================================================
// BatteryNotifier.qml -- the battery tells you what it is doing (source "battery"; SOURCES.md).
//
// It listens to the shell's ONE battery reader, silicon's (the SiliconBatteryAdapter, injected as `battery`: this
// source reads no sysfs and builds no BatteryData, whose uevent read is an ACPI call into the embedded
// controller), and says:
//
//   level   8 % Critical with Hibernate (15 % is the OSD's card); 3 % Critical with Hibernate, sticky, breaking do-not-disturb
//           (sources.battery.levels; they run while the status is Discharging OR charging is STALLED -- nothing reaches a drained pack
//           on a charger that cannot feed the machine, the adapter's `chargeStalled`), each a share of the pack the limit leaves: with the 80 % limit on, 8 % speaks at 6,
//           and the card's rail is scaled the same way, as the bar's track is (the body says the real figure). ONE key: each level the charge falls to replaces the card of the one before,
//           a flicker 8, 9, 8 says it once, and the card goes the moment charging starts. While it is up its
//           rail follows the charge SILENTLY, as an UPDATE of the record: a card the user took away has nothing to
//           follow and stays away until the next level (posting it again made a new toast per percent, for the
//           whole way from 8 to 3); the title is the
//           state ("Battery low", "very low", "critical"), the body the reading it was posted at. The shell never
//           powers anything down on its own: Hibernate is a DUD until the machine can hibernate (it says so on a
//           card of its own, as the power reel's does) and `sources.battery.hibernate: "systemctl"` makes it real.
//   limit   "Charged to 80 %": the pack reached its target -- the EC's charge limit, or 100. It arrives WITH its
//           reading (the adapter holds the event until silicon has published it), so the figure is the crossing's
//           own. It goes when the pack starts to discharge.
//   drain   "Battery draining fast": the draw stays `factor` times above the usual, and over `minW` watts, for
//           `minutes` -- a runaway process. "Usual" is eased by TIME (an exponential in minutes applied with the
//           real interval between readings), held out while the draw is anomalous, kept in sources.json across
//           restarts; its card opens silicon's popup, which names the process.
//
// Every reading comes from the adapter's `reading` signal, once per publication, after its events. The popup
// of silicon open (`battery.silicon.popupOpen`) files the posts silently: the user is looking at the battery.
// =============================================================================
SourceBase {
    id: src

    sourceId: "battery"
    appName: "Battery"
    glyph: G.battery
    keys: ["level", "limit", "drain", "hibernate"]

    // The SiliconBatteryAdapter (null: this source is off).
    property var battery: null
    ready: !!src.battery
    attended: !!src.battery && !!src.battery.silicon && src.battery.silicon.popupOpen === true

    // The clock the drain's average is read by (the probes' seam; the shell's is the wall).
    property var nowFn: function () { return Date.now(); }

    // ====================================================================================================
    //  the levels
    // ====================================================================================================
    readonly property int _target: src.battery && src.battery.targetPercent > 0 ? src.battery.targetPercent : 100
    readonly property var _levels: Levels.scaleLevels(Levels.sortLevels(src.settings.levels), src._target)
    property var _lv: Levels.newState()
    property string _levelUid: ""           // the level card's record, "" with none out (a rail that follows updates it)
    property int _lastPct: -1

    property string _levelsKey: ""
    on_LevelsChanged: {
        // The list moved (notifications.jsonc): the high-water mark is an index into the previous one. (Any edit of
        // the file makes a new array of the same levels; only a real change starts over.)
        const key = JSON.stringify(src._levels);
        if (key === src._levelsKey)
            return;
        src._levelsKey = key;
        if (!src.active)
            return;
        src._lv = Levels.newState();
        src._levelUid = "";
        src.withdraw("level");
        src._read();
    }

    function _read() {
        if (!src.active)
            return;
        const b = src.battery;
        // "Charging" with nothing reaching the pack (silicon's chargeStalled: acpi's "charging at zero rate") is a pack that is
        // being drained, whatever the kernel's word says (2026-11-04: 2 % falling to 0 % for eight minutes under "Charging").
        const draining = b.status === "Discharging" || b.chargeStalled === true;
        const out = Levels.step(src._lv, { percent: b.percent, status: draining ? "Discharging" : b.status }, src._levels);
        if (out.withdraw) {
            src._levelUid = "";
            src._lastPct = -1;
            src.withdraw("level");
        }
        if (b.status === "Discharging")
            src.withdraw("limit");
        if (out.post >= 0) {
            src._postLevel(out.post, b);
        } else if (src._levelUid !== "" && draining && b.percent !== src._lastPct) {
            // the rail moves, in place; the user has taken the card away: nothing is left to follow
            src._lastPct = b.percent;
            if (!src.update(src._levelUid, { progress: Levels.share(b.percent, src._target) }))
                src._levelUid = "";
        }
    }

    function _postLevel(idx, b) {
        const lv = src._levels[idx];
        const t = Levels.levelText(lv, idx, src._levels.length, b.percent, b.estimatedTimeSec > 0 ? b.estimatedTimeSec / 60 : -1);
        src._lastPct = b.percent;
        src._levelUid = src.post("level", {
            title: t.title, body: t.body, urgency: lv.urgency, timeoutMs: lv.timeoutMs, breakDnd: lv.breakDnd,
            progress: Levels.share(b.percent, src._target),
            // a card with Hibernate on it must survive its button (an action consumes a card unless it is resident)
            resident: lv.hibernate,
            actions: lv.hibernate ? [{ id: "hibernate", label: "Hibernate", run: () => src.hibernate() }] : [],
            onDefault: () => src.host.open("silicon")
        });
    }

    // A DUD until the machine can hibernate: it says so, on a card of its own so the
    // warning stays. "systemctl" is the day it works.
    function hibernate() {
        if (src.settings.hibernate === "systemctl") {
            src.host.run(["systemctl", "hibernate"]);
            return;
        }
        src.post("hibernate", {
            title: "Hibernate is not set up yet",
            body: "The machine has no resume device configured, so the button does nothing.",
            urgency: "low", timeoutMs: 5000
        });
    }

    // ====================================================================================================
    //  the charge limit
    // ====================================================================================================
    function _charged() {
        if (!src.active || !src.settings.limitReached)
            return;
        const t = Levels.limitText(src.battery.percent);
        src.post("limit", { title: t.title, body: t.body, urgency: "low", icon: G.batteryCharged });
    }

    // ====================================================================================================
    //  the fast drain
    // ====================================================================================================
    property var _drain: Levels.newDrain(0, 0, 0)
    property double _savedMs: 0

    function _sample() {
        if (!src.active || !src.settings.fastDrain.enabled)
            return;
        const b = src.battery;
        const now = src.nowFn();
        const p = src.settings.fastDrain;
        const out = Levels.drainStep(src._drain, { nowMs: now, watts: b.powerNowW, discharging: b.isDischarging }, p);
        if (out.clear)
            src.withdraw("drain");
        if (out.fire)
            src.post("drain", {
                title: "Battery draining fast", body: Levels.drainText(src._drain.fastW, src._drain.usualW), urgency: "normal",
                actions: [{ id: "open", label: "Open", run: () => src.host.open("silicon") }],
                onDefault: () => src.host.open("silicon")
            });
        if (now - src._savedMs >= 300000 && src._drain.usualW > 0)
            src._saveUsual(now);
    }
    function _saveUsual(now) {
        src._savedMs = now;
        src.host.state.put("battery", { usualW: Math.round(src._drain.usualW * 10) / 10 });
    }

    Connections {
        target: src.battery
        ignoreUnknownSignals: true
        function onEventFullyCharged() {
            src._charged();
        }
        function onReading() {
            src._read();
            src._sample();
        }
    }

    onActivated: {
        const st = src.host.state.get("battery");
        src._drain = Levels.newDrain(typeof st.usualW === "number" ? st.usualW : 0, src.nowFn(), src.settings.fastDrain.warmupMin);
        src._lv = Levels.newState();
        src._levelUid = "";
        src._lastPct = -1;
        src._read();
    }
    onDeactivated: {
        if (src._drain.usualW > 0)
            src._saveUsual(src.nowFn());
        src._levelUid = "";
    }
}
