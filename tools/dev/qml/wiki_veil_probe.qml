pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell
import "modules/common/theme"
import "modules/wiki"
import "modules/wiki/data"
import "modules/wiki/WikiVeilPick.js" as Pick

// =============================================================================
// tools/dev/qml/wiki_veil_probe.qml -- the wiki veils (modules/wiki/WikiVeil.qml)
// held to what they promise. Runner: tools/dev/wiki_veil_probe.sh, which also
// judges the pictures this file writes (WVP_OUT). Prints WVP lines and
// "WVP RESULT PASS|FAIL". A bare smoke (no PROBE=1) quits at once.
//
// STATE CHECKS (here)
//   clock     a running veil's time moves; hidden it stops; under a theme
//             crossfade it stops; a veil told `running: false` never moves
//   card      the real WikiPopup on WikiMock: an entry with no picture builds a
//             veil that runs, an idle shell (`windowActive` false) stops it, an
//             entry with a logo has its plate, an entry with a photograph
//             builds NO veil; a photograph whose file is gone shows one
//   thumb     the real WikiCompactCard: its veil is built, still, at its start
//   pick      PICK lines for the runner (node must agree), and a fair share of
//             1000 ids per pattern
//
// PICTURES (the runner judges them)
//   grid.png  rows = the five patterns; columns = the same article twice, another
//             article, the first with a plate, the first in another hue, and both
//             hues with no hue share
//   seq_<n>.png  the five patterns, `frames` frames 1/24 s apart
// =============================================================================
Scope {
    id: root
    readonly property bool live: Quickshell.env("PROBE") === "1"
    readonly property string out: Quickshell.env("WVP_OUT") || ""
    readonly property int frames: 96
    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("WVP " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    readonly property var names: Pick.NAMES
    readonly property string keyA: "wiki.archlinux.org/Systemd"
    readonly property string keyB: "en.wikipedia.org/Messier_87"
    readonly property real cw: 240
    readonly property real ch: 136

    // every WikiVeil under `it` (through Loaders and Repeaters)
    function veilsIn(it: Item): var {
        const found = [];
        const walk = o => {
            if (o.objectName === "wikiVeil")
                found.push(o);
            const kids = o.children || [];
            for (let i = 0; i < kids.length; i++)
                walk(kids[i]);
        };
        walk(it);
        return found;
    }

    WikiMock {
        id: mock
        dryRun: true
        scenario: "noImage"
    }

    Window {
        id: win
        visible: root.live
        width: 1700
        height: 1500
        color: Theme.surface

        // ---- the grid ---------------------------------------------------------------------
        Rectangle {
            id: grid
            width: 7 * root.cw
            height: root.names.length * root.ch
            color: Theme.listBox
            Repeater {
                model: root.names
                delegate: Item {
                    id: row
                    required property string modelData
                    required property int index
                    y: row.index * root.ch
                    Repeater {
                        model: 7
                        delegate: WikiVeil {
                            id: cell
                            required property int index
                            x: cell.index * root.cw
                            width: root.cw
                            height: root.ch
                            pattern: row.modelData
                            seedKey: cell.index === 2 ? root.keyB : root.keyA
                            hue: cell.index === 4 || cell.index === 5 ? Theme.mdOrange : Theme.mdBlue
                            plateRadius: cell.index === 3 ? 40 : 0
                            running: false
                            Component.onCompleted: {
                                if (cell.index >= 5)
                                    cell.style.hueShare = 0;
                            }
                        }
                    }
                }
            }
        }

        // ---- the sequence -------------------------------------------------------------------
        Rectangle {
            id: seq
            y: grid.height + 4
            width: root.names.length * root.cw
            height: root.ch
            color: Theme.listBox
            Repeater {
                id: seqVeils
                model: root.names
                delegate: WikiVeil {
                    id: sv
                    required property string modelData
                    required property int index
                    x: sv.index * root.cw
                    width: root.cw
                    height: root.ch
                    pattern: sv.modelData
                    seedKey: root.keyA
                    running: false
                    // every wall turns within the sequence: a turn that snaps has nowhere to hide
                    Component.onCompleted: sv.style.mazeEveryS = 5
                }
            }
        }

        // ---- the clock's subjects ---------------------------------------------------------------
        WikiVeil {
            id: runner
            x: 0
            y: seq.y + seq.height + 4
            width: 120
            height: 68
            seedKey: root.keyA
        }
        WikiVeil {
            id: still
            x: 124
            y: runner.y
            width: 120
            height: 68
            seedKey: root.keyA
            running: false
        }
        WikiCarousel {
            id: lostPhoto
            x: 248
            y: runner.y
            width: 240
            height: 136
            veilKey: root.keyB
            images: [{ kind: "photo", url: "file:///nonexistent/wiki-veil-probe.jpg", thumbUrl: "", aspect: 1.78, focusY: 0.5, credit: "", license: "" }]
        }

        // ---- the real cards -------------------------------------------------------------------------
        WikiPopup {
            id: popup
            x: 500
            y: runner.y
            service: mock
            startTab: "deepen"
            width: implicitWidth
            height: implicitHeight
        }
        WikiCompactCard {
            id: compact
            x: 960
            y: runner.y
            width: 396
            variant: "wide"
            service: mock
            tab: "deepen"
        }
    }

    // ---- the steps: a function runs, then the next after `wait` ms (or when a grab lands) ----------
    property int _i: -1
    property real _t0: 0
    property real _held: 0
    function grab(item: Item, name: string): void {
        stepper.stop();
        item.grabToImage(r => {
            r.saveToFile(root.out + "/" + name);
            stepper.interval = 1;
            stepper.start();
        });
    }
    readonly property var steps: [
        // ---- pick ----
        () => {
            const keys = ["", "a", root.keyA, root.keyB, "wiki.gentoo.org/Portage", "docs.kernel.org/scheduler", "en.wikipedia.org/Zürich", "x".repeat(300)];
            for (const k of keys) {
                const p = Pick.of(k);
                console.log("WVP PICK " + JSON.stringify([k, p.pattern, p.seed, p.t0]));
            }
            const count = {};
            for (let i = 0; i < 1000; i++) {
                const p = Pick.of("en.wikipedia.org/Article_" + i).pattern;
                count[p] = (count[p] || 0) + 1;
            }
            let fair = root.names.length === 5;
            for (const n of root.names)
                fair = fair && count[n] >= 150 && count[n] <= 250;
            root.check("pick: each of the five patterns gets a fair share of 1000 ids", fair, JSON.stringify(count));
            const again = Pick.of(root.keyA), once = Pick.of(root.keyA);
            root.check("pick: the same id is the same veil", JSON.stringify(again) === JSON.stringify(once), "");
            return 300;
        },
        // ---- clock ----
        () => {
            root.check("clock: a veil on show is ticking", runner.ticking, "ticking " + runner.ticking);
            root.check("clock: a veil starts at its article's time", Math.abs(still.time - Pick.of(root.keyA).t0) < 1e-6, still.time + " vs " + Pick.of(root.keyA).t0);
            root._t0 = runner.time;
            return 600;
        },
        () => {
            root.check("clock: a running veil's time moves", runner.time > root._t0 + 0.05, (runner.time - root._t0).toFixed(3) + " s in 600 ms");
            root.check("clock: a veil told not to run does not", !still.ticking && Math.abs(still.time - Pick.of(root.keyA).t0) < 1e-6, "ticking " + still.ticking + " time " + still.time);
            runner.visible = false;
            return 100;
        },
        () => {
            root._held = runner.time;
            return 500;
        },
        () => {
            root.check("clock: hidden, the veil stops", !runner.ticking && runner.time === root._held, "ticking " + runner.ticking + " moved " + (runner.time - root._held).toFixed(3));
            runner.visible = true;
            // a theme crossfade, as Theme reports one (its two flags; no host is registered in a probe)
            Theme._hosted = true;
            Theme._switching = true;
            return 100;
        },
        () => {
            root.check("clock: the probe's crossfade is one", Theme.crossfading, "Theme.crossfading " + Theme.crossfading);
            root._held = runner.time;
            return 500;
        },
        () => {
            root.check("clock: under a theme crossfade the veil stops", !runner.ticking && runner.time === root._held, "ticking " + runner.ticking + " moved " + (runner.time - root._held).toFixed(3));
            Theme._switching = false;
            Theme._hosted = false;
            return 300;
        },
        () => {
            root.check("clock: after the crossfade it runs on", runner.ticking && runner.time > root._held, "ticking " + runner.ticking);
            return 50;
        },
        // ---- the real card ----
        () => {
            const v = root.veilsIn(popup);
            const img = popup.card ? popup.card.images : [];
            root.check("card: an entry with no picture is a veil in the model", img.length === 1 && img[0].kind === "veil", JSON.stringify(img));
            root.check("card: ... and builds ONE veil in the well", v.length === 1, v.length + " veils");
            if (v.length === 1) {
                root.check("card: the veil is the article's own", v[0].seedKey === popup.card.id && v[0].shown === Pick.of(popup.card.id).pattern, v[0].seedKey + " " + v[0].shown);
                root.check("card: the veil runs while the card is on show", v[0].ticking, "ticking " + v[0].ticking);
                root.check("card: no plate without a logo", v[0].plateRadius === 0, "plate " + v[0].plateRadius);
            }
            popup.windowActive = false;
            return 200;
        },
        () => {
            const v = root.veilsIn(popup);
            root.check("card: an idle shell stops the veil", v.length === 1 && !v[0].ticking, v.length === 1 ? "ticking " + v[0].ticking : v.length + " veils");
            popup.windowActive = true;
            mock.scenario = "normal";
            return 400;
        },
        () => {
            // normal: Deepen is Systemd (a logo), Discover a photograph
            const v = root.veilsIn(popup);
            const img = popup.card ? popup.card.images : [];
            root.check("card: an entry with a logo keeps it in the model", img.length === 1 && img[0].kind === "relief", JSON.stringify(img));
            root.check("card: ... on its veil's plate", v.length === 1 && v[0].plateRadius > 20, v.length === 1 ? "plate " + v[0].plateRadius : v.length + " veils");
            popup.showTab("discover");
            return 400;
        },
        () => {
            const v = root.veilsIn(popup);
            const img = popup.card ? popup.card.images : [];
            root.check("card: the photograph card is one", img.length >= 1 && img[0].kind === "photo", JSON.stringify(img).slice(0, 120));
            root.check("card: a photograph builds no veil", v.length === 0, v.length + " veils");
            const lost = root.veilsIn(lostPhoto);
            root.check("card: a photograph whose file is gone shows the article's veil", lost.length === 1 && lost[0].visible && lost[0].seedKey === root.keyB,
                       lost.length + " veils");
            mock.scenario = "noImage";
            return 400;
        },
        // ---- the thumbnail ----
        () => {
            const v = root.veilsIn(compact);
            root.check("thumb: a card with no picture has its veil", v.length === 1, v.length + " veils");
            if (v.length === 1) {
                root.check("thumb: the thumbnail's veil is still", !v[0].ticking && !v[0].running, "running " + v[0].running + " ticking " + v[0].ticking);
                root.check("thumb: ... at the article's start", Math.abs(v[0].time - Pick.of(v[0].seedKey).t0) < 1e-6, String(v[0].time));
                root.check("thumb: ... the middle of the picture, smaller", v[0].zoom < 1 && v[0].zoom > 0.2 && v[0].cornerRadius > 0, "zoom " + v[0].zoom);
                root.check("thumb: ... and the article's own", v[0].seedKey === compact.card.id, v[0].seedKey);
            }
            return 50;
        },
        // ---- the pictures ----
        () => {
            root.grab(grid, "grid.png");
            return -1;
        }
    ]
    property int _frame: 0
    function nextFrame(): void {
        if (root._frame >= root.frames) {
            console.log("WVP frames " + root.frames);
            console.log("WVP RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks)");
            Qt.quit();
            return;
        }
        for (let i = 0; i < seqVeils.count; i++)
            seqVeils.itemAt(i).seek(root._frame / 24);
        const n = root._frame++;
        // one frame for the uniform to land, then the grab
        frameWait.name = "seq_" + String(n).padStart(3, "0") + ".png";
        frameWait.start();
    }
    Timer {
        id: frameWait
        property string name: ""
        interval: 20
        onTriggered: seq.grabToImage(r => {
            r.saveToFile(root.out + "/" + frameWait.name);
            root.nextFrame();
        })
    }
    Timer {
        id: stepper
        interval: 300
        running: root.live
        onTriggered: {
            root._i++;
            if (root._i >= root.steps.length) {
                root.nextFrame();
                return;
            }
            let wait = 50;
            try {
                wait = root.steps[root._i]();
            } catch (e) {
                root.check("step " + root._i + " ran", false, String(e));
            }
            if (wait >= 0) {
                stepper.interval = wait;
                stepper.start();
            }
        }
    }
    Timer {
        interval: 0
        running: !root.live
        onTriggered: Qt.quit()
    }
}
