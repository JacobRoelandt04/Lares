# Round 2 -- the names every stream relies on

(The plans, stage-0 facts and round notes this contract names beside it are no longer in `docs/`: they are in git history,
`git log --all -- 'docs/agent_added_files_and_folders/shell_progress/'`.)
(The gates, probes and fixtures this contract names without a directory went with the cleanup: tag `pre-cleanup` has them. What a change is proved with now is in `tools/dev/`, [tools.md](../tools.md).)

Wave 1's `shell.md` (this folder) still holds. This file adds round 2's names as they are fixed; a section marked
PENDING is not a contract yet. Never rename a member listed here; a needed change is a request.

## 1. Scale (fixed 2026-10-16 from stage 0 P2, `R2-0.md`; built by stream SC)

The user's ask (DeploymentNotes.md 132-140): one global scaler, a bar and a popup scaler, independent of
Hyprland's own output scale, every pixel-resolution graphic rendered at the scale (a restart may apply it).

- **shell.json** `"scale": { "global": 1.0, "bar": 1.0, "popup": 1.0, "outputs": { "<connector>": { "global": .., "bar": .., "popup": .. } } }`.
  `global` = DEVICE px per DESIGN px (what the user turns: 1.25 makes everything 25 % bigger on any output
  at any Hyprland scale); `bar`, `popup` = RATIOS on it (default 1). A per-output entry wins (key = the
  window's `screen.name`). Read at start; a restart applies a change.
- **`ShellScale`** singleton (`modules/shell/scale/ShellScale.qml`):
  `configured(name, kind)` (kind `"frame" | "bar" | "popup"`: frame -> g; bar -> g x bar; popup -> g x popup,
  g = the output's global or the global), `dpr(item)` = `item.Window.window.devicePixelRatio` (NEVER
  `Screen.devicePixelRatio`: the attached Screen reports an INTEGER 2 at Hyprland 1.25 / 1.5),
  `frameScale(item, name)` = configured(name, "frame") / dpr(item), `renderScale(name, kind)` = configured(name, kind).
- **The frame**: inside `ShellScreen`'s `body` (so the ThemeCrossfade, a sibling, captures unscaled) an
  `Item { width: win.width / k; height: win.height / k; scale: k; transformOrigin: Item.TopLeft }` holds
  the `ShellFrame`, k = `ShellScale.frameScale(win, win.screen.name)`. Everything inside is laid out in
  DESIGN px; the engine's geometry (radii, fillets, snaps, gaps) follows for free. `GooeyMask` needs nothing.
- **SLIM** = `6 / k` design px (Hyprland's gaps_out is 6 compositor px). **Reserve** = `Math.round(thickness x k)`
  compositor px (`GooeyEdgeReservers` takes the engine's reserve x k).
- **renderScale** keeps its meaning: DEVICE px per DESIGN px (a texture's size = size x renderScale).
  `frame.renderScale` = `ShellScale.renderScale(name, "frame")`; owners keep `renderScale: frame.renderScale`
  (x their ratio once ratios exist). Nothing reads `Screen.devicePixelRatio`.
- **Resolution rules** (every pixel-resolution consumer, proven in `r2_s0_scale_sharp.sh`):
  a `layer` sets `layer.textureSize: Qt.size(width * renderScale, height * renderScale)`; a Canvas is the
  shared **`ScaledCanvas`** (built renderScale x larger, scaled down, `ctx.scale(rs, rs)` after `reset()`,
  rs in the repaint key -- `canvasSize` does NOT stretch a canvas); an `Image` decodes at
  `sourceSize: Qt.size(w * renderScale, h * renderScale)`; a `ShaderEffectSource` sets `textureSize` the
  same way. Text, ShadowBox, Shapes and the SDF shaders need nothing.
- **Bar and popup RATIOS** (PENDING, stream EL, Addendum 3): a bar's thickness and module row, a body's
  content under its ratio; the engine converts content-unit numbers at its boundary (in: implicit size,
  `secondaryAnchor`, `secondaryInset`, `secondaryOpenMin`, `alongShift`, `gestureHold*`; out: `hostRoom`,
  `secondaryCutout`, `gestureWheel` x/y) and scales its own constants (`maxR`, `blendRadius`, `flushSnap`,
  `snapDistance`, `tintBlend`, neck sizes) by the ratio. Until then the ratios are 1.
- **Windows outside the frame** (`OsdPillWindow`, `AuthPillWindow`): the same scaled Item with
  `ShellScale.frameScale`, reading `ShellScale.renderScale`. The lock is its own surface (lock stage).
- **The size standard** (PENDING): after the user has picked the global scale from renders, a per-module
  pass makes text and list density consistent (the complaints: LLM, notes, player lists, wiki). Until
  then nobody resizes for "too small".

### 1a. As built (stream SC, merged 14c379c1, 2026-10-21)
- `modules/shell/scale/`: `ScaleConfig.js` (the block parsed and clamped: global 0.5..4, ratios 0.5..2; per-output keys win key by key)
  and the `ShellScale` singleton (its `source` is ShellConfig's parsed object, bound in ShellServices).
- `modules/common/components/`: `ScaleRoot` (the scaled Item; ShellScreen's body and the two pill windows hold one), `DeviceScale`
  (`value` from the nearest ScaleRoot, else the window's ratio; `size(w, h)` for decodes; `texSize(w, h)` for layers and
  ShaderEffectSources -- 0x0 where nothing is magnified, because a requested textureSize is not Qt's default path even at the
  item's own size), `ScaledCanvas`. New consumers take DeviceScale; nothing reads the attached `Screen.devicePixelRatio`.
- Gates: `r2_s0_scale_census.sh --mine` (quick), `shell_scale_audit.sh` (a running frame at 1.5: no soft raster),
  `shell_scale_consumers_render.sh`, `shell_probe.sh` with `SCALE=` / `HYPR_SCALE=` / `SCALE_OUT2=`, `shell_overlay_probe.sh`,
  `shell_pills_scale_probe.sh`; `shell_scale_pick.sh` renders the user's pick sheets.
- The ratios are stream EL's (Addendum 3); MultiEffect's `blurMax` is in ITEM px and is not multiplied by the scale.

## 2. A key-opened popup over a fullscreen window (fixed from stage 0 P4; built by stream SC)

`ShellScreen`: `WlrLayershell.layer: overlayWanted ? WlrLayer.Overlay : WlrLayer.Top`; `overlayWanted` =
a key-opened popup (clipboard, launcher; any owner that sets `wantsOverlay`) is open on this screen AND
this screen's focused window is fullscreen (`FocusedScreen.fullscreen`). Set in the same event that opens
the popup; cleared only after the popup has CLOSED (its close animation done). The owners' "not over
fullscreen" refusals go. The switch is clean (same surface, one frame step, mask and keyboard grab survive).

## 3. Open / travel cost (fixed 2026-10-17 from stage 0 P3, `R2-0.md` P3; engine part: stream EL)

The cause (P3): a content is built SYNCHRONOUSLY in the click's frame, ~45 us per visual item; LLM, weather
and clock build 3300-4800 items (182-196 ms: a 192-222 ms hole on open, 217-241 ms in a travel). Keeping
contents alive removes the holes but live hidden contents burn 14-15 % of a core; async delays the popup
0.4-0.85 s (refused). The contract:
- **`parked`**: every content honours `property bool parked` -- while true it runs NO animation, timer,
  FrameAnimation, particle system or canvas repaint and asks no service for anything; its implicit size
  stays valid. The engine sets it; a content never sets it.
- **Build on hover**: an owner calls `engine.prebuild(ownerId)` when the pointer has rested ~80 ms on its
  button (hover intent; a key-opened owner does not); the engine builds that owner's content into a PARKED
  slot (laid out at its implicit size, not shown, no `popupOpen`), and `open()` / a travel ADOPTS it -- no
  build in the click's frame. At most ONE parked content per window: a new prebuild replaces it.
- **The last closed content stays parked** (P3's keepalive2: warm reopen 53-85 ms, travel holes 26-33 ms)
  until a prebuild or another open needs the slot.
- **Prewarm through the engine's own path**: after the shell is ready and idle, each popup is built once at
  opacity above 0 inside its clips in the real window for one frame and destroyed, one popup per idle beat
  (SiliconPrewarm's rule; silicon's own prewarm is worth 261 ms cold).
- **Idle is free**: an open popup with nothing changing commits no frames (P3: LLM, weather, player commit
  120 frames/s idle) -- each module gates its own clocks; `tools/dev/perf/shell_idle.sh` gates it.
- **Build less** (each module): virtualise long lists (the LLM sidebar: -120 ms measured), build hidden
  tabs / sections lazily (weather, clock), so the first frame needs only what is shown.
- Gate: `shell_open_timing.sh` against `R2-0_P3/base/merged.json` (`compare`): warm opens of every popup
  under 100 ms to the first shown frame, no presented gap over 50 ms in an open or a travel, idle CPU at
  baseline.

### 3a. As built (stream EL, merged e3245aab, 2026-10-21; notes in `R2-EL.md`)
- A primary's content is the ENGINE's, not a Loader's (the Loader stays for children, the lane, the OSD, the
  flourish, and as the fallback). `engine.prebuild(ownerId, component, initial)` builds into a hidden park only
  while the engine is calm (nothing opening, closing, moving or swapping; it waits up to 3 s, and any open
  cancels it). `open()` and a travel's swap ADOPT the parked content. One parked content at a time; it ages
  out after 2 min, and a retired one is destroyed when the engine rests.
- The content is built WITH `{parked: true}` (as an initial property, so nothing runs for a frame) and the
  engine writes `parked` from then on. A content that declares nothing behaves as before.
- `recycle()` (optional, on the content): only a content that has it is kept parked after it was SHOWN and
  closed. It must reset what a fresh open expects: secondaries, dates, scroll. Clock and weather have none
  yet, so for them the saving is the hover build plus the re-arm.
- Owners: `HoverIntent` (`modules/common/components/HoverIntent.qml`, an 80 ms rest, armed while
  `!popupMine` so a close under a resting pointer builds the next one) on the button calls `prebuild`.
  Pending requests (the clock's `pendingWiki`, stocks' `pendingDetail`) are handed over at OPEN, not at
  build. The content takes the keyboard when `parked` turns false, never while parked.
- Prewarm: `ShellFrame.prewarmEntries` (clock and weather so far) and the knob `ShellFrame.prewarm`. It starts
  6 s after ready, screens 2.5 s apart, one entry per 500 ms beat, and yields to any popup. Each entry is drawn
  plain, then through the clip layer, at 2 % scale and opacity.
- A secondary that opens WITH its primary is released when the primary's DRAWN extent reaches
  `closeChildLead`, the close's own number, so both directions share one choreography (`reopenChildLeadMs` is
  deleted). `docs/contracts/gooey_engine.md` still names `reopenChildLeadMs` (~line 348). That file carries the
  user's uncommitted edits, so its contract text is updated after they commit.
- The module half, for every other owner (LLM, stocks, notes, player, network/bluetooth, notifications,
  update, launcher, clipboard), goes to its stream: HoverIntent plus `prebuild(.., {parked: true})`, `parked`
  honoured, pending requests handed at open, a line in `prewarmEntries`, and `recycle()` where reuse is safe.
- THE SHELL SAYS WHEN IT HAS SETTLED (stream PF, merged 851628c8): `ShellServices.settled` turns true once every screen's
  frame says `prewarmDone()`, the launcher is `ready` and the icon store is not `busy` (`AppIconStore.busy`: a bake or an
  atlas pack running; polled every 500 ms for at most five minutes); the
  shell prints `LARES settled screens=<n>` once and the IPC probe answers the key `settled`. Anything that measures the
  shell AT REST waits for it (`tools/dev/perf/shell_idle.sh`): before it, the start's tails (engine warm-up, the icon bake, the
  atlas decode, the prewarm) are what a window sees.

## 4. Notification sources (built by stream NS, merged b594c53d; notes in `NS.md`)

One host, `NotificationSources` (`modules/notifications/sources/`), built ONCE by ShellServices
beside the NotificationService (not per ShellFrame; the sources need nothing per screen):

```
NotificationSources { id: notificationSources; live: services.live; persist: services.live; service: services.notifications
    updates: updatesService; battery: batteryAdapter; stocks: services.stocks; calendar: services.calendar; osd: osdService
    runner: services.commands; ownerOf: key => services.focusedOwner(key); stateDir: services.stateDir + "/notifications" }
```

plus `import "../notifications/sources"`. The shell-hosted contract holds for it: every service is injected (null = that source is off), no source
builds a service, writes a property of one, registers a shortcut or connects an unaddressed request; a card's "Open" goes through
`ownerOf(key)` -- the focused screen's owner of `update`, `silicon`, `stocks`, `clock` (each has `open()`); a command a click asked for goes to
`services.commands` (which a mock only records). `live: false` runs nothing at all: no source active, no process, no post.

Hook lines in files that were nobody's (each is one statement and a comment):

| file | line |
|---|---|
| `modules/silicon/data/SiliconBatteryAdapter.qml` | `signal reading`, emitted after `_flush()` in `_refresh()`: an event arrives WITH its reading (the order CLAUDE.md names); stream SI will be told |
| `modules/osd/data/OsdKinds.js` (+ `osd.example.jsonc`, `osd_js_cases.js`, `test_osd_sources_probe.qml`, the adapter probe) | `kinds.battery.route = "off"` after the loop in `defaultConfig()` |
| `modules/stocks/data/StocksViewModel.qml` | `timeoutMs: 0` removed from `notifyAlerts` (the sticky alert) |
| `modules/stocks/data/StocksConfig.qml` (+ `stocks.example.jsonc`) | `sudden: { pct, minutes, bySymbol }`, normalised (a bad value is a line in `lastError`, the default stays) |
| `modules/shell/ShellServices.qml` | the import and the instance above; it names `services.commands` (the alias), not the id `runner`, so stream T's rename of the ids does not touch it |

Keys: `sources.<id>` of notifications.json (`update`, `battery`, `stocks`, `screenshot`, `usb`, `calendar`, `disk`, `units`, `thermal`), every
one with `enabled`; the rule keys of NotifyPolicy (`mute`, `urgency`, `timeoutMs`, `sound`, ...) live in the same block and pass through. The
table is `SourceSettings.js`; `notifications.example.jsonc` documents each key and `notification_sources_js_cases.js` proves the example
equals the table's defaults (the example cannot drift).

Rows for `tools/dev/shell_gates.sh` (stream X's file, not edited here):

```
quick  js_notification_sources  run  node notification_sources_js_cases.js
quick  notification_glyphs      run  bash notification_source_glyphs.sh
qml    nsrc_host        box  notification_source_host_probe.sh
qml    nsrc_update      box  notification_source_update_probe.sh
qml    nsrc_battery     box  notification_source_battery_probe.sh
qml    nsrc_stocks      box  notification_source_stocks_probe.sh
qml    nsrc_screenshot  box  notification_source_screenshot_probe.sh
qml    nsrc_usb         box  notification_source_usb_probe.sh
qml    nsrc_calendar    box  notification_source_calendar_probe.sh
qml    nsrc_disk        box  notification_source_disk_probe.sh
qml    nsrc_units       box  notification_source_units_probe.sh
qml    nsrc_thermal     box  notification_source_thermal_probe.sh
```

The noload rows (`nshost nsupdate nsbattery nsstocks nsshot nsusb nscal nsdisk nsunits nsthermal`) are in `tools/dev/runner_noload_check.sh`.

