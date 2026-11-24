//! Structural audits of the source itself: the properties the safety argument leans on, kept
//! true by tests instead of by care. Only compiled for `cargo test`.

use std::collections::BTreeMap;

fn sources() -> BTreeMap<&'static str, &'static str> {
    BTreeMap::from([
        ("boost.rs", include_str!("boost.rs")),
        ("cli.rs", include_str!("cli.rs")),
        ("commands.rs", include_str!("commands.rs")),
        ("ctx.rs", include_str!("ctx.rs")),
        ("fsx.rs", include_str!("fsx.rs")),
        ("gpu.rs", include_str!("gpu.rs")),
        ("json.rs", include_str!("json.rs")),
        ("knobs.rs", include_str!("knobs.rs")),
        ("machine.rs", include_str!("machine.rs")),
        ("main.rs", include_str!("main.rs")),
        ("mux.rs", include_str!("mux.rs")),
        ("plan.rs", include_str!("plan.rs")),
        ("platform.rs", include_str!("platform.rs")),
        ("report.rs", include_str!("report.rs")),
        ("roots.rs", include_str!("roots.rs")),
        ("state.rs", include_str!("state.rs")),
        ("sys.rs", include_str!("sys.rs")),
        ("whitelist.rs", include_str!("whitelist.rs")),
        ("wifi.rs", include_str!("wifi.rs")),
        ("writer.rs", include_str!("writer.rs")),
    ])
}

/// The production half of a file (everything before its test module).
fn production(text: &str) -> &str {
    text.split("#[cfg(test)]\nmod tests").next().unwrap_or(text)
}

fn offenders(needles: &[&str], allowed: &[&str]) -> Vec<String> {
    let mut found = Vec::new();
    for (name, text) in sources() {
        if allowed.contains(&name) {
            continue;
        }
        for needle in needles {
            if production(text).contains(needle) {
                found.push(format!("{name} uses {needle}"));
            }
        }
    }
    found
}

#[test]
fn only_platform_rs_starts_programs() {
    let needles = [concat!("Command", "::new"), "process::Command", "std::process::Stdio", "exec(", "Cmd::"];
    assert_eq!(offenders(&needles, &["platform.rs"]), Vec::<String>::new());
    // and platform.rs never takes a program name from anywhere but its own constants
    let p = production(include_str!("platform.rs"));
    assert!(p.contains("const SYSTEMCTL: &str = \"/usr/bin/systemctl\""));
    assert!(!p.contains("env::var"), "no environment lookup decides what is run");
}

#[test]
fn only_the_door_the_state_files_and_the_test_reboot_log_open_files_for_writing() {
    let needles = [
        "OpenOptions",
        "File::create",
        "fs::write(",
        "fs::rename(",
        "fs::remove_file(",
        "fs::remove_dir",
        "fs::create_dir",
        "set_permissions",
        "DirBuilder",
        "fs::copy(",
        "hard_link",
        "symlink(",
    ];
    // writer.rs is the sysfs door; state.rs the helper's own files; platform.rs the test reboot log
    assert_eq!(offenders(&needles, &["writer.rs", "state.rs", "platform.rs"]), Vec::<String>::new());
    // platform.rs opens exactly one file for writing, and only to append a line to SILICON_TEST_REBOOT
    let p = production(include_str!("platform.rs"));
    assert_eq!(p.matches("OpenOptions::new()").count(), 1);
    assert!(p.contains(".append(true)"));
    // writer.rs opens sysfs for writing in exactly one place
    let w = production(include_str!("writer.rs"));
    assert_eq!(w.matches("OpenOptions::new()").count(), 1);
    assert!(w.contains(".write(true).truncate(true).custom_flags(O_NOFOLLOW)"));
    assert!(!w.contains(".create("), "a sysfs write never creates");
    // state.rs: `create(true)` only for the lock file; the temp files are `create_new`
    let s = production(include_str!("state.rs"));
    assert_eq!(s.matches(".create(true)").count(), 1, "the lock file");
    assert_eq!(s.matches(".create_new(true)").count(), 1, "the temp file of an atomic write");
}

#[test]
fn every_sysfs_write_names_a_whitelist_class() {
    // The only callers of Writer::write are the plan executor and the mux firmware write: both pass a Class.
    let mut callers = Vec::new();
    for (name, text) in sources() {
        let n = production(text).matches(".write(\"").count() + production(text).matches("w.write(").count();
        if n > 0 && name != "writer.rs" {
            callers.push(name);
        }
    }
    assert!(callers.iter().all(|c| ["plan.rs", "mux.rs", "boost.rs"].contains(c)), "{callers:?}");
}

#[test]
fn the_boost_floors_are_written_by_the_boost_alone_and_the_boost_writes_nothing_else() {
    // the two classes are named by the whitelist, the door (the i915 check) and the boost, nowhere else: no knob of
    // `apply` / `set-boot` can reach min_perf_pct or a GPU frequency
    assert_eq!(
        offenders(&["BoostCpuFloor", "BoostGpuFloor"], &["whitelist.rs", "writer.rs", "boost.rs"]),
        Vec::<String>::new()
    );
    let b = production(include_str!("boost.rs"));
    // its two write calls (raise, put back) pass the class of the floor they write, never a literal of another class
    assert_eq!(b.matches("w.write(").count(), 2);
    assert!(b.contains("w.write(r.which.name(), r.which.class(), &r.path, &r.before)"));
    assert_eq!(b.matches(".w.write(").count(), 1);
    assert!(b.contains("self.w.write(r.which.name(), r.which.class(), &r.path, &r.ours)"));
    assert!(b.contains("Which::Cpu => Class::BoostCpuFloor,\n            Which::Gpu => Class::BoostGpuFloor,"));
    assert_eq!(b.matches("Class::").count(), 2, "boost.rs names only its two classes");
    // the protocol has one verb
    assert!(b.contains("line.strip_prefix(\"boost \")"));
}

#[test]
fn production_code_has_no_unwrap_expect_panic_or_indexing_escape_hatches() {
    for (name, text) in sources() {
        let p = production(text);
        for needle in
            [".unwrap()", ".expect(", "panic!(", "unreachable!(", "todo!(", "unimplemented!(", "#[allow(", "unsafe {"]
        {
            let allowed_unsafe = needle == "unsafe {" && name == "sys.rs";
            assert!(allowed_unsafe || !p.contains(needle), "{name} contains {needle}");
        }
    }
    // the unsafe blocks: geteuid, and the boost server's getsockopt(SO_PEERCRED), poll and signal -- each documented
    let sys = production(include_str!("sys.rs"));
    assert_eq!(sys.matches("unsafe {").count(), 4, "geteuid, getsockopt, poll, signal");
    assert_eq!(sys.matches("// SAFETY: ").count(), 4);
    for s in ["SAFETY: geteuid(2)", "SAFETY: getsockopt(2)", "SAFETY: poll(2)", "SAFETY: signal(2)"] {
        assert!(sys.contains(s), "{s}");
    }
    // the signal handler does nothing but an atomic store
    assert!(sys.contains("extern \"C\" fn on_term(_sig: i32) {\n    TERM.store(true, Ordering::SeqCst);"));
}

#[test]
fn the_stack_teardown_is_asked_for_in_one_place_and_only_for_the_dgpu_direction() {
    let m = production(include_str!("mux.rs"));
    // the definition and one call
    assert_eq!(m.matches("bring_stack_down(").count(), 2);
    // the call sits behind the rule, and the rule is the dGPU direction alone: the way back to hybrid -- the
    // user's way out, also what `mux-guard`'s revert writes -- never waits for the NVIDIA stack
    let at = m.find("bring_stack_down(ctx, &m)").unwrap_or(0);
    let clause = m.get(..at).unwrap_or("").rsplit("else if ").next().unwrap_or("");
    assert!(clause.trim_start().starts_with("needs_stack_down(rec.want) {"), "{clause}");
    assert!(m.contains("fn needs_stack_down(want: Wiring) -> bool {\n    want == Wiring::Dgpu\n}"));
    // and nothing outside mux.rs asks the platform to stop a unit or unload a module
    assert_eq!(offenders(&["stop_unit(", "unload_module("], &["platform.rs", "mux.rs"]), Vec::<String>::new());
}

#[test]
fn the_nvidia_drivers_proc_entry_is_read_by_what_reports_a_status_and_nothing_that_writes() {
    // the one read that goes to the NVIDIA driver is in find_dgpu (gpu.rs), behind `nvidia_node`
    let gpu = production(include_str!("gpu.rs"));
    assert_eq!(gpu.matches("proc_path(&format!(\"driver/nvidia").count(), 1);
    assert_eq!(
        offenders(&["proc_path(&format!(\"driver/nvidia", "driver/nvidia/gpus/{pci}"], &["gpu.rs"]),
        Vec::<String>::new()
    );
    // only Machine::build asks find_dgpu for it, and only `discover` says yes; `discover_for_write` says no
    assert_eq!(offenders(&["find_dgpu("], &["gpu.rs", "machine.rs"]), Vec::<String>::new());
    let m = production(include_str!("machine.rs"));
    assert_eq!(m.matches("gpu::find_dgpu(roots, nvidia_node)").count(), 1);
    assert!(m.contains("pub fn discover(roots: &Roots) -> Machine {\n        Machine::build(roots, true)\n    }"));
    assert!(m.contains(
        "pub fn discover_for_write(roots: &Roots) -> Machine {\n        Machine::build(roots, false)\n    }"
    ));
    // the full discovery is asked for in cli.rs and nowhere else: the status command, and the answer to a command the
    // shell runs (the answers of systemd's own use the lean one)
    assert_eq!(offenders(&["Machine::discover("], &["cli.rs", "machine.rs"]), Vec::<String>::new());
    assert_eq!(production(include_str!("cli.rs")).matches("Machine::discover(").count(), 2);
}

#[test]
fn the_dgpu_value_is_written_for_a_queued_request_and_nowhere_else() {
    // `write_firmware` is the only way to the MUX attribute. Its callers: `apply` (the record's own want), `revert`
    // (hybrid, spelled out) and the guard's withdrawal, whose value comes from `withdraw_toward` -- hybrid only.
    let m = production(include_str!("mux.rs"));
    assert_eq!(m.matches("write_firmware(").count(), 4, "the definition and three callers");
    assert!(m.contains("write_firmware(ctx, &m, rec.want)"));
    assert!(m.contains("write_firmware(ctx, &m, Wiring::Hybrid)"));
    assert!(m.contains("write_firmware(ctx, &m, back)"));
    assert!(m.contains(
        "fn withdraw_toward(found: Wiring) -> Option<Wiring> {\n    (found == Wiring::Hybrid).then_some(found)\n}"
    ));
}

#[test]
fn the_simulated_platform_never_reaches_a_real_command() {
    let p = production(include_str!("platform.rs"));
    let sim = p.split("impl Platform for Simulated").nth(1).unwrap_or("");
    assert!(!sim.is_empty());
    for needle in ["Cmd", "Command", "Stdio", "systemctl"] {
        assert!(!sim.contains(needle), "the simulated platform mentions {needle}");
    }
}
