pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix

// =============================================================================
// SwipeVerbCard.qml -- a card with a verb on each side, swiped off (or
// through) by two fingers or a left-button drag. The notification toasts and
// the manager's rows and group headers:
//
//   toast     RIGHT = file (the tray), LEFT = delete (the bin); both fly off
//   manager   RIGHT = pin / unpin (springs back, still commits), LEFT = delete
//             (which side is which: notifications.jsonc toasts.swipe, manager.swipe)
//   header    BOTH = clear (the group); both fly off -- pinning a group makes
//             no sense, so the header has one verb on either side
//
// THE WELL. The card's face (the host's content) slides off a CARVED WELL of
// the same shape and radius, carved into the card's ground (`groundColor`).
// The side the card uncovers shows the verb that swipe will do: swiping right
// uncovers the LEFT side, which carries `rightVerb`'s glyph, centred in the
// uncovered band. The glyph fades in with the uncovered distance and its colour
// crosses from faint to the verb's own colour as the band reaches the commit
// line -- two fractions of the drawn offset, mixed with Mix.js, never a
// Behavior on a colour. At rest the well is not drawn at all, so a resting
// card is exactly its face.
//
// THE WELL EXISTS ONLY WHERE THE CARD HAS UNCOVERED IT. It is one carved box
// of the card's size and radius, drawn once into a layer and cut (WellCut,
// shaders/well_cut.frag) to what the face does not cover: the band between the
// side the card left and the face's edge, PLUS the wedges the face's rounded
// corners leave open on its leading edge -- the face is transparent there, and
// a straight cut at its edge would leave them to the ground, which is lighter
// than the well: a pale corner round every rounded corner of a swiped card. It
// is never shrunk to the band, which would grow a second pair of corners at
// the face. Under the face there is only the ground: the face fades near the
// commit line (FADE), and with the well under it too the translucent face
// would show the well's floor and glyph through itself.
// The layer takes the well's bevel slack on every side, because a carved box
// draws its bevel OUTSIDE its rect (a clip on a carved box's edge
// shears its bevel). The glyph is inside the layer, so a glyph still wider
// than a narrow band is cut at the face's edge too.
//
// THE WELL'S PRESENCE. A fly-off takes the well with it: from the decision to
// the landing the well (glyph included) fades out linearly in the FLIGHT'S
// TIME -- one clock, the drawn offset itself (the flight is OutCubic, so
// 1 - t = cbrt(1 - travelled share)) -- and a landed card draws no well at all
// (the whole band would stay drawn after the landing, and the room's
// close would slide the next card over it or cut it with the lane's edge). A face a
// stand-in has taken over (`faceHidden`) fades its well out in place over
// `wellFadeMs`.
//
// THE FINGERS AND THE CARD ARE TWO NUMBERS. `scrub(px)` is where the fingers
// are (the reader's cumulative displacement, or the drag's translation);
// what is DRAWN chases it through the give below at no more than the card's
// own speed -- a whole width in `flyMs` (a scrub that follows the
// fingers 1:1 finishes a flick in a frame). The chase is a FrameAnimation
// stepping toward the target, not a NumberAnimation restarted per event: a
// restart per wheel event starves an animation whose events come faster than
// the frames (a Behavior whose binding changes every frame never
// ticks). The decision is taken on the FINGERS, never on what is drawn:
//
//   release(v)   past `commitFraction` of the width, or a fling (|v| >=
//                `flingPxPerS` the way the card is displaced): commit.
//                Otherwise spring back (OutCubic, `springMs`). -> the
//                direction committed, 0 for none.
//
// THE GIVE. Up to the commit line the card follows the fingers 1:1; past it,
// resistance with the gestures.md taper 1 - (1 - t)^2, joined with slope 1 at
// the knee and saturating at `maxFraction` of the width, so what is left of
// the gesture reads as effort. A side with no verb ("") only gives
// `blockedGivePx`, on the same taper from half the slope, and never commits.
//
// COMMIT. `committed(dir)` fires at the decision (the host starts its
// collapse), after the exit has started. A side that flies off flies to past
// the width (OutCubic, `flyMs` scaled by what is left); one that does not
// (pin) swings out to the commit line if it was short of it and springs back.
// `landed(dir)` when the motion is over -- dir 0 for a plain spring back.
// `flownSign` says which way a fly-off went (-1 / +1) from its start until
// reset(), 0 for a card that did not fly (the manager's leave motion).
//
//   commit(dir)  the user's decision from elsewhere (the reader's notch or
//                pull-through): committed + the exit. false when that side has
//                no verb or the card is already committed.
//   flyOff(dir, verb)  PROGRAMMATIC exit (the host's timeout filing a toast): flies
//                off that way whatever the verbs say (the well shows `verb`), emits
//                landed only -- the host already made the decision, so no committed.
//   reset()      back to rest at once (a host reusing a card).
//
// FADE. On a side that flies off, the face's opacity is one value of the
// drawn offset: 1 up to `fadeFrom` of the width, 0 at the whole width. A card
// held at 0.6 W is already translucent where the host's clip cuts it, and a
// fly-off is invisible before the clip edge matters ("nothing is cut hard").
// A side that springs back (pin / unpin) never fades.
//
// THE FACE FADES AS ONE PICTURE. Items fading each on their own show through
// each other: an app's badge over an avatar shows the avatar's pink through
// the badge (23 levels), the two strokes of a Chevron darken
// where they cross. So while the face is translucent -- or displaced under a
// SideFade, whose cut it draws through (THE LIST) -- it is ONE LAYER: drawn
// once into a texture, and that texture faded (and cut). No layer at rest: a
// resting card is its plain scene graph, to the pixel. The layer
//   - is larger than the face by `bleedPx` on every side: content draws past
//     the face (a carved rim, a highlight ring), and a layer is cut on its
//     item's rect;
//   - is sized at the scale it is seen at (the card's own scale to the
//     window's device pixels, measured) and kept on whole device pixels (`_snap`), so the texture is
//     not resampled -- soft, and banded at the half-pixel crossings;
//   - switches only where the drawn offset moves -- in the chase and the
//     animations, never inside a pointer event's delivery (a
//     layer flipped there destroys what the delivery agent is walking);
//     `reset()`, the one call a host may make from an event, keeps it one
//     turn longer.
// Cost: one texture of the face's size
// for as long as the face is translucent or displaced under a SideFade, drawn
// when its content changes -- not per frame of the motion, which only moves
// the quad.
//
// MOUSE. A left-button drag past `dragThreshold` px (x only; DragHandler with
// no target, on the card's root so its translation does not move with the
// face) is the same scrub and release. A press and release without one is
// `clicked()`. The click area lies UNDER the host's content, so a RaisedButton
// (or a link) in the face keeps its own clicks; a drag that starts on one
// still steals it past the threshold and swipes.
//
// CONTENT. Sized by its own implicit size -- the card's implicit size is the
// face's children's rect, so content must not anchor to the face (a loop).
// The face moves over the ground, but its content's bevel lies a pixel
// OUTSIDE the face, over the well's cut: content eases its rim to alpha (a
// carved ShadowBox with surfaceColor "transparent"). A header
// (ListSectionHeader) is content like any other: its own MouseArea keeps the
// click, the drag below takes the press over past `dragThreshold`.
//
// THE LIST. A host clips its rows' strip at its SideFade's `clipInset` and
// hands every card that SideFade (`sideFade`). A displaced card then cuts
// ITSELF to the host's outline -- per pixel row, so a card pushed under a
// rounded corner follows the curve -- and fades out on the side it moves to,
// gone before the cut (SideCut; shaders/side_cut.frag has the two ramps).
// Only the displaced card is touched, and only while it is displaced.
//
// A STAND-IN. `faceItem` is the face as drawn (the card's size, at the drawn
// offset): where a RowFlight clone lifts off from (`RowFlight.begin(...,
// fromItem)`). While the clone flies, the host sets `faceHidden`: the face
// is not drawn and the well fades out where it is, so the band a pin swipe
// uncovered never vanishes in one frame.
// =============================================================================
Item {
    id: card

    // ---- Contract (CONTRACT.md C1) -------------------------------------------------
    default property alias content: holder.data
    property string rightVerb: "file"        // either side: "file" | "pin" | "unpin" | "delete" | "clear" | "hide" | "unhide" | "" (no verb)
    property string leftVerb: "delete"
    property bool rightFliesOff: true        // false: springs back, still commits
    property bool leftFliesOff: true
    // A side that says no: a swipe past the commit line on it commits nothing, the card springs back and wiggles (`refuse()`),
    // the shell's one refusal (Shake). A KEPT record's delete.
    property bool leftRefuses: false
    property bool rightRefuses: false
    property real radius: 14
    property color groundColor: Theme.surface   // the surface the well is carved into
    property real commitFraction: 0.4        // of the width, on release
    property bool dragEnabled: true          // left-button drag == swipe
    // The list's SideFade (THE LIST); null: the host's own clip is the cut.
    property SideFade sideFade: null
    // A stand-in draws the face (A STAND-IN): the face hidden, the well fading.
    property bool faceHidden: false
    readonly property real offset: card._x   // drawn, px, + = right
    readonly property bool swiping: card._state !== "rest"
    // Which way a fly-off went: -1 / +1 from its start until reset(); 0 when
    // the card did not fly (at rest, sprung back, a pin's swing).
    readonly property int flownSign: card._flownSign
    // The refusal's wiggle is playing (`refuse()`).
    readonly property bool refusing: refusal.running
    // The face as drawn: the card's size, at the drawn offset.
    readonly property Item faceItem: faceBody

    signal committed(int direction)
    signal landed(int direction)
    signal clicked

    // ---- Tuning ----------------------------------------------------------------------
    // A whole width at the card's own speed: the chase's cap, and the fly-off.
    property int flyMs: 260
    property int springMs: 260
    // How far a pin swings out when committed from short of the commit line.
    property int swingMs: 120
    property real flingPxPerS: 900
    property real maxFraction: 0.8
    property real blockedGivePx: 24
    property real dragThreshold: 6
    property string glyphFamily: "Symbols Nerd Font"
    property real glyphSize: 20
    // The glyph keeps this far from the well's edge while the band is narrow.
    property real glyphInset: 12
    // The well: a container's carve, one step deeper than the card's.
    property real wellShadowWidth: 4
    property real wellBevelWidth: 1
    // The face fade (see FADE above): on by default.
    property bool faceFade: true
    property real fadeFrom: 0.45
    // How long a hidden face's well takes to fade out (a presence fade).
    property int wellFadeMs: 160
    // How far the content may draw outside the face (a carved rim 1-2 px, a
    // highlight ring): the face's layer takes this much slack on every side.
    property int bleedPx: 4

    implicitWidth: Math.ceil(holder.childrenRect.x + holder.childrenRect.width)
    implicitHeight: Math.ceil(holder.childrenRect.y + holder.childrenRect.height)

    // ---- State -------------------------------------------------------------------------
    // "rest" | "scrub" | "spring" | "commit" | "gone"
    property string _state: "rest"
    property real _x: 0          // drawn offset
    property real _target: 0     // what the chase steps toward (the give of the fingers)
    property real _fingerPx: 0   // where the fingers are
    property int _landDir: 0
    // The verb a commit shows until it lands: the host may flip the verbs at
    // `committed` (pin -> unpin) while the card is still swinging back.
    property string _shownVerb: ""
    // A fly-off in progress (or landed): it fades whatever the side's flag
    // says -- flyOff() is the host's and may fly any side.
    property bool _flying: false
    property int _flownSign: 0
    property int _shakeDir: -1
    property real _flyFrom: 0
    property real _flyTo: 0
    // The face's whole-pixel offset: what is drawn, and where the well is cut.
    readonly property int _faceX: Math.round(card._x + card._shakeDir * refusal.offset)
    readonly property real _faceOpacity: {
        if (!card.faceFade || card._x === 0)
            return 1;
        if (!card._flying && !(card._x > 0 ? card.rightFliesOff : card.leftFliesOff))
            return 1;
        const f = Math.abs(card._x) / Math.max(1, card.width);
        return 1 - Math.max(0, Math.min(1, (f - card.fadeFrom) / Math.max(0.01, 1 - card.fadeFrom)));
    }

    function scrub(px) {
        if (card._state === "commit" || card._state === "gone")
            return;
        if (card._state !== "scrub") {
            card._stopMotion();
            card._state = "scrub";
        }
        card._fingerPx = px;
        card._chaseTo(card._give(px));
    }

    function release(velocityPxPerS) {
        if (card._state !== "scrub")
            return 0;
        const f = card._fingerPx;
        const v = velocityPxPerS || 0;
        const W = Math.max(1, card.width);
        let dir = 0;
        if (Math.abs(f) >= card.commitFraction * W)
            dir = f > 0 ? 1 : -1;
        else if (f !== 0 && Math.abs(v) >= card.flingPxPerS && (v > 0) === (f > 0))
            dir = f > 0 ? 1 : -1;
        card._fingerPx = 0;
        if (dir !== 0 && card.commit(dir))
            return dir;
        card._springBack(0);
        return 0;
    }

    function commit(direction) {
        const dir = direction > 0 ? 1 : -1;
        if (card._state === "commit" || card._state === "gone" || card._verbOf(dir) === "")
            return false;
        if (dir > 0 ? card.rightRefuses : card.leftRefuses) {
            card.refuse(dir);
            return false;
        }
        card._stopMotion();
        card._state = "commit";
        card._shownVerb = card._verbOf(dir);
        if (dir > 0 ? card.rightFliesOff : card.leftFliesOff)
            card._fly(dir);
        else
            card._swing(dir);
        card.committed(dir);
        return true;
    }

    // Say no: the card wiggles (Shake) toward `direction` first (-1, the left, by default) and, when the fingers have it
    // out, springs back. Commits nothing; a card that is leaving is left alone.
    function refuse(direction) {
        if (card._state === "commit" || card._state === "gone")
            return;
        card._shakeDir = direction > 0 ? 1 : -1;
        if (card._state === "scrub" || card._x !== 0)
            card._springBack(0);
        refusal.play();
    }

    function flyOff(direction, verb) {
        const dir = direction > 0 ? 1 : -1;
        if (card._state === "gone")
            return;
        card._stopMotion();
        card._state = "commit";
        card._shownVerb = verb;
        card._fly(dir);
    }

    function reset() {
        // A host may call this from a pointer event: the face's layer goes
        // one turn later, outside the delivery (THE FACE FADES AS ONE PICTURE).
        if (card._layered) {
            card._layerLinger = true;
            Qt.callLater(card._dropLinger);
        }
        card._stopMotion();
        card._flying = false;
        card._flownSign = 0;
        card._shownVerb = "";
        card._fingerPx = 0;
        card._target = 0;
        card._x = 0;
        card._state = "rest";
    }

    // A harness pin: the drawn offset, held still.
    function _pin(px) {
        card._stopMotion();
        card._state = "scrub";
        card._fingerPx = px;
        card._target = px;
        card._x = px;
    }

    function _verbOf(dir) {
        return dir > 0 ? card.rightVerb : card.leftVerb;
    }

    // The give: fingers -> drawn, in px (see the header).
    function _give(px) {
        const W = Math.max(1, card.width);
        const dir = px > 0 ? 1 : -1;
        const s = Math.abs(px) / W;
        let g;
        if (card._verbOf(dir) === "") {
            const b = card.blockedGivePx / W;
            const t = Math.min(1, s / (4 * b));
            g = b * (1 - (1 - t) * (1 - t));
        } else {
            const c = card.commitFraction;
            const m = Math.max(c + 0.01, card.maxFraction);
            if (s <= c) {
                g = s;
            } else {
                const t = Math.min(1, (s - c) / (2 * (m - c)));
                g = c + (m - c) * (1 - (1 - t) * (1 - t));
            }
        }
        return dir * g * W;
    }

    function _chaseTo(px) {
        card._target = px;
    }

    function _stopMotion() {
        run.stop();
        swing.stop();
        card._target = card._x;
    }

    function _springBack(landDir) {
        card._stopMotion();
        card._state = "spring";
        card._landDir = landDir;
        run.from = card._x;
        run.to = 0;
        run.duration = card.springMs;
        run.start();
    }

    function _fly(dir) {
        card._flying = true;
        card._flownSign = dir;
        const W = Math.max(1, card.width);
        const to = dir * (W + card.radius);
        card._landDir = dir;
        card._flyFrom = card._x;
        card._flyTo = to;
        run.from = card._x;
        run.to = to;
        run.duration = Math.max(120, Math.round(card.flyMs * Math.abs(to - card._x) / W));
        run.start();
    }

    function _swing(dir) {
        const peak = dir * card.commitFraction * Math.max(1, card.width);
        card._landDir = dir;
        swingOut.from = card._x;
        swingOut.to = Math.abs(card._x) < Math.abs(peak) ? peak : card._x;
        swingBack.to = 0;
        swing.start();
    }

    function _landed() {
        const dir = card._landDir;
        card._landDir = 0;
        card._target = card._x;
        card._state = card._state === "commit" && card._x !== 0 ? "gone" : "rest";
        if (card._state === "rest")
            card._shownVerb = "";
        card.landed(dir);
    }

    // ---- Motion ------------------------------------------------------------------------
    // The chase: toward _target at no more than a width per flyMs.
    FrameAnimation {
        id: chase
        running: card._state === "scrub" && Math.abs(card._target - card._x) > 0.01
        onTriggered: {
            const W = Math.max(1, card.width);
            const step = W / card.flyMs * Math.min(50, chase.frameTime * 1000);
            const d = card._target - card._x;
            card._x = Math.abs(d) <= step ? card._target : card._x + (d > 0 ? step : -step);
        }
    }
    NumberAnimation {
        id: run
        target: card
        property: "_x"
        easing.type: Easing.OutCubic
        onFinished: card._landed()
    }
    SequentialAnimation {
        id: swing
        NumberAnimation {
            id: swingOut
            target: card
            property: "_x"
            duration: card.swingMs
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            id: swingBack
            target: card
            property: "_x"
            duration: card.springMs
            easing.type: Easing.OutCubic
        }
        onFinished: card._landed()
    }

    // ---- The well ----------------------------------------------------------------------
    readonly property int _side: card._x > 0 ? 1 : -1
    readonly property real _band: Math.abs(card._x)
    // Presence: the glyph is in once the band holds it with its insets.
    readonly property real _presence: Math.max(0, Math.min(1, (card._band - card.glyphSize * 0.35) / (card.glyphSize * 0.65 + 2 * card.glyphInset)))
    // Armed: the verb's colour reaches full strength at the commit line.
    readonly property real _armed: {
        const c = card.commitFraction * Math.max(1, card.width);
        return Math.max(0, Math.min(1, (card._band - 0.5 * c) / (0.5 * c)));
    }
    // THE WELL'S PRESENCE: 1 - t over a fly-off (the flight is OutCubic: the
    // travelled share is 1 - (1 - t)^3), times the hidden face's fade.
    readonly property real _flyPresence: {
        if (!card._flying)
            return 1;
        const span = Math.abs(card._flyTo - card._flyFrom);
        if (span < 0.5)
            return 0;
        const p = Math.max(0, Math.min(1, Math.abs(card._x - card._flyFrom) / span));
        return Math.cbrt(1 - p);
    }
    property real _hiddenPresence: 1
    readonly property real _wellPresence: card._flyPresence * card._hiddenPresence
    onFaceHiddenChanged: {
        if (card.faceHidden) {
            hideWell.restart();
        } else {
            hideWell.stop();
            card._hiddenPresence = 1;
        }
    }
    NumberAnimation {
        id: hideWell
        target: card
        property: "_hiddenPresence"
        from: 1
        to: 0
        duration: card.wellFadeMs
        easing.type: Easing.OutCubic
    }

    function _glyphOf(verb) {
        switch (verb) {
        case "file":
        case "hide":              // a live toast into the manager: an archive, both ways (NotificationService, LIVE)
            return "\u{F0120}";   // md-tray_arrow_down
        case "unhide":            // out of the manager, a toast again
            return "\u{F011D}";   // md-tray_arrow_up
        case "delete":
            return "\u{F0A7A}";   // md-trash_can_outline
        case "pin":
            return "\u{F0403}";   // md-pin
        case "unpin":
            return "\u{F0404}";   // md-pin_off
        case "clear":
            return "\u{F039F}";   // md-notification_clear_all
        }
        return "";
    }
    function _colorOf(verb) {
        switch (verb) {
        // Both remove what the card stands for (a clear is a group's delete,
        // with the same undo): the one destructive colour.
        case "delete":
        case "clear":
            return Theme.error;
        case "pin":
        case "unpin":
        case "unhide":
            return Theme.accent;
        }
        return Theme.textMuted;
    }

    // The uncovered band, and the wedges the face's rounded corners leave open
    // on its leading edge (a straight cut at the face's edge would leave those
    // to the ground, which is lighter than the well -- a pale corner round
    // every rounded corner of a swiped card). The well is one layer, drawn
    // once, cut to what the face does not cover per pixel (WellCut,
    // shaders/well_cut.frag) -- so under a translucent face there is still only
    // the ground, and the wedge needs no second shape. The layer is larger than
    // the card by the bevel's slack; its presence is its OPACITY, so its
    // texture is not redrawn while the well fades.
    readonly property bool _wellOn: card._band > 0.01 && card._wellPresence > 0.001
    // The layer outlives the well by one turn (a host's reset() may drop the
    // well inside a pointer event's delivery: a layer flipped there destroys
    // what the delivery agent is walking).
    property bool _wellLayer: false
    on_WellOnChanged: {
        if (card._wellOn)
            card._wellLayer = true;
        else
            Qt.callLater(card._dropWellLayer);
    }
    function _dropWellLayer() {
        if (!card._wellOn)
            card._wellLayer = false;
    }
    on_WellLayerChanged: if (card._wellLayer) card._sample()

    Item {
        id: wellClip
        objectName: "swipeWellClip"
        readonly property real slack: Math.ceil(card.wellBevelWidth) + 1
        visible: card._wellOn
        x: -wellClip.slack + (card._wellLayer ? card._wellSnap.x : 0)
        y: -wellClip.slack + (card._wellLayer ? card._wellSnap.y : 0)
        width: card.width + 2 * wellClip.slack
        height: card.height + 2 * wellClip.slack
        opacity: card._wellPresence
        layer.enabled: card._wellLayer
        layer.smooth: true
        layer.textureSize: Qt.size(Math.max(1, Math.ceil(wellClip.width * card._k)), Math.max(1, Math.ceil(wellClip.height * card._k)))
        layer.effect: wellCutEffect

        ShadowBox {
            id: well
            // The card's whole box, placed in the card's frame.
            x: wellClip.slack
            y: wellClip.slack
            width: card.width
            height: card.height
            baseRadius: card.radius
            surfaceColor: card.groundColor
            backgroundColor: Theme.panelSunk
            bevelColor: Theme.bevel
            shadowColor: Theme.shadowDeep
            bevelWidth: card.wellBevelWidth
            shadowWidth: card.wellShadowWidth
        }

        Text {
            id: glyph
            readonly property string verb: card._shownVerb !== "" ? card._shownVerb : card._verbOf(card._side)
            readonly property real cx: card._side > 0
                ? Math.max(glyph.implicitWidth / 2 + card.glyphInset, card._band / 2)
                : Math.min(card.width - glyph.implicitWidth / 2 - card.glyphInset, card.width - card._band / 2)
            visible: glyph.text !== "" && card._presence > 0
            text: card._glyphOf(glyph.verb)
            color: Mix.c(Theme.textFaint, card._colorOf(glyph.verb), card._armed)
            opacity: card._presence
            font.family: card.glyphFamily
            font.pixelSize: card.glyphSize
            // Centred by hand, on whole pixels (anchors.centerIn rounds
            // differently); the card's frame is whole too.
            x: wellClip.slack + Math.round(glyph.cx - glyph.implicitWidth / 2)
            y: wellClip.slack + Math.round((card.height - glyph.implicitHeight) / 2)
        }
    }

    // The well's cut, in the layer's frame: the face's drawn rect there.
    Component {
        id: wellCutEffect
        ShaderEffect {
            property vector2d size: Qt.vector2d(wellClip.width, wellClip.height)
            property vector4d face: Qt.vector4d(
                card._faceX + (card._layered ? card._snap.x : 0) + wellClip.slack - card._wellSnap.x,
                (card._layered ? card._snap.y : 0) + wellClip.slack - card._wellSnap.y,
                card.width, card.height)
            property real radius: card.radius
            property real side: card._side
            property real reach: card.radius + 2
            property real tail: 8
            property real inset: 1
            property real aa: 1 / Math.max(0.0001, card._k)
            fragmentShader: "shaders/well_cut.frag.qsb"
        }
    }

    // ---- The face ----------------------------------------------------------------------
    // The layer's decision (THE FACE FADES AS ONE PICTURE): the drawn offset,
    // the state (a landed card draws nothing) -- all written in the chase and
    // the animations -- and the host's static wiring.
    readonly property bool _wantLayer: card._state !== "gone" && card._faceX !== 0
        && (card.sideFade !== null || card._faceOpacity < 1)
    property bool _layerLinger: false
    readonly property bool _layered: card._wantLayer || card._layerLinger
    function _dropLinger() {
        card._layerLinger = false;
    }
    on_LayeredChanged: if (card._layered) card._sample()

    // Sampled while layered (below): the whole-pixel snap, the card's scale
    // to the window's device pixels, one device pixel, and the face in the SideFade's frame
    // (the host's half of the cut -- its outline, its clip -- SideCut binds).
    // Every length handed to the cut is in the SideFade's units: a row may be
    // scaled on its way in or out of a list, so the rects are mapped corner to
    // corner and the displacement and the radius take the card's scale to it.
    property point _snap: Qt.point(0, 0)
    property point _wellSnap: Qt.point(0, 0)
    property real _k: 1
    property real _aa: 1
    property real _kf: 1
    property vector4d _uLayer: Qt.vector4d(0, 0, 0, 0)
    property vector4d _uRest: Qt.vector4d(0, 0, 0, 0)

    // mapToItem in a binding does not re-evaluate when an ancestor moves (a
    // neighbour's room closing moves this card), so the geometry is sampled
    // on the window's afterAnimating: after this frame's animations and
    // layouts, before it is synchronised. A frame in which nothing moved is a
    // frame nobody draws: the sampler costs nothing while the card is still.
    function _sample() {
        const s = face.slack;
        const o = card.mapToItem(null, card._faceX - s, -s);
        const u = card.mapToItem(null, card._faceX - s + 1, -s + 1);
        const kx = Math.abs(u.x - o.x) > 0.0001 ? u.x - o.x : 1;
        const ky = Math.abs(u.y - o.y) > 0.0001 ? u.y - o.y : 1;
        // the WINDOW's pixel ratio (the attached Screen's is the integer wl_output scale at a fractional Hyprland scale)
        const win = card.Window.window;
        const dpr = win && win.devicePixelRatio > 0 ? win.devicePixelRatio : 1;
        const sx = (Math.round(o.x * dpr) / dpr - o.x) / kx;
        const sy = (Math.round(o.y * dpr) / dpr - o.y) / ky;
        card._snap = Qt.point(sx, sy);
        const ws = wellClip.slack;
        const w0 = card.mapToItem(null, -ws, -ws);
        card._wellSnap = Qt.point((Math.round(w0.x * dpr) / dpr - w0.x) / kx, (Math.round(w0.y * dpr) / dpr - w0.y) / ky);
        // Device pixels per card unit: the layer's texture is seen at that size.
        card._k = kx * dpr;
        const f = card.sideFade;
        if (!f)
            return;
        const lo = card.mapToItem(f, card._faceX - s + sx, -s + sy);
        const hi = card.mapToItem(f, card._faceX - s + sx + face.width, -s + sy + face.height);
        const r0 = card.mapToItem(f, 0, 0);
        const r1 = card.mapToItem(f, card.width, card.height);
        const kf = card.width > 0 && Math.abs(r1.x - r0.x) > 0.0001 ? (r1.x - r0.x) / card.width : 1;
        card._kf = kf;
        // One device pixel, in the SideFade's units.
        card._aa = kf / Math.max(0.0001, kx * dpr);
        card._uLayer = Qt.vector4d(lo.x, lo.y, hi.x - lo.x, hi.y - lo.y);
        card._uRest = Qt.vector4d(r0.x, r0.y, r1.x - r0.x, r1.y - r0.y);
    }
    Connections {
        target: card._layered || card._wellLayer ? card.Window.window : null
        function onAfterAnimating() {
            card._sample();
        }
    }

    Shake {
        id: refusal
        amplitude: 6
    }

    Item {
        id: face
        objectName: "swipeFace"
        readonly property int slack: Math.max(0, card.bleedPx)
        x: card._faceX - face.slack + (card._layered ? card._snap.x : 0)
        y: -face.slack + (card._layered ? card._snap.y : 0)
        width: card.width + 2 * face.slack
        height: card.height + 2 * face.slack
        opacity: card._faceOpacity
        layer.enabled: card._layered
        layer.smooth: true
        layer.textureSize: Qt.size(Math.max(1, Math.ceil(face.width * card._k)), Math.max(1, Math.ceil(face.height * card._k)))
        layer.effect: card.sideFade ? cutEffect : null

        // The face proper: the card's size, at the drawn offset.
        Item {
            id: faceBody
            x: face.slack
            y: face.slack
            width: card.width
            height: card.height
            visible: !card.faceHidden

            // Under the host's content: whatever the content does not take is
            // the card's click.
            MouseArea {
                id: clickArea
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                cursorShape: Qt.PointingHandCursor
                onClicked: card.clicked()
            }
            // The content, apart from the click area so that only IT sizes the card.
            Item {
                id: holder
                width: faceBody.width
                height: faceBody.height
            }
        }
    }

    // The displaced face's cut and side fade (THE LIST; SideCut).
    Component {
        id: cutEffect
        SideCut {
            fade: card.sideFade
            layerRect: card._uLayer
            rest: card._uRest
            disp: card._faceX * card._kf
            cardRadius: card.radius * card._kf
            aa: card._aa
        }
    }

    // ---- The mouse's swipe ------------------------------------------------------------
    property var _dragHist: []
    DragHandler {
        id: drag
        target: null
        enabled: card.dragEnabled
        acceptedButtons: Qt.LeftButton
        yAxis.enabled: false
        dragThreshold: card.dragThreshold
        onActiveChanged: {
            if (drag.active) {
                card._dragHist = [];
                return;
            }
            card.release(card._dragVelocity());
        }
        onActiveTranslationChanged: {
            if (!drag.active)
                return;
            const now = Date.now();
            const h = card._dragHist;
            h.push({
                t: now,
                x: drag.activeTranslation.x
            });
            // Keep one sample older than the window as its baseline.
            while (h.length > 2 && now - h[1].t > 100)
                h.shift();
            card.scrub(drag.activeTranslation.x);
        }
    }
    // px/s over the last 100 ms before the release, measured from the last
    // sample before that window: a drag that stopped before the release has
    // no velocity, one released mid-motion has its motion's.
    function _dragVelocity() {
        const h = card._dragHist;
        const now = Date.now();
        if (h.length < 2 || now - h[h.length - 1].t > 100)
            return 0;
        const first = h[0];
        return (h[h.length - 1].x - first.x) / Math.max(0.03, (now - first.t) / 1000);
    }
}
