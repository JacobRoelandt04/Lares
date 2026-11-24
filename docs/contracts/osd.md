# OSD — frozen contract (round 1, 2026-10-03)

(The plans, stage-0 facts and round notes this contract names beside it are no longer in `docs/`: they are in git history,
`git log --all -- 'docs/agent_added_files_and_folders/osd_progress/'`.)

Names here are FIXED. A stream that needs a change asks the lead first; nobody renames
silently. The plan and the user's decisions are in `PLAN.md` next to this file.

## 0. Kinds

Kind ids, in this exact spelling:

    volume  mic  brightness  kbd  lockkeys  layout  theme
    track  bluetooth  network  vpn  autoTunnel  btLow  capture  battery  power  caption  generic

- **User kinds** come from a key or an action, and pre-empt at once: `volume mic brightness kbd
  lockkeys layout theme`.
- **Event kinds** come from the system: `track bluetooth network vpn autoTunnel btLow capture battery power caption generic`
  (`autoTunnel` and `btLow`, added by aerial's round, 2026-11-19: the tunnel the module raised by itself on a Public network,
  payload `tunnel: { country }`, and a Bluetooth device's battery at 20 % / 10 %, payload `bt: { name, icon, battery }`; both are
  the `device` card family and come from the AerialService's `osd(kind, payload)` signal -- a card only, the route is the user's)
  (`power`, the 15th, added by silicon's stage 6, 2026-10-07: a CPU profile, GPU mode or charge limit
  changed outside silicon's popup, and the MUX's outcome notice; `caption`, the 16th, added by the
  dictation in round 5, 2026-11-08: the live words of a window take or a voice ask, `kinds/OsdCaption.qml`,
  payload `caption: { mode, head, lines, live, hint }`, a fixed size from `OsdStyle.captionExtent`. Its
  service renews it in place every second while the take runs and ends it with
  `OsdService.withdraw(kind, key)`: the owner drops it from the queue and takes it down if it is on show
  -- a withdraw while it waits for a dip's swap cancels the swap -- and does nothing when it is on show
  while another kind already waits for the swap).
  They are shown for at least `minShowMs` and queued as a FIFO, deduped by kind+key, capped at
  `queueCap`.
- **Dip vs in place:**
  - A request whose `kind` differs from the shown one dips.
  - The same `kind` with a different `key` also dips (two BT devices, for instance).
  - The same kind and the same key update in place.
  - Volume `key` is always `"out"` and mic is always `"in"`, so an output-device switch stays
    in place.

## 1. Payload / request (one object, owner and content read it)

```
{
  kind: "<kind id>", key: "<string>", serial: <int, bumped by the service per request>,
  source: "<who asked: 'key' | 'external' | 'ipc' | 'bus:<name>' | 'mock'>",
  user: <bool: user kind / key-initiated>, ms: <dismiss ms or 0 = config default>,

  // levels (volume, mic, brightness)
  value: <0..max>, max: <1 or 1.5>, muted: <bool>, boost: <bool: the slider's allowBoost>,
  device: { type: "speaker"|"headphone"|"headset"|"hdmi"|"bluetooth"|"mic"|"display", name: "<str>" },

  // kbd
  stop: <int 0..stops-1>, stops: <int, 4>,

  // lockkeys
  keys: { caps: <bool>, num: <bool> }, changed: "caps"|"num"|"",

  // layout
  layout: { code: "US", name: "English (US)" },

  // theme
  theme: { name: "eva", mode: "dark" },              // shown as "eva dark"

  // track (MPD only)
  track: { title, artist, album, art: "<url or ''>", state: "play"|"pause"|"stop",
           action: "next"|"prev"|"toggle"|"stop"|"" },

  // bluetooth
  bt: { name, icon: "<NetIcons kind or ''>", battery: <0..100 or -1>, state: "connected"|"disconnected" },

  // btLow shares the bluetooth shape minus `state`; autoTunnel is `tunnel: { country: "NL" }`

  // network / vpn
  net: { ssid, signal: <0..100>, state: "connected"|"lost" },
  vpn: { name, state: "up"|"down" },

  // capture
  // (a deleted shot is no card: `capture deleted <path> ""` is OsdService.shotDeleted, 2026-11-01)
  capture: { what: "shot"|"rec-start"|"rec-stop"|"copied", path: "<file or ''>",
             thumb: "<file url or ''>", copied: <bool>, label: "<str>" },

  // battery
  battery: { percent: <int>, event: "low"|"full" },

  // power (silicon, stage 6) and generic share this shape
  glyph: "<nerd font char>", title: "<str>", detail: "<str>", colorToken: "<Theme token or ''>"
}
```

Fields a kind does not use are absent or ignored. The content binds to fields defensively: a
missing field renders as its blank/neutral state.

**A brightness `value` is the STEP, not raw / max** (round 3). A key climbs a ladder of rungs along the
perceptual curve (`OsdKinds.brightnessRungs`: twenty at 5 %; rung 0 = true 0, rung 1 = the true minimum
level `floorRaw`, the top = max) and the request says rung / rungs -- 0, 0.05, 0.10 ... 1: the ball and the
figure read it, five points a press. A drag on the slider (`userValue`) is a step-space fraction and maps
back through the ladder (never to true 0: that is the key's second press). A held key stops at the bottom
rung; a fresh press down that begins there goes to true 0, and one up leaves it
(`OsdKinds.brightnessZeroOpens`, decided at the press, the volume boost gate downwards).

**A brightness card for an external display (DDC, round 2)** adds payload fields, all optional: `pending` (the figure is the GOAL and the
display has not confirmed it: the card draws the figure and glyph muted and sweeps a slim "sent" mark; it is asked for again every second
while pending and once with `pending: false` when the write is done), `ddcState` (`"unknown" | "probing" | "ok" | "unsupported" |
"failing"`), `unavailable` (true for unsupported / failing: nothing moves, the slider is off) and `note` (the words under the display's
name: the reason, or "Looking for the display" while no figure is known). `device.name` is the display's label, never the laptop's.

## 2. `modules/common/osd/OsdBus.qml` (singleton, qmldir `singleton OsdBus 1.0`)

```
property var service: null           // OsdService registers itself; clears on destruction
function show(req) -> bool           // false = no service or route not "osd" (the caller falls back)
```

Silicon's planned call `show({source, key, glyph, title, detail, colorToken, ms})` without a
`kind` is treated as `kind: "generic"`. Generic is disabled by default in config, so it returns
false until the user enables it.

## 3. `modules/osd/data/OsdService.qml`

```
property bool live: true                 // false: no Process / Pipewire / Hyprland; sources simulate
property var config                      // OsdConfig
property string screen                   // the screen the OSD shows on (focused monitor; mockup: "")
property bool playerOpen: false          // the player module is open on some screen (mini, normal, side panel):
                                         // the OR of every screen's owner, written ONCE by the shell. The owners hold
                                         // the `track` card back while it is true (OsdKinds.suppressedBy, §6)
property var displayBackend: null        // the display module (Panorama service or mock): null = brightness keys step the laptop's backlight.
                                         // brightnessTarget(screen) -> { kind "panel" (internal) | "ddc" (EVERY external: its state says the rest), connector, label };
                                         // ddcAdjust(n, delta): bool (adds to the display's one goal; false = it cannot take it), ddcValue / ddcGoal /
                                         // ddcMax / ddcPending / ddcState ("unknown"|"probing"|"ok"|"unsupported"|"failing") / ddcReason (n),
                                         // ddcScrub(n, v) / ddcCommit(n) (a slider: written at rest), optional ddcEnsure(), signal ddcChanged(name)
property string focusedScreen: ""        // the focused output's name, written by the host: the brightness keys' fallback target
property var monitorRects: []            // FocusedScreen.outputs (name, x, y, width, height in pixels, scale, transform) or ready logical rects:
                                         // the brightness keys act on the monitor under the pointer (`hyprctl -j cursorpos`, 150 ms, else focusedScreen)
property string hyprctl: "hyprctl"       // the program that answers cursorpos (a probe's stub)
property bool pointerLive: live          // false: the focused screen decides without asking
property int pointerWaitMs: 150, gestureKeepMs: 400
readonly property int panelRev           // the laptop panel for the display module's popup: bump-read first in a binding
function panelBrightness()               // -> { capable, value 0..1 }
function setPanelBrightness(v01)         // on the ladder; never writes 0
function refreshPanel()                  // read the panel now; panelRev moves
readonly property var sources            // { audio, backlight, ddcBrightness, kbd, lockKeys, layout, theme, mpd, bt, net, capture, battery }
signal request(var req)                  // an accepted request for the owner(s); req has `serial`

function show(req) -> bool               // entry for sources, the bus and IPC: fills defaults,
                                         // applies route (osd -> request; notification -> DesktopNotifier; off -> false)
// actions (keys, IPC, mockup Run tab)
function volume(verb)                    // "up" | "down" | "mute" | "press-up" | "release-up" ...
function mic(verb)                       // "up" | "down" | "mute"
function brightness(verb)                // "up" | "down" | "up-fine" | "down-fine"
function kbd(verb)                       // "up" | "down"
function lockkeys()
function media(verb)                     // "next" | "prev" | "toggle" | "stop"
function capture(what, a, b)             // ("shot", path, "copied"|"plain"), ("rec", "start"|"stop", path), ("copied", label)
// from the content (interactive OSD)
function userValue(kind, v)              // volume/mic/brightness: set the value (no OSD re-request beyond in-place)
function userToggleMute(kind)
function userToggleBoost(kind)
function test(kind)                      // a plausible request of that kind (IPC `test`)
```

**Volume key repeat and boost:**
- The hardware keys arrive through `OsdShortcuts` as press/release.
- The service's own repeat timer steps volume or brightness while a key is held. The delay and
  rate come from config, or "auto" (`hyprctl getoption input:repeat_delay/rate`, mockup
  600/25).
- The boost gate: a held key stops at 1.0. A press that starts at 1.0 crosses into boost, up
  to `boostMax`.

## 4. `modules/osd/OsdContent.qml` (drop-in; one per kind instance)

```
property string kind
property string orientation: "h"         // "h" | "v" | "pill"
property var payload: ({})
property bool interactive: true          // pill: false
property var style: null                 // OsdStyle; null = built-in defaults
property real renderScale: 1
readonly property bool hovered
signal userValue(real v)
signal userToggleMute()
signal userToggleBoost()
signal touched()                         // any pointer interaction (re-arms the owner's timer)
signal hideRequested()                   // the card's own hide button (the caption's): the owner hides it
readonly property rect hideRect          // that button's hit area in this item's px (empty: the card has none)
implicitWidth / implicitHeight           // per kind x orientation (OsdStyle holds the numbers)
```

**Rules:**
- Text never rotates. Vertical layouts stack.
- Colours bind to `Theme` (no hex defaults left).
- There is no `Behavior` on a colour.
- A level's displayed value eases on ONE clock: 120 ms OutCubic for external changes, and
  directly while dragging.
- The wheel is read with a `MouseArea` (gestures.md), never a WheelHandler. Middle-click mutes.
- The content declares no `keyboardFocusRequest` (the engine treats that as "none").

## 5. Engine OSD slot (`modules/bar/gooey/GooeyEngine.qml`)

```
function openOsd(ownerId, barId, along, w, h, component, opts)   // opts { alongAt: 0.5, widthFrom, key }
function closeOsd(opts)                                           // opts { ms, easingIndex }
signal osdSwap(string ownerId, var key)   // bottom of a dip / hop, BEFORE the component is set
readonly property var  theOsd             // GooeyBody
readonly property bool osdOpen            // live || dipping
readonly property string osdOwnerId
readonly property string osdRequestOwner
readonly property bool osdBlocked
readonly property string osdPhase         // closed | opening | open | moving | dipping | closing
readonly property var  osdKey
readonly property var  osdTargetBox
readonly property var  osdStats           // {placements, opens, dips, hops, displaced, pushes, blocked}
property int  osdOpenMs: 320;  property int osdOpenEasingIndex: 3;  property real osdOvershoot: 1.15
property int  osdCloseMs: 220; property int osdCloseEasingIndex: 1
property int  osdDipFoldMs: 110; property int osdDipFoldEasingIndex: 6
property int  osdDipRiseMs: 240; property int osdDipRiseEasingIndex: 3
property real osdDipWidthTo: 1
property int  osdGlideMs: 300; property int osdGlideEasingIndex: 1
property real osdWidthFrom: 0.6
property bool osdMelt: true; property bool osdDisplaceLane: true; property bool osdPushPopup: true
property var  osdPoseBox: null            // debug: draw the OSD at this box (PoseRecorder playback)
```

**Request semantics:**
- `openOsd` with the same component and key as the shown one updates in place: `w`/`h` null
  follow the implicit size on the resize clock.
- A different component or key dips.
- A different bar hops: fold on the old bar, open fresh on the new one.
- `along` is bar-local px, as in `open`'s `localCenter`. `alongAt` is the fraction of the OSD's
  length that sits at `along` (the lane's rule).

**Priority:** the OSD glides first, then the lane is displaced, then thePopup is pushed
(`osdYield`), then the OSD waits (`osdBlocked`).

**Rendering:**
- The OSD clips against every other slot on every frame, so it yields.
- It melts (`peers[]`) with same-edge neighbours.
- It keeps a gap of `blendRadius` from perpendicular ones.
- Layout order: the OSD comes after the lane and before the flourish. With no OSD out, the
  scene is byte-identical to HEAD.

## 6. `modules/osd/OsdOwner.qml`

```
required property var engine
property var service                       // OsdService
property var style                         // OsdStyle
property string ownerId: "osd"
property string screenName: ""
property var spot: ({ bar: "right", along: 0.5 })   // BarSpot.placeOf rules (bar+along or corner)
property bool fullscreen: false            // FullscreenWatch.fullscreen (focused screen)
property string fullscreenMode: "pill"     // "pill" | "suppress"
property var pill: null                    // OsdPill instance (the host places it; mockup: on stage)
readonly property var shown                // payload on screen
readonly property var pending              // payload waiting for osdSwap
readonly property string orientation       // "h" | "v" from the spot's bar edge
readonly property bool hovered
readonly property bool hidden              // the shown card is hidden by the user (tucked on a bar, the ball in the pill)
function hideShown()                       // the content's hideRequested / the pill's: hide the card on show (its key's)
function unhide()                          // the pointer moved onto the sliver or the ball: out again
property int resumeMinMs: 800
property int minShowMs: 600
property int queueCap: 3
```

**Behaviour:**
- **Each request:**
  - In fullscreen with mode `pill`: `pill.present(req, hidden)`.
  - Otherwise: `engine.openOsd(ownerId, place.barId, place.local, null, null, componentFor(req.kind), {alongAt, key: req.kind + ":" + req.key, tucked: hidden})`.
- **Hidden** (round 6): the user's hide button marks the shown card's KEY hidden; its renewals land in place (tucked / in the ball),
  another card in between comes out as ever and the hidden one returns hidden, `withdraw` of that key or `dismiss` forgets it. A
  HoverArm on `engine.osdTuckZone` (active while `engine.osdTuckedRest`) calls `unhide()` a turn after the pointer MOVED onto it.
- **Promotion:** `pending` becomes `shown` on `osdSwap`, or at once when the request updates in
  place or opens fresh.
- **Held back:** with `service.playerOpen` a `track` request is dropped on arrival (not queued) and
  the ones already waiting go the moment it turns true; what is on screen runs out. Round 3: "the
  osd mpd currently playing should not open when the player module is open in any way". Only the
  OSD surface: a kind routed to a notification is untouched.
- **Dismiss:** a single-shot timer per request (`req.ms` or config). Hover freezes it; on leave
  the remaining time is `max(remaining, resumeMinMs)`; `touched()` re-arms it; on expiry,
  `engine.closeOsd()` or `pill.dismiss()`.

## 7. `modules/osd/OsdPill.qml` (+ `OsdPillWindow.qml`)

```
property var style
property real renderScale: 1
readonly property real pillT              // 0..2: 0 dot -> 1 vertical capsule -> 2 full width
readonly property bool showing
function present(req, hidden)             // first: spawn; same kind: in place; other kind: curtain swap; hidden: the ball
function dismiss()
signal closed()
signal hideRequested()                    // the content's hide button
signal revealRequested()                  // the host's pointer moved onto the parked ball (`reveal()`)
readonly property bool hidden, ballParked, moving
readonly property real offsetY            // <= 0: how far up the host draws it (the ball's rise)
readonly property rect ballRect, hideRect // where the host takes input, in the pill's px
implicitWidth / implicitHeight            // the current box (the host centres it at the top)
```

`OsdPillFrame`: everything of the window but the window -- the pill (centred, `pillTop + offsetY` down), the crossfade host, and
two zone Items in its own px (`ballZone`, `hideZone`; no size when unused) with a HoverArm on the ball; its implicit size is
`OsdStyle.pillWindowExtent()` (the largest pill of EVERY kind, the shadow's reach round it, the top margin) times `k`.
`OsdPillWindow`: a PanelWindow, top anchor, `WlrLayershell.layer: WlrLayer.Overlay`, `exclusiveZone: 0`, `mask` the union of the
frame's two zones (empty: click-through), transparent background, filled by one `OsdPillFrame`; created per screen by the final
assembly.

## 8. `modules/osd/OsdStyle.qml`

A `QtObject` holding every look and motion number of the content and the pill; it is the
mockup panel's target. Names are chosen by stream V and listed in its header comment, and
stream O reads only `style.extentOf(kind, orientation)` (returns `{w, h}`).

## 9. `osd.json` (`~/.config/quickshell/config/osd.jsonc`; `.examples/osd.jsonc`, JsonComments)

```
{
  "spot": { "bar": "right", "along": 0.5 },        // or { "corner": "right-bottom" }
  "screen": "focused",                              // or a connector's name
  "fullscreen": "pill",                             // "pill" | "keys" | "suppress"
  "dismissMs": 2000, "resumeMinMs": 800, "queueCap": 3,
  "repeat": { "delayMs": "auto", "rateHz": "auto" },
  "volume": { "step": 0.02, "boostMax": 1.5 },
  "mic": { "step": 0.05 },
  "brightness": { "device": "", "step": 0.05, "fineStep": 0.01, "gamma": 2.0, "floorRaw": 1, "target": "pointer" },
  "media": { "keys": "mpd" },                       // "mpd" | "auto"
  "capture": { "dir": "~/Pictures/Screenshots", "name": "shot-%Y%m%d-%H%M%S.png", "copy": true,
               "openCommand": ["xdg-open", "{path}"], "editCommand": [], "click": "edit" },
  "kbd": { "device": "asus::kbd_backlight" },
  "layout": { "keyboard": "main", "codes": { "English (US)": "US", "Belgian": "BE" } },
  "kinds": {                                        // per kind: route, ms (0: a user kind's dismissMs, an event kind's table time), events
    "volume": { "route": "osd", "ms": 0 }, ... ,
    "generic": { "route": "off", "ms": 0 }
  }
}
```

Routes are `"osd"`, `"notification"` (posted through `DesktopNotifier`) or `"off"`. Every kind
defaults to `"osd"` except `generic`, which is `"off"`.

## 10. Shared pieces (stream C)

- **`modules/common/system/FullscreenWatch.qml`:**
  - `property bool liveSignals: true`, `property bool fake: false`,
    `property bool fakeFullscreen: false`
  - `readonly property bool fullscreen` (the focused workspace has a fullscreen window),
    `readonly property string focusedScreen`
  - Logic lifted from `NotificationHolds.qml`, which then uses it.
- **`modules/common/system/LockKeys.qml`:** promoted from `modules/lockscreen/lock/KeyState.qml`,
  with the same API plus `num`; the lockscreen imports it.
- **`modules/common/components/AudioGlyphs.qml`** (QtObject):
  - `outputGlyph(type, volume, muted)`, `inputGlyph(muted)`, `deviceType(node)`
  - the table moved from `AudioBarButton.qml:53-73`, which reads it.
- **`modules/common/components/GrooveTrack.qml`:** `property string orientation: "horizontal"`
  ("horizontal" | "vertical"). Horizontal stays byte-identical.
- **`modules/common/components/BarSpot.js`:** `placeOf(spot, bars)`, lifted verbatim from
  `NotificationsBarOwner._placeOf`. It returns
  `{barId, local, alongAt, corner2D, corner, key}`; the notifications owner calls it.

## 11. IPC (`modules/osd/OsdIpc.qml`, target `osd`)

```
volume <up|down|mute>   mic <up|down|mute>   brightness <up|down|up-fine|down-fine>   kbd <up|down>
lockkeys   media <next|prev|toggle|stop>
capture <shot|rec|copied> <a> <b>
request <json>   dismiss   test <kind>      (not `show`: quickshell ipc has its own `show` subcommand)
```

GlobalShortcut names (`OsdShortcuts.qml`, appid `lares`): `osd-volume-up`,
`osd-volume-down`, `osd-volume-mute`, `osd-mic-mute`, `osd-brightness-up`, `osd-brightness-down`,
`osd-brightness-up-fine`, `osd-brightness-down-fine`, `osd-kbd-up`, `osd-kbd-down`,
`osd-lockkeys`, `osd-media-next`, `osd-media-prev`, `osd-media-toggle`, `osd-media-stop`.
