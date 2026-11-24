//! Local-time conversions behind a trait, so every DST case is deterministic in a test.
//!
//! `LibcCal` asks the C library (`localtime_r`, so `TZ` and the system zone apply); `TableCal` is a
//! fixed table of UTC offsets and `FixedCal` one offset. The conversion back from a local civil time is
//! written ONCE, on top of `local()` alone, so all implementations agree on the two awkward cases:
//! a local time the spring-forward gap skips moves FORWARD (02:30 -> 03:30), and a repeated local time
//! (fall back) takes its FIRST occurrence.

use std::fmt;

/// A civil date. Ordering is chronological.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Date {
    pub y: i32,
    pub m: u32,
    pub d: u32,
}

/// Days since 1970-01-01 of a civil date (Howard Hinnant's algorithm).
pub fn days_from_civil(y: i32, m: u32, d: u32) -> i64 {
    let y = i64::from(y) - i64::from(m <= 2);
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = (i64::from(m) + 9) % 12;
    let doy = (153 * mp + 2) / 5 + i64::from(d) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// The civil date of a day count since 1970-01-01.
pub fn civil_from_days(z: i64) -> (i32, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    ((y + i64::from(m <= 2)) as i32, m, d)
}

impl Date {
    pub fn days(self) -> i64 {
        days_from_civil(self.y, self.m, self.d)
    }

    pub fn from_days(n: i64) -> Date {
        let (y, m, d) = civil_from_days(n);
        Date { y, m, d }
    }

    pub fn add_days(self, n: i64) -> Date {
        Date::from_days(self.days() + n)
    }

    /// 1 = Monday ... 7 = Sunday.
    pub fn weekday(self) -> u32 {
        // 1970-01-01 was a Thursday (4).
        ((self.days() + 3).rem_euclid(7) + 1) as u32
    }

    /// Strict `YYYY-MM-DD` of a real calendar date.
    pub fn parse(s: &str) -> Option<Date> {
        let b = s.as_bytes();
        if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
            return None;
        }
        let digits = |r: std::ops::Range<usize>| -> Option<u32> {
            let t = &s[r];
            if t.bytes().all(|c| c.is_ascii_digit()) {
                t.parse().ok()
            } else {
                None
            }
        };
        let (y, m, d) = (digits(0..4)? as i32, digits(5..7)?, digits(8..10)?);
        if !(1..=12).contains(&m) || d == 0 {
            return None;
        }
        let date = Date { y, m, d };
        (Date::from_days(date.days()) == date).then_some(date)
    }
}

impl fmt::Display for Date {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:04}-{:02}-{:02}", self.y, self.m, self.d)
    }
}

/// A local wall-clock reading.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Local {
    pub date: Date,
    pub hour: u32,
    pub min: u32,
    pub sec: u32,
    /// Seconds east of UTC at that instant.
    pub off_s: i32,
}

pub trait Calendar {
    /// The local reading of an instant (epoch milliseconds).
    fn local(&self, ms: i64) -> Local;

    /// The instant of a local civil time. A time the DST gap skips moves forward, a repeated one takes
    /// its first occurrence.
    fn resolve_local(&self, date: Date, hour: u32, min: u32, sec: u32) -> i64 {
        let naive = (date.days() * 86_400 + i64::from(hour) * 3600 + i64::from(min) * 60 + i64::from(sec)) * 1000;
        let before = self.local(naive - 86_400_000).off_s;
        let after = self.local(naive + 86_400_000).off_s;
        let mut best: Option<i64> = None;
        for off in [before, after] {
            let t = naive - i64::from(off) * 1000;
            let l = self.local(t);
            if l.date == date && l.hour == hour && l.min == min && l.sec == sec {
                best = Some(best.map_or(t, |b| b.min(t)));
            }
        }
        best.unwrap_or(naive - i64::from(before) * 1000)
    }
}

fn local_of(ms: i64, off_s: i32) -> Local {
    let secs = ms.div_euclid(1000) + i64::from(off_s);
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    Local {
        date: Date::from_days(days),
        hour: (rem / 3600) as u32,
        min: (rem % 3600 / 60) as u32,
        sec: (rem % 60) as u32,
        off_s,
    }
}

/// The C library's local time (`TZ`, `/etc/localtime`).
pub struct LibcCal;

impl LibcCal {
    pub fn new() -> LibcCal {
        extern "C" {
            fn tzset();
        }
        // SAFETY: tzset only reads the environment.
        unsafe { tzset() };
        LibcCal
    }
}

impl Default for LibcCal {
    fn default() -> Self {
        Self::new()
    }
}

impl Calendar for LibcCal {
    fn local(&self, ms: i64) -> Local {
        let t: libc::time_t = ms.div_euclid(1000) as libc::time_t;
        // SAFETY: tm is plain data, localtime_r fills it and keeps no pointer.
        let tm = unsafe {
            let mut tm: libc::tm = std::mem::zeroed();
            if libc::localtime_r(&t, &mut tm).is_null() {
                return local_of(ms, 0);
            }
            tm
        };
        Local {
            date: Date { y: tm.tm_year + 1900, m: (tm.tm_mon + 1) as u32, d: tm.tm_mday as u32 },
            hour: tm.tm_hour as u32,
            min: tm.tm_min as u32,
            sec: tm.tm_sec as u32,
            off_s: tm.tm_gmtoff as i32,
        }
    }
}

/// One fixed UTC offset (seconds east).
pub struct FixedCal(pub i32);

impl Calendar for FixedCal {
    fn local(&self, ms: i64) -> Local {
        local_of(ms, self.0)
    }
}

/// A table of UTC offsets: `(from_utc_ms, off_s)` sorted by time, `base` before the first.
pub struct TableCal {
    base: i32,
    transitions: Vec<(i64, i32)>,
}

impl TableCal {
    pub fn new(base: i32, transitions: Vec<(i64, i32)>) -> TableCal {
        TableCal { base, transitions }
    }

    /// Europe/Brussels 2025-2028: CET = +1 h, CEST = +2 h, switching at 01:00 UTC on the last Sundays of
    /// March and October (2026-10-25 is 25 h long, 2027-03-28 is 23 h).
    pub fn brussels() -> TableCal {
        let at = |y, m, d| days_from_civil(y, m, d) * 86_400_000 + 3_600_000;
        TableCal::new(
            3600,
            vec![
                (at(2025, 3, 30), 7200),
                (at(2025, 10, 26), 3600),
                (at(2026, 3, 29), 7200),
                (at(2026, 10, 25), 3600),
                (at(2027, 3, 28), 7200),
                (at(2027, 10, 31), 3600),
                (at(2028, 3, 26), 7200),
                (at(2028, 10, 29), 3600),
            ],
        )
    }
}

impl Calendar for TableCal {
    fn local(&self, ms: i64) -> Local {
        let off = self.transitions.iter().rev().find(|(t, _)| *t <= ms).map_or(self.base, |(_, o)| *o);
        local_of(ms, off)
    }
}

/// The logical day (starts at `dsh` local) an instant belongs to.
pub fn logical_date(cal: &dyn Calendar, ms: i64, dsh: u32) -> Date {
    let l = cal.local(ms);
    let mut date = if l.hour < dsh { l.date.add_days(-1) } else { l.date };
    // A DST step at the day start can leave the first guess one day off; the bounds are the truth.
    let (s, e) = day_bounds(cal, date, dsh);
    if ms < s {
        date = date.add_days(-1);
    } else if ms >= e {
        date = date.add_days(1);
    }
    date
}

/// `[start, end)` of a logical day in epoch ms.
pub fn day_bounds(cal: &dyn Calendar, date: Date, dsh: u32) -> (i64, i64) {
    (cal.resolve_local(date, dsh, 0, 0), cal.resolve_local(date.add_days(1), dsh, 0, 0))
}

/// The start date of the week (configured `week_start`, 1 = Monday) containing `date`.
pub fn week_start_of(date: Date, week_start: u32) -> Date {
    let back = (date.weekday() + 7 - week_start) % 7;
    date.add_days(-i64::from(back))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(y: i32, m: u32, dd: u32) -> Date {
        Date { y, m, d: dd }
    }

    #[test]
    fn civil_roundtrip_and_weekday() {
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(d(2026, 10, 4).weekday(), 7, "2026-10-04 is a Sunday");
        assert_eq!(d(2026, 9, 28).weekday(), 1, "2026-09-28 is a Monday");
        for n in [-1000i64, 0, 365, 20_000, 20_730] {
            assert_eq!(Date::from_days(n).days(), n);
        }
        assert_eq!(d(2028, 2, 29).add_days(1), d(2028, 3, 1));
    }

    #[test]
    fn date_parse_is_strict() {
        assert_eq!(Date::parse("2026-10-03"), Some(d(2026, 10, 3)));
        for bad in ["2026-13-01", "2026-02-30", "2026-1-03", "26-10-03", "2026/10/03", "", "2026-10-0a", "2026-10-03 "]
        {
            assert_eq!(Date::parse(bad), None, "{bad}");
        }
        assert_eq!(d(2026, 10, 3).to_string(), "2026-10-03");
    }

    #[test]
    fn brussels_dst_days_are_25_and_23_hours() {
        // The logical day starts at 04:00, AFTER the 02:00/03:00 switch of the transition date, so the
        // long day is the one that started the day before: 2026-10-24 (04:00 CEST -> 04:00 CET on the
        // 25th) is 25 h, and 2027-03-27 (-> 04:00 CEST on the 28th) is 23 h.
        let cal = TableCal::brussels();
        let (s, e) = day_bounds(&cal, d(2026, 10, 24), 4);
        assert_eq!(e - s, 25 * 3_600_000, "fall back: the logical day of 2026-10-24 is 25 h");
        let (s, e) = day_bounds(&cal, d(2027, 3, 27), 4);
        assert_eq!(e - s, 23 * 3_600_000, "spring forward: the logical day of 2027-03-27 is 23 h");
        for (y, m, dd) in [(2026, 10, 25), (2027, 3, 28), (2026, 10, 3)] {
            let (s, e) = day_bounds(&cal, d(y, m, dd), 4);
            assert_eq!(e - s, 24 * 3_600_000);
        }
    }

    #[test]
    fn gap_moves_forward_and_repeat_takes_the_first() {
        let cal = TableCal::brussels();
        let t = cal.resolve_local(d(2027, 3, 28), 2, 30, 0);
        let l = cal.local(t);
        assert_eq!((l.hour, l.min), (3, 30), "02:30 does not exist on 2027-03-28 and moves forward");
        let t = cal.resolve_local(d(2026, 10, 25), 2, 30, 0);
        assert_eq!(cal.local(t).off_s, 7200, "the repeated 02:30 is the CEST one");
    }

    #[test]
    fn logical_date_follows_the_day_start() {
        let cal = TableCal::brussels();
        let t = cal.resolve_local(d(2026, 10, 3), 3, 59, 59);
        assert_eq!(logical_date(&cal, t, 4), d(2026, 10, 2));
        let t = cal.resolve_local(d(2026, 10, 3), 4, 0, 0);
        assert_eq!(logical_date(&cal, t, 4), d(2026, 10, 3));
    }

    #[test]
    fn week_start_respects_the_configured_day() {
        assert_eq!(week_start_of(d(2026, 10, 4), 1), d(2026, 9, 28));
        assert_eq!(week_start_of(d(2026, 9, 28), 1), d(2026, 9, 28));
        assert_eq!(week_start_of(d(2026, 10, 4), 7), d(2026, 10, 4));
        assert_eq!(week_start_of(d(2026, 10, 3), 7), d(2026, 9, 27));
    }

    #[test]
    fn fixed_cal_offsets() {
        let cal = FixedCal(3600);
        let l = cal.local(0);
        assert_eq!((l.date, l.hour), (d(1970, 1, 1), 1));
    }
}
