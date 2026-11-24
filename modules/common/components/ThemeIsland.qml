pragma ComponentBehavior: Bound

import QtQuick
import "../theme"

// =============================================================================
// ThemeIsland.qml -- a moving thing that keeps moving through a theme switch.
//
// A light/dark switch shows a still picture of the frame before, faded out over
// the new palette, and anything that keeps moving under it is a second copy of
// itself while it is opaque (CLAUDE.md), so everything holds still for the 420 ms.
// An ISLAND is the opt-in exception: its shape is CUT OUT of the picture (the
// host's theme_hole shader), so the live thing shows through the hole, and the
// thing brings its own old colours to the new ones (FadeColor) on the same clock.
//
//     ThemeIsland {                       // a child of the thing, in ITS coordinates
//         id: island
//         x: cx - r; y: cy - r; width: 2 * r; height: 2 * r; radius: r     // a disc
//         live: root.atRest                 // the thing can run through a switch
//     }
//     running: root.visible && (!Theme.crossfading || island.armed)       // its clock
//     skyColor: sky.value                                                 // FadeColor
//
// THE ITEM'S OWN RECT is the hole (`radius` rounds it; a disc is width/2). It is
// decided at the ask, once: `armed` is `live` at Theme.aboutToSwitch, held until the
// fade is over, so the hole and the thing's clock cannot disagree half way. A
// host that is not there (no ThemeCrossfade in this window, or its picture was not
// taken) has no hole to cut: the thing is simply live under no picture, or under a
// picture that never showed.
//
// The hole follows the item every frame while it is cut (the popup can move), through
// mapToItem, so the item may sit anywhere under the host's window.
// =============================================================================
Item {
    id: island

    // The thing can run through the fade: decided at the ask.
    property bool live: true
    // The hole's corner radius, in this item's px (width / 2 is a disc).
    property real radius: 0
    // A rectangle whose edges are put on whole DEVICE pixels, and cut HARD (no feather; `radius` still rounds it): for an island that has its own
    // opaque content over the rect (silicon's ghost, IslandGround), which must end exactly where the hole does or a line of the wrong picture shows.
    // `snapRect` is then the snapped rect in the PARENT's coordinates, for that content to lie on (the unsnapped rect until the
    // host has cut the picture once).
    property bool snap: false
    readonly property rect snapRect: island._snapRect
    property rect _snapRect: Qt.rect(island.x, island.y, island.width, island.height)

    // True from the ask of a switch (when `live` held and a host exists) until the fade is over.
    readonly property bool armed: island._armed
    // THE LIVE CURTAIN: non-null while its line, not a fade, is what passes over this island. A second copy of the thing in the old palette (silicon's ghost)
    // then stands at full opacity with `layer.effect: island.wipeEffect`, which cuts it by the same line as the rest of the old world.
    readonly property var wipe: island._host && island._host.wiping ? island._host.wipe : null
    readonly property Component wipeEffect: Component {
        ShaderEffect {
            id: cut
            property var source
            readonly property var w: island.wipe
            readonly property point at: (Theme.fadeProgress, cut.mapToItem(null, 0, 0))
            readonly property point end: (Theme.fadeProgress, cut.mapToItem(null, cut.width, cut.height))
            property vector2d size: cut.Window.window ? Qt.vector2d(cut.Window.window.width, cut.Window.window.height) : Qt.vector2d(1, 1)
            property vector2d origin: cut.w ? Qt.vector2d(cut.w.originX, cut.w.originY) : Qt.vector2d(0, 0)
            property real progress: cut.w ? cut.w.progress : 1
            property real soft: cut.w ? cut.w.soft : 1
            property real seed: cut.w ? cut.w.seed : 0
            property real style: cut.w ? cut.w.styleIndex : 0
            property vector4d place: Qt.vector4d(cut.at.x, cut.at.y, cut.end.x - cut.at.x, cut.end.y - cut.at.y)
            fragmentShader: "shaders/curtain_ghost.frag.qsb"
        }
    }
    property bool _armed: false
    property var _host: null

    visible: false

    // The hole in the host's coordinates.
    function holeIn(host: Item, dpr: real): var {
        const a = island.mapToItem(host, 0, 0);
        const b = island.mapToItem(host, island.width, island.height);
        if (island.snap) {
            const d = dpr > 0 ? dpr : 1;
            const x0 = Math.round(Math.min(a.x, b.x) * d) / d, x1 = Math.round(Math.max(a.x, b.x) * d) / d;
            const y0 = Math.round(Math.min(a.y, b.y) * d) / d, y1 = Math.round(Math.max(a.y, b.y) * d) / d;
            const p0 = island.parent.mapFromItem(host, x0, y0);
            const p1 = island.parent.mapFromItem(host, x1, y1);
            island._snapRect = Qt.rect(p0.x, p0.y, p1.x - p0.x, p1.y - p0.y);
            const kk = island.width > 0 ? (x1 - x0) / island.width : 1;
            return { "cx": (x0 + x1) / 2, "cy": (y0 + y1) / 2, "hx": (x1 - x0) / 2, "hy": (y1 - y0) / 2, "r": Math.max(0, Math.min(island.radius * kk, (x1 - x0) / 2, (y1 - y0) / 2)), "hard": true };
        }
        const hx = Math.abs(b.x - a.x) / 2;
        const hy = Math.abs(b.y - a.y) / 2;
        const k = island.width > 0 ? hx / (island.width / 2) : 1;
        return {
            "cx": (a.x + b.x) / 2,
            "cy": (a.y + b.y) / 2,
            "hx": hx,
            "hy": hy,
            "r": Math.max(0, Math.min(island.radius * k, hx, hy))
        };
    }

    function _find() {
        const win = island.Window.window;
        let h = null;
        if (win) {
            const hosts = Theme.crossfadeHosts;
            for (let i = 0; i < hosts.length; i++) {
                if (hosts[i].registerIsland && hosts[i].hostWindow === win) {
                    h = hosts[i];
                    break;
                }
            }
        }
        if (h === island._host)
            return;
        if (island._host)
            island._host.unregisterIsland(island);
        island._host = h;
        if (h)
            h.registerIsland(island);
    }
    Window.onWindowChanged: island._find()
    Component.onCompleted: island._find()
    Component.onDestruction: if (island._host) island._host.unregisterIsland(island)

    on_ArmedChanged: if (island._host) island._host.recount()

    Connections {
        target: Theme
        function onCrossfadeHostsChanged() {
            island._find();
        }
        function onAboutToSwitch() {
            island._find();
            island._snapRect = Qt.rect(island.x, island.y, island.width, island.height);
            island._armed = island.live && island._host !== null && island.width > 0 && island.height > 0;
        }
        function onCrossfadingChanged() {
            if (!Theme.crossfading)
                island._armed = false;
        }
    }
}
