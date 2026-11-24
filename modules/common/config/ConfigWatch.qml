pragma ComponentBehavior: Bound

import QtQuick

import "../components"
import "../components/ConfigTell.js" as ConfigTell
import "../components/JsonComments.js" as JsonComments
import "ConfigCheck.js" as Check
import "ConfigSpecs.js" as Specs

// =============================================================================
// ConfigWatch.qml -- a mistake in a hand-edited config is SAID: one toast per file, with the line, the key and why, gone by itself when
// the file is right (the user, 2026-11-22). One per shell.
//
// It reads no file of its own where a loader already does: every ConfigFile tells what it read (ConfigTell.js). `extra` are the files no
// loader of the shell reads (screentime.jsonc is the daemon's, lockscreen.jsonc the lock's): a ConfigFile each. The check is the file's spec
// (ConfigSpecs.js); what each loader then does with a wrong value is the loader's own (its default stands, or the number is clamped).
//
//   dirs        only files of these directories count (the user's config/ by its own path and by the snapshot's link to it, each with a
//               trailing slash); `extra` is read from the first
//   notifier    a DesktopNotifier-like: notify(key, spec), withdraw(key)
//   mistakes    { name: [lines] } now, for a probe and for `told`
// =============================================================================
Item {
    id: root

    property bool live: false
    property var dirs: []
    property var notifier: null
    property var extra: []
    readonly property var mistakes: root._mistakes
    // the most lines a toast shows
    property int maxLines: 4

    signal told(string name, var lines)

    property var _mistakes: ({})

    function _nameOf(path: string): string {
        for (const dir of root.dirs) {
            if (dir === "" || path.indexOf(dir) !== 0)
                continue;
            const rest = path.substring(dir.length);
            if (rest.indexOf("/") < 0 && rest.endsWith(".jsonc"))
                return rest.substring(0, rest.length - 6);
        }
        return "";
    }

    function _saw(path: string, text: string): void {
        const name = root._nameOf(path);
        const spec = name !== "" ? Specs.specOf(name) : null;
        if (!spec)
            return;
        const lines = Check.mistakes(spec, text, JsonComments.locate);
        const before = root._mistakes[name] || [];
        if (JSON.stringify(lines) === JSON.stringify(before))
            return;
        const m = Object.assign({}, root._mistakes);
        if (lines.length > 0)
            m[name] = lines;
        else
            delete m[name];
        root._mistakes = m;
        root._say(name, lines);
        root.told(name, lines);
    }

    function _say(name: string, lines: var): void {
        for (const l of lines)
            console.warn("ConfigWatch: " + name + ".jsonc " + l);
        if (!root.notifier)
            return;
        if (lines.length === 0) {
            root.notifier.withdraw(name);
            return;
        }
        const show = lines.slice(0, root.maxLines);
        if (lines.length > show.length)
            show.push("and " + (lines.length - show.length) + " more: lares config " + name);
        root.notifier.notify(name, {
            title: name + ".jsonc: " + (lines.length === 1 ? "a mistake" : lines.length + " mistakes"),
            body: show.join("\n"), urgency: "normal"
        });
    }

    Repeater {
        model: root.live ? root.extra : []
        delegate: Item {
            id: one
            required property string modelData
            ConfigFile { path: root.dirs[0] + one.modelData + ".jsonc" }
        }
    }

    // A 0 ms Timer: the notifier's slots do not exist yet at completion (CLAUDE.md), and the loaders have read their files by then.
    Timer {
        interval: 0
        running: root.live
        onTriggered: ConfigTell.listen((path, text) => root._saw(path, text))
    }
    Component.onDestruction: if (root.live) ConfigTell.listen(null)
}
