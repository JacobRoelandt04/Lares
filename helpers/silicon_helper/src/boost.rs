//! The interaction boost: while a shell motion runs (a popup opening, the island moving: 0.2 - 0.5 s) the
//! session user's shell asks for a FLOOR under the Intel GPU's frequency and the CPU's performance, and this
//! server puts both back as soon as the asked time is over. A motion that ends before the hardware has clocked up
//! from its rest is the cost it removes (docs/silicon.md, "The interaction boost").
//!
//! Run by systemd as root (`lares-boost.service`: `silicon-helper boost-serve uid=<uid> gpuMhz=<mhz> cpuPct=<pct>`).
//! It listens on `<run>/lares-boost/sock` (0600, owned by that uid) and serves ONE verb, one line:
//!
//!   boost <ms>        50 <= ms <= 2000: raise the floors (or extend the deadline), answer `ok <ms left>`
//!
//! Anything else is answered `refused <why>` and the connection is closed. A peer whose SO_PEERCRED uid is not the
//! configured one is refused at the door. The floors it may write, and nothing else:
//!
//!   gpu   the render GT's minimum frequency of the i915 card that drives the panel (`gt/gt0/rps_min_freq_mhz`
//!         where the kernel has it, else `gt_min_freq_mhz`), raised to `gpuMhz` clamped to [RPn, max]
//!   cpu   intel_pstate's `min_perf_pct` (one global file: every core the compositor may run on), raised to
//!         `cpuPct` (at most 60, and never above max_perf_pct). The profile path never writes it (knobs.rs).
//!
//! A floor already at or above its target is left alone. The values found are written to a record BEFORE the first
//! raise; they are put back when the deadline passes, when the connection that asked closes, on SIGTERM / SIGINT,
//! at the next start (a record a killed server left) and by `boost-restore` (the unit's ExecStopPost). A value is
//! put back only while the file still reads what the boost wrote: if anything else changed it meanwhile, it is left
//! as that writer left it and the record forgets it. Every write goes through the whitelisted door (writer.rs).

use std::io::{ErrorKind, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::fsx::{self, is_prefixed_number, parse_u64};
use crate::json::Json;
use crate::roots::Roots;
use crate::state::BoostDir;
use crate::sys::{self, PollFd, POLLIN};
use crate::whitelist::Class;
use crate::writer::{Faults, Writer};

pub const MIN_MS: u64 = 50;
pub const MAX_MS: u64 = 2000;
pub const CPU_PCT_MAX: u64 = 60;
pub const GPU_MHZ_MIN: u64 = 100;
pub const GPU_MHZ_MAX: u64 = 4000;
const MAX_CLIENTS: usize = 4;
const MAX_LINE: usize = 64;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Which {
    Cpu,
    Gpu,
}

impl Which {
    pub fn name(self) -> &'static str {
        match self {
            Which::Cpu => "cpu",
            Which::Gpu => "gpu",
        }
    }

    fn parse(s: &str) -> Option<Which> {
        match s {
            "cpu" => Some(Which::Cpu),
            "gpu" => Some(Which::Gpu),
            _ => None,
        }
    }

    fn class(self) -> Class {
        match self {
            Which::Cpu => Class::BoostCpuFloor,
            Which::Gpu => Class::BoostGpuFloor,
        }
    }
}

/// `boost-serve`'s arguments: `uid=<n>` (required, not 0), `gpuMhz=<n>` (0 = leave the GPU alone, else
/// 100..=4000, clamped to the card's [RPn, max] at start; default 1600), `cpuPct=<n>` (0 = leave the CPU alone,
/// else 1..=60; default 30).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Config {
    pub uid: u32,
    pub gpu_mhz: u64,
    pub cpu_pct: u64,
}

pub fn parse_args(words: &[String]) -> Result<Config, String> {
    let mut uid = None;
    let mut gpu_mhz = 1600;
    let mut cpu_pct = 30;
    for w in words {
        let (k, v) = w.split_once('=').ok_or_else(|| format!("'{w}' is not key=value"))?;
        let n = parse_u64(v)
            .filter(|_| !v.is_empty() && v.len() <= 7)
            .ok_or_else(|| format!("{k}: '{v}' is not a whole number"))?;
        match k {
            "uid" if uid.is_some() => return Err("uid given twice".into()),
            "uid" => uid = Some(u32::try_from(n).map_err(|_| format!("uid {n} is out of range"))?),
            "gpuMhz" if n == 0 || (GPU_MHZ_MIN..=GPU_MHZ_MAX).contains(&n) => gpu_mhz = n,
            "gpuMhz" => return Err(format!("gpuMhz {n} is outside 0 or {GPU_MHZ_MIN}..={GPU_MHZ_MAX}")),
            "cpuPct" if n <= CPU_PCT_MAX => cpu_pct = n,
            "cpuPct" => return Err(format!("cpuPct {n} is outside 0..={CPU_PCT_MAX}")),
            _ => return Err(format!("unknown argument '{k}' (uid, gpuMhz, cpuPct)")),
        }
    }
    match uid {
        None => Err("boost-serve needs uid=<the session user's uid>".into()),
        Some(0) => Err("the boost is served to a session user, never to root (uid=0)".into()),
        Some(uid) => Ok(Config { uid, gpu_mhz, cpu_pct }),
    }
}

/// A file the boost may raise, and the value it raises it to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Floor {
    pub which: Which,
    pub path: PathBuf,
    pub target: u64,
}

fn read_num(path: &Path) -> Option<u64> {
    fsx::read_opt(path).and_then(|t| parse_u64(t.trim()))
}

/// The i915 cards (`cardN` under class/drm whose PCI device is bound to i915), the one with a connected eDP first.
fn intel_cards(roots: &Roots) -> Vec<PathBuf> {
    let drm = roots.sys_path("class/drm");
    let names = fsx::list_dir(&drm);
    let mut cards: Vec<(bool, String)> = names
        .iter()
        .filter(|n| is_prefixed_number(n, "card"))
        .filter(|n| {
            std::fs::read_link(drm.join(n).join("device/driver"))
                .ok()
                .and_then(|l| l.file_name().map(|f| f == "i915"))
                .unwrap_or(false)
        })
        .map(|n| {
            let panel = names.iter().any(|c| {
                c.strip_prefix(n.as_str()).is_some_and(|r| r.starts_with("-eDP-"))
                    && fsx::read_opt(&drm.join(c).join("status")).as_deref() == Some("connected")
            });
            (!panel, n.clone())
        })
        .collect();
    cards.sort_by_key(|(no_panel, name)| (*no_panel, fsx::natural_key(name)));
    cards.into_iter().map(|(_, n)| drm.join(n)).collect()
}

/// The floors this machine has, for `cfg`, with a line each for the journal.
pub fn find_floors(roots: &Roots, cfg: &Config, notes: &mut Vec<String>) -> Vec<Floor> {
    let mut floors = Vec::new();
    if cfg.gpu_mhz > 0 {
        let found = intel_cards(roots).into_iter().find_map(|card| {
            // the per-GT files where the kernel has them, the card's legacy ones otherwise
            let gt = card.join("gt/gt0");
            let (min, rpn, max) = if gt.join("rps_min_freq_mhz").is_file() {
                (gt.join("rps_min_freq_mhz"), gt.join("rps_RPn_freq_mhz"), gt.join("rps_max_freq_mhz"))
            } else {
                (card.join("gt_min_freq_mhz"), card.join("gt_RPn_freq_mhz"), card.join("gt_max_freq_mhz"))
            };
            let (rpn, max) = (read_num(&rpn)?, read_num(&max)?);
            (min.is_file() && rpn <= max).then(|| Floor {
                which: Which::Gpu,
                target: cfg.gpu_mhz.clamp(rpn, max),
                path: min,
            })
        });
        match found {
            Some(f) => {
                notes.push(format!("gpu floor: {} -> {} MHz while a motion runs", f.path.display(), f.target));
                floors.push(f);
            }
            None => notes.push("gpu floor: no i915 card with a minimum frequency here: the GPU is left alone".into()),
        }
    }
    if cfg.cpu_pct > 0 {
        let min = roots.sys_path("devices/system/cpu/intel_pstate/min_perf_pct");
        let max = read_num(&roots.sys_path("devices/system/cpu/intel_pstate/max_perf_pct"));
        match (min.is_file(), max) {
            (true, Some(max)) => {
                let target = cfg.cpu_pct.min(max);
                notes.push(format!("cpu floor: {} -> {target} % while a motion runs", min.display()));
                floors.push(Floor { which: Which::Cpu, path: min, target });
            }
            _ => {
                notes.push("cpu floor: no intel_pstate min_perf_pct / max_perf_pct here: the CPU is left alone".into())
            }
        }
    }
    floors
}

/// One value the boost wrote, and what it found there before.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Raised {
    which: Which,
    path: PathBuf,
    before: String,
    ours: String,
}

fn record_of(raised: &[Raised]) -> Json {
    let items = raised
        .iter()
        .map(|r| {
            Json::obj([
                ("which", Json::str(r.which.name())),
                ("path", Json::str(r.path.to_string_lossy().into_owned())),
                ("before", Json::str(r.before.as_str())),
                ("ours", Json::str(r.ours.as_str())),
            ])
        })
        .collect();
    Json::obj([("proto", Json::Int(1)), ("floors", Json::Arr(items))])
}

fn parse_record(doc: &Json) -> Result<Vec<Raised>, String> {
    let Some(Json::Arr(items)) = doc.get("floors") else { return Err("no floors list".into()) };
    items
        .iter()
        .map(|it| {
            let s = |k: &str| it.get(k).and_then(Json::as_str).ok_or_else(|| format!("an entry has no {k}"));
            let num =
                |k: &str| s(k).and_then(|v| parse_u64(v).map(|_| v.to_string()).ok_or(format!("{k} is not a number")));
            Ok(Raised {
                which: Which::parse(s("which")?).ok_or("an entry names neither cpu nor gpu")?,
                path: PathBuf::from(s("path")?),
                before: num("before")?,
                ours: num("ours")?,
            })
        })
        .collect()
}

fn read_text(path: &Path) -> Option<String> {
    fsx::read_opt(path).map(|t| t.trim().to_string())
}

/// Put one value back if the file still reads ours; a note either way when it did not.
fn put_back(w: &Writer, r: &Raised, notes: &mut Vec<String>) {
    match read_text(&r.path) {
        Some(now) if now == r.ours => {
            if let Err(e) = w.write(r.which.name(), r.which.class(), &r.path, &r.before) {
                notes.push(format!(
                    "{} floor: could not put {} back in {}: {e}",
                    r.which.name(),
                    r.before,
                    r.path.display()
                ));
            }
        }
        Some(now) => notes.push(format!(
            "{} floor: {} reads {now}, not the boost's {}: someone else changed it, it is left as it is",
            r.which.name(),
            r.path.display(),
            r.ours
        )),
        None => notes.push(format!("{} floor: {} cannot be read: nothing put back", r.which.name(), r.path.display())),
    }
}

/// A record found at start (a server killed before it put the values back), or `boost-restore`: every entry that
/// still reads ours is put back, then the record goes.
pub fn restore_record(w: &Writer, dir: &BoostDir, notes: &mut Vec<String>) -> Result<usize, String> {
    let Some(doc) = dir.read_record()? else { return Ok(0) };
    let raised = parse_record(&doc)?;
    for r in &raised {
        put_back(w, r, notes);
    }
    dir.remove_record().map_err(|e| format!("cannot remove the boost record: {e}"))?;
    Ok(raised.len())
}

/// The floors, what is raised now, and until when.
pub struct Booster<'a> {
    w: Writer<'a>,
    dir: &'a BoostDir,
    floors: Vec<Floor>,
    raised: Vec<Raised>,
    until: Option<Instant>,
    pub notes: Vec<String>,
}

impl<'a> Booster<'a> {
    pub fn new(w: Writer<'a>, dir: &'a BoostDir, floors: Vec<Floor>) -> Booster<'a> {
        Booster { w, dir, floors, raised: Vec::new(), until: None, notes: Vec::new() }
    }

    pub fn deadline(&self) -> Option<Instant> {
        self.until
    }

    #[cfg(test)]
    pub fn is_raised(&self) -> bool {
        !self.raised.is_empty()
    }

    fn save(&mut self) -> bool {
        let r = if self.raised.is_empty() {
            self.dir.remove_record()
        } else {
            self.dir.write_record(&record_of(&self.raised))
        };
        match r {
            Ok(()) => true,
            Err(e) => {
                self.notes.push(format!("cannot write the boost record: {e}"));
                false
            }
        }
    }

    /// Forget every raised value that no longer reads ours (another writer's change stands).
    fn drop_foreign(&mut self) {
        let before = self.raised.len();
        let notes = &mut self.notes;
        self.raised.retain(|r| match read_text(&r.path) {
            Some(now) if now == r.ours => true,
            now => {
                notes.push(format!(
                    "{} floor: {} reads {}, not the boost's {}: someone else changed it, the boost leaves it",
                    r.which.name(),
                    r.path.display(),
                    now.as_deref().unwrap_or("nothing"),
                    r.ours
                ));
                false
            }
        });
        if self.raised.len() != before {
            self.save();
        }
    }

    /// `boost <ms>`: raise (or only extend). Answers the time the floors stay up, from `now`.
    pub fn boost(&mut self, now: Instant, ms: u64) -> u64 {
        let want = now + Duration::from_millis(ms);
        if self.until.is_some() {
            self.drop_foreign();
            self.until = self.until.max(Some(want));
            return self.left(now);
        }
        // what will be raised: every floor below its target; the record first, then the writes
        let mut plan: Vec<Raised> = Vec::new();
        for f in &self.floors {
            match read_text(&f.path).and_then(|t| parse_u64(&t).map(|n| (t, n))) {
                Some((text, n)) if n < f.target => {
                    plan.push(Raised { which: f.which, path: f.path.clone(), before: text, ours: f.target.to_string() })
                }
                Some(_) => {}
                None => self.notes.push(format!("{} floor: {} cannot be read", f.which.name(), f.path.display())),
            }
        }
        self.raised = plan.clone();
        if !self.raised.is_empty() && !self.save() {
            self.raised.clear();
            return 0;
        }
        let mut kept = Vec::new();
        for r in plan {
            if let Err(e) = self.w.write(r.which.name(), r.which.class(), &r.path, &r.ours) {
                self.notes.push(format!("{} floor: cannot raise {}: {e}", r.which.name(), r.path.display()));
                continue;
            }
            // the kernel may store something else (a clamp): what it reads now is what a put-back compares with
            match read_text(&r.path) {
                Some(now) if now == r.before => {}
                Some(now) => kept.push(Raised { ours: now, ..r }),
                None => {}
            }
        }
        if kept != self.raised {
            self.raised = kept;
            self.save();
        }
        self.until = Some(want);
        self.left(now)
    }

    fn left(&self, now: Instant) -> u64 {
        self.until.map_or(0, |u| u64::try_from(u.saturating_duration_since(now).as_millis()).unwrap_or(u64::MAX))
    }

    /// The deadline has passed: put everything back.
    pub fn expire(&mut self, now: Instant) {
        if self.until.is_some_and(|u| u <= now) {
            self.restore();
        }
    }

    /// Put back every value that still reads ours, forget the rest, drop the record.
    pub fn restore(&mut self) {
        let raised = std::mem::take(&mut self.raised);
        for r in &raised {
            put_back(&self.w, r, &mut self.notes);
        }
        self.until = None;
        if !raised.is_empty() {
            self.save();
        }
    }
}

/// One line of the protocol. `Ok(ms)` for a valid boost; `Err((why, close))`.
pub fn parse_line(line: &str) -> Result<u64, (String, bool)> {
    let line = line.strip_suffix('\r').unwrap_or(line);
    let Some(arg) = line.strip_prefix("boost ") else {
        return Err(("the only verb is: boost <ms>".into(), true));
    };
    match parse_u64(arg).filter(|_| !arg.is_empty() && arg.len() <= 5) {
        Some(ms) if (MIN_MS..=MAX_MS).contains(&ms) => Ok(ms),
        Some(ms) => Err((format!("{ms} ms is outside {MIN_MS}..={MAX_MS}"), false)),
        None => Err((format!("'{arg}' is not a whole number of ms"), true)),
    }
}

struct Client {
    stream: UnixStream,
    buf: Vec<u8>,
    id: u64,
}

fn log(line: &str) {
    let _ = writeln!(std::io::stderr().lock(), "silicon-helper: boost: {line}");
}

fn flush_notes(notes: &mut Vec<String>) {
    for n in notes.drain(..) {
        log(&n);
    }
}

/// Read what a client sent; answer each whole line. `false`: the client is done (closed, refused, an error).
fn serve_client(c: &mut Client, booster: &mut Booster, owner: &mut Option<u64>) -> bool {
    let mut chunk = [0u8; 256];
    loop {
        match c.stream.read(&mut chunk) {
            Ok(0) => return false,
            Ok(n) => c.buf.extend_from_slice(chunk.get(..n).unwrap_or(&[])),
            Err(e) if e.kind() == ErrorKind::WouldBlock => break,
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(_) => return false,
        }
    }
    while let Some(at) = c.buf.iter().position(|&b| b == b'\n') {
        let line: Vec<u8> = c.buf.drain(..=at).collect();
        let text = String::from_utf8_lossy(line.get(..at).unwrap_or(&[])).into_owned();
        let (reply, keep) = match parse_line(&text) {
            Ok(ms) => {
                let left = booster.boost(Instant::now(), ms);
                *owner = Some(c.id);
                (format!("ok {left}\n"), true)
            }
            Err((why, close)) => (format!("refused {why}\n"), !close),
        };
        if c.stream.write_all(reply.as_bytes()).is_err() || !keep {
            return false;
        }
    }
    if c.buf.len() > MAX_LINE {
        let _ = c.stream.write_all(b"refused a line is at most 64 bytes\n");
        return false;
    }
    true
}

/// `boost-serve`: bind, serve until SIGTERM / SIGINT, put everything back. Returns the exit code. `chown`: hand the
/// socket to the session user (the real run, as root); a test run cannot give a file away and keeps it its own
/// (0600 either way), so the peer check alone is what refuses another uid there.
pub fn serve(roots: &Roots, faults: &Faults, cfg: &Config, chown: bool) -> (i32, String) {
    let Some(run) = roots.run.as_ref() else {
        return (2, "the boost needs a run directory (--run-root in test mode)".into());
    };
    let dir = match BoostDir::open(run) {
        Ok(d) => d,
        Err(why) => return (3, why),
    };
    sys::catch_term();
    let w = Writer::new(roots, faults);
    let mut notes = Vec::new();
    match restore_record(&w, &dir, &mut notes) {
        Ok(0) => {}
        Ok(n) => notes.push(format!("a record of {n} raised value(s) was left by an earlier server: put back")),
        Err(why) => notes.push(format!("the boost record could not be used: {why}")),
    }
    let floors = find_floors(roots, cfg, &mut notes);
    flush_notes(&mut notes);
    if let Err(e) = dir.clear_socket() {
        return (3, format!("{}: {e}", dir.socket_path().display()));
    }
    let listener = match UnixListener::bind(dir.socket_path()) {
        Ok(l) => l,
        Err(e) => return (3, format!("cannot listen on {}: {e}", dir.socket_path().display())),
    };
    if let Err(e) = dir.own_socket(chown.then_some(cfg.uid)).and_then(|()| listener.set_nonblocking(true)) {
        dir.remove_socket();
        return (3, format!("cannot hand {} to uid {}: {e}", dir.socket_path().display(), cfg.uid));
    }
    log(&format!("serving uid {} on {}", cfg.uid, dir.socket_path().display()));
    let mut booster = Booster::new(Writer::new(roots, faults), &dir, floors);
    let mut clients: Vec<Client> = Vec::new();
    let mut owner: Option<u64> = None;
    let mut next_id: u64 = 0;
    let mut code = 0;
    let mut why = String::new();
    while !sys::term_asked() {
        let timeout = booster.deadline().map_or(-1, |d| {
            let ms = d.saturating_duration_since(Instant::now()).as_millis().saturating_add(1);
            i32::try_from(ms).unwrap_or(i32::MAX)
        });
        let mut fds: Vec<PollFd> = std::iter::once(listener.as_raw_fd())
            .chain(clients.iter().map(|c| c.stream.as_raw_fd()))
            .map(|fd| PollFd { fd, events: POLLIN, revents: 0 })
            .collect();
        match sys::poll_fds(&mut fds, timeout) {
            Ok(_) => {}
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(e) => {
                code = 1;
                why = format!("poll: {e}");
                break;
            }
        }
        booster.expire(Instant::now());
        // the clients first (their fds are the ones polled), then new connections
        let mut done: Vec<u64> = Vec::new();
        for (c, fd) in clients.iter_mut().zip(fds.iter().skip(1)) {
            if fd.revents != 0 && !serve_client(c, &mut booster, &mut owner) {
                done.push(c.id);
            }
        }
        if !done.is_empty() {
            clients.retain(|c| !done.contains(&c.id));
            if owner.is_some_and(|o| done.contains(&o)) {
                owner = None;
                booster.restore(); // the connection that asked is gone: so is the boost
            }
        }
        if fds.first().is_some_and(|f| f.revents != 0) {
            loop {
                let mut stream = match listener.accept() {
                    Ok((s, _)) => s,
                    Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                    Err(_) => break,
                };
                let peer = sys::peer_uid(stream.as_raw_fd());
                if peer != Some(cfg.uid) {
                    let _ = stream.write_all(b"refused not the session user\n");
                    log(&format!("refused a connection from uid {}", peer.map_or("unknown".into(), |u| u.to_string())));
                    continue;
                }
                if clients.len() >= MAX_CLIENTS {
                    let _ = stream.write_all(b"refused too many connections\n");
                    continue;
                }
                if stream.set_nonblocking(true).is_err() {
                    continue;
                }
                next_id = next_id.wrapping_add(1);
                clients.push(Client { stream, buf: Vec::new(), id: next_id });
            }
        }
        flush_notes(&mut booster.notes);
    }
    booster.restore();
    flush_notes(&mut booster.notes);
    dir.remove_socket();
    log(if code == 0 { "stopped; every floor put back" } else { "stopped on an error; every floor put back" });
    (code, why)
}

/// `boost-restore` (the unit's ExecStopPost, after a server that could not put things back itself).
pub fn restore(roots: &Roots, faults: &Faults) -> (i32, String) {
    let Some(run) = roots.run.as_ref() else {
        return (2, "the boost needs a run directory (--run-root in test mode)".into());
    };
    let dir = match BoostDir::open(run) {
        Ok(d) => d,
        Err(why) => return (3, why),
    };
    let w = Writer::new(roots, faults);
    let mut notes = Vec::new();
    let r = restore_record(&w, &dir, &mut notes);
    flush_notes(&mut notes);
    match r {
        Ok(_) => (0, String::new()),
        Err(why) => (1, why),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::symlink;

    fn w(words: &[&str]) -> Vec<String> {
        words.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn arguments() {
        assert_eq!(parse_args(&w(&["uid=1000"])), Ok(Config { uid: 1000, gpu_mhz: 1600, cpu_pct: 30 }));
        assert_eq!(
            parse_args(&w(&["uid=1000", "gpuMhz=0", "cpuPct=0"])),
            Ok(Config { uid: 1000, gpu_mhz: 0, cpu_pct: 0 })
        );
        for bad in [
            &[][..],
            &["uid=0"],
            &["uid=1000", "uid=1000"],
            &["uid=1000", "cpuPct=61"],
            &["uid=1000", "gpuMhz=50"],
            &["uid=1000", "gpuMhz=5000"],
            &["uid=1000", "maxPerf=9"],
            &["uid=1000", "cpuPct=-1"],
            &["uid=x"],
            &["1000"],
        ] {
            assert!(parse_args(&w(bad)).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn lines() {
        assert_eq!(parse_line("boost 300"), Ok(300));
        assert_eq!(parse_line("boost 50\r"), Ok(50));
        assert_eq!(parse_line("boost 2000"), Ok(2000));
        assert!(matches!(parse_line("boost 49"), Err((_, false))));
        assert!(matches!(parse_line("boost 2001"), Err((_, false))));
        for bad in
            ["boost", "boost ", "boost -1", "boost 3e2", "boost 123456", "BOOST 300", "restore", "write /sys/x 1", ""]
        {
            assert!(matches!(parse_line(bad), Err((_, true))), "{bad:?}");
        }
    }

    /// A fake /sys with an i915 card (the per-GT files or the legacy ones) and intel_pstate; the record dir.
    struct World {
        d: PathBuf,
        roots: Roots,
    }

    impl World {
        fn new(tag: &str, per_gt: bool) -> World {
            let d = std::env::temp_dir().join(format!("sh-boost-{tag}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&d);
            let dev = d.join("sys/devices/pci0000:00/0000:00:02.0");
            let card = dev.join("drm/card1");
            fs::create_dir_all(&card).unwrap();
            fs::create_dir_all(d.join("sys/bus/pci/drivers/i915")).unwrap();
            symlink("../../../bus/pci/drivers/i915", dev.join("driver")).unwrap();
            symlink("../..", card.join("device")).unwrap();
            let files = if per_gt {
                fs::create_dir_all(card.join("gt/gt0")).unwrap();
                [
                    ("gt/gt0/rps_min_freq_mhz", "100"),
                    ("gt/gt0/rps_RPn_freq_mhz", "800"),
                    ("gt/gt0/rps_max_freq_mhz", "2350"),
                ]
            } else {
                [("gt_min_freq_mhz", "100"), ("gt_RPn_freq_mhz", "800"), ("gt_max_freq_mhz", "2350")]
            };
            for (f, v) in files {
                fs::write(card.join(f), format!("{v}\n")).unwrap();
            }
            let edp = dev.join("drm/card1-eDP-1");
            fs::create_dir_all(&edp).unwrap();
            fs::write(edp.join("status"), "connected\n").unwrap();
            fs::create_dir_all(d.join("sys/class/drm")).unwrap();
            symlink("../../devices/pci0000:00/0000:00:02.0/drm/card1", d.join("sys/class/drm/card1")).unwrap();
            symlink("../../devices/pci0000:00/0000:00:02.0/drm/card1-eDP-1", d.join("sys/class/drm/card1-eDP-1"))
                .unwrap();
            let ps = d.join("sys/devices/system/cpu/intel_pstate");
            fs::create_dir_all(&ps).unwrap();
            fs::write(ps.join("min_perf_pct"), "8\n").unwrap();
            fs::write(ps.join("max_perf_pct"), "100\n").unwrap();
            fs::create_dir_all(d.join("run")).unwrap();
            let opts =
                crate::roots::TestOpts { sysfs_root: Some(d.clone()), run_root: Some(d.clone()), ..Default::default() };
            let roots = Roots::from_test(&opts).unwrap();
            World { d, roots }
        }
        fn gpu(&self) -> PathBuf {
            let card = self.d.join("sys/devices/pci0000:00/0000:00:02.0/drm/card1");
            if card.join("gt/gt0").is_dir() {
                card.join("gt/gt0/rps_min_freq_mhz")
            } else {
                card.join("gt_min_freq_mhz")
            }
        }
        fn cpu(&self) -> PathBuf {
            self.d.join("sys/devices/system/cpu/intel_pstate/min_perf_pct")
        }
        fn read(p: &Path) -> String {
            fs::read_to_string(p).unwrap().trim().to_string()
        }
        fn floors(&self) -> Vec<Floor> {
            find_floors(&self.roots, &Config { uid: 1000, gpu_mhz: 1600, cpu_pct: 30 }, &mut Vec::new())
        }
    }

    impl Drop for World {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.d);
        }
    }

    #[test]
    fn discovery_prefers_the_per_gt_file_and_clamps_the_target() {
        let wd = World::new("disc", true);
        let f = wd.floors();
        assert_eq!(f.len(), 2);
        assert_eq!((f[0].which, f[0].target), (Which::Gpu, 1600));
        assert!(f[0].path.ends_with("card1/gt/gt0/rps_min_freq_mhz"), "{:?}", f[0].path);
        assert_eq!((f[1].which, f[1].target), (Which::Cpu, 30));
        let lo = find_floors(&wd.roots, &Config { uid: 1, gpu_mhz: 300, cpu_pct: 60 }, &mut Vec::new());
        assert_eq!(lo[0].target, 800, "clamped up to RPn");
        let hi = find_floors(&wd.roots, &Config { uid: 1, gpu_mhz: 4000, cpu_pct: 0 }, &mut Vec::new());
        assert_eq!((hi.len(), hi[0].target), (1, 2350), "clamped down to max; cpuPct 0 leaves the CPU alone");
        fs::write(wd.d.join("sys/devices/system/cpu/intel_pstate/max_perf_pct"), "20\n").unwrap();
        assert_eq!(wd.floors()[1].target, 20, "never above max_perf_pct");
        let legacy = World::new("legacy", false);
        assert!(legacy.floors()[0].path.ends_with("card1/gt_min_freq_mhz"));
    }

    #[test]
    fn a_card_not_on_i915_is_never_a_floor_nor_writable() {
        let wd = World::new("nv", true);
        let dev = wd.d.join("sys/devices/pci0000:00/0000:00:02.0");
        fs::remove_file(dev.join("driver")).unwrap();
        fs::create_dir_all(wd.d.join("sys/bus/pci/drivers/nvidia")).unwrap();
        symlink("../../../bus/pci/drivers/nvidia", dev.join("driver")).unwrap();
        let f = wd.floors();
        assert!(f.iter().all(|f| f.which == Which::Cpu));
        let faults = Faults::none();
        let w = Writer::new(&wd.roots, &faults);
        assert!(w.write("gpu", Class::BoostGpuFloor, &wd.gpu(), "1600").is_err());
        assert_eq!(World::read(&wd.gpu()), "100");
    }

    #[test]
    fn raise_extend_expire_and_put_back() {
        let wd = World::new("cycle", true);
        let dir = BoostDir::open(wd.roots.run.as_ref().unwrap()).unwrap();
        let faults = Faults::none();
        let mut b = Booster::new(Writer::new(&wd.roots, &faults), &dir, wd.floors());
        let t0 = Instant::now();
        assert_eq!(b.boost(t0, 300), 300);
        assert_eq!((World::read(&wd.gpu()), World::read(&wd.cpu())), ("1600".into(), "30".into()));
        assert!(dir.read_record().unwrap().is_some(), "the record holds what to put back");
        // a second ask only moves the deadline (later, never earlier)
        assert_eq!(b.boost(t0 + Duration::from_millis(100), 500), 500);
        assert_eq!(b.boost(t0 + Duration::from_millis(150), 50), 450);
        b.expire(t0 + Duration::from_millis(599));
        assert!(b.is_raised());
        b.expire(t0 + Duration::from_millis(600));
        assert!(!b.is_raised());
        assert_eq!((World::read(&wd.gpu()), World::read(&wd.cpu())), ("100".into(), "8".into()));
        assert!(dir.read_record().unwrap().is_none());
    }

    #[test]
    fn a_floor_already_above_its_target_is_left_alone() {
        let wd = World::new("above", true);
        fs::write(wd.cpu(), "50\n").unwrap();
        let dir = BoostDir::open(wd.roots.run.as_ref().unwrap()).unwrap();
        let faults = Faults::none();
        let mut b = Booster::new(Writer::new(&wd.roots, &faults), &dir, wd.floors());
        let t0 = Instant::now();
        b.boost(t0, 200);
        assert_eq!(World::read(&wd.cpu()), "50");
        b.restore();
        assert_eq!((World::read(&wd.gpu()), World::read(&wd.cpu())), ("100".into(), "50".into()));
    }

    #[test]
    fn a_foreign_change_stands_and_is_never_raised_over() {
        let wd = World::new("foreign", true);
        let dir = BoostDir::open(wd.roots.run.as_ref().unwrap()).unwrap();
        let faults = Faults::none();
        let mut b = Booster::new(Writer::new(&wd.roots, &faults), &dir, wd.floors());
        let t0 = Instant::now();
        b.boost(t0, 300);
        fs::write(wd.cpu(), "50\n").unwrap(); // powertop, the user, ...
        b.boost(t0 + Duration::from_millis(10), 300); // an extension: the CPU entry is forgotten
        fs::write(wd.gpu(), "1200\n").unwrap();
        b.restore();
        assert_eq!((World::read(&wd.gpu()), World::read(&wd.cpu())), ("1200".into(), "50".into()));
        assert!(b.notes.iter().any(|n| n.contains("someone else changed it")), "{:?}", b.notes);
        assert!(dir.read_record().unwrap().is_none());
    }

    #[test]
    fn a_value_other_than_ours_is_never_put_back() {
        let wd = World::new("clamp", true);
        let dir = BoostDir::open(wd.roots.run.as_ref().unwrap()).unwrap();
        let none = Faults::none();
        let mut b = Booster::new(Writer::new(&wd.roots, &none), &dir, wd.floors());
        let t0 = Instant::now();
        b.boost(t0, 300);
        fs::write(wd.cpu(), "25\n").unwrap();
        // 25 is not ours (30): a change by someone else, left
        b.restore();
        assert_eq!(World::read(&wd.cpu()), "25");
    }

    #[test]
    fn a_stale_record_is_put_back_and_only_where_it_still_reads_ours() {
        let wd = World::new("stale", true);
        let dir = BoostDir::open(wd.roots.run.as_ref().unwrap()).unwrap();
        let faults = Faults::none();
        {
            let mut b = Booster::new(Writer::new(&wd.roots, &faults), &dir, wd.floors());
            b.boost(Instant::now(), 2000);
            std::mem::forget(b); // a server killed with the floors up
        }
        fs::write(wd.cpu(), "40\n").unwrap();
        let mut notes = Vec::new();
        let n = restore_record(&Writer::new(&wd.roots, &faults), &dir, &mut notes).unwrap();
        assert_eq!(n, 2);
        assert_eq!((World::read(&wd.gpu()), World::read(&wd.cpu())), ("100".into(), "40".into()));
        assert!(dir.read_record().unwrap().is_none());
        assert_eq!(restore_record(&Writer::new(&wd.roots, &faults), &dir, &mut notes).unwrap(), 0);
    }

    #[test]
    fn a_record_that_names_another_file_writes_nothing() {
        let wd = World::new("evil", true);
        let dir = BoostDir::open(wd.roots.run.as_ref().unwrap()).unwrap();
        let victim = wd.d.join("sys/devices/system/cpu/intel_pstate/max_perf_pct");
        let doc =
            record_of(&[Raised { which: Which::Cpu, path: victim.clone(), before: "1".into(), ours: "100".into() }]);
        dir.write_record(&doc).unwrap();
        let faults = Faults::none();
        let mut notes = Vec::new();
        restore_record(&Writer::new(&wd.roots, &faults), &dir, &mut notes).unwrap();
        assert_eq!(World::read(&victim), "100", "the whitelist refused it: {notes:?}");
        assert!(notes.iter().any(|n| n.contains("could not put")));
    }
}
