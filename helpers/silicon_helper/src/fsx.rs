//! Small, bounded readers over sysfs/procfs plus the parsers every knob shares.
//! Nothing here writes.

use std::fs::{self, File};
use std::io::{self, Read};
use std::path::Path;

/// A sysfs attribute is at most one page; /proc/modules and state files get this larger cap.
const MAX_TEXT: u64 = 64 * 1024;

/// Read a small text file: bounded, lossy UTF-8, surrounding whitespace and NULs trimmed.
pub fn read_text(path: &Path) -> io::Result<String> {
    let mut buf = Vec::new();
    File::open(path)?.take(MAX_TEXT + 1).read_to_end(&mut buf)?;
    if u64::try_from(buf.len()).unwrap_or(u64::MAX) > MAX_TEXT {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "file is larger than 64 KiB"));
    }
    Ok(String::from_utf8_lossy(&buf).trim_matches(|c: char| c.is_whitespace() || c == '\0').to_string())
}

/// `read_text`, with every failure (missing, unreadable, too large) as `None`.
pub fn read_opt(path: &Path) -> Option<String> {
    read_text(path).ok()
}

/// Names in a directory, natural order (`policy2` before `policy10`); entries whose names
/// are not UTF-8 are skipped. A directory that cannot be read is an empty list.
pub fn list_dir(path: &Path) -> Vec<String> {
    let Ok(rd) = fs::read_dir(path) else { return Vec::new() };
    let mut names: Vec<String> = rd.filter_map(|e| e.ok()?.file_name().into_string().ok()).collect();
    names.sort_by_key(|n| natural_key(n));
    names
}

/// (text before the last run of digits, that number, text after): a stable natural order.
pub fn natural_key(name: &str) -> (String, u64, String) {
    let end = name.rfind(|c: char| c.is_ascii_digit()).map_or(0, |i| i + 1);
    if end == 0 {
        return (name.to_string(), 0, String::new());
    }
    let head = name.get(..end).unwrap_or("");
    let start = head.trim_end_matches(|c: char| c.is_ascii_digit()).len();
    let prefix = head.get(..start).unwrap_or("").to_string();
    let n = head.get(start..).unwrap_or("").parse::<u64>().unwrap_or(0);
    (prefix, n, name.get(end..).unwrap_or("").to_string())
}

/// `<prefix><digits>` with at least one digit and nothing else.
pub fn is_prefixed_number(name: &str, prefix: &str) -> bool {
    name.strip_prefix(prefix).is_some_and(|d| !d.is_empty() && d.bytes().all(|b| b.is_ascii_digit()))
}

/// Unsigned decimal digits only (no sign, no hex, no whitespace).
pub fn parse_u64(s: &str) -> Option<u64> {
    if s.is_empty() || s.len() > 19 || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}

/// A kernel list ("quiet balanced performance", "0;1"): whitespace- or `;`-separated words.
/// A word that is not plain `[A-Za-z0-9_.-]` (<= 40 chars) is dropped: nothing odd is ever
/// offered back as a value to write.
pub fn tokens(s: &str) -> Vec<String> {
    s.split(|c: char| c.is_whitespace() || c == ';')
        .filter(|w| {
            !w.is_empty()
                && w.len() <= 40
                && w.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
        })
        .map(str::to_string)
        .collect()
}

/// A non-negative decimal (`45`, `45.5`) as microwatts: at most `max_int` integer digits and `max_frac`
/// fractional ones, no sign, no exponent, no leading zero (but `0.5`), no trailing dot.
pub fn parse_decimal_uw(s: &str, max_int: usize, max_frac: usize) -> Option<u64> {
    let (int, frac) = match s.split_once('.') {
        Some((i, f)) => (i, Some(f)),
        None => (s, None),
    };
    let digits = |t: &str| !t.is_empty() && t.bytes().all(|b| b.is_ascii_digit());
    if !digits(int) || int.len() > max_int || (int.len() > 1 && int.starts_with('0')) {
        return None;
    }
    let mut uw = int.parse::<u64>().ok()?.checked_mul(1_000_000)?;
    if let Some(f) = frac {
        if !digits(f) || f.len() > max_frac.min(6) {
            return None;
        }
        let scale = 10u64.pow(u32::try_from(6 - f.len()).ok()?);
        uw = uw.checked_add(f.parse::<u64>().ok()?.checked_mul(scale)?)?;
    }
    Some(uw)
}

/// Elements of `a` that are also in `b`, in `a`'s order.
pub fn intersect(a: &[String], b: &[String]) -> Vec<String> {
    a.iter().filter(|x| b.contains(x)).cloned().collect()
}

/// Watts of a microwatt count as a JSON number text: `45`, `45.5`, `45.000001`.
pub fn watts_text(uw: u64) -> String {
    let whole = uw / 1_000_000;
    let frac = uw % 1_000_000;
    if frac == 0 {
        whole.to_string()
    } else {
        let f = format!("{frac:06}");
        format!("{whole}.{}", f.trim_end_matches('0'))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn natural_order() {
        let mut v = vec!["policy10", "policy2", "policy0", "policy1", "x"];
        v.sort_by_key(|n| natural_key(n));
        assert_eq!(v, ["policy0", "policy1", "policy2", "policy10", "x"]);
        let mut w = ["intel-rapl:0:1", "intel-rapl:0", "intel-rapl:0:0"];
        w.sort_by_key(|n| natural_key(n));
        assert_eq!(w.first().copied(), Some("intel-rapl:0"));
    }

    #[test]
    fn prefixed_numbers() {
        assert!(is_prefixed_number("policy12", "policy"));
        assert!(!is_prefixed_number("policy", "policy"));
        assert!(!is_prefixed_number("policy1a", "policy"));
        assert!(!is_prefixed_number("xpolicy1", "policy"));
        assert!(!is_prefixed_number("policy-1", "policy"));
    }

    #[test]
    fn unsigned_parsing_is_strict() {
        assert_eq!(parse_u64("45000000"), Some(45_000_000));
        for bad in ["", "-1", "+1", "0x10", " 1", "1 ", "1.0", "99999999999999999999"] {
            assert_eq!(parse_u64(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn token_lists_keep_the_kernels_order_and_drop_odd_words() {
        assert_eq!(tokens("quiet balanced performance"), ["quiet", "balanced", "performance"]);
        assert_eq!(tokens("0;1"), ["0", "1"]);
        assert_eq!(tokens("a ../b low-power c$d"), ["a", "low-power"]);
        assert!(tokens("").is_empty());
    }

    #[test]
    fn decimal_watts_are_exact_and_strict() {
        assert_eq!(parse_decimal_uw("45", 4, 3), Some(45_000_000));
        assert_eq!(parse_decimal_uw("45.5", 4, 3), Some(45_500_000));
        assert_eq!(parse_decimal_uw("0.125", 4, 3), Some(125_000));
        assert_eq!(parse_decimal_uw("0", 4, 3), Some(0));
        assert_eq!(parse_decimal_uw("45.000001", 6, 6), Some(45_000_001));
        for bad in
            ["", ".5", "5.", "05", "00", "-1", "+1", "4.5.5", "4,5", "1e3", "12345", "4.1234", " 4", "4 ", "0x10", "٤"]
        {
            assert_eq!(parse_decimal_uw(bad, 4, 3), None, "{bad:?}");
        }
        assert_eq!(watts_text(parse_decimal_uw("45.125", 4, 3).unwrap_or(0)), "45.125", "round trip");
    }

    #[test]
    fn watts_text_formats() {
        assert_eq!(watts_text(45_000_000), "45");
        assert_eq!(watts_text(45_500_000), "45.5");
        assert_eq!(watts_text(45_000_001), "45.000001");
        assert_eq!(watts_text(0), "0");
    }

    #[test]
    fn read_text_trims_and_bounds() {
        let dir = std::env::temp_dir().join(format!("sh-fsx-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let f = dir.join("a");
        fs::write(&f, "  powersave\n").unwrap();
        assert_eq!(read_text(&f).unwrap(), "powersave");
        fs::write(&f, vec![b'x'; 70_000]).unwrap();
        assert!(read_text(&f).is_err());
        fs::write(&f, b"ok\xff\xfe").unwrap();
        assert!(read_text(&f).unwrap().starts_with("ok"), "invalid UTF-8 is replaced, never a panic");
        assert!(read_text(&dir).is_err(), "a directory is not text");
        let _ = fs::remove_dir_all(&dir);
    }
}
