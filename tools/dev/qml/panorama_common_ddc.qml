import QtQuick
import Quickshell
import Quickshell.Io
import "modules/panorama/data"

// tools/dev/qml/panorama_common_ddc.qml -- DdcClient against a stub ddcutil (PCOM_W/bin/ddcutil: prints the captured detect
// bytes, answers getvcp from a value file, logs every argv). Prints "PCC ok|FAIL <name>" lines and "PCC RESULT PASS|FAIL".
Scope {
    id: root
    property string dir: Quickshell.env("PCOM_W")
    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("PCC " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }
    function j(v: var): string {
        return JSON.stringify(v);
    }

    QtObject {
        id: fakeDrm
        property var connectors: [{ name: "DVI-I-1", driver: "evdi", status: "connected" }, { name: "DP-1", driver: "i915", status: "connected" }]
        signal changed
    }
    property var changedLog: []
    DdcClient {
        id: ddc
        live: true
        program: root.dir + "/bin/ddcutil"
        directProgram: root.dir + "/bin/lares-ddc"
        sysRoot: root.dir + "/sys"
        drm: fakeDrm
        timeoutMs: 1500
        onValueChanged: connector => root.changedLog.push(connector)
    }

    Process { id: sh; stdout: StdioCollector { id: shOut } }
    property var cont: null
    function run(cmd: string, then: var): void {
        root.cont = then;
        sh.command = ["sh", "-c", cmd];
        sh.running = true;
    }
    Connections {
        target: sh
        function onExited() {
            const f = root.cont;
            root.cont = null;
            if (f)
                f(shOut.text);
        }
    }
    // the stub's log as [{ t, argv }]
    function calls(then: var): void {
        root.run("cat '" + root.dir + "/ddcutil.log' 2>/dev/null", function (t) {
            then(t.split("\n").filter(l => l.trim() !== "").map(l => l.trim().split(" ").slice(1).join(" ")));
        });
    }
    function count(list: var, verb: string): int {
        return list.filter(a => a.indexOf(verb) === 0).length;
    }

    property real _deadline: 0
    property var _cond: null
    property var _then: null
    property string _name: ""
    function until(name: string, cond: var, ms: int, then: var): void {
        root._name = name; root._cond = cond; root._deadline = Date.now() + ms; root._then = then;
    }
    function wait(ms: int, then: var): void {
        const t = Date.now() + ms;
        root.until("wait", () => Date.now() >= t, ms + 2000, then);
    }
    Timer {
        interval: 40
        running: true
        repeat: true
        onTriggered: {
            if (!root._cond)
                return;
            if (root._cond()) {
                const f = root._then;
                root._cond = null;
                root._then = null;
                if (f)
                    f();
            } else if (Date.now() > root._deadline) {
                root.check("step: " + root._name, false, "timed out");
                root._cond = null;
                root.finish();
            }
        }
    }

    property int detects0: 0
    Component.onCompleted: {
        root.check("nothing asked before detect(): no capable display, no value", ddc.capable("DP-1") === false && ddc.value("DP-1") === -1 && ddc.detected === false, "");
        ddc.detect();
        root.until("detected and read", () => ddc.detected && ddc.value("DP-1") === 50 && ddc.error("HDMI-A-1") !== "", 15000, root.s2);
    }

    function s2() {
        root.check("capable: DP-1 and HDMI-A-1 yes; an eDP that answers DDC never", ddc.capable("DP-1") && ddc.capable("HDMI-A-1") && !ddc.capable("eDP-1") && !ddc.capable("nothing"), root.j(Object.keys(ddc.displays)));
        // (the user's dock, 2026-11-23: ddcutil refuses evdi's bus, which answers DDC/CI all the same; ARMs evdiddcutil, evdiblocked)
        root.check("the DisplayLink output is capable on its connector's own bus (21, from sysfs), whatever ddcutil lists for it", ddc.capable("DVI-I-1") && ddc.displays["DVI-I-1"].bus === 21 && ddc.displays["DVI-I-1"].direct === true, root.j(ddc.displays["DVI-I-1"]));
        root.check("value and max read from `VCP 10 C 50 100`", ddc.value("DP-1") === 50 && ddc.max("DP-1") === 100, String(ddc.value("DP-1")));
        root.check("a display that hangs is an error after the timeout, the lane goes on", ddc.error("HDMI-A-1").indexOf("no answer") === 0 && ddc.value("HDMI-A-1") === -1, ddc.error("HDMI-A-1"));
        root.check("adjust on an unknown value says no", ddc.adjust("HDMI-A-1", 5) === false, "");
        root.calls(function (c) {
            const bad = c.filter(a => (a.indexOf("getvcp") === 0 || a.indexOf("setvcp") === 0) && !/ --bus \d+( |$)/.test(a));
            root.check("every call names its bus", c.length >= 3 && bad.length === 0, root.j(bad));
            // (ddcutil's own start-up checks take six seconds on the laptop's NVIDIA HDMI: every call skips them; ARM slowchecks)
            root.check("every call skips ddcutil's start-up checks", c.filter(a => (a.indexOf("getvcp") === 0 || a.indexOf("setvcp") === 0) && a.indexOf("--skip-ddc-checks") < 0).length === 0, root.j(c));
            root.check("ddcutil is never asked for the DisplayLink output or the eDP (buses 9, 21, 3)", c.filter(a => / --bus (9|21|3)( |$)/.test(a)).length === 0, root.j(c));
            root.check("the DisplayLink output is read by the direct tool: `direct get 21`, its figure 40", c.indexOf("direct get 21") >= 0 && ddc.value("DVI-I-1") === 40, root.j(c) + " v=" + ddc.value("DVI-I-1"));
            root.check("getvcp 10 --brief --bus 5 for DP-1", c.indexOf("getvcp 10 --brief --bus 5 --skip-ddc-checks") >= 0, root.j(c));
            root.reads0 = root.count(c, "getvcp");
            ddc.read("DP-1", false);
            root.wait(500, root.s3);
        });
    }
    property int reads0: 0
    function s3() {
        root.calls(function (c) {
            root.check("value cached: a second read inside 60 s asks nothing", root.count(c, "getvcp") === root.reads0, root.count(c, "getvcp") + "/" + root.reads0);
            ddc.read("DP-1", true);
            root.wait(800, function () {
                root.calls(function (c2) {
                    root.check("... and a forced read asks once", root.count(c2, "getvcp") === root.reads0 + 1, String(root.count(c2, "getvcp")));
                    root.s4();
                });
            });
        });
    }
    function s4() {
        root.changedLog = [];
        for (let v = 61; v <= 65; v++)
            ddc.set("DP-1", v);
        root.check("the figure follows the hand at once", ddc.value("DP-1") === 65 && root.changedLog.indexOf("DP-1") >= 0, String(ddc.value("DP-1")));
        root.wait(1800, function () {
            root.calls(function (c) {
                const sets = c.filter(a => a.indexOf("setvcp") === 0);
                root.check("five sets in a burst are coalesced: the first (verified) and the newest", sets.length === 2 && sets[0] === "setvcp 10 61 --bus 5 --skip-ddc-checks" && sets[1] === "setvcp 10 65 --bus 5 --skip-ddc-checks --noverify", root.j(sets));
                root.sets0 = sets.length;
                root.check("adjust moves from the newest target", ddc.adjust("DP-1", -5) === true && ddc.value("DP-1") === 60, String(ddc.value("DP-1")));
                root.wait(1200, root.s5);
            });
        });
    }
    property int sets0: 0
    function s5() {
        root.calls(function (c) {
            const sets = c.filter(a => a.indexOf("setvcp") === 0);
            root.check("... one call for it", sets.length === root.sets0 + 1 && sets[sets.length - 1] === "setvcp 10 60 --bus 5 --skip-ddc-checks --noverify", root.j(sets));
            ddc.set("DVI-I-1", 10);
            ddc.set("eDP-1", 10);
            root.wait(500, function () {
                root.calls(function (c2) {
                    root.check("a set on an eDP asks nothing, one on the DisplayLink output no ddcutil", root.count(c2, "setvcp") === root.sets0 + 1, String(root.count(c2, "setvcp")));
                    root.check("... it is ONE `direct set 21 10`, read back, and the figure follows", c2.filter(a => a.indexOf("direct set") === 0).join("|") === "direct set 21 10" && ddc.value("DVI-I-1") === 10 && ddc.error("DVI-I-1") === "", root.j(c2.filter(a => a.indexOf("direct") === 0)) + " v=" + ddc.value("DVI-I-1") + " e=" + ddc.error("DVI-I-1"));
                    root.detects0 = root.count(c2, "detect");
                    fakeDrm.changed();
                    root.wait(800, root.s6);
                });
            });
        });
    }
    function s6() {
        root.calls(function (c) {
            root.check("a drm change after a detect runs it again", root.count(c, "detect") === root.detects0 + 1, root.count(c, "detect") + "/" + root.detects0);
            root.finish();
        });
    }
    function finish(): void {
        console.log("PCC RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + ")");
        quitTimer.start();
    }
    Timer { id: quitTimer; interval: 0; onTriggered: Qt.quit() }
}
