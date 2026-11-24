pragma ComponentBehavior: Bound

import QtQuick

import "../../common/notify"

// =============================================================================
// PanoramaKeepPrompt.qml -- "Keep these display settings?" after Apply, as ONE TOAST (decisions 7 and 18). No visual: the service
// holds one. It is the silicon MUX keep prompt's pattern (modules/silicon/MuxKeepPrompt.qml) without its chain:
//
//   [card] Keep these display settings?
//          Reverting in 12 s                                <- PanoramaKeepBody
//          [ Revert ] [ Keep ]                    the card's inset drains with the deadline
//
// A SHELL POST through the notification service: `fixed` (no swipe, no click on the body: only the buttons answer), sticky
// (`timeoutMs: -1`), DND-proof (`breakDnd`: a screen that went dark must still be answerable), no sound.
//
// THE COUNTDOWN STARTS ON THE GLASS. The toast is in the scheduler's stack (`toasts.shown`) and the lane is neither folded beside a
// popup (`blocked`) nor waiting for a screen (`unplaced`): then `service.markShown()` sets the deadline (keepSeconds from now) and
// tells the engine, whose own guard follows. Before that the change simply holds: the engine's 45 s cap covers a toast that never
// shows (decision 32 closes the popup on Apply so the lane is free).
//
// ONLY A CLICK KEEPS: `service.keep()` is called from the Keep button's action and nothing else; Revert, Escape (the host routes it
// while `waiting`) and the timeout revert.
// =============================================================================
Item {
    id: root

    visible: false

    property var service: null
    property bool ready: true

    readonly property string sourceId: "panorama"
    readonly property string key: "panorama-keep"

    // the toast is up and asking (the host routes Escape to revert() while this is true)
    readonly property bool waiting: root._uid !== ""
    // whole seconds left, or -1 before the countdown runs
    readonly property int secondsLeft: root._secondsLeft

    readonly property var _bus: NotificationBus.service
    readonly property bool _want: root.ready && !!root.service && root.service.phase === "awaiting"

    property string _uid: ""
    property int _secondsLeft: -1

    Component {
        id: bodyComp
        PanoramaKeepBody {}
    }

    function revert(): void {
        if (root.service && root.service.phase === "awaiting")
            root.service.revert();
    }

    function _post(): void {
        const bus = root._bus;
        root._uid = bus.post({
            source: root.sourceId, key: root.key, appName: "Panorama", icon: String.fromCodePoint(0xF0379),
            title: "Keep these display settings?", body: "",
            urgency: "normal", timeoutMs: -1, fixed: true, breakDnd: true, sound: "none",
            actions: [{ id: "revert", label: "Revert" }, { id: "keep", label: "Keep" }],
            onAction: id => root._answer(id),
            bodyComponent: bodyComp, bodyProps: { prompt: root }
        });
    }

    function _answer(id: string): void {
        if (!root.service)
            return;
        if (id === "keep")
            root.service.keep();
        else if (id === "revert")
            root.service.revert();
    }

    function _retire(): void {
        const uid = root._uid;
        root._uid = "";
        root._secondsLeft = -1;
        tick.stop();
        if (root._bus && uid !== "")
            root._bus.withdraw(root.sourceId, root.key);
    }

    function _sync(): void {
        const bus = root._bus;
        if (!root._want || !bus) {
            if (root._uid !== "")
                root._retire();
            return;
        }
        if (root._uid !== "" && (!bus.store || !bus.store.get(root._uid)))
            root._uid = "";
        if (root._uid === "")
            root._post();
        const t = bus.toasts;
        const glass = !!t && t.shown.indexOf(root._uid) >= 0 && !t.blocked && !t.unplaced;
        if (glass && root.service.trial.deadlineMs <= 0) {
            root.service.markShown();
            const tr = root.service.trial;
            bus.update(root._uid, { deadlineMs: tr.deadlineMs, deadlineTotalMs: tr.totalMs });
            root._tick();
            tick.start();
        }
    }

    function _tick(): void {
        const tr = root.service ? root.service.trial : null;
        root._secondsLeft = tr && tr.deadlineMs > 0 ? Math.max(0, Math.ceil((tr.deadlineMs - Date.now()) / 1000)) : -1;
    }

    // A display clock arms one tick for the next whole second (the law: never a repeat at another interval than the unit shown).
    Timer {
        id: tick
        interval: 1000
        repeat: false
        onTriggered: {
            root._tick();
            const tr = root.service ? root.service.trial : null;
            if (root._uid !== "" && tr && tr.deadlineMs > 0) {
                const left = tr.deadlineMs - Date.now();
                tick.interval = Math.max(20, ((left % 1000) + 1000) % 1000 || 1000);
                tick.start();
            }
        }
    }

    on_WantChanged: look.restart()
    on_BusChanged: look.restart()
    Component.onDestruction: root._retire()
    Timer {
        id: look
        interval: 0
        onTriggered: root._sync()
    }
    Connections {
        target: root._bus
        ignoreUnknownSignals: true
        function onRecordRemoved(uid: string) {
            if (uid === root._uid) {
                root._uid = "";
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
}
