pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// =============================================================================
// NaturalScroll.qml -- whether Hyprland flips the wheel for the touchpad and for a mouse (`input:touchpad:natural_scroll`,
// `input:natural_scroll`). READ ONLY (`hyprctl -j getoption`), once when it starts and again on every `configreloaded`.
//
// WHY. Qt can say that a wheel's deltas were flipped (`WheelEvent.inverted`, set from wl_pointer's axis_relative_direction),
// but Hyprland reports every axis event as IDENTICAL whatever it did to the deltas (with
// natural scrolling on, fingers moving up arrive as a negative angle delta and `inverted` false, so a reader that
// trusted `inverted` alone would turn the volume down). The compositor's own setting is the truth. A wheel reader
// flips a delta when `inverted` is true OR when the device's kind is natural here -- one flip, either way.
//
// A touchpad event is the one that carries a pixel delta (CLAUDE.md: a touchpad on Wayland sends angle deltas too); a mouse
// notch carries none. `live` false (a mockup, a mock run, a probe) asks nobody: both stay false unless the host sets them.
// =============================================================================
Item {
    id: root

    property bool live: false
    property bool touchpad: false
    property bool mouse: false

    readonly property string _mark: "@@NATURALSCROLL@@"
    function refresh(): void {
        if (!root.live)
            return;
        if (reader.running) {
            again.restart();
            return;
        }
        reader.running = true;
    }
    function _parse(text: string): void {
        const parts = text.split(root._mark);
        if (parts.length < 2)
            return;
        root.touchpad = root._on(parts[0]);
        root.mouse = root._on(parts[1]);
    }
    // One `hyprctl -j getoption` answer of a flag: {"option": "...", "bool": true, "set": true} (as Hyprland 0.56 prints it; an
    // `int` member is read too). Anything that is not that (no hyprctl, an option it does not have) is off.
    function _on(text: string): bool {
        try {
            const o = JSON.parse(text.trim());
            if (typeof o.bool === "boolean")
                return o.bool;
            return typeof o.int === "number" && o.int !== 0;
        } catch (e) {
            return false;
        }
    }

    Timer {
        id: again
        interval: 120
        onTriggered: root.refresh()
    }
    Process {
        id: reader
        command: ["sh", "-c", "hyprctl -j getoption input:touchpad:natural_scroll 2>/dev/null; echo '" + root._mark
                  + "'; hyprctl -j getoption input:natural_scroll 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: root._parse(this.text)
        }
    }

    LazyLoader {
        active: root.live
        component: Scope {
            Connections {
                target: Hyprland
                function onRawEvent(ev) {
                    if (ev.name === "configreloaded")
                        again.restart();
                }
            }
            Component.onCompleted: root.refresh()
        }
    }
}
