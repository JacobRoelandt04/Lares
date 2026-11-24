import QtQuick
import Quickshell
import Quickshell.Io
import "modules/silicon/data"

// tools/dev/qml/boost_client_probe.qml -- BoostClient against a stub server on BC_SOCK (tools/dev/boost_client_probe.sh runs
// it). Prints BC lines and "BC RESULT PASS|FAIL". The runner then holds the stub's own log to the asks that must have arrived.
Scope {
    id: root
    property int fails: 0
    property int checks: 0

    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("BC " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    BoostClient { id: live; wanted: true; socketPath: Quickshell.env("BC_SOCK") || "" }
    BoostClient { id: missing; wanted: true; socketPath: (Quickshell.env("BC_SOCK") || "") + ".missing" }
    BoostClient { id: off; wanted: false; socketPath: Quickshell.env("BC_SOCK") || "" }

    // the stub's own log: the close must reach the server while the shell runs, not at its exit
    FileView { id: stubLog; path: Quickshell.env("BC_LOG") || ""; printErrors: false; blockLoading: true }

    property int step: 0
    property int ticks: 0

    // each step waits on a condition, never on a time (a cap of ticks is the failsafe)
    Timer {
        id: driver
        interval: 20
        repeat: true
        running: true
        onTriggered: {
            root.ticks++;
            if (root.ticks > 400) {
                root.check("step " + root.step + " came to pass", false, "timed out");
                root.finish();
                return;
            }
            switch (root.step) {
            case 0:
                if (live.status !== "on" || missing.status !== "absent")
                    return;
                root.check("the service is seen (on), a missing one is absent, a key that is off is off",
                           live.status === "on" && missing.status === "absent" && off.status === "off", live.status + " " + missing.status + " " + off.status);
                live.kick(300);
                break;
            case 1:
                if (live.stats.written < 1)
                    return;
                // the first ask is written once the lazy connection is up; the next ones are judged against it
                live.kick(200);   // outlasted by the 300 asked: nothing
                live.kick(250);   // the same
                live.kick(800);   // longer: written
                for (let i = 0; i < 5; i++)
                    missing.kick(300);
                off.kick(300);
                root.check("asks the boost already covers write nothing; a longer one is written (2 written of 5 asks)",
                           live.stats.written === 2 && live.stats.asks === 4, JSON.stringify(live.stats));
                root.check("an absent service and a key that is off write nothing",
                           missing.stats.written === 0 && off.stats.written === 0 && missing.status === "absent",
                           JSON.stringify(missing.stats) + " " + JSON.stringify(off.stats));
                live.wanted = false;   // the key goes off: the connection closes (the server puts the floors back)
                break;
            case 2:
                stubLog.reload();
                if (live.status !== "off" || live._sock !== null || stubLog.text().indexOf("CLOSE") < 0)
                    return;
                root.check("the key off closes the connection (the server saw it)", true, "");
                root.finish();
                return;
            }
            root.step++;
            root.ticks = 0;
        }
    }

    function finish(): void {
        driver.running = false;
        console.log("BC RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks)");
        quitTimer.start();
    }
    Timer { id: quitTimer; interval: 300; onTriggered: Qt.quit() }
}
