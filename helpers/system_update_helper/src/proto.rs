// Stdin protocol — host responses to question events.
//
// Wire format: one JSON object per line. Required field `id` matching the
// question event's id. The shape of `answer` depends on the question kind:
//
//   yes/no:           {"id": "q3", "answer": "yes"}
//                     {"id": "q3", "answer": "no"}
//   select-provider:  {"id": "q4", "answer": "<chosen-provider>"}
//   import-key:       {"id": "q7", "answer": "yes"}
//   remove-pkgs:      {"id": "q5", "answer": "yes"} → drop unresolvable
//                     {"id": "q5", "answer": "no"}  → abort transaction
//   number-list:      {"id": "q6", "answer": [1, 3, 5]}   (rare in libalpm
//                     event path; AUR-side prompts use it instead)
//
// Cancellation:
//   {"id": "*", "answer": "abort"} aborts the run as soon as it's read.
//
// The helper waits on stdin from the moment it emits a `question.*` event
// until a matching response arrives. While waiting the helper does NOT
// emit further events, so the host doesn't need to buffer state.

// PromptStream is held in main but currently unused inside the run path —
// the libalpm question callbacks ('static lifetime) take ownership of stdin
// via a worker thread instead. Kept here so future non-libalpm flows
// (config negotiation, AUR-specific yes/no) have a ready-made consumer.
#![allow(dead_code)]

use anyhow::{Context, Result};
use serde::Deserialize;
use std::io::{BufRead, BufReader, Read};

#[derive(Deserialize, Debug)]
pub struct Reply {
    pub id: String,
    pub answer: AnswerValue,
}

#[derive(Deserialize, Debug)]
#[serde(untagged)]
pub enum AnswerValue {
    Text(String),
    Numbers(Vec<u32>),
}

impl AnswerValue {
    pub fn as_yes_no(&self) -> Option<bool> {
        match self {
            AnswerValue::Text(s) => match s.to_ascii_lowercase().as_str() {
                "y" | "yes" | "true" | "1" => Some(true),
                "n" | "no" | "false" | "0" => Some(false),
                _ => None,
            },
            _ => None,
        }
    }
    pub fn as_text(&self) -> Option<&str> {
        match self {
            AnswerValue::Text(s) => Some(s.as_str()),
            _ => None,
        }
    }
    pub fn is_abort(&self) -> bool {
        matches!(self.as_text(), Some("abort"))
    }
}

pub struct PromptStream<R: Read> {
    reader: BufReader<R>,
    buf: String,
}

impl<R: Read> PromptStream<R> {
    pub fn new(reader: R) -> Self {
        Self {
            reader: BufReader::new(reader),
            buf: String::new(),
        }
    }

    /// Block until a JSON reply with the matching `id` is read. Returns
    /// the answer payload on match, an error on EOF / parse failure, or
    /// the abort sentinel that callers should treat as "user cancelled".
    pub fn await_reply(&mut self, id: &str) -> Result<AnswerValue> {
        loop {
            self.buf.clear();
            let n = self
                .reader
                .read_line(&mut self.buf)
                .context("reading stdin reply")?;
            if n == 0 {
                anyhow::bail!("stdin closed before reply for {id}");
            }
            let line = self.buf.trim();
            if line.is_empty() {
                continue;
            }
            let reply: Reply = serde_json::from_str(line)
                .with_context(|| format!("parsing reply line: {line}"))?;
            // Wildcard abort: the host can pre-emptively shut us down.
            if reply.id == "*" || reply.id == id {
                if reply.answer.is_abort() {
                    anyhow::bail!("cancelled by host (id={id})");
                }
                return Ok(reply.answer);
            }
            // Reply for a different (presumably stale) question — ignore
            // and keep waiting. Could log this if it becomes an issue.
        }
    }
}
