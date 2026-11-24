pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// =============================================================================
// KeyRelease.qml -- "a window opened or took the focus": the event that makes a popup let go of the keyboard.
//
// The case: the LLM open over an empty desktop, a kitty opened by a keybind, and what is typed goes into the LLM's composer -- the
// popup's keyboard (on-demand, or a focus grab) outranks the new window's. The compositor tells us on socket2:
//
//   openwindow>>ADDRESS,WORKSPACE,CLASS,TITLE    a window mapped (WORKSPACE is the workspace's NAME: "3")
//   activewindowv2>>ADDRESS                      a window took the focus (empty when none has it: ignored)
//
// and neither names a monitor, so the SCREEN is the one that shows the window's workspace (openwindow), else the focused one. The
// answer waits one short timer (`settleMs`) so that FocusedScreen, which hears the same line, has taken the focus move that goes
// with it. `released(screenName, address, byFocus)` is the whole output, the address of the window an openwindow named ("0x.." or "") and
// whether ONLY a focus event was heard (activewindowv2: the compositor also sends it when a popup's own opening or closing changes hands
// of the focus, so the engine ignores it for a moment after any change of its popup); the shell hands it to that screen's engine
// (`releaseKeys()`), which does nothing when no popup is up there.
//
// A RELEASE ALONE DOES NOT HAND THE WINDOW THE KEYS. In the nested Hyprland a window that maps while a popup's layer holds
// the keyboard is NOT given the focus, and when the layer lets go the compositor refocuses the LAST window (the old one) -- on an empty
// desktop, none: `activewindow` stays empty and the typing goes nowhere. So after an effective release the shell focuses the window that
// opened (`focusWindow`), and puts the pointer back where it was: `hl.dsp.focus({ window })` warps the pointer to the window's centre
// (CLAUDE.md, the Lua laws), and a pointer that jumps because a window opened is a bug of its own.
//
//   live        true listens to the compositor's event line; false hears nothing (a fake drives `handleEvent`)
//   focusSource the shell's FocusedScreen (its `name` and `monitors`)
// =============================================================================
Item {
    id: root

    property bool live: false
    property var focusSource: null
    property int settleMs: 30

    signal released(string screenName, string address, bool byFocus)

    // For a probe: the events that counted, oldest first ("openwindow"), the windows focused after a release, and the last Lua sent.
    property var seen: []
    property var focused: []
    property string lastLua: ""

    property string _screen: ""
    property string _address: ""
    property bool _opened: false

    // One socket2 line, split at ">>".
    function handleEvent(eventName: string, data: string): void {
        if (eventName === "openwindow") {
            const parts = String(data).split(",");
            root._address = parts.length > 0 && parts[0] !== "" ? "0x" + parts[0] : "";
            root._opened = true;
            root._note(root._screenOfWorkspace(parts.length > 1 ? parts[1] : ""), eventName);
        } else if (eventName === "activewindowv2") {
            const addr = String(data).trim();
            if (addr === "" || addr === ",")
                return;
            root._note("", eventName);
        }
    }

    function _screenOfWorkspace(ws: string): string {
        const id = /^-?\d+$/.test(ws) ? parseInt(ws, 10) : NaN;
        const mons = root.focusSource ? root.focusSource.monitors : [];
        if (!isNaN(id) && mons)
            for (let i = 0; i < mons.length; i++)
                if (mons[i].activeWorkspaceId === id)
                    return mons[i].name;
        return "";
    }

    function _note(screenName: string, what: string): void {
        // a window event with a monitor of its own wins over a bare focus event inside the same settle
        if (screenName !== "" || root._screen === "")
            root._screen = screenName !== "" ? screenName : "?";
        root.seen = root.seen.concat([what]);
        settle.restart();
    }

    Timer {
        id: settle
        interval: root.settleMs
        onTriggered: {
            let name = root._screen;
            const address = root._address;
            const byFocus = !root._opened;
            root._screen = "";
            root._address = "";
            root._opened = false;
            if (name === "?" || name === "")
                name = root.focusSource ? root.focusSource.name : "";
            if (name !== "")
                root.released(name, address, byFocus);
        }
    }

    // Focus the window that opened, the pointer left where it is (one Lua chunk: the position is read before the dispatch moves it).
    function focusWindow(address: string): void {
        if (!/^0x[0-9a-fA-F]+$/.test(address))
            return;
        root.focused = root.focused.concat([address]);
        root.lastLua = 'local p = hl.get_cursor_pos() hl.dispatch(hl.dsp.focus({ window = "address:' + address
            + '" })) if p then hl.dispatch(hl.dsp.cursor.move({ x = p.x, y = p.y })) end';
        if (!root.live)
            return;
        focuser.command = ["hyprctl", "eval", root.lastLua];
        focuser.running = true;
    }
    Process {
        id: focuser
    }

    LazyLoader {
        active: root.live
        component: Scope {
            Connections {
                target: Hyprland
                function onRawEvent(ev) {
                    root.handleEvent(ev.name, ev.data);
                }
            }
        }
    }
}
