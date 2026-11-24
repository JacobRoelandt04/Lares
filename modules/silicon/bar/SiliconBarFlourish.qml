pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"
import "SiliconFlourishLoad.js" as Load
import "SiliconGlyphPose.js" as Pose

// =============================================================================
// SiliconBarFlourish.qml -- THE PROFILE GLYPH'S FLOURISH (feedback/silicon.md "Bar icon flourish": a little icon flourish, the
// leaf flows in the wind, the scales tip, the bolt emits arcs; then "Flourish adjusments": the scales tip under a weight thrown from one
// pan to the other, the bolt's charge runs out and strikes in again). The host arms it (`armed`).
//
// EVENT-BOUND, not random: the flourish plays when something HAPPENS, so it never costs a frame the bar would not
// have drawn anyway, and it says why it is moving.
//   profile change     the glyph that lands plays its own motion (this file's `play("profile")`, called by the button)
//   the pointer        coming onto the profile glyph plays its motion (the user's rule for every glyph flourish): the
//                      button's one MouseArea finds the glyph under the pointer and feeds `glyphClock.pointerAt`, and the
//                      bar glyphs' one flourish clock (GlyphFlourish) plays it once per entry, never restarting a motion in progress
//   load, behind its own switch `loadEnabled`: a heavy session STARTS -> the glyph's motion, hard
//                      (`start`); one CLEARS -> the glyph's motion, gently (`clear`); the load SWINGS -> the glyph's motion
//                      (`swing`). SiliconFlourishLoad.js decides, from the readings fed to `load`.
// What the tree already plays, left alone: the charger going in or out, the pack reaching full or low -- the ring, the groove's
// tint, the colour's fade and (plug-in) the sparks. The GPU's side has a glyph of its own, with its own flourish (SiliconBarGpu).
//
// THE MOTIONS are those of the three glyphs, drawn as DEFORMED OUTLINES, not as moves of the whole glyph (which reads as stiff):
// the leaf bends to the wind, and the scales only tip where they should tip and do not bring the base with them. The font's outlines are checked in as data (SiliconGlyphParts.js, made by make_glyph_parts.py) and posed by
// SiliconGlyphPose.js from this file's clock; SiliconBarGlyph draws the pose in place of its Text while `playing`:
//   leaf    the blade bends along its length (a wave running up it, damped ~2 swings), the stem's foot stays put
//   scales  a weight swells in the left pan, is flicked over the pivot and lands in the right one, which drops under it and
//           stands tipped until the weight melts away; the base stands still, the pans hang from the beam's ends and swing late
//   bolt    its ink runs off downward and out through the lower tip, a new charge comes in at the upper tip and lands
//           hard: the bolt swells and bobs once; either stream's end is a point on the bolt's zigzag spine
// One clock: `u` 0..1 over the glyph's length, the bar glyphs' flourish clock (GlyphFlourish), which runs only while a flourish
// plays and holds still while the theme crossfades; an event while one plays starts it over (the glyph may be a new one). Every
// pose is the font's own outline at u = 0 and at u = 1, and at rest nothing is drawn, nothing asks for a frame.
//
// The host (SiliconBarFace) hands `playing`, `u` and `strength` to the glyph, and feeds `kind` and `load`. Nothing is drawn here.
// =============================================================================
Item {
    id: fl

    property bool armed: false
    property bool loadEnabled: true
    property int kind: 1                       // the glyph: 0 leaf (Quiet), 1 scales (Balanced), 2 bolt (Performance)
    property int ms: 900                       // the flourish's unit: each glyph runs its own share of it (Pose.time)
    property real load: 0                      // the CPU's load 0..1, reading by reading
    property var loadLook: ({})                // SiliconFlourishLoad.DEFAULTS' overrides

    signal played(string why)

    // ---- the one clock (it starts one turn after the ask: the profile's own handler asks before `kind` has followed it, and
    // the clock's length is the glyph's) ----
    // the clock itself (the button feeds its `pointerAt`; a harness holds it: tools/dev/qml/glyph_flourish_strip.qml)
    readonly property alias glyphClock: clock
    readonly property real u: clock.u
    property real strength: 1
    readonly property bool playing: clock.playing
    GlyphFlourish {
        id: clock
        host: fl
        armed: fl.armed
        ms: Math.round(fl.ms * Pose.time(fl.kind))
        overlap: "restart"
        // `why`: "profile" | "hover" | "start" | "clear" | "swing" -- the strength of the motion it plays
        onPlayed: why => {
            fl.strength = why === "start" ? 1.3 : (why === "clear" ? 0.65 : 1);
            fl.played(why);
        }
    }

    function play(why) {
        clock.play(why);
    }

    // ---- the load's events ----
    property var _st: Load.newState()
    onLoadChanged: {
        if (!fl.armed || !fl.loadEnabled)
            return;
        const ev = Load.step(fl._st, fl.load, Date.now(), fl.loadLook);
        if (ev !== "")
            fl.play(ev);
    }
    onArmedChanged: fl._st = Load.newState()
}
