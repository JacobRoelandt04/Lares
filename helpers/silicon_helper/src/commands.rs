//! `apply`, `set-charge-limit`, `set-boot` and `boot-apply`: everything that writes kernel
//! knobs. Each takes the one lock first, looks at the machine, validates the WHOLE request,
//! and only then writes.

use std::thread::sleep;
use std::time::Instant;

use crate::ctx::{Ctx, Outcome};
use crate::knobs::Knob;
use crate::machine::{Machine, ZoneKind};
use crate::plan::{self, Code, Entry, Request};
use crate::state::{BootMark, BootSet, CapsRecord, Locked, ZoneCaps};
use crate::sys::now_ms;
use crate::writer::Writer;

fn exit_of(entries: &[Entry]) -> i32 {
    if entries.iter().all(Entry::ok) {
        0
    } else if entries.iter().any(|e| matches!(e.code, Code::Io | Code::Mismatch)) {
        1
    } else {
        2
    }
}

/// `apply [key=value ...]`: any subset, all or nothing.
pub fn apply(ctx: &Ctx, words: &[String]) -> Outcome {
    let req = match Request::parse(words) {
        Ok(r) => r,
        Err(why) => return Outcome::usage(why),
    };
    if req.items.is_empty() {
        return Outcome::new(Vec::new(), 0);
    }
    let _lock = match ctx.st.lock() {
        Ok(l) => l,
        Err(e) => return Outcome::io_before_write(e),
    };
    let m = Machine::discover_for_write(ctx.roots);
    let w = Writer::new(ctx.roots, ctx.faults);
    match plan::require_all(plan::plan(&m, &w, &req)) {
        Err(entries) => Outcome::new(entries, 2),
        Ok(steps) => {
            let entries = plan::run_steps(&w, &m, &steps);
            let code = exit_of(&entries);
            Outcome::new(entries, code)
        }
    }
}

/// `set-charge-limit 80|100`: written now, and stored for the next boot.
pub fn set_charge_limit(ctx: &Ctx, words: &[String]) -> Outcome {
    let [raw] = words else { return Outcome::usage("set-charge-limit takes one value: 80 or 100") };
    let lock = match ctx.st.lock() {
        Ok(l) => l,
        Err(e) => return Outcome::io_before_write(e),
    };
    let m = Machine::discover_for_write(ctx.roots);
    let w = Writer::new(ctx.roots, ctx.faults);
    let step = match plan::plan_charge_limit(&m, &w, raw) {
        Ok(s) => s,
        Err(e) => return Outcome::one(e),
    };
    // The stored boot set must be readable before anything is written.
    let old = match ctx.st.boot_set() {
        Ok(s) => s.unwrap_or_default(),
        Err(why) => return Outcome::one(Entry::failed(Knob::ChargeLimit, step.want, Code::Refused, why)),
    };
    let mut entry = plan::run_step(&w, &step);
    if entry.ok() {
        let limit = if raw == "80" { 80 } else { 100 };
        let new = BootSet { apply: old.apply.clone(), charge_limit: Some(limit) };
        let stored = lock.write_boot_set(&new).map_err(|e| e.to_string()).and_then(|()| match ctx.st.boot_set() {
            Ok(Some(back)) if back == new => Ok(()),
            Ok(_) => Err("boot.json reads back differently from what was written".to_string()),
            Err(e) => Err(e),
        });
        if let Err(why) = stored {
            entry.code = Code::Io;
            entry.why = format!("the limit was set, but could not be stored for the next boot: {why}");
        }
    }
    Outcome::one(entry)
}

/// `set-boot <apply arguments>`: validated as `apply` would, then stored.
pub fn set_boot(ctx: &Ctx, words: &[String]) -> Outcome {
    let req = match Request::parse(words) {
        Ok(r) => r,
        Err(why) => return Outcome::usage(why),
    };
    let lock = match ctx.st.lock() {
        Ok(l) => l,
        Err(e) => return Outcome::io_before_write(e),
    };
    let m = Machine::discover_for_write(ctx.roots);
    let w = Writer::new(ctx.roots, ctx.faults);
    let steps = match plan::require_all(plan::plan(&m, &w, &req)) {
        Ok(s) => s,
        Err(entries) => return Outcome::new(entries, 2),
    };
    let old = match ctx.st.boot_set() {
        Ok(s) => s.unwrap_or_default(),
        Err(why) => return Outcome::usage(why),
    };
    let new = BootSet { apply: req.words(), charge_limit: old.charge_limit };
    let stored = lock.write_boot_set(&new).map_err(|e| e.to_string()).and_then(|()| match ctx.st.boot_set() {
        Ok(Some(back)) if back == new => Ok(()),
        Ok(_) => Err("boot.json reads back differently from what was written".to_string()),
        Err(e) => Err(e),
    });
    let entries: Vec<Entry> = steps
        .into_iter()
        .map(|s| match &stored {
            Ok(()) => Entry::success(s.knob, s.want.clone(), s.want),
            Err(why) => Entry::failed(s.knob, s.want, Code::Io, why.clone()),
        })
        .collect();
    let code = exit_of(&entries);
    Outcome::new(entries, code)
}

/// Knobs `boot-apply` is about to need that are not registered yet (what it waits for).
fn missing_for_boot(m: &Machine, set: Option<&BootSet>, previous: Option<&CapsRecord>) -> Vec<&'static str> {
    let mut missing = Vec::new();
    if let Some(set) = set {
        for (key, _) in &set.apply {
            let absent = match Knob::from_arg(key) {
                Some(Knob::Profile) => m.profile.is_none(),
                Some(Knob::Governor) => m.governor.is_none(),
                Some(Knob::Epp) => m.epp.is_none(),
                Some(Knob::Turbo) => m.turbo.is_none(),
                Some(Knob::MaxPerf) => m.max_perf.is_none(),
                Some(Knob::Pl1 | Knob::Pl2) => m.zones.is_empty(),
                _ => false,
            };
            if absent {
                missing.push(Knob::from_arg(key).map_or("knob", Knob::name));
            }
        }
        if set.charge_limit.is_some() && m.battery.is_none() {
            missing.push("chargeLimit");
        }
    }
    // A zone that was there at the last boot is expected again.
    if let Some(prev) = previous {
        for (kind, was) in [(ZoneKind::Msr, prev.msr.is_some()), (ZoneKind::Mmio, prev.mmio.is_some())] {
            if was && !m.zones.iter().any(|z| z.kind == kind) {
                missing.push("rapl");
            }
        }
    }
    missing
}

fn zone_caps(m: &Machine, kind: ZoneKind) -> Option<ZoneCaps> {
    m.zones.iter().find(|z| z.kind == kind).map(|z| ZoneCaps { pl1_uw: z.pl1_uw, pl2_uw: z.pl2_uw })
}

/// What `record_caps_locked` found to do.
#[derive(Debug, PartialEq, Eq)]
pub enum Recorded {
    /// This boot had no record: the firmware's limits are on record now.
    Now,
    /// This boot already has its record: nothing was recorded (a later run would record values something lowered).
    Already,
    /// No RAPL package zone is present: there is nothing to record (a later run still may).
    NoZone,
}

/// Record the firmware's power limits for this boot -- only if the record's bootId is not this boot's -- and
/// read the record back. The ONE piece of code behind both `record-caps` and the first half of `boot-apply`.
fn record_caps_locked(ctx: &Ctx, lock: &Locked, m: &Machine, boot_id: &str) -> Result<Recorded, String> {
    if m.caps_record.as_ref().map(|r| r.boot_id.as_str()) == Some(boot_id) {
        return Ok(Recorded::Already);
    }
    if m.zones.is_empty() {
        return Ok(Recorded::NoZone);
    }
    let record = CapsRecord {
        boot_id: boot_id.to_string(),
        msr: zone_caps(m, ZoneKind::Msr),
        mmio: zone_caps(m, ZoneKind::Mmio),
    };
    lock.write_caps(&record).map_err(|e| e.to_string())?;
    match ctx.st.caps() {
        Ok(Some(back)) if back == record => Ok(Recorded::Now),
        Ok(_) => Err("the firmware's limits read back differently from what was recorded".to_string()),
        Err(e) => Err(e),
    }
}

/// `record-caps`: record the firmware's power limits for this boot, if this boot has not recorded them yet, and
/// NOTHING else -- no boot set applied, no charge limit written, no boot mark. `install.sh` runs it, so a
/// re-install in the middle of a session (a binary update, a boot set already stored) cannot re-apply the
/// stored boot profile over the one the user is using.
pub fn record_caps(ctx: &Ctx) -> Outcome {
    let lock = match ctx.st.lock() {
        Ok(l) => l,
        Err(e) => return Outcome::io_before_write(e),
    };
    let m = Machine::discover_for_write(ctx.roots);
    let Some(boot_id) = m.boot_id.clone() else {
        return Outcome::io_before_write("the boot id cannot be read");
    };
    let mut out = Outcome::new(Vec::new(), 0);
    match record_caps_locked(ctx, &lock, &m, &boot_id) {
        Ok(Recorded::Now) => {}
        Ok(Recorded::Already) => {
            out.why = Some("the firmware's power limits are already on record for this boot".to_string())
        }
        Ok(Recorded::NoZone) => out.why = Some("no RAPL package zone is present: nothing to record".to_string()),
        Err(e) => {
            out.code = 1;
            out.why = Some(format!("the firmware's power limits could not be recorded: {e}"));
        }
    }
    out.notes = m.notes;
    out
}

/// `boot-apply`, run by silicon-boot.service early in every boot. FIRST it does what `record-caps` does (the
/// firmware's power limits for this boot, only if this boot has no record yet: a later run would record values
/// something lowered), THEN it applies the stored boot set and the stored charge limit. Knobs that are not
/// registered yet are waited for (bounded). A stored value the kernel no longer accepts is reported and
/// skipped; the others still land.
pub fn boot_apply(ctx: &Ctx) -> Outcome {
    let timing = ctx.platform.timing();
    let mut notes: Vec<String> = Vec::new();
    let mut failed = false;
    let mut why: Option<String> = None;
    // A boot set that is not understood is never guessed at: nothing is applied from it, and the run says so.
    let set = match ctx.st.boot_set() {
        Ok(s) => s,
        Err(e) => {
            failed = true;
            why = Some(e.clone());
            notes.push(e);
            None
        }
    };
    let previous = ctx.st.caps().unwrap_or(None);
    let started = Instant::now();
    loop {
        let m = Machine::discover_for_write(ctx.roots);
        if missing_for_boot(&m, set.as_ref(), previous.as_ref()).is_empty() || started.elapsed() >= timing.boot_wait {
            break;
        }
        sleep(timing.boot_poll);
    }

    let lock = match ctx.st.lock() {
        Ok(l) => l,
        Err(e) => return Outcome::io_before_write(e),
    };
    let m = Machine::discover_for_write(ctx.roots);
    notes.extend(m.notes.iter().cloned());
    let Some(boot_id) = m.boot_id.clone() else {
        return Outcome::io_before_write("the boot id cannot be read");
    };

    if let Err(e) = record_caps_locked(ctx, &lock, &m, &boot_id) {
        failed = true;
        why = Some(format!("the firmware's power limits could not be recorded: {e}"));
    }

    let m = Machine::discover_for_write(ctx.roots);
    let w = Writer::new(ctx.roots, ctx.faults);
    let mut entries: Vec<Entry> = Vec::new();
    if let Some(set) = &set {
        let words: Vec<String> = set.apply.iter().map(|(k, v)| format!("{k}={v}")).collect();
        match Request::parse(&words) {
            Err(e) => {
                failed = true;
                why = Some(format!("the stored boot set is not understood: {e}"));
            }
            Ok(req) => {
                let mut steps = Vec::new();
                for (_, verdict) in plan::plan(&m, &w, &req) {
                    match verdict {
                        Ok(s) => steps.push(s),
                        Err(e) => entries.push(e),
                    }
                }
                entries.extend(plan::run_steps(&w, &m, &steps));
                entries.sort_by_key(|e| e.knob);
            }
        }
        if let Some(limit) = set.charge_limit {
            entries.push(match plan::plan_charge_limit(&m, &w, &limit.to_string()) {
                Ok(step) => plan::run_step(&w, &step),
                Err(e) => e,
            });
        }
    }

    let all_ok = entries.iter().all(Entry::ok) && !failed;
    let mark = BootMark { boot_id, at_ms: now_ms(), ok: all_ok };
    if let Err(e) = lock.write_mark(&mark) {
        failed = true;
        why = Some(format!("cannot record that boot-apply ran: {e}"));
    }
    let mut out = Outcome::new(entries, if all_ok && !failed { 0 } else { 1 });
    out.why = why.or_else(|| notes.first().cloned());
    out.notes = notes;
    out
}
