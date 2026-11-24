import QtQuick

// =============================================================================
// HoloLayerBase.qml -- one hologram's PLANE, LENS and HAZE machinery, the toolkit's: an upright plane through `anchor` facing the viewer's horizontal direction
// (normal (0.7071, 0, 0.7071) in board space), `planeW` mm wide, from `planeBase` to `planeBase + planeH` mm above the anchor, with the projector's haze and the
// lens on the anchor; in true isometric it shows 1:1 across and x 0.8165 up. The scene places this item over the rect IsoCore.holoRect() gives. The picture
// is a scene's own shader (silicon's: the symbols, the fractals, the beam; holo_common.glsl is the shared part: noise, the entrance, the flicker, the
// projector cone, the lens glow). A scene's own HoloLayer derives from this, names its pack and adds what it draws.
//
// What it does with the scene's numbers:
//   - `power` is the scene's entrance (0 -> 1 over the whole power-on sequence); this layer maps its own window of it (`powerFrom` .. 1) to its flicker-on.
//   - `time` is the scene clock. The idle motion is a function of it (so a film frame is exact), plus an extra phase that integrates `energy` (never tempo
//     x time: a change of load never jumps a phase). Every oscillator reaches the shader as a fraction of a cycle, wrapped here in double precision.
//   - Photosensitivity: nothing in the shader flickers faster than 3 Hz (the fastest steady oscillator is 1.6 Hz, and 2.9 Hz at full load with the tempo boost).
//   - `awake` dims the whole hologram; `presence` shows it; `live` is the idle ladder's (the flicker and the scan are gone at 0); `breath` a slow brightness factor.
// Cost: the item is only drawn while it is shown (`presence` > 0 and the entrance has begun).
// =============================================================================
ShaderEffect {
    id: root

    property var anchor: [0, 0, 0]        // mm; the beam's start (the graphics tile)
    property var target: [0, 0, 0]        // mm; the beam's end: the ghost die's centre at its top, the card at rest (IsoCamera.ghostDie; the shader adds the hover)
    property real planeW: 52
    property real planeBase: 10
    property real planeH: 48

    // the scene's camera (scene px) and this item's offset in the scene
    property real pxPerMm: 3.4
    property real originX: 0
    property real originY: 0
    property real offsetX: root.x
    property real offsetY: root.y
    property int family: 0
    property bool dark: false
    property real renderScale: 1

    property real time: 0                 // s, the scene clock
    property color colour: "#4480F4"

    property real energy: 0.5             // 0..1: CPU load / GPU utilisation
    property real power: 1                // 0..1: power-on (the entrance flickers it up from 0)
    property real presence: 1             // 0..1: GPU shown while the card is seated; beam shown in Integrated
    property real awake: 1                // 0..1: dims the whole hologram (a dGPU asleep: bind the scene's dgpuAwake); 1 = no change
    property real live: 1                 // 0..1: the idle ladder's: the flicker and the scan run at 1 and are gone at 0 (a halted hologram is a still picture)
    property real breath: 1               // a slow brightness factor on the whole hologram's light (the scene's MUX breath); 1 = none

    // ---- private tunables ----
    property real powerFrom: 0.45         // the scene's power at which this hologram starts to flicker on
    property real tempoBoost: 0.6         // idle tempo x (1 + tempoBoost * energy); 0.6 keeps the fastest component under 3 Hz at full load
    property real frameStrength: 0.40     // the plane's corner brackets, 0 hides them
    property real scanDepth: 0.26         // how dark the thin scanlines draw (0 hides them)
    property real bandStrength: 0.07      // the slow bright band that crosses the plane every 6 s
    property real beamStrength: 1.8       // the projector beam's haze, 0 hides it
    // The projector's base: the lens discs and rings on the anchor (and the GPU's big ring), at this share of full strength. The idle ladder's
    // `live` takes them out with the rest of the motion, so a halted hologram has none (they look odd without the particles).
    property real lensStrength: 0.5

    readonly property real _hp: Math.max(0, Math.min(1, (root.power - root.powerFrom) / (1 - root.powerFrom)))

    visible: root.presence > 0.003 && root._hp > 0.001

    // ---- the idle clock: the scene time plus the energy's accumulated extra tempo ----
    property real _lastT: -1
    property real _extra: 0
    onTimeChanged: {
        const dt = root.time - root._lastT;
        if (dt < 0)
            root._extra = 0;
        else if (root._lastT >= 0 && dt < 0.25)
            root._extra += dt * root.tempoBoost * root.energy;
        root._lastT = root.time;
    }
    readonly property real _T: root.time + root._extra
    // a fraction of a cycle of an oscillator at `f` Hz, exact in doubles
    function _cyc(f: real): real {
        const c = f * root._T;
        return c - Math.floor(c);
    }

    function _v(c: color): vector4d {
        return Qt.vector4d(c.r, c.g, c.b, 1);
    }
    function _arr(a: var, i: int): real {
        return a && a.length > i ? a[i] : 0;
    }

    // The ROOT of this file: a literal path would resolve against the file that instantiates it, so the path is a Qt.resolvedUrl, and

    // `source` is declared for Qt's built-in shader, which samples it and which the effect can hold before that binding lands.

    property var source: null

    property vector4d view: Qt.vector4d(root.width, root.height, root.pxPerMm, root.family)
    property vector4d plane: Qt.vector4d(root.planeW, root.planeBase, root.planeH, root.beamStrength)
    property vector4d anchorP: Qt.vector4d(root._arr(root.anchor, 0), root._arr(root.anchor, 1), root._arr(root.anchor, 2), root.presence)
    property vector4d targetP: Qt.vector4d(root._arr(root.target, 0), root._arr(root.target, 1), root._arr(root.target, 2), root.energy)
    property vector4d phA: Qt.vector4d(root._cyc(0.55), root._cyc(0.83), root._cyc(1.57), root._cyc(0.163))
    property vector4d phB: Qt.vector4d(root._cyc(0.27), root._cyc(0.21), root._cyc(0.22), root._cyc(0.9))
    property vector4d phC: Qt.vector4d(root._cyc(0.9), root._cyc(0.35), root._cyc(0.032), root._cyc(0.6))
    property vector4d colA: Qt.vector4d(root.colour.r, root.colour.g, root.colour.b, root.awake)
    property vector4d liveP: Qt.vector4d(root.live, root.breath, root.lensStrength, 0)
}
