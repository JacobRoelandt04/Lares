pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/silicon"
import "modules/silicon/data"
import "modules/silicon/data/SiliconModel.js" as Model
import "modules/silicon/scene"

// =============================================================================
// tools/dev/qml/silicon_perf_probe.qml -- what silicon costs, for tools/silicon/calibrate_overhead.sh: frames presented per clock
// tick, and (sampled by the runner from /proc between the marks) the GPU time and the CPU time.
//
//   SCOPE=scene  (default) the bare scene on a 16 ms timer of its own, `VARIANT`:
//     alive    the live scene: the clock ticks time and the pulse/flow phases; the cached board stays still
//     rebake   alive, and the cached board re-rendered EVERY tick (a transient: the card lifting, the plug, the lever)
//     lift     alive, and the CPU package lifted and turning continuously (a profile change: the live patch
//              over the zone, the board below held)
//   SCOPE=popup  the WHOLE popup (scene + plates + overlays + input) on SiliconMock, on its OWN clock: the idle
//                ladder drives it, `LEVEL`:
//     alive    the ladder stays alive: 16 ms ticks, a game's worth of figures changing four times a second
//     calm     calm from the start: 33 ms ticks
//     halt     the ladder halts after 0.7 s and the clock parks (the live layer eases to rest first): the steady
//              window is a quiet stretch with nothing changing -- no tick, no frame
//     haltfig  halted, and the sensors move every 2 s (the service's halted cadence): a figure's change may cost
//              its own frame, nothing else may
//     igpu     alive, and the GPU zone stepped to Integrated and back every 2.5 s (two arrow presses each way, from the first second of the
//              steady window): the card leaves its slot and comes back, the beam and the ghost card, the hologram's de-rez -- the
//              switch the user saw drop frames (round 7, F1). Informational: the table's GPU ms/frame and ms/s are what to read
//     entrance the popup is OPENED inside the measured window (made 150 ms after the start mark, `entranceEnabled`, the board
//              powering on over 1.2 s): what a first second of the popup costs. The verdict is exact: the cached board is handed NO
//              changed uniform after the first 0.3 s (each change renders the whole board again: ~40 ms of GPU a frame in a Wayland
//              client -- CLAUDE.md's cached-layer law; the swap module's fade was the case that taught it, removed in round 3); the
//              GPU time the runner sums over the window is for the record
//   ABLATE=plates,holos,particles,glow,board   hide those parts of the popup (the measurement says what each costs:
//                ablate before optimising)
//   FAMILY=0|1  SECONDS=8 (the steady window after a 3 s warm-up); DARK=1 is the runner's (it seeds the theme's mode)
//   SIZE=2 (the runner's SIZE=2) makes the window twice as wide and as tall -- four times the pixels, as a HiDPI panel
//   of the same logical size has -- and the popup is drawn that large (`sizeScale`; the bare scene fills the window): the shaders' cost
//   follows the pixels. (QT_SCALE_FACTOR does not: on the offscreen platform it changes the reported pixel ratio and not what is rendered.)
//
// Prints SILICON_PERF lines: "pid=", "sec <n> frames <f> ticks <t>", "steady start", "steady end frames <f> ticks <t>",
// and a RESULT line.
// =============================================================================
Window {
    id: root

    readonly property int size: parseInt(Quickshell.env("SIZE") || "1")
    width: 760 * root.size
    height: 560 * root.size
    visible: true
    color: Theme.surface

    readonly property string scope: Quickshell.env("SCOPE") || "scene"
    readonly property string variant: Quickshell.env("VARIANT") || "alive"
    readonly property string level: Quickshell.env("LEVEL") || "alive"
    readonly property string ablate: Quickshell.env("ABLATE") || ""
    readonly property int family: parseInt(Quickshell.env("FAMILY") || "0")
    readonly property int seconds: parseInt(Quickshell.env("SECONDS") || "8")
    // frames are counted in a plain object: nothing can bind to a counter
    readonly property var n: ({ frames: 0, ticks: 0 })
    property int sec: 0
    property real last: 0
    property int steadyFrames: 0
    property int steadyTicks: 0
    property bool opened: false
    readonly property var boardWatch: ({ changes: 0, openedAt: 0 })

    Connections {
        target: root
        function onFrameSwapped() {
            root.n.frames++;
        }
    }

    // ---- SCOPE=scene: the bare scene and a clock of its own ----
    Loader {
        id: sceneLoader
        anchors.fill: parent
        active: root.scope === "scene"
        sourceComponent: SiliconScene {
            family: root.family
            renderScale: root.size
            cpuLoad: 0.55
            dgpuAwake: 1
            gpuUtil: 0.5
            gpuMode: 2
            flowW: -11
        }
    }
    Timer {
        interval: 16
        repeat: true
        running: root.scope === "scene"
        onTriggered: {
            const scene = sceneLoader.item as SiliconScene;
            if (!scene)
                return;
            const now = Date.now() / 1000;
            const dt = root.last > 0 ? Math.min(0.05, now - root.last) : 0.016;
            root.last = now;
            root.n.ticks++;
            scene.time += dt;
            scene.cpuPhase += dt * 0.9;
            scene.gpuPhase += dt * 1.2;
            scene.flowPhase += dt * 24;
            if (root.variant === "rebake")
                scene.lever = (root.n.ticks % 2) * 1e-4;
            else if (root.variant === "lift") {
                scene.pkgRise = 1;
                scene.pkgQuarter = 0.02 + (scene.time * 0.6) % 0.96;
            }
        }
    }

    // ---- SCOPE=popup: the whole popup on SiliconMock and its own clock ----
    component PopupRig: Item {
        id: rig
        readonly property alias mock: m
        readonly property alias popup: p
        SiliconMock {
            id: m
            playing: root.level !== "halt" && root.level !== "haltfig"
            scenario: root.level === "igpu" ? "desk" : "game"     // (a game holds the dGPU: Integrated then asks for a confirmation and the card never moves)
            timeMs: 13000
            popupOpen: true
            machineHolders: []
            idleLadder.calmAfterMs: root.ladderTimes()[0]
            idleLadder.haltAfterMs: root.ladderTimes()[1]
            Component.onCompleted: {
                if (root.level === "igpu")
                    m.externalGpuMode(2);
            }
        }
        SiliconPopup {
            id: p
            anchors.fill: parent
            vm: m
            family: root.family
            sizeScale: root.size
            shown: true
            entranceEnabled: root.level === "entrance"
        }
    }
    // the ladder's [calmAfterMs, haltAfterMs] for the level measured
    function ladderTimes(): var {
        if (root.level === "calm")
            return [300, 3600000];
        if (root.level === "halt" || root.level === "haltfig")
            return [300, 700];
        return [3600000, 7200000];
    }
    Loader {
        id: popupLoader
        anchors.fill: parent
        // `entrance` makes the popup inside the measured window (the runner's start mark, then a beat so the GPU time sampled at
        // the mark is the mark's); every other level has it from the start
        active: root.scope === "popup" && (root.level !== "entrance" || root.opened)
        sourceComponent: Component {
            PopupRig {}
        }
        onLoaded: {
            const p = (popupLoader.item as PopupRig).popup;
            p.clock.ticked.connect(dt => root.n.ticks++);
            root.applyAblation(p);
            if (root.level === "entrance" || root.level === "igpu")
                root.watchBoard(p.sceneItem as SiliconScene);
        }
    }
    // every uniform the cached board is handed, as its properties: a change of any of them renders the whole board again
    readonly property var boardInputs: ["family", "dark", "renderScale", "pxPerMm", "originX", "originY", "offsetX", "offsetY", "pkgTurn", "pkgLift",
        "cardLift", "cardDissolve", "plugIn", "lever", "lightDir", "shadowStrength", "colours", "colours2", "tune", "lockBar", "lockShackle", "lockDim",
        "lockAlpha", "condCode", "cycCode", "timeLabel"]
    function watchBoard(sc: SiliconScene) {
        // the board is the scene's only cached BoardLayer (the live patch over the CPU zone is not)
        const board = sc.children.find(c => c.cached === true);
        if (!board) {
            console.log("SILICON_PERF entrance: no board layer found");
            return;
        }
        root.boardWatch.openedAt = Date.now();
        for (const name of root.boardInputs)
            board[name + "Changed"].connect(() => {
                if (Date.now() - root.boardWatch.openedAt > 300)
                    root.boardWatch.changes++;
            });
    }
    function applyAblation(p) {
        const parts = root.ablate.split(",").filter(s => s !== "");
        for (const a of parts) {
            if (a === "plates") {
                p.cpuBlock.visible = false;
                p.gpuBlock.visible = false;
            }
            for (const c of p.sceneItem.children) {
                const isField = c.emitter !== undefined, isHolo = c.kind !== undefined && c.planeW !== undefined;
                const isGlow = c.pulse !== undefined, isBoard = c.cached !== undefined;
                if ((a === "particles" && isField) || (a === "holos" && isHolo) || (a === "glow" && isGlow) || (a === "board" && isBoard))
                    c.visible = false;
            }
        }
    }
    // a halted popup whose sensors still move every 2 s (the service's halted cadence): the figures' own frames. The
    // sensors alternate between two readings 0.9 s apart (own count: the timer fires on every other second, so the
    // second's parity would pick the same reading every time and only the first change would be a change)
    property int sensorSteps: 0
    Timer {
        interval: 2000
        repeat: true
        running: root.scope === "popup" && root.level === "haltfig" && root.sec >= 3
        onTriggered: {
            const rig = popupLoader.item as PopupRig;
            const m = rig ? rig.mock : null;
            if (m) {
                root.sensorSteps++;
                m.timeMs = 13000 + (root.sensorSteps % 2 ? 900 : 0);
            }
        }
    }

    // level igpu: Hybrid > Smart > Integrated and back, every 2.5 s, in the steady window
    property int gpuSteps: 0
    Timer {
        interval: 2500
        repeat: true
        running: root.scope === "popup" && root.level === "igpu" && root.sec >= 3
        onTriggered: {
            const rig = popupLoader.item as PopupRig;
            if (!rig)
                return;
            const dir = root.gpuSteps % 2 === 0 ? -1 : 1;
            root.gpuSteps++;
            rig.popup.stepGpu(dir);
            rig.popup.stepGpu(dir);
        }
    }

    Timer {
        id: openTimer
        interval: 150
        onTriggered: root.opened = true
    }

    Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: {
            root.sec++;
            console.log("SILICON_PERF sec " + root.sec + " frames " + root.n.frames + " ticks " + root.n.ticks);
            if (root.sec === 3) {
                root.steadyFrames = root.n.frames;
                root.steadyTicks = root.n.ticks;
                console.log("SILICON_PERF steady start");
                if (root.level === "entrance")
                    openTimer.start();
            }
            if (root.sec === 3 + root.seconds) {
                const f = root.n.frames - root.steadyFrames, t = root.n.ticks - root.steadyTicks;
                console.log("SILICON_PERF steady end frames " + f + " ticks " + t);
                const fpt = t > 0 ? f / t : 0;
                let ok;
                if (root.scope === "popup" && root.level === "entrance") {
                    // the window held what it says it does: the board powered all the way on
                    const sc = ((popupLoader.item as PopupRig).popup as SiliconPopup).sceneItem as SiliconScene;
                    console.log("SILICON_PERF entrance power " + sc.power.toFixed(3) + " board uniform changes after 0.3 s: " + root.boardWatch.changes);
                    ok = f > 0 && sc.power > 0.999 && root.boardWatch.changes === 0;
                } else if (root.scope === "popup" && root.level === "igpu") {
                    console.log("SILICON_PERF igpu steps " + root.gpuSteps + " board uniform changes (frames the cached board is rendered again) " + root.boardWatch.changes);
                    ok = f > 0 && root.gpuSteps >= 2;
                } else if (root.scope === "popup" && (root.level === "halt" || root.level === "haltfig"))
                    ok = t === 0 && (root.level === "halt" ? f === 0 : f <= root.seconds);
                else
                    ok = fpt >= 0.8 && fpt <= (root.scope === "popup" && root.level === "calm" ? 1.15 : 1.05);   // calm: the figures' own frames are a larger share of fewer ticks
                const fam = root.family;
                console.log("SILICON_PERF RESULT " + (ok ? "PASS" : "FAIL") + " scope=" + root.scope + " variant=" + (root.scope === "scene" ? root.variant : root.level)
                            + " family=" + fam + " size=" + root.size + " frames/tick=" + fpt.toFixed(3) + " frames=" + f + " ticks=" + t);
                quit.start();
            }
        }
    }

    // the runner samples the process's GPU time right after "steady end": stay up for it
    Timer {
        id: quit
        interval: 1500
        onTriggered: Qt.quit()
    }

    Component.onCompleted: console.log("SILICON_PERF pid=" + Quickshell.processId + " scope=" + root.scope + " variant=" + (root.scope === "scene" ? root.variant : root.level))
}
