# Notifications round 1 — frozen contract

(The plans, stage-0 facts and round notes this contract names beside it are no longer in `docs/`: they are in git history,
`git log --all -- 'docs/agent_added_files_and_folders/notifications_progress/'`.)
(The gates, probes and fixtures this contract names without a directory went with the cleanup: tag `pre-cleanup` has them. What a change is proved with now is in `tools/dev/`, [tools.md](../tools.md).)

Approved plan: `PLAN.md` here (copy of `~/.claude/plans/your-job-is-to-stateless-puddle.md`;
its Decisions section is the user's and is not re-asked). Stage 0 facts: `0.md`.

Every stream builds against the names below. A stream that needs a change writes it in its
progress file (`<X>.md`) and asks the host (U) — it never edits another stream's files.

**Hands off for everyone:** `modules/common/theme/Theme.qml`, `themes/eva.json`,
`tools/dev/theme_sync_probe.sh` (concurrent sessions), every `modules/launcher/**` file and
`test_launcher*` (the launcher session is live in this tree), `bar_in_progress.qml` (the
user's). Existing Theme tokens only.

**Test hygiene:** `SCRATCH=$HOME/.cache/claude-notifications/<stream>` (NOT /tmp — its quota
bit the launcher round), `SANDBOX=$SCRATCH/lares-sandbox` via `tools/dev/sandbox.sh`; private
`XDG_CONFIG/STATE/DATA/CACHE_HOME` with a seeded `theme/state.json`; anything that registers
or talks to `org.freedesktop.Notifications` runs under `tools/dev/notifications_bus.sh` (a private
bus with NO activatable services); stub `pw-play` / `notify-send` / `gdbus` / `hyprctl` /
`systemctl` on PATH wherever the code could reach them; grabs offscreen +
`QT_QUICK_BACKEND=rhi`; quit from a Timer; never pkill/pgrep quickshell; kill only the pid
you hold; no perf benchmark while another quickshell runs (the host serialises perf).
Streams do NOT commit; the host commits each landed stream by explicit paths.

## Shared vocabulary

- **urgency** strings: `"low" | "normal" | "critical"`.
- **group** ids, in display order: `"critical" | "system" | "normal" | "low"`. Everything with
  `origin: "shell"` is `"system"`; a D-Bus notification's group is its urgency unless an app
  rule overrides it.
- **sourceId**: a shell source's slug — `"clock"`, `"stocks"`, `"launcher"`, `"llm"`,
  later `"battery"`, `"update"`, `"network"`, `"bluetooth"`, `"auth"`, `"notifications"` (the
  module's own summaries). `DesktopNotifier.sourceId` defaults to `appName.toLowerCase()`.
- **appKey**: the bundling key of a D-Bus notification: `desktopEntry` if non-empty, else
  `appName`, lowercased and trimmed. For shell records `appKey = sourceId`.
- Time is epoch **ms** everywhere (`Date.now()`); durations in ms; `-1` = sticky / never.

## Record (persisted shape)

```
{ uid:        string   // "d<serverId>-<arrivedMs>" for dbus, "s<sourceId>-<key>-<arrivedMs>" for shell
  origin:     "dbus" | "shell"
  serverId:   int      // Notification.id (0 for shell)
  sourceId:   string   // "" for dbus
  key:        string   // shell key ("" for dbus)
  appName, appKey, desktopEntry, appIcon: string
  summary:    string
  body:       string   // NotifyMarkup.sanitize()d StyledText
  bodyText:   string   // NotifyMarkup.plain(), for filter + collapsed header subtitle
  urgency:    "low" | "normal" | "critical"
  group:      "critical" | "system" | "normal" | "low"
  arrivedMs, updatedMs: number
  actions:    [{ id, label }]        // "default" and "inline-reply" are NOT in this list
  hasDefault: bool
  reply:      null | { placeholder }  // x-kde-reply-placeholder-text hint, else the action's text
  image:      null | { url, file, w, h, kind: "avatar" | "picture", openPath }
                                      // url: live (image://qsimage/..., image://icon/..., file://...)
                                      // file: images/<uid>.png once grabbed, "" before
  progress:   int                     // -1 none, else 0..100 (the "value" hint)
  resident, transient: bool
  pinned:     bool,  pinnedMs: number
  closed:     bool   // the app closed it while pinned: kept, actions off
  stale:      bool   // loaded from disk after a restart: actions + reply off
  seen:       bool   // arrived before the manager was last opened
}
```
Runtime only (never persisted, never in a model — the service keeps them in a side map by
uid): the live `Notification`, the spec's callbacks (`onAction`, `onDefault`, action `run`),
`bodyComponent` + `bodyProps`, sound decisions, toast timing. `update(uid, { bodyProps })` re-feeds a LOADED body
(the card writes the new props into the item it already built, keyed on the rich record's `rev`, which only
`update` moves): a body that may be updated takes its data as one object property.

`history.json` = `{ "version": 1, "records": [ ...record ] }`, written 300 ms after the last
change (coalesced), atomic, with a self-write guard (StocksState pattern). `transient` records
and records whose app rule says `history: false` are never written. Image files live in
`<state>/notifications/images/<uid>.png` and are deleted with their record.

## Config — `$XDG_CONFIG_HOME/quickshell/config/notifications.jsonc`

Parsed through `JsonComments.strip` (comments allowed; an error names the line and keeps the
previous config). Hot-reloaded (static FileView path, `watchChanges`). Every key optional; the
defaults below are the code's and `notifications.example.jsonc` documents them.

```
{
  "spot":      { "corner": "top-right" },          // or { "bar": "<barId>", "along": 0.5 }
  "screen":    "focused",                          // or a connector's name
  "timeouts":  { "low": 4000, "normal": 8000, "critical": -1,
                 "clampMin": 3000, "clampMax": 60000 },
  "toasts":    { "max": 5, "floodCount": 3, "floodWindowMs": 10000, "hoverResumeMinMs": 2000,
                 "swipe": { "right": "file", "left": "delete" } },
  "manager":   { "openGroup": "latest", "swipe": { "right": "pin", "left": "delete" } },
  "clickFocus": true,
  "bell":      { "ring": "always" },
  "retention": { "count": 200, "days": 7 },
  "undoMs":    10000,
  "idleMs":    60000,                              // away-hold: IdleMonitor timeout
  "sounds":    { "low": [], "normal": ["~/.local/share/sounds/notification.mp3",
                                       "/usr/share/sounds/notification.mp3"],
                 "critical": ["~/.local/share/sounds/notification-critical.mp3",
                              "~/.local/share/sounds/notification.mp3",
                              "/usr/share/sounds/notification.mp3"] },
                                                   // first file that exists wins; none = silent
  "soundVolume": -1,
  "dnd":       { "remember": true, "hours": [], "summary": true, "holdApps": [],
                 "breakthroughSources": ["clock", "auth"], "holdFullscreen": true, "holdScreencast": true },
  "apps":      { "kitty": { "focusSuppress": false } },
  "sources":   { }                                 // "<sourceId>": same keys as an app rule
}
```
App/source rule keys: `mute` (bool: no toast, no sound, still filed), `urgency`, `group`,
`timeoutMs`, `sound` (path, `"none"`, or absent), `breakDnd` (bool: past DND, no other hold), `history` (bool), `focusSuppress` (bool,
default true). App rules match `desktopEntry` first, then `appName`, case-insensitive.

## P — pure policy (`.pragma library`, node-testable)

`modules/notifications/data/NotifyPolicy.js`
```
GROUPS = ["critical", "system", "normal", "low"]
defaults()                                   -> the config defaults above (deep copy)
merge(cfg)                                   -> defaults deep-merged with a parsed file
ruleFor(cfg, rec)                            -> {} | rule (apps by desktopEntry, then appName;
                                                sources by sourceId)
groupOf(rec, rule)                           -> group id
timeoutFor(rec, cfg, rule, requestedMs)      -> ms | -1
    // requestedMs: the sender's expire_timeout (dbus) or spec.timeoutMs (shell; undefined = default)
    // dbus: -1 -> urgency default; 0 -> -1 for normal/critical, low default for low;
    //       N -> clamp(N, clampMin, clampMax). rule.timeoutMs wins over all of it.
    // shell: undefined -> rule/source timeout, else urgency default; -1 sticky; N as given.
breaks(rec, cfg, specBreak)                  -> bool   // critical || specBreak || source in list
decide(rec, ctx)                             -> { toast: "show"|"hold"|"file"|"drop",
                                                  sound: bool, seen: bool, reason: string }
    ctx = { dnd, breaks, hold: ""|"locked"|"screencast"|"fullscreen", managerOpen,
            attended, focusedSender, focusSuppress, mute, synchronous }
    // In this order: synchronous -> drop. managerOpen -> file (seen, silent).
    // attended -> file (seen, silent). dnd && !breaks -> file (silent). mute -> file
    // (silent). focusedSender && focusSuppress && urgency != critical -> file (silent).
    // hold "locked" -> hold (everything; nothing draws over the lock; criticals come back
    // individually on release, see heldRelease). hold "screencast" | "fullscreen" -> hold,
    // EXCEPT urgency critical -> show (in full). else show (sound unless rule/urgency
    // says none). Only "show" and "hold" ever reach a toast; DND never replays.
retoast(prev, next)                          -> "retoast" | "silent" | "inplace"
    // summary or body changed -> retoast; only progress changed -> silent; else inplace
order(records)                               -> records sorted: group order, then pinned
                                                (pinnedMs desc), then updatedMs desc
bundle(groupRecords, minSize = 2)            -> [{ appKey, records: [...] } | { record }]
retain(records, nowMs, cfg, protectedUids)   -> { keep: [...], drop: [...] }
    // pinned never dropped; protectedUids (undo windows) never dropped; oldest first by
    // count, then everything older than days
imageKind(w, h, cfg)                         -> "avatar" | "picture"
    // both sides <= avatarMax and aspect within 0.8..1.25 -> avatar
staggerDeadlines(deadlines, minGapMs)        -> deadlines, pushed so no two are < minGap apart
                                                (order kept; sticky -1 untouched)
floodCheck(history, appKey, nowMs, cfg)      -> { flooded: bool, count }
    // history: [{ appKey, t }] of recent SHOWN toasts
heldRelease(held, reason)                    -> { summary: { count, reason } | null,
                                                  individual: [uid...] }
    // criticals always individual; the rest one summary (none when zero)
dotGroup(records, lastOpenedMs)              -> group id | ""   // most urgent unseen
```
`modules/notifications/data/NotifyMarkup.js`
```
sanitize(body) -> StyledText: keeps <b> <i> <u> and <a href> with http/https/mailto/file
                  schemes; drops <img> (keeps its alt text); escapes everything else; \n -> <br>
plain(body)    -> text with tags removed and entities decoded, whitespace collapsed
```
`modules/common/components/SenderMatch.js`
```
norm(s)                                  -> lowercased, trimmed, ".desktop" stripped
matches(rec, win)                        -> bool   // win = { cls, initialClass, title, pid }
    // pid (sender-pid hint) exact wins; else desktopEntry / appName vs class / initialClass
focusTarget(rec, windows)                -> window | null   // best match among clients
```
`modules/common/components/RelTime.js`
```
format(ms, nowMs) -> { text, nextMs }
    // < 60 s "now"; < 60 min "N min"; < 24 h "N h"; else "ddd HH:mm" (older than 6 days:
    // "d MMM HH:mm"); nextMs = the instant the text would change
absolute(ms)      -> "ddd d MMM yyyy, HH:mm"
```

## D — data, service, adapter

`modules/common/notify/qmldir` (`singleton NotificationBus 1.0 NotificationBus.qml`) +
`NotificationBus.qml`: `Singleton { property var service: null }`. Only the service writes it.

`modules/notifications/data/NotificationService.qml` (one per shell, outside `Variants`):
```
property string configPath      // default $XDG_CONFIG_HOME/quickshell/config/notifications.jsonc
property string statePath       // default $XDG_STATE_HOME/lares/notifications/state.json
property string historyPath     // default $XDG_STATE_HOME/lares/notifications/history.json
property bool serverEnabled: true   // owns org.freedesktop.Notifications (bridge Loader)
property bool registerOnBus: true   // writes NotificationBus.service
property bool liveSignals: true     // false in probes: holds are driven by hand
property bool persist: true         // false: nothing is read or written
property var  iconStore: null       // the ONE AppIconStore per shell (host hands it)
readonly property var store         // NotificationStore
readonly property var config        // merged config object (NotifyPolicy.merge)
readonly property var holds         // NotificationHolds
readonly property var toasts        // ToastScheduler
readonly property int serial        // bumps on ANY record/list change (read it first)

// shell sources
function post(spec): string uid
    spec = { source (required), key ("" = unique), title, body, urgency ("normal"),
             timeoutMs (undefined = default), actions: [{ id, label, run? }],
             onAction(id), onDefault(), bodyComponent, bodyProps, icon (glyph text or
             icon name/path), image (url/path), progress (-1), sound ("none" default;
             "default" = urgency sound; or a path), breakDnd (false), resident (false),
             persist (true), fixed (false), deadlineMs (0), deadlineTotalMs (0) }
    // same (source, key) as a live record = replace in place (retoast rule applies)
    // deadlineMs / deadlineTotalMs (round 11): a time that is somebody else's, only SHOWN. The wall instant and the span (ms) the card's
    //   drain runs over; ToastEntry draws it from the instant (stepped as every drain is), with no freeze for a hover, an idle user
    //   or a folded lane, and the scheduler never sees it: the toast stays sticky there, so nothing expires, is filed or is dropped
    //   when the drain reaches nothing. `update(uid, { deadlineMs, deadlineTotalMs })` moves it in place, silently (a later instant
    //   stretches the span so a drain never refills -- the poster's job); 0 = none. The MUX keep prompt (silicon) is the one user.
    // fixed: live UI, not a notification (the auth prompt, stage 2). rec.fixed = true,
    //   transient, seen, group "fixed" (none of the manager's groups: it is neither listed
    //   nor counted). The user's verbs do nothing to it -- file, remove, togglePin, activate
    //   return false/no-op, clearAll/clearGroup skip it, a click or an action never consumes
    //   it, the toast has no swipe verbs (ToastEntry.fixed). Only the poster ends it, with
    //   withdraw/withdrawUid. Whatever takes it off the lane otherwise (a timeout, an
    //   overflowing stack, a hold's digest) DROPS the record; a decision to file it (manager
    //   open, DND, a rule) shows it instead, and opening the manager puts it straight back
    //   on the lane. Known limit: a sixth toast on a full stack pushes an older FIXED one
    //   off -- and drops it (a prompt should be the newest, or the stack not full).
function update(uid, patch): bool
function withdraw(source, key)          // gone everywhere; pinned -> closed, kept
function withdrawUid(uid)
function attend(source, on)             // while on: that source's posts file silently, seen

// interaction (a rich body's ask of the host; stage 2)
function setInteraction(token, { keyboard: "none"|"onDemand"|"exclusive", catchAll: bool, uid?: string })
function clearInteraction(token)
readonly property var interaction       // { keyboard, catchAll }: the strongest over all tokens;
                                        // a NEW object only when either changed (interactionChanged)
    // The token is the caller's own string. The body clears its own on destruction; a token
    // whose spec carries `uid` (or equals a uid) is also cleared the moment that record ends
    // (withdraw, drop), so a body that never ran cannot leave the lane catching clicks.
    // NotificationToast republishes it: keyboardFocusRequest = the stronger of a reply being
    // typed ("onDemand") and interaction.keyboard; `maskCatchAll` = interaction.catchAll,
    // which GooeyEngine reads (gooey_engine.md, `maskCatchAll`). Probe: auth_lane_probe.sh.

// user verbs (the UI calls these)
function file(uid)          // toast right-swipe / timeout: leaves the toast, stays
function remove(uid)        // left swipe / Delete: gone; dbus -> Notification.dismiss()
function togglePin(uid)
function invoke(uid, actionId)
function activate(uid)      // body click: default action, else focus the sender's window
function reply(uid, text)
function clearAll(): string token       // unpinned only
function clearGroup(group): string token
function undo(token): bool              // within undoMs
function markSeen()                     // manager opened
function imageGrabbed(uid, file)        // the UI saved a live image; record.image.file = file

property bool dnd                       // persisted in state.json
readonly property string holdReason     // holds.reason
readonly property var groupCounts       // { critical, system, normal, low } (unpinned + pinned)
readonly property string dotGroup       // NotifyPolicy.dotGroup
property string lastGroup               // persisted; the manager writes it
readonly property string laneScreen     // focused monitor name when the stack last grew
property bool managerOpen               // the owner binds it
signal openManagerRequested(string screenName)   // IPC / "+N more" / summary toast
signal closeManagerRequested()
signal recordAdded(string uid)          // for the UI's row animations
signal recordRemoved(string uid)
```
Behaviour pinned down by stage 0 (`0.md`): the server emits `notification` ONCE per id — a
replace updates the same object in place, so the bridge watches `summaryChanged`,
`bodyChanged`, `hintsChanged`, `actionsChanged`, `imageChanged`, `urgencyChanged`,
`appIconChanged` and runs `retoast`. `invoke()` on a non-resident notification and
`sendInlineReply()` both CLOSE it (`Dismissed`) — the record goes with it (resident stays).
An untracked notification is reported Dismissed to the client at once (that is how
synchronous OSD ones are dropped). `closed(CloseRequested)` = the app withdrew it.
Capabilities: set `bodySupported`, `bodyMarkupSupported`, `bodyHyperlinksSupported`,
`actionsSupported`, `imageSupported`, `inlineReplySupported`, `persistenceSupported`,
`keepOnReload`; `extraHints: ["sound"]` (we honour sound-file / suppress-sound). Do NOT
advertise `x-canonical-private-synchronous`.

`NotificationStore.qml`
```
readonly property ListModel model       // rows { uid, rec } ; rec = QtObject { property var d }
readonly property int serial
function get(uid): record | null         // the d object
function put(record)                     // insert or replace (d re-assigned, no new delegate)
function patch(uid, fields)
function drop(uid)
function all(): [record]                 // NotifyPolicy.order()ed
function ensureLoaded() / save()         // history.json (read once, at completion), images cleanup
                                         // (a load() that re-read the file was dead and read the PREVIOUS
                                         // load's bytes -- reload() then text() on a blockLoading-only
                                         // FileView -- and is gone; shell round 2)
```
`ToastScheduler.qml` (`service.toasts`)
```
property int maxToasts; property int staggerMs      // from config
readonly property var shown             // [uid], newest first, <= maxToasts
readonly property int moreCount         // pushed out by overflow since the stack last emptied
readonly property var floods            // { uid: n } "<app> . +n more"
readonly property bool frozen           // hover || idle || replying
readonly property int serial
function timing(uid): { totalMs, leftMs, sticky }   // leftMs as of now, frozen-aware
function hover(on)
function replying(on)
function expireNow(uid)                 // the UI's right swipe (= file) goes via service.file
signal expired(string uid)
```
`NotificationHolds.qml` (`service.holds`)
```
property bool liveSignals
property bool fullscreen; property bool screencast; property bool locked; property bool idle
readonly property string reason          // "locked" > "screencast" > "fullscreen" > "app" (dnd.holdApps) > ""
property var activeWindow                // { cls, initialClass, title, pid } | null
readonly property var windows            // [{ cls, initialClass, title, pid, address }]
function focusApp(rec): bool             // Hyprland dispatch focuswindow on SenderMatch target
```
Live sources: Hyprland `rawEvent` (`screencast>>STATE,OWNER`, `fullscreen>>0|1`,
`activewindowv2`), `Hyprland.toplevels`, `IdleMonitor { timeout: idleMs/1000 }`; lock via the
IPC `hold("locked", on)` (the user's hypridle line) — no polling.

`NotificationsIpc.qml` — `IpcHandler { target: "notifications" }`:
`function dnd(mode: string): string` (`"on" | "off" | "toggle" | ""` query → `"on"|"off"`),
`open(): void`, `toggle(): void`, `close(): void`, `count(): int` (unseen),
`hold(reason: string, on: bool): void`.

`NotificationConfig.qml`, `NotificationState.qml` (`dnd`, `lastGroup`, `lastOpenedMs`),
`NotificationServerBridge.qml`, `NotificationSound.qml`, `FakeNotification.qml` (a QtObject
with Notification's shape + the change signals + `expire/dismiss/sendInlineReply`, and
`actions: [{ identifier, text, invoke() }]`), `NotificationFixtures.qml` — internal to D.

**Adapter** — `modules/common/components/DesktopNotifier.qml` keeps every existing member
(`appName`, `notifySend`, `gdbus`, `keys`, `notify`, `withdraw`, `action`) and gains:
```
property string sourceId: appName.toLowerCase()
property bool attended: false
```
With `NotificationBus.service` set: `notify(key, spec)` → `post({ source: sourceId, key, title,
body, urgency, timeoutMs: spec.timeoutMs === 0 ? -1 : spec.timeoutMs, actions, onAction: id =>
action(key, id), sound: "none" })`; `withdraw(key)` → `service.withdraw(sourceId, key)`;
`attended` → `service.attend(sourceId, attended)`. Body click on such a record = its action
with id `default`, `open` or `show` if it has one. Without the bus: the notify-send path is
byte-identical to HEAD (LLM probe T9 and the timer/clock probes count its argv).

**LlmAttention** — same branch in `_notify` / `_answered` (post / withdraw, `Show` → `showRequested()`);
new: `signal openConversation(string convId)` and, with the bus only and `!attended`,
`service.answerCompleted(convId, title, preview)` → `post({ source: "llm", key: "answer",
title, body: preview, urgency: "low", actions: [{ id: "open", label: "Open" }] })`.
A SPOKEN ask (round 8) opens no popup and skips that "answer" post: `service.voiceAnswered(...)` →
ONE `post({ source: "llm", key: "voice-<convId>", title, body: the answer's first lines, actions: open })`
("Copied" in the same toast when the answer went to the clipboard; a failed or dropped ask says why
there), and an approval a spoken turn needs → `post({ source: "llm", key: "confirm", actions: run /
deny / open, persist: false, timeoutMs: -1 })`, answered through `service.answerConfirm` like the
panel's buttons; a stale record's actions do nothing. Typed chats keep `Show` only.

## C1 — swipe (`modules/common/components/`)

`SwipeVerbCard.qml`
```
default property alias content: face.data   // the card face; card height = face's implicitHeight
property string rightVerb: "file"            // "file" | "pin" | "unpin" | "" (disabled)
property string leftVerb: "delete"           // "delete" | ""
property bool rightFliesOff: true            // pin/unpin: false -> springs back, still commits
property bool leftFliesOff: true
property real radius: 14
property color groundColor                   // the surface the well is carved into
property real commitFraction: 0.4            // of width, on release
property bool dragEnabled: true              // left-button drag == swipe
readonly property real offset                // px, + = right
readonly property bool swiping
function scrub(px)                           // the reader's cumulative displacement
function release(velocityPxPerS)             // commit or spring back
function flyOff(direction)                   // +1 / -1, programmatic
signal committed(int direction)              // at the decision (the host starts its collapse)
signal landed(int direction)                 // fly-off (or spring-back) finished
signal clicked()                             // press + release with no drag
```
The well reveals the verb glyph on the side the card uncovers (swiping right uncovers the
LEFT side, which shows `rightVerb`'s glyph). Glyphs: file = tray-arrow-down, delete =
trash-can-outline, pin = pin, unpin = pin-off (Material Design Nerd Font).

`SwipeVerbReader.qml` (fills the list area, over the rows)
```
property var rowAt: null         // function(x, y) -> SwipeVerbCard | null (reader coordinates)
property real units: 900         // wheel units to cross one card width's commitFraction
property real flingUnitsPerS: 2600
property int idleMs: 6000        // fallback lift for devices without a zero-delta event
readonly property bool active    // a horizontal gesture is latched -> host swipeGestureActive
readonly property bool holding   // committed; the rest of this gesture is swallowed
readonly property Item card      // the card this gesture drives
function gestureWheel(ev): bool  // ev = { x, y, angleDelta, pixelDelta } (reader coords);
                                 // false when no gesture is held
signal committed(Item card, int direction)
```
gestures.md applies whole: a MouseArea (NoButton, propagateComposedEvents,
`wheel.accepted = false`), axis picked when clearly ahead and latched until the zero-delta
lift, the row picked at the gesture's START, `holding` after a commit so a row sliding under
the fingers never moves, the chase never faster than the card's own animation.

## C2 — list + small parts (`modules/common/components/`)

`BoundaryClock.qml` — `readonly property double now`; `function request(atMs)` (the earliest
future request arms ONE single-shot timer; on it, `now` updates and the requests clear; every
reader re-requests its next boundary from `RelTime.format(...).nextMs`).

`UndoDrainButton.qml` — a RaisedButton that turns into Undo:
```
property string text: "Clear"; property string undoText: "Undo"
property int drainMs: 10000
property color surfaceColor           // what it stands on
readonly property bool undoing
readonly property real drain          // 1 -> 0 while undoing
function arm()                        // enter the undo state (after the host cleared)
function disarm()
signal clicked()                      // in the normal state
signal undoClicked()
signal expired()                      // the drain ran out
```
The drain shows in the button's own inset/highlight sweep (ShadowBox progress), one clock.

`ListWave.qml` + `ListWave.js` — list_animation.md as a component, over `AnimatedListRow`s:
```
property Item view                    // the Flickable (contentY, height)
property int staggerMs: 55; property int animMs: 240
readonly property bool busy
function expand(rows)                 // [AnimatedListRow] in order
function collapse(rows, done)         // done() after the last visible row left + the sweep
function swap(outRows, inRows)        // collapse then expand, one stagger step apart
```
`ListWave.js`: `bands(slots, viewTop, viewH, margin)`, `expandPlan(...)`, `collapsePlan(...)`
— the C2 agent names the plan functions and records them in `C2.md`.

## L — the engine lane (`modules/bar/gooey/*`, `GooeyGeometry.js`)

```
readonly property GooeyBody theLane
readonly property bool laneOpen
readonly property string laneOwnerId
readonly property bool laneBlocked      // placement found no room beside thePopup
readonly property string laneKeyboard   // the lane content's keyboardFocusRequest
readonly property string keyboardFocus  // the stronger of popupKeyboard and laneKeyboard
property bool laneMelt: true
property int laneGlideMs: 400
function openLane(ownerId, barId, localCenter, w, h, cornerAnim2D, component, widthFrom)
function closeLane()
```
The lane content speaks the same content contract as a primary (implicit size, gesture hold,
`gestureWheel`, `keyboardFocusRequest`, `hostRoom`); no secondary, no live resize.
Lane-only, optional: `maskCatchAll` (bool) -- while true the engine's input region also takes
the whole track (one more rect), re-laid out when it changes.

## U — host UI (main session)

`modules/notifications/*.qml` + `toast/`, `manager/`, `parts/`; `test_notifications.qml`
(`LANE=stage|popup|lane`, `INPROC=1`, `LIVE=1`); `notifications_{mockup,render,toast_probe,
manager_probe}.sh`; `tools/dev/perf/notifications_*.sh`; `docs/notifications.md`.
The owner API (for the user's assembly):
```
NotificationsBarOwner { engine; bar; barId; ownerId; anchorItem; screenName; service }
NotificationsBarButton { owner; orientation }
```
