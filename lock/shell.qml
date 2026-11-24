//@ pragma Env QSG_DISTANCEFIELD_ANTIALIASING=gray
import QtQuick
import Quickshell

import "modules/lockscreen/lock"

// =============================================================================
// lock/shell.qml -- the lock process's entry (`quickshell -p lock/shell.qml`).
//
// The lock is its OWN quickshell, in its own root (a second quickshell
// under the shell's root fights it over .qmlls.ini at ~1.4 cores each; and a
// root cannot import "../", hence the modules/ symlink here; a path into the repo goes through RepoRoot).
//
// SAFETY. Started anywhere but under tools/lockscreen/lares-lock this would lock
// the user's session with nothing supervising it: a lock that dies then leaves
// Hyprland's lockdead screen. The supervisor sets LARES_LOCK_SUPERVISED=1; without
// it the process says why and quits, and LockRoot (the WlSessionLock) is never
// even created. The quit comes from a 0 ms Timer: Qt.quit() from
// Component.onCompleted does not quit (nothing is connected to it yet).
//
// `settings.watchFiles: false`: editing a lock file while locked must never
// reload (a reload that evaluates `locked` false UNLOCKS).
//
// The Env pragma at the top makes the lock's text GRAY-antialiased, as the shell's
// is (shell.qml says why: Qt 6.12 draws a distance-field Text in LCD fringes on its
// first frames and gray after, so the shell draws gray everywhere).
// =============================================================================
ShellRoot {
    id: shell
    settings.watchFiles: false

    readonly property bool allowed: Quickshell.env("LARES_LOCK_SUPERVISED") === "1"

    LazyLoader {
        active: shell.allowed
        LockRoot {}
    }

    Timer {
        interval: 0
        running: !shell.allowed
        onTriggered: {
            console.log("lock: refusing to lock: LARES_LOCK_SUPERVISED is not 1 (start it with tools/lockscreen/lares-lock)");
            Qt.quit();
        }
    }
}
