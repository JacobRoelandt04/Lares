pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import "../../../common/theme"
import "../../../common/scroll"
import "../../../common/components"
import "../../../common/components/Bytes.js" as Bytes
import "../../../common/components/Mix.js" as Mix

// =============================================================================
// PlayerQueue.qml
//
// The play queue, as the INSIDE of its own carved list box: the container, the
// flick and the dressing all belong to this file, because the popup only places
// the panel — it does not dress it. The list-box stack is the system update's:
// a ShadowBox whose viewport fills it EXACTLY, rows inset by 6 rather than the
// viewport, and the wheel read by a MouseArea over the list that feeds the
// shell's KineticScroll (a notch glides, a lift coasts; modules/common/scroll).
// The fades and the corner re-cut are the shared
// `CarvedListDressing`.
//
// HOW THE LIST MOVES — docs/contracts/list_animation.md, in full
// -----------------------------------------------------------
// Only what is on screen animates; everything past the fold is PLACED. A queue
// replaced wholesale is a SWAP, and a swap is a collapse followed by an expand
// — never two waves running through each other. `_sync` decides who leaves,
// `_applyArrivals` decides who flies in, and the two are sequenced by
// `leaveCleanup` + `enterDelay` so the second can never overlap the first.
//
// THE TAIL IS HELD BACK, NOT PLACED EARLY (list_animation.md, section 2a)
// -----------------------------------------------------------------------
// The rows that will land below the fold take their SLOT in the frame the
// expansion begins — so the box is at its true height at once, and the fade,
// the scroll range and the foot are right from that instant — but they are
// not DRAWN until the staggered head has finished entering. Drawing them at
// once is not "instant", it is EARLY: with the head still at zero height the
// tail is on screen ABOVE the rows that belong above it, and is then shoved
// down by them as they arrive. Holding the slot without the ink is the
// reading taken here, because it is the only one that satisfies both halves
// of the doc: nothing is visible before the fold is where it will finally be,
// and the container never lies about its height.
//
// Its turn is the frame the LAST ROW THE USER CAN SEE lands — the frame the
// viewport is full, which is one stagger step before the head's own last row,
// since that one is the overscan row below the fold — and that moment is fixed
// when the wave is decided (`tailReveal`).
// It is not the settle's: a settle is extended by every row a scrolling
// hand reveals, so the tail's turn would run away from a hand scrolling
// towards it, and rows would arrive one at a time, out of order, for as long
// as the list has rows left.
//
// Before that landing it is reassessed while it runs, as the doc asks: a held
// row the user scrolls to before its turn reveals itself (`peeked` on the
// delegate) and slides in rather than popping — with its height HELD, so the
// ground does not move under a scrolling hand. After it there is nothing left
// to reveal, which is what makes a scroll into the tail read as scrolling
// through a list rather than as a list still arriving.
//
// FOLLOWING WHAT ARRIVES AT THE VERY BOTTOM
// -----------------------------------------
// A queue parked at the end of a FULL viewport has nowhere to put what is
// appended to it: the new rows land below the fold and nothing appears to
// have happened. (A queue with room left at its foot is not that list — it
// has never been scrolled anywhere, and what arrives lands in plain sight.)
// So the view follows them down — and stops before the last row that was
// already there would leave the top, because that row is what says WHERE
// they went.
// While the view is what moves, the arriving rows hold their height and only
// slide: one clock per motion, and a content height that is still growing
// would clamp the scroll target away.
//
// "Off screen" is BOTH ends of the viewport, and getting that wrong is not a
// cosmetic matter: a row above the fold that is left standing instead of being
// retired is not in the queue any more, nothing ever removes it, and the
// arrivals shuffle it to the foot of the list where it stays for good. The
// rows under the user's eye are kept from sliding about by taking the height
// that goes out of the scroll position, which is exact and costs nothing.
//
// THE HEADER IS PINNED, AND THE FOG IS UNDER IT
// ---------------------------------------------
// The queue's header is the tab's title, its count and its Clear button, and
// all three have to be there wherever the list is scrolled to — so it does not
// scroll. The rows scroll UNDER it and out of sight; its box still meets the
// container's top corners, and the content keeps its height at its head
// (`headSlot`) so the first row starts under it rather than behind it.
//
// What says "the list continues this way" is then the header's own foot rather
// than the box's top edge, and that is where the fade has to be. It is drawn
// here (`headerFog`) because CarvedListDressing can only fade at the edges of
// the box it dresses; its own top fade ends up behind the header, where it can
// never be seen. The fog is SOLID before it fades, over exactly the ground the
// header leaves open — the sliver either side where its bottom corners curve
// away, and the band of `bottomGap` between its foot and the first slot — so
// no row is ever visible in the gap between the header and the fade.
//
// A pinned header also takes a row's height off the top of what can be SEEN,
// which is a fact the wave has to know: `_visibleTop`, not the scroll
// position, is where "on screen" starts.
//
// The list still runs to the box's other edge — the last row's slot meets the
// foot, less the air that row carries (`rowFootAir`), so a list scrolled to
// its end has nothing left to scroll into and its last song is not pressed
// against the carved edge.
//
// ONE MARK FOR THE CURRENT SONG
// -----------------------------
// The playing row is marked by its stripe and by nothing else: no second
// colour on the text, no glyph in the number slot. `playing` is carried by the
// SAME mark — the stripe rests at full accent while the music runs and drains
// to a grey with a note of accent in it when it is paused (UpdatePackageRow's
// drain, relative to the ground so it survives a dark theme). Saying "this one"
// and "it is paused" with one object is the house rule; a stripe AND a colour
// AND a glyph is the same fact three times.
//
// DRAGGING A ROW TO REORDER IT
// ----------------------------
// The finger carries a ghost of the row; the list itself opens a gap where the
// row would land. The gap is a PHANTOM row — an empty AnimatedListRow with the
// row's own height — and moving the gap is one phantom leaving (collapsing) as
// another enters (growing) on the same clock, so the sum of the two never
// changes and the rows between them glide by exactly one row height. The
// dragged row keeps its place in the model at zero height, so the phantom and
// the row it stands for always add up to one row: nothing else in the list
// moves at pickup or at landing.
//
// The DROP is RowFlight's: the ghost is handed to it as the row it flies from,
// so the clone picks up exactly where the finger let go, and the flight brings
// it into the slot with the camera-follow scroll, the motion blur and the
// scroll lock that component already owns. Its lift leg is one millisecond
// here and not the usual 160 — the row was lifted when the hand picked it up,
// and lifting it twice reads as a hiccup at the moment of release.
//
// A drop that changes nothing is not a flight: the ghost settles back into its
// own slot on the list's own easing. RowFlight would end such a flight the
// instant it started (its own model-index check, correctly), and the ghost
// would pop rather than land.
//
// The overlay the ghost and the clone are drawn in is `flightOverlay`, which
// the host points at the popup root. An item that paints outside an ancestor's
// bounds never receives input there, and a Flickable would slice the clone in
// half — both are why nothing that flies is drawn inside the list box.
// =============================================================================
Item {
    id: root

    // Device px per design px here (the nearest ScaleRoot's, else the window's): the layers below are made at the glass's resolution.
    DeviceScale {
        id: dev
    }

    // ---- Data ------------------------------------------------------------
    // [song object] in queue order — see the module's vocabulary. Only
    // id/pos/title/artist/duration/album/disc/track are read here.
    property var songs: []
    // songid of the song being played, -1 for none.
    property int currentId: -1
    property bool playing: false

    // ---- Host wiring -----------------------------------------------------
    // Where the drag ghost and the flight clone are DRAWN: the popup's root
    // item. Null draws them inside the panel, where the list box clips them —
    // useful only for a probe.
    property Item flightOverlay: null
    // The player (MpdService or its mock): a song's details read it.
    property var player: null
    // A page opened from this list in ANOTHER panel (the popup's Show album): how far the rows have zoomed towards the row it grew out of, and that row's middle in this file's frame.
    property real crossZoom: 1
    property point crossFocus: Qt.point(0, 0)

    // ---- Look ------------------------------------------------------------
    property real listScale: 1.0
    // Every corner of every box in here, the pinned header's included. That
    // header sits flush with the container's top edge, so its corner has to be
    // able to COINCIDE with the container's -- and a box whose foot is rounder
    // or flatter than its head reads as one side having a different radius.
    // One number, therefore, and it is the container's.
    property real containerRadius: 14
    property bool compact: false
    property string fontFamily: "Inter"

    // Colours. Plain properties, defaulted from Theme, so a host may override
    // any of them; never assigned from JS (that would kill the binding).
    property color listBoxColor: Theme.listBox
    property color headerBoxColor: Theme.headerBox
    property color textColor: Theme.textPrimary
    property color mutedColor: Theme.textMuted
    property color faintColor: Theme.textFaint
    property color accentColor: Theme.accent
    property color surfaceColor: Theme.surface
    property color bevelColor: Theme.bevel
    property color borderColor: Theme.border
    // The header box's own relief and the Clear button's plateau. Not in the
    // nine the contract names, but a header box and a raised button cannot be
    // drawn without them.
    property color headerBoxBevelColor: Theme.headerBoxBevel
    property color headerBoxShadowColor: Theme.headerBoxShadow
    property color buttonPlateauColor: Theme.buttonPlateau
    property color buttonPlateauHoverColor: Theme.buttonPlateauHover
    property color buttonBevelColor: Theme.buttonBevel
    property color buttonShadowColor: Theme.buttonShadow

    // ---- Layout numbers (the house's, as properties) ---------------------
    property real rowInset: 6           // rows only; the header meets the edges
    property real listFadeHeight: 34
    property real headerBoxPadding: 11
    property real headerBoxPaddingV: 8
    // The header box's own carve, tunable like every other box in the panel.
    // The COLOURS are theme tokens (headerBoxColor and friends above) and are
    // edited as theme rows.
    property real headerBevelWidth: 1
    property real headerShadowWidth: 3
    property real rowVPad: 4
    property real rowLineGap: 1
    property real rowVirtualSpacing: 6
    // The air under the LAST row's ink, on top of the half spacing its own
    // slot already carries. It is the ROW's, not the box's: a list that ends
    // on a header does not want it, and a box padded at the foot would be
    // padded at the head too, where the header's own box has to meet the
    // container's corners. 6 is the header box's bottom gap, which makes the
    // space under the last row's ink (4 + 3 + 6) equal the space over the
    // first row's (6 + 3 + 4) -- space above equals space below.
    property real rowFootAir: 6
    property real stripeWidth: 3
    property real rowSidePadding: 2
    property real rowGap: 8             // between the row's own blocks
    property int  rowAnimDuration: 240
    property int  rowStaggerMs: 55
    property real scrollSpeed: 1.0
    // The gap under the finger moves faster than a row enters a list: the
    // pointer is already somewhere else by the time a 240 ms slide lands.
    property int  gapAnimDuration: 160
    // How far past the half-way line the ghost must go before the gap leaves
    // the slot it is in, as a fraction of a row pitch. A dead band, not a
    // delay: it costs nothing in the direction of travel and it is the only
    // thing that stops a hand RESTING on a boundary flipping the gap forever.
    // Kept well under 0.5, or the gap could never reach the next slot at all.
    property real slotHysteresis: 0.15
    // Whether a gap that is MOVED collapses from where it got to rather than
    // snapping to full height first. On, always, in the shipped popup; it is a
    // property only so a probe can turn it off and watch the jitter come back.
    property bool gapResumes: true
    // Following rows that arrived below the fold at the very bottom of the
    // list. 260 ms OutCubic is the house's resize easing: the view moving to
    // meet new content is the same kind of motion as a container growing.
    property int  followScrollMs: 260
    // How close to the end still counts as "already scrolled to the end", in
    // row pitches. Half a row is short enough that a list stopped in the
    // middle never follows, and long enough that one parked a pixel or two
    // short of its end still does.
    property real followFootSlack: 0.5

    // ---- Type ------------------------------------------------------------
    property int titleSize: 13
    property int artistSize: 11
    property int headerTitleSize: 15
    property int figureSize: root.compact ? 10 : 11

    // ---- Drag and flight tuning -----------------------------------------
    // px of pointer travel before a press becomes a drag rather than a click.
    property real dragThreshold: 6
    property real flightLiftScale: 1.055
    property int  flightTravelMs: 340
    property int  flightLandMs: 160
    property real flightShortDistance: 220
    property int  flightMinTravelMs: 130
    property real flightBlurRefDistance: 700
    property real flightBlurMax: 0.55
    property int  flightSettleMs: 90
    property int  flightPreMoveDelayMs: 100
    property int  flightPreDropDelayMs: 100
    property real flightMinTravel: 4
    property real autoScrollDeadZone: 12
    property real autoScrollRamp: 140
    property real autoScrollMaxSpeed: 900

    // ---- Signals ---------------------------------------------------------
    signal playRequested(int songId)
    signal removeRequested(int songId)
    // Indices into `songs`. For a queue read whole from MPD these ARE the
    // queue positions, and `toPos` is the index the song occupies once the
    // move has been applied — which is what MPD's `move` expects.
    signal moveRequested(int fromPos, int toPos)
    signal clearRequested()
    // A right click on a row: its song id and where the click was (scene coordinates). The host opens the
    // row's menu (play next, remove, details, its album); the list moves nothing for it.
    signal menuRequested(int songId, real sceneX, real sceneY)
    // A song page's own buttons, and what it opens: the host's.
    signal songActionRequested(string action, var song)

    // ---- Derived ---------------------------------------------------------
    readonly property real _s: Math.max(0.2, root.listScale)
    readonly property int  _count: root.songs ? root.songs.length : 0
    readonly property real _vSpacing: root.rowVirtualSpacing * root._s
    // Every row is the same height, computed rather than measured: the drag's
    // gap, the flight's landing and the drop index all need a row's pitch
    // BEFORE any row exists, and a measurement fed back into what sizes the
    // rows would be a loop.
    readonly property real _rowContentH:
        root.rowVPad * 2 * root._s + fmTitle.height
        + (root.compact ? 0 : root.rowLineGap * root._s + fmArtist.height)
    readonly property real _rowPitch: root._rowContentH + root._vSpacing

    readonly property real _totalDuration: {
        let t = 0;
        const l = root.songs || [];
        for (let i = 0; i < l.length; i++) t += Number(l[i].duration) || 0;
        return t;
    }
    readonly property real _maxDuration: {
        let t = 0;
        const l = root.songs || [];
        for (let i = 0; i < l.length; i++) t = Math.max(t, Number(l[i].duration) || 0);
        return t;
    }
    // Fixed slots, sized from the longest form THIS queue can reach — not from
    // the worst case a library could hold. Measured off a template of eights
    // through FontMetrics, never by reading a Text's own width back.
    readonly property string _durTemplate:
        (Bytes.formatEta(Math.max(1, root._maxDuration)) || "0:00").replace(/[0-9]/g, "8")
    readonly property real _durSlot: fmFig.advanceWidth(root._durTemplate)
    // WHAT THE NUMBER IN FRONT OF A ROW IS
    // ------------------------------------
    // A row that belongs to an ALBUM keeps the album's own track number;
    // every other row takes its place IN THE QUEUE. The album's numbering is
    // the only one that means anything for a record played end to end, and it
    // means nothing at all for a playlist -- there the user queued a list that
    // has an order of its own, and that order is what the numbers have to say.
    //
    // "Belongs to an album" is decided from the queue itself, because the
    // queue holds both at once and nothing on a song says where it was queued
    // FROM: an album row is one in a run of CONSECUTIVE rows that share one
    // non-empty album and stand in that album's own order -- (disc, track)
    // strictly ascending, every track tagged -- and the run is at least two
    // rows long. That is exactly what queueing a record produces and what
    // queueing a list does not: a playlist that happens to be an album in
    // album order IS that album and reads right either way, a playlist that is
    // not is numbered 1..n like the list it came from, and a single loose song
    // is never a run, so it takes its queue number.
    //
    // The key is (disc, track) rather than track because disc 2's track 1 is
    // not a step backwards from disc 1's track 12: comparing tracks alone
    // would break a double album into a playlist halfway down.
    readonly property var _numbers: {
        const l = root.songs || [];
        const out = [];
        let i = 0;
        while (i < l.length) {
            const album = String(l[i].album || "");
            let j = i + 1;
            if (album.length > 0)
                while (j < l.length && String(l[j].album || "") === album) j++;
            let run = album.length > 0 && j - i >= 2;
            for (let k = i; run && k < j; k++) {
                const t = Number(l[k].track) || 0;
                if (t <= 0) { run = false; break; }
                if (k > i) {
                    const d0 = Number(l[k - 1].disc) || 0;
                    const d1 = Number(l[k].disc) || 0;
                    const t0 = Number(l[k - 1].track) || 0;
                    // A run is CONTIGUOUS, not merely ascending: take track 2
                    // out of 1-5 and 1,3,4,5 still ascends, so the record
                    // would keep its own numbering with a hole in it, which
                    // reads as a count that has not been updated. A gap in
                    // the track numbers means the record is no longer being
                    // played as itself, and the queue numbers it as a queue.
                    // A new disc starts its own count and is not a gap.
                    if (d1 < d0 || (d1 === d0 && t !== t0 + 1)) run = false;
                }
            }
            for (let k = i; k < j; k++)
                out.push(run ? (Number(l[k].track) || 0) : k + 1);
            i = j;
        }
        return out;
    }
    // The slot is sized from the numbers that are actually DRAWN, not from the
    // track tags: a queue of loose songs numbers itself 1..n, and past the
    // hundredth row that is a digit the album numbering never needed.
    readonly property int _maxNumber: {
        const n = root._numbers;
        let m = 0;
        for (let i = 0; i < n.length; i++) m = Math.max(m, n[i]);
        return m;
    }
    readonly property real _numSlot: fmFig.advanceWidth(
        "8".repeat(Math.max(2, String(Math.max(1, root._maxNumber)).length)))
    readonly property real _removeSlot: fmFig.height * 1.2

    // A song's identity for the whole file: MPD's songid where there is one,
    // and position+uri where there is not (a queue read before the ids are
    // known). Keys are strings because RowFlight's key is.
    function _keyOf(s) {
        if (!s) return "";
        const id = Number(s.id);
        return (id >= 0)
            ? "id:" + id
            : "u:" + (s.pos !== undefined ? s.pos : "?") + ":" + (s.file || "");
    }

    // =====================================================================
    //  METRICS
    // =====================================================================
    FontMetrics {
        id: fmTitle
        font.family: root.fontFamily
        font.pixelSize: root.titleSize * root._s
    }
    FontMetrics {
        id: fmArtist
        font.family: root.fontFamily
        font.pixelSize: root.artistSize * root._s
    }
    FontMetrics {
        id: fmFig
        font.family: root.fontFamily
        font.pixelSize: root.figureSize * root._s
    }
    FontMetrics {
        id: fmHead
        font.family: root.fontFamily
        font.pixelSize: root.headerTitleSize * root._s
    }

    // =====================================================================
    //  ROW MODEL
    //
    //  The panel keeps its own copy of the order so a drag can commit
    //  immediately and the flight has somewhere to land, rather than waiting
    //  for MPD to confirm through `songs`. `_sync` reconciles the two: a host
    //  that refuses the move simply moves the row back.
    // =====================================================================
    ListModel { id: rowModel }

    // `deferred`  the row holds its slot but is not drawn — the tail of an
    //             expand, waiting for the head to finish.
    // `keepHeight` the row slides in without animating its height — used when
    //             the VIEW is the thing moving, so the ground stays still.
    // Both are carried by the phantom too: a ListModel takes its roles from
    // the first object inserted, and a row shape that differs by one field is
    // a role that silently reads back undefined.
    function _entry(s, num, state, stagger, deferred, keepHeight) {
        return {
            key: root._keyOf(s),
            songId: Number(s.id) >= 0 ? Number(s.id) : -1,
            pos: Number(s.pos) >= 0 ? Number(s.pos) : 0,
            title: String(s.title || s.file || ""),
            artist: String(s.artist || ""),
            dur: Number(s.duration) || 0,
            num: Number(num) || 0,
            rowState: state,
            staggerIdx: stagger,
            deferred: !!deferred,
            keepHeight: !!keepHeight,
            isPhantom: false
        };
    }
    function _phantom(state) {
        return {
            key: "", songId: -1, pos: 0, title: "", artist: "",
            dur: 0, num: 0, rowState: state, staggerIdx: 0,
            deferred: false, keepHeight: false, isPhantom: true,
            // When this phantom was told to collapse, so the reap below can
            // wait for it to FINISH rather than cutting it off mid-way.
            leftAt: 0
        };
    }

    function _modelIndexOf(key, from) {
        for (let i = from || 0; i < rowModel.count; i++) {
            const r = rowModel.get(i);
            if (!r.isPhantom && r.key === key) return i;
        }
        return -1;
    }
    // Position among the REAL rows, which is what the host's queue positions
    // count in, and what RowFlight asks for.
    function _rowIndexOf(key) {
        let n = 0;
        for (let i = 0; i < rowModel.count; i++) {
            const r = rowModel.get(i);
            if (r.isPhantom) continue;
            if (r.key === key) return n;
            n++;
        }
        return -1;
    }

    property bool _syncQueued: false
    function _scheduleSync() {
        if (root._syncQueued) return;
        root._syncQueued = true;
        Qt.callLater(function () {
            root._syncQueued = false;
            root._sync();
        });
    }
    onSongsChanged: root._scheduleSync()
    Component.onCompleted: root._sync()

    // Whatever the host says while a wave is running is remembered and applied
    // once it has finished. Two waves crossing is exactly what the list rule
    // forbids, and the fold can only be computed off a list that is at rest.
    property bool _syncDeferred: false
    readonly property bool _waveRunning:
        leaveCleanup.running || enterDelay.running || enterSettle.running
    // True until the panel has drawn a non-empty list once: a queue that has
    // never shown anything is PLACED, because there is nothing on screen for a
    // wave to arrive into. Every later fill — including one after a Clear — is
    // an expand and flies in.
    property bool _firstFill: true

    // Where a row's slot sits in the content's own coordinates. Every row in
    // this list is one pitch, so a row's resting position is known from its
    // index before the row exists — which is what makes the fold decidable
    // without measuring a list that is still moving.
    function _slotY(rowIndex) {
        return queueHeader.height + rowIndex * root._rowPitch;
    }
    // The top of what the user can actually SEE, in content coordinates. Not
    // the scroll position: the header is pinned over the viewport, so the
    // first `queueHeader.height` of it is covered. At the top of the list
    // that band is exactly the header's own slot and this answers `cy`
    // unchanged; anywhere else it is a row's worth of list that is drawn but
    // hidden, and a wave that counts it as on screen animates a row nobody
    // sees and holds its tail back a stagger step too long for it.
    function _visibleTop(cy) {
        return cy + queueHeader.height;
    }

    // ---- What is worth DRAWING -----------------------------------------
    // `_onScreen` decides what animates; this decides what is painted at all.
    // Both are the viewport plus an overscan, and this one's is two rows so a
    // row is drawn before it can be looked at rather than in the frame it is
    // needed. The Column starts at the Flickable's own origin here (its head
    // slot is the pinned header's height, inside the content), so a row's y
    // needs no correction.
    readonly property real _cullPad: root._rowPitch * 2
    // Before the box has been laid out there is no viewport to be outside of,
    // and culling against a height of zero would hide the whole list.
    readonly property bool _culling: flick.height > 0
    readonly property real _cullTop: flick.contentY - root._cullPad
    readonly property real _cullBottom: flick.contentY + flick.height + root._cullPad

    // Is that slot worth animating? The visible viewport plus a row of
    // overscan either side, so a row one pixel past the fold does not read as
    // popped in. The scroll position is passed IN rather than read here: a
    // caller decides the whole wave against the layout as it stood when it
    // started, and the Flickable moves under it as the first rows give up
    // their height.
    function _onScreen(slotY, cy) {
        // Before the box has a height nothing can be off screen yet, so the
        // whole list is worth animating -- which is also the only answer that
        // cannot silently place a list nobody has measured.
        if (flick.height <= 0) return true;
        const over = root._rowPitch;
        return slotY + root._rowPitch > root._visibleTop(cy) - over
            && slotY < cy + flick.height + over;
    }

    // Strictly inside the viewport, no overscan. `_onScreen` deliberately
    // allows a row either side so a row a pixel past the fold does not read as
    // popped in; THIS is the other question -- can the user SEE it -- and it
    // is what decides when the viewport counts as full.
    function _inViewport(slotY, cy) {
        if (flick.height <= 0) return true;
        return slotY + root._rowPitch > root._visibleTop(cy)
            && slotY < cy + flick.height;
    }

    // THE COLLAPSE HALF.
    //
    // Rows that are gone leave, rows that only moved are moved, and the
    // arrivals are handed to `_applyArrivals` — which runs now if nothing is
    // leaving, and one stagger step after the departures have gone if
    // something is. Rebuilding the model wholesale would restart every
    // animation and throw away the scroll position on every MPD update.
    function _sync() {
        // A drag or a flight owns the order for as long as it runs; the
        // host's answer is applied when the row has landed.
        if (root._dragging || flight.active || root._waveRunning) {
            root._syncDeferred = true;
            return;
        }
        root._syncDeferred = false;

        const want = root.songs || [];
        const wanted = {};
        for (let i = 0; i < want.length; i++) wanted[root._keyOf(want[i])] = true;

        // Decided against the layout as it stands, BEFORE anything is touched:
        // "work out what is on screen first". The scroll position is read once
        // here for the same reason -- the first row to be retired moves it.
        const cy = flick.contentY;
        let departing = 0;      // the ones that actually animate out
        let retiring = 0;       // every row that is going, animated or not
        let shrankAbove = 0;    // height retired ENTIRELY above the viewport
        for (let i = 0; i < rowModel.count; i++) {
            const r = rowModel.get(i);
            if (r.isPhantom || wanted[r.key]) continue;
            retiring++;
            const y = root._slotY(i);
            if (root._onScreen(y, cy)) {
                // staggerIdx BEFORE rowState, always: writing rowState fires
                // AnimatedListRow.onRowStateChanged synchronously, and that
                // schedules the kick from whatever staggerIdx holds at the
                // time. Setting the index afterwards is one wave too late.
                rowModel.setProperty(i, "staggerIdx", departing++);
                rowModel.setProperty(i, "rowState", "leaving");
            } else {
                // Off the screen is off the screen, above the fold as much as
                // below it: gone in this same frame, so whatever follows the
                // list sits directly under the last visible row, exactly as if
                // the list had only ever held what you can see. Leaving the
                // ones above standing instead is not a gentler answer, it is a
                // wrong one -- they are not in the queue any more, and the
                // arrivals shuffle them to the list's foot, where they stay.
                rowModel.setProperty(i, "staggerIdx", 0);
                rowModel.setProperty(i, "rowState", "collapsed");
                // A slot that ends above the viewport takes its height out
                // from ABOVE the scroll position, so the rows below it all
                // move up by that much. Taking the same amount off the scroll
                // position puts them back: what the user is looking at does
                // not move. At the very END of a list the Flickable's own
                // clamp happens to do this, which is why it has to be checked
                // from the MIDDLE.
                if (y + root._rowPitch <= cy) shrankAbove += root._rowPitch;
            }
        }
        if (shrankAbove > 0) {
            kinetic.stop();
            flick.contentY = Math.max(0, cy - shrankAbove);
        }

        if (retiring > 0) {
            // The last row to leave starts `departing * staggerMs` late, so the
            // sweep has to wait for the wave it actually started -- a fixed
            // interval would clip the tail of any list longer than it assumed.
            leaveCleanup.interval = departing > 0
                ? root.rowAnimDuration + root.rowStaggerMs * departing + 60
                : 16;
            leaveCleanup.restart();
            return;             // the arrivals wait for the collapse
        }
        root._applyArrivals();
    }

    // THE EXPAND HALF.
    //
    // Arrivals go in in the host's order; the ones whose slot lands on screen
    // fly in staggered from the top. The rest — the tail, which sits below the
    // fold once the head has landed — take their SLOT in this same frame, so
    // the list is at its true height at once and the fade, the scroll range
    // and anything anchored to the foot are right from that instant. What they
    // do not take is the screen: they are held undrawn until the head has
    // finished entering (list_animation.md, section 2a), because a tail drawn
    // now would sit above the head that belongs above it and be shoved down by
    // it.
    //
    // The wave IS reassessed while it runs: a held row the user scrolls to
    // reveals itself from the delegate's `peeked`.
    function _applyArrivals() {
        const want = root.songs || [];
        const animateNew = !root._firstFill;

        // Who is here already, and where the new rows fall among them.
        // Counted before anything is inserted, because the follow below is
        // decided against the layout as it stands.
        const here = {};
        let kept = 0;
        for (let i = 0; i < rowModel.count; i++) {
            const r = rowModel.get(i);
            if (r.isPhantom || r.rowState === "leaving"
                || r.rowState === "collapsed") continue;
            here[r.key] = true;
            kept++;
        }
        let firstNew = -1;
        let fresh = 0;
        for (let k = 0; k < want.length; k++) {
            if (here[root._keyOf(want[k])]) continue;
            if (firstNew < 0) firstNew = k;
            fresh++;
        }

        // EXPANDING AT THE VERY BOTTOM. Every new row goes after every row
        // that is already there, and the list is already parked at its end, so
        // the arrivals would land below the fold with nothing to say they had
        // arrived. Follow them — but no further than the slot of the last row
        // that was already there, so it stays at the top of the viewport
        // rather than leaving it: it is this list's version of the doc's
        // header, the thing that says where the new rows went. Less the
        // pinned header, which would otherwise cover the very row the clamp
        // exists to keep on screen, and less the fog under it, because a row
        // half erased by that fade is exactly the "partially off-screen" the
        // doc stops short of.
        const appendAtFoot = animateNew && fresh > 0 && firstNew > 0
            && firstNew === kept && want.length - firstNew === fresh
            && root._atFoot();

        // Read once, for the whole wave: the first row to claim its height
        // moves the Flickable under the rows still being decided. When the
        // view is going to follow, the fold is decided where the list WILL be,
        // so the rows the follow uncovers fly in instead of being held.
        const cyNow = flick.contentY;
        const followTo = appendAtFoot
            ? Math.max(cyNow, Math.min(
                  Math.max(0, queueHeader.height + root.rowFootAir * root._s
                              + want.length * root._rowPitch - flick.height),
                  root._slotY(firstNew - 1) - queueHeader.height
                      - root.listFadeHeight))
            : cyNow;
        const following = followTo > cyNow + 0.5;
        const cy = followTo;
        root._waveCy = cy;

        let entering = 0;
        let held = 0;
        let cursor = 0;
        // The stagger index of the last entering row whose slot is inside the
        // viewport: when THAT row lands, the viewport is full. The head runs
        // one row longer than that -- `_onScreen`'s overscan row is past the
        // fold by definition -- and waiting for it would leave a stagger step
        // in which the user is looking at a full list that is still holding
        // its tail back.
        let lastVisible = -1;
        for (let k = 0; k < want.length; k++) {
            while (cursor < rowModel.count
                   && (rowModel.get(cursor).rowState === "leaving"
                       || rowModel.get(cursor).rowState === "collapsed"
                       || rowModel.get(cursor).isPhantom))
                cursor++;
            const s = want[k];
            const key = root._keyOf(s);
            const at = root._modelIndexOf(key, cursor);
            if (at < 0) {
                // k IS the row's final index, so its slot is known already.
                const slot = root._slotY(k);
                const onScreen = root._onScreen(slot, cy);
                const fly = animateNew && onScreen;
                if (animateNew && !onScreen) held++;
                // `entering` is this row's own stagger index until the insert
                // below claims it.
                if (fly && root._inViewport(slot, cy)) lastVisible = entering;
                rowModel.insert(cursor, root._entry(
                    s, root._numbers[k],
                    fly ? "entering" : "rest", fly ? entering++ : 0,
                    animateNew && !onScreen,     // held below the fold
                    fly && following));          // the view moves, not the row
            } else {
                if (at !== cursor) rowModel.move(at, cursor, 1);
                const cur = rowModel.get(cursor);
                if (cur.title !== String(s.title || s.file || ""))
                    rowModel.setProperty(cursor, "title", String(s.title || s.file || ""));
                if (cur.artist !== String(s.artist || ""))
                    rowModel.setProperty(cursor, "artist", String(s.artist || ""));
                if (cur.dur !== (Number(s.duration) || 0))
                    rowModel.setProperty(cursor, "dur", Number(s.duration) || 0);
                if (cur.num !== (Number(root._numbers[k]) || 0))
                    rowModel.setProperty(cursor, "num", Number(root._numbers[k]) || 0);
                if (cur.pos !== (Number(s.pos) >= 0 ? Number(s.pos) : 0))
                    rowModel.setProperty(cursor, "pos", Number(s.pos) >= 0 ? Number(s.pos) : 0);
            }
            cursor++;
        }
        if (rowModel.count > 0) root._firstFill = false;

        // The follow can be started only now, but its target was computed
        // before a single row went in — and it cannot be clamped away by a
        // list that is still growing, because every row that arrives under it
        // holds its height.
        if (following) {
            bottomFollow.stop();
            kinetic.stop();
            bottomFollow.to = followTo;
            bottomFollow.start();
        }

        tailReveal.stop();
        if (entering > 0) {
            // THE TAIL'S TURN IS THE VIEWPORT FILLING, AND NOTHING MAY
            // MOVE IT. That is the LAST VISIBLE row's stagger step plus one
            // slide -- not the head's own last row, which is the overscan row
            // below the fold: the 55 ms between the two is a window in which
            // the user is already scrolling a viewport that looks finished.
            // Nothing entering
            // below the fold is on screen, so placing the tail while that one
            // is still in the air is invisible. Fixed here, where the wave is
            // decided, and never extended afterwards.
            if (held > 0) {
                tailReveal.interval = lastVisible < 0 ? 16
                    : root.rowAnimDuration + root.rowStaggerMs * lastVisible;
                tailReveal.restart();
            }
            root._startSettle(root.rowAnimDuration
                              + root.rowStaggerMs * entering + 60);
        } else {
            // No staggered head to wait for, so "when the head has finished"
            // is now: the tail is simply placed, in this same frame.
            if (held > 0) root._revealTail();
            if (root._syncDeferred) root._scheduleSync();
        }
    }

    // Is the list parked at its end, with nothing but the end below it?
    //
    // Two facts, and the second is the one a scroll position alone cannot
    // tell: a list with ROOM LEFT at the foot of its viewport has not been
    // scrolled anywhere, and what is appended to it lands in that room, in
    // plain sight. Following there would scroll the queue's own header and
    // the playing row off the top to show rows that were arriving on screen
    // anyway. So the viewport has to be full first; only then does half a
    // row of slack on the scroll position decide whether it is parked at the
    // end of it.
    function _atFoot() {
        if (flick.contentHeight < flick.height) return false;
        const max = Math.max(0, flick.contentHeight - flick.height);
        return flick.contentY >= max - root.followFootSlack * root._rowPitch;
    }

    // The tail's turn: the head has landed (or there never was one), so the
    // rows that were holding their slots undrawn are placed. They are below
    // the fold by construction, which is why this is one frame with nothing
    // to animate — placing them IS the doc's "they appear instantly".
    function _revealTail() {
        for (let i = 0; i < rowModel.count; i++)
            if (rowModel.get(i).deferred)
                rowModel.setProperty(i, "deferred", false);
    }

    // One row of the tail, reached by the user scrolling to it before its
    // turn. It has come into view, so it animates rather than pops — but with
    // its height held, because the ground under a scrolling hand must not
    // move. staggerIdx 0: the scroll is the stagger.
    function _revealRow(key) {
        const i = root._modelIndexOf(key, 0);
        if (i < 0 || !rowModel.get(i).deferred) return;
        // staggerIdx and the two flags BEFORE rowState, always: writing
        // rowState fires AnimatedListRow.onRowStateChanged synchronously.
        rowModel.setProperty(i, "staggerIdx", 0);
        rowModel.setProperty(i, "keepHeight", true);
        rowModel.setProperty(i, "deferred", false);
        rowModel.setProperty(i, "rowState", "entering");
        // The wave may not end before this row has finished sliding, or the
        // settle snaps it home mid-slide.
        root._startSettle(Math.max(root._waveEndsAt - Date.now(),
                                   root.rowAnimDuration + 60));
    }

    // The wave's clock, kept as an absolute end: a Timer cannot be asked how
    // much of itself is left, and a reveal must be able to extend the wave
    // without shortening what is already running.
    property real _waveEndsAt: 0
    // True while a head is still entering. Written, never bound to
    // `enterSettle.running`: a reveal RESTARTS that timer, so a binding would
    // flicker false/true inside the very notification that caused it and Qt
    // would call the whole chain a loop (36 times a run).
    property bool _enterWave: false
    // Where the fold was decided. A held row is bunched under a head that has
    // not claimed its height yet, so its position alone cannot say whether
    // the user can legitimately see it; what says so is the scroll having
    // MOVED from here. Half a row of slack, so the follow's own easing (which
    // ends exactly at `_waveCy`) never counts as the user scrolling.
    property real _waveCy: 0
    readonly property bool _peekOpen: root._enterWave
        && Math.abs(flick.contentY - root._waveCy) > root._rowPitch * 0.5
    function _startSettle(ms) {
        enterSettle.interval = Math.max(16, Math.round(ms));
        root._waveEndsAt = Date.now() + enterSettle.interval;
        root._enterWave = true;
        enterSettle.restart();
    }

    // Reveals asked for by the delegates, applied on the next turn of the
    // event loop rather than inside the binding notification that asked: the
    // reveal writes the very model field the notification is reading, which
    // is a binding loop however true it is. Qt.callLater cannot do this —
    // repeated calls with one function reference collapse to the LAST
    // arguments, and a flick reveals a dozen rows in one frame.
    property var _peekQueue: []
    function _peek(key) {
        if (root._peekQueue.indexOf(key) >= 0) return;
        const l = root._peekQueue.slice();
        l.push(key);
        root._peekQueue = l;
        peekFlush.restart();
    }
    Timer {
        id: peekFlush
        interval: 0
        repeat: false
        onTriggered: {
            const l = root._peekQueue;
            root._peekQueue = [];
            for (let i = 0; i < l.length; i++) root._revealRow(l[i]);
        }
    }

    Timer {
        id: leaveCleanup
        // Written by _sync from the size of the wave it just started.
        interval: root.rowAnimDuration + root.rowStaggerMs + 60
        repeat: false
        onTriggered: {
            for (let i = rowModel.count - 1; i >= 0; i--) {
                const r = rowModel.get(i);
                if (r.isPhantom) continue;
                if (r.rowState === "leaving" || r.rowState === "collapsed")
                    rowModel.remove(i);
            }
            // One stagger step of daylight between the collapse and the expand:
            // long enough to read as "and then", short enough not to read as a
            // pause. The arrivals are re-read from `songs` here, so a queue
            // that changed again mid-collapse lands on its latest answer.
            enterDelay.interval = Math.max(1, root.rowStaggerMs);
            enterDelay.restart();
        }
    }
    Timer {
        id: enterDelay
        repeat: false
        onTriggered: root._applyArrivals()
    }
    // THE TAIL'S OWN CLOCK.
    //
    // When the viewport is fully populated, every remaining entering item
    // appears instantly in the list, albeit off-screen.
    //
    // It cannot be the settle's: a settle is EXTENDED by every held row a
    // scrolling hand reveals, so the tail's turn would run away from the very
    // hand scrolling towards it. Scroll the instant the viewport looks full
    // and each row reached would reveal itself, slide in on its own, and buy
    // the rest another slide's worth of delay -- rows arriving one at a time,
    // out of order, for as long as the list has rows left, longer the longer
    // the list is. This timer is set once, when the wave is decided, and
    // never restarted by a reveal: the head lands, the tail is placed, and
    // from that instant there is nothing left for a scroll to find.
    Timer {
        id: tailReveal
        repeat: false
        onTriggered: {
            // The peek window closes with it -- with nothing deferred there
            // is nothing to peek at, and saying so here keeps the delegates'
            // gate from holding a dependency on the scroll position for the
            // rest of the wave.
            root._enterWave = false;
            root._revealTail();
        }
    }
    Timer {
        id: enterSettle
        repeat: false
        onTriggered: {
            root._enterWave = false;
            // The model tells the truth again. A row left flagged "entering"
            // flies a second time the moment its delegate is rebuilt, a row
            // left deferred would never be drawn at all, and a row left with
            // its height held would not animate the next time it moves.
            for (let i = 0; i < rowModel.count; i++) {
                const r = rowModel.get(i);
                if (r.rowState === "entering")
                    rowModel.setProperty(i, "rowState", "rest");
                if (r.deferred) rowModel.setProperty(i, "deferred", false);
                if (r.keepHeight) rowModel.setProperty(i, "keepHeight", false);
            }
            if (root._syncDeferred) root._scheduleSync();
        }
    }

    // The view following rows that arrived below the fold at the foot of the
    // list. Written straight onto the Flickable rather than through a
    // Behavior: it is a motion the list makes, not a value that happens to
    // change, and it has to be stoppable the instant the user takes over.
    NumberAnimation {
        id: bottomFollow
        target: flick
        property: "contentY"
        duration: root.followScrollMs
        easing.type: Easing.OutCubic
    }

    // =====================================================================
    //  THE BOX
    // =====================================================================
    implicitHeight: content.implicitHeight

    // What this panel paints outside its own rect, in whole pixels (its carved box's bevel): a clip
    // standing on its edge must stand at least this far out (AudioPlayerPopup's `panelHost._slack`).
    readonly property real bleed: Math.ceil(box._margin)

    ShadowBox {
        id: box
        anchors.fill: parent
        baseRadius: root.containerRadius
        surfaceColor: root.surfaceColor
        bevelColor: root.bevelColor
        shadowColor: root.borderColor
        backgroundColor: root.listBoxColor
        bevelWidth: 1
        shadowWidth: 3

        Flickable {
            id: flick
            objectName: "playerQueueFlick"
            anchors.fill: parent
            contentWidth: content.width
            contentHeight: content.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            // Dragged by the user: the follow is theirs to interrupt. Only
            // dragStarted, never movementStarted -- the follow moves the
            // content itself, and would stop itself on the first frame.
            onDragStarted: { bottomFollow.stop(); kinetic.stop(); }
            // Held still while a row is airborne or under the finger: the
            // landing slot must not scroll away mid-flight, and a drag that
            // also flicked the list would fight the auto-scroll.
            interactive: !flight.scrollLocked && !root._dragging && !root.pageOpen
            // The page left behind: gone (and deaf) for as long as a page lies on the box. Opacity, not visible: a hidden Column does not hear its rows.
            opacity: pageStack.listF
            enabled: !root.pageOpen

            Column {
                id: content
                objectName: "playerQueueContent"
                width: flick.width
                spacing: 0      // AnimatedListRow reserves its own spacing
                // Towards the row a page grows out of, whichever panel the page is in. On the Column, so the Flickable's own clip stands where it stands.
                transform: Scale {
                    origin.x: pageStack.listInMorph ? pageStack.focusPoint.x : root.crossFocus.x
                    origin.y: (pageStack.listInMorph ? pageStack.focusPoint.y : root.crossFocus.y) + flick.contentY
                    xScale: pageStack.listInMorph ? pageStack.listZoom : root.crossZoom
                    yScale: pageStack.listInMorph ? pageStack.listZoom : root.crossZoom
                }

                // The header's own slot. It is PINNED over the viewport
                // (below, outside the Flickable), and this is the height it
                // keeps at the head of the content so the first row starts
                // under it rather than behind it -- and so every slot in the
                // list is still one pitch below the one above it, which is
                // what `_slotY` counts.
                Item {
                    id: headSlot
                    width: content.width
                    height: queueHeader.height
                }

                Repeater {
                    id: rowRepeater
                    model: rowModel

                    delegate: AnimatedListRow {
                        id: wrap
                        required property var model

                        rowState: wrap.model.rowState
                        staggerIdx: wrap.model.staggerIdx
                        animDuration: wrap.model.isPhantom ? root.gapAnimDuration
                                                           : root.rowAnimDuration
                        // Only the GAP resumes mid-flight. A gap that is moved
                        // every few frames must collapse from where it got to,
                        // not from full height -- see `_reslot`, and
                        // AnimatedListRow's `resumeOnStateChange`.
                        resumeOnStateChange: wrap.model.isPhantom && root.gapResumes
                        staggerMs: root.rowStaggerMs
                        // A row that arrives while the VIEW is what moves
                        // holds its height and only slides: the follow is the
                        // motion, and a second clock under it would move the
                        // ground the scroll is aiming at.
                        animateHeight: !wrap.model.keepHeight

                        // A held row the user scrolled to before its turn:
                        // the scroll has left where the fold was decided
                        // (`_peekOpen`) and the row's own slot is now under
                        // the viewport. Its LIVE position, not its final one:
                        // what the user can see is what is drawn, and the two
                        // differ by however much height the head has still to
                        // claim. The gate is what keeps that difference from
                        // revealing the whole tail at the top of the list in
                        // the wave's first frame, where every held row is
                        // bunched under a head of no height at all.
                        //
                        // The cheap terms are first on purpose: a row that is
                        // not held never registers a dependency on the scroll
                        // position or on its own y, so this costs nothing at
                        // every other moment.
                        readonly property bool peeked:
                            wrap.model.deferred && root._peekOpen
                            && wrap.y + wrap.height > flick.contentY
                            && wrap.y < flick.contentY + flick.height
                        onPeekedChanged: if (wrap.peeked) root._peek(wrap.model.key)
                        // Every height in this list is known, so nothing is
                        // measured: the row that is in the air gives up all
                        // of its space and the phantom holding its place
                        // takes exactly that much, which is what keeps the
                        // list still at pickup and at landing.
                        contentHeight: root._suppressedKey.length > 0
                                       && !wrap.model.isPhantom
                                       && wrap.model.key === root._suppressedKey
                            ? 0 : root._rowContentH
                        virtualSpacing: root._suppressedKey.length > 0
                                        && !wrap.model.isPhantom
                                        && wrap.model.key === root._suppressedKey
                            ? 0 : root._vSpacing

                        readonly property alias queueItem: queueRow
                        QueueRow {
                            id: queueRow
                            // Not drawn while it is held: `visible`, not an
                            // opacity of 0, because an item at zero opacity
                            // still takes the pointer -- and a held row sits
                            // under the entering head, where the user's click
                            // would land on a song they cannot see.
                            //
                            // AND NOT DRAWN PAST THE VIEWPORT. Qt Quick
                            // renders every node the scene holds -- a clip
                            // cuts the pixels, it does not skip the work --
                            // so a queue of 500 songs would be drawn 500 rows
                            // deep on every frame the popup paints, with a
                            // dozen of them on screen. Measured on the
                            // library's rows, which are the same shape: 0.2
                            // points of a CPU thread per row, per frame, flat
                            // in the row count and paid whenever anything
                            // else on the popup moves.
                            //
                            // The row that is IN THE HAND is exempt, for the
                            // same reason it is made transparent rather than
                            // hidden: hiding it takes the grab away from the
                            // MouseArea running the drag and the release
                            // never arrives. Its wrapper is zero-height and
                            // it follows the finger, so it is off screen by
                            // this test the moment the drag leaves the
                            // viewport -- which is exactly when the release
                            // matters most.
                            held: wrap.model.isPhantom || wrap.model.deferred
                            visible: !queueRow.held
                                     && (wrap.model.key === root._suppressedKey
                                         || !root._culling
                                         || (wrap.y + wrap.height > root._cullTop
                                             && wrap.y < root._cullBottom))
                            // The row in the air is made TRANSPARENT, never
                            // hidden. Hiding it takes the mouse grab away from
                            // the very MouseArea that is running the drag, and
                            // the release then never arrives: the gap follows
                            // the finger (the moves land on whatever row is
                            // under it, which still forwards them) and the drop
                            // is simply never seen. Its wrapper is zero-height
                            // while it is up, so Qt prunes pointer delivery to
                            // it and nothing but the grab can reach it anyway.
                            opacity: root._suppressedKey.length > 0
                                     && wrap.model.key === root._suppressedKey ? 0 : 1
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: root.rowInset * root._s
                            anchors.rightMargin: root.rowInset * root._s
                            rowKey: wrap.model.key
                            songId: wrap.model.songId
                            title: wrap.model.title
                            artist: wrap.model.artist
                            dur: wrap.model.dur
                            num: wrap.model.num
                            current: wrap.model.songId >= 0
                                     && wrap.model.songId === root.currentId
                        }
                    }
                }

                // THE LAST ROW'S AIR. The row's own vertical padding plus
                // half its virtual spacing alone would stand between the last
                // song's ink and the box's inner edge, and scrolled fully down
                // that reads as tight — the ink is nearly against the carved
                // foot. The air is the row's, so it is drawn here
                // rather than as padding on the box: this list's last item is
                // always a song (its one header is pinned at the head), which
                // is what makes an unconditional spacer the right shape of it.
                // A list that can END on a header would have to ask.
                Item {
                    id: footAir
                    width: content.width
                    height: root.rowFootAir * root._s
                }
            }

            // Smears the list vertically while it scrolls under a flying row.
            // Idle at every other moment — MotionBlur bypasses its own capture
            // below `threshold`, so there is no standing cost.
            MotionBlur {
                source: content
                amount: flight.blur
                threshold: 0.02
                direction: Qt.vector2d(0, 1)
            }
        }

        // THE WHEEL, through the shell's one scroll engine (modules/common/scroll): a
        // notch glides, fingers follow and a lift coasts. A MouseArea over the list,
        // not a WheelHandler: a handler never hears the zero-delta event that is the
        // fingers lifting (it starts the coast) nor a purely sideways one. It takes no
        // button and no hover, so a click and a row's hover pass through it.
        KineticScroll {
            id: kinetic
            flick: flick
            speed: root.scrollSpeed * ScrollFeel.speed
        }
        WheelArea {
            anchors.fill: flick
            enabled: !flight.scrollLocked && !root._dragging && !root.pageOpen
            turned: wheel => {
                const py = wheel.pixelDelta.y, ay = wheel.angleDelta.y;
                if (py === 0 && ay === 0 && (wheel.pixelDelta.x !== 0 || wheel.angleDelta.x !== 0)) {
                    wheel.accepted = false;    // purely sideways: not this list's
                    return;
                }
                // The hand wins over the follow, always.
                bottomFollow.stop();
                kinetic.feed(py, ay, wheel.phase);
                wheel.accepted = true;
            }
        }

        CarvedListDressing {
            id: dress
            flick: flick
            boxColor: root.listBoxColor
            surfaceColor: root.surfaceColor
            bevelColor: root.bevelColor
            radius: root.containerRadius
            // A page lies on the box itself: no fade may lie over its carve.
            fadeHeight: pageStack.listF > 0 ? root.listFadeHeight : 0
        }

        // THE FOG UNDER THE PINNED HEADER.
        //
        // The rows go under the header, so the thing that says "the list
        // continues this way" is the header's own foot, not the box's top
        // edge — and the dressing's top fade, which is drawn at that edge,
        // is behind the header where it can never be seen. That fade is
        // where this belongs; CarvedListDressing cannot be told to start it
        // lower, and if it could, this item would go and the queue would
        // hand it `queueHeader.height` instead.
        //
        // It is SOLID before it fades, and that solid part is the whole
        // point: the header box's bottom corners curve away from
        // the box's edges, and its foot stands `bottomGap` clear of the
        // first row's slot, so there is a sliver of open ground above the
        // fade's top edge on both sides and a band of it across the whole
        // width. Rows must not be visible in either. The solid runs from
        // where the corner arcs begin down to where the rows begin, which
        // covers both, and is invisible when nothing is under it because it
        // is painted in the ground's own colour.
        Rectangle {
            id: headerFog
            objectName: "playerQueueHeaderFog"
            // The corners leave a sliver of the box's ground above the
            // header's bottom edge, and a row must not be visible in it, so
            // the solid part reaches up by the header's own corner radius --
            // the container's, unscaled, exactly as the box is given it.
            readonly property real solid: queueHeader.bottomGap
                                        + root.containerRadius
            anchors.left: parent.left
            anchors.right: parent.right
            y: queueHeader.height - headerFog.solid
            height: headerFog.solid + root.listFadeHeight
            // The same fact as the dressing's own top fade, read off the
            // dressing so there is one answer to "is there more above".
            opacity: dress.moreAbove ? 1 : 0
            visible: opacity > 0 && pageStack.listF > 0
            Behavior on opacity { NumberAnimation { duration: dress.fadeMs } }
            gradient: Gradient {
                GradientStop { position: 0.0; color: root.listBoxColor }
                // A Gradient IGNORES a stop list whose positions do not
                // increase, so the hard stop is clamped off both ends rather
                // than allowed to meet its neighbour.
                GradientStop {
                    position: Math.max(0.001, Math.min(0.999,
                        headerFog.solid / Math.max(1, headerFog.height)))
                    color: root.listBoxColor
                }
                GradientStop { position: 1.0; color: "transparent" }
            }
        }

        // PINNED, and above the dressing: the fade at the box's top edge
        // would otherwise wash the header it is drawn over. Clipped, because
        // the header box's bevel is drawn OUTSIDE its own rect and would land
        // on the container's own rim.
        QueueHeader {
            id: queueHeader
            objectName: "playerQueueHeader"
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            clip: true
            opacity: pageStack.listF
            enabled: !root.pageOpen
        }

        // Empty is a sentence, not a silhouette: there is nothing loading and
        // nothing to resolve into.
        Text {
            anchors.centerIn: parent
            text: "Nothing queued"
            color: root.faintColor
            font.family: root.fontFamily
            font.pixelSize: root.artistSize * root._s
            opacity: root._count === 0 && !root.pageOpen ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 160 } }
        }
    }

    // ---- a song's details: a page over the list, the library's kind (PlayerPageStack), with a way back of its own ----------
    readonly property bool pageOpen: pageStack.pageOpen
    readonly property alias pages: pageStack
    function closePage(all) {
        pageStack.closePage(all);
    }
    // Escape: what is on top goes first.
    function handleEscape() {
        if (!root.pageOpen)
            return false;
        root.closePage();
        return true;
    }
    function openSongPage(uri, songId, first) {
        pageStack.openPage("song", uri, "", { where: "list", id: songId }, null, first);
    }
    // A row of the list, if it is on screen: what a page grows out of and lands back on. Its face is taken as it stands.
    function tileOfSong(songId) {
        for (let i = 0; i < rowRepeater.count; i++) {
            const w = rowRepeater.itemAt(i);
            const it = w ? w.queueItem : null;
            if (!it || it.songId !== songId)
                continue;
            const top = w.y - flick.contentY;
            if (top + w.height <= 0 || top >= flick.height)
                return null;
            return { item: it, w: it.width, h: it.height, color: root.listBoxColor, radius: 6, facts: null };
        }
        return null;
    }
    PlayerPageStack {
        id: pageStack
        anchors.fill: box
        player: root.player
        listTile: t => root.tileOfSong(t.id)
        listLabel: "Queue"
        fontFamily: root.fontFamily
        containerRadius: root.containerRadius
        inset: box.shadowWidth
        scrollSpeed: root.scrollSpeed
        listBoxColor: root.listBoxColor
        headerBoxColor: root.headerBoxColor
        surfaceColor: root.surfaceColor
        bevelColor: root.bevelColor
        borderColor: root.borderColor
        textColor: root.textColor
        mutedColor: root.mutedColor
        faintColor: root.faintColor
        accentColor: root.accentColor
        buttonPlateauColor: root.buttonPlateauColor
        buttonPlateauHoverColor: root.buttonPlateauHoverColor
        buttonBevelColor: root.buttonBevelColor
        buttonShadowColor: root.buttonShadowColor
        onSongAction: (action, song) => root.songActionRequested(action, song)
    }

    // =====================================================================
    //  DRAG TO REORDER
    // =====================================================================
    // The row under the finger. Empty when nothing is being dragged AND
    // nothing is in flight — one name for "this row is in the air", so the
    // height rules above do not have to know which of the two it is.
    readonly property string _suppressedKey:
        root._dragKey.length > 0 ? root._dragKey : flight.key
    property string _dragKey: ""
    property bool _dragging: false
    // Where the gap is, counted in rows of the list WITHOUT the dragged row —
    // which is exactly the index the row will occupy when it lands.
    property int _gapSlot: -1
    // The pointer's scene Y, the row's own scene X (a drag reorders, it never
    // moves the row sideways, so the ghost keeps the column it was picked up
    // in) and the grab's offset inside the row.
    property real _ptrSceneY: 0
    property real _grabSceneX: 0
    property real _grabOffsetY: 0

    function _beginDrag(rowItem, sceneX, sceneY) {
        if (root._dragging || flight.active) return;
        const key = rowItem.rowKey;
        const mi = root._modelIndexOf(key, 0);
        if (mi < 0) return;
        const top = rowItem.mapToItem(null, 0, 0);
        root._dragKey = key;
        root._dragging = true;
        root._grabSceneX = top.x;
        root._grabOffsetY = sceneY - top.y;
        root._ptrSceneY = sceneY;
        root._gapSlot = root._rowIndexOf(key);
        bottomFollow.stop();
        kinetic.stop();
        // The gap opens at rest, exactly where the row was, in the same turn
        // the row gives up its height: nothing in the list moves at pickup.
        rowModel.insert(mi, root._phantom("rest"));
        autoScroll.begin(root);
        root._placeGhost();
    }

    function _dragTo(sceneY) {
        if (!root._dragging) return;
        root._ptrSceneY = sceneY;
        root._placeGhost();
        autoScroll.at(root._autoScrollY(sceneY));
        root._reslot();
    }

    // WHERE THE GROUND STARTS MOVING, and it is not the container's top edge.
    //
    // SelectionAutoScroll measures its overshoot against the FLICKABLE's own
    // rect, and this list's Flickable fills the whole box: the rows scroll
    // UNDER the pinned header, so the top of that rect is behind the header
    // and a drag has to leave the container altogether before the list starts
    // coming up. What the reader sees as the top of the list is the header's
    // FOOT -- that is where the first row appears from -- so that is where the
    // scroll has to begin.
    //
    // The two rects differ at the TOP only, so only the top half is corrected:
    // the pointer is handed over a header's height further up, which puts the
    // header's foot exactly on the Flickable's top edge and leaves the dead
    // zone and the ramp measured from there. The bottom half is handed over
    // untouched, because the foot of the viewport IS the foot of the box.
    function _autoScrollY(sceneY) {
        // ONE ROW LOWER THAN THE HEADER'S FOOT. At the pinned header's foot
        // the trigger is too high, so the pointer is handed over a header AND
        // a row pitch. The cost is deliberate and worth saying: the band
        // covers the first fully visible row, so dragging INTO that slot
        // scrolls the list under the finger.
        const dh = queueHeader.height + root._rowPitch;
        if (dh <= 0) return sceneY;
        const top = flick.mapToItem(null, 0, 0).y;
        return sceneY < top + flick.height / 2 ? sceneY - dh : sceneY;
    }

    // The auto-scroll moved the ground under a still pointer: the slot under
    // it is a different one now. Duck-typed contract with SelectionAutoScroll.
    function autoScrollReapply() {
        root._placeGhost();
        root._reslot();
    }

    function _placeGhost() {
        const layer = root.flightOverlay ? root.flightOverlay : root;
        const p = layer.mapFromItem(null, root._grabSceneX,
                                    root._ptrSceneY - root._grabOffsetY);
        dragGhost.x = p.x;
        dragGhost.y = p.y;
    }

    // Which slot the ghost is over, from the RESTING layout: every real row is
    // one pitch, the dragged row is nothing and the gap is one pitch. Reading
    // it off the live items would read a list that is still animating.
    function _slotUnderGhost() {
        const top = content.mapFromItem(null, root._grabSceneX,
                                        root._ptrSceneY - root._grabOffsetY);
        const rel = top.y - queueHeader.height;
        const n = Math.max(0, root._realCount() - 1);
        const exact = rel / Math.max(1, root._rowPitch);
        // A DEAD BAND AROUND THE BOUNDARY. `Math.round` alone is a knife edge
        // at every half pitch, and this is re-read on every mouse move (a
        // 1000 Hz mouse fires several per frame) and on every frame of an edge
        // scroll -- so a hand resting on a boundary flipped the gap back and
        // forth indefinitely. The slot only LEAVES the one it is in once the
        // ghost is `slotHysteresis` past the half-way line; in the direction of
        // travel that costs nothing, because the band is crossed at the same
        // moment either way.
        if (root._gapSlot >= 0 && root._gapSlot <= n
            && Math.abs(exact - root._gapSlot) <= 0.5 + root.slotHysteresis)
            return root._gapSlot;
        return Math.max(0, Math.min(n, Math.round(exact)));
    }

    function _realCount() {
        let n = 0;
        for (let i = 0; i < rowModel.count; i++)
            if (!rowModel.get(i).isPhantom) n++;
        return n;
    }

    // Move the gap: the one that is there collapses while the new one grows,
    // on the same clock, so their sum never changes and the rows between them
    // travel exactly one row height.
    function _reslot() {
        const slot = root._slotUnderGhost();
        if (slot === root._gapSlot) return;
        root._gapSlot = slot;

        for (let i = rowModel.count - 1; i >= 0; i--) {
            const r = rowModel.get(i);
            if (r.isPhantom && r.rowState !== "leaving") {
                rowModel.setProperty(i, "rowState", "leaving");
                rowModel.setProperty(i, "staggerIdx", 0);
                rowModel.setProperty(i, "leftAt", Date.now());
            }
        }
        rowModel.insert(root._modelIndexForSlot(slot), root._phantom("entering"));
        // STARTED, not restarted. Restarting pushes the reap out to 220 ms
        // after the LAST slot change, so a continuous drag would never reap at
        // all and every collapsed phantom would stay in the model -- each one
        // making every row below it re-evaluate its cull binding. On its own
        // clock it sweeps them up as it goes.
        if (!gapCleanup.running) gapCleanup.start();
    }

    // The model index at which a phantom lands so that the dragged row would
    // come to rest at `slot` — counting real rows and ignoring the dragged one
    // (it has no height) and any phantom that is collapsing.
    function _modelIndexForSlot(slot) {
        let n = 0;
        for (let i = 0; i < rowModel.count; i++) {
            const r = rowModel.get(i);
            if (r.isPhantom) continue;
            if (r.key === root._dragKey) continue;
            if (n === slot) return i;
            n++;
        }
        return rowModel.count;
    }

    // REAPS ONLY WHAT HAS FINISHED COLLAPSING.
    //
    // A phantom still easing to zero that is DELETED has its remaining height
    // vanish in one frame. Under the drag's own auto-scroll -- where the slot
    // legitimately changes every frame and there is always a phantom in flight
    // -- that would land on the sweep's interval as a stutter or snap at a
    // constant interval. And a sweep restarted on every slot change is pushed
    // past the end of the gesture during a continuous drag, so it never runs
    // mid-drag and the dead phantoms pile up.
    //
    // So the sweep is periodic AND patient: a phantom is only removed once its
    // own collapse has had `gapAnimDuration` to run, and the timer keeps
    // sweeping while any are still in flight.
    Timer {
        id: gapCleanup
        interval: Math.max(32, Math.round(root.gapAnimDuration / 2))
        repeat: true
        running: false
        onTriggered: {
            const now = Date.now();
            const ripe = root.gapAnimDuration + 40;
            let alive = 0;
            for (let i = rowModel.count - 1; i >= 0; i--) {
                const r = rowModel.get(i);
                if (!r.isPhantom || r.rowState !== "leaving") continue;
                if (now - r.leftAt >= ripe) rowModel.remove(i);
                else alive++;
            }
            if (alive === 0) gapCleanup.stop();
        }
    }

    function _endDrag(cancelled) {
        if (!root._dragging) return;
        autoScroll.end();
        root._dragging = false;

        const key = root._dragKey;
        const from = root._rowIndexOf(key);
        const to = cancelled ? from : root._gapSlot;
        root._gapSlot = -1;

        if (from < 0 || to < 0 || to === from) {
            // Nothing changed places. There is no flight to make: the ghost
            // settles back into its own slot and the gap closes under it.
            ghostReturn.stop();
            const p = root._restTopIn(root.flightOverlay ? root.flightOverlay : root, key);
            ghostReturn.to = isNaN(p) ? dragGhost.y : p;
            ghostReturn.start();
            return;
        }
        root._flyTo(key, from, to);
    }

    NumberAnimation {
        id: ghostReturn
        target: dragGhost
        property: "y"
        duration: root.rowAnimDuration
        easing.type: Easing.OutCubic
        onFinished: root._clearDrag()
    }

    function _clearDrag() {
        root._dragKey = "";
        for (let i = rowModel.count - 1; i >= 0; i--)
            if (rowModel.get(i).isPhantom) rowModel.remove(i);
        if (root._syncDeferred) root._scheduleSync();
    }

    // =====================================================================
    //  THE LANDING
    // =====================================================================
    function _flyTo(key, from, to) {
        const mi = root._modelIndexOf(key, 0);
        if (mi < 0) { root._clearDrag(); return; }
        const r = rowModel.get(mi);
        root._pendingFrom = from;
        root._pendingTo = to;
        // The ghost IS the row the flight lifts from, so the clone appears
        // exactly where the finger let go. RowFlight walks up from that item
        // to find the Flickable, and the ghost lives in the overlay — hence
        // `flick` is handed over explicitly.
        if (!flight.begin(key, dragGhost, {
                title: r.title, artist: r.artist, dur: r.dur, num: r.num,
                songId: r.songId, current: r.songId === root.currentId
            })) {
            root._clearDrag();
            return;
        }
        root._dragKey = "";     // the flight's own key suppresses the row now
        Qt.callLater(function () { flight.reconciled(); });
    }
    property int _pendingFrom: -1
    property int _pendingTo: -1

    // Where a row comes to rest, computed from the model and never measured:
    // the destination is either a phantom that is still growing or a row that
    // is still moving, and a sample of either is a moving target.
    function _restTopIn(item, key) {
        let idx = -1;
        for (let i = 0; i < rowModel.count; i++) {
            const r = rowModel.get(i);
            if (r.isPhantom && r.rowState !== "leaving") { idx = i; break; }
        }
        if (idx < 0) idx = root._modelIndexOf(key, 0);
        if (idx < 0) return NaN;
        let y = 0;
        for (let i = 0; i < idx; i++) {
            const r = rowModel.get(i);
            if (r.isPhantom && r.rowState === "leaving") continue;   // giving it up
            if (r.rowState === "collapsed") continue;                // retired, zero high
            if (!r.isPhantom && r.key === root._suppressedKey) continue;   // in the air
            y += root._rowPitch;
        }
        // The wrapper offsets its content by half the virtual spacing, and the
        // clone is aligned to the CONTENT.
        return content.mapToItem(item, 0, 0).y + queueHeader.height
             + y + root._vSpacing / 2;
    }

    function _findRow(key) {
        const found = root._walk(content, function (i) {
            return i.rowKey !== undefined && i.rowKey === key
                && i.objectName === "playerQueueRow";
        });
        return found;
    }
    function _walk(item, pred) {
        if (!item) return null;
        if (pred(item)) return item;
        for (let i = 0; i < item.children.length; i++) {
            const r = root._walk(item.children[i], pred);
            if (r) return r;
        }
        return null;
    }

    RowFlight {
        id: flight
        anchors.fill: parent
        overlayItem: root.flightOverlay
        flick: flick

        // The row was lifted when the hand picked it up. Lifting it a second
        // time at the moment of release reads as a hiccup, so the lift leg is
        // as short as an animation can be and the clone simply starts in the
        // air, where the ghost already was.
        liftMs: 1
        liftScale: root.flightLiftScale
        travelMs: root.flightTravelMs
        landMs: root.flightLandMs
        exitMs: root.rowAnimDuration
        shortDistance: root.flightShortDistance
        minTravelMs: root.flightMinTravelMs
        blurRefDistance: root.flightBlurRefDistance
        blurMax: root.flightBlurMax
        settleMs: root.flightSettleMs
        preMoveDelayMs: root.flightPreMoveDelayMs
        preDropDelayMs: root.flightPreDropDelayMs
        minTravel: root.flightMinTravel
        backingColor: root.listBoxColor

        findDest: key => root._findRow(key)
        destTopIn: (item, key) => root._restTopIn(item, key)
        // No gap is opened at the drop: the finger already opened one, it is
        // already exactly one row wide, and opening a second would make the
        // list bounce open by two rows and shut again.
        beginGap: null
        endGap: () => root._clearDrag()
        indexOf: key => root._rowIndexOf(key)
        commit: key => {
            const mi = root._modelIndexOf(key, 0);
            let phantom = -1;
            for (let i = 0; i < rowModel.count; i++)
                if (rowModel.get(i).isPhantom && rowModel.get(i).rowState !== "leaving") {
                    phantom = i;
                    break;
                }
            if (mi >= 0 && phantom >= 0 && mi !== phantom)
                rowModel.move(mi, phantom, 1);
            if (root._pendingFrom >= 0 && root._pendingTo >= 0)
                root.moveRequested(root._pendingFrom, root._pendingTo);
            root._pendingFrom = -1;
            root._pendingTo = -1;
        }

        cloneComponent: Component {
            QueueRow {
                id: ghostRow
                objectName: "playerQueueRowGhost"
                property var flightData: null
                rowKey: ""
                title: ghostRow.flightData ? ghostRow.flightData.title : ""
                artist: ghostRow.flightData ? ghostRow.flightData.artist : ""
                dur: ghostRow.flightData ? ghostRow.flightData.dur : 0
                num: ghostRow.flightData ? ghostRow.flightData.num : 0
                songId: ghostRow.flightData ? ghostRow.flightData.songId : -1
                current: ghostRow.flightData ? !!ghostRow.flightData.current : false
                interactive: false
            }
        }
    }

    SelectionAutoScroll {
        id: autoScroll
        flickable: flick
        deadZone: root.autoScrollDeadZone
        rampDistance: root.autoScrollRamp
        maxSpeed: root.autoScrollMaxSpeed
    }

    // The row in the hand: the same three pieces RowFlight draws, so the
    // handoff at release changes nothing on screen.
    Item {
        id: dragGhost
        parent: root.flightOverlay ? root.flightOverlay : root
        z: 101
        visible: root._dragKey.length > 0 && !flight.active
        width: Math.max(0, flick.width - root.rowInset * root._s * 2)
        implicitHeight: root._rowContentH
        height: root._rowContentH

        // The contact shadow under the lifted row. Black on purpose and in
        // both themes, as RowFlight's is: it is a shadow the row casts, not a
        // surface of the design, and it is drawn blurred at 30% — a themed
        // grey would read as a grey card on light and as nothing on dark.
        Rectangle {
            id: ghostShadow
            anchors.fill: parent
            anchors.margins: -6
            anchors.topMargin: -2
            anchors.bottomMargin: -10
            radius: 12
            color: "#000000"
            opacity: 0.30
            z: -2
            layer.enabled: true
            layer.textureSize: dev.texSize(ghostShadow.width, ghostShadow.height)
            layer.effect: MultiEffect {
                blurEnabled: true
                blur: 1.0
                blurMax: 24
            }
        }
        Rectangle {
            anchors.fill: parent
            anchors.margins: -2
            anchors.topMargin: 0
            anchors.bottomMargin: 0
            radius: 7
            color: root.listBoxColor
            z: -1
        }
        QueueRow {
            id: ghostContent
            anchors.left: parent.left
            anchors.right: parent.right
            rowKey: ""
            title: {
                const i = root._modelIndexOf(root._dragKey, 0);
                return i >= 0 ? rowModel.get(i).title : "";
            }
            artist: {
                const i = root._modelIndexOf(root._dragKey, 0);
                return i >= 0 ? rowModel.get(i).artist : "";
            }
            dur: {
                const i = root._modelIndexOf(root._dragKey, 0);
                return i >= 0 ? rowModel.get(i).dur : 0;
            }
            num: {
                const i = root._modelIndexOf(root._dragKey, 0);
                return i >= 0 ? rowModel.get(i).num : 0;
            }
            songId: {
                const i = root._modelIndexOf(root._dragKey, 0);
                return i >= 0 ? rowModel.get(i).songId : -1;
            }
            current: ghostContent.songId >= 0 && ghostContent.songId === root.currentId
            interactive: false
        }
        scale: root.flightLiftScale
        transformOrigin: Item.Center
    }

    // =====================================================================
    //  THE HEADER
    //
    //  PINNED over the viewport: it is the tab's own title and its Clear
    //  button, and both have to be reachable wherever the list is scrolled
    //  to. So it does not scroll — the rows scroll UNDER it, and the fog
    //  above marks where they go. Its box still meets the container's top
    //  corners, so the two curves coincide.
    //
    //  Its height is held at the head of the content all the same (`headSlot`),
    //  which is what keeps the first row out from under it at rest and every
    //  slot in the list one pitch below the one above.
    // =====================================================================
    component QueueHeader: Item {
        id: head
        implicitHeight: Math.max(head._textH, clearButton.height)
                        + root.headerBoxPaddingV * 2 * root._s
                        + head.bottomGap
        // The air between the header box's foot and the first row's slot.
        // Public: the fog under the header is placed off it.
        readonly property real bottomGap: 6 * root._s
        readonly property real _pad: root.headerBoxPadding * root._s
        readonly property real _textH: fmHead.height
            + (root.compact ? 0 : fmArtist.height)

        ShadowBox {
            id: headBox
            anchors.fill: parent
            anchors.bottomMargin: head.bottomGap
            // The container's radius on every corner -- the head's two meet
            // the container's own. Pre-divided, because ShadowBox multiplies
            // every radius by sizeScale and the container's number is the
            // host's, not the row scale's.
            baseRadius: root.containerRadius / root._s
            sizeScale: root._s
            surfaceColor: root.listBoxColor
            backgroundColor: root.headerBoxColor
            bevelColor: root.headerBoxBevelColor
            shadowColor: root.headerBoxShadowColor
            bevelWidth: root.headerBevelWidth
            shadowWidth: root.headerShadowWidth
        }

        Text {
            id: headTitle
            x: head._pad
            y: root.headerBoxPaddingV * root._s
            text: "Queue"
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: root.headerTitleSize * root._s
            font.bold: true
        }
        Text {
            id: headCount
            x: root.compact
                ? headTitle.x + fmHead.advanceWidth(headTitle.text) + root.rowGap * root._s
                : head._pad
            y: root.compact ? headTitle.y + (fmHead.height - fmArtist.height) / 2
                            : headTitle.y + fmHead.height
            // Empty says nothing here: the body's "Nothing queued" is the one sentence.
            text: root._count === 0
                ? ""
                : root._count + (root._count === 1 ? " track · " : " tracks · ")
                  + Bytes.formatEta(root._totalDuration)
            color: root.mutedColor
            font.family: root.fontFamily
            font.pixelSize: root.artistSize * root._s
        }

        RaisedButton {
            id: clearButton
            x: head.width - width - head._pad
            y: (head.height - head.bottomGap - height) / 2
            height: Math.round(22 * root._s)
            minWidth: Math.round(52 * root._s)
            horizontalPadding: 10 * root._s
            fontPixelSize: root.figureSize * root._s
            fontFamily: root.fontFamily
            text: "Clear"
            enabled: root._count > 0
            radius: 8 * root._s
            bevelWidth: 1.5
            shadowWidth: 5
            // A raised button stands on the header box, not on the popup's
            // surface: the ground it is lifted off is what its shadow falls on.
            surfaceColor: root.headerBoxColor
            plateauColor: root.buttonPlateauColor
            plateauHoverColor: root.buttonPlateauHoverColor
            bevelColor: root.buttonBevelColor
            shadowColor: root.buttonShadowColor
            textColor: root.textColor
            faintTextColor: root.faintColor
            onClicked: root.clearRequested()
        }
    }

    // =====================================================================
    //  ONE ROW
    //
    //  [stripe] [ no. ]  Title                       3:47   [x]
    //                     Artist
    //
    //  Every figure sits in its own fixed slot, so a two-digit number or a
    //  four-minute song moves nothing beside it.
    // =====================================================================
    component QueueRow: Item {
        id: row
        objectName: "playerQueueRow"

        property string rowKey: ""
        property int songId: -1
        property string title: ""
        property string artist: ""
        property real dur: 0
        // The number drawn in the slot in front of the title: the album's
        // track number for a row that belongs to an album, its place in the
        // queue for every other row. Decided in `_numbers`, not here.
        property int num: 0
        // The song under the needle: the row wears the stripe.
        property bool current: false
        // The ghost and the flight clone draw the row without answering to
        // the pointer: there is exactly one live copy of any row.
        property bool interactive: true
        // WHAT THE ROW IS, as opposed to whether it is painted. A phantom gap
        // and a row still held below the fold are not rows of the list a
        // reader is looking at, and the list rule is written about exactly
        // that distinction. It is not read off `visible`: the list does not
        // paint the rows past the viewport, so a row scrolled past is invisible
        // but not held.
        property bool held: false

        implicitHeight: root._rowContentH

        readonly property real _pad: root.rowSidePadding * root._s
        readonly property real _left: row._pad + root.stripeWidth * root._s
                                    + root.rowGap * root._s + root._numSlot
                                    + root.rowGap * root._s
        readonly property real _right: root._durSlot + root.rowGap * root._s
                                     + root._removeSlot + row._pad

        // The mark, and the only one: full accent while the music runs,
        // drained toward the ground it lies on while it is paused. A drain
        // relative to the ground rather than an absolute grey is what keeps
        // it a drain in both themes.
        readonly property color _drained: Qt.hsla(
            root.accentColor.hslHue, 0.22,
            root.listBoxColor.hslLightness
                + (0.5 - root.listBoxColor.hslLightness) * 0.4732, 1.0)
        property real _playF: row.current && root.playing ? 1 : 0
        Behavior on _playF {
            NumberAnimation { duration: root.rowAnimDuration; easing.type: Easing.OutCubic }
        }

        Rectangle {
            id: stripe
            x: row._pad
            y: root.rowVPad * root._s
            width: root.stripeWidth * root._s
            height: Math.max(0, row.implicitHeight - root.rowVPad * 2 * root._s)
            radius: width / 2
            visible: row.current
            color: Mix.c(row._drained, root.accentColor, row._playF)
        }

        Text {
            id: numberText
            x: row._pad + root.stripeWidth * root._s + root.rowGap * root._s
            width: root._numSlot
            y: (fmTitle.height - fmFig.height) / 2 + root.rowVPad * root._s
            horizontalAlignment: Text.AlignRight
            text: row.num > 0 ? String(row.num) : ""
            color: root.faintColor
            font.family: root.fontFamily
            font.pixelSize: root.figureSize * root._s
        }

        Text {
            id: titleText
            x: row._left
            y: root.rowVPad * root._s
            width: Math.max(0, row.width - row._left - row._right
                            - (root.compact ? row._artistW + root.rowGap * root._s * 2 : 0))
            elide: Text.ElideRight
            text: row.title
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: root.titleSize * root._s
        }

        // Compact puts the artist on the title line, right-aligned in what
        // the title leaves: the artists then form a column of their own and
        // no row's artist moves when another row's title changes length.
        // Measured, never read back off the Text that draws it.
        readonly property real _artistW: root.compact
            ? Math.min(fmArtist.advanceWidth(row.artist),
                       Math.max(0, (row.width - row._left - row._right) * 0.45))
            : 0

        Text {
            id: artistText
            // In compact the artist ends one gap before the duration's SLOT,
            // not against the duration's ink. Audiowide has no tabular figures,
            // so a right-aligned time's left edge wanders with its digits: pack
            // the artist against that and the gap breathes from 6 px to 0 as
            // the seconds tick.
            x: root.compact ? row.width - row._right - root.rowGap * root._s - row._artistW
                            : row._left
            y: root.compact
                ? titleText.y + (fmTitle.height - fmArtist.height) / 2
                : titleText.y + fmTitle.height + root.rowLineGap * root._s
            width: root.compact ? row._artistW
                                : Math.max(0, row.width - row._left - row._right)
            elide: Text.ElideRight
            text: row.artist
            color: root.mutedColor
            font.family: root.fontFamily
            font.pixelSize: root.artistSize * root._s
        }

        Text {
            id: durText
            x: row.width - row._pad - root._removeSlot - root.rowGap * root._s
               - root._durSlot
            width: root._durSlot
            y: (fmTitle.height - fmFig.height) / 2 + root.rowVPad * root._s
            horizontalAlignment: Text.AlignRight
            text: row.dur > 0 ? Bytes.formatEta(row.dur) : ""
            color: root.faintColor
            font.family: root.fontFamily
            font.pixelSize: root.figureSize * root._s
        }

        // The whole row is the play target. Nothing announces it but the
        // pointer; there is no hover wash, exactly as in the update's list.
        MouseArea {
            id: rowArea
            anchors.fill: parent
            enabled: row.interactive
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            property bool armed: false
            property real pressSceneY: 0

            onPressed: (mouse) => {
                const p = rowArea.mapToItem(null, mouse.x, mouse.y);
                if (mouse.button === Qt.RightButton) {
                    if (row.songId >= 0) root.menuRequested(row.songId, p.x, p.y);
                    return;
                }
                rowArea.armed = true;
                rowArea.pressSceneY = p.y;
            }
            onPositionChanged: (mouse) => {
                if (!rowArea.armed && !root._dragging) return;
                const p = rowArea.mapToItem(null, mouse.x, mouse.y);
                if (root._dragging) { root._dragTo(p.y); return; }
                if (Math.abs(p.y - rowArea.pressSceneY) < root.dragThreshold * root._s) return;
                root._beginDrag(row, p.x, p.y);
                root._dragTo(p.y);
            }
            onReleased: (mouse) => {
                if (root._dragging) {
                    root._endDrag(false);
                } else if (rowArea.armed
                           && rowArea.contains(Qt.point(mouse.x, mouse.y))) {
                    if (row.songId >= 0) root.playRequested(row.songId);
                }
                rowArea.armed = false;
            }
            onCanceled: {
                if (root._dragging) root._endDrag(true);
                rowArea.armed = false;
            }
        }

        // The one glyph on the row, and it is not there until the pointer is.
        // Its slot is reserved at all times, so nothing shifts when it fades.
        Item {
            id: removeSlot
            x: row.width - row._pad - root._removeSlot
            y: (row.implicitHeight - height) / 2
            width: root._removeSlot
            height: root._removeSlot
            opacity: row.interactive && (rowArea.containsMouse || removeArea.containsMouse)
                     ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 160 } }

            Text {
                anchors.centerIn: parent
                text: "\uF00D"   // fa-times
                font.family: "Symbols Nerd Font"
                font.pixelSize: root.figureSize * root._s
                color: removeArea.containsMouse ? root.textColor : root.faintColor
            }
            MouseArea {
                id: removeArea
                anchors.fill: parent
                enabled: row.interactive
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: if (row.songId >= 0) root.removeRequested(row.songId)
            }
        }
    }

}
