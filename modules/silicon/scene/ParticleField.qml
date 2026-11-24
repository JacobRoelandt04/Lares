import QtQuick

import "SceneGeometry.js" as Geo

// =============================================================================
// ParticleField.qml -- one GPU particle pass: ONE ShaderEffect over ONE GridMesh, a quad per row
// (N <= 8192 per mesh -- beyond it ids vanish SILENTLY). Every particle
// is a pure function of (id, `time`, the drive properties below): nothing is stored, nothing is
// integrated here, so a film that sets `time` per frame draws what the live scene draws.
// Shaders: shaders/src/silicon_particles.vert.in / .frag.in + particles_common.glsl (the motion of
// each emitter), assembled by tools/dev/silicon_shader_gen.js.
//
// emitter "cpu" / "gpu": sparks from the package / the GPU die into a 3D cone (with volume) toward
//          the hologram plane over `anchor`; pass 0 draws those BEHIND the plane, pass 1 those in
//          FRONT (the plane's normal is (0.7071, 0, 0.7071)). Stretched along their own screen
//          velocity. `energy` thins and thickens the plume and sets how high it climbs; `colour`
//          recolours every live spark at once (the scene eases it with the hologram's de-rez).
// emitter "traces": the pack's POLES -- the swirl (discharging, flowW < 0: thrown out of the
//          (-) terminal) and funnel (charging, flowW > 0: drawn into the (+) one, in `chargeColour`); dots per
//          watt, kept within ~10 mm of the terminal so they stay clear of the CPU package. The flow along
//          the copper is the glow's pulses alone. Parts of the
//          board hide what they stand in front of (asked at the end of the streak nearest the terminal).
//          Every number of both fields is a property (charge* / discharge*, below), tuned on the mockup's Particles tab.
// emitter "card": the card dissolving into particles where the board shader's dissolve has gone
//          (`cardDissolve`, `cardLift`), and condensing back the other way (progress is a function
//          of the dissolve, so the reverse is the same motion backwards).
//
// A field with nothing to draw is not visible: it costs nothing -- and that includes a field whose
// `brightness` has reached nothing: the idle ladder eases it to 0 on the way to halt, so a halted popup
// draws no particle at all, not even an invisible one. `forceVisible` keeps it drawn (the owner's
// pre-warm: a pipeline is compiled by its first DRAW).
// =============================================================================
ShaderEffect {
    id: root

    // ---- the scene's contract ----
    property string emitter: "cpu"
    property int pass: 0                  // sparks: 0 draws those behind the hologram's plane, 1 those in front
    property int count: 0                 // particles in the mesh; 0 = the emitter's own default (<= 8192)
    property var anchor: [0, 0, 0]        // mm: the die top (sparks), the card's centre (card)
    property real pxPerMm: 3.4
    property real originX: 0
    property real originY: 0
    property int family: 0                // 0 Material, 1 Blueprint (the two share one look here)
    property bool dark: false
    property real renderScale: 1

    property real time: 0
    property real energy: 0.5             // sparks: 0 a few lazy ones .. 1 a lively plume
    property color colour: "#4480F4"
    property real power: 1                // the entrance, 0..1
    property real flowW: 0                // traces: > 0 charging, < 0 discharging, watts
    property color chargeColour: "#44C145"
    property real cardDissolve: 0
    property real cardLift: 0
    property real pkgTurn: 0              // rad: the CPU package's turn and
    property real pkgLift: 0              // mm, its lift (what hides a packet behind it)

    // ---- tuning (the mockup panel's) ----
    property real brightness: 1           // x every particle's alpha (the scene hands the idle ladder's live in here)
    property bool forceVisible: false
    property real seed: root._kind === 0 ? (root.emitter === "gpu" ? 2 : 1) : (root._kind === 1 ? 3 : 5)
    property real coneDeg: 30
    property real emitRadius: root.emitter === "gpu" ? 4.0 : 8
    property real lifeS: 1.5
    property real reachMin: 12
    property real reachMax: 64
    property real energyFloor: root.emitter === "gpu" ? 0 : 0.07

    // ---- the poles' tuning (emitter "traces"; the mockup's Particles tab edits these, mockups/silicon.qml carries each one's tip) ----
    // The CHARGING field is the funnel drawn into the (+) terminal (the (-) one's is the weak one), the DISCHARGING field the swirl thrown out
    // of the (-) terminal (the (+) one's is the weak one). A field's speed is its reach over its life. Lengths in mm on the board, leans in
    // degrees from the face's normal toward +z, `Floor` the faintest a spawned particle may be, `Edge` the soft edge of the density gate at most.
    property real chargeKneeW: 18         // the watts at which 63 % of the slots live: dens = 1 - exp(-W / knee)
    property real chargeWeak: 0.40        // the weak pole's share of the density
    property real chargeLifeMinusS: 1.0
    property real chargeLifePlusS: 1.0
    property real chargeAlpha: 1.0
    property real chargeReachMinus: 7
    property real chargeReachPlus: 4.4    // straight out along +x: gone before the charger's chokes, which start 1.9 mm from the face, can hide it
    property real chargeMouthMinus: 3.0
    property real chargeMouthPlus: 1.0    // narrow: the charger's first choke stands 2.1 mm to the side of the axis
    property real chargeNeck: 0.8
    property real chargeTwist: 0          // turns about the axis on the way in (0: the funnel does not twist)
    property real chargeOriginY: 1.4      // the (-) funnel's height up its face (it hangs above it)
    property real chargeOriginPlusY: 1.0  // the (+) funnel's: the face's vertical centre (SceneGeometry.js POLES.plus.y), as the discharge field's
    property real chargeSize: 1
    property real chargeLeanMinus: 0
    property real chargeLeanPlus: 0       // perpendicular to the face
    property real chargeFloor: 0.6
    property real chargeEdge: 0.10

    property real dischargeKneeW: 18
    property real dischargeWeak: 0.40
    property real dischargeLifeMinusS: 1.5
    property real dischargeLifePlusS: 0.9     // shorter than the (-) one's: a short straight field that lived as long would barely move before it faded
    property real dischargeAlpha: 1.0
    property real dischargeReachMinus: 10
    property real dischargeReachPlus: 4.4 // straight out along +x: gone before the charger's first capacitor, 6.7 mm from the face
    property real dischargeRadiusMinus: 2.2   // the swirl's radius at the end of its throw
    property real dischargeRadiusPlus: 1.4    // narrower: the charger's first choke stands 2.1 mm to the side of the straight (+) swirl's axis, and its ring must not reach it
    property real dischargeTurnsMin: 0.5  // fewest turns of a swirl
    property real dischargeTurnsMax: 1.2  // most turns
    property real dischargeOriginY: 1.0    // the face's vertical centre (SceneGeometry.js POLES.plus.y)
    property real dischargeSize: 1
    property real dischargeLeanMinus: 0
    property real dischargeLeanPlus: 0    // perpendicular to the face
    property real dischargeFloor: 0.6
    property real dischargeEdge: 0.10

    // ---- derived ----
    readonly property int _kind: root.emitter === "traces" ? 1 : (root.emitter === "card" ? 2 : 0)
    readonly property int _default: root._kind === 0 ? (root.emitter === "gpu" ? 700 : 900)
                                    : (root._kind === 1 ? 200 : 2800)
    readonly property int _n: Math.max(1, Math.min(8192, root.count > 0 ? root.count : root._default))
    readonly property var _card: Geo.CARD
    readonly property bool _active: {
        if (root.forceVisible)
            return true;
        if (root.brightness < 0.004)
            return false;
        switch (root._kind) {
        case 0: return root.power > 0.4 && root.energy + root.energyFloor > 0.004;
        case 1: return root.power > 0.02 && Math.abs(root.flowW) > 0.1;
        default: return root.cardDissolve > 0.001 && root.cardDissolve < 0.999;
        }
    }
    visible: root._active

    function _v(c: color, w: real): vector4d {
        return Qt.vector4d(c.r, c.g, c.b, w);
    }

    mesh: GridMesh {
        resolution: Qt.size(1, 4 * root._n - 1)
    }
    // The ROOT of this file: a literal path would resolve against the file that instantiates it, so the path is a Qt.resolvedUrl, and
    // `source` is declared for Qt's built-in shader, which samples it and which the effect can hold before that binding lands.
    property var source: null
    vertexShader: Qt.resolvedUrl("../shaders/silicon_particles.vert.qsb")
    fragmentShader: Qt.resolvedUrl("../shaders/silicon_particles.frag.qsb")
    property vector4d cfgMesh: Qt.vector4d(4 * root._n - 1, root._n, root._kind, root.pass)
    property vector4d cfgView: Qt.vector4d(root.originX, root.originY, root.pxPerMm, root.family)
    // the time is wrapped so a session of hours keeps the float's resolution (the plume re-rolls
    // once every ~34 min, which a statistical cloud does not show)
    property vector4d cfgClock: Qt.vector4d(root.time % 2048, root.seed, root.width, root.height)
    property vector4d cfgLook: Qt.vector4d(root.dark ? 1 : 0, Math.max(1, root.renderScale), root.brightness, root.power)
    property vector4d cfgAnchor: Qt.vector4d(root.anchor[0], root.anchor[1], root.anchor[2], root.coneDeg * Math.PI / 180)
    property vector4d cfgDrive: {
        switch (root._kind) {
        case 0: return Qt.vector4d(root.energy, root.energyFloor, root.reachMin, root.reachMax);
        case 1: return Qt.vector4d(root.flowW, 0, root.pkgTurn, root.pkgLift);
        default: return Qt.vector4d(root.cardDissolve, root.cardLift, root._card.rest + root._card.pcb, 0);
        }
    }
    property vector4d cfgDrive2: Qt.vector4d(root.emitRadius, root.lifeS, 0, 0)
    property vector4d cfgCard: Qt.vector4d(root._card.x0, root._card.z0, root._card.x1, root._card.z1)
    property vector4d colNow: root._v(root.colour, 1)
    property vector4d colAux: root._v(root.chargeColour, 1)

    readonly property real _rad: Math.PI / 180
    property vector4d cfgPole0: Qt.vector4d(root.chargeKneeW, root.chargeWeak, root.chargeLifeMinusS, root.chargeAlpha)
    property vector4d cfgPole1: Qt.vector4d(root.chargeReachMinus, root.chargeReachPlus, root.chargeMouthMinus, root.chargeMouthPlus)
    property vector4d cfgPole2: Qt.vector4d(root.chargeNeck, root.chargeTwist, root.chargeOriginY, root.chargeSize)
    property vector4d cfgPole3: Qt.vector4d(root.chargeLeanMinus * root._rad, root.chargeLeanPlus * root._rad, root.chargeFloor, root.chargeEdge)
    property vector4d cfgPole4: Qt.vector4d(root.dischargeKneeW, root.dischargeWeak, root.dischargeLifeMinusS, root.dischargeAlpha)
    property vector4d cfgPole5: Qt.vector4d(root.dischargeReachMinus, root.dischargeReachPlus, root.dischargeRadiusMinus, root.dischargeTurnsMin)
    property vector4d cfgPole6: Qt.vector4d(root.dischargeTurnsMax, root.dischargeOriginY, root.dischargeSize, root.dischargeRadiusPlus)
    property vector4d cfgPole8: Qt.vector4d(root.chargeLifePlusS, root.dischargeLifePlusS, root.chargeOriginPlusY, 0)
    property vector4d cfgPole7: Qt.vector4d(root.dischargeLeanMinus * root._rad, root.dischargeLeanPlus * root._rad, root.dischargeFloor, root.dischargeEdge)
}
