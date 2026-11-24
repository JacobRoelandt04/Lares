pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// OledShift.qml -- the OLED care: the bar's CONTENT moves one device pixel now and then.
//
// Burn-in care by pixel shift, nothing else (no screen shader). Every `intervalMs` (240 s) the three zone rows -- every icon and text inside the islands --
// step to the next of NINE places of a 3 x 3 square of whole DEVICE pixels (ORBIT: the centre, then once round the ring; each step is
// at most one pixel on each axis, and all nine are visited). The islands' FREE ends (the ends not on a screen corner) step along the
// edge with the x, so the room between an end and its module stays as designed (ShellLayout.bars, THE OLED SHIFT), and an island's input
// rect with its end; the islands' thickness, the ends on the corners, the slim bars, the continuous bar and the reserve (so the windows'
// gaps) never move. Only ShellFrame reads `dx` / `dy`, in device px, and converts them with the frame's renderScale (`oledX` / `oledY`:
// the ZoneRows and the islands' records), so a step is a whole device pixel at any scale.
//
// A STEP WAITS while anything that was placed from the module positions is out. A popup, the reel's strip and its reason label read
// their module's place at the moment they open, and a step under them would leave them a pixel behind; so each ShellFrame reports
// `setHeld(key, true)` while it has something out (a popup in any phase but closed, the strip, a flourish, the theme crossfade) and
// the step is taken the moment the last holder lets go. `pending` says a step (or a switch) is waiting.
//
//   on            THE ONE SWITCH, shell.jsonc's `oled.enabled` (read hot; ShellServices binds it): false puts the content back at (0,0)
//                 and stops the timer; the step is kept
//   shift()       `lares oled shift`: one step now (the same wait applies, and the answer says so)
//   persistence   <statePath> = {"step": 3}, read before the first frame (so a restart does not jump back to the centre) and written
//                 at every step (a file from before the switch moved to the config may still hold an "on": it is ignored)
//
// `dx` / `dy` are the place that is DRAWN (lagging the target only while a step waits).
// =============================================================================
Item {
    id: root

    // Where the state is kept; "" = in memory only.
    property string statePath: ""
    property int intervalMs: 240000

    // THE SWITCH (shell.jsonc `oled.enabled` and `oled.shift`; the random flourishes follow `oled.enabled` alone, ShellFrame's FlourishScheduler).
    property bool on: true

    // The orbit, device px (x right, y down): the centre, then the ring once round, each step one pixel on each axis at most.
    readonly property var orbit: [[0, 0], [1, 0], [1, 1], [0, 1], [-1, 1], [-1, 0], [-1, -1], [0, -1], [1, -1]]

    // The place that is drawn, in device px, and the step it is.
    readonly property int dx: root._shownOn ? root.orbit[root._shownStep][0] : 0
    readonly property int dy: root._shownOn ? root.orbit[root._shownStep][1] : 0
    readonly property int shownStep: root._shownStep
    readonly property int step: root._step
    // A step or a switch is waiting for the holders to let go.
    readonly property bool pending: root._isPending()
    // Something is out that was placed from the modules' positions.
    readonly property bool busy: root._heldCount > 0
    // How many steps were taken (shown) and how many were asked (a probe reads them).
    property int taken: 0
    property int asked: 0

    property int _step: 0
    property bool _shownOn: false
    property int _shownStep: 0
    property var _held: ({})
    property int _heldCount: 0
    property real _nextAt: 0

    // ---- the holders ----
    // A key for one frame's hold: the screen's name and a number of its own.
    property int _keys: 0
    function holderKey(name: string): string {
        root._keys++;
        return (name || "screen") + "#" + root._keys;
    }
    function setHeld(key: string, held: bool): void {
        const was = root._held[key] === true;
        if (was === held)
            return;
        const h = Object.assign({}, root._held);
        if (held)
            h[key] = true;
        else
            delete h[key];
        root._held = h;
        root._heldCount = Object.keys(h).length;
        if (!held)
            root._arrive();
    }

    // `pending` computed from the facts: a handler of `on` runs before the binding on `pending` has followed it (a stale answer would
    // leave the content off its place with nothing holding it).
    function _isPending(): bool {
        return root._shownOn !== root.on || (root.on && root._shownStep !== root._step);
    }
    // Take the target if nothing holds it.
    function _arrive(): void {
        if (root._heldCount > 0 || !root._isPending())
            return;
        const stepped = root._shownStep !== root._step && root.on;
        root._shownOn = root.on;
        root._shownStep = root._step;
        if (stepped)
            root.taken++;
    }

    // ---- the asks ----
    // One step now. Answers what happened.
    function shift(): string {
        if (!root.on)
            return "off: nothing moves (\"oled\": { \"enabled\": false } in shell.jsonc)";
        if (root._isPending())
            return "waiting: " + root._why() + " (the step already asked is taken when it closes)";
        root._step = (root._step + 1) % root.orbit.length;
        root.asked++;
        root._save();
        root._arrive();
        root._restartTimer();
        return root._isPending() ? "waiting: " + root._why() + " (step " + root._step + " is taken when it closes)" : "stepped to " + root._place();
    }
    // The switch moved (the config was read again): the content goes back to the centre (or on from the step it had) the moment nothing
    // holds it, and the timer follows.
    onOnChanged: {
        root._arrive();
        root._restartTimer();
    }
    function _place(): string {
        return "(" + root.orbit[root._shownStep][0] + "," + root.orbit[root._shownStep][1] + ") step " + root._shownStep;
    }
    function _why(): string {
        const k = Object.keys(root._held);
        return k.length > 0 ? k.map(x => x.split("#")[0]).join(", ") + " has something out" : "something is out";
    }
    // One line of JSON for `lares oled status`.
    function status(): string {
        const t = root.on ? root.orbit[root._step] : [0, 0];
        return JSON.stringify({
            on: root.on,
            step: root._step,
            x: root.dx,
            y: root.dy,
            target: { x: t[0], y: t[1] },
            pending: root.pending,
            held: Object.keys(root._held),
            intervalS: Math.round(root.intervalMs / 1000),
            nextInS: root.on && root._nextAt > 0 ? Math.max(0, Math.round((root._nextAt - Date.now()) / 1000)) : null,
            taken: root.taken
        });
    }

    // ---- the timer ----
    function _restartTimer(): void {
        root._nextAt = Date.now() + root.intervalMs;
        tick.restart();
    }
    Timer {
        id: tick
        interval: root.intervalMs
        running: root.on
        repeat: true
        onTriggered: {
            root._nextAt = Date.now() + root.intervalMs;
            root.shift();
        }
    }

    // ---- the state file ----
    function _save(): void {
        if (root.statePath !== "")
            stateFile.setText(JSON.stringify({ step: root._step }) + "\n");
    }
    function _read(text: string): void {
        let step = 0;
        try {
            const o = JSON.parse(text);
            if (o && Number.isInteger(o.step) && o.step >= 0 && o.step < root.orbit.length)
                step = o.step;
        } catch (e) {
        }
        root._step = step;
    }
    FileView {
        id: stateFile
        path: root.statePath
        blockLoading: true
        atomicWrites: true
        printErrors: false
    }

    Component.onCompleted: {
        if (root.statePath !== "") {
            const dir = root.statePath.substring(0, root.statePath.lastIndexOf("/"));
            if (dir !== "")
                Quickshell.execDetached(["mkdir", "-p", dir]);
        }
        // read before the first frame (blockLoading: the text is there now)
        root._read(root.statePath !== "" ? stateFile.text() : "");
        // what is drawn from the first frame is the saved place
        root._shownOn = root.on;
        root._shownStep = root._step;
        if (root.on)
            root._restartTimer();
    }
}
