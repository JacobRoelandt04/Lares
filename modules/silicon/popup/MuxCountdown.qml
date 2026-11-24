pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

import "../data/SiliconModel.js" as Model
import "MuxFlow.js" as Flow

// =============================================================================
// MuxCountdown.qml -- the keep prompt's clock: how long until the boot guard puts hybrid back.
//
//   mux       the facts (`vm.gpu.mux`)
//   running   true while somebody is looking: nothing is armed, read or sampled otherwise
//   remainingMs  number | null (null: no deadline known); text "1:47" ("" when unknown)
//
// THE RULE is HELPER_PROTOCOL.md's, and the data layer's (SiliconModel.muxRemainingMs): deadlineUptimeMs
// minus the shell's OWN /proc/uptime (the guard's clock; a wall clock steps at boot when NTP corrects it,
// which is when this is up), the wall deadline only as the fallback. The uptime is read here, by a FileView
// with a static path, once per sample, `reload()` then `text()` under `blockAllReads` (a reload without it
// hands back the PREVIOUS read).
//
// TICKING. Not a repeating Timer: a 1 s interval started at an arbitrary phase changes the figure OFF THE
// BEAT, and the animation clock a Timer runs on can lead the wall by a few percent. Every sample reads the
// clock, shows the second it finds and arms ONE single-shot Timer for the next whole-second boundary; a
// wake that comes early finds the same second, and arms for what is left. So the figure changes when the
// remaining time crosses a whole second, whatever drove the sample (a tick, new facts, `running`).
// =============================================================================
Item {
    id: root

    property var mux: null
    property bool running: false
    // () => ms since boot; null reads /proc/uptime. A probe hands in a clock it moves.
    property var uptimeProvider: null

    readonly property var remainingMs: root._rem
    readonly property bool known: root._rem !== null
    readonly property bool expired: root._rem !== null && root._rem <= 0
    readonly property string text: root._rem === null ? "" : Flow.clock(root._rem)

    visible: false

    property var _rem: null

    // Static path: a FileView is never repointed (the second path would answer with the first's bytes).
    FileView {
        id: proc
        path: "/proc/uptime"
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }

    function _uptimeMs() {
        if (root.uptimeProvider)
            return root.uptimeProvider();
        proc.reload();
        const v = parseFloat(String(proc.text()).split(/\s+/)[0]);
        return isFinite(v) ? Math.round(v * 1000) : null;
    }

    // Read the clock, show what it says, arm for the next boundary. Idempotent: any driver may call it.
    function sample() {
        tick.stop();
        const ms = Model.muxRemainingMs(root.mux, Date.now(), root._uptimeMs());
        root._rem = ms;
        if (!root.running)
            return;
        const next = Flow.untilNext(ms);
        if (next > 0) {
            tick.interval = next;
            tick.start();
        }
    }

    onMuxChanged: root.sample()
    onRunningChanged: root.sample()
    // a clock built running, over facts that are already there, has no change to hear
    Component.onCompleted: root.sample()

    Timer {
        id: tick
        repeat: false
        onTriggered: root.sample()
    }
}
