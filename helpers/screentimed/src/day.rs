//! A logical day's record (`iv` + `breaks` are the truth) and everything derived from it (`Sum`).
//!
//! `compute_sum` is pure: the same function feeds the day file, the live view of today and `rebuild`,
//! so a derived figure can never disagree with the intervals it came from. Sessions, pickups and
//! switches are all read off `iv` + `breaks`: a session is a maximal run of intervals with no break
//! between them, so a short idle pause (a gap with no break) stays inside its session.

use crate::cal::{Calendar, Date};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;

pub const DESKTOP: &str = "~desktop";

/// One focus interval `[s, e)` on (app, monitor), indices into the day's `apps` / `mons`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Iv {
    pub s: i64,
    pub e: i64,
    pub app: u32,
    pub mon: u32,
    /// Index into the day's `progs`: the program in front in a terminal window (kitty's
    /// foreground process), or NO_PROG for every other app.
    pub prog: u32,
}

/// An interval with no program (any app that is not a terminal, or a terminal it could not read).
pub const NO_PROG: u32 = u32::MAX;

/// A stay on an app shorter than this is not a switch (see compute_sum).
pub const MIN_STAY_MS: i64 = 2000;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Day {
    pub date: Date,
    pub start: i64,
    pub end: i64,
    pub apps: Vec<String>,
    pub mons: Vec<String>,
    /// Terminal programs by name (the process's own name, never its arguments). Written only when
    /// there is one, so a day without a terminal keeps its v1 bytes.
    pub progs: Vec<String>,
    pub iv: Vec<Iv>,
    /// `(at, why)` sorted by `at`; why is one of lock|sleep|idle|nosession|stop. Every one ends a session.
    pub breaks: Vec<(i64, String)>,
}

fn intern(list: &mut Vec<String>, name: &str) -> u32 {
    if let Some(i) = list.iter().position(|a| a == name) {
        return i as u32;
    }
    list.push(name.to_string());
    (list.len() - 1) as u32
}

impl Day {
    pub fn new(date: Date, start: i64, end: i64) -> Day {
        Day {
            date,
            start,
            end,
            apps: Vec::new(),
            mons: Vec::new(),
            progs: Vec::new(),
            iv: Vec::new(),
            breaks: Vec::new(),
        }
    }

    pub fn app_idx(&mut self, name: &str) -> u32 {
        intern(&mut self.apps, name)
    }

    pub fn mon_idx(&mut self, name: &str) -> u32 {
        intern(&mut self.mons, name)
    }

    pub fn prog_idx(&mut self, name: Option<&str>) -> u32 {
        name.map_or(NO_PROG, |n| intern(&mut self.progs, n))
    }

    /// A break keeps `breaks` sorted by time.
    pub fn add_break(&mut self, at: i64, why: &str) {
        let pos = self.breaks.iter().position(|(t, _)| *t > at).unwrap_or(self.breaks.len());
        self.breaks.insert(pos, (at, why.to_string()));
    }

    /// The same day with `apps` / `mons` / `progs` renumbered by first use and the unused ones dropped.
    pub fn compacted(&self) -> Day {
        let mut apps: Vec<String> = Vec::new();
        let mut mons: Vec<String> = Vec::new();
        let mut progs: Vec<String> = Vec::new();
        let mut iv = Vec::with_capacity(self.iv.len());
        for v in &self.iv {
            let a = intern(&mut apps, &self.apps[v.app as usize]);
            let m = intern(&mut mons, &self.mons[v.mon as usize]);
            let p = if v.prog == NO_PROG { NO_PROG } else { intern(&mut progs, &self.progs[v.prog as usize]) };
            iv.push(Iv { s: v.s, e: v.e, app: a, mon: m, prog: p });
        }
        Day { date: self.date, start: self.start, end: self.end, apps, mons, progs, iv, breaks: self.breaks.clone() }
    }

    pub fn from_value(v: &Value) -> Result<Day, String> {
        let o = v.as_object().ok_or("day file is not an object")?;
        if o.get("v").and_then(Value::as_i64) != Some(1) {
            return Err("unsupported day file version".into());
        }
        let date = o.get("date").and_then(Value::as_str).and_then(Date::parse).ok_or("bad date")?;
        let start = o.get("start").and_then(Value::as_i64).ok_or("bad start")?;
        let end = o.get("end").and_then(Value::as_i64).ok_or("bad end")?;
        let strings = |k: &str| -> Result<Vec<String>, String> {
            o.get(k)
                .and_then(Value::as_array)
                .ok_or(format!("bad {k}"))?
                .iter()
                .map(|x| x.as_str().map(str::to_string).ok_or(format!("bad {k} entry")))
                .collect()
        };
        let apps = strings("apps")?;
        let mons = strings("mons")?;
        let progs = if o.contains_key("progs") { strings("progs")? } else { Vec::new() };
        let mut iv = Vec::new();
        for x in o.get("iv").and_then(Value::as_array).ok_or("bad iv")? {
            let a = x.as_array().filter(|a| a.len() == 4 || a.len() == 5).ok_or("bad iv row")?;
            let n = |i: usize| a[i].as_i64().ok_or("bad iv number");
            let (s, e, app, mon) = (n(0)?, n(1)?, n(2)?, n(3)?);
            let prog = if a.len() == 5 { n(4)? } else { -1 };
            if app < 0
                || mon < 0
                || app as usize >= apps.len()
                || mon as usize >= mons.len()
                || e < s
                || prog >= progs.len() as i64
                || (a.len() == 5 && prog < 0)
            {
                return Err("iv row out of range".into());
            }
            let prog = if prog < 0 { NO_PROG } else { prog as u32 };
            iv.push(Iv { s, e, app: app as u32, mon: mon as u32, prog });
        }
        iv.sort_by_key(|v| v.s);
        let mut breaks = Vec::new();
        for x in o.get("breaks").and_then(Value::as_array).ok_or("bad breaks")? {
            let a = x.as_array().filter(|a| a.len() == 2).ok_or("bad break row")?;
            breaks.push((a[0].as_i64().ok_or("bad break time")?, a[1].as_str().ok_or("bad break why")?.to_string()));
        }
        breaks.sort_by_key(|b| b.0);
        Ok(Day { date, start, end, apps, mons, progs, iv, breaks })
    }

    /// The day file's object. `sum` is the derived cache.
    pub fn to_value(&self, sum: &Sum) -> Value {
        let iv = |v: &Iv| {
            if v.prog == NO_PROG {
                json!([v.s, v.e, v.app, v.mon])
            } else {
                json!([v.s, v.e, v.app, v.mon, v.prog])
            }
        };
        let mut o = json!({
            "v": 1,
            "date": self.date.to_string(),
            "start": self.start,
            "end": self.end,
            "apps": self.apps,
            "mons": self.mons,
            "iv": self.iv.iter().map(iv).collect::<Vec<_>>(),
            "breaks": self.breaks.iter().map(|(t, w)| json!([t, w])).collect::<Vec<_>>(),
            "sum": sum.to_value(),
        });
        if !self.progs.is_empty() {
            o["progs"] = json!(self.progs);
        }
        o
    }
}

/// The longest single non-Desktop interval.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Longest {
    pub app: String,
    pub s: i64,
    pub at: i64,
}

/// A session's part within one day: `(start, end, active seconds, cont)`.
pub type SessionPart = (i64, i64, i64, bool);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Sum {
    pub total: i64,
    pub apps: BTreeMap<String, i64>,
    pub hours: [i64; 24],
    pub app_hours: BTreeMap<String, [i64; 24]>,
    pub first: Option<i64>,
    pub last: Option<i64>,
    pub switches: i64,
    pub longest: Option<Longest>,
    pub sessions: Vec<SessionPart>,
    pub pickups: i64,
    pub mons: BTreeMap<String, i64>,
    /// app -> program -> seconds, for the terminal apps whose programs were read.
    pub sub: BTreeMap<String, BTreeMap<String, i64>>,
}

/// Milliseconds to whole seconds, to the nearest.
pub fn secs(ms: i64) -> i64 {
    (ms + 500).div_euclid(1000)
}

fn hour_index(cal: &dyn Calendar, t: i64, dsh: u32) -> usize {
    let h = if cfg!(feature = "arm-dst") { t.div_euclid(3_600_000).rem_euclid(24) as u32 } else { cal.local(t).hour };
    ((h + 24 - dsh) % 24) as usize
}

fn next_hour_boundary(cal: &dyn Calendar, t: i64) -> i64 {
    if cfg!(feature = "arm-dst") {
        return (t.div_euclid(3_600_000) + 1) * 3_600_000;
    }
    let l = cal.local(t);
    let into = i64::from(l.min * 60 + l.sec) * 1000 + t.rem_euclid(1000);
    t - into + 3_600_000
}

/// Everything derived from a day's intervals and breaks.
pub fn compute_sum(day: &Day, cal: &dyn Calendar, dsh: u32) -> Sum {
    let mut total = 0i64;
    let mut app_ms = vec![0i64; day.apps.len()];
    let mut mon_ms = vec![0i64; day.mons.len()];
    let mut hours = [0i64; 24];
    let mut app_hours = vec![[0i64; 24]; day.apps.len()];
    let mut switches = 0i64;
    let mut longest: Option<(i64, usize, i64)> = None;
    // A STAY: one app over touching intervals with no break between them, so a monitor or program
    // change does not end it. The longest stretch is the longest stay. A switch is a change of app
    // between stays of MIN_STAY_MS or more; a shorter one -- the pointer crossing a window, focus
    // passing through on a workspace change (342 of 784 "switches" on a real day) -- passes
    // through like the Desktop. Its time counts all the same.
    let mut run: Option<(u32, i64, i64)> = None;
    let mut prog_ms: BTreeMap<(u32, u32), i64> = BTreeMap::new();
    let mut sessions: Vec<(i64, i64, i64, bool)> = Vec::new();
    let mut breaks: Vec<i64> = day.breaks.iter().map(|b| b.0).collect();
    breaks.sort_unstable();
    let mut bi = 0usize;
    let mut prev_e: Option<i64> = None;
    let mut last_nd: Option<u32> = None;
    let desktop = day.apps.iter().position(|a| a == DESKTOP).map(|i| i as u32);
    let settle =
        |r: Option<(u32, i64, i64)>, last: &mut Option<u32>, sw: &mut i64, lg: &mut Option<(i64, usize, i64)>| {
            let Some((a, s, e)) = r else { return };
            if Some(a) == desktop {
                return;
            }
            if e - s >= MIN_STAY_MS || cfg!(feature = "arm-bounce") {
                if last.is_some_and(|l| l != a) {
                    *sw += 1;
                }
                *last = Some(a);
            }
            if lg.is_none_or(|(d, _, _)| e - s > d) {
                *lg = Some((e - s, a as usize, s));
            }
        };
    for v in &day.iv {
        let dur = v.e - v.s;
        if dur <= 0 {
            continue;
        }
        total += dur;
        app_ms[v.app as usize] += dur;
        mon_ms[v.mon as usize] += dur;
        if v.prog != NO_PROG {
            *prog_ms.entry((v.app, v.prog)).or_insert(0) += dur;
        }
        let mut t = v.s;
        while t < v.e {
            let next = next_hour_boundary(cal, t).min(v.e).max(t + 1);
            let h = hour_index(cal, t, dsh);
            hours[h] += next - t;
            app_hours[v.app as usize][h] += next - t;
            t = next;
        }
        // Session grouping: a break at or after the previous interval's end and at or before this
        // one's start separates them (before the day's first interval: any break since the day began).
        let lo = prev_e.unwrap_or(day.start);
        let mut broke = false;
        while bi < breaks.len() && breaks[bi] <= v.s {
            if breaks[bi] >= lo {
                broke = true;
            }
            bi += 1;
        }
        let touching = prev_e == Some(v.s) && !broke;
        let extends = matches!(run, Some((a, _, _)) if a == v.app && touching);
        if !extends {
            settle(run.take(), &mut last_nd, &mut switches, &mut longest);
        }
        if prev_e.is_none() || broke {
            sessions.push((v.s, v.e, 0, prev_e.is_none() && !broke && v.s == day.start));
            last_nd = None;
        }
        if let Some(s) = sessions.last_mut() {
            s.1 = v.e;
            s.2 += dur;
        }
        prev_e = Some(v.e);
        run = match run {
            Some((a, s, _)) if extends => Some((a, s, v.e)),
            _ => Some((v.app, v.s, v.e)),
        };
    }
    settle(run, &mut last_nd, &mut switches, &mut longest);
    let mut apps = BTreeMap::new();
    let mut ah = BTreeMap::new();
    for (i, name) in day.apps.iter().enumerate() {
        if app_ms[i] > 0 {
            apps.insert(name.clone(), secs(app_ms[i]));
            ah.insert(name.clone(), app_hours[i].map(secs));
        }
    }
    let mut mons = BTreeMap::new();
    for (i, name) in day.mons.iter().enumerate() {
        if mon_ms[i] > 0 {
            mons.insert(name.clone(), secs(mon_ms[i]));
        }
    }
    let pickups = sessions.iter().filter(|s| !s.3).count() as i64;
    let mut sub: BTreeMap<String, BTreeMap<String, i64>> = BTreeMap::new();
    for ((a, pr), ms) in prog_ms {
        if ms > 0 {
            sub.entry(day.apps[a as usize].clone()).or_default().insert(day.progs[pr as usize].clone(), secs(ms));
        }
    }
    Sum {
        total: secs(total),
        apps,
        hours: hours.map(secs),
        app_hours: ah,
        first: day.iv.iter().find(|v| v.e > v.s).map(|v| v.s),
        last: day.iv.iter().rev().find(|v| v.e > v.s).map(|v| v.e),
        switches,
        longest: longest.map(|(d, a, at)| Longest { app: day.apps[a].clone(), s: secs(d), at }),
        sessions: sessions.into_iter().map(|(s, e, a, c)| (s, e, secs(a), c)).collect(),
        pickups,
        mons,
        sub,
    }
}

impl Sum {
    pub fn to_value(&self) -> Value {
        let apps: Map<String, Value> = self.apps.iter().map(|(k, v)| (k.clone(), json!(v))).collect();
        let app_hours: Map<String, Value> = self.app_hours.iter().map(|(k, v)| (k.clone(), json!(v))).collect();
        let mons: Map<String, Value> = self.mons.iter().map(|(k, v)| (k.clone(), json!(v))).collect();
        let longest = match &self.longest {
            Some(l) => json!({"app": l.app, "s": l.s, "at": l.at}),
            None => json!({"app": null, "s": 0, "at": null}),
        };
        let mut o = json!({
            "total": self.total,
            "apps": apps,
            "hours": self.hours,
            "appHours": app_hours,
            "first": self.first,
            "last": self.last,
            "switches": self.switches,
            "longest": longest,
            "sessions": self.sessions.iter().map(|(s, e, a, c)| json!([s, e, a, c])).collect::<Vec<_>>(),
            "pickups": self.pickups,
            "mons": mons,
        });
        if !self.sub.is_empty() {
            o["sub"] = json!(self.sub);
        }
        o
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cal::TableCal;

    fn day() -> (Day, TableCal) {
        let cal = TableCal::brussels();
        let date = Date { y: 2026, m: 10, d: 3 };
        let (s, e) = crate::cal::day_bounds(&cal, date, 4);
        (Day::new(date, s, e), cal)
    }

    fn put(d: &mut Day, s: i64, e: i64, app: &str) {
        let a = d.app_idx(app);
        let m = d.mon_idx("eDP-1");
        d.iv.push(Iv { s, e, app: a, mon: m, prog: NO_PROG });
    }

    #[test]
    fn compact_renumbers_by_first_use_and_drops_unused() {
        let (mut d, _) = day();
        d.app_idx("ghost");
        let s0 = d.start;
        put(&mut d, s0 + 10_000, s0 + 20_000, "zen");
        put(&mut d, s0 + 20_000, s0 + 30_000, "kitty");
        let c = d.compacted();
        assert_eq!(c.apps, vec!["zen", "kitty"]);
    }

    #[test]
    fn day_value_round_trips() {
        let (mut d, cal) = day();
        let s0 = d.start;
        put(&mut d, s0 + 1000, s0 + 61_000, "kitty");
        d.add_break(s0 + 70_000, "lock");
        let v = d.to_value(&compute_sum(&d, &cal, 4));
        assert_eq!(Day::from_value(&v).unwrap(), d);
    }

    #[test]
    fn corrupt_day_files_are_refused() {
        for bad in [json!([]), json!({"v": 2}), json!({"v":1,"date":"x"})] {
            assert!(Day::from_value(&bad).is_err());
        }
    }

    #[test]
    fn rounding_is_to_the_nearest_second() {
        assert_eq!((secs(499), secs(500), secs(1499), secs(1500)), (0, 1, 1, 2));
    }
}
