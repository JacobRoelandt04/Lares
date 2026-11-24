//! Arguments, the three ways the helper can run, and the answer's envelope.
//!
//!   real    euid 0, no test option      writes the real machine (pkexec, systemd units)
//!   test    euid != 0, a test option    writes only under the test roots; nothing is executed
//!   plain   euid != 0, no test option   `status` only: a write is refused (nothing can be
//!                                       written without root anyway; this says so)
//!
//! As root, ANY test option or variable is refused before anything is read or written: a
//! fake `/sys` must never be able to stand in for the real one in a root process, nor a
//! fault be armed there.

use std::path::PathBuf;

use crate::boost;
use crate::commands;
use crate::ctx::{Ctx, Outcome};
use crate::json::Json;
use crate::machine::Machine;
use crate::mux;
use crate::platform::{Platform, Real, Simulated};
use crate::report::{self, Answer};
use crate::roots::{Roots, TestOpts};
use crate::state::{State, Wiring};
use crate::wifi;
use crate::writer::Faults;

/// What the helper reads from its environment: nothing but these.
#[derive(Debug, Default, Clone)]
pub struct Env {
    /// `PKEXEC_UID` is set: pkexec started us.
    pub pkexec: bool,
    /// `SILICON_TEST_FAULTS`
    pub faults: Option<String>,
    /// `SILICON_TEST_REBOOT`
    pub reboot_file: Option<PathBuf>,
}

impl Env {
    pub fn from_process() -> Env {
        Env {
            pkexec: std::env::var_os("PKEXEC_UID").is_some(),
            faults: std::env::var_os("SILICON_TEST_FAULTS").map(|v| v.to_string_lossy().into_owned()),
            reboot_file: std::env::var_os("SILICON_TEST_REBOOT").map(PathBuf::from),
        }
    }
}

pub struct Output {
    pub json: String,
    pub code: i32,
    /// Diagnostics for stderr; the caller parses stdout only.
    pub stderr: Vec<String>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Command {
    Status,
    Apply,
    SetChargeLimit,
    SetBoot,
    MuxRequest,
    MuxCancel,
    MuxPromptShown,
    MuxConfirm,
    RecordCaps,
    BootApply,
    MuxApply,
    MuxGuard,
    WifiPowersave,
    Capabilities,
    BoostServe,
    BoostRestore,
}

impl Command {
    fn parse(word: &str) -> Option<Command> {
        Some(match word {
            "status" => Command::Status,
            "apply" => Command::Apply,
            "set-charge-limit" => Command::SetChargeLimit,
            "set-boot" => Command::SetBoot,
            "mux-request" => Command::MuxRequest,
            "mux-cancel" => Command::MuxCancel,
            "mux-prompt-shown" => Command::MuxPromptShown,
            "mux-confirm" => Command::MuxConfirm,
            "record-caps" => Command::RecordCaps,
            "boot-apply" => Command::BootApply,
            "mux-apply" => Command::MuxApply,
            "mux-guard" => Command::MuxGuard,
            "wifi-powersave" => Command::WifiPowersave,
            "capabilities" => Command::Capabilities,
            "boost-serve" => Command::BoostServe,
            "boost-restore" => Command::BoostRestore,
            _ => return None,
        })
    }

    /// Only systemd starts these; pkexec never may.
    fn systemd_only(self) -> bool {
        matches!(
            self,
            Command::RecordCaps
                | Command::BootApply
                | Command::MuxApply
                | Command::MuxGuard
                | Command::BoostServe
                | Command::BoostRestore
        )
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Mode {
    Real,
    Test,
    Plain,
}

pub fn bare(why: impl Into<String>, code: i32) -> Output {
    let answer = Answer { ok: false, results: None, why: Some(why.into()), status: None };
    Output { json: answer.to_json().render(), code, stderr: Vec::new() }
}

/// Every verb, as `capabilities` lists them.
const VERBS: [&str; 16] = [
    "status",
    "apply",
    "set-charge-limit",
    "set-boot",
    "mux-request",
    "mux-cancel",
    "mux-prompt-shown",
    "mux-confirm",
    "record-caps",
    "boot-apply",
    "mux-apply",
    "mux-guard",
    "wifi-powersave",
    "capabilities",
    "boost-serve",
    "boost-restore",
];

const TEST_OPTIONS: [&str; 6] =
    ["--sysfs-root", "--proc-root", "--state-dir", "--dev-root", "--modules-root", "--run-root"];

/// Split `args` into the test options and the positional words.
fn split_args(args: &[String]) -> Result<(TestOpts, Vec<String>), String> {
    let mut opts = TestOpts::default();
    let mut words = Vec::new();
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        let Some(rest) = arg.strip_prefix("--") else {
            words.push(arg.clone());
            continue;
        };
        let (name, inline) = match rest.split_once('=') {
            Some((n, v)) => (format!("--{n}"), Some(v.to_string())),
            None => (arg.clone(), None),
        };
        let slot = match name.as_str() {
            "--sysfs-root" => &mut opts.sysfs_root,
            "--proc-root" => &mut opts.proc_root,
            "--state-dir" => &mut opts.state_dir,
            "--dev-root" => &mut opts.dev_root,
            "--modules-root" => &mut opts.modules_root,
            "--run-root" => &mut opts.run_root,
            _ => return Err(format!("unknown option {name}")),
        };
        let value = match inline {
            Some(v) => v,
            None => it.next().cloned().ok_or_else(|| format!("{name} needs a directory"))?,
        };
        if value.is_empty() {
            return Err(format!("{name} needs a directory"));
        }
        if slot.replace(PathBuf::from(value)).is_some() {
            return Err(format!("{name} given twice"));
        }
    }
    Ok((opts, words))
}

/// Run one invocation. `euid` is the caller's effective uid (main reads it; tests pass 0 to
/// prove the root refusals without ever being root).
pub fn run(args: &[String], env: &Env, euid: u32) -> Output {
    // 1. Test mode as root: refused first, before anything is parsed, read or written.
    let test_named = args
        .iter()
        .any(|a| TEST_OPTIONS.iter().any(|o| a == o || a.strip_prefix(o).is_some_and(|r| r.starts_with('='))));
    let test_requested = test_named || env.faults.is_some() || env.reboot_file.is_some();
    if euid == 0 && test_requested {
        return bare("test mode (--sysfs-root, --proc-root, --state-dir, --dev-root, --modules-root, --run-root, SILICON_TEST_FAULTS, SILICON_TEST_REBOOT) is refused when running as root", 4);
    }

    // 2. Syntax.
    let (opts, words) = match split_args(args) {
        Ok(v) => v,
        Err(why) => return bare(why, 2),
    };
    let Some((first, rest)) = words.split_first() else {
        return bare("no command: status, apply, set-charge-limit, set-boot, mux-request, mux-cancel, mux-prompt-shown, mux-confirm, wifi-powersave, capabilities (record-caps, boot-apply, mux-apply, mux-guard, boost-serve and boost-restore are systemd's)", 2);
    };
    let Some(command) = Command::parse(first) else {
        return bare(format!("unknown command '{first}'"), 2);
    };

    // 3. What may run here.
    if command.systemd_only() && env.pkexec {
        return bare(format!("{first} is for systemd only and is refused under pkexec"), 2);
    }
    let mode = match (euid == 0, test_requested) {
        (true, _) => Mode::Real,
        (false, true) => Mode::Test,
        (false, false) => Mode::Plain,
    };
    if command != Command::Status && command != Command::Capabilities {
        match mode {
            Mode::Plain if command.systemd_only() => {
                return bare(format!("{first} is for systemd (as root) only; it writes, so it is not run here"), 2);
            }
            Mode::Plain => return bare(format!("{first} writes: run it through pkexec (or give the test options)"), 2),
            Mode::Test if matches!(command, Command::BoostServe | Command::BoostRestore) => {
                if opts.sysfs_root.is_none() || opts.run_root.is_none() {
                    return bare(format!("test mode needs --sysfs-root and --run-root for {first}"), 2);
                }
            }
            Mode::Test if opts.sysfs_root.is_none() || opts.state_dir.is_none() => {
                return bare(format!("test mode needs --sysfs-root and --state-dir for {first}"), 2);
            }
            _ => {}
        }
    }
    let faults = match env.faults.as_deref().map(Faults::parse) {
        None => Faults::none(),
        Some(Ok(f)) => f,
        Some(Err(why)) => return bare(format!("SILICON_TEST_FAULTS: {why}"), 2),
    };

    // 4. The world it will look at.
    let roots = match if test_requested { Roots::from_test(&opts) } else { Roots::real() } {
        Ok(r) => r,
        Err(why) => return bare(why, 3),
    };
    let st = State::new(roots.state.clone());
    let real = Real;
    let simulated = Simulated::new(roots.clone(), env.reboot_file.clone());
    let platform: &dyn Platform = if mode == Mode::Real { &real } else { &simulated };
    let ctx = Ctx { roots: &roots, faults: &faults, platform, st: &st };

    // 5. Do it.
    let outcome = match command {
        Command::Status => return status(&roots),
        Command::Capabilities => return capabilities(),
        Command::WifiPowersave => return wifi_powersave(&ctx, rest),
        Command::BoostServe => {
            return match boost::parse_args(rest) {
                Ok(cfg) => boost_answer(boost::serve(&roots, &faults, &cfg, mode == Mode::Real)),
                Err(why) => bare(why, 2),
            }
        }
        Command::BoostRestore if !rest.is_empty() => return bare("boost-restore takes no arguments", 2),
        Command::BoostRestore => return boost_answer(boost::restore(&roots, &faults)),
        Command::Apply => commands::apply(&ctx, rest),
        Command::SetChargeLimit => commands::set_charge_limit(&ctx, rest),
        Command::SetBoot => commands::set_boot(&ctx, rest),
        Command::MuxRequest => match rest {
            [w] => match Wiring::parse(w) {
                Some(want) => mux::request(&ctx, want),
                None => Outcome::usage("mux-request takes dgpu or hybrid"),
            },
            _ => Outcome::usage("mux-request takes one value: dgpu or hybrid"),
        },
        Command::MuxCancel
        | Command::MuxPromptShown
        | Command::MuxConfirm
        | Command::RecordCaps
        | Command::BootApply
        | Command::MuxApply
        | Command::MuxGuard
            if !rest.is_empty() =>
        {
            Outcome::usage(format!("{first} takes no arguments"))
        }
        Command::MuxCancel => mux::cancel(&ctx),
        Command::MuxPromptShown => mux::prompt_shown(&ctx),
        Command::MuxConfirm => mux::confirm(&ctx),
        Command::RecordCaps => commands::record_caps(&ctx),
        Command::BootApply => commands::boot_apply(&ctx),
        Command::MuxApply => mux::apply(&ctx),
        Command::MuxGuard => mux::guard(&ctx),
    };
    finish(&roots, outcome, !command.systemd_only())
}

/// `capabilities`: the verbs this build knows, for anyone (no root, nothing read): a caller learns whether the
/// INSTALLED helper has a verb that was added after it was installed (`lares setup`, the Wi-Fi power-save watcher)
/// without asking the verb itself, which an older helper answers with "unknown command".
fn capabilities() -> Output {
    let verbs: Vec<String> = VERBS.iter().map(|v| v.to_string()).collect();
    let answer =
        Json::obj([("ok", Json::Bool(true)), ("proto", Json::Int(report::PROTO)), ("verbs", Json::strs(&verbs))]);
    Output { json: answer.render(), code: 0, stderr: Vec::new() }
}

/// The answer of `boost-serve` (when it stops) and `boost-restore`: only whether it ended well; the journal has the rest.
fn boost_answer((code, why): (i32, String)) -> Output {
    if code == 0 {
        let answer = Json::obj([("ok", Json::Bool(true)), ("proto", Json::Int(report::PROTO))]);
        Output { json: answer.render(), code: 0, stderr: Vec::new() }
    } else {
        bare(why, code)
    }
}

/// `wifi-powersave <iface> on|off`: validated, run by absolute path, read back.
fn wifi_powersave(ctx: &Ctx, words: &[String]) -> Output {
    let [iface, state] = words else { return bare("wifi-powersave takes an interface and on or off", 2) };
    let on = match state.as_str() {
        "on" => true,
        "off" => false,
        _ => return bare("wifi-powersave takes on or off", 2),
    };
    match wifi::set_power_save(ctx, iface, on) {
        Ok(now) => {
            let wifi = Json::obj([
                ("iface", Json::str(iface.as_str())),
                ("powerSave", Json::str(if now { "on" } else { "off" })),
            ]);
            let answer = Json::obj([("ok", Json::Bool(true)), ("proto", Json::Int(report::PROTO)), ("wifi", wifi)]);
            Output { json: answer.render(), code: 0, stderr: Vec::new() }
        }
        Err((code, why)) => bare(why, code),
    }
}

fn status(roots: &Roots) -> Output {
    let machine = Machine::discover(roots);
    let stderr = machine.notes.clone();
    let answer = Answer { ok: true, results: None, why: None, status: Some(report::status_json(&machine)) };
    Output { json: answer.to_json().render(), code: 0, stderr }
}

/// Wrap a write command's outcome: the results, the exit code, and the status as it is NOW. The commands the shell
/// runs get the full status (it replaces the shell's own copy, `paths` included). systemd's own -- `boot-apply`,
/// `mux-apply`, `mux-guard`, `record-caps`, whose answers only reach the journal -- never read the NVIDIA driver's
/// proc entry (`paths.dgpu.nvidia` reads null): at shutdown and at boot a driver that is going down or coming up
/// is the one to trust least, and nothing those commands do may wait on it.
fn finish(roots: &Roots, o: Outcome, full: bool) -> Output {
    let machine = if full { Machine::discover(roots) } else { Machine::discover_for_write(roots) };
    let mut stderr = o.notes;
    stderr.extend(machine.notes.iter().cloned());
    if let Some(why) = &o.why {
        stderr.push(why.clone());
    }
    for e in o.entries.iter().filter(|e| !e.ok()) {
        stderr.push(format!("{}: {} ({})", e.knob.name(), e.why, e.code.as_str()));
    }
    let answer =
        Answer { ok: o.code == 0, results: Some(o.entries), why: o.why, status: Some(report::status_json(&machine)) };
    Output { json: answer.to_json().render(), code: o.code, stderr }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn tmpdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("sh-cli-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(d.join("sys")).unwrap();
        fs::write(d.join("marker"), "untouched").unwrap();
        d
    }

    fn args(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    fn listing(d: &std::path::Path) -> Vec<String> {
        let mut out = Vec::new();
        fn walk(dir: &std::path::Path, out: &mut Vec<String>) {
            for e in fs::read_dir(dir).unwrap() {
                let e = e.unwrap();
                let p = e.path();
                out.push(format!(
                    "{}:{}",
                    p.display(),
                    if p.is_file() { fs::read_to_string(&p).unwrap_or_default() } else { String::new() }
                ));
                if p.is_dir() {
                    walk(&p, out);
                }
            }
        }
        walk(d, &mut out);
        out.sort();
        out
    }

    /// ARM: test mode as root. The euid is PASSED IN as 0; this test never runs as root.
    #[test]
    fn arm_test_mode_as_root_is_refused_before_anything_is_read_or_written() {
        let d = tmpdir("root");
        let dir = d.display().to_string();
        let before = listing(&d);
        for opt in TEST_OPTIONS {
            for cmd in ["status", "apply", "record-caps", "boot-apply", "mux-guard", "set-charge-limit", "frobnicate"] {
                let out = run(&args(&[opt, &dir, cmd]), &Env::default(), 0);
                assert_eq!(out.code, 4, "{opt} {cmd}: {}", out.json);
                assert!(out.json.contains("refused when running as root"), "{}", out.json);
                assert!(out.json.contains("\"ok\":false"));
                // the --opt=value form, and the option after the command
                let out = run(&args(&[cmd, &format!("{opt}={dir}")]), &Env::default(), 0);
                assert_eq!(out.code, 4, "{opt}= {cmd}");
            }
        }
        for env in [
            Env { faults: Some("profile:eio".into()), ..Env::default() },
            Env { faults: Some(String::new()), ..Env::default() },
            Env { reboot_file: Some(d.join("reboots")), ..Env::default() },
            Env { pkexec: true, faults: Some("x".into()), ..Env::default() },
        ] {
            for cmd in ["status", "apply", "mux-guard"] {
                let out = run(&args(&[cmd]), &env, 0);
                assert_eq!(out.code, 4, "{cmd} {env:?}");
            }
        }
        assert_eq!(listing(&d), before, "nothing was read into existence or written");
        assert!(!d.join("reboots").exists());
        // the same options are fine for an ordinary user
        let out = run(&args(&["status", "--sysfs-root", &dir]), &Env::default(), 1000);
        assert_eq!(out.code, 0, "{}", out.json);
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn root_without_test_options_is_the_real_mode_and_only_status_is_run_here() {
        // Real mode reads the real /sys (read-only); a write command is NEVER run as root in a test.
        let out = run(&args(&["status"]), &Env::default(), 0);
        assert_eq!(out.code, 0);
        assert!(out.json.starts_with("{\"ok\":true,\"proto\":1,\"status\":{"));
    }

    #[test]
    fn a_plain_user_cannot_write_and_a_test_user_needs_both_roots() {
        // Argument-less forms only: this runs in-process against the REAL roots when no option is given, so
        // even a helper that lost the refusal could not write anything from here.
        let d = tmpdir("plain");
        let dir = d.display().to_string();
        let before = listing(&d);
        let cases: [Vec<&str>; 5] =
            [vec!["apply"], vec!["set-boot"], vec!["mux-cancel"], vec!["mux-confirm"], vec!["mux-prompt-shown"]];
        for words in cases {
            let out = run(&args(&words), &Env::default(), 1000);
            assert_eq!(out.code, 2, "{words:?}: {}", out.json);
            assert!(out.json.contains("pkexec"), "{}", out.json);
            let out = run(&args(&[&["--sysfs-root", &dir], &words[..]].concat()), &Env::default(), 1000);
            assert_eq!(out.code, 2, "{words:?} with only --sysfs-root");
            assert!(out.json.contains("--state-dir"));
        }
        // the systemd-only ones, plain: refused as such (argument-less, so nothing could be written from here)
        for cmd in ["record-caps", "boot-apply", "mux-apply", "mux-guard"] {
            let out = run(&args(&[cmd]), &Env::default(), 1000);
            assert_eq!(out.code, 2, "{cmd}: {}", out.json);
            assert!(out.json.contains("for systemd"), "{}", out.json);
        }
        assert_eq!(listing(&d), before);
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn systemd_only_commands_are_refused_under_pkexec_before_the_world_is_looked_at() {
        let env = Env { pkexec: true, ..Env::default() };
        for cmd in ["record-caps", "boot-apply", "mux-apply", "mux-guard"] {
            // even as root, even with nothing else wrong
            let out = run(&args(&[cmd]), &env, 0);
            assert_eq!(out.code, 2, "{cmd}: {}", out.json);
            assert!(out.json.contains("systemd only"));
        }
        let out = run(&args(&["status"]), &env, 0);
        assert_eq!(out.code, 0, "status is fine under pkexec");
    }

    #[test]
    fn syntax_errors_are_exit_2_with_a_why_and_never_a_panic() {
        for bad in [
            vec![],
            vec!["--sysfs-root"],
            vec!["--sysfs-root="],
            vec!["--sysfs-root", "/a", "--sysfs-root", "/b", "status"],
            vec!["--unknown", "status"],
            vec!["--", "status"],
            vec!["status", "--proc-root"],
            vec!["nope"],
            vec![""],
            vec!["status=1"],
        ] {
            let out = run(&args(&bad), &Env::default(), 1000);
            assert_eq!(out.code, 2, "{bad:?}: {}", out.json);
            assert!(out.json.contains("\"why\""), "{bad:?}");
            assert!(out.json.starts_with("{\"ok\":false,\"proto\":1"));
        }
    }

    #[test]
    fn every_output_is_one_line_of_valid_json() {
        let d = tmpdir("oneline");
        let dir = d.display().to_string();
        for words in [vec!["status"], vec!["apply"], vec!["apply", "profile=\"\n\\"]] {
            let mut a = vec!["--sysfs-root", &dir];
            a.extend(words.iter().copied());
            let out = run(&args(&a), &Env::default(), 1000);
            assert!(!out.json.contains('\n'), "{}", out.json);
            assert!(crate::json::parse(&out.json).is_ok(), "{}", out.json);
        }
        let _ = fs::remove_dir_all(&d);
    }
}
