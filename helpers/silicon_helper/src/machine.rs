//! What this machine has right now, found by looking: every knob is discovered by name, by
//! type or by content, never assumed. A knob a kernel renames or drops simply is not there
//! (its feature is false): that is never an error and never a guess.

use std::path::PathBuf;

use crate::fsx::{intersect, is_prefixed_number, list_dir, parse_u64, read_opt, tokens};
use crate::gpu::{self, Dgpu};
use crate::roots::Roots;
use crate::state::{BootMark, CapsRecord, MuxRecord, State, Wiring};

/// The lowest a power cap may be set: 8 W.
pub const CAP_FLOOR_UW: u64 = 8_000_000;

/// A knob that is one file per cpufreq policy: the governor, the EPP.
#[derive(Debug, Clone)]
pub struct PolicyKnob {
    /// Every policy's attribute file with the value it holds now.
    pub files: Vec<(PathBuf, String)>,
    /// The kernel's own list, in its order (minus `default` for the EPP).
    pub choices: Vec<String>,
    /// The same on every policy, else `mixed`.
    pub value: String,
}

#[derive(Debug, Clone)]
pub struct ProfileKnob {
    /// The class handlers' `profile` files (or the one legacy file).
    pub files: Vec<(PathBuf, String)>,
    /// What every handler offers, minus `custom`.
    pub choices: Vec<String>,
    /// The same on every handler, else `custom` (the kernel's own word for "not one profile").
    pub value: String,
}

#[derive(Debug, Clone)]
pub struct MaxPerf {
    pub file: PathBuf,
    pub value: u32,
    pub min: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ZoneKind {
    Msr,
    Mmio,
}

impl ZoneKind {
    pub fn name(self) -> &'static str {
        match self {
            ZoneKind::Msr => "msr",
            ZoneKind::Mmio => "mmio",
        }
    }
}

/// A RAPL package zone whose PL1 (`long_term`) and PL2 (`short_term`) were found by name.
#[derive(Debug, Clone)]
pub struct Zone {
    pub kind: ZoneKind,
    pub pl1_file: PathBuf,
    pub pl2_file: PathBuf,
    pub pl1_uw: u64,
    pub pl2_uw: u64,
}

#[derive(Debug, Clone)]
pub struct Battery {
    /// `/sys/class/power_supply/BATn`, as reported.
    pub path: PathBuf,
    pub file: PathBuf,
    pub limit: i64,
}

#[derive(Debug, Clone)]
pub struct MuxKnob {
    pub file: PathBuf,
    pub armoury: bool,
    pub stored: Wiring,
}

#[derive(Debug, Clone, Default)]
pub struct Paths {
    pub ac: Option<PathBuf>,
    pub coretemp: Option<PathBuf>,
    pub rc6: Option<PathBuf>,
    pub cpufreq: Option<PathBuf>,
}

#[derive(Debug, Clone)]
pub struct Machine {
    pub profile: Option<ProfileKnob>,
    pub governor: Option<PolicyKnob>,
    pub epp: Option<PolicyKnob>,
    /// (`no_turbo` file, turbo is on)
    pub turbo: Option<(PathBuf, bool)>,
    pub max_perf: Option<MaxPerf>,
    pub zones: Vec<Zone>,
    pub battery: Option<Battery>,
    pub mux: Option<MuxKnob>,
    pub wiring: Option<Wiring>,
    pub dgpu: Option<Dgpu>,
    pub paths: Paths,
    /// What a switch to dGPU-only needs of the NVIDIA stack (loaded, built for every kernel): (ok, what is missing).
    pub precheck: (bool, String),
    /// Whether the unit that writes a queued change at shutdown is active (`gpu::mux_unit_check`): a request of
    /// EITHER direction is refused while it is not.
    pub mux_unit: (bool, String),
    pub boot_id: Option<String>,
    /// The caps record as stored (any boot); `ceilings` says whether it is this boot's.
    pub caps_record: Option<CapsRecord>,
    pub mark: Option<BootMark>,
    pub mux_record: Option<MuxRecord>,
    /// Things worth a line on stderr (a state file that is not understood).
    pub notes: Vec<String>,
}

fn policy_knob(roots: &Roots, attr: &str, list_attr: &str, drop: &[&str], mixed: &str) -> Option<PolicyKnob> {
    let base = roots.sys_path("devices/system/cpu/cpufreq");
    let mut files: Vec<(PathBuf, String)> = Vec::new();
    let mut choices: Option<Vec<String>> = None;
    for name in list_dir(&base).iter().filter(|n| is_prefixed_number(n, "policy")) {
        let dir = base.join(name);
        let (Some(current), Some(list)) = (read_opt(&dir.join(attr)), read_opt(&dir.join(list_attr))) else { continue };
        let mut list = tokens(&list);
        list.retain(|t| !drop.contains(&t.as_str()));
        if list.is_empty() {
            continue;
        }
        choices = Some(match choices {
            None => list,
            Some(prev) => intersect(&prev, &list),
        });
        files.push((dir.join(attr), current));
    }
    let choices = choices.filter(|c| !c.is_empty())?;
    let value = common_value(&files, mixed)?;
    Some(PolicyKnob { files, choices, value })
}

/// The one value every file holds, else `different`; `None` for no files at all.
fn common_value(files: &[(PathBuf, String)], different: &str) -> Option<String> {
    let first = files.first()?.1.clone();
    Some(if files.iter().all(|(_, v)| *v == first) { first } else { different.to_string() })
}

fn discover_profile(roots: &Roots) -> Option<ProfileKnob> {
    let class = roots.sys_path("class/platform-profile");
    let mut files: Vec<(PathBuf, String)> = Vec::new();
    let mut choices: Option<Vec<String>> = None;
    for name in list_dir(&class).iter().filter(|n| is_prefixed_number(n, "platform-profile-")) {
        let dir = class.join(name);
        let (Some(current), Some(list)) = (read_opt(&dir.join("profile")), read_opt(&dir.join("choices"))) else {
            continue;
        };
        let mut list = tokens(&list);
        list.retain(|t| t != "custom");
        choices = Some(match choices {
            None => list,
            Some(prev) => intersect(&prev, &list),
        });
        files.push((dir.join("profile"), current));
    }
    if files.is_empty() {
        let legacy = roots.sys_path("firmware/acpi/platform_profile");
        let (Some(current), Some(list)) =
            (read_opt(&legacy), read_opt(&roots.sys_path("firmware/acpi/platform_profile_choices")))
        else {
            return None;
        };
        let mut list = tokens(&list);
        list.retain(|t| t != "custom");
        files.push((legacy, current));
        choices = Some(list);
    }
    let choices = choices.filter(|c| !c.is_empty())?;
    let value = common_value(&files, "custom")?;
    Some(ProfileKnob { files, choices, value })
}

fn discover_turbo(roots: &Roots) -> Option<(PathBuf, bool)> {
    let file = roots.sys_path("devices/system/cpu/intel_pstate/no_turbo");
    match read_opt(&file)?.as_str() {
        "0" => Some((file, true)),
        "1" => Some((file, false)),
        _ => None,
    }
}

fn discover_max_perf(roots: &Roots) -> Option<MaxPerf> {
    let base = roots.sys_path("devices/system/cpu/intel_pstate");
    let file = base.join("max_perf_pct");
    let value = u32::try_from(parse_u64(&read_opt(&file)?)?).ok()?;
    let min = u32::try_from(parse_u64(&read_opt(&base.join("min_perf_pct"))?)?).ok()?;
    Some(MaxPerf { file, value, min })
}

/// The package zones of both RAPL interfaces. PL1 is the constraint NAMED `long_term`, PL2
/// the one NAMED `short_term`; `peak_power` (PL4) is never looked at, and a zone whose
/// names are not the expected two is not offered at all.
fn discover_zones(roots: &Roots) -> Vec<Zone> {
    let mut zones = Vec::new();
    for (class_name, kind) in [("intel-rapl:0", ZoneKind::Msr), ("intel-rapl-mmio:0", ZoneKind::Mmio)] {
        let dir = roots.sys_path(&format!("class/powercap/{class_name}"));
        if read_opt(&dir.join("name")).as_deref() != Some("package-0") {
            continue;
        }
        let (mut long, mut short) = (None, None);
        let mut ambiguous = false;
        for n in 0..4u32 {
            match read_opt(&dir.join(format!("constraint_{n}_name"))).as_deref() {
                Some("long_term") => ambiguous |= long.replace(n).is_some(),
                Some("short_term") => ambiguous |= short.replace(n).is_some(),
                _ => {}
            }
        }
        let (Some(long), Some(short)) = (long, short) else { continue };
        if ambiguous || long > 1 || short > 1 {
            continue;
        }
        let pl1_file = dir.join(format!("constraint_{long}_power_limit_uw"));
        let pl2_file = dir.join(format!("constraint_{short}_power_limit_uw"));
        let (Some(pl1_uw), Some(pl2_uw)) =
            (read_opt(&pl1_file).and_then(|t| parse_u64(&t)), read_opt(&pl2_file).and_then(|t| parse_u64(&t)))
        else {
            continue;
        };
        zones.push(Zone { kind, pl1_file, pl2_file, pl1_uw, pl2_uw });
    }
    zones
}

fn discover_battery(roots: &Roots) -> Option<Battery> {
    let class = roots.sys_path("class/power_supply");
    list_dir(&class).into_iter().filter(|n| is_prefixed_number(n, "BAT")).find_map(|name| {
        let dir = class.join(&name);
        if read_opt(&dir.join("type")).as_deref() != Some("Battery") {
            return None;
        }
        let file = dir.join("charge_control_end_threshold");
        let limit = read_opt(&file)?.parse::<i64>().ok()?;
        Some(Battery { path: dir, file, limit })
    })
}

fn discover_ac(roots: &Roots) -> Option<PathBuf> {
    let class = roots.sys_path("class/power_supply");
    list_dir(&class)
        .into_iter()
        .map(|n| class.join(n))
        .find(|dir| read_opt(&dir.join("type")).as_deref() == Some("Mains"))
}

fn discover_coretemp(roots: &Roots) -> Option<PathBuf> {
    let class = roots.sys_path("class/hwmon");
    list_dir(&class)
        .into_iter()
        .filter(|n| is_prefixed_number(n, "hwmon"))
        .map(|n| class.join(n))
        .find(|dir| read_opt(&dir.join("name")).as_deref() == Some("coretemp"))
}

/// The MUX: asus-armoury's `gpu_mux_mode` when the kernel has it (it must offer 0 and 1),
/// otherwise the legacy asus-nb-wmi file. 1 is hybrid, 0 is dgpu.
fn discover_mux(roots: &Roots) -> Option<MuxKnob> {
    let armoury = roots.sys_path("class/firmware-attributes/asus-armoury/attributes/gpu_mux_mode");
    if let (Some(current), Some(possible)) =
        (read_opt(&armoury.join("current_value")), read_opt(&armoury.join("possible_values")))
    {
        let offered = tokens(&possible);
        let both = ["0", "1"].iter().all(|v| offered.iter().any(|o| o == v));
        if let (true, Some(stored)) = (both, Wiring::from_mux_value(&current)) {
            return Some(MuxKnob { file: armoury.join("current_value"), armoury: true, stored });
        }
    }
    let legacy = roots.sys_path("devices/platform/asus-nb-wmi/gpu_mux_mode");
    let stored = Wiring::from_mux_value(&read_opt(&legacy)?)?;
    Some(MuxKnob { file: legacy, armoury: false, stored })
}

/// A state file that is there but not understood reads as absent here; the reason is kept.
fn noted<T>(notes: &mut Vec<String>, r: Result<Option<T>, String>) -> Option<T> {
    r.unwrap_or_else(|e| {
        notes.push(e);
        None
    })
}

impl Machine {
    /// Everything `status` reports, the dGPU's `/dev/nvidiaN` included -- which only the NVIDIA driver's own proc
    /// entry names, a read that can block for good on a wedged driver. Only what reports a status calls this.
    pub fn discover(roots: &Roots) -> Machine {
        Machine::build(roots, true)
    }

    /// What anything that WRITES needs: the same machine without the one read that goes to the NVIDIA driver
    /// (`/proc/driver/nvidia/gpus/<pci>/information`). A write -- the way back to hybrid above all -- must never
    /// wait on a driver it does not write to; `tests/mux.rs` wedges that entry and every write path still finishes.
    pub fn discover_for_write(roots: &Roots) -> Machine {
        Machine::build(roots, false)
    }

    /// What a request for `want` has to pass: the NVIDIA stack's checks for dGPU-only, and -- for both
    /// directions -- the unit that would write it at shutdown being active. (ok, what is wrong in plain words.)
    pub fn mux_prechecks(&self, want: Wiring) -> (bool, String) {
        let mut wrong: Vec<&str> = Vec::new();
        if want == Wiring::Dgpu && !self.precheck.0 {
            wrong.push(&self.precheck.1);
        }
        if !self.mux_unit.0 {
            wrong.push(&self.mux_unit.1);
        }
        (wrong.is_empty(), wrong.join("; "))
    }

    fn build(roots: &Roots, nvidia_node: bool) -> Machine {
        let st = State::new(roots.state.clone());
        let mut notes = Vec::new();
        let caps_record = noted(&mut notes, st.caps());
        let mark = noted(&mut notes, st.mark());
        let mux_record = noted(&mut notes, st.mux());
        let cpufreq = Some(roots.sys_path("devices/system/cpu/cpufreq")).filter(|p| p.is_dir());
        Machine {
            profile: discover_profile(roots),
            governor: policy_knob(roots, "scaling_governor", "scaling_available_governors", &[], "mixed"),
            epp: policy_knob(
                roots,
                "energy_performance_preference",
                "energy_performance_available_preferences",
                &["default"],
                "mixed",
            ),
            turbo: discover_turbo(roots),
            max_perf: discover_max_perf(roots),
            zones: discover_zones(roots),
            battery: discover_battery(roots),
            mux: discover_mux(roots),
            wiring: gpu::wiring_now(roots),
            dgpu: gpu::find_dgpu(roots, nvidia_node),
            paths: Paths {
                ac: discover_ac(roots),
                coretemp: discover_coretemp(roots),
                rc6: gpu::rc6_path(roots),
                cpufreq,
            },
            precheck: gpu::precheck_mux(roots),
            mux_unit: gpu::mux_unit_check(roots),
            boot_id: read_opt(&roots.proc_path("sys/kernel/random/boot_id")).filter(|b| !b.is_empty()),
            caps_record,
            mark,
            mux_record,
            notes,
        }
    }

    #[cfg(test)]
    /// A machine with nothing on it (tests fill in what they need).
    pub fn blank() -> Machine {
        Machine {
            profile: None,
            governor: None,
            epp: None,
            turbo: None,
            max_perf: None,
            zones: Vec::new(),
            battery: None,
            mux: None,
            wiring: None,
            dgpu: None,
            paths: Paths::default(),
            precheck: (true, String::new()),
            mux_unit: (true, String::new()),
            boot_id: Some("boot-1".into()),
            caps_record: None,
            mark: None,
            mux_record: None,
            notes: Vec::new(),
        }
    }

    /// The firmware's PL1/PL2 as `boot-apply` recorded them in THIS boot, before anything was
    /// written: the lower of the zones recorded. `None` when there is no record for this boot.
    pub fn ceilings(&self) -> Option<(u64, u64)> {
        let rec = self.caps_record.as_ref()?;
        if self.boot_id.as_deref() != Some(rec.boot_id.as_str()) {
            return None;
        }
        let zones: Vec<_> = [&rec.msr, &rec.mmio].into_iter().flatten().collect();
        Some((zones.iter().map(|z| z.pl1_uw).min()?, zones.iter().map(|z| z.pl2_uw).min()?))
    }

    /// Caps are writable: a package zone is there AND the firmware's limits are on record for
    /// this boot AND they sit at or above the floor.
    pub fn caps_ready(&self) -> bool {
        !self.zones.is_empty() && self.ceilings().is_some_and(|(p1, p2)| p1 >= CAP_FLOOR_UW && p2 >= CAP_FLOOR_UW)
    }

    /// The limits in force: the lower of the zones present.
    pub fn effective_caps(&self) -> Option<(u64, u64)> {
        Some((self.zones.iter().map(|z| z.pl1_uw).min()?, self.zones.iter().map(|z| z.pl2_uw).min()?))
    }

    /// Whether any cpufreq policy runs the `performance` governor (EPP is fixed then).
    pub fn epp_locked(&self) -> bool {
        self.governor.as_ref().is_some_and(|g| g.files.iter().any(|(_, v)| v == "performance"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::ZoneCaps;

    pub(crate) fn zone(kind: ZoneKind, p1: u64, p2: u64) -> Zone {
        Zone { kind, pl1_file: PathBuf::new(), pl2_file: PathBuf::new(), pl1_uw: p1, pl2_uw: p2 }
    }

    #[test]
    fn ceilings_are_the_lower_zone_of_this_boots_record_only() {
        let mut m = Machine::blank();
        assert_eq!(m.ceilings(), None);
        m.caps_record = Some(CapsRecord {
            boot_id: "boot-1".into(),
            msr: Some(ZoneCaps { pl1_uw: 65_000_000, pl2_uw: 115_000_000 }),
            mmio: Some(ZoneCaps { pl1_uw: 45_000_000, pl2_uw: 115_000_000 }),
        });
        assert_eq!(m.ceilings(), Some((45_000_000, 115_000_000)));
        m.boot_id = Some("boot-2".into());
        assert_eq!(m.ceilings(), None, "a record of another boot is no record");
        m.boot_id = None;
        assert_eq!(m.ceilings(), None);
    }

    #[test]
    fn caps_need_a_zone_a_record_and_a_ceiling_above_the_floor() {
        let mut m = Machine::blank();
        let rec = |p1: u64, p2: u64| CapsRecord {
            boot_id: "boot-1".into(),
            msr: Some(ZoneCaps { pl1_uw: p1, pl2_uw: p2 }),
            mmio: None,
        };
        m.caps_record = Some(rec(45_000_000, 115_000_000));
        assert!(!m.caps_ready(), "no zone");
        m.zones = vec![zone(ZoneKind::Msr, 45_000_000, 115_000_000)];
        assert!(m.caps_ready());
        m.caps_record = Some(rec(7_000_000, 115_000_000));
        assert!(!m.caps_ready(), "ceiling below the 8 W floor");
        m.caps_record = Some(CapsRecord { boot_id: "boot-1".into(), msr: None, mmio: None });
        assert!(!m.caps_ready(), "nothing recorded");
    }

    #[test]
    fn effective_caps_are_the_lower_zone() {
        let mut m = Machine::blank();
        assert_eq!(m.effective_caps(), None);
        m.zones = vec![zone(ZoneKind::Msr, 65_000_000, 115_000_000), zone(ZoneKind::Mmio, 45_000_000, 120_000_000)];
        assert_eq!(m.effective_caps(), Some((45_000_000, 115_000_000)));
    }

    #[test]
    fn common_value_names_a_disagreement() {
        let f = |v: &str| (PathBuf::new(), v.to_string());
        assert_eq!(common_value(&[f("a"), f("a")], "mixed"), Some("a".into()));
        assert_eq!(common_value(&[f("a"), f("b")], "mixed"), Some("mixed".into()));
        assert_eq!(common_value(&[], "mixed"), None);
    }

    /// READ-ONLY. The paths this machine really has, found the way the helper finds them, must pass the
    /// whitelist: the shapes in whitelist.rs match the kernel's actual layout (this proves it on whatever
    /// machine runs the tests; the captures prove it for 6.18 and 7.2). `vet` canonicalises and checks; it
    /// never opens anything for writing.
    #[test]
    fn on_the_real_machine_every_discovered_knob_passes_the_whitelist() {
        use crate::whitelist::Class;
        use crate::writer::{Faults, Writer};
        let Ok(roots) = Roots::real() else { return };
        let m = Machine::discover_for_write(&roots);
        let faults = Faults::none();
        let w = Writer::new(&roots, &faults);
        let mut vetted = 0;
        let mut check = |class: Class, path: &PathBuf| {
            assert!(
                w.vet(class, path).is_ok(),
                "{} must be on the whitelist as {class:?}: {:?}",
                path.display(),
                w.vet(class, path).err()
            );
            vetted += 1;
        };
        for (p, _) in m.profile.iter().flat_map(|k| &k.files) {
            check(Class::Profile, p);
        }
        for (p, _) in m.governor.iter().flat_map(|k| &k.files) {
            check(Class::Governor, p);
        }
        for (p, _) in m.epp.iter().flat_map(|k| &k.files) {
            check(Class::Epp, p);
        }
        if let Some((p, _)) = &m.turbo {
            check(Class::Turbo, p);
        }
        if let Some(mp) = &m.max_perf {
            check(Class::MaxPerf, &mp.file);
        }
        for z in &m.zones {
            check(Class::Rapl, &z.pl1_file);
            check(Class::Rapl, &z.pl2_file);
        }
        if let Some(b) = &m.battery {
            check(Class::ChargeLimit, &b.file);
        }
        if let Some(k) = &m.mux {
            check(Class::Mux, &k.file);
        }
        eprintln!("{vetted} real knob files vetted against the whitelist");
    }
}
