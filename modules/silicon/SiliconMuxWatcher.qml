pragma ComponentBehavior: Bound

import QtQuick

import "../common/components"
import "popup/MuxFlow.js" as Flow

// =============================================================================
// SiliconMuxWatcher.qml -- the MUX's moments that come without the popup (CONTRACT
// section 11). The owner holds one; it has no visual.
//
//   THE PROMPT IS DUE. A dGPU-only request restarts the machine and the boot guard gives the user a
//   couple of minutes to keep it. At login with the record `awaiting-keep` the prompt is ONE TOAST
//   (MuxKeepPrompt, which this holds: Keep, Go back now, and the guard's own deadline as the card's drain); no popup
//   opens for it (the user, 2026-11-15: "I'd rather have the confirmation to be in a toast"). The watcher only
//   says WHEN it may be shown (`ready`, below); what the toast does -- told to the helper when it is on the glass, the
//   deadline, the way back -- is the prompt's.
//
//   NOT BEFORE THE USER CAN SEE IT. The dGPU session starts under the boot lock (SDDM `--locked-cmd`), which holds the
//   screen until the user types the password, and a toast under the lock is not one the user was shown. So the prompt
//   waits until the session is UNLOCKED (`locked`, the lock's own word, which stays true through its retraction) and the
//   shell is ON THE GLASS (`shown`: the frame has been presented) and the helper has answered (`vm.helper.ok`: the record
//   is a fact, not the seed); while any is not so nothing is posted and the helper is told nothing, and the change of that
//   fact brings it. The guard's window runs meanwhile (a keep prompt is due for 5 minutes after the boot, 2 once shown); if
//   it runs out locked, the guard reverts as designed and the outcome's notification (below) says so. A lock that comes
//   while the toast is up takes it away and the unlock gives it back.
//
//   (2026-11-15, the user's two dGPU-only boots, frame journal + helper log: the helper was told "prompt shown" 26 s after the
//   unlock on the first (the GUI thread stood still for 25.3 s from 0.4 s after the unlock -- the start-up prewarm on a cold
//   NVIDIA shader cache, 6 s after the first frame -- and the popup this used to open was closing 230 ms after it drew) and
//   0.8 s after the unlock on the second (it opened and was kept 5 s later). The gate opened at the unlock both times; what
//   failed the first was the popup, which a freeze and any input can close. A fixed toast cannot be swiped away.)
//
//   THE GUARD PUT HYBRID BACK. The record is `reverted` ("dGPU only was not kept, so the laptop went back to
//   Hybrid") or `failed` (a request that did not go through, with the helper's words), and the user has not
//   been told (`outcomeSeen` false): ONE NOTIFICATION (key `silicon-mux`, stored in the manager: the words are long, the
//   helper's reasons longer, and an OSD card cut them off) and then `vm.markMuxOutcomeSeen()`, which the data layer
//   persists, so a later shell says nothing. A kept or cancelled switch is the user's own answer: no notice, only the
//   mark, so the fact stays true. What the words say is MuxFlow.outcome's: a `failed` record whose wiring is in effect
//   is told as what it is (the switch is on), not as a failure. A way back from the prompt that did not go through
//   (`prompt.wayBackFailed`) is told by the same key (MuxFlow.wayBackFailed).
//
//   TOLD AT STARTUP, OR ONCE THE SHELL HAS OUTLIVED THE REBOOT. On the real machine the guard writes `reverted`
//   and REBOOTS at once: a notice posted and marked seen in that last moment is lost with the shell, and the
//   shell after the reboot -- which would have told it -- finds it seen and stays silent. So an unseen outcome
//   is told at once only when it is already there at the watcher's first look at facts that are really there
//   (the helper has answered: `vm.helper.ok`; the seed's empty record is not a look), the shell's start. A
//   record that turns reverted or failed while this shell watches is told by nobody for `outcomeGraceMs` (30 s;
//   the keep prompt says it is going back meanwhile); a real reboot kills the shell first and the next one tells
//   it, and a revert that was not followed by one (the reboot was not started, or hybrid could not be written
//   back and the machine stays up) is told ONCE when the grace has passed, if it is still unseen. `lookAgain()`
//   re-runs the startup look, inside the grace or after it: a mock or a mockup never reboots, and its "restart
//   the shell" button calls it; what it tells the grace then tells nothing of.
//
// All of it is decided by one function reading the facts afresh (`_look`), called from a 0 ms Timer that the
// facts' changes (and the start) arm: a change handler runs before the bindings that depend on the same
// property, and an intent made inside the rebuild of the facts loops through it.
// =============================================================================
Item {
    id: root

    property var vm: null
    // The session is held by the lock (the shell's LockOwner.locked), and the shell is on screen (a frame presented).
    // The defaults are a mockup's / a bare owner's: no lock, shown.
    property bool locked: false
    property bool shown: true

    // an outcome that turns up while this shell watches is told only if the shell is still alive this long after
    property int outcomeGraceMs: 30000

    // the keep prompt's toast (a probe and the mockup read it)
    readonly property alias prompt: keepPrompt

    visible: false

    // ---- the facts ----
    function _mux() {
        return root.vm && root.vm.gpu ? root.vm.gpu.mux : null;
    }
    readonly property string _state: {
        const m = root._mux();
        return m ? String(m.state) : "";
    }
    readonly property bool _unseen: {
        const m = root._mux();
        return !!m && m.outcomeSeen === false;
    }
    // The helper has answered: the record (or its absence) is a fact now, not the seed.
    readonly property bool _known: !!root.vm && !!root.vm.helper && root.vm.helper.ok === true
    // The prompt may be put in front of the user: not under the boot lock, not before the frame is on the glass, and the
    // facts are real.
    readonly property bool _ready: !root.locked && root.shown

    // ---- the keep prompt: one toast, the prompt's own flow ----
    MuxKeepPrompt {
        id: keepPrompt
        vm: root.vm
        ready: root._ready && root._known
        onWayBackFailed: why => root._announceWayBack(why)
    }

    // Looked at from a 0 ms Timer, never from the handler of the change: what `_look` does (an intent, a notice)
    // is not to be done inside the rebuild of the facts it reads -- done there, the mock's own rebuild answers
    // "Binding loop detected for property gpu" and keeps the OLD facts. The same timer is the first look: the
    // service and the OSD service are all built by the time it fires, which onCompleted cannot say.
    on_StateChanged: look.restart()
    on_UnseenChanged: look.restart()
    on_KnownChanged: look.restart()
    Timer {
        id: look
        interval: 0
        running: true
        onTriggered: root._look()
    }

    // the startup look has been made (the first look at facts that are really there)
    property bool _started: false

    // Re-run the startup look: the prompt is due again, an unseen outcome is told. For a mock or a mockup, which
    // never reboot (a real shell's start does this by being a start).
    function lookAgain() {
        root._started = false;
        keepPrompt.again();
        look.restart();
    }

    function _look() {
        const m = root._mux();
        if (!m || !root.vm || !root._known)
            return;
        const start = !root._started;
        root._started = true;
        const st = String(m.state);

        if (st === "reverted" || st === "failed") {
            if (m.outcomeSeen === false) {
                if (start)
                    root._announce(m);               // already there at the shell's start
                else if (!graceTimer.running)
                    graceTimer.restart();            // seen happening: the machine is about to reboot
            }
        } else {
            graceTimer.stop();
            if ((st === "kept" || st === "cancelled") && m.outcomeSeen === false)
                root.vm.markMuxOutcomeSeen();
        }
    }

    // The grace of an outcome seen happening (above): still here, still unseen -> told now.
    Timer {
        id: graceTimer
        interval: root.outcomeGraceMs
        onTriggered: root._graceDue()
    }
    function _graceDue() {
        const m = root._mux();
        if (m && (m.state === "reverted" || m.state === "failed") && m.outcomeSeen === false)
            root._announce(m);
    }

    // ---- the guard's last word, once ----
    DesktopNotifier {
        id: notifier
        appName: "Silicon"
        keys: ["silicon-mux"]
    }
    function _announce(m) {
        graceTimer.stop();
        const o = Flow.outcome(m);
        if (!o)
            return;
        notifier.notify("silicon-mux", { title: o.title, body: o.body });
        root.vm.markMuxOutcomeSeen();
    }
    // The prompt's way back did not go through (its keep step took, so the guard no longer counts).
    function _announceWayBack(why) {
        const n = Flow.wayBackFailed(root._mux(), why);
        notifier.notify("silicon-mux", { title: n.title, body: n.body });
    }
}
