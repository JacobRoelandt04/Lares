# screentimed

Per-app focused-window time for the screentime module. One static Rust binary, `libc` + `serde_json` only,
one single-threaded `poll()`. The contract is
`docs/contracts/screentime.md`; platform facts are in `0.md`.

```
cargo build --offline --release            # ./target/release/screentimed (static-pie, see "Static")
cargo test --offline && cargo clippy --offline --all-targets -- -D warnings && cargo fmt --check
./install.sh [--dry-run | --uninstall]     # the user's binary + unit, no root, no systemctl
```

## Layout

| file | what |
|---|---|
| `src/core.rs` | the PURE state machine: `Core::handle(Input, Clocks{wall,mono,boot}) -> Vec<Output>`. Backdating, cutting, roll, sessions, suspend placement, digest trigger. Tests: `src/core_tests.rs` (one per CONTRACT section 3 edge case) |
| `src/cal.rs` | `Calendar` trait: `LibcCal` (localtime_r), `TableCal` (Europe/Brussels table), `FixedCal`; local time -> instant is written once on top of `local()` |
| `src/day.rs` | the day record and `compute_sum` (everything in `sum` is derived from `iv` + `breaks`) |
| `src/store.rs` | day files, `state.json`, config; atomic 0600 writes |
| `src/proto.rs`, `src/view.rs` | line framing and message parsing; STATE and week/day/range replies |
| `src/hypr.rs` | socket2 events, socket1 requests, instance discovery; the title is dropped at parse |
| `src/event_loop.rs` | the daemon (`run`) and `serve-frozen` |
| `src/replay.rs` | `replay` and `rebuild` |
| `src/ctl.rs`, `src/cli.rs` | `ctl`, `lock-run`, `query`; argument parsing |
| `tests/*.rs` | libc calendar with `TZ=Europe/Brussels` (own process), the client commands |

## Decisions worth knowing

- **Sessions are derived from the file.** A session is a run of intervals with no break between; a short
  idle pause leaves no break. `cont` = the file's first interval starts exactly at the day start with no
  break before it (the roll splits the open interval exactly there).
- **A break whose day left RAM** (the away spanned the roll and ended after boundary + maxBackdateS) is
  written at the start of the current day.
- **`stop` break**: written only when a restart cannot continue the session (other boot, or the gap is
  over `sessionBreakMin`), never at TERM.
- **Suspend detection runs on every input**, not only on the tick, so the first event after a wake cannot
  close the interval over the sleep. The tick (armed only while active) is for a wake with no event.
- **Hyprland events**: only `activewindowv2`, `focusedmon`, `monitoradded/removed`. A non-empty address
  asks socket1 `j/activewindow`; one reply per read burst resolves every window event in it. An empty
  address needs no query (Desktop).
- **dayStartHour is read at start**: a SIGHUP reload keeps it (days already written carry the old bounds).
- Discovery watches (inotify) exist only while no instance answers; a short one-shot retry timer covers a
  socket that is bound but not yet listening.

## Static

`.cargo/config.toml` links the binary static-pie (`+crt-static`). Dynamic, the same daemon sat at 3.1 MB
RSS (libc.so alone maps 1.4 MB); static it is 1.8 MB after the gate's queries. The price is a 1.6 MB file.

## replay input

`screentimed replay events.ndjson --data DIR`: one JSON object per line
`{"wall":ms,"mono":ms,"boot":ms,"in":{"k":KIND,...}}` (`mono`, `boot` default to `wall`; a first line
`{"cfg":{...}}` configures). Kinds: `start{boot,saved?,lockPid?}` `hyprup{app,mon,monitors}` `hyprdown`
`focus{app|null}` `aw{json}` (a raw `j/activewindow` reply, titles and all, through the daemon's parser)
`focusmon{mon}` `monadd{mon}` `monrm{mon}` `idle{ago}` `active` `lock{pid?}` `unlock` `sleep` `wake`
`lockexit{pid}` `tick` `roll` `shutdown` `reload{cfg}` `flush`. The day roll needs no event: the core splits
at the boundary when the next input's wall is past it. Run it with the zone you want in `TZ`.

## Overhead (measured on this machine)

- binary 1 604 704 bytes (static; 681 kB dynamic); RSS 1.56 MB at start, 1.88 MB after a 28-day history
  and 54 queries.
- away 60 s: 0 voluntary context switches, 0 CPU ticks, data dir unchanged. Active with
  `--flush-s 20 --check-s 20`: 3 wakeups per minute.
- 12.8 us of daemon CPU per focus event over 20 000 lockstep events (each costs one socket1 round
  trip), under the plan's 30 us.
- `week` cold: 1.0 to 1.5 ms client-side round trip (seven files parsed).
