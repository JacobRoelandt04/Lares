// =============================================================================
// particles_ubo.glsl -- the ONE uniform block of silicon_particles.vert and .frag. Both stages
// include this file, so they cannot disagree (Qt binds the same buffer to both and nothing checks
// it; tools/dev/shader_ubo_match.py does). ParticleField.qml writes every member by name.
//
// What the drive vectors hold depends on the emitter (cfgMesh.z):
//   0 sparks   cfgDrive  x energy 0..1, y energy floor (the sparks alive at no load), z reach
//                        min mm, w reach max mm
//              cfgDrive2 x emission disc radius mm, y mean life s
//   1 traces   cfgDrive  x flowW (> 0 charging, < 0 discharging), y -, z, w the package's turn rad and lift mm (what hides a spark)
//              (the pack's poles: the funnel and the swirl)
//   2 card     cfgDrive  x dissolve 0..1, y lift mm, z the PCB's top at rest (mm), w -
//
// The poles' tuning (traces only; ParticleField.qml's charge* / discharge* properties, which the mockup's Particles tab edits):
//   cfgPole0..3 the CHARGING field (the funnel), cfgPole4..7 the DISCHARGING one (the swirl)
//   cfgPole0 / 4  x density knee W (the watts at which 63 % of the slots live), y the weak pole's share of the density, z life (-) s, w alpha
//   cfgPole1      x reach (-) mm, y reach (+) mm, z mouth (-) mm, w mouth (+) mm          (funnel)
//   cfgPole2      x neck mm, y twist turns, z origin height (-) mm, w size (a scale on the width)
//   cfgPole5      x reach (-) mm, y reach (+) mm, z swirl radius (-) mm, w turns (fewest)  (swirl)
//   cfgPole6      x turns (most), y origin height mm, z size, w swirl radius (+) mm
//   cfgPole3 / 7  x lean (-) rad, y lean (+) rad, z alpha floor, w soft edge of the density gate
//   cfgPole8      x life (+) s of the charging field, y life (+) s of the discharging one, z the (+) funnel's origin height
// =============================================================================
layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;

    vec4  cfgMesh;     // x mesh rows (4N - 1), y N drawn, z emitter 0 sparks 1 traces 2 card, w pass (sparks: 0 behind the plane, 1 in front)
    vec4  cfgView;     // x, y board origin (item px), z px per mm, w family 0 Material 1 Blueprint
    vec4  cfgClock;    // x time s (wrapped), y seed, z item width px, w item height px
    vec4  cfgLook;     // x dark 0 / 1, y device px per item px, z brightness, w power-on 0..1
    vec4  cfgAnchor;   // xyz anchor mm (the die top for sparks, the card's centre), w cone half angle rad
    vec4  cfgDrive;
    vec4  cfgDrive2;
    vec4  cfgCard;     // the card's footprint: x0 z0 x1 z1 mm
    vec4  colNow;      // the colour every live particle shows (the scene eases it; a change recolours the plume in flight)
    vec4  colAux;      // traces: the charge colour

    vec4  cfgPole0;    // the poles' tuning: see the header
    vec4  cfgPole1;
    vec4  cfgPole2;
    vec4  cfgPole3;
    vec4  cfgPole4;
    vec4  cfgPole5;
    vec4  cfgPole6;
    vec4  cfgPole7;
    vec4  cfgPole8;
};
