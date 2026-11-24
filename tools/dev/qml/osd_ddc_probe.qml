import QtQuick
import Quickshell

import "modules/osd/data"
import "modules/osd/data/sources"

// tools/dev/qml/osd_ddc_probe.qml -- the brightness keys act on the display UNDER THE POINTER (tools/dev/osd_ddc_probe.sh runs it).
// OsdService live: false (pointerLive: true, ODP_BIN/hyprctl_* stubs print `hyprctl -j cursorpos`) with a STUB display backend (the Panorama
// surface: brightnessTarget, ddc*) that records its calls. Prints "ODP ok|FAIL <name>" and "ODP RESULT PASS|FAIL (n/n checks)".
Scope {
    id: root
    property string bin: Quickshell.env("ODP_BIN")
    property int fails: 0
    property int checks: 0
    property var reqs: []
    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("ODP " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    // the stub backend: every external is "ddc" (the display module says so; its state tells the rest)
    QtObject {
        id: be
        property var calls: []
        property var st: ({})        // name -> { v, goal, pend, state, reason, delta }
        signal ddcChanged(string name)
        function brightnessTarget(s: string): var {
            if (s === "eDP-1" || s === "")
                return { kind: "panel", connector: "", label: "" };
            return { kind: "ddc", connector: s, label: s === "DP-1" ? "DELL U2723QE" : "LG 27" };
        }
        function _s(n) { return be.st[n] || { v: -1, goal: -1, pend: false, state: "unknown", reason: "", delta: 0 }; }
        function ddcEnsure(): void { be.calls.push("ensure"); }
        function ddcValue(n: string): int { return be._s(n).v; }
        function ddcGoal(n: string): int { const s = be._s(n); return s.goal >= 0 ? s.goal : s.v; }
        function ddcMax(n: string): int { return 100; }
        function ddcPending(n: string): bool { const s = be._s(n); return s.pend || s.delta !== 0; }
        function ddcState(n: string): string { return be._s(n).state; }
        function ddcReason(n: string): string { return be._s(n).reason; }
        function ddcAdjust(n: string, d: int): bool {
            const s = be._s(n);
            be.calls.push("adjust " + n + " " + d);
            if (s.state === "unsupported" || s.state === "failing")
                return false;
            if (s.v < 0) {
                s.delta += d;
            } else {
                s.goal = Math.max(0, Math.min(100, (s.goal >= 0 ? s.goal : s.v) + d));
                s.pend = true;
            }
            be.st[n] = s;
            return true;
        }
        function ddcScrub(n: string, v: int): void { be.calls.push("scrub " + n + " " + v); }
        function ddcCommit(n: string): void { be.calls.push("commit " + n); }
        // the write is done: the goal is the value, pending falls
        function settle(n: string): void {
            const s = be._s(n);
            s.v = s.goal >= 0 ? s.goal : s.v;
            s.goal = -1;
            s.pend = false;
            be.st[n] = s;
            be.ddcChanged(n);
        }
        function reset(): void { be.calls = []; root.reqs = []; }
    }

    OsdService {
        id: svc
        live: false
        registerOnBus: false
        pointerLive: true
        hyprctl: root.bin + "/hyprctl_a"
        displayBackend: be
        focusedScreen: "eDP-1"
        gestureKeepMs: 400
        monitorRects: [
            { name: "eDP-1", x: 0, y: 0, width: 2880, height: 1620, scale: 1.5, transform: 0 },
            { name: "DP-1", x: 1920, y: 0, width: 2560, height: 1440, scale: 1, transform: 0 },
            { name: "DP-2", x: 4480, y: 0, width: 1920, height: 1080, scale: 1, transform: 0 },
            { name: "DP-3", x: 6400, y: 0, width: 1920, height: 1080, scale: 1, transform: 0 },
            { name: "DP-4", x: 8320, y: 0, width: 1920, height: 1080, scale: 1, transform: 0 }
        ]
        onRequest: req => root.reqs.push(req)
    }

    // the media keys (osd.jsonc media.keys "auto"): a stub mpd and a stub playerctl (the runner's: one player plays, one is paused)
    QtObject {
        id: mpd
        property bool connected: true
        property string playState: "stop"
        property var current: null
        property var calls: []
        function next(): void { mpd.calls = mpd.calls.concat(["next"]); }
        function prev(): void { mpd.calls = mpd.calls.concat(["prev"]); }
        function toggle(): void { mpd.calls = mpd.calls.concat(["toggle"]); }
        function stop(): void { mpd.calls = mpd.calls.concat(["stop"]); }
    }
    property var tracks: []
    MpdSource {
        id: media
        live: true
        backend: mpd
        others: true
        onRequest: req => root.tracks = root.tracks.concat([req])
    }
    function mediaKey(verb: string, playerctl: string, state: string, song: var): void {
        mpd.calls = [];
        root.tracks = [];
        mpd.playState = state;
        mpd.current = song;
        media._noPlayerctl = false;
        media.playerctl = root.bin + "/" + playerctl;
        media.media(verb);
    }

    readonly property string label: "DELL U2723QE"
    function setup() {
        be.st = {
            "DP-1": { v: 50, goal: -1, pend: false, state: "ok", reason: "", delta: 0 },
            "DP-2": { v: -1, goal: -1, pend: false, state: "probing", reason: "", delta: 0 },
            "DP-3": { v: -1, goal: -1, pend: false, state: "unsupported", reason: "This display takes no brightness over DDC.", delta: 0 },
            "DP-4": { v: 40, goal: -1, pend: false, state: "failing", reason: "DDC communication failed", delta: 0 }
        };
        be.reset();
        svc._autoDelay = 100000;
        svc.sources.backlight.device = "stub0";
        svc.sources.backlight.simulateSet(200, 400);
        svc.displayBackend = be;
        svc.focusedScreen = "eDP-1";
        svc.hyprctl = root.bin + "/hyprctl_a";
        svc.sources.ddcBrightness.pendingRefreshMs = 120;
    }
    function last() { return root.reqs.length ? root.reqs[root.reqs.length - 1] : null; }
    function isPanel(r) { return r !== null && r.kind === "brightness" && r.device.name !== root.label && r.pending === undefined; }
    function near(a, b) { return Math.abs(a - b) < 1e-9; }
    function has(s) { return be.calls.indexOf(s) >= 0; }
    function nadj() { return be.calls.filter(c => c.indexOf("adjust ") === 0).length; }
    function newGesture() { svc._bGesture = null; }

    // the sequencer: each step waits for its own signal (a request count or a condition), never a timer
    property var steps: []
    property int at: -1
    property real _deadline: 0
    function step(name: string, act: var, cond: var) { root.steps.push({ name: name, act: act, cond: cond }); }
    function go() { root.at = 0; root._enter(); }
    function _enter() {
        const s = root.steps[root.at];
        s.act();
        root._deadline = Date.now() + 5000;
    }
    Timer {
        interval: 15; running: root.at >= 0; repeat: true
        onTriggered: {
            const s = root.steps[root.at];
            if (!s.cond()) {
                if (Date.now() > root._deadline) {
                    root.check(s.name + " (the awaited signal never came)", false, JSON.stringify(root.reqs) + JSON.stringify(be.calls));
                    root.at = -1;
                    root.done();
                }
                return;
            }
            root.at++;
            if (root.at >= root.steps.length) {
                root.at = -1;
                root.done();
            } else
                root._enter();
        }
    }
    function reqsAtLeast(n) { return () => root.reqs.length >= n; }
    function now() { return () => true; }

    Component.onCompleted: {
        if (root.bin === "") {
            console.log("ODP RESULT PASS (not driven: no runner env)");
            Qt.callLater(Qt.quit);
            return;
        }
        root.setup();
        // 1 pointer on the laptop while the external is focused: the laptop's backlight
        root.step("1", () => { root.setup(); svc.focusedScreen = "DP-1"; svc.hyprctl = root.bin + "/hyprctl_a"; root.newGesture(); svc.brightness("up"); }, root.reqsAtLeast(1));
        root.step("1c", () => root.check("pointer on the laptop, external focused: the panel steps, no ddc call", root.isPanel(root.last()) && root.nadj() === 0, JSON.stringify(root.reqs) + JSON.stringify(be.calls)), root.now());
        // 2 pointer on the external while the laptop is focused: DDC, with the pending look at once, and no panel step
        root.step("2", () => { root.setup(); root.newGesture(); svc.focusedScreen = "eDP-1"; svc.hyprctl = root.bin + "/hyprctl_b"; svc.brightness("up"); }, root.reqsAtLeast(1));
        root.step("2c", () => {
            const r = root.last();
            root.check("pointer on the external, laptop focused: ddcAdjust +5 on DP-1", root.has("adjust DP-1 5") && root.nadj() === 1, JSON.stringify(be.calls));
            root.check("the card names the display, shows the GOAL, pending: true", r.kind === "brightness" && r.device.name === root.label && root.near(r.value, 0.55) && r.pending === true && r.ddcState === "ok" && r.unavailable === false, JSON.stringify(r));
            root.check("the laptop's backlight was not touched", svc.sources.backlight.raw === 200, String(svc.sources.backlight.raw));
            be.settle("DP-1");
        }, root.reqsAtLeast(2));
        root.step("2d", () => {
            const r = root.last();
            root.check("the write is done: the card is asked again, pending false, same figure", r.pending === false && root.near(r.value, 0.55) && r.source === "ddc", JSON.stringify(r));
        }, root.now());
        // 3 a gesture keeps its display: the pointer moves away mid-hold, repeats and the next taps stay on the external
        root.step("3", () => { root.setup(); root.newGesture(); svc.focusedScreen = "eDP-1"; svc.hyprctl = root.bin + "/hyprctl_b"; svc.brightness("press-up"); }, root.reqsAtLeast(1));
        root.step("3b", () => { svc.hyprctl = root.bin + "/hyprctl_a"; for (let i = 0; i < 6; i++) svc._repeat(); svc.brightness("up"); }, () => root.nadj() >= 8);
        root.step("3c", () => {
            svc.brightness("release-up");
            root.check("a hold: the press, six repeats and a tap within 400 ms all reach DP-1, none dropped", root.nadj() === 8 && root.reqs.length >= 8 && !root.isPanel(root.last()), root.nadj() + " " + root.reqs.length);
            root.check("the figure is the sum: 50 + 8 x 5 = 90", root.near(root.last().value, 0.9), root.last().value);
        }, root.now());
        // 4 presses before the pointer's answer wait their turn, in order, on the SAME display
        root.step("4", () => { root.setup(); root.newGesture(); svc.hyprctl = root.bin + "/hyprctl_slow_b"; svc.pointerWaitMs = 150; svc.brightness("up"); svc.brightness("up"); svc.brightness("down"); },
                  () => root.reqs.length >= 3);
        root.step("4c", () => root.check("a slow cursorpos: after 150 ms the FOCUSED screen (the laptop) takes the 3 queued steps", root.reqs.length === 3 && root.isPanel(root.last()) && root.nadj() === 0, JSON.stringify(root.reqs.length) + JSON.stringify(be.calls)), root.now());
        root.step("4d", () => root.check("...the late answer changes nothing", true, ""), root.now());
        // 5 cursorpos missing / failing: the focus decides
        root.step("5", () => { root.setup(); root.newGesture(); svc.focusedScreen = "DP-1"; svc.hyprctl = root.bin + "/no_such_program"; svc.brightness("up"); }, () => root.nadj() >= 1);
        root.step("5c", () => root.check("hyprctl missing, external focused: DDC", root.has("adjust DP-1 5") && !root.isPanel(root.last()), JSON.stringify(be.calls)), root.now());
        root.step("5d", () => { root.setup(); root.newGesture(); svc.focusedScreen = "eDP-1"; svc.hyprctl = root.bin + "/hyprctl_fail"; svc.brightness("up"); }, root.reqsAtLeast(1));
        root.step("5e", () => root.check("cursorpos failing, laptop focused: the panel", root.isPanel(root.last()) && root.nadj() === 0, JSON.stringify(root.reqs)), root.now());
        // 6 an external without DDC: the card says so, the laptop is NOT stepped
        root.step("6", () => { root.setup(); root.newGesture(); svc.focusedScreen = "eDP-1"; svc.hyprctl = root.bin + "/hyprctl_c"; svc.brightness("up"); }, root.reqsAtLeast(1));
        root.step("6c", () => {
            const r = root.last();
            root.check("no DDC for DP-3: an unavailable card with the reason under the name", r.unavailable === true && r.pending === false && r.ddcState === "unsupported" && r.note.indexOf("no brightness over DDC") > 0 && r.device.name === "LG 27", JSON.stringify(r));
            root.check("...and the laptop's backlight stays where it was", svc.sources.backlight.raw === 200 && root.reqs.length === 1, String(svc.sources.backlight.raw));
        }, root.now());
        root.step("6d", () => { root.setup(); root.newGesture(); svc.hyprctl = root.bin + "/hyprctl_d"; svc.brightness("up"); }, root.reqsAtLeast(1));
        root.step("6e", () => root.check("a remembered failure: the card says the display's words", root.last().unavailable === true && root.last().ddcState === "failing" && root.last().note === "DDC communication failed", JSON.stringify(root.last())), root.now());
        // 7 an unknown value: the card is up at once, "looking", then the value lands and the card follows
        root.step("7", () => { root.setup(); root.newGesture(); svc.hyprctl = root.bin + "/hyprctl_e"; svc.brightness("up"); }, root.reqsAtLeast(1));
        root.step("7c", () => {
            const r = root.last();
            root.check("unknown value: a pending card at once, no figure yet, 'Looking for the display'", r.pending === true && r.value === 0 && r.note === "Looking for the display" && r.ddcState === "probing", JSON.stringify(r));
            const s = be.st["DP-2"]; s.v = 30; s.state = "ok"; s.goal = 35; s.delta = 0; s.pend = true; be.ddcChanged("DP-2");
        }, root.reqsAtLeast(2));
        root.step("7d", () => root.check("the value lands: the card shows the goal (the kept step applied)", root.near(root.last().value, 0.35) && root.last().note === "" && root.last().pending === true, JSON.stringify(root.last())), root.now());
        // 8 pending keeps the card alive: it is asked for again while it waits
        root.step("8", () => { root.reqs = []; }, () => root.reqs.length >= 2);
        root.step("8c", () => { root.check("a pending card is asked for again (the 120 ms refresh) while it waits", root.reqs.length >= 2 && root.reqs.every(r => r.pending === true), JSON.stringify(root.reqs.length)); be.settle("DP-2"); }, root.now());
        // 9 the card's slider on a DDC card scrubs; on the panel card it does not
        root.step("9", () => { root.setup(); root.newGesture(); svc.hyprctl = root.bin + "/hyprctl_b"; svc.brightness("up"); }, root.reqsAtLeast(1));
        root.step("9c", () => { be.calls = []; svc.userValue("brightness", 0.3); root.check("the slider on a DDC card: ddcScrub (written at rest by the client)", root.has("scrub DP-1 30"), JSON.stringify(be.calls)); }, root.now());
        root.step("9d", () => { root.setup(); root.newGesture(); svc.hyprctl = root.bin + "/hyprctl_a"; svc.brightness("up"); }, root.reqsAtLeast(1));
        root.step("9e", () => { svc.userValue("brightness", 0.3); root.check("the slider on the panel card: no scrub", !be.calls.some(c => c.indexOf("scrub") === 0), JSON.stringify(be.calls)); }, root.now());
        // 10 null backend
        root.step("10", () => { root.setup(); root.newGesture(); svc.displayBackend = null; svc.hyprctl = root.bin + "/hyprctl_b"; svc.brightness("up"); }, root.reqsAtLeast(1));
        root.step("10c", () => { root.check("null backend: today's path", root.isPanel(root.last()) && be.calls.length === 0, JSON.stringify(root.reqs)); svc.displayBackend = be; }, root.now());
        // 12 osd.jsonc brightness.target: the focused screen's display, the laptop's own (the pointer is on the external both times, asked by neither)
        root.step("12", () => { root.setup(); root.newGesture(); svc.config.apply({ brightness: { target: "focused" } }); svc.focusedScreen = "eDP-1"; svc.hyprctl = root.bin + "/hyprctl_b"; svc.brightness("up"); }, root.reqsAtLeast(1));
        root.step("12c", () => root.check("target focused: the pointer on the external, the laptop focused -> the panel", root.isPanel(root.last()) && root.nadj() === 0, JSON.stringify(root.reqs)), root.now());
        root.step("12d", () => { root.setup(); root.newGesture(); svc.config.apply({ brightness: { target: "panel" } }); svc.focusedScreen = "DP-1"; svc.hyprctl = root.bin + "/hyprctl_b"; svc.brightness("up"); }, root.reqsAtLeast(1));
        root.step("12e", () => { root.check("target panel: the external focused and under the pointer -> the panel", root.isPanel(root.last()) && root.nadj() === 0, JSON.stringify(root.reqs)); svc.config.apply({}); }, root.now());
        // 13 osd.jsonc kinds.<kind>.events: an event that is left out is not shown (and not handled)
        root.step("13", () => {
            root.setup();
            svc.config.apply({ kinds: { track: { events: ["key"] }, network: { events: [] }, volume: { events: ["key", "external"] } } });
            const tr = src => ({ kind: "track", source: src, track: { title: "T", artist: "", album: "", art: "", state: "play", action: src === "key" ? "next" : "" } });
            const vol = ev => ({ kind: "volume", source: ev === "key" ? "key" : "external", event: ev, value: 0.5, max: 1, muted: false, boost: false, device: { type: "speaker", name: "S" } });
            const got = [svc.show(tr("key")), svc.show(tr("external")), svc.show(Object.assign(tr("external"), { event: "key" })),
                         svc.show({ kind: "network", net: { ssid: "H", signal: 1, state: "lost" } }), svc.show(vol("external")), svc.show(vol("device")), svc.test("volume")];
            root.check("events: what is left out is not shown; a cover that lands on a key's card is the key's; an unlisted kind and a test are whole",
                       JSON.stringify(got) === "[true,false,true,false,true,false,true]" && root.reqs.length === 4, JSON.stringify(got) + root.reqs.length);
            svc.config.apply({});
        }, root.now());
        // 14 media.keys "auto": mpd with a song in play keeps the keys; without one the player that plays has them (and its card)
        root.step("14", () => root.mediaKey("toggle", "playerctl_two", "pause", { id: 1 }), root.now());
        root.step("14b", () => root.check("media auto: mpd paused in a song keeps the key", JSON.stringify(mpd.calls) === '["toggle"]', JSON.stringify(mpd.calls)), root.now());
        root.step("14c", () => { root.mediaKey("toggle", "playerctl_two", "stop", null); media.media("next"); }, () => root.tracks.length >= 2);
        root.step("14d", () => {
            const t = root.tracks[0];
            root.check("media auto: the player that PLAYS has the key, its card what it plays, no picture from the net; a press meanwhile waits its turn",
                       mpd.calls.length === 0 && t.source === "key" && t.track.title === "A film" && t.track.action === "toggle" && t.track.state === "pause" && t.track.art === ""
                       && root.tracks[1].track.action === "next" && root.tracks[1].track.title === "browser.2 next", JSON.stringify(root.tracks) + JSON.stringify(mpd.calls));
        }, root.now());
        root.step("14e", () => root.mediaKey("toggle", "playerctl_none", "stop", null), () => mpd.calls.length > 0);
        root.step("14f", () => root.check("media auto: no player at all -> mpd", JSON.stringify(mpd.calls) === '["toggle"]' && root.tracks.length === 0, JSON.stringify(mpd.calls)), root.now());
        root.step("14g", () => root.mediaKey("next", "no_playerctl", "stop", null), () => mpd.calls.length > 0);
        root.step("14h", () => { root.check("media auto: no playerctl -> mpd, remembered", mpd.calls[0] === "next" && media._noPlayerctl, JSON.stringify(mpd.calls)); media.media("next"); }, () => mpd.calls.length === 2);
        // 11 the laptop's panel for the popup
        root.step("11", () => { root.setup(); }, root.now());
        root.step("11c", () => {
            const rev = svc.panelRev;
            const a = svc.panelBrightness();
            root.check("panelBrightness: capable, a figure in 0..1", a.capable === true && a.value >= 0 && a.value <= 1, JSON.stringify(a));
            svc.setPanelBrightness(0.5);
            const b = svc.panelBrightness();
            root.check("setPanelBrightness moves the figure and panelRev", svc.panelRev > rev && Math.abs(b.value - 0.5) < 0.06, JSON.stringify(b) + " " + svc.panelRev);
            svc.setPanelBrightness(0);
            root.check("a slider at 0 never blacks the panel", svc.sources.backlight.raw >= 1, String(svc.sources.backlight.raw));
        }, root.now());
        root.go();
    }

    function done() {
        console.log("ODP RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks)");
        Qt.quit();
    }
}
