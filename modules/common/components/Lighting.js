// =============================================================================
// Lighting.js
//
// One light, given the way a light is actually tuned.
//
// Every lit object in the shell -- the record, its sleeve, the turntable's
// spindle -- is lit by directions in VIEW space: x right, y up, z toward the
// eye. Nobody tunes a light by typing a unit vector, and a vector3d cannot be
// put on a slider, so each of them exposes the same two numbers instead: an
// ANGLE that sweeps the lamp around the object (0 is from the right, 90 from
// above) and an ELEVATION that lifts it out of the object's plane toward the
// camera. This turns that pair into the vector the shaders want.
//
// It lives here rather than in each component because two objects in one scene
// that disagree about where the room's lamp is read as a collage, and the only
// way to keep them agreeing is for them to build the direction the same way.
//
// Not a `.pragma library`: `Qt.vector3d` lives on the QML global object, which
// a shared library context does not have.
// =============================================================================

function dirOf(angleDeg, elevation) {
    const e = Math.max(-0.999, Math.min(0.999, elevation));
    const r = Math.sqrt(Math.max(0, 1 - e * e));
    const a = angleDeg * Math.PI / 180;
    return Qt.vector3d(Math.cos(a) * r, Math.sin(a) * r, e);
}
