//! The program in front in a terminal window, read from /proc.
//!
//! A terminal (kitty here: one process per window) runs its shell, or a program it was started with,
//! on a pseudo-terminal. The process group that owns that terminal's foreground -- the `tpgid` field
//! of any process on it -- is the job the user is looking at: `claude`, `nvim`, `yay`, or the shell
//! itself at its prompt. Its leader's `comm` is the name recorded: the process's own short name,
//! never its arguments, its working directory or the window's title.
//!
//! A wrapper that only starts something else (`sudo yay`) gives way to the program it started. A
//! terminal with several pseudo-terminals (tabs) cannot say which one is shown; the first whose
//! foreground is not a shell is taken, so a program in any tab outranks an idle prompt.
//!
//! Cost: a handful of small /proc reads, done only when the focused window is a terminal and it
//! changed focus or retitled (kitty retitles on every command start and end).

use std::fs;
use std::path::Path;

/// The foreground program's names that are a shell at its prompt.
pub const SHELLS: [&str; 6] = ["bash", "zsh", "fish", "sh", "dash", "nu"];
const WRAPPERS: [&str; 10] = ["sudo", "doas", "env", "nice", "nohup", "time", "timeout", "stdbuf", "unbuffer", "run0"];

/// `(comm, tty_nr, tpgid)` of a process, from its `stat` (comm may hold spaces and parentheses, so the
/// fields are split after its LAST ')').
fn stat(root: &Path, pid: i32) -> Option<(String, i64, i32)> {
    let s = fs::read_to_string(root.join(pid.to_string()).join("stat")).ok()?;
    let open = s.find('(')?;
    let close = s.rfind(')')?;
    let comm = s.get(open + 1..close)?.to_string();
    let rest: Vec<&str> = s.get(close + 1..)?.split_whitespace().collect();
    // rest[0] = state, [1] ppid, [2] pgrp, [3] session, [4] tty_nr, [5] tpgid
    let tty: i64 = rest.get(4)?.parse().ok()?;
    let tpgid: i32 = rest.get(5)?.parse().ok()?;
    Some((comm, tty, tpgid))
}

/// The children of `pid`. The kernel lists them per thread; a terminal forks from its main thread
/// (kitty's 7 threads: all three children on the main one), so that list is read first and the
/// other threads only when it is empty (a read costs 42 us against 77 for every thread, measured on kitty).
fn children(root: &Path, pid: i32) -> Vec<i32> {
    let main = root.join(pid.to_string()).join("task").join(pid.to_string()).join("children");
    if let Ok(s) = fs::read_to_string(main) {
        let out: Vec<i32> = s.split_whitespace().filter_map(|c| c.parse().ok()).collect();
        if !out.is_empty() {
            return out;
        }
    }
    let mut out = Vec::new();
    let Ok(tasks) = fs::read_dir(root.join(pid.to_string()).join("task")) else { return out };
    for t in tasks.flatten() {
        if let Ok(s) = fs::read_to_string(t.path().join("children")) {
            out.extend(s.split_whitespace().filter_map(|c| c.parse::<i32>().ok()));
        }
    }
    out.sort_unstable();
    out.dedup();
    out
}

/// The name of the job in front on the terminal `child` is attached to, a wrapper resolved to what
/// it started. A child on the emulator's OWN terminal (`own_tty`: kitty's helpers inherit the login
/// tty Hyprland was started from) is not a window's terminal.
fn front_of(root: &Path, child: i32, own_tty: i64) -> Option<String> {
    let (_, tty, tpgid) = stat(root, child)?;
    if tty == 0 || tty == own_tty || tpgid <= 0 {
        return None;
    }
    let (mut comm, _, _) = stat(root, tpgid)?;
    let mut leader = tpgid;
    for _ in 0..3 {
        if !WRAPPERS.contains(&comm.as_str()) {
            break;
        }
        let Some(&next) = children(root, leader).first() else { break };
        let Some((c, _, _)) = stat(root, next) else { break };
        leader = next;
        comm = c;
    }
    (!comm.is_empty()).then_some(comm)
}

/// The program in front in the terminal window whose process is `pid`, or None when it has no
/// terminal to read (not a terminal emulator, or gone).
pub fn foreground(root: &Path, pid: i32) -> Option<String> {
    let own_tty = stat(root, pid).map_or(0, |s| s.1);
    let mut shell: Option<String> = None;
    for c in children(root, pid) {
        match front_of(root, c, own_tty) {
            Some(name) if SHELLS.contains(&name.as_str()) => {
                shell.get_or_insert(name);
            }
            Some(name) => return Some(name),
            None => {}
        }
    }
    shell
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    struct Fake(PathBuf);
    impl Fake {
        fn new(tag: &str) -> Fake {
            let d = std::env::temp_dir().join(format!("st-fg-{tag}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&d);
            fs::create_dir_all(&d).unwrap();
            Fake(d)
        }
        /// A process: its comm, its terminal (0 = none), its terminal's foreground group, children.
        fn proc(&self, pid: i32, comm: &str, tty: i64, tpgid: i32, kids: &[i32]) -> &Fake {
            let p = self.0.join(pid.to_string());
            fs::create_dir_all(p.join("task").join(pid.to_string())).unwrap();
            fs::write(p.join("stat"), format!("{pid} ({comm}) S 1 {pid} {pid} {tty} {tpgid} 4194560 0 0")).unwrap();
            let k: Vec<String> = kids.iter().map(i32::to_string).collect();
            fs::write(p.join("task").join(pid.to_string()).join("children"), k.join(" ") + " ").unwrap();
            self
        }
    }
    impl Drop for Fake {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn a_program_in_front_of_the_shell() {
        // kitty 10 on the login tty 1025 (fg: start-hyprland 5), two kittens that inherited it, and
        // bash 12 on pts 34816 with claude 20 in front (measured: the kittens' tpgid is the session's).
        let f = Fake::new("claude");
        f.proc(5, "start-hyprland", 1025, 5, &[]);
        f.proc(10, "kitty", 1025, 5, &[11, 12, 13]).proc(11, "kitten", 1025, 5, &[]).proc(13, "kitten", 1025, 5, &[]);
        f.proc(12, "bash", 34816, 20, &[20]).proc(20, "claude", 34816, 20, &[]);
        assert_eq!(foreground(&f.0, 10), Some("claude".into()));
    }

    #[test]
    fn the_shell_at_its_prompt() {
        let f = Fake::new("prompt");
        f.proc(10, "kitty", 0, -1, &[12]).proc(12, "bash", 34816, 12, &[]);
        assert_eq!(foreground(&f.0, 10), Some("bash".into()));
    }

    #[test]
    fn a_window_started_with_its_program() {
        // `kitty sh -c yazi`: yazi is the terminal's own first process.
        let f = Fake::new("yazi");
        f.proc(10, "kitty", 0, -1, &[12]).proc(12, "yazi", 34817, 12, &[]);
        assert_eq!(foreground(&f.0, 10), Some("yazi".into()));
    }

    #[test]
    fn a_wrapper_gives_way_to_what_it_started() {
        let f = Fake::new("sudo");
        f.proc(10, "kitty", 0, -1, &[12]).proc(12, "bash", 34816, 30, &[30]);
        f.proc(30, "sudo", 34816, 30, &[31]).proc(31, "yay", 34816, 30, &[]);
        assert_eq!(foreground(&f.0, 10), Some("yay".into()));
    }

    #[test]
    fn a_program_in_any_tab_outranks_a_prompt() {
        let f = Fake::new("tabs");
        f.proc(10, "kitty", 0, -1, &[12, 14]).proc(12, "bash", 34816, 12, &[]);
        f.proc(14, "bash", 34818, 40, &[40]).proc(40, "nvim", 34818, 40, &[]);
        assert_eq!(foreground(&f.0, 10), Some("nvim".into()));
    }

    #[test]
    fn a_comm_with_spaces_and_parentheses() {
        let f = Fake::new("comm");
        f.proc(10, "kitty", 0, -1, &[12]).proc(12, "bash", 34816, 50, &[50]).proc(50, "a (b) c", 34816, 50, &[]);
        assert_eq!(foreground(&f.0, 10), Some("a (b) c".into()));
    }

    /// On the real /proc: `ST_FG_PID=<a terminal's pid> cargo test --offline -- --ignored live_proc --nocapture`.
    #[test]
    #[ignore]
    fn live_proc() {
        let pid: i32 = std::env::var("ST_FG_PID").expect("ST_FG_PID").parse().unwrap();
        println!("foreground of {pid}: {:?}", foreground(Path::new("/proc"), pid));
        let t = std::time::Instant::now();
        for _ in 0..1000 {
            std::hint::black_box(foreground(Path::new("/proc"), pid));
        }
        println!("one read: {:.1} us", t.elapsed().as_secs_f64() * 1e3);
    }

    #[test]
    fn nothing_to_read() {
        let f = Fake::new("none");
        f.proc(10, "zen", 0, -1, &[11]).proc(11, "zen", 0, -1, &[]);
        assert_eq!(foreground(&f.0, 10), None);
        assert_eq!(foreground(&f.0, 99), None);
    }
}
