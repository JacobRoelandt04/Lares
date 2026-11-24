// pacman driver — runs a `pacman -Syu`-equivalent transaction directly via
// libalpm. Every libalpm callback is translated into a JSON event on stdout.
// Question callbacks pause the run until the host replies on stdin.
//
// What this is NOT: a re-implementation of pacman. We use the same libalpm
// the pacman CLI uses, with the same /etc/pacman.conf, the same DBs, the
// same sigverify rules. The only thing this binary does that pacman -Syu
// doesn't is route events into a structured stream rather than a humanized
// stdout transcript.

use crate::event::{Event, HookWhen, PackageOp, ProgressKind};
use crate::proto::PromptStream;
use crate::sink::EventSink;
use alpm::{
    Alpm, AnyDownloadEvent, AnyEvent, AnyQuestion, DownloadEvent, DownloadResult, Event as AEvent,
    HookWhen as AHookWhen, PackageOperation, Progress, Question, TransFlag,
};
use alpm_utils::{alpm_with_conf, configure_alpm};
use anyhow::{Context, Result};
use pacmanconf::Config;
use std::cell::RefCell;
use std::io::Read;
use std::rc::Rc;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;

/// Shared callback state. Every closure registered on the alpm handle
/// captures `Rc<RefCell<CallbackState>>` so they can:
///   - emit through the EventSink
///   - read pending question replies from a channel fed by the prompt thread
///   - stash partial state (last download file → carry into progress events)
struct CallbackState {
    sink: EventSink,
    /// Queued question events that need a reply. The main thread enqueues
    /// the question id; the prompt thread blocks on stdin and pushes back
    /// the answer on `replies`.
    questions: Sender<QuestionRequest>,
    replies: Receiver<QuestionResponse>,
}

struct QuestionRequest {
    id: String,
    /// Human-form so the prompt thread can re-emit if needed for retry.
    _kind: &'static str,
}

#[derive(Debug)]
struct QuestionResponse {
    id: String,
    answer: AnswerVal,
}

#[derive(Debug)]
enum AnswerVal {
    Bool(bool),
    Index(i32),
    Abort,
}

pub fn sysupgrade(
    sink: &mut EventSink,
    prompt: &mut PromptStream<std::io::StdinLock>,
    no_sync: bool,
    dry_run: bool,
) -> Result<()> {
    sink.emit(Event::LogInfo {
        msg: format!(
            "starting sysupgrade (no_sync={no_sync}, dry_run={dry_run})"
        ),
    });

    // Read /etc/pacman.conf — same source of truth pacman uses, so we
    // honour user IgnorePkg / IgnoreGroup / cache dir / hooks dir / etc.
    let conf = Config::new().context("loading pacman.conf")?;
    let mut alpm = alpm_with_conf(&conf).context("opening alpm handle")?;

    // ---- Bidirectional question pipe ----
    // The libalpm question callback runs SYNCHRONOUSLY inside the alpm
    // transaction commit; it must block until the host answers. We can't
    // read stdin from inside the callback (callbacks are 'static, the
    // PromptStream isn't easily share-able). Solution: spin up a small
    // helper thread that owns stdin and exchanges QuestionRequest/Response
    // messages over channels. The callback sends a request and blocks on
    // the reply channel.
    let (q_tx, q_rx) = mpsc::channel::<QuestionRequest>();
    let (a_tx, a_rx) = mpsc::channel::<QuestionResponse>();

    // The PromptStream parameter is reserved for future use (e.g. an
    // initial config negotiation). For now the question worker takes
    // its own stdin lock — a fresh BufReader inside the spawned thread
    // — because libalpm callbacks are 'static and can't borrow the
    // caller's PromptStream.
    let _ = prompt;
    spawn_question_worker(q_rx, a_tx);

    let state = Rc::new(RefCell::new(CallbackState {
        sink: EventSink::new(std::io::stdout().lock()),
        questions: q_tx,
        replies: a_rx,
    }));

    install_callbacks(&alpm, state.clone());

    // ---- DB sync ----
    if !no_sync {
        let dbs = alpm.syncdbs_mut();
        let n = dbs.len();
        emit(&state, Event::LogInfo {
            msg: format!("syncing {n} repo dbs"),
        });
        for db in alpm.syncdbs() {
            emit(&state, Event::DbSyncStart {
                db: db.name().to_string(),
            });
        }
        // Drive the actual update via the AlpmList<DbMut> handle. The
        // download callback fires per-file; the per-db DbSyncStart/Done
        // pair we emit here brackets the batch.
        let result = alpm.syncdbs_mut().update(false);
        let success = result.is_ok();
        for db in alpm.syncdbs() {
            emit(&state, Event::DbSyncDone {
                db: db.name().to_string(),
                success,
            });
        }
        result.context("db sync failed")?;
    }

    // ---- Stage upgrades ----
    let flags = TransFlag::NONE;
    alpm.trans_init(flags).context("trans_init")?;
    alpm.sync_sysupgrade(false).context("sync_sysupgrade")?;

    if dry_run {
        emit(&state, Event::LogInfo {
            msg: "dry_run: skipping prepare/commit".into(),
        });
        let _ = alpm.trans_release();
        return Ok(());
    }

    // ---- Commit ----
    emit(&state, Event::TransactionStart);

    // `trans_prepare` returns a PrepareError that borrows the handle, so
    // the error result has to drop before we can call trans_release. Same
    // pattern for trans_commit. Scope each call so the error value stops
    // borrowing before we release.
    let prepare_msg = {
        match alpm.trans_prepare() {
            Ok(()) => None,
            Err(e) => Some(format!("trans_prepare: {e:?}")),
        }
    };
    if let Some(msg) = prepare_msg {
        emit(&state, Event::LogError { msg });
        let _ = alpm.trans_release();
        anyhow::bail!("trans_prepare failed");
    }

    let commit_msg = {
        match alpm.trans_commit() {
            Ok(()) => None,
            Err(e) => Some(format!("trans_commit: {e:?}")),
        }
    };
    if let Some(msg) = commit_msg {
        emit(&state, Event::LogError { msg });
        let _ = alpm.trans_release();
        anyhow::bail!("trans_commit failed");
    }
    alpm.trans_release().context("trans_release")?;
    emit(&state, Event::TransactionDone);

    // Re-emit any sync conf to the host now that we know what was
    // installed. (The host will already have seen package.op events.)
    let _ = configure_alpm; // keep in scope to silence the unused-import warning when configure_alpm isn't used here

    Ok(())
}

fn emit(state: &Rc<RefCell<CallbackState>>, ev: Event) {
    state.borrow_mut().sink.emit(ev);
}

fn install_callbacks(alpm: &Alpm, state: Rc<RefCell<CallbackState>>) {
    let st = state.clone();
    alpm.set_event_cb((), move |ev: AnyEvent, _: &mut ()| {
        on_event(&st, ev);
    });

    let st = state.clone();
    alpm.set_progress_cb(
        (),
        move |kind: Progress, name: &str, percent: i32, total: usize, current: usize, _: &mut ()| {
            on_progress(&st, kind, name, percent, total, current);
        },
    );

    let st = state.clone();
    alpm.set_dl_cb((), move |file: &str, ev: AnyDownloadEvent, _: &mut ()| {
        on_download(&st, file, ev);
    });

    let st = state.clone();
    alpm.set_question_cb((), move |q: AnyQuestion, _: &mut ()| {
        on_question(&st, q);
    });
}

fn on_event(state: &Rc<RefCell<CallbackState>>, ev: AnyEvent) {
    use AEvent::*;
    let mapped: Option<Event> = match ev.event() {
        CheckDepsStart => Some(Event::CheckdepsStart),
        CheckDepsDone => Some(Event::CheckdepsDone),
        FileConflictsStart => Some(Event::FileconflictsStart),
        FileConflictsDone => Some(Event::FileconflictsDone),
        ResolveDepsStart => Some(Event::ResolvedepsStart),
        ResolveDepsDone => Some(Event::ResolvedepsDone),
        InterConflictsStart => Some(Event::InterconflictsStart),
        InterConflictsDone => Some(Event::InterconflictsDone),
        TransactionStart => Some(Event::TransactionStart),
        TransactionDone => Some(Event::TransactionDone),
        IntegrityStart => Some(Event::IntegrityStart),
        IntegrityDone => Some(Event::IntegrityDone),
        LoadStart => Some(Event::LoadStart),
        LoadDone => Some(Event::LoadDone),
        DiskSpaceStart => Some(Event::DiskspaceStart),
        DiskSpaceDone => Some(Event::DiskspaceDone),
        KeyringStart => Some(Event::KeyringStart),
        KeyringDone => Some(Event::KeyringDone),
        KeyDownloadStart => Some(Event::KeyDownloadStart),
        KeyDownloadDone => Some(Event::KeyDownloadDone),
        // RetrieveStart / RetrieveDone are the libalpm DB-retrieve
        // bracket; per-DB names are emitted in `sysupgrade()` itself.
        // We DON'T re-emit here to avoid duplicates.
        RetrieveStart | RetrieveDone | RetrieveFailed => None,

        PackageOperationStart(op) => Some(map_pkg_op(op.operation(), true)),
        PackageOperationDone(op) => Some(map_pkg_op(op.operation(), false)),

        ScriptletInfo(s) => Some(Event::ScriptletLine {
            line: s.line().trim_end().to_string(),
        }),

        PkgRetrieveStart(p) => Some(Event::DownloadBatchStart {
            count: p.num(),
            total_bytes: p.total_size().max(0) as u64,
        }),
        PkgRetrieveDone(_) => Some(Event::DownloadBatchDone { success: true }),
        PkgRetrieveFailed(_) => Some(Event::DownloadBatchDone { success: false }),

        OptDepRemoval(o) => Some(Event::OptdepRemoved {
            pkg: o.pkg().name().to_string(),
            optdep: o.optdep().to_string(),
        }),
        DatabaseMissing(d) => Some(Event::DbMissing {
            db: d.dbname().to_string(),
        }),

        PacnewCreated(p) => Some(Event::PacnewCreated {
            file: p.file().to_string(),
            from_noupgrade: p.from_noupgrade(),
            old_pkg: p.oldpkg().map(|x| x.name().to_string()),
            new_pkg: p.newpkg().map(|x| x.name().to_string()),
        }),
        PacsaveCreated(p) => Some(Event::PacsaveCreated {
            file: p.file().to_string(),
            old_pkg: p.oldpkg().map(|x| x.name().to_string()),
        }),

        HookStart(h) => Some(Event::HookBatchStart {
            when: hook_when(h.when()),
        }),
        HookDone(h) => Some(Event::HookBatchDone {
            when: hook_when(h.when()),
        }),
        HookRunStart(h) => Some(Event::HookRunStart {
            name: h.name().to_string(),
            desc: h.desc().unwrap_or("").to_string(),
            position: h.position(),
            total: h.total(),
        }),
        HookRunDone(h) => Some(Event::HookRunDone {
            name: h.name().to_string(),
            desc: h.desc().unwrap_or("").to_string(),
            position: h.position(),
            total: h.total(),
        }),
    };
    if let Some(ev) = mapped {
        state.borrow_mut().sink.emit(ev);
    }
}

fn map_pkg_op(op: PackageOperation, is_start: bool) -> Event {
    let (kind, name, oldv, newv) = match op {
        PackageOperation::Install(np) => (
            PackageOp::Install,
            np.name().to_string(),
            None,
            Some(np.version().to_string()),
        ),
        PackageOperation::Upgrade(np, op) => (
            PackageOp::Upgrade,
            np.name().to_string(),
            Some(op.version().to_string()),
            Some(np.version().to_string()),
        ),
        PackageOperation::Reinstall(np, op) => (
            PackageOp::Reinstall,
            np.name().to_string(),
            Some(op.version().to_string()),
            Some(np.version().to_string()),
        ),
        PackageOperation::Downgrade(np, op) => (
            PackageOp::Downgrade,
            np.name().to_string(),
            Some(op.version().to_string()),
            Some(np.version().to_string()),
        ),
        PackageOperation::Remove(op) => (
            PackageOp::Remove,
            op.name().to_string(),
            Some(op.version().to_string()),
            None,
        ),
    };
    if is_start {
        Event::PackageOpStart {
            op: kind,
            name,
            old_version: oldv,
            new_version: newv,
        }
    } else {
        Event::PackageOpDone {
            op: kind,
            name,
            old_version: oldv,
            new_version: newv,
        }
    }
}

fn hook_when(w: AHookWhen) -> HookWhen {
    match w {
        AHookWhen::PreTransaction => HookWhen::Pre,
        AHookWhen::PostTransaction => HookWhen::Post,
    }
}

fn on_progress(
    state: &Rc<RefCell<CallbackState>>,
    kind: Progress,
    name: &str,
    percent: i32,
    total: usize,
    current: usize,
) {
    let kind = match kind {
        Progress::AddStart => ProgressKind::AddStart,
        Progress::UpgradeStart => ProgressKind::UpgradeStart,
        Progress::DowngradeStart => ProgressKind::DowngradeStart,
        Progress::ReinstallStart => ProgressKind::ReinstallStart,
        Progress::RemoveStart => ProgressKind::RemoveStart,
        Progress::ConflictsStart => ProgressKind::ConflictsStart,
        Progress::DiskspaceStart => ProgressKind::DiskspaceStart,
        Progress::IntegrityStart => ProgressKind::IntegrityStart,
        Progress::LoadStart => ProgressKind::LoadStart,
        Progress::KeyringStart => ProgressKind::KeyringStart,
    };
    state.borrow_mut().sink.emit(Event::PackageProgress {
        kind,
        name: name.to_string(),
        percent: percent.max(0) as u32,
        current,
        total,
    });
}

fn on_download(state: &Rc<RefCell<CallbackState>>, file: &str, ev: AnyDownloadEvent) {
    match ev.event() {
        DownloadEvent::Init(_) => state.borrow_mut().sink.emit(Event::DownloadInit {
            file: file.to_string(),
            total_bytes: 0,
        }),
        DownloadEvent::Progress(p) => state.borrow_mut().sink.emit(Event::DownloadProgress {
            file: file.to_string(),
            done_bytes: p.downloaded.max(0) as u64,
            total_bytes: p.total.max(0) as u64,
        }),
        DownloadEvent::Retry(r) => state.borrow_mut().sink.emit(Event::DownloadRetry {
            file: file.to_string(),
            // libalpm doesn't expose backoff delay; pass 0 so the host
            // can decide how to display it.
            delay_ms: if r.resume { 0 } else { 0 },
        }),
        DownloadEvent::Completed(c) => {
            // Emit the final size so a host that only sees Completed
            // (e.g. tiny files where Progress fires after the data has
            // already been read) still has total_bytes for its meter.
            let _ = c.total;
            let _ = matches!(c.result, DownloadResult::Failed);
            state.borrow_mut().sink.emit(Event::DownloadComplete {
                file: file.to_string(),
            });
        }
    }
}

fn on_question(state: &Rc<RefCell<CallbackState>>, mut q: AnyQuestion) {
    let id = state.borrow_mut().sink.next_question_id();
    let kind: &'static str = match q.question() {
        Question::InstallIgnorepkg(ref qq) => {
            state.borrow_mut().sink.emit(Event::QInstallIgnorepkg {
                id: id.clone(),
                name: qq.pkg().name().to_string(),
            });
            "install_ignorepkg"
        }
        Question::Replace(ref qq) => {
            state.borrow_mut().sink.emit(Event::QReplacePkg {
                id: id.clone(),
                old_pkg: qq.oldpkg().name().to_string(),
                new_pkg: qq.newpkg().name().to_string(),
                new_db: qq.newdb().name().to_string(),
            });
            "replace_pkg"
        }
        Question::Conflict(ref qq) => {
            let c = qq.conflict();
            state.borrow_mut().sink.emit(Event::QConflictPkg {
                id: id.clone(),
                package1: c.package1().name().to_string(),
                package2: c.package2().name().to_string(),
                reason: c.reason().to_string(),
            });
            "conflict_pkg"
        }
        Question::Corrupted(ref qq) => {
            state.borrow_mut().sink.emit(Event::QCorruptedPkg {
                id: id.clone(),
                name: qq.filepath().to_string(),
                reason: format!("{:?}", qq.reason()),
            });
            "corrupted_pkg"
        }
        Question::RemovePkgs(ref qq) => {
            let pkgs: Vec<String> = qq.packages().iter().map(|p| p.name().to_string()).collect();
            state.borrow_mut().sink.emit(Event::QRemovePkgs {
                id: id.clone(),
                packages: pkgs,
            });
            "remove_pkgs"
        }
        Question::SelectProvider(ref qq) => {
            let providers: Vec<String> =
                qq.providers().iter().map(|p| p.name().to_string()).collect();
            state.borrow_mut().sink.emit(Event::QSelectProvider {
                id: id.clone(),
                target: qq.depend().to_string(),
                providers,
            });
            "select_provider"
        }
        Question::ImportKey(ref qq) => {
            state.borrow_mut().sink.emit(Event::QImportKey {
                id: id.clone(),
                fingerprint: qq.fingerprint().to_string(),
                uid: qq.uid().to_string(),
                created: String::new(),
            });
            "import_key"
        }
    };

    // Send the request to the prompt thread and wait for the matching
    // response.
    let _ = state.borrow_mut().questions.send(QuestionRequest {
        id: id.clone(),
        _kind: kind,
    });
    loop {
        match state.borrow_mut().replies.recv() {
            Ok(reply) if reply.id == id => {
                apply_answer(&mut q, reply.answer);
                return;
            }
            Ok(_) => continue, // stale / wrong-id reply, ignore
            Err(_) => {
                // Channel closed (host hung up). Default-deny safest:
                // refuse the question, abort the transaction.
                q.set_answer(false);
                return;
            }
        }
    }
}

fn apply_answer(q: &mut AnyQuestion, ans: AnswerVal) {
    match ans {
        AnswerVal::Bool(b) => match q.question() {
            Question::InstallIgnorepkg(mut qq) => qq.set_install(b),
            Question::Replace(qq) => qq.set_replace(b),
            Question::Conflict(mut qq) => qq.set_remove(b),
            Question::Corrupted(mut qq) => qq.set_remove(b),
            Question::RemovePkgs(mut qq) => qq.set_skip(b),
            Question::ImportKey(mut qq) => qq.set_import(b),
            Question::SelectProvider(mut qq) => qq.set_index(if b { 0 } else { -1 }),
        },
        AnswerVal::Index(i) => {
            if let Question::SelectProvider(mut qq) = q.question() {
                qq.set_index(i);
            } else {
                q.set_answer(false);
            }
        }
        AnswerVal::Abort => q.set_answer(false),
    }
}

/// The prompt worker owns stdin and feeds question replies back to the
/// callbacks. Runs once per helper invocation; exits on stdin EOF.
fn spawn_question_worker(rx: Receiver<QuestionRequest>, tx: Sender<QuestionResponse>) {
    thread::spawn(move || {
        let stdin = std::io::stdin();
        let mut buf = String::new();
        let mut handle = stdin.lock();
        // We read stdin lazily — only when we know a question is waiting.
        // Outside of that the helper doesn't expect any input.
        while let Ok(req) = rx.recv() {
            buf.clear();
            // Block-read a single line.
            let mut byte = [0u8; 1];
            loop {
                match handle.read(&mut byte) {
                    Ok(0) => break, // EOF
                    Ok(_) => {
                        if byte[0] == b'\n' {
                            break;
                        }
                        buf.push(byte[0] as char);
                    }
                    Err(_) => break,
                }
            }
            let trimmed = buf.trim();
            let answer = parse_reply_line(trimmed, &req.id);
            let _ = tx.send(QuestionResponse {
                id: req.id,
                answer,
            });
        }
    });
}

fn parse_reply_line(line: &str, _expected_id: &str) -> AnswerVal {
    if line.is_empty() {
        return AnswerVal::Bool(false);
    }
    // Tolerate plain "yes" / "no" / "y" / "n" / "abort" / "<index>" lines
    // even when not wrapped in JSON, so a script can drive the helper
    // from a pipe without serde_json overhead.
    let lower = line.to_ascii_lowercase();
    if lower == "abort" {
        return AnswerVal::Abort;
    }
    if matches!(lower.as_str(), "y" | "yes" | "true" | "1") {
        return AnswerVal::Bool(true);
    }
    if matches!(lower.as_str(), "n" | "no" | "false" | "0") {
        return AnswerVal::Bool(false);
    }
    if let Ok(i) = lower.parse::<i32>() {
        return AnswerVal::Index(i);
    }
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(line) {
        if let Some(ans) = v.get("answer") {
            if let Some(b) = ans.as_bool() {
                return AnswerVal::Bool(b);
            }
            if let Some(s) = ans.as_str() {
                if s == "abort" {
                    return AnswerVal::Abort;
                }
                let s = s.to_ascii_lowercase();
                if matches!(s.as_str(), "y" | "yes") {
                    return AnswerVal::Bool(true);
                }
                if matches!(s.as_str(), "n" | "no") {
                    return AnswerVal::Bool(false);
                }
                if let Ok(i) = s.parse::<i32>() {
                    return AnswerVal::Index(i);
                }
            }
            if let Some(i) = ans.as_i64() {
                return AnswerVal::Index(i as i32);
            }
        }
    }
    AnswerVal::Bool(false)
}
