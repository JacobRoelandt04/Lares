//! Files: day files, `state.json`, the config. Every write is atomic (tmp + rename, mode 0600).

use crate::cal::Date;
use crate::core::{Cfg, LastSess, Saved};
use crate::day::{Day, Sum};
use crate::digest::WeekAgg;
use serde_json::{json, Value};
use std::fs;
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

/// Atomic file write: a sibling temp file, fsync, rename. Parents are created 0700.
pub fn atomic_write(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    }
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    let res = (|| {
        let mut f = fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_data()?;
        fs::rename(&tmp, path)
    })();
    if res.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    res
}

/// `//` and `/* */` comments blanked OUTSIDE strings (a path or a URL with `//` in it survives; every
/// byte keeps its place, so serde's line and column are the file's own). An unterminated `/*` and a
/// lone `/` are left for the parser to refuse. The same rule as the shell's JsonComments.strip.
pub fn strip_comments(src: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(src.len());
    let (mut i, mut in_str, mut esc) = (0, false, false);
    while i < src.len() {
        let c = src[i];
        if in_str {
            out.push(c);
            if esc {
                esc = false;
            } else if c == b'\\' {
                esc = true;
            } else if c == b'"' {
                in_str = false;
            }
            i += 1;
        } else if c == b'"' {
            in_str = true;
            out.push(c);
            i += 1;
        } else if c == b'/' && src.get(i + 1) == Some(&b'/') {
            while i < src.len() && src[i] != b'\n' {
                out.push(b' ');
                i += 1;
            }
        } else if c == b'/' && src.get(i + 1) == Some(&b'*') {
            match src[i + 2..].windows(2).position(|w| w == b"*/") {
                Some(at) => {
                    let end = i + 2 + at + 2;
                    out.extend(src[i..end].iter().map(|&b| if b == b'\n' { b'\n' } else { b' ' }));
                    i = end;
                }
                None => {
                    out.extend_from_slice(&src[i..]);
                    break;
                }
            }
        } else {
            out.push(c);
            i += 1;
        }
    }
    out
}

/// The file a config named `path` lives in (the shell's rule: ConfigFile, tools/lib/jsonc.py): `<name>.jsonc` when it exists,
/// else the `<name>.json` beside it, else -- only for a file in a folder named `config` -- the same two names one level up, where
/// every config lived before (2026-11-12); the first that exists, else the `.jsonc` (a name that is neither is taken as it is).
pub fn config_file(path: &Path) -> PathBuf {
    let s = path.to_string_lossy();
    let (jsonc, json) = if let Some(base) = s.strip_suffix(".jsonc") {
        (path.to_path_buf(), PathBuf::from(format!("{base}.json")))
    } else if s.ends_with(".json") {
        (PathBuf::from(format!("{s}c")), path.to_path_buf())
    } else {
        return path.to_path_buf();
    };
    let mut cands = vec![jsonc.clone(), json];
    if let (Some(dir), Some(name)) = (jsonc.parent(), jsonc.file_name()) {
        if dir.file_name().map(|n| n == "config").unwrap_or(false) {
            if let Some(up) = dir.parent() {
                let n = name.to_string_lossy().to_string();
                cands.push(up.join(&n));
                cands.push(up.join(&n[..n.len() - 1]));
            }
        }
    }
    cands.into_iter().find(|c| c.exists()).unwrap_or(jsonc)
}

/// The config file (`config/screentime.jsonc`, else its older places; comments allowed), or the defaults when
/// it is missing or not JSON (said once on stderr).
pub fn load_config(path: &Path) -> Cfg {
    let file = config_file(path);
    match fs::read(&file) {
        Ok(b) => match serde_json::from_slice::<Value>(&strip_comments(&b)) {
            Ok(v) => Cfg::from_value(&v),
            Err(e) => {
                eprintln!("screentimed: {}: {e}; using defaults", file.display());
                Cfg::default()
            }
        },
        Err(_) => Cfg::default(),
    }
}

pub struct Store {
    root: PathBuf,
}

impl Store {
    pub fn new(root: &Path) -> Store {
        Store { root: root.to_path_buf() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn day_path(&self, date: Date) -> PathBuf {
        self.root.join("days").join(format!("{:04}", date.y)).join(format!("{date}.json"))
    }

    pub fn state_path(&self) -> PathBuf {
        self.root.join("state.json")
    }

    pub fn day_exists(&self, date: Date) -> bool {
        self.day_path(date).is_file()
    }

    /// The day file's JSON; None when missing or unreadable.
    pub fn read_day_value(&self, date: Date) -> Option<Value> {
        let b = fs::read(self.day_path(date)).ok()?;
        serde_json::from_slice(&b).ok()
    }

    pub fn read_day(&self, date: Date) -> Option<Day> {
        Day::from_value(&self.read_day_value(date)?).ok()
    }

    /// For the daemon's start: today's file, a corrupt one set aside (never overwritten blind).
    pub fn read_day_for_start(&self, date: Date) -> Option<Day> {
        if !self.day_exists(date) {
            return None;
        }
        let day = self.read_day(date);
        if day.is_none() {
            let p = self.day_path(date);
            let _ = fs::rename(&p, p.with_extension("json.corrupt"));
            eprintln!("screentimed: {} is not a day file; moved aside", p.display());
        }
        day
    }

    pub fn write_day(&self, day: &Day, sum: &Sum) -> std::io::Result<()> {
        let mut s = serde_json::to_string(&day.to_value(sum)).unwrap_or_default();
        s.push('\n');
        atomic_write(&self.day_path(day.date), s.as_bytes())
    }

    pub fn write_state(&self, s: &Saved) -> std::io::Result<()> {
        let ls = s
            .last_session
            .as_ref()
            .map(|l| json!({"start": l.start, "end": l.end, "active": l.active_s, "why": l.why}));
        let v = json!({
            "v": 1,
            "bootId": s.boot_id,
            "savedAt": s.saved_at,
            "session": s.session.map(|(st, a)| json!({"start": st, "active": a})),
            "lastSession": ls,
            "awaySince": s.away_since,
            "digestWeek": s.digest_week.map(|d| d.to_string()),
            "lockPid": s.lock_pid,
        });
        let mut t = serde_json::to_string(&v).unwrap_or_default();
        t.push('\n');
        atomic_write(&self.state_path(), t.as_bytes())
    }

    pub fn read_state(&self) -> Option<Saved> {
        let v: Value = serde_json::from_slice(&fs::read(self.state_path()).ok()?).ok()?;
        let o = v.as_object()?;
        let last_session = o.get("lastSession").and_then(|l| {
            Some(LastSess {
                start: l.get("start")?.as_i64()?,
                end: l.get("end")?.as_i64()?,
                active_s: l.get("active")?.as_i64()?,
                why: l.get("why")?.as_str()?.to_string(),
            })
        });
        let session = o.get("session").and_then(|s| Some((s.get("start")?.as_i64()?, s.get("active")?.as_i64()?)));
        Some(Saved {
            boot_id: o.get("bootId")?.as_str()?.to_string(),
            saved_at: o.get("savedAt")?.as_i64()?,
            session,
            last_session,
            away_since: o.get("awaySince").and_then(Value::as_i64),
            digest_week: o.get("digestWeek").and_then(Value::as_str).and_then(Date::parse),
            lock_pid: o.get("lockPid").and_then(Value::as_i64).map(|p| p as i32),
        })
    }

    /// Every day file's date, ascending.
    pub fn list_days(&self) -> Vec<Date> {
        let mut out = Vec::new();
        let Ok(years) = fs::read_dir(self.root.join("days")) else { return out };
        for y in years.flatten() {
            let Ok(files) = fs::read_dir(y.path()) else { continue };
            for f in files.flatten() {
                let name = f.file_name().to_string_lossy().to_string();
                if let Some(d) = name.strip_suffix(".json").and_then(Date::parse) {
                    out.push(d);
                }
            }
        }
        out.sort();
        out
    }

    /// One week's totals from its day files; None when no day has data.
    pub fn week_agg(&self, from: Date) -> Option<WeekAgg> {
        let mut agg = WeekAgg::default();
        let mut any = false;
        for i in 0..7 {
            let Some(v) = self.read_day_value(from.add_days(i)) else { continue };
            let Some(sum) = v.get("sum") else { continue };
            let total = sum.get("total").and_then(Value::as_i64).unwrap_or(0);
            if total <= 0 {
                continue;
            }
            any = true;
            agg.total += total;
            if let Some(apps) = sum.get("apps").and_then(Value::as_object) {
                for (k, s) in apps {
                    *agg.apps.entry(k.clone()).or_insert(0) += s.as_i64().unwrap_or(0);
                }
            }
        }
        any.then_some(agg)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cal::TableCal;
    use crate::day::{compute_sum, Iv};

    fn tmp(name: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("st-unit-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&p);
        p
    }

    #[test]
    fn config_reads_the_config_folder_first_and_the_old_places_after_it() {
        let root = std::env::temp_dir().join(format!("screentimed-cfgdir-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("config")).unwrap();
        let named = root.join("config/screentime.jsonc");
        // none: where a first write goes, in config/
        assert_eq!(config_file(&named), named);
        // only the old place: read there
        fs::write(root.join("screentime.jsonc"), "{}").unwrap();
        assert_eq!(config_file(&named), root.join("screentime.jsonc"));
        fs::remove_file(root.join("screentime.jsonc")).unwrap();
        fs::write(root.join("screentime.json"), "{}").unwrap();
        assert_eq!(config_file(&named), root.join("screentime.json"));
        // config/ wins over the old places
        fs::write(&named, "{}").unwrap();
        assert_eq!(config_file(&named), named);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn config_reads_the_jsonc_first_with_comments_and_the_json_after_it() {
        let root = tmp("cfg");
        fs::create_dir_all(&root).unwrap();
        let jsonc = root.join("screentime.jsonc");
        let json = root.join("screentime.json");
        // neither: the defaults, and the .jsonc is where a first write would go
        assert_eq!(config_file(&json), jsonc);
        assert_eq!(load_config(&json).day_start_hour, Cfg::default().day_start_hour);
        // only the .json (the older name, comments in it are read too)
        fs::write(&json, b"{ \"dayStartHour\": 5 } // the old name").unwrap();
        assert_eq!(config_file(&jsonc), json);
        assert_eq!(load_config(&jsonc).day_start_hour, 5);
        // both: the .jsonc wins, whichever name is asked for; a URL's `//` and a block comment are no comment
        fs::write(&jsonc, b"/* the new one */ { \"dayStartHour\": 3, // \"dayStartHour\": 9\n \"x\": \"http://a//b\" }").unwrap();
        assert_eq!(config_file(&json), jsonc);
        assert_eq!(load_config(&json).day_start_hour, 3);
        // an unterminated block comment is not silently a smaller file: the defaults, said on stderr
        fs::write(&jsonc, b"{ \"dayStartHour\": 3 } /* open").unwrap();
        assert_eq!(load_config(&jsonc).day_start_hour, Cfg::default().day_start_hour);
        assert_eq!(strip_comments(b"a // b\nc /* d\n */ e").len(), 19);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn day_and_state_round_trip_with_private_modes() {
        let root = tmp("store");
        let st = Store::new(&root);
        let cal = TableCal::brussels();
        let date = Date { y: 2026, m: 10, d: 3 };
        let (s, e) = crate::cal::day_bounds(&cal, date, 4);
        let mut d = Day::new(date, s, e);
        let a = d.app_idx("kitty");
        let m = d.mon_idx("eDP-1");
        d.iv.push(Iv { s: s + 1000, e: s + 5000, app: a, mon: m, prog: crate::day::NO_PROG });
        st.write_day(&d, &compute_sum(&d, &cal, 4)).unwrap();
        assert_eq!(st.read_day(date).unwrap(), d);
        let mode = fs::metadata(st.day_path(date)).unwrap().permissions();
        assert_eq!(std::os::unix::fs::PermissionsExt::mode(&mode) & 0o777, 0o600);
        assert_eq!(st.list_days(), vec![date]);
        let saved = Saved {
            boot_id: "b".into(),
            saved_at: 5,
            session: Some((1, 2)),
            last_session: Some(LastSess { start: 1, end: 2, active_s: 3, why: "lock".into() }),
            away_since: None,
            digest_week: Some(date),
            lock_pid: Some(7),
        };
        st.write_state(&saved).unwrap();
        assert_eq!(st.read_state().unwrap(), saved);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn corrupt_start_file_is_set_aside() {
        let root = tmp("corrupt");
        let st = Store::new(&root);
        let date = Date { y: 2026, m: 10, d: 3 };
        atomic_write(&st.day_path(date), b"{not json").unwrap();
        assert!(st.read_day_for_start(date).is_none());
        assert!(!st.day_exists(date));
        assert!(st.day_path(date).with_extension("json.corrupt").exists());
        let _ = fs::remove_dir_all(&root);
    }
}
