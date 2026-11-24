//! JSON, by hand: a writer that escapes correctly and a strict reader for the helper's own
//! state files. The reader refuses what it does not understand (exponents, malformed numbers,
//! duplicate keys, lone surrogates, raw control characters, trailing text, deep nesting)
//! instead of guessing. Integers read as `Int`; a number with a fraction (watts) is kept as its
//! text, `Num`, and read exactly by whoever needs it.

use std::fmt::Write as _;

#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Int(i64),
    /// A number already formatted by the caller (watts: `45`, `45.5`).
    Num(String),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

impl Json {
    pub fn str(s: impl Into<String>) -> Json {
        Json::Str(s.into())
    }

    pub fn opt_str(s: Option<&str>) -> Json {
        s.map_or(Json::Null, Json::str)
    }

    pub fn obj<const N: usize>(pairs: [(&str, Json); N]) -> Json {
        Json::Obj(pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
    }

    pub fn strs(items: &[String]) -> Json {
        Json::Arr(items.iter().map(|s| Json::str(s.as_str())).collect())
    }

    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Obj(pairs) => pairs.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Json::Int(i) => Some(*i),
            _ => None,
        }
    }

    pub fn is_null(&self) -> bool {
        matches!(self, Json::Null)
    }

    pub fn render(&self) -> String {
        let mut out = String::new();
        self.write_into(&mut out);
        out
    }

    fn write_into(&self, out: &mut String) {
        match self {
            Json::Null => out.push_str("null"),
            Json::Bool(true) => out.push_str("true"),
            Json::Bool(false) => out.push_str("false"),
            Json::Int(i) => {
                let _ = write!(out, "{i}");
            }
            Json::Num(n) => out.push_str(n),
            Json::Str(s) => escape_into(out, s),
            Json::Arr(items) => {
                out.push('[');
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    item.write_into(out);
                }
                out.push(']');
            }
            Json::Obj(pairs) => {
                out.push('{');
                for (i, (k, v)) in pairs.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    escape_into(out, k);
                    out.push(':');
                    v.write_into(out);
                }
                out.push('}');
            }
        }
    }
}

/// Quote `s` as a JSON string: quotes, backslashes and control characters (and DEL) are
/// escaped, everything else -- non-ASCII included -- passes through as UTF-8.
pub fn escape_into(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if u32::from(c) < 0x20 || c == '\u{7f}' => {
                let _ = write!(out, "\\u{:04x}", u32::from(c));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

const MAX_DEPTH: usize = 12;

/// Parse one JSON document.
pub fn parse(text: &str) -> Result<Json, String> {
    let mut p = Parser { text, b: text.as_bytes(), i: 0 };
    p.ws();
    let v = p.value(0)?;
    p.ws();
    if p.i != p.b.len() {
        return Err(format!("unexpected text after the value at byte {}", p.i));
    }
    Ok(v)
}

struct Parser<'a> {
    text: &'a str,
    b: &'a [u8],
    i: usize,
}

impl Parser<'_> {
    fn peek(&self) -> Option<u8> {
        self.b.get(self.i).copied()
    }

    fn ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.i += 1;
        }
    }

    fn eat(&mut self, c: u8) -> Result<(), String> {
        if self.peek() == Some(c) {
            self.i += 1;
            Ok(())
        } else {
            Err(format!("expected '{}' at byte {}", c as char, self.i))
        }
    }

    fn literal(&mut self, word: &str, v: Json) -> Result<Json, String> {
        if self.b.get(self.i..self.i + word.len()) == Some(word.as_bytes()) {
            self.i += word.len();
            Ok(v)
        } else {
            Err(format!("unexpected token at byte {}", self.i))
        }
    }

    fn value(&mut self, depth: usize) -> Result<Json, String> {
        if depth > MAX_DEPTH {
            return Err("nested too deeply".into());
        }
        match self.peek() {
            Some(b'{') => self.object(depth),
            Some(b'[') => self.array(depth),
            Some(b'"') => Ok(Json::Str(self.string()?)),
            Some(b't') => self.literal("true", Json::Bool(true)),
            Some(b'f') => self.literal("false", Json::Bool(false)),
            Some(b'n') => self.literal("null", Json::Null),
            Some(b'-' | b'0'..=b'9') => self.number(),
            _ => Err(format!("unexpected token at byte {}", self.i)),
        }
    }

    fn number(&mut self) -> Result<Json, String> {
        let start = self.i;
        if self.peek() == Some(b'-') {
            self.i += 1;
        }
        match self.peek() {
            Some(b'0') => self.i += 1,
            Some(b'1'..=b'9') => {
                while matches!(self.peek(), Some(b'0'..=b'9')) {
                    self.i += 1;
                }
            }
            _ => return Err(format!("bad number at byte {start}")),
        }
        if self.peek() == Some(b'.') {
            self.i += 1;
            let frac = self.i;
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.i += 1;
            }
            if self.i == frac || matches!(self.peek(), Some(b'.' | b'e' | b'E')) {
                return Err(format!("bad number at byte {start}"));
            }
            return Ok(Json::Num(self.text.get(start..self.i).unwrap_or("").to_string()));
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            return Err(format!("exponents are not understood (byte {start})"));
        }
        let digits = self.text.get(start..self.i).unwrap_or("");
        digits.parse::<i64>().map(Json::Int).map_err(|_| format!("number out of range at byte {start}"))
    }

    fn hex4(&mut self) -> Result<u32, String> {
        let digits = self.b.get(self.i..self.i + 4).ok_or("short \\u escape")?;
        let mut v = 0u32;
        for d in digits {
            let n = char::from(*d).to_digit(16).ok_or("bad \\u escape")?;
            v = v * 16 + n;
        }
        self.i += 4;
        Ok(v)
    }

    fn string(&mut self) -> Result<String, String> {
        self.eat(b'"')?;
        let mut out = String::new();
        loop {
            let start = self.i;
            while let Some(c) = self.peek() {
                if c == b'"' || c == b'\\' || c < 0x20 {
                    break;
                }
                self.i += 1;
            }
            out.push_str(self.text.get(start..self.i).ok_or("string is not valid UTF-8")?);
            match self.peek() {
                Some(b'"') => {
                    self.i += 1;
                    return Ok(out);
                }
                Some(b'\\') => {
                    self.i += 1;
                    let esc = self.peek().ok_or("unterminated escape")?;
                    self.i += 1;
                    match esc {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let hi = self.hex4()?;
                            let cp = if (0xD800..0xDC00).contains(&hi) {
                                if self.b.get(self.i..self.i + 2) != Some(b"\\u") {
                                    return Err("lone surrogate".into());
                                }
                                self.i += 2;
                                let lo = self.hex4()?;
                                if !(0xDC00..0xE000).contains(&lo) {
                                    return Err("lone surrogate".into());
                                }
                                0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                            } else if (0xDC00..0xE000).contains(&hi) {
                                return Err("lone surrogate".into());
                            } else {
                                hi
                            };
                            out.push(char::from_u32(cp).ok_or("bad code point")?);
                        }
                        _ => return Err("unknown escape".into()),
                    }
                }
                Some(_) => return Err("raw control character in a string".into()),
                None => return Err("unterminated string".into()),
            }
        }
    }

    fn array(&mut self, depth: usize) -> Result<Json, String> {
        self.eat(b'[')?;
        let mut items = Vec::new();
        self.ws();
        if self.peek() == Some(b']') {
            self.i += 1;
            return Ok(Json::Arr(items));
        }
        loop {
            self.ws();
            items.push(self.value(depth + 1)?);
            self.ws();
            match self.peek() {
                Some(b',') => self.i += 1,
                Some(b']') => {
                    self.i += 1;
                    return Ok(Json::Arr(items));
                }
                _ => return Err(format!("expected ',' or ']' at byte {}", self.i)),
            }
        }
    }

    fn object(&mut self, depth: usize) -> Result<Json, String> {
        self.eat(b'{')?;
        let mut pairs: Vec<(String, Json)> = Vec::new();
        self.ws();
        if self.peek() == Some(b'}') {
            self.i += 1;
            return Ok(Json::Obj(pairs));
        }
        loop {
            self.ws();
            let key = self.string()?;
            if pairs.iter().any(|(k, _)| *k == key) {
                return Err(format!("duplicate key '{key}'"));
            }
            self.ws();
            self.eat(b':')?;
            self.ws();
            let v = self.value(depth + 1)?;
            pairs.push((key, v));
            self.ws();
            match self.peek() {
                Some(b',') => self.i += 1,
                Some(b'}') => {
                    self.i += 1;
                    return Ok(Json::Obj(pairs));
                }
                _ => return Err(format!("expected ',' or '}}' at byte {}", self.i)),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn esc(s: &str) -> String {
        let mut out = String::new();
        escape_into(&mut out, s);
        out
    }

    #[test]
    fn escapes_quotes_backslashes_and_controls() {
        assert_eq!(esc("plain"), r#""plain""#);
        assert_eq!(esc("a\"b"), r#""a\"b""#);
        assert_eq!(esc("a\\b"), r#""a\\b""#);
        assert_eq!(esc("l1\nl2\r\t"), r#""l1\nl2\r\t""#);
        assert_eq!(esc("\u{1}\u{1f}\u{7f}"), r#""\u0001\u001f\u007f""#);
        assert_eq!(esc("\u{8}\u{c}"), r#""\b\f""#);
    }

    #[test]
    fn non_ascii_passes_through_as_utf8() {
        assert_eq!(esc("Größe — 電源 🔋"), "\"Größe — 電源 🔋\"");
        assert_eq!(esc("\u{2028}"), "\"\u{2028}\"");
    }

    #[test]
    fn every_control_character_round_trips() {
        let all: String = (0u32..0x80).filter_map(char::from_u32).collect();
        let doc = Json::Str(all.clone()).render();
        assert!(!doc.chars().any(|c| u32::from(c) < 0x20), "no raw control character may be written");
        assert_eq!(parse(&doc), Ok(Json::Str(all)));
    }

    #[test]
    fn writer_shapes() {
        let v = Json::obj([
            ("a", Json::Int(-3)),
            ("b", Json::Arr(vec![Json::Null, Json::Bool(true), Json::Num("45.5".into())])),
            ("c", Json::str("x\"y")),
        ]);
        assert_eq!(v.render(), r#"{"a":-3,"b":[null,true,45.5],"c":"x\"y"}"#);
    }

    #[test]
    fn reader_round_trips_the_writer() {
        let v = Json::obj([
            ("n", Json::Int(1_759_500_000_000)),
            ("s", Json::str("quo\"te \\ nl\n é")),
            ("o", Json::obj([("z", Json::Null), ("t", Json::Bool(false))])),
            ("e", Json::Arr(vec![])),
        ]);
        assert_eq!(parse(&v.render()), Ok(v));
    }

    #[test]
    fn reader_understands_escapes_and_surrogate_pairs() {
        assert_eq!(parse(r#""\u00e9\n\/""#), Ok(Json::str("é\n/")));
        assert_eq!(parse(r#""\ud83d\udd0b""#), Ok(Json::str("🔋")));
    }

    #[test]
    fn reader_refuses_what_it_does_not_understand() {
        for bad in [
            "",
            " ",
            "{",
            "[1,]",
            "{\"a\":1,}",
            "{'a':1}",
            "{\"a\":1}x",
            "{\"a\":1}{\"b\":2}",
            "NaN",
            "1.",
            ".5",
            "1.5.2",
            "1.5e3",
            "1e3",
            "1E3",
            "-",
            "01",
            "99999999999999999999",
            "\"unterminated",
            "\"raw\ttab\"",
            "\"\\ud83d\"",
            "\"\\udd0b\"",
            "\"\\x41\"",
            "{\"a\":1,\"a\":2}",
            "\u{feff}{}",
            "tru",
            "{\"a\" 1}",
        ] {
            assert!(parse(bad).is_err(), "must refuse {bad:?}");
        }
    }

    #[test]
    fn decimals_are_kept_as_their_text() {
        assert_eq!(parse("45.5"), Ok(Json::Num("45.5".into())));
        assert_eq!(parse("-0.25"), Ok(Json::Num("-0.25".into())));
        assert_eq!(parse("[1, 2.50]"), Ok(Json::Arr(vec![Json::Int(1), Json::Num("2.50".into())])));
        assert_eq!(Json::Num("45.5".into()).render(), "45.5");
    }

    #[test]
    fn reader_refuses_a_nesting_bomb_without_overflowing_the_stack() {
        let bomb = "[".repeat(100_000);
        assert!(parse(&bomb).is_err());
        let ok = format!("{}{}", "[".repeat(8), "]".repeat(8));
        assert!(parse(&ok).is_ok());
    }

    #[test]
    fn accessors() {
        let v = parse(r#"{"a":"x","b":7,"c":null}"#).unwrap_or(Json::Null);
        assert_eq!(v.get("a").and_then(Json::as_str), Some("x"));
        assert_eq!(v.get("b").and_then(Json::as_i64), Some(7));
        assert!(v.get("c").is_some_and(Json::is_null));
        assert!(v.get("d").is_none());
    }
}
