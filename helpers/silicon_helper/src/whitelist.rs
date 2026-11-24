//! The exact-path whitelist. A path is judged on its CANONICAL form (every symlink already
//! resolved, below the canonical `/sys`), by shape: which directory family, which file. A
//! path that matches no entry is refused before it is opened, whatever asked for it.
//!
//! Deliberately absent: RAPL subzones (`intel-rapl:0:N`), `constraint_2_*` (PL4, the peak
//! power), every `time_window`/`enabled`/`energy` file, `intel_pstate/status`, every cpufreq
//! file but the governor and the EPP, and every asus-nb-wmi file but `gpu_mux_mode`.
//!
//! The two floors of the interaction boost (`boost.rs`) have classes of their own: intel_pstate's
//! `min_perf_pct` and the Intel GPU's minimum frequency (`gt_min_freq_mhz`, or the per-GT
//! `gt/gt0/rps_min_freq_mhz`). No knob of `apply` maps to them (knobs.rs): the profile path still
//! refuses `min_perf_pct`; only the boost raises it, bounded, for under two seconds, and puts it back.

use crate::fsx::is_prefixed_number;

/// What a whitelisted file is for. A write names the class it expects, so the governor's
/// path can never be used to write the EPP, or the MUX path the charge limit.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Class {
    Governor,
    Epp,
    Turbo,
    MaxPerf,
    Profile,
    /// `constraint_0` / `constraint_1` of a package zone (PL1 / PL2 -- never PL4).
    Rapl,
    ChargeLimit,
    Mux,
    /// intel_pstate's `min_perf_pct`: the boost's CPU floor, never a profile knob.
    BoostCpuFloor,
    /// The render GT's minimum frequency of a `cardN` (writer.rs also wants the card's driver to be i915).
    BoostGpuFloor,
}

fn rapl_zone(family: &str, zone: &str) -> bool {
    matches!((family, zone), ("intel-rapl", "intel-rapl:0") | ("intel-rapl-mmio", "intel-rapl-mmio:0"))
}

/// Classify a canonical path given as its components below `/sys`.
pub fn classify(rel: &[&str]) -> Option<Class> {
    match rel {
        ["devices", "system", "cpu", "cpufreq", policy, "scaling_governor"] if is_prefixed_number(policy, "policy") => {
            Some(Class::Governor)
        }
        ["devices", "system", "cpu", "cpufreq", policy, "energy_performance_preference"]
            if is_prefixed_number(policy, "policy") =>
        {
            Some(Class::Epp)
        }
        ["devices", "system", "cpu", "intel_pstate", "no_turbo"] => Some(Class::Turbo),
        ["devices", "system", "cpu", "intel_pstate", "max_perf_pct"] => Some(Class::MaxPerf),
        ["firmware", "acpi", "platform_profile"] => Some(Class::Profile),
        ["devices", .., handler, "profile"] if is_prefixed_number(handler, "platform-profile-") => Some(Class::Profile),
        ["devices", "virtual", "powercap", family, zone, file]
            if rapl_zone(family, zone)
                && matches!(*file, "constraint_0_power_limit_uw" | "constraint_1_power_limit_uw") =>
        {
            Some(Class::Rapl)
        }
        ["devices", .., "power_supply", battery, "charge_control_end_threshold"]
            if is_prefixed_number(battery, "BAT") =>
        {
            Some(Class::ChargeLimit)
        }
        ["devices", "platform", "asus-nb-wmi", "gpu_mux_mode"] => Some(Class::Mux),
        ["devices", "system", "cpu", "intel_pstate", "min_perf_pct"] => Some(Class::BoostCpuFloor),
        ["devices", .., "drm", card, "gt_min_freq_mhz"] if is_prefixed_number(card, "card") => {
            Some(Class::BoostGpuFloor)
        }
        ["devices", .., "drm", card, "gt", "gt0", "rps_min_freq_mhz"] if is_prefixed_number(card, "card") => {
            Some(Class::BoostGpuFloor)
        }
        ["devices", "virtual", "firmware-attributes", "asus-armoury", "attributes", "gpu_mux_mode", "current_value"] => {
            Some(Class::Mux)
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(path: &str) -> Option<Class> {
        let parts: Vec<&str> = path.trim_start_matches('/').split('/').collect();
        classify(&parts)
    }

    #[test]
    fn allowed_shapes() {
        use Class::*;
        let cases = [
            ("devices/system/cpu/cpufreq/policy0/scaling_governor", Governor),
            ("devices/system/cpu/cpufreq/policy21/scaling_governor", Governor),
            ("devices/system/cpu/cpufreq/policy7/energy_performance_preference", Epp),
            ("devices/system/cpu/intel_pstate/no_turbo", Turbo),
            ("devices/system/cpu/intel_pstate/max_perf_pct", MaxPerf),
            ("firmware/acpi/platform_profile", Profile),
            ("devices/platform/asus-nb-wmi/platform-profile/platform-profile-0/profile", Profile),
            ("devices/pci0000:00/0000:00:14.3/platform-profile-12/profile", Profile),
            ("devices/virtual/powercap/intel-rapl/intel-rapl:0/constraint_0_power_limit_uw", Rapl),
            ("devices/virtual/powercap/intel-rapl/intel-rapl:0/constraint_1_power_limit_uw", Rapl),
            ("devices/virtual/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw", Rapl),
            ("devices/virtual/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_1_power_limit_uw", Rapl),
            (
                "devices/LNXSYSTM:00/LNXSYBUS:00/PNP0A08:00/PNP0C0A:03/power_supply/BAT0/charge_control_end_threshold",
                ChargeLimit,
            ),
            ("devices/platform/x/power_supply/BAT12/charge_control_end_threshold", ChargeLimit),
            ("devices/platform/asus-nb-wmi/gpu_mux_mode", Mux),
            ("devices/virtual/firmware-attributes/asus-armoury/attributes/gpu_mux_mode/current_value", Mux),
            ("devices/system/cpu/intel_pstate/min_perf_pct", BoostCpuFloor),
            ("devices/pci0000:00/0000:00:02.0/drm/card1/gt_min_freq_mhz", BoostGpuFloor),
            ("devices/pci0000:00/0000:00:02.0/drm/card0/gt/gt0/rps_min_freq_mhz", BoostGpuFloor),
        ];
        for (path, class) in cases {
            assert_eq!(c(path), Some(class), "{path}");
        }
    }

    #[test]
    fn everything_else_is_refused() {
        let refused = [
            // PL4, the subzones and every other RAPL file
            "devices/virtual/powercap/intel-rapl/intel-rapl:0/constraint_2_power_limit_uw",
            "devices/virtual/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_2_power_limit_uw",
            "devices/virtual/powercap/intel-rapl/intel-rapl:0/constraint_3_power_limit_uw",
            "devices/virtual/powercap/intel-rapl/intel-rapl:0/constraint_0_time_window_us",
            "devices/virtual/powercap/intel-rapl/intel-rapl:0/constraint_0_max_power_uw",
            "devices/virtual/powercap/intel-rapl/intel-rapl:0/enabled",
            "devices/virtual/powercap/intel-rapl/intel-rapl:0/energy_uj",
            "devices/virtual/powercap/intel-rapl/intel-rapl:0/intel-rapl:0:0/constraint_0_power_limit_uw",
            "devices/virtual/powercap/intel-rapl/intel-rapl:0/intel-rapl:0:1/constraint_1_power_limit_uw",
            "devices/virtual/powercap/intel-rapl/intel-rapl:1/constraint_0_power_limit_uw",
            "devices/virtual/powercap/intel-rapl-mmio/intel-rapl:0/constraint_0_power_limit_uw",
            "devices/virtual/powercap/intel-rapl/intel-rapl-mmio:0/constraint_0_power_limit_uw",
            // cpufreq, but not the two knobs
            "devices/system/cpu/cpufreq/policy0/scaling_max_freq",
            "devices/system/cpu/cpufreq/policy0/scaling_min_freq",
            "devices/system/cpu/cpufreq/policy0/scaling_available_governors",
            "devices/system/cpu/cpufreq/policy0/energy_performance_available_preferences",
            "devices/system/cpu/cpufreq/policy/scaling_governor",
            "devices/system/cpu/cpufreq/policyX/scaling_governor",
            "devices/system/cpu/cpu0/cpufreq/scaling_governor",
            "devices/system/cpu/cpufreq/policy0/sub/scaling_governor",
            // intel_pstate, but not the two knobs
            "devices/system/cpu/intel_pstate/status",
            "devices/system/cpu/intel_pstate/hwp_dynamic_boost",
            // platform profile lookalikes
            "devices/platform/asus-nb-wmi/platform-profile/platform-profile-0/choices",
            "devices/platform/asus-nb-wmi/platform-profile/platform-profile-0/name",
            "devices/platform/asus-nb-wmi/platform-profile/platform-profile-/profile",
            "devices/platform/asus-nb-wmi/platform-profile/profile",
            "firmware/acpi/platform_profile_choices",
            "class/platform-profile/platform-profile-0/profile",
            // batteries
            "devices/platform/x/power_supply/AC0/charge_control_end_threshold",
            "devices/platform/x/power_supply/BAT/charge_control_end_threshold",
            "devices/platform/x/power_supply/BAT0/charge_control_start_threshold",
            "devices/platform/x/power_supply/BAT0/charge_behaviour",
            "devices/platform/x/power_supply/BAT0/uevent",
            "devices/platform/x/BAT0/charge_control_end_threshold",
            // asus
            "devices/platform/asus-nb-wmi/throttle_thermal_policy",
            "devices/platform/asus-nb-wmi/dgpu_disable",
            "devices/platform/asus-nb-wmi/egpu_enable",
            "devices/platform/asus-nb-wmi/cpufv",
            "devices/virtual/firmware-attributes/asus-armoury/attributes/gpu_mux_mode/possible_values",
            "devices/virtual/firmware-attributes/asus-armoury/attributes/pending_reboot",
            "devices/virtual/firmware-attributes/asus-armoury/attributes/ppt_pl1_spl/current_value",
            "devices/virtual/firmware-attributes/asus-armoury/attributes/nv_tgp/current_value",
            "devices/virtual/firmware-attributes/other/attributes/gpu_mux_mode/current_value",
            // the GPU: only the render GT's minimum
            "devices/pci0000:00/0000:00:02.0/drm/card1/gt_max_freq_mhz",
            "devices/pci0000:00/0000:00:02.0/drm/card1/gt_boost_freq_mhz",
            "devices/pci0000:00/0000:00:02.0/drm/card1/gt/gt0/rps_max_freq_mhz",
            "devices/pci0000:00/0000:00:02.0/drm/card1/gt/gt0/rps_boost_freq_mhz",
            "devices/pci0000:00/0000:00:02.0/drm/card1/gt/gt1/rps_min_freq_mhz",
            "devices/pci0000:00/0000:00:02.0/drm/card1-eDP-1/gt_min_freq_mhz",
            "devices/pci0000:00/0000:00:02.0/drm/renderD128/gt_min_freq_mhz",
            "devices/pci0000:00/0000:00:02.0/card1/gt_min_freq_mhz",
            "class/drm/card1/gt_min_freq_mhz",
            // anywhere else
            "power/state",
            "kernel/mm/transparent_hugepage/enabled",
            "class/power_supply/BAT0/charge_control_end_threshold",
            "devices/system/cpu/cpufreq/boost",
            "",
        ];
        for path in refused {
            assert_eq!(c(path), None, "{path:?} must be refused");
        }
    }
}
