# aerial -- the network (Wi-Fi, cable, hotspot, Bluetooth, the tunnel)

## What it is
One popup that is the machine's real network card drawn as hardware: the Intel AX210 seated in its M.2 slot on a slice of mainboard, in silicon's material (one thin
slab, every part the surface's own tone, the names carved into the board, colour only where it says something). Its parts ARE the controls; everything is in view,
there are no tabs, and one popup answers any click on the bar's pill. Above the card stands THE CLOUD: a signal fan -- a standing Wi-Fi glyph -- whose origin is the
centre of the card's white label; the networks in range hang on its arcs (nearer the card = stronger), the Bluetooth devices that are not connected float in the near
field just over the card, and whatever IS connected is printed on the label itself (the docked network below, the Bluetooth devices above). Right of the card a small
globe is the tunnel. It replaced the old network module (round 10); the design is the user's, from a 15-round interview
(`docs/agent_added_files_and_folders/aerial_progress/PLAN.md`) and three feedback rounds (`R2.md`, `R3.md` beside it: their answers win).

## Where it lives
- Bar: the right island of the top bar, module id `aerial` (between `volume` and `bridge`; `network` in a `zones` list or a `scale.popups` entry
  still counts as `aerial`). ONE pill holds both glyphs, the Wi-Fi / wire / plane half and the Bluetooth rune, and is ONE button: any click
  opens the one popup, a second click closes it. Between the glyphs stand the Bluetooth battery stripe and, while the link carries a transfer, the
  down / up figures (the pill widens into the gap either side; horizontal bars only). Each half plays its own hover flourish (the fan pings, the
  wire passes data, the plane takes off, the rune empties and fills); they join the OLED care's pool as group `aerial`.
- The pill's states (the shapes that carry information stay; ON IS A COLOUR, nothing is slashed): the Wi-Fi fan by level (an alert fan with the "!"
  while a pad warns), the wired socket, the plane (airplane), the broadcasting glyph in place of the fan while the **hotspot** is up, a small
  **padlock** on the glyph while the **tunnel** is up, an **open padlock** in the warn colour on a **Public network with no tunnel**, and the
  warn / error ink after a **failed health pad**. Bluetooth: the rune, with its two dots while a device is connected.
- Popup: one layout, 760 x 646 design px, no views: the board fills the width (as silicon's does) and the height is the cloud's -- the label's centre stands
  `CLOUD.top` design px under the popup's top edge (`AerialCamera.fitNatural`). Drawn at `scale.popups.aerial` of `shell.jsonc` (1.35 by default, as
  silicon's board); the board's look (Material / Blueprint) is silicon's one setting for both boards. Detail popups open beside it as the engine's
  secondary, on the side `look.secondarySide` of `config/aerial.jsonc` names.
- OSD: Wi-Fi joined / lost / failed (with the reason in the service's words), a cable in / out, the tunnel up / down, a Bluetooth device
  connecting / leaving, and two cards of aerial's own: **autoTunnel** (the tunnel raised by itself on a Public network) and **btLow** (a device's
  battery at 20 % and 10 %). Cards only: the route of each kind is the user's (`osd.jsonc` `kinds`).
- No keyboard shortcut and no IPC verb.

## What you can do
Every part of the board and what it does:
| Part | Shows | Act |
|---|---|---|
| The label, WI-FI zone (lower) | the docked network's name over the full width (it shrinks, then is cut in the MIDDLE so a suffix always shows), band, channel, standard, dBm and link rate; "via NL . NL#42" with a shield while tunnelled; the hotspot's name; a dashed drop hint when nothing is docked ("airplane mode" / "Wi-Fi is off" when nothing can be) | drop a network = connect; pull it off = disconnect; click = that network's panel |
| The label, BLUETOOTH zone (upper) | the CONNECTED devices: one large row (glyph, name, battery, earbuds' parts), two rows, a 2 x 2 grid, then three + "+n"; Intel's small print (the real MACs) while there is none | drop a device = connect / pair; pull a row off = disconnect; click = the device's panel |
| The label as a whole | a sticker (pale paper with dark print in light mode, a dark sticker with white print in dark mode); BRUSHED CHROME while the tunnel is up (a 1.5 s wipe from the globe's side with a bright front; the print becomes a matte roughening). The chrome is a mirror lying flat: a room is reflected in it, which slides when the card tilts (airplane), shifts a little with the pointer, and carries the cloud's pulse as it leaves the label | -- |
| Screw | seated / out (a pan head with a cross slot on a threaded shaft) | click = **airplane**: the screw unscrews (one eased turn anticlockwise as it lifts), the card springs up out of the slot, the cloud folds; again seats it and gives back every radio as it was |
| The two latches | the Wi-Fi fan and the Bluetooth rune engraved on their faces, lit in the radio's own hue while it is on (locked under a hard block) | a click anywhere in a latch's GROOVE flips it = the Wi-Fi radio / Bluetooth power (the rest of the housing picks nothing) |
| Memory chip (MEM) | -- | click = the saved-networks panel (search, priority, autoconnect, forget, merge doubles, add by name; a Card page) |
| SCAN button | lit while searching | click = a 30 s Bluetooth search (strangers appear in the near field); again while it runs = stop |
| BEACON LED | blinks while visible, a shrinking ring | click = visible to others for 3 min (a device that starts the pairing from its side finds the laptop); again = invisible |
| LAN jack | green = link, amber = activity; the plug and cable while one is in | click = the wired panel |
| Test pads LINK ADDR GATEWAY DNS NET | an LED ON each gold pad (green / amber / red) | click = re-test + the pad's explanation and fix |
| RATE / DATA displays | live down / up; today's data; the speed test. The unit is engraved under each and follows the figure (`RATE - Mb/s`, `DATA - GiB`, `PING - ms`) | click RATE = a speed test (asks once: `RUN? - MB` with the cap blinking on the display); click DATA = the history |
| Globe (VPN) | the tunnel; the connected country's light | click a COUNTRY'S LIGHT = tunnel through it (Proton's own pick of server); the light clicked pulses until the tunnel answers; the light at the globe's foot = the FASTEST server, and a toggle: lit while the tunnel it raised is up, a second click takes that tunnel down; click the connected country, the sphere elsewhere or the lens = the VPN panel; drag a country onto the label = the same connect; a sideways two-finger swipe turns it, a vertical one tilts it |
| Your own hotspot in the cloud | its broadcast glyph and name, shown only while a CABLE carries the connection (the card shares what the cable brings in) | drag onto the label = start it; pull it off = stop it |
| A network in the cloud | a node in its band's hue + its name (saved ones in the text ink, strangers muted; a lock, an open lock in the warn colour when public); far strangers are dots | rest the pointer = its facts; click = its panel; drag onto the label = connect (it hovers until NetworkManager takes the connection up, then shrinks into the label once; an attempt that fails shakes and drifts back; the label says "connecting…" until the link's figures are there); let go anywhere else = it stays there until the popup closes |
| A device in the near field | its kind's glyph + name in Bluetooth's hue (strangers smaller, only while a search runs) | click = its panel; drag onto the label = connect / pair |
The owner answers the board's own switches (the screw, the latches, SCAN, BEACON, the pads: `AerialBarOwner._answer`); the popup opens the panels and routes the globe;
the cloud, the label's rows and the drag are the scene's and the DragController's.

## What it shows and where the data comes from
ONE `AerialService` per shell (`ShellServices.aerial`; its twin `AerialMock` in a mock shell), the members of `docs/contracts/aerial.md` section 2:
- Wi-Fi, the cable, the hotspot, Proton's connection, the profiles, the health pads, the speed test: the helper `tools/aerial/aerial-helper` (python,
  D-Bus: NetworkManager and BlueZ's agent), one JSON line a fact, restarted with backoff;
- ProtonVPN's facts come from its CLI, whose sign-in is in the login keyring. While that is LOCKED (behind the boot lock, until your password
  opens it) the module asks the CLI nothing by itself -- the CLI would raise the keyring's password window -- and asks within ~2 s of it opening;
  the VPN panel says so meanwhile. A tunnel you click runs the CLI whatever the keyring;
- Bluetooth adapter and devices: Quickshell's `Bluetooth`; a device's battery parts through UPower (read only, only while a device is connected);
- signal, rates and usage: `/proc/net/wireless` and `/proc/net/dev` on ONE beat (1 s while the popup is open or a pill shows the figures, 60 s
  otherwise), never a fork; usage in `~/.local/state/lares/aerial/usage.json`;
- trust (a new network is Public until marked Trusted) in `~/.local/state/lares/aerial/trust.json`; the server the last "fastest" pick landed on in `vpn.json` beside it (the
  globe's fastest light is a toggle across a restart); settings from `config/aerial.jsonc`.
- THE HEALTH PADS ARE TOLERANT: a test is a fail only after it failed repeatedly (the gateway's ping 3 tries, DNS and NET 2, 0.7 s apart; the pad stays `testing` between
  them), and a pad that did fail is asked again by itself, popup open or not (after 20 s, then every 60 s, while the connection is the same), quietly: it stays red until the
  answer, no blink. So one lost ping never paints the pill red, and a real outage clears itself when it is over.
The pill reads the same facts (`AerialPill.js` folds them into one record) and the OSD sources the same service (`OsdKinds.netModelOf`, `btRowsOf`,
the service's `osd(kind, payload)` signal for `autoTunnel` and `btLow`). The airplane memory is the service's (one per shell), so the plane holds with
no popup open.

## Settings (`config/aerial.jsonc`, example `.examples/aerial.jsonc`)
`autoTunnel` (raise the tunnel on joining a Public network, once the NET pad passes; on), `searchSeconds` (30), `visibleSeconds` (180),
`speedTest.capMB` (200), `portalCheckUrl` (Arch's nm-check page: what the NET pad fetches), `usage.enabled`, `look.secondarySide` (`far` | `start` | `end`),
`autoTunnelTo` (`"fastest"`, or a country: `"BE"`), `autoTunnelOn` (`"any"` | `"wifi"`: a cable never raises it), `newNetworks` (`"public"` |
`"trusted"`: a network marked Public is then kept as such), `bar.traffic` / `bar.trafficFromMbps` (the bar's figures, from 10 Mb/s, staying down
to half of it), `btLow` ([20, 10]: a Bluetooth device's battery is told at these), `sounds`. In `shell.jsonc`: the
zone id `aerial` (`network` accepted), `scale.popups.aerial` (1.35), `scale.popups."aerial.detail"`. Theme tokens keep their `net*` names (user
copies shadow them). The pill's tuning (the figures' margin and hold) is the Button tab of `mockups/aerial_traffic.qml`.

## How it is built
| Path | What |
|---|---|
| `modules/aerial/AerialBarOwner.qml` | the bar-side owner: the pill, the hover prebuild, the one popup (at the pill's rounded middle), `sharedFlags` (`aerialPopupOpen`, `aerialRatesWatch`); never builds a service |
| `modules/aerial/bar/` | the pill (it hovers as silicon's does: the carved container darkens, no glyph changes colour for a hover or an open popup): `AerialBarButton.qml`, `AerialPill.js`, `NetTrafficFigures.qml` + `NetTraffic.js`, `BtBattery.js` + `BtBatteryParts.qml`, `parts/NetPose.js` + `NetParts.js` |
| `modules/aerial/scene/AerialGeometry.js` | THE ONE GEOMETRY (board mm): parts, traces, the names (`LABELS`), their engraved variants (`SILK_VARIANTS`), courtyards, the latches' emblems, the label's three zones, the cloud's numbers (`CLOUD`, `ANCHORS.cloud`) |
| `modules/aerial/scene/AerialCamera.js` | the fit (the width by the board, the height by the cloud), the patches' rects, the pick, the label's affine map |
| `modules/aerial/shaders/src/`, `tools/dev/board_gen/scenes/aerial.js` | the board's and the glow's shader templates and materials (the toolkit's generator: `node tools/dev/board_gen/gen.js aerial`, then `tools/dev/bake_shaders.sh aerial`) |
| `tools/aerial/make_silk.py`, `scene/assets/silk.png` + `silk.json` | THE SILKSCREEN: names, courtyards, unit variants and emblems as one signed-distance texture (20 texels per mm: this board is drawn at 8.8 px per mm times the shell's scale, so silicon's 8 were magnified) the board shader carves (Material; the carve's widths are silicon's in PIXELS, `SILK_K` in `aerial_materials.glsl`) or inks (Blueprint); `--check` fails a stale bake and any name a part, a courtyard or a trace can cover |
| `modules/aerial/scene/AerialScene.qml` | the cached board, the live patch over what moves, the cables, the label, the glow; the ONE beat (30 Hz) and its live layer: running, or at rest (as silicon: after 30 s without the pointer the motion eases to rest over a second and no clock runs; a wake eases back over 0.4 s; no slower middle rung) |
| `modules/aerial/scene/AerialLabel.qml`, `shaders/label_plate.frag` | the label (QML on the shield's plane, crisp text) and its ground (paper / chrome / the drafted plate). The chrome's room is the shader's (`room()`: its lights and where they stand); what moves it comes in as `axes` (the scene's label map), `tilt` (the card's), `lead` (the pointer, led by `AerialPopup._leadTo`) and `pulseRadius` (the cloud's front) |
| `modules/aerial/scene/CloudHolo.qml`, `CloudPlace.js`, `CloudTag.qml`, `shaders/cloud.frag` | the cloud: the field (the pulse from the label's centre, the dotted guides), the placer (pure, node-tested: the spread, the overflow, the budget) and a tag (a `FloatCard` on the popup's one `FloatClock`) |
| `modules/aerial/scene/GlobeLayer.qml`, `GlobeMath.js`, `GlobeGesture.qml`, `shaders/globe.frag` | the globe |
| `modules/aerial/popup/` | `AerialPopup.qml` (the stage, the life, the panels' slot, the clicks), `DragController.qml` (every carry and drop), `SpeedDisplay.js`, `AerialSounds.qml` |
| `modules/aerial/secondary/` | the detail panels |
| `modules/aerial/data/` | `AerialService`, `AerialMock`, `AerialModel.js` (pure), `AerialState`, fixtures |
| `tools/aerial/` | the helper, the fake NetworkManager + BlueZ, the capture script, the test bed |
| `modules/shell/ShellServices.qml`, `ShellFrame.qml` | ONE service; one owner per screen in the zone slot `aerial`; the engine's prewarm entry; the notifier (`Aerial`) |
| `mockups/aerial.qml`, `mockups/aerial_traffic.qml`, `mockups/aerial_panels.qml` | the mockups (the settings panels; Save writes the module) |

## Limits
- The test bed (a virtual radio rig: `hostapd`, a private NetworkManager) is the user's one root step; until it is installed the service is proved
  against the fake NetworkManager and the stubs, and the desk checklist is the real join / wrong password / eduroam / Proton / hotspot / earbuds run.
- Bluetooth codecs and the audio profile show only while the device is connected; battery parts only for a device UPower mirrors.
- A hotspot needs `dnsmasq` (the card says so) and one channel for AP + client. A hotspot with no password is OPEN: the panels decide whether to
  generate one (the pill and the owner do not).
- The hotspot's broadcasting glyph has no outline of its own in `NetParts.js`, so it plays no hover flourish; the padlock badges are still ink.
- A saved profile bound to an interface name the machine no longer has (`connection.interface-name`; the card is wlp46s0 or wlp47s0 by the day here) loses that name when it
  is connected: the helper writes the profile (NetworkManager refuses it otherwise). A name that is a device of the machine is left alone.
- The password field's keyboard request belongs to the detail panels; a panel's keys come back when the pointer moves inside it (`ShellFrame` `keyReclaim`, any live body).
- A crowd shows about twenty names; the weakest strangers beyond that are dots (a hover opens one). The speed test's toast names curl's own reason when it fails.

## How to change it
- A part's place or size: `AerialGeometry.js`, then `node tools/dev/aerial_clearance_cases.js` (nothing may stand on a trace, in a hole's ring, in a courtyard or in the cut-out: it names every breach), `python3 tools/aerial/make_silk.py` (it refuses a name that is now covered), `node tools/dev/board_gen/gen.js aerial`,
  `tools/dev/bake_shaders.sh aerial`, and look: `tools/dev/aerial_r3_board.sh <dir>` (the board alone), `tools/dev/aerial_r3_popup.sh <dir>` (the whole popup).
- A name on the board: `LABELS` (it must stand in front of or right of its part, on open board); an engraved unit is one of `SILK_VARIANTS` (the words are baked:
  `SpeedDisplay.engraving` and `AerialFacts`' units must return exactly those).
- The cloud's shape: `CLOUD` (radii, half angle, the air above the label) and `CloudPlace.js` (`SPAN_SHARE`, `ROW`, the spread); `node tools/dev/aerial_holo_cases.js`.
- The label: `LABEL_HEAD` / `LABEL_BT` / `LABEL_ZONE` and `AerialLabel.qml`; `tools/dev/aerial_r3_label.sh`.
- The pill's states: `AerialPill.js` (what is true) and `AerialBarButton.qml` (how it is drawn); a new glyph needs its codepoint checked against the installed
  Symbols Nerd Font by name, and a flourish needs its outline in `tools/dev/flourish_parts.py`.
- A new OSD card: `OsdKinds.js` (KINDS, `validate`, `sampleRequest`, `notificationText`), `OsdCard.qml`, `OsdStyle.familyOf`.
- The owner's contract: `docs/contracts/shell.md` section 4.

## Checks
`tools/dev/smoke.sh shell.qml mockups/aerial.qml mockups/aerial_traffic.qml mockups/osd.qml`; `tools/dev/shell_hosted_m3_probe.sh` (the owner hosted: no
service, the flags OR over two screens, airplane across screens and a close, one popup for any click; ARMs); `tools/dev/glyph_flourish_probe.sh`
(the pill's flourishes), `tools/dev/bt_battery_probe.sh`, `tools/dev/bt_battery_motion_probe.sh`, the pill's facts (`pillfacts_*` in `glyph_flourish_probe.sh`'s pill lines),
`tools/dev/bar_glyphs_sheet.sh` (every pill state), `tools/dev/shell_layout_cases.js` (the `network` alias), `tools/dev/aerial_service_probe.sh` (also the `fastest`
fact through a restart and the pads' quiet re-test: ARMs fastestalways, nopersistfast, noretest, quietshown), `tools/dev/aerial_helper_probe.sh` (a lost ping is no
fail: ARM onetry), `node tools/dev/aerial_model_cases.js` (the tunnel's name across a switch, the OSD's card for it),
`tools/dev/aerial_integration_probe.sh` (the data layer).

The scene and the popup (round 3; every runner ends in one `RESULT` line, its ARMs are in its header):

| Runner | What it holds |
|---|---|
| `python3 -B tools/aerial/make_silk.py --check` | the baked lettering is current; no name stands where a part, a courtyard or a trace covers it (quick tier `aerial_silk`) |
| `node tools/dev/aerial_facts_cases.js`, `aerial_model_cases.js`, `aerial_holo_cases.js` | the label's facts, the model, the cloud's placer (arcs, spread, overflow, the label budget; quick tier) |
| `node tools/dev/board_gen/gen.js aerial --check` | the generated shaders match the geometry (quick tier) |
| `node tools/dev/aerial_clearance_cases.js` | the board's clearances, edge to edge, from the geometry: decorations, courtyards, traces, names, the holes and the cut-out (quick tier `aerial_clearance`; ARMs capontrace, chipathole, bigyard) |
| `tools/dev/aerial_scene_probe.sh` | the board: picks at rest and tilted, the label on the shield plane, the coax on its grommets, and by pixels (`aerial_scene_pixels.py`) the carved names, the unit labels' variants, the latches' emblems, no light inside the lifted card |
| `tools/dev/aerial_holo_probe.sh` | the cloud on the real popup (probe `qml/aerial_cloud_probe.qml`): rest before a tag opens, drags onto the label (ONE docking flight while the service keeps publishing; a refused drop drifts back), the Bluetooth drops and `carriedBt`, the globe's clicks (the fastest light as a toggle), the float, 0 frames halted |
| `tools/dev/aerial_life_probe.sh` | panels, Escape, the password flow, the speed test's two clicks and every engraved word against a baked variant, the cues' shakes, running-or-at-rest (the ladder's middle rung changes nothing, the halt eases to rest, the wake eases back) |
| `tools/dev/aerial_tunnel_probe.sh` | the tunnel's wipe on the real popup built the engine's way (asynchronously: the label's rows arrive in any order), 1.5 s long, no script error; the room in the chrome follows the pointer (by pixels: the label's middle changes on chrome, not a pixel on paper) and the plate holds the card's tilt; `WAYLAND=1` in the nested compositor |
| `tools/dev/aerial_globe_probe.sh` | the globe's marks and picks, the meridians ending on the polar circles |
| `tools/dev/aerial_r3_label.sh` (`WHAT=probe`) | the label's bands, the Bluetooth rows, the chrome wipe |
| `tools/dev/aerial_panels_probe.sh`, `aerial_qr_probe.sh`, `aerial_helper_probe.sh` | the side panels, the QR, the helper (the speed test's failure line) |
| `tools/dev/aerial_keys_env_probe.sh` | nested Hyprland: the keys reach a side panel's field and come back (`ShellFrame.keyReclaim`) |

Looks, not gates: `tools/dev/aerial_r3_board.sh` (the board alone), `tools/dev/aerial_r3_popup.sh` (the whole popup, every scenario),
`tools/dev/aerial_round_sheet.sh` (round 2 beside round 3), `tools/dev/aerial_film.sh`, `aerial_scene_sheet.sh`, `aerial_panels_sheet.sh`, `aerial_globe_sheet.sh`.
