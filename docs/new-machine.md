# Lares on a new machine

Written while the desktop was set up from nothing on 2026-11-22 (an i5 with an NVIDIA card and one ultrawide: no battery, no
backlight, no internal panel, SDDM asking for the password). The steps in the order that works, and what is different on a machine
that is not the laptop. `lares setup` checks all of it, one line each, and can be run between any two steps.

## The steps

1. **The checkout**, and the command on your `PATH`:
   ```bash
   git clone git@github.com:JacobRoelandt04/Lares.git ~/.config/quickshell
   mkdir -p ~/.local/bin && ln -s ~/.config/quickshell/tools/shell/lares ~/.local/bin/lares
   ```
2. **The packages**: `lares setup` prints one `pacman` line (and one for the AUR) with what is missing; what each thing is for is
   `tools/shell/needs.tsv`. The names there are packages, not commands.
3. **The lock's password file**, before anything can lock: root step R2 of `lares setup`. Without it the lock asks the TTY's own
   `login` stack, so it can always be opened, but a login keyring is not unlocked by it.
4. **Your settings.** `~/.config/quickshell/config/` is in no repository. Copy the folder from the other machine
   (`tar czf` and KDE Connect will do), or start empty; then `lares init` writes what this machine's hardware asks for (only files
   that are not there) and prints what your own files lack.
5. **Your Hyprland config**: `lares binds` prints every line the shell needs and compares yours.
6. **The other notification daemon**: the shell is the notification server. Mask the old one so that D-Bus does not start it again
   (`systemctl --user mask mako.service`).
7. **`lares deploy`**, then log out and in (the autostart line runs `lares start`), or start it at once in the running session:
   `hyprctl dispatch 'hl.dsp.exec_cmd("'$HOME'/.local/state/lares/shell/current/tools/shell/lares start")'`. The first start writes
   `~/.config/hypr/config/panorama.lua` (the displays) by itself when your config already loads it.
8. **The lock, once, by hand** (the power reel), with a way out known first: Ctrl+Alt+F3, log in, and
   `~/.local/state/lares/lock/current/tools/lockscreen/lares-lock --rescue`. Only then hypridle, which locks before it suspends.
9. **The rest, each on its own**: the screen-time daemon (`lares setup` prints the line), `themectl migrate` (what it would edit:
   `--dry-run`), `tools/stt/setup.sh` (dictation, about 10 GB), an Ollama model, the group-tabs plugin
   (`make -C tools/hypr-group-tabs && make -C tools/hypr-group-tabs install`), the two lines of `~/.bashrc`
   (`tools/shell/sudo-offer.bash`, `lares session hook`).

## What differs from machine to machine

| | Where |
|---|---|
| a module this machine has no use for | `shell.jsonc` `"modules": { "silicon": false }`: no service, no button, no key, no process; read at the shell's start |
| the size | `shell.jsonc` `scale.global` (1.25 on the laptop's small dense panel, 1 on the 34-inch) |
| an LCD | `shell.jsonc` `"oled": { "enabled": false }` |
| the wallpapers | `shell.jsonc` `theme.wallpapers`: a list may name pictures that are not here (they are left out of the draw) |
| the keyboard's light | `osd.jsonc` `"kbd": { "device": "" }` (none) or another LED's name |
| a desktop's DP socket | `panorama.jsonc` `"portLabels": { "usbc": "DisplayPort" }` |
| the displays themselves | the panorama popup; its data is `~/.local/state/lares/panorama/setups.json`, per machine |
| Hyprland's own lines | a git-ignored `config/host.lua` your `hyprland.lua` loads last with `pcall(require, "config/host")`, and a `hypridle.host.conf` for other times |

Nothing has to be switched off by hand for a battery, a backlight, a lid or a keyboard light that is not there: what reads one finds
nothing and does nothing. `silicon` is the one module that is a machine's own (an ASUS laptop's).

## Suspend, on a machine nobody has seen sleep

`tools/dev/suspend_lab.py check` says what is known to be in the way, `history 400` every suspend the journal holds. Then, in a terminal of
yours (it asks for root by `sudo`): `stage devices`, `ladder`, `sleep`, each with `--without <module>` for a driver that refuses. The first two
are the kernel's rehearsals, the machine does not sleep. A test that never comes back is filed at the next `check`, with the kernel's last line.

On the desktop the memory's temperature sensors (`spd5118`, DDR5) refused 30 of 34 suspends between 2025-10 and 2026-01; the one boot without that
driver slept and came back with no error. What it costs to do without is the sticks' temperatures. A refused suspend locks the screen and does
nothing more.

Tried 2026-11-22 (kernel 7.3.5, nvidia-open 620.73.04, Hyprland 0.57.2): without `spd5118` a real S3 sleep of 17 s, woken by a USB device, came back
with no driver error. With it the rehearsal went in and the sensors failed to RESUME (-6); a real sleep with it is untried. The ladder stopped at
`platform`, on NVIDIA's `Flip event timeout`. Seen once, in a rehearsal: the machine was back and Hyprland drew nothing for 37 s, until the mouse
moved (the kernel's log says PASS; the frame journal's `latency` record has it). A second real
sleep, 57 s, was woken by the alarm with no hand on the machine: the picture came back by itself. Open: the bar missed ~1 s of frames about 15 s
after both resumes (frame journal, 20:35:04 and 20:45:24), cause not known.

Hibernation needs no swap partition: a swap FILE on ext4 as large as the memory and the `resume` hook in mkinitcpio; on UEFI systemd notes the
file's place itself (`HibernateLocation`), elsewhere `resume=` and `resume_offset=` say it. The reel's Hibernate runs nothing until the
machine's `config/power.jsonc` gives it a command ([power.md](power.md), Limits): wire it once a real hibernate and resume have passed there.

## To work on the shell there

The dev kit (`tools/dev/`, [tools.md](tools.md)) needs more than the shell does: `mutter` (it hosts the nested Hyprland), `wtype`,
`wf-recorder`, `bubblewrap`, `rsync`, `lua`, `nodejs`, `qt6-shadertools` and `glslang` (the shaders), `python-numpy` and
`python-scipy` (the silkscreens). `tools/dev/lock_env.sh up` is the first thing to try. On the desktop the quick tier is green but for
what is not installed there.

## Traps

- **An autologin or a greeter.** `lares-lock-session --boot` is in the autostart of every machine. With SDDM's autologin it is the
  boot's lock; behind a greeter that asked for the password it does nothing. Whatever it is not sure of, it locks.
- **The session's `PATH`** is not your terminal's: `~/.bashrc` is read by terminals only, and hypridle's `command -v screentimed`
  finds nothing in `~/.local/bin` until the session has it (`hl.env("PATH", ...)` in `host.lua`).
- **NVIDIA as the only GPU.** Name every EGL platform file but `09_nvidia_wayland2.json` in
  `__EGL_EXTERNAL_PLATFORM_CONFIG_FILENAMES` (`lares setup`, "NVIDIA EGL platform"), or every frame is held one refresh longer.
- **A dotfile manager that still owns the old files** (chezmoi's source held the desktop's old `.config/hypr`, kitty theme and
  starship prompt): an `apply` there puts them back over the new ones.
- **`theme.lua`, `hyprlock-colors.conf` and `hyprpaper.conf`** are written by `themectl`. Tracked in a repository two machines
  share, they differ at every theme switch.
- **`qt.qpa.services: Failed to register with host portal`** in the shell's log is Qt's `xdgdesktopportal` theme registering twice. It
  harms nothing; `~/.config/QtProject/qtlogging.ini` with `[Rules]` and `qt.qpa.services.warning=false` silences it.
