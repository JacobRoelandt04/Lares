//! The knobs a write can name, their names in results and in `apply` arguments, and the
//! order `apply` writes them in.

#[derive(Clone, Copy, PartialEq, Eq, Debug, PartialOrd, Ord)]
pub enum Knob {
    Profile,
    Governor,
    Epp,
    Turbo,
    MaxPerf,
    Pl1,
    Pl2,
    ChargeLimit,
    Mux,
}

impl Knob {
    /// The knobs of `apply`, in the order they are applied: profile, governor, EPP, turbo,
    /// max_perf_pct, then the caps.
    pub const APPLY: [Knob; 7] =
        [Knob::Profile, Knob::Governor, Knob::Epp, Knob::Turbo, Knob::MaxPerf, Knob::Pl1, Knob::Pl2];

    /// The `knob` a result carries.
    pub fn name(self) -> &'static str {
        match self {
            Knob::Profile => "profile",
            Knob::Governor => "governor",
            Knob::Epp => "epp",
            Knob::Turbo => "turbo",
            Knob::MaxPerf => "maxPerfPct",
            Knob::Pl1 => "pl1W",
            Knob::Pl2 => "pl2W",
            Knob::ChargeLimit => "chargeLimit",
            Knob::Mux => "mux",
        }
    }

    /// The `key=` of an `apply` argument.
    pub fn arg(self) -> Option<&'static str> {
        match self {
            Knob::Profile => Some("profile"),
            Knob::Governor => Some("governor"),
            Knob::Epp => Some("epp"),
            Knob::Turbo => Some("turbo"),
            Knob::MaxPerf => Some("max_perf_pct"),
            Knob::Pl1 => Some("pl1_w"),
            Knob::Pl2 => Some("pl2_w"),
            Knob::ChargeLimit | Knob::Mux => None,
        }
    }

    pub fn from_arg(key: &str) -> Option<Knob> {
        Knob::APPLY.into_iter().find(|k| k.arg() == Some(key))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arguments_and_names_round_trip() {
        for k in Knob::APPLY {
            assert_eq!(k.arg().and_then(Knob::from_arg), Some(k));
        }
        assert_eq!(Knob::from_arg("custom"), None);
        assert_eq!(Knob::from_arg("chargeLimit"), None);
        assert_eq!(Knob::MaxPerf.name(), "maxPerfPct");
        assert_eq!(Knob::from_arg("max_perf_pct"), Some(Knob::MaxPerf));
    }

    #[test]
    fn apply_order_is_the_documented_one() {
        let names: Vec<&str> = Knob::APPLY.iter().map(|k| k.name()).collect();
        assert_eq!(names, ["profile", "governor", "epp", "turbo", "maxPerfPct", "pl1W", "pl2W"]);
    }
}
