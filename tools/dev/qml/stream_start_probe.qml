pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "modules/common/components"
import "modules/osd/data/sources"

// tools/dev/qml/stream_start_probe.qml -- a SupervisedStream whose state changes while the config is still LOADING. Quickshell only records a
// start asked for then (`running` reads false until the load is over) and starts the process afterwards. tools/dev/stream_start_probe.sh runs it;
// each child appends its word to SSP_DIR/ran. Prints SSP lines and "SSP RESULT PASS|FAIL".
Scope {
    id: root
    readonly property string dir: Quickshell.env("SSP_DIR")
    readonly property bool bare: !root.dir
    property bool _on: true
    property bool _late: false
    property string _word: "first"
    property string _led: "asus::kbd_backlight"
    property int fails: 0

    function check(name: string, ok: bool, detail: string): void {
        if (!ok)
            root.fails++;
        console.log("SSP " + (ok ? "ok   " : "FAIL ") + name + (ok ? "" : "  [" + detail + "]"));
    }
    function cmd(word: string): var {
        return ["setpriv", "--pdeathsig", "TERM", "--", "sh", "-c", "echo " + word + " >> \"$1/ran\"; exec sleep 60", "sh", root.dir];
    }

    // on from the start, switched off in the parent's onCompleted (a config that loads there)
    SupervisedStream {
        enabled: !root.bare && root._on
        command: root.cmd("off")
        what: "SSP: the one switched off"
    }
    // on from the start, another command in the parent's onCompleted
    SupervisedStream {
        enabled: !root.bare
        command: root.cmd(root._word)
        what: "SSP: the one with another command"
    }
    // on, and left alone
    SupervisedStream {
        enabled: !root.bare
        command: root.cmd("plain")
        what: "SSP: the plain one"
    }
    // off, switched on after the load
    SupervisedStream {
        id: late
        enabled: root._late
        command: root.cmd("late")
        what: "SSP: the late one"
    }
    // the keyboard light with no device (osd.jsonc "kbd": { "device": "" }, read as the OSD completes); its helper is the stub in SSP_DIR
    KbdLightSource {
        live: !root.bare
        device: root._led
        python: root.dir + "/python-stub"
        ledRoot: root.dir
    }
    Component.onCompleted: {
        if (root.bare)
            return;
        root._on = false;
        root._word = "second";
        root._led = "";
    }

    FileView {
        id: ran
        path: root.dir + "/ran"
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }
    function words(): var {
        ran.reload();
        return ran.text().split("\n").filter(w => w !== "");
    }
    property int _tries: 0
    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            if (root.bare) {
                Qt.quit();
                return;
            }
            root._tries++;
            const w = root.words();
            // the plain child's word says the load is over and the starts have been made; half a second more for the ones that must not come
            if (!root._late) {
                if ((w.indexOf("plain") < 0 || w.indexOf("second") < 0) && root._tries < 100)
                    return;
                if (root._tries < 100 && root._tries < root._seenAt + 6) {
                    if (root._seenAt === 0)
                        root._seenAt = root._tries;
                    return;
                }
                root.check("a stream that is left alone starts", w.indexOf("plain") >= 0, w.join(" "));
                root.check("a stream switched off while the config loads starts nothing", w.indexOf("off") < 0, w.join(" "));
                root.check("a stream given another command while the config loads starts that one, once", w.filter(x => x === "second").length === 1 && w.indexOf("first") < 0, w.join(" "));
                root.check("no keyboard light: no helper", w.indexOf("helper") < 0, w.join(" "));
                root._late = true;
                root._tries = 0;
                return;
            }
            if (w.indexOf("late") < 0 && root._tries < 60)
                return;
            root.check("a stream switched on after the load starts", w.indexOf("late") >= 0 && late.running, w.join(" "));
            console.log("SSP RESULT " + (root.fails === 0 ? "PASS" : "FAIL"));
            Qt.quit();
        }
    }
    property int _seenAt: 0
}
