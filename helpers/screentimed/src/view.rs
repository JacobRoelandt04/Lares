//! Replies and pushes: the STATE object and the week / day / range queries, from the live core (when
//! there is one) and the day files. `serve-frozen` uses the same code with no core.

use crate::cal::{day_bounds, logical_date, Calendar, Date};
use crate::core::{Cfg, Core, Snap, R_ASLEEP, R_IDLE, R_LOCKED, R_NOSESSION};
use crate::day::{compute_sum, Day, Sum};
use crate::proto::{err_reply, ok_reply};
use crate::store::Store;
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;

pub struct View<'a> {
    pub cfg: &'a Cfg,
    pub cal: &'a dyn Calendar,
    pub store: &'a Store,
    pub core: Option<&'a Core>,
    pub now: i64,
}

fn away_names(r: u8) -> Vec<&'static str> {
    let mut v = Vec::new();
    for (bit, name) in [(R_IDLE, "idle"), (R_LOCKED, "locked"), (R_ASLEEP, "asleep"), (R_NOSESSION, "nosession")] {
        if r & bit != 0 {
            v.push(name);
        }
    }
    v
}

fn map_i64(m: &BTreeMap<String, i64>) -> Value {
    Value::Object(m.iter().map(|(k, v)| (k.clone(), json!(v))).collect::<Map<_, _>>())
}

fn state_value(s: &Snap, cfg: &Cfg) -> Value {
    json!({
        "now": s.now,
        "day": s.date.to_string(),
        "dayStart": s.day_start,
        "dayEnd": s.day_end,
        "active": s.r == 0,
        "away": away_names(s.r),
        "awaySince": s.away_since,
        "app": s.app,
        "mon": s.mon,
        "appSince": s.app_since,
        "prog": s.prog,
        "stretchSince": s.stretch_since,
        "session": s.session.map(|(st, a)| json!({"start": st, "active": a})),
        "lastSession": s.last_session.as_ref().map(|l| json!({"start": l.start, "end": l.end, "active": l.active_s, "why": l.why})),
        "today": {"total": s.today_total, "apps": map_i64(&s.today_apps)},
        "focusedMon": s.focused_mon,
        "focusedMonSince": s.focused_mon_since,
        "lastFocus": map_i64(&s.last_focus),
        "present": s.present,
        "dropped": s.dropped,
        "config": {"dayStartHour": cfg.day_start_hour, "weekStart": cfg.week_start, "sessionBreakMin": cfg.session_break_min},
    })
}

impl View<'_> {
    fn today(&self) -> Date {
        match self.core {
            Some(c) => c.date_of(self.now),
            None => logical_date(self.cal, self.now, self.cfg.day_start_hour),
        }
    }

    pub fn state(&self) -> Value {
        if let Some(c) = self.core {
            return state_value(&c.snapshot(self.now), self.cfg);
        }
        // Frozen: from the files, as of `now`, nobody at the keyboard.
        let date = self.today();
        let (ds, de) = day_bounds(self.cal, date, self.cfg.day_start_hour);
        let sum = self.store.read_day_value(date).and_then(|v| v.get("sum").cloned());
        let total = sum.as_ref().and_then(|s| s.get("total")).and_then(Value::as_i64).unwrap_or(0);
        let apps: BTreeMap<String, i64> = sum
            .as_ref()
            .and_then(|s| s.get("apps"))
            .and_then(Value::as_object)
            .map(|o| o.iter().map(|(k, v)| (k.clone(), v.as_i64().unwrap_or(0))).collect())
            .unwrap_or_default();
        let snap = Snap {
            now: self.now,
            date,
            day_start: ds,
            day_end: de,
            r: R_NOSESSION,
            away_since: None,
            app: None,
            mon: None,
            app_since: None,
            prog: None,
            stretch_since: None,
            session: None,
            last_session: None,
            today_total: total,
            today_apps: apps,
            focused_mon: None,
            focused_mon_since: None,
            last_focus: BTreeMap::new(),
            present: Vec::new(),
            dropped: 0,
        };
        state_value(&snap, self.cfg)
    }

    pub fn state_push(&self) -> String {
        json!({"v": 1, "ev": "state", "state": self.state()}).to_string()
    }

    pub fn focus_push(&self) -> String {
        let Some(c) = self.core else { return String::new() };
        let s = c.snapshot(self.now);
        json!({
            "v": 1, "ev": "focus", "app": s.app, "mon": s.mon, "since": s.app_since,
            "prog": s.prog, "stretchSince": s.stretch_since,
            "today": {"total": s.today_total, "apps": map_i64(&s.today_apps)},
        })
        .to_string()
    }

    pub fn monitors_push(&self) -> String {
        let Some(c) = self.core else { return String::new() };
        let s = c.snapshot(self.now);
        json!({
            "v": 1, "ev": "monitors", "focusedMon": s.focused_mon, "focusedMonSince": s.focused_mon_since,
            "lastFocus": map_i64(&s.last_focus), "present": s.present,
        })
        .to_string()
    }

    /// A live day (RAM) as `(day, open)` for a date.
    fn live(&self, date: Date) -> Option<(Day, bool)> {
        self.core?.live_day(date, self.now)
    }

    /// The `sum` of a day with data (or today), and whether it came from RAM.
    fn sum_value(&self, date: Date) -> Option<Value> {
        if let Some((d, _)) = self.live(date) {
            return Some(compute_sum(&d, self.cal, self.cfg.day_start_hour).to_value());
        }
        self.store.read_day_value(date)?.get("sum").cloned()
    }

    fn status_of(&self, date: Date, has: bool) -> &'static str {
        if date > self.today() {
            "future"
        } else if has || date == self.today() {
            "ok"
        } else {
            "none"
        }
    }

    fn daysum(&self, date: Date) -> Value {
        let (s, e) = day_bounds(self.cal, date, self.cfg.day_start_hour);
        let sum = if date > self.today() { None } else { self.sum_value(date) };
        let sum = match sum {
            None if date == self.today() => {
                let empty = Day::new(date, s, e);
                Some(compute_sum(&empty, self.cal, self.cfg.day_start_hour).to_value())
            }
            other => other,
        };
        json!({"date": date.to_string(), "status": self.status_of(date, sum.is_some()), "start": s, "end": e, "sum": sum})
    }

    pub fn week(&self, id: &Value, from: &str) -> String {
        let Some(d) = Date::parse(from) else { return err_reply(id, "baddate") };
        if d.weekday() != self.cfg.week_start {
            return err_reply(id, "notweekstart");
        }
        let days: Vec<Value> = (0..7).map(|i| self.daysum(d.add_days(i))).collect();
        ok_reply(id, "week", json!({"from": from, "days": days}))
    }

    pub fn day(&self, id: &Value, date: &str) -> String {
        let Some(d) = Date::parse(date) else { return err_reply(id, "baddate") };
        let mut v = self.daysum(d);
        let o = v.as_object_mut().expect("object");
        let mut open = false;
        if d <= self.today() {
            if let Some((day, op)) = self.live(d) {
                let c = day.compacted();
                let sum: Sum = compute_sum(&c, self.cal, self.cfg.day_start_hour);
                let full = c.to_value(&sum);
                for k in ["apps", "mons", "iv", "breaks"] {
                    o.insert(k.into(), full[k].clone());
                }
                open = op;
            } else if let Some(full) = self.store.read_day_value(d) {
                for k in ["apps", "mons", "iv", "breaks"] {
                    o.insert(k.into(), full.get(k).cloned().unwrap_or(json!([])));
                }
            }
        }
        for k in ["apps", "mons", "iv", "breaks"] {
            o.entry(k).or_insert(json!([]));
        }
        if open {
            o.insert("open".into(), json!(true));
        }
        ok_reply(id, "day", v)
    }

    pub fn range(&self, id: &Value, from: &str, to: &str) -> String {
        let (Some(a), Some(b)) = (Date::parse(from), Date::parse(to)) else { return err_reply(id, "baddate") };
        if b < a || b.days() - a.days() >= 400 {
            return err_reply(id, "badrequest");
        }
        let mut m = Map::new();
        for i in 0..=(b.days() - a.days()) {
            let d = a.add_days(i);
            if d > self.today() {
                break;
            }
            if let Some(total) = self.sum_value(d).and_then(|s| s.get("total").and_then(Value::as_i64)) {
                if total > 0 {
                    m.insert(d.to_string(), json!(total));
                }
            }
        }
        ok_reply(id, "range", Value::Object(m))
    }
}
