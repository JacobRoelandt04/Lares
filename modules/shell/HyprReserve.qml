pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// =============================================================================
// HyprReserve.qml -- what the bars take from the compositor's work area on ONE output, set on the output itself.
//
// A 1 px PanelWindow per edge with an exclusive zone would be an EXPOSED window each, and Qt runs a process's animations from
// vsync only while exactly ONE window is exposed (QSGThreadedRenderLoop::startOrStopAnimationTimer): with more, a system timer of int(1000 / refresh) ms ticks them.
// In the real shell at 120 Hz 6 exposed windows draw 87 frames/s with 38 % of the steps doubled; 1 exposed window draws 120 frames/s
// and none doubled. So the reserve is the output's own:
//
//     hl.monitor({ output = "<name>", reserved_area = { top = T, right = R, bottom = B, left = L } })
//
// Hyprland facts this rests on (Hyprland 0.57, nested, tools/dev/shell_probe.sh): a rule with only `output` and `reserved_area` keeps the mode,
// the scale and the bit depth of the rule in force; `hyprctl -j monitors` reads the same `reserved` as with exclusive zones; it is applied at once, sends no
// socket2 event, and a layer that ignores zones (the bar window, `exclusionMode: Ignore`) stays over the whole output. A reload, config-only too, puts the config's
// rule back and takes the reserve with it: `configreloaded` applies it again. A dead shell leaves the reserve standing until the next start or reload, so
// the way down gives it back.
//
// A RULE IS NOT FREE, AND WHY IS NOT KNOWN. Sent while a window is fullscreen it leaves the bar window with an unanswered frame: a popup rising over the window then takes 1.1 s, through
// a remap, where it takes 50 ms without a rule (`hold` below). Sent at the end of a show, the next frame of the bar window comes about 500 ms later, three
// of three, where per-edge windows leave a gap of about 80 ms (the journal calls it `gui`, which proves nothing with one window exposed: the cause may be the
// compositor's or a rest). So it is sent only when the reserve really changes, which is the bars' toggle, and never for a float.
//
// THE RULE STOPS THE COMPOSITOR FOR HALF A SECOND, AND AT THE SHELL'S START THAT WAS A SECOND OF IT (measured 2026-11-23, nested, warm:
// launch -> ready 2362 ms with the rule, 1388 without). It was sent twice: at the window's build with the values of a frame that knows
// neither its bars nor its scale ({0, 6, 6, 6}), and again with the real ones ({43, 9, 9, 9}) as the first frame was about to show --
// Hyprland answered the client's next sync 460 ms and the next frame callback 490 ms later. So:
//   - nothing is sent before the reserve is final (`hold`: the host holds until its frame is whole);
//   - the FIRST time, the compositor is asked what it has (`hyprctl -j monitors`: `reserved` is [left, top, right, bottom]); a reserve that
//     is in force already is adopted, not sent again;
//   - the rule sent is kept in `cacheFile`, and the next start's stub (shell.qml) sends it at its first line, while the QML loads: the
//     half second is spent beside the load instead of in front of the first frame. What the stub sent is what this then finds in force.
//
//   live     true runs hyprctl; false only records `lastLua` (offscreen, where there is no compositor to tell)
//   output   the connector's name
//   reserve  { top, right, bottom, left }, compositor px, whole (ShellLayout.windowReserve)
//   hold     nothing is sent while true: a rule applied under a fullscreen window takes the frame of a popup rising over it from the compositor (the first frame 1.1 s late,
//            through a remap), and with a window over the whole output there is nothing for a reserve to do
// =============================================================================
Item {
    id: root

    property bool live: false
    property string output: ""
    property var reserve: ({ top: 0, right: 0, bottom: 0, left: 0 })
    property bool hold: false
    // Where the rule in force is kept for the next start's stub ("" keeps none); `adopted` counts the reserves found in force and not sent.
    property string cacheFile: ""
    property int adopted: 0

    // The last Lua sent, how many times, what Hyprland answered: probes read them.
    property string lastLua: ""
    property int sent: 0
    property string lastReply: ""

    function _lua(r: var): string {
        return 'hl.monitor({ output = "' + root.output + '", reserved_area = { top = ' + (r.top || 0) + ', right = ' + (r.right || 0)
            + ', bottom = ' + (r.bottom || 0) + ', left = ' + (r.left || 0) + ' } })';
    }

    property string _inForce: ""
    property bool _busy: false
    property bool _again: false
    property bool _asked: false     // the compositor was asked once what it has (the first sync of this object's life)

    // (One rule for a change of several edges: the bars' release moves them in steps of one turn.)
    onReserveChanged: Qt.callLater(root._sync)
    onHoldChanged: Qt.callLater(root._sync)
    onOutputChanged: Qt.callLater(root._sync)
    Component.onCompleted: root._sync()

    function _sync(): void {
        if (root.output === "" || root.hold)
            return;
        if (root._busy) {
            root._again = true;
            return;
        }
        const lua = root._lua(root.reserve);
        if (lua === root._inForce)
            return;
        if (root.live && !root._asked) {
            root._asked = true;
            root._busy = true;
            asker.running = true;
            return;
        }
        root._send(lua);
    }
    function _send(lua: string): void {
        root._inForce = lua;
        root.lastLua = lua;
        root.sent += 1;
        if (!root.live)
            return;
        root._busy = true;
        runner.command = ["hyprctl", "eval", lua];
        runner.running = true;
        if (root.cacheFile !== "")
            Quickshell.execDetached(["sh", "-c", 'mkdir -p "${1%/*}" && printf "%s\\n" "$2" > "$1.tmp" && mv -f "$1.tmp" "$1"', "sh", root.cacheFile, lua]);
    }
    // What the compositor has for this output: the same four numbers mean nothing is to be sent.
    function _inForceNow(text: string): bool {
        let mons = null;
        try {
            mons = JSON.parse(text);
        } catch (e) {
            return false;
        }
        if (!mons || !(mons.length > 0))
            return false;
        for (let i = 0; i < mons.length; i++) {
            const m = mons[i];
            if (!m || m.name !== root.output || !m.reserved || m.reserved.length !== 4)
                continue;
            const r = root.reserve;
            return m.reserved[0] === (r.left || 0) && m.reserved[1] === (r.top || 0) && m.reserved[2] === (r.right || 0) && m.reserved[3] === (r.bottom || 0);
        }
        return false;
    }
    Process {
        id: asker
        command: ["hyprctl", "-j", "monitors"]
        stdout: StdioCollector {
            id: asked
        }
        onExited: (code, status) => {
            root._busy = false;
            root._again = false;
            if (root.output === "" || root.hold)
                return;     // held meanwhile: the next sync sends (the question is not asked twice)
            const lua = root._lua(root.reserve);
            if (code === 0 && root._inForceNow(asked.text)) {
                root._inForce = lua;
                root.lastLua = lua;
                root.adopted += 1;
                return;
            }
            root._send(lua);
        }
    }

    Process {
        id: runner
        stdout: StdioCollector {
            id: out
        }
        stderr: StdioCollector {
            id: err
        }
        onExited: (code, status) => {
            const text = (out.text + err.text).trim();
            root.lastReply = text;
            if (code !== 0 || /^(error|warning)/i.test(text)) {
                console.warn("HyprReserve: hyprctl eval said: " + text + " (exit " + code + ")");
                root._inForce = "";
            }
            root._busy = false;
            if (root._again) {
                root._again = false;
                root._sync();
            }
        }
    }

    // A reload took the rule back to the config's.
    LazyLoader {
        active: root.live
        component: Scope {
            Connections {
                target: Hyprland
                function onRawEvent(ev) {
                    if (ev.name === "configreloaded") {
                        root._inForce = "";
                        root._sync();
                    } else if (ev.name === "monitoraddedv2" || ev.name === "monitorremovedv2"
                               || (ev.name === "custom" && String(ev.data).indexOf("lares-panorama,") === 0)) {
                        recheck.restart();
                    }
                }
            }
        }
    }

    // A CHANGE OF THE DISPLAYS CAN TAKE THE RESERVE AWAY WITH NO WORD (the user's dock, 2026-11-23: after a mirror was reverted the laptop's
    // windows ran to the screen's edges until a reload; not reproduced with headless outputs, so the cause inside Hyprland is not known).
    // After every plug, unplug and word of the display engine the compositor is asked once more what it has; a reserve still in force
    // costs one read and no rule.
    Timer {
        id: recheck
        interval: 800
        onTriggered: {
            if (root._busy) {
                recheck.restart();
                return;
            }
            root._inForce = "";
            root._asked = false;
            root._sync();
        }
    }

    // The way down: no room is kept for bars that are gone. A detached hyprctl, because this process is going.
    Component.onDestruction: {
        if (root.live && root.output !== "" && root._inForce !== "")
            Quickshell.execDetached(["hyprctl", "eval", root._lua({})]);     // (the cache stays: the next start's stub puts it back at once)
    }
}
