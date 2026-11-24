pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.Pipewire

import "modules/common/theme"
import "modules/common/glyphs"
import "modules/shell"

// =============================================================================
// audio_glyph_live_probe.qml -- the bar's speaker / microphone pill (VolumeParity -> AudioBarButton) on the REAL PipeWire
// graph, READ ONLY (tools/dev/audio_glyph_live_probe.sh: SANDBOX_LINK=pipewire; this file binds nodes and reads, it writes nothing).
// Two pills in one window: A on the session's own default sink / source, B on the first UNMUTED device-backed sink and source.
// For each pill: what the node says, and what the pill's glyph PIXELS are (the one furthest from the pill's ground, per half),
// judged against the ON hue and the muted ink. Prints `ALG ...` lines and `ALG RESULT PASS|FAIL`.
// =============================================================================
ShellRoot {
    id: root
    readonly property var nodes: Pipewire.nodes.values
    function _pick(sink: bool, wantMuted: bool): var {
        for (let i = 0; i < root.nodes.length; i++) {
            const n = root.nodes[i];
            if (n && n.audio && !n.isStream && n.isSink === sink && (n.audio.muted === true) === wantMuted)
                return n;
        }
        return null;
    }
    PwObjectTracker { objects: root.nodes.filter(n => n && !n.isStream) }

    QtObject {
        id: standIn
        property var defaultSink: root._pick(true, false)
        property var defaultSource: root._pick(false, false)
    }
    QtObject {
        id: session
        property var defaultSink: Pipewire.defaultAudioSink
        property var defaultSource: Pipewire.defaultAudioSource
    }

    FloatingWindow {
        id: win
        implicitWidth: 400
        implicitHeight: 120
        visible: true
        color: Theme.surface
        Item {
            id: stage
            anchors.fill: parent
        Row {
            anchors.centerIn: parent
            spacing: 40
            VolumeParity { id: pillA; pipewire: session }
            VolumeParity { id: pillB; pipewire: standIn }
        }
        }

        Timer {
            interval: 1800; running: true
            onTriggered: {
                for (const p of [{ n: "A", pill: pillA, pw: session }, { n: "B", pill: pillB, pw: standIn }]) {
                    console.log("ALG pill", p.n, "sink", p.pw.defaultSink ? p.pw.defaultSink.name : null, "muted", p.pw.defaultSink && p.pw.defaultSink.audio ? p.pw.defaultSink.audio.muted : "-",
                        "| source", p.pw.defaultSource ? p.pw.defaultSource.name : null, "muted", p.pw.defaultSource && p.pw.defaultSource.audio ? p.pw.defaultSource.audio.muted : "-",
                        "| sinkMuted", p.pill.sinkMuted, "sourceMuted", p.pill.sourceMuted);
                }
                stage.grabToImage(function (res) {
                    res.saveToFile(Quickshell.env("OUT_DIR") + "/pills.png");
                    // geometry and the colours judged, one line a half: x0 x1 y0 y1 muted(0/1) on-hue ink-hue
                    for (const p of [{ n: "A", pill: pillA }, { n: "B", pill: pillB }]) {
                        const o = p.pill.mapToItem(stage, 0, 0);
                        const w = p.pill.width, h = p.pill.height;
                        console.log("ALG half", p.n, "speaker", Math.round(o.x), Math.round(o.x + w / 2), Math.round(o.y), Math.round(o.y + h), p.pill.sinkMuted ? 1 : 0, BarHues.speakerOn, Theme.textMuted);
                        console.log("ALG half", p.n, "mic", Math.round(o.x + w / 2), Math.round(o.x + w), Math.round(o.y), Math.round(o.y + h), p.pill.sourceMuted ? 1 : 0, BarHues.micOn, Theme.textMuted);
                    }
                    console.log("ALG grabbed");
                    Qt.quit();
                });
            }
        }
    }
}
