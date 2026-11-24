import QtQuick
import Quickshell
import Quickshell.Io
import "modules/panorama/data"

// tools/dev/qml/panorama_ddc_r2.qml -- DdcClient, round 2: detect by itself, no connector line, a real max, pending goals, one verified
// first write, failing remembered, scrubbing at rest. Scenario = PDR_MODE (the stub ddcutil in PDR_W/bin reads it too):
//   ok | slow | noconn | nobusmap | ignore | getfail | detectfail | scrub
// Prints "PDR ok|FAIL <name>" and "PDR RESULT PASS|FAIL".
Scope {
    id: root
    property string dir: Quickshell.env("PDR_W")
    property string mode: Quickshell.env("PDR_MODE")
    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("PDR " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }
    function j(v: var): string { return JSON.stringify(v); }

    readonly property bool nv: root.mode === "noconn" || root.mode === "nobusmap"
    readonly property string ext: root.nv ? "DP-3" : "DP-1"
    readonly property var outs: root.nv
        ? [{ name: "eDP-1", description: "Sharp" }, { name: "DP-3", description: root.mode === "nobusmap" ? "Something Else" : "Acer Technologies VG240Y 0x1" }, { name: "HDMI-A-1", description: "Dell Inc. DELL U2723QE 7ZQ4PX3" }]
        : [{ name: "eDP-1", description: "Sharp" }, { name: "DP-1", description: "Dell Inc. DELL U2723QE 7ZQ4PX3" }]
    property var changed: []
    property var statesSeen: []
    DdcClient {
        id: ddc
        live: true
        program: root.dir + "/bin/ddcutil"
        sysRoot: root.dir + "/sys"
        outputs: root.outs
        timeoutMs: 8000
        onValueChanged: n => { root.changed.push(n); if (n === root.ext) root.statesSeen.push(ddc.stateOf(n) + (ddc.pending(n) ? "+p" : "")); }
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
    function calls(then: var): void {
        root.run("cat '" + root.dir + "/ddcutil.log' 2>/dev/null", function (t) {
            then(t.split("\n").filter(l => l.trim() !== "").map(l => l.trim().split(" ").slice(1).join(" ")));
        });
    }
    function n(list: var, verb: string): int { return list.filter(a => a.indexOf(verb) === 0).length; }
    function sets(list: var): var { return list.filter(a => a.indexOf("setvcp") === 0); }

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
        interval: 30; running: true; repeat: true
        onTriggered: {
            if (!root._cond)
                return;
            if (root._cond()) {
                const f = root._then; root._cond = null; root._then = null;
                if (f) f();
            } else if (Date.now() > root._deadline) {
                root.check("step: " + root._name, false, "timed out");
                root._cond = null;
                root.finish();
            }
        }
    }

    Component.onCompleted: {
        if (root.dir === "") {
            console.log("PDR RESULT PASS (not driven: no runner env)");
            Qt.callLater(Qt.quit);
            return;
        }
        // nothing is called: the outputs alone make the client look
        if (root.mode === "slow") {
            // the cold start: six presses before anything was looked for (3 s a call: the detect and the read are still out)
            let acc = true;
            for (let i = 0; i < 6; i++)
                acc = ddc.adjust("DP-1", 5) && acc;
            root.check("cold: every press is taken before the value is known", acc && ddc.pending("DP-1"), String(acc));
            root.until("settled", () => ddc.detected && !ddc.pending("DP-1") && !ddc.busy("DP-1") && ddc.value("DP-1") === 80, 60000, root.sSlow);
            return;
        }
        if (root.mode === "detectfail")
            root.until("detect answered", () => !ddc.detecting && ddc.detectedFor !== "", 12000, root.sFailDetect);
        else if (root.mode === "getfail")
            root.until("read failed", () => ddc.stateOf(root.ext) === "failing", 12000, root.sGetFail);
        else
            root.until("detected and read by itself", () => ddc.detected && ddc.value(root.ext) === 50, 25000, root.start);
    }

    function start() {
        root.check("no call of ours: detected from the outputs alone, the value read", ddc.stateOf(root.ext) === "ok" && ddc.capable(root.ext), ddc.stateOf(root.ext));
        root.check("the real maximum (255) is read, not 100", ddc.max(root.ext) === 255, String(ddc.max(root.ext)));
        root.check("detectedFor is the output signature", ddc.detectedFor === (root.nv ? "DP-3,HDMI-A-1,eDP-1" : "DP-1,eDP-1"), ddc.detectedFor);
        if (root.nv) {
            root.check("a block with no connector line is matched (" + root.mode + ")", ddc.capable("DP-3") && ddc.capable("HDMI-A-1"), root.j(Object.keys(ddc.displays)));
            root.calls(c => { root.check("every call names the right bus", c.indexOf("getvcp 10 --brief --bus 6 --skip-ddc-checks") >= 0, root.j(c)); root.next(); });
            return;
        }
        root.next();
    }
    function next() {
        if (root.mode === "ok") root.sOk();
        else if (root.mode === "slow") root.sSlow();
        else if (root.mode === "ignore") root.sIgnore();
        else if (root.mode === "scrub") root.sScrub();
        else root.finish();
    }

    // 10 presses in 300 ms: one or two setvcp, the final goal, the first verified, pending at once and settled at the write's end
    function sOk() {
        root.statesSeen = [];
        let acc = true;
        for (let i = 0; i < 10; i++)
            acc = ddc.adjust("DP-1", 5) && acc;
        root.check("every press is taken", acc, "");
        root.check("pending shows within the turn, the goal is value + 10 steps", ddc.pending("DP-1") && ddc.goal("DP-1") === 100 && ddc.value("DP-1") === 100, ddc.goal("DP-1") + " " + ddc.pending("DP-1"));
        root.until("settled", () => !ddc.pending("DP-1") && !ddc.busy("DP-1"), 12000, function () {
            root.calls(c => {
                const s = root.sets(c);
                root.check("10 presses are one or two setvcp calls ending on the goal", s.length >= 1 && s.length <= 2 && s[s.length - 1].indexOf("setvcp 10 100 ") === 0, root.j(s));
                root.check("the FIRST write is verified (no --noverify)", s[0].indexOf("--noverify") < 0, s[0]);
                root.check("pending fell on the write: the figure stayed", ddc.value("DP-1") === 100 && root.statesSeen.indexOf("ok") >= 0, root.j(root.statesSeen));
                root.s0 = root.n(c, "getvcp"); root.w0 = s.length;
                ddc.adjust("DP-1", -5);
                root.until("second write", () => !ddc.pending("DP-1") && !ddc.busy("DP-1"), 8000, function () {
                    root.calls(c2 => {
                        const s2 = root.sets(c2);
                        root.check("a later write goes with --noverify and no read-back", s2.length === root.w0 + 1 && s2[s2.length - 1].indexOf("--noverify") > 0 && root.n(c2, "getvcp") === root.s0, root.j(s2));
                        root.check("the detect ran once for the whole session", root.n(c2, "detect") === 1, String(root.n(c2, "detect")));
                        root.finish();
                    });
                });
            });
        });
    }
    property int s0: 0
    property int w0: 0

    // slow stub (3 s a call): the six presses of the cold start are one goal, none lost
    function sSlow() {
        root.calls(c => {
            const s = root.sets(c);
            root.check("cold: ONE write for the six presses, 50 + 6 x 5", s.length === 1 && s[0].indexOf("setvcp 10 80 ") === 0, root.j(s));
            root.finish();
        });
    }

    function sIgnore() {
        ddc.adjust("DP-1", 5);
        root.until("failing", () => ddc.stateOf("DP-1") === "failing", 15000, function () {
            root.check("an ignoring monitor ends failing, with the reason", ddc.reasonOf("DP-1") === "the display ignored the request" && !ddc.pending("DP-1"), ddc.reasonOf("DP-1"));
            root.check("the figure is taken back to what the display said", ddc.value("DP-1") === 50, String(ddc.value("DP-1")));
            root.calls(c => {
                root.w0 = c.length;
                const a = ddc.adjust("DP-1", 5), b = ddc.adjust("DP-1", 5);
                root.wait(600, function () {
                    root.calls(c2 => {
                        root.check("later presses are refused and re-probe nothing", a === false && b === false && c2.length === root.w0, root.j(c2.slice(root.w0)));
                        root.finish();
                    });
                });
            });
        });
    }

    function sGetFail() {
        root.check("a failing read: state failing with ddcutil's words", ddc.reasonOf(root.ext).indexOf("DDC communication failed") >= 0, ddc.reasonOf(root.ext));
        root.calls(c => {
            root.w0 = c.length;
            const a = ddc.adjust(root.ext, 5);
            root.wait(500, function () {
                root.calls(c2 => {
                    root.check("a press on a failing display is refused, nothing is probed again", a === false && c2.length === root.w0, root.j(c2.slice(root.w0)));
                    root.finish();
                });
            });
        });
    }

    function sFailDetect() {
        root.check("detect exit 1: every external failing, with the reason", ddc.stateOf("DP-1") === "failing" && ddc.detected === false && ddc.reasonOf("DP-1") !== "", ddc.stateOf("DP-1") + ddc.reasonOf("DP-1"));
        root.check("a press is refused", ddc.adjust("DP-1", 5) === false, "");
        root.calls(c => {
            root.w0 = root.n(c, "detect");
            ddc.ensureDetected();
            root.wait(500, function () {
                root.calls(c2 => {
                    root.check("ensureDetected inside the retry window asks nothing", root.n(c2, "detect") === root.w0, String(root.n(c2, "detect")));
                    root.finish();
                });
            });
        });
    }

    function sScrub() {
        ddc.scrub("DP-1", 60); ddc.scrub("DP-1", 61); ddc.scrub("DP-1", 62);
        root.check("scrub: the figure and pending follow the hand at once", ddc.value("DP-1") === 62 && ddc.pending("DP-1"), String(ddc.value("DP-1")));
        root.wait(120, function () {
            root.calls(c => {
                root.check("scrub: nothing is written while the hand moves", root.sets(c).length === 0, root.j(root.sets(c)));
                root.until("rest write", () => !ddc.pending("DP-1") && !ddc.busy("DP-1"), 8000, function () {
                    root.calls(c2 => {
                        const s = root.sets(c2);
                        root.check("scrub: ONE write after the rest, the last value", s.length === 1 && s[0].indexOf("setvcp 10 62 ") === 0, root.j(s));
                        ddc.scrub("DP-1", 30);
                        ddc.commit("DP-1");
                        root.until("commit write", () => !ddc.pending("DP-1") && !ddc.busy("DP-1"), 8000, function () {
                            root.calls(c3 => {
                                root.check("commit writes at once", root.sets(c3).length === 2 && root.sets(c3)[1].indexOf("setvcp 10 30 ") === 0, root.j(root.sets(c3)));
                                root.finish();
                            });
                        });
                    });
                });
            });
        });
    }

    function finish(): void {
        console.log("PDR RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + ")");
        quitTimer.start();
    }
    Timer { id: quitTimer; interval: 0; onTriggered: Qt.quit() }
}
