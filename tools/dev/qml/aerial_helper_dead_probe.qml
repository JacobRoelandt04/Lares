pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell

import "modules/aerial/data"
import "modules/aerial/popup"
import "modules/aerial/bar"
import "modules/common/theme"

// =============================================================================
// aerial_helper_dead_probe.qml -- a dead network helper is SAID (commit eef271f7). The REAL AerialPopup (the board's label) and the REAL AerialBarButton (the bar
// pill) over one AerialMock (scenario `airplane`: nothing docked, so the label's idle line shows) whose `helper` fact is played failed and healthy again. Read from properties:
//   healthy               the label's zone says "airplane mode" and no helper words; the pill does not warn (`pill.fault` "", `_warnNet` 0)
//   helper failed         a Text of the popup reads "Network helper not running: <error>" (the helper words outrank airplane's); the pill's fault is "warn" and its warn
//                         fraction `_warnNet` settles at 1 (the glyph takes the warn lamp)
//   helper back           the words are gone, "airplane mode" is back, the pill stops warning
// Run by tools/dev/aerial_helper_dead_probe.sh; bare it quits at once (no AHD_RUN). One `AHD ok|FAIL <id>: what` line per check, then `AHD DONE PASS|FAIL`.
// =============================================================================
ShellRoot {
    id: probe
    settings.watchFiles: false
    readonly property bool run: Quickshell.env("AHD_RUN") === "1"
    property int checks: 0
    property int fails: 0
    function check(id: string, ok: bool, what: string): void {
        probe.checks++;
        if (!ok)
            probe.fails++;
        console.log("AHD " + (ok ? "ok  " : "FAIL ") + id + ": " + what);
    }
    Timer { interval: 0; running: !probe.run; onTriggered: Qt.quit() }

    readonly property string deadError: "the network helper exited (1)"
    readonly property string deadWords: "Network helper not running: " + probe.deadError

    AerialMock {
        id: mock
        live: probe.run
        scenario: "airplane"
        drift: 0
        scanPeriodMs: 100000
        settleMs: 150
    }

    Window {
        id: win
        visible: probe.run
        width: 1100
        height: 760
        color: Theme.surface
        AerialPopup {
            id: popup
            service: mock
            family: 0
            renderScale: 1
            animate: false
            entranceEnabled: false
            soundsEnabled: false
        }
        AerialBarButton {
            id: pillBtn
            x: 900
            y: 20
            service: mock
        }
    }

    function textsOf(item: Item, out: var): var {
        if (!item)
            return out;
        if (typeof item.text === "string" && item.text.length > 0 && item.visible)   // qmllint disable missing-property
            out.push(item.text);   // qmllint disable missing-property
        for (let i = 0; i < item.children.length; i++)
            probe.textsOf(item.children[i], out);
        return out;
    }
    function labelWords(): var { return probe.textsOf(popup, []).filter(t => t.indexOf("Network helper") === 0 || t === "airplane mode"); }
    function labelHas(t: string): bool { return probe.labelWords().indexOf(t) >= 0; }

    // wait for a condition, naming what was read when the time box runs out
    function until(id: string, cond: var, what: string, read: var): var {
        return w => {
            if (cond()) {
                probe.check(id, true, what);
                return true;
            }
            if (w < 5000)
                return "wait";
            probe.check(id, false, what + " -- read: " + read());
            return true;
        };
    }

    property var steps: []
    property int stepAt: 0
    property real stepStarted: 0
    Timer {
        id: driver
        interval: 40
        repeat: true
        onTriggered: {
            if (probe.stepAt >= probe.steps.length) {
                driver.stop();
                console.log("AHD DONE " + (probe.fails === 0 && probe.checks > 0 ? "PASS" : "FAIL") + " (" + (probe.checks - probe.fails) + "/" + probe.checks + ")");
                Qt.quit();
                return;
            }
            const waited = Date.now() - probe.stepStarted;
            let r = true;
            try {
                r = probe.steps[probe.stepAt](waited);
            } catch (e) {
                probe.check("step" + probe.stepAt, false, "threw: " + e);
            }
            if (r === "wait")
                return;
            probe.stepAt++;
            probe.stepStarted = Date.now();
        }
    }
    Component.onCompleted: Qt.callLater(() => {
        if (!probe.run) {
            Qt.quit();
            return;
        }
        const words = () => JSON.stringify(probe.labelWords());
        probe.steps = [
            probe.until("label.healthy", () => probe.labelHas("airplane mode") && !probe.labelHas(probe.deadWords), "a healthy helper: the label says 'airplane mode', no helper words", words),
            probe.until("pill.healthy", () => pillBtn.pill.fault === "" && pillBtn._warnNet === 0, "a healthy helper: the pill does not warn", () => pillBtn.pill.fault + " / " + pillBtn._warnNet),
            () => { mock._set("helper", { state: "failed", error: probe.deadError }); },
            probe.until("label", () => probe.labelHas(probe.deadWords) && !probe.labelHas("airplane mode"), "a failed helper: the label says '" + probe.deadWords + "' instead of 'airplane mode'", words),
            probe.until("pill.fault", () => pillBtn.pill.fault === "warn" && pillBtn.pill.helperFailed, "a failed helper: the pill's fault is warn", () => pillBtn.pill.fault + " / " + pillBtn.pill.helperFailed),
            probe.until("pill.glyph", () => pillBtn._warnNet === 1, "a failed helper: the glyph's warn fraction settles at 1", () => String(pillBtn._warnNet)),
            () => { mock._set("helper", { state: "up", error: "" }); },
            probe.until("label.back", () => probe.labelHas("airplane mode") && !probe.labelHas(probe.deadWords), "the helper is back: 'airplane mode' returns, the helper words go", words),
            probe.until("pill.back", () => pillBtn.pill.fault === "" && pillBtn._warnNet === 0, "the helper is back: the pill stops warning", () => pillBtn.pill.fault + " / " + pillBtn._warnNet)
        ];
        probe.stepStarted = Date.now();
        driver.start();
    })
}
