pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/common/glyphs"
import "modules/common/components"

// =============================================================================
// weather_ink_sheet.qml -- every weather condition WeatherGlyph can be asked for, in the set named by SET, at the sizes the
// shell draws them, as ONE picture; then the set is switched live to the other and back, a picture each (the toggle's proof).
// Runner and judge: tools/dev/weather_ink_probe.sh.
//
//   OUT_DIR   where the pictures go (first.png, other.png, back.png) -- required; with none (a bare smoke) it loads and quits
//   SET       "ink" (default) | "carved": the set of first.png and back.png
//   OTHER=1   every glyph with otherMode (the theme's other half, on that half's surface)
//
// Prints `INK_SHEET cell <name> <accent 0|1> <x> <y> <w> <h>` per glyph (the judge's map: `accent` says whether the ink icon
// has a coloured part, written here by hand, not read from the set) and `INK_SHEET RESULT PASS|FAIL`.
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 1180
        implicitHeight: 1500
        visible: true
        color: stage.color

        readonly property string outDir: Quickshell.env("OUT_DIR") || ""
        readonly property string firstSet: Quickshell.env("SET") === "carved" ? "carved" : "ink"
        readonly property bool other: Quickshell.env("OTHER") === "1"
        readonly property var sizes: [14, 18, 24, 32, 48, 88]

        // [name, kind, intensity, night, shower, accent]
        readonly property var rows: {
            const out = [
                ["clear_day", "clear", 1, false, false, 1], ["clear_night", "clear", 1, true, false, 1],
                ["partly_day", "partly", 1, false, false, 1], ["partly_night", "partly", 1, true, false, 1],
                ["cloudy", "cloudy", 1, false, false, 0], ["fog", "fog", 1, false, false, 0],
                ["wind", "wind", 1, false, false, 0], ["unknown", "no-such-kind", 1, false, false, 0]
            ];
            for (const k of ["rain", "sleet", "snow", "hail", "thunder"]) {
                for (let n = 0; n < 3; ++n)
                    out.push([k + n, k, n, false, false, 1]);
                out.push([k + "1_shower", k, 1, false, true, 1]);
                out.push([k + "1_shower_night", k, 1, true, true, 1]);
            }
            for (const p of [0.06, 0.25, 0.4, 0.5, 0.62, 0.75, 0.94])
                out.push(["moon_" + Math.round(p * 100), "moon", 1, true, false, 1, p, null]);
            for (const d of [0, 45, 90, 200])
                out.push(["arrow_" + d, "arrow", 1, false, false, 0, 0.5, d]);
            out.push(["arrow_none", "arrow", 1, false, false, 0, 0.5, null]);
            return out;
        }

        Rectangle {
            id: stage
            anchors.fill: parent
            color: win.other ? Theme.counterpart(Theme.surface.toString(), "surface") : Theme.surface

            Flow {
                id: flow
                anchors.fill: parent
                anchors.margins: 10
                spacing: 6
                Repeater {
                    id: cells
                    model: win.rows.length
                    Row {
                        id: cell
                        required property int index
                        readonly property var row: win.rows[cell.index]
                        spacing: 8
                        height: 92
                        Repeater {
                            model: win.sizes.length
                            Item {
                                id: slot
                                required property int index
                                readonly property real s: win.sizes[slot.index]
                                readonly property string name: cell.row[0] + "@" + slot.s
                                readonly property int accent: cell.row[5]
                                width: slot.s
                                height: 92
                                WeatherGlyph {
                                    y: Math.round((92 - slot.s) / 2)
                                    size: slot.s
                                    kind: cell.row[1]
                                    intensity: cell.row[2]
                                    night: cell.row[3]
                                    shower: cell.row[4]
                                    moonPhase: cell.row.length > 6 ? cell.row[6] : 0.5
                                    direction: cell.row.length > 7 ? cell.row[7] : null
                                    otherMode: win.other
                                }
                            }
                        }
                    }
                }
            }
        }

        property int _step: 0
        readonly property var shots: ["first", "other", "back"]
        function shoot() {
            const name = win.shots[win._step];
            stage.grabToImage(r => {
                r.saveToFile(win.outDir + "/" + name + ".png");
                console.log("INK_SHEET shot " + name + " set " + WeatherGlyphSet.set);
                win._step++;
                if (win._step >= win.shots.length) {
                    console.log("INK_SHEET RESULT PASS");
                    Qt.quit();
                    return;
                }
                WeatherGlyphSet.set = win._step === 1 ? (win.firstSet === "ink" ? "carved" : "ink") : win.firstSet;
                settle.restart();
            });
        }
        Timer {
            id: settle
            interval: 400
            onTriggered: win.shoot()
        }
        Timer {
            interval: 0
            running: true
            onTriggered: {
                if (win.outDir === "") {
                    Qt.quit();
                    return;
                }
                WeatherGlyphSet.set = win.firstSet;
                for (let i = 0; i < cells.count; ++i) {
                    const c = cells.itemAt(i);
                    for (let j = 0; j < c.children.length; ++j) {
                        const it = c.children[j];
                        if (it.name === undefined)
                            continue;
                        const p = it.mapToItem(stage, 0, 0);
                        console.log("INK_SHEET cell " + it.name + " " + it.accent + " " + Math.round(p.x) + " " + Math.round(p.y)
                            + " " + it.width + " " + it.height);
                    }
                }
                settle.restart();
            }
        }
    }
}
