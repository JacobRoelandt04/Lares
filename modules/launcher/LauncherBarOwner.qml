pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

import "../common/components"
import "data"
import "FlourishPresets.js" as Presets

// =============================================================================
// LauncherBarOwner.qml -- the application launcher's bar-side owner.
//
// The bar engine builds a popup's content on open and destroys it on close,
// so what must outlive the popup lives here: the LauncherService (the apps,
// favourites, frecency, the folders, the sort and layout) and the tunables.
//
// How it opens:
//   * Alt+Space -- a Hyprland global shortcut, `lares:launcher`
//     (`bind = ALT, SPACE, global, lares:launcher`); pressed again it
//     closes; over a fullscreen window too -- it floats there as a pill (the
//     engine's THE FLOATING POPUP: any popup opened over a fullscreen window).
//     The keyboard is the launcher's at once (exclusive + a focus grab: a
//     click anywhere else closes it).
//   * hovering the slim bottom bar -- after `tune.hoverOpenMs` at rest. A
//     hover-opened launcher closes when the pointer has been off the bar and
//     the popup for `tune.hoverCloseMs`, UNTIL the user engages (types, moves
//     the highlight, drags, opens a menu); from then on only Escape, a
//     launch, a click outside or the shortcut close it.
//
// A FILE DRAGGED ONTO IT. The popup's DropArea links a dropped file in; what would make a drop
// impossible is the launcher itself holding the keyboard through a HyprlandFocusGrab, which an outside click clears -- and the click that STARTS a
// drag is an outside click. So:
//   * a click outside does not close a shortcut-opened launcher (launcher.jsonc `clickOutsideCloses`, off): the
//     grab clearing only means the keyboard has gone elsewhere (`_grabLost`), and the launcher asks
//     the layer for on-demand keys only -- the compositor hands them back when the pointer returns
//     (and the popup's hover pulse helps). The click that cleared the grab is the compositor's and is
//     not delivered, so the first click on a drag source is spent (open, kb=onDemand, no click delivered, the next keys go to the
//     application). Escape (while it has the keys, or the shell's Escape bind), the shortcut again, a
//     launch and the hover rules still close it.
//   * opened over the user's file browser -- the focused window is one of launcher.jsonc's
//     `keysFree`, kitty running yazi -- the launcher takes NO keys and holds no
//     grab (`keysFree`): arrows, space and the rest stay with the browser, the launcher is a drop
//     target, and a click ON it gives it the keyboard (on-demand). Asked once, by one `hyprctl -j
//     activewindow`, when the shortcut is pressed (`liveWindow`; no answer in 250 ms opens it
//     normally). A hover-opened launcher is never keys-free: it never held the keys.
// Every open starts fresh: at the root, no query, no pinned folder and no
// new folder held at its cell (the service's session, ended once the closed
// popup's content is gone -- not when its close starts, or the list rebuilt
// under the fading popup and under a launch's departing row).
//
// SHELL-HOSTED (`shellHosted`, CONTRACT section 4). The shell has one owner PER
// SCREEN and ONE LauncherService, built by the host and handed in as `service`.
// A hosted owner builds none (nor the script-failure DesktopNotifier, which is
// the host's: it sets the service's `notifier`), registers no GlobalShortcut
// (the host's one ShortcutRouter calls `shortcutPressed()` on the focused
// screen's owner) and writes no property of the service. What stays PER WINDOW
// is what cannot be shared: the ConfirmFlourish (it drives this screen's
// engine). Icons are the icon theme's, drawn by AppIcon wherever they are
// shown: there is nothing to share. A shortcut-opened
// launcher takes the keyboard by its HyprlandFocusGrab on `grabWindows` (the
// host's bar window); the bottom bar's hover-open is not mounted by the shell.
// Not hosted (the mockup, the probes): the owner builds its own service.
//
// A launch plays the CONFIRM FLOURISH (ConfirmFlourish, held here: it
// outlives the popup's content): the row detaches from the closing launcher and
// is thrown -- up to the screen's centre, no speed at its apex, back down as a
// ball into this bar (it waits for nothing, not the launched window either). A reopen while it plays waits for the
// ball to merge (bounded), so the ball never falls through the growing
// launcher.
// =============================================================================
Item {
    id: owner

    property var engine: null
    property var bar: null
    property string barId: ""
    property string ownerId: "launcher"
    // Where along the bar the popup grows from (bar-local); -1: its middle.
    property real anchorAlong: -1

    property LauncherTune tune: LauncherTune {}

    // launcher.jsonc, as the service read it.
    readonly property var _file: owner.service && owner.service.config ? owner.service.config : null
    // THE FLOURISH PRESET: launcher.jsonc's `"flourish": "<name>"` (FlourishPresets.js: honey, syrup, dew, classic; "off" plays none).
    // "" (no key) leaves the tune as it is -- LauncherTune's own values ARE honey's, and a mockup's panel is the
    // tune's author -- so the preset is written only when the file names one, or takes the name away again (then
    // the default's values come back). A name the file spells wrongly says so once and plays the default.
    readonly property string _flourishWanted: owner._file ? owner._file.flourish : ""
    property string _flourishApplied: ""
    on_FlourishWantedChanged: owner._applyFlourish()
    function _applyFlourish() {
        const want = owner._flourishWanted;
        if (want === owner._flourishApplied || want === "off")
            return;
        let name = want;
        if (name !== "" && !Presets.values(name)) {
            console.log("LauncherBarOwner: launcher.jsonc: \"flourish\": \"" + want + "\" is not a preset (" + Presets.names().join(", ") + ") -- " + Presets.DEFAULT + " plays");
            name = Presets.DEFAULT;
        } else if (name === "") {
            name = Presets.DEFAULT;
        }
        Presets.apply(owner.tune, name);
        owner._flourishApplied = want;
    }
    Component.onCompleted: owner._applyFlourish()
    // The wiki service (WikiService, or a WikiMock), INJECTED by whoever builds
    // this owner -- never built here. With one, the popup's foot carries a
    // line with today's Discover article (LauncherPopup); without, the popup
    // has no such line.
    property var wiki: null

    // Where the files are: XDG defaults; a mockup or a probe points them at
    // its own copies. Set once, at creation (every FileView has one path).
    readonly property string _config: (Quickshell.env("XDG_CONFIG_HOME") || ((Quickshell.env("HOME") || "") + "/.config")) + "/quickshell"
    readonly property string _state: (Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state")) + "/lares/launcher"
    property string configPath: owner._config + "/config/launcher.jsonc"
    property string favoritesPath: owner._state + "/favorites.json"
    property string favoritesLegacyPath: owner._config + "/launcher_favorites.json"
    property string statePath: owner._state + "/state.json"
    // "" = launcher.jsonc's scriptsRoot (itself defaulting to
    // ~/.config/quickshell/launcher); a mockup points it at a scratch copy.
    property string scriptsRootOverride: ""
    // Launch nothing (a mockup, a probe): the service records what it would
    // have run.
    property bool dryRun: false
    // The quick answers' child and the copy command of the owner's OWN service ([] / the default: the shell's; a mockup or a probe
    // points them at a stub). A shell-hosted owner's service is the host's.
    property var answerCommand: []
    property var copyCommand: ["wl-copy", "--"]
    // The Alt+Space shortcut is registered by the real shell only: a mockup
    // registering the same name would take it from the running desktop.
    property bool shortcutEnabled: true
    // Ask Hyprland for the focused window when the shortcut opens the launcher (see "A FILE DRAGGED
    // ONTO IT"). A mockup or a probe turns it off: the launcher then always takes its keys.
    property bool liveWindow: true
    // The windows a shortcut-opened launcher grabs focus for (the shell's
    // bar windows). None in a mockup: it is an ordinary window.
    property var grabWindows: []

    // The shell's mode (see the header): service and store injected, nothing built, no shortcut.
    property bool shellHosted: false
    // Nothing of the launcher is shared through flags (the host routes the key; see CONTRACT 3).
    readonly property var sharedFlags: ({})

    // The service: what the host injects (shell-hosted; null = absent), else the owner's own (`own`,
    // below). Read-only for everything but the host.
    readonly property var _kit: own.item
    property var service: owner._kit ? owner._kit.service : null
    readonly property alias flourish: flourishItem
    readonly property bool popupMine: !!owner.engine && owner.engine.popupOpen && owner.engine.popupOwnerId === owner.ownerId
    // The shell's popup stack (GooeyEngine "THE POPUP STACK"): the launcher does not close another popup for good, and its close
    // gives the place back.
    readonly property bool joinsPopupStack: true

    // What the owner builds when nothing is injected (the mockup, the probes): the service and the
    // failure notifier. A shell-hosted owner builds none of it. (A Loader holds an Item; the service is a Scope inside it.)
    Loader {
        id: own
        active: !owner.shellHosted
        sourceComponent: Item {
            id: kit
            readonly property alias service: service

            LauncherService {
                id: service
                configPath: owner.configPath
                favoritesPath: owner.favoritesPath
                favoritesLegacyPath: owner.favoritesLegacyPath
                statePath: owner.statePath
                scriptsRootOverride: owner.scriptsRootOverride
                dryRun: owner.dryRun
                answerCommand: owner.answerCommand
                copyCommand: owner.copyCommand
                notifier: failureNotifier
                // The panel's rows and columns (-1: launcher.jsonc's).
                rowsOverride: owner.tune.rows
                columnsOverride: owner.tune.columns
            }
            // A script that fails says so (its own last line), one slot per key.
            DesktopNotifier {
                id: failureNotifier
                appName: "Launcher"
                keys: service.notifyKeys
            }
        }
    }
    ConfirmFlourish {
        id: flourishItem
        engine: owner.engine
        tune: owner.tune
        ownerId: owner.ownerId
        barId: owner.barId
    }

    // ---- Opening and closing ------------------------------------------------------------------------
    // "shortcut" | "hover" while the popup is ours, "" otherwise.
    property string openedBy: ""
    property bool engaged: false
    property bool barHovered: false
    property bool popupHovered: false

    readonly property Component popupComponent: Component {
        LauncherPopup {
            id: content
            service: owner.service
            wiki: owner.wiki
            tune: owner.tune
            flourishOff: owner._flourishWanted === "off"
            answerTakesEnter: !owner._file || owner._file.answers.takesEnter
            keyboardOwned: owner._keysHeld
            keysFree: owner.keysFree
            grabbed: owner._grabActive
            cornerRadii: owner.engine ? owner.engine.popupCornerRadii : [0, 0, 0, 0]
            flourish: owner.flourish
            onCloseRequested: owner.close()
            onEngaged: owner.engaged = true
            onHoveredChanged: owner.popupHovered = hovered
            Component.onCompleted: owner._content = content
            onContentGone: owner._contentGone(content)
        }
    }
    // The popup's content while it exists (a close ends it; a reopen inside
    // the close gets the same one back).
    property var _content: null
    // A reopen held for the flourish's merge: how it was asked for.
    property string _pendingBy: ""

    function open(by) {
        if (!owner.engine || !owner.bar || !owner.service || owner.popupMine)
            return;
        // Asked again while a reopen waits: a shortcut's ask outranks a
        // hover's (a hover's would give up if the pointer left the bar).
        if (owner._pendingBy !== "") {
            if ((by || "shortcut") === "shortcut")
                owner._pendingBy = "shortcut";
            return;
        }
        if (flourishItem.holdReopen(() => owner._openHeld())) {
            owner._pendingBy = by || "shortcut";
            return;
        }
        owner._openNow(by);
    }
    function _openHeld() {
        const by = owner._pendingBy;
        owner._pendingBy = "";
        // A hover-open whose pointer has left the bar while it waited: none.
        if (by === "hover" && !owner.barHovered)
            return;
        owner._openNow(by);
    }
    function _openNow(by) {
        if (!owner.engine || !owner.bar || !owner.service || owner.popupMine)
            return;
        owner.openedBy = by || "shortcut";
        owner.engaged = false;
        owner.keysFree = owner.openedBy === "shortcut" && owner._keysFreeNext;
        owner._keysFreeNext = false;
        owner._grabLost = false;
        // Still closing: the engine reopens this very content, so its session
        // ends now rather than when it would have been gone; gone, a reset
        // still waiting for its turn is made now, before the new one opens.
        if (owner._content) {
            owner._endSession();
            owner._content.freshen();
        } else {
            owner._flushEnd();
        }
        // A rescan per open: the apps and the scripts root as they are now.
        owner.service.refresh();
        // The query the last session left, while it is young enough (launcher.jsonc `keepQuerySec`).
        if (owner._left !== null && owner._file && Date.now() - owner._left.at < owner._file.keepQuerySec * 1000)
            owner.service.setQuery(owner._left.query);
        owner._left = null;
        const along = owner.anchorAlong >= 0 ? owner.anchorAlong : owner.bar.width / 2;
        owner.engine.open(owner.ownerId, owner.barId, along, null, null, false, owner.popupComponent, 1);
    }
    function close() {
        if (owner.popupMine)
            owner.engine.close();
    }
    // A toggle while a reopen waits for the flourish's merge takes the
    // reopen back: the launcher the user asked for is not open yet, so the
    // second press is the "close" of the pair (without this the press would only
    // re-record the wait, and the launcher would open after the merge anyway).
    function _cancelHeldOpen() {
        if (owner._pendingBy === "")
            return false;
        owner._pendingBy = "";
        flourishItem.cancelReopen();
        return true;
    }
    function toggle() {
        if (owner._cancelHeldOpen())
            return;
        if (owner.popupMine)
            owner.close();
        else
            owner.open("shortcut");
    }
    onPopupMineChanged: {
        if (owner.popupMine) {
            owner._launched = false;
            return;
        }
        owner._closedAt = Date.now();
        owner.openedBy = "";
        owner.engaged = false;
        owner.popupHovered = false;
        owner.keysFree = false;
        owner._grabLost = false;
    }
    // The content is gone (its close has finished): the session ends -- the
    // query, the folder, the pins and held places. Not at the close's start:
    // the list rebuilt at once under the content still fading out, and under a
    // launch's row as it left for the flourish. Nor inside the
    // content's destruction: the rows being torn down heard the service change
    // (a folder row's minis) and built new icons in a dying tree ("Cannot
    // find member data", four per run). So after it, in the next turn -- or
    // at once when a reopen comes first.
    property bool _endPending: false
    function _contentGone(c) {
        if (owner._content === c)
            owner._content = null;
        if (!owner.popupMine && !owner._endPending) {
            owner._endPending = true;
            Qt.callLater(owner._flushEnd);
        }
    }
    function _flushEnd() {
        if (!owner._endPending)
            return;
        owner._endPending = false;
        if (!owner.popupMine)
            owner._endSession();
    }
    // The query of the session that ended and when it was closed; a launch leaves none.
    property var _left: null
    property real _closedAt: 0
    Connections {
        target: owner.service
        function onLaunched(key, keepOpen) {
            if (!keepOpen)
                owner._launched = true;
        }
    }
    property bool _launched: false
    function _endSession() {
        if (!owner.service)
            return;
        owner._left = owner._launched || owner.service.query === "" ? null : { query: owner.service.query, at: owner._closedAt };
        owner.service.endSession();
        owner.service.setQuery("");
        if (owner.service.folder !== "")
            owner.service.closeFolder();
    }

    // The shortcut. qmllint reports GlobalShortcut
    // unresolved ("PostReloadHook was not found"): Quickshell 0.3.1's
    // _GlobalShortcuts qmldir does not declare `depends Quickshell`, so the
    // linter cannot see its base type. It resolves at runtime (the mockup and
    // the probe load clean); nothing here can fix the package's qmldir.
    LazyLoader {
        active: owner.shortcutEnabled && !owner.shellHosted
        GlobalShortcut {
            appid: "lares"
            name: "launcher"
            description: "Open the application launcher"
            onPressed: owner.shortcutPressed()
        }
    }
    function shortcutPressed() {
        // Closing, or taking back a reopen that waits: nothing to ask. Opening: which window has the focus?
        if (!owner.liveWindow || owner.popupMine || owner._pendingBy !== "") {
            owner.toggle();
            return;
        }
        if (windowCheck.running) {
            // A repeat press while the ask is in flight waits for it; a stale ask (given up on) does not.
            if (!windowAnswer.running)
                owner.toggle();
            return;
        }
        windowCheck.running = true;
        windowAnswer.restart();
    }

    // ---- The user's file browser keeps its keys ----------------------------------------------------------
    // The launcher is open WITHOUT the keyboard (see "A FILE DRAGGED ONTO IT"); set by _openNow from the
    // answer below, and cleared when the popup is gone.
    property bool keysFree: false
    property bool _keysFreeNext: false
    // The focus grab cleared (a click outside): the keyboard has gone to what was clicked.
    property bool _grabLost: false
    // The launcher claims the keyboard: opened by the shortcut, not over the file browser, not given up.
    readonly property bool _keysHeld: owner.openedBy === "shortcut" && !owner.keysFree && !owner._grabLost
    function _freeKeysFor(w) {
        if (!w || !owner._file)
            return false;
        const inCls = String(w["class"] || "").toLowerCase();
        const inTitle = String(w.title || "").toLowerCase();
        for (const free of owner._file.keysFree) {
            const cls = String(free["class"] || "").toLowerCase();
            const word = String(free.title || "").toLowerCase();
            if ((cls !== "" || word !== "") && (cls === "" || inCls === cls) && (word === "" || inTitle.indexOf(word) >= 0))
                return true;
        }
        return false;
    }
    function _windowKnown(w) {
        const free = owner._freeKeysFor(w);
        windowAnswer.stop();
        // Consumed by _openNow, which a reopen waiting for the flourish's merge reaches later.
        owner._keysFreeNext = free;
        owner.toggle();
    }
    Process {
        id: windowCheck
        command: ["hyprctl", "activewindow", "-j"]
        // Decide on the whole answer: the collector's text is complete when its stream ends.
        stdout: StdioCollector {
            id: activeWindow
            onStreamFinished: {
                if (!windowAnswer.running)
                    return;
                let w = null;
                try {
                    w = JSON.parse(activeWindow.text || "{}");
                } catch (e) {
                    w = null;
                }
                owner._windowKnown(w);
            }
        }
    }
    // No answer (no hyprctl, a stuck compositor): the launcher opens with the keys.
    Timer {
        id: windowAnswer
        interval: 250
        onTriggered: owner._windowKnown(null)
    }

    // The keyboard of a shortcut-opened launcher, where the host has a window to grab for: the popup
    // asks the layer for no keyboard of its own meanwhile (LauncherPopup.grabbed). Over the file browser
    // there is none, and once the grab has cleared there is none to take again.
    readonly property bool _grabActive: owner.popupMine && owner._keysHeld && owner.grabWindows.length > 0
    HyprlandFocusGrab {
        active: owner._grabActive
        windows: owner.grabWindows
        onCleared: owner._grabCleared()
    }
    // An outside click clears the grab and is not delivered. It only lets the keyboard go
    // (launcher.jsonc `clickOutsideCloses` makes it close the launcher).
    function _grabCleared() {
        if (owner._file && owner._file.clickOutsideCloses)
            owner.close();
        else
            owner._grabLost = true;
    }

    // Hover on the bar: open after a rest; a hover-opened launcher the user
    // has not engaged closes once the pointer has left bar and popup alike.
    onBarHoveredChanged: {
        if (owner.barHovered && !owner.popupMine)
            hoverOpen.restart();
        else
            hoverOpen.stop();
        owner._checkLeave();
    }
    onPopupHoveredChanged: owner._checkLeave()
    onEngagedChanged: owner._checkLeave()
    Timer {
        id: hoverOpen
        interval: owner.tune.hoverOpenMs
        onTriggered: {
            if (owner.barHovered && !owner.popupMine)
                owner.open("hover");
        }
    }
    function _checkLeave() {
        if (owner.popupMine && owner.openedBy === "hover" && !owner.engaged && !owner.barHovered && !owner.popupHovered)
            hoverClose.restart();
        else
            hoverClose.stop();
    }
    Timer {
        id: hoverClose
        interval: owner.tune.hoverCloseMs
        onTriggered: {
            if (owner.openedBy === "hover" && !owner.engaged && !owner.barHovered && !owner.popupHovered)
                owner.close();
        }
    }
}
