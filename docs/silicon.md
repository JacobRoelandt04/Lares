# silicon -- battery, CPU profile and GPU mode

## What it is
One popup that is a small isometric motherboard. The top half holds the CPU (a package with its four tiles) and the GPU (a card in a PCIe
slot); the bottom half holds the battery pack, the charger's jack and a DIP switch. Traces run between them, so the power the laptop uses is
seen flowing from the pack or the charger into the chips. It replaces asusctl: one place to read the battery and to change the CPU profile,
the GPU mode and the charge limit.

## Where it lives
- Bar: the right island of the top bar, module id `silicon` (between `bridge` and `update`). The button shows the battery percentage (it
  rolls over when it changes, as the clock's minutes do), a
  small glyph of the CPU profile in its colour and one of the GPU's mode in its own; under them a thin track holds the charge, scaled to the
  limit while the limit is on. On a side bar the same parts stack. The GPU's glyph says the mode, the cousin of the profile glyph that shares
  its hue: a feather (Integrated), a lightbulb (Smart), layers (Hybrid), fire (dGPU-only). It is lit while something uses the card and faded
  while the card idles (the feather is always at full strength: the iGPU is the one drawing), keeps the mode it came from, lit, while
  Integrated still has apps on the card, and breathes in dGPU-only's hue while a MUX switch waits for its restart. Each of the two glyphs
  plays a small flourish of its own: for a pointer on THAT glyph (the figure and the track play nothing), when its fact changes (the
  profile; the mode), and the GPU's also when the card wakes. The profile's three: the leaf sways on its stem; the scales throw a weight
  from the left pan to the right, which drops under it, stands tipped and comes back as the weight melts away; the bolt's ink runs off
  downward and out through the lower tip while a new charge strikes in from above and lands with a swell and a bob, each stream's
  end a point on the bolt's zigzag spine
  (`bar/SiliconGlyphPose.js`; the numbers are `SCALES` and `BOLT` there).
- Popup: one layout, 760 design px wide and as tall as the board, no views. It opens from a click on the button and is drawn at the ratio
  `scale.popups.silicon` of `shell.jsonc` (1.35 by default). Its extra cards (tuning, GPU settings and three questions) open beside it as the
  engine's secondary, on the side `look.secondarySide` names, and are drawn at their own ratio: `scale.popups."silicon.detail"`, by default
  the plain `popup` ratio (1.0), never the board's 1.35 (round 7; `tools/dev/detail_scale_probe.sh`).
- No keyboard shortcut and no IPC verb.

## What you can do
- CPU profile: hover the CPU half and click the faint arrows, or swipe two fingers sideways across it, to step Quiet - Balanced -
  Performance. The package lifts out of its socket, turns a quarter and sets down; the hologram above it changes (a leaf for Quiet, scales
  for Balanced, a shock for Performance).
- CPU tuning card: click the package or its hologram. It holds the energy preference (four steps; fixed while the governor is `performance`),
  turbo boost, the governor, the highest speed as a share of the maximum, and the sustained and burst power limits (PL1, PL2, only lower
  than the firmware's, PL1 never above PL2). "Reset to profile" shows only while the values differ from the profile's.
- GPU mode: the same arrows or swipe over the GPU half step Integrated - Smart - Hybrid - dGPU-only. In Integrated the card slides out and
  dissolves and the CPU's graphics tile shows a ghost of it. Apps that already use the NVIDIA card keep running when the mode blocks it;
  the popup first asks which apps they are.
- GPU settings card: click the card or its slot. It holds cardwire's own switches (Integrated on battery and the mode it returns to on the
  charger, Hybrid while an external display is on the NVIDIA card's port, the experimental NVIDIA block) and the Smart-mode app list
  (allowed or blocked, and "Never ask again" for a blocked one).
- dGPU-only needs a restart and is guarded. "Restart now" in the restart card restarts the laptop; after the restart a keep prompt appears
  as ONE TOAST (no popup opens for it; round 11): "Keep dGPU only?" with Keep and Go back now, "Going back in 1:47" and the card's own
  drain running with the helper's real deadline. It comes once the session is unlocked and the shell is on screen (a dGPU session starts
  under the boot lock, and nothing is posted while the lock holds the screen), cannot be swiped away or filed (the guard counts down
  whatever you do) and breaks through do-not-disturb. Doing nothing puts Hybrid back and restarts once more, so a wiring that gives no picture
  cannot lock you out. Keep takes the toast away and says nothing more; Go back now asks Hybrid and the restart (the helper has no
  "revert now": keep, request Hybrid, restart, each waited for) and the toast says "Going back to Hybrid" meanwhile. Leaving dGPU-only
  later is one restart request too; the mode wanted afterwards is the last step asked for.
- Charge limit: click the DIP switch, 80 % or 100 %. At 80 a lock bar closes over the fourth cell. A refused write is shown as a small
  error tag beside the switch.
- Hover the watts display for the raw figure the pack reports (the shown one has the popup's own draw taken off).
- The popup plays three small clicks (card latched, switch flipped, plug moved) and goes calm after 10 s without the pointer and still
  after 30 s; a still popup draws no frames.
- Outside the popup: a profile, GPU mode or charge limit changed by another program shows as an OSD pill (kind `power`), and the bar button
  pulses on a battery event (plug in, unplug, full, low) with a burst of sparks. A Smart-mode app kept off the NVIDIA card posts one
  notification per app and session with "Allow always" and "Ignore". The MUX's last word (the guard put Hybrid back, or a switch did not go
  through) is a notification too, kept in the notification manager, never an OSD card; a switch the helper recorded as failed whose wiring is in
  effect is told as "dGPU only is on" (see the next section).
- Fans (2026-11-13): after every resume the shell re-kicks the firmware's fan logic -- 8 s later (the first status and the firmware's own
  re-adds have landed) it writes another platform profile, waits 1.5 s and writes yours back (two plain `apply profile=` calls, no root change; it is
  no manual change: holds stay, no OSD, the popup never shows the in-between profile). And the FAN GUARD watches for fans that are not
  turning: it compares the CPU temperature with what this machine, in this profile, normally reads at the load it has now, and when the
  package is >= 85 degrees AND 15 above that for 20 s it re-kicks once silently; still hot a minute later (and not falling), a critical notice
  "The fans look stuck" (temperature, load, what that load usually reads) and a Performance hold until the CPU is under 75 degrees. 90 degrees
  under a build is not an alarm. What it cannot see: a fan itself (nothing exposes a speed), and a stuck fan under a load so heavy that working
  fans also reach the limit. Before it has learned a load (~5 minutes of steady samples per load step and profile) only >= 95 degrees at a
  light load fires.
- Changing your mind about dGPU-only (2026-11-19): the firmware is written only at SHUTDOWN, so until then a dGPU-only request is a record
  the helper can withdraw. A step to any other mode (swipe, arrows) while it is queued first sends the helper's `cancel`, and on its answer
  sets the chosen mode through cardwire; a pill says "dGPU-only switch cancelled" and the restart prompt goes away. A request already
  written at shutdown (`applied`) is refused ("already written; it can be undone after the restart"). `SiliconService.rebootArgv` (the
  shell binds it to the reel's reboot command, which saves the session first) is what "Restart now" runs; unset it is a bare
  `systemctl reboot`.
- `tools/silicon/mux_score.sh` (yours to run, after a reboot into each mode; opens benchmark windows): glmark2 and vkmark, windowed
  1280x720 and fullscreen, default scenes. Hybrid runs the iGPU and the dGPU through prime-run, dGPU-only natively; results go to
  `~/.local/share/lares/mux-score/<mode>-<gpu>-<date>.json` and a table says by what percentage dGPU-only is ahead of each Hybrid row.
  `--compare` only prints it. It warns on battery, on a different platform profile, and when a "dGPU" run's renderer is not NVIDIA
  (cardwire blocking the card). Not `tools/dev/mux_bench.sh`, which measures latency. Probe: `tools/dev/silicon_mux_score_probe.sh` (stubs).
- The caption says "Plugged in · no charge is reaching the pack" when the kernel says Charging and nothing flows for 30 s (a drained pack on a
  charger that cannot feed the machine: `acpi` reads "charging at zero rate"). The notifications' low-battery card (8 % / 3 %) runs in that
  state too, as if the pack were discharging, which it is.

## What it shows and where the data comes from
| Part | Source |
|---|---|
| CPU profile, tuning, power limits, charge limit | the root helper `/usr/local/libexec/silicon-helper` (status read without a prompt, writes through pkexec) and the kernel's sysfs files it names; a path it does not report is a hidden feature |
| Battery percent, watts, time, condition, cycles | the battery's sysfs files (read at the popup's rhythm, and once per udev `power_supply` event) |
| Hours since the pack was last full | UPower's charge history (one read-only `gdbus` call) and what the service saw itself |
| GPU mode, Smart apps, who uses the card, card power state | the cardwire daemon on the system bus (`busctl`, one `gdbus monitor`) and `nvidia-smi` only while the card is awake with a real user |
| External display on the NVIDIA card's HDMI | `/sys/class/drm` read at start, on a udev `drm` event and after a mode change |
| RAM | `/proc/meminfo` |
| The fan guard's temperature and load | the coretemp's `temp1_input`, `/proc/stat` and the cores' `scaling_cur_freq` (cached kernel files, read on the beat, no fork, no firmware); what is learned is `~/.local/state/lares/silicon/thermal-baseline.json` (`{profile: {loadBucket: {n, p90}}}`, a quantile tracker; delete it to start over) |
| The popup's own draw | the shell's CPU and GPU time times two watt coefficients, subtracted from the battery's flow |
Without the helper the CPU half reads "Profile unknown" with the reason and the tuning card says "Power control is unavailable"; without
cardwire the GPU half reads "Mode unknown" and the settings card says it needs cardwire. A zone without its daemon stays dark. The popup
state lives in `~/.local/state/lares/silicon/state.json`. The bar's GPU glyph is drawn only once cardwire and the helper have each answered
(`gpu.known`): the Hybrid it would otherwise show is a fallback, not a fact; cardwire is asked again after 1 s, 2 s, 4 s ... (a busy boot).
The EPP the glyph's dot and the CPU detail show is the helper's status, refreshed within a battery poll (5 s shut, 1 s open) of any outside
change of it, so it is the machine's.

## Settings
`~/.config/quickshell/config/silicon.jsonc` (template `.examples/silicon.jsonc`, read hot, never written by the shell). A bad value is ignored with
one warning, a file that does not parse keeps the last good one.
- `defaultProfile`: `"quiet"`, `"balanced"`, `"performance"` or `null` (default). The profile the laptop comes up in, from early boot. The
  shell stores that profile's row of `profiles` as the helper's boot set; `silicon-boot.service` applies it at every boot. The shell never
  switches the profile when it starts.
- `profiles.<quiet|balanced|performance>`: what a profile applies besides the firmware's platform profile: `epp`, `turbo`, `governor`,
  `maxPerfPct`, `pl1W`, `pl2W`; `null` keeps the firmware's value (`epp`, `turbo` and `governor` null are not written at all).
- `overhead.wPerCpuSec` / `wPerGpuSec` (2.0 / 5.0, 0..50): watts per second of the shell's CPU and GPU time; 0 turns the correction off.
- `gpu.ignoredHolders`: process names that never count as an app on the NVIDIA card (cardwired, nvidia-persistenced, the session, quickshell,
  btop, nvidia-smi by default). The list is the whole truth.
- `onPower.ac` / `onPower.battery` (null): the profile a plug switches to. Only the plug switches (not the start; a plug in a resume's first
  seconds waits for them to pass); during a hold the plug changes what comes back after it.
- `holds.systemUpdate` (`"performance"`; `"balanced"`, or null: an update holds nothing).
- `battery.lowAt` (15, 5..50): the charge that counts as low, of what the limit leaves: the bar's red, the OSD's card, the lock's band.
- `fans.guard`, `fans.resumeKick` (true): the fan guard, and the fans' wake-up after a resume.
- `gpu.askWhenBusy` (true; false switches to Integrated or Smart without the question), `gpu.blockedNotice` (true).
- `sounds` (true): the popup's sounds (how loud is the mockup's).
- `interactionBoost` (false): ask `lares-boost.service` for a GPU / CPU floor while a shell motion runs ("The interaction boost", below).
  Does nothing without the root step R6. The floors themselves are the unit's arguments, not this file's.
- `look.family` (`"material"` carved, `"blueprint"`; the old spelling `"eva"` is still read as `"material"`) and `look.secondarySide` (`"far"`, `"start"`, `"end"`).
The size is `shell.jsonc` `scale.popups.silicon`. The look and motion (the idle ladder's times, the sounds' volumes, the entrance, the
colours) are constants tuned in `mockups/silicon.qml` (`quickshell -p ~/.config/quickshell/mockups/silicon.qml`); Save writes the module.

## How it is built
| Path | Role |
|---|---|
| `modules/silicon/SiliconBarOwner.qml`, `SiliconBarButton.qml`, `bar/` | the bar side: owner (wiring, family, secondary side, size), the pill, the profile glyph and the GPU mode's glyph (`SiliconBarGpu`, posed by `SiliconGpuPose.js` from the font's outlines `tools/dev/flourish_parts.py` writes), each with its flourish (its events, and a pointer on that glyph), and the charge sparks |
| `modules/silicon/SiliconPopup.qml` | the popup content, laid out at its design size and scaled by the stage (`PopupStage`, the toolkit's) |
| `modules/silicon/scene/` | the board: `SiliconScene`, `IsoCamera.js` (picking), `SceneGeometry.js`, `MotionDirector` + `MotionScripts.js` (the films), `SiliconClock` (the idle ladder's clock), board, glow and hologram layers, particles |
| `modules/silicon/popup/` | input by arithmetic (`SceneInput`), the plates (`ZoneBlock`), `MuxFlow.js` (the words and the clock's arithmetic), `MuxCountdown` (the guard's clock), `ErrorTag`, `SiliconSounds` |
| `modules/silicon/secondary/` | the engine's secondary: tuning, GPU settings, restart and question panels |
| `modules/silicon/data/` | `SiliconService` (real) and `SiliconMock` (same members) over `SiliconViewModel` and `SiliconModel.js`; `HelperClient`, `CardwireClient`, `SysfsPoller`, `UpowerHistory`, `PowerEventWatcher`, `OverheadMeter`, `IdleLadder`, `HoldFollower`, `FanGuard` (+ `FanGuardMath.js`), `SystemUpdateHold`, `SiliconConfig`, `SiliconBatteryAdapter`, `BoostClient` (the interaction boost's client: ONE, in ShellServices, `services.boost`) |
| `modules/silicon/shaders/`, `assets/` | the board, glow and hologram shaders (generated by `tools/dev/silicon_shader_gen.js` = `tools/dev/board_gen/gen.js silicon`) and the silkscreen printing |
| `modules/common/board/`, `tools/dev/board_gen/` | the board toolkit silicon shares with aerial (the camera core, figures, layout helpers, `BoardClock`, `BoardInput`, `BoardIsland`, the layer / glow / holo bases, `ReadingBeat`, `IdleLadder`, `PopupStage`, `ErrorTag`, the shared GLSL, the shader generator): `modules/common/board/README.md`. Silicon's `IsoCamera.js`, `Figures.js`, `PopupLayout.js`, `SiliconClock`, `SceneInput`, `SiliconIsland`, `BoardLayer`, `GlowLayer`, `HoloLayer` derive from it and keep what is silicon's. `ReadingBeat.qml` and `IdleLadder.qml` are there: the idle ladder's four times are still silicon's tuned constants (the silicon mockup's Save writes them in that file) |
| `modules/silicon/SiliconMuxWatcher.qml`, `MuxKeepPrompt.qml`, `MuxKeepBody.qml`, `BlockedAppNotifier.qml`, `SiliconPrewarm.qml` | once-per-shell helpers: the watcher (when the keep prompt may be shown, the MUX outcome notice), the keep prompt's toast and its one-line body, the blocked-app notice, a first draw |
| `helpers/silicon_helper/` | the Rust root helper, its polkit rule and three units (`silicon-boot`, `silicon-mux`, `silicon-mux-guard`); `install.sh` is run by you with sudo. Its `boost-serve` / `boost-restore` (`src/boost.rs`) are the interaction boost's server, run by `tools/shell/root/lares-boost.service.in` (installed by `lares setup` R6) |
| `tools/silicon/`, `assets/sounds/silicon/` | calibration and capture scripts, the generators of the silkscreen and the click sounds, the three sounds |
Shared parts used (all in `modules/common/components` unless said): `ShadowBox` (carved and raised boxes), `GrooveSlider` and `GrooveToggle`
(the tuning sliders and switches), `RaisedButton`, `TabSelector`, `ScrollDressing` (the app list), `HoverTip`, `WheelStepper` (one detent per
swipe), `ScaleRoot`/`DeviceScale` (the design-px stage), `ThemeIsland` (the board keeps moving through a light/dark switch), `SoundPlayer`,
`DesktopNotifier`, `BoundaryClock`, `SleepWatcher`, `ConfigFile`, and `modules/common/power` (`PowerBus`: a module asks for a profile to
be held, silicon does the switching). The shell runs ONE service; every screen's owner is handed it, and the battery reader the OSD and
the lock use is silicon's (`SiliconBatteryAdapter`), because reading the battery is an embedded-controller call.

## Limits
- `silicon-helper wifi-powersave <iface> on|off` (added for the AirPlay watcher, `docs/audio.md` "Airplay"): runs `/usr/bin/iw dev <iface> set power_save on|off` after checking
  the name is a plain interface name, that it exists under `/sys/class/net` and is wireless (`wireless/` or `phy80211`), and answers what `iw ... get power_save`
  reads back (`{"ok":true,"proto":1,"wifi":{"iface":"wlp47s0","powerSave":"off"}}`). Nothing is persisted: NetworkManager puts power save back at its next
  activation of the connection. Test mode simulates it (nothing runs). `silicon-helper capabilities` (any user, nothing read) lists the verbs of the INSTALLED
  build, which is how `lares setup` (R4) tells a helper that predates the verb: the polkit rule already covers it (same program), so the one step is a
  rebuild and `sudo ./install.sh`.
- The firmware offers the charge limit at 80 and 100 only; sysfs is a cache of the request, not a readback.
- The helper only lowers the power limits (floor 8 W, ceiling the firmware's own) and only writes values the running kernel lists.
- On kernel 7.2 asus-armoury answers a `gpu_mux_mode` write with the OLD value until the restart and says so in `pending_reboot`; the helper
  accepts that read-back (an older helper recorded the switch as `failed`, so no keep prompt ran and the shell told a failure that was not one).
- dGPU-only takes effect at the next boot: its windows (5 minutes after the boot for a click on Keep, 2 minutes once the prompt is up) belong
  to the root helper and no user file changes them. The 2 minutes start when the toast is on the glass (the shell tells the helper then),
  and the toast's drain is the helper's own deadline, not a timer of the shell's.
- The first boot into dGPU-only froze the shell's GUI thread for 25 s, 6 s after its first frame (2026-11-15, frame journal: a cold NVIDIA
  shader cache under the start-up prewarm): the prompt waits for the thread like everything else, and the helper's 5 minutes run meanwhile.
- The external-display switch depends on cardwire's own detection, which may not work.
- The boot profile is the last word at boot only against the units `silicon-boot.service` is ordered after (asusd, asus-boot-quiet,
  powertop). `powertop --auto-tune` (2.16 and later) writes every policy's EPP to `balance_performance` and intel_pstate's `min_perf_pct`
  to 50, a second or more into its run: beside an unordered silicon-boot it finished later in 14 of 15 boots and the boot profile's EPP
  was gone before the login (2026-11-15). `min_perf_pct` is no knob of silicon's (the helper refuses it; it is the floor of the popup's
  maximum-performance range, 8 here and 48-50 after powertop): a drop-in on the user's own `powertop.service` puts it back
  (`ExecStartPost=/bin/sh -c 'echo 0 > /sys/devices/system/cpu/intel_pstate/min_perf_pct'`; the kernel clamps 0 to its floor).
  A knob found changed with no write of ours in the journal: `grep` the installed tools for its sysfs path (`strings /usr/bin/powertop`)
  and compare the units' finish times per boot (`journalctl -b -o short-precise -u powertop.service -u silicon-boot.service`).
- A system update holds Performance while it runs and puts the profile back afterwards; a loaded language model raises Quiet to Balanced
  and never lowers a profile. A manual profile change drops every hold and nothing is restored.
- Never create a `SiliconService` outside the shell or its own probe: it calls pkexec and the real helper. Mockups use the mock; the
  footer's Live switch in `mockups/silicon.qml` needs two clicks.

## The interaction boost
WHY. On Quiet the cores rest at 400 MHz (no turbo, EPP power) and the Arc iGPU (i915) sits in RC6 and wakes at its efficient 800 MHz
(this laptop: `gt_min_freq_mhz` 100, RPn = RP1 800, max = boost 2350). Hyprland re-composites the whole 2880x1620 output for every shell
frame, and a shell motion (a popup opening, the island moving: 200-500 ms) is over before the hardware has clocked up: measured
(2026-11-23, a surfaceless EGL burst of six blended full-output quads at 120 Hz for 333 ms), `gt_act_freq_mhz` stayed at 800 from the first
frame to the last, about 0.5 ms of GPU per full-screen blend, and no i915 waitboost came from glFinish / glReadPixels waits. The session's
frame journal shows the island motion at ~60 fps for its whole length. The boost raises the floors for the motion only.

WHAT. `silicon-helper boost-serve` (`src/boost.rs`), as root under `lares-boost.service`, listens on `/run/lares-boost/sock` -- 0600, owned
by your uid, and every connection's SO_PEERCRED uid must be yours (the other side's uid as the kernel recorded it; it cannot be forged).
One verb, one line: `boost <ms>` (50..2000) answers `ok <ms the floors stay up>`; anything else is refused and closed. It writes two
floors, through the helper's whitelisted door, classes of their own that no profile knob reaches:
- the GPU: the render GT's minimum of the i915 card that drives the eDP (`gt/gt0/rps_min_freq_mhz` where the kernel has it, else
  `gt_min_freq_mhz`; never a card that is not bound to i915), raised to `gpuMhz` (default 1600) clamped to the card's [RPn, max];
- the CPU: intel_pstate's `min_perf_pct` (one global file: whatever core the compositor runs on), raised to `cpuPct` (default 30, at most
  60, never above `max_perf_pct`). It is a percent of the TURBO maximum, so with turbo off it is a floor under the profile's own
  ceiling, which stays. This is a separate, bounded, self-restoring write: the profile path (`apply`, `set-boot`) still refuses the file.
A floor already at or above its target is left alone; a second ask while the floors are up only moves the deadline (never earlier). What
it found is written to `/run/lares-boost/record.json` BEFORE the first write, and put back when the deadline passes, when the connection
that asked closes (the shell gone, or `interactionBoost` switched off), when the unit stops (SIGTERM), at the next start and by
`boost-restore` (the unit's ExecStopPost) if the server was killed -- each value only while the file still reads what the boost wrote: a
value someone else changed meanwhile (powertop, you) stands, and the record forgets it. While a boost is up the popup's
maximum-performance range shows the raised `min_perf_pct` as its floor.

WHAT THE KERNEL DOES WITH IT (read from i915's source, not measured here). Meteor Lake runs i915 with GuC SLPC: a write of the minimum
(`intel_rps_set_min_frequency` -> `intel_guc_slpc_set_min_freq`) hands GuC a new global minimum, which it applies at once while the GT is
awake (the actual frequency is clamped into [min, max]); SLPC's own floor is the efficient frequency RP1 unless `slpc_ignore_eff_freq`,
which is why the woken GPU sits at 800 here (`slpc_ignore_eff_freq` reads 0). In RC6 the GT is power-gated and has no frequency: the floor applies when it wakes, and a
higher floor does not wake it. Whether it is up in time for the first frame of a motion is the measurement's question (`gt_act_freq_mhz`).

COST. Only while a motion runs (a kick lasts what the motion asks, a few hundred ms). The server sleeps in poll(2) between asks (no timer,
no wakeups); the shell's client forks once at start (`test -S`) and holds one connection.

INSTALL / REMOVE. `lares setup`, step R6 (optional): it writes the unit from the deployed snapshot with your uid, enables and starts it; its
undo disables and removes it (the floors go back as it stops). The helper itself must have the verb (`silicon-helper capabilities` lists
`boost-serve`; R6 prints the rebuild first when it does not). Then `"interactionBoost": true` in `silicon.jsonc`; the shell's log says
`LARES boost on` (`off`: the key; `absent`: no service). Other floors: edit `gpuMhz=` / `cpuPct=` in `/etc/systemd/system/lares-boost.service`
(0 leaves that one alone), `sudo systemctl daemon-reload && sudo systemctl restart lares-boost`. The journal: `journalctl -u lares-boost`.

HOW TO MEASURE IT. The shell's frame journal, the same scenario with the key off and on (the tour's `--boost-ab`), and per run: the iGPU's
`gt_act_freq_mhz` (or `gt/gt0/rps_act_freq_mhz`) and `gt/gt0/rc6_residency_ms` (any user), `/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq`. Energy: the package counter
`/sys/class/powercap/intel-rapl:0/energy_uj` is root-only (0400), so read it with `sudo cat` before and after a run (it wraps at
`max_energy_range_uj`), or on battery the UPower draw (`power_now`, 1 Hz and noisy: long runs only). Without the service, the floors can be
held by hand for a whole A/B (a FIXED floor for the run, the worst case for power):
    G=/sys/class/drm/card1/gt/gt0/rps_min_freq_mhz C=/sys/devices/system/cpu/intel_pstate/min_perf_pct; g0=$(cat $G) c0=$(cat $C); echo "back: $g0 $c0"
    echo 1600 | sudo tee $G; echo 30 | sudo tee $C        # raise
    echo $g0 | sudo tee $G; echo $c0 | sudo tee $C        # back (in the same shell; else the two numbers printed above)
Gates: `cargo test` in `helpers/silicon_helper` (`tests/boost.rs` runs the real binary on a copy of this laptop's sysfs), the client
`tools/dev/boost_client_probe.sh` (a stub server; ARMs norate, noclose), the root step `tools/dev/lares_deploy_probe.sh` (scenario `boost`,
ARM boostuid).

## How to change it
- A profile's values (epp, turbo, a power cap): its row in `silicon.jsonc`; takes effect within a moment.
- The boot profile: `defaultProfile` in `silicon.jsonc`; applies at the next boot.
- The popup's size: `scale.popups.silicon` in `shell.jsonc`; its colours and sounds: the board's tokens in `modules/silicon/scene/SiliconStyle.qml`
  and the sound takes in `popup/SiliconSounds.qml`, best tuned in the mockup and saved there. Gate: `tools/dev/smoke.sh mockups/silicon.qml`.
- The boards' shaders: change `modules/silicon/shaders/*.frag`, rebuild with `tools/dev/bake_shaders.sh`, check `node tools/dev/silicon_shader_gen.js --check`.
  The board has a vertex shader of its own (`silicon_board.vert`, generated with the fragment): on NVIDIA's OpenGL ES context the pair links
  at GLSL ES 3.00 and the pack has no 100 es variant (round 8: the 100 es variant had drawn with every uniform at 0). After a change to
  either run `tools/dev/silicon_board_probe.sh` and `SHIM=1 tools/dev/silicon_board_probe.sh` (Mesa as NVIDIA's ES context, in lock_env).
- The data layer or the helper's protocol: `tools/dev/silicon_service_probe.sh` (fake machine; `HELPER=real` builds the helper in test mode).
  The keep prompt toast (the gate, told to the helper on the glass, the deadline, Keep, Go back now): `tools/dev/silicon_mux_watcher_probe.sh`; the glyph never drawing a guess:
  `tools/dev/silicon_glyph_probe.sh`.
  The bar's two glyphs: each one's flourish for a pointer on it and only it (top and side bar), the GPU mode's events, its four poses and the
  profile's three the font's outline at both ends, the scales' weight and tip, the bolt's drain and strike: `tools/dev/glyph_flourish_probe.sh` (ARMs silicongroup, gpurest,
  flatscales, noweight, nocharge, boltring); frame by frame: `ONLY=fire
  tools/dev/glyph_flourish_strip.sh` (feather, bulb, bulbidle, layers, fire; leaf, scales, bolt); every state as a still, against an older
  revision: `BEFORE=<rev> tools/dev/bar_glyphs_sheet.sh`. After a font update: `python3 tools/dev/flourish_parts.py --check`.
  The fan guard and the resume re-kick: `PHASES=fan tools/dev/silicon_service_probe.sh` (ARMs noload, nokick, nobaseline, kickmanual, viashown).
  The MUX notice and the keep toast in the mockup's owner probe (O16, O19): `tools/dev/silicon_mux_notice_probe.sh` (`WAIT_MS=60000` on a cold NVIDIA shader cache: the
  first popup open takes longer than the 12 s a check waits); the low-battery card on a stalled charge: `tools/dev/battery_notifier_probe.sh`.
  The helper itself: `cargo test --offline` in `helpers/silicon_helper` (use `CARGO_TARGET_DIR` outside the repo).
