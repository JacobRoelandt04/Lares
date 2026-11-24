# system_update -- the system update

## What it is
The Arch update (`yay -Syu`) as a popup: it counts what is waiting, runs the update in front of you, shows what is downloading, installing
and hooking, asks yay's and pacman's questions in its own card and keeps the run alive when the popup, the shell or a config reload goes
away.

## Where it lives
- Bar: the right island of the top bar, module id `update` (before `notifications`). Idle, the icon is an archive glyph whose colour says
  updates wait: the muted ink below `accentAt` of them (1: none), the accent below `warnAt`, the warn colour below `errorAt`, the error colour from
  there on, and red after a run that failed. The pointer takes it to its own hover colour, which is none of those, and, idle, tosses
  the lid while two papers rise (`components/ArchivePose.js`; the glyph_button mockup's Flourish tab). A per-step run sequence is
  proposed (a storyboard), not built. While a run goes the icon turns into a small pill with the glyph, the whole run's percentage, a mark for the phase (a
  question in the warn colour while yay waits for an answer, an exclamation in the error colour while it fails) and a thin progress bar; when
  the run ends it stays a moment on its last figure and folds back.
- Popup: three views, switched by the tab row (it slides in when the pointer rests along the popup's top edge and goes when the pointer
  leaves) or a two-finger horizontal swipe anywhere on it.
  `quiet` is the status card alone (400 px of tabs plus padding); `normal` (700 px) adds the phase rail and the category list; `verbose`
  (1080 px) puts a terminal beside the list. It opens in `quiet` when nothing runs and in the run's own view while one does; the view is
  remembered across a shell restart for that run. Its size can be set with `scale.popups.update` in `shell.jsonc`.
- No keyboard shortcut and no IPC verb. The notification source `update` (see `notifications.md`) can start a run from its card.

## What you can do
- Read the card: "N updates available", "System up to date", "Checking...", "Update complete", or during a run the phase ("Downloading",
  "Verifying", "Installing official packages", "Running post-install hooks"...) with an operation line, the figure at the right ("n / m
  packages - eta") and held slots so nothing jumps. A Run-update button shows when idle (there is no Refresh button: the popup looks again by itself, see "When it looks"); "Retry" after a failed run.
- Phase rail (normal and verbose): notches for Sync, Resolve, Sources, Download, Install, Hooks, AUR (the last two only when the transaction
  has them), a ball that rests in a notch for phases that cannot be measured and travels for those that can; it never goes backwards.
- Category list: Core, Extra, Multilib, AUR, Flatpak (a repo yay does not know gets its own), a header per category with its progress, rows
  with the package, the version you move TO (left click reveals the current one and makes the icon a link to the package's upstream page),
  a skeleton while the check runs. During a run a package leaves after it finishes and an emptied category collapses.
- Right click a row to make the package a favourite: favourites are pinned in their own category at the top and keep the saturated
  category colour while every other row is drained to grey. They are kept in `~/.local/state/lares/system-update/favorites.json` (shell state, beside the run's markers; until 2026-11-23 they were `system_update_favorites.json` in the repo's root, copied over once at the first start).
- Answer yay's and pacman's questions in the card (one at a time): the packages to exclude and the PKGBUILD edit as a numbered-list field
  with the tool's own hint and an apply button; clean build, diffs, proceed, skip-dependency and plain yes/no as a pair of buttons with the
  default in the accent. The same questions can arrive as a notification card.
- sudo's password is never asked in the popup: it goes to the shell's authentication toast (face or password); the card says
  "Authenticating..." while Howdy or PAM waits.
- Verbose terminal: the real output, in kitty's palette so it reads like a kitty window in either theme; select, Ctrl+C to copy, wrap toggle.
- Snapshots (optional, [snapshots.md](snapshots.md)): when the shell has the snapshot service, a run that the rule says needs one (40 or more
  packages, or a critical one) gets a **Snapshot** notch on the rail after the download. The pre-transaction hook takes the snapshot; the
  card says it is being taken, with its percent, and the operation line names what it is for ("linux, mesa and 110 more"). Under the idle card
  a line "Snapshot 3 h ago" (or "No snapshot yet") opens the snapshots page, the popup's side page, where each snapshot has an Undo that
  starts an undo run (`pacman -U` of the old files, shown like an update run but never counted as the last success).
  When a snapshot cannot be taken, the update stops before anything is installed and the card says "No snapshot, so nothing was installed"
  with the reason (disk space, too large, too slow, another snapshot, or a failure); its button "Update without it" runs the update once without
  one. Undo of the whole feature: `uninstall.sh` (snapshots.md "How to undo it"); without the service the popup has no notch, line or page.
- While a run goes silicon holds the Performance profile and puts the previous one back after it (`silicon.md`).

## What it shows and where the data comes from
| Part | Source |
|---|---|
| What is waiting | `checkupdates` (joined against `pacman -Sl` for the repo), `yay -Qua --aur`, `flatpak remote-ls --updates` (skipped without flatpak), in parallel |
| When it looks | one poll 15 minutes after the last check ENDED (whoever started it), when a popup opens on numbers older than 5 minutes, and when a run ends; a check in flight is joined, not doubled |
| The run | `helpers/update-run.sh` starts `yay -Syu --sudoloop` detached under `script(1)` in a run directory (`transcript.log`, `timing.log`, `stdin.fifo`, `run.json`, `exit`); the shell only tails the transcript and writes answers into the fifo |
| Questions' sudo | `helpers/sudo-askpass` is yay's sudo, so every sudo call asks the askpass socket that the shell answers through its authentication broker |
| The run's marker | `~/.local/state/lares/system-update/last-run.json` (`running` or `finished`) beside `last-success.json` and `view.json` |
| Logs | the raw transcript, its timing and `ui-state.jsonl` (what the popup believed) of every run, under `~/.local/share/system-update-logs/runs/<stamp>/`; the newest 30 runs are kept, older ones pruned as a new run starts (`helpers/update-run.sh`) |
| Package upstream page | `pacman -Si` / `yay -Si`, only when an expanded row's icon is clicked |
A shell that starts while a run is going reattaches to it. Not live (a mock shell, a mockup) the service replays a captured transcript
through the same parser and shows a simulated set of updates; nothing starts yay, pacman or checkupdates. `helpers/update-attach.sh` is
the way to watch or answer a run from a plain terminal when the popup cannot.

## Settings
`~/.config/quickshell/config/system_update.jsonc` (template `.examples/system_update.jsonc`, read hot; a file that does not parse keeps the
previous settings):
- `icon.accentAt` (1): the count at which the icon turns from the muted ink to the accent; a whole number, 1 and up.
- `icon.warnAt` (30): the count at which it turns from the accent to the warn colour; a whole number, not below `accentAt`.
- `icon.errorAt` (150): the count at which it turns to the error colour; a whole number, not below `warnAt` (steps out of order are all
  three defaults). The old key `dot` is no longer read; the log says so when a file still has it.
- `check.everyMin` (15; 0 = only when asked), `check.staleMin` (5): the idle poll, and how old the numbers may be when a popup opens.
- `check.official`, `check.aur`, `check.flatpak` (true): a source that is false is never asked and never listed.
- `view` ("quiet"): the view a popup opens on when no update runs (`"normal"`, `"verbose"`, or `"last"`: the one it was left in); a run keeps its own.
- `list.groupMin` (3; 0 = no groups) and `list.open` ([]: the categories whose lists are open, or `"all"`).
- `run.flags` (["--sudoloop"]): what is handed to yay after `-Syu`, each a flag of its own.
The count is the status count: a group of three or more packages of one repo sharing a prefix counts as one; the popup and the lock
screen show the real number of packages. The popup's look, the rail, the list scales, the swipe numbers and the prompt are tuned in
`mockups/system_update.qml` (`quickshell -p ~/.config/quickshell/mockups/system_update.qml`; Save writes the module); its Run tab runs a
mock run (scrub, speed, fail at a step), replays a captured transcript through the real parser, or runs the real command behind a
confirmation.

## How it is built
| Path | Role |
|---|---|
| `modules/bar/system_update/SystemUpdateBarOwner.qml`, `components/SystemUpdateIcon.qml` | the button, the popup's door, the remembered view; the icon |
| `modules/bar/system_update/SystemUpdateService.qml` | the service, once per shell: backend, parser, logger, available updates, progress, recorder, the askpass pair, the view memory, the dot's thresholds; `live` is its safety switch (false replays) |
| `components/TerminalBackend.qml` | reads the run's transcript, parses ANSI colours, keeps a screen model for cursor-addressed rows, writes answers; stops with Ctrl-C |
| `components/PackageUpdateParser.qml` | the headless state machine over the output: phase, counters, packages, hooks, errors, prompts (`docs/contracts/system_update_phases.md` is its reference) |
| `components/SystemUpdatePopup.qml` | the popup: status card, prompt banner, rail, list, terminal, the three views |
| `components/UpdateCategorySection.qml`, `UpdatePackageRow.qml`, `FromToPair.qml`, `UpdateGroups.js`, `PackageIcons.qml` | the carved category list, a row, the version pair, grouping, the icon registry |
| `components/TerminalView.qml` | the verbose terminal (frozen history plus a live tail, so a hidden view costs nothing) |
| `components/AvailableUpdatesService.qml`, `PackageUrlOpener.qml` | what is waiting; a package's upstream page |
| `components/SystemUpdateProgress.js`, `SystemUpdateWork.js`, `SystemUpdateRunProgress.qml` | the whole run as one figure and a phase mark for the icon |
| `components/SystemUpdateLogger.qml`, `UiStateRecorder.qml` | raw-log rotation (the two newest of a replay), the transcript beside what the popup believed |
| `modules/common/components/MockUpdateRun.qml`, `tools/system_update/replay_yay_log.sh` | the synthetic run and the replay of a captured log |
| `helpers/update-run.sh`, `update-attach.sh`, `sudo-askpass` | the detached supervisor, the terminal attachment, yay's sudo; `helpers/system_update_helper/` is a Rust libalpm event-stream tool nothing in the shell uses |
Shared parts used (`modules/common/components`): `ShadowBox`, `RaisedButton`, `PhaseRail`, `DownloadStats`, `ListSkeleton`,
`ListSectionHeader`, `AnimatedListRow`, `RowFlight` (the favourite's flight), `TabSelector` (the views and their swipe), `HoverTip`, `Chevron`,
`BoundaryClock` and `RelTime` ("checked 5 min ago"), `FavoritesStore`, `AskpassServer`. The service is built once per shell and shared by
every screen's owner.

## Limits
- The transaction belongs to the supervisor, not to the shell: closing the popup, restarting the shell or reloading its config does not
  touch it. The popup has no stop button; a run is ended from a terminal with `helpers/update-attach.sh --abort` (Ctrl-C).
- yay's output is read by rules. A line shape the parser does not know falls into the nearest phase, so a new yay version is checked by
  replaying a real capture (`tools/system_update/replay_yay_log.sh`).
- pacman prints `error: failed retrieving file` for every mirror attempt; the popup counts that as a notice (kind "mirror"), and an
  error is only what ends the transaction (`failed to commit transaction`) or a non-zero exit.
- Kernel and initramfs work are hooks, not a phase: they are shown as the operation line inside Install and Hooks.
- A package whose upstream URL `pacman -Si` / `yay -Si` cannot give opens its archlinux.org search or its AUR page instead.

## How to change it
- The icon's colour steps: `icon.accentAt` / `icon.warnAt` / `icon.errorAt` in `system_update.jsonc`.
- A popup colour or size: the properties at the top of `SystemUpdatePopup.qml` (`normalMinWidth`, `verboseMinWidth`, `tabSelectorWidth`,
  the prompt and rail numbers), tuned in `mockups/system_update.qml` and saved there.
- How often it looks: `pollIntervalMs` in `SystemUpdateService.qml`; what it looks at: `AvailableUpdatesService.qml`.
- A package icon: `PackageIcons.qml`; a repo's colour: `AvailableUpdatesService.categoryOrder` and the theme's `cat*` tokens.
- A new yay question: `PackageUpdateParser.qml` (the prompt kinds) and the card in `SystemUpdatePopup.qml`.
Gate: `tools/dev/smoke.sh mockups/system_update.qml`; with a real capture, `tools/system_update/replay_yay_log.sh <log>` feeds the parser the way a run does.
