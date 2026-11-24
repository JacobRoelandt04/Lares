# Shell assembly -- CONTRACT (wave 1)

(The plans, stage-0 facts and round notes this contract names beside it are no longer in `docs/`: they are in git history,
`git log --all -- 'docs/agent_added_files_and_folders/shell_progress/'`.)
(The gates, probes and fixtures this contract names without a directory went with the cleanup: tag `pre-cleanup` has them. What a change is proved with now is in `tools/dev/`, [tools.md](../tools.md).)

The names every stream relies on. Frozen when the wave-1 streams start; after that only the
orchestrator changes it -- a stream that needs a change asks in its report, never edits another
stream's files. Everything here is BACKWARDS COMPATIBLE: a member added to an existing owner
defaults to today's behaviour, so every module mockup and probe keeps working unchanged.

## 1. Streams and file ownership (wave 1)

| stream | owns (and its modules' `test_*.qml` mockups + runners) |
|---|---|
| F1 trial tool (DONE, merged 30f60463) | `tools/shell/*`, `lares_shell_*`, `tools/dev/fixtures/lares/` |
| F2 frame | `shell.qml`, `shell.example.jsonc`, `modules/shell/*`, `modules/idle/*`, `modules/bar/audio/*`, `test_shell.qml`, `shell_*` (not `shell_s0_*`), `tools/dev/perf/shell_idle.sh` |
| E1 engine (DONE, merged 3456d3a4) | `modules/bar/gooey/*`, `modules/bar/gooey/GooeyField.qml`, `GooeyGeometry.js`, the gooey runners (`gooey_*`, `test_gooey_*.qml`) |
| E2 common (DONE, merged f7c8caec) | `modules/common/theme/*`, `modules/common/components/ThemeCrossfade.qml`, `modules/common/system/*`, `modules/bar/workspaces/*`, `test_workspaces*.qml`, `test_fullscreen_watch_probe.qml`, their runners |
| M1 | `modules/clock/*`, `modules/stocks/*`, `modules/silicon/*` (except `data/SiliconBatteryAdapter.qml`), `modules/notes/*`, their mockups + runners |
| M2 | `modules/launcher/*`, `modules/clipboard/*`, `modules/osd/*`, `modules/notifications/*`, `modules/auth/*`, their mockups + runners |
| M3 | `modules/aerial/*` (the network, rebuilt as aerial in round 10: its owner, pill, data and popup; `modules/network/*` and `modules/bar/network/*` are retired), `modules/windowtray/*`, their mockups + runners |
| N1 system update (DONE, merged e7ab91a3) | `modules/bar/system_update/*` (new), `modules/common/components/SystemUpdate*.qml` + `SystemUpdateWork.js`, `test_system_update_popup.qml` + its runners |
| N2 LLM (DONE, merged 6df08d3c) | `modules/bar/llm/*` (new), `modules/common/components/Llm*.qml`, `test_llm_*.qml` + runners |
| N3 player, weather, adapter (DONE, merged cfa85025) | `modules/bar/player/*` (new), `modules/weather/*`, `modules/bar/player/components/AudioPlayerPopup.qml` + `Player*.qml` + `MpdService.qml` (its tick, 0b fact 11c), `modules/silicon/data/SiliconBatteryAdapter.qml` (new), `test_audio_player.qml`, `test_weather_popup.qml` + runners |
| S settings pipeline | `modules/common/mockup/*`, `tools/dev/mockup_save_defaults.py`, `tools/dev/mockup_wiring_check.py`, `tools/dev/mockup_panel_test.sh`, `mockup_footer_bytes.sh`, `tools/dev/mockup_promote.py` (new) |

A file not listed is nobody's: ask. `modules/battery/` is untouched (the user's standing rule).

## 2. Fixed names

- Entry `shell.qml` (repo root), started `quickshell -n -p <abs>/shell.qml`.
- Env `SHELL_SERVICES=live|mock` (default live). Mock = every service is its module's mock twin and
  every HOME path (notes root, stores, configs) points into `$XDG_STATE_HOME/lares-shell-mock/`.
- Ready line (console.log, once): `LARES ready screens=<n>`.
- IPC target `shell`: `ping()` -> `"ok"`; `bars(on: string)` ("1"/"0"/"toggle").
- Layer: every bar window `WlrLayershell.layer: Top`, namespace `lares-bar`, `exclusionMode: Ignore`.
- barIds: islands `topL` `topC` `topR`, continuous `top`; slim `right` `bottom` `left`.
- GlobalShortcuts (appid `lares`), registered ONCE by `ShortcutRouter`: `launcher`, `clipboard`, `picker`,
  `notes`, `bars` (-> the focused screen's launcher `shortcutPressed()`, clipboard / picker `toggle()` (their owners already
  grab), notes `shortcutPressed()`: section 10's keyboard map); the OSD's 15 by one `OsdShortcuts`.
- Owner keys (ShellFrame's `owners` map, ShellServices' routing): `clock`, `stocks`, `silicon`, `bridge`, `panorama` (the machine popup: Displays and Presets tabs, one PresetsService handed in),
  `notes`, `launcher`, `clipboard`, `picker`, `osd`, `notifications`, `aerial`, `windowtray`, `weather`,
  `player`, `llm`, `update`, `power`, `idle`.

## 3. ShellServices (F2) -- once per shell

Holds every once-per-shell service (PLAN.md's layout table) under these ids, built live or mock:
`notifications`, `notifyClock`, `auth` (broker), `howdy`, `polkit`, `osd`, `osdStyle`, `pipewire`,
`mpd`, `aerial` (the AerialService or its mock: Wi-Fi, cable, hotspot, Bluetooth, the tunnel; it replaced `network` and `bluetooth`), `silicon`, `siliconBattery`, `calendar`, `timers`, `wiki`,
`screentime`, `weather`, `stocks`, `launcher`, `iconStore`, `appLookup`, `clipboard`, `picker`, `bridge`, `panorama` (PanoramaService, or PanoramaMock in a mock shell), `drm` (the ONE DrmWatch: silicon and
Panorama read it), `notes`,
`llm` (N2's bundle), `updates` (N1's service), `tray`, `windowtrayConfig`, `focus` (FocusedScreen),
`idle` (IdleService).

Cross-screen glue (F2 implements, the owners only expose what it reads):
- `registerScreen(name, frame)` / `unregisterScreen(name)`; `frame.owners[key]` is that screen's owner.
- `ownerOn(name, key)`; `focusedOwner(key)` = the owner on `focus.name`, else the first live screen's.
- Aggregation: for each row below, the service property = OR over every screen's
  `owner.sharedFlags[flag]`; recomputed on any change and on register/unregister.
- Routing: the unaddressed request signals below go to `focusedOwner(key)` (Panorama's `openRequested(name)`, the never-seen toast's
  Arrange…, goes to the focused screen's `panorama.openWith(name)`). Escape: when no popup takes it, Panorama's keep toast does
  (`panorama.keepPrompt.waiting` -> `revert()`).
- Once-per-shell helpers formerly inside owners: silicon's `SiliconMuxWatcher` (no owner: the keep prompt is a toast
  through the notification service) and `BlockedAppNotifier`; the DesktopNotifiers of stocks alerts,
  launcher script failures, the wiki and the timers; `OsdShortcuts`, `OsdIpc`, `AuthOwner`.

| service.property written by the host | from owner key . sharedFlags flag |
|---|---|
| `wiki.popupOpen` | `clock.wikiPopupOpen` |
| `timers.attended` | `clock.timersAttended` |
| `stocks.popupOpen` | `stocks.popupOpen` |
| `silicon.popupOpen` | `silicon.popupOpen` |
| `bridge.popupOpen` | `bridge.popupOpen` |
| `panorama.popupOpen` | `panorama.popupOpen` |
| `notifications.managerOpen` | `notifications.managerOpen` |
| `aerial.popupOpen` | `aerial.aerialPopupOpen` |
| `aerial.ratesWatched` (when the service has it: the mock has no beat) | `aerial.aerialRatesWatch` |
| `clipboard.hostOpen` | `clipboard.hostOpen` OR `picker.hostOpen` (the picker pastes through the clipboard service; `picker.forwardHostOpen` is false, the host writes the clipboard service once) |
| `weather.popupOpen` | `weather.popupOpen` |
| `updates.popupOpen` | `update.popupOpen` |
| `llm.attended` (LlmAttention) | `llm.attended` |

| request (signal) | routed to |
|---|---|
| `wiki.openRequested(tab)` | `focusedOwner("clock").openWiki(tab)` |
| `stocks.alertOpenRequested(sym)` | `focusedOwner("stocks").openSymbol(sym)` |
| `llm.attention.showRequested()` / `openConversation(id)` | `focusedOwner("llm").open()` / `.openConversation(id)` |
| silicon MUX keep prompt due at login | none (round 11): a toast through the notification service, no popup (the watcher's `MuxKeepPrompt`) |
| `ShortcutRouter` launcher / clipboard / picker / notes / bars | `focusedOwner("launcher").shortcutPressed()` / `clipboard.toggle()` / `picker.toggle()` / `notes.shortcutPressed()` (a key-opened notes popup: section 10) / the frames' bars toggle |
| `notifications.openManagerRequested(screenName)` | unchanged: already screen-addressed, the owner keeps its own Connections |

## 4. The owner contract in shell-hosted mode (M1, M2, M3; the new owners follow it natively)

Every existing owner gains `property bool shellHosted: false`. When TRUE the owner:
1. builds NO service of its own -- every service is injected; a null one means the feature is
   absent, never a self-built live service (no `Loader` that would start one);
2. registers NO GlobalShortcut (`shortcutEnabled` is also set false by the host);
3. writes NO property of a SERVICE (its Bindings onto services carry `when: !owner.shellHosted &&
   ...`); Bindings onto its OWN button or its screen's Workspaces stay;
4. connects to NO unaddressed request signal of a service (the host routes them -- section 3);
5. hosts NO once-per-shell watcher or notifier (section 3 lists them);
6. exposes `readonly property var sharedFlags` -- a plain object with the values it would have
   written (keys as in section 3), and keeps `popupMine`, `toggle()`, `open()`, `close()`.
With `shellHosted: false` (the default) the owner is byte-for-byte today's.

| owner (stream) | members added | `sharedFlags` |
|---|---|---|
| `ClockBarOwner` (M1) | `shellHosted` | `{ wikiPopupOpen, timersAttended }` |
| `ClockBarButton` (M1) | `fontFamily` (default today's look), fixed digit slots; fits E2's Workspaces clock slot | -- |
| `StocksBarOwner` (M1) | `shellHosted` | `{ popupOpen }` |
| `SiliconBarOwner` (M1) | `shellHosted`, `prewarmArmed: bool` (default = `ownsService`, the host sets true per window) | `{ popupOpen }` |
| `NotesBarOwner` (M1) | `shellHosted`, `store` (an injected NotesStore; null = build its own, today's) | `{}` (the store's own state is per store, once) |
| `SecondaryMemory` users (M1 stocks) | one memory per owner, in memory for the session (no file since 2026-11-12) | -- |
| `LauncherBarOwner` (M2) | `shellHosted`, `service` + `iconStore` injectable (null = build its own); the atlas page Images stay per window | `{}` |
| `ClipboardBarOwner` (M2) | `shellHosted` (`style` is passed by the host) | `{ hostOpen }` |
| `PickerBarOwner` (round 8) | `shellHosted`, `service` = the shell's one `PickerService` (`live`, `clipboard` injected; `style` by the host); writes only `service.origin`, once, by opening | `{ hostOpen }` |
| `BridgeBarOwner` (2026-11-16) | `shellHosted`, `service` = the shell's one `BridgeService` (`live`, `notifier`, `runner`, `clipboard` injected by the host); writes nothing of it; not hosted and with none handed in it runs its own, never live | `{ popupOpen }` |
| `OsdOwner` (M2) | `active: bool` (default true; the host sets true only on the focused screen); spot / fullscreenMode / timings bound by the host from `osd.json` | -- |
| `NotificationsBarOwner` (M2) | `shellHosted` | `{ managerOpen }` |
| `AuthOwner` (M2) | none -- ONE instance; the host binds `screenName` to `focus.name` | -- |
| `AerialBarOwner` (M3, round 10) | `shellHosted`, `service` = the shell's one `AerialService` (`live` by the host; null = the feature is absent: the owner never builds one, hosted or not); writes nothing of it; one popup for any click on its pill | `{ aerialPopupOpen, aerialRatesWatch }` |
| `WindowTrayOwner` (M3) | `shellHosted` (no service writes today; the flag is for symmetry) | `{}` |

Keyboard: every popup that types or reads keys declares `keyboardFocusRequest` (clock: "onDemand";
aerial: the detail panels' fields (the password field: stream P); LLM, system update: "onDemand" with
the exclusive pulse on open; the player's Space via HoverArm). The notifications manager, when
"exclusive", declares `maskCatchAll: true` + `function outsidePress()` so a click elsewhere
releases it. HyprlandFocusGrab users (launcher, clipboard, windowtray) get `grabWindows: [<this
screen's window>]` from the host.

## 5. New owners and services (N1, N2, N3)

Every new owner: `engine`, `bar`, `barId`, `ownerId`, `anchorItem` (the button, or an OutletAnchor),
`readonly popupMine`, `sharedFlags`, `toggle()`, `open()`, `close()`, opening with
`engine.open(ownerId, barId, anchorItem.mapToItem(bar, w/2, h/2).x, null, null, false, component, 1)`.

| file (stream) | members |
|---|---|
| `modules/bar/system_update/SystemUpdateService.qml` (N1, MERGED e7ab91a3) | `live` (default FALSE: startUpdate() replays `replayLog` through the real backend/parser via `tools/system_update/replay_yay_log.sh`, mock `avail`, no auto-reattach; the live shell sets `live: true`), `autoStart`, `refreshAfterRun`, `mockAvailable` (follows `!live`), `mockSpec`, `pollIntervalMs` (15 min), `staleRefreshMs` (5 min), `replayLog` / `replayDelay` / `replayScript`, `runScript` / `runCommand`, `stateDir` (`$XDG_STATE_HOME/lares/system-update`; marker `last-run.json`, `last-success.json`) / `markerPath` / `successPath` / `askpassPath` (`$XDG_RUNTIME_DIR/lares-askpass-update.sock`) / `logDir` -- paths are read ONCE at creation, a mock host sets them in the declaration --, `askpassBroker` (default `AuthBus.broker`), `askpassRequireSudoParent`; out: `backend`, `parser`, `logger`, `avail`, `recorder`, `askpassServer`, `askpassSource` (alive for the whole shell), `running`, `lastSuccessAtMs`, `staleDays`; `popupOpen` (host-written: the OR of the screens' `sharedFlags.popupOpen`; an open refreshes stale numbers); `startUpdate()`, `startReplay()`, `awaitRun(runId)`, `reattachIfRunning()`, `refreshIfStale()`, `registerPopup(item)` / `unregisterPopup(item)` (the recorder follows the newest live popup). Declare it under a Scope or an Item, never `createObject` it without a parent item |
| `modules/bar/system_update/SystemUpdateBarOwner.qml` (N1, MERGED) | the owner (`ownerId: "update"`); `updates` (the service); `verbosityMode` memory; `sharedFlags { popupOpen }`; `fontFamily` (Audiowide), `orientation`; `button` (alias of the themed SystemUpdateIcon, 32 px well, fits a 40 px bar; `staleDays` fed by the owner). Popup inputs it hands on: `askpassServer`, `keyboardFocusRequest`, `grabKeyboard`, `pulseKeyboard()` |
| `modules/bar/llm/LlmServices.qml` (N2, MERGED 6df08d3c) | `live` (default FALSE; mock backend), `storePath` (follows `live`: conversations.json / mock_conversations.json beside it), `model`, `baseUrl`, `protocol`, `broker`, `howdyMode`, `howdyTimeoutMs`; out `backend`, `store`, `tools`, `attention`, `service` (built with `probeGpuAtStart: false`: no nvidia-smi until a picker / a finished answer reads the card); `attended` (host-written: OR of the screens' `owners.llm.sharedFlags.attended`) |
| `modules/bar/llm/LlmBarOwner.qml` (N2, MERGED) | the owner (`ownerId: "llm"`, `barId: "left"`, `anchorItem` = an OutletAnchor inside the LEFT bar near its top end: bar-local x = length - 24); `llm` (the bundle); `fontFamily` / `bodyFontFamily` / `monoFamily` (Audiowide / Exo 2 / Consolas), `attachDir`, `portalHelper` (tools/notes/portal_pick.py), `openUrl`; `openConversation(id)`; one turn after its popup closes (or an answer ends with the chat shut) it prunes an empty chat and releases the model unless another screen's chat popup is up (`llm.attended`). No shortcut, no grabWindows. Route `llm.attention.showRequested()` -> the focused screen's `open()`, `openConversation(id)` likewise |
| `modules/weather/WeatherBarOwner.qml` (N3, MERGED cfa85025) | the owner (`ownerId: "weather"`; opens only with a `service`); `service`; memory `viewMode`, `stripView`, `listView` (the popup opens ON them at rest); `detailSide` ("far"), `fontFamily`, `renderScale`; `shown` (host: false while the bars are hidden); out `popupMine`, `popupPresent`, `backdropRunning` (true only while the popup is on screen, `shown`, and its window visible), `sharedFlags { popupOpen }` |
| `modules/bar/player/PlayerBarOwner.qml` (N3, MERGED) | the owner (`ownerId: "player"`; opens only with a `player`); `player` (MpdService or PlayerMockRun); memory `viewMode` / `browseOpen` / `browsePanel`; `fontFamily`, `levelTapEnabled` (default true); `sharedFlags: {}`. The popup asks for the keyboard through HoverArm (Exclusive only while the pointer has moved onto it) and holds the player's elapsed clock (`PlayerTickHold`) for as long as it exists |
| `modules/silicon/data/SiliconBatteryAdapter.qml` (N3, MERGED) | an Item (declare it under an Item/Scope); `silicon` in; out: `percent`, `status`, `isCharging`, `isDischarging`, `isFull` (includes held at the charge limit), `powerNowW` (magnitude), `estimatedTimeSec`, `signal eventLowCharge`, `signal eventFullyCharged`, `signal eventChargingStarted`, `signal eventChargingStopped` -- an event is held until silicon has published the reading it announces (<= 250 ms). No sysfs read of its own |
| `modules/common/components/MpdService.qml` (N3, MERGED) | + `holdTick(item)` / `releaseTick(item)`, `tickHolds`, `ticking`: the elapsed clock's FrameAnimation runs only while `playing` AND held; `PlayerTickHold { player; active }` is the holder object (the player popup holds it; the OSD's media card and the lock band later) |

## 6. Common (E2, MERGED f7c8caec; `E2.md` has the detail)

- `modules/common/system/FocusedScreen.qml` (import `modules/common/system`): `live` (default FALSE = a fake
  driven by `setMonitors` / `addMonitor` / `removeMonitor` / `setFocused` / `setActiveWorkspace` /
  `setFullscreen`, through the same state as the live path), `readonly name` (focused monitor, "" unknown),
  `readonly monitors` ([{ id, name, focused, activeWorkspaceId, x, y, width, height, scale }]), `readonly
  fullscreen`, `activeWorkspaceOf(name)` (-1 unknown; "" = the focused monitor's), `signal changed()`. Live:
  seeded by one `hyprctl -j monitors; workspaces` read, then socket2. ONE per shell (ShellServices); mock mode
  feeds it from `Quickshell.screens`. It does not carry the special workspace.
- `FullscreenWatch`: optional `focusSource` (NOT `focus`: `Item.focus` is FINAL); with one it answers from it
  and builds no Hyprland reader of its own; without, today's behaviour.
- `Theme`: `registerHost(item)` / `unregisterHost(item)` / `hostReady(item)`; ThemeCrossfade registers itself;
  a switch commits once EVERY registered host has captured or declined (a host whose window is not visible
  declines; 120 ms fallback); `crossfadeHost` stays readable. One ThemeCrossfade per WINDOW with themed content
  (each screen's bar window, OsdPillWindow, AuthPillWindow: `Item { id: body; anchors.fill: parent }` around
  the content and a sibling `ThemeCrossfade { target: body; anchors.fill: body }`).
- `Workspaces`: `focusSource` (FocusedScreen), `screenName` (this bar's monitor; "" follows the focused one);
  the ball sits on `focusSource.activeWorkspaceOf(screenName)`, snapped at login; `focusWorkspace(id)` = the
  click (monitor focus only when this bar's monitor is not focused -- it warps the pointer -- then
  `hl.dsp.focus({ workspace = N })`); `dispatcher` (a probe's seam); `readonly property rect clockSlot` and
  `clockText: ""`. The FITTED clock slot is 64 x 18 px at every scale: `trackSeparation: (10 + 5 * S) / S`,
  `clockSize: 64 / S`, `clockCross: 18 / S`, `width: 2 * pitch + 64 + 100 * S`; the slot is
  `rect(width / 2 - 32, 11, 64, 18)` in Workspaces' coordinates. The scale S (0.6 / 0.75 / 0.9) is the user's
  pick from the wave-1 sheet.

## 7. Engine (E1)

- `GooeyBar.inputMask: bool` (default true): false keeps the bar out of the input mask (the slim bars).
- `GooeyEdgeReservers.screen` (a bare host's; the shell's reserve is `HyprReserve`, the output's own `reserved_area`, perf phase 2).
- Budget guard: a lane or OSD placement that would exceed `GooeyField.maxBodies` is blocked for
  budget (the OSD folds first, then the lane) and re-placed when a body frees. Readouts for probes:
  `engine.osdBlockedReason`, `engine.laneBlockedReason` ("" / "room" / "budget").

## 8. Settings pipeline (S) and the trial tool (F1)

- After a successful Save that wrote implementation files, the mockup runs `<repo>/tools/shell/lares
  apply --commit "<module>" <files...>`: it commits exactly those files (`<NAME> - tuning: <module>`, NAME the first word of git's user.name in capitals),
  then: a trial running -> `restart`; a deployed shell (after cutover) -> `deploy HEAD` + restart;
  nothing running -> nothing. F1 implements `apply` (MERGED 30f60463); S calls it. Files are absolute or
  relative to the REPO root. Exit: 0 done (also nothing changed: no commit, no restart), 1 refused or failed
  (`.qmlls.ini`, a directory, a path outside the repo), 2 usage, 4 committed but the restart is refused while a package
  transaction runs (3, "a deployed marker is present, redeploy not built", went with the turnover: `apply` redeploys now). Anything else staged or untracked is left alone; the commit has no trailer.
- Save never writes from a sandbox copy (MOCKUP_REPO rules) and never touches a binding, a sentinel,
  a themed or a file-backed row (PLAN.md, stream S).

## 9. Gates every stream adds or keeps

Each stream: its new runners (armed once), the mockups/probes of every module it touched (green as
at stage 0's baseline), qmllint + smoke. The orchestrator runs, after the merge and alone: the gooey
chain, `tools/dev/perf/*`, the shell probe in `tools/dev/lock_env.sh`, the renders, the service census.

## 10. What stage 0 changed (0.md is the index; 0a.md / 0b.md the measurements)

- **Dispatch forms (Lua; `Hyprland.dispatch(x)` is `hl.dispatch(x)`).** Workspace:
  `hl.dsp.focus({ workspace = N })`. Monitor: `hl.dsp.focus({ monitor = "NAME" })` -- it WARPS the pointer to
  that monitor's centre, so send it only when `Hyprland.focusedMonitor` is not already the target. Window:
  `hl.dsp.focus({ window = "address:0x..." })` -- switches workspace and warps the pointer onto the window.
  Start a program as the compositor's child: `hyprctl dispatch 'hl.dsp.exec_cmd("...")'`. A Lua warning
  exits `hyprctl` 0 (read the text), an error 7.
- **Keyboard map.** A popup opened by a CLICK on the bar may use the 120 ms pulse or plain OnDemand (the
  pointer rests on the layer: the whole bar window is one layer surface, toasts and popups included). A popup
  opened by a KEY or from outside the shell (Alt+Space, Alt+V, Alt+Period, Alt+N, the manager by key / IPC) has no pointer
  on it: it takes a `HyprlandFocusGrab` on the host's `grabWindows` (keys whatever the mode, closes on an
  outside click, the click is not delivered) or holds Exclusive for as long as it is open with its own
  outside-click dismissal (`maskCatchAll` + `outsidePress`; under Exclusive no window receives any pointer).
  ShortcutRouter therefore calls launcher `shortcutPressed()`, clipboard `toggle()` (ClipboardBarOwner already
  holds a HyprlandFocusGrab) and NOTES `shortcutPressed()` (new in NotesBarOwner: toggle as a key-opened popup,
  keyboard by a grab on `grabWindows`); notes' `toggle()` stays the click path (the pulse). The compositor's view of a layer's
  keyboard mode is `hl.get_layers()[i].interactivity` (0 none / 1 exclusive / 2 on-demand), not
  `hyprctl -j layers`.
- **Layer fade.** Every `lares-bar` surface fades ~0.5 s in and out unless
  `hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })`: the
  trial tool installs it by eval (and re-installs it on socket2 `configreloaded`, which drops runtime binds,
  layer rules and handlers); `layerrules.lua` at cutover. The OSD and auth pills are surfaces of their own and
  take the same rule (`lares_osd_pill_noanim` `^osd-pill$`, `lares_auth_pill_noanim` `^auth-pill$`; FX, 3ca96615).
- **Focus source.** Screens map to monitors by NAME. `FocusedScreen` seeds from `hyprctl -j monitors` (the
  real session showed null focus properties at start on 2026-10-13; the nested one did not), expects
  `Quickshell.screens` ~0.5 s after `monitoradded` / `monitorremoved`, `focusedWorkspace == null` ~0.5 s after
  an unplug, and a focus move to Hyprland's first monitor when ANY output is removed.
- **Idle.** One `IdleInhibitor` per screen's bar window, all on one flag; toggle `enabled` false -> true after
  any hide / show of a window (a re-shown window has lost its inhibitor); release = idle one full timeout later.
- **Crash handler.** The supervisor runs the shell with `QS_DISABLE_CRASH_HANDLER=1`, reads the exit status
  (255 = does not load OR crashed within 10 s; 139 / 134 = crashed), identifies the shell with `quickshell list
  --path --json`, stops it with `quickshell kill --pid` then SIGTERM. `tools/dev/sandbox.sh` runs every probe with
  the handler off.
- **Idle cost.** An offscreen run cannot see a FrameAnimation wake the windows: the idle gate counts presented
  frames in `tools/dev/lock_env.sh` too. `MpdService`'s tick runs only while a holder shows elapsed time (N3);
  `LlmService` touches the GPU only after the chat's first open (N2).
- **Two quickshells, one root.** The trial tool moves the repo root's `.qmlls.ini` aside for the trial
  (`trial off` puts the same link back): nothing in the shell may depend on QML tooling files.

## 11. The lock in the assembly (stream LS, lock-ls)

The lockscreen (modules/lockscreen: LockOwner, LockPopup; the lock process `lock/shell.qml` under `tools/lockscreen/lares-lock`) is mounted in
the assembly. The lock is a SEPARATE process that owns the keyboard, the password and the session lock; the shell only draws its popup in
the real bar's popup slot (it is the socket SERVER, contracts/lockscreen.md section 3) and gets out of its way.

- **`ShellServices.lock`** (alias of ONE `LockOwner`) and **`ShellServices.locale`** (a `LocaleConfig`: `locale.json` in the shell dir, else
  the example). Inputs: `battery` = the SiliconBatteryAdapter (never a BatteryData: the census forbids it), `weather`, `updates` =
  `updatesService.avail`, `screentime`, `mpd`, `wikiService`, `locale`; each may be null (its cell is absent). `greetingName` is the
  account's first name (`getent`), "Mock" in a mock. Census: `lock: LockOwner`, `locale: LocaleConfig`.
- **The socket.** `SHELL_LOCK=live|mock` (default: the services' mode). `live` is the lock process's path
  (`<XDG_RUNTIME_DIR>/lares-lock/<WAYLAND_DISPLAY>.sock`); `mock` listens NOWHERE (`LockOwner.listen: false`), so a windowed mock shell
  on the desktop never takes over a real lock's socket (a private mock socket, the first version, met the last run's stale file and logged
  "Deleted existing file ... to create socket", which failed the log-clean gates). The lock gate runs MOCK services on the
  REAL path (`SHELL_LOCK=live`) in its own nested compositor.
- **What `lock.locked` does** (true from the lock's first state until its retract is over, and past a vanished lock for as long as its
  supervisor holds the session, below):
  - `notifications.holds.locked` is written by a `Binding` (ShellServices, beside the aggregation's): a toast is held and a summary
    ("N notifications while the screen was locked") is filed at the end; the clipboard follows the same holds and drops its sealed copies
    (`ClipboardService`, and `ClipboardMock` since this stream). The hypridle hook's `notifications hold locked <bool>` may still write the
    property; the Binding survives a plain assignment and owns the value from the lock's own word.
  - every bar window (`ShellScreen`): keyboard mode None and an EMPTY input region (`mask: noInput`), whatever the engine asks for or its
    mask holds -- the lock process owns both. The gate makes the lock's popup ask for the exclusive keyboard and makes the bars' layer
    interactive above the lock (`above_lock = 2`), and the window still takes neither.
  - the idle inhibitor (the idle reel's "normal" / "soft": one `IdleInhibitor` per bar window, `ShellScreen`) HOLDS THROUGH THE LOCK (the user's decision of 2026-10-30, after
    the machine suspended on the lock under coffee: "holds fully": no dim, no blank, no suspend; until then it was released while locked). MEASURED (`shell_lock_idle_spike.sh`,
    the env's Hyprland; L9 of `shell_lock_probe.sh`): an inhibitor held by a `lares-bar` layer over the session lock is COUNTED, so hypridle's plain listeners stay quiet. The lid is hard mode's.
  - the bars are UP: `ShellServices.barsUp = barsShown || lock.locked`; the frames follow `barsUp` (`ShellFrame.barsShown`), `barsShown`
    stays what the toggle asked. A toggle made while locked changes nothing visible and closes nothing (`ShellFrame.closeAll` is a no-op
    while locked); when the lock lets go the bars go back to the toggle's state and, if it is "hidden", close what is open.
- **Registration.** `ShellFrame` registers each screen with the one owner (`lock.register(screen, engine, frame.barOf("clock"),
  frame.barIdOf("clock"), clockButton)`: the popup hangs from the clock's island at the button's centre) once the frame has a size, again
  when the clock's island changes (islands <-> continuous, the clock moved to another zone), and unregisters it on destruction.
- **LockOwner in a scaled shell.** `rects()` / `targetRects()` map BOTH corners to the window (`inWindow`): the frame is drawn inside a
  `ScaleRoot` (configured scale over the window's ratio) and a rect's size scales too. The hints carry every bar of the screen that has an
  area (the islands and the slim bars, the clock's first) and the popup. The popup's `renderScale` is the screen's engine's
  (`engine.renderScale`: device px per content px), not the attached `Screen`'s integer ratio.
- **The orphan hold.** A lock that vanishes with no `unlocking` and no `bye` (crash: the supervisor relaunches it once, then hands the
  session to hyprlock) leaves the popup up for `orphanMs` (6 s) and `locked` up until `orphanMs` has passed AND the supervisor has let go of
  its flock `$XDG_RUNTIME_DIR/lares-lock.lock` (it holds it for the whole of the Lares lock, its relaunch and the hyprlock fallback), asked once a
  second and only while orphaned. The question is read from the kernel's table, which takes nothing: `/proc/locks` has a FLOCK line whose
  `MAJ:MIN:INO` is the file's (`stat -c '%Hd %Ld %i'`, `%02x:%02x:%d`). NEVER `flock -n <file> true`: it takes the lock for an instant and a
  lock that starts then (hypridle's before-sleep) finds it held, exits 0 and never locks. LockOwner keeps the check inline (a `sh -c` of a few
  lines; it asks `lares-lock.lock` and, until `lares cleanup-old-name`, the old name's `qs-lock.lock`); `tools/lockscreen/lares-lock-held`
  (the lock-process stream's) does the same by path.
- **The reel's Lock item** (`ReelActions`): ONE detached command that decides when it runs: `sh -c 'if [ -x "$1" ]; then exec "$1"; fi;
  exec "$2"' sh <state>/lares/lock/current/tools/lockscreen/lares-lock-session ~/.local/bin/hyprlock` -- the Lares lock from its snapshot when
  that entry point is executable, else the hyprlock wrapper (today's behaviour); never nothing. `ReelActions.lockRunner` (null everywhere
  but one place): the ONE command a MOCK shell runs for real -- the Lock item, when the lock is live (`SHELL_LOCK=live`) inside a nested test
  compositor (`LOCK_ENV_DIR`, which tools/dev/lock_env.sh puts in every process of its own); the mock's runner records and runs nothing, so the
  gate gets the whole chain from a real right click to the supervisor.
- **A detached command has no stdio of the shell's** (`CommandRunner._detach`: `setsid -f sh -c 'exec "$@" </dev/null >/dev/null 2>&1'`). The
  cause of "right clicking the selected Lock does not lock, most of the time" (feedback/reel.md): a `Process` gives its child a pipe for stdin,
  stdout and stderr, `setsid -f` exits at once and the Process is destroyed, closing the shell's end -- and the detached child's first word on
  stdout or stderr is a write to a pipe nobody reads, which kills it (SIGPIPE). The hyprlock wrapper and the supervisor both talk, so the lock
  died before it had locked anything whenever its first word came after the Process was gone, i.e. nearly always, and not always. Proved by a
  detached `sh` that marks its start, sleeps, writes and marks again (the second mark never came), and by the gate with the stub entry point
  made to talk (L1.stdio; ARM `nostdio` puts the old command back).
- **The power reel rests on Lock** (`ReelItems.POWER_REST`, snapped by `ShellFrame`'s `powerReel.Component.onCompleted`; commit 202f2ef0 -- the
  feedback "default selected is sleep" was made at 1a182218, before it: a reel rests on index 0 until a host moves it and POWER lists Sleep first).
  `shell probe` carries `screens[n].reels = { power, idle }` (the selected ids); the gate's L10 reads it at the shell's start and after a lock.
- **Probe hooks** (the `shell` IPC in `modules/shell/ShellMain.qml`, MOCK shells only; a live one answers "live" and does nothing): `hook notify <text>` posts a toast,
  `hook secret` seals a copy in the clipboard mock, `hook idle <mode>` sets the idle reel's mode (the reel's Lock is driven by a REAL right
  click, never by a hook). `shell probe` carries `lock`, `barsUp`, `notifications`, `clipboard`, `reels` and `written.holdsLocked`.
- **Gates.** `shell_lock_probe.sh` (env tier, row `shell_lock`, noload key `shlock`; groups L1-L5, L7-L11, ARMs `nokbd nomask nohold
  onecorner orphan6s nobars noidle noreel norest nostdio`, each failing its own check; L6, a `hyprctl reload` mid-lock, is the lock-process
  stream's to add; L1 and every other lock of the gate start from a REAL right click on the power reel's Lock cell -- the env's virtual pointer
  has no right button, so `fixtures/shell_lock/rbutton.c` is a one-shot second virtual pointer that presses it at the cursor's place --;
  L10 the power reel rests on Lock at the start and after a lock; L11 five locks in a row from the reel, each unlocked by the password), the frame
  probe's `f12` (in process), and the spike `shell_lock_idle_spike.sh` for the idle inhibitor. The gate runs the REAL lock in the nested
  compositor from a tree copy, behind a stub `lares-lock-session` in the env's `<state>/lares/lock/current/tools/lockscreen/` (the stub
  execs the copy's supervisor the way lock_integration.sh does and keeps its words in `$LOCK_ENV_DIR/sup.out`); the mock shell RECORDS
  the reel's command (the mock runs nothing) and the gate runs that command, detached. Its stresses (in the run's sandbox copy, never the
  tree): the lock's popup ASKS for the exclusive keyboard, and the bars' layer is made INTERACTIVE above the lock (`above_lock = 2`, a rule of
  its own name: redefining the env's `lares_bar_above_lock` does not take), so that only the window's own clauses keep the keyboard and the
  pointer from the shell.

## 12. The config specs (round "json additions", 2026-11-23)

Every hand-edited `config/<name>.jsonc` has a SPEC: `modules/common/config/specs/<name>.js` says for every key its type, its default (today's
behaviour) and what it may be (the grammar is at the top of `modules/common/config/ConfigCheck.js`). Made of the spec and of nothing else:

| What | Where | Reads |
|---|---|---|
| the toast that says a mistake (one per file, with the line; withdrawn when the file is right) | `modules/common/config/ConfigWatch.qml`, one in `ShellServices` | every `ConfigFile`'s text through `ConfigTell.js`; `extra` for a file no loader of the shell reads |
| the loader of a new file: `settings` with every key, right from the first turn, hot; a key marked `start` keeps its first value | `JsonConfig.qml` (`services.powerConfig`, `workspacesConfig`, `clockConfig`, `playerConfig`, `audioConfig`, `notesConfig`, `pickerConfig`, `lockscreenConfig`, the LLM's) | the spec |
| `lares config` (check, `set`, `find`) | `tools/shell/lares-config-check.py` | the schemas |
| VS Code's completion, hover words and underlines | `.examples/schema/<name>.schema.json`, `.vscode/settings.json` (written by `node tools/dev/config_schema.js`) | the spec and the comments of `.examples/<name>.jsonc` |

An older loader keeps its own merge (and its own leniency: a clamp, a default); ShellConfig and SystemUpdateService read their newer keys
through the spec (`ShellConfig.checked`, `SystemUpdateService.settings`).

A NEW KEY is: its line in the spec, its words in the example (the line right above the key, or after it on its line: that is the hover text),
`node tools/dev/config_schema.js`, then the code that reads it. A new FILE adds `ConfigSpecs.js` (one import, one line) and
`tools/dev/config_paths_check.py` NAMES. The gate `tools/dev/config_spec_check.js` (quick tier) holds the four together: every example is
right by its spec and writes every default the spec has, every key without a default is named in the example's words, every spec has an
example and is in `ConfigSpecs.js`, the schemas are fresh, and the shell's checker and `lares config` give the same lines for the cases of
`tools/dev/fixtures/config_cases.json`. `tools/dev/config_watch_probe.sh` holds JsonConfig and ConfigWatch; `tools/dev/shell_options_probe.sh`
the keys that decide what the real frame builds; `tools/dev/bar_clicks_probe.sh` the bar's right and middle clicks.
