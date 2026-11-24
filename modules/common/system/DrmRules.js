.pragma library

// =============================================================================
// DrmRules.js -- what the shell reads out of /sys/class/drm (and the DisplayLink dock's two other
// traces) as PLAIN VALUES. Pure: nothing here opens a file or starts a process; DrmWatch runs the
// scan script and hands the text in. No Qt, loadable under node.
//
//   SCAN_SCRIPT                 one short `sh` (args: drm root, usb root, evdi module path)
//   parseScan(text)             -> { connectors, displayLinkUsb, evdiLoaded }
//   nvidiaHdmi(connectors)      silicon's fact: an HDMI-A connector of an NVIDIA card reads connected
//   connectedSince(prev, connectors, now)   the map name -> ms a connector became connected
//
// A connector: { name "DP-1", dir "card1-DP-1", card "card1", type "DP", index 1, driver "i915" |
// "xe" | "nvidia" | "evdi" | "", vendor "0x8086" (the card's PCI vendor; "" for a platform device
// such as evdi), status "connected" | "disconnected" | "unknown", enabled (the kernel's `enabled`
// file: "enabled" / "disabled"), nvidia (the card's PCI vendor is 0x10de) }.
//
// THE RULE OF THE NVIDIA HDMI FACT (it moved here from silicon's SysfsParse, unchanged). Only an
// HDMI-A connector of a card whose PCI vendor is 0x10de counts. The laptop's other outputs are not
// the card's: the iGPU's eDP / DP-1..4 (USB-C), and a DisplayLink dock, which appears as a DRM card
// of its own (evdi, a virtual platform device with DVI-I connectors) with no PCI vendor at all.
//
// /sys/class/drm has one directory per card (`card1`, with `device` -> its PCI device) and one per
// connector (`card1-HDMI-A-1/status`). A connector's `status` is the kernel's CACHED answer (drm's
// status_show does not probe) and the card's `device/vendor` and `device/driver` are cached
// attributes: reading them never wakes a sleeping card. The NVIDIA card's connectors exist only
// while nvidia_drm has the card, so "no such connector" is "no cable".
// =============================================================================

var NVIDIA_PCI_VENDOR = "0x10de";
var DISPLAYLINK_USB_VENDOR = "17e9";

// Lines: `c TAB dir TAB vendor TAB status TAB enabled TAB driver`, `u TAB usb device`, `m TAB evdi`.
var SCAN_SCRIPT = [
    'if cd "$1" 2>/dev/null; then',
    '  for c in card[0-9]*-*; do',
    '    [ -f "$c/status" ] || continue',
    '    card=${c%%-*}',
    '    drv=$(readlink "$card/device/driver" 2>/dev/null); drv=${drv##*/}',
    '    printf "c\\t%s\\t%s\\t%s\\t%s\\t%s\\n" "$c" "$(cat "$card/device/vendor" 2>/dev/null)" "$(cat "$c/status" 2>/dev/null)" "$(cat "$c/enabled" 2>/dev/null)" "$drv"',
    '  done',
    'fi',
    'for d in "$2"/*/; do',
    '  [ -f "${d}idVendor" ] && [ "$(cat "${d}idVendor" 2>/dev/null)" = ' + DISPLAYLINK_USB_VENDOR + ' ] && printf "u\\t%s\\n" "${d%/}"',
    'done',
    '[ -e "$3" ] && printf "m\\tevdi\\n"',
    'exit 0'
].join("\n");

function parseScan(text) {
    var out = { connectors: [], displayLinkUsb: false, evdiLoaded: false };
    String(text === undefined || text === null ? "" : text).split("\n").forEach(function (line) {
        var f = line.split("\t");
        if (f[0] === "u") {
            out.displayLinkUsb = true;
            return;
        }
        if (f[0] === "m") {
            out.evdiLoaded = true;
            return;
        }
        if (f[0] !== "c" || f.length < 4)
            return;
        var dir = f[1].trim();
        var m = /^(card\d+)-(.+)-(\d+)$/.exec(dir);
        if (!m)
            return;
        var vendor = f[2].trim().toLowerCase();
        out.connectors.push({
            name: m[2] + "-" + m[3], dir: dir, card: m[1], type: m[2], index: parseInt(m[3], 10),
            driver: f.length > 5 ? f[5].trim() : "", vendor: vendor, status: f[3].trim(),
            enabled: f.length > 4 ? f[4].trim() : "", nvidia: vendor === NVIDIA_PCI_VENDOR
        });
    });
    return out;
}

function nvidiaHdmi(connectors) {
    var list = connectors || [];
    for (var i = 0; i < list.length; i++) {
        var c = list[i];
        if (c.nvidia && c.type === "HDMI-A" && c.status === "connected")
            return true;
    }
    return false;
}

// Keyed by the connector name ("DP-1": the Hyprland output's name, which is unique). A connector keeps the instant it first read connected, until it reads anything else.
function connectedSince(prev, connectors, now) {
    var next = {};
    (connectors || []).forEach(function (c) {
        if (c.status === "connected")
            next[c.name] = prev && prev[c.name] !== undefined ? prev[c.name] : now;
    });
    return next;
}
