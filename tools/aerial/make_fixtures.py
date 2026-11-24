#!/usr/bin/env python3
"""Scrub the user's capture (READ ONLY) into modules/aerial/data/fixtures/.

  python3 -I tools/aerial/make_fixtures.py [<capture dir>]

What is replaced, consistently across every file (the same real value gets the same fake one):
  - every MAC / BSSID (also nmcli's `\\:` spelling)  -> 02:AE:00:00:00:NN (locally administered), case kept
  - every IPv4 (public IP, LAN, gateway, DNS, the tunnel's) -> RFC 5737 documentation ranges (loopback, 0.0.0.0, masks kept)
  - every IPv6 -> 2001:db8::N, link-local fe80::N (found as the leak check finds them, tools/publish/privacy_check.py
    v6_spans: an address right after a `:`, as in nmcli's `IP6.ADDRESS[1]:2a..`, once slipped through a plain pattern)
  - every real value of the private list -> its stand-in: `replace` of config/privacy.jsonc (never tracked; or the file
    $LARES_PRIVACY_FILE names): the saved networks' and the neighbours' SSIDs, the school login, the user and host names.
    Without the list the script refuses: it would copy the real names through.
  - every connection UUID -> a derived fake one
The Proton account line and the proton_info file are never copied. Run again after a new capture, then
`python3 -B tools/publish/privacy_check.py`: it must list nothing under modules/aerial/data/fixtures/.
"""
import sys, os, re, uuid, ipaddress

CAP = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.cache/lares/aerial-capture/20261119-222354")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "modules", "aerial", "data", "fixtures")

FILES = {
    "iw_link.txt": "iw_link.txt", "iw_station.txt": "iw_station.txt", "iw_reg.txt": "iw_reg.txt",
    "nm_wifi_list.txt": "nm_wifi_list.txt", "nm_devices.txt": "nm_devices.txt", "nm_connections.txt": "nm_connections.txt",
    "nm_device_wifi.txt": "nm_device_wifi.txt", "nm_device_wired.txt": "nm_device_wired.txt", "nm_general.txt": "nm_general.txt",
    "nm_permissions.txt": "nm_permissions.txt", "nm_active_wifi_profile.txt": "nm_active_wifi_profile.txt",
    "nm_eduroam_profile.txt": "nm_eduroam_profile.txt", "nm_hotspot_profile.txt": "nm_hotspot_profile.txt",
    "rfkill.txt": "rfkill.txt", "bluez_adapter.txt": "bluez_adapter.txt", "proc_net_wireless.txt": "proc_net_wireless.txt",
    "proton_status_off.txt": "proton_status_off.txt", "p1_connected.proton_status.txt": "proton_status_connected.txt",
    "p3_connected.proton_status.txt": "proton_status_securecore.txt", "proton_config.txt": "proton_config.txt",
    "proton_countries.txt": "proton_countries.txt", "proton_cities_NL.txt": "proton_cities_NL.txt",
    "proton_cities_BE.txt": "proton_cities_BE.txt", "p1_connect.txt": "proton_connect.txt",
    "p3_securecore.txt": "proton_connect_securecore.txt", "p2_disconnect.txt": "proton_disconnect.txt",
    "p4_ks_set.txt": "proton_set_killswitch.txt", "proton_version.txt": "proton_version.txt",
    "p1_connected.nm_active.txt": "nm_active_vpn_up.txt", "p0_before.nm_active.txt": "nm_active_vpn_down.txt",
    "p1_connected.nm_devices.txt": "nm_devices_vpn_up.txt", "p1_connect.nmcli_monitor.txt": "nmcli_monitor_vpn_connect.txt",
    "p1_connected.nm_vpn_profile.txt": "nm_vpn_profile.txt",
}
# Public stand-ins the private list need not hold (the phone's hotspot is named after its model, which the bridge's skin names).
PUBLIC_MAP = {"REDMAGIC 10S Pro": "Phone-Hotspot", "laptop-user": "laptop-hotspot"}
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "publish"))
import jsonc  # noqa: E402
from privacy_check import v6_spans  # noqa: E402


def private_map():
    """real -> stand-in, from the private list; exits when there is none (the scrub would copy the real names)."""
    path = os.environ.get("LARES_PRIVACY_FILE") or jsonc.resolve(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "config", "privacy.jsonc"))
    if not os.path.exists(path):
        sys.exit("make_fixtures: no private list (config/privacy.jsonc): the real names would be copied through; refusing")
    return dict(jsonc.load(path).get("replace") or {})


class Maps:
    def __init__(self):
        self.mac, self.v4, self.v6, self.uu = {}, {}, {}, {}

    def m(self, s):
        k = s.upper()
        if k not in self.mac:
            self.mac[k] = "02:AE:00:00:00:%02X" % (len(self.mac) + 1)
        r = self.mac[k]
        return r.lower() if s == s.lower() and s != s.upper() else r

    def ip4(self, s):
        if s.startswith(("127.", "0.", "255.")) or s in ("0.0.0.0",):
            return s
        if s not in self.v4:
            n = len(self.v4)
            net = ("192.0.2", "198.51.100", "203.0.113")[n % 3]
            self.v4[s] = "%s.%d" % (net, n // 3 + 2)
        return self.v4[s]

    def ip6(self, s):
        if s not in self.v6:
            n = len(self.v6) + 1
            low = ipaddress.ip_address(s).is_link_local
            self.v6[s] = ("fe80::%x" if low else "2001:db8::%x") % n
        return self.v6[s]

    def u(self, s):
        if s.lower() not in self.uu:
            self.uu[s.lower()] = str(uuid.uuid5(uuid.NAMESPACE_DNS, "aerial-fixture-" + s.lower()))
        return self.uu[s.lower()]


M = Maps()
MAC_RE = re.compile(r"(?<![0-9A-Fa-f])([0-9A-Fa-f]{2})((?:\\?:[0-9A-Fa-f]{2}){5})(?![0-9A-Fa-f])")
V4_RE = re.compile(r"(?<![\d.])(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?![\d.]*\d)")
UU_RE = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")


def scrub(text, names):
    for k in sorted(names, key=len, reverse=True):
        text = text.replace(k, names[k])
    for k in sorted(PUBLIC_MAP, key=len, reverse=True):
        text = text.replace(k, PUBLIC_MAP[k])

    def mac(m):
        raw = m.group(0)
        esc = "\\:" in raw
        plain = raw.replace("\\:", ":")
        r = M.m(plain)
        return r.replace(":", "\\:") if esc else r
    text = MAC_RE.sub(mac, text)
    text = UU_RE.sub(lambda m: M.u(m.group(0)), text)

    for a, b, addr in sorted(v6_spans(text), reverse=True):
        if not (addr.is_loopback or addr.is_unspecified or addr.is_multicast):
            text = text[:a] + M.ip6(str(addr)) + text[b:]

    def v4(m):
        s = m.group(1)
        try:
            ipaddress.IPv4Address(s)
        except ValueError:
            return s
        return M.ip4(s)
    return V4_RE.sub(v4, text)


def main():
    names = private_map()
    os.makedirs(OUT, exist_ok=True)
    for src, dst in FILES.items():
        p = os.path.join(CAP, src)
        if not os.path.exists(p):
            print("skip (missing):", src)
            continue
        with open(p, "r", encoding="utf-8", newline="") as f:
            t = f.read()
        with open(os.path.join(OUT, dst), "w", encoding="utf-8", newline="") as f:
            f.write(scrub(t, names))
        print("ok", dst)
    print("replaced: %d MACs, %d IPv4, %d IPv6, %d UUIDs" % (len(M.mac), len(M.v4), len(M.v6), len(M.uu)))


if __name__ == "__main__":
    main()
