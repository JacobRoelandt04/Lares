//! install.sh, as far as it can be tested without root: the dry run (which prints every step
//! it would take and changes nothing), the refusals, and that --uninstall removes only what
//! install puts there. A real run is never made here; as a precaution the one test that
//! invokes the script without --dry-run only does so as a non-root user, where it refuses
//! before it does anything.

use std::collections::BTreeSet;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

fn real_script_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).to_path_buf()
}

/// A copy of install.sh, units and polkit files in a temp dir, with `target/release/silicon-helper`
/// being a copy of the test binary (an ELF executable), so the script finds what it needs.
fn staged(tag: &str, with_binary: bool) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("silicon-install-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("units")).unwrap();
    fs::create_dir_all(dir.join("polkit")).unwrap();
    let src = real_script_dir();
    fs::copy(src.join("install.sh"), dir.join("install.sh")).unwrap();
    fs::set_permissions(dir.join("install.sh"), fs::Permissions::from_mode(0o755)).unwrap();
    for sub in ["units", "polkit"] {
        for e in fs::read_dir(src.join(sub)).unwrap() {
            let e = e.unwrap();
            fs::copy(e.path(), dir.join(sub).join(e.file_name())).unwrap();
        }
    }
    if with_binary {
        fs::create_dir_all(dir.join("target/release")).unwrap();
        fs::copy(env!("CARGO_BIN_EXE_silicon-helper"), dir.join("target/release/silicon-helper")).unwrap();
    }
    dir
}

struct Ran {
    code: i32,
    out: String,
    err: String,
}

fn run(dir: &Path, args: &[&str], env: &[(&str, &str)]) -> Ran {
    let out = Command::new("bash")
        .arg(dir.join("install.sh"))
        .args(args)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .envs(env.iter().copied())
        .output()
        .unwrap();
    Ran {
        code: out.status.code().unwrap_or(-1),
        out: String::from_utf8_lossy(&out.stdout).into_owned(),
        err: String::from_utf8_lossy(&out.stderr).into_owned(),
    }
}

fn user() -> String {
    String::from_utf8(Command::new("id").arg("-un").output().unwrap().stdout).unwrap().trim().to_string()
}

fn is_root() -> bool {
    String::from_utf8(Command::new("id").arg("-u").output().unwrap().stdout).unwrap().trim() == "0"
}

/// The (command, arguments) of every "would run" line.
fn steps(out: &str) -> Vec<Vec<String>> {
    out.lines()
        .filter_map(|l| l.strip_prefix("would run (failure ignored): ").or_else(|| l.strip_prefix("would run: ")))
        .map(|rest| rest.split(' ').map(str::to_string).collect())
        .collect()
}

const INSTALLED: [&str; 6] = [
    "/usr/local/libexec/silicon-helper",
    "/usr/share/polkit-1/actions/org.lares.silicon.helper.policy",
    "/etc/polkit-1/rules.d/50-lares-silicon-helper.rules",
    "/etc/systemd/system/silicon-boot.service",
    "/etc/systemd/system/silicon-mux.service",
    "/etc/systemd/system/silicon-mux-guard.service",
];

fn exists_now() -> Vec<bool> {
    INSTALLED.iter().chain(["/var/lib/silicon", "/usr/local/libexec"].iter()).map(|p| Path::new(p).exists()).collect()
}

#[test]
fn the_dry_run_names_every_step_and_changes_nothing() {
    assert!(!is_root(), "run the tests as an ordinary user");
    let dir = staged("dry", true);
    let before = exists_now();
    let r = run(&dir, &["--dry-run"], &[]);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    assert_eq!(exists_now(), before, "a dry run changes nothing");
    for path in INSTALLED {
        assert!(r.out.contains(path), "the dry run must mention {path}\n{}", r.out);
    }
    let me = user();
    assert!(r.out.contains(&format!("install for user {me} (dry run: 1)")));
    // the rule is rendered for this user, for the one action, with the active+local conditions
    assert!(r.out.contains(&format!("subject.user == \"{me}\"")), "{}", r.out);
    assert!(r.out.contains("action.id == \"org.lares.silicon.helper\""));
    assert!(r.out.contains("subject.active && subject.local"));
    assert!(!r.out.contains("@USER@"));
    // every command it would run is one of install / systemctl / the helper, and only install and
    // the units write anywhere; owners and modes are explicit
    for s in steps(&r.out) {
        let cmd = s.first().map(String::as_str).unwrap_or("");
        assert!(
            ["install", "systemctl", "/usr/local/libexec/silicon-helper"].contains(&cmd),
            "unexpected command {s:?}"
        );
        if cmd == "install" && !s.contains(&"-d".to_string()) {
            assert!(s.windows(2).any(|w| w == ["-o", "root"]) && s.windows(2).any(|w| w == ["-g", "root"]), "{s:?}");
            let mode = s.iter().position(|a| a == "-m").and_then(|i| s.get(i + 1)).cloned().unwrap_or_default();
            let dest = s.last().cloned().unwrap_or_default();
            let want = if dest == INSTALLED[0] { "0755" } else { "0644" };
            assert_eq!(mode, want, "{s:?}");
            assert!(INSTALLED.contains(&dest.as_str()), "installs only to the documented paths: {dest}");
        }
    }
    assert!(r.out.contains("install -m 0755 -o root -g root -- "), "{}", r.out);
    assert!(r.out.contains("systemctl enable silicon-boot.service silicon-mux-guard.service"));
    assert!(r.out.contains("systemctl enable --now silicon-mux.service"));
    assert!(r.out.contains("silicon-helper record-caps"));
    assert!(
        !r.out.contains("boot-apply"),
        "the installer never runs boot-apply (it would re-apply the stored boot set)"
    );
    assert!(r.out.contains("asusd, asusctl and asus-boot-quiet.service are untouched"));
    assert!(
        !steps(&r.out).iter().flatten().any(|a| a.contains("asus")),
        "no step touches asusd, asusctl or asus-boot-quiet"
    );
    // it never runs cargo and never removes anything on install
    assert!(!steps(&r.out).iter().any(|s| matches!(s.first().map(String::as_str), Some("rm" | "cargo" | "rustc"))));
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn the_uninstall_dry_run_removes_exactly_what_install_installs() {
    let dir = staged("undo", true);
    let r = run(&dir, &["--uninstall", "--dry-run"], &[]);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    let removed: BTreeSet<String> = steps(&r.out)
        .into_iter()
        .filter(|s| s.first().map(String::as_str) == Some("rm"))
        .flat_map(|s| s.into_iter().skip(1))
        .filter(|a| a.starts_with('/'))
        .collect();
    for path in INSTALLED {
        assert!(removed.contains(path), "uninstall must remove {path}: {removed:?}");
    }
    let allowed: BTreeSet<String> = INSTALLED
        .iter()
        .map(|s| s.to_string())
        .chain(
            [
                "firmware_caps.json",
                "boot.json",
                "mux.json",
                "boot_applied.json",
                ".lock",
                ".firmware_caps.json.tmp",
                ".boot.json.tmp",
                ".mux.json.tmp",
                ".boot_applied.json.tmp",
            ]
            .iter()
            .map(|f| format!("/var/lib/silicon/{f}")),
        )
        .collect();
    assert_eq!(removed, allowed, "and nothing else");
    for s in steps(&r.out) {
        let cmd = s.first().map(String::as_str).unwrap_or("");
        assert!(["systemctl", "rm", "rmdir"].contains(&cmd), "{s:?}");
        if cmd == "rm" {
            assert!(s.contains(&"-f".to_string()) && s.contains(&"--".to_string()), "{s:?}");
            assert!(!s.iter().any(|a| a == "-r" || a == "-rf" || a == "-R"), "never recursive: {s:?}");
        }
        if cmd == "rmdir" {
            assert!(s.last().is_some_and(|d| d == "/var/lib/silicon" || d == "/usr/local/libexec"), "{s:?}");
        }
    }
    assert!(r.out.contains("left alone: asusd, asusctl, asus-boot-quiet.service"));
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn it_refuses_a_missing_build_and_an_unknown_argument() {
    let dir = staged("refuse", false);
    // no release build: the dry run says what the real one would do
    let r = run(&dir, &["--dry-run"], &[]);
    assert_eq!(r.code, 1);
    assert!(r.err.contains("cargo build --release"), "{}", r.err);
    // an argument it does not know
    let r = run(&dir, &["--frobnicate"], &[]);
    assert_eq!(r.code, 2);
    let _ = fs::remove_dir_all(&dir);
}

/// A copy of the script that can do NOTHING real: its `export PATH=` line is removed so that the
/// directory of stubs we put first in PATH shadows install, systemctl, rm, rmdir and runuser. The
/// stubs only append "<name> <args>" to a log. (The one other edit, for the positive run, is
/// stated at its use.) The shipped script is never run in real mode by these tests.
struct Stubbed {
    dir: PathBuf,
    log: PathBuf,
}

fn stubbed(tag: &str) -> Stubbed {
    let dir = staged(tag, true);
    let script = fs::read_to_string(dir.join("install.sh")).unwrap();
    assert!(script.contains("export PATH=/usr/sbin:/usr/bin:/sbin:/bin\n"));
    assert!(script.contains("BIN_DST=/usr/local/libexec/silicon-helper\n"));
    // PATH: so the stubs shadow the real tools. BIN_DST: so the helper the script runs after installing is a stub
    // too (it logs its arguments), not whatever is installed on this machine at /usr/local/libexec.
    let bin = dir.join("bin/silicon-helper");
    fs::write(
        dir.join("install.sh"),
        script
            .replace("export PATH=/usr/sbin:/usr/bin:/sbin:/bin\n", "")
            .replace("BIN_DST=/usr/local/libexec/silicon-helper\n", &format!("BIN_DST={}\n", bin.display())),
    )
    .unwrap();
    fs::create_dir_all(dir.join("stubs")).unwrap();
    fs::create_dir_all(dir.join("bin")).unwrap();
    let log = dir.join("calls.log");
    for name in ["install", "systemctl", "rm", "rmdir", "runuser"] {
        let stub = dir.join("stubs").join(name);
        fs::write(&stub, format!("#!/bin/bash\nprintf '%s' '{name}' >> '{}'\nprintf ' %s' \"$@\" >> '{}'\nprintf '\\n' >> '{}'\n[ '{name}' = runuser ] && echo '{{\"ok\":true}}'\nexit 0\n", log.display(), log.display(), log.display())).unwrap();
        fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();
    }
    fs::write(&bin, format!("#!/bin/bash\nprintf '%s' \"$0\" >> '{}'\nprintf ' %s' \"$@\" >> '{}'\nprintf '\\n' >> '{}'\necho '{{\"ok\":true}}'\nexit 0\n", log.display(), log.display(), log.display())).unwrap();
    fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();
    Stubbed { dir, log }
}

fn run_stubbed(s: &Stubbed, args: &[&str], env: &[(&str, &str)]) -> Ran {
    let path = format!("{}:/usr/bin:/bin", s.dir.join("stubs").display());
    let tmp = s.dir.join("tmp");
    fs::create_dir_all(&tmp).unwrap();
    let tmp = tmp.display().to_string();
    // mktemp makes the rule's temp file in here, so it goes away with the staged directory (the stubbed rm removes nothing)
    let mut all: Vec<(&str, &str)> = vec![("PATH", path.as_str()), ("TMPDIR", tmp.as_str())];
    all.extend_from_slice(env);
    let out = Command::new("bash").arg(s.dir.join("install.sh")).args(args).env_clear().envs(all).output().unwrap();
    Ran {
        code: out.status.code().unwrap_or(-1),
        out: String::from_utf8_lossy(&out.stdout).into_owned(),
        err: String::from_utf8_lossy(&out.stderr).into_owned(),
    }
}

fn logged(s: &Stubbed) -> Vec<String> {
    fs::read_to_string(&s.log).map(|t| t.lines().map(str::to_string).collect()).unwrap_or_default()
}

#[test]
fn a_real_run_without_root_is_refused_before_it_calls_anything() {
    for args in [vec![], vec!["--uninstall"]] {
        let s = stubbed("noroot");
        if is_root() {
            return; // as root the guard would let it go on (into stubs only); the guard is for the others
        }
        let r = run_stubbed(&s, &args, &[]);
        assert_eq!(r.code, 1, "{}{}", r.out, r.err);
        assert!(r.err.contains("run it with sudo"), "{}", r.err);
        assert!(logged(&s).is_empty(), "nothing was called: {:?}", logged(&s));
        // sudo from an account, but SUDO_USER absent or root: still refused (needs EUID 0 first, so this is the order)
        let _ = fs::remove_dir_all(&s.dir);
    }
}

/// Every command a dry run says it would run, as one string each, in order: the `would run` forms, the
/// helper call that is "reported, not fatal", and the status check as the user.
fn planned(out: &str, user: &str) -> Vec<String> {
    out.lines()
        .filter_map(|l| {
            if let Some(rest) = l
                .strip_prefix("would run (failure ignored): ")
                .or_else(|| l.strip_prefix("would run (failure reported, not fatal): "))
                .or_else(|| l.strip_prefix("would run: "))
            {
                return Some(rest.to_string());
            }
            let rest = l.strip_prefix(&format!("would run, as {user}: "))?;
            let cmd = rest.split("   (").next()?;
            Some(format!("runuser -u {user} -- {cmd}"))
        })
        .collect()
}

#[test]
fn the_real_sequence_is_the_one_the_dry_run_printed() {
    // The one edit besides PATH and BIN_DST: the EUID check is skipped, so the real code path runs -- into stubs.
    let s = stubbed("sequence");
    let script = fs::read_to_string(s.dir.join("install.sh")).unwrap();
    let needle = "[[ $EUID -eq 0 ]] || die \"run it with sudo:  sudo $0 $*\"";
    assert!(script.contains(needle));
    fs::write(s.dir.join("install.sh"), script.replace(needle, "true")).unwrap();
    let me = user();
    let dry = run(&s.dir, &["--dry-run"], &[]);
    assert_eq!(dry.code, 0, "{}{}", dry.out, dry.err);
    let here = s.dir.display().to_string();
    let norm = |c: &str| c.replace(&here, "<repo>");
    let planned: Vec<String> = planned(&dry.out, &me).iter().map(|c| norm(c)).collect();
    let r = run_stubbed(&s, &[], &[("SUDO_USER", me.as_str())]);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    let calls: Vec<String> = logged(&s).iter().map(|c| norm(c)).collect();
    // every planned step was actually made, in the same order -- the helper included; the rule goes through a
    // temp file (an install line that the dry run shows as a block) and rm cleans that file up
    let made: Vec<String> = calls.iter().filter(|c| !c.starts_with("rm ") && !c.ends_with(".rules")).cloned().collect();
    assert_eq!(made, planned, "dry run and real run disagree");
    assert!(
        calls.iter().any(|c| c.starts_with("install -m 0644 -o root -g root -- <repo>/tmp/tmp.")
            && c.ends_with("/etc/polkit-1/rules.d/50-lares-silicon-helper.rules")),
        "{calls:?}"
    );
    // the installer records the firmware's caps and nothing else: never `boot-apply`, which would re-apply the stored boot set
    assert!(calls.iter().any(|c| c == "<repo>/bin/silicon-helper record-caps"), "{calls:?}");
    assert!(calls.iter().any(|c| c == &format!("runuser -u {me} -- <repo>/bin/silicon-helper status")), "{calls:?}");
    for c in calls.iter().chain(planned.iter()) {
        assert!(!c.contains("boot-apply"), "a (re-)install must not run boot-apply: {c}");
    }
    let helper_calls: Vec<&String> = calls.iter().filter(|c| c.starts_with("<repo>/bin/silicon-helper")).collect();
    assert_eq!(
        helper_calls,
        ["<repo>/bin/silicon-helper record-caps"],
        "the one helper command the installer runs as root"
    );
    let _ = fs::remove_dir_all(&s.dir);
}

#[test]
fn the_user_the_rule_is_for_must_be_a_plain_existing_non_root_login() {
    let dir = staged("user", true);
    for bad in ["root", "a b", "x\"; rm -rf /; \"", "$(id)", "UPPER", "-rf", "", "a'b", "alice\nroot"] {
        let r = run(&dir, &["--dry-run"], &[("SUDO_USER", bad)]);
        if bad.is_empty() {
            continue; // empty SUDO_USER is the same as unset: falls back to the current user
        }
        assert_ne!(r.code, 0, "SUDO_USER={bad:?} must be refused: {}{}", r.out, r.err);
        assert!(!r.out.contains("polkit.addRule"), "no rule is rendered for {bad:?}");
    }
    let r = run(&dir, &["--dry-run"], &[("SUDO_USER", "no_such_user_xyz")]);
    assert_eq!(r.code, 1);
    assert!(r.err.contains("no such user"), "{}", r.err);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn a_binary_that_is_not_an_elf_is_refused() {
    let dir = staged("notelf", true);
    fs::write(dir.join("target/release/silicon-helper"), "#!/bin/sh\necho hi\n").unwrap();
    fs::set_permissions(dir.join("target/release/silicon-helper"), fs::Permissions::from_mode(0o755)).unwrap();
    let r = run(&dir, &["--dry-run"], &[]);
    assert_eq!(r.code, 1);
    assert!(r.err.contains("not an ELF"), "{}", r.err);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn uninstall_refuses_while_a_mux_change_is_in_flight() {
    // The shipped script has no test seam: this runs a COPY whose state directory is rewritten.
    let dir = staged("inflight", true);
    let state = dir.join("state");
    fs::create_dir_all(&state).unwrap();
    let script = fs::read_to_string(dir.join("install.sh")).unwrap();
    assert!(script.contains("STATE_DIR=/var/lib/silicon"));
    fs::write(
        dir.join("install.sh"),
        script.replace("STATE_DIR=/var/lib/silicon", &format!("STATE_DIR={}", state.display())),
    )
    .unwrap();
    for (s, refused) in [
        ("applied", true),
        ("awaiting-keep", true),
        ("queued", false),
        ("kept", false),
        ("reverted", false),
        ("failed", false),
        ("cancelled", false),
    ] {
        fs::write(state.join("mux.json"), format!("{{\"want\":\"dgpu\",\"from\":\"hybrid\",\"state\":\"{s}\",\"why\":\"\",\"requestedAtMs\":1,\"bootId\":\"b\",\"deadlineMs\":null}}\n")).unwrap();
        let r = run(&dir, &["--uninstall", "--dry-run"], &[]);
        if refused {
            assert_eq!(r.code, 1, "{s}: {}{}", r.out, r.err);
            assert!(r.err.contains("a GPU mode change is in flight"), "{s}: {}", r.err);
            assert!(steps(&r.out).is_empty(), "nothing is even planned");
        } else {
            assert_eq!(r.code, 0, "{s}: {}{}", r.out, r.err);
            assert!(!steps(&r.out).is_empty(), "{s}");
        }
    }
    fs::remove_file(state.join("mux.json")).unwrap();
    assert_eq!(run(&dir, &["--uninstall", "--dry-run"], &[]).code, 0);
    let _ = fs::remove_dir_all(&dir);
}

/// silicon-boot's values are the last word at boot only if the unit is ordered after every unit that
/// writes the same knobs. `powertop --auto-tune` (2.16+) writes every policy's EPP and min_perf_pct a
/// second into its run: left out of After=, it finished after boot-apply in 14 of 15 boots and the boot
/// profile's EPP was gone before the login (2026-11-15).
#[test]
fn the_boot_unit_is_ordered_after_every_other_writer_of_its_knobs() {
    let text = fs::read_to_string(real_script_dir().join("units/silicon-boot.service")).unwrap();
    let after: Vec<&str> = text.lines().filter_map(|l| l.strip_prefix("After=")).flat_map(str::split_whitespace).collect();
    for unit in ["asusd.service", "asus-boot-quiet.service", "powertop.service"] {
        assert!(after.contains(&unit), "silicon-boot.service must be ordered After={unit}: {after:?}");
    }
    assert!(!text.lines().any(|l| l.starts_with("Before=")), "nothing is ordered after this unit");
}
