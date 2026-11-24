//! Shared by the integration tests: a sandbox (a COPY of a fixture tree plus fake /proc, /dev,
//! /usr/lib/modules and a state dir), the helper run as a child process in test mode, a
//! small JSON reader, and tree snapshots that prove what a call did NOT touch.
//!
//! The fixtures themselves are never written to; every test copies one first. The helper
//! refuses its test options as root, so these tests must run as an ordinary user.
#![allow(dead_code)]

use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

pub const BIN: &str = env!("CARGO_BIN_EXE_silicon-helper");
pub const BOOT_A: &str = "aaaaaaaa-0000-4000-8000-000000000001";
pub const BOOT_B: &str = "bbbbbbbb-0000-4000-8000-000000000002";

pub fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

// ---------------------------------------------------------------- json (test side)

#[derive(Debug, Clone, PartialEq)]
pub enum V {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<V>),
    Obj(Vec<(String, V)>),
}

struct P<'a> {
    b: &'a [u8],
    i: usize,
}

impl P<'_> {
    fn ws(&mut self) {
        while self.i < self.b.len() && matches!(self.b[self.i], b' ' | b'\n' | b'\t' | b'\r') {
            self.i += 1;
        }
    }
    fn lit(&mut self, w: &str, v: V) -> V {
        assert!(self.b[self.i..].starts_with(w.as_bytes()), "bad literal at {}", self.i);
        self.i += w.len();
        v
    }
    fn value(&mut self) -> V {
        self.ws();
        match self.b[self.i] {
            b'{' => {
                self.i += 1;
                let mut pairs = Vec::new();
                self.ws();
                if self.b[self.i] == b'}' {
                    self.i += 1;
                    return V::Obj(pairs);
                }
                loop {
                    self.ws();
                    let k = self.string();
                    self.ws();
                    assert_eq!(self.b[self.i], b':');
                    self.i += 1;
                    let v = self.value();
                    pairs.push((k, v));
                    self.ws();
                    match self.b[self.i] {
                        b',' => self.i += 1,
                        b'}' => {
                            self.i += 1;
                            return V::Obj(pairs);
                        }
                        c => panic!("bad object at {}: {}", self.i, c as char),
                    }
                }
            }
            b'[' => {
                self.i += 1;
                let mut items = Vec::new();
                self.ws();
                if self.b[self.i] == b']' {
                    self.i += 1;
                    return V::Arr(items);
                }
                loop {
                    items.push(self.value());
                    self.ws();
                    match self.b[self.i] {
                        b',' => self.i += 1,
                        b']' => {
                            self.i += 1;
                            return V::Arr(items);
                        }
                        c => panic!("bad array at {}: {}", self.i, c as char),
                    }
                }
            }
            b'"' => V::Str(self.string()),
            b't' => self.lit("true", V::Bool(true)),
            b'f' => self.lit("false", V::Bool(false)),
            b'n' => self.lit("null", V::Null),
            _ => {
                let start = self.i;
                while self.i < self.b.len() && matches!(self.b[self.i], b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9')
                {
                    self.i += 1;
                }
                V::Num(std::str::from_utf8(&self.b[start..self.i]).unwrap().parse().unwrap())
            }
        }
    }
    fn string(&mut self) -> String {
        assert_eq!(self.b[self.i], b'"');
        self.i += 1;
        let mut out: Vec<u8> = Vec::new();
        loop {
            let c = self.b[self.i];
            self.i += 1;
            match c {
                b'"' => return String::from_utf8(out).unwrap(),
                b'\\' => {
                    let e = self.b[self.i];
                    self.i += 1;
                    match e {
                        b'n' => out.push(b'\n'),
                        b't' => out.push(b'\t'),
                        b'r' => out.push(b'\r'),
                        b'b' => out.push(8),
                        b'f' => out.push(12),
                        b'u' => {
                            let hex = std::str::from_utf8(&self.b[self.i..self.i + 4]).unwrap();
                            self.i += 4;
                            let ch = char::from_u32(u32::from_str_radix(hex, 16).unwrap()).unwrap();
                            let mut buf = [0u8; 4];
                            out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                        }
                        other => out.push(other),
                    }
                }
                other => out.push(other),
            }
        }
    }
}

impl V {
    pub fn parse(text: &str) -> V {
        let mut p = P { b: text.as_bytes(), i: 0 };
        let v = p.value();
        p.ws();
        assert_eq!(p.i, p.b.len(), "trailing text after the JSON value");
        v
    }

    /// `a.b.0.c`: object keys and array indexes. Panics with the path when it is not there.
    pub fn at(&self, path: &str) -> &V {
        let mut cur = self;
        for part in path.split('.') {
            cur = match cur {
                V::Obj(pairs) => pairs
                    .iter()
                    .find(|(k, _)| k == part)
                    .map(|(_, v)| v)
                    .unwrap_or_else(|| panic!("no key '{part}' in path '{path}'")),
                V::Arr(items) => items
                    .get(part.parse::<usize>().unwrap())
                    .unwrap_or_else(|| panic!("no index '{part}' in path '{path}'")),
                _ => panic!("'{part}' of '{path}' is not inside an object or array"),
            };
        }
        cur
    }

    pub fn has(&self, key: &str) -> bool {
        matches!(self, V::Obj(p) if p.iter().any(|(k, _)| k == key))
    }

    pub fn str(&self) -> &str {
        match self {
            V::Str(s) => s,
            other => panic!("not a string: {other:?}"),
        }
    }
    pub fn num(&self) -> f64 {
        match self {
            V::Num(n) => *n,
            other => panic!("not a number: {other:?}"),
        }
    }
    pub fn bool(&self) -> bool {
        match self {
            V::Bool(b) => *b,
            other => panic!("not a bool: {other:?}"),
        }
    }
    pub fn is_null(&self) -> bool {
        matches!(self, V::Null)
    }
    pub fn arr(&self) -> &[V] {
        match self {
            V::Arr(a) => a,
            other => panic!("not an array: {other:?}"),
        }
    }
    pub fn keys(&self) -> Vec<&str> {
        match self {
            V::Obj(p) => p.iter().map(|(k, _)| k.as_str()).collect(),
            other => panic!("not an object: {other:?}"),
        }
    }
    pub fn strs(&self) -> Vec<&str> {
        self.arr().iter().map(V::str).collect()
    }
}

// ---------------------------------------------------------------- one run of the helper

#[derive(Debug)]
pub struct Run {
    pub code: i32,
    pub json: V,
    pub stdout: String,
    pub stderr: String,
}

impl Run {
    fn from_output(code: i32, stdout: String, stderr: String) -> Run {
        // The wire format: exactly ONE json object, then a newline.
        assert!(stdout.ends_with('\n') && stdout.matches('\n').count() == 1, "stdout must be one line: {stdout:?}");
        let json = V::parse(stdout.trim_end());
        assert!(json.has("ok") && json.at("ok") != &V::Null, "every answer carries ok");
        assert_eq!(json.at("proto").num(), 1.0, "every answer carries proto 1");
        Run { code, json, stdout, stderr }
    }

    pub fn ok(&self) -> bool {
        self.json.at("ok").bool()
    }

    pub fn status(&self) -> &V {
        self.json.at("status")
    }

    pub fn results(&self) -> &[V] {
        self.json.at("results").arr()
    }

    /// The result of the knob `name`; panics if there is none.
    pub fn result(&self, name: &str) -> &V {
        self.results()
            .iter()
            .find(|r| r.at("knob").str() == name)
            .unwrap_or_else(|| panic!("no result for '{name}' in {}", self.stdout))
    }

    pub fn code_of(&self, name: &str) -> &str {
        self.result(name).at("code").str()
    }

    pub fn why(&self) -> String {
        if self.json.has("why") {
            self.json.at("why").str().to_string()
        } else {
            String::new()
        }
    }

    pub fn expect(&self, code: i32) -> &Run {
        assert_eq!(self.code, code, "exit code; stdout: {}\nstderr: {}", self.stdout, self.stderr);
        self
    }
}

/// Wait for a helper to finish, or kill it and FAIL after `secs`: a hung helper must fail a test, never hang the
/// whole run. Polls with a short, growing pause (a helper normally answers in a few milliseconds).
pub fn wait_for(mut child: Child, secs: u64) -> Run {
    let start = Instant::now();
    let mut pause = 1;
    loop {
        match child.try_wait().unwrap() {
            Some(_) => break,
            None if start.elapsed() > Duration::from_secs(secs) => {
                let _ = child.kill();
                let _ = child.wait();
                panic!("the helper did not finish within {secs} s");
            }
            None => {
                std::thread::sleep(Duration::from_millis(pause));
                pause = (pause * 2).min(20);
            }
        }
    }
    let out = child.wait_with_output().unwrap();
    Run::from_output(
        out.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

/// How long a foreground call may take before it is a failure (the slowest legitimate one is about a second).
const CALL_LIMIT_SECS: u64 = 60;

// ---------------------------------------------------------------- snapshots

#[derive(Debug, Clone, PartialEq)]
pub struct Snap(pub BTreeMap<String, String>);

impl Snap {
    /// Paths that differ between two snapshots (changed, added or removed), sorted.
    pub fn diff(&self, after: &Snap) -> Vec<String> {
        let mut changed: Vec<String> = Vec::new();
        for (k, v) in &self.0 {
            if after.0.get(k) != Some(v) {
                changed.push(k.clone());
            }
        }
        for k in after.0.keys() {
            if !self.0.contains_key(k) {
                changed.push(k.clone());
            }
        }
        changed.sort();
        changed.dedup();
        changed
    }
}

fn walk(base: &Path, dir: &Path, out: &mut BTreeMap<String, String>) {
    let mut entries: Vec<_> = fs::read_dir(dir).unwrap().map(|e| e.unwrap()).collect();
    entries.sort_by_key(|e| e.file_name());
    for e in entries {
        let p = e.path();
        let rel = p.strip_prefix(base).unwrap().to_string_lossy().into_owned();
        if rel.ends_with(".lock") {
            continue;
        }
        let ft = e.file_type().unwrap();
        if ft.is_symlink() {
            out.insert(rel, format!("-> {}", fs::read_link(&p).unwrap().display()));
        } else if ft.is_dir() {
            out.insert(rel.clone(), "<dir>".to_string());
            walk(base, &p, out);
        } else {
            let mode = fs::metadata(&p).unwrap().permissions().mode() & 0o777;
            // an unreadable file (cpufv is write-only) is judged by its mode alone
            let text = fs::read(&p)
                .map(|b| String::from_utf8_lossy(&b).into_owned())
                .unwrap_or_else(|_| "<unreadable>".to_string());
            out.insert(rel, format!("{mode:o}:{text}"));
        }
    }
}

// ---------------------------------------------------------------- the sandbox

static COUNTER: AtomicUsize = AtomicUsize::new(0);

fn copy_tree(src: &Path, dst: &Path) {
    fs::create_dir_all(dst).unwrap();
    for e in fs::read_dir(src).unwrap() {
        let e = e.unwrap();
        let (from, to) = (e.path(), dst.join(e.file_name()));
        let ft = e.file_type().unwrap();
        if ft.is_symlink() {
            symlink(fs::read_link(&from).unwrap(), &to).unwrap();
        } else if ft.is_dir() {
            copy_tree(&from, &to);
        } else {
            fs::copy(&from, &to).unwrap();
            fs::set_permissions(&to, fs::Permissions::from_mode(0o644)).unwrap();
        }
    }
}

pub struct Sandbox {
    pub dir: PathBuf,
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

pub fn must_not_be_root() {
    let out = Command::new("id").arg("-u").output().unwrap();
    assert_ne!(
        String::from_utf8_lossy(&out.stdout).trim(),
        "0",
        "these tests must run as an ordinary user: the helper refuses test mode as root"
    );
}

impl Sandbox {
    /// A copy of `tests/fixtures/<fixture>` with fake proc, dev, modules and state around it.
    pub fn new(fixture: &str) -> Sandbox {
        must_not_be_root();
        let dir = std::env::temp_dir().join(format!(
            "silicon-helper-test-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst)
        ));
        fs::create_dir_all(&dir).unwrap();
        let sb = Sandbox { dir };
        let src = fixtures().join(fixture);
        copy_tree(&src.join("sys"), &sb.root().join("sys"));
        if let Ok(modes) = fs::read_to_string(src.join("modes.txt")) {
            for line in modes.lines() {
                if let Some((mode, path)) = line.split_once(' ') {
                    let target = sb.root().join(path.trim_start_matches('/'));
                    if target.is_file() {
                        fs::set_permissions(&target, fs::Permissions::from_mode(u32::from_str_radix(mode, 8).unwrap()))
                            .unwrap();
                    }
                }
            }
        }
        sb.defaults();
        sb
    }

    /// The directory passed as `--sysfs-root` (it contains `sys/`).
    pub fn root(&self) -> PathBuf {
        self.dir.join("root")
    }
    pub fn procroot(&self) -> PathBuf {
        self.dir.join("procroot")
    }
    pub fn devroot(&self) -> PathBuf {
        self.dir.join("devroot")
    }
    pub fn modules(&self) -> PathBuf {
        self.dir.join("modules")
    }
    /// The directory passed as `--run-root` (it contains `run/`): systemd's own view of the units.
    pub fn runroot(&self) -> PathBuf {
        self.dir.join("runroot")
    }
    /// Where systemd exports one `invocation:<unit>` symlink per ACTIVE unit.
    pub fn units(&self) -> PathBuf {
        self.runroot().join("run/systemd/units")
    }
    pub fn state(&self) -> PathBuf {
        self.dir.join("state")
    }
    pub fn reboot_file(&self) -> PathBuf {
        self.dir.join("reboots.log")
    }

    /// `rel` is below `/sys`.
    pub fn sys(&self, rel: &str) -> PathBuf {
        self.root().join("sys").join(rel)
    }
    pub fn proc_(&self, rel: &str) -> PathBuf {
        self.procroot().join("proc").join(rel)
    }
    pub fn dev(&self, rel: &str) -> PathBuf {
        self.devroot().join("dev").join(rel)
    }

    pub fn put(&self, path: &Path, text: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    /// Trimmed text of a file below `/sys`.
    pub fn read(&self, rel: &str) -> String {
        fs::read_to_string(self.sys(rel)).unwrap_or_else(|e| panic!("{rel}: {e}")).trim().to_string()
    }

    pub fn set(&self, rel: &str, text: &str) {
        self.put(&self.sys(rel), &format!("{text}\n"));
    }

    pub fn remove(&self, rel: &str) {
        let p = self.sys(rel);
        match fs::symlink_metadata(&p) {
            Ok(m) if m.is_dir() => fs::remove_dir_all(&p).unwrap(),
            Ok(_) => fs::remove_file(&p).unwrap(),
            Err(e) => panic!("{rel}: {e}"),
        }
    }

    pub fn chmod(&self, rel: &str, mode: u32) {
        fs::set_permissions(self.sys(rel), fs::Permissions::from_mode(mode)).unwrap();
    }

    pub fn state_file(&self, name: &str) -> String {
        fs::read_to_string(self.state().join(name)).unwrap_or_else(|e| panic!("state/{name}: {e}"))
    }

    pub fn state_json(&self, name: &str) -> V {
        V::parse(self.state_file(name).trim_end())
    }

    pub fn has_state(&self, name: &str) -> bool {
        self.state().join(name).exists()
    }

    fn defaults(&self) {
        self.new_boot(BOOT_A);
        self.put(&self.proc_("uptime"), "100.50 400.00\n");
        self.put(
            &self.proc_("modules"),
            "nvidia_uvm 2482176 0 - Live 0x0000000000000000 (OE)\n\
             nvidia_drm 163840 0 - Live 0x0000000000000000 (OE)\n\
             nvidia_modeset 1998848 1 nvidia_drm, Live 0x0000000000000000 (OE)\n\
             nvidia 18722816 2 nvidia_uvm,nvidia_modeset, Live 0x0000000000000000 (OE)\n\
             snd_hda_intel 233472 3 - Live 0x0000000000000000\n",
        );
        self.put(
            &self.proc_("driver/nvidia/gpus/0000:01:00.0/information"),
            "Model: \t NVIDIA GeForce RTX 4060 Laptop GPU\nBus Location: \t 0000:01:00.0\nDevice Minor: \t 0\n",
        );
        for node in [
            "dri/card0",
            "dri/card1",
            "dri/renderD128",
            "dri/renderD129",
            "nvidia0",
            "nvidiactl",
            "nvidia-modeset",
            "nvidia-uvm",
        ] {
            self.put(&self.dev(node), "");
        }
        for kernel in ["6.18.54-1-lts", "7.2.7-arch1-1"] {
            self.put(&self.modules().join(kernel).join("vmlinuz"), "");
            self.put(&self.modules().join(kernel).join("updates/dkms/nvidia.ko.zst"), "");
        }
        fs::create_dir_all(self.state()).unwrap();
        // systemd is running and silicon-mux.service is active: one link per active unit, each to an invocation id
        fs::create_dir_all(self.units()).unwrap();
        symlink("0123456789abcdef0123456789abcdef", self.units().join("invocation:dbus-broker.service")).unwrap();
        self.mux_unit(true);
        // The captures list only `card0` under the dGPU's drm directory; a render node is there on the machine.
        let drm = self.sys("devices/pci0000:00/0000:00:01.0/0000:01:00.0/drm");
        if drm.is_dir() {
            fs::create_dir_all(drm.join("renderD129")).unwrap();
        }
        // The 7.2 capture missed this plain file; the real attribute reads 0 until a change is pending.
        let attrs = self.sys("devices/virtual/firmware-attributes/asus-armoury/attributes");
        if attrs.is_dir() {
            self.put(&attrs.join("pending_reboot"), "0\n");
        }
    }

    /// silicon-mux.service is active (systemd exports its invocation link) or is not (the link is gone).
    pub fn mux_unit(&self, active: bool) {
        let link = self.units().join("invocation:silicon-mux.service");
        let _ = fs::remove_file(&link);
        if active {
            symlink("fedcba9876543210fedcba9876543210", &link).unwrap();
        }
    }

    /// systemd exports nothing at all (another systemd, a container): no unit has an invocation link.
    pub fn systemd_exports_nothing(&self) {
        for e in fs::read_dir(self.units()).unwrap() {
            fs::remove_file(e.unwrap().path()).unwrap();
        }
    }

    /// Time since boot as the fake `/proc/uptime` shows it (replaced atomically: a guard polls it).
    pub fn set_uptime(&self, seconds: &str) {
        let path = self.proc_("uptime");
        let tmp = path.with_extension("tmp");
        fs::write(&tmp, format!("{seconds} 900.00\n")).unwrap();
        fs::rename(&tmp, &path).unwrap();
    }

    pub fn new_boot(&self, id: &str) {
        self.put(&self.proc_("sys/kernel/random/boot_id"), &format!("{id}\n"));
    }

    /// The panel moves to the dGPU (`dgpu`) or back to the iGPU (`hybrid`), as a reboot would do.
    pub fn rewire(&self, to: &str) {
        let (intel, nvidia) = self.edp_connectors();
        let (on, off) = if to == "dgpu" { (&nvidia, &intel) } else { (&intel, &nvidia) };
        self.put(on, "connected\n");
        self.put(off, "disconnected\n");
    }

    pub fn all_edp(&self, status: &str) {
        let (intel, nvidia) = self.edp_connectors();
        self.put(&intel, &format!("{status}\n"));
        self.put(&nvidia, &format!("{status}\n"));
    }

    /// (Intel's eDP `status` file, NVIDIA's), found by vendor.
    fn edp_connectors(&self) -> (PathBuf, PathBuf) {
        let drm = self.sys("class/drm");
        let (mut intel, mut nvidia) = (None, None);
        for e in fs::read_dir(&drm).unwrap() {
            let name = e.unwrap().file_name().to_string_lossy().into_owned();
            let Some((card, conn)) = name.split_once('-') else { continue };
            if !conn.starts_with("eDP-") {
                continue;
            }
            let vendor = fs::read_to_string(drm.join(card).join("device/vendor")).unwrap();
            let status = drm.join(&name).join("status");
            if vendor.trim() == "0x8086" {
                intel = Some(status);
            } else {
                nvidia = Some(status);
            }
        }
        (intel.expect("an Intel eDP connector"), nvidia.expect("an NVIDIA eDP connector"))
    }

    pub fn snapshot(&self) -> Snap {
        let mut out = BTreeMap::new();
        walk(&self.dir, &self.dir, &mut out);
        Snap(out)
    }

    /// The test options that make the helper look at this sandbox.
    pub fn opts(&self) -> Vec<String> {
        let mut o = self.opts_without_run_root();
        o.extend(["--run-root".to_string(), self.runroot().display().to_string()]);
        o
    }

    /// The same without `--run-root`: what a probe written before that option existed passes.
    pub fn opts_without_run_root(&self) -> Vec<String> {
        vec![
            "--sysfs-root".into(),
            self.root().display().to_string(),
            "--proc-root".into(),
            self.procroot().display().to_string(),
            "--state-dir".into(),
            self.state().display().to_string(),
            "--dev-root".into(),
            self.devroot().display().to_string(),
            "--modules-root".into(),
            self.modules().display().to_string(),
        ]
    }

    pub fn command(&self, args: &[&str], env: &[(&str, &str)]) -> Command {
        let mut cmd = Command::new(BIN);
        cmd.args(self.opts()).args(args).env_clear().envs(env.iter().copied());
        cmd
    }

    pub fn run(&self, args: &[&str]) -> Run {
        self.run_env(args, &[])
    }

    pub fn run_env(&self, args: &[&str], env: &[(&str, &str)]) -> Run {
        wait_for(self.spawn(args, env), CALL_LIMIT_SECS)
    }

    /// The helper with exactly these arguments (no sandbox options added).
    pub fn run_raw(&self, args: &[&str], env: &[(&str, &str)]) -> Run {
        let child = Command::new(BIN)
            .args(args)
            .env_clear()
            .envs(env.iter().copied())
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        wait_for(child, CALL_LIMIT_SECS)
    }

    pub fn spawn(&self, args: &[&str], env: &[(&str, &str)]) -> Child {
        self.command(args, env).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap()
    }

    pub fn status(&self) -> Run {
        self.run(&["status"])
    }

    /// `boot-apply`, expected to land everything.
    pub fn boot_apply(&self) -> Run {
        let r = self.run(&["boot-apply"]);
        assert_eq!(r.code, 0, "boot-apply: {}\n{}", r.stdout, r.stderr);
        r
    }

    /// The firmware's limits are on record for this boot (a `boot-apply` ran).
    pub fn with_caps(self) -> Sandbox {
        self.boot_apply();
        self
    }
}

/// Assert that nothing under the sandbox changed between two snapshots.
pub fn assert_untouched(before: &Snap, after: &Snap) {
    let changed = before.diff(after);
    assert!(changed.is_empty(), "a refused call must write nothing, but these changed: {changed:#?}");
}
