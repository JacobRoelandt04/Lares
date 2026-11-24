# Panorama: the displays

Plug a display in and it works; then arrange it in a popup. Hyprland applies your saved arrangements itself, from a file Lares
writes, so they hold from the moment Hyprland starts (boot lock, login) and through a crash of the shell. The plan and your 32
decisions: `docs/agent_added_files_and_folders/panorama/PLAN.md`. The measured Hyprland facts: `FACTS.md` beside it. The fixed
names: `docs/contracts/panorama.md`.

## What it does

- **A display you never connected before** is extended at once: placed above the laptop and centred, in its preferred mode, at a
  scale that shows things at the laptop's physical size, but never below 1 (a TV or projector gets Hyprland's own `auto`). It
  takes workspaces 3 and 4. A toast says so, with **Mirror**, **Only external** and **Arrange…**.
- **A combination you have arranged before** (laptop + this dock, laptop + that TV) comes back exactly as you left it, silently.
  A new combination grows from the largest one you saved: the known displays stay where they were and the new one goes on top.
- **A display you plug in turns on.** Switching a display off in its detail lasts until its cable is pulled (or the session ends): the
  next plug lights it again, whatever the saved setup said, and the setup is corrected. While a connected display is off, the popup
  says so ("<display> is off in this setup") with **Enable**. The laptop's own panel is different: "Only external" stays.
- **Four workspaces, always.** The new display shows its own workspace (3) the moment it is plugged; the extra one Hyprland makes
  for a new monitor is taken away at once, with no focus or pointer move. A mirror changes nothing.
- **Unplugging** says "<display> disconnected". Hyprland moves the workspaces over to what is left, and plugging back moves them
  back.
- **The safety rule**: if every screen that is on goes away (for example "Only external", then the cable is pulled), the laptop
  panel comes back at once.

## The popup

ONE popup with TWO TABS behind the one glyph (the user's decision, 2026-11-21): **Displays** (below) and **Presets** (the saved desktops,
docs/presets.md). Each tab keeps its own size (Displays 460 wide; Presets 596, or 304 while no preset is saved) and the popup morphs between them as the clock popup does
between Calendar and Timers: the tab row on top, the tab's own content under it, a switch is one step of size that the engine eases. A
click opens it **by situation**: Displays when a display besides the laptop's is connected or a mirror is up, Presets when only the
laptop's screen is there; "Arrange…" on a toast always opens Displays. A tab you pick (a click, or a two-finger sideways swipe anywhere
on the popup) is yours until the next click decides again. A tab is built when first shown. The glyph is always there; loading a preset
closes the popup and the glyph clears its windows and deals them again once. The displays service reads the monitors' DDC state and the panel's backlight only while
the Displays tab is on show.

### The Displays tab

- The **glyph** sits in the machine island (the right one, after the phone), always. It shows how many displays are in use (one, two or three panes, and "+"
  past three) and a mark while mirroring, with windows tiled on every screen that carries no mark (a master and a stack of two on a lone
  screen, two over each other on a narrower one). Its flourish takes the windows away and deals them in again; the "+" and the mirror mark
  say something, so they only dip and spring back. A click opens the popup; there is no key. **While a cast is being made** (from the click until the TV
  shows it, it fails or you stop it; also when a broken link is made again) the glyph takes its hover colour and deals its windows over and over.
- The **canvas** shows every display as a tile to scale, with its name, resolution, refresh and scale. The tiles have a small gap
  between them (drawn only: Hyprland's edges still touch) and float on one slow clock (the theme popup's Balatro float, gentler: they
  are dealt in when the popup opens, sway, and lean towards the pointer). Hover a tile and that physical screen shows an outline and
  its name. Click a tile and its **settings** open beside the popup.
- **Dragging** a tile: the card follows your hand, translucent, and the other tiles stop floating and come to rest. The place it will
  take is an outline drawn above everything, and it is decided by the POINTER, not by the carried tile's corner: the tile under the
  pointer is cut by its two diagonals into four triangles, and the triangle is the side the carried tile attaches to; where the
  pointer is along that side (thirds) picks start, centre or end. Outside every tile, the nearest tile and its facing side. So the
  laptop can go left of an ultrawide while the pointer is over the ultrawide. Tiles never overlap and the layout stays in one piece;
  the laptop is always at 0,0. A display that is off waits in a row under the canvas.
- The **settings** of one display (the second popup; every change is staged):
  - on/off and "Mirror the laptop";
  - resolution: a button with a chevron that opens a menu (the largest first);
  - refresh and rotation side by side as segmented rows (a dropdown when a display has many refresh rates);
  - scale: only the values Hyprland accepts, as a segmented row; the one that shows things at the laptop's physical size is named
    beside the caption;
  - adaptive sync and 8 or 10 bit side by side; colour (sRGB, wide, HDR, with SDR brightness and saturation under HDR);
  - the display's own brightness (DDC; the laptop's panel too where the service reads it; over a DisplayLink dock once `lares setup`'s R7 rule is in): it is written when
    you let go of the slider, or 250 ms after it stops, and the figure is muted while the write is out;
  - which workspaces live there: four plain toggles;
  - **Reset arrangement**: the one quiet action at the foot.
  The settings never animate their own height: a block that comes or goes steps the panel to its final size and the popup eases
  the box (the same for the apply bar, the hints and the parked row of the main popup).
- **Hints** say why a screen is dark:
  - a DisplayLink dock with no picture (the service or the evdi module, with the command to run);
  - a display that is plugged in but off (one click turns it on);
  - settings that did not take;
  - "HDMI is off" in Integrated mode. The HDMI port is wired to the NVIDIA card, which Integrated mode switches off.
- **Apply** sends your edits. The popup closes, and a toast asks **Keep these display settings?** with a 15 s countdown. Only a
  click on Keep keeps them; Revert, Escape or the timeout puts the old ones back. A display that does not take the new
  settings is reverted at once.

The brightness keys follow focus. On the laptop they move its backlight; on an external with DDC they move the monitor's own
brightness, and the OSD names it; on an external without DDC they move the laptop's backlight.

## Casting to a TV (off until you try it)

**Prerequisites.** `fluxcast` installed (the AUR package; Lares carries the small ffmpeg shim it needs), and a TV that speaks Miracast
(Screen Share mode on, on an LG: the TV's input list). DLNA would need `python-upnpclient` and is not used.

**Switch it on.** `"cast": true` in `config/panorama.jsonc` (see `.examples/panorama.jsonc`; read hot). Off, none of this exists: no chip, no scan.

**What you see.** Open the machine popup on its Displays tab. When it opens the shell scans for TVs (about 8 s, at most once every 30 s) and each
capable one waits as a chip in the row under the canvas. A click turns the chip into its confirm step, in place, with one honest line: pairing can
fail and the laptop's Wi-Fi card can drop for a few seconds (measured: it crashes in about 2 of 3 pairings and the normal link is down about 8 s;
the tool retries once, never loops). Leave the chip with the pointer, or press Escape, to cancel. **Cast** makes a virtual display for it (a
headless output `LARES-CAST-1`, 1920x1080 at 60 Hz, centred above the laptop) and streams it. The chip shows what is going on (Connecting…,
Retrying…, Negotiating…) and a failure says why for 6 s ("The TV did not answer", "Cancelled on the TV", ...).

**Your Wi-Fi during a cast.** It stays on the access point it is on (it reconnects to it once at the start, and once when the cast ends): roaming to
another one while the TV's link is up crashes the Wi-Fi card, which is what broke casts after 10 - 100 s. If the link does break, the stream is made
again once ("Reconnecting…"), else the cast ends and says so. What happened is in `~/.local/state/lares/cast/cast.log`.

**Workspaces.** The TV takes 3 and 4 like any external; with a real external there too, that one takes 3 and the TV 4. The "Keep these display
settings?" toast shows during a cast (a cast is a screen share, which holds other toasts back) and under do-not-disturb.

**Lares' size on the TV.** `"scale": { "outputs": { "LARES-CAST-1": { "global": 1.0 } } }` in shell.jsonc, then `lares restart` (it ends a running cast).

**Extend or mirror.** The TV then is a normal tile with a small cast mark: drag it, change its scale. Its detail has no Resolution, Refresh or Rotation of a display: the stream's own resolution and frame rate are the only ones, and a TV is not rotated. Its detail has the cast's state,
**Stop casting**, the stream's figures (below), and the stream's quality (resolution, frame rate, bitrate, sound), which is sent only when you press **Apply to stream** (the
stream restarts once). **Mirror the laptop** acts at once, with no Apply and no keep toast: the virtual display is REMOVED and the laptop's own
screen is streamed (one restart of the stream, the Wi-Fi staying where it is); turning it off makes the display again. The choice is remembered
per TV: the next cast of a mirrored TV makes no virtual display at all. (Until 2026-11-23 the display was only switched off, and a cast of a
mirrored TV made one and switched it off in the same instant: that is what closed your windows and restarted the shell.)

**A click always counts.** A Cast click while the popup is still scanning is kept and starts when the scan has ended ("Waiting for the scan…");
anything that refuses a cast says why on the chip; a click on a chip that shows a failure opens the confirm step again.

**The figures** in the TV's detail, once a second, all together; at the caption's right how long it has been streaming (and how often it was made again):

| figure | what it says | where it comes from |
|---|---|---|
| Frames sent | frames encoded and sent per second, over the last 3 s: the negotiated rate when all is well | ffmpeg's own progress |
| Dropped frames | frames the sender left out, in the whole cast | ffmpeg |
| Repeated frames | frames it sent twice because the screen capture delivered none in time, in the whole cast | ffmpeg |
| Encoder behind | how far the stream runs behind its own best moment: 0.0 s when the encoder keeps up, growing when it cannot (a lower resolution or frame rate) | ffmpeg's clock against the wall |
| Data sent | what went to the Wi-Fi card, over the last 3 s | the interface's byte counter |
| Round trip | the Wi-Fi way to the TV and back, measured with one small ping a second | an ICMP echo to the TV |
| Signal, Link rate | how strongly the TV is heard, and the speed the Wi-Fi card sends at (every 5 s) | `iw` |

"–" is "not known right now" (the link is being made again). A figure with no source is not there: a TV that answers no ping has no Round trip. **None of
them is the latency you see**: the TV keeps pictures in a buffer of its own and tells nobody, so the time from your screen to the TV's glass cannot be
measured from here (film both screens with one camera). The TV's own losses and the Wi-Fi's retransmissions are left out for the same reason (the
contract says why). The averages of every cast are the last lines of its log, `~/.local/state/lares/cast/cast.log`.

**Stop.** Stop casting, or the TV going away, removes the virtual display. If anything crashes, the engine removes a cast display nobody keeps
after 5 s. A running cast also counts as the screen being shared for the idle layer.

**Your first real try, in order.**
1. `lares deploy`, `"cast": true`, the TV in Screen Share mode; open the Displays tab: one chip for the TV after about 8 s.
2. Click the chip, read the line, move away (it cancels); click again and press **Cast**. `hyprctl -j monitors all` shows LARES-CAST-1 only now,
   above the laptop. No keep toast and no "connected" toast should appear.
3. Expect the Wi-Fi to blink; the chip should say Retrying… once and then stream or fail, never loop.
4. When the picture is on the TV: the tile with its mark, the detail's state line with the negotiated mode, a quality change waits for Apply to
   stream, Mirror the laptop shows the laptop on the TV (the virtual display is GONE from `monitors all`; the stream restarts once and the
   Wi-Fi does not reconnect in between: `cast.log` says "hold kept for the restart", then "hold taken over"). Stop, cast again: still mirrored,
   and no LARES-CAST output is ever listed.
5. Stop casting leaves no LARES-CAST output. Also try Cancel on the TV and restarting the shell mid-cast (the output goes within about 5 s).
6. Look at a moving picture: the latency was never measured. In the TV's detail: are all eight figures there (the round trip needs a TV that answers a
   ping), does Dropped or Repeated rise by itself, is Encoder behind 0.0 s at 1080p?
7. While it connects the bar's glyph is blue and deals its windows over and over; it ends its turn when the TV shows the picture and stays
   blue until the cast ends.

## Your steps (once)

1. `lares deploy`.
2. `lares panorama-import`. It shows a plan and the diffs and asks for `yes`. It:
   - keeps your laptop panel's block and the DisplayLink ultrawide's from `~/.config/hypr/config/monitors.lua` as setups;
   - drops the "mirror every HDMI display" rule and the workspace rules;
   - writes `~/.config/hypr/config/panorama.lua` (generated: do not edit it);
   - replaces `require("config/monitors")` in `hyprland.lua` with `pcall(require, "config/panorama")`;
   - keeps a backup under `~/.local/state/lares/panorama/import-<date>/`.
   Until then the popup is read-only and says so.
3. `lares binds`: the "displays -- Panorama" row reads ok.

On another machine whose Hyprland config already has the `pcall(require, "config/panorama")` line there is nothing to import: the generated
file is in no repository, and the shell writes it at its first start.

## A machine with no panel of its own (a desktop)

- A display never seen takes the **fastest refresh of its preferred size** (a monitor's own "preferred" mode is often 60 Hz); beside a
  laptop's panel the preferred mode stands. A mode you Keep is yours.
- The home display holds workspaces 1-2 (all four when it is the only one); another display takes 3-4.
- The only display is no news: no "connected" toast, and none when it goes to sleep. Toasts offer only Arrange (there is no laptop panel
  to mirror or switch off), the last display that is on cannot be switched off, and the button opens Presets while there is one display.
- A `DP-N` connector is named "USB-C" after a laptop's port; `panorama.jsonc` `"portLabels": { "usbc": "DisplayPort" }` names it otherwise.

## Files

| file | what |
|---|---|
| `~/.local/state/lares/panorama/setups.json` | the setups (the popup's store) |
| `~/.config/hypr/config/panorama.lua` | generated from it: the engine (`tools/panorama/engine.lua`) + the setups; Hyprland requires it |
| `$XDG_RUNTIME_DIR/lares/panorama.json` | what the engine did last (the shell reads it) |
| `config/panorama.jsonc` | tunables (`.examples/panorama.jsonc`): the keep countdown (`keepSeconds`; the engine's own revert follows it), the identify delay, the toasts, `openTab` (the tab a click opens on: the situation's, `displays`, `presets` or `last`), the port words, `cast`, and `castQuality` (what a TV not set up yet streams at) |
| `$XDG_RUNTIME_DIR/lares/panorama-cast.json` | the engine's table of cast displays (name -> TV) and the names a live cast keeps |

## Checks after a change

- `node tools/dev/panorama_cases.js --arms` and `lua tools/dev/panorama_cases.lua --arms`: the rules, in both languages.
- `tools/dev/panorama_hypr_facts.py`: the Hyprland facts (a nested Hyprland). Run it after a Hyprland update.
- `tools/dev/panorama_engine_env_probe.sh`: the engine in a nested Hyprland.
- `node tools/dev/panorama_layout_cases.js --arms`: the canvas geometry (the pointer's drop, the relations), pure.
- `tools/dev/panorama_ui_probe.sh` (`ARM=all`): the popup on the mock, driven by real pointer events: drops, the carry and its outline, the
  drawn gap, the float's clock, every height changing in ONE step, the dropdown, the sliders' commit at rest. `mockups/panorama.qml`:
  every number of the popup on its panel (tabs Canvas, Tile, Float, Side); `RESMENU=1` and `STAGE=drag` set a state for a grab
  (`tools/dev/panorama_grab.sh`).
- `tools/dev/panorama_tabs_probe.sh` (`ARM=all`): the machine popup's two tabs on the mock services and a stand-in engine: the tab by situation, the
  owner holding it across a park, the swipe, Escape per tab, the detail closing on the Presets tab, the glyph's deal. `mockups/panorama.qml`
  shows both tabs (`TAB=presets`).
- The cast tool and its figures: `tools/dev/cast_tool_probe.sh` (`ARM=all`; stub and real ffmpeg, and the tool's real lines through `node
  tools/dev/cast_parse_cases.js --lines`), `tools/dev/cast_service_probe.sh`, `node tools/dev/cast_parse_cases.js --arms`.
- The glyph while a cast is being made: `tools/dev/panorama_castglyph_probe.sh` (`ARM=all`; `film <outdir>` its filmstrip).
- Casting: `tools/dev/panorama_service_probe.sh` (the keeper's order on the real service and the mock, 7 ARMs), `tools/dev/panorama_ui_probe.sh`
  (the chip, the confirm step, the tile, the detail, the off-switch census and picture), the cast cases of the two case tables and the
  cast section of `panorama_engine_env_probe.sh`; `CAST=chips|confirm|connecting|tile|detail|failed` on `mockups/panorama.qml` sets a state for a grab.
- `tools/dev/panorama_common_probe.sh`: FocusedScreen's outputs, the DRM watcher, DDC.
- `tools/dev/osd_ddc_probe.sh`: the brightness keys follow focus (DDC, the panel, the fallback).
- `tools/dev/shell_probe.sh`: the real shell in a nested Hyprland, the glyph's click among every button's.
- `PHASE=cast tools/dev/panorama_shell_env_probe.sh`: a whole cast on the live service, the live cast service with a stub tool and the real
  engine (armed, scan, LARES-CAST-1, stream, stop).
- `tools/dev/panorama_shell_env_probe.sh`: the LIVE service inside the real shell in a nested Hyprland: the engine set up the import's
  way, a plug (count, toast, no warning), identify ink by pixels on the right screen, an unplug; a stub ddcutil, refused without it.

## Only your hardware can show (a checklist)

- DisplayLink:
  - the dock's display gives its own description on DVI-I-N, and the imported DVI-I-1 setup binds to it the first time;
  - evdi comes up in time at boot;
  - with the DisplayLink service stopped, the hint and its command appear.
- HDMI in Hybrid mode:
  - the modeset;
  - mirroring across the two GPUs;
  - DDC over the NVIDIA card;
  - HDR, colour and VRR on a TV;
  - a projector falls back to `auto`.
- DDC: its latency, and the brightness keys on an external.
- A real "settings did not take" (a refresh the display refuses).
- Workspaces moving with no pointer jump.
- "Only external" with the lid open, and the lock on the external.
- A known setup with a non-preferred mode: Hyprland's own rule applies first, then the engine's, so watch for a second blink at plug.
- Unplugging HDMI: the NVIDIA driver can keep the port "connected" after the cable is out, so the display engine reads the port itself
  once a second (`cable:` lines in its log, `gone` in `$XDG_RUNTIME_DIR/lares/panorama.json`). Seen working on HDMI, both ways. Not yet
  seen: a display switched off in its detail and then replugged, and any of it on the DisplayLink dock.
- Brightness keys on the external (HDMI): a step should land in well under a second. On the DisplayLink dock too: ddcutil refuses
  the dock's bus (no EDID on it), so the shell speaks DDC/CI to it itself (`tools/panorama/lares-ddc get|set <bus>`, the bus from
  `/sys/class/drm/card*-DVI-I-*/ddc`). That bus is root's until the udev rule of `lares setup` (R7) is installed; without it the
  display's detail says "the dock's brightness bus is not open to you (lares setup)". Measured on the dock: read 0.08 s, 100 -> 70 -> 100.
- After reverting a mirror on the dock: the laptop's windows must keep their distance from the screen's edges.
- A display that is dark and not listed in the popup: `cat /sys/class/drm/card*-HDMI-A-1/status` says whether the machine sees the cable
  at all. On 2026-11-23 it read "disconnected" for 15 minutes with the cable in, and the kernel logged "Unable to read EDID": the plug
  at the DISPLAY's end was loose. Reseat both ends before suspecting anything else.

## Later

