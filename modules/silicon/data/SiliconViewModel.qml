pragma ComponentBehavior: Bound

import QtQuick
import "SiliconModel.js" as Model

// =============================================================================
// SiliconViewModel.qml -- the part of silicon's service the popup, the bar button and the scene
// READ that does not depend on where the data came from. SiliconService and SiliconMock each hold
// one and expose its members as their own, so the facts, the targets and the captions are ONE
// implementation (the stocks module's StocksViewModel pattern).
//
//   build(inputs)      the input record (SiliconModel.buildFacts' header says what is in it)
//                      -> the facts and the captions
//   aim(zone, value)   an INTENT: the target moves at once, the scene animates, the write follows
//   aimTuning(patch)   the pending tuning (what the CPU's panel shows while its write settles)
//   settle(zone)       the write is done: the target follows the facts again
//   fail(zone, why, keepIntent)   refused or mismatched: the target animates BACK to the facts and
//                      `why` goes into the zone's caption error (cpuError / gpuError / batteryError)
//                      until the next intent in that zone or `errorMs` -- whichever comes first.
//                      `keepIntent`: a NEWER intent of the zone is still on its way, its target stands
//   clearError(zone)
//
// FACTS (plain objects, NO colours): cpu, cores, igpu, gpu, memory, display, battery, helper, caption.
// TARGETS, in the SCENE's order (CONTRACT section 6), not the kernel's and not cardwire's:
//   profileTarget       0 Quiet, 1 Balanced, 2 Performance
//   gpuModeTarget       0 Integrated, 1 Smart, 2 Hybrid, 3 dGPU-only; what was last asked while it is
//                       on its way, then -- a MUX request that waits for a restart is a target until it
//                       is answered, cancelled or applied (the record is the truth, so it survives a
//                       shell restart) -- where the request goes: dGPU-only, or the way back to the mode
//                       asked for after it (`gpu.mux.afterMode`, Hybrid when none), which the arrows can
//                       move to Smart and Integrated under the one queued request
//   chargeLimitTarget   80 | 100
// and the actual state in the same orders: profileIndex, gpuMode.
//
// Zones are "cpu", "gpu" (and the MUX, which shows in the GPU zone) and "battery".
// =============================================================================
Item {
    id: root

    readonly property var _seed: Model.buildFacts({
        config: Model.defaultConfig(),
        helper: { installed: false, ok: false, why: "the silicon helper has not been asked yet", answered: false },
        status: null, sensors: null, cardwire: { present: false, asked: false, why: "cardwire has not been asked yet" },
        smi: null, battery: null, overheadW: 0, lastFullMs: 0, hold: null, muxOutcomeSeenAt: 0
    })

    property var cpu: root._seed.cpu
    property var cores: root._seed.cores
    property var igpu: root._seed.igpu
    property var gpu: root._seed.gpu
    property var memory: root._seed.memory
    property var display: root._seed.display
    property var battery: root._seed.battery
    property var helper: root._seed.helper
    property var caption: Model.buildCaption(root._seed, ({}))
    property var tuningTarget: ({})

    readonly property int profileIndex: Model.profileIndex(root.cpu.profile)
    readonly property int gpuMode: root.gpu.step
    readonly property int profileTarget: root._intent.profile !== null ? root._intent.profile : root.profileIndex
    readonly property int gpuModeTarget: root._intent.gpu !== null ? root._intent.gpu
        : (root.gpu.mux.pending ? (root.gpu.mux.want === "dgpu" ? 3 : (root.gpu.mux.afterMode !== null ? root.gpu.mux.afterMode : 2))
                                : root.gpu.step)
    readonly property int chargeLimitTarget: root._intent.limit !== null
        ? root._intent.limit : (root.battery.limitOn ? root.battery.limitPct : 100)

    property int errorMs: 10000

    // WHICH READING the facts are from: the beat's serial and period (ms) that the service's reader fired on, or the mock's
    // tick count and `tickMs`, and the reading's own time. A display that changes slower than the readings changes on a reading whose
    // serial is a multiple of its own period in readings, never between two; the since-full display counts from `readingAtMs`.
    // `readingSerial` is written LAST in a build, so whoever reacts to it sees the whole reading.
    property int readingSerial: 0
    property int readingMs: 1000
    property double readingAtMs: Date.now()

    function build(inputs) {
        const f = Model.buildFacts(inputs);
        root.readingMs = inputs.readingMs;
        root.readingAtMs = inputs.nowMs;
        root.cpu = f.cpu;
        root.cores = f.cores;
        root.igpu = f.igpu;
        root.gpu = f.gpu;
        root.memory = f.memory;
        root.display = f.display;
        root.battery = f.battery;
        root.helper = f.helper;
        root._caption();
        root.readingSerial = inputs.readingSerial;
    }

    function aim(zone, value) {
        root.clearError(zone);
        const i = Object.assign({}, root._intent);
        if (zone === "cpu")
            i.profile = value;
        else if (zone === "gpu")
            i.gpu = value;
        else if (zone === "battery")
            i.limit = value;
        root._intent = i;
    }

    function aimTuning(patch) {
        root.tuningTarget = patch ? Object.assign({}, patch) : ({});
    }

    function settle(zone) {
        root._dropIntent(zone);
    }

    function fail(zone, why, keepIntent) {
        if (!keepIntent)
            root._dropIntent(zone);
        const e = Object.assign({}, root._errors);
        e[zone] = String(why);
        root._errors = e;
        const at = Object.assign({}, root._errorAt);
        at[zone] = Date.now();
        root._errorAt = at;
        root._caption();
        sweep.restart();
    }

    function clearError(zone) {
        if (!root._errors[zone])
            return;
        const e = Object.assign({}, root._errors);
        delete e[zone];
        root._errors = e;
        root._caption();
    }

    // ---- Private -----------------------------------------------------------------
    property var _intent: ({ profile: null, gpu: null, limit: null })
    property var _errors: ({})
    property var _errorAt: ({})

    function _dropIntent(zone) {
        const i = Object.assign({}, root._intent);
        if (zone === "cpu") {
            i.profile = null;
            root.tuningTarget = ({});
        } else if (zone === "gpu") {
            i.gpu = null;
        } else if (zone === "battery") {
            i.limit = null;
        }
        root._intent = i;
    }

    function _caption() {
        root.caption = Model.buildCaption({ cpu: root.cpu, gpu: root.gpu, battery: root.battery, helper: root.helper },
                                          { cpu: root._errors.cpu, gpu: root._errors.gpu, battery: root._errors.battery });
    }

    // An error is shown until the next intent in its zone or `errorMs`; one timer sweeps them.
    Timer {
        id: sweep
        interval: 500
        repeat: true
        onTriggered: {
            const now = Date.now();
            const zones = Object.keys(root._errors);
            let any = false;
            for (let i = 0; i < zones.length; i++) {
                if (now - (root._errorAt[zones[i]] || 0) >= root.errorMs)
                    root.clearError(zones[i]);
                else
                    any = true;
            }
            if (!any)
                sweep.stop();
        }
    }
}
