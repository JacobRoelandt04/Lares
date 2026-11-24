//! `apply` against copies of the real capture: the round trip, what each knob writes (and
//! nothing else), validation, ordering, read-back and the injected faults.

mod common;
use common::*;

const PROFILE: &str = "devices/platform/asus-nb-wmi/platform-profile/platform-profile-0/profile";
const NO_TURBO: &str = "devices/system/cpu/intel_pstate/no_turbo";
const MAX_PERF: &str = "devices/system/cpu/intel_pstate/max_perf_pct";
const MSR: &str = "devices/virtual/powercap/intel-rapl/intel-rapl:0";
const MMIO: &str = "devices/virtual/powercap/intel-rapl-mmio/intel-rapl-mmio:0";

fn policies() -> Vec<u32> {
    (0..22).collect()
}

fn epp(n: u32) -> String {
    format!("devices/system/cpu/cpufreq/policy{n}/energy_performance_preference")
}

fn gov(n: u32) -> String {
    format!("devices/system/cpu/cpufreq/policy{n}/scaling_governor")
}

fn sorted(mut v: Vec<String>) -> Vec<String> {
    v.sort();
    v
}

fn under_root(rel: &[String]) -> Vec<String> {
    sorted(rel.iter().map(|r| format!("root/sys/{r}")).collect())
}

#[test]
fn a_full_apply_writes_exactly_the_expected_files_and_reads_each_back() {
    for fixture in ["n6506mv_618lts", "n6506mv_72"] {
        full_apply(fixture);
    }
}

fn full_apply(fixture: &str) {
    let sb = Sandbox::new(fixture).with_caps();
    let before = sb.snapshot();
    let r =
        sb.run(&["apply", "profile=performance", "epp=power", "turbo=0", "max_perf_pct=80", "pl1_w=40", "pl2_w=100"]);
    r.expect(0);
    assert!(r.ok());
    let names: Vec<&str> = r.results().iter().map(|e| e.at("knob").str()).collect();
    assert_eq!(names, ["profile", "epp", "turbo", "maxPerfPct", "pl1W", "pl2W"], "results come in the apply order");
    for e in r.results() {
        assert_eq!(e.keys(), ["knob", "want", "got", "ok", "code", "why"]);
        assert!(e.at("ok").bool());
        assert_eq!(e.at("code").str(), "ok");
        assert_eq!(e.at("why").str(), "");
        assert_eq!(e.at("want"), e.at("got"), "{}", e.at("knob").str());
    }
    assert_eq!(r.result("profile").at("got").str(), "performance");
    assert_eq!(r.result("turbo").at("got"), &V::Bool(false));
    assert_eq!(r.result("maxPerfPct").at("got").num(), 80.0);
    assert_eq!(r.result("pl1W").at("got").num(), 40.0);
    assert_eq!(r.result("pl2W").at("got").num(), 100.0);

    // the files, and ONLY the files
    let mut expected: Vec<String> = vec![PROFILE.into(), NO_TURBO.into(), MAX_PERF.into()];
    expected.extend(policies().into_iter().map(epp));
    for zone in [MSR, MMIO] {
        expected.push(format!("{zone}/constraint_0_power_limit_uw"));
        expected.push(format!("{zone}/constraint_1_power_limit_uw"));
    }
    assert_eq!(before.diff(&sb.snapshot()), under_root(&expected));
    assert_eq!(sb.read(PROFILE), "performance");
    assert_eq!(sb.read(NO_TURBO), "1", "turbo off is no_turbo 1");
    assert_eq!(sb.read(MAX_PERF), "80");
    assert_eq!(sb.read(&epp(0)), "power");
    assert_eq!(sb.read(&epp(21)), "power");
    for zone in [MSR, MMIO] {
        assert_eq!(sb.read(&format!("{zone}/constraint_0_power_limit_uw")), "40000000");
        assert_eq!(sb.read(&format!("{zone}/constraint_1_power_limit_uw")), "100000000");
        assert_eq!(sb.read(&format!("{zone}/constraint_2_power_limit_uw")), "217000000", "PL4 is never touched");
    }
    assert_ne!(
        sb.read("firmware/acpi/platform_profile"),
        "performance",
        "only the class handler is written when there is one"
    );

    // the status in the answer is the status after the writes
    let s = r.status();
    assert_eq!(s.at("values.profile").str(), "performance");
    assert_eq!(s.at("values.epp").str(), "power");
    assert_eq!(s.at("values.turbo"), &V::Bool(false));
    assert_eq!(s.at("values.maxPerfPct").num(), 80.0);
    assert_eq!(s.at("values.caps.pl1W").num(), 40.0);
    assert_eq!(s.at("values.caps.zones.msr.pl2W").num(), 100.0);
    assert_eq!(s.at("limits.capCeilW.pl1").num(), 45.0, "the ceiling is the firmware's, not the new value");

    // governor next: all 22 policies, and EPP becomes fixed
    let g = sb.run(&["apply", "governor=performance"]);
    g.expect(0);
    assert_eq!(g.result("governor").at("got").str(), "performance");
    assert!(g.status().at("limits.eppLocked").bool());
    assert_eq!(sb.read(&gov(0)), "performance");
    assert_eq!(sb.read(&gov(21)), "performance");
}

#[test]
fn a_partial_apply_touches_only_its_knob_and_an_empty_one_nothing() {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    let before = sb.snapshot();
    let r = sb.run(&["apply"]);
    r.expect(0);
    assert!(r.ok());
    assert!(r.results().is_empty());
    assert_untouched(&before, &sb.snapshot());

    let r = sb.run(&["apply", "turbo=0"]);
    r.expect(0);
    assert_eq!(before.diff(&sb.snapshot()), under_root(&[NO_TURBO.to_string()]));
    let r = sb.run(&["apply", "turbo=1"]);
    r.expect(0);
    assert_eq!(sb.read(NO_TURBO), "0");
    assert_eq!(r.result("turbo").at("got"), &V::Bool(true));
}

#[test]
fn caps_accept_firmware_and_write_the_recorded_ceiling_to_every_zone() {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    let r = sb.run(&["apply", "pl1_w=20", "pl2_w=30"]);
    r.expect(0);
    let r = sb.run(&["apply", "pl1_w=firmware", "pl2_w=firmware"]);
    r.expect(0);
    assert_eq!(r.result("pl1W").at("want").num(), 45.0);
    assert_eq!(r.result("pl2W").at("got").num(), 115.0);
    for zone in [MSR, MMIO] {
        assert_eq!(sb.read(&format!("{zone}/constraint_0_power_limit_uw")), "45000000");
        assert_eq!(sb.read(&format!("{zone}/constraint_1_power_limit_uw")), "115000000");
    }
}

#[test]
fn lowering_and_raising_both_caps_in_one_call_works_either_way() {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    sb.run(&["apply", "pl1_w=20", "pl2_w=30"]).expect(0);
    // raising PL1 past the old PL2 (the helper writes PL2 first so PL1 <= PL2 always holds)
    let up = sb.run(&["apply", "pl1_w=45", "pl2_w=115"]);
    up.expect(0);
    assert_eq!(up.result("pl1W").at("got").num(), 45.0);
    assert_eq!(up.result("pl2W").at("got").num(), 115.0);
    sb.run(&["apply", "pl1_w=10", "pl2_w=12"]).expect(0);
    assert_eq!(sb.read(&format!("{MMIO}/constraint_0_power_limit_uw")), "10000000");
    assert_eq!(sb.read(&format!("{MMIO}/constraint_1_power_limit_uw")), "12000000");
}

fn refused(sb: &Sandbox, args: &[&str], knob: &str, code: &str, why_has: &str) {
    let before = sb.snapshot();
    let mut full = vec!["apply"];
    full.extend_from_slice(args);
    let r = sb.run(&full);
    assert_eq!(r.code, 2, "{args:?}: {}", r.stdout);
    assert!(!r.ok());
    assert_eq!(r.code_of(knob), code, "{args:?}: {}", r.stdout);
    let why = r.result(knob).at("why").str();
    assert!(why.contains(why_has), "{args:?}: why '{why}' should mention '{why_has}'");
    assert!(r.result(knob).at("got").is_null(), "a refused knob has no got");
    assert_untouched(&before, &sb.snapshot());
}

#[test]
fn values_outside_the_kernels_lists_or_the_ranges_are_refused_and_write_nothing() {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    refused(&sb, &["profile=turbo"], "profile", "refused", "quiet, balanced, performance");
    refused(&sb, &["profile=custom"], "profile", "refused", "custom");
    refused(&sb, &["profile="], "profile", "refused", "not a profile");
    refused(&sb, &["profile=Quiet"], "profile", "refused", "not a profile");
    refused(&sb, &["governor=schedutil"], "governor", "refused", "performance, powersave");
    refused(&sb, &["epp=default"], "epp", "refused", "alias");
    refused(&sb, &["epp=turbo"], "epp", "refused", "performance, balance_performance, balance_power, power");
    refused(&sb, &["turbo=2"], "turbo", "refused", "0 or 1");
    refused(&sb, &["turbo="], "turbo", "refused", "0 or 1");
    refused(&sb, &["turbo=true"], "turbo", "refused", "0 or 1");
    refused(&sb, &["max_perf_pct=49"], "maxPerfPct", "refused", "between 50 and 100");
    refused(&sb, &["max_perf_pct=101"], "maxPerfPct", "refused", "between 50 and 100");
    refused(&sb, &["max_perf_pct=abc"], "maxPerfPct", "refused", "whole number");
    refused(&sb, &["max_perf_pct=-1"], "maxPerfPct", "refused", "whole number");
    refused(&sb, &["max_perf_pct=8e1"], "maxPerfPct", "refused", "whole number");
    refused(&sb, &["max_perf_pct=0100"], "maxPerfPct", "refused", "whole number");
    refused(&sb, &["pl1_w=46"], "pl1W", "refused", "above the firmware's 45 W");
    refused(&sb, &["pl2_w=116"], "pl2W", "refused", "above the firmware's 115 W");
    refused(&sb, &["pl1_w=7"], "pl1W", "refused", "below the 8 W floor");
    refused(&sb, &["pl2_w=0"], "pl2W", "refused", "below the 8 W floor");
    refused(&sb, &["pl1_w=4.5"], "pl1W", "refused", "below the 8 W floor");
    refused(&sb, &["pl1_w=45.001"], "pl1W", "refused", "above the firmware's 45 W");
    for bad in ["4.", ".5", "4.1234", "abc", "-5", "Firmware", "99999", "045", "4,5", "1e1", "40W"] {
        let arg = format!("pl1_w={bad}");
        refused(&sb, &[arg.as_str()], "pl1W", "refused", "number of watts");
    }
}

#[test]
fn caps_may_have_a_decimal_and_are_checked_and_read_back_exactly() {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    let r = sb.run(&["apply", "pl1_w=40.5", "pl2_w=100.125"]);
    r.expect(0);
    assert_eq!(r.result("pl1W").at("want").num(), 40.5);
    assert_eq!(r.result("pl1W").at("got").num(), 40.5);
    assert_eq!(r.result("pl2W").at("got").num(), 100.125);
    assert!(r.stdout.contains("\"got\":40.5") && r.stdout.contains("\"got\":100.125"), "{}", r.stdout);
    assert_eq!(sb.read(&format!("{MSR}/constraint_0_power_limit_uw")), "40500000");
    assert_eq!(sb.read(&format!("{MMIO}/constraint_1_power_limit_uw")), "100125000");
    // the ceiling is exact too
    refused(&sb, &["pl1_w=45.001"], "pl1W", "refused", "above the firmware's 45 W");
    sb.run(&["apply", "pl1_w=45.000"]).expect(0);
}

#[test]
fn pl1_above_pl2_is_refused_whichever_way_it_comes_about() {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    refused(&sb, &["pl1_w=40", "pl2_w=30"], "pl1W", "refused", "PL1 (40 W) would be above PL2 (30 W)");
    refused(&sb, &["pl2_w=30"], "pl2W", "refused", "PL1 (65 W) would be above PL2 (30 W) on the msr zone");
    // with PL2 lowered first, a PL1 above it is refused too
    sb.run(&["apply", "pl1_w=20", "pl2_w=30"]).expect(0);
    refused(&sb, &["pl1_w=35"], "pl1W", "refused", "PL1 (35 W) would be above PL2 (30 W)");
}

#[test]
fn one_refusal_refuses_the_whole_call_and_the_valid_knobs_are_not_written() {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    let before = sb.snapshot();
    let r = sb.run(&["apply", "profile=quiet", "turbo=0", "epp=nonsense"]);
    r.expect(2);
    assert_eq!(r.code_of("epp"), "refused");
    assert_eq!(r.code_of("profile"), "refused");
    assert!(r.result("profile").at("why").str().contains("epp was refused"), "{}", r.stdout);
    assert_eq!(r.result("turbo").at("want"), &V::Bool(false));
    assert!(r.results().iter().all(|e| !e.at("ok").bool()));
    assert_untouched(&before, &sb.snapshot());
}

#[test]
fn epp_is_locked_while_the_resulting_governor_is_performance() {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    let before = sb.snapshot();
    let r = sb.run(&["apply", "governor=performance", "epp=power"]);
    r.expect(2);
    assert_eq!(r.code_of("epp"), "locked");
    assert!(r.result("epp").at("why").str().contains("governor is performance"));
    assert_eq!(r.code_of("governor"), "refused", "the valid governor change is not written either");
    assert_untouched(&before, &sb.snapshot());

    sb.run(&["apply", "governor=performance"]).expect(0);
    let before = sb.snapshot();
    let r = sb.run(&["apply", "epp=power"]);
    r.expect(2);
    assert_eq!(r.code_of("epp"), "locked");
    assert_untouched(&before, &sb.snapshot());

    // leaving performance in the same call lifts the lock: governor is written first
    let r = sb.run(&["apply", "epp=power", "governor=powersave"]);
    r.expect(0);
    assert_eq!(sb.read(&gov(5)), "powersave");
    assert_eq!(sb.read(&epp(5)), "power");
}

#[test]
fn usage_errors_are_refused_with_a_why_and_no_results() {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    for args in [
        vec!["apply", "profile"],
        vec!["apply", "colour=blue"],
        vec!["apply", "profile=quiet", "profile=balanced"],
        vec!["apply", "chargeLimit=80"],
        vec!["apply", "--bogus"],
        vec!["frobnicate"],
        vec![],
    ] {
        let before = sb.snapshot();
        let r = sb.run(&args);
        r.expect(2);
        assert!(!r.ok());
        assert!(!r.why().is_empty(), "{args:?}");
        assert_untouched(&before, &sb.snapshot());
    }
}

#[test]
fn a_write_command_without_test_options_is_refused_before_it_can_touch_anything() {
    // Only argument-less (or invalid-valued) forms are run here without --sysfs-root, so that even a
    // helper that lost this refusal could not write the real machine from this test.
    let sb = Sandbox::new("n6506mv_618lts");
    let before = sb.snapshot();
    for cmd in [
        vec!["apply"],
        vec!["set-boot"],
        vec!["mux-cancel"],
        vec!["mux-confirm"],
        vec!["mux-prompt-shown"],
        vec!["set-charge-limit", "7"],
        vec!["mux-request", "nope"],
    ] {
        let r = sb.run_raw(&cmd, &[]);
        r.expect(2);
        if cmd.first() != Some(&"mux-request") {
            assert!(r.why().contains("pkexec"), "{cmd:?}: {}", r.why());
        }
    }
    // test mode needs BOTH roots a write touches
    let root = sb.root().display().to_string();
    let r = sb.run_raw(&["apply", "--sysfs-root", &root], &[]);
    r.expect(2);
    assert!(r.why().contains("--state-dir"), "{}", r.why());
    let state = sb.state().display().to_string();
    let r = sb.run_raw(&["apply", "--state-dir", &state], &[]);
    r.expect(2);
    assert!(r.why().contains("--sysfs-root"), "{}", r.why());
    assert_untouched(&before, &sb.snapshot());
}

#[test]
fn caps_without_a_recorded_ceiling_are_not_writable() {
    let sb = Sandbox::new("n6506mv_618lts");
    let before = sb.snapshot();
    let r = sb.run(&["apply", "pl1_w=40"]);
    r.expect(2);
    assert_eq!(r.code_of("pl1W"), "absent");
    assert!(r.result("pl1W").at("why").str().contains("not on record for this boot"));
    assert_untouched(&before, &sb.snapshot());
    // a record from ANOTHER boot is no record
    sb.boot_apply();
    sb.new_boot(BOOT_B);
    let before = sb.snapshot();
    let r = sb.run(&["apply", "pl1_w=40"]);
    r.expect(2);
    assert_eq!(r.code_of("pl1W"), "absent");
    assert!(!r.status().at("features.caps").bool());
    assert!(r.status().at("limits.capCeilW").is_null());
    assert_untouched(&before, &sb.snapshot());
}

// ---------------------------------------------------------------- faults

fn faulted(faults: &str, args: &[&str]) -> (Sandbox, Run) {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    let mut full = vec!["apply"];
    full.extend_from_slice(args);
    let r = sb.run_env(&full, &[("SILICON_TEST_FAULTS", faults)]);
    (sb, r)
}

#[test]
fn an_eio_write_is_io_and_does_not_stop_the_later_knobs() {
    let (sb, r) = faulted("profile:eio", &["profile=quiet", "turbo=0"]);
    r.expect(1);
    assert!(!r.ok());
    assert_eq!(r.code_of("profile"), "io");
    assert!(r.result("profile").at("why").str().contains("Input/output error"), "{}", r.stdout);
    assert_eq!(r.result("profile").at("got").str(), "balanced", "got is what the kernel holds");
    assert_eq!(r.code_of("turbo"), "ok", "a failed write does not stop the later knobs");
    assert_eq!(sb.read(PROFILE), "balanced");
    assert_eq!(sb.read(NO_TURBO), "1");
}

#[test]
fn an_ignored_write_reads_back_wrong_and_is_a_mismatch() {
    let (sb, r) = faulted("epp:ignore", &["epp=power"]);
    r.expect(1);
    assert_eq!(r.code_of("epp"), "mismatch");
    assert_eq!(r.result("epp").at("got").str(), "balance_power", "the value did not change");
    assert!(r.result("epp").at("why").str().contains("kept other values"), "{}", r.stdout);
    assert_eq!(sb.read(&epp(3)), "balance_power");
}

#[test]
fn a_clamped_write_reports_what_the_kernel_stored() {
    let (sb, r) = faulted("pl1W:clamp:35", &["pl1_w=40"]);
    r.expect(1);
    assert_eq!(r.code_of("pl1W"), "mismatch");
    assert_eq!(r.result("pl1W").at("want").num(), 40.0);
    assert_eq!(r.result("pl1W").at("got").num(), 35.0, "the lower zone value");
    assert_eq!(sb.read(&format!("{MSR}/constraint_0_power_limit_uw")), "35000000");

    let (_, r) = faulted("maxPerfPct:clamp:90", &["max_perf_pct=70"]);
    r.expect(1);
    assert_eq!(r.code_of("maxPerfPct"), "mismatch");
    assert_eq!(r.result("maxPerfPct").at("got").num(), 90.0);

    let (_, r) = faulted("governor:clamp:powersave", &["governor=performance"]);
    r.expect(1);
    assert_eq!(r.code_of("governor"), "mismatch");
    assert_eq!(r.result("governor").at("got").str(), "powersave");
}

#[test]
fn a_fault_on_one_knob_leaves_every_other_knob_alone() {
    let (sb, r) = faulted("turbo:eio,pl2W:ignore", &["profile=quiet", "turbo=0", "pl1_w=30", "pl2_w=60"]);
    r.expect(1);
    assert_eq!(r.code_of("profile"), "ok");
    assert_eq!(r.code_of("turbo"), "io");
    assert_eq!(r.code_of("pl1W"), "ok");
    assert_eq!(r.code_of("pl2W"), "mismatch");
    assert_eq!(sb.read(PROFILE), "quiet");
    assert_eq!(sb.read(&format!("{MMIO}/constraint_0_power_limit_uw")), "30000000");
    assert_eq!(sb.read(&format!("{MMIO}/constraint_1_power_limit_uw")), "115000000");
}

#[test]
fn every_answer_is_one_line_of_valid_json_even_with_hostile_text_around() {
    // a policy whose governor reads back with quotes and a backslash must be escaped, not break the line
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    sb.set(&gov(0), "pow\"er\\sa\tve");
    let r = sb.status();
    r.expect(0);
    assert_eq!(r.status().at("values.governor").str(), "mixed");
    assert_eq!(r.stdout.matches('\n').count(), 1);
}
