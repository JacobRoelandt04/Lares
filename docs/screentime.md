# Screen time

## What it is

A record of which app had your attention, kept by a tiny background program, and a card that shows where the machine's time went: by week, by day and
by app. The card is the clock popup's third tab (Screen). Holding `S` on the calendar tints every day by how long you used the machine.

## Where it lives

- The daemon: `screentimed`, a user service (`systemctl --user`) installed from `helpers/screentimed/`. It owns the data; the shell only asks.
- The card: the clock popup's Screen tab, next to Calendar and Timers (see `clock.md`). The tab exists when the shell holds a screen-time service
  (always in the live shell; with no daemon running the card says "Screentime is not running").
- The tint: hold `S` on the Calendar tab.
- No bar button, no shortcut of its own, no IPC verb in the shell. The daemon has a command line (`screentimed ctl ...`, `query ...`) for the
  things that feed it.

## What you can do

- Read the header: TODAY and SESSION (live, as of the moment the tab opened), the shown week's label ("14 Sep - 20 Sep") with chevrons, its total and
  its daily average.
- Step weeks: the chevrons, a sideways two-finger swipe over the chart, or Left / Right. Never into the future. A week that is not loaded yet is asked
  for and the step lands when it arrives.
- Switch the chart's face: Days (seven bars of active time, the whole week's apps faint behind), Hours (a 7 x 24 grid, each cell the share of that
  hour), Span (one floating bar per day from first activity to last). A vertical swipe, the dots, or Up / Down cycle them; the shell remembers the face for the session.
- Click a day on the chart (its bar, its row in the grid, its span) to see that day: the stats strip and the app list switch to it and a ribbon opens under the chart, the day as columns
  by hour, stacked by app. Click the day again, or Esc, to go back to the week.
- Read the stats strip: switches per hour, the longest stretch on one app, pickups.
- The app list: the apps of the shown week or day, most used first, with icon, name, duration and a bar of its share. Click an app to focus it: the
  chart's bars, grid and spans redraw for that app alone. Click again, or Esc, to let go. A terminal's row carries the faint names of the programs run
  in it (kitty: `claude`, `nvim`, `yay`).
- Hold `S` on the calendar: every day of the six shown weeks tints by its share of the heaviest shown day.

## What it shows and where the data comes from

- The daemon watches Hyprland's focus events (`activewindowv2`, monitors) and records the focused window's class and the interval. Titles are
  dropped when an event is parsed; a terminal's foreground program is read as its process name from `/proc` (never its arguments or directory).
- It also takes feeds: idle and active from hypridle (`screentimed ctl idle <seconds>`, `active`), lock and unlock (the shell's lock session runs
  `screentimed lock-run` around the locker), sleep and wake. An away of at least `sessionBreakMin` ends a session; a lock or a suspend always does; an idle
  feed never removes more than `maxBackdateS` seconds.
- A "day" starts at `dayStartHour` local (4 by default), so a 01:00 session counts to the evening it began in.
- Files: day files `~/.local/share/lares/screentime/days/<year>/<date>.json` and `state.json` (mode 0600, written atomically), the socket
  `$XDG_RUNTIME_DIR/screentime/screentimed.sock`. Totals are flushed every `flushS` seconds while active.
- The shell connects to the socket (retrying with backoff from 250 ms to 10 s; a desktop without the daemon costs one silent stat every ten seconds).
  The card takes ONE snapshot a session: when the tab is shown the service re-asks the daemon once and nothing on the card changes while it stays open.
- A Monday notification ("digest") says last week's total (`digest`).
- App names and icons come from the desktop entries (the launcher's lookup); an app with none shows its class.
- Missing: no daemon, "Screentime is not running"; a week without activity, "No activity this week".

## Settings

The daemon's `~/.config/quickshell/config/screentime.jsonc` (`//` and `/* */` comments allowed; it is re-read on `SIGHUP` or a restart of the daemon; every key
optional, out-of-range takes the default). `.examples/screentime.jsonc` is the full list.

| Key | Meaning | Default |
|---|---|---|
| `dayStartHour` | local hour a logical day starts (0 .. 23); read at start | 4 |
| `weekStart` | 1 Monday .. 7 Sunday | 1 |
| `sessionBreakMin` | minutes away that end a session | 5 |
| `maxBackdateS` | most an idle feed may remove | 900 |
| `flushS` | seconds between disk writes while active | 300 |
| `checkS` | seconds between looks for a suspend nobody announced | 60 |
| `digest` | the Monday toast | true |
| `aliases` | `{class: class}` two classes that are one app | {} |
| `ignore` | classes recorded as no app (their time is the desktop's) | [] |
| `names` | `{class: name}` display names, for the digest only | {} |
| `terminals` | classes whose foreground program is recorded | kitty, foot, Alacritty, ghostty, wezterm, konsole |

The tab key (`S`) and the tint's fade are properties of `ClockPopupContent.qml` (`usageTintKey`, `usageTintFadeMs`). The card's look (width, the faces' height,
the ribbon's time, how many apps keep their own colour) is tuned in `mockups/screentime.qml`; Save writes the module.

## How it is built

| Path | Role |
|---|---|
| `helpers/screentimed/` | the daemon (Rust, `libc` + `serde_json`, one single-threaded `poll()`): `src/core.rs` the pure state machine, `store.rs` files and config, `hypr.rs` Hyprland's sockets, `fg.rs` the terminal's foreground program, `proto.rs` / `view.rs` the socket, `ctl.rs` / `cli.rs` the commands, `replay.rs` replay and rebuild; `install.sh`, `units/screentimed.service` |
| `modules/screentime/data/ScreentimeService.qml` | the shell's end of the socket: connection, snapshot, caches of weeks, days and ranges; getters never ask |
| `modules/screentime/data/ScreentimeModel.js`, `ScreentimeApps.qml` | every figure the card draws as pure JS (calendar, live sums, columns); the app lookup |
| `modules/screentime/data/ScreentimeMock.qml` | the same surface on fixed data (mock shell, mockup) |
| `modules/screentime/ScreentimeCard.qml` | the card: header, faces on one clock, stats, ribbon, list; keys and gesture hand-over |
| `modules/screentime/ScreentimeBars.qml`, `ScreentimeHeatmap.qml`, `ScreentimeSpan.qml` | the three faces |
| `modules/screentime/ScreentimeRibbon.qml`, `ScreentimeStats.qml`, `ScreentimeAppList.qml`, `ScreentimeAppRow.qml` | the day's histogram, the strip, the list |

Shared components used: `CardViewCycler`, `TimelineChart`, `ShadowBox`, `ScrollDressing`, `WheelStepper`, `AppLookup`. The clock popup hosts the card and owns its
wheel reader (`docs/contracts/gestures.md`); the socket's messages are specified in `docs/contracts/screentime.md`.

## Limits

- It records the focused window's class and time, and nothing else: no titles, no keystrokes, no screenshots.
- The card is a snapshot of the moment the tab opened; close and reopen it for fresh figures.
- A suspend nobody announced is found within `checkS`; an open interval is split exactly at the day's boundary.
- The daemon has to be installed and started by you: `cargo build --release` in `helpers/screentimed`, then `./install.sh` (it copies the binary to
  `~/.local/bin` and the unit to `~/.config/systemd/user`, touches nothing else), then `systemctl --user enable --now screentimed`.

## How to change it

- A threshold, the day's start, the week's start: `screentime.jsonc`, then `systemctl --user restart screentimed` (or `kill -HUP` it).
- Merge two classes into one app: `aliases` in `screentime.jsonc`.
- The card's size, faces or colours: `mockups/screentime.qml` (`quickshell -p ~/.config/quickshell/mockups/screentime.qml`), change on the panel, Save.
- The daemon's code: `cargo test --offline` in `helpers/screentimed`.
- Proof: `tools/dev/smoke.sh mockups/screentime.qml`, `tools/dev/mockup_panel_test.sh mockups/screentime.qml`, `tools/dev/screentime_live_probe.sh` (reads the installed daemon,
  never feeds it), `tools/dev/sheet_check.sh`.
