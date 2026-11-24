pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/aerial/data"
import "modules/aerial/scene"
import "modules/common/theme"
import "modules/aerial/scene/AerialFacts.js" as Facts

// The board ALONE (AerialScene on the mock's facts, no hologram, no popup) for round 3's look at the parts: SCEN (the mock's scenario) FAMILY (0 | 1) SCALE (the render
// scale: 1, 1.35, 2 ...) AIR=1 (airplane: the card up, the screw out) AIRT=<0..1> (the pose held part way) ASK=<a SILK_VARIANTS.rates text> -> $PNG. Offscreen only.
Window {
    id: win
    readonly property real k: Number(Quickshell.env("SCALE") || 1)
    width: Math.ceil(760 * win.k)
    height: Math.ceil(scene.naturalHeight * win.k)
    visible: true
    color: Theme.surface
    Rectangle { anchors.fill: parent; color: Theme.surface }
    AerialMock {
        id: mock
        live: true
        scenario: Quickshell.env("SCEN") || "home"
        drift: 0
        scanPeriodMs: 100000
        settleMs: 150
    }
    readonly property var facts: {
        const dep = mock.serial;
        return { wifi: mock.wifi, bt: mock.bt, wired: mock.wired, hotspot: mock.hotspot, proton: mock.proton, health: mock.health, rates: mock.rates, usage: mock.usage, speed: mock.speed,
                 airplane: Quickshell.env("AIR") === "1" ? { on: true, remembered: { wifi: true, bt: true } } : mock.airplane, config: mock.config, dep: dep };
    }
    AerialScene {
        id: scene
        width: 760
        transformOrigin: Item.TopLeft
        scale: win.k
        family: Number(Quickshell.env("FAMILY") || 0)
        renderScale: win.k
        animate: false
        state: Facts.describe(win.facts, Date.now())
        silkTexts: Quickshell.env("ASK") ? ({ rates: Quickshell.env("ASK") }) : ({})
        // AIRT=<0..1>: the airplane pose held part way (the screw's lift and turn, then the card's tilt), for a sheet of the motion
        Component.onCompleted: {
            if (Quickshell.env("AIRT"))
                scene.airplaneT = Number(Quickshell.env("AIRT"));
        }
    }
    Timer {
        interval: Number(Quickshell.env("GRAB_MS") || 1600)
        running: true
        onTriggered: win.contentItem.grabToImage(r => { if (Quickshell.env("PNG")) r.saveToFile(Quickshell.env("PNG")); Qt.quit(); })
    }
}
