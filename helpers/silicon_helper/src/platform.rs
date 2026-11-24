//! Everything that is not a file: asking systemd things, stopping the NVIDIA services,
//! unloading the NVIDIA modules, rebooting. These run ONLY in real mode (euid 0, no test
//! option); in test mode the same calls are simulated from the test roots, and a reboot is a
//! line appended to `SILICON_TEST_REBOOT`. This is the only file that starts a program.

use std::cell::RefCell;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant};

use crate::gpu::{self, is_nvidia_module};
use crate::roots::Roots;

/// The only units `mux-apply` ever stops.
pub const NVIDIA_UNITS: [&str; 2] = ["nvidia-powerd.service", "nvidia-persistenced.service"];

const SYSTEMCTL: &str = "/usr/bin/systemctl";
const IW: &str = "/usr/bin/iw";
const RMMOD: [&str; 4] = ["/usr/bin/rmmod", "/usr/sbin/rmmod", "/sbin/rmmod", "/bin/rmmod"];

/// How long the helper is willing to wait for things; short in test mode.
#[derive(Clone, Copy, Debug)]
pub struct Timing {
    /// `mux-apply`: for the dGPU's users to let go, and for a stopped unit to be down.
    pub drain: Duration,
    /// `mux-guard`: for the panel's wiring to become readable after the boot.
    pub wiring: Duration,
    /// `mux-guard`: between looks at the record.
    pub guard_poll: Duration,
    /// `boot-apply`: for knobs that are not registered yet.
    pub boot_wait: Duration,
    pub boot_poll: Duration,
}

impl Timing {
    pub fn real() -> Timing {
        Timing {
            drain: Duration::from_secs(20),
            wiring: Duration::from_secs(30),
            guard_poll: Duration::from_millis(500),
            boot_wait: Duration::from_secs(30),
            boot_poll: Duration::from_millis(500),
        }
    }

    pub fn test() -> Timing {
        Timing {
            drain: Duration::from_millis(900),
            wiring: Duration::from_millis(600),
            guard_poll: Duration::from_millis(100),
            boot_wait: Duration::from_millis(800),
            boot_poll: Duration::from_millis(50),
        }
    }
}

pub trait Platform {
    fn timing(&self) -> Timing;
    /// Is the system going down? `mux-apply` writes the firmware at shutdown and at no other time.
    fn shutting_down(&self) -> Result<bool, String>;
    /// Stop one of `NVIDIA_UNITS` (if it is running) and wait until it is down.
    fn stop_unit(&self, unit: &str) -> Result<(), String>;
    /// Unload one NVIDIA module (`nvidia`, `nvidia_drm`, ...). Never forced.
    fn unload_module(&self, name: &str) -> Result<(), String>;
    /// Ask for one reboot.
    fn reboot(&self) -> Result<(), String>;
    /// Set a wireless interface's power save and answer what it reads back (`true` = on). The name is already validated.
    fn wifi_power_save(&self, iface: &str, on: bool) -> Result<bool, String>;
}

// ---------------------------------------------------------------- real

pub struct Real;

/// Every program the helper can ever start, as data: this enum is the complete list of its
/// effects outside the files it owns. Nothing is ever forced (`rmmod -f`, `reboot --force`,
/// `--ignore-inhibitors` are not expressible).
#[derive(Debug, Clone, PartialEq)]
pub enum Cmd {
    IsSystemRunning,
    IsActive(String),
    StopNoBlock(String),
    Rmmod(String),
    Reboot,
    /// `iw dev <iface> set power_save on|off`
    IwSet(String, bool),
    /// `iw dev <iface> get power_save`
    IwGet(String),
}

impl Cmd {
    /// The program (absolute path) and its arguments.
    pub fn argv(&self) -> (String, Vec<String>) {
        let ctl = |args: &[&str]| (SYSTEMCTL.to_string(), args.iter().map(|a| a.to_string()).collect::<Vec<_>>());
        match self {
            Cmd::IsSystemRunning => ctl(&["is-system-running"]),
            Cmd::IsActive(unit) => ctl(&["is-active", "--quiet", unit]),
            Cmd::StopNoBlock(unit) => ctl(&["stop", "--no-block", unit]),
            Cmd::Reboot => ctl(&["reboot"]),
            Cmd::IwSet(iface, on) => (
                IW.to_string(),
                ["dev", iface, "set", "power_save", if *on { "on" } else { "off" }]
                    .iter()
                    .map(|a| a.to_string())
                    .collect(),
            ),
            Cmd::IwGet(iface) => {
                (IW.to_string(), ["dev", iface, "get", "power_save"].iter().map(|a| a.to_string()).collect())
            }
            Cmd::Rmmod(module) => {
                (RMMOD.iter().find(|p| Path::new(p).exists()).unwrap_or(&RMMOD[0]).to_string(), vec![module.clone()])
            }
        }
    }

    /// (exit code, stdout, first line of stderr).
    fn run(&self) -> Result<(i32, String, String), String> {
        let (program, args) = self.argv();
        let out = Command::new(&program)
            .args(&args)
            .env_clear()
            .stdin(Stdio::null())
            .output()
            .map_err(|e| format!("cannot run {program}: {e}"))?;
        Ok((
            out.status.code().unwrap_or(-1),
            String::from_utf8_lossy(&out.stdout).trim().to_string(),
            String::from_utf8_lossy(&out.stderr).lines().next().unwrap_or("").trim().to_string(),
        ))
    }
}

fn unit_active(unit: &str) -> bool {
    Cmd::IsActive(unit.to_string()).run().is_ok_and(|(code, _, _)| code == 0)
}

impl Platform for Real {
    fn timing(&self) -> Timing {
        Timing::real()
    }

    fn shutting_down(&self) -> Result<bool, String> {
        let (_, out, _) = Cmd::IsSystemRunning.run()?;
        Ok(out == "stopping")
    }

    fn stop_unit(&self, unit: &str) -> Result<(), String> {
        if !NVIDIA_UNITS.contains(&unit) {
            return Err(format!("{unit} is not a unit this helper stops"));
        }
        if !unit_active(unit) {
            return Ok(());
        }
        let (code, _, err) = Cmd::StopNoBlock(unit.to_string()).run()?;
        if code != 0 {
            return Err(format!("systemctl stop {unit} failed: {err}"));
        }
        let start = Instant::now();
        while unit_active(unit) {
            if start.elapsed() >= Timing::real().drain {
                return Err(format!("{unit} is still running"));
            }
            sleep(Duration::from_millis(200));
        }
        Ok(())
    }

    fn unload_module(&self, name: &str) -> Result<(), String> {
        if !is_nvidia_module(name) {
            return Err(format!("{name} is not an NVIDIA module"));
        }
        let (code, _, err) = Cmd::Rmmod(name.to_string()).run()?;
        if code == 0 {
            Ok(())
        } else {
            Err(format!("rmmod {name}: {err}"))
        }
    }

    fn reboot(&self) -> Result<(), String> {
        let (code, _, err) = Cmd::Reboot.run()?;
        if code == 0 {
            Ok(())
        } else {
            Err(format!("systemctl reboot: {err}"))
        }
    }

    fn wifi_power_save(&self, iface: &str, on: bool) -> Result<bool, String> {
        if !crate::wifi::valid_name(iface) {
            return Err(format!("'{iface}' is not an interface name"));
        }
        let (code, _, err) = Cmd::IwSet(iface.to_string(), on).run()?;
        if code != 0 {
            return Err(format!("iw {iface} set power_save: {err}"));
        }
        let (code, out, err) = Cmd::IwGet(iface.to_string()).run()?;
        if code != 0 {
            return Err(format!("iw {iface} get power_save: {err}"));
        }
        // "Power save: on" / "Power save: off"
        match out.rsplit(':').next().map(str::trim) {
            Some("on") => Ok(true),
            Some("off") => Ok(false),
            _ => Err(format!("iw {iface} get power_save answered '{out}'")),
        }
    }
}

// ---------------------------------------------------------------- test mode

/// Test mode's stand-in: nothing is run. The module table is the proc root's `modules`
/// (a module goes when it has no dependents left and no references from outside the stack,
/// as `rmmod` would decide), and a reboot is a line in `SILICON_TEST_REBOOT`.
pub struct Simulated {
    roots: Roots,
    reboot_file: Option<PathBuf>,
    unloaded: RefCell<Vec<String>>,
    /// The power save each interface was last set to (an interface starts `on`, as NetworkManager leaves it).
    wifi: RefCell<Vec<(String, bool)>>,
}

impl Simulated {
    pub fn new(roots: Roots, reboot_file: Option<PathBuf>) -> Simulated {
        Simulated { roots, reboot_file, unloaded: RefCell::new(Vec::new()), wifi: RefCell::new(Vec::new()) }
    }
}

impl Platform for Simulated {
    fn timing(&self) -> Timing {
        Timing::test()
    }

    fn shutting_down(&self) -> Result<bool, String> {
        Ok(true)
    }

    fn stop_unit(&self, unit: &str) -> Result<(), String> {
        if NVIDIA_UNITS.contains(&unit) {
            Ok(())
        } else {
            Err(format!("{unit} is not a unit this helper stops"))
        }
    }

    fn unload_module(&self, name: &str) -> Result<(), String> {
        if !is_nvidia_module(name) {
            return Err(format!("{name} is not an NVIDIA module"));
        }
        let table = gpu::nvidia_modules(&self.roots);
        let unloaded = self.unloaded.borrow().clone();
        let Some(m) = table.iter().find(|m| m.name == name && !unloaded.contains(&m.name)) else {
            return Err(format!("{name} is not loaded"));
        };
        if let Some(d) = m.dependents.iter().find(|d| !unloaded.contains(d)) {
            return Err(format!("rmmod {name}: in use by {d}"));
        }
        if let Some((_, n)) = gpu::outside_references(std::slice::from_ref(m)).first() {
            return Err(format!("rmmod {name}: in use ({n} references)"));
        }
        self.unloaded.borrow_mut().push(m.name.clone());
        Ok(())
    }

    fn reboot(&self) -> Result<(), String> {
        let Some(file) = &self.reboot_file else {
            return Err("test mode: SILICON_TEST_REBOOT is not set, so no reboot is asked for".to_string());
        };
        let mut f =
            OpenOptions::new().create(true).append(true).open(file).map_err(|e| format!("{}: {e}", file.display()))?;
        writeln!(f, "reboot requested by silicon-helper").map_err(|e| format!("{}: {e}", file.display()))
    }

    fn wifi_power_save(&self, iface: &str, on: bool) -> Result<bool, String> {
        let mut seen = self.wifi.borrow_mut();
        seen.retain(|(name, _)| name != iface);
        seen.push((iface.to_string(), on));
        Ok(on)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_complete_list_of_what_the_helper_can_execute() {
        let argv = |c: Cmd| {
            let (p, a) = c.argv();
            format!("{p} {}", a.join(" "))
        };
        assert_eq!(argv(Cmd::IsSystemRunning), "/usr/bin/systemctl is-system-running");
        assert_eq!(
            argv(Cmd::IsActive("nvidia-powerd.service".into())),
            "/usr/bin/systemctl is-active --quiet nvidia-powerd.service"
        );
        assert_eq!(
            argv(Cmd::StopNoBlock("nvidia-persistenced.service".into())),
            "/usr/bin/systemctl stop --no-block nvidia-persistenced.service"
        );
        assert_eq!(argv(Cmd::Reboot), "/usr/bin/systemctl reboot");
        assert_eq!(argv(Cmd::IwSet("wlp47s0".into(), false)), "/usr/bin/iw dev wlp47s0 set power_save off");
        assert_eq!(argv(Cmd::IwSet("wlp47s0".into(), true)), "/usr/bin/iw dev wlp47s0 set power_save on");
        assert_eq!(argv(Cmd::IwGet("wlp47s0".into())), "/usr/bin/iw dev wlp47s0 get power_save");
        let rmmod = argv(Cmd::Rmmod("nvidia_drm".into()));
        assert!(rmmod.ends_with("rmmod nvidia_drm") && rmmod.starts_with('/'), "{rmmod}");
        // nothing is ever forced
        for c in [Cmd::Reboot, Cmd::Rmmod("nvidia".into()), Cmd::StopNoBlock("nvidia-powerd.service".into())] {
            let (_, args) = c.argv();
            assert!(
                !args.iter().any(|a| matches!(
                    a.as_str(),
                    "-f" | "--force" | "-ff" | "--ignore-inhibitors" | "-i" | "--no-wall"
                )),
                "{args:?}"
            );
        }
    }

    #[test]
    fn the_real_platform_refuses_a_unit_or_module_it_does_not_own_before_running_anything() {
        assert!(Real.stop_unit("sshd.service").unwrap_err().contains("not a unit this helper stops"));
        assert!(Real.stop_unit("../../etc/x").is_err());
        assert!(Real.unload_module("ext4").unwrap_err().contains("not an NVIDIA module"));
        assert!(Real.unload_module("nvidia; reboot").is_err());
        assert!(Real.unload_module("").is_err());
        for bad in ["", "-h", "wl0; reboot", "../x", "wlan0\n"] {
            assert!(Real.wifi_power_save(bad, false).unwrap_err().contains("not an interface name"), "{bad:?}");
        }
    }

    #[test]
    fn the_simulated_platform_runs_nothing_and_a_reboot_needs_its_log() {
        let roots = Roots::real().unwrap();
        let sim = Simulated::new(roots, None);
        assert_eq!(sim.shutting_down(), Ok(true));
        assert!(sim.reboot().unwrap_err().contains("SILICON_TEST_REBOOT"), "without a log nothing is asked for");
        let log = std::env::temp_dir().join(format!("sh-reboot-{}", std::process::id()));
        let _ = std::fs::remove_file(&log);
        let sim = Simulated::new(Roots::real().unwrap(), Some(log.clone()));
        sim.reboot().unwrap();
        sim.reboot().unwrap();
        assert_eq!(std::fs::read_to_string(&log).unwrap().lines().count(), 2);
        let _ = std::fs::remove_file(&log);
    }
}
