pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// SysfsLevel.qml -- one brightnessctl-managed device: read its raw value and
// maximum from sysfs when asked, write a new raw value through brightnessctl.
// What BacklightSource and KbdLightSource share.
//
//   read()      refresh raw / max from sysfs (skipped while a write of ours is
//               still on its way: the file is behind the target then)
//   write(v)    set raw to v at once and send it; writes are SERIALISED -- one
//               brightnessctl at a time, the latest target wins -- so a held
//               key's 25 Hz is a handful of processes and not a pile
//   pending     a write is running or waiting
//
// `brightnessctl -d <device> set N` is unprivileged: logind does the write.
//
// The two sysfs files sit behind Loaders: a FileView takes its path once and is
// never repointed (CLAUDE.md), so a changed `device` builds new ones.
//
// THE READ IS `blockAllReads`, NOT `blockLoading` (CLAUDE.md, "FileView.reload() then
// text()"): with blockLoading alone `reload()` followed at once by `text()` hands back
// the PREVIOUS load, so every press would step from the value the file held one press ago --
// a press that does nothing (the same step again), a double step, or a step the wrong
// way once the file has moved behind the shell's back (hypridle's dim and restore, the
// Fn key).
//
// `live: false` touches nothing: raw / max are whatever `seed()` said and
// write() only moves raw.
// =============================================================================
Item {
    id: root

    property bool live: true
    property string device: ""
    property string sysfsRoot: "/sys/class/backlight"
    property string brightnessctl: "brightnessctl"

    readonly property int raw: root._raw
    readonly property int max: root._max
    readonly property bool pending: writer.running || root._wanted >= 0

    property int _raw: 0
    property int _max: 1
    property int _wanted: -1
    // True once a real read gave a maximum (or seed() set one).
    property bool known: false

    function seed(raw, max) {
        root._raw = raw;
        root._max = Math.max(1, max);
        root.known = true;
    }

    function read() {
        if (!root.live || root.pending)
            return;
        const cur = root._curView, mx = root._maxView;
        if (!cur || !mx)
            return;
        cur.reload();
        mx.reload();
        const c = parseInt(String(cur.text()).trim());
        const m = parseInt(String(mx.text()).trim());
        if (isFinite(m) && m > 0) {
            root._max = m;
            root.known = true;
        }
        if (isFinite(c))
            root._raw = c;
    }

    function write(v) {
        root._raw = v;
        if (!root.live)
            return;
        root._wanted = v;
        root._flush();
    }

    function _flush() {
        if (writer.running || root._wanted < 0)
            return;
        const v = root._wanted;
        root._wanted = -1;
        writer.command = [root.brightnessctl, "-q", "-d", root.device, "set", String(v)];
        writer.running = true;
    }

    Process {
        id: writer
        running: false
        onRunningChanged: if (!writer.running) root._flush()
    }

    Loader {
        id: curFile
        active: root.live && root.device.length > 0
        sourceComponent: FileView {
            path: root.sysfsRoot + "/" + root.device + "/brightness"
            blockAllReads: true
            printErrors: false
        }
    }
    Loader {
        id: maxFile
        active: root.live && root.device.length > 0
        sourceComponent: FileView {
            path: root.sysfsRoot + "/" + root.device + "/max_brightness"
            blockAllReads: true
            printErrors: false
        }
    }
    readonly property var _curView: curFile.item
    readonly property var _maxView: maxFile.item

    onDeviceChanged: {
        if (!root.live || !curFile.active)
            return;
        curFile.active = false;
        maxFile.active = false;
        curFile.active = root.device.length > 0;
        maxFile.active = root.device.length > 0;
    }
}
