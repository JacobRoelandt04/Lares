//@ pragma Env QSG_DISTANCEFIELD_ANTIALIASING=gray
//@ pragma Env QV4_GC_TIMELIMIT=2
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// THE SCAN: Quickshell reads and hashes every file a scanned file imports, transitively, before anything is compiled (~0.9 s for
// the shell's tree, measured), for its file watcher (off: settings.watchFiles) and for the qmldirs it writes on `qs:`. Loaded from
// `file:`, the body needs neither, so the stub imports no directory -- except when the body is to be loaded on `qs:`
// (LARES_FILE_ROOT=0, below), where those qmldirs are how a directory's types are found. The preprocessor reads only the environment.
//@ if env("LARES_FILE_ROOT") == "0"
import "modules/shell"
//@ endif

// =============================================================================
// shell.qml -- THE SHELL (docs/agent_added_files_and_folders/shell_progress/PLAN.md).
//
//   quickshell -n -p <this file>                  the desktop's (SHELL_SERVICES=live, the default)
//   SHELL_SERVICES=mock quickshell -n -p <this>   every service its module's mock twin, every path a mock's,
//                                                 every command recorded and none run (probes, renders)
//   QS_DISABLE_FILE_WATCHER=1 in front of either  never reloads on an edit (lares's supervisor runs it so)
//
// The Env pragma at the top makes ALL the shell's text gray: Qt 6.12 draws a distance-field Text with colour fringes until
// anything about it changes and in gray after, so the default is a mix, and every hand-over from a fresh copy (the title's
// morph, a card landing in the manager) steps (CLAUDE.md, "A DISTANCE-FIELD TEXT").
// QV4_GC_TIMELIMIT: the JS collector works in slices of 2 ms instead of Qt's 5, because a 120 Hz frame has 8.3 ms and the tick takes 3 of them: measured, 23 missed frames per 1000 of
// popup motion with 5 ms slices and 7.2 with 2 (three interleaved reps; 1 ms is no better than 2, a full collection at rest changes nothing).
//
// THIS FILE IS A STUB: the shell's body is modules/shell/ShellMain.qml (ShellServices, the shortcuts, one ShellScreen per output, the
// IPC target `shell`, the ready line), created once from here. Quickshell serves every file it loads on its own `qs:` URL scheme, and
// Qt's QML disk cache takes only local files ("File has to be a local file"), so on `qs:` all of the shell -- ~1000 files and scripts -- was
// parsed and compiled at EVERY start (5-7 s before the first QML line). The body is created from a `file:` URL instead: the stub is
// the only file compiled on `qs:`, everything ShellMain imports follows its `file:` URL (one type world: relative imports and
// qmldirs resolve against it), and Qt caches each compiled unit (`QML_DISK_CACHE_PATH`, lares-supervise sets it). Created with
// Qt.createComponent + createObject(parent), never a Loader: createObject parents after the completion, so ShellMain's own gc()
// can close a collection cycle that started inside the build (CLAUDE.md "A GC CYCLE ...").
//
// THE SWITCH: shell.jsonc `"workarounds": { "fileRoot": false }` loads the body on `qs:` by its relative path, as before (on unless
// exactly false). lares-supervise reads it as it starts the shell and passes LARES_FILE_ROOT=0 -- the one thing Quickshell's scanner
// can read before the stub exists, and the scan is what `qs:` needs; a start by hand says it the same way. The log says
// `LARES root file|qs` and, once the services are up, `LARES start root=<ms> load=<ms> services=<ms>` (ShellMain).
// =============================================================================
ShellRoot {
    id: root

    // The file watcher costs nothing at rest, but a shell that reloads under the user is a shell that restarts: the
    // supervisor also sets QS_DISABLE_FILE_WATCHER (the same switch).
    settings.watchFiles: false

    // The stub's first JS (a property's initial value is evaluated as the object is built): the start of `LARES start root=`.
    readonly property real startMs: Date.now()
    property var main: null

    function _build(comp: var, scheme: string): void {
        if (comp.status !== Component.Ready) {
            console.warn("LARES root " + scheme + ": ShellMain did not load: " + comp.errorString());
            return;
        }
        const t = Date.now();
        root.main = comp.createObject(root, { startMs: root.startMs, buildMs: t });
        if (!root.main) {
            console.warn("LARES root " + scheme + ": ShellMain was not created: " + comp.errorString());
            return;
        }
        root.main.rootMs = Date.now() - root.startMs;
        root.main.tellStart();
    }
    // THE RESERVE, EARLY (modules/shell/HyprReserve.qml): the rule that keeps the bars' room on an output stops the compositor for half a
    // second, so the rule of the last start is sent NOW, beside the load, for every output that is connected. A file holds one line this
    // shell wrote; anything else in it is not run. Offscreen and outside Hyprland nothing is sent.
    function _earlyReserve(): void {
        if (Quickshell.env("QT_QPA_PLATFORM") === "offscreen" || !Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE"))
            return;
        const state = Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state");
        const dir = state + (Quickshell.env("SHELL_SERVICES") === "mock" ? "/lares-shell-mock/state" : "/lares") + "/reserve";
        Quickshell.execDetached(["sh", "-c", 'mons=$(hyprctl -j monitors) || exit 0\n'
            + 'for f in "$1"/*.lua; do\n'
            + '    [ -f "$f" ] || continue\n'
            + '    n=${f##*/}; n=${n%.lua}\n'
            + '    printf "%s" "$mons" | grep -Fq "\\"name\\": \\"$n\\"" || continue\n'
            + '    grep -Eqx "hl\\.monitor\\(\\{ output = \\"$n\\", reserved_area = \\{ top = [0-9]+, right = [0-9]+, bottom = [0-9]+, left = [0-9]+ \\} \\}\\)" "$f" || continue\n'
            + '    hyprctl eval "$(cat "$f")" > /dev/null\n'
            + 'done', "sh", dir]);
    }
    Component.onCompleted: {
        root._earlyReserve();
        const file = Quickshell.env("LARES_FILE_ROOT") !== "0";
        let url = Qt.resolvedUrl("modules/shell/ShellMain.qml");
        if (file) {
            const dir = String(Quickshell.shellDir).replace(/\/+$/, "");
            url = "file://" + encodeURI(dir).replace(/#/g, "%23").replace(/\?/g, "%3F") + "/modules/shell/ShellMain.qml";
        }
        console.log("LARES root " + (file ? "file" : "qs"));
        const comp = Qt.createComponent(url);
        if (comp.status === Component.Loading)
            comp.statusChanged.connect(() => root._build(comp, file ? "file" : "qs"));
        else
            root._build(comp, file ? "file" : "qs");
    }
}
