pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// DdcBrightnessSource.qml -- an external display's own brightness, stepped over DDC/CI by the shell's
// brightness keys. The sibling of BacklightSource: the same request, the same card.
//
//   adjust(target, dir, fine, phase)   a key step on `target` ({ connector, label }: the display the pointer was on at the
//                                      gesture's press, resolved by the service; kept for the repeats and the release)
//   setValue(frac)                     a drag on the card's slider while it names a DDC display (written at rest, DdcClient.scrub)
//   signal request(var req)            one request per step, BacklightSource's shape (kind "brightness", value 0..1, max 1,
//                                      device { type "display", name <the display's label> }) PLUS
//                                        pending      the figure is the GOAL and the display has not confirmed it yet
//                                        ddcState     "unknown" | "probing" | "ok" | "unsupported" | "failing"
//                                        unavailable  the display takes no brightness (unsupported / failing): nothing moves, the note says why
//                                        note         the words under the display's name ("" none)
//
// NOTHING WAITS, NOTHING IS DROPPED, THE LAPTOP IS NEVER STEPPED FOR AN EXTERNAL. A key adds its step to the display's ONE goal in the
// backend (`ddcAdjust`: the client keeps a step even while the value is not known yet and sends only the newest goal) and the card is
// shown AT ONCE at the goal, `pending`. When the write is done the backend says so (`ddcChanged`) and the card is asked for again
// without `pending` (its time starts again from there); while it waits the card is asked for every second so it stays up. A display
// that cannot take the request (no DDC, a failure remembered) gets a card that says so under its name.
//
// THE STEP. The figure is the display's own scale (0..max, the real maximum DdcClient read), not the panel's gamma ladder: a key
// moves `stepFrac` of max (OsdConfig brightness.step, 5 %) and Shift `fineStep` (1 %), at least one unit.
//
// The backend (the Panorama service or its mock) offers: ddcAdjust(n, delta): bool, ddcValue(n), ddcGoal(n), ddcMax(n), ddcPending(n),
// ddcState(n), ddcReason(n), ddcScrub(n, v), ddcCommit(n) and signal ddcChanged(name); optional ddcEnsure().
// =============================================================================
Item {
    id: root

    property var backend: null
    property real stepFrac: 0.05
    property real fineStepFrac: 0.01
    // while pending, the card is asked for again at this period (it stays up)
    property int pendingRefreshMs: 1000
    // a change of the shown display is answered with a card only this long after the last ask of ours
    property int answerWindowMs: 15000

    signal request(var req)

    // the display the card is showing (a drag on its slider sets this one), "" when none
    property string shownName: ""

    property string _label: ""
    property real _lastAt: 0
    property string _lastSig: ""

    function adjust(target, dir, fine, phase) {
        if (phase === "release")
            return true;
        if (root.backend === null || !target)
            return false;
        const n = target.connector;
        if (typeof root.backend.ddcEnsure === "function")
            root.backend.ddcEnsure();
        const max = Math.max(1, root.backend.ddcMax(n));
        const delta = dir * Math.max(1, Math.round((fine ? root.fineStepFrac : root.stepFrac) * max));
        root.backend.ddcAdjust(n, delta);
        root.shownName = n;
        root._label = target.label;
        root._emit("key");
        return true;
    }

    function setValue(frac) {
        const n = root.shownName;
        if (root.backend === null || n === "")
            return;
        const m = Math.max(1, root.backend.ddcMax(n));
        root.backend.ddcScrub(n, Math.round(Math.max(0, Math.min(1, frac)) * m));
        root._lastAt = Date.now();
    }

    // the card as the backend's facts say it is now
    function _emit(source) {
        const n = root.shownName;
        const b = root.backend;
        const max = Math.max(1, b.ddcMax(n));
        const st = b.ddcState(n);
        const unavailable = st === "unsupported" || st === "failing";
        const g = b.ddcGoal(n);
        const known = g >= 0;
        const pending = !unavailable && b.ddcPending(n);
        let note = "";
        if (unavailable)
            note = String(b.ddcReason(n) || (st === "unsupported" ? "No brightness control" : "Not answering"));
        else if (!known)
            note = "Looking for the display";
        root._lastAt = Date.now();
        root._lastSig = root._sig(n);
        refresh.running = pending;
        root.request({
            kind: "brightness",
            key: "brightness",
            source: source,
            value: known ? Math.max(0, Math.min(max, g)) / max : 0,
            max: 1,
            muted: false,
            boost: false,
            device: { type: "display", name: root._label },
            pending: pending,
            ddcState: st,
            unavailable: unavailable,
            note: note
        });
    }

    function _sig(n) {
        const b = root.backend;
        return b.ddcState(n) + "|" + (b.ddcPending(n) ? "p" : "-") + "|" + (b.ddcGoal(n) >= 0 ? "k" : "u");
    }

    Timer {
        id: refresh
        interval: root.pendingRefreshMs
        repeat: true
        onTriggered: {
            if (root.shownName === "" || root.backend === null || !root.backend.ddcPending(root.shownName)) {
                refresh.running = false;
                return;
            }
            root._emit("ddc");
        }
    }

    Connections {
        target: root.backend
        ignoreUnknownSignals: true
        function onDdcChanged(name) {
            if (name !== root.shownName || name === "" || Date.now() - root._lastAt > root.answerWindowMs)
                return;
            if (root._sig(name) !== root._lastSig)
                root._emit("ddc");
        }
    }
}
