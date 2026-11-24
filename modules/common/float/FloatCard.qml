pragma ComponentBehavior: Bound

import QtQuick

import "FloatMotion.js" as Float

// =============================================================================
// FloatCard.qml -- one floating card: an Item whose own transform is the card's pose, so what is declared inside it sways, tilts towards the pointer,
// lifts under the hand and is dealt in when the popup opens (the theme popup's Balatro float, shared). Position it as any Item (x/y, anchors): the
// pose is drawn about that place and never moves the layout.
//
//   clock        the popup's one FloatClock: it steps every card registered with it. null: the card stands still at rest (pose 0, the plain item).
//   style        the numbers (FloatStyle). null: the card stands still at rest, whatever its clock
//   seed         this card's own sway (FloatMotion.make): two cards with two seeds are never in step. Stable per card, so a card sways the same way
//                at every open (a note: a hash of its key).
//   stateKey     "": the sway is this card's own. A key: the clock keeps the sway under it, so a card rebuilt for the same thing (a delegate
//                handed from one grid to another) sways on where the last one was. Stepped once a tick, however many cards show it.
//   order        its place in the deal (reading order)
//   floats       false: the deal only, no sway, no tilt (a place that is part of the page: the notes' + slot, the weather popup's hero)
//   lifted       the hand is on it: it lifts (liftScale)
//   tilting      the pointer is on it: it leans towards pointerX / pointerY (-1 .. 1 across the card)
//   dealTurnSign which way the deal turns it; every other card the other way by default
//   pose*        the pose the last tick drew (a probe, a ghost that leaves from where the card was drawn)
//   kick(v)      a push on the lift (a click's answer)
//
// INPUT FOLLOWS THE PICTURE when it is declared inside: a MouseArea or HoverHandler in a FloatCard is hit-tested through its transform, so a click
// lands where the card is drawn. The lift is the hysteresis: a card the pointer enters grows towards it by more than it sways or leans, so the
// pointer does not slip off its edge. Input on the resting rect instead (the theme card: its tilt never chases itself) is declared beside it.
// =============================================================================
Item {
    id: card

    property FloatClock clock: null
    property FloatStyle style: null
    property int seed: 1
    property string stateKey: ""
    property int order: 0
    property bool floats: true
    property bool lifted: false
    property bool tilting: false
    property real pointerX: 0
    property real pointerY: 0
    property real dealTurnSign: card.order % 2 === 0 ? 1 : -1

    property real poseX: 0
    property real poseY: 0
    property real poseRot: 0
    property real poseTiltX: 0
    property real poseTiltY: 0
    property real poseLift: 0

    property var _st: null

    // One step of the clock. True while this card still moves fast (its deal, or a spring the pointer pulled): the clock stays on every frame.
    function advance(dt: real): bool {
        const s = card.style;
        if (!s)
            return false;
        const age = card.clock ? card.clock.dealAge : 1e6;
        const delay = card.order * s.dealStaggerMs / 1000;
        const dur = s.dealMs / 1000;
        const left = Float.dealLeft(age, delay, dur);
        const dealing = age < delay + dur;
        if (!card.floats) {
            card.poseY = left * s.dealRise;
            card.poseRot = left * s.dealTurn * card.dealTurnSign;
            return dealing;
        }
        if (!card._st)
            card._st = card.stateKey !== "" && card.clock ? card.clock.stateFor(card.stateKey, card.seed, s) : Float.make(card.seed, s);
        const st = card._st;
        const ask = {
            tx: card.tilting ? card.pointerX : 0,
            ty: card.tilting ? card.pointerY : 0,
            lift: card.lifted ? 1 : 0
        };
        const n = card.clock ? card.clock.tickNo : 0;
        if (st.tick !== n) {
            st.tick = n;
            Float.step(st, dt, s, ask);
        }
        card._pose(st, left);
        return dealing || !Float.settled(st, ask);
    }
    function _pose(st: var, left: real): void {
        const s = card.style;
        const k = card.clock ? card.clock.sway : 1;
        card.poseX = st.x.v * k;
        card.poseY = st.y.v * k + left * s.dealRise;
        card.poseRot = st.rot.v * k + left * s.dealTurn * card.dealTurnSign;
        card.poseTiltX = st.tx.v;
        card.poseTiltY = st.ty.v;
        card.poseLift = st.lift.v;
    }
    function kick(v: real): void {
        if (card._st)
            Float.kick(card._st, v);
        card._wake();
    }

    // The pointer's asks reach the clock at once: a card the pointer enters leans on the next frame, not on the next rest tick.
    function _wake(): void {
        if (card.clock)
            card.clock.wake();
    }
    onLiftedChanged: card._wake()
    onTiltingChanged: card._wake()
    onPointerXChanged: if (card.tilting) card._wake()
    onPointerYChanged: if (card.tilting) card._wake()

    // Registered with the clock it has; a destroyed clock reads null here, and there is nothing to take back.
    property FloatClock _reg: null
    function _sync(): void {
        if (card._reg === card.clock)
            return;
        if (card._reg)
            card._reg.unregister(card);
        card._reg = card.clock;
        if (card.clock)
            card.clock.register(card);
        // A card built for something whose sway the clock already keeps is drawn where that sway is, from its first frame (not at rest
        // until the next tick: a morph that leaves from this card would start from the wrong place).
        const st = card.floats && card.style && card.stateKey !== "" && card.clock ? card.clock.stateKept(card.stateKey) : null;
        if (st) {
            card._st = st;
            card._pose(st, 0);
        }
    }
    onClockChanged: card._sync()
    Component.onCompleted: card._sync()
    Component.onDestruction: {
        if (card._reg)
            card._reg.unregister(card);
    }

    transform: [
        Translate {
            x: card.poseX
            y: card.poseY
        },
        Rotation {
            origin.x: card.width / 2
            origin.y: card.height / 2
            angle: card.poseRot
        },
        Rotation {
            origin.x: card.width / 2
            origin.y: card.height / 2
            axis.x: 1
            axis.y: 0
            axis.z: 0
            distanceToPlane: card.style ? card.style.planeDistance : 700
            angle: card.style ? -card.poseTiltY * card.style.tiltMax : 0
        },
        Rotation {
            origin.x: card.width / 2
            origin.y: card.height / 2
            axis.x: 0
            axis.y: 1
            axis.z: 0
            distanceToPlane: card.style ? card.style.planeDistance : 700
            angle: card.style ? card.poseTiltX * card.style.tiltMax : 0
        },
        Scale {
            origin.x: card.width / 2
            origin.y: card.height / 2
            xScale: card.style ? 1 + card.poseLift * (card.style.liftScale - 1) : 1
            yScale: xScale
        }
    ]
}
