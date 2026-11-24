#!/usr/bin/env node
// AerialModel.js (modules/aerial/data) under node: every pure function, table-tested. Last line: AERIAL-MODEL RESULT PASS|FAIL.
//   AERIAL_MOD=<dir>   a sandbox copy with a fault put back (the probe's ARMs)
//   node tools/dev/aerial_model_cases.js --arm   proves the harness can fail (a wrong expectation is a FAIL)
process.env.TZ = "Europe/Brussels";
const fs = require("fs"), path = require("path"), vm = require("vm");
const ROOT = path.join(__dirname, "..", "..");
const MOD = process.env.AERIAL_MOD || path.join(ROOT, "modules");
const src = fs.readFileSync(path.join(MOD, "aerial/data/AerialModel.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const ctx = vm.createContext({});
vm.runInContext(src + "\n;this.M = { " + [...src.matchAll(/^function ([A-Za-z0-9_]+)/gm)].map(m => m[1]).concat(["MEMBERS", "BAND_MIN", "HYST", "DEFAULT_CONFIG"]).join(", ") + " };", ctx);
const M = ctx.M;
// the OSD's reading of the same facts (netModelOf / diffNet): a switch of tunnel must be told with the NEW server
const osdSrc = fs.readFileSync(path.join(MOD, "osd/data/OsdKinds.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const octx = vm.createContext({});
vm.runInContext(osdSrc + "\n;this.K = { netModelOf: netModelOf, diffNet: diffNet };", octx);
const K = octx.K;
let fails = 0, n = 0;
function eq(name, got, want) {
    n++;
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) return;
    fails++;
    console.log("AM " + name + " FAIL  got " + g + "  want " + w);
}
function ok(name, cond, detail) { n++; if (!cond) { fails++; console.log("AM " + name + " FAIL  " + (detail || "")); } }
if (process.argv.includes("--arm")) eq("arm", 1, 2);

// ---- members
ok("members.props", M.MEMBERS.props.length === 17 && M.MEMBERS.props.includes("errors"));
ok("members.intents", M.MEMBERS.intents.length === 45, "n=" + M.MEMBERS.intents.length);
eq("members.missing", M.missingMembers({ live: 1 }).length, M.MEMBERS.props.length + 4 + 45 - 1);

// ---- band / channel / security
eq("band", [2412, 2484, 5180, 5825, 5955, 7115, 100].map(M.bandOf), ["2.4", "2.4", "5", "5", "6", "6", ""]);
eq("channel", [2412, 2437, 2484, 5180, 5745, 5955, 5935, 6415].map(M.channelOf), [1, 6, 14, 36, 149, 1, 2, 93]);
eq("sec.open", M.securityOf(0, 0, 0), "open");
eq("sec.wep", M.securityOf(1, 0, 0), "wep");
eq("sec.wpa2", M.securityOf(1, 0, 0x100 | 0x8), "wpa2");
eq("sec.wpa2.wpaonly", M.securityOf(1, 0x100, 0), "wpa2");
eq("sec.wpa3", M.securityOf(1, 0, 0x400), "wpa3");
eq("sec.wpa23", M.securityOf(1, 0, 0x400 | 0x100), "wpa2/3");
eq("sec.eap", M.securityOf(1, 0, 0x200), "eap");
eq("sec.owe", M.securityOf(0, 0, 0x800), "owe");
eq("sec.suiteb", M.securityOf(1, 0, 0x2000), "eap");
eq("profsec", ["wpa-psk", "sae", "wpa-eap", "none", "", "owe"].map(M.profileSecurity), ["wpa2", "wpa3", "eap", "open", "open", "owe"]);
eq("standard", [["he", "5"], ["he", "6"], ["vht", "5"], ["ht", "2.4"], ["", "5"], ["x", "5"]].map(a => M.standardOf(a[0], a[1])), ["Wi-Fi 6", "Wi-Fi 6E", "Wi-Fi 5", "Wi-Fi 4", "", ""]);

// ---- signal bands: first sight is plain, then hysteresis
eq("band.first", [100, 70, 69, 50, 49, 30, 29, 0].map(s => M.signalBandOf(s, undefined)), [0, 0, 1, 1, 2, 2, 3, 3]);
eq("band.hyst.hold", M.signalBandOf(66, 0), 0);          // 4 under the edge: stays
eq("band.hyst.leave", M.signalBandOf(63, 0), 1);         // 7 under: leaves
eq("band.hyst.enter", M.signalBandOf(74, 1), 1);         // 4 over: stays
eq("band.hyst.enter2", M.signalBandOf(77, 1), 0);
eq("band.jump", M.signalBandOf(5, 0), 3);                // a big drop goes all the way
// noise around an edge never flaps; the same noise with no memory does
(function () {
    let b = M.signalBandOf(72, undefined), changes = 0, plain = 0, pp = M.signalBandOf(72, undefined);
    let seed = 7;
    for (let i = 0; i < 400; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        const s = 70 + ((seed >> 8) % 9) - 4;                // 66..74
        const nb = M.signalBandOf(s, b); if (nb !== b) changes++; b = nb;
        const np = M.signalBandOf(s, undefined); if (np !== pp) plain++; pp = np;
    }
    ok("band.noflap", changes === 0, "changes=" + changes);
    ok("band.noise.is.noisy", plain > 40, "plain=" + plain);
})();

// ---- Wi-Fi fold
const AP = (path, bssid, ssid, freq, strength, o) => Object.assign({ path, bssid, ssid, ssidHex: "", freq, width: 80, strength, maxBitrate: 866000, flags: 1, wpaFlags: 0, rsnFlags: 0x108, lastSeen: 100 }, o || {});
const snap = {
    device: { iface: "wlp47s0", hwAddress: "AA:00:00:00:00:01", permHwAddress: "AA:00:00:00:00:01", driver: "iwlwifi" },
    aps: [AP("/ap/1", "aa:aa:aa:aa:aa:01", "Home", 5180, 80), AP("/ap/2", "aa:aa:aa:aa:aa:02", "Home", 2437, 55), AP("/ap/3", "bb:bb:bb:bb:bb:01", "Cafe", 2412, 40, { flags: 0, rsnFlags: 0 }),
          AP("/ap/4", "cc:cc:cc:cc:cc:01", "", 5200, 33), AP("/ap/5", "dd:dd:dd:dd:dd:01", "Uni", 5500, 60, { rsnFlags: 0x200 })],
    activeAp: "/ap/1", scanning: false, lastScan: 5000
};
const profs = [
    { uuid: "u-home", id: "Home", type: "802-11-wireless", ssid: "Home", mode: "infrastructure", security: "wpa-psk", autoconnect: true, autoconnectPriority: 5, timestamp: 1700000000 },
    { uuid: "u-home1", id: "Home 1", type: "802-11-wireless", ssid: "Home", mode: "infrastructure", security: "wpa-psk", autoconnect: true, timestamp: 1600000000 },
    { uuid: "u-uni", id: "Uni", type: "802-11-wireless", ssid: "Uni", mode: "infrastructure", security: "wpa-eap" },
    { uuid: "u-hs", id: "Hotspot", type: "802-11-wireless", ssid: "laptop", mode: "ap", security: "wpa-psk" },
    { uuid: "u-eth", id: "Wired", type: "802-3-ethernet", ssid: "" }
];
const devices = [
    { iface: "wlp47s0", type: "wifi", driver: "iwlwifi", state: 100, hwAddress: "AA:00:00:00:00:01", ip4: { address: "192.168.1.20/24", gateway: "192.168.1.1", dns: ["1.1.1.1"] }, ip6: ["fe80::1/64"] },
    { iface: "enp46s0", type: "ethernet", driver: "r8169", state: 20, carrier: false, hwAddress: "AA:00:00:00:00:09" },
    { iface: "docker0", type: "ethernet", state: 100, carrier: true },
    { iface: "proton0", type: "wireguard", state: 100 },
    { iface: "pvpnksintrf0", type: "dummy", state: 100 }
];
const active = [{ uuid: "u-home", id: "Home", type: "802-11-wireless", devices: ["wlp47s0"], state: 2, vpn: false, default4: true }];
const base = { wifiSnap: snap, devices, active, profiles: profs, nm: { running: true, wirelessEnabled: true, wirelessHardwareEnabled: true }, link: { standard: "he", rxMbps: 1201, txMbps: 960, dbm: -50 },
               dbm: -52, trust: { "u-home": true }, prevBands: {}, overrides: {}, activeSince: { "u-home": 123 }, bootMs: 1e12 - 5e5, nowMs: 1.7e12, dnsmasq: true, clients: [], proton: { installed: true, signedIn: "yes" }, catalog: null };
const f = M.compose(base);
const w = f.wifi;
eq("wifi.keys", w.networks.map(x => x.key), ["Cafe", "Home", "Uni", "hidden:CC:CC:CC:CC:CC:01"]);
const home = w.networks.find(x => x.key === "Home");
eq("net.home.bands", home.bands, ["2.4", "5"]);
eq("net.home.best", [home.bestBand, home.signal, home.signalBand], ["5", 80, 0]);
eq("net.home.known", [home.known, home.profileUuids, home.connected, home.state], [true, ["u-home", "u-home1"], true, "connected"]);
eq("net.home.trust.all", home.trusted, false);         // one of its two profiles is not marked: Public
eq("net.home.aps", home.aps.map(a => [a.bssid, a.channel, a.band, a.active, a.maxRateMbps]), [["AA:AA:AA:AA:AA:01", 36, "5", true, 866], ["AA:AA:AA:AA:AA:02", 6, "2.4", false, 866]]);
const cafe = w.networks.find(x => x.key === "Cafe");
eq("net.cafe", [cafe.security, cafe.known, cafe.trusted, cafe.state, cafe.signalBand], ["open", false, false, "idle", 2]);
eq("net.uni.eap", w.networks.find(x => x.key === "Uni").security, "eap");
const hid = w.networks.find(x => x.hidden);
eq("net.hidden", [hid.ssid, hid.known, hid.security, hid.aps.length], ["", false, "wpa2", 1]);
eq("net.hotspot.mark", w.networks.some(x => x.ownHotspot), false);
eq("active", [w.active.key, w.active.band, w.active.channel, w.active.standard, w.active.dbm, w.active.rateMbps, w.active.ip4, w.active.prefix4, w.active.gateway4, w.active.dns, w.active.ip6, w.active.sinceMs, w.active.bssid],
   ["Home", "5", 36, "Wi-Fi 6", -52, 1201, "192.168.1.20", 24, "192.168.1.1", ["1.1.1.1"], ["fe80::1"], 123, "AA:AA:AA:AA:AA:01"]);
eq("wifi.flags", [w.present, w.iface, w.radioOn, w.softBlocked, w.hardBlocked, w.driver, w.lastScanMs], [true, "wlp47s0", true, false, false, "iwlwifi", base.bootMs + 5000]);
eq("ap.lastSeen", home.aps[0].lastSeenMs, base.bootMs + 100000);
eq("profiles.doubles", w.profiles.filter(p => p.ssid === "Home").map(p => [p.uuid, p.doubles]), [["u-home", ["u-home1"]], ["u-home1", ["u-home"]]]);
eq("profiles.type", w.profiles.map(p => p.uuid), ["u-home", "u-home1", "u-uni", "u-hs"]);   // the wired profile is not a Wi-Fi one
eq("profiles.misc", [w.profiles[0].priority, w.profiles[0].lastUsedMs, w.profiles[0].inRange, w.profiles[0].trusted, w.profiles[0].security, w.profiles[2].security, w.profiles[3].inRange], [5, 1700000000000, true, true, "wpa2", "eap", false]);
// a wifi doubles pair is by SSID *and* type: a same-SSID AP-mode profile is not a double
eq("doubles.type", M.foldProfiles([{ uuid: "a", type: "802-11-wireless", ssid: "X", mode: "infrastructure" }, { uuid: "b", type: "802-11-wireless", ssid: "X", mode: "ap" }], {}, {}).map(p => p.doubles), [[], []]);
// override states
const f2 = M.compose(Object.assign({}, base, { active: [], overrides: { Cafe: { state: "needsSecret" }, Uni: { state: "failed", failReason: "no-secrets" } } }));
eq("override", f2.wifi.networks.filter(x => x.state !== "idle").map(x => [x.key, x.state, x.failReason]), [["Uni", "failed", "no-secrets"], ["Cafe", "needsSecret", ""]].sort((a, b) => a[0] < b[0] ? -1 : 1));
eq("noactive", f2.wifi.active, null);
// hotspot profile active: it is the hotspot, not wifi.active
const f3 = M.compose(Object.assign({}, base, { active: [{ uuid: "u-hs", id: "Hotspot", type: "802-11-wireless", devices: ["wlp47s0"], state: 2 }], clients: [{ mac: "x", ip: "10.42.0.2", name: "phone", dbm: -40 }] }));
eq("hotspot.active", [f3.wifi.active, f3.hotspot.active, f3.hotspot.state, f3.hotspot.ssid, f3.hotspot.clients.length, f3.hotspot.available, f3.wifi.networks.find(x => x.key === "Home").connected], [null, true, "active", "laptop", 1, true, false]);
eq("hotspot.ownmark", M.compose(Object.assign({}, base, { wifiSnap: Object.assign({}, snap, { aps: snap.aps.concat([AP("/ap/9", "ee:ee:ee:ee:ee:01", "laptop", 2412, 90)]) }) })).wifi.networks.find(x => x.key === "laptop").ownHotspot, true);
eq("hotspot.missing", [M.compose(Object.assign({}, base, { dnsmasq: false })).hotspot.missing, M.compose(Object.assign({}, base, { wifiSnap: { device: null, aps: [] }, devices: [] })).hotspot.missing], ["dnsmasq", "device"]);
eq("hotspot.uplink", M.compose(Object.assign({}, base, { devices: devices.map(d => d.iface === "enp46s0" ? Object.assign({}, d, { state: 100, carrier: true }) : d), active: active.concat([{ uuid: "u-eth", id: "Wired", type: "802-3-ethernet", devices: ["enp46s0"], state: 2 }]) })).hotspot.uplink, "cable");
// radio blocks
const f4 = M.compose(Object.assign({}, base, { nm: { wirelessEnabled: false, wirelessHardwareEnabled: false } }));
eq("radio", [f4.wifi.radioOn, f4.wifi.softBlocked, f4.wifi.hardBlocked], [false, true, true]);
// no device
eq("nowifi", [M.compose(Object.assign({}, base, { wifiSnap: null, devices: [] })).wifi.present], [false]);
// hysteresis through compose: a net at 66 keeps band 0 when it had it
eq("compose.hyst", [M.compose(Object.assign({}, base, { wifiSnap: Object.assign({}, snap, { aps: [AP("/ap/1", "aa:aa:aa:aa:aa:01", "Home", 5180, 66)] }), prevBands: { Home: 0 } })).wifi.networks[0].signalBand,
                    M.compose(Object.assign({}, base, { wifiSnap: Object.assign({}, snap, { aps: [AP("/ap/1", "aa:aa:aa:aa:aa:01", "Home", 5180, 66)] }), prevBands: {} })).wifi.networks[0].signalBand], [0, 1]);
eq("bands.out", f.bands.Home, 0);

// ---- wired
eq("wired.jacks", f.wired.jacks.map(j => [j.iface, j.kind, j.carrier, j.state, j.connected]), [["enp46s0", "rj45", false, "unavailable", false]]);
eq("wired.usb", M.buildWired({ devices: [{ iface: "enx1", type: "ethernet", driver: "cdc_ncm", state: 100, carrier: true }], active: [] }).jacks[0].kind, "usb");
eq("virtual", ["docker0", "br-1", "veth12", "lo", "proton0", "pvpn1", "wlp1", "enp1", "virbr0", "p2p-dev-wlp1"].map(M.isVirtualIface), [true, true, true, true, true, true, false, false, true, true]);

// ---- Proton: dummies are never the network or the primary; up = a wireguard "ProtonVPN *" on proton0
const dummy = { uuid: "u-ks", id: "pvpn-killswitch", type: "dummy", devices: ["pvpnksintrf0"], state: 2, default4: true };
const leak = { uuid: "u-ks6", id: "pvpn-killswitch-ipv6", type: "dummy", devices: ["ipv6leakintrf0"], state: 2 };
const tun = { uuid: "u-p", id: "ProtonVPN NL#799", type: "wireguard", devices: ["proton0"], state: 2, vpn: true };
eq("isKillswitch", [M.isKillswitch(dummy), M.isKillswitch(leak), M.isKillswitch(tun), M.isKillswitch(active[0])], [true, true, false, false]);
eq("isProtonConn", [M.isProtonConn(tun), M.isProtonConn(dummy), M.isProtonConn(Object.assign({}, tun, { id: "Work" })), M.isProtonConn(Object.assign({}, tun, { devices: ["wg0"] }))], [true, false, false, false]);
const catalog = M.catalogFact({ tier: 2, countries: [{ code: "NL", name: "Netherlands", lat: 52, lon: 5, servers: 2, minLoad: 40, features: 12, cities: [{ name: "Amsterdam", lat: 52.3, lon: 4.9, servers: [{ name: "NL#799", load: 48, features: 4, status: 1 }] }] }] }, 3);
eq("catalog", [catalog.serial, catalog.tier, catalog.countries[0].features, catalog.countries[0].cities[0].servers[0].features], [3, 2, ["p2p", "streaming"], ["p2p"]]);
const withTun = M.compose(Object.assign({}, base, { active: active.concat([tun, dummy, leak]), catalog, activeSince: { "u-p": 777 }, proton: { installed: true, signedIn: "yes", status: { server: { name: "NL#799", city: "Amsterdam", country: "Netherlands" }, protocol: "wireguard", load: 48 }, config: { "Kill Switch": "off", NetShield: "Malware only", IPv6: "on", "Custom DNS": "off" } } }));
eq("proton.up", [withTun.proton.state, withTun.proton.server.name, withTun.proton.server.country, withTun.proton.server.city, withTun.proton.server.load, withTun.proton.sinceMs, withTun.proton.killSwitch, withTun.proton.netshield, withTun.proton.ipv6],
   ["up", "NL#799", "NL", "Amsterdam", 48, 777, "off", "malware-only", true]);
eq("proton.wifi.unchanged", [withTun.wifi.active.key, withTun.rateIface], ["Home", "wlp47s0"]);
// the dummy alone (the first 0.8 s of a connect): the network does not vanish; Proton is down
const dummyOnly = M.compose(Object.assign({}, base, { active: active.concat([dummy]) }));
eq("proton.dummyonly", [dummyOnly.proton.state, dummyOnly.wifi.active.key, dummyOnly.rateIface], ["down", "Home", "wlp47s0"]);
// the dummy as the ONLY default (primary) connection: still no network from it
eq("carrying.dummyfirst", M.carryingIface([dummy, Object.assign({}, active[0], { default4: false })], devices), "wlp47s0");
eq("carrying.vpn.skipped", M.carryingIface([Object.assign({}, tun, { default4: true }), active[0]], devices), "wlp47s0");
eq("carrying.none", M.carryingIface([dummy], devices), "");
eq("carrying.wired", M.carryingIface([{ uuid: "e", id: "W", type: "802-3-ethernet", devices: ["enp46s0"], state: 2, default4: true }, Object.assign({}, active[0], { default4: false })], devices), "enp46s0");
eq("proton.connecting", M.compose(Object.assign({}, base, { active: active.concat([Object.assign({}, tun, { state: 1 })]) })).proton.state, "connecting");
eq("proton.failed", M.compose(Object.assign({}, base, { proton: { installed: true, signedIn: "yes", failed: true } })).proton.state, "failed");
eq("proton.signedin", [M.compose(Object.assign({}, base, { proton: { installed: true } })).proton.signedIn, M.compose(Object.assign({}, base, { proton: { installed: true, signedIn: "no" } })).proton.signedIn], ["unknown", "no"]);
eq("proton.locked", [M.compose(Object.assign({}, base, { proton: { installed: true } })).proton.locked, M.compose(Object.assign({}, base, { proton: { installed: true, locked: true } })).proton.locked], [false, true]);
// a SWITCH NL -> US: NetworkManager activates "ProtonVPN US#12" BEFORE the CLI exits, so for a while the CLI's last words still name NL#799.
// The active connection's id is the truth for which server; the stale words (city, load, protocol) count only for the same server.
const usTun = { uuid: "u-p2", id: "ProtonVPN US#12", type: "wireguard", devices: ["proton0"], state: 2, vpn: true };
const staleSt = { server: { name: "NL#799", city: "Amsterdam", country: "Netherlands" }, protocol: "wireguard", load: 48 };
const stale = M.compose(Object.assign({}, base, { active: active.concat([usTun]), catalog, proton: { installed: true, signedIn: "yes", status: staleSt } }));
eq("proton.switch.stale", [stale.proton.state, stale.proton.server.name, stale.proton.server.country, stale.proton.server.city, stale.proton.server.load], ["up", "US#12", "US", "", 0]);
const staleCat = M.compose(Object.assign({}, base, { active: active.concat([tun]), catalog, proton: { installed: true, signedIn: "yes", status: { server: { name: "US#12" }, load: 9 } } }));
eq("proton.switch.stale.catalog", [staleCat.proton.server.name, staleCat.proton.server.city, staleCat.proton.server.load], ["NL#799", "Amsterdam", 48]);
const fresh = M.compose(Object.assign({}, base, { active: active.concat([usTun]), proton: { installed: true, signedIn: "yes", status: { server: { name: "US#12", city: "Chicago", country: "United States" }, load: 31 } } }));
eq("proton.switch.fresh", [fresh.proton.server.name, fresh.proton.server.city, fresh.proton.server.country, fresh.proton.server.load], ["US#12", "Chicago", "United States", 31]);
eq("proton.countryOfName", ["NL#799", "IS-NL#1", "CH-BE#2", "NL-FREE#133", "weird"].map(M.countryOfName), ["NL", "NL", "BE", "NL", ""]);
eq("proton.securecore.country", M.compose(Object.assign({}, base, { active: active.concat([Object.assign({}, usTun, { id: "ProtonVPN IS-NL#1" })]) })).proton.server.country, "NL");
// the OSD: the card of a switch names the NEW server (through the stale-words moment, and as a direct swap)
const nlUp = M.compose(Object.assign({}, base, { active: active.concat([tun]), proton: { installed: true, signedIn: "yes", status: staleSt } }));
const vpnEv = (a, b) => K.diffNet(K.netModelOf(a), K.netModelOf(b)).filter(e => e.kind === "vpn").map(e => e.vpn.name + ":" + e.vpn.state);
eq("osd.switch.direct", vpnEv(nlUp, stale), ["US#12:up"]);
const nlGone = M.compose(Object.assign({}, base, { active: active.concat([]), proton: { installed: true, signedIn: "yes", status: staleSt } }));
eq("osd.switch.viadown", vpnEv(nlUp, nlGone).concat(vpnEv(nlGone, stale)), ["NL#799:down", "US#12:up"]);
eq("osd.same.server.silent", vpnEv(nlUp, nlUp), []);
// the globe's toggle: `fastest` is true while the tunnel was asked for with Proton's own pick, then while its name is the one that pick landed on
const fastWith = (extra, act) => M.compose(Object.assign({}, base, { active: active.concat(act === undefined ? [tun] : act), proton: Object.assign({ installed: true, signedIn: "yes", status: {} }, extra) })).proton.fastest;
eq("proton.fastest", [fastWith({}), fastWith({ fastestAsk: true }), fastWith({ fastestServer: "NL#799" }), fastWith({ fastestServer: "NL#1" }), fastWith({ fastestAsk: true }, []), fastWith({ fastestServer: "NL#799" }, [])], [false, true, true, false, false, false]);


eq("proton.config", [M.protonConfig({ "Kill Switch": "Standard", NetShield: "Malware, ads and trackers", IPv6: "off", "Custom DNS": "9.9.9.9" }), M.protonConfig(null)],
   [{ killSwitch: "standard", netshield: "malware-ads-trackers", ipv6: false, customDns: "9.9.9.9" }, { killSwitch: "off", netshield: "off", ipv6: false, customDns: "" }]);
// the helper's activeAp is a BSSID
eq("activeAp.bssid", M.compose(Object.assign({}, base, { wifiSnap: Object.assign({}, snap, { activeAp: "AA:AA:AA:AA:AA:02" }) })).wifi.active.bssid, "AA:AA:AA:AA:AA:02");
eq("wifi.lastScanMs.epoch", M.compose(Object.assign({}, base, { wifiSnap: Object.assign({}, snap, { lastScanMs: 1.7e12 - 10 }) })).wifi.lastScanMs, 1.7e12 - 10);

// ---- auto-tunnel
const on = { enabled: true, installed: true, signedIn: "yes", hasNetwork: true, trusted: false, netPad: "ok", portal: false, protonState: "down", suppressed: false };
eq("auto.raise", M.autoTunnelDecision(on), "raise");
eq("auto.portal", M.autoTunnelDecision(Object.assign({}, on, { portal: true })), "wait-portal");
eq("auto.portal.pad", M.autoTunnelDecision(Object.assign({}, on, { netPad: "warn" })), "wait-portal");
eq("auto.portal.beats.ok", M.autoTunnelDecision(Object.assign({}, on, { portal: true, netPad: "ok" })), "wait-portal");
eq("auto.link", [M.autoTunnelDecision(Object.assign({}, on, { netPad: "unknown" })), M.autoTunnelDecision(Object.assign({}, on, { netPad: "testing" })), M.autoTunnelDecision(Object.assign({}, on, { netPad: "fail" }))], ["wait-link", "wait-link", "wait-link"]);
eq("auto.none", [{ enabled: false }, { installed: false }, { signedIn: "no" }, { signedIn: "unknown" }, { hasNetwork: false }, { trusted: true }, { suppressed: true }, { protonState: "up" }, { protonState: "connecting" }].map(o => M.autoTunnelDecision(Object.assign({}, on, o))), Array(9).fill("none"));
eq("auto.waiting", ["raise", "wait-portal", "wait-link", "none"].map(M.waitingOf), ["", "portal", "link", ""]);

// ---- speed gate
eq("gate", [M.speedGate({ trusted: false }, false), M.speedGate({ trusted: true, metered: true }, false), M.speedGate({ trusted: true }, false), M.speedGate({ trusted: false }, true), M.speedGate(null, false)], ["public", "metered", "", "", ""]);

// ---- trust
const seed = M.trustSeed(profs);
eq("trust.seed", Object.keys(seed).sort(), ["u-eth", "u-home", "u-home1", "u-hs", "u-uni"]);
eq("trust.new.public", M.trustedOf(seed, "u-new"), false);
eq("trust.set", [M.trustSet(seed, ["u-new"], true)["u-new"], M.trustSet(seed, ["u-home"], false)["u-home"], M.trustFromJson(M.trustToJson(seed))["u-uni"]], [true, undefined, true]);
eq("trust.badjson", [M.trustFromJson("{"), M.trustFromJson(""), M.trustFromJson("[]")], [null, null, null]);

// ---- pads
eq("pads.free", f.health.pads.map(p => [p.id, p.state]), [["link", "ok"], ["addr", "ok"], ["gateway", "unknown"], ["dns", "unknown"], ["net", "unknown"]]);
const fp = M.compose(Object.assign({}, base, { pads: { net: { state: "warn", detail: "login page", ms: 120 } }, portal: { present: true, url: "http://x/login" } }));
eq("pads.net", [fp.health.pads[4].state, fp.health.pads[4].detail, fp.health.portal.present], ["warn", "login page", true]);
eq("pads.down", M.compose(Object.assign({}, base, { active: [] })).health.pads.map(p => p.state), ["fail", "unknown", "unknown", "unknown", "unknown"]);

// ---- Bluetooth
eq("kind", [["audio-headset", "Earbuds"], ["audio-headphones", "WH-1000"], ["audio-card", "JBL"], ["phone", "Pixel"], ["computer", "Laptop"], ["input-mouse", "MX"], ["input-keyboard", "K"], ["input-gaming", "Pad"], ["", "Foo"]].map(a => M.kindOf(a[0], a[1])),
   ["earbuds", "headset", "speaker", "phone", "computer", "mouse", "keyboard", "gamepad", "generic"]);
const dev = (a, o) => Object.assign({ address: a, name: "D" + a, icon: "phone", connected: false, paired: false, bonded: false, trusted: false, blocked: false, pairing: false, battery: 0, batteryAvailable: false }, o || {});
const btIn = { btAdapter: { enabled: true, state: "Enabled", discovering: true, discoverable: false, name: "lap" }, nowMs: 1000, btSeen: { "03": true },
               btDevices: [dev("01", { connected: true, paired: true, icon: "audio-headset", name: "Earbuds", batteryAvailable: true, battery: 60 }), dev("02", { paired: true }), dev("03"), dev("04")],
               btParts: { "01": { left: { pct: 40, charging: false }, right: { pct: 55, charging: true }, case: { pct: 90, charging: false } } } };
const bt = M.buildBt(btIn);
eq("bt.rings", bt.devices.map(d => [d.address, d.ring]), [["01", "inner"], ["02", "middle"], ["03", "outer"]]);
eq("bt.battery", [bt.devices[0].battery, bt.devices[0].parts, bt.devices[0].kind], [40, { left: 40, right: 55, case: 90, charging: true }, "earbuds"]);
eq("bt.flags", [bt.present, bt.powered, bt.discovering, bt.searchUntilMs, bt.visibleUntilMs], [true, true, true, 0, 0]);
eq("bt.deadlines", [M.buildBt(Object.assign({}, btIn, { btSearchUntilMs: 5000, btVisibleUntilMs: 900 })).searchUntilMs, M.buildBt(Object.assign({}, btIn, { btSearchUntilMs: 5000, btVisibleUntilMs: 900 })).visibleUntilMs], [5000, 0]);
eq("bt.absent", [M.buildBt({ btAdapter: null, btDevices: [] }).present, M.buildBt({ btAdapter: null }).powered], [false, false]);
eq("bt.softblock", M.buildBt(Object.assign({}, btIn, { btAdapter: { enabled: false, state: "Blocked" }, btRfkill: { hard: true } })).softBlocked, true);
eq("bt.caseonly", M.btBattery(dev("09", { connected: true }), { "09": { case: { pct: 80, charging: false } } }).pct, -1);
eq("seen", [M.btSeenNext({}, [dev("07"), dev("08", { paired: true })], true), M.btSeenNext({ "07": true }, [dev("08")], false)], [{ "07": true }, { "07": true }]);

// ---- low battery: 20 / 10, once per crossing, re-armed above 25
(function () {
    const d = (pct, o) => [{ address: "01", name: "Buds", connected: true, battery: pct, parts: o || null }];
    let st = {}, ev = [];
    function step(pct, o) { const r = M.lowBattery(st, d(pct, o)); st = r.state; ev = ev.concat(r.events.map(e => e.level)); }
    [50, 30, 21, 20, 19, 18, 12, 11, 10, 9, 8].forEach(p => step(p));
    eq("low.once", ev, [20, 10]);
    step(22); step(24); step(19);
    eq("low.noarm.below25", ev, [20, 10]);          // 22 / 24 are not above 25: not re-armed
    step(26); step(20);
    eq("low.rearm", ev, [20, 10, 20]);
    step(5);
    eq("low.crit.after", ev, [20, 10, 20, 10]);
    ev = []; st = {}; step(15, { charging: true }); step(15);
    eq("low.charging", ev, [20]);                    // the first while charging says nothing; the second (not charging) does
    ev = []; st = {}; const r = M.lowBattery({}, [{ address: "02", name: "x", connected: false, battery: 5 }, { address: "03", name: "y", connected: true, battery: -1 }]);
    eq("low.skips", r.events, []);
    ev = []; st = {}; step(8);
    eq("low.firstsight.crit", ev, [10]);
})();

// ---- usage
(function () {
    const T = (y, mo, d, h, mi) => new Date(y, mo - 1, d, h || 12, mi || 0).getTime();
    eq("daykey", [M.dayKey(T(2026, 11, 19)), M.dayKey(T(2026, 1, 1, 0, 0)), M.dayKey(T(2026, 12, 31, 23, 59))], ["2026-11-19", "2026-01-01", "2026-12-31"]);
    // DST (Europe/Brussels): 2026-03-29 spring forward (23 h day), 2026-10-25 fall back (25 h day)
    eq("dst.back.spring", [M.dayKeyBack(T(2026, 3, 30, 0, 30), 1), M.dayKeyBack(T(2026, 3, 29, 12), 1), M.dayKeyBack(T(2026, 3, 30, 12), 2)], ["2026-03-29", "2026-03-28", "2026-03-28"]);
    eq("dst.back.fall", [M.dayKeyBack(T(2026, 10, 26, 0, 30), 1), M.dayKeyBack(T(2026, 10, 26, 12), 2), M.dayKeyBack(T(2026, 10, 25, 12), 1)], ["2026-10-25", "2026-10-24", "2026-10-24"]);
    eq("dst.days.run", (function () { const u = M.usageFacts(M.usageNew(), T(2026, 3, 30, 0, 10), "").days.map(d => d.day); return [u.length, u[27], u[28], u[29], new Set(u).size]; })(), [30, "2026-03-28", "2026-03-29", "2026-03-30", 30]);
    eq("dst.days.fall", (function () { const u = M.usageFacts(M.usageNew(), T(2026, 10, 25, 23, 50), "").days.map(d => d.day); return [u[28], u[29], new Set(u).size]; })(), ["2026-10-24", "2026-10-25", 30]);
    // a sample on each side of the changes lands on the right day
    let s = M.usageNew();
    s = M.usageSample(s, { iface: "w", rx: 0, tx: 0, key: "Home", label: "Home" }, T(2026, 3, 29, 1, 59));
    s = M.usageSample(s, { iface: "w", rx: 1000, tx: 500, key: "Home", label: "Home" }, T(2026, 3, 29, 3, 1));
    eq("usage.dst.day", Object.keys(s.days), ["2026-03-29"]);
    // counters: baseline counts nothing; deltas go to the previous key; a counter that went backwards counts from 0
    let u = M.usageNew(); const t0 = T(2026, 11, 19, 10);
    u = M.usageSample(u, { iface: "w", rx: 5000, tx: 5000, key: "Home", label: "Home" }, t0);
    eq("usage.baseline", Object.keys(u.days).length, 0);
    u = M.usageSample(u, { iface: "w", rx: 6000, tx: 5500, key: "Home", label: "Home" }, t0 + 1000);
    eq("usage.delta", u.days["2026-11-19"].Home, 1500);
    u = M.usageSample(u, { iface: "w", rx: 6100, tx: 5500, key: "Cafe", label: "Cafe" }, t0 + 2000);      // network changed: these 100 B were under Home
    eq("usage.attrib.prev", [u.days["2026-11-19"].Home, u.days["2026-11-19"].Cafe], [1600, undefined]);
    u = M.usageSample(u, { iface: "w", rx: 6300, tx: 5600, key: "Cafe", label: "Cafe" }, t0 + 3000);
    eq("usage.attrib.new", u.days["2026-11-19"].Cafe, 300);
    u = M.usageSample(u, { iface: "w", rx: 40, tx: 10, key: "Cafe", label: "Cafe" }, t0 + 4000);          // reset (reboot / iface reset)
    eq("usage.reset", u.days["2026-11-19"].Cafe, 350);
    u = M.usageSample(u, { iface: "e", rx: 99999, tx: 99999, key: "wired:e", label: "Cable" }, t0 + 5000);  // another interface: baseline
    eq("usage.iface.baseline", u.days["2026-11-19"].Cafe, 350);
    u = M.usageSample(u, { iface: "e", rx: 100999, tx: 99999, key: "wired:e", label: "Cable" }, t0 + 6000);
    eq("usage.wired", u.days["2026-11-19"]["wired:e"], 1000);
    u = M.usageSample(u, { iface: "e", rx: 101999, tx: 99999, key: "", label: "" }, t0 + 7000);             // no network: the interval still belongs to the last key
    u = M.usageSample(u, { iface: "e", rx: 150000, tx: 99999, key: "", label: "" }, t0 + 8000);             // ...but nothing counts with no key
    eq("usage.nokey", u.days["2026-11-19"]["wired:e"], 2000);
    // persistence round trip = a reboot: days kept, counters fresh (a baseline), nothing counted twice
    const back = M.usageFromJson(M.usageToJson(u));
    eq("usage.persist", [back.last, JSON.stringify(back.days) === JSON.stringify(u.days)], [null, true]);
    const after = M.usageSample(back, { iface: "w", rx: 12, tx: 12, key: "Home", label: "Home" }, t0 + 9000);
    eq("usage.reboot.nodouble", after.days["2026-11-19"].Home, u.days["2026-11-19"].Home);
    eq("usage.badjson", [Object.keys(M.usageFromJson("{").days).length, Object.keys(M.usageFromJson('{"days":{"x":{"a":1},"2026-01-01":{"a":-4,"b":2}}}').days["2026-01-01"])], [0, ["b"]]);
    // facts
    const fct = M.usageFacts(u, t0 + 9000, "Cafe");
    eq("usage.facts", [fct.todayBytes, fct.monthBytes, fct.current, fct.byNetwork.map(n => [n.key, n.label, n.today, n.month]), fct.days.length, fct.days[29]],
       [u.days["2026-11-19"].Home + 350 + 2000, u.days["2026-11-19"].Home + 350 + 2000, { key: "Cafe", bytes: 350 }, [["Home", "Home", 1600, 1600], ["wired:e", "Cable", 2000, 2000], ["Cafe", "Cafe", 350, 350]].sort((a, b) => b[3] - a[3]), 30, { day: "2026-11-19", bytes: 3950 }]);
    // 30 days kept: older ones are pruned, last month stays out of "month"
    let old = M.usageNew(); old.days["2026-09-01"] = { a: 7 }; old.days["2026-10-25"] = { a: 5 }; old.days["2026-10-20"] = { a: 3 };
    old = M.usageSample(old, { iface: "w", rx: 1, tx: 1, key: "a", label: "a" }, T(2026, 11, 19));
    eq("usage.prune", Object.keys(old.days).sort(), ["2026-10-20", "2026-10-25"]);
    eq("usage.month", [M.usageFacts(old, T(2026, 11, 19), "").monthBytes, M.usageFacts(old, T(2026, 11, 19), "").days.reduce((a, d) => a + d.bytes, 0)], [0, 5]);
    eq("usage.pruneedge", (function () { let o = M.usageNew(); o.days["2026-10-19"] = { a: 1 }; o.days["2026-10-18"] = { a: 1 }; o = M.usageSample(o, { iface: "w", rx: 1, tx: 1, key: "a", label: "a" }, T(2026, 11, 18)); return Object.keys(o.days).sort(); })(), ["2026-10-19"]);
})();

// ---- /proc readers
eq("proc.wireless", M.parseProcWireless("Inter-| sta-|   Quality        |   Discarded packets               | Missed | WE\n face | tus | link level noise |  nwid  crypt   frag  retry   misc | beacon | 22\nwlp47s0: 0000   60.  -50.  -256        0      0      0      0      0        0\n"), { wlp47s0: -50 });
eq("proc.dev", M.parseProcNetDev("Inter-|   Receive                                                |  Transmit\n face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n    lo: 100 1 0 0 0 0 0 0 100 1 0 0 0 0 0 0\nwlp47s0: 123456 99 0 0 0 0 0 0 7890 50 0 0 0 0 0 0\n"), { lo: { rx: 100, tx: 100 }, wlp47s0: { rx: 123456, tx: 7890 } });
eq("rate", [M.rateBps({ rx: 0, tx: 0 }, { rx: 2000, tx: 500 }, 1000), M.rateBps({ rx: 9000, tx: 9000 }, { rx: 1000, tx: 0 }, 1000), M.rateBps(null, { rx: 1, tx: 1 }, 1000)], [{ rxBps: 2000, txBps: 500 }, { rxBps: 1000, txBps: 0 }, { rxBps: 0, txBps: 0 }]);

// ---- errors
(function () {
    eq("part", [["connect", "Cafe"], ["setRadio", ""], ["btConnect", "01"], ["vpnConnect", ""], ["testPad", "dns"], ["testPad", "all"], ["setAirplane", ""], ["startHotspot", ""], ["updateProfile", "u"], ["connectWired", "e"], ["btSearch", ""], ["btVisible", ""], ["setBtPowered", ""], ["runSpeedTest", ""]].map(a => M.partOf(a[0], a[1])),
       ["net:Cafe", "dip.wifi", "bt:01", "globe", "pad.dns", "pad.net", "screw", "hotspot", "mem", "jack", "bt.scan", "beacon", "dip.bt", "rates"]);
    let es = [];
    const r = M.errorRecord("connect", "Cafe", "wrong password", 5);
    es = M.errorsPush(es, r);
    es = M.errorsPush(es, M.errorRecord("connect", "Cafe", "again", 9));
    eq("err.replace", es.map(e => [e.id, e.part, e.text, e.sinceMs]), [["connect:Cafe", "net:Cafe", "again", 9]]);
    ok("err.way", es[0].way.length > 0);
    eq("err.dismiss", M.errorsDismiss(es, "connect:Cafe"), []);
    eq("err.prune.keeps", M.errorsPrune(es, f).length, 1);
    eq("err.prune.connected", M.errorsPrune(M.errorsPush([], M.errorRecord("connect", "Home", "x", 1)), f).length, 0);
    eq("err.prune.gone", M.errorsPrune(M.errorsPush([], M.errorRecord("connect", "Nowhere", "x", 1)), f).length, 0);
    eq("err.prune.pad", M.errorsPrune(M.errorsPush([], M.errorRecord("testPad", "link", "x", 1)), f).length, 0);
    eq("err.prune.globe", [M.errorsPrune(M.errorsPush([], M.errorRecord("vpnConnect", "", "x", 1)), withTun).length, M.errorsPrune(M.errorsPush([], M.errorRecord("vpnConnect", "", "x", 1)), f).length], [0, 1]);
    const same = M.errorsPush([], M.errorRecord("scan", "", "x", 1));
    ok("err.prune.same", M.errorsPrune(same, f) === same);
})();

// ---- an error as a toast
(function () {
    const f = { health: { portal: { present: true, url: "http://x" } }, bt: { devices: [{ address: "AA", name: "Buds" }] } };
    const w = (i, a, t, ff) => M.toastWords(M.errorRecord(i, a, t, 1), ff === undefined ? f : ff);
    eq("toast.net", [w("connect", "Cafe", "The password was not accepted.").title, w("connect", "Cafe", "x").key], ["Could not join Cafe", "fail-connect:Cafe"]);
    eq("toast.portal.action", [w("testPad", "all", "x").action, w("testPad", "all", "x", { health: { portal: { present: false } } }).action, w("openPortal", "", "x").action], ["portal", "", ""]);
    ok("toast.proton.command", w("vpnConnect", "", "ProtonVPN is not signed in.").body.indexOf("protonvpn signin") > 0);
    eq("toast.bt", w("btConnect", "AA", "x").title, "Bluetooth: Buds");
    eq("toast.same.key", w("connect", "Cafe", "a").key === w("connect", "Cafe", "b").key, true);
})();

// ---- config
(function () {
    const w = []; const c = M.configFrom({ autoTunnel: false, searchSeconds: 1, visibleSeconds: 99, speedTest: { capMB: 50 }, portalCheckUrl: "ftp://x", look: { secondarySide: "end" } }, t => w.push(t));
    eq("config", [c.autoTunnel, c.searchSeconds, c.visibleSeconds, c.speedTest.capMB, c.portalCheckUrl, c.look.secondarySide, w.length], [false, 30, 99, 50, "http://ping.archlinux.org/nm-check.txt", "end", 2]);
    eq("config.default", M.configFrom(null), M.DEFAULT_CONFIG);
    eq("config.default.immutable", (function () { M.configFrom({ speedTest: { capMB: 7 } }); return M.DEFAULT_CONFIG.speedTest.capMB; })(), 200);
})();

// ---- one switch written into the hand-edited file
eq("cfgbool.replace", M.setConfigBool('{\n  // keep\n  "autoTunnel": true, // on\n  "searchSeconds": 30\n}', "autoTunnel", false), '{\n  // keep\n  "autoTunnel": false, // on\n  "searchSeconds": 30\n}');
eq("cfgbool.insert", JSON.parse(M.setConfigBool('{\n  "searchSeconds": 30\n}', "autoTunnel", false)), { autoTunnel: false, searchSeconds: 30 });
eq("cfgbool.insert.empty", JSON.parse(M.setConfigBool('{}', "autoTunnel", true)), { autoTunnel: true });
eq("cfgbool.insert.nofile", JSON.parse(M.setConfigBool('', "autoTunnel", true)), { autoTunnel: true });

console.log(`AM ${n} checks, ${fails} failed`);
// ---- a connection NetworkManager accepted and then failed (stream I)
eq("activationfail.nosecrets", M.activationFailText("no-secrets", false), "The password was not accepted.");
eq("activationfail.sawauth", M.activationFailText("supplicant-timeout", true), "The password was not accepted.");
eq("activationfail.dhcp", M.activationFailText("dhcp-failed", false), "The network did not hand out an address.");
eq("activationfail.other", M.activationFailText("", false), "The connection could not be made.");

console.log("AERIAL-MODEL RESULT " + (fails === 0 ? "PASS" : "FAIL"));
process.exit(fails === 0 ? 0 : 1);
