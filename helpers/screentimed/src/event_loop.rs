//! The daemon: ONE single-threaded `poll()` over everything that can happen. At rest (away) nothing is
//! armed but the day roll (once a day), so the process sleeps in `poll(-1)` and costs nothing:
//! signalfd (TERM/INT/HUP), the listening socket and its clients, Hyprland's event socket, a
//! CLOCK_REALTIME timerfd for the day roll (absolute, cancelled by a clock step), a CLOCK_MONOTONIC
//! timerfd for the flush / suspend check that is armed ONLY WHILE ACTIVE, a pidfd of the lock pid,
//! and an inotify watch on Hyprland's runtime directory that exists only while no instance answers.

use crate::cal::{Date, LibcCal};
use crate::core::{Cfg, Clocks, Core, Input, Output};
use crate::day::compute_sum;
use crate::digest;
use crate::fg;
use crate::hypr::{self, Ev};
use crate::proto::{self, Feed, Line, LineBuf, Msg, Query, T_FOCUS, T_MONITORS, T_STATE};
use crate::store::{load_config, Store};
use crate::view::View;
use serde_json::json;
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub struct Opts {
    pub data: PathBuf,
    pub socket: PathBuf,
    pub hypr_dir: Option<PathBuf>,
    pub config: PathBuf,
    pub flush_s: Option<u32>,
    pub check_s: Option<u32>,
}

const MAX_CLIENTS: usize = 16;
const MAX_OUT: usize = 4 << 20;
const RETRY_MS: i64 = 200;
const RETRY_MAX: u32 = 25;
const BYE_GRACE_MS: i32 = 300;

pub fn clocks() -> Clocks {
    let get = |id: libc::clockid_t| -> i64 {
        let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        // SAFETY: ts is a valid out pointer.
        unsafe { libc::clock_gettime(id, &mut ts) };
        ts.tv_sec * 1000 + ts.tv_nsec / 1_000_000
    };
    Clocks { wall: get(libc::CLOCK_REALTIME), mono: get(libc::CLOCK_MONOTONIC), boot: get(libc::CLOCK_BOOTTIME) }
}

fn timerfd(clock: libc::clockid_t) -> RawFd {
    // SAFETY: plain syscall.
    unsafe { libc::timerfd_create(clock, libc::TFD_NONBLOCK | libc::TFD_CLOEXEC) }
}

fn ms_spec(ms: i64) -> libc::timespec {
    libc::timespec { tv_sec: ms.div_euclid(1000), tv_nsec: ms.rem_euclid(1000) * 1_000_000 }
}

fn arm(fd: RawFd, first_ms: i64, interval_ms: i64, flags: libc::c_int) {
    let its = libc::itimerspec { it_interval: ms_spec(interval_ms), it_value: ms_spec(first_ms) };
    // SAFETY: its is valid; the old value is not wanted.
    unsafe { libc::timerfd_settime(fd, flags, &its, std::ptr::null_mut()) };
}

/// Reads a timerfd: Ok(true) when it fired, Err on ECANCELED (the wall clock was set).
fn read_timer(fd: RawFd) -> bool {
    let mut n = 0u64;
    // SAFETY: reads 8 bytes into n.
    let r = unsafe { libc::read(fd, (&mut n as *mut u64).cast(), 8) };
    r == 8 || std::io::Error::last_os_error().raw_os_error() == Some(libc::ECANCELED)
}

struct Client {
    stream: UnixStream,
    lines: LineBuf,
    out: Vec<u8>,
    topics: u8,
}

#[derive(Clone, Copy)]
enum Tag {
    Signal,
    Listener,
    Roll,
    Tick,
    Retry,
    Events,
    Inotify,
    Pid,
    Client(usize),
}

struct Daemon {
    core: Core,
    store: Store,
    opts: Opts,
    runtime: PathBuf,
    listener: UnixListener,
    clients: Vec<Client>,
    sig_fd: RawFd,
    roll_fd: RawFd,
    tick_fd: RawFd,
    retry_fd: RawFd,
    ino_fd: RawFd,
    ino_wds: Vec<i32>,
    ev: Option<UnixStream>,
    ev_buf: Vec<u8>,
    hypr_dir: Option<PathBuf>,
    /// The focused window's address (no `0x`), and its process when it is a terminal: the window
    /// whose retitles mean its program may have changed.
    focus_addr: String,
    focus_term: Option<i32>,
    pid: Option<(i32, RawFd)>,
    queue: VecDeque<Input>,
    retries: u32,
    stopping: bool,
}

pub fn default_data() -> PathBuf {
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    data_in(&base)
}

/// The data dir under a data home: `lares/screentime`, and the old name's `quickshell/screentime` only while that is a real directory and
/// the new one does not exist yet (before `lares migrate-name`; after it the old path is a symlink to the new dir and either resolves).
pub fn data_in(base: &Path) -> PathBuf {
    let new = base.join("lares/screentime");
    let old = base.join("quickshell/screentime");
    if !new.exists() && old.is_dir() {
        return old;
    }
    new
}

pub fn default_config() -> PathBuf {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    base.join("quickshell/config/screentime.jsonc")
}

fn load_cfg(opts: &Opts) -> Cfg {
    let mut cfg = load_config(&opts.config);
    if let Some(f) = opts.flush_s {
        cfg.flush_s = f;
    }
    if let Some(c) = opts.check_s {
        cfg.check_s = c;
    }
    cfg
}

fn boot_id() -> String {
    std::fs::read_to_string("/proc/sys/kernel/random/boot_id").map(|s| s.trim().to_string()).unwrap_or_default()
}

/// A `hyprlock` of this user (a one-time scan of `comm`; the wrapper script or the real binary).
fn scan_hyprlock() -> Option<i32> {
    let uid = unsafe { libc::getuid() };
    let mut best: Option<i32> = None;
    for e in std::fs::read_dir("/proc").ok()?.flatten() {
        let Some(pid) = e.file_name().to_str().and_then(|s| s.parse::<i32>().ok()) else { continue };
        let Ok(comm) = std::fs::read_to_string(e.path().join("comm")) else { continue };
        if comm.trim() != "hyprlock" || std::fs::metadata(e.path()).map(|m| m.uid()).ok() != Some(uid) {
            continue;
        }
        best = Some(best.map_or(pid, |b| b.min(pid)));
    }
    best
}

fn bind_socket(path: &Path) -> Result<UnixListener, String> {
    if let Some(dir) = path.parent() {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)
            .map_err(|e| format!("{}: {e}", dir.display()))?;
        // systemd's RuntimeDirectory is 0755 unless told otherwise: the contract says 0700.
        let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    }
    if path.exists() {
        if UnixStream::connect(path).is_ok() {
            return Err(format!("{}: another screentimed answers there", path.display()));
        }
        let _ = std::fs::remove_file(path);
    }
    let l = UnixListener::bind(path).map_err(|e| format!("bind {}: {e}", path.display()))?;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    l.set_nonblocking(true).map_err(|e| e.to_string())?;
    Ok(l)
}

fn signal_fd() -> RawFd {
    // SAFETY: builds a mask, blocks it, opens a signalfd; SIGCHLD ignored so children are reaped by
    // the kernel (the digest's notify-send is never waited on).
    unsafe {
        let mut set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut set);
        for s in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
            libc::sigaddset(&mut set, s);
        }
        libc::sigprocmask(libc::SIG_BLOCK, &set, std::ptr::null_mut());
        libc::signal(libc::SIGCHLD, libc::SIG_IGN);
        libc::signalfd(-1, &set, libc::SFD_NONBLOCK | libc::SFD_CLOEXEC)
    }
}

pub fn run(opts: Opts) -> i32 {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_default();
    if opts.hypr_dir.is_none() && runtime.as_os_str().is_empty() {
        eprintln!("screentimed: XDG_RUNTIME_DIR is not set (needed to find Hyprland)");
        return 2;
    }
    let listener = match bind_socket(&opts.socket) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("screentimed: {e}");
            return 1;
        }
    };
    let cfg = load_cfg(&opts);
    let store = Store::new(&opts.data);
    let core = Core::new(cfg, Box::new(LibcCal::new()));
    let ino_fd = {
        // SAFETY: plain syscall.
        unsafe { libc::inotify_init1(libc::IN_NONBLOCK | libc::IN_CLOEXEC) }
    };
    let mut d = Daemon {
        core,
        store,
        opts,
        runtime,
        listener,
        clients: Vec::new(),
        sig_fd: signal_fd(),
        roll_fd: timerfd(libc::CLOCK_REALTIME),
        tick_fd: timerfd(libc::CLOCK_MONOTONIC),
        retry_fd: timerfd(libc::CLOCK_MONOTONIC),
        ino_fd,
        ino_wds: Vec::new(),
        ev: None,
        ev_buf: Vec::new(),
        focus_addr: String::new(),
        focus_term: None,
        hypr_dir: None,
        pid: None,
        queue: VecDeque::new(),
        retries: 0,
        stopping: false,
    };
    if cfg!(feature = "arm-tick") {
        arm(d.tick_fd, 1000, 1000, 0);
    }
    d.start();
    d.main_loop();
    let _ = std::fs::remove_file(&d.opts.socket);
    0
}

impl Daemon {
    fn start(&mut self) {
        let ck = clocks();
        let date = self.core.date_of(ck.wall);
        let day = self.store.read_day_for_start(date);
        let saved = self.store.read_state();
        let lock_pid = scan_hyprlock()
            .or_else(|| saved.as_ref().and_then(|s| s.lock_pid).filter(|p| Path::new(&format!("/proc/{p}")).exists()));
        self.feed(Input::Start { boot_id: boot_id(), saved, lock_pid, day });
        if !self.try_connect() {
            self.add_watches();
        }
    }

    fn feed(&mut self, input: Input) {
        let ck = clocks();
        let outs = self.core.handle(input, ck);
        self.apply(outs, ck.wall);
    }

    fn view(&self, now: i64) -> View<'_> {
        View { cfg: self.core.cfg(), cal: self.core.calendar(), store: &self.store, core: Some(&self.core), now }
    }

    fn apply(&mut self, outs: Vec<Output>, now: i64) {
        for o in outs {
            match o {
                Output::WriteDay(day) => {
                    let c = day.compacted();
                    let sum = compute_sum(&c, self.core.calendar(), self.core.cfg().day_start_hour);
                    if let Err(e) = self.store.write_day(&c, &sum) {
                        eprintln!("screentimed: writing {}: {e}", c.date);
                    }
                }
                Output::WriteState(s) => {
                    if let Err(e) = self.store.write_state(&s) {
                        eprintln!("screentimed: writing state.json: {e}");
                    }
                }
                Output::PushState => {
                    if self.clients.iter().any(|c| c.topics & T_STATE != 0) {
                        let m = self.view(now).state_push();
                        self.broadcast(T_STATE, &m);
                    }
                }
                Output::PushFocus => {
                    if self.clients.iter().any(|c| c.topics & T_FOCUS != 0) {
                        let m = self.view(now).focus_push();
                        self.broadcast(T_FOCUS, &m);
                    }
                }
                Output::PushMonitors => {
                    if self.clients.iter().any(|c| c.topics & T_MONITORS != 0) {
                        let m = self.view(now).monitors_push();
                        self.broadcast(T_MONITORS, &m);
                    }
                }
                Output::PushDay(date) => {
                    let m = json!({"v": 1, "ev": "day", "date": date.to_string()}).to_string();
                    self.broadcast(T_STATE, &m);
                }
                Output::ArmRoll(at) => {
                    arm(self.roll_fd, at.max(1), 0, libc::TFD_TIMER_ABSTIME | libc::TFD_TIMER_CANCEL_ON_SET)
                }
                Output::ArmTick(on) => {
                    if !cfg!(feature = "arm-tick") {
                        let p = i64::from(self.core.cfg().flush_s.min(self.core.cfg().check_s)) * 1000;
                        if on {
                            arm(self.tick_fd, p, p, 0);
                        } else {
                            arm(self.tick_fd, 0, 0, 0);
                        }
                    }
                }
                Output::WatchPid(pid) => self.watch_pid(pid),
                Output::UnwatchPid => self.unwatch_pid(),
                Output::Digest(week) => self.send_digest(week),
            }
        }
    }

    fn watch_pid(&mut self, pid: i32) {
        if cfg!(feature = "arm-nopidfd") {
            return;
        }
        self.unwatch_pid();
        // SAFETY: pidfd_open takes a pid and flags.
        let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) } as RawFd;
        if fd < 0 {
            // Already gone: the lock it stood for is over.
            self.queue.push_back(Input::LockExited(pid));
        } else {
            self.pid = Some((pid, fd));
        }
    }

    fn unwatch_pid(&mut self) {
        if let Some((_, fd)) = self.pid.take() {
            // SAFETY: fd was opened by watch_pid.
            unsafe { libc::close(fd) };
        }
    }

    fn send_digest(&self, week: Date) {
        let last = self.store.week_agg(week.add_days(-7));
        let before = self.store.week_agg(week.add_days(-14));
        let Some(body) = last.and_then(|l| digest::compose(&l, before.as_ref(), &self.core.cfg().names)) else {
            return;
        };
        let _ = std::process::Command::new("notify-send")
            .args(["-a", "Screentime", "-i", "preferences-desktop-display", "Screen time last week", &body])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }

    // --- clients -------------------------------------------------------------------------------

    fn send(c: &mut Client, bytes: &[u8]) -> bool {
        if c.out.is_empty() {
            match c.stream.write(bytes) {
                Ok(n) if n == bytes.len() => return true,
                Ok(n) => c.out.extend_from_slice(&bytes[n..]),
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => c.out.extend_from_slice(bytes),
                Err(_) => return false,
            }
        } else {
            c.out.extend_from_slice(bytes);
        }
        c.out.len() <= MAX_OUT
    }

    fn broadcast(&mut self, topic: u8, msg: &str) {
        if msg.is_empty() {
            return;
        }
        let line = format!("{msg}\n");
        self.clients.retain_mut(|c| c.topics & topic == 0 || Daemon::send(c, line.as_bytes()));
    }

    fn client_read(&mut self, i: usize) -> bool {
        let mut buf = [0u8; 16384];
        let n = match self.clients[i].stream.read(&mut buf) {
            Ok(0) => return false,
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::Interrupted => {
                return true
            }
            Err(_) => return false,
        };
        let lines = self.clients[i].lines.push(&buf[..n]);
        for l in lines {
            let msg = match l {
                Line::TooLong => Msg::Bad,
                Line::Ok(b) => proto::parse(&b),
            };
            match msg {
                Msg::Blank => {}
                Msg::Bad => self.queue.push_back(Input::Dropped(1)),
                Msg::Feed(f) => self.queue.push_back(match f {
                    Feed::Idle(a) => Input::Idle(a),
                    Feed::Active => Input::Active,
                    Feed::Lock(p) => Input::Lock(p),
                    Feed::Unlock => Input::Unlock,
                    Feed::Sleep => Input::Sleep,
                    Feed::Wake => Input::Wake,
                }),
                Msg::BadQuery { id } => {
                    let r = format!("{}\n", proto::err_reply(&id, "badrequest"));
                    if !Daemon::send(&mut self.clients[i], r.as_bytes()) {
                        return false;
                    }
                }
                Msg::Query { id, q } => {
                    // Anything fed earlier on this connection has to be in the answer.
                    while let Some(inp) = self.queue.pop_front() {
                        self.feed(inp);
                    }
                    let now = clocks().wall;
                    let (reply, watch) = {
                        let v = self.view(now);
                        match &q {
                            Query::State => (proto::ok_reply(&id, "state", v.state()), None),
                            Query::Week(f) => (v.week(&id, f), None),
                            Query::Day(d) => (v.day(&id, d), None),
                            Query::Range(a, b) => (v.range(&id, a, b), None),
                            Query::Watch(mask, names) => (proto::ok_reply(&id, "watching", json!(names)), Some(*mask)),
                        }
                    };
                    let mut out = format!("{reply}\n");
                    if let Some(mask) = watch {
                        self.clients[i].topics = mask;
                        if mask & T_STATE != 0 {
                            out.push_str(&self.view(now).state_push());
                            out.push('\n');
                        }
                    }
                    if !Daemon::send(&mut self.clients[i], out.as_bytes()) {
                        return false;
                    }
                    if out.len() > 32 * 1024 {
                        // SAFETY: returns freed heap to the OS: the RSS gate counts what a big reply left.
                        unsafe { libc::malloc_trim(0) };
                    }
                }
            }
        }
        true
    }

    fn client_flush(&mut self, i: usize) -> bool {
        let c = &mut self.clients[i];
        match c.stream.write(&c.out) {
            Ok(n) => {
                c.out.drain(..n);
                true
            }
            Err(e) => e.kind() == std::io::ErrorKind::WouldBlock,
        }
    }

    // --- hyprland ------------------------------------------------------------------------------

    fn instance_root(&self) -> PathBuf {
        self.runtime.join("hypr")
    }

    fn candidates(&self) -> Vec<PathBuf> {
        match &self.opts.hypr_dir {
            Some(d) => vec![d.clone()],
            None => hypr::instances(&self.instance_root()),
        }
    }

    /// Finds an instance that accepts, takes its monitors and focused window, and feeds `HyprUp`.
    fn try_connect(&mut self) -> bool {
        for dir in self.candidates() {
            let Ok(ev) = hypr::connect_events(&dir) else { continue };
            let Ok(mons) = hypr::request(&dir, "j/monitors") else { continue };
            let Ok(aw) = hypr::request(&dir, "j/activewindow") else { continue };
            let Some((mon, monitors)) = hypr::parse_monitors(&mons) else { continue };
            let app = hypr::parse_activewindow(&aw).flatten();
            let prog = self.take_focus(app.as_deref(), hypr::parse_activewindow_pid(&aw));
            self.ev = Some(ev);
            self.ev_buf.clear();
            self.hypr_dir = Some(dir);
            self.clear_watches();
            arm(self.retry_fd, 0, 0, 0);
            self.retries = 0;
            self.feed(Input::HyprUp { app, prog, mon, monitors });
            return true;
        }
        false
    }

    fn add_watches(&mut self) {
        if self.ino_fd < 0 {
            return;
        }
        let add = |fd: RawFd, p: &Path| -> Option<i32> {
            let c = std::ffi::CString::new(p.as_os_str().as_encoded_bytes()).ok()?;
            // SAFETY: valid fd and C string.
            let wd = unsafe { libc::inotify_add_watch(fd, c.as_ptr(), libc::IN_CREATE | libc::IN_MOVED_TO) };
            (wd >= 0).then_some(wd)
        };
        let mut paths: Vec<PathBuf> = Vec::new();
        match &self.opts.hypr_dir {
            Some(d) => {
                if let Some(p) = d.parent() {
                    paths.push(p.to_path_buf());
                }
                paths.push(d.clone());
            }
            None => {
                let root = self.instance_root();
                if root.is_dir() {
                    paths.push(root.clone());
                    paths.extend(hypr::instances(&root));
                } else {
                    paths.push(self.runtime.clone());
                }
            }
        }
        for p in paths {
            if let Some(wd) = add(self.ino_fd, &p) {
                if !self.ino_wds.contains(&wd) {
                    self.ino_wds.push(wd);
                }
            }
        }
    }

    fn clear_watches(&mut self) {
        for wd in self.ino_wds.drain(..) {
            // SAFETY: wd came from inotify_add_watch on this fd.
            unsafe { libc::inotify_rm_watch(self.ino_fd, wd) };
        }
        // Drain anything queued so the fd is not readable at rest.
        let mut b = [0u8; 4096];
        // SAFETY: nonblocking read into a local buffer.
        while unsafe { libc::read(self.ino_fd, b.as_mut_ptr().cast(), b.len()) } > 0 {}
    }

    fn hypr_lost(&mut self) {
        self.ev = None;
        self.hypr_dir = None;
        if !self.try_connect() {
            self.feed(Input::HyprDown);
            self.retries = 0;
            self.add_watches();
        }
    }

    fn discovery_wake(&mut self) {
        let mut b = [0u8; 4096];
        // SAFETY: nonblocking read into a local buffer.
        while unsafe { libc::read(self.ino_fd, b.as_mut_ptr().cast(), b.len()) } > 0 {}
        self.retry();
    }

    fn retry(&mut self) {
        if self.ev.is_some() || self.try_connect() {
            return;
        }
        self.add_watches();
        if !self.candidates().is_empty() && self.retries < RETRY_MAX {
            self.retries += 1;
            arm(self.retry_fd, RETRY_MS, 0, 0);
        }
    }

    fn on_events(&mut self) {
        let mut buf = [0u8; 65536];
        let n = match self.ev.as_mut().map(|s| s.read(&mut buf)) {
            Some(Ok(0)) => return self.hypr_lost(),
            Some(Ok(n)) => n,
            Some(Err(e))
                if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::Interrupted =>
            {
                return
            }
            _ => return self.hypr_lost(),
        };
        self.ev_buf.extend_from_slice(&buf[..n]);
        let mut data = std::mem::take(&mut self.ev_buf);
        let end = data.iter().rposition(|b| *b == b'\n').map_or(0, |i| i + 1);
        let rest = data.split_off(end);
        if rest.len() < (1 << 20) {
            self.ev_buf = rest;
        }
        // Every window event of this read is resolved by ONE j/activewindow at the end: the reply
        // describes the focus NOW, which is also what every earlier event of the burst led to.
        // A retitle of the focused terminal is likewise ONE /proc read at the end.
        let mut pending = false;
        let mut retitled = false;
        for line in String::from_utf8_lossy(&data).lines() {
            match hypr::parse_event(line) {
                Ev::ActiveV2(addr) if addr.is_empty() => {
                    pending = false;
                    self.focus_addr.clear();
                    self.focus_term = None;
                    self.feed(Input::Focus { app: None, prog: None });
                }
                Ev::ActiveV2(addr) => {
                    self.focus_addr = addr.trim_start_matches("0x").to_string();
                    pending = true;
                }
                Ev::TitleV2(addr) => {
                    if self.focus_term.is_some() && addr.trim_start_matches("0x") == self.focus_addr {
                        retitled = true;
                    }
                }
                Ev::FocusedMon(mon) if !mon.is_empty() => self.feed(Input::FocusMon { mon }),
                Ev::MonitorAdded(m) => self.feed(Input::MonitorAdded(m)),
                Ev::MonitorRemoved(m) => self.feed(Input::MonitorRemoved(m)),
                _ => {}
            }
        }
        if pending {
            if let Some(dir) = self.hypr_dir.clone() {
                if let Ok(b) = hypr::request(&dir, "j/activewindow") {
                    if let Some(app) = hypr::parse_activewindow(&b) {
                        let prog = self.take_focus(app.as_deref(), hypr::parse_activewindow_pid(&b));
                        self.feed(Input::Focus { app, prog });
                    }
                }
            }
        } else if retitled {
            if let Some(pid) = self.focus_term {
                let prog = fg::foreground(Path::new("/proc"), pid);
                self.feed(Input::Prog(prog));
            }
        }
    }

    /// Takes the newly focused window: remembers its process when its class is a terminal, and
    /// reads the program in front of it.
    fn take_focus(&mut self, class: Option<&str>, pid: Option<i32>) -> Option<String> {
        let term = class.is_some_and(|c| self.core.cfg().terminals.iter().any(|t| t == c));
        self.focus_term = if term { pid } else { None };
        self.focus_term.and_then(|p| fg::foreground(Path::new("/proc"), p))
    }

    // --- loop ----------------------------------------------------------------------------------

    fn on_signal(&mut self) {
        let mut si = [0u8; 128];
        // SAFETY: reads one signalfd_siginfo (128 bytes).
        let n = unsafe { libc::read(self.sig_fd, si.as_mut_ptr().cast(), 128) };
        if n != 128 {
            return;
        }
        let signo = u32::from_ne_bytes([si[0], si[1], si[2], si[3]]) as i32;
        if signo == libc::SIGHUP {
            let cfg = load_cfg(&self.opts);
            self.feed(Input::Reload(Box::new(cfg)));
        } else {
            self.stopping = true;
        }
    }

    fn main_loop(&mut self) {
        while !self.stopping {
            while let Some(i) = self.queue.pop_front() {
                self.feed(i);
            }
            let mut fds: Vec<libc::pollfd> = Vec::new();
            let mut tags: Vec<Tag> = Vec::new();
            let mut add = |fd: RawFd, ev: i16, tag: Tag| {
                fds.push(libc::pollfd { fd, events: ev, revents: 0 });
                tags.push(tag);
            };
            add(self.sig_fd, libc::POLLIN, Tag::Signal);
            add(self.listener.as_raw_fd(), libc::POLLIN, Tag::Listener);
            add(self.roll_fd, libc::POLLIN, Tag::Roll);
            add(self.tick_fd, libc::POLLIN, Tag::Tick);
            add(self.retry_fd, libc::POLLIN, Tag::Retry);
            if let Some(s) = &self.ev {
                add(s.as_raw_fd(), libc::POLLIN, Tag::Events);
            }
            if !self.ino_wds.is_empty() {
                add(self.ino_fd, libc::POLLIN, Tag::Inotify);
            }
            if let Some((_, fd)) = self.pid {
                add(fd, libc::POLLIN, Tag::Pid);
            }
            for (i, c) in self.clients.iter().enumerate() {
                let ev = libc::POLLIN | if c.out.is_empty() { 0 } else { libc::POLLOUT };
                add(c.stream.as_raw_fd(), ev, Tag::Client(i));
            }
            // SAFETY: fds is a valid array of its length.
            let r = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) };
            if r < 0 {
                continue;
            }
            let mut dead: Vec<usize> = Vec::new();
            for (pf, tag) in fds.iter().zip(tags.iter()) {
                if pf.revents == 0 {
                    continue;
                }
                match *tag {
                    Tag::Signal => self.on_signal(),
                    Tag::Listener => self.accept(),
                    Tag::Roll => {
                        if read_timer(self.roll_fd) {
                            self.feed(Input::DayRoll);
                        }
                    }
                    Tag::Tick => {
                        if read_timer(self.tick_fd) {
                            self.feed(Input::Tick);
                        }
                    }
                    Tag::Retry => {
                        if read_timer(self.retry_fd) {
                            self.retry();
                        }
                    }
                    Tag::Events => self.on_events(),
                    Tag::Inotify => self.discovery_wake(),
                    Tag::Pid => {
                        if let Some((pid, _)) = self.pid {
                            self.unwatch_pid();
                            self.queue.push_back(Input::LockExited(pid));
                        }
                    }
                    Tag::Client(i) => {
                        let mut keep = true;
                        if pf.revents & libc::POLLOUT != 0 {
                            keep = self.client_flush(i);
                        }
                        if keep && pf.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
                            keep = self.client_read(i);
                        }
                        if !keep {
                            dead.push(i);
                        }
                    }
                }
            }
            dead.sort_unstable();
            dead.dedup();
            for i in dead.into_iter().rev() {
                if i < self.clients.len() {
                    self.clients.remove(i);
                }
            }
        }
        self.shutdown();
    }

    fn accept(&mut self) {
        while let Ok((s, _)) = self.listener.accept() {
            if self.clients.len() >= MAX_CLIENTS || s.set_nonblocking(true).is_err() {
                continue;
            }
            self.clients.push(Client { stream: s, lines: LineBuf::default(), out: Vec::new(), topics: 0 });
        }
    }

    /// TERM: close the open interval, write everything, say `bye`, give the clients a moment to close
    /// first (a peer closed from the far end is logged as an error by Quickshell), then go.
    fn shutdown(&mut self) {
        // The socket goes first: a client that re-dials on `bye` then finds nothing (a silent
        // stat) instead of a listener that is about to close (ServerNotFoundError in its log).
        let _ = std::fs::remove_file(&self.opts.socket);
        self.feed(Input::Shutdown);
        while let Some(i) = self.queue.pop_front() {
            self.feed(i);
        }
        let bye = format!("{}\n", json!({"v": 1, "ev": "bye"}));
        self.clients.retain_mut(|c| Daemon::send(c, bye.as_bytes()));
        let deadline = std::time::Instant::now() + Duration::from_millis(BYE_GRACE_MS as u64);
        while !self.clients.is_empty() {
            let left = deadline.saturating_duration_since(std::time::Instant::now()).as_millis() as i32;
            if left <= 0 {
                break;
            }
            let mut fds: Vec<libc::pollfd> = self
                .clients
                .iter()
                .map(|c| libc::pollfd { fd: c.stream.as_raw_fd(), events: libc::POLLIN, revents: 0 })
                .collect();
            // SAFETY: fds is a valid array of its length.
            unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, left) };
            let mut keep = Vec::new();
            for (c, pf) in self.clients.drain(..).zip(fds.iter()) {
                let mut c = c;
                let mut b = [0u8; 4096];
                let gone = pf.revents != 0
                    && !matches!(c.stream.read(&mut b), Ok(n) if n > 0)
                    && pf.revents & libc::POLLIN != 0
                    || pf.revents & (libc::POLLHUP | libc::POLLERR) != 0;
                if !gone {
                    keep.push(c);
                }
            }
            self.clients = keep;
        }
    }
}

/// `serve-frozen`: answer queries from the day files as of `now`; no Hyprland, no feeds, no pushes.
pub fn serve_frozen(data: &Path, socket: &Path, now: i64, cfg: Cfg) -> i32 {
    let listener = match bind_socket(socket) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("screentimed: {e}");
            return 1;
        }
    };
    let store = Store::new(data);
    let cal = LibcCal::new();
    let mut clients: Vec<(UnixStream, LineBuf)> = Vec::new();
    // SAFETY: a process that is asked to stop just stops; the socket file is removed by the next start.
    let stop = signal_fd();
    loop {
        let mut fds = vec![
            libc::pollfd { fd: stop, events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: listener.as_raw_fd(), events: libc::POLLIN, revents: 0 },
        ];
        fds.extend(clients.iter().map(|c| libc::pollfd { fd: c.0.as_raw_fd(), events: libc::POLLIN, revents: 0 }));
        // SAFETY: fds is a valid array of its length.
        unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) };
        if fds[0].revents != 0 {
            // As `run` stops: the socket first, then `bye`, then a moment for the clients to
            // close their ends first (whoever closes decides whose log has the PeerClosedError).
            let _ = std::fs::remove_file(socket);
            let bye = format!("{}\n", json!({"v": 1, "ev": "bye"}));
            clients.retain_mut(|c| c.0.write_all(bye.as_bytes()).is_ok());
            let deadline = std::time::Instant::now() + Duration::from_millis(BYE_GRACE_MS as u64);
            while !clients.is_empty() {
                let left = deadline.saturating_duration_since(std::time::Instant::now()).as_millis() as i32;
                if left <= 0 {
                    break;
                }
                let mut pfds: Vec<libc::pollfd> = clients
                    .iter()
                    .map(|c| libc::pollfd { fd: c.0.as_raw_fd(), events: libc::POLLIN, revents: 0 })
                    .collect();
                // SAFETY: pfds is a valid array of its length.
                unsafe { libc::poll(pfds.as_mut_ptr(), pfds.len() as libc::nfds_t, left) };
                let mut keep = Vec::new();
                for (mut c, pf) in clients.drain(..).zip(pfds.iter()) {
                    let mut b = [0u8; 4096];
                    let gone = pf.revents != 0 && !matches!(c.0.read(&mut b), Ok(n) if n > 0)
                        || pf.revents & (libc::POLLHUP | libc::POLLERR) != 0;
                    if !gone {
                        keep.push(c);
                    }
                }
                clients = keep;
            }
            return 0;
        }
        if fds[1].revents != 0 {
            while let Ok((s, _)) = listener.accept() {
                if s.set_nonblocking(true).is_ok() && clients.len() < MAX_CLIENTS {
                    clients.push((s, LineBuf::default()));
                }
            }
        }
        let mut dead = Vec::new();
        for (i, pf) in fds.iter().enumerate().skip(2) {
            if pf.revents == 0 {
                continue;
            }
            let (s, lb) = &mut clients[i - 2];
            let mut buf = [0u8; 16384];
            let n = match s.read(&mut buf) {
                Ok(0) => {
                    dead.push(i - 2);
                    continue;
                }
                Ok(n) => n,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => continue,
                Err(_) => {
                    dead.push(i - 2);
                    continue;
                }
            };
            for l in lb.push(&buf[..n]) {
                let Line::Ok(b) = l else { continue };
                let v = View { cfg: &cfg, cal: &cal, store: &store, core: None, now };
                let reply = match proto::parse(&b) {
                    Msg::Query { id, q } => match q {
                        Query::State => Some(proto::ok_reply(&id, "state", v.state())),
                        Query::Week(f) => Some(v.week(&id, &f)),
                        Query::Day(d) => Some(v.day(&id, &d)),
                        Query::Range(a, b) => Some(v.range(&id, &a, &b)),
                        Query::Watch(_, names) => Some(proto::ok_reply(&id, "watching", json!(names))),
                    },
                    Msg::BadQuery { id } => Some(proto::err_reply(&id, "badrequest")),
                    _ => None,
                };
                if let Some(r) = reply {
                    let _ = s.write_all(format!("{r}\n").as_bytes());
                }
            }
        }
        for i in dead.into_iter().rev() {
            clients.remove(i);
        }
    }
}

#[cfg(test)]
mod data_dir_tests {
    use super::data_in;
    use std::fs;

    fn scratch(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("screentimed-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn lares_name_is_the_default_and_the_old_one_only_while_it_is_all_there_is() {
        let base = scratch("data");
        assert_eq!(data_in(&base), base.join("lares/screentime"), "a fresh machine: the Lares name");
        fs::create_dir_all(base.join("quickshell/screentime")).unwrap();
        assert_eq!(data_in(&base), base.join("quickshell/screentime"), "before migrate-name: the old dir is the data");
        fs::create_dir_all(base.join("lares")).unwrap();
        fs::rename(base.join("quickshell/screentime"), base.join("lares/screentime")).unwrap();
        std::os::unix::fs::symlink(base.join("lares/screentime"), base.join("quickshell/screentime")).unwrap();
        assert_eq!(data_in(&base), base.join("lares/screentime"), "after: the new dir, the old path is a symlink to it");
        let _ = fs::remove_dir_all(&base);
    }
}
