pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/common/glyphs"
import "modules/bar/audio/data"
import "modules/shell"

// =============================================================================
// audio_glyph_toggle_probe.qml -- the bar's volume pill on a PRIVATE PipeWire (tools/dev/audio_glyph_toggle_probe.sh): the real
// PipewireService, the real VolumeParity, a null sink and a null source. The right click (a mute toggle) is delivered through the
// pill's own `click()`; after each one the node's `muted` and the pill's glyph pixels are printed (`ATG step ...`, one grab per
// step, saved as step<n>.png, judged by the runner): unmuted wears the ON hue, muted the muted ink, and every toggle flips both.
// =============================================================================
ShellRoot {
    id: root
    PipewireService { id: pw }

    FloatingWindow {
        id: win
        implicitWidth: 200
        implicitHeight: 100
        visible: true
        color: Theme.surface
        Item {
            id: stage
            anchors.fill: parent
            VolumeParity {
                id: pill
                anchors.centerIn: parent
                pipewire: pw
            }
        }

        property int step: 0
        // 0 unmuted at the start, then: mute the speaker, mute the mic, unmute the speaker, unmute the mic
        readonly property var plan: [
            { what: "start", f: () => {} },
            { what: "mute speaker", f: () => pill.click(0, Qt.RightButton) },
            { what: "mute mic", f: () => pill.click(1, Qt.RightButton) },
            { what: "unmute speaker", f: () => pill.click(0, Qt.RightButton) },
            { what: "unmute mic", f: () => pill.click(1, Qt.RightButton) }
        ]
        function _next(): void {
            if (win.step >= win.plan.length) {
                console.log("ATG done");
                Qt.quit();
                return;
            }
            const st = win.plan[win.step];
            st.f();
            settle.restart();
        }
        Timer {
            id: settle
            interval: 900
            onTriggered: {
                const o = pill.mapToItem(stage, 0, 0);
                console.log("ATG step", win.step, win.plan[win.step].what, "| sink", pw.defaultSink ? pw.defaultSink.name : null,
                    "muted", pw.defaultSink && pw.defaultSink.audio ? pw.defaultSink.audio.muted : "-",
                    "| source", pw.defaultSource ? pw.defaultSource.name : null, "muted", pw.defaultSource && pw.defaultSource.audio ? pw.defaultSource.audio.muted : "-",
                    "| pill sinkMuted", pill.sinkMuted, "sourceMuted", pill.sourceMuted, "| geom", Math.round(o.x), Math.round(o.y), pill.width, pill.height,
                    "| hues", BarHues.speakerOn, BarHues.micOn, Theme.textMuted);
                stage.grabToImage(function (res) {
                    res.saveToFile(Quickshell.env("OUT_DIR") + "/step" + win.step + ".png");
                    win.step++;
                    win._next();
                });
            }
        }
        Timer {
            interval: 2000; running: true
            onTriggered: win._next()
        }
    }
}
