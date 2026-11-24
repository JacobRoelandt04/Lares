# session -- session restore: the windows and the terminals' programs come back after a log-out

## What it is
Logging out of Hyprland loses every window. Session restore keeps a picture of the session -- every window, where it stands,
and what each terminal runs -- and at the next login starts what was open and puts it back: workspace, floating place and size,
tabbed groups in their tab order with the same tab on show, maximized / fullscreen, pinned, the special workspace, the active
workspace and the focused window. A kitty comes back in its directory with its program: run again by itself when the
program is known to be harmless (`lazygit`, `nvim notes.md`, `btop`, `claude --resume <its session>`), otherwise **typed at
the prompt, not run** -- you press Enter if you want it.

A restore is **prepared out of sight and shown at once**: every window is opened on a hidden staging workspace (no key
reaches it), the groups are built there -- tab order, the tab on show, the lock -- and then everything moves to its place in
one step. You never see five tiles fold into a group. While it prepares, one toast says how far it is.

It ships **switched off** (`config/session.jsonc`, `"enabled": false`). The commands work by hand either way.

## Trying it
```
lares session hook        # prints one line for your ~/.bashrc (once; the terminals opened after it carry the hook)
lares session save        # a picture of the session now
lares session show        # what it holds, and per terminal: RUN <cmd> or type <cmd> (why)
lares session restore --dry   # what a restore would start; starts nothing
lares session restore     # starts what is MISSING, out of sight, and shows it at once (open windows are never moved or doubled)
lares session reveal      # shows any window a restore left on a hidden staging workspace (none, normally)
lares session list | forget [n|--all] | status
lares session classify -- yay -Syu     # the verdict for one command
```
Then `"enabled": true` in `~/.config/quickshell/config/session.jsonc` (example: `.examples/session.jsonc`).

## What happens when it is on
| When | What |
|---|---|
| the power reel's **Log out**, **Reboot**, **Power off** | the picture is saved first (`lares-session end <item>`, at most 3 s, never in the way), then the item runs as always |
| a login after a **log-out** (same boot) | a toast asks: Restore / Discard -- normal urgency, it stays until you answer it (`afterLogout`; `"auto"` restores by itself under the boot lock instead, so the windows stand ready at the unlock) |
| a login after a **reboot / power-off / cold boot** | the same toast (`afterReboot`; any reboot or power-off counts, whoever started it -- the reel, `systemctl reboot` in a terminal, the MUX switch: the watcher asks systemd whether the machine is going down as the session ends) |
| a login after a session that **did not end** (a Hyprland crash, a kill, a power loss) | a **critical, sticky** toast asks; a restore then runs **no** command by itself, every one is typed (`afterCrash`). Never restored by itself: what was open may be why it crashed |
| Hyprland's **safe mode** | nothing, and nothing is touched: the shell does not even run there. The ask comes at the first normal login after it |
| a restore that itself ended in a crash | that picture is never restored by itself again; the ask says so |
| the shell restarts (a deploy, a crash of the shell) | nothing: a decision belongs to a session's start. An ask not answered yet is posted again |
| while the session runs | one small watcher keeps the rolling picture current (on window events, and every 30 s for the terminals' programs); it is what an ask after a crash offers |
| the unlock after a restore made under the lock | the window that had the focus gets it back (Hyprland gives no focus under a lock, so it is given then) |
| while a restore runs | one changing toast: "5 of 13 windows are ready / Waiting for Zen Browser" ("Preparing the windows" from the moment you click Restore, in the ask's place). Not under the lock. It goes when the windows appear, and the result below takes its place |
| after a restore | ONE quiet toast, always -- the status toast's closing: what needs you ("2 commands are typed and wait for Enter", "Postman: did not open", "Windows is still starting: its window opens on workspace 4", 12 s), else "10 windows are back" (6 s; "Everything was already open" when nothing was missing). Under the lock it waits for the unlock. (Until 2026-11-15 a restore that needed nothing ended with no toast at all: the status toast just went, and it read as a fault.) |

An ask waits until the session is unlocked and the bar is on the screen. Dismissing it keeps the picture: `lares session
restore` still works. The newest 5 pictures are kept (`keep`; `lares session list`).

## Terminals: run, or only typed
What a terminal runs is read from `/proc` (the kitty's shell, the terminal's foreground job): the REAL program and arguments,
so an alias cannot hide anything (`lg` reads `lazygit`). The bash hook adds the line as you typed it.

**Run again by itself** only when all of this holds; **typed** otherwise, with the reason in `session show`:
1. the last session ended cleanly;
2. nothing of the job runs as root (`sudo ...` is typed);
3. it is one command -- a pipeline, a redirection or `$(...)` is typed. A **chain** (`cd repo; lg`, `cd repo && claude -r`)
   counts as the command of it that is *running*: what came before it is done (the terminal already comes back in the
   directory the `cd` went to) and is never typed or run again. When commands still *follow* the running one
   (`claude; exit`), it and they are typed;
4. the typed line starts with a program, or an alias for exactly that program -- a shell function, a builtin, `FOO=1 cmd`
   are typed (a function may do anything after the program you see);
5. the program is on the **run list** (`tools/session/rules.json`), with arguments that list allows:
   editors with files (`nvim`, `vim`, `nano`, `hx`; not `-c` / `+cmd`), file managers (`yazi`, `ranger`, `lf`), monitors (`btop`,
   `htop`, `nvtop`), pagers (`less`, `man`, `bat`), `lazygit` / `tig`, followers (`tail -f`, `journalctl -f`, `dmesg -w`),
   `watch` of a read-only command, `git log|diff|show|status|blame`, bare REPLs (`python`, `node`), `claude` (bare, `-r`,
   `--resume`, `--continue`: resumed by the id of the session that was on screen; a prompt argument or a permission flag is typed).

**Everything else is typed, known or not** (your choice of 2026-11-14: a tool nobody listed costs one Enter; a package manager
that re-ran by itself could cost a half-done transaction). The known risky ones carry their reason: package managers, `sudo`,
`rm` / `mv` / `dd`, transfers (`curl`, `rsync`, `scp`), `git push`, `systemctl`, builds, `docker`, `ssh`, scripts.
Add your own in `session.jsonc`: `"run": ["k9s"]`, `"type": ["nvim"]`.

A kitty that ran a program WITHOUT a shell (`kitty --title yazi sh -c yazi`, a launcher entry with `Terminal=true`) is started
the same way when the program is on the run list; otherwise (a program not on it, or any program after a crash) it comes back
as a shell in the same window -- its title and options kept, so your window rules still match it -- with what RAN typed
(`yazi`, not `sh -c yazi`).

A terminal started as `kitty --hold <program>` whose program is over (`kitty --hold fastfetch`: it ran, and kitty put a
shell in its place) comes back as that plain shell: the held program is not run a second time.

Only a program that is RUNNING when the picture is taken counts. A command that had finished is never run again, and the
command that takes the picture (`lares session save` typed in a terminal) is no part of it: that terminal comes back at
its prompt.

### The bash hook (`tools/session/session-hook.bash`)
One sourced file, last in `~/.bashrc` (`lares session hook` prints the line). It does two things with shell builtins:
- **the mark**: while a command runs, its typed line stands in `$XDG_RUNTIME_DIR/lares-session/tty/pts-<n>` (0600, memory only),
  with what each command word of it is (a program, an alias and its value, a function, a builtin) -- which is how a chain's
  running command is told from the ones already done. Emptied at the next prompt. No fork (bash 5.3), about 0.3 ms a command.
  A terminal opened before a deploy keeps the hook it loaded: after a change to the hook, its lines are judged by the older
  mark (a chain's running command is then typed, not run) until that shell is restarted.
- **the claim**: a terminal a restore opened carries a token; its command is run in the shell (quit the program: a prompt), or
  written at the prompt unexecuted -- through readline itself, no remote control, nothing injected into the terminal.

Without the hook windows, directories and shell-less kitties still come back; a shell's program does not, and the restore says
so ("not taken by a shell").

## Apps
- **Any app** is started the way its launcher starts it (its `.desktop` entry, with the documents it had open as arguments;
  else its command line) in its old directory, and its window is put back.
- **Apps that reopen their own windows** (Zen, Firefox, VS Code, Vesktop, Postman; `"selfRestore"` in `rules.json` or your
  `apps`) are started ONCE; their windows are told apart by title and moved to where each was. What is IN a window is the
  app's own business. For VS Code (one process, several windows) the capture records each window's folder (its title's root
  name resolved against `~/.config/Code/User/workspaceStorage`); the restore starts `code`, waits for its own restore to
  settle, then opens each saved folder that is not open with `code -n <folder>`. A window whose folder is not found is
  left to VS Code.
- **The Windows VM** (`com.freerdp.client.sdl3`): started through its own launcher (`windows-vm.desktop`), which connects at
  once to a VM that still runs -- the usual case after a log-out, the container outlives the session -- and boots one that
  does not (after a reboot: up to minutes). It is a `"slow"` app: its window is never held back or waited for long; a
  temporary window rule puts it on its workspace whenever it opens, and until then the result toast says it is still
  starting. `"apps": { "com.freerdp.client.sdl3": { "skip": true } }` leaves it out.
- **Not started**: an app set to `"skip"`,
  an app with no known way to start it (`session show` says "NOT restored").
- A new app needs no entry: it is started and placed; only state inside it is its own.

## Where it lives
| File | What |
|---|---|
| `tools/session/lares-session` | the tool: `save`, `list`, `show`, `restore`, `forget`, `status`, `classify`; for the shell: `begin`, `watch`, `end`, `answer` |
| `tools/session/sessionlib/` | `hypr.py` (Hyprland's sockets, no fork), `procs.py` (/proc), `capture.py`, `classify.py`, `policy.py`, `plan.py`, `restore.py`, `state.py` |
| `tools/session/rules.json` | the run list, the reasons of the typed ones, the apps |
| `tools/session/session-hook.bash` | the bash hook |
| `modules/session/SessionService.qml` | the shell's part: when to decide, the asks, the watcher (one per shell) |
| `modules/shell/ReelActions.qml` | the save before Log out / Reboot / Power off |
| `~/.config/quickshell/config/session.jsonc` | your settings (example `.examples/session.jsonc`) |
| `~/.local/state/lares/session/` | `state.json`, `rolling.json`, `snapshots/` (0600; the newest `keep`, 5) |
Contract: `docs/contracts/session.md` (the snapshot, the state, the pending command, the policy table, the measured facts).
No mockup: the module draws nothing of its own (its toasts are notification cards).

## Limits
- **Right after a login on a cold GPU shader cache the shell's UI can stand still for tens of seconds**, and so does the status toast. The
  restore is its own process and is not held up: the windows come, while the toast waits at its last count (the user's "stuck at 6/10",
  2026-11-15: the shell's start-up warm-up compiled a large shader on the NVIDIA GL path, first frames of the third prewarm entry,
  about 28 s with no frame; the tool's lines waited in the pipe and the toast caught up at once, then closed). Nothing in the toasts is wrong
  then -- `session_toast_probe.sh` `stall` holds the GUI thread for seconds and proves the catch-up. It is the warm-up's cost (docs/contracts/gooey_engine.md, the
  prewarm), paid once per changed shader.
- **A window on a staging workspace is not drawn** until it is shown (Hyprland answers no frame to a hidden workspace), so
  an app may repaint once in its first frame on screen. A window that opens after its restore has given up (later than
  10 / 30 s) can still land on a staging workspace for a minute: the restore leaves a helper that shows it, the watcher
  shows it too, and `lares session reveal` does it by hand.
- **Tiled layout is approximate.** Workspace, floating geometry, groups, their tab order and their lock are exact. A dwindle tree is not
  readable from Hyprland: tiled windows are opened in reading order and swapped onto the saved place nearest to them; split
  ratios are Hyprland's.
- **Scrollback, shell variables, a program's inner state** (a menu you were in) do not come back.
- **One terminal per kitty process** (your setup: new tab is disabled). A kitty with several tabs / OS windows comes back as
  its first terminal; the picture says so.
- **A window that opens later than 10 s (a terminal) / 30 s (an app)** is reported missing and is not placed.
- **Other exits** than the reel's (`hyprctl dispatch 'hl.dsp.exit()'` typed by hand) leave no end mark: the next login asks
  as after a crash. A reboot or power-off from anywhere else is seen two ways: the watcher asks systemd while the session ends (it races the
  shutdown and often loses; each try is a line in `~/.local/state/lares/session/watch-end.log`), and the NEXT start asks the
  previous boot's journal for logind's "System is rebooting / powering down" -- the guarantee. A power cut or a crash leaves
  no such line and stays a crash.
- **Apps are not asked to quit** before the session ends (as before: Hyprland drops them). A browser that restores its own
  windows does so from its own crash recovery.
- Command lines in a picture are stored as typed (0600), the same exposure as `~/.bash_history`.

## Presets
A preset is a named picture of the WHOLE desktop (every workspace, the special one too): arrange the desktop, save it as
"dev", load it later. It is a snapshot of the kind `save` makes, kept until you delete it, in
`~/.local/share/lares/session/presets/<name>.json` (0600; never rotated away with the snapshots). Presets work whether
`"enabled"` is on or not. The popup that lists them lives on a bar button (the `presets` module, built separately); this
is the tool it calls.
```
lares-session preset list [--json]                      the presets, by name
lares-session preset current [--json]                   the desktop as it is now
lares-session preset save <name> [--over]               keep the desktop as <name>; refused when the name exists (--over replaces it)
lares-session preset rename <old> <new>                 lares-session preset delete <name>      lares-session preset undelete <name>
lares-session preset load <name> --add | --replace [--dry]
```
A name is 1-40 characters; two names that differ only in case or punctuation are one preset ("Dev" and "dev!"). Delete puts
the file in a trash folder: `undelete` brings it back until the next successful save sweeps it.

**Two ways to load.** `--add` keeps everything that is open and adds what the preset has and the desktop lacks. `--replace`
first closes every open window the preset has no place for (the special workspace too; never the shell's own windows or a
class in `skipClasses`, nor one of an app you set to `"skip"`), then does what `--add` does. `--dry` lists what would close,
what would be moved and what would be opened, and changes nothing: the popup asks you with it before a replace.

**A window that is open already is moved, not opened twice.** In both modes a window the preset has is REUSED when an open one
stands for it, and moved to the preset's place (workspace, float size and position, group membership and tab order, the tab on
show, the group's lock, fullscreen, pin), together with the windows that are started, in the same single step. What stands for
what:

| Saved window | An open window stands for it when |
|---|---|
| a terminal (kitty) | it is in the same directory AND runs the same program (the first word of the job), or both are at a prompt. A terminal running something else is not reused (a program cannot be changed from outside): the saved one is opened beside it |
| VS Code | it has the same folder |
| a browser or another app that restores its own windows | same class: windows with the same title first, then in order |
| any other app | same class; where the class has several windows, the same title too |

Every open window is used once.

**Terminals the preset starts** follow the rules of a restore after a clean session (`run` list: run by itself, anything else
typed at the prompt), with one difference: a Claude Code job (`claude`, `claude --resume <id>`, `-r`, `--continue`) comes
back as a bare `claude` in its directory, a fresh session, never the old conversation.

**Closing is polite.** A replace asks each window to close (the app is never killed) and waits up to `"closeTimeoutMs"`
(default 8 s, `session.jsonc`) for it to go. A window that asks first (unsaved changes) stays open; the result lists it as
`kept` and the load goes on. Nothing is opened or moved before the close step is over.

**Limits.** A preset does not reproduce a dwindle tree (windows arrive in reading order and are swapped to the nearest saved
place), a program's own state, or which window of a preset's workspace is on which monitor beyond the workspace number. A
terminal the preset reuses keeps what it shows. A load never answers a pending login restore, and a crash during one is an
ordinary crash (the rolling picture is what comes back).

## Checks
```
python3 tools/dev/session_cases.py          # the tables: run-or-type, /proc, the policy, a session's start, the plan
tools/dev/session_hook_probe.sh             # the bash hook on a pty
tools/dev/session_service_probe.sh          # the shell's service on a stub tool
tools/dev/session_toast_probe.sh            # the three toasts on the REAL lane and stack: ask -> status -> closing confirmation,
                                            #   the same across a stalled UI thread, and with the start-up prewarm running
tools/dev/session_env_probe.sh              # a real session saved, closed and restored in the nested Hyprland
                                            #   MODE=half (part of it open)  MODE=locked (under a session lock)
                                            #   MODE=preset (save, rearrange, load --add, load --replace)
```
Each has `ARM=all`. None touches the desktop.

## How to change it
- A program should run by itself / never: `"run"` / `"type"` in `session.jsonc`; for everyone, `tools/session/rules.json`
  and a line in `tools/dev/session_classify_cases.tsv`.
- An app opens its windows itself: `"apps": { "<class>": { "selfRestore": true } }`.
- What a login does: `afterLogout`, `afterReboot` (`"ask"`, `"ask-critical"`, `"auto"`, `"off"`), `afterCrash` (`"ask"`, `"off"`).
- A Claude Code terminal of a restore: `"claude"` -- `"resume"` (its conversation goes on), `"fresh"` (a new one in its folder), `"type"`
  (the command waits at the prompt). A preset's: `"presets": { "claude": "fresh" | "resume" }`; `"confirmReplace": false` loads a preset
  that closes windows without asking first.
- How many pictures are kept: `"keep"` (5; 1 to 100). The toast that closes a restore or a preset load: `"resultToast"` (`"always"`,
  `"needs"`: only when something needs you, `"off"`).
- An app's `"launch"` is a list (`["code", "--new-window"]`); anything else leaves the built-in way to start it. `"terminals"` lists the
  terminal classes, and kitty is the only one the capture knows.
