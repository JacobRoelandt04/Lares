//! Machines that are not this one: a hand-made tree numbered differently from the capture
//! (`synth_base`) and mutations of it and of the captures -- a kernel that renames, drops or
//! adds a knob. A knob that is not there is a feature that is false, never an error and
//! never a guess; one the kernel adds to a list is offered because it is the kernel's.

mod common;
use common::*;
use std::fs;

const CLASS_PROFILE: &str = "devices/platform/synth-wmi/platform-profile/platform-profile-1/profile";
const LEGACY_PROFILE: &str = "firmware/acpi/platform_profile";
const MSR: &str = "devices/virtual/powercap/intel-rapl/intel-rapl:0";
const MMIO: &str = "devices/virtual/powercap/intel-rapl-mmio/intel-rapl-mmio:0";
const BAT: &str = "devices/platform/synth-battery/power_supply/BAT1/charge_control_end_threshold";
const NO_TURBO: &str = "devices/system/cpu/intel_pstate/no_turbo";

fn synth() -> Sandbox {
    Sandbox::new("synth_base")
}

fn epp(n: u32) -> String {
    format!("devices/system/cpu/cpufreq/policy{n}/energy_performance_preference")
}

fn gov(n: u32) -> String {
    format!("devices/system/cpu/cpufreq/policy{n}/scaling_governor")
}

#[test]
fn synth_base_is_read_by_what_is_there_not_by_what_the_capture_had() {
    let sb = synth();
    let r = sb.status();
    r.expect(0);
    let s = r.status();
    for f in ["profile", "epp", "turbo", "governor", "maxPerfPct", "chargeLimit", "mux"] {
        assert!(s.at(&format!("features.{f}")).bool(), "{f}");
    }
    assert!(!s.at("features.caps").bool());
    assert_eq!(
        s.at("lists.profiles").strs(),
        ["low-power", "balanced", "performance"],
        "hyphenated names pass through"
    );
    assert_eq!(s.at("values.profile").str(), "balanced");
    assert_eq!(s.at("values.epp").str(), "balance_performance");
    assert_eq!(s.at("limits.maxPerfPct.min").num(), 20.0, "min_perf_pct is read, not assumed");
    assert_eq!(s.at("values.caps.zones.msr.pl1W").num(), 30.0);
    assert_eq!(s.at("values.caps.zones.mmio.pl1W").num(), 25.0);
    assert_eq!(s.at("values.caps.pl1W").num(), 25.0);
    assert_eq!(s.at("values.caps.pl2W").num(), 90.0);
    assert_eq!(s.at("values.chargeLimit").num(), 100.0);
    assert_eq!(s.at("paths.battery").str(), sb.sys("class/power_supply/BAT1").display().to_string());
    assert_eq!(s.at("paths.ac").str(), sb.sys("class/power_supply/ADP1").display().to_string());
    assert_eq!(s.at("paths.coretemp").str(), sb.sys("class/hwmon/hwmon2").display().to_string());
    assert_eq!(
        s.at("paths.rc6").str(),
        sb.sys("class/drm/card0/gt/gt0/rc6_residency_ms").display().to_string(),
        "the i915 card is card0 here"
    );
    assert_eq!(s.at("paths.dgpu.pci").str(), "0000:01:00.0", "the 3D controller, not its audio function");
    assert_eq!(s.at("paths.dgpu.card").str(), sb.dev("dri/card1").display().to_string());
    assert_eq!(s.at("paths.dgpu.render").str(), sb.dev("dri/renderD129").display().to_string());
    assert_eq!(s.at("paths.dgpu.nvidia").str(), sb.dev("nvidia0").display().to_string());
    assert_eq!(s.at("mux.wiringNow").str(), "hybrid", "the Intel card's eDP is connected");
    assert_eq!(s.at("mux.stored").str(), "hybrid");
}

#[test]
fn synth_base_applies_end_to_end_with_its_own_ceiling() {
    let sb = synth().with_caps();
    assert_eq!(sb.state_json("firmware_caps.json").at("msr.pl1W").num(), 30.0);
    let s = sb.status();
    assert_eq!(s.status().at("limits.capCeilW.pl1").num(), 25.0, "the lower zone");
    let r = sb.run(&["apply", "profile=low-power", "epp=power", "turbo=0", "max_perf_pct=20", "pl1_w=25", "pl2_w=60"]);
    r.expect(0);
    assert_eq!(sb.read(CLASS_PROFILE), "low-power");
    assert_eq!(sb.read(LEGACY_PROFILE), "balanced", "the class handler is written, the legacy file is only read");
    for n in [0, 1, 3, 7] {
        assert_eq!(sb.read(&epp(n)), "power");
    }
    assert_eq!(sb.read(&format!("{MSR}/constraint_0_power_limit_uw")), "25000000");
    assert_eq!(sb.read(&format!("{MMIO}/constraint_1_power_limit_uw")), "60000000");
    assert_eq!(sb.read(&format!("{MSR}/constraint_2_power_limit_uw")), "150000000");
    let r = sb.run(&["apply", "pl1_w=26"]);
    r.expect(2);
    assert!(r.result("pl1W").at("why").str().contains("above the firmware's 25 W"));
    let r = sb.run(&["apply", "max_perf_pct=19"]);
    r.expect(2);
    assert!(r.result("maxPerfPct").at("why").str().contains("between 20 and 100"));
}

#[test]
fn a_class_only_profile_control_is_written_through_the_class() {
    let sb = synth();
    sb.remove(LEGACY_PROFILE);
    sb.remove("firmware/acpi/platform_profile_choices");
    let r = sb.status();
    assert_eq!(r.status().at("values.profile").str(), "balanced");
    assert_eq!(r.status().at("lists.profiles").strs(), ["low-power", "balanced", "performance"]);
    sb.run(&["apply", "profile=performance"]).expect(0);
    assert_eq!(sb.read(CLASS_PROFILE), "performance");
}

#[test]
fn a_legacy_only_profile_control_is_written_through_the_legacy_file() {
    let sb = synth();
    sb.remove("class/platform-profile");
    sb.remove("devices/platform/synth-wmi");
    sb.set("firmware/acpi/platform_profile_choices", "quiet balanced balanced-performance performance custom");
    let r = sb.status();
    assert_eq!(
        r.status().at("lists.profiles").strs(),
        ["quiet", "balanced", "balanced-performance", "performance"],
        "custom is stripped"
    );
    sb.run(&["apply", "profile=balanced-performance"]).expect(0);
    assert_eq!(sb.read(LEGACY_PROFILE), "balanced-performance");
    sb.run(&["apply", "profile=custom"]).expect(2);
    sb.run(&["apply", "profile=low-power"]).expect(2);
}

#[test]
fn two_profile_handlers_are_written_together_and_a_mix_reads_as_custom() {
    let sb = synth();
    let other = "devices/platform/other-wmi/platform-profile/platform-profile-2";
    sb.set(&format!("{other}/name"), "other-wmi");
    sb.set(&format!("{other}/choices"), "balanced performance custom");
    sb.set(&format!("{other}/profile"), "performance");
    std::os::unix::fs::symlink(
        "../../devices/platform/other-wmi/platform-profile/platform-profile-2",
        sb.sys("class/platform-profile/platform-profile-2"),
    )
    .unwrap();
    let r = sb.status();
    assert_eq!(r.status().at("values.profile").str(), "custom", "the handlers disagree");
    assert_eq!(r.status().at("lists.profiles").strs(), ["balanced", "performance"], "what BOTH offer, minus custom");

    let before = sb.snapshot();
    let r = sb.run(&["apply", "profile=custom"]);
    r.expect(2);
    assert_untouched(&before, &sb.snapshot());
    let r = sb.run(&["apply", "profile=low-power"]);
    r.expect(2);
    assert!(r.result("profile").at("why").str().contains("balanced, performance"));
    assert_untouched(&before, &sb.snapshot());

    let r = sb.run(&["apply", "profile=balanced"]);
    r.expect(0);
    assert_eq!(sb.read(CLASS_PROFILE), "balanced");
    assert_eq!(sb.read(&format!("{other}/profile")), "balanced");
    assert_eq!(r.status().at("values.profile").str(), "balanced");
}

#[test]
fn a_passive_pstate_has_no_epp_and_offers_the_kernels_governors() {
    let sb = synth();
    for n in [0, 1, 3, 7] {
        sb.remove(&epp(n));
        sb.remove(&format!("devices/system/cpu/cpufreq/policy{n}/energy_performance_available_preferences"));
        sb.set(
            &format!("devices/system/cpu/cpufreq/policy{n}/scaling_available_governors"),
            "conservative ondemand userspace powersave performance schedutil",
        );
    }
    sb.set("devices/system/cpu/intel_pstate/status", "passive");
    let r = sb.status();
    let s = r.status();
    assert!(!s.at("features.epp").bool());
    assert!(s.at("values.epp").is_null());
    assert!(s.at("lists.epps").arr().is_empty());
    assert!(!s.at("limits.eppLocked").bool());
    assert_eq!(
        s.at("lists.governors").strs(),
        ["conservative", "ondemand", "userspace", "powersave", "performance", "schedutil"],
        "the kernel's order"
    );
    let before = sb.snapshot();
    let r = sb.run(&["apply", "epp=power"]);
    r.expect(2);
    assert_eq!(r.code_of("epp"), "absent");
    assert_untouched(&before, &sb.snapshot());
    sb.run(&["apply", "governor=schedutil"]).expect(0);
    assert_eq!(sb.read(&gov(7)), "schedutil");
}

#[test]
fn a_kernel_without_no_turbo_has_no_turbo_feature() {
    let sb = synth();
    sb.remove(NO_TURBO);
    let r = sb.status();
    assert!(!r.status().at("features.turbo").bool());
    assert!(r.status().at("values.turbo").is_null());
    let before = sb.snapshot();
    let r = sb.run(&["apply", "turbo=0"]);
    r.expect(2);
    assert_eq!(r.code_of("turbo"), "absent");
    assert_untouched(&before, &sb.snapshot());
    // an unreadable value is not a guess either
    sb.set(NO_TURBO, "7");
    assert!(!sb.status().status().at("features.turbo").bool());
}

#[test]
fn a_performance_governor_locks_the_epp_and_a_mix_is_named_mixed() {
    let sb = synth().with_caps();
    for n in [0, 1, 3, 7] {
        sb.set(&gov(n), "performance");
    }
    let r = sb.status();
    assert_eq!(r.status().at("values.governor").str(), "performance");
    assert!(r.status().at("limits.eppLocked").bool());
    let before = sb.snapshot();
    let r = sb.run(&["apply", "epp=power"]);
    r.expect(2);
    assert_eq!(r.code_of("epp"), "locked");
    assert_untouched(&before, &sb.snapshot());
    sb.run(&["apply", "governor=powersave", "epp=power"]).expect(0);
    assert_eq!(sb.read(&epp(3)), "power");

    sb.set(&gov(1), "performance");
    let r = sb.status();
    assert_eq!(r.status().at("values.governor").str(), "mixed");
    assert!(r.status().at("limits.eppLocked").bool(), "one policy on performance is enough to fix its EPP");
    sb.set(&epp(1), "balance_power");
    assert_eq!(sb.status().status().at("values.epp").str(), "mixed");
}

#[test]
fn msr_only_rapl_records_and_writes_one_zone() {
    let sb = synth();
    sb.remove("class/powercap/intel-rapl-mmio:0");
    sb.remove("devices/virtual/powercap/intel-rapl-mmio");
    let r = sb.status();
    assert_eq!(r.status().at("values.caps.zones.msr.pl1W").num(), 30.0);
    assert!(r.status().at("values.caps.zones.mmio").is_null(), "an absent zone is null");
    assert_eq!(r.status().at("values.caps.pl1W").num(), 30.0);
    sb.boot_apply();
    let rec = sb.state_json("firmware_caps.json");
    assert_eq!(rec.at("msr.pl1W").num(), 30.0);
    assert!(rec.at("mmio").is_null());
    assert_eq!(sb.status().status().at("limits.capCeilW.pl1").num(), 30.0);
    sb.run(&["apply", "pl1_w=20", "pl2_w=60"]).expect(0);
    assert_eq!(sb.read(&format!("{MSR}/constraint_0_power_limit_uw")), "20000000");
}

#[test]
fn mmio_only_rapl_works_too() {
    let sb = synth();
    sb.remove("class/powercap/intel-rapl:0");
    sb.remove("devices/virtual/powercap/intel-rapl");
    sb.boot_apply();
    let rec = sb.state_json("firmware_caps.json");
    assert!(rec.at("msr").is_null());
    assert_eq!(rec.at("mmio.pl1W").num(), 25.0);
    sb.run(&["apply", "pl1_w=22"]).expect(0);
    assert_eq!(sb.read(&format!("{MMIO}/constraint_0_power_limit_uw")), "22000000");
}

#[test]
fn locked_rapl_files_fail_as_io_not_as_a_panic() {
    let sb = synth().with_caps();
    for zone in [MSR, MMIO] {
        for c in ["constraint_0_power_limit_uw", "constraint_1_power_limit_uw"] {
            sb.chmod(&format!("{zone}/{c}"), 0o444);
        }
    }
    let r = sb.run(&["apply", "turbo=0", "pl1_w=20", "pl2_w=60"]);
    r.expect(1);
    assert_eq!(r.code_of("turbo"), "ok");
    assert_eq!(r.code_of("pl1W"), "io");
    assert_eq!(r.code_of("pl2W"), "io");
    assert!(r.result("pl1W").at("why").str().contains("Permission denied"), "{}", r.stdout);
    assert_eq!(r.result("pl1W").at("got").num(), 25.0, "got is what the kernel holds");
    assert_eq!(sb.read(&format!("{MSR}/constraint_0_power_limit_uw")), "30000000");
}

#[test]
fn a_machine_without_a_mux_or_a_charge_limit_has_those_features_false() {
    let sb = synth();
    sb.remove("devices/platform/asus-nb-wmi");
    sb.remove(BAT);
    let r = sb.status();
    r.expect(0);
    let s = r.status();
    assert!(!s.at("features.mux").bool());
    assert!(!s.at("features.chargeLimit").bool());
    assert!(s.at("values.muxStored").is_null());
    assert!(s.at("values.chargeLimit").is_null());
    assert!(s.at("mux.stored").is_null());
    assert!(s.at("features.profile").bool(), "everything else is unaffected");
    let before = sb.snapshot();
    let r = sb.run(&["set-charge-limit", "80"]);
    r.expect(2);
    assert_eq!(r.code_of("chargeLimit"), "absent");
    sb.run(&["mux-request", "dgpu"]).expect(2);
    assert_untouched(&before, &sb.snapshot());
}

#[test]
fn a_profile_choice_the_kernel_adds_is_offered_because_it_is_the_kernels() {
    let sb = synth();
    for f in [
        "devices/platform/synth-wmi/platform-profile/platform-profile-1/choices",
        "firmware/acpi/platform_profile_choices",
    ] {
        sb.set(f, "low-power balanced turbo-nitro ../x performance custom");
    }
    let r = sb.status();
    assert_eq!(
        r.status().at("lists.profiles").strs(),
        ["low-power", "balanced", "turbo-nitro", "performance"],
        "an odd word is dropped, custom is stripped"
    );
    let r = sb.run(&["apply", "profile=turbo-nitro"]);
    r.expect(0);
    assert_eq!(sb.read(CLASS_PROFILE), "turbo-nitro");
    sb.run(&["apply", "profile=../x"]).expect(2);
}

#[test]
fn a_renamed_constraint_makes_caps_false_even_with_a_record() {
    let sb = synth().with_caps();
    assert!(sb.status().status().at("features.caps").bool());
    for zone in [MSR, MMIO] {
        sb.set(&format!("{zone}/constraint_0_name"), "pl1_sustained");
    }
    let r = sb.status();
    assert!(!r.status().at("features.caps").bool(), "no constraint named long_term: no PL1 to find");
    assert!(r.status().at("values.caps").is_null());
    let before = sb.snapshot();
    let r = sb.run(&["apply", "pl1_w=20"]);
    r.expect(2);
    assert_eq!(r.code_of("pl1W"), "absent");
    assert_untouched(&before, &sb.snapshot());
}

#[test]
fn constraints_are_found_by_name_not_by_index() {
    let sb = synth();
    for (zone, long, short) in [(MSR, 30_000_000u64, 90_000_000u64), (MMIO, 25_000_000, 90_000_000)] {
        sb.set(&format!("{zone}/constraint_0_name"), "short_term");
        sb.set(&format!("{zone}/constraint_0_power_limit_uw"), &short.to_string());
        sb.set(&format!("{zone}/constraint_1_name"), "long_term");
        sb.set(&format!("{zone}/constraint_1_power_limit_uw"), &long.to_string());
    }
    let r = sb.status();
    assert_eq!(r.status().at("values.caps.zones.msr.pl1W").num(), 30.0, "PL1 is the one NAMED long_term");
    assert_eq!(r.status().at("values.caps.zones.msr.pl2W").num(), 90.0);
    sb.boot_apply();
    sb.run(&["apply", "pl1_w=20", "pl2_w=60"]).expect(0);
    assert_eq!(
        sb.read(&format!("{MSR}/constraint_1_power_limit_uw")),
        "20000000",
        "PL1 went to the constraint named long_term"
    );
    assert_eq!(sb.read(&format!("{MSR}/constraint_0_power_limit_uw")), "60000000");
    assert_eq!(sb.read(&format!("{MSR}/constraint_2_power_limit_uw")), "150000000", "PL4 is never written");
}

#[test]
fn pl4_can_never_be_taken_for_pl1_even_when_it_is_named_so() {
    let sb = synth();
    for zone in [MSR, MMIO] {
        sb.set(&format!("{zone}/constraint_0_name"), "peak_power");
        sb.set(&format!("{zone}/constraint_2_name"), "long_term");
    }
    let r = sb.status();
    assert!(
        r.status().at("values.caps").is_null(),
        "constraint_2 is outside the whitelist: the zone is not offered at all"
    );
    let sb2 = sb;
    sb2.boot_apply();
    let before = sb2.snapshot();
    let r = sb2.run(&["apply", "pl1_w=20", "pl2_w=60"]);
    r.expect(2);
    assert_eq!(r.code_of("pl1W"), "absent");
    assert_untouched(&before, &sb2.snapshot());
    assert_eq!(sb2.read(&format!("{MSR}/constraint_2_power_limit_uw")), "150000000");
}

#[test]
fn two_constraints_with_the_same_name_make_the_zone_ambiguous_and_unused() {
    let sb = synth();
    sb.set(&format!("{MSR}/constraint_1_name"), "long_term");
    let r = sb.status();
    assert!(r.status().at("values.caps.zones.msr").is_null());
    assert_eq!(r.status().at("values.caps.zones.mmio.pl1W").num(), 25.0, "the other zone is fine");
}

#[test]
fn a_power_supply_that_is_not_a_battery_has_no_charge_limit() {
    let sb = synth();
    sb.set("devices/platform/synth-battery/power_supply/BAT1/type", "Mains");
    assert!(!sb.status().status().at("features.chargeLimit").bool());
    let before = sb.snapshot();
    sb.run(&["set-charge-limit", "80"]).expect(2);
    assert_untouched(&before, &sb.snapshot());
    // a first BAT0 that is not a battery is skipped; BAT1 is found by its type
    sb.set("devices/platform/synth-battery/power_supply/BAT1/type", "Battery");
    sb.set("devices/platform/junk/power_supply/BAT0/type", "Unknown");
    sb.set("devices/platform/junk/power_supply/BAT0/charge_control_end_threshold", "100");
    std::os::unix::fs::symlink("../../devices/platform/junk/power_supply/BAT0", sb.sys("class/power_supply/BAT0"))
        .unwrap();
    let r = sb.status();
    assert_eq!(r.status().at("paths.battery").str(), sb.sys("class/power_supply/BAT1").display().to_string());
    sb.run(&["set-charge-limit", "80"]).expect(0);
    assert_eq!(sb.read(BAT), "80");
    assert_eq!(sb.read("devices/platform/junk/power_supply/BAT0/charge_control_end_threshold"), "100");
}

#[test]
fn a_missing_dgpu_or_coretemp_or_cpufreq_is_null_not_an_error() {
    let sb = synth();
    sb.remove("bus/pci/devices/0000:01:00.0");
    sb.remove("bus/pci/devices/0000:01:00.1");
    sb.remove("devices/platform/coretemp.0");
    sb.remove("class/hwmon/hwmon2");
    sb.remove("devices/system/cpu/cpufreq");
    let r = sb.status();
    r.expect(0);
    let s = r.status();
    assert!(s.at("paths.dgpu").is_null());
    assert!(s.at("paths.coretemp").is_null());
    assert!(s.at("paths.cpufreq").is_null());
    assert!(!s.at("features.governor").bool());
    assert!(!s.at("features.epp").bool());
    assert!(s.at("features.turbo").bool(), "intel_pstate is a different directory");
}

#[test]
fn an_empty_sysfs_is_a_machine_with_no_features_and_no_error() {
    let sb = synth();
    fs::remove_dir_all(sb.sys("")).unwrap();
    fs::create_dir_all(sb.sys("")).unwrap();
    let r = sb.status();
    r.expect(0);
    assert!(r.ok());
    let s = r.status();
    for f in ["profile", "epp", "turbo", "governor", "maxPerfPct", "caps", "chargeLimit", "mux"] {
        assert!(!s.at(&format!("features.{f}")).bool(), "{f}");
    }
    for v in ["profile", "epp", "turbo", "governor", "maxPerfPct", "caps", "chargeLimit", "muxStored"] {
        assert!(s.at(&format!("values.{v}")).is_null(), "{v}");
    }
    assert!(
        s.at("lists.profiles").arr().is_empty()
            && s.at("lists.epps").arr().is_empty()
            && s.at("lists.governors").arr().is_empty()
    );
    assert!(s.at("limits.maxPerfPct").is_null());
    for p in ["dgpu", "battery", "ac", "coretemp", "rc6", "cpufreq"] {
        assert!(s.at(&format!("paths.{p}")).is_null(), "{p}");
    }
    assert!(s.at("mux.wiringNow").is_null());
    for args in [
        vec!["apply", "profile=quiet"],
        vec!["apply", "turbo=0"],
        vec!["apply", "governor=powersave"],
        vec!["apply", "epp=power"],
        vec!["apply", "max_perf_pct=60"],
    ] {
        let r = sb.run(&args);
        r.expect(2);
        assert_eq!(r.results().len(), 1);
        assert_eq!(r.results()[0].at("code").str(), "absent", "{args:?}");
    }
}

#[test]
fn odd_file_contents_never_panic_and_never_become_a_value() {
    let sb = synth();
    // invalid UTF-8, a NUL, and an oversized list
    fs::write(sb.sys(&gov(0)), b"power\xff\xfesave\0\n").unwrap();
    fs::write(sb.sys("devices/system/cpu/cpufreq/policy1/scaling_available_governors"), vec![b'x'; 200_000]).unwrap();
    fs::write(sb.sys("devices/system/cpu/intel_pstate/max_perf_pct"), b"\xff\xff").unwrap();
    sb.set(&format!("{MSR}/constraint_0_power_limit_uw"), "-5");
    sb.set(&format!("{MMIO}/constraint_1_power_limit_uw"), "0x10");
    let r = sb.status();
    r.expect(0);
    assert!(r.ok());
    assert!(!r.status().at("features.maxPerfPct").bool(), "not a number: not a feature");
    assert!(
        r.status().at("values.caps").is_null(),
        "a limit that is not a number drops its zone, and with both gone there are no caps"
    );
    let r = sb.run(&["apply", "max_perf_pct=60"]);
    r.expect(2);
}

#[test]
fn fractional_watts_are_reported_as_they_are() {
    let sb = synth();
    sb.set(&format!("{MSR}/constraint_0_power_limit_uw"), "30500000");
    sb.set(&format!("{MMIO}/constraint_0_power_limit_uw"), "25125000");
    let r = sb.status();
    assert_eq!(r.status().at("values.caps.zones.msr.pl1W").num(), 30.5);
    assert_eq!(r.status().at("values.caps.pl1W").num(), 25.125);
    assert!(r.stdout.contains("\"pl1W\":30.5") && r.stdout.contains("\"pl1W\":25.125"), "{}", r.stdout);
}

#[test]
fn a_policy_that_lacks_the_epp_is_skipped_by_the_epp_and_not_by_the_governor() {
    let sb = synth();
    sb.remove(&epp(3));
    sb.remove("devices/system/cpu/cpufreq/policy3/energy_performance_available_preferences");
    let r = sb.run(&["apply", "epp=power", "governor=performance"]);
    r.expect(2); // governor performance locks the epp
    sb.run(&["apply", "epp=power"]).expect(0);
    assert_eq!(sb.read(&epp(0)), "power");
    assert!(!sb.sys(&epp(3)).exists(), "never created");
    sb.run(&["apply", "governor=performance"]).expect(0);
    assert_eq!(sb.read(&gov(3)), "performance");
}

#[test]
fn the_helper_never_creates_a_file_that_a_kernel_did_not_offer() {
    let sb = synth().with_caps();
    let before = sb.snapshot();
    sb.run(&["apply", "profile=performance", "epp=power", "turbo=0", "max_perf_pct=50", "pl1_w=20", "pl2_w=60"])
        .expect(0);
    sb.run(&["set-charge-limit", "80"]).expect(0);
    let after = sb.snapshot();
    let added: Vec<_> = before.0.keys().filter(|k| !after.0.contains_key(*k)).collect();
    assert!(added.is_empty(), "files removed: {added:?}");
    let created: Vec<_> = after.0.keys().filter(|k| !before.0.contains_key(*k) && !k.starts_with("state/")).collect();
    assert!(created.is_empty(), "files created: {created:?}");
}

#[test]
fn what_policies_disagree_about_is_not_offered() {
    let sb = synth();
    // policy 1 has no balance_performance and no performance governor: only what EVERY policy offers is offered
    sb.set(
        "devices/system/cpu/cpufreq/policy1/energy_performance_available_preferences",
        "default performance balance_power power",
    );
    sb.set("devices/system/cpu/cpufreq/policy1/scaling_available_governors", "powersave");
    let r = sb.status();
    assert_eq!(
        r.status().at("lists.epps").strs(),
        ["performance", "balance_power", "power"],
        "the first policy's order, minus what policy 1 lacks"
    );
    assert_eq!(r.status().at("lists.governors").strs(), ["powersave"]);
    let before = sb.snapshot();
    let r = sb.run(&["apply", "epp=balance_performance"]);
    r.expect(2);
    assert!(r.result("epp").at("why").str().contains("performance, balance_power, power"), "{}", r.stdout);
    assert_untouched(&before, &sb.snapshot());
    sb.run(&["apply", "governor=performance"]).expect(2);
    assert_untouched(&before, &sb.snapshot());
    sb.run(&["apply", "epp=balance_power"]).expect(0);
}
