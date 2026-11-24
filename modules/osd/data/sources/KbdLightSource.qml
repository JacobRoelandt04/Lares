pragma ComponentBehavior: Bound

import QtQuick
import "../../../common/components"
import "../../../common/system"

// =============================================================================
// KbdLightSource.qml -- the keyboard backlight: the shell's own keys, and the
// laptop's Fn key.
//
//   adjust(dir)                a key step (up | down), clamped to 0..max
//   signal request(var req)    one partial CONTRACT section 1 request
//
// THE Fn KEY writes the LED in firmware and the kernel only SAYS so through
// `brightness_hw_changed` (a sysfs attribute that raises POLLPRI; plain inotify
// never sees it). tools/osd/sysfs_pollpri.py waits on it with select.poll and
// prints one line, the new value, per change; it runs under
// `setpriv --pdeathsig TERM` so it dies with the shell. Our own brightnessctl
// writes do not touch that attribute, so they never echo.
//
// THE HELPER IS SUPERVISED. The attribute answers read() with ENODATA until the firmware has changed
// the LED once since boot, and a bare `Process` is never started again, so a helper that took that for
// a crash would stay gone with nobody noticing. The helper waits out ENODATA and reopens a vanished
// attribute itself, and a SupervisedStream starts it again, with one warning per failing streak,
// whatever else ends it.
//
// 4 stops on this laptop (asus::kbd_backlight, max 3): `stop` is the raw value,
// `stops` is max + 1.
//
// `device: ""` is a machine with no keyboard light: no helper, no file read, adjust() does nothing.
//
// `live: false` runs no helper and writes nothing: simulateSet() seeds the
// value, simulateHw(raw) is the helper's line, and a key step emits the same
// request.
// =============================================================================
Item {
    id: root

    property bool live: true
    property string device: "asus::kbd_backlight"
    property string helperPath: RepoRoot.dir + "/tools/osd/sysfs_pollpri.py"
    property string ledRoot: "/sys/class/leds"
    property string python: "python3"

    signal request(var req)

    readonly property int raw: level.raw
    readonly property int max: level.max
    // A write of ours is running or waiting (the file is behind the target then).
    readonly property bool pending: level.pending

    // Read the device now (a read only; adjust() does it itself).
    function refresh() {
        level.read();
    }

    function simulateSet(raw, max) {
        level.seed(raw, max);
    }
    // One line of the helper's output: the Fn key set the LED to `raw`.
    function simulateHw(raw) {
        root._onHardware(String(raw));
    }

    function adjust(dir) {
        level.read();
        if (!level.known)
            return false;
        const v = Math.max(0, Math.min(level.max, level.raw + (dir < 0 ? -1 : 1)));
        level.write(v);
        root._emit(v, "key");
        return true;
    }

    function _onHardware(line) {
        const v = parseInt(String(line).trim());
        if (!isFinite(v) || v < 0)
            return;
        // The helper's number is the LED's; the maximum comes from the device.
        level.read();
        const mx = level.known ? level.max : 3;
        const c = Math.min(v, mx);
        level.seed(c, mx);
        root._emit(c, "external");
    }

    function _emit(v, source) {
        root.request({
            kind: "kbd",
            key: "kbd",
            source: source,
            stop: v,
            stops: level.max + 1
        });
    }

    SysfsLevel {
        id: level
        live: root.live
        device: root.device
        sysfsRoot: root.ledRoot
    }

    SupervisedStream {
        id: watcher
        enabled: root.live && root.device !== ""
        what: "OSD: the keyboard light's Fn-key watcher"
        command: ["setpriv", "--pdeathsig", "TERM", "--", root.python, root.helperPath,
                  root.ledRoot + "/" + root.device + "/brightness_hw_changed"]
        onLine: text => root._onHardware(text)
    }
}
