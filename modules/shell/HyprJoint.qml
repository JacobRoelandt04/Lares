pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

import "HyprJoint.js" as Joint

// =============================================================================
// HyprJoint.qml -- the one number the bars' joints and Hyprland's windows share.
//
// The corner of a tiled window is drawn by Hyprland with an outline of radius `decoration:rounding` + `general:border_size`; the joint the bars
// draw for it to sit in is a field fillet whose circle must be that big (HyprJoint.js: the geometry and the measurements). The
// shell asks Hyprland for both numbers -- READ ONLY, `hyprctl -j getoption`, once when it starts and again on every `configreloaded` -- instead
// of carrying a blendRadius of 20 that fits only a Hyprland at 14 and 3. ShellConfig's `jointRounding` / `jointBorder` can name either number, and
// then what Hyprland says for that one is ignored.
//
//   live            true reads the compositor (hyprctl + socket2's configreloaded); false answers the defaults (14 and 3: the joint the shell
//                   is drawn for) and Hyprland is never touched: a mockup, an in-process probe
//   roundingOver, borderOver   ShellConfig's overrides (a number wins; null asks Hyprland)
//   rounding, border   the two numbers (compositor px); `outer` = their sum, the radius of a window's outline (0 with no rounding: a square
//                   corner). The host turns `outer` into the
//                   blendRadius of its frame (HyprJoint.js blendFor: the windows do not grow with the frame's scale, so the joint must not)
//   power           decoration:rounding_power (informational: the joint is a circle, and a power other than 2 is not one)
//   read            Hyprland has answered at least once
// =============================================================================
Item {
    id: root

    property bool live: false
    property var roundingOver: null
    property var borderOver: null

    readonly property real rounding: root._joint.rounding
    readonly property real border: root._joint.border
    readonly property real outer: root._joint.outer
    readonly property real power: root._joint.power
    readonly property bool read: root._joint.read

    // The texts of the three answers; null until Hyprland says (or when it does not: no hyprctl, an option it does not have).
    property var _answers: [null, null, null]
    readonly property var _joint: Joint.read(root._answers[0], root._answers[1], root._answers[2], { rounding: root.roundingOver, border: root.borderOver })
    // Each distinct reading of Hyprland is said ONCE (the first answer, a reload that moved a number): what the probes read the shell's own
    // answer from. It reads `_joint`, not the outputs above: this handler runs BEFORE their bindings have followed it (a signal here would be one step
    // stale).
    property string _said: ""
    on_JointChanged: {
        if (!root.live || !root._joint.read)
            return;
        const line = "rounding " + root._joint.rounding + " border " + root._joint.border + " -> outline " + root._joint.outer + " (compositor px)";
        if (line === root._said)
            return;
        root._said = line;
        console.log("HYPRJOINT " + line);
    }

    readonly property string _mark: "@@HYPRJOINT@@"
    function refresh(): void {
        if (!root.live)
            return;
        if (reader.running) {
            again.restart();
            return;
        }
        reader.running = true;
    }
    function _parse(text: string): void {
        const parts = text.split(root._mark);
        if (parts.length < 3)
            return;
        const a = parts.map(s => s.trim()).map(s => (s === "" ? null : s));
        const old = root._answers;
        if (a[0] === old[0] && a[1] === old[1] && a[2] === old[2])
            return;
        root._answers = [a[0], a[1], a[2]];
    }

    // A reload that arrives while a read is out is read again after it (a burst of reloads is one read, then one more).
    Timer {
        id: again
        interval: 120
        onTriggered: root.refresh()
    }
    Process {
        id: reader
        command: ["sh", "-c", "hyprctl -j getoption decoration:rounding; echo '" + root._mark + "'; hyprctl -j getoption general:border_size; echo '"
                  + root._mark + "'; hyprctl -j getoption decoration:rounding_power"]
        stdout: StdioCollector {
            onStreamFinished: root._parse(this.text)
        }
    }

    // The compositor's config was reloaded: the numbers may have changed. Only when live, and the first read starts once the line is connected.
    LazyLoader {
        active: root.live
        component: Scope {
            Connections {
                target: Hyprland
                function onRawEvent(ev) {
                    if (ev.name === "configreloaded")
                        again.restart();
                }
            }
            Component.onCompleted: root.refresh()
        }
    }
}
