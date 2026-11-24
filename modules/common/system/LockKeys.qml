pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// LockKeys.qml -- are caps lock / num lock on. The lock's dots show caps; the
// OSD reports both.
//
// Qt does not say: a surface only sees the keys typed. Hyprland knows
// (`hyprctl -j devices`, a `capsLock` and a `numLock` per keyboard), so this
// asks it. `num` follows the same any-keyboard rule as `caps`.
//
// WHY IT ASKS MORE THAN ONCE. Asking once at start and once 60 ms after a Caps
// Lock PRESS, and taking the answer of the "main" keyboard only, would leave
// the indicator on: a real laptop has several keyboards (the keyboard, a power
// button, a consumer-control device...) and `main` is the one Hyprland last
// heard from, not necessarily the one holding the lock; the compositor's own
// update can also land after a single 60 ms look. Nothing would ask again, so
// a wrong answer would be kept for the rest of the lock. So:
//   - caps is on when ANY keyboard says so;
//   - a Caps Lock (or Num Lock) press AND its release each ask three times (now, +80 ms,
//     +250 ms), and a read requested while one is running is run again when it
//     ends, never dropped;
//   - while caps shows, every key asks once more (throttled) and a 1 s poll
//     keeps asking, so a stale "on" cannot outlive its cause by more than a
//     second whatever happened to the events.
// A failed read leaves the previous answer: a wrong "caps on" is worse than a
// stale one, and both are cosmetic (the password itself is never affected).
// The poll heals a stale caps "on" only: num is on most of the time on a desk
// keyboard, and a poll for it would cost a `hyprctl` a second for nothing. `num`
// is read at start and after every Num Lock press and release (a change made
// elsewhere, with no key here, is not seen until the next key or `refresh()`).
// =============================================================================
Scope {
    id: root

    property bool caps: false
    property bool num: false
    // The last answer per keyboard: { "<name>": { caps, num } } (which keyboard flipped is the OSD's question), and each answer as it lands.
    property var boards: ({})
    signal answered
    // The poll's period while caps shows (a probe shortens it).
    property int pollMs: 1000
    // Reads started, for probes.
    property int reads: 0

    function keyPressed(key) {
        if (key === Qt.Key_CapsLock || key === Qt.Key_NumLock)
            root._burst();
        else if (root.caps)
            root.refresh();
    }
    function keyReleased(key) {
        if (key === Qt.Key_CapsLock || key === Qt.Key_NumLock)
            root._burst();
    }
    // Ask now and again shortly after: the LED state and the compositor's
    // report can both trail the key.
    function _burst() {
        root.refresh();
        late1.restart();
        late2.restart();
    }
    function refresh() {
        if (probe.running)
            root._again = true;
        else
            root._start();
    }
    property bool _again: false
    function _start() {
        root.reads++;
        probe.running = true;
    }

    // Caps (num) is on when any keyboard has it on. Hyprland writes a bare `none`
    // for a keyboard with no keymap (a virtual one): not JSON.
    function parse(text) {
        try {
            const d = JSON.parse(String(text).replace(/:\s*none\b/g, ": null"));
            const kbs = (d && d.keyboards) ? d.keyboards : [];
            if (kbs.length === 0)
                return;
            const b = {};
            for (let i = 0; i < kbs.length; i++)
                b[b[String(kbs[i].name)] === undefined ? String(kbs[i].name) : kbs[i].name + "#" + i] = { caps: kbs[i].capsLock === true, num: kbs[i].numLock === true };
            root.boards = b;
            root.caps = kbs.some(k => k.capsLock === true);
            root.num = kbs.some(k => k.numLock === true);
        } catch (e) {
            return;
        }
        root.answered();
    }

    Process {
        id: probe
        command: ["hyprctl", "-j", "devices"]
        stdout: StdioCollector {
            onStreamFinished: root.parse(this.text)
        }
        onRunningChanged: {
            if (!probe.running && root._again) {
                root._again = false;
                root._start();
            }
        }
    }
    Timer {
        id: late1
        interval: 80
        onTriggered: root.refresh()
    }
    Timer {
        id: late2
        interval: 250
        onTriggered: root.refresh()
    }
    Timer {
        interval: root.pollMs
        repeat: true
        running: root.caps
        onTriggered: root.refresh()
    }

    Component.onCompleted: root.refresh()
}
