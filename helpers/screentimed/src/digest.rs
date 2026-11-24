//! DUR (the duration text shared with the QML side) and the weekly digest body.

use std::collections::BTreeMap;

/// DUR: `<1m`, `{m}m`, `{h}h {m}m`; 0 is `0m`.
pub fn fmt_dur(s: i64) -> String {
    if s <= 0 {
        "0m".to_string()
    } else if s < 60 {
        "<1m".to_string()
    } else if s < 3600 {
        format!("{}m", s / 60)
    } else {
        format!("{}h {}m", s / 3600, (s % 3600) / 60)
    }
}

/// A class as the digest names it: the part after the last `.`, first letter capitalised.
pub fn pretty(class: &str) -> String {
    let tail = match class.rsplit_once('.') {
        Some((_, t)) if !t.is_empty() => t,
        _ => class,
    };
    let mut it = tail.chars();
    match it.next() {
        Some(c) => c.to_uppercase().collect::<String>() + it.as_str(),
        None => String::new(),
    }
}

/// One week's figures.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct WeekAgg {
    pub total: i64,
    pub apps: BTreeMap<String, i64>,
}

/// The digest body for last week (`last`) against the one before (`before`, None without data), or
/// None when last week has no data.
pub fn compose(last: &WeekAgg, before: Option<&WeekAgg>, names: &BTreeMap<String, String>) -> Option<String> {
    if last.total <= 0 {
        return None;
    }
    let mut body = fmt_dur(last.total);
    if let Some(b) = before.filter(|b| b.total > 0) {
        let diff = last.total - b.total;
        // Integer percent, to the nearest; the "same" band is within +-2 %.
        let pct = (diff.abs() * 100 + b.total / 2) / b.total;
        if diff.abs() * 100 <= 2 * b.total {
            body.push_str(", about the same as the week before");
        } else if diff < 0 {
            body.push_str(&format!(", {pct}% less than the week before"));
        } else {
            body.push_str(&format!(", {pct}% more than the week before"));
        }
    }
    body.push('.');
    let mut top: Vec<(&String, &i64)> =
        last.apps.iter().filter(|(a, s)| a.as_str() != crate::day::DESKTOP && **s > 0).collect();
    top.sort_by(|a, b| b.1.cmp(a.1).then(a.0.cmp(b.0)));
    top.truncate(3);
    if !top.is_empty() {
        let parts: Vec<String> = top
            .iter()
            .map(|(a, s)| format!("{} {}", names.get(*a).cloned().unwrap_or_else(|| pretty(a)), fmt_dur(**s)))
            .collect();
        body.push_str(&format!(" Top: {}.", parts.join(", ")));
    }
    Some(body)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn agg(total: i64, apps: &[(&str, i64)]) -> WeekAgg {
        WeekAgg { total, apps: apps.iter().map(|(a, s)| (a.to_string(), *s)).collect() }
    }

    #[test]
    fn dur_cases_from_the_shared_fixture() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/durations.json");
        let v: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let rows = v.as_array().unwrap();
        assert!(rows.len() >= 15);
        for r in rows {
            let (s, t) = (r[0].as_i64().unwrap(), r[1].as_str().unwrap());
            assert_eq!(fmt_dur(s), t, "DUR of {s} s");
        }
    }

    #[test]
    fn digest_text_case_from_the_contract() {
        let last =
            agg(112_800, &[("com.microsoft.VSCode", 39_720), ("zen", 34_800), ("kitty", 5000), ("~desktop", 40_000)]);
        let before = agg(128_182, &[]);
        let mut names = BTreeMap::new();
        names.insert("com.microsoft.VSCode".to_string(), "Code".to_string());
        let body = compose(&last, Some(&before), &names).unwrap();
        assert_eq!(body, "31h 20m, 12% less than the week before. Top: Code 11h 2m, Zen 9h 40m, Kitty 1h 23m.");
    }

    #[test]
    fn digest_more_and_about_the_same() {
        let names = BTreeMap::new();
        let more = compose(&agg(3600 * 12, &[]), Some(&agg(3600 * 10, &[])), &names).unwrap();
        assert_eq!(more, "12h 0m, 20% more than the week before.");
        let same = compose(&agg(100_000, &[]), Some(&agg(101_900, &[])), &names).unwrap();
        assert_eq!(same, "27h 46m, about the same as the week before.");
        // exactly +-2 % is still "the same", just past it is not
        assert!(compose(&agg(98_000, &[]), Some(&agg(100_000, &[])), &names).unwrap().contains("about the same"));
        assert!(compose(&agg(97_900, &[]), Some(&agg(100_000, &[])), &names).unwrap().contains("2% less"));
    }

    #[test]
    fn digest_without_a_previous_week_leaves_the_clause_out() {
        let names = BTreeMap::new();
        let body = compose(&agg(7200, &[("zen", 7200)]), None, &names).unwrap();
        assert_eq!(body, "2h 0m. Top: Zen 2h 0m.");
        let none_total = compose(&agg(7200, &[]), Some(&agg(0, &[])), &names).unwrap();
        assert_eq!(none_total, "2h 0m.");
    }

    #[test]
    fn digest_top_three_excludes_desktop_and_prettifies() {
        let names = BTreeMap::new();
        let last = agg(9000, &[("~desktop", 5000), ("org.mozilla.firefox", 2000), ("a", 1000), ("b", 900), ("c", 800)]);
        let body = compose(&last, None, &names).unwrap();
        assert_eq!(body, "2h 30m. Top: Firefox 33m, A 16m, B 15m.");
        assert_eq!(pretty("com.microsoft.VSCode"), "VSCode");
        assert_eq!(pretty("zen"), "Zen");
        assert_eq!(pretty("weird."), "Weird.");
    }

    #[test]
    fn no_digest_without_data() {
        assert_eq!(compose(&agg(0, &[]), None, &BTreeMap::new()), None);
    }
}
