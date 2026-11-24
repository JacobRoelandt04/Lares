//! What every command runs against, and what it answers.

use crate::plan::{Code, Entry};
use crate::platform::Platform;
use crate::roots::Roots;
use crate::state::State;
use crate::writer::Faults;

pub struct Ctx<'a> {
    pub roots: &'a Roots,
    pub faults: &'a Faults,
    pub platform: &'a dyn Platform,
    pub st: &'a State,
}

/// What a command did: results, a whole-call `why`, the exit code and lines for stderr.
pub struct Outcome {
    pub entries: Vec<Entry>,
    pub why: Option<String>,
    pub code: i32,
    pub notes: Vec<String>,
}

impl Outcome {
    pub fn new(entries: Vec<Entry>, code: i32) -> Outcome {
        Outcome { entries, why: None, code, notes: Vec::new() }
    }

    /// Bad arguments, or a command that is not allowed here: nothing was written (exit 2).
    pub fn usage(why: impl Into<String>) -> Outcome {
        Outcome { entries: Vec::new(), why: Some(why.into()), code: 2, notes: Vec::new() }
    }

    /// The call failed before it could write anything (exit 3).
    pub fn io_before_write(why: impl Into<String>) -> Outcome {
        Outcome { entries: Vec::new(), why: Some(why.into()), code: 3, notes: Vec::new() }
    }

    /// A single result, with the exit code its code implies.
    pub fn one(entry: Entry) -> Outcome {
        let code = match entry.code {
            Code::Ok => 0,
            Code::Io | Code::Mismatch => 1,
            Code::Refused | Code::Absent | Code::Locked => 2,
        };
        Outcome::new(vec![entry], code)
    }
}
