# Clock

## What it is

The time in the middle of the top bar. Click it and a popup opens with your calendar, timers (countdown, pomodoro, stopwatch, alarms) and, when
the screen-time service is there, a Screen tab. The clock sits in the middle of the workspaces groove, and the timers colour that groove, so a
running timer can be read without opening anything.

## Where it lives

- Bar: centre island, between the weather and the stocks. The button is the clock slot of the workspaces groove (`modules/bar/workspaces/Workspaces.qml`);
  the groove takes the island's remainder.
- Popup: one popup with a tab row (Calendar, Timers, Screen). The popup changes width with the tab: wide for the calendar, a narrower square
  card for the timers, the Screen card's own width for the Screen tab. A sideways two-finger swipe anywhere outside the month switches tabs.
- Opening: a click on the clock (`ClockBarOwner.toggle()`). Resting the pointer on the button builds the popup ahead, so the click is instant.
  There is no keyboard shortcut and no IPC verb.
- A reminder card shortly before an appointment is the notifications module's (`calendar` in `notifications.jsonc`); its "Open calendar"
  button opens this popup.

## What you can do

The bar button
- Read `hh:mm`. Hover it: the seconds slide in on its right and the workspace dots on either side make room; they leave when the pointer does.
- Figures roll like an odometer when they change.

Workspaces groove (same slot)
- One dot per numbered workspace and a ball on the one this screen shows. Click a dot to go there. A two-finger swipe along the groove steps
  workspaces; the step across the clock continues from where the fingers leaned the ball, as every other step does
  (`tools/dev/workspaces_swipe_probe.sh`). Special and named workspaces get no dot.
- While a countdown or pomodoro runs, the groove fills with colour (see Timers). When a timer finishes, dust comes off the groove.

Calendar tab
- A month grid with week numbers, the selected day and today marked as carved squares; the selected square glides to the day you click.
  Appointments show as coloured dots (three per row, centred); multi-day events show as lines across their days.
- The side list shows the selected day's appointments: coloured stripe, start time, duration pill. Click a row to expand its details
  (description, location, and the time to go: "in 25 min", "started 20 min ago"). An appointment in progress erases its stripe as time runs out.
- Click the list's header to open the calendars panel: tick which calendars are shown (remembered).
- Month arrows in the grid header; a two-finger swipe over the month steps months; holding Ctrl turns every month step into a year step.
  Click a week number to make it week 1 of that year (click again to clear). The header has a way back to today when today is not in view.
- Keys (while the popup has the keyboard): arrows move the selection a day or a week, `T` jumps to today,
  PgUp/PgDn step a month (Ctrl: a year). Holding `S` tints every day by its screen time (needs the screen-time service).
- Under the appointments there is a small wiki card (see `wiki.md`); clicking it opens the full wiki card beside the popup.

Timers tab: one carved square card with four views, switched by the dots at its right edge or a vertical two-finger swipe.
- Timer: wind the ring with the pointer like a kitchen timer (a quarter turn per order of magnitude, then an hour a turn; Shift winds a second
  per pixel; the wheel also winds). Presets sit in the lower-left corner: `+` saves the dialled time, a right-click removes one.
  Start / Pause / Stop, Reset under it.
- Pomodoro: four sessions of focus and short break, then a long break. The focus, short and long durations are set by the wheel on their
  figures (right-click puts the default back). A control at the top right cycles what follows a phase: wait to be started, start by itself,
  or only breaks start by themselves. Skip and Reset take two clicks (the first arms, 2.5 s later it lets go).
- Stopwatch: Start / Pause, Lap, Reset; laps are listed newest first, the fastest and slowest coloured once there are three.
- Alarms: `+` adds one; rows show time, weekdays (clickable on every row) and an on/off toggle. A click on a row selects it (the dial winds its time)
  and shows its label and Delete. No weekday set means once. A ringing alarm shows Stop and Snooze (9 min: `clock.jsonc` `timers.snoozeMin`).
- Everything keeps running with the popup closed. A finished timer plays a sound (up to 60 s) and posts a notification; the notification and the
  timer are one ask: dismissing either ends both. The popup opens on the Timers tab once after a timer finished unseen.
- Which tab opens: the Calendar, unless a timer is in progress and the Timers tab is where you left it; the Screen tab is never the default.
  The Timers card opens on the view of the timer that finished unseen, else the one started last.

Screen tab: the screen-time card (`screentime.md`).

## What it shows and where the data comes from

- Calendar: `.ics` share links listed in `~/.config/quickshell/config/calendars.jsonc` (Proton's read-only share links work). Each feed is fetched
  with `curl` (`CalendarFeed.qml`), cached at `$XDG_CACHE_HOME/lares/calendars/<id>.ics` (so the grid paints at once on start), parsed by
  `ical.js` and expanded by `rrule.js` (DAILY, WEEKLY, MONTHLY, YEARLY, INTERVAL, COUNT, UNTIL, BYDAY, EXDATE). With no file, or an unparseable
  one, the calendar is empty (the month still shows, with no dots) and the error text is on the service.
- Timers: `$XDG_STATE_HOME/lares/clock/timers.json` (absolute times, so a restart or a suspend loses nothing; what ended while the machine
  slept finishes on resume silently, the notification saying when: "ended at 14:05", an alarm "missed at 07:00" within 12 hours). The
  timer durations, advance mode and presets are kept there too; there is no key for them in a settings file.
- Calendar view state: `$XDG_STATE_HOME/lares/calendar/visibility.json` (hidden calendars) and `week-offsets.json` (week-1 anchors).
- Screen tab: only present when the shell holds a screen-time service (the daemon, `screentime.md`); otherwise the popup has two tabs.
- Wiki card: only present when the shell holds a wiki service.

## Settings

`~/.config/quickshell/config/calendars.jsonc` (read hot, comments allowed; the real file holds secret share URLs, so it is not in git):

| Key | Meaning | Default |
|---|---|---|
| `weekStart` | first weekday: 0 Sunday, 1 Monday | 1 |
| `pollIntervalMs` | how often feeds are refetched | 900000 (15 min) |
| `calendars[]` | one entry per feed: `id`, `name`, `color`, `url`, optional `pollIntervalMs`, `remind` | none |
| `calendars[].remind` | its appointments announced: true (notifications.jsonc `leadMin`), false, or minutes before (1 .. 1440) | true |

An entry without `url` is skipped; a missing `id` becomes `cal<n>`, a missing `color` the theme's text colour. A key the file stops giving (or gives out of range)
goes back to its default on the next save, and a file that is deleted empties the feeds. The full example is `.examples/calendars.jsonc`.

`~/.config/quickshell/config/clock.jsonc` (read hot unless said; every key with its words in `.examples/clock.jsonc`):

| Key | Meaning | Default |
|---|---|---|
| `open` | the tab a click opens on: `auto` (the calendar, or the timers when you left it there with one in progress), `calendar`, `timers`, `last` (where you left it); a timer that finished unseen always wins | `auto` |
| `seconds` | the bar's seconds: `hover`, `always` (their room kept, ticking only while the bar is on show), `never` | `hover` |
| `timers.snoozeMin` | what Snooze adds (no longer kept in `timers.json`) | 9 |
| `timers.sounds` | `countdown` / `pomodoro` / `alarm`: a freedesktop sound name, a path or `none`; a missing file plays the default | the freedesktop alarm / complete |
| `timers.volume` | 0 .. 1; -1 the stream's level | -1 |
| `timers.ringSec` | the longest a countdown or alarm rings | 60 |
| `timers.soundUnderDnd` | false: silent under do-not-disturb (the card still shows) | true |
| `timers.countdownMin` | the countdown's time in a new session (read at start) | 5 |
| `timers.focusMin` / `shortMin` / `longMin` | the pomodoro's first lengths and what a right click puts back (read at start; `timers.json` keeps what you set) | 25 / 5 / 30 |
| `timers.missedHours` | an alarm missed by more is not reported (one due within the minute always rings) | 12 |
| `look.secondarySide` | where the wiki's card opens: `end`, `start`, `far` | `end` |
The clock's look and motion (sizes, glide durations, dial geometry, colours) are tuned in `mockups/clock.qml`; its Save writes the module. The workspaces groove's
size (`workspacesScale`, `workspacesPitch`, `workspacesWidth`) is in `modules/shell/ShellConfig.qml`, tuned on the Layout tab of `mockups/shell.qml`.

### The break nudge (the workspaces rail)

`config/breaks.jsonc` (read hot, comments allowed; example `.examples/breaks.jsonc`, every key with its default and range): `enabled` (true), `durationMin` (50: minutes of use until the rail is full), `pauseMin` (5: an idle span this long empties even a full rail),
`idleGraceSec` (30: a shorter idle is use, and is the IdleMonitor's timeout), `rewindPower` (2), `stepSec` (60), `stepEaseMs` (700), `hiddenMin` (10).
The model banks CREDIT, seconds of use, that grows only while you are active. An idle span (no input; a locked screen from lock to unlock and a suspend from sleep to wake are idle spans too, and causes
that overlap are ONE span from the earliest start) first takes back the credit given since it began, then, when input returns, rewinds the rail by `((span - grace) / (pause*60 - grace)) ^ rewindPower` of the FULL rail: 3 minutes of
a 5 minute pause at power 2 is 0.3086 of the rail, so small idles cost little and the cost grows the more idle you are. A suspend with no "about to sleep" heard is the wall-clock gap since the last accounting.
THE DRAWN FILL MOVES ONLY ON ITS OWN BEAT: every `stepSec` the head is set to the progress and eases there (`stepEaseMs`, OutCubic; a fact `{t0, t1, ease}` the rail draws itself, repainting per pixel of glide at most 30 times a second for the ease only);
between beats there is no repaint and no wake-up (one single-shot timer, re-armed per beat, stopped in a span and at full). A rewind is shown at once when input returns (it eases too). Below `hiddenMin` of credit nothing is drawn; the beat that crosses it
eases the fill in from the rail's start, and a rewind under it eases it back out. Full: the burst plays once when the DRAWN head lands on full, and again only after the fill went below 90 % of the rail. Colour: warn, UNDER any timer's fill.
Cost, per hour of use (`tools/dev/break_budget.sh`, a 400 px rail): 748 paints / 748 wake-ups before (a paint per half pixel of a linear creep) against 328 / 379 now.
Code: `modules/bar/workspaces/BreakModel.qml` (the rules, no machine), `BreakClock.qml` (the shell's one instance: IdleMonitor, `Sleep`, the file; the owner hands it to its Workspaces), proof `tools/dev/break_model_probe.sh`
(28 checks on a manual clock; ARMs overtimers, noease, easeunbounded, nograce, linear, nohidden, onlyidle, nosleep, lockreset, nobeat, reburst), `tools/dev/break_sheet.sh`; try it on `mockups/workspaces.qml` (Run tab, "Break nudge": every key has a slider and a tip).

## How it is built

| Path | Role |
|---|---|
| `modules/clock/ClockBarOwner.qml` | the bar-side owner: what must outlive the popup (tab, timers' link to the groove, tab rule, requests) |
| `modules/clock/ClockBarButton.qml` | the `hh:mm` figures, seconds on hover, the roll |
| `modules/clock/ClockPopupContent.qml` | the popup: tab row, calendar, timers, screen tab, wiki tear-off, swipe routing |
| `modules/clock/calendar/` | `CalendarView` (month grid, glide, keys), `MonthHeader`, `MonthWeekRow` / `RowStrip` (the week rows), `AppointmentList` / `AppointmentRow` (the day's list), `EventIn.js` (time to go) |
| `modules/clock/timers/` | `TimersCard` (the four views on one clock), `TimerDial` (the winding ring), `CountdownView`, `PomodoroView`, `StopwatchView`, `AlarmView`, `dial.js`, `format.js` |
| `modules/clock/data/` | `TimerService` + `timers.js` (state, ticking, disk, notifications, sound), `CalendarConfig`, `CalendarService`, `CalendarFeed`, `ical.js`, `rrule.js`, the two small stores, `MockCalendarData` |
| `modules/bar/workspaces/Workspaces.qml` | the groove, the dots, the ball, the fills the timers write |
| `modules/clock/PlusButton.qml`, `ProgressStripe.qml` | the `+` button; a stripe that doubles as a gauge |

Shared components used: `TabSelector` (tab row), `ShadowBox` (carved boxes), `CarvedRing` (the dial), `CardViewCycler` and `ViewBlend` (the
timer views on one clock), `DigitCells` (figures that do not jitter), `BoundaryClock` (a tick on each minute/second boundary, resume-safe),
`SeamFade`, `Chevron`, `ScrollDressing` and `KineticScroll` (lists), `WheelStepper`, `HoverIntent`, `DesktopNotifier`, `SoundPlayer`.
Service pair: the shell builds one `CalendarService` (live) or `MockCalendarData` (mock shell) and one `TimerService` (saved to disk only when live);
the owner takes them injected.

## Limits

- The calendar is read-only: it shows share-link feeds and never writes one.
- No sleep inhibitor: a timer that ends during suspend finishes on resume, silently.
- Workspaces: only numbered workspaces get a dot.
- The break count is not kept across a shell restart (it starts again from the first input).
- A calendar fetch needs `curl`; a failed fetch leaves the cached copy on screen.

## How to change it

- A colour: the clock reads `Theme.<token>` everywhere (`themes/*.json`); a calendar's colour is its `color` in `calendars.jsonc`.
- A size or a timing (cell size, glide time, dial radius): open `mockups/clock.qml` (`quickshell -p ~/.config/quickshell/mockups/clock.qml`),
  change it on the panel, Save. Or edit the property default in `modules/clock/calendar/CalendarView.qml` / `modules/clock/timers/TimersCard.qml`.
- The first weekday or a feed: `calendars.jsonc`.
- Timer defaults (focus 25, short 5, long 30 min, snooze 9 min, the sounds): `clock.jsonc` `timers`; the presets are the card's own (kept in `timers.json`).
- Proof: `tools/dev/smoke.sh mockups/clock.qml` (no warnings), `tools/dev/mockup_panel_test.sh mockups/clock.qml`, `tools/dev/config_loaders_probe.sh` (`calendars.jsonc`), and `tools/dev/sheet_check.sh` for a picture-for-picture
  comparison of the whole shell.
