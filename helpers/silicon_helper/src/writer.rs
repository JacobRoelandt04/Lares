//! The one door every write to `/sys` goes through, and the test faults that can be armed
//! behind it. A write is: canonicalise, check the whitelist (and, for the battery, that its
//! `type` is `Battery`), refuse anything that is not a plain file, open write-only without
//! creating and without following a symlink, write once. Nothing else in the helper opens a
//! sysfs file for writing.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Component, Path, PathBuf};

use crate::fsx::{self, parse_decimal_uw};
use crate::roots::Roots;
use crate::state::Wiring;
use crate::sys::O_NOFOLLOW;
use crate::whitelist::{classify, Class};

/// The knob names a fault can address: the result `knob`s plus `mux`.
pub const FAULT_KNOBS: [&str; 9] =
    ["profile", "epp", "turbo", "governor", "maxPerfPct", "pl1W", "pl2W", "chargeLimit", "mux"];

/// What the file holds when the kernel clamps `knob` to `value`, `value` written as the apply
/// argument is (names as they are, turbo 0|1, whole numbers, watts, mux `hybrid`|`dgpu`).
fn clamp_text(knob: &str, value: &str) -> Result<String, String> {
    let bad = || format!("'{value}' is not a value of {knob}");
    let digits = !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit());
    match knob {
        "profile" | "epp" | "governor" => {
            let word = !value.is_empty()
                && value.len() <= 40
                && value.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'));
            word.then(|| value.to_string()).ok_or_else(bad)
        }
        // the file is no_turbo: turbo on is 0
        "turbo" => match value {
            "1" => Ok("0".to_string()),
            "0" => Ok("1".to_string()),
            _ => Err(bad()),
        },
        "maxPerfPct" | "chargeLimit" => {
            value.parse::<u32>().ok().filter(|_| digits).map(|n| n.to_string()).ok_or_else(bad)
        }
        "pl1W" | "pl2W" => parse_decimal_uw(value, 4, 3).map(|uw| uw.to_string()).ok_or_else(bad),
        "mux" => Wiring::parse(value).map(|w| w.mux_value().to_string()).ok_or_else(bad),
        _ => Err(bad()),
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Fault {
    /// The write fails with EIO.
    Eio,
    /// The write succeeds and the value does not change.
    Ignore,
    /// The kernel stores this instead: the FILE ends up holding this text (the clamp value the caller
    /// gave, in the knob's own units, converted the way a write converts it).
    Clamp(String),
}

#[derive(Debug, Default, Clone)]
pub struct Faults(Vec<(String, Fault)>);

impl Faults {
    pub fn none() -> Faults {
        Faults::default()
    }

    /// `<knob>:<fault>[,...]` with fault = `eio` | `ignore` | `clamp:<value>`.
    pub fn parse(spec: &str) -> Result<Faults, String> {
        let mut items = Vec::new();
        for part in spec.split(',').filter(|p| !p.is_empty()) {
            let (knob, fault) = part.split_once(':').ok_or_else(|| format!("fault '{part}' has no ':'"))?;
            if !FAULT_KNOBS.contains(&knob) {
                return Err(format!("fault names an unknown knob '{knob}'"));
            }
            let fault = match fault {
                "eio" => Fault::Eio,
                "ignore" => Fault::Ignore,
                other => match other.strip_prefix("clamp:") {
                    Some(v) => Fault::Clamp(clamp_text(knob, v)?),
                    None => return Err(format!("unknown fault '{other}' (eio, ignore, clamp:<value>)")),
                },
            };
            items.push((knob.to_string(), fault));
        }
        Ok(Faults(items))
    }

    pub fn get(&self, knob: &str) -> Option<&Fault> {
        self.0.iter().find(|(k, _)| k == knob).map(|(_, f)| f)
    }
}

#[derive(Debug)]
pub enum WriteError {
    /// The whitelist said no (or the path is not a plain file): nothing was opened.
    Refused(String),
    Io(io::Error),
}

impl std::fmt::Display for WriteError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WriteError::Refused(why) => f.write_str(why),
            WriteError::Io(e) => write!(f, "{e}"),
        }
    }
}

fn refused(why: impl Into<String>) -> WriteError {
    WriteError::Refused(why.into())
}

pub struct Writer<'a> {
    roots: &'a Roots,
    faults: &'a Faults,
}

/// Open for writing: write-only, truncating (what `echo > file` does; sysfs ignores it),
/// NEVER creating, never following a symlink on the final component.
pub fn open_write(path: &Path) -> io::Result<File> {
    OpenOptions::new().write(true).truncate(true).custom_flags(O_NOFOLLOW).open(path)
}

/// The PCI device above the `drm` directory of `canon` is bound to i915 (never the NVIDIA card's).
fn drm_driver_is_i915(canon: &Path) -> bool {
    let Some(drm) = canon.ancestors().find(|a| a.file_name().is_some_and(|n| n == "drm")) else { return false };
    let Some(device) = drm.parent() else { return false };
    fs::read_link(device.join("driver")).ok().and_then(|l| l.file_name().map(|n| n == "i915")).unwrap_or(false)
}

impl<'a> Writer<'a> {
    pub fn new(roots: &'a Roots, faults: &'a Faults) -> Writer<'a> {
        Writer { roots, faults }
    }

    /// Resolve `path` and check it against the whitelist for `class`; returns the canonical
    /// path a write would open. Used to validate a whole plan before anything is written.
    pub fn vet(&self, class: Class, path: &Path) -> Result<PathBuf, WriteError> {
        let canon = fs::canonicalize(path).map_err(WriteError::Io)?;
        let rel = canon
            .strip_prefix(&self.roots.sys_canon)
            .map_err(|_| refused(format!("{} is outside /sys", canon.display())))?;
        let parts: Vec<&str> = rel
            .components()
            .map(|c| match c {
                Component::Normal(s) => s.to_str(),
                _ => None,
            })
            .collect::<Option<Vec<_>>>()
            .ok_or_else(|| refused("not a plain path under /sys"))?;
        match classify(&parts) {
            Some(found) if found == class => {}
            Some(found) => return Err(refused(format!("{} is a {found:?} file, not {class:?}", canon.display()))),
            None => return Err(refused(format!("{} is not on the whitelist", canon.display()))),
        }
        if class == Class::ChargeLimit {
            let kind = canon.parent().and_then(|dir| fsx::read_opt(&dir.join("type")));
            if kind.as_deref() != Some("Battery") {
                return Err(refused("the power supply is not of type Battery"));
            }
        }
        if class == Class::BoostGpuFloor && !drm_driver_is_i915(&canon) {
            return Err(refused("the GPU of that card is not driven by i915"));
        }
        let meta = fs::symlink_metadata(&canon).map_err(WriteError::Io)?;
        if !meta.is_file() {
            return Err(refused(format!("{} is not a plain file", canon.display())));
        }
        Ok(canon)
    }

    /// Write `value` (plus a newline) to `path` as the whitelist class `class`.
    pub fn write(&self, knob: &str, class: Class, path: &Path, value: &str) -> Result<(), WriteError> {
        let canon = self.vet(class, path)?;
        let text = match self.faults.get(knob) {
            Some(Fault::Eio) => return Err(WriteError::Io(io::Error::from_raw_os_error(5))),
            Some(Fault::Ignore) => return Ok(()),
            Some(Fault::Clamp(v)) => v.as_str(),
            None => value,
        };
        let mut file = open_write(&canon).map_err(WriteError::Io)?;
        if !file.metadata().map_err(WriteError::Io)?.is_file() {
            return Err(refused(format!("{} is not a plain file", canon.display())));
        }
        file.write_all(format!("{text}\n").as_bytes()).map_err(WriteError::Io)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("sh-writer-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn fault_specs() {
        let f = Faults::parse("profile:eio,epp:ignore,pl1W:clamp:30,turbo:clamp:1,mux:clamp:hybrid,pl2W:clamp:45.5")
            .unwrap();
        assert_eq!(f.get("profile"), Some(&Fault::Eio));
        assert_eq!(f.get("epp"), Some(&Fault::Ignore));
        assert_eq!(f.get("pl1W"), Some(&Fault::Clamp("30000000".into())), "watts, stored as the file holds them");
        assert_eq!(f.get("turbo"), Some(&Fault::Clamp("0".into())), "turbo on is no_turbo 0");
        assert_eq!(f.get("mux"), Some(&Fault::Clamp("1".into())));
        assert_eq!(f.get("pl2W"), Some(&Fault::Clamp("45500000".into())));
        assert_eq!(f.get("maxPerfPct"), None);
        assert!(Faults::parse("").unwrap().get("profile").is_none());
        for bad in [
            "profile",
            "nope:eio",
            "profile:boom",
            "profile:clamp:",
            "profile:clamp",
            "turbo:clamp:7",
            "turbo:clamp:on",
            "maxPerfPct:clamp:-1",
            "maxPerfPct:clamp:9x",
            "pl1W:clamp:abc",
            "pl1W:clamp:30000000000",
            "mux:clamp:1",
            "profile:clamp:../x",
            "epp:clamp:a b",
        ] {
            assert!(Faults::parse(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn open_write_does_not_follow_a_symlink_and_does_not_create() {
        let d = tmp("nofollow");
        let real = d.join("real");
        fs::write(&real, "keep").unwrap();
        let link = d.join("link");
        symlink(&real, &link).unwrap();
        let err = open_write(&link).expect_err("a symlink as the final component must be refused by the kernel");
        assert_eq!(err.raw_os_error(), Some(40), "ELOOP: O_NOFOLLOW is the right bit on this architecture");
        assert_eq!(fs::read_to_string(&real).unwrap(), "keep");
        let missing = d.join("missing");
        assert!(open_write(&missing).is_err());
        assert!(!missing.exists(), "no O_CREAT: a missing file stays missing");
        let _ = fs::remove_dir_all(&d);
    }

    fn roots_for(d: &Path) -> Roots {
        let opts = crate::roots::TestOpts { sysfs_root: Some(d.to_path_buf()), ..Default::default() };
        Roots::from_test(&opts).unwrap()
    }

    #[test]
    fn vet_follows_links_then_judges_the_canonical_path() {
        let d = tmp("vet");
        let gov = d.join("sys/devices/system/cpu/cpufreq/policy0");
        fs::create_dir_all(&gov).unwrap();
        fs::write(gov.join("scaling_governor"), "powersave\n").unwrap();
        fs::write(gov.join("scaling_min_freq"), "1\n").unwrap();
        // a harmless-looking link under the name of a whitelisted file
        fs::create_dir_all(d.join("sys/class/x")).unwrap();
        symlink("../../devices/system/cpu/cpufreq/policy0/scaling_min_freq", d.join("sys/class/x/gov")).unwrap();
        let roots = roots_for(&d);
        let faults = Faults::none();
        let w = Writer::new(&roots, &faults);
        assert!(w.vet(Class::Governor, &gov.join("scaling_governor")).is_ok());
        assert!(matches!(w.vet(Class::Epp, &gov.join("scaling_governor")), Err(WriteError::Refused(_))));
        assert!(matches!(w.vet(Class::Governor, &gov.join("scaling_min_freq")), Err(WriteError::Refused(_))));
        // the link's NAME says nothing: its canonical target is judged
        assert!(matches!(w.vet(Class::Governor, &d.join("sys/class/x/gov")), Err(WriteError::Refused(_))));
        // a link to a file outside /sys
        let outside = d.join("outside");
        fs::write(&outside, "x").unwrap();
        symlink(&outside, gov.join("scaling_governor_link")).unwrap();
        assert!(matches!(w.vet(Class::Governor, &gov.join("scaling_governor_link")), Err(WriteError::Refused(_))));
        // a write through any of them leaves the victims alone
        assert!(w.write("governor", Class::Governor, &gov.join("scaling_governor_link"), "performance").is_err());
        assert_eq!(fs::read_to_string(&outside).unwrap(), "x");
        assert!(w.write("governor", Class::Governor, &d.join("sys/class/x/gov"), "performance").is_err());
        assert_eq!(fs::read_to_string(gov.join("scaling_min_freq")).unwrap(), "1\n");
        // and the real one writes
        w.write("governor", Class::Governor, &gov.join("scaling_governor"), "performance").unwrap();
        assert_eq!(fs::read_to_string(gov.join("scaling_governor")).unwrap(), "performance\n");
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn a_battery_must_say_it_is_a_battery() {
        let d = tmp("bat");
        let ps = d.join("sys/devices/platform/x/power_supply/BAT0");
        fs::create_dir_all(&ps).unwrap();
        fs::write(ps.join("charge_control_end_threshold"), "100\n").unwrap();
        let roots = roots_for(&d);
        let faults = Faults::none();
        let w = Writer::new(&roots, &faults);
        let f = ps.join("charge_control_end_threshold");
        assert!(w.vet(Class::ChargeLimit, &f).is_err(), "no type file");
        fs::write(ps.join("type"), "Mains\n").unwrap();
        assert!(w.vet(Class::ChargeLimit, &f).is_err(), "type Mains");
        fs::write(ps.join("type"), "Battery\n").unwrap();
        assert!(w.vet(Class::ChargeLimit, &f).is_ok());
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn faults_act_behind_the_door() {
        let d = tmp("faults");
        let dir = d.join("sys/devices/system/cpu/intel_pstate");
        fs::create_dir_all(&dir).unwrap();
        let f = dir.join("no_turbo");
        fs::write(&f, "0\n").unwrap();
        let roots = roots_for(&d);
        let eio = Faults::parse("turbo:eio").unwrap();
        let err = Writer::new(&roots, &eio).write("turbo", Class::Turbo, &f, "1").unwrap_err();
        assert!(matches!(&err, WriteError::Io(e) if e.raw_os_error() == Some(5)));
        assert_eq!(fs::read_to_string(&f).unwrap(), "0\n");
        let ignore = Faults::parse("turbo:ignore").unwrap();
        Writer::new(&roots, &ignore).write("turbo", Class::Turbo, &f, "1").unwrap();
        assert_eq!(fs::read_to_string(&f).unwrap(), "0\n");
        let clamp = Faults::parse("turbo:clamp:1").unwrap();
        Writer::new(&roots, &clamp).write("turbo", Class::Turbo, &f, "1").unwrap();
        assert_eq!(fs::read_to_string(&f).unwrap(), "0\n", "the kernel kept turbo on: no_turbo reads 0");
        let other = Faults::parse("epp:eio").unwrap();
        Writer::new(&roots, &other).write("turbo", Class::Turbo, &f, "1").unwrap();
        assert_eq!(fs::read_to_string(&f).unwrap(), "1\n", "a fault on another knob does nothing");
        let _ = fs::remove_dir_all(&d);
    }
}
