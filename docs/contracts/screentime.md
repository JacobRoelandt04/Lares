# Screentime contract (frozen 2026-10-04, v1)

(The plans, stage-0 facts and round notes this contract names beside it are no longer in `docs/`: they are in git history,
`git log --all -- 'docs/agent_added_files_and_folders/screentime_progress/'`.)

Every stream builds to this file. A change to it is an orchestrator commit that the affected
streams are told about. Platform facts are in `0.md`, the plan in `PLAN.md`.

Units: **every time on the wire and on disk is epoch milliseconds (integer)**, and every duration is
**seconds (integer)**. Dates are local `YYYY-MM-DD` strings naming a *logical day*: the day that
starts at `dayStartHour` (04:00) local time on that date.

## 1. Paths, config, CLI

| what | path |
|---|---|
| socket | `$XDG_RUNTIME_DIR/screentime/screentimed.sock`; the directory is mode 0700 and is created by the daemon if missing (the unit also sets `RuntimeDirectory=screentime`) |
| day files | `$XDG_DATA_HOME/lares/screentime/days/YYYY/YYYY-MM-DD.json` (`~/.local/share/...`) |
| restart state | `$XDG_DATA_HOME/lares/screentime/state.json` |
| config | `$XDG_CONFIG_HOME/quickshell/config/screentime.jsonc`. Optional: every key has a compiled default. Re-read on SIGHUP. The repo carries `screentime.example.jsonc` |

Config keys and defaults: `dayStartHour` 4, `weekStart` 1 (1 = Monday … 7 = Sunday),
`sessionBreakMin` 5, `maxBackdateS` 900, `flushS` 300, `checkS` 60, `digest` true,
`aliases` {} (class → class, applied before anything is recorded: merges classes that are the
same app), `names` {} (class → display name, used by the digest only).

Binary `screentimed` (crate `helpers/screentimed/`):

```
screentimed run [--data DIR] [--socket PATH] [--hypr-dir DIR] [--config FILE] [--flush-s N] [--check-s N]
screentimed ctl idle <agoSeconds> | active | lock [--pid N] | unlock | sleep | wake      [--socket PATH]
screentimed lock-run <cmd> [args...]                                                    [--socket PATH]
screentimed query state | week <YYYY-MM-DD> | day <YYYY-MM-DD> | range <from> <to>      [--socket PATH]
screentimed serve-frozen --data DIR --socket PATH --now <ms>     (answers queries from files, as of <ms>; no Hyprland, no feeds)
screentimed replay <events.ndjson> --data DIR                     (pure core, explicit clocks; writes day files)
screentimed rebuild --data DIR                                    (recomputes every `sum` from `iv` + `breaks`)
```

- `--hypr-dir` names ONE instance directory (the one holding `.socket.sock` / `.socket2.sock`). Without
  it the daemon discovers instances itself (§4).
- `ctl` never waits for a reply. It connects, writes one line and closes, with a 100 ms connect/write
  timeout. Whether the daemon is down or stopped, it exits 0 within 150 ms. Its exit code is
  always 0 because hooks must never fail on its account.
- `lock-run` sends `{"feed":"lock","pid":<its own pid>}` the same way, then `execvp`s the command, so
  that pid IS the locker's. When the send fails it still execs. If the exec fails it exits 127.
- `query` prints the reply line to stdout. Exit 0 on `ok`, 1 otherwise, 2 when the daemon is unreachable.

## 2. Wire protocol (NDJSON over the Unix socket)

One JSON object per line, UTF-8, at most 64 KiB per line. A line that is malformed or too long
is dropped and counted in `state.dropped`, and the connection stays open. Unknown keys are ignored.
Every reply and push carries `"v":1`.

**Feeds** (fire and forget, no reply):

| line | meaning |
|---|---|
| `{"feed":"idle","ago":120}` | no input for `ago` seconds. Adds reason `idle` and backdates (§3) |
| `{"feed":"active"}` | input again. Removes `idle` |
| `{"feed":"lock","pid":123}` | locked. `pid` is optional; with one, that process's exit means unlock (pidfd) |
| `{"feed":"unlock"}` | removes `locked` |
| `{"feed":"sleep"}` / `{"feed":"wake"}` | adds / removes `asleep` |

**Queries** carry `"id"` (any JSON number or string), which is echoed. Failure is
`{"v":1,"id":…,"ok":false,"error":"<word>"}`, where the word is one of `badrequest`, `notweekstart`
or `baddate`.

| query | reply |
|---|---|
| `{"q":"state","id":1}` | `{"v":1,"id":1,"ok":true,"state":STATE}` |
| `{"q":"week","from":"2026-09-28","id":2}` | `{…,"week":{"from":"2026-09-28","days":[DAYSUM×7]}}`; `from` must be a week start, else `notweekstart` |
| `{"q":"day","date":"2026-10-03","id":3}` | `{…,"day":DAYFULL}` |
| `{"q":"range","from":"2026-09-01","to":"2026-10-12","id":4}` | `{…,"range":{"2026-09-01":secs,…}}` (inclusive; only days with data; at most 400 days) |
| `{"q":"watch","topics":["state","focus","monitors"],"id":5}` | `{…,"watching":[…]}`, then pushes. A new `watch` replaces the topic set; `[]` stops pushes |

`DAYSUM` = `{"date","status","start","end","sum"}`:
- `status` is `"ok"` (data or today), `"none"` (a past day with no file) or `"future"`.
- `start`/`end` are the logical day's bounds in ms.
- `sum` is SUM (§5), or `null` unless `ok`.
- **Today's entry is live**: the open interval is included up to `now`.

`DAYFULL` = DAYSUM plus `apps`, `mons`, `iv`, `breaks` from the day file (§5). Today's open interval
appears as a closed one ending at `now`, and `"open":true` is set on DAYFULL.

**Pushes** (only to a connection that asked for the topic, except `bye`):

| push | when |
|---|---|
| `{"v":1,"ev":"state","state":STATE}` | on subscribe, on any change of `active` / `away` / `session` / `day`, and after a config reload |
| `{"v":1,"ev":"focus","app":…,"mon":…,"since":ms,"today":{"total":s,"apps":{…}}}` | every focus change while active (§3), with today's closed totals |
| `{"v":1,"ev":"monitors","focusedMon":…,"focusedMonSince":ms,"lastFocus":{name:ms},"present":[names]}` | `focusedmon` changes, a monitor added or removed |
| `{"v":1,"ev":"day","date":"…"}` | a day file was finalised or rewritten (roll, backdate across the roll, rebuild): drop caches for that date |
| `{"v":1,"ev":"bye"}` | the daemon is stopping. It writes `bye`, then closes. **The client closes first** when it reads `bye` (PeerClosedError rule) |

## 3. State machine

- **Focus** F = (app, mon). `app` is the class after `aliases`, or `"~desktop"` when no window is
  focused. `mon` is the focused monitor's name.
- **Away reasons** R ⊆ {`idle`, `locked`, `asleep`, `nosession`}. The user is **active** ⇔ R = ∅.
  While active there is exactly one open interval `[appSince, …)` on F.
- **Focus change** (a new `app` or `mon`): close the open interval at now and open one on the new F.
  Two changes within the same millisecond leave no zero-length interval. A change that does
  not change F does nothing.
- **`idle(ago)`**: compute t\* = max(now − min(ago, maxBackdateS)·1000, activeSince), where
  `activeSince` is when R last became ∅. Every interval held in RAM that ends after t\* is cut
  at t\*, and one that starts at or after t\* is dropped, with its switch count undone. Then R += idle,
  and `awaySince` = t\*.
- **`lock` / `sleep`**: close at now (or keep `awaySince` if already away). R += reason, and the
  **session ends** at `awaySince`, with break `lock` / `sleep` recorded.
- **R becomes ∅**: open an interval on F at now. A **new session** starts when a lock or sleep
  break ended the last one, or when `now − awaySince ≥ sessionBreakMin`. In that second case a
  break `idle` is recorded at `awaySince`. Otherwise the session continues, and `session.active`
  does not count the pause.
- **Pickups** = sessions that start within the logical day.
- **Day roll** at `dayStartHour` local, via timerfd at an absolute CLOCK_REALTIME time with
  `TFD_TIMER_CANCEL_ON_SET`, so a wall-clock step re-plans. The open interval is split at the
  boundary and a running session continues (`cont`). Yesterday's records stay in RAM until
  boundary + maxBackdateS, so a backdate across 04:00 rewrites yesterday's file. Then they are final.
- **Suspend with no feed.** While active, a CLOCK_MONOTONIC timerfd checks every `checkS` whether
  (BOOTTIME − MONOTONIC) grew. A growth d > 2 s, seen at wall time W, is a suspend at [W−d, W]:
  intervals are cut at W−d, break `sleep`, the session ends, and R is unchanged. A `sleep` feed
  that arrives within 5 s after such a detection is ignored, and so is its `wake`.
- **Wall clock stepped backwards**: an interval with e < s is clamped to zero length and dropped.
  Durations are never negative.
- **Daemon start**: R = {nosession} until a Hyprland instance answers. If a `hyprlock` owned by this
  user is running (a one-time `/proc` scan of `comm`), R += locked with that pid. A session in
  `state.json` continues when `boot_id` matches and now − its saved `awaySince`/`savedAt` is under the
  break length. Otherwise a new session starts at the first active moment.
- **Lock pid**: the pidfd's exit removes `locked` only when that pid is the one recorded. An
  explicit `unlock` removes it too, and clears the pid.
- Duplicate feeds are idempotent. `active` while not idle does nothing.
- **`nosession`**: Hyprland gone, meaning socket2 hit EOF and no instance answers. Intervals close,
  and the session ends after the break length like any other away.

## 4. Hyprland

Per `0.md`, the daemon reads socket2 and reacts to exactly these events:
- `activewindowv2>>ADDR`: ask socket1 `j/activewindow`. Its `class` is the app; `{}` or an empty
  ADDR means `~desktop`. It never parses `activewindow` or `openwindow`, because a class may hold a comma.
- `focusedmon>>NAME,WS`: `mon` = NAME. This is a focus change, and it updates `focusedMon`, `focusedMonSince` and `lastFocus[NAME]`.
- `monitoradded>>NAME` / `monitorremoved>>NAME`: the `monitors` push's `present` list.
- EOF on socket2: R += nosession. Then rediscover.

Startup and rediscovery:
1. Read `j/monitors` (which monitor has `focused`) and `j/activewindow`.
2. Instances are the directories under `$XDG_RUNTIME_DIR/hypr/` whose `.socket2.sock` accepts a connection. The newest `hyprland.lock` mtime wins.
3. inotify on `$XDG_RUNTIME_DIR/hypr/` (IN_CREATE, IN_MOVED_TO) and on the instance directory wakes a rediscovery. There is no polling.

## 5. Day file v1

```json
{ "v": 1, "date": "2026-10-03", "start": 1759456800000, "end": 1759543200000,
  "apps": ["kitty", "zen", "~desktop"], "mons": ["eDP-1"],
  "iv": [[1759460000000, 1759460420000, 0, 0], ...],
  "breaks": [[1759470000000, "lock"], ...],
  "sum": SUM }
```

- `iv` is `[s, e, appIndex, monIndex]`, sorted by `s`, non-overlapping and inside `[start, end)`.
  `breaks` is `[at, why]` with why ∈ `lock|sleep|idle|nosession|stop`.
- **The file is the truth for `iv`/`breaks`**. `sum` is derived, and `rebuild` recomputes it.

SUM:

| key | value |
|---|---|
| `total` | active seconds (Desktop included) |
| `apps` | `{app: seconds}` |
| `hours` | `[24]` seconds per local wall hour; index = (localHour − dayStartHour) mod 24. A DST 25 h day adds both of the repeated hour's halves to one bucket |
| `appHours` | `{app: [24]}` |
| `first`, `last` | ms of the first interval's start and the last one's end (`null` with no intervals) |
| `switches` | changes between distinct non-Desktop apps. A→Desktop→B = 1, A→Desktop→A = 0, the first focus of a session = 0 |
| `longest` | `{app, s, at}`: the longest single non-Desktop interval (one focus, no away inside) |
| `sessions` | `[[s, e, activeSeconds, cont]]`, the session's part within this day. `cont` = it started on an earlier day |
| `pickups` | number of sessions with `cont` false |
| `mons` | `{monName: seconds}` |

A file is written atomically (tmp + rename, mode 0600) on these occasions:
- every `flushS` seconds while active and dirty
- on away, lock, sleep, roll, SIGTERM and SIGHUP

Today's file holds closed intervals only, so a crash loses at most `flushS`.

`state.json` = `{v, bootId, savedAt, session:{start, active}|null, lastSession:{start,end,active,why}|null, awaySince|null, digestWeek:"YYYY-MM-DD"|null, lockPid|null}`.

**No window title is ever read into memory, written, logged or sent.** `j/activewindow`'s `title`
is dropped at parse. The replay probe plants a title sentinel and fails on any byte of it.

## 6. STATE object

```
{ "now": ms, "day": "YYYY-MM-DD", "dayStart": ms, "dayEnd": ms,
  "active": bool, "away": ["idle"|"locked"|"asleep"|"nosession"...], "awaySince": ms|null,
  "app": str|null, "mon": str|null, "appSince": ms|null,
  "session": {"start": ms, "active": s} | null,          // active seconds up to appSince (or awaySince)
  "lastSession": {"start": ms, "end": ms, "active": s, "why": str} | null,
  "today": {"total": s, "apps": {app: s}},              // closed intervals only
  "focusedMon": str|null, "focusedMonSince": ms|null, "lastFocus": {name: ms}, "present": [names],
  "dropped": n, "config": {"dayStartHour", "weekStart", "sessionBreakMin"} }
```

The client computes live figures. The daemon never ticks for the UI.
- `today.total + (active ? now − appSince : 0)`
- `session.active + (active ? now − appSince : 0)`

## 7. Weekly digest

At the first R → ∅ of a new week, the daemon sends one `notify-send` when all of these hold: `digest` is true, the previous week has data,
and `state.digestWeek` ≠ this week. The call is
`notify-send -a Screentime -i preferences-desktop-display "Screen time last week" "<body>"`, run in a
child process that is reaped and never waited on.

Body: `"31h 20m, 12% less than the week before. Top: Code 11h 2m, Zen 9h 40m."`
- The comparison clause is left out when the week before has no data. "more" is used when the week grew, and "about the same as" when the change is within ±2%.
- At most three apps, Desktop excluded.
- Names come from `names`, else the class prettified: the part after the last `.`, first letter capitalised (`com.microsoft.VSCode` → `VSCode`, `zen` → `Zen`).

Durations use DUR (§8).

## 8. DUR: duration text (shared by Rust and JS)

`fmt(s)`:
- `s < 60` → `"<1m"`; `s < 3600` → `"{m}m"`; else `"{h}h {m}m"`.
- `m` is floor((s mod 3600)/60), without zero padding.
- `0` → `"0m"`.

The cases are listed in `helpers/screentimed/tests/fixtures/durations.json` (`[[seconds, "text"], …]`).
The UI may lay figures out in fixed cells (DigitCells), but the text is this.

## 9. QML data API (`modules/screentime/data/`)

`ScreentimeService.qml` (the real daemon) and `ScreentimeMock.qml` (synthetic) expose the SAME members:

```
readonly property string status        // "connecting" | "ok" | "absent"
readonly property var    state         // STATE (§6) or null
readonly property real   clockOffsetMs // mock: shifts its own clock; service: 0
property bool            live          // host sets true while the card is on screen -> subscribes "focus"
readonly property int    serial        // bumps on any cache change (read it first in bindings)
function loadWeek(from)   function week(from)    // getter -> {from, days:[DAYSUM]} | null
function loadDay(date)    function day(date)     // getter -> DAYFULL | null
function loadRange(a, b)  function range(a, b)   // getter -> {date: secs} | null
function weekStartOf(date) -> "YYYY-MM-DD"     // uses state.config (or the mock's)
```

- **Getters never ask; `load*` asks.** A getter called from a binding reads the cache only. A
  `day` push or a `day` change in `state` drops the affected entries, and the host re-asks.
- The service's connection follows `ShellLink.qml`: a fresh `Socket` per attempt, a FileView stat
  probe before connecting (an absent daemon logs nothing), retries from 250 ms backing off to
  10 s, SplitParser slices re-split on `\n`, and the client closes on `bye`.
- On connect it sends `watch ["state"]` (+ `"focus"` while `live`), then `state`.

`ScreentimeModel.js` (pure, `.pragma library`, node-tested) holds every computation the UI needs:
DUR `fmt`, the logical-day helpers, the live merge of the open interval into today's `sum`, and the
bars, heat cells, span bars, stats, list rows and ribbon segments built from DAYSUM/DAYFULL. Stream J
writes it, and stream U calls it and adds nothing computational to QML.

`ScreentimeApps.qml`: class → `{desktopId, name, icon, categories}`. It uses
`DesktopEntries.heuristicLookup`, then `SenderMatch.norm`/tail. The result is cached per class.
`~desktop` → `{name:"Desktop", glyph}`. **Rows carry facts (class, seconds). Delegates
resolve the colour** through `AppHue.js` + `iconStore.entryFor(desktopId)`. Never put a themed
colour into a Repeater model.

## 10. Card API (`modules/screentime/ScreentimeCard.qml`, the clock's third tab)

```
property var service          // ScreentimeService | ScreentimeMock | null
property var iconStore        // AppIconStore | null (initials when null)
property bool live            // host: tab shown and popup open
implicitWidth                 // its own fixed width; the height is the host's (454 in the clock)
function ownerAt(x, y)        // -> "week" (the faces card) | "list" (only while the list can scroll) | ""
function stepWeekBy(units, fromPixels)   // sideways wheel over the faces card (WheelStepper)
function cycleFacesBy(units, fromPixels) // vertical wheel over the faces card (CardViewCycler)
function endGesture()
property bool listWheelEnabled
function handleKey(e)         // Left/Right = week, Up/Down = face, Esc = clear day/app
function stepWeek(n)  function selectDay(i)  function focusApp(cls)  function pinMorph(t)
property int face             // 0 bars | 1 hours | 2 span (the owner remembers it)
```

## 11. Idle-system feed

The future idle system's soft mode ("dim the built-in OLED when the focus has lived on another
monitor") subscribes to `watch ["monitors"]`. It reads `focusedMon`, `focusedMonSince` and `lastFocus`
(each monitor's last moment of focus), and `present`. It sends nothing back. Its own idle
decisions reach the daemon as the same feeds hypridle sends today (§2).

## Amendments (2026-10-07, from the streams' readings; binding)

- **DST day names.** The logical days that hold the switch are 2026-10-24 (25 h) and 2027-03-27 (23 h),
  not the 25th / 28th. The tests use the real facts.
- **`cont`** is derived from the file alone. A day's first session is `cont` when its first interval starts
  exactly at the day start and no break comes before it. A session that crosses 04:00 after a short idle
  pause therefore counts as a new pickup (rare, accepted).
- **Late breaks.** A break whose day has already left RAM is written at the start of the current day.
  When a restart cannot continue the session, `stop` goes at the end of today's last closed interval.
  It is never written at TERM.
- **`lastFocus`.** When focus moves between monitors, BOTH monitors get `now`.
- **Suspend check** runs on every input as well as on the tick, so the first event after a wake
  cannot stretch an interval over the sleep.
- **`dayStartHour` is fixed at start.** SIGHUP re-reads every other key; days already written keep
  their bounds.
- **A second `lock` with a different pid keeps the first pid.** A pid-less `lock` accepts a later pid.
- **`longest`** with no non-Desktop interval is `{"app":null,"s":0,"at":null}`. An empty class is `~desktop`.
- **`day` pushes** go to connections that watch `state`. Only `state` is pushed on subscribe.
- **The unit** sets `RuntimeDirectoryMode=0700`. `install.sh` creates the data directory, because
  `ReadWritePaths=-…` skips a missing path under the read-only home.
- **Static link.** `helpers/screentimed/.cargo/config.toml` builds with `+crt-static`: 1.6 MB binary,
  1.9 MB RSS after 28 days and 54 queries. The dynamic build sat at 3.1 MB RSS.
- **Live merge** (data layer). `liveSum` merges from `max(appSince, sum.last, dayStart)`, so a
  closed-only SUM and the daemon's "as of now" today both count every second once. `bars()` takes
  `todayDate`.

## Amendments (2026-10-13: terminal programs; binding)

The user asked what kitty's time goes to: "the most used programs" beside the kitty row.

- **Focus is (app, monitor, program).** For a window whose class is in the config's `terminals`
  (default: kitty, foot, Alacritty, ghostty, wezterm, konsole), the daemon reads the program in
  front from /proc (`fg.rs`). That is the terminal's foreground process group leader's `comm`: a
  short name, never arguments, a working directory or a title. A wrapper (`sudo`) gives way to the
  program it started. It reads on focus and on a `windowtitlev2` of the focused terminal (kitty
  retitles on every command), at most once per socket read, about 42 µs. A program change closes the
  interval and opens the next, like a monitor change, so backdating, the roll and sessions carry it
  unchanged.
- **Day file.** An interval may have a 5th element, an index into a new `progs` list. Both appear
  only when there is a program, so a day without one keeps its v1 bytes (the replay goldens are
  unchanged).
- **Sum.** `sub`: app -> program -> seconds, present only when non-empty. `longest` is now the
  longest RUN on one app: touching intervals with no break between them, so a monitor or program
  change does not cut it. Before, it was the longest single interval.
- **State.** `prog` is the focused terminal's program or null. `stretchSince` is where the current run
  began; `liveSum` measures the live longest stretch from it.
- **Shell side.** `Model.rows` lists no app under 60 s ("<1m", the user). A row's `progs` holds its
  top three programs over 60 s; shells (bash, zsh, fish, sh, dash, nu), which are the prompt, are
  left out.
- **Not measured: instant commands** (`git status`, `ls`). They finish before any read sees them.
  Counting them needs a source that sees every command (a shell hook, or the command name taken from
  kitty's title as it starts), which is the user's call.

## Amendment (2026-10-13: one snapshot a session; binding)

The user saw the open popup flash as data came in. The cause: on every focus push the service
dropped today's cached week, so for a moment the card read no week, drew itself empty, and refilled
when the re-asked week landed. The user's rule: never update the shown information during a popup
session. Every open takes the data once.

- **§9 `live`** = a session is on show. Becoming live calls `refresh()`, which re-asks the state
  and every cached week, day and range. Each answer replaces the old one where it stands, so no
  getter ever reads null on the way. Nothing else changes until the next session.
- **The service subscribes to nothing.** It asks for the state on connect and on each refresh.
  `bye` still reaches every client. The mock keeps the same contract: in a session a lever or the
  day roll changes its own truth only, and `refresh()` publishes it.
- **The card's figures** (Today, Session, the live merge) are taken at the snapshot's own instant,
  `state.now`. No clock ticks while the card is shown; the BoundaryClock and the card's `live` are
  gone, and so is the service's `clockOffsetMs`.
- **The lock** takes its own snapshot as it comes up (LockOwner calls `refresh()` when it wants its
  popup).
- **The mockup's Run tab** has a Refetch button that calls `refresh()`, for debugging.
