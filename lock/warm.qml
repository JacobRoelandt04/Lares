pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/lockscreen/veil"

// =============================================================================
// lock/warm.qml -- fills the GPU driver's shader cache with every veil's
// shaders, so the first lock with a veil does not stall compiling them (a veil's
// first frame costs 0.5-1.3 s with an empty Mesa cache, 0.06-0.12 s with a warm
// one).
//
//   tools/lockscreen/lares-lock-warm       is the only thing that starts this.
//
// NOT A LOCK. No WlSessionLock, no PAM, no socket: an OFFSCREEN window (the
// script sets QT_QPA_PLATFORM=offscreen and pins Mesa), one LockVeil per
// proposal in turn, each shown at presence > 0 for a few frames (a ShaderEffect
// is not built until it is visible, and its program is compiled by the first
// frame that draws it), then quit. The cache it fills is the caller's own
// ($XDG_CACHE_HOME/mesa_shader_cache), the one the lock reads.
//
// WARM_VEILS="a b" restricts the run to those veils; the default is every
// proposal LockVeil knows. Prints WARM <veil> first=<ms> frames=<n> per veil and
// WARM RESULT PASS|FAIL (FAIL = a veil never drew). Quits from a Timer:
// Qt.quit() from Component.onCompleted does not quit.
// =============================================================================
ShellRoot {
    id: root
    settings.watchFiles: false

    readonly property var wanted: {
        const w = (Quickshell.env("WARM_VEILS") || "").trim();
        return w === "" ? probe.proposals : w.split(/\s+/);
    }
    readonly property int framesPer: 8
    readonly property int minMs: 150
    readonly property int giveUpMs: 15000

    property int index: -1
    property real stepAt: 0
    property int frames: 0
    property real firstMs: -1
    property int failed: 0
    property bool done: false

    // only for its list of proposals
    LockVeil {
        id: probe
        proposal: ""
        visible: false
        width: 0
        height: 0
    }

    function next() {
        root.index++;
        veil.presence = 0;
        veil.proposal = "";
        if (root.index >= root.wanted.length) {
            root.finish();
            return;
        }
        root.frames = 0;
        root.firstMs = -1;
        root.stepAt = Date.now();
        veil.proposal = root.wanted[root.index];
        veil.presence = 0.6;
        giveUp.restart();
    }

    function settle(ok) {
        giveUp.stop();
        const v = root.wanted[root.index];
        console.log("WARM " + v + " first=" + root.firstMs + " frames=" + root.frames + (ok ? "" : " NEVER DREW"));
        if (!ok)
            root.failed++;
        root.next();
    }

    function finish() {
        root.done = true;
        console.log("WARM RESULT " + (root.failed === 0 && root.wanted.length > 0 ? "PASS" : "FAIL"));
        // hide first: Qt writes its pipeline cache when the scene graph is released
        win.visible = false;
        quit.start();
    }

    Window {
        id: win
        width: 1920
        height: 1080
        visible: true
        color: "#9aa0aa"

        onFrameSwapped: {
            if (root.index < 0 || root.done || !veil.item)
                return;
            root.frames++;
            if (root.firstMs < 0)
                root.firstMs = Date.now() - root.stepAt;
            if (root.frames >= root.framesPer && Date.now() - root.stepAt >= root.minMs)
                root.settle(true);
        }

        LockVeil {
            id: veil
            anchors.fill: parent
            proposal: ""
            presence: 0
            popupRect: Qt.rect(660, 60, 600, 420)
            barRect: Qt.rect(0, 0, 1920, 44)
        }
    }

    Timer {
        // let the window come up and render its first empty frames
        interval: 400
        running: true
        onTriggered: root.next()
    }
    Timer {
        id: giveUp
        interval: root.giveUpMs
        onTriggered: root.settle(false)
    }
    Timer {
        id: quit
        interval: 300
        onTriggered: Qt.quit()
    }
}
