//! `apply`, `set-boot`, `set-charge-limit` and `boot-apply` share one engine: a request is
//! VALIDATED into a plan (every value against the kernel's own lists and the ranges, every
//! target path against the whitelist), and only a plan with no refusal is executed, knob by
//! knob in a fixed order, each write read back. Nothing here writes before validation ends.

use std::path::{Path, PathBuf};

use crate::fsx::{parse_decimal_uw, parse_u64, read_opt, watts_text};
use crate::json::Json;
use crate::knobs::Knob;
use crate::machine::{Machine, CAP_FLOOR_UW};
use crate::whitelist::Class;
use crate::writer::{WriteError, Writer};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Code {
    Ok,
    /// Validation said no; this call wrote nothing.
    Refused,
    /// The knob does not exist here.
    Absent,
    /// EPP under the performance governor.
    Locked,
    /// The write itself failed.
    Io,
    /// Written, but the read-back differs.
    Mismatch,
}

impl Code {
    pub fn as_str(self) -> &'static str {
        match self {
            Code::Ok => "ok",
            Code::Refused => "refused",
            Code::Absent => "absent",
            Code::Locked => "locked",
            Code::Io => "io",
            Code::Mismatch => "mismatch",
        }
    }
}

/// One element of a write's `results`.
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub knob: Knob,
    pub want: Json,
    pub got: Json,
    pub code: Code,
    pub why: String,
}

impl Entry {
    pub fn ok(&self) -> bool {
        self.code == Code::Ok
    }

    pub fn failed(knob: Knob, want: Json, code: Code, why: impl Into<String>) -> Entry {
        Entry { knob, want, got: Json::Null, code, why: why.into() }
    }

    pub fn success(knob: Knob, want: Json, got: Json) -> Entry {
        Entry { knob, want, got, code: Code::Ok, why: String::new() }
    }

    pub fn to_json(&self) -> Json {
        Json::obj([
            ("knob", Json::str(self.knob.name())),
            ("want", self.want.clone()),
            ("got", self.got.clone()),
            ("ok", Json::Bool(self.ok())),
            ("code", Json::str(self.code.as_str())),
            ("why", Json::str(self.why.as_str())),
        ])
    }
}

/// One file to write, already resolved and checked.
#[derive(Clone, Debug)]
pub struct Target {
    pub label: String,
    pub path: PathBuf,
    pub class: Class,
    pub value: String,
}

#[derive(Clone, Copy, Debug)]
pub enum GotKind {
    /// Text; the word for "the files disagree".
    Text(&'static str),
    /// `no_turbo` text as a boolean (turbo on).
    Turbo,
    Int,
    Watts,
}

#[derive(Clone, Debug)]
pub struct Step {
    pub knob: Knob,
    pub want: Json,
    pub targets: Vec<Target>,
    pub got: GotKind,
}

// ---------------------------------------------------------------- the request

/// The arguments of `apply` (and of a stored boot set): any subset of the seven knobs, each
/// at most once. Values are kept as typed; they are judged knob by knob.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Request {
    pub items: Vec<(Knob, String)>,
}

impl Request {
    /// `key=value` words. A word that is not `key=value`, an unknown key or a repeated key
    /// is a usage error (nothing to attach a result to).
    pub fn parse(words: &[String]) -> Result<Request, String> {
        let mut items: Vec<(Knob, String)> = Vec::new();
        for w in words {
            let (key, value) = w.split_once('=').ok_or_else(|| format!("'{w}' is not key=value"))?;
            let knob = Knob::from_arg(key).ok_or_else(|| format!("unknown argument '{key}'"))?;
            if items.iter().any(|(k, _)| *k == knob) {
                return Err(format!("'{key}' given twice"));
            }
            items.push((knob, value.to_string()));
        }
        items.sort_by_key(|(k, _)| *k);
        Ok(Request { items })
    }

    pub fn get(&self, knob: Knob) -> Option<&str> {
        self.items.iter().find(|(k, _)| *k == knob).map(|(_, v)| v.as_str())
    }

    /// The words, as `Request::parse` takes them.
    pub fn words(&self) -> Vec<(String, String)> {
        self.items.iter().filter_map(|(k, v)| Some((k.arg()?.to_string(), v.clone()))).collect()
    }
}

/// The `want` of a result for a value typed as `raw`, typed as the knob's own value is.
fn want_of(knob: Knob, raw: &str) -> Json {
    let number = (!raw.is_empty() && raw.len() <= 9).then(|| parse_u64(raw)).flatten();
    match (knob, number) {
        (Knob::Turbo, _) if raw == "0" || raw == "1" => Json::Bool(raw == "1"),
        (Knob::MaxPerf | Knob::ChargeLimit, Some(n)) => Json::Int(i64::try_from(n).unwrap_or(0)),
        (Knob::Pl1 | Knob::Pl2, _) => {
            parse_decimal_uw(raw, 4, 3).map_or_else(|| Json::str(raw), |uw| Json::Num(watts_text(uw)))
        }
        _ => Json::str(raw),
    }
}

// ---------------------------------------------------------------- validation

fn refuse(knob: Knob, raw: &str, why: impl Into<String>) -> Entry {
    Entry::failed(knob, want_of(knob, raw), Code::Refused, why)
}

fn absent(knob: Knob, raw: &str, why: impl Into<String>) -> Entry {
    Entry::failed(knob, want_of(knob, raw), Code::Absent, why)
}

fn vet_all(
    w: &Writer,
    knob: Knob,
    raw: &str,
    class: Class,
    files: &[(PathBuf, String)],
    value: &str,
    label: &dyn Fn(&Path) -> String,
) -> Result<Vec<Target>, Entry> {
    files
        .iter()
        .map(|(path, _)| {
            let canon = w.vet(class, path).map_err(|e| match e {
                WriteError::Refused(why) => refuse(knob, raw, why),
                WriteError::Io(e) => refuse(knob, raw, format!("{}: {e}", path.display())),
            })?;
            Ok(Target { label: label(path), path: canon, class, value: value.to_string() })
        })
        .collect()
}

/// `policy7` from `.../cpufreq/policy7/scaling_governor`.
fn policy_label(path: &Path) -> String {
    path.parent().and_then(|p| p.file_name()).and_then(|n| n.to_str()).unwrap_or("policy").to_string()
}

fn handler_label(path: &Path) -> String {
    path.parent()
        .and_then(|p| p.file_name())
        .and_then(|n| n.to_str())
        .map_or_else(|| "platform_profile".to_string(), str::to_string)
}

fn one_label(name: &'static str) -> impl Fn(&Path) -> String {
    move |_| name.to_string()
}

fn choose(choices: &[String], knob: Knob, raw: &str, what: &str) -> Result<(), Entry> {
    if choices.iter().any(|c| c == raw) {
        Ok(())
    } else {
        Err(refuse(knob, raw, format!("'{raw}' is not {what} the kernel offers ({})", choices.join(", "))))
    }
}

/// Plain decimal digits, no sign, no leading zero, at most `max_len` of them.
fn plain_uint(raw: &str, max_len: usize) -> Option<u64> {
    if raw.len() > max_len || (raw.len() > 1 && raw.starts_with('0')) {
        return None;
    }
    parse_u64(raw)
}

fn plan_profile(m: &Machine, w: &Writer, raw: &str) -> Result<Step, Entry> {
    let k = Knob::Profile;
    let Some(p) = &m.profile else { return Err(absent(k, raw, "this machine has no platform profile control")) };
    if raw == "custom" {
        return Err(refuse(k, raw, "custom is the kernel's word for a mix of profiles, not one to choose"));
    }
    choose(&p.choices, k, raw, "a profile")?;
    let targets = vet_all(w, k, raw, Class::Profile, &p.files, raw, &handler_label)?;
    Ok(Step { knob: k, want: Json::str(raw), targets, got: GotKind::Text("custom") })
}

fn plan_governor(m: &Machine, w: &Writer, raw: &str) -> Result<Step, Entry> {
    let k = Knob::Governor;
    let Some(g) = &m.governor else { return Err(absent(k, raw, "this machine has no cpufreq governor control")) };
    choose(&g.choices, k, raw, "a governor")?;
    let targets = vet_all(w, k, raw, Class::Governor, &g.files, raw, &policy_label)?;
    Ok(Step { knob: k, want: Json::str(raw), targets, got: GotKind::Text("mixed") })
}

fn plan_epp(m: &Machine, w: &Writer, req: &Request, raw: &str) -> Result<Step, Entry> {
    let k = Knob::Epp;
    let Some(e) = &m.epp else { return Err(absent(k, raw, "this CPU driver has no energy performance preference")) };
    if raw == "default" {
        return Err(refuse(k, raw, "default is an alias of another step, not a step of its own"));
    }
    choose(&e.choices, k, raw, "a preference")?;
    let performance_after = req.get(Knob::Governor).map_or_else(|| m.epp_locked(), |g| g == "performance");
    if performance_after {
        return Err(Entry::failed(k, want_of(k, raw), Code::Locked, "EPP is fixed while the governor is performance"));
    }
    let targets = vet_all(w, k, raw, Class::Epp, &e.files, raw, &policy_label)?;
    Ok(Step { knob: k, want: Json::str(raw), targets, got: GotKind::Text("mixed") })
}

fn plan_turbo(m: &Machine, w: &Writer, raw: &str) -> Result<Step, Entry> {
    let k = Knob::Turbo;
    let Some((file, _)) = &m.turbo else { return Err(absent(k, raw, "this CPU driver has no turbo switch")) };
    if raw != "0" && raw != "1" {
        return Err(refuse(k, raw, "turbo must be 0 or 1"));
    }
    let value = if raw == "1" { "0" } else { "1" };
    let targets = vet_all(w, k, raw, Class::Turbo, &[(file.clone(), String::new())], value, &one_label("no_turbo"))?;
    Ok(Step { knob: k, want: Json::Bool(raw == "1"), targets, got: GotKind::Turbo })
}

fn plan_max_perf(m: &Machine, w: &Writer, raw: &str) -> Result<Step, Entry> {
    let k = Knob::MaxPerf;
    let Some(mp) = &m.max_perf else { return Err(absent(k, raw, "this CPU driver has no max_perf_pct")) };
    let Some(n) = plain_uint(raw, 3).and_then(|n| u32::try_from(n).ok()) else {
        return Err(refuse(k, raw, "max_perf_pct must be a whole number"));
    };
    if n < mp.min || n > 100 {
        return Err(refuse(k, raw, format!("max_perf_pct must be between {} and 100", mp.min)));
    }
    let targets = vet_all(
        w,
        k,
        raw,
        Class::MaxPerf,
        &[(mp.file.clone(), String::new())],
        &n.to_string(),
        &one_label("max_perf_pct"),
    )?;
    Ok(Step { knob: k, want: Json::Int(i64::from(n)), targets, got: GotKind::Int })
}

/// `firmware` (the recorded ceiling) or watts, whole or with up to three decimals (`45`, `45.5`).
fn parse_cap(raw: &str, ceiling_uw: u64) -> Result<u64, String> {
    if raw == "firmware" {
        return Ok(ceiling_uw);
    }
    parse_decimal_uw(raw, 4, 3)
        .ok_or_else(|| "a power cap is a number of watts (45 or 45.5), or 'firmware'".to_string())
}

fn plan_cap(m: &Machine, w: &Writer, req: &Request, knob: Knob) -> Result<Step, Entry> {
    let raw = req.get(knob).unwrap_or("");
    if m.zones.is_empty() {
        return Err(absent(knob, raw, "this machine has no RAPL package limits"));
    }
    let Some((ceil1, ceil2)) = m.ceilings().filter(|_| m.caps_ready()) else {
        return Err(absent(
            knob,
            raw,
            "the firmware's power limits are not on record for this boot, so they cannot be lowered safely",
        ));
    };
    let ceiling = if knob == Knob::Pl1 { ceil1 } else { ceil2 };
    let uw = parse_cap(raw, ceiling).map_err(|why| refuse(knob, raw, why))?;
    if uw < CAP_FLOOR_UW {
        return Err(refuse(knob, raw, format!("below the {} W floor", watts_text(CAP_FLOOR_UW))));
    }
    if uw > ceiling {
        return Err(refuse(knob, raw, format!("above the firmware's {} W", watts_text(ceiling))));
    }
    // PL1 <= PL2 on every zone after the call (a PL the call does not name keeps its value).
    // It is reported once, on the first of the two knobs the call names.
    let asked = |k: Knob, ceil: u64| req.get(k).and_then(|r| parse_cap(r, ceil).ok());
    let (want1, want2) = (asked(Knob::Pl1, ceil1), asked(Knob::Pl2, ceil2));
    let reporter = if req.get(Knob::Pl1).is_some() { Knob::Pl1 } else { Knob::Pl2 };
    if knob == reporter {
        for z in &m.zones {
            let (p1, p2) = (want1.unwrap_or(z.pl1_uw), want2.unwrap_or(z.pl2_uw));
            if p1 > p2 {
                return Err(refuse(
                    knob,
                    raw,
                    format!(
                        "PL1 ({} W) would be above PL2 ({} W) on the {} zone",
                        watts_text(p1),
                        watts_text(p2),
                        z.kind.name()
                    ),
                ));
            }
        }
    }
    let targets = m
        .zones
        .iter()
        .map(|z| {
            let file = if knob == Knob::Pl1 { &z.pl1_file } else { &z.pl2_file };
            let canon = w.vet(Class::Rapl, file).map_err(|e| refuse(knob, raw, e.to_string()))?;
            Ok(Target {
                label: format!("{} zone", z.kind.name()),
                path: canon,
                class: Class::Rapl,
                value: uw.to_string(),
            })
        })
        .collect::<Result<Vec<_>, Entry>>()?;
    Ok(Step { knob, want: Json::Num(watts_text(uw)), targets, got: GotKind::Watts })
}

pub fn plan_charge_limit(m: &Machine, w: &Writer, raw: &str) -> Result<Step, Entry> {
    let k = Knob::ChargeLimit;
    let Some(b) = &m.battery else { return Err(absent(k, raw, "this machine has no battery charge limit")) };
    if raw != "80" && raw != "100" {
        return Err(refuse(k, raw, "the charge limit is 80 or 100"));
    }
    let n = if raw == "80" { 80 } else { 100 };
    let targets = vet_all(
        w,
        k,
        raw,
        Class::ChargeLimit,
        &[(b.file.clone(), String::new())],
        raw,
        &one_label("charge_control_end_threshold"),
    )?;
    Ok(Step { knob: k, want: Json::Int(n), targets, got: GotKind::Int })
}

/// Validate every knob of `req`, independently; the verdicts come in the apply order.
pub fn plan(m: &Machine, w: &Writer, req: &Request) -> Vec<(Knob, Result<Step, Entry>)> {
    Knob::APPLY
        .into_iter()
        .filter_map(|knob| {
            let raw = req.get(knob)?;
            let verdict = match knob {
                Knob::Profile => plan_profile(m, w, raw),
                Knob::Governor => plan_governor(m, w, raw),
                Knob::Epp => plan_epp(m, w, req, raw),
                Knob::Turbo => plan_turbo(m, w, raw),
                Knob::MaxPerf => plan_max_perf(m, w, raw),
                Knob::Pl1 | Knob::Pl2 => plan_cap(m, w, req, knob),
                Knob::ChargeLimit | Knob::Mux => return None,
            };
            Some((knob, verdict))
        })
        .collect()
}

/// All-or-nothing: if any knob was refused, every knob is reported -- the refused ones with
/// their own code, the rest as "not written" -- and `Err` carries that report. Otherwise the
/// steps, ready to run.
pub fn require_all(verdicts: Vec<(Knob, Result<Step, Entry>)>) -> Result<Vec<Step>, Vec<Entry>> {
    let culprit = verdicts.iter().find(|(_, v)| v.is_err()).map(|(k, _)| k.name());
    let Some(culprit) = culprit else {
        return Ok(verdicts.into_iter().filter_map(|(_, v)| v.ok()).collect());
    };
    Err(verdicts
        .into_iter()
        .map(|(_, v)| match v {
            Err(entry) => entry,
            Ok(step) => {
                Entry::failed(step.knob, step.want, Code::Refused, format!("not written: {culprit} was refused"))
            }
        })
        .collect())
}

// ---------------------------------------------------------------- execution

fn same(a: &str, b: &str) -> bool {
    a == b || matches!((parse_u64(a), parse_u64(b)), (Some(x), Some(y)) if x == y)
}

fn got_json(kind: GotKind, texts: &[String]) -> Json {
    let first = texts.first().cloned().unwrap_or_default();
    match kind {
        GotKind::Text(different) => {
            Json::str(if texts.iter().all(|t| *t == first) { first } else { different.to_string() })
        }
        GotKind::Turbo => match first.as_str() {
            "0" => Json::Bool(true),
            "1" => Json::Bool(false),
            other => Json::str(other),
        },
        GotKind::Int => parse_u64(&first)
            .map_or_else(|| Json::str(first.as_str()), |n| Json::Int(i64::try_from(n).unwrap_or(i64::MAX))),
        GotKind::Watts => {
            let values: Option<Vec<u64>> = texts.iter().map(|t| parse_u64(t)).collect();
            match values.and_then(|v| v.into_iter().min()) {
                Some(uw) => Json::Num(watts_text(uw)),
                None => Json::str(first.as_str()),
            }
        }
    }
}

/// Write every target of `step`, read each back, and say what happened.
pub fn run_step(w: &Writer, step: &Step) -> Entry {
    let mut errors: Vec<String> = Vec::new();
    let mut refused_by_door = false;
    for t in &step.targets {
        if let Err(e) = w.write(step.knob.name(), t.class, &t.path, &t.value) {
            refused_by_door |= matches!(e, WriteError::Refused(_));
            errors.push(format!("{}: {e}", t.label));
        }
    }
    let mut texts: Vec<String> = Vec::new();
    let mut differing: Vec<String> = Vec::new();
    for t in &step.targets {
        match read_opt(&t.path) {
            Some(text) => {
                if !same(&text, &t.value) {
                    differing.push(format!("{} holds '{text}'", t.label));
                }
                texts.push(text);
            }
            None => errors.push(format!("{}: cannot be read back", t.label)),
        }
    }
    let got = got_json(step.got, &texts);
    let join = |v: &[String]| v.iter().take(2).cloned().collect::<Vec<_>>().join("; ");
    let (code, why) = if !errors.is_empty() {
        (if refused_by_door { Code::Refused } else { Code::Io }, join(&errors))
    } else if !differing.is_empty() {
        (Code::Mismatch, format!("written, but the kernel kept other values: {}", join(&differing)))
    } else {
        (Code::Ok, String::new())
    };
    Entry { knob: step.knob, want: step.want.clone(), got, code, why }
}

/// The order to run `steps` in: the fixed one -- except that the two caps swap when raising
/// PL1 past a zone's current PL2 needs PL2 first, so PL1 <= PL2 holds at every instant.
/// Indexes into `steps`.
pub fn exec_order(steps: &[Step], m: &Machine) -> Vec<usize> {
    let mut order: Vec<usize> = (0..steps.len()).collect();
    let at = |knob: Knob| order.iter().position(|&i| steps.get(i).is_some_and(|s| s.knob == knob));
    if let (Some(a), Some(b)) = (at(Knob::Pl1), at(Knob::Pl2)) {
        let raises_past = order.get(a).and_then(|&i| steps.get(i)).is_some_and(|s1| {
            s1.targets.iter().zip(&m.zones).any(|(t, z)| parse_u64(&t.value).is_some_and(|new1| new1 > z.pl2_uw))
        });
        if raises_past {
            order.swap(a, b);
        }
    }
    order
}

/// Run `steps` (see `exec_order`); the results come back in the apply order.
pub fn run_steps(w: &Writer, m: &Machine, steps: &[Step]) -> Vec<Entry> {
    let mut entries: Vec<Entry> =
        exec_order(steps, m).into_iter().filter_map(|i| steps.get(i)).map(|s| run_step(w, s)).collect();
    entries.sort_by_key(|e| e.knob);
    entries
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn words(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn request_parsing() {
        let r = Request::parse(&words(&["epp=power", "profile=quiet", "pl1_w=40"])).unwrap();
        assert_eq!(r.get(Knob::Profile), Some("quiet"));
        let order: Vec<Knob> = r.items.iter().map(|(k, _)| *k).collect();
        assert_eq!(order, [Knob::Profile, Knob::Epp, Knob::Pl1], "stored in the apply order");
        assert_eq!(Request::parse(&[]).unwrap(), Request::default());
        for bad in [
            &["profile"][..],
            &["nope=1"],
            &["profile=a", "profile=b"],
            &["=x"],
            &["chargeLimit=80"],
            &["max_perf_pct"],
        ] {
            assert!(Request::parse(&words(bad)).is_err(), "{bad:?}");
        }
        assert_eq!(r.words().len(), 3);
    }

    #[test]
    fn cap_values() {
        assert_eq!(parse_cap("45", 99), Ok(45_000_000));
        assert_eq!(parse_cap("0", 99), Ok(0), "zero is a number (and then below the floor)");
        assert_eq!(parse_cap("firmware", 45_000_000), Ok(45_000_000));
        assert_eq!(parse_cap("45.5", 99), Ok(45_500_000));
        assert_eq!(parse_cap("0.125", 99), Ok(125_000));
        for bad in ["", "-5", "4.", ".5", "4.1234", "45W", "0x10", "12345", " 45", "+45", "045", "00", "1e2", "4,5"] {
            assert!(parse_cap(bad, 0).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn wants_are_typed_like_the_knob() {
        assert_eq!(want_of(Knob::Turbo, "1"), Json::Bool(true));
        assert_eq!(want_of(Knob::Turbo, "maybe"), Json::str("maybe"));
        assert_eq!(want_of(Knob::MaxPerf, "80"), Json::Int(80));
        assert_eq!(want_of(Knob::MaxPerf, "8x"), Json::str("8x"));
        assert_eq!(want_of(Knob::Pl1, "60"), Json::Num("60".into()));
        assert_eq!(want_of(Knob::Pl1, "0"), Json::Num("0".into()));
        assert_eq!(want_of(Knob::Pl2, "45.50"), Json::Num("45.5".into()));
        assert_eq!(want_of(Knob::Pl2, "abc"), Json::str("abc"));
        assert_eq!(want_of(Knob::Profile, "quiet"), Json::str("quiet"));
    }

    #[test]
    fn got_values() {
        let t = |s: &[&str]| s.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        assert_eq!(got_json(GotKind::Text("mixed"), &t(&["a", "a"])), Json::str("a"));
        assert_eq!(got_json(GotKind::Text("mixed"), &t(&["a", "b"])), Json::str("mixed"));
        assert_eq!(got_json(GotKind::Turbo, &t(&["0"])), Json::Bool(true));
        assert_eq!(got_json(GotKind::Int, &t(&["80"])), Json::Int(80));
        assert_eq!(got_json(GotKind::Watts, &t(&["45000000", "30000000"])), Json::Num("30".into()));
    }

    fn cap_step(knob: Knob, per_zone_uw: &[u64]) -> Step {
        Step {
            knob,
            want: Json::Null,
            targets: per_zone_uw
                .iter()
                .map(|v| Target {
                    label: String::new(),
                    path: PathBuf::new(),
                    class: Class::Rapl,
                    value: v.to_string(),
                })
                .collect(),
            got: GotKind::Watts,
        }
    }

    #[test]
    fn caps_are_ordered_so_pl1_never_exceeds_pl2_at_any_instant() {
        use crate::machine::{Zone, ZoneKind};
        let zone = |p1: u64, p2: u64| Zone {
            kind: ZoneKind::Msr,
            pl1_file: PathBuf::new(),
            pl2_file: PathBuf::new(),
            pl1_uw: p1,
            pl2_uw: p2,
        };
        let mut m = Machine::blank();
        m.zones = vec![zone(20_000_000, 30_000_000)];
        // raising both from (20, 30) to (45, 115): PL1 would pass the old PL2 -> PL2 first
        let steps = [cap_step(Knob::Pl1, &[45_000_000]), cap_step(Knob::Pl2, &[115_000_000])];
        assert_eq!(exec_order(&steps, &m), [1, 0]);
        // lowering both from (45, 115) to (20, 30): PL1 first is fine
        m.zones = vec![zone(45_000_000, 115_000_000)];
        let steps = [cap_step(Knob::Pl1, &[20_000_000]), cap_step(Knob::Pl2, &[30_000_000])];
        assert_eq!(exec_order(&steps, &m), [0, 1]);
        // one cap alone, or other knobs around them, keep the fixed order
        let steps = [cap_step(Knob::Pl2, &[30_000_000])];
        assert_eq!(exec_order(&steps, &m), [0]);
    }

    #[test]
    fn numeric_read_backs_compare_as_numbers() {
        assert!(same("45000000", "45000000"));
        assert!(same("0045", "45"));
        assert!(!same("45", "46"));
        assert!(same("quiet", "quiet"));
        assert!(!same("quiet", "balanced"));
    }
}
