# Contract: bridge (the phone / device bridge)

The fixed names between `tools/bridge/lares-bridge` (the tool), `modules/bridge/data/BridgeService.qml` (the service),
`modules/bridge/BridgePopup.qml` (the popup) and `modules/bridge/body/PhoneStage.qml` (the phone). User page:
`docs/bridge.md`. The brief is `feedback/phone.md`; the decisions are in section 8.

## 1. Who does what

- **The tool** (Python + Gio, no shell needed) owns every fact and every verdict: which devices exist, how each is linked,
  what each action can do right now and why not (`can`), how a transport is resolved, every argv. It is the only writer of
  its state file. A second implementation of one of its rules in QML is not allowed.
- **The service** (QML, ONE per shell) only says when (`watch` while it runs, a one-shot per action), keeps the model the
  popup reads, and talks to the user (toasts). `live` defaults to FALSE; not live, it starts nothing and reads scenario
  lines through the same parser.
- **The popup** shows facts and asks the service. It decides nothing about availability: a tile is enabled by `can.<x>.ok`
  and says `can.<x>.why` / `.hint` when it is not (or, enabled, why its last try failed). No failure takes a control away.
- **The phone stage** draws the body, places the two faces, owns the flip and the body's hit zones. It knows nothing of
  KDE Connect or adb.

## 2. Files

```
tools/bridge/lares-bridge            the CLI (watch, the one-shots, _run)
tools/bridge/bridgelib/*.py          resolve, merge, argv, caps (pure); kdc, adbsock, usb, mounts, jobs, state, doctor (I/O)
tools/bridge/make_decor.py           the body's textures: what lies under the back glass and the frame's walls, drawn from
                                     BodyGeometry.js SKINS (dev-time generator; the PNGs in modules/bridge/assets/ are committed)
config/bridge.jsonc                  the user's (ConfigFile rule); .examples/bridge.jsonc holds every key at its default
$XDG_STATE_HOME/lares/bridge/        0700; files 0600
    state.json                       { links: {<kdc id>: <adb serial>}, prefs: {<key>: {...}}, lastSeen: {<key>: s}, current,
                                       facts: {<key>: {...}} }      (never an address)
$XDG_RUNTIME_DIR/lares/bridge/       0700; this boot only
    jobs/<id>.json                   one record per job (section 5); ids are m-<n> (mirror), f-<n> (a mount: "files"), s-<n> (send)
    adb-started                      present while the adb server running is one the tool started
    tries.json                       the last failed try per device and action: the one-shots write it, the watcher shows it as
                                     `can.<action>.why` until that device's links change (a one-shot asked for by name tries anyway)
    mine.json                        the mount points the tool mounted (only those are ever cleaned by itself)
$XDG_CACHE_HOME/lares/bridge/        0700; what happened, read after a test on the real phone (holds serials and addresses:
                                     never copied into the repo)
    trace.jsonl                      one line per event: `watch` (each printed line), `call` (a one-shot, its answer, ms), `exec`
                                     (a command run: argv, status, the tail of its output), `ident`, `adopt`; at 2 MB it moves
                                     to trace.1.jsonl
    jobs/<stamp>-<id>.log            a job's whole output, `$ <argv>` first and `[exit N]` last; the last 30 are kept
```
Test overrides (environment): `LARES_BRIDGE_CONFIG` (a config file), `LARES_BRIDGE_STATE`, `LARES_BRIDGE_RUNTIME`,
`LARES_BRIDGE_CACHE` (dirs; with `LARES_BRIDGE_STATE` set the cache defaults to `<state>-cache`, never the user's),
`LARES_BRIDGE_SYS` (a fake `/sys` root for USB), `LARES_BRIDGE_MOUNTINFO` (a file in mountinfo's format), `LARES_BRIDGE_ENOTCONN`
(mount points that read as stale: a real stale FUSE mount cannot be made in a test), the session bus through
`DBUS_SESSION_BUS_ADDRESS`, the adb server through `ANDROID_ADB_SERVER_PORT`, programs through `PATH` (`adb`, `scrcpy`,
`aft-mtp-mount`, `sshfs`, `fusermount3`, `systemd-run`, `systemctl`, `kitty`). The tool creates nothing before it has recognised
its command, and never D-Bus-activates KDE Connect (calls only while the name has an owner).

## 3. The `watch` line

`lares-bridge watch` prints ONE JSON object per line: one at start, one per change (coalesced over 50 ms; while a job
with figures runs, at most one per 500 ms). `serial` starts at 1 and rises by one per line; a line is printed only when the
picture really changed. The first line waits (1.5 s at most) for KDE Connect's first read and adb's first answer. A fault prints
`{"v":1,"error":"..."}` and the process exits non-zero (the service's SupervisedStream restarts it). A device KDE Connect sees
but has not paired is in `pairing` only (in `devices` too once it is also known over adb or USB).

```
{ "v": 1, "serial": 42,
  "env": { "kdeconnect": "running" | "down" | "missing",          // the daemon on the bus | not on the bus | not installed
           "adbServer": "up" | "down",
           "have": { "adb": true, "scrcpy": "5.0.1", "aft": true, "sshfs": false, "fusermount": true } },   // "" = absent
  "current": "<device key>" | "",
  "devices": [ <device> ... ],          // paired first, then by lastSeen, newest first; an unpaired reachable one is in `pairing`
  "pairing": [ { "key", "name", "type", "byPeer": bool, "verificationKey" } ... ],   // reachable, not paired
  "jobs": [ <job> ... ],                // live ones and ended ones not yet acknowledged
  "wifiPair": null | { "key", "name", "state": "waiting" | "paired" | "failed" | "expired", "reason", "png" } }
                                        // a Wireless debugging pairing (`wifipair`): its QR code is `png`; gone after 10 min
```

`<device>`:
```
{ "key": "kdc:<id>" | "adb:<serial>",   // kdc when KDE Connect knows it, else the adb serial
  "name": "REDMAGIC 10 Pro", "type": "phone" | "tablet" | "tv",   // KDE Connect's desktops and laptops are left out
                                         // name: KDE Connect's, else the phone's own (asked over the cable), else the USB
                                         // product string, else adb's model, else the serial
  "skin": "redmagic-10s-pro-moonlight" | "generic",                // config devices[<name|key>].skin, else by name table, else generic
  "present": bool,                       // reachable over KDE Connect, or on the cable, or an adb transport up
  "link": "none" | "wifi" | "usb" | "both",
  "lastSeen": 1794912345,
  "kdc": null | { "id", "paired": bool, "pairState": 0..3, "reachable": bool, "links": ["LAN"], "addresses": ["192.168.0.240"],
                  "plugins": ["battery", ...], "verificationKey": "305BAF9E", "pairRequested": bool, "pairRequestedByPeer": bool },
  "battery": null | { "charge": 81, "charging": false },
  "cell": null | { "strength": 0..4, "type": "LTE" },
  "usb": null | { "serial", "vendor", "product", "adbIface": bool, "mtpIface": bool },
  "adb": null | { "serial", "transport": "usb" | "tcp", "state": "device" | "unauthorized" | "offline", "address": "" | "ip:port" },
  "pin": "none" | "set" | "failed",     // an unlock PIN is kept in the login keyring for this phone / the last unlock with it failed
                                         // (kept in the tool's state file by `pin` / `unlock`, never read from the keyring per line; never the PIN)
  "prefs": { "keepWireless": true, "mode": "mirror", "screenOff": false, "record": false, "wifiDebug": false, "castAudio": false },
                                         // keepWireless ON by default (arms at every plug-in); wifiDebug: paired for Wireless
                                         // debugging (set by the pairing); castAudio: the cast plays the phone's sound
  "mounts": { "usb":  { "point": "/mnt/android", "state": "unmounted" | "mounting" | "mounted" | "stale", "mine": bool, "open": <point> },
              "wifi": { "point": "/run/user/1000/<id>", "state": ..., "mine": bool, "open": "<point>/storage/emulated/0" } },
                                         // open: what Open opens and the row shows (Wi-Fi: the phone's storage, getDirectories)
  "facts": null | { "model", "android", "storageTotal", "storageFree", "batteryHealth", "batteryTempC", "at": <s> },   // after `facts`
  "can": { "<action>": { "ok": bool, "why": "", "hint": "", "via": "" } ... } }
```
`can` has exactly these actions: `mirror` (via `usb` | `tcp`), `mountUsb`, `mountWifi`, `send` (via `adb` | `kdeconnect`),
`shot`, `ring`, `clip`, `key`, `pair`, `unpair`, `arm`, `facts`, `unlock` (an adb path like `key`, and `pin` "set": otherwise "No PIN kept" /
"Set it on the Details page", or "The PIN failed last time" / "Set it again on the Details page"; `via` is the adb path). `why` is one short sentence in the user's words ("adb is
not connected"); `hint` is what to do. With `ok` false they say why it cannot; with `ok` TRUE and `why` set they say why the last
try failed: a failure is told, never a lock -- the control stays pressable and a press tries again.

`<job>`:
```
{ "id": "m-18", "kind": "mirror" | "mount" | "send", "device": "<key>", "mode": "mirror" | "desktop" | "camera" | "audio" | "",
  "via": "usb" | "tcp" | "adb" | "kdeconnect" | "mtp", "phase": "starting" | "running" | "done" | "failed",
  "started": <s>, "ended": null | <s>, "code": null | <int>, "reason": "",          // reason: the last stderr line that says why
  "files": 0, "file": 0, "name": "", "done": 0, "total": 0, "rate": 0 }              // send only; bytes; 0 total = unknown
```

## 4. The one-shots

Each prints exactly ONE JSON line on stdout — `{"ok": true, ...}` or `{"ok": false, "reason": "...", "hint": "..."}` —
and human text only on stderr. Exit status: 0 done, 1 failed, 2 usage, 3 not available (a program, the daemon or the
device is not there, or `can` says no: the answer then carries the table's reason and hint), 4 refused (already mirroring, a
job still running, a stale mount somebody else made). `<dev>` is a device key (`pair` / `accept` / `reject` also take a key
of `pairing`).

A `mirror` or a `mount usb` answers once its job has left `starting` (3-4 s at most): a scrcpy that stops at once is the
answer `{ok: false, reason, hint}` and leaves NO job; only a job that dies after it was accepted reads `failed` in `jobs` and
wants its `ack`. A `send` over KDE Connect is no job at all (`{ok: true, via: "kdeconnect", job: ""}`): the daemon takes the
files and reports nothing back. `doctor` exits 0 with `ok: false` when a row is missing; `doctor --plain` exits 1.

| Call | Does | Extra in the answer |
|---|---|---|
| `state` | the first `watch` line, then exit | (the line itself) |
| `mirror <dev> [--mode mirror\|desktop\|camera\|audio] [--screen-off] [--record]` | resolve the transport, connect, start a job | `job`, `via` |
| `stop <job id>` | end a job (TERM to its wrapper; the scope as the last resort) | |
| `mount <dev> usb\|wifi` | `aft-mtp-mount` as a job, or KDE Connect's sftp. By cable, a phone on adb whose `svc usb getFunctions` lacks `mtp` is asked `svc usb setFunctions mtp` first and given 4 s for its MTP interface (with File transfer no longer switched on at every unlock, `usbcalm`, the mount asks for it; `can.mountUsb` is ok with adb on the cable and no MTP yet) | `point`, `job` (usb) |
| `unmount <dev> usb\|wifi` | `fusermount3 -u`, or sftp unmount; cleans a stale endpoint of its own | |
| `send <dev> [--via adb\|kdeconnect] <path>...` | a job (`adb push` to `files.sendDir`), or a KDE Connect share | `job`, `via` |
| `shot <dev>` | `adb exec-out screencap -p` into `shots.dir` as `phone-<YYYYmmdd-HHMMSS>.png` | `path` |
| `ring <dev>` / `clip <dev>` | find my phone / send the clipboard (KDE Connect) | |
| `key <dev> power\|volup\|voldown` | `adb shell input keyevent` | |
| `pair` / `accept` / `reject` / `unpair <dev>` | KDE Connect pairing | |
| `refresh` | KDE Connect `forceOnNetworkChange` | |
| `arm <dev>` / `disarm <dev>` | `adb tcpip <port>` / `adb usb` | |
| `set <dev> <pref> <json value>` | writes `prefs` (keepWireless, mode, screenOff, record) | |
| `select <dev>` | writes `current` | |
| `facts <dev>` | reads model, Android version, storage, battery health / temperature and `usbUnlocked` over adb; stored for the watch line. `usbUnlocked`: "none" when `dumpsys usb` has no `screen_unlocked_functions=` line, else its value lower-cased ("mtp": the Developer option Default USB configuration is File transfer, which restarts adbd at every lock and unlock) | `facts` |
| `wifipair <dev> [cancel]` | a Wireless debugging pairing: writes the QR code (`WIFI:T:ADB;S:<name>;P:<pw>;;`, bridgelib/qr.py) and starts `_pairwait`, which finds the phone's `_adb-tls-pairing._tcp` service by the code's name and runs `adb pair`; progress in `wifiPair`; the password lives in the code and the waiter's environment only. `cancel` ends it | `name`, `png` |
| `castprep <dev> [--unlock] [--hold] [--record]` | before the popup's cast: walks the transport like a mirror (cable, TCP up, Wireless debugging by mDNS, the armed port), then reads the lock state (`asleep`: the screen was off BEFORE anything woke it). `--hold` (a Mirror): the phone's own `system screen_off_timeout` is recorded once per device in `<state>/hold.json` (a record already there is never overwritten: a reconnect cannot record the raised value) and raised to 30 min; without it a recorded hold is given back (a Desktop). `--unlock` with `pin` "set": the unlock (as `unlock --auto`, under its flock, waiting up to 5 s for a running one: never typed twice); it never fails castprep. `--record` (the Mirror page's Record): `record`, the file the cast records into -- `mirror.recordDir` (made here; a folder that cannot be made fails 1) / `phone-<YYYYmmdd-HHMMSS>.mp4`, the one naming rule of a mirror's `--record` too | `serial`, `via`, `maxSize`, `bitRate`, `maxFps`, `asleep`, `held`, `unlock: {ok, already, why}` (only with `--unlock` and a PIN kept), `record` (only with `--record`) |
| `castend <dev> [--sleep]` / `castend --all` | the cast ended: the recorded timeout goes back IF the phone still reads the value written (else the user changed it: left alone) and the record goes; `--sleep`: an awake phone gets KEYCODE_SLEEP, a dark one is left alone. `--all` (the shell's start): every record, sleeping nothing. An unreachable phone fails (1) and keeps its record | `released: [keys]`, `slept` |
| `usbcalm <dev> [off\|on]` | `svc usb setScreenUnlockedFunctions` with no function (off, the default) or `mtp` (on: the way back); stores the device's pref `usbUnlockMtp` (= on), reads `dumpsys usb` back. Gated by `can.key`; usage 2 | `usbUnlocked` |
| `lockstate <dev>` | one `adb shell` (dumpsys trust / window / power / deviceidle, grep'd on the phone): is the phone locked, is its lock screen in front. Needs `can.key` | `locked` (`deviceLocked=1`; else any of isKeyguardShowing / mDreamingLockscreen / mScreenLocked), `keyguard`, `awake` (mWakefulness=Awake), `focus` (`"keyguard"` when the focused window is NotificationShade / Keyguard / Bouncer, `"app"`, or `""`) |
| `pin <dev> set` | the PIN is read as ONE line on stdin (4 to 16 characters of `[0-9A-Za-z]`; anything else is a usage error and nothing is stored); stored in the login keyring through `secret-tool` (service=`lares-bridge`, device=<KDE Connect id, else the device key>, label "Lares bridge: unlock PIN for <name>"); `pin` becomes "set". A locked keyring is refused (3, "The keyring is locked"), never prompted | |
| `pin <dev> forget` | clears it from the keyring; `pin` becomes "none" | |
| `unlock <dev> [--auto]` | see below. `--auto` changes nothing but the trace | `unlocked: true`, `already: true` when it was not locked, `dismissed: true` when only a trusted lock screen was taken away |
| `ack <job id>` | forgets an ended job | |
| `doctor [--plain]` | `{ok, rows: [{id, ok, text, hint}]}`; `--plain` prints lines for `lares setup` | `rows` |

**`unlock`** (the PIN kept in the keyring, typed over adb): `can.unlock` gates it (3); one at a time through a non-blocking flock on
`<state>/unlock.lock` (4, "Already unlocking"); transport resolved; `lockstate`: not locked and no lock screen → `{ok, unlocked: true, already: true}`;
not locked but the lock screen shows (trust: Smart Lock keeps it unlocked, the swipe-only lock screen stays) → wake, `wm dismiss-keyguard`, re-read
up to 6 times → `{ok, unlocked: true, dismissed: true}` (no PIN, no keyring) or 1 "The lock screen did not go away"; the keyring
locked → 3 "The keyring is locked" / "It opens with your password at the lock screen" (no prompt is ever made); no PIN found → `pin` "none",
3 "No PIN kept". Then `input keyevent KEYCODE_WAKEUP`, `wm dismiss-keyguard`, 0.5 s, `lockstate` again: unlocked → done; the PIN is typed ONLY
when it is still locked, the phone is awake AND `focus` is `keyguard` (else 1 "The lock screen did not take the keys" / "The phone did not wake",
nothing typed, `pin` unchanged, the reason is told as `can.unlock.why`). The PIN goes in as `input text <PIN>` on the STDIN of `adb -s <serial> shell -T`
(never an argv; the output is not traced); after 0.6 s, still locked with the keyguard in front → `KEYCODE_ENTER` (a pad that auto-confirms needs none, and an
Enter after an unlock would land in an app); `lockstate` is polled for up to 2.5 s. Unlocked → `{ok, unlocked: true}`. Still locked → `pin` "failed" and
1 "The PIN did not unlock the phone" / "Set it again on the Details page": that PIN is NEVER typed again until `pin set` (Android throttles and escalates
wrong attempts). The PIN is in no argv, file, environment, trace line, answer or stderr; the trace (`kind: "unlock"`) keeps the steps (`start` with `auto`,
each `lockstate`, `typed`, `enter`, `unlocked` / `failed`).

**The cast's own stream** (`lares-cast`, stdout, one JSON event per line): `ready`, `size`, `client`, `ended`, `error` as before, and
`{"event":"flow","on":true|false}` -- video frames are arriving from the phone (the first one, or the first after a gap) / none for 1.5 s (scrcpy repeats the last frame
~10x/s on a live display, so silence means the phone gives no picture: asleep, off, locked dark). No event at the start until the first frame, or until 1.5 s of nothing
(then `on: false`). `--new-display WxH[/DPI]` shows a new virtual display instead of the main one: server parameters `new_display=WxH/dpi`, `vd_destroy_content=false`
(its apps move to the phone's screen when the cast ends), no `max_size`; without a DPI it is `round(density * W / screenWidth)` clamped to [120, 640] from the
phone's own `wm size` / `wm density` (overrides win). Every event is also written to the trace (`kind: "cast"`, the event's fields and the `serial`).
`{"event":"lock","keyguard":bool,"awake":bool}` (round 6): once after `ready` from one `adb shell` read of the phone's clock and its lock state
(`castlib/lock.py`; skipped, and read again every 4 s, while the phone does not answer), then at every CHANGE of the pair from a follower `adb logcat -b
events -v epoch -T '<the phone's MM-DD hh:mm:ss.000 of that read>' -s wm_set_keyguard_shown power_screen_state` (a `-T <count>` counts lines BEFORE the
tag filter and prints nothing): `wm_set_keyguard_shown: [display, shown, aod, goingAway, occluded, reason]` for display 0 only, keyguard = shown and not
goingAway (AOD counts as locked); `power_screen_state: [on, ...]`, awake = on. The follower is restarted after 1, 2, 4 s (an adbd restart ends it) with
a fresh read, and dies with the cast (pdeathsig). Args: `--new-display WxH[/DPI] [--flex]`: `--flex` adds `flex_display=true` (a virtual display the
client resizes, dpi unchanged). stdin, beside touch / scroll / key / text / screen / keyframe / quit: `{"wake":true}` (KEYCODE_WAKEUP 224 down and up),
`{"resize":{"w":W,"h":H}}` (RESIZE_DISPLAY: type 21, `>BHH`, scrcpy 5.0.1's `ControlMessageReader.parseResizeDisplay`; only with `--flex`, else
ignored). `--record PATH`: the stream is also written to a file, from the first key frame and with the phone's own times whatever the
player's (`LARES_CAST_TS` never applies to it), by a sink of its own fed by the same broadcast as a player (its queue is its own: a full one never
drops the player; it skips to the next key frame with room and counts what it skipped). It is streamable FLV in `PATH.part.flv` as it comes (one
write a tag: a SIGKILLed cast leaves a part any player opens); a sequence header the phone sends again (a desktop resized) is written again and
its SPS / PPS go in-band before the next key frame. A PATH already taken (or its part) becomes `<stem>-2.mp4`, `-3`, ... (a restarted session
never writes over the file before it). At the end -- quit, EOF, TERM, the phone gone -- after `ended` and once the phone is let go, the part is
remuxed (`ffmpeg -y -loglevel error -i PATH.part.flv -c copy -f mp4 PATH.tmp`, then renamed to PATH) and deleted, and one event says how it went:
`{"event":"record","path":PATH}` | `{"event":"record","error":why,"kept":PATH.part.flv}` (the remux failed: the part stays) |
`{"event":"record","error":why}` (the file could not be opened at the start: the cast went on without it) | `{"event":"record","empty":true}`
(no picture came: nothing is kept); `"dropped": n` beside it when frames were skipped. CastSession reads `record` even after its quit and gives
a recording tool `recordKillAfterMs` (60 s) before it kills it. Exit: after cleanup stdout is flushed under its lock (2 s at most) and the process leaves with `os._exit` (a daemon thread mid-write at the
interpreter's shutdown aborted it with exit -6 on the real phone).

**The transport ladder** (`resolve`): the device's USB serial with adb in state `device` → an adb TCP transport of that
device already up → `adb mdns services` naming it → KDE Connect's `addresses` with the armed port (`adb.port`), tried
with `adb connect`. No address is ever written to a file. scrcpy is always started with `-s <serial>`.

**adb server**: the tool starts one only for a need (an action, `facts`, Keep wireless ready at a plug-in) and stops it
`adb.idleKillS` after the last need only if `adb-started` says it started it.

## 5. Jobs

A job is started as `systemd-run --user --scope --collect --quiet --expand-environment=no --unit=lares-bridge-<kind>-<id>
-- setsid -f <tool> _run <id> -- <argv...>`. The wrapper (`_run`) stays the child's parent, writes `jobs/<id>.json`
atomically (the `<job>` fields plus `pid`, `pidStart`) at every phase change and at most every 500 ms for figures, and
forwards TERM. `watch` reads the records and holds a pidfd on each live wrapper: a wrapper that died without writing
`done` / `failed` reads `failed` ("ended without a word"). A job outlives the popup, the service and the shell.

## 6. The service (`BridgeService`)

```
property bool live: false                 // false: starts nothing; `scenario` feeds lines
property string scenario: ""              // not live: a key of BridgeScenarios.js ("none", "pairing", "asleep", "wifi", "wired",
                                          //   "mirroring", "mounted", "transfer", "error")
property bool popupOpen: false            // written by the host (ONE writer, the OR over the screens)
property string configPath / toolPath / python / var launcher     // injectable, as SessionService's
readonly property bool ready              // a line has arrived
readonly property int serial              // bumps once per accepted line, AFTER everything below is written
readonly property var env                 // the line's env
readonly property ListModel devices       // roles: key (string), rec (QtObject { property var d }) -- re-assigned d, never rebuilt
readonly property int count
readonly property string currentKey
readonly property var current             // the current device's d, or null
readonly property var pairing             // array
readonly property var jobs                // array
readonly property var wifiPair            // the line's `wifiPair`
readonly property var castSession         // the ONE cast (modules/bridge/cast/CastSession: tools/bridge/lares-cast)
readonly property string castKey          // the device it casts ("" none)
readonly property string castMode         // "mirror" (the phone's own screen) | "desktop" (a new virtual screen, lares-cast --new-display)
readonly property bool castHolding        // the cast page holds its last frame, blurred, under a title box (castHoldWhy)
readonly property string castHoldWhy      // "Resizing" (a mirror's restart at a new bucket) | "Reconnecting" | "Unlocking" | "" (none)
readonly property bool castUnlocking      // an unlock asked from the cast page runs: the page sends the phone nothing meanwhile
readonly property string castPhase        // idle | connecting | starting | live | reconnecting | failed. A session that ENDS without being
                                          //   asked (the phone closed the stream: an adbd restart, Wi-Fi) is brought back: "reconnecting",
                                          //   castprep again (NEVER --unlock: nobody asked, a phone locked meanwhile stays locked), a new
                                          //   session; tries after 0.5, 1, 2, 4 s, given back only by a session that stayed live 10 s
                                          //   (one that dies at once would reconnect for ever), spent -> "failed" (Try again). "ended" is NEVER "starting"
                                          //   (round 5 mapped it there: the page said "Starting" for ever after every lock or unlock)
readonly property bool casting            // connecting, starting, live or reconnecting
readonly property string castReason
property real castScale                   // the popup's size while the cast shows (session only)
property real castShift                   // and its place off the icon along the bar (both carried in and out with the page)
property bool castTurning                 // written by the cast page: the phone on show is turning; a new size (a mirror's restart, a
                                          //   desktop's resize) waits until it has landed
function castStart(key, mode, record) / castStop() / castDetach() / castSetAudio(on)
                                          // record (the Mirror page's Record): castprep --record names the file, lares-cast --record
                                          //   writes it, `castRecording` says so; the unlock and the hold are a cast's without it. Start
                                          //   with another Record over a running cast starts it again (the file is finished). Its end
                                          //   is one toast (BridgeModel.recordToast): "Recording saved" + the path, or "Could not save the
                                          //   recording" naming the part kept; `empty` says nothing. castDetach's window records too
readonly property bool castRecording      // the cast records
function castWantRoom(w, h, dpr)          // the cast page's room in device px and the window's real ratio: a mirror's stream bucket (a
                                          //   different bucket restarts it, `cast.reloadOnResize`, never while it records: a restart
                                          //   would cut the file in two); a desktop's screen
                                          //   (`BridgeModel.desktopScreen`, below) is made once and then RESIZED live (`--flex`), never
                                          //   restarted for a size (its apps would go)
function castHoldReady()                  // the cast page has taken its last frame: a Resizing restart goes ahead (else by itself after 250 ms)
function castUnlock(key)                  // the cast page's unlock: a first press or key on a dark or locked picture (below)
function usbCalm(key, on)                 // `usbcalm <key> off|on` (Details' row "File transfer at unlock")
function castWoke()                       // the cast page woke a dark phone (CastView `wakeAsked`): it is put back to sleep at the cast's end
function setPin(key, pin) / forgetPin(key)   // `pin set` with the PIN on the child's STDIN only (never argv, `calls` or an answer);
                                          //   refused before anything runs unless 4-16 digits or letters
function wifiPair(key) / wifiPairCancel()
readonly property bool busy               // a send job is running (the idle cause)
readonly property var settings            // BridgeConfig's parsed config (section 7)
property string page: ""                  // "" | "mirror" | "files": the page on show; lives here because a popup's content is per
                                          //   screen and destroyed on close
readonly property var acts                // { "<action>": { state: "idle" | "busy" | "done" | "failed", why: "", hint: "", at: <ms> } }
                                          //   for the current device: always every `can` key (13 with unlock) (a mount is `mountUsb` /
                                          //   `mountWifi`, a disarm is `arm`, the picker's send is `send`); a new object per change
readonly property int rowSerial           // bumps when the devices' order or membership changed
readonly property bool picking            // the file picker is open
readonly property string lastError        // the last line the parser refused, in words
signal acted(string key, string action, bool ok, string why)
function device(key): var                 // d or null
function job(key, kind): var              // the live job of that kind for that device, or null
function select(key)
function mirror(key, opts)  /  stopJob(id)                    // opts: { mode, screenOff, record }
function mount(key, which)  /  unmount(key, which)  /  openFiles(key, which)     // which: "usb" | "wifi"
function send(key, paths)   /  pickAndSend(key)               // pickAndSend: the portal picker (tools/notes/portal_pick.py)
function shot(key)  /  ring(key)  /  clip(key)  /  pressKey(key, name)           // name: "power" | "volup" | "voldown"
function pair(key)  /  accept(key)  /  reject(key)  /  unpair(key)  /  refresh()
function setPref(key, name, value)  /  loadFacts(key)  /  arm(key)  /  disarm(key)
function copyText(text)                   // onto the clipboard, through the injected clipboard service
readonly property var calls               // not live: every action asked, in order ({ action, key, args }); nothing runs
```
Toasts (through the injected `notifier`, a DesktopNotifier): a send is ONE `live` progress toast replaced in the same
turn by ONE closing toast; a mirror or a mount that failed is one toast with the tool's reason and hint; a shot goes to
the OSD's capture card; an unlock is one toast only when it is news ("The PIN did not unlock the phone", "The lock screen did not take
the keys"): a phone out of reach, a locked keyring or no PIN kept are what the Details page says. Nothing is posted for what KDE
Connect posts itself (pair requests, received files, pings).

**The cast page** (`screen/CastPage.qml` + `cast/CastView.qml`, round 6):
- *The turn.* The player follows `CastPage.shown` (its host's: ScreenFace `shown`, BridgePopup's own `visible`), never the page's
  `visible`: the stage hides the face turned away, so that went false whenever the phone's back was toward the viewer -- a free look
  past a quarter turn, the popup's opening turn -- and the player was let go and opened again on the way round: "Starting" until the
  phone's next key frame, and the encoder restarted by RESET_VIDEO, soft for a moment ("the stream is trying to adapt", the user,
  2026-11-22). `CastPage.turning` (ScreenFace `turning`, the stage's `flipping`) is written to the service's `castTurning`. A hold taken
  behind the turned phone (a reconnect) ends on the new stream's first frame though its own last frame was never taken (a face that
  is not drawn cannot be grabbed). Cast ARMs `turnstops`, `lookresize`, `hiddenhold`.
- *Input.* `CastPage.inputHeld` (its host's: ScreenFace `castInputHeld`, which BridgePopup binds to its free look) OR the service's
  `castUnlocking`: the view sends the phone NOTHING (no touch / move / up, no wheel, no key, no text); a finger already down gets its `up`
  where it was the moment the hold starts.
- *A Desktop never unlocks* (measured 2026-11-21): Android keeps scrcpy's new display usable, its launcher focused, while the phone is
  locked; the lock screen and the power state are display 0's (`wm_set_keyguard_shown` for display 0, global wakefulness "Awake" while the
  new display lives), and keys injected over adb go to the FOCUSED display (the Desktop's), so the tool's lock-screen check refuses to type.
  A Desktop's start passes no `--unlock`, its picture has no trigger (`CastView.lockTrigger` false) and never says "Screen off", and a
  popup opening asks no unlock at all (service ARMs `deskunlock`, `openunlock`; cast ARM `deskclick`).
- *The unlock trigger.* The first pointer press or key (a modifier alone is none: Alt is the free look's, cast ARM `altwakes`) over the picture of a phone that is dark (the tool's `lock` events say
  `awake: false`; without them, `flow` off) or shows its lock screen (`keyguard`) is swallowed, the screen is woken (`wake`), and when
  `can.unlock.ok` (a PIN kept, adb reaches the phone) `castUnlock` asks `unlock --auto` (hold "Unlocking" until its answer, then the next
  frame). A locked phone with no PIN to type gets its input as usual (typed by hand); a dark one that cannot be unlocked is only woken. A
  dark page says "Screen off". The unlock is also asked before every Mirror's START (`castprep --unlock` when `pin` is "set"); never by a
  reconnect, and never at a popup's open (the user, 2026-11-21: only a cast lights the phone; round 5 unlocked at every open).
- *Awake only while cast.* A Mirror's castprep passes `--hold` (a Desktop's does not, and gives a hold back); `castStop()` (Stop, another
  phone's cast, `cast.closeAfterS` behind a closed popup) runs `castend <key>`, with `--sleep` when the phone was dark at a castprep
  (`asleep`) or the page woke it (`castWoke`); `castDetach()` runs `castend` without `--sleep` (scrcpy's window still shows the phone); a
  mode switch on the same phone only halts (the next castprep takes the hold over, the owed sleep is kept). The live service's first line
  runs `castend --all` once. lares-cast never passes scrcpy's `stay_awake` (cast probe p7). Service ARMs `nohold`, `nosleep`; tool ARMs
  `rerecord`, `restoreany`. An unlock from the picture never takes over a hold already up
  (Resizing, Reconnecting): it only holds the input then.
- *The hold.* One freeze of the last frame, blurred, under the carved title box labelled `castHoldWhy`; kept through a restart's gap
  (`CastView.keepPicture`); Resizing / Reconnecting end on the new stream's first frame (`pictureShown`), Unlocking with the unlock's answer.
  A hold with no picture shows the phase's words instead.
- *A Desktop's screen* (`BridgeModel.desktopScreen(roomW, roomH, dpr, cast)`, device px and the window's real ratio): its short side is at
  least `cast.desktopMinPx` px and at least `cast.desktopMinDp` dp at `cast.desktopScale` laptop px per dp; whole multiples of 8, the long
  side at most 2400; dpi = 160 x short / dp, clamped 120 - 640 (the rest room 330 x 734 at 1.25 -> 640 x 1424 / 320). Measured on the
  user's phone (2026-11-21): its secondary launcher (ZTE's `SecondaryDisplayLauncher`, the teal button) IGNORES the display's density and
  lays out in pixels: under ~600 px of short side its app list overlaps ("the apps melt into each other"), at 656 px it is clean; density
  only sizes the apps. The phone's own launcher (Smart Launcher) cannot run there: a singleTask home started on another display takes
  the phone's ONE home task with it. The start's factor (screen px per room px) is kept: a settled room change (700 ms) sends `resize`.
- *USB.* At a popup open, once the facts say `usbUnlocked` is neither "" nor "none" and the device's `prefs.usbUnlockMtp` is not true, the
  service asks `usbcalm <key> off` once per open (a failure included). Details: "File transfer at unlock" Off / On, a QuietButton for
  `usbcalm on` (the way back, remembered) / `off`.

## 7. The config (`config/bridge.jsonc`)

```
{ "files":  { "usbMount": "/mnt/android",
              "open": ["kitty", "-o", "background_opacity=0.75", "--title", "yazi", "yazi", "{path}"],
              "sendDir": "/sdcard/Download" },
  "mirror": { "usb":  { "maxSize": 0, "bitRate": "", "maxFps": 0 },
              "wifi": { "maxSize": 1600, "bitRate": "6M", "maxFps": 60 },
              "recordDir": "~/Videos", "extraArgs": [] },
  "adb":    { "start": "onDemand", "idleKillS": 300, "port": 5555 },        // start: "onDemand" | "onPlug"
  "shots":  { "dir": "~/Pictures/Screenshots" },
  "flip":   { "onOpen": true },
  "cast": { "closeAfterS": 120,         // the cast outlives a closed popup this long
            "reloadOnResize": true,     // a resized mirror restarts its stream at the new size (sharper), the last frame held meanwhile
            "desktopScale": 1.0,        // laptop px per Android dp on a Desktop (0.5 - 3): 1 = text as big as the desktop's
            "desktopMinDp": 320,        // a Desktop's short side is never fewer dp (240 - 1200): apps lay out for at least a small phone
            "desktopMinPx": 640 },      // nor fewer pixels (320 - 2400): the phone's secondary launcher lays out in px, not dp
  "relight": true,
  "devices": { "<name or key>": { "skin": "redmagic-10s-pro-moonlight", "hidden": false } } }
```
The tool reads it through `tools/lib/jsonc.py`, the service through `BridgeConfig.qml` (ConfigFile). Both clamp a bad
value to the default and never fail on a missing key.

## 8. The phone stage (`modules/bridge/body/PhoneStage.qml`)

One fixed size (`implicitWidth` x `implicitHeight`: 320 x 664; the phone has equal room above and below, which a turn's
nearer, taller edge needs); the popup IS this size.

```
property string skin: "generic"
property alias front: <host>.data         // the screen's content: fills its host (the display), NO layer in it
property alias back: <host>.data          // items on the back's plate (transparent ground, NO layer); the popup puts none there
property color screenGround: Theme.listBox    // the display's ground: the stage draws it under the front face and a hair past
                                              //   the display's outline, so the face needs no ground of its own
property bool canFlip: true               // false while the popup has a page open or morphing
property bool relight: true
property bool wired: false                // the cable is drawn in the port
property bool busy: false                 // the fan's ring is lit (a mirror or a transfer runs)
property var partEnabled: ({})            // { power: bool, volup: bool, voldown: bool, cable: bool }: a hit zone takes the pointer
property var partTips: ({})               // { power: "Wake or sleep the screen", ... }: the hover tip, also for a disabled part
property Item overlayItem: null           // where tips are parented (the popup's overlay)
readonly property string face             // "front" | "back": the face at rest (the one that takes input)
readonly property bool flipping           // a turn is in the air (both faces deaf)
readonly property rect screenRect         // the display, in the stage's coordinates, on whole device pixels
readonly property rect plateRect          // the back's plate, likewise
readonly property real screenRadius       // the display's corner radius (the body rounds the corners; content keeps clear)
property real pinTurn: -1                 // a harness or the mockup holds the body at this many turns (0 front, 0.5 back)
property real pinTilt: 0                  // ... and, while held, tips it by this many degrees (90 the bottom wall, -90 the top)
readonly property string hoverPart        // "" | "power" | "volup" | "voldown" | "cable"
readonly property bool atRest             // nothing of the stage's moves or is about to: the body is its cached picture
function regrid()                         // the stage may have moved in its window: read its corner's place on the glass again
signal partClicked(string part)
function scrubTo(p)                       // the fingers' share of a half turn, 0..1 (SwipeScrub's scrub)
function commit()  /  cancel()            // the lift: go on to the other face / spring back
function flipTo(face)                     // a whole run to that face
function flourish()                       // one full turn, landing on the face it started from
function warm()                           // draw the pipelines once (the engine's prewarm)
// FREE LOOK: held, the pointer's own motion turns the body (the stage's hover reads it); let go, it goes back to `face`
readonly property bool looking            // from the hold until the body is back at rest (it counts as `flipping`)
readonly property bool lookHeld           // only while it is held: the pointer is blank over the stage
function lookBegin(): bool                // false: not now (a turn plays, a pin holds the body, a theme switch runs)
function lookBy(dx, dy)                   // the pointer went this far (px): what the hover does; a harness may too
function lookEnd()                        // back to the face it showed, on one clock, the short way round
signal lookStrayed()                      // the hidden pointer is `lookStrayPx` from where the look began (and once more as
                                          //   it is let go): the HOST puts it back there; one that cannot does nothing
signal pointerMoved(int modifiers)        // a pointer motion over the stage, with its keyboard modifiers
```
Rules the popup relies on: at rest the faces are drawn directly (identity transform, crisp, interactive); while
`flipping` they are the same items under the stage's projection (nothing is captured), deaf; `face` changes in the turn
the run lands. The stage never runs a clock at rest. The faces must hold no `layer` (a layer under the projection is
resampled) and must not animate a colour. The device scale is found (DeviceScale), never handed in. The stage's content
lies on the glass's own pixels wherever the popup stands (it is moved by its corner's fraction of a device pixel), so
`screenRect` / `plateRect` can be a fraction of a design pixel off a whole number: lay content out inside the faces, never
beside the stage by these rects. A turn asked for
starts one turn of the event loop later (the body leaves its cached layer, which must not happen inside a pointer
event's delivery), so `flipping` rises a turn after `flourish()` / `scrubTo()` / `commit()`.

The body's own controls are hit zones, not items over drawn parts: `power`, `volup`, `voldown` beside the right frame,
`cable` under the port. Everything else on the body is drawn and takes no pointer.

A skin (`BodyGeometry.js` `SKINS[<name>]`, millimetres) is the ONE description of a phone: `w`, `h`, `t`, `corner`, `edge` (the
frame's rounded edge), `display`, `lip`, `sheet` (where the back face's items lie, as the back is seen), `back` (what lies under
the back glass: `make_decor.py` draws it), `walls` (what each wall of the frame carries; a skin without it gets its `keys` as
bars), `keys` (what stands proud of the frame and what a press moves: `{ id, press: [parts], side, y0, y1, kind, hz }`; a part
named in `press` answers with its share of the key, so a rocker is one key and two parts) and the materials' own colours. The
shader takes at most four keys. A back may carry what stands PROUD of it: `back.plateau { x0, y0, x1, y1, r, h, edge }` (a
rounded slab `h` mm out of the back) and up to three `back.lenses` of radius `r` standing `back.ringH` further; the shader
raises them (uniforms `platA/B`, `ringA..C`, all 0 for a flat back) and `make_decor.py` only paints and shades them.

The popup (`BridgePopup`) adds: `readonly property bool freeLooking` (the look is held: the cast page sends the phone nothing),
`readonly property bool pointerHidden` (the engine's contract word, the same fact: the shell's cursor cover hides the pointer),
`signal lookPointer(string what)` (`"hold"`: remember where the pointer is; `"home"`: put it back -- the OWNER does it through
Hyprland with `HeldPointer.js`'s two expressions, for a live service only), `property bool freeLookHold` (a mockup or a harness
holds the look without the key) and `property bool lookFromMotion` (Alt is also read off pointer motions; a harness whose
synthetic pointer carries no modifiers says no). The key is Alt. `keyboardFocusRequest` is `onDemand` from the first pointer
motion onto the popup until it is parked.

## 9. Decisions (the user's, 2026-11-16)

Name `bridge`. A front-on phone whose screen is the control panel; the body depicts the user's REDMAGIC 10S Pro (silver
"Moonlight") accurately, `generic` for any other device. The back was a second face with the device sheet on it; since
the review of round 2 (2026-11-17: "the flip is purely a fidget, nothing functional") it is the phone's bare back, and
the sheet is the Details page behind the device menu (`ScreenFace` page `"device"`, `DeviceMenu.detailsRequested()`). One
full turn plays at every popup open (`flip.onOpen`). Only the power key, the volume rocker and the cable act. The bar
glyph stands always, after `network`. Not in round 1: a phone-notifications page, a media remote, the phone as a webcam,
an SMS tile.

## 10. Ownership while it is built

| Stream | Owns |
|---|---|
| T (tool) | `tools/bridge/lares-bridge`, `tools/bridge/bridgelib/`, `.examples/bridge.jsonc`, `tools/dev/bridge_cases.py`, `tools/dev/bridge_tool_probe.sh`, `tools/dev/stubs/bridge/`, `tools/dev/fixtures/bridge/` |
| D (service) | `modules/bridge/data/`, `tools/dev/bridge_service_probe.sh`, `tools/dev/qml/bridge_service_probe.qml` |
| G (bar) | `modules/bridge/BridgeBarButton.qml`, `BridgeBarOwner.qml`, `modules/bridge/bar/`, `modules/common/glyphs/BarHues.*`, `tools/dev/flourish_parts.py`, the glyph sheets and the flourish probe |
| U (popup) | `modules/bridge/BridgePopup.qml`, `modules/bridge/screen/` (with the device sheet, once `modules/bridge/back/`), `modules/common/components/TileButton.qml`, `mockups/bridge.qml`, `tools/dev/bridge_popup_probe.sh`, `tools/dev/qml/bridge_popup_probe.qml` |
| B (body) | `modules/bridge/body/`, `modules/bridge/shaders/`, `modules/bridge/assets/`, `tools/bridge/make_decor.py`, `tools/dev/bridge_body_probe.sh`, `tools/dev/bridge_flip_perf.sh`, their harnesses, the shader directory lists |
| M (mount) | everything under `modules/shell/`, `modules/idle/`, the module lists, `docs/` |
