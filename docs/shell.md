# The shell

## What it is

The shell is the frame of the desktop: the bars along the edges of every screen and the popups that grow out of them, drawn as
one soft surface. The project is called **Lares** (until round 9 it was "the Quickshell desktop shell"); it is built on Quickshell
and keeps its `quickshell` binary and its configuration directory, `~/.config/quickshell`, which is the checkout. The bars, the notification server, the polkit agent, the tray, the power menu, the lock and the OSD are one
configuration, so every part shares one look, one theme, one scroll feel and one set of keys.

## Where it lives

Each screen gets the same layout (`modules/shell/ShellFrame.qml`):

- **The top bar**, 40 px: three islands (left, centre, right) with the wallpaper between them, or one continuous bar
  (`topMode`). It holds every button.
- **Three slim bars**, 6 px (right, bottom, left): the gap Hyprland leaves anyway. They hold no buttons; popups come out of them.

| Zone | Modules, left to right (ids as `shell.jsonc` names them) |
|---|---|
| left island | `power` `idle` `theme` `notes` `llm` `windowtray` |
| centre island | `weather` `clock` `stocks` |
| right island | `player` `volume` `aerial` `bridge` `panorama` `silicon` `update` `notifications` |

Where things come out: notes and the LLM out of the left bar near its top; the launcher, the clipboard and the picker out of the bottom bar's
middle; the OSD out of the right bar's middle; the toasts from the top bar's right end. Every other popup grows out of the
island under its button.

**Keys** (global shortcuts of the app id `lares`, `modules/shell/ShortcutRouter.qml`, bound in your `keybinds.lua`;
`lares binds` prints the lines and checks yours):

| Key | Does |
|---|---|
| Alt+Space | the launcher ([launcher.md](launcher.md)) |
| Alt+V | the clipboard ([clipboard.md](clipboard.md)) |
| Alt+Period | the emoji and symbol picker ([picker.md](picker.md)) |
| Alt+N | the notes ([notes.md](notes.md)) |
| Super+F2 | hides or shows all the bars on every screen |
| Super+L | locks the session, through the power reel's own path (the same command as the reel's lock: [power.md](power.md)) |
| Escape | closes the open popup; bound only while a popup is open (`modules/shell/EscapeBind.qml`), so Escape reaches the windows otherwise. What a popup is in the middle of goes first (an open menu, a rename, a confirm, a typed search); a popup's DETAIL (its side popup) goes with it on one press, or first with `"escape": "detail"` in shell.jsonc (`GooeyEngine.escapeDetailFirst`, the contents' `stepBack()`) |
| Super+Shift+S | a screenshot of a region (`tools/osd/shot.sh region`) |
| Super+Shift+F12 | restarts the shell from its snapshot (`lares restart`): the rescue when it hangs |

**A key that opens a popup plays its module's bar glyph**, as a hover would (`ShortcutRouter._keyFlourish`): the entry of that module in the flourish
registry on the screen the popup opens on (the focused one) plays its demo -- not on a key that closes, not while that flourish already plays, not for a
module with no glyph flourish (the launcher, the clipboard, the picker today). A module that gets a key later needs nothing when its flourish `group`
is its key's name (`notes` / `notes`); another group is one line in the router's `_flourishGroup`. The lock key plays every padlock through the power reel.
Proof: `tools/dev/idle_auto_causes_probe.sh` (its second harness, `tools/dev/qml/key_flourish_probe.qml`).

The volume, brightness, keyboard-light, media and lock keys belong to the OSD ([osd.md](osd.md)).

**IPC** (`quickshell ipc call shell <verb>`, in `modules/shell/ShellMain.qml`): `ping` (answers `ok`), `bars 1|0|toggle`, `toggle <owner>`
(the focused screen's popup of that owner, as its bar button would: `open` / `shut` / `none`), `theme` (the theme button's click), `status` (one line of
JSON: screens, services mode, polkit agent, notification server, tray, bars), `aura <palette> <group>` and `auraStop` (the aura,
below), `probe` and `census` (what the gates read).

## What you can do

- **Open a popup**: click a module's button. The popup grows out of the bar under it. Click the same button again, or press
  Escape, to close it.
- **Go to another popup**: click another button while one is open. The popup travels to it, along the bar or round a corner onto
  the next bar, and changes content on the way. There is one popup at a time.
- **Details**: some popups open a second popup from their side (a weather day, a stock, a tray submenu) and close it with themselves.
- **Reels**: hover the power or the idle cell in the left island and a strip rolls out with its choices ([power.md](power.md), [idle.md](idle.md)).
- **Hide the bars**: Super+F2. The windows take the room back; Super+F2 again brings the bars back. While the bars are hidden, and
  over a fullscreen window, a popup opens as a free-floating pill instead of hanging from a bar.
- **Swipe and scroll**: a two-finger sideways swipe across a popup switches its views or tabs where a module has them; every list
  scrolls with the same feel (a mouse notch glides, a touchpad follows the fingers and coasts).
- **Toasts and the OSD** make way for each other and for the open popup ([notifications.md](notifications.md), [osd.md](osd.md)).
- **While the session is locked**, the bars and the lock's own popup stay over the lock screen ([lockscreen.md](lockscreen.md)). Only the idle
  reel and the volume pill take the pointer there; the keys are the lock's.
- **When the shell starts** the bar shows nothing until it is whole, then appears in one frame: every island at its length, the reel cells
  drawn, the title read. Under the boot lock it waits for the lock's first word too (at most 5 s), so it is born locked: the title reads
  "New session", the clock's eye and the padlock shut; the lock's popup then comes out of it. The log says when and why
  (`LARES shown <output> <ms> ms after its first frame (<why>)`).

## What it shows and where the data comes from

- **One of everything** (`modules/shell/ShellServices.qml`): the notification server, the polkit agent, the player, the battery
  reader, the weather, the stocks, the OSD and the other services exist once however many screens there are, and every screen's
  modules are handed them. A service that is missing makes its feature absent; nothing else breaks.
- **Mock mode**: `SHELL_SERVICES=mock` swaps every service for its module's mock twin. Nothing is run, no D-Bus name is taken,
  no sound plays. The gates and `mockups/shell.qml` run this way.
- **Hyprland**: the focused screen comes from `hyprctl -j monitors` / `workspaces` and the event socket
  (`modules/common/system/FocusedScreen.qml`, one per shell); the room the bars take is set on each output
  (`modules/shell/HyprReserve.qml`); the bars' rounded joints are drawn to nest the windows' corners, read from Hyprland's
  `rounding` and `border_size` (`modules/shell/HyprJoint.qml`); the touchpad's natural-scroll setting is read so a swipe goes the
  way the fingers do (`modules/shell/NaturalScroll.qml`).
- **The aura** (a prototype, off by default): the halo round the shell lights up with a few flowing hues on some events
  (`modules/shell/AuraEvents.qml`) or on `quickshell ipc call shell aura accent all`.

## Settings

`~/.config/quickshell/config/shell.jsonc`, read by `modules/shell/ShellConfig.qml`. Every key is optional; the commented example
`.examples/shell.jsonc` is the full list, and every value in it is the default. A file that does not parse keeps the last good
settings, and the shell's log says the line and column.

| Key | Meaning | Default |
|---|---|---|
| `topMode` | `"islands"` or `"continuous"` | `"islands"` |
| `font` | the face of the shell's own text | `"Audiowide"` |
| `centre` | `"centred"` (centre island in the middle of the screen) or `"equal"` (both voids the same) | `"centred"` |
| `zones` | the modules of each island, in order; a module left out returns to its own zone | the table above |
| `islands` | fixed island lengths per output (`"eDP-1"`, `"default"`); a length left out follows the modules | `{}` |
| `outlets` | where notes and the LLM open: a bar and a place along it, 0 .. 1 | left bar, 0 |
| `scale` | `global` (the whole shell's size, 0.5 .. 4), `bar` and `popup` ratios, `popups` per popup, `pills`, `outputs` per output | 1, with silicon and aerial 1.35 and the LLM 1.1 |
| `shadow` | `mode` `"off"` or `"halo"`, `color`, `aura` | off |
| `border` | a ring just outside the surface: `false`, `true` (3 px), a width, or `{ width, color }` | `false` |
| `theme` | the theme button and the curtain ([theme.md](theme.md)) | the shell alone, no curtain |
| `icons` | `overrides` (an app's own picture) and `fallback` (the icon for an app with none) | `{}`, `application-x-executable` |
| `oled.enabled`, `oled.flourishes` | the OLED care's one switch (`enabled`: the pixel shift and the random flourishes, read hot) and the random flourishes: `idle` / `active` switches, their waits (`idleEveryS`, `activeEveryS`), and which glyphs take part (`glyphs`, by group or `group.glyph`) ([oledcare.md](oledcare.md)) | on, decorative glyphs only |
| `escape` | what one Escape takes while a popup's detail (its side popup) is open: `"all"` both, `"detail"` the detail first | `"all"` |
| `input` | the mouse: `sideButtons` (`"both"` / `"back"` / `"forward"` / `"off"`: hold one and move = a two-finger swipe, hold one and turn the wheel = one step sideways a notch), `sideClick` (a click = one step back / on), `sideGain`, `sidePointer` (`"hold"` / `"free"`), `notchPx` and `notchMs` (a wheel notch in a list); [gestures.md](contracts/gestures.md) section 6 | both, clicks on, 1, hold, 120 px in 140 ms |
| `hoverCursor` | the pointer changes over what it can act on (a hand, the beam on text, the resize arrows) in every window of the shell; `false` keeps the plain arrow everywhere (`modules/shell/cursor/`). The bridge's free look hides the pointer either way | `false` |
| `dictation` | speech to text into the focused field: the key, the model, the rules ([dictation.md](dictation.md)) | off |
| `modules` | a module that is off is not loaded: `{ "silicon": false }` means no service, no button, no popup, no key, no prewarm, no process. `power` `idle` `theme` `notes` `llm` `weather` `stocks` `player` `volume` `aerial` `bridge` `panorama` `silicon` `update` `clipboard` `picker` `wiki` `screentime`; the clock, the window title with the tray, the notifications and the launcher are always there; the picker goes with the clipboard. Read ONCE, at the shell's start (`lares restart`); only an exact `false` counts, anything else is said in the log (`tools/dev/shell_modules_probe.sh`) | all on |
| `geoclueAgent` | `lares start` starts geoclue's demo agent at login for the weather's location, unless one runs (read by `tools/shell/lares` only) | `false` |
| `workarounds.fileRoot` | the shell's body is loaded from a `file:` URL and compiled QML is kept in `~/.cache/lares/qmlcache` (a warm start reaches its first QML line in ~1.2 s instead of ~5; Qt checks every unit by content, so a deploy recompiles only what changed). `false` is the old path (every file on Quickshell's `qs:` scheme, compiled at every start). Read by the supervisor at each start of the shell (`LARES_FILE_ROOT=0`), since the choice is made before any QML exists | `true` |
| `workarounds.gcAtScreenBuild` | collect once as each screen's window is built: the cure for Qt 6.12's collector losing live objects when a cycle starts inside that build (`tools/dev/qt_gc_attach_probe.sh`); acts at the next start of the shell | `true` |
| `workarounds.visibleInk` | each bar window tells Hyprland where it can have ink (hyprland_surface_v1's visible region: the bars' edges, the popups, toasts and OSD that are out, with their halo, ring and joints, and any field tile outside those), so the compositor blends that and not the whole output under every frame of the shell; the whole window while the theme switches, the lock holds, a glyph's flourish plays, a popup floats over a fullscreen window or Panorama identifies (`modules/bar/gooey/GooeyInk.qml`, `modules/common/system/InkWhole.qml`; gate `tools/dev/visible_ink_probe.sh`); hot | `false` |
| `workarounds.mpdResumeSeek` | the player seeks a resumed song back to where it paused (mpd 0.24 skips a piece on resume); hot | `true` |
| `debug.frameJournal` | write missed frames to `~/.local/state/lares/perf/frame-journal.jsonl` | `true` |
| `clicks` | what a right or middle click on a bar button does: `"none"`, `"popup"`, a word of that button (`"next"` on the player, `"dnd"` on the bell, `"timer"` on the clock ...) or a command as a list; nothing while the session is locked (`modules/shell/BarClicks.qml`, a catcher per `ModuleSlot`) | as shipped |
| `clickAway` | the popups a click outside closes (the engine's void catcher; no keyboard grab) | `[]` |
| `bars.outputs` | which displays get the bars: `"all"`, `"internal"`, or connector names (`"!"` leaves one out); never none | `"all"` |
| `flourishes.hover`, `flourishes.key` | the bar glyphs' flourishes played by a hover, by the key that opens a module's popup (the OLED care's random ones are `oled`) | `true` |
| `oled.shift`, `oled.shiftEveryS` | the pixel shift apart from the random flourishes, and its step | `true`, `240` |
| `shadow.auraEvents` | which events light the aura (`llm`: the least seconds of an answer, or `false`) | all four |
| `terminal` | the terminal a launcher app or script that wants one runs in | `["kitty", "-e"]` |
| `recorders` | programs that count as a screen share while they run | `wf-recorder`, `wl-screenrec`, `wayvnc` |
| `workarounds.mpdResumeSeek` | the player seeks back after mpd 0.24 skips on a resume | `true` |

The outlets (`outlets.notes` / `.llm`): a slim bar (`"left"`, `"right"`, `"bottom"`) and a place along it, or `"top"`: under the module's own button.

**What was refused** in any of these files is said: one toast per file as you save it (the line, the key, why; it goes when the file is right),
and `lares config` prints the same for every file (`lares config set`: what you changed; `lares config find <word>`: the keys about it). VS Code
completes and explains every key (`.examples/schema/`, mapped by the repo's `.vscode/settings.json`; another editor: a `"$schema"` line at the
top of the file naming `../.examples/schema/<name>.schema.json`). The checks are one spec per file, `modules/common/config/specs/<name>.js`
(`docs/contracts/shell.md`, "The config specs").

Times and dates are written as `~/.config/quickshell/config/locale.jsonc` says (`timeFormat`, default `"HH:mm"`; `dateFormat`, default
`"dddd d MMMM"`; example `.examples/locale.jsonc`), read by `modules/common/locale/LocaleConfig.qml`. Today only the LOCK follows it;
the shell's own times (the bar clock, timers, calendar rows, relative times, stocks, notifications) are written 24 h in their own
formats, so a 12 h `timeFormat` changes the lock alone.

The layout's numbers (the gap between modules, the least void between islands, the window title's slot, the workspaces' groove,
the halo's reach and softness) are constants, tuned in `mockups/shell.qml`; Save writes them into `modules/shell/ShellConfig.qml`.
The popup engine on its own is `mockups/bar.qml`.

## How it is built

| File or directory | Role |
|---|---|
| `shell.qml` | the entry: a stub (the pragmas, `LARES root file\|qs`) that creates `modules/shell/ShellMain.qml` from a `file:` URL, so Qt's QML disk cache serves every file (Quickshell's own `qs:` scheme is refused by it: 5 s of compiling at every start) |
| `modules/shell/ShellMain.qml` | the shell's body: one ShellServices, the keys, one ShellScreen per output, the `shell` IPC target, the ready line |
| `modules/shell/ShellServices.qml` | everything there is one of, live or mock, and the glue between screens (which popup is open where, the focused screen) |
| `modules/shell/ShellScreen.qml` | one screen's window (layer `lares-bar`): the first frame (the content held out of sight until the bar is whole), the theme crossfade, the reserve, the OSD's and the toasts' pills, the idle inhibitor |
| `modules/shell/ShellFrame.qml` | one screen's content: the engine, the bars, every module and its owner |
| `modules/shell/ShellLayout.js` | the geometry as plain functions: zones, island lengths, the bars, the reserve |
| `modules/shell/ShellConfig.qml`, `modules/shell/scale/` | `shell.jsonc` and the layout constants; the one scale |
| `modules/shell/ShortcutRouter.qml`, `EscapeBind.qml`, `KeyRelease.qml` | the global keys; Escape while a popup is open; letting the keyboard go when a window takes the focus |
| `modules/shell/HyprReserve.qml`, `HyprJoint.qml` (+ `.js`), `NaturalScroll.qml` | what the shell asks Hyprland or tells it |
| `modules/shell/CommandRunner.qml` | the shell's one way to run a program (records instead of running in mock mode) |
| `modules/shell/ReelItems.js`, `ReelActions.qml` | the two reels' items and what they do |
| `modules/shell/Theme*.qml` | the theme button, the theme switch and the curtain ([theme.md](theme.md)) |
| `modules/shell/OledShift.qml` | the OLED care ([oledcare.md](oledcare.md)) |
| `modules/shell/VolumeParity.qml` | the volume and microphone pill ([audio.md](audio.md)) |
| `modules/shell/perf/` | the frame journal |
| `modules/shell/cursor/` | `ShellCursor` (the `hoverCursor` setting) and `CursorCover` (the disabled area over each window that keeps the arrow while it is off) |
| `modules/bar/gooey/` | the popup engine: `GooeyEngine.qml` (where every bar and popup is on each frame), `GooeyBody.qml` (one popup slot), `GooeyBar.qml`, `GooeyField.qml` + `shaders/` (draws them all as one surface), `GooeyGeometry.js` (the shape rules), `GooeyMask.qml` (where the window takes input) |
| `modules/common/` | what every module shares: `components/`, `theme/`, `system/`, `icons/`, `locale/`, `scroll/` (KineticScroll + ScrollFeel; WheelArea + WheelHub + SideSwipe: the one wheel reader and the side buttons), `mockup/` (the mockup framework) |
| `tools/shell/` | `lares` and its supervisor, `lares-config.py` (what `binds` reads of your config; the one-time `cleanup-marks`), the root steps' files ([tools.md](tools.md)) |

The engine has one popup slot that travels, a spare for a jump with no bar to travel along, a chain of child popups (details,
submenus), the toasts' lane, the OSD slot and the reels' strip. A module talks to it through its owner (`<Module>BarOwner.qml`),
which builds the popup's content and is handed its services by the shell.

## Running it

The shell and the lock run from a **snapshot** of a commit (`~/.local/state/lares/{shell,lock}/current`), never from the
working tree, so an edit in progress never reaches the desktop. `tools/shell/lares` (details in [tools.md](tools.md)):

- `lares deploy [REV]`: a snapshot of a commit (default `HEAD`) for the shell and for the lock, and the running shell restarted
  on it (stop, `current` moved, start). It never touches a config file. Refused while a package update runs (`--force`).
- `lares start`: what Hyprland's autostart runs at login -- the shell under its supervisor, which restarts it when it exits and,
  when it keeps crashing, says so once (Hyprland's own notification) and tries again less often.
- **The watchdog** (supervisor, from the next login: a running supervisor keeps its old bytes): every 15 s it pings the shell over IPC; a
  shell that answers nothing for 90 s in a row (never within 120 s of its start or of a resume from suspend) is frozen, not busy. It saves
  the evidence under `~/.local/state/lares/stalls/<time>/` (log tail, every thread's state, a stack when `eu-stack` or `gdb` is installed,
  `hyprctl` layers / clients / activewindow; the last 5 are kept), kills the shell, restarts it like any exit (counted against the restart
  limit) and says so through `hyprctl notify`. If it ever fires, send that folder. `lares log stalls` lists them, `lares log last` shows the
  previous shell's log tail (`~/.local/state/lares/shell-last.log`, written at every shell exit; the runtime log dies at reboot).
  The shell names the supervisor its Yama ptracer at start (`PR_SET_PTRACER`, fail-open, ~25 ms), so only the supervisor's own children (the stack dump) may trace it. Proof: `tools/dev/lares_watchdog_probe.sh` (ARMs nowatchdog, noresume, noptracer). The rise watch in `ShellScreen` no longer remaps on a missing frame
  alone: it asks for a frame first, and a window remaps at most once per 10 s (`RemapRule.js`, `tools/dev/shell_remap_cases.js`).
- `lares restart`: the shell stopped and started again from its snapshot; Super+Shift+F12 runs it.
- `lares binds`: the lines the shell needs in your Hyprland config and how yours compare (missing, stale, conflicting); writes
  nothing. `lares setup` checks a whole machine the same way, the packages (`tools/shell/needs.tsv`), the portal drop-ins and the root steps
  included (printed, never run); on a terminal every command to run or line to paste is in bold blue (the terminal's palette slot 4), and
  piped or with `NO_COLOR` it is the plain text. `lares init` writes what a new machine's hardware asks for, once ([new-machine.md](new-machine.md)).
- `lares snapshot <verb>`: the SYSTEM snapshots (restic copies of /usr, /etc and the rest, taken before large updates; not the shell's own
  deploy snapshots above): `status`, `list`, `show`, `create`, `keep`, `delete`, `undo-plan`, `files`, `undo`, `rescue status`, and
  `offsite status|sync|verify|fetch|try` for the Proton Drive copy. It runs the tool of this tree as it is. `lares setup` has the optional row
  and the printed step R5 (never a TO DO unless `config/snapshots.jsonc` exists or the install is half done), and an informational row when
  `fstrim.timer` is off on an SSD. [snapshots.md](snapshots.md).
- `lares preview`: the shell on mock services in a nested Hyprland window; the desktop is untouched.
- `lares status` and `lares log`: what runs, and its log.
- `lares migrate-name` and `lares cleanup-old-name`: the one-time move to the name Lares and its end ("The name change", below).
- The rest (`apply`, `oled`, `session`, `update-running`, `cleanup-marks`, `panorama-import`, `fallback`): `lares help` lists every
  command with its arguments; `session` is in [session.md](session.md), `oled` in [oledcare.md](oledcare.md).

The lines your config holds for the shell (`lares binds` prints them with your paths):

| File | Lines |
|---|---|
| `autostart.lua`, inside `hl.on("hyprland.start", ...)` | the lock's `lares-lock-session --boot` first (it locks an autologin's session; behind a greeter that asked for the password it does nothing), then `lares start`, `themectl apply` (when `theme.apply` is `"themectl"`), `lares-lock-warm --if-stale` |
| `keybinds.lua` | the keys above, the OSD's keys, the dictation's four, and Super+Shift+F12 -> `lares restart` |
| `layerrules.lua` | `no_anim` for the shell's layer namespaces (`lares-bar`, `osd-pill`, `auth-pill`, `lares-curtain`, `toast-pill`) |
| `environment.lua` | `QS_CONFIG_PATH` = the snapshot's `shell.qml`, so a bare `quickshell ipc ...` reaches the shell |
| `hypridle.conf` | `lock_cmd` and `before_sleep_cmd` run the lock's `lares-lock-session`; `inhibit_sleep = 3` |

### The name change

The project's directories, commands and names changed with its name; an existing machine crosses once, in this order, and **the old
names keep working until the last step** -- a running shell, supervisor, lock and hypridle are never asked to stop:

| Step | What it does | What works between this step and the next |
|---|---|---|
| 1. `lares migrate-name` | moves what is ours to its Lares name -- `~/.local/state/quickshell/<ours>` -> `~/.local/state/lares/<ours>` (the snapshots, notifications, llm, wiki ...), the same under `~/.cache` and `~/.local/share`, the tool's own `~/.local/state/qs-shell` -> `lares/tool`, `~/.cache/quickshell-stt` -> `lares-stt`, the runtime dirs `qs-shell` -> `lares` and `qs-session` -> `lares-session` -- and leaves a **symlink at each old path**. Every move is ONE exchange (`renameat2`), so there is no instant in which an old path is missing. Quickshell's own directories (`by-shell`, `crashes`, `qmlcache`, and Qt's `qtpipelinecache-*`, `qtshadercache-*`, `_qt_*`) stay. Links `~/.local/bin/lares`, takes out `~/.local/bin/qs-shell` (when it is our link), copies `qs-ime` to `lares-ime`. The plan and a typed `yes` first | everything of the old name: the deployed shell, the old keybinds (they run the old snapshot through the symlinks), the lock. `lares` is on the PATH; `lares deploy`, **refused** (exit 4) until this step has run, works from here |
| 2. `lares deploy` | snapshots the commit; replaces a supervisor that runs under the old name (quickshell lists a shell by the path it was given, and the old supervisor gives the old path); places a one-line **shim** at each old entry-point name that a line of yours or an installed old root file still runs (`qs-shell`, `qs-lock-session`, `qs-lock-held`, `qs-lock-warm`), inside the snapshot, never in the repo | the old lines keep working through the shims: Super+Shift+F12, hypridle's lock, the boot lock. **Super+L, Alt+Space ... do nothing until step 3: do it right after** (the global shortcuts' app id is `lares` now) |
| 3. your lines | `lares binds` lists each one STALE with the line to use: the `quickshell:<x>` globals become `lares:<x>`, the autostart and the panic bind run `lares ...`, the layer rules take the `lares-bar` / `lares-curtain` namespaces, `QS_CONFIG_PATH` the new snapshot path; `lares setup` lists the rest (hypridle.conf, hyproled-toggle.sh, `~/.local/bin/hyprlock`, `~/.bashrc`). Then `hyprctl reload`, restart hypridle (or log in again). Rebuild screentimed (`helpers/screentimed`) and the dictation's venv (`tools/stt/setup.sh`) when `lares setup` asks | everything; the shims are redundant now, and the next deploy places none |
| 4. the root steps (`lares setup` prints them; R1 and R3 install files of the deployed snapshot, so they come after step 2) | install the Lares files **beside** the old ones: `lares-boot-lock` and `hyprland-lares.desktop`, then SDDM's `Session=` line; `/etc/pam.d/lares-lock` and `lares-lock-face` (copies of `qs-lock*`); silicon's polkit action `org.lares.silicon.helper` | the lock asks PAM for `lares-lock` once that file exists, `qs-lock` before; the next boot starts the lock from either snapshot |
| 5. `lares cleanup-old-name` | removes the symlinks and prints the root removal (`sudo rm -f` of the old PAM files, boot lock, session file and polkit files). **Refuses** while a line of yours, SDDM's `Session=hyprland-qslock`, the dictation's venv, a supervisor or a lock of the old name still names an old thing | the old names are gone |

The lock's last-resort hyprlock (its pinned config names the PAM service) is handed `qs-lock` while only the old PAM file is installed, so it
can always be opened. A lock of either name counts as "a lock is up" until step 5 (`lares-lock-held` reads both `lares-lock.lock` and `qs-lock.lock`; the
launcher and the supervisor refuse to start a second lock beside one). A deploy while a lock is up leaves the lock's snapshot as it is,
as always; a new shell does not see an old-name lock on its socket (`$XDG_RUNTIME_DIR/lares-lock/`), so the lock draws its own card
until it is unlocked. A system update's sudo askpass socket (`$XDG_RUNTIME_DIR/quickshell-askpass-update.sock` -> `lares-askpass-update.sock`)
follows the shell that serves it: do not deploy in the middle of an update.

### The portals between two sessions

The same notification ("xdg-desktop-portal-gtk failed", from the units source of the notifications module, whose `Show log` tail is
the journal of the unit) after a re-login is a real failed unit, not a shell fault. Hyprland's exit stops `graphical-session.target`
and leaves the user manager's environment on its dead socket (DISPLAY and HYPRLAND_INSTANCE_SIGNATURE unset, WAYLAND_DISPLAY and
XDG_CURRENT_DESKTOP put back). The manager outlives the logout by 10 s (`UserStopDelaySec`), and a client still dying in that gap
D-Bus-activates `xdg-desktop-portal`, which activates its backends; the GTK one has no `Restart=` and no display, fails five
times in 0.2 s (`cannot open display:`) and ends in `start-limit-hit`, so the new session's first Settings reads fail
("Could not activate remote peer ... startup job failed") for ~10 s. The frontend and the file chooser started in the gap also
keep a stale environment for the whole session. The fix is the user's, in systemd, not in the shell: a drop-in per portal unit,
`Requisite=graphical-session.target`, so a start request with no session up is refused (no process, no failed state, no
start-limit) and one inside a session runs as before. `lares setup` checks it ("portals in a session") and prints the line.

The folder opener: `xdg-open` of a folder falls to the first `inode/directory` registrant here (easytag), and xdg-utils' generic mode ignores `Terminal=true`, so yazi's own desktop file opens no window. `lares setup` (row "folders open in") prints one line that copies `tools/shell/applications/lares-yazi.desktop` (yazi in kitty, like Super+E) from the deployed snapshot into `~/.local/share/applications/` and makes it the default for `inode/directory`; lares never writes it itself. The drive card's Open does not use it (it runs `usb.openCommand`).

### The performance tour

`lares-perf-tour` (`tools/shell/lares-perf-tour`, `lares perf tour` once that verb is wired) replays ONE fixed scripted pass over the
running shell, marks its span and prints what the frame journal recorded for it, so two runs (before / after a change, boost off / on,
an old snapshot / a new one) are comparable. It is for the user's terminal on his real session: it refuses without a tty, while a
package transaction runs, and while the session is locked. Keep hands off the keyboard and pointer for about 2.5 minutes.

What it does, all net-zero: every owner's popup opened and closed (the global shortcuts `lares:launcher|clipboard|picker|notes`, and
`quickshell ipc call shell toggle <owner>` for the rest; a shell older than that call skips them with one line), three test
notifications posted and withdrawn, two throwaway kitty windows (`lares-tour-a` / `-b`: focus changes, title changes of different
widths, a width-neutral spinner-like title loop), a hop to an empty workspace and back, the OSD (volume and brightness up x3 then
down x3 through `quickshell ipc call osd ...`, the mic muted twice through the key's own global), the theme switched twice where the
shell can be told from outside (otherwise skipped). `lares-perf-tour --list` prints the script with its pacing, `--dry` checks the
environment, `--no-theme --no-windows --no-hop` leave a part out, `--label` names the run.

`--fresh` restarts the shell first (`lares restart`), times each start phase from `shell.log` (Launching config, `LARES shown`,
`LARES ready`, `LARES settled`, `LARES start` / `LARES prewarm` when the shell says them), runs a short tour the moment `ready` is
said (the first 30 s after a load, where the user meets the shell), then the full tour after `settled`. `--boost-ab` runs the full
tour twice and asks you to flip silicon.jsonc `interactionBoost` between the halves (it never edits your config; the printed lines for
a machine with no boost service are `boost_manual_lines()`). Energy: RAPL through `sudo -n` (run `sudo -v` first) and the battery's
energy delta.

Each tour writes `~/.local/state/lares/perf/tours/<stamp>.json` (marks, facts, per-action results, the report) and prints
`tools/dev/perf/frame_journal_report.py` cut to the span (`--since-ms/--until-ms`): frames, missed per 1000, the groups, RIGHT AFTER
LOAD. `lares-perf-tour compare A.json B.json` puts two side by side per group. The report no longer counts a window at rest (a gap of
a minute or more, or seconds with the GUI thread free: frozen, covered, locked) as frames missed. Gate: `tools/dev/perf_tour_probe.sh`
(the tour against the nested mock shell; ARMs badtoggle, notty).

## Limits

- One popup at a time (plus its details, the toasts, the OSD and a reel strip).
- The surface draws at most 12 shapes (bars and popups together); past that the OSD and the toasts lose their background first.
- The app icon theme is read when the shell starts: a changed icon theme shows after `lares restart`.
- The shell runs from its snapshot with `QS_DISABLE_FILE_WATCHER=1`: an edit to a `.qml` file reaches it with the next
  `lares deploy` of a commit that holds it; a change to `scale` shows after `lares restart`. The other keys of `shell.jsonc`
  apply when the file is saved.

## Retention

Every file the shell writes that would otherwise grow for ever, its limit and where the limit lives. The sweep is
`tools/shell/lares-sweep` (one table of rules at the top of the file: path, what counts as used, age, keep-N). The supervisor runs
`lares-sweep --daily` 60 s after it starts and every 24 h (one fork a day, niced; no Timer in the shell), and each run writes one
line per rule to `~/.local/state/lares/tool/lares.log`. By hand: `tools/shell/lares-sweep --dry-run` lists every path it would
delete and deletes nothing; `--rule <id>` runs one rule. A deploy restarts the SHELL, not the supervisor, so a change to the
supervisor (or to the sweep it runs) first acts at the next login (`lares start`).

"Used" is the newer of a file's atime and mtime (written, or read: a logo's Image, a chart's FileView). It holds on a `relatime`
mount (a read moves atime once a day); on a `noatime` mount the sweep skips the rules that go by atime and says so in the log.

| What | Where | Limit | Where the limit lives |
| --- | --- | --- | --- |
| System-update run logs | `~/.local/share/system-update-logs/runs/<stamp>/` | newest 30 runs, pruned as a new run starts; never the running one | `helpers/update-run.sh` `prune_runs` (`LARES_UPDATE_KEEP_RUNS`) |
| Launcher icon generations | `~/.cache/lares/launcher/icons/<theme>/p<hash>/` | a generation `current` does not name and nothing used for 90 days | `lares-sweep` rule `launcher-icons` |
| Stocks logos | `~/.cache/lares/stocks/logos/` | a symbol's files (and its index row) unused 90 days | `lares-sweep` rule `stocks-logos` |
| Stocks charts | `~/.cache/lares/stocks/charts/` | unused 90 days | `lares-sweep` rule `stocks-charts` |
| Wiki images | `~/.local/state/lares/wiki/img/` | named by no entry, live page or daily extra AND unused 90 days | `lares-sweep` rule `wiki-images` |
| Crash dumps | `~/.cache/quickshell/crashes/` | newest 10 | `lares-sweep` rule `crash-dumps` |
| Clipboard history | the clipboard store (`tools/clipboard`) | 1000 items, 30 days, 500 MB | the clipboard module's store |
| LLM conversations | the LLM module's state | 200 | the LLM module |
| Notification history | the notification service | 200 records, 7 days (pins kept) | `NotifyPolicy.retain` |
| Dictation takes | `~/.local/state/lares/dictation/takes.jsonl` | last 100 lines | `DictationService.qml` (the append) |
| Perf frame journal | `tools/dev/perf` | 1000 lines, rotated | the journal writer |
| `lares.log` | `~/.local/state/lares/tool/` | 2000 lines once past 1 MB | `lares` `trim_log` |
| `shell.log` (the running shell's output) | the state dir on `/run/user` | cut to its last tenth over 100 MiB, checked every 10 s | `lares-supervise` `cap_log` |
| Deploy and lock snapshots | `~/.local/state/lares/{shell,lock}/` | current + previous (+ the running supervisor's) | `lares` `deploy_prune` |
| Lock logs | the lock's state dir | 8 | `tools/lockscreen/lares-lock` `LOG_KEEP` |
| System-update cache | `~/.cache/lares/system-update-logs/` | 2 | the system-update service |
| Screen-time days, music art caches, STT models | their own dirs | none, by choice | (kept on purpose) |

## How to change it

- **Move a module** to another island or reorder one: edit `zones` in `~/.config/quickshell/config/shell.jsonc` and save.
- **Make everything bigger or smaller**: `scale.global` (1.25 is 25 % bigger), then `lares restart`.
- **A key, a layer rule, an autostart line**: `lares binds` prints the line; it goes in your Hyprland config by your hand.
- **One island or three**: `topMode`.
- **A layout number** (spacing, the title's slot, the halo): open `quickshell -p ~/.config/quickshell/mockups/shell.qml`, tune,
  Save. Then `tools/dev/smoke.sh mockups/shell.qml` and `node tools/dev/shell_layout_cases.js`.
- **After any code change**: `tools/dev/smoke.sh shell.qml`, then `tools/dev/shell_probe.sh` (the real shell in a nested Hyprland, never
  on the desktop), then commit and `lares deploy`. A change to how the bar comes up (ShellScreen's first frame, anything the bar shows at the
  start): `tools/dev/bar_boot_film.sh` (the boot under the lock, filmed: the first frame whole, "New session", an ordinary lock "Away").
  A change to the joint the windows' corners nest in (`modules/shell/HyprJoint.js`): `node tools/dev/hypr_joint_cases.js`, then
  `tools/dev/shell_joint_probe.sh` (a real tiled window against the shell in the nested Hyprland, shot over black and over white: no
  wallpaper between the two arcs, the window's border whole; `SWEEP=1` for other scales, roundings and borders).

Contracts (for developers): [contracts/shell.md](contracts/shell.md), [contracts/shell_round2.md](contracts/shell_round2.md),
[contracts/gooey_engine.md](contracts/gooey_engine.md).
