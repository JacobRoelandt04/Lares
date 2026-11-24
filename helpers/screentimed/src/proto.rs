//! The wire protocol: line framing (64 KiB cap) and message parsing. Replies are built in `view.rs`.

use serde_json::{json, Value};

pub const MAX_LINE: usize = 64 * 1024;

pub const T_STATE: u8 = 1;
pub const T_FOCUS: u8 = 2;
pub const T_MONITORS: u8 = 4;

/// What a connection's byte stream yielded.
#[derive(Debug, PartialEq, Eq)]
pub enum Line {
    Ok(Vec<u8>),
    /// A line over `MAX_LINE`: dropped (its tail up to the newline is skipped too).
    TooLong,
}

/// Splits a byte stream into lines, never holding more than `MAX_LINE` bytes of one.
#[derive(Default)]
pub struct LineBuf {
    buf: Vec<u8>,
    discarding: bool,
}

impl LineBuf {
    pub fn push(&mut self, data: &[u8]) -> Vec<Line> {
        let mut out = Vec::new();
        let mut rest = data;
        loop {
            match rest.iter().position(|b| *b == b'\n') {
                Some(i) => {
                    let (head, tail) = rest.split_at(i);
                    rest = &tail[1..];
                    if self.discarding {
                        self.discarding = false;
                    } else if self.buf.len() + head.len() > MAX_LINE {
                        self.buf.clear();
                        out.push(Line::TooLong);
                    } else {
                        self.buf.extend_from_slice(head);
                        out.push(Line::Ok(std::mem::take(&mut self.buf)));
                    }
                }
                None => {
                    if !self.discarding {
                        if self.buf.len() + rest.len() > MAX_LINE {
                            self.buf.clear();
                            self.discarding = true;
                            out.push(Line::TooLong);
                        } else {
                            self.buf.extend_from_slice(rest);
                        }
                    }
                    return out;
                }
            }
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum Feed {
    Idle(i64),
    Active,
    Lock(Option<i32>),
    Unlock,
    Sleep,
    Wake,
}

#[derive(Debug, PartialEq)]
pub enum Query {
    State,
    Week(String),
    Day(String),
    Range(String, String),
    Watch(u8, Vec<&'static str>),
}

#[derive(Debug, PartialEq)]
pub enum Msg {
    Feed(Feed),
    Query {
        id: Value,
        q: Query,
    },
    /// A query line that names no known query or lacks a field: answered `badrequest`.
    BadQuery {
        id: Value,
    },
    /// Malformed JSON, not an object, an unknown feed: dropped and counted.
    Bad,
    /// A blank line.
    Blank,
}

/// The accepted topics as a mask and as their names.
pub fn topics(list: &[Value]) -> (u8, Vec<&'static str>) {
    let mut mask = 0;
    let mut names = Vec::new();
    for t in list.iter().filter_map(Value::as_str) {
        let (bit, name) = match t {
            "state" => (T_STATE, "state"),
            "focus" => (T_FOCUS, "focus"),
            "monitors" => (T_MONITORS, "monitors"),
            _ => continue,
        };
        if mask & bit == 0 {
            mask |= bit;
            names.push(name);
        }
    }
    (mask, names)
}

pub fn parse(line: &[u8]) -> Msg {
    if line.iter().all(u8::is_ascii_whitespace) {
        return Msg::Blank;
    }
    let Ok(v) = serde_json::from_slice::<Value>(line) else { return Msg::Bad };
    let Some(o) = v.as_object() else { return Msg::Bad };
    if let Some(f) = o.get("feed").and_then(Value::as_str) {
        let feed = match f {
            "idle" => match o.get("ago").and_then(|a| a.as_i64().or_else(|| a.as_f64().map(|x| x as i64))) {
                Some(a) => Feed::Idle(a.max(0)),
                None => return Msg::Bad,
            },
            "active" => Feed::Active,
            "lock" => Feed::Lock(
                o.get("pid").and_then(Value::as_i64).filter(|p| *p > 0 && *p <= i64::from(i32::MAX)).map(|p| p as i32),
            ),
            "unlock" => Feed::Unlock,
            "sleep" => Feed::Sleep,
            "wake" => Feed::Wake,
            _ => return Msg::Bad,
        };
        return Msg::Feed(feed);
    }
    let Some(q) = o.get("q").and_then(Value::as_str) else { return Msg::Bad };
    let id = o.get("id").cloned().filter(|i| i.is_number() || i.is_string()).unwrap_or(Value::Null);
    if id.is_null() {
        return Msg::BadQuery { id };
    }
    let s = |k: &str| o.get(k).and_then(Value::as_str).map(str::to_string);
    let query = match q {
        "state" => Some(Query::State),
        "week" => s("from").map(Query::Week),
        "day" => s("date").map(Query::Day),
        "range" => s("from").zip(s("to")).map(|(a, b)| Query::Range(a, b)),
        "watch" => o.get("topics").and_then(Value::as_array).map(|t| {
            let (m, n) = topics(t);
            Query::Watch(m, n)
        }),
        _ => None,
    };
    match query {
        Some(q) => Msg::Query { id, q },
        None => Msg::BadQuery { id },
    }
}

pub fn err_reply(id: &Value, word: &str) -> String {
    json!({"v": 1, "id": id, "ok": false, "error": word}).to_string()
}

pub fn ok_reply(id: &Value, key: &str, val: Value) -> String {
    let mut o = serde_json::Map::new();
    o.insert("v".into(), json!(1));
    o.insert("id".into(), id.clone());
    o.insert("ok".into(), json!(true));
    o.insert(key.into(), val);
    Value::Object(o).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(b: &mut LineBuf, s: &[u8]) -> Vec<Line> {
        b.push(s)
    }

    #[test]
    fn framing_splits_and_joins_across_reads() {
        let mut b = LineBuf::default();
        assert_eq!(lines(&mut b, b"{\"a\":1}\n{\"b"), vec![Line::Ok(b"{\"a\":1}".to_vec())]);
        assert_eq!(lines(&mut b, b"\":2}\n\n"), vec![Line::Ok(b"{\"b\":2}".to_vec()), Line::Ok(vec![])]);
    }

    #[test]
    fn a_line_over_64_kib_is_dropped_once_and_the_stream_recovers() {
        let mut b = LineBuf::default();
        let big = vec![b'x'; MAX_LINE + 10];
        let mut got = lines(&mut b, &big);
        got.extend(lines(&mut b, &big));
        got.extend(lines(&mut b, b"tail\n{\"feed\":\"active\"}\n"));
        assert_eq!(got, vec![Line::TooLong, Line::Ok(b"{\"feed\":\"active\"}".to_vec())]);
        // a line of exactly the cap passes
        let mut b = LineBuf::default();
        let mut ok = vec![b'y'; MAX_LINE];
        ok.push(b'\n');
        assert_eq!(lines(&mut b, &ok).len(), 1);
        assert!(matches!(lines(&mut b, &vec![b'z'; MAX_LINE + 1]).first(), Some(Line::TooLong)));
    }

    #[test]
    fn malformed_lines_are_bad_and_unknown_keys_are_ignored() {
        assert_eq!(parse(b"{nope"), Msg::Bad);
        assert_eq!(parse(b"[1,2]"), Msg::Bad);
        assert_eq!(parse(b"{\"feed\":\"dance\"}"), Msg::Bad);
        assert_eq!(parse(b"{\"feed\":\"idle\"}"), Msg::Bad, "idle needs ago");
        assert_eq!(parse(b"  "), Msg::Blank);
        assert_eq!(parse(b"{\"feed\":\"idle\",\"ago\":120,\"extra\":[1],\"x\":null}"), Msg::Feed(Feed::Idle(120)));
        assert_eq!(parse(b"{\"feed\":\"lock\",\"pid\":123}"), Msg::Feed(Feed::Lock(Some(123))));
        assert_eq!(parse(b"{\"feed\":\"lock\"}"), Msg::Feed(Feed::Lock(None)));
        assert_eq!(parse(b"{\"feed\":\"lock\",\"pid\":-4}"), Msg::Feed(Feed::Lock(None)));
    }

    #[test]
    fn queries_carry_an_id_and_unknown_ones_are_badrequest() {
        assert_eq!(parse(b"{\"q\":\"state\",\"id\":1}"), Msg::Query { id: json!(1), q: Query::State });
        assert_eq!(
            parse(b"{\"q\":\"week\",\"from\":\"2026-09-28\",\"id\":\"a\"}"),
            Msg::Query { id: json!("a"), q: Query::Week("2026-09-28".into()) }
        );
        assert_eq!(parse(b"{\"q\":\"week\",\"id\":2}"), Msg::BadQuery { id: json!(2) });
        assert_eq!(parse(b"{\"q\":\"frobnicate\",\"id\":3}"), Msg::BadQuery { id: json!(3) });
        assert_eq!(parse(b"{\"q\":\"state\"}"), Msg::BadQuery { id: Value::Null });
        assert_eq!(
            parse(b"{\"q\":\"watch\",\"topics\":[\"state\",\"nope\",\"focus\",\"state\"],\"id\":5}"),
            Msg::Query { id: json!(5), q: Query::Watch(T_STATE | T_FOCUS, vec!["state", "focus"]) }
        );
    }

    #[test]
    fn replies_echo_the_id() {
        assert_eq!(err_reply(&json!(7), "baddate"), "{\"error\":\"baddate\",\"id\":7,\"ok\":false,\"v\":1}");
        let r: Value = serde_json::from_str(&ok_reply(&json!("x"), "state", json!({"a": 1}))).unwrap();
        assert_eq!((r["id"].as_str(), r["ok"].as_bool(), r["v"].as_i64()), (Some("x"), Some(true), Some(1)));
    }
}
