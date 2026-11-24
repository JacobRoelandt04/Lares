//! silicon-helper: the root helper of the silicon module. Std only. It writes a handful of
//! power knobs (CPU profile, EPP, turbo, governor, max_perf_pct, RAPL caps, battery charge
//! limit, GPU MUX) after validating every value against the kernel's own lists and ranges,
//! reads each write back, and answers with one JSON object (HELPER_PROTOCOL.md v1).
//!
//! Every unwrap, index and panic is a decision: the lints below make them build errors.
#![cfg_attr(not(test), deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::indexing_slicing))]

#[cfg(test)]
mod audit;
mod boost;
mod cli;
mod commands;
mod ctx;
mod fsx;
mod gpu;
mod json;
mod knobs;
mod machine;
mod mux;
mod plan;
mod platform;
mod report;
mod roots;
mod state;
mod sys;
mod whitelist;
mod wifi;
mod writer;

use std::io::Write;

fn main() {
    let args: Result<Vec<String>, _> = std::env::args_os().skip(1).map(|a| a.into_string()).collect();
    let out = match args {
        Err(_) => cli::bare("an argument is not valid UTF-8", 2),
        Ok(args) => {
            let env = cli::Env::from_process();
            let euid = sys::effective_uid();
            std::panic::catch_unwind(|| cli::run(&args, &env, euid)).unwrap_or_else(|_| {
                cli::bare("internal error: the helper panicked (see stderr); nothing further was done", 1)
            })
        }
    };
    let mut stdout = std::io::stdout().lock();
    let _ = stdout.write_all(out.json.as_bytes());
    let _ = stdout.write_all(b"\n");
    let _ = stdout.flush();
    let mut stderr = std::io::stderr().lock();
    for line in &out.stderr {
        let _ = writeln!(stderr, "silicon-helper: {line}");
    }
    std::process::exit(out.code);
}
