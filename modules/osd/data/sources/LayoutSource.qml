pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "../OsdKinds.js" as Kinds

// =============================================================================
// LayoutSource.qml -- the keyboard layout, shown when it switches.
//
//   signal request(var req)    one partial CONTRACT section 1 request
//
// Hyprland says `activelayout>>KEYBOARD,LAYOUT NAME` on its event socket
// (read as Quickshell.Hyprland's `rawEvent`). Here kb_layout is "us,be" with
// grp:alts_toggle, the user switches by pressing both Alt keys, and every
// keyboard device of the machine answers it with an event of its own (the
// video bus, the power button...), so:
//
//   - only ONE keyboard counts: `keyboard: "main"` = the keyboard `hyprctl -j
//     devices` marked `main: true` when this source first read it (the one the
//     user types on), or a keyboard's name as written. It is STICKY: Hyprland
//     makes a keyboard main the moment it is added (a USB headset's media keys,
//     a virtual keyboard), and following it made the plugging of one show the
//     layout card ("US", which it was), then lose every real switch once the
//     device went again. The primary is re-picked only when it has left the
//     list;
//   - an event from a keyboard this source has never heard of re-reads the
//     device list first and is judged after it (a hot-plugged keyboard, or the
//     first event of the session before the list has come back);
//   - the layout in force is what the primary's `active_keymap` says at the
//     first read, so the first event of a session is not "a change" from
//     nothing; after that it is the last layout the primary reported;
//   - the same layout twice inside `dedupeMs` is one event, and so is a layout
//     that is already the shown one.
//
// The code on the card comes from `codes` (osd.jsonc's `layout.codes`), then
// OsdKinds.layoutCode's own fallbacks.
//
// `live: false` listens to nothing and runs no hyprctl: simulateDevices(text)
// is the device list, simulateEvent(data) is one `activelayout` payload.
// =============================================================================
Item {
    id: root

    property bool live: true
    property string keyboard: "main"
    property var codes: ({})
    property int dedupeMs: 100

    signal request(var req)

    readonly property string layout: root._layout

    property string _main: ""
    property var _known: ({})
    property string _layout: ""
    property double _lastAt: 0
    property var _waiting: []

    function _isOurs(kb) {
        if (root.keyboard !== "main")
            return kb === root.keyboard;
        return kb === root._main;
    }

    function _onRaw(name, data) {
        if (name !== "activelayout")
            return;
        const ev = Kinds.parseActiveLayout(data);
        if (!ev)
            return;
        // Hyprland's getActiveLayout says `error` or `none` when it has no layout name for the keymap of the moment, which is every keyboard being added: a resume re-adds
        // them all (0.57, measured in tools/dev/lock_env.sh with a virtual keyboard: `<kb>,none`, `<kb>,error`, then the real name). Neither is a layout: shown, the card would say "ER".
        if (ev.layout === "error" || ev.layout === "none")
            return;
        // An unknown keyboard asks for a fresh list; its event waits for it.
        if (root._known[ev.keyboard] !== true && root.keyboard === "main") {
            root._waiting = root._waiting.concat([ev]);
            root._refreshDevices();
            return;
        }
        root._judge(ev);
    }

    function _judge(ev) {
        if (!root._isOurs(ev.keyboard))
            return;
        const now = Date.now();
        const same = ev.layout === root._layout;
        const fresh = now - root._lastAt >= root.dedupeMs;
        root._layout = ev.layout;
        if (same || !fresh)
            return;
        root._lastAt = now;
        root.request({
            kind: "layout",
            key: "layout",
            source: "external",
            layout: { code: Kinds.layoutCode(ev.layout, root.codes), name: ev.layout }
        });
    }

    // `hyprctl -j devices`: Hyprland writes a bare `none` for a keyboard with no
    // keymap, which is not JSON.
    function _applyDevices(text) {
        let kbs = [];
        try {
            const d = JSON.parse(String(text).replace(/:\s*none\b/g, ": null"));
            kbs = d && d.keyboards ? d.keyboards : [];
        } catch (e) {
            kbs = [];
        }
        const known = {};
        let seatMain = "";
        const keymap = {};
        for (let i = 0; i < kbs.length; i++) {
            known[kbs[i].name] = true;
            keymap[kbs[i].name] = typeof kbs[i].active_keymap === "string" ? kbs[i].active_keymap : "";
            if (kbs[i].main === true)
                seatMain = kbs[i].name;
        }
        root._known = known;
        // The primary keyboard stays the one first seen as main while it is still there: the seat's `main` moves to
        // whatever keyboard was added or typed on last.
        if (root._main === "" || known[root._main] !== true)
            root._main = seatMain !== "" ? seatMain : root._main;
        // What is in force now, when nothing has said yet. `error` and `none` are a keyboard that has no keymap of
        // its name this moment, not a layout.
        const now = keymap[root._main];
        if (root._layout === "" && now && now !== "error" && now !== "none")
            root._layout = now;
        const w = root._waiting;
        root._waiting = [];
        for (let j = 0; j < w.length; j++) {
            // Still unknown after the refresh: the event is not a keyboard's.
            if (root._known[w[j].keyboard] === true)
                root._judge(w[j]);
        }
    }

    function _refreshDevices() {
        if (root.live)
            devices.running = true;
    }

    function simulateDevices(text) {
        root._applyDevices(text);
    }
    function simulateEvent(data) {
        root._onRaw("activelayout", data);
    }

    Process {
        id: devices
        command: ["hyprctl", "-j", "devices"]
        stdout: StdioCollector {
            onStreamFinished: root._applyDevices(this.text)
        }
    }

    LazyLoader {
        active: root.live
        component: Scope {
            Connections {
                target: Hyprland
                function onRawEvent(ev) {
                    root._onRaw(ev.name, ev.data);
                }
            }
        }
    }

    Component.onCompleted: root._refreshDevices()
}
