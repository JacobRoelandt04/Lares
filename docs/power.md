# power -- the power reel

## What it is
One icon at the left end of the top bar that is a ring of icons: sleep, power off, reboot, hibernate, log out, lock. The icon in the bar is
the selected one; hovering it lets the rest of the ring hang out of the bar as a strip with a half-round end, and turning the ring slides
another icon into the bar. Only the selected icon can be fired, and only by a right click, so scrolling past "power off" never does
anything. It replaces wleave.

At rest the bar's icon is in the shade every other bar glyph rests in (`Theme.textMuted`); the hover, press and fire colours and the strip's
faint icons are unchanged (`tools/dev/bar_ink_probe.sh` reads the inked pixel of a reel cell against the token).

## Where it lives
- Bar: the left island of the top bar, module id `power` (the first of the island). The island's idle-inhibit reel (`idle`, see `idle.md`) is
  the same component with other items and another click rule.
- The strip is the engine's reel slot, a body of its own beside the popup: hovering a reel never closes or moves a popup that is out. It
  hangs from the bar's edge with the curve the engine draws out of it, and it travels along the bar when the pointer goes to another reel.
- The ring rests on Lock when the shell starts (a right click on the freshly started bar locks, the one item that costs nothing).
- While the session is locked the reel closes and opens no more (the lock's popup is the one thing up).
- One key: the `lares:lock` global (`ShortcutRouter`) locks through the reel's own path (the same command, and the padlock's
  flourish). Bind it in `keybinds.lua`: `hl.bind("SUPER + L", hl.dsp.global("lares:lock"))`. No IPC verb.

## What you can do
- Hover the icon (after 90 ms) to open the strip; leaving closes it after a short grace (160 ms), because the pointer crosses from the bar's
  cell into the strip through a frame where neither has it.
- Turn the ring: scrolling down or right is the next item, whichever way the strip lies. A mouse wheel notch is one step; a two-finger
  scroll counts against a threshold, gives a little as it pulls and snaps one item when the threshold is crossed. Icons that pass the end
  come back at the other, so the ring never ends.
- A left click on any other icon slides it into the bar (selects it). It does nothing else.
- A right click on the SELECTED icon fires it. This is the reel's safety: no scroll and no left click fires anything.
- Items and what they run (`modules/shell/ReelActions.qml`):

| Item | Tint | Runs |
|---|---|---|
| Sleep | blue | `systemctl suspend` |
| Power off | red | `systemctl poweroff` |
| Reboot | yellow | `systemctl reboot` |
| Hibernate | cyan | nothing, and a notification says so, until `power.jsonc` gives it a command |
| Log out | magenta | `hyprctl dispatch hl.dsp.exit()` |
| Lock | green | the shell's own lock (`lares-lock-session` of the lock snapshot), else `~/.local/bin/hyprlock`; detached, so a shell restart cannot unlock it |

- **With session restore on** ([session.md](session.md)), Log out, Reboot and Power off first save the session's picture:
  `lares-session end <item>` under a 3 s deadline with its status ignored, then the item's own command, in one `sh -c` -- a save that
  fails or hangs never keeps the session from ending. Off (as shipped) the commands are exactly the table's.
- Turning the ring throws a few faint particles away from the direction of the turn; firing an item flashes it.
- **Every item has a flourish** (at most a second; `modules/bar/reel/ReelFlourish.js`): it plays when the item fires, when the pointer
  arrives on the bar's cell (an entry and a motion: a cell that comes up under a resting pointer plays nothing), when the pointer moves onto
  any other icon of the open strip (it says the icon can be clicked; the idle reel's icons too), and when the item ARRIVES in the cell as
  the ring is turned (a scroll, a swipe, a click on the strip). Hover and arrival are demos: nothing fires. A flourish in
  progress is never started over (a fresh hover, the icon turned back into the cell); an icon turned out of the cell mid-flourish plays
  on where the ring took it and ends at rest by itself; a fast flick that commits several steps in one turn plays only the icon it lands
  on. One clock per item, so nothing piles up, and none runs at rest. At rest every glyph is the font's own, to the pixel, except the
  padlock:

| Item | Flourish | Fires |
|---|---|---|
| Sleep | the moon runs through every phase back to its own | at once (the lock's veil and the sleep fade are its show) |
| Power off | the 1 and the 0 trade places along one loop, never touching | when the flourish has played, + 120 ms |
| Reboot | one turn the way the arrow points, wound back first, settling past | when the flourish has played, + 120 ms |
| Hibernate | a hard kick and a spin about the vertical axis that winds down, the far face darker | when the flourish has played, + 120 ms |
| Log out | the arrow dashes out right (cut at the cell's edge) and slides back out of the box's left wall | when the flourish has played, + 120 ms |
| Lock | OPEN at rest: the shackle a little up (60 font units: its top ink one device row over the bar's tallest other glyph at 1x and 1.25) and its short right leg out of the body with a gap of two device rows; the shackle shoots down and the lock takes the knock on a stiff spring (a dip of about 1.6 px at 1x and 2 at 1.25, 140 ms in, and a rebound of a third of it) | at once: the flourish plays while the lock comes up |

  The padlock stays shut while the session is locked and springs open when the lock lets go; a lock that starts by itself (hypridle
  before a suspend, the key) plays the engage too (the shell hears the lock's `locking` phase before it is secure). A waiting action runs
  when the reel says its flourish has ended (with a failsafe of its length + 0.5 s when no bar is on show).
- **The idle reel's items have flourishes too** (`modules/bar/reel/IdleFlourish.js`, the same triggers: the pointer's arrival on the cell
  and an item turned into it; choosing a mode plays nothing more, and nothing in a flourish chooses one):

| Item | Flourish |
|---|---|
| Idle allowed (zzz) | the Zs float up and right along their own line, each bobbing on its own beat; the top one drifts out fading as a new one grows in at the bottom left |
| Soft (sunset) | the rays draw in, the sun sinks into the horizon, horizon and arrow take a knock (the arrow a beat behind); the sun drops back in from above and lands with a smaller knock and a squash, the rays spring out |
| Normal (mug) | STIR: a spoon pops out of the mug, stirs one quick circle and dips back; two wisps of steam wind into a little spiral with it and evaporate |
| Hard (infinity) | a half twist about the long axis that travels left to right (easing in, fastest across the middle, easing out); the strip's crossing parts as the twist reaches it, the near strand drawn over the far one; the two loops are never more than 99 degrees apart (at 180 the sign would untwist into a plain loop) |

- **The OLED care plays them now and then** (`docs/oledcare.md`, the random flourishes): the item each reel is turned to, through the
  same demo a hover plays -- never a fire.

## What it shows and where the data comes from
It reads nothing: the items are a fixed list (`modules/shell/ReelItems.js`: id, glyph, label, a tint: a role of the bar's hue table, `modules/common/glyphs/BarHues.js`, which gives
every option its own terminal colour in every theme). The only live facts are the
shell's lock state (it blocks the reel) and, for Hibernate, nothing. In a mock shell every command is recorded, never run
(`CommandRunner`), so a test can press every item.

## Settings
`~/.config/quickshell/config/power.jsonc` (template `.examples/power.jsonc`):

| Key | Meaning | Default |
|---|---|---|
| `items` | which items the reel has and their order; `lock` always is (read as the shell starts) | all six |
| `rest` | the item the ring rests on when the shell starts (the one a right click would fire) | `"lock"` |
| `commands` | a command instead of an item's own, as a list (`sleep`, `poweroff`, `reboot`, `hibernate`, `logout`); the session is still saved first | `{}` |
| `waitForFlourish` | power off, reboot, hibernate and log out wait for their flourish | `true` |
| `leftClickFires` | a left click on the selected icon fires it too | `false` |

The glyphs and tints are `ReelItems.js`; what each item does of its own is `ReelActions.qml`. The reel's size, the timing of the turn, the swipe's threshold and pull,
the fog at the ends, the particles and the delays of opening and closing are properties of `IconReelStyle` (`modules/common/components`),
shared with the idle reel and tuned in `mockups/power.qml` (`quickshell -p ~/.config/quickshell/mockups/power.qml`; Save writes the
module). That mockup shows four reels on a horizontal and a vertical bar on the real engine and fires nothing: `activated` runs
`notify-send` with the command in the body and never the command.

## How it is built
| Path | Role |
|---|---|
| `modules/bar/reel/IconReel.qml` | the ring: state and rules (selection, wrapping, the detent of a wheel notch and of a swipe, activation), no pixels |
| `modules/bar/reel/IconReelView.qml` | a clipped window onto the ring: the bar's cell and the strip are two views of one ring, so an icon sliding into the bar leaves one and enters the other at the same coordinate; pointer picking and the wheel reader |
| `modules/bar/reel/ReelBarModule.qml` | the module: the ring, its cell in a gooey bar and the strip handed to the engine's reel slot; opens on hover, closes after the grace; plays the selected item's flourish when the pointer arrives and an item's as the user turns it into the cell |
| `modules/bar/reel/ReelFlourish.js`, `IdleFlourish.js` | the flourishes of the power reel and of the idle reel: one linear clock per item, every curve a function of it, and THE POSE (`pose`): the Text's turn / scale / shade and up to six vector layers, the one shape both reels answer in; the glyph outlines (from the font: `tools/dev/reel_glyph_outlines.py`, `--idle`) |
| `modules/bar/reel/ReelFlourishes.qml`, `IdleFlourishes.qml`, `FlourishClock.qml` | a reel's flourish set: one clock per item (shared by both views; each registers itself with the OLED care's `FlourishRegistry`), `hover` / `arrive` / `demo` / `poseOf`; the power set also the padlock's shut state and `played(id)` |
| `modules/bar/reel/ReelGlyphArt.qml` | draws a pose's layers (no item by name): the vector half of a glyph while it moves, and the padlock always; reboot and hibernate turn the Text itself (IconReelView applies the pose's turn and scale) |
| `modules/common/components/IconReelStyle.qml` | every number of the reel's look and motion |
| `modules/shell/ReelItems.js`, `ReelActions.qml`, `CommandRunner.qml` | the items, what they run, the command runner (live runs, mock records) |
| `modules/shell/ShellFrame.qml` | mounts the reel as module `power` with `blocked` bound to the lock |
| `mockups/power.qml` | the mockup |
Shared parts used: the gooey engine's reel slot (`modules/bar/gooey`, `docs/contracts/gooey_engine.md`), `Mix`, the particles of
`modules/common/particles`, the swipe rule of `docs/contracts/gestures.md` (a swipe is a wheel, ended by the zero-delta event).

## Limits
- Hibernate does nothing until `power.jsonc` gives it a command (`"commands": { "hibernate": ["systemctl", "hibernate"] }`):
  its item says so in a notification. Wire it only on a machine that has passed a real hibernate and resume. A machine
  that cannot hibernate leaves it unset, or drops `"hibernate"` from `items` so the reel does not show it.
- In the idle reel's `hard` mode the shell holds logind's sleep lock, so Sleep and Hibernate are refused.
- A reel fires only by a right click on the selected icon (the lock also by its key); there is no confirmation beyond that.
- The flourishes' numbers are constants of `ReelFlourish.js` / `IdleFlourish.js`, not mockup settings.
- Log out is Hyprland's Lua form `hl.dsp.exit()`; Hyprland has no plain `exit` dispatcher.

## How to change it
- Add, remove or reorder an item or change its glyph or tint: `ReelItems.js` (`POWER`); then its command in `ReelActions.commandOf`.
- Make the ring rest on another item: `POWER_REST` in `ReelItems.js`.
- Change the feel (step time, swipe threshold, fog, delays): `IconReelStyle.qml` defaults, best in `mockups/power.qml` and saved there.
- Move the reel to another place in the bar: `zones` in `shell.jsonc` (`power` is a module id like any other).
- A flourish: `ReelFlourish.js` / `IdleFlourish.js` (the `pose` function and `DURATION`); which actions wait: `WAITS`. A reel of a new kind
  brings its own set (clockOf / hover / arrive / demo / poseOf, as `IdleFlourishes.qml`) and the views draw it unchanged.
Gate: `tools/dev/smoke.sh mockups/power.qml`, `tools/dev/reel_auto_probe.sh` (with its ARMs; the scroll: arrivals, no restart, the frame
record of every clock), `tools/dev/reel_flourish_strip.sh` (every
flourish of both reels as a strip over the old tree's, every rest pose against the old tree to the pixel and every lock strip ending on its rest, the
padlock's knock measured: `KNOCK` lines; `SCALE=1.25` for the user's frame, `MAY_MOVE` for a rest changed on purpose), `tools/dev/reel_film.sh` (the real shell and lock in a nested Hyprland:
the key, the flourish over the lock, the idle reel's cinematic and the Ctrl override).
