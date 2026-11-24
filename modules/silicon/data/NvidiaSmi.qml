pragma ComponentBehavior: Bound

import QtQuick
import "SysfsParse.js" as S
import "../../common/system"

// =============================================================================
// NvidiaSmi.qml -- the dGPU's utilisation, temperature, power and memory, from nvidia-smi.
//
// THE RULE THAT SHAPES THIS FILE. Asking wakes the card: one query from D3cold costs 2.1 s and
// keeps the dGPU awake for ~21 s, and polling at ANY period keeps it awake for good (measured).
// So it runs ONLY while the dGPU has a real user (CardwireParse.lsofHolders:
// the processes on ITS OWN nodes, minus the plumbing) and is already awake -- `active` is that
// and nothing else, set by the service, and the service's beat (`poll()`) is the only thing that ever starts the
// process, but for the first query when `active` rises. The moment `active` falls the reading is dropped (null): a stale
// number is worse than a dash. A query still in flight is allowed to finish (it was started while
// the card was in use).
//
//   active        run (true) / do not run (false)
//   poll()        ask once (the service calls it on the stats beat; `active` still decides)
//   command       the binary ("nvidia-smi"; a probe's stub)
//   reading       { util, tempC, watts, vramUsedMB, vramTotalMB } | null
//   failed        the last query did not give a reading (the driver is busy, the binary is not there)
//   read(sample)  every reading
//
// A query that does not answer within 5 s is killed. `stdin` is closed.
// =============================================================================
Item {
    id: root

    property bool active: false
    property string command: "nvidia-smi"

    readonly property var reading: root._reading
    readonly property bool failed: root._failed
    signal read(var sample)

    // ---- Private ---------------------------------------------------------------
    property var _reading: null
    property bool _failed: false

    onActiveChanged: {
        if (!root.active) {
            if (root._reading !== null)
                root._reading = null;
            root._failed = false;
        } else {
            root.poll();
        }
    }

    function poll() {
        // The second guard: nothing starts a query for a card nobody is using.
        if (!root.active || lane.busy)
            return;
        lane.run([root.command, "--query-gpu=" + S.NVIDIA_SMI_FIELDS, "--format=csv,noheader,nounits"], function (res) {
            if (!root.active)
                return;
            const s = res.code === 0 && !res.timedOut ? S.parseNvidiaSmi(res.out) : null;
            root._failed = s === null;
            root._reading = s;
            if (s !== null)
                root.read(s);
        });
    }

    ProcLane { id: lane; timeoutMs: 5000 }
}
