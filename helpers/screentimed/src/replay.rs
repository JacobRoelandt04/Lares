//! `replay` (an NDJSON event log through the pure core with explicit clocks) and `rebuild`.
//!
//! A line is `{"wall":ms,"mono":ms,"boot":ms,"in":{"k":KIND,...}}`; `mono` and `boot` default to
//! `wall`. A line without `in` but with `cfg` configures the core (first line only). Kinds:
//! start{boot,saved?,lockPid?} hyprup{app,mon,monitors} hyprdown focus{app|null} aw{json}
//! focusmon{mon} monadd{mon} monrm{mon} idle{ago} active lock{pid?} unlock sleep wake lockexit{pid}
//! tick roll shutdown reload{cfg} flush. `aw` carries a raw `j/activewindow` reply (titles and all) and
//! goes through the daemon's own parser.

use crate::cal::{Date, LibcCal};
use crate::core::{Cfg, Clocks, Core, Input, LastSess, Output, Saved};
use crate::day::{compute_sum, Day};
use crate::digest;
use crate::hypr;
use crate::store::Store;
use serde_json::Value;
use std::io::Write;
use std::path::Path;

fn s(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(Value::as_str).map(str::to_string)
}

fn saved_from(v: &Value) -> Option<Saved> {
    let ls = v.get("lastSession").filter(|l| l.is_object()).and_then(|l| {
        Some(LastSess {
            start: l.get("start")?.as_i64()?,
            end: l.get("end")?.as_i64()?,
            active_s: l.get("active")?.as_i64()?,
            why: l.get("why")?.as_str()?.to_string(),
        })
    });
    Some(Saved {
        boot_id: s(v, "bootId")?,
        saved_at: v.get("savedAt")?.as_i64()?,
        session: v
            .get("session")
            .filter(|x| x.is_object())
            .and_then(|x| Some((x.get("start")?.as_i64()?, x.get("active")?.as_i64()?))),
        last_session: ls,
        away_since: v.get("awaySince").and_then(Value::as_i64),
        digest_week: v.get("digestWeek").and_then(Value::as_str).and_then(Date::parse),
        lock_pid: v.get("lockPid").and_then(Value::as_i64).map(|p| p as i32),
    })
}

fn decode(i: &Value, core: &Core, store: &Store, wall: i64) -> Result<Input, String> {
    let k = i.get("k").and_then(Value::as_str).ok_or("input without k")?;
    let pid = |key: &str| i.get(key).and_then(Value::as_i64).map(|p| p as i32);
    Ok(match k {
        "start" => Input::Start {
            boot_id: s(i, "boot").unwrap_or_default(),
            saved: i.get("saved").and_then(saved_from),
            lock_pid: pid("lockPid"),
            day: store.read_day_for_start(core.date_of(wall)),
        },
        "hyprup" => Input::HyprUp {
            app: s(i, "app"),
            prog: s(i, "prog"),
            mon: s(i, "mon").unwrap_or_else(|| "?".into()),
            monitors: i
                .get("monitors")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(|m| m.as_str().map(str::to_string)).collect())
                .unwrap_or_default(),
        },
        "hyprdown" => Input::HyprDown,
        "focus" => Input::Focus { app: s(i, "app"), prog: s(i, "prog") },
        "prog" => Input::Prog(s(i, "prog")),
        "aw" => {
            let raw = s(i, "json").ok_or("aw without json")?;
            Input::Focus { app: hypr::parse_activewindow(raw.as_bytes()).ok_or("unparseable aw")?, prog: s(i, "prog") }
        }
        "focusmon" => Input::FocusMon { mon: s(i, "mon").ok_or("focusmon without mon")? },
        "monadd" => Input::MonitorAdded(s(i, "mon").ok_or("monadd without mon")?),
        "monrm" => Input::MonitorRemoved(s(i, "mon").ok_or("monrm without mon")?),
        "idle" => Input::Idle(i.get("ago").and_then(Value::as_i64).ok_or("idle without ago")?),
        "active" => Input::Active,
        "lock" => Input::Lock(pid("pid")),
        "unlock" => Input::Unlock,
        "sleep" => Input::Sleep,
        "wake" => Input::Wake,
        "lockexit" => Input::LockExited(pid("pid").ok_or("lockexit without pid")?),
        "tick" => Input::Tick,
        "roll" => Input::DayRoll,
        "shutdown" => Input::Shutdown,
        "reload" => Input::Reload(Box::new(Cfg::from_value(i.get("cfg").unwrap_or(&Value::Null)))),
        "flush" => Input::Flush,
        other => return Err(format!("unknown input kind {other}")),
    })
}

fn carry_out(core: &Core, store: &Store, data: &Path, outs: Vec<Output>) {
    for o in outs {
        match o {
            Output::WriteDay(d) => {
                let c = d.compacted();
                let sum = compute_sum(&c, core.calendar(), core.cfg().day_start_hour);
                if let Err(e) = store.write_day(&c, &sum) {
                    eprintln!("replay: {e}");
                }
            }
            Output::WriteState(st) => {
                let _ = store.write_state(&st);
            }
            Output::Digest(week) => {
                let body = store
                    .week_agg(week.add_days(-7))
                    .and_then(|l| digest::compose(&l, store.week_agg(week.add_days(-14)).as_ref(), &core.cfg().names));
                if let Some(b) = body {
                    if let Ok(mut f) =
                        std::fs::OpenOptions::new().create(true).append(true).open(data.join("notify.log"))
                    {
                        let _ = writeln!(f, "Screen time last week | {b}");
                    }
                }
            }
            _ => {}
        }
    }
}

pub fn replay(file: &Path, data: &Path, mut cfg: Cfg) -> Result<(), String> {
    let text = std::fs::read_to_string(file).map_err(|e| format!("{}: {e}", file.display()))?;
    let store = Store::new(data);
    let mut core: Option<Core> = None;
    let mut last = Clocks { wall: 0, mono: 0, boot: 0 };
    for (n, line) in text.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let v: Value = serde_json::from_str(line).map_err(|e| format!("line {}: {e}", n + 1))?;
        let Some(input) = v.get("in") else {
            if let Some(c) = v.get("cfg") {
                cfg = Cfg::from_value(c);
            }
            continue;
        };
        let wall = v.get("wall").and_then(Value::as_i64).ok_or(format!("line {}: no wall", n + 1))?;
        let mono = v.get("mono").and_then(Value::as_i64).unwrap_or(wall);
        let boot = v.get("boot").and_then(Value::as_i64).unwrap_or(mono);
        let ck = Clocks { wall, mono, boot };
        last = ck;
        let c = core.get_or_insert_with(|| Core::new(cfg.clone(), Box::new(LibcCal::new())));
        let inp = decode(input, c, &store, wall).map_err(|e| format!("line {}: {e}", n + 1))?;
        let outs = c.handle(inp, ck);
        carry_out(c, &store, data, outs);
    }
    if let Some(c) = core.as_mut() {
        let outs = c.handle(Input::Flush, last);
        carry_out(c, &store, data, outs);
    }
    Ok(())
}

/// Recomputes every day file's `sum` from its `iv` + `breaks`; returns (files, changed).
pub fn rebuild(data: &Path, cfg: &Cfg) -> (usize, usize) {
    let store = Store::new(data);
    let cal = LibcCal::new();
    let (mut n, mut changed) = (0, 0);
    for date in store.list_days() {
        let Some(old) = store.read_day_value(date) else { continue };
        let Ok(day) = Day::from_value(&old) else { continue };
        let c = day.compacted();
        let new = c.to_value(&compute_sum(&c, &cal, cfg.day_start_hour));
        n += 1;
        if new != old {
            let _ = store.write_day(&c, &compute_sum(&c, &cal, cfg.day_start_hour));
            changed += 1;
        }
    }
    (n, changed)
}
