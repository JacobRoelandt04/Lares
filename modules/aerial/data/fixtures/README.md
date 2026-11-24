# aerial fixtures

Scrubbed copies of the user's capture (`~/.cache/lares/aerial-capture/20261119-222354/`, 2026-11-19), the shapes the helper's parsers,
the fake NetworkManager and the stubs are written against. Made by `tools/aerial/make_fixtures.py` (run it again after a new capture).

## What was replaced (the same real value always gets the same fake one, in every file)
- every MAC / BSSID (also nmcli's `\:` spelling) -> `02:AE:00:00:00:NN`, a locally administered range
- every IPv4 address (the public IP, LAN, gateway, DNS servers, the tunnel's) -> `192.0.2.x`, `198.51.100.x`, `203.0.113.x`
  (RFC 5737 documentation ranges); `127.*`, `0.0.0.0` and masks stay
- every IPv6 address -> `2001:db8::N` (global) or `fe80::N` (link-local). The first scrub missed the ones right after a `:`
  (nmcli's `IP6.ADDRESS[1]:...`): they were put right by hand on 2026-11-23 (`2001:db8::c` .. `::12`, `fe80::d` .. `::13`), and the
  scrubber now finds them as the leak check does (`tools/publish/privacy_check.py`)
- every saved network, neighbour and profile name -> neutral names (`HomeNet-AP`, `Saved-A`, `Neighbour-A`, `Cafe-WiFi` ...), the real ones read from the private list
  (`config/privacy.jsonc` `replace`, never tracked);
  `eduroam` and `Hotspot` are generic and stay; the hotspot's SSID is `laptop-hotspot`
- every connection UUID -> a UUID derived from it (`uuid5`)
- the school login (identity, anonymous identity, domain), the user name and the host name, the provider's DNS domain
- NOT copied at all: the Proton account line, `proton_info`, nothing from `upower` / `pactl`, no secret (the capture holds none: nmcli
  printed `<hidden>`)
Proton's own server names (`NL#799`, `IS-BE#3`) are public and stay.

## The files
| File | What it is (capture file) |
|---|---|
| `iw_link.txt`, `iw_station.txt`, `iw_reg.txt` | `iw dev wlp47s0 link`, `station dump`, `reg get` (the AX210 is self-managed) |
| `nm_wifi_list.txt` | `nmcli -t dev wifi list` (the five APs the card saw; one SSID on two bands) |
| `nm_devices.txt`, `nm_devices_vpn_up.txt` | `nmcli dev` before and while Proton's tunnel is up (the dummies `pvpnksintrf0`, `ipv6leakintrf0`, `proton0`) |
| `nm_connections.txt` | all saved profiles (doubled names, the wired profile, the hotspot) |
| `nm_active_vpn_down.txt`, `nm_active_vpn_up.txt` | active connections without / with the tunnel |
| `nm_device_wifi.txt`, `nm_device_wired.txt` | `nmcli dev show` of the Wi-Fi device and the jack without carrier |
| `nm_active_wifi_profile.txt`, `nm_eduroam_profile.txt`, `nm_hotspot_profile.txt`, `nm_vpn_profile.txt` | `nmcli -s con show` of a Wi-Fi profile, the 802.1X one (no CA, no domain check), the AP profile, Proton's wireguard profile |
| `nm_general.txt`, `nm_permissions.txt` | NM state and polkit permissions |
| `nmcli_monitor_vpn_connect.txt` | the order of events while `protonvpn connect` ran |
| `proc_net_wireless.txt`, `rfkill.txt`, `bluez_adapter.txt` | /proc/net/wireless, rfkill, the BlueZ adapter (name scrubbed) |
| `proton_*.txt` | the CLI's outputs, byte for byte: `proton_connect.txt` ("Connected to NL#799 ..." with a trailing space), `proton_connect_securecore.txt`, `proton_disconnect.txt` (exit status 1!), `proton_status_{off,connected,securecore}.txt`, `proton_config.txt` (the table), `proton_set_killswitch.txt`, `proton_countries.txt`, `proton_cities_{NL,BE}.txt`, `proton_version.txt` |
| `scenario.json` | HAND-WRITTEN (all values fake): the world `tools/aerial/fake_nm.py` serves by default: five devices, eleven access points (a hidden one, one SSID on two bands, open / WPA2 / WPA3 / EAP, one that appears on a scan), 19 saved profiles (doubles, eduroam-like EAP, an AP profile, the wired profile) |
| `serverlist_subset.json` | Proton's `serverlist.json` schema, 16 logical servers of NL / BE / IS (Secure Core exits, P2P, Tor-less, one Tier-3 server the digest must drop); IPs and keys are placeholders (`tools/aerial/make_serverlist_subset.py`) |
