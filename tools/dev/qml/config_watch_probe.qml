pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "modules/common/config"
import "modules/common/components"
import "modules/common/config/ConfigSpecs.js" as Specs

// tools/dev/qml/config_watch_probe.qml -- JsonConfig (a file read through its spec, from the first turn, hot) and ConfigWatch (a mistake is
// told once, with its line, and withdrawn when the file is right). tools/dev/config_watch_probe.sh runs it in a private directory (CW_DIR);
// bare it quits. Prints CW lines and "CW RESULT PASS|FAIL".
Scope {
    id: root
    readonly property string dir: Quickshell.env("CW_DIR") || ""
    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("CW " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }
    function js(v: var): string { return JSON.stringify(v); }

    // a stub of DesktopNotifier
    property var log: []
    QtObject {
        id: fakeNotifier
        function notify(key: string, spec: var): void { root.log.push({ what: "notify", key: key, title: spec.title, body: spec.body }); }
        function withdraw(key: string): void { root.log.push({ what: "withdraw", key: key }); }
    }
    function ofKey(key: string): var { return root.log.filter(l => l.key === key); }

    JsonConfig {
        id: breaks
        name: "breaks"
        spec: Specs.specOf("breaks")
        configPath: root.dir + "/config/breaks.jsonc"
        property int changes: 0
        onChanged: breaks.changes++
    }
    // "rest" and "items" are read at the start, "waitForFlourish" is hot
    JsonConfig {
        id: power
        name: "power"
        spec: Specs.specOf("power")
        configPath: root.dir + "/config/power.jsonc"
    }
    readonly property var powerItems: power.settings.items
    property int itemsChanged: 0
    onPowerItemsChanged: root.itemsChanged++
    // what a Loader decides in the turn it completes, before the event loop has run
    property string atBuild: ""
    Loader {
        active: breaks.settings.durationMin === 42
        sourceComponent: Component { Item { Component.onCompleted: root.atBuild = "built" } }
    }
    property int firstSeen: -1
    Component.onCompleted: {
        if (root.dir === "") {
            bare.start();
            return;
        }
        root.firstSeen = breaks.settings.durationMin;
        poll.start();
    }
    Timer { id: bare; interval: 0; onTriggered: Qt.quit() }

    // a second loader of the shell's own kind: a plain ConfigFile, which ConfigWatch hears through ConfigTell
    ConfigFile { id: osd; path: root.dir + "/config/osd.jsonc" }
    // outside the directory: not the user's file
    ConfigFile { id: other; path: root.dir + "/elsewhere/osd.jsonc" }
    ConfigFile { id: noSpec; path: root.dir + "/config/zebra.jsonc" }
    ConfigWatch {
        id: watch
        live: root.dir !== ""
        dirs: [root.dir + "/config/"]
        notifier: fakeNotifier
        extra: ["screentime"]
    }

    Process { id: sh }
    function run(cmd: string): void { sh.command = ["sh", "-c", cmd]; sh.running = true; }
    property int step: 0
    property int waited: 0
    function wait(ok: bool, name: string, detail: string): bool {
        if (ok) {
            root.waited = 0;
            return true;
        }
        if (++root.waited > 100) {
            root.check(name, false, "never: " + detail);
            root.waited = 0;
            return true;
        }
        return false;
    }
    property int notesBefore: 0

    function next(): void {
        switch (root.step) {
        case 0:
            root.check("the settings are the file's from the first turn", root.firstSeen === 42, String(root.firstSeen));
            root.check("a Loader decided as it was built is decided on the file", root.atBuild === "built", root.atBuild);
            root.check("a key left out is its default", breaks.settings.pauseMin === 5 && breaks.settings.enabled === true, root.js(breaks.settings));
            if (!root.wait(root.ofKey("osd").length > 0 && root.ofKey("screentime").length > 0, "the mistakes are told", root.js(root.log)))
                return;
            break;
        case 1: {
            const o = root.ofKey("osd")[0];
            root.check("a toast names the file and its count", o.title === "osd.jsonc: 2 mistakes", o.title);
            root.check("... the line, the key and why", o.body === "line 3: dismisMs is not a key -- did you mean \"dismissMs\"?\nline 4: queueCap is 900, must be a whole number 1 .. 20", o.body);
            root.check("a file no loader reads is watched too (extra)", root.ofKey("screentime")[0].title === "screentime.jsonc: a mistake", root.js(root.ofKey("screentime")));
            root.check("a file that is right says nothing", root.ofKey("breaks").length === 0, root.js(root.log));
            root.check("a file outside the directory, and one with no spec, say nothing", root.ofKey("zebra").length === 0 && root.log.length === 2, root.js(root.log));
            root.notesBefore = root.log.length;
            root.itemsChanged = 0;
            root.check("a list of the file is the settings'", root.js(power.settings.items) === "[\"lock\",\"sleep\"]" && power.settings.rest === "sleep", root.js(power.settings));
            // the same text written again: nothing new
            root.run("cat " + root.dir + "/config/osd.jsonc > " + root.dir + "/x && cat " + root.dir + "/x > " + root.dir + "/config/osd.jsonc; "
                + "printf '{ \"durationMin\": 30, \"stepSec\": 0 }' > " + root.dir + "/config/breaks.jsonc; "
                + "printf '{ \"rest\": \"lock\", \"items\": [\"lock\"], \"waitForFlourish\": false }' > " + root.dir + "/config/power.jsonc");
            break;
        }
        case 2:
            if (!root.wait(breaks.settings.durationMin === 30, "a save is followed", root.js(breaks.settings)))
                return;
            root.check("a value that is wrong leaves its default", breaks.settings.stepSec === 60, root.js(breaks.settings));
            root.check("... and is a problem", breaks.problems.length === 1 && breaks.problems[0].path[0] === "stepSec", root.js(breaks.problems));
            if (!root.wait(root.ofKey("breaks").length === 1, "its mistake is told", root.js(root.log)))
                return;
            if (!root.wait(power.settings.waitForFlourish === false, "a hot key is followed", root.js(power.settings)))
                return;
            root.check("a key read at the start keeps its value, the same object", power.settings.rest === "sleep" && root.itemsChanged === 0
                && root.js(power.settings.items) === "[\"lock\",\"sleep\"]", root.js(power.settings) + " " + root.itemsChanged);
            root.check("the same text again says nothing again", root.ofKey("osd").length === 1, root.js(root.ofKey("osd")));
            root.run("printf '{ \"durationMin\": 31 \"stepSec\": 10 }' > " + root.dir + "/config/breaks.jsonc");
            break;
        case 3:
            if (!root.wait(breaks.lastError !== "", "a file that does not parse is said", breaks.lastError))
                return;
            root.check("a file that does not parse keeps the previous settings", breaks.settings.durationMin === 30, root.js(breaks.settings));
            root.check("the toast of it names the line", root.ofKey("breaks").slice(-1)[0].body.indexOf("line 1: missing comma") === 0, root.js(root.ofKey("breaks")));
            root.run("printf '{ \"durationMin\": 31, \"stepSec\": 10 }' > " + root.dir + "/config/breaks.jsonc; printf '{}' > " + root.dir + "/config/osd.jsonc");
            break;
        case 4:
            if (!root.wait(breaks.settings.durationMin === 31 && root.ofKey("osd").length === 2, "the fixed files are read", root.js(root.log)))
                return;
            root.check("the toast of a file that is right again goes", root.ofKey("osd")[1].what === "withdraw" && root.ofKey("breaks").slice(-1)[0].what === "withdraw", root.js(root.log));
            root.check("no mistake is left but screentime's", root.js(Object.keys(watch.mistakes)) === "[\"screentime\"]", root.js(watch.mistakes));
            root.run("rm " + root.dir + "/config/breaks.jsonc");
            break;
        case 5:
            if (!root.wait(breaks.settings.durationMin === 50 && !breaks.present, "a file that is gone is the defaults", root.js(breaks.settings)))
                return;
            breaks.apply({ durationMin: 12, nonsense: 1 });
            root.check("apply() sets the object", breaks.settings.durationMin === 12 && breaks.problems.length === 1, root.js(breaks.problems));
            console.log("CW RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + ")");
            poll.stop();
            Qt.quit();
            return;
        }
        root.step++;
    }
    Timer { id: poll; interval: 50; repeat: true; onTriggered: root.next() }
}
