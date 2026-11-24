pragma ComponentBehavior: Bound

import QtQuick

import "../common/notify"
import "popup"
import "popup/MuxFlow.js" as Flow

// =============================================================================
// MuxKeepPrompt.qml -- "keep dGPU only?" after the restart into it, as ONE TOAST (CONTRACT section 11). No visual: the
// watcher holds one, once per shell. It replaces the keep panel the silicon popup used to open by itself (the user, 2026-11-15:
// "I'd rather have the confirmation to be in a toast").
//
//   [card] Keep dGPU only?
//          The screen is on the NVIDIA card now. If you do nothing, the laptop goes back to Hybrid and restarts once more.
//          Going back in 1:47                                            <- MuxKeepBody, the guard's clock
//          [ Go back now ] [ Keep ]                      the card's inset drains with the helper's own deadline
//
// A SHELL POST through the notification service (NotificationBus), `fixed` (no swipe, no click, never filed or removed by the
// user: the guard counts down whatever the user does, so the prompt may not be swiped into oblivion), sticky in the scheduler
// and DND-proof (`breakDnd`). The drain is the record's DEADLINE (`deadlineMs`, `deadlineTotalMs`: ToastEntry draws it from the
// instant, with no freeze for a hover and nothing filed or dropped when it reaches nothing): the revert is the helper's and
// the toast only shows it. After Keep the toast goes and nothing else is said (it goes when the FACTS say `kept`, so a Keep
// the helper refused leaves it standing); Go back now is the same three steps the popup's panel took (below).
//
// WHEN IT IS UP (`_sync`, one function reading the facts afresh from a 0 ms timer the facts' changes arm): the record is
// `awaiting-keep` (or the way back is on its way, or the guard's revert was seen happening) AND `ready` (the watcher's: the
// session is unlocked and the frame is on the glass, and the helper has answered) AND there is a service to post to. A lock that
// comes takes it away (a toast under the lock is nobody's) and the unlock brings it back.
//
// THE HELPER IS TOLD WHEN THE USER CAN SEE IT, not when it is posted: the toast is in the scheduler's stack
// (`toasts.shown`) and the lane is neither folded away beside a popup (`blocked`) nor waiting for a screen (`unplaced`). Then
// `vm.muxPromptShown()` shortens the guard's window to the prompt's own (`promptWindowS`, the helper's constant) -- once: a
// window already within the prompt's span has been shortened (this boot, an earlier showing or an earlier shell), and the
// helper's min() would change nothing. The figure and the drain wait until the shortened window has landed (or 3 s), so
// the prompt never shows the full boot window flashing down to the prompt's.
//
// THE DEADLINE IS THE GUARD'S: the instant is now plus MuxCountdown's remaining time (the data layer's rule: the record's uptime
// deadline minus the shell's own /proc/uptime), the span the drain runs over is that time when it first showed. A later
// instant stretches the span (a drain never refills), an earlier one lets it jump down.
//
// ONLY A CLICK KEEPS: `vm.muxKeep()` is called from `keep()`, the Keep button's action and nothing else (a dead man's switch
// that a default, a timer or a key could press would not be one).
//
// GO BACK NOW. The helper REFUSES a new request while a record awaits its keep (mux.rs request(): "a GPU mode change is
// waiting for your confirmation") and has no "revert now". So the way back is three steps the service already offers, each
// waited for on the FACTS: keep (the record leaves awaiting-keep), request hybrid (a queued record, no guard), restart now. The
// toast says "Going back to Hybrid" meanwhile (its buttons gone). A step that is refused or never answered gives the prompt
// back while the record still awaits its keep; once it has been kept, the prompt is over and `wayBackFailed` says so (the
// watcher tells the user: Hybrid did not come back, dGPU only stays on).
//
// THE REVERT, SEEN FROM HERE. When the record turns `reverted` while the shell watched it await its keep, the guard has put
// hybrid back and the laptop restarts at once: the toast says "Going back to Hybrid" until the outcome has been told (the
// watcher does that at a shell's START, or after its grace when no reboot came).
// =============================================================================
Item {
    id: root

    visible: false

    property var vm: null
    // The prompt may be shown: the session is unlocked, the shell's frame is on the glass, the helper has answered.
    property bool ready: false

    signal wayBackFailed(string why)

    // the toast's identity in the service
    readonly property string sourceId: "silicon"
    readonly property string key: "silicon-mux-keep"

    // ---- the facts ----
    readonly property var _mux: root.vm && root.vm.gpu ? root.vm.gpu.mux : null
    readonly property bool _awaiting: !!root._mux && root._mux.state === "awaiting-keep"
    readonly property string _state: root._mux ? String(root._mux.state) : ""
    // the prompt's window: the helper's constant, a fact (a root helper reads no config)
    readonly property real _windowMs: (root._mux ? root._mux.promptWindowS : 0) * 1000
    readonly property var _bus: NotificationBus.service

    // the guard's revert, seen happening while the record awaited its keep (not a record that was already reverted when
    // this shell started: nothing is restarting then) and not yet told
    property bool _sawAwaiting: false
    readonly property bool _reverted: root._sawAwaiting && !!root._mux && root._mux.state === "reverted" && root._mux.outcomeSeen === false

    // the way back while it is on its way: "" | "keep" | "request" | "restart"
    property string _back: ""
    // what the toast says: "ask" (waiting for the answer) | "back" (Hybrid is on its way)
    readonly property string phase: root._back !== "" || root._reverted ? "back" : "ask"

    // ---- what the body reads ----
    readonly property alias countdown: clk
    readonly property string countdownText: clk.text
    readonly property bool figureShown: root._glass && root.phase === "ask" && clk.known
                                        && (clk.remainingMs <= root._windowMs + 1500 || root._graceOver)
    // the toast is up (posted and in the service's stack)
    readonly property bool up: root._uid !== ""
    // what the two buttons may do right now
    readonly property bool canGoBack: root.up && root._back === "" && !root._reverted && root._awaiting
    readonly property bool canKeep: root.canGoBack && !root._keepAsked

    // ---- the toast ----
    property string _uid: ""
    property string _postedPhase: ""
    // the user can see it: in the stack, the lane neither folded nor waiting for a screen
    property bool _glass: false
    property bool _told: false
    property bool _graceOver: false
    property real _endMs: 0
    property real _totalMs: 0

    function _glyph() {
        return String.fromCodePoint(0xF08AE);       // md-expansion_card: the graphics card
    }

    Component {
        id: bodyComp
        MuxKeepBody {}
    }

    function _post() {
        const bus = root._bus;
        const copy = Flow.keepCopy(root.phase);
        const ask = root.phase === "ask";
        const spec = {
            source: root.sourceId, key: root.key, appName: "Silicon", icon: root._glyph(),
            title: copy.title, body: copy.body,
            urgency: "normal", timeoutMs: -1, fixed: true, breakDnd: true, sound: "none",
            actions: ask ? [{ id: "back", label: "Go back now" }, { id: "keep", label: "Keep" }] : [],
            onAction: id => root._answer(id)
        };
        if (ask) {
            spec.bodyComponent = bodyComp;
            spec.bodyProps = { prompt: root };
        }
        root._uid = bus.post(spec);
        root._postedPhase = root.phase;
        // the record is new: it carries no deadline until the next push (the span is kept: a drain never refills)
        root._endMs = 0;
    }

    function _retire() {
        const bus = root._bus;
        const uid = root._uid;
        root._uid = "";
        root._postedPhase = "";
        root._glass = false;
        root._told = false;
        root._graceOver = false;
        root._endMs = 0;
        // an episode that is over starts its next drain full; one only taken away (the lock) goes on from where it was
        if (!root._awaiting)
            root._totalMs = 0;
        grace.stop();
        if (bus && uid !== "")
            bus.withdraw(root.sourceId, root.key);
    }

    // the toast's action
    function _answer(id) {
        if (id === "keep")
            root.keep();
        else if (id === "back")
            root.goBack();
    }

    // Re-run the prompt for a host that never reboots (a mock, a mockup): it is due again, told again.
    function again() {
        root._retire();
        root._back = "";
        chainGuard.stop();
        root._sawAwaiting = root._awaiting;
        look.restart();
    }

    // ---- one function reads the facts and puts the toast where it belongs ----
    on_AwaitingChanged: {
        if (root._awaiting)
            root._sawAwaiting = true;
        look.restart();
    }
    on_StateChanged: {
        if (root._state !== "awaiting-keep" && root._state !== "reverted")
            root._sawAwaiting = false;
        look.restart();
    }
    on_RevertedChanged: look.restart()
    // The helper's shortened deadline lands as new facts of the same state: the drain follows them.
    on_MuxChanged: look.restart()
    onFigureShownChanged: look.restart()
    on_BackChanged: look.restart()
    on_BusChanged: look.restart()
    onReadyChanged: look.restart()
    onVmChanged: look.restart()
    Component.onCompleted: {
        if (root._awaiting)
            root._sawAwaiting = true;
        look.restart();
    }
    Component.onDestruction: root._retire()
    Timer {
        id: look
        interval: 0
        onTriggered: {
            root._advance();
            root._sync();
        }
    }
    // The toast's own stack: it left the lane (a full stack dropped it), or the lane folded away / came back.
    Connections {
        target: root._bus
        ignoreUnknownSignals: true
        function onRecordRemoved(uid: string) {
            if (uid === root._uid) {
                root._uid = "";
                root._glass = false;
                look.restart();
            }
        }
    }
    Connections {
        target: root._bus ? root._bus.toasts : null
        ignoreUnknownSignals: true
        function onSerialChanged() { look.restart(); }
        function onBlockedChanged() { look.restart(); }
        function onUnplacedChanged() { look.restart(); }
    }

    function _sync() {
        const bus = root._bus;
        const want = root.ready && !!bus && !!root._mux && (root._awaiting || root._back !== "" || root._reverted);
        if (!want) {
            if (root._uid !== "")
                root._retire();
            return;
        }
        // a record the service no longer has (dropped under us) is posted again
        if (root._uid !== "" && (!bus.store || !bus.store.get(root._uid)))
            root._uid = "";
        if (root._uid === "" || root._postedPhase !== root.phase)
            root._post();
        const t = bus.toasts;
        root._glass = !!t && t.shown.indexOf(root._uid) >= 0 && !t.blocked && !t.unplaced;
        if (root._glass && root.phase === "ask") {
            if (!root._graceOver && !grace.running)
                grace.start();
            clk.sample();
            root._tell();
            root._pushDeadline();
        }
    }

    // ---- the helper is told once the user can see it; the figure waits for the shortened window ----
    Timer {
        id: grace
        interval: 3000
        onTriggered: {
            root._graceOver = true;
            look.restart();
        }
    }
    function _tell() {
        if (!root._glass || !root._awaiting || root._told || !root.vm)
            return;
        root._told = true;
        // Already within the prompt's span: the window was shortened (by an earlier showing of this prompt, in
        // this boot or a shell before this one), and asking again would change nothing.
        if (clk.known && clk.remainingMs <= root._windowMs)
            return;
        root.vm.muxPromptShown();
    }

    // Ticking while the toast is on screen asking: never bound to `figureShown`, which reads this clock's own figure.
    MuxCountdown {
        id: clk
        mux: root._mux
        running: root._glass && root.phase === "ask"
    }

    // ---- the drain: the guard's instant, put on the record ----
    function _pushDeadline() {
        if (!root.figureShown || root._uid === "")
            return;
        const rem = clk.remainingMs;
        const end = Math.round(Date.now() + rem);
        if (root._endMs > 0 && Math.abs(end - root._endMs) < 1500)
            return;
        // a later instant stretches the span (a drain never refills); the first one sets it
        if (root._totalMs <= 0)
            root._totalMs = Math.max(1, rem);
        else if (root._endMs > 0 && end > root._endMs)
            root._totalMs += end - root._endMs;
        else
            root._totalMs = Math.max(root._totalMs, rem);
        root._endMs = end;
        root._bus.update(root._uid, { deadlineMs: end, deadlineTotalMs: root._totalMs });
    }

    // ---- Keep: one click, once ----
    property bool _keepAsked: false
    Timer {
        id: keepGuard
        interval: 4000
        onTriggered: root._keepAsked = false
    }
    function keep() {
        if (!root.vm || !root.canKeep)
            return;
        root._keepAsked = true;
        keepGuard.restart();
        root.vm.muxKeep();
    }

    // ---- Go back now: keep -> request hybrid -> restart, each step waited for on the facts ----
    function goBack() {
        if (!root.vm || !root.canGoBack)
            return;
        root._back = "keep";
        chainGuard.restart();
        if (!root.vm.muxKeep())
            root._abort("");
    }
    function _abort(why: string) {
        chainGuard.stop();
        const wasKept = root._back !== "" && !root._awaiting;
        root._back = "";
        // the record left its keep: the prompt is over, and Hybrid did not come back
        if (wasKept && root._state !== "reverted")
            root.wayBackFailed(why);
    }
    function _advance() {
        if (root._back === "" || !root.vm)
            return;
        const m = root.vm.gpu.mux;
        if (root._back === "keep" && m.state === "kept") {
            root._back = "request";
            if (!root.vm.muxRequest("hybrid"))
                root._abort("");
        } else if (root._back === "request" && m.state === "queued" && m.want === "hybrid") {
            root._back = "restart";
            if (!root.vm.muxRebootNow())
                root._abort("");
        } else if (root._back === "restart" && m.state !== "queued") {
            // the restart took (a mock restarts at once), or the record moved on
            chainGuard.stop();
            root._back = "";
        }
    }
    // A step that is refused or never answered gives the prompt back.
    Timer {
        id: chainGuard
        interval: 20000
        onTriggered: root._abort("")
    }
    Connections {
        target: root.vm
        ignoreUnknownSignals: true
        function onWriteRefused(zone: string, why: string) {
            if (root._back !== "")
                root._abort(why);
        }
    }
}
