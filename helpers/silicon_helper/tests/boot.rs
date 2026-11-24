//! The charge limit, the stored boot set, `boot-apply` (the firmware's caps recorded once per
//! boot, then the boot set applied) and the one lock.

mod common;
use common::*;
use std::fs;
use std::process::Command;
use std::time::{Duration, Instant};

const BAT: &str =
    "devices/LNXSYSTM:00/LNXSYBUS:00/PNP0A08:00/PNP0C0A:03/power_supply/BAT0/charge_control_end_threshold";
const MSR: &str = "devices/virtual/powercap/intel-rapl/intel-rapl:0";
const MMIO: &str = "devices/virtual/powercap/intel-rapl-mmio/intel-rapl-mmio:0";
const PROFILE: &str = "devices/platform/asus-nb-wmi/platform-profile/platform-profile-0/profile";

fn compact(v: &str) -> String {
    v.trim().to_string()
}

// ---------------------------------------------------------------- charge limit

#[test]
fn the_charge_limit_is_written_read_back_and_stored_for_the_next_boot() {
    for fixture in ["n6506mv_618lts", "n6506mv_72"] {
        charge_limit_round_trip(fixture);
    }
}

fn charge_limit_round_trip(fixture: &str) {
    let sb = Sandbox::new(fixture);
    let before = sb.snapshot();
    let r = sb.run(&["set-charge-limit", "80"]);
    r.expect(0);
    assert!(r.ok());
    assert_eq!(r.results().len(), 1);
    assert_eq!(r.result("chargeLimit").at("want").num(), 80.0);
    assert_eq!(r.result("chargeLimit").at("got").num(), 80.0);
    assert_eq!(r.status().at("values.chargeLimit").num(), 80.0);
    assert_eq!(sb.read(BAT), "80");
    assert_eq!(compact(&sb.state_file("boot.json")), r#"{"version":1,"apply":{},"chargeLimit":80}"#);
    assert_eq!(before.diff(&sb.snapshot()), vec![format!("root/sys/{BAT}"), "state/boot.json".to_string()]);
    sb.run(&["set-charge-limit", "100"]).expect(0);
    assert_eq!(sb.read(BAT), "100");
    assert!(sb.state_file("boot.json").contains("\"chargeLimit\":100"));
}

#[test]
fn only_80_and_100_are_accepted() {
    let sb = Sandbox::new("n6506mv_618lts");
    let before = sb.snapshot();
    for bad in ["90", "79", "101", "0", "50", "80x", "", "-1", "0x50", " 80", "080", "80.0", "eighty"] {
        let r = sb.run(&["set-charge-limit", bad]);
        r.expect(2);
        assert_eq!(r.code_of("chargeLimit"), "refused", "{bad:?}");
        assert!(r.result("chargeLimit").at("why").str().contains("80 or 100"), "{bad:?}");
        assert_untouched(&before, &sb.snapshot());
    }
    for args in [vec!["set-charge-limit"], vec!["set-charge-limit", "80", "100"], vec!["set-charge-limit", "limit=80"]]
    {
        let r = sb.run(&args);
        r.expect(2);
        assert_untouched(&before, &sb.snapshot());
    }
}

#[test]
fn a_failed_charge_limit_write_is_not_stored() {
    let sb = Sandbox::new("n6506mv_618lts");
    let r = sb.run_env(&["set-charge-limit", "80"], &[("SILICON_TEST_FAULTS", "chargeLimit:eio")]);
    r.expect(1);
    assert_eq!(r.code_of("chargeLimit"), "io");
    assert!(!sb.has_state("boot.json"), "a limit that did not land is not remembered for the next boot");
    assert_eq!(sb.read(BAT), "100");
    let r = sb.run_env(&["set-charge-limit", "80"], &[("SILICON_TEST_FAULTS", "chargeLimit:ignore")]);
    r.expect(1);
    assert_eq!(r.code_of("chargeLimit"), "mismatch");
    assert_eq!(r.result("chargeLimit").at("got").num(), 100.0);
    assert!(!sb.has_state("boot.json"));
}

#[test]
fn a_corrupt_boot_file_stops_the_charge_limit_before_anything_is_written() {
    let sb = Sandbox::new("n6506mv_618lts");
    fs::write(sb.state().join("boot.json"), "{ not json").unwrap();
    let before = sb.snapshot();
    let r = sb.run(&["set-charge-limit", "80"]);
    r.expect(2);
    assert_eq!(r.code_of("chargeLimit"), "refused");
    assert!(r.result("chargeLimit").at("why").str().contains("not understood"));
    assert_untouched(&before, &sb.snapshot());
}

// ---------------------------------------------------------------- set-boot

const FULL: [&str; 8] = [
    "set-boot",
    "profile=quiet",
    "epp=power",
    "turbo=0",
    "governor=powersave",
    "max_perf_pct=100",
    "pl1_w=45",
    "pl2_w=firmware",
];

#[test]
fn set_boot_validates_like_apply_and_stores_without_writing_a_knob() {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    let before = sb.snapshot();
    let r = sb.run(&FULL);
    r.expect(0);
    let names: Vec<&str> = r.results().iter().map(|e| e.at("knob").str()).collect();
    assert_eq!(names, ["profile", "governor", "epp", "turbo", "maxPerfPct", "pl1W", "pl2W"]);
    for e in r.results() {
        assert!(e.at("ok").bool());
        assert_eq!(e.at("code").str(), "ok");
        assert_eq!(e.at("want"), e.at("got"), "got is the stored value");
    }
    assert_eq!(r.result("pl2W").at("got").num(), 115.0, "firmware resolves to the recorded ceiling");
    assert_eq!(
        compact(&sb.state_file("boot.json")),
        r#"{"version":1,"apply":{"profile":"quiet","governor":"powersave","epp":"power","turbo":"0","max_perf_pct":"100","pl1_w":"45","pl2_w":"firmware"},"chargeLimit":null}"#
    );
    assert_eq!(before.diff(&sb.snapshot()), vec!["state/boot.json".to_string()], "not one kernel knob was written");
}

#[test]
fn set_boot_refuses_what_apply_would_refuse_and_stores_nothing() {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    let before = sb.snapshot();
    for args in [
        vec!["set-boot", "profile=custom"],
        vec!["set-boot", "profile=quiet", "epp=nonsense"],
        vec!["set-boot", "governor=performance", "epp=power"],
        vec!["set-boot", "pl1_w=500"],
        vec!["set-boot", "pl1_w=40", "pl2_w=30"],
        vec!["set-boot", "turbo=7"],
        vec!["set-boot", "chargeLimit=80"],
        vec!["set-boot", "profile=quiet", "profile=balanced"],
    ] {
        let r = sb.run(&args);
        r.expect(2);
        assert!(!r.ok(), "{args:?}");
        assert_untouched(&before, &sb.snapshot());
    }
}

#[test]
fn set_boot_keeps_the_stored_charge_limit_and_an_empty_one_clears_only_the_arguments() {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    sb.run(&["set-charge-limit", "80"]).expect(0);
    sb.run(&["set-boot", "profile=quiet"]).expect(0);
    assert_eq!(compact(&sb.state_file("boot.json")), r#"{"version":1,"apply":{"profile":"quiet"},"chargeLimit":80}"#);
    sb.run(&["set-boot"]).expect(0);
    assert_eq!(compact(&sb.state_file("boot.json")), r#"{"version":1,"apply":{},"chargeLimit":80}"#);
    sb.run(&["set-charge-limit", "100"]).expect(0);
    assert_eq!(
        compact(&sb.state_file("boot.json")),
        r#"{"version":1,"apply":{},"chargeLimit":100}"#,
        "set-charge-limit keeps the arguments too"
    );
}

#[test]
fn caps_in_a_boot_set_need_the_recorded_ceiling_like_apply() {
    let sb = Sandbox::new("n6506mv_618lts");
    let r = sb.run(&["set-boot", "pl1_w=40"]);
    r.expect(2);
    assert_eq!(r.code_of("pl1W"), "absent");
    assert!(!sb.has_state("boot.json"));
}

// ---------------------------------------------------------------- boot-apply

#[test]
fn boot_apply_records_the_firmwares_caps_once_per_boot() {
    let sb = Sandbox::new("n6506mv_618lts");
    let r = sb.run(&["boot-apply"]);
    r.expect(0);
    assert!(r.results().is_empty(), "no boot set exists yet: it only records the caps");
    let recorded = sb.state_file("firmware_caps.json");
    assert_eq!(
        compact(&recorded),
        format!(r#"{{"bootId":"{BOOT_A}","msr":{{"pl1W":65,"pl2W":115}},"mmio":{{"pl1W":45,"pl2W":115}}}}"#)
    );
    assert!(sb.status().status().at("boot.applied").bool());
    assert_eq!(sb.state_json("boot_applied.json").at("ok"), &V::Bool(true));

    // something lowers the limits in this boot; a second boot-apply must not record THAT
    sb.run(&["apply", "pl1_w=30", "pl2_w=60"]).expect(0);
    sb.boot_apply();
    assert_eq!(sb.state_file("firmware_caps.json"), recorded, "a later run in the same boot never re-records");
    let s = sb.status();
    assert_eq!(s.status().at("limits.capCeilW.pl1").num(), 45.0, "the ceiling stays the firmware's");
    assert_eq!(s.status().at("values.caps.pl1W").num(), 30.0);

    // a new boot: the firmware's limits are back, and this boot gets its own record
    sb.set(&format!("{MSR}/constraint_0_power_limit_uw"), "65000000");
    sb.set(&format!("{MSR}/constraint_1_power_limit_uw"), "115000000");
    sb.set(&format!("{MMIO}/constraint_0_power_limit_uw"), "45000000");
    sb.set(&format!("{MMIO}/constraint_1_power_limit_uw"), "115000000");
    sb.new_boot(BOOT_B);
    assert!(sb.status().status().at("limits.capCeilW").is_null(), "the old record is not this boot's");
    sb.boot_apply();
    assert_eq!(sb.state_json("firmware_caps.json").at("bootId").str(), BOOT_B);
    assert_eq!(sb.status().status().at("limits.capCeilW.pl1").num(), 45.0);
}

#[test]
fn boot_apply_applies_the_stored_boot_set_and_the_stored_charge_limit() {
    for fixture in ["n6506mv_618lts", "n6506mv_72"] {
        boot_set_round_trip(fixture);
    }
}

fn boot_set_round_trip(fixture: &str) {
    let first = Sandbox::new(fixture).with_caps();
    first.run(&FULL).expect(0);
    first.run(&["set-charge-limit", "80"]).expect(0);
    let stored = first.state_file("boot.json");

    // the next boot: the firmware is back to its own values, the helper's state persisted
    let sb = Sandbox::new(fixture);
    fs::write(sb.state().join("boot.json"), &stored).unwrap();
    sb.new_boot(BOOT_B);
    let before = sb.snapshot();
    let r = sb.run(&["boot-apply"]);
    r.expect(0);
    let names: Vec<&str> = r.results().iter().map(|e| e.at("knob").str()).collect();
    assert_eq!(names, ["profile", "governor", "epp", "turbo", "maxPerfPct", "pl1W", "pl2W", "chargeLimit"]);
    assert!(r.results().iter().all(|e| e.at("ok").bool()), "{}", r.stdout);
    assert_eq!(sb.read(PROFILE), "quiet");
    assert_eq!(sb.read("devices/system/cpu/cpufreq/policy9/energy_performance_preference"), "power");
    assert_eq!(sb.read("devices/system/cpu/intel_pstate/no_turbo"), "1");
    assert_eq!(sb.read(BAT), "80");
    assert_eq!(
        sb.read(&format!("{MSR}/constraint_0_power_limit_uw")),
        "45000000",
        "the MSR zone is lowered from 65 W to the ceiling"
    );
    assert_eq!(sb.read(&format!("{MMIO}/constraint_1_power_limit_uw")), "115000000");
    // the record was taken BEFORE the boot set lowered anything
    assert_eq!(sb.state_json("firmware_caps.json").at("msr.pl1W").num(), 65.0);
    assert!(sb.status().status().at("boot.applied").bool());
    let changed = before.diff(&sb.snapshot());
    assert!(
        changed.contains(&"state/firmware_caps.json".to_string())
            && changed.contains(&"state/boot_applied.json".to_string())
    );
    assert!(!changed.iter().any(|p| p.contains("constraint_2")), "PL4 untouched: {changed:?}");
}

#[test]
fn boot_apply_skips_a_stored_value_the_kernel_no_longer_accepts_and_applies_the_rest() {
    let sb = Sandbox::new("n6506mv_618lts");
    fs::write(
        sb.state().join("boot.json"),
        r#"{"version":1,"apply":{"profile":"turbo","turbo":"0","epp":"power"},"chargeLimit":80}"#,
    )
    .unwrap();
    let r = sb.run(&["boot-apply"]);
    r.expect(1);
    assert_eq!(r.code_of("profile"), "refused");
    assert_eq!(r.code_of("turbo"), "ok");
    assert_eq!(r.code_of("epp"), "ok");
    assert_eq!(r.code_of("chargeLimit"), "ok");
    assert_eq!(sb.read(PROFILE), "balanced", "the refused one is left alone");
    assert_eq!(sb.read("devices/system/cpu/intel_pstate/no_turbo"), "1");
    assert_eq!(sb.read(BAT), "80");
    assert_eq!(sb.state_json("boot_applied.json").at("ok"), &V::Bool(false));
    assert!(!sb.status().status().at("boot.applied").bool(), "not everything landed");
}

#[test]
fn boot_apply_retries_for_a_knob_that_is_not_registered_yet() {
    let sb = Sandbox::new("n6506mv_618lts");
    fs::write(sb.state().join("boot.json"), r#"{"version":1,"apply":{"max_perf_pct":"60"},"chargeLimit":null}"#)
        .unwrap();
    let hidden = sb.sys("devices/system/cpu/intel_pstate/max_perf_pct");
    let min = sb.sys("devices/system/cpu/intel_pstate/min_perf_pct");
    fs::remove_file(&hidden).unwrap();
    let child = sb.spawn(&["boot-apply"], &[]);
    std::thread::sleep(Duration::from_millis(250));
    fs::write(&hidden, "100\n").unwrap();
    let r = wait_for(child, 20);
    assert!(min.exists());
    r.expect(0);
    assert_eq!(r.code_of("maxPerfPct"), "ok");
    assert_eq!(sb.read("devices/system/cpu/intel_pstate/max_perf_pct"), "60");
}

#[test]
fn boot_apply_gives_up_on_a_knob_that_never_appears_after_a_bounded_wait() {
    let sb = Sandbox::new("n6506mv_618lts");
    fs::write(
        sb.state().join("boot.json"),
        r#"{"version":1,"apply":{"max_perf_pct":"60","turbo":"0"},"chargeLimit":null}"#,
    )
    .unwrap();
    fs::remove_file(sb.sys("devices/system/cpu/intel_pstate/max_perf_pct")).unwrap();
    let start = Instant::now();
    let r = sb.run(&["boot-apply"]);
    r.expect(1);
    assert!(start.elapsed() >= Duration::from_millis(700), "it waited for the knob");
    assert!(start.elapsed() < Duration::from_secs(10), "the wait is bounded");
    assert_eq!(r.code_of("maxPerfPct"), "absent");
    assert_eq!(r.code_of("turbo"), "ok", "the others still land");
}

#[test]
fn boot_apply_with_a_corrupt_boot_file_still_records_the_caps_and_says_so() {
    let sb = Sandbox::new("n6506mv_618lts");
    fs::write(sb.state().join("boot.json"), "garbage").unwrap();
    let r = sb.run(&["boot-apply"]);
    r.expect(1);
    assert!(r.why().contains("not understood"), "{}", r.why());
    assert!(sb.has_state("firmware_caps.json"));
    assert_eq!(sb.state_json("boot_applied.json").at("ok"), &V::Bool(false));
    assert_eq!(
        fs::read_to_string(sb.state().join("boot.json")).unwrap(),
        "garbage",
        "the helper never overwrites a file it does not understand"
    );
}

#[test]
fn boot_apply_needs_a_boot_id() {
    let sb = Sandbox::new("n6506mv_618lts");
    fs::remove_file(sb.proc_("sys/kernel/random/boot_id")).unwrap();
    let before = sb.snapshot();
    let r = sb.run(&["boot-apply"]);
    r.expect(3);
    assert_untouched(&before, &sb.snapshot());
}

// ---------------------------------------------------------------- record-caps (what install.sh runs)

const RECORD_A: &str =
    r#"{"bootId":"aaaaaaaa-0000-4000-8000-000000000001","msr":{"pl1W":65,"pl2W":115},"mmio":{"pl1W":45,"pl2W":115}}"#;

#[test]
fn record_caps_records_the_firmwares_limits_once_per_boot_and_writes_nothing_else() {
    let sb = Sandbox::new("n6506mv_618lts");
    let before = sb.snapshot();
    let r = sb.run(&["record-caps"]);
    r.expect(0);
    assert!(r.ok());
    assert!(r.results().is_empty(), "no knob is involved");
    assert_eq!(r.why(), "");
    assert_eq!(compact(&sb.state_file("firmware_caps.json")), RECORD_A);
    assert_eq!(
        before.diff(&sb.snapshot()),
        vec!["state/firmware_caps.json".to_string()],
        "NOTHING else: no kernel knob, no boot mark, no boot.json"
    );
    assert!(!sb.has_state("boot_applied.json") && !sb.has_state("boot.json"));
    let s = r.status();
    assert!(s.at("features.caps").bool(), "caps are writable once the limits are on record");
    assert_eq!(s.at("limits.capCeilW.pl1").num(), 45.0);
    assert_eq!(s.at("limits.capCeilW.pl2").num(), 115.0);
    assert!(!s.at("boot.applied").bool(), "record-caps is not boot-apply: the boot set has not been applied");

    // a second run in the same boot records nothing, said in words
    let recorded = sb.state_file("firmware_caps.json");
    let again = sb.snapshot();
    let r = sb.run(&["record-caps"]);
    r.expect(0);
    assert!(r.why().contains("already on record"), "{}", r.why());
    assert_untouched(&again, &sb.snapshot());

    // ... and never records what something lowered
    sb.run(&["apply", "pl1_w=30", "pl2_w=60"]).expect(0);
    sb.run(&["record-caps"]).expect(0);
    assert_eq!(sb.state_file("firmware_caps.json"), recorded);
    assert_eq!(sb.status().status().at("limits.capCeilW.pl1").num(), 45.0, "the ceiling stays the firmware's");

    // a new boot is a new record (the firmware's values are back)
    for (zone, a, b) in [(MSR, "65000000", "115000000"), (MMIO, "45000000", "115000000")] {
        sb.set(&format!("{zone}/constraint_0_power_limit_uw"), a);
        sb.set(&format!("{zone}/constraint_1_power_limit_uw"), b);
    }
    sb.new_boot(BOOT_B);
    sb.run(&["record-caps"]).expect(0);
    assert_eq!(sb.state_json("firmware_caps.json").at("bootId").str(), BOOT_B);
    assert!(!sb.has_state("boot_applied.json"));
}

#[test]
fn a_reinstall_in_the_middle_of_a_session_does_not_reapply_the_boot_set() {
    // The state a re-install meets: a boot set (and a charge limit) already stored, the user's live profile
    // something else, and this boot's caps not on record. record-caps must record and touch nothing else;
    // boot-apply on the same state is what changes the live profile (that is silicon-boot's job, at boot).
    let seed = |sb: &Sandbox| {
        fs::write(
            sb.state().join("boot.json"),
            r#"{"version":1,"apply":{"profile":"quiet","epp":"power","turbo":"0","max_perf_pct":"60"},"chargeLimit":80}"#,
        )
        .unwrap();
        sb.set(PROFILE, "performance"); // the user's live profile
        sb.set("devices/system/cpu/intel_pstate/no_turbo", "0");
    };
    let sb = Sandbox::new("n6506mv_618lts");
    seed(&sb);
    let before = sb.snapshot();
    let r = sb.run(&["record-caps"]);
    r.expect(0);
    assert_eq!(
        before.diff(&sb.snapshot()),
        vec!["state/firmware_caps.json".to_string()],
        "only the record: the profile, EPP, turbo, max_perf_pct and the charge limit are all as the user left them"
    );
    assert_eq!(sb.read(PROFILE), "performance");
    assert_eq!(sb.read(BAT), "100");
    assert_eq!(sb.read("devices/system/cpu/cpufreq/policy5/energy_performance_preference"), "balance_power");
    assert!(r.status().at("features.caps").bool());

    // the same state under boot-apply: it DOES apply the boot set (so the installer must not run it)
    let twin = Sandbox::new("n6506mv_618lts");
    seed(&twin);
    twin.run(&["boot-apply"]).expect(0);
    assert_eq!(twin.read(PROFILE), "quiet");
    assert_eq!(twin.read(BAT), "80");
    assert_eq!(twin.read("devices/system/cpu/cpufreq/policy5/energy_performance_preference"), "power");
    // ... and both record the very same thing: one piece of code behind both
    assert_eq!(sb.state_file("firmware_caps.json"), twin.state_file("firmware_caps.json"));
}

#[test]
fn record_caps_with_no_zone_records_nothing_and_is_no_error() {
    let sb = Sandbox::new("synth_base");
    sb.remove("class/powercap/intel-rapl:0");
    sb.remove("class/powercap/intel-rapl-mmio:0");
    let before = sb.snapshot();
    let r = sb.run(&["record-caps"]);
    r.expect(0);
    assert!(r.why().contains("no RAPL package zone"), "{}", r.why());
    assert_untouched(&before, &sb.snapshot());
    assert!(!sb.has_state("firmware_caps.json"));
    assert!(!r.status().at("features.caps").bool());
}

#[test]
fn record_caps_replaces_a_record_it_cannot_read_and_says_so() {
    // The record is derived data (the firmware's own values), so a corrupt one is simply taken again.
    let sb = Sandbox::new("n6506mv_618lts");
    fs::write(sb.state().join("firmware_caps.json"), "{ torn").unwrap();
    let r = sb.run(&["record-caps"]);
    r.expect(0);
    assert!(r.stderr.contains("not understood"), "{}", r.stderr);
    assert_eq!(compact(&sb.state_file("firmware_caps.json")), RECORD_A);
    // the old shape of this file, in microwatts, is not understood either: it is replaced, not guessed at
    fs::write(
        sb.state().join("firmware_caps.json"),
        format!(r#"{{"bootId":"{BOOT_A}","msr":{{"pl1Uw":65000000,"pl2Uw":115000000}},"mmio":null}}"#),
    )
    .unwrap();
    sb.run(&["record-caps"]).expect(0);
    assert_eq!(compact(&sb.state_file("firmware_caps.json")), RECORD_A);
}

#[test]
fn record_caps_needs_a_boot_id_takes_no_arguments_and_is_never_a_pkexec_command() {
    let sb = Sandbox::new("n6506mv_618lts");
    let before = sb.snapshot();
    sb.run(&["record-caps", "now"]).expect(2);
    sb.run(&["record-caps", "boot=1"]).expect(2);
    sb.run_env(&["record-caps"], &[("PKEXEC_UID", "1000")]).expect(2);
    assert_untouched(&before, &sb.snapshot());
    assert!(!sb.state().join(".lock").exists(), "refused before the state directory is looked at");
    fs::remove_file(sb.proc_("sys/kernel/random/boot_id")).unwrap();
    let without_id = sb.snapshot();
    let r = sb.run(&["record-caps"]);
    r.expect(3);
    assert_untouched(&without_id, &sb.snapshot());
}

#[test]
fn record_caps_and_boot_apply_share_the_same_faults() {
    // a record that cannot be written is exit 1 with a why -- in both commands
    let sb = Sandbox::new("n6506mv_618lts");
    fs::create_dir(sb.state().join(".firmware_caps.json.tmp")).unwrap(); // a directory where the temp file goes
    let r = sb.run(&["record-caps"]);
    r.expect(1);
    assert!(r.why().contains("could not be recorded"), "{}", r.why());
    assert!(!sb.has_state("firmware_caps.json"));
    let r = sb.run(&["boot-apply"]);
    r.expect(1);
    assert!(r.why().contains("could not be recorded"), "{}", r.why());
}

// ---------------------------------------------------------------- the one lock

#[test]
fn a_helper_waits_for_the_lock_instead_of_interleaving_with_the_holder() {
    let sb = Sandbox::new("n6506mv_618lts");
    sb.run(&["set-charge-limit", "100"]).expect(0); // creates the lock file
    let lock = sb.state().join(".lock");
    let mut holder = Command::new("flock").arg(&lock).args(["sleep", "1.5"]).spawn().expect("flock(1) from util-linux");
    std::thread::sleep(Duration::from_millis(300));
    let start = Instant::now();
    let r = sb.run(&["apply", "turbo=0"]);
    let waited = start.elapsed();
    holder.wait().unwrap();
    r.expect(0);
    assert!(waited >= Duration::from_millis(900), "apply must have waited for the holder, waited {waited:?}");
}

#[test]
fn concurrent_applies_never_leave_the_policies_mixed() {
    let sb = Sandbox::new("n6506mv_618lts");
    let children: Vec<_> =
        (0..14).map(|i| sb.spawn(&["apply", if i % 2 == 0 { "epp=power" } else { "epp=performance" }], &[])).collect();
    for c in children {
        wait_for(c, 30).expect(0);
    }
    let s = sb.status();
    let epp = s.status().at("values.epp").str();
    assert!(epp == "power" || epp == "performance", "every policy holds the same value, got {epp}");
}
