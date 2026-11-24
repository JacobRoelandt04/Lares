# Performance

(The progress notes this contract names (`perf_pass/`) are no longer in `docs/`: they are in git history,
`git log --all -- 'docs/agent_added_files_and_folders/perf_pass/'`.)
(The gates, probes and fixtures this contract names without a directory went with the cleanup: tag `pre-cleanup` has them. What a change is proved with now is in `tools/dev/`, [tools.md](../tools.md).)

An audit of the whole shell (2026-08-31): fifteen agents reading one
subsystem each, 244 findings, then measurement to decide which of them were
actually costing anything. **The measurement is the point.** Several findings
that read as obviously expensive moved nothing, and one thing nobody had
listed turned out to be two thirds of the reported lag.

## The harness

| tool | what it answers |
|---|---|
| `tools/dev/perf/scenario.sh <label> VAR=…` | one interaction benchmark, run ALONE, with /proc CPU beside it. Refuses to start if another quickshell is up |
| `tools/dev/perf/suite.sh <tag>` | the five scenarios, strictly serial |
| `tools/dev/perf/compare.py <a> <b>` | two suite runs side by side; flags anything that regressed |
| `tools/dev/perf/fidelity_check.sh <tag>` / `--diff a b` | the ten popup states rendered offscreen and compared pixel for pixel |
| `measure_idle_cpu.sh <qml>` | standing CPU with nothing happening |
| `test_viewswitch_probe.qml` | the scripted interaction: `SCENARIO=switch\|expand\|idle`, `EXPAND=1`, `PACKAGES=n` |

Three numbers per repetition, because they say different things: `blockMs`
(assignment → next presented frame — the felt freeze), `worstGap` (the
largest gap after it), `jank` (frames that missed 8.3ms at 120Hz). `FRAMES=`
on the last line is the guard: Qt animates off the render loop, so a window
the compositor is not presenting produces no frames and every lag number
above it is a lie.

**Fidelity gate.** Nine of the ten rendered states are bit-identical between
two runs of unchanged code, so one moved pixel is a real change. `prompt` is
not reproducible — the run reaches it at a different moment each time — and
is excluded.

## What was measured, before and after

| scenario | before | after |
|---|---|---|
| view switch, categories open, 69 packages | 48 ms | **37 ms** |
| view switch, categories open, 276 packages | 161 ms | **136 ms** |
| expand / collapse four categories | 90 ms | **79 ms** |
| view switch, categories shut | 8 ms | 8 ms (nothing to save) |
| live run, no interaction | 0.060 cpu-s/s | 0.059 |
| battery data, forks per 12s | 268 | **224** |

## The finding that mattered most was not in the list

The switch cost is **0.55 ms per instantiated row**, linear from 69 to 276 —
constant work per row, not a quadratic. An ablation giving both views the
same list scale (`SAME_SCALE=1`, a diagnostic, never a setting) drops the
switch from 37 ms to **12 ms**: two thirds of what is left is the scale
cascade, every `Text` in every instantiated row re-shaping at a new pixel
size. All six repetitions cost the same, so it is shaping, not glyph
rasterisation — no cache warming would touch it.

Removing that needs viewport culling of rows, which trades a switch hitch
for a pop while scrolling. **Not taken:** that is a fidelity cost, and
fidelity is the constraint.

## Fixed

- **stats-block-built-in-every-row** — Every row builds a full DownloadStats (14 QObjects, 9 Texts, a FontMetrics, ~13 text measurements) that can only ever be seen during a byte-moving step  
  `modules/bar/system_update/components/UpdatePackageRow.qml:455`
- **connector-shape-per-row** — A QQuickShape with the curve renderer is built and kept visible on every row, for a connector that is fully transparent until the row is expanded  
  `modules/bar/system_update/components/FromToPair.qml:136`
- **hover-glyph-always-instantiated** — The link-hover glyph is a second full Text on every row, re-shaping its font every frame of an expand and re-darkening its colour every frame of the theme fade, while invisible  
  `modules/bar/system_update/components/UpdatePackageRow.qml:386`
- **glyphfor-no-memo** — glyphFor runs a linear scan of 15 regexes per row with no memo, and is re-run for every row on every category open  
  `modules/bar/system_update/components/PackageIcons.qml:89`
- **apply-progress-scans-every-section** — Every progress event makes every section linear-scan its whole row model, allocating a ListModel wrapper object per row, then 5 more for the row it finds  
  `modules/bar/system_update/components/UpdateCategorySection.qml:711`
- **progressinfo-called-seven-times** — `_progressInfo()` is called seven times per parser tick — seven object-literal pairs and seven regex parses for one value  
  `modules/bar/system_update/components/SystemUpdatePopup.qml:628`
- **glyphfor-uncached** — Every row delegate re-runs a 15-regex icon lookup on creation, with no memoisation  
  `modules/bar/system_update/components/SystemUpdatePopup.qml:3424`
- **battery-forks-cat-once-per-second** — Battery state is read by fork+exec'ing /usr/bin/cat once a second, all day  
  `modules/common/system/BatteryData.qml:99`
- (RESOLVED 2026-09-22: BatteryData no longer reads the threshold; ChargeLimitData is its one reader) **chargelimit-duplicate-sysfs-poll** — ChargeLimitData polls the same sysfs file BatteryData is already polling, on the same 3 s cadence, with its own fork  
  `modules/bar/battery/data/ChargeLimitData.qml:90`
- **downloadstats-instantiated-per-package-row** — Every package row builds a full DownloadStats — 14 items, a FontMetrics and ~13 text-shaping calls — even in the idle list where it is never shown  
  `modules/bar/system_update/components/UpdatePackageRow.qml:455`
- **updatecategorysection-model-get-repeated** — _applyProgress calls rowModel.get(i) five times for the same row inside a linear scan run per progress tick per category  
  `modules/bar/system_update/components/UpdateCategorySection.qml:711`

## Checked and found already handled

- `wavefield-arrays-per-contour-sample` — the wavefield's 60 Hz stepper is
  already gated on `!_isFlat` and latches flat when every node is under 0.1.
- The bar's own composition (`test_bar.qml`) measures **0.000 cpu-s/s** at
  idle, so the always-on FBO and bloom findings cost nothing while nothing
  moves. They would only bite if something re-rendered continuously.

## Round 9 — the audio player while it is PLAYING (2026-09-10)

Rounds 7 and 8 went after idle. This one went after the other half, and the
headline is that **the playing popup was halved**. Measured against the
pre-round tree (`d37b678`) rebuilt and run in the same session, `PLAY=1`,
`WARMUP=16 WINDOW=10`:

| state | before | after |
|---|---|---|
| player playing | 43.8 % cpu, 3.15 ms/frame, 106.6 gpu ms/s | **23.4 %, 1.50 ms/frame, 105.5** |
| mini playing | 42.2 % cpu, 3.12 ms/frame, 64.2 gpu ms/s | **22.2 %, 1.42 ms/frame, 64.2** |

GPU unchanged and the frame count UP (139 → 156), which is the signature of
"the same pixels for less CPU" rather than of something being dropped. Pixel
gates: 0 px moved on all nine record states and all ten system-update states;
`vinyl_sequence.sh all` is PASS on every scenario with all nine armed
faults still failing, and `audio_player_probe_run.sh` likewise.

Take the absolute numbers with the caveat that this harness free-runs: a mid-round
reading of the same tree drifted 21.2 → 23.5 while another session was working
on the machine, which is why the two arms above were captured back to back on a
quiet one. The RATIO held everywhere: about half the CPU and about half the
per-frame cost.

### What was fixed

- **`VinylDisc._quad` off the spin's path.** `_axes` was a `var` array, QML
  compares `var` by identity, so a fresh array notified every frame and pulled
  a sixty-line drawn-rect derivation, a `Qt.rect`, four item-geometry bindings
  and a uniform with it — for a value the spin provably cannot change.
- **`SquishItem` stops re-rasterising to move.** Its paint was already in
  canvas-local coordinates, so a slide along a straight rail redrew exactly
  what was on the canvas: a 66-point polygon fill with a software shadow, every
  frame. The repaint is gated on a comparison against the outline last painted.
- **`PlayerViewfinder._stretchF` floored** at the 0.01 the file already used.
  `dist / dt` with an integer-millisecond `dt` jittered every frame, retargeting
  a Behavior that moved the ball's width — without this the gate above could
  never match.
- **`PlayerData` stops seating lyrics behind a shut tab.** `active`/`visible`
  gate what a panel shows, never what its handlers do.
- **The mockup's Run-tab readout** stops re-shaping a four-line paragraph every
  frame. Harness, not drop-in — but it taxed every measurement of this module.

### What was measured and NOT fixed

Every one of these was killed by its own ablation before a line was written,
which is the round's real lesson.

| candidate | measured | verdict |
|---|---|---|
| size the spark canvas + FBOs to the live cloud | 46 px of air → 6 px: **+0.4 % cpu, +0.4 gpu** (noise) | dropped — the plan's headline fix was worth nothing |
| the per-particle allocations (filter over 320 slots, trail objects, rgba strings) | paint skipped entirely: **0.0 cpu** | dropped |
| `blurMax` 22 → 8 at the same effective radius | **+0.6 cpu, +0.1 gpu** | dropped — MultiEffect's blur is not priced by `blurMax` here |
| `_elapsedText` rebuilt per frame | ablation **−0.6 %** (3× the noise floor and no more) | dropped |
| the particle sim on a FrameAnimation instead of a 16 ms Timer | wakeups 62/s → **155/s**, cpu neutral | reverted |
| layer-caching the "static" panels | they already do no per-frame work | never started |

### Three instruments were lying, and that is the durable part

- **`vinyl_fidelity.sh` claimed a zero noise floor.** It moved 18–25 px run to
  run on `grid_clean`. The moving pixels were its own cell CAPTIONS — Qt
  rasterises glyphs through the distance-field cache on the render thread and
  it is not bit-exact. The states with no caption were exactly zero every time.
  `CAPTIONS=0` (new in `test_vinyl_render.qml`) restores a real zero floor on
  all nine, including the edge-on poses. A tolerance was refused: it would hide
  the few-pixel geometry shift the gate exists to catch.
- **`fidelity_check.sh`'s `prompt` state is stable WITHIN a tree.** It reported
  a solid 16 px regression, reproducible on both sides — and a byte-identical
  copy of the candidate tree rendered it clean. Re-capturing from the same
  directory proves nothing about `prompt`. Its two captures also settle at
  different window alpha, so a raw RGBA compare called it 96 % of the frame
  where compositing both on one background showed 16 px.
- **`mockup_cpu.sh`'s "frames/s" is a count of paint REQUESTS.** Under
  `QSG_RENDER_LOOP=basic` offscreen the loop renders on its own ~62 Hz tick
  while anything animates, and it floors there: every clock in the popup capped
  to 30 a second, sparks off and the flight recorder off, still drew 60 frames.
  Readings of 133 and 156 are two or more clocks asking out of phase. **No
  frame-rate change can be demonstrated with this harness** — that needs a real
  vsynced window.

Two ablations had also rotted silently: `particles_off.py` anchored on the
vinyl particles round 8 deleted, and `vinylstage_off.py` inserted a duplicate
`visible:` so the run failed to LOAD and reported "DIED", which reads like a
flaky run rather than a broken instrument.

And **`visible: false` ablations under-measure**: `viewfinder_off` valued the
rail at 0.02 ms/frame while the ball gate alone beat that many times over,
because hiding an item leaves its bindings and its canvas repaints running.

### Still open

- `VinylStage.spinHz` ships as a knob (Motion tab, default 0 = every frame) and
  is **unmeasured** for the reason above. On this machine's 120 Hz panel the
  popup pays twice a 60 Hz screen's bill for the same picture.
- The record's silhouette sub-sampling was **attempted and reverted**. It is a
  real 22.3 % of the record in `player` and 37.0 % in `mini` (`vinyl_ab.sh
  AB="edgeSamples:0"`, at the pose the record holds while playing), and an
  analytic replacement gated on a `flatPose` uniform measured **13.0 % faster**
  at that pose (`vinyl_pair.sh`, 12.78 → 11.12 ms/s). It also drew a different
  record: 4645 px of the pin sheet at 232/255 measuring both edges against the
  mid-plane, still 3628 at 229 after correcting them to the near and far faces.
  A flat record is still a thick one under a pinhole camera, `fpx` is the
  derivative of the wrong radius once the edges move off the mid-plane, and the
  spindle hole is two pixels across in some states — which is the case the
  sub-samples exist for. The whole prize is under 1 % of the GPU (the disc is
  39.4 gpu ms/s of 1000) on a popup that was CPU bound, so it was not worth a
  third iteration. The measurement is recorded in `vinyl_disc.frag` beside the
  two earlier failed attempts.

## Round 2, stream PF — the shell AT REST (2026-10-22)

The night pass saw the real shell present 22 frames in each main window in some idle runs and 0-2 in others, 0.134 cpu-s/s with
the engine's warm-up on and 0.0044 off, "intermittent on the same code", and the LLM popup present 3-6 frames in its idle phases.
None of it was the shell at rest. Measured with a clock on every frame (`tools/dev/perf/shell_idle_frames.sh`) and Qt's own
`qt.quick.dirty` log, which names the item that asked for the frame:

| what the night pass saw | what it was | how it was shown |
|---|---|---|
| ~0.9 Hz, 22 frames per 25 s window per main window | **the silicon MOCK's script**: `MockTimeline` desk wakes the dGPU at t = 40..46 s of every 60 s loop; `SiliconBarMark` fades ring -> dot -> ring, 160 ms each way = 11 frames each, 1 frame in each of the four other windows | `qt.quick.dirty` named `SiliconBarMark`'s two Rectangles (OpacityValue); mock still (`playing: false`): a 130 s window holds one frame per main window per minute (the clock, allowed); `ARM=mockplays`: 54 frames, 23 per main window |
| 0.134 cpu-s/s with the warm-up on, 0.0044 off; ~2 frames with 0.06 cpu-s/s | **the window landed in the start's tails**: the engine's warm-up (1-2 cores for 5-8 s on a warm shader cache, 20-35 s on the cold one a nested session starts with), the launcher's icon bake (a child) and atlas pack, and then **1.2-2.5 s of the MAIN thread, once, 20-45 s after the start** | per-thread series (`proc_series.py`): the burst is `quickshell`'s main thread with no frame; after settle two interleaved pairs: warm-up on 0.0005 and 0.0007, off 0.0005 and 0.0005 cpu-s/s -- no parked content works at rest |
| the LLM popup's 3 / 3 / 6 / 6 frames in `llm_scroll_perf` IDLE0-3 | **the composer's caret blink**: exactly 2 frames a second | `ABL=llmnofocus` (the composer never takes the focus): 0 / 0 / 0 / 0; `qt.quick.dirty`: `TextArea llmComposerField` `Content` every 500 ms; in the stage with the popup open: 80 frames in 40 s (period 0.500 s), 0.0090 cpu-s/s vs 0 frames and 0.0007 unfocused: 4.2 ms of CPU per blink frame |

**The fix is in how the gate waits**, not in a module: ShellServices prints `LARES settled screens=<n>` once every frame's warm-up has
run out (`ShellFrame.prewarmDone`), the launcher is ready and `AppIconStore` is not busy (bake or atlas pack); `shell_idle.sh` waits for
it, then quiet seconds, then the quiet stretch of the minute, with the mocks still. Three full runs, in parallel and under load: A 0
frames / 0.0000-0.0005 cpu-s/s, B pass, C.shell 0 frames / 0.0004-0.0008, C.stage 0 frames / 0.0000-0.0004. ARMs: `wake` fails every
phase (62 frames/s in A; 1518 frames per main window in C), `nosettle` fails "never said settled", `mockplays` fails C. Phase B had its
own flaw: `mockup_running.sh` waits 30 s for the stage to print, and a cold shader cache takes longer on a loaded machine ("no census");
B has its own launch now and takes its census at A's settle time + 60 s (the old one, 8 s after the window, found the engine's warm-up
timers -- a 400 and a 500 ms one-shot -- running; at 110 s there were none).

**The main-thread burst is the launcher's atlas pages decoded eight times.** After the icon bake and the atlas pack the pages are
read as Images by FOUR Repeaters per window -- `ShellFrame` (the icon-pages Item), `WindowTitleButton`, `LauncherBarOwner`,
`AppIconPages` -- each `asynchronous: false`, `cache: false`: every one decodes the same 1920x1152 PNGs on the main thread (and each holds
its own QImage). Ablated on a copy: all four with `cache: true` (one decode, shared through the pixmap cache; the URL carries the pack's
revision, so a re-pack is a new key) cut the burst from 1.6-2.2 s to ~0.25 s of the main thread AND the settled shell's resident set
from 1113 to 843 MiB (each of the eight Images held its own decoded copy of the pages); `asynchronous: true` moves 1.5 s to the
`QQuickPixmapReader` thread; the launcher's two sites alone gain 14 % (2960 -> 2550 ms over the same 26 s), because the other two keep
decoding. NOT applied: two of the four files are other streams' (`ShellFrame`, `WindowTitleButton`) -- one word each;
`shell_idle_ablate.py atlascache` is the patch, and run against it `app_mark_render` (11 / 14 pixels one level off: text raster noise),
`windowtray_popup_probe` (57 / 57) and `launcher_popup_probe` pass (`tools/dev/perf/ablated_gate.sh atlascache <runner>`). The launcher's `_rebuild` (the catalogue), the first suspect, is 15 ms.

**The caret blink was not stoppable from QML in the one prototype made.** GTK's policy (blink for 10 s after the last key, then hold
steady) as a patch -- `cursorVisible` set back to false whenever Qt sets it true, a `cursorDelegate`, its own clock
(`shell_idle_ablate.py llmcaret`, run with `WARM_MS=12000 ABL=llmcaret tools/dev/perf/llm_idle_frames.sh`) -- still presents 3 / 3 / 6 / 6
frames, and the dirty log still names `TextArea llmComposerField` `Content` every 500 ms: the repaint request comes from the text
control's own blink timer, which a focused editable edit starts at focus-in, not from the property. A text field that holds the focus
costs two frames a second (0.8 % of a core here); what remains is to release the focus when the popup has been idle (a policy of the
popup's owner, with the pointer bringing it back) or to accept it.

**Item 4, the user's "CPU spikes every 10-20 s"**: no trial shell was running, so `shell_rest_sampler.sh --trial` could not be read.
Offline, at the shell's real size (1.25 GB RSS): a `sh -c grep` spawn every 2 s (what `ThermalNotifier` does every 15 s) costs the shell
about 1-2 ms; a forced full GC pass takes 11-22 ms on the settled heap and shows as one 10 ms tick every 8 s at the sampler's resolution
-- a blip of 10-20 % in btop at 100 ms, which an unforced pass would be too. The mock shell at rest has no spike above 20 ms (a 70 s
series at 0.1 s: 140 ms of CPU in all, 13 ticks of 10 ms, eight of them the probe's own passes), so what the user saw is in the LIVE
pollers or the collector; read it on the trial.

Tools: `tools/dev/perf/shell_idle_frames.sh` (the shell or the stage in the nested Hyprland, stderr through `ts_filter.py`, a per-thread
CPU series through `proc_series.py`, `WAIT_SETTLED=1`, `WARM=1` for a shader cache that outlives the run, `ABL=` ablations of the run's own
copy from `shell_idle_ablate.py`, `SHOTS=` grim pictures at seconds of the minute; a native stack of the main thread cannot be had this way:
`ptrace_scope` is 1, only a parent may attach, `eu-stack` from a sibling gets EPERM -- `mockup_stacks.sh` launches under gdb for that
reason), `shell_idle_frames.py` (frames per window, gaps, period; CPU per bucket; the
threads that carried it between two times), `tools/dev/perf/llm_idle_frames.sh` (`llm_scroll_perf`'s idle phases with ablations).
These runners went in the 2026-11-06 cleanup (`docs/agent_added_files_and_folders/shell_progress/cleanup_survey/c1_deleted.json`);
tag `pre-cleanup` holds them under their old names (`git show pre-cleanup:tests/perf/shell_idle_frames.sh`). The shell at rest is measured today by
`tools/dev/perf/shell_rest_sampler.sh` (CLAUDE.md, "A SHELL THAT POLLS").

## Backlog — verified as real by the audit, not yet measured or fixed

Ordered by the audit's own estimate of what they cost. Nothing here has been
confirmed with a measurement on this machine, which is exactly why it is a
backlog and not a claim: the audit's own hit rate was well under half.

### algorithmic (22)

- `SystemUpdatePopup.qml:2988` **flight-tree-walks** — A favourite toggle runs five full depth-first walks of the entire popup item tree, descending through every package row
- `SystemUpdatePopup.qml:723` **reconcile-get-in-callback** — _reconcileCategories re-fetches categoryModel.get(i) inside the .some() callback, once per candidate
- `SystemUpdateHelperDriver.qml:473` **helper-findpkg-quadratic** — _findOrAddPkg is a linear ListModel scan called twice per package, making the transaction O(N^2)
- `UiStateRecorder.qml:180` **recorder-walks-package-model-twice** — Every snapshot walks the parser's package model twice -- _pkgStates and _activeDownloads each scan it end to end
- `AvailableUpdatesService.qml:95` **categoryrank-indexof-in-comparator** — categoryRank does an Array.indexOf inside every sort comparison, and a second one on every miss
- `AvailableUpdatesService.qml:321` **isfavorite-linear-scan** — isFavorite() is a linear scan of the favourites array, called once per row on four different whole-model passes
- `MockupRegistry.qml:90` **defaultof-linear-scan** — defaultOf() linear-scans a whole list per entry, so every modifiedCount pass is O(n²) in the list length
- `TerminalView.qml:213` **batches-shift-quadratic** — `_out.batches` grows one entry per flush without bound and is drained with `Array.shift()`, which is O(n) per trim
- `UpdateCategorySection.qml:668` **localecompare-sort-per-sync** — _sourceRows re-sorts the whole category with localeCompare on every sync, though the ordering only changes when membership changes
- `UpdateCategorySection.qml:1055` **cleanup-removes-rows-one-at-a-time** — Collapse cleanup removes the rows one `ListModel.remove` call at a time — 170 separate model change-sets and Repeater updates in one JS turn
- `UpdateCategorySection.qml:355` **flight-dest-scans-model** — flightDestTopIn walks the model row by row to compute a value that is `index * rowHeight`
- `UpdateCategorySection.qml:825` **sync-quadratic-on-source-swap** — _indexOfRow's linear scan makes _syncSilent O(n²) whenever the target contains rows the model does not have
- `TerminalBackend.qml:635` **tail-rescan-per-chunk** — _nextRowBreak rescans the whole retained tail for \n and for the row-move regex on every chunk, re-covering ground already proven break-free
- `TerminalBackend.qml:564` **newline-only-path-quadratic** — The screenModel=false fallback rewrites the whole tail QString property once per line
- `GooeyEngine.qml:41` **gooey-hasbarat-quadratic** — hasBarAt is O(n^2) with an object allocation per inner step, and is called from the per-frame edge-metrics path for a value that is a layout constant
- `particles.js:170` **emit-scans-saturated-pool** — emit() linear-scans the pool from index 0 for a free slot on every single particle, and does the full scan for nothing when the pool is saturated
- `CalendarService.qml:169` **day-scan-per-uncached-day** — getEventsForDay rescans the entire occurrence array for every uncached day, with two QML property reads per event
- `MockCalendarData.qml:131` **day-scan-per-uncached-day-mock** — MockCalendarData carries the same per-day full-array scan with two QML property reads per event
- `SystemUpdatePopup.qml:2988` **full-tree-dfs-per-favourite** — A favourite toggle walks the entire popup item tree five times
- `particles.js:186` **particles-filter-per-frame** — getActiveParticles() scans and allocates over the whole pool (up to 1500 slots) on every paint
- `particles.js:179` **particles-update-scans-dead-slots** — ParticleSystem.update() calls update() on every pool slot including the inactive ones
- `particles.js:168` **particles-emit-linear-scan** — emit() restarts its search for a free slot at index 0 every call, and the callers call it once per particle

### per-frame (40)

- `SystemUpdatePopup.qml:3420` **flight-reveal-fanout** — The animated _flightReveal is handed to every section, which binds it into every row delegate although only one row's value can change
- `SystemUpdatePopup.qml:3380` **active-package-fanout** — _activePackage changes per installed package and invalidates a name-comparison binding in every row delegate
- `shadow_box.frag:162` **sdf-interior-computed-then-discarded** — Every interior fragment of every ShadowBox runs both easings, the pow, the progress mix and the seam smoothstep, then throws all of it away
- `ShadowBox.qml:237` **progress-shape-bindings-never-change** — _sw, _edgeAlpha and _falloff re-evaluate on every frame of a progress sweep even though every production host sets idle == active, so they never change value
- `IconButton.qml:177` **iconbutton-three-fbos-per-frame** — IconButton runs three offscreen render targets plus a MultiEffect Gaussian blur every frame for a static glyph, because precompute defaults to false
- `motion_blur.frag:32` **motionblur-two-zero-weight-taps** — Two of motion_blur's fifteen texture taps are multiplied by a weight of exactly zero
- `FromToPair.qml:119` **reveal-fraction-computed-twice** — The reveal ramp is written out twice and evaluated twice per frame — the label's opacity and the connector's opacity are the same expression
- `TipRow.qml:77` **tip-advance-reshaped-on-resize** — Every tooltip re-shapes its whole tip string whenever the panel width changes, because contentWidth reads TextMetrics.advanceWidth (uncached in Qt) alongside tipRow.width
- `ColorList.qml:52` **themed-swatch-per-fade-frame** — Every themed colour row re-reads the interpolated theme token and rewrites its hex TextField on every frame of the theme crossfade, hidden tabs included
- `TerminalView.qml:356` **tail-visible-tohtml** — `visible: text.length > 0` re-serialises the whole live-tail QTextDocument to HTML on every single flush
- `Theme.qml:116` **ansi-tokens-lerped-per-frame** — The 16 ANSI tokens and the two arrays built from them interpolate on every fade frame, but nothing on screen ever reads an intermediate value
- `GooeyEngine.qml:781` **fade-runs-while-popup-invisible** — The popup's content Loader is never released, so a theme switch re-runs the entire popup colour graph for 420 ms while `thePopup` is invisible
- `Theme.qml:52` **fadeprogress-dead-binding** — `fadeProgress` is a public property with no consumer anywhere, re-evaluated on every frame of every crossfade
- `AnimatedListRow.qml:77` **column-positions-every-retired-row** — Rows retired to zero extent stay visible to the Column positioner and the renderer, so all 182 children are repositioned every frame of a 614 ms wave
- `UpdateCategorySection.qml:505` **height-changed-handler-on-every-row** — Every row carries an onHeightChanged JS handler that exists only to measure row 0
- `TerminalBackend.qml:661` **currow-property-churn** — _curRow is a QML int property used as a scan-local cursor: read/written ~8 times per row with a change-signal emission each time
- (RESOLVED 2026-09-22: the overlay is gone; `ParticleLayer` gates its layer and glow on live particles and needs no mapping) `BatteryParticleOverlay.qml:172` **battery-bloom-layer-always-enabled** — particleLayer's blur+mask MultiEffect is unconditionally enabled — it keeps blurring a blank canvas, the exact cost PhaseRail already fixed
- `BatteryEventFX.qml:87` **battery-eventfx-shader-always-live** — The battery's distortion ShaderEffect and its live ShaderEffectSource run on every frame even when all four pulse channels are at zero
- `Workspaces.qml:617` **workspaces-bloom-blurs-empty-canvas** — The workspace sparks bloom is `visible: root.sparksEnabled` with no `hasParticles` gate — it blurs an empty canvas for the life of the bar
- `GrooveSlider.qml:1189` **grooveslider-bloom-blurs-empty-canvas** — GrooveSlider's slide-spark bloom has the same missing `hasParticles` gate
- `IconButton.qml:113` **iconbutton-live-shader-chain-by-default** — IconButton defaults to `precompute: false`, keeping two live ShaderEffectSources and a blur layer per button re-rendering every frame for content that never changes
- `GooeyEngine.qml:621` **fullscreen-msaa-layer** — A full-screen 4x-MSAA layer wraps the entire bar, so any 1-pixel change repaints the whole screen
- `GooeyEngine.qml:785` **gooey-curtain-tessellated-per-frame** — The transition curtain rebuilds and re-tessellates the full metaball path every popup-animation frame at opacity 0
- `Workspaces.qml:617` **workspaces-bloom-ungated** — The spark bloom MultiEffect blurs an empty particle canvas whenever the bar redraws
- `GooeyEngine.qml:924` **gooey-openpos-recomputed-per-frame** — getEdgeMetrics recomputes the popup's fully-open rectangle every frame although it is constant for the whole animation
- `particles.js:179` **particles-update-scans-whole-pool** — The particle step iterates the entire preallocated pool every tick, active or not
- `SquishItem.qml:292` **contour-rebuilt-three-times-per-frame** — _contour is a binding with three separately-notifying dependencies, so the pill contour is rebuilt 3x per frame instead of once
- `PhaseRail.qml:462` **three-stop-scans-per-frame** — _ballH, ballInSlot and ballInSlotTight each linear-scan the stops calling groove.xAt() on every frame the ball moves, recomputing the same pixel positions from scratch
- `MonthWeekRow.qml:194` **selector-instantiated-on-non-target-tiles** — All 18 tiled rows carry a selector box and label; 12 can never be visible, yet their positions re-bind every frame of the glide
- `MonthWeekRow.qml:196` **selector-slice-drawn-then-clipped** — Even in the target month all six rows draw the selector; four or five are entirely outside their row's clip
- `MonthWeekRow.qml:86` **row-clip-splits-the-grid-into-18-batches** — clip:true on every row exists only for the selector slice, but puts the whole ~190-item row subtree behind a clip node
- `MonthWeekRow.qml:331` **covered-binding-for-a-glyph-that-rarely-exists** — Per-cell `covered` re-evaluates every frame of the selection glide to colour a '+' overflow glyph that most months never render
- `AppointmentRow.qml:222` **expand-behaviors-duplicate-the-expand-clock** — Seven Behaviors re-animate values that are pure functions of the row's own _expandFraction clock
- `CalendarView.qml:97` **blur-sampler-is-a-free-running-qtimer** — The motion-blur amount is sampled by a 16 ms Timer rather than the frame clock, so it drifts against frames
- `PackageUpdateParser.qml:704` **dl-row-five-setproperty** — Every accepted download row fires 4–5 separate ListModel.setProperty calls where one set() would do — 5x the dataChanged emissions
- `SystemUpdatePopup.qml:2113` **motionblur-captures-whole-content** — The flight's MotionBlur captures the whole scrollable column, not the ~350 px of it that is on screen
- `GooeyEngine.qml:621` **gooey-fullscreen-msaa-layer** — The whole bar is composited through a full-screen 4x-MSAA FBO that is re-rendered whenever anything in the bar moves
- `GooeyMask.qml:10` **gooey-mask-rebuilt-every-frame** — The window's input region is recomputed and pushed to the compositor on every frame of the popup animation
- (RESOLVED 2026-09-22: the overlay is gone; `ParticleLayer` gates its layer and glow on live particles and needs no mapping) `BatteryParticleOverlay.qml:99` **battery-overlay-ancestor-walk-per-frame** — An ancestor-chain walk plus five mapToItem calls and two object literals re-run on every frame the popup moves
- `IconButton.qml:195` **iconbutton-precompute-defaults-off** — IconButton keeps two live ShaderEffectSource captures and a MultiEffect blur chain per button because `precompute` defaults to false

### idle-power (29)

- `SystemUpdatePopup.qml:316` **hidden-popup-keeps-computing** — Nothing but the dots Timer consults root.visible, so a closed-but-retained popup runs the whole derived chain at full rate for a background update
- `AvailableUpdatesService.qml:477` **login-shell-per-probe** — All three update probes spawn a LOGIN shell (bash -lc), sourcing /etc/profile and 23 profile.d scripts before doing anything
- `TerminalView.qml:295` **flick-not-cancelled-on-hide** — An in-flight Flickable flick keeps the animation driver awake after the view is hidden by a view switch
- `Theme.qml:692` **state-write-retry-unbounded** — `_flushStateWrite` re-arms its own 150 ms timer forever when `_stateDirReady` never becomes true, with no attempt limit
- `UpdateCategorySection.qml:820` **done-exit-timer-forces-full-resync** — doneExitTimer schedules a complete model reconcile every 220 ms whether or not any row has actually crossed its retirement delay
- `UpdateCategorySection.qml:614` **schedule-sync-spins-the-event-loop** — _scheduleSync busy-requeues itself through Qt.callLater on every event-loop pass for the entire length of a wave
- `SquishItem.qml:101` **squish-physics-ticker-never-sleeps** — SquishItem's 60 Hz physics Timer has no rest condition — it runs forever for every GrooveSlider on screen
- `BatteryParticles.qml:88` **battery-particles-no-visibility-gate** — The battery particle stream is gated on watts only, never on being visible — on battery power it simulates and repaints at 60 Hz forever
- `PipewireService.qml:104` **pipewire-poll-never-gated** — PipewireService rebuilds five categorised node arrays every 750 ms, unconditionally, for lists only the popup reads
- `PhaseRail.qml:686` **phaserail-particles-outlive-popup-close** — The rail's orbit swirl keeps emitting and simulating when the update popup is closed mid-run
- `AudioLevelMeter.qml:56` **audio-meter-ticks-through-silence** — The level meter's 60 Hz envelope tick keeps running when the input and both envelopes have already reached zero
- `BatteryData.qml:89` **battery-dead-threshold-poll** — A `cat` process is forked every 3 s to fill two properties nothing in the repo reads
- `BatteryData.qml:81` **battery-fork-per-poll** — sysfs is read by forking `cat` once a second instead of a FileView
- `GooeyEngine.qml:778` **gooey-content-never-unloaded** — Popup content is instantiated on first open and never unloaded or told it is off-screen
- `SquishItem.qml:101` **squishitem-idle-ticker** — SquishItem's physics ticker runs at 62.5 Hz forever whenever usePath is false
- `PipewireService.qml:104` **pipewire-750ms-forever-poll** — A 750 ms timer rebuilds five node arrays for the life of the session, whether or not the audio UI exists
- `bar_in_progress.qml:65` **fullscreen-transparent-panel** — The bar is one full-screen transparent layer surface per monitor, which blocks direct scanout
- `PhaseRail.qml:766` **chase-timer-ticks-for-nothing-while-unsettled** — chaseTimer keeps waking at 32 ms for the whole of a creeping phase, writing 0 to _attractor.chase every tick
- `SquishItem.qml:104` **squish-physics-ticker-never-idles** — Free-mode physicsTicker runs at 62.5 Hz for the item's whole lifetime, and its never-quite-zero _angVel keeps the contour rebuilding and the canvas repainting for ~90 s after the last movement
- `PhaseRail.qml:687` **particle-gates-ignore-visibility** — Every particle gate in the rail keys on `active`, never on the rail being visible
- `ParticleSystem.qml:148` **hasparticles-cleared-only-in-onpaint** — The liveness flag that gates the 16 ms timer, the bloom and the layer FBO is only ever cleared inside onPaint
- `MonthWeekRow.qml:497` **dot-fade-runs-on-offscreen-tiles** — Every mark dot runs a 150 ms fade-in on creation, including dots in the two tiles parked outside the viewport
- `SystemUpdatePopup.qml:803` **recompute-while-popup-closed** — The whole summary/category/row pipeline keeps running for the entire duration of a background update while the popup is closed and off screen
- `SquishItem.qml:104` **squishitem-idle-physics-ticker** — SquishItem's 60 Hz physics Timer runs forever in free mode, whether or not the ball has moved or is visible
- `Workspaces.qml:625` **workspaces-bloom-not-gated-on-particles** — The sparks bloom MultiEffect is gated on the feature flag, not on particles existing, so it blurs a blank canvas
- (RESOLVED 2026-09-22: the overlay is gone; `ParticleLayer` gates its layer and glow on live particles and needs no mapping) `BatteryParticleOverlay.qml:172` **battery-particlelayer-layer-always-on** — The battery particle layer's FBO + masked bloom is enabled unconditionally, not gated on particles existing
- `AudioLevelMeter.qml:58` **audiolevelmeter-envelope-never-settles** — The level meter's 60 Hz envelope timer runs whenever `active`, and its exponential decay never reaches zero, so it relayouts a zero-width bar forever
- `GooeyEngine.qml:781` **gooey-loader-never-unloaded** — Popup content is never unloaded: once opened, a module's timers, animations and bindings keep running behind opacity 0 forever
- `PipewireService.qml:104` **pipewire-750ms-poll** — Pipewire node lists are rebuilt by a 750 ms poll that runs whether or not any audio UI exists

### layout (12)

- `ShadowBox.qml:185` **radii-nine-evaluations-per-resize** — Corner radii are recomputed nine times per geometry change through a diamond of five bindings and four JS calls, then usually collapse to the same vector4d
- `MockupPanel.qml:79` **hidden-pages-relayout-on-splitter-drag** — All nine tab pages are anchored to fill the panel, so a splitter drag re-lays-out ~150 rows of hidden pages every frame
- `TerminalView.qml:228` **switch-catchup-single-block** — The view-switch catch-up appends the entire backlog as ONE `insertHtml`, producing one giant QTextBlock that defeats QQuickTextEdit's per-block scene-graph culling for the rest of the session
- `TerminalView.qml:355` **nowrap-contentwidth-churn** — With wrapping off, the tail's `contentWidth` drives a Column re-position and a Flickable contentWidth change on every flush
- `UpdateCategorySection.qml:529` **view-switch-rescales-every-instantiated-row** — A view switch re-derives every scaled dimension and re-lays out every Text in all 182 instantiated rows so that ~12 visible ones can change size
- `PhaseRail.qml:938` **hidden-labels-still-relayout** — The label Repeater's Text delegates re-run their layout and elide on every resize frame even when _showLabels is false and nothing is drawn
- `AppointmentRow.qml:139` **appointment-row-hidden-metric-texts** — Two hidden Text items per appointment row re-measure the same two constant strings in every row
- `SystemUpdatePopup.qml:2101` **resize-relayouts-clipped-rows** — Every row in the list re-elides its text on every frame of the mode-switch resize, including the ~85% that are clipped out of the viewport
- `SystemUpdatePopup.qml:2009` **terminal-scrollback-flush-in-switch-frame** — Switching to verbose lays out the entire hidden terminal scrollback in the same frame as the list relayout, when only the last ~40 lines are on screen
- `SystemUpdatePopup.qml:2104` **downloadstats-slot-remeasure-invisible** — The list-scale change re-measures every row's DownloadStats slot table, including for the rows whose stats block is invisible
- `SystemUpdatePopup.qml:1716` **prompt-banner-relayout-while-shut** — The prompt banner's column relayouts on every frame of every popup resize even though the banner is shut for almost the whole run
- `SystemUpdatePopup.qml:1608` **phaserail-relayout-while-hidden** — The phase rail is fully laid out on every resize frame while it is invisible, which is the popup's whole idle life before the first run

### allocation (55)

- `SystemUpdatePopup.qml:628` **progress-info-fanout** — _progressInfo() is a fresh object-allocating function call evaluated seven separate times per parser property change
- `SystemUpdatePopup.qml:479` **live-regex-churn** — _dotsNeeded runs three regex tests per operation change, and _live() allocates a String and a match array per tick for texts with no ellipsis
- `SystemUpdateHelperDriver.qml:356` **helper-progress-string-churn** — The two highest-frequency helper events allocate a fresh RegExp and rebuild constant strings on every tick
- `SystemUpdateHelperDriver.qml:449` **helper-lines-model-unbounded** — linesModel grows without limit on aur.makepkg.line, unlike TerminalBackend which caps its scrollback
- `MonthWeekRow.qml:395` **calendar-mark-shadowboxes-always-instantiated** — 378 multi-day-line ShadowBoxes (each a ShaderEffect + ~24 uniform bindings) are instantiated per calendar, nearly all permanently invisible
- `IconButton.qml:257` **iconbutton-debug-swatch-always-built** — The debug mask swatch and its ShaderEffectSource are instantiated on every IconButton, debug or not
- `ShadowBox.qml:280` **shadowbox-spare-container-item** — Every ShadowBox allocates a content-holder Item with anchors even though most instances have no content
- `ShadowBox.qml:85` **easing-array-literals-per-instance** — Two JS array literals are allocated per ShadowBox instance for easing curves no production host ever overrides, then converted through four QJSValue index reads each
- `IconButton.qml:244` **iconbutton-dead-color-behaviors** — Two of IconButton's three ColorAnimation Behaviors can never fire with the shipped defaults
- `DownloadStats.qml:215` **linewidth-array-churn** — _lineWidth allocates an array, a filtered copy and two closures, and is called twice per re-evaluation
- `DownloadStats.qml:200` **fm-font-read-per-slot** — `const f = fm.font` is read eight-plus times per re-measure purely to register a dependency, materialising a QFont wrapper each time
- `DownloadStats.qml:131` **totalmult-object-literal** — _totalMult allocates a five-key dictionary to do one lookup, duplicating Bytes.js's own multiplier table
- `TipRow.qml:38` **tiprow-eager-construction** — Each of ~170 rows builds a TextMetrics, a FontMetrics and a full ToolTip (Popup + Text + Rectangle) at load, for a tip almost none of them will ever show
- `MockupRegistry.qml:129` **modifiedcount-iterator-allocation** — modifiedCount()'s nested for-of allocates an iterator and a result object per entry
- `MockupPanel.qml:41` **tablists-alloc-per-pill** — Each tab pill rebuilds its list-id array from scratch on every re-evaluation of its mark
- `TipRow.qml:45` **fontmetrics-per-row-for-a-constant** — A FontMetrics per row exists only to compute one number that is the same for all ~170 rows
- `TerminalView.qml:412` **disabled-input-row-constructed** — The input row, its four Controls Buttons and the prompt banner are fully constructed even when the host disables all of them
- `Theme.qml:345` **settoken-json-roundtrip-per-keystroke** — `setToken` deep-clones the whole theme document through JSON and re-resolves all 51 tokens for a one-token edit, on every keystroke
- `Theme.qml:398` **parseall-rebuilds-tokennames** — `_parseAll` calls `Object.keys(root.defaults)` instead of the cached `tokenNames`, unlike every other 51-token walk in the file
- `Theme.qml:318` **baseof-dead-api-allocates-rawmap** — `baseOf()`, `common` and `ready` are dead public API; `baseOf` in particular builds a full 51-key raw map per call, which is the shape that bites if a panel ever binds it per row
- `UpdateCategorySection.qml:884` **reconcile-double-get-per-row** — The reconcile loop fetches the same model row three or four times per target row
- `TerminalBackend.qml:905` **parse-char-append** — _parseAnsiLine accumulates literal text one character at a time (charAt + string +=), ~2 V4 heap allocations per input character
- `TerminalBackend.qml:494` **tailbuf-qstring-flatten** — _tailBuf is a QML `property string`, so `+= chunk` flattens the whole rope into a fresh QString on every chunk
- `TerminalBackend.qml:1098` **logwriter-pending-quadratic** — The log writer accumulates into a QML string property, so each append flattens everything buffered since the last 200 ms flush — quadratic per window
- `TerminalBackend.qml:1036` **html-escape-char-loop** — _htmlEscape walks every character of every rendered row in JS, although the whole 9 MB transcript contains no `&` and no `<`
- `TerminalBackend.qml:614` **clone-state-redundant** — _cloneState is called before every _parseAnsiLine that must not advance the carry — but _parseAnsiLine already snapshots and never mutates its argument
- `TerminalBackend.qml:710` **isnoise-regex-per-row** — _isNoise evaluates a regex literal for every row because the two cheap string comparisons fail for all real output
- `TerminalBackend.qml:683` **cr-strip-substring-loop** — Trailing carriage returns are stripped one at a time, each iteration copying the entire row; the same loop is duplicated three times
- `TerminalBackend.qml:668` **touched-delete-dictmode** — _flushRows deletes keys from the coalescing map, pushing the object into V4 dictionary mode for the rest of the chunk
- `TerminalBackend.qml:1057` **html-prefix-per-row** — _segmentsToHtml rebuilds the constant wrapper prefix and reads the fontFamily property on every row
- `TerminalBackend.qml:831` **parse-closure-per-call** — _parseAnsiLine allocates a capturing arrow-function per call in addition to its state object and segments array
- `TerminalBackend.qml:999` **color256-per-call-allocations** — _color256 allocates its steps table per call and _rgbHex allocates a closure per call
- `Workspaces.qml:642` **paintkey-stringifies-static-arrays** — Canvas repaint keys JSON.stringify five to six arrays, of which all but one are immutable config
- `Workspaces.qml:881` **workspaces-pathfunc-triple-eval** — The ball's contour sampler evaluates _ballXYAt about 100 times per frame, two thirds of them thrown away
- `ParticleSystem.qml:72` **particles-perframe-allocation** — Every painted frame allocates a filtered array, two colour arrays per particle, and a formatted rgba() string per particle
- `Workspaces.qml:330` **workspaces-spark-colour-roundtrip** — Each emitted spark converts two QML colours to strings so ParticleSystem can parse them back
- `ParticleSystem.qml:79` **particle-paint-loop-allocations** — The particle paint loop allocates two arrays, a template string and (in update) a history object per particle per frame
- `SquishItem.qml:519` **ball-canvas-size-churn** — The ball Canvas is resized from the contour's bounding box, so its backing image is reallocated and re-uploaded on most frames of a travel
- `PhaseRail.qml:866` **tone-restringified-per-emitted-particle** — Every emitted particle re-converts _tone to a string and re-parses it back into an RGBA array
- `GrooveTrack.qml:83` **paintgroove-rebuilds-helpers-per-paint** — _paintGroove re-creates its two helper closures, its band array and 21 Qt.rgba colours on every paint of every canvas
- `MonthWeekRow.qml:395` **line-mark-shadowbox-always-instantiated** — 378 ShaderEffect-backed ShadowBoxes are built for multi-day line slots that are almost never lines, and their colour bindings re-run on every tile rebuild
- `MonthWeekRow.qml:424` **extra-dot-slot-always-instantiated** — The truncated-line 'extra dot / +' slot builds 4 items in every mark slot, for a state that needs three full lanes plus a single event on the same day
- `MonthWeekRow.qml:110` **daystatus-allocates-today-per-cell** — _dayStatus allocates two Dates per cell, one of them a re-derivation of the unchanging `today`
- `AppointmentRow.qml:255` **shape-curverenderer-per-appointment-row** — A CurveRenderer Shape is built in every appointment row, including rows that can never show the separator line
- `ical.js:193` **ical-rawblock-is-dead-weight** — The parser rebuilds every VEVENT's raw text as a string and stores it on the event; nothing ever reads it
- `CalendarService.qml:273` **marks-and-day-caches-never-evicted** — The three query caches grow with every month visited and are only ever cleared wholesale on a feed change
- `PackageUpdateParser.qml:506` **progressrow-ansi-strip** — _progressRow runs a global ANSI-strip regex on every row, but ~77 % of rows were already ANSI-stripped by TerminalBackend
- `PackageUpdateParser.qml:466` **prompt-tail-dead-strip** — processPromptTail runs a dead ANSI-strip plus a trim on every PTY chunk before the cheap anchored test rejects it
- `PackageUpdateParser.qml:524` **regex-literals-per-call** — Every regex in the per-row hot path is a literal inside the function, so a RegExp object is allocated on each evaluation
- `PackageUpdateParser.qml:507` **trailing-ws-regex** — Trailing-whitespace trim done with an unanchored /\s+$/ regex on column-padded rows
- `PackageUpdateParser.qml:718` **noteline-dead-strips** — _noteLine and processLine strip ANSI from a string TerminalBackend already stripped — three dead regex passes per committed line
- `particles.js:136` **particles-per-particle-per-frame-allocation** — Every particle allocates four objects/arrays and a formatted colour string per frame
- `GrooveSlider.qml:1215` **grooveslider-paintkey-string-per-frame** — A 34-element array is built, stringified and joined every frame of a slider drag just to decide whether to repaint
- `Workspaces.qml:642` **paintkey-json-stringify-static-arrays** — Canvas paint keys JSON.stringify static easing/geometry arrays on every colour change, including every frame of a theme fade
- `Workspaces.qml:290` **workspaces-ballxy-object-per-frame** — Three var-object bindings on the ball's position allocate four objects and run three bezier solves per frame

### redundant-work (63)

- `SystemUpdatePopup.qml:3070` **stepstatus-hot-path** — _stepStatus reads the _stateRank var property twice per call, and the per-section arrow adds a _currentStep property read, on the hottest per-package path in the run
- `SystemUpdatePopup.qml:875` **step-change-rewalks-model** — Every step transition re-walks all 212 packages to recompute counts that cannot have changed, only to reorder at most six categories
- `SystemUpdatePopup.qml:756` **dead-name-read** — _recomputePackageSummary reads p.name into a variable that is never used
- `SystemUpdatePopup.qml:1125` **dead-status-color** — _statusColor is a dead binding that re-evaluates on every frame of a theme crossfade
- `SystemUpdatePopup.qml:803` **double-count-connections** — Two separate Connections objects watch parser.packages.onCountChanged, doubling the dispatch on every package append
- `AvailableUpdatesService.qml:297` **fav-toggle-rebuilds-whole-model** — Every favourite toggle triggers a full model clear+rebuild through onFavoritesChanged, exactly the churn _markAndReposition was written to avoid
- `AvailableUpdatesService.qml:699` **refresh-sorts-and-rebuilds-twice** — _finishSource calls _reorder() immediately after _commitStaged(), re-sorting and re-appending the model that was just built sorted
- `AvailableUpdatesService.qml:293` **parsefavorites-reorders-twice** — _parseFavorites calls _reorder() explicitly after an assignment that already reordered through onFavoritesChanged
- `AvailableUpdatesService.qml:360` **markreposition-dead-recompute** — _markAndReposition ends with a _recomputeCategories() whose result is always discarded
- `AvailableUpdatesService.qml:233` **loadcache-appends-then-rebuilds** — _loadCache appends every cached row into the live model, then _reorder() clears it and appends them all again
- `AvailableUpdatesService.qml:587` **commitstaged-carry-loop-always-runs** — _commitStaged walks the entire existing model looking for rows from failed sources even when no source failed
- `MonthWeekRow.qml:194` **selector-drawn-six-times** — The calendar selector ShadowBox is drawn six times per frame at the same absolute position; five are clipped away to nothing
- `MotionBlur.qml:51` **motionblur-captures-whole-list-content** — MotionBlur's capture is sized to the whole source item, so the popup's list blur renders the entire scrolled content height into an FBO of which only the viewport is ever seen
- `TabSelector.qml:372` **tabselector-basewidth-echo** — The TabSelector track feeds its own anchored width back into baseWidth, so implicitWidth/implicitHeight are recomputed every resize frame and discarded
- `UpdatePackageRow.qml:261` **faint-stripe-recomputed-per-row** — _faintStripe does three RGB→HSL conversions plus an hsla build per row for a value that is identical across every row of a category
- `DownloadStats.qml:118` **widedigit-remeasured-per-instance** — _wideDigit measures all ten digits with FontMetrics per instance, and re-measures every slot on any font or scale change
- `UpdateCategorySection.qml:209` **parserate-round-trip-per-recount** — Bytes.parseRate re-parses the same rate string for every active row on every recount — and for AUR rows the number was thrown away to make that string in the first place
- `MockupPanel.qml:27` **modified-count-fanout** — Five independent bindings recount the same modified-state over the whole registry, each capturing every registered property as a dependency
- `MockupTabPage.qml:35` **hidden-page-counts** — All 9 tab pages and the hidden Profiles page keep counting their modified values while only one page is on screen
- `MockupRegistry.qml:104` **colormodified-scan-before-themed-exit** — colorModified() does the defaultOf scan before the themed early-out, so 49 rows that always answer false pay for the lookup anyway
- `MockupRegistry.qml:121` **entrymodified-per-entry-lookups** — entryModified() resolves the list's target and kind per entry instead of per list
- `TerminalView.qml:234` **tail-rebuilt-whole** — The 65-row live tail is rebuilt, re-compared and re-parsed in full every flush when only one row changed
- `TerminalView.qml:279` **redundant-previewupdated-sync** — `onPreviewUpdated` calls `_syncOutput()` for a model change that has already called it
- `TerminalView.qml:238` **totail-called-three-times** — `_toTail()` runs two or three times per flush; only the last one can do anything
- `ColorList.qml:54` **colorlist-syncs-hidden-tabs** — Every colour row of every control-panel tab re-formats its hex string and writes a TextField on each fade frame, including the ~29 rows sitting on tabs that are not on screen
- `Theme.qml:773` **startup-double-parse-quadruple-apply** — Startup parses the theme JSON twice, runs the full 51-token resolve twice, and throws away two complete `_parseAll(defaults)` passes — all on the blocking path that must produce the first painted frame
- `Theme.qml:484` **snapshot-when-mix-is-one** — `_apply(true)` always lerps a 51-token snapshot, even when `_mix` is 1 and the snapshot is a verbatim copy of `_toC`
- `UpdateCategorySection.qml:183` **recount-scans-whole-transaction-per-section** — _recountStep walks the entire 218-package transaction in every section every 120 ms, including sections the current step excludes outright
- `UpdateCategorySection.qml:371` **end-flight-scans-past-the-phantom** — endFlightGap scans the whole model for a phantom it already has the index of, and keeps scanning after removing it
- `UpdateCategorySection.qml:1001` **close-writes-both-roles-for-every-row** — _close writes staggerIdx and rowState for all 182 rows including the ~85 that already hold exactly those values
- `AnimatedListRow.qml:155` **holder-dead-implicit-height-binding** — holder.implicitHeight is bound to childrenRect.height but nothing ever reads holder's height
- `TerminalBackend.qml:749` **preview-full-tail-reparse** — _updatePreview re-parses the entire retained tail char-by-char on every chunk; 99.88% of it is thrown away by the CR reset
- `TerminalBackend.qml:576` **preview-split-discarded** — The progressPreview string is split/sliced/joined on every chunk but the 120 ms throttle discards 80% of them unread
- `TerminalBackend.qml:718` **double-parse-committed-line** — Every newline-terminated line is ANSI-parsed twice and rendered to plain text twice, then _isNoise-tested twice
- `TerminalBackend.qml:688` **html-for-rows-never-shown** — HTML is built for every in-place row rewrite, including the ~99% that are overwritten before any frame paints them, and while the view is hidden
- `ChargeLimitData.qml:90` **charge-threshold-polled-twice** — Two independent 3 s pollers `cat` the same sysfs file, and the second one has no polling gate at all
- `ClockBarButton.qml:42` **clock-formats-both-orientations** — The bar clock formats three strings and lays out two hidden Text items every minute, when only one orientation is ever shown
- `GooeyEngine.qml:112` **gooey-dead-transition-pulse** — globalTransitionPulse is written, timed and cleared, and read by nothing
- `GooeyMask.qml:23` **gooey-mask-dead-regions** — The input mask carries four permanently zero-sized Regions and 40 bindings that all re-read barsList
- `BatteryEventFX.qml:87` **battery-eventfx-identity-pass** — The bar's battery icon is permanently routed through an FBO and a 528-triangle distortion mesh for four rare events
- `particles.js:180` **particle-update-scans-whole-pool** — update() calls Particle.update on all 260 pool slots every tick, and getActiveParticles() allocates a filtered array plus a closure every paint
- `GrooveTrack.qml:163` **groove-base-canvas-repaints-on-fill-only-changes** — One _paintKey mixes base-canvas and fill-canvas inputs, so the base groove is fully re-rastered on every frame of the 900 ms tone fade even though none of its three colours changed
- `GrooveTrack.qml:167` **paintkey-stringifies-constants** — _paintKey runs three JSON.stringify calls on every evaluation, two of them over arrays that never change
- `PhaseRail.qml:925` **hidden-label-colour-behaviors** — Each label's two 240 ms colour fractions animate on every step change even when the labels are not shown
- `CalendarFeed.qml:164` **expansion-window-restrings-the-ics-for-nothing** — Every month step materialises both feeds' whole ICS as JS strings four times, then bails out of the re-expansion it exists to do
- `MonthWeekRow.qml:172` **cell-date-computed-twice-per-column** — Each column's date, in-month test and is-today test are computed twice — once by the day-number layer, once by the day-cell layer
- `CalendarConfig.qml:60` **calendar-config-parsed-two-or-three-times-at-startup** — calendars.json is parsed by three separate paths on load, and each reassignment of `entries` tears down and rebuilds every CalendarFeed
- `PackageUpdateParser.qml:495` **preview-rows-reparsed** — processProgress re-parses the same progress rows every 120 ms — 40 % are exact duplicates inside one call, 81 % were already handled by the previous call
- `PackageUpdateParser.qml:683` **current-downloading-supersede** — currentDownloading is rewritten once per download row inside a batch — 76 % of the assignments are overwritten before any frame is drawn
- `PackageUpdateParser.qml:350` **update-per-key-setproperty** — _update fires one setProperty (one dataChanged) per key of the data dict
- `PackageUpdateParser.qml:512` **total-row-unanchored-regex** — _readTotalRow's unanchored 'Total (' regex is tried on every progress row before the per-package pattern
- `PackageUpdateParser.qml:695` **parsesize-double-regex** — _applyDownloadRow re-parses with a regex the byte string the row pattern just captured
- `PackageUpdateParser.qml:699` **date-now-per-row** — Date.now() called once per download row when once per batch would do
- `PackageUpdateParser.qml:650` **trunccache-miss-not-cached** — _resolveTruncated does not cache the 'not truncated at all' miss, so an unmappable filename re-runs the check on every repaint
- `PackageUpdateParser.qml:251` **exclude-remove-one-by-one** — excludeSelection and skipContextPackages remove rows one at a time, firing a model signal storm per removal
- `SystemUpdatePopup.qml:191` **skeleton-probes-churn-while-invisible** — Four hidden probe Texts and the whole ListSkeleton re-measure on every mode switch and re-position on every resize frame, while invisible
- `SystemUpdatePopup.qml:3334` **redundant-preferred-height** — `Layout.preferredHeight: implicitHeight` on the category delegate is a redundant binding and an extra layout invalidation per section per animation frame
- `SystemUpdatePopup.qml:756` **dead-name-read-per-package** — `_recomputePackageSummary` reads a ListModel property per package and throws it away, and re-reads `m.count` and `p.isAur` every iteration
- `SystemUpdatePopup.qml:2210` **gesturehold-dead-bindings** — `gestureHoldWidth` / `gestureHoldHeight` re-evaluate on every frame of every resize and nothing in the repo reads them
- `GooeyEngine.qml:925` **gooey-getedgemetrics-recomputes-open-geometry-4x** — getEdgeMetrics recomputes the identical open-popup geometry block four times per frame, once per edge
- `Workspaces.qml:330` **workspaces-emit-parses-colour-per-particle** — Spark emission stringifies and re-parses the same two colours, and allocates a fresh closure, once per particle instead of once per burst
- `PhaseRail.qml:302` **phaserail-xat-recomputed-twice-per-frame** — ballInSlot and ballInSlotTight recompute the identical notch pixel positions on every frame the ball moves
- `ClockBarButton.qml:42` **clockbarbutton-builds-both-layouts** — The clock formats and re-lays-out the layout it is not showing on every minute change

### io (11)

- `AvailableUpdatesService.qml:407` **shell-writes-instead-of-fileview** — Both file writes fork a shell pipeline (sh -c 'mkdir && cat > tmp && mv') where the rest of the codebase uses FileView.setText with atomicWrites
- `SystemUpdateLogger.qml:69` **logger-double-mkdir** — _ensureDir spawns a mkdir process at construction and again at the start of every run, for a directory that already exists after the first
- `PackageUrlOpener.qml:78` **urlopener-exec-chain** — A link click spawns sh -> timeout -> env -> pacman where timeout -> pacman would do
- `MockupStore.qml:218` **profile-listing-second-python-spawn** — Startup spawns python3 twice: once to write the derived default profile, then again to list the directory the first call already had open
- `MockupWindow.qml:172` **mkdir-spawn-every-launch** — A mkdir process is spawned at every launch for a directory that exists after the first one, and that is only needed if the zoom is ever changed
- `Theme.qml:549` **state-file-self-write-echo** — The state file has no self-write guard, so every mode toggle pays a synchronous disk read and two extra JSON parses — 150 ms into the crossfade
- `BatteryData.qml:81` **battery-uevent-cat-per-second** — Battery state is read by fork+exec'ing `cat` once a second, all day
- `AvailableUpdatesService.qml:487` **update-probes-spawn-login-shells** — Every update probe runs through `bash -lc`, sourcing the full login-profile chain three times per poll
- `AvailableUpdatesService.qml:241` **update-cache-rewritten-every-poll** — The updates cache is re-serialised and rewritten through a four-process shell pipeline on every poll, even when the row set is identical
- `AvailableUpdatesService.qml:199` **update-poll-runs-three-probes-regardless** — The 15-minute update poll runs three subprocesses and two network round-trips forever, with no gating on lid, lock or power source
- `CalendarFeed.qml:92` **ics-cache-rewritten-on-every-poll** — The disk cache is rewritten every poll even when the fetched ICS is byte-identical


## Phase 2 of the perf pass (the night of 2026-11-01..02)

`perf_pass/PHASE2.md` has the tables. In one line each, nested Hyprland at 120 Hz, the user's scale path, three interleaved reps:

- **One exposed window** (`HyprReserve`, the OSD pill mapped on demand): 87 fps with 38 % double steps -> 120 fps with none (S11, `tools/dev/perf/clock_steps_gate.sh`).
- **`QV4_GC_TIMELIMIT=2`**: popup motion 15.1 -> 5.3 misses per 1000; a forced `gc()` at rest measured nothing and was dropped.
- **Incubated prebuild**: hover sweep 38.3 worst 53 ms -> 20.1 worst 25.
- **A journey builds before the flight**: largest mid-flight tick 41-56 ms -> 8-22; the click's first frame pays instead.
- **The audio popup at rest**: 200 frames in 4 s at 11 ms of polish -> none. The cost was the slider balls' software shadow, not the patch lines (ablated); laid out at its asked size nothing moves them.
- **PipewireService** follows `valuesChanged`: 1.33 wakeups/s -> 0, by construction (no real-service number).
- **Measured worthless and dropped**: `parkPinned` on weather (worse: it keeps the prewarm's every card) and silicon (nothing).

## The performance pass of 2026-11-22..23 — asked of the user's own frame journal first

The user's item: "one gigantic performance pass ... a prime candidate are the lock veils", cost at rest and the smoothness of
interactions first, only changes that leave pixels and motion identical. Run on the DESKTOP (a 6-core desktop CPU, one mid-range NVIDIA card, 3440x1440@120):
the laptop's own modules (silicon, the battery, the OLED care) were read from the code, not measured.

**The method that worked: the real session's records, then Qt's own instruments, then one stream per thing they named.** A
70-unit read-the-code audit was started and stopped (far too costly); nothing in this section came from it.

| instrument | what it answered |
|---|---|
| `tools/dev/perf/frame_journal_report.py` on the user's journal (119 000 frames) | 117 frames missed per 1000; the groups, by frames missed |
| `tools/dev/perf/frame_split.sh` (new) | per frame of the nested mock shell: Qt's polish / sync / render / swap and the GUI thread's ms (`QSG_RENDER_TIMING`), by scenario |
| `frame_split.sh PROFILE=1` + `qml_profile.py` (new) | Qt's QML profiler attached to the shell: JS functions, bindings and handlers by self time |
| `tools/dev/perf/shell_rest_sampler.sh` (`--trial`, `--private`, and a plain pid) | the shell's, the mock's and the SUPERVISOR's CPU at rest |
| `tools/dev/perf/shell_mem.sh` (new) | the settled mock shell's memory by ablation |
| the field-shape differential, the veil harness (new, below) | a change proved bit for bit / pixel for pixel, and timed where it runs |

### What the journal's worst groups were

- **"no known motion", 42 % of all missed frames (5 800 of 13 900): the GPU's idle clock, not the shell.** 216 of 277 such records
  start 50 ms after a MINUTE boundary (the bar clock's roll) and are 200-350 ms of frames exactly 25 ms apart, after which the same run
  draws at 8 ms. Nested, the roll is 40 frames at 8 ms with under 1 ms of GUI time. A passive watch (nvidia-smi 0.7 s before each minute,
  the journal after it): the stutter is recorded when the NVIDIA card sat in P8 / P5 (210-435 MHz) and not when it sat in P0 / P2
  (1837 MHz), 12 minutes of 13. The journal classes it `gui` because the GUI thread is blocked waiting for the swap: on this machine
  that class also means "the GPU or the compositor was slow". "islands moving" (the second group) costs ~0 ms of GUI time per frame nested
  and falls on a focus change, the same moment the GPU wakes.
- **Every motion: `GooeyGeometry.fieldShape`.** The profiler, in a popup's open and close, three toasts, the launcher and the audio
  popup alike: `GooeyEngine.layout -> GooeyField._update -> fieldShape` is 60-80 % of all QML/JS time, once per frame and again whenever
  the field's `relax` clock runs.

### Fixed

- **The supervisor's loop: 0.97 % of a core at rest -> nothing between pings.** `lares-supervise` turns every 0.5 s; a turn was an
  external `sleep`, two `$(now_ms)` and three `$(pid_state)`: 2 execs and ~10 forks a second, 170 ms of its own CPU and 410 ms of
  reaped children a minute (the whole quickshell process took 0.9 %). It is a sibling of the shell, so no sample of the shell's children
  showed it. Now: bash's loadable `sleep`, `now_ms_into`, a `pid_alive` that reads /proc itself. `lares_watchdog_probe.sh` phase `rest`
  (the reaped children's page faults stand still for 6 s between two pings; ARM `forkloop`).
- **`fieldShape` at 0.38 of its cost, bit for bit.** 0.934 -> 0.352 ms a call in QV4 over 7 189 recorded calls (per class 0.31-0.46);
  the GUI thread's animation time per frame of the clock popup's open 1.19 -> 0.50 ms, its worst frame 13 -> 5 ms; three toasts' worst
  frame 30 -> 10 ms. The cost was QV4's price list, not the geometry: a `for...of` step ~490 ns against ~30 for a counted loop, a
  closure created ~300 ns, an array literal ~120, a call of a function of the same file ~60 against ~35 through a local name. Counted
  loops, no closures or arrays per step, helpers that read the box directly, insertion sorts for the tiles, and the 43 functions the
  body calls handed in as locals. Proof: the real engine's inputs recorded (`field_shape_record.sh`: every popup, interrupted toggles,
  travels, secondaries, toasts, the OSD; islands, the continuous bar at 1.25, the border with its halo) and replayed through the old
  and the new file, every output, the state and the inputs compared as canonical JSON: 0 of 7 189 differ in node and in QV4; armed
  (`FS_ARM=const|order|state`) 7 137 / 7 137 / 7 189 differ.
- **The lock veils' slot bindings run only when a pulse lives.** Each veil hands 16-32 pulse slots to its shader, each a binding on
  one `var` that was a fresh object every tick: with nothing alive (the common case) the slots now read one constant object. GUI time
  per tick 29-86 us -> 5-68 us (dimples 54 -> 8, louvres 44 -> 5); 0 px differ over 105 jobs x two modes x two sizes, 1 741 928 when armed.

### Measured, and what it says

| | |
|---|---|
| the shell at rest, live (the desktop, nobody at it) | ~0.2 % of a core on the GUI thread; children: two 15 s polls (~30 ms a fire: `ContentHold`'s `hyprctl -j clients` + `busctl`, `ThermalNotifier`'s `sh` + `grep`), the update check every 15 min (~770 ms: three login shells, `checkupdates`, `yay`, `flatpak`) |
| the mock shell at rest, two screens | 0.6 % of a core, 0 frames, 0 forks |
| a veil's frame on the desktop's NVIDIA card at 1837 MHz | 0.25-0.48 ms of GPU beyond a 0.17 ms floor at 3440x1440 (relief 0.47, keycaps 0.41, paper 0.34, dials 0.29, louvres 0.28, gooey 0.25, dimples 0.25); the whole lock window 0.60-0.82 ms; at the idle clock several times that |
| the lock at rest (after `idleSeconds`) | 0 frames, every veil, with the shell beside it and without |
| a veil's first frame, cold shader cache | keycaps 1.25-1.37 s, louvres 1.19-1.22 s, dimples 0.99-1.12 s, relief 0.34 s, the others ~0.1 s; warm 2-4 ms. `lares deploy` and every unlock warm it, so cold is a driver update or a machine never warmed |
| popups that draw while merely open | theme 120 fps (its strands, by design), silicon 64, aerial 39, weather 30, audio 30 while sound flows (the patch bay's canvas), panorama 20, the LLM's caret 2; clock, notes, update, notifications, bridge, launcher, picker, the tray 0 |
| the settled mock shell's memory | ~847 MiB resident; the start-up prewarm holds ~260 MiB of it (583 without), silicon ~65, transparent huge pages ~55; two starts of one tree differ by up to ~40 MiB |
| what the prewarm buys | without it the first open stalls the render thread: weather 332 ms, bridge 485 ms, aerial 3.2 s (cold cache), clock 15 ms |

### Found and left (with the number)

- A SECONDARY TALLER THAN ITS PRIMARY KEEPS ITS CLIP LAYER ON AT REST, so a tick of its content is two window frames (the wiki
  session: a 24 Hz veil at 47.8 frames/s, 23.7 with the layer off). The term is the corner one of `GooeyEngine._applyClip`: the child's
  corner at the step is drawn at radius 23 against `rest` 20.5 (`ABL=cliplog`). Treating that as rest is not pixel-identical for a
  content that draws to its box's corner.
- A QUARTER OF ALL `fieldShape` CALLS REPEAT THE PREVIOUS CALL'S INPUTS (1 738 of 7 189: the relax clock and two calls in one frame);
  only the settle weights differ. A stateless part cached on exact inputs would skip most of it, bit-identically; structural, not begun.
  `layout()` outside fieldShape is now as dear as fieldShape (~0.4 ms a call under the profiler).
- THE COLD COMPILE OF KEYCAPS / LOUVRES / DIMPLES: the vertex shader's finite-difference gradient inlines the 32-pulse chain three
  times (96 call sites; relief has 32 and compiles in 0.34 s). With keycaps' two extra `fieldAt` calls removed: 1 174 -> 306 ms. An
  identical fix evaluates the three points in one chain; it needs the pixel proof in both GL variants and a look on Mesa iris.
- THE FIRST OPEN OF THE PLAYER (183 ms) AND OF SILICON (164 ms, prewarmed) STALL THE RENDER THREAD on a cold cache nested; the first
  launcher open creates one `AppIcon` Image in 19-20 ms (the first decode of its kind; the second open has none).
- The two 15 s polls and the update check's login shells (above): ~0.2 % of a core together. `ContentHold` is `modules/idle`'s.
- Laptop only, from the code: silicon's `Lsof` call every 5 s while the dGPU is awake in Hybrid, the battery's `uevent` (an ACPI
  `_BST`) every 5 s with the popup closed. `~/.cache/claude-orch/perf/rest_census.md` held the whole table (57 rows) for the night.

## Pass 2 — the laptop on the quiet profile and the iGPU (2026-11-23)

The user's bar: on `quiet` (no turbo, EPP `power`, cores resting at 400 MHz) and the Arc iGPU (i915; RC6 at rest, 800 MHz when woken)
Lares loads quick, is operable at once and never drops a frame in daily use; RAM last. Rule: identical pixels and motion first, a
visible trade only behind a switch that is off. Measured ON the laptop (Ultra 9 185H, eDP 2880x1620@120, Hyprland scale 1.25,
`scale.global` 1.25, halo + border on), nested (`lock_env.sh` draws on the real iGPU through Mesa) with the user's own shell.jsonc,
and read from the laptop's own frame journal. `~/.cache/claude-orch/perf2/COMMON.md` was the streams' brief.

### What the laptop said first

- **The journal (11 sessions, 199 000 frames, the code before pass 1):** 29-47 frames missed per 1000 in the good sessions. By group:
  the islands (title / focus) ~1150 missed, the OSD ~200, popups resting open (silicon, aerial, panorama) ~220, toasts / secondaries
  / reels ~300; ~1080 of all misses in a run's first 3 frames. After the journal's own artefacts were removed (below) the total
  "missed" fell from 273 651 to 5 217: one 37-minute locked gap had been counted as 268 434 frames.
- **The client's frame fits.** Nested, a popup's open and close, a toast, the OSD and the island motion hold an 8 ms cadence with
  1-3 ms of GUI time a frame (2-5 on closes: a close lays its content out on the live box) and 0-2 ms of render.
- **The island motion at 60 fps in the real session is the compositor's, not the client's.** In the journal's raw events the tick
  and the swap are 1 ms apart and the wait for the next frame callback is ~17 ms. Hyprland 0.57.2 damages a layer surface's WHOLE
  geometry at every commit (`CLayerSurface::onCommit` -> `damageBox(geomFixed)`; read in its source), Qt commits full damage anyway
  (`eglSwapBuffers`), and the bar window is one full-output surface: every shell frame is a 2880x1620 recomposite of the user's
  translucent windows, blur and shadows. A surfaceless GL test on this machine: a 120 Hz burst of six blended full-screen quads for
  333 ms ran at 800 MHz from the first frame to the last (~0.5 ms of GPU per full-screen blend; no clock-up inside a motion, no i915
  waitboost from `glFinish` / `glReadPixels`). It cannot be reproduced nested (headless outputs have no real vblank; Hyprland's
  `debug:overlay` "Rendertime" is CPU time, 1.0-1.5 ms with and without the decoration). The cures are the interaction boost and a
  smaller blend (`visibleInk`), and their proof is the user's own tour.
- **Pass 1 never measured the island motion:** the mock shell's title followed a mock, so `title:` / `focus:` drew no frame
  (`frame_split_ablate.py` `livetitle`, always applied now).
- **At rest (the real shell, 600 s, `shell_rest_sampler.sh --trial`):** 1.0 % of a core -- the GUI thread 0.66 %, reaped children
  0.25 % (cardwire's `Lsof` every 5 s while the dGPU reads D0, `hyprctl -j clients` and the thermal `grep` every 15 s).

### Start-up (nested mock shell, warm, medians of 4-5 interleaved runs; `tools/dev/perf/start_split.sh`)

The tree before the pass (`ea85711b`) against the final tree, interleaved, 5 rounds each (min-max in brackets):

| | before | after |
|---|---|---|
| "Launching config" -> first QML line | 4925 ms (4908-4935) | 1198 ms (1185-1201) |
| first QML line -> shown | 646 ms (631-690) | 186 ms (182-190) |
| shown -> ready | 493 ms (489-505) | 1 ms (1-6) |
| "Launching config" -> ready | 6071 ms (6028-6108) | 1384 ms (1372-1397) |
| the prewarm starts after ready | ~6 s (fixed) | 0.4-0.8 s (the shell idle) |
| the prewarm lasts (warm caches) | ~7 s | 3.4-4.0 s |
| `LARES settled` after launch | 19.1 s warm (the real logs: 20-22 s; 23-29 s with a cold shader cache) | 5.8 s |

- **The QML disk cache (4976 -> 1200 ms).** Quickshell loads the config on its `qs:` scheme and Qt's cache takes local files only: 2010
  refusals in one start, every file compiled every time. `shell.qml` is a stub that creates `modules/shell/ShellMain.qml` from a
  `file:` URL and imports no directory (Quickshell's scan of the tree was another 0.9 s). Cold (first start, writes the cache)
  4457 ms; `QML_DISABLE_DISK_CACHE=1` 4240; `fileRoot: false` 4967. A deploy keeps the cache: same content with new mtimes stays at
  1230 ms, one changed file recompiles alone (one checksum mismatch, 1245 ms). What is left of the 1.2 s: ~0.6 s loading ~1006
  cached units, ~0.3 s ShellServices, ~0.27 s the frame, owners and engine.
- **The bars' reserve (launch -> ready 2362 -> 1397 ms).** `hl.monitor reserved_area` stops the compositor ~0.5 s per rule and was
  sent twice around the first frame: with a frame's values that knows neither its bars nor its scale, then with the real ones
  (`WAYLAND_DEBUG=client`: Mesa's `wl_display.sync` answered 459 ms late, the first swap 496 ms). Sent once, when the frame is whole;
  adopted when the compositor already has it; cached, and sent by the next start's stub beside the load (`HyprReserve.qml`).
- **The prewarm** (`LARES prewarm ...` lines, `prewarm_report.py`): an idle gate instead of a fixed 6 s, incubated builds, a 150 ms
  beat, and a parked content holds it only while fresh (it used to stop for good behind the first popup used:
  `prewarm_stall_probe.sh`). Largest GUI block per entry, warm: notifications 33 -> 0-2 ms, panorama 15 -> 1, theme 66 -> 15,
  llm 56 -> 10; the first DRAWS stay: silicon ~720 ms, clock 196 (synchronous: pinned), aerial 170, weather 158, bridge 131. On a
  cold Mesa cache silicon's board alone is a 7.5 s compile.
- **Modules at start** (`start_split.sh new:warm:-<module>`): stocks -179 ms of ready (its caches read and computed before the first
  frame), weather -40, bridge -40, aerial -29, silicon -27; the rest within the noise. The popups' contents are 58 % of what is
  compiled (the owners name them by type): loading them by URL at first use is an estimated ~350 ms of load, not built.
- **The lock** (`lock_start_split.sh`): launch -> secure 469 ms; a `file:` root took 43 ms off, warm only. Built, measured,
  reverted: not worth a change to the process whose failure is a lockout. `lares-lock-warm` loads on `qs:` and primes no QML cache.
- `lares start` no longer waits for the geoclue agent in front of the supervisor.

### Built, off by default

- **The interaction boost** (`silicon.jsonc` `interactionBoost`, `lares setup` R6; docs/silicon.md): a root service of the silicon
  helper raises the iGPU's floor (`gt/gt0/rps_min_freq_mhz`, 1600 of [800, 2350]) and the CPU's (`min_perf_pct` 30) for the length
  of a shell motion and puts both back; the engine kicks it once per motion (`GooeyBody.run / runTo / runSlide`, the islands'
  `lenAnim`). Proved on the helper's fake sysfs (271 tests) and the fake root; its effect on the real session is the user's A/B.
- **`lares perf tour`** (`tools/shell/lares-perf-tour`; docs/shell.md): one fixed pass over the user's running shell, reported from
  the frame journal for its span; `--fresh` restarts first and tours right at `ready`, `--boost-ab`, `compare`.

- **`workarounds.visibleInk`** (shell.jsonc; docs/shell.md): the bar window's hyprland-surface visible region is its ink -- the edge
  bands at full length (so an island motion never changes it), every slot's box for its whole motion, any field tile outside those,
  12 padded rects -- and the whole window while anything draws outside the field (a theme switch, the lock, a glyph flourish, a float
  over fullscreen). `visible_ink_probe.sh`: 437 frames judged, no ink outside the region; armed (rects shrunk by the reach) 433 cut.
  Client cost +0.03-0.09 ms a frame; nested no measurable gain (GPU busy share 24.7 -> 24.0 %, inside the spread). Its theme
  crossfade path was not exercised (the mock's theme click does not crossfade).

### The pixels

`sheet_check.sh` against a baseline of the tree before the pass, 214 states: with the prewarm off in the sheet's copy **0 pixels
moved**. As shipped, the sheet's shell states are grabbed ~6 s after `ready`, where the old prewarm had not started and the new one
has: the weather popup's title "(" (3 px, both modes: the sheet's native glyph cache), 1 px of one level in the audio popup, and,
when a grab lands inside the warm-up, the prewarm stage's own 2 % ink in the window's corner (61 px, up to 6 levels; not repeatable).

### The real session, before (the user's tour, 2026-11-23 14:23, quiet, AC, snapshot `dd9d3190`)

29 actions in 101 s (the four key-opened popups, three toasts, title and focus changes, a workspace hop, the OSD): 38 stutters, 73
frames missed -- the OSD resting open 36, the islands 7 (+4 after them), toasts 11, notes 6, picker 4; first frames late: picker
113 ms, launcher 63 ms. The file is `~/.local/state/lares/perf/tours/20261123-142351-baseline.json`; the same tour after the deploy
is the comparison (`lares perf tour compare`).

### The journal's artefacts, fixed

A window that freezes (`updatesEnabled`) or remaps ends its run and drops a pending latency (the "osd:closing 485 ms / 8 s" and
"islands 8.9 s" records); `islands` is noted only when the lengths differ; the title morph is a known motion; the report leaves a
gap of a minute or more (or 5 s free) out of "missed" and has a RIGHT AFTER LOAD section and a span (`--since-ms / --until-ms`).

### Measured and left (with the number)

- The OSD's first frame: sparks, the slider's blur and its particles ablated change nothing (second gap 13-16 ms, a 6-9 ms render
  on the third frame either way); its content builds in 6-8 ms.
- Popups resting open cost their frame COUNT, not their frames: aerial 42 frames/s, silicon 62, weather 31, panorama 20, theme 120,
  each frame a full recomposite in the real session. Lower rates are visible trades (switches, not built).
- The wiki secondary builds synchronously in 61 ms inside an animation tick (a 72 ms hole).
- **Silicon's ~715 ms prewarm block is Mesa LINKING its programs, cache hits included** (`MESA_SHADER_CACHE_SHOW_STATS`: 138 hits,
  0 misses; a preload timer on the GL calls): four programs, 511 ms -- the board's fragment program (323 KB of GLSL) 220 ms, 176,
  92 and 23. With Qt's pipeline cache file Qt calls `glProgramBinary` per pipeline instead: 8 loads of 23-211 ms, ~713 ms -- no
  better. A second silicon entry in the same process blocks 1 ms: once per process, not per draw. The render thread burns 1030 ms
  in the 1.27 s window, the GUI thread 90. No order of work gets under the largest single link (~220 ms); one ShaderEffect's first
  draw per frame would bring 715 to ~220 and needs a content-to-engine "still revealing" contract (not built). Whether switching
  Qt's own disk cache off helps is NOT settled (714 and 520 in two runs with different cache states).
- **The clock's 196 ms** (synchronous: the pinned content) is its 18 week rows (`clknorows`: 26 ms). Built one per turn while
  parked, the prewarm entry fell to 28 ms but the rows landed at the first real open instead (a 10-11 ms frame the old code does
  not have): reverted. Aerial (~155), bridge (~130) and weather (~110-160) were not taken apart.
- `frame_split.sh` stops its shell with SIGTERM, which writes no `qqpc_opengl`; the user's supervisor stops it gracefully, which
  does. A nested run has the user's cache state only after one graceful exit.
- `lengthsTarget` and the fieldShape repeat cache: absent from the profile (~0.04 ms a frame).

### The weather popup's view switch (2026-11-23, quiet, nested; `frame_split.sh <out> wview:<n>`, `wview_stat.py`)

Ablated first: the float, the static layers and the backdrop each cost nothing in a switch, and the morph's own clock little. The cost
is every card following the popup's easing box -- its width or height changes each frame and its inside re-lays out -- on top of the
engine's own layout (~4 ms a frame: the floor, what a switch to mini costs). GUI time per heavy frame 15-20 ms -> 8-12; frames later
than 12 ms per switch: mini > normal 13.5 -> 4, detailed > normal 13 -> 10, normal > detailed 10 -> 10. What changed, all pixel-identical
(sheet_check 0 px in every weather state): the daily list lays out only the views in play (7 -> 1 at rest), hands its rows each
blended slot as ONE number (a row binding re-runs only for the slot that moved) and its absent air-quality segments read nothing; the
strip's taper is in line in the ribbon loop. THE FIRST SWITCH OUT OF MINI BUILT THE STRIP AND THE LIST IN ITS OWN TURN (272 ms, nothing
drawn): they are built ahead through asynchronous Loaders, one card a beat from 0.7 s after the popup is shown (two pauses of 77 and
100 ms in the resting sky, once a session); a switch that lands in the build finishes it in its turn (108 ms at worst). Left: the
strip's two ribbons re-tessellated per width (~12 %), the C++ side of resizing ~3000 items, the engine's layout. The resize kicks the
interaction boost, so its A/B covers this motion. A settle-tick dedupe in GooeyField measured nothing and was reverted.
