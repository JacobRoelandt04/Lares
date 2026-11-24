# Lock screen

## What it is

When the session locks, the desktop blurs under an animated "veil" and the shell's own popup hangs from the centre island with the
time, a password field and a glance at the machine. It replaces hyprlock with a lock in the shell's material, and it is built so the
session is never left on Hyprland's "compositor is locked" screen: if the lock fails, another takes over.

## Where it lives

- **Two processes.** The lock itself is a separate Quickshell process (`lock/shell.qml`) that holds the session lock, the keyboard and
  the password. The desktop shell only draws: its bars and the lock popup are shown over the lock screen, and it cannot unlock
  anything. The two talk over a socket in `$XDG_RUNTIME_DIR/lares-lock/`.
- **The popup** hangs from the centre island on every screen while locked (`modules/lockscreen/LockOwner.qml`). If the shell has
  not shown it on a screen within `fallbackDelayMs`, the lock draws the same card there itself, where the popup hangs. At boot (the
  lock SDDM starts before the shell) the veil shows alone and the card waits `bootFallbackDelayMs` (or comes at once after a wrong
  password; keys typed blind still unlock). The card goes when the shell names its bar and comes back if the shell's popup has not
  followed within `handoverGraceMs`.
- **At boot the screen stays black until the veil's floor is on it, whole** (the tty's black, extended). Hyprland draws the
  session's workspace -- the wallpaper -- from the moment a lock asks until the lock has drawn, so a boot lock (and a relaunched or
  replaced one) first puts a black cover over every screen (`BootCover.qml`) and asks only once Hyprland shows the cover (lists it
  as mapped: a frame the GPU has not finished is not on screen yet); its own first
  frame is plain black, and the veil is built after that, so Hyprland's sad-face "lockdead" screen can never come in between
  however long the veil's shaders take. Every veil then draws its whole floor in its first frame (relief, keycaps, dimples,
  louvres always did; paper's bed, gooey's ground and dials' sand used to be laid in by a front) and only the detail forms on it.
  Nothing shows through a boot veil: the wallpaper first appears through the unlock's fade.
- **The veils draw the shell only where the shell says it is**: before the shell has sent its bar and popup (a boot, or a regular
  lock before the popup opens) no veil draws a guessed silhouette (paper drew a "T" and its shadow; dials centred its rings round
  an empty hub where the popup would be); paper's shadow of the shell comes in over 0.6 s when the bar arrives and follows the
  popup as it opens. The dials' rings centre on the top centre of the screen until the shell names its bar, then on the bar's
  foot, round a small hub of their own; when the popup comes out of the bar they open out round it over 1.2 s (`arriveSeconds`),
  following it as it opens, and a re-cut wave then gives each ring the tick count of its new size, so no ring re-ticks in view.
- **How it is started**: always through `tools/lockscreen/lares-lock-session`, run from a snapshot of a commit
  (`~/.local/state/lares/lock/current`), never from the working tree. Three things call it: the Lock item of the power reel
  (`modules/shell/ReelActions.qml`), hypridle's lock and before-sleep commands (`lock_cmd` / `before_sleep_cmd` in
  `hypridle.conf`; `lares setup` checks them), and at boot `tools/shell/root/lares-boot-lock` (Hyprland's `--locked-cmd`, root step
  R1 of `lares setup`).
- **The boot call is for a session nobody typed a password for.** The autostart's `lares-lock-session --boot` locks an autologin's session.
  Behind a greeter (logind says the session's service is `sddm`, `gdm-password` or `lightdm`, and the compositor was not started with
  `--locked-cmd`) it does nothing; whatever is not known for certain locks (`tools/dev/lock_boot_rule_cases.sh`).
  Hyprland writes its pid file (`hyprland.lock`) about 0.13 s AFTER it has started the autostart, so the rule waits for it (3 s at most,
  and only behind a greeter).
- **The password's PAM service** is `lares-lock`, `qs-lock` where only the old name's file is there, and the TTY's own `login` on a
  machine with neither (a service that is not installed denies everything). The last-resort hyprlock is handed the same one. Root step R2
  installs `tools/shell/root/lares-lock.pam`.
- No keyboard shortcut and no IPC target of its own.

## What you can do

- **Unlock with the password**: type it and press Enter. The field shows dots; a wrong password flushes the field and the line under it
  says so. There is never a timed lockout: only PAM's own short delay after a wrong password.
- **Unlock with the face** (howdy): a scan starts once the session is locked, beside the password, and whichever succeeds first
  unlocks; the face glyph at the end of the field shows the scan (scanning, not recognised, too dark, unavailable). With
  `keyringPassword` on, the face is not offered until the password has opened the login keyring once per boot.
- **Read the machine at a glance**: the time, a greeting on the first unlock of the session (otherwise the date), how long ago it was
  locked; the battery, the weather, waiting updates and screen time (each only when its source is there); the mini vinyl and its
  buttons while music plays, otherwise the wiki card.
- **While locked**, the shell's idle reel and the volume pill still take the pointer ([idle.md](idle.md), [audio.md](audio.md)); everything else of the
  shell is display only.
- **Hidden windows**: windows that match `obscure` are covered by a placeholder while locked.
- **Stillness**: after `idleSeconds` without a key or pointer motion the veil eases to still and stops drawing; a key wakes it.

### The veils

`veil` picks one, or `"random"` draws from `veils` in a shuffle bag (each once per round, never twice in a row):

| Name | What it is (`modules/lockscreen/veil/`) |
|---|---|
| `relief` | a low carved landscape of dune ridges lit by the real sun or moon for the time and place (`VeilRelief.qml`) |
| `gooey` | blobs of the bar's own material welling up and joining like the bar and its popups (`VeilGooey.qml`) |
| `dimples` | a pin-screen of tiny carved wells following slow travelling waves (`VeilDimples.qml`) |
| `paper` | four sheets of the material cut along soft contour lines, drifting over each other (`VeilPaper.qml`) |
| `louvres` | rows of slats turning in slow waves; a key sends a wave out from the field (`VeilLouvres.qml`) |
| `keycaps` | a field of raised keycaps pressed down by waves and by each key typed (`VeilKeycaps.qml`) |
| `dials` | concentric engraved rings turning at their own rates round the popup (`VeilDials.qml`) |

## What it shows and where the data comes from

- **Authentication**: PAM through the `lares-lock` service (`modules/lockscreen/lock/AuthController.qml`), password and face in
  parallel; `tools/lockscreen/howdy-reap` frees the camera when a face scan is given up.
- **The desktop under the veil**: a still of the screen, blurred, with the shell's own surfaces painted out
  (`DesktopLayer.qml`, `DesktopBlur.qml`, `DesktopInpaint.qml` in `modules/lockscreen/lock/`). The still is checked before it is shown
  (`PictureProbe`, shared with the sleep veil): a copy that came out empty -- all transparent or all black, which would be a black
  screen under the rising veil and again under the unlock -- is taken again with a fresh capture, up to three times, each one logged
  `LARESLOCK fact desktop <screen>: S0 empty (<n>)`; after that the lock has no still: the veil rises over the live desktop and the
  desktop is hidden once the veil is up. Hyprland stops drawing the desktop beneath the lock (xray off) only once the veil is up,
  never on the lock's own frame count, and the lock asks for the session only after Hyprland has confirmed it draws the desktop
  beneath (xray on): either the other way round showed a black frame (`tools/dev/sleep_lockenv_film.sh` `ARM=lates0`, `ARM=slowxray`).
- **The popup's figures** come from the shell's services (battery from silicon, weather, system update, screen time, player, wiki),
  handed in by the shell. The lock's own fallback card has the battery and the clock only.
- **Times and dates** follow `locale.jsonc` ([shell.md](shell.md)).

## Settings

`~/.config/quickshell/config/lockscreen.jsonc`, read once when the lock starts (`modules/lockscreen/lock/LockConfig.qml`), and by the shell for
what its popup shows (hot). The commented example `.examples/lockscreen.jsonc` is the full list; when the file is absent the example is what
the lock uses.

| Key | Meaning | Default |
|---|---|---|
| `veil` / `veils` | one veil by name, or `"random"` over the list | `"random"`, all seven |
| `idleSeconds` | seconds without input before the veil stills | 30 |
| `fps` / `batteryFpsRatio` | the veil's frame rate; on battery it is `fps` x this | 60 / 0.5 |
| `blurInMs` / `veilRiseMs` | the desktop's blur-in, then the veil's rise | 250 / 1200 |
| `unlockHoldMs` / `unlockMs` | after a good unlock, hold, then fade to the desktop | 600 / 400 |
| `face` | `"auto"` (use howdy when set up), `"on"` (say what is missing), `"off"` | `"auto"` |
| `keyringPassword` | no face until the password has opened the keyring this boot | `true` |
| `faceRearmCooldownMs` | pause between two face scans | 5000 |
| `fallbackDelayMs` | how long the lock waits for the shell's popup before drawing its own card | 2000 |
| `bootFallbackDelayMs` | the same at boot, before the shell has started (a wrong password brings the card at once) | 30000 |
| `handoverGraceMs` | the card goes when the shell names its bar; it comes back if the popup has not followed within this | 3000 |
| `greetingName` | the name in "Good morning, ..." (`""`: the first word of the account's full name) | `""` |
| `popupBand` | the band's cells in their order: `"battery"`, `"weather"`, `"updates"`, `"screen"` | all four |
| `popupFoot` | what stands at the popup's foot, in order of preference: `"music"`, `"wiki"` | both |
| `greeting` | when the greeting is said: `"boot"`, `"always"`, `"never"` | `"boot"` |
| `faceWhen` | when a scan starts by itself: `"boot"`, `"resume"`, `"return"`, and `"ask"` (a key: always) | all four |
| `lockedControls` | what takes the pointer while locked: `"idle"`, `"volume"`, `"player"` | all three |
| `obscure` | windows covered while locked: a list of `{ "class": regex, "title": regex }` | `[]` (the example's two apply while there is no file) |

The popup's look is tuned in `mockups/lockscreen.qml`; the veils in `mockups/lockveil.qml` (one tab per veil, `VEIL=<name>` at
launch). Save writes the module.

## How it is built

| File or directory | Role |
|---|---|
| `lock/shell.qml` | the lock process's entry (`lock/modules` links to the shell's `modules/`) |
| `lock/warm.qml` | draws every veil once so the GPU's shader cache is warm (`tools/lockscreen/lares-lock-warm`) |
| `modules/lockscreen/lock/` | the lock process: `LockRoot.qml` (the session lock), `LockSurface.qml` (one screen), `AuthController.qml`, `FaceAvailability.qml`, `KeyboardWatch.qml` (gets the keyboard back after a resume), `Obscurer.qml`, `ShellLink.qml` (its end of the socket), `LockConfig.qml`, `VeilBag.js` |
| `modules/lockscreen/LockOwner.qml`, `LockState.qml`, `LockProtocol.js` | the shell's end of the socket, the facts both sides share, the wire format |
| `modules/lockscreen/popup/` | the lock popup: `LockPopup.qml`, the clock (`LockClockBlock.qml`, `LockDigits.qml`), the field (`LockField.qml`, `FaceGlyph.qml`, `LockStatusRow.qml`), `LockInfoBand.qml`, `LockMediaSlot.qml` |
| `modules/lockscreen/veil/` | `LockVeil.qml` (the veils' host and clock), the seven veils, `VeilStage.qml` (the stand-in lock screen the mockups use) |
| `modules/lockscreen/shaders/` | the veils' and the blur's shaders |
| `tools/lockscreen/` | `lares-lock-session` (the one entry point), `lares-lock` (the supervisor), `lares-lock-held` (is a lock up?), `lares-lock-hop` (the keyboard hop's hands), `lares-lock-warm`, `howdy-reap`, `hyprlock.conf` (the last resort's layout) |

Shared components: `DigitCells` (the clock's figures), `ShadowBox` (the carved field), `ConfigFile` (the config).

**The supervisor** (`tools/lockscreen/lares-lock`) is the only thing that starts the lock. It sets Hyprland's
`allow_session_lock_restore` and the rule that draws the shell over the lock before every launch (and, before a boot, relaunched
or replaced lock, a `no_anim` rule for the cover's `lares-lock-cover` layer, so it is black in its first frame), and takes them back
after. A lock
that is not secure within 5 s, or that exits without unlocking, is relaunched once; a second failure hands the session to hyprlock
with the same PAM service. (The lock asks PAM for `lares-lock` and `lares-lock-face` once those files are in `/etc/pam.d`, and for the old
name's `qs-lock` / `qs-lock-face` until then: `lares setup` prints the root step that copies one to the other.) From a TTY, `tools/lockscreen/lares-lock --rescue` ends a lock that will not unlock.

## Limits

- The lock is never started on the desktop by a test: every lock test runs inside `tools/dev/lock_env.sh` (a nested Hyprland with its
  own runtime, config and bus). A mockup shows the popup and the veils, never a real session lock.
- The lock reads `lockscreen.jsonc` once, at start: a change shows at the next lock.
- The lock runs from a snapshot of a COMMIT: an edit to its code reaches the real lock once it is committed and `lares restart`,
  `apply` or `deploy` has moved the snapshot (never while a lock is up).
- After a suspend Hyprland does not hand the keyboard back to the lock surface; the lock gets it back by moving the pointer to
  another output and back (a short-lived headless output on a one-screen machine).

## How to change it

- **Which veils, how fast, how long the unlock fades**: edit `~/.config/quickshell/config/lockscreen.jsonc`; it applies at the next lock.
- **A veil's look**: `quickshell -p ~/.config/quickshell/mockups/lockveil.qml` (the veil's tab), tune, Save; then
  `tools/dev/smoke.sh mockups/lockveil.qml`.
- **The popup's layout**: `mockups/lockscreen.qml`, Save; then `tools/dev/smoke.sh mockups/lockscreen.qml`.
- **The supervisor or the way the lock starts**: `tools/lockscreen/`; gate `tools/dev/lock_supervisor_probe.sh` (runs in a nested
  Hyprland).
- **The desktop's still and its check**: `tools/dev/sleep_lockenv_film.sh` films a real lock under the sleep fade, several sleeps in
  one process; `ARM=emptys0` empties the still (the check finds it, the veil rises over the live desktop), `ARM=emptys0,nos0check` takes
  the check out (black: check L fails). `tools/dev/picture_probe.sh` holds the check itself (offscreen).
- **The boot**: `tools/dev/lock_boot_film.sh` films it in the nested Hyprland, every veil (`floor`) and the shell's arrival
  (`ontime`, `late`, `never`, `fail`), with the compositor kept busy as a real boot's is; `ARM=` puts one fault back (its header).
  The paper veil's shell silhouette: `tools/dev/lock_env/probes/paper_shell_probe.sh` (offscreen); the dials veil's place and its
  arrival: `tools/dev/lock_env/probes/dials_shell_probe.sh` (offscreen; `ARM=guess|noease|nocut` puts one fault back).

Contract (for developers): [contracts/lockscreen.md](contracts/lockscreen.md).
