//! The ARMs: things that must be refused (exit 2) with nothing written. Each one arms a
//! fault the helper is built to refuse, and the sandbox is compared byte for byte before and
//! after (every file's content and mode, every link's target, every directory entry).
//! The "test root as root" ARM is a unit test inside the crate (src/cli.rs): it simulates
//! euid 0 by passing it in, never by being root.

mod common;
use common::*;
use std::fs;
use std::os::unix::fs::symlink;

const MSR: &str = "devices/virtual/powercap/intel-rapl/intel-rapl:0";
const MMIO: &str = "devices/virtual/powercap/intel-rapl-mmio/intel-rapl-mmio:0";
const BAT: &str =
    "devices/LNXSYSTM:00/LNXSYBUS:00/PNP0A08:00/PNP0C0A:03/power_supply/BAT0/charge_control_end_threshold";
const MUX: &str = "devices/platform/asus-nb-wmi/gpu_mux_mode";

/// Run `args`, expect exit 2 and a byte-identical sandbox.
fn refused_and_untouched(sb: &Sandbox, args: &[&str]) -> Run {
    let before = sb.snapshot();
    let r = sb.run(args);
    assert_eq!(r.code, 2, "{args:?} must be refused: {}", r.stdout);
    assert!(!r.ok());
    assert_untouched(&before, &sb.snapshot());
    r
}

#[test]
fn arm_a_path_outside_the_whitelist_is_refused_before_it_is_opened() {
    // (the knob's file, the call that would write it, what the decoy must hold to look like a
    // value of that knob, a non-whitelisted file of the tree with such a value, a whitelisted
    // file of ANOTHER knob with such a value) -- every link reads as a plausible value, so it
    // is the whitelist, not the reader, that has to stop the write
    struct Case(&'static str, &'static [&'static str], &'static str, &'static str, &'static str);
    let cases = [
        Case(
            "devices/system/cpu/cpufreq/policy4/scaling_governor",
            &["apply", "governor=performance"],
            "powersave",
            "devices/system/cpu/intel_pstate/status",
            "devices/system/cpu/cpufreq/policy4/energy_performance_preference",
        ),
        Case(
            "devices/system/cpu/cpufreq/policy4/energy_performance_preference",
            &["apply", "epp=power"],
            "balance_power",
            "devices/system/cpu/cpufreq/policy4/scaling_max_freq",
            "devices/system/cpu/cpufreq/policy4/scaling_governor",
        ),
        Case(
            "devices/system/cpu/intel_pstate/no_turbo",
            &["apply", "turbo=1"],
            "0",
            "devices/system/cpu/intel_pstate/hwp_dynamic_boost",
            MUX,
        ),
        Case(
            "devices/system/cpu/intel_pstate/max_perf_pct",
            &["apply", "max_perf_pct=60"],
            "100",
            "devices/system/cpu/intel_pstate/min_perf_pct",
            BAT,
        ),
        Case(
            "devices/platform/asus-nb-wmi/platform-profile/platform-profile-0/profile",
            &["apply", "profile=quiet"],
            "balanced",
            "devices/platform/asus-nb-wmi/platform-profile/platform-profile-0/name",
            "devices/system/cpu/cpufreq/policy0/scaling_governor",
        ),
        Case(
            "devices/virtual/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw",
            &["apply", "pl1_w=40"],
            "45000000",
            "devices/virtual/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_max_power_uw",
            "devices/system/cpu/intel_pstate/max_perf_pct",
        ),
        Case(
            BAT,
            &["set-charge-limit", "80"],
            "100",
            "devices/LNXSYSTM:00/LNXSYBUS:00/PNP0A08:00/PNP0C0A:03/power_supply/BAT0/capacity",
            "devices/system/cpu/intel_pstate/max_perf_pct",
        ),
    ];
    for Case(file, call, plausible, in_tree, other_knob) in cases {
        for kind in ["outside", "in_tree", "other_knob"] {
            let sb = Sandbox::new("n6506mv_618lts").with_caps();
            let decoy = sb.dir.join("decoy");
            fs::write(&decoy, format!("{plausible}\n")).unwrap();
            let link_to = match kind {
                "outside" => decoy.clone(),
                "in_tree" => sb.sys(in_tree),
                _ => sb.sys(other_knob),
            };
            let victim = sb.sys(file);
            fs::remove_file(&victim).unwrap();
            symlink(&link_to, &victim).unwrap();
            let r = refused_and_untouched(&sb, call);
            let e = r
                .results()
                .iter()
                .find(|e| e.at("code").str() == "refused")
                .unwrap_or_else(|| panic!("{file} -> {kind}: a refused result in {}", r.stdout));
            let why = e.at("why").str();
            assert!(
                why.contains("whitelist") || why.contains("outside /sys") || why.contains("file, not"),
                "{file} -> {kind}: {why}"
            );
            assert_eq!(fs::read_to_string(&decoy).unwrap(), format!("{plausible}\n"), "{file} -> {kind}");
        }
    }
}

#[test]
fn arm_one_bad_policy_link_refuses_the_whole_governor_change() {
    let sb = Sandbox::new("n6506mv_618lts");
    let decoy = sb.dir.join("decoy");
    fs::write(&decoy, "x\n").unwrap();
    let victim = sb.sys("devices/system/cpu/cpufreq/policy21/scaling_governor");
    fs::remove_file(&victim).unwrap();
    symlink(&decoy, &victim).unwrap();
    let r = refused_and_untouched(&sb, &["apply", "governor=performance"]);
    assert_eq!(r.code_of("governor"), "refused");
    assert_eq!(
        sb.read("devices/system/cpu/cpufreq/policy0/scaling_governor"),
        "powersave",
        "the 21 good policies were not written either"
    );
}

#[test]
fn arm_a_directory_or_a_dangling_link_where_a_knob_should_be_is_refused() {
    let sb = Sandbox::new("n6506mv_618lts");
    let f = sb.sys("devices/system/cpu/intel_pstate/no_turbo");
    fs::remove_file(&f).unwrap();
    fs::create_dir(&f).unwrap();
    refused_and_untouched(&sb, &["apply", "turbo=0"]);
    fs::remove_dir(&f).unwrap();
    symlink("/nonexistent/nowhere", &f).unwrap();
    // the knob is not readable now: it is not there (a feature that is false), and nothing is created
    let r = refused_and_untouched(&sb, &["apply", "turbo=0"]);
    assert_eq!(r.code_of("turbo"), "absent");
}

#[test]
fn arm_pl4_is_never_written() {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    // a kernel (or a prankster) that calls PL4 `long_term`, moving the real PL1 to constraint 2's neighbour
    for zone in [MSR, MMIO] {
        for c in ["constraint_0_name", "constraint_2_name"] {
            sb.chmod(&format!("{zone}/{c}"), 0o644);
        }
        sb.set(&format!("{zone}/constraint_0_name"), "peak_power");
        sb.set(&format!("{zone}/constraint_2_name"), "long_term");
    }
    let r = refused_and_untouched(&sb, &["apply", "pl1_w=20"]);
    assert_eq!(r.code_of("pl1W"), "absent");
    let r = refused_and_untouched(&sb, &["apply", "pl1_w=20", "pl2_w=30"]);
    assert_eq!(r.code_of("pl2W"), "absent");
    assert_eq!(sb.read(&format!("{MSR}/constraint_2_power_limit_uw")), "217000000");
    assert_eq!(sb.read(&format!("{MMIO}/constraint_2_power_limit_uw")), "217000000");
}

#[test]
fn arm_charge_limit_90() {
    let sb = Sandbox::new("n6506mv_618lts");
    let r = refused_and_untouched(&sb, &["set-charge-limit", "90"]);
    assert_eq!(r.code_of("chargeLimit"), "refused");
    assert_eq!(sb.read(BAT), "100");
    assert!(!sb.has_state("boot.json"));
}

#[test]
fn arm_epp_while_the_governor_is_performance() {
    let sb = Sandbox::new("n6506mv_618lts");
    for n in 0..22 {
        sb.set(&format!("devices/system/cpu/cpufreq/policy{n}/scaling_governor"), "performance");
    }
    let r = refused_and_untouched(&sb, &["apply", "epp=power"]);
    assert_eq!(r.code_of("epp"), "locked");
    let r = refused_and_untouched(&sb, &["apply", "epp=performance"]);
    assert_eq!(r.code_of("epp"), "locked", "even the value it already has: the knob is fixed");
}

#[test]
fn arm_profile_custom() {
    let sb = Sandbox::new("n6506mv_618lts");
    // the kernel itself lists custom as a choice of the handler
    sb.chmod("devices/platform/asus-nb-wmi/platform-profile/platform-profile-0/choices", 0o644);
    sb.set(
        "devices/platform/asus-nb-wmi/platform-profile/platform-profile-0/choices",
        "quiet balanced performance custom",
    );
    let r = sb.status();
    assert_eq!(r.status().at("lists.profiles").strs(), ["quiet", "balanced", "performance"]);
    let r = refused_and_untouched(&sb, &["apply", "profile=custom"]);
    assert_eq!(r.code_of("profile"), "refused");
}

#[test]
fn arm_caps_above_the_ceiling() {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    refused_and_untouched(&sb, &["apply", "pl1_w=46"]);
    refused_and_untouched(&sb, &["apply", "pl2_w=116"]);
    refused_and_untouched(&sb, &["apply", "pl1_w=66", "pl2_w=116"]);
    refused_and_untouched(&sb, &["apply", "pl1_w=1000"]);
    // 66 W was accepted by the kernel on the real machine (max_power_uw is the TDP, not a ceiling): the helper still refuses it
    assert_eq!(sb.read(&format!("{MSR}/constraint_0_max_power_uw")), "45000000");
}

#[test]
fn arm_caps_below_8_w() {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    refused_and_untouched(&sb, &["apply", "pl1_w=7"]);
    refused_and_untouched(&sb, &["apply", "pl2_w=7"]);
    refused_and_untouched(&sb, &["apply", "pl1_w=0", "pl2_w=0"]);
}

#[test]
fn arm_pl1_above_pl2() {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    refused_and_untouched(&sb, &["apply", "pl1_w=40", "pl2_w=30"]);
    refused_and_untouched(&sb, &["apply", "pl2_w=44"]);
}

#[test]
fn arm_systemd_only_commands_are_refused_under_pkexec() {
    for cmd in ["record-caps", "boot-apply", "mux-apply", "mux-guard"] {
        let sb = Sandbox::new("n6506mv_618lts");
        // a queued request would otherwise be applied, a boot set would otherwise be written
        let before = sb.snapshot();
        let r = sb.run_env(&[cmd], &[("PKEXEC_UID", "1000")]);
        r.expect(2);
        assert!(!r.ok());
        assert!(r.why().contains("systemd only"), "{cmd}: {}", r.why());
        assert!(r.json.at("ok") == &V::Bool(false));
        assert_untouched(&before, &sb.snapshot());
        assert!(!sb.state().join(".lock").exists(), "{cmd}: refused before it even looked at the state directory");
        assert!(!sb.has_state("firmware_caps.json") && !sb.has_state("boot_applied.json"));
        // an EMPTY PKEXEC_UID is still set
        sb.run_env(&[cmd], &[("PKEXEC_UID", "")]).expect(2);
        // and without it the same command is allowed
        assert_ne!(sb.run(&[cmd]).code, 2, "{cmd} runs when systemd (no PKEXEC_UID) starts it");
    }
}

#[test]
fn arm_pkexec_may_still_run_the_ordinary_commands() {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    let r = sb.run_env(&["apply", "turbo=0"], &[("PKEXEC_UID", "1000")]);
    r.expect(0);
    assert_eq!(sb.read("devices/system/cpu/intel_pstate/no_turbo"), "1");
    sb.run_env(&["mux-request", "dgpu"], &[("PKEXEC_UID", "1000")]).expect(0);
}

#[test]
fn arm_hostile_values_never_get_near_a_write() {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    let long = "a".repeat(20_000);
    let hostile = [
        "quiet\nperformance",
        "quiet ",
        " quiet",
        "quiet;rm -rf /",
        "../../../etc/passwd",
        "$(touch /tmp/x)",
        "`id`",
        "quiet\u{7f}",
        "ｑｕｉｅｔ",
        "QUIET",
        "balanced,performance",
        long.as_str(),
    ];
    for v in hostile {
        let arg = format!("profile={v}");
        refused_and_untouched(&sb, &["apply", &arg]);
        let arg = format!("epp={v}");
        refused_and_untouched(&sb, &["apply", &arg]);
        let arg = format!("governor={v}");
        refused_and_untouched(&sb, &["apply", &arg]);
        let arg = format!("pl1_w={v}");
        refused_and_untouched(&sb, &["apply", &arg]);
        let arg = format!("max_perf_pct={v}");
        refused_and_untouched(&sb, &["apply", &arg]);
        refused_and_untouched(&sb, &["set-charge-limit", v]);
        refused_and_untouched(&sb, &["mux-request", v]);
    }
}

#[test]
fn arm_the_mux_write_goes_through_the_whitelist_too() {
    let sb = Sandbox::new("n6506mv_618lts");
    sb.run(&["mux-request", "dgpu"]).expect(0);
    let decoy = sb.dir.join("decoy");
    fs::write(&decoy, "1\n").unwrap();
    let victim = sb.sys(MUX);
    fs::remove_file(&victim).unwrap();
    symlink(&decoy, &victim).unwrap();
    let r = sb.run(&["mux-apply"]);
    // the firmware is not written: the discovery reads the link's target, but the write is refused
    assert_ne!(r.code, 0, "{}", r.stdout);
    assert_eq!(fs::read_to_string(&decoy).unwrap(), "1\n");
    assert_eq!(sb.state_json("mux.json").at("state").str(), "failed");
    assert!(
        sb.state_json("mux.json").at("why").str().contains("whitelist")
            || sb.state_json("mux.json").at("why").str().contains("outside /sys")
    );
}

#[test]
fn arm_the_way_back_goes_through_the_whitelist_too() {
    // The way back waits for no NVIDIA stack and makes no teardown, but it is no less checked: the same
    // door, the same whitelist. A MUX path that is a link to a file that reads as plausibly as the real
    // one (outside /sys, inside it but off the whitelist, or another knob's whitelisted file) is refused,
    // and the target is not written.
    for kind in ["outside", "in_tree", "other_knob"] {
        let sb = Sandbox::new("n6506mv_618lts");
        sb.set(MUX, "0");
        sb.rewire("dgpu");
        sb.run(&["mux-request", "hybrid"]).expect(0);
        let decoy = sb.dir.join("decoy");
        fs::write(&decoy, "0\n").unwrap();
        let link_to = match kind {
            "outside" => decoy.clone(),
            "in_tree" => sb.sys("devices/system/cpu/intel_pstate/hwp_dynamic_boost"),
            _ => sb.sys("devices/system/cpu/intel_pstate/no_turbo"),
        };
        let target_before = fs::read_to_string(&link_to).unwrap();
        let victim = sb.sys(MUX);
        fs::remove_file(&victim).unwrap();
        symlink(&link_to, &victim).unwrap();
        let r = sb.run(&["mux-apply"]);
        assert_ne!(r.code, 0, "{kind}: {}", r.stdout);
        assert_eq!(fs::read_to_string(&link_to).unwrap(), target_before, "{kind}: the decoy was not written");
        let rec = sb.state_json("mux.json");
        assert_eq!(rec.at("state").str(), "failed", "{kind}");
        let why = rec.at("why").str();
        assert!(
            why.contains("whitelist") || why.contains("outside /sys") || why.contains("file, not"),
            "{kind}: {why}"
        );
    }
}

#[test]
fn arm_a_fault_variable_names_only_known_knobs_and_faults() {
    let sb = Sandbox::new("n6506mv_618lts");
    for spec in ["nope:eio", "profile:explode", "profile", "profile:clamp:", "pl1_w:eio"] {
        let before = sb.snapshot();
        let r = sb.run_env(&["apply", "turbo=0"], &[("SILICON_TEST_FAULTS", spec)]);
        r.expect(2);
        assert!(r.why().contains("SILICON_TEST_FAULTS"), "{spec}: {}", r.why());
        assert_untouched(&before, &sb.snapshot());
    }
}
