//! Argument parsing and the subcommands.

use crate::core::Cfg;
use crate::{ctl, event_loop, replay, store};
use std::path::PathBuf;

const USAGE: &str = "usage:
  screentimed run [--data DIR] [--socket PATH] [--hypr-dir DIR] [--config FILE] [--flush-s N] [--check-s N]
  screentimed ctl idle <agoSeconds> | active | lock [--pid N] | unlock | sleep | wake   [--socket PATH]
  screentimed lock-run [--socket PATH] <cmd> [args...]
  screentimed query state | week <YYYY-MM-DD> | day <YYYY-MM-DD> | range <from> <to>    [--socket PATH]
  screentimed serve-frozen --data DIR --socket PATH --now <ms>
  screentimed replay <events.ndjson> --data DIR [--config FILE]
  screentimed rebuild --data DIR [--config FILE]";

/// Pulls `--name value` out of `args` (anywhere), leaving the rest in place.
fn take(args: &mut Vec<String>, name: &str) -> Option<String> {
    let i = args.iter().position(|a| a == name)?;
    if i + 1 >= args.len() {
        args.remove(i);
        return None;
    }
    let v = args.remove(i + 1);
    args.remove(i);
    Some(v)
}

fn num(args: &mut Vec<String>, name: &str) -> Option<u32> {
    take(args, name).and_then(|v| v.parse().ok()).filter(|n| *n > 0)
}

pub fn main() -> i32 {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        eprintln!("{USAGE}");
        return 2;
    }
    let cmd = args.remove(0);
    match cmd.as_str() {
        "run" => {
            let opts = event_loop::Opts {
                data: take(&mut args, "--data").map_or_else(event_loop::default_data, PathBuf::from),
                socket: take(&mut args, "--socket").map_or_else(ctl::default_socket, PathBuf::from),
                hypr_dir: take(&mut args, "--hypr-dir").map(PathBuf::from),
                config: take(&mut args, "--config").map_or_else(event_loop::default_config, PathBuf::from),
                flush_s: num(&mut args, "--flush-s"),
                check_s: num(&mut args, "--check-s"),
            };
            event_loop::run(opts)
        }
        "ctl" => {
            let sock = take(&mut args, "--socket").map_or_else(ctl::default_socket, PathBuf::from);
            ctl::ctl(&sock, &args)
        }
        "lock-run" => {
            // `--socket` only counts before the command: after it the words are the locker's own.
            let sock = if args.first().map(String::as_str) == Some("--socket") && args.len() >= 2 {
                let p = PathBuf::from(args.remove(1));
                args.remove(0);
                p
            } else {
                ctl::default_socket()
            };
            ctl::lock_run(&sock, &args)
        }
        "query" => {
            let sock = take(&mut args, "--socket").map_or_else(ctl::default_socket, PathBuf::from);
            ctl::query(&sock, &args)
        }
        "serve-frozen" => {
            let (Some(data), Some(sock), Some(now)) = (
                take(&mut args, "--data"),
                take(&mut args, "--socket"),
                take(&mut args, "--now").and_then(|n| n.parse::<i64>().ok()),
            ) else {
                eprintln!("{USAGE}");
                return 2;
            };
            let cfg = take(&mut args, "--config").map_or_else(Cfg::default, |p| store::load_config(&PathBuf::from(p)));
            event_loop::serve_frozen(&PathBuf::from(data), &PathBuf::from(sock), now, cfg)
        }
        "replay" => {
            let cfg = take(&mut args, "--config").map_or_else(Cfg::default, |p| store::load_config(&PathBuf::from(p)));
            let (Some(data), Some(file)) = (take(&mut args, "--data"), args.first()) else {
                eprintln!("{USAGE}");
                return 2;
            };
            match replay::replay(&PathBuf::from(file), &PathBuf::from(data), cfg) {
                Ok(()) => 0,
                Err(e) => {
                    eprintln!("screentimed replay: {e}");
                    1
                }
            }
        }
        "rebuild" => {
            let cfg = take(&mut args, "--config").map_or_else(Cfg::default, |p| store::load_config(&PathBuf::from(p)));
            let Some(data) = take(&mut args, "--data") else {
                eprintln!("{USAGE}");
                return 2;
            };
            let (n, c) = replay::rebuild(&PathBuf::from(data), &cfg);
            println!("rebuilt {n} day files, {c} changed");
            0
        }
        _ => {
            eprintln!("{USAGE}");
            2
        }
    }
}
