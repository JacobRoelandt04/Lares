pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell

import "modules/common/theme"
import "modules/bar/system_update/components"

// =============================================================================
// su_check_failed_probe.qml -- a failed update check says WHY in words, a partial list says which source was not checked (commit c90d8ce1).
// The REAL SystemUpdatePopup over a REAL AvailableUpdatesService in its mock mode (no yay, no pacman, no network, no cache): a source's probe
// is staged failing through the service's own `_finishSource(source, count, stderr)` -- the call every real probe ends in -- with the stderr texts
// the tools print. The card's two Texts (headline, line under it) are read:
//   no packages, aur fails with a resolver error      "Could not check for updates" / "No connection to the network"
//   no packages, only aur fails (other text)          "The AUR did not answer"
//   no packages, only official fails                  "A mirror failed to answer"
//   no packages, official + aur fail                  "Some sources did not answer"
//   3 packages, aur fails                             "3 updates available" / "AUR not checked"
//   3 packages, official + aur fail                   "Official repos and AUR not checked"
//   3 packages, nothing fails                         no "not checked" line, no failure words
//   the tool's raw text (error: failed retrieving ..) is never on the card
// Run by tools/dev/su_check_failed_probe.sh; bare it quits at once (no SCF_RUN). One `SCF ok|FAIL <id>: what` line per check, then `SCF DONE PASS|FAIL`.
// =============================================================================
ShellRoot {
    id: probe
    settings.watchFiles: false
    readonly property bool run: Quickshell.env("SCF_RUN") === "1"
    property int checks: 0
    property int fails: 0
    function check(id: string, ok: bool, what: string): void {
        probe.checks++;
        if (!ok)
            probe.fails++;
        console.log("SCF " + (ok ? "ok  " : "FAIL ") + id + ": " + what);
    }
    Timer { interval: 0; running: !probe.run; onTriggered: Qt.quit() }

    AvailableUpdatesService {
        id: svc
        mockMode: true
        cacheEnabled: false
        mockSpec: ({})
    }

    Window {
        id: win
        visible: probe.run
        width: 520
        height: 760
        color: Theme.surface
        SystemUpdatePopup {
            id: popup
            anchors.fill: parent
            availableUpdates: svc
            idleSubtextDelayMs: 40
        }
    }

    // every Text of the popup whose text is one of the words (the card's headline / sub line are plain Texts)
    function textsOf(item: Item, out: var): var {
        if (!item)
            return out;
        if (typeof item.text === "string" && item.text.length > 0 && item.visible && item.opacity > 0.99)   // qmllint disable missing-property
            out.push(item.text);   // qmllint disable missing-property
        for (let i = 0; i < item.children.length; i++)
            probe.textsOf(item.children[i], out);
        return out;
    }
    function shown(): var { return probe.textsOf(popup, []); }
    function has(t: string): bool { return probe.shown().indexOf(t) >= 0; }

    // stage a check: `spec` rows come from the mock probe, each failure is a source ending in stderr, as the real probes do
    function stage(spec: var, failures: var): void {
        svc.mockSpec = spec;
        svc.refresh();
        for (const f of failures) {
            svc._pendingSources += 1;   // qmllint disable missing-property
            svc._finishSource(f[0], 0, f[1]);   // qmllint disable missing-property
        }
    }
    function scenario(id: string, spec: var, failures: var, head: string, sub: string, what: string): var {
        let started = false;
        return w => {
            if (!started) {
                if (svc.refreshing)
                    return "wait";
                started = true;
                probe.stage(spec, failures);
                return "wait";
            }
            if (svc.refreshing || !probe.has(head) || (sub !== "" && !probe.has(sub))) {
                if (w < 6000)
                    return "wait";
                probe.check(id, false, what + ": wanted '" + head + "' / '" + sub + "', the card shows " + JSON.stringify(probe.shown().slice(0, 12)));
                return true;
            }
            probe.check(id, true, what + " ('" + head + "' / '" + sub + "')");
            return true;
        };
    }
    // a scenario's second look: words that must NOT be on the card
    function absent(id: string, bad: var, what: string): var {
        return () => {
            const shown = probe.shown().join("\n");
            const hit = bad.filter(b => shown.indexOf(b) >= 0);
            probe.check(id, hit.length === 0, what + (hit.length ? " -- on the card: " + JSON.stringify(hit) : ""));
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
                console.log("SCF DONE " + (probe.fails === 0 && probe.checks > 0 ? "PASS" : "FAIL") + " (" + (probe.checks - probe.fails) + "/" + probe.checks + ")");
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
        const RAW = "error: failed retrieving file 'core.db' from mirror.example : The requested URL returned error: 503";
        probe.steps = [
            probe.scenario("net", {}, [["aur", "error: Could not resolve host: aur.archlinux.org"]], "Could not check for updates", "No connection to the network", "a resolver failure says the network is down"),
            probe.absent("net.raw", ["Could not resolve host", "aur:"], "the tool's raw line is not on the card"),
            probe.scenario("aur", {}, [["aur", RAW]], "Could not check for updates", "The AUR did not answer", "only the AUR failing says so"),
            probe.absent("aur.raw", ["failed retrieving", "503"], "the raw pacman text is not on the card"),
            probe.scenario("official", {}, [["official", RAW]], "Could not check for updates", "A mirror failed to answer", "only the official repos failing says a mirror"),
            probe.scenario("both", {}, [["official", RAW], ["aur", RAW]], "Could not check for updates", "Some sources did not answer", "two sources failing say so"),
            probe.scenario("partial", { core: 3 }, [["aur", RAW]], "3 updates available", "AUR not checked", "updates found but the AUR failed: the list is partial"),
            probe.scenario("partial.two", { core: 3 }, [["official", RAW], ["aur", RAW]], "3 updates available", "Official repos and AUR not checked", "two sources missing are both named"),
            probe.scenario("healthy", { core: 3 }, [], "3 updates available", "", "a clean check lists the updates"),
            w => w < 400 ? "wait" : true,
            probe.absent("healthy.quiet", ["not checked", "did not answer", "No connection", "Could not check"], "a clean check says no failure and no 'not checked'")
        ];
        probe.stepStarted = Date.now();
        driver.start();
    })
}
