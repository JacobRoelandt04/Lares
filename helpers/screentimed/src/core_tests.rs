//! CONTRACT section 3, one test per edge case, on explicit clocks and a Brussels table calendar.

use super::*;
use crate::cal::TableCal;
use crate::day::compute_sum;

const D: &str = "2026-10-03";

fn at(date: &str, h: u32, m: u32, s: u32) -> i64 {
    TableCal::brussels().resolve_local(Date::parse(date).unwrap(), h, m, s)
}

struct H {
    c: Core,
    wall: i64,
    mono: i64,
    boot: i64,
}

impl H {
    fn new() -> H {
        H::with(Cfg::default())
    }

    fn with(cfg: Cfg) -> H {
        H { c: Core::new(cfg, Box::new(TableCal::brussels())), wall: 0, mono: 1_000_000, boot: 5_000_000 }
    }

    /// Moves every clock forward to this local time.
    fn at(&mut self, date: &str, h: u32, m: u32, s: u32) -> &mut H {
        let w = at(date, h, m, s);
        let d = if self.wall == 0 { 0 } else { w - self.wall };
        self.wall = w;
        self.mono += d;
        self.boot += d;
        self
    }

    fn send(&mut self, i: Input) -> Vec<Output> {
        self.c.handle(i, Clocks { wall: self.wall, mono: self.mono, boot: self.boot })
    }

    /// Brings the session up: Start, then a Hyprland on one monitor focused on `app`.
    fn up(&mut self, app: &str) {
        self.send(Input::Start { boot_id: "b1".into(), saved: None, lock_pid: None, day: None });
        self.send(Input::HyprUp {
            app: Some(app.into()),
            prog: None,
            mon: "eDP-1".into(),
            monitors: vec!["eDP-1".into()],
        });
    }

    fn focus(&mut self, app: &str) {
        self.send(Input::Focus { app: Some(app.into()), prog: None });
    }

    fn day(&self, date: &str) -> &Day {
        let d = Date::parse(date).unwrap();
        &self.c.days.iter().find(|r| r.day.date == d).expect("day in RAM").day
    }

    /// Closed intervals of a day as (start, end, app), times in ms.
    fn ivs(&self, date: &str) -> Vec<(i64, i64, String)> {
        let d = self.day(date);
        d.iv.iter().map(|v| (v.s, v.e, d.apps[v.app as usize].clone())).collect()
    }

    fn sum(&self, date: &str) -> crate::day::Sum {
        compute_sum(self.day(date), self.c.calendar(), 4)
    }

    fn snap(&self) -> Snap {
        self.c.snapshot(self.wall)
    }
}

fn app(s: &str) -> String {
    s.to_string()
}

#[test]
fn backdate_across_a_focus_change() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("kitty");
    h.at(D, 10, 1, 0).focus("zen");
    h.at(D, 10, 2, 0).focus("code");
    let outs = h.at(D, 10, 3, 0).send(Input::Idle(90));
    // t* = 10:01:30: kitty keeps its minute, zen is cut at t*, code (started after t*) is dropped.
    assert_eq!(
        h.ivs(D),
        vec![(at(D, 10, 0, 0), at(D, 10, 1, 0), app("kitty")), (at(D, 10, 1, 0), at(D, 10, 1, 30), app("zen"))]
    );
    assert_eq!(h.snap().away_since, Some(at(D, 10, 1, 30)));
    assert!(outs.iter().any(|o| matches!(o, Output::WriteDay(_))), "idle writes the file");
    assert_eq!(h.snap().session, Some((at(D, 10, 0, 0), 90)), "session.active lost the removed time");
}

#[test]
fn backdate_across_the_0400_roll() {
    let mut h = H::new();
    h.at("2026-10-03", 23, 50, 0).up("kitty");
    let outs = h.at("2026-10-04", 4, 5, 0).send(Input::Idle(900));
    // activeSince 23:50 < t* 03:50 (ago 900 s from 04:05): yesterday is cut at 03:50, today's is dropped.
    assert_eq!(h.ivs("2026-10-03"), vec![(at("2026-10-03", 23, 50, 0), at("2026-10-04", 3, 50, 0), app("kitty"))]);
    assert!(h.ivs("2026-10-04").is_empty());
    assert!(
        outs.iter().any(|o| matches!(o, Output::PushDay(d) if d.to_string() == "2026-10-03")),
        "yesterday's file was rewritten"
    );
    let wrote_yesterday = outs.iter().any(|o| matches!(o, Output::WriteDay(d) if d.date.to_string() == "2026-10-03"));
    assert!(wrote_yesterday);
}

#[test]
fn backdate_longer_than_the_open_interval_cascades_into_the_one_before() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("kitty");
    h.at(D, 10, 0, 10).focus("zen");
    h.at(D, 10, 2, 0).send(Input::Idle(115));
    // t* = 10:00:05, before zen even started: zen is dropped whole and kitty is cut.
    assert_eq!(h.ivs(D), vec![(at(D, 10, 0, 0), at(D, 10, 0, 5), app("kitty"))]);
}

#[test]
fn ago_greater_than_max_backdate_is_clamped_and_never_before_active_since() {
    let mut h = H::new();
    h.at(D, 9, 0, 0).up("kitty");
    h.at(D, 10, 0, 0).send(Input::Idle(3600));
    assert_eq!(h.ivs(D), vec![(at(D, 9, 0, 0), at(D, 9, 45, 0), app("kitty"))], "maxBackdateS 900 -> 09:45");
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("kitty");
    h.at(D, 10, 1, 0).send(Input::Idle(600));
    assert!(h.ivs(D).is_empty(), "t* cannot go before the moment the user became active");
    assert_eq!(h.snap().away_since, Some(at(D, 10, 0, 0)));
}

#[test]
fn dst_fall_back_logical_day_is_25_hours_and_both_halves_share_a_bucket() {
    let mut h = H::new();
    h.at("2026-10-24", 23, 30, 0).up("kitty");
    h.at("2026-10-25", 3, 30, 0).send(Input::Shutdown);
    let d = Date::parse("2026-10-24").unwrap();
    assert_eq!(h.day("2026-10-24").end - h.day("2026-10-24").start, 25 * 3_600_000);
    let s = h.sum("2026-10-24");
    assert_eq!(s.total, 5 * 3600, "23:30 CEST to 03:30 CET is five real hours");
    assert_eq!(s.hours.iter().sum::<i64>(), s.total);
    assert_eq!(s.hours[22], 2 * 3600, "02:00-03:00 CEST and 02:00-03:00 CET are one bucket");
    assert_eq!((s.hours[19], s.hours[20], s.hours[21], s.hours[23]), (1800, 3600, 3600, 1800));
    assert_eq!(h.day("2026-10-24").date, d);
}

#[test]
fn dst_spring_forward_logical_day_is_23_hours() {
    let mut h = H::new();
    h.at("2027-03-27", 23, 30, 0).up("kitty");
    h.at("2027-03-28", 3, 30, 0).send(Input::Shutdown);
    let day = h.day("2027-03-27");
    assert_eq!(day.end - day.start, 23 * 3_600_000);
    let s = h.sum("2027-03-27");
    assert_eq!(s.total, 3 * 3600, "23:30 CET to 03:30 CEST is three real hours");
    assert_eq!(s.hours[22], 0, "the 02:xx hour does not exist that night");
    assert_eq!(s.hours.iter().sum::<i64>(), s.total);
}

#[test]
fn daemon_start_mid_session_continues_the_session_on_the_same_boot() {
    let mut h = H::new();
    // today's file already holds 10 minutes of kitty
    let date = Date::parse(D).unwrap();
    let (st, en) = day_bounds(&TableCal::brussels(), date, 4);
    let mut day = Day::new(date, st, en);
    let a = day.app_idx("kitty");
    let m = day.mon_idx("eDP-1");
    day.iv.push(Iv { s: at(D, 9, 50, 0), e: at(D, 10, 0, 0), app: a, mon: m, prog: crate::day::NO_PROG });
    let saved = Saved {
        boot_id: "b1".into(),
        saved_at: at(D, 10, 0, 0),
        session: Some((at(D, 9, 0, 0), 600)),
        last_session: None,
        away_since: None,
        digest_week: Date::parse("2026-09-28"),
        lock_pid: None,
    };
    h.at(D, 10, 2, 0).send(Input::Start { boot_id: "b1".into(), saved: Some(saved), lock_pid: None, day: Some(day) });
    h.send(Input::HyprUp { app: Some("kitty".into()), prog: None, mon: "eDP-1".into(), monitors: vec![] });
    let s = h.snap();
    assert_eq!(s.session, Some((at(D, 9, 0, 0), 600)), "same session, its active seconds carried");
    assert!(h.day(D).breaks.is_empty(), "no break: the daemon restart was shorter than the session break");
    assert_eq!(h.day(D).iv.len(), 1, "the file's interval is kept and appended to");
}

#[test]
fn daemon_start_on_another_boot_or_after_the_break_starts_a_new_session() {
    for (boot, minutes) in [("b2", 2u32), ("b1", 9u32)] {
        let mut h = H::new();
        let date = Date::parse(D).unwrap();
        let (st, en) = day_bounds(&TableCal::brussels(), date, 4);
        let mut day = Day::new(date, st, en);
        let a = day.app_idx("kitty");
        let m = day.mon_idx("eDP-1");
        day.iv.push(Iv { s: at(D, 9, 50, 0), e: at(D, 10, 0, 0), app: a, mon: m, prog: crate::day::NO_PROG });
        let saved = Saved {
            boot_id: "b1".into(),
            saved_at: at(D, 10, 0, 0),
            session: Some((at(D, 9, 0, 0), 600)),
            last_session: None,
            away_since: None,
            digest_week: None,
            lock_pid: None,
        };
        h.at(D, 10, minutes, 0).send(Input::Start {
            boot_id: boot.into(),
            saved: Some(saved),
            lock_pid: None,
            day: Some(day),
        });
        h.send(Input::HyprUp { app: Some("kitty".into()), prog: None, mon: "eDP-1".into(), monitors: vec![] });
        assert_eq!(h.snap().session.map(|s| s.0), Some(h.wall), "{boot} +{minutes}m: a new session starts now");
        assert_eq!(h.snap().last_session.map(|l| l.why), Some("stop".to_string()));
        assert_eq!(
            h.day(D).breaks,
            vec![(at(D, 10, 0, 0), "stop".to_string())],
            "the file's earlier part is a finished session"
        );
        h.at(D, 10, minutes + 1, 0).send(Input::Shutdown);
        assert_eq!(h.sum(D).sessions.len(), 2);
    }
}

#[test]
fn hyprland_eof_goes_nosession_and_rediscovery_resumes_the_session() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("kitty");
    h.at(D, 10, 0, 30).send(Input::HyprDown);
    assert_eq!(h.snap().r, R_NOSESSION);
    assert_eq!(h.ivs(D), vec![(at(D, 10, 0, 0), at(D, 10, 0, 30), app("kitty"))], "intervals close at the EOF");
    h.at(D, 10, 0, 50).send(Input::HyprUp {
        app: Some("zen".into()),
        prog: None,
        mon: "eDP-1".into(),
        monitors: vec!["eDP-1".into()],
    });
    assert!(h.c.is_active());
    assert_eq!(h.snap().session.map(|s| s.0), Some(at(D, 10, 0, 0)), "a short gap keeps the session");
    // a long one ends it with a nosession break at the moment Hyprland went away
    h.at(D, 10, 10, 0).send(Input::HyprDown);
    h.at(D, 10, 20, 0).send(Input::HyprUp { app: None, prog: None, mon: "eDP-1".into(), monitors: vec![] });
    assert_eq!(h.snap().session.map(|s| s.0), Some(at(D, 10, 20, 0)));
    assert!(h.day(D).breaks.contains(&(at(D, 10, 10, 0), "nosession".to_string())));
    assert_eq!(h.snap().app.as_deref(), Some(DESKTOP));
}

#[test]
fn empty_workspace_is_desktop() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("kitty");
    h.at(D, 10, 1, 0).send(Input::Focus { app: None, prog: None });
    assert_eq!(h.snap().app.as_deref(), Some("~desktop"));
    assert_eq!(h.snap().app_since, Some(at(D, 10, 1, 0)));
    h.at(D, 10, 2, 0).send(Input::Shutdown);
    assert_eq!(h.ivs(D)[1], (at(D, 10, 1, 0), at(D, 10, 2, 0), app("~desktop")));
    assert_eq!(h.sum(D).total, 120, "Desktop counts as screen time");
}

#[test]
fn wake_while_locked_stays_away() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("kitty");
    h.at(D, 10, 5, 0).send(Input::Lock(None));
    h.at(D, 10, 6, 0).send(Input::Sleep);
    h.at(D, 10, 7, 0).send(Input::Wake);
    assert_eq!(h.snap().r, R_LOCKED, "asleep went, locked stays");
    assert!(!h.c.is_active());
    h.at(D, 10, 8, 0).send(Input::Unlock);
    assert!(h.c.is_active());
    assert_eq!(h.snap().session.map(|s| s.0), Some(at(D, 10, 8, 0)), "a lock ended the session");
    assert_eq!(h.snap().last_session.map(|l| (l.end, l.why)), Some((at(D, 10, 5, 0), "lock".to_string())));
}

#[test]
fn unannounced_suspend_is_placed_by_the_boottime_gap_and_a_late_sleep_feed_is_ignored() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("kitty");
    h.at(D, 10, 9, 50).send(Input::Tick);
    // suspended 10:10:00 - 10:30:00 (1200 s): BOOTTIME runs on, MONOTONIC does not
    h.at(D, 10, 30, 5);
    h.mono -= 1_200_000;
    let outs = h.send(Input::Tick);
    assert_eq!(h.ivs(D), vec![(at(D, 10, 0, 0), at(D, 10, 10, 5), app("kitty"))], "cut at W - d");
    assert!(h.day(D).breaks.contains(&(at(D, 10, 10, 5), "sleep".to_string())));
    assert!(h.c.is_active(), "R is unchanged: the user woke it");
    assert_eq!(h.snap().session.map(|s| s.0), Some(at(D, 10, 30, 5)), "a new session starts at the wake");
    assert!(outs.iter().any(|o| matches!(o, Output::WriteDay(_))));
    h.at(D, 10, 30, 7).send(Input::Sleep);
    assert!(h.c.is_active(), "a sleep feed within 5 s of the detection is the late echo");
    h.send(Input::Wake);
    assert!(h.c.is_active());
    h.at(D, 10, 31, 0).send(Input::Sleep);
    assert!(!h.c.is_active(), "a later sleep feed is real");
}

#[test]
fn duplicate_feeds_are_idempotent() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("kitty");
    h.at(D, 10, 2, 0).send(Input::Idle(60));
    let after_first = (h.ivs(D), h.snap().away_since, h.snap().r);
    h.at(D, 10, 2, 10).send(Input::Idle(5));
    assert_eq!((h.ivs(D), h.snap().away_since, h.snap().r), after_first, "a second idle changes nothing");
    h.at(D, 10, 3, 0).send(Input::Active);
    h.send(Input::Active);
    assert!(h.c.is_active());
    assert_eq!(h.ivs(D).len(), 1);
    h.at(D, 10, 4, 0).send(Input::Lock(None));
    let r = h.snap().away_since;
    h.at(D, 10, 4, 5).send(Input::Lock(None));
    assert_eq!(h.snap().away_since, r);
    h.send(Input::Unlock);
    h.send(Input::Unlock);
    h.at(D, 10, 5, 0).send(Input::Sleep);
    h.send(Input::Sleep);
    h.send(Input::Wake);
    h.send(Input::Wake);
    assert!(h.c.is_active());
    let before = h.ivs(D).len();
    h.send(Input::Active);
    assert_eq!(h.ivs(D).len(), before, "active while not idle does nothing");
}

#[test]
fn monitor_unplugged_while_focused_moves_the_interval_by_focusedmon_alone() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).send(Input::Start { boot_id: "b".into(), saved: None, lock_pid: None, day: None });
    h.send(Input::HyprUp {
        app: Some("kitty".into()),
        prog: None,
        mon: "LOCK-2".into(),
        monitors: vec!["LOCK-1".into(), "LOCK-2".into()],
    });
    h.at(D, 10, 1, 0).send(Input::FocusMon { mon: "LOCK-1".into() });
    h.send(Input::MonitorRemoved("LOCK-2".into()));
    let s = h.snap();
    assert_eq!((s.mon.as_deref(), s.app.as_deref()), (Some("LOCK-1"), Some("kitty")));
    assert_eq!(s.present, vec!["LOCK-1".to_string()]);
    assert_eq!(s.focused_mon.as_deref(), Some("LOCK-1"));
    assert_eq!(s.focused_mon_since, Some(at(D, 10, 1, 0)));
    assert_eq!(s.last_focus.get("LOCK-2"), Some(&at(D, 10, 1, 0)), "the monitor that lost focus got its last moment");
    h.at(D, 10, 2, 0).send(Input::Shutdown);
    let d = h.day(D);
    assert_eq!(d.mons, vec!["LOCK-2".to_string(), "LOCK-1".to_string()]);
    assert_eq!(h.sum(D).mons.get("LOCK-2"), Some(&60));
    assert_eq!(h.sum(D).switches, 0, "the same app on another monitor is no switch");
}

#[test]
fn wall_clock_stepped_back_never_makes_a_negative_or_overlapping_interval() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("kitty");
    h.at(D, 10, 30, 0).focus("zen");
    // the wall clock jumps back an hour (monotonic goes on)
    h.wall = at(D, 9, 30, 0);
    h.mono += 60_000;
    h.boot += 60_000;
    h.focus("code");
    h.wall = at(D, 9, 45, 0);
    h.mono += 900_000;
    h.boot += 900_000;
    h.send(Input::Shutdown);
    let ivs = h.ivs(D);
    for w in ivs.windows(2) {
        assert!(w[0].1 <= w[1].0, "sorted and non overlapping: {ivs:?}");
    }
    assert!(ivs.iter().all(|(s, e, _)| e > s), "no zero or negative interval: {ivs:?}");
    assert!(h.sum(D).total >= 0);
}

#[test]
fn switches_count_distinct_non_desktop_apps_and_ignore_desktop_in_between() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("kitty");
    h.at(D, 10, 1, 0).send(Input::Focus { app: None, prog: None });
    h.at(D, 10, 2, 0).focus("kitty");
    assert_eq!(h.sum(D).switches, 0, "first focus is no switch, A -> Desktop -> A is none");
    h.at(D, 10, 3, 0).send(Input::Focus { app: None, prog: None });
    h.at(D, 10, 4, 0).focus("zen");
    h.at(D, 10, 5, 0).send(Input::Shutdown);
    assert_eq!(h.sum(D).switches, 1, "A -> Desktop -> B is one");
}

#[test]
fn longest_ignores_desktop_and_pickups_count_sessions() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("kitty");
    h.at(D, 10, 10, 0).send(Input::Focus { app: None, prog: None });
    h.at(D, 10, 40, 0).focus("zen");
    h.at(D, 10, 45, 0).send(Input::Lock(None));
    h.at(D, 10, 50, 0).send(Input::Unlock);
    h.at(D, 11, 0, 0).send(Input::Shutdown);
    let s = h.sum(D);
    let l = s.longest.unwrap();
    assert_eq!((l.app.as_str(), l.s, l.at), ("kitty", 600, at(D, 10, 0, 0)), "the 30 minutes of Desktop do not count");
    assert_eq!(s.pickups, 2, "the lock ended the first session");
    assert_eq!(s.sessions.len(), 2);
    assert_eq!(s.sessions[0].2, 2700, "kitty 10 + desktop 30 + zen 5 minutes");
}

#[test]
fn a_short_idle_pause_keeps_the_session_and_a_long_one_ends_it() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("kitty");
    h.at(D, 10, 10, 0).send(Input::Idle(120));
    assert_eq!(h.snap().away_since, Some(at(D, 10, 8, 0)));
    h.at(D, 10, 11, 0).send(Input::Active);
    let s = h.snap();
    assert_eq!(s.session.map(|x| x.0), Some(at(D, 10, 0, 0)), "3 min < sessionBreakMin: same session");
    assert_eq!(s.session.map(|x| x.1), Some(480), "the pause is not counted");
    h.at(D, 10, 20, 0).send(Input::Idle(120));
    h.at(D, 10, 30, 0).send(Input::Active);
    let s = h.snap();
    assert_eq!(s.session.map(|x| x.0), Some(at(D, 10, 30, 0)), "12 min away ends it");
    assert_eq!(s.last_session.map(|l| (l.end, l.why)), Some((at(D, 10, 18, 0), "idle".to_string())));
    assert!(h.day(D).breaks.contains(&(at(D, 10, 18, 0), "idle".to_string())));
    h.at(D, 10, 40, 0).send(Input::Shutdown);
    let sum = h.sum(D);
    assert_eq!(sum.sessions.len(), 2, "one session before the long break, one after");
    assert_eq!(sum.pickups, 2);
}

#[test]
fn lock_pid_exit_unlocks_and_an_explicit_unlock_clears_the_pid() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("kitty");
    let o = h.at(D, 10, 1, 0).send(Input::Lock(Some(99)));
    assert!(o.iter().any(|x| matches!(x, Output::WatchPid(99))));
    h.send(Input::LockExited(98));
    assert_eq!(h.snap().r, R_LOCKED, "some other pid's exit is not ours");
    h.at(D, 10, 2, 0).send(Input::LockExited(99));
    assert!(h.c.is_active(), "the locker died: unlocked");
    h.at(D, 10, 3, 0).send(Input::Lock(Some(5)));
    let o = h.at(D, 10, 4, 0).send(Input::Unlock);
    assert!(o.iter().any(|x| matches!(x, Output::UnwatchPid)));
    assert!(h.c.is_active());
    h.send(Input::LockExited(5));
    assert!(h.c.is_active());
    // the first pid stays: a second lock-run whose locker refuses to start must not unlock the session
    h.at(D, 10, 5, 0).send(Input::Lock(Some(1)));
    h.send(Input::Lock(Some(2)));
    h.send(Input::LockExited(2));
    assert_eq!(h.snap().r, R_LOCKED);
    h.send(Input::LockExited(1));
    assert!(h.c.is_active());
}

#[test]
fn the_roll_splits_the_open_interval_and_the_session_continues() {
    let mut h = H::new();
    h.at("2026-10-03", 23, 59, 0).up("kitty");
    h.at("2026-10-04", 4, 1, 0).send(Input::DayRoll);
    let b = at("2026-10-04", 4, 0, 0);
    assert_eq!(
        h.ivs("2026-10-03"),
        vec![(at("2026-10-03", 23, 59, 0), b, app("kitty"))],
        "yesterday ends at the boundary"
    );
    assert_eq!(h.snap().app_since, Some(b), "today's interval starts at the boundary");
    h.at("2026-10-04", 4, 2, 0).send(Input::Shutdown);
    assert_eq!(h.ivs("2026-10-04"), vec![(b, at("2026-10-04", 4, 2, 0), app("kitty"))]);
    let s = h.sum("2026-10-04");
    assert_eq!(s.sessions, vec![(b, at("2026-10-04", 4, 2, 0), 120, true)], "the running session continues: cont");
    assert_eq!(s.pickups, 0);
    assert_eq!(h.sum("2026-10-03").pickups, 1);
}

#[test]
fn yesterday_stays_in_ram_until_the_backdate_window_is_over() {
    let mut h = H::new();
    h.at("2026-10-03", 23, 59, 0).up("kitty");
    h.at("2026-10-04", 4, 1, 0).send(Input::DayRoll);
    assert_eq!(h.c.days.len(), 2);
    h.at("2026-10-04", 4, 16, 0).send(Input::Tick);
    assert_eq!(h.c.days.len(), 1, "boundary + maxBackdateS passed: yesterday is final and leaves RAM");
}

#[test]
fn the_flush_tick_writes_only_when_dirty_and_due() {
    let cfg = Cfg { flush_s: 20, check_s: 20, ..Cfg::default() };
    let mut h = H::with(cfg);
    h.at(D, 10, 0, 0).up("kitty");
    h.at(D, 10, 0, 5).focus("zen");
    let o = h.at(D, 10, 0, 10).send(Input::Tick);
    assert!(!o.iter().any(|x| matches!(x, Output::WriteDay(_))), "not due yet");
    let o = h.at(D, 10, 0, 20).send(Input::Tick);
    assert!(o.iter().any(|x| matches!(x, Output::WriteDay(_))), "due and dirty");
    let o = h.at(D, 10, 0, 40).send(Input::Tick);
    assert!(!o.iter().any(|x| matches!(x, Output::WriteDay(_))), "clean: nothing to write");
}

#[test]
fn only_presence_is_armed_while_away() {
    let mut h = H::new();
    let o = h.at(D, 10, 0, 0).send(Input::Start { boot_id: "b".into(), saved: None, lock_pid: None, day: None });
    assert!(!o.iter().any(|x| matches!(x, Output::ArmTick(true))), "no tick before the user is active");
    let o = h.send(Input::HyprUp { app: Some("a".into()), prog: None, mon: "m".into(), monitors: vec![] });
    assert!(o.iter().any(|x| matches!(x, Output::ArmTick(true))));
    let o = h.at(D, 10, 5, 0).send(Input::Idle(60));
    assert!(o.iter().any(|x| matches!(x, Output::ArmTick(false))), "the tick is disarmed on away");
}

#[test]
fn aliases_merge_classes_before_anything_is_recorded() {
    let mut cfg = Cfg::default();
    cfg.aliases.insert("code-oss".into(), "com.microsoft.VSCode".into());
    let mut h = H::with(cfg);
    h.at(D, 10, 0, 0).up("code-oss");
    h.at(D, 10, 1, 0).focus("com.microsoft.VSCode");
    h.at(D, 10, 2, 0).send(Input::Shutdown);
    assert_eq!(h.ivs(D), vec![(at(D, 10, 0, 0), at(D, 10, 2, 0), app("com.microsoft.VSCode"))]);
    assert_eq!(h.day(D).apps, vec!["com.microsoft.VSCode".to_string()]);
}

#[test]
fn an_ignored_class_is_the_desktops_time() {
    let v: Value = serde_json::from_str(r#"{"ignore": ["steam", 3]}"#).unwrap();
    let mut h = H::with(Cfg::from_value(&v));
    h.at(D, 10, 0, 0).up("kitty");
    h.at(D, 10, 1, 0).focus("steam");
    h.at(D, 10, 2, 0).focus("kitty");
    h.at(D, 10, 3, 0).send(Input::Shutdown);
    assert_eq!(
        h.ivs(D),
        vec![
            (at(D, 10, 0, 0), at(D, 10, 1, 0), app("kitty")),
            (at(D, 10, 1, 0), at(D, 10, 2, 0), app(DESKTOP)),
            (at(D, 10, 2, 0), at(D, 10, 3, 0), app("kitty"))
        ]
    );
    assert!(!h.day(D).apps.contains(&"steam".to_string()));
}

#[test]
fn the_digest_is_asked_once_per_week_at_the_first_activity() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).send(Input::Start { boot_id: "b".into(), saved: None, lock_pid: None, day: None });
    let o = h.send(Input::HyprUp { app: Some("a".into()), prog: None, mon: "m".into(), monitors: vec![] });
    let week: Vec<_> =
        o.iter().filter_map(|x| if let Output::Digest(d) = x { Some(d.to_string()) } else { None }).collect();
    assert_eq!(week, vec!["2026-09-28".to_string()], "the week containing 2026-10-03 starts on Monday 09-28");
    let o = h.at(D, 10, 30, 0).send(Input::Idle(60));
    assert!(!o.iter().any(|x| matches!(x, Output::Digest(_))));
    let o = h.at(D, 10, 40, 0).send(Input::Active);
    assert!(!o.iter().any(|x| matches!(x, Output::Digest(_))), "same week: asked once");
    let o = h.at("2026-10-05", 9, 0, 0).send(Input::Idle(0));
    assert!(o.iter().all(|x| !matches!(x, Output::Digest(_))));
    let o = h.at("2026-10-05", 9, 10, 0).send(Input::Active);
    assert!(
        o.iter().any(|x| matches!(x, Output::Digest(d) if d.to_string() == "2026-10-05")),
        "a new week at its first activity"
    );
    let cfg = Cfg { digest: false, ..Cfg::default() };
    let mut h = H::with(cfg);
    h.at(D, 10, 0, 0).send(Input::Start { boot_id: "b".into(), saved: None, lock_pid: None, day: None });
    let o = h.send(Input::HyprUp { app: Some("a".into()), prog: None, mon: "m".into(), monitors: vec![] });
    assert!(!o.iter().any(|x| matches!(x, Output::Digest(_))), "digest: false");
}

#[test]
fn a_state_push_comes_with_every_session_or_away_change_and_dropped_counts() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("kitty");
    let o = h.at(D, 10, 1, 0).send(Input::Idle(0));
    assert!(o.iter().any(|x| matches!(x, Output::PushState)));
    h.send(Input::Dropped(2));
    h.send(Input::Dropped(1));
    assert_eq!(h.snap().dropped, 3);
    let o = h.at(D, 10, 2, 0).focus_out();
    assert!(!o.iter().any(|x| matches!(x, Output::PushFocus)), "no focus push while away");
}

impl H {
    fn focus_out(&mut self) -> Vec<Output> {
        self.send(Input::Focus { app: Some("zen".into()), prog: None })
    }
}

#[test]
fn the_roll_is_always_rearmed_for_the_end_of_the_day_and_a_day_roll_input_rearms_it() {
    let mut h = H::new();
    let o = h.at(D, 10, 0, 0).send(Input::Start { boot_id: "b".into(), saved: None, lock_pid: None, day: None });
    let end = at("2026-10-04", 4, 0, 0);
    assert!(o.iter().any(|x| matches!(x, Output::ArmRoll(e) if *e == end)));
    let o = h.at(D, 10, 1, 0).send(Input::DayRoll);
    assert!(
        o.iter().any(|x| matches!(x, Output::ArmRoll(e) if *e == end)),
        "a cancelled timer (clock step) is re-armed"
    );
}

#[test]
fn shutdown_closes_the_interval_and_saves_the_session_for_the_next_start() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("kitty");
    let o = h.at(D, 10, 5, 0).send(Input::Shutdown);
    let saved = o.iter().find_map(|x| if let Output::WriteState(s) = x { Some((**s).clone()) } else { None }).unwrap();
    assert_eq!(saved.session, Some((at(D, 10, 0, 0), 300)));
    assert_eq!(saved.saved_at, at(D, 10, 5, 0));
    assert!(o.iter().any(|x| matches!(x, Output::WriteDay(_))));
}

#[test]
fn title_free_by_construction_core_inputs_carry_only_classes() {
    // Focus takes a class and a program name (a process's own short name); there is no field a title could travel in.
    let i = Input::Focus { app: Some("kitty".into()), prog: Some("claude".into()) };
    assert!(format!("{i:?}").contains("kitty"));
}

#[test]
fn cfg_is_lenient_about_bad_values() {
    let v: Value = serde_json::from_str(r#"{"dayStartHour": 30, "weekStart": 7, "sessionBreakMin": "x", "digest": false, "aliases": {"a": "b", "c": 1}, "//": "n"}"#).unwrap();
    let c = Cfg::from_value(&v);
    assert_eq!((c.day_start_hour, c.week_start, c.session_break_min, c.digest), (4, 7, 5, false));
    assert_eq!(c.aliases.len(), 1);
}

#[test]
fn sessions_derived_from_a_file_match_the_live_ones_after_a_rebuild() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("kitty");
    h.at(D, 10, 20, 0).send(Input::Lock(None));
    h.at(D, 10, 30, 0).send(Input::Unlock);
    h.at(D, 10, 40, 0).send(Input::Shutdown);
    let a = h.sum(D);
    let v = h.day(D).to_value(&a);
    let back = Day::from_value(&v).unwrap();
    assert_eq!(compute_sum(&back, h.c.calendar(), 4), a);
}

// ---- terminal programs (what kitty's time went to) -------------------

fn progs(h: &H, date: &str) -> Vec<(i64, i64, String, Option<String>)> {
    let d = h.day(date);
    d.iv.iter()
        .map(|v| {
            let p = (v.prog != crate::day::NO_PROG).then(|| d.progs[v.prog as usize].clone());
            (v.s, v.e, d.apps[v.app as usize].clone(), p)
        })
        .collect()
}

#[test]
fn a_program_change_splits_the_terminal_interval_but_not_the_stretch() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("zen");
    h.at(D, 10, 1, 0).send(Input::Focus { app: Some("kitty".into()), prog: Some("bash".into()) });
    h.at(D, 10, 2, 0).send(Input::Prog(Some("claude".into())));
    h.at(D, 10, 12, 0).send(Input::Prog(Some("bash".into())));
    h.at(D, 10, 12, 0).send(Input::Prog(Some("bash".into()))); // a retitle with the same program: nothing
    assert_eq!(h.snap().prog.as_deref(), Some("bash"));
    assert_eq!(h.snap().stretch_since, Some(at(D, 10, 1, 0)), "the run on kitty began at its focus");
    h.at(D, 10, 13, 0).focus("zen");
    assert_eq!(
        progs(&h, D),
        vec![
            (at(D, 10, 0, 0), at(D, 10, 1, 0), app("zen"), None),
            (at(D, 10, 1, 0), at(D, 10, 2, 0), app("kitty"), Some(app("bash"))),
            (at(D, 10, 2, 0), at(D, 10, 12, 0), app("kitty"), Some(app("claude"))),
            (at(D, 10, 12, 0), at(D, 10, 13, 0), app("kitty"), Some(app("bash"))),
        ]
    );
    let s = h.sum(D);
    assert_eq!(s.sub.get("kitty").and_then(|m| m.get("claude")), Some(&600));
    assert_eq!(s.sub.get("kitty").and_then(|m| m.get("bash")), Some(&120));
    assert!(!s.sub.contains_key("zen"), "an app with no program has none");
    assert_eq!(s.switches, 1, "zen -> kitty (the last zen is still open): the program changes are not switches");
    let l = s.longest.expect("a longest stretch");
    assert_eq!((l.app.as_str(), l.s), ("kitty", 720), "the stretch runs over the program changes");
}

#[test]
fn backdate_cuts_across_a_program_change() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("zen");
    h.at(D, 10, 0, 0).send(Input::Focus { app: Some("kitty".into()), prog: Some("claude".into()) });
    h.at(D, 10, 5, 0).send(Input::Prog(Some("bash".into())));
    h.at(D, 10, 6, 0).send(Input::Idle(120));
    // t* = 10:04: claude is cut there, the bash minute (after t*) is dropped.
    assert_eq!(progs(&h, D), vec![(at(D, 10, 0, 0), at(D, 10, 4, 0), app("kitty"), Some(app("claude")))]);
    // Back: the program read while away is the one the interval opens with.
    h.at(D, 10, 7, 0).send(Input::Prog(Some("nvim".into())));
    h.at(D, 10, 8, 0).send(Input::Active);
    h.at(D, 10, 9, 0).focus("zen");
    assert_eq!(progs(&h, D)[1], (at(D, 10, 8, 0), at(D, 10, 9, 0), app("kitty"), Some(app("nvim"))));
}

#[test]
fn a_day_with_programs_round_trips_and_one_without_keeps_its_bytes() {
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("zen");
    h.at(D, 10, 1, 0).send(Input::Focus { app: Some("kitty".into()), prog: Some("claude".into()) });
    h.at(D, 10, 2, 0).focus("zen");
    let d = h.day(D).clone();
    let v = d.to_value(&h.sum(D));
    assert_eq!(v["progs"], serde_json::json!(["claude"]));
    assert_eq!(Day::from_value(&v).unwrap(), d);
    let mut plain = H::new();
    plain.at(D, 10, 0, 0).up("zen");
    plain.at(D, 10, 1, 0).focus("kitty");
    let pv = plain.day(D).to_value(&plain.sum(D));
    assert!(pv.get("progs").is_none() && pv["sum"].get("sub").is_none(), "no program: no new keys");
    assert!(pv["iv"].as_array().unwrap().iter().all(|r| r.as_array().unwrap().len() == 4));
}

#[test]
fn a_stay_under_two_seconds_is_no_switch() {
    // The pointer crossing a window: A -> B (1 s) -> A is no switch; A -> B (1 s) -> C is one
    // (B passes through like the Desktop); B held 3 s is a real stay: two switches.
    let mut h = H::new();
    h.at(D, 10, 0, 0).up("kitty");
    h.at(D, 10, 5, 0).focus("zen");
    h.at(D, 10, 5, 1).focus("kitty");
    h.at(D, 10, 9, 0).focus("zen");
    h.at(D, 10, 9, 1).focus("code");
    h.at(D, 10, 12, 0).focus("zen");
    h.at(D, 10, 12, 3).focus("code");
    h.at(D, 10, 15, 0).focus("kitty");
    let s = h.sum(D);
    // kitty, (zen 1 s), kitty | (zen 1 s), code: 1 | zen 3 s: 2 | code (closed at 10:15): 3
    assert_eq!(s.switches, 3);
    assert_eq!(s.apps.get("zen"), Some(&5), "the passing stays' time still counts");
}
