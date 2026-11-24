pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

import "../../common/components"
import "../../common/icons"
import "../../common/theme"

// =============================================================================
// Obscurer.qml -- windows the user does not want on show while the session is
// locked are covered on this screen by a carved placeholder.
//
// `obscure` (lockscreen.jsonc) is a list of matchers `{ "class": "<regex>",
// "title": "<regex>" }`; a window is covered when every key that is present
// matches (JS RegExp, `test`, so anchor it yourself; a "(?i)" prefix means
// case-insensitive, which JS has no inline syntax for). Only windows on THIS
// screen's VISIBLE workspace count, and the placeholder sits at the window's
// rectangle, over everything the lock draws of the desktop: it is drawn from
// the first frame, so the live sharp phase, the blur-in and the captured
// frames all carry it (the captures are taken of the output, placeholder
// included -- which is why nothing needs to be "baked" afterwards: the held
// frames and the still already contain it).
//
// The window list comes from `hyprctl -j clients` / `monitors` (a Process:
// the answer is one JSON document, and a refresh is one call). It is asked at
// creation, on every Hyprland event that can change a window's rectangle,
// class, title or workspace, and once a second while `live`.
//
// FAILS CLOSED WHERE CHEAP. A window whose rectangle is unknown covers
// nothing, and there is nothing cheap to cover it with: the honest failure
// mode is that between the lock's first frame and the first answer (tens of
// ms) a listed window is still on show, and that a matcher with a malformed
// regex matches nothing (it is logged). A window that is hidden, unmapped or on
// another workspace is not covered, because it is not shown.
// =============================================================================
Item {
    id: root

    property var screen: null
    // [{ class, title }]; see the header
    property var obscure: []
    // keep polling (the live phases); the still is baked, so a settled lock
    // stops asking
    property bool live: true

    // covered rectangles in this screen's item px: [{ x, y, w, h, cls, title, icon }]
    readonly property var rects: root._rects
    property var _rects: []
    property var _monitor: null
    property var _clients: null
    // A probe reads how many refreshes happened.
    property int refreshes: 0

    function refresh(): void {
        if (root.obscure.length === 0 || !root.screen)
            return;
        if (!monProc.running && !cliProc.running) {
            root.refreshes++;
            monProc.running = true;
        }
    }

    function _matcher(s: string): var {
        let flags = "";
        let src = String(s);
        if (src.startsWith("(?i)")) {
            flags = "i";
            src = src.slice(4);
        }
        try {
            return new RegExp(src, flags);
        } catch (e) {
            console.warn("Obscurer: bad pattern '" + s + "': " + e);
            return null;
        }
    }

    property var _compiled: {
        const out = [];
        for (const o of root.obscure) {
            const m = {};
            let bad = false;
            for (const k of ["class", "title"]) {
                if (o[k] === undefined)
                    continue;
                const r = root._matcher(o[k]);
                if (r === null)
                    bad = true;
                m[k] = r;
            }
            // an entry with no usable key matches nothing
            if (!bad && (m["class"] || m["title"]))
                out.push(m);
        }
        return out;
    }

    function _iconFor(cls: string): string {
        if (cls === "")
            return "";
        const e = DesktopEntries.heuristicLookup(cls);
        if (!e || !e.icon)
            return "";
        const p = AppIcons.checkedPath(e.icon);
        if (!p)
            return "";
        return p.startsWith("/") ? "file://" + p : p;
    }

    function _recompute(): void {
        const mon = root._monitor;
        const clients = root._clients;
        if (!mon || !clients) {
            return;
        }
        const ws = mon.activeWorkspace ? mon.activeWorkspace.id : -1;
        const out = [];
        for (const c of clients) {
            if (c.monitor !== mon.id || !c.mapped || c.hidden)
                continue;
            if (!c.workspace || c.workspace.id !== ws)
                continue;
            let hit = false;
            for (const m of root._compiled) {
                if ((!m["class"] || m["class"].test(c["class"] || "")) && (!m.title || m.title.test(c.title || ""))) {
                    hit = true;
                    break;
                }
            }
            if (!hit)
                continue;
            out.push({
                x: c.at[0] - mon.x,
                y: c.at[1] - mon.y,
                w: c.size[0],
                h: c.size[1],
                cls: c["class"] || "",
                title: c.title || "",
                icon: root._iconFor(c["class"] || "")
            });
        }
        // rebuild only on a real change: a delegate is a ShadowBox
        if (JSON.stringify(out) !== JSON.stringify(root._rects))
            root._rects = out;
    }

    Process {
        id: monProc
        command: ["hyprctl", "-j", "monitors"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    for (const m of JSON.parse(text))
                        if (root.screen && m.name === root.screen.name)
                            root._monitor = m;
                } catch (e) {
                    console.warn("Obscurer: monitors: " + e);
                }
                cliProc.running = true;
            }
        }
    }
    Process {
        id: cliProc
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root._clients = JSON.parse(text);
                    root._recompute();
                } catch (e) {
                    console.warn("Obscurer: clients: " + e);
                }
            }
        }
    }

    Connections {
        target: Hyprland
        function onRawEvent(ev) {
            const n = ev.name;
            if (n === "openwindow" || n === "closewindow" || n === "movewindow" || n === "movewindowv2" || n === "windowtitle" || n === "windowtitlev2" || n === "workspace" || n === "workspacev2" || n === "fullscreen" || n === "changefloatingmode" || n === "activespecial" || n === "focusedmon" || n === "monitoradded" || n === "monitorremoved")
                debounce.restart();
        }
    }
    Timer {
        id: debounce
        interval: 40
        onTriggered: root.refresh()
    }
    Timer {
        interval: 1000
        repeat: true
        running: root.live && root.obscure.length > 0
        onTriggered: root.refresh()
    }
    onScreenChanged: root.refresh()
    Component.onCompleted: root.refresh()

    Repeater {
        model: root._rects
        ShadowBox {
            id: box
            required property var modelData
            x: box.modelData.x
            y: box.modelData.y
            baseWidth: box.modelData.w
            baseHeight: box.modelData.h
            baseRadius: 10
            // carved into whatever the desktop is: no ground colour of its own
            surfaceColor: "transparent"
            backgroundColor: Theme.listBox
            bevelColor: Theme.bevel
            shadowColor: Theme.border
            bevelWidth: 1
            shadowWidth: 3
            Image {
                readonly property real _s: Math.min(96, Math.min(box.baseWidth, box.baseHeight) * 0.4)
                anchors.centerIn: parent
                width: _s
                height: _s
                sourceSize: Qt.size(128, 128)
                source: box.modelData.icon
                visible: false
                fillMode: Image.PreserveAspectFit
                asynchronous: false
                id: icon
            }
            // the app's icon as a faint silhouette: the placeholder says WHAT is
            // covered without saying anything of what it showed
            MultiEffect {
                anchors.fill: icon
                source: icon
                visible: icon.status === Image.Ready
                colorization: 1.0
                colorizationColor: Theme.textFaint
                opacity: 0.35
            }
        }
    }
}
