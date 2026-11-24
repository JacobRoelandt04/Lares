pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "SysfsParse.js" as S
import "CardwireParse.js" as CW

// =============================================================================
// SysfsPoller.qml -- every /proc and /sys file silicon reads, read the way this shell reads
// sysfs: a FileView per path (static, created once, never repointed), `reload()` and `text()`
// -- a read(), not a fork (a `cat` per poll would be ~115,000 processes a day
// for a file that barely moves). Two groups, each read when its owner calls `pollStats()` /
// `pollBattery()` -- the service does, on its ReadingBeat; the poller keeps no timer of its own:
//
//   STATS    /proc/stat -> load (total and per core, the SCENE's 16 cores), cpufreq
//            policyN/scaling_cur_freq -> clock, the coretemp hwmon's temp1_input -> package
//            temperature, the i915 rc6 residency -> the iGPU's busy share, the dGPU's PCI
//            power_state -> its D-state, /proc/meminfo -> the memory.
//            `statsRead({ clockMHz, loadPct, tempC, cores, igpuBusy, dState, memory })`.
//   BATTERY  the battery's uevent (the maths is PowerMath's), the charge limit, the mains flag.
//            `batteryRead({ uevent, ac, limitPct })`.
//   KNOBS    with every battery poll: the kernel's own copies of what the helper sets -- the platform profile,
//            policy0's EPP and governor, intel_pstate's no_turbo and max_perf_pct. `knobsRead(key)`, one string.
//            These are values the kernel keeps (no firmware call, ~0.15 ms a read), so an
//            outside change (an Fn key, another tool) is seen within a battery poll WITHOUT asking the helper,
//            whose status re-reads the GPU MUX through the ASUS firmware (an ACPI call into the embedded controller).
//
// WHERE: the paths the HELPER's status names (`paths`: battery, ac, coretemp, rc6, cpufreq,
// dgpu.powerState) -- a path it does not report is a hidden feature, never an error. Only the
// battery and the mains have a default (`defaults`) so the battery strip works with no helper.
// The CPU's topology (which CPU is a P, E or LPE core, who shares a core) is read once from the
// directories around `paths.cpufreq` (cpuN/topology, cpuN/cache/index3/shared_cpu_list, devices/cpu_core and
// cpu_atom). `procRoot` is /proc, or a probe's fake one.
//
// A first stats poll has no earlier /proc/stat to difference against, so it seeds and asks
// again after 250 ms; and whenever polling stops (the popup closed) the memory is dropped, so
// the first sample after a reopening is not an average over minutes.
// =============================================================================
Item {
    id: root

    property var paths: ({})
    property var defaults: ({ battery: "/sys/class/power_supply/BAT0", ac: "/sys/class/power_supply/AC0" })
    property string procRoot: "/proc"
    property bool statsActive: false      // the stats are being polled (by the service's beat): false drops the memory that differences need

    signal statsRead(var sample)
    signal batteryRead(var sample)
    signal knobsRead(string key)

    function pollStats() {
        const now = Date.now();
        const out = { clockMHz: null, loadPct: null, tempC: null, cores: [], igpuBusy: null, dState: "", memory: null };
        const p = root.paths || {};

        const stat = S.parseProcStat(root.read(root.procRoot + "/stat"));
        if (root._prevStat !== null) {
            const loads = S.cpuLoads(root._prevStat, stat);
            Object.keys(loads).forEach(function (k) { root._loads[k] = loads[k]; });
            const t = S.totalLoad(root._prevStat, stat);
            if (t !== null)
                out.loadPct = Math.round(t * 1000) / 10;
        } else {
            quick.restart();
        }
        root._prevStat = stat;
        out.cores = S.coreLoads(root._groups, root._loads);

        if (typeof p.cpufreq === "string" && p.cpufreq !== "") {
            const khz = [];
            for (let i = 0; i < root._cpuIds.length; i++)
                khz.push(S.toInt(root.read(p.cpufreq + "/policy" + root._cpuIds[i] + "/scaling_cur_freq"), 0));
            out.clockMHz = S.meanFreqMHz(khz);
        }
        if (typeof p.coretemp === "string" && p.coretemp !== "") {
            const t = S.toInt(root.read(p.coretemp + "/temp1_input"), null);
            out.tempC = t === null ? null : Math.round(t / 100) / 10;
        }
        if (typeof p.rc6 === "string" && p.rc6 !== "") {
            const ms = S.toInt(root.read(p.rc6), null);
            if (ms !== null) {
                if (root._prevRc6 !== null)
                    out.igpuBusy = S.rc6Busy(root._prevRc6, ms, now - root._prevRc6At);
                root._prevRc6 = ms;
                root._prevRc6At = now;
            }
        }
        if (p.dgpu && typeof p.dgpu.powerState === "string" && p.dgpu.powerState !== "")
            out.dState = CW.powerStateName(root.read(p.dgpu.powerState));
        out.memory = S.parseMeminfo(root.read(root.procRoot + "/meminfo"));
        root.statsRead(out);
    }

    function pollBattery() {
        const b = root.paths && root.paths.battery ? root.paths.battery : root.defaults.battery;
        const a = root.paths && root.paths.ac ? root.paths.ac : root.defaults.ac;
        const ac = root.read(a + "/online").trim();
        root.batteryRead({
            uevent: root.read(b + "/uevent"),
            ac: ac === "1" ? true : (ac === "0" ? false : null),
            limitPct: S.toInt(root.read(b + "/charge_control_end_threshold"), null)
        });
        root.pollKnobs();
    }

    // FanGuard's reading, taken by FanGuard on the beat (the stats' own memory is not touched, and nothing is emitted): the package
    // temperature and the LOAD INDEX, the share of the machine's full speed the cores are doing -- the sum over every CPU of its busy
    // share since the last call times its own clock, over the CPU count times policy0's highest clock (a busy core at 400 MHz makes little heat,
    // one at 4.8 GHz a lot). `index` is null on the first call (nothing to difference against); the whole call is null when the
    // helper reported no coretemp. Files only (the kernel's cached values), no fork: two reads and one per busy CPU.
    function guardSample() {
        const p = root.paths || {};
        if (typeof p.coretemp !== "string" || p.coretemp === "" || typeof p.cpufreq !== "string" || p.cpufreq === "" || root._cpuIds.length === 0)
            return null;
        const t = S.toInt(root.read(p.coretemp + "/temp1_input"), null);
        if (t === null)
            return null;
        if (root._guardMaxKhz === 0)
            root._guardMaxKhz = S.toInt(root.read(p.cpufreq + "/policy" + root._cpuIds[0] + "/cpuinfo_max_freq"), 0) || 4000000;
        const stat = S.parseProcStat(root.read(root.procRoot + "/stat"));
        let index = null;
        if (root._guardPrev !== null) {
            const loads = S.cpuLoads(root._guardPrev, stat);
            let sum = 0;
            for (let i = 0; i < root._cpuIds.length; i++) {
                const busy = loads[root._cpuIds[i]];
                if (busy > 0)
                    sum += busy * S.toInt(root.read(p.cpufreq + "/policy" + root._cpuIds[i] + "/scaling_cur_freq"), 0);
            }
            index = Math.round(1000 * sum / (root._cpuIds.length * root._guardMaxKhz)) / 10;
        }
        root._guardPrev = stat;
        return { tempC: Math.round(t / 100) / 10, index: index };
    }

    // The ACPI "Fan" cooling devices' states, e.g. "0 0 0 0": a fact the firmware gives the kernel, which on this laptop reads 0 whatever
    // the fan does, so it is only logged beside a guard's decision and never judged. "" when the sysfs root is unknown.
    function acpiFans() {
        const cf = root.paths && typeof root.paths.cpufreq === "string" ? root.paths.cpufreq : "";
        const tail = "/devices/system/cpu/cpufreq";
        if (!cf.endsWith(tail))
            return "";
        const dir = cf.slice(0, cf.length - tail.length) + "/class/thermal/cooling_device";
        const out = [];
        for (let i = 0; i < 12; i++) {
            if (root.read(dir + i + "/type").trim() === "Fan")
                out.push(root.read(dir + i + "/cur_state").trim());
        }
        return out.join(" ");
    }

    // The sysfs root is the one the helper's status names (paths.cpufreq = <root>/devices/system/cpu/cpufreq), so a
    // probe's fake tree is read and the real machine never is; no status yet, nothing to compare.
    function pollKnobs() {
        const cf = root.paths && typeof root.paths.cpufreq === "string" ? root.paths.cpufreq : "";
        const tail = "/devices/system/cpu/cpufreq";
        if (!cf.endsWith(tail))
            return;
        const sys = cf.slice(0, cf.length - tail.length);
        // the profile twice: the kernel keeps /sys/firmware/acpi/platform_profile as an alias of the class handler's file, and
        // the helper reads and writes the class file when there is one -- a tree where the two are separate files (the
        // probe's) or a kernel without the legacy one still shows an outside change
        const files = [sys + "/firmware/acpi/platform_profile", sys + "/class/platform-profile/platform-profile-0/profile",
                       cf + "/policy0/energy_performance_preference",
                       cf + "/policy0/scaling_governor", sys + "/devices/system/cpu/intel_pstate/no_turbo",
                       sys + "/devices/system/cpu/intel_pstate/max_perf_pct"];
        root.knobsRead(files.map(function (f) { return root.read(f).trim(); }).join("|"));
    }

    // ---- Private ---------------------------------------------------------------
    property var _views: ({})
    property var _prevStat: null
    property var _guardPrev: null         // FanGuard's own /proc/stat memory
    property int _guardMaxKhz: 0
    property var _loads: ({})
    property var _prevRc6: null
    property real _prevRc6At: 0
    property var _groups: []
    property var _cpuIds: []
    property string _topologyFor: ""

    // `blockAllReads`: a FileView's reload() is ASYNCHRONOUS even with `blockLoading` (that one only
    // holds the FIRST load): reload() then text() answers with the PREVIOUS load, a whole poll late
    // (measured: two reloads in a row, both read the content as of the load before them). With
    // `blockAllReads` every reload blocks until it has read, and text() is the file as it is now.
    Component {
        id: viewComp
        FileView { blockLoading: true; blockAllReads: true; printErrors: false; watchChanges: false }
    }

    // One FileView per path, created on first use with its path in the initial properties and never
    // repointed. Public: the overhead meter reads its /proc/<pid> files through the same cache.
    function read(path) {
        if (typeof path !== "string" || path === "")
            return "";
        let v = root._views[path];
        if (!v) {
            v = viewComp.createObject(root, { path: path });
            root._views[path] = v;
        }
        v.reload();
        return v.text();
    }

    onPathsChanged: root._topology()

    function _topology() {
        const cf = root.paths && typeof root.paths.cpufreq === "string" ? root.paths.cpufreq : "";
        if (cf === "" || cf === root._topologyFor)
            return;
        root._topologyFor = cf;
        const cpuDir = cf.replace(/\/cpufreq\/?$/, "");
        const devDir = cpuDir.replace(/\/system\/cpu\/?$/, "");
        const ids = S.cpuList(root.read(cpuDir + "/present"));
        const topo = {
            core: S.cpuList(root.read(devDir + "/cpu_core/cpus")),
            atom: S.cpuList(root.read(devDir + "/cpu_atom/cpus")),
            l3: {},
            siblings: {}
        };
        for (let i = 0; i < ids.length; i++) {
            topo.siblings[ids[i]] = S.cpuList(root.read(cpuDir + "/cpu" + ids[i] + "/topology/thread_siblings_list"));
            topo.l3[ids[i]] = root.read(cpuDir + "/cpu" + ids[i] + "/cache/index3/shared_cpu_list").trim() !== "";
        }
        root._cpuIds = ids;
        root._groups = S.topologyGroups(topo);
    }

    onStatsActiveChanged: {
        if (!root.statsActive) {
            root._prevStat = null;
            root._prevRc6 = null;
            root._loads = ({});
        }
    }

    Timer {
        id: quick
        interval: 250
        onTriggered: {
            if (root.statsActive)
                root.pollStats();
        }
    }
}
