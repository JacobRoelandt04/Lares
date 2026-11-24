//! The only `unsafe` in the helper, and the platform constants it needs. std has no
//! effective-uid accessor and no `O_NOFOLLOW`, and a dependency is not worth either. The
//! interaction boost's server (`boost.rs`) adds three more calls std does not have on a stable
//! toolchain: the peer's credentials of a unix socket (`SO_PEERCRED`), poll(2), and a SIGTERM /
//! SIGINT handler that only sets a flag.

use std::os::fd::RawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

extern "C" {
    fn geteuid() -> u32;
    fn getsockopt(fd: i32, level: i32, name: i32, value: *mut Ucred, len: *mut u32) -> i32;
    fn poll(fds: *mut PollFd, nfds: u64, timeout: i32) -> i32;
    fn signal(sig: i32, handler: usize) -> usize;
}

/// The effective user id of this process.
pub fn effective_uid() -> u32 {
    // SAFETY: geteuid(2) takes no arguments, touches no memory and cannot fail.
    unsafe { geteuid() }
}

/// `struct ucred` of <sys/socket.h>.
#[repr(C)]
#[derive(Default)]
struct Ucred {
    pid: i32,
    uid: u32,
    gid: u32,
}

const SOL_SOCKET: i32 = 1;
const SO_PEERCRED: i32 = 17;

/// The uid of the process at the other end of a connected unix socket, as the kernel recorded it
/// at connect(2): it cannot be forged by the peer.
pub fn peer_uid(fd: RawFd) -> Option<u32> {
    let mut cred = Ucred::default();
    let mut len = u32::try_from(std::mem::size_of::<Ucred>()).ok()?;
    // SAFETY: getsockopt(2) writes at most `len` bytes into `cred`, a live, properly sized and aligned
    // `struct ucred` owned by this frame; `fd` is only read. A bad fd is an error return, not UB.
    let rc = unsafe { getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &mut cred, &mut len) };
    (rc == 0 && usize::try_from(len).ok() == Some(std::mem::size_of::<Ucred>())).then_some(cred.uid)
}

/// `struct pollfd` of <poll.h>.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct PollFd {
    pub fd: i32,
    pub events: i16,
    pub revents: i16,
}

pub const POLLIN: i16 = 0x001;

/// poll(2) over `fds` for at most `timeout_ms` (-1: no limit). `Err` carries the OS error
/// (EINTR when a signal arrived: poll is never restarted after a handler, whatever SA_RESTART says).
pub fn poll_fds(fds: &mut [PollFd], timeout_ms: i32) -> std::io::Result<usize> {
    let n = u64::try_from(fds.len()).map_err(|_| std::io::Error::from_raw_os_error(22))?;
    // SAFETY: poll(2) reads and writes exactly `n` `struct pollfd`s starting at `fds`, a live mutable
    // slice of that length with the C layout (repr(C)); it keeps no pointer past the call.
    let rc = unsafe { poll(fds.as_mut_ptr(), n, timeout_ms) };
    usize::try_from(rc).map_err(|_| std::io::Error::last_os_error())
}

static TERM: AtomicBool = AtomicBool::new(false);

extern "C" fn on_term(_sig: i32) {
    TERM.store(true, Ordering::SeqCst); // an atomic store is async-signal-safe
}

/// SIGTERM and SIGINT only set a flag (`term_asked`); the server's poll returns with EINTR and the
/// loop restores and leaves.
pub fn catch_term() {
    for sig in [15, 2] {
        // SAFETY: signal(2) with a handler that only stores to an atomic (async-signal-safe). The
        // previous handler it returns is not needed.
        let _ = unsafe { signal(sig, on_term as extern "C" fn(i32) as usize) };
    }
}

pub fn term_asked() -> bool {
    TERM.load(Ordering::SeqCst)
}

/// `O_NOFOLLOW`: fail with ELOOP when the final path component is a symlink. The value
/// differs per architecture, so an unknown one stops the build instead of guessing.
#[cfg(any(target_arch = "x86_64", target_arch = "x86", target_arch = "riscv64"))]
pub const O_NOFOLLOW: i32 = 0o400000;
#[cfg(any(target_arch = "aarch64", target_arch = "arm"))]
pub const O_NOFOLLOW: i32 = 0o100000;
#[cfg(not(any(
    target_arch = "x86_64",
    target_arch = "x86",
    target_arch = "riscv64",
    target_arch = "aarch64",
    target_arch = "arm"
)))]
compile_error!(
    "silicon-helper: O_NOFOLLOW is not known for this architecture; add it to sys.rs after checking <asm/fcntl.h>"
);

/// Wall-clock milliseconds since the epoch (0 if the clock is before it).
pub fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}
