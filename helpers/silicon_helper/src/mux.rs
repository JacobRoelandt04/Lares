//! The GPU MUX. The firmware is NEVER written when the user asks: `mux-request` only writes
//! a record. `mux-apply` writes the firmware at shutdown. A switch TO dGPU-only is written with the
//! NVIDIA stack down (mirroring asusctl 6.5: the write is skipped, and the record says why, when the
//! stack cannot be brought down); the way BACK to hybrid is written whatever state the stack is in,
//! and never tries to bring it down (`needs_stack_down`). `mux-guard` runs at the next boot: it
//! checks that the wiring really changed, and for dGPU-only wiring it reverts to hybrid and reboots
//! -- once per record, the record's new state written BEFORE the reboot is asked for -- unless the
//! user confirmed in time.

use std::thread::sleep;
use std::time::{Duration, Instant};

use crate::ctx::{Ctx, Outcome};
use crate::fsx::{read_opt, read_text};
use crate::gpu;
use crate::json::Json;
use crate::knobs::Knob;
use crate::machine::{Machine, MuxKnob};
use crate::plan::{Code, Entry};
use crate::platform::{Timing, NVIDIA_UNITS};
use crate::roots::Roots;
use crate::state::{Locked, MuxRecord, MuxState, Wiring};
use crate::sys::now_ms;
use crate::whitelist::Class;
use crate::writer::{WriteError, Writer};

/// dGPU-only wiring stays unconfirmed at most this long after the boot.
const BOOT_WINDOW_MS: u64 = 300_000;
/// `mux-prompt-shown` leaves the user this long to answer.
const PROMPT_WINDOW_MS: u64 = 120_000;

fn entry(want: &str, got: &str, why: &str) -> Entry {
    Entry { knob: Knob::Mux, want: Json::str(want), got: Json::str(got), code: Code::Ok, why: why.to_string() }
}

fn failure(want: &str, code: Code, why: impl Into<String>) -> Outcome {
    Outcome::one(Entry::failed(Knob::Mux, Json::str(want), code, why))
}

/// Write a record and read it back.
fn commit(ctx: &Ctx, lock: &Locked, rec: &MuxRecord) -> Result<(), String> {
    lock.write_mux(rec).map_err(|e| format!("cannot write the MUX record: {e}"))?;
    match ctx.st.mux() {
        Ok(Some(back)) if back == *rec => Ok(()),
        Ok(_) => Err("the MUX record reads back differently from what was written".to_string()),
        Err(e) => Err(e),
    }
}

fn load(ctx: &Ctx) -> Result<Option<MuxRecord>, Outcome> {
    ctx.st.mux().map_err(|e| Outcome::one(Entry::failed(Knob::Mux, Json::Null, Code::Refused, e)))
}

fn take_lock(ctx: &Ctx) -> Result<Locked, Outcome> {
    ctx.st.lock().map_err(Outcome::io_before_write)
}

// ---------------------------------------------------------------- request / cancel / prompt / confirm

pub fn request(ctx: &Ctx, want: Wiring) -> Outcome {
    let want_s = want.as_str();
    let lock = match take_lock(ctx) {
        Ok(l) => l,
        Err(o) => return o,
    };
    // Looked at under the lock, so the decision is made on the state it will be written to.
    let m = Machine::discover_for_write(ctx.roots);
    let Some(knob) = &m.mux else {
        return failure(want_s, Code::Absent, "this machine has no GPU MUX switch");
    };
    let Some(boot_id) = m.boot_id.clone() else {
        return failure(want_s, Code::Refused, "the boot id cannot be read");
    };
    let existing = match load(ctx) {
        Ok(r) => r,
        Err(o) => return o,
    };
    if let Some(r) = &existing {
        if r.state == MuxState::AwaitingKeep {
            return failure(want_s, Code::Refused, "a GPU mode change is waiting for your confirmation");
        }
        if r.state == MuxState::Applied && r.boot_id != boot_id {
            return failure(
                want_s,
                Code::Refused,
                "the last GPU mode change has not been checked since the reboot yet",
            );
        }
    }
    let pending = existing.as_ref().filter(|r| matches!(r.state, MuxState::Queued | MuxState::Applied));
    let current = m.wiring.unwrap_or(knob.stored);

    // Already as wanted, in the panel AND in the firmware: nothing to queue; a queued
    // record that asked for the opposite is withdrawn.
    if want == current && want == knob.stored {
        let Some(r) = pending else {
            return Outcome::one(entry(want_s, "unchanged", &format!("already {want_s}")));
        };
        let mut done = r.clone();
        done.state = MuxState::Cancelled;
        done.why = format!("withdrawn: the panel is already wired as {want_s}");
        done.clear_deadline();
        return match commit(ctx, &lock, &done) {
            Ok(()) => Outcome::one(entry(want_s, "cancelled", "")),
            Err(why) => failure(want_s, Code::Io, why),
        };
    }
    if pending.is_some_and(|r| r.state == MuxState::Queued && r.want == want) {
        return Outcome::one(entry(want_s, "queued", "already queued"));
    }
    // What a NEW record needs (cancelling or withdrawing one, above, needs nothing): for dGPU-only the NVIDIA stack's
    // checks, and for both directions the unit that would write it at shutdown being active.
    let (ok, why) = m.mux_prechecks(want);
    if !ok {
        return failure(want_s, Code::Refused, why);
    }
    let rec = MuxRecord {
        want,
        from: current,
        state: MuxState::Queued,
        why: String::new(),
        requested_at_ms: now_ms(),
        boot_id,
        deadline_ms: None,
        deadline_boot_id: None,
        deadline_uptime_ms: None,
    };
    match commit(ctx, &lock, &rec) {
        Ok(()) => Outcome::one(entry(want_s, "queued", "")),
        Err(why) => failure(want_s, Code::Io, why),
    }
}

/// Move a record that is in one of `from` to `to` (the shared body of cancel and confirm).
fn transition(ctx: &Ctx, from: &[MuxState], to: MuxState, want: &str, none: &str) -> Outcome {
    let lock = match take_lock(ctx) {
        Ok(l) => l,
        Err(o) => return o,
    };
    let rec = match load(ctx) {
        Ok(r) => r,
        Err(o) => return o,
    };
    let Some(mut rec) = rec.filter(|r| from.contains(&r.state)) else {
        return failure(want, Code::Refused, none);
    };
    rec.state = to;
    rec.clear_deadline();
    rec.why = String::new();
    match commit(ctx, &lock, &rec) {
        Ok(()) => Outcome::one(entry(want, to.as_str(), "")),
        Err(why) => failure(want, Code::Io, why),
    }
}

pub fn cancel(ctx: &Ctx) -> Outcome {
    transition(ctx, &[MuxState::Queued], MuxState::Cancelled, "cancelled", "no GPU mode change is queued")
}

pub fn confirm(ctx: &Ctx) -> Outcome {
    transition(ctx, &[MuxState::AwaitingKeep], MuxState::Kept, "kept", "no GPU mode change is waiting for confirmation")
}

/// `mux-prompt-shown`: the shell put the keep prompt on screen, so the user has two minutes from now.
/// BOTH deadlines become min(deadline, now + 120 s), each on its own clock: the guard's, in time since
/// boot, and the wall-clock one the shell counts down.
pub fn prompt_shown(ctx: &Ctx) -> Outcome {
    let want = "awaiting-keep";
    let lock = match take_lock(ctx) {
        Ok(l) => l,
        Err(o) => return o,
    };
    let rec = match load(ctx) {
        Ok(r) => r,
        Err(o) => return o,
    };
    let Some(mut rec) = rec.filter(|r| r.state == MuxState::AwaitingKeep) else {
        return failure(want, Code::Refused, "no GPU mode change is waiting for confirmation");
    };
    let (Some(boot_id), Some(uptime)) = (this_boot_id(ctx.roots), uptime_ms(ctx.roots)) else {
        return Outcome::io_before_write("the boot id or the time since boot cannot be read");
    };
    // A window that counted in an earlier boot is over: the guard reverts it at once, and a prompt
    // shown now must not give it two more minutes.
    if rec.deadline_boot_id.as_deref().is_some_and(|b| b != boot_id) {
        return failure(
            want,
            Code::Refused,
            "the confirmation window belonged to an earlier boot: the change is being reverted",
        );
    }
    let soon_uptime = uptime.saturating_add(PROMPT_WINDOW_MS);
    rec.deadline_uptime_ms = Some(rec.deadline_uptime_ms.unwrap_or(BOOT_WINDOW_MS).min(soon_uptime));
    rec.deadline_boot_id = Some(boot_id);
    let soon_wall = now_ms().saturating_add(PROMPT_WINDOW_MS);
    rec.deadline_ms = Some(rec.deadline_ms.map_or(soon_wall, |d| d.min(soon_wall)));
    match commit(ctx, &lock, &rec) {
        Ok(()) => Outcome::one(entry(want, "awaiting-keep", "")),
        Err(why) => failure(want, Code::Io, why),
    }
}

// ---------------------------------------------------------------- the firmware

/// Write `gpu_mux_mode` through the whitelist door and read it back.
fn write_firmware(ctx: &Ctx, m: &Machine, want: Wiring) -> Result<(), (Code, String)> {
    let Some(knob) = &m.mux else { return Err((Code::Absent, "this machine has no GPU MUX switch".to_string())) };
    Writer::new(ctx.roots, ctx.faults).write("mux", Class::Mux, &knob.file, want.mux_value()).map_err(|e| match e {
        WriteError::Refused(why) => (Code::Refused, why),
        WriteError::Io(e) => (Code::Io, format!("writing gpu_mux_mode: {e}")),
    })?;
    match read_opt(&knob.file).as_deref().and_then(Wiring::from_mux_value) {
        Some(w) if w == want => Ok(()),
        // asus-armoury (kernel 7.2) answers with the OLD value until the restart and says so in `pending_reboot`: the
        // firmware took the write (measured 2026-11-04: read back "hybrid", `pending_reboot: 1`, and the next boot was
        // wired dgpu). Recording that as a mismatch made the record `failed`, so the guard never asked for the keep.
        // If the write really was lost, the record is `applied` and the guard finds the panel not wired as asked at
        // the next boot (`Decision::Fail`), so nothing depends on this answer being right.
        Some(_) if armoury_write_pending(knob) => Ok(()),
        Some(w) => Err((Code::Mismatch, format!("the firmware holds {} after the write", w.as_str()))),
        None => Err((Code::Mismatch, "gpu_mux_mode cannot be read back".to_string())),
    }
}

/// asus-armoury's `pending_reboot` says "1": a firmware attribute was written and waits for the restart.
fn armoury_write_pending(knob: &MuxKnob) -> bool {
    knob.armoury
        && knob
            .file
            .parent()
            .and_then(|d| d.parent())
            .and_then(|d| read_text(&d.join("pending_reboot")).ok())
            .is_some_and(|t| t.trim() == "1")
}

/// Which direction has to wait for the NVIDIA stack to come down before the firmware is written.
///
/// Only dGPU-only. It is the switch that can hurt -- the next boot then depends on the NVIDIA stack to
/// light the panel at all -- so its write is made with the stack down or not at all (the record says
/// `failed`, and the user is still on hybrid).
///
/// The way BACK is hybrid, the firmware's factory state and the user's way out, and it waits for
/// nothing: it does not even try the teardown. After a dGPU-only boot the kernel console may sit on the
/// NVIDIA card and `nvidia_drm` may refuse to unload (measured), and a rule that refused to
/// write until the stack was down would leave the machine stuck in the mode this write is there to leave.
/// The teardown (two services, the card's users, four `rmmod`s) is also the part of this helper most tied
/// to the driver and kernel version, so it is the one thing that could keep the write from happening --
/// by failing, by hanging, by crashing -- and the user's way out must not depend on it. Writing hybrid
/// with the driver loaded is what `mux-guard`'s revert already does, and it changes the firmware's
/// STORED setting only: the wiring in effect changes at the reboot (measured;
/// `status.mux.wiringNow`).
fn needs_stack_down(want: Wiring) -> bool {
    want == Wiring::Dgpu
}

/// What the record and the answer say about a way back written while NVIDIA modules were loaded
/// (empty when none were, and for the dGPU direction, which only writes with the stack down).
fn driver_note(loaded: &[String]) -> String {
    if loaded.is_empty() {
        return String::new();
    }
    format!(
        "written with the NVIDIA driver still loaded ({}): the way back does not wait for the stack",
        loaded.join(", ")
    )
}

/// Everything that keeps the NVIDIA modules in use, brought down: the two NVIDIA services
/// stopped, the dGPU's users drained (bounded), the modules unloaded dependents first. Only the
/// dGPU direction asks for it (`needs_stack_down`).
fn bring_stack_down(ctx: &Ctx, m: &Machine) -> Result<(), String> {
    for unit in NVIDIA_UNITS {
        ctx.platform.stop_unit(unit)?;
    }
    let nodes = gpu::gpu_nodes(ctx.roots, m.dgpu.as_ref());
    let start = Instant::now();
    loop {
        let held = gpu::holders(ctx.roots, &nodes, std::process::id());
        if held.is_empty() {
            break;
        }
        if start.elapsed() >= ctx.platform.timing().drain {
            let names: Vec<String> = held.iter().take(3).map(|h| format!("{} ({})", h.comm, h.pid)).collect();
            return Err(format!("the dGPU is still in use by {}", names.join(", ")));
        }
        sleep(Duration::from_millis(50));
    }
    let loaded = gpu::nvidia_modules(ctx.roots);
    for name in gpu::unload_order(&loaded)? {
        ctx.platform.unload_module(&name)?;
    }
    Ok(())
}

/// `mux-apply`, run by silicon-mux.service at shutdown.
pub fn apply(ctx: &Ctx) -> Outcome {
    let lock = match take_lock(ctx) {
        Ok(l) => l,
        Err(o) => return o,
    };
    let rec = match load(ctx) {
        Ok(r) => r,
        Err(o) => return o,
    };
    let Some(mut rec) = rec.filter(|r| r.state == MuxState::Queued) else {
        let mut o = Outcome::new(Vec::new(), 0);
        o.why = Some("no GPU mode change is queued".to_string());
        return o;
    };
    let want_s = rec.want.as_str();
    match ctx.platform.shutting_down() {
        Ok(true) => {}
        Ok(false) => {
            return failure(
                want_s,
                Code::Refused,
                "the system is not shutting down: the MUX is written only at shutdown",
            )
        }
        Err(e) => {
            return failure(want_s, Code::Refused, format!("cannot tell whether the system is shutting down: {e}"))
        }
    }
    let m = Machine::discover_for_write(ctx.roots);
    let blocked = if m.mux.is_none() {
        Some(("this machine no longer has a GPU MUX switch".to_string(), Code::Absent))
    } else if rec.want == Wiring::Dgpu && !m.precheck.0 {
        Some((format!("the pre-checks no longer pass: {}", m.precheck.1), Code::Refused))
    } else if needs_stack_down(rec.want) {
        bring_stack_down(ctx, &m).err().map(|why| {
            (format!("the NVIDIA stack could not be brought down, so the firmware was not written: {why}"), Code::Io)
        })
    } else {
        None
    };
    // What the way back is written under, as it stands at the moment of the write.
    let loaded: Vec<String> = if needs_stack_down(rec.want) {
        Vec::new()
    } else {
        gpu::nvidia_modules(ctx.roots).into_iter().map(|module| module.name).collect()
    };
    let result = match blocked {
        Some((why, code)) => Err((code, why)),
        None => write_firmware(ctx, &m, rec.want),
    };
    let mut notes = Vec::new();
    if let Some(k) = m.mux.as_ref().filter(|k| k.armoury) {
        if let Some(pending) =
            k.file.parent().and_then(|d| d.parent()).and_then(|d| read_text(&d.join("pending_reboot")).ok())
        {
            notes.push(format!("asus-armoury pending_reboot: {pending}"));
        }
    }
    let mut out = match result {
        Ok(()) => {
            let note = driver_note(&loaded);
            rec.state = MuxState::Applied;
            rec.why = note.clone();
            if !note.is_empty() {
                notes.push(note.clone());
            }
            match commit(ctx, &lock, &rec) {
                Ok(()) => Outcome::one(entry(want_s, "applied", &note)),
                Err(why) => failure(want_s, Code::Io, why),
            }
        }
        Err((code, why)) => {
            rec.state = MuxState::Failed;
            rec.why = why.clone();
            match commit(ctx, &lock, &rec) {
                Ok(()) => failure(want_s, code, why),
                Err(e) => failure(want_s, Code::Io, format!("{why}; and {e}")),
            }
        }
    };
    out.notes = notes;
    out
}

// ---------------------------------------------------------------- the guard

/// The two clocks the guard can read. Only `uptime_ms` -- time since boot, `/proc/uptime`, which
/// does not step -- ever decides anything. `wall_ms` only says what wall time a deadline falls on,
/// for the shell's countdown: a wall clock steps early in a boot when NTP corrects it (backwards,
/// when the RTC was ahead), and a guard that trusted it would leave an unconfirmed dGPU-only switch
/// -- possibly with a dark panel -- waiting for hours.
#[derive(Clone, Copy, Debug)]
pub struct Clocks {
    pub wall_ms: u64,
    pub uptime_ms: u64,
}

/// A deadline as the record carries it: the wall-clock ms the shell counts down to, and the guard's
/// own pair (the boot it counts in, and ms since that boot).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Deadline {
    pub wall_ms: Option<u64>,
    pub boot_id: Option<String>,
    pub uptime_ms: Option<u64>,
}

impl Deadline {
    /// boot + 5 min, in this boot.
    fn boot_window(boot_id: &str, clocks: Clocks) -> Deadline {
        Deadline {
            wall_ms: Some(clocks.wall_ms.saturating_sub(clocks.uptime_ms).saturating_add(BOOT_WINDOW_MS)),
            boot_id: Some(boot_id.to_string()),
            uptime_ms: Some(BOOT_WINDOW_MS),
        }
    }
}

/// What the guard does next with the record it just read.
#[derive(Debug, PartialEq)]
pub enum Decision {
    /// Nothing (more) to guard.
    Done(String),
    Wait(Duration),
    /// Move the record on (and give it this deadline: none for `kept`).
    Promote {
        state: MuxState,
        deadline: Deadline,
        why: String,
    },
    /// The switch did not take: record `failed`, and -- only when that is hybrid -- put hybrid back in the
    /// firmware (`withdraw_toward`) so a later reboot cannot surprise anyone with a pending dGPU-only setting.
    Fail {
        why: String,
        withdraw: Option<Wiring>,
    },
    /// The deadline passed unconfirmed: write hybrid, record `reverted`, reboot once.
    Revert,
}

/// What the guard writes back into the firmware when a switch did not take and the panel is wired as `found`.
/// ONLY toward hybrid. A dGPU-only switch that did not take must not leave a pending dGPU setting that a later
/// reboot could surprise anyone with, so hybrid is put back. A way BACK that did not take (the panel is still on
/// the NVIDIA card) writes nothing: the firmware keeps the hybrid it was given, and the dGPU value is never
/// written at boot -- it is written only at shutdown, for a request the user made, with the pre-checks passed
/// and the stack down, and then guarded by the confirmation window.
fn withdraw_toward(found: Wiring) -> Option<Wiring> {
    (found == Wiring::Hybrid).then_some(found)
}

/// The guard's state machine, as a pure function of what it can see. In `awaiting-keep` it decides
/// ONLY on the record's boot/uptime pair against `clocks.uptime_ms`: a deadline that counts in
/// another boot has passed (an unconfirmed record that survived a reboot), otherwise it is reached
/// when the time since boot is. The wall clock is never compared with anything.
pub fn guard_decide(
    rec: &MuxRecord,
    boot_id: &str,
    wiring: Option<Wiring>,
    waited: Duration,
    clocks: Clocks,
    timing: &Timing,
) -> Decision {
    let window = Deadline::boot_window(boot_id, clocks);
    let promote = |state, deadline, why: &str| Decision::Promote { state, deadline, why: why.to_string() };
    match rec.state {
        MuxState::Applied => {
            if rec.boot_id == boot_id {
                return Decision::Done("applied in this boot; the guard acts after the reboot".to_string());
            }
            match (rec.want, wiring) {
                (Wiring::Hybrid, Some(Wiring::Hybrid)) => promote(MuxState::Kept, Deadline::default(), ""),
                (Wiring::Dgpu, Some(Wiring::Dgpu)) => promote(MuxState::AwaitingKeep, window, ""),
                (_, Some(found)) => Decision::Fail {
                    why: format!(
                        "the panel is wired to {} after the reboot (wanted {}); {}",
                        found.as_str(),
                        rec.want.as_str(),
                        if withdraw_toward(found).is_some() {
                            "the pending firmware setting was withdrawn"
                        } else {
                            "the firmware setting was left as it is"
                        }
                    ),
                    withdraw: withdraw_toward(found),
                },
                (_, None) if waited < timing.wiring => Decision::Wait(timing.guard_poll),
                // Cannot tell. After a switch to dGPU-only the panel may well be dark: the guard stays armed.
                (Wiring::Dgpu, None) => promote(
                    MuxState::AwaitingKeep,
                    window,
                    "the panel's wiring could not be read; the guard stays armed",
                ),
                (Wiring::Hybrid, None) => Decision::Fail {
                    why: "the panel's wiring could not be read after the reboot".to_string(),
                    withdraw: None,
                },
            }
        }
        MuxState::AwaitingKeep => match (rec.deadline_boot_id.as_deref(), rec.deadline_uptime_ms) {
            (Some(b), _) if b != boot_id => Decision::Revert,
            (Some(_), Some(d)) if clocks.uptime_ms >= d => Decision::Revert,
            (Some(_), Some(d)) => Decision::Wait(Duration::from_millis(d - clocks.uptime_ms).min(timing.guard_poll)),
            // No pair (or half of one): the helper never writes it so; the boot window stands in for it.
            _ => promote(MuxState::AwaitingKeep, window, &rec.why),
        },
        _ => Decision::Done("nothing to guard".to_string()),
    }
}

/// This boot's id, from the proc root.
fn this_boot_id(roots: &Roots) -> Option<String> {
    read_opt(&roots.proc_path("sys/kernel/random/boot_id")).filter(|b| !b.is_empty())
}

/// Milliseconds since this boot began, from the proc root's `uptime` (`CLOCK_BOOTTIME`: it does not step
/// and it counts a suspend). `None` when it cannot be read as `<seconds>[.<fraction>] ...`.
fn uptime_ms(roots: &Roots) -> Option<u64> {
    let text = read_opt(&roots.proc_path("uptime"))?;
    let first = text.split_whitespace().next()?;
    let (secs, frac) = match first.split_once('.') {
        Some((s, f)) => (s, f),
        None => (first, "0"),
    };
    let digits = |t: &str| !t.is_empty() && t.bytes().all(|b| b.is_ascii_digit());
    if !digits(secs) || !digits(frac) {
        return None;
    }
    let millis: String = frac.chars().chain("000".chars()).take(3).collect();
    secs.parse::<u64>().ok()?.checked_mul(1000)?.checked_add(millis.parse::<u64>().ok()?)
}

fn revert(ctx: &Ctx, lock: &Locked, mut rec: MuxRecord) -> Outcome {
    let want_s = Wiring::Hybrid.as_str();
    let m = Machine::discover_for_write(ctx.roots);
    rec.clear_deadline();
    match write_firmware(ctx, &m, Wiring::Hybrid) {
        Err((code, why)) => {
            rec.state = MuxState::Failed;
            rec.why = format!("not confirmed in time, and hybrid could not be written back: {why}");
            let why_out = rec.why.clone();
            match commit(ctx, lock, &rec) {
                Ok(()) => failure(want_s, if code == Code::Refused { Code::Io } else { code }, why_out),
                Err(e) => failure(want_s, Code::Io, format!("{why_out}; and {e}")),
            }
        }
        Ok(()) => {
            rec.state = MuxState::Reverted;
            rec.why = "not confirmed in time: hybrid wiring was written back and the machine reboots once".to_string();
            if let Err(e) = commit(ctx, lock, &rec) {
                return failure(want_s, Code::Io, e);
            }
            // The record says `reverted` BEFORE the reboot is asked for: a second run never asks again.
            match ctx.platform.reboot() {
                Ok(()) => Outcome::one(entry(want_s, "reverted", &rec.why)),
                Err(e) => Outcome::one(Entry::failed(
                    Knob::Mux,
                    Json::str(want_s),
                    Code::Io,
                    format!("reverted, but the reboot was not started: {e}"),
                )),
            }
        }
    }
}

/// `mux-guard`, run by silicon-mux-guard.service at boot. Returns when there is nothing
/// (more) to guard.
pub fn guard(ctx: &Ctx) -> Outcome {
    let timing = ctx.platform.timing();
    let started = Instant::now();
    let Some(boot_id) = this_boot_id(ctx.roots) else {
        return Outcome::io_before_write("the boot id cannot be read");
    };
    loop {
        let lock = match take_lock(ctx) {
            Ok(l) => l,
            Err(o) => return o,
        };
        let rec = match load(ctx) {
            Ok(Some(r)) => r,
            Ok(None) => {
                let mut none = Outcome::new(Vec::new(), 0);
                none.why = Some("no GPU mode change to guard".to_string());
                return none;
            }
            Err(o) => return o,
        };
        let wiring = if rec.state == MuxState::Applied { gpu::wiring_now(ctx.roots) } else { None };
        // Time since boot decides. If /proc/uptime cannot be read the guard counts its own time (bounded,
        // from its start) -- never the wall clock.
        let own = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
        let clocks = Clocks { wall_ms: now_ms(), uptime_ms: uptime_ms(ctx.roots).unwrap_or(own) };
        match guard_decide(&rec, &boot_id, wiring, started.elapsed(), clocks, &timing) {
            Decision::Done(why) => {
                // The answer states where the record ended up, not where this run moved it to.
                let mut done = Outcome::one(entry(rec.want.as_str(), rec.state.as_str(), &rec.why));
                done.why = Some(why);
                return done;
            }
            Decision::Wait(d) => {
                drop(lock);
                sleep(d);
            }
            Decision::Promote { state, deadline, why } => {
                let mut next = rec.clone();
                next.state = state;
                next.deadline_ms = deadline.wall_ms;
                next.deadline_boot_id = deadline.boot_id;
                next.deadline_uptime_ms = deadline.uptime_ms;
                next.why = why;
                if let Err(e) = commit(ctx, &lock, &next) {
                    return Outcome::one(Entry::failed(Knob::Mux, Json::str(next.want.as_str()), Code::Io, e));
                }
            }
            Decision::Fail { why, withdraw } => {
                let mut next = rec.clone();
                next.state = MuxState::Failed;
                next.clear_deadline();
                next.why = why;
                let m = Machine::discover_for_write(ctx.roots);
                if let (Some(back), Some(k)) = (withdraw, &m.mux) {
                    if k.stored != back {
                        if let Err((_, e)) = write_firmware(ctx, &m, back) {
                            next.why =
                                format!("{}; the pending firmware setting could not be withdrawn: {e}", next.why);
                        }
                    }
                }
                return match commit(ctx, &lock, &next) {
                    Ok(()) => failure(next.want.as_str(), Code::Mismatch, next.why.clone()),
                    Err(e) => failure(next.want.as_str(), Code::Io, e),
                };
            }
            Decision::Revert => return revert(ctx, &lock, rec),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform::Platform;
    use crate::roots::TestOpts;
    use crate::state::State;
    use crate::writer::Faults;
    use std::cell::RefCell;
    use std::fs;
    use std::path::PathBuf;

    /// `deadline` = (the boot it counts in, ms since that boot).
    fn rec(state: MuxState, want: Wiring, boot: &str, deadline: Option<(&str, u64)>) -> MuxRecord {
        MuxRecord {
            want,
            from: if want == Wiring::Dgpu { Wiring::Hybrid } else { Wiring::Dgpu },
            state,
            why: String::new(),
            requested_at_ms: 1,
            boot_id: boot.into(),
            deadline_ms: deadline.map(|_| 4_000_000_000_000),
            deadline_boot_id: deadline.map(|(b, _)| b.to_string()),
            deadline_uptime_ms: deadline.map(|(_, u)| u),
        }
    }

    /// The guard of boot "boot-2", `uptime_ms` into it, with the wall clock at `wall_ms`.
    fn decide(r: &MuxRecord, wiring: Option<Wiring>, waited_ms: u64, wall_ms: u64, uptime_ms: u64) -> Decision {
        guard_decide(
            r,
            "boot-2",
            wiring,
            Duration::from_millis(waited_ms),
            Clocks { wall_ms, uptime_ms },
            &Timing::test(),
        )
    }

    fn window(wall_ms: u64, uptime_ms: u64) -> Deadline {
        Deadline {
            wall_ms: Some(wall_ms - uptime_ms + 300_000),
            boot_id: Some("boot-2".to_string()),
            uptime_ms: Some(300_000),
        }
    }

    #[test]
    fn applied_in_a_new_boot_follows_the_wiring() {
        let d = rec(MuxState::Applied, Wiring::Dgpu, "boot-1", None);
        assert_eq!(
            decide(&d, Some(Wiring::Dgpu), 0, 5_000_000, 4_000),
            Decision::Promote { state: MuxState::AwaitingKeep, deadline: window(5_000_000, 4_000), why: String::new() },
            "promotion: this boot, 300 000 ms since it; the wall deadline is for display"
        );
        let h = rec(MuxState::Applied, Wiring::Hybrid, "boot-1", None);
        assert_eq!(
            decide(&h, Some(Wiring::Hybrid), 0, 5_000, 4_000),
            Decision::Promote { state: MuxState::Kept, deadline: Deadline::default(), why: String::new() }
        );
        assert!(matches!(
            decide(&d, Some(Wiring::Hybrid), 0, 5_000, 4_000),
            Decision::Fail { withdraw: Some(Wiring::Hybrid), .. }
        ));
        // the way back that did not take (hybrid wanted, the panel still on the NVIDIA card): nothing is written
        // back -- the dGPU value is never written at boot
        match decide(&h, Some(Wiring::Dgpu), 0, 5_000, 4_000) {
            Decision::Fail { withdraw: None, why } => assert!(
                why.contains("wired to dgpu after the reboot (wanted hybrid)") && why.contains("left as it is"),
                "{why}"
            ),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn the_guard_never_withdraws_toward_dgpu() {
        // every way a record can reach the guard and fail: wanted either way, the panel wired either way or
        // unreadable, before and after the wait for the wiring. The only thing it may ever put back is hybrid.
        assert_eq!(withdraw_toward(Wiring::Hybrid), Some(Wiring::Hybrid));
        assert_eq!(withdraw_toward(Wiring::Dgpu), None);
        let (mut withdrew_hybrid, mut withdrew_nothing) = (false, false);
        for state in [MuxState::Applied, MuxState::AwaitingKeep, MuxState::Queued, MuxState::Failed] {
            for want in [Wiring::Hybrid, Wiring::Dgpu] {
                for wiring in [Some(Wiring::Hybrid), Some(Wiring::Dgpu), None] {
                    for waited in [0, 10_000] {
                        let r = rec(state, want, "boot-1", Some(("boot-2", 300_000)));
                        if let Decision::Fail { withdraw, .. } = decide(&r, wiring, waited, 5_000, 4_000) {
                            assert!(
                                matches!(withdraw, None | Some(Wiring::Hybrid)),
                                "{state:?} want {want:?} wiring {wiring:?}: {withdraw:?}"
                            );
                            withdrew_hybrid |= withdraw == Some(Wiring::Hybrid);
                            withdrew_nothing |= withdraw.is_none();
                        }
                    }
                }
            }
        }
        assert!(withdrew_hybrid && withdrew_nothing, "the sweep reached both kinds of failure");
    }

    #[test]
    fn an_unreadable_wiring_is_waited_for_and_then_guarded_for_dgpu() {
        let d = rec(MuxState::Applied, Wiring::Dgpu, "boot-1", None);
        assert!(matches!(decide(&d, None, 0, 5_000, 4_000), Decision::Wait(_)));
        assert!(
            matches!(decide(&d, None, 10_000, 5_000, 4_000), Decision::Promote { state: MuxState::AwaitingKeep, .. }),
            "a dark panel is the case the guard exists for"
        );
        let h = rec(MuxState::Applied, Wiring::Hybrid, "boot-1", None);
        assert!(matches!(decide(&h, None, 10_000, 5_000, 4_000), Decision::Fail { withdraw: None, .. }));
    }

    #[test]
    fn applied_in_the_same_boot_waits_for_the_reboot() {
        let d = rec(MuxState::Applied, Wiring::Dgpu, "boot-2", None);
        assert!(matches!(decide(&d, Some(Wiring::Dgpu), 0, 5_000, 4_000), Decision::Done(_)));
    }

    #[test]
    fn awaiting_keep_waits_by_uptime_and_reverts_when_the_uptime_reaches_the_deadline() {
        let r = rec(MuxState::AwaitingKeep, Wiring::Dgpu, "boot-1", Some(("boot-2", 300_000)));
        assert!(
            matches!(decide(&r, Some(Wiring::Dgpu), 0, 1, 299_950), Decision::Wait(d) if d == Duration::from_millis(50)),
            "the wait is what is left of the uptime, capped at the poll"
        );
        assert!(matches!(decide(&r, None, 0, 1, 10_000), Decision::Wait(d) if d <= Timing::test().guard_poll));
        assert_eq!(decide(&r, Some(Wiring::Dgpu), 0, 1, 300_000), Decision::Revert);
        assert_eq!(decide(&r, None, 0, 1, 999_999), Decision::Revert);
    }

    #[test]
    fn the_wall_clock_never_decides() {
        // The same record and the same uptime, under every wall clock a boot can show (NTP stepping it
        // back by hours, forward by days, a dead RTC at 0, the far future): the same decision.
        let walls = [0, 1, 1_000, 4_000_000_000_000, 4_000_000_000_001, 3_999_999_999_999, u64::MAX / 2, u64::MAX];
        for (uptime, expect_revert) in [(10_000u64, false), (299_999, false), (300_000, true), (7_200_000, true)] {
            let r = rec(MuxState::AwaitingKeep, Wiring::Dgpu, "boot-1", Some(("boot-2", 300_000)));
            for wall in walls {
                let got = decide(&r, Some(Wiring::Dgpu), 0, wall, uptime);
                assert_eq!(got == Decision::Revert, expect_revert, "uptime {uptime} wall {wall}: {got:?}");
                // and the wall deadline stored in the record is no input either
                let mut other = r.clone();
                other.deadline_ms = Some(wall);
                assert_eq!(decide(&other, Some(Wiring::Dgpu), 0, 5, uptime), got);
                other.deadline_ms = None;
                assert_eq!(decide(&other, Some(Wiring::Dgpu), 0, wall, uptime), got);
            }
        }
    }

    #[test]
    fn a_record_that_survived_a_reboot_is_past_its_deadline() {
        // awaiting-keep whose deadline counts in boot-1, seen by the guard of boot-2: revert at once,
        // however early in this boot it is and whatever the pair says
        let r = rec(MuxState::AwaitingKeep, Wiring::Dgpu, "boot-1", Some(("boot-1", 300_000)));
        for uptime in [0, 1_000, 299_999, 300_000] {
            assert_eq!(decide(&r, Some(Wiring::Dgpu), 0, 5_000, uptime), Decision::Revert, "uptime {uptime}");
        }
        let far = rec(MuxState::AwaitingKeep, Wiring::Dgpu, "boot-1", Some(("boot-1", u64::MAX)));
        assert_eq!(decide(&far, None, 0, 5, 1_000), Decision::Revert);
        // a pair whose boot is this one is not "another boot"
        let mine = rec(MuxState::AwaitingKeep, Wiring::Dgpu, "boot-1", Some(("boot-2", 300_000)));
        assert!(matches!(decide(&mine, None, 0, 5, 1_000), Decision::Wait(_)));
    }

    #[test]
    fn a_missing_or_half_a_pair_is_set_to_the_boot_window() {
        let mut r = rec(MuxState::AwaitingKeep, Wiring::Dgpu, "boot-1", None);
        r.deadline_ms = Some(123); // a wall deadline alone is no pair
        let expect = Decision::Promote {
            state: MuxState::AwaitingKeep,
            deadline: window(9_000_000, 20_000),
            why: String::new(),
        };
        assert_eq!(decide(&r, None, 0, 9_000_000, 20_000), expect);
        r.deadline_uptime_ms = Some(5);
        assert_eq!(decide(&r, None, 0, 9_000_000, 20_000), expect, "an uptime without its boot is not a pair");
        r.deadline_uptime_ms = None;
        r.deadline_boot_id = Some("boot-2".into());
        assert_eq!(decide(&r, None, 0, 9_000_000, 20_000), expect, "a boot without its uptime is not a pair");
    }

    #[test]
    fn terminal_and_queued_records_are_not_the_guards() {
        for s in [MuxState::Queued, MuxState::Kept, MuxState::Reverted, MuxState::Cancelled, MuxState::Failed] {
            let r = rec(s, Wiring::Dgpu, "boot-1", Some(("boot-1", 1)));
            assert!(matches!(decide(&r, Some(Wiring::Dgpu), 0, 99_999, 99_999), Decision::Done(_)), "{s:?}");
        }
    }

    #[test]
    fn a_reverted_record_never_asks_for_a_second_reboot() {
        // The reboot happens only on Decision::Revert, which only AwaitingKeep can produce.
        let r = rec(MuxState::Reverted, Wiring::Dgpu, "boot-1", Some(("boot-1", 1)));
        assert_ne!(decide(&r, Some(Wiring::Hybrid), 0, 99_999, 99_999), Decision::Revert);
    }

    #[test]
    fn uptime_is_read_strictly() {
        let dir = std::env::temp_dir().join(format!("sh-uptime-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("sys")).unwrap();
        fs::create_dir_all(dir.join("proc")).unwrap();
        let opts = TestOpts { sysfs_root: Some(dir.clone()), proc_root: Some(dir.clone()), ..TestOpts::default() };
        let roots = Roots::from_test(&opts).unwrap();
        let read = |text: &str| {
            fs::write(dir.join("proc/uptime"), text).unwrap();
            uptime_ms(&roots)
        };
        assert_eq!(read("100.50 400.00\n"), Some(100_500));
        assert_eq!(read("12345.6789 1.0"), Some(12_345_678));
        assert_eq!(read("7 3"), Some(7_000));
        assert_eq!(read("0.01 0.02"), Some(10));
        for bad in ["", "abc 1", "-1.5 2", "1.5.5 2", ".5 1", "1e3 1", "1. 2", "99999999999999999999.0 1"] {
            assert_eq!(read(bad), None, "{bad:?}");
        }
        fs::remove_file(dir.join("proc/uptime")).unwrap();
        assert_eq!(uptime_ms(&roots), None);
        let _ = fs::remove_dir_all(&dir);
    }

    // ---- mux-apply against a scripted platform: the paths only a real shutdown reaches

    struct Fake {
        shutting: Result<bool, String>,
        fail_stop: bool,
        fail_unload: Option<&'static str>,
        firmware: PathBuf,
        calls: RefCell<Vec<String>>,
    }

    impl Platform for Fake {
        fn timing(&self) -> Timing {
            Timing::test()
        }
        fn shutting_down(&self) -> Result<bool, String> {
            self.calls.borrow_mut().push("shutting_down?".into());
            self.shutting.clone()
        }
        fn stop_unit(&self, unit: &str) -> Result<(), String> {
            self.calls.borrow_mut().push(format!("stop {unit}"));
            if self.fail_stop {
                Err("stuck".into())
            } else {
                Ok(())
            }
        }
        fn unload_module(&self, name: &str) -> Result<(), String> {
            let fw = fs::read_to_string(&self.firmware).unwrap_or_default().trim().to_string();
            self.calls.borrow_mut().push(format!("unload {name} (firmware reads {fw})"));
            if self.fail_unload == Some(name) {
                Err(format!("rmmod {name}: busy"))
            } else {
                Ok(())
            }
        }
        fn reboot(&self) -> Result<(), String> {
            self.calls.borrow_mut().push("reboot".into());
            Ok(())
        }
        fn wifi_power_save(&self, _iface: &str, on: bool) -> Result<bool, String> {
            Ok(on)
        }
    }

    struct World {
        dir: PathBuf,
        roots: Roots,
        st: State,
        firmware: PathBuf,
    }

    impl Drop for World {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }

    /// A machine with a dGPU-only switch queued (the firmware still holds hybrid).
    fn world(tag: &str) -> World {
        world_for(tag, Wiring::Dgpu)
    }

    /// A machine with a `want` switch queued; the firmware still holds the OTHER setting, as it does the
    /// moment before the write (for the way back, dGPU-only: `0`).
    fn world_for(tag: &str, want: Wiring) -> World {
        let dir = std::env::temp_dir().join(format!("sh-mux-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let put = |rel: &str, text: &str| {
            let p = dir.join(rel);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            fs::write(p, text).unwrap();
        };
        put("root/sys/devices/platform/asus-nb-wmi/gpu_mux_mode", if want == Wiring::Dgpu { "1\n" } else { "0\n" });
        put("procroot/proc/sys/kernel/random/boot_id", "boot-1\n");
        put(
            "procroot/proc/modules",
            "nvidia_uvm 1 0 - Live 0x0\nnvidia_drm 1 0 - Live 0x0\nnvidia_modeset 1 1 nvidia_drm, Live 0x0\nnvidia 1 2 nvidia_uvm,nvidia_modeset, Live 0x0\n",
        );
        put("modules/6.0/vmlinuz", "");
        put("modules/6.0/updates/dkms/nvidia.ko.zst", "");
        fs::create_dir_all(dir.join("devroot/dev")).unwrap();
        let opts = TestOpts {
            sysfs_root: Some(dir.join("root")),
            proc_root: Some(dir.join("procroot")),
            state_dir: Some(dir.join("state")),
            dev_root: Some(dir.join("devroot")),
            modules_root: Some(dir.join("modules")),
            run_root: None,
        };
        let roots = Roots::from_test(&opts).unwrap();
        let st = State::new(roots.state.clone());
        let lock = st.lock().unwrap();
        lock.write_mux(&rec(MuxState::Queued, want, "boot-1", None)).unwrap();
        drop(lock);
        let firmware = dir.join("root/sys/devices/platform/asus-nb-wmi/gpu_mux_mode");
        World { dir, roots, st, firmware }
    }

    fn fake(w: &World) -> Fake {
        Fake {
            shutting: Ok(true),
            fail_stop: false,
            fail_unload: None,
            firmware: w.firmware.clone(),
            calls: RefCell::new(Vec::new()),
        }
    }

    fn run_apply(w: &World, p: &Fake) -> Outcome {
        let faults = Faults::none();
        apply(&Ctx { roots: &w.roots, faults: &faults, platform: p, st: &w.st })
    }

    fn firmware(w: &World) -> String {
        fs::read_to_string(&w.firmware).unwrap().trim().to_string()
    }

    #[test]
    fn apply_does_nothing_unless_the_system_is_shutting_down() {
        for answer in [Ok(false), Err("no systemd".to_string())] {
            let w = world("notshutting");
            let p = Fake { shutting: answer.clone(), ..fake(&w) };
            let before = fs::read_to_string(w.dir.join("state/mux.json")).unwrap();
            let out = run_apply(&w, &p);
            assert_eq!(out.code, 2, "{answer:?}");
            assert_eq!(out.entries.first().map(|e| e.code), Some(Code::Refused));
            assert_eq!(firmware(&w), "1", "the firmware is not written outside a shutdown");
            assert_eq!(
                fs::read_to_string(w.dir.join("state/mux.json")).unwrap(),
                before,
                "the record stays queued for the real shutdown"
            );
            assert_eq!(*p.calls.borrow(), ["shutting_down?"], "no unit was stopped, no module unloaded");
        }
    }

    #[test]
    fn the_stack_comes_down_in_order_and_the_firmware_is_written_after_the_last_unload() {
        let w = world("order");
        let p = fake(&w);
        let out = run_apply(&w, &p);
        assert_eq!(out.code, 0);
        assert_eq!(firmware(&w), "0");
        let calls = p.calls.borrow().clone();
        assert_eq!(calls.first().map(String::as_str), Some("shutting_down?"));
        assert_eq!(calls.get(1).map(String::as_str), Some("stop nvidia-powerd.service"));
        assert_eq!(calls.get(2).map(String::as_str), Some("stop nvidia-persistenced.service"));
        let unloads: Vec<&String> = calls.iter().filter(|c| c.starts_with("unload")).collect();
        assert_eq!(unloads.len(), 4);
        let pos = |name: &str| calls.iter().position(|c| c.starts_with(&format!("unload {name} "))).unwrap();
        assert!(
            pos("nvidia_drm") < pos("nvidia_modeset")
                && pos("nvidia_modeset") < pos("nvidia")
                && pos("nvidia_uvm") < pos("nvidia")
        );
        assert!(
            unloads.iter().all(|c| c.ends_with("(firmware reads 1)")),
            "every unload happened BEFORE the firmware write: {unloads:?}"
        );
        assert!(!calls.iter().any(|c| c == "reboot"), "mux-apply never reboots");
    }

    #[test]
    fn a_unit_that_will_not_stop_means_no_unload_and_no_write() {
        let w = world("stuck");
        let p = Fake { fail_stop: true, ..fake(&w) };
        let out = run_apply(&w, &p);
        assert_eq!(out.code, 1);
        assert_eq!(firmware(&w), "1");
        assert!(!p.calls.borrow().iter().any(|c| c.starts_with("unload")));
        let rec = w.st.mux().unwrap().unwrap();
        assert_eq!(rec.state, MuxState::Failed);
        assert!(rec.why.contains("stuck"), "{}", rec.why);
    }

    #[test]
    fn a_module_that_will_not_unload_means_no_write_and_the_why_says_which() {
        let w = world("busy");
        let p = Fake { fail_unload: Some("nvidia"), ..fake(&w) };
        let out = run_apply(&w, &p);
        assert_eq!(out.code, 1);
        assert_eq!(firmware(&w), "1", "the firmware is not written with the NVIDIA stack up");
        let rec = w.st.mux().unwrap().unwrap();
        assert_eq!(rec.state, MuxState::Failed);
        assert!(rec.why.contains("rmmod nvidia: busy") && rec.why.contains("not written"), "{}", rec.why);
    }

    // ---- the way back: hybrid is written whatever state the NVIDIA stack is in

    #[test]
    fn only_the_dgpu_direction_waits_for_the_stack() {
        assert!(needs_stack_down(Wiring::Dgpu));
        assert!(!needs_stack_down(Wiring::Hybrid), "the way back is the user's way out: it waits for nothing");
    }

    #[test]
    fn the_way_back_is_written_without_asking_anything_of_the_stack() {
        // every step of the teardown is armed to fail: the services will not stop, nvidia_drm will not unload
        let w = world_for("wayback", Wiring::Hybrid);
        let p = Fake { fail_stop: true, fail_unload: Some("nvidia_drm"), ..fake(&w) };
        assert_eq!(firmware(&w), "0", "dGPU-only is what the firmware holds before the write");
        let out = run_apply(&w, &p);
        assert_eq!(out.code, 0, "{:?}", out.entries.first().map(|e| e.why.clone()));
        assert_eq!(firmware(&w), "1", "hybrid was written with the driver loaded");
        assert_eq!(
            *p.calls.borrow(),
            ["shutting_down?"],
            "no service was stopped and no module unloaded: the teardown is not even tried"
        );
        let rec = w.st.mux().unwrap().unwrap();
        assert_eq!(rec.state, MuxState::Applied);
        assert!(
            rec.why.contains("written with the NVIDIA driver still loaded")
                && ["nvidia_uvm", "nvidia_drm", "nvidia_modeset", "nvidia"].iter().all(|m| rec.why.contains(m)),
            "the record says so, and names what was loaded: {}",
            rec.why
        );
        let entry = out.entries.first().unwrap();
        assert!(entry.ok() && entry.why == rec.why, "the answer says the same: {}", entry.why);
        assert_eq!(out.notes, std::slice::from_ref(&rec.why), "and so does stderr");
    }

    #[test]
    fn the_way_back_has_nothing_to_say_when_no_driver_is_loaded() {
        let w = world_for("wayback-bare", Wiring::Hybrid);
        fs::write(w.dir.join("procroot/proc/modules"), "snd_hda_intel 233472 3 - Live 0x0\n").unwrap();
        let p = fake(&w);
        let out = run_apply(&w, &p);
        assert_eq!(out.code, 0);
        assert_eq!(firmware(&w), "1");
        let rec = w.st.mux().unwrap().unwrap();
        assert_eq!((rec.state, rec.why.as_str()), (MuxState::Applied, ""));
        assert!(out.notes.is_empty() && out.entries.first().is_some_and(|e| e.why.is_empty()));
    }

    #[test]
    fn the_way_back_still_waits_for_the_shutdown() {
        for answer in [Ok(false), Err("no systemd".to_string())] {
            let w = world_for("wayback-notshutting", Wiring::Hybrid);
            let p = Fake { shutting: answer.clone(), ..fake(&w) };
            let before = fs::read_to_string(w.dir.join("state/mux.json")).unwrap();
            let out = run_apply(&w, &p);
            assert_eq!(out.code, 2, "{answer:?}");
            assert_eq!(firmware(&w), "0", "the firmware is not written outside a shutdown, in either direction");
            assert_eq!(fs::read_to_string(w.dir.join("state/mux.json")).unwrap(), before);
            assert_eq!(*p.calls.borrow(), ["shutting_down?"]);
        }
    }

    #[test]
    fn the_way_back_needs_the_switch_to_be_there() {
        let w = world_for("wayback-noswitch", Wiring::Hybrid);
        fs::remove_file(&w.firmware).unwrap();
        let out = run_apply(&w, &fake(&w));
        assert_eq!(out.code, 2);
        assert_eq!(out.entries.first().map(|e| e.code), Some(Code::Absent));
        assert_eq!(w.st.mux().unwrap().unwrap().state, MuxState::Failed);
    }

    #[test]
    fn the_way_back_goes_through_the_same_door_and_is_read_back() {
        // the kernel that ignores the write, and the one that clamps it to dGPU-only: both are a failed
        // record, never an `applied` one
        for (fault, code) in [("mux:ignore", Code::Mismatch), ("mux:clamp:dgpu", Code::Mismatch), ("mux:eio", Code::Io)]
        {
            let w = world_for("wayback-fault", Wiring::Hybrid);
            let faults = Faults::parse(fault).unwrap();
            let p = fake(&w);
            let out = apply(&Ctx { roots: &w.roots, faults: &faults, platform: &p, st: &w.st });
            assert_eq!(out.entries.first().map(|e| e.code), Some(code), "{fault}");
            assert_eq!(firmware(&w), "0", "{fault}: nothing but the faulty write happened");
            assert_eq!(w.st.mux().unwrap().unwrap().state, MuxState::Failed, "{fault}");
            assert_eq!(*p.calls.borrow(), ["shutting_down?"], "{fault}");
        }
    }
}
