//! The client side: `ctl` (a hook's feed: never waits, always exits 0), `lock-run` (feed, then exec the
//! locker so the pid IS the locker's) and `query`.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const SEND_BUDGET: Duration = Duration::from_millis(100);

/// The default socket: `$XDG_RUNTIME_DIR/screentime/screentimed.sock`.
pub fn default_socket() -> PathBuf {
    let rt = std::env::var_os("XDG_RUNTIME_DIR").map_or_else(|| PathBuf::from("/run/user/0"), PathBuf::from);
    rt.join("screentime").join("screentimed.sock")
}

/// Connects and writes one line without ever blocking longer than 100 ms in total. Returns the stream
/// (so a caller may linger) or None when the daemon is absent, stopped with a full queue, or too slow.
fn send(sock: &Path, line: &str) -> Option<std::os::fd::OwnedFd> {
    use std::os::fd::{FromRawFd, OwnedFd};
    let path = sock.as_os_str().as_encoded_bytes();
    // SAFETY: plain socket calls on a fresh descriptor owned by `fd`.
    unsafe {
        let raw = libc::socket(libc::AF_UNIX, libc::SOCK_STREAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC, 0);
        if raw < 0 {
            return None;
        }
        let fd = OwnedFd::from_raw_fd(raw);
        let mut addr: libc::sockaddr_un = std::mem::zeroed();
        addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
        if path.len() >= addr.sun_path.len() {
            return None;
        }
        for (i, b) in path.iter().enumerate() {
            addr.sun_path[i] = *b as libc::c_char;
        }
        let t0 = Instant::now();
        loop {
            let r = libc::connect(
                std::os::fd::AsRawFd::as_raw_fd(&fd),
                (&addr as *const libc::sockaddr_un).cast(),
                std::mem::size_of::<libc::sockaddr_un>() as libc::socklen_t,
            );
            if r == 0 {
                break;
            }
            // A full listen queue (a stopped daemon) answers EAGAIN: retry until the budget is gone.
            if std::io::Error::last_os_error().raw_os_error() != Some(libc::EAGAIN) || t0.elapsed() >= SEND_BUDGET {
                return None;
            }
            std::thread::sleep(Duration::from_millis(3));
        }
        let bytes = format!("{line}\n");
        let n =
            libc::send(std::os::fd::AsRawFd::as_raw_fd(&fd), bytes.as_ptr().cast(), bytes.len(), libc::MSG_NOSIGNAL);
        if n as usize != bytes.len() {
            return None;
        }
        Some(fd)
    }
}

/// `ctl <feed>`: never fails, never waits.
pub fn ctl(sock: &Path, args: &[String]) -> i32 {
    let line = match args.first().map(String::as_str) {
        Some("idle") => match args.get(1).and_then(|a| a.parse::<i64>().ok()) {
            Some(a) => json!({"feed": "idle", "ago": a}),
            None => return 0,
        },
        Some("active") => json!({"feed": "active"}),
        Some("lock") => {
            let pid = args
                .iter()
                .position(|a| a == "--pid")
                .and_then(|i| args.get(i + 1))
                .and_then(|p| p.parse::<i64>().ok());
            match pid {
                Some(p) => json!({"feed": "lock", "pid": p}),
                None => json!({"feed": "lock"}),
            }
        }
        Some("unlock") => json!({"feed": "unlock"}),
        Some("sleep") => json!({"feed": "sleep"}),
        Some("wake") => json!({"feed": "wake"}),
        _ => return 0,
    };
    let fd = send(sock, &line.to_string());
    if cfg!(feature = "arm-ctlwait") {
        // ARM: wait for a reply nobody sends (up to a second). A stopped daemon makes this late.
        if let Some(fd) = &fd {
            let mut p = libc::pollfd { fd: std::os::fd::AsRawFd::as_raw_fd(fd), events: libc::POLLIN, revents: 0 };
            // SAFETY: one valid pollfd.
            unsafe { libc::poll(&mut p, 1, 1000) };
        }
    }
    0
}

/// `lock-run <cmd> [args...]`: tell the daemon this pid is the locker, then become the locker.
pub fn lock_run(sock: &Path, cmd: &[String]) -> i32 {
    let Some((prog, rest)) = cmd.split_first() else {
        eprintln!("screentimed lock-run: no command");
        return 127;
    };
    let _ = send(sock, &json!({"feed": "lock", "pid": std::process::id()}).to_string());
    let err = std::process::Command::new(prog).args(rest).exec();
    eprintln!("screentimed lock-run: {prog}: {err}");
    127
}

/// `query ...`: prints the reply line. 0 on ok, 1 otherwise, 2 when the daemon is unreachable.
pub fn query(sock: &Path, args: &[String]) -> i32 {
    let id = 1;
    let q = match args.first().map(String::as_str) {
        Some("state") => json!({"q": "state", "id": id}),
        Some("week") if args.len() >= 2 => json!({"q": "week", "from": args[1], "id": id}),
        Some("day") if args.len() >= 2 => json!({"q": "day", "date": args[1], "id": id}),
        Some("range") if args.len() >= 3 => json!({"q": "range", "from": args[1], "to": args[2], "id": id}),
        _ => {
            eprintln!("usage: screentimed query state | week <date> | day <date> | range <from> <to>");
            return 1;
        }
    };
    let Ok(mut s) = UnixStream::connect(sock) else { return 2 };
    let _ = s.set_read_timeout(Some(Duration::from_secs(3)));
    let _ = s.set_write_timeout(Some(Duration::from_secs(3)));
    if writeln!(s, "{q}").is_err() {
        return 2;
    }
    let mut r = BufReader::new(s);
    loop {
        let mut line = String::new();
        match r.read_line(&mut line) {
            Ok(0) | Err(_) => return 2,
            Ok(_) => {}
        }
        let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
        if v.get("id") == Some(&json!(id)) {
            print!("{line}");
            let _ = std::io::stdout().flush();
            return i32::from(v.get("ok") != Some(&json!(true)));
        }
    }
}
