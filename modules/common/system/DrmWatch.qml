pragma ComponentBehavior: Bound

import QtQuick
import "../components"
import "DrmRules.js" as R

// =============================================================================
// DrmWatch.qml -- the DRM connectors, a DisplayLink dock's traces and when each connector
// became connected: ONE per shell, read from /sys and kept by ONE long-lived udev monitor.
// (Lifted from silicon's DisplayWatcher, which only knew the NVIDIA HDMI fact.)
//
//   connectors        [{ name "DP-1", dir, card, type, index, driver, vendor, status, enabled, nvidia }]
//                     (DrmRules.js has the record and the reasons)
//   nvidiaHdmi        an HDMI-A connector of an NVIDIA card reads connected (silicon's `display.hdmi`)
//   displayLinkUsb    a USB device of vendor 17e9 is present; displayLinkSince the instant it was
//                     first seen (0 when absent)
//   evdiLoaded        /sys/module/evdi exists
//   displayLinkActive `systemctl is-active displaylink.service`; asked only when a scan runs with a
//                     dock present (a fork is not free)
//   connectedSince    { <connector name>: ms } of the connectors reading connected, for "connected but off"
//   watching / why    the udev monitor is running; `why` says why not
//   scans             how many scans were made (a probe's counter)
//   rescan()          read now (a scan in flight makes it once more when it ends)
//   changed()         anything above moved
//
// WHEN IT LOOKS. Never on a timer: once at start, on a udev `drm` event or a usb `add` / `remove`
// (a dock plugged or pulled), and when the owner asks (`rescan()`). ONE `udevadm monitor --udev
// --subsystem-match=drm --subsystem-match=usb` under `setpriv --pdeathsig TERM`, kept by a
// SupervisedStream; a burst of events is one scan (`debounceMs`). A scan is one short `sh`
// reading cached files, so a sleeping card stays asleep.
//
// QUIET. udevadm and setpriv are looked for with `command -v` first: a Process whose program does
// not exist reports neither a start nor an exit and warns. Without them the facts are still read
// at start and on `rescan()`, and `why` says the live watching is off.
// =============================================================================
Item {
    id: root

    property string drmRoot: "/sys/class/drm"
    property string usbRoot: "/sys/bus/usb/devices"
    property string evdiModule: "/sys/module/evdi"
    property string udevadm: "udevadm"
    property string systemctl: "systemctl"
    property int debounceMs: 300
    property int timeoutMs: 6000

    readonly property var connectors: root._connectors
    readonly property bool nvidiaHdmi: root._nvidiaHdmi
    readonly property bool displayLinkUsb: root._usb
    readonly property real displayLinkSince: root._usbSince
    readonly property bool evdiLoaded: root._evdi
    readonly property bool displayLinkActive: root._dlActive
    readonly property var connectedSince: root._since
    readonly property bool watching: root._watching
    readonly property string why: root._why
    readonly property int scans: root._scans

    signal changed

    function rescan() {
        if (!root._ready || !root.enabled)
            return;
        if (root._inFlight) {
            root._again = true;
            return;
        }
        root._scan();
    }

    // ---- Private -----------------------------------------------------------------
    property bool _ready: false
    property bool _inFlight: false
    property bool _again: false
    property var _connectors: []
    property bool _nvidiaHdmi: false
    property bool _usb: false
    property real _usbSince: 0
    property bool _evdi: false
    property bool _dlActive: false
    property var _since: ({})
    property string _sig: ""
    property bool _watching: false
    property string _why: ""
    property int _scans: 0

    ProcLane { id: lane; timeoutMs: root.timeoutMs }

    function _scan() {
        root._inFlight = true;
        root._scans++;
        lane.run(["sh", "-c", R.SCAN_SCRIPT, "sh", root.drmRoot, root.usbRoot, root.evdiModule], function (r) {
            if (r.code !== 0 || r.timedOut) {
                root._scanEnded();
                return;
            }
            const p = R.parseScan(r.out);
            if (!p.displayLinkUsb) {
                root._apply(p, false);
                return;
            }
            // a dock is present: is its service up? (asked here and nowhere else)
            lane.run([root.systemctl, "is-active", "displaylink.service"], function (a) {
                root._apply(p, !a.timedOut && String(a.out).trim() === "active");
            });
        });
    }

    function _apply(p, dlActive) {
        const now = Date.now();
        const since = R.connectedSince(root._since, p.connectors, now);
        const usbSince = p.displayLinkUsb ? (root._usbSince > 0 ? root._usbSince : now) : 0;
        // the signature holds what a reader can see; the instants follow from it
        const sig = JSON.stringify([p.connectors, p.displayLinkUsb, p.evdiLoaded, dlActive]);
        if (sig !== root._sig) {
            root._sig = sig;
            root._connectors = p.connectors;
            root._nvidiaHdmi = R.nvidiaHdmi(p.connectors);
            root._usb = p.displayLinkUsb;
            root._usbSince = usbSince;
            root._evdi = p.evdiLoaded;
            root._dlActive = dlActive;
            root._since = since;
            root.changed();
        }
        root._scanEnded();
    }

    function _scanEnded() {
        root._inFlight = false;
        if (root._again) {
            root._again = false;
            Qt.callLater(root.rescan);
        }
    }

    Timer { id: debounce; interval: root.debounceMs; onTriggered: root.rescan() }

    // ---- the monitor ------------------------------------------------------------
    SupervisedStream {
        id: mon
        enabled: false
        what: "DrmWatch: the udev monitor"
        onLine: text => root._feed(text)
        onExited: (code, expected) => {
            if (!expected)
                root._why = "the udev monitor ended (" + code + "); restarting it";
        }
    }

    // Only an event line counts, not the monitor's header. A drm event of any kind; a usb one only when a device came or went
    // (every `change` / `bind` of a keyboard would be a scan for nothing).
    function _feed(text) {
        const m = /^UDEV\s+\[[^\]]*\]\s+(add|remove|change|bind|unbind)\s.*\((drm|usb)\)\s*$/.exec(String(text));
        if (!m)
            return;
        if (m[2] === "usb" && m[1] !== "add" && m[1] !== "remove")
            return;
        debounce.restart();
    }

    function _startMonitor() {
        if (!root.enabled || mon.enabled)
            return;
        lane.run(["sh", "-c", "command -v \"$1\" > /dev/null 2>&1 && command -v setpriv > /dev/null 2>&1", "sh", root.udevadm], function (res) {
            if (res.code !== 0) {
                root._why = "udevadm or setpriv is not installed (" + root.udevadm + "): connectors are read at start and when asked";
                return;
            }
            root._why = "";
            mon.command = ["setpriv", "--pdeathsig", "TERM", "--", root.udevadm, "monitor", "--udev", "--subsystem-match=drm", "--subsystem-match=usb"];
            mon.enabled = true;
            root._watching = true;
        });
    }

    onEnabledChanged: {
        if (!root._ready)
            return;
        if (root.enabled) {
            root.rescan();
            root._startMonitor();
        } else {
            root._watching = false;
            debounce.stop();
            mon.enabled = false;
        }
    }

    Component.onCompleted: {
        root._ready = true;
        if (root.enabled) {
            root.rescan();
            root._startMonitor();
        }
    }
}
