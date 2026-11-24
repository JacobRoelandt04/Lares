//! The wire format: `status` as HELPER_PROTOCOL.md v1 lays it out, and the envelope around
//! results. Field names, nesting and nulls are the protocol's; nothing is added to them.

use std::path::Path;

use crate::fsx::watts_text;
use crate::json::Json;
use crate::machine::{Machine, Zone, ZoneKind, CAP_FLOOR_UW};
use crate::plan::Entry;
use crate::state::Wiring;

pub const PROTO: i64 = 1;

fn path_json(p: &Option<impl AsRef<Path>>) -> Json {
    p.as_ref().map_or(Json::Null, |p| Json::str(p.as_ref().to_string_lossy().into_owned()))
}

fn watts(uw: u64) -> Json {
    Json::Num(watts_text(uw))
}

fn zone_json(zones: &[Zone], kind: ZoneKind) -> Json {
    zones
        .iter()
        .find(|z| z.kind == kind)
        .map_or(Json::Null, |z| Json::obj([("pl1W", watts(z.pl1_uw)), ("pl2W", watts(z.pl2_uw))]))
}

fn caps_value(m: &Machine) -> Json {
    match m.effective_caps() {
        None => Json::Null,
        Some((pl1, pl2)) => Json::obj([
            ("pl1W", watts(pl1)),
            ("pl2W", watts(pl2)),
            (
                "zones",
                Json::obj([("msr", zone_json(&m.zones, ZoneKind::Msr)), ("mmio", zone_json(&m.zones, ZoneKind::Mmio))]),
            ),
        ]),
    }
}

pub fn status_json(m: &Machine) -> Json {
    let features = Json::obj([
        ("profile", Json::Bool(m.profile.is_some())),
        ("epp", Json::Bool(m.epp.is_some())),
        ("turbo", Json::Bool(m.turbo.is_some())),
        ("governor", Json::Bool(m.governor.is_some())),
        ("maxPerfPct", Json::Bool(m.max_perf.is_some())),
        ("caps", Json::Bool(m.caps_ready())),
        ("chargeLimit", Json::Bool(m.battery.is_some())),
        ("mux", Json::Bool(m.mux.is_some())),
    ]);
    let stored = m.mux.as_ref().map(|k| k.stored.as_str());
    let values = Json::obj([
        ("profile", Json::opt_str(m.profile.as_ref().map(|p| p.value.as_str()))),
        ("epp", Json::opt_str(m.epp.as_ref().map(|p| p.value.as_str()))),
        ("turbo", m.turbo.as_ref().map_or(Json::Null, |(_, on)| Json::Bool(*on))),
        ("governor", Json::opt_str(m.governor.as_ref().map(|p| p.value.as_str()))),
        ("maxPerfPct", m.max_perf.as_ref().map_or(Json::Null, |mp| Json::Int(i64::from(mp.value)))),
        ("caps", caps_value(m)),
        ("chargeLimit", m.battery.as_ref().map_or(Json::Null, |b| Json::Int(b.limit))),
        ("muxStored", Json::opt_str(stored)),
    ]);
    let empty: Vec<String> = Vec::new();
    let lists = Json::obj([
        ("profiles", Json::strs(m.profile.as_ref().map_or(&empty, |p| &p.choices))),
        ("epps", Json::strs(m.epp.as_ref().map_or(&empty, |p| &p.choices))),
        ("governors", Json::strs(m.governor.as_ref().map_or(&empty, |p| &p.choices))),
    ]);
    let limits = Json::obj([
        ("capFloorW", watts(CAP_FLOOR_UW)),
        ("capCeilW", m.ceilings().map_or(Json::Null, |(p1, p2)| Json::obj([("pl1", watts(p1)), ("pl2", watts(p2))]))),
        (
            "maxPerfPct",
            m.max_perf
                .as_ref()
                .map_or(Json::Null, |mp| Json::obj([("min", Json::Int(i64::from(mp.min))), ("max", Json::Int(100))])),
        ),
        ("eppLocked", Json::Bool(m.epp_locked())),
    ]);
    let dgpu = m.dgpu.as_ref().map_or(Json::Null, |d| {
        Json::obj([
            ("pci", Json::str(d.pci.as_str())),
            ("card", path_json(&d.card)),
            ("render", path_json(&d.render)),
            ("nvidia", path_json(&d.nvidia)),
            ("powerState", path_json(&d.power_state)),
        ])
    });
    let paths = Json::obj([
        ("dgpu", dgpu),
        ("battery", path_json(&m.battery.as_ref().map(|b| b.path.clone()))),
        ("ac", path_json(&m.paths.ac)),
        ("coretemp", path_json(&m.paths.coretemp)),
        ("rc6", path_json(&m.paths.rc6)),
        ("cpufreq", path_json(&m.paths.cpufreq)),
    ]);
    // what a request for dGPU-only, the stricter direction, would meet: the NVIDIA stack's checks and the unit
    let (mux_ok, mux_why) = m.mux_prechecks(Wiring::Dgpu);
    let prechecks = Json::obj([("mux", Json::obj([("ok", Json::Bool(mux_ok)), ("why", Json::str(mux_why))]))]);
    let mux = Json::obj([
        ("stored", Json::opt_str(stored)),
        ("wiringNow", Json::opt_str(m.wiring.map(|w| w.as_str()))),
        ("record", m.mux_record.as_ref().map_or(Json::Null, |r| r.to_json())),
    ]);
    let applied = match (&m.mark, &m.boot_id) {
        (Some(mark), Some(id)) => mark.boot_id == *id && mark.ok,
        _ => false,
    };
    let boot = Json::obj([("id", Json::opt_str(m.boot_id.as_deref())), ("applied", Json::Bool(applied))]);
    Json::obj([
        ("features", features),
        ("values", values),
        ("lists", lists),
        ("limits", limits),
        ("paths", paths),
        ("prechecks", prechecks),
        ("mux", mux),
        ("boot", boot),
    ])
}

/// What a call answers: `ok`, the protocol version, the per-knob results (writes), a `why`
/// when the call as a whole was refused or failed, and the status read after the writes.
pub struct Answer {
    pub ok: bool,
    pub results: Option<Vec<Entry>>,
    pub why: Option<String>,
    pub status: Option<Json>,
}

impl Answer {
    pub fn to_json(&self) -> Json {
        let mut pairs: Vec<(&str, Json)> = vec![("ok", Json::Bool(self.ok)), ("proto", Json::Int(PROTO))];
        if let Some(why) = &self.why {
            pairs.push(("why", Json::str(why.as_str())));
        }
        if let Some(results) = &self.results {
            pairs.push(("results", Json::Arr(results.iter().map(Entry::to_json).collect())));
        }
        if let Some(status) = &self.status {
            pairs.push(("status", status.clone()));
        }
        Json::Obj(pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
    }
}
