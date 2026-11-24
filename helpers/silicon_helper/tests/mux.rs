//! The GPU MUX, end to end in test mode: request (a record, never the firmware), apply (the
//! firmware, at shutdown: a switch TO dGPU-only with the NVIDIA stack down, the way BACK to hybrid
//! whatever the stack does), guard (the next boot: kept, reverted with exactly one reboot, failed,
//! cancelled) -- with `SILICON_TEST_REBOOT` standing in for `systemctl reboot`.

mod common;
use common::*;
use std::fs;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const LEGACY: &str = "devices/platform/asus-nb-wmi/gpu_mux_mode";
const ARMOURY: &str = "devices/virtual/firmware-attributes/asus-armoury/attributes/gpu_mux_mode/current_value";
const PENDING: &str = "devices/virtual/firmware-attributes/asus-armoury/attributes/pending_reboot";

fn now_ms() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as f64
}

fn record(sb: &Sandbox) -> V {
    sb.state_json("mux.json")
}

fn state_of(sb: &Sandbox) -> String {
    record(sb).at("state").str().to_string()
}

fn reboots(sb: &Sandbox) -> usize {
    fs::read_to_string(sb.reboot_file()).map(|t| t.lines().count()).unwrap_or(0)
}

fn reboot_env(sb: &Sandbox) -> String {
    sb.reboot_file().display().to_string()
}

/// Request dgpu and apply it at "shutdown": the firmware now holds 0, the record says applied.
fn applied_dgpu(sb: &Sandbox) {
    sb.run(&["mux-request", "dgpu"]).expect(0);
    let r = sb.run(&["mux-apply"]);
    r.expect(0);
    assert_eq!(state_of(sb), "applied");
}

/// The machine rebooted and the panel is wired as it now is.
fn reboot_into(sb: &Sandbox, wiring: &str) {
    sb.new_boot(BOOT_B);
    sb.rewire(wiring);
}

fn wait_for_state(sb: &Sandbox, want: &str) {
    let start = Instant::now();
    loop {
        if sb.has_state("mux.json") && state_of(sb) == want {
            return;
        }
        assert!(
            start.elapsed() < Duration::from_secs(8),
            "the record never reached '{want}': {}",
            sb.state_file("mux.json")
        );
        std::thread::sleep(Duration::from_millis(30));
    }
}

/// Replace the value of `"key":` in mux.json, atomically (a guard polls the file; it must never see half of it).
/// The values here are numbers, `null` or strings without a comma.
fn set_field(sb: &Sandbox, key: &str, value: &str) {
    let text = sb.state_file("mux.json");
    let needle = format!("\"{key}\":");
    let at = text.find(&needle).unwrap_or_else(|| panic!("no {key} in {text}")) + needle.len();
    let end = text[at..].find([',', '}']).unwrap() + at;
    let tmp = sb.state().join(".mux.json.test");
    fs::write(&tmp, format!("{}{}{}", &text[..at], value, &text[end..])).unwrap();
    fs::rename(&tmp, sb.state().join("mux.json")).unwrap();
}

/// The wall-clock deadline (what the shell counts down to) -- never what the guard decides on.
fn set_deadline(sb: &Sandbox, ms: u64) {
    set_field(sb, "deadlineMs", &ms.to_string());
}

/// The guard's deadline reached: 1 ms since boot, and the fake uptime is far past it.
fn expire(sb: &Sandbox) {
    set_field(sb, "deadlineUptimeMs", "1");
}

/// The guard of the second boot (the fake clocks: uptime 100.5 s) with the reboot log, running in the background.
fn spawn_guard(sb: &Sandbox) -> std::process::Child {
    let log = reboot_env(sb);
    sb.spawn(&["mux-guard"], &[("SILICON_TEST_REBOOT", log.as_str())])
}

// ---------------------------------------------------------------- request

#[test]
fn a_request_writes_only_a_record_and_never_the_firmware() {
    let sb = Sandbox::new("n6506mv_618lts");
    let before = sb.snapshot();
    let r = sb.run(&["mux-request", "dgpu"]);
    r.expect(0);
    assert!(r.ok());
    assert_eq!(r.results().len(), 1);
    let e = r.result("mux");
    assert_eq!(e.at("want").str(), "dgpu");
    assert_eq!(e.at("got").str(), "queued");
    assert!(e.at("ok").bool());
    let rec = record(&sb);
    assert_eq!(
        rec.keys(),
        ["want", "from", "state", "why", "requestedAtMs", "bootId", "deadlineMs", "deadlineBootId", "deadlineUptimeMs"]
    );
    assert_eq!(rec.at("want").str(), "dgpu");
    assert_eq!(rec.at("from").str(), "hybrid");
    assert_eq!(rec.at("state").str(), "queued");
    assert_eq!(rec.at("why").str(), "");
    assert!((rec.at("requestedAtMs").num() - now_ms()).abs() < 60_000.0);
    assert_eq!(rec.at("bootId").str(), BOOT_A);
    assert!(
        rec.at("deadlineMs").is_null() && rec.at("deadlineBootId").is_null() && rec.at("deadlineUptimeMs").is_null()
    );
    assert_eq!(r.status().at("mux.record"), &rec, "status.mux.record is the file");
    assert_eq!(
        before.diff(&sb.snapshot()),
        vec!["state/mux.json".to_string()],
        "NOTHING is written to the firmware at request time"
    );
    assert_eq!(sb.read(LEGACY), "1");
}

#[test]
fn a_request_for_hybrid_needs_no_prechecks() {
    let sb = Sandbox::new("n6506mv_618lts");
    sb.set(LEGACY, "0");
    sb.rewire("dgpu");
    fs::remove_file(sb.proc_("modules")).unwrap();
    let r = sb.run(&["mux-request", "hybrid"]);
    r.expect(0);
    assert_eq!(record(&sb).at("from").str(), "dgpu");
    assert_eq!(record(&sb).at("want").str(), "hybrid");
}

#[test]
fn the_prechecks_name_what_is_missing_and_refuse_dgpu() {
    let sb = Sandbox::new("n6506mv_618lts");
    fs::remove_file(sb.modules().join("7.2.7-arch1-1/updates/dkms/nvidia.ko.zst")).unwrap();
    let before = sb.snapshot();
    let r = sb.run(&["mux-request", "dgpu"]);
    r.expect(2);
    assert_eq!(r.code_of("mux"), "refused");
    assert_eq!(r.result("mux").at("why").str(), "no nvidia module is built for kernel 7.2.7-arch1-1");
    assert!(!r.status().at("prechecks.mux.ok").bool());
    assert_eq!(r.status().at("prechecks.mux.why").str(), "no nvidia module is built for kernel 7.2.7-arch1-1");
    assert_untouched(&before, &sb.snapshot());

    fs::write(sb.proc_("modules"), "snd_hda_intel 233472 3 - Live 0x0\n").unwrap();
    let r = sb.status();
    assert_eq!(
        r.status().at("prechecks.mux.why").str(),
        "the nvidia module is not loaded; no nvidia module is built for kernel 7.2.7-arch1-1"
    );
    fs::remove_dir_all(sb.modules().join("6.18.54-1-lts")).unwrap();
    fs::remove_dir_all(sb.modules().join("7.2.7-arch1-1")).unwrap();
    assert!(sb.status().status().at("prechecks.mux.why").str().contains("no installed kernel"));
    // a leftover directory with no kernel image in it is not an installed kernel
    fs::create_dir_all(sb.modules().join("5.10.0-removed/kernel")).unwrap();
    assert!(sb.status().status().at("prechecks.mux.why").str().contains("no installed kernel"));
}

#[test]
fn a_module_built_into_the_kernel_tree_or_extramodules_counts_too() {
    let sb = Sandbox::new("n6506mv_618lts");
    fs::remove_file(sb.modules().join("7.2.7-arch1-1/updates/dkms/nvidia.ko.zst")).unwrap();
    sb.put(&sb.modules().join("7.2.7-arch1-1/extramodules/nvidia.ko.xz"), "");
    assert!(sb.status().status().at("prechecks.mux.ok").bool());
}

// ---------------------------------------------------------------- cancel and equal requests

#[test]
fn a_queued_request_can_be_cancelled_or_withdrawn_by_asking_for_what_is_already_so() {
    let sb = Sandbox::new("n6506mv_618lts");
    sb.run(&["mux-request", "dgpu"]).expect(0);
    let r = sb.run(&["mux-cancel"]);
    r.expect(0);
    assert_eq!(r.result("mux").at("got").str(), "cancelled");
    assert_eq!(state_of(&sb), "cancelled");
    assert_eq!(sb.read(LEGACY), "1");

    sb.run(&["mux-request", "dgpu"]).expect(0);
    assert_eq!(state_of(&sb), "queued", "a finished record does not block the next request");
    // hybrid is what the panel is wired as AND what the firmware holds: it clears the queue
    let r = sb.run(&["mux-request", "hybrid"]);
    r.expect(0);
    assert_eq!(r.result("mux").at("got").str(), "cancelled");
    assert_eq!(state_of(&sb), "cancelled");
    assert!(record(&sb).at("why").str().contains("withdrawn"));

    // nothing queued, already as wanted: nothing to do, nothing written
    let before = sb.snapshot();
    let r = sb.run(&["mux-request", "hybrid"]);
    r.expect(0);
    assert_eq!(r.result("mux").at("got").str(), "unchanged");
    assert_untouched(&before, &sb.snapshot());

    // the same request twice queues once
    sb.run(&["mux-request", "dgpu"]).expect(0);
    let first = sb.state_file("mux.json");
    let r = sb.run(&["mux-request", "dgpu"]);
    r.expect(0);
    assert_eq!(sb.state_file("mux.json"), first);
}

#[test]
fn cancel_confirm_and_prompt_shown_refuse_when_they_have_nothing_to_act_on() {
    let sb = Sandbox::new("n6506mv_618lts");
    let before = sb.snapshot();
    for cmd in ["mux-cancel", "mux-confirm", "mux-prompt-shown"] {
        let r = sb.run(&[cmd]);
        r.expect(2);
        assert_eq!(r.code_of("mux"), "refused", "{cmd}");
    }
    assert_untouched(&before, &sb.snapshot());
    sb.run(&["mux-request", "dgpu"]).expect(0);
    sb.run(&["mux-confirm"]).expect(2);
    sb.run(&["mux-prompt-shown"]).expect(2);
    assert_eq!(state_of(&sb), "queued");
}

// ---------------------------------------------------------------- apply (shutdown)

#[test]
fn apply_writes_the_firmware_after_the_stack_is_down_and_records_it() {
    let sb = Sandbox::new("n6506mv_618lts");
    sb.run(&["mux-request", "dgpu"]).expect(0);
    let before = sb.snapshot();
    let r = sb.run(&["mux-apply"]);
    r.expect(0);
    assert_eq!(r.result("mux").at("got").str(), "applied");
    assert_eq!(sb.read(LEGACY), "0", "dgpu is gpu_mux_mode 0");
    assert_eq!(state_of(&sb), "applied");
    assert_eq!(before.diff(&sb.snapshot()), vec![format!("root/sys/{LEGACY}"), "state/mux.json".to_string()]);
    assert_eq!(r.status().at("values.muxStored").str(), "dgpu", "the firmware's stored setting");
    assert_eq!(r.status().at("mux.wiringNow").str(), "hybrid", "the wiring in effect changes at the reboot");
}

#[test]
fn apply_with_nothing_queued_does_nothing() {
    let sb = Sandbox::new("n6506mv_618lts");
    let before = sb.snapshot();
    let r = sb.run(&["mux-apply"]);
    r.expect(0);
    assert!(r.results().is_empty());
    assert_eq!(r.why(), "no GPU mode change is queued");
    assert_untouched(&before, &sb.snapshot());
    for state in ["cancelled", "failed", "kept", "applied"] {
        sb.run(&["mux-request", "dgpu"]).expect(0);
        let text = sb.state_file("mux.json").replace("\"state\":\"queued\"", &format!("\"state\":\"{state}\""));
        fs::write(sb.state().join("mux.json"), &text).unwrap();
        let before = sb.snapshot();
        sb.run(&["mux-apply"]).expect(0);
        assert_untouched(&before, &sb.snapshot());
    }
}

#[test]
fn apply_skips_the_write_when_something_still_holds_the_dgpu() {
    let sb = Sandbox::new("n6506mv_618lts");
    sb.run(&["mux-request", "dgpu"]).expect(0);
    sb.put(&sb.proc_("4242/comm"), "blender\n");
    fs::create_dir_all(sb.proc_("4242/fd")).unwrap();
    std::os::unix::fs::symlink(sb.dev("nvidia0"), sb.proc_("4242/fd/3")).unwrap();
    // an unrelated process with an unrelated file does not matter
    sb.put(&sb.proc_("77/comm"), "kitty\n");
    fs::create_dir_all(sb.proc_("77/fd")).unwrap();
    std::os::unix::fs::symlink("/tmp/whatever", sb.proc_("77/fd/0")).unwrap();
    let before = sb.snapshot();
    let start = Instant::now();
    let r = sb.run(&["mux-apply"]);
    r.expect(1);
    assert!(start.elapsed() >= Duration::from_millis(800), "it waited for the user to let go, bounded");
    assert_eq!(r.code_of("mux"), "io");
    assert!(r.result("mux").at("why").str().contains("still in use by blender (4242)"), "{}", r.stdout);
    assert!(!r.result("mux").at("why").str().contains("kitty"));
    assert_eq!(sb.read(LEGACY), "1", "the firmware was NOT written");
    assert_eq!(state_of(&sb), "failed");
    assert!(record(&sb).at("why").str().contains("blender"));
    assert_eq!(before.diff(&sb.snapshot()), vec!["state/mux.json".to_string()]);

    // the holder lets go: a new request works and the write goes through
    fs::remove_dir_all(sb.proc_("4242")).unwrap();
    sb.run(&["mux-request", "dgpu"]).expect(0);
    sb.run(&["mux-apply"]).expect(0);
    assert_eq!(sb.read(LEGACY), "0");
}

#[test]
fn apply_skips_the_write_when_the_nvidia_modules_cannot_be_unloaded() {
    let sb = Sandbox::new("n6506mv_618lts");
    // nvidia_drm has 3 references from outside the stack (an open file descriptor, say)
    fs::write(
        sb.proc_("modules"),
        "nvidia_uvm 2482176 0 - Live 0x0\nnvidia_drm 163840 3 - Live 0x0\nnvidia_modeset 1998848 1 nvidia_drm, Live 0x0\nnvidia 18722816 2 nvidia_uvm,nvidia_modeset, Live 0x0\n",
    )
    .unwrap();
    sb.run(&["mux-request", "dgpu"]).expect(0);
    let r = sb.run(&["mux-apply"]);
    r.expect(1);
    assert!(r.result("mux").at("why").str().contains("rmmod nvidia_drm: in use (3 references)"), "{}", r.stdout);
    assert_eq!(sb.read(LEGACY), "1");
    assert_eq!(state_of(&sb), "failed");
    // a module another driver depends on stops it too
    fs::write(sb.proc_("modules"), "nvidia 18722816 1 ib_core, Live 0x0\n").unwrap();
    sb.run(&["mux-request", "dgpu"]).expect(0);
    let r = sb.run(&["mux-apply"]);
    r.expect(1);
    assert!(r.result("mux").at("why").str().contains("nvidia is in use by ib_core"), "{}", r.stdout);
    assert_eq!(sb.read(LEGACY), "1");
}

#[test]
fn apply_with_the_stack_already_down_is_fine() {
    let sb = Sandbox::new("n6506mv_618lts");
    fs::write(sb.proc_("modules"), "snd_hda_intel 233472 3 - Live 0x0\n").unwrap();
    sb.run(&["mux-request", "hybrid"]).expect(0); // wiring is hybrid: a no-op request
    sb.set(LEGACY, "0");
    sb.run(&["mux-request", "hybrid"]).expect(0);
    sb.run(&["mux-apply"]).expect(0);
    assert_eq!(sb.read(LEGACY), "1");
}

#[test]
fn a_request_in_the_same_boot_after_apply_can_still_undo_it() {
    let sb = Sandbox::new("n6506mv_618lts");
    applied_dgpu(&sb);
    assert_eq!(sb.read(LEGACY), "0");
    // no reboot happened: the panel is still wired as hybrid but the firmware holds dgpu
    let r = sb.run(&["mux-request", "hybrid"]);
    r.expect(0);
    assert_eq!(
        r.result("mux").at("got").str(),
        "queued",
        "the firmware's pending value must be put back at the next shutdown"
    );
    sb.run(&["mux-apply"]).expect(0);
    assert_eq!(sb.read(LEGACY), "1");
}

#[test]
fn the_armoury_attribute_is_the_one_written_when_the_kernel_has_it() {
    let sb = Sandbox::new("n6506mv_72");
    sb.run(&["mux-request", "dgpu"]).expect(0);
    let before = sb.snapshot();
    let r = sb.run(&["mux-apply"]);
    r.expect(0);
    assert_eq!(sb.read(ARMOURY), "0");
    assert_eq!(sb.read(LEGACY), "1", "the legacy file beside it is left alone");
    assert_eq!(sb.read(PENDING), "0", "pending_reboot is read, never written");
    assert_eq!(before.diff(&sb.snapshot()), vec![format!("root/sys/{ARMOURY}"), "state/mux.json".to_string()]);
    assert_eq!(r.status().at("values.muxStored").str(), "dgpu");
    assert!(r.stderr.contains("pending_reboot"), "the helper mentions it: {}", r.stderr);
}

#[test]
fn an_armoury_attribute_that_does_not_offer_both_values_is_not_used() {
    let sb = Sandbox::new("n6506mv_72");
    let possible = "devices/virtual/firmware-attributes/asus-armoury/attributes/gpu_mux_mode/possible_values";
    sb.chmod(possible, 0o644);
    sb.set(possible, "1");
    sb.run(&["mux-request", "dgpu"]).expect(0);
    sb.run(&["mux-apply"]).expect(0);
    assert_eq!(sb.read(LEGACY), "0", "falls back to the legacy file");
    assert_eq!(sb.read(ARMOURY), "1");
}

// ---------------------------------------------------------------- the stack rule, by direction

/// The machine is on a dGPU-only boot: the firmware holds 0 and the panel hangs off the NVIDIA card.
fn on_dgpu_only(sb: &Sandbox) {
    sb.set(LEGACY, "0");
    sb.rewire("dgpu");
}

/// No NVIDIA module is loaded at all (the driver failed to load, or was unloaded).
fn driver_absent(sb: &Sandbox) {
    fs::write(sb.proc_("modules"), "snd_hda_intel 233472 3 - Live 0x0\n").unwrap();
}

/// The NVIDIA stack cannot be taken down: `nvidia_drm` has references from outside the stack (after a
/// dGPU-only boot the console may sit on the NVIDIA framebuffer), and a process holds the card.
fn stack_stuck(sb: &Sandbox) {
    fs::write(
        sb.proc_("modules"),
        "nvidia_uvm 2482176 0 - Live 0x0\nnvidia_drm 163840 3 - Live 0x0\nnvidia_modeset 1998848 1 nvidia_drm, Live 0x0\nnvidia 18722816 2 nvidia_uvm,nvidia_modeset, Live 0x0\n",
    )
    .unwrap();
    sb.put(&sb.proc_("4242/comm"), "blender\n");
    fs::create_dir_all(sb.proc_("4242/fd")).unwrap();
    std::os::unix::fs::symlink(sb.dev("nvidia0"), sb.proc_("4242/fd/3")).unwrap();
}

/// THE rule of `mux-apply`, as a table: only the switch TO dGPU-only waits for the NVIDIA stack to come
/// down (and is not written when it will not); the way back to hybrid is written whatever the stack does.
/// The default stack of the sandbox is loaded and CAN come down (every reference is the stack's own).
#[test]
fn the_stack_rule_by_direction_and_by_state_of_the_stack() {
    struct Case {
        want: &'static str,
        stack: &'static str,
        code: i32,
        firmware: &'static str,
        state: &'static str,
        why: &'static str,
    }
    let case = |want, stack, code, firmware, state, why| Case { want, stack, code, firmware, state, why };
    let cases = [
        // the way back: written in all three, the driver only mentioned when it was loaded
        case("hybrid", "absent", 0, "1", "applied", ""),
        case("hybrid", "comes down", 0, "1", "applied", "written with the NVIDIA driver still loaded"),
        case("hybrid", "stuck", 0, "1", "applied", "written with the NVIDIA driver still loaded"),
        // the switch to dGPU-only: written with the stack down, NOT written (a failed record, still on
        // hybrid) when it will not come down
        case("dgpu", "comes down", 0, "0", "applied", ""),
        case("dgpu", "stuck", 1, "1", "failed", "the NVIDIA stack could not be brought down"),
    ];
    for c in cases {
        let sb = Sandbox::new("n6506mv_618lts");
        if c.want == "hybrid" {
            on_dgpu_only(&sb);
        }
        match c.stack {
            "absent" => driver_absent(&sb),
            "stuck" => stack_stuck(&sb),
            _ => {}
        }
        let label = format!("{} with a stack that is {}", c.want, c.stack);
        sb.run(&["mux-request", c.want]).expect(0);
        let before = sb.snapshot();
        let r = sb.run(&["mux-apply"]);
        r.expect(c.code);
        assert_eq!(sb.read(LEGACY), c.firmware, "{label}: the firmware");
        assert_eq!(state_of(&sb), c.state, "{label}: the record");
        let why = r.result("mux").at("why").str();
        assert!(why.contains(c.why) && (!c.why.is_empty() || why.is_empty()), "{label}: the answer says '{why}'");
        assert_eq!(record(&sb).at("why").str(), why, "{label}: the record and the answer say the same");
        let touched = if c.state == "applied" {
            vec![format!("root/sys/{LEGACY}"), "state/mux.json".to_string()]
        } else {
            vec!["state/mux.json".to_string()]
        };
        assert_eq!(before.diff(&sb.snapshot()), touched, "{label}: nothing else was written");
    }
}

#[test]
fn the_way_back_with_the_dgpu_in_use_is_written_and_names_the_driver() {
    // a process holds the card and nvidia_drm has outside references: the dGPU direction records `failed`
    // after its drain (apply_skips_the_write_when_something_still_holds_the_dgpu); the way back is written
    let sb = Sandbox::new("n6506mv_618lts");
    on_dgpu_only(&sb);
    stack_stuck(&sb);
    sb.run(&["mux-request", "hybrid"]).expect(0);
    let r = sb.run(&["mux-apply"]);
    r.expect(0);
    assert!(r.ok());
    let why = r.result("mux").at("why").str();
    for module in ["nvidia_uvm", "nvidia_drm", "nvidia_modeset", "nvidia"] {
        assert!(why.contains(module), "{module} in '{why}'");
    }
    assert!(r.stderr.contains("written with the NVIDIA driver still loaded"), "the journal gets it too: {}", r.stderr);
    assert_eq!(r.status().at("values.muxStored").str(), "hybrid");
    assert_eq!(r.status().at("mux.record.state").str(), "applied");
}

#[test]
fn the_way_back_goes_to_the_armoury_attribute_too_with_the_stack_stuck() {
    let sb = Sandbox::new("n6506mv_72");
    on_dgpu_only(&sb);
    sb.set(ARMOURY, "0");
    stack_stuck(&sb);
    sb.run(&["mux-request", "hybrid"]).expect(0);
    let before = sb.snapshot();
    let r = sb.run(&["mux-apply"]);
    r.expect(0);
    assert_eq!(sb.read(ARMOURY), "1");
    assert_eq!(sb.read(LEGACY), "0", "the legacy file beside it is left alone");
    assert_eq!(sb.read(PENDING), "0", "pending_reboot is read, never written");
    assert_eq!(before.diff(&sb.snapshot()), vec![format!("root/sys/{ARMOURY}"), "state/mux.json".to_string()]);
}

#[test]
fn a_failing_way_back_write_is_a_failed_record_and_the_firmware_is_not_touched() {
    for (fault, code, why) in [
        ("mux:eio", "io", "writing gpu_mux_mode"),
        ("mux:ignore", "mismatch", "the firmware holds dgpu after the write"),
        ("mux:clamp:dgpu", "mismatch", "the firmware holds dgpu after the write"),
    ] {
        let sb = Sandbox::new("n6506mv_618lts");
        on_dgpu_only(&sb);
        stack_stuck(&sb);
        sb.run(&["mux-request", "hybrid"]).expect(0);
        let r = sb.run_env(&["mux-apply"], &[("SILICON_TEST_FAULTS", fault)]);
        r.expect(1);
        assert_eq!(r.code_of("mux"), code, "{fault}");
        assert_eq!(state_of(&sb), "failed", "{fault}");
        assert!(record(&sb).at("why").str().contains(why), "{fault}: {}", record(&sb).at("why").str());
        assert_eq!(sb.read(LEGACY), "0", "{fault}: still dGPU-only, honestly recorded");
    }
}

#[test]
fn the_way_back_end_to_end_with_the_stack_stuck() {
    let sb = Sandbox::new("n6506mv_618lts");
    on_dgpu_only(&sb);
    stack_stuck(&sb);
    sb.run(&["mux-request", "hybrid"]).expect(0);
    sb.run(&["mux-apply"]).expect(0);
    assert_eq!(sb.read(LEGACY), "1");
    // the reboot: the panel is wired to the iGPU again, the guard has nothing to wait for
    reboot_into(&sb, "hybrid");
    let log = reboot_env(&sb);
    let r = sb.run_env(&["mux-guard"], &[("SILICON_TEST_REBOOT", log.as_str())]);
    r.expect(0);
    assert_eq!(state_of(&sb), "kept", "back on hybrid: confirmed at once, no prompt, no deadline");
    assert!(record(&sb).at("deadlineBootId").is_null());
    assert_eq!(reboots(&sb), 0);
    assert_eq!(sb.read(LEGACY), "1");
}

// ---------------------------------------------------------------- guard (next boot)

#[test]
fn guard_kept_the_user_confirms_in_time() {
    let sb = Sandbox::new("n6506mv_618lts");
    applied_dgpu(&sb);
    reboot_into(&sb, "dgpu");
    let guard = spawn_guard(&sb);
    wait_for_state(&sb, "awaiting-keep");
    let rec = record(&sb);
    // the guard's deadline is boot + 5 min, counted in THIS boot's time since boot
    assert_eq!(rec.at("deadlineBootId").str(), BOOT_B);
    assert_eq!(rec.at("deadlineUptimeMs").num(), 300_000.0);
    // the wall-clock deadline is for the shell's countdown: the fake uptime is 100.5 s, so about 199.5 s from now
    let left = rec.at("deadlineMs").num() - now_ms();
    assert!(left > 190_000.0 && left < 210_000.0, "deadline {left} ms away");
    assert_eq!(rec.at("why").str(), "");
    // status.mux.record carries the pair
    let st = sb.status();
    assert_eq!(st.status().at("mux.record.deadlineBootId").str(), BOOT_B);
    assert_eq!(st.status().at("mux.record.deadlineUptimeMs").num(), 300_000.0);
    assert_eq!(st.status().at("mux.record"), &rec);

    // the prompt shortens BOTH deadlines, each on its own clock: uptime 100.5 s + 120 s, and wall now + 120 s
    let r = sb.run(&["mux-prompt-shown"]);
    r.expect(0);
    let after = record(&sb);
    assert_eq!(after.at("deadlineUptimeMs").num(), 220_500.0, "min(300 000, 100 500 + 120 000)");
    assert_eq!(after.at("deadlineBootId").str(), BOOT_B);
    let left = after.at("deadlineMs").num() - now_ms();
    assert!(left > 100_000.0 && left <= 120_500.0, "the prompt shortens the deadline to about 120 s, got {left}");
    // ... and neither ever grows: a second prompt a little later (uptime 130 s) moves the uptime deadline only down
    sb.set_uptime("130.00");
    sb.run(&["mux-prompt-shown"]).expect(0);
    assert_eq!(
        record(&sb).at("deadlineUptimeMs").num(),
        220_500.0,
        "130 s + 120 s = 250 s is later: the earlier deadline stands"
    );
    set_field(&sb, "deadlineUptimeMs", "150000");
    sb.run(&["mux-prompt-shown"]).expect(0);
    assert_eq!(record(&sb).at("deadlineUptimeMs").num(), 150_000.0, "min(existing, uptime + 120 s): never grows");
    assert!(record(&sb).at("deadlineMs").num() - now_ms() <= 120_500.0);
    sb.set_uptime("100.50");
    set_field(&sb, "deadlineUptimeMs", "220500");

    // a request while the change waits for its answer is refused
    sb.run(&["mux-request", "hybrid"]).expect(2);

    let r = sb.run(&["mux-confirm"]);
    r.expect(0);
    assert_eq!(r.result("mux").at("got").str(), "kept");
    let done = wait_for(guard, 10);
    done.expect(0);
    assert_eq!(done.result("mux").at("got").str(), "kept", "the guard's own answer says where the record ended up");
    assert_eq!(state_of(&sb), "kept");
    assert_eq!(reboots(&sb), 0, "kept: no reboot");
    assert_eq!(sb.read(LEGACY), "0", "kept: the firmware keeps dgpu");
    let kept = record(&sb);
    assert!(
        kept.at("deadlineMs").is_null() && kept.at("deadlineBootId").is_null() && kept.at("deadlineUptimeMs").is_null()
    );
}

#[test]
fn guard_reverted_after_the_deadline_with_exactly_one_reboot() {
    let sb = Sandbox::new("n6506mv_618lts");
    applied_dgpu(&sb);
    reboot_into(&sb, "dgpu");
    let reboot_file = reboot_env(&sb);
    let env = [("SILICON_TEST_REBOOT", reboot_file.as_str())];
    let guard = sb.spawn(&["mux-guard"], &env);
    wait_for_state(&sb, "awaiting-keep");
    expire(&sb);
    let done = wait_for(guard, 10);
    done.expect(0);
    assert_eq!(state_of(&sb), "reverted");
    assert_eq!(done.result("mux").at("got").str(), "reverted");
    assert_eq!(sb.read(LEGACY), "1", "hybrid (1) was written back");
    assert!(record(&sb).at("why").str().contains("not confirmed in time"));
    assert_eq!(reboots(&sb), 1, "one reboot line");
    assert_eq!(fs::read_to_string(sb.reboot_file()).unwrap().trim(), "reboot requested by silicon-helper");

    // once per record: running the guard again (the next boot, say) asks for nothing
    let again = sb.run_env(&["mux-guard"], &env);
    again.expect(0);
    assert_eq!(reboots(&sb), 1, "the record said reverted BEFORE the first reboot; a second run never asks again");
    assert_eq!(state_of(&sb), "reverted");
}

#[test]
fn guard_writes_the_record_before_it_asks_for_the_reboot() {
    // The reboot request fails (no SILICON_TEST_REBOOT in test mode): the record must already say reverted.
    let sb = Sandbox::new("n6506mv_618lts");
    applied_dgpu(&sb);
    reboot_into(&sb, "dgpu");
    let guard = sb.spawn(&["mux-guard"], &[]);
    wait_for_state(&sb, "awaiting-keep");
    expire(&sb);
    let done = wait_for(guard, 10);
    done.expect(1);
    assert_eq!(state_of(&sb), "reverted", "the state is written first");
    assert_eq!(done.code_of("mux"), "io");
    assert!(done.result("mux").at("why").str().contains("reboot was not started"), "{}", done.stdout);
    assert_eq!(sb.read(LEGACY), "1");
}

#[test]
fn guard_failed_when_the_wiring_did_not_change() {
    let sb = Sandbox::new("n6506mv_618lts");
    applied_dgpu(&sb);
    sb.new_boot(BOOT_B); // rebooted, but the panel is still on the iGPU
    let reboot_file = reboot_env(&sb);
    let r = sb.run_env(&["mux-guard"], &[("SILICON_TEST_REBOOT", reboot_file.as_str())]);
    r.expect(1);
    assert_eq!(state_of(&sb), "failed");
    assert!(
        record(&sb).at("why").str().contains("wired to hybrid after the reboot (wanted dgpu)"),
        "{}",
        record(&sb).at("why").str()
    );
    assert_eq!(sb.read(LEGACY), "1", "the pending firmware setting was withdrawn so a later reboot cannot surprise");
    assert_eq!(reboots(&sb), 0, "nothing to revert, no reboot");
    assert!(record(&sb).at("deadlineMs").is_null());
}

#[test]
fn a_way_back_that_did_not_take_writes_nothing_and_the_record_says_why() {
    // The firmware was given hybrid at shutdown, the machine rebooted -- and the panel is still on the NVIDIA card.
    // The guard marks the record failed and WRITES NOTHING: the dGPU value is never written at boot, only at
    // shutdown for a request the user made (pre-checks, stack down, then the confirmation window). The old rule put
    // "what the panel is wired as" back -- a dGPU write nobody asked for, undoing a way back that a second boot
    // might still have completed.
    let sb = Sandbox::new("n6506mv_618lts");
    on_dgpu_only(&sb);
    sb.run(&["mux-request", "hybrid"]).expect(0);
    sb.run(&["mux-apply"]).expect(0);
    assert_eq!(sb.read(LEGACY), "1", "the firmware holds hybrid");
    reboot_into(&sb, "dgpu");
    let before = sb.snapshot();
    let log = reboot_env(&sb);
    let r = sb.run_env(&["mux-guard"], &[("SILICON_TEST_REBOOT", log.as_str())]);
    r.expect(1);
    assert_eq!(r.code_of("mux"), "mismatch");
    assert_eq!(state_of(&sb), "failed");
    let why = record(&sb).at("why").str().to_string();
    assert!(why.contains("wired to dgpu after the reboot (wanted hybrid)") && why.contains("left as it is"), "{why}");
    assert_eq!(sb.read(LEGACY), "1", "the firmware keeps hybrid: the dGPU value was not written");
    assert_eq!(reboots(&sb), 0);
    assert_eq!(before.diff(&sb.snapshot()), vec!["state/mux.json".to_string()], "only the record changed");
    assert!(record(&sb).at("deadlineMs").is_null());
}

#[test]
fn guard_keeps_hybrid_at_once_and_does_not_wait() {
    let sb = Sandbox::new("n6506mv_618lts");
    sb.set(LEGACY, "0");
    sb.rewire("dgpu");
    sb.run(&["mux-request", "hybrid"]).expect(0);
    sb.run(&["mux-apply"]).expect(0);
    assert_eq!(sb.read(LEGACY), "1");
    reboot_into(&sb, "hybrid");
    let start = Instant::now();
    let r = sb.run(&["mux-guard"]);
    r.expect(0);
    assert!(start.elapsed() < Duration::from_secs(3));
    assert_eq!(state_of(&sb), "kept", "going back to hybrid needs no confirmation");
}

#[test]
fn guard_stays_armed_when_the_wiring_cannot_be_read_after_a_switch_to_dgpu() {
    let sb = Sandbox::new("n6506mv_618lts");
    applied_dgpu(&sb);
    sb.new_boot(BOOT_B);
    sb.all_edp("disconnected"); // the panel is dark and no connector reads connected
    let reboot_file = reboot_env(&sb);
    let guard = sb.spawn(&["mux-guard"], &[("SILICON_TEST_REBOOT", reboot_file.as_str())]);
    wait_for_state(&sb, "awaiting-keep");
    assert!(record(&sb).at("why").str().contains("stays armed"));
    expire(&sb);
    let done = wait_for(guard, 10);
    done.expect(0);
    assert_eq!(state_of(&sb), "reverted");
    assert_eq!(reboots(&sb), 1);
}

#[test]
fn guard_in_the_boot_that_applied_does_nothing_yet() {
    let sb = Sandbox::new("n6506mv_618lts");
    applied_dgpu(&sb);
    let before = sb.snapshot();
    let r = sb.run(&["mux-guard"]);
    r.expect(0);
    assert!(r.why().contains("applied in this boot"));
    assert_eq!(state_of(&sb), "applied");
    assert_untouched(&before, &sb.snapshot());
    // and a request in the next boot is refused until the guard has looked
    sb.new_boot(BOOT_B);
    sb.rewire("dgpu");
    let r = sb.run(&["mux-request", "hybrid"]);
    r.expect(2);
    assert!(r.result("mux").at("why").str().contains("not been checked"), "{}", r.stdout);
}

#[test]
fn guard_with_no_record_or_a_finished_one_does_nothing() {
    let sb = Sandbox::new("n6506mv_618lts");
    let before = sb.snapshot();
    sb.run(&["mux-guard"]).expect(0);
    assert_untouched(&before, &sb.snapshot());
    sb.run(&["mux-request", "dgpu"]).expect(0);
    sb.run(&["mux-cancel"]).expect(0);
    let before = sb.snapshot();
    sb.run(&["mux-guard"]).expect(0);
    assert_untouched(&before, &sb.snapshot());
}

#[test]
fn a_failed_revert_write_is_failed_and_never_a_reboot() {
    let sb = Sandbox::new("n6506mv_618lts");
    applied_dgpu(&sb);
    reboot_into(&sb, "dgpu");
    let reboot_file = reboot_env(&sb);
    let env = [("SILICON_TEST_REBOOT", reboot_file.as_str()), ("SILICON_TEST_FAULTS", "mux:eio")];
    let guard = sb.spawn(&["mux-guard"], &env);
    wait_for_state(&sb, "awaiting-keep");
    expire(&sb);
    let done = wait_for(guard, 10);
    done.expect(1);
    assert_eq!(state_of(&sb), "failed");
    assert!(record(&sb).at("why").str().contains("hybrid could not be written back"));
    assert_eq!(reboots(&sb), 0, "a reboot cannot fix a firmware write that failed");
    assert_eq!(sb.read(LEGACY), "0");
}

// ---------------------------------------------------------------- the guard decides on time since boot

const BOOT_C: &str = "cccccccc-0000-4000-8000-000000000003";

/// Boot B's guard has promoted the record and is waiting: returns it (still running).
fn waiting_guard(sb: &Sandbox) -> std::process::Child {
    applied_dgpu(sb);
    reboot_into(sb, "dgpu");
    let guard = spawn_guard(sb);
    wait_for_state(sb, "awaiting-keep");
    assert_eq!(record(sb).at("deadlineBootId").str(), BOOT_B);
    assert_eq!(record(sb).at("deadlineUptimeMs").num(), 300_000.0);
    guard
}

#[test]
fn status_mux_record_carries_the_boot_and_uptime_deadline() {
    let sb = Sandbox::new("n6506mv_618lts");
    let guard = waiting_guard(&sb);
    let st = sb.status();
    let rec = st.status().at("mux.record");
    assert_eq!(rec.at("state").str(), "awaiting-keep");
    assert_eq!(rec.at("deadlineBootId").str(), BOOT_B, "the boot the guard's deadline counts in");
    assert_eq!(rec.at("deadlineUptimeMs").num(), 300_000.0, "boot + 5 min, as ms since that boot");
    assert!(rec.at("deadlineMs").num() > now_ms(), "and the wall-clock deadline for the countdown");
    assert_eq!(st.status().at("boot.id").str(), BOOT_B, "so a reader can tell whether the pair counts in its boot");
    assert_eq!(
        rec.keys(),
        ["want", "from", "state", "why", "requestedAtMs", "bootId", "deadlineMs", "deadlineBootId", "deadlineUptimeMs"]
    );
    sb.run(&["mux-confirm"]).expect(0);
    wait_for(guard, 10).expect(0);
    let done = sb.status();
    let rec = done.status().at("mux.record");
    assert!(
        rec.at("deadlineBootId").is_null() && rec.at("deadlineUptimeMs").is_null() && rec.at("deadlineMs").is_null()
    );
}

#[test]
fn prompt_shown_shortens_both_deadlines_each_on_its_own_clock_and_neither_grows() {
    let sb = Sandbox::new("n6506mv_618lts");
    let guard = waiting_guard(&sb);
    let uptime_deadline = |sb: &Sandbox| record(sb).at("deadlineUptimeMs").num();
    let wall_left = |sb: &Sandbox| record(sb).at("deadlineMs").num() - now_ms();

    // the prompt appears 100.5 s into the boot: the guard's deadline becomes min(300 000, 100 500 + 120 000)
    // ms since boot, the shell's min(wall deadline, now + 120 s) -- two clocks, two minimums
    sb.run(&["mux-prompt-shown"]).expect(0);
    assert_eq!(uptime_deadline(&sb), 220_500.0);
    assert_eq!(record(&sb).at("deadlineBootId").str(), BOOT_B);
    assert!(wall_left(&sb) > 100_000.0 && wall_left(&sb) <= 120_500.0, "{}", wall_left(&sb));

    // the wall clock stepped back by hours: the stored wall deadline is 3 h ahead. The prompt pulls IT to
    // now + 120 s and leaves the guard's deadline (its own clock) alone
    set_deadline(&sb, (now_ms() + 3.0 * 3_600_000.0) as u64);
    sb.run(&["mux-prompt-shown"]).expect(0);
    assert!(wall_left(&sb) <= 120_500.0, "the wall deadline came back to now + 120 s: {}", wall_left(&sb));
    assert_eq!(uptime_deadline(&sb), 220_500.0, "the uptime deadline did not move with the wall clock");

    // the wall clock stepped forward: the stored wall deadline is long past. The prompt never grows it
    set_deadline(&sb, 1);
    sb.run(&["mux-prompt-shown"]).expect(0);
    assert_eq!(record(&sb).at("deadlineMs").num(), 1.0, "min(existing, now + 120 s): it never grows");
    assert_eq!(uptime_deadline(&sb), 220_500.0);

    // later in the boot (130 s): 130 + 120 = 250 s is LATER than 220.5 s, so the guard's deadline stands; an earlier
    // one (150 s) is kept as it is
    sb.set_uptime("130.00");
    sb.run(&["mux-prompt-shown"]).expect(0);
    assert_eq!(uptime_deadline(&sb), 220_500.0);
    set_field(&sb, "deadlineUptimeMs", "150000");
    sb.run(&["mux-prompt-shown"]).expect(0);
    assert_eq!(uptime_deadline(&sb), 150_000.0);

    // and it is the shortened uptime deadline the guard now acts on
    sb.set_uptime("150.00");
    let done = wait_for(guard, 10);
    done.expect(0);
    assert_eq!(state_of(&sb), "reverted");
    assert_eq!(reboots(&sb), 1);
}

#[test]
fn a_wall_clock_that_stepped_back_by_hours_still_reverts_on_time() {
    // NTP corrects an RTC that was hours ahead: the wall deadline stored at promotion is now THREE HOURS in the
    // future. The guard must not wait for it: five minutes since boot is five minutes since boot.
    let sb = Sandbox::new("n6506mv_618lts");
    let mut guard = waiting_guard(&sb);
    set_deadline(&sb, (now_ms() + 3.0 * 3_600_000.0) as u64);
    std::thread::sleep(Duration::from_millis(500));
    assert!(guard.try_wait().unwrap().is_none(), "still waiting at 100 s since boot");
    assert_eq!(state_of(&sb), "awaiting-keep");
    assert_eq!(reboots(&sb), 0);
    sb.set_uptime("300.50"); // the fake /proc/uptime: five minutes since boot
    let done = wait_for(guard, 10);
    done.expect(0);
    assert_eq!(state_of(&sb), "reverted", "on time, whatever the wall clock says");
    assert_eq!(reboots(&sb), 1);
    assert_eq!(sb.read(LEGACY), "1");
    let rec = record(&sb);
    assert!(
        rec.at("deadlineMs").is_null() && rec.at("deadlineBootId").is_null() && rec.at("deadlineUptimeMs").is_null()
    );
}

#[test]
fn a_wall_clock_that_stepped_forward_does_not_revert_early() {
    // The wall clock jumps forward (a day, say): the stored wall deadline is now long past. Nothing is due.
    let sb = Sandbox::new("n6506mv_618lts");
    let mut guard = waiting_guard(&sb);
    set_deadline(&sb, 1);
    std::thread::sleep(Duration::from_millis(600)); // six polls
    assert!(guard.try_wait().unwrap().is_none(), "the guard keeps waiting");
    assert_eq!(state_of(&sb), "awaiting-keep");
    assert_eq!(reboots(&sb), 0, "no early reboot");
    assert_eq!(sb.read(LEGACY), "0", "no early revert");
    // the user can still confirm
    sb.run(&["mux-confirm"]).expect(0);
    wait_for(guard, 10).expect(0);
    assert_eq!(state_of(&sb), "kept");
    assert_eq!(reboots(&sb), 0);
}

#[test]
fn an_awaiting_keep_record_from_another_boot_reverts_at_once_and_reboots_once() {
    let sb = Sandbox::new("n6506mv_618lts");
    let mut guard = waiting_guard(&sb);
    // the machine reboots before the user confirms: boot B's guard is gone, boot C starts
    guard.kill().unwrap();
    guard.wait().unwrap();
    assert_eq!(state_of(&sb), "awaiting-keep");
    sb.new_boot(BOOT_C);
    sb.set_uptime("1.00"); // one second into the new boot: nowhere near 300 s
    let log = reboot_env(&sb);
    let env = [("SILICON_TEST_REBOOT", log.as_str())];
    let start = Instant::now();
    let r = sb.run_env(&["mux-guard"], &env);
    r.expect(0);
    assert!(start.elapsed() < Duration::from_secs(3), "at once");
    assert_eq!(state_of(&sb), "reverted", "an unconfirmed record that survived a reboot is past its deadline");
    assert_eq!(sb.read(LEGACY), "1");
    assert_eq!(reboots(&sb), 1);
    // once per record: the guard of the next boot asks for nothing
    sb.new_boot("dddddddd-0000-4000-8000-000000000004");
    sb.run_env(&["mux-guard"], &env).expect(0);
    sb.run_env(&["mux-guard"], &env).expect(0);
    assert_eq!(reboots(&sb), 1, "still exactly one reboot line");
    assert_eq!(state_of(&sb), "reverted");
}

#[test]
fn a_prompt_shown_in_another_boot_does_not_give_a_dead_window_two_more_minutes() {
    let sb = Sandbox::new("n6506mv_618lts");
    let mut guard = waiting_guard(&sb);
    guard.kill().unwrap();
    guard.wait().unwrap();
    sb.new_boot(BOOT_C);
    let before = sb.snapshot();
    let r = sb.run(&["mux-prompt-shown"]);
    r.expect(2);
    assert_eq!(r.code_of("mux"), "refused");
    assert!(r.result("mux").at("why").str().contains("earlier boot"), "{}", r.stdout);
    assert_untouched(&before, &sb.snapshot());
}

#[test]
fn a_record_without_the_pair_gets_the_boot_window_from_the_guard() {
    // an awaiting-keep record in the older shape (no deadlineBootId / deadlineUptimeMs): the strict reader takes
    // it, status shows it with the pair null, and the guard sets the boot window, as for any missing deadline
    let sb = Sandbox::new("n6506mv_618lts");
    applied_dgpu(&sb);
    reboot_into(&sb, "dgpu");
    let old = format!(
        "{{\"want\":\"dgpu\",\"from\":\"hybrid\",\"state\":\"awaiting-keep\",\"why\":\"\",\"requestedAtMs\":1,\"bootId\":\"{BOOT_A}\",\"deadlineMs\":4102444800000}}\n"
    );
    fs::write(sb.state().join("mux.json"), old).unwrap();
    let st = sb.status();
    assert!(
        st.status().at("mux.record.deadlineBootId").is_null()
            && st.status().at("mux.record.deadlineUptimeMs").is_null()
    );
    assert_eq!(st.status().at("mux.record.deadlineMs").num(), 4_102_444_800_000.0);
    let guard = spawn_guard(&sb);
    let start = Instant::now();
    while !record(&sb).has("deadlineUptimeMs") || record(&sb).at("deadlineUptimeMs").is_null() {
        assert!(
            start.elapsed() < Duration::from_secs(8),
            "the guard never set the pair: {}",
            sb.state_file("mux.json")
        );
        std::thread::sleep(Duration::from_millis(30));
    }
    let rec = record(&sb);
    assert_eq!(rec.at("deadlineBootId").str(), BOOT_B);
    assert_eq!(rec.at("deadlineUptimeMs").num(), 300_000.0);
    let left = rec.at("deadlineMs").num() - now_ms();
    assert!(left > 190_000.0 && left < 210_000.0, "the wall deadline is recomputed for display: {left}");
    assert_eq!(state_of(&sb), "awaiting-keep");
    expire(&sb);
    wait_for(guard, 10).expect(0);
    assert_eq!(state_of(&sb), "reverted");
}

#[test]
fn without_a_readable_uptime_the_guard_counts_its_own_time_never_the_wall_clock() {
    let sb = Sandbox::new("n6506mv_618lts");
    applied_dgpu(&sb);
    reboot_into(&sb, "dgpu");
    fs::remove_file(sb.proc_("uptime")).unwrap();
    let mut guard = spawn_guard(&sb);
    wait_for_state(&sb, "awaiting-keep");
    // a wall deadline hours away, and a guard-time deadline 1.5 s away: the second one counts
    set_deadline(&sb, (now_ms() + 3.0 * 3_600_000.0) as u64);
    set_field(&sb, "deadlineUptimeMs", "1500");
    std::thread::sleep(Duration::from_millis(300));
    assert!(guard.try_wait().unwrap().is_none() && state_of(&sb) == "awaiting-keep", "not yet");
    wait_for(guard, 10).expect(0);
    assert_eq!(state_of(&sb), "reverted");
    assert_eq!(reboots(&sb), 1);
}

// ---------------------------------------------------------------- faults at apply

#[test]
fn a_failing_or_ignored_firmware_write_is_a_failed_record() {
    let sb = Sandbox::new("n6506mv_618lts");
    sb.run(&["mux-request", "dgpu"]).expect(0);
    let r = sb.run_env(&["mux-apply"], &[("SILICON_TEST_FAULTS", "mux:eio")]);
    r.expect(1);
    assert_eq!(r.code_of("mux"), "io");
    assert_eq!(state_of(&sb), "failed");
    assert_eq!(sb.read(LEGACY), "1");
    sb.run(&["mux-request", "dgpu"]).expect(0);
    let r = sb.run_env(&["mux-apply"], &[("SILICON_TEST_FAULTS", "mux:ignore")]);
    r.expect(1);
    assert_eq!(r.code_of("mux"), "mismatch");
    assert_eq!(state_of(&sb), "failed");
    assert!(record(&sb).at("why").str().contains("the firmware holds hybrid after the write"));
    sb.run(&["mux-request", "dgpu"]).expect(0);
    let r = sb.run_env(&["mux-apply"], &[("SILICON_TEST_FAULTS", "mux:clamp:hybrid")]);
    r.expect(1);
    assert_eq!(r.code_of("mux"), "mismatch");
}

// ---------------------------------------------------------------- the armoury answers with the old value until the restart

/// 2026-11-04, kernel 7.2: the firmware took the write, `current_value` still reads the old value and `pending_reboot` says 1.
/// (`mux:ignore` is the old value standing; the fixture's `pending_reboot` is the attribute's own file.)
#[test]
fn an_armoury_write_that_waits_for_the_restart_is_applied_not_failed() {
    let sb = Sandbox::new("n6506mv_72");
    sb.run(&["mux-request", "dgpu"]).expect(0);
    sb.chmod(PENDING, 0o644);
    sb.set(PENDING, "1");
    let r = sb.run_env(&["mux-apply"], &[("SILICON_TEST_FAULTS", "mux:ignore")]);
    r.expect(0);
    assert_eq!(state_of(&sb), "applied", "{}", sb.state_file("mux.json"));
    assert_eq!(sb.read(ARMOURY), "1", "the stand-in kept the old value, as the real attribute does until the restart");
    // the next boot: the panel is wired dgpu -> the guard asks for the keep, like any applied switch
    reboot_into(&sb, "dgpu");
    let guard = spawn_guard(&sb);
    wait_for_state(&sb, "awaiting-keep");
    sb.run(&["mux-confirm"]).expect(0);
    wait_for(guard, 10).expect(0);
    assert_eq!(state_of(&sb), "kept");
    assert_eq!(reboots(&sb), 0, "kept: no reboot");
}

#[test]
fn an_armoury_write_that_reads_back_old_with_nothing_pending_is_still_a_mismatch() {
    let sb = Sandbox::new("n6506mv_72");
    sb.run(&["mux-request", "dgpu"]).expect(0);
    assert_eq!(sb.read(PENDING), "0");
    let r = sb.run_env(&["mux-apply"], &[("SILICON_TEST_FAULTS", "mux:ignore")]);
    r.expect(1);
    assert_eq!(r.code_of("mux"), "mismatch");
    assert_eq!(state_of(&sb), "failed");
    assert!(record(&sb).at("why").str().contains("the firmware holds hybrid after the write"));
}

#[test]
fn a_pending_reboot_means_nothing_without_the_armoury_attribute() {
    // the legacy file has no pending_reboot of its own: a stray one beside the armoury tree is not read for it
    let sb = Sandbox::new("n6506mv_618lts");
    sb.run(&["mux-request", "dgpu"]).expect(0);
    let r = sb.run_env(&["mux-apply"], &[("SILICON_TEST_FAULTS", "mux:ignore")]);
    r.expect(1);
    assert_eq!(r.code_of("mux"), "mismatch");
    assert_eq!(state_of(&sb), "failed");
}

// ---------------------------------------------------------------- records the helper does not understand

#[test]
fn a_record_that_is_not_understood_is_reported_and_never_overwritten() {
    let sb = Sandbox::new("n6506mv_618lts");
    fs::write(sb.state().join("mux.json"), r#"{"want":"dgpu","state":"queued"}"#).unwrap();
    let r = sb.status();
    r.expect(0);
    assert!(r.status().at("mux.record").is_null());
    assert!(r.stderr.contains("not understood"), "{}", r.stderr);
    let before = sb.snapshot();
    let r = sb.run(&["mux-request", "dgpu"]);
    r.expect(2);
    assert!(r.result("mux").at("why").str().contains("not understood"));
    assert_untouched(&before, &sb.snapshot());
    for cmd in ["mux-cancel", "mux-confirm", "mux-apply", "mux-guard"] {
        let r = sb.run(&[cmd]);
        assert_ne!(r.code, 0, "{cmd}");
    }
    assert_untouched(&before, &sb.snapshot());
}

#[test]
fn a_machine_without_a_mux_refuses_requests_as_absent() {
    let sb = Sandbox::new("n6506mv_618lts");
    sb.remove(LEGACY);
    let before = sb.snapshot();
    let r = sb.run(&["mux-request", "dgpu"]);
    r.expect(2);
    assert_eq!(r.code_of("mux"), "absent");
    assert!(!r.status().at("features.mux").bool());
    assert!(r.status().at("values.muxStored").is_null());
    assert!(r.status().at("mux.stored").is_null());
    assert_untouched(&before, &sb.snapshot());
}

#[test]
fn bad_arguments_to_the_mux_commands_are_usage_errors() {
    let sb = Sandbox::new("n6506mv_618lts");
    let before = sb.snapshot();
    for args in [
        vec!["mux-request"],
        vec!["mux-request", "both"],
        vec!["mux-request", "dgpu", "hybrid"],
        vec!["mux-request", "DGPU"],
        vec!["mux-cancel", "now"],
        vec!["mux-confirm", "x"],
        vec!["mux-apply", "x"],
    ] {
        sb.run(&args).expect(2);
    }
    assert_untouched(&before, &sb.snapshot());
}

// ---------------------------------------------------------------- nothing that writes reads the NVIDIA driver

/// The NVIDIA driver's proc entry made a trap: a FIFO with no writer, so that any read of it blocks for good --
/// what a wedged driver does to `/proc/driver/nvidia/gpus/<pci>/information`.
fn wedge_the_nvidia_proc_entry(sb: &Sandbox) {
    let info = sb.proc_("driver/nvidia/gpus/0000:01:00.0/information");
    fs::remove_file(&info).unwrap();
    let made = std::process::Command::new("mkfifo").arg(&info).status().unwrap();
    assert!(made.success(), "mkfifo");
}

/// Proof that the trap is one: `status` reads that entry and never comes back.
fn assert_status_hangs_on_the_wedge(sb: &Sandbox) {
    let mut child = sb.spawn(&["status"], &[]);
    std::thread::sleep(Duration::from_millis(700));
    let hung = child.try_wait().unwrap().is_none();
    let _ = child.kill();
    let _ = child.wait();
    assert!(hung, "status came back: the wedged entry is no trap, and the tests that use it prove nothing");
}

#[test]
fn the_way_back_is_written_when_the_nvidia_proc_entry_blocks() {
    let sb = Sandbox::new("n6506mv_618lts");
    on_dgpu_only(&sb);
    stack_stuck(&sb);
    sb.run(&["mux-request", "hybrid"]).expect(0);
    wedge_the_nvidia_proc_entry(&sb);
    assert_status_hangs_on_the_wedge(&sb);
    // no read of the driver on the way to the write, and none in the answer either (systemd's own commands do
    // not carry the NVIDIA node): the helper finishes
    let r = wait_for(sb.spawn(&["mux-apply"], &[]), 5);
    r.expect(0);
    assert_eq!(sb.read(LEGACY), "1");
    assert_eq!(state_of(&sb), "applied");
    assert!(
        r.status().at("paths.dgpu.nvidia").is_null(),
        "the answer to a systemd command reads nothing of the driver"
    );
    assert_eq!(r.status().at("paths.dgpu.pci").str(), "0000:01:00.0", "the rest of the dGPU is still there");
}

#[test]
fn the_revert_is_written_when_the_nvidia_proc_entry_blocks() {
    let sb = Sandbox::new("n6506mv_618lts");
    applied_dgpu(&sb);
    reboot_into(&sb, "dgpu");
    wedge_the_nvidia_proc_entry(&sb);
    let reboot_file = reboot_env(&sb);
    let guard = sb.spawn(&["mux-guard"], &[("SILICON_TEST_REBOOT", reboot_file.as_str())]);
    wait_for_state(&sb, "awaiting-keep");
    expire(&sb);
    let done = wait_for(guard, 5);
    done.expect(0);
    assert_eq!(state_of(&sb), "reverted");
    assert_eq!(sb.read(LEGACY), "1", "hybrid was written back");
    assert_eq!(reboots(&sb), 1);
}

#[test]
fn the_guards_withdrawal_is_written_when_the_nvidia_proc_entry_blocks() {
    let sb = Sandbox::new("n6506mv_618lts");
    applied_dgpu(&sb);
    sb.new_boot(BOOT_B); // rebooted, but the panel is still on the iGPU
    wedge_the_nvidia_proc_entry(&sb);
    let reboot_file = reboot_env(&sb);
    let r = wait_for(sb.spawn(&["mux-guard"], &[("SILICON_TEST_REBOOT", reboot_file.as_str())]), 5);
    r.expect(1);
    assert_eq!(state_of(&sb), "failed");
    assert_eq!(sb.read(LEGACY), "1", "the pending dGPU setting was withdrawn");
}

#[test]
fn the_other_commands_systemd_runs_do_not_read_the_driver_either() {
    let sb = Sandbox::new("n6506mv_618lts");
    wedge_the_nvidia_proc_entry(&sb);
    wait_for(sb.spawn(&["record-caps"], &[]), 5).expect(0);
    wait_for(sb.spawn(&["boot-apply"], &[]), 5).expect(0);
}

// ---------------------------------------------------------------- the unit that writes a queued change

#[test]
fn a_request_is_refused_while_the_unit_that_would_write_it_is_not_active() {
    // a queued change is written by silicon-mux.service's ExecStop, at shutdown: with that unit not active it would
    // never be written. Both directions are refused (the way back included: it would queue and never happen).
    for (want, dgpu_only) in [("dgpu", false), ("hybrid", true)] {
        let sb = Sandbox::new("n6506mv_618lts");
        if dgpu_only {
            on_dgpu_only(&sb);
        }
        sb.mux_unit(false);
        let st = sb.status();
        st.expect(0);
        assert!(!st.status().at("prechecks.mux.ok").bool(), "{want}: status says so first, in the shape it always had");
        let why = st.status().at("prechecks.mux.why").str().to_string();
        assert!(why.contains("silicon-mux.service is not active") && why.contains("systemctl start"), "{want}: {why}");
        assert!(st.status().at("features.mux").bool(), "the knob is there; it is the request that cannot go ahead");
        let before = sb.snapshot();
        let r = sb.run(&["mux-request", want]);
        r.expect(2);
        assert_eq!(r.code_of("mux"), "refused", "{want}");
        assert_eq!(r.result("mux").at("why").str(), why, "{want}: the refusal says what status says");
        assert_untouched(&before, &sb.snapshot());
        // the unit is back: the same request goes through
        sb.mux_unit(true);
        assert!(sb.status().status().at("prechecks.mux.ok").bool(), "{want}");
        sb.run(&["mux-request", want]).expect(0);
        assert_eq!(state_of(&sb), "queued", "{want}");
    }
}

#[test]
fn a_queued_request_can_still_be_cancelled_or_withdrawn_when_the_unit_is_not_active() {
    // undoing needs no unit: nothing new is promised
    let sb = Sandbox::new("n6506mv_618lts");
    sb.run(&["mux-request", "dgpu"]).expect(0);
    sb.mux_unit(false);
    sb.run(&["mux-cancel"]).expect(0);
    assert_eq!(state_of(&sb), "cancelled");
    sb.mux_unit(true);
    sb.run(&["mux-request", "dgpu"]).expect(0);
    sb.mux_unit(false);
    let r = sb.run(&["mux-request", "hybrid"]); // hybrid is what the panel is: it withdraws the queued dgpu
    r.expect(0);
    assert_eq!(r.result("mux").at("got").str(), "cancelled");
}

#[test]
fn the_unit_and_the_nvidia_stack_are_both_named_when_both_are_wrong() {
    let sb = Sandbox::new("n6506mv_618lts");
    fs::remove_file(sb.modules().join("7.2.7-arch1-1/updates/dkms/nvidia.ko.zst")).unwrap();
    sb.mux_unit(false);
    let why = sb.status().status().at("prechecks.mux.why").str().to_string();
    assert!(why.contains("no nvidia module is built for kernel 7.2.7-arch1-1"), "{why}");
    assert!(why.contains("; silicon-mux.service is not active"), "{why}");
    // the way back has no NVIDIA pre-check: only the unit is named
    on_dgpu_only(&sb);
    let r = sb.run(&["mux-request", "hybrid"]);
    r.expect(2);
    assert!(
        r.result("mux").at("why").str().starts_with("silicon-mux.service is not active"),
        "{}",
        r.result("mux").at("why").str()
    );
}

#[test]
fn a_systemd_that_exports_nothing_is_not_taken_for_an_inactive_unit() {
    // systemd calls those links an implementation detail: if none exists for any unit, the check cannot tell, and the
    // way back is never refused on the strength of a file systemd does not write
    let sb = Sandbox::new("n6506mv_618lts");
    on_dgpu_only(&sb);
    sb.systemd_exports_nothing();
    assert!(sb.status().status().at("prechecks.mux.ok").bool());
    sb.run(&["mux-request", "hybrid"]).expect(0);
    assert_eq!(state_of(&sb), "queued");
    // and a run directory that has no systemd in it at all
    let sb = Sandbox::new("n6506mv_618lts");
    fs::remove_dir_all(sb.runroot().join("run")).unwrap();
    assert!(sb.status().status().at("prechecks.mux.ok").bool());
}

#[test]
fn without_a_run_root_the_unit_is_not_looked_for() {
    // a probe written before --run-root existed passes the five options it knew: it behaves as it always did
    let sb = Sandbox::new("n6506mv_618lts");
    sb.mux_unit(false);
    let mut args = sb.opts_without_run_root();
    args.push("status".to_string());
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let r = sb.run_raw(&args, &[]);
    r.expect(0);
    assert!(r.status().at("prechecks.mux.ok").bool());
}
