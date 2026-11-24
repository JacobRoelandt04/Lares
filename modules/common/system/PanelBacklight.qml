pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "PanelBacklightRules.js" as Rules

// =============================================================================
// PanelBacklight.qml -- the shell's ONE answer to "which backlight is the laptop panel's".
//
//   device        its name ("" until found)         max          its maximum raw value (0 until found)
//   ready         a device was found                zeroIsBlack  raw 0 turns the panel black (false: nvidia_0 -- write the lowest
//                                                               value AND draw black over the panel where "dark" is meant)
//   scanned       the machine has been looked at    panelThere   it has a laptop panel (an eDP connector or a backlight); a desktop has not
//
// THE RULE (PanelBacklightRules.js): the backlight of the GPU that DRIVES the eDP -- Hybrid: intel_backlight (never a stray
// nvidia_0), dGPU-only: nvidia_0 -- from /sys/class/drm/card*-eDP-*'s card and its `driver` link; fallback the only backlight there is.
// Every consumer (the OSD's keys, LidDim, SoftIdle, the sleep fade and its guard) takes the device from here; none names one.
//
// READ, NOT WATCHED. The device set is fixed per boot (the MUX applies at boot), but nvidia_0 registers late: a read at the first use,
// again at 2, 5, 15 and 45 s while no device was found, and on every resume (Sleep.watcher). One bash prints the facts, the pure
// rules decide. Created on first use (a QML singleton), so a shell without a consumer reads nothing.
//
// LARES_SYSFS_ROOT (the environment, read once) -- for test runners: the directory that stands for /sys (class/backlight,
// class/drm). `zeroOverrides` ({ "<device>": bool }) is idle.jsonc's `zeroIsBlack`, written by IdleConfig.
// =============================================================================
Singleton {
    id: root

    readonly property string sysRoot: Quickshell.env("LARES_SYSFS_ROOT") || "/sys"
    // idle.jsonc `zeroIsBlack`
    property var zeroOverrides: ({})

    readonly property var decision: Rules.decide(root._info, root.zeroOverrides)
    readonly property string device: root.decision.device
    readonly property int max: root.decision.max
    readonly property bool ready: root.decision.ready
    readonly property bool zeroIsBlack: root.decision.zeroIsBlack
    readonly property bool scanned: root._scanned
    readonly property bool panelThere: root._info.backlights.length > 0 || root._info.edp.length > 0
    // the GPU driver of the eDP connector ("" = unknown)
    readonly property string driver: root.decision.driver
    readonly property string why: root.decision.why

    // does raw 0 turn THIS device's panel black (a device a config names, which may not be the panel's own)
    function zeroBlackOf(name: string): bool {
        return Rules.zeroIsBlack(name, root.zeroOverrides);
    }

    // read again now (a probe, or after the sysfs tree changed)
    function rescan(): void {
        if (!scan.running)
            scan.running = true;
    }

    property var _info: ({ backlights: [], edp: [] })
    property bool _scanned: false
    property int _attempt: 0
    readonly property var _delaysMs: [2000, 3000, 10000, 30000]

    Process {
        id: scan
        command: ["bash", "-c",
            "r=$1\n"
            + "for d in \"$r\"/class/backlight/*/; do\n"
            + "  [ -e \"$d\" ] || continue\n"
            + "  n=${d%/}; n=${n##*/}; t=$(cat \"$d/type\" 2>/dev/null); m=$(cat \"$d/max_brightness\" 2>/dev/null)\n"
            + "  echo \"bl $n ${t:--} ${m:-0}\"\n"
            + "done\n"
            + "for c in \"$r\"/class/drm/card*-eDP-*; do\n"
            + "  [ -e \"$c\" ] || continue\n"
            + "  drv=$(readlink -f \"$c/device/device/driver\" 2>/dev/null); [ -d \"$drv\" ] || drv=$(readlink -f \"$c/device/driver\" 2>/dev/null)\n"
            + "  st=$(cat \"$c/status\" 2>/dev/null)\n"
            + "  [ -d \"$drv\" ] && echo \"edp ${c##*/} ${drv##*/} ${st:--}\" || echo \"edp ${c##*/} - ${st:--}\"\n"
            + "done", "panel-backlight", root.sysRoot]
        stdout: StdioCollector {
            onStreamFinished: {
                root._info = Rules.parseScan(this.text);
                root._scanned = true;
                if (!root.ready && root._attempt < root._delaysMs.length) {
                    retry.interval = root._delaysMs[root._attempt];
                    root._attempt++;
                    retry.restart();
                }
            }
        }
    }
    Timer {
        id: retry
        repeat: false
        onTriggered: root.rescan()
    }
    Connections {
        target: Sleep.watcher
        function onResumed(): void {
            root._attempt = 0;
            root.rescan();
        }
    }
    Component.onCompleted: root.rescan()
}
