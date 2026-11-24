pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Quickshell

// The shell's shader packs, compiled by the context this process gets: one ShaderEffect per pack (a .frag with its .vert when
// there is one), all drawn in the first frame, which is where Qt builds every pipeline. tools/dev/shader_compile_probe.sh reads the
// log for the driver's refusals; this file only draws them and says how many. PAIRS: a JSON list of {frag, vert} file URLs.
Window {
    id: win
    width: 1200; height: 800; visible: true; color: "#EAEDF5"
    property var pairs: JSON.parse(Quickshell.env("PAIRS") || "[]")
    Grid {
        columns: 10; spacing: 4
        Repeater {
            model: win.pairs.length
            ShaderEffect {
                id: fx
                required property int index
                width: 110; height: 70
                fragmentShader: win.pairs[fx.index].frag
                vertexShader: win.pairs[fx.index].vert
            }
        }
    }
    // a 0 ms quit does not exist yet at completion (CLAUDE.md): the first frame lands well inside 4 s, offscreen or on Wayland
    Timer { interval: 4000; running: true; onTriggered: { console.log("SHADER_COMPILE drew " + win.pairs.length + " packs"); Qt.quit(); } }
}
