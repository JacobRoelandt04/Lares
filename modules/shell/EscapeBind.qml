pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// =============================================================================
// EscapeBind.qml -- the runtime Hyprland bind on a bare Escape.
//
// While a popup is open (`wanted`: ShellServices.escapeWanted -- any popup, whether or not it asks for the keyboard, and whether or not its
// keys were let go to a window: the first Escape with a popup up is the popup's) the shell asks Hyprland for
//
//     hl.bind("Escape", hl.dsp.global("lares:popup-escape"))
//
// which ShortcutRouter's GlobalShortcut of that name answers (ShellServices.escapePressed -> the engine's `pressEscape()`). The bind is
// modifier-less: Hyprland matches a bind's modifiers exactly, so Shift+Esc, Ctrl+Esc, Super+Esc (the user's own binds) are not it and
// reach their clients as ever, and no other key is bound. It is taken out again the moment nothing wants it, and put back on socket2's
// `configreloaded` (a reload drops every runtime bind) while something still does.
//
// Hyprland facts this rests on (tools/shell/lares, THE HYPRLAND FORMS): `hyprctl eval` answers "ok" (a Lua error exits 7, a Lua
// WARNING exits 0 -- the text is read); hl.unbind compares the key's SPELLING, so "Escape" removes only the bare one; binding twice keeps
// both, so every apply unbinds first. The user's config has no bare Escape bind (keybinds.lua); if it ever gets one, this unbind takes
// it out until the next reload.
//
// A bind that outlives the shell eats Escape for nothing (a global shortcut nobody answers still consumes the key): the shell takes it
// out on its way down, and a shell that starts clears whatever a dead one left, before anything is wanted.
//
//   live    true runs hyprctl; false only records `lastLua` (a mock shell, a probe)
//   wanted  the bind should be in
// =============================================================================
Item {
    id: root

    property bool live: false
    property bool wanted: false

    // What is in force (true after an apply that Hyprland answered), and the last Lua sent: probes read them.
    readonly property bool applied: root._applied
    property string lastLua: ""
    property int sent: 0
    property string lastReply: ""

    readonly property string bindKeys: "Escape"
    readonly property string unbindLua: 'hl.unbind("' + root.bindKeys + '")'
    readonly property string bindLua: root.unbindLua + ' hl.bind("' + root.bindKeys + '", hl.dsp.global("lares:popup-escape"))'

    property bool _applied: false
    property bool _busy: false
    property bool _again: false
    property bool _started: false

    onWantedChanged: root._sync()

    // Ask for the state `wanted` says (idempotent: a state already in force sends nothing unless `force`).
    function _sync(force: bool): void {
        if (!root._started)
            return;
        if (root._busy) {
            root._again = true;
            return;
        }
        if (!force && root.wanted === root._applied)
            return;
        root._send(root.wanted ? root.bindLua : root.unbindLua, root.wanted);
    }

    function _send(lua: string, on: bool): void {
        root.lastLua = lua;
        root.sent += 1;
        if (!root.live) {
            root._applied = on;
            return;
        }
        root._busy = true;
        runner.pendingOn = on;
        runner.command = ["hyprctl", "eval", lua];
        runner.running = true;
    }

    Process {
        id: runner
        property bool pendingOn: false
        stdout: StdioCollector {
            id: out
        }
        stderr: StdioCollector {
            id: err
        }
        onExited: (code, status) => {
            const text = (out.text + err.text).trim();
            root.lastReply = text;
            const bad = code !== 0 || /^(error|warning)/i.test(text);
            if (bad)
                console.warn("EscapeBind: hyprctl eval said: " + text + " (exit " + code + ")");
            root._applied = !bad && runner.pendingOn;
            root._busy = false;
            if (root._again) {
                root._again = false;
                root._sync();
            }
        }
    }

    // A reload took the bind: put it back if it is wanted.
    LazyLoader {
        active: root.live
        component: Scope {
            Connections {
                target: Hyprland
                function onRawEvent(ev) {
                    if (ev.name === "configreloaded") {
                        root._applied = false;
                        root._sync();
                    }
                }
            }
        }
    }

    // Start: clear what a dead shell left (an unbind is "ok" when nothing is bound), then follow `wanted`.
    Component.onCompleted: {
        root._started = true;
        root._send(root.unbindLua, false);
        if (root.wanted)
            root._sync();
    }

    // The way down: the bind must not outlive the shell. A detached hyprctl, because this process is going.
    Component.onDestruction: {
        if (root.live && (root._applied || root._busy))
            Quickshell.execDetached(["hyprctl", "eval", root.unbindLua]);
    }
}
