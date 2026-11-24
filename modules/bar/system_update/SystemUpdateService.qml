pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../../common/auth"
import "../../common/components"
import "../../common/system"
import "../../auth/data"
import "components"
import "components/SystemUpdateWork.js" as Work
import "../../common/components/JsonComments.js" as JsonComments
import "../../common/config/ConfigCheck.js" as Check
import "../../common/config/ConfigSpecs.js" as Specs

// =============================================================================
// SystemUpdateService.qml -- the system update, as the SHELL holds it.
//
// Once per shell. The engine builds a popup's content on open and DESTROYS it on
// close, and an update outlives its popup (it outlives the SHELL: see THE RUN IS
// NOT OURS), so everything that has to keep working with the popup shut lives
// here and the popup is only handed these objects:
//
// (The members below are aliases; the objects' ids are terminalBackend, updateParser, availableUpdates and uiRecorder, so that no
// id shadows the member of its own name.)
//
//   backend    the TerminalBackend: tails the run's transcript, writes its fifo
//   parser     the PackageUpdateParser on top of it: the run's phase, packages, prompts
//   logger     raw-log rotation: the backend's own tee of a run it started (a replay) goes
//              to a timestamped file, and the 2 newest are kept
//   avail      the available updates: a poll `pollIntervalMs` after the last check ENDED (whoever
//              started it: a popup that opened on stale numbers, a run's end, the notifier --
//              the poll never doubles a check that has just landed, and a check in flight is
//              joined), at the start and when a run ends. No fetch is made on a resume from sleep:
//              the poll's own timer is due when it is due
//   progress   the whole run as one figure (SystemUpdateRunProgress): `percent`, the phase `mark`, the
//              `outcome` an ended run left -- what the bar's button shows while a run goes, popup or no popup
//   recorder   UiStateRecorder: the transcript beside what the popup BELIEVED of it
//   askpassServer / askpassSource
//              the socket sudo's askpass helper asks on, and the pair's hand-over to
//              the shell's AuthBroker (the authentication toast). The service, not the
//              popup, serves it: a sudo asking while the popup is closed would go unanswered
//              and the run would sit at "[sudo] password" until the helper's timeout.
//
//   viewMemory the popup's VIEW (quiet / normal / verbose): quiet whenever nothing runs, and while
//              a run is going the view it was last shown in, kept across a shell restart (view.json
//              beside the marker, keyed by the run). ONE memory for the shell, not one per screen
//              or per popup: `openView()` is what a popup opens in, `noteView(v)` what the popups
//              report as they change.
//
// `live` is the safety switch. LIVE: startUpdate() starts the real detached run
// (helpers/update-run.sh, `yay -Syu --sudoloop`), the available updates are the
// machine's own, and a run still going when the shell starts is reattached.
// NOT live (the default): startUpdate() REPLAYS a captured transcript through the
// same backend and parser (tools/system_update/replay_yay_log.sh), and the available updates are
// a simulated set: nothing here starts yay or pacman or asks checkupdates. (It can
// still WATCH a run somebody else started: `reattachIfRunning()` only reads.) The one
// place a real run is started (`_startReal`) is guarded by `live` itself, and the
// default is the safe one: whoever mounts the service for real says `live: true`.
//
// WHAT A HOST DOES. It sets `live`, hands `popupOpen` (the OR of its screens'
// owners: a popup is open somewhere) and registers the popup content it builds
// (`registerPopup`) so the recorder can read the popup's beliefs. The owner
// (SystemUpdateBarOwner) is the host's half: the icon, the popup, `verbosityMode`.
// A host that drives the run itself (a mockup's AUTORUN) turns `autoStart` off.
//
// Paths (`stateDir`, `markerPath`, `successPath`, `askpassPath`, `logDir`) are
// read ONCE, at creation: a FileView must keep one path for good (see the marker).
// A host that must not touch the machine's own sets them before the service
// completes.
// =============================================================================
Item {
    id: root

    // ---- How it runs --------------------------------------------------------
    property bool live: false
    // At start: reattach to a run in progress (live only), else take a first
    // look at the available updates.
    property bool autoStart: true
    // A run ended: look again at what is left to update.
    property bool refreshAfterRun: true
    // The available updates are a simulated set (no checkupdates, no yay -Qua):
    // follows `live`, but a mockup may want real numbers beside a replayed run.
    property bool mockAvailable: !root.live
    // The simulated set, per category (AvailableUpdatesService's own default: one
    // category far taller than any viewport). It is the first one drawn: the
    // service turns mock mode on as it is built, and that refreshes at once.
    property var mockSpec: ({ core: 9, extra: 180, multilib: 14, aur: 6, flatpak: 5 })
    // system_update.jsonc `check`: the idle poll (0: only when asked) and how old the numbers may be when a popup opens
    property int pollIntervalMs: Math.round(root.settings.check.everyMin * 60000)
    property int staleRefreshMs: Math.round(root.settings.check.staleMin * 60000)

    // What a replay is: tools/system_update/replay_yay_log.sh's log ("" = its own default, the
    // newest capture or the bundled sample) and the seconds between its lines (0 =
    // as fast as it can go, with no pause at prompts).
    property string replayLog: ""
    property real replayDelay: 0.03
    property string replayScript: RepoRoot.dir + "/tools/system_update/replay_yay_log.sh"

    // What a real run is: the supervisor that owns it, and the command it runs.
    property string runScript: RepoRoot.dir + "/helpers/update-run.sh"
    property string runCommand: ["yay", "-Syu"].concat(root.settings.run.flags).join(" ")

    // The snapshot service (SnapshotService, once per shell; null = no snapshots in this shell). The popup
    // reads it for the notch, the line and the page; this service only starts the runs that concern it.
    property var snapshots: null
    // What the run in force is: "update" (yay -Syu) or "undo" (pacman -U of a snapshot's undo plan). Kept
    // after the run ends, until the next one starts, so what reads the end of a run (the notifier, the aura)
    // knows whose end it was. The parser takes it as an input.
    property string runKind: "update"
    // The user's undo tool, and the one-run skip token the pre-transaction hook honours
    // (docs/contracts/snapshots.md sections 7 and 10).
    property string snapshotTool: RepoRoot.dir + "/tools/snapshot/lares-snapshot"
    property string skipTokenPath: Quickshell.env("XDG_RUNTIME_DIR") ? Quickshell.env("XDG_RUNTIME_DIR") + "/lares/snapshot-skip" : ""

    // ---- Where it keeps things ----------------------------------------------
    property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
        + "/lares/system-update"
    // Where the favourites lived before (the repo's root): moved to stateDir/favorites.json once (FavoritesStore.legacyPath); "" = none
    property string favoritesLegacyPath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
        + "/quickshell/system_update_favorites.json"
    // The supervisor's durable marker (update-run.sh): which run, its pid, whether
    // it is still going or how it ended. The silicon service reads it too.
    property string markerPath: root.stateDir + "/last-run.json"
    // The end of the last SUCCESSFUL run, kept apart: the marker is rewritten by
    // every run, and a failed one must not make the system look freshly updated.
    property string successPath: root.stateDir + "/last-success.json"
    property string askpassPath: Quickshell.env("XDG_RUNTIME_DIR")
        ? Quickshell.env("XDG_RUNTIME_DIR") + "/lares-askpass-update.sock" : ""
    property string logDir: ""
    // False only in a probe: no process of a test is root, so none can be the
    // setuid sudo the server insists on for the requester's parent.
    property bool askpassRequireSudoParent: true
    property var askpassBroker: AuthBus.broker

    // ---- What it owns ---------------------------------------------------------
    readonly property alias backend: terminalBackend
    readonly property alias parser: updateParser
    readonly property alias logger: logger
    readonly property alias avail: availableUpdates
    readonly property alias progress: runProgress
    readonly property alias recorder: uiRecorder
    readonly property alias askpassServer: askpassServer
    // Opens a package's upstream URL for the popup. Here, not in the popup, because a click on the link closes the popup
    // and an AUR lookup (yay -Si) outlives the content that asked.
    readonly property alias urlOpener: urlOpener
    readonly property alias askpassSource: askpassSource
    // A run is going: the transcript's tail is alive (an attached run) or a
    // replay is playing.
    readonly property bool running: terminalBackend.running

    // ---- Days since the last successful update -------------------------------
    // From the supervisor's marker (its end time, when it ended well), kept in
    // `successPath` so a later failed run does not erase it. 0 when no run is
    // known: no cobweb on the icon for a machine this shell has not seen update.
    // Re-read when a run ends; the figure moves on the hour, the clock's own beat.
    property double lastSuccessAtMs: 0
    readonly property double staleDays: root.lastSuccessAtMs > 0
        ? Math.max(0, hourClock.now - root.lastSuccessAtMs) / 86400000 : 0

    // ---- Written by the host --------------------------------------------------
    // A popup is open on some screen. Opening one on numbers older than
    // `staleRefreshMs` looks again; one that is fresh is left alone.
    property bool popupOpen: false
    onPopupOpenChanged: {
        if (root.popupOpen)
            root.refreshIfStale();
    }

    // ---- The bar icon: where its colour steps ------------------------------------------------
    //
    // The icon is the muted ink below iconAccentAt updates, the accent below iconWarnAt, the warn colour
    // below iconErrorAt, the error colour from there. Optional file $XDG_CONFIG_HOME/quickshell/config/system_update.jsonc
    // (or .json), hot: { "icon": { "accentAt": 1, "warnAt": 30, "errorAt": 150 } } (.examples/system_update.jsonc
    // has it with comments). A value that is not a whole number >= 1 is the default; steps out of order
    // (accentAt <= warnAt <= errorAt) are all three defaults; a file that does not parse keeps the numbers it
    // had and the log says where.
    property int iconAccentAt: 1
    property int iconWarnAt: 30
    property int iconErrorAt: 150
    // The file's other keys through its spec (modules/common/config/specs/system_update.js): every key, its default where the file says
    // nothing or something wrong.
    property var settings: Check.read(Specs.specOf("system_update"), {}).settings
    property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
        + "/quickshell/config/system_update.jsonc"
    function _applyConfig(text) {
        let accent = 1;
        let warn = 30;
        let err = 150;
        const t = String(text || "");
        if (t.trim().length === 0)
            root.settings = Check.read(Specs.specOf("system_update"), {}).settings;
        if (t.trim().length > 0) {
            let o = null;
            try {
                o = JSON.parse(JsonComments.strip(t));
            } catch (e) {
                const at = JsonComments.locate(t);
                console.warn("system_update.jsonc" + (at ? " line " + at.line + ", column " + at.column + ": " + at.reason : ": " + e.message)
                             + " -- the previous settings are kept");
                return;
            }
            root.settings = Check.read(Specs.specOf("system_update"), o).settings;
            if (o && typeof o === "object" && o.dot !== undefined)
                console.warn("system_update.jsonc: \"dot\" is now \"icon\" -- the dot's numbers are not read");
            const d = o && typeof o === "object" ? o.icon : null;
            if (d && typeof d === "object") {
                const a = Number(d.accentAt);
                const w = Number(d.warnAt);
                const x = Number(d.errorAt);
                if (isFinite(a) && a >= 1)
                    accent = Math.floor(a);
                if (isFinite(w) && w >= 1)
                    warn = Math.floor(w);
                if (isFinite(x) && x >= 1)
                    err = Math.floor(x);
                if (warn < accent || err < warn) {
                    console.warn("system_update.jsonc: icon.accentAt <= icon.warnAt <= icon.errorAt does not hold -- all three are the defaults");
                    accent = 1;
                    warn = 30;
                    err = 150;
                }
            }
        }
        root.iconAccentAt = accent;
        root.iconWarnAt = warn;
        root.iconErrorAt = err;
    }
    ConfigFile {
        id: configFile
        path: root.configPath
        onLoaded: root._applyConfig(configFile.text())
        onLoadFailed: root._applyConfig("")
    }

    // ---- The popup's view ---------------------------------------------------------------
    //
    // The popup is QUIET unless an update is in progress, and then it opens
    // in the view that update was last shown in, restarts included. The memory is the shell's:
    // one, not one per screen's owner.
    //
    //   _lastView   the view the OPEN popup shows (a popup reports it on open and on every change);
    //               what a run that is started under it begins with
    //   runView     the view the current run is shown in; every popup's report while a run is going
    //               replaces it, and a real run's is kept in view.json (the marker is the
    //               supervisor's -- this shell writes nothing there)
    property string _lastView: "quiet"
    property string runView: "quiet"
    property string viewPath: root.stateDir + "/view.json"
    readonly property bool runActive: root.running || attachPoll.running

    function _validView(v) {
        return v === "quiet" || v === "normal" || v === "verbose";
    }
    // What a popup opens in: the run's view while one runs; else system_update.jsonc's `view` ("last": the one the last popup was left in).
    function openView() {
        return root.runActive ? root.runView : root.idleView();
    }
    function idleView() {
        const v = root.settings.view;
        return v === "last" ? root._lastView : v;
    }
    // A popup shows `view` now (it opened in it, or the user moved it there).
    function noteView(view) {
        if (!root._validView(view))
            return;
        root._lastView = view;
        if (root.runActive && view !== root.runView) {
            root.runView = view;
            root._persistRunView();
        }
    }
    // A run begins: with the view of the popup it was started under, quiet when there is none.
    function _armRunView(view) {
        root.runView = root._validView(view) ? view : "quiet";
        root._persistRunView();
    }
    function _viewAtStart() {
        return root.popupOpen ? root._lastView : "quiet";
    }
    function _persistRunView() {
        if (!root.recorder.recording || root.recorder.runId.length === 0)
            return;
        viewFile.setText(JSON.stringify({ runId: root.recorder.runId, view: root.runView }) + "\n");
    }
    // The view a restarted shell finds the run in: what was kept for THIS run, else quiet.
    function _savedView(runId) {
        viewFile.reload();
        try {
            const o = JSON.parse(viewFile.text() || "{}");
            if (o && o.runId === runId && root._validView(o.view))
                return o.view;
        } catch (e) {}
        return "quiet";
    }
    FileView {
        id: viewFile
        blockAllReads: true
        blockWrites: true
        printErrors: false
        path: root.viewPath
    }

    // The popup asks "a fresh check, please" every time it is shown idle, and the
    // host's `popupOpen` says the same: either way one refresh, and none while a
    // run is its own state or a check is already out.
    function refreshIfStale() {
        if (root.running || availableUpdates.refreshing)
            return;
        if (Date.now() - availableUpdates.lastRefreshAtMs < root.staleRefreshMs)
            return;
        availableUpdates.refresh();
    }

    // ---- The recorder reads the popup ----------------------------------------
    // What the popup believed is a popup's own state, and the popup exists only
    // while it is open: each content built registers here, and the newest one
    // still alive is what the recorder reads (two screens can each have one).
    property var _popups: []
    function registerPopup(item) {
        if (!item || root._popups.indexOf(item) >= 0)
            return;
        root._popups = root._popups.concat([item]);
        uiRecorder.popup = item;
    }
    function unregisterPopup(item) {
        const left = root._popups.filter(p => p !== item);
        root._popups = left;
        uiRecorder.popup = left.length > 0 ? left[left.length - 1] : null;
    }

    // =========================================================================
    //  The pipeline
    // =========================================================================
    TerminalBackend {
        id: terminalBackend
        scrollbackMax: 5000
        useTTY: true
        clearOnStart: true
    }
    PackageUpdateParser {
        id: updateParser
        backend: terminalBackend
        runKind: root.runKind
    }
    SystemUpdateRunProgress {
        id: runProgress
        parser: updateParser
        running: terminalBackend.running
        snapshots: root.snapshots
    }
    SystemUpdateLogger {
        id: logger
        backend: terminalBackend
        logDir: root.logDir
    }
    AvailableUpdatesService {
        id: availableUpdates
        // the favourites are this service's state, beside the run's markers (a mock's stateDir is its own)
        favoritesPath: root.stateDir + "/favorites.json"
        favoritesLegacyPath: root.favoritesLegacyPath
        mockSpec: root.mockSpec
        mockMode: root.mockAvailable
        // Not while a run is going: the list on screen is the run's, and a check
        // racing the transaction tells nobody anything. The run's end refreshes.
        pollIntervalMs: root.running ? 0 : root.pollIntervalMs
        officialEnabled: root.settings.check.official
        aurEnabled: root.settings.check.aur
        flatpakEnabled: root.settings.check.flatpak
        groupMin: root.settings.list.groupMin
    }
    PackageUrlOpener { id: urlOpener }

    // Records the raw transcript AND what the UI made of it, side by side. Only for
    // real runs (startReal, reattach): a replay or a synthetic run tells us nothing
    // we did not already put there.
    UiStateRecorder {
        id: uiRecorder
        parser: updateParser
        backend: terminalBackend
        service: availableUpdates
    }

    // =========================================================================
    //  sudo's password
    //
    // yay's sudo (yay --sudo helpers/sudo-askpass, update-run.sh) asks its
    // SUDO_ASKPASS helper, which connects to `askpassPath`. The socket is served
    // while the backend is attached to a live run, with the supervisor's pid as the
    // root every sudo of the run must descend from, and each request becomes an
    // AuthBroker request (the toast takes the face, the password or the cancel).
    // No secret crosses the backend or the run's stdin.fifo. The run outlives any
    // one shell and the helper retries until the next one serves the same path;
    // this pair serves it for the whole life of the shell, popup or no popup.
    // =========================================================================
    AskpassServer {
        id: askpassServer
        path: root.askpassPath
        active: root.askpassPath.length > 0 && terminalBackend.attached === true && terminalBackend.running === true
        rootPid: Number(terminalBackend.attachPid || 0)
        requireSudoParent: root.askpassRequireSudoParent
        // update-run.sh's LARES_ASKPASS_TIMEOUT: sudo's own passwd_timeout.
        answerWindowMs: 300000
    }
    HowdyConfig {
        id: howdy
    }
    AskpassSource {
        id: askpassSource
        broker: root.askpassBroker
        server: askpassServer
        title: "System update"
        howdyMode: howdy.mode
        faceTimeoutMs: howdy.timeoutMs
        // What the toast says: the run, and what yay is doing when sudo asks --
        // the card's own words (SystemUpdateWork.js), popup or no popup.
        describe: function (request) {
            return Work.askpassDescription(updateParser.phase, updateParser.subPhase, updateParser.phaseLabel,
                                           root.runKind, updateParser.snapshotState);
        }
        // With no broker there is nobody to ask: the source answers sudo "" at
        // once (it says so, and yay stops) rather than leave it waiting on a
        // toast that cannot come.
        onDeclined: (request, reason) => console.warn("update: sudo was refused a password prompt: " + reason)
    }

    // =========================================================================
    //  THE RUN IS NOT OURS
    //
    // A real update is owned by helpers/update-run.sh, not by this shell.
    // Quickshell's `Process` destructor calls kill(), and `Process` is a
    // PostReloadHook, so a CONFIG RELOAD would destroy it -- saving any
    // .qml file while an update ran would kill it mid-transaction, which can
    // leave the machine with a new kernel and no initramfs. So the shell
    // only ATTACHES: it reads the transcript and writes the fifo, and can
    // come and go while the run continues.
    // =========================================================================
    // ONE static path, refreshed with reload(). A FileView loads synchronously on its FIRST `path`
    // assignment and NOT on later ones -- assign a second path and `text()`
    // hands back the PREVIOUS file's bytes, with no error and no warning.
    // (`reload()` on an unchanged path is fine, and picks up a file that did
    // not exist when the path was set; `blockAllReads` makes the read after it
    // the new bytes, where `blockLoading` alone hands back the previous load.)
    // So the shell reads only the marker, which is why the supervisor puts the
    // pid in it.
    //
    // `printErrors: false`: the marker legitimately does not exist until the
    // first run ever.
    FileView {
        id: marker
        blockAllReads: true
        printErrors: false
        path: root.markerPath
    }
    FileView {
        id: successFile
        blockAllReads: true
        blockWrites: true
        printErrors: false
        path: root.successPath
    }
    // A pid's /proc/<pid>/stat has a FileView of its own, made for the one read:
    // pointing a single one at each pid in turn is the repoint the law above
    // forbids (a failed read LEAVES THE PREVIOUS FILE'S CONTENTS in place).
    Component {
        id: statViewC
        FileView {
            blockLoading: true
            printErrors: false
        }
    }

    function _readMarker() {
        marker.reload();
        const t = marker.text();
        if (!t || t.length === 0) return null;
        try { return JSON.parse(t); } catch (e) { return null; }
    }
    // /proc rather than spawning `kill -0`: no process, and a dead pid simply
    // has no stat file. /proc/N/stat always begins "N (", so what was read
    // validates itself against the pid we asked about.
    function _pidAlive(pid) {
        if (!(pid > 0)) return false;
        const fv = statViewC.createObject(root, { path: "/proc/" + pid + "/stat" }) as FileView;
        const text = fv.text();
        fv.destroy();
        return text.indexOf(String(pid) + " (") === 0;
    }
    // The supervisor has started when the marker names OUR run and says it is
    // running. Until then there is nothing to attach to.
    function _attachWhenReady(runId) {
        const m = root._readMarker();
        if (!m || m.runId !== runId || m.state !== "running" || !m.pid) return false;
        terminalBackend.attach(m.runDir, m.pid);
        return true;
    }
    // A run is going that this shell is not attached to: another shell's, a
    // terminal's. A second supervisor on top of it would be two yays at once.
    function _runInProgress() {
        const m = root._readMarker();
        return !!m && m.state === "running" && !!m.pid && root._pidAlive(m.pid);
    }

    // run.json is written before the command starts, but execDetached returns
    // immediately, so the file may not be there for a beat.
    property string _pendingRunId: ""
    Timer {
        id: attachPoll
        interval: 120
        repeat: true
        property int tries: 0
        onTriggered: {
            if (root._attachWhenReady(root._pendingRunId)) { attachPoll.stop(); return; }
            if (++attachPoll.tries > 40) {
                attachPoll.stop();
                console.warn("update: the supervisor never announced run " + root._pendingRunId);
            }
        }
    }
    // Wait for the supervisor of run `runId` to announce itself, then attach. The
    // second half of a real start, public so a probe that launched a stub
    // supervisor of its own can walk the same path.
    function awaitRun(runId) {
        attachPoll.tries = 0;
        root._pendingRunId = runId;
        attachPoll.restart();
    }

    // On load: is one of our updates still going? The marker is outside the
    // runtime dir on purpose -- a run killed by the machine going down has to
    // be detectable after the reboot that killed it.
    function reattachIfRunning() {
        const m = root._readMarker();
        if (!m || m.state !== "running" || !m.runDir || !m.pid) return false;
        // Liveness is the SUPERVISOR'S PID. A marker still saying "running"
        // with a dead pid is the interesting case -- the machine went down
        // mid-transaction -- and is not a reattach.
        if (!root._pidAlive(m.pid)) return false;
        console.log("update: reattaching to a run still in progress: " + m.runDir);
        root.runKind = m.kind === "undo" ? "undo" : "update";
        // RECORD THE REST OF IT. The recorder is started here as well as by a real start, so a shell
        // that relaunched mid-run still records the remainder. The original start time comes
        // from the marker so `t` continues rather than restarting.
        uiRecorder.start(m.runId, m.startedAt);
        root._armRunView(root._savedView(m.runId));
        terminalBackend.attach(m.runDir, m.pid);
        return true;
    }

    function _runStamp() {
        const d = new Date();
        function p2(n) {
            return (n < 10 ? "0" : "") + n;
        }
        return d.getFullYear() + "-" + p2(d.getMonth() + 1) + "-" + p2(d.getDate()) + "_" + p2(d.getHours()) + "-" + p2(d.getMinutes()) + "-" + p2(d.getSeconds());
    }

    // The update. LIVE: the real thing, detached. Otherwise a replay. `withoutSnapshot`: the user answered a
    // failed snapshot with "Update without it": the skip token is laid before the run starts and taken back
    // when it ends.
    function startUpdate(withoutSnapshot) {
        if (root.live) {
            root._startReal(root.runCommand, "update", withoutSnapshot === true);
        } else {
            root.runKind = "update";
            root.startReplay();
        }
    }

    // The undo of the update a snapshot was taken before: `lares-snapshot undo <short>` on the run's PTY
    // (sudo -A pacman -U), through the same supervisor, its marker saying `kind: undo`.
    function startUndo(short) {
        const id = String(short || "");
        if (!/^[0-9a-f]{8}$/.test(id))
            return;
        // Only a live shell runs one: an undo has no replay (a mockup plays its own, MockUpdateRun).
        if (root.live)
            root._startReal("'" + root.snapshotTool.replace(/'/g, "'\\''") + "' undo " + id, "undo", false);
    }

    // The skip token (section 7): a regular file the hook looks for, not consumed, at most 2 h old. Written in
    // the SAME process that starts the supervisor so the token is there before pacman is; removed when a run ends
    // (any run, also one that outlived this shell) and at start when nothing runs.
    function _dropSkipToken() {
        if (root.live && root.skipTokenPath.length > 0)
            Quickshell.execDetached(["rm", "-f", "--", root.skipTokenPath]);
    }

    // The captured transcript through the real backend and parser, at
    // `replayDelay` (tools/system_update/replay_yay_log.sh pauses at prompts when it is above 0).
    // Never a run: it is what a mockup's Replay button and every non-live start do.
    function startReplay() {
        // A replay is nobody's attached run: forget the last attach's directory,
        // pid and transcript path, or its prompts would be written to a dead
        // fifo and its bytes appended to a real run's transcript.
        root._armRunView(root._viewAtStart());
        terminalBackend.attachDir = "";
        terminalBackend.attachPid = 0;
        terminalBackend.useTTY = true;
        terminalBackend.logFilePath = "";
        const d = Number(root.replayDelay);
        terminalBackend.command = "bash '" + root.replayScript.replace(/'/g, "'\\''") + "' '"
            + root.replayLog.replace(/'/g, "'\\''") + "' " + (d > 0 ? d.toFixed(3) : "0");
        terminalBackend.start();
    }

    // THE ONLY PLACE A REAL RUN STARTS. Guarded by `live`, and by there being
    // no run already: a second supervisor on top of a going one would be two yays
    // fighting for pacman's lock.
    function _startReal(command, kind, withoutSnapshot) {
        if (!root.live)
            return;
        if (root.running || attachPoll.running || root._runInProgress()) {
            console.log("update: a run is already going; not starting another");
            return;
        }
        // `yay -Syu` invokes sudo internally, and update-run.sh gives it
        // `--sudo helpers/sudo-askpass` (every call -A) + SUDO_ASKPASS, so
        // sudo asks through the askpass pair above and the authentication
        // toast (AuthBus.broker), never on the PTY. A shell that hosts no
        // AuthBroker has its run's first sudo refused ("sudo: no password
        // was provided").
        root.runKind = kind;
        const stamp = root._runStamp();
        uiRecorder.start(stamp);
        root._armRunView(root._viewAtStart());
        // The recorder's run dir IS the run dir: transcript.log lands beside
        // ui-state.jsonl, and both survive a reboot.
        const runDir = uiRecorder.runDir;
        // The transcript is written by script(1) inside the supervisor, not
        // by the backend's tee -- attach() points logFilePath at it so the
        // logger still reports the right path.
        // Detached, so nothing that happens to this shell can reach it.
        // --sudoloop: yay refreshes the sudo timestamp in the background for
        // as long as it runs.
        //
        // Without it the run loses its AUR half. sudo's timestamp
        // expires after a few minutes of not being used; a run can spend 13
        // minutes in hooks (one `Updating X fontdir indices` alone took 10.2),
        // so by the time yay comes back to install the AUR packages the
        // ticket is stale and it asks for the password again, long after the
        // user has stopped watching: the run ends exit=1 with `aur 0/8`.
        const args = ["--kind", kind, runDir, command];
        if (withoutSnapshot && root.skipTokenPath.length > 0) {
            const dir = root.skipTokenPath.substring(0, root.skipTokenPath.lastIndexOf("/"));
            Quickshell.execDetached(["sh", "-c", 'mkdir -p -- "$1" && : > "$2" && shift 2 && exec setsid "$@"',
                                     "sh", dir, root.skipTokenPath, root.runScript].concat(args));
        } else {
            Quickshell.execDetached(["setsid", root.runScript].concat(args));
        }
        root.awaitRun(stamp);
    }

    // =========================================================================
    //  Days since the last successful update
    // =========================================================================
    function _refreshLastSuccess() {
        let best = 0;
        successFile.reload();
        try {
            best = Number(JSON.parse(successFile.text() || "{}").endedAt) || 0;
        } catch (e) {
            best = 0;
        }
        const m = root._readMarker();
        // (an undo is not an update: the machine is not freshly updated by one)
        if (m && m.state === "finished" && m.exit === 0 && m.kind !== "undo" && Number(m.endedAt) > best) {
            best = Number(m.endedAt);
            // The directory is the marker's own, which exists if the marker does.
            successFile.setText(JSON.stringify({ endedAt: best, runId: String(m.runId || "") }) + "\n");
        }
        if (best !== root.lastSuccessAtMs)
            root.lastSuccessAtMs = best;
        root._askHour();
    }
    // The figure is in days: the hour is a fine enough beat, and BoundaryClock
    // is the shell's one clock for a figure that moves on a boundary (it follows
    // a suspend on its own).
    BoundaryClock {
        id: hourClock
    }
    function _askHour() {
        if (root.lastSuccessAtMs > 0)
            hourClock.request((Math.floor(Date.now() / 3600000) + 1) * 3600000);
    }
    Connections {
        target: hourClock
        function onNowChanged() {
            root._askHour();
        }
    }

    // A run ended (the tail exits with the supervisor, which writes the marker
    // just before it does).
    Connections {
        target: terminalBackend
        function onExited(code, status) {
            root._dropSkipToken();
            root._refreshLastSuccess();
            // After an undo too: what it took back waits again.
            if (root.refreshAfterRun)
                availableUpdates.refresh();
        }
    }

    // On load: is one of our updates still going? Then the run itself is the
    // state. Nothing running means a fresh start: take a look at what is
    // outstanding so the icon and the idle panel have something to show.
    // Deferred a turn so every part above has completed (a parent's
    // Component.onCompleted can run before its children's).
    function _start() {
        root._applyConfig(configFile.text());
        root._refreshLastSuccess();
        if (!root.autoStart)
            return;
        if (root.live && root.reattachIfRunning())
            return;
        // No run, so no token of a run can still be wanted (the hook ignores one after 2 h; this is the tidy).
        root._dropSkipToken();
        availableUpdates.refresh();
    }
    Component.onCompleted: Qt.callLater(root._start)
}
