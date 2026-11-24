pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/osd"
import "modules/osd/data"

// =============================================================================
// osd_pill_live_probe.qml -- the pill's REAL window on a real compositor (tools/dev/osd_hide_probe.sh LIVE=1 runs it in
// tools/dev/lock_env.sh): OsdPillWindow (a PanelWindow -- so the smoke runs it in the nested env, gate smoke_panelwindow -- a layer surface on Overlay, its input region the frame's zones) over a window that
// counts the presses that reach it, driven by the OSD's owner as over a fullscreen window (the service live: false, an engine
// stand-in with no bar: the pill is the only surface). The runner moves and clicks the env's virtual pointer.
//
// Prints `OHL out <hide zone> <window>` when the caption is out (zone x y w h, window x y w h on the layout), `OHL hidden`,
// `OHL parked <ball zone>` when the ball has risen, `OHL revealed`, `OHL under <x> <y>` for every press the window below
// gets, and `OHL ready`.
// =============================================================================
ShellRoot {
    id: root

    OsdService {
        id: svc
        live: false
    }
    OsdStyle {
        id: ostyle
    }
    // what the owner reads of an engine when only the pill is out
    QtObject {
        id: noEngine
        property var barsList: []
        property string osdPhase: "closed"
    }
    OsdOwner {
        id: owner
        engine: noEngine
        service: svc
        style: ostyle
        pill: pillWin.pill
        fullscreen: true
        onHiddenChanged: console.log(owner.hidden ? "OHL hidden" : "OHL revealed")
    }

    // the window below: a press that goes through the pill's window lands here
    FloatingWindow {
        id: under
        visible: true
        color: "#203040"
        MouseArea {
            anchors.fill: parent
            onPressed: mouse => console.log("OHL under " + Math.round(mouse.x) + " " + Math.round(mouse.y))
        }
    }
    OsdPillWindow {
        id: pillWin
        screen: Quickshell.screens[0]
        style: ostyle
    }

    function caption(): var {
        return { kind: "caption", key: "dictation", source: "dictation", ms: 600000,
                 caption: { mode: "source", head: "Transcribing Zen", lines: ["The town was built on the old trade road."], live: "and the bridge", hint: "" } };
    }
    function rectOf(it: Item): string {
        return Math.round(it.x) + " " + Math.round(it.y) + " " + Math.round(it.width) + " " + Math.round(it.height);
    }
    property bool saidOut: false
    property bool saidParked: false
    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            const q = pillWin.pill;
            if (!root.saidOut && q.showing && q.pillT >= 2 && q.contentOpacity >= 1 && !q.moving && pillWin.width > 0) {
                root.saidOut = true;
                console.log("OHL out " + root.rectOf(pillWin.hideZone) + " window " + Math.round((Quickshell.screens[0].width - pillWin.width) / 2) + " 0 "
                            + pillWin.width + " " + pillWin.height);
            }
            if (!root.saidParked && q.ballParked) {
                root.saidParked = true;
                console.log("OHL parked " + root.rectOf(pillWin.ballZone));
            }
            if (root.saidParked && !q.hidden && q.pillT >= 2 && !q.moving)
                root.saidParked = false;
        }
    }
    Timer {
        interval: 1500
        running: true
        onTriggered: {
            console.log("OHL ready");
            svc.show(root.caption());
        }
    }
}
