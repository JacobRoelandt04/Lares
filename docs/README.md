# Lares: the pages

One page per part of the shell: what it is, where it lives, what you can do with it, where its data comes from, its settings, how it
is built, its limits, and the few small changes people make most, with the file to open and the check to run. The `contracts/`
folder holds the technical contracts (the fixed names modules and the engine rely on), for whoever changes the code underneath.

## How to change something

- **Settings you edit by hand** live in `~/.config/quickshell/config/<name>.jsonc` (comments allowed; a file not moved there yet is
  still read one level up). Each has a commented example in
  `~/.config/quickshell/.examples/<name>.jsonc` that lists every key with its default: copy the keys you want to change, keep only
  those. Most are read again the moment you save; each page says when one is not. A mistake (a mistyped key, a value out of its range, a
  missing comma) is said in a toast as you save, with its line; `lares config` checks every file from a terminal, `lares config set` lists
  what you changed, `lares config find <word>` finds a key. In VS Code every key completes and explains itself as you type.
- **Look and motion** (sizes, colours, timings, curves) are tuned in a module's mockup, which shows the module on a stage beside a
  control panel: `quickshell -p ~/.config/quickshell/mockups/<id>.qml`. The panel's **Save** writes the changed values into the
  module's own code. Each page names its mockup.
- **Colours** are never written into a component: every colour is a token of the theme (`theme.md`). A colour changed on a mockup's
  theme rows is saved into the theme file.
- **After a change**: `tools/dev/smoke.sh <file.qml>` loads a file and fails on any warning; `tools/shell/lares preview` shows the
  shell on mock services in a nested window; commit, then `tools/shell/lares deploy` puts the commit on the desktop (the shell runs
  from a snapshot of a commit, never from the working tree).

## The frame

| Page | What it is |
|---|---|
| [shell.md](shell.md) | the bars, the islands, the popups that grow out of them, the keys, `shell.jsonc`, and running the shell with `lares` |
| [theme.md](theme.md) | the light / dark themes, the theme button and popup, `themectl` for the whole desktop, the curtain |
| [tools.md](tools.md) | what is under `tools/`, `helpers/` and `llm_tools/`, and who runs each |
| [snapshots.md](snapshots.md) | system snapshots before large updates, Undo, the rescue entry in GRUB, the copy on Proton Drive (optional; `lares snapshot`, `lares setup` R5; contract [contracts/snapshots.md](contracts/snapshots.md)) |
| [session.md](session.md) | session restore: the windows and the terminals' programs come back after a log-out (off as shipped; `lares session`) |
| [new-machine.md](new-machine.md) | setting Lares up on a machine that has never run it: the steps in order, what differs per machine, the traps |
| [publishing.md](publishing.md) | the public copy: an export of `main` without the agents' notes, judged by the leak check (`lares publish`), pushed to a separate repository |

## The modules

In the order they stand on the top bar (ids as `shell.jsonc` names them):

| Page | Bar id | What it is |
|---|---|---|
| [power.md](power.md) | `power` | the power reel: sleep, power off, reboot, hibernate, log out, lock |
| [idle.md](idle.md) | `idle` | the idle reel (off, soft, normal, hard) and the sleep fade |
| [theme.md](theme.md) | `theme` | the theme button |
| [presets.md](presets.md) | `presets` | saved desktops: load a whole arrangement of windows by name (the Presets tab of the panorama popup) |
| [oledcare.md](oledcare.md) | `oled` | the OLED burn-in protection (a switch in shell.jsonc, no bar button) |
| [notes.md](notes.md) | `notes` | plain-text markdown notes as tiles, with a live-preview editor |
| [llm.md](llm.md) | `llm` | the chat with a local language model (Ollama), with tools |
| [windowtray.md](windowtray.md) | `windowtray` | the focused window's title, and the system tray behind it |
| [weather.md](weather.md) | `weather` | the weather now, the next 48 hours and 16 days |
| [clock.md](clock.md) | `clock` | the time, the workspaces groove, the calendar, timers and alarms |
| [stocks.md](stocks.md) | `stocks` | the portfolio, the markets and each stock |
| [player.md](player.md) | `player` | the music player (mpd), a record on a platter |
| [audio.md](audio.md) | `volume` | the volume and microphone pill, and the sound mixer |
| [aerial.md](aerial.md) | `aerial` | the network: Wi-Fi, cable, hotspot, Bluetooth, the tunnel (the old `network`) |
| [bridge.md](bridge.md) | `bridge` | the phone: its screen mirrored, its storage mounted, files sent, on a phone you can turn over |
| [panorama.md](panorama.md) | `panorama` | the displays: a plugged display just works (Hyprland applies the saved setup itself), then arrange it on a canvas |
| [silicon.md](silicon.md) | `silicon` | the battery, the CPU profile and the GPU mode, on a little motherboard |
| [system_update.md](system_update.md) | `update` | the Arch system update |
| [notifications.md](notifications.md) | `notifications` | the notification server: toasts and the manager behind the bell |

Without a button of their own:

| Page | What it is |
|---|---|
| [launcher.md](launcher.md) | the application launcher (Alt+Space) |
| [clipboard.md](clipboard.md) | the clipboard shelf (Alt+V) |
| [picker.md](picker.md) | emoji, symbols and Nerd Fonts icons on Alt+Period (replaces rofimoji): three tabs, one search, alt codes, icon names, recents, one skin tone |
| [osd.md](osd.md) | the on-screen display for volume, brightness, keys and events |
| [auth.md](auth.md) | the password card for polkit and sudo |
| [lockscreen.md](lockscreen.md) | the lock screen and its veils |
| [screentime.md](screentime.md) | the record of where the machine's time went (the clock's Screen tab) |
| [wiki.md](wiki.md) | one article a day, on the calendar, the lock screen and an empty manager |
| [dictation.md](dictation.md) | speech to text into the focused field on fn+F10, a spoken question to the local model (a prototype, off until shell.jsonc turns it on) |

## Requests

`requests/` holds the user's own open requests, as written: [requests/window_container.md](requests/window_container.md) (a popup
that would hold a real window) and [requests/oledcare.md](requests/oledcare.md) (the OLED-care question, the user's text; the
module's page is [oledcare.md](oledcare.md)).

## Contracts (for developers)

The names a module, the engine or a tool relies on, fixed so parts can change independently. Read the one for the code you touch.

| Contract | What it fixes |
|---|---|
| [contracts/gooey_engine.md](contracts/gooey_engine.md) | the popup engine: bodies, slots (the popup, its child chain, the lane, the OSD, the reel), the content contract |
| [contracts/shell.md](contracts/shell.md) | the shell assembly: the services, the owners in shell-hosted mode, the keys, the settings pipeline |
| [contracts/shell_round2.md](contracts/shell_round2.md) | the shell's later names: the scale, a key-opened popup over a fullscreen window, the open / travel cost, notification sources |
| [contracts/mockup_framework.md](contracts/mockup_framework.md) | how a mockup and its control panel are built, and what Save writes |
| [contracts/theme.md](contracts/theme.md) | the theme's layers, the token names, how components read colours |
| [contracts/gestures.md](contracts/gestures.md) | two-finger swipes: how a swipe is read and held |
| [contracts/list_animation.md](contracts/list_animation.md) | how a list expands, collapses and swaps |
| [contracts/performance.md](contracts/performance.md) | the performance measurements and the harness in `tools/dev/perf/` |
| [contracts/system_update_phases.md](contracts/system_update_phases.md) | the phases of a `yay -Syu` run the update's parser follows |
| [contracts/auth.md](contracts/auth.md) | the auth broker, its sources and the card |
| [contracts/clipboard.md](contracts/clipboard.md) | the clipboard's processes, store and popup |
| [contracts/launcher.md](contracts/launcher.md) | the launcher's service and popup |
| [contracts/lockscreen.md](contracts/lockscreen.md) | the lock process, its state, the socket protocol, the lock popup |
| [contracts/notifications.md](contracts/notifications.md) | the notification service, the toasts, the manager |
| [contracts/osd.md](contracts/osd.md) | the OSD's kinds, requests, service and owner |
| [contracts/screentime.md](contracts/screentime.md) | the screen-time daemon's socket and data |
| [contracts/silicon.md](contracts/silicon.md), [contracts/silicon_helper_protocol.md](contracts/silicon_helper_protocol.md) | silicon's service and popup; the root helper's wire protocol |
| [contracts/wiki.md](contracts/wiki.md), [contracts/wiki_api_notes.md](contracts/wiki_api_notes.md), [contracts/wiki_jev_api.md](contracts/wiki_jev_api.md) | the wiki's service and tool; the live APIs it reads, as measured |
| [contracts/windowtray.md](contracts/windowtray.md) | the window title and tray |

Contracts keep their own wording: they record why a name is what it is, so some of their sections read as the history of a decision.
