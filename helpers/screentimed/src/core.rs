//! The pure state machine. No clock, no file, no socket: every input arrives with the three clocks it
//! happened at, and every effect leaves as an `Output` for the shell around it (the poll loop, or the
//! replay driver) to carry out. CONTRACT.md section 3 is this file.
//!
//! Time arithmetic all lives here: backdating, interval cutting, the day roll, session and pickup
//! bookkeeping, suspend placement, the hour bucketing's day bounds. Nothing here touches the window
//! title; a focus arrives as a class name.

use crate::cal::{day_bounds, logical_date, week_start_of, Calendar, Date};
use crate::day::{secs, Day, Iv, DESKTOP};
use serde_json::Value;
use std::collections::BTreeMap;

pub const R_IDLE: u8 = 1;
pub const R_LOCKED: u8 = 2;
pub const R_ASLEEP: u8 = 4;
pub const R_NOSESSION: u8 = 8;

/// A suspend is a BOOTTIME-over-MONOTONIC growth larger than this.
const SUSPEND_MIN_MS: i64 = 2000;
/// A `sleep` feed this soon after a detected suspend is the late echo of it.
const LATE_SLEEP_MS: i64 = 5000;
/// A tick may come this early and still be the flush tick (timer slack).
const FLUSH_SLACK_MS: i64 = 1000;

#[derive(Clone, Debug)]
pub struct Cfg {
    pub day_start_hour: u32,
    pub week_start: u32,
    pub session_break_min: u32,
    pub max_backdate_s: u32,
    pub flush_s: u32,
    pub check_s: u32,
    pub digest: bool,
    pub aliases: BTreeMap<String, String>,
    pub names: BTreeMap<String, String>,
    /// Window classes recorded as no app (their time is the desktop's).
    pub ignore: Vec<String>,
    /// Window classes whose foreground program is read (fg.rs) and recorded with the interval.
    pub terminals: Vec<String>,
}

impl Default for Cfg {
    fn default() -> Cfg {
        Cfg {
            day_start_hour: 4,
            week_start: 1,
            session_break_min: 5,
            max_backdate_s: 900,
            flush_s: 300,
            check_s: 60,
            digest: true,
            aliases: BTreeMap::new(),
            names: BTreeMap::new(),
            ignore: Vec::new(),
            terminals: [
                "kitty",
                "foot",
                "Alacritty",
                "com.mitchellh.ghostty",
                "org.wezfurlong.wezterm",
                "org.kde.konsole",
            ]
            .map(String::from)
            .to_vec(),
        }
    }
}

impl Cfg {
    /// Lenient: a key of the wrong type or out of range keeps its default.
    pub fn from_value(v: &Value) -> Cfg {
        let mut c = Cfg::default();
        let num = |k: &str, lo: i64, hi: i64| v.get(k).and_then(Value::as_i64).filter(|n| (lo..=hi).contains(n));
        if let Some(n) = num("dayStartHour", 0, 23) {
            c.day_start_hour = n as u32;
        }
        if let Some(n) = num("weekStart", 1, 7) {
            c.week_start = n as u32;
        }
        if let Some(n) = num("sessionBreakMin", 0, 24 * 60) {
            c.session_break_min = n as u32;
        }
        if let Some(n) = num("maxBackdateS", 0, 86_400) {
            c.max_backdate_s = n as u32;
        }
        if let Some(n) = num("flushS", 1, 86_400) {
            c.flush_s = n as u32;
        }
        if let Some(n) = num("checkS", 1, 86_400) {
            c.check_s = n as u32;
        }
        if let Some(b) = v.get("digest").and_then(Value::as_bool) {
            c.digest = b;
        }
        let map = |k: &str| -> BTreeMap<String, String> {
            v.get(k)
                .and_then(Value::as_object)
                .map(|o| o.iter().filter_map(|(a, b)| b.as_str().map(|b| (a.clone(), b.to_string()))).collect())
                .unwrap_or_default()
        };
        c.aliases = map("aliases");
        c.names = map("names");
        let list = |k: &str| {
            v.get(k)
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect())
        };
        if let Some(a) = list("terminals") {
            c.terminals = a;
        }
        if let Some(a) = list("ignore") {
            c.ignore = a;
        }
        c
    }

    fn break_ms(&self) -> i64 {
        i64::from(self.session_break_min) * 60_000
    }

    fn backdate_ms(&self) -> i64 {
        i64::from(self.max_backdate_s) * 1000
    }
}

/// The three clocks an input happened at, in milliseconds.
#[derive(Clone, Copy, Debug)]
pub struct Clocks {
    pub wall: i64,
    pub mono: i64,
    pub boot: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LastSess {
    pub start: i64,
    pub end: i64,
    pub active_s: i64,
    pub why: String,
}

/// What `state.json` carries across a restart.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Saved {
    pub boot_id: String,
    pub saved_at: i64,
    /// `(start, active seconds)`.
    pub session: Option<(i64, i64)>,
    pub last_session: Option<LastSess>,
    pub away_since: Option<i64>,
    pub digest_week: Option<Date>,
    pub lock_pid: Option<i32>,
}

#[derive(Clone, Debug)]
#[allow(clippy::large_enum_variant)]
pub enum Input {
    /// Daemon start: the boot, what `state.json` held, a running locker's pid, today's file if any.
    Start {
        boot_id: String,
        saved: Option<Saved>,
        lock_pid: Option<i32>,
        day: Option<Day>,
    },
    /// A Hyprland instance answered: its focused window's class (None = nothing focused) and monitors.
    HyprUp {
        app: Option<String>,
        /// The focused terminal window's foreground program (None for any other app).
        prog: Option<String>,
        mon: String,
        monitors: Vec<String>,
    },
    HyprDown,
    /// `activewindowv2` resolved: the class, or None for an empty workspace, and the program in
    /// front when the window is a terminal.
    Focus {
        app: Option<String>,
        prog: Option<String>,
    },
    /// The focused terminal window's foreground program changed (read on its title change).
    Prog(Option<String>),
    FocusMon {
        mon: String,
    },
    MonitorAdded(String),
    MonitorRemoved(String),
    Idle(i64),
    Active,
    Lock(Option<i32>),
    Unlock,
    Sleep,
    Wake,
    /// The watched lock pid exited.
    LockExited(i32),
    Tick,
    /// The day-roll timer fired (or was cancelled by a clock step).
    DayRoll,
    Shutdown,
    Reload(Box<Cfg>),
    /// SIGHUP's write of everything dirty.
    Flush,
    Dropped(u32),
}

#[derive(Clone, Debug)]
pub enum Output {
    WriteDay(Box<Day>),
    WriteState(Box<Saved>),
    PushState,
    PushFocus,
    PushMonitors,
    PushDay(Date),
    /// Arm the day-roll timer at this absolute wall time.
    ArmRoll(i64),
    /// Arm (true) or disarm (false) the flush / suspend-check tick.
    ArmTick(bool),
    WatchPid(i32),
    UnwatchPid,
    /// First activity of a new week: send the digest for the week before this one starting here.
    Digest(Date),
}

struct Sess {
    start: i64,
    active_ms: i64,
}

struct RamDay {
    day: Day,
    dirty: bool,
    exists: bool,
    final_at: Option<i64>,
    app_ms: Vec<i64>,
    total_ms: i64,
}

impl RamDay {
    fn new(day: Day, exists: bool) -> RamDay {
        let mut r = RamDay { day, dirty: false, exists, final_at: None, app_ms: Vec::new(), total_ms: 0 };
        r.recompute();
        r
    }

    fn recompute(&mut self) {
        self.app_ms = vec![0; self.day.apps.len()];
        self.total_ms = 0;
        for v in &self.day.iv {
            self.app_ms[v.app as usize] += v.e - v.s;
            self.total_ms += v.e - v.s;
        }
    }

    fn add(&mut self, app: u32, ms: i64) {
        if self.app_ms.len() <= app as usize {
            self.app_ms.resize(app as usize + 1, 0);
        }
        self.app_ms[app as usize] += ms;
        self.total_ms += ms;
    }
}

/// A plain-data view of the machine for the STATE object.
#[derive(Clone, Debug)]
pub struct Snap {
    pub now: i64,
    pub date: Date,
    pub day_start: i64,
    pub day_end: i64,
    pub r: u8,
    pub away_since: Option<i64>,
    pub app: Option<String>,
    pub mon: Option<String>,
    pub app_since: Option<i64>,
    pub prog: Option<String>,
    /// Where the current run on one app began (a monitor or program change does not end it).
    pub stretch_since: Option<i64>,
    pub session: Option<(i64, i64)>,
    pub last_session: Option<LastSess>,
    pub today_total: i64,
    pub today_apps: BTreeMap<String, i64>,
    pub focused_mon: Option<String>,
    pub focused_mon_since: Option<i64>,
    pub last_focus: BTreeMap<String, i64>,
    pub present: Vec<String>,
    pub dropped: u64,
}

pub struct Core {
    cfg: Cfg,
    cal: Box<dyn Calendar>,
    r: u8,
    app: Option<String>,
    mon: Option<String>,
    prog: Option<String>,
    open: Option<i64>,
    stretch_since: Option<i64>,
    active_since: i64,
    away_since: Option<i64>,
    away_why: &'static str,
    session: Option<Sess>,
    last_session: Option<LastSess>,
    days: Vec<RamDay>,
    gap: Option<i64>,
    sleep_ignore_until: i64,
    last_flush_mono: i64,
    lock_pid: Option<i32>,
    digest_week: Option<Date>,
    boot_id: String,
    focused_mon: Option<String>,
    focused_mon_since: Option<i64>,
    last_focus: BTreeMap<String, i64>,
    present: Vec<String>,
    dropped: u64,
    armed_roll: Option<i64>,
    now: i64,
    mono: i64,
    boot: i64,
}

impl Core {
    pub fn new(cfg: Cfg, cal: Box<dyn Calendar>) -> Core {
        Core {
            cfg,
            cal,
            r: R_NOSESSION,
            app: None,
            mon: None,
            prog: None,
            open: None,
            stretch_since: None,
            active_since: 0,
            away_since: None,
            away_why: "nosession",
            session: None,
            last_session: None,
            days: Vec::new(),
            gap: None,
            sleep_ignore_until: i64::MIN,
            last_flush_mono: 0,
            lock_pid: None,
            digest_week: None,
            boot_id: String::new(),
            focused_mon: None,
            focused_mon_since: None,
            last_focus: BTreeMap::new(),
            present: Vec::new(),
            dropped: 0,
            armed_roll: None,
            now: 0,
            mono: 0,
            boot: 0,
        }
    }

    pub fn cfg(&self) -> &Cfg {
        &self.cfg
    }

    pub fn calendar(&self) -> &dyn Calendar {
        self.cal.as_ref()
    }

    pub fn is_active(&self) -> bool {
        self.r == 0
    }

    pub fn date_of(&self, ms: i64) -> Date {
        logical_date(self.cal.as_ref(), ms, self.cfg.day_start_hour)
    }

    /// When the current day ends (the next roll), absolute wall ms; None before the first input.
    pub fn next_roll(&self) -> Option<i64> {
        self.days.last().map(|d| d.day.end)
    }

    pub fn saved(&self) -> Saved {
        Saved {
            boot_id: self.boot_id.clone(),
            saved_at: self.now,
            session: self.session.as_ref().map(|s| (s.start, secs(s.active_ms))),
            last_session: self.last_session.clone(),
            away_since: self.away_since,
            digest_week: self.digest_week,
            lock_pid: self.lock_pid,
        }
    }

    fn cur(&self) -> &RamDay {
        self.days.last().expect("a day exists after the first input")
    }

    fn cur_mut(&mut self) -> &mut RamDay {
        self.days.last_mut().expect("a day exists after the first input")
    }

    fn make_day(&self, date: Date) -> RamDay {
        let (s, e) = day_bounds(self.cal.as_ref(), date, self.cfg.day_start_hour);
        RamDay::new(Day::new(date, s, e), false)
    }

    pub fn snapshot(&self, now: i64) -> Snap {
        let cur = self.days.last();
        let mut today_apps = BTreeMap::new();
        if let Some(c) = cur {
            for (i, ms) in c.app_ms.iter().enumerate() {
                if *ms > 0 {
                    today_apps.insert(c.day.apps[i].clone(), secs(*ms));
                }
            }
        }
        let date = cur.map_or_else(|| self.date_of(now), |c| c.day.date);
        let (ds, de) = cur
            .map_or_else(|| day_bounds(self.cal.as_ref(), date, self.cfg.day_start_hour), |c| (c.day.start, c.day.end));
        Snap {
            now,
            date,
            day_start: ds,
            day_end: de,
            r: self.r,
            away_since: self.away_since,
            app: self.app.clone(),
            mon: self.mon.clone(),
            app_since: if self.r == 0 { self.open } else { None },
            prog: self.prog.clone(),
            stretch_since: if self.r == 0 && self.open.is_some() { self.stretch_since } else { None },
            session: self.session.as_ref().map(|s| (s.start, secs(s.active_ms))),
            last_session: self.last_session.clone(),
            today_total: cur.map_or(0, |c| secs(c.total_ms)),
            today_apps,
            focused_mon: self.focused_mon.clone(),
            focused_mon_since: self.focused_mon_since,
            last_focus: self.last_focus.clone(),
            present: self.present.clone(),
            dropped: self.dropped,
        }
    }

    /// The RAM copy of a logical day, with the open interval appended as a closed one ending at `now`.
    /// The flag says that interval was added.
    pub fn live_day(&self, date: Date, now: i64) -> Option<(Day, bool)> {
        let rd = self.days.iter().find(|d| d.day.date == date)?;
        let mut day = rd.day.clone();
        let mut open = false;
        if rd.day.date == self.cur().day.date && self.r == 0 {
            if let (Some(s), Some(app)) = (self.open, self.app.clone()) {
                let s = s.max(day.iv.last().map_or(day.start, |l| l.e)).max(day.start);
                let e = now.min(day.end);
                if e > s {
                    let a = day.app_idx(&app);
                    let m = day.mon_idx(self.mon.as_deref().unwrap_or("?"));
                    let p = day.prog_idx(self.prog.as_deref());
                    day.iv.push(Iv { s, e, app: a, mon: m, prog: p });
                    open = true;
                }
            }
        }
        if rd.day.iv.is_empty() && !open && !rd.exists && date != self.cur().day.date {
            return None;
        }
        Some((day, open))
    }

    fn signature(&self) -> (u8, Option<i64>, Option<Date>) {
        (self.r, self.session.as_ref().map(|s| s.start), self.days.last().map(|d| d.day.date))
    }

    fn resolve_app(&self, app: Option<String>) -> String {
        match app {
            Some(c) if !c.is_empty() && !self.cfg.ignore.contains(&c) => self.cfg.aliases.get(&c).cloned().unwrap_or(c),
            _ => DESKTOP.to_string(),
        }
    }

    /// Feeds one input through the machine at the given clocks.
    pub fn handle(&mut self, input: Input, ck: Clocks) -> Vec<Output> {
        self.now = ck.wall;
        self.mono = ck.mono;
        self.boot = ck.boot;
        let mut out = Vec::new();
        if self.days.is_empty() {
            let d = self.make_day(self.date_of(ck.wall));
            self.days.push(d);
            self.gap = Some(ck.boot - ck.mono);
        }
        let sig = self.signature();
        let rearm_roll = matches!(input, Input::DayRoll | Input::Start { .. });
        if let Input::Start { boot_id, saved, lock_pid, day } = input {
            self.start(boot_id, saved, lock_pid, day, &mut out);
        } else {
            self.detect_suspend(&mut out);
            self.roll_due(&mut out);
            self.drop_final();
            self.apply(input, &mut out);
        }
        let roll = self.cur().day.end;
        if rearm_roll || self.armed_roll != Some(roll) {
            self.armed_roll = Some(roll);
            out.push(Output::ArmRoll(roll));
        }
        if self.signature() != sig && !out.iter().any(|o| matches!(o, Output::PushState)) {
            out.push(Output::PushState);
        }
        out
    }

    fn apply(&mut self, input: Input, out: &mut Vec<Output>) {
        let now = self.now;
        match input {
            Input::Start { .. } => {}
            Input::HyprUp { app, prog, mon, monitors } => {
                let app = self.resolve_app(app);
                self.present = monitors;
                self.focused_mon = Some(mon.clone());
                self.focused_mon_since = Some(now);
                self.last_focus.insert(mon.clone(), now);
                if self.r & R_NOSESSION != 0 {
                    self.app = Some(app);
                    self.mon = Some(mon);
                    self.prog = prog;
                    self.r &= !R_NOSESSION;
                    if self.r == 0 {
                        self.become_active(out);
                    }
                } else {
                    self.change_focus(Some(app), Some(mon), Some(prog), out);
                }
                out.push(Output::PushMonitors);
            }
            Input::HyprDown => {
                if self.r & R_NOSESSION == 0 {
                    if self.r == 0 {
                        self.begin_away("nosession", out);
                    }
                    self.r |= R_NOSESSION;
                    self.app = None;
                    self.mon = None;
                    self.prog = None;
                    self.focused_mon = None;
                    self.focused_mon_since = None;
                    self.present.clear();
                    self.flush_all(out);
                    out.push(Output::PushMonitors);
                }
            }
            Input::Focus { app, prog } => {
                let app = self.resolve_app(app);
                self.change_focus(Some(app), None, Some(prog), out);
            }
            Input::Prog(prog) => self.change_focus(None, None, Some(prog), out),
            Input::FocusMon { mon } => {
                if self.focused_mon.as_deref() != Some(mon.as_str()) {
                    if let Some(old) = self.focused_mon.take() {
                        self.last_focus.insert(old, now);
                    }
                    self.focused_mon = Some(mon.clone());
                    self.focused_mon_since = Some(now);
                    self.last_focus.insert(mon.clone(), now);
                    out.push(Output::PushMonitors);
                }
                self.change_focus(None, Some(mon), None, out);
            }
            Input::MonitorAdded(name) => {
                if !self.present.contains(&name) {
                    self.present.push(name);
                }
                out.push(Output::PushMonitors);
            }
            Input::MonitorRemoved(name) => {
                self.present.retain(|n| *n != name);
                out.push(Output::PushMonitors);
            }
            Input::Idle(ago) => self.on_idle(ago, out),
            Input::Active => {
                if self.r & R_IDLE != 0 {
                    self.r &= !R_IDLE;
                    if self.r == 0 {
                        self.become_active(out);
                    }
                }
            }
            Input::Lock(pid) => self.on_lock(pid, out),
            Input::Unlock => self.unlock(out),
            Input::LockExited(pid) => {
                if self.lock_pid == Some(pid) {
                    self.unlock(out);
                }
            }
            Input::Sleep => {
                if now < self.sleep_ignore_until || self.r & R_ASLEEP != 0 {
                    return;
                }
                if self.r == 0 {
                    self.begin_away("sleep", out);
                }
                self.r |= R_ASLEEP;
                let at = self.away_since.unwrap_or(now);
                self.end_session(at, "sleep");
                self.flush_all(out);
            }
            Input::Wake => {
                if self.r & R_ASLEEP != 0 {
                    self.r &= !R_ASLEEP;
                    if self.r == 0 {
                        self.become_active(out);
                    }
                }
            }
            Input::Tick => {
                let due = self.mono - self.last_flush_mono + FLUSH_SLACK_MS >= i64::from(self.cfg.flush_s) * 1000;
                if self.r == 0 && due && self.days.iter().any(|d| d.dirty) {
                    self.flush_all(out);
                }
            }
            Input::DayRoll => {}
            Input::Shutdown => {
                self.close_open_at(now);
                self.flush_all(out);
                out.push(Output::UnwatchPid);
            }
            Input::Reload(cfg) => {
                let mut cfg = *cfg;
                // The day start is read once: days already written carry the old bounds.
                cfg.day_start_hour = self.cfg.day_start_hour;
                self.cfg = cfg;
                self.flush_all(out);
                out.push(Output::PushState);
                out.push(Output::ArmTick(self.r == 0));
            }
            Input::Flush => self.flush_all(out),
            Input::Dropped(n) => self.dropped += u64::from(n),
        }
    }

    // --- start ---------------------------------------------------------------------------------

    fn start(
        &mut self,
        boot_id: String,
        saved: Option<Saved>,
        lock_pid: Option<i32>,
        day: Option<Day>,
        out: &mut Vec<Output>,
    ) {
        let now = self.now;
        self.boot_id = boot_id.clone();
        self.r = R_NOSESSION;
        self.app = None;
        self.mon = None;
        self.prog = None;
        self.open = None;
        self.session = None;
        self.away_since = Some(now);
        self.away_why = "nosession";
        if let Some(d) = day {
            if d.date == self.date_of(now) {
                self.days.clear();
                self.days.push(RamDay::new(d, true));
            }
        }
        let mut continued = false;
        if let Some(s) = saved {
            self.digest_week = s.digest_week;
            self.last_session = s.last_session.clone();
            let from = s.away_since.unwrap_or(s.saved_at);
            if let Some((st, act)) = s.session {
                if s.boot_id == boot_id && now - from < self.cfg.break_ms() {
                    self.session = Some(Sess { start: st, active_ms: act * 1000 });
                    self.away_since = Some(from.min(now));
                    continued = true;
                } else {
                    self.last_session = Some(LastSess { start: st, end: from, active_s: act, why: "stop".into() });
                }
            }
        }
        if !continued {
            // The earlier part of today's file is a session that ended when the daemon stopped.
            let cur = self.cur_mut();
            if let Some(last_e) = cur.day.iv.last().map(|v| v.e) {
                if !cur.day.breaks.iter().any(|(t, _)| *t >= last_e) {
                    cur.day.add_break(last_e, "stop");
                    cur.dirty = true;
                }
            }
        }
        if let Some(p) = lock_pid {
            self.r |= R_LOCKED;
            self.lock_pid = Some(p);
            if continued {
                let at = self.away_since.unwrap_or(now);
                self.end_session(at, "lock");
            }
            out.push(Output::WatchPid(p));
        }
        out.push(Output::PushState);
    }

    // --- intervals -------------------------------------------------------------------------------

    fn push_interval(&mut self, s: i64, e: i64, app: &str, mon: &str, prog: Option<&str>) {
        let cur = self.days.last_mut().expect("a day exists");
        let mut s = s.max(cur.day.start);
        if let Some(l) = cur.day.iv.last() {
            s = s.max(l.e);
        }
        let e = e.min(cur.day.end);
        if e <= s {
            return;
        }
        let a = cur.day.app_idx(app);
        let m = cur.day.mon_idx(mon);
        let p = cur.day.prog_idx(prog);
        cur.day.iv.push(Iv { s, e, app: a, mon: m, prog: p });
        cur.add(a, e - s);
        cur.dirty = true;
        if let Some(sess) = &mut self.session {
            sess.active_ms += e - s;
        }
    }

    /// Closes the open interval at `e`. An interval that would be empty (or negative after a wall clock
    /// step back) is dropped, so two changes in one millisecond leave no zero-length record.
    fn close_open_at(&mut self, e: i64) {
        let Some(s) = self.open.take() else { return };
        let Some(app) = self.app.clone() else { return };
        let mon = self.mon.clone().unwrap_or_else(|| "?".into());
        let prog = self.prog.clone();
        self.push_interval(s, e, &app, &mon, prog.as_deref());
    }

    /// Removes everything recorded after `t` from the intervals held in RAM: an interval that ends
    /// after `t` is cut there, one that starts at or after it is dropped.
    fn cut_back(&mut self, t: i64, out: &mut Vec<Output>) {
        let cur_date = self.cur().day.date;
        let mut removed = 0i64;
        let mut rewritten: Vec<Date> = Vec::new();
        for di in (0..self.days.len()).rev() {
            let rd = &mut self.days[di];
            let mut touched = false;
            while let Some(last) = rd.day.iv.last().copied() {
                if last.e <= t {
                    break;
                }
                touched = true;
                if last.s >= t {
                    rd.day.iv.pop();
                    removed += last.e - last.s;
                } else {
                    if let Some(l) = rd.day.iv.last_mut() {
                        l.e = t;
                    }
                    removed += last.e - t;
                    break;
                }
            }
            if touched {
                rd.dirty = true;
                rd.recompute();
                if rd.day.date != cur_date {
                    rewritten.push(rd.day.date);
                }
            }
            if !rd.day.iv.is_empty() {
                break;
            }
        }
        if let Some(s) = &mut self.session {
            s.active_ms = (s.active_ms - removed).max(0);
        }
        for d in rewritten {
            out.push(Output::PushDay(d));
        }
    }

    /// A change of the focus (app, monitor, terminal program): `None` keeps that part, and `prog`
    /// is `Some(None)` for a window with no program to read.
    fn change_focus(
        &mut self,
        app: Option<String>,
        mon: Option<String>,
        prog: Option<Option<String>>,
        out: &mut Vec<Output>,
    ) {
        let napp = app.or_else(|| self.app.clone());
        let nmon = mon.or_else(|| self.mon.clone());
        let nprog = prog.unwrap_or_else(|| self.prog.clone());
        if napp == self.app && nmon == self.mon && nprog == self.prog {
            return;
        }
        let same_app = napp == self.app;
        let running = self.r == 0 && self.open.is_some();
        if running {
            let now = self.now;
            self.close_open_at(now);
        }
        self.app = napp;
        self.mon = nmon;
        self.prog = nprog;
        if running && self.app.is_some() {
            self.open = Some(self.now);
            if !same_app {
                self.stretch_since = Some(self.now);
            }
            out.push(Output::PushFocus);
        }
    }

    // --- away / active -----------------------------------------------------------------------------

    fn begin_away(&mut self, why: &'static str, out: &mut Vec<Output>) {
        let now = self.now;
        self.close_open_at(now);
        self.away_since = Some(now);
        self.away_why = why;
        out.push(Output::ArmTick(false));
    }

    fn on_idle(&mut self, ago_s: i64, out: &mut Vec<Output>) {
        if self.r & R_IDLE != 0 {
            return;
        }
        if self.r != 0 {
            self.r |= R_IDLE;
            return;
        }
        let now = self.now;
        self.close_open_at(now);
        let back = ago_s.clamp(0, i64::from(self.cfg.max_backdate_s)) * 1000;
        let t = if cfg!(feature = "arm-nobackdate") { now } else { (now - back).max(self.active_since).min(now) };
        self.cut_back(t, out);
        self.away_since = Some(t);
        self.away_why = "idle";
        self.r |= R_IDLE;
        self.flush_all(out);
        out.push(Output::ArmTick(false));
    }

    fn on_lock(&mut self, pid: Option<i32>, out: &mut Vec<Output>) {
        if self.r & R_LOCKED != 0 {
            // The first pid stays: a second `lock-run` whose locker refuses to start must not unlock.
            if self.lock_pid.is_none() {
                if let Some(p) = pid {
                    self.lock_pid = Some(p);
                    out.push(Output::WatchPid(p));
                }
            }
            return;
        }
        if self.r == 0 {
            self.begin_away("lock", out);
        }
        self.r |= R_LOCKED;
        let at = self.away_since.unwrap_or(self.now);
        self.end_session(at, "lock");
        if let Some(p) = pid {
            self.lock_pid = Some(p);
            out.push(Output::WatchPid(p));
        }
        self.flush_all(out);
    }

    fn unlock(&mut self, out: &mut Vec<Output>) {
        if self.r & R_LOCKED == 0 {
            return;
        }
        self.r &= !R_LOCKED;
        self.lock_pid = None;
        out.push(Output::UnwatchPid);
        if self.r == 0 {
            self.become_active(out);
        }
    }

    fn start_session(&mut self, at: i64) {
        self.session = Some(Sess { start: at, active_ms: 0 });
    }

    /// Ends the session at `at` with a break of that kind. No session, no break.
    fn end_session(&mut self, at: i64, why: &str) {
        let Some(s) = self.session.take() else { return };
        self.last_session =
            Some(LastSess { start: s.start, end: at.max(s.start), active_s: secs(s.active_ms), why: why.to_string() });
        self.record_break(at, why);
    }

    fn record_break(&mut self, at: i64, why: &str) {
        let idx = self
            .days
            .iter()
            .position(|d| at >= d.day.start && at < d.day.end)
            .unwrap_or(if at < self.days[0].day.start { 0 } else { self.days.len() - 1 });
        let d = &mut self.days[idx];
        let t = at.max(d.day.start);
        d.day.add_break(t, why);
        d.dirty = true;
    }

    fn become_active(&mut self, out: &mut Vec<Output>) {
        let now = self.now;
        self.active_since = now;
        let away = self.away_since.take().unwrap_or(now);
        let why = self.away_why;
        if self.session.is_none() {
            self.start_session(now);
        } else if now - away >= self.cfg.break_ms() {
            self.end_session(away, why);
            self.start_session(now);
        }
        if self.app.is_some() {
            self.open = Some(now);
            self.stretch_since = Some(now);
        }
        out.push(Output::ArmTick(true));
        self.last_flush_mono = self.mono;
        let week = week_start_of(self.date_of(now), self.cfg.week_start);
        if self.digest_week != Some(week) {
            self.digest_week = Some(week);
            if self.cfg.digest {
                out.push(Output::Digest(week));
            }
        }
    }

    // --- suspend, roll, flush --------------------------------------------------------------------------

    /// A suspend nobody announced: BOOTTIME grew over MONOTONIC by d, so the machine slept for [W-d, W].
    fn detect_suspend(&mut self, out: &mut Vec<Output>) {
        let g = self.boot - self.mono;
        let Some(prev) = self.gap else {
            self.gap = Some(g);
            return;
        };
        self.gap = Some(g);
        let d = g - prev;
        if d <= SUSPEND_MIN_MS {
            return;
        }
        let w = self.now;
        self.sleep_ignore_until = w + LATE_SLEEP_MS;
        if self.r == 0 {
            let t0 = (w - d).max(self.active_since).min(w);
            self.close_open_at(w);
            self.cut_back(t0, out);
            self.end_session(t0, "sleep");
            self.start_session(w);
            self.active_since = w;
            if self.app.is_some() {
                self.open = Some(w);
                self.stretch_since = Some(w);
            }
            self.flush_all(out);
        } else if self.session.is_some() {
            let at = self.away_since.unwrap_or(w - d);
            self.end_session(at, "sleep");
            self.flush_all(out);
        }
    }

    fn roll_due(&mut self, out: &mut Vec<Output>) {
        let mut rolled: Vec<Date> = Vec::new();
        while self.now >= self.cur().day.end {
            let end = self.cur().day.end;
            let old = self.cur().day.date;
            let was_open = self.open.is_some();
            if !cfg!(feature = "arm-nosplit") {
                self.close_open_at(end);
            }
            let final_at = end + self.cfg.backdate_ms();
            self.cur_mut().final_at = Some(final_at);
            let next = self.make_day(self.date_of(end));
            self.days.push(next);
            if was_open && !cfg!(feature = "arm-nosplit") {
                self.open = Some(end);
                self.stretch_since = Some(end);
            }
            rolled.push(old);
        }
        if !rolled.is_empty() {
            self.flush_all(out);
            for d in rolled {
                out.push(Output::PushDay(d));
            }
        }
    }

    /// Yesterday's records stay in RAM until boundary + maxBackdate; after that they are final.
    fn drop_final(&mut self) {
        let now = self.now;
        let n = self.days.len();
        let mut i = 0;
        self.days.retain(|d| {
            i += 1;
            i == n || d.dirty || d.final_at.is_none_or(|f| now < f)
        });
    }

    fn flush_all(&mut self, out: &mut Vec<Output>) {
        for rd in &mut self.days {
            if rd.dirty {
                rd.dirty = false;
                if !rd.day.iv.is_empty() || rd.exists {
                    rd.exists = true;
                    out.push(Output::WriteDay(Box::new(rd.day.clone())));
                }
            }
        }
        out.push(Output::WriteState(Box::new(self.saved())));
        self.last_flush_mono = self.mono;
    }
}

#[cfg(test)]
#[path = "core_tests.rs"]
mod core_tests;
