// AUR orchestrator — wraps `paru -Syua --noconfirm` (or one-shot
// `paru -S <name>`) and translates the small stable set of `==>` markers
// in its stdout into structured `aur.*` events.
//
// Why wrap rather than re-implement: AUR builds = `makepkg`, which is a
// shell script that drives a series of pkgbuild functions. We don't get
// libalpm-style callbacks here — but the `==>` prefix lines makepkg
// emits at every phase boundary (`==> Starting build()...`, etc.) are
// stable, narrow, and used by every wrapper. Parsing those gives us 95%
// of the structure with ~50 lines of regex versus reimplementing the
// dependency resolver, source fetcher, and PKGBUILD evaluator.
//
// The helper still surfaces every raw paru/makepkg line as
// `aur.makepkg.line` events so a verbose-mode terminal view in the host
// can render the original transcript alongside the structured stream.

use crate::event::{AurPhase, Event};
use crate::proto::PromptStream;
use crate::sink::EventSink;
use anyhow::{Context, Result};
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};

pub fn upgrade(
    sink: &mut EventSink,
    _prompt: &mut PromptStream<std::io::StdinLock>,
    dry_run: bool,
) -> Result<()> {
    sink.emit(Event::AurRunStart {
        // Names are filled in below as `==> Making package:` lines arrive;
        // we don't pre-resolve to keep this binary independent of the AUR
        // RPC. Hosts that want pre-flight info should call paru's
        // `paru -Qua --aur` themselves and pass the list to the helper.
        packages: vec![],
    });

    if dry_run {
        sink.emit(Event::LogInfo {
            msg: "dry_run: skipping paru invocation".into(),
        });
        sink.emit(Event::AurRunDone);
        return Ok(());
    }

    run_paru(sink, &["-Syua", "--noconfirm", "--useask"])?;
    sink.emit(Event::AurRunDone);
    Ok(())
}

pub fn build_and_install_one(
    sink: &mut EventSink,
    _prompt: &mut PromptStream<std::io::StdinLock>,
    name: &str,
    dry_run: bool,
) -> Result<()> {
    sink.emit(Event::AurRunStart {
        packages: vec![name.to_string()],
    });
    if dry_run {
        sink.emit(Event::LogInfo {
            msg: format!("dry_run: would build+install {name}"),
        });
        sink.emit(Event::AurRunDone);
        return Ok(());
    }
    run_paru(sink, &["-S", "--aur", "--noconfirm", name])?;
    sink.emit(Event::AurRunDone);
    Ok(())
}

fn run_paru(sink: &mut EventSink, args: &[&str]) -> Result<()> {
    let helper = pick_helper()?;
    sink.emit(Event::LogInfo {
        msg: format!("invoking {helper} {}", args.join(" ")),
    });

    let mut cmd = Command::new(&helper);
    cmd.args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    // makepkg refuses to run as root. If we're invoked via sudo, drop to
    // the original user before exec'ing the AUR wrapper. paru itself will
    // sudo back up for `pacman -U` at install time.
    if let Ok(sudo_user) = std::env::var("SUDO_USER") {
        sink.emit(Event::LogInfo {
            msg: format!("dropping to user {sudo_user} for makepkg"),
        });
        // `runuser` preserves env better than `su`; avoids password
        // prompt because we're already root.
        let mut runuser = Command::new("runuser");
        runuser
            .args(["-u", &sudo_user, "--", &helper])
            .args(args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        cmd = runuser;
    }

    let mut child = cmd
        .spawn()
        .with_context(|| format!("spawning {helper}"))?;

    // Read stdout line-by-line, emitting raw + structured events.
    let stdout = child
        .stdout
        .take()
        .context("paru stdout was not piped")?;
    let stderr = child
        .stderr
        .take()
        .context("paru stderr was not piped")?;

    // Stderr in a thread so we don't deadlock if paru fills its stderr
    // pipe before stdout drains. Just relay each line as a log.warn so
    // hosts can surface it.
    let stderr_handle = std::thread::spawn(move || {
        let reader = BufReader::new(stderr);
        for line in reader.lines().map_while(Result::ok) {
            // Channel back through stdout — we keep a single sink to
            // preserve event ordering.
            let mut s = EventSink::new(std::io::stdout().lock());
            s.emit(Event::LogWarn {
                msg: format!("paru[stderr]: {line}"),
            });
        }
    });

    let mut current_pkg: Option<String> = None;
    let mut current_phase: Option<AurPhase> = None;
    let reader = BufReader::new(stdout);
    for line in reader.lines().map_while(Result::ok) {
        // Always relay raw line for verbose-mode terminal view.
        sink.emit(Event::AurMakepkgLine {
            name: current_pkg.clone().unwrap_or_default(),
            line: line.clone(),
        });

        translate_marker(sink, &line, &mut current_pkg, &mut current_phase);
    }

    let status = child.wait().context("paru exit")?;
    let _ = stderr_handle.join();

    if !status.success() {
        sink.emit(Event::AurError {
            name: current_pkg.clone(),
            msg: format!("paru exited {}", status.code().unwrap_or(-1)),
        });
        anyhow::bail!("paru failed");
    }

    Ok(())
}

/// Decide which AUR helper to wrap. Prefer paru, fall back to yay.
fn pick_helper() -> Result<String> {
    for candidate in ["paru", "yay"] {
        if which(candidate) {
            return Ok(candidate.to_string());
        }
    }
    anyhow::bail!("neither paru nor yay found in PATH")
}

fn which(prog: &str) -> bool {
    if let Ok(path) = std::env::var("PATH") {
        for dir in path.split(':') {
            if std::path::Path::new(dir).join(prog).exists() {
                return true;
            }
        }
    }
    false
}

/// Translate a single makepkg/paru output line into structured events.
/// We intentionally match a tiny stable set of markers — the rest of
/// the line is already in `aur.makepkg.line` for hosts to render.
fn translate_marker(
    sink: &mut EventSink,
    line: &str,
    current_pkg: &mut Option<String>,
    current_phase: &mut Option<AurPhase>,
) {
    // Strip ANSI before matching — paru/makepkg colourize most output.
    let stripped = strip_ansi(line);
    let s = stripped.trim();

    // ":: Looking for AUR packages..." → start of resolution. We don't
    // emit a discrete event for it; the AurRunStart already covered it.

    // "==> Making package: <name> <version>"
    if let Some(rest) = s.strip_prefix("==> Making package: ") {
        let name = rest.split_whitespace().next().unwrap_or("").to_string();
        if !name.is_empty() {
            // Close out the previous pkg's phase if any.
            if let (Some(prev_name), Some(prev_phase)) = (current_pkg.clone(), current_phase.take())
            {
                sink.emit(Event::AurPhaseDone {
                    name: prev_name.clone(),
                    phase: prev_phase,
                    success: true,
                    log_path: None,
                });
                sink.emit(Event::AurBuildDone {
                    name: prev_name,
                    success: true,
                    artifacts: vec![],
                });
            }
            sink.emit(Event::AurBuildStart {
                name: name.clone(),
                work_dir: String::new(),
            });
            *current_pkg = Some(name);
        }
        return;
    }

    // "==> Starting <fn>()..."
    if let Some(rest) = s.strip_prefix("==> Starting ") {
        if let Some(fn_name) = rest.strip_suffix("()...") {
            let phase = match fn_name {
                "pkgver" => AurPhase::Pkgver,
                "prepare" => AurPhase::Prepare,
                "build" => AurPhase::Build,
                "check" => AurPhase::Check,
                "package" => AurPhase::Package,
                _ => return,
            };
            // Close out the previous phase if still open.
            if let (Some(name), Some(prev)) = (current_pkg.clone(), current_phase.take()) {
                sink.emit(Event::AurPhaseDone {
                    name,
                    phase: prev,
                    success: true,
                    log_path: None,
                });
            }
            if let Some(name) = current_pkg.clone() {
                sink.emit(Event::AurPhaseStart {
                    name,
                    phase,
                    log_path: None,
                });
                *current_phase = Some(phase);
            }
            return;
        }
    }

    // "==> Retrieving sources..." / "==> Checking source integrity..."
    if s.starts_with("==> Retrieving sources") {
        if let Some(name) = current_pkg.clone() {
            sink.emit(Event::AurPhaseStart {
                name,
                phase: AurPhase::SourceFetch,
                log_path: None,
            });
            *current_phase = Some(AurPhase::SourceFetch);
        }
        return;
    }
    if s.starts_with("==> Validating source files with ") {
        if let Some(name) = current_pkg.clone() {
            // Close the SourceFetch phase if open and start integrity.
            if let Some(prev) = current_phase.take() {
                sink.emit(Event::AurPhaseDone {
                    name: name.clone(),
                    phase: prev,
                    success: true,
                    log_path: None,
                });
            }
            sink.emit(Event::AurPhaseStart {
                name,
                phase: AurPhase::SourceIntegrity,
                log_path: None,
            });
            *current_phase = Some(AurPhase::SourceIntegrity);
        }
        return;
    }

    // "==> Finished making: <name> <ver> (...)"
    if let Some(rest) = s.strip_prefix("==> Finished making: ") {
        let name = rest.split_whitespace().next().unwrap_or("").to_string();
        if let (Some(open_name), Some(prev)) = (current_pkg.clone(), current_phase.take()) {
            sink.emit(Event::AurPhaseDone {
                name: open_name.clone(),
                phase: prev,
                success: true,
                log_path: None,
            });
        }
        sink.emit(Event::AurBuildDone {
            name: name.clone(),
            success: true,
            artifacts: vec![],
        });
        if current_pkg.as_deref() == Some(name.as_str()) {
            *current_pkg = None;
        }
        return;
    }

    // ":: Cloning <pkg> AUR repo" — fetch markers paru emits.
    if let Some(rest) = s.strip_prefix(":: Cloning ") {
        if let Some(name) = rest.split(' ').next() {
            sink.emit(Event::AurFetchStart {
                name: name.to_string(),
            });
        }
        return;
    }
    if let Some(rest) = s.strip_prefix(":: Updating ") {
        if rest.contains(" AUR ") {
            if let Some(name) = rest.split(' ').next() {
                sink.emit(Event::AurFetchStart {
                    name: name.to_string(),
                });
            }
        }
        return;
    }

    // Errors:
    if s.starts_with("error: ") || s.starts_with("==> ERROR:") {
        sink.emit(Event::AurError {
            name: current_pkg.clone(),
            msg: s.to_string(),
        });
    }
}

/// Strip ANSI SGR / CSI sequences. We don't need a full terminal emulator
/// — `\x1b[<...>m` and the occasional clear-line are the only sequences
/// makepkg/paru produce.
fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == 0x1b && i + 1 < bytes.len() && bytes[i + 1] == b'[' {
            // skip until a final byte (in @-~)
            i += 2;
            while i < bytes.len() {
                let c = bytes[i];
                i += 1;
                if (0x40..=0x7E).contains(&c) {
                    break;
                }
            }
            continue;
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}
