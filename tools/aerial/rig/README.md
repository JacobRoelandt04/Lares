# The aerial test bed

A real NetworkManager the module can be tested against without touching the user's network
(`docs/agent_added_files_and_folders/aerial_progress/PLAN.md`, "The test bed"; the user's steps: `.../aerial_progress/R.md`). It needs root
to exist at all, so it is installed by ONE reviewed command and proven in a fixed order before any test uses it. Reviewed and checked
without root in stream R (2026-11-20); never yet run.

```
sudo ~/.config/quickshell/tools/aerial/rig/install.sh     # shows every change, asks "yes"
systemctl start lares-aerial-rig                          # no password (polkit rule for that one unit); returns when the rig is READY
systemctl stop lares-aerial-rig                           # everything goes: netns, radios, run dir
sudo ~/.config/quickshell/tools/aerial/rig/uninstall.sh   # the files go (packages stay)
```
`lares setup` shows the row "aerial test bed" (never a TO DO). An agent runs `tools/dev/aerial_rig_probe.sh` (safety first, then the module).

## What runs where
```
 initial netns (the user's machine)          netns lares-rig + its own mount and UTS namespaces
 ----------------------------------          ---------------------------------------------------------------
 the user's NetworkManager                   hostapd  ap0  (radio A, 2.4 GHz): "rig-open" open, "rig-wpa2" WPA2-PSK,
   ignores driver:mac80211_hwsim                          a hidden BSS "rig-hidden" (WPA2-PSK)
   (conf.d line, below)                      hostapd  ap1  (radio B, 5 GHz ch36 if the domain allows it, else 2.4 ch11):
                                                          "rig-wpa3" SAE, "rig-eap" 802.1X (PEAP/TTLS, hostapd's EAP server),
                                                          "rig-wpa2" again (one name on two radios = roaming / dual band)
 quickshell under test (as the user)         dnsmasq  DHCP + DNS for every AP subnet; the check host resolves to the portal
   DBUS_SYSTEM_BUS_ADDRESS=                  portal.py  answers the check URL: "NetworkManager is online" or a 302 to a
     unix:path=/run/lares-rig/bus                       login page, switched by /run/lares-rig/portal (a file the user owns)
 nmcli (as the user), same variable          dbus-daemon  a private bus, socket /run/lares-rig/bus (owned by the user)
                                             wpa_supplicant -u  on that bus (NetworkManager's Wi-Fi backend)
                                             NetworkManager  on that bus, auth-polkit=false, keyfiles in /run, dns=none,
                                                          manages radio C (the client) and nothing else
                                             wpa_supplicant  on radio D as a "phone" that joins the hotspot under test
```
Four `mac80211_hwsim` radios, made by `modprobe mac80211_hwsim radios=4` and moved into the netns at once; named by ROLE in phy order
(`/run/lares-rig/roles`: ap_a, ap_b, client, phone). A veth `lrig-h` (host, 10.77.255.2/30) / `lrig-n` (netns) and a host route
10.77.0.0/24 give the user's processes (the module's helper pings the gateway and fetches the check URL from the user's netns) a way to the
rig's gateway 10.77.0.1 and portal (`http://10.77.0.1:8080/nm-check.txt`; the helper is given it by address, `--check-url`). What only the
netns can see (`/proc/net/wireless`, `/proc/net/dev`, `iw ... station dump | link`, `iw reg get`) is copied to `/run/lares-rig/pub/` every
0.5 s for the user's processes (stub `iw`: `tools/dev/stubs/aerial_rig/iw`).

## Safety laws (each proven by `tools/dev/aerial_rig_probe.sh` before anything else; a FAIL stops the run)
1. **`/dev/rfkill` is global.** NetworkManager writes rfkill when its Wi-Fi switch turns. The rig's mount namespace bind-mounts `/dev/null`
   over `/dev/rfkill` (the rig checks the mask before it says ready). The probe flips the RIG's switch on the rig's bus and compares the
   real radios' soft / hard state (virtual radios excluded by their sysfs path) before and after.
2. **`/etc/resolv.conf` is the user's.** `dns=none`, `rc-manager=unmanaged` AND a private file bind-mounted over it (checked by inode before
   ready); the probe hashes the real file and its link.
3. **The user's NetworkManager never manages a virtual radio or the veth.** `/etc/NetworkManager/conf.d/90-lares-aerial-rig.conf` (a
   `[device-...]` section: `match-device=driver:mac80211_hwsim,interface-name:lrig-h`, `managed=0`) is loaded with `nmcli general reload
   conf`; the probe compares the user's `nmcli` general / connections / devices before, during and after.
4. **The rig's state lives in `/run/lares-rig/`** (tmpfs): private bind mounts over `/run/NetworkManager`, `/var/lib/NetworkManager` and
   `/run/udev`, its own `--config / --config-dir / --system-config-dir / --intern-config / --state-file / --pid-file`; its own UTS
   namespace (a hostname set by DHCP stays inside); no service activation on its bus (the user's dispatcher scripts and polkit never run).
5. **Root runs only root-owned copies** (`/usr/local/lib/lares/aerial-rig/`, root:root; never the repo). The portal runs as the USER (it
   writes the switch file the user owns); the hostapd / wpa control dirs are root-owned and group-readable, nothing the user may create.
6. **The unit is never enabled**: started on demand, stopped after a run. `ExecStopPost` (cleanup) also runs after a FAILED start; `prepare`
   undoes itself on any failure; `mac80211_hwsim` is unloaded only if this run loaded it (a foreign one: the rig refuses); the regulatory
   domain goes back. `rig inner` refuses to run outside the netns.
7. **The rig's addresses are free**: `prepare` refuses when the host already has 10.77.x.x (the veth brings a route into the user's table).

## Proven without root (stream R, `tools/dev/aerial_rig_install_probe.sh`, ARMs realpath, nouser)
- `install.sh` / `uninstall.sh` run as written on a FAKE ROOT (every path moved in, `id` = 0, stub pacman / systemctl / nmcli that log): the
  files, their bytes and modes, the calls (exactly pacman -S, daemon-reload, `nmcli general reload conf`), idempotence, refusals write
  nothing, the user's own files untouched, the uninstall restores the tree; a line naming a real path is refused before it runs.
- The polkit rule evaluated in node: the user may start / stop / restart THIS unit; nobody else, nothing else.
- dnsmasq `--test`; the private bus config parsed by a real dbus-daemon; the rig's NetworkManager config and the user's line parsed by the
  real NetworkManager (`--print-config`: dns=none, rc-manager=unmanaged, auth-polkit=false, keyfile path, unmanaged-devices, connectivity
  off); the unit through `systemd-analyze verify`; hostapd's keys against the upstream list (hostapd is not installed here); every
  placeholder filled; the role mapping on a scrambled `iw dev`; the mount order (masks before NetworkManager); the guards in the text.
- The probe's dry parts (`aerial_rig_probe.sh --selftest`): refusal without the rig, the safety snapshot read-only and stable.

## Only the first real run proves
- hostapd's behaviour in Arch's build: multi-BSS on hwsim, 5 GHz ch36 under BE (needs `wireless-regdb`; else AP B falls back to 2.4 GHz ch11),
  SAE, hostapd's EAP server with PEAP / TTLS (OpenSSL 3 and MD4 for MSCHAPv2; else the 802.1X scenarios fail and the AP is dropped).
- NetworkManager inside a netns managing a hwsim radio: the rig writes `I:1` udev records for the netns' links into a private `/run/udev`;
  if NM still calls the radio "not initialized", the fallback is `[device] match-device=driver:mac80211_hwsim managed=1` in the rig's nm.conf.
- `iw phy set netns name`, `ip link add ... peer netns`, the host route, the bind masks under `ip netns exec` + `unshare`, Type=notify.
- Roaming by `hostapd_cli disable`, the hotspot's AP mode on a hwsim radio, the phone's join, dBm (`/proc/net/wireless` may be empty
  without wext).
- Timings: a cold start (`TimeoutStartSec=90`), every scenario's `ms` in `tools/dev/qml/aerial_rig_probe.qml`.

## Files
| File | Installed to | What |
|---|---|---|
| `install.sh` | -- | the user's one root step (prints every change, asks `yes`): packages, the copies, the unit, the polkit rule, the conf.d line |
| `uninstall.sh` | -- | takes all of it back out (packages stay) |
| `rig` | `/usr/local/lib/lares/aerial-rig/rig` | `prepare` / `run` / `inner` / `cleanup` / `status`, what the unit runs |
| `conf/*` | same dir, `conf/` | hostapd, dnsmasq, NetworkManager, the private bus, EAP users |
| `portal.py` | same dir | the check URL and its login page |
| `lares-aerial-rig.service` | `/etc/systemd/system/` | Type=notify, never enabled |
