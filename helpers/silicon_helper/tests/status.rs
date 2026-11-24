//! `status` against the two captures of the real machine: every field of HELPER_PROTOCOL's
//! example, checked against what the fixture says.

mod common;
use common::*;
use std::fs;

fn path(sb: &Sandbox, rel: &str) -> String {
    sb.sys(rel).display().to_string()
}

#[test]
fn status_618lts_matches_the_capture_field_by_field() {
    let sb = Sandbox::new("n6506mv_618lts");
    let before = sb.snapshot();
    let r = sb.status();
    r.expect(0);
    assert!(r.ok());
    assert_eq!(r.json.keys(), ["ok", "proto", "status"]);
    let s = r.status();
    assert_eq!(s.keys(), ["features", "values", "lists", "limits", "paths", "prechecks", "mux", "boot"]);

    // features: all there but caps (the firmware's limits are not on record before boot-apply)
    assert_eq!(
        s.at("features").keys(),
        ["profile", "epp", "turbo", "governor", "maxPerfPct", "caps", "chargeLimit", "mux"]
    );
    for f in ["profile", "epp", "turbo", "governor", "maxPerfPct", "chargeLimit", "mux"] {
        assert!(s.at(&format!("features.{f}")).bool(), "feature {f}");
    }
    assert!(!s.at("features.caps").bool());

    // values, as the capture holds them
    assert_eq!(s.at("values.profile").str(), "balanced");
    assert_eq!(s.at("values.epp").str(), "balance_power", "the same on all 22 policies");
    assert!(s.at("values.turbo").bool(), "no_turbo is 0");
    assert_eq!(s.at("values.governor").str(), "powersave");
    assert_eq!(s.at("values.maxPerfPct").num(), 100.0);
    assert_eq!(s.at("values.caps.pl1W").num(), 45.0, "the lower of 65 and 45");
    assert_eq!(s.at("values.caps.pl2W").num(), 115.0);
    assert_eq!(s.at("values.caps.zones.msr.pl1W").num(), 65.0);
    assert_eq!(s.at("values.caps.zones.msr.pl2W").num(), 115.0);
    assert_eq!(s.at("values.caps.zones.mmio.pl1W").num(), 45.0);
    assert_eq!(s.at("values.caps.zones.mmio.pl2W").num(), 115.0);
    assert_eq!(s.at("values.chargeLimit").num(), 100.0);
    assert_eq!(s.at("values.muxStored").str(), "hybrid");

    // lists: the kernel's own, in its order, minus custom / default
    assert_eq!(s.at("lists.profiles").strs(), ["quiet", "balanced", "performance"]);
    assert_eq!(s.at("lists.epps").strs(), ["performance", "balance_performance", "balance_power", "power"]);
    assert_eq!(s.at("lists.governors").strs(), ["performance", "powersave"]);

    // limits
    assert_eq!(s.at("limits.capFloorW").num(), 8.0);
    assert!(s.at("limits.capCeilW").is_null(), "nothing recorded in this boot yet");
    assert_eq!(s.at("limits.maxPerfPct.min").num(), 50.0, "min_perf_pct of this machine");
    assert_eq!(s.at("limits.maxPerfPct.max").num(), 100.0);
    assert!(!s.at("limits.eppLocked").bool());

    // paths: the real-looking paths under the test roots
    assert_eq!(s.at("paths.dgpu.pci").str(), "0000:01:00.0");
    assert_eq!(s.at("paths.dgpu.card").str(), sb.dev("dri/card0").display().to_string());
    assert_eq!(s.at("paths.dgpu.render").str(), sb.dev("dri/renderD129").display().to_string());
    assert_eq!(s.at("paths.dgpu.nvidia").str(), sb.dev("nvidia0").display().to_string());
    assert_eq!(s.at("paths.dgpu.powerState").str(), path(&sb, "bus/pci/devices/0000:01:00.0/power_state"));
    assert_eq!(s.at("paths.battery").str(), path(&sb, "class/power_supply/BAT0"));
    assert_eq!(s.at("paths.ac").str(), path(&sb, "class/power_supply/AC0"));
    assert_eq!(s.at("paths.coretemp").str(), path(&sb, "class/hwmon/hwmon4"), "the hwmon whose name is coretemp");
    assert_eq!(s.at("paths.rc6").str(), path(&sb, "class/drm/card1/gt/gt0/rc6_residency_ms"), "the i915 card's");
    assert_eq!(s.at("paths.cpufreq").str(), path(&sb, "devices/system/cpu/cpufreq"));
    for p in
        ["dgpu.card", "dgpu.render", "dgpu.nvidia", "dgpu.powerState", "battery", "ac", "coretemp", "rc6", "cpufreq"]
    {
        assert!(std::path::Path::new(s.at(&format!("paths.{p}")).str()).exists(), "{p} must be readable as reported");
    }

    // prechecks, mux, boot
    assert!(s.at("prechecks.mux.ok").bool());
    assert_eq!(s.at("prechecks.mux.why").str(), "");
    assert_eq!(s.at("mux.stored").str(), "hybrid");
    assert_eq!(s.at("mux.wiringNow").str(), "hybrid", "Intel's eDP is connected");
    assert!(s.at("mux.record").is_null());
    assert_eq!(s.at("boot.id").str(), BOOT_A);
    assert!(!s.at("boot.applied").bool());

    assert_untouched(&before, &sb.snapshot());
}

#[test]
fn status_after_boot_apply_has_the_ceiling_and_caps() {
    let sb = Sandbox::new("n6506mv_618lts").with_caps();
    let s = sb.status();
    assert!(s.status().at("features.caps").bool());
    assert_eq!(s.status().at("limits.capCeilW.pl1").num(), 45.0);
    assert_eq!(s.status().at("limits.capCeilW.pl2").num(), 115.0);
    assert!(s.status().at("boot.applied").bool());
}

#[test]
fn status_72_reads_the_armoury_mux_and_everything_else_unchanged() {
    let sb = Sandbox::new("n6506mv_72");
    let r = sb.status();
    r.expect(0);
    let s = r.status();
    assert_eq!(s.at("values.profile").str(), "quiet", "the 7.2 capture was taken in Quiet");
    assert_eq!(s.at("values.epp").str(), "balance_performance", "the boot leaves EPP at the CPU's default");
    assert_eq!(s.at("values.caps.zones.msr.pl1W").num(), 65.0);
    assert_eq!(s.at("values.muxStored").str(), "hybrid");
    assert_eq!(s.at("mux.stored").str(), "hybrid");
    assert!(s.at("features.mux").bool());
    assert_eq!(s.at("lists.epps").strs(), ["performance", "balance_performance", "balance_power", "power"]);
}

#[test]
fn the_mux_reads_the_firmwares_stored_value_and_the_wiring_separately() {
    let sb = Sandbox::new("n6506mv_618lts");
    sb.set("devices/platform/asus-nb-wmi/gpu_mux_mode", "0");
    let s = sb.status();
    assert_eq!(s.status().at("values.muxStored").str(), "dgpu", "what the firmware will do at the next boot");
    assert_eq!(s.status().at("mux.wiringNow").str(), "hybrid", "what the panel is wired as now");
    sb.rewire("dgpu");
    assert_eq!(sb.status().status().at("mux.wiringNow").str(), "dgpu");
    sb.all_edp("disconnected");
    assert!(sb.status().status().at("mux.wiringNow").is_null(), "neither reads: null, never a guess");
    sb.all_edp("connected");
    assert!(sb.status().status().at("mux.wiringNow").is_null(), "both reads: null too");
}

#[test]
fn status_never_writes_and_never_creates_a_state_directory() {
    let sb = Sandbox::new("n6506mv_618lts");
    std::fs::remove_dir_all(sb.state()).unwrap();
    let r = sb.run_raw(
        &[
            "status",
            "--sysfs-root",
            &sb.root().display().to_string(),
            "--proc-root",
            &sb.procroot().display().to_string(),
            "--dev-root",
            &sb.devroot().display().to_string(),
            "--modules-root",
            &sb.modules().display().to_string(),
        ],
        &[],
    );
    r.expect(0);
    assert!(!sb.state().exists(), "status without --state-dir reads state as empty and creates nothing");
    assert!(r.status().at("mux.record").is_null());
}

#[test]
fn options_may_come_before_or_after_the_command_and_in_the_equals_form() {
    let sb = Sandbox::new("n6506mv_618lts");
    let root = sb.root().display().to_string();
    let a = sb.run_raw(&["--sysfs-root", &root, "status"], &[]);
    let b = sb.run_raw(&["status", &format!("--sysfs-root={root}")], &[]);
    a.expect(0);
    b.expect(0);
    assert_eq!(a.status().at("paths.battery"), b.status().at("paths.battery"));
}

#[test]
fn a_missing_sysfs_root_is_an_io_failure_before_anything_else() {
    let sb = Sandbox::new("n6506mv_618lts");
    let gone = sb.dir.join("nope").display().to_string();
    let r = sb.run_raw(&["status", "--sysfs-root", &gone], &[]);
    assert_eq!(r.code, 3);
    assert!(!r.ok());
    assert!(r.why().contains("cannot read"), "{}", r.why());
}

#[test]
fn the_proc_and_dev_roots_may_be_the_directory_holding_proc_or_the_proc_directory_itself() {
    // HELPER_PROTOCOL: `--proc-root <dir>` reads `<dir>/proc/...`. A caller that passes the proc directory itself
    // (`--proc-root <tree>/proc`, as the data layer's probe does) is understood too.
    let sb = Sandbox::new("n6506mv_618lts");
    let (root, state) = (sb.root().display().to_string(), sb.state().display().to_string());
    let holder = sb.run_raw(
        &[
            "status",
            "--sysfs-root",
            &root,
            "--state-dir",
            &state,
            "--proc-root",
            &sb.procroot().display().to_string(),
            "--dev-root",
            &sb.devroot().display().to_string(),
        ],
        &[],
    );
    let itself = sb.run_raw(
        &[
            "status",
            "--sysfs-root",
            &root,
            "--state-dir",
            &state,
            "--proc-root",
            &sb.procroot().join("proc").display().to_string(),
            "--dev-root",
            &sb.devroot().join("dev").display().to_string(),
        ],
        &[],
    );
    holder.expect(0);
    itself.expect(0);
    assert_eq!(holder.status().at("boot.id").str(), BOOT_A);
    assert_eq!(itself.status().at("boot.id").str(), BOOT_A);
    assert_eq!(holder.status().at("paths.dgpu"), itself.status().at("paths.dgpu"));
    assert_eq!(itself.status().at("paths.dgpu.nvidia").str(), sb.dev("nvidia0").display().to_string());
}

#[test]
fn the_dgpus_nodes_are_named_by_sysfs_and_proc_not_looked_for_in_dev() {
    // a /dev that does not have the nodes (a hermetic probe, a container) still gets the names the kernel gives
    let sb = Sandbox::new("n6506mv_618lts");
    for node in ["dri", "nvidia0", "nvidiactl", "nvidia-modeset", "nvidia-uvm"] {
        let p = sb.dev(node);
        let _ = if p.is_dir() { fs::remove_dir_all(&p) } else { fs::remove_file(&p) };
    }
    assert!(sb.devroot().join("dev").is_dir() && !sb.dev("nvidia0").exists());
    let r = sb.status();
    r.expect(0);
    let s = r.status();
    assert_eq!(s.at("paths.dgpu.card").str(), sb.dev("dri/card0").display().to_string());
    assert_eq!(s.at("paths.dgpu.render").str(), sb.dev("dri/renderD129").display().to_string());
    assert_eq!(s.at("paths.dgpu.nvidia").str(), sb.dev("nvidia0").display().to_string());
    // and without the NVIDIA driver's proc entry there is no nvidia node to name
    fs::remove_dir_all(sb.proc_("driver")).unwrap();
    assert!(sb.status().status().at("paths.dgpu.nvidia").is_null());
}
