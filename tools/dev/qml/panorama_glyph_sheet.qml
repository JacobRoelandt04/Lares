pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/panorama/bar"

// =============================================================================
// panorama_glyph_sheet.qml -- the panorama button alone, in each state it shows, one PNG per state (a light harness beside the
// big bar_glyphs_sheet: that one takes minutes). OUT_DIR required; SCALE (default 1) is the item scale of the stage (device pixels per
// glyph pixel, so 1.25 shows the antialiasing a 1.25 output gives); prints `PANO_SHEET cell <name>` and `PANO_SHEET RESULT PASS|FAIL`.
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 400
        implicitHeight: 80
        visible: true
        color: Theme.surface
        readonly property string outDir: Quickshell.env("OUT_DIR") || ""
        readonly property real sc: Number(Quickshell.env("SCALE") || 1)

        Item {
            id: stage
            width: 48
            height: 48
            scale: win.sc
            transformOrigin: Item.TopLeft
            Rectangle {
                anchors.fill: parent
                color: Theme.surface
            }
            PanoramaBarButton {
                id: btn
                anchors.centerIn: parent
                flourishEnabled: false
            }
        }

        readonly property var steps: [
            { n: "1", p: 1, m: false }, { n: "2", p: 2, m: false }, { n: "3", p: 3, m: false }, { n: "4", p: 4, m: false },
            { n: "1m", p: 1, m: true }, { n: "2m", p: 2, m: true }, { n: "3m", p: 3, m: true }, { n: "4m", p: 4, m: true }
        ]
        property int _i: -1
        property int _n: 0
        function next(): void {
            win._i++;
            if (win._i >= win.steps.length) {
                console.log("PANO_SHEET RESULT " + (win._n === win.steps.length ? "PASS" : "FAIL"));
                quit.start();
                return;
            }
            btn.panes = win.steps[win._i].p;
            btn.mirroring = win.steps[win._i].m;
            wait.restart();
        }
        Timer {
            id: wait
            interval: 900
            onTriggered: {
                const nm = win.steps[win._i].n;
                stage.grabToImage(r => {
                    r.saveToFile(win.outDir + "/pano_" + nm + ".png");
                    win._n++;
                    console.log("PANO_SHEET cell " + nm);
                    win.next();
                }, Qt.size(48 * win.sc, 48 * win.sc));
            }
        }
        Timer {
            id: quit
            interval: 50
            onTriggered: Qt.quit()
        }
        Timer {
            running: true
            interval: 600
            onTriggered: win.next()
        }
    }
}
