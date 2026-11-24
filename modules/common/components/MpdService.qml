pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "../system"
import "MpdShuffle.js" as Shuffle
import "MpdFidelity.js" as Fidelity

// =============================================================================
// MpdService.qml
//
// The player's model. Everything the UI reads about what is playing, what is
// queued and what is in the library, plus the functions that change it. The
// wire lives in MpdClient; this file knows what the commands MEAN.
//
// NOTHING HERE POLLS. Every state field is written from a `status` /
// `currentsong` read triggered by an idle notification, and idle is push. The
// one clock in the file is the elapsed interpolator, and it interpolates — it
// does not ask the daemon anything. A one-second status poll (what rmpc does)
// would be 3600 round trips an hour to learn a number we can compute.
//
// WHY ELAPSED IS INTERPOLATED AT ALL. MPD reports `elapsed` in whole decoder
// chunks — measured on this daemon it advances in ~0.27 s steps — and only
// when something asks. The vinyl's rotation IS this value, so at 60 fps a
// stepped elapsed would be a record that jerks four times a second. So a
// FrameAnimation advances it locally by `frameTime` and every status read
// re-seats it.
//
// THE INTERPOLATOR RUNS ONLY WHILE SOMETHING SHOWS THE ELAPSED TIME. A running
// FrameAnimation makes EVERY window of the process render at vsync (measured:
// 41 frames in 1.5 s of an unobserved one, 0 without), and in the shell this
// service is ONE for every screen: music playing would hold each bar window at
// 120 frames a second whether or not a pixel changed. So the clock is held
// (`holdTick(who)` / `releaseTick(who)`; PlayerTickHold is the idiom) by what
// draws the position -- the player popup while it exists, the OSD's track card
// and the lock's media slot when they show it -- and with no holder nothing
// runs. The position is then CAUGHT UP, by the wall clock, at the moments
// anything reads it: a status read, `prev()` (the three-second rule), and the
// first holder (who also asks for a status, which re-seats it exactly -- a
// suspend is a jump of the wall clock the catch-up cannot know about).
// `_elapsedAtMs` is when `_elapsed` was last written, and the only thing the
// catch-up counts from.
//
// RE-SEATING NEVER RUNS BACKWARDS. A status read arrives for reasons that have
// nothing to do with time (a volume change fires `changed: mixer`, and we read
// status), and the daemon's quantised value is usually a fraction of a second
// BEHIND our interpolation. Snapping to it would make the record stutter
// backwards every time the user touched the volume. So within
// `elapsedResyncSec` we only ever move forward, and a real discontinuity —
// a seek we issued, a new song, a gap bigger than the tolerance — is applied
// exactly. That is one rule, not two code paths: `_forceSeat` is set by the
// things that KNOW the position jumped.
//
// AND THE DAEMON ITSELF SKIPS ON EVERY RESUME. MPD drops what it has already
// decoded when it pauses and carries on from the head of that buffer, which on
// this machine is 0.776 s of music gone per resume -- measured, and measured as
// a real skip rather than a reporting artefact, because the song then ends that
// much early. Hold a play/pause key down and the record races. `pause` freezes
// `elapsed` where the music stopped, so that value is an anchor and a resume
// that lands anywhere else is seeked back onto it: `_anchorPause`, from the
// status read, so a resume asked for by mpc is corrected too.
//
// A LIST IS QUEUED IN THE LIST'S OWN ORDER. `add <directory>` queues in the
// database's order and `findadd … sort <tag>` in one tag's, and neither is the
// order somebody put a list in -- so every list is resolved through the same
// function that LISTS it and queued as `add`s in that order. See `appendAlbum`.
//
// THE QUEUE IS RE-READ ONLY WHEN IT CHANGED. `status.playlist` is a version
// integer that MPD bumps on every mutation; `playlistinfo` on a 527-song queue
// is 7 500 lines through a QString signal per line. Comparing the version
// first is the difference between reading it once and reading it on every
// `changed: playlist` echo of our own edits.
//
// ALBUM ART IS NEVER PULLED THROUGH THE PROTOCOL. `albumart`/`readpicture`
// return raw binary inline, and Quickshell's SplitParser hands over QStrings —
// UTF-8 decoding would shred a JPEG. The cover is derived from the song's own
// `file` instead: same directory, `cover.jpg`.
//
// AND WHEN THE DIRECTORY HAS NONE, THE FILE ITSELF DOES. A directory of one
// album has a cover file and its songs share it; a directory of loose songs --
// `Tracks/`, the favourites -- has none and never will, because its 35 songs
// are 35 different records. Every one of them carries its own picture, though,
// and so do the cover-less `Albums/Loop Hero Soundtrack` mp3s. `AudioArt`
// extracts those to a cache directory, one file at a time, and `coverUrlFor`
// hands the result out as its FOURTH answer.
//
// BUT THE DIRECTORY IS ASKED WHETHER IT HAS ONE. Three of the forty directories
// in this library have no cover file — `Albums/Loop Hero Soundtrack`, `Tracks/`
// and the one playlist directory — which is 94 of the 527 songs, and handing
// out a url for a file that is not there makes `Cannot open:
// file:///home/user/Music/Albums/Loop Hero Soundtrack/cover.jpg` reach the
// console. `listfiles <dir>` lists a directory INCLUDING the files MPD does not
// recognise, so one command list at connect time answers it for the whole
// library (40 directories, 1 925 lines, 5.7 ms on the daemon). While that
// answer is in flight nothing guesses: an unknown directory hands out no url
// at all, and `_reseatDerived` fixes up whatever was built before it landed.
//
// AN ALBUM IS A DIRECTORY UNDER `Albums/`, AND NOTHING ELSE IS ONE. The library
// is `~/Music`, which holds `Albums/`, `Playlists/` and `Tracks/`; the last two
// are full of songs carrying the album tag of the record they were ripped from,
// so `list album` over the whole library answers 85 albums where the shelf
// holds 38. Every album, artist and genre query therefore carries MPD's own
// `(base 'Albums')`. Pushed to the daemon, not sieved here: the daemon answers
// the filtered query in the same 0.1 ms, and a row that is never built cannot
// leak into a grid through the one path somebody forgot to filter.
//
// THE LISTS TAB IS THE OTHER TWO DIRECTORIES. A playlist on this system is a
// DIRECTORY of songs under `Playlists/`, and `Tracks/` is one too — the loose
// songs, which the source calls favourites. So `playlists` is one synthetic
// entry for `Tracks/` followed by every directory under `Playlists/`, and
// MPD's own stored playlists after those. Three sources, one row shape, one
// `songsOfPlaylist`; nothing above this file knows which kind it is holding.
//
// RECENTLY PLAYED IS DERIVED, NOT STORED. The store is one `lastplayed` sticker
// per file and that is all. Everything above it — consecutive songs of one
// album folded into an album entry, the album that is still PLAYING shown with
// the songs of it that have finished — is computed from that list, the current
// song and the queue, and `recent` is a binding on that pure function. So there
// is no second state to keep in step: clear the queue and the prediction is
// gone on the next frame, because the prediction was never written down.
// =============================================================================
Item {
    id: root

    // ---- Configuration ------------------------------------------------------

    // The transport. Left null it makes its own (on `socketPath`, "" the
    // client's default); set it at construction to share one connection
    // between several views.
    property MpdClient client: null
    property string socketPath: ""

    // Where MPD's `music_directory` actually is, for turning a song's relative
    // `file` into a cover url.
    property string musicDir: (Quickshell.env("HOME") || "") + "/Music"

    // The three directories `~/Music` is made of, as properties rather than as
    // a literal in five filters. `albumsSubdir` is the one that decides what an
    // album IS; `tracksSubdir` is the loose songs, shown as a playlist called
    // `favoritesName` because that is what they are — a directory of songs
    // somebody chose — and `playlistsSubdir` holds one directory per playlist.
    property string albumsSubdir: "Albums"
    property string tracksSubdir: "Tracks"
    property string favoritesName: "Favorites"
    property string playlistsSubdir: "Playlists"

    // A LIST HAS NO COVER OF ITS OWN, so it wears its songs'. `listCoverCount`
    // is how many the row carries -- four, because the panel draws four as a
    // 2 x 2 grid and fewer than four as one picture -- and `listCoverProbe` is
    // how many of the list's songs may be ASKED for one. The two differ because
    // a list of loose songs answers out of the FILES (`AudioArt`, one process
    // each): a list whose first four songs share one album would otherwise
    // walk all thirty-five of them looking for a fourth distinct picture, and
    // pay for the walk. Past the probe the row shows what it found.
    property int listCoverCount: 4
    property int listCoverProbe: 12

    // What a directory's cover file may be called, in MPD's own order
    // (`albumart` looks for exactly these three). The first one a directory
    // actually holds is the one its songs point at.
    property var coverNames: ["cover.jpg", "cover.png", "cover.webp"]
    // Ask the daemon which directories have one. Off, every song of a
    // cover-less directory carries a url to a file that is not there, and
    // every Image pointed at it warns; the cost of it being on is one command
    // list per connection.
    property bool scanCovers: true

    // When a song's directory holds no cover file, read the picture out of the
    // FILE. One `ffmpeg -c copy` per file into a cache directory, gated on this
    // and cached on disk for good -- see AudioArt.qml. Off, a loose song has no
    // art at all.
    property bool embedArt: true

    // Hand out a SMALL COPY of every cover instead of the original. The scans in
    // the library are 1400-5000 px and Qt decodes a JPEG in full whatever
    // `sourceSize` says (~44 ms each, on the one reader thread every Image of the
    // process shares), which holds the vinyl's label behind the library's
    // rows and leaves the OSD's card blank for ~5 frames. One `ffmpeg` per cover,
    // once, into a cache directory -- see CoverThumbs.qml. Off, the originals.
    property bool thumbCovers: true

    // The artists shelf holds the artists that have an ALBUM under `Albums/`,
    // which is what "my artists" means when the shelf is what you browse. With
    // this on it also holds the ones that appear ONLY in `Tracks/` or in a
    // playlist directory — a song added to a list by somebody who owns nothing
    // else of theirs. It changes `artists`, and it widens `songsOfArtist` to
    // match: an artist listed because of a loose song has to open into it.
    property bool artistsIncludeLoose: false

    // The CD-player convention: `prev` restarts the current song once you are
    // this far into it, and only steps back before that. MPD itself has no
    // such rule — its `previous` at 31 s jumps to the previous
    // track — so it is ours to implement. 0: always the song before.
    property real prevRestartSec: 3

    // How far the daemon's elapsed may lag ours before we believe it over our
    // own clock. MPD's own granularity is ~0.27 s; this leaves room for that
    // plus the round trip.
    property real elapsedResyncSec: 0.75

    // ---- The resume that skips ---------------------------------------------
    //
    // MPD THROWS AWAY WHAT IT HAS ALREADY DECODED WHEN IT PAUSES, and carries
    // on from the head of that buffer when it resumes -- so every resume SKIPS
    // a piece of the music. Measured against this daemon (0.24.15, PipeWire
    // output): 0.776 s per resume, every time, whoever asks for it. It is a
    // real skip and not a reporting artefact -- twelve pause/resume cycles
    // inside one second advanced `elapsed` by 9.1 s, and the song then ENDED
    // 9.4 s early, so that audio was never played. That is "holding space
    // makes the progress go way faster" -- the clock is honest, the daemon is
    // eating the music.
    //
    // A CLIENT CANNOT STOP IT DROPPING THE BUFFER. It can put the position
    // back, and the reference it puts it back onto is THIS MODULE'S OWN CLOCK:
    // `_elapsed` is seated exactly at a pause, stops while paused and runs at
    // real time while playing, so it is where the position would be if nothing
    // had skipped. A resume that lands anywhere else is seeked onto it.
    //
    // THE SIZE OF THE SKIP CANNOT BE READ OFF THE RESUME. `status` arrives
    // about two milliseconds after the resume and the daemon's own number has
    // not finished moving: measured, it shows 0.50 s of a jump that is 0.76 s
    // thirty milliseconds later. Waiting for it to settle is not an option
    // either -- a held-down play/pause key toggles every 30 ms, so there is no
    // settled moment to read. So the lead is LEARNED instead of measured: the
    // seek uses the best estimate there is, and the next PAUSE says how far
    // wrong it was, because at a pause the daemon's frozen number and this
    // module's clock are two readings of the same instant and their difference
    // is the whole residual. One correction per cycle, one measurement per
    // cycle, and it converges on the first one.
    //
    // Measured over 30 rapid toggles: the position advanced 3.9 s (uncorrected
    // 11.5 s) with the estimate taken from the resume alone, and 0.7 s with the
    // estimate learned -- against 0.9 s of wall clock, which is what "it did
    // not race" means.
    //
    // IT CORRECTS ANY RESUME, not only one this module asked for: the
    // transition is read off `status`, so a resume from mpc or another
    // frontend is put back too.
    property bool losslessResume: true
    // What counts as a skip worth a seek. `elapsed` moves in whole decoder
    // chunks (~0.26 s here), so anything under that is quantisation rather than
    // a jump; anything bigger than `maxResumeSkip` is something else moving the
    // song and is left where it is.
    property real resumeSkipMin: 0.35
    property real maxResumeSkip: 3
    // The deadband on the LEARNING, which is a finer question than the one
    // above: a correction that lands within this of the clock is right, and
    // chasing the chunk boundary would only make the estimate twitch.
    property real resumeLearnMin: 0.08
    // How long the clock stays on its own trajectory after a resume, waiting
    // for the daemon to settle and be measured. It is released early by the
    // next pause, by a song change and by a stop; the bound is only so that a
    // resume followed by an hour of playing cannot pin it for ever.
    property int resumeHoldMs: 400

    // Biased-shuffle knobs, passed straight to MpdShuffle.
    property int shuffleArtistGap: 3
    property int shuffleAlbumGap: 2
    property int shuffleTries: 40

    // WHAT COUNTS AS A RECORD -- how forgiving `_findAlbumRun` is about the
    // block of album it needs to find in the queue before the vinyl treats
    // what is playing as a record it could turn over. All three err towards
    // NOT finding one: a flip that should not have happened is the fault a
    // user reports, a flip that did not happen is one nobody notices.
    //   coverage  how much of the album has to be queued (0.75 = nine songs of
    //             a twelve, so two unreadable files still leave a record while
    //             three songs picked out of it do not)
    //   density   songs of the album over the span they occupy (0.8 = at most
    //             one foreign song in five), which is what stops an album
    //             shuffled THROUGH a queue of other songs from reading as one
    //   gap       foreign songs in a row the block may step over, which is
    //             what keeps a "play next" dropped into a record from cutting
    //             it in two
    //   min       songs of the record that have to be in the queue before it
    //             is a record at all -- a run of ONE song is never an album,
    //             however complete the tags on it are
    property real albumRunCoverage: 0.75
    property real albumRunDensity: 0.8
    property int albumRunGap: 2
    property int albumRunMin: 2

    property bool debug: false

    // ---- State (read-only; written from status / currentsong) ---------------
    readonly property bool connected: root._client ? root._client.connected : false
    // MPD is walking the library right now (`status.updating_db`). A rescan is
    // the one library operation with a visible duration, so the button that
    // starts it has something to say while it runs.
    readonly property bool updating: root._updating
    readonly property string playState: root._playState          // play|pause|stop
    readonly property bool playing: root._playState === "play"
    readonly property int songId: root._songId                   // -1 when none
    readonly property int songPos: root._songPos                 // -1 when none
    readonly property real duration: root._duration              // seconds
    // Seconds. LIVE while something holds the clock (`tickHolds` > 0), else as of the last
    // status read and caught up to the wall clock by the next reader (see the header).
    readonly property real elapsed: root._elapsed
    // How many holders keep the interpolator running, and whether it runs (a probe's readouts).
    readonly property int tickHolds: root._tickHoldCount
    readonly property bool ticking: _tick.running
    readonly property real volume: root._volume                  // 0..1

    readonly property bool repeatOn: root._repeatOn
    readonly property bool randomOn: root._randomOn
    // `single` and `consume` are tri-state on the wire: "0" | "1" | "oneshot".
    // The booleans are the common reading; the raw mode is there for a pill
    // that wants to show the third state.
    readonly property bool singleOn: root._singleMode !== "0"
    readonly property bool consumeOn: root._consumeMode !== "0"

    readonly property int bitrate: root._bitrate                 // kbps, live (moves through a song)
    // mpd's own `status.error` ("" when none): the last playback failure, kept by the daemon until
    // `clearerror` or the next play.
    readonly property string statusError: root._statusError
    // The health check (MpdHealth.qml): what is wrong with the sound, in words, and the one click that
    // cures it. `health` is the banner's object; only a watched player (a clock holder) looks at all.
    readonly property var health: root._health.snapshot
    function healthRun(id) { root._health.run(id); }
    function healthCheck() { root._health.checkAgain(); }
    function healthDismiss() { root._health.dismiss(); }
    readonly property string audioFormat: root._audioFormat      // "96000:24:2"
    readonly property var current: root._current                 // song object|null
    readonly property var fidelity: root._fidelity               // tier object|null
    readonly property var queue: root._queue                     // [song object]
    readonly property int queueLength: root._queueLength

    // HOW FAR THROUGH THE RECORD ON THE PLATTER, 0..1, and 0 whenever there is
    // no record on it. The vinyl's mid-album flip is driven by this number and
    // by nothing else, so what it MEANS is the whole of the rule -- see
    // `_findAlbumRun`, which is where the reasoning is written down:
    //
    //   * A record is on the platter because an ALBUM is playing. An album is
    //     a directory under `albumsSubdir` whose songs agree about their album
    //     tag, and most of it has to be in the queue in one block. A playlist
    //     of loose songs is not an album however complete the tags on any one
    //     of them are, and a run of one song is never an album.
    //   * The position is a position IN THE QUEUED RUN, not in the album the
    //     tags claim -- that is what makes a shuffled album turn over at the
    //     middle song of its own shuffled order.
    //   * The length is the record's REAL length, which is how many songs the
    //     daemon has in that directory.
    //   * Nothing playing is no progress. An album sitting in a queue nobody
    //     has started reads 0, never 1.
    readonly property real albumProgress: root._albumProgress    // 0..1

    // ---- Library (lazy, cached) ---------------------------------------------
    // [{albumArtist, album, albumArtists, date, coverUrl, songCount, dirUri,
    //   dirPath, genre}]
    // `albumArtist` is the primary credit and is safe to send back in a
    // filter; `albumArtists` is every credit, for a row that wants to show
    // them all. `genre` is the album's main genre — the first MPD reports for
    // it — and it is here because the library colours an album's header by it
    // and would otherwise have to ask per row.
    readonly property var albums: root._albums
    // [{name, albumCount, songCount, genre, loose}] — `genre` is the one this
    // artist has the most songs of, which is what their header is coloured by,
    // and `loose` marks an artist who is here only because of a song in
    // `Tracks/` or in a playlist (so `albumCount` is 0 and a row can say
    // "3 tracks" instead of "0 albums"). A pure function of the two shelves
    // and the flag, so turning the flag off cannot leave a loose artist
    // behind: there is no second list to keep in step.
    readonly property var artists: root._mergeArtists(root._artists, root._looseArtists,
                                                      root.artistsIncludeLoose)
    // [{name, songCount, albumCount}] — case-folded, so the library's
    // "SoundTrack" and "Soundtrack" are one genre with 247 songs and not two.
    readonly property var genres: root._genres
    readonly property bool libraryLoading: root._libraryLoading
    // What has been played, newest first, and what lists there are to play.
    // Neither is something MPD keeps on its own.
    //
    // `recent` entries are `{kind: "album"|"song", playedAt, key, …}`: an album
    // entry carries `{albumArtist, album, coverUrl, songs, songCount, partial,
    // predicted}` with `songs` in the order they were played, and a song entry
    // is a plain song object with those three list fields added. `key` is what
    // `removeRecent` takes back. It is a BINDING on a pure function of the
    // sticker list, the current song and the queue — see `_groupRecent`.
    //
    // A RUN PLAYED FROM A LIST IS AN ALBUM ENTRY TOO: same `kind`, same header
    // with its songs under it, and the list's own name in `album`. Where it
    // came from is a FIELD -- `list` is the list's name and "" on an album run,
    // `listCovers` is the 2 x 2 the lists tab wears, and `listIndex` runs
    // parallel to `songs` with each one's place in the list, which is what
    // survives it being played shuffled. Zero there means "no place of its
    // own", which is every song of an album run: its number is its track tag.
    readonly property var recent: root._groupRecent(root._recentSongs, root._currentFile,
                                                    root._predictKey, root._albumCounts,
                                                    root._predictListKey, root._playlists)
    // [{name, uri, kind: "songdir"|"stored", synthetic, songCount, modified}]
    readonly property var playlists: root._playlists
    // How many ENTRIES `recent` shows, and how many played songs are resolved
    // to build them. The second is the expensive one — every song needs a
    // record, and a record is a `find` — so it is a window on the sticker
    // database rather than the whole of it. An album of sixteen songs is one
    // entry built out of sixteen of the second number.
    property int recentLimit: 40
    property int recentSongLimit: 120
    // Shuffle as a MODE over the queue's order, rather than MPD's `random`.
    // The shuffle spaces artists and albums out, and
    // MPD's random would pick its own order over the top of any we impose. While
    // this is on, anything added to the queue is shuffled in.
    readonly property bool shuffleMode: root._shuffleMode
    readonly property bool libraryLoaded: root._libraryLoaded

    // ---- Signals ------------------------------------------------------------
    // A different song is current. The property change signals cover every
    // other transition; this one exists because the vinyl's whole opening
    // choreography hangs off it and "songId changed" reads as an accident —
    // and because it is the only one emitted with `current` and `fidelity`
    // ALREADY describing the new song. The automatic `songIdChanged` fires
    // halfway through applying a status read, when `current` is still the
    // previous track; a handler that wants the cover must use this one.
    signal songChanged(int songId)

    // A file's embedded picture is now known -- `url` is "" when the file holds
    // none. The records already handed out are rewritten a moment after it
    // (`_reseatDerived`, debounced so a list resolving thirty-five files does
    // not rebuild thirty-five times), so a binding on `current` / `queue` /
    // `albums` needs nothing from this; it is for anything holding a file name
    // of its own rather than a record.
    signal coverArtResolved(string file, string url)

    // =========================================================================
    // Controls. All fire-and-forget: the daemon echoes every one of them back
    // through idle, and that echo is what moves the state. The two exceptions
    // are `seek` and `setVolume`, which update locally first — a scrub that
    // waits a round trip for the ball to follow the finger feels broken.
    // =========================================================================

    function play() {
        root._send(root._playState === "pause" ? "pause 0" : "play");
    }
    function pause() {
        if (root._playState === "play") root._send("pause 1");
    }
    function toggle() {
        // Bare `pause` toggles, but only between play and pause; from stop it
        // does nothing at all, which is not what a play/pause button means.
        if (root._playState === "stop") root._send("play");
        else root._send("pause");
    }
    function stop() {
        root._send("stop");
    }
    function next() {
        // `next`/`previous` ACK with "Not playing" when stopped. Guarding here
        // keeps that out of `lastError`, where it would look like a fault.
        if (root._playState !== "stop") root._send("next");
    }
    function prev() {
        if (root._playState === "stop") return;
        // The rule reads the position as it is NOW: with nothing holding the
        // clock (a media key, no popup) it has not been advancing.
        root._catchUp();
        if (root.prevRestartSec > 0 && root._elapsed >= root.prevRestartSec && root._songId >= 0) {
            // seekid, not seekcur: the song could change between the status
            // read this decision used and the command landing.
            root._forceSeat = true;
            root._putElapsed(0);
            root._send("seekid " + root._songId + " 0");
        } else {
            root._send("previous");
        }
    }

    function seek(sec) {
        if (root._playState === "stop" || root._songId < 0) return;
        let t = Math.max(0, Number(sec) || 0);
        if (root._duration > 0) t = Math.min(t, root._duration);
        root._forceSeat = true;
        root._putElapsed(t);
        root._send("seekid " + root._songId + " " + t.toFixed(3));
    }
    function seekFrac(f) {
        if (!(root._duration > 0)) return;
        root.seek(Math.max(0, Math.min(1, Number(f) || 0)) * root._duration);
    }

    function setVolume(v01) {
        if (!root._hasMixer) return;
        const v = Math.max(0, Math.min(1, Number(v01) || 0));
        root._volume = v;
        root._send("setvol " + Math.round(v * 100));
    }

    function setRepeat(b) { root._send("repeat " + (b ? 1 : 0)); }
    function setRandom(b) { root._send("random " + (b ? 1 : 0)); }
    function setSingle(b) { root.setSingleMode(b ? "1" : "0"); }
    function setConsume(b) { root.setConsumeMode(b ? "1" : "0"); }
    // The tri-state form, for a pill that offers "oneshot".
    function setSingleMode(mode) { root._send("single " + root._modeArg(mode)); }
    function setConsumeMode(mode) { root._send("consume " + root._modeArg(mode)); }

    function playId(id) { root._send("playid " + Math.round(id)); }
    function removeId(id) { root._send("deleteid " + Math.round(id)); }
    function clearQueue() { root._send("clear"); }
    function moveQueue(from, to) {
        if (from === to) return;
        root._send("move " + Math.round(from) + " " + Math.round(to));
    }

    // One song, from nowhere in particular. Whatever list it was last queued
    // from, this is not that: the origin goes, so the play it leads to is a
    // standalone entry in the played list.
    function appendUri(uri) {
        root._clearListOrigin(uri);
        root._send("add " + root._q(uri));
    }
    function playNextUri(uri) {
        root._clearListOrigin(uri);
        // `+0` is "right after the current song"; with no current song MPD
        // answers ACK [55] "No current song", so plain append is the fallback.
        root._keepOrderOnce = true;
        if (root._songId >= 0) root._send("addid " + root._q(uri) + " +0");
        else root._send("add " + root._q(uri));
    }
    // A song picked to be HEARD NOW -- a click on its row in the library.
    //
    // With something under the needle (playing or paused) it goes in right after
    // it and `next` steps onto it. With nothing playing it cannot: `next` and
    // `previous` are refused when stopped ("Not playing", guarded off in `next()`
    // above), so `playNextUri` + `next()` would queue the song and then do nothing
    // at all -- an album that has run out, a queue that was cleared, a stop
    // pressed by hand: the record would come in and the music never start. So the song
    // is appended and THAT entry is played, by the id MPD answers `addid` with
    // (a position would be a guess about a queue another client may have moved).
    function playUriNow(uri) {
        root._clearListOrigin(uri);
        if (root._playState !== "stop") {
            root.playNextUri(uri);
            root.next();
            return;
        }
        if (!root._client) return;
        root._client.send("addid " + root._q(uri), (ok, lines) => {
            const id = ok ? root._int(root._client.parseKV(lines || []).Id, -1) : -1;
            if (id >= 0) root._send("playid " + id);
        });
    }

    // ---- Queueing a list, IN THE LIST'S OWN ORDER ---------------------------
    //
    // `add <directory>` and `findadd … sort <tag>` both queue in the DAEMON's
    // order, and the daemon's order is not the list's. `add` on a directory
    // walks the database, which is sorted by uri, so `Tracks/` comes out
    // alphabetically by artist; `sort` orders by ONE tag, so a genre of eight
    // albums comes out as every album's track 1, then every album's track 2,
    // and the one two-disc album on this shelf comes out 1-1, 2-1, 1-2, 2-2.
    //
    // A list somebody made has an order of its own and it is the only order
    // that means anything:
    //
    //   Favorites (`Tracks/`)  the file's own mtime, NEWEST FIRST -- those
    //                          files were downloaded in the order they were
    //                          favourited, which is what `lastModified` is
    //   a playlist directory   the `NN.` at the head of the file's own name
    //   a stored playlist      the playlist's own, which is the file's own
    //   an album               disc, then track
    //   a genre                album by album, each in disc/track order
    //
    // So every one of them is RESOLVED first -- through the same
    // `songsOfAlbum` / `songsOfGenre` / `songsOfPlaylist` the panel LISTS them
    // with, so what is queued and what is shown can never disagree -- and then
    // queued as one command list of `add`s in that order.
    //
    // AND SHUFFLE IS WHAT FILLS IT. The mode reorders the collection on its way
    // IN -- see `_queueSongs`, which is the only door -- so the list's own
    // order stands exactly when the mode is off.
    function appendAlbum(albumArtist, album) {
        root.songsOfAlbum(albumArtist, album, songs => root._queueSongs(songs, false, false));
    }
    function playAlbum(albumArtist, album) {
        root.songsOfAlbum(albumArtist, album, songs => root._queueSongs(songs, true, true));
    }
    // The album in the queue's place, not started: the popup starts it when its record is down.
    function loadAlbum(albumArtist, album) {
        root.songsOfAlbum(albumArtist, album, songs => root._queueSongs(songs, true, false));
    }

    // The one place a resolved list becomes queue entries. One command list,
    // in the order handed in; `clear` and `play` ride in the same list so a
    // replace is one round trip and the queue is never briefly empty.
    //
    // AN EMPTY ANSWER CHANGES NOTHING, replace or not. A list that resolved to
    // nothing is a query that failed or a directory that has been emptied, and
    // wiping the queue for it is the one outcome nobody asked for.
    //
    // AND THIS IS WHERE SHUFFLE DOES ITS JOB: it works on any collection
    // of audio files (albums, lists, genres, ...) when adding them to the
    // queue. Every collection comes through here, so the mode is applied here,
    // once, to what is ARRIVING -- and the list's own order stands untouched
    // when the mode is off.
    //
    // IT CANNOT BE LEFT TO `_readQueue`'s growth rule. `playAlbum` is
    // `clear` + the adds + `play` in ONE command list: the queue it publishes
    // is no longer than the one it replaced, so nothing GREW, and the `play`
    // seats the first song SENT -- which a re-spread arriving a round trip
    // later can no longer move. The two halves do different jobs: this one
    // orders what is coming in, the growth rule mixes it with what was already
    // waiting.
    function _queueSongs(songs, replace, thenPlay, listName) {
        const src = songs || [];
        if (src.length === 0) return;
        // The LIST's own order is the numbering, so it is read off what was
        // handed in, before the mode is allowed to reorder anything.
        root._markListOrigin(src, listName || "");
        const l = root._shuffleMode && src.length > 1 ? root._shuffled(src) : src;
        const cmds = [];
        if (replace) cmds.push("clear");
        for (let i = 0; i < l.length; i++) {
            if (!l[i] || !l[i].file) continue;
            cmds.push("add " + root._q(l[i].file));
        }
        if (cmds.length === (replace ? 1 : 0)) return;
        if (thenPlay) cmds.push("play");
        root._sendAll(cmds, null);
    }

    // The biased shuffle, applied to the queue in place. The currently playing
    // song is pinned to the front rather than thrown into the draw: shuffling
    // it away from under the needle would restart playback, and every player
    // that has ever shipped shuffles what is COMING.
    //
    // It is applied as `moveid`s, not clear+re-add: ids survive a move, so the
    // queue view can animate rows to their new places instead of watching the
    // whole list disappear and come back. Only the moves that actually change
    // something are sent — the target order is simulated first.
    function shuffleQueue() {
        const q = root._queue || [];
        if (q.length < 2) return;
        for (let k = 0; k < q.length; k++) {
            if (!(q[k].id >= 0)) {
                // No stable ids to move by (a queue read that never landed).
                // MPD's own uniform shuffle is a worse result than ours but a
                // better one than nothing.
                root._send("shuffle");
                return;
            }
        }
        const head = [];
        let rest = q;
        if (root._songId >= 0) {
            rest = [];
            for (let i = 0; i < q.length; i++) {
                if (q[i].id === root._songId) head.push(q[i]);
                else rest.push(q[i]);
            }
        }
        const order = head.concat(root._shuffled(rest));
        const live = [];
        for (let j = 0; j < q.length; j++) live.push(q[j].id);
        const cmds = [];
        for (let p = 0; p < order.length; p++) {
            const id = order[p].id;
            const at = live.indexOf(id);
            if (at === p) continue;
            cmds.push("moveid " + id + " " + p);
            live.splice(at, 1);
            live.splice(p, 0, id);
        }
        root._sendAll(cmds);
    }

    // The origin map, rewritten rather than mutated: `recent` is a binding on a
    // pure function and a map edited in place changes nothing anybody notices.
    function _markListOrigin(songs, name) {
        const src = songs || [];
        if (src.length === 0) return;
        const m = ({});
        const keys = Object.keys(root._listOrigin);
        for (let k = 0; k < keys.length; k++) m[keys[k]] = root._listOrigin[keys[k]];
        for (let i = 0; i < src.length; i++) {
            if (!src[i] || !src[i].file) continue;
            if (name) m[src[i].file] = { name: name, index: i + 1 };
            else delete m[src[i].file];
        }
        root._listOrigin = m;
    }
    function _clearListOrigin(uri) {
        const f = String(uri || "");
        if (f === "" || root._listOrigin[f] === undefined) return;
        root._markListOrigin([{ file: f }], "");
    }

    // The biased shuffle with this module's knobs on it, in ONE place: the fill
    // and the re-spread are the same mode and must not be able to disagree.
    function _shuffled(songs) {
        return Shuffle.shuffled(songs || [], {
            minArtistGap: root.shuffleArtistGap,
            minAlbumGap: root.shuffleAlbumGap,
            tries: root.shuffleTries
        });
    }

    // Force a full re-read. Nothing in normal operation needs this — idle does
    // it — but a host that just connected a stub, or a probe, does.
    function refresh() {
        root._queueVersion = -1;
        root._readState();
    }

    // ---- Library ------------------------------------------------------------

    // Shuffle as a mode: see `shuffleMode`.
    function setShuffleMode(on) {
        root._shuffleMode = !!on;
        if (root._shuffleMode)
            root.shuffleQueue();
    }

    // The lists tab. Three sources, one row shape:
    //
    //   Favorites          `Tracks/` — the loose songs, first and `synthetic`
    //   a playlist         one directory under `Playlists/`
    //   a stored playlist  MPD's own, from `listplaylists`
    //
    // The first two are directories of songs, which is what a playlist is on
    // this system; the third is kept because a playlist saved from any other
    // client is still a playlist and asking costs one command. Refreshed by
    // `stored_playlist` and by `database` — a directory dropped into
    // `Playlists/` appears as soon as MPD has walked it.
    //
    // THE ORDER OF THE TWO COMMANDS IS THE ERROR HANDLING. `lsinfo` on a
    // directory that does not exist ACKs, and an ACK aborts a command list at
    // the failing command — so the one that can fail goes LAST, the groups that
    // did arrive are used, and a machine with no `Playlists/` still gets its
    // stored playlists and its Favorites. `ok` is deliberately not trusted.
    function loadPlaylists() {
        root._playlistsWanted = true;
        if (!root.connected) return;
        root._sendAll(["listplaylists", "lsinfo " + root._q(root.playlistsSubdir)],
                      (ok, groups) => root._playlistsPhase1(groups || []));
    }

    // The songs of any of the three kinds. A directory playlist is a `find`
    // under its base; a stored one is `listplaylistinfo`. A name this file has
    // never heard of is assumed to be a stored playlist.
    function songsOfPlaylist(name, cb) {
        if (!root.connected) {
            if (cb) cb([]);
            return;
        }
        const e = root._playlistEntry(name);
        if (e && e.kind === "songdir") {
            // `find` answers in the database's order; the LIST's order is put
            // on top of it. File name first, so the numbers only ever have to
            // break a tie they can actually break.
            root._findSongs(root._baseArg(e.uri), songs => {
                if (cb) cb(root._listOrder(songs, e));
            }, "file");
            return;
        }
        root._client.send("listplaylistinfo " + root._q(name), (ok, lines) => {
            if (!ok) {
                if (cb) cb([]);
                return;
            }
            const recs = root._client.parseObjects(lines, "file");
            const out = [];
            // A stored playlist's ORDER is the playlist, so it is not sorted.
            for (let i = 0; i < recs.length; i++)
                out.push(root._songOf(recs[i]));
            if (cb) cb(out);
        });
    }

    // Every song of a genre, across the albums that carry it. Case-folded and
    // album-rooted like everything else the library shows.
    function songsOfGenre(name, cb) {
        root._findSongs(root._genreFilter(name), cb, "album");
    }

    // The albums under a genre — the middle level of genre -> album -> song.
    // Answered from the shelf rather than from the daemon: the album rows are
    // already built, already merged across double credits and already carry
    // the cover and the song count a header needs, and a second query would be
    // a second truth. A call made before the library is loaded is a standing
    // request, honoured when it lands.
    function albumsOfGenre(name, cb) {
        if (!cb) return;
        if (root._libraryLoaded) { cb(root._albumsOfGenreNow(name)); return; }
        root._genreWaiters = root._genreWaiters.concat([{ name: name, cb: cb }]);
        root.loadLibrary();
    }

    // A list queued whole. A directory playlist is resolved first, because
    // `add <directory>` would queue it in the database's order -- which for
    // Favorites is alphabetical by artist and for a numbered playlist is only
    // accidentally the numbering. A STORED playlist keeps `load`: MPD's own
    // command for MPD's own object, and its order IS the playlist file's.
    //
    // EITHER KIND IS A LIST, so either kind records where its songs came from:
    // a stored playlist is resolved as well, and only for that -- `load` still
    // does the queueing, because the order it queues in is the playlist file's
    // and asking for it twice would be two truths. The resolve is one command
    // and it happens once per list queued.
    function playPlaylist(name) {
        const e = root._playlistEntry(name);
        if (e && e.kind === "songdir") {
            root.songsOfPlaylist(name, songs => root._queueSongs(songs, true, true, name));
            return;
        }
        root.songsOfPlaylist(name, songs => root._markListOrigin(songs, name));
        root._sendAll(["clear", "load " + root._q(name), "play"], null);
    }
    function appendPlaylist(name) {
        const e = root._playlistEntry(name);
        if (e && e.kind === "songdir") {
            root.songsOfPlaylist(name, songs => root._queueSongs(songs, false, false, name));
            return;
        }
        root.songsOfPlaylist(name, songs => root._markListOrigin(songs, name));
        root._send("load " + root._q(name));
    }

    // A genre, queued whole. Resolved rather than `findadd`-ed for the reason
    // above: `sort Track` across eight albums interleaves them, and a genre is
    // meant to play album by album.
    function appendGenre(name) {
        root.songsOfGenre(name, songs => root._queueSongs(songs, false, false));
    }
    function playGenre(name) {
        root.songsOfGenre(name, songs => root._queueSongs(songs, true, true));
    }

    // MPD's `rescan`, not `update`: `update` skips files whose timestamp has
    // not moved, and the reason to press this button is that the database is
    // wrong about something it thinks it already knows. The daemon answers
    // with a job id, sets `updating_db` in `status`, and fires `database` when
    // it has finished — which is what reloads the shelf, so nothing here has
    // to wait for anything.
    function rescanLibrary() {
        root._send("rescan");
    }

    // What has been played. MPD has no such list, so the module keeps one in
    // the sticker database: a timestamp per file, written as each song starts.
    // Stickers survive a restart and belong to the daemon, so the list is the
    // same whichever client wrote it -- which is what "recently played" has to
    // mean on a shared daemon.
    //
    // TWO STEPS, AND THE SECOND IS CACHED. The daemon sorts and windows the
    // stickers itself (`sort -value_int window 0:N`); a file then needs its
    // RECORD, and a record is a `find` each. A sticker is written on every song
    // change, so re-resolving the whole window every three minutes would be the
    // module's most expensive habit — records are kept by file until the
    // database moves under them, and a track change then costs one `find`.
    //
    // What comes out of here is the raw played list. The GROUPING — albums,
    // the prediction, the limit — is `_groupRecent`, and `recent` is a binding
    // on it, so nothing has to remember to regroup when the queue changes.
    // TWO FINDS, ONE ROUND TRIP: when each file was played, and what the play
    // was part of. The second is not windowed -- there is no order to window it
    // by, and it holds one row per file the first one holds, since the two are
    // written together.
    function loadRecent() {
        root._recentWanted = true;
        if (!root.connected) return;
        root._sendAll(["sticker find song \"\" " + root.stickerName
                       + " sort -value_int window 0:" + Math.max(1, root.recentSongLimit),
                       "sticker find song \"\" " + root.listStickerName],
                      (ok, groups) => root._recentStickers(ok, groups || []));
    }

    // Forget one entry of `recent`, by the `key` the entry carries. An album
    // forgets every song under it, which is what removing an album from a list
    // of played songs has to mean.
    function removeRecent(kind, key) {
        const list = root.recent || [];
        const files = [];
        for (let i = 0; i < list.length; i++) {
            const e = list[i];
            if (e.key !== key) continue;
            if (kind && e.kind !== kind) continue;
            if (e.kind === "album") {
                for (let j = 0; j < e.songs.length; j++) files.push(e.songs[j].file);
            } else if (e.file) {
                files.push(e.file);
            }
        }
        root._forgetPlayed(files, root._listStickered(files));
    }

    // Which of these files actually carry a `lastlist` sticker. A delete for a
    // sticker that is not there ACKs and takes the rest of the command list
    // with it, and a file played before this module wrote the second sticker
    // has only the first.
    function _listStickered(files) {
        const rows = root._recentSongs || [];
        const has = ({});
        for (let i = 0; i < rows.length; i++)
            if (rows[i].hasList && rows[i].song) has[rows[i].song.file] = 1;
        const out = [];
        const f = files || [];
        for (let j = 0; j < f.length; j++)
            if (has[f[j]] !== undefined) out.push(f[j]);
        return out;
    }

    // Forget all of it. Everything in the sticker database, not just the
    // window that is on screen: the button says clear, and leaving the rest
    // behind would make the list refill itself from underneath the moment it
    // was emptied.
    function clearRecent() {
        root._recentSongs = [];
        if (!root.connected) return;
        // Both names asked for, so both are cleared to exactly what is there:
        // a `lastlist` left behind would put a song in a list it was never
        // played as part of the next time it is played on its own.
        root._sendAll(["sticker find song \"\" " + root.stickerName,
                       "sticker find song \"\" " + root.listStickerName],
                      (ok, groups) => {
                          if (!ok) return;
                          root._forgetPlayed(root._stickerFiles((groups || [])[0]),
                                             root._stickerFiles((groups || [])[1]));
                      });
    }

    // The files a `sticker find` answered with.
    function _stickerFiles(lines) {
        const recs = root._client.parseObjects(lines || [], "file");
        const out = [];
        for (let i = 0; i < recs.length; i++) {
            const f = root._client.first(recs[i].file);
            if (f) out.push(f);
        }
        return out;
    }

    // Two phases, because MPD cannot answer it in one.
    //   1. three questions in one command list, all rooted at `Albums/`: the
    //      album tree (`list album … group albumartist`, 1.7 KB / 0.1 ms), the
    //      genre histogram (`count … group genre`), and each album's genre
    //      (`list genre … group albumartist group album`, 118 lines).
    //   2. one `count` and one `find … window 0:1` per album, in a single
    //      command list: the song count, and one file to hang the date, the
    //      cover url and the directory off.
    // The alternative, `listallinfo`, is 188 KB and 7 599 lines — the daemon
    // does it in 1.4 ms and QML spends far longer than that emitting them.
    //
    // `group date` is NOT asked for, though it would save the finds: it groups
    // by the tag, so an album whose tracks disagree about their date splits
    // into two albums. The date comes off the first track instead, which is
    // the one a UI would show anyway.
    function loadLibrary() {
        // Recorded before the guards, so a call made while the client is down
        // is a standing request rather than a no-op: `_onReady` honours it.
        root._libraryWanted = true;
        // Recently-played and the lists are readings of the same panel;
        // asking for the library is asking for all five tabs.
        root.loadRecent();
        root.loadPlaylists();
        if (root.artistsIncludeLoose) root._loadLooseArtists();
        if (root._libraryLoading || !root.connected) return;
        root._libraryLoading = true;
        // Three questions, one round trip, all three rooted at `Albums/`:
        // the album tree, the genre histogram, and which genre each album is.
        // The third is what lets a library colour an album header by its genre
        // and nest genre -> album -> song without a query per row; it is 118
        // lines for this collection.
        const base = root._baseArg(root.albumsSubdir);
        root._sendAll(["list album " + base + " group albumartist",
                       "count " + base + " group genre",
                       "list genre " + base + " group albumartist group album"],
                      (ok, groups) => root._libraryPhase1(ok, groups));
    }

    // ---- Library: search, details, play next -------------------------------------------------------
    // Songs whose title, artist or album contains `q` (case-insensitive, the daemon's `search`), over the
    // WHOLE music directory -- the favourites and the lists are songs too -- capped at `limit`.
    function searchSongs(q, cb, limit) {
        const t = String(q || "").trim();
        if (t === "") { if (cb) cb([]); return; }
        if (!root._client || !root._client.connected) { if (cb) cb([]); return; }
        // MPD's filter language has AND and NOT but no OR: one search per tag, in one command list, merged
        // by file with the title hits first.
        const v = root._fv(t);
        const cap = Math.max(1, limit || 60);
        const cmds = ["Title", "Artist", "Album"].map(tag => "search \"(" + tag + " contains '" + v + "')\" window 0:" + cap);
        root._client.sendAll(cmds, (ok, groups) => {
            const out = [];
            const seen = ({});
            if (ok) {
                for (let g = 0; g < groups.length && out.length < cap; g++) {
                    const recs = root._client.parseObjects(groups[g] || [], "file");
                    for (let i = 0; i < recs.length && out.length < cap; i++) {
                        if (seen[recs[i].file]) continue;
                        seen[recs[i].file] = true;
                        out.push(root._songOf(recs[i]));
                    }
                }
            }
            if (cb) cb(out);
        });
    }

    // Everything the daemon knows about one file: the song, and its other tags verbatim
    // ({ Composer: "…", Label: "…" }), for the details sheet.
    function songInfo(uri, cb) {
        root._findSongs("\"(file == '" + root._fv(uri) + "')\"", songs => {
            const so = songs.length > 0 ? songs[0] : null;
            if (!so) { if (cb) cb(null); return; }
            const tags = ({});
            const rec = so._rec || {};
            const skip = { file: 1, Id: 1, Pos: 1, "Last-Modified": 1, Format: 1, duration: 1, Time: 1 };
            for (const k in rec) if (!skip[k]) tags[k] = root._client.joined(rec[k]);
            delete so._rec;
            if (cb) cb({ song: so, tags: tags, lastModified: rec["Last-Modified"] || "" });
        }, "file", true);
    }

    // An album page's facts, from its songs: total length, discs, years, the formats it holds
    // (a mixed album says so), the label if any tag carries one. { songs, duration, discs, year,
    // genre, label, formats: ["FLAC 24-bit 44.1 kHz"], mixed: bool }.
    function albumInfo(albumArtist, album, cb) {
        root._findSongs(root._albumFilter(albumArtist, album) + " sort Track", songs => {
            let dur = 0;
            const discs = ({});
            const fmts = ({});
            const order = [];
            let label = "";
            let genre = "";
            let year = 0;
            for (let i = 0; i < songs.length; i++) {
                const so = songs[i];
                dur += so.duration || 0;
                discs[so.disc || 1] = true;
                const y = root._yearOf(so.date);
                if (y > 0 && (year === 0 || y < year)) year = y;
                if (!genre && so.genre) genre = so.genre;
                if (!label && so._rec && so._rec.Label) label = root._client.joined(so._rec.Label);
                // `Format` is in a database record only once the file has been decoded; the extension is always there.
                const fx = Fidelity.classify(so.format, 0, so.file);
                const key = fx.label || Fidelity.codecOf(so.file);
                if (key && !fmts[key]) { fmts[key] = true; order.push(key); }
                delete so._rec;
            }
            if (cb) cb({ songs: songs, duration: dur, discs: Object.keys(discs).length, year: year,
                         genre: genre, label: label, formats: order, mixed: order.length > 1 });
        }, "track", true);
    }

    // PLAY NEXT: right after the song under the needle, in the order given, and the order is KEPT even
    // while shuffle is a mode (the growth rule below would otherwise re-spread a queue the user just
    // ordered by hand). With nothing under the needle it appends: `+0` is refused ("No current song").
    function playNextSongs(songs) {
        const src = (songs || []).filter(x => x && x.file);
        if (src.length === 0) return;
        const cmds = [];
        for (let i = 0; i < src.length; i++) {
            root._clearListOrigin(src[i].file);
            cmds.push(root._songId >= 0 ? "addid " + root._q(src[i].file) + " +" + i : "add " + root._q(src[i].file));
        }
        root._keepOrderOnce = true;
        root._sendAll(cmds, null);
    }
    function playNextAlbum(albumArtist, album) {
        root.songsOfAlbum(albumArtist, album, songs => root.playNextSongs(songs));
    }
    function playArtist(name) {
        root.songsOfArtist(name, songs => root._queueSongs(songs, true, true));
    }
    function playNextArtist(name) {
        root.songsOfArtist(name, songs => root.playNextSongs(songs));
    }
    // Albums an artist has, off the shelf (the page's list): every album that credits them.
    function albumsOfArtist(name) {
        const out = [];
        const all = root._albums || [];
        for (let i = 0; i < all.length; i++) {
            const c = all[i].albumArtists || [all[i].albumArtist];
            if (c.indexOf(name) >= 0) out.push(all[i]);
        }
        return out;
    }

    function songsOfAlbum(albumArtist, album, cb) {
        root._findSongs(root._albumFilter(albumArtist, album) + " sort Track", cb, "track");
    }
    // An artist's songs. Rooted at the shelf like everything else the library
    // shows — UNLESS loose artists are included, in which case the loose songs
    // are the whole reason some of those artists are on the list at all and the
    // search has to be able to reach them. `AlbumArtist ==` still matches a
    // file with only an `Artist` tag: MPD's filters fall back to it (P:186-190),
    // verified on the two loose `Arsenal` tracks.
    function songsOfArtist(name, cb) {
        const expr = "(AlbumArtist == '" + root._fv(name) + "')";
        root._findSongs(root.artistsIncludeLoose ? "\"" + expr + "\"" : root._inAlbums(expr),
                        cb, "album");
    }

    // A song's cover: its own directory's cover file. Percent-encoded, because
    // 38 of 39 album directories have a space in their name and a couple have
    // an apostrophe.
    //
    // FOUR ANSWERS, NOT TWO. A directory the scan has been through hands out
    // the file it actually holds, or NOTHING when it holds none. A directory
    // nobody has asked about yet hands out the conventional `cover.jpg` — the
    // right answer when `scanCovers`
    // is off — EXCEPT while a scan is running, where the answer is a round trip
    // away and a guess would only be a warning in the log.
    //
    // THE FOURTH IS THE FILE'S OWN PICTURE, and it is reached only from the
    // second: a directory KNOWN to hold no cover file. Not from the third (a
    // directory nobody has asked about already answers `cover.jpg`) and not
    // while the scan is running (its answer is milliseconds away and would
    // make the extraction wasted work). It is asynchronous, so like the scan
    // it answers "" the first time and the record is rewritten when the
    // picture lands — `coverArtResolved`, and `_reseatDerived` before it.
    function coverUrlFor(file) {
        if (!file) return "";
        const s = String(file);
        const i = s.lastIndexOf("/");
        if (i <= 0) return "";
        const dir = s.substring(0, i);
        const url = root.coverUrlForDir(dir);
        if (url.length > 0) return url;
        // `undefined` is "not asked / still scanning"; only a known-empty
        // directory falls through to the file itself.
        if (!root.embedArt || root._coverByDir[dir] !== "") return "";
        return root._thumbed(root._art.urlFor(root.musicDir + "/" + s));
    }
    // The same question asked of a directory, which is what the shelf holds.
    function coverUrlForDir(dir) {
        if (!dir) return "";
        const known = root._coverByDir[dir];
        if (known !== undefined)
            return known.length > 0 ? root._thumbed(root._coverUrlOf(dir, known)) : "";
        if (root._coverScanning) return "";
        return root._thumbed(root._coverUrlOf(dir, root.coverNames.length > 0 ? root.coverNames[0] : "cover.jpg"));
    }
    // A cover's url -> its thumbnail's, or the url itself while there is none
    // (CoverThumbs answers at once and says `resolved` when the copy exists).
    function _thumbed(url) {
        return root.thumbCovers && url.length > 0 ? root._thumbs.thumbFor(url) : url;
    }
    // Whether the FILE's own picture is settled -- a picture, or known to hold
    // none. `coverUrlFor` answers "" for both "nothing yet" and "there is
    // none", and a view that must not flash a placeholder needs to know which
    // of the two it is holding. False whenever the directory answered, because
    // then the file was never asked.
    function coverArtKnown(file) {
        if (!root.embedArt || !file) return false;
        return root._art.isKnown(root.musicDir + "/" + String(file));
    }
    function _coverUrlOf(dir, name) {
        return "file://" + root._encodePath(root.musicDir + "/" + dir + "/" + name);
    }

    // =========================================================================
    // Internals
    // =========================================================================
    property MpdClient _client: null
    // The raw played list: [{song, at, list, listIndex, hasList}], one per file
    // that carries a `lastplayed` sticker, newest first -- `list` and
    // `listIndex` being the second sticker, what the play was part of and where
    // it sat in it. `recent` is a pure function of this plus the current song
    // plus the queue's two predictions.
    property var _recentSongs: []
    // file -> song record, or null for a file that is no longer in the
    // database. Dropped whenever the database changes; nothing else can make
    // a record stale.
    property var _songCache: ({})
    // The album the queue says is still being played through: the current
    // song's album, IF more of it is queued after the current position. Empty
    // otherwise — which is exactly what "the grouping stops when the queue is
    // cleared" means, with nothing to remember.
    property string _predictKey: ""
    // The same, for a LIST: "list\u0000<name>" while another song of the list
    // the current one was queued from is still in the queue. A separate key
    // because it is a separate run -- an album run is the contiguous block
    // around the needle, a list run is the list wherever its songs landed.
    property string _predictListKey: ""
    // The file under the needle. Excluded from the played list, because a song
    // that is playing has not been played yet: its sticker is written when it
    // STARTS, and it joins the list when the next one takes over.
    readonly property string _currentFile: root._current && root._current.file
                                           ? String(root._current.file) : ""
    property var _playlists: []
    // Playlist uri -> the first `listCoverProbe` files of it, in the LIST's
    // order. The rows' pictures are read out of this, and it is a separate map
    // rather than a field on the row because the row is rebuilt (by its song
    // count, by a `database` event) more often than the list's contents change.
    property var _listFiles: ({})
    // file -> {name, index}: the list a QUEUED song was put in the queue from,
    // and its place in that list. Written when a list is queued, read when a
    // song starts playing and written on from there into the sticker. It is
    // about the queue, not about history: a song that leaves the queue keeps
    // its entry (harmless, and the map is bounded by what one session queues),
    // and a song queued from anywhere else loses it -- which is the whole of
    // "a song played from nowhere in particular is a standalone play".
    //
    // IT DOES NOT SURVIVE A RESTART, and it should not pretend to: MPD's queue
    // does survive one, but which list its songs were put there from is not
    // something the daemon was ever told. What was already PLAYED keeps its
    // list, because that went into the sticker at the time.
    property var _listOrigin: ({})
    property bool _recentWanted: false
    property bool _playlistsWanted: false
    property bool _shuffleMode: false
    // The sticker the played-at timestamp is written under. A name, not a
    // literal in three places.
    property string stickerName: "lastplayed"
    // ...and the one that says WHAT THE PLAY WAS PART OF: "<place>:<list>", or
    // empty for a play that was part of no list. Written in the same breath as
    // the timestamp, because it is the same fact about the same play, and kept
    // in the sticker database for the same reason: it has to survive a restart
    // and it belongs to the daemon, not to whichever client was up at the time.
    // The PLACE is stored rather than looked up later -- that is what lets a
    // list played shuffled still be numbered in the list's own order, and what
    // keeps the numbering right when the list itself changes afterwards.
    property string listStickerName: "lastlist"
    property string _playState: "stop"
    property int _songId: -1
    property int _songPos: -1
    property real _duration: 0
    property real _elapsed: 0
    // WHEN `_elapsed` was last written (Date.now(), ms): what the catch-up counts from.
    property real _elapsedAtMs: 0
    property real _volume: 1
    property bool _hasMixer: true
    property bool _repeatOn: false
    property bool _randomOn: false
    property string _singleMode: "0"
    property string _consumeMode: "0"
    property int _bitrate: 0
    property string _statusError: ""
    // A "play next" is in flight: the queue read that shows it must not be re-spread by the shuffle mode.
    property bool _keepOrderOnce: false
    property string _audioFormat: ""
    property var _current: null
    property var _fidelity: null
    property var _queue: []
    property int _queueLength: 0
    property real _albumProgress: 0
    // THE RECORD ON THE PLATTER, latched. `_runKey` is its directory and its
    // album tag together, `_runIds` the queue ids of its songs in the order
    // they were queued, `_runTotal` how many songs the record has.
    //
    // LATCHED BY ID rather than re-derived from the queue every time, because
    // the queue under a record that is already playing can lose songs --
    // consume mode eats each one as it plays, a delete takes one out -- and a
    // record does not come off the platter for that. The ids are what survive
    // both: a move keeps them, a clear and re-add does not, which is exactly
    // the line between "the same record" and "a new one".
    property string _runKey: ""
    property var _runIds: []
    property int _runTotal: 0
    property var _albums: []
    property var _artists: []
    // [{name, songCount}] — the artists who appear in `Tracks/` or in a
    // playlist directory, whether or not they also have an album. Merged with
    // the shelf by `_mergeArtists`; loaded only while `artistsIncludeLoose`
    // wants it, because it is two queries nobody else needs.
    property var _looseArtists: []
    property bool _looseLoaded: false
    property var _genres: []
    // Directory uri -> the cover file it holds, "" for one that holds none,
    // absent for one nobody has asked about. `coverUrlFor` reads it; nothing
    // else may, because "" and absent mean different things.
    property var _coverByDir: ({})
    property bool _coverScanning: false
    property bool _coversScanned: false
    // file uri -> the file's own mtime on disk, epoch seconds. Filled by the
    // SAME `listfiles` pass the cover scan runs, because `listfiles` reads the
    // directory and the database does not. Absent for a file the scan has not
    // reached, which is what `lastModified: 0` means.
    property var _mtimeByFile: ({})
    // Album directory uri -> the first song in it. What the shelf's cover is
    // asked OF when the directory holds no cover file: a directory has no
    // picture inside it, a file does, so the row has to ask on behalf of a
    // song. Filled by the shelf read, which already has the record in its hand.
    property var _firstFileByDir: ({})
    // albumKey ("<albumArtist>\u0000<album>") -> song count, from the shelf.
    property var _albumCounts: ({})
    // Album directory uri -> how many songs the daemon holds in it, which is
    // how long the record REALLY is. Asked once per directory the needle
    // actually reaches (`count "(base '...')"`, one line back) rather than
    // read off the shelf: the shelf is only fetched when somebody opens the
    // library, and the record has to know its own length before then. -1 while
    // the question is out. A plain map -- nothing binds to it.
    property var _dirSongs: ({})
    // The same key -> the album's main genre, and the folded genre table the
    // display spelling and the counts are read out of.
    property var _albumGenre: ({})
    property var _genreFold: ({})
    property var _genreOrder: []
    // albumsOfGenre() calls made before the shelf existed.
    property var _genreWaiters: []
    property bool _updating: false
    property bool _libraryLoading: false
    property bool _libraryLoaded: false
    // Somebody has asked for the library at least once. Recorded rather than
    // inferred from `_albums.length`, a proxy that gets two cases wrong: a
    // `loadLibrary()` issued before the daemon is up (the login order — the
    // shell starts first) would be dropped and never retried, and a
    // `changed: database` while the shelf is still empty would do nothing.
    property bool _libraryWanted: false
    property int _queueVersion: -1
    // Whether a queue has been read at all on this connection. The growth rule
    // needs a BEFORE, and the first read has none: what came back is what was
    // already there.
    property bool _queueSeen: false
    property bool _needQueue: false
    property bool _forceSeat: false
    // The song this module last saw PAUSED. A resume of anything else is not
    // this song's position moving.
    property int _pauseId: -1
    // The output's lead: how far the daemon's `elapsed` ends up ahead of where
    // the music actually is, which is also exactly what a resume skips. 0 until
    // a cycle has measured it.
    property real _resumeSkip: 0
    // While this is in the future the clock stays on its own trajectory and the
    // daemon's number is not seated -- the window a correction is made and
    // measured in. 0 when the clock is following the daemon normally.
    property real _resumeHeldUntil: 0
    property var _pendingAlbums: []

    onArtistsIncludeLooseChanged: {
        if (root.artistsIncludeLoose) root._loadLooseArtists();
    }

    property MpdHealth _health: MpdHealth {
        service: root
        client: root._client
        script: RepoRoot.dir + "/tools/player/audio_diagnose.py"
    }

    // The current song's average bitrate (AudioBitrate.qml). Read only while something holds
    // the clock -- the popup is the one place the figure is shown -- so a closed popup forks
    // nothing at a track change. The chip's tier is classified again when the figure lands.
    property AudioBitrate _avgRead: AudioBitrate {
        active: root._tickHoldCount > 0 && root.playState !== "stop"
        path: root._current && root._current.file ? root.musicDir + "/" + root._current.file : ""
        duration: root._current && root._current.duration > 0 ? root._current.duration : root._duration
        onKbpsChanged: root._reclassify()
        onPendingChanged: root._reclassify()
        onFailedChanged: root._reclassify()
    }

    // The file's own picture, for the directories that have no cover file.
    // `active` is the gate: with `embedArt` off nothing here ever forks.
    property AudioArt _art: AudioArt {
        active: root.embedArt
    }
    Connections {
        target: root._art
        function onResolved(path, url) {
            root._onArtResolved(path, url);
        }
    }
    // The small copies of the covers (CoverThumbs.qml). `active` is the gate: with
    // `thumbCovers` off nothing here ever forks.
    property CoverThumbs _thumbs: CoverThumbs {
        active: root.thumbCovers
    }
    // A copy landing swaps a url for a url: nothing is missing meanwhile, so it is
    // never urgent, and the shelf asks about every album at once -- ~50 copies in
    // the first minute of a new cache. A CEILING, started once and left to fire
    // (like `_artSettle`: restarting it per arrival would show nothing until the
    // last copy), so that is a handful of rewrites of the queue and the shelf, not
    // fifty.
    Connections {
        target: root._thumbs
        function onResolved() {
            if (!_thumbSettle.running) _thumbSettle.start();
        }
    }
    property Timer _thumbSettle: Timer {
        interval: 1500
        repeat: false
        onTriggered: root._reseatDerived()
    }
    // At most one re-seat per 60 ms. A picture landing rewrites the current
    // song, the whole queue, the resolved-record cache and the shelf; a 35-song
    // favourites list resolving one file every 40 ms would otherwise do all of
    // that 35 times.
    //
    // IT IS A CEILING, NOT A QUIET PERIOD. Restarting it on every arrival would
    // mean nothing appeared until the LAST file of a long list had been
    // extracted -- a second and a half of blank vinyl while the covers were
    // already on the disk. Started once and left to fire, it lands the first
    // batch 60 ms in and coalesces the rest.
    property Timer _artSettle: Timer {
        interval: 60
        repeat: false
        onTriggered: root._reseatDerived()
    }

    // `path` is absolute; the records are keyed by the uri MPD uses.
    function _onArtResolved(path, url) {
        const pre = root.musicDir + "/";
        const file = String(path).indexOf(pre) === 0
            ? String(path).substring(pre.length) : String(path);
        if (!root._artSettle.running) root._artSettle.start();
        root.coverArtResolved(file, url);
    }

    Component { id: _clientComponent; MpdClient {} }

    Component.onCompleted: {
        root._client = root.client ? root.client : _clientComponent.createObject(root, root.socketPath !== "" ? { socketPath: root.socketPath } : {});
        root._client.changed.connect(root._onSubsystem);
        root._client.ready.connect(root._onReady);
        if (root._client.connected) root._onReady();
    }

    function _log(m) { if (root.debug) console.log("MpdService: " + m); }

    function _send(cmd) {
        if (root._client) root._client.send(cmd, null);
    }
    function _sendAll(cmds, cb) {
        if (root._client) root._client.sendAll(cmds, cb || null);
    }
    function _q(arg) { return root._client ? root._client.quote(arg) : '""'; }
    function _fv(v) { return root._client ? root._client.filterValue(v) : String(v); }

    // `(base 'X')` on its own, as a finished protocol argument.
    function _baseArg(uri) {
        return "\"(base '" + root._fv(uri) + "')\"";
    }
    // An expression AND-ed with the album root, as a finished argument. Every
    // query that means "in the library" goes through this: `Tracks/` and the
    // playlist directories carry the album tags of the records they came from.
    // Without the base `list album` answers 85 album names, and the shelf built
    // from them is 40 rows and 542 songs where the daemon knows 38 and 527.
    function _inAlbums(expr) {
        return "\"((base '" + root._fv(root.albumsSubdir) + "') AND " + expr + ")\"";
    }
    function _albumFilter(albumArtist, album) {
        return root._inAlbums("((AlbumArtist == '" + root._fv(albumArtist)
                              + "') AND (Album == '" + root._fv(album) + "'))");
    }
    // `eq_ci`, not `==`: this library holds both "SoundTrack" and "Soundtrack"
    // and they are one genre. MPD 0.24 does the folding itself, so the two
    // spellings are one query rather than one query per spelling.
    function _genreFilter(name) {
        return root._inAlbums("(Genre eq_ci '" + root._fv(name) + "')");
    }
    // The lookup key a genre name folds onto. The display name is chosen once,
    // in `_libraryPhase1`; everything else compares folded.
    // "1999-08-28" / "1999" / "1999-08" -> 1999; 0 when the tag has no year.
    function _yearOf(date) {
        const m = /^\s*(\d{4})/.exec(String(date || ""));
        return m ? parseInt(m[1], 10) : 0;
    }
    function _foldGenre(name) {
        return String(name || "").trim().toLowerCase();
    }
    function _modeArg(mode) {
        if (mode === "oneshot") return "oneshot";
        return (mode === true || mode === 1 || mode === "1") ? "1" : "0";
    }
    function _encodePath(p) {
        // encodeURI leaves `/` alone, which is what a path wants, but it also
        // leaves `#` and `?` — both of which end a URL's path.
        return encodeURI(p).replace(/#/g, "%23").replace(/\?/g, "%3F");
    }
    function _int(v, dflt) {
        const n = parseInt(v, 10);
        return isFinite(n) ? n : dflt;
    }
    function _num(v, dflt) {
        const n = parseFloat(v);
        return isFinite(n) ? n : dflt;
    }

    // ---- Connection lifecycle ----------------------------------------------
    function _onReady() {
        root._log("connected, protocol " + root._client.version);
        root._queueVersion = -1;
        root._queueSeen = false;
        // A `count` that is in flight when the socket dies leaves its -1 behind,
        // and -1 means "the question is out" -- it would never be asked again.
        root._dirSongs = ({});
        // BEFORE the first status read, so the first song record is built with
        // the covers already known, or at worst while the scan suppresses the
        // guess. MPD answers in order, so this is not a hope: the first step's
        // reply lands before `currentsong`'s.
        root._scanCovers();
        root._readState();
        // The loose latch goes up when the two counts are SENT, so a socket
        // that dies mid-question leaves it up with nothing behind it — the same
        // trap `_libraryLoading` is cleared for below. Two `count` queries are
        // a cheaper answer than a shelf that quietly loses its loose artists
        // for the rest of the session.
        root._looseLoaded = false;
        if (root.artistsIncludeLoose) root._loadLooseArtists();
        if (root._recentWanted) root.loadRecent();
        if (root._playlistsWanted) root.loadPlaylists();
        if (root._libraryWanted) {
            // A load that is in flight when the socket dies is answered with
            // ok = false and leaves the flag down; clear it either way so this
            // one is not refused as a duplicate.
            root._libraryLoading = false;
            root.loadLibrary();
        }
    }

    function _onSubsystem(sub) {
        if (sub === "database") {
            // The library changed underneath us. Drop the caches; reload only
            // if somebody had asked for it once already. The resolved song
            // records go too — a rescan is the only thing that can make one
            // wrong, and it is also the only thing that fires this.
            root._libraryLoaded = false;
            root._songCache = ({});
            // How many songs an album directory holds is a fact about the
            // database, and a rescan is the only thing that can change it.
            root._dirSongs = ({});
            // A rescan is the only thing that can add or remove a cover file,
            // and the same read carries the mtimes. Both maps are KEPT while
            // the new ones are fetched rather than cleared: clearing would
            // blank every cover on screen for a round trip, and a stale answer
            // for one directory is a smaller lie than that.
            root._coversScanned = false;
            root._scanCovers();
            root._looseLoaded = false;
            if (root.artistsIncludeLoose) root._loadLooseArtists();
            if (root._recentWanted) root.loadRecent();
            if (root._playlistsWanted) root.loadPlaylists();
            if (root._libraryWanted) root.loadLibrary();
            return;
        }
        if (sub === "sticker") {
            if (root._recentWanted) root.loadRecent();
            return;
        }
        if (sub === "stored_playlist") {
            if (root._playlistsWanted) root.loadPlaylists();
            return;
        }
        if (sub === "player" || sub === "mixer" || sub === "options"
                || sub === "playlist" || sub === "update") {
            // One idle reply can carry several of these (a `play` fires
            // `player` AND `mixer`). Coalesce them into one read.
            _readCoalesce.restart();
        }
    }

    Timer {
        id: _readCoalesce
        interval: 0
        repeat: false
        onTriggered: root._readState()
    }

    // Two sticker writes per song change, in one command list: WHEN it was
    // played and WHAT IT WAS PART OF. The daemon answers with a `sticker` idle
    // notification, which is what refreshes the list -- so the write and the
    // read are never in the same round trip and a client that is not showing
    // the list pays for nothing but the write.
    //
    // THE SECOND ONE IS ALWAYS WRITTEN, empty for a play that was part of no
    // list. Deleting it instead would be one command either way, but it would
    // ACK on every standalone play (MPD has no delete-if-present) and it would
    // leave the two stickers out of step, so a file whose list attribution had
    // to be TAKEN BACK -- queued from a list once, then played on its own --
    // could not tell the difference between "not a list" and "never asked".
    // Empty is the answer to the question; absent is the question never put.
    function _notePlayed() {
        if (!root._current || !root._current.file || !root.connected)
            return;
        const file = root._current.file;
        const now = Math.floor(Date.now() / 1000);
        const o = root._listOrigin[file];
        const val = o && o.name ? (String(o.index || 0) + ":" + o.name) : "";
        root._sendAll(["sticker set song " + root._q(file) + " "
                       + root.stickerName + " " + root._q(String(now)),
                       "sticker set song " + root._q(file) + " "
                       + root.listStickerName + " " + root._q(val)], null);
    }

    function _readState() {
        if (!root._client || !root._client.connected) return;
        root._client.sendAll(["status", "currentsong"], (ok, groups) => {
            if (!ok) return;
            const songMoved = root._applyStatus(groups[0] || []);
            root._applyCurrent(groups[1] || []);
            // Both halves applied: `songId`, `current` and `fidelity` now
            // describe the same song, which is the whole promise of this
            // signal over the bare `songIdChanged`.
            if (songMoved) {
                root.songChanged(root._songId);
                root._notePlayed();
            }
            if (root._needQueue) {
                root._needQueue = false;
                root._readQueue();
            } else {
                root._recomputeAlbumRun();
            }
        });
    }

    function _applyStatus(lines) {
        const s = root._client.parseKV(lines);
        // The position the old state implies, BEFORE the new one is read: every
        // comparison below (the resume's lead, the seat's tolerance) is against it.
        root._catchUp();
        const wasId = root._songId;
        const wasState = root._playState;

        root._playState = s.state || "stop";
        root._songId = root._int(s.songid, -1);
        root._songPos = root._int(s.song, -1);
        root._duration = root._num(s.duration, 0);
        root._repeatOn = s.repeat === "1";
        root._randomOn = s.random === "1";
        root._singleMode = s.single || "0";
        root._consumeMode = s.consume || "0";
        root._bitrate = root._int(s.bitrate, 0);
        root._statusError = s.error || "";
        root._audioFormat = s.audio || "";
        root._queueLength = root._int(s.playlistlength, 0);
        root._updating = s.updating_db !== undefined;

        root._hasMixer = s.volume !== undefined;
        if (root._hasMixer)
            root._volume = Math.max(0, Math.min(1, root._int(s.volume, 0) / 100));

        if (root._songId !== wasId) root._forceSeat = true;
        root._seatElapsed(root._anchorPause(wasState, root._num(s.elapsed, 0)));
        // The position is as of this read, written or not (a pause resumed at the
        // value it stopped at writes nothing, and the catch-up must not count
        // the hour it was paused).
        root._elapsedAtMs = Date.now();

        const v = root._int(s.playlist, -1);
        if (v !== root._queueVersion) {
            root._queueVersion = v;
            root._needQueue = true;
        }
        // The caller emits `songChanged`, not this function. `status` and
        // `currentsong` arrive in one command list and are applied in that
        // order, so at THIS point `current` is still the previous track — and
        // the first thing the vinyl's opening choreography reads off the
        // signal is `current.coverUrl`. Emitted here it would fly in the last
        // sleeve, or none at all on the first song of a session.
        return root._songId !== wasId;
    }

    // The resume put back onto this module's own clock. Returns the value
    // `_seatElapsed` should take: the daemon's, except inside the window a
    // correction is being made and measured in, where it is the clock's own --
    // so the position the module SHOWS never takes the skip either, not for one
    // frame.
    function _anchorPause(wasState, reported) {
        if (root._playState === "pause") {
            // THE MEASUREMENT. The daemon has stopped, so its frozen number and
            // this module's clock are two readings of one instant and the whole
            // residual of the last correction is their difference. It is the
            // only chance to take it: while playing, the daemon's number is
            // still moving and quantised.
            if (root._resumeHeldUntil > 0 && root._songId === root._pauseId) {
                const err = reported - root._elapsed;
                if (Math.abs(err) > root.resumeLearnMin && Math.abs(err) <= root.maxResumeSkip)
                    root._resumeSkip = Math.max(0, Math.min(root.maxResumeSkip,
                                                            root._resumeSkip + err));
            }
            root._resumeHeldUntil = 0;
            root._pauseId = root._songId;
            return reported;
        }
        if (root._playState !== "play") {
            root._resumeHeldUntil = 0;
            root._pauseId = -1;
            return reported;
        }
        // Inside the window: the clock keeps its own trajectory, so a read that
        // catches the daemon mid-jump cannot drag it along.
        if (root._resumeHeldUntil > 0) {
            if (root._songId !== root._pauseId || Date.now() > root._resumeHeldUntil) {
                root._resumeHeldUntil = 0;
                return reported;
            }
            return root._elapsed;
        }
        const wasId = root._pauseId;
        root._pauseId = root._songId;
        if (!root.losslessResume || wasState !== "pause"
                || root._songId < 0 || root._songId !== wasId)
            return reported;
        // THE CORRECTION. The learned lead where there is one, and what the
        // daemon has visibly jumped so far where there is not -- an under-read,
        // but a better first guess than nothing, and the pause after it says by
        // how much. The window opens either way, because a resume left
        // uncorrected is the one that has the most to teach.
        const lead = root._resumeSkip > 0 ? root._resumeSkip
                                          : (reported - root._elapsed);
        if (lead >= root.resumeSkipMin && lead <= root.maxResumeSkip)
            // Not through `seek()`: that one is a user asking to move and it
            // seats the clock at the target. This one asks the DAEMON to come
            // back to where the clock already is.
            root._send("seekid " + root._songId + " "
                       + Math.max(0, root._elapsed - lead).toFixed(3));
        root._resumeHeldUntil = Date.now() + root.resumeHoldMs;
        return root._elapsed;
    }

    function _seatElapsed(v) {
        if (root._forceSeat || root._playState !== "play"
                || Math.abs(v - root._elapsed) > root.elapsedResyncSec) {
            root._putElapsed(v);
            root._forceSeat = false;
            return;
        }
        // Inside the tolerance the daemon is only ever behind us — its value
        // is a floor, never a rewind.
        if (v > root._elapsed) root._putElapsed(v);
    }

    // The one writer of `_elapsed`: the value, and when it was true.
    function _putElapsed(v) {
        root._elapsed = v;
        root._elapsedAtMs = Date.now();
    }

    // The position, advanced by the wall clock for the time nothing ran the
    // interpolator (header). A no-op while it runs, while not playing and when
    // the wall clock stepped back.
    function _catchUp() {
        if (_tick.running || root._playState !== "play")
            return;
        const dt = (Date.now() - root._elapsedAtMs) / 1000;
        if (!(dt > 0))
            return;
        let e = root._elapsed + dt;
        if (root._duration > 0 && e > root._duration) e = root._duration;
        root._putElapsed(e);
    }

    // ---- Who is looking at the elapsed time --------------------------------
    // `who` is any object that releases itself (PlayerTickHold does, in
    // Component.onDestruction). Held twice by the same object counts once.
    property var _tickHolders: []
    property int _tickHoldCount: 0
    function holdTick(who) {
        if (!who || root._tickHolders.indexOf(who) >= 0)
            return;
        // Caught up while the clock is still off: from the stamp to now is the
        // time nobody was looking.
        if (root._tickHolders.length === 0)
            root._catchUp();
        root._tickHolders.push(who);
        root._tickHoldCount = root._tickHolders.length;
        // The first holder asks the daemon where it is: a suspend steps the wall
        // clock, and the catch-up above cannot know.
        if (root._tickHoldCount === 1 && root.playing)
            root._readState();
    }
    function releaseTick(who) {
        const i = root._tickHolders.indexOf(who);
        if (i < 0)
            return;
        root._tickHolders.splice(i, 1);
        root._tickHoldCount = root._tickHolders.length;
    }

    function _applyCurrent(lines) {
        const recs = root._client.parseObjects(lines, "file");
        if (recs.length === 0) {
            root._current = null;
            root._fidelity = null;
            return;
        }
        const song = root._songOf(recs[0]);
        root._current = song;
        // `audio:` (live, from the decoder) beats `Format:` (from the scan)
        // only because they are identical when both exist and `audio:` is
        // absent while stopped — so the chip survives a stop.
        root._fidelity = Fidelity.classify(root._audioFormat || song.format,
                                           root._bitrateFor(song.file), song.file);
    }

    // The figure the chip and its lobe show: the FILE's average once it is read; 0 while the
    // read is in flight (a live number shown for 100 ms and then replaced by the real one
    // would be a figure that moves); the live reading only when the file cannot be read.
    function _bitrateFor(file) {
        const r = root._avgRead;
        if (r.kbps > 0 && root._current && root._current.file === file) return r.kbps;
        if (r.pending && root._current && root._current.file === file) return 0;
        return root._bitrate;
    }
    function _reclassify() {
        if (!root._current) return;
        root._fidelity = Fidelity.classify(root._audioFormat || root._current.format,
                                           root._bitrateFor(root._current.file), root._current.file);
    }

    // One MPD record -> the module's song object.
    //
    // `artist` and `genre` are DISPLAY strings: a tag with several values is
    // joined, because that is what a row shows. `albumArtist` is a GROUPING
    // KEY: it is the primary value only, so `appendAlbum(song.albumArtist,
    // song.album)` builds a filter that actually matches. The two differ on
    // exactly one album here, and getting them the same way round would either
    // print half a credit or send an unmatchable name to the daemon.
    //
    // AlbumArtist is absent altogether from a record whose file has no such
    // tag (every Loop Hero mp3) even though `list albumartist` reports one for
    // the same song — `list` falls back to Artist and a record does not. The
    // same fallback here keeps the two agreeing.
    function _songOf(rec) {
        const c = root._client;
        const file = rec.file || "";
        const artist = c.joined(rec.Artist) || c.joined(rec.AlbumArtist);
        return {
            id: root._int(rec.Id, -1),
            pos: root._int(rec.Pos, -1),
            file: file,
            title: c.joined(rec.Title) || root._titleFromFile(file),
            artist: artist,
            albumArtist: c.first(rec.AlbumArtist) || c.first(rec.Artist),
            album: c.joined(rec.Album),
            track: root._int(c.first(rec.Track), 0),
            disc: root._int(c.first(rec.Disc), 0),
            date: c.first(rec.Date),
            genre: c.joined(rec.Genre),
            duration: root._num(c.first(rec.duration), 0),
            format: c.first(rec.Format),
            coverUrl: root.coverUrlFor(file),
            // The file's mtime on disk in epoch SECONDS, 0 until the directory
            // read has reached it. The favourites are a download in the order
            // they were favourited, so this is the only thing that says what
            // their order IS -- see `_takeMtimes` for why it is not MPD's own.
            lastModified: root.modifiedOf(file)
        };
    }

    // "Albums/x/03. Artist - Title.flac" -> "03. Artist - Title". Only ever
    // reached by a file with no Title tag.
    function _titleFromFile(file) {
        if (!file) return "";
        let s = String(file);
        const i = s.lastIndexOf("/");
        if (i >= 0) s = s.substring(i + 1);
        const d = s.lastIndexOf(".");
        return d > 0 ? s.substring(0, d) : s;
    }

    // The queue, re-read whenever the daemon says its version changed.
    //
    // AN EMPTY ANSWER IS NOT AN EMPTY QUEUE. `status` has already told us how
    // long the queue is; a `playlistinfo` that comes back with fewer records
    // than that is a reply that lost a race, not a queue that emptied -- and
    // publishing it would empty the queue for one frame, which takes the record
    // off the platter, runs the put-away, and brings the whole album straight
    // back on with a second arrival. That double arrival can only happen against
    // the live daemon: nothing in the mock can lose a reply.
    //
    // The status's own count is the authority, so a short answer is dropped and
    // read again on the next tick. A LONGER answer is kept: the queue grew
    // between the status and the reply, and the reply is the newer truth.
    // A dropped answer is asked for again on its own rather than waiting for
    // whatever would next have polled `status`: a stopped daemon can sit
    // between idle events for minutes, and a queue nobody re-read is a queue
    // the module is wrong about for that whole time.
    Timer {
        id: queueRetry
        interval: 120
        repeat: false
        onTriggered: root._readState()
    }

    function _readQueue() {
        root._client.send("playlistinfo", (ok, lines) => {
            if (!ok) return;
            const recs = root._client.parseObjects(lines, "file");
            const arr = [];
            for (let i = 0; i < recs.length; i++) arr.push(root._songOf(recs[i]));
            if (arr.length < root._queueLength) {
                root._needQueue = true;         // ask again; do not publish this
                queueRetry.restart();
                return;
            }
            // MEASURED AGAINST THE QUEUE THIS MODULE LAST PUBLISHED: `_applyStatus`
            // has ALREADY overwritten `_queueLength` with the daemon's new count
            // by the time this reply lands, so `arr.length > _queueLength` would be
            // N > N on every read and the rule would never fire. (It could only
            // fire by accident -- a `status` landing between a `clear` and the
            // adds after it reports 0 while the `playlistinfo` behind it counts 35.)
            //
            // AND NOT ON THE FIRST READ OF A CONNECTION. A queue that was
            // already there when the socket opened did not grow, it arrived,
            // and spreading it would be this module reordering somebody's queue
            // for the crime of being looked at.
            const grew = root._queueSeen && arr.length > (root._queue || []).length;
            root._queue = arr;
            root._queueLength = arr.length;
            root._queueSeen = true;
            root._recomputeAlbumRun();
            // While shuffle is a mode, what is ADDED is shuffled in rather than
            // tacked on the end -- which is the whole difference between a mode
            // and a button you press once. `_queueSongs` has already ordered
            // the collection that arrived; this mixes it with what was waiting,
            // and it is the only half a bare `add` from anywhere else goes
            // through. Only on growth: a move is the user ordering the queue by
            // hand, and re-shuffling under them would undo it.
            if (root._shuffleMode && grew && !root._keepOrderOnce)
                root.shuffleQueue();
            root._keepOrderOnce = false;
        });
    }

    // ---- The album run inside the queue -------------------------------------
    function _albumKeyOf(song) {
        if (!song || !song.album) return "";
        return (song.albumArtist || song.artist || "") + "\u0000" + song.album;
    }

    // The LIST the queue says is still being played through -- the same job as
    // `_predictKey`, and NOT by contiguity: a list added while the shuffle mode
    // is on is spread through the queue, so the run is "any other song of it
    // still queued", not "the block around this one".
    function _listPrediction(q, pos) {
        if (pos < 0 || pos >= q.length) return "";
        const cur = q[pos];
        const o = cur && cur.file ? root._listOrigin[cur.file] : null;
        if (!o || !o.name) return "";
        for (let i = 0; i < q.length; i++) {
            if (i === pos || !q[i].file) continue;
            const oi = root._listOrigin[q[i].file];
            if (oi && oi.name === o.name) return "list\u0000" + o.name;
        }
        return "";
    }

    // THE DIRECTORY A RECORD IS. `albumsSubdir` is what decides what an album
    // is everywhere else in this module -- the shelf, every library filter --
    // and it decides it here too: a song under `Albums/<name>/` is a track of
    // that record; a song in `Tracks/` or in a playlist directory is a loose
    // song that happens to carry an album's tags.
    //
    // THAT DISTINCTION IS THE WHOLE OF "a playlist must never flip the record".
    // `Tracks/Radiohead - Street Spirit (Fade Out).m4a` is tagged 12 of 12 of
    // The Bends and is, by where it lives, not a record -- so a favourites
    // list shuffled into an empty queue has no album progress at all, whatever
    // its songs claim.
    function _albumDirOf(file) {
        const s = String(file || "");
        // An EMPTY `albumsSubdir` is "the whole library is the shelf", which is
        // the reading every library filter takes of it (`_inAlbums` builds
        // `(base '')`), so every directory is an album directory.
        const head = root.albumsSubdir === "" ? "" : root.albumsSubdir + "/";
        if (head !== "" && s.indexOf(head) !== 0) return "";
        const slash = s.indexOf("/", head.length);
        // A file lying loose directly in the shelf's root is in no record.
        if (slash < 0) return "";
        return s.substring(0, slash);
    }

    // HOW LONG THE RECORD IS: the songs the daemon holds in that directory,
    // asked once and kept. -1 is "not known yet" -- either the question is out
    // or there is no client to ask -- and a record of unknown length is not a
    // record yet, so the run is refused until the answer lands and this runs
    // again.
    function _albumSizeOf(dir) {
        if (dir === "") return -1;
        const known = root._dirSongs[dir];
        if (known !== undefined) return known;
        if (!root._client || !root._client.connected) return -1;
        root._dirSongs[dir] = -1;
        root._client.send("count " + root._baseArg(dir), (ok, lines) => {
            root._dirSongs[dir] = ok ? root._int(root._client.parseKV(lines).songs, 0) : 0;
            root._recomputeAlbumRun();
        });
        return -1;
    }

    // THE RUN AROUND THE NEEDLE, or null when what is playing is not a record.
    //
    // A record is on the platter because an ALBUM is playing, so all of these
    // have to hold at once and each one answers a case a plainer rule gets
    // wrong:
    //
    //   the block   the songs of this album around the current one, stepping
    //               over up to `albumRunGap` foreign songs in a row and
    //               stopping at anything wider. Stopping is what makes the
    //               SAME ALBUM QUEUED TWICE two records rather than one long
    //               one when the copies are apart, and the stepping is what
    //               keeps a "play next" dropped into the middle of a record
    //               from cutting it in half.
    //   min         A RUN OF ONE SONG IS NEVER AN ALBUM, whatever its tags
    //               say. This is the rule a favourites list would break.
    //   coverage    most of the album has to be there. THREE SONGS OF TWELVE
    //               is a selection, not a record: you would not put the record
    //               on the platter to hear them, and you would certainly not
    //               turn it over after the second.
    //   density     the block has to be solid. AN ALBUM SHUFFLED THROUGH a
    //               queue of other songs is not a record on a platter either
    //               -- you would be swapping records every song -- so there is
    //               nothing to turn over. An album shuffled among ITSELF, which
    //               is what this module's shuffle mode does to a collection on
    //               its way in, stays one solid block and does turn over, at
    //               the middle song of its own shuffled order.
    //
    // And the run is CHUNKED BY THE RECORD'S OWN LENGTH, so an album queued
    // twice back to back is two records: the second starts at its first side
    // again, which is a fall, which is what turns the record back over.
    function _findAlbumRun(q, pos) {
        const cur = q[pos];
        const dir = root._albumDirOf(cur ? cur.file : "");
        if (dir === "") return null;
        const key = root._albumKeyOf(cur);
        if (key === "") return null;
        const n = root._albumSizeOf(dir);
        // Unknown (-1) or a directory holding one song: no record.
        if (n < 2) return null;
        // BOTH facts have to agree -- same directory AND same album tag -- so
        // a directory whose songs disagree about their album is no record and
        // two directories that agree are still two records.
        const mine = i => {
            const s = q[i];
            return !!s && root._albumDirOf(s.file) === dir && root._albumKeyOf(s) === key;
        };
        let a = pos;
        let b = pos;
        for (let i = pos - 1, back = 0; i >= 0 && back <= root.albumRunGap; i--) {
            if (mine(i)) { a = i; back = 0; } else back++;
        }
        for (let j = pos + 1, fwd = 0; j < q.length && fwd <= root.albumRunGap; j++) {
            if (mine(j)) { b = j; fwd = 0; } else fwd++;
        }
        const members = [];
        for (let m = a; m <= b; m++) if (mine(m)) members.push(m);
        const found = members.length;
        if (found < root.albumRunMin) return null;
        if (found < Math.max(root.albumRunMin, Math.ceil(n * root.albumRunCoverage))) return null;
        if (found < (b - a + 1) * root.albumRunDensity) return null;
        const at = members.indexOf(pos);
        const copy = Math.floor(at / n);
        const ids = [];
        for (let c = copy * n; c < members.length && c < copy * n + n; c++)
            ids.push(q[members[c]].id);
        return { key: dir + "\u0000" + key, ids: ids, total: n, local: at - copy * n };
    }

    function _publishRun(local) {
        root._albumProgress = root._runTotal > 0
            ? Math.min(1, (local + 1) / root._runTotal) : 0;
    }
    function _dropRun() {
        root._runKey = "";
        root._runIds = [];
        root._runTotal = 0;
        root._albumProgress = 0;
    }
    // A STOP IS NOT THE RECORD COMING OFF. MPD drops `songid` from `status`
    // while stopped, so the position within the run is unknown for as long as
    // it lasts -- and the album is still on the platter, side B up, not
    // spinning. So the number is HELD: zeroing it and putting it back is a
    // fall and then a rise, which is precisely the pair the stage reads as
    // "turn the record back over, and now turn it again". It is dropped only
    // when the queue no longer holds a single song of the run.
    function _holdRun(q) {
        if (root._runKey === "") { root._albumProgress = 0; return; }
        for (let i = 0; i < q.length; i++)
            if (root._runIds.indexOf(q[i].id) >= 0) return;
        root._dropRun();
    }

    // More of this album is queued directly after the current song, so it is
    // going to be played through: the whole of the "predict it" rule, and it
    // needs no memory. Clear the queue and it is empty on the next read, which
    // is what makes the recently-played grouping stop. It is NOT the record's
    // run: this one groups a listening, and two songs of an album are a
    // listening while they are not a record.
    function _predictAlbumKey(q, pos) {
        if (pos < 0 || pos >= q.length) return "";
        const key = root._albumKeyOf(q[pos]);
        if (key === "") return "";
        return pos + 1 < q.length && root._albumKeyOf(q[pos + 1]) === key ? key : "";
    }

    function _recomputeAlbumRun() {
        const q = root._queue || [];
        const pos = root._songPos;
        // Read off the same queue as the run below, and in every branch of it.
        root._predictListKey = root._listPrediction(q, pos);
        root._predictKey = root._predictAlbumKey(q, pos);
        // NOTHING IS PLAYING IS NO PROGRESS: a stopped player may not put a
        // record ON the platter, which is what makes an album queued and never
        // started read 0 rather than 1. It does not take one off either.
        if (root._playState === "stop" || pos < 0 || pos >= q.length) {
            root._holdRun(q);
            return;
        }
        const cur = q[pos];
        // Still inside the record that is already on the platter.
        const held = cur ? root._runIds.indexOf(cur.id) : -1;
        if (root._runKey !== "" && held >= 0) {
            root._publishRun(held);
            return;
        }
        const run = root._findAlbumRun(q, pos);
        if (!run) { root._dropRun(); return; }
        root._runKey = run.key;
        root._runIds = run.ids;
        root._runTotal = run.total;
        root._publishRun(run.local);
    }

    // ---- Elapsed interpolation ----------------------------------------------
    // Runs only while the song plays AND something holds it (see the header).
    FrameAnimation {
        id: _tick
        running: root.playing && root._tickHoldCount > 0
        onTriggered: {
            let e = root._elapsed + _tick.frameTime;
            if (root._duration > 0 && e > root._duration) e = root._duration;
            root._putElapsed(e);
        }
    }

    // ---- Library ------------------------------------------------------------
    function _libraryPhase1(ok, groups) {
        if (!ok) {
            root._libraryLoading = false;
            root._flushGenreWaiters();
            return;
        }
        // `list album group albumartist` emits, per album, the group value
        // then the item: AlbumArtist, Album. Any key that is not the listed
        // type updates the group context; the listed type closes a record.
        const lines = groups[0] || [];
        const ctx = {};
        const pending = [];
        for (let i = 0; i < lines.length; i++) {
            const kv = root._client.parseKV([lines[i]]);
            const keys = Object.keys(kv);
            if (keys.length === 0) continue;
            const k = keys[0];
            if (k === "Album") {
                pending.push({
                    albumArtist: ctx.AlbumArtist || "",
                    album: kv.Album,
                    date: "",
                    coverUrl: "",
                    songCount: 0,
                    dirUri: "",
                    dirPath: ""
                });
            } else {
                ctx[k] = kv[k];
            }
        }

        // The genre histogram, folded by case. "SoundTrack" (12 songs) and
        // "Soundtrack" (235) are one genre with 247, and the spelling shown is
        // the one most of the songs use — a deterministic choice from the data
        // rather than whichever MPD happened to list first.
        const gl = root._client.parseObjects(groups[1] || [], "Genre");
        const byFold = ({});
        const foldOrder = [];
        for (let j = 0; j < gl.length; j++) {
            const raw = root._client.first(gl[j].Genre);
            // MPD reports the untagged songs as a genre with an empty name.
            // A nameless row in a genre browser is noise; the UI can offer its
            // own "everything else" if it wants one.
            if (!raw) continue;
            const fold = root._foldGenre(raw);
            const n = root._int(gl[j].songs, 0);
            if (byFold[fold] === undefined) {
                byFold[fold] = { name: raw, songCount: 0, albumCount: 0, weight: 0, duration: 0 };
                foldOrder.push(fold);
            }
            const g = byFold[fold];
            g.songCount += n;
            // `count … group genre` answers `playtime` (seconds) beside `songs`.
            g.duration += root._num(gl[j].playtime, 0);
            if (n > g.weight) { g.weight = n; g.name = raw; }
        }
        root._genreFold = byFold;
        root._genreOrder = foldOrder;

        // Which genre each album is. `list genre … group albumartist group
        // album` emits the group values as they change and then the item, so
        // the same context walk as above reads it — and the FIRST genre listed
        // for an album is its main one, which is the only one for every album
        // in this library.
        const gmap = ({});
        const gctx = ({});
        const glines = groups[2] || [];
        for (let m = 0; m < glines.length; m++) {
            const kv2 = root._client.parseKV([glines[m]]);
            const ks = Object.keys(kv2);
            if (ks.length === 0) continue;
            if (ks[0] !== "Genre") { gctx[ks[0]] = kv2[ks[0]]; continue; }
            if (!kv2.Genre) continue;
            const akey = (gctx.AlbumArtist || "") + "\u0000" + (gctx.Album || "");
            if (gmap[akey] === undefined) gmap[akey] = kv2.Genre;
        }
        root._albumGenre = gmap;

        if (pending.length === 0) {
            // No albums at all — a machine with no `Albums/` directory. The
            // genre histogram is still real, so it is published with an album
            // count of zero rather than dropped on the floor.
            const empty = [];
            for (let g = 0; g < root._genreOrder.length; g++)
                empty.push(root._genreFold[root._genreOrder[g]]);
            empty.sort((x, y) => root._byName(x.name, y.name));
            root._genres = empty;
            root._albums = [];
            root._artists = [];
            root._albumCounts = ({});
            root._libraryLoading = false;
            root._libraryLoaded = true;
            root._flushGenreWaiters();
            return;
        }
        root._pendingAlbums = pending;
        const cmds = [];
        for (let p = 0; p < pending.length; p++) {
            const f = root._albumFilter(pending[p].albumArtist, pending[p].album);
            cmds.push("count " + f);
            cmds.push("find " + f + " window 0:1");
        }
        root._sendAll(cmds, (ok2, groups2) => root._libraryPhase2(ok2, groups2));
    }

    function _libraryPhase2(ok, groups) {
        const list = root._pendingAlbums;
        root._pendingAlbums = [];
        if (!ok) {
            root._libraryLoading = false;
            root._flushGenreWaiters();
            return;
        }
        const counts = ({});
        for (let i = 0; i < list.length; i++) {
            const cnt = root._client.parseKV(groups[i * 2] || []);
            list[i].songCount = root._int(cnt.songs, 0);
            // The album's total length, from the same `count` (`playtime`, seconds): what a detail page
            // and a sort by length read, without opening the album.
            list[i].duration = root._num(cnt.playtime, 0);
            const akey = list[i].albumArtist + "\u0000" + list[i].album;
            list[i].genre = root._albumGenre[akey] || "";
            // Keyed the way a SONG keys its album, and filled from the list
            // BEFORE the double credits are merged — so a song crediting
            // either artist finds the same total. This is what tells a
            // recently-played album run whether it is the whole record.
            counts[akey] = list[i].songCount;
            const recs = root._client.parseObjects(groups[i * 2 + 1] || [], "file");
            if (recs.length > 0) {
                const file = recs[0].file || "";
                const slash = file.lastIndexOf("/");
                list[i].dirUri = slash > 0 ? file.substring(0, slash) : "";
                if (list[i].dirUri) root._firstFileByDir[list[i].dirUri] = file;
                list[i].dirPath = slash > 0 ? root.musicDir + "/" + file.substring(0, slash) : root.musicDir;
                list[i].coverUrl = root.coverUrlFor(file);
                list[i].date = root._client.first(recs[0].Date);
            }
            list[i].year = root._yearOf(list[i].date);
        }

        // Artists come from the tree BEFORE it is deduplicated: an album
        // credited to two album artists belongs to both of their shelves.
        const byArtist = {};
        const order = [];
        for (let k = 0; k < list.length; k++) {
            const n = list[k].albumArtist;
            if (byArtist[n] === undefined) {
                byArtist[n] = { albums: 0, songs: 0, duration: 0, genres: ({}) };
                order.push(n);
            }
            const a = byArtist[n];
            a.albums++;
            a.songs += list[k].songCount;
            a.duration += list[k].duration || 0;
            // An artist's genre is the one they have the most SONGS of, not
            // the most albums of: two EPs do not outweigh a double album.
            const gf = root._foldGenre(list[k].genre);
            if (gf) a.genres[gf] = (a.genres[gf] || 0) + list[k].songCount;
        }
        const arts = [];
        for (let m = 0; m < order.length; m++) {
            const a = byArtist[order[m]];
            let best = "";
            let bestN = -1;
            const gks = Object.keys(a.genres);
            for (let g = 0; g < gks.length; g++) {
                // Ties broken by name, so the answer does not depend on the
                // order the daemon happened to list an artist's albums in.
                if (a.genres[gks[g]] > bestN
                        || (a.genres[gks[g]] === bestN && gks[g] < best)) {
                    bestN = a.genres[gks[g]];
                    best = gks[g];
                }
            }
            arts.push({
                name: order[m],
                albumCount: a.albums,
                songCount: a.songs,
                duration: a.duration,
                loose: false,
                genre: best && root._genreFold[best] ? root._genreFold[best].name : ""
            });
        }
        arts.sort((x, y) => root._byName(x.name, y.name));
        root._artists = arts;

        // …but the album GRID must not show one record twice. `list album
        // group albumartist` returns a row per credited album artist, so the
        // one album here with two of them comes back twice, with the same 13
        // songs counted under each — 39 albums and 540 songs where the daemon
        // knows 38 and 527. The physical album is its directory, so that is
        // what merges them, and the row keeps every credit in `albumArtists`
        // while `albumArtist` stays the single filter-safe primary.
        const seen = {};
        const merged = [];
        for (let d = 0; d < list.length; d++) {
            const row = list[d];
            const key = row.dirPath || (row.albumArtist + "\u0000" + row.album);
            if (seen[key] === undefined) {
                seen[key] = merged.length;
                row.albumArtists = [row.albumArtist];
                merged.push(row);
            } else {
                const t = merged[seen[key]];
                if (t.albumArtists.indexOf(row.albumArtist) < 0) t.albumArtists.push(row.albumArtist);
                if (!t.genre && row.genre) t.genre = row.genre;
            }
        }
        merged.sort((x, y) => {
            const c = root._byName(x.albumArtist, y.albumArtist);
            if (c !== 0) return c;
            if (x.date !== y.date) return x.date < y.date ? -1 : 1;
            return root._byName(x.album, y.album);
        });
        root._albums = merged;
        root._albumCounts = counts;

        // How many ALBUMS a genre has, which is the count its header shows: a
        // genre opens into albums, not straight into songs.
        // Counted on the merged shelf, so the album with two credits is one.
        const gs = [];
        for (let g = 0; g < root._genreOrder.length; g++) {
            const e = root._genreFold[root._genreOrder[g]];
            e.albumCount = 0;
            gs.push(e);
        }
        for (let a2 = 0; a2 < merged.length; a2++) {
            const e2 = root._genreFold[root._foldGenre(merged[a2].genre)];
            if (e2) e2.albumCount++;
        }
        gs.sort((x, y) => root._byName(x.name, y.name));
        root._genres = gs;

        root._libraryLoading = false;
        root._libraryLoaded = true;
        root._flushGenreWaiters();
    }

    // Everything that asked for a genre's albums before the shelf existed.
    function _flushGenreWaiters() {
        const w = root._genreWaiters;
        if (w.length === 0) return;
        root._genreWaiters = [];
        for (let i = 0; i < w.length; i++)
            w[i].cb(root._albumsOfGenreNow(w[i].name));
    }

    function _albumsOfGenreNow(name) {
        const fold = root._foldGenre(name);
        const al = root._albums || [];
        const out = [];
        for (let i = 0; i < al.length; i++)
            if (root._foldGenre(al[i].genre) === fold) out.push(al[i]);
        return out;
    }

    // MPD sorts by bytes, which files `airiel`, `blinch` and `my bloody
    // valentine` after every capitalised name. Nobody reads a library that
    // way, so every list this file hands out is sorted case-insensitively.
    function _byName(a, b) {
        const x = String(a || "").toLowerCase();
        const y = String(b || "").toLowerCase();
        return x < y ? -1 : (x > y ? 1 : 0);
    }

    // ---- Which directories have a cover ------------------------------------
    //
    // Two steps, because MPD cannot answer it in one: `lsinfo` names the
    // directories, `listfiles` says what is IN each of them — including the
    // files the database does not index, which is the only way to see a
    // `cover.jpg` at all.
    //
    // It is its own command list, not a tail on the library's, for one reason:
    // `lsinfo`/`listfiles` on a directory that is not there ACKs, an ACK aborts
    // the rest of a command list, and the shelf must not be able to fail
    // because a machine has no `Playlists/`. Neither step trusts `ok`; the
    // groups that did arrive are used.
    function _scanCovers() {
        if (!root.scanCovers || !root.connected || root._coverScanning) return;
        root._coverScanning = true;
        // The fallible one LAST: `Playlists/` is the directory a fresh machine
        // is least likely to have.
        root._sendAll(["lsinfo " + root._q(root.albumsSubdir),
                       "lsinfo " + root._q(root.playlistsSubdir)],
                      (ok, groups) => root._coverDirs(groups || []));
    }

    function _coverDirs(groups) {
        const dirs = [];
        for (let g = 0; g < groups.length; g++) {
            const recs = root._client.parseObjects(groups[g] || [], "directory");
            for (let i = 0; i < recs.length; i++) {
                const uri = root._client.first(recs[i].directory);
                if (uri) dirs.push(uri);
            }
        }
        // The loose songs live in a directory too, and it is the one the
        // module knows without being told.
        if (root.tracksSubdir) dirs.push(root.tracksSubdir);
        if (dirs.length === 0) {
            root._coverScanning = false;
            root._coversScanned = true;
            return;
        }
        const cmds = [];
        for (let d = 0; d < dirs.length; d++)
            cmds.push("listfiles " + root._q(dirs[d]));
        root._sendAll(cmds, (ok, gs) => root._coverFiles(dirs, gs || []));
    }

    function _coverFiles(dirs, groups) {
        const map = ({});
        const keys = Object.keys(root._coverByDir);
        for (let k = 0; k < keys.length; k++) map[keys[k]] = root._coverByDir[keys[k]];
        const mt = ({});
        const mkeys = Object.keys(root._mtimeByFile);
        for (let m = 0; m < mkeys.length; m++) mt[mkeys[m]] = root._mtimeByFile[mkeys[m]];
        for (let i = 0; i < dirs.length && i < groups.length; i++) {
            // ONE parse, TWO answers. `listfiles` gives `file` / `size` /
            // `Last-Modified` per entry, and both questions this module asks of
            // a directory are answered by the same records.
            const recs = root._client.parseObjects(groups[i] || [], "file");
            map[dirs[i]] = root._pickCover(recs);
            root._takeMtimes(dirs[i], recs, mt);
        }
        root._coverByDir = map;
        root._mtimeByFile = mt;
        root._coverScanning = false;
        root._coversScanned = true;
        root._reseatDerived();
    }

    // The first of `coverNames` the directory actually holds, matched without
    // regard to case (a `Cover.jpg` is a cover), and "" when it holds none.
    function _pickCover(recs) {
        const have = ({});
        for (let i = 0; i < recs.length; i++) {
            const name = root._client.first(recs[i].file);
            if (!name) continue;
            have[String(name).toLowerCase()] = name;
        }
        for (let n = 0; n < root.coverNames.length; n++) {
            const want = String(root.coverNames[n]).toLowerCase();
            if (have[want] !== undefined) return have[want];
        }
        return "";
    }

    // The mtimes of one directory's entries, into `out`, keyed by the uri a
    // song record carries. `listfiles` names the entries relative to the
    // directory it was asked about.
    //
    // THE DATABASE'S OWN `Last-Modified` IS NOT USED, and that is the whole
    // point of taking it from here. MPD keeps the value it saw when it last
    // INDEXED the file, so it is right only until a file changes under a
    // daemon that has not rescanned: measured on this library before a rescan,
    // `lsinfo "Tracks"` named `Muse - Uprising` as its newest while the
    // directory named `Future Islands - Seasons (Waiting on You)` -- and the
    // directory was right, because that is the one that was downloaded last
    // and the favourites are numbered in the order they were downloaded.
    // `listfiles` reads the directory, so it cannot be stale; and this module
    // already runs it once per directory for the covers.
    function _takeMtimes(dir, recs, out) {
        for (let i = 0; i < recs.length; i++) {
            const name = root._client.first(recs[i].file);
            if (!name) continue;
            const t = root._epochOf(root._client.first(recs[i]["Last-Modified"]));
            if (t > 0) out[dir + "/" + name] = t;
        }
    }

    // MPD's ISO-8601 UTC stamp ("2001-02-03T04:05:06Z") -> epoch SECONDS, 0
    // when there is none or it does not parse.
    function _epochOf(iso) {
        if (!iso) return 0;
        const ms = Date.parse(String(iso));
        return isFinite(ms) ? Math.floor(ms / 1000) : 0;
    }

    // A file's mtime as the directory read saw it, 0 while the scan has not
    // reached it. Public because a list that numbers itself by it needs to ask
    // about a file it holds only the name of.
    function modifiedOf(file) {
        if (!file) return 0;
        const t = root._mtimeByFile[String(file)];
        return t === undefined ? 0 : t;
    }

    // Everything built before the answer landed, told the truth. A song record
    // is a snapshot — `coverUrl` and `lastModified` are written into it once —
    // so the records that are still being shown are the ones that have to be
    // rewritten: the current song, the queue, the resolved-record cache the
    // played list is built from, and the shelf.
    function _reseatDerived() {
        if (root._current) {
            const fixed = root._withDerived(root._current);
            if (fixed) root._current = fixed;
        }
        const q = root._queue || [];
        let moved = false;
        const nq = [];
        for (let i = 0; i < q.length; i++) {
            const f = root._withDerived(q[i]);
            moved = moved || f !== null;
            nq.push(f ? f : q[i]);
        }
        if (moved) root._queue = nq;

        const cache = ({});
        const keys = Object.keys(root._songCache);
        let cmoved = false;
        for (let k = 0; k < keys.length; k++) {
            const rec = root._songCache[keys[k]];
            const f2 = rec ? root._withDerived(rec) : null;
            cmoved = cmoved || f2 !== null;
            cache[keys[k]] = f2 ? f2 : rec;
        }
        if (cmoved) root._songCache = cache;

        // The shelf keeps the album's directory as a uri of its own, which is
        // the thing the cover belongs to.
        // The shelf asks THROUGH its first song, not about its directory: a
        // directory with no cover file has no picture of its own, and the row
        // that showed nothing for it is the one the album's own tracks can
        // answer. `coverUrlFor` is directory-first, so nothing changes
        // for the 37 that have one.
        const al = root._albums || [];
        let amoved = false;
        for (let a = 0; a < al.length; a++) {
            const dirUri = al[a].dirUri || "";
            const ff = root._firstFileByDir[dirUri];
            const want = ff ? root.coverUrlFor(ff) : root.coverUrlForDir(dirUri);
            if (want !== al[a].coverUrl) { al[a].coverUrl = want; amoved = true; }
        }
        if (amoved) root._albums = al.slice();

        // The lists' pictures, which are read out of the same extractions.
        root._seatListCovers();

        // ASKED LAST, SO EXTRACTED NEXT. The want list is newest-first and
        // bounded, and a queue longer than that bound would otherwise push the
        // song under the needle off the end of it -- which is the one picture
        // the record is actually wearing.
        if (root._currentFile.length > 0) root.coverUrlFor(root._currentFile);
    }

    // A copy of `song` with the cover AND the mtime it should have, or null
    // when it already has both. Copied rather than mutated: a record handed out
    // is a snapshot, and a list only redraws when the property it is bound to
    // changes. Both fields come from the same directory read, so a record built
    // before it landed is wrong about both and is fixed in one pass.
    function _withDerived(song) {
        if (!song || !song.file) return null;
        const url = root.coverUrlFor(song.file);
        const mt = root.modifiedOf(song.file);
        if (url === song.coverUrl && mt === song.lastModified) return null;
        const out = ({});
        const props = Object.keys(song);
        for (let i = 0; i < props.length; i++) out[props[i]] = song[props[i]];
        out.coverUrl = url;
        out.lastModified = mt;
        return out;
    }

    // ---- The artists who have no album -------------------------------------
    //
    // Two counts, one per directory that holds loose songs, each in its OWN
    // round trip: either directory may be missing on another machine, and one
    // ACK must not take the other's answer with it. `count … group albumartist`
    // gives the name and the song count in one line pair, and MPD's own
    // fallback to `Artist` is what makes it work at all for files that carry no
    // `AlbumArtist` tag (measured: 25 artists in `Tracks/`, 29 in the playlist
    // directory, 41 of them with no album on the shelf).
    function _loadLooseArtists() {
        if (!root.connected || root._looseLoaded) return;
        root._looseLoaded = true;
        const roots = [root.tracksSubdir, root.playlistsSubdir];
        const found = ({});
        // Whether ANY of the questions came back. A teardown answers every
        // waiting caller with ok = false, so without this an empty result
        // would replace a good list and the latch would keep it that way.
        let answered = false;
        let left = 0;
        for (let i = 0; i < roots.length; i++)
            if (roots[i]) left++;
        // A host with neither directory has a real, empty answer.
        if (left === 0) { root._seatLoose(found, true); return; }
        for (let i = 0; i < roots.length; i++) {
            if (!roots[i]) continue;
            root._client.send("count " + root._baseArg(roots[i]) + " group albumartist",
                              (ok, lines) => {
                if (ok) {
                    answered = true;
                    const recs = root._client.parseObjects(lines, "AlbumArtist");
                    for (let r = 0; r < recs.length; r++) {
                        const n = root._client.first(recs[r].AlbumArtist);
                        if (!n) continue;
                        found[n] = (found[n] || 0) + root._int(recs[r].songs, 0);
                    }
                }
                if (--left <= 0) root._seatLoose(found, answered);
            });
        }
    }

    function _seatLoose(found, answered) {
        // Nothing came back at all: keep whatever is on the list and drop the
        // latch, so the next connect asks again instead of showing an empty
        // shelf under a toggle that says the loose artists are included.
        if (!answered) {
            root._looseLoaded = false;
            return;
        }
        const out = [];
        const names = Object.keys(found);
        for (let i = 0; i < names.length; i++)
            out.push({ name: names[i], songCount: found[names[i]] });
        out.sort((a, b) => root._byName(a.name, b.name));
        root._looseArtists = out;
    }

    // The two shelves as one list. Pure: `artists` is a binding on it, so the
    // flag going off cannot leave anybody behind.
    function _mergeArtists(shelf, loose, include) {
        const src = shelf || [];
        if (!include) return src;
        const extra = ({});
        const ll = loose || [];
        for (let i = 0; i < ll.length; i++) extra[ll[i].name] = ll[i].songCount;
        const out = [];
        for (let j = 0; j < src.length; j++) {
            const a = src[j];
            const add = extra[a.name] || 0;
            delete extra[a.name];
            out.push(add === 0 ? a : {
                name: a.name, albumCount: a.albumCount, genre: a.genre,
                songCount: (a.songCount || 0) + add, loose: false
            });
        }
        const rest = Object.keys(extra);
        for (let k = 0; k < rest.length; k++)
            out.push({ name: rest[k], albumCount: 0, genre: "",
                       songCount: extra[rest[k]], loose: true });
        out.sort((x, y) => root._byName(x.name, y.name));
        return out;
    }

    // ---- The lists ----------------------------------------------------------

    // `groups[0]` is `listplaylists`, `groups[1]` the `lsinfo` of the playlist
    // directory — which may be missing entirely, so a group that is not there
    // is read as empty rather than as a failure.
    function _playlistsPhase1(groups) {
        const out = [];
        // Favorites first, and synthetic: it is a directory of loose songs the
        // source calls favourites, not something this module invented, and not
        // something the GUI ever edits.
        out.push({
            name: root.favoritesName,
            uri: root.tracksSubdir,
            kind: "songdir",
            synthetic: true,
            songCount: -1,
            modified: "",
            // Up to four of the list's own songs' covers, de-duplicated and in
            // the list's order. Empty until `_scanListCovers` has answered.
            coverUrls: root._listCoversOf(root.tracksSubdir)
        });

        const dirs = root._client.parseObjects(groups[1] || [], "directory");
        const dirRows = [];
        for (let i = 0; i < dirs.length; i++) {
            const uri = root._client.first(dirs[i].directory);
            if (!uri) continue;
            const slash = uri.lastIndexOf("/");
            dirRows.push({
                name: slash >= 0 ? uri.substring(slash + 1) : uri,
                uri: uri,
                kind: "songdir",
                synthetic: false,
                songCount: -1,
                modified: root._client.first(dirs[i]["Last-Modified"]) || "",
                coverUrls: root._listCoversOf(uri)
            });
        }
        dirRows.sort((x, y) => root._byName(x.name, y.name));

        const stored = root._client.parseObjects(groups[0] || [], "playlist");
        const storedRows = [];
        for (let j = 0; j < stored.length; j++) {
            const name = root._client.first(stored[j].playlist);
            if (!name) continue;
            storedRows.push({
                name: name,
                uri: name,
                kind: "stored",
                synthetic: false,
                // A stored playlist's length is `listplaylistinfo`, which is
                // the whole playlist — too much to ask for a subtitle. It is
                // counted when somebody opens it.
                songCount: -1,
                modified: root._client.first(stored[j]["Last-Modified"]) || "",
                coverUrls: root._listCoversOf(name)
            });
        }
        storedRows.sort((x, y) => root._byName(x.name, y.name));

        root._playlists = out.concat(dirRows, storedRows);
        root._countPlaylistDirs();
        root._scanListCovers();
    }

    // One `count` per directory list, in one command list. Favorites goes LAST
    // because it is the one whose directory this module assumes rather than
    // discovered: `count "(base 'Nope')"` ACKs, and an ACK aborts the rest of
    // the list, so the assumption cannot cost the counts that were real.
    function _countPlaylistDirs() {
        const rows = root._playlists;
        const want = [];
        for (let i = 0; i < rows.length; i++)
            if (rows[i].kind === "songdir" && !rows[i].synthetic) want.push(rows[i].uri);
        for (let j = 0; j < rows.length; j++)
            if (rows[j].kind === "songdir" && rows[j].synthetic) want.push(rows[j].uri);
        if (want.length === 0) return;
        const cmds = [];
        for (let k = 0; k < want.length; k++)
            cmds.push("count " + root._baseArg(want[k]));
        root._sendAll(cmds, (ok, groups) => {
            // The answers are seated by URI, not by the index they were asked
            // at: a `database` event and a `stored_playlist` event can both be
            // in flight, and the second list would otherwise take the first
            // list's numbers.
            const got = ({});
            for (let m = 0; m < want.length && m < groups.length; m++) {
                const kv = root._client.parseKV(groups[m] || []);
                if (kv.songs !== undefined) got[want[m]] = root._int(kv.songs, -1);
            }
            const list = [];
            const live = root._playlists;
            for (let n = 0; n < live.length; n++) {
                const row = live[n];
                if (got[row.uri] === undefined) { list.push(row); continue; }
                // Copied field by field rather than rebuilt from a literal:
                // a literal is where a new field (`coverUrls`, say) goes
                // missing.
                const copy = ({});
                const props = Object.keys(row);
                for (let q = 0; q < props.length; q++) copy[props[q]] = row[props[q]];
                copy.songCount = got[row.uri];
                list.push(copy);
            }
            root._playlists = list;
        });
    }

    // A list's own order, applied to the songs of it. `songs` arrives sorted by
    // file name, which is both the fallback and the tiebreak: a list nobody
    // numbered is in the order the directory is in, and two files carrying the
    // same number keep it.
    //
    // FAVORITES IS THE ONE ORDERED BY TIME. `Tracks/` is the source's
    // favourites, downloaded one after another in the order they were
    // favourited, and the app they came from shows the newest at the top --
    // so newest first, by the DIRECTORY's mtime (`lastModified`), never by
    // MPD's database `Last-Modified`, which is only as fresh as the last
    // rescan. A file the directory read has not reached yet carries 0 and
    // sorts last, and `_reseatDerived` is what makes the answer right once it
    // lands.
    function _listOrder(songs, entry) {
        const l = songs || [];
        const dec = [];
        for (let i = 0; i < l.length; i++)
            dec.push({ s: l[i], at: i, n: root._fileNumber(l[i].file) });
        if (entry && entry.synthetic === true) {
            dec.sort((a, b) => {
                const ta = Number(a.s.lastModified) || 0;
                const tb = Number(b.s.lastModified) || 0;
                return ta === tb ? a.at - b.at : tb - ta;
            });
        } else {
            // An unnumbered file goes after every numbered one rather than
            // ahead of "01.": a list that is half numbered is a list somebody
            // added to, and the additions are the unnumbered half.
            dec.sort((a, b) => {
                if (a.n !== b.n) {
                    if (a.n === 0) return 1;
                    if (b.n === 0) return -1;
                    return a.n - b.n;
                }
                return a.at - b.at;
            });
        }
        const out = [];
        for (let j = 0; j < dec.length; j++) out.push(dec[j].s);
        return out;
    }

    // The `NN.` at the head of a file's own name ("01. Artist - Title.m4a"),
    // 0 where the name carries none. Robust about the separator (a dot, a
    // bracket, a dash, an underscore or plain whitespace) and deliberately NOT
    // robust about a year: "1999 - Song.flac" is not a numbered file, so the
    // digits have to be followed by something that separates them from the
    // name. PlayerLibrary._fileNumber is the same rule with the row's position
    // as its fallback.
    function _fileNumber(file) {
        const u = String(file || "");
        const cut = u.lastIndexOf("/");
        const base = cut >= 0 ? u.substring(cut + 1) : u;
        const m = /^\s*(\d{1,3})\s*(?:[.)\-_]\s*|\s+)/.exec(base);
        if (m === null) return 0;
        const n = parseInt(m[1], 10);
        return n > 0 ? n : 0;
    }

    // ---- What a list looks like ---------------------------------------------
    //
    // A list has no picture of its own, so it wears up to four of its songs'.
    // Asking for them is asking the SONGS -- one `find` per directory list,
    // through the same `songsOfPlaylist` that orders it, so the four pictures
    // are the first four distinct ones IN THE LIST'S ORDER rather than four
    // arbitrary ones.
    //
    // NOTHING WAITS FOR THEM. A loose song's picture is inside the file and
    // costs a process, so the first pass usually answers with fewer than four
    // -- often none. The row is seated with what there is and re-seated when
    // the extractions land, exactly as a record is dressed when its art arrives
    // late: `_reseatDerived` is on the same 60 ms coalescing timer.
    function _scanListCovers() {
        const rows = root._playlists || [];
        for (let i = 0; i < rows.length; i++) {
            const uri = rows[i].uri;
            root.songsOfPlaylist(rows[i].name, songs => {
                const files = [];
                for (let j = 0; j < songs.length && j < root.listCoverProbe; j++)
                    if (songs[j] && songs[j].file) files.push(songs[j].file);
                const map = ({});
                const keys = Object.keys(root._listFiles);
                for (let k = 0; k < keys.length; k++) map[keys[k]] = root._listFiles[keys[k]];
                map[uri] = files;
                root._listFiles = map;
                root._seatListCovers();
            });
        }
    }

    // The rows told what they look like now. Rewrites `_playlists` only when a
    // row's pictures actually changed -- it is called from `_reseatDerived`,
    // which runs on every batch of extractions, and a list that redrew for an
    // unchanged array would flicker through a whole favourites list.
    function _seatListCovers() {
        const rows = root._playlists || [];
        if (rows.length === 0) return;
        const out = [];
        let moved = false;
        for (let i = 0; i < rows.length; i++) {
            const want = root._listCoversOf(rows[i].uri);
            const have = rows[i].coverUrls || [];
            if (want.length === have.length && want.join("\u0000") === have.join("\u0000")) {
                out.push(rows[i]);
                continue;
            }
            const copy = ({});
            const props = Object.keys(rows[i]);
            for (let k = 0; k < props.length; k++) copy[props[k]] = rows[i][props[k]];
            copy.coverUrls = want;
            out.push(copy);
            moved = true;
        }
        if (moved) root._playlists = out;
    }

    // The first `listCoverCount` DISTINCT pictures among the files the probe
    // took. A file with no answer yet contributes nothing and is simply passed
    // over; asking is what registers the extraction, so the next pass has more
    // to work with.
    function _listCoversOf(uri) {
        const files = root._listFiles[uri] || [];
        const out = [];
        for (let i = 0; i < files.length && out.length < root.listCoverCount; i++) {
            const u = root.coverUrlFor(files[i]);
            if (u.length > 0 && out.indexOf(u) < 0) out.push(u);
        }
        return out;
    }

    function _playlistEntry(name) {
        const rows = root._playlists || [];
        for (let i = 0; i < rows.length; i++)
            if (rows[i].name === name) return rows[i];
        // Favorites is the one row this file knows without being told, so a
        // caller that asks for it before the list has loaded still gets the
        // Tracks directory rather than an ACK for a stored playlist that does
        // not exist.
        if (name === root.favoritesName)
            return { name: name, uri: root.tracksSubdir, kind: "songdir",
                     synthetic: true, songCount: -1, modified: "" };
        return null;
    }

    // ---- Recently played ----------------------------------------------------

    function _recentStickers(ok, groups) {
        if (!ok) return;                  // no sticker db configured: no list
        const recs = root._client.parseObjects(groups[0] || [], "file");
        // file -> the raw second half of the same play. A file that is in here
        // with an empty value was played as part of NO list, and that is an
        // answer; a file that is not in here at all was played before this
        // module wrote the second sticker, and `hasList` is what keeps a delete
        // for one of those out of a command list.
        const raws = ({});
        const lrecs = root._client.parseObjects(groups[1] || [], "file");
        for (let j = 0; j < lrecs.length; j++) {
            const lf = root._client.first(lrecs[j].file);
            if (!lf) continue;
            const lraw = root._client.first(lrecs[j].sticker) || "";
            const leq = lraw.indexOf("=");
            raws[lf] = leq >= 0 ? lraw.substring(leq + 1) : "";
        }
        const stamped = [];
        const need = [];
        for (let i = 0; i < recs.length; i++) {
            const f = root._client.first(recs[i].file);
            if (!f) continue;
            const raw = root._client.first(recs[i].sticker) || "";
            const eq = raw.indexOf("=");
            const t = eq >= 0 ? parseInt(raw.substring(eq + 1), 10) : 0;
            const o = root._listOfSticker(raws[f]);
            stamped.push({ file: f, at: isFinite(t) ? t : 0, list: o.name,
                           listIndex: o.index, hasList: raws[f] !== undefined });
            if (root._songCache[f] === undefined) need.push(f);
        }
        // The daemon sorted it (`sort -value_int`); sorted again because the
        // grouping depends on the order being right and this costs nothing.
        stamped.sort((x, y) => y.at - x.at);
        if (need.length === 0) { root._seatRecent(stamped); return; }
        const cmds = [];
        for (let n = 0; n < need.length; n++)
            cmds.push("find \"(file == '" + root._fv(need[n]) + "')\"");
        root._client.sendAll(cmds, (ok2, groups) => {
            const cache = ({});
            const keys = Object.keys(root._songCache);
            for (let k = 0; k < keys.length; k++) cache[keys[k]] = root._songCache[keys[k]];
            for (let g = 0; g < need.length && g < groups.length; g++) {
                const r = root._client.parseObjects(groups[g] || [], "file");
                // A file that has left the library is remembered as null, so
                // it is not asked for again on every reload.
                cache[need[g]] = r.length > 0 ? root._songOf(r[0]) : null;
            }
            root._songCache = cache;
            root._seatRecent(stamped);
        });
    }

    function _seatRecent(stamped) {
        const out = [];
        for (let i = 0; i < stamped.length; i++) {
            const song = root._songCache[stamped[i].file];
            if (song) out.push({ song: song, at: stamped[i].at,
                                 list: stamped[i].list, listIndex: stamped[i].listIndex,
                                 hasList: stamped[i].hasList });
        }
        root._recentSongs = out;
    }

    // "<place>:<list>" back apart. An empty value is a play that was part of no
    // list; a value with no colon is a name with no place, which is what a
    // sticker written by any other client would look like.
    function _listOfSticker(raw) {
        const v = String(raw === undefined ? "" : raw);
        if (v === "") return { name: "", index: 0 };
        const c = v.indexOf(":");
        if (c < 0) return { name: v, index: 0 };
        const n = parseInt(v.substring(0, c), 10);
        return { name: v.substring(c + 1), index: isFinite(n) && n > 0 ? n : 0 };
    }

    // Drop these files from the played list and from the sticker database.
    // The list is trimmed here rather than waited for: the daemon echoes the
    // write back as `changed: sticker` a round trip later and rebuilds the
    // same answer, but the row has to leave when the button is pressed.
    function _forgetPlayed(files, listFiles) {
        const f = files || [];
        const lf = listFiles || [];
        if (f.length === 0 && lf.length === 0) return;
        const gone = ({});
        for (let i = 0; i < f.length; i++) gone[f[i]] = 1;
        const keep = [];
        const src = root._recentSongs || [];
        for (let j = 0; j < src.length; j++)
            if (gone[src[j].song.file] === undefined) keep.push(src[j]);
        root._recentSongs = keep;
        const cmds = [];
        for (let k = 0; k < f.length; k++)
            cmds.push("sticker delete song " + root._q(f[k]) + " " + root.stickerName);
        // The play histories go FIRST and what each play was part of after
        // them, for the reason below: an ACK on one of the second kind must not
        // be able to take the first kind with it.
        for (let m = 0; m < lf.length; m++)
            cmds.push("sticker delete song " + root._q(lf[m]) + " " + root.listStickerName);
        // One command list. A file that left the database between the read and
        // this write ACKs and stops the rest — a second press finishes the job,
        // and the alternative (a round trip per file) costs more every time to
        // insure against a race that needs a rescan mid-click.
        root._sendAll(cmds, null);
    }

    // THE RUN A PLAY BELONGS TO: the list it was played as part of where there
    // was one, the album otherwise. ONE rule, so a list and an album group by
    // the same code and cannot come to disagree about what a run is.
    //
    // NO ALBUM AND NO LIST IS NOT A RUN. An untagged file groups with nothing,
    // or two loose songs by one artist would wear a header over an album that
    // does not exist.
    function _runKeyOfRow(row) {
        if (row && row.list) return "list\u0000" + row.list;
        return root._albumKeyOf(row ? row.song : null);
    }
    // The lists tab's row for a name, out of the rows handed in. It carries the
    // list's length and its pictures; a list nobody has loaded yet answers with
    // neither, and the entry is still a list entry.
    function _listRowOf(name, lists) {
        const l = lists || [];
        for (let i = 0; i < l.length; i++)
            if (l[i] && l[i].name === name) return l[i];
        return null;
    }

    // The whole of the grouping, as a function of its inputs and nothing else.
    //
    //   rows           [{song, at, list, listIndex}] — every file with a
    //                  played-at sticker, and what the play was part of
    //   currentFile    the song under the needle: not played yet, so not here
    //   predictKey     the album the queue says is still being played through
    //   counts         albumKey -> how many songs the album has
    //   predictListKey the same for a list
    //   lists          the lists tab's rows, for a list run's length and covers
    //
    // Consecutive plays of one run fold into one entry. Consecutive in TIME:
    // interrupt an album with one other song and the run ends there, and what
    // follows starts a new one — which is what "the grouping stops" means.
    // A run of one is a plain song, because a header over a single track says
    // something that did not happen.
    //
    // The exception is the run being played RIGHT NOW with more of itself
    // queued ahead: it groups from its first finished song, and each next one
    // joins it, so the entry fills in as the record plays. It is the last run
    // by construction — anything played after it would have ended it.
    function _groupRecent(rows, currentFile, predictKey, counts, predictListKey, lists) {
        const src = (rows || []).slice();
        src.sort((x, y) => x.at - y.at);          // play order, oldest first
        const runs = [];
        for (let i = 0; i < src.length; i++) {
            const r = src[i];
            if (!r.song || (currentFile && r.song.file === currentFile)) continue;
            const key = root._runKeyOfRow(r);
            const last = runs.length > 0 ? runs[runs.length - 1] : null;
            if (key !== "" && last && last.key === key) last.rows.push(r);
            else runs.push({ key: key, rows: [r] });
        }
        const entries = [];
        for (let j = 0; j < runs.length; j++) {
            const run = runs[j];
            const isList = run.key.indexOf("list\u0000") === 0;
            const listName = isList ? run.key.substring(5) : "";
            const predicted = run.key !== "" && j === runs.length - 1
                              && run.key === (isList ? predictListKey : predictKey);
            if (run.key !== "" && (run.rows.length > 1 || predicted)) {
                const songs = [];
                // Parallel to `songs`: the place each one holds in the LIST it
                // was played from, and 0 for an album run, where the number a
                // song wears is its own track tag.
                const places = [];
                let newest = 0;
                for (let k = 0; k < run.rows.length; k++) {
                    songs.push(run.rows[k].song);
                    places.push(isList ? (run.rows[k].listIndex || 0) : 0);
                    if (run.rows[k].at > newest) newest = run.rows[k].at;
                }
                const lrow = isList ? root._listRowOf(listName, lists) : null;
                const total = isList
                    ? (lrow && lrow.songCount > 0 ? lrow.songCount : 0)
                    : (counts && counts[run.key] !== undefined ? counts[run.key] : 0);
                entries.push({
                    kind: "album",
                    // Unique per RUN, not per album: the same record listened
                    // to twice is two entries, and removing one must not take
                    // the other with it.
                    key: (isList ? "list\u0000" + listName : "album\u0000" + run.key)
                         + "\u0000" + run.rows[0].at,
                    playedAt: newest,
                    albumArtist: isList ? "" : songs[0].albumArtist,
                    album: isList ? listName : songs[0].album,
                    coverUrl: songs[0].coverUrl,
                    // In the order they were played, which for a record played
                    // front to back is its track order and for a shuffled one
                    // is the truth.
                    songs: songs,
                    songCount: total,
                    predicted: predicted,
                    partial: predicted || (total > 0 && songs.length < total),
                    list: listName,
                    listCovers: lrow ? (lrow.coverUrls || []) : [],
                    listIndex: places
                });
            } else {
                for (let m = 0; m < run.rows.length; m++) {
                    const song = run.rows[m].song;
                    const e = ({});
                    const props = Object.keys(song);
                    for (let p = 0; p < props.length; p++) e[props[p]] = song[props[p]];
                    e.kind = "song";
                    e.key = "song\u0000" + song.file;
                    e.playedAt = run.rows[m].at;
                    // The song's own fields are on the entry (a song entry is
                    // a plain song object with playedAt). `song` points at
                    // the same record as well, because the mock run nests it
                    // that way and a row that reads `e.song.title` must not
                    // depend on which source it is looking at.
                    e.song = song;
                    entries.push(e);
                }
            }
        }
        entries.reverse();                         // newest first, as shown
        const lim = Math.max(1, root.recentLimit);
        return entries.length > lim ? entries.slice(0, lim) : entries;
    }

    // `mode` is how the answer is ordered: "track" (disc then track, one
    // album), "album" (album first, for a query that spans several) or "file"
    // (a directory playlist, whose numbered file names ARE its order).
    function _findSongs(argText, cb, mode, withRecs) {
        if (!root._client || !root._client.connected) {
            if (cb) cb([]);
            return;
        }
        root._client.send("find " + argText, (ok, lines) => {
            if (!ok) {
                if (cb) cb([]);
                return;
            }
            const recs = root._client.parseObjects(lines, "file");
            const out = [];
            for (let i = 0; i < recs.length; i++) {
                const so = root._songOf(recs[i]);
                if (withRecs) so._rec = recs[i];
                out.push(so);
            }
            // MPD's `sort` takes one tag, and a multi-disc album needs two.
            out.sort((x, y) => {
                if (mode === "file") return root._byName(x.file, y.file);
                if (mode === "album") {
                    const c = root._byName(x.album, y.album);
                    if (c !== 0) return c;
                }
                if (x.disc !== y.disc) return x.disc - y.disc;
                if (x.track !== y.track) return x.track - y.track;
                return root._byName(x.file, y.file);
            });
            if (cb) cb(out);
        });
    }
}
