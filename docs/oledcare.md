# oledcare -- the OLED care: the bar's content moves a pixel now and then, and its glyphs play now and then

## What it is
Burn-in care in two quiet parts, both switched by ONE config line, `"oled": { "enabled": ... }` in shell.jsonc (read hot, on by default): the PIXEL SHIFT and the RANDOM FLOURISHES.

PIXEL SHIFT. Every 240 seconds (waybar's period) every icon and text in the three islands moves to the next of nine
places of a 3 x 3 square of whole DEVICE pixels: the centre, then once round the ring (right, down-right, down, down-left, left, up-left,
up, up-right), then the centre again. A static icon is thus smeared over a 3 px square over a few hours; if it ever imprints it is a blur,
not a sharp icon. The islands' FREE ends -- the ends that stand in the open, not on a screen corner -- step sideways with the icons, so the
room between an end and the module beside it stays as designed at every place: the left island's right end, the whole centre island, the
right island's left end. Nothing else moves: the ends on the screen's corners, the islands' bottom edge, the slim bars, the continuous bar
(it has no free end) and the reserved edges (so the windows' gaps: the exclusion zone is never changed, so Hyprland never moves a window).
An island's input region follows its end. The old method (hyproled's checkerboard screen shader around a hard-coded waybar rectangle) is
gone: the shell never calls it.

RANDOM FLOURISHES. Now and then one of the bar's glyphs plays its flourish by itself -- the same motion a hover plays -- so no glyph stands
still for hours, and the bar looks alive: about every 2-4 minutes while nobody touches the machine (no input for a minute) and every
10-20 minutes while someone works. The glyphs take turns from a shuffle bag (every one plays before any plays twice, across all screens).
By default the pool is the DECORATIVE glyphs: the power reel's and the idle reel's (only the item each is turned to: the one in the bar's
cell), the system update's archive, the weather icon (the ink set's; its flourish is the condition's own), the audio and networking pills'
halves (the speaker, the microphone, the network glyph, Bluetooth: each gives its signal once; a half that is off or muted plays its smaller,
empty version), the notes glyph (the sheet peeled off its block), the chat star (it kindles), the bridge's phone (flipped like a coin) and the stocks line (a ripple the way the day goes; a neutral wave while markets are closed). The bell (a new notification), the player's disc (a new song) and silicon's two glyphs (a profile
change; the GPU's mode or its card waking) mean something when they move, so they stay event-only unless switched on (`oled.flourishes.glyphs`, below). A turn is skipped
while the session is locked, the bars are away, the focused window is fullscreen, the theme fades, a popup or the reel's strip is out on
that screen, or a flourish already plays there; it is never saved up for when the reason ends.

## Where it lives
- No bar button (it was one until round 8: the care is switched by shell.jsonc's `oled.enabled`, `false` stops both parts, read hot; the
  step the pixel shift stood at is kept for when it comes back on).
- Keys / IPC: none bound. `lares oled shift | status | flourish` asks the running shell (the trial's, else the deployed one):
  `shift` takes the next step NOW, to see how noticeable it is (with a popup out it says "waiting" and takes the step when it closes;
  with the care switched off it says so), `status` is one line of JSON (on, step, x, y in device px, pending, who holds it, seconds to
  the next step), `flourish` plays a random flourish now. Behind it: IPC target `shell`, `oledShift()`, `oledStatus()`,
  `oledFlourish()` (`shell.qml`).

## What it does, exactly
- A step is whole device pixels at any scale: `OledShift.dx / dy` are device px and `ShellFrame` divides them by `renderScale`
  (`oledX`, `oledY`, applied to the three `ZoneRow`s). Measured at scale 1 and 1.25 (`tools/dev/oled_shift_probe.sh`).
- The islands' free ends take `oledX` too (`ShellLayout.bars(..., shift)`): the left island grows or shrinks at its right end, the centre
  island moves, the right island's start moves (its right end stays on the corner). The centre and right rows ride on their island; the left
  row takes the step inside its island. The two voids between the islands keep their width (both their ends step). The step is a whole
  device pixel, so an end's picture is the centre's moved by exactly that -- but for one antialiased pixel per end, where the sky fillet
  meets the end's face, a few levels off after an ODD step (the field's antialiasing width comes from derivatives over 2 x 2 pixel quads
  fixed to the screen; a 2 px step is exact). The engine's input rect of an island is its bar's rect, so it follows; a step taken while
  the island lengths move (a new window title) widens the input rect held for the move.
- A step WAITS while something placed from a module's position is out, because a popup, the reel's strip and its reason label read their
  module's place when they open: any popup slot (primary, the three children, the reel, the reel's child) in a phase but closed, ANY glyph
  flourish playing on that screen (they register themselves: `FlourishRegistry`), the theme crossfade. The step is taken the moment the last
  holder lets go (`OledShift.setHeld`; each frame holds under a key of its own).
- THE FLOURISH REGISTRY (`modules/common/flourish/FlourishRegistry.qml`): every `GlyphFlourish` (a bar glyph's clock) and every reel item's
  `FlourishClock` adds itself when it is made and leaves when it is destroyed, by identity (every screen has a "bell"). Each carries its
  name (`group`, and `glyph` in a reel), whether it is decorative, the Item it lives under (which screen), whether it is on show and
  `demo()`. A NEW FLOURISH JOINS THE POOL BY NAMING ITSELF: `group: "mymodule"` on its GlyphFlourish (and `decorative: true` if its motion
  means nothing) -- nothing else lists the glyphs. A reel's item plays through its set's demo, never its fire (a power item's fire is what
  powers the machine off).
- THE SCHEDULER (`modules/common/flourish/FlourishScheduler.qml`, one per screen in `ShellFrame`): one single-shot wait drawn from the
  mode's range, re-armed after every turn and whenever the mode changes; idle is an `IdleMonitor` (60 s) that ignores inhibitors (a video
  holds the screen on; it does not mean someone is at the keyboard). Logged: `LARESFLOURISH play <group.glyph> idle|active`.
- The place persists: `<state dir>/oled-shift.json` = `{"step": 3}` (`~/.local/state/lares/oled-shift.json`), read before
  the first frame, written at every step (an older file's `"on"` is ignored). Default step 0. `oled.enabled` false puts the content back at
  (0,0), stops the timer and the flourish scheduler; true resumes the step.
- Hidden bars (Super+F2): the rows fade with the bars; nothing to do.

## Your configs
Nothing in your Hyprland config starts hyproled's watcher, and the shell never calls hyproled: the scripts under
`~/.config/hypr/scripts/hyproled/` are yours, on disk, unused by the shell. (`hyproled-toggle.sh`'s `evaluate` also counts the
Lares lock as a lock: harmless.)

## Settings
The shift: `intervalMs` (240 000) and the orbit are properties of `OledShift.qml`. The switch and the random flourishes: shell.jsonc,
read hot (`.examples/shell.jsonc` documents every key). `enabled` is on unless exactly `false`; anything else that is not a boolean is
on and the shell's log names it:

    "oled": { "enabled": true, "flourishes": {
        "idle": true, "active": true,                         // each mode on or off
        "idleEveryS": [120, 240], "activeEveryS": [600, 1200], // the wait between two, seconds, drawn evenly (10 .. 86400)
        "glyphs": { "power": true, "power.hibernate": false, "bell": true } } }

`glyphs` takes a group (`power`, `idleReel`, `update`, `weather`, `audio`, `aerial`, `notes`, `llm`, `theme`, `bridge`, `bell`, `player`, `silicon`) or one glyph of a
reel or a pill (`power.sleep`, `power.poweroff`, `power.reboot`, `power.hibernate`, `power.logout`, `power.lock`, `idleReel.zzz`, `idleReel.sunset`,
`idleReel.mug`, `idleReel.infinity`, `audio.speaker`, `audio.mic`, `aerial.wifi` (whatever the network half shows), `aerial.bluetooth`,
`silicon.gpu` (the GPU mode's glyph; `silicon` alone is the profile's glyph and, with no `silicon.gpu` key, the GPU's too);
a glyph key wins over its group, and a glyph with neither takes its default (decorative in, event-bound out). A bad value takes its
default and the shell's log names it.

## How it is built
| Path | Role |
|---|---|
| `modules/shell/OledShift.qml` | the state (the step), `on` (bound to the config's switch), the timer, the holders, the persistence, `shift()` / `status()` |
| `modules/shell/ShellFrame.qml` | the zone rows' offset (`oledX/Y`) and the islands' free ends (`barSpecs`), `oledHeld` (from the registry) and the frame's hold key; the frame's `FlourishScheduler` and its gates (`flourishBlock`); `flourishNow()` |
| `modules/shell/ShellLayout.js` | `bars(..., shift)` / `maskUnion(..., shift)`: the islands' free ends at the step's x (THE OLED SHIFT) |
| `modules/common/flourish/` | `FlourishRegistry` (singleton: every glyph flourish, the shuffle bag), `FlourishScheduler`, `FlourishConfig.js` (the config, the pool rule, the bag's shuffle) |
| `modules/common/components/GlyphFlourish.qml`, `modules/bar/reel/FlourishClock.qml` | register themselves; `demo()` |
| `modules/shell/ShellConfig.qml` | `oledEnabled` / `oledFlourishes`: shell.jsonc `oled.enabled` and `oled.flourishes`, checked (`FlourishConfig.enabledOf`) |
| `modules/shell/ShellServices.qml` | makes the one `OledShift` (state file under the shell's state dir; `on` follows `oledEnabled`) |
| `shell.qml`, `tools/shell/lares` | the IPC functions and the `oled` command |

## Check
`tools/dev/oled_shift_probe.sh` (mock shell with the user's edge -- a halo and the ring --, offscreen, scale 1 and 1.25: the nine places;
at each the islands' free ends at the step's x, the corner ends, the thickness, the slim bars and the reserve unmoved, the room between each
free end and its module the centre's, the field and the input rects on the bars; a step during a lengths move inside the held input rect;
the deferral, the reel strip level with its cell at every place, the restart (and an old state file's `on`), the config switch off / on, the IPC words; the pictures at (0,0), (1,0) and
(-1,0) and (0,0) after the ring judged by `tools/dev/oled_shift_pixels.py`: each void between two islands the centre's moved by exactly the
step (one re-rasterised pixel per end allowed) and the (-1,0) picture the (1,0) one moved 2 px to the pixel, the joints with the slim bars
unmoved, the centre after the ring the first centre; `GRABS_OUT=<dir>` keeps them, `oled_shift_pixels.py sheet` makes a before/after sheet; ARMs nodefer, nostrip,
halfpixel, moveisland, nofollow, rowtwice, nohold, nopersist, noconfig), `tools/dev/flourish_pool_probe.sh` (mock shell, offscreen, the idleness pinned: the registry and its scope, the archive holding
the shift, two rounds of the bag, never the fire path, the gates (the config switch among them), the config; ARMs nogate, firepath, staleheld, configoff) and the deploy
probe's autostart check (`tools/dev/lares_deploy_probe.sh`, ARM nowatcher).

## Limits
- Only the bar's content moves; the windows' own content (a window that stays at one place) is the windows'.
- A reel's random flourish plays only the item the reel is turned to (the others are not on show); the power reel rests on Lock.
- The random flourishes count no frames while the screen is off (DPMS): a turn may play to a dark panel.
