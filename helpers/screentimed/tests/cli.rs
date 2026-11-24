//! The binary's client commands, without a daemon.

use std::process::Command;
use std::time::Instant;

fn bin() -> Command {
    let mut c = Command::new(env!("CARGO_BIN_EXE_screentimed"));
    c.env("XDG_RUNTIME_DIR", "/tmp/st-cli-none");
    c
}

#[test]
fn ctl_with_no_daemon_exits_zero_fast() {
    let t = Instant::now();
    let st = bin().args(["ctl", "idle", "120"]).status().unwrap();
    assert!(st.success());
    assert!(t.elapsed().as_millis() < 150, "{:?}", t.elapsed());
}

#[test]
fn query_with_no_daemon_exits_two() {
    assert_eq!(bin().args(["query", "state"]).status().unwrap().code(), Some(2));
}

#[test]
fn lock_run_still_runs_the_command_and_a_missing_one_is_127() {
    assert_eq!(bin().args(["lock-run", "true"]).status().unwrap().code(), Some(0));
    assert_eq!(bin().args(["lock-run", "sh", "-c", "exit 3"]).status().unwrap().code(), Some(3));
    assert_eq!(bin().args(["lock-run", "/nonexistent/hyprlock"]).status().unwrap().code(), Some(127));
}

#[test]
fn unknown_subcommand_is_a_usage_error() {
    assert_eq!(bin().arg("frobnicate").status().unwrap().code(), Some(2));
}
