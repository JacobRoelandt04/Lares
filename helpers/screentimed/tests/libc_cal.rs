//! The libc calendar with a real zone. Its own test binary: it sets `TZ` for the whole process.

use screentimed::cal::{day_bounds, Calendar, Date, LibcCal, TableCal};

#[test]
fn libc_calendar_matches_the_table_in_europe_brussels() {
    std::env::set_var("TZ", "Europe/Brussels");
    let libc_cal = LibcCal::new();
    let table = TableCal::brussels();
    // Every hour of both DST weekends and an ordinary day: the same local reading from both.
    let from = Date { y: 2026, m: 10, d: 23 }.days() * 86_400_000;
    for h in 0..(5 * 24) {
        let t = from + h * 3_600_000 + 17_000;
        assert_eq!(libc_cal.local(t), table.local(t), "t = {t}");
    }
    let from = Date { y: 2027, m: 3, d: 26 }.days() * 86_400_000;
    for h in 0..(5 * 24) {
        let t = from + h * 3_600_000;
        assert_eq!(libc_cal.local(t), table.local(t), "t = {t}");
    }
    for (y, m, d, hours) in [(2026, 10, 24, 25), (2027, 3, 27, 23), (2026, 10, 3, 24)] {
        let (s, e) = day_bounds(&libc_cal, Date { y, m, d }, 4);
        assert_eq!(e - s, hours * 3_600_000, "{y}-{m}-{d}");
        assert_eq!(day_bounds(&table, Date { y, m, d }, 4), (s, e));
    }
    // the awkward ones go the same way as the table's
    let gap = libc_cal.resolve_local(Date { y: 2027, m: 3, d: 28 }, 2, 30, 0);
    assert_eq!(gap, table.resolve_local(Date { y: 2027, m: 3, d: 28 }, 2, 30, 0));
    assert_eq!(libc_cal.local(gap).hour, 3);
    let rep = libc_cal.resolve_local(Date { y: 2026, m: 10, d: 25 }, 2, 30, 0);
    assert_eq!(libc_cal.local(rep).off_s, 7200, "first occurrence");
}
