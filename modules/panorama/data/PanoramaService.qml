pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "PanoramaModel.js" as Model
import "PanoramaStaging.js" as Staging

// =============================================================================
// PanoramaService.qml -- the displays, as the popup and the glyph see them (docs/contracts/panorama.md section 4). ONE per shell
// (ShellServices). PanoramaMock.qml has the same surface for the mockup and the probes.
//
// WHO DOES WHAT. Hyprland applies the setups itself (tools/panorama/engine.lua inside the generated panorama.lua: a plug, an
// unplug, a reload). This service:
// - reads what is there (FocusedScreen.outputs + DrmWatch's connectors);
// - holds the store (setups.json);
// - keeps the engine's copy in step (EngineLink: the generated file + `hyprctl eval`);
// - stages the popup's edits;
// - runs a trial and its keep toast;
// - tells the user about a never-seen display, an unplug, and what is wrong.
//
// THE KEEP FLOW (decision 7):
// 1. apply() sends the staged data to the engine as a TRIAL (`panorama.try`): the engine applies it, verifies it at +1.5 s
//    (a mismatch reverts there, at once), and arms a guard of its own.
// 2. The phase is `awaiting` once the engine says `trying`, and PanoramaKeepPrompt posts the toast.
// 3. The toast tells us when it is ON THE GLASS (`markShown`): the countdown starts there (keepSeconds), and the engine's
//    guard is re-armed to the same span plus a grace.
// 4. Keep (a click only) writes the store and the file; the timeout, Escape, Revert or a failed trial puts the previous data back AND
//    drops the staged edit: after a revert the popup shows what is in force, never a picture of what did not hold (the keep toast is the
//    one place that says a revert happened).
//
// NOTHING IS WRITTEN WHILE THE ENGINE IS MISSING. Before the user's `lares panorama-import` (their step: it edits their
// Hyprland config) the popup is read-only and says so; the service records no display and posts no never-seen toast.
// =============================================================================
Item {
    id: root

    // ---- inputs ----
    property bool live: false
    property var focusSource: null           // FocusedScreen (outputs, outputsChanged, refresh); `focus` is FINAL on an Item
    property var drm: null                   // DrmWatch (connectors, displayLinkUsb, ...)
    property var silicon: null               // SiliconService (gpuMode 0 = Integrated, gpu.known)
    property var notifier: null              // DesktopNotifier
    property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/lares"
    property string runtimeDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/lares"
    property string configPath: ""
    property string hyprDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/hypr"
    property string engineSource: ""
    property bool popupOpen: false
    // the toasts may be posted: the session is unlocked and the shell is on screen (the host binds it)
    property bool ready: true

    // the cast service (CastService; ShellServices builds ONE and hands it over; null: no casting). Casting is OFF unless panorama.jsonc says
    // `"cast": true` AND the engine answers AND there is a cast service (docs/contracts/panorama.md section 10)
    property var cast: null

    signal openRequested(string name)

    // ---- cast (section 10) ----
    readonly property bool castEnabled: config.settings.cast === true && root.cast !== null && link.stateName === "active"
    // every device the scan found ({ id, name, protocol, capable, note }); the popup shows the capable ones
    readonly property var castDevices: root.castEnabled && root.cast ? (root.cast.devices || []) : []
    readonly property string castState: root.cast ? root.cast.state : "idle"
    readonly property string castDevice: root.cast ? root.cast.device : ""
    readonly property var castFailure: root.cast ? root.cast.failure : null
    readonly property var castMode: root.cast ? root.cast.mode : null
    // idle | opening | starting | streaming | stopping | restarting  (CastKeeper: the ORDER of a cast)
    readonly property string castPhase: castKeeper.phase
    readonly property string castOutput: castKeeper.outputName
    // the device the keeper is on (from the click to the end), "" when no cast is going on
    readonly property string castActiveDevice: castKeeper.device
    // a cast is going on, from the click to the end (the idle auto layer's cause: the screen is being shared)
    readonly property bool castActive: castKeeper.phase !== "idle"
    // it is being made or made again, the stream not up (the bar's glyph: its hover hue and its flourish over and over)
    readonly property bool castWorking: root.castEnabled && castKeeper.working
    // the stream's figures (CastStats: null unless a shower holds them)
    readonly property var castStats: root.cast ? root.cast.stats : null
    function castHoldStats(): void {
        if (root.cast)
            root.cast.holdStats();
    }
    function castReleaseStats(): void {
        if (root.cast)
            root.cast.releaseStats();
    }
    readonly property var castNotice: castKeeper.notice
    readonly property bool castScanning: root.cast ? root.cast.scanning : false
    function castStatusText(deviceId: string): string {
        return castKeeper.statusText(deviceId);
    }
    function castNoticeFor(deviceId: string): string {
        return castKeeper.noticeFor(deviceId);
    }
    // the TV's name for a cast identity (`cast:<device id>`), "" when the scan has not seen it
    function castNameOf(ident: string): string {
        const id = String(ident).slice(5);
        const d = (root.cast ? root.cast.devices || [] : []).find(x => x.id === id);
        return d ? d.name : "";
    }
    function castStart(deviceId: string): bool {
        return castKeeper.start(deviceId);
    }
    // a click on a chip whose notice stands: the notice goes
    function castDismissNotice(): void {
        castKeeper.dismissNotice();
    }
    // the cast has no output of its own: it mirrors the laptop (the TV is then the stand-in display Staging.CAST_STANDIN)
    readonly property bool castMirrored: castKeeper.virtual
    // the name the cast's display goes by in `displays` and the plan: its output, or the stand-in while it mirrors
    readonly property string castDisplayName: castKeeper.virtual ? Staging.CAST_STANDIN : castKeeper.outputName
    // Mirror the laptop on the TV, or give the TV a display of its own. NO TRIAL (like the quality: a cast is the user's click and stopping
    // it is the revert): the TV's setup is stored and the keeper restarts the stream ONCE in its other shape -- a mirror has no output.
    function castSetMirror(on: bool): void {
        const ident = castKeeper.identity;
        if (ident === "" || root.castDisplayName === "" || root._internalName() === "")
            return;
        const d = Staging.castSetup(store.doc, root._plan, ident, root._autoName(), Math.floor(Date.now() / 1000), sp => {
            sp.mirror = on === true;
            sp.enabled = true;
        });
        if (d === null)
            return;
        root.discard();
        root._commitData(d);
    }
    function castStop(): void {
        castKeeper.stop();
    }
    // the stored quality of a cast display (resolution, fps, bitrate, audio), defaults filled
    function castQualityOf(name: string): var {
        const sp = root._plan.specs[name];
        return Staging.castQuality(sp && sp.cast ? sp.cast : {}, root.settings.castQuality);
    }
    // Save the quality in the cast display's setup and restart the stream ONCE with it (the detail's "Apply to stream")
    function castApplyQuality(q: var): void {
        const name = root.castDisplayName, ident = castKeeper.identity;
        if (name === "" || ident === "")
            return;
        const d = Staging.castSetup(store.doc, root._plan, ident, root._autoName(), Math.floor(Date.now() / 1000), sp => {
            sp.cast = { res: q.res, fps: q.fps, bitrate: q.bitrate, audio: q.audio !== false };
        });
        if (d === null)
            return;
        if (!d.displays[ident])
            d.displays[ident] = { label: root._labelOf(name), custom: false, internal: false, port: name, placeholder: false };
        root._commitData(d);
        castKeeper.restart(q);
    }

    // ---- outputs (contract section 4) ----
    readonly property var displays: root._displays
    readonly property var plan: root._plan
    readonly property string setKey: root._plan.setKey
    readonly property bool setupSaved: !!(root.store.doc.setups || {})[root._plan.setKey]
    readonly property string setupName: root.setupSaved ? (root.store.doc.setups[root._plan.setKey].name || root._autoName()) : ""
    readonly property var setups: root._setupList(root.store.serial, root._plan.setKey)
    readonly property var staged: root._staged
    readonly property var stagedSplit: root._stagedSplit
    // ONE read for the workspace chips: workspace -> display identity, the staged one while an edit is staged, else the one in force
    readonly property var splitIdents: root._stagedSplit !== null ? root._stagedSplit : Staging.splitIdents(root._plan)
    readonly property bool dirty: root._isDirty(root._staged, root._stagedSplit, root._plan)
    readonly property string phase: root._phase
    readonly property var trial: root._trial
    readonly property var diagnostics: root._diagnostics
    readonly property string identify: root._identify
    readonly property int panes: root._panes
    readonly property bool mirroring: root._mirroring
    readonly property string engineState: link.stateName
    readonly property string engineWhy: link.why
    readonly property var settings: config.settings
    // the engine's link (a probe writes its state to stand in for the engine's answers)
    readonly property var engineLink: link
    // the parts a probe reaches: the cast keeper (its calls to the engine are its signals) and the config (apply(obj) in place of a file)
    readonly property alias castKeeper: castKeeper
    readonly property alias configObject: config

    // ---- methods ----
    function stage(): void {
        if (root._staged !== null)
            return;
        root._stagedFor = root._plan.setKey;
        root._staged = Staging.stagedFrom(root._plan);
        // the split as it is IN FORCE (resolved, complete), never the store's partial one: a chip already in force is no change
        root._stagedSplit = Staging.splitIdents(root._plan);
        root._relations = Staging.relationsOf(root._staged, root._outputs);
        if (root._phase === "idle")
            root._phase = "staged";
    }

    // The default arrangement of the live set, as if it had never been seen (the model's defaults for these outputs): staged, so the user
    // can Apply or Discard it. When the trial is kept the stored setup is simply overwritten.
    function stageReset(): void {
        if (root._phase !== "idle" && root._phase !== "staged")
            return;
        const r = Staging.resetEdit(root._outputs);
        root._stagedFor = root._plan.setKey;
        root._staged = r.staged;
        root._stagedSplit = r.split;
        root._relations = Staging.relationsOf(root._staged, root._outputs);
        root._phase = "staged";
    }

    function stageMove(name: string, x: int, y: int): void {
        root.stage();
        const r = Staging.patchSpec(root._staged, name, { position: [x, y] }, root._outputs, root._relations);
        root._staged = r.staged;
        // a drag is the user's word on how the tiles sit: the relations are read from the picture it left
        root._relations = Staging.relationsOf(root._staged, root._outputs);
    }

    // A change of a tile's size (mode, scale, rotation, on / off, mirror) re-places the layout from the relations taken when the edit began
    // (or at the last drag), so a change and its undo leave the layout where it was (PanoramaLayout.relayout).
    function stageSpec(name: string, patch: var): void {
        root.stage();
        const r = Staging.patchSpec(root._staged, name, patch, root._outputs, root._relations);
        root._staged = r.staged;
        if (!r.sizes && patch.position !== undefined)
            root._relations = Staging.relationsOf(root._staged, root._outputs);
    }

    // Workspace `ws` onto `ident`; a click on the display it is already on gives it back to the internal one.
    function stageSplit(ws: string, ident: string): void {
        root.stage();
        root._stagedSplit = Staging.toggleSplit(root._stagedSplit, ws, ident, root._plan);
    }

    function discard(): void {
        root._staged = null;
        root._stagedSplit = null;
        root._relations = null;
        if (root._phase === "staged")
            root._phase = "idle";
    }

    function apply(): bool {
        if (root._staged === null || link.stateName !== "active" || (root._phase !== "staged" && root._phase !== "idle"))
            return false;
        const cand = root._candidate();
        const token = "t" + Date.now();
        root._trial = { token: token, deadlineMs: 0, totalMs: config.settings.keepSeconds * 1000, verdict: "" };
        root._pending = cand;
        root._phase = "applying";
        link.tryCandidate(cand, token);
        applyGuard.restart();
        return true;
    }

    // The keep toast is on the glass: the countdown runs from here (decision 18) and the engine's guard follows it.
    function markShown(): void {
        if (root._phase !== "awaiting" || root._trial.deadlineMs > 0)
            return;
        const total = config.settings.keepSeconds * 1000;
        const t = JSON.parse(JSON.stringify(root._trial));
        t.deadlineMs = Date.now() + total;
        t.totalMs = total;
        root._trial = t;
        // the engine reverts by itself 2 s after the toast's own countdown (panorama.jsonc keepSeconds; a fixed 17 s cut a longer one short)
        link.shown(t.token, total + 2000);
        countdown.interval = total;
        countdown.restart();
    }

    function keep(): void {
        if (root._phase !== "awaiting")
            return;
        countdown.stop();
        root._phase = "keeping";
        link.keep(root._trial.token);
        const cand = root._pending;
        root._pending = null;
        root.store.write(cand);
        link.writeFile(cand);
        root._staged = null;
        root._stagedSplit = null;
        root._relations = null;
        root._trial = { token: "", deadlineMs: 0, totalMs: 0, verdict: "" };
        root._phase = "idle";
    }

    function revert(): void {
        root._revert();
    }

    function renameSetup(key: string, name: string): void {
        const d = JSON.parse(JSON.stringify(root.store.doc));
        if (!d.setups[key])
            return;
        const n = String(name || "").trim();
        d.setups[key].name = n;
        d.setups[key].custom = n !== "";
        root._commitData(d);
    }

    function forgetSetup(key: string): void {
        const d = JSON.parse(JSON.stringify(root.store.doc));
        if (!d.setups[key])
            return;
        delete d.setups[key];
        root._commitData(d);
    }

    function setIdentify(name: string): void {
        root._identify = String(name || "");
    }

    // ---- the OSD's brightness keys and the popup's slider (round 2, stream A3) ----
    // The OSD acts on the display under the pointer; every EXTERNAL is a "ddc" target and its ddcState says the rest ("ok", "probing",
    // "unsupported", "failing" + ddcReason): the keys never step the laptop's backlight for an external. DdcClient looks at the outputs by
    // itself (outputs below), so a display is known before the first key.
    readonly property bool ddcDetected: ddc.detected
    function brightnessTarget(screenName: string): var {
        if (screenName === "" || Model.isInternal(screenName))
            return { kind: "panel", connector: "", label: "" };
        if (Model.isCast(screenName))
            return { kind: "none", connector: "", label: "" };
        return { kind: "ddc", connector: screenName, label: root._labelOf(screenName) };
    }
    function ddcEnsure(): void {
        ddc.ensureDetected();
    }
    function ddcDetect(): void {
        ddc.ensureDetected();
    }
    function ddcValue(name: string): int {
        return ddc.value(name);
    }
    function ddcGoal(name: string): int {
        return ddc.goal(name);
    }
    function ddcMax(name: string): int {
        return ddc.max(name);
    }
    function ddcPending(name: string): bool {
        return ddc.pending(name);
    }
    function ddcState(name: string): string {
        return ddc.stateOf(name);
    }
    function ddcReason(name: string): string {
        return ddc.reasonOf(name);
    }
    function ddcRead(name: string): void {
        ddc.read(name, true);
    }
    // false: the display cannot take it (no DDC, a failure remembered); a step with the value still unknown is kept, not refused
    function ddcAdjust(name: string, delta: int): bool {
        return ddc.adjust(name, delta);
    }
    function ddcSet(name: string, value: int): void {
        ddc.set(name, value);
    }
    // the idle dim's (modules/idle/DdcDim.qml): who can be asked, who it is whatever the connector, whether a call is out, one more try now
    function ddcNames(): var {
        return ddc.names();
    }
    function ddcKey(name: string): string {
        return ddc.keyOf(name);
    }
    function ddcBusy(name: string): bool {
        return ddc.busy(name);
    }
    function ddcForgive(name: string): void {
        ddc.forgive(name);
    }
    // a slider being dragged: written at rest (250 ms) or at ddcCommit
    function ddcScrub(name: string, value: int): void {
        ddc.scrub(name, value);
    }
    function ddcCommit(name: string): void {
        ddc.commit(name);
    }
    signal ddcChanged(string name)

    // ---- the popup's brightness slider ----
    // `panel`: the OSD service (it owns the laptop panel's backlight; ShellServices hands it over; null in a mockup)
    // { capable, value (0..1, -1 unknown), pending (a goal is out, or the display is being looked for), reason (words when not capable) }.
    // Bump-read `brightnessRev` first in a binding: it moves whenever any answer does.
    property var panel: null
    readonly property int brightnessRev: root._brightRev
    function brightnessOf(name: string): var {
        root._brightRev;
        if (name === "" || Model.isInternal(name)) {
            if (root.panel === null)
                return { capable: false, value: -1, pending: false, reason: "The laptop panel's brightness is on its keys." };
            const p = root.panel.panelBrightness();
            return { capable: p.capable, value: p.value, pending: false, reason: p.capable ? "" : "No backlight found." };
        }
        if (Model.isCast(name))
            return { capable: false, value: -1, pending: false, reason: "A cast display has no brightness." };
        const st = ddc.stateOf(name);
        if (ddc.capable(name) && st !== "failing" && st !== "unsupported") {
            const g = ddc.goal(name);
            return { capable: true, value: g < 0 ? -1 : Math.max(0, Math.min(1, g / ddc.max(name))), pending: g < 0 || ddc.pending(name), reason: "" };
        }
        if (root.live && (st === "unknown" || st === "probing"))
            return { capable: false, value: -1, pending: true, reason: "Looking for DDC." };
        return { capable: false, value: -1, pending: false, reason: ddc.reasonOf(name) || "This display takes no brightness over DDC." };
    }
    // while the hand moves: the figure follows at once, the write goes out at rest or at commitBrightness (the release)
    function setBrightness(name: string, v01: real): void {
        const v = Math.max(0, Math.min(1, v01));
        if (name === "" || Model.isInternal(name)) {
            if (root.panel !== null)
                root.panel.setPanelBrightness(v);
        } else {
            ddc.scrub(name, Math.round(v * ddc.max(name)));
        }
    }
    function commitBrightness(name: string): void {
        if (name !== "" && !Model.isInternal(name))
            ddc.commit(name);
    }

    function enableOutput(name: string): void {
        root.stage();
        if (root._staged[name]) {
            root.stageSpec(name, { enabled: true });
            root.apply();
        }
    }

    // The never-seen toast's buttons (decision 3): a trial each, with the keep toast.
    function quick(kind: string, name: string): void {
        if (root._phase !== "idle" && root._phase !== "staged")
            return;
        // both are of the laptop's panel: without one there is nothing to mirror and nothing to switch off
        const internal = root._internalName();
        if (internal === "")
            return;
        root.discard();
        root.stage();
        if (kind === "mirror" && name !== "" && root._staged[name])
            root.stageSpec(name, { mirror: true });
        else if (kind === "external" && internal !== "")
            root.stageSpec(internal, { enabled: false });
        else
            return;
        root.apply();
    }

    // ---- the parts ----
    readonly property alias store: store
    PanoramaStore {
        id: store
        live: root.live
        path: root.stateDir + "/panorama/setups.json"
    }
    PanoramaConfig {
        id: config
        live: root.live
        configPath: root.configPath
    }
    EngineLink {
        id: link
        live: root.live
        hyprDir: root.hyprDir
        runtimeDir: root.runtimeDir
        engineSource: root.engineSource
    }
    DdcClient {
        id: ddc
        live: root.live
        drm: root.drm
        outputs: root._outputs
        onValueChanged: connector => {
            root._ddcRev++;
            root._brightRev++;
            root.ddcChanged(connector);
        }
        onDetectedChanged: {
            root._brightRev++;
            if (ddc.detected)
                root.ddcChanged("");
        }
    }
    // the keep toast (the host routes Escape to keepPrompt.revert() while keepPrompt.waiting)
    readonly property alias keepPrompt: keepPrompt
    PanoramaKeepPrompt {
        id: keepPrompt
        service: root
        ready: root.ready
    }

    // the cast keeper: the ORDER of a cast (open the output, wait for it, stream it, close it once)
    CastKeeper {
        id: castKeeper
        cast: root.cast
        armed: root.castEnabled
        defaultQuality: root.settings.castQuality
        popupOpen: root.popupOpen
        // (the outputs there really are: the keeper waits for the cast's own one, which the stand-in hides from the display list)
        outputs: root._realOutputs
        castMap: root._castMap
        plan: root._plan
        mirrorWanted: ident => Staging.castMirrorStored(root._realOutputs, root.store.doc, ident)
        onOpenOutput: identity => link.castOpen(identity)
        // (the outputs are read again once the engine has had the time to remove it: no tile outlives its output on a missed event)
        onCloseOutput: name => {
            link.castClose(name);
            reread.restart();
        }
        onKeepNames: names => link.castKeep(names)
    }

    // ---- private state ----
    Timer {
        id: reread
        interval: 1200
        onTriggered: if (root.focusSource) root.focusSource.refresh()
    }
    property var _castMap: ({})
    // the listed outputs that have no display (the engine's `gone`)
    property var _gone: []
    // AN EDIT BELONGS TO THE SET IT WAS MADE IN: staged specs are keyed by connector, so one left standing through a plug, an unplug or a
    // cast was written into whatever set was live at Apply (how a display came to be stored "off" that nobody switched off there)
    property string _stagedFor: ""
    on_PlanChanged: {
        if (root._staged !== null && root._stagedFor !== root._plan.setKey && (root._phase === "staged" || root._phase === "idle"))
            root.discard();
        // what is new, what went away (below)
        seen.restart();
    }
    property var _staged: null
    property var _stagedSplit: null
    property string _phase: "idle"
    property var _trial: ({ token: "", deadlineMs: 0, totalMs: 0, verdict: "" })
    property var _pending: null
    property var _relations: null            // PanoramaLayout.relationsOf of the staged layout (opaque): taken at stage() and after each drag
    property int _brightRev: 0
    property string _identify: ""
    property int _ddcRev: 0
    property real _now: Date.now()
    // a COUNTING instrument must not be a property a binding reads: the session's told sets live in a var
    property var _told: ({ fresh: {}, diag: {}, present: null, gone: {} })

    readonly property var _realOutputs: root._withDrivers(root.focusSource ? root.focusSource.outputs : [], root.drm ? root.drm.connectors : [])
    // (a cast that mirrors has no output: the TV's stand-in record joins the list)
    readonly property var _outputs: castKeeper.virtual ? Staging.withStandIn(root._realOutputs, castKeeper.identity) : root._realOutputs
    readonly property var _plan: Model.resolve(root._outputs, root.store.doc)
    readonly property var _displays: root._displayList(root._outputs, root._plan, root.store.serial, root._ddcRev)
    readonly property int _panes: root._outputs.filter(o => !Model.isIgnored(o.name) && o.enabled !== false && !o.mirrorOf).length
    readonly property bool _mirroring: root._outputs.some(o => !Model.isIgnored(o.name) && !!o.mirrorOf)
    readonly property var _diagnostics: Model.diagnose({
        now: root._now, outputs: root._outputs, plan: root._plan,
        drm: root.drm ? { connectors: (root.drm.connectors || []).filter(c => root._gone.indexOf(c.name) < 0), displayLinkUsb: root.drm.displayLinkUsb,
                          displayLinkSince: root.drm.displayLinkSince, evdiLoaded: root.drm.evdiLoaded,
                          displayLinkActive: root.drm.displayLinkActive } : {},
        connectedSince: root.drm && root.drm.connectedSince ? root.drm.connectedSince : {},
        gpuMode: root.silicon && root.silicon.gpu && root.silicon.gpu.known && root.silicon.gpuMode === 0 ? "integrated" : "",
        verdict: root._trial.verdict
    })

    function _withDrivers(outs: var, conns: var): var {
        const drv = {}, gone = {};
        for (let i = 0; i < (conns || []).length; i++) {
            drv[conns[i].name] = conns[i].driver || "";
            gone[conns[i].name] = conns[i].status === "disconnected";
        }
        const res = [];
        for (let j = 0; j < (outs || []).length; j++) {
            // a nested Hyprland's host window (backend "wayland"): never a display, as the engine's reader says (FACTS.md E5)
            if (outs[j].backend === "wayland")
                continue;
            // a cast-named output no cast has is a leftover the engine sweeps, not a display (the engine's reader says the same)
            if (Model.isCast(outs[j].name) && !root._castMap[outs[j].name])
                continue;
            // Hyprland keeps a switched-off output listed while its cable is out: with the kernel saying the connector is empty it is no display
            if (outs[j].enabled === false && gone[outs[j].name] === true)
                continue;
            // ... and one the engine's cable watch says has no display (the NVIDIA driver keeps a pulled HDMI "connected")
            if (root._gone.indexOf(outs[j].name) >= 0)
                continue;
            const o = Object.assign({}, outs[j]);
            if (!o.driver)
                o.driver = drv[o.name] || "";
            if (root._castMap[o.name])
                o.castId = root._castMap[o.name];
            res.push(o);
        }
        return res;
    }

    function _labelOf(name: string): string {
        const d = root._displays.find(x => x.name === name);
        return d ? d.label : name;
    }

    function _internalName(): string {
        const o = root._outputs.find(x => Model.isInternal(x.name));
        return o ? o.name : "";
    }

    function _displayList(outs: var, plan: var, serial: int, ddcRev: int): var {
        const auto = Model.labels(outs, config.settings.portLabels);
        const known = store.doc.displays || {};
        const res = [];
        for (let i = 0; i < outs.length; i++) {
            const o = outs[i];
            if (Model.isIgnored(o.name))
                continue;
            const ident = plan.ids[o.name];
            const rec = known[ident];
            const d = Object.assign({}, o);
            d.ident = ident;
            d.internal = Model.isInternal(o.name);
            d.kind = Model.portKind(o.name, o.driver);
            d.cast = Model.isCast(o.name);
            d.label = rec && rec.custom && rec.label ? rec.label : ((d.cast && root.castNameOf(ident) !== "") ? root.castNameOf(ident) : (auto[o.name] || o.name));
            d.ddc = { capable: ddc.capable(o.name), value: ddc.value(o.name), max: ddc.max(o.name), busy: ddc.busy(o.name), state: ddc.stateOf(o.name) };
            res.push(d);
        }
        return res;
    }

    function _autoName(): string {
        const ds = root._displays.slice(0);
        ds.sort((a, b) => (a.internal !== b.internal) ? (a.internal ? -1 : 1) : (a.x - b.x));
        return ds.map(d => d.label).join(" + ");
    }

    function _setupList(serial: int, liveKey: string): var {
        const setups = store.doc.setups || {}, displays = store.doc.displays || {};
        const res = [];
        for (const key in setups) {
            const st = setups[key];
            const labels = key.split(" + ").map(id => (displays[id] && displays[id].label) || id);
            res.push({ key: key, name: st.name || labels.join(" + "), custom: !!st.custom, used: st.used || 0,
                       live: key === liveKey, labels: labels });
        }
        res.sort((a, b) => (a.live !== b.live) ? (a.live ? -1 : 1) : (b.used - a.used));
        return res;
    }

    function _isDirty(staged: var, split: var, plan: var): bool {
        return Staging.isDirty(staged, split, plan);
    }

    // The data the trial asks for: this set's setup from the staged specs, every present display recorded, the split merged.
    function _candidate(): var {
        const d = JSON.parse(JSON.stringify(store.doc));
        d.v = 1;
        d.displays = d.displays || {};
        d.setups = d.setups || {};
        d.split = d.split || {};
        const outputs = {};
        for (let i = 0; i < root._displays.length; i++) {
            const disp = root._displays[i];
            const rec = d.displays[disp.ident] || {};
            d.displays[disp.ident] = { label: rec.custom ? rec.label : disp.label, custom: !!rec.custom, internal: disp.internal,
                                       port: disp.name, placeholder: false };
            if (root._staged[disp.name])
                outputs[disp.ident] = root._staged[disp.name];
        }
        const old = d.setups[root._plan.setKey] || {};
        d.setups[root._plan.setKey] = { name: old.custom ? old.name : root._autoName(), custom: !!old.custom,
                                        used: Math.floor(Date.now() / 1000), outputs: outputs };
        // only what differs from the defaults is kept of the split (the whole map when that would not reproduce the edit)
        d.split = Staging.splitForStore(d.split, root._staged, root._stagedSplit, root._outputs);
        return d;
    }

    // A change of the data outside a trial (rename, forget, a display seen for the first time, a placeholder bound).
    function _commitData(d: var): void {
        root.store.write(d);
        if (link.stateName === "active") {
            link.writeFile(d);
            link.reloadData(d);
        }
    }

    // After ANY revert (the toast's button, Escape, the timeout, the engine's "failed") the staged edit goes with it: what the popup
    // shows is what is in force again, re-read from the compositor, never a picture of what did not hold.
    function _revert(): void {
        if (root._phase !== "awaiting" && root._phase !== "applying")
            return;
        countdown.stop();
        applyGuard.stop();
        root._phase = "reverting";
        link.revert(root._trial.token);
        root._pending = null;
        root._staged = null;
        root._stagedSplit = null;
        root._relations = null;
        root._phase = "idle";
        if (root.focusSource)
            root.focusSource.refresh();
    }

    // ---- the engine's word ----
    Connections {
        target: link
        function onStateChanged() {
            root._onEngineState();
        }
    }
    function _onEngineState(): void {
        const st = link.state || {};
        const cm = st.cast && st.cast.outputs ? st.cast.outputs : {};
        if (JSON.stringify(cm) !== JSON.stringify(root._castMap))
            root._castMap = cm;
        const gn = st.gone || [];
        if (JSON.stringify(gn) !== JSON.stringify(root._gone))
            root._gone = gn;
        const tr = st.trial || {};
        if (root._trial.token !== "" && tr.token === root._trial.token) {
            if (root._phase === "applying" && (tr.phase === "trying" || tr.phase === "shown")) {
                applyGuard.stop();
                root._phase = "awaiting";
            } else if ((root._phase === "applying" || root._phase === "awaiting") && tr.phase === "failed") {
                const t = JSON.parse(JSON.stringify(root._trial));
                t.verdict = tr.verdict || "failed:";
                root._trial = t;
                root._revert();
            } else if (root._phase === "awaiting" && tr.phase === "reverted") {
                root._revert();
            }
        }
        // A plug switched a display on against its stored setup (the engine's `on`): the store says so too, once, and the engine's
        // entry is done when it reads the data back.
        const on = st.on || [];
        if (on.length > 0 && root.live) {
            let d = null;
            for (const e of on) {
                const src = d || root.store.doc;
                const sp = src.setups && src.setups[e.set] && src.setups[e.set].outputs ? src.setups[e.set].outputs[e.id] : null;
                if (sp && sp.enabled === false) {
                    d = d || JSON.parse(JSON.stringify(root.store.doc));
                    d.setups[e.set].outputs[e.id].enabled = true;
                }
            }
            if (d !== null)
                root._commitData(d);
        }
        // An import placeholder took a real display's identity in the engine: the store follows.
        if ((st.bound || []).length > 0) {
            const b = Model.bindPlaceholders(root.store.doc, root._outputs);
            if (b.bound.length > 0)
                root._commitData(b.data);
        }
    }
    // An engine that never answers a trial: the trial is called off (the engine's own guard reverts it too).
    Timer {
        id: applyGuard
        interval: 6000
        onTriggered: {
            if (root._phase === "applying")
                root._revert();
        }
    }
    Timer {
        id: countdown
        onTriggered: root._revert()
    }

    // A stale engine (the tree's engine.lua is newer than the file's) is rewritten at once.
    Connections {
        target: link
        function onStateNameChanged() {
            // what is new is looked at again once the engine has answered (at a start the plan is made before it has, and nothing moves it after)
            if (link.stateName === "active")
                seen.restart();
            if (link.stateName === "stale" && root.live && root.store.present) {
                link.writeFile(root.store.doc);
                link.evalLoad();
            }
        }
        // A fresh machine: the config loads the file and the file is not there (EngineLink.fresh). Written once, with whatever is saved.
        function onFreshChanged() {
            if (link.fresh && root.live) {
                link.writeFile(root.store.doc);
                link.evalLoad();
            }
        }
    }

    // ---- what is new, what went away ----
    Timer {
        id: seen
        interval: 0
        onTriggered: root._look()
    }
    function _look(): void {
        const present = {};
        for (let i = 0; i < root._displays.length; i++)
            present[root._displays[i].ident] = root._displays[i];
        const before = root._told.present;
        root._told.present = present;
        if (link.stateName !== "active")
            return;
        // Unplugged (not merely switched off: a switched-off output is still listed, and a mirror change can drop an output from ONE read).
        // The absence must hold ~400 ms (goneCheck) before the user is told.
        for (const id in present)
            delete root._told.gone[id];
        // (with nothing left -- a desktop's one monitor asleep -- there is nobody to tell)
        if (before !== null && config.settings.toasts.unplug && root.notifier && Object.keys(present).length > 0) {
            for (const id in before) {
                if (!present[id] && !Model.isInternal(before[id].name) && !Model.isCast(before[id].name))
                    root._told.gone[id] = before[id].label;
            }
            if (Object.keys(root._told.gone).length > 0)
                goneCheck.restart();
        }
        // (only the shell's own service has a notifier; a probe hands one in. Everything below writes the user's files: live only.)
        if (!root.live)
            return;
        // Never seen: told once and recorded, so the next plug is a known display.
        const known = root.store.doc.displays || {};
        let fresh = [];
        for (const id in present)
            // a cast display is the user's own click, never a surprise: no "connected" toast
            if (!known[id] && !Model.isInternal(present[id].name) && !Model.isCast(present[id].name))
                fresh.push(present[id]);
        if (fresh.length === 0)
            return;
        const d = JSON.parse(JSON.stringify(root.store.doc));
        d.displays = d.displays || {};
        const lap = root._internalName() !== "";
        for (const disp of fresh) {
            d.displays[disp.ident] = { label: disp.label, custom: false, internal: false, port: disp.name, placeholder: false };
            // the only display of a machine with no panel of its own is no news
            if (!lap && Object.keys(present).length < 2)
                continue;
            if (config.settings.toasts.newDisplay && root.notifier && !root._told.fresh[disp.ident]) {
                root._told.fresh[disp.ident] = true;
                root.notifier.notify("new-" + disp.name, {
                    title: disp.label + " connected", body: lap ? "Extended above the laptop." : "Extended.",
                    actions: (lap ? [{ id: "mirror", label: "Mirror" }, { id: "external", label: "Only external" }] : [])
                        .concat([{ id: "arrange", label: "Arrange…" }])
                });
            }
        }
        root._commitData(d);
    }
    Timer {
        id: goneCheck
        interval: 400
        onTriggered: {
            const gone = root._told.gone;
            root._told.gone = {};
            const here = {};
            for (const d of root._displays)
                here[d.ident] = true;
            for (const id in gone) {
                if (!here[id] && root.notifier)
                    root.notifier.notify("gone-" + id, { title: gone[id] + " disconnected", body: "", timeoutMs: 4000 });
            }
        }
    }
    Connections {
        target: root.notifier
        ignoreUnknownSignals: true
        function onAction(key: string, id: string) {
            if (key.indexOf("new-") !== 0)
                return;
            const name = key.slice(4);
            root.notifier.withdraw(key);
            if (id === "arrange" || id === "default")
                root.openRequested(name);
            else
                root.quick(id, name);
        }
    }

    // ---- the diagnostics: told once a session, re-read while a threshold is pending ----
    on_DiagnosticsChanged: diagTell.restart()
    Timer {
        id: diagTell
        interval: 0
        onTriggered: {
            if (!root.live || !root.notifier)
                return;
            for (const dg of root._diagnostics) {
                // (a display off in its setup is said in the popup, with the way back: it is the user's own word, no toast)
                if (dg.kind === "hdmi-integrated" || dg.kind === "setup-off" || root._told.diag[dg.id])
                    continue;
                root._told.diag[dg.id] = true;
                root.notifier.notify("diag-" + dg.id, { title: dg.title, body: dg.body + (dg.command ? "\n" + dg.command : "") });
            }
        }
    }
    Timer {
        // Only while a diagnostic waits on time (the dock's 8 s, a connector's 3 s): no clock otherwise.
        interval: 1000
        repeat: true
        running: root.live && !!root.drm && (root.drm.displayLinkUsb
                 || (root.drm.connectors || []).some(c => c.status === "connected"
                     && !root._outputs.some(o => o.name === c.name && o.enabled !== false)))
        onTriggered: root._now = Date.now()
    }
    Connections {
        target: root.panel
        enabled: root.panel !== null
        ignoreUnknownSignals: true
        function onPanelRevChanged() {
            root._brightRev++;
        }
    }
    onPopupOpenChanged: {
        if (root.popupOpen) {
            ddc.ensureDetected();
            if (root.panel !== null)
                root.panel.refreshPanel();
        }
    }
}
