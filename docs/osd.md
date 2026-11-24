# On-screen display (OSD)

## What it is

A small card that grows out of the right bar for a moment when something changes: the volume, the microphone, the screen or keyboard
brightness, Caps Lock, the keyboard layout, the theme, the song, a network or Bluetooth connection, a screenshot, the battery. It
replaces the volume and brightness scripts' pop-ups with one display in the shell's material that also answers the hardware keys.

## Where it lives

- **Where it comes out**: the middle of the right slim bar by default (`spot`). It is its own slot of the popup engine: it can be out
  at the same time as a popup and the toasts, and it makes way for them (it slides to the nearest free place, or folds into its bar
  and waits). When the kind changes while it is out, it folds into the bar and rises again with the new card.
- **Over a fullscreen window**: a capsule at the top centre of the screen (`modules/osd/OsdPillWindow.qml`) that clicks go
  through -- all but the caption's hide button and, once hidden, its ball -- or
  nothing (`fullscreen: "suppress"`).
- **Keys** (global shortcuts of the app id `lares`, `modules/osd/OsdShortcuts.qml`; they also work while the session is locked):

| Key | Shortcut name | Does |
|---|---|---|
| XF86AudioRaiseVolume / LowerVolume / Mute | `osd-volume-up` / `-down` / `-mute` | volume |
| XF86AudioMicMute | `osd-mic-mute` | microphone mute |
| XF86MonBrightnessUp / Down (Shift: fine) | `osd-brightness-up` / `-down` / `-up-fine` / `-down-fine` | screen brightness |
| XF86KbdBrightnessUp / Down | `osd-kbd-up` / `-down` | keyboard light |
| XF86AudioNext / Prev / Play / Pause / Stop | `osd-media-next` / `-prev` / `-toggle` / `-stop` | music (mpd) |
| CAPS + Caps_Lock, MOD2 + Num_Lock | `osd-lockkeys` | the lock keys' card (the key still reaches the app: `non_consuming`) |

  A held key repeats at the compositor's own repeat delay and rate. `lares binds list` prints the table.
- **IPC** (`quickshell ipc call osd <verb>`, `modules/osd/OsdIpc.qml`, for scripts; the keys never go through it): `volume
  <up|down|mute>`, `mic <up|down|mute>`, `brightness <up|down|up-fine|down-fine>`, `kbd <up|down>`, `lockkeys`,
  `media <next|prev|toggle|stop>`, `capture <shot|rec|copied|deleted> <a> <b>`, `request <json>`, `dismiss`, `test <kind>`. Each
  answers `true` when it did something.

## What you can do

- **Volume, microphone, brightness** (a glyph, a slider, the figure and, on a horizontal bar, the device's name): drag the ball, scroll on
  the card, middle-click to mute (not brightness). Volume keys stop at 100 %; a fresh press at 100 % goes into boost, up to
  `boostMax`. Brightness keys climb even steps of how bright the screen LOOKS; at the bottom a fresh press down turns the screen off.
- **Keyboard light**: four stops engraved on a rail. **Caps / Num Lock**: the two keys drawn as keys. **Layout**: the two-letter code
  big ("BE", "US").
- **Song**: the cover, title and artist when the track changes; a click opens the player's popup. Not shown while the player's popup
  is open or the session is locked (both already show the song).
- **Screenshot** (Super+Shift+S, `tools/osd/shot.sh`): the thumbnail; a click opens it in the editor (swappy; `capture.click`,
  `capture.editCommand`), the trash icon on its corner deletes it.
- **Theme, Bluetooth, network, VPN, battery, power** (silicon's profile, GPU mode and charge limit changed outside its popup): a plain
  card with a glyph and words.
- **Hide the caption**: the button at the far end of its head row (the notes' compress glyph). On a bar the card sinks into the bar
  until 3 px of it stand out (`osdTuckPx`); over a fullscreen window the pill collapses to a ball that rises until less than half of
  it is on screen and fades to a faint presence over 3 s. The words keep coming underneath. Move the pointer onto the sliver -- or
  onto the slim bar beside it, out to the screen's edge -- or onto the ball, and it comes back out. A resting pointer never brings it
  back: only one that moves. Another card in between comes out as ever, and the caption returns hidden; the end of the take forgets it.
- **Dictation's caption** (round 5): the live words of a window take (Ctrl+fn+F10) or a voice ask (Alt+fn+F10) -- a fixed-size card
  with the last lines, renewed while the take runs and taken down when it ends (`docs/dictation.md`). Another card takes the
  slot as over any event; the words come back with the next renewal.
- **Hover a card** to keep it; it goes `resumeMinMs` after the pointer leaves. The pill over a fullscreen window does not hold on a
  hover: its only input is the caption's hide button and the hidden ball.
- **Order**: a key's card shows at once; system events wait their turn behind the card on show (at most `queueCap`, the oldest
  dropped).

## What it shows and where the data comes from

One service (`modules/osd/data/OsdService.qml`) with a source per kind (`modules/osd/data/sources/`):

| Source | Reads |
|---|---|
| `AudioSource.qml` | PipeWire's default output and input (the keys change them; an app's change is shown too) |
| `BacklightSource.qml`, `SysfsLevel.qml` | the backlight in sysfs, written with `brightnessctl -d <device>`; the device is the panel's own (`PanelBacklight`, docs/idle.md), unless `brightness.device` names one; where raw 0 is not black (nvidia_0) a key never writes 0 |
| `DdcBrightnessSource.qml` | an external display's own brightness over DDC/CI (through the display module's service, never ddcutil itself); see "Brightness keys act on the display under the pointer" |
| `KbdLightSource.qml` | the keyboard backlight (the Fn key's own change is watched too) |
| `LockKeysSource.qml` | Caps / Num Lock's state, shown the moment a reading says the lock has changed (on at the key's press, off at its release) |
| `LayoutSource.qml` | the keyboard layout, from Hyprland's event socket |
| `MpdSource.qml` | mpd: the media keys, and its own track changes |
| `NetSource.qml`, `BtSource.qml` | the AerialService (the shell's one): Wi-Fi up, lost or failed, a cable in or out, a VPN, the tunnel aerial raised by itself (`autoTunnel`), a device connecting, a device's battery low (`btLow`) |
| `BatterySource.qml` | silicon's battery reader: the low-charge line and the charge limit reached |
| `ThemeSource.qml` | the theme changing |
| `CaptureSource.qml` | screenshots and recordings, through IPC only (`tools/osd/shot.sh`) |

### Brightness keys act on the display under the pointer

With the display module wired (`OsdService.displayBackend`, `monitorRects`, `focusedScreen`) a brightness key acts on the display the
POINTER is on (round 2; before, the focused one). At a gesture's press the service runs ONE `hyprctl -j cursorpos` (150 ms at most; a
missing or failing hyprctl, or a point on no rect, falls back to the focused screen) and takes the monitor whose logical rect holds the
point (`OsdPointer.js`: pixels / scale, width and height swapped for transform 1 / 3, a point on a shared edge belongs to the monitor that
starts there). The gesture's display is kept for the held key's repeats and release and `gestureKeepMs` (400) past the last press, so
a run of taps is one gesture; steps taken before the answer wait and run in order.

- the laptop panel: its backlight, exactly as before (the ladder, `zeroIsBlack`);
- an external display: its own brightness over DDC/CI. A key adds its step (5 % / 1 % of the display's REAL maximum, at least one unit) to
  the display's one goal in the backend; the client sends only the newest. Nothing is dropped, nothing waits for a read, and the laptop's
  backlight is NEVER stepped for an external;
- the card is up at once at the GOAL with `pending: true` (the figure and glyph mixed toward the faint ink, a slim accent mark sweeping the
  foot of the card), is asked for again every second while pending, and once more with `pending: false` when the write is done;
- an external with no DDC (`ddcState` "unsupported") or one whose last request failed (`"failing"`, remembered 60 s) gets a card with
  `unavailable: true` and the reason as `note` under the display's name; nothing moves;
- a drag on the card's slider scrubs that display (`ddcScrub`): the figure follows the hand, the write goes out at rest (250 ms) or on
  release.

The laptop panel for the display module's popup: `panelBrightness()` -> `{ capable, value 0..1 }`, `setPanelBrightness(v01)`,
`refreshPanel()` and the `panelRev` counter (bump-read it first in a binding; it also moves on every key step).

With no backend (a mockup, a probe) the keys are the laptop's backlight. Check: `tools/dev/osd_ddc_probe.sh` (part 1 against a stub
backend, part 2 the whole path with a real DdcClient and stub ddcutil / hyprctl / brightnessctl), `node tools/dev/osd_pointer_cases.js`.

A kind routed to `"notification"` becomes a desktop notification instead; a kind whose device is missing shows nothing.

## Settings

`~/.config/quickshell/config/osd.jsonc`, re-read when it is saved (`modules/osd/data/OsdConfig.qml`, keys in `modules/osd/data/OsdKinds.js`).
The commented example `.examples/osd.jsonc` is the full list; every value in it is the default.

| Key | Meaning | Default |
|---|---|---|
| `spot` | where the OSD comes out: `{ "bar": edge, "along": 0..1 }` or `{ "corner": "right-bottom" }` | right bar, 0.5 |
| `screen` | `"focused"`, or a connector's name (`"DP-1"`; the focused one while it is not there); over a fullscreen window it asks THAT display | `"focused"` |
| `fullscreen` | over a fullscreen window: `"pill"`, `"keys"` (the pill for what you did alone: the keys, a media key's track, a capture, the dictation's words) or `"suppress"` | `"pill"` |
| `dismissMs` / `resumeMinMs` | how long a key's card stays; how long after the pointer leaves | 2000 / 800 |
| `queueCap` | event cards waiting behind the one shown | 3 |
| `repeat` | a held key's `delayMs` / `rateHz`, or `"auto"` (the compositor's) | `"auto"` |
| `volume` / `mic` | `step` (and volume's `boostMax`) | 0.02, 1.5 / 0.05 |
| `brightness` | `device`, `step`, `fineStep`, `gamma`, `floorRaw`, `target` (`"pointer"`, `"focused"`, `"panel"`) | `""` (the panel's backlight, found by the shell), 0.05, 0.01, 2.0, 1, `"pointer"` |
| `media` | `keys`: `"mpd"`, or `"auto"` (another player through playerctl while mpd has no song in play; also under the lock, whose keys are the same) | `"mpd"` |
| `capture` | `dir`, `name`, `copy` (read by `tools/osd/shot.sh` at each shot), `openCommand`, `editCommand` (`[]` = swappy), `click` (`"edit"`, `"open"`, `"none"`) | `~/Pictures/Screenshots`, `shot-%Y%m%d-%H%M%S.png`, true, `xdg-open`, `[]`, `"edit"` |
| `kbd` | the keyboard backlight's `device` | `asus::kbd_backlight` |
| `lockkeys.keys` | the keys the lock keys card shows, in order; `["caps"]` for a keyboard with no number pad (no Num key on the card, and a Num Lock change shows nothing) | `["caps", "num"]` |
| `layout` | which `keyboard`, and `codes` (a layout name to its short code) | `main`, US / BE |
| `kinds` | per kind: `route` (`"osd"`, `"notification"`, `"off"`), `ms` (0: `dismissMs` for what a key shows, 3 to 4 s for the others) and, where it has some, `events` | all `"osd"` but `generic` (`"off"`); every event |

The cards' look and pacing are tuned in `mockups/osd.qml` (the OSD on the real bar engine; run it through `tools/dev/osd_mockup.sh`);
Save writes `modules/osd/OsdStyle.qml`.

## How it is built

| File or directory | Role |
|---|---|
| `modules/osd/data/OsdService.qml` | the one brain: values, key repeat, requests |
| `modules/osd/data/OsdKinds.js` | the kind table, the brightness ladder, the config's rules |
| `modules/osd/data/OsdConfig.qml`, `sources/` | the config; one source per kind |
| `modules/osd/OsdOwner.qml` | the OSD on one screen: where it shows, what waits, when it goes |
| `modules/osd/OsdContent.qml` | the card for one kind (the wheel and middle click over a level) |
| `modules/osd/kinds/` | the cards: `OsdLevel.qml`, `OsdStops.qml`, `OsdLockKeys.qml`, `OsdLayoutCode.qml`, `OsdTrack.qml`, `OsdCapture.qml`, `OsdCard.qml` (the plain events), and their parts |
| `modules/osd/Battery*.qml` | the battery card's carved cell, its nub and its fill |
| `modules/osd/OsdPill.qml`, `OsdPillFrame.qml`, `OsdPillWindow.qml` | the capsule over a fullscreen window (and its ball); everything of its window but the window -- sized for the largest pill of every kind (`OsdStyle.pillWindowExtent`), its input zones; the window |
| `modules/osd/OsdShortcuts.qml`, `OsdIpc.qml` | the keys; the `osd` IPC target |
| `modules/osd/OsdStyle.qml` | every look and motion number |
| `modules/common/osd/OsdBus.qml` | where other modules find the OSD to ask for a card |
| `tools/osd/shot.sh` | the screenshot that ends in a capture card |

Shared: `GrooveSlider` (the level's slider, the same as the volume popup's), `PhaseRail` (the keyboard light's rail),
`RoundedImage` (the cover), `BarSpot.js` (a bar and a place along it).

## Limits

- A machine with no keyboard light says so: `osd.jsonc` `"kbd": { "device": "" }` (nothing then watches for one). Another laptop's LED is named there.
- A keyboard with no number pad: `osd.jsonc` `"lockkeys": { "keys": ["caps"] }`.

- One card at a time; system events wait, the oldest goes when the queue is full.
- A global key gives one press and one release: the shell repeats a held key itself, and cuts a key whose release never comes.
- `hyprctl dispatch` of an OSD shortcut sends a press with no release.
- Other programs' notifications are not shown as OSD cards (`generic` is `"off"`).

## How to change it

- **How long cards stay, the steps, where it comes out**: edit `~/.config/quickshell/config/osd.jsonc` and save; it applies at once. Then
  `tools/dev/config_loaders_probe.sh`.
- **Send a kind to a notification, or nowhere**: `kinds.<kind>.route`.
- **The cards' look and motion**: `tools/dev/osd_mockup.sh run` opens `mockups/osd.qml` (on the desktop, private settings); tune, Save.
  Then `tools/dev/osd_mockup.sh` (load, report every warning). The tuck's numbers are on the Slot tab (Dip), the ball's on the Pill tab.
- **The pill's open** (`OsdPill`): ONE motion. Growth and widening run on one parallel animation (`pillOpenGrowMs` 130, the widening
  `pillOpenWidenMs` 190 starting `pillOpenLeadMs` 50 in, both OutCubic: no standstill between them), and the content fades in
  (`pillFadeInMs` 120) as soon as the widening is `pillFadeAt` (0.94) done: the share at which the capsule's ends pass the widest ink of
  any kind with 2 px to spare. Content half in ~210 ms, whole ~270 ms after `present()`. The close keeps `pillGrowMs` / `pillWidenMs`.
  The request-to-first-frame path has no delay of its own (service -> owner `_deliver` -> `pill.present`, all in one turn; the window is
  kept mapped while the bar is covered). `tools/dev/osd_pill_open_probe.sh` (every kind per frame: readable by 260 ms, ink covered,
  one motion; ARMs slowfade, early, nooverlap).
- **The hide button, the tuck, the ball, the pill's window**: `tools/dev/osd_hide_probe.sh` (offscreen: the real engine, a pointer
  through QtTest, the pill's pixels at scale 1 and 1.25); `LIVE=1` adds the pill's real window in a nested Hyprland.
- **The Caps / Num Lock binds**: `tools/dev/osd_lockkeys_probe.sh` presses the laptop's real keycodes in a nested Hyprland with
  `OsdShortcuts.qml`'s bind lines and waits for the card. On Hyprland 0.57 a lock key's own modifier is held while it is down, so a
  bind of the plain key never fires.
- **A key**: the binds are Hyprland's (`~/.config/hypr/config/keybinds.lua`); the names they call are in `modules/osd/OsdShortcuts.qml`.

Contract (for developers): [contracts/osd.md](contracts/osd.md).
