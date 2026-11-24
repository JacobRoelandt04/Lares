pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/components/Bytes.js" as Bytes
import "SystemUpdateWork.js" as Work

// =============================================================================
// PackageUpdateParser.qml
//
// Headless state-machine consumer of a TerminalBackend.lineAppended stream.
// Recognises the phases of `yay -Syu` (documented in
// docs/contracts/system_update_phases.md §1-2) and exposes them as bindable QML
// state + a handful of ListModels that a popup UI can render.
//
// Non-visual by design. Drop into any scene, bind `backend` to a running
// TerminalBackend, read `phase` / `phaseLabel` / `packages` / `errors` / etc.
//
// Phases (top-level IDs mirror the reference doc):
//   INITIAL, DB_SYNC_1, AUR_SEARCH, UPGRADE_LIST, PROMPT_EXCLUDE,
//   GROUPED_SUMMARY, PKGBUILD_CACHE, PROMPT_CLEANBUILD, PROMPT_DIFFS,
//   AUR_SRC_FETCH, SRCINFO_PARSE, DB_SYNC_2, OFFICIAL_INSTALL,
//   AUR_BUILD_LOOP, AUR_INSTALL, FINAL_ERRORS, FAILED, COMPLETE
//
// Sub-phases within OFFICIAL_INSTALL / AUR_INSTALL track pacman's inner steps:
//   L0_RESOLVE, L1_TABLE, L2_DOWNLOAD, L3_INTEGRITY, L4_PREHOOKS,
//   L5_CHANGES, L6_POSTHOOKS, N0_LOAD, N1_TABLE, N3_INTEGRITY,
//   N5_CHANGES, N6_POSTHOOKS
// =============================================================================
Item {
    id: root

    // Required: a TerminalBackend instance whose lineAppended we listen to.
    property var backend: null

    // What the run is: "update" (yay -Syu) or "undo" (`pacman -U` of the packages a snapshot's
    // undo plan names). An INPUT, set by the host before the run starts, so reset() leaves it:
    // an undo prints "loading packages..." first, which an update reads as its AUR install, and
    // its table rows have no repo column, which an update reads as AUR packages.
    property string runKind: "update"

    // ---- Top-level state (read-only to consumers) ----
    property string phase: "INITIAL"
    property string phaseLabel: "Waiting…"
    property string subPhase: ""
    property string subPhaseLabel: ""

    // ---- Counters ----
    property int totalPackages: 0           // from ":: N packages to upgrade"

    // Download (L.2)
    property int downloadsDone: 0
    property int downloadsTotal: 0
    property string currentDownloading: ""
    // EVERY package pacman has in flight, in the order they started.
    //
    // `currentDownloading` is whichever row was printed last, and with
    // ParallelDownloads = 20 pacman prints a row per file several times a
    // second: the single name flips between all twenty, so anything showing
    // it flickers through the whole set. The list is what a view should show.
    //
    // Kept as a whole-array reassignment (a `var` mutated in place notifies
    // nothing) but only when the SET changes -- a package starting or
    // finishing -- not on the progress rows in between, which is what keeps
    // it off the hot path.
    property var downloadingNames: []
    property var _dlInFlight: ({})
    // Aggregate telemetry from the "Total (n/m)" row: bytes so far, combined
    // throughput, ETA and percent. The rail shows these; the list shows the
    // per-package equivalents.
    property string downloadSoFar: ""
    property string downloadRate: ""
    property string downloadEta: ""
    property int    downloadPct: -1
    // pacman's own summary of the transaction, in bytes: "Total Download
    // Size:", "Total Installed Size:" and "Net Upgrade Size:" (negative when
    // the upgrade shrinks the install). Each line overwrites when pacman
    // prints it again for the AUR install pass -- the value describes the
    // transaction being reviewed, the same way installsTotal does.
    property real totalDownloadBytes: 0

    // Integrity checks (L.3 / N.3) — just the label moves, each 100%
    property string integrityStep: ""

    // Install (L.5 / N.5)
    // Same shape as the hooks below: the live "(n/m) upgrading X" row is
    // package n STARTING, so n-1 are done; the newline-terminated 100% copy
    // of that row is what makes it n. Reading the live row as done would show
    // 157/157 with a full groove while shellcheck is still unpacking.
    property int installsDone: 0
    property int installsStarted: 0
    property int installsTotal: 0
    property string currentInstalling: ""

    // Hooks (L.4 / L.6 / N.6)
    // pacman prints "(n/m) Hook name..." when a hook STARTS. So `hooksDone`
    // is the number COMPLETED (n - 1 while hook n runs, m once the phase
    // ends) and `hooksStarted` is n; a counter that read n as done would show
    // "2/2" with a full groove while the second hook still has ten seconds
    // of DKMS work to do.
    property int hooksDone: 0
    property int hooksStarted: 0
    property int hooksTotal: 0
    property string currentHook: ""

    // AUR builds (M)
    property int aurBuildsDone: 0
    property int aurBuildsTotal: 0
    property string currentAurBuild: ""
    property string currentAurBuildStep: ""     // fetching|preparing|compiling|packaging|...
    // AUR source fetch (the first half of the AUR work, before the official
    // transaction): makepkg downloads each package's sources with curl, and
    // curl's progress meter is the only figure that phase prints. Read per
    // repaint, like pacman's download rows.
    property int    aurSourcesDone: 0             // packages whose sources are in
    property string sourceFetchFile: ""           // file curl is on
    property int    sourceFetchPct: -1            // of that file; -1 = none live
    property real   sourceFetchBytesDone: 0
    property real   sourceFetchBytesTotal: 0
    property string sourceFetchRate: ""           // "3.6 MiB/s"
    property string sourceFetchEta: ""            // "00:09"
    // Bytes already on disk for the file curl is fetching. `curl -C -` resumes
    // a partial download and then reports the RANGE it is fetching as the
    // Total, not the file's size -- a ~54 MiB source resumed at 42.4 MiB is
    // called 13.68M by curl, so the row would be sized wrong and hit
    // 100% in a second. Added back to both figures for the rest of that file.
    property real   _curlResumeOffset: 0
    // The official transaction's package changes have run. makepkg prints
    // "Making package" twice per AUR package -- once to fetch its sources
    // before the transaction, once to build it after -- and the state of
    // the package row alone could not tell them apart when the row had been
    // dropped and re-added in between.
    property bool _pastOfficialInstall: false
    // The AUR half's second act has begun: pacman has been told to proceed
    // with the built packages. Latched, because the reset it triggers must
    // happen once and must not be replayed by a later sub-phase.
    property bool _aurInstallReset: false
    // The size of the transaction pacman is ABOUT to run, read from its own
    // table header ("Package (1)  Old Version ..."). A mixed run has TWO
    // transactions, and the install counter would carry the official one's
    // total into the AUR one ("installing yyjson 0 / 44" while pacman is
    // installing one AUR package) until the first "(1/1) upgrading" line corrects it.
    property int _txnTotal: 0
    // pacman's list under ":: The following packages cannot be upgraded due
    // to unresolvable dependencies:" -- exactly what yay's "skip the above
    // packages" question is about.
    property var _unresolvable: []
    property bool _unresolvableCapture: false

    // Initramfs rebuild (L.6.b sub-output)
    property string currentInitramfsKernel: ""
    property string currentInitramfsHook: ""

    // DKMS (L.4 / L.6.a sub-output)
    property string currentDkmsOp: ""           // human-readable snapshot
    // Upper bound on a line that could plausibly be a package-table row.
    // Anything longer is redraw noise and is not worth running the pattern on.
    property int maxTableRowChars: 400
    property int maxProgressRowChars: 400

    // Prompt state. The scalar mirrors (`currentPromptKind` / `currentPromptText`
    // / `currentPromptDefault`) exist alongside the JS-object `currentPrompt`
    // because QML's binding tracker is unreliable when reading nested fields
    // off a `var` property — bind to the scalars in UI code instead.
    property var currentPrompt: null            // {kind, text, defaultValue} or null
    property string currentPromptKind: ""       // "" when no prompt active
    property string currentPromptText: ""
    property string currentPromptDefault: ""
    property bool awaitingUserInput: false

    // Errors
    property int errorCount: 0

    // ---- The snapshot hook (docs/contracts/snapshots.md section 7) ----
    // Before a large update a PreTransaction hook makes a snapshot and prints `lares-snapshot: ...`
    // lines inside pacman's "Running pre-transaction hooks" block. `subPhase` stays L4_PREHOOKS
    // through it (the hook counter and _closeHooks key on that); these say what the hook did.
    //   snapshotState     "" (no word yet) | "running" | "done" | "skipped" | "failed"
    //   snapshotProgress  0..1, -1 until the hook has said it started
    //   snapshotCode      skip / failed code ("small", "space", ...), "" otherwise
    //   snapshotText      what the hook said last that is for people: its `start` words
    //                     ("112 packages: linux, mesa"), a skip's or a failure's text
    //   snapshotShort     the snapshot's short id once done
    property string snapshotState: ""
    property real snapshotProgress: -1
    property string snapshotCode: ""
    property string snapshotText: ""
    property string snapshotShort: ""

    // ---- ListModels ----
    // state: queued -> downloading -> downloaded -> installed for an official
    // package; queued -> fetching -> sources-ready -> building -> built ->
    // staged -> installed for an AUR one.
    ListModel { id: _packages }            // {number, repo, name, oldVer, newVer, isAur, role, flavour, state, error}
    ListModel { id: _hooks }               // {name, phase, index, total}
    ListModel { id: _initramfsBuilds }     // {kernel, preset, hookCount, success}
    ListModel { id: _dkmsOps }             // {op, module, version, kernel}
    ListModel { id: _errors }              // {pkg, reason}
    // Everything the run said that was not an error and not progress: pacman's
    // warnings, makepkg's, yay's orphan / out-of-date notices, and a package's
    // own post-install note. Without a record a run could tell
    // the user to run `systemctl --user daemon-reload` and the only way to
    // learn of it would be to watch the terminal in verbose view at the
    // moment it scrolls past.
    ListModel { id: _notices }             // {text, kind}

    property alias packages: _packages
    property alias hooks: _hooks
    property alias errors: _errors
    property alias notices: _notices
    property int noticeCount: 0

    // ---- Signals (fire-and-forget for UI animations) ----
    // NOTE: avoid `phaseChanged` / `subPhaseChanged` names — QML auto-generates
    // xChanged signals for every property, and overriding them with a custom
    // signature errors at load.
    signal phaseEntered(string phaseId, string label)
    signal subPhaseEntered(string subId, string label)
    signal packageEvent(string name, string verb, string detail)
    signal promptOpened(string kind, string raw)
    signal promptClosed(string kind)

    // One package's live state moved. Carries the name so a view can update
    // exactly that row: binding a list to the model's dataChanged instead
    // would re-diff every package on every percent tick of every concurrent
    // download.
    signal packageProgress(string name, string state, int pct,
                           string rate, string eta)
    // Every built AUR package has been handed to pacman and is waiting to be
    // installed. Views use this to put the rows back to "not done yet", so
    // that being installed is something the eye can SEE happen rather than one
    // word changing.
    signal aurInstallReset()
    signal initramfsKernelStarted(string kernel)
    signal initramfsKernelEnded(string kernel, bool success)
    signal dkmsOpLogged(string op, string module, string version, string kernel)

    // ---- Private state ----
    property int _dbSyncCount: 0
    property var _pkgByName: ({})          // name → row index in _packages

    function _setPhase(id, label) {
        if (root.phase === id) return;
        if (root.phase === "AUR_SRC_FETCH") _finishSourceFetch();
        root.phase = id;
        root.phaseLabel = label;
        phaseEntered(id, label);
    }
    function _setSubPhase(id, label) {
        if (root.subPhase === id && root.subPhaseLabel === label) return;
        if (root.subPhase === "L2_DOWNLOAD" && id !== "L2_DOWNLOAD") root._finishDownload();
        if (id === "L5_CHANGES" || id === "L6_POSTHOOKS") root._pastOfficialInstall = true;
        // The AUR transaction has been approved -- integrity is the first
        // thing pacman does after "Proceed?" is answered. Ground truth, so a
        // replay, the verbose view's own buttons and a --noconfirm run all
        // reach it; the popup calls the same latched function from the
        // answer itself, purely so the rows react on the click.
        if (id === "N3_INTEGRITY" || id === "N5_CHANGES") root.resetAurForInstall();
        root.subPhase = id;
        root.subPhaseLabel = label;
        subPhaseEntered(id, label);
    }
    // Leaving the download sub-phase means every file is in. The last live
    // "Total" repaint is whatever the screen-row throttle happened to catch --
    // 99% with a package name still up, on the reference run -- so pin the
    // aggregate to its end state rather than let the rail sit on that.
    function _finishDownload() {
        root.downloadPct = 100;
        root.downloadRate = ""; root.downloadEta = "";
        root.currentDownloading = "";
        root._clearDownloading();
        if (root.downloadsTotal > 0) root.downloadsDone = root.downloadsTotal;
    }
    // Leaving the source fetch means every package's sources are in --
    // makepkg's verify-source pass ends without a line saying so.
    function _finishSourceFetch() {
        for (let i = 0; i < _packages.count; i++)
            if (_packages.get(i).state === "fetching") _packages.setProperty(i, "state", "sources-ready");
        root.aurSourcesDone = root.aurBuildsTotal;
        root.sourceFetchFile = ""; root.sourceFetchPct = -1;
        root.sourceFetchRate = ""; root.sourceFetchEta = "";
    }
    // pacman has taken the built packages into a transaction of its own. Until
    // it commits them they are BUILT BUT NOT INSTALLED, which is a different
    // thing from either -- so they get their own state rather than sitting on
    // "built" (which the AUR step reads as finished) or falling back to
    // "queued" (which _progressRow would promote to "installing" the moment
    // pacman merely STARTS a package, lighting every row one package early).
    function resetAurForInstall() {
        if (root._aurInstallReset) return;
        root._aurInstallReset = true;
        for (let i = _packages.count - 1; i >= 0; i--) {
            const p = _packages.get(i);
            if (!p.isAur) continue;
            if (p.state !== "built" && p.state !== "sources-ready") continue;
            root._update(p.name, {state: "staged"});
        }
        root.aurInstallReset();
    }
    // Deduped by its own text: makepkg prints the same two lines once per
    // package, and the same pacman warning can arrive for two kernels. `kind` is
    // where it came from as far as the prefix can say: "pacman", "aur" (yay's
    // own notices) or "tool" -- `==> WARNING:` is makepkg AND mkinitcpio AND
    // anything else with that prefix, so it does not claim more than it knows.
    property var _noticeSeen: ({})
    // While a package is being COMPILED the speaker on an unprefixed
    // "warning:" line is the build, not pacman. Read with the notice rules.
    readonly property bool _buildSpeaking: root.phase === "AUR_BUILD_LOOP"
    // Routine makepkg chatter that says nothing about THIS run. Listed
    // explicitly rather than filtered by a pattern, so adding to it is a
    // decision somebody made on purpose.
    readonly property var _noticeSkip: [
        "Using existing $srcdir/ tree",
        "Skipping verification of source file PGP signatures.",
        // Cargo says this while a build that has ALREADY failed winds its
        // other jobs down. The failure itself is reported as an error, with
        // the package and the exit status, so this is the same news twice.
        // The principle for this list: a
        // build tool talking to itself about a failure it is already
        // reporting is not a notice.
        "build failed, waiting for other jobs to finish..."
    ]
    function _addNotice(text, kind) {
        const t = String(text).trim();
        if (t.length === 0 || root._noticeSkip.indexOf(t) >= 0) return;
        if (root._noticeSeen[t]) return;
        root._noticeSeen[t] = true;
        _notices.append({text: t, kind: kind});
        root.noticeCount = _notices.count;
    }
    function _closePrompt() {
        if (!root.awaitingUserInput) return;
        const kind = root.currentPrompt ? root.currentPrompt.kind : "";
        root.awaitingUserInput = false;
        root.currentPrompt = null;
        root.currentPromptKind = "";
        root.currentPromptText = "";
        root.currentPromptDefault = "";
        // A stale context would outlive its question: the skip-dependency
        // prompt, seen only in the terminal's tail, would show the previous
        // question's lines and "skip" would then remove the wrong package.
        root.currentPromptContext = [];
        promptClosed(kind);
    }
    // The answer to "Packages to exclude", applied to the package list the
    // same way yay applies it: numbers and ranges name packages to drop, a
    // "^" prefix keeps those and drops the rest, and a bare word drops a
    // whole repo. Anything unparseable is ignored, as yay ignores it.
    function excludeSelection(text) {
        const toks = String(text || "").trim().split(/[\s,]+/).filter(t => t.length > 0);
        if (toks.length === 0) return;
        const drop = {}, keep = {}, repos = {};
        let invert = false;
        for (let t of toks) {
            let neg = false;
            if (t[0] === "^") { neg = true; invert = true; t = t.slice(1); }
            const m = t.match(/^(\d+)(?:-(\d+))?$/);
            if (m) {
                const lo = Number(m[1]), hi = m[2] !== undefined ? Number(m[2]) : lo;
                for (let n = Math.min(lo, hi); n <= Math.max(lo, hi); n++) (neg ? keep : drop)[n] = true;
            } else if (/^[a-z0-9_-]+$/i.test(t)) {
                repos[t.toLowerCase()] = true;
            }
        }
        for (let i = _packages.count - 1; i >= 0; i--) {
            const r = _packages.get(i);
            const num = r.number || 0;
            let gone = false;
            if (invert) gone = num > 0 && !keep[num];
            else if (num > 0 && drop[num]) gone = true;
            if (!gone && r.repo && repos[String(r.repo).toLowerCase()]) gone = true;
            if (gone) _packages.remove(i);
        }
        // Rows moved; the name -> index map has to follow, or the next
        // "Packages (N)" table would update the wrong rows.
        const map = {};
        for (let i = 0; i < _packages.count; i++) map[_packages.get(i).name] = i;
        root._pkgByName = map;
    }

    // pacman prints no "hooks finished" line; the phase ends when the next
    // thing starts. Whoever moves on calls this so hooksDone reaches m and
    // the hook sub-phase stops answering for the header.
    function _closeHooks() {
        if (root.subPhase !== "L4_PREHOOKS" && root.subPhase !== "L6_POSTHOOKS" && root.subPhase !== "N6_POSTHOOKS") return;
        root.hooksDone = root.hooksTotal;
        root.currentHook = "";
        root.currentDkmsOp = ""; root.currentInitramfsKernel = ""; root.currentInitramfsHook = "";
        _setSubPhase("", "");
    }

    // The process is gone; nothing else will arrive to close what is open.
    // pacman prints no "hooks finished" line and nothing at all after the
    // last hook, so without this a clean run would end showing hook 3/3 still
    // running. Only a clean exit is completion: a failed run keeps its last
    // phase so the popup can show where it stopped.
    // One error per distinct (package, reason): pacman repeats a mirror
    // failure per file and per retry.
    property var _errorSeen: ({})
    function _addError(pkg, reason) {
        const key = pkg + "\u0000" + reason;
        if (root._errorSeen[key]) return;
        root._errorSeen[key] = true;
        _errors.append({pkg: pkg, reason: reason});
        root.errorCount = _errors.count;
    }

    // The exit status of the run, -1 until it has ended.
    property int exitCode: -1
    function finish(exitCode) {
        root.exitCode = exitCode;
        if (exitCode !== 0) {
            // The process said it failed. If no line above explained why,
            // the exit status is the explanation there is -- a run that
            // ends non-zero with an empty error list still ended non-zero,
            // and "Update complete" over it would be a lie.
            if (root.errorCount === 0)
                root._addError(root.runKind === "undo" ? "undo" : "yay", "exit status " + exitCode);
            if (root.phase !== "FINAL_ERRORS")
                _setPhase("FAILED", Work.endLabel(root.runKind, false));
            // The phase STAYS where it stopped -- that is the point of a
            // failed run -- but nothing is running any more, so nothing may
            // still be shown as running. The hook counter lags by one by
            // construction (pacman numbers a hook when it STARTS) and only
            // _closeHooks() ever catches it up, which a failed run never
            // reaches: the last frame would sit on "0 / 1
            // hooks" over a hook the transcript shows finishing. Settle it to
            // what STARTED, not to the total -- the hooks after it never ran.
            if (root.hooksStarted > root.hooksDone) root.hooksDone = root.hooksStarted;
            root.currentHook = "";
            root.currentDkmsOp = "";
            root.currentInitramfsKernel = ""; root.currentInitramfsHook = "";
            return;
        }
        _closeHooks();
        if (root.installsTotal > 0 && root.installsDone < root.installsTotal) {
            root.installsDone = root.installsTotal;
            root.installsStarted = root.installsTotal;
        }
        root.currentInstalling = "";
        _setSubPhase("", "");
        _setPhase("COMPLETE", Work.endLabel(root.runKind, true));
    }

    function _openPrompt(kind, text, defaultValue) {
        // The same question reaches here twice: once from the terminal's
        // tail (the line has no newline until it is answered) and once when
        // that line commits with the answer on it. The second is not a new
        // question.
        if (root.awaitingUserInput && root.currentPromptKind === kind) return;
        root.awaitingUserInput = true;
        // For the skip-dependency question the context IS pacman's list of
        // what cannot be upgraded, when it was seen; the warnings above it
        // repeat the same names a dozen times.
        root.currentPromptContext = (kind === "yay_skip_dep" && root._unresolvable.length > 0)
            ? [root._unresolvable.join("  ")]
            : root._recentLines.filter(l =>
            /^(warning|error|::|->|==>)/i.test(l) || /depend/i.test(l)
            // pacman lists "the following package" as an indented bare
            // name on its own line: that IS the package the question means.
            || /^[A-Za-z0-9@._+-]+(\s+[\d.:+-]+)*$/.test(l)).slice(-5);
        root.currentPrompt = {kind: kind, text: text, defaultValue: defaultValue};
        root.currentPromptKind = kind;
        root.currentPromptText = text;
        root.currentPromptDefault = defaultValue;
        promptOpened(kind, text);
    }
    // "15.15 MiB" -> bytes. Kept on the parser as a thin wrapper so a view
    // holding a parser reference can convert without its own import; the
    // arithmetic lives in Bytes.js where the formatters can share it.
    function parseSize(text) { return Bytes.parseSize(text); }

    function _findOrAdd(name, data) {
        if (name in root._pkgByName) {
            // Known already -- nearly always, since yay's upgrade list names
            // every package before pacman's table does. The table is where
            // the sizes come from, so its fields have to land on the existing
            // row; returning without them would leave dlBytes at 0 for every package
            // of every run.
            if (data) root._update(name, data);
            return root._pkgByName[name];
        }
        const base = {
            number: 0, repo: "", name: name, oldVer: "", newVer: "",
            isAur: false, role: "unknown", flavour: "binary",
            state: "queued", error: "",
            // Per-package download telemetry, filled from the live screen rows.
            dlPct: 0, dlRate: "", dlEta: "", dlSoFarBytes: 0,
            // Sizes as pacman printed them and in BYTES, parsed once here
            // rather than re-parsed from the display strings every time a
            // view wants to weight progress by data rather than by package
            // count. Every role is declared on the first append: a ListModel
            // fixes its role set from that row, and a later setProperty on an
            // unknown role would be dropped.
            netChange: "", downloadSize: "", dlBytes: 0, netBytes: 0
        };
        for (const k in data) base[k] = data[k];
        _packages.append(base);
        const idx = _packages.count - 1;
        root._pkgByName[name] = idx;
        if (base.newVer) root._indexFile(name, base.newVer);
        return idx;
    }
    function _update(name, data) {
        const idx = root._pkgByName[name];
        if (idx === undefined) return;
        for (const k in data) _packages.setProperty(idx, k, data[k]);
        if (data.newVer) root._indexFile(name, data.newVer);
        if (data.state !== undefined) {
            const pct = data.state === "installed" || data.state === "built" ? 100 : 0;
            root.packageProgress(name, data.state, pct, "", "");
        }
    }

    // Download rows identify a package by its FILE name, which is exactly
    // `<name>-<newVer>-<arch>`. Reconstructing the key from the version we
    // already hold is exact; splitting the filename back apart with a regex is
    // not, because both name and version may contain hyphens
    // (`libyuv-r2921+644251f25-1-x86_64` has no unambiguous split point).
    property var _fileToPkg: ({})
    function _indexFile(name, newVer) {
        root._fileToPkg[name + "-" + newVer] = name;
    }

    function reset() {
        _setPhase("INITIAL", "Waiting…");
        _setSubPhase("", "");
        root._dbSyncCount = 0;
        root._pkgByName = ({});
        root._fileToPkg = ({});
        root._truncCache = ({});
        root.totalPackages = 0;
        root.downloadsDone = 0; root.downloadsTotal = 0; root.currentDownloading = "";
        root._clearDownloading();
        root.downloadSoFar = ""; root.downloadRate = "";
        root.downloadEta = ""; root.downloadPct = -1;
        root._dlWriteAt = ({});
        root.totalDownloadBytes = 0;
        root.integrityStep = "";
        root.installsDone = 0; root.installsStarted = 0; root.installsTotal = 0;
        root.currentInstalling = "";
        root.hooksDone = 0; root.hooksStarted = 0; root.hooksTotal = 0; root.currentHook = "";
        root.aurBuildsDone = 0; root.aurBuildsTotal = 0;
        root.currentAurBuild = ""; root.currentAurBuildStep = "";
        root.aurSourcesDone = 0; root.sourceFetchFile = ""; root.sourceFetchPct = -1;
        root.sourceFetchBytesDone = 0; root.sourceFetchBytesTotal = 0;
        root.sourceFetchRate = ""; root.sourceFetchEta = "";
        root._curlResumeOffset = 0;
        root._pastOfficialInstall = false;
        root._aurInstallReset = false;
        root._txnTotal = 0;
        root._unresolvable = []; root._unresolvableCapture = false;
        root.currentInitramfsKernel = ""; root.currentInitramfsHook = "";
        root.currentDkmsOp = "";
        root.awaitingUserInput = false; root.currentPrompt = null;
        root.currentPromptKind = "";
        root.currentPromptText = "";
        root.currentPromptDefault = "";
        root.errorCount = 0;
        root._errorSeen = ({});
        root.snapshotState = ""; root.snapshotProgress = -1;
        root.snapshotCode = ""; root.snapshotText = ""; root.snapshotShort = "";
        root.exitCode = -1;
        root.noticeCount = 0;
        root._noticeSeen = ({});
        _packages.clear(); _hooks.clear();
        _initramfsBuilds.clear(); _dkmsOps.clear(); _errors.clear();
        _notices.clear();
    }

    // Handle an in-place progress render — text that has been drawn but not
    // terminated with a newline.
    //
    // pacman's parallel-download block never emits a newline for the whole
    // download phase (one 1.5 MB "line" in the reference capture), so the
    // aggregate "Total (n/m)" counter and the per-file rows are invisible to
    // line-based parsing. Without this the UI shows no download progress at
    // all for several minutes of a real run.
    //
    // Deliberately narrow: only progress counters are read here. It must not
    // open or close prompts or advance phases, because this text is a partial
    // render that may be rewritten a thousand times a second.
    // curl's progress meter, as makepkg shows it while retrieving a source:
    //   "  2 89.74M   2  2.58M   0      0  1.99M      0   00:44   00:01   00:43  2.58M"
    // % total, total, % received, received, % xferd, xferd, average down,
    // average up, time total, time spent, time left, current speed. Sizes
    // are 1024-based with k/M/G suffixes. Only meaningful while an AUR
    // package is fetching; the figures go to the phase and to that
    // package's row, gated on the bytes moving like pacman's rows are.
    function _curlSize(t) {
        const m = String(t).match(/^([\d.]+)([kMGT])?$/);
        if (!m) return 0;
        const mult = {k: 1024, M: 1048576, G: 1073741824, T: 1099511627776};
        return parseFloat(m[1]) * (m[2] ? mult[m[2]] : 1);
    }
    function _curlRow(line) {
        if (root.phase !== "AUR_SRC_FETCH" && root.phase !== "AUR_BUILD_LOOP") return false;
        const m = line.match(/^\s*(\d+)\s+([\d.]+[kMGT]?)\s+(\d+)\s+([\d.]+[kMGT]?)\s+\d+\s+\S+\s+(\S+)\s+\S+\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*$/);
        if (!m) return false;
        // The resume offset is part of both the file and what is already in
        // hand, so the percentage curl prints is of the RANGE and has to be
        // recomputed against the whole file.
        const off = root._curlResumeOffset;
        const total = root._curlSize(m[2]) + off;
        const got = root._curlSize(m[4]) + off;
        const pct = total > 0
            ? Math.max(0, Math.min(100, Math.round(got / total * 100)))
            : Math.max(0, Math.min(100, parseInt(m[3])));
        const speed = root._curlSize(m[9]);
        const rate = speed > 0 ? Bytes.formatBytes(speed) + "/s" : "";
        const eta = m[8].indexOf("-") >= 0 ? "" : m[8].replace(/^0:/, "");
        root.sourceFetchPct = pct;
        root.sourceFetchBytesDone = got;
        root.sourceFetchBytesTotal = total;
        root.sourceFetchRate = rate;
        root.sourceFetchEta = eta;
        const name = root.currentAurBuild;
        if (name && (name in root._pkgByName)) {
            const idx = root._pkgByName[name];
            const cur = _packages.get(idx);
            const moved = pct !== cur.dlPct || got !== cur.dlSoFarBytes;
            if (moved || rate !== cur.dlRate || eta !== cur.dlEta) {
                _packages.setProperty(idx, "dlPct", pct);
                _packages.setProperty(idx, "dlSoFarBytes", got);
                if (total > 0) _packages.setProperty(idx, "dlBytes", total);
                _packages.setProperty(idx, "dlRate", rate);
                _packages.setProperty(idx, "dlEta", eta);
                root.packageProgress(name, "fetching", pct, rate, eta);
            }
        }
        return true;
    }

    // A yes/no question sits in the terminal's TAIL until it is answered:
    // the line has no newline, so it never reaches processLine while it
    // matters. The backend's preview carries it; open the question from
    // there, with the context that is current NOW.
    function processPromptTail(raw) {
        if (raw == null || root.awaitingUserInput) return;
        const t = String(raw).replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").trim();
        if (!/\[[yY]\/[nN]\]\s*[:?]?\s*$/.test(t)) return;
        root._matchYesNoPrompt(t);
    }
    // The yes/no questions, from the tail or from the committed line (which
    // then carries the echoed answer after the "[y/N]").
    function _matchYesNoPrompt(line) {
        if (line.match(/Proceed with install/i) && line.match(/\[Y\/n\]/i)) {
            _openPrompt("pacman_proceed", "Proceed with install", "Y");
            return true;
        }
        if (line.match(/skip the above package/i)) {
            _openPrompt("yay_skip_dep", "Do you want to skip the above packages for this upgrade", "N");
            return true;
        }
        // yay asks with "::", makepkg with "==>": a matcher that accepts only one
        // drops the other. "Remove make dependencies after install? [y/N]" would
        // open no prompt here at all: the popup's own tail backstop would see the
        // [y/N] and show a yes/no banner, but with no text behind it the title would
        // fall through to the literal word "Question" and neither button would be
        // marked as yay's default. Both prefixes are accepted, and a bare question
        // too -- the [y/N] at the end is what identifies it.
        const m = line.match(/^(?:::|==>|->)?\s*(.+?)\s*\[([yY]\/[nN])\]\s*[yYnN]?\s*$/);
        if (m) {
            const def = m[2].match(/^[Y]/) ? "Y" : "N";
            _openPrompt("yay_yesno", m[1].replace(/\?$/, "").trim(), def);
            return true;
        }
        return false;
    }

    function processProgress(raw) {
        if (raw == null) return;
        // The preview is a snapshot of several rendered rows; walk them all so
        // the aggregate row is not missed just because a per-file row happened
        // to be drawn last.
        const rows = String(raw).split("\n");
        for (let i = 0; i < rows.length; i++) root._progressRow(rows[i]);
    }

    function _progressRow(raw) {
        // Length guard, same reason as the package table: a progress row is a
        // short, fixed-shape line. The lazy `(\S+?)` in the per-file pattern
        // backtracks catastrophically over a multi-kilobyte redraw segment,
        // which is enough to lock the UI thread outright.
        if (raw == null || raw.length > root.maxProgressRowChars) return;
        let line = String(raw);
        line = line.replace(/\x1b\[[0-9;?]*[ -\/]*[@-~]/g, "");
        line = line.replace(/\s+$/, "");
        if (line.length === 0) return;

        // Aggregate download progress: " Total ( 16/212) 2020.5 MiB ... 58%"
        if (root._readTotalRow(line)) return;
        // curl's meter during a source fetch, redrawn in place.
        if (root._curlRow(line)) return;
        // Per-package download row, the full shape:
        //   " jdk-openjdk-26.0.2.1.u1-1-x86_64   8.3 MiB   483 KiB/s 13:48 [#--] 2%"
        // Name, bytes received, rate, ETA, bar, percent — per package, for all
        // of them (verified against the reference capture: 212/212 packages
        // reach 100%). Runs BEFORE the loose per-file branch below, which only
        // recognises the enqueue burst and would otherwise swallow these.
        // The ETA is "--:--" until the first rate sample; that row still
        // carries a byte count worth recording.
        {
            const m = line.match(
                /^\s*(\S+)\s+([\d.]+\s*[KMGT]?i?B)\s+([\d.]+\s*[KMGT]?i?B\/s)\s+(\d+:\d+|--:--)\s+\[[#\-]*\]\s+(\d+)%$/);
            if (m) {
                root._applyDownloadRow(m[1], m[2], m[3], m[4] === "--:--" ? "" : m[4], parseInt(m[5]));
                return;
            }
        }
        // Per-file row: " <pkg>-<ver>-<arch>  150.1 MiB  2.47 MiB/s 03:52 [...] 20%"
        {
            const m = line.match(/^\s*(\S+?)(?:\.pkg\.tar\.\w+)?\s+\d[\d.]*\s*[KMG]iB\s/);
            if (m && root.downloadsTotal > 0) {
                root._noteDownloading(m[1]);
                return;
            }
        }
        // Live install / hook counters, redrawn in place between newlines.
        {
            const m = line.match(/^\(\s*(\d+)\/\s*(\d+)\)\s+(upgrading|installing|reinstalling|removing|downgrading)\s+(\S+)/);
            if (m) {
                const n = parseInt(m[1]);
                // The live row names the package being worked on NOW, so n-1
                // are done; the committed 100% copy (processLine) makes it n.
                // Never stepped backwards: a screen-row batch can still carry
                // row n after its committed line has already counted it.
                root.installsStarted = Math.max(root.installsStarted, n);
                root.installsDone = Math.max(root.installsDone, n - 1);
                root.installsTotal = parseInt(m[2]);
                root.currentInstalling = m[4];
                // The in-place render is the package being worked on NOW; the
                // newline-terminated copy of the same line at 100% is what
                // marks it installed. Without this a package would go straight
                // from queued to installed and never be shown as active.
                const cur = root._pkgByName[m[4]];
                if (cur !== undefined) {
                    const st = _packages.get(cur).state;
                    if (st === "queued" || st === "downloading" || st === "downloaded")
                        root._update(m[4], {state: "installing"});
                }
                return;
            }
        }
    }

    // The aggregate download row, in both the live screen copy and the final
    // newline-terminated one pacman leaves behind at 100%:
    //   " Total (157/157)  741.2 MiB  10.1 MiB/s 01:13 [####] 100%"
    // Returns true when the line was one, so either caller can stop there.
    function _readTotalRow(line) {
        const m = line.match(
            /Total \(\s*(\d+)\/\s*(\d+)\)\s+([\d.]+\s*[KMGT]?i?B)\s+([\d.]+\s*[KMGT]?i?B\/s)\s+(\d+:\d+|--:--)\s+\[[#\-]*\]\s+(\d+)%/);
        if (m) {
            const n = parseInt(m[1]), total = parseInt(m[2]), pct = parseInt(m[6]);
            // Rows reach here out of stream order: a newline-terminated row is
            // fed at once while the in-place rows drawn before it arrive at
            // the end of the chunk. A row older than the current state is
            // ignored -- the rule the install counter already follows -- so
            // the aggregate never runs backwards and the end-of-download pin
            // is not undone by a late batch.
            if (total === root.downloadsTotal
                    && (n < root.downloadsDone || (n === root.downloadsDone && pct < root.downloadPct)))
                return true;
            root.downloadsDone = n;
            root.downloadsTotal = total;
            root.downloadSoFar = m[3];
            root.downloadRate = m[4];
            root.downloadEta = m[5] === "--:--" ? "" : m[5];
            root.downloadPct = parseInt(m[6]);
            return true;
        }
        // Bare counter, before the size columns appear.
        const m2 = line.match(/Total \(\s*(\d+)\/\s*(\d+)\)/);
        if (m2) {
            const n = parseInt(m2[1]), total = parseInt(m2[2]);
            if (total === root.downloadsTotal && n < root.downloadsDone) return true;
            root.downloadsDone = n;
            root.downloadsTotal = total;
            return true;
        }
        return false;
    }

    // Main: handle one committed line from the backend.
    // `raw` has already been ANSI-stripped by TerminalBackend._commitLine.
    // Route the live screen rows (cursor-addressed, never newline-terminated)
    // through the same narrow progress reader as the tail preview.
    function processScreenRows(rows) {
        if (!rows) return;
        for (let i = 0; i < rows.length; i++) root._progressRow(rows[i]);
    }

    // Record one package's download telemetry.
    //
    // Only advances a package that is still queued or already downloading, so
    // a late repaint of a row cannot drag an installed package backwards.
    // Writes are gated (see _applyDownloadRow): at 20 concurrent downloads
    // redrawing several times a second the model would otherwise take tens
    // of thousands of writes over a long run, most of them setting the value
    // it already holds.
    // Truncated names resolved once and remembered, so the scan below runs at
    // most once per package rather than on every progress tick.
    property var _truncCache: ({})
    // When each package's row was last written, for the time budget below.
    property var _dlWriteAt: ({})
    // How stale a row's rate/ETA may get before a repaint is written through
    // even though its byte count has not moved.
    property int dlWriteBudgetMs: 500

    // FALLBACK for a truncated filename column.
    //
    // pacman truncates filenames to fit the terminal ("bubblewrap-0.12....",
    // "python-platformd..."), and exact reconstruction cannot match those — only the
    // packages whose names happen to fit would show any progress and every other
    // row would sit frozen.
    //
    // TerminalBackend sizes its PTY wide enough that this should not
    // happen, so this is insurance rather than the main path: it only runs
    // when the exact lookup misses, and caches its answer. Kept because the
    // width can still fail to take, and because a pathological name could
    // outgrow any width we pick.
    //
    // Resolved by prefix instead. An ambiguous prefix returns nothing rather
    // than guessing, since attributing bytes to the wrong package is worse
    // than attributing them to none.
    function _resolveTruncated(file) {
        const cached = root._truncCache[file];
        if (cached !== undefined) return cached || undefined;
        const m = String(file).match(/^(.*?)\.{2,}$/);
        if (!m || m[1].length < 4) return undefined;
        const prefix = m[1];
        // Matched in BOTH directions. The stored key is "name-version" with
        // no architecture, and the truncation can fall either side of that
        // boundary: "bubblewrap-0.12." stops inside the version (shorter than
        // the key) while "libuv-1.52.1-2-x" has already eaten into the arch
        // (longer than it). Testing only one direction would miss the latter.
        let hit;
        for (const key in root._fileToPkg) {
            if (key.indexOf(prefix) !== 0 && prefix.indexOf(key) !== 0) continue;
            const cand = root._fileToPkg[key];
            if (hit !== undefined && hit !== cand) {
                root._truncCache[file] = "";
                return undefined;
            }
            hit = cand;
        }
        root._truncCache[file] = hit || "";
        return hit;
    }

    // One name entering or leaving the in-flight set. Both are no-ops when
    // the name is already in the state asked for, so the progress rows that
    // repeat a name several times a second allocate nothing.
    function _noteDownloading(name) {
        root.currentDownloading = name;
        if (root._dlInFlight[name]) return;
        root._dlInFlight[name] = true;
        root.downloadingNames = root.downloadingNames.concat([name]);
    }
    function _doneDownloading(name) {
        if (!root._dlInFlight[name]) return;
        delete root._dlInFlight[name];
        root.downloadingNames = root.downloadingNames.filter(n => n !== name);
    }
    function _clearDownloading() {
        root._dlInFlight = ({});
        if (root.downloadingNames.length > 0) root.downloadingNames = [];
    }

    function _applyDownloadRow(file, received, rate, eta, pct) {
        const base = String(file).replace(/-(x86_64|any|i686|aarch64|armv7h)$/, "");
        let name = root._fileToPkg[base];
        if (name === undefined) name = root._resolveTruncated(file);
        if (name === undefined) return;
        const idx = root._pkgByName[name];
        if (idx === undefined) return;

        const cur = _packages.get(idx);
        if (cur.state !== "queued" && cur.state !== "downloading"
            && cur.state !== "downloaded") return;

        // NEVER BACK OUT OF `downloaded`. pacman prints a package's first
        // file to 100%, then starts a SECOND one for the same package at 0%
        // -- its signature, or a retry -- and following that would take the row
        // from `downloaded` back to `downloading`, once per package that has
        // one. Steps never go backwards; the state is a high-water mark like
        // every other step's, while the FIGURES keep following the live file,
        // because that is what the row is actually showing.
        const done = pct >= 100 || cur.state === "downloaded";
        // Not `currentDownloading = name` alone: the in-flight SET is what a
        // view can show without flickering through twenty names.
        if (done) root._doneDownloading(name);
        else root._noteDownloading(name);

        // Writes are gated on the DATA, not on the percent. Rate and ETA move
        // on almost every repaint, so writing them freely would put ~53 000
        // property writes through the model over the reference capture's
        // download phase. Gating on the percent would bound that, but one percent
        // of a 144 MiB file is 1.4 MiB -- six seconds at the rate that run
        // was getting -- and the row would sit on a stale rate for all of it. So:
        // write when the received byte count moved (pacman prints it to
        // 0.1 MiB, a natural coarse tick), and otherwise at most once per
        // budget, so a stalled row still shows its rate decaying. A repaint
        // that changes nothing at all is never written.
        const bytes = Bytes.parseSize(received);
        const want = done ? "downloaded" : "downloading";
        const moved = bytes !== cur.dlSoFarBytes || pct !== cur.dlPct || cur.state !== want;
        if (!moved && rate === cur.dlRate && eta === cur.dlEta) return;
        const now = Date.now();
        const last = root._dlWriteAt[name];
        if (!moved && last !== undefined && now - last < root.dlWriteBudgetMs) return;
        root._dlWriteAt[name] = now;

        _packages.setProperty(idx, "dlPct", pct);
        _packages.setProperty(idx, "dlSoFarBytes", bytes);
        _packages.setProperty(idx, "dlRate", rate);
        _packages.setProperty(idx, "dlEta", eta);
        if (cur.state !== want) _packages.setProperty(idx, "state", want);
        root.packageProgress(name, want, pct, rate, eta);
    }

    // The last few lines before a prompt, so a bare "[y/N]" can be shown
    // with what it is actually about -- yay warns about a dependency in the
    // lines above the question, and the question alone reads as "Question".
    property var currentPromptContext: []
    property var _recentLines: []
    function _noteLine(line) {
        const t = line.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").trim();
        if (t.length === 0) return;
        if (/^\s*[\[#=-]+[\]#=-]*\s*\d*%?\s*$/.test(t)) return;      // progress bars
        if (/\[y\/n\]|\[Y\/n\]|\[y\/N\]/i.test(t)) return;         // the question itself
        root._recentLines.push(t);
        if (root._recentLines.length > 8) root._recentLines.shift();
    }
    // Names in the prompt's context that are packages of this transaction:
    // what "the above package" refers to. Removing them is what a "yes" to
    // yay's skip-dependency question means for the list.
    function skipContextPackages() {
        // pacman's own list first; the prompt's context lines only when
        // there was none (older pacman wording).
        const ctx = root._unresolvable.length > 0 ? root._unresolvable : (root.currentPromptContext || []);
        const hit = {};
        for (const l of ctx)
            for (const tok of String(l).split(/[^A-Za-z0-9@._+-]+/))
                if (tok.length > 1 && (tok in root._pkgByName)) hit[tok] = true;
        root._unresolvable = [];
        const names = Object.keys(hit);
        if (names.length === 0) return;
        for (let i = _packages.count - 1; i >= 0; i--)
            if (hit[_packages.get(i).name]) _packages.remove(i);
        const map = {};
        for (let i = 0; i < _packages.count; i++) map[_packages.get(i).name] = i;
        root._pkgByName = map;
    }

    // One `lares-snapshot: <verb> ...` line of the hook. The hook runs once a RUN, so a second
    // transaction (the AUR install) answers `skip run`, which must not take a done snapshot back.
    function _snapshotLine(rest) {
        let m;
        if ((m = rest.match(/^start(?: (.*))?$/))) {
            root.snapshotState = "running"; root.snapshotCode = "";
            root.snapshotText = m[1] || "";
            if (root.snapshotProgress < 0) root.snapshotProgress = 0;
        } else if ((m = rest.match(/^progress (\d+)\s*$/))) {
            if (root.snapshotState === "" ) root.snapshotState = "running";
            // Rises only: a hook that restarts its count must not walk the notch back.
            root.snapshotProgress = Math.max(root.snapshotProgress, Math.min(1, parseInt(m[1]) / 100));
        } else if ((m = rest.match(/^done (\S+)/))) {
            root.snapshotState = "done"; root.snapshotCode = "";
            root.snapshotShort = m[1];
            root.snapshotProgress = 1;
        } else if ((m = rest.match(/^skip (\S+)(?: (.*))?$/))) {
            if (root.snapshotState === "done") return;
            root.snapshotState = "skipped"; root.snapshotCode = m[1];
            root.snapshotText = m[2] || "";
        } else if ((m = rest.match(/^failed (\S+)(?: (.*))?$/))) {
            root.snapshotState = "failed"; root.snapshotCode = m[1];
            root.snapshotText = m[2] || "";
            root._addError("snapshot", Work.snapshotFailure(m[1], m[2]));
        } else if ((m = rest.match(/^notice (.+)$/))) {
            root._addNotice(m[1], "snapshot");
        }
    }

    function processLine(raw) {
        let line = raw == null ? "" : String(raw);
        // A line redrawn with bare carriage returns (curl's meter; no cursor
        // escapes, so the backend cannot split it into rows) arrives whole
        // when it finally ends. Its earlier states are progress rows; the
        // last one is the line.
        if (line.indexOf("\r") >= 0) {
            const segs = line.split("\r");
            for (let i = 0; i < segs.length - 1; i++) root._progressRow(segs[i]);
            line = segs[segs.length - 1];
        }
        // Defensive: some PTY streams leak charset-switch `(B` (ESC(B)
        line = line.replace(/\x1b\([AB012]/g, "").replace(/\x1b\)[AB012]/g, "");
        line = line.replace(/\s+$/, "");
        // AFTER the cleanup: `_recentLines` is what a prompt's context is
        // drawn from, and a line with escape residue in it reads as noise
        // wherever it is shown.
        root._noteLine(line);

        // === Notices ===
        // Read early and NOT returned from: a warning is a note about a line
        // that may still be a line the parser has a rule for.
        {
            let m = line.match(/^[Ww]arning: (.+)$/);
            // A WARNING IS THE SPEAKER'S, and an unprefixed "warning:" has
            // two speakers in one run.
            //
            // Outside a build it is pacman (or a hook's systemd), and the
            // line is about the MACHINE: a dependency it cannot resolve, a
            // file it could not read, a permission that differs, a unit that
            // changed on disk. Those are the notices this list is for.
            //
            // While a package is being COMPILED it is the compiler, warning
            // about the source it was handed -- the package's business, not
            // the machine's, and there can be hundreds of them. The build's
            // own outcome is reported as an error with its exit status, which
            // is the part that concerns the reader.
            //
            // Cargo makes the point itself: every line a build script writes
            // to stderr is relayed as "warning: <crate>@<version>: <line>",
            // so the prefix says WHERE A LINE CAME FROM and not what it is.
            // cardwire's eBPF build script is a nested cargo, and its forty
            // ordinary "Compiling" lines would arrive as forty warnings in the
            // popup. The relay is refused in every
            // phase, not only during the build: what it wraps is judged by
            // the rules below like any other line, and none of them mistake
            // "   Compiling syn v3.0.3" for a notice.
            //
            // makepkg's own "==> WARNING:" keeps its place in every phase.
            // Those ARE about the package and the machine ("Package contains
            // reference to $srcdir", "Using existing $srcdir tree"), they are
            // deduped, and there is a handful of them per run.
            if (m && !root._buildSpeaking
                    && !/^[A-Za-z0-9._+-]+@\S+: /.test(m[1]))
                root._addNotice(m[1], "pacman");
            else if ((m = line.match(/^==> WARNING: (.+)$/))) root._addNotice(m[1], "tool");
            else if ((m = line.match(/^\s*-> ((?:Orphan \(unmaintained\) AUR|Flagged Out Of Date AUR|Packages not in AUR)[^:]*): (.+)$/)))
                root._addNotice(m[1] + ": " + m[2], "aur");
        }

        // pacman's list of what it will not upgrade: the header line, then
        // the names indented on one or more lines, then a blank line and
        // the question. Captured as data rather than left in the recent
        // lines, so the question can show and act on exactly that list.
        if (line.match(/^:: The following packages cannot be upgraded due to unresolvable dependencies/)) {
            root._unresolvable = []; root._unresolvableCapture = true; return;
        }
        if (root._unresolvableCapture) {
            const names = line.match(/^\s+([A-Za-z0-9@._+-]+(?:\s+[A-Za-z0-9@._+-]+)*)\s*$/);
            if (names) { root._unresolvable = root._unresolvable.concat(names[1].split(/\s+/)); return; }
            if (line.trim().length > 0) root._unresolvableCapture = false;
            else return;
        }
        // The snapshot hook's lines, only while a transaction is in its pre-transaction hooks.
        if (line.indexOf("lares-snapshot: ") === 0 && root.subPhase === "L4_PREHOOKS"
                && (root.phase === "OFFICIAL_INSTALL" || root.phase === "AUR_INSTALL")) {
            root._snapshotLine(line.substring(16));
            return;
        }
        // curl's meter for a source download, on the line it ends with.
        if (root._curlRow(line)) return;

        // Close any open prompt as soon as a non-prompt line arrives.
        //
        // EXCEPT while the phase says we are parked at one of yay's numbered
        // menus. Those wait indefinitely for input, and yay can emit further
        // output around them; closing on that output would leave the UI showing the
        // question with no input control attached to it.
        const _atMenu = root.phase === "PROMPT_EXCLUDE"
                     || root.phase === "PROMPT_CLEANBUILD"
                     || root.phase === "PROMPT_DIFFS"
                     || root.phase === "PROMPT_EDIT_PKGBUILD";
        if (root.awaitingUserInput && !_atMenu
            && line.length > 0 && !line.startsWith("==>") && !line.startsWith("[sudo]")
            && !line.match(/\[Y\/n\]|\[y\/N\]/)) {
            _closePrompt();
        }

        // === Error path (can interrupt anywhere) ===
        //
        // pacman's OWN failures, which never reach yay's "Failed to install"
        // report because the transaction never got as far as a package: a
        // download lost to a slow mirror ends `error: failed to commit transaction
        // (failed to retrieve some files)`, exit 1 -- and the card would say
        // "Update complete" if nothing below counted it.
        //
        // A MIRROR THAT FAILED IS NOT A RUN THAT FAILED. pacman prints
        // `error: failed retrieving file 'X' from <mirror> : <why>` for EVERY
        // attempt and goes on to the next mirror: a run can have
        // five of them (one file failed on three mirrors), then
        // `warning: too many errors from <mirror>, skipping ...`, and
        // install 538 packages with exit 0 -- yet be shown under a red "Finished with 5
        // errors". It is the WORD "error" on the line that is pacman's, not
        // the outcome; the outcome is the line that says the transaction
        // could not be committed (all three failed captures end in `error:
        // failed to commit transaction (failed to retrieve some files)`,
        // after the same retrieval lines), or the exit status. So a retrieval
        // failure is a NOTICE -- visible, named, never red -- and the error
        // is the commit line, which a run that really failed always prints.
        {
            let m = line.match(/^error: failed retrieving file '([^']+)' from (\S+)\s*:\s*(.+)$/);
            if (m) {
                const pkg = m[1].replace(/(-x86_64|-any|-i686|-aarch64)?\.pkg\.tar\.\w+(\.sig)?$/, "")
                    + (/\.sig$/.test(m[1]) ? " (signature)" : "");
                root._addNotice(pkg + " from " + m[2] + ": " + m[3].trim(), "mirror");
                return;
            }
            m = line.match(/^error: failed to commit transaction \((.+)\)\s*$/);
            if (m) {
                // The snapshot hook that stopped the transaction has said why; pacman's own line
                // about "transaction hooks" is the same news, vaguer.
                if (root.snapshotState === "failed" && /failed to run transaction hooks/.test(m[1])) return;
                root._addError("pacman", "failed to commit transaction: " + m[1]);
                return;
            }
            // "Errors occurred, no packages were upgraded." and yay's
            // " -> error installing repo packages" are the same news again.
        }
        if (line.match(/^ -> Failed to install the following packages/)) {
            _setPhase("FINAL_ERRORS", "Failed packages report");
            return;
        }
        if (root.phase === "FINAL_ERRORS") {
            const m = line.match(/^(\S+)\s*-\s*(.+)$/);
            if (m) {
                root._addError(m[1], m[2]);
                _update(m[1], {state: "failed", error: m[2]});
            }
            return;
        }

        // === DB sync (A or K) ===
        if (line === ":: Synchronizing package databases...") {
            root._dbSyncCount += 1;
            if (root._dbSyncCount === 1)
                _setPhase("DB_SYNC_1", "Syncing package databases");
            else
                _setPhase("DB_SYNC_2", "Re-syncing before install");
            return;
        }

        // === AUR search (B) ===
        // This marker is often embedded into the tail of the previous DB-sync
        // line because pacman uses cursor-up escapes to redraw repo rows in
        // place; our ANSI-strip flattens those onto one long line. Match
        // substring rather than requiring line-start.
        if (line.indexOf(":: Searching AUR for updates") >= 0) {
            _setPhase("AUR_SEARCH", "Searching for updates");
            return;
        }

        // === Packages count → UPGRADE_LIST (C) ===
        {
            const m = line.match(/^:: (\d+) packages to upgrade\/install\.?$/);
            if (m) {
                root.totalPackages = parseInt(m[1]);
                _setPhase("UPGRADE_LIST", "Upgrade list (" + m[1]
                          + (m[1] === "1" ? " package)" : " packages)"));
                return;
            }
        }

        // === Upgrade list numbered rows ===
        if (root.phase === "UPGRADE_LIST") {
            // Trailing content after the new version is TOLERATED, not
            // anchored away: yay appends an age marker to AUR rows
            // ("... -> 1.1.22-1 [1h34m]"), so a `$` here would silently drop
            // every AUR package from the run — the category would simply never
            // appear once an update started, while the pre-run list, which
            // is parsed elsewhere and already tolerant, shows them fine.
            const m = line.match(
                /^\s*(\d+)\s+(\S+)\/(\S+)\s+(\S+)\s+->\s+(\S+)(?:\s+.*)?$/);
            if (m) {
                const num = parseInt(m[1]);
                const repo = m[2]; const name = m[3];
                const oldVer = m[4]; const newVer = m[5];
                const isAur = (repo === "aur");
                const flavour = isAur
                    ? (name.endsWith("-bin") ? "binary" : name.endsWith("-git") ? "git" : "source")
                    : (name.match(/^linux(-lts|-zen|-g14|-hardened|-rt)?$/) ? "kernel"
                       : name.endsWith("-dkms") ? "dkms"
                       : "binary");
                _findOrAdd(name, {number: num, repo: repo, oldVer: oldVer, newVer: newVer, isAur: isAur, flavour: flavour});
                if (isAur) root.aurBuildsTotal += 1;
                return;
            }
        }

        // === pacman's transaction summary ===
        // The table's summary lines. Checked BEFORE the row pattern: with an
        // optional Old Version column, "Total Download Size:  741.15 MiB"
        // has the shape of a row too.
        {
            const m = line.match(/^(Total Download Size|Total Installed Size|Net Upgrade Size):\s+(-?[\d.]+\s*[KMGT]?i?B)\s*$/);
            if (m) {
                const bytes = Bytes.parseSize(m[2]);
                // Only the download total is read by anything: the other two describe the
                // LAST transaction pacman summarised rather than the run -- on a mixed run,
                // the 8-package AUR one -- and a written-never-read property holding a
                // misleading figure is worse than no property.
                if (m[1] === "Total Download Size") root.totalDownloadBytes = bytes;
                return;
            }
        }

        // === pacman's verbose package table (VerbosePkgLists) ===
        // "extra/abseil-cpp   20260526.0-2   20260817.0-1   0.09 MiB   1.35 MiB"
        // and the AUR install table, which has no repo prefix:
        // "antigravity-cli    1.1.13_...-1   1.1.19_...-1   0.03 MiB"
        // This is pacman's own authoritative list of what it will change,
        // including sizes, and it is emitted for every package. Rows are
        // matched only while the table is open so ordinary text cannot be
        // mistaken for one.
        // Length guard before the table regex.
        //
        // With ParallelDownloads the whole download phase arrives as ONE line
        // of ~1.5 MB. A pattern of repeated `\S+\s+` groups backtracks
        // catastrophically over input like that — it hangs the popup outright,
        // while the same data through the backend alone took 130 ms. No real
        // table row is anywhere near this long.
        if (line.length <= root.maxTableRowChars
            && (root.phase === "OFFICIAL_INSTALL" || root.phase === "AUR_INSTALL")) {
            // Old Version is OPTIONAL: a package new to the system has an
            // empty column there ("extra/qemu-system-hexagon  11.1.1-1
            // 11.40 MiB  3.25 MiB"). Download Size is blank for a package
            // already in the cache, so that column is optional too and reads
            // as 0 bytes.
            const m = line.match(/^(?:(\S+)\/)?(\S+)\s+(?:(\S+)\s+)?(\S+)\s+(-?[\d.]+\s*[KMG]iB)(?:\s+(-?[\d.]+\s*[KMG]iB))?\s*$/);
            if (m && m[4].match(/\d/) && (m[3] === undefined || m[3].match(/\d/))) {
                const repo = m[1] || "";
                const name = m[2];
                const data = {
                    newVer: m[4],
                    // An undo's table is pacman -U's: no repo column, and not one AUR package.
                    isAur: root.runKind !== "undo" && (repo === "" || repo === "aur"),
                    netChange: m[5] || "",
                    netBytes: Bytes.parseSize(m[5])
                };
                // Merged into a row the upgrade list already filled, so a
                // column this table lacks must not blank what that row has:
                // the AUR table has no repo column, and "" would wipe "aur".
                if (repo) data.repo = repo;
                if (m[3] !== undefined) data.oldVer = m[3];
                // Same guard as its neighbours: the AUR
                // install table has four columns, so m[6] is undefined there
                // and an unguarded write would put 0 over the size the source fetch measured.
                if (m[6] !== undefined) {
                    data.downloadSize = m[6];
                    data.dlBytes = Bytes.parseSize(m[6]);
                }
                // Blank Download Size: the file is already in the cache, so
                // pacman fetches nothing for it and prints no row -- for the
                // download step it is through before the step begins.
                if (!data.isAur && m[6] === undefined) data.state = "downloaded";
                _findOrAdd(name, data);
                return;
            }
        }

        // === Prompts (yay 12.x). Matches use substring/relaxed forms because
        // yay's wording drifts between versions (e.g. "Proceed with install?"
        // vs "Proceed with installation?"). Bare-substring matches survive
        // future tweaks.
        if (line.indexOf("==> Packages to exclude") >= 0) {
            _setPhase("PROMPT_EXCLUDE", "Exclude packages?");
            _openPrompt("yay_exclude", "Packages to exclude", "");
            return;
        }
        if (line.indexOf("==> Packages to cleanBuild") >= 0) {
            _setPhase("PROMPT_CLEANBUILD", "Clean AUR build caches?");
            _openPrompt("yay_cleanbuild", "Packages to cleanBuild", "N");
            return;
        }
        if (line.indexOf("==> Diffs to show") >= 0) {
            _setPhase("PROMPT_DIFFS", "Show PKGBUILD diffs?");
            _openPrompt("yay_diffs", "Diffs to show", "N");
            return;
        }
        if (line.indexOf("==> PKGBUILDs to edit") >= 0) {
            _setPhase("PROMPT_EDIT_PKGBUILD", "Edit PKGBUILDs?");
            _openPrompt("yay_edit_pkgbuild", "PKGBUILDs to edit", "N");
            return;
        }
        // pacman's "Proceed with installation?", yay's skip-a-dependency
        // question and its other "==> ... [y/N]" ones. Usually already open
        // from the tail (see processPromptTail); this is the committed line.
        if (root._matchYesNoPrompt(line)) return;

        // === Grouped summary (E) ===
        {
            const m = line.match(/^(Sync Dependency|Sync Explicit|AUR Dependency|AUR Explicit) \((\d+)\): (.+)$/);
            if (m) {
                if (root.phase !== "GROUPED_SUMMARY")
                    _setPhase("GROUPED_SUMMARY", "Dependency summary");
                const role = m[1].endsWith("Explicit") ? "explicit" : "dependency";
                const pkgs = m[3].split(/,\s*/);
                for (const p of pkgs) {
                    // "python-click-8.3.3-1" → name = "python-click"
                    const pm = p.match(/^(.+)-([^-\s]+-\d+)$/);
                    const nm = pm ? pm[1] : p;
                    if (root._pkgByName[nm] !== undefined)
                        _update(nm, {role: role});
                }
                return;
            }
        }

        // === PKGBUILD cache (F) ===
        if (line.match(/^:: (?:PKGBUILD up to date, skipping download|Downloading PKGBUILD):/)) {
            if (root.phase !== "PKGBUILD_CACHE")
                _setPhase("PKGBUILD_CACHE", "Checking AUR PKGBUILDs");
            return;
        }

        // === SRCINFO parsing (J) ===
        {
            const m = line.match(/^:: \((\d+)\/(\d+)\) Parsing SRCINFO: (.+)$/);
            if (m) {
                _setPhase("SRCINFO_PARSE", "Parsing SRCINFO " + m[1] + "/" + m[2]);
                return;
            }
        }

        // === Start OFFICIAL_INSTALL (L) ===
        // Same cursor-merge hazard as AUR_SEARCH — use substring match.
        if (line.indexOf(":: Starting full system upgrade") >= 0) {
            _setPhase("OFFICIAL_INSTALL", "Installing official packages");
            _setSubPhase("L0_RESOLVE", "Resolving dependencies");
            return;
        }
        // Package table header → L1_TABLE / N1_TABLE, and the size of the
        // transaction it heads. pacman prints it for BOTH transactions of a
        // mixed run (it is singular whatever the count -- "Package (44)"),
        // and the guard here answers in both: otherwise the AUR
        // transaction would stay in N0_LOAD, so the card would read "Loading built
        // .pkg.tar.zst" for the whole time the user spends at its Proceed
        // prompt, with the table and the question already on screen.
        {
            const m = line.match(/^Package \((\d+)\)\s+Old Version/);
            if (m && (root.phase === "OFFICIAL_INSTALL" || root.phase === "AUR_INSTALL")) {
                root._txnTotal = parseInt(m[1]);
                _setSubPhase(root.phase === "AUR_INSTALL" ? "N1_TABLE" : "L1_TABLE",
                             "Reviewing package changes");
                return;
            }
        }

        // === :: Retrieving packages... (L.2 download start) ===
        if (line === ":: Retrieving packages...") {
            _setSubPhase("L2_DOWNLOAD", "Downloading packages");
            return;
        }

        // Download Total line: " Total (N/M)  <size>  <rate>  <eta>  [bar]  NN%"
        // The final 100% row IS newline-terminated (pacman leaves it behind
        // when the block ends), so it arrives here and not as a screen row.
        // Read the full shape, or the rail freezes on the last live value --
        // 99% for the rest of the run.
        if (line.match(/^\s*Total \(/) && root._readTotalRow(line)) return;
        // Per-file header during download: " <pkg>-<ver>-<arch>"
        if (root.subPhase === "L2_DOWNLOAD") {
            const m = line.match(/^\s([\w\.\+\-:]+?)-(\d[\w\.\+]*-\d+)-(x86_64|any|i686|aarch64)\s*$/);
            if (m) { root._noteDownloading(m[1]); return; }
        }

        // === Integrity checks (L.3 / N.3) ===
        {
            const m = line.match(/^\(\s*(\d+)\/(\d+)\)\s+(checking keys in keyring|checking package integrity|loading package files|checking for file conflicts|checking available disk space).*?(\d+)%\s*$/);
            if (m) {
                if (root.phase === "AUR_INSTALL") {
                    _setSubPhase("N3_INTEGRITY", m[3]);
                } else {
                    _setSubPhase("L3_INTEGRITY", m[3]);
                }
                root.integrityStep = m[3];
                return;
            }
        }

        // === Pre / post transaction hooks ===
        if (line === ":: Running pre-transaction hooks...") {
            _setSubPhase("L4_PREHOOKS", "Running pre-install hooks");
            root.hooksDone = 0; root.hooksStarted = 0; root.hooksTotal = 0; root.currentHook = "";
            root.currentDkmsOp = ""; root.currentInitramfsKernel = ""; root.currentInitramfsHook = "";
            return;
        }
        if (line === ":: Running post-transaction hooks...") {
            if (root.phase === "AUR_INSTALL")
                _setSubPhase("N6_POSTHOOKS", "Running post-install hooks");
            else
                _setSubPhase("L6_POSTHOOKS", "Running post-install hooks");
            root.hooksDone = 0; root.hooksStarted = 0; root.hooksTotal = 0; root.currentHook = "";
            root.currentDkmsOp = ""; root.currentInitramfsKernel = ""; root.currentInitramfsHook = "";
            return;
        }
        if (root.subPhase === "L4_PREHOOKS" || root.subPhase === "L6_POSTHOOKS" || root.subPhase === "N6_POSTHOOKS") {
            const m = line.match(/^\(\s*(\d+)\/(\d+)\)\s+(.+?)\.{0,3}\s*$/);
            if (m) {
                const n = parseInt(m[1]);
                root.hooksStarted = n;
                root.hooksDone = Math.max(0, n - 1);
                root.hooksTotal = parseInt(m[2]);
                root.currentHook = m[3];
                // Whatever the previous hook was doing is over.
                root.currentDkmsOp = "";
                root.currentInitramfsKernel = "";
                root.currentInitramfsHook = "";
                _hooks.append({name: m[3], phase: root.subPhase, index: n, total: root.hooksTotal});
                return;
            }
        }

        // === Processing package changes ===
        if (line === ":: Processing package changes...") {
            // The counters are cleared BEFORE the sub-phase is announced.
            // `_setSubPhase` emits, and a listener that reads the install
            // figures on that signal would otherwise read the PREVIOUS
            // transaction's.
            //
            // A mixed run has two transactions. This one's total and its
            // current package start empty; the only line that corrects
            // them is the first "(n/m) upgrading" of the new transaction, so
            // the AUR install would open on "installing yyjson 0 / 44", the last
            // official package and the official count.
            // The table header above knows the real size before this line.
            root.installsDone = 0; root.installsStarted = 0;
            root.installsTotal = root._txnTotal;
            root.currentInstalling = "";
            // The pre-transaction hooks are all through, DKMS removal
            // included -- it must not keep the status on "DKMS" for the
            // whole install.
            root.hooksDone = root.hooksTotal;
            root.currentDkmsOp = ""; root.currentInitramfsKernel = ""; root.currentInitramfsHook = "";
            if (root.phase === "AUR_INSTALL")
                _setSubPhase("N5_CHANGES", "Processing package changes");
            else
                _setSubPhase("L5_CHANGES", "Processing package changes");
            return;
        }
        {
            const m = line.match(/^\(\s*(\d+)\/(\d+)\) (upgrading|installing|reinstalling|removing|downgrading) ([\w\.\+\-:]+)/);
            if (m && (root.subPhase === "L5_CHANGES" || root.subPhase === "N5_CHANGES")) {
                const n = parseInt(m[1]); const total = parseInt(m[2]);
                const verb = m[3]; const name = m[4];
                // The committed copy of the row is the 100% one: package n is
                // through. Its live copy, read in _progressRow, only says
                // it has started.
                root.installsDone = n; root.installsTotal = total;
                root.installsStarted = Math.max(root.installsStarted, n);
                root.currentInstalling = name;
                _update(name, {state: verb === "removing" ? "removed" : "installed"});
                packageEvent(name, verb, "");
                return;
            }
        }

        // === "loading packages..." → AUR_INSTALL (N) ===
        if (line === "loading packages..." && root.runKind === "undo") {
            // pacman -U of old packages: the first and only transaction, an official one.
            _setPhase("OFFICIAL_INSTALL", "Downgrading packages");
            _setSubPhase("L0_RESOLVE", "Resolving dependencies");
            return;
        }
        if (line === "loading packages...") {
            _closeHooks();
            _setPhase("AUR_INSTALL", "Installing built AUR packages");
            _setSubPhase("N0_LOAD", "Loading built .pkg.tar.zst");
            return;
        }

        // === "==> Making package: X VER (...)" ===
        //     First pass (no fakeroot follow-up within a few lines) = phase I
        //     Second pass (same pkg, plus "Entering fakeroot") = phase M
        //     We distinguish via the per-pkg state stored in _packages.
        {
            const m = line.match(/^==> Making package: (\S+) (\S+) \(.+\)$/);
            if (m) {
                _closeHooks();
                const name = m[1];
                if (!(name in root._pkgByName))
                    _findOrAdd(name, {isAur: true, flavour: name.endsWith("-bin") ? "binary" : name.endsWith("-git") ? "git" : "source"});
                const idx = root._pkgByName[name];
                const cur = _packages.get(idx).state;
                // The fetch pass comes before the official transaction; a
                // "Making package" after it is the build, whatever the row
                // says (it may have been re-added meanwhile).
                if (cur === "queued" && !root._pastOfficialInstall) {
                    if (root.phase !== "AUR_SRC_FETCH" && root.phase !== "AUR_BUILD_LOOP")
                        _setPhase("AUR_SRC_FETCH", "Fetching AUR sources");
                    // The previous package's sources are in once the next
                    // one starts.
                    if (root.currentAurBuild && root.currentAurBuild !== name
                            && (root.currentAurBuild in root._pkgByName)
                            && _packages.get(root._pkgByName[root.currentAurBuild]).state === "fetching") {
                        _update(root.currentAurBuild, {state: "sources-ready"});
                        root.aurSourcesDone += 1;
                    }
                    _update(name, {state: "fetching"});
                    root.currentAurBuild = name;
                    root.currentAurBuildStep = "fetching sources";
                    root.sourceFetchFile = ""; root.sourceFetchPct = -1;
                } else {
                    // Seen before → this is the build pass (M)
                    if (root.phase !== "AUR_BUILD_LOOP")
                        _setPhase("AUR_BUILD_LOOP", "Building AUR packages");
                    _update(name, {state: "building"});
                    root.currentAurBuild = name;
                    // NOT "entering fakeroot": makepkg checks dependencies,
                    // retrieves, validates and extracts first, so saying it
                    // here would name a thing that has not happened and then go
                    // back three steps. "==> Entering fakeroot environment"
                    // is the only line that may say it.
                    root.currentAurBuildStep = "starting build";
                }
                return;
            }
        }

        // === AUR build sub-step markers ===
        if (root.phase === "AUR_SRC_FETCH" || root.phase === "AUR_BUILD_LOOP") {
            if (line === "==> Retrieving sources...")            { root.currentAurBuildStep = "retrieving sources"; return; }
            {
                // curl says so before its meter starts, and its Total column
                // is the remaining range from here on.
                const m = line.match(/^\*\* Resuming transfer from byte position (\d+)/);
                if (m) { root._curlResumeOffset = parseInt(m[1]); return; }
            }
            {
                // "  -> Downloading zen-browser-1.21.16b-1-x86_64.tar.xz..."
                const m = line.match(/^\s*-> Downloading (\S+?)\.\.\.$/);
                if (m) {
                    root.sourceFetchFile = m[1]; root.sourceFetchPct = 0;
                    root._curlResumeOffset = 0;
                    root.sourceFetchBytesDone = 0; root.sourceFetchBytesTotal = 0;
                    root.sourceFetchRate = ""; root.sourceFetchEta = "";
                    root.currentAurBuildStep = "downloading " + m[1];
                    return;
                }
            }
            // Whatever the PKGBUILD declares: sha256sums, sha512sums,
            // b2sums, md5sums. Some packages use sha512 and the like, so a matcher for
            // sha256 alone would leave their checksum pass showing the
            // PREVIOUS step's label all the way through.
            if (line.match(/^==> Validating source/)) { root.currentAurBuildStep = "validating sources"; return; }
            if (line === "==> Extracting sources...")            { root.currentAurBuildStep = "extracting";  return; }
            if (line.match(/^==> Starting prepare\(\)/))         { root.currentAurBuildStep = "preparing";   return; }
            if (line.match(/^==> Starting pkgver\(\)/))          { root.currentAurBuildStep = "version check"; return; }
            if (line.match(/^==> Starting build\(\)/))           { root.currentAurBuildStep = "compiling";   return; }
            if (line.match(/^==> Starting check\(\)/))           { root.currentAurBuildStep = "testing";     return; }
            if (line.match(/^==> Starting package\(\)/))         { root.currentAurBuildStep = "packaging";   return; }
            if (line === "==> Tidying install...")               { root.currentAurBuildStep = "tidying";     return; }
            if (line.match(/^==> Creating package "/))           { root.currentAurBuildStep = "creating .pkg.tar.zst"; return; }
            if (line === "==> Entering fakeroot environment...") { root.currentAurBuildStep = "in fakeroot"; return; }
            // FETCH PASS ONLY. yay runs makepkg THREE times per package --
            // verifysource before the official transaction, then --nobuild
            // (which ends "Sources are ready."), then the real build -- so
            // ungated this would drag a package the preceding "Making package"
            // had just set to `building` back to `sources-ready`, once per
            // package, every run. States never go backwards.
            if (line === "==> Sources are ready." && root.phase === "AUR_SRC_FETCH") {
                if (root.currentAurBuild) _update(root.currentAurBuild, {state: "sources-ready"});
                return;
            }
            {
                const m = line.match(/^==> Finished making: (\S+) /);
                if (m) {
                    const name = m[1];
                    if (root.phase === "AUR_BUILD_LOOP") {
                        _update(name, {state: "built"});
                        root.aurBuildsDone += 1;
                        packageEvent(name, "built", "");
                    }
                    root.currentAurBuildStep = "done";
                    return;
                }
            }
            // Source validate FAILED → fail current pkg
            {
                const m = line.match(/^\s+(\S+) \.\.\. FAILED$/);
                if (m && root.currentAurBuild) {
                    _update(root.currentAurBuild, {state: "failed", error: "sha256 FAILED: " + m[1]});
                    return;
                }
            }
            // Generic makepkg ERROR
            if (line.match(/^==> ERROR: /)) {
                if (root.currentAurBuild) _update(root.currentAurBuild, {state: "failed", error: line});
                return;
            }
            // yay's post-error summary
            {
                const m = line.match(/^ -> error making: (\S+)/);
                if (m) {
                    const n = m[1].replace(/-exit.*$/, "");
                    if (n in root._pkgByName) _update(n, {state: "failed", error: line});
                    return;
                }
            }
        }

        // === DKMS ops (inside pre/post hooks) ===
        {
            const m = line.match(/^==> dkms (install|remove) --no-depmod (\S+)\/(\S+) -k (\S+)$/);
            if (m) {
                _dkmsOps.append({op: m[1], module: m[2], version: m[3], kernel: m[4]});
                root.currentDkmsOp = m[1] + " " + m[2] + "/" + m[3] + " for " + m[4];
                dkmsOpLogged(m[1], m[2], m[3], m[4]);
                return;
            }
        }
        {
            const m = line.match(/^==> depmod (\S+)$/);
            if (m) { root.currentDkmsOp = "depmod " + m[1]; return; }
        }

        // === Initramfs rebuild markers ===
        {
            const m = line.match(/^==> Building image from preset: \/etc\/mkinitcpio\.d\/([^.]+)\.preset: '(.+)'$/);
            if (m) {
                root.currentInitramfsKernel = m[1];
                _initramfsBuilds.append({kernel: m[1], preset: m[2], hookCount: 0, success: false});
                initramfsKernelStarted(m[1]);
                return;
            }
        }
        {
            const m = line.match(/^\s+-> Running build hook: \[(\w+)\]$/);
            if (m && root.currentInitramfsKernel) {
                root.currentInitramfsHook = m[1];
                if (_initramfsBuilds.count > 0) {
                    const lastIdx = _initramfsBuilds.count - 1;
                    const cur = _initramfsBuilds.get(lastIdx).hookCount;
                    _initramfsBuilds.setProperty(lastIdx, "hookCount", cur + 1);
                }
                return;
            }
        }
        if (line === "==> Initcpio image generation successful") {
            if (_initramfsBuilds.count > 0) {
                const lastIdx = _initramfsBuilds.count - 1;
                _initramfsBuilds.setProperty(lastIdx, "success", true);
                const kern = _initramfsBuilds.get(lastIdx).kernel;
                initramfsKernelEnded(kern, true);
            }
            root.currentInitramfsHook = "";
            return;
        }
    }

    // Listen to the backend. Reset the parser state whenever the backend
    // (re)starts so a back-to-back run doesn't inherit stale phase state.
    Connections {
        target: root.backend
        function onLineAppended(raw) { root.processLine(raw); }
        function onProgressPreview(text) { root.processProgress(text); }
        function onPreviewUpdated(text) { root.processPromptTail(text); }
        function onScreenRows(rows) { root.processScreenRows(rows); }
        function onStarted() { root.reset(); }
        function onExited(code, status) { root.finish(code); }
    }

    onBackendChanged: reset()
}
