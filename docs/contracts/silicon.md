# silicon — contract (FROZEN 2026-10-03: the user's stage-0 confirmations and stage-1 picks, section 8)

(The plans, stage-0 facts and round notes this contract names beside it are no longer in `docs/`: they are in git history,
`git log --all -- 'docs/agent_added_files_and_folders/silicon_progress/'`.)
(The gates, probes and fixtures this contract names without a directory went with the cleanup: tag `pre-cleanup` has them. What a change is proved with now is in `tools/dev/`, [tools.md](../tools.md).)

Plan: `PLAN.md` (copy of `~/.claude/plans/it-is-your-job-crystalline-meteor.md`). Stage-0
facts: `0.md` + `tools/dev/fixtures/silicon/stage0_facts.json`. After the freeze, changing this file
is the orchestrator's job; a stream that needs a change asks, it never edits another stream's
files.

## 0. Safety rules for everyone

- **No test touches the real machine.** No write to the real `/sys`, no `cardwire set`, no
  write to `gpu_mux_mode`, no reboot, no suspend, no `systemctl` on system units, no sound on the
  desktop. Tests use a fake sysfs tree, the helper in test mode (honoured only when euid ≠ 0),
  a cardwire stub on a private bus (`tools/dev/notifications_bus.sh` pattern) and stubs for
  `pkexec`, `systemctl`, `nvidia-smi`, `pw-play`, `notify-send`; a probe asserts nothing outside
  its fixture was written.
- `nvidia-smi` is never called while the dGPU is not in D0 (asking wakes it).
- Never `pkill`/`pgrep -x quickshell`; kill only pids you started. `pgrep -f` matches your own
  shell.
- Anything that starts a quickshell goes through `tools/dev/sandbox.sh` with a private
  `XDG_CONFIG_HOME` (theme state seeded), offscreen + `QT_QUICK_BACKEND=rhi` for grabs.
- Hands off: `modules/bar/gooey/**` (read-only bindings to `thePopup`), `modules/battery/**`,
  `bar_in_progress.qml`, the system-update module.

## 1. Names

- Module `modules/silicon/` (`scene/`, `shaders/`, `data/`, `mock/`), mockup `test_silicon.qml`,
  style harness `test_silicon_style.qml`, helper `helpers/silicon_helper` → binary
  `silicon-helper` installed at `/usr/local/libexec/silicon-helper`, config
  `$XDG_CONFIG_HOME/quickshell/config/silicon.jsonc` (tracked `silicon.example.jsonc`), state
  `$XDG_STATE_HOME/lares/silicon/state.json`, root state `/var/lib/silicon/`.
- Theme tokens (light + dark; stage 4 adds them, SiliconStyle.qml holds the values until then):
  `profileQuiet` #44C145, `profileBalanced` #4480F4, `profilePerformance` #FF6D12,
  `profileTweak` #C838C6 (dark #CF68E1; the 2nd rim hue of a tweaked profile), `gpuIntegrated`
  #44C145, `gpuSmart` #00BEC4, `gpuHybrid` #4480F4, `gpuDgpu` #FF6D12; plus the two kept families'
  palettes (`SiliconStyle._pal`, eight slots each, light and dark).

## 2. Service (SiliconService and SiliconMock: identical members, over SiliconViewModel)

Facts (plain objects, NO colours): `cpu {profile, profiles[], epp, eppChoices[], turbo,
governor, governors[], maxPerfPct, pl1W, pl2W, capFloorW, capCeilW{pl1,pl2}, tweaked, heldBy,
clockMHz, loadPct, tempC}`, `cores [{kind:"P"|"E"|"LPE", load}]` (16), `igpu {busy}`,
`gpu {mode, modes[], dState, awake, util, tempC, watts, vramUsedMB, vramTotalMB, holders[],
blockedApps[], policies[], config{batteryAutoSwitch, batteryAutoSwitchMode,
externalDisplayAutoSwitch, nvidiaBlock}, ignoredApps[], mux{state, pending, prechecks{ok, why}, deadlineBootId,
deadlineUptimeMs, bootId, bootWindowS, promptWindowS, afterMode}}` (stage 6: `ignoredApps` and every `policies[]` row's
`ignored`; the windows are the helper's constants, mirrored; round 2: `mux.afterMode`, the STEP -- 0 Integrated, 1 Smart,
2 Hybrid, or null -- wanted once a way back from dGPU-only has restarted, applied through cardwire ONCE and forgotten),
`battery {pct, status, ac, wattsReal, wattsNormalised, minutesLeft, minutesToFull, toLimit,
conditionPct, cycles, lastFullMs, limitOn}`, `helper {installed, ok, why}`,
`caption {cpu, gpu, battery, cpuError, gpuError}`,
`memory {totalKiB, availableKiB, usedFraction}` (round 2: `/proc/meminfo` at the stats cadence, MemTotal and MemAvailable only --
round 3 dropped the swap with its module; null while unknown),
`display {hdmi}` (round 4, D1: true while an external display is connected to the NVIDIA card's HDMI-A connector, and ONLY that one -- see below).
In dGPU-only wiring the arrows offer all four steps: stepping left queues the way back and remembers
the step asked for (`afterMode`: the LAST step asked, section 14), stepping back to dGPU-only cancels it.

GPU facts, as stage 0 measured them (`0.md` §7-9, `0_spike.md` §3):
- `gpu.mode` / `gpu.modes[]`: cardwire's `Mode` u32 — **0 Integrated, 1 Hybrid, 2 Manual, 3 Smart**.
  `modes[]` is `AvailableModes`, never a fixed list ([0,1,3] here; in dGPU-only wiring cardwire
  refuses 0 and 3). Config setters persist by themselves (`SaveToFile` is never called).
- `gpu.dState`: `D0 | D1 | D2 | D3hot | D3cold`, normalised (the method answers `"D3cold\n"`, the
  signal `'D3Cold'`). `awake` = `D0`. Read from cardwire's signal or sysfs `power_state`; neither
  wakes the card, and no read-only cardwire call does (spike: 36 of 36 samples `suspended`).
- `gpu.holders[]`: process names on the dGPU's OWN nodes — its DRM card and render node and its
  `/dev/nvidiaN`, resolved from its PCI device by the helper's `status` (never hard-coded: a kernel
  may renumber them) — minus the plumbing: the daemons `{cardwired, nvidia-persiste}` (kernel `comm`, 15
  chars) and, since R5 W1, the SESSION's own processes `{Hyprland, Xwayland, Xorg, systemd, systemd-logind}`
  (section 14). `/dev/nvidiactl` never counts (Hyprland and VS Code hold it without using the card).
- `nvidia-smi` runs ONLY while `holders` is non-empty (one query from D3cold costs 2.1 s and keeps
  the card awake ~21 s; polling at any period keeps it awake for good).
- `gpu.policies[]`: only apps the user chose or that were blocked at least once — `GetAppPolicies`
  lists every app cardwire has seen (26 here, kitty and quickshell among them), in a different
  order on every call (sort by name). Policy **0 Blocked, 1 Allowed**.
- Signals: `ProcessBlockedChanged` `((tu)usus)` = ((secs, nanos), pid, comm, gpuId, appId);
  `NewAppAdded` `(s(sasasu))` = (id, (name, desktopIds[0..1], icons[0..1], policy)) — typed from
  cardwire 0.12.3's source, not yet seen live. Parser: `spike/silicon/cardwire_parse.js`
  (stage 3 starts from it; replies byte-exact in `tools/dev/fixtures/silicon/cardwire/spike_replies.json`).
Targets (what the scene animates to): `profileTarget`, `gpuModeTarget`, `chargeLimitTarget`.
Signals: `batteryEvent(kind)` (full | low | chargeStart | chargeStop), `acChanged(on)`,
`gpuPowerChanged(dState)`, `writeRefused(zone, why)`, `appBlocked(app)`, `osd(request)`.
Intents: `stepProfile(dir)`, `setTuning(patch)`, `resetTuning()`, `setChargeLimit(on)`,
`stepGpuMode(dir)`, `setGpuMode(mode, {confirmHolders})`, `setCardwireConfig(key, value)`,
`setAppPolicy(app, allowed)`, `ignoreApp(app)`, `muxRequest(want[, after])`, `muxRebootNow()`,
`muxKeep()`, `muxCancel()`.

## 3. Helper CLI + JSON (std-only Rust)

`silicon-helper status` (unprivileged) → `{ok, status:{features, values, lists, paths,
prechecks, mux, boot}}`. (`prechecks.mux`: for dGPU-only the NVIDIA checks -- the driver
loaded, a DKMS module for every installed kernel -- and, for both directions since stage 6, `silicon-mux.service`
active; write paths never read /proc/driver/nvidia.) Privileged (pkexec, or the stage-0 transport fallback):
`apply profile= epp= turbo= governor= max_perf_pct= pl1_w= pl2_w=` (any subset; fixed order
profile → governor → EPP → turbo → max_perf → caps; caps on both RAPL zones keeping PL1 ≤ PL2),
`set-charge-limit 80|100`, `set-boot <apply-args>`, `mux-request dgpu|hybrid`, `mux-cancel`,
`mux-prompt-shown`, `mux-confirm`. systemd-only (refused when `PKEXEC_UID` is set):
`boot-apply`, `mux-apply` (at shutdown), `mux-guard` (no resume unit: stage 0 found nothing that
resets). **The exact wire format, field by field: `silicon_helper_protocol.md` (v1).** Output `{ok, results:[{knob, want, got, ok, code,
why}], status}`; exit 0 ok, 1 a write failed, 2 refused (nothing written), 3 I/O, 4 test root
refused. Test mode: `--sysfs-root <dir>` and `SILICON_TEST_FAULTS`, honoured only when euid ≠ 0.
Transport: **pkexec** — stage 0 showed polkit treats the shell's processes (kitty scopes under
`user@1000.service`) as the user's active local session; no socket fallback.
`status.paths.dgpu {pci, card, render, nvidia}` resolved from `/sys/bus/pci/devices/<pci>/drm/`
at every call. `status.mux {stored, wiringNow, pending}`: `stored` is what `gpu_mux_mode` shows
(the firmware's STORED setting — after a write, the pending one), `wiringNow` is read from which
panel connector is connected (`eDP` on the Intel card = hybrid, on the NVIDIA card = dgpu).

## 4. Config (`silicon.json`, read-only to the shell, hot reload; `//` comments allowed)

`profiles.{quiet,balanced,performance}.{epp, turbo, governor, maxPerfPct, pl1W, pl2W}`
(null = keep the firmware's value); seeds: quiet power/false/powersave, balanced
balance_power/true/powersave, performance performance/true/powersave. `idle.{calmAfterMs,
haltAfterMs, statsHaltedMs, batteryHaltedMs}`, `overhead.{wPerCpuSec, wPerGpuSec}`,
`sounds.{latch, dip, plug}` (volume 0..1) and `sounds.variant.{latch, dip, plug, plug_out}` (the take, `"a"` | `"b"` | `"c"`;
round 2's defaults latch a, dip a, plug c, plug_out a -- the user's picks; a bad value is one warning and the default);
stage 6 REMOVED `mux.{guardWindowS, keepPromptS}` (the helper runs as root and never reads the user's config, so its
windows -- 300 s / 120 s -- are constants the shell mirrors);
`look.family` (`"material"` | `"blueprint"`, default `"material"`; the old spelling `"eva"` is read as `"material"`: the user kept both families);
`look.secondarySide` (`"far"` | `"start"` | `"end"`, default `"far"`; R5 D1: where every secondary the popup opens hangs, section 14).
State: `lastFullMs`, `ignoredApps[]`, `muxOutcomeSeenAt`, `afterMuxMode` (round 2, see §2 `mux.afterMode`).

## 5. Cross-module buses

`modules/common/power/PowerBus`: `hold(source, profile, reason)`, `release(source)`; a manual
change drops every hold (nothing restored). `modules/common/osd/OsdBus` (built by the OSD module,
2026-10-03): `show({source, key, glyph, title, detail, colorToken, ms}) -> bool`; since stage 6 silicon's requests
carry `kind: "power"`, the OSD's own kind for them (routed to the OSD by default); a request without
a `kind` is treated as kind "generic", which the OSD config leaves disabled until the user enables
it -- `false` (no OSD service, or the kind not routed to it) means silicon falls back to a desktop
notification.

## 6. Scene

**Fixed by the stage-1 core** (`modules/silicon/scene/`, `modules/silicon/shaders/src/`):
- `SceneGeometry.js` is the one description of the board (boxes in mm with their move group:
  board / pkg / card / plug / lever; traces with role cpu|gpu|charge, length and distance from the
  pack; labels; anchors; the CPU zone, the square the package turns in; `PKG.lift`, how far a
  profile change raises it). Nobody hard-codes a coordinate elsewhere. A point that rides on the
  package (the beam's graphics tile) is placed by `IsoCamera.pkgPoint(G, p, turn, lift)`.
- Shaders are ASSEMBLED: `node tools/dev/silicon_shader_gen.js [names]` builds
  `modules/silicon/shaders/<name>` from `src/<name>.in` + the geometry (`// @@GEOM`) + includes
  (`// @@INCLUDE x.glsl`); `--check` fails when stale. Ownership by file: `silicon_board.frag.in`,
  `silicon_glow.frag.in` = core; `board_materials.glsl`, `glow_materials.glsl`, `SiliconStyle.qml`,
  `make_silkscreen.py` = board-look stream; `silicon_holo.frag.in` + `HoloLayer.qml` = hologram
  stream; `silicon_particles.vert.in/.frag.in` + `ParticleField.qml` = particle stream.
- Layers, back to front (`SiliconScene.qml`): BoardLayer (the cached still board; it never holds the
  package: the patch's rect is its `hole` uniform, transparent) · BoardLayer `patch` (the CPU zone's rect,
  `IsoCamera.patchRect`, always shown, the whole scene there, ground included; a layer that renders again
  only while the package lifts and turns -- `silicon_camera_parity.sh` SEAM + MOTION; drawn `SiliconScene.patchMargin`
  (2) device px BEYOND its hole, and out there only what is opaque -- `silicon_board.frag`'s `hole` is the patch's CORE on
  the patch itself -- so that a quad a row short, which a layer drawn inside the engine's clip layer has at a fractional scale, can never
  leave a line of the surface open between the two: `silicon_open_film.sh`) · GlowLayer (live light) ·
  particles traces/card/bursts and the cpu/gpu sparks behind the planes · HoloLayer beam, cpu, gpu ·
  the sparks in front.
- The scene's state API (what a film or the service drives): `time power profile cpuNextProfile
  cpuDerez cpuLoad cores[16] cpuPhase tweak gpuMode gpuNextMode gpuDerez dgpuAwake gpuUtil gpuPhase
  beam igpuBusy fill flowW flowPhase eventAge eventKind pkgQuarter pkgRise cardLift cardDissolve
  plugIn lever` (+ `family dark renderScale`). `pkgQuarter`: profile k rests at k, a change passes
  through the fractions (clockwise going up); `pkgRise` 0..1 is the lift as a fraction of
  `PKG.lift`. The CPU hologram's symbol IS the profile's index (0 leaf, 1 scales, 2 shock). Colours
  are derived (SiliconStyle `profileColour`, `gpuColour`, `tweakColour`), never stored in the state.
- `gpuMode` in the scene and the bar is the STEP order the user sees, left to right: **0 Integrated
  · 1 Smart · 2 Hybrid · 3 dGPU-only**. The view model maps onto it: cardwire `Mode` 0 → 0, 3 → 1,
  1 → 2, and the MUX wiring `dgpu` → 3 whatever cardwire says. cardwire's 2 Manual is not in this
  machine's `AvailableModes`; if it is ever reported the zone shows Hybrid and the caption names it.
- `MotionScripts.js` holds every motion as a pure function of time (`stateAt(name, t, base)`); the
  style harness films it, stage 5 plays it live.
- HoloLayer and ParticleField keep their PROPERTY API (the stubs' headers) whatever their bodies.

Already fixed by stage 0 (`0_spike.md`):
- **Camera** (true isometric, yaw 45°, pitch 35.264°), one source (`IsoCamera.js`) for shaders,
  particles and hit-testing: `CAM_R = (0.70710678, 0, -0.70710678)`,
  `CAM_U = (-0.40824829, 0.81649658, -0.40824829)`, `CAM_C = (0.57735027, 0.57735027, 0.57735027)`
  (toward the camera); screen `x = ox + s·dot(P, CAM_R)`, `y = oy − s·dot(P, CAM_U)`.
- **Particles**: one ShaderEffect + `GridMesh { resolution: Qt.size(1, 4N − 1) }` per pass, the
  spike's row-to-corner layout and dead-particle collapse; **N ≤ 8192 per mesh** (beyond it the
  excess is lost SILENTLY — 16-bit indices); float hashes only (the bake targets include GLSL ES 100).
- **Clock**: one Timer → one time uniform per effect; nothing re-grabbed per tick, nothing touched
  from `frameSwapped`. Gate: frames per tick in [0.80, 1.05] (template: the spike's pace probe + its
  `extraframe` / `regrab` ARMs).
- **Entrance** (the owner binds `engine.thePopup.t / phase / contentOpacity`), verbatim — a bare
  rule fires INSIDE `engine.open()` with a stale `t`:
  ```qml
  readonly property bool entranceReady:
      (openPhase === "opening" && openT >= 0.6 && openOpacity > 0)
      || ((openPhase === "open" || openPhase === "moving") && openOpacity >= 0.6)
  property bool entered: false
  onEntranceReadyChanged: if (entranceReady && !entered) { entered = true; scene.powerOn() }
  onOpenPhaseChanged: if (openPhase === "closing" || openPhase === "closed") entered = false
  ```
  Never read `t` at creation (the content is built at phase `closed` with the last run's `t`).
- **Pre-warm**: the owner builds the scene's effects hidden at shell start (a cold first open stalls
  the open animation 146 ms; warm 12).
- **Measured floor**: board stub (18 boxes + shadows + traces) + 4000 particles = 0.24 ms GPU per
  frame net; the engine window's own frame per tick = 0.22 ms. Budget 3 ms alive.

## 7. Settled by stage 0 (`0.md` has every measurement)

- A profile switch is `platform_profile` (the EC's thermal policy: quiet 2 / balanced 0 /
  performance 1) plus the linked values silicon applies from `silicon.json` (EPP, turbo, governor,
  max_perf_pct, caps). The firmware moves nothing else, on a switch, an unplug, a replug or a resume.
- EPP has FOUR steps: power, balance_power, balance_performance, performance. `default` is an alias
  of balance_performance on this CPU and is never offered.
- RAPL PL1/PL2 are writable on both zones and not locked; the effective PL1 is the lower zone's.
  `constraint_*_max_power_uw` is the TDP (45 W), NOT a ceiling (66 W was accepted).
- Caps (confirmed by the user, 2026-10-03): lower only. Ceiling = the firmware's values read at boot
  (MSR 65/115, MMIO 45/115: effective 45 W PL1, 115 W PL2), floor 8 W, both zones written, PL1 <= PL2,
  PL4 never. At those limits the CPU is already thermally limited (barrel: bursts to ~88 W, then
  45-47 W, 94 C and throttling in Balanced and Performance).
- Boot: the machine comes up in Quiet with EPP at the CPU's default; `silicon-boot.service` applies
  Quiet's linked values, ordered after every unit that writes the same knobs (asusd, asus-boot-quiet and
  powertop: `powertop --auto-tune` 2.16+ sets EPP balance_performance and min_perf_pct 50 a second into its
  run, and won the race in 14 of 15 boots until the unit was ordered after it, 2026-11-15). No resume or unplug unit: nothing resets (the data layer's external-change
  detection covers a firmware that would).
- Battery: `power_now` updates at 1 Hz and is noisy; `energy_now` moves in ~1 % steps, so time left
  comes from smoothed `power_now`. The charger TYPE cannot be read (AC0 covers barrel and USB-C;
  UCSI fails on 6.18 and 7.2.7): the scene's jack stands for both.
- The dGPU wakes for 20-60 s on every power event (unplug, replug, resume): shown, not fought.
- MUX: `asus-nb-wmi/gpu_mux_mode` on 6.18; 7.2.7 adds `asus-armoury/attributes/gpu_mux_mode`
  (+ `pending_reboot`) beside it -- the helper prefers armoury when present. The write is queued and
  applied at shutdown (confirmed by the user, 2026-10-03), BY DIRECTION since stage 6 (section 10): to
  dGPU-only with the NVIDIA stack down, as asusctl 6.5 does, or not at all; the way back to hybrid whatever
  the stack does, never trying the teardown. A new request needs `silicon-mux.service` active.
- Transport pkexec; cardwire integers, D-state names, holder filter and signals: section 2.

**Confirmed by the user at the stage-0 stop (2026-10-03):** the caps rule, the four EPP steps, the
MUX written at shutdown.

## 8. Picked by the user at the stage-1 stop (2026-10-03)

- **Families: Material AND Blueprint**, both kept ("I like both ... Can we go forward with the two
  of them and have a control panel toggle between them for when the mockup arrives?"). Family 0
  Material, 1 Blueprint; Real hardware is deleted. The mockup's panel switches them (stage 4), the
  shell reads `look.family`. Silkscreen channels: R Material, G Blueprint.
- **Motion: lift and turn.** A profile change lifts the package `PKG.lift` (12 mm), turns it a
  quarter per step and sets it down; multi-step = one lift, one longer turn (`MotionScripts` lift1,
  lift2, liftDown). The board and the light do not move. The camera orbit is deleted.
- **Quiet's hologram: the leaf** (after 5 s close-ups of both). The feather is deleted.
- **Bar button: face B, the pill**, with the dGPU mark at **7 px, a 1.5 px ring**. Faces A and C are
  deleted.
- The tweak hue and every palette value stay tunable on the mockup's panel (stage 4).

## 9. Stage 4: the popup, its secondaries, the owner, the mockup (APIs fixed 2026-10-07)

Theme tokens are in (`profile*`, `gpu*`, `profileTweak`, `siliconEva*`, `siliconBlueprint*`; both
modes in `themes/eva.json`); `SiliconStyle` reads them and the scene's `dark` IS the theme's mode, so a
harness renders one mode per process (`silicon_style_render.sh` splits its jobs). The motions'
curves stay in `MotionScripts.js`; the live director that plays them is stage 4's (the idle ladder,
the entrance, pre-warm and sounds are stage 5's).

**Who owns what** (nobody edits another stream's files; a change needed elsewhere is asked for):
- **P, the popup:** `modules/silicon/SiliconPopup.qml` (skeleton in place), `modules/silicon/popup/**`,
  `modules/silicon/scene/MotionDirector.qml`, `modules/silicon/scene/SiliconClock.qml`; may ADD a motion
  to `MotionScripts.js` (never change one); `test_silicon_popup_probe.qml` + `silicon_popup_probe.sh`,
  `test_silicon_render.qml` + `silicon_render.sh`.
- **S, the secondaries:** `modules/silicon/secondary/**` (skeleton `SiliconSecondary.qml` in place);
  `test_silicon_secondary_probe.qml` + `silicon_secondary_probe.sh` (+ its render states).
- **M, the owner and the mockup:** `modules/silicon/SiliconBarOwner.qml`, `test_silicon.qml`,
  `silicon_mockup.sh`.
- Read-only for all: the rest of `modules/silicon/scene/**`, `shaders/**`, `data/**`, `bar/**`,
  `SiliconBarButton.qml`, `modules/bar/gooey/**`, `modules/common/**`, Theme.

**`SiliconPopup`** in: `vm` (SiliconService | SiliconMock), `family` (0 Material, 1 Blueprint),
`renderScale`, `shown` (opening/open and visible: the clock runs only while shown and not
`Theme.crossfading`). Size 760 x 560, one layout (round 2: 760 x `scene.naturalHeight`, 510 -- the bottom plate is gone, §12). The engine's secondary contract as StocksPopup has it
(`secondaryComponent` = a SiliconSecondary with the popup's `vm` / `family` / `renderScale` and `kind` =
`secondaryKey`; `secondaryOpen`, `secondaryAnchor`, `secondarySide`, `secondaryOverhang`,
`secondaryInset`, `secondaryKey` "tuning" | "gpu" (R5 D1: and "mux" | "confirm", section 14); `secondaryPersistent` went with the keep
prompt in round 11 -- nothing asks for a secondary while the popup is still growing any more); `openSecondary(kind)`, `closeSecondary()`. Input by arithmetic (`IsoCamera.pick`, never a MouseArea over a drawn part): the
package opens "tuning", the card or its slot "gpu", the DIP lever flips the charge limit; hover-only
chevrons (absent at an end, no looping) and a horizontal two-finger swipe over a zone step it
(`stepProfile` / `stepGpuMode`; gestures.md); the hand cursor is the only affordance. One caption per
zone (instant swaps, `*Error` in the error colour), the readouts, the battery figures in fixed slots,
the holders confirm card; `vm.touch()` on pointer activity. Round 2: once a dGPU-only step has settled the restart card opens
by itself (Later dismisses it; a click on the card reopens it). `MotionDirector` turns targets and facts
into the scene's state with the MotionScripts curves (one clock per motion; a refused write plays the
way back); `SiliconClock` advances `time` and the phases while shown.

**`SiliconSecondary`** in: `vm`, `kind`, `family`, `renderScale`; its own implicit size per kind.
"tuning": EPP four steps (TabSelector; disabled, with the reason, under the performance governor),
turbo, governor (the kernel's list and an honest hint), max_perf_pct, PL1 / PL2 (hidden while
`cpu.capsWritable` is false), "Reset to profile" only while tweaked -- through `setTuning` /
`resetTuning`, pending values from `tuningTarget`. "gpu": cardwire's switches (`setCardwireConfig`)
and the Smart app list (`setAppPolicy`, `ignoreApp`).

**`SiliconBarOwner`** (StocksBarOwner is the model): `engine`, `bar`, `barId`, `ownerId` "silicon",
`anchorItem`, `service` (a SiliconService made by URL when none is given); binds the bar button's facts
from the vm (step order for `gpuMode`), `vm.popupOpen` to "the popup is ours", battery events to the
button's pulse, `family` from `vm.config.look.family`; `toggle` / `open` / `close` through
`engine.open(...)`. **`test_silicon.qml`**: the mockup on the real engine (test_stocks.qml is the
model) with SiliconMock; tabs Look (the family switch, the silicon tokens as hex fields through
`MockupRegistry.setColor`), Scenario (the mock's timeline), Motion, Bar (top / side).

This file is frozen. Changing it is the orchestrator's job, with the user's say.

## 10. Decided by the user after the stage-4 report (2026-10-07)

- **The engine fault O12 found is fixed** in `GooeyEngine.openChild` ("just fix the issue if it is not
  going to be a compromise elsewhere"): a secondary asked for again while it closes turns round from
  where it is drawn (the OSD's rule), and the close curve is cleared. Gate:
  `gooey_engine_probe_run.sh` (+ `ARM=reopenclose`, the old code, must fail).
- **Changes made outside the popup are OSD pills** ("as osd"): stage 6 adds a silicon kind to the OSD
  module; a desktop notification stays only the fallback for no OSD service.
- **The way back from dGPU-only writes hybrid at shutdown even when the NVIDIA stack cannot be taken
  down** ("write hybrid at shutdown. you say more safe, so we pick that"): hybrid is the safe direction;
  the dGPU direction keeps the stack-down rule.
- **Cadence:** the plan runs to completion before the user's feedback ("I'd like to execute the plan to
  completion first and then the massive feedback lists will come flowing in"): no stop between stages
  5, 6 and 7; the steps that need the user's hands (a helper reinstall, the overhead calibration on
  battery, the asusctl checklist) are collected for the end.

## 11. Stages 5 + 6 as one wave (APIs fixed 2026-10-07)

The user asked for the plan to run to completion before their feedback, so stages 5 (motion, idle,
entrance, sounds) and 6 (MUX flow, hold, OSD, Smart prompts) run as ONE wave of five streams on the
foundation commit (skeletons + the hooks below, pre-wired by Opus). Nobody edits a file another stream
owns; a change needed elsewhere is a request in the stream's report.

| Stream | Owns |
|---|---|
| W1 motion + frame budget | `SiliconPopup.qml` (not the internals of W2's / W3's components), `popup/` SceneInput, PopupLayout.js, ZoneBlock, ZoneChevron, ZoneReadouts, BatteryFigures, FigureSlot, ConfirmCard; `scene/**`; `shaders/**` + `tools/dev/silicon_shader_gen.js`; a new `SiliconPrewarm.qml` if it earns its place; tests `silicon_popup_probe.sh`, `silicon_render.sh`, `silicon_perf.sh`, `silicon_films.sh`, `silicon_flash_check.py`, `silicon_camera_parity.sh`, `silicon_geom_cases.js` and their QML, a new `silicon_idle_probe.sh` |
| W2 sounds | `modules/common/components/SoundPlayer.qml`, `popup/SiliconSounds.qml`, `tools/silicon/make_clicks.py`, `assets/sounds/silicon/**`, a new `silicon_sounds_probe.sh` (+ QML) |
| W3 flows | `popup/MuxCard.qml`, `popup/KeepCard.qml`, `SiliconMuxWatcher.qml`, `BlockedAppNotifier.qml`, a new `silicon_flows_probe.sh` (+ QML) and `silicon_flows_render.sh` (+ QML) |
| W4 data + OSD | `modules/silicon/data/**`, `modules/osd/**`, `modules/common/osd/**`, `test_osd.qml`, `silicon.example.jsonc`, `tools/dev/silicon_service_probe.sh` (+ QML), `silicon_data_cases.js`, the OSD's own gates |
| W5 helper | `helpers/silicon_helper/**`, `docs/contracts/silicon_helper_protocol.md` |
| Opus | `SiliconBarOwner.qml`, the mockup (after the wave), CONTRACT, docs, `tools/dev/runner_noload_check.sh` |

**Hooks (pre-wired):**
- `MotionDirector` signals `cardLatched(bool seated)`, `leverFlipped(bool limitOn)`, `plugMoved(bool
  plugged)`: W1 emits each from the motion as it reaches that point (the latch as the card seats or
  lets go, the lever passing its middle, the plug landing or leaving); W2's `SiliconSounds { vm,
  director, active }` plays them (volumes `vm.config.sounds.{latch, dip, plug}`, 0 = silent; only while
  `active`).
- `SiliconPopup.openProgress` (0..1; the owner binds its engine popup: body `t` while opening, content
  opacity while open or moving) and `entranceEnabled` (the owner true, harnesses false = the board is
  simply on): W1 plays the power-on entrance into `scene.power` once the popup is mostly out (>= 0.6).
- `MuxCard { vm, open, sizes; readonly wanted; signal dismissed }`: while `wanted` (a MUX request
  QUEUED -- after the firmware write nothing is the user's to do) a click on the card or slot opens it instead of the GPU panel (routed in the popup).
  (R5 D1: the restart card and the holders question were cards laid over the GPU zone and are secondaries now --
  `MuxPanel` and `ConfirmPanel` in `secondary/`; the words, the buttons and the rules are the same. Section 14. The third, the
  keep prompt, was a secondary too (`KeepPanel`, the popup's `KeepFlow`) until round 11: it is a toast now, section 11a.)
- Owner-level: `SiliconMuxWatcher { vm, locked, shown }` (no owner, no popup: it says when the keep prompt may be shown, holds the
  prompt, and tells the MUX's last word after a revert as one outcome notice, then `markMuxOutcomeSeen()`),
  `BlockedAppNotifier { vm }`.

**11a -- the keep prompt is a toast (round 11, the user: "I'd rather have the confirmation to be in a toast").**
`MuxKeepPrompt { vm, ready; countdown, countdownText, figureShown, phase; signal wayBackFailed(why); again() }`, held by the watcher
(`watcher.prompt`), posts ONE shell record through the notification service (`NotificationBus.service`: source `silicon`, key
`silicon-mux-keep`, `fixed: true` -- no swipe, no click, never filed or removed by the user --, sticky in the scheduler, `breakDnd`,
sound none, urgency normal; actions `back` ("Go back now") and `keep` ("Keep"); the rich body `MuxKeepBody`, "Going back in 1:47").
It is up while the record is `awaiting-keep` (or the way back is on its way, or the guard's revert was seen happening) AND `ready`
(the watcher's: unlocked, the frame on the glass, the helper answered) AND a service exists; a lock takes it away, the unlock
brings it back. The helper is told (`vm.muxPromptShown()`) when the toast is IN THE STACK and the lane is neither folded away
(`toasts.blocked`) nor waiting for a screen (`toasts.unplaced`) -- once, by the rule of the data (a window already within the prompt's
span is not asked again). The card's drain is the record's `deadlineMs` / `deadlineTotalMs` (NotificationService.post / update;
ToastEntry draws it from the instant: no freeze for a hover or an idle user, nothing filed or dropped when it reaches nothing), the
instant being now plus the guard's clock (`MuxCountdown`: the record's uptime deadline minus the shell's /proc/uptime). Keep
(`vm.muxKeep()`, from the action only) takes the toast away when the facts say `kept`; Go back now is keep -> `muxRequest("hybrid")`
-> `muxRebootNow()`, each waited for, the toast saying "Going back to Hybrid" meanwhile; a step refused or unanswered after the
keep took ends the prompt and `wayBackFailed` is told as a notice (`MuxFlow.wayBackFailed`). No popup opens for any of it.

**Facts and kinds:**
- W4 adds `ignored` (bool) to every `gpu.policies[]` row and `gpu.ignoredApps` (the persisted ids); W3
  reads them (an ignored app is never notified).
- W4 adds the OSD kind **`power`** (`OsdKinds.js`: not user-pressed, its own duration and priority; a
  pill with a glyph, a title, a detail and the colour named by `colorToken`); silicon's outside-change
  requests carry `kind: "power"`. W3's outcome notice is NOT an OSD card (changed 2026-11-06: the card cut the helper's words off):
  it is a notification (`DesktopNotifier`, key `silicon-mux`, stored in the notification manager), always, with the words of
  `MuxFlow.outcome(mux)` -> `{ title, body }`. A `failed` record whose `wiringNow` equals its `want` is told as "dGPU only is on" /
  "Hybrid is on" (the helper's read-back of asus-armoury answered with the old value; see docs/silicon.md, "How to change it").
- Battery `stalled` (PowerMath, 2026-11-06): status Charging with under 0.5 W flowing for 30 s, on a pack more than 2 points under its
  target (`acpi`: "charging at zero rate"). `facts.battery.stalled`; the caption reads "Plugged in · no charge is reaching the pack";
  `SiliconBatteryAdapter.chargeStalled` carries it to readers outside the popup (BatteryNotifier runs its low-charge levels on it).
- A zone without its daemon (CPU: `!vm.helper.ok`; GPU: `!vm.gpu.present`) never powers on: its
  hologram and its sparks stay off (W1). While `vm.gpu.mux.pending` the GPU hologram pulses (W1).
- Idle: the clock follows `vm.idleState` -- alive 16 ms, calm 33 ms, halt STOPPED on a clean frame (no
  frozen mid-flight sparks); hover or a change of target or fact wakes it with a ramp; the figures keep
  refreshing while halted (W1).
- W5: the way back (dgpu -> hybrid) is written at shutdown even when the NVIDIA stack cannot be taken
  down (section 10); the dGPU direction keeps the stack-down rule. The CLI and the test mode do not
  change shape; W4's service-level MUX probe drives them as silicon_helper_protocol.md describes.

## 12. Round 2 (the user's first feedback, 2026-10-08; items in `R2.md`, waves in `R2_STAGE2.md`)

The battery has no plate: its figures are printed on the board. `SiliconScene` takes, from the popup:
- `figures` -- the board's figures as display strings (`Model.buildFigures`, node-tested), null before the first reading:
  `{ watts, wattsRaw, time, timeMode, sinceFull, condition, cycles, ram }`. Characters `0-9 - space d h`; a `.` lights the
  cell before it; a `:` only in `time`. Fixed cells, right-aligned: `watts` 4 (charging has no sign), `time` 4 + the colon
  (`--:--` unknown), `sinceFull` 3 with its unit (`4.0h` / `37h` / `4d`, capped at `99d`; never full: blank), `ram` 3 (used
  GiB); longer than its display: `--`. `timeMode` `left` | `full` | `limit` | `""` picks the printed label (TIME LEFT / TO
  FULL / TO 80) and an empty mode blanks the display. Round 3 (F1, the user: the label "dissappears when full"): with no estimate
  -- full on AC, held at the limit, idle -- the figures are `time "--:--"` under `timeMode "left"`; `""` now means only that there
  is no pack. `sinceFull` reads `0.0h` while the pack is at its target, and its moment is the later of the service's own and
  UPower's charge history (T2). `condition` and `cycles` are board text. The hover over the watts
  display swaps in `wattsRaw` at once (the popup's own draw left in).
- Round 5 (F1): the CPU's three figures moved off its plate onto three 3-cell displays (`SEG7` segClock / segLoad / segTemp):
  the figures gain `{ cpuClock, cpuLoad, cpuTemp }` (`Figures.cpuFigures(vm.cpu)`): clock in GHz with two decimals, the point
  taking no cell (`3.42`, at most `9.99`), usage in % and temperature in degrees C (3 cells each, clamped); a sensor that has not
  answered shows dashes (`-.--`, `---`). The CPU's plate keeps its title and its tail.
- `memory` -- `{ usedFraction }` (`Model.buildMemory`): the RAM chips fill like the cells (2 GB a chip). (Round 2 also drew a
  swap module beside them while the swap was in use, `swapUsedFraction` / `swapActive`; round 3 removed it at the user's request.)
- `naturalHeight` (read-only) -- the popup's height for the board top-aligned with the camera's 14 px bottom margin at the
  current width (510 at 760); it never reads the scene's own height. The popup's `implicitHeight` binds it.
- Pick names (SceneInput, by arithmetic): `segWatts`, `segTime`, `segFull`, `segRam`; the DIP switch stays `dipBody` (the
  battery error tag stands beside it, carved, the error colour, 160 ms presence).
- The charge limit's lock bar on the 4th cell is ONE fraction (`MotionScripts.LOCK_SECONDS` 0.34 s): it engages once the
  lever has landed on 80 and lets go as soon as the lever leaves it; the cell under it dims by the same fraction.

Scene rules round 2 settled (`SceneGeometry.js` is still the one description):
- Displays are a LIST (`SEG7`: name, footprint, cells, colon, figures key, colour); lit segments live in the glow layer (a
  1 Hz figure change never re-renders the cached board), body, window and ghost segments in the board. Lit vs window
  >= 3:1 in all four family x mode renders (`silicon_display_contrast.py`).
- Repeated parts are ONE primitive (`ROW`: one bounding test, a fixed 2-3 cell tests per ray, straight-line code); a
  `bake` part is board-only (no glow, no particles, no shadow). Every part stands on EMPTY board: its footprint + 0.6 mm
  clear of every trace corridor, the gold fingers, every label and every other part (`silicon_geom_cases.js` G14/G16/G17).
- A second palette (`palI..palP`: the displays' window, their unlit segments and bezel, the lock's amber, gold, the memory
  hue, the ribbon's film and its conductors) from Theme tokens in `themes/eva.json`, both modes (board_materials.glsl's header).
- Cold compile budget (`silicon_compile_time.sh`, Mesa cache off): board <= 2000 ms, glow <= 1000 ms.
- The display ribbon leaves the board's front-left edge and folds twice (down-right, then down-left on screen); it is lit
  by the GPU that drives the panel: the iGPU's colour through the zone's front trace, in dGPU-only the dGPU's through the
  left-edge trace.

## 13. Round 4, stream D: the HDMI fact and the cable (the user's D1, 2026-10-09; `R4.md`, `R4_PLAN.md`)

**The fact** `display.hdmi` (bool; service and mock alike, member parity). Machine facts, taken read-only on 2026-10-09 in Hybrid with the
card asleep: only `card1` (i915, 0000:00:02.0) exists, with connectors `card1-eDP-1` (connected) and `card1-DP-1..4`; the NVIDIA card's connectors
(an `HDMI-A-n` among them) exist only while nvidia_drm has the card. The rule (`DrmRules.nvidiaHdmi`, modules/common/system): a connector counts when its name is
`card<N>-HDMI-A-<n>`, its card's `device/vendor` is `0x10de` and its `status` reads `connected`. A DisplayLink dock (evdi: a DRM card of its own,
DVI-I connectors, a platform device with no PCI vendor) and the iGPU's DP-1..4 (USB-C) never count; a connector that does not exist is "no cable".
- Reading: `DrmWatch.qml` (modules/common/system; the shell's ONE, injected as `drm`, else the service builds its own) runs `DrmRules.SCAN_SCRIPT` (one short `sh` over the cached `status` / `vendor` files; they never wake a sleeping
  card -- the probe reads the card's `power/runtime_status` before and after) at start, on a udev `drm` event, when cardwire's mode moves and on
  `refresh()` (a resume). The events come from ONE `udevadm monitor --udev --subsystem-match=drm --subsystem-match=usb` under `setpriv --pdeathsig TERM`, restarted with a
  back-off; a burst is one scan (300 ms). No timer, no fork per poll. `SiliconService` takes `drmRoot` / `udevadm` / `displayEnabled` (a probe's fakes);
  `SiliconMock.hdmiConnected` is the mockup's knob (Machine group, "HDMI display").
**The scene** `SiliconScene.hdmiIn` (0 out and faded .. 1 seated), MotionDirector's: in while the fact holds, the card is seated in its slot and the target
mode is not Integrated; out when it does not; the card's way OUT (to Integrated) starts only once it is out ("will just unplug the cable before the lift
up and scatter"), and the cable goes back in only after the card has seated. `SceneGeometry.HDMI` (shell, hood, cable on the receptacle's axis, group `hdmi`,
baked: only the cached board draws it), the board shader's `motion.y`, `HDMI_FADE` / `HDMI_TRAVEL`; the cable fades by the charger cable's expression over its
own stretch (the popup's edge is 36 mm from the plate). A rare event like the charger plug's: the cached board re-renders each frame of the 0.45 s slide.
  Films `hdmiOut` / `hdmiIn` (MotionScripts); `silicon_geom_cases.js` G25; `silicon_visibility.js` has the cable's states.

**The UPower fixtures** (call 4): the real captures of this laptop's charge history live in the gitignored `tools/dev/fixtures/silicon/upower_local/` (they stay
in git history); `tools/silicon/make_upower_fixture.py` writes the committed SYNTHETIC week in the same bytes into `tools/dev/fixtures/silicon/upower/`; the gates
replay the synthetic always and the real one when the local folder has it (`silicon_data_cases.js` L5, the service probe's `mainreal` phase).

## 14. Round 5, stream G: the dialogs are secondaries, where a secondary opens, the last step asked for wins, the session is not a user

(The user's X1, D1 and W1, 2026-10-11; `R5.md`, `R5_PLAN.md`.)

**D1 -- the cards are secondaries.** The restart card (what a MUX request waits for) and the question a GPU step that would block busy
apps asks were carved cards laid over the GPU zone (`FlowCardFrame`, now deleted: nothing else used it), and so was the keep prompt
(after the restart into dGPU-only) -- which is a TOAST since round 11 (section 11a: the watcher no longer opens the popup, `KeepPanel`
and `KeepFlow` are gone). They are the popup's secondary now, with the same words, buttons and rules; a click elsewhere in the popup
closes the restart card and the question, as it did.
- ONE secondary slot, four things in it, the first of these that is due winning: `"confirm"`, `"mux"`, then the panel the user opened
  (`"tuning"` | `"gpu"`) -- which is still there, under, when the dialog over it has been answered. `secondaryKey` /
  `secondaryOpen` / `secondaryAnchor` are derived (read-only); the dialogs hang at the GPU part (`PopupLayout.partAnchor`), a
  panel at the part that asked; `openSecondary(kind, at)` opens a PANEL only; `closeSecondary()` puts away what the user can
  (the panel, the question, the restart card).
- Content: `secondary/MuxPanel.qml`, `ConfirmPanel.qml` (views, 300 px wide: `SecondaryStyle.dialogWidth`,
  title 16 bold, the buttons `secondary/FlowButton.qml` on the popup's surface) loaded by `SiliconSecondary` by its `kind` /
  the engine's key. The engine tears a secondary's content down when it closes, so what must outlive it lives in the POPUP:
  `_confirmStep` / `_confirmHolders` (what is asked and of whom, as raised), `_muxOpen`. `SiliconSecondary` takes `confirmStep`,
  `confirmHolders` and answers `confirmed()`, `cancelled()`, `muxDismissed()`.
- An answer is given ONCE: a panel that was just answered (Later, Restart now, Cancel the request, Cancel, Confirm) has its buttons
  dead for 700 ms -- the secondary fades out for a moment, may be turned round if asked for again, and a second click on a button
  that is going away must not ask the vm again (a second `muxCancel` is refused by the helper and the GPU zone would say so).
  (`SiliconPopup.secondaryPersistent` was `true` for one thing only: the keep prompt at a login, asked for while the popup was still
  growing, held back until it had nearly landed. The prompt is a toast now and the popup has no such secondary: the property is gone.)
- **Where a secondary opens is ONE setting for all four** (the panels too -- they share the mechanism): the engine's side for a
  child, `look.secondarySide` = `"far"` (away from the bar; the default) | `"start"` | `"end"` (along it) in silicon.json
  (`SiliconModel` seed; `silicon.example.jsonc` documents it; the user's file is never edited). `SiliconBarOwner.secondarySide`
  is that value unless the host hands `secondarySideOverride` (`""` | `"far"` | `"start"` | `"end"`; the mockup's panel does:
  Look tab, group "Secondaries", "secondary side"); `SiliconPopup.secondarySide` (the engine's contract property) is what the
  owner passes down. An open secondary moves to the new side when it changes.
- Tests: `silicon_harness/SecondaryHost.qml` builds the popup's `secondaryComponent` the way the engine does (a window of
  its own) for the probes that host a SiliconPopup without the engine; the mockup's owner probe (O16, O18, O19) proves the same on
  the real engine -- the dialogs, the side setting (below / right of / left of the popup) and a real click on each dialog's buttons; O16 and
  O19 prove the keep toast on the stage's own NotificationService (posted, fixed, no popup opened, the helper told, the drain the guard's
  deadline, Keep and Go back now, the lock), and `tools/dev/silicon_mux_watcher_probe.sh` the same on a stub service with its ARMs.

**X1 -- the last step asked for wins.** The mode wanted after the way back from dGPU-only (`SiliconState.afterMuxMode`, the fact
`gpu.mux.afterMode`) is written where the user ASKS (`muxRequest`, a re-aim, `muxCancel`) and by nobody else: a helper's reply
used to write the step of the newest REQUEST over a newer re-aim (Hybrid -> Smart -> Integrated ended on Smart whenever the
second step came before the first answer and the third after it). `afterMuxPlan` still forgets it when the facts say nothing is
coming. The mock answers its MUX asks one at a time, in order, `writeMs` apart (the service's write lane). `muxRebootNow` flushes
the state file first. `SiliconService` re-reads who holds the card when the card's nodes become known (the first read could come
before them). The restart card names where the laptop ENDS (`MuxFlow.muxCardCopy`: "Integrated needs a restart", ...), live.

**W1 -- the session is not a user of the dGPU.** `gpu.holders` leaves out `Hyprland`, `Xwayland`, `Xorg`, `systemd`,
`systemd-logind` (`CardwireParse.SESSION_HOLDERS`, compared on the lowercased kernel `comm`): measured read-only on 2026-10-11
(cardwire's `Gpu Lsof`, the dGPU runtime-suspended) they hold the card's own nodes while it sleeps, so holding it keeps nothing
awake, and cardwire blocks only NEW opens, so a switch to Integrated or Smart cuts nothing running off. A Steam game, blender,
anything else that opens the card for work is still a holder and still asks (the question, the caption's "in use by", nvidia-smi's
gate). The same list decides the mode asked for after a way back, which is judged at the next login by the same rule.


## 15. Firmware traffic (2026-10-12, after the EC wedge)

On 2026-10-12 the laptop's embedded controller wedged (keyboard dropping keys, a warm reboot carrying it, a cold power-off
with the charger out clearing it). The logs show no silicon write out of the ordinary (profile switches at firmware power
limits; a MUX request and cancel, which write only the helper's record), so the cause is not established. What silicon asks
of the firmware was cut anyway, measured by read latency (`silicon_ec_cost.sh` documents why the EC's GPE counter does
not count transactions on this platform):
- kernel-cached, free (~0.15 ms): platform_profile, EPP, governor, no_turbo, max_perf_pct, the charge limit.
- ACPI into the EC: the battery's uevent (`_BST`, ~3.1 ms), the mains flag (~0.1 ms), the MUX's `gpu_mux_mode` (an ASUS WMI
  call, ~0.6 ms). RAPL limits are the CPU's registers, never the EC.
- `SiliconService._cad.status` (counted in beats since round 8, below): the helper's whole status (a process, a fresh walk, the MUX through the firmware) once a
  minute open and every five minutes closed, instead of every 2 s open. It is also asked at start, on opening, on a resume
  (`refresh()`), after silicon's own writes (their replies carry it) and when a knob moved: `SysfsPoller.knobsRead(key)` reads
  the kernel-cached knobs with every battery poll, under the sysfs root the status names, and `_onKnobs` asks for a status
  when the key changes. `statusRuns` counts the runs (an instrument for the probe).
- The battery stays at 1 beat (1 Hz alive) while the popup is open and alive (the live watts; `power_now` itself moves at 1 Hz).
- Gates: `tools/dev/silicon_service_probe.sh` `status-quiet` (an open popup with nothing changing: at most one run in 8 s) and
  `status-on-knob` (an outside profile change applied within 5 s through one status), ARMs `statuspoll` and `noknobs`.

## 16. One beat for every reading (round 8, C1)

The user: "the update frequencies so that all are fractions of each other: a fast stat updates 4 times and on the 4th a slow
stat updates." Before, five free-running timers (SysfsPoller's stats and battery, NvidiaSmi, OverheadMeter, the service's
status) drifted apart in phase, the halted periods were not multiples (2 s and 5 s), and the CPU clock display changed on the
WALL's whole second, between two readings.

- `data/ReadingBeat.qml`: one repeating Timer at `baseMs`; `serial` (incremented before `beat(serial)`), `restart()` (serial 0 and
  `beat(0)` at once). A change of `baseMs` keeps the serial running.
- `SiliconModel.cadence(level, open, idle)` -> `{ baseMs, stats, battery, status, overhead }`, the last four in BEATS (0 = not read).
  `SiliconService._cad` is that; `_onBeat(serial)` fires a reader when `serial % count === 0`, so a slow reader lands ON a fast beat. The
  beat is judged by `_cadNow()`: opening restarts the beat from a change handler, which runs before the `_cad` binding follows.

  | state | base | stats | battery | status | overhead |
  |-------|------|-------|---------|--------|----------|
  | alive | 1000 | 1 | 1 | 60 (60 s) | 1 |
  | calm | 2000 | 1 | 1 | 30 | 1 |
  | halted | `statsHaltedMs` (2000) | 1 | `batteryHaltedMs` (6000) / base = 3 | 30 | 1 |
  | closed | `batteryHaltedMs` (6000) | 0 | 1 | 50 (300 s) | 0 |

  A period that is not a whole number of beats is ROUNDED to the nearest (at least one), in `wholeBeats()` only. The battery's halted
  default is now 6000 (three beats; fewer EC reads than 5000).
- NvidiaSmi and OverheadMeter lost their timers and `intervalMs` (`poll()`); SysfsPoller lost its two (`statsActive` replaces
  `statsIntervalMs` for the "stats stopped, drop the differences" rule). Its 250 ms `quick` re-poll after the first stats seed stays, and
  so do the explicit polls after the user's own acts. Opening the popup is `beat.restart()` (beat 0 reads everything).
- Every build carries `readingSerial` (written LAST), `readingMs` (the beat's period; the mock's `tickMs`, 250) and `readingAtMs` (the
  build's `nowMs`), on the view model and re-exported by the service and the mock.
- Displays that change slower than the readings change ON a reading: the popup's CPU clock takes the reading's value when
  `readingSerial % max(1, round(1000 / readingMs)) === 0` (4 in the mock, 1 in the service) and the first reading replaces the dashes at
  once; the since-full display counts from `readingAtMs`, so it advances on the first reading after its boundary. `BoundaryClock`s
  are gone from the popup.
- Gates: `node silicon_data_cases.js` (`cadence`, ARMs `cad*`), `silicon_service_probe.sh` (`beat-*`, ARMs `freebattery`,
  `statuspoll`), `silicon_cpu_clock_probe.sh` (ARMs `livecadence`, `wallsecond`), `silicon_popup_probe.sh` (figures).

## 17. Shell assembly round 2, stream SI: the open at the asked size, the parked content, the popup's own scale (2026-10-22)

**The user's words** (`DeploymentNotes.md`): 53 "the opening/close animation easing looks different than what the norm is for all other popups, though this
might just be lag"; 57 "slight stutter when holograms appear" (cold); 136 "the silicon popup can be made bigger ... 95% of it is shaders ... let it scale
freely".

**The scene is laid out at the size the popup ASKED for (53).** `SiliconScene` fits its camera by its WIDTH and `naturalHeight` is a function of it, and it
was laid out at the BOX's width. While the popup opened -- the box growing from a 425 px cell to 760 and landing with the open's OutBack overshoot (762 for
a frame) -- the popup asked the engine for 509, 508, 507, 506 px of height, and the engine answers every ask (`GooeyEngine._contentResized` ->
`_retarget` -> `run(resizeMs)`) by aiming the box again from where it is, which RESTARTS THE OPEN'S CLOCK: the box chased its own target (the recorder's
`t` fell back to 0 two to four times per open) and the cached board was rendered again at every size. The easing differed by LAG, not by design. Now the
scene is `designWidth` (760) wide and `naturalHeight` tall whatever the box is; the box only reveals it, as it reveals every other popup's content.
`shell_open_timing.sh` (silicon alone, 3 passes, medians, nested Hyprland; machine load 4 to 10, so an A/B in the same conditions -- the idle machine's
numbers are in the table below): open end cold / warm / warm2 882 / 970 / 799 ms before, 393 / 390 / 390 after (idle: 403 / 391 / 397; update and notes 407-445); travel into silicon 755 / 786 -> 420 / 405; the longest gap 91-199 -> 16-25 ms; missed frames 25-40 ->
0-4. `SiliconPopup` has no member that is the box's size but `gestureHoldWidth/Height` (the swipe's hold, in the engine's units).

**The parked content (57; R2-CONTRACT 3).** `SiliconPopup.parked` is written by the ENGINE: true while the content is held hidden -- built ahead of the click
on a hover (`SiliconBarOwner`: `HoverIntent` -> `engine.prebuild`), kept after its popup closed, or drawn once by the prewarm. Parked it runs nothing and
asks nothing (`_live` = shown and not parked drives the clock and the sounds; `_touch` leaves the service alone). `recycle()` puts a kept
content back to what a new one starts as (the secondary gone, the entrance to play from dark, the pointer's gesture and hover over, the clock awake), which
is what lets the engine keep it. `prewarm: true` (set by the engine's prewarm entry in `ShellFrame.prewarmEntries`, never on a shown content) draws the
board ON with the card's live patch shown and no entrance: a DARK board draws no hologram, no spark and no lit figure, so a plain `{ parked: true }`
entry would compile them at the first real open, through the engine's clip layer, in the middle of its power-on -- the cold stutter and the 179 ms first
close. Gates: `silicon_parked_probe.sh` (23 checks, 7 ARMs), `silicon_gates.sh parked`.

**One prewarm, the engine's.** `SiliconPrewarm.qml` (stage 5: the whole popup drawn once, 6 s after start, in every window) and the engine's prewarm entry
drew the same thing twice. Measured with `shell_open_timing.sh`, silicon alone, 3 passes, medians (open cold: show / longest gap / missed frames;
first close cold: longest gap):

    configuration              | open cold: show/gap/miss/end | first close: gap/end     | travel notes>si end/gap
    both (as it was)           | 64 / 25 / 4 / 403            | 16 / 366                 | 422 / 17              
    the engine's only          | 56 / 25 / 3 / 404            | 17 / 372                 | 423 / 17              
    SiliconPrewarm only        | 144 / 108 / 14 / 480         | 193 / 537                | 423 / 24              
    both, no hover prebuild    | 71 / 62 / 3 / 437            | 15 / 365                 | 413 / 17              
    neither                    | 281 / 249 / 31 / 622         | 186 / 531                | 420 / 17              

So the shell no longer arms `SiliconPrewarm` (`ShellFrame` passes no `prewarmArmed`; the owner's default is `ownsService`, false when hosted); it stays for
an owner of the real service outside the shell (the Live mockup) and for `silicon_prewarm.sh`. The final tree measures the same (open cold 61 / 25 / 4 /
411, first close 17 / 374), and `ABL=noprewarm` (silicon's engine entry off) reproduces `neither` (279 / 250 / 32 / 642; 201 / 548).

A CAVEAT FOR THE HARNESS. A 180-210 ms frame gap shows in one `silicon open warm` or `close warm` row of most runs, at HEAD too, and is NOT silicon's: it sits at
+22.0 to +22.7 s after `LARES ready` in every pass that has it, at the shell's own `LARES settled` (+22.0 to +23.0 s) -- the start's tails, which
ShellServices' header names (the launcher's catalogue and icon atlas read on the main thread) -- and lands in whichever scenario runs at that moment, while
`shell_open_timing.sh` starts measuring at +16.8 s. (The HEAD runs had a second one at +20.0 s, in the `open warm` of the same passes; the runs after this round's changes do not.) A request:
the harness waits for `LARES settled` before its first scenario.

**The popup's own scale (136).** `look.scale` in silicon.json (0.5 .. 2, default 1; the shell's own range for a ratio) is a ratio ON TOP of the shell's popup
scale (`scale.popup`), the one popup that scales freely: the board is shaders and has no reading size to standardise. `SiliconBarOwner.sizeScale` is the
config's value unless the host hands a `sizeScaleOverride` above 0 (the mockup's `popup scale` row; -1 follows the config) and hands it to the popup and its
prewarm. `SiliconPopup` derives from `PopupStage.qml`: a ScaleRoot of that factor INSIDE the body's (the engine's `contentFrame` is a ScaleRoot of the popup
ratio), into which every child the popup declares goes through a default property alias, laid out in DESIGN px as before. The root is in the engine's
CONTENT units: `implicitWidth/Height` = `designWidth/Height` x `sizeScale`; what the popup tells the engine in item px is multiplied by `stageScale`
(`secondaryAnchor`; `secondaryInset` is 0) and what the engine hands back divided (`gestureWheel`'s x / y); the board's layers are made at `renderScale` x
`stageScale` (a texture made at the design size and stretched goes soft). The CPU/GPU panels (`SiliconSecondary`) are the engine's child and keep the
shell's popup size. At 1 the stage is an identity (no transform node). Gates: `silicon_scale_probe.sh` (K 1 .. 2 at ratio 1 and 1.5, through the
owner's override and through the config; C1-C9: the owner, the engine's box, the layers' scale, the picture's size on the window, a real click on the
package opens the panel and it hangs on the part, a real wheel starts the plate's swipe; ARMs `noscale`, `norender`, `noanchor`, `nostage`) and
`silicon_scale_equiv.sh` (the popup at global G with silicon's K and at global G x K are the same picture to the pixel, in the settled frame drawn
straight and through the engine's clip layer; ARM `noscale`). `silicon_pace.sh` / `silicon_perf.sh` at `SIZE=2` use it (`sizeScale: 2`).

## 18. The boot profile (Q16, 2026-11-02)

The user: "I hope this also means that when the system is in the early stages of booting, it already has that profile set ... I would not want the
profile to change to the set default only when the shell launches." So `defaultProfile` in silicon.jsonc (`"quiet"` | `"balanced"` | `"performance"`,
default null) is STORED, never applied: whenever the helper's stored boot set -- `/var/lib/silicon/boot.json`, 0644, read by the service itself because
`status.boot` carries only `{id, applied}` -- does not hold the named profile's linked values (`Model.linkedPatch` against the helper's status: the
arguments a switch to it applies), SiliconService asks `pkexec silicon-helper set-boot <those arguments>` ONCE per difference (`Model.bootPlan` /
`bootDecide`: an attempt is remembered against the profile, its arguments and the file's text, so a refusal is `bootProfile.why` plus one log line and is
not asked again until the config or the file changes or the shell restarts), and `silicon-boot.service` applies the set at every boot (CONTRACT section 7
"Boot"), before the login screen. No `apply` is ever made from this path: the profile in use stays until the user switches; an edit takes effect at the
next boot. An absent key stores nothing and clears nothing (`pkexec silicon-helper set-boot` with no arguments clears it, keeping the charge limit). New
member on both the service and the mock (`Model.MEMBERS`): `bootProfile {want, state: off | waiting | storing | stored | failed, why}`; the service's
`bootFile` (default the real path) is the probe's fake state dir. No helper change. Gate: `tools/dev/silicon_service_probe.sh` phase `boot` against the real
helper in test mode (ARMs `noboot`, `bootapply`), and the mock phase's `mock-boot-*` checks.
