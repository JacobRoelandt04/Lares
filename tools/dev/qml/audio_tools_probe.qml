pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/shell"
import "modules/audio"
import "modules/audio/data"

// =============================================================================
// audio_tools_probe.qml -- a row's tools (test tone, mute, lock channels, the advanced chevron) are on screen with NO pointer in the
// popup: the real AudioPopup on the mock sound system, Outputs tab, every tool found by objectName and judged by its effective opacity
// (the product up its ancestors; a disabled tool is 0.45 by design and is not counted). tools/dev/audio_tools_probe.sh runs it.
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 720
        implicitHeight: 540
        visible: true
        color: Theme.surface

        AudioMock {
            id: mock
            popupOpen: true
        }
        VolumeParity {
            id: pill
            visible: false
            pipewire: mock.world
        }
        AudioPopup {
            id: popup
            anchors.fill: parent
            service: mock
            parity: pill
            section: "sinks"
        }

        function _walk(item: Item, name: string, out: var): void {
            if (item.objectName === name)
                out.push(item);
            for (let i = 0; i < item.children.length; i++)
                win._walk(item.children[i], name, out);
        }
        function _effective(item: Item): real {
            let o = 1;
            for (let p = item; p; p = p.parent)
                o *= p.opacity;
            return o;
        }

        Timer {
            interval: 2500
            running: true
            onTriggered: {
                let bad = 0;
                let seen = 0;
                const names = ["toneButton", "muteButton", "lockButton", "advancedButton"];
                for (const n of names) {
                    const found = [];
                    win._walk(win.contentItem, n, found);
                    let counted = 0;
                    for (const it of found) {
                        if (!it.visible || it.enabled === false)
                            continue;
                        counted += 1;
                        const o = win._effective(it);
                        if (o < 0.99) {
                            bad += 1;
                            console.log("AUDIOTOOLS FAIL " + n + " effective opacity " + o.toFixed(2));
                        }
                    }
                    seen += counted;
                    console.log("AUDIOTOOLS " + n + " found " + found.length + " counted " + counted);
                }
                console.log("AUDIOTOOLS RESULT " + (bad === 0 && seen >= 8 ? "PASS" : "FAIL") + " (" + seen + " tools judged, " + bad + " not fully shown)");
                Qt.quit();
            }
        }
    }
}
