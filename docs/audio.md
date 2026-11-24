# audio -- volume and the sound mixer

## What it is
A bar pill with a speaker half and a microphone half, and a popup that is pavucontrol's whole window rebuilt in the shell's material:
every app's volume, every output and input device, the cards and their profiles. Nothing in pavucontrol needs a button of its own any more.
It also draws what pavucontrol cannot: a line from each stream to the device it really plays on, a glow in the rows while something sounds
and a test tone per output.

## Where it lives
- Bar: the right island of the top bar, module id `volume` (between `player` and `aerial`). The speaker half shows the device by type
  (speaker, headphones, headset, HDMI, Bluetooth); the microphone half shows the microphone. The speaker has three glyphs: no wave at 0 %
  (below half a percent, where the figure reads 0), one wave from 1 % up to 50 %, two above (the boost range stays at two); the Material
  set has no third wave. The glyphs differ in width, so the speaker is placed as the two-wave one would be and its body never moves: a
  wave grows outward (`AudioBarButton` `pinGlyph`; the thresholds are `AudioGlyphs.levelLowMax` / `levelMedMax`, tuned in
  `mockups/audio_button.qml`). The mockup's page for the check: `tools/dev/audio_levels_probe.sh` (the glyph by level and the body's x at 4x). Each half keeps its
  glyph when muted: a live half wears its own colour (the speaker green, the microphone yellow, neighbours on the hue circle; the bar's hue
  table, `modules/common/glyphs/BarHues.js`), a muted half the muted ink. The pill is the bar's carved pill (silicon's, aerial's): the pointer on
  either half deepens its fill a shade; the glyphs keep their colours, and an open popup is not marked on the pill.
- Pill: left click on the speaker opens the popup on Outputs, on the microphone on Inputs (on the half whose tab is showing it closes; on
  the other it switches tab). Right click mutes that half. The wheel moves the speaker's volume or the microphone's gain by 1 % a step.
  Over the lock screen a click on either half mutes.
- Popup: 720 px wide (design px), five tabs: Playback, Recording, Outputs, Inputs, Configuration. Opened without a half (a toggle) it starts on the tab it last showed.
  One layout. Its size can be set with `scale.popups.audio` in `shell.jsonc`.
- The hardware keys (volume up and down, mute, microphone mute) and their on-screen card are the OSD's, not this module's: see `osd.md`.
- No shortcut and no IPC verb of its own.

## What you can do
- Switch tab by clicking it or with a two-finger sideways swipe; up and down scrolls the list.
- A row's tools (test tone, mute, lock channels, the advanced chevron) are always shown, as bar glyphs are: muted ink at rest, the pair's
  hover colour (`BarHues.audioHover`, the bar's one hover clock) under the pointer, the accent while one holds a state (a muted device's crossed
  speaker, an unlocked channel pair, a running tone).
- Playback and Recording: one row per app stream (name, title, state, mute, lock channels, a slider per channel with percent and dB).
  A box of the devices stands beside the list and a line runs from each stream to the device it goes to. Drag the ball at the line's end
  onto another device to move the stream there, or click it to pick from a list; right click a row for the same list and "Terminate
  Playback" / "Terminate Recording". Playback also has the System Sounds row (the volume of event sounds).
- Outputs and Inputs: one row per device with its name, card, state, mute, lock channels, a Port chip ("(unplugged)" as pavucontrol prints
  it) and an Advanced fold (the port's latency offset, and on a digital output the formats it takes through). A click on a row makes the
  device the default: the ball in the rail beside the list glides to it. Right click: Set as default, Rename device, Test tone, "Allow up
  to 153 %" (the slider's boost). An output's tone button plays a short test sound to that output only.
- Configuration: one row per card with its Profile and, for a Bluetooth card, its Codec; three switches at the foot: Show volume meters
  (default on), Hide unavailable card profiles, Feedback sound (a click after a sink's volume change, off by default).
- Playback, Recording, Outputs and Inputs have a "Show" chip at the foot that filters the list (All streams, Applications, Virtual streams;
  All / Hardware / Virtual output devices; All / All except monitors / Hardware / Virtual input devices / Monitors). The choice is remembered.
- A wheel over a slider is that slider's only when the pointer moved onto it and rested there; a scroll through the list never changes a
  volume by accident. The percent turns the accent colour when the wheel is the slider's.

## What it shows and where the data comes from
| Part | Source |
|---|---|
| Nodes, per-channel volume, mute, defaults, the link graph (where a stream really goes) | Quickshell's PipeWire binding |
| Cards, ports, profiles, codecs, latency offsets, formats, moving a stream, the full snapshot | `pactl` (`-f json list`, one child per slot, every call with a deadline) |
| A node's error state | `pw-dump Node` |
| The configured default and System Sounds | `pw-metadata` |
| Terminate | `pw-cli destroy` (pactl has no such verb) |
| Test tone and feedback sound | `pw-play`, targeted at one output |
| Levels | a PipeWire peak monitor per row, only on the tab being shown and only where it wakes nothing (a running stream, an output something plays to; the Inputs tab meters its microphones while it is open) |
| Kept settings and device names | `~/.local/state/lares/audio/popup.json` (filters, renames, the three switches) |
At rest the service runs nothing: no child, no subscription, no timer. Open, one `pactl subscribe` says when to read and a heartbeat reads
anyway, because a hung server sends no events. Every change is read back: a row says when a change did not take ("Did not move to
Headphones: still on Speaker"), in pactl's words when pactl refused. When the server is unwell the popup says so in a banner with what it is
made of: "The sound server is not answering" (`tools/audio/lares-audio-diag` names the hung part), "... is not running", "pactl is not
installed", "pactl failed", or "The shell lost its connection to PipeWire". Rows stay with what was last known and the calls that need pactl
fail at once with the reason.

### The flourishes (the bar pill)
Each half of the pill has a short flourish, a SOUND CHECK (`modules/bar/audio/parts/AudioPose.js`; `life()` there is how long each
runs, 0.6 to 0.85 s):
- **The speaker THUMPS**: its cone kicks out from its back edge (which never moves: the pinned edge), each wave it has is pushed
  outward in turn, and one more wave is thrown from the outermost and thins to nothing. The level it shows is in every frame (its own
  waves only shift; the thrown one is a thin crescent on the move, never a second real wave). A speaker that makes NO SOUND -- muted, or
  at no volume, which is the same glyph on this machine (the route zeroes the volume on mute) -- kicks as hard and lets out a PUFF, a
  cartoon "poof": ONE little cloud is blown out of the mouth (fast, then it all but stops), billows into a cumulus as it comes (its
  lobes swell out of its body: a flat foot, a bumpy top, higher in front -- the silhouette that is still a cloud at the bar's size),
  hangs a moment, rising, and wears away from its back while it thins. It is one outline to the last: no loose discs, which read as
  bubbles (the two round ones it was before did). A puff is air, not sound: never an arc.
- **The microphone is TOSSED AND CAUGHT**: the cradle crouches, the capsule is thrown up out of it, turns once end over end and drops
  back in; the cradle takes the catch on its stem like a spring, and the thud is picked up -- two small crescents fly off either side of
  the capsule's head. MUTED it is a dud: a small hop with a shake of the head, a small catch, nothing picked up.
- **Headphones and a headset BURST**: the cups are drawn in a little toward each other (the build-up), then both let go -- two waves fly
  off each side, one after the other, and the cups are thrown apart; the headband's stiffness springs them back and they ring down.
  The waves go outward (between the cups there are under four pixels at the bar's size). Muted: the squeeze and a smaller spring, no wave.
- Any other output device (a dock, a phone, a speaker box, a car, HDMI, Bluetooth) nods.

A MUTED half makes the start and no sound comes out. Every pose is the font's own outline at its first and last instant. It plays
when the pointer comes onto that half and moves, and at random with the OLED care (`docs/oledcare.md`: group `audio`, glyphs
`audio.speaker` and `audio.mic`); `flourishEnabled: false` on `AudioBarButton` switches both off. The numbers (kick, puff, toss height,
squeeze, recoil, ...) are the `DEFAULTS` at the top of `AudioPose.js` (the puff's lobes: `PUFF_LOBES` there); the thrown things (the
wave; the puff's outline, `clump`, a union of discs as one contour) are `modules/common/components/GlyphSignal.js`. The outlines are `parts/AudioParts.js`, written by `tools/dev/flourish_parts.py` from the
installed font, which also refuses a font whose capsule or cups are not where the poses move them (a glyph an icon pack swaps in has
no outline there and no flourish). Check: `tools/dev/glyph_flourish_probe.sh` (the `pill_*` lines; ARMs mutedwave, soundpuff, puffloose, mutedmark,
mutedburst, bothhalves), strips `SET=pills tools/dev/glyph_flourish_strip.sh`.

## Airplay
Sound to an AirPlay (RAOP) speaker, through PipeWire's `raop-discover` (its sink is `raop_sink.<host>.<ip>.<port>`, one `libpipewire-module-raop-sink`
per speaker). Two things follow from it, both in `modules/audio/data/AirplayWatch.qml` (ONE per shell, built by `ShellServices` as `services.airplay`;
`AirplayWatchMock.qml` is the twin of `SHELL_SERVICES=mock`; the pure half is `AirplayRules.js`).

**The facts.** `sending`: a PipeWire link group into a RAOP sink is `Active` (Quickshell's `Pipewire.linkGroups`: the model and each group's `state` say
when it changes; nothing polls). `latencyMs`: the sink's `raop.latency.ms` + `sess.latency.msec` from its module's arguments, read with ONE `pw-dump Module`
when a RAOP sink first appears (matched by ip and port in the sink's name; `raop.ifindex` names the Wi-Fi interface). `mpdInto`: mpd's own stream
(`mpd.PipeWire`) is among the active links. `delayMs`: `latencyMs` while `mpdInto` (`config.delay` replaces it with a number, `delayExtraMs` is added, never
below 0), else 0. `modules/audio/airplay/AirplayDelay.qml` is the shell's one number for it (a singleton `ShellServices` writes; 0 everywhere else, so a
mockup is the player as it was).

**Power save.** The stream drops out while the radio sleeps between beacons. NetworkManager cannot change power save on an active connection (it applies
`802-11-wireless.powersave` only at activation), so it is `iw dev <iface> set power_save off|on` as root: the silicon helper's `wifi-powersave` verb behind
the user's passwordless polkit rule (`helpers/silicon_helper`, `docs/silicon.md`). Sending for 2 s: power save is read (`iw ... get power_save`, no root);
`on` is turned off through `pkexec` (after a `pkcheck` that says polkit would not ask: no dialog ever opens from here) and a record says WE did
(`$XDG_RUNTIME_DIR/lares/airplay-powersave.json`); already `off` is the user's own setting, never touched and never restored. While sending it is read
again every 30 s (one single-shot) and put back off when NetworkManager turned it on (a roam, a reconnect). `graceSec` (60) after the last sound, if it is
ours, it is turned on again; a shell that died with it off puts it back at its next start when nothing is sending. A missing verb, helper or rule is said
once in the log and not retried until the next sending session; `lares setup` row R4 prints the root step (rebuild the helper as yourself, `sudo
./install.sh`, the same install as before).

**Consumers** (all read `AirplayDelay.delayMs`; the popup's playhead, a scrub and the queue stay live): the track OSD card (`MpdSource`) for a song change that
came by itself is shown that much later, a media key's card at once (a newer change replaces the pending one, a stop, a pause or a disconnect drops it); the
bar glyph's new-song flourish (`PlayerBarButton`, every change waits, a skip from the popup too: the sound it asked for is as late); the lyrics' active line and
reading head (`PlayerData`: position minus the delay, clamped at 0)). The delay holds while mpd is paused (its link into the speaker is Paused, not gone), so the lyrics' line does not jump by the delay at a pause and back at the resume.

**Settings.** `config/airplay.jsonc` (template `.examples/airplay.jsonc`, read hot): `powersave` (true), `graceSec` (60), `delay` (`"auto"` or ms), `delayExtraMs` (0).
**Check:** `tools/dev/airplay_probe.sh` (a private PipeWire, stubs for `iw`, `pkexec`, `pkcheck` and `pw-dump`; ARMs listed in its header),
`tools/dev/airplay_setup_probe.sh` (setup's R4 row and the printed step), `cargo test` in `helpers/silicon_helper`. What only a real AirPlay session shows: that the sum
`raop.latency.ms` + `sess.latency.msec` is how late it sounds (`delayExtraMs` corrects it) and that a roam really turns power save back on.

## Settings
`config/audio.jsonc` (read hot; example `.examples/audio.jsonc`; the airplay watcher has its own file, above):

| Key | Meaning | Default |
|---|---|---|
| `pill.speakerOpens` / `micOpens` | the tab each half of the pill opens (`playback`, `recording`, `sinks`, `sources`, `cards`); the half that opened it takes the accent | `sinks` / `sources` |
| `hide` | device names (`pactl list short sinks` / `sources`, `*` any text) left out of Outputs, Inputs and a stream's device box; the default and a device a stream is on are always listed | `[]` |

The state file above holds what the popup keeps; `shell.jsonc` places the pill in its zone and sizes the popup. The look
(figure slots, row heights, the patch line's waves, the rail) is tuned in `mockups/audio.qml` (`quickshell -p ~/.config/quickshell/mockups/audio.qml`;
its Faults tab breaks the mock sound system every way listed above) and the slider in `mockups/groove_slider.qml`; Save writes the module.
The bar button has its own mockup, `mockups/audio_button.qml`.

## How it is built
| Path | Role |
|---|---|
| `modules/bar/audio/AudioBarButton.qml` | the pill: draws the glyphs and reports clicks and the wheel; what they do is `modules/shell/VolumeParity.qml` (one volume step for the whole shell, counted from where the hand took the level) |
| `modules/bar/audio/data/PipewireService.qml`, `PipewireMock.qml` | the live PipeWire lists (hardware sinks and sources, output and input streams) and a mock with the same members |
| `modules/audio/AudioBarOwner.qml` | the popup's bar-side object: the tab, the popup's open flag, `showHalf(half)` |
| `modules/audio/AudioPopup.qml` | the popup content: tabs, banner, lists, the one wheel reader, the foot |
| `AudioList.qml`, `AudioRow.qml`, `AudioChannel.qml`, `AudioReveal.qml`, `AudioCardRow.qml`, `AudioAdvanced.qml`, `AudioChoice.qml`, `AudioRenameField.qml` | one tab's rows, one row, one slider line, a part that comes and goes, a card, the Advanced fold, a pick list, the rename field |
| `AudioSockets.qml`, `AudioPatchBay.qml`, `AudioPeak.qml` | the device box beside Playback and Recording, the lines and the travelling marker, one row's level |
| `AudioStyle.qml`, `AudioGlyphButton.qml` | sizes and colours of the popup, the small glyph button |
| `modules/audio/data/AirplayWatch.qml`, `AirplayWatchMock.qml`, `AirplayRules.js`, `modules/audio/airplay/AirplayDelay.qml` | the AirPlay watcher, its twin, its pure half and the shell's one delay number (above) |
| `modules/audio/data/AudioService.qml`, `AudioMock.qml` | the one service (every verb, the read-back, health) and its mock; `AudioWorld.qml` is the fake sound system the mock stands on |
| `AudioCalls.qml`, `AudioModel.js` | the child processes with their deadlines; the pure half that joins pactl, pw-dump and the binding into rows and judges whether a change took |
Shared parts used (`modules/common/components`): `GrooveSlider` (the volume groove with its ball, boost and mute behaviour),
`GrooveToggle`, `TabSelector`, `ShadowBox`, `SlotRail` (the default's rail), `ScrollDressing`, `AnimatedListRow`, `FloatingMenu` (the
right-click and pick lists), `HoverTip`, `AudioGlyphs` (device glyphs by type), `WheelStepper`. The service is built once per shell and
handed to every screen's owner.

## Limits
- Quickshell does not reconnect to PipeWire after the daemon restarts; the popup falls back to `pactl` and says the shell lost the
  connection until the shell restarts.
- Renaming a device is the shell's own label, kept in `popup.json`: pavucontrol's rename needs a protocol pipewire-pulse does not
  implement.
- No "lock card to this profile" (pipewire-pulse has no such message) and no Ctrl+1..5 tab keys: a popup has no keyboard unless it asks.
- A stream the session manager marks as not movable (`node.dont-move`) is reported as not moved: pactl exits 0 for it and only the link
  graph tells.
- WirePlumber takes no device whose routes all say unavailable, so making such a device the default has no effect.
- A device-backed node answers a volume write later than the next write arrives; the wheel therefore counts from the level the hand took.

## How to change it
- A size or colour of the popup: `modules/audio/AudioStyle.qml` (`popupWidth`, `listHeight`, figure slots), tuned in `mockups/audio.qml`.
- A tab's filter names or a default filter: `FILTERS` and `FILTER_DEFAULT` in `modules/audio/data/AudioModel.js`.
- The step and feel of the wheel on the pill: `VolumeParity.qml`; the keys' step: `volume.step` and `mic.step` in `osd.jsonc`.
- A new setting switch on Configuration: an `Option { text; settingKey }` in `AudioPopup.qml`; it is stored by `AudioService.setSetting`.
- The slider's behaviour (ball, bend, boost): `modules/common/components/GrooveSlider.qml`, tuned in `mockups/groove_slider.qml`.
Gate: `tools/dev/smoke.sh mockups/audio.qml mockups/audio_button.qml mockups/groove_slider.qml`, `tools/dev/audio_levels_probe.sh`.
