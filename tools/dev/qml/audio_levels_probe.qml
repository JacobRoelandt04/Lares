pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/bar/audio"

// =============================================================================
// audio_levels_probe.qml -- the bar's speaker at each volume: which glyph the table gives (checked here) and the pill at 4x, one PNG
// per level (tools/dev/audio_levels_probe.sh measures where the speaker's body stands in each). The speaker steps to one wave at the
// first sound (anything the figure does not read as 0 %), to two above half, and its body never moves.
//
//   OUT_DIR   where the PNGs go -- required (otherwise the glyph checks alone)
//   SCALE     the grab's scale (default 4)
// Prints `AUDIOLV level <v> glyph <hex> waves <n>` per level and AUDIOLV RESULT PASS|FAIL (the glyph table; the runner adds the body's x).
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 260
        implicitHeight: 140
        visible: true
        color: Theme.surface

        readonly property string outDir: Quickshell.env("OUT_DIR") || ""
        readonly property real zoom: Math.max(1, Number(Quickshell.env("SCALE") || 4))
        // volume, waves wanted
        readonly property var plan: [[0, 0], [0.004, 0], [0.005, 1], [0.01, 1], [0.33, 1], [0.34, 1], [0.5, 1], [0.51, 2], [1.0, 2], [1.5, 2]]
        property int at: 0
        property int fails: 0

        // the pill DRAWN at `zoom` (a scaled item, so the text is rastered at that size: a grab's own upscale would be soft)
        Item {
            id: frame
            x: 10
            y: 10
            width: pill.width * win.zoom
            height: pill.height * win.zoom
            AudioBarButton {
                id: pill
                scale: win.zoom
                transformOrigin: Item.TopLeft
                outputVolume: win.plan[Math.min(win.at, win.plan.length - 1)][0]
                inputVolume: 0.5
            }
        }

        readonly property var codeOf: ({ "\u{F057F}": 0, "\u{F0580}": 1, "\u{F057E}": 2 })

        Timer {
            id: stepTimer
            interval: 80
            running: true
            onTriggered: {
                const v = win.plan[win.at][0];
                const want = win.plan[win.at][1];
                const g = pill.glyphs.outputGlyph("speaker", v, false);
                const waves = win.codeOf[g];
                const hex = g.codePointAt(0).toString(16).toUpperCase();
                console.log("AUDIOLV level " + v + " glyph " + hex + " waves " + waves);
                if (waves !== want)
                    console.log("AUDIOLV FAIL level " + v + " shows " + waves + " waves, wanted " + want);
                if (waves !== want)
                    win.fails += 1;
                if (win.outDir === "") {
                    win.next();
                    return;
                }
                const ok = frame.grabToImage(r => {
                    if (!r.saveToFile(win.outDir + "/level_" + win.at + ".png"))
                        win.fails += 1;
                    win.next();
                });
                if (!ok) {
                    win.fails += 1;
                    win.next();
                }
            }
        }
        function next(): void {
            win.at += 1;
            if (win.at >= win.plan.length) {
                console.log("AUDIOLV RESULT " + (win.fails === 0 ? "PASS" : "FAIL") + " (" + win.plan.length + " levels, " + win.fails + " failed)");
                quitTimer.start();
                return;
            }
            stepTimer.start();
        }
        Timer {
            id: quitTimer
            interval: 50
            onTriggered: Qt.quit()
        }
    }
}
