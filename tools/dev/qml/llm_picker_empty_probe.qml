pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell

import "modules/common/theme"
import "modules/bar/llm/components"

// =============================================================================
// llm_picker_empty_probe.qml -- the model picker's empty list SAYS why (commits 0110d6c9, 2cb3bb6f). The REAL LlmModelPicker in a window, no
// service, no ollama; the empty-list Text is read from its properties:
//   busy                        -> "Loading models…"
//   offline (backend said so)   -> "Ollama is not running"
//   online with none            -> "No models installed"
//   with a model                -> none of the three words is drawn (no empty line at all)
// Run by tools/dev/llm_picker_empty_probe.sh; bare it quits at once (no LPE_RUN). One `LPE ok|FAIL <id>: what` line per check, then `LPE DONE PASS|FAIL`.
// =============================================================================
ShellRoot {
    id: probe
    settings.watchFiles: false
    readonly property bool run: Quickshell.env("LPE_RUN") === "1"
    property int checks: 0
    property int fails: 0
    function check(id: string, ok: bool, what: string): void {
        probe.checks++;
        if (!ok)
            probe.fails++;
        console.log("LPE " + (ok ? "ok  " : "FAIL ") + id + ": " + what);
    }
    Timer { interval: 0; running: !probe.run; onTriggered: Qt.quit() }

    Window {
        id: win
        visible: probe.run
        width: 520
        height: 420
        color: Theme.surface
        LlmModelPicker {
            id: picker
            x: 20
            y: 20
            width: 360
            open: true
            models: []
            busy: false
            offline: false
        }
    }

    readonly property var words: ["Loading models…", "Ollama is not running", "No models installed"]
    // the visible empty-list Texts of the picker: any Text item showing one of the three words (case as shipped)
    // qmllint disable missing-property
    function emptyWords(item: Item, out: var): var {
        if (!item)
            return out;
        if (item.text !== undefined && probe.words.indexOf(String(item.text)) >= 0 && item.visible && item.height > 0)
            out.push(String(item.text));
        for (let i = 0; i < item.children.length; i++)
            probe.emptyWords(item.children[i], out);
        return out;
    }
    // qmllint enable missing-property
    function said(): string { return probe.emptyWords(picker, []).join("|"); }

    property var steps: []
    property int stepAt: 0
    Timer {
        id: driver
        interval: 30
        repeat: true
        onTriggered: {
            if (probe.stepAt >= probe.steps.length) {
                driver.stop();
                console.log("LPE DONE " + (probe.fails === 0 && probe.checks > 0 ? "PASS" : "FAIL") + " (" + (probe.checks - probe.fails) + "/" + probe.checks + ")");
                Qt.quit();
                return;
            }
            try {
                probe.steps[probe.stepAt]();
            } catch (e) {
                probe.check("step" + probe.stepAt, false, "threw: " + e);
            }
            probe.stepAt++;
        }
    }
    Component.onCompleted: Qt.callLater(() => {
        if (!probe.run) {
            Qt.quit();
            return;
        }
        probe.steps = [
            // two quiet turns first: the picker is laid out
            () => {},
            () => {},
            () => probe.check("none.online", probe.said() === "No models installed", "online with no models says 'No models installed' (read: '" + probe.said() + "')"),
            () => { picker.offline = true; },
            () => probe.check("offline", probe.said() === "Ollama is not running", "offline says 'Ollama is not running' (read: '" + probe.said() + "')"),
            () => { picker.busy = true; },
            () => probe.check("busy", probe.said() === "Loading models…", "busy says 'Loading models…', before offline (read: '" + probe.said() + "')"),
            () => { picker.busy = false; picker.offline = false; picker.models = [{ id: "stub:1b", family: "stub", sizeBytes: 1e9, quant: "Q4", paramSize: "1B", ctx: 4096, caps: { vision: false, tools: false, thinking: false, audio: false }, loaded: false, sizeVram: 0 }]; },
            () => {},
            () => probe.check("healthy", probe.said() === "", "a healthy list draws none of the empty words (read: '" + probe.said() + "')"),
            () => { picker.offline = true; },
            () => probe.check("healthy.offline", probe.said() === "", "offline with a model listed still draws no empty word (read: '" + probe.said() + "')")
        ];
        driver.start();
    })
}
