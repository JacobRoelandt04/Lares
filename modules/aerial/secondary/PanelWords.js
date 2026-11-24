.pragma library

// =============================================================================
// PanelWords.js -- the words of the aerial panels, pure (node-testable). Titles say what is happening NOW in the user's model; a fact
// that is not known is "" (the row takes no room), never a dash.
// =============================================================================

function security(s) {
    switch (s) {
    case "open": return "Open";
    case "owe": return "Open (encrypted)";
    case "wep": return "WEP";
    case "wpa2": return "WPA2";
    case "wpa3": return "WPA3";
    case "wpa2/3": return "WPA2 / WPA3";
    case "eap": return "WPA Enterprise";
    }
    return "";
}

function secured(s) {
    return s === "wep" || s === "wpa2" || s === "wpa3" || s === "wpa2/3" || s === "eap";
}

function band(b) {
    return b === "2.4" || b === "5" || b === "6" ? b + " GHz" : "";
}

function bands(list) {
    return (list || []).map(band).filter(function (x) { return x !== ""; }).join(" + ");
}

function rate(mbps) {
    var n = Number(mbps);
    if (!(n > 0)) return "";
    return n >= 1000 ? (Math.round(n / 100) / 10) + " Gbit/s" : Math.round(n) + " Mbit/s";
}

function dbm(v) {
    var n = Number(v);
    return n < 0 ? Math.round(n) + " dBm" : "";
}

function netState(st) {
    switch (st) {
    case "connected": return "Connected";
    case "connecting": return "Connecting";
    case "needsSecret": return "Needs a password";
    case "disconnecting": return "Disconnecting";
    case "failed": return "Could not connect";
    }
    return "Not connected";
}

// the width of a channel the way a person says it
function width(mhz) {
    return Number(mhz) > 0 ? Number(mhz) + " MHz" : "";
}

function channel(ap) {
    if (!ap) return "";
    var s = ap.channel > 0 ? "channel " + ap.channel : "";
    var w = width(ap.widthMhz);
    return s + (s !== "" && w !== "" ? ", " : "") + w;
}

function ipLine(ip, prefix) {
    return ip ? ip + (prefix > 0 ? "/" + prefix : "") : "";
}

// a catalog feature list ("secure-core", "securecore", "p2p", "tor") against one wanted name, dashes ignored
function hasFeature(list, name) {
    var w = String(name).replace(/-/g, "");
    var l = list || [];
    for (var i = 0; i < l.length; i++)
        if (String(l[i]).replace(/-/g, "") === w) return true;
    return false;
}

function featureWords(list) {
    var out = [];
    if (hasFeature(list, "securecore")) out.push("Secure Core");
    if (hasFeature(list, "p2p")) out.push("P2P");
    if (hasFeature(list, "tor")) out.push("Tor");
    return out.join(", ");
}

// ---- the test pads: what the stage means in plain words, and the way out ----
var PADS = {
    link: { title: "Link", means: "Whether the network card has a link: a Wi-Fi network joined, or a cable in.",
            ok: "The card has a link.", warn: "The link is weak.", fail: "There is no link. Join a network or plug a cable in.", unknown: "Not looked at yet." },
    addr: { title: "Address", means: "Whether the network gave this machine an address (DHCP).",
            ok: "The network gave this machine an address.", warn: "The address is not settled yet.", fail: "The network gave no address. Reconnect, or check the IP settings.", unknown: "Waits for a link." },
    gateway: { title: "Gateway", means: "Whether the router (the first hop) answers.",
               ok: "The router answers.", warn: "The router answers slowly.", fail: "The router does not answer. Move closer, or restart it.", unknown: "Waits for an address." },
    dns: { title: "DNS", means: "Whether names (example.org) turn into addresses.",
           ok: "Names resolve.", warn: "Names resolve slowly.", fail: "Names do not resolve. Try another DNS server on the IP & DNS page.", unknown: "Waits for the router." },
    net: { title: "Internet", means: "Whether the internet itself answers (a small page is fetched, nothing more).",
           ok: "The internet answers.", warn: "The network may want a login first.", fail: "The internet does not answer.", unknown: "Waits for names." }
};

function pad(id) {
    return PADS[id] || { title: id, means: "", ok: "", warn: "", fail: "", unknown: "" };
}

function padState(id, state) {
    var p = pad(id);
    return p[state] !== undefined ? p[state] : p.unknown;
}

function btKind(k) {
    switch (k) {
    case "earbuds": return "Earbuds";
    case "headset": return "Headset";
    case "speaker": return "Speaker";
    case "phone": return "Phone";
    case "computer": return "Computer";
    case "mouse": return "Mouse";
    case "keyboard": return "Keyboard";
    case "gamepad": return "Game controller";
    case "watch": return "Watch";
    }
    return "Device";
}

function btRing(r) {
    return r === "inner" ? "Connected" : r === "middle" ? "Paired" : r === "outer" ? "Heard nearby" : "";
}

// 482913 / "482913" -> "482 913" (the way it is read out)
function code3(code) {
    var s = String(code === undefined || code === null ? "" : code).replace(/\s+/g, "");
    return s.length === 6 ? s.slice(0, 3) + " " + s.slice(3) : String(code === undefined || code === null ? "" : code);
}

// "Hello" -> a relative-time-free short date "5 Nov" for the chart's axis
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
function dayLabel(day) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(day));
    return m ? Number(m[3]) + " " + MONTHS[Number(m[2]) - 1] : "";
}

// the axis maximum of a chart: 1, 2 or 5 times a power of ten (of bytes, decimal: the counters are bytes)
function niceMax(v) {
    var n = Number(v);
    if (!(n > 0)) return 1;
    var e = Math.pow(10, Math.floor(Math.log(n) / Math.LN10));
    var f = n / e;
    return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * e;
}

function bytes(n) {
    var v = Number(n);
    if (!isFinite(v) || v < 0) return "";
    var u = ["B", "kB", "MB", "GB", "TB"], i = 0;
    while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; }
    return (i === 0 ? Math.round(v) : (v >= 100 ? Math.round(v) : Math.round(v * 10) / 10)) + " " + u[i];
}
