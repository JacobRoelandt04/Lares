pragma ComponentBehavior: Bound

import QtQuick

import "PanoramaModel.js" as Model
import "PanoramaStaging.js" as Staging

// =============================================================================
// CastKeeper.qml -- the glue between a cast (CastService / CastMock), the displays and the engine (docs/contracts/panorama.md section 10).
// ONE per PanoramaService and one per PanoramaMock (the same rules, so the mock cannot differ). It owns the ORDER of a cast and nothing else:
//
//   start(deviceId)   EXTENDED: openOutput(identity) -> the engine makes LARES-CAST-<n> -> the output is LISTED and the resolved setup has
//                     LANDED (liveDiff of the plan against the output says "") -> cast.start(device, output, quality)
//                     MIRRORED (the TV's stored setup says so: `mirrorWanted`): NO OUTPUT AT ALL -> cast.start(device, the internal one,
//                     quality). `virtual` is true and the host shows the TV as a display that mirrors (a stand-in record).
//                     A MIRRORING OR DISABLED OUTPUT CANNOT BE REMOVED AND ONE DISABLED AS IT IS BORN KILLS THE CLIENTS BINDING IT (the
//                     2026-11-23 session: hyprpaper, the browser, the terminals and the shell died at 13:38:38), so a cast output only
//                     ever exists on and extended.
//   the stream ends   (any reason: stopped / failed / peer-gone) -> closeOutput(name) ONCE and keepNames([]) -> idle; a failure leaves a
//                     `notice` for 6 s (the chip says why), then the cast service's failure is cleared
//   stop()            cast.stop(); before the stream is up it closes the output at once
//   restart()         ONE stop and ONE start (quality changed, the mirror moved); the stop keeps the Wi-Fi hold. Between the two the cast
//                     takes the shape now wanted: to a mirror the output is closed, from a mirror it is opened and waited for
//   scanIfDue()       cast.scan() at most once per `scanEveryMs`, never while a cast or a scan runs
//
// There is no keep trial: a cast display is the user's click, and stopping it is the revert. The engine sweeps a LARES-CAST output no
// live cast keeps (keepNames), so a crash anywhere in here leaves nothing behind.
//
// INPUTS the host sets: `cast`, `armed` (the config's "cast" AND the engine active AND a cast service), `popupOpen`, `outputs` (the present
// outputs, `castId` filled), `castMap` (output name -> cast identity, the engine's table), `plan` (resolve's answer).
// OUTPUTS the host connects: openOutput(identity), closeOutput(name), keepNames(names).
// =============================================================================
Item {
    id: root
    visible: false

    property var cast: null
    property bool armed: false
    // the quality of a TV not set up yet (panorama.jsonc castQuality)
    property var defaultQuality: Staging.CAST_QUALITY
    property bool popupOpen: false
    property var outputs: []
    property var castMap: ({})
    property var plan: null
    property int scanEveryMs: 30000
    property int openWaitMs: 12000
    property int noticeMs: 6000
    // function(identity): bool -- the TV's stored setup says it mirrors the laptop (the host asks its store; null: never)
    property var mirrorWanted: null

    signal openOutput(string identity)
    signal closeOutput(string name)
    signal keepNames(var names)

    // idle | opening | starting | streaming | stopping | restarting
    readonly property string phase: root._phase
    readonly property string device: root._device
    readonly property string identity: root._ident
    readonly property string outputName: root._name
    readonly property bool active: root._phase !== "idle"
    // a cast is being made or made again (a lost link, a restart), from the click until the stream is up, has failed or was stopped; also one that
    // something else started on the cast service (the bar's glyph says so: PanoramaBarButton.working)
    readonly property bool working: root._phase === "opening" || root._phase === "starting" || root._phase === "restarting"
                                    || (root.cast !== null && (root.cast.state === "connecting" || root.cast.state === "negotiating"))
    // { device, text } for `noticeMs` after a cast that did not hold; null otherwise
    readonly property var notice: root._notice
    readonly property bool mirrored: root.active && root._virtual
    // the cast has no output of its own (it mirrors): the host stands a display record in for the TV
    readonly property bool virtual: root._phase !== "idle" && root._virtual

    // the words a chip shows while this device is the one being cast (instant swaps; "" when it is not the device or nothing is going on)
    function statusText(deviceId: string): string {
        if (root._phase === "idle" || root._device !== deviceId)
            return "";
        const st = root.cast ? root.cast.state : "idle";
        if (root._phase === "opening")
            return root._held ? "Waiting for the scan…" : "Preparing…";
        if (root._phase === "stopping" || st === "stopping")
            return "Stopping…";
        if (root._phase === "restarting")
            return "Restarting…";
        // the tool lost the link of a stream that was up and makes it again
        if (root._phase === "streaming" && (st === "connecting" || st === "negotiating"))
            return "Reconnecting…";
        if (st === "negotiating")
            return "Negotiating…";
        if (st === "streaming")
            return "Casting";
        if (st === "connecting")
            return root.cast.retried ? "Retrying…" : "Connecting…";
        return "Connecting…";
    }

    function noticeFor(deviceId: string): string {
        return root._notice !== null && root._notice.device === deviceId ? root._notice.text : "";
    }

    // ---- the calls -----------------------------------------------------------------------------------------------------------------------
    // A CLICK IS NEVER DROPPED IN SILENCE: a refusal leaves its reason as the device's notice (the chip shows it), and the popup's own
    // scan is no refusal at all -- the cast is prepared and starts when the scan has ended (it ran 9-12 s with the chips on show, and
    // a Cast click in that span did nothing: "I had to press twice").
    function start(deviceId: string): bool {
        if (deviceId === "")
            return false;
        if (!root.armed || root.cast === null)
            return root._refuse(deviceId, "Casting is not ready");
        // (the device being cast says so on its own chip: no notice over its status)
        if (root._phase !== "idle")
            return root._device === deviceId ? false : root._refuse(deviceId, "Another cast is still going on");
        const st = root.cast.state;
        if (st !== "idle" && st !== "failed")
            return root._refuse(deviceId, "The last cast is still stopping");
        if (st === "failed")
            root.cast.clearFailure();
        root._clearNotice();
        root._device = deviceId;
        root._ident = "cast:" + deviceId;
        root._name = "";
        root._closed = true;
        root._virtual = false;
        root._phase = "opening";
        root._enter();
        return true;
    }

    function stop(): void {
        if (root._phase === "idle" || root._phase === "stopping")
            return;
        // nothing is streaming yet (the output or the scan is waited for): there is no end to wait for
        if (root._waiting || root._held) {
            root._finish();
            return;
        }
        root._phase = "stopping";
        root.cast.stop(false);
    }

    // ONE stop and ONE start: `q` (optional) is the quality the new run takes, else the plan's
    function restart(q: var): void {
        if (root._phase !== "streaming" && root._phase !== "starting")
            return;
        root._override = q || null;
        root._phase = "restarting";
        root.cast.stop(true);
    }

    // the chip was clicked while its notice stood: the notice goes, the click counts
    function dismissNotice(): void {
        root._clearNotice();
        if (root.cast && root.cast.state === "failed" && root._phase === "idle")
            root.cast.clearFailure();
    }

    function scanIfDue(): bool {
        if (!root.armed || root.cast === null || root._phase !== "idle" || root.cast.scanning || root._castBusy())
            return false;
        const now = Date.now();
        if (root._lastScan > 0 && now - root._lastScan < root.scanEveryMs)
            return false;
        root._lastScan = now;
        return root.cast.scan();
    }

    // The shell's start (or the engine becoming active): tell the engine which cast outputs are live (none unless a cast runs)
    function sync(): void {
        root.keepNames(root._name !== "" && !root._closed ? [root._name] : []);
        // (a mirrored cast keeps no name: it has no output)
    }

    // ---- private ---------------------------------------------------------------------------------------------------------------------------
    property string _phase: "idle"
    property string _device: ""
    property string _ident: ""
    property string _name: ""
    property bool _closed: true              // no output of this cast is open (never opened, or closed already)
    property bool _virtual: false            // the cast mirrors: no output, the stream takes the internal one
    property bool _waiting: false            // the output is asked for and not there (or its setup has not landed) yet
    property bool _held: false               // ready to begin, held by the popup's scan
    property var _override: null
    property var _notice: null
    property real _lastScan: 0

    function _castBusy(): bool {
        const st = root.cast.state;
        return root.cast.scanning || (st !== "idle" && st !== "failed");
    }

    function _outOf(ident: string): var {
        for (const o of root.outputs)
            if (o.castId === ident && o.standIn !== true)
                return o;
        return null;
    }

    function _internalName(): string {
        for (const o of root.outputs)
            if (Model.isInternal(o.name) && !Model.isIgnored(o.name))
                return o.name;
        return "";
    }

    function _specOf(): var {
        // (while it mirrors, the TV's spec is the stand-in's)
        const n = root._virtual ? Staging.CAST_STANDIN : root._name;
        return root.plan && root.plan.specs && n !== "" ? (root.plan.specs[n] || null) : null;
    }

    function _wantMirror(): bool {
        return root._internalName() !== "" && typeof root.mirrorWanted === "function" && root.mirrorWanted(root._ident) === true;
    }

    // the stream's target: the cast's own output, or the internal one while the cast mirrors it
    function _target(): string {
        return root._virtual ? root._internalName() : root._name;
    }

    // The cast takes the shape now wanted and begins: a mirror has no output (one it still has is closed), an extended cast has its
    // output listed with its setup landed.
    function _enter(): void {
        root._held = false;
        if (root._wantMirror()) {
            root._waiting = false;
            openWait.stop();
            root._closeOutput();
            root._virtual = true;
            root._name = "";
            root._ready();
            return;
        }
        root._virtual = false;
        root._closed = false;
        root._waiting = true;
        openWait.interval = root.openWaitMs;
        openWait.restart();
        root.openOutput(root._ident);
        root._look();
    }

    function _ready(): void {
        if (root.cast.scanning) {
            root._held = true;
            return;
        }
        root._held = false;
        root._begin();
    }

    function _closeOutput(): void {
        if (root._closed)
            return;
        root._closed = true;
        const name = root._name !== "" ? root._name : root._nameOf(root._ident);
        if (name !== "")
            root.closeOutput(name);
        root.keepNames([]);
    }

    function _refuse(deviceId: string, text: string): bool {
        root._notice = { device: deviceId, text: text };
        noticeTimer.interval = root.noticeMs;
        noticeTimer.restart();
        return false;
    }

    function _opts(): var {
        const sp = root._specOf();
        const q = Staging.castQuality(root._override || (sp && sp.cast) || {}, root.defaultQuality);
        const o = { res: q.res, fps: q.fps, bitrate: q.bitrate };
        if (q.audio === false)
            o.audio = false;
        return o;
    }

    // the output is listed and the resolved setup has landed: the stream may start
    function _look(): void {
        if (!root._waiting)
            return;
        const out = root._outOf(root._ident);
        const sp = out && root.plan && root.plan.specs ? root.plan.specs[out.name] : null;
        if (!out || !sp || Model.liveDiff(out, sp) !== "")
            return;
        root._waiting = false;
        openWait.stop();
        root._name = out.name;
        root.keepNames([root._name]);
        root._ready();
    }

    function _begin(): void {
        if (root._phase !== "restarting")
            root._phase = "starting";
        if (!root.cast.start(root._device, root._target(), root._opts())) {
            root._fail("The cast could not start");
            return;
        }
    }

    function _fail(text: string): void {
        root._setNotice(text);
        root._finish();
    }

    // the one exit: the output goes (once), the engine is told nothing is live, and the cast service's failure outlives it only as the notice
    function _finish(): void {
        openWait.stop();
        root._waiting = false;
        root._held = false;
        root._closeOutput();
        root._virtual = false;
        root._phase = "idle";
        root._override = null;
        // a hold a restart handed over and no start took is given back
        if (root.cast !== null && typeof root.cast.restore === "function")
            root.cast.restore();
    }

    function _nameOf(ident: string): string {
        for (const n in root.castMap)
            if (root.castMap[n] === ident)
                return n;
        return "";
    }

    function _noticeText(f: var, reason: string): string {
        const r = f && f.reason ? f.reason : reason;
        if (r === "activation")
            return "The TV did not answer";
        if (r === "cancelled")
            return "Cancelled on the TV";
        if (r === "link")
            return "The Wi-Fi link to the TV broke";
        if (r === "peer-gone")
            return "The TV ended the stream";
        return "fluxcast failed: " + String((f && f.detail) || "").slice(0, 60);
    }

    function _setNotice(text: string): void {
        root._notice = { device: root._device, text: text };
        noticeTimer.interval = root.noticeMs;
        noticeTimer.restart();
    }

    function _clearNotice(): void {
        noticeTimer.stop();
        root._notice = null;
    }

    function _onEnded(reason: string): void {
        if (root._phase === "idle")
            return;
        if (root._phase === "restarting") {
            root._enter();
            return;
        }
        if (reason !== "stopped")
            root._setNotice(root._noticeText(root.cast.failure, reason));
        root._finish();
    }

    Connections {
        target: root.cast
        ignoreUnknownSignals: true
        function onStarted() {
            if (root._phase === "starting" || (root._phase === "restarting" && !root._waiting && !root._held))
                root._phase = "streaming";
        }
        function onScanningChanged() {
            if (root._held && !root.cast.scanning)
                root._ready();
        }
        function onEnded(reason: string) {
            root._onEnded(reason);
        }
    }

    // the output's coming, the setup landing
    onOutputsChanged: root._look()
    onPlanChanged: {
        root._look();
        // the mirror moved while streaming: the stream follows (one restart, the cast taking its other shape in between)
        if (root._phase === "streaming" && root._wantMirror() !== root._virtual)
            root.restart(null);
    }
    onArmedChanged: {
        if (!root.armed) {
            if (root._phase !== "idle")
                root.stop();
            return;
        }
        // the shell's start (or the config turning casting on): tell the engine which cast outputs are live (none), look for TVs
        root.sync();
        if (root.popupOpen)
            root.scanIfDue();
    }
    onPopupOpenChanged: {
        if (root.popupOpen)
            root.scanIfDue();
    }

    Timer {
        id: openWait
        onTriggered: {
            if (root._waiting)
                root._fail("The display could not be made");
        }
    }
    Timer {
        id: noticeTimer
        onTriggered: {
            root._notice = null;
            if (root.cast && root.cast.state === "failed" && root._phase === "idle")
                root.cast.clearFailure();
        }
    }
}
