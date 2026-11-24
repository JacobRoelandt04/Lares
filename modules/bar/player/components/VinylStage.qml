pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"
import "../../../common/components"

// =============================================================================
// VinylStage.qml
//
// The record, the sleeve, the platter, and everything they DO. VinylDisc knows
// what a record looks like and Turntable what a platter looks like; this knows
// that the record arrives INSIDE its sleeve, is left behind when the sleeve
// slides away, swivels to show itself off, comes down onto the spindle, turns
// with the music, flips at the half of an album, and is finally flung back
// into a sleeve that recoils.
//
// One clock per motion, as everywhere else in the shell:
//
//   spinDeg       integrated once per frame from ONE rate. While the record is
//                 on the platter that rate is the playback position's own
//                 derivative times 200 deg/s (33 1/3 rpm) -- the record's angle
//                 is the MUSIC, so scrubbing spins it and nothing has to be
//                 kept in sync with anything. What the position may NOT do is
//                 jump: the platter turns at its own speed, so a track change,
//                 a click on the rail and a re-seated clock are carried rather
//                 than turned, and only a hand on the ball (`scrubbing`) winds
//                 the record round faster than the music does.
//   _showT        the swivel, the rise toward the camera and the drop onto the
//                 platter are ONE 0..1 progress. The record is already coming
//                 down when the drop "starts", so there is no seam between
//                 showing itself off and being played -- they are one arc.
//   _flipT        the half-album flip is a single 0..1 progress read through
//                 one time warp, so the rise, the turns, the fall and the
//                 slow-motion at the top cannot drift apart.
//   _slideT       the sleeve's slide across the table: one progress from which
//                 both its travel and its rotation are read, because a sleeve
//                 that turns as it slows is one physical fact, not two
//                 animations.
//   sleeveY       not a clock either, and not a correction: the sleeve
//                 travels on ONE STRAIGHT LINE and the geometry that keeps
//                 the record inside its mouth is spent on the APPROACH'S
//                 ANGLE. See THE MOUTH IS ANSWERED WITH THE ANGLE.
//
// The record is HIDDEN INSIDE THE SLEEVE until the sleeve moves: the sleeve is
// bigger than the record it holds (a real one is 12.375" to a 12" record) and
// the record sits on the platter behind it, so it is uncovered geometrically,
// exactly where the sleeve no longer is, rather than faded in.
//
// The animations never touch playback. The one exception is at the very start:
// `holdPlaybackUntilDown` lets the drop finish before the module is told it
// may play, and that is reported by `sequenceFinished("start")`.
//
// The stage announces no impacts and throws no sparks: a landing is read off
// the landing.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // PUBLIC API
    // ======================================================================
    // The art is the HOST'S: it is bound, never assigned from in here. An
    // assignment would destroy that binding for good and the record would go
    // on showing a stale cover for the rest of the session -- a second
    // arrival would play with the previous album's art.
    property string albumArt: ""

    // What the module is doing. The stage never reads a player; it is told.
    property bool playing: false
    property real positionSec: 0
    property real durationSec: 0
    // True while a hand is dragging the position -- the viewfinder's ball.
    // It is the one thing that tells a SCRUB (the position moving because
    // somebody is moving it, continuously, frame by frame) from a JUMP (a
    // track change, a click on the rail, the service re-seating its clock off
    // a status read). The record follows the first and carries through the
    // second; see THE SPIN INTEGRATOR for why that is one rule and not two.
    property bool scrubbing: false

    // HOW FAR THROUGH THE ALBUM the record is, 0..1 by song count. It is the
    // host's number and the stage's only view of the queue: the record is
    // turned over for reasons READ OFF IT (see WHY A RECORD IS TURNED OVER),
    // so a host binds this and nothing else. A host that binds nothing gets no
    // flip, which is the right thing for a stage that is not playing an album.
    property real albumProgress: 0

    // Platter speed. A 12" LP runs at 33 1/3 rpm = 200 degrees a second, which
    // is also what makes a scrub across a three-minute track look violent and
    // a scrub across a twenty-minute one look calm -- correctly, because it is.
    property real rpm: 33.333
    readonly property real degPerSec: root.rpm * 6.0

    // How far a DRAGGED second of position turns the record, against the
    // platter's own speed. At 1 -- the record's angle being the position
    // exactly -- a drag across a three-minute track would spin it a hundred
    // times, which reads as a strobe rather than as a record being wound by hand. At
    // 0.2 a ten-second nudge is a little over one turn: enough to say "I moved
    // it", slow enough to watch. Nothing else is scaled: playback still turns
    // it at 33 1/3 rpm.
    property real scrubSpinScale: 0.2

    // The most position, in seconds per second of real time, that the music is
    // allowed to drag the record round. Playback advances the position by one
    // second per second, so the headroom above 1 is for the service re-seating
    // its clock forward; everything above it -- a track change's whole track,
    // a click on the rail, a mock run at four times speed -- is CARRIED
    // instead of turned. A record on a platter turns at 33 1/3 rpm and nothing
    // that happens to the playhead makes it turn faster, which is exactly why
    // a skip must not snap it round.
    property real positionCatchup: 1.6

    // A pause is not a motor cut: the wheel takes a moment to let go, and
    // another to take up again. It is not what a direct drive does either. The
    // slowdown when pausing and the run-up when resuming are THE SAME, so they
    // are one number, and the run-down's easing is the run-up's read backwards
    // (an InCubic against its OutCubic) rather than a curve of its own -- equal
    // milliseconds with unequal easings sweep 93 degrees one way and 62 the
    // other, which is not "the same" by the only measure the eye has.
    property real spinRunupMs: 620
    property real spinRundownMs: 620

    // Sequencing
    property bool holdPlaybackUntilDown: true
    readonly property string phase: root._phase

    // The platter under the record. The host's call: a module with nothing at
    // all to play shows no turntable either, and only the host knows that.
    property bool showTurntable: false

    // Geometry
    property real discSize: Math.min(root.width, root.height)

    // WHERE THE RECORD IS, in the stage's own coordinates.
    //
    // The stage is the record's CANVAS, not its box: everything the record
    // throws past its own silhouette -- its shadow above all -- is drawn by the
    // disc's shader inside the stage's item and cut off at its edge. So the
    // stage is given the whole card and the record a slot inside it, and the
    // two centres are not the same point. -1 means the stage's own middle,
    // which is what a stage sized to the record wants and what every harness
    // films; a host that hands the stage a card sets these to the middle of the
    // record's slot in it.
    //
    // Everything that has to agree with the record reads `recordCX`/`recordCY`
    // rather than half the width: the disc and its shadow, the platter and its
    // spindle, the sleeve that holds it and the sleeve's rest position. The
    // sleeve's ENTRANCES are the exception, and deliberately so -- "off the
    // right of the stage" is a fact about the stage, so a record placed
    // off-centre does not drag them around with it.
    property real recordCenterX: -1
    property real recordCenterY: -1
    readonly property real recordCX: root.recordCenterX < 0 ? root.width / 2 : root.recordCenterX
    readonly property real recordCY: root.recordCenterY < 0 ? root.height / 2 : root.recordCenterY
    // How far that is from the stage's own centre. It is exactly zero when the
    // record is centred, which keeps every placement below bit-for-bit the
    // same as for a record in the stage's middle.
    readonly property real _rdx: root.recordCX - root.width / 2
    readonly property real _rdy: root.recordCY - root.height / 2
    property real restHeight: 0          // px above the platter when playing
    // Heights are fractions of the record, not pixels: the same choreography
    // has to read at 118 px in `mini` and at 340 in `player`, and a fixed lift
    // is a shove at one size and a twitch at the other.
    property real liftFrac: 0.55         // the flip's apex
    readonly property real liftHeight: root.discSize * root.liftFrac

    // How much of `discSize` the record itself takes up. The rest of the box
    // is the room the record needs to grow into as it lifts toward the camera
    // -- the box is a layout slot, the record is what is drawn in it.
    //
    // It lives HERE and not on the disc because the disc's item is the
    // whole stage: what VinylDisc is given is the fraction that makes its own
    // item come out at this size, which is not a number anybody can tune.
    // ONE FRACTION PER VIEW, because the two views do not need the same room.
    // The headroom this leaves is for the lift toward the camera and for the
    // shadow; `mini` neither lifts as far nor throws as much, so the record can
    // stand nearer the edge of its box there and read bigger at the small size
    // where it needs the help.
    property real recordFrac: 0.78
    property real miniRecordFrac: 0.96
    // Which of the two applies. The host says which view it is in.
    property bool compact: false
    // How far between the two, 0 in the player and 1 in mini. A host that only
    // sets `compact` gets a step; one that eases a view switch
    // sets this too and the fraction travels with it. Kept BESIDE the bool and
    // not instead of it: the vinyl harnesses and the panel read `recordFrac`
    // and `miniRecordFrac` directly, and a host that knows nothing of a
    // transition must still get the right resting number.
    property real compactF: root.compact ? 1 : 0
    readonly property real _recordFrac:
        root.recordFrac + (root.miniRecordFrac - root.recordFrac)
        * Math.max(0, Math.min(1, root.compactF))

    // Whether the record's label actually has its art on it. Forwarded from the
    // disc so a check can assert the TEXTURE, not just the path: a white label
    // can sit under a correct `albumArt`.
    readonly property bool labelReady: disc.labelReady

    // The record as DRAWN, not the box it is drawn in. A sleeve sized to the
    // box instead of to the record would be a third bigger than the thing it
    // holds.
    readonly property real recordDiameter: root.discSize * root._recordFrac

    // How much bigger the sleeve is than the record it holds. A real 12" LP
    // goes into a 12.375" sleeve, which is this to three figures.
    property real sleeveOversize: 1.031

    // The record's height while it is being put away. It is a knob and not a
    // number because it decides the SLEEVE'S SIZE: the record is nearer the
    // camera when it is lifted and is therefore drawn bigger, and the sleeve
    // has to be able to swallow it at that size without the record shrinking
    // to fit -- so the sleeve is measured against the record AS FLUNG.
    property real putAwayLiftFrac: 0.12
    readonly property real putAwayLift: root.discSize * root.putAwayLiftFrac

    // The pinhole camera the record is drawn with sits `camDistFrac` radii in
    // front of the platter, so a record `h` px up is drawn this much bigger.
    function perspAt(h) {
        const cz = disc.discRadius * disc.camDistFrac;
        return cz / Math.max(1, cz - h);
    }

    // Sized to the record it must hold at its LARGEST -- plus the couple of
    // pixels the sleeve's own cut wanders by, since that ragged edge is drawn
    // inside the item's bounds and a record flush with them would show through
    // it.
    readonly property real sleeveSize: root.recordDiameter * root.perspAt(root.putAwayLift) * root.sleeveOversize + sleeve.edgeWear * 0.6

    // Where the sleeve comes to rest at the end, to the RIGHT of the record --
    // the record is flung into it, so it must be beside the record and still
    // fully on the stage. Whichever of those two is the tighter bound wins.
    readonly property real sleeveRestX: Math.min(root.recordDiameter * 0.55, Math.max(0, (root.width - root.sleeveSize) / 2 - root._rdx))

    // Where a sleeve waits off the stage, as a translate from the RECORD's
    // centre: the distance is the stage's own, so an off-centre record does not
    // drag the sleeve's entrances and exits around with it.
    function _offStageX(frac) {
        return root.width * frac - root._rdx;
    }

    signal sequenceFinished(string which)

    // ======================================================================
    // POSE, all written by the animations below
    // ======================================================================
    property real spinDeg: 0
    property real spinRate: 0            // deg/s, used when NOT position-driven
    property real discHeight: 0
    property real discX: 0
    property real discY: 0
    property real tiltX: 0
    property real tiltY: 0
    property real flipDeg: 0
    property real flipAxisDeg: 0
    property real discOpacity: 0

    property real sleeveX: 0
    property real sleeveY: 0
    property real sleeveRot: 0
    property real sleeveOpacity: 0
    property string sleeveArt: ""

    // ======================================================================
    // INTERNAL STATE
    // ======================================================================
    // "idle" nothing on stage -- "arriving" sleeve sliding in with the record
    // inside it -- "revealing" sleeve sliding off the record -- "showing" the
    // swivel and the rise -- "dropping" the same arc past its apex --
    // "playing" -- "flipping" -- "ending" -- "sleeving".
    property string _phase: "idle"
    property bool _positionDriven: false
    property real _lastPos: 0
    // Set for the one frame between the wheel reaching the platter's speed and
    // the music taking the record back off it. See the hand-back below.
    property bool _handBack: false
    // How fast the record is turning right now, measured by the integrator
    // rather than assumed: the music turns it at the platter's speed, a hand on
    // the ball turns it at the drag's, and a hand that has stopped moving turns
    // it not at all. It is what every hand-over to the rate integrator starts
    // from, which is what makes a hand-over invisible.
    property real _turnRate: 0
    property real _flipT: 0
    property real _flipFrom: 0
    property real _flipTo: 0

    // The variance the flip's axis wanders through: up to +-15 degrees off
    // the x axis, moving slowly, never the same twice, and never a jump.
    property real flipAxisVariance: 15

    // Multiplies every duration in every sequence. 1 is the choreography as it
    // ships; below 1 runs it faster (which is how a probe watches a whole
    // arrival inside a test's patience), above 1 slows it down (which is how a
    // person judges whether a sweep overshoots too far). It is one number
    // rather than a knob per animation, so the SHAPE of the choreography
    // cannot change when its speed does.
    //
    // It is read only when a segment STARTS: a QML animation's duration is
    // taken at that moment, so turning the dial mid-sweep changes the segments
    // after the current one, not the one you are watching.
    property real timeScale: 1.0
    readonly property real _ts: Math.max(0.02, root.timeScale)

    // Holds whichever sequence is running exactly where it is. The pose stays
    // put, the clock stops, and clearing it carries on from the same frame --
    // which is what makes it a pause rather than a stop.
    property bool sequencesPaused: false
    readonly property bool sequenceRunning: startAnim.running || flipAnim.running || endAnim.running || exitAnim.running

    implicitWidth: 320
    implicitHeight: 320

    // ======================================================================
    // THE SPIN INTEGRATOR
    //
    // The one place the record's angle is advanced. Position-driven while the
    // record is on the platter -- the music turns it -- and rate-driven while
    // it is being spun up, run down, or let go of at a pause.
    //
    // What it does NOT do is follow the position wherever it goes. A record on
    // a platter turns at 33 1/3 rpm, so the position may only turn it at that
    // speed and never backwards: a track change (the position falling by a
    // whole track), a click on the rail and the service re-seating its clock
    // off a status read are all CARRIED, which is what stops a skip snapping
    // the record round and what stops a pause nudging it a couple of degrees.
    // The one exception is a hand on the ball, which is continuous and is what
    // `scrubbing` says.
    // ======================================================================
    // Which way the record's own turn READS. A record that has been flipped is
    // being watched from its other side, so the same physical spin appears to
    // run backwards -- and a record that appears to run backwards on the
    // platter is the thing that gives the flip away. So the sign follows the
    // FACE. It can only change where cos(flipDeg) crosses zero, which is
    // exactly where the record is edge-on to the camera and its face cannot be
    // read at all: the reversal is not placed at a moment, it is placed at an
    // orientation, and there is no frame in which the record is seen to turn
    // the wrong way.
    readonly property real _faceSign: Math.cos(root.flipDeg * Math.PI / 180) >= 0 ? 1 : -1

    // HOW OFTEN THE RECORD'S ANGLE MOVES, in Hz. 0 -- the default -- means
    // EVERY FRAME, which is what a FrameAnimation gives.
    //
    // It is a knob and not a decision because the record's clock sets the
    // price of the whole popup. While it turns, the scene is dirty every
    // frame, so every other per-frame cost in the card is paid at the frame
    // rate -- and this machine's panel is 120 Hz, which is twice the bill of a
    // 60 Hz one for the same picture. Nothing about that is the record's
    // fault; it is simply the only thing here that animates continuously.
    //
    // What to judge it by is the DUST AND THE SCUFFING, not the label: they
    // are the highest-frequency detail on the disc and they are what sells the
    // spin. At 33 1/3 rpm the record turns 3.3 degrees a frame at 120 Hz and
    // 6.7 at 60, and a speck at the rim moves proportionally further each step.
    //
    // Below 60 the FrameAnimation is swapped for a Timer, because that is the
    // only way the number actually falls: a FrameAnimation CONSUMES frames and
    // will happily run at whatever rate the loop offers (measured: putting the
    // particle simulation on one takes its wakeups from 62 a second to 155). A Timer wakes at its own rate and dirties the scene then, and
    // only then.
    property real spinHz: 0

    // One condition, two clocks -- exactly one of which is ever running.
    //
    // HELD STILL WHILE THE THEME CROSSFADES, unless the record is an ISLAND. A light/dark
    // switch is a still picture of the frame before, faded out over the new palette, so a
    // record that keeps turning under it is two records for the length of the fade: the old
    // one frozen at the angle it had, the live one running on. So the record at rest on the
    // platter is cut OUT of the picture (`themeIsland`, a disc), turns on through the fade
    // and reflects a room that goes from the old palette to the new (VinylDisc's FadeColor).
    // Armed at the ask only for a record that is turning on the platter; anything else (a
    // sequence, a sleeve, a stopped record) stays in the picture and is held still for the
    // 420 ms, then takes up where it stopped (`_advanceSpin` re-seats `_lastPos` on every
    // step, so the playhead's 420 ms of progress is read as ONE step, at most
    // `positionCatchup` times the usual).
    readonly property bool _spinWanted:
        root.visible && (root._positionDriven || Math.abs(root.spinRate) > 0.01)
    readonly property bool _spinRunning: root._spinWanted && (!Theme.crossfading || themeIsland.armed)

    // The record as a hole in the theme switch's picture. Its disc is the DRAWN record minus the
    // rim (2 px: the lacquer's edge is shaded and its antialiasing is the picture's to keep).
    // Off = the record is held still through a switch like everything else (the host's choice; a probe's control).
    property bool islandEnabled: true
    readonly property bool islandArmed: themeIsland.armed
    ThemeIsland {
        id: themeIsland
        readonly property real _r: Math.max(0, root.recordDiameter * root.perspAt(root.discHeight) / 2 - 2)
        x: root.recordCX - themeIsland._r
        y: root.recordCY - themeIsland._r
        width: themeIsland._r * 2
        height: themeIsland._r * 2
        radius: themeIsland._r
        live: root.islandEnabled && root._spinWanted && root._phase === "playing" && !root.sequenceRunning
              && root.discOpacity > 0.99 && root.sleeveOpacity < 0.01
              && Math.abs(root.tiltX) < 0.01 && Math.abs(root.tiltY) < 0.01
              && Math.abs(root.discX) < 0.01 && Math.abs(root.discY) < 0.01
    }

    // The integration itself, shared, so the two clocks cannot drift apart in
    // what they DO -- only in how often they do it.
    function _advanceSpin(dt) {
        let adv = 0;                          // degrees this step
        if (root._positionDriven) {
            const dp = root.positionSec - root._lastPos;
            root._lastPos = root.positionSec;
            // A hand on the ball turns it, at its own ratio. Anything else
            // may only turn it as fast as the platter does -- and never
            // backwards -- so a jump is carried rather than integrated:
            // the same clamp that stops a track change snapping it round
            // stops the couple of degrees a re-seated clock would add.
            //
            // CARRIED MEANS "KEEPS TURNING", NOT "STOPS". A clamp of
            // `Math.max(dp, 0)` would hand the integrator a ZERO whenever the
            // position is not credible -- and a track change makes it not
            // credible exactly once: `elapsed` drops from the old song's length
            // to nought, so `dp` is a large negative and `_lastPos` is re-seated
            // on the line above before anything can spend it. The record would
            // then hold still for precisely one frame, every track change,
            // dropping 3.3 degrees at 60 Hz and 1.67 at 120 and never repaying
            // them. On a record whose dust and scuffing are what sell the spin,
            // one duplicated frame is a visible stutter.
            //
            // The live daemon is worse: MpdService's interpolator SATURATES at
            // the track's duration and nothing polls, so `dp` is zero for every
            // frame between the song ending and MPD's idle round-trip landing,
            // and the record would stand still for the whole window rather than
            // one frame of it.
            //
            // A record on a platter turns at 33 1/3 rpm whatever the playhead
            // is doing. So an incredible position yields the PLATTER's own
            // step (`dt`), which is what "carried" means, and which is also
            // what a pause hands over from (`_turnRate` below reads the same
            // number instead of halving on a dead frame).
            if (root.scrubbing) {
                adv = dp * root.scrubSpinScale * root.degPerSec;
            } else {
                // `dp > 0` is a playhead that moved forward: follow it, never
                // faster than `positionCatchup`. Anything else -- backwards, or
                // not moving at all while the music plays -- is the clock being
                // wrong about a record that is not.
                //
                // AND ONLY WHILE IT IS ACTUALLY PLAYING. `_retimeSpin` returns
                // early for any phase but `playing`/`flipping` -- a sequence
                // owns the spin while it runs -- so `_positionDriven` can still
                // be true through an arrival, a put-away or a reveal with
                // nothing playing at all. Carrying at the platter's rate there
                // would turn the record at full speed underneath a sequence
                // that is posing it, and the hand-over back to the plain spin
                // would show as a jump (a 1-2 frame stutter where the arrive
                // animation fades over into the general spinning). Not playing
                // means not turning.
                const carried = dp > 0 ? Math.min(dp, dt * root.positionCatchup)
                                       : (root.playing ? dt : 0);
                adv = carried * root.degPerSec;
            }
        } else {
            adv = root.spinRate * dt;
        }
        root.spinDeg += adv * root._faceSign;
        // What the record is ACTUALLY turning at, in deg/s: the rate a
        // pause has to let go FROM, whatever is driving it. Half the
        // difference per STEP is about 30 ms of memory at 60 steps a second --
        // long enough that a host whose clock only moves every third step
        // still reads as turning, short enough that a hand which stopped
        // moving a fifth of a second ago hands over nothing at all. It is a
        // fraction per step rather than a time constant, so at a lower
        // `spinHz` it simply remembers fewer, shorter-spaced steps.
        root._turnRate += (adv / dt - root._turnRate) * 0.5;
        if (root.spinDeg > 3.6e6 || root.spinDeg < -3.6e6)
            root.spinDeg = root.spinDeg % 360;
    }

    FrameAnimation {
        id: spinClock
        running: root._spinRunning && root.spinHz <= 0
        onTriggered: root._advanceSpin(Math.min(spinClock.frameTime, 0.1))
    }

    Timer {
        id: spinTick
        running: root._spinRunning && root.spinHz > 0
        repeat: true
        interval: Math.max(1, Math.round(1000 / Math.max(1, root.spinHz)))
        // Wall time between ticks, not the nominal interval: a Timer that is
        // late must still turn the record by the time that actually passed, or
        // the platter runs slow whenever the machine is busy -- and the whole
        // point of this knob is to be used on a machine that is busy.
        property real _last: 0
        onRunningChanged: spinTick._last = Date.now()
        onTriggered: {
            const now = Date.now();
            const dt = Math.min(Math.max(now - spinTick._last, 1) / 1000, 0.1);
            spinTick._last = now;
            root._advanceSpin(dt);
        }
    }

    // ======================================================================
    // WHAT DRIVES THE SPIN
    //
    // Three drives and one resolver. A scrub owns the angle outright, paused
    // or not, because the record's angle is the ball's. Playing hands it to
    // the position. A pause hands it to the rate integrator at the speed the
    // music was turning it and runs it down; resuming winds it back up and
    // hands it back. Everything that can change the answer calls this, so
    // there is one place that decides and no second state to keep in step --
    // and because the hand-over is always at the rate the record was already
    // turning at, none of it can move the record by a degree.
    // ======================================================================
    function _retimeSpin() {
        if (root._phase !== "playing" && root._phase !== "flipping")
            return;                               // a sequence owns the spin while it runs
        spinUp.stop();
        spinDown.stop();
        settleHold.stop();
        root._handBack = false;
        if (root.scrubbing) {
            root.spinRate = 0;
            root._lastPos = root.positionSec;
            root._positionDriven = true;
        } else if (root.playing) {
            if (root._positionDriven)
                root._lastPos = root.positionSec;  // already turning: nothing to wind up
            else
                spinUp.start();
        } else if (root._positionDriven || Math.abs(root.spinRate) > 0.01) {
            if (root._positionDriven)
                // At the rate it was turning, and never faster than the platter
                // turns it. Playing hands over the platter's own speed, because
                // that is what the music was doing; a hand that let go of a
                // still ball hands over nothing, and a hand that let go mid-drag
                // hands over the drag -- backwards too, if that is the way it
                // was being wound. Handing over the platter's speed regardless
                // would spin the record up half a turn after a drag it had
                // already stopped, with nothing playing.
                root.spinRate = Math.max(-root.degPerSec, Math.min(root.degPerSec, root._turnRate));
            root._positionDriven = false;
            spinDown.start();
        }
    }

    onPlayingChanged: root._retimeSpin()
    onScrubbingChanged: root._retimeSpin()

    // ======================================================================
    // WHO TURNS THE RECORD ONCE A SEQUENCE HAS PUT IT DOWN
    //
    // A sequence that ends with the record on the platter must not declare the
    // answer -- driven by the position, always -- because that is only true
    // while there is music. With nothing playing the integrator would run
    // anyway: a FrameAnimation at 60 Hz over a position that never moves, for
    // as long as the record sat there. It draws nothing (measured: 0.0 renders
    // a second either way), but a running animation is a running animation --
    // the process wakes 63 times a second for it, and on a compositor that is
    // what holds the render thread awake.
    //
    //   record on the platter, nothing playing,
    //   still position-driven                    62.8 wakeups/s
    //   the same with the drive handed back       1.1 wakeups/s
    //   the record switched off entirely          1.0 wakeups/s
    //
    // It is called AFTER `sequenceFinished`, never before: `holdPlaybackUntilDown`
    // makes that signal the thing that STARTS the music, so a drive resolved
    // ahead of it would always find nothing playing, stop a wheel that is about
    // to be needed, and wind it back up from zero under a record that never
    // stopped. Asked afterwards, a host that started the music is already
    // playing and this does nothing at all.
    //
    // A hand on the ball drives the record whether or not anything is playing,
    // which is why `scrubbing` is asked too.
    // ======================================================================
    // WHAT A SEQUENCE HANDS OVER WHEN NOTHING IS PLAYING: a run-down, never a
    // dead stop. An arrival drops the record at the platter's full speed -- so
    // if the daemon's play state has not landed yet (it arrives through an idle
    // round-trip, and with the LIVE source it can land a few frames after the
    // sequence ends), zeroing `spinRate` outright would take the wheel from
    // full speed to zero in one frame, and when `playing` did arrive `spinUp`
    // would wind it back up from zero: a seam between the arrival and the plain
    // spin, which shows only on a LIVE queue -- the signature of a race with
    // the daemon. Handing over at the rate the record is actually turning, the
    // way a pause does in `_retimeSpin`, makes a late `playing` a resume from
    // wherever the run-down has got to rather than a wind-up from nothing.
    //
    // AND NOT EVEN A RUN-DOWN STRAIGHT AWAY. The record lands at exactly
    // 200 deg/s and the music's first movement is frames later -- the play
    // state arrives through the host's own round-trip, whichever host it is --
    // so a run-down started at once takes the wheel down a few degrees a second
    // before `spinUp` winds it back: a tiny dip the eye can see. A record that
    // has just been LANDED spinning was put down to be played, so the platter's
    // speed is held for `landingHoldMs` before anything runs it down; a
    // `playing` that lands inside that window finds the wheel exactly where the
    // arrival left it, and the hand-over costs nothing at all.
    property int landingHoldMs: 900
    function _settleDrive() {
        if (root.playing || root.scrubbing)
            return;
        if (root._positionDriven)
            root.spinRate = Math.max(-root.degPerSec, Math.min(root.degPerSec, root._turnRate));
        root._positionDriven = false;
        if (Math.abs(root.spinRate) > 0.01)
            settleHold.restart();
    }
    Timer {
        id: settleHold
        interval: root.landingHoldMs
        repeat: false
        onTriggered: {
            // The music may have started in the meantime, or a pause may have
            // begun its own run-down; neither wants a second one.
            if (root.playing || root.scrubbing || spinDown.running)
                return;
            if (Math.abs(root.spinRate) > 0.01)
                spinDown.start();
        }
    }

    SequentialAnimation {
        id: spinUp
        NumberAnimation {
            target: root
            property: "spinRate"
            to: root.degPerSec
            duration: Math.round(root.spinRunupMs * root._ts)
            easing.type: Easing.OutCubic
        }
        ScriptAction {
            script: {
                // The wheel is at the platter's speed. The music takes the
                // record back on the first frame the music actually MOVES,
                // not here: `_lastPos` is already the position's latest value
                // (it is held there for exactly this moment while the wheel
                // drives), so an integrator that went position-driven now
                // would find nothing to turn the record by and it would stand
                // still for one whole frame at the instant it reached speed:
                // the hand-back frame would turn 0.000 degrees where every
                // frame around it turns 3.2.
                root._handBack = true;
            }
        }
    }

    NumberAnimation {
        id: spinDown
        target: root
        property: "spinRate"
        to: 0
        duration: Math.round(root.spinRundownMs * root._ts)
        // The run-up, backwards: the rate of an OutCubic read at 1 - u IS an
        // InCubic, so the wheel lets go exactly the way it took up and sweeps
        // the same 93 degrees doing it.
        easing.type: Easing.InCubic
    }

    onPositionSecChanged: {
        if (root._positionDriven)
            return;
        if (root._handBack) {
            // The music has moved. Take the record back FROM WHERE THE
            // POSITION WAS -- `_lastPos` is deliberately left where the
            // previous change put it -- so the integrator's next look finds a
            // whole frame of music to turn it by and the hand-over costs it
            // nothing.
            root._handBack = false;
            root._positionDriven = true;
            root.spinRate = 0;
            return;
        }
        root._lastPos = root.positionSec;
    }

    // ======================================================================
    // THE SLEEVE'S SLIDE
    //
    // A sleeve pushed across a smooth table does not overshoot its mark and
    // spring back: it decelerates to a stop under friction. So there is no
    // OutBack anywhere near it. `_slideT` is one linear clock and BOTH the
    // travel and the rotation are read off it, because they are one physical
    // fact: the table's imperfections get more of a hold on a slow sleeve than
    // on a fast one, so it turns further per pixel travelled as it settles.
    // ======================================================================
    property real _slideT: 0
    property bool _sliding: false
    property real _slideFromX: 0
    property real _slideToX: 0
    property real _slideFromRot: 0
    property real _slideToRot: 0
    // The three numbers `_fitSlide` solves for. They are the whole of what the
    // mouth costs: over which fraction of the slide the turn is spent, and the
    // row the sleeve rides at -- ONE row for the whole slide, so its path is a
    // straight line and can have no corner in it.
    property real _slideTurnEnd: 1
    property real _slideRow: 0

    // How long a slide takes. Slow enough to see it come to rest.
    property real sleeveSlideMs: 1050
    // Where a sleeve comes to REST, in degrees. Nothing pushed across a table
    // ends square with the world, so neither does this: each sleeve keeps this
    // much of the tilt it arrived with, which means the sign is the approach's
    // and not a second number -- the put-away comes in from the right turned
    // clockwise and settles clockwise, the arrival comes in from the left
    // turned anticlockwise and settles anticlockwise.
    property real sleeveSettleRot: 3
    // The friction law. 2 is ideal Coulomb friction -- a velocity falling
    // linearly to zero; above it the sleeve covers more of the distance early
    // and creeps the last of the way, which is what card on wood does.
    property real slideFriction: 2.4
    // How far the TURN lags the travel, 0..1. 0 turns it in step with the
    // slide; 1 is a turn that is only half done when the sleeve has covered
    // four fifths of its distance, so the last of it happens while the sleeve
    // is barely moving -- the table getting more of a hold on it as it slows.
    //
    // This is a shape, not the physical law, because the physical law is
    // invisible: with the turn proportional to v*(1 + grip*(1 - v)), 3.4% of
    // the rotation is left in the last 30% of the time over this slide -- half
    // a degree, which nobody can see. What reads is the lag.
    property real slideRotGrip: 0.75

    function _slideEase(u) {
        const x = 1 - Math.min(1, Math.max(0, u));
        return 1 - Math.pow(x, Math.max(1.01, root.slideFriction));
    }

    // The same slide, read as rotation: the travel's own curve pulled back
    // toward one that lags it. Both end with no rate at all, so the sleeve
    // stops turning as it stops moving rather than being cut off mid-turn.
    function _slideTurn(u) {
        const t = Math.min(1, Math.max(0, u));
        const g = Math.min(1, Math.max(0, root.slideRotGrip));
        const lag = t * t * t * (t * (t * 6 - 15) + 10);
        return root._slideEase(t) * (1 - g) + lag * g;
    }

    // The record travels WITH the sleeve on the way in, because it is inside
    // it. Without this the record waits in the middle of the stage for its own
    // sleeve to arrive and hide it, which is the same "visible from the start"
    // the reveal exists to avoid -- only more absurd.
    property bool _carryRecord: false

    // Where the slide has the sleeve at any point of its own progress -- not
    // only at the point it has reached. The mouth's placement reads them ahead
    // of itself, which is the whole of how it gets down without a step.
    function _slideXAt(u) {
        return root._slideFromX + (root._slideToX - root._slideFromX) * root._slideEase(u);
    }
    // The turn is spent over the FIRST `_slideTurnEnd` of the slide rather than
    // over all of it. A sleeve carrying its record has no reason to hurry and
    // gets the whole slide (the fit returns 1); a sleeve arriving beside a
    // record has to be done turning before its mouth closes over it, and the
    // fit is what works out when that is.
    function _slideRotAt(u) {
        return root._slideFromRot + (root._slideToRot - root._slideFromRot) * root._slideTurn(u / Math.max(0.05, root._slideTurnEnd));
    }

    function _applySlide(u) {
        root.sleeveX = root._slideXAt(u);
        root.sleeveY = root._slideRow;
        root.sleeveRot = root._slideRotAt(u);
        if (root._carryRecord)
            root.discX = root.sleeveX;
    }

    // ======================================================================
    // THE MOUTH IS ANSWERED WITH THE ANGLE
    //
    // A sleeve arrives TURNED, and a turned sleeve covers less of a circle
    // lying off to its left than a square one does: the record sits `a` from
    // the sleeve's own centre along its axis, so a tilt of `th` carries it
    // `a * sin(th)` off the sleeve's centre line, and the mouth has only
    // `half - reach(a)` to give. The sleeve is a real 12.375" to a real 12" --
    // three per cent -- so once the chewed rim has taken its guard the whole
    // margin is six and a half pixels at the popup's own size and one and a
    // half in mini, and an arrival tilt that spends all of it shows the record
    // BELOW the sleeve's lower edge (ten pixels of it, through the whole
    // arrival).
    //
    // THE COVERING IS NOT PAID FOR IN TRANSLATION. Putting the row wherever the
    // covering asks for, led and smoothed so that it arrives without a step, is
    // 36 px down and 36 px back up on a 527 px stage, which is a dive and a
    // climb. It is not a corner that can be rounded off; it is a detour, and
    // the only way to have no detour is to need none.
    //
    // So the covering is solved for the ANGLE, which is the variable it is
    // actually about, and the sleeve's path is a straight line. Three
    // numbers come out of `_fitSlide`, once, when a slide begins:
    //
    //   the rest tilt   `a * sin(th) <= half - reach(a)` read at the meanest
    //                   `a` the slide reaches. That is `a = half`, where the
    //                   record's centre is level with the mouth's own plane:
    //                   there the record spans the mouth's full width and all
    //                   that is left is the three per cent the sleeve is bigger
    //                   by, which bounds the rest tilt at 1.7 degrees. It is
    //                   the sleeve's own proportions talking, not a taste --
    //                   a sleeve cannot lie further off square than that and
    //                   still hold its record.
    //   the turn's end  the sleeve has to be DONE turning by the time its mouth
    //                   is over the record, so the turn is spent over the first
    //                   part of the slide and the rest of it is a straight
    //                   push home. What is left to watch is the bigger half:
    //                   the sleeve still enters the stage at ten degrees.
    //   the row         whatever the first two could not cover, which is zero
    //                   at both geometries this ships at. It is the guarantee
    //                   rather than the mechanism, and it is ONE number for the
    //                   whole slide, so the path cannot bend at all.
    //
    // Only the two LONG edges are answered. The record is never to the left of
    // the sleeve's closed side in any sequence, and the open side is the one it
    // is allowed to show out of.
    // ======================================================================
    property real mouthGuard: 2.0        // px of its own edge the chewed rim eats
    // How much of the tilt the mouth allows the sleeve to actually take at
    // rest. Every pixel of the margin spent on the angle is a pixel the record
    // has not got when it is fired in afterwards, so the fit keeps a fifth of
    // it back.
    property real mouthTiltSafety: 0.8
    // Where the turn ends, against the moment the record's centre reaches the
    // mouth's plane. 1 finishes it exactly there; below 1 finishes it early,
    // which is the same thing said with a margin. Above 1 the sleeve is still
    // turning while the mouth is closing over the record, which puts a kink in
    // its path.
    property real mouthTurnFrac: 0.9
    // The most the sleeve may ride off the record's own line, as a fraction of
    // the record, when the angle alone cannot cover it. It is a backstop for a
    // geometry this was not measured at; at the popup's and at mini's it is
    // never called on and the sleeve rides at exactly zero. 0 takes the
    // backstop away.
    property real mouthRideFrac: 0.06

    // One edge of the band of rows that keep the record inside the mouth, for a
    // sleeve at `sx` turned `rot`: `side` +1 is the lowest row that does, -1 the
    // highest. In the WORLD and not across the sleeve -- the constraint is
    // measured across the sleeve, so it is divided by the cosine to be spent
    // along the screen's own vertical.
    function _mouthLimit(sx, rot, side) {
        const th = rot * Math.PI / 180;
        const c = Math.cos(th), s = Math.sin(th);
        // The record's centre in the sleeve's own frame, with the sleeve at the
        // row it would take with no correction at all. On the way in the record
        // is INSIDE the sleeve and travels at its centre.
        const ax = (root._carryRecord ? sx : root.discX) - sx;
        const ay = root.discY;
        const lx = ax * c + ay * s;
        const ly = -ax * s + ay * c;
        const half = root.sleeveSize * 0.5 - root.mouthGuard;
        const rec = root.recordDiameter * root.perspAt(root.discHeight) * 0.5;
        // How far the record reaches across the sleeve, counting only the part
        // of it that is inside the mouth: everything past the open edge is out
        // in the room and belongs there.
        const d = -half - lx;
        if (d >= rec)
            return side > 0 ? -Infinity : Infinity;   // not in the mouth at all: no constraint
        const reach = d <= 0 ? rec : Math.sqrt(Math.max(0, rec * rec - d * d));
        return (ly - side * (half - reach)) / Math.max(0.2, c);
    }

    // How far the record is from the sleeve's centre ALONG the sleeve's axis at
    // a point of the slide. It is zero for the whole arrival -- there the
    // record travels at the sleeve's own centre -- which is why the fit hands
    // the arrival back its full tilt and the whole slide to spend it over.
    function _slideAlongAt(u) {
        return root._carryRecord ? 0 : Math.abs(root._slideXAt(u) - root.discX);
    }

    // Solve the approach from the covering condition. Called once per slide,
    // before its first frame, and it writes the three numbers the slide is then
    // read from -- so nothing here runs while the sleeve is moving and the
    // sleeve's path is a straight line with a fixed angle law on it.
    function _fitSlide() {
        const N = 48;
        const half = root.sleeveSize * 0.5 - root.mouthGuard;
        const rec = root.recordDiameter * root.perspAt(root.discHeight) * 0.5;

        // 1. THE REST TILT. `half - reach(a)` is at its meanest at a = half, so
        //    the tightest moment of the slide is whichever `a` it reaches
        //    nearest that -- and using the record's full radius for the reach
        //    there is the pessimistic reading of the ones either side of it.
        let aMin = Infinity, aMax = 0;
        for (let i = 0; i <= N; ++i) {
            const a = root._slideAlongAt(i / N);
            aMin = Math.min(aMin, a);
            aMax = Math.max(aMax, a);
        }
        const aTight = Math.min(aMax, Math.max(aMin, half));
        const room = aTight > 1e-3 ? (half - rec) / aTight : 1;
        const lim = Math.asin(Math.min(1, Math.max(0, room))) * 180 / Math.PI * Math.max(0, root.mouthTiltSafety);
        root._slideToRot = (root._slideToRot < 0 ? -1 : 1) * Math.min(Math.abs(root._slideToRot), lim);

        // 2. THE TURN'S WINDOW. Where along the slide the record's centre
        //    reaches the mouth's plane. A slide that never brings it there --
        //    every arrival -- keeps the whole of itself to turn in.
        let cross = 1;
        for (let i = 1; i <= N; ++i) {
            const a0 = root._slideAlongAt((i - 1) / N);
            const a1 = root._slideAlongAt(i / N);
            if ((a0 - half) * (a1 - half) <= 0 && a0 !== a1) {
                cross = ((i - 1) + (a0 - half) / (a0 - a1)) / N;
                break;
            }
        }
        root._slideTurnEnd = Math.min(1, Math.max(0.15, cross * root.mouthTurnFrac));

        // 3. WHAT IS LEFT. The covering condition read again against the angle
        //    the first two just fixed, which is the only honest way to know
        //    they were enough. Zero at both geometries this ships at.
        let need = 0;
        for (let i = 0; i <= N; ++i) {
            const u = i / N;
            need = Math.max(need, root._mouthLimit(root._slideXAt(u), root._slideRotAt(u), 1));
        }
        root._slideRow = Math.min(Math.max(0, need), root.recordDiameter * root.mouthRideFrac);
    }

    // ======================================================================
    // THE EXIT, AND WHERE THE STAGE IS HANDED OVER
    //
    // The sleeve leaving is not part of the slide -- it does not settle under
    // friction, it accelerates away -- so it has its own progress, and it is
    // its own progress rather than two NumberAnimations because of WHERE THE
    // HAND-OVER IS.
    //
    // `sequenceFinished("armed")` is the moment the host may bring the next
    // record in, and the stage has ONE sleeve: the arrival takes it over
    // wherever the exit has got to. Announcing it on the exit's first frame,
    // with the sleeve still whole and parked beside the platter, would make the
    // next arrival begin by teleporting that sleeve off the left, cutting the
    // put-away short. Two sleeves cannot cross when there is only one of them.
    //
    // So the signal is placed at the fraction of the exit at which THE SLEEVE
    // HAS LEFT THE STAGE, solved off the exit's own curve before its first
    // frame is drawn. There is nothing of the old record left to see, so the
    // arrival taking the sleeve over cannot be seen either.
    property real _exitT: 0
    property bool _exiting: false
    property real _exitFromX: 0
    property real _exitToX: 0
    property real _exitFromRot: 0
    property real _exitToRot: 0
    property real _exitArmedT: 1
    // How long the sleeve takes to leave.
    property real sleeveExitMs: 560
    // How much of the sleeve may still be showing when the next record is
    // called for, as a fraction of the sleeve's own width. 0 hands over when
    // the sleeve is off the scene, then the next one comes; 1 hands over on the
    // exit's first frame.
    property real handoverOverlap: 0

    // How much of the sleeve is on the stage, 0..1: the span of the turned card
    // that falls inside the stage's own width, over its whole span. It is the
    // hand-over's proof, so it is public and read at the pose rather than
    // computed from the clock -- the same way the mouth's two margins are.
    function _sleeveOnStageAt(x, rotDeg) {
        const th = rotDeg * Math.PI / 180;
        const half = root.sleeveSize * 0.5 * (Math.abs(Math.cos(th)) + Math.abs(Math.sin(th)));
        const c = root.recordCX + x;
        const vis = Math.min(root.width, c + half) - Math.max(0, c - half);
        return Math.min(1, Math.max(0, vis / Math.max(1, 2 * half)));
    }

    // The exit's two curves, written out rather than eased by the animation, so
    // that the progress can be SPLIT at the hand-over without the split
    // changing the shape: a linear clock through a cubic (the travel) and a
    // quadratic (the turn).
    function _exitXAt(u) {
        const t = Math.min(1, Math.max(0, u));
        return root._exitFromX + (root._exitToX - root._exitFromX) * t * t * t;
    }
    function _exitRotAt(u) {
        const t = Math.min(1, Math.max(0, u));
        return root._exitFromRot + (root._exitToRot - root._exitFromRot) * t * t;
    }
    function _applyExit(u) {
        root.sleeveX = root._exitXAt(u);
        root.sleeveRot = root._exitRotAt(u);
        // Only when the record never came out of it: an arrival called off
        // mid-slide leaves on the same straight line it came in on, with its
        // record still inside.
        if (root._carryRecord)
            root.discX = root.sleeveX;
    }

    function _beginExit(toX, toRot) {
        root._exitFromX = root.sleeveX;
        root._exitToX = toX;
        root._exitFromRot = root.sleeveRot;
        root._exitToRot = toRot;
        // Where the sleeve is gone, read off the curve the exit is about to be
        // drawn from rather than assumed from its duration: it is the first
        // sample at which no more of the sleeve is on the stage than the
        // hand-over allows.
        let t = 1;
        const N = 64;
        for (let i = 0; i <= N; ++i) {
            const u = i / N;
            if (root._sleeveOnStageAt(root._exitXAt(u), root._exitRotAt(u)) <= root.handoverOverlap) {
                t = u;
                break;
            }
        }
        root._exitArmedT = Math.min(1, Math.max(0, t));
        root._exitT = 0;
        root._exiting = true;
        root._applyExit(0);
        exitAnim.restart();
    }

    on_ExitTChanged: if (root._exiting)
        root._applyExit(root._exitT)

    function _beginSlide(fromX, toX, fromRot, toRot) {
        root._slideFromX = fromX;
        root._slideToX = toX;
        root._slideFromRot = fromRot;
        root._slideToRot = toRot;
        root._slideTurnEnd = 1;
        root._slideRow = 0;
        root._slideT = 0;
        root._sliding = true;
        // The angle and the row are solved BEFORE the first frame is placed:
        // the fit reads `_slideToRot` and writes it back capped, and the row it
        // works out is the one the whole slide is drawn at.
        root._fitSlide();
        root._applySlide(0);
    }

    on_SlideTChanged: if (root._sliding)
        root._applySlide(root._slideT)

    // ======================================================================
    // THE ARRIVAL'S ARC
    //
    // The swivel, the rise toward the camera and the drop onto the platter are
    // ONE quantity, not three animations in a row. The record leaves the
    // platter as it starts turning on its own axes, is closest to the camera
    // in the middle of the swivel, and is already coming down when the last
    // quarter of the swivel is still running -- so the drop has no beginning
    // of its own to give it away.
    // ======================================================================
    property real _showT: 0
    property real showMs: 3200           // the whole swivel-and-drop
    property real showTurns: 1.5         // how many times the swivel goes round
    property real showTiltAmp: 22        // degrees off the view plane at its widest
    property real showPeakFrac: 0.20     // how close to the camera it comes, of its own size
    // Where in the arc the record is nearest the camera. Past the middle,
    // because the record should start going away again closer to the final
    // quarter of the swivel -- and because the swivel itself ends before the
    // arc does, that lands at about three quarters of the swivel proper, with
    // the rest of the descent being the drop.
    property real showApexFrac: 0.62
    // How much of the arc the SWIVEL occupies. The last of the arc is the
    // record already on its way down and no longer turning on its own axes:
    // one continuous descent that becomes the drop, rather than a drop with a
    // beginning of its own.
    property real showTiltEndFrac: 0.85
    // How far into the sleeve's exit the swivel starts. The record is uncovered
    // from its left edge, so it can begin to show itself well before the sleeve
    // has left the stage, since it is revealed rather than faded in.
    property real showStartFrac: 0.45
    // Where in the arc the platter takes the record: on the way down, so the
    // spin is already at speed when it lands rather than starting there. The
    // record begins to turn while the swivel is still going, which stops the
    // spin reading as a separate event bolted to the end of the swivel.
    property real spinupStartFrac: 0.42

    readonly property real showPeak: root.restHeight + root.discSize * root.showPeakFrac

    // 0 on the platter, 1 at the top of the arc, 0 again on the platter.
    function _arc(u) {
        const a = Math.min(0.95, Math.max(0.05, root.showApexFrac));
        const t = Math.min(1, Math.max(0, u));
        if (t <= a) {
            // Smootherstep: it leaves the platter without a jerk and arrives at
            // the apex with no speed to reverse.
            const x = t / a;
            return x * x * x * (x * (x * 6 - 15) + 10);
        }
        // Gravity, then a cushion: the fall accelerates away from the apex and
        // is still decelerating when it lands, which is what a hand setting a
        // record down does and what a free fall does not.
        const x = (t - a) / (1 - a);
        return 1 - x * x * (2 - x);
    }

    on_ShowTChanged: {
        if (root._phase !== "showing" && root._phase !== "dropping")
            return;
        const u = root._showT;
        root.discHeight = root.restHeight + (root.showPeak - root.restHeight) * root._arc(u);
        // The swivel is a cone, not two crossing rocks: the record's normal
        // goes round `showTurns` times inside an envelope that is nothing at
        // both ends, so it starts flat, is at its most turned where it is
        // nearest the camera, and lands flat without being told to.
        const sw = Math.min(1, u / Math.max(0.05, root.showTiltEndFrac));
        const env = Math.sin(Math.PI * sw);
        const ph = 2 * Math.PI * root.showTurns * sw;
        root.tiltX = root.showTiltAmp * env * Math.sin(ph);
        root.tiltY = -root.showTiltAmp * env * Math.cos(ph);
        if (root._phase === "showing" && u > root.showApexFrac)
            root._phase = "dropping";
    }

    // ======================================================================
    // THE FLIP'S TIME WARP
    //
    // One monotone remap of the flip's progress. Its derivative is the flip's
    // SPEED, so writing the speed profile and integrating it is the only way
    // to get "everything slows down together at the top" without a second
    // clock: rise, spin and fall all read the same warped progress.
    //
    //   base      accelerate out of the platter and settle back into it, with
    //             a WIDE ramp at each end -- the record is next to the platter
    //             there and must not snap into the turn or out of it
    //   slow      a plateau where the record is nearest the camera, entered
    //             and left gradually
    //
    // The slow-motion window is given in MILLISECONDS rather than as a
    // fraction of the flip, because a duration is what the eye judges and
    // because it then keeps its timing when the flip's duration changes.
    //
    // WHERE THE WINDOW GOES IS NOT A NUMBER OF MILLISECONDS. The slow motion is
    // the one moment of the flip the eye can actually read the record in, and
    // the record's own angle there is whatever the warp happens to integrate
    // to -- so a tweak to any of these knobs slides the record's face round
    // under the moment it is held up for. Widening the shoulders alone moves
    // the held apex from 745 degrees to 801: a hairline, edge-on record at the
    // slowest, highest instant of the whole flip, with the spin's own direction
    // change (which can only happen edge-on) dragged into the slow motion with
    // it.
    //
    // So the window is PLACED AGAINST THE RECORD, not against the clock. The
    // start above is nominal; the placement slides it to the nearest moment at
    // which the record has turned a WHOLE number of times since the flip began.
    // That is the one orientation that satisfies both halves of the requirement
    // at once: the record is face-on where it is held up (a whole turn is a
    // face), it is showing the same face -- and therefore turning the same way
    // -- as it was on the platter, and the edge-on crossings, where the spin's
    // direction reverses, are half a turn away in either direction, which is as
    // far into fast motion as they can be put.
    //
    // Integrated once at load into a lookup table; sampling it is two array
    // reads and a lerp.
    // ======================================================================
    property real flipMs: 3200              // the whole flip
    property real flipSlowFactor: 0.075     // speed at the apex, as a fraction
    property real flipSlowStartMs: 1080     // where the slow motion is asked for
    property real flipSlowMs: 942           // and how long it lasts
    // How gradually the slow motion is entered and LEFT, and they are not the
    // same number. Going in reads better than coming out at any width -- the
    // eye is following a record that is arriving somewhere -- so the way out
    // gets the wider curve and the bigger share of the change (230 in, 420
    // out).
    property real flipSlowEdgeInMs: 230
    property real flipSlowEdgeOutMs: 420
    property real flipEndEase: 0.4         // how wide the ramp at each END is
    // Whether the window is placed against the record's orientation at all.
    // False leaves it at the nominal millisecond.
    property bool flipApexOnFace: true
    property var _warpTable: []
    // Where the window ACTUALLY starts, once it has been placed. Written by the
    // placement, never set: `flipSlowStartMs` is the nominal one.
    property real _slowStartMs: 1080

    // The speed profile, integrated, for a window starting at `slowStart`.
    function _warpTableFor(slowStart) {
        const N = 256;
        const v = new Array(N + 1);
        const lo = Math.max(0, Math.min(1, slowStart / Math.max(1, root.flipMs)));
        const hi = Math.max(lo, Math.min(1, (slowStart + root.flipSlowMs) / Math.max(1, root.flipMs)));
        const eIn = Math.max(root.flipSlowEdgeInMs / Math.max(1, root.flipMs), 1e-4);
        const eOut = Math.max(root.flipSlowEdgeOutMs / Math.max(1, root.flipMs), 1e-4);
        const ew = Math.max(1e-3, root.flipEndEase);
        for (let i = 0; i <= N; ++i) {
            const t = i / N;
            // Accelerate away, decelerate back: zero speed at both ends is
            // what stops the record from snapping out of the platter, and the
            // two smoothsteps widen that into a ramp you can watch.
            let base = Math.pow(Math.sin(Math.PI * t), 0.55);
            const r0 = Math.min(1, t / ew), r1 = Math.min(1, (1 - t) / ew);
            base *= r0 * r0 * (3 - 2 * r0) * r1 * r1 * (3 - 2 * r1);
            // The plateau: full speed outside [lo, hi], the slow factor
            // inside it, and its two shoulders are different widths.
            const d = t < lo ? (lo - t) / eIn : (t > hi ? (t - hi) / eOut : 0);
            let inWell = 1.0 - Math.min(1, Math.max(0, d));
            inWell = inWell * inWell * (3 - 2 * inWell);
            const slow = 1.0 - (1.0 - root.flipSlowFactor) * inWell;
            v[i] = Math.max(base * slow, 1e-4);
        }
        const s = new Array(N + 1);
        s[0] = 0;
        for (let i = 1; i <= N; ++i)
            s[i] = s[i - 1] + 0.5 * (v[i] + v[i - 1]);
        const total = s[N];
        for (let i = 0; i <= N; ++i)
            s[i] /= total;
        return s;
    }

    function _sampleTable(tab, t) {
        if (!tab || tab.length < 2)
            return t;
        const N = tab.length - 1;
        const x = Math.min(Math.max(t, 0), 1) * N;
        const i = Math.min(N - 1, Math.floor(x));
        const f = x - i;
        return tab[i] * (1 - f) + tab[i + 1] * f;
    }

    // The progress the record has reached at the middle of the window -- which
    // is where it is held highest, and therefore the angle the whole flip is
    // judged on.
    function _apexOf(tab, slowStart) {
        return root._sampleTable(tab, Math.min(1, (slowStart + root.flipSlowMs * 0.5) / Math.max(1, root.flipMs)));
    }

    function _buildWarp() {
        let start = root.flipSlowStartMs;
        let tab = root._warpTableFor(start);
        let apex = root._apexOf(tab, start);
        const hiStart = Math.max(0, root.flipMs - root.flipSlowMs);
        // A whole turn of the record is 1 / flipTurns of the flip's progress,
        // so the faces the record can be held up on -- showing the SAME side it
        // left the platter on -- are the multiples of that. Take the nearest
        // one that is actually reachable.
        //
        // A flip of ONE TURN OR LESS has none: its only whole turns are its two
        // ends, and the one face a half turn offers on the way is the record's
        // other side, which is the face that would put the spin's direction
        // change inside the slow motion rather than half a turn away from it.
        // So there is nothing to slide to and the nominal placement stands --
        // including at the bottom of the panel's range (0.5). Clamping into an
        // empty bracket instead of bailing here would put the whole slow-motion
        // window at t = 0 of the flip: the record would slow down as it left
        // the platter, and the arc's apex and the window's centre -- the same
        // instant by construction -- would be two thirds of the flip apart.
        let target = -1;
        if (root.flipApexOnFace && root.flipTurns > 0.01) {
            // Where the apex can be PUT AT ALL: the window's start runs from
            // the beginning of the flip to as late as the window still fits
            // inside it, and the apex rises with the start, so those two ends
            // are the whole reachable range. It is read from the warp itself
            // rather than assumed, because every knob above moves it.
            const aLo = root._apexOf(root._warpTableFor(0), 0);
            const aHi = root._apexOf(root._warpTableFor(hiStart), hiStart);
            const step = 1 / root.flipTurns;
            let best = 1e9;
            for (let k = 1; k * step < 1; ++k) {
                const cand = k * step;
                if (cand < aLo || cand > aHi)
                    continue;
                if (Math.abs(cand - apex) < best) {
                    best = Math.abs(cand - apex);
                    target = cand;
                }
            }
        }
        if (target > 0) {
            // Later start, more progress before it, so the apex rises with the
            // start and one bisection finds it.
            let lo = 0, hi = hiStart;
            for (let i = 0; i < 16; ++i) {
                const mid = (lo + hi) * 0.5;
                if (root._apexOf(root._warpTableFor(mid), mid) < target)
                    lo = mid;
                else
                    hi = mid;
            }
            start = (lo + hi) * 0.5;
            tab = root._warpTableFor(start);
            apex = root._apexOf(tab, start);
        }
        root._warpTable = tab;
        root._slowStartMs = start;
        root._flipApexS = apex;
    }

    function warp(t) {
        return root._sampleTable(root._warpTable, t);
    }

    Component.onCompleted: root._buildWarp()
    onFlipMsChanged: root._buildWarp()
    onFlipSlowFactorChanged: root._buildWarp()
    onFlipSlowStartMsChanged: root._buildWarp()
    onFlipSlowMsChanged: root._buildWarp()
    onFlipSlowEdgeInMsChanged: root._buildWarp()
    onFlipSlowEdgeOutMsChanged: root._buildWarp()
    onFlipEndEaseChanged: root._buildWarp()
    onFlipTurnsChanged: root._buildWarp()
    onFlipApexOnFaceChanged: root._buildWarp()

    // The flip reads the warped progress for everything at once.
    readonly property real _flipS: root.warp(root._flipT)
    property real flipTurns: 2.5            // 900 degrees: it lands on side B

    // The angle the flip STARTS from. A record that has already been flipped is
    // lying on side B at 180 degrees, and a flip that began at 0 would turn it
    // back to side A in one frame -- an instant reversal of everything the eye
    // reads off the face, spin included, right at the trigger. So a flip turns
    // `flipTurns` x 360 degrees FROM WHERE THE RECORD IS, and lands a half turn
    // on from there.
    property real _flipBase: 0

    // The record is highest where the slow motion is, not at the middle of the
    // flip: the window is not symmetric, and the apex has to follow it or
    // the record would be on its way down through the moment it is meant to be
    // held up for. It is the warped progress at the window's OWN centre, so the
    // two are the same instant by construction -- written by `_buildWarp`,
    // which is where the window's place is decided.
    property real _flipApexS: 0.5

    // 0 on the platter, 1 at the apex, 0 back on the platter -- with the apex
    // wherever `a` says. At a = 0.5 this is exactly sin(pi * s).
    function _flipRise(s, a) {
        if (a <= 0.02 || a >= 0.98)
            return Math.sin(Math.PI * s);
        const x = s <= a ? s / a : (1 - s) / (1 - a);
        return Math.sin(Math.PI * 0.5 * Math.min(1, Math.max(0, x)));
    }

    on_FlipSChanged: {
        if (root._phase !== "flipping")
            return;
        const s = root._flipS;
        root.flipDeg = root._flipBase + 360 * root.flipTurns * s;
        // Rise and fall on the same warped clock, so the apex of the arc and
        // the slow-motion are the same instant by construction.
        root.discHeight = root.restHeight + (root.liftHeight - root.restHeight) * root._flipRise(s, root._flipApexS);
        // The axis wanders slowly across the flip rather than being picked
        // once: a straight interpolation over the whole 0..1 is as slow as it
        // can be, and never repeats because the ends are drawn per flip.
        root.flipAxisDeg = root._flipFrom + (root._flipTo - root._flipFrom) * s;
    }

    // ======================================================================
    // THE PIECES
    // ======================================================================
    // The record's own material, the sleeve's wear and the platter's dressing
    // are theirs, not the stage's: a panel that wants to tune them reaches
    // them through these rather than through fifty pass-through properties.
    readonly property alias disc: disc
    // The platter, so a panel can reach its own knobs one hop rather than two.
    readonly property alias platter: platter
    readonly property alias sleeve: sleeve
    readonly property alias turntable: platter

    // The platter, and the spindle the record is dropped onto.
    property real platterFrac: 0.94         // of the record's diameter
    // Spindle height, of the record's diameter. Nothing draws the pin's length
    // from above -- what shows it is the SHADOW it lays across the mat, and a
    // longer pin's shadow (0.075) reads as a rod rather than as a spindle.
    property real pinLengthFrac: 0.064
    property real pinShadowStrength: 0.55   // of the spindle, on the label
    // Public and readonly: a host that has to place anything against the
    // spindle needs the two numbers the pin is drawn from.
    readonly property real pinLength: root.recordDiameter * root.pinLengthFrac
    // Measured from the HOLE, so the pin fits through it by construction.
    readonly property real pinRadius: disc.discRadius * disc.holeFrac * 0.82
    // The pin cannot be seen through the record's hole while the sleeve is
    // over the middle of the stage: it would be drawn on top of the card.
    readonly property bool _sleeveOverCentre: root.sleeveOpacity > 0.01 && Math.abs(root.sleeveX) < root.sleeveSize * 0.5

    // What the platter is carved INTO. The stage paints no background of its
    // own (the drop-in rule), so the one thing it cannot know is the colour
    // behind it, and the bevel outside a carved edge needs it. The card the
    // record sits in is a list box, which is why that is the default.
    property color platterSurfaceColor: Theme.listBox

    Turntable {
        id: platter
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: root._rdx
        anchors.verticalCenterOffset: root._rdy
        visible: root.showTurntable
        platterSize: root.recordDiameter * root.platterFrac
        pinLength: root.pinLength
        pinRadius: root.pinRadius
        recordHeightPx: root.discHeight
        surfaceColor: root.platterSurfaceColor
    }

    VinylDisc {
        id: disc
        // THE DISC'S ITEM IS THE WHOLE STAGE, not a box the size of the record.
        // A shader cannot put a pixel outside its own item, so everything the
        // record throws past its own silhouette would be cut off at the edge of
        // a box only a fraction wider than the record itself: the shadow of a
        // lifted record would end at a horizontal line above the title and at a
        // vertical one down its right, and the record itself would be clipped
        // while it is flung left in the put-away's windup.
        //
        // The record's SIZE does not change with it. VinylDisc reads its radius
        // off its own item, so the fraction it is handed here is whatever makes
        // that come out at `recordFrac` of `discSize` -- the record lands in
        // the same place, at the same size, with the whole card to spill into.
        anchors.fill: parent
        radiusFrac: Math.min(1, root._recordFrac * root.discSize / Math.max(1, Math.min(root.width, root.height)))
        opacity: root.discOpacity
        islandArmed: themeIsland.armed
        islandPlace: themeIsland

        spinDeg: root.spinDeg
        tiltX: root.tiltX
        tiltY: root.tiltY
        flipDeg: root.flipDeg
        flipAxisDeg: root.flipAxisDeg
        heightPx: root.discHeight
        // The record's centre, and the stage's, are two different points: the
        // disc's item is the whole canvas and the record sits wherever the host
        // put its slot in it.
        offsetX: root.discX + root._rdx
        offsetY: root.discY + root._rdy
        // THE CAMERA STANDS OVER THE PIN, not over the middle of the canvas.
        // The disc's item is the whole card, so a record placed off-centre was
        // seen off-axis: in mini it sits 157 px off an axis only 193 px long,
        // which would slide it 45 px left as it lifted to the flip's apex and
        // turn its sheen 43 degrees away from the player's. This is the
        // record's SLOT and deliberately not discX/discY -- the camera stands
        // over the turntable, so a record flung away from it is seen more
        // steeply.
        cameraX: root._rdx
        cameraY: root._rdy
        albumArt: root.albumArt

        // The spindle's shadow on the label. It is the record's to draw -- the
        // label is its texture -- and the stage's to place. What the shader
        // casts the shadow from is the length of pin standing PROUD of the
        // label, which is the pin minus however far the record has risen up it:
        // longest with the record down on the platter, gone by the time the
        // record clears the top of the pin. Feeding the record's own height
        // instead inverts it: the shadow would be longest at the one height
        // where the pin barely shows, and absent while the record rests.
        //
        // The strength has to fade to nothing over the same range: at
        // zero protrusion the shader draws the pin's own cross-section, and a
        // record held above the pin would keep a little dark dot on its label.
        pinShadowStrength: (root.showTurntable && root.pinLength > 0) ? root.pinShadowStrength * Math.max(0, 1 - root.discHeight / root.pinLength) : 0
        pinRadius: root.pinRadius
        pinHeightPx: Math.max(0, root.pinLength - root.discHeight)
        scuff: 0.24
        specStrength: 0.8
    }

    // The length of spindle that stands ABOVE the record, drawn in front of it:
    // this is the pin coming through the hole. It shortens to nothing as the
    // record comes down and grows back as it is lifted.
    Turntable {
        id: platterPin
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: root._rdx
        anchors.verticalCenterOffset: root._rdy
        pinFrontOnly: true
        visible: root.showTurntable && root.discOpacity > 0.01 && !root._sleeveOverCentre
        platterSize: platter.platterSize
        pinLength: root.pinLength
        pinRadius: root.pinRadius
        recordHeightPx: root.discHeight
        surfaceColor: root.platterSurfaceColor
    }

    VinylSleeve {
        id: sleeve
        anchors.centerIn: parent
        // sleeveX/sleeveY are measured from the RECORD's centre -- the sleeve
        // is the thing the record goes into, so that is the point they are both
        // placed against.
        anchors.horizontalCenterOffset: root._rdx
        anchors.verticalCenterOffset: root._rdy
        // The same key light the record uses. Two objects in one scene that
        // disagree about where the lamp is read as a collage, and the sleeve
        // and the record are on screen together for the whole arrival.
        lightDir: disc.lightDir0
        // A sleeve is a shade bigger than the RECORD it holds, and big enough
        // to hide it completely until it moves.
        width: root.sleeveSize
        height: root.sleeveSize
        opacity: root.sleeveOpacity
        albumArt: root.sleeveArt !== "" ? root.sleeveArt : root.albumArt
        transform: [
            Rotation {
                origin.x: sleeve.width / 2
                origin.y: sleeve.height / 2
                angle: root.sleeveRot
            },
            Translate {
                x: root.sleeveX
                y: root.sleeveY
            }
        ]
    }

    // ======================================================================
    // THE SEQUENCES
    // ======================================================================

    // ---- arrival: sleeve slides in WITH the record inside it ---------------
    function startSequence() {
        root.sleeveArt = "";
        endAnim.stop();
        exitAnim.stop();
        root._exiting = false;
        flipAnim.stop();
        spinUp.stop();
        spinDown.stop();
        root._handBack = false;
        startAnim.restart();
    }

    SequentialAnimation {
        id: startAnim
        paused: startAnim.running && root.sequencesPaused

        ScriptAction {
            script: {
                root._phase = "arriving";
                root._positionDriven = false;
                root.spinRate = 0;
                root.spinDeg = 0;
                root.flipDeg = 0;
                root.tiltX = 0;
                root.tiltY = 0;
                // On the platter, inside the sleeve: it is not floating, and
                // it is not visible -- the sleeve is bigger than it is.
                root.discHeight = root.restHeight;
                root.discOpacity = 1;
                root.sleeveOpacity = 1;
                root.sleeveY = 0;
                root._flipBase = 0;
                // A NEW RECORD, so a new side and nothing behind it: the first
                // progress this album reports has nothing to have fallen from,
                // and the half it crosses is its own.
                root._albumSeen = 0;
                root._halfTaken = false;
                root._carryRecord = true;
                // It comes in from the left turned anticlockwise, so it keeps
                // an anticlockwise remnant of that when it stops -- the same
                // rule, and the same number, as the put-away's.
                root._beginSlide(root._offStageX(-1.25), 0, -16, -root.sleeveSettleRot);
            }
        }
        // The slide in: friction, not a bounce.
        NumberAnimation {
            target: root
            property: "_slideT"
            from: 0
            to: 1
            duration: Math.round(root.sleeveSlideMs * root._ts)
            easing.type: Easing.Linear
        }
        // A very short pause.
        PauseAnimation {
            duration: Math.round(180 * root._ts)
        }
        ScriptAction {
            script: {
                root._sliding = false;
                // The sleeve has arrived; the record it brought stays where it
                // put it, which is the middle of the stage.
                root._carryRecord = false;
                root.discX = 0;
                root._phase = "revealing";
                root._showT = 0;
            }
        }
        // The reveal: the record is anchored and is uncovered as the sleeve
        // leaves to the right, and it begins to show itself off before the
        // sleeve has finished leaving.
        ParallelAnimation {
            SequentialAnimation {
                ParallelAnimation {
                    NumberAnimation {
                        target: root
                        property: "sleeveX"
                        to: root._offStageX(1.45)
                        duration: Math.round(760 * root._ts)
                        easing.type: Easing.InOutCubic
                    }
                    NumberAnimation {
                        target: root
                        property: "sleeveRot"
                        to: 7
                        duration: Math.round(760 * root._ts)
                        easing.type: Easing.InOutQuad
                    }
                }
                ScriptAction {
                    script: root.sleeveOpacity = 0
                }
            }
            SequentialAnimation {
                PauseAnimation {
                    duration: Math.round(760 * root.showStartFrac * root._ts)
                }
                ScriptAction {
                    script: root._phase = "showing"
                }
                ParallelAnimation {
                    // The one arc: swivel, rise toward the camera, and back
                    // down onto the platter.
                    NumberAnimation {
                        target: root
                        property: "_showT"
                        from: 0
                        to: 1
                        duration: Math.round(root.showMs * root._ts)
                        easing.type: Easing.Linear
                    }
                    // The platter takes it on the way down, so the record is
                    // already turning at speed when it lands.
                    SequentialAnimation {
                        PauseAnimation {
                            duration: Math.round(root.showMs * root.spinupStartFrac * root._ts)
                        }
                        NumberAnimation {
                            target: root
                            property: "spinRate"
                            to: root.degPerSec
                            duration: Math.round(root.showMs * (1 - root.spinupStartFrac) * root._ts)
                            easing.type: Easing.OutCubic
                        }
                    }
                }
            }
        }
        ScriptAction {
            script: {
                root.discHeight = root.restHeight;
                root.tiltX = 0;
                root.tiltY = 0;
                root._lastPos = root.positionSec;
                root._positionDriven = true;
                root.spinRate = 0;
                root._phase = "playing";
                root.sequenceFinished("start");
                root._settleDrive();
            }
        }
    }

    // ======================================================================
    // WHY A RECORD IS TURNED OVER
    //
    // Two reasons, and both of them are the album's own progress -- which is
    // why they are read HERE, off one number, rather than latched by whoever
    // happens to be watching the queue.
    //
    //   the half     this side has been played through, so the record goes onto
    //                its other one. Latched, because the progress jitters
    //                around the halfway point when a queue is reordered under
    //                it; walking BACK past the half re-arms it, because
    //                crossing it again is a second crossing and not a flap.
    //   the restart  the album's progress falling back toward its start while
    //                THE SAME RECORD IS ON THE PLATTER. That is side B running
    //                out and side A being put on again, whatever caused it --
    //                repeat all coming round, a prev at the album's first song,
    //                a queue rebuilt in place. It is a fact about the progress
    //                and not about the setting that produced it.
    //
    // A FALL IS NOT A TRACK CHANGE. Stepping back one song inside the album
    // drops the progress by one song's worth; the album starting over drops it
    // to its own first song, which is at most half of wherever it was however
    // long the album is. That is the whole test, and it needs to know nothing
    // about the queue.
    //
    // AND A NEW ALBUM IS NOT A RESTART. Its progress starts low too, so the
    // reasons are read only while the record is PLAYING: the record being
    // replaced is already in `ending` by then, and an arrival re-seeds the
    // baseline at nothing, so the first progress a new record reports has
    // nothing to have fallen from.
    //
    // WHICH IS WHY THE READ IS DEFERRED. The progress and whatever the host
    // does about a new album are two bindings off one update of the service,
    // and the order they are evaluated in is Qt's business. Read inside the
    // change handler, the arriving album's progress is compared against the
    // leaving album's with the stage still saying "playing" -- an arrival read
    // as a restart. `Qt.callLater` reads both once the turn has settled, which
    // is the only moment they are both true.
    // ======================================================================
    // How far the progress must fall to count as the album starting over, as a
    // fraction of where it was. 0.5 is "at most half of it": the first song of
    // a run of any length is, and a step back inside one never is.
    property real albumRestartFall: 0.5
    property real _albumSeen: 0
    property bool _halfTaken: false
    property bool _albumQueued: false

    onAlbumProgressChanged: {
        if (root._albumQueued)
            return;
        root._albumQueued = true;
        Qt.callLater(root._readAlbumProgress);
    }

    function _readAlbumProgress() {
        root._albumQueued = false;
        const p = root.albumProgress;
        const was = root._albumSeen;
        root._albumSeen = p;
        if (p <= 0) {
            // Nothing is playing: there is no side to have taken.
            root._halfTaken = false;
            return;
        }
        const restarted = was > 0 && p <= was * root.albumRestartFall + 1e-6;
        if (p < 0.5)
            root._halfTaken = false;
        if (!restarted && (root._halfTaken || p < 0.5))
            return;
        // A record can only be turned over while it is ON the platter, and a
        // reason found at any other moment is not saved for later: the flip is
        // about where the album is NOW, and by the time a record is down its
        // album has moved on.
        if (root._phase !== "playing")
            return;
        if (!restarted)
            root._halfTaken = true;
        root.flipSequence();
    }

    // ---- the half-album flip ----------------------------------------------
    function flipSequence() {
        if (root._phase !== "playing")
            return;
        // Both ends of the axis wander are drawn up front, so the whole flip is one
        // slow interpolation with no per-frame randomness in it.
        root._flipFrom = (Math.random() * 2 - 1) * root.flipAxisVariance;
        root._flipTo = (Math.random() * 2 - 1) * root.flipAxisVariance;
        root._flipBase = root.flipDeg % 360;
        flipAnim.restart();
    }

    SequentialAnimation {
        id: flipAnim
        paused: flipAnim.running && root.sequencesPaused
        ScriptAction {
            script: {
                root._phase = "flipping";
                root._positionDriven = true;      // the music keeps playing
            }
        }
        NumberAnimation {
            target: root
            property: "_flipT"
            from: 0
            to: 1
            duration: Math.round(root.flipMs * root._ts)
            easing.type: Easing.Linear
        }
        ScriptAction {
            script: {
                // A half turn on top of whole ones: the record lands on its
                // other side, which is the whole point of flipping it.
                root.flipDeg = root.flipDeg % 360;
                root.discHeight = root.restHeight;
                root._phase = "playing";
                root.sequenceFinished("flip");
                root._settleDrive();
            }
        }
    }

    // ---- the end: run down, lift, and be put away -------------------------
    function endSequence() {
        // ALREADY LEAVING. The put-away cannot be run twice over one record:
        // its own `armed` is what hands the stage to whoever asked for this,
        // and restarting it would bring the record back to be run down again.
        if (root._phase === "ending")
            return;
        if (root._phase === "sleeving") {
            // Past `armed` the stage is already clear, so a caller that has
            // only just found the next record is told so at once rather than
            // waiting for a hand-over that has been and gone.
            root.sequenceFinished("armed");
            return;
        }
        // AN ARRIVAL IS A SEQUENCE TOO: stopping the flip but not the arrival
        // would leave the arrival's own NumberAnimation on `spinRate` -- the
        // wind-up it runs over the drop -- fighting the put-away's run-down on
        // the same property, and its last ScriptAction still to come to declare
        // the record playing in the middle of being taken off. That is the
        // wind-down being cut short by a sequence starting.
        startAnim.stop();
        flipAnim.stop();
        exitAnim.stop();
        root._exiting = false;
        spinUp.stop();
        spinDown.stop();
        // A wheel that has just reached speed is waiting for the music to take
        // the record back; a sequence taking it instead must cancel that, or
        // the next position update would hand a record the put-away is already
        // running down back to a clock that is no longer driving it.
        root._handBack = false;
        root._sliding = false;
        if (root._carryRecord) {
            // THE RECORD NEVER CAME OUT OF THE SLEEVE. An arrival called off
            // during its slide is already packed: there is nothing to run down
            // (the record has not turned a degree), nothing to lift off the
            // spindle and nothing to fling, and the only honest thing left to
            // do with it is to carry on out the way it came. It is the same
            // exit, entered from the other end -- and the same `armed`, so the
            // host is handed the stage exactly as it is by the long way round.
            root._positionDriven = false;
            root.spinRate = 0;
            root._phase = "ending";
            root.sleeveArt = root.albumArt;
            root._beginExit(root._offStageX(-1.4), -9);
            return;
        }
        endAnim.restart();
    }

    SequentialAnimation {
        id: endAnim
        paused: endAnim.running && root.sequencesPaused
        ScriptAction {
            script: {
                root._phase = "ending";
                // Hand the spin back to the rate integrator AT THE RATE THE
                // RECORD IS ACTUALLY TURNING, whatever is turning it. The music
                // turns it at the platter's own speed, so that is what the
                // position regime hands over; a wheel that is still winding up
                // after a resume, or already running down after a pause, hands
                // over the rate it had reached. Taking the platter's full speed
                // whenever `playing` is true would be a jump of up to 200 deg/s
                // at the very top of the run-down: a put-away that started while
                // the record was still spinning up would SPEED IT UP first,
                // which reads as an abrupt wind-down.
                root.spinRate = (root.playing && root._positionDriven) ? root.degPerSec : root.spinRate;
                root._positionDriven = false;
                // The sleeve that arrives is THIS album's, snapped now: the
                // host may have moved on to the next album's art already.
                root.sleeveArt = root.albumArt;
            }
        }
        // The wheel runs down -- and whatever pose an arrival was cut off in
        // comes back to the platter while it does, rather than being put away
        // swivelled and off to one side. All three move by NOTHING for a record
        // that was simply playing, which is every put-away that is not an
        // interrupted arrival: it is already at the middle with no tilt on it.
        ParallelAnimation {
            NumberAnimation {
                target: root
                property: "spinRate"
                to: 0
                duration: Math.round(2200 * root._ts)
                easing.type: Easing.InOutCubic
            }
            NumberAnimation {
                target: root
                property: "discX"
                to: 0
                duration: Math.round(620 * root._ts)
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root
                property: "tiltX"
                to: 0
                duration: Math.round(620 * root._ts)
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root
                property: "tiltY"
                to: 0
                duration: Math.round(620 * root._ts)
                easing.type: Easing.OutCubic
            }
        }
        // The record is lifted off the spindle FIRST. A sleeve that arrived
        // first would have to be slid under a record lying on the platter, and
        // the record would then be inside it without ever having gone in.
        NumberAnimation {
            target: root
            property: "discHeight"
            to: root.putAwayLift
            duration: Math.round(620 * root._ts)
            easing.type: Easing.OutCubic
        }
        // Now the sleeve slides in from the right and stops beside the record
        // -- already partly over it, because that is where there is room.
        ScriptAction {
            script: {
                root.sleeveOpacity = 1;
                root._carryRecord = false;    // it is out of the sleeve, not in it
                root._beginSlide(root._offStageX(1.3), root.sleeveRestX, 14, root.sleeveSettleRot);
            }
        }
        NumberAnimation {
            target: root
            property: "_slideT"
            from: 0
            to: 1
            duration: Math.round(root.sleeveSlideMs * root._ts)
            easing.type: Easing.Linear
        }
        ScriptAction {
            script: root._sliding = false
        }
        // The windup: the record is pulled left before it goes.
        NumberAnimation {
            target: root
            property: "discX"
            to: -root.discSize * 0.09
            duration: Math.round(240 * root._ts)
            easing.type: Easing.OutCubic
        }
        // ...and is fired into the sleeve. Its HEIGHT does not change while it
        // flies: a record that came down to the platter on the way in would be
        // drawn smaller as it went, and would read as shrinking to fit.
        NumberAnimation {
            target: root
            property: "discX"
            to: root.sleeveRestX
            duration: Math.round(165 * root._ts)
            easing.type: Easing.InCubic
        }
        ScriptAction {
            script: {
                root.discOpacity = 0;
                root.discHeight = root.restHeight;
            }
        }
        // The recoil, and the stiff invisible spring that stops it. This one IS
        // a bounce: it is a collision, not a slide.
        NumberAnimation {
            target: root
            property: "sleeveX"
            to: root.sleeveRestX + root.discSize * 0.09
            duration: Math.round(110 * root._ts)
            easing.type: Easing.OutQuad
        }
        NumberAnimation {
            target: root
            property: "sleeveX"
            to: root.sleeveRestX
            duration: Math.round(520 * root._ts)
            easing.type: Easing.OutElastic
            easing.amplitude: 0.55
            easing.period: 0.32
        }
        // Away it goes, to the right, and the stage is handed over as soon as
        // it has gone.
        ScriptAction {
            script: root._beginExit(root._offStageX(1.4), 9)
        }
    }

    // ---- the sleeve leaving, and the hand-over inside it -------------------
    SequentialAnimation {
        id: exitAnim
        paused: exitAnim.running && root.sequencesPaused
        // As far as the sleeve being gone...
        NumberAnimation {
            target: root
            property: "_exitT"
            from: 0
            to: root._exitArmedT
            duration: Math.round(root.sleeveExitMs * root._exitArmedT * root._ts)
            easing.type: Easing.Linear
        }
        // ...which is where the next record may come in. The sleeve is off the
        // stage, so an arrival taking it over here is not a cut: there is
        // nothing left of the old one to cut off.
        ScriptAction {
            script: {
                root._phase = "sleeving";
                root.sequenceFinished("armed");
            }
        }
        NumberAnimation {
            target: root
            property: "_exitT"
            to: 1
            duration: Math.round(root.sleeveExitMs * (1 - root._exitArmedT) * root._ts)
            easing.type: Easing.Linear
        }
        ScriptAction {
            script: {
                root._exiting = false;
                root.sleeveOpacity = 0;
                root.sleeveArt = "";
                // The record goes with it. It is already gone by the time the
                // put-away hands over -- it was fired into the sleeve -- and it
                // is still inside the sleeve when a called-off arrival leaves
                // with it, so this is the one place both ways out end.
                root.discOpacity = 0;
                root._carryRecord = false;
                root.discX = 0;
                root._phase = "idle";
                root.sequenceFinished("end");
            }
        }
    }

    // Stops every sequence and the spin, and leaves the pose EXACTLY where it
    // is. `snapToPlaying` also stops everything, but it then puts the record
    // flat on the platter -- which is the wrong thing for anything that wants
    // to take the pose over from here (a scrubber replaying recorded frames,
    // a host parking the module) rather than to start playing.
    function freeze() {
        startAnim.stop();
        flipAnim.stop();
        endAnim.stop();
        exitAnim.stop();
        spinUp.stop();
        spinDown.stop();
        root.sequencesPaused = false;
        root._positionDriven = false;
        root._handBack = false;
        root._sliding = false;
        root._exiting = false;
        root._carryRecord = false;
        root.spinRate = 0;
        root._turnRate = 0;
    }

    // Stops everything and puts the record on the platter, turning with the
    // music: what a module does when it is shown mid-track rather than at one.
    function snapToPlaying() {
        startAnim.stop();
        endAnim.stop();
        exitAnim.stop();
        flipAnim.stop();
        spinUp.stop();
        spinDown.stop();
        root._handBack = false;
        root._sliding = false;
        root._exiting = false;
        root._carryRecord = false;
        root.spinRate = 0;
        root._turnRate = 0;
        root.flipDeg = 0;
        root._flipBase = 0;
        root.tiltX = 0;
        root.tiltY = 0;
        root.discX = 0;
        root.discHeight = root.restHeight;
        root.discOpacity = 1;
        root.sleeveOpacity = 0;
        root.sleeveY = 0;
        root._lastPos = root.positionSec;
        root._positionDriven = true;
        // The record is taken over WHERE IT IS, and that includes which side it
        // is on: an album already past its half has had that side, so the next
        // song is not a reason to turn it, and the progress it is at now is
        // what the next reading is measured against.
        root._albumSeen = root.albumProgress;
        root._halfTaken = root.albumProgress >= 0.5;
        root._phase = "playing";
        // ...and it is only DRIVEN by the position if there is one moving. A
        // popup opened over a PAUSED player lands here too, and left
        // position-driven it would integrate a still number at 60 Hz for as
        // long as the popup stayed open. Same resolver as the sequences use.
        root._settleDrive();
    }
}
