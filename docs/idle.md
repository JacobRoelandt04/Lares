# Idle

## What it is

The idle reel in the left island chooses what the machine may do when nobody touches it: dim the screen and then sleep, only dim the
screen, nothing at all, or not even sleep with the lid closed. Beside it, the shell makes the screen fall asleep gently before the machine
suspends and wake gently after.

## Where it lives

- **The idle reel**: the `idle` id in the left island, next to the power reel. Its icon is the mode selected; hovering it rolls out
  a strip with the four modes. The reel itself (how it turns, looks and resists) is the same component as the power reel:
  [power.md](power.md).
- **The sleep veil**: a window over every screen that exists only while the machine falls asleep or wakes.
- No keyboard shortcut and no IPC target of its own.

## What you can do

| Mode | Icon | What it does |
|---|---|---|
| `off` | sleep | **Idle allowed: dim, then suspend.** The shell dims the laptop panel exactly as in `soft` (same steps, levels, video pause and away rule) and holds nothing, so hypridle goes on to suspend at its 240 s listener (the lock and the sleep fade as ever). The mode the shell starts in. |
| `soft` | setting sun | **Dim, never blank.** hypridle's rules are held off (a Wayland inhibitor), and the shell dims the laptop panel itself: to `dimLevel` after `dimAfter`, deeper after `deepAfter`, and to the dim level after `awayAfter` with the focus on another output. It never blanks, locks or suspends, and gives the brightness back at the first input. Nothing dims while a video or anything else asks the screen to stay on. |
| `normal` | coffee cup | **No idle actions.** A Wayland idle inhibitor on every screen keeps hypridle's ordinary rules quiet -- through the lock, over a fullscreen window and across every remap of the bar's window (see "How normal holds"). Listeners marked `ignore_inhibit` (screen time's) still run. |
| `hard` | infinity | **No sleep at all.** A logind inhibitor blocks idle, sleep and the lid switch. Closing the lid puts the panel at 0 and opening it brings the brightness back over `lidRestore` seconds (a brightness key during the climb wins). |

- **Pick a mode**: hover the cell and scroll; the mode applies once the reel has rested on it (400 ms), so scrolling past a mode
  applies nothing. A click on the selected icon applies it at once.
- **When a mode is refused** (soft with no brightness script, a hard lock that could not be held) a notification gives the reason,
  and the reel turns back to the mode in force.
- **When something needs the machine awake the mode rises by itself** (the auto layer, `modules/idle/IdleAuto.qml`): the mode in force is
  the higher of yours and theirs (off < soft < normal < hard).

| Holder | Asks for | Why |
|---|---|---|
| content being watched (a browser's or player's request to keep the screen on: ScreenSaver D-Bus, a window's Wayland inhibitor, a `systemd-inhibit --what=idle` of another program) | normal | no dim, no suspend: the point is to see it |
| a system update run | soft | it may dim, it must never suspend mid-update (its own `systemd-inhibit` now holds sleep, shutdown and the lid, not idle) |
| the LLM answering | soft | an answer must not stall in a suspend |
| a timer counting (countdown, pomodoro phase, stopwatch; paused ones ask nothing) | soft | an alarm must ring on time |
| the player playing (mpd) | soft | the music would stop |
| the screen shared or recorded (a portal cast session: OBS, a browser's or Discord's share; or a wlr recorder's process: `wf-recorder`, `wl-screenrec`, `wayvnc`) | normal | others see the screen: no dimming under them. Outranks every soft cause by its mode |
| a wiki batch running (also the GPU-automatic ones, and the wait for the dGPU before one) | soft | the batch must not be cut by a suspend |
| a file being downloaded into the download folder | soft | the download would stall in a suspend |
| files being sent to a phone (the bridge's send, over the cable) | soft | the transfer would be cut by a suspend |
| a package job of someone else's (yay, pacman or an AUR build, run in a terminal) that has run 2 minutes | soft | the install would be cut mid-transaction |

  A holder counts after it has held for 3 s and stops after it has let go for 15 s, so a paused video or a quick answer does not
  make the reel dance. When the auto layer raises the mode, changes its cause or lets go, **the reel opens by itself, travels the
  long way round to the mode in force and closes**. When it raised the mode (or another holder took over at the same mode), **the
  reason pops out beside the strip** once the turn has landed -- a side popup to the right of the strip, level with its 3rd icon
  (one above the last), like the tray's name label: the cause in words, one bold line ("Firefox is playing video", "The LLM is answering",
  "Pomodoro running", "System update running", "Music playing", "Screen is being shared", "Wiki batch running", "Downloading
  ubuntu.iso", "Building foo (yay)", "Updating packages (pacman)"; the reel beside it shows the mode) -- and holds a reading pause of 4 s (on while the pointer is on the words, and at least 1.5 s
  after it leaves them) before it folds and the strip after it. **Hovering the idle reel while the auto layer holds the mode brings
  the reason out again** beside the open strip; it goes with the strip. The way back to your mode tells nothing (it is your own mode
  coming back), and a mode you picked shows no reason. **What a cause asks for is a floor, never a swap** (round 12): the mode in
  force is the higher of yours and the floor (`IdleService.floorMode`), read from the two sources in one expression, so the auto
  layer never lowers or overwrites a mode you picked -- a hard stays hard under a soft cause and is yours when the cause ends. While a
  cause holds, the selected icon keeps its colour and the reel takes a plain scroll or click **at or above the floor** (that is your
  mode then: the cause no longer raises it); a plain pick **under** the floor is refused: the reel does not turn, the icon shakes
  across the strip and the cause is told beside the open strip. **Hold Ctrl** to go below anyway: the holders of that moment are set
  aside until another one asks.
- **While the session is locked** the idle reel still takes the pointer, so a mode can be changed over the lock screen.

#### What counts as a download

A **partial file that still grows, in the download folder** (`xdg-user-dir DOWNLOAD`, top level only): a browser's `*.part` (Firefox,
Zen), `*.crdownload` (Chromium), `*.download`, yt-dlp's `*.part` / `*.ytdl`, aria2's `*.aria2` control file (and, while it stands, the
data file beside it, written in place). "Still grows" means a create or write within 10 s: a stalled or paused download stops counting
after that (and the auto layer lets go 15 s later), a finished or cancelled one at once (its partial file is renamed or deleted).
**Only a long one counts**: a partial file must have grown continuously for **2 minutes** (`DownloadWatch.minAgeMs`, 120000) before it holds
anything -- a small download ends before a suspend could hurt it (the user's call). Its age runs from the first write seen; a stall of
10 s or more resets it, so a resumed download earns its two minutes again. The on debounce (3 s) comes after that. The timer is still ONE
single-shot, armed for the earliest due instant (a young download coming of age, or a counted one stalling).
**Not seen**: a `curl -o` / `wget` to a path outside the folder, a download a browser saves elsewhere or in a subfolder, a torrent client's
own folder, a Flatpak browser whose download folder is another path. It costs one `inotifywait` on that folder: no polling of sizes.

#### What counts as a package job

A **pacman / yay / paru command line that is a transaction** (`-S` that is not a query, `-U`, `-R`; the restart guard's rule, see below), a
**`makepkg` build** (an AUR build compiles for minutes holding no database lock), and a **GUI package manager's lock** (pamac, PackageKit).
Not counted: `checkupdates`' `pacman -Sy --dbpath <a copy>` (the shell's own update check, every few minutes), `yay -Qua`, a search or a query. A
bare `yay` / `paru` counts (it is `-Syu`; `yay <term>` searches and then installs).

**Why not only `db.lck`.** pacman holds `/var/lib/pacman/db.lck` for its own transaction only: an AUR build (yay downloading, makepkg compiling, yay
at its prompts) holds none, and a crashed pacman leaves the file for ever. So `modules/common/system/pkgjobs.py` (ONE child of the shell, reading
`/proc` in its own process, 5 s apart, printing a line only when the picture changes: **no fork per look**, about 6 ms of CPU a look) hands the
process records and the lock's existence to `PackageJobRules.js`, and the lock alone is a job only while a GUI package manager's daemon runs.
The rule for "is this a transaction" is `pm_args_transact` in `tools/shell/lares` (the restart guard) ported to JS; **both are held to one table,
`tools/dev/pm_transact_cases.txt`** (the idle causes probe runs the bash function and the port over it): change the rule there first.

**Only a long job counts** (`PackageJobWatch.minAgeMs`, 120000, as for downloads: a short install ends before a suspend could hurt it). The age
runs from the first look that saw a job; no job at all for `gapMs` (15 s) begins a new one, so two chained commands are one job. The 3 s on
debounce comes after that, the 15 s off one after it ends.

**Words** come from the command line: `Building <pkg> (yay)` (the makepkg's directory), `Installing foo, bar (pacman)`, `Installing 3 packages
(yay)`, `Updating packages (yay)`, `Removing foo (pacman)`.

**The shell's own update is not this cause.** A job whose process tree has the update's supervisor (`update-run.sh`, pid from the update's
backend `attachPid`) among its ancestors is the shell's own run: it stays the existing cause `update` ("System update running", at once, as before)
and is never counted here. With a run going and its pid not known yet, no job is counted as someone else's. Decided from facts (the ancestry), not timing.

### How normal holds (and soft)

hypridle's 240 s suspend respects Wayland idle inhibitors, and **Hyprland decides whether one counts only at a recheck** -- a window
mapped, unmapped or focused, a fullscreen change, an inhibitor made or destroyed -- and only if the inhibitor's surface is then mapped,
takes input and is not faded out. Between rechecks its verdict stands, whatever happens to the surface. So the shell (ShellScreen's
IDLE HOLD, `modules/shell/ShellScreen.qml`):

- **holds one on every screen's bar window, made afresh for every surface the window gets.** The bar's window is remapped now and then
  (a popup opened over a fullscreen window that found the window stale), and a remapped layer window is a new surface: Quickshell 0.3.2's
  `IdleInhibitor`, kept for the window's life, could lose its inhibitor to the old window's deletion and never make another.
- **asserts it again when Hyprland says a shell surface has mapped** (`openlayer` of `lares-bar` / `osd-pill`): an inhibitor made for a surface
  that has not drawn yet does not count, and a map is no recheck. A fresh inhibitor is one.
- **holds one on the OSD pill's window while a fullscreen window covers the bar.** Under a fullscreen window the bar's layer is faded to
  nothing and counts for nothing at any recheck; the pill's window is on the Overlay layer, which a fullscreen window does not hide, and
  is mapped then anyway. Its letting go when the fullscreen ends is itself the recheck that counts the bar again (the fullscreen's own
  recheck reads the bar before it has faded back in).
- holds it **through the lock** (the user's decision of 2026-10-30): Hyprland counts an inhibitor on a layer drawn over the lock.

On 2026-11-10 the machine suspended under `normal` with the focus on kitty: the bar had been remapped under a fullscreen window and its
inhibitor was gone, and a fullscreen's end leaves even a live one uncounted until something rechecks. `tools/dev/idle_hold_env_probe.sh`
holds all of it on the real shell in the nested Hyprland, against an ext-idle-notify listener with a 4 s timeout ("How to change it").

### The sleep fade (every mode)

When the machine is about to sleep, the shell waits for the lock's veil to be up, then dims the laptop panel to 0 while the sleep
veil closes over every screen (the picture defocuses, splits its colours and sinks), and only then lets the machine sleep. On waking
the panel climbs back at the same pace while the veil opens; typing works at once, and an unlock skips the rest of the climb. If the
suspend hangs on its way in, a watchdog (`modules/idle/sleep/sleep_guard.py`) gives the light back.

**The brightness the climb returns to is the user's, not the dimmed one.** In `off` the panel has already been dimmed twice (soft's steps at 2 and
3 minutes) when hypridle's 240 s suspend comes, so at the sleep the panel reads the deep value. The fade takes the level to give back from
the brightness script's state file when it exists (`stateFile`: SoftIdle saved the brightness it found there BEFORE it dimmed, the value a
`--resume` would restore), else from the panel. When the climb has landed (or a brightness key took over, or an unlock skipped the rest, or the
guard lit the panel) the fade tells SoftIdle (`gaveBack` -> `SoftIdle.panelGivenBack()`): its level goes to 0, the state file goes, and the
idleness it heard before the sleep is over, so the next dim saves the full value again. `tools/dev/sleep_dim_probe.sh` holds it (below).

The veil's picture is a capture of the screen, checked before it is used (`PictureProbe` in `modules/common/components/`, shared with
the lock's still): a copy that came out empty -- all transparent or all black, which the veil would draw as a black screen for most of
the fall and of the wake -- is taken again with a fresh capture, up to three times, each one logged `LARESSLEEP <screen> <ms> picture
empty (<n>)` in the shell's log; after that the veil goes on without a picture (the vignette and the light over the live screen).

## What it shows and where the data comes from

- **Input and idle times**: Wayland idle notifications, read by `modules/idle/SoftIdle.qml`.
- **Who asks the screen to stay on** (`modules/idle/ContentHold.qml`): browsers' requests to `org.freedesktop.ScreenSaver` (read with
  `dbus-monitor`), windows holding a Wayland idle inhibitor or an `idle_inhibit` rule (`hyprctl -j clients`), and logind idle
  inhibitors (`systemd-inhibit --what=idle`).
- **Brightness**: `brightnessctl`, and the user's own brightness script (`script`), whose `--resume` gives back the saved value.
- **External displays** (`modules/idle/DdcDim.qml` + `DdcDimRules.js`; a desktop has no panel to dim): the same idleness, the same two steps, sent
  as ONE DDC write each (about 0.3 s on a quick monitor) through the displays service's one lane (`PanoramaService.ddc*`, so the module `panorama`
  must be on). Before the first step the display is read afresh and its figure saved in `~/.local/state/lares/ddc-dim.json` under its identity (make,
  model, serial); the first input writes that figure back, a brightness key pressed as that input keeps its step, and a display that was switched
  off, replugged elsewhere or did not answer (after a resume) gets its own figure the moment it does -- a restarted shell included. On a machine with
  no panel `soft` needs no brightness script. Gate: `tools/dev/ddc_dim_probe.sh` (6 ARMs), `idle_mode_probe.sh`'s desktop run.
- **Which backlight is the panel's** (`modules/common/system/PanelBacklight.qml` + `PanelBacklightRules.js`, the ONE rule): the backlight of the GPU
  that DRIVES the eDP (`/sys/class/drm/card*-eDP-*` -> its card's `driver`): Hybrid (i915 / xe) the raw `intel_backlight`, dGPU-only (nvidia) `nvidia_0`
  (brightnessctl max 100). A stray `nvidia_0` in Hybrid is never picked (writing it correlated with the suspend hangs). Where the driver cannot be
  read: the non-NVIDIA backlight, else the only one; nothing found is "no device" and every consumer behaves as before with none. Re-read at the start,
  at 2, 5, 15 and 45 s while none was found (nvidia_0 registers late) and on every resume. SoftIdle, LidDim, SleepFade (and `sleep_guard.py`'s
  `device=`) and the OSD keys all take the device from it, and every brightnessctl call names it (`-c backlight -d <device>`; no bare call).
  **Where 0 is not black** (`zeroIsBlack`; the table says no for `nvidia_0`, yes for the rest; `idle.jsonc` `"zeroIsBlack": {"<device>": bool}`
  overrides it): "dark" is the lowest value written AND black drawn over the panel -- the sleep fade's veil dims the panel's picture itself, and the
  lid closed in hard idle asks the veil to HOLD the panel's output black (`SleepFade.lidHold`, phase `lidhold`) until the lid opens, when the climb
  takes over. The OSD's keys stop at the floor rung there (they never write 0). The user's own `brightness.sh` (hypridle's pre-idle / idle,
  `set 0`) is bare `brightnessctl`: on a dGPU-only boot that is nvidia_0 too, and its `set 0` is not black there.
- **The lid**: logind's `LidClosed` on the system bus, read only (`modules/idle/LidWatcher.qml`).
- **Sleep**: logind's `PrepareForSleep` signal and a sleep delay inhibitor the shell holds while it runs (at most logind's 5 s).
- **hypridle** keeps running in every mode; the modes decide what it is allowed to do. `hypridle.conf` has no brightness listener: the
  dimming is the shell's, and the 240 s listener suspends without a `--resume` first (the shell gives the brightness back at the first input,
  and the sleep fade owns the way down: a `--resume` there would flash the dimmed panel to full just before the lock's veil). The screentime
  listeners stay. `lares setup` checks its two locks (`lock_cmd`, `before_sleep_cmd`) and `inhibit_sleep = 3`.

## Settings

`~/.config/quickshell/config/idle.jsonc`, read while the shell runs (`modules/idle/IdleConfig.qml`, keys in `modules/idle/IdleConfig.js`).
The commented example `.examples/idle.jsonc` is the full list; every value in it is the default.

| Key | Meaning | Default |
|---|---|---|
| `dimAfter` / `deepAfter` | seconds without input until soft dims, then dims deeper (0 = never) | 120 / 180 |
| `dimLevel` / `deepLevel` | how bright the dimmed panel looks, as a share of before | 0.7 / 0.5 |
| `ddcDim` | dim the external displays over DDC too: `true`, `false`, or `null` = only on a machine with no laptop panel | `null` |
| `ddcDimLevel` / `ddcDeepLevel` | an external display's own brightness figure at the two steps, as a share of what it was | 0.35 / 0 |
| `awayAfter` | seconds with the focus on an external output until the laptop panel dims | 300 |
| `panel` | the laptop panel: the output whose name starts with this | `"eDP"` |
| `script` / `stateFile` | the user's brightness script and where it keeps the saved value | `~/.config/hypr/scripts/brightness.sh`, `/tmp/idle_backlight_value` |
| `brightnessctl` | the program that reads and sets the brightness | `"brightnessctl"` |
| `zeroIsBlack` | per backlight device, whether raw 0 turns the panel black (the shell's table: `nvidia_0` no, the rest yes) | `{}` |
| `lidRestore` | seconds the panel takes to climb back when the lid opens in hard mode | 2.5 |
| `sleepFade` | the sleep fade on or off (off: no sleep inhibitor is held) | `true` |
| `sleepFadeTime` | seconds of the fall and of the climb (or `sleepFallTime` / `sleepClimbTime` apart) | 1.5 |
| `sleepFadeStrength` | how strong the sleep veil's effect is (0 = the light alone) | 1 |
| `auto.<cause>` | the mode a cause raises to: `content`, `share` (normal), `update`, `llm`, `timer`, `wiki`, `bridge`, `download`, `pkg`, `music` (soft); `"off"`: that cause never counts | the table |
| `items` | the modes the idle reel offers (`off` always; the ladder's order whatever the list's). One left out is never in force: a start on it goes to the nearest offered mode below, a cause asking for it to the nearest offered above (none above: the highest). Read as the shell starts. A desktop with no lid has little use for hard: `["off", "soft", "normal"]` | all four |
| `start` | the mode the shell starts in, or `"last"`: the one you left in this Hyprland session (a restart of the shell keeps it, a new login starts at off; `~/.local/state/lares/idle-mode.json`) | `"off"` |
| `download.minMinutes` / `download.folder` | how long a download grows before it counts, and the folder watched (`""`: `xdg-user-dir DOWNLOAD`) | 2 / `""` |
| `packages.minMinutes` | how long a package build or install outside the popup runs before it counts | 2 |
| `autoTell` | how a change the auto layer made is shown: `"cinematic"` (the strip comes out, turns the long way and says why) or `"quiet"` (the cell turns; the reason is beside the strip when the pointer brings it out) | `"cinematic"` |
| `contentIgnore` | programs whose request to keep the screen on is NOT content (see below); your list replaces the default, `[]` ignores nothing | `["sdl-freerdp3", "sdl-freerdp", "com.freerdp.client.sdl3", "com.freerdp.client.sdl", "org.kdeconnect.daemon"]` |

### Programs that ask for the screen but are not content

SDL programs call `org.freedesktop.ScreenSaver.Inhibit` for their whole life, whatever they show (SDL's reason is "Playing a game"). FreeRDP's SDL client
(`sdl-freerdp3`, window class `com.freerdp.client.sdl3`) is one: opening the Windows VM's remote-desktop window raised the mode to `normal` by itself.
`contentIgnore` is a list of exact names (trimmed, any case, never a substring: `"sdl"` would swallow every SDL game) matched against all three
sources the content watch reads: the D-Bus holder's application name (what `LARES idle content holds: ...` prints), a window's class (the Wayland
inhibitor) and logind's `who`. A holder on the list holds nothing; the log says `LARES idle content ignored: sdl-freerdp3` once when it first
shows up, so you can see the list at work. A real game or a video still counts. To add a program, find its name in that log line (or `hyprctl -j clients`
for a window's class), then put the whole list in `idle.jsonc`; it applies at once.

`org.kdeconnect.daemon` is on the default list because KDE Connect's "Inhibit screensaver" plugin asks for the screen for as long as a phone
is CONNECTED, not while anything plays: with a phone always in reach the auto mode never let go ("org.kdeconnect.daemon is playing video",
2026-11-19).

The reel's look is tuned in `mockups/power.qml`; the whole shell with the idle mode it applies is `mockups/shell.qml`.

## How it is built

| File or directory | Role |
|---|---|
| `modules/idle/IdleService.qml` | the four modes: what each holds and releases, the user's mode (`selectedMode`) and the mode in force (`mode`), a refusal and its reason; `dims` is the ONE rule for where the panel dims (off and soft) |
| `modules/idle/IdleAuto.qml`, `IdleAutoRules.js` | the auto layer: the holders, their debounce, the override |
| `modules/common/system/ScreenShareWatch.qml` | THE screen-share reading, one per shell (ShellServices): read by the idle auto layer and by the toasts' holds (`NotificationHolds` keeps its own only when a mockup or probe hands it none) |
| `modules/common/system/DownloadWatch.qml`, `DownloadRules.js` | the download folder: one `inotifywait` (see "What counts as a download"), read by the idle auto layer |
| `modules/common/system/PackageJobWatch.qml`, `PackageJobRules.js`, `pkgjobs.py` | package jobs: the scanner child, the rules (what is a job, whose, its words, the 2-minute age), read by the idle auto layer (see "What counts as a package job") |
| `modules/bar/reel/ReelFollow.qml` | keeps the reel on the mode in force: the cinematic for an automatic change, a plain turn otherwise; puts the reason out beside the strip (the cinematic's reading pause, and under a hover while the auto layer holds) |
| `modules/bar/reel/ReelReason.qml` | the reason: the strip's side popup (the gooey engine's REEL CHILD), the cause, one bold line in the tray label's look, its height even so it sits on whole pixels about the 3rd icon's middle |
| `modules/idle/SoftIdle.qml`, `SoftRules.js` | the dimming rules of off and soft (and `panelGivenBack`: the sleep fade returned the panel to the brightness it saved) |
| `modules/idle/ContentHold.qml`, `ContentRules.js` | who is asking the screen to stay on (watched all the time for the auto layer: the window and logind reads every 15 s) |
| `modules/idle/LidWatcher.qml`, `LidRules.js`, `LidDim.qml` | the lid, and the panel at 0 while it is closed in hard mode |
| `modules/idle/IdleConfig.qml`, `IdleConfig.js` | `idle.jsonc` |
| `modules/idle/sleep/` | the sleep fade: `SleepFade.qml` (the sequence), `SleepVeils.qml` / `SleepVeil.qml` / `SleepCapture.qml` / `SleepVeilEffect.qml` (the veil per screen), `SleepRules.js`, `sleep_guard.py`, `shaders/` |
| `modules/shell/ReelItems.js`, `ReelActions.qml` | the reel's four items and what a pick does |
| `modules/shell/ShellScreen.qml` | THE IDLE HOLD: the idle inhibitor of `normal` (and `soft`) on each screen's window, afresh for every surface and again at every shell surface's map, and on the OSD pill's window while a fullscreen window covers the bar ("How normal holds") |

Shared: `modules/bar/reel/` (the reel), `CommandRunner` (every command; recorded instead of run on mock services).

## Limits

- The mode is not remembered: the shell starts in `off`.
- `shell.jsonc` `"modules": { "idle": false }`: no reel, no dimming, no hold of any kind; hypridle's own times are all there is.
- `soft` needs the brightness script; without it the mode is refused and says so.
- `soft` and `off` dim the laptop panel only; an external screen is left alone, and a machine with no backlight dims nothing (`soft` still holds the screen on). Where the dimming cannot run (no brightness script or no brightnessctl) `off` dims nothing and does not say so; `soft` is refused.
- A `hypridle.conf` that still has its own brightness listeners dims as well as an `off` shell: the two fight. The file is yours; nothing edits it.
- The lock and suspend times of `off` are hypridle's own (`~/.config/hypr/hypridle.conf`: suspend at 240 s), not this module's; the dimming times are this module's (`dimAfter` / `deepAfter`).

## How to change it

- **Soft's times and levels, the lid's climb, the sleep fade's speed**: edit `~/.config/quickshell/config/idle.jsonc` and save; it applies at
  once. Then `tools/dev/config_loaders_probe.sh`.
- **A mode's icon or label**: `modules/shell/ReelItems.js` (`IDLE`); what a mode does: `modules/idle/IdleService.qml`. Then
  `tools/dev/idle_mode_probe.sh` (each mode's dimming and holds on the mock service, with its ARMs), `tools/dev/smoke.sh shell.qml` and `tools/dev/shell_probe.sh`.
- **How normal's inhibitor is held** (ShellScreen's IDLE HOLD): `tools/dev/idle_hold_env_probe.sh` -- the real shell in the nested Hyprland, an
  ext-idle-notify listener that respects inhibitors (4 s), an app put fullscreen, a popup floated over it with the bar window REMAPPED (forced,
  in the old window's worst order), the fullscreen ended, all twice, and another client's recheck while covered; `ARM=all` breaks each part
  (`oneinhibitor` the old single inhibitor, `onegeneration`, `noreassert`, `nopill`) and each must let the listener idle.
- **What holds the mode up by itself**: the table `HOLDERS` in `modules/idle/IdleAutoRules.js` (and the fact's binding in
  `ShellServices.qml`); the debounce: `onMs` / `offMs` in `IdleAuto.qml`; the cinematic's pace: `ReelFollow.qml`. Then
  `tools/dev/reel_auto_probe.sh` (with its ARMs) and `tools/dev/idle_auto_causes_probe.sh` (the share, the wiki batch, the download and the package
  jobs, on the mock shell services, real files in a private folder and a fake `/proc`, with its ARMs `pkgnoage`, `checkupdates`, `double`).
- **What counts as a package transaction**: `tools/dev/pm_transact_cases.txt` first, then `pm_args_transact` in `tools/shell/lares` and
  `transacts()` in `PackageJobRules.js`; the idle causes probe holds both to the table.
- **The level the sleep fade gives back** (`SleepFade` `_read`, `SleepRules.parseLevel`, `SoftIdle.panelGivenBack`, `IdleService`'s `onGaveBack`): then
  `tools/dev/sleep_dim_probe.sh` (SoftIdle and SleepFade live on a stub `brightnessctl` over a fake backlight and a stub `--resume`: dim, deep,
  suspend, climb with silent monitors / the wake key heard before / after the climb / a brightness key during it, a plain suspend, no suspend; ARMs
  `oldsaved`, `nosync`, `nostatefile`, `keyloses`, `barectl`; it runs on a dGPU-only fixture tree and fails any brightnessctl call without `-d`).
- **The panel's backlight** (`PanelBacklight*`, `LidDim`, `SleepFade.lidHold`, `SoftRules`, the OSD's `BacklightSource`): `tools/dev/panel_backlight_probe.sh`
  (six fixture sysfs trees: Hybrid, Hybrid with a stray nvidia_0, dGPU-only, nothing, driver unreadable x2; the OSD key, the lid hold and SoftRules'
  argv on each; ARMs `hybridstray`, `barectl`, `nohold`).
- **The sleep fade**: `modules/idle/sleep/`. Then `tools/dev/sleep_lockenv_film.sh` (the real fade, its veil windows and a real lock in
  the nested Hyprland, several sleeps in one process -- the fade after the first is the one a first can spoil; `ARM=emptypic` makes
  every capture empty and the veil must go on without a picture, `ARM=emptypic,nocheck` takes the check out and must FAIL) and
  `tools/dev/picture_probe.sh` (the check itself, offscreen).
- **What `hypridle.conf` must say for the shell**: `lares setup` checks it (`hypridle_line_has` in `tools/shell/lares`); the
  deploy probe proves the check (`tools/dev/lares_deploy_probe.sh`, scenario `setup`).
- **How the reel looks and turns**: `mockups/power.qml`, Save.
