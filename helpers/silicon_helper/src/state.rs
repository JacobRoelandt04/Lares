//! The helper's own state under `/var/lib/silicon`: four small JSON files, written atomically
//! (temp file in the same directory, fsync, rename, fsync of the directory) and only while
//! holding the one flock. Readers (`status` runs unprivileged) take no lock: a rename is
//! atomic, they see the old file or the new one, never half of either.

use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::thread::sleep;
use std::time::{Duration, Instant};

use crate::fsx::{self, parse_decimal_uw, watts_text};
use crate::json::{self, Json};
use crate::knobs::Knob;
use crate::sys::O_NOFOLLOW;

pub const CAPS_FILE: &str = "firmware_caps.json";
pub const BOOT_FILE: &str = "boot.json";
pub const MUX_FILE: &str = "mux.json";
pub const MARK_FILE: &str = "boot_applied.json";
const LOCK_FILE: &str = ".lock";
/// The only files `write_atomic` will create.
const FILES: [&str; 4] = [CAPS_FILE, BOOT_FILE, MUX_FILE, MARK_FILE];
const LOCK_WAIT: Duration = Duration::from_secs(10);

// ---------------------------------------------------------------- records

/// How the panel is wired: the Intel GPU drives it (`hybrid`) or the NVIDIA one (`dgpu`).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Wiring {
    Hybrid,
    Dgpu,
}

impl Wiring {
    pub fn as_str(self) -> &'static str {
        match self {
            Wiring::Hybrid => "hybrid",
            Wiring::Dgpu => "dgpu",
        }
    }

    pub fn parse(s: &str) -> Option<Wiring> {
        match s {
            "hybrid" => Some(Wiring::Hybrid),
            "dgpu" => Some(Wiring::Dgpu),
            _ => None,
        }
    }

    /// `gpu_mux_mode`: 1 is hybrid, 0 is dgpu.
    pub fn mux_value(self) -> &'static str {
        match self {
            Wiring::Hybrid => "1",
            Wiring::Dgpu => "0",
        }
    }

    pub fn from_mux_value(s: &str) -> Option<Wiring> {
        match s {
            "1" => Some(Wiring::Hybrid),
            "0" => Some(Wiring::Dgpu),
            _ => None,
        }
    }
}

fn only_keys(v: &Json, allowed: &[&str]) -> Result<(), String> {
    match v {
        Json::Obj(pairs) => match pairs.iter().find(|(k, _)| !allowed.contains(&k.as_str())) {
            Some((k, _)) => Err(format!("unknown key '{k}'")),
            None => Ok(()),
        },
        _ => Err("not an object".into()),
    }
}

fn field<'a>(v: &'a Json, key: &str) -> Result<&'a Json, String> {
    v.get(key).ok_or_else(|| format!("missing '{key}'"))
}

fn str_field<'a>(v: &'a Json, key: &str) -> Result<&'a str, String> {
    field(v, key)?.as_str().ok_or_else(|| format!("'{key}' is not a string"))
}

fn uint_field(v: &Json, key: &str) -> Result<u64, String> {
    let i = field(v, key)?.as_i64().ok_or_else(|| format!("'{key}' is not an integer"))?;
    u64::try_from(i).map_err(|_| format!("'{key}' is negative"))
}

/// One RAPL zone's limits as the firmware left them, in microwatts (written as watts, like `status`).
#[derive(Clone, Debug, PartialEq)]
pub struct ZoneCaps {
    pub pl1_uw: u64,
    pub pl2_uw: u64,
}

/// `firmware_caps.json`: what the firmware's limits were at this boot, before anything was
/// written. Valid only for the boot it names.
#[derive(Clone, Debug, PartialEq)]
pub struct CapsRecord {
    pub boot_id: String,
    pub msr: Option<ZoneCaps>,
    pub mmio: Option<ZoneCaps>,
}

impl CapsRecord {
    fn zone_json(z: &Option<ZoneCaps>) -> Json {
        match z {
            None => Json::Null,
            Some(z) => {
                Json::obj([("pl1W", Json::Num(watts_text(z.pl1_uw))), ("pl2W", Json::Num(watts_text(z.pl2_uw)))])
            }
        }
    }

    /// Watts as a JSON number (`45`, `45.5`), exactly, as microwatts.
    fn watts_field(v: &Json, key: &str) -> Result<u64, String> {
        match field(v, key)? {
            Json::Int(i) => u64::try_from(*i)
                .ok()
                .and_then(|w| w.checked_mul(1_000_000))
                .ok_or_else(|| format!("'{key}' is not a number of watts")),
            Json::Num(text) => parse_decimal_uw(text, 6, 6).ok_or_else(|| format!("'{key}' is not a number of watts")),
            _ => Err(format!("'{key}' is not a number of watts")),
        }
    }

    fn zone_from(v: &Json, key: &str) -> Result<Option<ZoneCaps>, String> {
        let z = field(v, key)?;
        if z.is_null() {
            return Ok(None);
        }
        only_keys(z, &["pl1W", "pl2W"])?;
        Ok(Some(ZoneCaps { pl1_uw: CapsRecord::watts_field(z, "pl1W")?, pl2_uw: CapsRecord::watts_field(z, "pl2W")? }))
    }

    pub fn to_json(&self) -> Json {
        Json::obj([
            ("bootId", Json::str(self.boot_id.as_str())),
            ("msr", CapsRecord::zone_json(&self.msr)),
            ("mmio", CapsRecord::zone_json(&self.mmio)),
        ])
    }

    pub fn from_json(v: &Json) -> Result<CapsRecord, String> {
        only_keys(v, &["bootId", "msr", "mmio"])?;
        Ok(CapsRecord {
            boot_id: str_field(v, "bootId")?.to_string(),
            msr: CapsRecord::zone_from(v, "msr")?,
            mmio: CapsRecord::zone_from(v, "mmio")?,
        })
    }
}

/// `boot.json`: what `boot-apply` applies -- the `apply` arguments as typed, and the stored
/// charge limit.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct BootSet {
    pub apply: Vec<(String, String)>,
    pub charge_limit: Option<u32>,
}

impl BootSet {
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("version", Json::Int(1)),
            ("apply", Json::Obj(self.apply.iter().map(|(k, v)| (k.clone(), Json::str(v.as_str()))).collect())),
            ("chargeLimit", self.charge_limit.map_or(Json::Null, |n| Json::Int(i64::from(n)))),
        ])
    }

    pub fn from_json(v: &Json) -> Result<BootSet, String> {
        only_keys(v, &["version", "apply", "chargeLimit"])?;
        if field(v, "version")?.as_i64() != Some(1) {
            return Err("unknown version".into());
        }
        let mut apply = Vec::new();
        match field(v, "apply")? {
            Json::Obj(pairs) => {
                for (k, val) in pairs {
                    if Knob::from_arg(k).is_none() {
                        return Err(format!("unknown apply argument '{k}'"));
                    }
                    let s = val.as_str().ok_or_else(|| format!("'{k}' is not a string"))?;
                    apply.push((k.clone(), s.to_string()));
                }
            }
            _ => return Err("'apply' is not an object".into()),
        }
        let charge_limit = match field(v, "chargeLimit")? {
            Json::Null => None,
            Json::Int(80) => Some(80),
            Json::Int(100) => Some(100),
            _ => return Err("'chargeLimit' is neither null, 80 nor 100".into()),
        };
        Ok(BootSet { apply, charge_limit })
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MuxState {
    Queued,
    Applied,
    AwaitingKeep,
    Kept,
    Reverted,
    Cancelled,
    Failed,
}

impl MuxState {
    pub fn as_str(self) -> &'static str {
        match self {
            MuxState::Queued => "queued",
            MuxState::Applied => "applied",
            MuxState::AwaitingKeep => "awaiting-keep",
            MuxState::Kept => "kept",
            MuxState::Reverted => "reverted",
            MuxState::Cancelled => "cancelled",
            MuxState::Failed => "failed",
        }
    }

    pub fn parse(s: &str) -> Option<MuxState> {
        [
            MuxState::Queued,
            MuxState::Applied,
            MuxState::AwaitingKeep,
            MuxState::Kept,
            MuxState::Reverted,
            MuxState::Cancelled,
            MuxState::Failed,
        ]
        .into_iter()
        .find(|s2| s2.as_str() == s)
    }
}

/// `mux.json`, also `status.mux.record`.
///
/// The three deadline fields are null unless the record is `awaiting-keep`. `deadline_ms` is the
/// hard deadline as WALL-CLOCK milliseconds: for the shell's countdown, never for a decision. The
/// guard decides on the pair `deadline_boot_id` / `deadline_uptime_ms`: the boot the deadline
/// counts in, and the deadline as milliseconds SINCE THAT BOOT (`/proc/uptime`). A wall clock
/// steps early in a boot when NTP corrects it; time since boot does not.
#[derive(Clone, Debug, PartialEq)]
pub struct MuxRecord {
    pub want: Wiring,
    pub from: Wiring,
    pub state: MuxState,
    pub why: String,
    pub requested_at_ms: u64,
    pub boot_id: String,
    pub deadline_ms: Option<u64>,
    pub deadline_boot_id: Option<String>,
    pub deadline_uptime_ms: Option<u64>,
}

impl MuxRecord {
    /// No deadline: what every state but `awaiting-keep` carries.
    pub fn clear_deadline(&mut self) {
        self.deadline_ms = None;
        self.deadline_boot_id = None;
        self.deadline_uptime_ms = None;
    }

    pub fn to_json(&self) -> Json {
        let int = |n: u64| Json::Int(i64::try_from(n).unwrap_or(i64::MAX));
        Json::obj([
            ("want", Json::str(self.want.as_str())),
            ("from", Json::str(self.from.as_str())),
            ("state", Json::str(self.state.as_str())),
            ("why", Json::str(self.why.as_str())),
            ("requestedAtMs", int(self.requested_at_ms)),
            ("bootId", Json::str(self.boot_id.as_str())),
            ("deadlineMs", self.deadline_ms.map_or(Json::Null, int)),
            ("deadlineBootId", Json::opt_str(self.deadline_boot_id.as_deref())),
            ("deadlineUptimeMs", self.deadline_uptime_ms.map_or(Json::Null, int)),
        ])
    }

    /// Strict: exactly the protocol's keys, each of its type. The deadline keys may be null; a record
    /// written before the boot/uptime pair existed (without those two keys) reads as having no pair.
    pub fn from_json(v: &Json) -> Result<MuxRecord, String> {
        only_keys(
            v,
            &[
                "want",
                "from",
                "state",
                "why",
                "requestedAtMs",
                "bootId",
                "deadlineMs",
                "deadlineBootId",
                "deadlineUptimeMs",
            ],
        )?;
        let wiring =
            |key: &str| Wiring::parse(str_field(v, key)?).ok_or_else(|| format!("'{key}' is not hybrid or dgpu"));
        let deadline_ms = match field(v, "deadlineMs")? {
            Json::Null => None,
            _ => Some(uint_field(v, "deadlineMs")?),
        };
        let deadline_boot_id = match v.get("deadlineBootId") {
            None | Some(Json::Null) => None,
            Some(Json::Str(s)) => Some(s.clone()),
            Some(_) => return Err("'deadlineBootId' is not a string".into()),
        };
        let deadline_uptime_ms = match v.get("deadlineUptimeMs") {
            None | Some(Json::Null) => None,
            Some(_) => Some(uint_field(v, "deadlineUptimeMs")?),
        };
        Ok(MuxRecord {
            want: wiring("want")?,
            from: wiring("from")?,
            state: MuxState::parse(str_field(v, "state")?).ok_or("unknown state")?,
            why: str_field(v, "why")?.to_string(),
            requested_at_ms: uint_field(v, "requestedAtMs")?,
            boot_id: str_field(v, "bootId")?.to_string(),
            deadline_ms,
            deadline_boot_id,
            deadline_uptime_ms,
        })
    }
}

/// `boot_applied.json`: `boot-apply` has run in this boot, and whether all of it landed.
#[derive(Clone, Debug, PartialEq)]
pub struct BootMark {
    pub boot_id: String,
    pub at_ms: u64,
    pub ok: bool,
}

impl BootMark {
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("bootId", Json::str(self.boot_id.as_str())),
            ("atMs", Json::Int(i64::try_from(self.at_ms).unwrap_or(i64::MAX))),
            ("ok", Json::Bool(self.ok)),
        ])
    }

    pub fn from_json(v: &Json) -> Result<BootMark, String> {
        only_keys(v, &["bootId", "atMs", "ok"])?;
        let ok = match field(v, "ok")? {
            Json::Bool(b) => *b,
            _ => return Err("'ok' is not a boolean".into()),
        };
        Ok(BootMark { boot_id: str_field(v, "bootId")?.to_string(), at_ms: uint_field(v, "atMs")?, ok })
    }
}

// ---------------------------------------------------------------- files

/// Read access to the state directory (no lock).
#[derive(Clone, Debug)]
pub struct State {
    dir: Option<PathBuf>,
}

impl State {
    pub fn new(dir: Option<PathBuf>) -> State {
        State { dir }
    }

    /// `Ok(None)` when there is no state directory or no such file; `Err` when the file is
    /// there and not understood (it is never guessed at, and never overwritten silently).
    fn load<T>(&self, name: &str, parse: fn(&Json) -> Result<T, String>) -> Result<Option<T>, String> {
        let Some(dir) = &self.dir else { return Ok(None) };
        let path = dir.join(name);
        match fs::symlink_metadata(&path) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(format!("{}: {e}", path.display())),
            Ok(_) => {}
        }
        let text = fsx::read_text(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        let doc = json::parse(&text).map_err(|e| format!("{} is not understood: {e}", path.display()))?;
        parse(&doc).map(Some).map_err(|e| format!("{} is not understood: {e}", path.display()))
    }

    pub fn caps(&self) -> Result<Option<CapsRecord>, String> {
        self.load(CAPS_FILE, CapsRecord::from_json)
    }

    pub fn boot_set(&self) -> Result<Option<BootSet>, String> {
        self.load(BOOT_FILE, BootSet::from_json)
    }

    pub fn mux(&self) -> Result<Option<MuxRecord>, String> {
        self.load(MUX_FILE, MuxRecord::from_json)
    }

    pub fn mark(&self) -> Result<Option<BootMark>, String> {
        self.load(MARK_FILE, BootMark::from_json)
    }

    /// Create the directory if needed and take the one lock. Waits up to ten seconds.
    pub fn lock(&self) -> Result<Locked, String> {
        let dir = self.dir.clone().ok_or("test mode needs --state-dir for anything that writes")?;
        if !dir.is_dir() {
            DirBuilder::new()
                .recursive(true)
                .mode(0o755)
                .create(&dir)
                .map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
        }
        let path = dir.join(LOCK_FILE);
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(O_NOFOLLOW)
            .open(&path)
            .map_err(|e| format!("cannot open {}: {e}", path.display()))?;
        let start = Instant::now();
        loop {
            match file.try_lock() {
                Ok(()) => return Ok(Locked { _file: file, dir }),
                Err(fs::TryLockError::WouldBlock) => {
                    if start.elapsed() >= LOCK_WAIT {
                        return Err(format!("{} is locked by another silicon-helper", path.display()));
                    }
                    sleep(Duration::from_millis(20));
                }
                Err(fs::TryLockError::Error(e)) => return Err(format!("cannot lock {}: {e}", path.display())),
            }
        }
    }
}

/// Proof that the lock is held; the only way to write a state file. Dropping it releases it.
pub struct Locked {
    _file: File,
    dir: PathBuf,
}

impl Locked {
    fn write_atomic(&self, name: &str, doc: &Json) -> io::Result<()> {
        if !FILES.contains(&name) {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "not a state file of this helper"));
        }
        atomic_write(&self.dir, name, doc)
    }

    pub fn write_caps(&self, r: &CapsRecord) -> io::Result<()> {
        self.write_atomic(CAPS_FILE, &r.to_json())
    }

    pub fn write_boot_set(&self, s: &BootSet) -> io::Result<()> {
        self.write_atomic(BOOT_FILE, &s.to_json())
    }

    pub fn write_mux(&self, r: &MuxRecord) -> io::Result<()> {
        self.write_atomic(MUX_FILE, &r.to_json())
    }

    pub fn write_mark(&self, m: &BootMark) -> io::Result<()> {
        self.write_atomic(MARK_FILE, &m.to_json())
    }
}

/// Temp file in `dir`, fsync, rename over `name`, fsync of the directory: a reader sees the old file or
/// the new one, never half of either.
fn atomic_write(dir: &Path, name: &str, doc: &Json) -> io::Result<()> {
    let tmp = dir.join(format!(".{name}.tmp"));
    let dest = dir.join(name);
    match fs::remove_file(&tmp) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    let mut f = OpenOptions::new().write(true).create_new(true).mode(0o644).open(&tmp)?;
    let result = (|| {
        f.set_permissions(fs::Permissions::from_mode(0o644))?;
        let mut text = doc.render();
        text.push('\n');
        f.write_all(text.as_bytes())?;
        f.sync_all()?;
        drop(f);
        fs::rename(&tmp, &dest)?;
        File::open(dir)?.sync_all()
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

// ---------------------------------------------------------------- the interaction boost's run directory

/// `<run>/lares-boost/`: the boost server's socket and its record of the values it must put back. On the real
/// machine systemd makes it (`RuntimeDirectory=lares-boost`, root 0755, kept across restarts so a record left by a
/// killed server is found by the next start and by `boost-restore`).
pub struct BoostDir {
    dir: PathBuf,
}

pub const BOOST_DIR: &str = "lares-boost";
const BOOST_RECORD: &str = "record.json";
const BOOST_SOCKET: &str = "sock";

impl BoostDir {
    /// The directory under `run`, made (0755) if it is not there; a symlink in its place is refused.
    pub fn open(run: &Path) -> Result<BoostDir, String> {
        let dir = run.join(BOOST_DIR);
        match fs::symlink_metadata(&dir) {
            Ok(m) if m.is_dir() => {}
            Ok(_) => return Err(format!("{} is not a directory", dir.display())),
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                DirBuilder::new()
                    .mode(0o755)
                    .create(&dir)
                    .map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
            }
            Err(e) => return Err(format!("{}: {e}", dir.display())),
        }
        Ok(BoostDir { dir })
    }

    pub fn socket_path(&self) -> PathBuf {
        self.dir.join(BOOST_SOCKET)
    }

    /// The record, `Ok(None)` when there is none; `Err` when it is there and not understood.
    pub fn read_record(&self) -> Result<Option<Json>, String> {
        let path = self.dir.join(BOOST_RECORD);
        match fs::symlink_metadata(&path) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(format!("{}: {e}", path.display())),
            Ok(m) if !m.is_file() => return Err(format!("{} is not a plain file", path.display())),
            Ok(_) => {}
        }
        let text = fsx::read_text(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        json::parse(&text).map(Some).map_err(|e| format!("{} is not understood: {e}", path.display()))
    }

    pub fn write_record(&self, doc: &Json) -> io::Result<()> {
        atomic_write(&self.dir, BOOST_RECORD, doc)
    }

    pub fn remove_record(&self) -> io::Result<()> {
        match fs::remove_file(self.dir.join(BOOST_RECORD)) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
            _ => Ok(()),
        }
    }

    /// Before a bind: a socket left by an earlier server goes; anything else at that name is refused.
    pub fn clear_socket(&self) -> io::Result<()> {
        let path = self.socket_path();
        match fs::symlink_metadata(&path) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e),
            Ok(m) if m.file_type().is_socket() => fs::remove_file(&path),
            Ok(_) => {
                Err(io::Error::new(io::ErrorKind::AlreadyExists, "something that is not a socket is in its place"))
            }
        }
    }

    /// After a bind: the socket is the session user's alone (0600, owned by `uid`). The peer check at every
    /// connection is the second lock on the same door.
    pub fn own_socket(&self, uid: Option<u32>) -> io::Result<()> {
        let path = self.socket_path();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        match uid {
            Some(uid) => std::os::unix::fs::chown(&path, Some(uid), None),
            None => Ok(()),
        }
    }

    pub fn remove_socket(&self) {
        let _ = self.clear_socket();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("sh-state-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        d
    }

    fn mux() -> MuxRecord {
        MuxRecord {
            want: Wiring::Dgpu,
            from: Wiring::Hybrid,
            state: MuxState::AwaitingKeep,
            why: "a \"quoted\" why\nwith a newline".into(),
            requested_at_ms: 1_759_500_000_000,
            boot_id: "abc".into(),
            deadline_ms: Some(1_759_500_300_000),
            deadline_boot_id: Some("def".into()),
            deadline_uptime_ms: Some(300_000),
        }
    }

    #[test]
    fn records_round_trip() {
        let m = mux();
        assert_eq!(MuxRecord::from_json(&json::parse(&m.to_json().render()).unwrap()), Ok(m));
        let c = CapsRecord {
            boot_id: "b".into(),
            msr: Some(ZoneCaps { pl1_uw: 65_000_000, pl2_uw: 115_000_000 }),
            mmio: None,
        };
        assert_eq!(CapsRecord::from_json(&json::parse(&c.to_json().render()).unwrap()), Ok(c));
        let s = BootSet {
            apply: vec![("profile".into(), "quiet".into()), ("pl1_w".into(), "firmware".into())],
            charge_limit: Some(80),
        };
        assert_eq!(BootSet::from_json(&json::parse(&s.to_json().render()).unwrap()), Ok(s));
        let k = BootMark { boot_id: "b".into(), at_ms: 5, ok: false };
        assert_eq!(BootMark::from_json(&json::parse(&k.to_json().render()).unwrap()), Ok(k));
    }

    #[test]
    fn mux_record_wire_shape_is_the_protocols() {
        let mut m = mux();
        m.state = MuxState::Queued;
        m.clear_deadline();
        m.why = String::new();
        assert_eq!(
            m.to_json().render(),
            r#"{"want":"dgpu","from":"hybrid","state":"queued","why":"","requestedAtMs":1759500000000,"bootId":"abc","deadlineMs":null,"deadlineBootId":null,"deadlineUptimeMs":null}"#
        );
        let m = mux();
        assert_eq!(
            m.to_json().render(),
            r#"{"want":"dgpu","from":"hybrid","state":"awaiting-keep","why":"a \"quoted\" why\nwith a newline","requestedAtMs":1759500000000,"bootId":"abc","deadlineMs":1759500300000,"deadlineBootId":"def","deadlineUptimeMs":300000}"#,
            "awaiting-keep carries the wall deadline (for the countdown) and the guard's own: the boot and the ms since it"
        );
    }

    #[test]
    fn the_two_deadline_keys_are_accepted_optional_and_typed() {
        let base = |tail: &str| {
            format!(
                r#"{{"want":"dgpu","from":"hybrid","state":"awaiting-keep","why":"","requestedAtMs":1,"bootId":"b","deadlineMs":5{tail}}}"#
            )
        };
        let read = |tail: &str| json::parse(&base(tail)).and_then(|j| MuxRecord::from_json(&j));
        // both keys, with values
        let r = read(r#","deadlineBootId":"x","deadlineUptimeMs":300000"#).unwrap();
        assert_eq!((r.deadline_boot_id.as_deref(), r.deadline_uptime_ms), (Some("x"), Some(300_000)));
        // both null, or absent (a record from before the pair existed): no pair
        for tail in [r#","deadlineBootId":null,"deadlineUptimeMs":null"#, ""] {
            let r = read(tail).unwrap();
            assert_eq!((r.deadline_boot_id, r.deadline_uptime_ms), (None, None), "{tail:?}");
        }
        // each alone is read as it is (the guard treats half a pair as no pair)
        assert_eq!(read(r#","deadlineUptimeMs":7"#).unwrap().deadline_uptime_ms, Some(7));
        assert_eq!(read(r#","deadlineBootId":"x""#).unwrap().deadline_boot_id.as_deref(), Some("x"));
        // wrong types and unknown keys are refused
        for tail in [
            r#","deadlineBootId":5"#,
            r#","deadlineBootId":true"#,
            r#","deadlineBootId":["x"]"#,
            r#","deadlineUptimeMs":-1"#,
            r#","deadlineUptimeMs":"300000""#,
            r#","deadlineUptimeMs":1.5"#,
            r#","deadlineUptimeMs":true"#,
            r#","deadlineUptime":1"#,
            r#","deadlineBootID":"x""#,
            r#","deadlineBootId":"x","deadlineUptimeMs":1,"extra":1"#,
        ] {
            assert!(read(tail).is_err(), "must refuse {tail}");
        }
    }

    #[test]
    fn records_refuse_what_they_do_not_understand() {
        let bad_mux = [
            r#"{"want":"dgpu","from":"hybrid","state":"queued","why":"","requestedAtMs":1,"bootId":"b","deadlineMs":null,"extra":1}"#,
            r#"{"want":"gpu","from":"hybrid","state":"queued","why":"","requestedAtMs":1,"bootId":"b","deadlineMs":null}"#,
            r#"{"want":"dgpu","from":"hybrid","state":"nope","why":"","requestedAtMs":1,"bootId":"b","deadlineMs":null}"#,
            r#"{"want":"dgpu","from":"hybrid","state":"queued","why":"","requestedAtMs":-1,"bootId":"b","deadlineMs":null}"#,
            r#"{"want":"dgpu","from":"hybrid","state":"queued","why":"","requestedAtMs":1,"bootId":"b"}"#,
            r#"{"want":"dgpu","from":"hybrid","state":"queued","why":3,"requestedAtMs":1,"bootId":"b","deadlineMs":null}"#,
            "[]",
        ];
        for text in bad_mux {
            let parsed = json::parse(text).and_then(|j| MuxRecord::from_json(&j));
            assert!(parsed.is_err(), "{text}");
        }
        for text in [
            r#"{"version":2,"apply":{},"chargeLimit":null}"#,
            r#"{"version":1,"apply":{"custom":"x"},"chargeLimit":null}"#,
            r#"{"version":1,"apply":{"profile":3},"chargeLimit":null}"#,
            r#"{"version":1,"apply":{},"chargeLimit":90}"#,
        ] {
            let parsed = json::parse(text).and_then(|j| BootSet::from_json(&j));
            assert!(parsed.is_err(), "{text}");
        }
    }

    #[test]
    fn atomic_write_leaves_no_temp_and_replaces_whole() {
        let d = tmp("atomic");
        let st = State::new(Some(d.clone()));
        let lock = st.lock().unwrap();
        lock.write_mux(&mux()).unwrap();
        let mut second = mux();
        second.state = MuxState::Kept;
        lock.write_mux(&second).unwrap();
        assert_eq!(st.mux().unwrap(), Some(second));
        let names = fsx::list_dir(&d);
        assert!(names.iter().all(|n| !n.ends_with(".tmp")), "{names:?}");
        assert!(names.contains(&".lock".to_string()) && names.contains(&"mux.json".to_string()));
        let mode = fs::metadata(d.join("mux.json")).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o644, "readable by the unprivileged `status`");
        assert!(lock.write_atomic("other.json", &Json::Null).is_err(), "only the helper's four files");
        drop(lock);
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn a_stale_temp_file_does_not_block_a_write() {
        let d = tmp("stale");
        let st = State::new(Some(d.clone()));
        let lock = st.lock().unwrap();
        fs::write(d.join(".mux.json.tmp"), "torn").unwrap();
        lock.write_mux(&mux()).unwrap();
        assert_eq!(st.mux().unwrap(), Some(mux()));
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn the_lock_is_exclusive() {
        let d = tmp("lock");
        let st = State::new(Some(d.clone()));
        let first = st.lock().unwrap();
        // a second handle on the same file cannot take it while the first lives
        let f2 = OpenOptions::new().read(true).write(true).open(d.join(".lock")).unwrap();
        assert!(matches!(f2.try_lock(), Err(fs::TryLockError::WouldBlock)));
        drop(first);
        assert!(f2.try_lock().is_ok());
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn the_lock_file_is_never_followed_through_a_symlink() {
        let d = tmp("locklink");
        fs::create_dir_all(&d).unwrap();
        let decoy = d.join("decoy");
        fs::write(&decoy, "keep me").unwrap();
        std::os::unix::fs::symlink(&decoy, d.join(".lock")).unwrap();
        let st = State::new(Some(d.clone()));
        assert!(st.lock().is_err(), "O_NOFOLLOW: a planted link is refused, not opened");
        assert_eq!(fs::read_to_string(&decoy).unwrap(), "keep me");
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn a_corrupt_file_is_an_error_not_an_absence() {
        let d = tmp("corrupt");
        fs::create_dir_all(&d).unwrap();
        let st = State::new(Some(d.clone()));
        assert_eq!(st.mux(), Ok(None));
        fs::write(d.join("mux.json"), "{not json").unwrap();
        assert!(st.mux().is_err());
        let none = State::new(None);
        assert_eq!(none.mux(), Ok(None));
        assert!(none.lock().is_err(), "no state dir, no lock, no write");
        let _ = fs::remove_dir_all(&d);
    }
}
