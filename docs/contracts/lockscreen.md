# Lockscreen — round 1 contract (frozen before the streams start)

(The plans, stage-0 facts and round notes this contract names beside it are no longer in `docs/`: they are in git history,
`git log --all -- 'docs/agent_added_files_and_folders/lockscreen_progress/'`.)
(The gates, probes and fixtures this contract names without a directory went with the cleanup: tag `pre-cleanup` has them. What a change is proved with now is in `tools/dev/`, [tools.md](../tools.md).)

Plan: `~/.claude/plans/your-job-is-to-indexed-map.md`. Brief:
`docs/lockscreen.md`. Stage 0 facts: `lock_stage0.sh` (read its
header — every design choice below that looks odd is one of those facts).

Changing anything in this file after the streams start is the orchestrator's
job. A stream that needs a change asks; it never edits another stream's
files.

## 0. The one safety rule for everyone

**The lock is never started outside `tools/dev/lock_env.sh`.** On the real desktop
it locks the user's session, and a lock that dies there leaves them on
Hyprland's lockdead screen with a TTY as the only way out. So:

- the entry `lock/shell.qml` refuses to lock unless `LARES_LOCK_SUPERVISED=1`
  (the supervisor sets it);
- the supervisor `tools/lockscreen/lares-lock` refuses to run unless
  `LOCK_ENV_DIR` is set (the test env) or `LARES_LOCK_REAL=1` (only the deploy
  config ever sets that);
- `tools/dev/smoke.sh` refuses any file that mentions `WlSessionLock` or imports
  `lockscreen/lock` unless it runs offscreen or inside the env;
- mockups (`test_lockscreen.qml`, `test_lockveil*.qml`) never instantiate
  `WlSessionLock`.

Never `pkill`/`pgrep -x quickshell`. Kill only pids you started, or
`tools/dev/lock_env.sh down`. A `pgrep -f` pattern matches your own shell's
command line.

## 1. Layout

```
lock/shell.qml                 the lock's entry: qs -p ~/.config/quickshell/lock/shell.qml
lock/modules -> ../modules     symlink: imports ("../" outside a quickshell root does not resolve)
lock/themes  -> ../themes      symlink: Theme reads Quickshell.shellDir + "/themes"
                               (its own root: two quickshells under one root that has a
                                .qmlls.ini re-link it against each other at ~1.4 cores each)
modules/lockscreen/
  LockProtocol.js              shared: socket path, message builders, parser      [orchestrator]
  LockState.qml                shared: the state both processes bind to           [orchestrator]
  lock/                        lock process only                                  [stream A]
  popup/                       the drop-in popup content                          [stream B]
  LockOwner.qml                shell side: socket server, opens the popup         [stream B]
  veil/LockVeil.qml            veil host: registry + THE clock                    [orchestrator]
  veil/VeilStage.qml           mockup stage for veils                             [orchestrator]
  veil/Veil<Name>.qml          one per proposal                                   [streams C1-C3]
  shaders/veil_<name>*.frag    per proposal                                       [streams C1-C3]
tools/lockscreen/lares-lock       supervisor                                         [stream A]
tools/lockscreen/hyprlock.conf pinned fallback hyprlock                           [stream A]
lockscreen.example.jsonc        config schema (section 5)                          [orchestrator]
locale.example.jsonc            time/date formats                                  [stream B]
```

## 2. LockState (`modules/lockscreen/LockState.qml`)

A plain `QtObject`. The lock process owns the only writable one; the shell
mirrors it from the socket (`LockProtocol.applyState`). Every field is a
FACT, never a colour or a string meant for display.

| field | type | meaning |
|---|---|---|
| `phase` | string | `"locking"` (lock requested, choreography running) · `"locked"` · `"unlocking"` (auth succeeded, retract running) |
| `boot` | bool | started by `--locked-cmd`: nothing behind the lock, veil opaque |
| `lockedAt` | double | ms since epoch when the lock was confirmed (`secure`) |
| `dots` | int | characters in the password buffer, 0..512 |
| `caps` | bool | caps lock on |
| `auth` | string | `"idle"` · `"checking"` (answer sent, PAM working, incl. pam_unix's ~2 s failure delay) · `"failed"` (last attempt wrong; until the next key) · `"ok"` |
| `failCount` | int | wrong passwords during this lock |
| `authMessage` | string | the password stack's last PAM message (raw) |
| `face` | string | `"absent"` (no face auth here) · `"idle"` (available, not scanning) · `"scanning"` · `"ok"` · `"failed"` (timeout / no match) · `"dark"` (image too dark) · `"busy"` (camera held by an aborted scan's compare.py; re-arm waits) · `"unavailable"` (AUTHINFO_UNAVAIL: lid closed, no device) · `"misconfigured"` (e.g. howdy `workaround = input`; `off` and `native` are accepted) |
| `faceMessage` | string | the face stack's last PAM message (raw) |
| `faceReason` | string | round 5: why the face is in its state, a fact the popup words: `""` `nomatch` `dark` `camera` `lid` `nomodel` `error` `stall` `timeout` `input` `workaround` `device` `config` `pam` (enum-checked on the wire) |
| `awake` | bool | input within `idleSeconds`; false = everything eases to still |

## 3. Protocol (`modules/lockscreen/LockProtocol.js`)

Unix socket, one JSON object per line. **Server: the shell** (`LockOwner`, a
`SocketServer` that is always listening). **Client: the lock** (`ShellLink`,
retries every 250 ms). Path: `LockProtocol.socketPath(runtimeDir, waylandDisplay)`
= `<XDG_RUNTIME_DIR>/lares-lock/<basename of WAYLAND_DISPLAY>.sock`
(both processes share both variables; the key keeps test envs apart).

lock → shell

| message | when |
|---|---|
| `{"t":"hello","v":1}` | on connect |
| `{"t":"state","s":{…every LockState field…}}` | on connect and after every change (coalesced to one per event-loop turn) |
| `{"t":"bye"}` | after the release, before quitting |

shell → lock

| message | meaning |
|---|---|
| `{"t":"hello","v":1}` | on connect |
| `{"t":"shown","screens":["LOCK-1",…]}` | the popup is visible on these screens: the lock hides its fallback card there |
| `{"t":"hints","screen":"LOCK-1","rects":[[x,y,w,h],…],"bar":[x,y,w,h]\|null,"popup":[x,y,w,h]\|null}` | screen-local logical rects of the bars + popup: rebuilt out of S0 before it is blurred. `bar` / `popup` (2026-10-23) NAME the bar the popup hangs from and the popup (null: none); a sender that names neither (the fakes) leaves the lock to its old guess by shape, which islands defeat (an island is no full-edge strip, and a retracting popup grows smaller than one) |
| `{"t":"targets","screen":"LOCK-1","field":[x,y,w,h]}` | round 2: where the password field is (screen-local logical px). Key pulses start there (round 3: the face rect and the click on the glyph are gone) |
| `{"t":"retracted"}` | the unlock retract finished: the lock may release now |

Rules: unknown `t`, a wrong `v`, malformed JSON, or a line over 64 KiB is
ignored (and counted, for probes). **Nothing a shell sends can unlock or
delay the unlock beyond 600 ms.** `retracted` before `phase == "unlocking"`
is ignored.

## 4. LockPopup (`modules/lockscreen/popup/LockPopup.qml`) — stream B

Drop-in content (thePopup, and the lock's fallback card). Sized by
`implicitWidth`/`implicitHeight` only.

```
property QtObject lockState: null   // LockState (null -> a quiet idle look)
property var battery: null          // BatteryData or null -> cell hidden
property var weather: null          // WeatherService or null -> cell hidden
property var updates: null          // AvailableUpdatesService or null -> cell hidden
property var mpd: null              // MpdService or null -> no vinyl
property var wikiService: null      // -> WikiCompactCard { service }
property var locale: null           // LocaleConfig or null -> 24 h defaults
property string greetingName: ""
property bool fallback: false       // hosted by the lock itself: no services, no exec, nothing clickable
property bool active: true          // false = at rest: nothing ticks
property real renderScale: 1
property string fontFamily: "Audiowide"
```

It never starts a `Process`, never opens a URL, never reads a singleton
service; everything comes in through these properties. Keyboard-only: the
popup has no pointer input at all (the shell's layers are not interactive).

## 5. Config (`lockscreen.example.jsonc` → the user's `lockscreen.json`)

Read by path (`Quickshell.shellDir + "/../lockscreen.json"`, falling back to
the example). Plain JSON.

```json
{
  "veil": "random",
  "veils": ["relief", "gooey", "dimples", "paper", "louvres", "keycaps", "dials"],
  "idleSeconds": 30,
  "fps": 60,
  "batteryFpsRatio": 0.5,
  "blurInMs": 250,
  "veilRiseMs": 1200,
  "unlockHoldMs": 600,
  "unlockMs": 400,
  "face": "auto",
  "faceRearmCooldownMs": 5000,
  "fallbackDelayMs": 2000,
  "bootFallbackDelayMs": 30000,
  "handoverGraceMs": 3000,
  "greetingName": "",
  "obscure": [
    { "class": "^(signal|Slack|discord)$" },
    { "title": "(?i)bank" }
  ]
}
```

`face`: `auto` | `on` | `off`; env `LARES_LOCK_FACE=0|1` wins. `veil`: a name, or
`random` = one of `veils` per lock, never the same twice in a row (round 2).

## 6. Supervisor (`tools/lockscreen/lares-lock`) — stream A

```
lares-lock [--boot]
```
- one lock at a time: `flock` on `$XDG_RUNTIME_DIR/lares-lock.lock`; a second
  call while a lock runs exits 0. Until `lares cleanup-old-name` a lock of the OLD name is a lock too: `lares-lock-session` and `lares-lock`
  refuse to start beside a held `$XDG_RUNTIME_DIR/qs-lock.lock`, and `lares-lock-held` reads both files (a file named either way is asked as the pair);
- refuses unless `LOCK_ENV_DIR` or `LARES_LOCK_REAL=1` (section 0);
- reads the user's `decoration:blur:xray` first, passes it as
  `LARES_LOCK_ORIG_BLUR_XRAY`, and on EVERY exit restores
  `session_lock_xray=false`, `session_lock_blur=true`, `blur.xray=<orig>`;
- runs `quickshell -p <root>/lock/shell.qml` with `LARES_LOCK_SUPERVISED=1`,
  `QS_DISABLE_CRASH_HANDLER=1`, `ulimit -c 0`, `LARES_LOCK_BOOT=1` for `--boot`;
- the lock prints on stdout, one line each: `LARESLOCK secure` (lock confirmed),
  `LARESLOCK unlocked` (AuthController succeeded AND the release was sent);
- watchdog: no `LARESLOCK secure` within 5 s → SIGKILL;
- an exit NOT preceded by `LARESLOCK unlocked` (any signal, `qs kill`,
  `Qt.quit()`, exit 0 included) → restore xray off at once, relaunch once;
  a second one → `/usr/bin/hyprlock --grace 0 -c tools/lockscreen/hyprlock.conf`
  (auth module `lares-lock`; with only the old name's PAM file in `/etc/pam.d` -- `LARES_LOCK_PAM_DIR` for a test -- it is handed a copy of the
  pinned file in `$XDG_RUNTIME_DIR` whose module is `qs-lock`: a service that is not installed denies everything, and the last resort must
  open); test mode replaces hyprlock with a stub;
- hyproled `suspend`/`resume` around the whole lock, skipped under
  `LOCK_ENV_DIR`.

## 7. LockVeil (`modules/lockscreen/veil/LockVeil.qml`) — orchestrator

The host owns THE clock; a proposal is a pure function of what the host
hands it, so a resting host renders nothing.

Host → proposal (the proposal is loaded with `host` as an initial property
and reads everything from it):

| host property | meaning |
|---|---|
| `time` | veil seconds; advances only while running |
| `speed` | 0..1, the eased motion rate (1 awake; eases to 0 over `restEaseMs` after `awake` goes false; back to 1 over `wakeEaseMs`) |
| `presence` | 0..1, how much of the veil is shown (the lock's choreography raises it over `veilRiseMs`, from the moment S0 is on screen) |
| `opaque` | boot: nothing behind; draw a full ground |
| `still` | the held desktop frame as a texture provider `Item`, or `null` |
| `renderScale` | device px per item px |
| `pulses` | array of `{kind, x, y, t}` (`t` in veil seconds), newest last, at most 32 (round 2: 16 cut ripples off); a proposal draws what it can afford and FADES the oldest out, never drops it mid-flight: `"key"`, `"fail"`, `"ok"`, `"wake"` |
| `popupRect`, `barRect` | where the shell's popup and its bar are (item px; empty = unknown) |
| `pointer` | `{x, y}` in item px or `null` |
| `dark` | the theme is dark (read at creation and on `Theme.settled`, never bound live) |

A proposal file `Veil<Name>.qml` is an `Item` with `property Item host` and
nothing required; it fills its parent; it never runs its own Timer or
FrameAnimation (particles included: step them from `host.time`); it reads
colours from `Theme` (no literals), holds still while `Theme.crossfading`
(the host's clock does), and draws in whole device pixels. Registered names:
`relief`, `gooey`, `dimples`, `paper`, `louvres`, `keycaps`, `dials` (round 2: the user kept relief,
gooey, dimples and zen; frost and sky were removed. Round 3 removed zen, the user's call, and
`LockConfig` falls back to the default list, with one log line, for a config that still names it).

## 8. Ownership

| stream | owns (creates / edits) |
|---|---|
| orchestrator | `LockProtocol.js`, `LockState.qml`, `veil/LockVeil.qml`, `veil/VeilStage.qml`, `test_lockveil.qml`, `lockscreen.example.jsonc`, this file, CLAUDE.md, `tools/dev/smoke.sh`, `tools/dev/bake_shaders.sh`, `tools/dev/lock_env*`, `lock_stage0.sh`, fixtures under `fixtures/lockscreen/` |
| A — lock process | `lock/`, `modules/lockscreen/lock/`, `tools/lockscreen/`, `lock_{auth,session,link,idle}_probe.sh`, `lock_security_gate.sh`, `lockscreen_js_cases.js`, new probes `tools/dev/lock_env/probes/a_*.qml` |
| B — popup + shell | `modules/lockscreen/popup/`, `modules/lockscreen/LockOwner.qml`, `modules/common/locale/`, `locale.example.jsonc`, `test_lockscreen.qml`, `test_lock_shell.qml`, `test_power.qml` (the Lock item only), `lockscreen_render.sh`, probes `tools/dev/lock_env/probes/b_*.qml` |
| C1 | `VeilRelief.qml`, `VeilDimples.qml`, `shaders/veil_relief*`, `shaders/veil_dimples*`, `test_lockveil_relief.qml`, `test_lockveil_dimples.qml` |
| C2 | `VeilGooey.qml`, `VeilZen.qml`, their shaders, `test_lockveil_gooey.qml`, `test_lockveil_zen.qml` |
| C3 | `VeilFrost.qml`, `VeilSky.qml`, their shaders, `test_lockveil_frost.qml`, `test_lockveil_sky.qml` |

Nobody commits: the orchestrator commits each stream's files once verified.

## Round 2 additions (2026-10-01)

- Face policy: a DELIBERATE lock never scans at once (the user is sitting in
  front of it and it would unlock at once). The face scan starts: at boot
  (`LARES_LOCK_BOOT=1`), on resume from sleep, on the first input after the lock
  has rested (awake false -> true), and on an explicit retry (Enter on an empty
  field). Round 3: the first character typed into an EMPTY field starts a scan
  too (whenever the face is idle / failed / dark / busy; through the cooldown),
  and Ctrl+Backspace clears the buffer like Ctrl+U.
- DesktopLayer exposes `readonly property bool veilRise`: true the moment S0 is on
  screen and the blur-in begins (round 4: the veil starts with it). LockSurface
  starts the rise on it.
- The supervisor reads the lock's log through a held fd (a moved log made it
  relaunch a lock that had unlocked).
- The supervisor marks its relaunch with `LARES_LOCK_RELAUNCH=1` beside
  `LARES_LOCK_BOOT=1`: a relaunch is a boot for the VEIL (lockdead behind it,
  nothing to capture) but a deliberate lock for the FACE (the user may be in
  front of it).
- THE CHOREOGRAPHY (round 4, the user's call: the veil right away). The burst,
  the slow-motion replay and the live compositor desktop are gone. At the lock:
  S0 (the sharp desktop, captured with the surface clear) is shown opaque, and
  two presented frames later xray goes OFF for the rest of the lock (the
  compositor's own blur is never used), `veilRise` turns true and the blur-in
  (`blurInMs` 250, kawase + grain, sharp -> blurred) starts: ~0.25 s after the
  lock request. `veilRiseMs` (1200) is the veil's rise over it.
- THE UNLOCK HOLD (round 4). On PAM success the veil gets its `ok`; the popup
  retracts; everything else holds for `unlockHoldMs` (600) with the veil at full
  presence; xray comes on 150 ms before the end of the hold (beneath the opaque
  lock); then the lock surface fades over `unlockMs` (400) to the live sharp
  desktop, the veil still animating; then the release. The fail-safe cap is
  `unlockHoldMs + unlockMs + 400`: whatever stalls, the session is released by
  then. Before the veil is up there is no hold.

## Post-deploy round 2 additions (2026-11-07): the boot

- THE SPAN. Hyprland 0.57 (`Renderer.cpp`, `SessionLockManager.cpp`) draws a locked session's WORKSPACE, with no black
  primer, from a locker's request until its surface has drawn on every output (`shallConsiderLockMissing()` is false for
  `lockdead_screen_delay` after the request, `clientLocked()` false until `locked`); before the request (--locked-cmd) and
  after `locked` it draws no workspace. A lock surface's first commit must carry a buffer (the configure is sent at
  `get_lock_surface`), so the span is at least the client's first frame, and a busy compositor (a real boot) draws frames in it.
- THE COVER (`modules/lockscreen/lock/BootCover.qml`, `LockRoot`): a `boot` lock (boot, relaunch, rekey) maps an opaque black
  `PanelWindow` (Overlay, namespace `lares-lock-cover`, no input, no keyboard) on every screen and asks for the session once every
  cover is MAPPED (`ready`): Hyprland applies a dmabuf commit only once its GPU fence is readable (`LOCK_REASON_FENCE`) while it
  acts on a lock request at once, so after its first frame the cover polls `hyprctl -j layers` (which lists a layer only once
  it is mapped) every 8 ms; 500 ms at most (`LARESLOCK fact cover: up (its frame N ms, mapped M ms ...)` | `NOT up ...`). The cover
  goes at `secure`.
  The supervisor sets `lares_lock_cover` `no_anim = true` before a BOOT=1 launch and `false` on the way out.
- THE BARE FIRST FRAME (`LockSurface`): every surface builds its desktop layer and veil after the lock's phase leaves
  `locking` (400 ms failsafe), a boot one too: its first frame is the surface's black and nothing else, so `secure` comes one
  frame after the request. A boot surface's rise (`_rises`) starts when its veil Loader is Ready (or failed), never before.
- THE FLOOR AT ONCE: with `opaque` a veil's ground is whole from the first frame it draws; an entrance only forms detail on
  it. Paper: `_bedFront` 1e6; gooey: no pour (`opaqueMode`); dials: `groundCov` 1.
- THE SHELL'S SILHOUETTE: a veil reads `popupRect` / `barRect` as the only truth -- empty means no shell, never a guessed
  stone or bar to draw (paper: the entrance's front then leaves the bar's foot, or the top centre; no shadow; dials: the rings centre on the bar's
  foot, or the top centre, round a hub of hubMargin alone). Paper's shadow of
  the shell comes in on one clock as the shell arrives (`_attach`, OutCubic over `attachSeconds` 0.6 veil s; a shell there in
  the veil's first 0.3 s was there from the start) and goes with it at once; its radii never exceed the box. Dials eases to a new place (`_arr`: centre, hub, entrance start; OutCubic
  over `arriveSeconds` 1.2 veil s) when what it centres on changes, and gives a ring a new tick count only under a re-cut front
  (`_cut` / the `recut` uniform: it leaves the hub once the hub has held still 0.25 veil s, at `recutSpeed` 1400 px/s at 1620
  high, the ring's engraving gone where its count changes).
- PROOF: `tools/dev/lock_boot_film.sh` (the `floor` scenario per veil, a busy compositor, THE COVER'S ORDER read from
  Hyprland's log -- the cover mapped before the session locked -- and the lock's -- the cover gone after `secure` --,
  `SLOWFENCE=`, the ARMs in its header), `tools/dev/lock_env/probes/paper_shell_probe.sh`,
  `tools/dev/lock_env/probes/dials_shell_probe.sh`. The lock logs
  `LARESLOCK fact cover: up (its frame N ms, mapped M ms ...)` and `LARESLOCK fact cover: gone`.
