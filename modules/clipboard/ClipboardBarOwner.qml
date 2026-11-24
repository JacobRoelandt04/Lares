pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// =============================================================================
// ClipboardBarOwner.qml -- the clipboard shelf's bar-side owner.
//
// The bar engine builds a popup's content on open and destroys it on close, so
// what must outlive the popup lives here or is handed in: the SERVICE
// (ClipboardService, or a ClipboardMock -- INJECTED, never built here), the
// style (ClipStyle: every number of the shelf) and the popup's few own
// tunables. The shelf rises from the launcher's slim bottom bar (`barId`), and
// there is no bar button: it opens by the shortcut only.
//
// HYPRLAND BIND (the user's keybinds.lua):
//
//     hl.bind("ALT + V", hl.dsp.global("lares:clipboard"))
//
// HOW IT OPENS. The bind is a GlobalShortcut named "clipboard" (appid
// "lares"), registered by the real shell only (`shortcutEnabled`; a mockup
// registering it would take it from the desktop). Pressed again it closes.
// Before anything opens, ONE `hyprctl -j activewindow` answers the three
// questions that must be asked before the popup takes the keyboard:
//   * which window the paste is FOR -- written to `service.origin`
//     ({address, cls}; the service sends the shortcut there once the popup has
//     let go of the keyboard, CONTRACT.md "hostOpen"),
//   * whether that window is fullscreen -- no open over it unless
//     `openOverFullscreen` (clipboard.jsonc's flag),
//   * what to do when there is no answer: hyprctl failed or returned {} (no
//     window). It opens anyway with `service.origin = null`, and the service
//     then only copies, never sends a key. `Hyprland.activeToplevel` is not
//     read: the origin and the fullscreen rule come from ONE authoritative
//     answer taken at the moment it matters, never from a cached property.
// A shortcut-opened popup takes the keyboard exclusively and a
// HyprlandFocusGrab over the shell's bar windows closes it on a click anywhere
// else.
//
// `service.hostOpen` is true exactly while this popup is the engine's.
//
// SHELL-HOSTED (`shellHosted`, CONTRACT section 4): the shell has one owner PER SCREEN on
// ONE service, so the owner writes no property of the service and registers no shortcut --
// two owners writing `hostOpen` would leave the last writer's answer, and the shell's one
// ShortcutRouter sends the key to the focused screen's `toggle()`. `sharedFlags.hostOpen` is
// the value the Binding would have written; the host sets `service.hostOpen` to the OR over
// its screens. The popup grows from the host's bottom bar (`barId: "bottom"`) and its
// HyprlandFocusGrab takes the window the host hands in `grabWindows`. What the owner does
// write on the service is `origin`, once, by the act of opening on the screen the key was
// pressed on (never a standing binding).
// =============================================================================
Item {
    id: owner

    property var engine: null
    property var bar: null
    property string barId: "launcherBar"
    property string ownerId: "clipboard"
    // Where along the bar the popup grows from (bar-local); -1: its middle.
    property real anchorAlong: -1

    // The service (ClipboardService / ClipboardMock): injected.
    property var service: null
    // A ClipStyle; the owner's host builds one (the panel writes it).
    property ClipStyle style: null
    // The popup's own tunables (the mockup's panel writes them here).
    property string fontFamily: "Inter"

    // The Alt+V shortcut is registered by the real shell only.
    property bool shortcutEnabled: true
    // Shell-hosted: no GlobalShortcut, no write of a service property (see the header).
    property bool shellHosted: false
    // What this owner would have written on the service: the host sets the service's flag to
    // the OR of its screens' values.
    readonly property var sharedFlags: ({ hostOpen: owner.popupMine })
    // The windows a shortcut-opened popup grabs focus for (the shell's bar
    // windows). None in a mockup: it is an ordinary window.
    property var grabWindows: []
    // clipboard.jsonc's openOverFullscreen (the service reads the config): open while the active window is fullscreen (the shell's
    // window is raised for this popup, and it floats there as a pill).
    property bool openOverFullscreen: !!owner.service && owner.service.openOverFullscreen === true
    // Ask Hyprland for the active window before opening. A mockup or a probe
    // turns it off: the service keeps the origin it was given.
    property bool liveWindow: true

    readonly property bool popupMine: !!owner.engine && owner.engine.popupOpen && owner.engine.popupOwnerId === owner.ownerId
    // The shell's popup stack (GooeyEngine "THE POPUP STACK"): opening the shelf over another popup does not close it for good,
    // and the shelf's close gives the place back.
    readonly property bool joinsPopupStack: true

    // The paste key is sent after the popup has let go of the keyboard.
    Binding {
        target: owner.service
        property: "hostOpen"
        value: owner.popupMine
        when: !!owner.service && !owner.shellHosted
    }

    readonly property Component popupComponent: Component {
        ClipboardPopup {
            id: content
            service: owner.service
            style: owner.style
            grabbed: owner._grabActive
            stateDir: owner.service ? owner.service.stateDir : ""
            fontFamily: owner.fontFamily
            // The service decides how long a delete stays undoable; the header offers exactly that.
            undoMs: owner.service ? owner.service.undoWindowMs : 8000
            onCloseRequested: owner.close()
            Component.onCompleted: owner._content = content
            onContentGone: {
                if (owner._content === content)
                    owner._content = null;
            }
        }
    }

    // ---- Opening and closing ------------------------------------------------------
    // The popup's content while it exists (a close ends it; a reopen inside
    // the close gets the same one back, and it starts fresh).
    property var _content: null
    function open() {
        if (!owner.engine || !owner.bar || !owner.service || owner.popupMine)
            return;
        if (owner._content)
            owner._content.freshen();
        const along = owner.anchorAlong >= 0 ? owner.anchorAlong : owner.bar.width / 2;
        owner.engine.open(owner.ownerId, owner.barId, along, null, null, false, owner.popupComponent, 1);
    }
    function close() {
        if (owner.popupMine)
            owner.engine.close();
    }
    // The shortcut's press, and a mockup's key.
    function toggle() {
        if (owner.popupMine) {
            owner.close();
            return;
        }
        if (!owner.liveWindow) {
            owner.open();
            return;
        }
        if (!windowCheck.running)
            windowCheck.running = true;
    }

    // `hyprctl activewindow -j`: address, class and fullscreen in one answer.
    function _windowKnown(w) {
        return !!w && typeof w.address === "string" && w.address.length > 0;
    }
    function _normAddress(a) {
        const s = String(a || "");
        return s === "" || s.indexOf("0x") === 0 ? s : "0x" + s;
    }
    function _decided(w) {
        const win = owner._windowKnown(w) ? w : null;
        const fs = win && win.fullscreen ? Number(win.fullscreen) : 0;
        if (fs !== 0 && !owner.openOverFullscreen)
            return;
        // BEFORE the popup opens: the service pastes into this window.
        owner.service.origin = win ? {
            address: owner._normAddress(win.address),
            cls: String(win["class"] || "")
        } : null;
        owner.open();
    }
    Process {
        id: windowCheck
        command: ["hyprctl", "activewindow", "-j"]
        // Decide on the whole answer: the collector's text is complete when
        // its stream ends, which is not ordered against the exit.
        stdout: StdioCollector {
            id: activeWindow
            onStreamFinished: {
                let w = null;
                try {
                    w = JSON.parse(activeWindow.text || "{}");
                } catch (e) {
                    w = null;
                }
                owner._decided(w);
            }
        }
    }

    // The linter cannot resolve GlobalShortcut (PostReloadHook "was not
    // found"): Quickshell 0.3.1's _GlobalShortcuts qmldir does not declare
    // `depends Quickshell`. It resolves at runtime (see LauncherBarOwner).
    LazyLoader {
        active: owner.shortcutEnabled && !owner.shellHosted
        GlobalShortcut {
            appid: "lares"
            name: "clipboard"
            description: "Open the clipboard shelf"
            onPressed: owner.toggle()
        }
    }
    // The keyboard of the open popup, where the host has a window to grab for: the popup asks the
    // layer for no keyboard of its own meanwhile (ClipboardPopup.grabbed).
    readonly property bool _grabActive: owner.popupMine && owner.grabWindows.length > 0
    HyprlandFocusGrab {
        active: owner._grabActive
        windows: owner.grabWindows
        onCleared: owner.close()
    }
}
