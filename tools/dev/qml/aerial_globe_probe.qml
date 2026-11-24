pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/aerial/scene"
import "modules/common/theme"

// =============================================================================
// tools/dev/qml/aerial_globe_probe.qml -- the VPN globe, judged (tools/dev/aerial_globe_probe.sh runs it, arms it, and reads the PNGs). One process; a step per tick.
// ROUND 3: the tunnel (TunnelLayer, tunnel.frag) is gone -- the label's chrome is the tunnel's look now and `tools/dev/aerial_r3_label.sh` proves it -- so its renders, its ink box and
// its halted check are gone; the globe's own checks stand, and the meridians' polar circles are new:
//   marks     the shader's own marker (a magenta disc where lat / lon lands by globe.frag's arithmetic) is grabbed for Brussels, Tokyo, Reykjavik at two turns each; the runner
//             finds its centre in the picture and compares it with GlobeMath's projection (`EXPECT mark ...` lines): the lights and the picking share GlobeMath, the shader has its own
//   pick      lightAt answers a front-facing light at its drawn place, nothing at a back-facing one, "fastest" always
//   renders   the globe at 4 turns, tunnel down / up (the exit light), in both families, to $OUT/globe_<family>_<turn>_<state>.png (the runner judges ink; $MODE is the theme's, seeded by the runner)
//   polar     the north pole turned to the viewer (tilt 1, the turn where the pole region is most face-on): the picture and the places of samples along a meridian and on the polar
//             circle (`EXPECT polar ...`, by GlobeMath, which the marks prove agrees with the shader); the runner looks for ink ON the parallel at 77.5 degrees and none between it and the pole
//   alive     a live globe turns; halted + spinning false presents no frame
// Prints `GP <name> PASS|FAIL <why>`, `EXPECT ...` and `GP RESULT PASS|FAIL`.
// =============================================================================
Window {
    id: root

    readonly property string out: Quickshell.env("OUT") || "/tmp/aerial_globe_probe"
    width: 760
    height: 640
    visible: true
    color: "#FF00FF"

    property var fails: []
    property int swaps: 0
    function check(name: string, ok: bool, why: string): void {
        console.log("GP " + name + " " + (ok ? "PASS" : "FAIL") + (why ? " " + why : ""));
        if (!ok)
            root.fails.push(name);
    }
    Connections {
        target: root
        function onFrameSwapped() { root.swaps++; }
    }

    // a sparse fixture of Proton's countries at their real coordinates (Brussels, Tokyo, Reykjavik are the probe's)
    readonly property var catalog: ({ countries: [
        { code: "BE", name: "Belgium", lat: 50.85, lon: 4.35, servers: 40, minLoad: 21 },
        { code: "JP", name: "Japan", lat: 35.68, lon: 139.69, servers: 120, minLoad: 33 },
        { code: "IS", name: "Iceland", lat: 64.14, lon: -21.9, servers: 10, minLoad: 12 },
        { code: "US", name: "United States", lat: 39.8, lon: -98.6, servers: 400, minLoad: 40 },
        { code: "BR", name: "Brazil", lat: -14.2, lon: -51.9, servers: 25, minLoad: 28 },
        { code: "AU", name: "Australia", lat: -25.3, lon: 133.8, servers: 60, minLoad: 37 },
        { code: "ZA", name: "South Africa", lat: -30.6, lon: 22.9, servers: 12, minLoad: 19 }] })

    Item {
        id: stage
        width: 760
        height: 640
        Rectangle {
            anchors.fill: parent
            color: Theme.surface
        }
        AerialScene {
            id: scene
            width: 760
            family: 0
            renderScale: 1
            animate: false
            state: null
        }
        GlobeLayer {
            id: globe
            anchors.fill: scene
            cam: scene.cam
            geo: scene.geo
            family: scene.family
            dark: scene.dark
            catalog: root.catalog
            proton: ({ state: "down", server: null })
            spinning: false
            interactive: false
        }
    }

    // ---- the sequencer ----
    property int _step: 0
    property bool _busy: false
    property var _steps: []
    function grab(name: string): void {
        root._busy = true;
        stage.grabToImage(function (r) {
            r.saveToFile(root.out + "/" + name + ".png");
            root._busy = false;
        });
    }
    function _markStep(city: string, lat: real, lon: real, k: int, turn: real, tilt: real): var {
        return function () {
            globe.tilt = tilt;
            globe.turn = turn;
            globe._raw = turn;
            globe.probeMark = Qt.vector4d(lat, lon, 1, 3);
            root._steps.splice(root._step, 0, function () {
                const p = globe.project(lat, lon);
                console.log("EXPECT mark " + city + " " + k + " " + p.x.toFixed(3) + " " + p.y.toFixed(3) + " " + (p.front ? 1 : 0));
                root.grab("mark_" + city + "_" + k);
            });
        };
    }
    Component.onCompleted: {
        const s = [];
        // marks: two turns each, the city on the visible hemisphere (the facing longitude is -turn)
        const cases = [["brussels", 50.85, 4.35, [[-0.09, 0], [-0.70, 0.5]]], ["tokyo", 35.68, 139.69, [[-2.09, 0], [-2.62, 1]]], ["reykjavik", 64.14, -21.9, [[0.35, 0], [0.87, 0.5]]]];   // [turn, tilt]: the second of each is TILTED (the shader's rotR against GlobeMath.tilt)
        cases.forEach(c => c[3].forEach((t, k) => s.push(root._markStep(c[0], c[1], c[2], k, t[0], t[1]))));
        s.push(function () { globe.probeMark = Qt.vector4d(0, 0, 0, 3); globe.tilt = 0; });
        // pick
        s.push(function () {
            globe.turn = -0.09;
            globe._raw = -0.09;
        });
        s.push(function () {
            const be = globe.lightPos("BE"), jp = globe.lightPos("JP");
            const hitBe = globe.lightAt(be.x, be.y), hitJp = globe.lightAt(jp.x, jp.y);
            root.check("pick-front", hitBe !== null && hitBe.code === "BE", JSON.stringify(hitBe));
            root.check("pick-back-none", hitJp === null && !globe.lightFront("JP"), JSON.stringify(hitJp));
            const ft = globe.lightPos("fastest"), hf = globe.lightAt(ft.x, ft.y);
            root.check("pick-fastest", hf !== null && hf.code === "fastest", JSON.stringify(hf));
            const far = globe.lightAt(be.x + 40, be.y + 40);
            root.check("pick-miss", far === null, JSON.stringify(far));
            root.check("pos-unknown", globe.lightPos("XX") === null, "");
        });
        s.push(function () {
            globe.turn = -2.62;
            globe._raw = -2.62;
        });
        s.push(function () {
            const jp = globe.lightPos("JP"), be = globe.lightPos("BE");
            const hitJp = globe.lightAt(jp.x, jp.y), hitBe = globe.lightAt(be.x, be.y);
            root.check("pick-front-turned", hitJp !== null && hitJp.code === "JP" && hitBe === null, JSON.stringify([hitJp, hitBe]));
        });
        // renders: 4 turns, down / up, both families
        [0, 1].forEach(fam => {
            s.push(function () {
                scene.family = fam;
                globe.power = 0;
            });
            s.push(function () {
                const f = globe._fr;
                console.log("EXPECT rect " + fam + " " + f.cx.toFixed(2) + " " + f.cy.toFixed(2) + " " + f.rp.toFixed(2));
                root.grab("base_" + fam);
            });
            s.push(function () { globe.power = 1; });
            [["down", false], ["up", true]].forEach(st => {
                [-0.17, -1.7, 2.9, 1.2].forEach((t, k) => {
                    s.push(function () {
                        scene.family = fam;
                        globe.turn = t;
                        globe._raw = t;
                        globe.proton = st[1] ? { state: "up", server: { country: "BE", name: "BE#42" } } : { state: "down", server: null };
                    });
                    s.push(function () {
                        root.grab("globe_" + fam + "_" + k + "_" + st[0]);
                    });
                });
            });
        });
        // polar: a pole toward the viewer, the SOUTH one by the popup's own tilt (1) and the NORTH one by a negative tilt only a probe can write (the UI never tips the north forward;
        // the shader's `abs(lat)` is what is judged). Meridian 150 E (a multiple of the hairline step, ocean where it matters) and the parallel's own stretch at 165 E (between two meridians)
        // (the GROWN globe -- the pointer over it, twice the radius -- so a degree of latitude is a couple of pixels: the meridians converge on the pole and need the room)
        s.push(function () { globe.pointerOver = true; });
        s.push(function () {});
        s.push(function () {});
        [0, 1].forEach(fam => {
            [["n", 1], ["s", -1]].forEach(pole => {
                s.push(function () {
                    scene.family = fam;
                    globe.proton = ({ state: "down", server: null });
                    // the tilt and turn that put the polar samples most face-on (the least foreshortened): searched with GlobeMath's own projection
                    const lats = [68, 74, 77.5, 80, 86].map(v => v * pole[1]);
                    let best = 0, bestTilt = 1, bestScore = -1e9;
                    [1.5, -1.5].forEach(tl => {            // (1.5 x the maximum tilt is the pole face-on: the popup tips the south only as far as 1, the probe judges the shader)
                        globe.tilt = tl;
                        for (let t = -3.14; t <= 3.14; t += 0.02) {
                            globe.turn = t;
                            globe._raw = t;
                            const score = Math.min.apply(null, lats.map(la => globe.project(la, 150).depth).concat([globe.project(77.5 * pole[1], 165).depth]));
                            if (score > bestScore) { bestScore = score; best = t; bestTilt = tl; }
                        }
                    });
                    globe.tilt = bestTilt;
                    globe.turn = best;
                    globe._raw = best;
                    globe.power = 1;
                    console.log("EXPECT polarturn " + fam + pole[0] + " tilt " + bestTilt + " turn " + best.toFixed(3) + " depth " + bestScore.toFixed(3));
                });
                s.push(function () {
                    [["below-m", 68, 150], ["below-m", 71, 150], ["below-m", 74, 150], ["below-o", 68, 165], ["below-o", 71, 165], ["below-o", 74, 165], ["cap", 77.5, 165], ["cap", 77.5, 135],
                     ["above-m", 80, 150], ["above-m", 82, 150], ["above-m", 84, 150], ["above-m", 86, 150], ["above-o", 80, 165], ["above-o", 82, 165], ["above-o", 84, 165], ["above-o", 86, 165]].forEach(c => {
                        const q = globe.project(c[1] * pole[1], c[2]);
                        console.log("EXPECT polar " + fam + pole[0] + " " + c[0] + " " + (c[1] * pole[1]) + " " + q.x.toFixed(2) + " " + q.y.toFixed(2) + " " + (q.front ? 1 : 0) + " " + q.depth.toFixed(3));
                    });
                    const a = globe.project(77.5 * pole[1], 150), b = globe.project(90 * pole[1], 150);
                    console.log("EXPECT polarspan " + fam + pole[0] + " " + Math.hypot(a.x - b.x, a.y - b.y).toFixed(2));
                    root.grab("polar_" + fam + pole[0]);
                });
            });
        });
        s.push(function () { globe.tilt = 0; globe.pointerOver = false; });
        // alive: the layer's own timer turns it; halted it presents nothing
        s.push(function () {
            scene.family = 0;
            globe.spinning = true;
            globe.halted = false;
            globe.turnRate = 6;            // the offscreen run is short: a fast turn proves the Timer, the rate is a property
            root._t0 = globe.turn;
        });
        s.push(function () {});
        s.push(function () {
            root.check("alive-turns", Math.abs(globe.turn - root._t0) > 0.01, "turn " + root._t0 + " -> " + globe.turn);
            globe.halted = true;
            scene.halted = true;           // the board's pulse beat (round 2) is a clock too: the host halts it with the rest
        });
        s.push(function () { root._sw0 = root.swaps; root._turn1 = globe.turn; });
        s.push(function () {});
        s.push(function () {});
        s.push(function () {});
        s.push(function () {});
        s.push(function () {
            root.check("halted-still", globe.turn === root._turn1 && root.swaps - root._sw0 <= 1, "turn " + root._turn1 + " -> " + globe.turn + ", frames " + (root.swaps - root._sw0));
        });
        s.push(function () {
            console.log("GP RESULT " + (root.fails.length ? "FAIL (" + root.fails.join(", ") + ")" : "PASS"));
            Qt.quit();
        });
        root._steps = s;
        tick.start();
    }
    property real _t0: 0
    property real _turn1: 0
    property int _sw0: 0
    Timer {
        id: tick
        interval: 280
        repeat: true
        onTriggered: {
            if (root._busy || root._step >= root._steps.length)
                return;
            const fn = root._steps[root._step++];
            fn();
        }
    }
}
