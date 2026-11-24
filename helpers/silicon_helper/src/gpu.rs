//! Everything the helper knows about the two GPUs, found rather than assumed: the NVIDIA
//! display device by PCI vendor and class, its nodes from its own sysfs/procfs entries, the
//! panel's wiring from which eDP connector is connected, the iGPU's rc6 counter by driver,
//! the MUX pre-checks, and the plumbing `mux-apply` needs (who holds the card, which NVIDIA
//! modules are loaded and in what order they can go).

use std::fs;
use std::path::{Path, PathBuf};

use crate::fsx::{self, is_prefixed_number, list_dir, read_opt};
use crate::roots::Roots;
use crate::state::Wiring;

const NVIDIA: &str = "0x10de";
const INTEL: &str = "0x8086";

#[derive(Debug, Clone, PartialEq)]
pub struct Dgpu {
    pub pci: String,
    pub card: Option<PathBuf>,
    pub render: Option<PathBuf>,
    pub nvidia: Option<PathBuf>,
    pub power_state: Option<PathBuf>,
}

fn is_pci_address(name: &str) -> bool {
    !name.is_empty() && name.len() <= 16 && name.bytes().all(|b| b.is_ascii_hexdigit() || b == b':' || b == b'.')
}

/// `/dev/dri/<name>` for the first entry of `drm` named `<prefix><digits>`. The kernel names the node
/// (udev creates it from the same entry): nothing is looked for in /dev.
fn dri_node(roots: &Roots, drm: &[String], prefix: &str) -> Option<PathBuf> {
    let name = drm.iter().find(|n| is_prefixed_number(n, prefix))?;
    Some(roots.dev_path(&format!("dri/{name}")))
}

/// The NVIDIA display controller: vendor 0x10de, PCI class 0x03xxxx (VGA or 3D). Its HDA
/// audio function (class 0x0403) is not it.
///
/// `nvidia_node` asks for the card's `/dev/nvidiaN`, which only the NVIDIA driver's own proc entry
/// (`/proc/driver/nvidia/gpus/<pci>/information`, "Device Minor") names. That read goes through the driver's
/// locks, so a driver that is wedged can block it for good: only what reports a status asks for it, and nothing
/// that writes does (`Machine::discover_for_write`).
pub fn find_dgpu(roots: &Roots, nvidia_node: bool) -> Option<Dgpu> {
    let devices = roots.sys_path("bus/pci/devices");
    for pci in list_dir(&devices) {
        if !is_pci_address(&pci) {
            continue;
        }
        let dir = devices.join(&pci);
        let vendor = read_opt(&dir.join("vendor"));
        let class = read_opt(&dir.join("class"));
        if vendor.as_deref() != Some(NVIDIA) || !class.as_deref().is_some_and(|c| c.starts_with("0x03")) {
            continue;
        }
        let drm = list_dir(&dir.join("drm"));
        let card = dri_node(roots, &drm, "card");
        let render = dri_node(roots, &drm, "renderD");
        let nvidia = if nvidia_node {
            read_opt(&roots.proc_path(&format!("driver/nvidia/gpus/{pci}/information")))
                .and_then(|info| {
                    info.lines().find_map(|l| l.strip_prefix("Device Minor:").and_then(|m| fsx::parse_u64(m.trim())))
                })
                .map(|minor| roots.dev_path(&format!("nvidia{minor}")))
        } else {
            None
        };
        let power_state = Some(roots.sys_path(&format!("bus/pci/devices/{pci}/power_state"))).filter(|p| p.exists());
        return Some(Dgpu { pci, card, render, nvidia, power_state });
    }
    None
}

/// Which GPU drives the panel right now: the one whose eDP connector reads `connected`
/// (Intel = hybrid, NVIDIA = dgpu). `None` when neither -- or both -- or a card is neither
/// vendor: never a guess.
pub fn wiring_now(roots: &Roots) -> Option<Wiring> {
    let drm = roots.sys_path("class/drm");
    let mut found: Vec<Wiring> = Vec::new();
    for name in list_dir(&drm) {
        let Some((card, connector)) = name.split_once('-') else { continue };
        if !is_prefixed_number(card, "card") || !connector.starts_with("eDP-") {
            continue;
        }
        if read_opt(&drm.join(&name).join("status")).as_deref() != Some("connected") {
            continue;
        }
        match read_opt(&drm.join(card).join("device/vendor")).as_deref() {
            Some(INTEL) => found.push(Wiring::Hybrid),
            Some(NVIDIA) => found.push(Wiring::Dgpu),
            _ => {}
        }
    }
    let first = *found.first()?;
    found.iter().all(|w| *w == first).then_some(first)
}

/// The iGPU's rc6 residency counter: the first card whose driver is i915.
pub fn rc6_path(roots: &Roots) -> Option<PathBuf> {
    let drm = roots.sys_path("class/drm");
    list_dir(&drm).into_iter().filter(|n| is_prefixed_number(n, "card")).find_map(|card| {
        let driver = fs::read_link(drm.join(&card).join("device/driver")).ok()?;
        if driver.file_name()?.to_str()? != "i915" {
            return None;
        }
        Some(drm.join(&card).join("gt/gt0/rc6_residency_ms")).filter(|p| p.exists())
    })
}

fn has_nvidia_module(kernel_dir: &Path) -> bool {
    ["updates/dkms", "updates", "extramodules", "kernel/drivers/video", "kernel/drivers/video/nvidia"]
        .iter()
        .any(|sub| list_dir(&kernel_dir.join(sub)).iter().any(|n| n == "nvidia.ko" || n.starts_with("nvidia.ko.")))
}

/// A directory under the modules root that is an installed kernel (it carries its image).
fn installed_kernels(roots: &Roots) -> Vec<String> {
    list_dir(&roots.modules)
        .into_iter()
        .filter(|n| !n.starts_with('.'))
        .filter(|n| roots.modules.join(n).join("vmlinuz").is_file() || roots.modules.join(n).join("pkgbase").is_file())
        .collect()
}

/// A switch to dGPU-only wiring leaves the NVIDIA stack as the only thing that can light the
/// panel: it must be loaded now, and a module must be built for EVERY installed kernel (any
/// of them can be the next boot). Returns (ok, what is missing in plain words).
pub fn precheck_mux(roots: &Roots) -> (bool, String) {
    let mut missing: Vec<String> = Vec::new();
    let loaded = read_opt(&roots.proc_path("modules"))
        .is_some_and(|t| t.lines().any(|l| l.split_whitespace().next() == Some("nvidia")));
    if !loaded {
        missing.push("the nvidia module is not loaded".to_string());
    }
    let kernels = installed_kernels(roots);
    if kernels.is_empty() {
        missing.push(format!("no installed kernel found under {}", roots.modules.display()));
    }
    for k in kernels {
        if !has_nvidia_module(&roots.modules.join(&k)) {
            missing.push(format!("no nvidia module is built for kernel {k}"));
        }
    }
    (missing.is_empty(), missing.join("; "))
}

/// The unit whose ExecStop writes a queued MUX change at shutdown.
pub const MUX_UNIT: &str = "silicon-mux.service";

/// Is the unit that writes a queued MUX change at shutdown active? If it is not, whatever is queued now would
/// never be written. (ok, what is wrong in plain words.)
///
/// Cheap enough for every `status` -- one `lstat`, no process, no bus: systemd exports one `invocation:<unit>`
/// symlink (to the unit's invocation id) while a unit is active, and removes it the moment the unit goes inactive
/// or failed (systemd's src/core/unit.c, `unit_notify` and `unit_unlink_state_files`). Checked read-only on this
/// machine (systemd 262): every link in `/run/systemd/units` belonged to an active unit -- this one, a
/// RemainAfterExit oneshot in `exited`, among them, its target equal to `systemctl show -p InvocationID` -- and the
/// inactive silicon-mux-guard.service had none. The link's target is an id, not a path, so the check never
/// follows it.
///
/// systemd calls those files an implementation detail of its journal, so the check fails OPEN where it cannot
/// know: a directory in which no unit at all has a link means systemd is not exporting them (another systemd, a
/// container), and the way back must never be refused because of it. And `None` (test mode, no `--run-root`)
/// does not look.
pub fn mux_unit_check(roots: &Roots) -> (bool, String) {
    let Some(dir) = &roots.units else { return (true, String::new()) };
    if fs::symlink_metadata(dir.join(format!("invocation:{MUX_UNIT}"))).is_ok() {
        return (true, String::new());
    }
    if !list_dir(dir).iter().any(|name| name.starts_with("invocation:")) {
        return (true, String::new());
    }
    (
        false,
        format!(
            "{MUX_UNIT} is not active, so a GPU mode change queued now would never be written at shutdown \
             (sudo systemctl start {MUX_UNIT})"
        ),
    )
}

// ---------------------------------------------------------------- mux-apply plumbing

#[derive(Debug, Clone, PartialEq)]
pub struct Holder {
    pub pid: u32,
    pub comm: String,
}

/// Every device node that keeps the NVIDIA modules in use: all `nvidia*` nodes of the dev
/// root (and `nvidia-caps/*`), plus the dGPU's DRM card and render node.
pub fn gpu_nodes(roots: &Roots, dgpu: Option<&Dgpu>) -> Vec<PathBuf> {
    let mut nodes: Vec<PathBuf> = Vec::new();
    for name in list_dir(&roots.dev).into_iter().filter(|n| n.starts_with("nvidia")) {
        let p = roots.dev.join(&name);
        if p.is_dir() {
            nodes.extend(list_dir(&p).into_iter().map(|n| p.join(n)));
        } else {
            nodes.push(p);
        }
    }
    if let Some(d) = dgpu {
        nodes.extend(d.card.iter().chain(d.render.iter()).cloned());
    }
    nodes
}

/// Processes (other than `own_pid`) with a file descriptor open on one of `nodes`.
pub fn holders(roots: &Roots, nodes: &[PathBuf], own_pid: u32) -> Vec<Holder> {
    let mut found = Vec::new();
    for name in list_dir(&roots.proc_) {
        let Some(pid) = fsx::parse_u64(&name).and_then(|n| u32::try_from(n).ok()) else { continue };
        if pid == own_pid {
            continue;
        }
        let fds = roots.proc_.join(&name).join("fd");
        let Ok(entries) = fs::read_dir(&fds) else { continue };
        let holds = entries.filter_map(Result::ok).any(|e| fs::read_link(e.path()).is_ok_and(|t| nodes.contains(&t)));
        if holds {
            let comm = read_opt(&roots.proc_.join(&name).join("comm")).unwrap_or_else(|| "?".to_string());
            found.push(Holder { pid, comm });
        }
    }
    found
}

/// One line of /proc/modules: `name size refcount dependents state address (flags)`.
#[derive(Debug, Clone, PartialEq)]
pub struct Module {
    pub name: String,
    pub refcnt: u64,
    pub dependents: Vec<String>,
}

pub fn is_nvidia_module(name: &str) -> bool {
    name == "nvidia"
        || name.strip_prefix("nvidia_").is_some_and(|r| {
            !r.is_empty() && r.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
        })
}

/// The loaded NVIDIA kernel modules (`nvidia`, `nvidia_drm`, `nvidia_modeset`, `nvidia_uvm`,
/// `nvidia_peermem`, ...), and nothing else, from the proc root's `modules`.
pub fn nvidia_modules(roots: &Roots) -> Vec<Module> {
    let text = read_opt(&roots.proc_path("modules")).unwrap_or_default();
    text.lines()
        .filter_map(|l| {
            let mut f = l.split_whitespace();
            let name = f.next()?;
            let _size = f.next()?;
            let refcnt = fsx::parse_u64(f.next()?)?;
            let deps = f.next()?;
            is_nvidia_module(name).then(|| Module {
                name: name.to_string(),
                refcnt,
                dependents: deps.split(',').filter(|d| !d.is_empty() && *d != "-").map(str::to_string).collect(),
            })
        })
        .collect()
}

/// The order to unload `mods` in: a module goes after everything that depends on it. Fails
/// when something that is not one of them depends on one of them, or the dependencies loop.
pub fn unload_order(mods: &[Module]) -> Result<Vec<String>, String> {
    let names: Vec<&str> = mods.iter().map(|m| m.name.as_str()).collect();
    for m in mods {
        if let Some(other) = m.dependents.iter().find(|d| !names.contains(&d.as_str())) {
            return Err(format!("{} is in use by {other}", m.name));
        }
    }
    let mut remaining: Vec<&Module> = mods.iter().collect();
    let mut order: Vec<String> = Vec::new();
    while !remaining.is_empty() {
        let (free, rest): (Vec<&Module>, Vec<&Module>) =
            remaining.iter().partition(|m| m.dependents.iter().all(|d| order.contains(d)));
        if free.is_empty() {
            return Err("the NVIDIA modules depend on each other in a loop".into());
        }
        order.extend(free.iter().map(|m| m.name.clone()));
        remaining = rest;
    }
    Ok(order)
}

/// Modules with references from outside the stack (open file descriptors and the like): the
/// count the kernel holds beyond one per dependent. A real `rmmod` refuses these.
pub fn outside_references(mods: &[Module]) -> Vec<(String, u64)> {
    mods.iter()
        .filter_map(|m| {
            let extra = m.refcnt.saturating_sub(u64::try_from(m.dependents.len()).unwrap_or(u64::MAX));
            (extra > 0).then(|| (m.name.clone(), extra))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(name: &str, refcnt: u64, deps: &[&str]) -> Module {
        Module { name: name.into(), refcnt, dependents: deps.iter().map(|d| d.to_string()).collect() }
    }

    #[test]
    fn unload_order_puts_dependents_first() {
        let mods = [
            m("nvidia", 2, &["nvidia_uvm", "nvidia_modeset"]),
            m("nvidia_modeset", 1, &["nvidia_drm"]),
            m("nvidia_uvm", 0, &[]),
            m("nvidia_drm", 0, &[]),
        ];
        let order = unload_order(&mods).unwrap();
        let pos = |n: &str| order.iter().position(|x| x == n).unwrap();
        assert!(pos("nvidia_drm") < pos("nvidia_modeset"));
        assert!(pos("nvidia_modeset") < pos("nvidia"));
        assert!(pos("nvidia_uvm") < pos("nvidia"));
        assert_eq!(order.len(), 4);
        assert!(outside_references(&mods).is_empty());
    }

    #[test]
    fn a_foreign_dependent_or_a_loop_stops_the_unload() {
        assert!(unload_order(&[m("nvidia", 1, &["ib_core"])]).unwrap_err().contains("ib_core"));
        assert!(unload_order(&[m("nvidia_a", 1, &["nvidia_b"]), m("nvidia_b", 1, &["nvidia_a"])]).is_err());
        assert_eq!(unload_order(&[]).unwrap(), Vec::<String>::new());
    }

    #[test]
    fn outside_references_are_what_a_real_rmmod_would_refuse() {
        let mods = [m("nvidia_drm", 3, &[]), m("nvidia", 1, &["nvidia_drm"])];
        assert_eq!(outside_references(&mods), vec![("nvidia_drm".to_string(), 3)]);
    }

    // ---- the unit that writes a queued change

    /// The test directory, removed when the test ends however it ends (a failed assertion included).
    struct Scratch(std::path::PathBuf);

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn units_world(tag: &str, links: &[&str]) -> (Scratch, Roots) {
        use crate::roots::TestOpts;
        let d = std::env::temp_dir().join(format!("sh-gpu-units-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(d.join("sys")).unwrap();
        fs::create_dir_all(d.join("run/systemd/units")).unwrap();
        for unit in links {
            // a dangling link, as systemd's are: the target is an invocation id, not a path
            std::os::unix::fs::symlink(
                "0123456789abcdef0123456789abcdef",
                d.join(format!("run/systemd/units/invocation:{unit}")),
            )
            .unwrap();
        }
        let opts = TestOpts { sysfs_root: Some(d.clone()), run_root: Some(d.clone()), ..TestOpts::default() };
        let roots = Roots::from_test(&opts).unwrap();
        (Scratch(d), roots)
    }

    #[test]
    fn the_unit_is_active_when_systemd_exports_its_invocation_link() {
        let (_dir, roots) = units_world("active", &["dbus-broker.service", "silicon-mux.service"]);
        assert_eq!(mux_unit_check(&roots), (true, String::new()), "a dangling link counts: it is never followed");
    }

    #[test]
    fn the_unit_is_not_active_when_others_have_links_and_it_has_none() {
        let (_dir, roots) = units_world("inactive", &["dbus-broker.service", "silicon-mux-guard.service.d"]);
        let (ok, why) = mux_unit_check(&roots);
        assert!(!ok);
        assert!(why.starts_with("silicon-mux.service is not active") && why.contains("systemctl start"), "{why}");
    }

    #[test]
    fn the_check_cannot_tell_without_a_systemd_that_exports_anything() {
        // no link for any unit, no directory, no look at all (test mode without --run-root): never a refusal
        let (dir, roots) = units_world("blind", &[]);
        assert_eq!(mux_unit_check(&roots), (true, String::new()));
        fs::remove_dir_all(dir.0.join("run")).unwrap();
        assert_eq!(mux_unit_check(&roots), (true, String::new()));
        let mut none = roots.clone();
        none.units = None;
        assert_eq!(mux_unit_check(&none), (true, String::new()));
    }

    #[test]
    fn only_nvidia_modules_are_ever_candidates() {
        for ok in ["nvidia", "nvidia_drm", "nvidia_modeset", "nvidia_uvm", "nvidia_peermem"] {
            assert!(is_nvidia_module(ok), "{ok}");
        }
        for no in ["nvidiafb", "nouveau", "nvidia_", "nvidia-drm", "xnvidia", "nvme", "nvidia_Drm", "snd_hda_intel", ""]
        {
            assert!(!is_nvidia_module(no), "{no}");
        }
    }
}
