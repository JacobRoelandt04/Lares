pragma ComponentBehavior: Bound

import QtQuick

import "scene"

// =============================================================================
// SiliconPrewarm.qml -- the popup, built and drawn once before the first click (measured
// in the isolated Hyprland, a real Wayland context).
//
// WHY. The first open of the popup in a process stalls. Measured as the time from the open to the first
// presented frame, and the worst gap between frames after it:
//
//                                   cold disk cache        warm disk cache (every later shell start)
//     no pre-warm                   640 ms, gaps to 1.1 s  120-140 ms
//     the scene alone, pre-warmed   34 ms                  61 ms
//     this (the whole popup)        14 ms                  35 ms     (the same popup opened a second time in a
//                                                                      process: 28-33 ms)
//
// The cost is the pipelines -- the board, the light, the holograms and the particles are four programs, each linked
// at its first DRAW, and the plates' text -- and the QML types' first instantiation (12-18 ms of `create` instead of
// 35-45). Both are paid once per process, so this pays them early, where nobody is looking.
//
// NOT ARMED BY THE SHELL. The engine's prewarm (GooeyEngine.prewarm; ShellFrame.prewarmEntries has silicon's
// entry) draws the same popup in the same window -- with `prewarm: true`, the board ON and the card's patch shown, plain and then through the engine's clip layer,
// which is where an open's power-on draws the holograms and the sparks for the first time -- and this second whole-popup draw, 6 s after start in every window,
// buys nothing on top of it. Measured with silicon alone, 3 passes, medians, the machine idle (open cold: first frame / longest gap / missed
// frames; first close cold: longest gap / end, ms):
//
//     configuration               open cold: show/gap/miss/end    first close: gap/end
//     both                        64 / 25 / 4 / 403               16 / 366
//     the engine's only           56 / 25 / 3 / 404               17 / 372
//     SiliconPrewarm only         144 / 108 / 14 / 480            193 / 537
//     both, no hover prebuild     71 / 62 / 3 / 437               15 / 365
//     neither                     281 / 249 / 31 / 622            186 / 531
//
// This one ALONE leaves the first cold open at a 108 ms gap and the first close at the 193 ms stall the engine's entry removes; the engine's alone is as good as
// both, so its own cost (WHAT IT COSTS, below) would be paid a second time for nothing. It stays for what has no engine: an owner of the real service outside the
// shell (the Live mockup; `prewarmArmed` defaults to `ownsService`).
//
// WHAT IT DRAWS. One whole SiliconPopup with no view model (the real component: every type, every program the
// click will ask for), `shown: false` so its clock never runs, scaled to 2 % (15 x 10 px) in the corner of its
// host and at 2 % opacity: a tint a couple of levels deep on a patch the size of a fingernail for a third of a
// second. It is INSIDE the host on purpose: an item outside a clipping ancestor may be culled, and an item at
// opacity 0 is not drawn at all, and then nothing is compiled.
//
// WHERE AND WHEN. In the window that will show the popup: a child of any item of the bar (the owner passes its
// `anchorItem`), because pipelines belong to the window's renderer. `delayMs` after the owner is built -- the shell
// has settled and nobody is clicking -- for `holdMs`, a few frames, then the popup is destroyed and its memory goes
// with it; the pipelines stay with the window. Once per process (`done`), unless `rearm()`.
//
// The card's live patch is shown too (forceCardPatch): see onLoaded.
//
// WHAT IT COSTS. The compile itself, once, in the host window's frame loop: a freeze of the bar's own frames of
// about 0.45 s and 0.12 s on a warm disk cache, 2.2 s on the first run after a driver, Qt or shader update (the cache
// is empty then), at a moment chosen to be quiet, instead of the same hitch inside the user's click. While it is
// alive one popup's nodes and the board's layer; nothing after: it holds no node once it is done.
//
// The owner: `SiliconPrewarm { parent: owner.anchorItem; armed: owner._wired }` (any item of the bar's window).
// =============================================================================
Item {
    id: root

    // ---- in ----
    property bool armed: true
    property int delayMs: 6000            // after the owner exists: the shell has settled
    property int holdMs: 400              // how long the scene is drawn (a few frames)
    property int family: 0                // the board's family (the programs are the same for both)
    property real sizeScale: 1            // the popup's own scale (SiliconBarOwner.sizeScale): the board's layers are made at the size they will be shown at

    // ---- out ----
    readonly property bool active: loader.active
    readonly property bool done: root._done

    property bool _done: false

    // asked for again (a Mesa or shader update in a long-lived shell is not seen, so this is for a harness)
    function rearm() {
        root._done = false;
        arm.restart();
    }

    width: 0
    height: 0

    Timer {
        id: arm
        interval: root.delayMs
        running: root.armed && !root._done
        onTriggered: loader.active = true
    }
    Timer {
        id: hold
        interval: root.holdMs
        onTriggered: {
            loader.active = false;
            root._done = true;
        }
    }

    Loader {
        id: loader
        active: false
        x: 0
        y: 0
        width: 760 * root.sizeScale
        height: loader.item ? (loader.item as Item).implicitHeight : 510 * root.sizeScale
        scale: 0.02
        transformOrigin: Item.TopLeft
        opacity: 0.02
        sourceComponent: Component {
            SiliconPopup {
                shown: false
                family: root.family
                sizeScale: root.sizeScale
            }
        }
        onLoaded: {
            // the card's live patch draws straight into the window, not into the board's layer: its own pipeline,
            // compiled at its first draw -- a hitch at the first GPU mode change of a session. Shown once here (the package's patch is always drawn, so the first frame has it).
            const sc = (loader.item as SiliconPopup).sceneItem as SiliconScene;
            sc.forceCardPatch = true;
            hold.restart();
        }
    }
}
