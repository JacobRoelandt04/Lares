# Contract: session restore

The fixed names and formats between `tools/session/lares-session`, `tools/session/session-hook.bash` and
`modules/session/SessionService.qml`, and the facts they were built on. User page: `docs/session.md`.

## 1. Who does what
- **The tool** (`lares-session`, Python, no shell needed) owns every fact: the snapshot, the state file, the policy, the restore.
- **The hook** (bash) owns a terminal's two halves: the mark of the running line, the claim of a pending command.
- **The service** (QML) only says when (`begin` once at its start, `watch` while it runs) and talks to the user (the ask, the
  status toast, the closing result: ALWAYS one -- what needs the user, else how many windows are back). The power reel calls `end`.
A second implementation of a rule in QML is not allowed: the policy is `sessionlib/policy.py` alone.

## 2. Files
```
$XDG_STATE_HOME/lares/session/      0700; files 0600
    state.json       { "current": <session>, "candidate": <candidate> }
    rolling.json     the live session's snapshot (the watcher; removed by `begin`)
    snapshots/<id>.json   <id> = <YYYYmmdd-HHMMSS>-<reason>, reason: manual | logout | reboot | poweroff | system | unclean
    lock             flock: one writer of state.json, one restore
$XDG_RUNTIME_DIR/lares-session/             0700; this boot only
    pending/<token>  "run" | "type" on the first line, the command after it
    tty/pts-<n>      the hook's mark; EMPTY at a prompt.
                     line 1: the kind of the line's first word (`type -t`: file | alias | function | builtin | keyword |
                             empty), then TAB-separated triples `word, kind, alias value` for every word of the line that
                             names a command (the line cut at blanks and `; & | ( )`; options and assignments left out)
                     line 2: the first word's alias value
                     the rest: the line as typed
                     (a mark without triples is a hook older than them: its `words` read empty)
config/session.jsonc                     the user's (ConfigFile rule); .examples/session.jsonc
```
`<session>` = `{sig, bootId, hyprPid, started, ended: null|"logout"|"reboot"|"poweroff"|"system", endedHow (with "system":
"reboot"|"poweroff"|"system"), endedAt, endSnapshot,
restoring: null|{snapshot, since, done}}`.
`<candidate>` = `{snapshot, decision, cause, clean, summary, time, answered, from: <the previous session>}`.

## 3. The snapshot (version 1)
`sessionlib/capture.py` has the field list. The rules:
- a window's `at` is relative to its monitor; a workspace's `key` is its number, else its name (`HyprWs.key`'s rule);
- an **app** is one process and class: several windows of one pid are one app (`count`), started once;
- a kitty is `kind: "terminal"` by its PROCESS (argv[0] `kitty`), whatever class it was given; `terminal` =
  `{opts, program, shell, cwd, rootArgv, job}`; `job` = `{tops: [{argv}], typed: <mark>|null, root, claude}`;
- a group's tab on show is the member Hyprland calls `visible` (then `acceptsInput`, then the least `focusHistoryID`); its
  `locked` comes from the compositor's Lua (`Hypr.group_locks`: `window.group.locked` written to a file; no hyprctl answer has it);
- a window standing on a STAGING workspace (section 6) is saved as its target workspace's;
- tags set by a window rule (`name*`) are not saved.

## 4. The tool's calls for the shell
| Call | Answer | Notes |
|---|---|---|
| `begin` | one JSON line `{decision: none|auto|ask|ask-critical, cause, clean, snapshot, summary, time[, repeat]}` | once per shell start. Same signature as the recorded session: `none`, or the unanswered ask again (`repeat`). Safe mode: `none`, nothing written. Otherwise it freezes the previous session's picture, decides, and records the new session |
| `watch` | `watching <sig>`, `wrote <summary>` per write, `stopped (signal|gone)` | started AFTER `begin` answered. Skips while a restore is in flight. Clears `restoring` 60 s after it finished. At its end asks whether the machine is going down (`system_end_kind`: `systemctl is-system-running` = `stopping`, or logind's `PreparingForShutdown`; the queued target names `endedHow`): yes -> `ended: "system"` |
| `end <logout|reboot|poweroff>` | `ended ...` | the reel, under `timeout -k 1 3`, status ignored |
| `restore [id] [--type-all] [--dry] [--no-focus] --json [--progress]` | the result line `{event: "result", restored, planned, skipped[], failed[], later[], ran, typed, waiting[], unclaimed, refocus, ms, snapshot}`; with `--progress` first `{event: "start", total}`, `{event: "progress", done, total, waiting[names]}` per change, `{event: "reveal"}` | exit 1 when something failed, 3 no snapshot, 4 refused (safe mode, another restore). `later`: slow apps not there yet `{name, workspace}`. After the result a child may linger (up to 65 s) for a late window |
| `reveal` | `revealed N windows` | every window on a staging workspace goes to the workspace its name stands for |
| `answer <restore|discard>` | | marks the candidate answered (a restore marks it itself) |
| `refocus` | `focused <address>` / `nothing to focus` | a restore under a session lock answers `refocus: true`: Hyprland gives no window the focus there, so the address is kept in `current.refocus` and the service calls this once at the unlock (exit 4 while locked) |

## 5. The policy (`policy.decide`)
| Previous session | Decision |
|---|---|
| this session runs in safe mode | none |
| nothing saved / no windows / older than `maxAgeHours` | none |
| not ended, and a restore was recorded (running, or finished < 60 s ago: the watcher had not cleared it) | ask-critical, "The last restore ..." -- its own snapshot is the candidate |
| not ended | ask-critical (`afterCrash`; never auto), `clean: false` |
| `logout`, same `bootId` | `afterLogout` (default `ask`) |
| `reboot` / `poweroff` / `system`, or another `bootId` | `afterReboot` |
`afterLogout` / `afterReboot`: `ask` (normal urgency), `ask-critical`, `auto`, `off`; both asks stay until answered and are
`clean` after a clean end. `clean: false` (an unclean end only) makes every command `type` (classify rule 1); the toast's
"nothing is run by itself" sentence follows `clean`, its urgency follows the decision.

### A chain (`classify._chain`)
A typed line with top-level `;`, `&&`, `||` or newlines is cut (`split_chain`, quote-aware). The RUNNING part is the one
whose first word -- by the mark's triples: a program, or an alias for one -- names a process at the top of the foreground job;
exactly one part must. The parts before it are done and dropped; with parts after it, the running one and they are typed.
Not told apart (two parts name the program, none does, a mark without triples for a later part): the real argv is typed.
The command that takes the picture is never a job: `procs.ancestry(own pid)` is excluded (`terminal_windows(ignore=)`).

## 6. A restore
**Staging.** A window is never opened where the user can see it. Its workspace's STAGING workspace is
`special:lsr-n<number>` (a numbered workspace) or `special:lsr-s<hex of the name>` (a named or special one):
`plan.stage_name` / `plan.stage_target`. The name alone says where its windows belong -- the one rule the reveal, the
sweep and the capture share.

1. Refused in safe mode. `reveal_stranded` first (an earlier restore cut short). The plan (`plan.build`, pure) skips a saved
   window an open client stands for (class + title) and an app that already runs; nothing that is open is moved. Skip, slow
   and selfRestore are read from TODAY's rules, never from a picture's stored verdict.
2. Per app:
   - `token`: `hl.dsp.exec_cmd("env [-C cwd] LARES_SESSION_TOKEN=<t> <argv>", { workspace = "<staging> silent",
     no_initial_focus = true [, float, size, move] })`; the new client is the one whose process environment has the token.
   - `multi` (`selfRestore`, or several windows on one pid): a temporary window rule `lares-session-<app>` (`workspace <staging
     of its first window> silent`), started once, its windows paired by title when as many as were saved are open and 1.2 s
     have passed; the rule is disabled.
   - `slow` (`"slow"` in the rules: the Windows VM's viewer): the same kind of rule but on the app's OWN workspace, ending
     itself after 10 min (`hl.timer`); awaited like any app, and when it has not come reported in `later`, its rule left on.
   A terminal whose `--hold` program is over is started without it. A terminal with a command: `pending/<token>` first.
3. **Prepared** on the staging workspaces, by address: each window on the staging workspace of its own target (a multi app's
   windows all opened on one), a float's size and place, the groups (`group.toggle` on the first member, `Group:add` for
   the others in tab order, `group.active`, then the lock -- `group.lock` TOGGLES, so the group is asked first), tags. A
   single restored tab of a group whose other tabs are already open is no group.
4. **Revealed**: ONE Lua chunk (`Hypr.run_lua`: a file, `dofile`) with a `pcall`-wrapped `window.move` per staged tile in
   reading order -- a group is one tile and goes with its first member -- then `window.pin` / `window.fullscreen`. It runs
   in a `finally`: whatever failed before, nothing stays hidden. `reveal_stranded` follows for what the chunk left.
5. **Settled** in sight: tiled windows swapped onto the nearest saved place, floats re-checked, each monitor's active
   workspace and the focused window (the pointer put back; owed to `refocus` under a lock).
6. `current.restoring` is set before the first start and `done` after the last step.
7. **Never lost**: Hyprland keeps an exec rule 60 s, so a window later than its launch's timeout still lands on staging.
   The command forks a child that stays that long and sweeps on every `openwindow`; the watcher sweeps before every
   picture; `lares-session reveal` sweeps by hand.

## 7. The hook
- Sourced LAST in `~/.bashrc`. It appends ONE element to `PROMPT_COMMAND` (made an array) and `${ __lares_sr_mark; }` to `PS0`.
- **Claim**: `LARES_SESSION_TOKEN` set -> `mv -n pending/<token> pending/<token>.<pid>`; the shell that renamed it owns it; the token
  is unset. At the first prompt: `run` = `history -s`, the mark, `eval`; `type` = `history -s`, `bind -x '"\e[0n": fill'`, and
  `\[\e[5n\]` appended to that prompt -- the terminal's answer is the key that fills `READLINE_LINE`.
- The fill re-binds the key to an EMPTY MACRO: bash redraws the prompt's last line after a `bind -x` command, which sends the
  query again; unbound, readline inserts the answer's `n`; still bound to the function, query and answer run for ever.

## 8. Measured (Hyprland 0.57.2, kitty 0.50, bash 5.3; `tools/dev/lock_env.sh`)
- `hyprctl dispatch 'hl.dsp.exec_cmd(cmd, {...})'` takes the rule table; `workspace = "N silent"`, `"special:x silent"`,
  `float`, `size = "w h"`, `move = "x y"`, `no_initial_focus` apply to the ONE window that carries Hyprland's own exec token.
- `hyprctl eval` answers `ok` and returns no value; state is read through the `j/` requests. Lua's `io` works there.
- `hl.dsp.group.toggle({ window })`, `hl.get_window(sel).group:add(window[, index])`, `hl.dsp.group.active({ index, window })`
  (index from 1, required), `hl.dsp.window.swap({ window, target })`, `window.move({ workspace, follow = false, window })`,
  `window.move({ x, y, relative = false, window })`, `window.resize({ x, y, relative = false, window })`,
  `window.float({ action = "set"|"unset", window })`, `window.pin`, `window.fullscreen({ action = "set", mode, window })`
  all work on a window that has no focus, on a workspace that is not shown, and under a session lock.
- Under a session lock `hl.dsp.focus({ window })` changes nothing (the workspace switch does work); after the unlock the focus is
  Hyprland's own choice. Focusing a window warps the pointer: `Hypr.focus_window` reads `hl.get_cursor_pos()` first and moves it back.
- A special workspace nobody shows is laid out at the monitor's full size (`dwindle:special_scale_factor` 1, the default and the
  user's), exists while it holds a window and is in no monitor's `specialWorkspace`. `window.move({ workspace })` of ONE member
  of a group moves the whole group, its order and its tab on show. A chunk of moves run by `hyprctl eval 'dofile(path)'`
  happens between two frames and reproduces the staged geometry exactly (two tiles and a float: 0 px moved).
- `hl.dsp.group.lock({ window })` toggles; `action = "lock" | "unlock" | "set"` toggle too (0.57.2). `window.group.locked`,
  `.current_index`, `window.workspace.name`, `window.at.x` are readable in Lua; `io.open` and `dofile` work in an eval;
  `hl.timer(fn, { timeout = ms, type = "oneshot" })` fires.
- A window rule made by `hyprctl eval` returns a handle: kept in a Lua global, `:set_enabled(false)` ends it.
- kitty: one process per OS window here, so a client's `pid` is the kitty; its children on a pts are the windows' root
  programs; `kitty --hold cmd` ends as `bash` (kitty's run-shell). `remember_window_size` (kitty's default) makes a floating
  kitty ask to be maximized: the test env sets it off, as the user's config does.
- Python restarts a `select()` interrupted by a signal whose handler returns (PEP 475): the watcher's TERM handler raises.
- logind's `PreparingForShutdown` (systemd 262) is true only WHILE a delay inhibitor holds a shutdown back (VS Code's "Ensure a
  clean shutdown"), false again once the job runs -- before the session is torn down and the watcher told to stop -- and never
  true with no delay inhibitor: the user's two MUX reboots of 2026-11-15 (`systemctl reboot`, no reel) were recorded as crashes.
  `systemctl is-system-running` reads `stopping` from the moment the shutdown's job is queued; `systemctl list-jobs` names the
  target (reboot / poweroff / halt / kexec).
- The watcher's mark still loses the race (the scopes die ~25 ms after the request). `begin` therefore asks the PREVIOUS boot's
  journal (`journalctl -b <id> -u systemd-logind -g 'System is (rebooting|powering down|halting)'`, 4 s, fails closed, never for
  the same boot) when the old record has no `ended` and another bootId; a hit is `ended: system` with `endedHow` / `endedAt`
  (`journal_end`; cases group `begin`, ARM nojournal). `watch-end.log` keeps the last 200 tries of the watcher.
- A snapshot window of an app whose rule has `folders` (VS Code) carries `folder` (path or .code-workspace); its `multi` launch
  carries `folders {windowId: folder}` and `restore` opens the missing ones with `<cmd> -n <folder>` after FOLDER_SETTLE_S
  without a new window (cases group `vscode`, ARM nofolders).

## 9. Presets
A preset is a named picture of the whole desktop. Written by `lares-session preset ...` only; the QML side (the `presets` popup)
speaks `--json`. Work whether `config/session.jsonc` `enabled` is true or not.

**File.** `$XDG_DATA_HOME/lares/session/presets/<slug>.json` (default `~/.local/share/...`; dir 0700, file 0600, atomic writes under
the state lock) = a version-1 snapshot (section 3: what `capture` makes) plus `"preset": {"name", "created", "updated"}` (epoch
seconds). Outside `snapshots/`: the rotation (`keep`) never touches one. `.trash/<slug>.json` holds a deleted one; the next successful
`save` sweeps `.trash/`. `slug` = the name lowercased, runs of characters outside `[a-z0-9]` -> `-`, trimmed; a name is 1..40
characters after a strip and must have a non-empty slug; two names with one slug are one preset (`exists`).

**Verbs** (exit: 0 ok, 4 refused, 2 usage / bad name, 3 nothing to do or no compositor, 1 failed). `--json` answers ONE object:
| Call | Answer |
|---|---|
| `preset list [--json]` | `{"presets": [{name, slug, created, updated, windows, workspaces, face}]}` sorted by name, case-insensitive (no `--json`: a table) |
| `preset current [--json]` | `{windows, workspaces, face}` of the live desktop (a capture, nothing saved) |
| `preset save <name> [--over] [--json]` | 0 `{"ok": true, name, slug}`; the name exists without `--over`: 4 `{"ok": false, "reason": "exists"}`; a bad name: 2 reason `name`. `--over` keeps `created`, moves `updated`, takes the new spelling |
| `preset rename <old> <new>`, `delete <name>`, `undelete <name>` `[--json]` | 0 `{"ok": true, name, slug}`; 4 reason `missing` or `exists` (a rename onto another preset, an undelete over a live one); 2 reason `name` / usage. `rename` keeps `created`; a case-only rename stays under its slug |
| `preset load <name> --replace\|--add [--dry] [--json [--progress]]` | below |

**FACE** (what the popup draws): `{"monitors": [{name, w, h}], "workspaces": [{key, name, special, monitor, windows: [{class, title,
at: [x, y], size: [w, h], floating, fullscreen: int, pinned, group: null | {id, index, active, size, locked}}]}]}`. `w`/`h` are LOGICAL
(pixel width / scale, rounded); `at` is relative to the window's monitor (as the snapshot stores it); `size` logical; only workspaces
that hold windows, numbered ascending, then named, then special ones; `group.size` = the members in the preset; a workspace's
windows are in reading order (`plan._order`). `key` is a string (`"2"`, `"work"`, `"special:default"`).

**Load.** `--add`: nothing open is closed; what the preset has and the desktop lacks is started. `--replace`: first every open window
no preset window stands for is closed (the capture's own skip rules: the shell's windows and `skipClasses` are not in a capture;
plus the classes whose rule says `skip`), then the same. Refused with exit 4 and `{"ok": false, "reason": "missing" | "safe-mode" |
"busy"}` (`--json`) / stderr; a preset with no windows is exit 3 reason `empty`.
- `--dry --json` -> `{"close": [{address, class, title}], "reuse": [{address, class, title}] (the open windows that will be moved),
  "launch": [{class, name}] (one per window to start), "skipped": [...]}`; `close` is `[]` in `--add`. Nothing is touched.
- A real run with `--json --progress` prints the lines of a restore (`{event: "start", total}` with `total` = reused + started,
  `progress`, `reveal`), then the restore's result line (section 4) plus `"reused": N, "closed": N, "kept": [{class, title}],
  "preset": "<name>"`; `restored` counts the reused windows too. Exit as `restore`.

**Reuse** (`plan.match_reuse`, pure, over the preset and a fresh capture of the desktop; each open window used once; the preset's
windows taken in reading order; today's rules judge):
| Saved window | Stands for it |
|---|---|
| terminal (kitty by its process) | same `cwd` AND same running program (the basenames of the job's tops' argv[0]; a kitty with no shell is told from a shell running that program) or both at a prompt; any other terminal is NOT reused |
| a window with a `folder` (VS Code) | same class, same `folder` |
| selfRestore (rule or app) | same class; exact title first, then by order |
| other | same class; where the preset or the desktop has several windows of the class, the same title too |
A reused window joins the restore's matched set (`plan["reuse"]`, `Restore.reused`/`addr`): `_prepare` first releases it (a locked
group is unlocked and the window leaves it with `hl.dsp.window.move({ out_of_group = true, window })`; a pin is undone with
`window.pin({ action = "unset" })`; a fullscreen with `window.fullscreen({ action = "unset", mode = "maximized"|"fullscreen" })` --
`unset` WITHOUT the mode does nothing, measured), then stages it on its target's `special:lsr-*` workspace, fixes its float,
rebuilds the groups in tab order with the tab on show and the lock, and it appears in the SAME single reveal chunk as the started
windows (which sets pin and fullscreen from the saved state). In a preset load the "already open" skip by class and title is off:
the match decided what stands for what.

**Terminals the preset starts**: `classify(..., claude=<presets.claude>)` and the session counted clean: the run list decides run or
type, except that with `"fresh"` (the default) a Claude job the list accepts (`claude`, `--resume <id>`, `-r`, `--continue`) is the bare
`claude` (`plan.build(..., claude="fresh")`; classify table flag `fresh`). A restore passes session.jsonc's `claude` (`"resume"`; `"type"`
types the conversation's command: flag `typed`). Facts are stored, today's rules judge.

**Close** (`restore.close_windows`): ONE Lua chunk of `pcall(function() hl.dispatch(hl.dsp.window.close({ window =
"address:0x.." })) end)` per window (`Hypr.run_lua`), then a wait of up to `closeTimeoutMs` (`config/session.jsonc`, default 8000) for
each to leave `j/clients`; a window still open (an unsaved-changes dialog) is left and listed in `kept`, and a short settle follows
before anything starts. Launches and moves start only after the close step.

**State.** A preset load does NOT mark the login candidate answered. It sets `current.restoring = {preset: <slug>, since, done}`
(no `snapshot`): the watcher pauses its pictures while `done` is null and clears it 60 s after. `begin` reads a `restoring` with
`preset` as no restoring at all: a crash during a load is an ordinary crash, decided from the rolling picture, and a preset is never
looked up in `snapshots/`.

Checks: `python3 tools/dev/session_cases.py` (groups `preset`, `reuse`, `begin`; ARMs rotatepresets, noreuse, closeadd, resumeclaude,
presetcrash), `MODE=preset tools/dev/session_env_probe.sh` (ARMs nomovereuse, closesall; a stub window that refuses to close proves
`kept`).
