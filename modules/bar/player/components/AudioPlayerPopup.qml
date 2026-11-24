pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

import "../../../common/theme"
import "../../../common/components"
import "../../../common/components/EditKeys.js" as EK

// =============================================================================
// AudioPlayerPopup.qml
//
// The audio player, as one drop-in for the bar's popup: a record on a platter,
// what is playing, a viewfinder, the transport, and -- when it is opened out --
// the queue or the library beside them.
//
// It owns composition and nothing else. The record is VinylStage's, the seek is
// PlayerViewfinder's, MPD is MpdService's; this file decides where they sit,
// how big the popup is in each view, and WHEN the record is put on and taken
// off the platter.
//
// Two views and a sidebar, switched by the two buttons at the foot:
//
//   mini      the record small beside the title, the viewfinder under it.
//             Sized to its own content, the way the system update's quiet is.
//   player    the record at full size, the centrepiece.
//   + sidebar the queue, the library or the track's own data beside it, which
//             the burger opens.
//
// The record is put on the platter per ALBUM, not per track. A record does not
// come out of its sleeve between two songs of the same album, and the module
// says so by simply not animating: the label is the album's cover, so nothing
// about it changes when the track does. What does happen per album:
//
//   a new album      the old record is run down and sleeved while the new one
//                    sweeps in -- the two sleeves cross, as the spec asks.
//   the half of it   VinylStage.flipSequence(): the record is flipped onto its
//                    other side, 1260 degrees about a wandering axis, without
//                    touching playback.
//   the end          run down, lift, and be fired back into the sleeve.
//
// Only ONE of those may hold the audio: a play pressed HERE on a stopped player
// waits for the record to be down before it starts the music. Anything that was
// already playing is never interrupted -- the animation catches up to it
// instead (`snapToPlaying`).
//
// The drop-in rules: no background is painted here (the host paints the
// surface), the size is carried by implicitWidth/implicitHeight with no
// Behavior of their own (the host eases them), the data lives outside in
// `player` because the host's Loader destroys this item on every close, and
// every colour is a Theme token a host may override.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // INPUTS
    // ======================================================================
    // An MpdService. Lives outside the popup: thePopup's Loader recreates the
    // content on every open, and a connection, a queue and a playing record
    // must all survive that.
    property var player: null

    // "mini" | "player". The queue and the library are a SIDEBAR, not a view,
    // and the burger opens it. With two views a single toggle at the bottom
    // left switches them -- mirroring the burger at the bottom right.
    property string viewMode: "player"
    // Whether that sidebar is open, and which panel it shows.
    property bool browseOpen: false
    property string browsePanel: "queue"

    property bool allowModeSwitch: true
    property bool vinylEnabled: true
    // How loud the music is, 0..1, for the viewfinder's playback sparks. A host
    // may drive it directly; `levelTapEnabled` instead lets the popup find
    // MPD's own PipeWire stream and measure it. Off by default: the tap costs a
    // process and about 25 MB, and only the module that OPENS the popup knows
    // whether that is worth it.
    property real loudness: 0
    // The rail's sparks follow the MUSIC, which costs one recorder on the
    // daemon's own output while something is playing. On, because the whole
    // point of the effect is that it answers the track: off, the rail throws
    // sparks by the ball's travel alone, which is a spark a second over a
    // four-minute song.
    property bool levelTapEnabled: true
    property bool vinylParticles: true
    property bool railParticles: true
    // An album started on a silence -- queued, played from its row, its cover, its
    // page or its menu -- waits for the record to touch down before it makes a
    // sound: that arrival is the module's one cinematic moment, so the music
    // waits for it. Every other way of starting playback (the play button, a
    // song picked out of the library, a track change) makes its sound as the
    // arrival BEGINS: waiting there would only be a pause between two songs.
    property bool holdPlaybackUntilDown: true

    // THE LIBRARY AS THE POPUP OPENS IT (player.jsonc library): the grouping, each grouping's sort and its direction, and whether
    // the artists shelf lists the artists with loose songs only (the service's switch, put to this at every open: the panel's
    // button changes it for the rest of the open).
    property string libraryGrouping: "albums"
    property var librarySort: ({ albums: "artist", artists: "name", genres: "name", playlists: "order" })
    property bool libraryAscending: true
    property bool libraryLooseArtists: false

    property string fontFamily: "Inter"

    // ======================================================================
    // HANDLES (the mockup's panel drives the inner components through these,
    // rather than through twenty pass-through properties)
    // ======================================================================
    readonly property alias vinyl: vinylStage
    // The record's material and the sleeve's wear, one hop rather than two: a
    // panel (and the wiring check that holds it honest) resolves
    // `popup.vinylDisc`, but gives up on `popup.vinyl.disc`.
    readonly property alias vinylDisc: vinylStage.disc
    readonly property alias vinylSleeve: vinylStage.sleeve
    readonly property alias turntable: vinylStage.platter
    readonly property alias rail: viewfinder
    readonly property alias transport: transportRow
    readonly property alias trackInfo: infoBlock
    readonly property alias queuePanel: queueList
    readonly property alias libraryPanel: libraryList
    readonly property alias dataPanel: dataPanel
    // The sidebar's own selector, which is a TabSelector like every other one
    // in the shell and has knobs of its own.
    readonly property alias panelTabs: panelTabs
    // The measurement behind the rail's sparks: its floor, its span and what
    // counts as a beat are knobs like any other.
    readonly property alias levelTap: levelTap

    // ======================================================================
    // GEOMETRY
    // ======================================================================
    property real padding: 12
    property real cardPadding: 12
    // Between the track's figures and the viewfinder under them: 12, where the
    // shell's text-to-rail gap is 6, because at 6 the figures sit too close to
    // the rail. The record gives the space up, not the popup.
    property real railGap: 12
    property real bodyGap: 10
    property real cardRadius: 14
    property real cardRadiusCompact: 10
    // The queue/library selector, at the foot of the sidebar column and level
    // with the transport beside it.
    property real panelTabWidth: 260
    // The transport's buttons are 38 across, and the selector sits beside them
    // on the same row: at 30 it would read as a shorter thing on the same
    // line. One number for both -- the buttons' own size.
    property real panelTabHeight: 38

    property real miniWidth: 480
    property real playerWidth: 560
    property real browsePanelWidth: 400
    // The full player, top to bottom; the record takes whatever room the text
    // and the rail leave, not the popup.
    property real playerMinHeight: 720
    // The record in mini: a thumbnail that still turns.
    property real miniVinylSize: 118
    property real transportHeight: 44

    readonly property bool compact: root.viewMode === "mini"
    // LAID OUT AT REST WHILE THE HOST OPENS AND CLOSES IT (GooeyEngine's content contract, THE REST FRAME): the record is
    // sized by the view (`_switchF` below), and laid out on a box still growing the card shrank under a full record and the
    // transport rode up over it. The growing box reveals this layout instead, standing still.
    readonly property bool revealOnOpen: true
    // The sidebar only makes sense beside the full player: mini is a strip.
    // Pressing the burger there opens the player WITH the sidebar rather than
    // refusing, which is what a burger that is visible should do.
    readonly property bool browsing: root.browseOpen && !root.compact
    // ONE RADIUS, WHATEVER IS OPEN. A sidebar that shrank it to the compact 10
    // would re-cut the record's own container and every header, button and
    // selector that has to meet its corners -- a module changing shape because
    // a panel appeared beside it. The compact radius belongs to the compact
    // VIEW, which is `mini`, and to nothing else.
    readonly property real _cardRadius: root._lerp(root.cardRadius, root.cardRadiusCompact, root._switchF)

    // ======================================================================
    // PALETTE
    // ======================================================================
    property color surfaceColor: Theme.surface
    property color panelColor: Theme.panelSunk
    property color listBoxColor: Theme.listBox
    property color headerBoxColor: Theme.headerBox
    property color bevelColor: Theme.bevel
    property color borderColor: Theme.border
    property color shadowDeepColor: Theme.shadowDeep
    property color primaryText: Theme.textPrimary
    property color mutedText: Theme.textMuted
    property color faintText: Theme.textFaint
    property color accent: Theme.accent
    property color accentHover: Theme.accentHover
    property color accentBevel: Theme.accentBevel
    property color textOnAccent: Theme.textOnAccent
    property color ballShadowColor: Theme.ballShadow
    property color buttonPlateauColor: Theme.buttonPlateau
    property color buttonPlateauHoverColor: Theme.buttonPlateauHover
    property color buttonBevelColor: Theme.buttonBevel
    property color buttonShadowColor: Theme.buttonShadow

    // ======================================================================
    // WHAT IS PLAYING
    //
    // Everything below reads `player` defensively: the popup is built before a
    // backend is handed in, and the mockup drives it with a stub.
    // ======================================================================
    readonly property var _cur: root.player ? root.player.current : null
    readonly property bool _hasSong: !!root._cur
    readonly property bool _playing: root.player ? root.player.playing : false
    readonly property real _position: root.player ? root.player.elapsed : 0
    readonly property real _duration: root.player ? root.player.duration : 0
    function _keyOf(song) {
        return song ? ((song.albumArtist || song.artist || "") + " — " + (song.album || "")) : "";
    }

    // WHICH ALBUM BELONGS ON THE PLATTER -- not "which song is playing".
    //
    // The current song goes null for a frame whenever the queue is edited, and
    // reading the album off it alone would make the record leave and come back
    // for a song being deleted three tracks away. So when nothing is playing the
    // queue's own head answers instead: a queue that still holds the album is a
    // record that stays on.
    readonly property var _queueHead: (root.player && root.player.queue && root.player.queue.length > 0) ? root.player.queue[0] : null

    // WHAT THE RECORD IS ABOUT, ASKED OF THE PLAYER RATHER THAN OF A BINDING.
    //
    // Every handler below calls this instead of reading `_albumSource`. The
    // reason: a change handler runs from inside its source's notify list,
    // BEFORE the other bindings on that source have had their turn, so
    // `on_QueueHeadChanged` sees the new queue with the old album's key -- and
    // an autoplay armed there decides there is nothing to wait for and starts
    // the music over an arrival that has not begun. A function reads the player
    // as it IS.
    //
    // The bindings below are this same function, so the two can never disagree;
    // they exist because the UI wants a property to bind to.
    function _sourceNow() {
        if (!root.player)
            return null;
        if (root.player.current)
            return root.player.current;
        // THE QUEUE ANSWERS FOR AN ALBUM THAT HAS NOT PLAYED, NEVER FOR ONE
        // THAT HAS FINISHED. The daemon at the end of its queue looks exactly
        // like a daemon holding a queue it has not started: stopped, with
        // nothing under the needle. The difference is memory -- the record on
        // the platter has been played -- and without it an album that ran out
        // leaves the record turning on an empty platter until the queue is
        // cleared by hand. It is only ever about
        // the album ON the platter: a queue whose head is some other album is a
        // record waiting to arrive, not one that has run out.
        // ...and it is asked of `_playedKey`, NEVER of `_onPlatter`. This is a
        // BINDING: reading a property that `_syncPlatter` writes would make it
        // depend on its own consequence (Qt reports
        // `Binding loop detected for property "_albumSource"`) -- and a loop
        // here is not a warning, it is the arrival running twice, because the
        // key changes under the very handler that has just started one.
        // `_playedKey` is written from a change handler and from nowhere else.
        const q = root.player.queue;
        const head = (q && q.length > 0) ? q[0] : null;
        // ...and the queue is only SPENT if the playhead had reached its end.
        // A daemon that stops anywhere else -- a stop pressed by hand, a repeat
        // that was turned off mid-album, a status that says "stop" for one
        // frame while the queue is rebuilt under it -- is not a queue that ran
        // out, and taking the record off for one of those would be a fault (the
        // repeat-all edge case).
        if (root._playedKey !== "" && root.player.playState === "stop"
            && root._keyOf(head) === root._playedKey
            && root._lastPos >= 0 && q && root._lastPos === q.length - 1)
            return null;
        return head;
    }
    readonly property var _albumSource: root._sourceNow()
    readonly property string _albumKey: root._keyOf(root._albumSource)
    readonly property string _coverUrl: root._coverOf(root._albumSource)
    // Read through the FUNCTION, never through `_coverUrl`, anywhere a change
    // handler runs: `_albumKey` and `_coverUrl` are two bindings on the same
    // source, and `on_AlbumKeyChanged` fires from inside that source's notify
    // list -- before `_coverUrl`'s turn in the same list. The handler therefore
    // sees the NEW album with the OLD album's cover (an empty one, on the first
    // arrival), and the record arrives blank.
    function _coverOf(song) {
        return song ? (song.coverUrl || "") : "";
    }

    // ======================================================================
    // SIZE
    //
    // mini is computed from its content, as the shell's compact views are; the
    // player's is a fixed minimum the host may exceed. No Behavior here: the
    // host eases these, and an already-eased implicit animates twice.
    // ======================================================================
    // Padding above the card, padding between the card and the transport, and
    // padding below it.
    readonly property real _chromeHeight: root.padding * 2 + root.transportHeight + root.padding

    implicitWidth: root.compact ? root.miniWidth : (root.browsing ? root.playerWidth + root.bodyGap + root.browsePanelWidth : root.playerWidth)

    implicitHeight: root.compact ? root._chromeHeight + card.targetHeight : root.playerMinHeight

    // ======================================================================
    // HOW FAR THROUGH A VIEW SWITCH WE ARE. 0 is the player, 1 is mini.
    //
    // DERIVED FROM THE POPUP'S OWN HEIGHT, not from a Behavior of its own,
    // because this popup animates nothing: the HOST eases its size, and the
    // two hosts do not agree on the curve. The mockup's stage runs 260 ms
    // OutCubic; the gooey bar runs 400 ms OutBack and overshoots by 1.2, and
    // on a side bar it swaps the axes. A clock of our own would be right in one
    // and visibly out of step in the other, and the drop-in rule is that the
    // content assumes nothing about the host beyond what it exposes. Reading
    // the size the host has actually given us is the one measure that is true
    // under both, and it keeps the shell's "one clock per motion" exactly.
    //
    // HEIGHT AND NOT WIDTH. The height moves only when the view changes; the
    // width also moves when the sidebar opens, which would drag the record's
    // size into a gesture that has nothing to do with it.
    //
    // Under a host that ignores `implicitHeight` and pins a size, this never
    // moves and every switch is instant, so there is no host this can be worse
    // on.
    //
    // The mini resting height has to be known from the player too, and in the
    // player nothing computes it -- `targetHeight` is mini's. So it is latched
    // whenever mini is the resting view; it moves only with the track's own
    // text metrics, and a stale one costs a slightly wrong curve, never a
    // wrong destination.
    property real _miniRestHeight: root._chromeHeight + root.miniVinylSize + root.cardPadding * 2
    // LATCHED AT REST, and rest is when the host's size equals ours. Latching
    // on the view flag alone would let the value move DURING a switch -- the
    // title block's metrics ease, so its implicit height changes every frame --
    // and a curve whose endpoint moves is not the same curve backwards.
    // READ LIVE, NOT THROUGH A BINDING. This runs as a handler of
    // `implicitHeightChanged`, and a handler runs inside its source's notify
    // list BEFORE sibling bindings re-evaluate -- so an `_atRest` binding read
    // here would still be true from the mini rest on the very frame the view
    // flips to player, and the player's resting size would be latched from the
    // MINI title block (512 for 496). The rule: a handler reads its facts
    // through a function, never through a sibling binding.
    function _latchRest() {
        if (root.height !== root.implicitHeight)
            return;
        if (root.compact)
            root._miniRestHeight = root.implicitHeight;
        else
            root._playerDiscSize = root._playerDiscLive;
    }
    onImplicitHeightChanged: root._latchRest()
    onHeightChanged: {
        root._latchRest();
        root._switchArrived();
    }

    //
    // ONLY WHILE A SWITCH IS IN FLIGHT (`_switching`). The height also moves when the HOST opens the popup: from nothing, on
    // every open, so a fraction read off it at any time replayed mini -> player under every open of the player (the record
    // grew in from the mini size) and swelled the mini record with the open's overshoot. Between switches it is the view's
    // own value, and the growing box reveals a layout that holds still. (`_switching` goes up in the view's change handler,
    // which runs before any binding has followed the view, so the first frame of a switch reads the height still at the old
    // view's rest -- the old view's value -- and the last, 420 ms on, the new one's: the two ends meet.)
    readonly property real _switchF: {
        const span = root.playerMinHeight - root._miniRestHeight;
        if (!(span > 1) || !root._switching)
            return root.compact ? 1 : 0;
        return Math.max(0, Math.min(1, (root.playerMinHeight - root.height) / span));
    }
    function _lerp(a, b, f) { return a + (b - a) * f; }
    // EVERY DISCRETE SWAP HAPPENS HERE, at the half-way point, in both
    // directions -- which is what makes the reverse switch the forward one
    // played backwards. Keyed on the bool, a swap would land at the START of
    // one direction and therefore at the END of the other.
    readonly property bool _pastHalf: root._switchF >= 0.5
    readonly property bool _midSwitch: root._switchF > 0.001 && root._switchF < 0.999

    // THE RECORD'S TWO RESTING SIZES, and the one it is drawn at between them.
    //
    // The player's size is measured against the card's RESTING height, never
    // taken as the RESIDUAL of the live card (whatever is left after the text
    // and the rail take their implicit heights): that is right at rest and
    // wrong the whole way through a switch -- on mini -> player the flag flips
    // while the card is still 142 px tall, so the subtraction goes NEGATIVE
    // (measured: -1.5 on the first frame), the record vanishes, the title and
    // the rail take the whole card, and the record only reappears once the
    // eased height has grown past them. And on player -> mini a constant
    // branch would take the record from 496 to 118 in one frame. Interpolated
    // from the resting height, it is monotone both ways and cannot grow first
    // then shrink.
    readonly property real _playerCardHeight: root.playerMinHeight - root._chromeHeight
    readonly property real _playerDiscLive: Math.max(0, Math.min(
        root.playerWidth - root.padding * 2 - root.cardPadding * 2,
        root._playerCardHeight - root.cardPadding * 2 - infoBlock.implicitHeight
            - root.railGap - viewfinder.implicitHeight - root.railGap))
    // LATCHED WHILE THE PLAYER IS THE RESTING VIEW. The title block and the
    // rail change their implicit heights the instant `compact` flips -- the
    // mini block is shorter -- so read live, the "player's resting size" would
    // grow by 16 px on the first frame of player -> mini (measured: 496 to 512)
    // before the lerp shrank it: a grow-then-shrink. Held from the last frame
    // the player was at rest, it is the size the record was actually drawn at.
    //
    // Seeded once at completion and never READ through a binding from the live
    // value: `_discSize` places the title block, whose height in mini reaches
    // back to the title block's own y, and a fallback that read the live
    // value from inside `_discSize` would close that circle (a binding loop on
    // `_discSize`). The seed is taken whatever view the popup is
    // built in; built into mini it is the mini block's height and so a few
    // pixels generous, and it is corrected on the first frame the player is
    // at rest, before anything could travel to it.
    property real _playerDiscSize: 0
    on_PlayerDiscLiveChanged: root._latchRest()
    readonly property real _discSize: root._lerp(root._playerDiscSize, root.miniVinylSize, root._switchF)
    // Where the title block's left edge is: beside the record in mini, at the
    // card's padding in the player. The rail's left margin follows the same
    // number, so the two move as one.
    readonly property real _infoX: root._lerp(root.cardPadding,
                                              root.cardPadding + root.miniVinylSize + root.cardPadding,
                                              root._switchF)

    // A switch in flight: the two fractions read the host's size only now (`_switchF`, `_sidebarF`). And tips are dismissed for
    // the length of a switch: `HoverTip` only closes when its `show` goes false, and the pointer is still on the button it
    // just pressed, so nothing else would ever close them.
    //
    // It ends when the host's size HAS ARRIVED at the asked one (both axes, within half a pixel): there the two fractions read
    // off the size are the view's own values, so handing them back to the view is no step. Not on a timer of its own: a timer
    // is no measure of the host's ease (the bar's resize is 260 ms, a switch during an open runs the open's 400, and a frame
    // that stalls makes any ease late), and a switch cut short would finish in one frame. `switchSettle` is only the end for a
    // host that never gives the asked size (a pinned stage), long after any ease.
    property bool _switching: false
    onViewModeChanged: { root._switching = true; switchSettle.restart(); }
    onBrowseOpenChanged: { root._switching = true; switchSettle.restart(); }
    function _switchArrived() {
        if (root._switching && Math.abs(root.width - root.implicitWidth) < 0.5 && Math.abs(root.height - root.implicitHeight) < 0.5) {
            switchSettle.stop();
            root._switching = false;
        }
    }
    onWidthChanged: root._switchArrived()
    Timer {
        id: switchSettle
        interval: 1500
        repeat: false
        onTriggered: root._switching = false
    }

    // HOW FAR THE SIDEBAR IS OUT, 0 shut and 1 open, read off the popup's WIDTH
    // the same way `_switchF` is read off its height: the width is what the
    // host eases when the sidebar opens or closes, and it is the only thing
    // that moves then. The panel stays in the layout while this is above zero,
    // so closing it -- or leaving it behind on the way into mini -- shrinks it
    // with the container instead of dropping it in one frame: the opening, in
    // reverse.
    // And like `_switchF`, only while a switch is in flight: between switches the panel is out or not, and an open (whose box
    // grows from nothing) neither slides it in nor swells it with the overshoot.
    readonly property real _sidebarF: !root._switching ? (root.browsing ? 1 : 0) : Math.max(0, Math.min(1,
        (root.width - root.playerWidth) / Math.max(1, root.bodyGap + root.browsePanelWidth)))
    readonly property bool _sidebarShown: root.browsing || root._sidebarF > 0.002
    // A component that is about to disappear or has just appeared gets a short
    // fade of 2-3 frames over the whole assembled component. As a fraction of
    // the sidebar's travel, so it is the same clock. The ease is OutCubic, so
    // its first frame already covers a fifth of the travel at 60 Hz and a tenth
    // at 120: 0.2 is one or two frames on the former and three on the latter.
    property real sidebarFadeF: 0.2
    readonly property real _sidebarOpacity: Math.max(0, Math.min(1, root._sidebarF / root.sidebarFadeF))

    // ======================================================================
    // THE RECORD'S LIFE
    //
    // One rule: the record on the platter is the ALBUM, so the sequences are
    // driven by the album changing, never by the track.
    // ======================================================================
    property string _onPlatter: ""       // the album key the record carries
    property bool _holdingForDrop: false
    // The art the record on the platter is WEARING, which is not the same as
    // the art of what is playing: a cleared queue has nothing playing, and the
    // record that is being put away still has to be the record you were just
    // listening to. Set when an arrival starts and kept until the next one.
    property string _platterArt: ""
    // WHICH ALBUM HAS ACTUALLY PLAYED. Latched the moment the music runs, and
    // read only by `_sourceNow` to tell an album that RAN OUT from one that has
    // not started: the daemon looks the same in both cases. It is a key rather
    // than a flag so a queue whose head is some other album is never mistaken
    // for one that finished -- and it is cleared by nothing else, because a
    // finished queue stays finished until something new is queued or played.
    // (Clearing it when the record leaves would bring the record straight back
    // on: the head would become the source again the instant the platter is
    // empty.)
    property string _playedKey: ""
    // ...and WHERE it was in the queue, so "the queue ran out" can be told from
    // "the daemon stopped". Latched while something is playing and kept after,
    // because the answer is needed exactly when there is no current song left.
    property int _lastPos: -1
    on_PlayingChanged: if (root._playing) {
        root._playedKey = root._keyOf(root._sourceNow());
        if (root.player && root.player.songPos >= 0)
            root._lastPos = root.player.songPos;
    }
    Connections {
        target: root.player
        enabled: !!root.player
        function onSongPosChanged() {
            if (root.player && root.player.songPos >= 0)
                root._lastPos = root.player.songPos;
        }
    }

    // The grace an empty album is given before the record is taken off. Long
    // enough to cover a lost reply and a queue being replaced, short enough
    // that a cleared queue still reads as immediate.
    property int emptyGraceMs: 350
    property bool _emptyPending: false
    property bool _emptyConfirmed: false
    Timer {
        id: emptyGrace
        interval: root.emptyGraceMs
        repeat: false
        onTriggered: {
            root._emptyPending = false;
            // Still nothing? Then it is real -- and this is the one pass that
            // is allowed to act on it.
            if (root._keyOf(root._sourceNow()) === "") {
                root._emptyConfirmed = true;
                root._syncPlatter();
                root._emptyConfirmed = false;
            }
        }
    }

    on_AlbumKeyChanged: {
        // The album changed under running music (an album replaced over another): it is the one that runs out, or the record stays on
        // for good at the end of it. `_playing` rises before the queue is read, so the rise sees the album it replaces.
        if (root._playing && root._keyOf(root._sourceNow()) !== "")
            root._playedKey = root._keyOf(root._sourceNow());
        // An album that came back inside the grace window cancels the put-away
        // it was about to cause.
        if (root._emptyPending && root._keyOf(root._sourceNow()) !== "") {
            root._emptyPending = false;
            emptyGrace.stop();
        }
        root._syncPlatter();
    }
    // The art can land AFTER the record does. A cover pulled out of the file
    // itself is one process away, so the album is known long before its picture
    // is: when the picture turns up for the album that is ON the platter, the
    // record puts it on rather than waiting for the next album to come round.
    // It is not a second arrival -- nothing moves, the label is simply there.
    on_CoverUrlChanged: {
        const src = root._sourceNow();
        const key = root._keyOf(src);
        const cover = root._coverOf(src);
        if (key !== "" && key === root._onPlatter && cover !== "" && root._platterArt !== cover)
            root._platterArt = cover;
    }
    on_QueueHeadChanged: {
        // What was asked for is not the album that ran out, even when it is the same album: it starts again, on a record of its own.
        if (root._autoplayArmed && root._queueHead)
            root._playedKey = "";
        root._syncPlatter();
        root._maybeAutoplay();
    }

    // Queueing an album into an empty queue starts it. The record's arrival
    // still holds the sound until it is down -- that is `_requestPlay`'s rule,
    // not a second one here.
    //
    // ARMED BY THE ACT OF QUEUEING, never by the queue's length changing. A
    // popup is rebuilt on every open, so its first look at a queue that is
    // already there is a 0 -> N transition, and "the queue grew from empty" would
    // therefore be true the instant the window opens: opening the popup would
    // start the music. The daemon does the same thing at shell start, filling
    // its queue from an asynchronous reply. So the flag is set where the USER
    // asks for something to be queued, and it survives exactly until the queue
    // actually arrives.
    property bool autoplayOnQueue: true
    property bool _autoplayArmed: false
    // WHETHER THE MUSIC WAITS FOR THE RECORD. Only a whole ALBUM does: its arrival
    // is the answer to "I queued that", and the album it brings does not start
    // until it is down. A song or a list queued into a silence plays AS SOON AS IT
    // IS QUEUED -- the record arrives over the music, as it does for a play pressed
    // by hand.
    property bool _autoplayHold: false
    function _armAutoplay(holdForArrival) {
        if (!root.autoplayOnQueue || !root.player)
            return;
        // Only into a silence. Queueing an album behind something that is
        // playing must not take the music over.
        if (root.player.playState === "stop") {
            root._autoplayArmed = true;
            root._autoplayHold = holdForArrival === true;
        }
    }
    function _maybeAutoplay() {
        if (!root._autoplayArmed || !root.player)
            return;
        const n = root.player.queue ? root.player.queue.length : 0;
        if (n === 0)
            return;
        root._autoplayArmed = false;
        // THE ONLY CALLER THAT MAY WAIT, AND ONLY FOR AN ALBUM (`_autoplayHold`).
        // The record's arrival is the answer to "I queued that", so the album it
        // brings does not start until it is down; a song or a list, like a play
        // pressed by hand, is answered at once.
        if (root.player.playState === "stop")
            root._requestPlay(root._autoplayHold);
    }
    // PLAY ON AN ALBUM. With no record to play -- an empty queue, or one that ran out
    // -- it is loaded and the record brings it: the arrival is the answer, and the
    // music starts when the record is down, as for an album queued. The row's menu,
    // its cover and the page's button all come here. Anything on the platter that is
    // not on its way off is replaced at once and the record catches up, playing or
    // not: run down and sleeved first, an album played on a paused record would be
    // ten seconds of silence (measured, in the real shell).
    function _playAlbum(albumArtist, album) {
        if (!root.player)
            return;
        const noRecord = root._onPlatter === "" || root._keyOf(root._sourceNow()) === "";
        if (root.player.playState === "play" || !noRecord || !root.vinylEnabled || !root.holdPlaybackUntilDown || !root.autoplayOnQueue) {
            root._holdingForDrop = false;
            root.player.playAlbum(albumArtist, album);
            return;
        }
        root._autoplayArmed = true;
        root._autoplayHold = true;
        root.player.loadAlbum(albumArtist, album);
    }

    // The cover is loaded BEFORE the record flies in, not while it does: the
    // label is the whole point of the arrival, and a record that sweeps in
    // blank and fills in halfway is worse than one that starts a beat later.
    // `Image` caches, so the disc's own copy is instant once this one is in.
    Image {
        id: coverPreload
        source: root._coverUrl
        visible: false
        asynchronous: true
        cache: true
        // scale-ok: this Image only warms the cache entry VinylDisc's label reads (same url, same sourceSize), and the label's decode
        // is `labelTexMax` = 512 whatever the scale (2x its drawn size, minified): this number must stay equal to it
        sourceSize.width: 512
        sourceSize.height: 512
        // MIPMAPPED, because the disc's LABEL is: this Image never draws, it
        // only warms the cache, and two Images sharing a cache key (same url,
        // same sourceSize) while disagreeing about mipmaps is what raises
        // "QSGPlainTexture: Mipmap settings changed without having image data
        // available" -- a warning that only appears when the record and a live
        // particle bloom are on screen together.
        mipmap: true
        // The preload is what an arrival waits on, so every move it makes is a
        // reason to look again -- a cached cover reaches `Ready` in the same
        // turn its source is set, and a flag that never goes false in between
        // would never announce itself.
        onSourceChanged: root._syncPlatter()
        onStatusChanged: {
            root._syncPlatter();
            root._noteCover();
        }
    }
    // THE LIBRARY'S PICTURES WAIT FOR THE RECORD'S LABEL, ONCE. Every async Image of
    // the process shares one reader thread and the pictures queued last are read
    // first: the library's dozen rows, built after the preload above, are decoded
    // BEFORE the label the user is looking at. So the rows are told to start only
    // after the label is in (or has nothing to load), and are never told to stop --
    // an album change must not blank twelve covers. A host with no label to wait
    // for (no record, or a preload that hangs) opens them after `_coversWaitMs`.
    property bool _coversOpen: false
    property int _coversWaitMs: 1200
    function _noteCover() {
        if (root._coversOpen)
            return;
        if (root._coverReady(root._coverOf(root._sourceNow())))
            root._coversOpen = true;
    }
    Timer {
        interval: root._coversWaitMs
        running: !root._coversOpen
        onTriggered: root._coversOpen = true
    }
    // Ready means THIS cover is ready: the preload still points at the previous
    // album for one turn after the source changes, and its `Ready` from that one
    // is not an answer about this one.
    //
    // Both sides go through `Qt.resolvedUrl` first, because they are not the
    // same kind of thing. `source` is a `url` and reads back PERCENT-DECODED;
    // the service hands out `encodeURI(path)`, and every one of the 38 album
    // directories here has a space in its name. Comparing the two as strings
    // is false for every real album -- the record never arrives, and because
    // `_holdingForDrop` is only cleared by the arrival finishing, the transport
    // would then swallow every press for the life of the popup.
    function _coverReady(url) {
        if (url === "")
            return true;
        return String(coverPreload.source) === String(Qt.resolvedUrl(url))
            && (coverPreload.status === Image.Ready || coverPreload.status === Image.Error);
    }

    // WHAT THE RECORD SHOULD BE WEARING, and the one rule that decides what to
    // do about it:
    //
    //   AN ANIMATION THAT HAS STARTED ALWAYS FINISHES.
    //
    // Skipping through a varied playlist asks for a new record faster than the
    // record can be changed, and answering every ask immediately --
    // `endSequence()` on top of a running arrival, `startSequence()` on top of
    // a put-away -- leaves the choreography stopped half way with a sleeve in
    // the air. So an ask only ever updates `_wantKey`; the sequences
    // are driven from `_step`, and `_step` never interrupts anything. When one
    // finishes, the next is decided from the album that is wanted THEN -- not
    // from the one that was wanted when it started, which may be four skips
    // old.
    property string _wantKey: ""

    // A sequence is running, or the stage is somewhere between two of them.
    // ASKED OF THE STAGE, never read off the binding, in `_step`. The binding
    // exists for the change signal below; reading it inside a handler is a
    // trap -- the phase moves in the same notify pass, so the property still
    // says what it said before, and a put-away would be started on top of an
    // arrival that has already begun.
    function _stageBusyNow() {
        const ph = vinylStage.phase;
        return vinylStage.sequenceRunning || (ph !== "idle" && ph !== "playing" && ph !== "flipping");
    }
    // ...and the moment it is not, whatever is wanted is asked for: the stage
    // coming to rest IS the event, so nothing has to remember to ask again --
    // not the signal, not the cover, not the queue.
    //
    // A PLAIN PROPERTY, written from the stage's own signals, and deliberately
    // NOT a binding: `_step` starts a sequence, which changes the very things
    // the binding reads, and Qt calls that a loop ("Binding loop detected for
    // property _stageBusy") because it is one.
    property bool _stageBusy: false
    function _noteStage() {
        const busy = root._stageBusyNow();
        if (busy === root._stageBusy)
            return;
        root._stageBusy = busy;
        if (!busy && !stepAfter.running)
            root._step();
    }
    // Qt.callLater, not a direct call: `_step` starts and stops the very
    // animations `sequenceRunning` is made of, and doing that from inside its
    // own change notification is what Qt reports as a binding loop on it.
    // Deferring to the end of the pass costs nothing and coalesces the two
    // signals into one look.
    Connections {
        target: vinylStage
        function onPhaseChanged() {
            Qt.callLater(root._noteStage);
        }
        function onSequenceRunningChanged() {
            Qt.callLater(root._noteStage);
        }
    }

    function _syncPlatter() {
        if (!root.vinylEnabled)
            return;
        // Live, never through the bindings: this is called from three change
        // handlers, and two of them run before the bindings have caught up.
        const key = root._keyOf(root._sourceNow());

        // NOTHING IS PLAYING -- BUT NOT YET. A record is taken off for a fact
        // about the module's state, and a state that lasts one frame is not a
        // fact: a reply that loses a race, a queue being replaced, a service
        // reconnecting, all read as "nothing is playing" for an instant. So an
        // empty album waits `emptyGraceMs` and is re-asked, and only the TIMER
        // may confirm it.
        if (key === "" && !root._emptyConfirmed) {
            if (!root._emptyPending) {
                root._emptyPending = true;
                emptyGrace.restart();
            }
            return;
        }
        if (key !== "") {
            root._emptyPending = false;
            emptyGrace.stop();
        }
        root._wantKey = key;
        root._step();
    }

    // The only place a sequence is started, and it starts one only when the
    // stage is standing still.
    function _step() {
        if (!root.vinylEnabled || root._stageBusyNow())
            return;
        const key = root._wantKey;
        if (key === root._onPlatter)
            return;
        if (root._onPlatter !== "" && vinylStage.phase !== "idle") {
            // Take off what is on first. The record that is leaving keeps the
            // art it was wearing all the way into the sleeve.
            vinylStage.endSequence("");
            return;
        }
        root._onPlatter = "";
        if (key === "")
            return;                          // the platter stays empty
        // The cover is loaded BEFORE the record flies in: the label is the
        // whole point of the arrival. The preload's own handlers call back in
        // here when it lands.
        const cover = root._coverOf(root._sourceNow());
        if (!root._coverReady(cover))
            return;
        root._onPlatter = key;
        root._platterArt = cover;
        vinylStage.startSequence();
    }

    // ...and after every sequence, ask again. `settleMs` is the beat between an
    // arrival landing and a put-away that is already due starting: the record
    // has just been handed to the music and stopping it dead in the same frame
    // would be an abrupt stop.
    property int settleMs: 260
    Timer {
        id: stepAfter
        interval: root.settleMs
        repeat: false
        onTriggered: root._step()
    }

    // HOW FAR THROUGH THE ALBUM WE ARE, handed to the stage and nothing else.
    // The stage decides what to do with it: crossing the half turns the record
    // over, and the progress FALLING BACK -- repeat all wrapping to the first
    // song, a prev at the first song, a queue rebuilt in place -- turns it back.
    // The host arms nothing: "the album started over" is just this property
    // falling.
    readonly property real _albumProgress: root.player ? (root.player.albumProgress || 0) : 0

    // The library is fetched when it is first LOOKED at, not when the popup
    // opens: it is 38 albums and 28 artists off the daemon, and a player that
    // never opens the browse view should never pay for it. The service's own
    // flags decide whether the ask is a no-op.
    function _ensureLibrary() {
        if (!root.browsing || root.browsePanel !== "library" || !root.player)
            return;
        if (root.player.libraryLoaded || root.player.libraryLoading)
            return;
        root.player.loadLibrary();
    }
    onBrowsingChanged: root._ensureLibrary()
    onBrowsePanelChanged: root._ensureLibrary()

    // ---- the way between the panels ----------------------------------------------------------------
    // A panel keeps its own pages (PlayerPageStack: the library's, and the queue's song details). A JUMP is a page opened in the library from anywhere else: the queue's Show
    // album, the player card's links, a song page in the queue. The tab selector goes with it, and back goes back where it came from, the tab selector with it; `ret` says
    // where that is: the panel on show (with the row a page grew out of, the morph crosses from that panel and lands on that row), or the sidebar shut, or mini.
    //
    // The hand taking over ends it: a tab clicked or swiped, the burger, the view toggle (`_handTook`). The page stays where it is and its back is the library's own.
    function _jumpFrom() {
        const shown = root.browsing;
        if (shown && root.browsePanel === "library")
            return null;
        const panel = shown ? root.browsePanel : "";
        return { panel: panel, tab: root.browsePanel, browseOpen: root.browseOpen, viewMode: root.viewMode,
                 label: panel === "queue" ? "Queue" : panel === "data" ? "Data" : "Player" };
    }
    function _putBack(ret) {
        if (ret.panel !== "") {
            root.browsePanel = ret.tab;
            return;
        }
        // The sidebar's close is the motion: the page stays in it until it has gone.
        root._shutting = ret;
        root.viewMode = ret.viewMode;
        root.browseOpen = ret.browseOpen;
    }
    property var _shutting: null
    on_SidebarShownChanged: {
        if (root._sidebarShown || root._shutting === null)
            return;
        root.browsePanel = root._shutting.tab;
        root._shutting = null;
        libraryList.pages.dropTop();
    }
    function _handTook() {
        root._searchRet = null;
        libraryList.pages.forgetReturns();
    }
    function openAlbumPage(albumArtist, album, tile) {
        if (!root.player) return;
        const ret = root._jumpFrom();
        root._showLibrary();
        libraryList.openAlbumPage(albumArtist, album, tile, ret);
    }
    function openArtistPage(name, tile) {
        if (!root.player) return;
        const ret = root._jumpFrom();
        root._showLibrary();
        libraryList.openArtistPage(name, tile, ret);
    }
    // What a jump from the queue grows out of: a row of the list, or what stands on the song page on top of it.
    function _queueTile(songId) {
        return { get: () => queueList.tileOfSong(songId) };
    }
    function _queuePageTile(kind) {
        return { get: () => {
            const pg = queueList.pages.shownPage;
            const it = pg ? pg.tileOf(kind) : null;
            return it ? { item: it, w: it.width, h: it.height, color: root.listBoxColor, radius: 6, facts: null } : null;
        } };
    }
    // A song page's own buttons, in whichever panel it stands.
    function _songAction(action, song, onQueue) {
        if (!root.player) return;
        const who = song.albumArtist || song.artist;
        if (action === "next") {
            root._armAutoplay(false);
            root.player.playNextUri(song.file);
        } else if (action === "queue") {
            root._armAutoplay(false);
            root.player.appendUri(song.file);
        } else if (action === "album" || action === "artist") {
            // Asked from the page it was opened from, it is that page: back.
            if (!onQueue && libraryList.pages.underIs(action, who, action === "album" ? song.album : ""))
                libraryList.closePage();
            else if (action === "album")
                root.openAlbumPage(who, song.album, onQueue ? root._queuePageTile("album") : { where: "page", kind: "album", a: who, b: song.album });
            else
                root.openArtistPage(who, onQueue ? root._queuePageTile("artist") : { where: "page", kind: "artist", a: who, b: "" });
        }
    }
    readonly property string _crossing: libraryList.crossing
    on_CrossingChanged: {
        if (root._crossing === "queue")
            queueList.crossFocus = libraryList.pages.focusIn(queueList);
    }
    property var _queueMenuSong: null
    function _openQueueMenu(songId, sceneX, sceneY) {
        if (!root.player) return;
        const q = root.player.queue || [];
        let song = null;
        let pos = -1;
        for (let i = 0; i < q.length; i++)
            if (q[i].id === songId) { song = q[i]; pos = i; }
        if (!song) return;
        root._queueMenuSong = song;
        const here = root.player.songPos;
        const rows = [{ id: "play", label: "Play now" }];
        // "Play next" = move it to right after the song under the needle; nothing to do when it already is,
        // or when it IS that song.
        if (here >= 0 && pos !== here && pos !== here + 1) rows.push({ id: "next", label: "Play next" });
        rows.push({ id: "remove", label: "Remove from queue" });
        rows.push({ separator: true });
        rows.push({ id: "details", label: "Song details" });
        if (song.album) rows.push({ id: "album", label: "Show album" });
        if (song.albumArtist || song.artist) rows.push({ id: "artist", label: "Go to artist" });
        queueMenu.rows = rows;
        const p = overlayLayer.mapFromItem(null, sceneX, sceneY);
        queueMenu.openAt(p.x, p.y);
    }
    FloatingMenu {
        id: queueMenu
        overlayItem: overlayLayer
        fontFamily: root.fontFamily
        fontPixelSize: 12
        menuWidth: 176
        onTriggered: id => {
            const s = root._queueMenuSong;
            if (!s || !root.player) return;
            if (id === "play") root.player.playId(s.id);
            else if (id === "remove") root.player.removeId(s.id);
            else if (id === "next") {
                const q = root.player.queue || [];
                let from = -1;
                for (let i = 0; i < q.length; i++) if (q[i].id === s.id) from = i;
                // moving forward shifts the target down by one: the song lands right after the current one
                const to = from > root.player.songPos ? root.player.songPos + 1 : root.player.songPos;
                if (from >= 0) root.player.moveQueue(from, to);
            }
            else if (id === "details") queueList.openSongPage(s.file, s.id, { title: s.title, artist: s.artist, album: s.album });
            else if (id === "album") root.openAlbumPage(s.albumArtist || s.artist, s.album, root._queueTile(s.id));
            else if (id === "artist") root.openArtistPage(s.albumArtist || s.artist, root._queueTile(s.id));
        }
    }

    // The play button. It never waits for the record: a press is an answer to
    // the user, and an answer that arrives two seconds later is a broken button.
    function requestPlayPause() {
        if (!root.player)
            return;
        // A press takes over from a hold: the landing must not undo a pause made in the meantime.
        root._holdingForDrop = false;
        if (root.player.playing)
            root.player.pause();
        else
            root._requestPlay(false);
    }

    // The ONE place a play is asked for, and it never starts a sequence itself:
    // a play that called `startSequence` directly while `_syncPlatter` was still
    // waiting for the cover to load would run the arrival TWICE on a freshly
    // queued album -- once blank, holding the music, and again with the right
    // art once the cover landed. The arrival has exactly one caller, and a play
    // either goes straight through (the record is already down) or waits for
    // that arrival to finish.
    function _requestPlay(holdForDrop) {
        if (!root.player)
            return;
        // Down means THIS album's record: the one on the platter may be the album it replaces.
        const down = !root.vinylEnabled
            || ((vinylStage.phase === "playing" || vinylStage.phase === "flipping") && root._onPlatter === root._keyOf(root._sourceNow()));
        if (down || !holdForDrop || !root.holdPlaybackUntilDown) {
            root.player.play();
            return;
        }
        // Only an ARRIVAL is worth waiting for, and `_syncPlatter` is what
        // decides whether there is one. If it starts nothing -- the album is
        // already on the platter, the stage is simply idle -- there is nothing
        // to hold the music for, and holding it anyway would make the play
        // button do nothing at all: the flag is cleared by the arrival
        // FINISHING, so a hold with no arrival never ends.
        root._holdingForDrop = true;
        root._syncPlatter();
        // Nothing is coming: the album on the platter is already this one and
        // the stage is simply idle (the popup was built over a paused player,
        // say).
        //
        // "Coming" is the album not being on the platter yet -- NOT "a sequence
        // is running this instant": an arrival waits for its cover, and asking
        // one frame too early would drop the hold mid-flight.
        if (root._onPlatter === root._keyOf(root._sourceNow()) && !vinylStage.sequenceRunning) {
            root._holdingForDrop = false;
            root.player.play();
        }
    }

    // ======================================================================
    // LAYOUT
    // ======================================================================
    ColumnLayout {
        id: contentLayout
        anchors.fill: parent
        anchors.margins: root.padding
        spacing: root.padding

        // ----- the body: the card, and beside it the sidebar when it is open --
        RowLayout {
            id: body
            Layout.fillWidth: true
            // FILLS IN BOTH VIEWS. Filling only in the player would snap the
            // card's height to its mini target in one frame on the way into
            // mini while the popup's own height is still easing down -- and the
            // surplus would land as dead air at the foot of the column with
            // the transport row floating up under the card for the whole 260 ms.
            // Filling puts the card on the host's ease for free; at rest the
            // geometry is identical, because the popup's implicitHeight is
            // built from `targetHeight` in the first place.
            Layout.fillHeight: true
            spacing: root.bodyGap

            ColumnLayout {
                id: playerColumn
                Layout.fillHeight: true
                // ONE WIDTH RULE, ON THE HOST'S OWN CLOCK, and the column never
                // fills. The sidebar is the only thing that opens and closes, so
                // it is the only thing whose width moves: the popup grows to the
                // RIGHT and the record does not stir.
                //
                // A column that filled whenever the sidebar was shut would take
                // the whole of the popup's still-wide row the instant the
                // sidebar was hidden -- the record and the buttons stretched --
                // and then shrink back as the popup's own width eases down.
                // A fixed player width avoids that double move, but mini is a
                // NARROWER popup than the player, and a column that insists on
                // the player's width there hangs 68 px past the popup's own
                // edge (the burger and the card's right side outside it).
                // Filling in mini and standing fixed in the player changes the
                // rule in the same frame the view flag flips, while the popup's
                // width is still the OTHER view's: leaving a sidebar behind, the
                // column takes the whole 1016 px row for a frame before easing
                // back to 456 (a very wide vinyl container). Interpolating
                // between the two resting widths on `_switchF` cannot do that,
                // because the fraction is read off the size the host has
                // actually given us.
                //
                // No minimum, so a popup that is momentarily narrower than the
                // layout's parts deforms instead of overflowing to the right.
                Layout.fillWidth: false
                Layout.preferredWidth: root._lerp(root.playerWidth, root.miniWidth,
                                                  root._switchF) - root.padding * 2
                Layout.minimumWidth: 0
                spacing: root.padding

                // ===== the card: the record, what is playing, the viewfinder ==
                ShadowBox {
                    id: card
                    Layout.fillWidth: true
                    // See `body` above: the card rides the host's ease in both
                    // views. `targetHeight` stays the unanimated DESTINATION
                    // that `implicitHeight` is built from -- easing that one
                    // would animate the popup's own implicit size, which the
                    // host is already easing, and two clocks on one number is
                    // the mistake this shell keeps deleting.
                    Layout.fillHeight: true
                    Layout.preferredHeight: -1

                    baseRadius: root._cardRadius
                    surfaceColor: root.surfaceColor
                    bevelColor: root.bevelColor
                    shadowColor: root.borderColor
                    backgroundColor: root.listBoxColor
                    bevelWidth: 1
                    shadowWidth: 3

                    // What the card WANTS to be in mini, unanimated -- the
                    // popup's own implicitHeight is built from it, so it must
                    // be the destination and not the eased value.
                    readonly property real targetHeight: root.compact ? root.cardPadding * 2 + Math.max(root.miniVinylSize, infoBlock.implicitHeight + root.railGap + viewfinder.implicitHeight) : 0

                    // Everything inside is clipped exactly at the card's edge,
                    // not inset from it: the record bleeds to the edge and the
                    // rail's particles fade there rather than being cut.
                    Item {
                        id: cardClip
                        anchors.fill: parent
                        clip: true

                        // ---- the record ----------------------------------
                        // Placed by binding rather than by two layouts: mini
                        // and player are the same three children in different
                        // places, and a second subtree would rebuild them both
                        // on every switch.
                        VinylStage {
                            id: vinylStage
                            // THE STAGE IS THE CARD. The record's shadow is
                            // drawn inside the stage's own item, so whatever
                            // the stage does not cover is a line the shadow is
                            // cut on: the render canvas is fitted to the
                            // CONTAINER and runs to the card's own edge in both
                            // views, so the only thing that cuts the shadow is
                            // the card.
                            //
                            // The stage does not imply where the record is, it
                            // is TOLD (`recordCenterX` / `recordCenterY`).
                            x: 0
                            y: 0
                            width: card.width
                            height: card.height
                            // OVER THE INFO BLOCK WHILE THE RECORD IS MOVING OR NOTHING
                            // IS PLAYING. The stage is declared first, so at rest the
                            // block (title, figures) is above it -- and the sleeve that
                            // comes in from the right when an album has run out, which
                            // is part of the stage, would slide UNDER the skeleton the
                            // block draws for "nothing playing". The two never overlap at rest, so the
                            // stage only takes the top while a sequence runs or there is
                            // no song to put words on; mid-switch the block is already
                            // at -1, below either.
                            z: (vinylStage.sequenceRunning || !root._hasSong) ? 1 : 0
                            // Both centres on the same fraction as the size,
                            // so the record shrinks WHILE it travels to where it
                            // is going, instead of arriving there in one frame.
                            recordCenterX: root._lerp(card.width / 2,
                                                      root.cardPadding + root.miniVinylSize / 2,
                                                      root._switchF)
                            recordCenterY: root._lerp(root.cardPadding + root._discSize / 2,
                                                      card.height / 2,
                                                      root._switchF)

                            // The record's own size, given rather than derived:
                            // the stage is not the record's box.
                            discSize: root._discSize
                            // Which of the stage's two record fractions applies.
                            compact: root._pastHalf
                            // ...and how far between them, so the record's own
                            // fraction rides the switch with its size.
                            compactF: root._switchF
                            visible: root.vinylEnabled

                            // What the RECORD is wearing, not what is playing:
                            // a cleared queue must still put away the record it
                            // was playing, with its own cover on it.
                            albumArt: root._platterArt
                            // The platter stands under the record, and stands
                            // alone when there is nothing on it -- which is
                            // what fills the card when the queue is empty.
                            showTurntable: root.vinylEnabled
                            platterSurfaceColor: root.listBoxColor
                            playing: root._playing
                            // The record's angle IS the position -- and while
                            // the viewfinder is being dragged, the position is
                            // the ball's, so scrubbing turns the record.
                            // How far through the album, which is what decides
                            // when the record is turned over -- and, when it
                            // falls back, turned over again.
                            albumProgress: root._albumProgress
                            positionSec: viewfinder.dragging ? viewfinder.displayPosition : root._position
                            // A hand on the ball TURNS the record, at the
                            // scrub's own ratio; anything else that moves the
                            // playhead is carried. The stage cannot tell the
                            // two apart from the position alone, so this is the
                            // difference, and it is the drag itself.
                            scrubbing: viewfinder.dragging
                            durationSec: root._duration

                            onSequenceFinished: which => {
                                // The record that landed may be one the album it holds for has already replaced:
                                // the hold goes on to the record that is on its way (`_step`).
                                const wanted = which === "start" ? root._keyOf(root._sourceNow()) : "";
                                if (which === "start" && root._holdingForDrop && (wanted === root._onPlatter || wanted === "")) {
                                    root._holdingForDrop = false;
                                    if (root.player && wanted !== "")
                                        root.player.play();
                                }
                                if (which === "end")
                                    root._onPlatter = "";
                                // WHATEVER IS WANTED NOW. Four skips may have
                                // gone by while this ran, so the next sequence
                                // is decided when the stage comes to rest, from
                                // the album that is wanted THEN -- see
                                // `_noteStage`. The one thing decided
                                // here is the BEAT after an arrival: a put-away
                                // that is already due must not stop the record
                                // dead in the frame it was handed the music in.
                                if (which === "start")
                                    stepAfter.restart();
                            }
                        }

                        // ---- what is playing ------------------------------
                        PlayerTrackInfo {
                            id: infoBlock
                            // Travels with the record rather than teleporting
                            // beside it, and is pushed by the record instead of
                            // the record being what is left over.
                            x: root._infoX
                            y: root._lerp(root.cardPadding * 2 + root._discSize,
                                          root.cardPadding, root._switchF)
                            width: card.width - infoBlock.x - root.cardPadding
                            // In mini the block is given the whole space down
                            // to the viewfinder, so `figuresAtBottom` has room
                            // to push the figures against it. It reads its own
                            // implicit height, never the height it is given,
                            // so this cannot loop.
                            height: root._lerp(infoBlock.implicitHeight,
                                               Math.max(infoBlock.implicitHeight, viewfinder.y - root.railGap - infoBlock.y),
                                               root._switchF)
                            // BEHIND THE RECORD WHILE THE TWO CROSS. The block
                            // travels from under the record to beside it, and
                            // the record from the centre to the left, so their
                            // paths cross -- and white text over a dark disc is
                            // the most visible thing in the whole switch. At
                            // rest they never overlap; mid-switch the record
                            // covers the text instead of the text covering the
                            // record.
                            z: root._midSwitch ? -1 : 0

                            title: root._cur ? (root._cur.title || "") : ""
                            artist: root._cur ? (root._cur.artist || "") : ""
                            album: root._cur ? (root._cur.album || "") : ""
                            // What is playing is a way in: its artist's page, its album's.
                            onArtistClicked: if (root._cur) root.openArtistPage(root._cur.albumArtist || root._cur.artist || "")
                            onAlbumClicked: if (root._cur) root.openAlbumPage(root._cur.albumArtist || root._cur.artist || "", root._cur.album || "")
                            position: viewfinder.dragging ? viewfinder.displayPosition : root._position
                            duration: root._duration
                            fidelity: root.player ? root.player.fidelity : null
                            compact: root._pastHalf
                            compactF: root._switchF
                            // Nothing playing: a static skeleton of what would
                            // be there, rather than an empty card.
                            empty: !root._hasSong
                            // In mini the figures are pinned to the block's
                            // foot, so they sit against the viewfinder and the
                            // blank space falls above them instead.
                            figuresAtBottom: root._pastHalf
                            figuresAtBottomF: root._switchF
                            // ONE owner for the distance between the figures
                            // and the rail, and it is the popup's `railGap`.
                            // The block keeps its own room below the figures by
                            // default, and both at 12 would measure 24.
                            figuresBottomGap: 0
                            fontFamily: root.fontFamily

                            textColor: root.primaryText
                            mutedColor: root.mutedText
                            faintColor: root.faintText
                            accentColor: root.accent
                            surfaceColor: root.listBoxColor
                            bevelColor: root.bevelColor
                            borderColor: root.borderColor
                        }

                        // ---- the viewfinder -------------------------------
                        // Glued to the card's foot, never laid out under
                        // content that changes height: anchored to the edge it
                        // moves exactly as the edge moves.
                        PlayerViewfinder {
                            id: viewfinder
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            // THE RAIL'S OUTER EDGE lines up with the figures
                            // above it -- the left of the left slot under the
                            // left of the elapsed time, the right of the right
                            // slot under the right of the total. That is
                            // `endSlotInset` (13.5 px here) and NOT
                            // `grooveInset` (20), which is the slot's CENTRE:
                            // hanging the item out by the centre would leave
                            // the slot's half-circle sticking out past the
                            // figures.
                            // The same left edge the title block has, so the
                            // rail shrinks in from the left with the record
                            // arriving beside it rather than snapping across.
                            anchors.leftMargin: root._infoX - viewfinder.endSlotInset
                            anchors.rightMargin: root.cardPadding - viewfinder.endSlotInset
                            anchors.bottomMargin: root.cardPadding
                            height: implicitHeight

                            position: root._position
                            duration: root._duration
                            playing: root._playing
                            seekable: root._hasSong
                            // The ball belongs to a track: with the skeleton up
                            // there is nothing for it to sit on, so it goes --
                            // the same flag the info block draws its skeleton
                            // from, never a second one.
                            ballVisible: root._hasSong
                            particlesEnabled: root.railParticles
                            loudness: root.levelTapEnabled ? levelTap.level : root.loudness
                            // A beat is an EVENT, not a level: it arrives as a
                            // counter so a burst cannot be missed between two
                            // samples or thrown twice for one hit.
                            beatSeq: root.levelTapEnabled ? levelTap.beatSeq : 0
                            beatStrength: root.levelTapEnabled ? levelTap.beatStrength : 0

                            accentColor: root.accent
                            surfaceColor: root.listBoxColor
                            grooveColor: root.panelColor
                            grooveBevelColor: root.bevelColor
                            grooveShadowColor: root.borderColor
                            ballShadowColor: root.ballShadowColor

                            // The distance from the rail's own edge to the
                            // card's clip, SIGNED. The rail hangs 8 px
                            // outside the clip on each side so its groove lines
                            // up with the figures, which makes these negative --
                            // the fade's zero line belongs 8 px INSIDE the rail,
                            // where the clip actually is. Clamped to 0 the zero
                            // line would sit at the rail's edge and the sparks
                            // would be cut hard at the clip instead of fading
                            // into it.
                            particleEdgeLeft: viewfinder.anchors.leftMargin
                            particleEdgeRight: viewfinder.anchors.rightMargin
                            particleEdgeTop: viewfinder.y
                            particleEdgeBottom: cardClip.height - viewfinder.y - viewfinder.height

                            onSeekRequested: seconds => {
                                if (root.player)
                                    root.player.seek(seconds);
                            }
                        }

                        // ---- what is wrong with the sound ---------------------------
                        // Over the head of the card, above everything (the record keeps
                        // its place; an error is worth covering it for). The service
                        // decides what to say (MpdHealth); this only shows it, and a
                        // player without the check (the mock) has no `health` and shows
                        // nothing.
                        PlayerHealthBanner {
                            id: healthBanner
                            z: 100
                            x: root.cardPadding
                            y: root.cardPadding
                            width: Math.max(0, cardClip.width - root.cardPadding * 2)
                            health: root.player && root.player.health !== undefined ? root.player.health : null
                            fontFamily: root.fontFamily
                            surfaceColor: root.listBoxColor
                            bevelColor: root.bevelColor
                            borderColor: root.borderColor
                            textColor: root.primaryText
                            mutedColor: root.mutedText
                            faintColor: root.faintText
                            accentColor: root.accent
                            buttonPlateauColor: root.buttonPlateauColor
                            buttonPlateauHoverColor: root.buttonPlateauHoverColor
                            buttonBevelColor: root.buttonBevelColor
                            buttonShadowColor: root.buttonShadowColor
                            radius: root._cardRadius - 4
                            onActionRequested: id => {
                                if (root.player) root.player.healthRun(id);
                            }
                            onCheckRequested: {
                                if (root.player) root.player.healthCheck();
                            }
                            onDismissRequested: {
                                if (root.player) root.player.healthDismiss();
                            }
                        }

                        // The record throws no sparks of its own: they nearly
                        // doubled the popup's GPU for a second after every drop.
                        // The rail's sparks and the sidebar's queueing burst are
                        // the popup's only ones.
                    }
                }
            }

            // ===== the sidebar, in browse only =====================
            // One Item that holds both panels; the one that is not shown is
            // not visible, but neither subtree is destroyed -- rebuilding a
            // list of 500 rows inside a property change is 60+ ms of blocked
            // frames.
            Item {
                id: panelHost
                Layout.fillHeight: true
                Layout.fillWidth: true
                // THE CELL IS GROWN BY THE BEVEL'S SLACK, AND THE PANELS STAND IN IT.
                // The panels' carved boxes (the grouping selector, the list's box) stand
                // flush with the cell on its top, right and left, and a ShadowBox draws
                // its bevel OUTSIDE its own rect: the cell's clip on the same line
                // scissors the whole band -- the shadow is cut off across the top and
                // right edge of the corner (the pixel row above the selector is the plain
                // surface, the row under it carries the bevel). So the cell
                // takes `_slack` more on every side (a negative layout margin: the popup's
                // padding is there to be overlapped) and each panel is inset by the same,
                // which leaves every panel exactly where it would stand without the slack
                // and gives the clip room for the band -- 2 px for bevelWidth 1, as the
                // composer's `_chipSlack`. The reveal's moving edge is the cell's own, and
                // the host clips the popup besides.
                //
                // THE SLACK IS WHAT THE PANELS SAY THEY PAINT OUTSIDE THEMSELVES (`bleed`), not a
                // number written here: the grouping selector's carved track lays 1.5 + 1 px (3 whole
                // pixels) and the Clear / All button's drop shadow 5 + 1, so a fixed 2 would scissor
                // the band's last pixel at a scale of 1.25 and the button's shadow outright. A panel
                // that grows its own paint raises it by itself.
                readonly property real _slack: Math.max(queueList.bleed, libraryList.bleed, dataPanel.bleed)
                Layout.margins: -panelHost._slack
                clip: true

                // REVEALED, NOT SQUISHED. The panels stand at the sidebar's
                // resting width, anchored to the cell's left edge, and the
                // cell's clip uncovers them as the container widens -- and
                // covers them again as it narrows. Scaling them on x to fit
                // whatever width the cell has would read as lagging behind in
                // taking up the freed up space: a panel compressed to half its
                // width does not look like a panel that is there yet. A reveal
                // does. Nothing overflows the popup either way: the cell clips,
                // and the real host clips its content besides.
                // NO FLOOR. With one, the sum of the layout's minimums --
                // 260 for the player's column, 200 here, the gap and the
                // padding -- comes to 494 inside a popup that is 480 wide for
                // the first frames of mini -> player, and Qt Quick Layouts
                // answer an impossible row by clamping at the minimum and
                // overflowing to the RIGHT. That is the sidebar hanging outside
                // the popup's rounded edge. Deforming is the honest answer.
                Layout.minimumWidth: 0
                visible: root._sidebarShown
                opacity: root._sidebarOpacity

                PlayerQueue {
                    id: queueList
                    // At the sidebar's RESTING width, whatever the cell is:
                    // the cell's clip reveals and covers it. See `panelHost`.
                    x: panelHost._slack
                    y: panelHost._slack
                    width: root.browsePanelWidth
                    height: panelHost.height - panelHost._slack * 2
                    // Under a page crossing from or to the library it recedes as the list under a page does.
                    visible: root.browsePanel === "queue" || root._crossing === "queue"
                    opacity: root._crossing === "queue" ? libraryList.pages.crossRecede : 1
                    crossZoom: root._crossing === "queue" ? libraryList.pages.crossZoom : 1
                    player: root.player
                    onSongActionRequested: (action, song) => root._songAction(action, song, true)
                    songs: root.player ? root.player.queue : []
                    currentId: root.player ? root.player.songId : -1
                    playing: root._playing
                    containerRadius: root._cardRadius
                    // The sidebar's layout for as long as the panel is SHOWN,
                    // not for as long as browsing is true: on the way into mini
                    // the flag drops on the first frame and the panel would re-lay
                    // itself out inside a sidebar that is still sliding away.
                    compact: root._sidebarShown
                    fontFamily: root.fontFamily
                    flightOverlay: overlayLayer

                    listBoxColor: root.listBoxColor
                    headerBoxColor: root.headerBoxColor
                    surfaceColor: root.surfaceColor
                    bevelColor: root.bevelColor
                    borderColor: root.borderColor
                    textColor: root.primaryText
                    mutedColor: root.mutedText
                    faintColor: root.faintText
                    accentColor: root.accent

                    onPlayRequested: id => {
                        if (root.player)
                            root.player.playId(id);
                    }
                    onRemoveRequested: id => {
                        if (root.player)
                            root.player.removeId(id);
                    }
                    onMoveRequested: (from, to) => {
                        if (root.player)
                            root.player.moveQueue(from, to);
                    }
                    onClearRequested: {
                        if (root.player)
                            root.player.clearQueue();
                    }
                    onMenuRequested: (songId, sx, sy) => root._openQueueMenu(songId, sx, sy)
                }

                PlayerLibrary {
                    id: libraryList
                    // At the sidebar's RESTING width, whatever the cell is:
                    // the cell's clip reveals and covers it. See `panelHost`.
                    x: panelHost._slack
                    y: panelHost._slack
                    width: root.browsePanelWidth
                    height: panelHost.height - panelHost._slack * 2
                    visible: root.browsePanel === "library" || root._crossing !== ""
                    z: root._crossing !== "" ? 1 : 0
                    coversEnabled: root._coversOpen
                    menuOverlay: overlayLayer
                    player: root.player
                    onSongActionRequested: (action, song) => root._songAction(action, song, false)
                    onReturnTaken: ret => root._putBack(ret)
                    // What the body comes to when the host has landed: read before it has, this is the list's fold
                    // (PlayerLibrary, THE FOLD). With the sidebar shut the panel has no height, and that is the answer.
                    restingHeight: root.browsing ? root.implicitHeight - root._chromeHeight : -1
                    albums: root.player ? root.player.albums : []
                    artists: root.player ? root.player.artists : []
                    genres: root.player ? root.player.genres : []
                    recent: root.player ? root.player.recent : []
                    playlists: root.player ? root.player.playlists : []
                    loading: root.player ? root.player.libraryLoading : false
                    // Whether the artists shelf holds only the artists with a
                    // full album or every artist the library knows. The panel
                    // asks; the service answers, and the shelf is rebuilt from
                    // the answer -- so this is a BINDING, never a write.
                    artistsIncludeLoose: root.player && root.player.artistsIncludeLoose === true
                    grouping: root.libraryGrouping
                    startSort: root.librarySort
                    startAscending: root.libraryAscending
                    // The song under the needle, so a row seen while browsing
                    // wears the same mark the queue gives it -- and drains it
                    // the same way while paused.
                    currentFile: root._cur ? root._cur.file : ""
                    playing: root._playing
                    containerRadius: root._cardRadius
                    // Its grouping selector and the button beside it sit over
                    // the container's own top corners, so they take the
                    // container's radius rather than a stadium of their own.
                    tabRadius: root._cardRadius
                    // The sidebar's layout for as long as the panel is SHOWN,
                    // not for as long as browsing is true: on the way into mini
                    // the flag drops on the first frame and the panel would re-lay
                    // itself out inside a sidebar that is still sliding away.
                    compact: root._sidebarShown
                    fontFamily: root.fontFamily

                    listBoxColor: root.listBoxColor
                    headerBoxColor: root.headerBoxColor
                    surfaceColor: root.surfaceColor
                    bevelColor: root.bevelColor
                    borderColor: root.borderColor
                    textColor: root.primaryText
                    mutedColor: root.mutedText
                    faintColor: root.faintText
                    accentColor: root.accent
                    accentHoverColor: root.accentHover

                    onPlayAlbumRequested: (albumArtist, album) => root._playAlbum(albumArtist, album)
                    onQueueAlbumRequested: (albumArtist, album) => {
                        if (root.player) {
                            root._armAutoplay(true);
                            root.player.appendAlbum(albumArtist, album);
                        }
                    }
                    // A left click on a song's row: heard now. Not `playNextUri`
                    // + `next()`: with nothing playing `next` is refused, so the
                    // song would be queued and the record brought in with no
                    // music -- see `MpdService.playUriNow`.
                    onPlaySongRequested: uri => {
                        if (root.player)
                            root.player.playUriNow(uri);
                    }
                    onQueueSongRequested: uri => {
                        if (root.player) {
                            root._armAutoplay(false);
                            root.player.appendUri(uri);
                        }
                    }
                    // A whole group queued from its header: a genre, a
                    // playlist, an artist. The service knows how to append each
                    // one; the panel only says which.
                    onQueueGroupRequested: (kind, key) => {
                        if (!root.player)
                            return;
                        root._armAutoplay(false);
                        if (kind === "genre")
                            root.player.appendGenre(key);
                        else if (kind === "playlist")
                            root.player.appendPlaylist(key);
                        else if (kind === "artist")
                            root.player.songsOfArtist(key, songs => {
                                for (let i = 0; i < songs.length; ++i)
                                    root.player.appendUri(songs[i].file);
                            });
                    }
                    onClearRecentRequested: {
                        if (root.player)
                            root.player.clearRecent();
                    }
                    // A menu pick that has no older signal: play an artist / genre / list, PLAY NEXT.
                    onActionRequested: (action, kind, a, b) => {
                        if (!root.player)
                            return;
                        if (action === "play") {
                            if (kind === "artist") root.player.playArtist(a);
                            else if (kind === "genre") root.player.playGenre(a);
                            else if (kind === "playlist") root.player.playPlaylist(a);
                        } else if (action === "next") {
                            root._armAutoplay(kind === "album");
                            if (kind === "album") root.player.playNextAlbum(a, b);
                            else if (kind === "artist") root.player.playNextArtist(a);
                            else if (kind === "song") root.player.playNextUri(a);
                        }
                    }
                    onAlbumPageRequested: (albumArtist, album) => {
                        if (root.player)
                            root.player.albumInfo(albumArtist, album, info => libraryList.showAlbumPage(albumArtist, album, info));
                    }
                    onSearchRequested: q => {
                        if (root.player && q !== "")
                            root.player.searchSongs(q, songs => libraryList.setSearchSongs(q, songs));
                    }
                    onArtistScopeToggled: includeLoose => {
                        if (root.player)
                            root.player.artistsIncludeLoose = includeLoose;
                    }
                    onRemoveRecentRequested: (kind, key) => {
                        if (root.player)
                            root.player.removeRecent(kind, key);
                    }
                    // The burst that answers a right click. Drawn from the
                    // popup's overlay, because a list clips and an
                    // acknowledgement cut off by the row it came from reads as
                    // a glitch.
                    onQueuedFeedback: (sceneX, sceneY, what) => root._queuedFeedback(sceneX, sceneY, what)

                    onExpandRequested: (kind, key) => {
                        if (!root.player)
                            return;
                        if (kind === "album") {
                            // An album takes two names to identify, so its key
                            // is both of them joined by the panel's own
                            // separator -- the unit separator, which no tag can
                            // contain. The panel owns that character; this
                            // reads it back rather than assuming one.
                            const parts = key.split(libraryList.keySeparator);
                            root.player.songsOfAlbum(parts[0], parts[1], songs => libraryList.setSongs(kind, key, songs));
                        } else if (kind === "artist") {
                            root.player.songsOfArtist(key, songs => libraryList.setSongs(kind, key, songs));
                        } else if (kind === "genre") {
                            // A genre is a level of ALBUMS, not of songs:
                            // expanding one lists its albums, and expanding an
                            // album inside it lists that album's songs.
                            root.player.albumsOfGenre(key, albums => libraryList.setAlbums(key, albums));
                        } else if (kind === "playlist") {
                            root.player.songsOfPlaylist(key, songs => libraryList.setSongs(kind, key, songs));
                        }
                    }
                }

                // The file's own words about what is playing: the lyrics
                // first, because that is what this tab is opened for, and the
                // rest of the tags under them. It answers about the queue's
                // head when nothing is playing -- its own rule, so the host
                // hands it the two plain properties and nothing else.
                PlayerData {
                    id: dataPanel
                    // At the sidebar's RESTING width, whatever the cell is:
                    // the cell's clip reveals and covers it. See `panelHost`.
                    x: panelHost._slack
                    y: panelHost._slack
                    width: root.browsePanelWidth
                    height: panelHost.height - panelHost._slack * 2
                    visible: root.browsePanel === "data" || root._crossing === "data"
                    opacity: root._crossing === "data" ? libraryList.pages.crossRecede : 1
                    // Nothing is read for a tab nobody has open.
                    active: root.browsing && root.browsePanel === "data"
                    song: root._cur
                    queue: root.player ? root.player.queue : []
                    playing: root._playing
                    position: viewfinder.dragging ? viewfinder.displayPosition : root._position
                    musicDir: root.player && root.player.musicDir ? root.player.musicDir : ""
                    containerRadius: root._cardRadius
                    // The sidebar's layout for as long as the panel is SHOWN,
                    // not for as long as browsing is true: on the way into mini
                    // the flag drops on the first frame and the panel would re-lay
                    // itself out inside a sidebar that is still sliding away.
                    compact: root._sidebarShown
                    fontFamily: root.fontFamily

                    listBoxColor: root.listBoxColor
                    headerBoxColor: root.headerBoxColor
                    surfaceColor: root.surfaceColor
                    bevelColor: root.bevelColor
                    borderColor: root.borderColor
                    textColor: root.primaryText
                    mutedColor: root.mutedText
                    faintColor: root.faintText
                    accentColor: root.accent

                    onSeekRequested: sec => {
                        if (root.player)
                            root.player.seek(sec);
                    }
                }
            }
        }

        // ----- the bottom row: the transport, and the sidebar's own selector --
        // One row, so every container's foot lines up: the card and the list
        // box end together above it, and the selector sits level with the
        // transport rather than stacked over the list.
        RowLayout {
            id: bottomRow
            Layout.fillWidth: true
            // Exactly the transport's height and no more. Without the maximum
            // the row grows to swallow the space the card should have: the
            // card ends 180 px short and the transport floats under it.
            Layout.fillHeight: false
            Layout.preferredHeight: root.transportHeight
            Layout.minimumHeight: root.transportHeight
            Layout.maximumHeight: root.transportHeight
            spacing: root.bodyGap

            Item {
                id: transportCell
                Layout.fillHeight: true
                // The same width rule the card above it uses, so the two are
                // the same column. See `playerColumn`.
                Layout.fillWidth: false
                Layout.preferredWidth: root._lerp(root.playerWidth, root.miniWidth,
                                                  root._switchF) - root.padding * 2
                Layout.minimumWidth: 0

                PlayerTransport {
                    id: transportRow
                    // A TIP DOES NOT SURVIVE A VIEW SWITCH. `HoverTip` only
                    // closes when its `show` goes false, and `show` is
                    // `tipsEnabled && hovered` -- the pointer is still on the
                    // button that was just pressed, so `hovered` never changes
                    // and the bubble would sit there through the whole
                    // transition.
                    // This is the one property all three tips have in common.
                    tipsEnabled: !root._switching
                    // ANCHORED, not laid out: its parent is a plain Item in the
                    // bottom row's layout, and a Layout attached property on a
                    // child of an Item does nothing at all -- it would draw at
                    // its own implicit size in the corner of a cell that grows
                    // to fill the popup.
                    anchors.fill: parent

                    playing: root._playing
                    // Shuffle is the queue's ORDER, not MPD's random mode: the
                    // spec asks for a shuffle that spaces artists and albums
                    // out, and MPD's random would pick its own order over the
                    // top of that. The mode latches, and while it is on
                    // anything added to the queue is shuffled in.
                    shuffleOn: root.player ? root.player.shuffleMode : false
                    repeatMode: root.player ? (root.player.singleOn && root.player.repeatOn ? "one" : (root.player.repeatOn ? "all" : "off")) : "off"
                    browseOpen: root.browsing
                    miniView: root._pastHalf
                    showViewToggle: root.allowModeSwitch
                    fontFamily: root.fontFamily
                    overlayItem: overlayLayer

                    surfaceColor: root.surfaceColor
                    plateauColor: root.buttonPlateauColor
                    plateauHoverColor: root.buttonPlateauHoverColor
                    bevelColor: root.buttonBevelColor
                    shadowColor: root.buttonShadowColor
                    accentColor: root.accent
                    accentHoverColor: root.accentHover
                    accentBevelColor: root.accentBevel
                    textColor: root.primaryText
                    mutedColor: root.mutedText
                    textOnAccentColor: root.textOnAccent

                    onPlayPauseRequested: root.requestPlayPause()
                    onNextRequested: if (root.player)
                        root.player.next()
                    onPrevRequested: if (root.player)
                        root.player.prev()
                    onShuffleToggled: if (root.player)
                        root.player.setShuffleMode(!root.player.shuffleMode)
                    onRepeatCycled: {
                        if (!root.player)
                            return;
                        // off -> all -> one -> off
                        if (!root.player.repeatOn) {
                            root.player.setRepeat(true);
                            root.player.setSingle(false);
                        } else if (!root.player.singleOn) {
                            root.player.setSingle(true);
                        } else {
                            root.player.setRepeat(false);
                            root.player.setSingle(false);
                        }
                    }
                    // The burger is the sidebar. Pressed in mini it opens
                    // the player WITH the sidebar rather than refusing: a
                    // button that is visible should do the thing it names.
                    onBrowseToggled: {
                        root._handTook();
                        if (root.compact) {
                            root.viewMode = "player";
                            root.browseOpen = true;
                        } else {
                            root.browseOpen = !root.browseOpen;
                        }
                    }
                    onViewToggleRequested: {
                        root._handTook();
                        root.viewMode = root.compact ? "player" : "mini";
                    }
                }
            }

            Item {
                id: selectorCell
                Layout.fillHeight: true
                Layout.fillWidth: true
                // NO FLOOR. With one, the sum of the layout's minimums --
                // 260 for the player's column, 200 here, the gap and the
                // padding -- comes to 494 inside a popup that is 480 wide for
                // the first frames of mini -> player, and Qt Quick Layouts
                // answer an impossible row by clamping at the minimum and
                // overflowing to the RIGHT. That is the sidebar hanging outside
                // the popup's rounded edge. Deforming is the honest answer.
                Layout.minimumWidth: 0
                visible: root._sidebarShown
                opacity: root._sidebarOpacity
                clip: true

                    TabSelector {
                        id: panelTabs
                        // Its resting width ALWAYS, revealed by the cell's clip
                        // rather than squeezed to the cell: squeezed, its three
                        // labels overran their slots into each other. Centred
                        // when the cell has room, and pinned to the cell's left
                        // edge when it has not, so the reveal grows from the
                        // side the cell grows from.
                        x: Math.max(0, (parent.width - width) / 2)
                        y: (parent.height - height) / 2
                        width: root.panelTabWidth
                        height: Math.min(root.panelTabHeight, parent.height)
                        tabs: [
                            {
                                id: "queue",
                                label: "queue"
                            },
                            {
                                id: "library",
                                label: "library"
                            },
                            {
                                id: "data",
                                label: "data"
                            }
                        ]
                        onTabChanged: id => {
                            root._handTook();
                            root.browsePanel = id;
                        }
                        // A right click on the ACTIVE library tab rescans the library. Nothing announces
                        // it but the pointer; the tab's own ink says it is running (`rescanSign`).
                        onTabSecondaryClicked: id => root.rescanFromTab(id)
                        // Its own defaults are eva-light literals no host ever
                        // passed; the popup's palette is what it must wear.
                        trackSurfaceColor: root.surfaceColor
                        trackBevelColor: root.borderColor
                        trackShadowColor: root.shadowDeepColor
                        trackBackgroundColor: root.panelColor
                        pillSurfaceColor: root.panelColor
                        pillBevelColor: root.accentBevel
                        pillShadowColor: root.buttonShadowColor
                        pillBackgroundColor: root.accent
                        textColor: root.primaryText
                        activeTextColor: root.textOnAccent
                        fontFamily: root.fontFamily
                        fontPixelSize: 11
                        // The popup takes no horizontal wheel events for
                        // itself, so this selector has them (its default): a
                        // swipe over the sidebar is a swipe of the sidebar.
                    }

                    // The selector tells the truth about every jump, and writes its own currentTab on a click, which would cut a plain binding for good
                    // (CLAUDE.md): without the Binding the queue's Show album would leave the pill on "queue" over the library.
                    Binding {
                        target: panelTabs
                        property: "currentTab"
                        value: root.browsePanel
                    }

                    // THE SIGN THAT A RESCAN RUNS: the library tab's pill breathes -- the tab's own ink, no new
                    // glyph. It runs while mpd says it is walking the library (`player.updating`) and for at
                    // least one breath after the click, so a rescan of a library that is already known
                    // (a few milliseconds) is still seen to have been taken. The loop finishes the breath it is
                    // in when the rescan ends, so it never stops on a half-lit pill, and it stands still
                    // while the theme crossfades (a crossfade is a still picture).
                    Rectangle {
                        id: rescanSign
                        readonly property bool wanted: root.browsePanel === "library"
                            && (rescanHold.running || (root.player !== null && root.player.updating === true))
                        readonly property real slot: panelTabs.width / Math.max(1, panelTabs.tabs.length)
                        x: panelTabs.x + panelTabs._currentIdx * rescanSign.slot + panelTabs.pillInset
                        y: panelTabs.y + panelTabs.pillInset
                        width: Math.max(0, rescanSign.slot - panelTabs.pillInset * 2)
                        height: Math.max(0, panelTabs.height - panelTabs.pillInset * 2)
                        radius: panelTabs._pillRadius
                        color: root.textOnAccent
                        opacity: 0
                        visible: breath.running
                        SequentialAnimation {
                            id: breath
                            running: rescanSign.wanted
                            loops: Animation.Infinite
                            alwaysRunToEnd: true
                            paused: running && Theme.crossfading
                            NumberAnimation { target: rescanSign; property: "opacity"; from: 0; to: 0.3; duration: 420; easing.type: Easing.InOutSine }
                            NumberAnimation { target: rescanSign; property: "opacity"; from: 0.3; to: 0; duration: 420; easing.type: Easing.InOutSine }
                        }
                    }
                    Timer {
                        id: rescanHold
                        interval: 840
                        repeat: false
                    }
            }
        }
    }

    // A secondary press on a sidebar tab. Only the library tab, only while it is the one open: a right click on
    // a tab that is not showing would rescan something the user is not looking at.
    function rescanFromTab(id) {
        if (id !== "library" || root.browsePanel !== "library") return;
        if (root.player === null || typeof root.player.rescanLibrary !== "function") return;
        rescanHold.restart();
        root.player.rescanLibrary();
    }

    // Measures MPD's own stream, so the viewfinder's sparks follow the music
    // rather than the clock. Only while something is actually playing: a paused
    // player has nothing to measure and a tap left running is a process left
    // running.
    PlayerLevelTap {
        id: levelTap
        active: root.levelTapEnabled && root._playing
    }

    // Space is play/pause while the pointer is over the popup. A Shortcut is
    // application-wide, so it is gated on the hover: the module must not
    // swallow the space bar from whatever else is on screen.
    MouseArea {
        id: hoverWatch
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        cursorShape: undefined   // clicks pass through: the cursor is what lies under it (a MouseArea owns an Arrow)
        hoverEnabled: true
        propagateComposedEvents: true
        z: -1                       // under everything; it only watches
    }

    // Inside a query a space is a space: it goes on to the key sink.
    Shortcut {
        sequences: ["Space"]
        enabled: hoverWatch.containsMouse && root.player !== null && !libraryList.searching
        onActivated: root.requestPlayPause()
    }

    // TYPING SEARCHES THE LIBRARY, as in notes and the launcher: there is no field to click, the query is the row under the selector. The
    // keys are the popup's on the same terms as Space (HoverArm, below: only while the pointer has moved onto it), and they arrive here. On any
    // other panel, or with the sidebar shut, the first letter brings the library out: nothing else in the popup reads letters.
    function _showLibrary() {
        if (root.compact)
            root.viewMode = "player";
        root.browseOpen = true;
        root.browsePanel = "library";
    }
    Item {
        id: keySink
        objectName: "playerKeySink"
        Keys.onPressed: event => {
            const lib = libraryList;
            const kill = EK.queryActionOf(event.key, event.modifiers);
            if (queueMenu.handleKey(event) || lib.menuKey(event)) {
                event.accepted = true;
            } else if (kill !== null) {
                lib.setQuery(EK.queryAfter(kill, lib.query));
                event.accepted = true;
            } else if (event.key === Qt.Key_Backspace) {
                lib.setQuery(lib.query.slice(0, -1));
                event.accepted = true;
            } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && lib.searching) {
                lib.openFirstHit();
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape) {
                // Only where no shell has bound the key (a mockup's window).
                event.accepted = root.handleEscape();
            } else if (event.text.length > 0 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
                       && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
                if (!lib.searching)
                    root._searchRet = root._jumpFrom();
                root._showLibrary();
                lib.setQuery(lib.query + event.text);
                event.accepted = true;
            }
        }
    }
    // Escape reaches the popup through the shell's bind (GooeyEngine.pressEscape), past any Shortcut of a menu: what is on top goes first,
    // and the popup closes when nothing is left to go.
    function handleEscape(): bool {
        if (queueMenu.open) {
            queueMenu.open = false;
            return true;
        }
        if (!root.browsing)
            return false;
        if (root.browsePanel === "queue")
            return queueList.handleEscape();
        if (root.browsePanel !== "library")
            return false;
        const searched = libraryList.searching;
        const used = libraryList.handleEscape();
        // A search that started somewhere else ends there.
        if (searched && !libraryList.searching && root._searchRet !== null) {
            const ret = root._searchRet;
            root._searchRet = null;
            if (ret.panel !== "")
                root.browsePanel = ret.tab;
            else
                root._putBackView(ret);
        }
        return used;
    }
    property var _searchRet: null
    function _putBackView(ret) {
        root.browsePanel = ret.tab;
        root.viewMode = ret.viewMode;
        root.browseOpen = ret.browseOpen;
    }

    // ON A LAYER SURFACE the keys come only if the popup ASKS for them: GooeyEngine reads
    // this off the open popup and the host maps it onto the surface's keyboard focus. A
    // popup must never take the keyboard from the window the user is typing in because it
    // APPEARED under a resting pointer, only because the pointer was MOVED onto it, and
    // must give it back the moment the pointer leaves: HoverArm (the auth card's idiom).
    // "exclusive", not "onDemand": measured on Hyprland 0.56: on-demand
    // is click-only. The mockup's stage is no layer surface; nothing reads this there and
    // Space works through the Shortcut above, gated on the hover.
    HoverArm {
        id: spaceArm
        target: root
        active: root.visible && root.player !== null
    }
    readonly property string keyboardFocusRequest: spaceArm.armed ? "exclusive" : "none"
    Connections {
        target: spaceArm
        function onArmedChanged() {
            if (spaceArm.armed)
                keySink.forceActiveFocus();
        }
    }

    // The position is drawn here (the ball, the figures, the record's angle): while this popup
    // exists the player's elapsed clock runs, and only then (MpdService's header says why).
    PlayerTickHold {
        player: root.player
        active: root.visible
    }

    // ======================================================================
    // THE OVERLAY
    //
    // Anything that must paint -- and be CLICKED -- outside a list's clip
    // region lives here, at the popup's root: Qt Quick prunes pointer delivery
    // at an ancestor's bounds, so paint escapes a clip but input does not.
    // ======================================================================
    Item {
        id: overlayLayer
        anchors.fill: parent
        z: 100

        // The answer to "I queued that": a small burst where the row was.
        // At the popup's root rather than inside the list, because a list
        // clips, and a burst that is clipped to the row it came from reads as
        // a glitch rather than as an acknowledgement.
        VinylParticles {
            id: queueSparks
            anchors.fill: parent
            enabled: root.vinylParticles
            sparkColor: root.accent
            maxParticles: 120
        }
    }

    // Every queueing action in the sidebar answers here. `what` is what was
    // queued (a song, an album, a genre, a playlist); a bigger thing gets a
    // bigger burst, because that is the one difference worth showing.
    function _queuedFeedback(sceneX, sceneY, what) {
        if (!root.vinylParticles)
            return;
        const p = root.mapFromItem(null, sceneX, sceneY);
        const strength = (what === "song") ? 0.5 : (what === "album") ? 0.85 : 1.0;
        queueSparks.burst(p.x, p.y, strength);
    }

    // There is no popup-wide gesture: the view is a button at the bottom left,
    // and a horizontal wheel over the popup belongs to whatever is under the
    // pointer -- the library's own grouping selector, a list -- rather than to
    // the module as a whole. So the popup declares no `swipeGestureActive` /
    // `gestureHold*` pair: they are a hint to the host about holding its
    // surface open during a gesture, and there is no gesture to hold it open
    // for.

    // The record catches up to a player that was already going -- opening the
    // popup on a track that is halfway through must not replay the arrival: the
    // host rebuilds this item on every open, so by the time it exists the daemon
    // may be playing, paused, or stopped on a seated queue. In every one of those
    // the record is ALREADY ON THE PLATTER -- so it is put there, wearing the
    // art it is wearing, rather than claimed as "on" while the stage is left
    // idle and blank. Claiming without placing leaves a bare platter under a
    // title, and `_syncPlatter`'s first guard then refuses to ever put it right.
    Component.onCompleted: {
        // The view and the panel handed over at the build (the owner's bindings) are where the popup stands, not a switch: the
        // change handlers run for them during the build.
        switchSettle.stop();
        root._switching = false;
        // A popup built straight into mini has never seen `implicitHeight`
        // change, so the latch above has nothing in it yet.
        root._playerDiscSize = root._playerDiscLive;   // a seed; corrected at rest
        root._latchRest();
        root._noteCover();
        if (root.player && root.player.artistsIncludeLoose !== root.libraryLooseArtists)
            root.player.artistsIncludeLoose = root.libraryLooseArtists;
        root._ensureLibrary();
        root._seatRecord();
    }

    // The popup closed with an arrival under way: no record will land to start the music, so it starts now. Pressed Play is still Play.
    Component.onDestruction: {
        if (root._holdingForDrop && root.player)
            root.player.play();
    }

    // THE PLAYER ITSELF CAN BE SWAPPED under a live popup: the mockup's Run tab
    // hands the same content the mock one moment and the daemon the next,
    // without waiting for whatever the record was doing to finish. Everything
    // the record knows is about the OLD player -- and because the two can name
    // the SAME album, `_syncPlatter`'s first guard would then agree the record
    // is already right and never dress it again: a blank record.
    //
    // So a swap is not a musical event and gets no choreography: whatever the
    // new player is holding is PLACED, wearing its own art, exactly the way the
    // popup places a record when it is first built.
    onPlayerChanged: {
        root._onPlatter = "";
        root._platterArt = "";
        root._holdingForDrop = false;
        root._autoplayArmed = false;
        root._playedKey = "";
        root._seatRecord();
        root._ensureLibrary();
    }

    // Put the record where the player says it should be, with no sequence at
    // all. Used by both of the moments above, so there is one rule and not two.
    function _seatRecord() {
        if (!root.vinylEnabled)
            return;
        const src = root._sourceNow();
        root._wantKey = root._keyOf(src);
        if (root._keyOf(src) !== "") {
            root._onPlatter = root._keyOf(src);
            root._platterArt = root._coverOf(src);
            root._playedKey = root._playing ? root._keyOf(src) : "";
            vinylStage.snapToPlaying();
        } else {
            root._onPlatter = "";
            if (vinylStage.phase !== "idle")
                vinylStage.endSequence("");
        }
    }
}
