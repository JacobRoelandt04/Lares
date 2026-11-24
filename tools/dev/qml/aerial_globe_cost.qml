pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/aerial/scene"
import "modules/aerial/scene/AerialGeometry.js" as Geo
import "modules/aerial/scene/AerialCamera.js" as Cam
import "modules/common/theme"

// the globe alone (no board; the tunnel is gone: round 3's label chrome replaced it): what tools/dev/aerial_globe_cost.sh times and reads the compiler's counts of. Prints `COST first-frame-ms <n>` (process start to the first presented frame) and `COST frames <n>` over 1.2 s.
Window {
    id: root
    width: 400
    height: 300
    visible: true
    color: Theme.surface
    readonly property var geo: JSON.parse(Geo.json())
    readonly property var fit: Cam.fitNatural(root.geo, 400, { l: 14, r: 14, t: 12, b: 14 })
    readonly property real t0: Date.now()
    readonly property bool bare: Quickshell.env("BARE") === "1"      // the same window without the effect: the cost of everything else
    property int swaps: 0
    property real first: 0
    Connections {
        target: root
        function onFrameSwapped() {
            root.swaps++;
            if (root.first === 0) {
                root.first = Date.now();
                console.log("COST first-frame-ms " + (root.first - root.t0));
                quit.start();
            }
        }
    }
    GlobeLayer {
        visible: !root.bare
        anchors.fill: parent
        cam: ({ s: root.fit.s, ox: root.fit.ox, oy: root.fit.oy })
        geo: root.geo
        catalog: ({ countries: [{ code: "BE", name: "Belgium", lat: 50.85, lon: 4.35, servers: 40, minLoad: 21 }] })
        proton: ({ state: "up", server: { country: "BE" } })
        spinning: false
        interactive: false
    }
    Timer {
        id: quit
        interval: 1200
        onTriggered: {
            console.log("COST frames-after-first " + root.swaps);
            Qt.quit();
        }
    }
}
