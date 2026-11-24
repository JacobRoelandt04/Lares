// JSON event protocol — every event the helper can emit.
//
// Wire format:
//
//   {"t": "<ISO8601>", "event": "<dotted_name>", "data": { ... }}
//
// `event` is the discriminator; `data` carries the payload. One JSON object
// per line. Hosts dispatch on `event`. The whole file is the source of
// truth — anything not in here is not a stable event.
//
// Naming convention: `<domain>.<phase>.<state>` — domains are
// `transaction`, `db`, `download`, `package`, `hook`, `keyring`,
// `key_download`, `integrity`, `load`, `diskspace`, `checkdeps`,
// `resolvedeps`, `interconflicts`, `fileconflicts`, `pacnew`, `pacsave`,
// `optdep`, `database`, `scriptlet`, `aur`, `question`, `helper`,
// `log`. Phase / state pairs match the libalpm event names where
// applicable so a host migrating from the legacy parser can map 1:1.

// Some variants below aren't constructed yet (helper milestones — pkgver
// phase, aur install batch endpoints, etc.) but are part of the wire
// schema hosts must accept. `#[allow(dead_code)]` keeps cargo quiet.
#![allow(dead_code)]

use serde::Serialize;

#[derive(Serialize, Debug)]
#[serde(tag = "event", content = "data", rename_all = "snake_case")]
pub enum Event {
    // ---- Helper lifecycle ----
    #[serde(rename = "helper.start")]
    HelperStart {
        version: String,
        mode: String,
        dry_run: bool,
    },
    #[serde(rename = "helper.exit")]
    HelperExit { code: i32 },

    // ---- Diagnostic logging (not part of state, just a comm channel) ----
    #[serde(rename = "log.info")]
    LogInfo { msg: String },
    #[serde(rename = "log.warn")]
    LogWarn { msg: String },
    #[serde(rename = "log.error")]
    LogError { msg: String },

    // ---- Transaction lifecycle ----
    #[serde(rename = "transaction.start")]
    TransactionStart,
    #[serde(rename = "transaction.done")]
    TransactionDone,

    // ---- DB sync (pacman -Sy) ----
    #[serde(rename = "db.sync.start")]
    DbSyncStart { db: String },
    #[serde(rename = "db.sync.done")]
    DbSyncDone { db: String, success: bool },
    #[serde(rename = "db.missing")]
    DbMissing { db: String },

    // ---- Dependency check / resolution / conflicts ----
    #[serde(rename = "checkdeps.start")]
    CheckdepsStart,
    #[serde(rename = "checkdeps.done")]
    CheckdepsDone,
    #[serde(rename = "resolvedeps.start")]
    ResolvedepsStart,
    #[serde(rename = "resolvedeps.done")]
    ResolvedepsDone,
    #[serde(rename = "interconflicts.start")]
    InterconflictsStart,
    #[serde(rename = "interconflicts.done")]
    InterconflictsDone,
    #[serde(rename = "fileconflicts.start")]
    FileconflictsStart,
    #[serde(rename = "fileconflicts.done")]
    FileconflictsDone,

    // ---- Integrity / load / diskspace ----
    #[serde(rename = "integrity.start")]
    IntegrityStart,
    #[serde(rename = "integrity.done")]
    IntegrityDone,
    #[serde(rename = "load.start")]
    LoadStart,
    #[serde(rename = "load.done")]
    LoadDone,
    #[serde(rename = "diskspace.start")]
    DiskspaceStart,
    #[serde(rename = "diskspace.done")]
    DiskspaceDone,

    // ---- Keyring ----
    #[serde(rename = "keyring.start")]
    KeyringStart,
    #[serde(rename = "keyring.done")]
    KeyringDone,
    #[serde(rename = "key_download.start")]
    KeyDownloadStart,
    #[serde(rename = "key_download.done")]
    KeyDownloadDone,

    // ---- Package downloads (libalpm download callback) ----
    #[serde(rename = "download.batch_start")]
    DownloadBatchStart { count: usize, total_bytes: u64 },
    #[serde(rename = "download.batch_done")]
    DownloadBatchDone { success: bool },
    #[serde(rename = "download.init")]
    DownloadInit { file: String, total_bytes: u64 },
    #[serde(rename = "download.progress")]
    DownloadProgress {
        file: String,
        done_bytes: u64,
        total_bytes: u64,
    },
    #[serde(rename = "download.retry")]
    DownloadRetry { file: String, delay_ms: u64 },
    #[serde(rename = "download.complete")]
    DownloadComplete { file: String },

    // ---- Per-package operations ----
    #[serde(rename = "package.op.start")]
    PackageOpStart {
        op: PackageOp,
        name: String,
        old_version: Option<String>,
        new_version: Option<String>,
    },
    #[serde(rename = "package.op.done")]
    PackageOpDone {
        op: PackageOp,
        name: String,
        old_version: Option<String>,
        new_version: Option<String>,
    },
    /// Generic install/upgrade/remove progress with percent. Fired from the
    /// libalpm progress callback (separate from per-file download bytes).
    #[serde(rename = "package.progress")]
    PackageProgress {
        kind: ProgressKind,
        name: String,
        percent: u32,
        current: usize,
        total: usize,
    },

    // ---- Hooks ----
    #[serde(rename = "hook.batch_start")]
    HookBatchStart { when: HookWhen },
    #[serde(rename = "hook.batch_done")]
    HookBatchDone { when: HookWhen },
    #[serde(rename = "hook.run.start")]
    HookRunStart {
        name: String,
        desc: String,
        position: usize,
        total: usize,
    },
    #[serde(rename = "hook.run.done")]
    HookRunDone {
        name: String,
        desc: String,
        position: usize,
        total: usize,
    },

    // ---- Misc events ----
    #[serde(rename = "scriptlet.line")]
    ScriptletLine { line: String },
    #[serde(rename = "pacnew.created")]
    PacnewCreated {
        file: String,
        from_noupgrade: bool,
        old_pkg: Option<String>,
        new_pkg: Option<String>,
    },
    #[serde(rename = "pacsave.created")]
    PacsaveCreated {
        file: String,
        old_pkg: Option<String>,
    },
    #[serde(rename = "optdep.removed")]
    OptdepRemoved { pkg: String, optdep: String },

    // ---- Questions: helper PAUSES until the host sends a response on
    // stdin matching the `id` field. Each variant carries the kind of
    // answer expected (yes/no, choose-one, set-of-numbers).
    #[serde(rename = "question.install_ignorepkg")]
    QInstallIgnorepkg { id: String, name: String },
    #[serde(rename = "question.replace_pkg")]
    QReplacePkg {
        id: String,
        old_pkg: String,
        new_pkg: String,
        new_db: String,
    },
    #[serde(rename = "question.conflict_pkg")]
    QConflictPkg {
        id: String,
        package1: String,
        package2: String,
        reason: String,
    },
    #[serde(rename = "question.corrupted_pkg")]
    QCorruptedPkg {
        id: String,
        name: String,
        reason: String,
    },
    #[serde(rename = "question.remove_pkgs")]
    QRemovePkgs { id: String, packages: Vec<String> },
    #[serde(rename = "question.select_provider")]
    QSelectProvider {
        id: String,
        target: String,
        providers: Vec<String>,
    },
    #[serde(rename = "question.import_key")]
    QImportKey {
        id: String,
        fingerprint: String,
        uid: String,
        created: String,
    },

    // ---- AUR side. makepkg-phase events come from a small stable set
    // of `==> Starting <fn>()...` markers + log-dir inotify, NOT a wide
    // regex on its full output.
    #[serde(rename = "aur.run.start")]
    AurRunStart { packages: Vec<String> },
    #[serde(rename = "aur.run.done")]
    AurRunDone,
    #[serde(rename = "aur.fetch.start")]
    AurFetchStart { name: String },
    #[serde(rename = "aur.fetch.done")]
    AurFetchDone { name: String, success: bool },
    /// PKGBUILD diff available for review (only fires when the host had
    /// previously cached the package's PKGBUILD).
    #[serde(rename = "aur.diff.available")]
    AurDiffAvailable {
        name: String,
        old_path: String,
        new_path: String,
    },
    #[serde(rename = "aur.build.start")]
    AurBuildStart { name: String, work_dir: String },
    #[serde(rename = "aur.phase.start")]
    AurPhaseStart {
        name: String,
        phase: AurPhase,
        log_path: Option<String>,
    },
    #[serde(rename = "aur.phase.done")]
    AurPhaseDone {
        name: String,
        phase: AurPhase,
        success: bool,
        log_path: Option<String>,
    },
    /// Raw makepkg stdout line, for hosts that want to tee it into a
    /// terminal view alongside the structured stream.
    #[serde(rename = "aur.makepkg.line")]
    AurMakepkgLine { name: String, line: String },
    #[serde(rename = "aur.build.done")]
    AurBuildDone {
        name: String,
        success: bool,
        artifacts: Vec<String>,
    },
    #[serde(rename = "aur.install.start")]
    AurInstallStart { packages: Vec<String> },
    #[serde(rename = "aur.install.done")]
    AurInstallDone {
        packages: Vec<String>,
        success: bool,
    },
    #[serde(rename = "aur.error")]
    AurError { name: Option<String>, msg: String },
}

#[derive(Serialize, Debug, Copy, Clone)]
#[serde(rename_all = "snake_case")]
pub enum PackageOp {
    Install,
    Upgrade,
    Reinstall,
    Downgrade,
    Remove,
}

#[derive(Serialize, Debug, Copy, Clone)]
#[serde(rename_all = "snake_case")]
pub enum ProgressKind {
    AddStart,
    UpgradeStart,
    DowngradeStart,
    ReinstallStart,
    RemoveStart,
    ConflictsStart,
    DiskspaceStart,
    IntegrityStart,
    LoadStart,
    KeyringStart,
}

#[derive(Serialize, Debug, Copy, Clone)]
#[serde(rename_all = "snake_case")]
pub enum HookWhen {
    Pre,
    Post,
}

#[derive(Serialize, Debug, Copy, Clone)]
#[serde(rename_all = "snake_case")]
pub enum AurPhase {
    /// `pkgver()` function — version probe before build.
    Pkgver,
    /// `prepare()` — patches, sed, etc.
    Prepare,
    /// `build()` — compile.
    Build,
    /// `check()` — test suite (optional).
    Check,
    /// `package()` — bundle into the install root.
    Package,
    /// makepkg's own integrity verification of source files.
    SourceIntegrity,
    /// Source download via curl/git/etc.
    SourceFetch,
}
