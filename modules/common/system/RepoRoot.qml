pragma Singleton

import QtQuick
import Quickshell

// =============================================================================
// RepoRoot.qml -- where this config lives: the directory that holds modules/,
// tools/, helpers/, llm_tools/, themes/, assets/, mockups/ and the user's
// <name>.jsonc files.
//
//   RepoRoot.dir + "/tools/theme/themectl"
//
// Every path into the repo goes through here, whichever file started the
// process. Quickshell takes the directory of the file it starts as shellDir, as
// given (no link resolved), and only `shell.qml` stands in the repo itself. The
// files started from a directory BELOW it -- the lock (lock/shell.qml), a
// mockup (mockups/<module>.qml), a test harness (tools/dev/qml/<probe>.qml) -- reach
// the modules through that directory's `modules` link, so their shellDir is the
// directory below, and so is the base of a module's own
// Qt.resolvedUrl("../../../tools/..."): from a mockup that read
// <repo>/mockups/tools/..., which does not exist. A directory below cannot
// import "../modules" instead (Quickshell's scanner refuses a module path
// outside the config folder: the singletons there are "not defined").
//
// `launchDirs` names those directories, relative to the repo: a shellDir that
// ends in one of them is that far below the repo. A new directory that starts
// a quickshell is added here, beside its `modules` link.
// =============================================================================
Singleton {
    id: root

    readonly property var launchDirs: ["lock", "mockups", "tools/dev/qml"]

    readonly property string dir: {
        const d = String(Quickshell.shellDir).replace(/\/+$/, "");
        for (const below of root.launchDirs) {
            if (d.endsWith("/" + below))
                return d.substring(0, d.length - below.length - 1);
        }
        return d;
    }
}
