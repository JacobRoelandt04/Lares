//! Where the helper reads and writes: the real `/sys`, `/proc`, `/dev`, `/usr/lib/modules`,
//! `/run/systemd/units` and `/var/lib/silicon`, or -- in test mode only -- directories standing in for them.

use std::path::{Path, PathBuf};

/// The test options, exactly as given on the command line.
#[derive(Debug, Default, Clone)]
pub struct TestOpts {
    pub sysfs_root: Option<PathBuf>,
    pub proc_root: Option<PathBuf>,
    pub state_dir: Option<PathBuf>,
    pub dev_root: Option<PathBuf>,
    pub modules_root: Option<PathBuf>,
    /// `--run-root <dir>`: holds `run/` (or is the run directory itself), the way proc and dev are given.
    pub run_root: Option<PathBuf>,
}

#[derive(Debug, Clone)]
pub struct Roots {
    /// `/sys` or `<root>/sys`, as the caller will read the paths we report.
    pub sys: PathBuf,
    /// `sys` with every symlink resolved: what a canonical target path must sit under.
    pub sys_canon: PathBuf,
    pub proc_: PathBuf,
    pub dev: PathBuf,
    /// `/usr/lib/modules`, or the test directory itself.
    pub modules: PathBuf,
    /// `/run/systemd/units`, where systemd exports one `invocation:<unit>` link per ACTIVE unit, or the test
    /// directory. `None` in test mode without `--run-root`: the unit is not looked for (a probe that does not
    /// know the option behaves as it always did).
    pub units: Option<PathBuf>,
    /// `/run`, or the test directory (`--run-root`): where the interaction boost keeps its socket and its
    /// record (`<run>/lares-boost/`). `None` in test mode without `--run-root`: the boost refuses to start.
    pub run: Option<PathBuf>,
    /// `/var/lib/silicon`, or the test directory. `None` in test mode without `--state-dir`:
    /// state reads as empty and nothing may be written.
    pub state: Option<PathBuf>,
}

fn absolute(p: &Path) -> Result<PathBuf, String> {
    if p.is_absolute() {
        return Ok(p.to_path_buf());
    }
    let cwd = std::env::current_dir().map_err(|e| format!("cannot find the working directory: {e}"))?;
    Ok(cwd.join(p))
}

impl Roots {
    pub fn real() -> Result<Roots, String> {
        Roots::build(&TestOpts::default(), false)
    }

    pub fn from_test(opts: &TestOpts) -> Result<Roots, String> {
        Roots::build(opts, true)
    }

    fn build(opts: &TestOpts, test: bool) -> Result<Roots, String> {
        // `--sysfs-root <dir>` holds `sys/`; `--proc-root <dir>` and `--dev-root <dir>` hold `proc/` / `dev/` the
        // same way (HELPER_PROTOCOL.md). A directory given for proc or dev that has no such subdirectory IS the
        // proc or dev directory: both readings of the flag work, and no real /proc has a `proc` entry in it.
        let under = |root: &Option<PathBuf>, sub: &str, real: &str, lenient: bool| -> Result<PathBuf, String> {
            match root {
                Some(d) => {
                    let d = absolute(d)?;
                    let inner = d.join(sub);
                    Ok(if lenient && !inner.is_dir() { d } else { inner })
                }
                None => Ok(PathBuf::from(real)),
            }
        };
        let sys = under(&opts.sysfs_root, "sys", "/sys", false)?;
        let sys_canon = sys.canonicalize().map_err(|e| format!("cannot read {}: {e}", sys.display()))?;
        let state = match (&opts.state_dir, test) {
            (Some(d), _) => Some(absolute(d)?),
            (None, false) => Some(PathBuf::from("/var/lib/silicon")),
            (None, true) => None,
        };
        let run = match (&opts.run_root, test) {
            (Some(_), _) => Some(under(&opts.run_root, "run", "/run", true)?),
            (None, false) => Some(PathBuf::from("/run")),
            (None, true) => None,
        };
        let units = run.as_ref().map(|r| r.join("systemd/units"));
        Ok(Roots {
            sys,
            sys_canon,
            proc_: under(&opts.proc_root, "proc", "/proc", true)?,
            dev: under(&opts.dev_root, "dev", "/dev", true)?,
            modules: match &opts.modules_root {
                Some(d) => absolute(d)?,
                None => PathBuf::from("/usr/lib/modules"),
            },
            units,
            run,
            state,
        })
    }

    pub fn sys_path(&self, rel: &str) -> PathBuf {
        self.sys.join(rel)
    }

    pub fn proc_path(&self, rel: &str) -> PathBuf {
        self.proc_.join(rel)
    }

    pub fn dev_path(&self, rel: &str) -> PathBuf {
        self.dev.join(rel)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn real_roots_are_the_real_paths() {
        let r = Roots::real().expect("/sys exists");
        assert_eq!(r.sys, Path::new("/sys"));
        assert_eq!(r.proc_, Path::new("/proc"));
        assert_eq!(r.dev, Path::new("/dev"));
        assert_eq!(r.modules, Path::new("/usr/lib/modules"));
        assert_eq!(r.units.as_deref(), Some(Path::new("/run/systemd/units")));
        assert_eq!(r.run.as_deref(), Some(Path::new("/run")));
        assert_eq!(r.state.as_deref(), Some(Path::new("/var/lib/silicon")));
    }

    #[test]
    fn a_proc_or_dev_root_may_be_the_directory_that_holds_proc_or_the_proc_directory_itself() {
        let d = std::env::temp_dir().join(format!("sh-roots2-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("sys")).unwrap();
        std::fs::create_dir_all(d.join("proc/sys")).unwrap();
        std::fs::create_dir_all(d.join("dev/dri")).unwrap();
        let both = |proc: &str, dev: &str| TestOpts {
            sysfs_root: Some(d.clone()),
            proc_root: Some(d.join(proc)),
            dev_root: Some(d.join(dev)),
            ..TestOpts::default()
        };
        // `<dir>` holds proc/ and dev/ ...
        let a = Roots::from_test(&both("", "")).unwrap();
        assert_eq!((a.proc_.clone(), a.dev.clone()), (d.join("proc"), d.join("dev")));
        // ... or `<dir>` is the proc / dev directory
        let b = Roots::from_test(&both("proc", "dev")).unwrap();
        assert_eq!((b.proc_, b.dev), (d.join("proc"), d.join("dev")));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_run_root_may_be_the_directory_that_holds_run_or_the_run_directory_itself() {
        let d = std::env::temp_dir().join(format!("sh-roots3-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("sys")).unwrap();
        std::fs::create_dir_all(d.join("run/systemd/units")).unwrap();
        let with =
            |run: &str| TestOpts { sysfs_root: Some(d.clone()), run_root: Some(d.join(run)), ..TestOpts::default() };
        let want = Some(d.join("run/systemd/units"));
        assert_eq!(Roots::from_test(&with("")).unwrap().units, want, "<dir> holds run/");
        assert_eq!(Roots::from_test(&with("run")).unwrap().units, want, "<dir> is the run directory");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn test_roots_sit_under_their_directories_and_state_needs_its_own() {
        let d = std::env::temp_dir().join(format!("sh-roots-{}", std::process::id()));
        std::fs::create_dir_all(d.join("sys")).unwrap();
        let opts = TestOpts { sysfs_root: Some(d.clone()), ..TestOpts::default() };
        let r = Roots::from_test(&opts).unwrap();
        assert_eq!(r.sys, d.join("sys"));
        assert_eq!(r.proc_, Path::new("/proc"), "a root not given is the real one (reads only)");
        assert!(r.state.is_none(), "test mode never falls back to /var/lib/silicon");
        assert!(r.units.is_none(), "test mode without --run-root does not look for the unit at all");
        let missing = TestOpts { sysfs_root: Some(d.join("nope")), ..TestOpts::default() };
        assert!(Roots::from_test(&missing).is_err());
        let _ = std::fs::remove_dir_all(&d);
    }
}
