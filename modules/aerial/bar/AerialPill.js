.pragma library

// =============================================================================
// AerialPill.js -- what the bar's pill draws of the AerialService's facts. Pure (node-testable: tools/dev/aerial_pill_cases.js).
//
// ONE record, `of(facts)`, from the facts the service publishes (wifi, wired, hotspot, bt, proton, health, airplane, rates, helper):
//   airplane   the master switch is in effect: the plane takes the Wi-Fi half's place
//   wiredShown the wired socket is the net half's glyph (the cable carries the traffic, or there is no Wi-Fi device and a jack)
//   hotspotOn  the own hotspot is up: the broadcasting glyph stands in place of the fan (the state wins over the fan's level)
//   netOn      the net half is ON (a link over the wire, the Wi-Fi radio up -- connected or looking --, or the hotspot)
//   bars       0..4, the connected network's strength (4 - signalBand: the band has the service's hysteresis)
//   fault      "" | "warn" | "error": the worst PAD that has been tested (a portal or a slow DNS is warn, a failed pad error; "warn" too while the network helper is dead)
//   helperFailed the network helper is not running: the net glyph takes the warn colour, on or off
//   vpnUp      Proton's tunnel is up                       -> a padlock badge on the net glyph
//   publicOpen the joined Wi-Fi network is Public and no tunnel is up -> an open padlock mark, in the warn colour
//   btOn       the Bluetooth radio is on (an adapter, powered, not blocked);  btConnected  a device is connected
// ON IS A COLOUR (no slashed glyph): the host mixes the half's on hue; the shapes that carry information stay.
// =============================================================================

function _arr(a) { return a && a.length !== undefined ? a : []; }

function of(f) {
    f = f || {};
    var wifi = f.wifi || {}, wired = f.wired || {}, hot = f.hotspot || {}, bt = f.bt || {}, proton = f.proton || {}, health = f.health || {};
    var rates = f.rates || {};
    var helperFailed = !!f.helper && f.helper.state === "failed";
    var airplane = !!(f.airplane && f.airplane.on);
    var nets = _arr(wifi.networks), jacks = _arr(wired.jacks);

    var joined = null;
    for (var i = 0; i < nets.length; i++)
        if (nets[i] && nets[i].connected) { joined = nets[i]; break; }
    var linked = null;
    for (var j = 0; j < jacks.length; j++)
        if (jacks[j] && jacks[j].connected) { linked = jacks[j]; break; }
    // the cable is the carrying link unless Wi-Fi is up AND the traffic runs over Wi-Fi (the scene's own rule: AerialFacts)
    var cableCarries = !!linked && (!joined || (rates.iface && linked.iface === rates.iface));
    var wiredShown = cableCarries || (!wifi.present && jacks.length > 0);
    var hotspotOn = !!hot.active;
    var radio = !!wifi.present && !!wifi.radioOn && !wifi.hardBlocked;
    var netOn = !airplane && (hotspotOn || cableCarries || (!wiredShown && radio));

    var worst = "";
    var pads = _arr(health.pads);
    for (var k = 0; k < pads.length; k++) {
        var s = pads[k] ? pads[k].state : "";
        if (s === "fail") worst = "error";
        else if (s === "warn" && worst !== "error") worst = "warn";
    }
    var tunnel = proton.state === "up";
    var onWifi = !!joined && !cableCarries && !hotspotOn;

    var devs = _arr(bt.devices), connected = false;
    for (var d = 0; d < devs.length; d++)
        if (devs[d] && devs[d].connected) { connected = true; break; }

    return {
        airplane: airplane,
        wiredShown: wiredShown,
        hotspotOn: hotspotOn,
        netOn: netOn,
        bars: joined ? Math.max(0, Math.min(4, 4 - (Number(joined.signalBand) || 0))) : 0,
        fault: helperFailed ? "warn" : netOn ? worst : "",
        helperFailed: helperFailed,
        vpnUp: netOn && tunnel,
        publicOpen: netOn && onWifi && joined.trusted === false && !tunnel,
        btOn: !!bt.present && !!bt.powered && !bt.hardBlocked && !bt.softBlocked,
        btConnected: connected
    };
}
