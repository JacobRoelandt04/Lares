pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// =============================================================================
// PickerBarOwner.qml -- the emoji / symbol picker's bar-side owner.
//
// The bar engine builds a popup's content on open and destroys it on close, so what must outlive the popup lives here or is
// handed in: the SERVICE (PickerService -- INJECTED, never built here: the data, the memory, the paste), the style (PickerStyle:
// every number of the grid) and the popup's few own tunables. The popup rises from the bottom bar (`barId`) like the clipboard's,
// and there is no bar button: it opens by the shortcut only.
//
// HYPRLAND BIND (the user's keybinds.lua; it replaced rofimoji's `hl.bind("SUPER + PERIOD", hl.dsp.exec_cmd("rofimoji"))`):
//
//     hl.bind("ALT + PERIOD", hl.dsp.global("lares:picker"))
//
// HOW IT OPENS -- the clipboard owner's, member for member (docs/clipboard.md, "Pasting"): the bind is a GlobalShortcut named
// "picker" (appid "lares"), registered by the real shell only (`shortcutEnabled`); pressed again it closes. Before anything
// opens, ONE `hyprctl -j activewindow` answers which window the paste is FOR (written to `service.origin`: {address, cls}),
// whether that window is fullscreen (no open over it unless `openOverFullscreen`), and what to do with no answer (it opens anyway
// with `service.origin = null`, and the pick then only copies). A key-opened popup takes the keyboard exclusively, or a
// HyprlandFocusGrab over the shell's bar windows closes it on a click anywhere else.
//
// `service.hostOpen` is true exactly while this popup is the engine's: the service forwards it to the clipboard service, which
// sends the paste key only after the keyboard is let go.
//
// SHELL-HOSTED (`shellHosted`, docs/contracts/shell.md section 4): the shell has one owner PER SCREEN on ONE service, so the
// owner writes no property of the service but `origin` (once, by the act of opening) and registers no shortcut -- the shell's one
// ShortcutRouter sends the key to the focused screen's `toggle()`. `sharedFlags.hostOpen` is the value the Binding would have
// written; the host sets `service.hostOpen` to the OR over its screens.
// =============================================================================
Item {
    id: owner

    property var engine: null
    property var bar: null
    property string barId: "launcherBar"
    property string ownerId: "picker"
    // Where along the bar the popup grows from (bar-local); -1: its middle.
    property real anchorAlong: -1

    // The service (PickerService): injected.
    property var service: null
    // A PickerStyle; the owner's host builds one (the panel writes it).
    property PickerStyle style: null
    // The popup's own tunables (the mockup's panel writes them here).
    property string fontFamily: "Inter"
    // What picker.jsonc says (PickerPopup, the same names).
    property var tabList: ["emoji", "symbols", "nerd"]
    property string openTab: "emoji"
    property string nerdPick: "glyph"
    property bool recents: true

    // The Alt+Period shortcut is registered by the real shell only.
    property bool shortcutEnabled: true
    // Shell-hosted: no GlobalShortcut, no write of a service property (see the header).
    property bool shellHosted: false
    // What this owner would have written on the service: the host sets the service's flag to
    // the OR of its screens' values.
    readonly property var sharedFlags: ({ hostOpen: owner.popupMine })
    // The windows a shortcut-opened popup grabs focus for (the shell's bar
    // windows). None in a mockup: it is an ordinary window.
    property var grabWindows: []
    // The clipboard's openOverFullscreen (clipboard.jsonc, read by the clipboard service this one pastes through): open while the
    // active window is fullscreen (the shell's window is raised for this popup).
    property bool openOverFullscreen: !!owner.service && owner.service.openOverFullscreen === true
    // Ask Hyprland for the active window before opening. A mockup or a probe
    // turns it off: the service keeps the origin it was given.
    property bool liveWindow: true

    readonly property bool popupMine: !!owner.engine && owner.engine.popupOpen && owner.engine.popupOwnerId === owner.ownerId
    // The shell's popup stack (GooeyEngine "THE POPUP STACK"): opening the picker over another popup does not close it for good,
    // and the picker's close gives the place back.
    readonly property bool joinsPopupStack: true

    // The paste key is sent after the popup has let go of the keyboard.
    Binding {
        target: owner.service
        property: "hostOpen"
        value: owner.popupMine
        when: !!owner.service && !owner.shellHosted
    }

    readonly property Component popupComponent: Component {
        PickerPopup {
            id: content
            service: owner.service
            style: owner.style
            grabbed: owner._grabActive
            fontFamily: owner.fontFamily
            tabList: owner.tabList
            openTab: owner.openTab
            nerdPick: owner.nerdPick
            recents: owner.recents
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
            name: "picker"
            description: "Open the emoji and symbol picker"
            onPressed: owner.toggle()
        }
    }
    // The keyboard of the open popup, where the host has a window to grab for: the popup asks the
    // layer for no keyboard of its own meanwhile (PickerPopup.grabbed).
    readonly property bool _grabActive: owner.popupMine && owner.grabWindows.length > 0
    HyprlandFocusGrab {
        active: owner._grabActive
        windows: owner.grabWindows
        onCleared: owner.close()
    }
}
