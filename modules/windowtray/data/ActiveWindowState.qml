pragma ComponentBehavior: Bound

import QtQuick
import "WindowTitle.js" as WindowTitle

// =============================================================================
// ActiveWindowState.qml -- the public face of ActiveWindowService and
// ActiveWindowMock, once. The two are this component with a source of windows
// added; whatever reads one reads the other.
//
//   in:  config      WindowTrayConfig.config (rewrites, stripSuffix)
//        appLookup   AppLookup (class -> desktop entry; for appName)
//   out: address, cls, title (raw), initialTitle, appName, shownTitle,
//        empty (no window: shownTitle "Desktop", cls "~desktop"),
//        focused (this bar's monitor holds the focus), urgent, serial
//
// A source writes ALL facts of the window with `_apply({...})` (partial objects
// merge over what is there): they live in ONE object, so a reader never sees the
// class of one window beside the title of another, and a write that changes
// nothing changes nothing -- no signal, no bump. `serial` bumps once per change
// of any out property, derived ones included (the lookup finding an entry, the
// config changing a rewrite), coalesced to one bump per turn of the event loop.
//
// A TERMINAL'S TITLE WAITS (executing `ls` does not flash
// the title from ~ to ls to ~ again). A shell sets the window's title to the command
// it is about to run and back to the directory when it ends, so a command that takes
// a moment longer than the prompt flashes across the bar. For a window whose class is
// in the config's `terminalClasses` (kitty first), a change of THE TITLE ALONE -- same
// window, same everything else -- is held `terminalTitleMs` before it is written, and
// a title that comes back to the one shown within it never shows at all. The hold is in
// `_apply`, on the way IN, because that is where a source's facts become the bar's:
// nothing downstream (the morph, the island that follows the title) sees the title
// that was held back, and nothing downstream needs to know. The deadline runs from the
// FIRST change that waits and what is written is the LATEST title, so a program that
// rewrites its title ten times a second still reaches the bar every `terminalTitleMs`
// (a restart on every change would starve it). Any other change -- another window, the
// desktop, the class -- writes through at once and drops what waited: it belonged to
// the window that went. A config without `terminalClasses` (a mockup's bare object)
// holds nothing.
// =============================================================================
Item {
    id: root

    property var config: null
    property var appLookup: null

    readonly property string address: root._s.address
    readonly property string cls: root._s.cls
    readonly property string title: root._s.title
    readonly property string initialTitle: root._s.initialTitle
    readonly property bool empty: root._s.empty
    readonly property bool focused: root._s.focused
    readonly property bool urgent: root._s.urgent
    readonly property string appName: {
        if (root.appLookup)
            return String(root.appLookup.app(root.cls).name);
        return root.empty ? "Desktop" : root.cls;
    }
    readonly property string shownTitle: {
        if (root.empty)
            return root.appName;
        const c = root.config;
        return WindowTitle.shownTitle(root.title, {
            initialTitle: root.initialTitle,
            appName: root.appName,
            rules: c ? c.rewrites : [],
            stripSuffix: c ? c.stripSuffix !== false : true
        });
    }
    readonly property int serial: root._serial
    // False from a live source's start until its first answer (the bar can show
    // nothing, rather than "Desktop", for those milliseconds). A mock is always ready.
    readonly property bool ready: root._ready

    // ---- For the sources ------------------------------------------------------
    property var _s: ({ address: "", cls: "~desktop", title: "", initialTitle: "", empty: true, focused: true, urgent: false })
    property int _serial: 0
    property bool _ready: true

    function _apply(o: var): void {
        const s = root._s;
        const same = !root._windowChanges(s, o);
        // The title alone waits, in a terminal; every other fact is written now.
        if ("title" in o && same) {
            const ms = root._holdMs(s.empty ? "" : s.cls);
            if (ms > 0) {
                const rest = {};
                for (const k in o)
                    if (k !== "title")
                        rest[k] = o[k];
                root._hold(String(o.title), ms);
                root._write(rest);
                return;
            }
        }
        // A title written at once, or another window, supersedes the one that waited. (A write of other facts only -- the window
        // turned urgent -- leaves it waiting.)
        if (!same || "title" in o) {
            root._pendingTitle = null;
            holdTimer.stop();
        }
        root._write(o);
    }

    function _write(o: var): void {
        const s = root._s;
        const n = {};
        let changed = false;
        for (const k in s) {
            n[k] = (k in o) ? o[k] : s[k];
            if (n[k] !== s[k])
                changed = true;
        }
        if (changed)
            root._s = n;
    }

    // Does `o` put another window (or the desktop) where this one is: a different address, class, or emptiness.
    function _windowChanges(s: var, o: var): bool {
        return ("address" in o && o.address !== s.address) || ("cls" in o && o.cls !== s.cls) || ("empty" in o && o.empty !== s.empty);
    }

    // How long a title of a window of `cls` waits (ms; 0: not at all).
    function _holdMs(cls: string): int {
        const c = root.config;
        if (!c || !Array.isArray(c.terminalClasses) || !WindowTitle.isTerminal(cls, c.terminalClasses))
            return 0;
        const ms = Number(c.terminalTitleMs);
        return ms > 0 ? Math.round(ms) : 0;
    }

    // `title` is wanted: shown now if it is what is shown (a change back), else the latest is written when the first wait ends.
    property var _pendingTitle: null
    function _hold(title: string, ms: int): void {
        if (title === root._s.title) {
            root._pendingTitle = null;
            holdTimer.stop();
            return;
        }
        root._pendingTitle = title;
        if (!holdTimer.running) {
            holdTimer.interval = ms;
            holdTimer.start();
        }
    }
    Timer {
        id: holdTimer
        onTriggered: {
            const t = root._pendingTitle;
            root._pendingTitle = null;
            if (t !== null)
                root._write({ title: t });
        }
    }

    // The no-window state, keeping who holds the focus.
    function _applyEmpty(focused: bool): void {
        root._apply({ address: "", cls: "~desktop", title: "", initialTitle: "", empty: true, focused: focused, urgent: false });
    }

    // ONE bump per turn of the event loop, after the change has gone through every binding
    // (a handler of `serial` must not see a class from one generation beside a title
    // from the other: a change handler runs before the bindings that follow the change).
    function _bump(): void {
        root._serial++;
    }

    on_SChanged: Qt.callLater(root._bump)
    onShownTitleChanged: Qt.callLater(root._bump)
    onAppNameChanged: Qt.callLater(root._bump)
}
