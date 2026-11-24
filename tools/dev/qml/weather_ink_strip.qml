pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/common/glyphs"
import "modules/common/components"

// =============================================================================
// weather_ink_strip.qml -- the ink weather icons' flourishes frame by frame, on a held clock: one row per icon, the icon at
// rest in the first column and then FRAMES poses from the first beat of its flourish to the last (WeatherGlyph `posing` /
// `poseBeat`), as ONE picture. Runner and judge: tools/dev/weather_ink_probe.sh (its strip pass).
//
//   OUT_DIR   where strip.png goes -- required; with none (a bare smoke) it loads and quits
//   FRAMES    poses per row (default 16)
//   SIZE      the glyph's size (default 48); each stands in a slot PAD px larger on every side, which must stay empty
//   COMMON    a number of beats: every row on ONE clock from 0 to that many beats (an icon whose flourish is over stands at
//             rest), for a film of them side by side; without it each row covers its own flourish
//
// Prints `INK_STRIP geometry <slot> <pad> <size> <frames>`, `INK_STRIP row <name> <index> <beats>` and
// `INK_STRIP RESULT PASS`.
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        readonly property string outDir: Quickshell.env("OUT_DIR") || ""
        readonly property int frames: Number(Quickshell.env("FRAMES") || 16)
        readonly property int size: Number(Quickshell.env("SIZE") || 48)
        readonly property int pad: 8
        readonly property real common: Number(Quickshell.env("COMMON") || 0)
        readonly property int slot: win.size + 2 * win.pad

        // [name, kind, intensity, night, shower]
        readonly property var rows: {
            const out = [
                ["clear_day", "clear", 1, false, false], ["clear_night", "clear", 1, true, false],
                ["partly_day", "partly", 1, false, false], ["partly_night", "partly", 1, true, false],
                ["cloudy", "cloudy", 1, false, false], ["cloud", "no-such-kind", 1, false, false],
                ["fog", "fog", 1, false, false], ["wind", "wind", 1, false, false]
            ];
            for (const k of ["rain", "sleet", "snow", "hail", "thunder"]) {
                for (let n = 0; n < 3; ++n)
                    out.push([k + n, k, n, false, false]);
                out.push([k + "1_shower", k, 1, false, true]);
                out.push([k + "1_shower_night", k, 1, true, true]);
            }
            // [.., moonPhase, direction]: the two icons that move as whole items
            out.push(["moon", "moon", 1, true, false, 0.3, null]);
            out.push(["arrow", "arrow", 1, false, false, 0.5, 60]);
            out.push(["arrow_none", "arrow", 1, false, false, 0.5, null]);
            return out;
        }

        implicitWidth: (win.frames + 1) * win.slot
        implicitHeight: win.rows.length * win.slot
        visible: true
        color: Theme.surface

        Rectangle {
            id: stage
            anchors.fill: parent
            color: Theme.surface

            Repeater {
                id: rowsRep
                model: win.rows.length
                Item {
                    id: row
                    required property int index
                    readonly property var spec: win.rows[row.index]
                    readonly property real beats: first.flourishBeats
                    y: row.index * win.slot
                    width: stage.width
                    height: win.slot
                    WeatherGlyph {
                        id: first
                        x: win.pad
                        y: win.pad
                        size: win.size
                        kind: row.spec[1]
                        intensity: row.spec[2]
                        night: row.spec[3]
                        shower: row.spec[4]
                        moonPhase: row.spec.length > 5 ? row.spec[5] : 0.5
                        direction: row.spec.length > 6 ? row.spec[6] : null
                    }
                    Repeater {
                        model: win.frames
                        WeatherGlyph {
                            id: g
                            required property int index
                            x: (g.index + 1) * win.slot + win.pad
                            y: win.pad
                            size: win.size
                            kind: row.spec[1]
                            intensity: row.spec[2]
                            night: row.spec[3]
                            shower: row.spec[4]
                            moonPhase: row.spec.length > 5 ? row.spec[5] : 0.5
                            direction: row.spec.length > 6 ? row.spec[6] : null
                            posing: true
                            poseBeat: (win.common > 0 ? Math.min(g.flourishBeats, win.common * g.index / Math.max(1, win.frames - 1))
                                                      : g.flourishBeats * g.index / Math.max(1, win.frames - 1))
                        }
                    }
                }
            }
        }

        Timer {
            id: settle
            interval: 500
            onTriggered: stage.grabToImage(r => {
                r.saveToFile(win.outDir + "/strip.png");
                console.log("INK_STRIP RESULT PASS");
                Qt.quit();
            })
        }
        Timer {
            interval: 0
            running: true
            onTriggered: {
                if (win.outDir === "") {
                    Qt.quit();
                    return;
                }
                WeatherGlyphSet.set = "ink";
                console.log("INK_STRIP geometry " + win.slot + " " + win.pad + " " + win.size + " " + win.frames);
                for (let i = 0; i < rowsRep.count; ++i) {
                    const beats = rowsRep.itemAt(i).beats; // qmllint disable missing-property
                    console.log("INK_STRIP row " + win.rows[i][0] + " " + i + " " + beats.toFixed(3));
                }
                settle.restart();
            }
        }
    }
}
