# Notifications

## What it is

The shell is the desktop's notification server: every app's notification arrives here, shows as a toast at the top right and waits
in a manager behind the bell. It also carries the shell's own messages (timers, the battery, a failed service,
a full disk, a USB drive, an update), so everything that wants attention comes through one place with one look.

## Where it lives

- **The bell**: the `notifications` id at the end of the right island (`modules/notifications/NotificationsBarButton.qml`). A bell
  when nothing is held back, a sleeping bell (the z's) under do-not-disturb and while toasts are held (fullscreen, a screen share, the
  lock). The bell itself takes the colour of the most urgent group that arrived since the manager was last opened (no dot); the pointer
  and an open manager take it to its own hover colour (brass), which is none of the groups' colours. It RINGS (a swing about its crown,
  the clapper following late; `parts/BellPose.js`) on every new notification -- under do-not-disturb and the holds too -- and when the
  pointer comes onto it; a notification mid-ring re-strikes it. Mockup: the Bell tab's ring rows; check `tools/dev/glyph_flourish_probe.sh`.
- **The toasts**: a stack hanging from the top bar's right end (`spot`), newest nearest the bar. It is its own slot of the popup
  engine (the lane), so toasts and a popup can be out together; they make way for each other. While the bars are hidden the stack
  floats on its own window (`modules/notifications/toast/ToastPillWindow.qml`).
- **The manager**: the bell's popup, out of the right island.
- **IPC** (`quickshell ipc call notifications <verb>`, `modules/notifications/data/NotificationsIpc.qml`): `dnd on|off|toggle` (`""`
  only asks), `open`, `toggle`, `close` (the manager on the focused screen), `count` (unseen notifications),
  `hold <locked|screencast|fullscreen|idle> <true|false>`.
- No keyboard shortcut of its own.

## What you can do

**On a toast**
- Swipe it right (two fingers, or drag with the left button) to file it into the manager, left to delete it.
- Hover it to stop its countdown; the coloured shade inside the card drains away as its time runs out, a whole device pixel at a time
  (`NotificationStyle.drainStepPx`, 1: counted against the distance the shade's boundary really travels, `width + 2 x feather`; a toast so
  short that a pixel falls due faster than the 16 ms timer floor takes the fewest whole pixels the floor allows). `tools/dev/toast_drain_probe.sh`
  measures the step against the shader's pixels (`MODE=truth`), the steps (`MODE=steps`) and the frames they cost (`MODE=count`).
- Click an action button, a link in the text, or **Reply** where the app offers one (the field opens on the card).
- "+N more" at the foot of the stack opens the manager.
- A toast that takes another's place -- a click consumes one and its app posts the next, a progress toast goes as its result
  comes, a full stack files its oldest for a new one -- is a HAND-OVER: the newcomer waits until the leaving card has gone (its
  160 ms fade, or its fly-off), then its room opens as the other's closes, on one clock, so the stack's box moves once from the
  old size to the new instead of growing by the newcomer and then shrinking by the leaver. A toast that comes with nothing
  leaving opens at once, as always. `tools/dev/toast_handover_probe.sh` (pass one: the lane's height per frame; ARMs nohandover,
  noresync).
- A toast ARRIVES AT ITS PLACE. Its card stands where it will rest from the first frame and fades in there (160 ms, presence) while
  its room opens (260 ms, the box with it); it is not slid in and not uncovered by a clip of its own. Round 10 showed why: in a
  hand-over the box hardly moves, so a clip that follows the room read as a curtain coming down inside a box that stands still ("the
  new toast appears from top to bottom"). What hides the card in its first frames is only what really covers that place: the box's
  edge while the box grows, and the row next to it while that row is still moving away (the newcomer paints under it, so the
  neighbour uncovers it and the newcomer never paints over it). Leaving is unchanged, and so is every frame count: an arrival and an
  exit take the same time as before. The same probe's second pass is THE ARRIVAL CHECK: every arrival (a lone toast, into a stack of
  one and of two, the hand-overs) is filmed frame by frame and judged from the pixels (`tools/dev/toast_entry_judge.py`): the card
  stands at its place in the content, every row of it that the box and the row over it leave in view carries the same share of its
  ink at rest (a clip would leave rows with none), and it paints under that row. ARMs oldclip (the slot's clip put back), oldrows
  (the rows' clip at the stack's drawn extent), topz (an arriving row over its neighbours); `SCALE=1.25` runs the same at the shell's
  frame scale, `EDGE=bottom` on a bottom stack (cut and order only: there the engine lays the content out from the box's top and a row
  under a leaving one is carried by that one's closing room, so its place in the content is not asserted); `FILM=1 FILM_EVERY=1` and
  `tools/dev/toast_entry_sheet.py` make a labelled strip of any of it. The "+N more" foot is still uncovered from the rows' side while
  its room opens (it stands at the rows' drawn end, which moves, so it has no place of its own to fade in at).
- A toast that keeps changing (a LIVE one: the wiki's batch progress) stays a toast when the manager opens, beside it. Either
  swipe HIDES it into the manager, where its updates change it without ever toasting it again; either swipe of its entry there (the
  tray-up glyph) brings it back as a toast. It cannot be deleted or cleared; its result ("Added 30") is an ordinary notification.
  `tools/dev/notif_live_probe.sh` (ARMs retoast, manager, keep, limbo).

**In the manager**
- Groups in a fixed order -- Critical, System, Normal, Low -- one open at a time (the one that last received something opens first).
- One row per app: a second notification turns the row into a bundle with "+N more from App"; the chevron unfolds it.
- Swipe a card right to pin it (a pinned card is never dropped from the history), left to delete it (`manager.swipe`; a toast's are `toasts.swipe`); swipe a group's header to clear
  the group. **Clear all** clears everything; the same button offers **Undo** for `undoMs`.
- Type to search: the query replaces the title and every group that matches opens. Escape clears the query, then closes the manager.
- Keys: Up / Down move the highlight, Enter opens a group or acts on a card, Delete deletes, Ctrl+P pins.
- The **Do not disturb** switch in the top row; or right click the bell.
- An empty manager shows today's wiki card; a click opens it in the clock's popup.

## What it shows and where the data comes from

- **Apps**: the `org.freedesktop.Notifications` server (`modules/notifications/data/NotificationServerBridge.qml`). It takes a
  body with markup and links, actions, an app image, inline replies, a `sound` hint, and keeps live notifications across a shell
  reload. It is the only server of the session: `lares setup` says when another daemon D-Bus could start (mako's service
  file, say) is not masked, since one started while the shell is down would keep the name.
- **What holds a toast back** (`modules/notifications/data/NotificationHolds.qml`): do-not-disturb, a fullscreen window, the screen
  being shared or recorded (a portal cast or a recorder process, read by the shell's one `ScreenShareWatch`,
  `modules/common/system/`, which the idle auto layer reads too), the session being locked (told by the lock), and being away (no input for
  `idleMs`: countdowns stop). One summary toast comes when a hold ends. A critical notification breaks do-not-disturb; the sources in
  `dnd.breakthroughSources` do too.
- **An app's own window focused**: its notification is filed silently (`focusSuppress`), except kitty's.
- **History**: `~/.local/state/lares/notifications/history.json` (`modules/notifications/data/NotificationStore.qml`).
- **Sounds**: the first existing file of the urgency's list (`modules/notifications/data/NotificationSound.qml`).
- **The shell's own sources** (`modules/notifications/sources/`, one host `NotificationSources.qml`):

| Source | Says |
|---|---|
| `battery` | the charge falling to 8 % and 3 % (with a Hibernate button), a runaway drain; the charge limit reached when `limitReached` is on |
| `update` | updates waiting a while after boot (the nudge), and the update run's start, question and result while its popup is shut |
| `stocks` | the stocks' alerts and a sudden move, each with the day's graph (`StockMoveBody`; `docs/stocks.md`) |
| `screenshot` | the shot as a card that waits: Open, Edit, Copy path |
| `usb` | a removable drive: "connected" (Mount, Eject), "mounted" (Open, Unmount; kept), "can be removed"; a warning when one vanishes still mounted |
| `calendar` | an appointment `leadMin` minutes ahead (several leads, one card), an all-day one at `allDayAt` |
| `disk` | free space under `minFreeGB` / `criticalGB` on the watched mounts |
| `units` | a systemd unit that failed: Show log, Copy log |
| `thermal` | the CPU throttled by heat for a long while |

  **The drive card** (`UsbNotifier.qml`, `UsbDrives.js`, test `tools/dev/usb_notifier_probe.sh`). One card per drive, four states, and it follows what the machine says
  (the lsblk picture includes mount points), so a mount made by anything else -- yazi's `M`, udiskie -- moves it too:
  *connected* (plugged, nothing mounted: Mount + Eject; the body click is Mount), *mounted* (any partition mounted: "at <mount point>", Open + Unmount;
  the body click is Open), *can be removed* (it was mounted, nothing is now, the drive is still there: no actions, goes after `safeSec` or with the drive)
  and, after Eject, "can be removed" again (it outlives the vanished drive by `safeSec`). Mount is `udisksctl mount -b` on every filesystem of the
  drive (udisks puts them under `/run/media/<user>`, where yazi's mount plugin can unmount them with `udisksctl unmount -b`); Open runs the
  `usb.openCommand` setting (default: yazi in a kitty window, the Super+E window, `{path}` = the first mount point) DETACHED through the host
  (`NotificationSources.run(argv, { detached: true })`); xdg-open is not used anywhere in the source. At the shell's start a drive that is already
  mounted gets its mounted card (the baseline announces no plain "connected"); the mounted card is not persisted, the start posts it again.
  A whole-disk filesystem (no partition table) mounts too, but yazi's plugin cannot unmount that case (it works on partitions).

  **Kept records.** A post with `kept: true` (the mounted-drive card) is filed into the manager like any card, but only its source's withdraw takes it
  away: `remove()` answers false, clear all / clear group and the retention pass skip it. The refusal is shown with the shell's one shake
  (`modules/common/components/Shake.qml`): `SwipeVerbCard.refuse()` (a delete swipe on the card, in the manager and as a toast, springs back and
  wiggles and commits nothing), the manager's Delete key shakes the selected row, and clear all / clear group shake each kept row left.

  Other modules post through the same service: `clock` (timers, alarms), `launcher` (a script that failed), `llm`, `network`,
  `bluetooth`, `auth` (the password card, [auth.md](auth.md)).

## Settings

`~/.config/quickshell/config/notifications.jsonc`, re-read when it is saved (`modules/notifications/data/NotificationConfig.qml`; the rules
in `NotifyPolicy.js` and `sources/SourceSettings.js`). The commented example `.examples/notifications.jsonc` is the full list, and
every value in it is the default.

| Key | Meaning | Default |
|---|---|---|
| `spot` | where the toasts appear: a corner, or `{ "bar", "along" }` | `top-right` |
| `screen` | the display they come on: `"focused"`, or a connector's name (the focused one while it is not there; a stack that is out moves with it) | `"focused"` |
| `timeouts` | per urgency (`low`, `normal`, `critical`), and the clamp on an app's own (`clampMin`, `clampMax`); -1 is sticky | 4 s, 8 s, sticky; 3-60 s |
| `toasts` | `max` at once, flood control (`floodCount` in `floodWindowMs`), `hoverResumeMinMs`; `swipe` `right` / `left`: `"file"` or `"delete"` | 5; 3 in 10 s; 2 s; file / delete |
| `manager` | `openGroup` (`"latest"`, `"first"`, `"none"` or a group); `swipe` `right` / `left`: `"pin"` or `"delete"` | latest; pin / delete |
| `clickFocus` | a click on a card with no action of its own brings its app's window to the front | true |
| `bell` | `ring`: `"always"`, `"notDnd"`, `"never"` | always |
| `retention` | history kept: `count` newest, none older than `days` (pinned never dropped) | 200, 7 |
| `undoMs` | how long Undo is offered after a clear | 10000 |
| `idleMs` | no input this long counts as away | 60000 |
| `sounds` | per urgency, a list of files; the first that exists plays | `~/.local/share/sounds/notification.mp3`, ... |
| `soundVolume` | 0 .. 1; -1 the stream's own level | -1 |
| `dnd` | `remember` (across a restart), `hours` (`["22:30-07:00"]`: switched on and off by the clock, yours in between), `summary` (after a hold), `holdApps` (window classes that hold toasts while focused), `breakthroughSources`, `holdFullscreen`, `holdScreencast` | true, none, true, none; `clock`, `auth`; true, true |
| `apps` | per app (desktop entry or name): `mute`, `urgency`, `group`, `timeoutMs`, `sound`, `breakDnd`, `drop`, `history`, `focusSuppress` | kitty not focus-suppressed; the network and Bluetooth applets dropped |
| `sources` | per shell source: the same rule keys (a `sound` is heard even where the source posts none), `enabled`, and the source's own keys -- calendar's `leadMin` (one or several), `allDayAt`, `calendars`; usb's `openAfterMount` | see the example |

The toasts' and the manager's look and motion are tuned in `mockups/notifications.qml` (run it through `tools/dev/notifications_mockup.sh`);
Save writes `modules/notifications/parts/NotificationStyle.qml`.

## How it is built

| File or directory | Role |
|---|---|
| `modules/notifications/data/NotificationService.qml` | the one service: receive, file, pin, delete, clear, undo, do-not-disturb |
| `modules/notifications/data/NotificationServerBridge.qml` | the D-Bus server |
| `modules/notifications/data/NotificationStore.qml`, `NotificationState.qml` | the history and the module's own state on disk |
| `modules/notifications/data/ToastScheduler.qml`, `NotificationHolds.qml` | which notifications are toasts now and for how long; what holds them |
| `modules/notifications/data/NotifyPolicy.js`, `NotificationConfig.qml`, `NotificationSound.qml`, `NotifyMarkup.js` | the rules, the config, the sound, the body's markup |
| `modules/notifications/NotificationsBarOwner.qml`, `NotificationsBarButton.qml` | the module on one screen; the bell |
| `modules/notifications/NotificationToast.qml`, `toast/` | the toast stack, its rows, its foot and its floating window |
| `modules/notifications/NotificationManagerPopup.qml`, `manager/` | the manager: header, groups, bundles, rows |
| `modules/notifications/parts/` | the card both use (`NotificationCard.qml`), its buttons, icon, picture band, style |
| `modules/notifications/sources/` | the shell's own sources |
| `modules/notifications/SwipeVerbCard.qml`, `SwipeVerbReader.qml`, `ListWave.qml` | a card swiped to a verb; the list's staggered motion |

Shared: `ScreenShareWatch` (the screen share, handed in by ShellServices), `ShadowBox` (the carved card), `UndoDrainButton` (Clear all / Undo), `BoundaryClock` + `RelTime.js` ("3 min"),
`SideFade` / `SideCut` (the list's side clip), `RowFlight` (a pinned card flying to its place), `DesktopNotifier` (other modules'
way to post).

## Limits

- No images inside the body text and no icons on action buttons from apps (the server says so in its capabilities).
- Only one notification server per session: while another daemon holds the name, the shell cannot take it.
- The toasts are on one screen at a time: the focused one when the first toast of a stack arrives, or the one `screen` names. Opening the manager folds
  them away (they are rows in it already).

## How to change it

- **Timeouts, how many toasts, retention, sounds, do-not-disturb**: edit `~/.config/quickshell/config/notifications.jsonc` and save; it
  applies at once. Then `tools/dev/config_loaders_probe.sh`.
- **Silence or drop one app**: an entry under `apps` (`"mute": true` keeps it in the manager, `"drop": true` keeps nothing).
- **Turn a shell source off or tune it**: its block under `sources` (`"enabled": false`).
- **The cards' look and motion**: `tools/dev/notifications_mockup.sh run`, tune, Save; then `tools/dev/notifications_mockup.sh` (load and
  report every warning). Anything that talks to the notification bus runs under `tools/dev/notifications_bus.sh` (a private bus).

Contract (for developers): [contracts/notifications.md](contracts/notifications.md).
