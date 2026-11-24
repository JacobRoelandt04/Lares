pragma ComponentBehavior: Bound

import QtQuick

import "PanoramaModel.js" as M
import "PanoramaMockEngine.js" as Eng
import "PanoramaScenarios.js" as Sc
import "PanoramaStaging.js" as Staging

// =============================================================================
// PanoramaMock.qml -- PanoramaService's twin for the mockup and the probes (docs/contracts/panorama.md section 4): the SAME names, the
// rules of PanoramaModel run on a fake Hyprland (PanoramaMockEngine.js). Nothing here reaches a machine.
//
// Read-only outputs, methods and signals are the service's. The mock's own controls: `scenario` (set it to load one), `scenarios`,
// `plug(fixture)`, `unplug(name)`, `failNextTrial`, `timeScale` (the trial's clocks run that many times faster), `log`, and
// `postedToasts` -- what the shell would hand the notifier: [{ key, title, body, actions: [{ id, label }], deadlineMs, totalMs }];
// `toastAction(key, id)` is a click on one of its buttons.
//
// A TRIAL: apply() sends the staged data to the fake engine; 1.5 s later the outputs are read back (PanoramaModel.verify): a mismatch
// reverts at once (the verdict), else the keep toast goes up (15 s) and the guard (45 s, then 17 s once the toast is shown) reverts when
// nobody answers. The staged edit lives through the trial and goes with every revert, exactly as PanoramaService's does: the staging
// rules are PanoramaStaging.js's, the one copy both read.
// =============================================================================
Item {
    id: root
    visible: false

    // ---- the service's inputs the mock has no use for -----------------------------------------------------------------------------------
    property bool live: false
    property bool popupOpen: false

    // ---- the mock's controls --------------------------------------------------------------------------------------------------------------
    property string scenario: "desk"
    readonly property var scenarios: Sc.scenarios()
    property bool failNextTrial: false
    property real timeScale: 1
    property var log: []
    property var postedToasts: []

    // ---- the service's read-only outputs -------------------------------------------------------------------------------------------------
    property var displays: []
    property var plan: null
    property string setKey: ""
    property string setupName: ""
    property bool setupSaved: false
    property var setups: []
    property var staged: null
    property var stagedSplit: null
    // ONE read for the workspace chips (the service's): staged if staged, else what is in force
    readonly property var splitIdents: root.stagedSplit !== null ? root.stagedSplit : (root.plan ? Staging.splitIdents(root.plan) : ({}))
    readonly property bool dirty: root._dirty
    property string phase: "idle"
    property var trial: ({ token: "", deadlineMs: 0, totalMs: 0, verdict: "" })
    property var diagnostics: []
    property string identify: ""
    property int panes: 1
    property bool mirroring: false
    property string engineState: "active"
    property string engineWhy: ""
    property int serial: 0
    property int brightnessRev: 0
    property var panel: null                 // the OSD service (the real service's laptop panel); a mock has none

    signal openRequested(string name)

    // ---- cast (docs/contracts/panorama.md section 10): the service's surface on a fake engine; a CastMock is handed in as `cast` ----
    property var cast: null
    property bool castConfig: false                  // the config's "cast": true (the mockup's switch)
    readonly property bool castEnabled: root.castConfig && root.cast !== null && root.engineState === "active"
    readonly property var castDevices: root.castEnabled && root.cast ? (root.cast.devices || []) : []
    readonly property string castState: root.cast ? root.cast.state : "idle"
    readonly property string castDevice: root.cast ? root.cast.device : ""
    readonly property var castFailure: root.cast ? root.cast.failure : null
    readonly property var castMode: root.cast ? root.cast.mode : null
    readonly property string castPhase: castKeeper.phase
    readonly property string castOutput: castKeeper.outputName
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
    property int castOpenMs: 300                     // the fake engine's output shows up this long after cast_open (scaled by timeScale)
    property int castSweepMs: 5000                   // the fake engine's grace for a cast output nobody keeps
    property var castLog: []                         // what the keeper asked of the engine: "open <ident>", "close <name>", "keep <names>"
    function castStatusText(deviceId: string): string {
        return castKeeper.statusText(deviceId);
    }
    function castNoticeFor(deviceId: string): string {
        return castKeeper.noticeFor(deviceId);
    }
    function castNameOf(ident: string): string {
        const id = String(ident).slice(5);
        const d = (root.cast ? root.cast.devices || [] : []).find(x => x.id === id);
        return d ? d.name : "";
    }
    function castStart(deviceId: string): bool {
        return castKeeper.start(deviceId);
    }
    function castDismissNotice(): void {
        castKeeper.dismissNotice();
    }
    readonly property bool castMirrored: castKeeper.virtual
    readonly property string castDisplayName: castKeeper.virtual ? Staging.CAST_STANDIN : castKeeper.outputName
    function castSetMirror(on: bool): void {
        const ident = castKeeper.identity, S = root._S;
        if (ident === "" || root.castDisplayName === "" || !root.plan || !Eng.internalOf(S))
            return;
        const d = Staging.castSetup(S.data, root.plan, ident, Eng.autoName(S, M.labels(S.outs)), Math.floor(root._now() / 1000), sp => {
            sp.mirror = on === true;
            sp.enabled = true;
        });
        if (d === null)
            return;
        root.discard();
        S.data = d;
        root._say("mirror " + ident + " " + (on === true));
        Eng.apply(S, root._now(), "mirror");
        root._refresh();
    }
    function castStop(): void {
        castKeeper.stop();
    }
    function castQualityOf(name: string): var {
        const sp = root.plan ? root.plan.specs[name] : null;
        return Staging.castQuality(sp && sp.cast ? sp.cast : {}, root.settings.castQuality);
    }
    function castApplyQuality(q: var): void {
        const name = root.castDisplayName, ident = castKeeper.identity, S = root._S;
        if (name === "" || ident === "" || !root.plan)
            return;
        const d = Staging.castSetup(S.data, root.plan, ident, Eng.autoName(S, M.labels(S.outs)), Math.floor(root._now() / 1000), sp => {
            sp.cast = { res: q.res, fps: q.fps, bitrate: q.bitrate, audio: q.audio !== false };
        });
        if (d === null)
            return;
        S.data = d;
        root._say("quality " + ident + " " + JSON.stringify(q));
        Eng.apply(S, root._now(), "quality");
        root._refresh();
        castKeeper.restart(q);
    }

    readonly property alias castKeeper: castKeeper
    // panorama.jsonc as the service parses it (PanoramaConfig.parse), at its defaults; a probe writes the keys it is about
    property var settings: ({ keepSeconds: 15, identifyDelayMs: 250, openTab: "situation", castQuality: Staging.CAST_QUALITY,
                              toasts: { newDisplay: true, unplug: true }, cast: false, portLabels: {} })
    CastKeeper {
        id: castKeeper
        cast: root.cast
        armed: root.castEnabled
        defaultQuality: root.settings.castQuality
        popupOpen: root.popupOpen
        outputs: root._outs
        castMap: root._castMap
        plan: root.plan
        mirrorWanted: ident => Staging.castMirrorStored(root._S.outs.filter(o => o.standIn !== true), root._S.data, ident)
        // a cast that mirrors has no output: the TV's stand-in joins (and leaves) the fake compositor's list
        onVirtualChanged: {
            const S = root._S;
            S.outs = S.outs.filter(o => o.standIn !== true);
            if (castKeeper.virtual && Eng.internalOf(S))
                S.outs.push(Staging.castStandIn(castKeeper.identity, Eng.internalOf(S).name));
            root._refresh();
        }
        onOpenOutput: identity => root._castOpen(identity)
        onCloseOutput: name => root._castClose(name)
        onKeepNames: names => root._castKeep(names)
    }
    property var _outs: []
    property var _castMap: ({})
    property var _castKept: []
    function _castOpen(ident: string): void {
        root.castLog = root.castLog.concat(["open " + ident]);
        const S = root._S;
        const name = Eng.castName(S, ident);
        S.cast.map[name] = ident;
        root._castKept = root._castKept.indexOf(name) < 0 ? root._castKept.concat([name]) : root._castKept;
        root._castMap = Object.assign({}, S.cast.map);
        castMade.pending = castMade.pending.concat([name]);
        castMade.interval = Math.max(1, Math.round(root.castOpenMs / root.timeScale));
        castMade.restart();
    }
    function _castClose(name: string): void {
        root.castLog = root.castLog.concat(["close " + name]);
        const S = root._S;
        delete S.cast.map[name];
        root._castKept = root._castKept.filter(n => n !== name);
        castMade.pending = castMade.pending.filter(n => n !== name);
        const i = S.outs.findIndex(o => o.name === name);
        if (i >= 0) {
            S.outs.splice(i, 1);
            delete S.since[name];
            root._say("cast output " + name + " removed");
            Eng.apply(S, root._now(), "removed:" + name);
        }
        root._castMap = Object.assign({}, S.cast.map);
        root._drop();
        root._refresh();
    }
    function _castKeep(names: var): void {
        root.castLog = root.castLog.concat(["keep " + JSON.stringify(names)]);
        root._castKept = names.slice(0);
        castSweep.interval = Math.max(1, Math.round(root.castSweepMs / root.timeScale));
        castSweep.restart();
    }
    Timer {
        id: castMade
        property var pending: []
        onTriggered: {
            const S = root._S, made = castMade.pending;
            castMade.pending = [];
            for (const name of made) {
                if (!S.cast.map[name] || Eng.outByName(S, name))
                    continue;
                S.outs.push(Eng.castFixture(name, S.cast.map[name]));
                S.since[name] = root._now();
                root._say("cast output " + name + " listed");
                Eng.apply(S, root._now(), "added:" + name);
            }
            root._drop();
            root._refresh();
        }
    }
    Timer {
        id: castSweep
        onTriggered: {
            const S = root._S;
            const stray = S.outs.filter(o => M.isCast(o.name) && o.standIn !== true && root._castKept.indexOf(o.name) < 0).map(o => o.name);
            for (const n of stray)
                root._castClose(n);
        }
    }

    // ---- state ---------------------------------------------------------------------------------------------------------------------------
    property var _S: Sc.build("desk")
    property bool _dirty: false
    property var _relations: null
    property var _snapshot: null
    property string _verdict: ""
    property bool _ready: false
    property int _tokenN: 0
    property int _toastN: 0

    function _now(): real {
        return Date.now();
    }

    function _say(line: string): void {
        Eng.log(root._S, root._now(), line);
        root.log = root._S.log.slice(0);
    }

    function _plan(): var {
        return M.resolve(root._S.outs, root._S.data);
    }

    // One read of the state, one write of every output, the serial last (a binding that reads two of them sees one generation).
    function _refresh(): void {
        const S = root._S, plan = root._plan();
        const present = S.outs.filter(o => !M.isIgnored(o.name));
        root._outs = S.outs.slice(0);
        root.displays = Eng.displays(S).map(d => {
            if (d.cast) {
                const nm = root.castNameOf(d.ident);
                if (nm !== "")
                    d.label = nm;
            }
            return d;
        });
        root.plan = plan;
        root.setKey = plan.setKey;
        const st = S.data.setups[plan.setKey];
        root.setupName = st ? (st.name || Eng.autoName(S, M.labels(S.outs))) : "";
        root.setupSaved = !!st;
        root.setups = Eng.setupsList(S, plan.setKey);
        root._dirty = root.staged ? Staging.isDirty(root.staged, root.stagedSplit, plan) : false;
        root.diagnostics = Eng.diagnostics(S, plan, root._verdict, root._now());
        root.panes = present.filter(o => o.enabled !== false && !o.mirrorOf).length;
        root.mirroring = present.some(o => !!o.mirrorOf);
        root.engineState = S.engineState;
        root.engineWhy = S.engineWhy;
        root.serial = root.serial + 1;
    }

    // ---- scenarios ---------------------------------------------------------------------------------------------------------------------------
    function load(id: string): void {
        verifyTimer.stop();
        guardTimer.stop();
        const S = Sc.build(id);
        S.cast = { map: {} };
        root._castMap = {};
        root._castKept = [];
        root.castLog = [];
        S.since = {};
        S.ddc = {};
        S.log = [];
        const now = root._now();
        for (const o of S.outs)
            S.since[o.name] = now - 20000;
        if (S.drm.displayLinkUsb)
            S.drm.displayLinkSince = Math.min(S.drm.displayLinkSince || now, now - 20000);
        root._S = S;
        root.failNextTrial = S.failNext;
        root.staged = null;
        root.stagedSplit = null;
        root.phase = "idle";
        root._relations = null;
        root._verdict = "";
        root.trial = { token: "", deadlineMs: 0, totalMs: 0, verdict: "" };
        root.postedToasts = [];
        root._say("scenario " + id);
        if (S.engineState === "active" && !S.noApply) {
            const r = Eng.apply(S, now, "load");
            root._arrived(r.plan, r.plan.unknown.slice(0), true);
        }
        root.log = S.log.slice(0);
        root._refresh();
    }

    // the displays an apply found never seen: a toast each (unless quiet), the grown setup saved
    function _arrived(plan: var, unknown: var, atLoad: bool): void {
        const S = root._S;
        const fresh = Eng.grow(S, plan, root._now());
        if (!unknown.length)
            return;
        for (const name of Object.keys(plan.ids)) {
            if (unknown.indexOf(plan.ids[name]) < 0)
                continue;
            if (S.quiet && atLoad)
                continue;
            const lab = M.labels(S.outs)[name];
            const lap = Eng.internalOf(S);
            // (the only display of a machine with no panel of its own is no news: the service's rule)
            if (!lap && Object.keys(plan.ids).length < 2)
                continue;
            root._post({ key: "seen:" + name, title: lab + " connected", body: lap ? "Extended above the laptop." : "Extended.",
                         actions: (lap ? [{ id: "mirror", label: "Mirror" }, { id: "external", label: "Only external" }] : [])
                             .concat([{ id: "arrange", label: "Arrange…", name: name }]),
                         ttl: 12000 });
        }
        root._say("never seen: " + unknown.join(", ") + " (saved " + fresh.length + " display records)");
    }

    onScenarioChanged: if (root._ready) root.load(root.scenario)
    Component.onCompleted: {
        root._ready = true;
        root.load(root.scenario);
    }

    // ---- hotplug -------------------------------------------------------------------------------------------------------------------------
    function plug(fixture: string): void {
        const S = root._S;
        if (S.engineState !== "active")
            return;
        const o = Sc.fixture(fixture);
        if (Eng.outByName(S, o.name)) {
            root._say("plug " + fixture + ": " + o.name + " is taken");
            return;
        }
        S.outs.push(o);
        S.since[o.name] = root._now();
        S.drm.connectors.push({ name: o.name, driver: o.driver, status: "connected" });
        if (o.driver === "evdi")
            S.drm.displayLinkUsb = true;
        root._say("plug " + o.name);
        const r = Eng.apply(S, root._now(), "added:" + o.name);
        root._arrived(r.plan, r.plan.unknown.slice(0), false);
        root._drop();
        root.log = S.log.slice(0);
        root._refresh();
    }

    function unplug(name: string): void {
        const S = root._S;
        const i = S.outs.findIndex(o => o.name === name);
        if (i < 0 || S.engineState !== "active")
            return;
        const lab = M.labels(S.outs)[name];
        S.outs.splice(i, 1);
        delete S.since[name];
        S.drm.connectors = S.drm.connectors.filter(c => c.name !== name);
        root._say("unplug " + name);
        Eng.safety(S, root._now());
        Eng.apply(S, root._now(), "removed:" + name);
        root._post({ key: "gone:" + name, title: lab + " disconnected", body: "", actions: [], ttl: 6000 });
        root._drop();
        root.log = S.log.slice(0);
        root._refresh();
    }

    // ---- staging -------------------------------------------------------------------------------------------------------------------------
    // the staged edit, its split and its relations: gone
    function _drop(): void {
        root.staged = null;
        root.stagedSplit = null;
        root._relations = null;
    }

    function stage(): void {
        if (root.staged || root.engineState !== "active")
            return;
        root.staged = Staging.stagedFrom(root.plan);
        root.stagedSplit = Staging.splitIdents(root.plan);
        root._relations = Staging.relationsOf(root.staged, root._S.outs);
        root.phase = "staged";
        root._refresh();
    }

    function stageReset(): void {
        if (root.engineState !== "active" || (root.phase !== "idle" && root.phase !== "staged"))
            return;
        const r = Staging.resetEdit(root._S.outs);
        root.staged = r.staged;
        root.stagedSplit = r.split;
        root._relations = Staging.relationsOf(root.staged, root._S.outs);
        root.phase = "staged";
        root._refresh();
    }

    function stageMove(name: string, x: real, y: real): void {
        root.stage();
        if (!root.staged || !root.staged[name])
            return;
        root.staged = Staging.patchSpec(root.staged, name, { position: [Math.round(x), Math.round(y)] }, root._S.outs, root._relations).staged;
        root._relations = Staging.relationsOf(root.staged, root._S.outs);
        root._refresh();
    }

    function stageSpec(name: string, patch: var): void {
        root.stage();
        if (!root.staged || !root.staged[name])
            return;
        const r = Staging.patchSpec(root.staged, name, patch, root._S.outs, root._relations);
        root.staged = r.staged;
        if (!r.sizes && patch.position !== undefined)
            root._relations = Staging.relationsOf(root.staged, root._S.outs);
        root._refresh();
    }

    function stageSplit(ws: string, ident: string): void {
        root.stage();
        if (!root.staged)
            return;
        root.stagedSplit = Staging.toggleSplit(root.stagedSplit, ws, ident, root.plan);
        root._refresh();
    }

    function discard(): void {
        root._drop();
        if (root.phase === "staged")
            root.phase = "idle";
        root._refresh();
    }

    function ddcSet(name: string, value: real): void {
        root._S.ddc[name] = Math.max(0, Math.min(100, Math.round(value)));
        root.brightnessRev++;
        root._refresh();
        root.ddcChanged(name);
    }

    // ---- the OSD's brightness keys: the service's surface (a fixture's display with a physical size and not DisplayLink has DDC) ----
    readonly property bool ddcDetected: true
    signal ddcChanged(string name)
    function _ddcOf(name: string): var {
        const d = root.displays.find(x => x.name === name);
        return d && d.ddc && d.ddc.capable ? d : null;
    }
    // every external is a "ddc" target (its state says whether it works); only the internal panel is "panel"
    function brightnessTarget(screenName: string): var {
        if (screenName === "" || M.isInternal(screenName))
            return { kind: "panel", connector: "", label: "" };
        if (M.isCast(screenName))
            return { kind: "none", connector: "", label: "" };
        const d = root.displays.find(x => x.name === screenName);
        return { kind: "ddc", connector: screenName, label: d ? d.label : screenName };
    }
    function ddcDetect(): void {
    }
    function ddcEnsure(): void {
    }
    function ddcGoal(name: string): int {
        return root.ddcValue(name);
    }
    function ddcPending(name: string): bool {
        return false;
    }
    // an honest mock: a fixture's display without DDC says "unsupported", it does not pretend
    function ddcState(name: string): string {
        return root._ddcOf(name) ? "ok" : "unsupported";
    }
    function ddcReason(name: string): string {
        return root._ddcOf(name) ? "" : "This display takes no brightness over DDC.";
    }
    function ddcNames(): var {
        return (root.displays || []).filter(d => d.ddc && d.ddc.capable).map(d => d.name);
    }
    function ddcKey(name: string): string {
        return name;
    }
    function ddcBusy(name: string): bool {
        return false;
    }
    function ddcForgive(name: string): void {
    }
    function ddcScrub(name: string, value: int): void {
        if (root._ddcOf(name))
            root.ddcSet(name, value);
    }
    function ddcCommit(name: string): void {
    }
    function commitBrightness(name: string): void {
    }
    // the service's brightness surface (a display with DDC; the internal panel has none yet: stream A3)
    function brightnessOf(name: string): var {
        void root.brightnessRev;
        if (name === "" || M.isInternal(name))
            return { capable: false, value: -1, pending: false, reason: "The laptop panel's brightness is on its keys." };
        if (M.isCast(name))
            return { capable: false, value: -1, pending: false, reason: "A cast display has no brightness." };
        const d = root._ddcOf(name);
        if (!d)
            return { capable: false, value: -1, pending: false, reason: "This display takes no brightness over DDC." };
        return { capable: true, value: Math.max(0, Math.min(1, d.ddc.value / 100)), pending: false, reason: "" };
    }
    function setBrightness(name: string, v01: real): void {
        if (root._ddcOf(name))
            root.ddcSet(name, Math.max(0, Math.min(1, v01)) * 100);
    }
    function ddcValue(name: string): int {
        const d = root._ddcOf(name);
        return d ? d.ddc.value : -1;
    }
    function ddcMax(name: string): int {
        return 100;
    }
    function ddcRead(name: string): void {
    }
    function ddcAdjust(name: string, delta: int): bool {
        const v = root.ddcValue(name);
        if (v < 0)
            return false;
        root.ddcSet(name, v + delta);
        return true;
    }

    // the keep toast as the host sees it (Escape reverts while it waits)
    readonly property QtObject keepPrompt: QtObject {
        readonly property bool waiting: root.phase === "awaiting"
        function revert(): void {
            root.revert();
        }
    }

    function setIdentify(name: string): void {
        root.identify = name;
    }

    function renameSetup(key: string, name: string): void {
        const st = root._S.data.setups[key];
        if (!st)
            return;
        // as the service does: an empty name gives the automatic one back
        const n = String(name || "").trim();
        st.name = n;
        st.custom = n !== "";
        root._say("rename " + key + " -> " + (n !== "" ? n : "(automatic)"));
        root._refresh();
    }

    function forgetSetup(key: string): void {
        if (key === root.setKey || !root._S.data.setups[key])
            return;
        delete root._S.data.setups[key];
        root._say("forget " + key);
        root._refresh();
    }

    // ---- the trial -------------------------------------------------------------------------------------------------------------------------
    function apply(): bool {
        // the service's guard: something staged, the engine active, no trial out. The staged edit stays until the trial ends.
        if (root.engineState !== "active" || !root.staged || (root.phase !== "staged" && root.phase !== "idle"))
            return false;
        const cand = Eng.candidate(root._S, root.plan, root.staged, root.stagedSplit, root._now());
        root._begin(cand, "apply");
        return true;
    }

    // The never-seen toast's buttons, the service's path: a trial of a staged edit, with the keep toast. `name` is the display the toast
    // is about (empty: every external).
    function quick(kind: string, name: string): void {
        const lap = Eng.internalOf(root._S);
        if (root.engineState !== "active" || !lap || (root.phase !== "idle" && root.phase !== "staged"))
            return;
        root.discard();
        root.stage();
        if (kind === "mirror") {
            for (const n of Object.keys(root.staged))
                if (n !== lap.name && (!name || n === name)) root.stageSpec(n, { mirror: true });
        } else if (kind === "external") {
            if (!Object.keys(root.staged).some(n => n !== lap.name && root.staged[n].enabled)) {
                root.discard();
                return;
            }
            root.stageSpec(lap.name, { enabled: false });
        } else {
            root.discard();
            return;
        }
        root.apply();
    }

    function enableOutput(name: string): void {
        root.stage();
        if (root.staged && root.staged[name]) {
            root.stageSpec(name, { enabled: true });
            root.apply();
        }
    }

    function _begin(cand: var, why: string): void {
        const S = root._S;
        root._snapshot = Eng.copy(S.data);
        root._verdict = "";
        root._tokenN += 1;
        root.trial = { token: "t" + root._tokenN, deadlineMs: 0, totalMs: 0, verdict: "" };
        S.data = cand;
        root.phase = "applying";
        root._say("try(" + why + ") " + root.trial.token);
        Eng.apply(S, root._now(), "trial");
        if (root.failNextTrial) {
            root.failNextTrial = false;
            root._say("the fake hardware refuses " + Eng.failOne(S));
        }
        root.log = S.log.slice(0);
        guardTimer.interval = Math.max(1, Math.round(45000 / root.timeScale));
        guardTimer.restart();
        verifyTimer.interval = Math.max(1, Math.round(1500 / root.timeScale));
        verifyTimer.restart();
        root._refresh();
    }

    function _verify(): void {
        const S = root._S;
        const v = M.verify(S.outs, M.resolve(S.outs, S.data));
        if (!v.ok) {
            root._back("failed:" + v.what);
            return;
        }
        const total = Math.round(15000 / root.timeScale);
        root.trial = { token: root.trial.token, deadlineMs: root._now() + total, totalMs: total, verdict: "" };
        root.phase = "awaiting";
        root._post({ key: "keep", title: "Keep these display settings?", body: "They go back by themselves in 15 seconds.",
                     actions: [{ id: "revert", label: "Revert" }, { id: "keep", label: "Keep" }], ttl: 0, deadlineMs: root.trial.deadlineMs, totalMs: total });
        guardTimer.interval = Math.max(1, Math.round(17000 / root.timeScale));
        guardTimer.restart();
        root._say("shown " + root.trial.token + ": guard 17 s");
        root._refresh();
    }

    function _back(verdict: string): void {
        const S = root._S;
        verifyTimer.stop();
        guardTimer.stop();
        S.data = root._snapshot;
        Eng.apply(S, root._now(), "revert");
        root._verdict = verdict;
        root.trial = { token: root.trial.token, deadlineMs: 0, totalMs: 0, verdict: verdict };
        root._unpost("keep");
        // as the service: the staged edit goes with every revert and the picture is the one in force
        root._drop();
        root.phase = "idle";
        root._say("revert " + root.trial.token + (verdict !== "" ? " (" + verdict + ")" : ""));
        root.log = S.log.slice(0);
        root._refresh();
    }

    function keep(): void {
        if (root.phase !== "awaiting")
            return;
        guardTimer.stop();
        root._unpost("keep");
        root.phase = "keeping";
        root._snapshot = null;
        root._say("keep " + root.trial.token);
        root.log = root._S.log.slice(0);
        root._drop();
        root.phase = "idle";
        root._refresh();
    }

    function revert(): void {
        if (root.phase !== "awaiting" && root.phase !== "applying")
            return;
        root.phase = "reverting";
        root._back("");
    }

    Timer {
        id: verifyTimer
        onTriggered: root._verify()
    }
    Timer {
        id: guardTimer
        onTriggered: {
            root._say("guard: nobody answered");
            root._back("");
        }
    }
    // a second's beat: the diagnostics age (a dock plugged 8 s ago speaks), toasts that ran out go
    Timer {
        interval: 1000
        repeat: true
        running: root._ready
        onTriggered: {
            const now = root._now();
            const keep = root.postedToasts.filter(t => t.expiresAt === 0 || t.expiresAt > now);
            if (keep.length !== root.postedToasts.length)
                root.postedToasts = keep;
            root.diagnostics = Eng.diagnostics(root._S, root.plan, root._verdict, now);
        }
    }

    // ---- toasts --------------------------------------------------------------------------------------------------------------------------
    function _post(t: var): void {
        const now = root._now();
        const rec = { key: t.key, title: t.title, body: t.body, actions: t.actions, deadlineMs: t.deadlineMs || 0, totalMs: t.totalMs || 0,
                      expiresAt: t.ttl > 0 ? now + t.ttl / root.timeScale : 0 };
        root.postedToasts = root.postedToasts.filter(x => x.key !== t.key).concat([rec]);
    }

    function _unpost(key: string): void {
        root.postedToasts = root.postedToasts.filter(x => x.key !== key);
    }

    function toastAction(key: string, id: string): void {
        if (key === "keep") {
            if (id === "keep") root.keep(); else root.revert();
            return;
        }
        const t = root.postedToasts.find(x => x.key === key);
        root._unpost(key);
        if (!t)
            return;
        if (id === "mirror" || id === "external")
            root.quick(id, key.slice(5));
        else if (id === "arrange")
            root.openRequested(key.slice(5));
    }

    function toastDismiss(key: string): void {
        root._unpost(key);
    }
}
