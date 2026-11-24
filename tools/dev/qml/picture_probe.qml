pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/components"

// =============================================================================
// picture_probe.qml -- PictureProbe (modules/common/components) on the pictures it must tell apart: run by tools/dev/picture_probe.sh,
// offscreen (QT_QUICK_BACKEND=rhi), in a hidden-from-the-desktop window. Each case is a scene copied through a mipmapped
// ShaderEffectSource with `live: false` and ONE scheduleUpdate, as the captures do, and judged by a PictureProbe that is never drawn:
//   bright       a lit gradient                                   ink
//   dark         the dark theme's surface (#1e1e2e), nothing else  ink   (dark is not empty)
//   patch        black with one 120 x 120 white square in a corner ink   (ink in one region is enough)
//   black        opaque black                                      empty
//   clear        an item that draws nothing (the copy of nothing)  empty
//   faint        white at alpha 1/255 everywhere                   empty (grabbed over nothing it un-premultiplies to white)
//   nosource     no source at all                                  unknown
// and `held`: after `bright` was judged its scene is taken away with no new copy asked, and the copy judged again is still lit (the probe
// brought the copy in, once; nothing takes it again, so what the picture draws later is what was judged).
// Prints "PP <case> <verdict> <inked>/<samples> PASS|FAIL" per case and "PP RESULT PASS|FAIL".
// =============================================================================
ShellRoot {
    id: root

    readonly property string dir: Quickshell.env("PP_DIR") || ""
    property var cases: [["dark", "ink"], ["patch", "ink"], ["black", "empty"], ["clear", "empty"], ["faint", "empty"], ["nosource", "unknown"], ["bright", "ink"]]
    property int at: -1
    property int fails: 0

    Timer {
        interval: 0
        running: root.dir === ""
        onTriggered: {
            console.log("PP not armed -- tools/dev/picture_probe.sh runs it");
            console.log("PP RESULT SKIP");
            Qt.quit();
        }
    }

    FloatingWindow {
        id: win
        visible: root.dir !== ""
        implicitWidth: 960
        implicitHeight: 540
        color: "#808080"

        Item {
            id: bright
            width: 960
            height: 540
            Rectangle {
                id: brightFill
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0; color: "#4480F4" }
                    GradientStop { position: 1; color: "#EAEDF5" }
                }
            }
        }
        Rectangle {
            id: dark
            width: 960
            height: 540
            color: "#1e1e2e"
        }
        Rectangle {
            id: patch
            width: 960
            height: 540
            color: "black"
            Rectangle {
                x: 960 - 120
                y: 540 - 120
                width: 120
                height: 120
                color: "white"
            }
        }
        Rectangle {
            id: black
            width: 960
            height: 540
            color: "black"
        }
        Item {
            id: clear
            width: 960
            height: 540
        }
        Rectangle {
            id: faint
            width: 960
            height: 540
            color: "#01ffffff"
        }

        ShaderEffectSource {
            id: copy
            width: 960
            height: 540
            live: false
            mipmap: true
            visible: false
        }
        PictureProbe {
            id: probe
            source: null
            file: root.dir + "/pp.xpm"
            onJudged: (verdict, inked, samples) => root.done(verdict, inked, samples)
        }
    }

    function next(): void {
        root.at++;
        if (root.at >= root.cases.length) {
            root.checkHeld();
            return;
        }
        const name = root.cases[root.at][0];
        const items = { bright: bright, dark: dark, patch: patch, black: black, clear: clear, faint: faint };
        if (name === "nosource") {
            probe.source = null;
        } else {
            copy.sourceItem = items[name];
            probe.source = copy;
            copy.scheduleUpdate();
        }
        probe.judge();
    }
    function done(verdict: string, inked: int, samples: int): void {
        const c = root.cases[root.at];
        const ok = verdict === c[1];
        if (!ok)
            root.fails++;
        console.log("PP " + c[0] + " " + verdict + " " + inked + "/" + samples + " " + (ok ? "PASS" : "FAIL") + " (wanted " + c[1] + ")");
        Qt.callLater(root.next);
    }
    // `held`: the copy is taken ONCE, by the probe's own pass -- a live:false copy is not taken again when the scene changes, so what the
    // picture draws later is what was judged. The bright scene is taken away (no new scheduleUpdate) and the same copy is judged again.
    function checkHeld(): void {
        brightFill.visible = false;
        heldProbe.judge();
    }
    PictureProbe {
        id: heldProbe
        parent: win.contentItem
        source: copy
        file: root.dir + "/pp_held.xpm"
        onJudged: (verdict, inked, samples) => {
            const ok = verdict === "ink";
            if (!ok)
                root.fails++;
            console.log("PP held " + verdict + " " + inked + "/" + samples + " " + (ok ? "PASS" : "FAIL") + " (the copy judged before still holds the lit scene)");
            console.log("PP RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + root.fails + " failed)");
            quitT.start();
        }
    }
    Timer {
        id: quitT
        interval: 0
        onTriggered: Qt.quit()
    }
    Timer {
        interval: 300
        running: root.dir !== ""
        onTriggered: root.next()
    }
    Timer {
        interval: 20000
        running: root.dir !== ""
        onTriggered: {
            console.log("PP RESULT FAIL (stuck at case " + root.at + ")");
            Qt.quit();
        }
    }
}
