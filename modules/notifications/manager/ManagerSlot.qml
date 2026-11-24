pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"
import "../../common/theme"
import ".."

// =============================================================================
// ManagerSlot.qml -- one row of the manager's list (a group's header, or an
// entry: a notification or an app's bundle): an AnimatedListRow, so the list's
// wave (ListWave) flies it in and out like any row, plus the ROOM the row
// takes, which the manager eases itself for the motions that are not a wave:
//
//   grow      0..1, the room a SINGLE ARRIVAL grows in place (the toast's rule:
//             a new notification grows its room where it lands, with a
//             presence fade, instead of sliding in from beyond the clip).
//             One clock: `arrive()` eases it over `arriveMs`, OutCubic. A
//             group's first arrival grows its header and its card as ONE block
//             on the section's clock (`arriveJoined()`: the section writes
//             `grow`).
//   presence  0..1, the arrival's fade (`presenceMs`).
//   reveal    0..1, a pin flight's share of this slot (RowFlight): the
//             destination opens as the clone comes in, the slot it left
//             (`phantomHeight` > 0) closes as the destination opens.
//   flipY     px, a row the model MOVED (an app's new notification taking its
//             row to the top of its group, a bundle falling below a neighbour
//             when its head is pinned away) is drawn where it was and eases to
//             its new place over `arriveMs`, OutCubic -- as are the rows it
//             passes (`flip(dy)`, the section measures both). The
//             translate is on the room, so the SLOT's geometry is always the
//             layout's: a flight measuring its destination reads the place it
//             will rest, not a frame of the motion.
//
// THE ROOM CARRIES ITS OWN GAP. The list's gaps are per-row margins, never a
// positioner's spacing (CLAUDE.md: a Column's spacing lands on the other side
// of a row that moves, and a row growing from nothing would bring its gap in
// one step). `gapAbove` / `gapBelow` are part of the room and grow with it, so
// a row that arrives or leaves takes its gap with it, continuously. The
// manager's rhythm: a header 6 above and 6 below its box, an entry 6 below its
// card -- 6 between cards, 12 between groups, 6 at both ends of the list.
//
// A CARD SWIPED OFF LEAVES THE WAY IT FLEW. The wave slides a leaving row out
// to the right; a row whose card has already flown off (`bodyItem.flownSign`,
// SwipeVerbCard) keeps its content where it is instead -- the slide is taken
// back off the room -- so the card goes on with its own flight alone and its
// room closes under it. Slid as well, a card swiped left would come back to
// the right on the wave and a card swiped right cross the list twice as fast.
// The slot itself still slides: ListWave judges its
// flights by the row's x.
//
// The room is whole pixels (Math.round), so the list and the popup's box step
// in pixels while it eases, as the toast's slots do.
//
// THE MOVING EDGE IS FOG, NOT A BLADE: the fog fade that appears when
// sliding a notification either side is there when expanding or collapsing
// a header too, never a harsh cutoff line. A row
// that grows or shrinks (the wave's extent, an arrival's grow, a flight's
// reveal) shows only the top `implicitHeight` of its room: what is below that
// edge is cut. Left to the neighbour, the cut would be the NEXT row's top drawn
// over the card -- a hard line across it; clipped by the room, it would be a
// hard line of the room's own. So the content is clipped to the height the row shows
// and a SeamFade dissolves its last `fogPx` into the ground at that edge --
// the list's own vocabulary, the length the side cut's long ramp has. One
// mechanism for every way a row's height moves, and nothing of it at rest: the
// clip is off and the band's opacity is 0 whenever the row is whole (the clip
// keeps the carved boxes' bevel slack on the top and sides, as EaseBox does).
//
// A BUNDLE'S CARDS ARE ROWS OF THE LIST (so the staggered exit of the items in
// a category holds when a group of notifications is expanded).
// An app's open bundle is its head card and one row per member under it, and
// each of them is a ManagerSlot the list's wave flies on its own step. The
// members live in this slot's TAIL, under the head's room: the slot is the HEAD
// row -- its `implicitHeight` and `_fullHeight`, what ListWave reads, are the
// head's alone -- and its layout `height` is the head plus the tail, so the
// section's Column lays the whole entry out as one. The tail holds still while
// the head slides (`x: -slot.x`) and rides the head's reorder translate. A
// slot with no tail is a plain row.
// =============================================================================
AnimatedListRow {
    id: slot

    default property alias body: inner.data

    property real gapAbove: 0
    property real gapBelow: 6
    property real grow: 1
    property real presence: 1
    property real reveal: 1
    // > 0: this slot is the hole a flown row left; it holds this height
    // times (1 - reveal) and draws only what its card leaves (the well of a
    // swipe fading where the face was: the clone draws the face).
    property real phantomHeight: 0
    property int arriveMs: 260
    property int presenceMs: 160
    // The undo token of the clear this row left in ("" none): its section
    // keeps it, gone, while that undo is on offer (GroupSection).
    property string heldBy: ""
    property real flipY: 0
    // The ground the fog dissolves into (the card the row sits on) and how
    // long it is: the side cut's long ramp (SideFade.fadeLength).
    property color groundColor: Theme.surface
    property real fogPx: 34
    // The place in the list's layout order, for a host that gathers rows to
    // hand to the wave (the header -1, an entry its index, a bundle's member
    // its entry's index and a fraction of its own).
    property real order: 0
    // What an expansion opens under, when it is not the nearest sibling above
    // (a bundle's first member opens under its head), and the view y that
    // header may rise to (-1: the wave's own line): ListWave's `waveKeep` /
    // `waveTopPx`.
    property Item waveKeep: null
    property real waveTopPx: -1

    // What the slot holds (its one child), for a host that asks it things.
    readonly property Item bodyItem: inner.children.length > 0 ? inner.children[0] : null
    // The room it takes when it is all there (its gaps included).
    readonly property real fullHeight: room._full
    // Which way the card of this row was swiped off (0: it was not).
    readonly property int flown: {
        const c = slot.bodyItem as SwipeVerbCard;
        if (c)
            return c.flownSign;
        const b = slot.bodyItem as AppBundleRow;
        if (b)
            return b.flownSign;
        const e = slot.bodyItem as EaseBox;
        const m = e ? e.child as SwipeVerbCard : null;
        return m ? m.flownSign : 0;
    }
    // Where this slot's tail goes (a bundle's members: AppBundleRow).
    readonly property Item tailHost: tail

    signal holeClosed()

    virtualSpacing: 0
    // The entry as the Column sees it: the head's animated height, then the tail.
    height: slot.implicitHeight + tail.height

    function arrive() {
        slot.grow = 0;
        slot.presence = 0;
        growAnim.duration = slot.arriveMs;
        growAnim.restart();
        presenceAnim.restart();
    }
    // A share of a joint arrival: the section writes `grow` on its one clock.
    function arriveJoined() {
        growAnim.stop();
        slot.grow = 0;
        slot.presence = 0;
        presenceAnim.restart();
    }
    // An arrival that starts part way (a flight's destination the flight
    // opened only so far before it ended).
    function arriveFrom(f) {
        slot.grow = Math.max(0, Math.min(1, f));
        slot.presence = 1;
        growAnim.duration = Math.max(1, Math.round(slot.arriveMs * (1 - slot.grow)));
        growAnim.restart();
    }
    function place() {
        growAnim.stop();
        presenceAnim.stop();
        slot.grow = 1;
        slot.presence = 1;
    }
    // Drawn `dy` px from where the layout now puts it, easing home. A second
    // move while one eases starts from what is drawn.
    function flip(dy) {
        flipAnim.stop();
        slot.flipY += dy;
        slot.z = Math.max(1, Math.abs(slot.flipY));
        flipAnim.from = slot.flipY;
        flipAnim.restart();
    }
    // A hole whose flight is over while it still holds room (the flight never
    // travelled): it closes on its own clock from where it is, then says so.
    property real _holeF: -1
    function closeHole(from) {
        slot._holeF = Math.max(0, Math.min(1, from));
        holeAnim.from = slot._holeF;
        holeAnim.duration = Math.max(1, Math.round(slot.arriveMs * slot._holeF));
        holeAnim.restart();
    }

    // The rows under the head (see the head of the file). Parented to the slot,
    // not to its holder: the head's extent and fade are not theirs.
    Column {
        id: tail
        parent: slot
        x: -slot.x
        y: slot.implicitHeight
        width: slot.width
        transform: Translate {
            y: slot.flipY
        }
    }

    NumberAnimation {
        id: growAnim
        target: slot
        property: "grow"
        to: 1
        easing.type: Easing.OutCubic
    }
    NumberAnimation {
        id: presenceAnim
        target: slot
        property: "presence"
        to: 1
        duration: slot.presenceMs
        easing.type: Easing.OutCubic
    }
    NumberAnimation {
        id: flipAnim
        target: slot
        property: "flipY"
        to: 0
        duration: slot.arriveMs
        easing.type: Easing.OutCubic
        onFinished: slot.z = 0
    }
    NumberAnimation {
        id: holeAnim
        target: slot
        property: "_holeF"
        to: 0
        easing.type: Easing.OutCubic
        onFinished: slot.holeClosed()
    }

    Item {
        id: room
        width: slot.width
        // The wave's slide taken back off a card that already flew.
        x: slot.flown !== 0 ? -slot.x : 0
        readonly property real _full: slot.phantomHeight > 0 ? slot.phantomHeight
            : inner.childrenRect.height + slot.gapAbove + slot.gapBelow
        readonly property real _f: slot.phantomHeight > 0 ? (slot._holeF >= 0 ? slot._holeF : 1 - slot.reveal)
            : slot.grow * slot.reveal
        implicitHeight: Math.round(room._full * Math.max(0, Math.min(1, room._f)))
        height: room.implicitHeight
        transform: Translate {
            y: slot.flipY
        }

        // What the row shows: its content down to `implicitHeight` (the room
        // times the wave's extent), with the bevel's slack above and beside it.
        // Never clipped at rest (a clip on a carved box's edge shears its bevel).
        Item {
            id: cutter
            readonly property real slack: 2
            readonly property real shown: Math.min(room.height, slot.implicitHeight)
            x: -cutter.slack
            y: -cutter.slack
            width: room.width + 2 * cutter.slack
            height: cutter.shown + cutter.slack
            clip: cutter.shown < room._full - 0.5

            Item {
                id: inner
                x: cutter.slack
                y: cutter.slack + slot.gapAbove
                width: room.width
                height: inner.childrenRect.height
                opacity: slot.presence
                // A hole draws what its card leaves while the flight runs (the
                // swipe's well fading: the face is the clone's); one closing on
                // its own clock after the flight draws nothing.
                visible: slot.phantomHeight <= 0 || slot._holeF < 0
            }

            // The fog at the moving edge: a hole keeps its hard edge (it
            // shows only the well a card leaves).
            SeamFade {
                ground: slot.groundColor
                fadeHeight: slot.fogPx
                extent: slot.phantomHeight > 0 || room._full <= 0 ? 1 : Math.max(0, Math.min(1, cutter.shown / room._full))
            }
        }
    }
}
