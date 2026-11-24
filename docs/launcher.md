# Launcher

## What it is

Press `Alt+Space`, type a few letters, press Enter. The launcher lists your applications and your own scripts, ranks what you use most
first, and opens a launched row as a splash into the bar. It is built for the keyboard, with folders and favourites for the things you launch
by hand.

## Where it lives

- No bar button. The popup grows from the slim bar at the bottom edge of the focused screen; it opens over a fullscreen window too, as a floating pill.
- `Alt+Space` (the shell's global shortcut `launcher`) opens it with the keyboard already in it and closes it again. Opening by resting the pointer on the bottom bar belongs
  to the mockups; the shell has the shortcut only.
- Opened over your file browser (the focused window is one of `keysFree`: kitty with `yazi` in its title) it takes no keys, so the browser keeps its arrows; click it for the
  keyboard. It is then still a drop target.
- Size: one list, or N columns, always `rows` rows tall, so the popup never resizes while you type.
- A one-line wiki teaser at its foot ("Today: <title>"): a click closes the launcher and opens the wiki card in the clock popup (`wiki.md`).
- No IPC verb.

## What you can do

- Type to search: the header becomes the query (there is no search field). It ranks by fuzzy match over the name, the real name, the generic name
  and the keywords, ties by favourite, frecency, name; matching letters are accented; folders are searched through (a hit inside a folder shows).
  `Ctrl+Backspace`, `Ctrl+W`, `Ctrl+U` kill by word or line. A leading space types nothing.
- Quick answers: when the query is something the launcher can answer (math, currency, number bases, time arithmetic, units, dates and time zones,
  colours, percentages and ratios, screen resolutions) the FIRST row of the list is the answer, highlighted. The popup does not resize: the answer takes
  one row's slot and the hits move down one. Its glyph is the kind's (a colour shows a carved swatch and the theme token it is nearest to, "≈ accent"), the
  value is big, what was understood sits muted under it with the small print faint, and up to three other forms stand at the right as plain text.
  `Enter` copies the main form and closes the launcher, `Shift+Enter` copies and stays (the line under the value says "Copied" for 1.2 s), a click on the row does
  the same, a click on another form copies that one. `Down` leaves the answer for the first hit and `Up` from the first hit comes back; the mouse moves the
  highlight as on any row. `Up` on an EMPTY query recalls the queries you copied an answer for (newest first, up to 20, kept across restarts; `Up` goes older,
  `Down` newer and out; typing leaves the recall). With no answer nothing about the keys changes.
- Arrow keys, `Home` / `End` (first / last row) and `PgUp` / `PgDn` (a visible page) move the highlight (a carved well that glides); Enter launches; `Shift+Enter` launches and keeps the launcher open; Esc clears
  the query, leaves the hidden-apps list or a folder, then closes. The mouse moves the highlight too, and a wheel under a still pointer moves it to the row that comes under it.
- `Tab` / `Shift+Tab` step the sort: Default (favourites, then by frecency, then never-launched A to Z), Name (A to Z, either direction) and Recent. The
  sort control at the header's right has the same modes, a Columns switch, and "Hidden apps".
- Favourites: a faint star at the end of a hovered row (or `Ctrl+F` on the highlighted row); a favourite's star takes it off. The row flies to its new place.
- Right-click a row: Favourite, Rename (a display title only; the file behind it is never touched), Remove from folder, Hide (an app of the main list),
  Remove from list (a linked script or desktop file; asks first), Show in file manager. A folder's menu: Pin for this session (it heads every search),
  Rename, Show in file manager, Remove folder (its items go back to the top; nothing is deleted).
- Folders: one level, under the scripts root. Rest a dragged row on another row's centre to make a folder of the two, or drop on a folder to move it in; the
  header band of an open folder is the way out for a drag. A folder shows up to four mini icons and a count. Click it to go in; the chevron, Esc or a
  two-finger swipe back goes up. Click a folder's name in the header to rename it.
- Drop a file (a script, a `.desktop` file) on the popup to link it in; "Show in file manager" opens the file chooser at the right folder, and what you pick is
  linked in the same way.
- Hide / Unhide: Hide writes the app's id into `hidden` of `launcher.jsonc`; "Hidden apps" in the sort menu lists them as ordinary rows to unhide.
- Launch: an app starts in a transient systemd user scope of its own (it outlives the shell); `Terminal=true` apps start in kitty; a script starts as a
  transient user service and, if it fails, a notification names it and quotes the script's last line.

## What it shows and where the data comes from

- Answers: a child process, `tools/launcher/answers.py` (the contract is "the answers child" in `docs/contracts/launcher_answers.md`), started at the first
  non-empty query through `SupervisedStream` (`setpriv --pdeathsig TERM python3 ...`), kept for the shell's life and restarted with backoff if it dies. Every query
  change asks with a rising id and only the latest id's reply is kept; an empty query clears the answers without asking; a `pending` answer (rates being fetched)
  is replaced in place by its landed reply. No python3 or no script: one log line and no answers. A copy goes through `wl-copy`.

- Apps: every desktop entry the system lists (not hidden, `OnlyShowIn` / `NotShowIn` honoured for the running desktop), minus `hidden`. Icons are the
  icon theme's (the theme the supervisor read at start); one app can take another picture through `shell.jsonc` `icons.overrides`.
- Scripts and folders: `scriptsRoot` (default `~/.config/quickshell/launcher/`), one level of folders deep: executable files (header lines `# name:`,
  `# icon:`, `# terminal: yes`, `# description:`), `.desktop` files and links to either. A link to an app's `.desktop` IS that app: it moves out of the main list
  into its folder. Hidden names, nested folders and broken links are not listed.
- What it remembers, in `$XDG_STATE_HOME/lares/launcher/state.json`: the answered queries (`answerHistory`), the sort, the layout (list or columns), frecency (count times the mean age weight
  of the last ten launches: under 4 days 100, 14 days 70, 31 days 50, 90 days 30, older 10), and display titles.
- Every open starts fresh: root, no query, no pinned folder (with `keepQuerySec` the query it was left with a moment ago is still there; a launch leaves none).

## Settings

`~/.config/quickshell/config/launcher.jsonc`, read hot; every key optional. The launcher rewrites only `hidden`, in place, every other byte kept.
`.examples/launcher.jsonc` has all of it.

| Key | Meaning | Default |
|---|---|---|
| `columns` | columns of the multi-column layout (1 .. 8) | 2 |
| `rows` | rows shown before the list scrolls (1 .. 40) | 9 |
| `scriptsRoot` | the scripts folder; `~/...` and absolute paths as written, anything else relative to `~/.config/quickshell` | `""` = `~/.config/quickshell/launcher` |
| `flourish` | the launch throw: `honey`, `syrup`, `dew`, `classic`, `off` (others play honey and log once) | `""` = honey |
| `answers.enabled`, `kinds` | the quick answers, and which families answer (`answers.py` `--kinds`) | true, all ten |
| `answers.takesEnter` | an answer takes the highlight, so Enter copies it; false: Enter takes the first app, Up reaches the answer | true |
| `answers.homeCurrency`, `currencies` | what an amount is turned into when you name none, and the ones beside it | `EUR`, USD EUR GBP JPY CHF |
| `answers.history` | how many answered queries Up brings back | 20 |
| `keysFree` | windows (a whole class and / or words of the title) that keep their keys while the launcher is open | kitty with `yazi` |
| `clickOutsideCloses` | a click outside closes it; else it only hands the keys to what was clicked | false |
| `keepQuerySec` | seconds the query outlives a close (a launch ends it) | 0 |
| `hidden` | desktop ids not listed | `[]` |

The terminal a terminal app or script runs in is `shell.jsonc` `terminal` (`["kitty", "-e"]`; the command is added at its end). A change of an `answers` option
restarts the answers child.

The throw is one parabola on one gravity: the row detaches, shoots up, hangs at its apex, falls into the bar and splashes; the presets differ in how thick the
strand and how heavy the beads are. Everything else about look and motion (sizes, row height, icon size, the hover and open delays, the flourish's numbers) is
`LauncherTune.qml`, tuned in `mockups/launcher.qml`; Save writes the module.

## How it is built

| Path | Role |
|---|---|
| `modules/launcher/LauncherBarOwner.qml` | bar side: how it opens (`shortcutPressed()`, keyboard grab, keys-free over the file browser), the ConfirmFlourish it holds, the session reset |
| `modules/launcher/LauncherPopup.qml`, `LauncherHeader.qml`, `LauncherTune.qml` | the popup, its header and sort control, every tunable number |
| `modules/launcher/browse/` | `LauncherGrid` (rows, highlight, keys, drag, flights), `AppRow`, `FolderRow`, `FlightClone`, `RowGeometry.js`, `RowText.js`, `CategoryHue.js` |
| `modules/launcher/ConfirmFlourish.qml`, `FlourishFrame.qml`, `FlourishFrame.js`, `FlourishFace.qml`, `FlourishPose.js`, `FlourishPresets.js` | the throw: the engine's flourish slot driven from one parabola; the presets |
| `modules/launcher/LauncherBar.qml`, `LauncherBarHover.qml` | the slim bottom bar and its hover opening, used by the mockups |
| `modules/launcher/data/LauncherService.qml` | the data layer: what is listed, order, folders, launching |
| `modules/launcher/data/LauncherConfig.qml`, `LauncherState.qml`, `LauncherFileOps.qml`, `LaunchRunner.qml`, `JsonEdit.js` | `launcher.jsonc` (and the one in-place write); `state.json`; the folder operations (the notes module's queue); how things start; the in-place edit |
| `modules/launcher/data/LauncherAnswers.qml` | the answers child: lazy start, ids, stale replies dropped, copy; owned by the service |
| `modules/launcher/browse/AnswerRow.qml`, `AnswerKinds.js` | the answer row (hosted by the popup, outside the grid) and its pure parts: glyph per kind (checked against the installed font), nearest theme token |
| `modules/launcher/data/LauncherModel.js`, `Frecency.js`, `DesktopFile.js`, `ScriptHeader.js` | pure JS: sorting and ranking, frecency, desktop-file parsing, script headers |

Shared components used: `RowFlight` (a row lifted and flown), `DragIntent.js` (group or reorder), `SortControl`, `FloatingMenu`, `ScrollDressing`, `SwipeScrub`,
`FuzzyMatch.js`, `FileDropOverlay`, `AppIcon`, `ShadowBox`, `HoverTip`, `Chevron`, `ConfigFile`, `DesktopNotifier`. The service surface is specified in
`docs/contracts/launcher.md`; the gestures in `docs/contracts/gestures.md`.

## Limits

- Folders are one level deep; a folder is never dragged into another.
- There is no custom order: the sort is Default, Name or Recent.
- A launch is a throw into the bar, not a wait for the application: the splash does not mean the window has opened.
- Script failures surface only as a notification with the script's last line.

## How to change it

- Columns, rows, scripts folder, flourish preset, hidden apps: `launcher.jsonc`.
- Row height, icon size, widths, open and close delays, the teaser's height, the throw's numbers: `mockups/launcher.qml`
  (`quickshell -p ~/.config/quickshell/mockups/launcher.qml`), change on the panel, Save; or `modules/launcher/LauncherTune.qml`.
- A new flourish preset: `modules/launcher/FlourishPresets.js`.
- A new sort mode: `modules/launcher/data/LauncherModel.js` and the menu rows in `modules/launcher/LauncherHeader.qml`.
- The answer row's look: the Answer look tab of the mockup (`answer*` in `LauncherTune.qml`); the Answers tab types a sample of every kind through a stand-in child
  (`tools/dev/fixtures/launcher_answers_stub.py`; `LAUNCHER_ANSWERS=real` asks the real one, `LAUNCHER_QUERY=<q>` types a query at the start).
- Proof: `tools/dev/launcher_answers_ui_probe.sh` (lifecycle, stale replies, pending, keys, copy, history, restart, the glyph names; ARMs in its header),
  `tools/dev/launcher_answers_sheet.sh` (every kind, light and dark, 1x and 1.25), `tools/dev/smoke.sh mockups/launcher.qml`, `tools/dev/mockup_panel_test.sh mockups/launcher.qml`, `tools/dev/config_loaders_probe.sh` (`launcher.jsonc`),
  `tools/dev/sheet_check.sh`.
