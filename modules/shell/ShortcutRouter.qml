pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland

import "../common/flourish"

// =============================================================================
// ShortcutRouter.qml -- the shell's keys, registered ONCE (CONTRACT section 2).
//
// GlobalShortcuts of the appid "lares", bound in Hyprland's Lua config (keybinds.lua; `lares binds`
// prints the lines and checks them):
//
//   launcher   Alt+Space   the focused screen's launcher `shortcutPressed()` (it asks hyprctl for a
//                          fullscreen window first, opens from the bottom bar, takes the keyboard by a focus grab)
//   clipboard  Alt+V       the focused screen's clipboard `toggle()` (its owner already holds the grab)
//   picker     Alt+Period    the focused screen's emoji / symbol picker `toggle()` (replaces rofimoji; same path as the clipboard)
//   notes      Alt+N       the focused screen's notes `shortcutPressed()`: a popup opened by a KEY, keyboard
//                          by a grab; a click on the button stays `toggle()`
//   bars       Super+F2    every screen's bars hide / show together
//   lock       Super+L     the lock, through the power reel's own path (ReelActions.firePower("lock"): the same command, and every
//                          screen's padlock plays its flourish while the lock comes up); nothing while the session is locked.
//                          The user binds it: hl.bind("SUPER + L", hl.dsp.global("lares:lock"))
//   popup-escape           (no config bind) the runtime bind on a bare Escape that EscapeBind holds while a popup is open
//                          (and its keys are not let go to a window): the focused screen's popup closes (or its content's `handleEscape()` takes the key)
//
// A KEY THAT OPENS A POPUP PLAYS THE MODULE'S BAR GLYPH, as a hover would (`_keyFlourish`): the glyph's flourish is registered in
// FlourishRegistry under its `group`, and a key opens the popup of the owner whose key name IS that group ("notes"), so the entry under
// the screen the popup opens on plays its `demo()` -- the hover's own motion, with the hover's own rules (armed, not while it plays).
// Only a key that OPENS (a close plays nothing) and only a module whose glyph has a flourish (the launcher, the clipboard and the picker have
// none: nothing plays). A module that gets a key later needs NOTHING here when its flourish `group` is its key's name; a different group
// is one more line in `_flourishGroup`. The lock key has its own (every padlock plays through ReelActions.firePower).
//
// One registration per name per shell, however many screens: a hosted owner (`shellHosted`) registers none of its own (the
// launcher and the clipboard are also told `shortcutEnabled: false`; the notes owner has no shortcut member at all). A shortcut acts on PRESS (`hyprctl dispatch` of a global sends a press and
// no release; a held key sends both). The linter cannot resolve GlobalShortcut ("PostReloadHook was not
// found": Quickshell 0.3.1's _GlobalShortcuts qmldir does not declare `depends Quickshell`); it resolves at
// runtime (LauncherBarOwner has the same note).
// =============================================================================
Scope {
    id: root

    property var services: null
    property bool enabled: true

    // For a probe: the key presses that arrived, oldest first.
    property var presses: []

    // The flourish group of a key's glyph, when it is not the key's own name ("" = the key's name).
    readonly property var _flourishGroup: ({})

    // The screen (its frame) an owner is on: the one whose `owners` holds it.
    function _frameOf(key: string, o: var): var {
        const frames = root.services.frames || {};
        const names = Object.keys(frames);
        for (let i = 0; i < names.length; i++) {
            if (root.services.ownerOn(names[i], key) === o)
                return frames[names[i]];
        }
        return null;
    }

    // The key opened `o`'s popup: play the glyph of that module on that screen only. Returns how many flourishes it started.
    function _keyFlourish(key: string, o: var): int {
        const frame = root._frameOf(key, o);
        if (!frame || !FlourishRegistry.keyPlays)
            return 0;
        const group = root._flourishGroup[key] || key;
        let n = 0;
        const mine = FlourishRegistry.entriesUnder(frame);
        for (let i = 0; i < mine.length; i++) {
            if (mine[i].group === group && mine[i].shown && mine[i].demo())
                n++;
        }
        return n;
    }

    function press(name: string): void {
        root.presses = root.presses.concat([name]);
        if (!root.services)
            return;
        if (name === "escape") {
            root.services.escapePressed();
            return;
        }
        if (name === "bars") {
            root.services.barsShown = !root.services.barsShown;
            return;
        }
        if (name === "lock") {
            if (root.services.reelActions && !(root.services.lock && root.services.lock.locked))
                root.services.reelActions.firePower("lock");
            return;
        }
        const key = name === "launcher" ? "launcher" : name === "clipboard" ? "clipboard" : name === "picker" ? "picker" : "notes";
        // a module that is switched off (shell.jsonc `modules`) has no popup to open
        if (root.services.moduleOn && !root.services.moduleOn(key))
            return;
        const o = root.services.focusedOwner(key);
        if (!o)
            return;
        const was = o.popupMine === true;
        if (name === "launcher")
            o.shortcutPressed();
        else if (name === "clipboard" || name === "picker")
            o.toggle();
        else if (o.shortcutPressed)
            o.shortcutPressed();
        else
            o.toggle();
        // a key that OPENED the popup plays its module's glyph, if it has a flourish
        if (!was && o.popupMine === true)
            root._keyFlourish(key, o);
    }

    LazyLoader {
        active: root.enabled
        Scope {
            GlobalShortcut {
                appid: "lares"
                name: "launcher"
                description: "Open the application launcher"
                onPressed: root.press("launcher")
            }
            GlobalShortcut {
                appid: "lares"
                name: "clipboard"
                description: "Open the clipboard shelf"
                onPressed: root.press("clipboard")
            }
            GlobalShortcut {
                appid: "lares"
                name: "picker"
                description: "Open the emoji and symbol picker"
                onPressed: root.press("picker")
            }
            GlobalShortcut {
                appid: "lares"
                name: "notes"
                description: "Open the notes"
                onPressed: root.press("notes")
            }
            // Not bound in the config: EscapeBind adds the bare-Escape bind at runtime while a popup holds the keys
            GlobalShortcut {
                appid: "lares"
                name: "popup-escape"
                description: "Close the open popup (Escape, bound while one is open)"
                onPressed: root.press("escape")
            }
            GlobalShortcut {
                appid: "lares"
                name: "bars"
                description: "Hide or show all the bars"
                onPressed: root.press("bars")
            }
            GlobalShortcut {
                appid: "lares"
                name: "lock"
                description: "Lock the session (the power reel's Lock)"
                onPressed: root.press("lock")
            }
        }
    }
}
