pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/silicon/scene"

// =============================================================================
// tools/dev/qml/silicon_board_probe.qml -- does the silicon board DRAW? One variant per process (tools/dev/silicon_board_probe.sh runs them
// and judges the PNGs): the REAL SiliconScene's BoardLayers at a rest pose, on an opaque magenta ground, everything that is not a BoardLayer hidden (the
// glows and holograms draw on any context; the board is what 2026-11-11's NVIDIA screenshot lacked), one grab, saved to $OUT.
//
//   VARIANT=cached       the scene as the popup has it: the board and the patch are layers, the card's patch is off
//           uncached     every BoardLayer straight into the window (no layer)
//           forcecard    the card's patch drawn over a seated card (SiliconScene.forceCardPatch)
//           patchoff     no hole and no patch: the board draws the package itself
//           all          nothing hidden: the whole scene, for the before / after sheets
//           nolod        diagnostic: the board pack with its two texture reads returned as 0 (PACKDIR/silicon_board_nolod.frag.qsb)
//           noao         diagnostic: the board pack without its contact darkening (PACKDIR/silicon_board_noao.frag.qsb)
//           novert       diagnostic: the board WITHOUT its own vertex shader -- Qt's built-in one, so on an ES context the GLSL ES 1.00 variant
//           mech_flat / mech_bias / mech_lod / mech_loop   the mechanism ladder: one cached layer, a flat colour / the silkscreen read with a
//                        bias / at an explicit level / a 75-entry table indexed by a loop (PACKDIR/mech_*.frag.qsb)
//   OUT=<png>  PACKDIR=<dir of baked variant packs>  FAMILY=0|1  SIZE=1|2
// Prints SBP lines; the runner reads the PNG.
// =============================================================================
Window {
    id: root

    readonly property string variant: Quickshell.env("VARIANT") || "cached"
    readonly property string out: Quickshell.env("OUT") || "/tmp/silicon_board_probe.png"
    readonly property string packDir: Quickshell.env("PACKDIR") || ""
    readonly property int family: parseInt(Quickshell.env("FAMILY") || "0")
    readonly property int size: parseInt(Quickshell.env("SIZE") || "1")
    readonly property bool mech: root.variant.indexOf("mech_") === 0
    readonly property var n: ({ swaps: 0, started: 0 })

    width: 760 * root.size
    height: 560 * root.size
    visible: true
    color: "#FF00FF"

    Rectangle {
        anchors.fill: parent
        color: "#FF00FF"
    }

    // a 1 px spinner in the corner: offscreen stops rendering when nothing changes, and the probe counts presented frames
    Rectangle {
        width: 1
        height: 1
        x: 0
        y: 0
        color: "#FF00FF"
        RotationAnimation on rotation { from: 0; to: 360; duration: 400; loops: Animation.Infinite }
    }

    Connections {
        target: root
        function onFrameSwapped() {
            root.n.swaps++;
        }
    }

    // the window may be any size (a tiling compositor stretches it); the picture is this fixed stage
    Item {
        id: stage
        width: 760 * root.size
        height: 560 * root.size
        Rectangle {
            anchors.fill: parent
            color: "#FF00FF"
        }
    }

    Loader {
        id: sceneLoader
        parent: stage
        anchors.fill: parent
        active: !root.mech
        sourceComponent: SiliconScene {
            family: root.family
            renderScale: root.size
            cpuLoad: 0.55
            dgpuAwake: 1
            gpuUtil: 0.5
            gpuMode: 2
            flowW: -11
            forceCardPatch: root.variant === "forcecard"
            patchOff: root.variant === "patchoff"
            Component.onCompleted: root.arrange(this)
        }
    }

    // the mechanism ladder: one effect in a cached layer, over the silkscreen image
    Image {
        id: silkImage
        source: Qt.resolvedUrl("modules/silicon/assets/silkscreen.png")
        visible: false
        smooth: true
        mipmap: true
    }
    Loader {
        id: mechLoader
        parent: stage
        x: 20
        y: 20
        width: 480
        height: 360
        active: root.mech
        sourceComponent: ShaderEffect {
            property var silk: silkImage
            property vector4d view: Qt.vector4d(6, 0, 0, 0)
            fragmentShader: "file://" + root.packDir + "/" + root.variant + ".frag.qsb"
            layer.enabled: true
            layer.textureSize: Qt.size(480 * root.size, 360 * root.size)
        }
    }

    // what the variant changes, done from outside: a BoardLayer is any child with `samplesPerAxis`; the rest of the scene is hidden unless `all`
    function arrange(scene: Item) {
        const kids = scene.children;
        for (let i = 0; i < kids.length; i++) {
            const k = kids[i];
            if (k.samplesPerAxis === undefined) {
                // the glows, the particle fields and the holograms go; a layered BoardLayer's own ShaderEffectSource is a sibling too, and stays
                const part = k.emitter !== undefined || k.kind !== undefined || k.figA !== undefined;
                if (part && root.variant !== "all")
                    k.visible = false;
                continue;
            }
            if (root.variant === "uncached")
                k.cached = false;
            else if (root.variant === "nolod" || root.variant === "noao")
                k.fragmentShader = "file://" + root.packDir + "/silicon_board_" + root.variant + ".frag.qsb";
            else if (root.variant === "novert")
                k.vertexShader = "";
        }
        console.log("SBP scene children " + kids.length + " variant " + root.variant);
    }

    // frames are not a clock: wait for the compositor to present several, then a wall floor for the first compile
    Timer {
        interval: 250
        repeat: true
        running: true
        onTriggered: {
            root.n.started += 250;
            if (root.n.swaps >= 8 && root.n.started >= 1500)
                root.shoot();
            else if (root.n.started > 60000)
                root.fail("no frames: " + root.n.swaps);
        }
    }
    property bool shot: false
    function shoot() {
        if (root.shot)
            return;
        root.shot = true;
        stage.grabToImage(function (r) {
            const ok = r.saveToFile(root.out);
            console.log("SBP grab " + root.variant + " " + (ok ? "saved" : "NOT-SAVED") + " " + root.out + " swaps=" + root.n.swaps);
            Qt.quit();
        });
    }
    function fail(why: string) {
        console.log("SBP FAIL " + why);
        Qt.quit();
    }
}
