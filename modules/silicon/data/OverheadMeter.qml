pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "SysfsParse.js" as S
import "../../common/system"

// =============================================================================
// OverheadMeter.qml -- what this popup costs the pack, as watts: the shell's own CPU time and
// GPU render time per second, times two coefficients (`wPerCpuSec`, `wPerGpuSec`: config
// `overhead.*`, uncalibrated seeds until tools/silicon/calibrate_overhead.sh measures them). The battery strip subtracts it
// from the discharge (and adds it back to the charge) so the number shown is the machine's, not
// the machine plus the act of looking at it; hovering shows the real one.
//
//   CPU  /proc/self/stat utime + stime (clock ticks) -- `/proc/self` is the shell, read by the
//        shell, so no pid and no process spawn.
//   GPU  /proc/self/fdinfo/<fd> `drm-engine-render` (ns) of every DRM fd, counted once per
//        client (`drm-client-id`). The fd numbers are not knowable from here (no directory
//        listing in QML), so one `ls -l /proc/<pid>/fd` finds them when the meter starts and
//        every two minutes after; a fork per scan, none per sample.
//
// Runs ONLY while `active` (the popup is open: the overhead is the popup's). Every start drops the
// baselines, so the first sample after a closed period is not an average over it; the figure is
// smoothed with a short exponential average so one busy frame does not read as a draw.
//
//   overheadW   watts, 0 until the second sample
//   (the last interval's CPU / GPU seconds per second stay private: `_cpuSec`, `_gpuSec`)
//   reader      anything with read(path) -> text (the service gives its SysfsPoller: one FileView
//               cache); selfRoot is /proc/self, or a probe's fake one
// =============================================================================
Item {
    id: root

    property bool active: false
    property real wPerCpuSec: 2.0
    property real wPerGpuSec: 5.0
    property var reader: null
    property string selfRoot: "/proc/self"
    property int clockTicks: 100
    property int rescanMs: 120000

    readonly property real overheadW: root._w
    signal sampled(real overheadW)

    // One reading, on the service's beat (every second): the fd list is looked at again every `rescanMs`.
    function poll() {
        if (!root.active)
            return;
        if (Date.now() - root._scannedAt >= root.rescanMs)
            root._scan();
        root.sample();
    }

    function sample() {
        if (!root.active || root.reader === null)
            return;
        const now = Date.now();
        const cpuTicks = root._cpuTicks();
        const gpuNs = root._gpuNs();
        if (root._prevAt > 0 && now > root._prevAt) {
            const dt = (now - root._prevAt) / 1000;
            const cs = cpuTicks !== null && root._prevCpu !== null ? Math.max(0, (cpuTicks - root._prevCpu) / root.clockTicks / dt) : 0;
            const gs = gpuNs !== null && root._prevGpu !== null ? Math.max(0, (gpuNs - root._prevGpu) / 1e9 / dt) : 0;
            const w = cs * root.wPerCpuSec + gs * root.wPerGpuSec;
            root._cpuSec = cs;
            root._gpuSec = gs;
            root._w = root._seeded ? root._w * 0.5 + w * 0.5 : w;
            root._seeded = true;
            root.sampled(root._w);
        }
        root._prevAt = now;
        root._prevCpu = cpuTicks;
        root._prevGpu = gpuNs;
    }

    // ---- Private ---------------------------------------------------------------
    property real _w: 0
    property real _cpuSec: 0
    property real _gpuSec: 0
    property bool _seeded: false
    property real _prevAt: 0
    property var _prevCpu: null
    property var _prevGpu: null
    property var _fds: []
    property real _scannedAt: 0

    // utime + stime: the 14th and 15th fields of /proc/<pid>/stat, counted AFTER the command's
    // closing parenthesis (the command may hold spaces), so indices 11 and 12 of what follows.
    function _cpuTicks() {
        const t = String(root.reader.read(root.selfRoot + "/stat"));
        const at = t.lastIndexOf(")");
        if (at < 0)
            return null;
        const f = t.substring(at + 1).trim().split(/\s+/);
        const u = parseInt(f[11], 10);
        const s = parseInt(f[12], 10);
        return isNaN(u) || isNaN(s) ? null : u + s;
    }

    function _gpuNs() {
        if (root._fds.length === 0)
            return null;
        const seen = {};
        let ns = 0;
        let any = false;
        for (let i = 0; i < root._fds.length; i++) {
            const info = S.parseFdinfo(root.reader.read(root.selfRoot + "/fdinfo/" + root._fds[i]));
            if (info === null)
                continue;
            any = true;
            if (info.clientId >= 0 && seen[info.clientId])
                continue;
            seen[info.clientId] = true;
            ns += info.renderNs;
        }
        return any ? ns : null;
    }

    function _scan() {
        root._scannedAt = Date.now();
        lane.run(["ls", "-l", "/proc/" + Quickshell.processId + "/fd"], function (res) {
            if (res.code !== 0)
                return;
            const fds = [];
            res.out.split("\n").forEach(function (l) {
                const m = /\s(\d+) -> \/dev\/dri\/(?:card|renderD)\d+\s*$/.exec(l);
                if (m)
                    fds.push(m[1]);
            });
            root._fds = fds;
        });
    }

    onActiveChanged: {
        root._prevAt = 0;
        root._prevCpu = null;
        root._prevGpu = null;
        root._seeded = false;
        if (root.active) {
            root._scan();
            root.sample();
        } else {
            root._w = 0;
            root._cpuSec = 0;
            root._gpuSec = 0;
        }
    }


    ProcLane { id: lane; timeoutMs: 5000 }
}
