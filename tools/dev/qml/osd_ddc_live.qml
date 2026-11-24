import QtQuick
import Quickshell
import Quickshell.Io

import "modules/osd/data"
import "modules/panorama/data"

// tools/dev/qml/osd_ddc_live.qml -- the whole path of a brightness key: OsdService -> a backend with PanoramaService's DDC surface (the shim
// below is the exact delegation the service patch writes) -> a real DdcClient -> stub ddcutil; the pointer is a stub hyprctl, the laptop's
// backlight a fake sysfs with a stub brightnessctl that logs. ODL_MODE = ok | slow | ignore (the stub ddcutil reads it too).
// Prints "ODL ok|FAIL <name>" and "ODL RESULT PASS|FAIL".
Scope {
    id: root
    property string dir: Quickshell.env("ODL_W")
    property string mode: Quickshell.env("ODL_MODE")
    property int fails: 0
    property int checks: 0
    property var reqs: []
    property var times: []
    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("ODL " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }
    function j(v: var): string { return JSON.stringify(v); }

    readonly property var outs: [
        { name: "eDP-1", description: "Sharp", x: 0, y: 0, width: 2880, height: 1620, scale: 1.5, transform: 0 },
        { name: "DP-1", description: "Dell Inc. DELL U2723QE 7ZQ4PX3", x: 1920, y: 0, width: 2560, height: 1440, scale: 1, transform: 0 }
    ]

    // PanoramaService's DDC surface, as the patch writes it
    DdcClient {
        id: ddc
        live: true
        program: root.dir + "/bin/ddcutil"
        outputs: root.outs
        timeoutMs: 8000
        onValueChanged: n => be.ddcChanged(n)
    }
    QtObject {
        id: be
        signal ddcChanged(string name)
        function brightnessTarget(s: string): var {
            if (s === "" || /^(eDP|LVDS|DSI)(-|$)/.test(s))
                return { kind: "panel", connector: "", label: "" };
            return { kind: "ddc", connector: s, label: "DELL U2723QE" };
        }
        function ddcEnsure(): void { ddc.ensureDetected(); }
        function ddcValue(n: string): int { return ddc.value(n); }
        function ddcGoal(n: string): int { return ddc.goal(n); }
        function ddcMax(n: string): int { return ddc.max(n); }
        function ddcPending(n: string): bool { return ddc.pending(n); }
        function ddcState(n: string): string { return ddc.stateOf(n); }
        function ddcReason(n: string): string { return ddc.reasonOf(n); }
        function ddcAdjust(n: string, d: int): bool { return ddc.adjust(n, d); }
        function ddcScrub(n: string, v: int): void { ddc.scrub(n, v); }
        function ddcCommit(n: string): void { ddc.commit(n); }
    }

    OsdService {
        id: svc
        live: false
        registerOnBus: false
        pointerLive: true
        hyprctl: root.dir + "/bin/hyprctl_b"
        displayBackend: be
        focusedScreen: "eDP-1"
        monitorRects: root.outs
        onRequest: req => { root.reqs.push(req); root.times.push(Date.now()); }
    }

    Process { id: sh; stdout: StdioCollector { id: shOut } }
    property var cont: null
    function run(cmd: string, then: var): void {
        root.cont = then; sh.command = ["sh", "-c", cmd]; sh.running = true;
    }
    Connections {
        target: sh
        function onExited() { const f = root.cont; root.cont = null; if (f) f(shOut.text); }
    }
    function lines(file: string, then: var): void {
        root.run("cat '" + root.dir + "/" + file + "' 2>/dev/null", t => then(t.split("\n").filter(l => l.trim() !== "").map(l => l.trim().split(" ").slice(1).join(" "))));
    }
    function sets(c: var): var { return c.filter(a => a.indexOf("setvcp") === 0); }

    property real _deadline: 0
    property var _cond: null
    property var _then: null
    property string _name: ""
    function until(name: string, cond: var, ms: int, then: var): void {
        root._name = name; root._cond = cond; root._deadline = Date.now() + ms; root._then = then;
    }
    function wait(ms: int, then: var): void {
        const t = Date.now() + ms;
        root.until("wait", () => Date.now() >= t, ms + 3000, then);
    }
    Timer {
        interval: 25; running: true; repeat: true
        onTriggered: {
            if (!root._cond)
                return;
            if (root._cond()) {
                const f = root._then; root._cond = null; root._then = null;
                if (f) f();
            } else if (Date.now() > root._deadline) {
                root.check("step: " + root._name, false, "timed out: " + root.j(root.reqs.slice(-2)));
                root._cond = null;
                root.finish();
            }
        }
    }
    function last() { return root.reqs.length ? root.reqs[root.reqs.length - 1] : null; }
    function settled() { return !ddc.pending("DP-1") && !ddc.busy("DP-1") && root.reqs.length > 0 && root.last().pending === false; }

    Component.onCompleted: {
        if (root.dir === "") {
            console.log("ODL RESULT PASS (not driven: no runner env)");
            Qt.callLater(Qt.quit);
            return;
        }
        // the laptop's backlight: a fake sysfs, the stub brightnessctl; the OSD's own sources stay offline
        const bl = svc.sources.backlight;
        bl.live = true;
        bl.sysfsRoot = root.dir + "/sysbl";
        bl.device = "stub0";
        svc._autoDelay = 100000;
        if (root.mode === "ok")
            root.sCold();
        else if (root.mode === "slow")
            root.until("warm: read by itself", () => ddc.stateOf("DP-1") === "ok", 40000, root.sSlow);
        else
            root.until("warm: read by itself", () => ddc.stateOf("DP-1") === "ok", 25000, root.sIgnore);
    }

    // the very first key press after start (the detect has not answered): the external, a card at once, NO write to the panel
    function sCold() {
        svc.brightness("up");
        root.until("a first card", () => root.reqs.length >= 1, 3000, function () {
            const r = root.last();
            root.check("the first press shows a card at once: pending, naming the display (the laptop's name never)", r.pending === true && r.device.name === "DELL U2723QE" && r.source !== "mock", root.j(r));
            root.until("settled", () => ddc.detected && root.settled(), 30000, function () {
                const r2 = root.last();
                root.check("the kept press lands: the goal 55 shown, pending fell on the write", Math.abs(r2.value - 0.55) < 0.005 && r2.pending === false && r2.ddcState === "ok", root.j(r2));
                root.lines("ddcutil.log", c => {
                    root.check("ONE write, of 55 (50 + the press), no matter how late the display was found", root.sets(c).length === 1 && root.sets(c)[0].indexOf("setvcp 10 55 ") === 0, root.j(c));
                    root.lines("bctl.log", b => {
                        root.check("the laptop's brightnessctl log stays EMPTY", b.length === 0, root.j(b));
                        root.sBurst();
                    });
                });
            });
        });
    }

    // ten presses in 300 ms: one or two writes, the final goal
    property int pressed: 0
    function sBurst() {
        root.reqs = [];
        root.pressed = 0;
        burst.start();
    }
    Timer {
        id: burst
        interval: 30; repeat: true
        onTriggered: {
            svc.brightness("up");
            if (++root.pressed >= 10) {
                burst.stop();
                root.until("burst settled", () => root.reqs.length >= 10 && !ddc.pending("DP-1") && !ddc.busy("DP-1") && root.last().pending === false, 20000, function () {
                    root.lines("ddcutil.log", c => {
                        const s = root.sets(c);
                        root.check("ten presses in 300 ms: at most three more writes (a write takes 0.2 s: the first, the newest at its end, the last), the last is 100", s.length >= 2 && s.length <= 4 && s[s.length - 1].indexOf("setvcp 10 100 ") === 0 && s[s.length - 1].indexOf("--noverify") > 0, root.j(s));
                        root.check("the card says 100, settled", Math.abs(root.last().value - 1) < 0.005 && root.last().pending === false, root.j(root.last()));
                        root.sLaptop();
                    });
                });
            }
        }
    }

    // pointer on the laptop while the external is focused: the panel, and the external's log does not move
    function sLaptop() {
        root.lines("ddcutil.log", c0 => {
            svc.focusedScreen = "DP-1";
            svc.hyprctl = root.dir + "/bin/hyprctl_a";
            svc._bGesture = null;
            root.reqs = [];
            svc.brightness("up");
            root.until("panel card", () => root.reqs.length >= 1, 3000, function () {
                root.wait(300, function () {
                    root.lines("bctl.log", b => {
                        root.lines("ddcutil.log", c1 => {
                            root.check("pointer on the laptop, external focused: brightnessctl set ran, ddcutil asked nothing", b.length >= 1 && b[0].indexOf("-d stub0 set") > 0 && c1.length === c0.length && root.last().pending === undefined, root.j(b) + root.j(c1.slice(c0.length)));
                            root.finish();
                        });
                    });
                });
            });
        });
    }

    // slow ddcutil (3 s a call): the card is up within a turn, the settle comes only with the write's end
    function sSlow() {
        root.reqs = []; root.times = [];
        const t0 = Date.now();
        svc.brightness("up");
        root.until("pending card", () => root.reqs.length >= 1, 3000, function () {
            root.check("pending shows within 600 ms of the press while the write needs 3 s", Date.now() - t0 < 600 && root.reqs[0].pending === true && Math.abs(root.reqs[0].value - 0.55) < 0.005, (Date.now() - t0) + " " + root.j(root.reqs[0]));
            root.until("settled", () => root.settled(), 30000, function () {
                const dt = Date.now() - t0;
                root.check("settled only when the write (and its verification read) ended: >= 5.5 s", dt >= 5500, String(dt));
                root.check("the card stayed up meanwhile: asked for again while pending", root.reqs.filter(r => r.pending === true).length >= 3, String(root.reqs.length));
                root.finish();
            });
        });
    }

    // the monitor ignores the request: failing once, the card says so, later presses probe nothing
    function sIgnore() {
        svc.brightness("up");
        root.until("failing card", () => root.reqs.length > 0 && root.last().ddcState === "failing", 20000, function () {
            root.check("an ignoring display: an unavailable card with the reason", root.last().unavailable === true && root.last().note === "the display ignored the request" && root.last().pending === false, root.j(root.last()));
            root.lines("ddcutil.log", c0 => {
                root.reqs = [];
                svc._bGesture = null;
                svc.brightness("up");
                root.until("card one", () => root.reqs.length >= 1, 3000, function () {
                svc._bGesture = null;
                svc.brightness("up");
                root.until("two cards", () => root.reqs.length >= 2, 3000, function () {
                    root.wait(500, function () {
                        root.lines("ddcutil.log", c1 => {
                            root.check("later presses say so again and re-probe nothing", c1.length === c0.length && root.reqs.every(r => r.unavailable === true), root.j(c1.slice(c0.length)));
                            root.finish();
                        });
                    });
                });
                });
            });
        });
    }

    function finish(): void {
        console.log("ODL RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks)");
        quitTimer.start();
    }
    Timer { id: quitTimer; interval: 0; onTriggered: Qt.quit() }
}
