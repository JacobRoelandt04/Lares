pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// MockUpdateRun.qml
//
// A synthetic system update, for looking at the UI.
//
// Replaying a real captured `yay -Syu` is a poor way to review visual design:
// it takes as long as the real thing, most of its runtime is one phase, and
// the interesting states (a failure, an AUR build, kernel work, a prompt)
// either never occur or flash past once. This drives the popup through every
// phase directly, with no process, no PTY and no parsing — so each state can
// be held still, scrubbed to, and looked at.
//
// It stands in for BOTH halves of the real pipeline, because the popup takes
// its "is a run happening" from the backend and its content from the parser:
//
//     SystemUpdatePopup {
//         backend: mock.backend
//         parser:  mock.parser
//     }
//
// Everything it exposes mirrors the shape of TerminalBackend and
// PackageUpdateParser. It is a mockup aid, not part of the real path.
// =============================================================================
Item {
    id: mock

    // ---- Configuration ----
    // How many packages per category the fake transaction contains.
    property var spec: ({core: 9, extra: 40, multilib: 14, aur: 6})
    // Playback speed multiplier; 1.0 is the scripted pace.
    property real speed: 1.0
    // Inject a failure when the run reaches this step key ("" disables).
    property string failAtStep: ""
    // The run takes a snapshot between the integrity checks and the install (the pre-transaction hook of
    // docs/contracts/snapshots.md): the parser's snapshot* state moves through running -> done, and a failure
    // injected at "snapshot" ends the run there with no package touched, as pacman does.
    property bool snapshotStep: false
    // An undo (pacman -U of old packages): a shorter script with no sync and no download, packages that are
    // all official, `runKind` "undo" on the parser.
    property bool undo: false
    // Pause the script when a prompt opens, as a real run would. The mock has
    // no stdin, so a prompt it stops on can never be answered — it answers
    // itself after `promptAutoAnswerMs` instead, which is long enough to look
    // at the banner and short enough not to strand the run.
    property bool pauseOnPrompt: true
    property int promptAutoAnswerMs: 2000

    readonly property alias running: _be.running
    readonly property int stepIndex: mock._idx
    readonly property int stepCount: mock._script.length
    // The script's step names in order (what a panel's jump buttons list), and a step's index by name.
    readonly property var stepNames: mock._script.map(st => st.name)
    function indexOfStep(name) {
        return mock.stepNames.indexOf(name);
    }
    readonly property string stepName: mock._idx >= 0 && mock._idx < mock._script.length
        ? mock._script[mock._idx].name : "idle"

    signal finished()

    // =================================================================
    //  Fake backend
    // =================================================================
    property alias backend: _be
    QtObject {
        id: _be
        property bool running: false
        property bool awaitingInput: false
        property bool passwordPrompt: false
        property string lastPrompt: ""
        property string command: ""
        property var linesModel: _lines
        property color defaultFg: "#5D5D5F"
        property string fontFamily: "Consolas"
        property bool _previewing: false
        function start() { mock.start(); }
        function submit(text) { mock.answerPrompt(text); }
    }
    ListModel { id: _lines }

    // =================================================================
    //  Fake parser
    // =================================================================
    property alias parser: _pp
    QtObject {
        id: _pp
        property string phase: "INITIAL"
        property string phaseLabel: "Idle"
        property string subPhase: ""
        property string subPhaseLabel: ""
        property string runKind: mock.undo ? "undo" : "update"
        property string snapshotState: ""
        property real snapshotProgress: -1
        property string snapshotCode: ""
        property string snapshotText: ""
        property string snapshotShort: ""

        property var packages: _pkgs
        property var errors: _errs
        property int errorCount: 0
        // The popup reads these for its notices block. The synthetic run
        // raises none, but a stub that simply lacks the property makes every
        // `noticeCount === 0` test read as false.
        property int noticeCount: 0
        readonly property ListModel notices: ListModel {}

        property bool awaitingUserInput: false
        property string currentPromptKind: ""
        property string currentPromptText: ""
        property string currentPromptDefault: ""

        property int downloadsDone: 0
        property int downloadsTotal: 0
        property string currentDownloading: ""
        property string downloadSoFar: ""
        property string downloadRate: ""
        property string downloadEta: ""
        property int downloadPct: -1
        // Sum of the packages' dlBytes, the way the parser reads pacman's
        // "Total Download Size" line.
        property real totalDownloadBytes: 0

        property int installsDone: 0
        property int installsTotal: 0
        property string currentInstalling: ""

        property int hooksDone: 0
        property int hooksStarted: 0
        property int hooksTotal: 0
        property string currentHook: ""

        property int aurBuildsDone: 0
        property int aurBuildsTotal: 0
        property string currentAurBuild: ""
        property string currentAurBuildStep: ""

        property string integrityStep: ""
        property string currentInitramfsKernel: ""
        property string currentInitramfsHook: ""
        property string currentDkmsOp: ""

        signal packageProgress(string name, string state, int pct)
    }

    ListModel { id: _pkgs }
    ListModel { id: _errs }
    ListModel { id: _initramfs }
    ListModel { id: _dkms }

    // =================================================================
    //  Fake package set
    // =================================================================
    readonly property var _names: ({
        core: ["linux", "linux-headers", "linux-lts", "systemd", "glibc",
               "openssl", "pacman", "coreutils", "linux-firmware"],
        extra: ["ffmpeg", "mpv", "gvfs", "libheif", "libbluray", "qt6-base",
                "qt6-webengine", "electron43", "libreoffice-fresh", "cef",
                "wine", "signal-desktop", "thunderbird", "gimp", "inkscape",
                "blender", "krita", "vlc", "obs-studio", "kdenlive",
                "python", "rust", "go", "nodejs", "clang", "llvm", "cmake",
                "boost", "icu", "harfbuzz", "cairo", "pango", "gtk4", "gtk3",
                "mesa", "vulkan-icd-loader", "pipewire", "wireplumber",
                "networkmanager", "bluez"],
        multilib: ["lib32-glibc", "lib32-mesa", "lib32-vulkan-icd-loader",
                   "lib32-gcc-libs", "lib32-libx11", "lib32-alsa-lib",
                   "lib32-openssl", "lib32-zlib", "lib32-curl", "lib32-libdrm",
                   "lib32-systemd", "lib32-pipewire", "lib32-freetype2",
                   "lib32-fontconfig"],
        aur: ["yay", "visual-studio-code-bin", "spotify", "zoom",
              "google-chrome", "asusctl"]
    })

    // A few hundred KiB for most, a few GiB for the occasional monster.
    function _mockSize(cat, i) {
        const huge = (i % 13 === 3) ? 900 : (i % 7 === 2 ? 60 : 1);
        const base = cat === "aur" ? 4 : 1;
        return (0.4 + (i % 5) * 0.3) * huge * base * 1048576;
    }

    function _mkVersion(i, bump) {
        const a = 1 + (i % 9), b = (i * 7) % 24, c = 1 + (i % 5) + (bump ? 1 : 0);
        return a + "." + b + "." + c + "-" + (1 + (i % 3) + (bump ? 1 : 0));
    }

    function _buildPackages() {
        _pkgs.clear();
        const cats = mock.undo ? ["core", "extra"] : ["core", "extra", "multilib", "aur"];
        for (const cat of cats) {
            const want = mock.spec[cat] || 0;
            const pool = mock._names[cat] || [];
            for (let i = 0; i < want; i++) {
                const nm = i < pool.length ? pool[i] : cat + "-pkg-" + (i + 1);
                _pkgs.append({
                    number: _pkgs.count + 1,
                    repo: cat === "aur" ? "aur" : cat,
                    name: nm,
                    oldVer: mock._mkVersion(i, false),
                    newVer: mock._mkVersion(i, true),
                    isAur: cat === "aur",
                    role: i % 4 === 0 ? "explicit" : "dependency",
                    flavour: cat === "aur" ? (i % 3 === 0 ? "git" : "source") : "binary",
                    state: "queued", error: "",
                    dlPct: 0, dlRate: "", dlEta: "",
                    // Deliberately lopsided: a couple of packages per category
                    // are enormous and the rest are small, which is what a real
                    // transaction looks like and what makes a byte-weighted
                    // progress bar behave differently from a package count.
                    dlBytes: mock._mockSize(cat, i),
                    netBytes: mock._mockSize(cat, i) * 2.4
                });
            }
        }
        {
            let total = 0;
            for (let i = 0; i < _pkgs.count; i++) total += _pkgs.get(i).dlBytes || 0;
            _pp.totalDownloadBytes = total;
        }
        _pp.downloadsTotal = _pkgs.count;
        _pp.installsTotal = _pkgs.count;
        _pp.aurBuildsTotal = mock.spec.aur || 0;
    }

    function _setState(i, st, pct) {
        _pkgs.setProperty(i, "state", st);
        if (pct !== undefined) _pkgs.setProperty(i, "dlPct", pct);
        _pp.packageProgress(_pkgs.get(i).name, st, pct === undefined ? 0 : pct);
    }

    // =================================================================
    //  Script
    //
    // Each entry: a name, how long it runs, and what to do on entry and on
    // every tick. Ticks are what animate download percentages and install
    // counters, so the visuals move the way a real run's do.
    // =================================================================
    property int _idx: -1
    property real _t: 0            // 0..1 through the current step
    property int _stepMs: 0

    // The snapshot hook's step: pacman's pre-transaction hooks, the first of which takes the snapshot.
    readonly property var _snapEntry: ({name: "snapshot", ms: 5000, enter: () => {
            _pp.subPhase = "L4_PREHOOKS"; _pp.subPhaseLabel = "Running pre-install hooks";
            _pp.hooksTotal = 3; _pp.hooksStarted = 1; _pp.hooksDone = 0;
            _pp.currentHook = "Taking a system snapshot";
            _pp.integrityStep = "";
            _pp.snapshotState = "running"; _pp.snapshotProgress = 0; _pp.snapshotCode = "";
            _pp.snapshotText = _pkgs.count + " packages: linux, mesa, nvidia-open";
        }, tick: (t) => {
            _pp.snapshotProgress = Math.floor(t * 20) / 20;
            if (t >= 1) {
                _pp.snapshotState = "done"; _pp.snapshotProgress = 1; _pp.snapshotShort = "6a493314";
                _pp.hooksDone = 1;
            }
        }})
    readonly property var _script: {
        if (mock.undo) {
            const u = mock._undoScript.slice();
            if (mock.snapshotStep) u.splice(u.findIndex(st => st.name === "integrity") + 1, 0, mock._snapEntry);
            return u;
        }
        if (!mock.snapshotStep) return mock._updateScript;
        const out = mock._updateScript.slice();
        out.splice(out.findIndex(st => st.name === "integrity") + 1, 0, mock._snapEntry);
        return out;
    }
    // pacman -U: it prints "loading packages..." and goes straight to its table; no database sync, no download.
    readonly property var _undoScript: [
        {name: "auth", ms: 1000, enter: () => {
            _pp.phase = "INITIAL"; _pp.phaseLabel = "Authenticating";
            _be.passwordPrompt = false;
        }},
        {name: "resolve", ms: 1600, enter: () => {
            _pp.phase = "OFFICIAL_INSTALL"; _pp.phaseLabel = "Downgrading packages";
            _pp.subPhase = "L1_TABLE"; _pp.subPhaseLabel = "Reviewing package changes";
            mock._buildPackages();
            _pp.downloadsTotal = 0; _pp.totalDownloadBytes = 0;
        }},
        {name: "integrity", ms: 1400, enter: () => {
            _pp.subPhase = "L3_INTEGRITY"; _pp.subPhaseLabel = "Checking integrity";
        }, tick: (t) => {
            const steps = ["checking keys in keyring", "checking package integrity",
                           "loading package files", "checking for file conflicts",
                           "checking available disk space"];
            _pp.integrityStep = steps[Math.min(steps.length - 1, Math.floor(t * steps.length))];
        }},
        {name: "install", ms: 5000, enter: () => {
            _pp.subPhase = "L5_CHANGES"; _pp.subPhaseLabel = "Processing package changes";
            _pp.integrityStep = "";
        }, tick: (t) => mock._tickInstall(t)},
        {name: "hooks", ms: 2200, enter: () => {
            _pp.subPhase = "L6_POSTHOOKS"; _pp.subPhaseLabel = "Running post-transaction hooks";
            _pp.hooksTotal = 4; _pp.hooksStarted = 0; _pp.hooksDone = 0;
        }, tick: (t) => mock._tickHooks(t)},
        {name: "done", ms: 600, enter: () => {
            _pp.phase = "COMPLETE"; _pp.phaseLabel = "Update undone";
            _pp.subPhase = ""; _pp.subPhaseLabel = "";
            for (let i = 0; i < _pkgs.count; i++)
                if (_pkgs.get(i).state !== "failed") mock._setState(i, "installed", 100);
        }}
    ]
    readonly property var _updateScript: [
        {name: "auth", ms: 1400, enter: () => {
            _pp.phase = "INITIAL"; _pp.phaseLabel = "Authenticating";
            _be.passwordPrompt = false;
        }},
        {name: "sync", ms: 2200, enter: () => {
            _pp.phase = "DB_SYNC_1"; _pp.phaseLabel = "Synchronising databases";
            _pp.subPhase = ""; _pp.subPhaseLabel = "";
        }},
        {name: "aur-search", ms: 1600, enter: () => {
            _pp.phase = "AUR_SEARCH"; _pp.phaseLabel = "Searching AUR";
        }},
        {name: "resolve", ms: 2000, enter: () => {
            _pp.phase = "UPGRADE_LIST"; _pp.phaseLabel = "Resolving upgrades";
            mock._buildPackages();
        }},
        {name: "prompt-exclude", ms: 0, enter: () => {
            _pp.phase = "PROMPT_EXCLUDE"; _pp.phaseLabel = "Packages to exclude";
            mock._openPrompt("yay_exclude",
                '==> Packages to exclude: (eg: "1 2 3", "1-3", "^4" or repo name)', "");
        }},
        {name: "graph", ms: 1600, enter: () => {
            _pp.phase = "GROUPED_SUMMARY"; _pp.phaseLabel = "Building dependency graph";
        }},
        {name: "prompt-proceed", ms: 0, enter: () => {
            _pp.phase = "OFFICIAL_INSTALL"; _pp.subPhase = "L0_RESOLVE";
            _pp.phaseLabel = "Installing official packages";
            _pp.subPhaseLabel = "Resolving dependencies";
            mock._openPrompt("pacman_proceed", ":: Proceed with installation? [Y/n]", "Y");
        }},
        {name: "download", ms: 9000, enter: () => {
            _pp.subPhase = "L2_DOWNLOAD"; _pp.subPhaseLabel = "Downloading packages";
            _pp.downloadPct = 0; _pp.downloadsDone = 0;
        }, tick: (t) => mock._tickDownload(t)},
        {name: "integrity", ms: 1800, enter: () => {
            _pp.subPhase = "L3_INTEGRITY"; _pp.subPhaseLabel = "Checking integrity";
            _pp.downloadRate = ""; _pp.downloadEta = ""; _pp.currentDownloading = "";
        }, tick: (t) => {
            const steps = ["checking keys in keyring", "checking package integrity",
                           "loading package files", "checking for file conflicts",
                           "checking available disk space"];
            _pp.integrityStep = steps[Math.min(steps.length - 1,
                                     Math.floor(t * steps.length))];
        }},
        {name: "install", ms: 8000, enter: () => {
            _pp.subPhase = "L5_CHANGES"; _pp.subPhaseLabel = "Processing package changes";
            _pp.integrityStep = "";
        }, tick: (t) => mock._tickInstall(t)},
        {name: "hooks", ms: 3000, enter: () => {
            _pp.subPhase = "L6_POSTHOOKS"; _pp.subPhaseLabel = "Running post-transaction hooks";
            _pp.hooksTotal = 8;
        }, tick: (t) => mock._tickHooks(t)},
        {name: "kernel", ms: 2600, enter: () => {
            _pp.subPhase = "L6_POSTHOOKS"; _pp.subPhaseLabel = "Rebuilding initramfs";
            _pp.currentInitramfsKernel = "linux";
            _initramfs.clear(); _initramfs.append({kernel: "linux", preset: "default"});
        }, tick: (t) => {
            const hooks = ["base", "udev", "modconf", "keyboard", "block", "filesystems"];
            _pp.currentInitramfsHook = hooks[Math.min(hooks.length - 1,
                                       Math.floor(t * hooks.length))];
        }},
        {name: "aur-build", ms: 6000, enter: () => {
            _pp.phase = "AUR_BUILD_LOOP"; _pp.phaseLabel = "Building AUR packages";
            _pp.subPhase = ""; _pp.subPhaseLabel = "";
            // The post-transaction hooks are all through once the AUR builds
            // start, the mkinitcpio one included.
            _pp.hooksDone = _pp.hooksTotal;
            _pp.currentInitramfsKernel = ""; _pp.currentInitramfsHook = "";
        }, tick: (t) => mock._tickAur(t)},
        {name: "done", ms: 600, enter: () => {
            _pp.phase = "COMPLETE"; _pp.phaseLabel = "Update complete";
            _pp.subPhase = ""; _pp.subPhaseLabel = "";
            _pp.currentAurBuild = ""; _pp.currentAurBuildStep = "";
            for (let i = 0; i < _pkgs.count; i++)
                if (_pkgs.get(i).state !== "failed") mock._setState(i, "installed", 100);
        }}
    ]

    // ---- Per-phase tick behaviour ----
    function _tickDownload(t) {
        const n = _pkgs.count;
        if (n === 0) return;
        // Twenty concurrent downloads, sliding through the list — the same
        // shape ParallelDownloads produces, so the list's motion under a real
        // run and under the mock look alike.
        const lead = t * (n + 20);
        let done = 0;
        for (let i = 0; i < n; i++) {
            const local = Math.max(0, Math.min(1, (lead - i) / 20));
            const pct = Math.round(local * 100);
            const cur = _pkgs.get(i);
            if (cur.state === "installed" || cur.state === "failed") continue;
            if (pct <= 0) continue;
            if (cur.dlPct !== pct) {
                _pkgs.setProperty(i, "dlPct", pct);
                _pkgs.setProperty(i, "dlRate", (120 + (i * 37) % 900) + " KiB/s");
                _pkgs.setProperty(i, "dlEta", "0" + (1 + i % 5) + ":"
                                  + (10 + (i * 13) % 50));
                const st = pct >= 100 ? "downloaded" : "downloading";
                if (cur.state !== st) _pkgs.setProperty(i, "state", st);
                _pp.packageProgress(cur.name, st, pct);
            }
            if (pct >= 100) done++;
            else if (pct > 0) _pp.currentDownloading = cur.name;
        }
        _pp.downloadsDone = done;
        _pp.downloadPct = Math.round(t * 100);
        _pp.downloadSoFar = (t * 3.4).toFixed(1) + " GiB";
        _pp.downloadRate = (6 + (t * 9) % 7).toFixed(1) + " MiB/s";
        const rem = Math.max(0, Math.round((1 - t) * 320));
        _pp.downloadEta = "0" + Math.floor(rem / 60) + ":"
                        + (rem % 60 < 10 ? "0" : "") + (rem % 60);
    }

    function _tickInstall(t) {
        const n = _pkgs.count;
        const upto = Math.floor(t * n);
        for (let i = 0; i < n; i++) {
            const cur = _pkgs.get(i);
            if (i < upto) {
                if (cur.state !== "installed" && cur.state !== "failed")
                    mock._setState(i, "installed", 100);
            } else if (i === upto) {
                if (cur.state !== "installing" && cur.state !== "failed") {
                    mock._setState(i, "installing", 0);
                    _pp.currentInstalling = cur.name;
                }
            }
        }
        _pp.installsDone = Math.min(n, upto);
    }

    function _tickHooks(t) {
        const hooks = ["Creating temporary files", "Reloading user manager configuration",
                       "Arming ConditionNeedsUpdate", "Updating GIO module cache",
                       "Compiling GSettings XML schema files", "Updating icon theme caches",
                       "Reloading GVFS config", "Updating the desktop file MIME type cache"];
        const i = Math.min(hooks.length - 1, Math.floor(t * hooks.length));
        // pacman announces a hook when it STARTS: hook i+1 runs, i are done.
        _pp.hooksStarted = i + 1;
        _pp.hooksDone = i;
        _pp.currentHook = hooks[i];
    }

    function _tickAur(t) {
        const aur = [];
        for (let i = 0; i < _pkgs.count; i++)
            if (_pkgs.get(i).isAur) aur.push(i);
        if (aur.length === 0) return;
        const steps = ["retrieving sources", "checking sha256sums",
                       "building", "packaging"];
        const pos = t * aur.length;
        const which = Math.min(aur.length - 1, Math.floor(pos));
        const frac = pos - which;
        for (let k = 0; k < aur.length; k++) {
            const i = aur[k];
            if (k < which) {
                if (_pkgs.get(i).state !== "built") mock._setState(i, "built", 100);
            } else if (k === which) {
                if (_pkgs.get(i).state !== "building") mock._setState(i, "building", 0);
                _pp.currentAurBuild = _pkgs.get(i).name;
                _pp.currentAurBuildStep =
                    steps[Math.min(steps.length - 1, Math.floor(frac * steps.length))];
            }
        }
        // At the end of the step every build is finished, including the one
        // still marked current mid-tick.
        _pp.aurBuildsDone = t >= 1 ? aur.length : which;
    }

    // =================================================================
    //  Prompts
    // =================================================================
    function _openPrompt(kind, text, def) {
        // Not pausing: the run plays through as if the prompt were answered.
        if (!mock.pauseOnPrompt) return;
        _pp.currentPromptKind = kind;
        _pp.currentPromptText = text;
        _pp.currentPromptDefault = def;
        _pp.awaitingUserInput = true;
        _be.awaitingInput = true;
        _be.lastPrompt = text;
        if (mock.pauseOnPrompt) {
            _timer.running = false;
            if (mock.promptAutoAnswerMs > 0) _promptTimer.restart();
        }
    }
    function _closePrompt() {
        _promptTimer.stop();
        _pp.awaitingUserInput = false;
        _pp.currentPromptKind = "";
        _pp.currentPromptText = "";
        _pp.currentPromptDefault = "";
        _be.awaitingInput = false;
        _be.lastPrompt = "";
    }
    function answerPrompt(text) {
        _pp.awaitingUserInput = false;
        _pp.currentPromptKind = "";
        _pp.currentPromptText = "";
        _be.awaitingInput = false;
        _be.lastPrompt = "";
        if (_be.running) { _timer.running = true; mock._advance(); }
    }

    // =================================================================
    //  Playback
    // =================================================================
    function start() {
        mock.reset();
        _be.running = true;
        mock._idx = -1;
        mock._advance();
        _timer.running = true;
    }
    function stop() {
        _timer.running = false;
        _be.running = false;
        _be.awaitingInput = false;
        _pp.awaitingUserInput = false;
    }
    function reset() {
        _timer.running = false;
        _be.running = false;
        _pkgs.clear(); _errs.clear(); _initramfs.clear(); _dkms.clear();
        _pp.phase = "INITIAL"; _pp.phaseLabel = "Idle";
        _pp.subPhase = ""; _pp.subPhaseLabel = "";
        _pp.errorCount = 0;
        _pp.downloadsDone = 0; _pp.downloadsTotal = 0; _pp.downloadPct = -1;
        _pp.downloadRate = ""; _pp.downloadEta = ""; _pp.downloadSoFar = "";
        _pp.currentDownloading = ""; _pp.currentInstalling = "";
        _pp.installsDone = 0; _pp.installsTotal = 0;
        _pp.hooksDone = 0; _pp.hooksStarted = 0; _pp.hooksTotal = 0; _pp.currentHook = "";
        _pp.aurBuildsDone = 0; _pp.aurBuildsTotal = 0;
        _pp.currentAurBuild = ""; _pp.currentAurBuildStep = "";
        _pp.integrityStep = "";
        _pp.snapshotState = ""; _pp.snapshotProgress = -1; _pp.snapshotCode = "";
        _pp.snapshotText = ""; _pp.snapshotShort = "";
        _pp.currentInitramfsKernel = ""; _pp.currentInitramfsHook = "";
        _pp.awaitingUserInput = false; _pp.currentPromptKind = "";
        _be.awaitingInput = false; _be.passwordPrompt = false; _be.lastPrompt = "";
        mock._idx = -1; mock._t = 0;
    }

    // Jump straight to a step and hold it there, for looking at one state.
    function gotoStep(i) {
        if (i < 0 || i >= mock._script.length) return;
        if (!_be.running) { mock.reset(); _be.running = true; }
        // The replay below rebuilds package state from scratch, so the error
        // list has to be cleared with it. Otherwise scrubbing away from a
        // failed step and back adds a second copy of the same error each time.
        _errs.clear();
        _pp.errorCount = 0;
        // Run every earlier step's enter() so the state that step depends on
        // exists — jumping to "install" without "resolve" would show a run
        // with no packages in it.
        for (let k = 0; k <= i; k++) {
            const st = mock._script[k];
            if (st.enter) st.enter();
            if (k < i) {
                if (st.tick) st.tick(1);
                // A prompt belonging to a step we are scrubbing PAST counts as
                // already answered. Without this the banner from an earlier
                // prompt stays open over every later phase, because replaying
                // enter() reopens it and nothing closes it again.
                mock._closePrompt();
            }
        }
        mock._idx = i;
        mock._t = 0;
        mock._stepMs = 0;
        if (mock._script[i].tick) mock._script[i].tick(0);
        // Failure injection has to work when SCRUBBING as well as when
        // playing: holding a failed state still is exactly the thing that is
        // impossible to review in a real run.
        if (mock.failAtStep.length > 0 && mock._script[i].name === mock.failAtStep)
            mock._injectFailure();
    }

    function _advance() {
        if (mock._idx >= 0 && mock._idx < mock._script.length) {
            const cur = mock._script[mock._idx];
            if (cur.tick) cur.tick(1);
        }
        mock._idx += 1;
        mock._t = 0;
        mock._stepMs = 0;
        if (mock._idx >= mock._script.length) {
            _timer.running = false;
            _be.running = false;
            mock.finished();
            return;
        }
        const st = mock._script[mock._idx];
        if (st.enter) st.enter();
        if (mock.failAtStep.length > 0 && st.name === mock.failAtStep)
            mock._injectFailure();
        if (st.tick) st.tick(0);
        if (st.ms === 0 && !_pp.awaitingUserInput) mock._advance();
    }

    function _injectFailure() {
        // The snapshot hook failed: pacman stops before it changes a package, and nothing runs after it.
        if (mock._script[mock._idx].name === "snapshot") {
            _pp.snapshotState = "failed"; _pp.snapshotCode = "space";
            _pp.snapshotText = "4.2 GB free after the update, 10 GB needed";
            _errs.append({
                pkg: "snapshot",
                reason: "Not enough free disk space for a snapshot: " + _pp.snapshotText
            });
            _pp.errorCount = _errs.count;
            _pp.phase = "FAILED"; _pp.phaseLabel = mock.undo ? "Undo failed" : "Update failed";
            _timer.running = false;
            _be.running = false;
            return;
        }
        // The parser's shape ({pkg, reason}); the popup's error rows read
        // exactly those two fields, and {line, context} would show as blanks.
        _errs.append({
            pkg: mock._script[mock._idx].name,
            reason: "error: failed to commit transaction (conflicting files)"
        });
        _pp.errorCount = _errs.count;
        for (let i = 0; i < _pkgs.count; i++) {
            if (_pkgs.get(i).state !== "installed") { mock._setState(i, "failed", 0); break; }
        }
    }

    Timer {
        id: _promptTimer
        interval: mock.promptAutoAnswerMs
        repeat: false
        onTriggered: if (_pp.awaitingUserInput) mock.answerPrompt("")
    }

    Timer {
        id: _timer
        interval: 33
        repeat: true
        running: false
        onTriggered: {
            if (mock._idx < 0 || mock._idx >= mock._script.length) return;
            if (_pp.awaitingUserInput) return;
            const st = mock._script[mock._idx];
            if (st.ms <= 0) { mock._advance(); return; }
            mock._stepMs += interval * Math.max(0.05, mock.speed);
            mock._t = Math.min(1, mock._stepMs / st.ms);
            if (st.tick) st.tick(mock._t);
            if (mock._t >= 1) mock._advance();
        }
    }
}
