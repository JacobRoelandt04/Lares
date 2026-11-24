pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// SecondaryMemory.qml -- whether a popup's secondary was open, and on what,
// kept across the popup's closes for the shell's session: the module half of a
// PERSISTENT secondary.
//
// The engine's half is timing (GooeyEngine: `secondaryPersistent` holds the
// child back while its popup grows and opens it on the mirror of the close).
// It never writes a property of the content, and the content is rebuilt on
// every open, so what to show has to come back from somewhere that outlives
// both: the module's bar-side owner holds one of these and hands it to every
// popup it builds.
//
//     // owner (long-lived):
//     SecondaryMemory { id: detailMemory; decayMs: 600000 }
//     Component.onCompleted (of the content it builds): if (detailMemory.restorable()) restore(detailMemory.key)
//     // popup content:
//     readonly property bool secondaryPersistent: true
//     onSecondaryOpenChanged: memory.remember(secondaryOpen, secondaryKey)
//     onSecondaryKeyChanged:  memory.remember(secondaryOpen, secondaryKey)
//     Component.onDestruction: memory.seen()
//
// The popup CLOSING is not a change: the engine closes the child itself and
// the content goes with `secondaryOpen` still true, which is what makes it come
// back. Only the user closing the detail (a click, a tab switch) records it.
//
// SESSION ONLY, WITH A DECAY (the user, 2026-11-12: "persistent within one
// session ... 10 minutes after the last open"). Nothing is written to disk: a
// shell restart or a boot forgets it. A detail last on screen `decayMs` ago
// (0 = never) no longer comes back by itself. "On screen" is stamped when it is
// opened or re-keyed (`remember`) and when the popup goes with it still open
// (`seen`), so the minutes count from the last moment it was shown, not from
// the click that first opened it. `restorable()` is a call, read once when a
// popup is built: a binding on `Date.now()` captures nothing (CLAUDE.md).
// =============================================================================
Item {
    id: root

    // How long after it was last shown the detail still comes back; 0 = always.
    property real decayMs: 0

    readonly property bool open: root._open
    readonly property var key: root._key

    function remember(open, key) {
        if (open)
            root._seenMs = Date.now();
        root._open = !!open;
        root._key = key === undefined ? null : key;
    }
    // The popup goes with the detail still out: it was on screen until now.
    function seen() {
        if (root._open)
            root._seenMs = Date.now();
    }
    function forget() {
        root.remember(false, null);
    }
    function restorable() {
        return root._open && root._key !== null
            && (root.decayMs <= 0 || Date.now() - root._seenMs < root.decayMs);
    }

    // ---- Private -------------------------------------------------------------
    property bool _open: false
    property var _key: null
    property real _seenMs: 0
}
