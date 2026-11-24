// Event sink — emits one JSON line per call to stdout.
//
// Locks stdout per emit instead of holding a writer; sidesteps the lifetime
// gymnastics of passing a `&mut Write` into libalpm callbacks (which require
// `'static` closures). Per-emit lock cost is negligible compared to the JSON
// serialization itself.
//
// Each event is wrapped with an ISO8601 timestamp and a monotonically
// increasing counter so consumers can detect dropped lines.

use crate::event::Event;
use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};

#[derive(serde::Serialize)]
struct Wrapper<'a> {
    t: String,
    seq: u64,
    #[serde(flatten)]
    inner: &'a Event,
}

static COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Default)]
pub struct EventSink;

impl EventSink {
    pub fn new<W>(_unused: W) -> Self {
        // The unused parameter exists only so callers can pass a writer
        // for symmetry with the older API; we ignore it and always use
        // stdout. Kept to avoid touching `main.rs` for cosmetic reasons.
        Self
    }

    pub fn emit(&mut self, e: Event) {
        let seq = COUNTER.fetch_add(1, Ordering::SeqCst);
        let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
        let w = Wrapper {
            t: now,
            seq,
            inner: &e,
        };
        let stdout = std::io::stdout();
        let mut out = stdout.lock();
        if let Err(err) = serde_json::to_writer(&mut out, &w) {
            // Best-effort fallback so the host knows something is wrong.
            let _ = writeln!(
                out,
                "{{\"t\":\"\",\"seq\":{seq},\"event\":\"log.error\",\"data\":{{\"msg\":\"event serialization failed: {err}\"}}}}"
            );
            return;
        }
        let _ = writeln!(out);
        let _ = out.flush();
    }

    pub fn next_question_id(&mut self) -> String {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        format!("q{n}")
    }
}
