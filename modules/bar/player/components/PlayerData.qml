pragma ComponentBehavior: Bound

import QtQuick
import "../../../common/theme"
import "../../../common/scroll"
import "../../../common/components"
import "../../../common/components/Mix.js" as Mix
import "../../../audio/airplay"

// =============================================================================
// PlayerData.qml
//
// The Data panel: what the FILE says about the track that is playing -- or,
// when nothing is, about the one at the head of the queue. It lives where the
// queue and the library live, in the same carved box, with the same header box
// meeting the container's top corners, the same 6 px row inset and the shared
// CarvedListDressing at both ends.
//
// THE LYRICS ARE WHY THIS TAB GETS OPENED, so they get the room: the identity
// and the four figures are one header block at the top, the lyrics take
// everything under it, and the rest of the tags sit BELOW them, past the fold,
// for the reader who wants them.
//
// FOLLOWED, WHEN THE FILE ALLOWS IT. 169 of the 591 files in this library carry
// a `LYRICS` tag whose every line begins `[mm:ss.xx]` (AudioTags measures and
// explains it). Where they exist the reading is followed line by line; where
// only an untimed block exists it is shown as a block; where there is neither
// the panel says so in one sentence. Nothing is ever guessed into a sync.
//
// ONE READING HEAD, ONE CLOCK. The mark for "this line, now" is a single
// object -- a stripe at the left of the line -- that GLIDES from line to line
// and whose fill drains with the line's own remaining time. It is one item
// rather than a stripe per row for the reason the house always gives: a value
// that drives several things is one animated property. It also means the 113
// rows of the longest lyric here carry one binding each on the active index
// (which changes once a line) instead of one on the position (which changes
// every frame).
//
// A GAP IS A LINE. `[00:31.78] ` with nothing after it is what an instrumental
// passage looks like in an LRC block, and it is kept: the head sits in the gap
// as a short stripe and fills as the gap runs out, which says "the singing
// stops here, and it comes back in a moment" with the object that was already
// on screen. No second vocabulary for it.
//
// ...EXCEPT THE LAST ONE, WHICH IS A FULL STOP. Most blocks in this library end
// with a stamped empty line -- `[02:28.08] ` closes Cabin Fever Freestyle,
// `[03:07.06] ` closes Show Me How -- and that entry is not a gap between two
// lines, it is the file saying THE WORDS END HERE. Kept as a row it draws a
// standalone stripe under the last lyric with nothing left to sing; drained
// against the TRACK's duration it then crawls through the two minutes of outro
// that follow. So it is taken out of the rows and kept as the one number it
// actually is: `_wordsEnd`. The head is handed to the final line, fills it
// against that number, and goes.
//
// CLICKING A LINE SEEKS TO IT, and nothing announces that but the pointer: the
// hand cursor and a short lift of the line's colour. Only where the lines are
// timed -- an untimed block has nowhere to seek to.
//
// THE FIGURES NEVER JITTER. Released / BPM / Key / Type each sit in a quarter
// of the header's own width, and a tag the file does not have shows an em dash
// rather than collapsing its slot and moving the other three.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // DATA
    // ======================================================================
    // What is playing, in the module's vocabulary (file, title, artist, album,
    // duration), and null when nothing is.
    property var song: null
    // The queue, for the one case the panel has to answer on its own: with
    // nothing playing, what this tab describes is THE TRACK THAT WOULD PLAY.
    // The rule lives here rather than in the host's binding because it is the
    // panel's own rule -- a host binds two plain properties and nothing else:
    //
    //     song:  player.current
    //     queue: player.queue
    property var queue: []
    // What is actually being described, and whether it is the queue's head
    // rather than what is under the needle. Both derived, so a host cannot
    // set one without the other and get a header that lies.
    readonly property var subject: root.song ? root.song
        : ((root.queue && root.queue.length > 0) ? root.queue[0] : null)
    readonly property bool upNext: !root.song && root.subject !== null
    property bool playing: false
    // Seconds into the track, live. This is what the reading follows.
    property real position: 0
    // Where MPD's music_directory is, for turning a song's relative `file`
    // into a path ffprobe can open. Ignored when `file` is already absolute.
    property string musicDir: ""

    // The panel is the one on show. Nothing is read while this is false: one
    // process per track change for a tab nobody has open is what the gate is
    // for. ANDed with `visible`, so a host that forgets it still pays nothing
    // for a hidden panel.
    property bool active: true

    // ======================================================================
    // LOOK
    // ======================================================================
    property real listScale: 1.0
    // Every corner of every box in here, the header's included. A header box
    // can sit flush with the container's edge, so its corner has to be able to
    // COINCIDE with the container's -- and a radius that changed with the
    // scroll would be a box that morphs as it reaches the edge. So a header
    // box has one radius and it is this one.
    property real containerRadius: 14
    property bool compact: false
    property string fontFamily: "Inter"

    // Colours. Plain properties defaulted from Theme, so a host may override
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
    property color headerBoxBevelColor: Theme.headerBoxBevel
    property color headerBoxShadowColor: Theme.headerBoxShadow

    // ======================================================================
    // LAYOUT NUMBERS (the house's, as properties)
    // ======================================================================
    property real rowInset: 6
    property real listFadeHeight: 34
    property real headerBoxPadding: 11
    property real headerBoxPaddingV: 8
    property real headerBottomGap: 6
    // Above a section label, and under it before the block it names.
    property real sectionTopGap: 12
    property real sectionBottomGap: 6
    property real footGap: 10
    // Between the header's title line and the figures row under it.
    property real factTopGap: 8
    property real factLabelGap: 1
    property real lyricLineGap: 6
    // A gap line's height, as a share of a sung line's. Short enough to read
    // as a pause, tall enough for the head to be a mark rather than a dot.
    property real gapLineFactor: 0.62
    property real stripeWidth: 3
    property real stripeRadius: 1.5
    // How much of the groove the head's own track shows through.
    property real stripeTrackAlpha: 0.8
    property real tagRowGap: 5
    // How far a line that has been sung is pushed back toward the box it sits
    // in. Dimmer than faint, because the eye belongs at the line that is
    // happening and the ones still coming.
    property real pastDim: 0.42
    // The label column of the tag block, as a share of the width.
    property real tagLabelShare: 0.34

    // ======================================================================
    // TYPE
    // ======================================================================
    property int headerTitleSize: 15
    property int subtitleSize: 11
    property int figureSize: root.compact ? 10 : 11
    property int labelSize: 10
    property int lyricSize: root.compact ? 13 : 14

    // ======================================================================
    // MOTION
    // ======================================================================
    // The reading head gliding from line to line, and the fade of anything
    // whose PRESENCE changes (the head itself, the lyrics arriving).
    property int headMoveMs: 200
    property int fadeMs: 160
    // A line lighting up and going out.
    property int litMs: 220
    property int hoverMs: 120
    // The follow: where in the viewport the current line is held, how long the
    // scroll to it takes, and how long a hand on the wheel switches it off for.
    property bool followPlayback: true
    property real followFraction: 0.38
    property int followMs: 420
    property int followResumeMs: 5000
    property real scrollSpeed: 1.0

    // ======================================================================
    // SIGNALS
    // ======================================================================
    // A timed line was clicked: seek there.
    signal seekRequested(real seconds)

    // ======================================================================
    // WHAT THE READER FOUND (published for a probe and for a host that wants
    // to say something about it)
    // ======================================================================
    readonly property alias reader: tagReader
    readonly property var tags: tagReader.tags
    readonly property var lyrics: tagReader.lyrics
    readonly property bool tagsReady: tagReader.ready

    // ======================================================================
    // DERIVED
    // ======================================================================
    readonly property real _s: Math.max(0.2, root.listScale)
    // ONE left edge for everything inside the box: the lyric lines, the
    // section labels and the tag rows all start here, and the reading head
    // stands in the inset to the left of it. The header box has its own
    // padding, exactly as the queue's does.
    readonly property real _textLeft:
        (root.rowInset + root.stripeWidth + root.headerBoxPadding / 2) * root._s
    // A line already sung, dimmed against the box rather than against a
    // literal: both ends are themed, so a theme switch carries it.
    readonly property color _lyricPast: Mix.c(root.faintColor, root.listBoxColor, root.pastDim)
    readonly property string _file: root.subject && root.subject.file ? String(root.subject.file) : ""
    readonly property string _path: {
        if (root._file.length === 0)
            return "";
        if (root._file.charAt(0) === "/")
            return root._file;
        return (root.musicDir.length > 0 ? root.musicDir + "/" : "") + root._file;
    }
    // The block as the PANEL reads it: one object carrying all three facts,
    // because reading two bindings on the same source asks about the order
    // they are re-evaluated in and that order is not ours to assume (read
    // apart, they can leave the first line of a new song unseated).
    //
    //   synced  the file timed these lines itself
    //   lines   the rows, the trailing terminator taken off
    //   end     where the singing stops, on the track's own clock
    //
    // With no terminator the words still have to end somewhere, and the block
    // itself says how long a line lasts: the median gap between consecutive
    // lines, held to the range a sung line actually falls in. Never the
    // track's duration -- an outro is not a line.
    readonly property var _block: {
        const ly = root.lyrics;
        const raw = (ly && ly.lines) ? ly.lines : [];
        if (!ly || !ly.synced)
            return { synced: false, lines: raw, end: 0 };
        const l = raw.slice();
        let end = 0;
        while (l.length > 0 && String(l[l.length - 1].text).length === 0) {
            end = l[l.length - 1].t;
            l.pop();
        }
        if (l.length === 0)
            return { synced: true, lines: l, end: end };
        const last = l[l.length - 1].t;
        if (end > last)
            return { synced: true, lines: l, end: end };
        const gaps = [];
        for (let i = 1; i < l.length; i++)
            gaps.push(l[i].t - l[i - 1].t);
        gaps.sort((a, b) => a - b);
        const med = gaps.length > 0 ? gaps[Math.floor(gaps.length / 2)] : 5;
        return { synced: true, lines: l, end: last + Math.max(2, Math.min(12, med)) };
    }
    readonly property var _lines: root._block.lines
    readonly property bool _synced: root._block.synced && root._lines.length > 0
    // Clamped to the track, for the file that stamped its terminator past the
    // end of its own audio.
    readonly property real _wordsEnd: {
        const e = root._block.end;
        const d = root.subject && root.subject.duration > 0 ? root.subject.duration : 0;
        return d > 0 ? Math.min(e, d) : e;
    }
    // THE POSITION, BUT ONLY WHEN SOMEBODY IS LOOKING.
    //
    // `position` is written every frame by the host's elapsed integrator, and
    // three things here follow it: the seat walk, `_headLive`, and `_lineFrac`,
    // which drives the reading head's own height. That is right while this
    // panel is the open one -- the head sweeps a word and genuinely wants the
    // frame rate -- and pure waste behind the queue or the library, which is
    // where the sidebar usually is. `active`/`visible` gate what the panel
    // SHOWS, not what it DOES.
    //
    // The short-circuit is the mechanism, not merely an early return: with
    // `active` false, `root.position` is never READ, so QML never captures it
    // as a dependency and none of the three re-evaluates at all.
    //
    // It parks at 0 rather than at its last value because 0 is where a seat
    // walk is cheapest to redo, and because a stale intermediate would be a
    // second truth about where the music is. That makes ZERO A LEGAL VALUE
    // this can be parked at, which is the sentinel collision: open the panel
    // at position 0, having closed it at position 0, and `_pos` does not
    // change, so nothing would re-seat and the head would come up stale.
    // Hence the two handlers below: becoming active and becoming visible each
    // re-seat explicitly.
    //
    // AIRPLAY: the lyrics are sung by the SOUND, which lags the player's position by the sink's buffer while mpd plays into an AirPlay
    // speaker (AirplayDelay.delayMs, 0 otherwise), so the active line and the head's sweep follow position - delay (never below 0).
    // The playhead, the scrub and everything else in the popup stay on the live position.
    readonly property real _pos: (root.active && root.visible) ? Math.max(0, root.position - AirplayDelay.delayMs / 1000) : 0

    // The head is present while there are words left to reach. Past the last
    // line's own end it is not somewhere in the outro, it is DONE.
    readonly property bool _headLive: root._synced && root._pos < root._wordsEnd
    readonly property bool _hasLyrics: root._lines.length > 0
    // What the header's state word says. Three states, because "not playing"
    // covers two very different facts: this is the track you paused, or this
    // is the one that would start.
    readonly property string _stateWord:
        root.upNext ? "Up next" : (root.playing ? "Now playing" : "Paused")

    // The line under the needle: the last one whose time has passed. -1 before
    // the first line, which is a real state -- an intro nobody sings over.
    property int _activeIdx: -1
    // How far through that line we are, 0..1, from its own time to the next
    // one's. The last line runs to `_wordsEnd` -- the end of the WORDS, which
    // is not the end of the track and on some files is nowhere near it.
    readonly property real _lineFrac: {
        if (!root._synced || root._activeIdx < 0 || root._activeIdx >= root._lines.length)
            return 0;
        const t0 = root._lines[root._activeIdx].t;
        const t1 = root._activeIdx + 1 < root._lines.length
            ? root._lines[root._activeIdx + 1].t
            : root._wordsEnd;
        if (!(t1 > t0))
            return 0;
        return Math.max(0, Math.min(1, (root._pos - t0) / (t1 - t0)));
    }

    function _seatActive() {
        // Read the block ONCE, and take both facts off that one object -- and
        // the SAME object the Repeater draws from, terminator already off it,
        // or the seat lands one index past the last row that exists.
        const b = root._block;
        // Called from the change handlers below DURING CREATION, before the binding of `_block`
        // has run: undefined then, and a TypeError per popup built.
        if (!b) {
            root._activeIdx = -1;
            return;
        }
        const l = b.lines;
        if (!b.synced || l.length === 0) {
            root._activeIdx = -1;
            return;
        }
        // Walked from where it was rather than searched: the position moves
        // by a frame at a time, so this is nearly always zero steps, and a
        // seek of any size still lands in one pass.
        let i = Math.max(-1, Math.min(root._activeIdx, l.length - 1));
        while (i + 1 < l.length && l[i + 1].t <= root._pos)
            i++;
        while (i >= 0 && l[i].t > root._pos)
            i--;
        root._activeIdx = i;
    }
    on_PosChanged: root._seatActive()
    // Zero is a legal parked value, so becoming visible again cannot be
    // detected as a change in `_pos`. See `_pos`.
    onActiveChanged: root._seatActive()
    onVisibleChanged: root._seatActive()
    on_LinesChanged: {
        root._activeIdx = -1;
        root._seatActive();
    }

    // The row item the head stands on. Held as an ITEM, not as a y, so the
    // head follows a re-layout (a resize rewraps every line) without anybody
    // recomputing anything.
    //
    // A BINDING, not a hand-off, and that is the whole of it: the rows are
    // made by a Repeater and the index is current BEFORE they exist -- the
    // first line of a song is already the one being sung the moment the lyrics
    // land -- so an imperative seat runs a frame too early and the head never
    // appears at all. `count` is in the expression so this re-runs when the
    // Repeater has finished building, and the length guard is what stops it
    // pointing at a row of the previous song while the two are out of step.
    readonly property Item _activeItem: {
        const n = lyricRepeater.count;
        if (root._activeIdx < 0 || root._activeIdx >= n || root._lines.length !== n)
            return null;
        return lyricRepeater.itemAt(root._activeIdx);
    }
    on_ActiveItemChanged: root._follow()

    // ---- The follow ------------------------------------------------------
    // Suspended by a hand on the wheel or a finger on the list: somebody
    // reading ahead is not to be dragged back to the singing.
    property real _followSuspendedUntil: 0
    function _suspendFollow() {
        root._followSuspendedUntil = Date.now() + root.followResumeMs;
    }
    function _follow() {
        if (!root.followPlayback || !root._synced || !root._activeItem)
            return;
        if (Date.now() < root._followSuspendedUntil || kinetic.moving)
            return;
        const max = Math.max(0, listFlick.contentHeight - listFlick.height);
        if (max <= 0)
            return;
        const mid = root._activeItem.mapToItem(content, 0, 0).y
                  + root._activeItem.height / 2;
        const want = Math.max(0, Math.min(max, mid - listFlick.height * root.followFraction));
        if (Math.abs(want - listFlick.contentY) < 1)
            return;
        kinetic.stop();
        followAnim.to = want;
        followAnim.restart();
    }
    NumberAnimation {
        id: followAnim
        target: listFlick
        property: "contentY"
        duration: root.followMs
        easing.type: Easing.OutCubic
    }

    // ======================================================================
    // THE READER
    // ======================================================================
    AudioTags {
        id: tagReader
        path: root._path
        active: root.active && root.visible
    }

    // ======================================================================
    // METRICS -- measured through FontMetrics, never by reading a Text back
    // ======================================================================
    FontMetrics {
        id: fmHead
        font.family: root.fontFamily
        font.pixelSize: root.headerTitleSize * root._s
    }
    FontMetrics {
        id: fmSub
        font.family: root.fontFamily
        font.pixelSize: root.subtitleSize * root._s
    }
    FontMetrics {
        id: fmFig
        font.family: root.fontFamily
        font.pixelSize: root.figureSize * root._s
    }
    FontMetrics {
        id: fmLabel
        font.family: root.fontFamily
        font.pixelSize: root.labelSize * root._s
    }
    FontMetrics {
        id: fmLyric
        font.family: root.fontFamily
        font.pixelSize: root.lyricSize * root._s
    }

    // ======================================================================
    // THE TAG BLOCK -- which tags, in which order, under which names
    // ======================================================================
    // Shown in the four figure slots, or already in the header: not repeated
    // below. The mp4 brand triple is the container talking about itself.
    readonly property var _tagSkip: ({
        "title": 1, "artist": 1, "album": 1, "album_artist": 1, "albumartist": 1,
        "date": 1, "bpm": 1, "tbpm": 1, "initialkey": 1, "releasetype": 1,
        // The same fact as `releasetype`, under MusicBrainz's name for it, and
        // the Type slot already falls back to it: showing it again below would
        // be the fact twice, in two spellings.
        "musicbrainz album type": 1,
        // Folded into the Track and Disc rows as "1 of 16" rather than
        // standing as two rows labelled "Of".
        "tracktotal": 1, "disctotal": 1,
        "major_brand": 1, "minor_version": 1, "compatible_brands": 1,
        "_format": 1, "_duration": 1, "_bitrate": 1, "_filename": 1
    })
    // The ones worth reading first; everything else follows in name order, so
    // a tag nobody anticipated is still shown rather than silently dropped.
    readonly property var _tagOrder: ["genre", "track", "disc",
                                      "composer", "performer", "conductor", "copyright",
                                      "label", "publisher", "isrc", "upc", "barcode",
                                      "originaldate", "url", "encoder"]
    readonly property var _tagNames: ({
        "genre": "Genre", "track": "Track", "disc": "Disc",
        "composer": "Composer", "performer": "Performer",
        "conductor": "Conductor", "copyright": "Copyright", "label": "Label",
        "publisher": "Publisher", "isrc": "ISRC", "upc": "UPC", "barcode": "Barcode",
        "originaldate": "First released", "url": "Source", "encoder": "Encoder",
        "musicbrainz album type": "Release", "rating": "Rating"
    })
    readonly property var _tagRows: {
        const out = [];
        const t = root.tags || ({});
        const seen = ({});
        for (let i = 0; i < root._tagOrder.length; i++) {
            const k = root._tagOrder[i];
            if (t[k] === undefined || String(t[k]).length === 0 || root._tagHidden(k, t))
                continue;
            seen[k] = 1;
            out.push({ label: root._tagLabel(k), value: root._tagValue(k, t) });
        }
        const keys = Object.keys(t).sort();
        for (let j = 0; j < keys.length; j++) {
            const k2 = keys[j];
            if (seen[k2] || root._tagHidden(k2, t) || k2.indexOf("lyric") >= 0)
                continue;
            if (String(t[k2]).length === 0)
                continue;
            out.push({ label: root._tagLabel(k2), value: String(t[k2]) });
        }
        // The file itself, last: the one fact in this block that is not a tag.
        if (root._file.length > 0) {
            const slash = root._file.lastIndexOf("/");
            out.push({ label: "File", value: slash >= 0 ? root._file.substring(slash + 1) : root._file });
        }
        return out;
    }
    // A tag the header already shows. `_tagSkip` is the fixed half; the
    // release date is the half that has to be decided per file, because the
    // Released slot shows `date` when the file has one and falls back to
    // `originaldate` when it does not. So `originaldate` is the same fact
    // twice exactly when it agrees with what the slot ended up showing, and a
    // second real fact (an original pressing behind a reissue) when it does
    // not -- which is when the row is worth its line.
    function _tagHidden(key, tags) {
        if (root._tagSkip[key])
            return true;
        if (key === "originaldate")
            return String(tags[key]) === root._factDate;
        return false;
    }

    // A tag's value as a row shows it. One number and its total are one fact,
    // and this library writes it both ways: the m4a puts "1/16" in `track`,
    // the FLAC puts "1" in `track` and "16" in `tracktotal`. Both come out as
    // "1 of 16" -- one spelling, whatever the container chose.
    function _tagValue(key, tags) {
        if (key !== "track" && key !== "disc")
            return String(tags[key]);
        let n = String(tags[key]);
        let m = String(tags[key + "total"] || "");
        const slash = n.indexOf("/");
        if (slash >= 0) {
            m = n.substring(slash + 1);
            n = n.substring(0, slash);
        }
        return m.length > 0 ? n + " of " + m : n;
    }
    function _tagLabel(key) {
        if (root._tagNames[key] !== undefined)
            return root._tagNames[key];
        const s = String(key).replace(/_/g, " ");
        return s.charAt(0).toUpperCase() + s.substring(1);
    }

    // The four fixed figures. A tag the file does not carry keeps its slot.
    function _tag(key) {
        const t = root.tags || ({});
        return t[key] !== undefined ? String(t[key]) : "";
    }
    readonly property string _factDate: root._tag("date") || root._tag("originaldate")
    readonly property string _factBpm: root._tag("bpm") || root._tag("tbpm")
    readonly property string _factKey: root._tag("initialkey")
    readonly property string _factType: {
        const s = root._tag("releasetype") || root._tag("musicbrainz album type");
        return s.length > 0 ? s.charAt(0).toUpperCase() + s.substring(1) : "";
    }

    // ======================================================================
    // THE BOX
    // ======================================================================
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
            id: listFlick
            objectName: "playerDataFlick"
            anchors.fill: parent
            contentWidth: content.width
            contentHeight: content.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            onDragStarted: { root._suspendFollow(); kinetic.stop(); }

            Column {
                id: content
                objectName: "playerDataContent"
                width: listFlick.width
                spacing: 0

                // Nothing playing and nothing queued: there is no identity to
                // state, and a header box with an em dash over it saying
                // "Now playing" is a header that lies. It goes, and the box is
                // left to the one sentence -- which is what the queue does with
                // its own empty list.
                DataHeader {
                    width: content.width
                    visible: root.subject !== null
                }

                // ---- the lyrics ------------------------------------------
                SectionLabel {
                    width: content.width
                    text: "Lyrics"
                    visible: root.subject !== null
                }

                Item {
                    id: lyricsBlock
                    width: content.width
                    implicitHeight: lyricCol.height
                    visible: root.subject !== null
                    // Presence fades; nothing crossfades. A read takes ~55 ms,
                    // so this is a blank slot for two frames, not a flash.
                    opacity: root.tagsReady ? 1 : 0
                    Behavior on opacity {
                        NumberAnimation {
                            duration: root.fadeMs
                        }
                    }

                    Column {
                        id: lyricCol
                        width: parent.width
                        spacing: root.lyricLineGap * root._s

                        Repeater {
                            id: lyricRepeater
                            model: root._lines
                            delegate: LyricLine {
                                required property var modelData
                                required property int index
                                width: lyricCol.width
                                text: modelData.text
                                at: modelData.t
                                idx: index
                            }
                        }
                    }

                    // ---- the reading head --------------------------------
                    Item {
                        id: readingHead
                        objectName: "playerDataHead"
                        x: root.rowInset * root._s
                        width: root.stripeWidth * root._s
                        y: root._activeItem ? root._activeItem.y : 0
                        height: root._activeItem ? root._activeItem.height : 0
                        visible: opacity > 0
                        opacity: root._headLive && root._activeItem ? 1 : 0

                        Behavior on y {
                            NumberAnimation {
                                duration: root.headMoveMs
                                easing.type: Easing.OutCubic
                            }
                        }
                        Behavior on height {
                            NumberAnimation {
                                duration: root.headMoveMs
                                easing.type: Easing.OutCubic
                            }
                        }
                        Behavior on opacity {
                            NumberAnimation {
                                duration: root.fadeMs
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: root.stripeRadius * root._s
                            color: Mix.c(root.listBoxColor, root.borderColor,
                                         root.stripeTrackAlpha)
                        }
                        Rectangle {
                            width: parent.width
                            height: parent.height * root._lineFrac
                            radius: root.stripeRadius * root._s
                            color: root.accentColor
                        }
                    }
                }

                // A file with no lyrics says so, in the place the lyrics
                // would have been -- not as a silhouette of something that
                // is never going to resolve.
                Item {
                    width: content.width
                    implicitHeight: root._hasLyrics || !root.tagsReady || root.subject === null
                        ? 0 : fmLyric.height * 2.4
                    visible: implicitHeight > 0
                    Text {
                        anchors.centerIn: parent
                        text: tagReader.error.length > 0 ? "Could not read this file"
                                                         : "No lyrics in this file"
                        color: root.faintColor
                        font.family: root.fontFamily
                        font.pixelSize: root.subtitleSize * root._s
                    }
                }

                // ---- the rest of the tags --------------------------------
                SectionLabel {
                    width: content.width
                    text: "Tags"
                    visible: root._tagRows.length > 0 && root.tagsReady
                }

                Column {
                    width: content.width
                    spacing: root.tagRowGap * root._s
                    visible: root._tagRows.length > 0 && root.tagsReady

                    Repeater {
                        model: root._tagRows
                        delegate: TagRow {
                            required property var modelData
                            width: content.width
                            label: modelData.label
                            value: modelData.value
                        }
                    }
                }

                Item {
                    width: content.width
                    implicitHeight: root.footGap * root._s
                }
            }
        }

        // THE WHEEL, through the shell's one scroll engine (modules/common/scroll): a
        // notch glides, fingers follow and a lift coasts. A MouseArea over the list,
        // not a WheelHandler: a handler never hears the zero-delta event that is the
        // fingers lifting (it starts the coast) nor a purely sideways one. It takes no
        // button and no hover, so a click and a lyric line's tap pass through it.
        KineticScroll {
            id: kinetic
            flick: listFlick
            speed: root.scrollSpeed * ScrollFeel.speed
            // Reading ahead includes the coast: the follow stays away until it has
            // stopped, and then for the usual while.
            onMovingChanged: if (!kinetic.moving) root._suspendFollow()
        }
        WheelArea {
            anchors.fill: listFlick
            turned: wheel => {
                const py = wheel.pixelDelta.y, ay = wheel.angleDelta.y;
                if (py === 0 && ay === 0 && (wheel.pixelDelta.x !== 0 || wheel.angleDelta.x !== 0)) {
                    wheel.accepted = false;    // purely sideways: not this list's
                    return;
                }
                root._suspendFollow();
                followAnim.stop();
                kinetic.feed(py, ay, wheel.phase);
                wheel.accepted = true;
            }
        }

        CarvedListDressing {
            flick: listFlick
            boxColor: root.listBoxColor
            surfaceColor: root.surfaceColor
            bevelColor: root.bevelColor
            radius: root.containerRadius
            fadeHeight: root.listFadeHeight
        }

        // Nothing playing and nothing queued: there is no file to read, which
        // is a sentence and not a skeleton.
        Text {
            anchors.centerIn: parent
            text: "Nothing playing"
            color: root.faintColor
            font.family: root.fontFamily
            font.pixelSize: root.subtitleSize * root._s
            opacity: root.subject === null ? 1 : 0
            visible: opacity > 0
            Behavior on opacity {
                NumberAnimation {
                    duration: root.fadeMs
                }
            }
        }
    }

    // ======================================================================
    // THE HEADER: who this is, and the four figures
    // ======================================================================
    component DataHeader: Item {
        id: head
        implicitHeight: head._textH + root.headerBoxPaddingV * 2 * root._s
                        + head._bottomGap
        readonly property real _bottomGap: root.headerBottomGap * root._s
        readonly property real _pad: root.headerBoxPadding * root._s
        readonly property real _factH: fmLabel.height + root.factLabelGap * root._s + fmFig.height
        readonly property real _textH: fmHead.height + fmSub.height
                                       + root.factTopGap * root._s + head._factH

        ShadowBox {
            anchors.fill: parent
            anchors.bottomMargin: head._bottomGap
            // The container's radius on every corner: the two top ones meet
            // the container's own and have to coincide with them, and a box
            // whose foot were rounder or flatter than its head reads as one
            // side of it having a different radius. Pre-divided, because
            // ShadowBox multiplies every radius by sizeScale and the
            // container's number is the host's, not the row scale's.
            baseRadius: root.containerRadius / root._s
            sizeScale: root._s
            surfaceColor: root.listBoxColor
            backgroundColor: root.headerBoxColor
            bevelColor: root.headerBoxBevelColor
            shadowColor: root.headerBoxShadowColor
            bevelWidth: 1
            shadowWidth: 3
        }

        Text {
            id: headTitle
            x: head._pad
            y: root.headerBoxPaddingV * root._s
            width: head.width - head._pad * 2 - stateWord.width - root.headerBoxPadding * root._s
            elide: Text.ElideRight
            text: root.subject && root.subject.title ? String(root.subject.title) : "—"
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: root.headerTitleSize * root._s
            font.bold: true
        }
        // Which track this is, when it is not the obvious one. The panel
        // describes the queue's head while nothing plays, and without this
        // word it would look like the record's own data.
        Text {
            id: stateWord
            x: head.width - width - head._pad
            y: headTitle.y + (fmHead.height - fmLabel.height) / 2
            text: root._stateWord
            color: root.faintColor
            font.family: root.fontFamily
            font.pixelSize: root.labelSize * root._s
        }
        Text {
            id: headSub
            x: head._pad
            y: headTitle.y + fmHead.height
            width: head.width - head._pad * 2
            elide: Text.ElideRight
            text: {
                if (!root.subject)
                    return "";
                const a = root.subject.artist ? String(root.subject.artist) : "";
                const b = root.subject.album ? String(root.subject.album) : "";
                return a.length > 0 && b.length > 0 ? a + " · " + b : a + b;
            }
            color: root.mutedColor
            font.family: root.fontFamily
            font.pixelSize: root.subtitleSize * root._s
        }

        Row {
            id: factRow
            x: head._pad
            y: headSub.y + fmSub.height + root.factTopGap * root._s
            width: head.width - head._pad * 2
            height: head._factH

            FactCell {
                width: factRow.width / 4
                label: "Released"
                value: root._factDate
            }
            FactCell {
                width: factRow.width / 4
                label: "BPM"
                value: root._factBpm
            }
            FactCell {
                width: factRow.width / 4
                label: "Key"
                value: root._factKey
            }
            FactCell {
                width: factRow.width / 4
                label: "Type"
                value: root._factType
                last: true
            }
        }
    }

    // One fixed figure slot: a quiet label with its figure under it, and a
    // hairline between it and the next.
    component FactCell: Item {
        id: cell
        property string label: ""
        property string value: ""
        property bool last: false
        height: fmLabel.height + root.factLabelGap * root._s + fmFig.height

        Text {
            id: cellLabel
            text: cell.label
            color: root.faintColor
            font.family: root.fontFamily
            font.pixelSize: root.labelSize * root._s
        }
        Text {
            y: cellLabel.height + root.factLabelGap * root._s
            width: cell.width - root.headerBoxPadding * root._s
            elide: Text.ElideRight
            // An em dash, not a blank: the slot is reserved either way, and a
            // blank one reads as a panel that failed rather than as a tag the
            // file never had.
            text: cell.value.length > 0 ? cell.value : "—"
            color: cell.value.length > 0 ? root.textColor : root.faintColor
            font.family: root.fontFamily
            font.pixelSize: root.figureSize * root._s
        }
        Rectangle {
            visible: !cell.last
            x: cell.width - root.headerBoxPadding * root._s / 2
            y: 1
            width: 1
            height: cell.height - 2
            color: root.borderColor
            opacity: 0.6
        }
    }

    // ======================================================================
    // A SECTION LABEL: a word over a block, with no box of its own. The panel
    // has one header box; a second one for "Lyrics" would weigh as much as
    // the thing it names.
    // ======================================================================
    component SectionLabel: Item {
        id: sect
        property string text: ""
        implicitHeight: fmLabel.height + (root.sectionTopGap + root.sectionBottomGap) * root._s

        Text {
            x: root._textLeft
            y: root.sectionTopGap * root._s
            text: sect.text
            color: root.mutedColor
            font.family: root.fontFamily
            font.pixelSize: root.labelSize * root._s
            font.bold: true
        }
    }

    // ======================================================================
    // ONE LYRIC LINE
    //
    //   [head] Show me how you care
    //
    // The row carries no mark of its own: the stripe is the panel's single
    // reading head, which stands on whichever row is current. What the row
    // owns is its colour, and that is one eased fraction -- lit -- mixed
    // between themed colours, never a Behavior on the colour itself.
    // ======================================================================
    component LyricLine: Item {
        id: line
        property string text: ""
        property real at: -1
        property int idx: -1
        objectName: "playerDataLyric"

        readonly property bool isGap: line.text.length === 0
        readonly property bool isActive: root._activeIdx === line.idx
        // Sung already, so out of the way: the reader's eye belongs at the
        // line that is happening and the ones coming.
        readonly property bool isPast: root._synced && root._activeIdx > line.idx
        readonly property bool clickable: root._synced && line.at >= 0

        implicitHeight: line.isGap
            ? Math.round(fmLyric.height * root.gapLineFactor)
            : lineText.implicitHeight

        property real lit: line.isActive ? 1 : 0
        Behavior on lit {
            NumberAnimation {
                duration: root.litMs
                easing.type: Easing.OutCubic
            }
        }
        property real hoverF: hover.hovered && line.clickable && !line.isGap ? 1 : 0
        Behavior on hoverF {
            NumberAnimation {
                duration: root.hoverMs
            }
        }

        Text {
            id: lineText
            x: root._textLeft
            width: line.width - x - root.rowInset * root._s
            text: line.text
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: root.lyricSize * root._s
            // Three resting colours, one eased fraction over them. An untimed
            // block has no "now", so every line of it is simply readable;
            // where there IS a now, what is coming is faint and what has gone
            // is fainter, which is what makes the lit line read as lit at all
            // -- primary against muted is not a step the eye sees.
            color: Mix.c3(!root._synced ? root.textColor
                                        : (line.isPast ? root._lyricPast : root.faintColor),
                          root.textColor, line.hoverF * 0.55,
                          root.textColor, line.lit)
        }

        HoverHandler {
            id: hover
            enabled: line.clickable && !line.isGap
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            enabled: line.clickable
            onTapped: {
                // Seeking to the line's own start would drop the reader into
                // the middle of the first syllable; a hair before it is what
                // a person means by "from here".
                root.seekRequested(Math.max(0, line.at - 0.15));
                root._suspendFollow();
            }
        }
    }

    // ======================================================================
    // ONE TAG ROW: a fixed label column, so every value starts at the same x.
    // ======================================================================
    component TagRow: Item {
        id: tagRow
        property string label: ""
        property string value: ""
        implicitHeight: Math.max(tagLabel.implicitHeight, tagValue.implicitHeight)

        Text {
            id: tagLabel
            x: root._textLeft
            width: tagRow.width * root.tagLabelShare - x
            elide: Text.ElideRight
            text: tagRow.label
            color: root.faintColor
            font.family: root.fontFamily
            font.pixelSize: root.labelSize * root._s
        }
        Text {
            id: tagValue
            x: tagRow.width * root.tagLabelShare
            width: tagRow.width - x - root._textLeft
            elide: Text.ElideRight
            text: tagRow.value
            color: root.mutedColor
            font.family: root.fontFamily
            font.pixelSize: root.figureSize * root._s
        }
    }
}
