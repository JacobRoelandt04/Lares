# Contract: aerial (the network module)

The fixed names every aerial stream builds against. The design is the user's (`docs/agent_added_files_and_folders/aerial_progress/
PLAN.md`); the measured facts are `S0.md` beside it. A name here changes only with this file, in the same commit.

## 1. Layout and ownership
| Path | What |
|---|---|
| `tools/aerial/aerial-helper` | THE backend process (python3, python-dbus + GLib): NetworkManager, the BlueZ agent, ProtonVPN, health checks, the speed test, Proton's catalogue. One per shell, started by the service. Section 3. |
| `tools/aerial/fake_nm.py` | a fake NetworkManager (+ a fake BlueZ AgentManager) on a PRIVATE bus, for the helper's and the service's tests; scenarios from the captured shapes. |
| `modules/aerial/data/AerialModel.js` | pure logic, node-testable (`.pragma library`): `MEMBERS`, folding access points into networks, signal bands with hysteresis, security from flags, the label's lines, pads, usage arithmetic, speed-test maths, the auto-tunnel rule, the doubles finder. |
| `modules/aerial/data/AerialService.qml` | the live service: runs the helper (SupervisedStream), Quickshell.Bluetooth for BT state, UPower for BT battery parts, `/proc/net/wireless` + `/proc/net/dev` by FileView (no fork). Section 2. |
| `modules/aerial/data/AerialMock.qml` | the mock twin: SAME members (section 2), scenarios + machine knobs for the mockup and probes; never touches the machine. |
| `modules/aerial/data/fixtures/` | scrubbed real captures (addresses replaced, see its README) the parser and the fake are written against. |
| `modules/aerial/scene/`, `popup/`, `secondary/`, `bar/` | the scene, the popup, the detail panels, the pill (stages 2-5). |
| `modules/common/board/`, `tools/dev/board_gen/` | the board toolkit shared with silicon (stage 2). |

## 2. AerialService / AerialMock members (identical; `AerialModel.MEMBERS` lists them; a probe fails on any one missing)
Every fact is a PLAIN object or array (no colours, no QObjects), replaced whole when it changes (never mutated in place), and
`serial` is bumped LAST in the same turn (CLAUDE.md: identity written last). `live` defaults FALSE (a host that forgets cannot reach
the machine). Times are ms since the epoch (`real`, never `int`).

### Properties
- `live: bool` (default false), `popupOpen: bool` (the host writes it), `serial: real`, `helper: {state: "off"|"starting"|"up"|"failed", error: string}`.
- `wifi`: `{ present, iface, mac, permMac, driver, firmware, country, radioOn, softBlocked, hardBlocked, scanning, lastScanMs, powersave, networks: [Net], active: Active|null, profiles: [Profile] }`
  - `Net = { key, ssid, hidden, security: "open"|"owe"|"wep"|"wpa2"|"wpa3"|"wpa2/3"|"eap", bands: ["2.4"|"5"|"6"], bestBand, signal (0-100, best AP), signalBand (0 strongest .. 3 weakest, WITH hysteresis), aps: [Ap], known, profileUuids: [uuid], connected, state: "idle"|"connecting"|"needsSecret"|"connected"|"disconnecting"|"failed", failReason, trusted: bool, ownHotspot: bool }`. `key` is the SSID, or `hidden:<bssid>` for a hidden AP. Stable order: by key.
  - `Ap = { bssid, freqMhz, channel, band, widthMhz, signal, maxRateMbps, lastSeenMs, active }`
  - `Active = { key, ssid, uuid, bssid, band, channel, widthMhz, standard: "Wi-Fi 4"|"Wi-Fi 5"|"Wi-Fi 6"|"Wi-Fi 6E"|"", dbm, rateMbps, ip4, prefix4, gateway4, ip6: [..], dns: [..], mac, sinceMs }`
  - `Profile = { uuid, name, ssid, security, autoconnect, priority, lastUsedMs, hidden, inRange, trusted, doubles: [uuid], ap, ip4method, metered, macPolicy, band, bssid, powersave, eap: { method, phase2, identity, anonymousIdentity, caCert, domain, systemCaCerts } | null }` (no secrets)
- `wired`: `{ jacks: [{ iface, kind: "rj45"|"usb", carrier, speedMbps, state, connected, uuid, ip4, prefix4, gateway4, dns, mac }] }`
- `hotspot`: `{ available, missing: ""|"dnsmasq"|"device", active, state, uuid, ssid, band, hasPassword, clients: [{ mac, ip, name, dbm }], uplink: "cable"|"none" }`
- `bt`: `{ present, powered, softBlocked, hardBlocked, discoverable, visibleUntilMs, discovering, searchUntilMs, name, address, devices: [Dev], prompt: Prompt|null }`
  - `Dev = { address, name, kind: "earbuds"|"headset"|"speaker"|"phone"|"computer"|"mouse"|"keyboard"|"gamepad"|"watch"|"generic", ring: "inner"|"middle"|"outer", connected, paired, trusted, blocked, pairing, battery (-1 unknown), parts: { left, right, case, charging } | null, rssi, profile: { active, available: [..], codec } | null }`
  - `Prompt = { rid, address, kind: "confirm"|"pin"|"passkey"|"display"|"authorize", code }`
- `proton`: `{ installed, signedIn: "yes"|"no"|"unknown", locked: bool, state: "down"|"connecting"|"up"|"disconnecting"|"failed", server: { name, country, city, load, protocol, features } | null, sinceMs, killSwitch: "off"|"standard", netshield: "off"|"malware-only"|"malware-ads-trackers", ipv6, customDns, autoTunnel: bool, waiting: ""|"portal"|"link", fastest: bool }`. `server.name` is the ACTIVE CONNECTION's (`ProtonVPN NL#799` -> `NL#799`): the CLI's last words describe it only when they name the same server (across a switch they are the previous tunnel's). `fastest`: the tunnel that is up or connecting was asked for with Proton's own pick (a `vpnConnect` with no country, city, server or `random`); it falls with the tunnel; it survives a restart through `vpn.json` while the tunnel's server name is the one that pick landed on
- `catalog`: `{ serial, tier, countries: [{ code, name, lat, lon, servers, minLoad, features, cities: [{ name, lat, lon, servers: [{ name, load, features, status }] }] }] }` (Proton's cache, digested; empty until read)
- `health`: `{ pads: [{ id: "link"|"addr"|"gateway"|"dns"|"net", state: "unknown"|"testing"|"ok"|"warn"|"fail", detail, atMs, ms }], portal: { present, url } }`
- `rates`: `{ iface, rxBps, txBps, atMs }` (the link carrying traffic; never read from the main default route alone, S0)
- `usage`: `{ todayBytes, monthBytes, current: { key, bytes }, byNetwork: [{ key, label, today, month }], days: [{ day: "YYYY-MM-DD", bytes }] }` (30 days)
- `speed`: `{ state: "idle"|"armed"|"latency"|"down"|"up"|"done"|"failed", liveMbps, result: { downMbps, upMbps, latencyMs, jitterMs, colo, bytes, atMs } | null, refused: ""|"public"|"metered" }`
- `airplane`: `{ on, remembered: { wifi, bt } }`
- `errors`: `[{ id, part, text, way, sinceMs }]` -- `part` is a scene part id: `label`, `screw`, `dip.wifi`, `dip.bt`, `mem`, `jack`, `bt.scan`, `beacon`, `pad.<id>`, `rates`, `usage`, `globe`, `hotspot`, `bt:<address>`, `net:<key>`.
- `config`: the parsed `config/aerial.jsonc` (section 5).

### Signals
- `osd(string kind, var payload)` -- kinds `autoTunnel` `{ country }`, `btLow` `{ address, name, battery }`; the OSD source listens.
- `secret(string uuid, string text)` -- the answer to `revealSecret` (never stored in a property).
- `failed(string id, string text)` -- every failed intent, also pushed into `errors`.
- `cue(string part)` -- ONE short physical cue per failed intent, for the scene part the error names (`part` as in `errors`): the label shakes, a DIP springs back. Fires for EVERY failure (a repeat whose toast stays quiet too), never stored: it is a moment, not a fact.
- ERRORS ARE TOASTS (round 2). The `errors` fact stays the service's record, but NOTHING in the popup may draw it persistently (no error tags). The service tells each failure through its `notifier` (a DesktopNotifier the shell hands down through `ShellServices`; null = no toasts, as in mockups; the mock has the same member): title (what failed: "Could not join Cafe"), body (the words + the way out), an action where there is one (the NET pad with a login page up: "Open the login page" -> `openPortal()`; a signed-out Proton names `protonvpn signin`). One KEY per error id (`fail-<id>`): a repeat REPLACES its toast; a repeat with the same words while the error still stands, within 60 s, is not told again (a dismissed toast stays gone); a cleared or dismissed error withdraws its toast (`AerialToasts.qml`, pure words in `AerialModel.toastWords`).

### Intents (methods; each returns nothing and answers through the facts)
Wi-Fi: `scan()`, `connect(key, opts)` (opts: `{ password, profileUuid, hiddenSsid, eap: { method, phase2, identity, anonymousIdentity, password, caCert, domain } }`), `disconnect()`, `forget(uuid)`, `setRadio(on)`, `setAutoconnect(uuid, on)`, `setPriority(uuid, n)`, `revealSecret(uuid)`, `updateProfile(uuid, patch)` (patch keys: `ipv4: {method, address, prefix, gateway, dns}`, `ipv6: {method}`, `mac: "permanent"|"random"|"stable"`, `metered: "yes"|"no"|"unknown"`, `band: ""|"bg"|"a"|"6GHz"`, `bssid`), `mergeDoubles(keepUuid, dropUuids)`, `addNetwork(ssid, security, password)`, `setTrusted(uuidOrKey, on)`, `setPowersave(on)`.
Wired: `connectWired(iface)`, `disconnectWired(iface)`. Hotspot: `startHotspot()`, `stopHotspot()`, `configureHotspot({ ssid, password, band })`.
Bluetooth: `setBtPowered(on)`, `btSearch()`, `btStopSearch()`, `btVisible()`, `btHide()` (round 6: SCAN and BEACON are toggles: the owner ends what runs on a second press), `btConnect(a)`, `btDisconnect(a)`, `btPair(a)`, `btCancelPair(a)`, `btTrust(a, on)`, `btBlock(a, on)`, `btForget(a)`, `btRename(a, name)`, `btSetProfile(a, profile)`, `btAnswer(rid, accept, value)`.
VPN: `vpnConnect({ country, city, server, feature })`, `vpnDisconnect()`, `vpnSet(key, value)`, `setAutoTunnel(on)`, `refreshCatalog()`.
Health / speed / misc: `testPad(id)` (`"all"` too), `openPortal()`, `armSpeedTest()`, `runSpeedTest()`, `cancelSpeedTest()`, `setAirplane(on)`, `dismissError(id)`, `touch()`, `refresh()`.

## 3. The helper's protocol (`tools/aerial/aerial-helper`)
Started as `setpriv --pdeathsig TERM -- python3 -I tools/aerial/aerial-helper [--bus-address <addr>]` (the address only for tests and
the test bed; default the system bus). One JSON object per line, both ways, UTF-8.

**Out (stdout)**: `{"t": <type>, ...}`
- `hello` `{v: 1, pid}` -- first line, before the slow imports finish is not required (it is cheap).
- `wifi` `{device: {...}, aps: [{path, bssid, ssid (str; "" hidden), ssidHex, freq, width, strength, maxBitrate, flags, wpaFlags, rsnFlags, lastSeen}], activeAp, scanning, lastScan}` -- a snapshot whenever any of it changes, coalesced to <= 1 per 100 ms.
- `devices` `[{path, iface, type: "wifi"|"ethernet"|..., driver, state, stateReason, hwAddress, permHwAddress, managed, carrier, speed, activeConnection, ip4, ip6}]` (virtual interfaces included; the service filters).
- `active` `[{path, uuid, id, type, devices: [iface], state, vpn, default4, default6, specific}]` -- active connections.
- `profiles` `[{uuid, id, type, ssid, mode, security, autoconnect, priority, timestamp, hidden, filename, ip4method, metered, macPolicy, band, bssid, eap}]` -- no secrets ever.
- `nm` `{running, state, primary, connectivity, wirelessEnabled, wirelessHardwareEnabled, version}`.
- `stats` `{iface, rx, tx, atMs}` -- only while asked (`stats` command), from NM `Device.Statistics`.
- `link` `{iface, standard, dbm, rxMbps, txMbps}` -- after `iw_link` (one `iw` call).
- `agent` `{rid, kind, device, code}` -- a pairing question from BlueZ while the agent is registered; answered by `agent_reply`.
- `proton` `{state, server, load, protocol, raw}` / `proton_config` `{...}` / `catalog` `{path, mtime, tier, countries}`.
- `keyring` `{locked}` -- `true` when a `proton` `status` / `config` was refused because the login keyring is locked (the reply: `ok: false`, "The keyring is locked"; the CLI is not run, so no password window is raised), `false` once it is open (the helper looks every 2 s meanwhile): the service then asks again. `connect`, `disconnect` and `set` are the user's clicks and run whatever the keyring.
- `pad` `{id, state, detail, ms}` / `portal` `{present, url}` / `speed` `{phase, liveMbps, result}`.
- `reply` `{id, ok, error, data}` -- to every command carrying an `id`.
- `log` `{level, text}` -- never a fact.

**In (stdin)**: `{"id": N, "cmd": <name>, ...args}`: `scan`, `activate {uuid, iface?, ap?}`, `add_activate {ssid, security, psk?, eap?, hidden?, iface?, bssid?}`, `deactivate {uuid}`, `delete {uuid}`, `update {uuid, patch}`, `secrets {uuid}` (reply `data: {psk}`), `wifi_enabled {on}`, `hotspot {on, uuid?, ssid?, psk?, band?}`, `stats {iface, ms}` (0 = stop), `iw_link {iface}`, `agent {on}`, `agent_reply {rid, accept, value?}`, `proton {action: "connect"|"disconnect"|"status"|"config"|"set", args}`, `catalog {path}`, `pad {id}`, `speed {action: "run"|"cancel", capBytes}`, `quit`.

**As built (stream H, 2026-11-19; these readings are now the contract):** array events are `{"t": "devices"|"active"|"profiles",
"v": [...]}`; the pad command names its pad by the key `pad` (`{"id": N, "cmd": "pad", "pad": "net"}`; `"all"` too), never by `id`;
`proton_config` is the CLI's table flat (`{"t":"proton_config","netshield":"malware-only","kill-switch":"off",...}`); the `proton`
event's `server` is `{name, city, country, via}` (`via` = the Secure Core entry country) and its `state` is the CLI's word
(`connected|disconnected|unknown`) -- up / down comes from `active[]` (`.proton`, `.killswitch` marks) and `nm.primaryReal` (the
primary connection with Proton's `pvpn-killswitch*` dummies skipped); catalog `features` are name lists (`securecore`, `tor`, `p2p`,
`streaming`, `ipv6`); the `agent` event also has kind `cancel` (a question that is gone); the `speed` event has phase `cancelled`
(the service maps it to `idle`) and `error` on `failed` (curl's own words, e.g. `latency: curl: (7) Failed to connect ...`, or `HTTP 429`; the run's reply carries the same text; a lost probe or one refused transfer does not fail the test, a transfer cut by the clock still counts what it moved); extras the service may use: `wifi.radioOn` / `hardwareEnabled` /
`lastScanMs`, `ap.lastSeenMs` / `mode`, device `typeCode` / `stateCode` / `stateReasonCode`, `link.bssid` / `freq` / `ssid`;
`iw` EHT reads "Wi-Fi 7"; the `profiles` line carries `complete` (false until every saved profile ListConnections named has answered GetSettings: the first-run trust seeding waits for it); a hidden network (or any AP whose broadcast SSID is not the one asked) is activated with the specific object "/" (NetworkManager refuses the nameless AP: the test bed). The details and examples: `aerial_progress/H.md`; the fake and the probe: `tools/aerial/fake_nm.py`,
`tools/dev/aerial_helper_probe.sh`.

**As built (stream I, 2026-11-19, the integration; these readings are now the contract too):**
- `pad` names its pad by the key `pad` (`{"cmd": "pad", "pad": "net"}`), as above; the contract line `pad {id}` is superseded.
- `stations {iface}` -> `{"t":"stations","iface","v":[{mac, dbm, connectedS, ip, name}]}` (also the reply's `data`): `iw dev <if> station dump`
  (no root) merged with dnsmasq's lease file `$AERIAL_LEASE_DIR` (default `/var/lib/NetworkManager`)`/dnsmasq-<iface>.leases` when readable
  (`ip` / `name` are "" otherwise). The service asks every `stationsEveryMs` (4 s) ONLY while the hotspot is active and the popup open, and
  drops `hotspot.clients` when it stops.
- `bt` (event, no command needed; `{"cmd":"bt"}` re-reads): `{present, address, name, powered, powerState, softBlocked, hardBlocked, discovering,
  discoverable, devices: [{address, name, paired, connected, rssi|null}]}` from BlueZ's own properties (`GetManagedObjects` at `/` +
  `PropertiesChanged` / `InterfacesAdded` / `InterfacesRemoved`, name owner watched), read-only, coalesced like every snapshot. `softBlocked` =
  `PowerState` `off-blocked` and no hard block; `hardBlocked` = a `bluetooth` rfkill's `hard` file (`$AERIAL_RFKILL_DIR`, default
  `/sys/class/rfkill`; re-read every 3 s only while the radio is `off-blocked`, since a switch under a blocked radio sends BlueZ nothing).
  The service merges `address`, the rfkill pair and each device's `rssi` (0 when null: BlueZ drops RSSI when discovery stops) into
  `bt`; presence, power, devices and everything else stay Quickshell's.
- `update {uuid, patch}` patch keys beyond the contract's: `psk` (a known network's new password; an empty one is "no change"),
  `eap: {password, identity, anonymousIdentity}`, `powersave` (2 off, 3 on: `802-11-wireless.powersave`), `ssid`, `autoconnect`, `priority`.
  `hotspot_config {uuid?, ssid?, psk?, band?}` saves the hotspot's profile WITHOUT starting it (the first AP-mode profile, else a new one
  with `ssid` required).
- the card: `wifi.device` has `driver`, `driverVersion`, `firmware` (NetworkManager's `FirmwareVersion`), `country` (see `reg`) and `powersave`
  (the active profile's setting; the model's `wifi.powersave` is `=== 3`). `reg {}` -> `{"t":"reg","country","phys":[{scope, country,
  selfManaged}]}` from `iw reg get`, asked once at start and on `reg` (the service sends it from `refresh()`); the country is the
  self-managed phy's, else the global one, `00` / `99` = "". `profiles[]` carries `powersave`.
- NetworkManager accepts an activation and FAILS it later (the `activate` / `add_activate` reply is ok): the service watches the Wi-Fi device
  (`devices[].stateCode`: 40-90 in progress, 60 asked for secrets, 100 done, 120 failed or back to 30 / 20 after progress, `stateReason`
  `no-secrets` for a wrong password) and turns it into `net:<key>` `failed` with `Model.activationFailText`.

**Rules**: every NetworkManager call is async (no call blocks the loop: a stuck NM never stalls the stream); a command's failure is
a `reply` with `ok: false` and NetworkManager's own error text; the helper never prints a secret except the `secrets` reply; a turn
that raises is logged and the loop goes on (a dead loop is a stuck module); it exits on stdin EOF.

## 4. The shell's side
One `AerialService` (or `AerialMock`) in `ShellServices`; owners are `shellHosted` (they build no service and write no service
property; `sharedFlags.aerialPopupOpen` is OR-ed and written once). The id is `aerial`; `network` stays an accepted alias in
`shell.jsonc` `zones` and `scale.popups`.

## 5. `config/aerial.jsonc` (example `.examples/aerial.jsonc`)
`{ "autoTunnel": true, "searchSeconds": 30, "visibleSeconds": 180, "speedTest": { "capMB": 200 }, "portalCheckUrl": "http://ping.archlinux.org/nm-check.txt", "usage": { "enabled": true }, "look": { "secondarySide": "start" } }` (`secondarySide`: `"start"` the left of a horizontal bar's popup (the default; the detail is long and tall, so its long edge joins the main popup's, as the stocks' detail does), `"end"` the right, `"far"` away from the bar)
