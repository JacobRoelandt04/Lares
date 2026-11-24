pragma ComponentBehavior: Bound

import QtQuick
import "../../common/components"
import "../../common/system"

// =============================================================================
// PowerEventWatcher.qml -- the kernel's word that the mains or the pack changed.
//
//   changed()     a power_supply udev event, debounced: the charger was plugged or pulled, the pack's status moved
//   watching      the udev monitor is running; `why` says why it is not ("" while it is, or nothing was asked yet)
//   events        how many events were heard (a probe's counter; a burst counts every line)
//
// WHY. The reading beat alone reads the battery -- every 6 s with the popup closed (`idle.batteryHaltedMs`) --
// so a charger plugged in would show on the bar after whatever was left of that period, and the status the kernel
// reports follows the plug by a second or two on top; the glyph should update as soon as the charger goes in. The kernel already says when it happens: ACPI notifies the battery and the adapter,
// the power_supply class emits a `change` uevent for each, and udev forwards it. The EC is not polled faster for
// it (the EC rule, CLAUDE.md: ask the firmware when the thing moves or the user acts): one read per EVENT, at most
// one per `minGapMs` (the service's rate rule), and nothing at all while nothing moves.
//
// HOW. ONE long-lived `udevadm monitor --udev --subsystem-match=power_supply` under `setpriv --pdeathsig TERM`
// (SupervisedStream: restarted with a back-off, one warning per failing streak), the way DrmWatch watches the
// connectors. A burst of events is one `changed()` (`debounceMs`). udevadm and setpriv are looked for with `command -v`
// before the monitor starts: a Process whose program does not exist reports neither a start nor an exit and warns in
// the log. Without them nothing is watched, `why` says so, and the beat alone reads the battery.
// =============================================================================
Item {
    id: root

    property string udevadm: "udevadm"
    property int debounceMs: 120
    property int timeoutMs: 4000

    readonly property bool watching: root._watching
    readonly property string why: root._why
    readonly property int events: root._events

    signal changed

    property bool _checked: false
    property bool _have: false
    property bool _watching: root.enabled && root._have && stream.running
    property string _why: ""
    property int _events: 0

    ProcLane { id: lane; timeoutMs: root.timeoutMs }

    function _probe() {
        if (root._checked)
            return;
        root._checked = true;
        lane.run(["sh", "-c", "command -v \"$1\" > /dev/null 2>&1 && command -v setpriv > /dev/null 2>&1", "sh", root.udevadm], function (res) {
            root._have = res.code === 0;
            root._why = root._have ? "" : "udevadm or setpriv is not installed (" + root.udevadm + "): the battery is read on the beat only";
        });
    }
    onEnabledChanged: if (root.enabled) root._probe()
    Component.onCompleted: if (root.enabled) root._probe()

    SupervisedStream {
        id: stream
        enabled: root.enabled && root._have
        what: "PowerEventWatcher: the udev monitor"
        command: ["setpriv", "--pdeathsig", "TERM", "--", root.udevadm, "monitor", "--udev", "--subsystem-match=power_supply"]
        // Only an event line counts, not the monitor's header ("monitor will print the received events for: ...").
        onLine: text => {
            if (/^UDEV\s+\[[^\]]*\]\s+(add|remove|change|bind|unbind)\s/.test(text)) {
                root._events++;
                debounce.restart();
            }
        }
    }

    Timer { id: debounce; interval: root.debounceMs; onTriggered: root.changed() }
}
