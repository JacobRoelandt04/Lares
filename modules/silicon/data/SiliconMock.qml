pragma ComponentBehavior: Bound

import QtQuick
import "../../common/board"
import "../../common/power"
import "HelperProto.js" as Proto
import "SiliconModel.js" as Model
import "MockTimeline.js" as TL
import "CardwireParse.js" as CW
import "PowerMath.js" as Pm

// =============================================================================
// SiliconMock.qml -- silicon's service with no machine behind it: the SAME members as SiliconService
// (facts, targets, signals, intents),
// over the same SiliconViewModel, driven by a TIMELINE the mockup can scrub. No Process, no file, no
// bus: a mockup, a harness or a film can run the popup against it anywhere.
//
// THE TIMELINE (MockTimeline.js: pure functions of time). `scenario` names one -- desk, compile, game,
// unplug, charge -- and `timeMs` is where in its minute-long loop the mock stands: bind a scrubber to
// it, or let it play (`playing`, `speed`). The sensors (cores, clock, temperature, the iGPU, the dGPU's
// state, its users and readings) and the battery are read from it; PowerMath turns the battery's
// samples into the same events the service emits. A jump of the clock (a scrub, the loop's wrap) fires
// nothing and starts the battery's average afresh.
//
// THE DEVICE (the status the helper would report, cardwire's mode, the charge limit, the MUX record) is
// the mock's own state, changed by the intents with a simulated settle + write (`settleMs`, `writeMs`);
// `refuseNext` ("cpu" | "gpu" | "battery" | "mux") makes the next write of that zone fail, which
// exercises the animate-back-and-explain path; `helperPresent` / `cardwirePresent` false greys a zone.
//
// THE MACHINE AT WILL (a reviewer's knobs over the timeline; each takes effect at once and plays what
// the machine's own change would -- an AC change pulses and plugs): `machinePct` (0..100, -1 follows
// the timeline) and `machineAc` ("on" | "off", "" follows it) set the pack, its status following from
// them and the charge limit as the firmware's does (plugged at the 80 % limit is "Not charging");
// `machineDgpu` ("asleep" | "awake" | "busy", "" follows) puts the dGPU in a state -- awake with
// nobody on it has no readings (the service asks nvidia-smi only while a real user holds the card),
// busy has `machineHolders` as its users; `helperOk` false is a helper that is installed but whose
// status fails; `hiddenFeatures` (names of the status's `features`) is a kernel without those knobs;
// `muxUnitActive` false is silicon-mux.service not running: the dGPU direction's pre-check fails with the helper's
// words and a NEW MUX request in either direction is refused with them (a queued change would never be written);
// `bootWindowS` and `promptWindowS` are the pretend guard's two windows -- the helper's constants
// (SiliconModel.MUX_BOOT_WINDOW_S / MUX_PROMPT_WINDOW_S, also the facts `gpu.mux.bootWindowS` / `promptWindowS`)
// unless a harness shortens them to see a revert without waiting.
//
// THE WAY BACK FROM dGPU-ONLY is the service's, step for step: all four steps while the wiring is dGPU-only, a step
// left is a request for Hybrid with the mode wanted after the restart riding along (`_afterMuxMode`, which the
// service keeps in SiliconState), a re-aim under the queued request asks nothing, `muxRebootNow()` is the restart --
// and the mode is then set through the mock's own cardwire path, once. Like the helper, a request over a record that
// waits for the user's answer (`awaiting-keep`) is refused. The MUX asks are answered ONE AT A TIME, in order, `writeMs`
// apart (the service's write lane), so a user who steps faster than that has several in flight; the mode wanted after
// the restart is the LAST step asked for, written where it is asked and never by an answer.
//
// THE BOOT PROFILE is the service's rule (Model.bootPlan / bootDecide) over a pretend boot set (`_bootApply`, nothing stored at
// first): a `config` naming a `defaultProfile` is stored one write later (`writeMs`; `refuseNext` "boot" refuses it), and nothing
// is ever applied -- the profile in use does not move.
//
// What only a mock has: externalProfile(name), externalGpuMode(step), externalLimit(on) -- a change
// "made outside the popup" (the OSD request and the notification fallback are the owner's, as in the
// service).
// =============================================================================
Item {
    id: root

    // ---- the mock's own controls (the mockup's panel) ------------------------------------------
    property string scenario: "desk"
    property real timeMs: 0
    property bool playing: true
    property real speed: 1
    property int tickMs: 250          // the timeline's step: the mock's reading period
    property int settleMs: 300
    property int writeMs: 150
    property string refuseNext: ""
    property bool helperPresent: true
    property bool cardwirePresent: true
    property int machinePct: -1
    property string machineAc: ""
    property string machineDgpu: ""
    property var machineHolders: ["steam", "proton"]
    property bool helperOk: true
    property var hiddenFeatures: []
    property bool muxUnitActive: true
    property int bootWindowS: Model.MUX_BOOT_WINDOW_S
    property int promptWindowS: Model.MUX_PROMPT_WINDOW_S
    // MOCK ONLY (the mockup's Memory group, the render harness): memory facts pinned by hand, { usedFraction: 0..1 } or null for the scenario's own.
    // The facts themselves are made from it (the same total the timeline reads), so the view model, the board's RAM display and its chips all follow
    // from this ONE source -- nothing writes the scene's `memory` behind the facts' back.
    property var memoryOverride: null
    // MOCK ONLY (the mockup's Display group): an external display is connected to the NVIDIA card's HDMI connector (the fact `display.hdmi`;
    // the service reads it from /sys/class/drm). A DisplayLink dock or a USB-C display is not this fact, so there is no knob for them.
    property bool hdmiConnected: false

    // ---- the service's members -------------------------------------------------------------------
    property bool popupOpen: false
    readonly property string idleState: ladder.level
    property var config: Model.defaultConfig()
    property var configWarnings: []
    property string configError: ""
    readonly property var bootProfile: root._boot

    readonly property int readingSerial: vm.readingSerial
    readonly property int readingMs: vm.readingMs
    readonly property double readingAtMs: vm.readingAtMs
    readonly property var cpu: vm.cpu
    readonly property var cores: vm.cores
    readonly property var igpu: vm.igpu
    readonly property var gpu: vm.gpu
    readonly property var memory: vm.memory
    readonly property var display: vm.display
    readonly property var battery: vm.battery
    readonly property var helper: vm.helper
    readonly property var caption: vm.caption
    readonly property var tuningTarget: vm.tuningTarget
    readonly property int profileTarget: vm.profileTarget
    readonly property int gpuModeTarget: vm.gpuModeTarget
    readonly property int chargeLimitTarget: vm.chargeLimitTarget
    readonly property int profileIndex: vm.profileIndex
    readonly property int gpuMode: vm.gpuMode

    signal batteryEvent(string kind)
    signal acChanged(bool on)
    signal gpuPowerChanged(string dState)
    signal writeRefused(string zone, string why)
    signal appBlocked(var app)
    signal osd(var request)

    // ---- intents: the CPU ------------------------------------------------------------------------
    function stepProfile(dir) {
        if (!root._cpuReady())
            return root._refuse("cpu", root._cpuWhy());
        const to = Model.nextProfile(vm.profileTarget, dir, vm.cpu.profiles);
        return to === null ? false : root.setProfile(to);
    }

    function setProfile(index) {
        const name = Model.PROFILES[index];
        if (!root._cpuReady())
            return root._refuse("cpu", root._cpuWhy());
        if (name === undefined || vm.cpu.profiles.indexOf(name) < 0)
            return root._refuse("cpu", "That profile is not available");
        if (index === vm.profileTarget && !vm.cpu.tweaked)
            return false;
        PowerBus.dropAll("manual");
        return root._switchProfile(name);
    }

    function setTuning(patch) {
        if (!root._cpuReady())
            return root._refuse("cpu", root._cpuWhy());
        const merged = Object.assign({}, root._cpuPatch, patch);
        const v = Proto.validatePatch(merged, root._shown());
        if (!v.ok)
            return root._refuse("cpu", v.why);
        root._cpuPatch = merged;
        vm.clearError("cpu");
        vm.aimTuning(root._tuningOf(merged));
        cpuWrite.restart();
        return true;
    }

    function resetTuning() {
        if (!root._cpuReady())
            return root._refuse("cpu", root._cpuWhy());
        if (vm.cpu.profile === "")
            return false;
        PowerBus.dropAll("manual");
        return root._switchProfile(vm.cpu.profile);
    }

    // ---- intents: the battery -------------------------------------------------------------------------
    function setChargeLimit(on) {
        if (!root._helperUp() || !root._shown().features.chargeLimit)
            return root._refuse("battery", "The charge limit is not available on this machine");
        const pct = on ? 80 : 100;
        if (pct === vm.chargeLimitTarget)
            return false;
        vm.aim("battery", pct);
        root._limitPending = pct;
        limitWrite.restart();
        return true;
    }

    // ---- intents: the GPU --------------------------------------------------------------------------------
    function stepGpuMode(dir) {
        if (!vm.gpu.present)
            return root._refuse("gpu", "GPU modes need cardwire: " + vm.gpu.why);
        const to = Model.stepFrom(vm.gpuModeTarget, dir, vm.gpu.steps);
        return to === null ? false : root.setGpuMode(to, {});
    }

    function setGpuMode(step, opts) {
        const plan = Model.planGpuMode(step, opts, vm.gpu, vm.gpuModeTarget);
        if (plan.action === "refuse")
            return root._refuse("gpu", plan.why);
        if (plan.action === "mux")
            return root.muxRequest(plan.want, plan.after);
        if (plan.action === "reaim") {
            vm.clearError("gpu");
            root._afterMuxMode = plan.after;
            return true;
        }
        if (plan.action === "none")
            return false;
        if (plan.action === "cancelmux") {
            // the mock withdraws the record at once, then the step goes the normal way
            root.muxCancel();
            vm.aim("gpu", step);
            root.osd(Model.osdMuxCancelled(step));
            root._gpuPending = plan.cw;
            gpuWrite.restart();
            return true;
        }
        vm.aim("gpu", step);
        root._gpuPending = plan.cw;
        gpuWrite.restart();
        return true;
    }

    function setCardwireConfig(key, value) {
        if (!vm.gpu.present)
            return root._refuse("gpu", "GPU settings need cardwire: " + vm.gpu.why);
        if (CW.setConfigArgv("session", key, value) === null)
            return root._refuse("gpu", "That setting is not available");
        vm.clearError("gpu");
        const c = Object.assign({}, root._cwConfig);
        c[key] = value;
        root._cwConfig = c;
        root._compute();
        return true;
    }

    function setAppPolicy(app, allowed) {
        if (!vm.gpu.present)
            return root._refuse("gpu", "App policies need cardwire: " + vm.gpu.why);
        vm.clearError("gpu");
        root._allPolicies = root._allPolicies.map(function (a) {
            return a.id === app ? Object.assign({}, a, { policy: allowed ? 1 : 0 }) : a;
        });
        root._compute();
        return true;
    }

    function ignoreApp(app) {
        if (typeof app === "string" && app !== "" && root._ignored.indexOf(app) < 0) {
            root._ignored = root._ignored.concat([app]);
            root._compute();
        }
    }

    // ---- intents: the MUX -------------------------------------------------------------------------------
    function muxRequest(want, after) {
        if (!root._helperUp() || !root._shown().features.mux)
            return root._refuse("mux", "The MUX switch is not available on this machine");
        const step = want === "dgpu" ? Model.STEP.DGPU : (after === 0 || after === 1 || after === 2 ? after : Model.STEP.HYBRID);
        vm.aim("gpu", step);
        // on the lane first, so that the facts rebuilt by the write below see a request on its way
        const op = { op: "request", want: want };
        if (root._muxOp === null) {
            root._muxOp = op;
            muxWrite.restart();
        } else {
            root._muxBehind = root._muxBehind.concat([op]);
        }
        // the mode wanted after the way back: THIS ask's, now (the service: SiliconState.afterMuxMode); a dGPU request takes it away
        root._afterMuxMode = want === "dgpu" ? null : step;
        return true;
    }

    // The mock restarts at once: the new wiring is in and the "keep this?" prompt is awaiting.
    property var rebootArgv: null           // the service's property of the name; the mock restarts at once and runs nothing
    function muxRebootNow() {
        const rec = root._status.mux.record;
        if (!rec || rec.state !== "queued")
            return root._refuse("mux", "No restart is waiting for a MUX change");
        const st = JSON.parse(JSON.stringify(root._status));
        st.mux.wiringNow = rec.want;
        st.mux.stored = rec.want;
        st.mux.record = Object.assign({}, rec, rec.want === "dgpu" ? { state: "awaiting-keep", deadlineMs: Date.now() + root.bootWindowS * 1000 } : { state: "kept", deadlineMs: null });
        root._status = st;
        root._compute();
        return true;
    }

    function muxKeep() { return root._muxRecordTo("awaiting-keep", "kept"); }
    function muxCancel() {
        root._afterMuxMode = null;      // the request is withdrawn, and so is the mode that rode with it
        return root._muxRecordTo("queued", "cancelled");
    }
    function muxPromptShown() {
        const rec = root._status.mux.record;
        if (!rec || rec.state !== "awaiting-keep")
            return false;
        const st = JSON.parse(JSON.stringify(root._status));
        st.mux.record.deadlineMs = Math.min(rec.deadlineMs, Date.now() + root.promptWindowS * 1000);
        root._status = st;
        root._compute();
        return true;
    }

    function markMuxOutcomeSeen() {
        const rec = root._status.mux.record;
        if (rec && typeof rec.requestedAtMs === "number")
            root._outcomeSeenAt = rec.requestedAtMs;
        root._compute();
    }

    // ---- lifecycle -----------------------------------------------------------------------------------------
    function touch() { ladder.touch(); }
    function refresh() { root._step(); }

    // ---- what only a mock has --------------------------------------------------------------------------------
    // A change made outside the popup: the status moves, the OSD is asked for, the target follows.
    function externalProfile(name) {
        if (Model.PROFILES.indexOf(name) < 0)
            return;
        PowerBus.dropAll("external");
        const lp = Model.linkedPatch(root.config, name, root._shown());
        root._status = root._applied(root._status, lp.patch);
        root.osd(Model.osdProfile(name));
        root._compute();
    }

    function externalGpuMode(step) {
        const cw = Model.cwOfStep(step);
        if (cw === null)
            return;
        root._mode = cw;
        root.osd(Model.osdGpu(step));
        root._compute();
    }

    function externalLimit(on) {
        root._status = root._applied(root._status, { chargeLimit: on ? 80 : 100 });
        root.osd(Model.osdLimit(on ? 80 : 100));
        root._compute();
    }

    // =====================================================================================
    // Private
    // =====================================================================================
    property var _status: TL.defaultStatus()
    property int _mode: 1
    property var _modes: [0, 1, 3]
    property var _cwConfig: ({ batteryAutoSwitch: false, batteryAutoSwitchMode: 1, externalDisplayAutoSwitch: false, nvidiaBlock: false })
    property var _allPolicies: [
        { id: "kitty", name: "kitty URL Launcher", desktopIds: ["kitty-open"], icons: ["kitty"], policy: 0 },
        { id: "quickshell", name: "Quickshell", desktopIds: ["org.quickshell"], icons: ["org.quickshell"], policy: 0 },
        { id: "steam_app_1295660", name: "Sid Meier's Civilization VII", desktopIds: ["steam_app_1295660"], icons: [], policy: 1 },
        { id: "zen-bin", name: "Zen Browser", desktopIds: ["zen"], icons: ["zen-browser"], policy: 0 }
    ]
    property var _blocked: ["kitty", "quickshell", "zen-bin"]
    property var _ignored: []
    property real _lastFullMs: 0
    property real _outcomeSeenAt: 0
    property var _pm: Pm.newState()
    property var _sample: null
    property var _prev: null
    property int _readings: 0       // the timeline's steps so far: the mock's reading serial (a tick is one; the service's is its beat's)
    property var _cpuPatch: ({})
    property var _limitPending: null
    property var _gpuPending: null
    property var _muxOp: null               // the MUX ask the next write answers (null: none on its way) ...
    property var _muxBehind: []             // ... and the ones asked while it was, in order
    property var _afterMuxMode: null        // the step wanted once the way back from dGPU-only has been restarted (the service keeps it in SiliconState)
    property real _lastT: 0
    property bool _ticking: false
    property string _lastD: ""
    property var _boot: ({ want: null, state: "off", why: "" })
    property var _bootApply: ({})           // the boot set the pretend helper holds: { <apply argument>: value }
    property var _bootLast: null
    property var _bootPatch: null           // the set-boot on its way (null: none)

    SiliconViewModel { id: vm }
    // The popup's idle ladder: its four times are the module's constants (IdleLadder), which the silicon mockup tunes through this.
    readonly property alias idleLadder: ladder
    IdleLadder {
        id: ladder
        open: root.popupOpen
    }
    HoldFollower {
        id: holds
        current: Model.PROFILES[vm.profileTarget]
        ready: root.helperPresent && root.helperOk
        onSwitchRequested: name => root._switchProfile(name)
    }

    function _cpuReady() {
        return root._helperUp() && root._shown().features.profile;
    }

    function _cpuWhy() {
        return root.helperPresent
            ? "Power control is unavailable: " + root._helperWhy
            : "Power profiles need the silicon helper, which is not installed";
    }

    // The helper as the shell sees it: installed and answering, and the status it would report (a
    // hidden feature is a knob this kernel does not have). Functions, read from the switches
    // themselves: the switches' change handlers recompute the facts, and a handler runs before a
    // binding that depends on the same property has followed it.
    function _helperUp() {
        return root.helperPresent && root.helperOk;
    }
    readonly property string _helperWhy: "the helper speaks protocol 2, this shell speaks 1 (mock)"
    function _shown() {
        const hide = root.hiddenFeatures || [];
        if (hide.length === 0 && root.muxUnitActive)
            return root._status;
        const st = JSON.parse(JSON.stringify(root._status));
        hide.forEach(function (k) {
            if (k in st.features)
                st.features[k] = false;
        });
        if (!root.muxUnitActive) {
            const pc = st.prechecks.mux;
            st.prechecks.mux = { ok: false, why: pc.ok ? root._unitWhy : pc.why + "; " + root._unitWhy };
        }
        return st;
    }
    // The helper's own words (HELPER_PROTOCOL.md): what a request meets while the unit that writes a queued change at
    // shutdown is not running.
    readonly property string _unitWhy: "silicon-mux.service is not active, so a GPU mode change queued now would never be written at shutdown (sudo systemctl start silicon-mux.service)"

    function _refuse(zone, why) {
        vm.fail(zone === "mux" ? "gpu" : zone, why);
        root.writeRefused(zone, why);
        return false;
    }

    function _tuningOf(patch) {
        const t = Object.assign({}, patch);
        delete t.profile;
        return t;
    }

    function _switchProfile(name) {
        const shown = root._shown();
        const lp = Model.linkedPatch(root.config, name, shown);
        const v = Proto.validatePatch(lp.patch, shown);
        if (!v.ok)
            return root._refuse("cpu", v.why);
        root._cpuPatch = Object.assign({}, lp.patch);
        vm.aim("cpu", Model.profileIndex(name));
        vm.aimTuning(root._tuningOf(lp.patch));
        cpuWrite.restart();
        return true;
    }

    // The status after a patch (what the helper's answer would say).
    function _applied(status, patch) {
        const st = JSON.parse(JSON.stringify(status));
        const v = st.values;
        const ceil = st.limits.capCeilW;
        Object.keys(patch).forEach(function (k) {
            if (k === "pl1W" || k === "pl2W") {
                const w = patch[k] === "firmware" ? (ceil ? ceil[k === "pl1W" ? "pl1" : "pl2"] : v.caps[k]) : patch[k];
                v.caps[k] = w;
                v.caps.zones.msr[k] = w;
                v.caps.zones.mmio[k] = w;
            } else {
                v[k] = patch[k];
            }
        });
        st.limits.eppLocked = v.governor === "performance";
        return st;
    }

    function _muxRecordTo(from, to) {
        const rec = root._status.mux.record;
        if (!rec || rec.state !== from)
            return false;
        const st = JSON.parse(JSON.stringify(root._status));
        st.mux.record.state = to;
        root._status = st;
        vm.settle("gpu");
        root._compute();
        return true;
    }

    // A write that is refused animates back with its words; `refuseNext` arms one.
    function _refusedNow(zone) {
        if (root.refuseNext !== zone)
            return false;
        root.refuseNext = "";
        root._refuse(zone, "Mock: the " + (zone === "gpu" ? "daemon" : "helper") + " refused the write");
        return true;
    }

    Timer {
        id: cpuWrite
        interval: root.settleMs + root.writeMs
        onTriggered: {
            const patch = root._cpuPatch;
            root._cpuPatch = ({});
            if (root._refusedNow("cpu"))
                return;
            root._status = root._applied(root._status, patch);
            vm.settle("cpu");
            root._compute();
        }
    }
    Timer {
        id: limitWrite
        interval: root.settleMs + root.writeMs
        onTriggered: {
            const pct = root._limitPending;
            root._limitPending = null;
            if (root._refusedNow("battery"))
                return;
            root._status = root._applied(root._status, { chargeLimit: pct });
            vm.settle("battery");
            root._compute();
        }
    }
    Timer {
        id: gpuWrite
        interval: root.writeMs
        onTriggered: {
            const cw = root._gpuPending;
            root._gpuPending = null;
            if (root._refusedNow("gpu"))
                return;
            root._mode = cw;
            vm.settle("gpu");
            root._compute();
        }
    }
    Timer {
        id: muxWrite
        interval: root.writeMs
        onTriggered: {
            const op = root._muxOp;
            root._muxOp = root._muxBehind.length > 0 ? root._muxBehind[0] : null;
            root._muxBehind = root._muxBehind.slice(1);
            if (root._muxOp !== null)
                muxWrite.restart();         // the next ask is answered one write later
            // (a refused ask rebuilds the facts, as the service's reply does: the mode it asked for after the way back is forgotten then)
            if (root._refusedNow("mux")) {
                root._compute();
                return;
            }
            const st = JSON.parse(JSON.stringify(root._status));
            // the helper's first refusal (mux.rs request()): a record that waits for the user's answer is not asked over
            if (st.mux.record && st.mux.record.state === "awaiting-keep") {
                root._refuse("mux", "a GPU mode change is waiting for your confirmation");
                root._compute();
                return;
            }
            if (st.mux.wiringNow === op.want) {
                if (st.mux.record && st.mux.record.state === "queued")
                    st.mux.record.state = "cancelled";
            } else if (st.mux.record && st.mux.record.state === "queued" && st.mux.record.want === op.want) {
                // already queued: the same request is not a new record
            } else {
                // only a NEW record needs the unit (cancelling one needs nothing), as the helper judges it
                if (!root.muxUnitActive) {
                    root._refuse("mux", root._unitWhy);
                    root._compute();
                    return;
                }
                st.mux.record = { want: op.want, from: st.mux.wiringNow, state: "queued", why: "", requestedAtMs: Date.now(), bootId: "mock", deadlineMs: null };
            }
            root._status = st;
            vm.settle("gpu");
            root._compute();
        }
    }
    Timer {
        id: bootWrite
        interval: root.writeMs
        onTriggered: {
            const patch = root._bootPatch;
            root._bootPatch = null;
            if (root.refuseNext === "boot") {
                root.refuseNext = "";
                if (root._bootLast !== null)
                    root._bootLast = { memo: root._bootLast.memo, why: "Mock: the helper refused the boot set" };
            } else {
                const apply = {};
                Proto.applyWords(patch).forEach(function (w) { const at = w.indexOf("="); apply[w.substring(0, at)] = w.substring(at + 1); });
                root._bootApply = apply;
            }
            root._bootCheck();
        }
    }
    // The service's rule over the pretend boot set: stored, never applied.
    function _bootCheck() {
        const text = JSON.stringify(root._bootApply);
        const plan = Model.bootPlan(root.config, root._helperUp() ? root._shown() : null, { ok: true, apply: root._bootApply, chargeLimit: null });
        const d = Model.bootDecide(plan, text, root._bootLast, root._bootPatch !== null);
        root._bootLast = d.last;
        if (d.send) {
            root._bootPatch = plan.patch;
            bootWrite.restart();
        }
        if (root._boot.want !== plan.want || root._boot.state !== d.state || root._boot.why !== d.why)
            root._boot = { want: plan.want, state: d.state, why: d.why };
    }

    // An unkept dGPU-only wiring is put back when its deadline passes (the boot guard's job).
    Timer {
        interval: 1000
        repeat: true
        running: root._status.mux.record !== null && root._status.mux.record.state === "awaiting-keep"
        onTriggered: {
            const rec = root._status.mux.record;
            if (rec && rec.state === "awaiting-keep" && rec.deadlineMs !== null && Date.now() >= rec.deadlineMs) {
                const st = JSON.parse(JSON.stringify(root._status));
                st.mux.wiringNow = "hybrid";
                st.mux.stored = "hybrid";
                st.mux.record.state = "reverted";
                st.mux.record.why = "not kept in time";
                root._status = st;
                root._compute();
            }
        }
    }

    // ---- the timeline ------------------------------------------------------------------------------------------
    Timer {
        interval: root.tickMs
        repeat: true
        running: root.playing
        onTriggered: {
            root._ticking = true;
            root.timeMs = (root.timeMs + root.tickMs * root.speed) % TL.durationMs(root.scenario);
            root._ticking = false;
        }
    }
    onTimeMsChanged: root._step()
    onScenarioChanged: {
        root._pm = Pm.newState();
        root._prev = null;
        root._step();
    }

    // The timeline's pack with the machine knobs over it: the status follows the plug, the charge and
    // the limit as the firmware's does.
    function _batteryOf(b) {
        if (root.machinePct < 0 && root.machineAc === "")
            return b;
        const ac = root.machineAc === "" ? b.ac : root.machineAc === "on";
        const pct = root.machinePct < 0 ? b.pct : Math.max(0, Math.min(100, root.machinePct));
        const limit = root._status.values.chargeLimit;
        const status = !ac ? "Discharging"
            : pct >= 100 ? "Full"
            : typeof limit === "number" && limit < 100 && pct >= limit ? "Not charging" : "Charging";
        const w = status === "Charging" ? (b.status === "Charging" ? b.powerW : 45)
            : status === "Discharging" ? (b.status === "Discharging" ? b.powerW : 12) : 0;
        return { status: status, pct: pct, powerW: w, energyNowWh: root._fullWh * pct / 100, ac: ac };
    }

    // The timeline's dGPU with the machine knob over it.
    function _gpuOf(s) {
        if (root.machineDgpu === "")
            return s;
        const g = Object.assign({}, s);
        const busy = root.machineDgpu === "busy";
        // "stale": the card went to sleep and the list of its users has not been read since (the service reads it on a beat)
        const stale = root.machineDgpu === "stale";
        g.dState = root.machineDgpu === "asleep" || stale ? "D3cold" : "D0";
        g.holders = busy || stale ? (root.machineHolders || []).slice() : [];
        g.smi = busy ? { util: 78, tempC: 64, watts: 52.5, vramUsedMB: 4200, vramTotalMB: 8188 } : null;
        return g;
    }

    // Read the timeline at timeMs and say what changed since the last read: the events only for a
    // forward step of about one tick (a scrub or the loop's wrap fires nothing).
    function _step() {
        root._readings++;
        const t = root.timeMs;
        const s = root._gpuOf(TL.sample(root.scenario, t));
        const forward = root._prev !== null && t >= root._lastT && t - root._lastT <= root.tickMs * Math.max(1, root.speed) * 3 + 1;
        const b = root._batteryOf(s.battery);
        const limit = root._status.values.chargeLimit;
        const opts = { limitPct: typeof limit === "number" ? limit : 100, lowChargeThreshold: root.config.battery.lowAt };
        if (!forward)
            root._pm = Pm.newState();
        const r = Pm.step(root._pm, { status: b.status, pct: b.pct, ac: b.ac, powerNowW: b.powerW }, Date.now(), opts);
        if (forward) {
            r.events.forEach(function (kind) {
                if (kind === "full")
                    root._lastFullMs = Date.now();
                root.batteryEvent(kind);
            });
            if (r.acChanged !== null)
                root.acChanged(r.acChanged);
            if (s.dState !== root._lastD && root._lastD !== "")
                root.gpuPowerChanged(s.dState);
            TL.blocksBetween(root.scenario, root._lastT, t).forEach(function (e) {
                if (root._ignored.indexOf(e.id) < 0)
                    root.appBlocked({ id: e.id, comm: e.comm, appId: e.id, pid: e.pid, gpuId: 1, atMs: Date.now() });
            });
        }
        root._lastD = s.dState;
        root._lastT = t;
        root._sample = s;
        root._prev = s;
        root._compute();
    }

    // the timeline's memory facts, or the pinned one made into the same shape (memory { totalKiB, availableKiB, usedFraction })
    function _memoryFacts(timeline) {
        const o = root.memoryOverride;
        if (o === null || o === undefined)
            return timeline;
        const used = Math.max(0, Math.min(1, Number(o.usedFraction) || 0));
        const avail = Math.round(TL.MEM_TOTAL_KIB * (1 - used));
        return { totalKiB: TL.MEM_TOTAL_KIB, availableKiB: avail, usedFraction: (TL.MEM_TOTAL_KIB - avail) / TL.MEM_TOTAL_KIB };
    }

    function _compute() {
        const s = root._sample;
        if (s === null)
            return;
        const b = root._batteryOf(s.battery);
        const sample = { present: true, status: b.status, pct: b.pct, cycles: 197, energyNowWh: b.energyNowWh, energyFullWh: root._fullWh, energyFullDesignWh: 75, powerNowW: b.powerW, voltageNowV: 16.8 };
        const limit = root._status.values.chargeLimit;
        const opts = { limitPct: typeof limit === "number" ? limit : 100, lowChargeThreshold: root.config.battery.lowAt };
        // a FLOOR that raised nothing (the machine was at or above it) is no hold to caption
        const winner = PowerBus.heldProfile !== "" && (!PowerBus.heldIsFloor || holds.raised) ? PowerBus.holds[PowerBus.heldBy] : null;
        const hasHelper = root.helperPresent;
        const up = root._helperUp();
        const shown = up ? root._shown() : null;
        vm.build({
            nowMs: Date.now(), readingSerial: root._readings, readingMs: root.tickMs, config: root.config,
            helper: up ? { installed: true, ok: true, why: "" }
                : hasHelper ? { installed: true, ok: false, why: root._helperWhy }
                : { installed: false, ok: false, why: "the silicon helper is not installed (mock)" },
            status: shown,
            sensors: { clockMHz: s.clockMHz, loadPct: s.loadPct, tempC: s.tempC, cores: s.cores, igpuBusy: s.igpuBusy },
            cardwire: {
                present: root.cardwirePresent, why: "cardwire is not running (mock)", mode: root._mode, modes: root._modes,
                dState: s.dState, holders: s.holders, blocked: root._blocked,
                policies: CW.filterPolicies(root._allPolicies, root._blocked), config: root._cwConfig
            },
            smi: s.smi,
            battery: { sample: sample, figures: Pm.figures(root._pm, sample, opts), ac: b.ac, limitPct: limit },
            overheadW: 0.4, lastFullMs: root._lastFullMs,
            hold: winner ? { source: PowerBus.heldBy, profile: PowerBus.heldProfile, reason: winner.reason } : null,
            muxOutcomeSeenAt: root._outcomeSeenAt,
            ignoredApps: root._ignored,
            muxWindows: { bootS: root.bootWindowS, promptS: root.promptWindowS },
            afterMuxMode: root._afterMuxMode,
            memory: root._memoryFacts(s.memory),
            display: { hdmi: root.hdmiConnected }
        });
        root._afterMux();
        root._bootCheck();
    }

    // The service's rule (Model.afterMuxPlan, SiliconService._afterMux): the mode asked for with a way back from dGPU-only,
    // once the restart is over, is set through cardwire as a normal step is, ONCE, and forgotten.
    function _afterMux() {
        const p = Model.afterMuxPlan(root._afterMuxMode, vm.gpu, root._muxOp !== null || muxWrite.running);
        if (p.action === "clear") {
            root._afterMuxMode = null;
        } else if (p.action === "apply") {
            root._afterMuxMode = null;
            const plan = Model.planGpuMode(p.step, {}, vm.gpu, vm.gpuModeTarget);
            if (plan.action === "refuse")
                root.osd(Model.osdAfterMuxRefused(p.step, plan.why));
            root.setGpuMode(p.step, {});
        }
    }
    readonly property real _fullWh: 59.455

    Connections {
        target: PowerBus
        function onChanged() { root._compute(); }
    }

    // The panel's switches take effect at once, not at the next tick.
    onHelperPresentChanged: root._compute()
    onCardwirePresentChanged: root._compute()
    onHdmiConnectedChanged: root._compute()
    onHelperOkChanged: root._compute()
    onHiddenFeaturesChanged: root._compute()
    onMuxUnitActiveChanged: root._compute()
    on_AfterMuxModeChanged: root._compute()
    onBootWindowSChanged: root._compute()
    onPromptWindowSChanged: root._compute()
    // A machine knob is the machine changing: read it now (at the same time, so it is a forward step
    // and its events fire -- an AC change plugs and pulses, a wake reports the D-state).
    onMemoryOverrideChanged: root._compute()
    onMachinePctChanged: root._step()
    onMachineAcChanged: root._step()
    onMachineDgpuChanged: root._step()
    onMachineHoldersChanged: root._step()
    onConfigChanged: root._compute()

    Component.onCompleted: root._step()
}
