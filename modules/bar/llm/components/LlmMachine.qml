pragma ComponentBehavior: Bound

import QtQuick
import "../../../common/power"
import "../../../common/system"

// =============================================================================
// LlmMachine.qml -- what the chat asks of the MACHINE while a model is loaded.
//
// Loading a model may enable the dGPU, as the system update sets the CPU profile to performance. It may also go to the
// balanced CPU profile for as long as the model is loaded, and return to quiet when done if that was the profile it came from.
// Going to balanced happens only from quiet (or from a balanced tuned to lower power). Changing the CPU profile by hand after
// the automatic change is definitive: the return does not happen. After a model loads, `ollama ps` must say GPU, else the
// service is restarted and the model reloaded.
//
// THREE THINGS, ONE CLOCK (the model being loaded):
//   THE CARD    gpu.acquire("llm") while a model is wanted -- a turn running, or any model resident in /api/ps (a tuner's load
//               counts) -- and gpu.release("llm") `lingerMs` after neither is true (an unload and a reload a moment apart keep
//               it). OllamaGpu is the shell's ONE, shared with the wiki: the mode goes back when the last holder lets go.
//   THE FLOOR   PowerBus.hold("llm", "balanced", ..., "floor") for the same span. A floor RAISES and never lowers (PowerFloor.js,
//               HoldFollower): Quiet -> Balanced and back; a Balanced tuned to lower power -> stock Balanced; Performance left
//               alone. A manual profile change drops every hold (PowerBus.dropAll): that is definitive, the hold is not taken
//               again until the model has gone and come back, and nothing is put back.
//   THE CHECK   once a resident model has been seen with nothing streaming, gpu.verifyLoad(model): on the CPU with the card up,
//               ollama is restarted ONCE (polkit path), the model is loaded again (LlmService.reloadModel) and checked again; a
//               second CPU answer is `note`, not another restart. A restart never lands under a running answer: the check waits
//               for the turn (and its title) to end.
//
// THE GATE (LlmService.sendGate): the turn's first request waits for `request()` to say true -- the card ready -- so the weights
// are loaded onto the GPU the first time, not on the CPU and then again. `opened()` lets it go; a card that could not be had
// opens it too (the chat works on whatever the machine has) and says why in `note`.
//
// Without a `gpu` (or one that cannot drive: no silicon, no cardwire) the gate is always open and only the floor works; `floorEnabled` false
// (llm.jsonc "machine"; a server that is not this machine's has neither) holds no profile.
// =============================================================================
Item {
    id: root

    property var service: null          // LlmService
    property var gpu: null              // OllamaGpu, the shell's ONE (null = the card is not ours to drive)
    property bool floorEnabled: true
    property string floorProfile: "balanced"
    property string holder: "llm"
    property int lingerMs: 5000
    // While the card is held and nothing streams, how often /api/ps is read, so a model ollama's own keep-alive evicted is noticed
    // (the service reads it only when something asks).
    property int refreshMs: 30000

    // ---- the gate (LlmService.sendGate) ------------------------------------------------------------------
    readonly property string say: root._waiting && root.gpu ? (root.gpu.sayOf(root.gpu.phase) || "getting the GPU ready") : ""
    signal opened()
    function request() {
        if (!root.gpu || !root.gpu.drivable)
            return true;
        root._engage();
        // ready, or refused on the spot (`_card` falls with the failure): either way the request goes
        if (!root._card || root.gpu.isReady(root.holder))
            return true;
        root._waiting = true;
        return false;
    }

    // ---- what it holds, for a mockup's panel ---------------------------------------------------------------------
    readonly property bool wanted: root._turn || root._resident
    readonly property bool holdingCard: root._card
    readonly property bool holdingFloor: root._floor
    // The last thing that did not work (the card could not be had, the model stays on the CPU); "" when nothing.
    readonly property string note: root._note

    property bool _waiting: false
    property bool _card: false
    property bool _floor: false
    property bool _dropped: false       // the user took the profile back: not again until the model has gone
    property string _note: ""
    property var _verified: ({})        // model -> checked (or given up on) while resident
    property string _checking: ""
    readonly property bool _turn: root._turnNow()
    readonly property var _loaded: !!root.service && !!root.service.backend ? root.service.backend.loaded : null
    readonly property bool _resident: root._residentNow()
    // The facts themselves, for a change handler: it runs BEFORE the bindings on the same change have followed (`wanted` still holds
    // the old answer there), so it asks these.
    function _turnNow() {
        return !!root.service && root.service.generating === true;
    }
    function _residentNow() {
        const m = !!root.service && !!root.service.backend ? root.service.backend.loaded : null;
        if (!m)
            return false;
        for (const k in m) {
            if (m[k] && (m[k].size || 0) > 0)
                return true;
        }
        return false;
    }

    onFloorEnabledChanged: {
        if (root.floorEnabled) {
            root._follow();
        } else if (root._floor) {
            PowerBus.release(root.holder);
            root._floor = false;
        }
    }
    on_TurnChanged: root._follow()
    on_ResidentChanged: root._follow()
    Component.onCompleted: root._follow()

    function _follow() {
        if (root._turnNow() || root._residentNow()) {
            linger.stop();
            root._engage();
        } else if (root._card || root._floor) {
            linger.restart();
        }
        root._look();
    }

    Timer {
        id: linger
        interval: root.lingerMs
        onTriggered: {
            if (!root._turnNow() && !root._residentNow())
                root._disengage();
        }
    }

    function _engage() {
        if (root.floorEnabled && !root._floor && !root._dropped)
            root._floor = PowerBus.hold(root.holder, root.floorProfile, "Language model loaded", "floor");
        if (root.gpu && root.gpu.drivable) {
            root._card = true;
            root.gpu.acquire(root.holder);       // idempotent; told again if it is ready, and may refuse on the spot
        }
    }

    function _disengage() {
        if (root._floor)
            PowerBus.release(root.holder);
        root._floor = false;
        root._dropped = false;
        if (root._card && root.gpu)
            root.gpu.release(root.holder);
        root._card = false;
        root._waiting = false;
        root._verified = ({});
        root._checking = "";
        root._note = "";
    }

    Connections {
        target: PowerBus
        function onDropped(sources) {
            if (sources.indexOf(root.holder) < 0)
                return;
            root._floor = false;
            root._dropped = true;
        }
    }

    Connections {
        target: root.gpu
        ignoreUnknownSignals: true
        function onReadyFor(holder) {
            if (holder !== root.holder)
                return;
            root._note = "";
            root._open();
            root._look();
        }
        function onFailedFor(holder, why) {
            if (holder !== root.holder)
                return;
            root._card = false;
            root._note = why;
            console.log("[llm gpu] " + why);
            root._open();
        }
        function onVerified(model) {
            if (model !== root._checking)
                return;
            root._markVerified(model);
        }
        function onReloadNeeded(model) {
            if (model !== root._checking || !root.service)
                return;
            root.service.reloadModel(model);
            root.gpu.verifyLoad(model);
        }
        function onVerifyFailed(model, why) {
            if (model !== root._checking)
                return;
            root._note = why;
            console.log("[llm gpu] " + why);
            root._markVerified(model);
        }
    }

    function _open() {
        if (!root._waiting)
            return;
        root._waiting = false;
        root.opened();
    }

    function _markVerified(model) {
        const v = Object.assign({}, root._verified);
        v[model] = true;
        root._verified = v;
        root._checking = "";
        if (root.service && root.service.backend && root.service.backend.refreshLoaded)
            root.service.backend.refreshLoaded();
    }

    // ---- the check after a load ---------------------------------------------------------------------------------
    Connections {
        target: root.service && root.service.backend ? root.service.backend : null
        ignoreUnknownSignals: true
        function onLoadedChanged() { root._look(); }
    }
    Connections {
        target: root.service
        ignoreUnknownSignals: true
        function onTitlingChanged() { root._look(); }
    }

    // A resident model nobody has checked, with the card up and nothing streaming (a restart would end the answer).
    function _look() {
        if (!root.gpu || !root.gpu.drivable || !root._card || !root.gpu.isReady(root.holder) || root._checking !== "")
            return;
        if (!root.service || root.service.generating || root.service.titling)
            return;
        const m = root._loaded;
        if (!m)
            return;
        const seen = ({});
        let todo = "";
        for (const k in m) {
            if (!m[k] || (m[k].size || 0) <= 0)
                continue;
            seen[k] = true;
            if (root._verified[k] !== true && todo === "")
                todo = k;
        }
        // a model that left is forgotten: coming back, it is checked again
        const keep = ({});
        for (const k in root._verified) {
            if (seen[k])
                keep[k] = true;
        }
        root._verified = keep;
        if (todo !== "") {
            root._checking = todo;
            root.gpu.verifyLoad(todo);
        }
    }

    // The residency is read only when something asks: while the card is held and nothing streams, ask now and then.
    Timer {
        interval: root.refreshMs
        repeat: true
        running: root._card && !!root.service && !root.service.generating
        onTriggered: {
            const be = root.service ? root.service.backend : null;
            if (be && be.refreshLoaded)
                be.refreshLoaded();
        }
    }
}
