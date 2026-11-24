pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "HyprRegistry.js" as Reg

// =============================================================================
// HyprSettings.qml -- the compositor settings the lock's desktop choreography
// flips, in order, and what puts them back. One per lock.
//
// WHAT IT FLIPS (the compositor's own blur is never used). What a lock can
// see of the desktop beneath it depends on two Hyprland options:
//   misc:session_lock_xray     on  = the desktop is rendered beneath the lock
//                              off = black (nothing drawn: the GPU idles)
//   misc:session_lock_blur     on  = the desktop beneath is BLURRED
// The shipped config keeps xray OFF and blur ON (a lock that has not drawn
// yet must never show the desktop sharp). The choreography turns them over:
//   prepareLock   BEFORE locked=true: xray on, lock blur off, so the first lock
//                 frame IS the live sharp desktop (no jump) and S0 can be
//                 captured of it
//   screenSettled the veil is up over S0: xray off. Hyprland stops rendering the
//                 desktop for the rest of the lock (GPU idle); blur stays off
//   prepareUnlock xray on, blur off: the live SHARP desktop beneath the fading
//                 lock (asked for shortly before the fade, beneath an opaque lock)
//   restore       the shipped values
//
// HOW. `hyprctl eval 'hl.config({ ... })'` (the Lua config, which
// works at runtime). Calls are ordered: each one is queued and started when the
// previous exited, because two racing evals may land in either order and the
// last one wins. `busy` is false when the queue is empty and nothing runs;
// `idle()` is emitted then, and `applied(name)` after each call.
//
// SEVERAL SCREENS, ONE SWITCH. xray is global, so the desktop may only go dark
// when EVERY screen has settled: a DesktopLayer registers its screen and
// reports that its veil is up over S0; the last one triggers xray off. That bookkeeping lives in
// HyprRegistry.js (a .pragma library, shared by every instance in the engine:
// the lock's own, and the one a DesktopLayer makes when its host did not hand
// it the lock's). A screen that registers after xray went off (hotplug while
// locked) finds `frozen` true and is treated like a boot lock: nothing beneath
// it to capture.
// =============================================================================
Scope {
    id: root

    readonly property bool busy: root._running || root._queue.length > 0
    // xray was switched off by a settle: the desktop beneath is no longer drawn
    readonly property bool frozen: root._tick >= 0 && Reg.isFrozen()
    // the queue drained
    signal idle()
    // one call finished: its name and hyprctl's reply
    signal applied(string name, string reply)
    // A probe arms a fault by turning this off: the final xray-off is skipped.
    property bool freezeEnabled: true

    property var _queue: []
    property bool _running: false
    // bumped when the shared registry changes, so `frozen` re-reads it
    property int _tick: 0
    property string _current: ""

    function _lua(misc): string {
        return "hl.config({ misc = { " + misc + " } })";
    }

    function _enqueue(name: string, lua: string): void {
        const q = root._queue.slice();
        q.push({ name: name, lua: lua });
        root._queue = q;
        root._pump();
    }

    function _pump(): void {
        if (root._running || root._queue.length === 0)
            return;
        const q = root._queue.slice();
        const job = q.shift();
        root._queue = q;
        root._current = job.name;
        root._running = true;
        proc.command = ["hyprctl", "eval", job.lua];
        proc.running = true;
    }

    // BEFORE locked = true. A boot lock changes nothing: it starts from the
    // shipped values (xray off = black) and there is nothing to show.
    function prepareLock(boot: bool): void {
        Reg.reset();
        root._tick++;
        if (boot)
            return;
        root._enqueue("prepareLock", root._lua("session_lock_xray = true, session_lock_blur = false"));
    }

    function register(name: string): void {
        Reg.register(name);
    }

    // One screen shows S0: when all do, the desktop goes dark.
    function screenSettled(name: string): void {
        const last = Reg.settle(name);
        root._tick++;
        if (last && root.freezeEnabled)
            root._enqueue("freeze", root._lua("session_lock_xray = false"));
        else if (last)
            Reg.thaw();
    }

    // The live SHARP desktop beneath the fading lock. Idempotent across
    // instances.
    function prepareUnlock(): void {
        if (!Reg.beginUnlock())
            return;
        root._tick++;
        root._enqueue("prepareUnlock", root._lua("session_lock_xray = true, session_lock_blur = false"));
    }

    // The shipped values, whatever state the lock ended in.
    function restore(): void {
        Reg.thaw();
        root._tick++;
        root._enqueue("restore", root._lua("session_lock_xray = false, session_lock_blur = true"));
    }

    Process {
        id: proc
        stdout: StdioCollector {
            id: out
        }
        stderr: StdioCollector {
            id: err
        }
    }
    // (an inline `onExited: (code, status) =>` makes qmllint warn about
    // QProcess::ExitStatus; a Connections is the repo's idiom, CurlRequest.qml)
    Connections {
        target: proc
        function onExited(code) {
            const reply = String(out.text).trim() + String(err.text).trim();
            if (code !== 0 || (reply !== "" && reply !== "ok"))
                console.warn("HyprSettings: " + root._current + " -> exit " + code + " '" + reply + "'");
            root._running = false;
            root.applied(root._current, reply);
            root._pump();
            if (!root.busy)
                root.idle();
        }
    }
}
