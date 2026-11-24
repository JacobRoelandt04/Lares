//! The interaction boost's server (`boost-serve`), run as a child in test mode on a copy of the laptop's sysfs
//! (n6506mv_72: an i915 card1 driving the eDP, the NVIDIA card0 beside it) with the GPU's frequency files added:
//! raise, extend, put back on the timer, on the asking connection's close, on SIGTERM, a stale record at start and
//! by `boost-restore`, a foreign change left standing, a refused peer, a refused verb, the bounds.

mod common;

use common::*;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant};

const GPU: &str = "devices/pci0000:00/0000:00:02.0/drm/card1/gt/gt0/rps_min_freq_mhz";
const CPU: &str = "devices/system/cpu/intel_pstate/min_perf_pct";

fn my_uid() -> u32 {
    fs::metadata("/proc/self").unwrap().uid()
}

fn world() -> Sandbox {
    let sb = Sandbox::new("n6506mv_72");
    let gt = "devices/pci0000:00/0000:00:02.0/drm/card1/gt/gt0";
    sb.set(&format!("{gt}/rps_min_freq_mhz"), "100");
    sb.set(&format!("{gt}/rps_RPn_freq_mhz"), "800");
    sb.set(&format!("{gt}/rps_max_freq_mhz"), "2350");
    sb.set(CPU, "8");
    fs::create_dir_all(sb.runroot().join("run")).unwrap();
    sb
}

fn boost_dir(sb: &Sandbox) -> PathBuf {
    sb.runroot().join("run/lares-boost")
}

fn sock(sb: &Sandbox) -> PathBuf {
    boost_dir(sb).join("sock")
}

fn floors(sb: &Sandbox) -> (String, String) {
    (sb.read(GPU), sb.read(CPU))
}

fn rested() -> (String, String) {
    ("100".into(), "8".into())
}

fn raised() -> (String, String) {
    ("1600".into(), "30".into())
}

fn serve(sb: &Sandbox, uid: u32) -> Child {
    let child = Command::new(BIN)
        .args(["boost-serve", &format!("uid={uid}"), "gpuMhz=1600", "cpuPct=30"])
        .arg("--sysfs-root")
        .arg(sb.root())
        .arg("--run-root")
        .arg(sb.runroot())
        .env_remove("PKEXEC_UID")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let t0 = Instant::now();
    while !sock(sb).exists() {
        assert!(t0.elapsed() < Duration::from_secs(5), "the socket never appeared");
        sleep(Duration::from_millis(10));
    }
    sleep(Duration::from_millis(20)); // bound before it exists, owned right after: let it finish
    child
}

fn stop(mut child: Child) -> (i32, String) {
    let pid = child.id().to_string();
    Command::new("kill").args(["-TERM", &pid]).status().unwrap();
    let t0 = Instant::now();
    loop {
        if let Some(st) = child.try_wait().unwrap() {
            let mut err = String::new();
            std::io::Read::read_to_string(child.stderr.as_mut().unwrap(), &mut err).unwrap();
            return (st.code().unwrap_or(-1), err);
        }
        assert!(t0.elapsed() < Duration::from_secs(5), "boost-serve did not stop on SIGTERM");
        sleep(Duration::from_millis(10));
    }
}

struct Conn {
    w: UnixStream,
    r: BufReader<UnixStream>,
}

impl Conn {
    fn open(sb: &Sandbox) -> Conn {
        let w = UnixStream::connect(sock(sb)).unwrap();
        w.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        let r = BufReader::new(w.try_clone().unwrap());
        Conn { w, r }
    }
    fn ask(&mut self, line: &str) -> String {
        self.w.write_all(format!("{line}\n").as_bytes()).unwrap();
        let mut reply = String::new();
        self.r.read_line(&mut reply).unwrap();
        reply.trim_end().to_string()
    }
    fn closed(&mut self) -> bool {
        let mut rest = String::new();
        matches!(self.r.read_line(&mut rest), Ok(0))
    }
}

fn wait_until(what: &str, secs: u64, f: impl Fn() -> bool) {
    let t0 = Instant::now();
    while !f() {
        assert!(t0.elapsed() < Duration::from_secs(secs), "timed out: {what}");
        sleep(Duration::from_millis(10));
    }
}

fn left(reply: &str) -> u64 {
    reply.strip_prefix("ok ").unwrap_or_else(|| panic!("not ok: {reply}")).parse().unwrap()
}

#[test]
fn raise_extend_and_put_back_on_the_timer() {
    let sb = world();
    let child = serve(&sb, my_uid());
    let mode = fs::metadata(sock(&sb)).unwrap();
    assert_eq!(mode.permissions().mode() & 0o777, 0o600, "the socket is the session user's alone");
    assert_eq!(mode.uid(), my_uid(), "(a test run keeps it; the real one hands it to uid=)");
    let mut c = Conn::open(&sb);
    let t0 = Instant::now();
    let l = left(&c.ask("boost 300"));
    assert!((250..=300).contains(&l), "{l}");
    assert_eq!(floors(&sb), raised());
    assert!(boost_dir(&sb).join("record.json").exists(), "the record is written before the raise");
    sleep(Duration::from_millis(100));
    let l = left(&c.ask("boost 600"));
    assert!((500..=600).contains(&l), "an ask while raised extends: {l}");
    let l = left(&c.ask("boost 50"));
    assert!(l > 400, "a shorter ask never shortens: {l}");
    sleep(Duration::from_millis(350));
    assert_eq!(floors(&sb), raised(), "still inside the extended deadline ({:?})", t0.elapsed());
    wait_until("the floors come back down", 3, || floors(&sb) == rested());
    assert!(t0.elapsed() >= Duration::from_millis(650), "not before the deadline: {:?}", t0.elapsed());
    assert!(!boost_dir(&sb).join("record.json").exists());
    // and up again on the next ask, on the same connection
    left(&c.ask("boost 200"));
    assert_eq!(floors(&sb), raised());
    drop(c);
    let (code, err) = stop(child);
    assert_eq!(code, 0, "{err}");
    assert_eq!(floors(&sb), rested());
    assert!(!sock(&sb).exists(), "the socket goes with the server");
}

#[test]
fn the_asking_connection_closing_puts_everything_back() {
    let sb = world();
    let child = serve(&sb, my_uid());
    let mut c = Conn::open(&sb);
    left(&c.ask("boost 2000"));
    assert_eq!(floors(&sb), raised());
    let t0 = Instant::now();
    drop(c);
    wait_until("put back at the close", 2, || floors(&sb) == rested());
    assert!(t0.elapsed() < Duration::from_millis(1000), "at the close, not the deadline: {:?}", t0.elapsed());
    stop(child);
}

#[test]
fn sigterm_puts_everything_back() {
    let sb = world();
    let child = serve(&sb, my_uid());
    let mut c = Conn::open(&sb);
    left(&c.ask("boost 2000"));
    assert_eq!(floors(&sb), raised());
    let (code, err) = stop(child);
    assert_eq!(code, 0, "{err}");
    assert_eq!(floors(&sb), rested(), "{err}");
    assert!(err.contains("every floor put back"), "{err}");
    assert!(c.closed());
}

#[test]
fn a_foreign_change_is_left_as_it_is() {
    let sb = world();
    let child = serve(&sb, my_uid());
    let mut c = Conn::open(&sb);
    left(&c.ask("boost 2000"));
    sb.set(CPU, "50"); // powertop's --auto-tune, or the user
    drop(c);
    wait_until("the GPU put back", 2, || sb.read(GPU) == "100");
    assert_eq!(sb.read(CPU), "50", "another writer's value stands");
    let (_, err) = stop(child);
    assert!(err.contains("someone else changed it"), "{err}");
}

#[test]
fn a_stale_record_is_put_back_at_start_and_by_boost_restore() {
    for verb in ["serve", "restore"] {
        let sb = world();
        sb.set(GPU, "1600");
        sb.set(CPU, "30");
        fs::create_dir_all(boost_dir(&sb)).unwrap();
        let rec = format!(
            "{{\"proto\":1,\"floors\":[{{\"which\":\"gpu\",\"path\":\"{}\",\"before\":\"100\",\"ours\":\"1600\"}},{{\"which\":\"cpu\",\"path\":\"{}\",\"before\":\"8\",\"ours\":\"30\"}}]}}\n",
            sb.sys(GPU).display(),
            sb.sys(CPU).display()
        );
        fs::write(boost_dir(&sb).join("record.json"), rec).unwrap();
        if verb == "serve" {
            let child = serve(&sb, my_uid());
            assert_eq!(floors(&sb), rested(), "put back before the socket is up");
            stop(child);
        } else {
            let out = Command::new(BIN)
                .arg("boost-restore")
                .arg("--sysfs-root")
                .arg(sb.root())
                .arg("--run-root")
                .arg(sb.runroot())
                .output()
                .unwrap();
            assert_eq!(out.status.code(), Some(0), "{}", String::from_utf8_lossy(&out.stdout));
            assert_eq!(floors(&sb), rested());
        }
        assert!(!boost_dir(&sb).join("record.json").exists(), "{verb}");
    }
}

#[test]
fn a_peer_that_is_not_the_session_user_is_refused() {
    let sb = world();
    let child = serve(&sb, my_uid() + 1);
    let mut c = Conn::open(&sb); // the test owns the socket file's directory; the peer check is what refuses
    let mut reply = String::new();
    c.r.read_line(&mut reply).unwrap();
    assert_eq!(reply.trim_end(), "refused not the session user");
    assert!(c.closed());
    assert_eq!(floors(&sb), rested());
    stop(child);
}

#[test]
fn a_verb_other_than_boost_is_refused_and_closes_and_the_bounds_hold() {
    let sb = world();
    let child = serve(&sb, my_uid());
    let mut c = Conn::open(&sb);
    assert!(c.ask("boost 10").starts_with("refused 10 ms is outside 50..=2000"));
    assert!(c.ask("boost 2001").starts_with("refused"));
    assert_eq!(floors(&sb), rested(), "out of bounds raises nothing");
    left(&c.ask("boost 100")); // the connection stayed
    assert!(c.ask("write /sys/devices/system/cpu/intel_pstate/max_perf_pct 1").starts_with("refused the only verb"));
    assert!(c.closed(), "an unknown verb closes the connection");
    let mut d = Conn::open(&sb);
    d.w.write_all(&[b'b'; 100]).unwrap();
    let mut reply = String::new();
    d.r.read_line(&mut reply).unwrap();
    assert!(reply.starts_with("refused a line is at most 64 bytes"), "{reply}");
    assert!(d.closed());
    stop(child);
    assert_eq!(sb.read("devices/system/cpu/intel_pstate/max_perf_pct"), "100");
}

#[test]
fn boost_serve_is_systemds_alone() {
    let sb = world();
    let plain = Command::new(BIN).args(["boost-serve", "uid=1000"]).env_remove("PKEXEC_UID").output().unwrap();
    assert_eq!(plain.status.code(), Some(2), "not run as a plain user without the test options");
    let pk = Command::new(BIN)
        .args(["boost-serve", "uid=1000", "--sysfs-root"])
        .arg(sb.root())
        .arg("--run-root")
        .arg(sb.runroot())
        .env("PKEXEC_UID", "1000")
        .output()
        .unwrap();
    assert_eq!(pk.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&pk.stdout).contains("systemd only"));
    let no_run = Command::new(BIN).args(["boost-serve", "uid=1000", "--sysfs-root"]).arg(sb.root()).output().unwrap();
    assert_eq!(no_run.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&no_run.stdout).contains("--run-root"));
    let bad = Command::new(BIN)
        .args(["boost-serve", "uid=1000", "cpuPct=90", "--sysfs-root"])
        .arg(sb.root())
        .arg("--run-root")
        .arg(sb.runroot())
        .output()
        .unwrap();
    assert_eq!(bad.status.code(), Some(2));
    let caps = Command::new(BIN).arg("capabilities").output().unwrap();
    assert!(String::from_utf8_lossy(&caps.stdout).contains("\"boost-serve\""));
}
