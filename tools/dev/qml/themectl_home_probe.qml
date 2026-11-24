pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "modules/common/theme"

// The themes' HOME (theme.md L1), seen from the shell: which file does Theme read, and where does a live edit go
// (tools/dev/themectl_home_probe.sh). A script of steps, every fact one `THP ...` line:
//   THP_STEPS="print;set accent #ABCDEF;wait 500;theme zeta;print;quit"
//     print            what Theme reads now: the accent, mode, pair, the file and its directory, the pairs, lastError
//     set <tok> <hex>  Theme.setToken (the mockup panel's Save of a themed row)
//     theme <name>     Theme.setTheme (the pair switch)
//     mode <m>         Theme.setMode
//     wait <ms>        the next step runs this long after (200 ms debounce: a write needs ~300)
//     quit
// The runner gives every scenario its own XDG_CONFIG_HOME (the home) and, in a sandbox copy of the tree, its own themes/ (the repo's).
ShellRoot {
    id: root
    settings.watchFiles: false

    readonly property var steps: (Quickshell.env("THP_STEPS") || "print;quit").split(";").map(s => s.trim()).filter(s => s.length > 0)
    property int at: 0

    function say(s: string): void {
        console.log("THP " + s);
    }

    function show(label: string): void {
        root.say(label + " accent=" + String(Theme.baseOf("accent")).toUpperCase() + " mode=" + Theme.mode + " theme=" + Theme.themeName
                 + " path=" + Theme.themePath + " dir=" + Theme.themesDir + " pairs=" + JSON.stringify(Theme.pairs) + " ready=" + Theme.ready
                 + " err=" + JSON.stringify(Theme.lastError));
    }

    function step(): void {
        if (root.at >= root.steps.length) {
            Qt.quit();
            return;
        }
        const s = root.steps[root.at++];
        const w = s.split(/\s+/);
        let delay = 60;
        if (w[0] === "print") {
            root.show("print#" + root.at);
        } else if (w[0] === "set") {
            root.say("set " + w[1] + " " + w[2] + " -> " + Theme.setToken(w[1], w[2]));
        } else if (w[0] === "theme") {
            Theme.setTheme(w[1]);
        } else if (w[0] === "mode") {
            Theme.setMode(w[1]);
        } else if (w[0] === "wait") {
            delay = parseInt(w[1]);
        } else if (w[0] === "quit") {
            root.say("RESULT done");
            Qt.quit();
            return;
        }
        stepTimer.interval = delay;
        stepTimer.restart();
    }

    // The first step waits for the singleton's directory listings (two `ls` children): until a pair is known, 3 s at the most.
    property int waited: 0
    Timer {
        id: stepTimer
        interval: 100
        running: true
        repeat: false
        onTriggered: {
            if (root.at === 0 && Theme.pairs.length === 0 && root.waited < 3000) {
                root.waited += 100;
                stepTimer.restart();
                return;
            }
            root.step();
        }
    }
}
