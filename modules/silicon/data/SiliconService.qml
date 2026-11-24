pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../../common/board"
import "../../common/components"
import "../../common/osd"
import "../../common/power"
import "../../common/system"
import "HelperProto.js" as Proto
import "SiliconModel.js" as Model
import "PowerMath.js" as Pm

// =============================================================================
// SiliconService.qml -- silicon's data layer over the real machine: the battery, the CPU's power
// profile and tuning, the GPU's mode. The contract is
// docs/contracts/silicon.md section 2; SiliconMock
// has the same members over the same SiliconViewModel.
//
// FACTS (plain objects, no colours): cpu, cores, igpu, gpu, memory, battery, helper, caption.
// TARGETS (what the scene animates to, in ITS order -- profile 0..2, GPU step 0 Integrated /
//   1 Smart / 2 Hybrid / 3 dGPU-only, charge limit 80|100): profileTarget, gpuModeTarget,
//   chargeLimitTarget; the actual state in the same orders: profileIndex, gpuMode.
// SIGNALS: batteryEvent(kind: full | low | chargeStart | chargeStop | chargeDone), acChanged(on),
//   gpuPowerChanged(dState), writeRefused(zone, why), appBlocked(app), osd(request).
// INTENTS: stepProfile(dir), setProfile(index), setTuning(patch), resetTuning(),
//   setChargeLimit(on), stepGpuMode(dir), setGpuMode(step, {confirmHolders}),
//   setCardwireConfig(key, value), setAppPolicy(app, allowed), ignoreApp(app),
//   muxRequest(want[, after]), muxRebootNow(), muxKeep(), muxCancel(), muxPromptShown(),
//   markMuxOutcomeSeen(); touch(), refresh().
//
// THE WAY BACK FROM dGPU-ONLY. While the panel is wired to the NVIDIA card all four steps are offered; a step
// left is a MUX request for Hybrid and the step wanted after the restart (`after`: Smart, Integrated, Hybrid) is
// remembered in SiliconState (`afterMuxMode`), because the restart ends this shell. The target keeps moving under the
// queued request (a re-aim asks the helper nothing), stepping back to dGPU-only cancels it, and once the laptop is back
// -- hybrid wiring, the record kept -- the mode is set through cardwire as a normal step is, ONCE, and forgotten
// (`Model.afterMuxPlan` decides from the facts, `_afterMux` carries it out at the end of every `_compute`).
//   THE LAST STEP ASKED FOR WINS. `afterMuxMode` is written where the user ASKS -- a request, a re-aim, a cancel --
//   and by nobody else: not by the helper's reply (the helper answers a request pkexec-slowly, and a user stepping
//   Hybrid -> Smart -> Integrated is faster than that: a reply that wrote the step its own request carried landed over the
//   newer re-aim), only cleared by `afterMuxPlan` when the facts say nothing is coming. The order of the replies is not
//   a thing the outcome depends on.
//
// WHERE EACH THING COMES FROM
//   facts    SysfsPoller's FileViews on the paths the helper's `status` names (a path it does not
//            report is a hidden feature); PowerMath for the battery; cardwire by busctl calls and ONE
//            gdbus monitor; nvidia-smi ONLY while the dGPU is awake and has a real user; the memory
//            from /proc/meminfo at the stats cadence; UPower's charge history (read-only, one gdbus
//            call: UpowerHistory) for "when the pack was last full".
//   SINCE FULL. The kernel has no such value. `battery.lastFullMs` is the LATER of the moment this service
//   recorded itself (the pack reaching its target, and the pack LEAVING it -- the last moment it was full -- seen
//   while the shell ran; SiliconState keeps it) and the one UPower's history gives (it covers the time the shell was
//   not running); while the pack IS at its target the display reads 0 (`battery.atTarget`).
//   writes   the helper through pkexec (HelperClient: ~300 ms settle, latest intent wins, one
//            Process at a time, a 10 s watchdog, the helper's read-back checked against what was
//            asked); cardwire through busctl set-property; `systemctl reboot` for the MUX.
//   A write the helper refuses, or whose read-back differs, ANIMATES THE TARGET BACK and puts
//   the reason in the zone's caption error; while a write is pending, external-change detection
//   is paused.
//
// AN EXTERNAL PROFILE CHANGE (made outside the popup: asusctl, a key) applies the new profile's
// linked values from silicon.jsonc, drops any hold (a manual change wins), and asks for an OSD --
// `OsdBus.show()` with a request of kind "power" (SiliconModel.osdProfile / osdGpu / osdLimit), a desktop
// notification only when it answers false (no OSD service, or the user routed the kind elsewhere). The
// same goes for cardwire's mode and the charge limit moved outside the popup.
//
// HOLDS (PowerBus). A hold switches to the held profile and remembers the one it left; a plain
// release switches back if nobody changed it meanwhile; a manual PROFILE change (the popup's, or an
// external one) drops every hold and nothing is restored. Tuning does not drop a hold.
//
// RESUME. Sleep.watcher's resume refreshes everything. Nothing is re-applied unless the helper's
// first status after it differs from the last one before it (the firmware reset something):
// then exactly the knobs that moved are put back.
//
// THE BOOT PROFILE (CONTRACT section 18). silicon.jsonc's `defaultProfile` is the profile the laptop COMES UP in: the
// named profile's linked values are STORED as the helper's boot set (`set-boot`; silicon-boot.service applies it early in every
// boot, before the login screen) -- whenever the stored set (`bootFile`, read on every status) is not what the config asks for,
// ONCE per difference (Model.bootDecide: a failure is `bootProfile.why` and one log line, never a retry per status). Nothing
// here ever APPLIES a profile: the profile in use stays until the user switches, and the next boot comes up in the stored one.
// No key stores nothing and clears nothing. `bootProfile` { want, state: off | waiting | storing | stored | failed, why }.
//
// THE FAN GUARD (FanGuard.qml; the 2026-11-13 stuck fans). Two parts. A RE-KICK after every resume (`_kickProfile`): the firmware's fan logic
// is re-programmed by writing the platform profile again -- another profile, a pause, this one back (HelperClient.queueKick: two plain `apply
// profile=` writes through the path the polkit rule already allows, so no root change). It is not a manual change (no hold is dropped, no OSD,
// the intermediate profile is never published), and whatever the firmware reset meanwhile is put back as a resume does (`_reapply`). And the
// GUARD: on the beat it judges the CPU temperature against what this machine normally reads at the load it has, and re-kicks once when it
// is hot for no reason the load explains, then, if that did not cure it, says so and holds Performance (PowerBus) until the CPU is below 75 degrees.
// Nothing here polls firmware: the guard reads the coretemp and the cores' cached files on the beat.
//
// IDLE LADDER (CONTRACT section 4 `idle.*`): `popupOpen` + `touch()` drive idleState (alive ->
// calm after idle.calmAfterMs -> halt after idle.haltAfterMs; closed is halt), and the readers'
// cadences follow it. The scene's frames follow the same state (SiliconClock); this is what is polled.
// =============================================================================
Item {
    id: root

    // ---- configuration -------------------------------------------------------------
    property string configPath:
        (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/quickshell/config/silicon.jsonc"
    property string statePath:
        (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/lares/silicon/state.json"
    // The old battery module's "last full" file, read ONCE to seed lastFullMs (never written).
    property string oldLastFullPath:
        (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/lares/battery/last-full"
    property string updateMarkerPath:
        (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/lares/system-update/last-run.json"
    property var helperStatusCommand: ["/usr/local/libexec/silicon-helper"]
    property var helperWriteCommand: ["pkexec", "/usr/local/libexec/silicon-helper"]
    property string cardwireBus: "system"
    property bool cardwireEnabled: true
    property string nvidiaSmi: "nvidia-smi"
    property string upowerGdbus: "gdbus"          // the one program that asks UPower (a probe's stub answers from a fixture)
    property bool upowerEnabled: true             // false: UPower is never asked
    property string procRoot: "/proc"
    property string drmRoot: "/sys/class/drm"        // the display connectors (the own DrmWatch's; a probe's fake one)
    property string usbRoot: "/sys/bus/usb/devices"  // the own DrmWatch's DisplayLink look (a probe's fake one)
    property string evdiModule: "/sys/module/evdi"
    // The shell's ONE DrmWatch (modules/common/system/DrmWatch.qml), handed in by the host; null builds the service's own.
    property var drm: null
    property string udevadm: "udevadm"               // the one long-lived watcher of drm events (a probe's stand-in feeds it)
    property bool displayEnabled: true               // false: the own DrmWatch reads nothing and display.hdmi stays false
    property bool powerEventsEnabled: true           // false: the power_supply udev monitor is never started (the battery is read on the beat only)
    property int powerEventGapMs: 1500               // the least time between two battery reads that udev events ask for
    property string systemctl: "systemctl"
    // The argv of the restart `muxRebootNow` runs, when the host has one that saves the session first (the reel's reboot:
    // `lares-session end reboot`, then `systemctl reboot`); null or empty: a bare `systemctl reboot`.
    property var rebootArgv: null
    property string notifySend: "notify-send"
    property var defaultPaths: ({ battery: "/sys/class/power_supply/BAT0", ac: "/sys/class/power_supply/AC0" })
    property int settleMs: 300
    property int helperTimeoutMs: 10000
    property int resumeWindowMs: 15000
    property bool persist: true
    property bool fanGuardEnabled: true
    readonly property bool _fanGuard: root.fanGuardEnabled && cfg.config.fans.guard
    property int fanSampleMs: 5000                  // the guard's reading, in whole beats (SiliconModel.cadence)
    property string thermalBaselinePath:
        (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/lares/silicon/thermal-baseline.json"
    property bool holdSystemUpdate: true
    // The helper's stored boot set (HelperProto.parseBootSet): read only while silicon.jsonc names a `defaultProfile`.
    property string bootFile: "/var/lib/silicon/boot.json"

    // The owner binds the popup's open state; the popup calls touch() on pointer activity.
    property bool popupOpen: false
    readonly property string idleState: ladder.level
    // the helper's status runs so far (its probe counts them: see `_cad`)
    readonly property int statusRuns: helperClient.statusRuns
    // the reading beat -- every reader runs on it; the probe reads its serial and cadence
    readonly property alias readingBeat: beat
    readonly property alias fanGuard: fan           // the guard (its probe reads and shortens it)
    readonly property int profileKicks: root._kickCount
    readonly property var cadence: root._cad
    // one line per reading a reader took: kind "stats" | "battery" | "smi" | "overhead" | "status" (a signal for the probe; nothing binds to it)
    signal polled(string kind)

    // ---- facts, targets ----------------------------------------------------------------
    readonly property int readingSerial: vm.readingSerial
    readonly property int readingMs: vm.readingMs
    readonly property double readingAtMs: vm.readingAtMs
    readonly property var cpu: vm.cpu
    readonly property var cores: vm.cores
    readonly property var igpu: vm.igpu
    readonly property var gpu: vm.gpu
    readonly property var memory: vm.memory
    readonly property var display: vm.display
    // for the probes (not part of the contract): what the display watcher has read, and whether its udev monitor is up
    readonly property var _drm: root.drm !== null ? root.drm : ownDrm
    readonly property int displayScans: root._drm.scans
    readonly property var displayConnectors: root._drm.connectors
    readonly property bool displayWatching: root._drm.watching
    // ... and the power watcher's: whether its udev monitor is up, how many battery reads its events asked for
    readonly property bool powerWatching: powerWatch.watching
    readonly property int powerEventPolls: root._powerPolls
    readonly property var battery: vm.battery
    readonly property var helper: vm.helper
    readonly property var caption: vm.caption
    readonly property var tuningTarget: vm.tuningTarget
    readonly property int profileTarget: vm.profileTarget
    readonly property int gpuModeTarget: vm.gpuModeTarget
    readonly property int chargeLimitTarget: vm.chargeLimitTarget
    readonly property int profileIndex: vm.profileIndex
    readonly property int gpuMode: vm.gpuMode
    readonly property var config: cfg.config
    readonly property var configWarnings: cfg.warnings
    readonly property string configError: cfg.lastError
    // { want: null | "quiet" | "balanced" | "performance", state: "off" | "waiting" | "storing" | "stored" | "failed", why }
    readonly property var bootProfile: root._boot

    signal batteryEvent(string kind)
    signal acChanged(bool on)
    signal gpuPowerChanged(string dState)
    signal writeRefused(string zone, string why)
    signal appBlocked(var app)
    signal osd(var request)

    // ---- intents: the CPU ----------------------------------------------------------------
    function stepProfile(dir) {
        if (!root._cpuReady())
            return root._refuse("cpu", root._cpuWhy());
        const to = Model.nextProfile(vm.profileTarget, dir, vm.cpu.profiles);
        if (to === null)
            return false;       // an end of the row: the chevron there is absent
        return root.setProfile(to);
    }

    function setProfile(index) {
        const name = Model.PROFILES[index];
        if (!root._cpuReady())
            return root._refuse("cpu", root._cpuWhy());
        if (name === undefined || vm.cpu.profiles.indexOf(name) < 0)
            return root._refuse("cpu", "That profile is not available");
        if (index === vm.profileTarget && !vm.cpu.tweaked)
            return false;
        root._manualProfile();
        return root._switchProfile(name);
    }

    // `patch`: any of { epp, turbo, governor, maxPerfPct, pl1W, pl2W }.
    function setTuning(patch) {
        if (!root._cpuReady())
            return root._refuse("cpu", root._cpuWhy());
        const merged = Object.assign({}, helperClient.applyPatch, patch);
        const v = Proto.validatePatch(merged, helperClient.status);
        if (!v.ok)
            return root._refuse("cpu", v.why);
        vm.clearError("cpu");
        vm.aimTuning(root._tuningOf(merged));
        helperClient.queueApply(patch);
        return true;
    }

    // Back to the profile's own linked values (a profile switch to the current one).
    function resetTuning() {
        if (!root._cpuReady())
            return root._refuse("cpu", root._cpuWhy());
        const name = vm.cpu.profile;
        if (name === "")
            return false;
        root._manualProfile();
        return root._switchProfile(name);
    }

    // ---- intents: the battery -----------------------------------------------------------------
    function setChargeLimit(on) {
        const f = helperClient.status ? helperClient.status.features : null;
        if (!helperClient.ok || !f || !f.chargeLimit)
            return root._refuse("battery", "The charge limit is not available on this machine");
        const pct = on ? 80 : 100;
        if (pct === vm.chargeLimitTarget)
            return false;
        vm.aim("battery", pct);
        root._limitAsked = root._limitAsked.concat([pct]);
        helperClient.queueChargeLimit(pct);
        return true;
    }

    // ---- intents: the GPU --------------------------------------------------------------------------
    function stepGpuMode(dir) {
        if (!vm.gpu.present)
            return root._refuse("gpu", "GPU modes need cardwire: " + vm.gpu.why);
        const to = Model.stepFrom(vm.gpuModeTarget, dir, vm.gpu.steps);
        if (to === null)
            return false;
        return root.setGpuMode(to, {});
    }

    // `step` is the scene's order (0 Integrated, 1 Smart, 2 Hybrid, 3 dGPU-only). Integrated and
    // Smart block the dGPU for NEW opens only; with apps on the card they ask for
    // `{ confirmHolders: true }` first (the popup lists them), and are refused without it.
    function setGpuMode(step, opts) {
        const plan = Model.planGpuMode(step, opts, vm.gpu, vm.gpuModeTarget);
        if (plan.action === "refuse")
            return root._refuse("gpu", plan.why);
        if (plan.action === "mux")
            return root.muxRequest(plan.want, plan.after);
        if (plan.action === "reaim") {
            // the way back is already queued: only where it ends up changes (the target follows the fact)
            vm.clearError("gpu");
            st.afterMuxMode = plan.after;
            return true;
        }
        if (plan.action === "none")
            return false;
        if (plan.action === "cancelmux") {
            // withdraw the queued dGPU-only request FIRST; the step is applied on the cancel's answer (_onWrote). A step
            // asked while the cancel is out replaces this one (the last wins) and asks nothing more of the helper.
            vm.aim("gpu", step);
            vm.clearError("gpu");
            const waiting = root._cancelThen !== null;
            root._cancelThen = { step: step, cw: plan.cw };
            if (waiting)
                return true;
            st.afterMuxMode = null;
            return helperClient.queueMux("cancel", "");
        }
        root._cancelThen = null;        // any other plan is the newer ask: the step waiting for a cancel's answer is dropped
        vm.aim("gpu", step);
        root._expectCw = plan.cw;
        cardwire.setMode(plan.cw);
        return true;
    }
    property var _cancelThen: null      // { step, cw }: the step to apply once the helper has withdrawn a queued dGPU-only request

    // The cancel's answer: the step asked with it goes to cardwire now (still the newest ask, or it was replaced/dropped above).
    function _afterCancel(r) {
        const then = root._cancelThen;
        root._cancelThen = null;
        if (then === null)
            return;
        if (!r.ok)
            return;                     // the helper's words are told by the caller; the target goes back with the fact
        root._osd(Model.osdMuxCancelled(then.step));
        root._expectCw = then.cw;
        cardwire.setMode(then.cw);
    }

    // `key`: batteryAutoSwitch | batteryAutoSwitchMode | externalDisplayAutoSwitch | nvidiaBlock.
    function setCardwireConfig(key, value) {
        if (!vm.gpu.present)
            return root._refuse("gpu", "GPU settings need cardwire: " + vm.gpu.why);
        vm.clearError("gpu");
        cardwire.setConfig(key, value);
        return true;
    }

    function setAppPolicy(app, allowed) {
        if (!vm.gpu.present)
            return root._refuse("gpu", "App policies need cardwire: " + vm.gpu.why);
        vm.clearError("gpu");
        cardwire.setPolicy(app, allowed);
        return true;
    }

    function ignoreApp(app) {
        st.ignore(app);
    }

    // ---- intents: the MUX -------------------------------------------------------------------------------
    // `want`: "dgpu" | "hybrid"; `after` (a way back only): the step wanted once the laptop is back, 0 Integrated,
    // 1 Smart, 2 Hybrid (the default), kept in SiliconState when the helper has taken the request. Nothing is
    // written to the firmware here: the helper records the request, after pre-checks of its own -- for dGPU-only
    // that nvidia is loaded and a DKMS module is built for every installed kernel, and for BOTH directions that
    // silicon-mux.service is active (it is what writes a queued change, so a change queued while it is not would
    // never be written) -- and that unit applies it at shutdown. The switch TO dGPU-only is written with the NVIDIA stack down or not at all; the way back is
    // written with the driver loaded if need be (the user's way out waits for nothing). A request the helper
    // refuses is not judged here: the target aims, the helper's words come back (`writeRefused`, the GPU
    // caption's error) and the target goes back; `gpu.mux.prechecks` carries what the dGPU direction would meet.
    function muxRequest(want, after) {
        const f = helperClient.status ? helperClient.status.features : null;
        if (!helperClient.ok || !f || !f.mux)
            return root._refuse("mux", "The MUX switch is not available on this machine");
        const step = want === "dgpu" ? Model.STEP.DGPU : (after === 0 || after === 1 || after === 2 ? after : Model.STEP.HYBRID);
        vm.aim("gpu", step);
        // Written NOW, where it is asked, and before the request is queued (`_afterMux` keeps it while a write is on its way).
        // A dGPU-only request takes the way back's mode with it.
        st.afterMuxMode = want === "dgpu" ? null : step;
        helperClient.queueMux("request", want);
        return true;
    }

    // Restart now, for a MUX request that waits for one. Never otherwise. The restart ends this shell: what the user asked
    // for after the way back (`afterMuxMode`) is on disk before it is asked, not 300 ms after the last step.
    function muxRebootNow() {
        if (vm.gpu.mux.state !== "queued")
            return root._refuse("mux", "No restart is waiting for a MUX change");
        st.flush();
        rebootLane.run(root.rebootArgv instanceof Array && root.rebootArgv.length > 0 ? root.rebootArgv : [root.systemctl, "reboot"], function (res) {
            if (res.code !== 0)
                root._refuse("mux", "The restart was not accepted" + (res.err.trim() !== "" ? ": " + res.err.trim().split("\n")[0] : ""));
        });
        return true;
    }

    function muxKeep() { return helperClient.queueMux("confirm", ""); }
    function muxCancel() {
        st.afterMuxMode = null;         // the request is withdrawn, and so is the mode that rode with it
        return helperClient.queueMux("cancel", "");
    }
    function muxPromptShown() { return helperClient.queueMux("promptShown", ""); }

    function markMuxOutcomeSeen() {
        const rec = helperClient.status ? helperClient.status.mux.record : null;
        if (rec && typeof rec.requestedAtMs === "number")
            st.muxOutcomeSeenAt = rec.requestedAtMs;
    }

    // ---- lifecycle ---------------------------------------------------------------------------------
    // Pointer activity in the open popup: the ladder goes back to alive.
    function touch() {
        ladder.touch();
    }

    // Everything again, now: the helper's status, cardwire, the battery and (open) the stats. A resume
    // and an explicit call; a popup opening asks for less (cardwire's signals have kept the rest).
    function refresh() {
        helperClient.refreshStatus();
        cardwire.refresh();
        poller.pollBattery();
        root._drm.rescan();
        if (root.upowerEnabled)
            upower.refresh(true);
        if (root.popupOpen)
            poller.pollStats();
    }

    // =====================================================================================
    // Private
    // =====================================================================================
    property var _paths: ({})
    property var _sensors: ({ clockMHz: null, loadPct: null, tempC: null, cores: [], igpuBusy: null })
    property var _sample: null
    property var _figures: null
    property var _ac: null
    property var _limitPct: null
    property var _limitAsked: []        // the limits THIS popup asked for and has not seen land: an own write is not news
    property string _dState: ""
    property string _sysDState: ""
    property var _lastStatus: null
    property var _preSleep: null
    property real _resumeUntil: 0
    // Inside the window after a resume whatever moved is the firmware's doing: put back, not news.
    function _resuming() { return root._resumeUntil > Date.now() && root._preSleep !== null; }
    property var _expectCw: null
    property int _lastCwMode: -2
    property bool _changeQueued: false
    property var _memory: null          // /proc/meminfo as SysfsParse.parseMeminfo reads it, or null
    property var _warned: ({})
    readonly property var _pm: Pm.newState()
    // How long "Charging with nothing flowing" lasts before the battery is called stalled (PowerMath.stalled). null: PowerMath's
    // own 30 s; the service probe shortens it.
    property var stallMs: null
    property var _atTarget: null        // whether the last sample had the pack at its target (null: no sample yet)
    // The battery's sysfs path as the poller reads it: the helper's, else the default.
    readonly property string _batteryPath: root._paths && typeof root._paths.battery === "string" && root._paths.battery !== ""
        ? root._paths.battery : root.defaultPaths.battery

    // `status` is the helper's whole report: a process, a fresh walk of the machine and a read of the GPU MUX through the ASUS
    // firmware (an ACPI method into the embedded controller). Asking it every 2 s while the popup is open is more than anything needs, and the EC of this
    // laptop once wedged while it did (no proof that was the cause). Outside changes are seen through
    // the kernel's own copies instead (SysfsPoller's knobs, every battery poll); a full status is asked at start, on opening,
    // on a resume, when a knob moved, after silicon's own changes (their replies carry it), and else once a minute open,
    // every five minutes closed.
    //
    // ONE BEAT FOR EVERY READER. `_cad` is `Model.cadence`: the beat's period and, for each reader, every how
    // many beats it reads (0 = not at all). A reader fires on a beat whose serial is a multiple of its count, so the slow
    // ones land ON a fast beat and the figures that change together are read together; opening the popup restarts the beat
    // (beat 0 reads everything at once). A change of period keeps the serial running.
    // (A beat is judged by `_cadNow()`, never by `_cad`: opening restarts the beat from a change handler, which runs before the
    // binding that follows the change.)
    readonly property var _cad: root._cadNow()
    function _cadNow() { return Model.cadence(ladder.level, root.popupOpen, ladder, root.fanSampleMs); }

    ReadingBeat {
        id: beat
        baseMs: root._cad.baseMs
        onBeat: serial => root._onBeat(serial)
    }
    function _onBeat(serial) {
        if (!root._ready)
            return;
        const c = root._cadNow();
        if (c.battery > 0 && serial % c.battery === 0)
            poller.pollBattery();
        if (c.stats > 0 && serial % c.stats === 0) {
            poller.pollStats();
            smi.poll();
        }
        if (c.overhead > 0 && serial % c.overhead === 0)
            meter.poll();
        if (root._fanGuard && c.guard > 0 && serial % c.guard === 0)
            fan.sample();
        if (c.status > 0 && serial % c.status === 0)
            helperClient.refreshStatus();
        // The bar's card shows the dGPU in use with the popup shut, and no signal says who opened a node. Only while the card is awake (asleep it
        // has nobody: this forks nothing at rest) and not when it is wired as the display, where nothing here depends on the list.
        if (!root.popupOpen && root._dState === "D0" && vm.gpu.wiring !== "dgpu")
            cardwire.refreshHolders();
    }

    SiliconConfig { id: cfg; configPath: root.configPath }
    SiliconState { id: st; statePath: root.statePath; persist: root.persist }
    SiliconViewModel { id: vm }

    HelperClient {
        id: helperClient
        statusCommand: root.helperStatusCommand
        writeCommand: root.helperWriteCommand
        settleMs: root.settleMs
        timeoutMs: root.helperTimeoutMs
        onStatusRead: (status, fromWrite) => root._onStatus(status, fromWrite)
        onStatusFailed: { root._changed(); root._bootSoon(); }
        onWrote: result => root._onWrote(result)
    }

    CardwireClient {
        id: cardwire
        bus: root.cardwireBus
        active: root.cardwireEnabled
        nodes: root._dgpuNodes
        ignoredHolders: cfg.config.gpu.ignoredHolders
        pci: root._dgpuPci
        onChanged: root._onCardwire()
        onPowerChanged: dState => root._setDState(dState)
        onAppBlocked: entry => {
            if (st.ignoredApps.indexOf(entry.id) < 0)
                root.appBlocked(entry);
        }
        onWrote: result => root._onCardwireWrote(result)
    }

    SysfsPoller {
        id: poller
        paths: root._paths
        defaults: root.defaultPaths
        procRoot: root.procRoot
        statsActive: root._cad.stats > 0
        onStatsRead: sample => { root.polled("stats"); root._onStats(sample); }
        onBatteryRead: sample => { root.polled("battery"); root._onBattery(sample); }
        onKnobsRead: key => root._onKnobs(key)
    }
    // An outside change (or silicon's own, whose reply already carried the status: one status more, harmless) moved a
    // knob the kernel keeps: ask the helper for the whole picture. The first key only seeds.
    property string _knobsKey: ""
    function _onKnobs(key) {
        const seen = root._knobsKey;
        root._knobsKey = key;
        if (seen !== "" && key !== seen)
            helperClient.refreshStatus();
    }

    NvidiaSmi {
        id: smi
        command: root.nvidiaSmi
        // The ONE condition under which nvidia-smi may run: the card is awake, something is using
        // it, and somebody is looking.
        active: root.popupOpen && cardwire.holders.length > 0 && root._dState === "D0"
        onReadingChanged: root._changed()
        onRead: root.polled("smi")
    }

    OverheadMeter {
        id: meter
        active: root.popupOpen
        reader: poller
        wPerCpuSec: cfg.config.overhead.wPerCpuSec
        wPerGpuSec: cfg.config.overhead.wPerGpuSec
        onSampled: { root.polled("overhead"); root._changed(); }
    }

    Loader {
        active: root.holdSystemUpdate
        sourceComponent: SystemUpdateHold {
            on: cfg.config.holds.systemUpdate !== null
            profile: cfg.config.holds.systemUpdate ?? "performance"
            markerPath: root.updateMarkerPath
            procRoot: root.procRoot
        }
    }

    DesktopNotifier {
        id: notifier
        appName: "Silicon"
        keys: ["silicon-osd", "fan-guard"]
        notifySend: root.notifySend
    }

    ProcLane { id: rebootLane; timeoutMs: 15000 }

    // An external display on the NVIDIA card's HDMI connector. Read at start, on udev drm events, when the GPU mode moves and on a resume.
    DrmWatch {
        id: ownDrm
        enabled: root.displayEnabled && root.drm === null
        drmRoot: root.drmRoot
        usbRoot: root.usbRoot
        evdiModule: root.evdiModule
        udevadm: root.udevadm
        systemctl: root.systemctl
    }
    Connections {
        target: root._drm
        function onChanged() {
            root._changed();
        }
    }

    // A POWER EVENT IS A BATTERY READ NOW: the charge glyph must answer a plug without a significant delay. The
    // beat reads the battery every 6 s with the popup closed, and the kernel's status follows a plug by a second or two on top;
    // udev says when the mains or the pack changed, and one read answers it -- the EC is asked when the thing moves, not faster
    // (CLAUDE.md, the EC rule). At most one read per `powerEventGapMs`: an event inside the gap is answered when the gap ends
    // (the second event of a plug -- the pack's status after the adapter's -- is exactly that), so a burst is one read and
    // a chatty battery driver cannot become a 1 Hz poll.
    PowerEventWatcher {
        id: powerWatch
        enabled: root.powerEventsEnabled && root._ready
        udevadm: root.udevadm
        onChanged: root._onPowerEvent()
    }
    property int _powerPolls: 0
    property double _powerPollAt: 0
    function _onPowerEvent() {
        if (!root._ready)
            return;
        const wait = root._powerPollAt + root.powerEventGapMs - Date.now();
        if (wait > 0) {
            powerTrail.interval = Math.max(1, Math.ceil(wait));
            powerTrail.restart();
            return;
        }
        root._powerPoll();
    }
    function _powerPoll() {
        root._powerPollAt = Date.now();
        root._powerPolls++;
        poller.pollBattery();
    }
    Timer { id: powerTrail; onTriggered: root._powerPoll() }

    UpowerHistory {
        id: upower
        gdbus: root.upowerGdbus
        batteryPath: root.upowerEnabled ? root._batteryPath : ""
        popupOpen: root.upowerEnabled && root.popupOpen
        onChanged: root._changed()
    }

    FileView {
        id: oldLastFull
        path: root.oldLastFullPath
        blockLoading: true
        blockWrites: true
        printErrors: false
    }

    readonly property var _dgpuNodes: {
        const d = root._paths ? root._paths.dgpu : null;
        const out = [];
        if (d)
            [d.card, d.render, d.nvidia].forEach(function (p) { if (typeof p === "string" && p !== "") out.push(p); });
        return out;
    }
    readonly property string _dgpuPci: root._paths && root._paths.dgpu && typeof root._paths.dgpu.pci === "string" ? root._paths.dgpu.pci : ""
    // Who holds the card is read from ITS nodes, which are known only once the helper has answered -- and cardwire's first look
    // can come before that, with no nodes to read (no answer is no holders), after which nothing asks again until the popup opens.
    // Asked again the moment the nodes are known, so `holders` is a fact and not a race: the mode wanted after a way back from
    // dGPU-only is judged by it at the next login. (Deferred: the client's own `nodes` follows this one.)
    on_DgpuNodesChanged: {
        if (root._dgpuNodes.length > 0)
            Qt.callLater(cardwire.refreshHolders);
    }

    // ---- inputs -> facts -------------------------------------------------------------------------------
    function _changed() {
        if (root._changeQueued)
            return;
        root._changeQueued = true;
        Qt.callLater(root._compute);
    }

    function _compute() {
        root._changeQueued = false;
        // a FLOOR that raised nothing (the machine was at or above it) is no hold to caption
        const winner = PowerBus.heldProfile !== "" && (!PowerBus.heldIsFloor || holds.raised) ? PowerBus.holds[PowerBus.heldBy] : null;
        vm.build({
            nowMs: Date.now(),
            readingSerial: beat.serial,
            readingMs: beat.baseMs,
            config: cfg.config,
            helper: { installed: helperClient.installed, ok: helperClient.ok, why: helperClient.why, answered: helperClient.answered },
            status: helperClient.status,
            sensors: root._sensors,
            cardwire: {
                present: cardwire.present, asked: cardwire.settled, why: cardwire.why, mode: cardwire.mode >= 0 ? cardwire.mode : null,
                modes: cardwire.modes, dState: root._dState, holders: cardwire.holders, blocked: cardwire.blocked,
                policies: cardwire.policies, config: cardwire.config
            },
            smi: smi.reading,
            battery: { sample: root._sample, figures: root._figures, ac: root._ac, limitPct: root._limitPct },
            overheadW: meter.overheadW,
            lastFullMs: st.lastFullMs,
            upower: { ms: upower.lastFullMs, ok: upower.ok, why: upower.why },
            hold: winner ? { source: PowerBus.heldBy, profile: PowerBus.heldProfile, reason: winner.reason } : null,
            muxOutcomeSeenAt: st.muxOutcomeSeenAt,
            ignoredApps: st.ignoredApps,
            afterMuxMode: st.afterMuxMode,
            memory: root._memory,
            display: { hdmi: root.displayEnabled && root._drm.nvidiaHdmi }
        });
        root._afterMux();
    }

    // The mode asked for with a way back from dGPU-only, once that restart is over (Model.afterMuxPlan says when, from the
    // facts just built): set through cardwire as a normal step is -- the holders rule included -- ONCE, and forgotten. A step
    // that is refused is told in the GPU caption and as a pill (nobody is looking at login) and is not asked again: the
    // user can ask for it themselves.
    function _afterMux() {
        const p = Model.afterMuxPlan(st.afterMuxMode, vm.gpu, helperClient.pending);
        if (p.action === "clear") {
            st.afterMuxMode = null;
        } else if (p.action === "apply") {
            st.afterMuxMode = null;
            const plan = Model.planGpuMode(p.step, {}, vm.gpu, vm.gpuModeTarget);
            if (plan.action === "refuse")
                root._osd(Model.osdAfterMuxRefused(p.step, plan.why));
            root.setGpuMode(p.step, {});
        }
    }

    function _setDState(d) {
        if (d === "" || d === root._dState)
            return;
        root._dState = d;
        root.gpuPowerChanged(d);
        // Who holds it is a fact of the card's state, popup or none: the bar lights the card on it (`gpu.inUse`). A power event is rare and asks once.
        cardwire.refreshHolders();
        root._changed();
    }

    function _onStats(s) {
        const old = root._sensors;
        if (s.memory !== null)
            root._memory = s.memory;
        root._sensors = {
            clockMHz: s.clockMHz !== null ? s.clockMHz : old.clockMHz,
            loadPct: s.loadPct !== null ? s.loadPct : old.loadPct,
            tempC: s.tempC !== null ? s.tempC : old.tempC,
            // `s.cores` crossed a signal inside an object: on Qt 6.12 it arrives as a list WRAPPER, not a JS array
            // (Array.isArray false, .length and indexing fine), and the model's `Array.isArray(sens.cores)` would then
            // build NO cores, so the popup would show no per-core load. Copy it into a real array here.
            cores: s.cores.length > 0 ? Array.prototype.slice.call(s.cores) : old.cores,
            igpuBusy: s.igpuBusy !== null ? s.igpuBusy : old.igpuBusy
        };
        // The card's state: cardwire PUSHES it (its signal), sysfs is the same truth read by poll. A
        // sample that has not changed since the last one says nothing new and never overrules a signal
        // that came between; it decides alone when cardwire is not there.
        if (s.dState !== "" && (!cardwire.present || s.dState !== root._sysDState))
            root._setDState(s.dState);
        root._sysDState = s.dState;
        if (root.popupOpen)
            cardwire.refreshHolders();
        root._changed();
    }

    function _onBattery(s) {
        const sample = Pm.parseUevent(s.uevent);
        const prevLimit = root._limitPct;
        root._ac = s.ac;
        root._limitPct = s.limitPct;
        if (sample === null) {
            root._sample = null;
            root._figures = null;
            root._atTarget = null;
            root._changed();
            return;
        }
        const opts = { limitPct: s.limitPct !== null ? s.limitPct : 100, stallMs: root.stallMs, lowChargeThreshold: cfg.config.battery.lowAt };
        const r = Pm.step(root._pm, { status: sample.status, pct: sample.pct, ac: s.ac, powerNowW: sample.powerNowW }, Date.now(), opts);
        root._sample = sample;
        root._figures = Pm.figures(root._pm, sample, opts);
        // The pack has just stopped being full (unplugged, or charging again below the limit): this is the last moment
        // it was, and what "since full" counts from. (Reaching the target is the `full` event below.)
        const at = Pm.atTarget(sample, opts);
        if (root._atTarget === true && !at)
            st.lastFullMs = Date.now();
        root._atTarget = at;
        r.events.forEach(function (kind) {
            if (kind === "full")
                st.lastFullMs = Date.now();
            // UPower writes the point of a pack that has become full (or stopped charging) a moment before this poll sees it
            if ((kind === "full" || kind === "chargeStop" || kind === "chargeDone") && root.upowerEnabled)
                upower.refreshSoon();
            root.batteryEvent(kind);
        });
        if (r.acChanged !== null)
            root.acChanged(r.acChanged);
        // A limit that moved and is not the one this popup asked for was set outside it.
        if (prevLimit !== null && s.limitPct !== null && s.limitPct !== prevLimit) {
            const own = root._limitAsked.indexOf(s.limitPct);
            if (own >= 0)
                root._limitAsked = root._limitAsked.slice(own + 1);     // it landed, and so did everything asked before it
            else if (!root._resuming())
                root._osd(Model.osdLimit(s.limitPct));
        }
        root._changed();
    }

    // ---- the helper's status: facts, paths, external changes ---------------------------------------
    function _onStatus(status, fromWrite) {
        const prev = root._lastStatus;
        root._lastStatus = status;
        if (JSON.stringify(status.paths) !== JSON.stringify(root._paths))
            root._paths = status.paths;
        if (!fromWrite && prev !== null && !helperClient.pending) {
            if (root._resuming()) {
                root._resumeUntil = 0;
                const gone = Proto.changedKnobs(root._preSleep, status);
                if (gone.length > 0)
                    root._reapply(root._preSleep, gone);
                root._preSleep = null;
            } else {
                const moved = Proto.changedKnobs(prev, status);
                if (moved.indexOf("profile") >= 0)
                    root._onExternalProfile(status);
            }
        }
        root._changed();
        root._bootSoon();
    }

    // The profile moved and this popup did not do it.
    function _onExternalProfile(status) {
        const name = status.values.profile;
        if (Model.PROFILES.indexOf(name) < 0)
            return;
        root._manualProfile();
        const lp = Model.linkedPatch(cfg.config, name, status);
        root._noteOnce(name, lp.notes);
        const patch = root._pruned(lp.patch, status);
        if (Object.keys(patch).length > 0)
            helperClient.replaceApply(patch);
        root._osd(Model.osdProfile(name));
    }

    // Put the knobs that the firmware changed across a resume back where they were.
    function _reapply(before, moved) {
        const v = before.values;
        const patch = {};
        moved.forEach(function (k) {
            if (k === "chargeLimit") {
                if (typeof v.chargeLimit === "number" && (v.chargeLimit === 80 || v.chargeLimit === 100)) {
                    root._limitAsked = root._limitAsked.concat([v.chargeLimit]);     // landing again is not news
                    helperClient.queueChargeLimit(v.chargeLimit);
                }
            } else if (k === "pl1W" || k === "pl2W") {
                if (v.caps && typeof v.caps[k] === "number")
                    patch[k] = v.caps[k];
            } else if (v[k] !== undefined && v[k] !== null && v[k] !== "mixed") {
                patch[k] = v[k];
            }
        });
        if (Object.keys(patch).length > 0)
            helperClient.queueApply(patch);
    }

    // What of `patch` the machine does not already have.
    function _pruned(patch, status) {
        const v = status.values;
        const caps = v.caps || {};
        const ceil = status.limits.capCeilW;
        const out = {};
        Object.keys(patch).forEach(function (k) {
            let live = v[k];
            let want = patch[k];
            if (k === "pl1W" || k === "pl2W") {
                live = caps[k];
                if (want === "firmware")
                    want = ceil ? ceil[k === "pl1W" ? "pl1" : "pl2"] : want;
                if (typeof live === "number" && typeof want === "number" && Math.abs(live - want) <= 0.5)
                    return;
            }
            if (live !== want)
                out[k] = patch[k];
        });
        return out;
    }

    function _noteOnce(profile, notes) {
        notes.forEach(function (n) {
            const key = profile + ": " + n;
            if (root._warned[key])
                return;
            root._warned[key] = true;
            console.warn("SiliconService: " + profile + " profile: " + n + " (silicon.jsonc), left out");
        });
    }

    // ---- profile switching -------------------------------------------------------------------------------------
    function _cpuReady() {
        return helperClient.ok && helperClient.status !== null && helperClient.status.features.profile;
    }

    function _cpuWhy() {
        return helperClient.installed
            ? "Power control is unavailable: " + helperClient.why
            : "Power profiles need the silicon helper, which is not installed";
    }

    // A manual profile change: every hold is dropped, nothing is restored.
    function _manualProfile() {
        PowerBus.dropAll("manual");
    }

    // Aim at a profile and send its linked values (a profile switch ends every tweak).
    function _switchProfile(name) {
        const lp = Model.linkedPatch(cfg.config, name, helperClient.status);
        root._noteOnce(name, lp.notes);
        const v = Proto.validatePatch(lp.patch, helperClient.status);
        if (!v.ok)
            return root._refuse("cpu", v.why);
        vm.aim("cpu", Model.profileIndex(name));
        vm.aimTuning(root._tuningOf(lp.patch));
        helperClient.replaceApply(lp.patch);
        return true;
    }

    function _tuningOf(patch) {
        const t = Object.assign({}, patch);
        delete t.profile;
        return t;
    }

    // ---- holds: the rule is HoldFollower's, shared with the mock ---------------------------------------------------
    HoldFollower {
        id: holds
        current: Model.PROFILES[vm.profileTarget]
        ready: helperClient.ok && helperClient.status !== null && helperClient.status.features.profile
        onSwitchRequested: name => root._switchProfile(name)
    }
    Connections {
        target: PowerBus
        function onChanged() { root._changed(); }
    }

    // ---- the profile by power (silicon.jsonc onPower) ----------------------------------------------------------------------
    // The PLUG switches and nothing else does: not the start (the first reading of the mains says nothing), not a resume (a plug in the
    // resume window, where the profile from before the sleep is put back, waits for its end). While a hold has raised the profile the plug
    // changes what comes back after it. A profile picked by hand stays until the next plug.
    onAcChanged: on => root._onPlug(on)
    function _onPlug(on) {
        if (root._resuming()) {
            plugLater.restart();
            return;
        }
        const name = on ? cfg.config.onPower.ac : cfg.config.onPower.battery;
        if (name === null || !root._cpuReady() || vm.cpu.profiles.indexOf(name) < 0 || holds.rebase(name))
            return;
        if (Model.PROFILES[vm.profileTarget] === name || !root._switchProfile(name))
            return;
        root._osd(Model.osdProfile(name));
        Qt.callLater(holds.follow);             // a floor that held the machine where it was holds it above this one too
    }
    Timer {
        id: plugLater
        interval: root.resumeWindowMs + 500
        onTriggered: root._onPlug(root._ac === true)
    }

    // ---- the fan guard and the re-kick ----------------------------------------------------------------------------------
    FanGuard {
        id: fan
        reader: poller
        profile: vm.cpu.profile
        ready: root._fanGuard && root._ready && helperClient.ok && helperClient.status !== null && helperClient.status.features.profile
        persist: root.persist
        statePath: root.thermalBaselinePath
        onKickRequested: why => { root._kickTries = 0; root._kickProfile(why); }
        onAlarm: info => root._fanAlarm(info)
    }

    property int _kickCount: 0              // kicks that went to the helper (the probe counts them)
    property var _kickBefore: null          // the status before a kick: what the firmware changed meanwhile is put back
    property int _kickTries: 0
    property string _kickWhy: ""
    Timer {
        id: kickRetry
        interval: 3000
        onTriggered: root._kickProfile(root._kickWhy)
    }

    // The profile the kick goes through: the neighbour with the least effect for the second or two it is there.
    function _kickVia(cur) {
        const have = vm.cpu.profiles;
        if (cur !== "balanced")
            return have.indexOf("balanced") >= 0 ? "balanced" : "";
        return have.indexOf("quiet") >= 0 ? "quiet" : (have.indexOf("performance") >= 0 ? "performance" : "");
    }

    // Re-program the firmware's fan logic by writing the platform profile again. Waits (3 s, five times) for a write of the user's or
    // a hold's to finish, never queues behind or between them.
    function _kickProfile(why) {
        if (!root._cpuReady())
            return;
        const cur = helperClient.status.values.profile;
        if (Model.PROFILES.indexOf(cur) < 0)
            return;                         // "custom": a mix of profiles, nothing to put back
        if (helperClient.pending) {
            root._kickWhy = why;
            if (root._kickTries++ < 5)
                kickRetry.restart();
            return;
        }
        const via = root._kickVia(cur);
        if (via === "")
            return;
        root._kickBefore = helperClient.status;
        if (helperClient.queueKick(cur, via)) {
            root._kickCount++;
            console.info("SiliconService: re-kicking the platform profile (" + why + "): " + cur + " via " + via);
        }
    }

    function _fanAlarm(info) {
        const t = Math.round(info.tempC);
        const usual = info.hasBaseline ? "usually reads " + Math.round(info.expectedC) + " °C" : "should not read above 95 °C";
        notifier.notify("fan-guard", {
            title: "The fans look stuck",
            body: "The CPU is at " + t + " °C at a load that " + usual + " (" + Math.round(info.loadPct) + " % of full speed). Performance is held to spin them up; your "
                  + info.profile + " profile comes back when the CPU is below " + info.releaseC + " °C.",
            urgency: "critical"
        });
    }

    // ---- write results ---------------------------------------------------------------------------------------------
    function _refuse(zone, why) {
        vm.fail(zone === "mux" ? "gpu" : zone, why);
        root.writeRefused(zone, why);
        return false;
    }

    function _onWrote(r) {
        // A write's end settles ITS zone's target, and only when nothing newer of that zone waits: a
        // profile step and the DIP switch in one breath are two writes, and neither strands the other.
        if (r.kind === "apply") {
            const newer = helperClient.applyPending;
            if (r.ok) {
                if (!newer)
                    vm.settle("cpu");
            } else {
                vm.fail("cpu", r.why, newer);
                root.writeRefused("cpu", r.why);
            }
        } else if (r.kind === "kick") {
            // nothing on screen moves. The way back is what counts: what the firmware reset meanwhile is put back (as after a resume),
            // and a way back that failed leaves the profile at the one the kick went through, so the normal switch puts it right
            if (r.step === "back" && r.ok) {
                const gone = Proto.changedKnobs(root._kickBefore, r.status);
                if (gone.length > 0)
                    root._reapply(root._kickBefore, gone);
            } else if (r.step === "back") {
                console.info("SiliconService: the kick could not put the profile back (" + r.why + "): switching to " + r.patch.profile);
                root._switchProfile(r.patch.profile);
            } else if (!r.ok) {
                console.info("SiliconService: the kick was refused (" + r.why + ")");
            }
        } else if (r.kind === "chargeLimit") {
            const newer = helperClient.limitPending;
            if (r.ok) {
                poller.pollBattery();       // the move lands, and is known as ours, before the ask is forgotten
                if (!newer)
                    vm.settle("battery");
            } else {
                vm.fail("battery", r.why, newer);
                root.writeRefused("battery", r.why);
            }
            root._limitAsked = newer ? root._limitAsked.filter(function (v) { return v !== r.patch.chargeLimit; }) : [];
        } else if (r.kind === "boot") {
            // nothing on screen moves: the boot set is for the next boot. A failure is the boot profile's why, said once.
            if (r.ok) {
                console.info("SiliconService: the boot profile " + r.patch.profile + " is stored: the next boot comes up in it");
            } else if (root._bootLast !== null) {
                root._bootLast = { memo: root._bootLast.memo, why: r.why !== "" ? r.why : "the helper refused the boot set" };
                console.warn("SiliconService: the boot profile " + r.patch.profile + " was not stored: " + root._bootLast.why);
            }
            root._bootSoon();
        } else if (r.kind === "mux") {
            // (the mode asked for after the way back is the user's ask, written where it was made: a reply does not touch it)
            // a cancel that carries a step: cardwire's answer settles the target, not this one (the target would fall back to the old mode between)
            const chained = r.op === "cancel" && r.ok && root._cancelThen !== null;
            if (r.op === "cancel")
                root._afterCancel(r);
            if (r.ok) {
                if (!chained)
                    vm.settle("gpu");
            } else {
                vm.fail("gpu", r.why);
                root.writeRefused("mux", r.why);
            }
        }
        root._changed();
    }

    // cardwire's Mode moved: ours (this popup asked for it) or somebody else's (`cardwire set` in
    // a terminal, its own battery auto-switch) -- the latter is shown like any change made outside.
    function _onCardwire() {
        const m = cardwire.mode;
        if (m >= 0 && root._lastCwMode !== m) {
            const first = root._lastCwMode === -2;
            root._lastCwMode = m;
            if (root._expectCw === m)
                root._expectCw = null;          // ours: asked for here, consumed once
            else if (!first)
                root._osd(Model.osdGpu(Model.stepOf(m, vm.gpu.wiring)));
            if (!first)
                root._drm.rescan();      // the card's connectors come and go with the mode (nvidia_drm has the card or does not); the first reading is not a change
        }
        root._changed();
    }

    function _onCardwireWrote(r) {
        if (r.kind === "mode") {
            if (r.ok) {
                vm.settle("gpu");
            } else {
                root._expectCw = null;
                vm.fail("gpu", r.why);
                root.writeRefused("gpu", r.why);
            }
        } else if (!r.ok) {
            vm.fail("gpu", r.why);
            root.writeRefused("gpu", r.why);
        }
        root._changed();
    }

    // ---- the boot profile -------------------------------------------------------------------------------------------
    // Stored, never applied: Model.bootPlan says what `defaultProfile` asks the boot set to hold, Model.bootDecide whether to ask now.
    property var _boot: ({ want: null, state: "off", why: "" })
    property var _bootLast: null        // the last set-boot asked: { memo, why } (Model.bootDecide)
    property bool _bootQueued: false
    Loader {
        id: bootSet
        active: cfg.config.defaultProfile !== null
        sourceComponent: FileView {
            path: root.bootFile
            blockLoading: true
            blockAllReads: true
            blockWrites: true
            printErrors: false
        }
    }
    function _bootSoon() {
        if (root._bootQueued)
            return;
        root._bootQueued = true;
        Qt.callLater(root._bootCheck);
    }
    function _bootCheck() {
        root._bootQueued = false;
        if (!root._ready)
            return;
        let text = "";
        if (bootSet.item) {
            bootSet.item.reload();
            text = bootSet.item.text();
        }
        const plan = Model.bootPlan(cfg.config, helperClient.ok ? helperClient.status : null, Proto.parseBootSet(text));
        if (plan.notes.length > 0)
            root._noteOnce(plan.want, plan.notes);
        const d = Model.bootDecide(plan, text, root._bootLast, helperClient.bootPending);
        root._bootLast = d.last;
        if (d.fresh)
            console.warn("SiliconService: the boot profile " + plan.want + " was not stored: " + d.why);
        if (d.send)
            helperClient.queueBoot(plan.patch);
        if (root._boot.want !== plan.want || root._boot.state !== d.state || root._boot.why !== d.why)
            root._boot = { want: plan.want, state: d.state, why: d.why };
    }

    // ---- OSD ---------------------------------------------------------------------------------------------------------------
    function _osd(req) {
        root.osd(req);
        if (!OsdBus.show(req))
            notifier.notify("silicon-osd", { title: req.title, body: req.detail, timeoutMs: 3000 });
    }

    // ---- sleep ----------------------------------------------------------------------------------------------------------------
    Connections {
        target: Sleep.watcher
        function onResumed() {
            root._resumeUntil = Date.now() + root.resumeWindowMs;
            root._preSleep = root._lastStatus;
            root.refresh();
            fan.resumed(root.fanGuardEnabled && cfg.config.fans.resumeKick);
        }
    }

    // ---- the idle ladder: alive -> calm -> halt, and what is polled follows it ---------------------------------------------------
    // The popup's idle ladder: its four times are the module's constants (IdleLadder), which the silicon mockup tunes through this.
    readonly property alias idleLadder: ladder
    IdleLadder {
        id: ladder
        open: root.popupOpen
    }

    // `popupOpen` may be true from the very start (an initial value): its change handler then runs while the object is still
    // being built, and asks cardwire through a client whose bus has not been set yet (one call to the DEFAULT bus, the system
    // one). Whatever opens at construction is read by Component.onCompleted instead.
    property bool _ready: false
    onPopupOpenChanged: {
        if (!root.popupOpen || !root._ready)
            return;
        cardwire.refreshLive();
        beat.restart();         // beat 0: the status, the battery and the stats at once
    }

    Connections {
        target: cfg
        function onConfigChanged() { root._changed(); root._bootSoon(); }
    }

    Connections {
        target: st
        function onLastFullMsChanged() { root._changed(); }
        function onMuxOutcomeSeenAtChanged() { root._changed(); }
        function onIgnoredAppsChanged() { root._changed(); }
        function onAfterMuxModeChanged() { root._changed(); }
    }

    Component.onCompleted: {
        cfg.ensureLoaded();
        st.ensureLoaded();
        root._seedLastFull();
        cardwire.start();
        if (root.upowerEnabled)
            upower.refresh(true);
        root._changed();
        root._ready = true;
        beat.restart();         // beat 0: the status and the battery, and the stats when the popup starts open
    }

    // The old battery module kept "when it last reached full" in a plain file; adopt it once.
    function _seedLastFull() {
        if (st.lastFullMs > 0)
            return;
        const v = parseInt(oldLastFull.text(), 10);
        if (!isNaN(v) && v > 0)
            st.lastFullMs = v;
    }
}
