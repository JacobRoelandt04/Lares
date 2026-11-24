//! Hyprland's two sockets: socket2 (the event stream) and socket1 (one request, one reply, closed).
//!
//! The daemon acts on five events (`activewindowv2`, `windowtitlev2`, `focusedmon`, `monitoradded`,
//! `monitorremoved`) and reads the class from socket1's `j/activewindow`, because a class may contain
//! a comma and the `activewindow` / `openwindow` lines cannot be split. A window TITLE is dropped the
//! moment the line or the reply is parsed: it is never stored, logged or sent. `windowtitlev2` is only
//! the signal that a terminal may have a new program in front (kitty retitles on every command).

use serde_json::Value;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Debug, PartialEq, Eq)]
pub enum Ev {
    /// `activewindowv2>>ADDR` (the address; empty = no window focused).
    ActiveV2(String),
    /// `windowtitlev2>>ADDR,TITLE`: the window's address only.
    TitleV2(String),
    FocusedMon(String),
    MonitorAdded(String),
    MonitorRemoved(String),
    Other,
}

pub fn parse_event(line: &str) -> Ev {
    let Some((name, data)) = line.split_once(">>") else { return Ev::Other };
    match name {
        "activewindowv2" => Ev::ActiveV2(data.trim().to_string()),
        "windowtitlev2" => Ev::TitleV2(data.split(',').next().unwrap_or("").trim().to_string()),
        // `focusedmon>>NAME,WORKSPACE`: a monitor name has no comma, a workspace name may.
        "focusedmon" => Ev::FocusedMon(data.split(',').next().unwrap_or("").to_string()),
        "monitoradded" => Ev::MonitorAdded(data.to_string()),
        "monitorremoved" => Ev::MonitorRemoved(data.to_string()),
        _ => Ev::Other,
    }
}

/// The class out of a `j/activewindow` reply. Outer None: not a reply we understand. Inner None:
/// nothing is focused (`{}`).
pub fn parse_activewindow(b: &[u8]) -> Option<Option<String>> {
    let v: Value = serde_json::from_slice(b).ok()?;
    let o = v.as_object()?;
    let Some(class) = o.get("class").and_then(Value::as_str) else { return Some(None) };
    if cfg!(feature = "arm-title") {
        // ARM: the title leaks into the app name (and so into every day file).
        let title = o.get("title").and_then(Value::as_str).unwrap_or("");
        return Some(Some(format!("{class} {title}")));
    }
    Some(Some(class.to_string()))
}

/// The focused window's process id out of a `j/activewindow` reply.
pub fn parse_activewindow_pid(b: &[u8]) -> Option<i32> {
    let v: Value = serde_json::from_slice(b).ok()?;
    v.get("pid").and_then(Value::as_i64).filter(|p| *p > 0).and_then(|p| i32::try_from(p).ok())
}

/// The focused monitor's name and every monitor's name out of `j/monitors`.
pub fn parse_monitors(b: &[u8]) -> Option<(String, Vec<String>)> {
    let v: Value = serde_json::from_slice(b).ok()?;
    let a = v.as_array()?;
    let names: Vec<String> =
        a.iter().filter_map(|m| m.get("name").and_then(Value::as_str).map(str::to_string)).collect();
    let focused = a
        .iter()
        .find(|m| m.get("focused").and_then(Value::as_bool) == Some(true))
        .and_then(|m| m.get("name").and_then(Value::as_str).map(str::to_string))
        .or_else(|| names.first().cloned())
        .unwrap_or_else(|| "?".to_string());
    Some((focused, names))
}

/// One socket1 request: connect, write, read to EOF. Bounded by short timeouts, so a wedged
/// compositor cannot wedge this daemon.
pub fn request(dir: &Path, cmd: &str) -> std::io::Result<Vec<u8>> {
    let mut s = UnixStream::connect(dir.join(".socket.sock"))?;
    s.set_read_timeout(Some(Duration::from_millis(400)))?;
    s.set_write_timeout(Some(Duration::from_millis(400)))?;
    s.write_all(cmd.as_bytes())?;
    let mut out = Vec::new();
    s.take(1 << 20).read_to_end(&mut out)?;
    Ok(out)
}

/// Instance directories under `root` (`$XDG_RUNTIME_DIR/hypr`), the newest `hyprland.lock` first.
pub fn instances(root: &Path) -> Vec<PathBuf> {
    let Ok(rd) = std::fs::read_dir(root) else { return Vec::new() };
    let mut v: Vec<(std::time::SystemTime, PathBuf)> = rd
        .flatten()
        .filter(|e| e.path().is_dir())
        .map(|e| {
            let p = e.path();
            let m = std::fs::metadata(p.join("hyprland.lock"))
                .or_else(|_| std::fs::metadata(&p))
                .and_then(|m| m.modified());
            (m.unwrap_or(std::time::UNIX_EPOCH), p)
        })
        .collect();
    v.sort_by(|a, b| b.0.cmp(&a.0));
    v.into_iter().map(|(_, p)| p).collect()
}

/// Connects the event socket of an instance (nonblocking afterwards).
pub fn connect_events(dir: &Path) -> std::io::Result<UnixStream> {
    let s = UnixStream::connect(dir.join(".socket2.sock"))?;
    s.set_nonblocking(true)?;
    Ok(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn events_are_parsed_by_name_and_class_commas_never_matter() {
        assert_eq!(parse_event("activewindowv2>>0x55d0c0a0"), Ev::ActiveV2("0x55d0c0a0".into()));
        assert_eq!(parse_event("activewindowv2>>"), Ev::ActiveV2(String::new()));
        assert_eq!(parse_event("windowtitlev2>>55c1b1f3aaa0,~/a, b: c"), Ev::TitleV2("55c1b1f3aaa0".into()));
        assert_eq!(parse_activewindow_pid(br#"{"class":"kitty","pid":2205}"#), Some(2205));
        assert_eq!(parse_activewindow_pid(b"{}"), None);
        assert_eq!(parse_event("focusedmon>>LOCK-2,2"), Ev::FocusedMon("LOCK-2".into()));
        assert_eq!(parse_event("focusedmon>>DP-1,a,b"), Ev::FocusedMon("DP-1".into()));
        assert_eq!(parse_event("monitoradded>>DP-2"), Ev::MonitorAdded("DP-2".into()));
        assert_eq!(parse_event("monitorremoved>>DP-2"), Ev::MonitorRemoved("DP-2".into()));
        // activewindow and openwindow carry a class with a comma: never acted on.
        assert_eq!(parse_event("activewindow>>st,comma,sleep"), Ev::Other);
        assert_eq!(parse_event("openwindow>>ADDR,1,st,comma,kitty"), Ev::Other);
        assert_eq!(parse_event("garbage"), Ev::Other);
    }

    #[test]
    fn activewindow_reply_gives_the_class_and_drops_the_title() {
        let r = br#"{"address":"0x1","class":"st,comma","title":"SECRET-TITLE","monitor":0}"#;
        if !cfg!(feature = "arm-title") {
            assert_eq!(parse_activewindow(r), Some(Some("st,comma".into())));
        }
        assert_eq!(parse_activewindow(b"{}"), Some(None));
        assert_eq!(parse_activewindow(b"Invalid"), None);
    }

    #[test]
    fn monitors_reply_names_the_focused_one() {
        let r = br#"[{"id":0,"name":"eDP-1","focused":false},{"id":1,"name":"DP-3","focused":true}]"#;
        assert_eq!(parse_monitors(r), Some(("DP-3".into(), vec!["eDP-1".into(), "DP-3".into()])));
        assert_eq!(parse_monitors(b"[]"), Some(("?".into(), vec![])));
    }
}
