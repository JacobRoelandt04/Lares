pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "parts"
import "toast"

// =============================================================================
// NotificationToast.qml -- theNotification's content: the toast stack.
//
// A drop-in (CLAUDE.md): sized only through implicitWidth / implicitHeight,
// assuming nothing of its host beyond the content contract -- the engine's
// lane in the shell, a MockupStage or thePopup in the mockup.
//
//   entries   service.toasts.shown (at most `maxToasts`), NEWEST NEAREST THE
//             BAR: at the top under a top bar, at the bottom over a bottom
//             bar (hostRoom.edge), so a new one always lands at the join.
//   foot      "+N more" when the stack pushed older ones into the manager;
//             a click opens the manager.
//
// SIZE. implicitHeight is the stack's FINAL height from the moment a row's
// room starts to change -- a new row at once, a leaving one when its room
// starts to close (once its card has gone, ToastSlot `collapsing`), the foot
// when "+N more" comes or goes -- and the host eases the box over its own
// 260 ms while each room eases its extent on the same clock from the same
// frame: the content and the box move together (within 0.5 px on
// every frame) and the box never chases a height that moves every frame.
//
// GOING EMPTY. The owner closes the lane on the frame the scheduler's `shown`
// empties (it does not wait for the last row to drop: the box would first
// shrink to its padding and only then close, a very short state).
// The rows' exits still play inside the closing box, and the stack keeps
// reporting the height it had (`_holding`): the close starts from the full
// box, and nothing on the way asks the host for the empty stack's height
// (the rooms and the foot close once their cards and words have gone, inside
// the closing box). The hold is taken when `shown` changes, before a row is
// marked leaving, and ends when a toast arrives.
//
// LEAVING. A row whose uid left `shown` stays in the local model until its
// exit has played: flown off right when it went to the manager (a timeout,
// "+N more", or the user's swipe, which already flew it), flown off left when
// deleted by a swipe, faded in place when its record is gone (its app closed
// it, a click consumed it). Its room closes once the card has gone
// (ToastSlot).
//
// THE ARRIVAL. A new row's card stands at its resting place from its first frame and fades in there (ToastSlot) while its room
// opens and the box with it: no clip of the slot's, and none of the rows' clip's either (below) may uncover it from the bar's side.
// The rows are in the column in order, so the row after a newcomer paints over it: a neighbour that moves away uncovers the
// newcomer. The box's own edge (the engine's clip) hides what the box has not grown to yet.
//
// THE ROWS' CLIP. A card swiped sideways may not be drawn outside the popup
// (it would poke out of the rounded corner). The rows sit in a clip at
// SideFade's `clipInset`, and every card is handed that SideFade: a displaced
// card cuts itself to the host's outline -- the RESTING radii (`cornerRadius`
// on the corners away from the bar) at the box's LIVE size, `width` x
// `height`, which is the box the host draws this frame (the final
// implicitHeight would cut a card held while the stack resizes straight, 6 px in)
// -- and fades out before that cut (SwipeVerbCard, THE LIST; SideFade). A
// resting card is untouched. The clip spans the rows' drawn extent plus
// `rowSlack` above and below (a carved card's bevel), so it moves with the
// stack as rows come and go -- but an ARRIVING row counts whole from its first frame (ToastSlot `clipHeight`), a closing room or a
// waiting heir what it draws, so the clip never cuts the card that stands at its place while its room opens. What floats off a card
// (its time's tip, the "..." menu) lives in the stack's overlay, outside that clip.
//
// THE PADDING IS CLAMPED to what the side fade needs (`padding` >= the
// style's toastPadding): between the cut and a resting card's rim, in every
// row the corners reach, at least `_minRampPx` of ramp -- under that the
// fade is a step (a 6 px padding leaves one pixel, a 0 px one puts
// the rows' clip through a resting card). 10 at the defaults, so a padding
// the panel offers below it lays out as 10.
//
// THE FOOT. "+N more" is a row of the stack: its room eases on the rows'
// clock from the frame the count comes or goes, its words fade in and out
// (presence), and it sits at the rows' DRAWN end, so it moves with them --
// placed at their final end it would jump over a card still flying off and its
// well, and grow into the box's height at once while the box
// eases (the box would lag it by 20 px). The count keeps its last
// words while the foot fades out.
//
// THE LAST ROW'S FOG. The lane closes in two dimensions (the box shrinks to its
// bar) while the last card leaves in one (sideways), so while the stack is going
// empty a fog of the ground's colour comes in over the stack's edge on the bar's
// side -- its top under a top bar, its foot over a bottom one -- more and more
// as the cards' exits near their end: opacity = the LEAST advanced exit among
// the rows (`ToastSlot.exitFraction`, the exit's own motion: one clock, no
// clock of the fog's own), its band `sideFadeLength` long, the side fades' own.
// It exists only then (`holding`): nothing at rest, and no other exit has it. A
// toast arriving during the close ends the hold and the fog lets go over one
// presence fade, so nothing pops.
//
// THE HAND-OVER. A toast that arrives while another leaves (a click consumes one
// and its source posts the next; a progress toast withdrawn as its result is
// posted; a full stack filing its oldest) must not grow the box by the newcomer
// and then shrink it by the leaver -- a whole card's bump, in either order. So:
//   a row arriving while another row's CARD is still on its way out (fading,
//   flying) waits, its room held at nothing (ToastSlot `waiting`), and is that
//   row's heir; when the leaving row's room starts to close, the heir's room
//   starts to open in the same turn: one change of the height, both rooms and
//   the host's box on one clock, the box straight from the old size to the new.
//   A row arriving FIRST and the row it replaces marked leaving later in the
//   same turn (a post, then a withdraw) is turned into that row's heir before it
//   has moved (`isFresh`, `hold`).
//   A row arriving while rooms are already CLOSING opens at once and puts them on
//   its clock (`resyncClose`), so the stack's rows and the box ease together from
//   that frame (the box may already have come down: an arrival that late turns it).
// The wait is at most the leaving card's own exit (a 160 ms fade, a fly); a toast
// that arrives with nothing leaving opens at once, as it always did.
//
// GESTURES. One SwipeVerbReader over the rows; the content exposes the sticky
// gesture contract (swipeGestureActive + the hold size taken when the gesture
// latched + gestureWheel) so a row leaving under the fingers -- the stack
// shrinking -- never makes the rest of the gesture deaf (gestures.md §4).
// =============================================================================
Item {
    id: root

    property var service: null
    property var clock: null
    // Where a card's tips and "..." menu float: the host's overlay when it
    // hands one, else the stack's own (`_overlay`, above everything) -- never
    // inside a card, which sits in the rows' clip (THE ROWS' CLIP).
    property Item overlayItem: null
    readonly property Item _overlay: root.overlayItem ? root.overlayItem : overlayLayer
    property NotificationStyle style: null
    readonly property string fontFamily: root.style ? root.style.fontFamily : "Inter"
    readonly property real toastWidth: root.style ? root.style.toastWidth : 360
    // THE PADDING IS CLAMPED (see the header).
    readonly property real padding: Math.max(root.style ? root.style.toastPadding : 12, root._minPadding)
    readonly property real gap: root.style ? root.style.toastGap : 6
    readonly property int enterMs: root.style ? root.style.enterMs : 260
    readonly property int presenceMs: root.style ? root.style.presenceMs : 160
    property color surfaceColor: Theme.surface
    // The host's RESTING corner radius (the engine's maxR for the lane; never
    // the inflating popupRadius: while the popup moves the engine's own clip
    // is on). The corners on the bar's side are joins, not corners.
    property real cornerRadius: 20
    // How far above and below the cards the rows' clip lies: a carved card
    // draws its bevel 1 px outside itself (a clip on a carved
    // box's edge shears its bevel).
    property real rowSlack: root.style ? root.style.toastRowSlack : 2

    // The engine writes it when the content declares it (bar_structure.md).
    property var hostRoom: null
    readonly property bool newestAtBottom: !!root.hostRoom && root.hostRoom.edge === "bottom"

    // ---- the content contract ------------------------------------------------------
    readonly property bool swipeGestureActive: reader.active
    property real gestureHoldWidth: 0
    property real gestureHoldHeight: 0
    // The stronger of a reply being typed (on demand) and what the service's
    // interaction asks for (a rich body's keyboard, NotificationService
    // INTERACTION); and whether the lane takes the whole track as input (the
    // engine reads it: GooeyEngine `maskCatchAll`).
    //
    // THE REPLY FIELD OPENS UNDER A RESTING POINTER: the click that opened it was
    // on the Reply button, on this layer. A layer that asks for OnDemand keys
    // while the pointer RESTS on it gets nothing until the pointer moves or
    // clicks, so the first words typed would go to
    // the window under the toast. The popups of this shell that open a field under
    // the pointer ask for the pulse -- EXCLUSIVE for 120 ms, then OnDemand, the
    // compositor handing the keys to whatever is under the pointer at the switch,
    // which is this layer -- and so does this one (SystemUpdatePopup's idiom).
    readonly property string keyboardFocusRequest: {
        const rank = { none: 0, onDemand: 1, exclusive: 2 };
        const own = root._replying ? (root._replyPulse ? "exclusive" : "onDemand") : "none";
        const asked = root.service && root.service.interaction ? root.service.interaction.keyboard : "none";
        return rank[asked] > rank[own] ? asked : own;
    }
    readonly property bool maskCatchAll: !!root.service && !!root.service.interaction && root.service.interaction.catchAll === true
    function gestureWheel(ev) {
        return reader.gestureWheel(ev);
    }
    onSwipeGestureActiveChanged: {
        if (root.swipeGestureActive) {
            root.gestureHoldWidth = root.width;
            root.gestureHoldHeight = root.height;
        }
    }

    readonly property bool empty: rows.count === 0
    readonly property int moreCount: root.service && root.service.toasts ? root.service.toasts.moreCount : 0
    // The stack is going empty: every row is leaving, the height is held.
    readonly property bool holding: root._holding
    // A reply field is open on a toast of the stack: the scheduler's claim, which goes with the toast it
    // belongs to (a card destroyed with its field open says nothing of its own). Not readonly, so a probe
    // can stand in for an open field by writing it.
    property bool _replying: !!root.service && !!root.service.toasts && root.service.toasts.replyOpen === true
    // The reply field has just opened: the keys are asked for exclusively for a moment.
    property bool _replyPulse: false
    on_ReplyingChanged: {
        replyPulse.stop();
        root._replyPulse = root._replying;
        if (root._replying)
            replyPulse.start();
    }
    Timer {
        id: replyPulse
        interval: 120
        onTriggered: root._replyPulse = false
    }
    property bool _holding: false
    property real _heldH: 0

    // The style's palette (a host overrides a group's colour there, once).
    readonly property GroupPalette _groups: root.style && root.style.groups ? root.style.groups : ownGroups
    GroupPalette {
        id: ownGroups
    }

    // ---- the mirror of `shown`, with the leaving rows kept ------------------------
    ListModel {
        id: rows
        // { uid, leaving: bool }
    }
    function _sync() {
        const shown = root.service && root.service.toasts ? (root.service.toasts.shown || []) : [];
        // Going empty: hold the height the stack has NOW, before any row is
        // marked leaving (which takes it out of the height).
        if (shown.length === 0 && rows.count > 0 && !root._holding) {
            root._heldH = root.implicitHeight;
            root._holding = true;
        } else if (shown.length > 0) {
            root._holding = false;
        }
        const want = {};
        for (let i = 0; i < shown.length; i++)
            want[shown[i]] = true;
        // Rows that left: start their exit (the delegate removes itself after it).
        for (let i = 0; i < rows.count; i++) {
            const r = rows.get(i);
            if (!want[r.uid] && !r.leaving)
                rows.setProperty(i, "leaving", true);
        }
        // Rows that arrived: newest nearest the bar.
        const have = {};
        for (let i = 0; i < rows.count; i++)
            have[rows.get(i).uid] = true;
        for (let i = shown.length - 1; i >= 0; i--) {
            const u = shown[i];
            if (have[u])
                continue;
            if (root.newestAtBottom)
                rows.append({ uid: u, leaving: false });
            else
                rows.insert(0, { uid: u, leaving: false });
        }
    }
    function _drop(uid) {
        for (let i = 0; i < rows.count; i++) {
            if (rows.get(i).uid === uid) {
                rows.remove(i);
                break;
            }
        }
        // A uid shown again while its old row was leaving is skipped (the
        // row is still here): the sync brings it in now.
        root._sync();
    }
    // ---- THE HAND-OVER (header) ------------------------------------------------------------------------------------
    // The slots from the bar's end (newest first): an arrival lands there, and pairs with the leaving row nearest it.
    function _slotsFromBar(): var {
        const out = [];
        for (let i = 0; i < slots.count; i++) {
            const s = slots.itemAt(root.newestAtBottom ? slots.count - 1 - i : i) as ToastSlot;
            if (s)
                out.push(s);
        }
        return out;
    }
    // The leaving row a new row waits for: its card still on its way out and nobody waiting for it yet.
    function _partnerFor(s: ToastSlot): ToastSlot {
        const all = root._slotsFromBar();
        for (let i = 0; i < all.length; i++) {
            const t = all[i];
            if (t !== s && t.leaving && !t.collapsing && !t.heir)
                return t;
        }
        return null;
    }
    function _arrived(slot: ToastSlot): void {
        const heir = root._partnerFor(slot);
        if (heir) {
            heir.heir = slot;
            slot.waiting = true;
            return;
        }
        // Rooms already closing: on this arrival's clock (it starts in this turn).
        const all = root._slotsFromBar();
        for (let i = 0; i < all.length; i++) {
            if (all[i] !== slot && all[i].collapsing)
                all[i].resyncClose();
        }
    }
    function _leavingStarted(slot: ToastSlot): void {
        if (slot.heir)
            return;
        const all = root._slotsFromBar();
        for (let i = 0; i < all.length; i++) {
            if (all[i] !== slot && all[i].isFresh()) {
                all[i].hold();
                slot.heir = all[i];
                return;
            }
        }
    }

    Connections {
        target: root.service ? root.service.toasts : null
        ignoreUnknownSignals: true
        // `shown` first: it changes before the scheduler resets `moreCount`.
        function onShownChanged() {
            root._sync();
        }
        function onSerialChanged() {
            root._sync();
        }
    }
    Component.onCompleted: {
        // A stack built with "+N more" already counted (a lane that comes
        // back) shows its foot as it is, as it shows its rows.
        if (root.moreCount > 0) {
            root._footCount = root.moreCount;
            root._footIn = true;
            root._footExtent = 1;
            root._footPresence = 1;
        }
        root._sync();
    }

    // The final height: what every row will be once its easing is over. Every
    // slot carries its gap on the side AWAY from the bar (a slot growing from
    // nothing brings its own gap with it, so no neighbour jumps), and the
    // padding on that side gives the last gap back: space above = space below.
    // A leaving row counts until its room starts to close (ToastSlot
    // `collapsing`), so the box and the room shrink from the same frame.
    readonly property real _stackH: {
        let h = 0;
        for (let i = 0; i < slots.count; i++) {
            const s = slots.itemAt(i) as ToastSlot;
            if (!s || s.collapsing || s.waiting)
                continue;
            h += s.entryHeight + root.gap;
        }
        return h;
    }
    // THE FOOT's room, final (what implicitHeight counts) and drawn.
    readonly property real _footRoom: foot.implicitHeight + root.gap
    readonly property real _footH: root._footIn ? root._footRoom : 0
    readonly property real _liveH: Math.ceil(root.padding * 2 - root.gap + root._stackH + root._footH)

    implicitWidth: Math.ceil(root.toastWidth + root.padding * 2)
    implicitHeight: root._holding ? root._heldH : root._liveH

    // Where the stack's first slot starts, and the rows' drawn extent (the
    // Column as it is this frame, without the gap its last slot carries).
    readonly property real _stackTop: root.newestAtBottom ? root.padding - root.gap + footRoom.height : root.padding
    readonly property real _rowsTop: root._stackTop + (root.newestAtBottom ? root.gap : 0)
    // What the rows' clip spans: the drawn extent, except that an ARRIVING row counts at its final height from its first
    // frame (ToastSlot `clipHeight`), so the clip does not cut the card that stands at its place while its room opens.
    readonly property real _rowsH: {
        let h = 0;
        for (let i = 0; i < slots.count; i++) {
            const s = slots.itemAt(i) as ToastSlot;
            if (s)
                h += s.clipHeight;
        }
        return Math.max(0, h - root.gap);
    }
    // The resting outline's corners [tl, tr, br, bl]: rounded away from the bar.
    readonly property var _radii: {
        const R = root.cornerRadius;
        switch (root.hostRoom ? root.hostRoom.edge : "") {
        case "top":
            return [0, 0, R, R];
        case "bottom":
            return [R, R, 0, 0];
        case "left":
            return [0, R, R, 0];
        case "right":
            return [R, 0, 0, R];
        default:
            return [R, R, R, R];
        }
    }

    HoverHandler {
        id: hover
        onHoveredChanged: {
            if (root.service && root.service.toasts)
                root.service.toasts.hover(hover.hovered);
        }
    }

    // The rows' strip: the host's full width, the rows' vertical clip.
    Item {
        id: rowStrip
        y: Math.floor(root._rowsTop - root.rowSlack)
        width: root.implicitWidth
        height: Math.ceil(root._rowsTop + root._rowsH + root.rowSlack) - rowStrip.y

        Item {
            id: rowClip
            objectName: "toastRowClip"
            x: fade.clipInset
            width: rowStrip.width - 2 * rowClip.x
            height: rowStrip.height
            clip: true

            Column {
                id: stack
                objectName: "toastStack"
                x: root.padding - rowClip.x
                y: root._stackTop - rowStrip.y
                width: root.toastWidth

                Repeater {
                    id: slots
                    model: rows

                    delegate: ToastSlot {
                        id: slotItem
                        width: stack.width
                        service: root.service
                        clock: root.clock
                        overlayItem: root._overlay
                        style: root.style
                        groups: root._groups
                        surfaceColor: root.surfaceColor
                        newestAtBottom: root.newestAtBottom
                        sideFade: fade
                        onGone: uid => root._drop(uid)
                        onArrived: root._arrived(slotItem)
                        onLeavingStarted: root._leavingStarted(slotItem)
                    }
                }
            }
        }
    }
    // The fog (see THE LAST ROW'S FOG): the cards' column, over the rows' edge
    // nearest the bar, on whole pixels.
    readonly property real _fogRaw: {
        if (slots.count === 0)
            return 1;
        let m = 1;
        for (let i = 0; i < slots.count; i++) {
            const s = slots.itemAt(i) as ToastSlot;
            if (s)
                m = Math.min(m, s.exitFraction);
        }
        return m;
    }
    property real _fogGate: root._holding ? 1 : 0
    // The strength the last exit reached, latched: an arrival during the close
    // makes a non-leaving row at once (the raw strength falls to 0 in that
    // frame), so the release fades what was SHOWN, not the new raw value. An
    // exit's strength never falls, so the latch is its high-water mark.
    property real _fogHeld: 0
    on_FogRawChanged: if (root._holding) root._fogHeld = Math.max(root._fogHeld, root._fogRaw)
    onHoldingChanged: {
        fogRelease.stop();
        if (root._holding) {
            root._fogHeld = root._fogRaw;
            root._fogGate = 1;
        } else {
            fogRelease.start();
        }
    }
    NumberAnimation {
        id: fogRelease
        target: root
        property: "_fogGate"
        to: 0
        duration: root.presenceMs
        easing.type: Easing.OutCubic
    }
    readonly property real fogStrength: root._fogGate * (root._holding ? root._fogRaw : root._fogHeld)
    readonly property real _fogLength: root.style ? root.style.sideFadeLength : 34
    Rectangle {
        id: topFog
        objectName: "toastTopFog"
        x: root.padding
        width: root.toastWidth
        height: root._fogLength
        y: root.newestAtBottom ? rowStrip.y + rowStrip.height - topFog.height - Math.round(root.rowSlack)
                               : rowStrip.y + Math.round(root.rowSlack)
        opacity: root.fogStrength
        visible: opacity > 0.002
        readonly property color clear: Qt.rgba(root.surfaceColor.r, root.surfaceColor.g, root.surfaceColor.b, 0)
        gradient: Gradient {
            GradientStop {
                position: 0.0
                color: root.newestAtBottom ? topFog.clear : root.surfaceColor
            }
            GradientStop {
                position: 1.0
                color: root.newestAtBottom ? root.surfaceColor : topFog.clear
            }
        }
    }
    SideFade {
        id: fade
        objectName: "toastSideFade"
        target: rowStrip
        inset: root._fadeInset
        rimPx: root._fadeRim
        leadPx: root._fadeLead
        cornerMargin: root._fadeMargin
        fadeLength: root.style ? root.style.sideFadeLength : 34
        // The box as the host draws it this frame (THE ROWS' CLIP).
        outline: ({ x: 0, y: -rowStrip.y, w: root.width, h: root.height, radii: root._radii })
    }
    readonly property real _fadeInset: root.style ? root.style.sideFadeInset : 2
    readonly property real _fadeRim: root.style ? root.style.sideFadeRimPx : 2
    readonly property real _fadeLead: root.style ? root.style.sideFadeLeadPx : 1
    readonly property real _fadeMargin: root.style ? root.style.sideFadeCornerMargin : 1

    // THE PADDING IS CLAMPED: the least padding whose every row, straight or
    // in a corner, leaves `_minRampPx` between the cut and a resting card's
    // rim -- side_cut.frag's short ramp, own - zero line - lead, with the
    // card at the padding from a corner of the outline's largest radius.
    // 5 px: the step between neighbouring columns is <= 0.126 wherever the
    // layout leaves 5 (0.42 with one).
    readonly property real _minRampPx: 5
    readonly property real _minPadding: root._leastPadding(Math.max(...root._radii), root.style ? root.style.cardRadius : 14,
                                                           Math.max(0, Math.round(root._fadeInset)), root._fadeMargin,
                                                           root._fadeLead, root._fadeRim, root._minRampPx)
    function _leastPadding(R, r, clip, m, lead, rim, need) {
        const Rm = Math.max(0, R - m);
        for (let p = 0; p < 64; p++) {
            if (p - rim - Math.max(clip, m) - lead < need)
                continue;
            let ok = true;
            // The card's rows from its edge until both its corner and the
            // outline's are straight (pixel centres).
            for (let e = 0.5; ok && (e < r || p + e - m < Rm); e += 1) {
                const d = p + e - m;
                const span = d < Rm ? m + Rm - Math.sqrt(Rm * Rm - (Rm - d) * (Rm - d)) : m;
                const own = (e < r ? p + r - Math.sqrt(r * r - (r - e) * (r - e)) : p) - rim;
                ok = own - Math.max(clip, span) - lead >= need;
            }
            if (ok)
                return p;
        }
        return 64;
    }

    // THE FOOT: a room of its own on the rows' clock, at the rows' drawn end,
    // entering as a row enters (room and presence together) and leaving as a
    // row leaves (the words fade, then the room closes: `_footIn` is what the
    // height counts, so the box and the room start from the same frame).
    property real _footExtent: 0
    property real _footPresence: 0
    property bool _footIn: false
    property int _footCount: 0
    onMoreCountChanged: {
        if (root.moreCount > 0) {
            root._footCount = root.moreCount;
            if (!root._footIn) {
                footOut.stop();
                footShrink.stop();
                root._footIn = true;
                footIn.start();
            }
        } else if (root._footIn) {
            footIn.stop();
            footOut.start();
        }
    }
    ParallelAnimation {
        id: footIn
        NumberAnimation {
            target: root
            property: "_footExtent"
            to: 1
            duration: root.enterMs
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: root
            property: "_footPresence"
            to: 1
            duration: root.presenceMs
            easing.type: Easing.OutCubic
        }
    }
    NumberAnimation {
        id: footOut
        target: root
        property: "_footPresence"
        to: 0
        duration: root.presenceMs
        easing.type: Easing.OutCubic
        onFinished: {
            root._footIn = false;
            footShrink.start();
        }
    }
    NumberAnimation {
        id: footShrink
        target: root
        property: "_footExtent"
        to: 0
        duration: root.enterMs
        easing.type: Easing.OutCubic
    }
    Item {
        id: footRoom
        objectName: "toastFootRoom"
        x: root.padding
        // Away from the bar: after the rows' drawn end (a top bar), or above
        // them at the padding (a bottom bar); revealed from the rows' side
        // while it opens (a row no longer is: THE ARRIVAL -- the foot stands
        // at the rows' drawn end, which moves, so it has no place of its own
        // to fade in at).
        y: root.newestAtBottom ? root.padding - root.gap : root._stackTop + stack.height
        width: root.toastWidth
        height: Math.round(root._footRoom * root._footExtent)
        clip: root._footExtent < 1

        ToastFoot {
            id: foot
            objectName: "toastFoot"
            y: root.newestAtBottom ? root.gap : 0
            width: root.toastWidth
            count: root._footCount
            fontFamily: root.fontFamily
            fontPixelSize: root.style ? root.style.stackFootSize : 11
            hoverMs: root.style ? root.style.footHoverMs : 120
            opacity: root._footPresence
            visible: root._footPresence > 0.001
            onClicked: {
                if (root.service)
                    root.service.openManagerRequested(root.service.laneScreen);
            }
        }
    }

    SwipeVerbReader {
        id: reader
        anchors.fill: rowStrip
        units: root.style ? root.style.swipeUnits : 900
        flingUnitsPerS: root.style ? root.style.swipeFlingUnitsPerS : 2600
        pullThrough: root.style ? root.style.swipePullThrough : 2.0
        idleMs: root.style ? root.style.swipeIdleMs : 6000
        mouseIdleMs: root.style ? root.style.swipeMouseIdleMs : 400
        sign: root.style ? root.style.swipeSign : 1
        rowAt: (x, y) => {
            const p = reader.mapToItem(stack, x, y);
            const s = stack.childAt(p.x, p.y) as ToastSlot;
            // A row already on its way out takes no new gesture (nor one still waiting to come in).
            return s && !s.leaving && !s.waiting ? s.card : null;
        }
    }

    // The stack's own overlay (see `overlayItem`): last, above the rows.
    Item {
        id: overlayLayer
        objectName: "toastOverlay"
        anchors.fill: parent
        z: 100
    }
}
