import QtQuick

import "../../common/board"
import "SceneGeometry.js" as Geo
import "IsoCamera.js" as Cam

// =============================================================================
// HoloLayer.qml -- one hologram: the CPU's symbol, the GPU's fractal or the integrated beam, on the toolkit's hologram scheme (HoloLayerBase: the plane, the
// lens and the haze, the entrance, the idle clock). What is here is silicon's: the symbols, the de-rez, the armillary, the ghost card.
// Its PROPERTY API is the contract with SiliconScene
// (CONTRACT section 6); the picture is silicon_holo.frag (shaders/src/silicon_holo.frag.in and the
// holo_*.glsl pieces it splices in).
//
// The plane: upright, through `anchor`, facing the viewer's horizontal direction (normal
// (0.7071, 0, 0.7071) in board space); `planeW` mm wide, from `planeBase` to `planeBase + planeH`
// mm above the anchor. In true isometric it shows 1:1 across and x 0.8165 up (a 2d image
// transformed to match isometric perspective). The scene places this item over the
// rect IsoCamera.holoRect() gives (the beam: over the tile and the card).
//
// What it does with the scene's numbers:
//   - `power` is the scene's entrance (0 -> 1 over the whole power-on sequence); this layer maps
//     its own window of it (`powerFrom` .. 1) to its flicker-on: at most three brief dips.
//   - `time` is the scene clock. The idle motion is a function of it (so a film frame is exact),
//     plus an extra phase that integrates `energy` (never tempo x time: a change of load never
//     jumps a phase). Every oscillator reaches the shader as a fraction of a cycle, wrapped here in
//     double precision.
//   - Photosensitivity: nothing in the shader flickers faster than 3 Hz (the fastest steady
//     oscillator is 1.6 Hz, and 2.9 Hz at full load with the tempo boost; the flicker's three terms
//     add up to 10 % in the worst case, a slow scan
//     band adds a 7 % bump once in six seconds), the power-on has three dips in about half a second
//     (once per popup open), the de-rez changes slice by slice, never the whole field.
//   - `awake` dims the whole hologram (the scene can bind a sleeping dGPU's hologram to it).
//
// The integrated beam: `anchor` is the graphics tile, `target` the die of the ghost card (IsoCamera.ghostDie) -- the beam fades out
// into it the way it fades in at the tile. The ghost is the REAL card without its I/O bracket: its parts are read here from SceneGeometry.PARTS
// (IsoCamera.ghostSet) and handed to the shader as uniforms (cardPcb ... r3hMlc2), so the ghost follows the card.
//
// Cost: the item is only drawn while it is shown (`presence` > 0 and the entrance has begun); the
// fractal marches inside its bounding sphere only.
// =============================================================================
HoloLayerBase {
    id: root

    property string kind: "cpu"           // "cpu" | "gpu" | "beam"


    // cpu: 0 leaf (Quiet), 1 scales (Balanced), 2 shock (Performance) -- the profile's index
    // gpu: 0 Sierpinski tetrahedron (Smart), 1 Menger sponge (Hybrid), 2 Mandelbulb (dGPU-only)
    property int symbol: 0
    property int nextSymbol: 0
    property real derez: 0                // 0 = symbol .. 1 = nextSymbol: the glitch de-rez between
    property color nextColour: root.colour
    property color tweakColour: "#C838C6"
    property real tweak: 0                // 0..1: the rim takes the second hue (tuning differs from the profile)

    // ---- private tunables ----
    property real arch: Cam.BEAM.arch    // mm the integrated beam rises in the middle (0 = straight)

    // ---- the additions, each its own switch (1 on, 0 off = the picture without it exactly) so each can be taken out on its own ----
    property real fxPlinth: 1        // CPU, the scales (Balanced): a horizontal base with a turning dial of ticks and a bead that keeps the time; the foot stands on it as round drums
    property real fxTrace: 1         // CPU, the shock (Performance): a faint oscilloscope trace with two phosphor echoes behind the bolt
    property real fxOrbits: 1        // GPU, the three fractals: an armillary of three turning rings with beads about the volume
    property real fxStream: 1        // the iGPU's beam: a slow soft swell of light runs down the beam's core, tile to card

    readonly property int _kind: root.kind === "gpu" ? 1 : (root.kind === "beam" ? 2 : 0)



    // ---- the armillary (the GPU's rings): one ring's screen frame, from its normal `n` (board space) and radius ----
    // The projected circle is an ellipse about its centre: its major axis R lies along `m` (the in-plane direction perpendicular to the view: it projects at full length), its
    // minor axis R |n.C| along the screen direction of the normal (`ns`, the normal's own projection, a unit vector perpendicular to the major axis). Edge-on (n.C = 0) the minor
    // axis is 0 and the ellipse a line: nothing may be divided by it. The shader takes the ring's second coordinate as y = q.ns / (R b) with b = sqrt(n.C^2 + FLOOR^2): the
    // true minor axis, except that it never goes below FLOOR (a hair of width at edge-on; 0.4 mm on the biggest ring). Dividing a vector that is itself 0 there by max(n.C^2, 0.0009)
    // would collapse the ellipse at edge-on to a pair of lines across the form and fling the ring about.
    // Which half is the near one: a point of the ring at angle a (R (cos a m + sin a w), w the in-plane direction at 90 degrees) is at depth w.C sin a = -sqrt(1 - (n.C)^2)
    // sin a: the half with sin a < 0 is nearer the viewer, whatever n.C's sign (taking the sign of n.C into it draws the far half in front). On screen y = se sin a with
    // se = (n.C) / b, so sin a = y / se: the shader gets `se` (+-1 away from edge-on, 0 at it: the two halves blend through 0.5 instead of swapping) and the bead's near weight is
    // plain -sin(its angle). Returns [X, Y, bead] for the shader (orbRing).
    function _ring(n: var, R: real, bead: real, spin: real): var {
        const CR = [0.70710678, 0, -0.70710678], CU = [-0.40824829, 0.81649658, -0.40824829], CC = [0.57735027, 0.57735027, 0.57735027];
        const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
        const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
        let m = cross(n, CC);
        const ml = Math.sqrt(dot(m, m));
        m = ml > 1e-4 ? [m[0] / ml, m[1] / ml, m[2] / ml] : CR;
        const ms = [dot(m, CR), dot(m, CU)];
        const sd = dot(n, CC);
        const ns = [-ms[1], ms[0]];                                           // unit, perpendicular to the major axis
        const sg = ns[0] * dot(n, CR) + ns[1] * dot(n, CU) >= 0 ? 1 : -1;     // towards the normal's own projection
        const b = Math.sqrt(sd * sd + 0.0004), se = sd / b;
        const ba = 2 * Math.PI * bead;
        const bs = Math.sin(ba);
        const bf = Math.min(1, Math.max(0, (0.12 - bs) / 0.24));              // smoothstep(-0.12, 0.12, -sin a) of the shader: 1 on the near half
        return [Qt.vector4d(ms[0], ms[1], sg * ns[0] / b, sg * ns[1] / b), Qt.vector4d(1 / R, se, bf * bf * (3 - 2 * bf), spin),
                Qt.point(R * (Math.cos(ba) * ms[0] + bs * sd * sg * ns[0]), R * (Math.cos(ba) * ms[1] + bs * sd * sg * ns[1]))];
    }
    // a ring's normal tilted `th` rad from the vertical towards the azimuth `az` (cycles)
    function _tilt(th: real, az: real): var {
        const a = 2 * Math.PI * az;
        return [Math.sin(th) * Math.cos(a), Math.cos(th), Math.sin(th) * Math.sin(a)];
    }
    readonly property bool _orbOn: root._kind === 1 && root.fxOrbits > 0.5
    readonly property var _o0: root._orbOn ? root._ring([0, 1, 0], 20.5, root._cyc(0.07), root._cyc(0.021)) : null
    readonly property var _o1: root._orbOn ? root._ring(root._tilt(0.49, root._cyc(0.04)), 19.0, root._cyc(0.052) + 0.4, 0) : null
    // the meridian ring: its normal lies in the horizontal plane and turns once in 40 s (it opens and closes like a hoop spinning)
    readonly property var _o2: root._orbOn ? root._ring(root._tilt(Math.PI / 2, root._cyc(0.025)), 17.2, root._cyc(0.045) + 0.7, 0) : null



    fragmentShader: Qt.resolvedUrl("../shaders/silicon_holo.frag.qsb")
    // ---- the uniform block (silicon_holo.frag.in says what each member is) ----
    property vector4d frame: Qt.vector4d(root.originX, root.originY, root._kind, root.dark ? 1 : 0)
    property vector4d quad: Qt.vector4d(root.offsetX, root.offsetY, root.renderScale, root.arch)
    property vector4d look: Qt.vector4d(root.derez, root.tweak, root._hp, root.symbol)
    property vector4d look2: Qt.vector4d(root.nextSymbol, root.frameStrength, root.scanDepth, root.bandStrength)
    // oscillators, in cycles: scan drift, two flickers, the hiccup | bob, sway, flow, pulse | crackle, orbit, spin, beam pulse
    property vector4d colB: root._v(root.nextColour)
    property vector4d colT: root._v(root.tweakColour)
    // ---- the card, for the integrated beam's ghost: SceneGeometry.PARTS through IsoCamera.ghostSet (one source) ----
    readonly property var _gs: Cam.ghostSet({ PARTS: Geo.PARTS, CARD: Geo.CARD })
    function _rect(row: var): vector4d {
        return Qt.vector4d(row.r[0], row.r[1], row.r[2], row.r[3]);
    }
    function _stepN(row: var): vector4d {
        return Qt.vector4d(row.step[0], row.step[1], row.n[0], row.n[1]);
    }
    function _yShape(row: var): vector4d {
        return Qt.vector4d(row.y[0], row.y[1], row.shape, row.skip);      // w: the cells the row leaves out, a mask (sum of 2^i)
    }
    property vector4d cardPcb: root._rect(root._gs.pcb)
    property vector4d cardSub: root._rect(root._gs.sub)
    property vector4d cardDie: root._rect(root._gs.die)
    property vector4d cardM0: root._rect(root._gs.gddr[0])
    property vector4d cardM1: root._rect(root._gs.gddr[1])
    property vector4d cardM2: root._rect(root._gs.gddr[2])
    property vector4d cardM3: root._rect(root._gs.gddr[3])
    // the PCB's underside and top, the substrate's top, the die's top (board mm, the card at rest)
    property vector4d cardH: Qt.vector4d(root._gs.pcb.y[0], root._gs.pcb.y[1], root._gs.sub.y[1], root._gs.die.y[1])
    // the switches and clocks of the additions (silicon_holo.frag.in says what each is). The trace and the stream ride the scene clock, never a wall one: a halted
    // popup (the clock stopped) holds its frame, and `live` is 0 there so the events are not in it
    property vector4d fxOn: Qt.vector4d(root.fxStream, root.fxPlinth, root.fxTrace, root.fxOrbits)
    property vector4d phD: Qt.vector4d(0, root._cyc(0.11), root._cyc(0.04), root._cyc(0.06))
    property vector4d orbX0: root._o0 ? root._o0[0] : Qt.vector4d(1, 0, 0, 1)
    property vector4d orbY0: root._o0 ? root._o0[1] : Qt.vector4d(1, 1, 0, 0)
    property vector4d orbX1: root._o1 ? root._o1[0] : Qt.vector4d(1, 0, 0, 1)
    property vector4d orbY1: root._o1 ? root._o1[1] : Qt.vector4d(1, 1, 0, 0)
    property vector4d orbX2: root._o2 ? root._o2[0] : Qt.vector4d(1, 0, 0, 1)
    property vector4d orbY2: root._o2 ? root._o2[1] : Qt.vector4d(1, 1, 0, 0)
    property vector4d orbB: Qt.vector4d(root._o0 ? root._o0[2].x : 0, root._o0 ? root._o0[2].y : 0, root._o1 ? root._o1[2].x : 0, root._o1 ? root._o1[2].y : 0)
    property vector4d orbC: Qt.vector4d(root._o2 ? root._o2[2].x : 0, root._o2 ? root._o2[2].y : 0, 0, 0)
    // the integrated beam's ghost card (silicon_holo.frag.in says what each is)
    readonly property var _box: Cam.ghostBox({ PARTS: Geo.PARTS }, 3)
    property vector4d r3hBox: Qt.vector4d(root._box.x0, root._box.z0, root._box.x1, root._box.z1)
    property vector4d r3hHover: Qt.vector4d(Cam.BEAM.hover, Cam.BEAM.bob, root._box.ry0 - 0.5, root._box.ry1 + 0.5)
    property vector4d r3hBeam: Qt.vector4d(Cam.BEAM.thick0, Cam.BEAM.thick1, 0, 0)
    property vector4d r3hTops: Qt.vector4d(root._gs.gddr[0].y[1], root._gs.sink.y[1], root._gs.fingers.pitch, root._gs.fingers.w)
    property vector4d r3hFing: Qt.vector4d(root._gs.fingers.x0, root._gs.fingers.z0, root._gs.fingers.x1, root._gs.fingers.z1)
    property vector4d r3hSink: root._rect(root._gs.sink)
    property vector4d r3hFin0: root._rect(root._gs.fins)
    property vector4d r3hFin1: root._stepN(root._gs.fins)
    property vector4d r3hFin2: root._yShape(root._gs.fins)
    property vector4d r3hChk0: root._rect(root._gs.chokes)
    property vector4d r3hChk1: root._stepN(root._gs.chokes)
    property vector4d r3hChk2: root._yShape(root._gs.chokes)
    property vector4d r3hFet0: root._rect(root._gs.fets)
    property vector4d r3hFet1: root._stepN(root._gs.fets)
    property vector4d r3hFet2: root._yShape(root._gs.fets)
    property vector4d r3hCap0: root._rect(root._gs.caps)
    property vector4d r3hCap1: root._stepN(root._gs.caps)
    property vector4d r3hCap2: root._yShape(root._gs.caps)
    property vector4d r3hMlc0: root._rect(root._gs.mlcc)
    property vector4d r3hMlc1: root._stepN(root._gs.mlcc)
    property vector4d r3hMlc2: root._yShape(root._gs.mlcc)
}
