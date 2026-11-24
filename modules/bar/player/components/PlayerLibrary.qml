pragma ComponentBehavior: Bound

import QtQuick
import "../../../common/theme"
import "../../../common/scroll"
import "../../../common/components"
import "../../../common/components/Bytes.js" as Bytes
import "../../../common/components/Mix.js" as Mix

// =============================================================================
// PlayerLibrary.qml
//
// The library browser: one carved list box with a grouping selector above it.
// Albums, artists, genres, recently played and playlists are five readings of
// the same shelf, so they are five tabs over ONE list — one box, one flick, one
// dressing, one skeleton, one row delegate. Switching grouping is a re-fill of
// that list, never a second subtree switched in beside it: a StackLayout with a
// list per view destroys and rebuilds every row on every switch, which is 64 to
// 100 ms of blocked frames (the measurement is in SystemUpdatePopup).
//
// THE BOX IS THIS FILE'S
// ----------------------
// The popup places the panel and nothing more, so the ShadowBox, the Flickable
// that fills it exactly, the row insets and the box's dressing (the shared
// `CarvedListDressing`: a fade at EACH end keyed on the scroll position, and
// the corner re-cut over the scrolling rows) are all here.
//
// THE TOP EDGE IS FLUSH, AND THE FOOT DEPENDS ON WHAT ENDS THERE
// --------------------------------------------------------------
// A row reserves half its virtual spacing above its content and half below, so
// a Column of them would start and end with a 3 px sliver of the box's fill and
// the first header would not touch the top edge. The Column is therefore lifted by
// half a spacing, and the Flickable's contentHeight is cut by the other half.
// The first header's box then starts exactly at the top edge.
//
// The foot is read from what ENDS there, and the two answers are opposite:
//
//   * a HEADER ends in a BOX, and a carved box meeting the container's edge is
//     the design (it takes the container's own corner there). The empty gap
//     the header carries under its box, inside its own row height, is trimmed
//     off the scroll extent (`_tailGap`), so the box ends on the edge.
//   * a SONG ends in bare TEXT, and text landing on the container's edge reads
//     cramped. It is given `rowFootAir` instead, as a spacer at the foot of
//     the Column.
//
// `rowFootAir` is the queue's own property, at the queue's own value, doing
// the same thing in the same place: the queue's list can only end on a song,
// so its spacer is unconditional, and this one asks. A list and the queue
// beside it that left different air under their last row would be two answers
// to one question.
//
// ONLY WHAT IS ON SCREEN ANIMATES  (docs/contracts/list_animation.md)
// -----------------------------------------------------------------
// Every wave — an expand, a collapse, a grouping swap — is cut off at the fold:
// rows that would land off-screen are PLACED, not staggered. A naive stagger
// gives row 40 a two-second delay, by which time the container has long since
// finished resizing, and the tail then flies in all at once into a list nobody
// is looking at. `_onScreen` is the whole rule, and it is asked about the
// RESTING layout (every row's height is known before the row exists) rather
// than about the items, which are still animating whenever it matters.
//
// THE TAIL IS PLACED WHEN THE HEAD HAS LANDED, NOT WHEN THE WAVE BEGINS
// ---------------------------------------------------------------------
// (the doc's section 2a). A tail that takes its height in the first frame is
// not "instant", it is EARLY: it is drawn where the head has not arrived yet,
// so row 19 is on screen above rows 1-18 and is then shoved down by them —
// which is the very defect AnimatedListRow's own comment records for a list
// that lets every row claim its space at once.
// So the tail is held in `collapsed` (zero height, no slide, nothing painted)
// until the last staggered row has entered, and takes its height in one frame
// then. By that moment the head has filled the viewport by construction, so
// the fold is where it will finally be and there is nothing on screen for the
// placement to move. `headEnd` is that clock and `_placeTail` is that frame;
// rows that land ABOVE the viewport pay their height back through the scroll,
// the mirror of the collapse's `dropAbove`.
//
// This is the one place the doc's rule 3 ("the list is at its full height from
// that instant") is read as "from the instant the head lands" rather than
// "from the first frame": section 2a says so explicitly.
//
// A LIST FOLLOWS WHAT OPENS AT ITS FOOT
// -------------------------------------
// A list already scrolled to its end has nowhere to put what opens below the
// last header, so the rows arrive off screen and the expansion reads as
// nothing having happened. The list scrolls with them (`_followExpansion`),
// and stops before the header itself would leave the top edge — the header
// staying visible is what says THIS is the thing you opened. Only when the
// block really has nowhere to go: with a couple of its rows already in view
// the expansion speaks for itself, and a list that scrolled every time a
// header opened would take the ground out from under the reader.
//
// The entrance is reassessed while it runs (the doc's rule 4), in ONE window
// and one only: while the head is still arriving and the tail is folded away,
// a scroll into the fold would show empty box, so `_unfoldToFill` asks the
// fold's own question again and lets in as many rows as the new viewport
// needs, each at its own turn.
//
// AND THE WAVE ENDS WHEN THE TAIL GOES DOWN, IN THAT SAME FRAME
// -------------------------------------------------------------
// The moment the head has landed the viewport is full and every row past it is
// at its resting height, so there is nothing left that could animate and
// nothing that may be let back into the wave. Keeping the wave open for the
// RANKS of the rows it never staggered -- rank 40 of a sixty-row fill is two
// seconds of clock nobody is watching -- and re-entering any of them a scroll
// brought near the fold would look like this: start scrolling the instant the
// list looks full and single rows fly in here and there, in no order, for as
// long as the whole fill would have taken. So both facts hold at once: nothing
// appears above the fold before the head has passed it, and the moment the
// viewport is full there is nothing left to animate.
//
// A GROUPING SWAP IS A COLLAPSE FOLLOWED BY AN EXPAND
// ---------------------------------------------------
// Not two lists passing through each other: every visible row of the old
// grouping leaves (the rest are simply gone), and only when the last of them
// has landed does the new grouping enter. The gap between the two is
// `swapGapMs` — one stagger step, the doc's "shortly after": all visible
// headers exit, THEN shortly after the new headers enter, so the clock starts
// at the END of the exit wave, not at its last kick.
//
// A GROUP'S COLOUR IS ITS GENRE'S, IN ITS HEADER'S INSET, ONCE
// ------------------------------------------------------------
// The hue in the left edge of a header's inset (ShadowBox.shadowProgress at 0
// with shadowProgressMinPx — the idle mark ListSectionHeader draws for a
// category that has not started) names the album's main GENRE, so the same
// album wears the same colour in every view it appears in, a genre header wears
// its own, and an artist wears the genre they have the most songs of. There is
// no second coloured mark: no stripe, no tinted text, no coloured chevron, and
// the genre glyph is muted ink like every other glyph.
//
// The six genres this library actually holds have hues of their own, all of
// them Theme tokens (the category set and the LLM module's six, which is the
// Catppuccin Latte palette CLAUDE.md names). Anything else is hashed onto the
// fallback ring — deterministically, so a genre keeps its colour between runs
// — and an untagged album gets the neutral, which is the honest answer. Genre
// names are folded to lower case: the library has both "SoundTrack" and
// "Soundtrack" in it.
//
// GENRES ARE TWO LEVELS DEEP
// --------------------------
// A genre is a list of albums, and an album is a list of songs. So a row's
// `depth` (0, 1, 2) is what its inset and its icon are read from, and its `key`
// (identity, expansion) is separate from its `dataKey` (the two names an album
// joins, which the songs cache and the signals are keyed by) — the same album
// can hang under two genres and must be able to be open under one of them.
//
// THE SONG THAT IS PLAYING WEARS THE QUEUE'S STRIPE
// -------------------------------------------------
// A reader browsing the library passes the song that is playing, and it is
// marked there exactly as it is in the queue beside it: the same 3 px rounded
// stripe at the head of the row, full accent while the music runs, drained
// toward the ground it lies on while it is paused, on the same eased fraction.
// One fact, one mark, and the same mark in both panels -- two panels that
// answered "which one is playing" differently would be two answers.
//
// Its slot is RESERVED on every song row, as it is in the queue: a mark that
// pushed the numbers along when the music reached the row would move half the
// list every time a track ended.
//
// A LIST'S PICTURE IS FOUR OF ITS SONGS'
// --------------------------------------
// A list has no cover of its own, so the service hands up to four of its
// songs' covers (`coverUrls`, already de-duplicated) and the slot the album's
// cover uses draws them as one picture: four fill it as a 2 x 2 grid, fewer
// than four is one picture rather than a grid with a hole in it, and none at
// all is the music note every other pictureless row wears. The slot's outer
// corners are cut once, over whichever of the three it is, so a grid takes the
// same rounding as a cover.
//
// The count is asked of the urls that are actually USABLE -- non-empty, and
// not one the missing-cover memo has already written off -- so a list whose
// fourth picture turns out not to be there falls back to one picture by
// itself, in the frame the failure is written down.
//
// WHO THE ARTIST IS, WHERE THE LIST DOES NOT SAY
// ----------------------------------------------
// Under an album header the artist is the header's own second line, and under
// an artist's shelf it is the tab. Two places have neither: a list, which is a
// run of loose files from a dozen albums, and a standalone song in recently
// played, which is not under anything. Those rows carry the artist, IN THE
// QUEUE'S OWN TREATMENT -- the muted subtitle size on the title's own line,
// right-hand end packed one gap before the duration's slot, elided at a share
// of the row (PlayerQueue's compact row, which is the queue the popup shows
// beside this panel: both take `compact` from the same `browsing`). The
// artists then form a column of their own and no row's artist moves when
// another row's title changes length.
//
// A ROW'S NUMBER IS NOT ALWAYS A TRACK NUMBER
// -------------------------------------------
// The slot at the head of a song row holds whatever numbers that song WHERE
// IT IS, and where nothing numbers it there is no slot either. Under an album
// -- its own tab, an artist's shelf, a genre's, recently played -- that is the
// tag's track number. Under a list it is not: a list is a run of loose files
// from a dozen albums, so the tags number them 1, 1, 2, 1, 3, 2 ... the same
// number several times. A list numbers its songs by the list:
//
//   Favorites (~/Music/Tracks)  the file's own mtime, NEWEST FIRST. The
//                               directory is the source's favourites list,
//                               downloaded in the order it was favourited, so
//                               the mtimes ARE that order; the app it came
//                               from puts the newest at the top, and so does
//                               this. `lastModified` (epoch seconds) is the
//                               service's field for it.
//   every other list            the `NN.` at the head of the file's own name
//                               ("01. Artist - Title.m4a"), which is where a
//                               downloaded list keeps its order, and the row's
//                               own position where the name carries none.
//
// In recently played the source has already done that numbering: a run from a
// list carries `listIndex` beside its songs, each song's place in the list,
// which is the number that survives the list being played SHUFFLED -- the tag
// would say 1, 1, 2 and the played order would say nothing at all. And a
// standalone song there is the nth of nothing: it wears no number, and no slot
// is kept for one, it being a top-level row that shares a column with none of
// the run songs a level in from it.
//
// RECENTLY PLAYED IS GROUPED BY THE SOURCE, DISPLAYED HERE
// --------------------------------------------------------
// `recent` arrives as [{kind: "album"|"song", ...}], newest first: the service
// decides what a RUN is (including one still playing whose remainder is in the
// queue) and this file draws it. A run entry carries its own songs, so opening
// one asks the host for nothing.
//
// A run is an album's or a LIST's, and both are `kind: "album"` -- that is the
// shape, a header with its songs under it, and a third kind would send every
// list run down the standalone-song path of a panel that had not learned the
// word. Where the run came from is the FIELD `list`: where it is set the header
// is the list's, exactly as the lists tab draws one (its name on one line, its
// 2 x 2 of covers, the lists tab's hue, and the list is what a right-click
// puts back in the queue), and its songs are numbered by `listIndex`.
//
// A separator marks the seam between a run and a standalone song, whichever of
// the two is on top: open, they are two runs of song rows with nothing between
// them; shut, they are a header and a song that have nothing to do with each
// other. The same thing needing the same line, so the seam does not wait for
// the run to be opened. Never between two runs -- two headers are two blocks
// already.
//
// A LEAVING ROW KEEPS THE CONTENT IT WAS DRAWN WITH
// -------------------------------------------------
// Which icon a header wears is the GROUPING's fact, not the row's, so a row
// that read it off `root.grouping` would change its icon in the first frame of
// a switch: leaving the artists tab, every artist's picture slot would turn
// into the genre glyph it is classified under, and only then fly out. So the grouping
// is written into the row when the row is built and read from there — icon,
// fallback glyph, one-line layout, hue and what a click on it means. A row on
// its way out is a picture of the list it belonged to. The side button at the
// top of the panel keeps its role the same way.
//
// WHY THE HEADER IS NOT ListSectionHeader
// ---------------------------------------
// It is that component in every respect but one: an album header has to carry
// its cover, and ListSectionHeader's only icon slot is a font glyph. Rather
// than edit a component another module owns, the header is reproduced here
// with an image slot, on ListSectionHeader's own numbers (box padding 11 x 8,
// bottom gap 6, the pre-divided shared corner radius, the same chevron
// geometry). An `iconSource` on ListSectionHeader would retire this copy.
//
// A HEADER BOX HAS ONE RADIUS, AND IT IS THE CONTAINER'S
// ------------------------------------------------------
// This list scrolls, so any top-level header can come to rest against either
// of the container's edges -- the list is flush at both ends. A corner that
// meets the container's has to COINCIDE with it, so it takes the container's
// radius; and a corner that took a smaller one until it reached the edge would
// be a box that changes shape as it is scrolled. Which leaves one number for
// the whole box, at both ends and on the nested headers too: two header boxes
// on one screen with two radii is the same discrepancy read across two boxes
// instead of across one.
// =============================================================================
Item {
    id: root

    // Device px per design px here (the nearest ScaleRoot's, else the window's).
    DeviceScale {
        id: dev
    }

    // ---- Data ------------------------------------------------------------
    // [{albumArtist, album, date, coverUrl, songCount, genre?}]
    property var albums: []
    // [{name, albumCount, coverUrl?, genre?}]
    property var artists: []
    // [{name, songCount, albums?: [{albumArtist, album, coverUrl, songCount}]}]
    property var genres: []
    // [{kind: "album", key?, albumArtist, album, coverUrl, songs: [song],
    //   playedAt, partial, songCount?}] or [{kind: "song", key?, song, ...song,
    //   playedAt}], newest first. A song entry's song is read off `song` where
    //   the source nests it and off the entry itself where the source spreads
    //   it, so a bare song object with no `kind` is still read as a song.
    //
    // A run entry that came from a LIST carries `list` (its name),
    // `listCovers` (up to four of its songs' covers, the picture the lists tab
    // gives it) and `listIndex` (parallel to `songs`: each one's place in the
    // list), and its album-shaped fields carry the list's own name so that
    // even a reader ignoring `list` says the right words.
    //
    // `key` is the SOURCE's own identity for the entry, and where there is one
    // it is what this list is keyed by and what `removeRecentRequested` hands
    // back. That matters twice over: a predicted album's `playedAt` moves every
    // time one more of its songs finishes, so a key built from it would make
    // the row a different row on every track -- it would fly out, fly back in
    // and lose its expansion, in the one view whose whole point is filling up
    // as the record plays -- and the service that owns the list is the only
    // thing that can say which entry to forget.
    property var recent: []
    // [{name, songCount, synthetic?}]
    property var playlists: []

    // ---- What is playing -------------------------------------------------
    // The uri of the song the player is on, and whether it is running. The row
    // whose `uri` matches wears the queue's stripe. Both are the HOST's to
    // bind; `playing` defaults to true so a host that binds only the file gets
    // the mark at full accent, which is the state a browsing reader is in
    // almost all of the time.
    property string currentFile: ""
    property bool playing: true

    // "albums" | "artists" | "genres" | "recent" | "playlists"
    property string grouping: "albums"
    property bool loading: false
    // Whether the artists shelf holds only artists with a full album under it
    // (false, the default) or every artist the library knows, including the
    // ones that only appear in Tracks/ or in a playlist. The DATA is the
    // service's; this is what the scope button on the artists tab draws, and
    // the host owns the property — the panel asks through
    // `artistScopeToggled` and never writes it, because a property a host
    // binds is a binding a JS assignment would destroy.
    property bool artistsIncludeLoose: false

    // ---- Look ------------------------------------------------------------
    property real listScale: 1.0
    // Every corner of every box in here, the header boxes' included -- see
    // the note at the head of the file.
    property real containerRadius: 14
    property bool compact: false
    property string fontFamily: "Inter"

    property color listBoxColor: Theme.listBox
    property color headerBoxColor: Theme.headerBox
    property color headerBoxBevelColor: Theme.headerBoxBevel
    property color headerBoxShadowColor: Theme.headerBoxShadow
    property color textColor: Theme.textPrimary
    property color mutedColor: Theme.textMuted
    property color faintColor: Theme.textFaint
    property color accentColor: Theme.accent
    property color accentHoverColor: Theme.accentHover
    property color accentBevelColor: Theme.accentBevel
    property color textOnAccentColor: Theme.textOnAccent
    property color surfaceColor: Theme.surface
    property color panelColor: Theme.panelSunk
    property color bevelColor: Theme.bevel
    property color borderColor: Theme.border
    property color buttonPlateauColor: Theme.buttonPlateau
    property color buttonPlateauHoverColor: Theme.buttonPlateauHover
    property color buttonBevelColor: Theme.buttonBevel
    property color buttonShadowColor: Theme.buttonShadow

    // Playlists are the one grouping with nothing to take a genre from, so they
    // keep a hue of their own.
    property color playlistsColor: Theme.catAur

    // The genres this library actually holds. Every one is a Theme token, so
    // the whole ring follows a theme switch on the theme's own clock.
    property color genreAmbientColor: Theme.catMultilib
    property color genreDreamPopColor: Theme.llmWrite
    property color genreElectronicColor: Theme.catAur
    property color genreRockColor: Theme.catCore
    property color genreShoegazeColor: Theme.llmCode
    property color genreSoundtrackColor: Theme.catExtra
    // No genre tag at all: the neutral says exactly that, and says it without
    // claiming a hue some other genre may want later.
    property color untaggedGenreColor: Theme.textFaint
    // Anything else, hashed by name. Never random: a genre that is not in the
    // table above must still wear the same colour every run.
    //
    // None of these is any of the six above: `llmExplain` and `llmSystem` are
    // catExtra's green and catCore's orange to within a few points, and an
    // unknown genre would sit directly under Soundtrack in two greens nobody
    // can tell apart. A fallback that can be mistaken for a named hue is worse
    // than no hue.
    property var genreFallbackColors: [Theme.llmData, Theme.llmOther,
                                       Theme.warn, Theme.catFlatpak,
                                       Theme.error]

    // ---- Layout numbers --------------------------------------------------
    property real padding: 12           // tab row -> box
    // The grouping selector's height, and with it the side button's: the two
    // are one row and share one height. The host raises this to
    // line the row up with whatever sits beside it.
    property real tabRowHeight: 32
    // The corner the selector's track takes. -1 leaves TabSelector its own
    // stadium; a host that wants it to answer a container beside it passes
    // that container's radius.
    property real tabRadius: -1

    // Whether the rows may start loading their pictures. Every asynchronous Image of
    // the process shares ONE reader thread and the pictures queued last are read
    // first, so a library that builds a dozen cover Images before the vinyl's label
    // has its own decoded puts the label BEHIND them. The host holds this false until the label is in
    // and then leaves it true; a standalone panel never waits.
    property bool coversEnabled: true
    // How long a decoded cover takes to appear (the shell's presence fade).
    property int coverFadeMs: 160
    // The button at the right end of the tab row: Clear on recently played,
    // the artists' scope toggle on artists.
    property real sideButtonWidth: 52
    property real rowInset: 6
    property real listFadeHeight: 34
    property real headerBoxPadding: 10
    property real headerBoxPaddingV: 8
    property real headerBottomGap: 4
    // The header box's own carve, and the hue's glow inside it. The system
    // update exposes the same four on its own headers ("Header box" and "Header
    // inset" on its panel) and this is the audio player's half of that pair --
    // with the difference that a genre
    // has no PROGRESS, so there is one width rather than an idle and an active
    // one: the sliver is constant.
    //
    // The COLOURS are theme tokens (`headerBoxColor` and friends above) and
    // stay theme rows on the Popup tab; the genre hue is the library's own and
    // is edited in the Library tab's hue rows.
    property real headerBevelWidth: 1
    property real headerShadowWidth: 7
    property real headerGlowWidth: 12
    property real headerGlowFeather: 1.5
    property real coverSize: 34
    property real coverRadius: 6
    property real rowGap: 8
    property real stripeWidth: 3
    property real songVPad: 4
    property real songInsetExtra: 0    // one level of nesting
    property real rowVirtualSpacing: 6
    // The air under the LAST row's ink when the list does NOT end on a header,
    // on top of the half spacing its own slot already carries. It is the ROW's,
    // not the box's: a list that ends on a header does not want it (its box is
    // meant to meet the container's edge), and a box padded at the foot would
    // be padded at the head too, where the first header has to meet the
    // container's corners. 6 is the header box's bottom gap, and it is the
    // queue's `rowFootAir` at the queue's own value -- the queue beside this
    // panel leaving different air under its last song would be two answers to
    // one question.
    property real rowFootAir: 6
    property int  rowAnimDuration: 240
    property int  rowStaggerMs: 55
    // The pause between the old grouping's last row landing and the new
    // grouping's first row starting. One stagger step is the doc's "shortly
    // after"; it is a property because it is the one number in the swap that
    // is a matter of taste.
    property int  swapGapMs: 55
    // Expanding at the foot: how much of the opened block has to be in view
    // already for the list NOT to follow it, in song rows, and how long the
    // follow takes. 260 OutCubic is the shell's resize easing — a scroll the
    // panel makes for itself is a resize of what is on screen.
    property real expandFollowMinRows: 2
    property int  expandFollowMs: 260
    // The backstop on a wave's head. A wave ends when its tail goes down,
    // which is a second at most -- but a reader scrolling along with a long
    // entrance keeps letting rows in and pushing that moment out, and past a
    // few seconds a scroll is browsing rather than keeping up. This is where
    // the panel stops waiting and puts the tail down regardless.
    property int  waveMaxMs: 4000
    property real scrollSpeed: 1.0

    // ---- Type ------------------------------------------------------------
    property int titleSize: 13
    property int subtitleSize: 11
    property int figureSize: root.compact ? 10 : 11
    property int chevronSize: 14

    // ---- Signals ---------------------------------------------------------
    // Emitted when the panel's own selector changed the grouping.
    signal groupingChanged_(string g)
    // The artists tab's scope button was pressed. The host answers by putting
    // the new value on `artistsIncludeLoose` (directly or through whatever
    // owns the data); the panel does not write it itself.
    signal artistScopeToggled(bool includeLoose)
    signal playAlbumRequested(string albumArtist, string album)
    signal queueAlbumRequested(string albumArtist, string album)
    // Everything else a header can stand for: kind is "artist" | "genre" |
    // "playlist" and key is its name. An album keeps its own two-name signal.
    signal queueGroupRequested(string kind, string key)
    signal playSongRequested(string uri)
    signal queueSongRequested(string uri)
    // "album" | "artist" | "genre" | "playlist" — the host answers with
    // setSongs(kind, key, songs). An album's key carries both of the names it
    // takes to identify one; `albumKey()` builds it and is the only place the
    // joining character is written. A genre answers with setAlbums(name,
    // albums) instead: a genre is a list of albums here, and only an album is
    // a list of songs.
    signal expandRequested(string kind, string key)
    // Recently played can be emptied and pruned. `kind` is "album" | "song";
    // `key` is the KEY THE ENTRY CARRIED, handed straight back, so the service
    // that built the list is the one that decides what identifies an entry in
    // it. An entry that carried none is keyed by what it is plus when it was
    // played, which is the same string this hands back.
    signal clearRecentRequested()
    signal removeRecentRequested(string kind, string key)
    // Something was put in the queue from this panel. The point is the centre
    // of the row that was queued, in SCENE coordinates, so the host can throw
    // its particles from where the click was; `what` is "album" | "song" |
    // "artist" | "genre" | "playlist".
    signal queuedFeedback(real sceneX, real sceneY, string what)

    // ---- search, sort, the row menu and the pages ----------------------------------------------------
    // A menu pick that is not one of the older signals: action "play" | "next" | "details" (the others
    // are queueAlbumRequested & co.), `kind` "album" | "artist" | "genre" | "playlist" | "song", and the
    // key as that kind names it (an album: its two names, song: its uri in `a`).
    signal actionRequested(string action, string kind, string a, string b)
    // A page was opened: the host answers an album with showAlbumPage(info) (the songs, the length, the
    // formats); an artist's is built from the shelf here.
    signal albumPageRequested(string albumArtist, string album)
    // A song page's own buttons, and back leaving this panel: the host's (PlayerPageStack).
    signal songActionRequested(string action, var song)
    signal returnTaken(var ret)
    // The query changed (settled for `searchDebounceMs`): the host answers with setSearchSongs().
    signal searchRequested(string query)
    // The popup's overlay layer: the row menu and the sort menu float there (anything painted outside
    // an ancestor's bounds gets no input).
    property Item menuOverlay: null
    // The player (MpdService or its mock): a song page reads it, and a song's row asks it for its album.
    property var player: null
    // THE QUERY HAS NO FIELD: as in the notes and the launcher, there is just text that turns into the query
    // when typing starts. The popup's key sink hands typing here; the row under the selector says the shelf's
    // size until there is a query, and then the query.
    readonly property string query: root._query
    property string _query: ""
    readonly property bool searching: root._query !== ""
    property var songHits: []
    // grouping -> { mode, asc }; a grouping with no entry sorts as the host starts it: `startSort` (grouping -> mode, the data's
    // own order where it names none) and `startAscending` (a mode with no direction, the playlists' order, is never turned).
    property var sortBy: ({})
    property var startSort: ({})
    property bool startAscending: true
    property real controlsRowHeight: 28
    // The shelf's line: its size, and how far it stands in from the selector's left edge.
    property int shelfTextSize: 13
    property real shelfTextInset: 2
    property int searchDebounceMs: 160
    function setQuery(q) {
        if (q === root._query)
            return;
        root._query = q;
        searchDebounce.restart();
        // The list is what answers a query: a page over it goes.
        if (q !== "" && root.pageOpen)
            root.closePage(true);
    }
    // A key while one of the panel's menus is open: the menu's (true when it used it).
    function menuKey(e) {
        return rowMenu.handleKey(e) || sortCtl.handleKey(e);
    }
    // Enter: what the first hit opens. A header's page, a song is played; a group with no page of its own opens in place.
    function openFirstHit() {
        for (let i = 0; i < rowModel.count; i++) {
            const r = rowModel.get(i);
            if (r.kind === "separator" || r.rowState === "leaving")
                continue;
            const w = rowRepeater.itemAt(i);
            const b = w && w.bodyLoader ? w.bodyLoader.item : null;
            if (r.kind === "song") {
                root.playSongRequested(r.uri);
            } else if (b) {
                const what = b._queueKind();
                const parts = String(r.dataKey).split(root.keySeparator);
                if (what === "album")
                    pageStack.openPage("album", parts[0] || "", parts[1] || "", { where: "list", key: r.key });
                else if (what === "artist")
                    pageStack.openPage("artist", r.dataKey, "", { where: "list", key: r.key });
                else
                    root._toggleGroup(r.key, what, r.dataKey);
            }
            return true;
        }
        return false;
    }
    // Escape, the list's part: a menu first, then a page's large cover, the page, the query. true = it took the key.
    function handleEscape() {
        if (rowMenu.open) {
            rowMenu.open = false;
            return true;
        }
        if (sortCtl.menuOpen) {
            sortCtl.closeMenu();
            return true;
        }
        const pg = pageStack.shownPage;
        if (pg && pg.closeCover())
            return true;
        if (root.pageOpen) {
            root.closePage();
            return true;
        }
        if (root.searching) {
            root.setQuery("");
            return true;
        }
        return false;
    }
    // The song results the host sent for `query` (the shelf's own rows are filtered here).
    function setSearchSongs(q, songs) {
        if (String(q) !== root.query.trim()) return;
        root.songHits = songs || [];
        root._scheduleRebuild();
    }

    // The unit separator: a character no tag can contain, so a composite key
    // never has to be quoted or escaped.
    readonly property string keySeparator: "\u001F"

    function albumKey(albumArtist, album) {
        return String(albumArtist || "") + root.keySeparator + String(album || "");
    }
    function setSongs(kind, key, songs) {
        const m = {};
        for (const k in root._songs) m[k] = root._songs[k];
        m[root._cacheKey(kind, key)] = songs || [];
        root._songs = m;
        root._sync();
    }
    // The other half of an expand: the albums under one genre. Genres that
    // arrive with their albums already attached never need this.
    function setAlbums(genre, albums) {
        const m = {};
        for (const k in root._genreAlbums) m[k] = root._genreAlbums[k];
        m[String(genre)] = albums || [];
        root._genreAlbums = m;
        root._sync();
    }

    // True while any wave — an entrance, an exit, or a grouping swap — is still
    // running. The list is settled when it is false; a probe waits on this
    // rather than on a number of milliseconds it would have to keep in step
    // with the stagger.
    readonly property bool animating:
        swapEnter.running || root._waveActive || leaveCleanup.running
        || root._tailHeld || followAnim.running || pageStack.morph !== null

    // ---- Derived ---------------------------------------------------------
    readonly property real _s: Math.max(0.2, root.listScale)
    readonly property real _vSpacing: root.rowVirtualSpacing * root._s
    readonly property real _boxPad: root.headerBoxPadding * root._s
    readonly property real _boxPadV: root.headerBoxPaddingV * root._s
    readonly property real _bottomGap: root.headerBottomGap * root._s
    readonly property real _coverSize: root.coverSize * root._s

    // Every height is known before a row exists, which is what lets the
    // skeleton, the corner rule, the fold and the scroll maths agree with the
    // list.
    readonly property real _groupTextH: fmTitle.height + fmSub.height
    readonly property real _groupRowH:
        Math.max(root._coverSize, root._groupTextH) + root._boxPadV * 2 + root._bottomGap
    readonly property real _songRowH: root.songVPad * 2 * root._s + fmTitle.height
    // The seam is a hairline, and its slot is whatever it takes to leave the
    // same air above the line as below it -- see THE SEAM below.
    readonly property real _lineH: Math.max(1, Math.round(root._s))
    readonly property real _groupPitch: root._groupRowH + root._vSpacing
    readonly property real _songPitch: root._songRowH + root._vSpacing

    // The stripe while the music is paused: the accent drained toward the
    // ground it lies on, PlayerQueue's own figures, and relative to that ground
    // rather than an absolute grey so it is a drain in both themes. One
    // computation for the whole list rather than one per row -- the value does
    // not depend on the row.
    readonly property color _drainedStripe: Qt.hsla(
        root.accentColor.hslHue, 0.22,
        root.listBoxColor.hslLightness
            + (0.5 - root.listBoxColor.hslLightness) * 0.4732, 1.0)

    // =====================================================================
    //  THE SEAM
    // =====================================================================
    // A seam sits half way between the INK above it and the ink below it, and
    // the two seams around a run leave that run the same air at its head as at
    // its foot: the line is centred between the two items surrounding it, and
    // the album is centred between the two lines.
    //
    // Ink is not the slot. A header box stands `headerBottomGap` clear of its
    // slot's foot (the air its songs sit under) and nothing clear of its head;
    // a song's line box is `songVPad` inside its slot at both ends. So a seam
    // in a fixed slot cannot have the same air on both sides: above a header it
    // would have 10 px over it and 6 under it -- too low down -- and under a
    // header 12 and 10.
    //
    // The seam's own slot therefore makes up the difference. `_seamAir` is the
    // air it keeps on each side and it is not a taste knob: it is exactly what
    // the seam under a header's foot has -- 6 clear of the box, 6 + 6 of
    // virtual spacing, 4 into the song's line box, 22 px -- split evenly. So
    // the seam under a header's foot, which reads as centred, keeps the space
    // it has, and every other seam is made to match it.
    readonly property real _seamAir:
        (root.headerBottomGap + root.rowVirtualSpacing * 2 + root.songVPad) / 2
    // What a row's ink leaves clear inside its slot, at the head and at the
    // foot, in the panel's own unscaled px: the two facts a seam beside it is
    // placed from. Carried ON the separator (`inkAbove` / `inkBelow`) rather
    // than looked up when it is drawn, because a row does not know its
    // neighbours -- `_seatSeams` reads them off the built list, where a run
    // that is open (its last row a song) and one that is shut (its last row
    // the header itself) are the same question asked once.
    function _inkTop(kind) { return kind === "song" ? root.songVPad : 0; }
    function _inkBot(kind) {
        return kind === "song" ? root.songVPad
             : kind === "separator" ? 0
             : root.headerBottomGap;
    }
    // Where the line sits inside its slot -- negative where the ink above it
    // is further away than the air it is owed, which is the seam under a
    // header's foot -- and how tall that slot has to be for the air below the
    // line to match the air above it.
    function _seamY(row) {
        return (root._seamAir - row.inkAbove - root.rowVirtualSpacing) * root._s;
    }
    function _seamH(row) {
        return root._lineH + root._seamY(row)
             + (root._seamAir - root.rowVirtualSpacing - row.inkBelow) * root._s;
    }
    // Every separator placed from the rows it actually ends up between.
    function _seatSeams(list) {
        for (let i = 0; i < list.length; i++) {
            if (list[i].kind !== "separator") continue;
            list[i].inkAbove = i > 0 ? root._inkBot(list[i - 1].kind) : 0;
            list[i].inkBelow = i + 1 < list.length ? root._inkTop(list[i + 1].kind) : 0;
        }
        return list;
    }

    // A row's height and its pitch, from the ROW: a separator's is its
    // neighbours' business and every other kind's is its kind's.
    function _rowH(row) {
        return row.kind === "song" ? root._songRowH
             : row.kind === "separator" ? root._seamH(row)
             : root._groupRowH;
    }
    function _pitchOf(row) { return root._rowH(row) + root._vSpacing; }

    // A row's inset is its depth: a top-level header runs to the box's own
    // edges, everything under one steps in by one `songInsetExtra` per level.
    function _leftInset(kind, depth) {
        if (kind === "group")
            return 0;
        if (kind === "album")
            return (root.rowInset + root.songInsetExtra * Math.max(1, depth)) * root._s;
        if (kind === "separator")
            return root.rowInset * root._s;
        return (root.rowInset + root.songInsetExtra * depth) * root._s;
    }
    function _rightInset(kind) {
        return kind === "group" ? 0 : root.rowInset * root._s;
    }

    // The grouping's rows, its kind name and its unit — FUNCTIONS of the
    // grouping, deliberately, and not one derived property between them.
    //
    // A derived binding must never be read from inside `onGroupingChanged`,
    // and the rebuild is called from there. A binding's connection to
    // `groupingChanged` is made when the binding first EVALUATES, which is
    // after the handler was connected, so the handler runs first and reads the
    // value the binding still holds: the list would be rebuilt from the
    // grouping it had just left, and the panel would run exactly one switch
    // behind for as long as it was open. A function has no such value to be
    // stale.
    function _sourceOf(g) {
        const raw = g === "albums"  ? (root.albums || [])
                  : g === "artists" ? (root.artists || [])
                  : g === "genres"  ? (root.genres || [])
                  : g === "recent"  ? (root.recent || [])
                                    : (root.playlists || []);
        return root._shape(g, raw);
    }

    // What the row under the selector says while nothing is typed: how much is on this shelf.
    readonly property string _shelfText: {
        const g = root.grouping;
        if (g === "recent")
            return "Recently played";
        const n = (g === "albums" ? root.albums : g === "artists" ? root.artists : g === "genres" ? root.genres : root.playlists || []).length;
        if (n === 0)
            return "";
        const unit = g === "albums" ? "albums" : g === "artists" ? "artists" : g === "genres" ? "genres" : "lists";
        return root._countText(n, unit);
    }
    // ---- the sort and the filter, both of the shelf as it is read --------------------------------------
    // Recent is a time order and has no sort; the query filters it like any shelf, a run by its album and its songs.
    function _defaultSort(g) { return g === "playlists" ? "order" : g === "albums" ? "artist" : "name"; }
    function _sortModesOf(g) {
        if (g === "albums") return [{ id: "artist", label: "Artist", directional: true }, { id: "title", label: "Title", directional: true },
                                    { id: "year", label: "Year", directional: true }, { id: "length", label: "Length", directional: true },
                                    { id: "songs", label: "Songs", directional: true }];
        if (g === "artists") return [{ id: "name", label: "Name", directional: true }, { id: "albums", label: "Albums", directional: true },
                                     { id: "songs", label: "Songs", directional: true }, { id: "length", label: "Length", directional: true }];
        if (g === "genres") return [{ id: "name", label: "Name", directional: true }, { id: "albums", label: "Albums", directional: true },
                                    { id: "songs", label: "Songs", directional: true }, { id: "length", label: "Length", directional: true }];
        if (g === "playlists") return [{ id: "order", label: "Default", directional: false }, { id: "name", label: "Name", directional: true },
                                       { id: "songs", label: "Songs", directional: true }];
        return [];
    }
    function _sortOf(g) {
        const e = root.sortBy[g];
        if (e)
            return e;
        const mode = root.startSort && root.startSort[g] ? String(root.startSort[g]) : root._defaultSort(g);
        return { mode: mode, asc: root.startAscending || mode === "order" };
    }
    function _setSort(mode, asc) {
        const m = {};
        for (const k in root.sortBy) m[k] = root.sortBy[k];
        m[root.grouping] = { mode: mode, asc: asc };
        root.sortBy = m;
        root._beginSwap();
    }
    function _hay(g, o) {
        if (g === "recent") {
            const songs = o.songs || (o.song ? [o.song] : [o]);
            return [o.list, o.album, o.albumArtist, o.title, o.artist].concat(songs.map(x => x.title)).filter(x => !!x).join("\n");
        }
        if (g === "albums") return [o.album, (o.albumArtists || [o.albumArtist]).join(" "), o.genre, o.year > 0 ? String(o.year) : o.date].join("\n");
        if (g === "artists") return [o.name, o.genre].join("\n");
        return String(o.name || "");
    }
    function _num(o, k) { return Number(o[k]) || 0; }
    function _shape(g, src) {
        let out = src;
        const q = String(root.query || "").trim().toLowerCase();
        if (q !== "")
            out = src.filter(o => !!o && root._hay(g, o).toLowerCase().indexOf(q) >= 0);
        if (g === "recent") return out;
        const s = root._sortOf(g);
        if (s.mode === root._defaultSort(g) && s.asc) return out;
        const dir = s.asc ? 1 : -1;
        const nameOf = o => String(g === "albums" ? o.album : o.name || "");
        const byName = (a, b) => nameOf(a).localeCompare(nameOf(b));
        const arr = out.slice();
        arr.sort((a, b) => {
            let c = 0;
            switch (s.mode) {
            case "artist": c = String(a.albumArtist || "").localeCompare(String(b.albumArtist || "")) || (root._num(a, "year") - root._num(b, "year")); break;
            case "title": case "name": c = byName(a, b); break;
            case "year": c = root._num(a, "year") - root._num(b, "year"); break;
            case "length": c = root._num(a, "duration") - root._num(b, "duration"); break;
            case "songs": c = root._num(a, "songCount") - root._num(b, "songCount"); break;
            case "albums": c = root._num(a, "albumCount") - root._num(b, "albumCount"); break;
            case "order": c = 0; break;
            }
            return (c !== 0 ? c : byName(a, b)) * dir;
        });
        return arr;
    }
    function _kindOf(g) {
        return g === "albums"    ? "album"
             : g === "artists"   ? "artist"
             : g === "genres"    ? "genre"
             : g === "playlists" ? "playlist"
                                 : "recent";
    }
    // What a HEADER of this grouping counts. A genre is a list of albums,
    // exactly as an artist's shelf is, so both of them count albums -- and the
    // service sends them `albumCount` for that reason. Only the things that
    // are lists of songs count songs.
    function _countUnitOf(g) {
        return (g === "artists" || g === "genres") ? "albums" : "songs";
    }
    // "1 albums" is a figure that lies about the thing beside it. The slot is
    // measured on the plural, which is the wider of the two, so a list with a
    // one-album artist in it still moves nothing.
    function _countText(n, unit) {
        return n + " " + (n === 1 ? unit.substring(0, unit.length - 1) : unit);
    }

    // =====================================================================
    //  GENRES: COLOUR, GLYPH, AND WHO BELONGS TO WHICH
    // =====================================================================
    // "SoundTrack" and "Soundtrack" are both in this library and are one genre.
    function genreKey(name) { return String(name || "").trim().toLowerCase(); }

    function genreColor(name) {
        const k = root.genreKey(name);
        if (k === "") return root.untaggedGenreColor;
        switch (k) {
        case "ambient": return root.genreAmbientColor;
        case "dream pop": return root.genreDreamPopColor;
        case "electronic": return root.genreElectronicColor;
        case "rock": return root.genreRockColor;
        case "shoegaze": return root.genreShoegazeColor;
        case "soundtrack": return root.genreSoundtrackColor;
        }
        const ring = root.genreFallbackColors || [];
        return ring.length > 0 ? ring[root._hash(k) % ring.length]
                               : root.untaggedGenreColor;
    }

    // FNV-1a. Any stable hash would do; what matters is that it is stable.
    function _hash(s) {
        let h = 2166136261;
        for (let i = 0; i < s.length; i++) {
            h ^= s.charCodeAt(i);
            h = (h * 16777619) >>> 0;
        }
        return h >>> 0;
    }

    // A genre has no cover to show, so it gets a mark instead. All of these are
    // Font Awesome glyphs in the BMP and every one was checked against Symbols
    // Nerd Font's own cmap; the tag is the fallback, which is what a genre
    // nobody has a picture of looks like.
    function genreGlyph(name) {
        switch (root.genreKey(name)) {
        case "ambient": return "\uF0C2";
        case "dream pop": return "\uF186";
        case "electronic": return "\uF0E7";
        case "rock": return "\uF130";
        case "shoegaze": return "\uF025";
        case "soundtrack": return "\uF008";
        }
        return "\uF02B";
    }

    // The albums under one genre entry: attached to the entry by the service,
    // or answered later through setAlbums().
    property var _genreAlbums: ({})

    // rowKey -> { kind, dataKey } for every group that is currently open.
    property var _openReq: ({})

    // A RESCAN INVALIDATES WHAT WAS FETCHED UNDER THE PREVIOUS SCAN.
    //
    // `_songs` and `_genreAlbums` hold answers the host gave for one group, so
    // that a second click does not send it back to MPD -- and `_toggleGroup`
    // only asks when the key is `undefined`, so a cached answer is never
    // re-fetched. That is right until the library is rescanned underneath them.
    //
    // Without it, giving an album a genre tag and rescanning leaves the genre's
    // header saying 2 albums -- that number comes from `genres`, which the scan
    // republishes -- while expanding it still shows 1, because that list comes
    // from this cache, which the scan does not touch. The colour changes for
    // the same reason the count does, which makes it look like a half-applied
    // rescan.
    //
    // Clearing alone is not enough: a group that is OPEN when the scan lands
    // would fall back to an empty list and sit there until it was collapsed and
    // clicked again. So every open group is asked for a second time -- and KEEPS
    // what it shows until the answer replaces it. Dropping its songs first would
    // leave every open group without any until the host answered, and a sync in
    // that gap takes its rows away: the ones in view leave, the ones out of view
    // are destroyed, and the answer builds them again, covers and all (with two
    // albums open, the one out of view comes back as 60 NEW rows). Only the
    // groups that are SHUT lose their answers, which is all the stale count
    // needs.
    function _invalidateFetched() {
        const songs = {};
        const albums = {};
        const ask = [];
        for (const k in root._openReq) {
            const r = root._openReq[k];
            // A recently-played album carries its own songs and asks for
            // nothing, exactly as on the way in.
            if (!r || !r.kind || r.kind === "recentAlbum")
                continue;
            if (r.kind === "genre") {
                const have = root._genreAlbums[String(r.dataKey)];
                if (have !== undefined) albums[String(r.dataKey)] = have;
            } else {
                const key = root._cacheKey(r.kind, r.dataKey);
                if (root._songs[key] !== undefined) songs[key] = root._songs[key];
            }
            ask.push(r);
        }
        root._songs = songs;
        root._genreAlbums = albums;
        for (let i = 0; i < ask.length; i++)
            root.expandRequested(ask[i].kind, ask[i].dataKey);
    }

    property bool _invalidateQueued: false
    function _scheduleInvalidate() {
        if (root._invalidateQueued) return;
        root._invalidateQueued = true;
        // One invalidation per scan, not one per list: a scan republishes
        // `albums`, `artists` and `genres` together.
        Qt.callLater(function () {
            root._invalidateQueued = false;
            root._invalidateFetched();
        });
    }
    function _albumsOf(g) {
        if (!g) return [];
        const fetched = root._genreAlbums[String(g.name || "")];
        if (fetched) return fetched;
        return (g.albums && g.albums.length !== undefined) ? g.albums : [];
    }

    // albumKey -> the genre an album carries on itself, when it carries one.
    // It beats the genre index everywhere, the artist tally included: if an
    // album says it is Rock, then its songs are Rock, and the album's header
    // and its artist's must not disagree about that.
    readonly property var _albumTag: {
        const m = {};
        const al = root.albums || [];
        for (let i = 0; i < al.length; i++) {
            const g = al[i].genre === undefined ? "" : String(al[i].genre);
            if (g !== "") m[root.albumKey(al[i].albumArtist, al[i].album)] = g;
        }
        return m;
    }

    // albumKey -> the genre with the most of that album's songs in it. Built
    // from the genre list, which is the only place the mapping exists: an album
    // row does not have to carry a genre tag, and if it does (`o.genre`) that
    // wins.
    readonly property var _genreOfAlbum: {
        const best = {};
        const n = {};
        const gs = root.genres || [];
        for (let i = 0; i < gs.length; i++) {
            const name = String(gs[i].name || "");
            const al = root._albumsOf(gs[i]);
            for (let j = 0; j < al.length; j++) {
                const k = root.albumKey(al[j].albumArtist, al[j].album);
                const c = Number(al[j].songCount) || 1;
                if (n[k] === undefined || c > n[k]) { n[k] = c; best[k] = name; }
            }
        }
        return best;
    }

    // artist name -> the genre they have the most songs of, tallied over every
    // album of theirs that any genre claims.
    readonly property var _genreOfArtist: {
        const tally = {};
        const gs = root.genres || [];
        for (let i = 0; i < gs.length; i++) {
            const name = String(gs[i].name || "");
            const al = root._albumsOf(gs[i]);
            for (let j = 0; j < al.length; j++) {
                const a = String(al[j].albumArtist || "");
                if (a === "") continue;
                const tag = root._albumTag[root.albumKey(a, al[j].album)];
                const g = tag === undefined ? name : tag;
                if (tally[a] === undefined) tally[a] = {};
                tally[a][g] = (tally[a][g] || 0) + (Number(al[j].songCount) || 1);
            }
        }
        const best = {};
        for (const a in tally) {
            let top = "";
            let n = -1;
            for (const g in tally[a])
                if (tally[a][g] > n) { n = tally[a][g]; top = g; }
            best[a] = top;
        }
        return best;
    }

    function _albumGenre(o) {
        if (o && o.genre !== undefined && String(o.genre) !== "") return String(o.genre);
        const g = root._genreOfAlbum[root.albumKey(o ? o.albumArtist : "",
                                                   o ? o.album : "")];
        return g === undefined ? "" : g;
    }
    function _artistGenre(o) {
        if (o && o.genre !== undefined && String(o.genre) !== "") return String(o.genre);
        const g = root._genreOfArtist[String(o ? o.name : "")];
        return g === undefined ? "" : g;
    }

    // =====================================================================
    //  FIXED SLOTS
    //
    //  Measured from the widest figure THIS grouping can show, through
    //  FontMetrics on a template of eights — never by reading a Text's own
    //  width back into what sizes it.
    // =====================================================================
    function _eights(n) { return String(Math.max(1, Math.round(n))).replace(/[0-9]/g, "8"); }

    readonly property real _countSlot: {
        const g = root.grouping;
        let m = 0;
        if (g === "recent") {
            const src = root.recent || [];
            for (let i = 0; i < src.length; i++) {
                if (!src[i] || src[i].kind !== "album") continue;
                m = Math.max(m, (src[i].songs || []).length);
                // BOTH figures, because the second is the one that runs away:
                // a run counts against what it came from, and four songs of a
                // thirty-five-song list say "4 of 35". Measured on the played
                // count alone the slot would be two digits short of the text it
                // has to hold.
                m = Math.max(m, Number(src[i].songCount) || 0);
            }
            // A run still filling up shows "8 of 12 songs", so the slot is
            // measured on the longest form it can take, not on today's.
            return m > 0 ? fmFig.advanceWidth(root._eights(m) + " of "
                                              + root._eights(m) + " songs") : 0;
        }
        // The widest figure any row of this grouping can show, in the word it
        // will show it in -- both words where both can appear, because a genre
        // header counts albums while the albums nested under it count songs.
        const l = root._sourceOf(g);
        let mA = 0;
        let mS = 0;
        for (let i = 0; i < l.length; i++) {
            mA = Math.max(mA, Number(l[i].albumCount) || 0);
            mS = Math.max(mS, Number(l[i].songCount) || 0);
        }
        if (g === "genres") {
            for (let i = 0; i < l.length; i++) {
                const al = root._albumsOf(l[i]);
                for (let j = 0; j < al.length; j++)
                    mS = Math.max(mS, Number(al[j].songCount) || 0);
            }
        }
        let wide = 0;
        if (mA > 0) wide = Math.max(wide, fmFig.advanceWidth(root._eights(mA) + " albums"));
        if (mS > 0) wide = Math.max(wide, fmFig.advanceWidth(root._eights(mS) + " songs"));
        return wide;
    }
    readonly property real _durSlot: fmFig.advanceWidth("88:88")
    // The number slot. Two digits wherever the number is an album's track
    // number; a list numbers its songs by the list, so a list of a hundred
    // needs a third digit -- in the lists tab and under a list's run in
    // recently played alike. Measured on the LONGEST list this shelf holds,
    // not on the one that happens to be open, so no row's number moves when
    // another list is opened.
    readonly property real _trackSlot: {
        let m = 0;
        if (root.grouping === "playlists") {
            const l = root.playlists || [];
            for (let i = 0; i < l.length; i++)
                m = Math.max(m, Number(l[i].songCount) || 0);
        } else if (root.grouping === "recent") {
            // A run from a list is numbered by the list, so the slot is
            // measured on the longest list ANY run on this shelf came from --
            // not on the one that happens to be open.
            const src = root.recent || [];
            for (let i = 0; i < src.length; i++) {
                const idx = src[i] && src[i].list ? (src[i].listIndex || []) : [];
                for (let j = 0; j < idx.length; j++)
                    m = Math.max(m, Number(idx[j]) || 0);
            }
        } else {
            return fmFig.advanceWidth("88");
        }
        return fmFig.advanceWidth(m >= 100 ? "888" : "88");
    }
    // The remove mark's slot, on the queue's own numbers. Reserved at all times
    // on a row that has one, so nothing shifts when it fades in.
    readonly property real _removeSlot: fmFig.height * 1.2

    FontMetrics {
        id: fmTitle
        font.family: root.fontFamily
        font.pixelSize: root.titleSize * root._s
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

    // =====================================================================
    //  COVERS THAT ARE NOT THERE
    //
    //  The service stops handing out a cover for a directory that has none,
    //  which is where that warning belongs. This is the panel's half: it never
    //  asks for an empty path, it keeps the fallback glyph for every slot that
    //  has no picture IN it (which is not the same as an Image that is not
    //  Ready -- see the slot), and a url that failed once is remembered so the
    //  album's other rows -- the same album under its genre, in recently
    //  played, in the albums tab -- ask for the glyph straight away instead of
    //  failing again each.
    //
    //  NOTHING CLEARS IT, AND NOTHING NEEDS IT CLEARED. An album with no cover at all is the SERVICE's answer, not
    //  this memo's: once the cover scan has run, `coverUrlForDir` returns ""
    //  for a directory that holds no cover file, so the row arrives here with
    //  an empty url and the memo is never even asked -- emptying it would put
    //  no picture back. The one url it can hold shut is the one the service
    //  GUESSES before the scan has answered (`<dir>/cover.jpg`): if that file
    //  is then created while the shell runs, the rescan hands back the very
    //  string the memo has written off. That is the price of the memo, it is
    //  paid until the shell is next started, and the alternative -- forgetting
    //  on every rescan -- is the whole library failing again, once per row per
    //  view, which is the warning the memo exists to prevent.
    // =====================================================================
    property var _missingCovers: ({})
    function _coverSource(url) {
        const u = String(url || "");
        return (u === "" || root._missingCovers[u] === true) ? "" : u;
    }
    function _noteMissingCover(url) {
        const u = String(url || "");
        if (u === "" || root._missingCovers[u] === true) return;
        const m = {};
        for (const k in root._missingCovers) m[k] = root._missingCovers[k];
        m[u] = true;
        root._missingCovers = m;
    }

    // =====================================================================
    //  MODEL
    //
    //  One flat model of rows, each carrying its own depth. A grouping switch
    //  replaces it through the swap; anything else (a group opening, songs
    //  arriving, the host's arrays changing) is a diff, so the rows that stay
    //  keep their delegates and the list keeps its place.
    // =====================================================================
    ListModel { id: rowModel }

    property var _expanded: ({})        // row key -> true
    property var _songs: ({})           // kind + separator + data key -> [song]

    function _isExpanded(key) { return !!root._expanded[key]; }
    function _cacheKey(kind, key) { return kind + root.keySeparator + key; }

    // ListModel fixes its roles from the first row appended, so every entry is
    // built from the same blank and carries every field, always.
    function _blank() {
        return {
            // The grouping the row was BUILT in, and the one every reading of
            // it goes through afterwards. A row on its way out of a switch is
            // a picture of the list it belonged to, so it must not read the
            // grouping the panel has already moved on to.
            kind: "song", grouping: root.grouping, isList: false,
            depth: 0, key: "", dataKey: "",
            primary: "", secondary: "", countText: "", cover: "", covers: "",
            genre: "",
            uri: "", track: 0, numbered: true, dur: 0,
            removable: false, removeKey: "",
            // A separator's own geometry, filled in by `_seatSeams` once the
            // list is built and the rows either side of it are known.
            inkAbove: 0, inkBelow: 0,
            rowState: "rest", staggerIdx: 0
        };
    }

    function _groupEntry(o) {
        const g = root.grouping;
        const isAlbum = g === "albums";
        const e = root._blank();
        e.kind = "group";
        e.depth = 0;
        e.primary = isAlbum ? String(o.album || "") : String(o.name || "");
        e.key = isAlbum ? root.albumKey(o.albumArtist, o.album) : e.primary;
        e.dataKey = e.key;
        e.secondary = isAlbum ? String(o.albumArtist || "") : "";
        // The word follows the FIELD, so the number and the noun can never
        // disagree. The grouping's own unit is preferred, and the other field
        // is read WITH ITS OWN WORD rather than silently relabelled: a genre
        // that only knows its song count says "30 songs", never "30 albums".
        const nA = Number(o.albumCount) || 0;
        const nS = Number(o.songCount) || 0;
        const useAlbums = root._countUnitOf(g) === "albums" ? nA > 0
                                                            : (nS === 0 && nA > 0);
        const n = useAlbums ? nA : nS;
        e.countText = n > 0 ? root._countText(n, useAlbums ? "albums" : "songs") : "";
        e.cover = String(o.coverUrl || "");
        e.covers = root._coverList(o.coverUrls);
        e.genre = isAlbum ? root._albumGenre(o)
                : g === "artists" ? root._artistGenre(o)
                : g === "genres" ? e.primary
                                 : "";
        return e;
    }

    // A list's pictures: up to four of its songs' covers, joined into the one
    // string a ListModel role can hold (an array becomes a nested ListModel,
    // which neither the diff nor the row could read back). Which of them are
    // usable is the ROW's question, once. One function, because a list wears
    // its pictures in its own tab and in recently played both.
    function _coverList(urls) {
        const parts = [];
        if (urls && urls.length !== undefined)
            for (let i = 0; i < urls.length && parts.length < 4; i++) {
                const u = String(urls[i] || "");
                if (u !== "") parts.push(u);
            }
        return parts.join(root.keySeparator);
    }

    // An album hanging under a genre. Its ROW key carries the genre so the same
    // album can be open under one genre and shut under another; its DATA key is
    // the album's own, so its songs land in the one cache every view reads.
    function _albumEntry(o, owner, depth) {
        const e = root._blank();
        e.kind = "album";
        e.depth = depth;
        e.dataKey = root.albumKey(o.albumArtist, o.album);
        e.key = owner + root.keySeparator + e.dataKey;
        e.primary = String(o.album || "");
        e.secondary = String(o.albumArtist || "");
        const n = Number(o.songCount) || 0;
        e.countText = n > 0 ? root._countText(n, "songs") : "";
        e.cover = String(o.coverUrl || "");
        e.genre = root._albumGenre(o);
        return e;
    }

    // `number` is what the row wears in the slot at the head of the row: 0 for
    // the tag's own track number, which is what a song under an ALBUM always
    // shows, and a positive number for a song under a LIST, where the list
    // does the numbering (see the header, `_listRows`, and the `listIndex` a
    // list's run in recently played arrives with). Whether the slot is there
    // at all is `numbered`, which only a standalone song turns off.
    function _songEntry(s, owner, depth, number) {
        const e = root._blank();
        e.kind = "song";
        e.depth = depth;
        e.uri = String(s.file || "");
        e.key = owner + root.keySeparator + e.uri;
        e.dataKey = e.uri;
        e.primary = String(s.title || s.file || "");
        e.secondary = String(s.artist || "");
        e.track = number > 0 ? number : (Number(s.track) || 0);
        e.dur = Number(s.duration) || 0;
        return e;
    }

    // The `NN.` at the head of a file's own name: "01. Artist - Title.m4a".
    // Robust about the separator (a dot, a bracket, a dash, an underscore or
    // plain whitespace) and about leading space, and deliberately NOT robust
    // about a year: "1999 - Song.flac" is not a numbered file, so the digits
    // have to be followed by something that separates them from the name or
    // they are not a number at all. `fallback` is the row's own position,
    // which is the honest answer for a list nobody numbered.
    function _fileNumber(file, fallback) {
        const u = String(file || "");
        const cut = u.lastIndexOf("/");
        const base = cut >= 0 ? u.substring(cut + 1) : u;
        const m = /^\s*(\d{1,3})\s*(?:[.)\-_]\s*|\s+)/.exec(base);
        if (m === null) return fallback;
        const n = parseInt(m[1], 10);
        return n > 0 ? n : fallback;
    }

    // The songs of one list, in the order they are shown and each with the
    // number it wears. `favourites` is the synthetic list the service builds
    // out of ~/Music/Tracks: it is ordered by the file's own mtime, newest
    // first, because those files were downloaded in the order they were
    // favourited and the app they came from shows the newest at the top.
    // Every other list is numbered by its file names, and by position where
    // the names carry no number.
    function _listRows(songs, favourites) {
        const l = songs || [];
        const rows = [];
        for (let i = 0; i < l.length; i++) rows.push({ s: l[i], at: i, n: i + 1 });
        if (favourites) {
            // Stable by construction: the source's own order breaks every
            // tie, including the one a list with no timestamps on it at all is
            // made entirely of -- and then the numbers are the positions,
            // which is the fallback either way.
            rows.sort((a, b) => {
                const ta = Number(a.s.lastModified) || 0;
                const tb = Number(b.s.lastModified) || 0;
                return ta === tb ? a.at - b.at : tb - ta;
            });
            for (let j = 0; j < rows.length; j++) rows[j].n = j + 1;
            return rows;
        }
        for (let k = 0; k < rows.length; k++)
            rows[k].n = root._fileNumber(rows[k].s.file, k + 1);
        return rows;
    }

    function _separatorEntry(after) {
        const e = root._blank();
        e.kind = "separator";
        e.key = "sep" + root.keySeparator + after;
        return e;
    }

    function _songsFor(kind, dataKey) {
        return root._songs[root._cacheKey(kind, dataKey)] || [];
    }

    // The list the model should hold, as plain objects. Built whole and then
    // diffed: the target is easy to reason about, and the diff is what keeps
    // the delegates.
    function _target() {
        const g = root.grouping;
        // Seated at the ONE place every list is finished, so a seam is placed
        // from the rows it ends up between whichever builder produced them.
        if (g === "recent") return root._seatSeams(root._withHits(root._recentTarget()));
        const out = [];
        const src = root._sourceOf(g);
        for (let i = 0; i < src.length; i++) {
            const entry = root._groupEntry(src[i]);
            out.push(entry);
            if (!root._isExpanded(entry.key)) continue;
            if (g === "genres") {
                const al = root._albumsOf(src[i]);
                for (let j = 0; j < al.length; j++) {
                    const ae = root._albumEntry(al[j], entry.key, 1);
                    out.push(ae);
                    if (!root._isExpanded(ae.key)) continue;
                    const inner = root._songsFor("album", ae.dataKey);
                    for (let k = 0; k < inner.length; k++)
                        out.push(root._songEntry(inner[k], ae.key, 2, 0));
                }
                continue;
            }
            const songs = root._songsFor(root._kindOf(g), entry.dataKey);
            // A list numbers its own songs; everything else shows the tag's
            // track number. `synthetic` is the service's mark for Favorites,
            // the one list that is a directory of loose files rather than a
            // playlist.
            if (g === "playlists") {
                const rows = root._listRows(songs, src[i].synthetic === true);
                for (let j = 0; j < rows.length; j++)
                    out.push(root._songEntry(rows[j].s, entry.key, 1, rows[j].n));
                continue;
            }
            for (let j = 0; j < songs.length; j++)
                out.push(root._songEntry(songs[j], entry.key, 1, 0));
        }
        return root._seatSeams(root._withHits(out));
    }

    // The songs the daemon found for the query, after the shelf's own matches: loose song rows, as the
    // standalone songs of recently played are (no number slot, a whole level out), behind the seam.
    function _withHits(out) {
        if (String(root.query || "").trim() === "") return out;
        const hits = root.songHits || [];
        if (hits.length === 0) return out;
        const res = out.slice();
        if (res.length > 0) res.push(root._separatorEntry("hits"));
        for (let i = 0; i < hits.length; i++) {
            const e = root._songEntry(hits[i], "hit", 0, 0);
            e.numbered = false;
            e.secondary = String(hits[i].artist || "");
            res.push(e);
        }
        return res;
    }

    // Recently played. The service says what is an album; a bare song object
    // with no `kind` is read as a song.
    //
    // THE SEAM GOES BETWEEN A RUN AND A LOOSE SONG, either way round: shut,
    // a header and a standalone song are two things that have nothing to do
    // with each other, and the line is what says so -- which is as true above
    // the header as below it. Open, it is the same line in the same place,
    // with the run's block reaching down to meet it. Never between two runs:
    // two headers are already two blocks, and a line between them would be
    // drawing a seam where there is none.
    function _recentTarget() {
        const out = [];
        const src = root._shape("recent", root.recent || []);
        let prev = "";      // "album" | "standalone" | ""
        for (let i = 0; i < src.length; i++) {
            const o = src[i];
            if (!o) continue;
            if (o.kind === "album") {
                // A RUN FROM A LIST IS DRAWN AS ONE. `kind` stays the
                // source's "album" because that is the SHAPE -- a header with
                // its songs under it -- and `list` is where the run came
                // from. Where there is one the header is the LIST's: its own
                // name, its 2 x 2 of covers, the lists tab's hue and its one
                // line, a list having no artist to write under it.
                const listName = String(o.list || "");
                const isList = listName !== "";
                const e = root._blank();
                e.kind = "group";
                e.depth = 0;
                e.isList = isList;
                // What the row stands for: a list is named by itself, an
                // album by the two names it takes to name one.
                e.dataKey = isList ? listName
                                   : root.albumKey(o.albumArtist, o.album);
                // The source's own key where there is one; otherwise two plays
                // of one album would be one row, so the time stands in for the
                // identity the entry did not carry.
                const aKey = (o.key === undefined || String(o.key) === "")
                    ? e.dataKey + root.keySeparator + String(o.playedAt || i)
                    : String(o.key);
                if (prev === "standalone")
                    out.push(root._separatorEntry(aKey));
                e.key = "recent" + root.keySeparator + aKey;
                e.removeKey = aKey;
                e.primary = isList ? listName : String(o.album || "");
                e.secondary = isList ? "" : String(o.albumArtist || "");
                e.cover = isList ? "" : String(o.coverUrl || "");
                e.covers = isList ? root._coverList(o.listCovers) : "";
                // A list has no genre to take a hue from and wears the lists
                // tab's own, which is the row's answer and not this field's.
                e.genre = isList ? "" : root._albumGenre(o);
                e.removable = true;
                const songs = o.songs || [];
                // How many songs the ALBUM has, which is what `songCount`
                // means on every other entry in this file too.
                const total = Number(o.songCount) || 0;
                // An album still filling up says so in its own count rather
                // than in a second mark beside it.
                e.countText = (o.partial && total > songs.length)
                    ? songs.length + " of " + total + " songs"
                    : root._countText(songs.length, "songs");
                out.push(e);
                prev = "album";
                if (!root._isExpanded(e.key)) continue;
                // A list numbers its songs by the LIST: `listIndex` runs
                // parallel to `songs`, so the number is the song's place in
                // the list however the list was played -- which is what
                // survives it being played shuffled. An album's song wears
                // its track tag, which is what 0 asks for.
                const idx = isList ? (o.listIndex || []) : [];
                for (let j = 0; j < songs.length; j++) {
                    const se = root._songEntry(songs[j], e.key, 1,
                                               Number(idx[j]) || 0);
                    se.isList = isList;
                    out.push(se);
                }
                continue;
            }
            // A standalone song, and the seam above it wherever a run is what
            // it follows. The song is on `song` where the source nests it and
            // on the entry itself where the source spreads it, so both shapes
            // are read through the one line.
            const so = o.song || o;
            if (prev === "album")
                out.push(root._separatorEntry(String(so.file || i)));
            const s = root._songEntry(so, "recent", 0, 0);
            // NO NUMBER, AND NO SLOT FOR ONE. A loose song is numbered by
            // nothing -- it is not the nth of anything -- and it is a
            // top-level row, a whole level of inset out from the songs of the
            // runs around it, so the slot it gave up was width no other row
            // ever lined up against.
            s.numbered = false;
            const sKey = (o.key === undefined || String(o.key) === "")
                ? s.uri + root.keySeparator + String(o.playedAt || i)
                : String(o.key);
            s.key = "recent" + root.keySeparator + sKey;
            s.removeKey = sKey;
            s.removable = true;
            out.push(s);
            prev = "standalone";
        }
        return out;
    }

    // =====================================================================
    //  THE FOLD
    //
    //  A row is on screen when its resting slot intersects the viewport, with
    //  a row's height of margin either side: a row one pixel below the fold
    //  reads as a popped-in row if it is placed, and a row promoted into the
    //  wave has to be promoted before it can be seen, because promotion snaps
    //  it off to the left.
    // =====================================================================
    // A list filled before its viewport has been laid out cannot tell the fold
    // from anything: every row answers "on screen", so every row is staggered
    // and a forty-row entrance takes two seconds to arrive at a place nobody
    // is looking. The first sync therefore waits for a height. It waits a
    // bounded number of frames and then goes anyway, because a panel that is
    // genuinely zero-high (a closed popup) must not spin a timer forever --
    // and by then `_onScreen` answers "nothing is on screen", so the fill that
    // follows places every row rather than staggering it.
    //
    // AND A HEIGHT READ BEFORE THE FIRST FRAME IS NOT THE LAYOUT'S ANSWER. The panel is built before
    // the popup's column has laid it out: a first sync would read a viewport of 56 px (panel 100; 640
    // after the first frame), name TWO rows as the head, fold the other fifty-one away, and when the
    // layout landed the tail would be placed at once -- two rows sliding in, a pause, and a wall of
    // rows with no motion. Two timer ticks do not wait for it (the first frame's polish takes 360 ms
    // and both ticks fall before it), so the viewport is ready after the window has presented a frame
    // with this panel in it: the head is then the rows the reader will actually see.
    //
    // THE FOLD IS WHERE THE LIST WILL END, NOT WHERE THE BOX IS NOW. The engine builds the content in
    // a box of nothing and eases it open, OutBack, over ~300 ms, so the first frame after the build
    // reads 16 px of viewport. That would name two rows as the head and fold the other fifty-seven;
    // the head would land at 337 ms, and everything the box had opened on by then would be placed in
    // ONE frame (two albums, then all the others at once). Waiting for the box would be an empty
    // sidebar for the whole open: the host says what the panel will be (`restingHeight`), the fold is
    // read from that, and the opening box reveals a wave that is already running.
    property real restingHeight: -1
    readonly property real _viewH: root.restingHeight >= 0 ? root.restingHeight - box.y : flick.height
    property int _layoutTries: 0
    property int layoutMaxTries: 30
    property bool _framed: false
    Connections {
        target: root.Window.window
        function onFrameSwapped() {
            if (root._framed)
                return;
            root._framed = true;
            root._sync();
        }
    }
    function _viewportReady() {
        return (root._viewH > 0 && root._framed) || root._layoutTries >= root.layoutMaxTries;
    }
    Timer {
        id: layoutWait
        interval: 16
        repeat: false
        onTriggered: {
            root._layoutTries++;
            root._sync();
        }
    }

    function _onScreen(top, row, cy) {
        const vh = root._viewH;
        // No viewport, so nothing is on screen -- and therefore nothing
        // animates. This is the popup's own first fill: the library is built
        // inside a sidebar that is closed, so the panel is genuinely zero-high
        // and stays that way until the burger is pressed. Answering "yes" here
        // (which is what a viewport-less list is usually written to do) hands
        // every row a stagger rank into a box nobody can see, holds the wave
        // open for as long as the list is long, and then trickles the tail in
        // under the user when the sidebar finally opens.
        if (vh <= 0) return false;
        const m = root._groupPitch;
        return (top + root._rowH(row)) > (cy - m) && top < (cy + vh + m);
    }

    // ---- What is worth DRAWING ------------------------------------------
    // The same question `_onScreen` asks, put to the LIVE layout rather than
    // the resting one and for a different reason: `_onScreen` decides what
    // animates, this decides what is painted at all. Both are the viewport
    // plus an overscan; this one's is two rows, because a row that appears in
    // the frame it is needed appears late.
    // Two of the TALLEST kind of row, which is a header: a pad measured in
    // song pitches is under one header row, and a flick could then reach a
    // row the frame before it is drawn. `_onScreen` overscans by the same
    // pitch for the same reason.
    readonly property real _cullPad: root._groupPitch * 2
    // Before the box has been laid out there is no viewport to be outside of,
    // and culling against a height of zero would hide the whole list.
    readonly property bool _culling: root._viewH > 0
    readonly property real _cullTop: flick.contentY - content.y - root._cullPad
    readonly property real _cullBottom:
        flick.contentY - content.y + root._viewH + root._cullPad

    // ---- Which rows may ask for their pictures ---------------------------------------------------------
    // From the RESTING layout (`_offsets`), not from a row's live place: a row that was just built has
    // none yet (a Column leaves it at y 0, and the folded tail has no height at all), and a live
    // reading would call the whole list near for the frame the cover Images are made in. The first
    // ring is the viewport and the cull pad about it; a moment later (`coverWideMs`, once the first
    // ring has had the reader thread to itself) it widens to a viewport either side, so a scroll
    // finds the next screen's pictures already there.
    property bool _coverWide: false
    property int coverWideMs: 400
    Timer {
        interval: root.coverWideMs
        running: root.coversEnabled && !root._coverWide
        onTriggered: root._coverWide = true
    }
    function _coverNearRow(i, row) {
        if (!root._culling) return true;
        const o = root._offsets;
        if (i >= o.length) return false;
        const pad = root._coverWide ? root._viewH : root._cullPad;
        const top = o[i] + content.y;
        return top + root._rowH(row) > flick.contentY - pad
            && top < flick.contentY + root._viewH + pad;
    }

    // ---- Which rows have their content built ---------------------------------------------------------------
    // A row near the reader (half a viewport and the cull pad either side, by the resting layout) is
    // built the moment it exists, a row of the wave the moment it is kicked (it is flat and off to the
    // left until then, and a dozen built together are a frame of the popup's own opening); the rest
    // are built in list order once the entrance is over, a chunk a tick. The cursor restarts whenever
    // the list is filled from nothing.
    property int buildChunk: 6
    property int _buildCursor: 0
    function _rowNeeded(i, row) {
        if (i < root._buildCursor) return true;
        if (!root._culling || row.rowState !== "rest") return false;
        const o = root._offsets;
        if (i >= o.length) return false;
        const pad = root._viewH / 2 + root._cullPad;
        const top = o[i] + content.y;
        return top + root._rowH(row) > flick.contentY - pad
            && top < flick.contentY + root._viewH + pad;
    }
    Timer {
        interval: 16
        repeat: true
        running: root._buildCursor < rowModel.count && !root._waveActive && root._framed
        onTriggered: root._buildCursor += root.buildChunk
    }

    function _offsetsOf(list) {
        const a = [];
        let y = 0;
        for (let i = 0; i < list.length; i++) {
            a.push(y);
            y += root._pitchOf(list[i]);
        }
        return a;
    }

    // ---- Which row the top edge crosses, and what the foot has to trim ----
    property var _offsets: []
    // The kind of the LAST row, which is the whole of what the foot is read
    // from: a header's own bottom gap is trimmed away so its box meets the
    // container's edge, and a row that ends in bare text is given `rowFootAir`
    // instead. Empty while there is no list, where the foot is neither.
    property string _tailKind: ""
    readonly property bool _tailIsHeader:
        root._tailKind === "group" || root._tailKind === "album"
    readonly property real _tailGap: root._tailIsHeader ? root._bottomGap : 0
    readonly property real _footAir:
        (root._tailKind !== "" && !root._tailIsHeader) ? root.rowFootAir * root._s : 0

    function _rebuildOffsets() {
        const a = [];
        let y = 0;
        for (let i = 0; i < rowModel.count; i++) {
            a.push(y);
            y += root._pitchOf(rowModel.get(i));
        }
        root._offsets = a;
        const n = rowModel.count;
        root._tailKind = n > 0 ? rowModel.get(n - 1).kind : "";
    }

    // =====================================================================
    //  THE WAVES
    // =====================================================================
    // THE WAVE'S CLOCK. The rows' stagger, the head's end, the wave's end and the leavers' sweep wait on
    // what was DRAWN (StaggerClock: a frame is never more than 25 ms of it), not on the wall: a frame that
    // stalls (the wave runs through the popup's own opening) holds the whole wave and it goes on, staggered,
    // from where it stopped, instead of every row that came due in the stall arriving in one turn.
    StaggerClock { id: staggerClock }
    readonly property var _clock: staggerClock

    property real _waveStart: 0
    property var _wavePlaced: ({})      // key -> its rank in the wave
    property bool _waveActive: false

    // True when waveMaxMs is shorter than the wave's own clock, so a row the
    // reassessment let in late may still be in the air when the cap fires --
    // and then the cap must not write the model's rowStates, which would snap
    // it into place.
    property bool _waveCapped: false

    // True while the wave's tail is folded away (`collapsed`) waiting for the
    // head to land.
    property bool _tailHeld: false
    // The last rank that is actually staggered — the row the tail is waiting
    // for. A reassessment can hand the wave a LATER row than the fill did
    // (`_unfoldToFill`), and then the tail is waiting for that one instead:
    // placing it on the old clock puts rows at full height above rows that
    // are still flying in, which is the very defect 2a is about, reappearing
    // in the middle of the list.
    property int _headRank: -1

    // THE WAVE IS OVER. Nothing is left in the air and nothing may be let
    // back into it: every remaining row is at its resting height, which is
    // what "the viewport is full, so everything else is simply there" means.
    //
    // `settle` puts the rows the wave animated back to "rest", which is what
    // the model has to say once they have arrived: `rowState` is read as what
    // a row is DOING, and leaving every row that ever entered marked
    // "entering" is a lie the next reader trips over. It is skipped by the cap
    // alone, where a row may still be flying and writing its state would snap
    // it into place.
    function _endWave(settle) {
        waveEnd.stop();
        root._waveActive = false;
        root._waveCapped = false;
        root._wavePlaced = ({});
        if (!settle) return;
        for (let i = 0; i < rowModel.count; i++)
            if (rowModel.get(i).rowState === "entering")
                rowModel.setProperty(i, "rowState", "rest");
    }

    ClockTimer {
        id: waveEnd
        clock: root._clock
        // The BACKSTOP, and only that: the head timer is the earlier of the
        // two in every wave that is not longer than waveMaxMs, and putting the
        // tail down ends the wave itself. So getting here at all means the
        // head outran the cap -- a reader scrolling along with a very long
        // entrance, which keeps extending it -- and the tail is put down now
        // rather than left folded away.
        onTriggered: root._tailHeld ? root._placeTail(!root._waveCapped)
                                    : root._endWave(!root._waveCapped)
    }

    // `lastIdx` is the last rank in the wave; `headIdx` the last rank that is
    // actually staggered, or -1 when nothing is (a fill with no viewport, or
    // one that fits entirely on screen).
    function _armWave(lastIdx, headIdx) {
        root._waveStart = root._clock.now;
        root._waveActive = true;
        const full = root.rowAnimDuration
            + root.rowStaggerMs * Math.max(0, lastIdx) + 80;
        root._waveCapped = full > root.waveMaxMs;
        waveEnd.interval = Math.min(root.waveMaxMs, full);
        waveEnd.restart();
        // The tail waits for the head. With no head there is nothing to wait
        // for, and the timer is one frame long instead of nothing at all
        // because the expansion's follow hangs off the same clock.
        root._tailHeld = headIdx >= 0;
        root._headRank = headIdx;
        headEnd.interval = headIdx >= 0
            ? root.rowAnimDuration + root.rowStaggerMs * headIdx + 40
            : 16;
        headEnd.restart();
    }

    ClockTimer {
        id: headEnd
        clock: root._clock
        // The head has landed -- every row of it, including any the
        // reassessment let in after the fill named one -- so the rows it
        // animated are at rest and the wave can be settled with them.
        onTriggered: root._placeTail(true)
    }

    // The head has landed, so the fold is where it will finally be: everything
    // past it takes its height, in this one frame. Nothing on screen moves,
    // because a head that has landed has filled the viewport by construction —
    // except when the reader has scrolled ABOVE the folded block, and then the
    // height appearing over their heads would drag the list down under them,
    // so the scroll pays back exactly what it took (the mirror of _sync's
    // `dropAbove`).
    function _placeTail(settle) {
        root._tailHeld = false;
        const cy = flick.contentY;
        // The live foot of the last row that HAS a position, walked down the
        // list. A folded row cannot be asked where it is: a Column does not
        // position a child of zero size at all, so its own `y` is still 0 and
        // every one of them would read as being above the viewport.
        let liveY = content.y;
        let addAbove = 0;
        for (let i = 0; i < rowModel.count; i++) {
            const r = rowModel.get(i);
            if (r.rowState === "collapsed") {
                if (liveY < cy) addAbove += root._pitchOf(r);
                rowModel.setProperty(i, "rowState", "rest");
                continue;
            }
            const item = rowRepeater.itemAt(i);
            // A row of zero height is not positioned either — an entering row
            // whose turn has not come yet is as unpositioned as a folded one,
            // and reading its `y` (still 0) puts the live cursor back at the
            // top of the list and pays back height that is below the reader.
            if (item && item.height > 0) liveY = content.y + item.y + item.height;
        }
        // BEFORE the scroll is paid back, not after: the rows have just taken
        // their height in the MODEL, but the Column only lays them out in its
        // polish, and until it has, the Flickable's bounds are still the
        // folded list's. A contentY beyond those bounds is fixed up straight
        // back by the Flickable, so the payback would survive or not according
        // to which of the two polished first -- at listScale 1 it did, at 1.2
        // it did not, and a semantically identical edit anywhere in the file
        // could flip it either way.
        if (addAbove > 0) {
            content.ensurePolished();
            flick.contentY = cy + addAbove;
        }
        // AND THE WAVE ENDS HERE, in the same frame. The head has landed, so
        // the viewport is full by construction and everything past it is now
        // at its resting height: there is nothing left that could animate, and
        // a row already at rest must never be flown in again because a scroll
        // brought it into view.
        //
        // Leaving the wave open for the ranks of the rows that were never
        // staggered would make a scroll started the moment the list looks full
        // pull single rows in out of order -- one here, one there, wherever a
        // rank happens to be still ahead of the clock -- for as long as the
        // WHOLE fill would take.
        root._endWave(settle);
        root._followExpansion();
    }

    // Reassessment while the head is still arriving (the doc's rule 4, read
    // through 2a): the reader can scroll while the tail is folded away, and
    // what the new viewport reaches must be rows rather than the seam the fold
    // left. As many of the folded rows as that viewport needs are let into the
    // wave, in order and each at its own turn -- the cadence is counted from
    // the wave's start, so a reader scrolling along with an entrance sees one
    // row arrive per stagger step exactly as the rows above them did.
    //
    // ASKED OF THE LIVE LAYOUT, NOT THE RESTING ONE.
    // A folded row has NO HEIGHT, so the fold is not a hole in the list: the
    // rows after it close up over it, and what a scroll actually brings into
    // view is whatever follows the fold. The resting slot answers a different
    // question ("will this row be on screen when it is all over"), and
    // answering that one un-folds every row the finished list would have put
    // in the viewport -- which, while the list is short by the whole of the
    // tail, is a screenful of rows sitting far ABOVE the reader. They then
    // arrive one by one over their own ranks, each pushing everything below
    // them down, and the reader is dragged backwards through the album for as
    // long as the wave lasts: a scroll of 900 px during a sixty-song entrance
    // promotes 49 rows and walks the view from Album 06 back to track 38 over
    // two seconds.
    //
    // So the layout the wave is COMMITTED to is walked instead: every row that
    // is not folded away holds its full pitch, whether it has arrived yet or
    // not, and only the folded ones hold nothing. That is where the fold will
    // be once everything already in the wave has landed, and it is the only
    // reading that is stable -- asking the LIVE heights instead makes an
    // entering row that has not started count for nothing, so the next scroll
    // finds the fold back at the top and un-folds another screenful, and
    // another, until the whole tail is in the wave. A folded row is let in
    // only if its slot there reaches the viewport; the ones behind the reader
    // stay folded, and `_placeTail` pays their height back through the scroll
    // in one frame instead.
    function _unfoldToFill() {
        const cy = flick.contentY;
        const vh = root._viewH;
        if (vh <= 0) return;
        const cursor = (root._clock.now - root._waveStart) / Math.max(1, root.rowStaggerMs);
        const keep = {};
        for (const k in root._wavePlaced) keep[k] = root._wavePlaced[k];
        let y = 0;
        let touched = false;
        let last = root._headRank;
        for (let i = 0; i < rowModel.count; i++) {
            const r = rowModel.get(i);
            const h = root._pitchOf(r);
            if (r.rowState !== "collapsed") { y += h; continue; }
            if (y > cy + vh + root._groupPitch) break;      // past the fold
            if (!root._onScreen(y, r, cy)) continue;   // behind the reader
            const wi = root._wavePlaced[r.key];
            rowModel.setProperty(i, "staggerIdx",
                wi === undefined ? 0 : Math.max(0, Math.round(wi - cursor)));
            rowModel.setProperty(i, "rowState", "entering");
            delete keep[r.key];
            if (wi !== undefined && wi > last) last = wi;
            touched = true;
            y += h;
        }
        if (!touched) return;
        root._wavePlaced = keep;
        // The tail now waits for the LAST row let in, not for the head the
        // fill named: placing it on the old clock would put the rows past the
        // fold at full height above rows still flying in.
        if (last > root._headRank) {
            root._headRank = last;
            headEnd.interval = Math.max(16,
                root._waveStart + root.rowAnimDuration
                + root.rowStaggerMs * last + 40 - root._clock.now);
            headEnd.restart();
        }
    }

    // What a scroll means, and the ONE thing it can do (the doc's rule 4).
    // There is exactly one window in which a scroll can change who animates:
    // while the head is still arriving and the tail is folded away. What the
    // new viewport reaches then is the seam the fold left, so the rows it
    // reaches are let into the wave. Once the tail is down the wave is over --
    // every row is at its resting height, the fold has nothing behind it, and
    // a scroll is browsing a finished list.
    function _reassess() {
        if (!root._waveActive || !root._tailHeld) return;
        // The follow's own scroll is the panel moving the list, not the reader
        // scrolling into the fold.
        if (followAnim.running) return;
        root._unfoldToFill();
    }

    // =====================================================================
    //  FOLLOWING WHAT OPENS AT THE FOOT   (list_animation.md, "at the very
    //  bottom")
    // =====================================================================
    // The header a click has just opened, held until the wave it started has
    // put the tail down — which is also when the block's resting geometry is
    // final. It survives a wave that inserted nothing (a host that answers an
    // expand asynchronously opens the group first and sends the songs after),
    // and any wave at all spends it.
    property string _followKey: ""

    NumberAnimation {
        id: followAnim
        target: flick
        property: "contentY"
        duration: root.expandFollowMs
        easing.type: Easing.OutCubic
    }

    function _followExpansion() {
        const key = root._followKey;
        root._followKey = "";
        if (key === "" || !root._isExpanded(key)) return;
        const vh = flick.height;
        const a = root._offsets;
        if (vh <= 0 || a.length !== rowModel.count || rowModel.count === 0) return;
        let idx = -1;
        for (let i = 0; i < rowModel.count; i++)
            if (rowModel.get(i).key === key) { idx = i; break; }
        if (idx < 0) return;
        const hdr = rowModel.get(idx);
        // What opened under it: everything nested deeper, which is one level
        // for an album's songs and two for a genre's albums and their songs.
        let end = idx + 1;
        while (end < rowModel.count && rowModel.get(end).depth > hdr.depth) end++;
        if (end === idx + 1) return;            // nothing arrived yet
        const cy = flick.contentY;
        // The foot of the header's own BOX, which is where the block starts.
        const foot = a[idx] + root._rowH(hdr) - root._bottomGap;
        if ((cy + vh) - foot >= root.expandFollowMinRows * root._songPitch) return;
        const last = rowModel.get(rowModel.count - 1);
        const blockEnd = a[end - 1] + root._rowH(rowModel.get(end - 1));
        // The resting scroll extent, from the offsets rather than from the
        // live Column: the rows the head timer has just placed have not been
        // through a layout pass yet, so `flick.contentHeight` is a frame stale
        // here and this is not.
        const maxScroll = Math.max(0, a[rowModel.count - 1] + root._pitchOf(last)
                                      - root._vSpacing - root._tailGap
                                      + root._footAir - vh);
        // Follow the block to its end, but never past the header's own top:
        // the header staying visible is what says which thing opened.
        const want = Math.min(a[idx], blockEnd - vh, maxScroll);
        if (want <= cy + 0.5) return;
        followAnim.stop();
        scrollEngine.stop();
        followAnim.to = want;
        followAnim.start();
    }

    // =====================================================================
    //  FILLING, DIFFING AND SWAPPING
    // =====================================================================
    // A whole list, from nothing. Rows that land on screen enter staggered;
    // the rest are placed, and remember their rank in case a scroll brings
    // them into view before the wave has passed them.
    function _fill(want, cy) {
        rowModel.clear();
        const offs = root._offsetsOf(want);
        const placed = {};
        // Who is on screen is decided for the whole list first: a row is only
        // folded away when there is a head for it to wait for.
        const on = [];
        let head = -1;
        for (let i = 0; i < want.length; i++) {
            on.push(root._onScreen(offs[i], want[i], cy));
            if (on[i]) head = i;
        }
        for (let i = 0; i < want.length; i++) {
            const e = want[i];
            if (on[i]) {
                e.rowState = "entering";
                e.staggerIdx = i;
            } else {
                e.rowState = head >= 0 ? "collapsed" : "rest";
                e.staggerIdx = 0;
                placed[e.key] = i;
            }
            rowModel.append(e);
        }
        root._wavePlaced = placed;
        root._rebuildOffsets();
        if (want.length > 0) root._armWave(want.length - 1, head);
    }

    function _indexOfKey(key, from) {
        for (let i = from || 0; i < rowModel.count; i++)
            if (rowModel.get(i).key === key && rowModel.get(i).rowState !== "leaving")
                return i;
        return -1;
    }

    function _sync() {
        // The swap owns the model until it fills, and the fill it is about to
        // do reads the target as it is then, so there is nothing to lose here.
        if (swapEnter.running) return;
        if (!root._viewportReady()) { layoutWait.restart(); return; }

        root._rebuildOffsets();
        const want = root._target();
        // AN EMPTY SHELF WHILE THE LIBRARY IS BEING FETCHED IS NOT AN EMPTY
        // SHELF. Changing the source hands the panel the NEW source's lists,
        // and those are empty until the daemon answers -- so the whole list
        // would be torn down and built again a moment later, and the covers
        // would pop out and in: every row destroyed takes its Image with it,
        // and every row rebuilt asks for the same picture a second time. The panel holds what it has until the answer arrives, and
        // then diffs it; `loading` falling is what asks again (below), so an
        // answer that really is empty still empties the list.
        if (root.loading && want.length === 0 && rowModel.count > 0) return;
        const offs = root._offsets;
        const cy = flick.contentY;

        const wanted = {};
        for (let i = 0; i < want.length; i++) wanted[want[i].key] = true;

        // ---- who goes, and who goes without being seen to ----------------
        // Everything off screen is removed in this frame. Rows above the
        // viewport would drag the list up under the user as they went, so the
        // scroll position pays back exactly what they took with them.
        let dropAbove = 0;
        for (let i = rowModel.count - 1; i >= 0; i--) {
            const r = rowModel.get(i);
            if (wanted[r.key] || r.rowState === "leaving") continue;
            if (root._onScreen(offs[i], r, cy)) continue;
            if (offs[i] + root._rowH(r) <= cy) dropAbove += root._pitchOf(r);
            root._dropRow(i);
        }
        if (dropAbove > 0) flick.contentY = Math.max(0, cy - dropAbove);

        let leaving = 0;
        for (let i = 0; i < rowModel.count; i++) {
            const r = rowModel.get(i);
            if (wanted[r.key] || r.rowState === "leaving") continue;
            rowModel.setProperty(i, "staggerIdx", leaving++);
            rowModel.setProperty(i, "rowState", "leaving");
        }

        if (rowModel.count === 0) root._buildCursor = 0;

        // ---- who arrives -------------------------------------------------
        // `y` walks the layout as it will be, leaving rows included: they hold
        // their height until they have gone, so they hold the fold's place too.
        const placed = {};
        // Where the folded rows went in, so the pass below can write their
        // state once the whole wave is known. An index recorded here stays
        // valid: everything that follows is inserted or moved at a cursor
        // above it.
        const placedIdx = [];
        let entering = 0;
        let lastHead = -1;
        let cursor = 0;
        let y = 0;
        for (let k = 0; k < want.length; k++) {
            while (cursor < rowModel.count && rowModel.get(cursor).rowState === "leaving") {
                y += root._pitchOf(rowModel.get(cursor));
                cursor++;
            }
            const e = want[k];
            const at = root._indexOfKey(e.key, cursor);
            if (at < 0) {
                if (root._onScreen(y, e, flick.contentY)) {
                    e.rowState = "entering";
                    e.staggerIdx = entering;
                    lastHead = entering;
                } else {
                    e.rowState = "rest";
                    e.staggerIdx = 0;
                    placed[e.key] = entering;
                    placedIdx.push(cursor);
                }
                entering++;
                rowModel.insert(cursor, e);
            } else {
                if (at !== cursor) rowModel.move(at, cursor, 1);
                const cur = rowModel.get(cursor);
                if (cur.grouping !== e.grouping) rowModel.setProperty(cursor, "grouping", e.grouping);
                if (cur.isList !== e.isList) rowModel.setProperty(cursor, "isList", e.isList);
                if (cur.primary !== e.primary) rowModel.setProperty(cursor, "primary", e.primary);
                if (cur.secondary !== e.secondary) rowModel.setProperty(cursor, "secondary", e.secondary);
                if (cur.countText !== e.countText) rowModel.setProperty(cursor, "countText", e.countText);
                if (cur.cover !== e.cover) rowModel.setProperty(cursor, "cover", e.cover);
                if (cur.covers !== e.covers) rowModel.setProperty(cursor, "covers", e.covers);
                if (cur.genre !== e.genre) rowModel.setProperty(cursor, "genre", e.genre);
                if (cur.dur !== e.dur) rowModel.setProperty(cursor, "dur", e.dur);
                if (cur.track !== e.track) rowModel.setProperty(cursor, "track", e.track);
                if (cur.numbered !== e.numbered) rowModel.setProperty(cursor, "numbered", e.numbered);
                if (cur.depth !== e.depth) rowModel.setProperty(cursor, "depth", e.depth);
                if (cur.removable !== e.removable) rowModel.setProperty(cursor, "removable", e.removable);
                if (cur.removeKey !== e.removeKey) rowModel.setProperty(cursor, "removeKey", e.removeKey);
                // A seam is keyed by the row it follows, so opening the run
                // above it keeps the same row and only moves its ink.
                if (cur.inkAbove !== e.inkAbove) rowModel.setProperty(cursor, "inkAbove", e.inkAbove);
                if (cur.inkBelow !== e.inkBelow) rowModel.setProperty(cursor, "inkBelow", e.inkBelow);
                if (cur.rowState === "leaving") rowModel.setProperty(cursor, "rowState", "rest");
            }
            y += root._pitchOf(e);
            cursor++;
        }

        if (entering > 0) {
            root._wavePlaced = placed;
            // Folded away only if there is a head to wait for. Written after
            // the pass rather than during it, because a head row can follow a
            // placed one and nothing knows there is one until the end.
            if (lastHead >= 0)
                for (let i = 0; i < placedIdx.length; i++)
                    rowModel.setProperty(placedIdx[i], "rowState", "collapsed");
            root._armWave(entering - 1, lastHead);
        }
        if (leaving > 0) {
            // The wave the sweep has to outlast is the one just started, not
            // a guess: a fixed interval clips the tail of a longer list.
            leaveCleanup.interval = root.rowAnimDuration
                + root.rowStaggerMs * Math.max(0, leaving - 1) + 60;
            leaveCleanup.restart();
        }
        root._rebuildOffsets();
    }

    // A row taken out of the model while its content is built re-reads a model row that is gone, once per bound property
    // ("Unable to assign [undefined] to QString" x 20 a row: the query's leavers, a rescan's -- `clear()` does not do it). The
    // content is switched off first, which is also the cheaper way to end it.
    function _dropRow(i) {
        const it = rowRepeater.itemAt(i);
        if (it && it.bodyLoader) it.bodyLoader.active = false;
        rowModel.remove(i);
    }

    ClockTimer {
        id: leaveCleanup
        clock: root._clock
        interval: root.rowAnimDuration + root.rowStaggerMs + 60
        // Written by _sync from the size of the wave it just started.
        onTriggered: {
            for (let i = rowModel.count - 1; i >= 0; i--)
                if (rowModel.get(i).rowState === "leaving") root._dropRow(i);
            root._rebuildOffsets();
        }
    }

    // A grouping switch: collapse, then expand. Everything off screen goes in
    // this frame (with the scroll paying back what it took, as in _sync), the
    // rest leaves staggered, and the new grouping is filled in only once the
    // last of them has landed.
    function _beginSwap() {
        // Before the panel has been laid out there is no fold to collapse to
        // and nothing to see leaving: the switch is a plain diff, deferred by
        // _sync until there is a viewport.
        if (!root._viewportReady()) { root._sync(); return; }
        root._rebuildOffsets();
        const offs = root._offsets;
        const cy = flick.contentY;
        let dropAbove = 0;
        for (let i = rowModel.count - 1; i >= 0; i--) {
            const r = rowModel.get(i);
            if (root._onScreen(offs[i], r, cy)) continue;
            if (offs[i] + root._rowH(r) <= cy) dropAbove += root._pitchOf(r);
            root._dropRow(i);
        }
        if (dropAbove > 0) flick.contentY = Math.max(0, cy - dropAbove);

        let leaving = 0;
        for (let i = 0; i < rowModel.count; i++) {
            rowModel.setProperty(i, "staggerIdx", leaving++);
            rowModel.setProperty(i, "rowState", "leaving");
        }
        root._rebuildOffsets();
        root._endWave(false);
        headEnd.stop();
        root._tailHeld = false;
        followAnim.stop();
        root._followKey = "";
        leaveCleanup.stop();
        swapEnter.interval = leaving > 0
            ? root.rowAnimDuration + root.rowStaggerMs * (leaving - 1) + root.swapGapMs
            : Math.max(16, root.swapGapMs);
        swapEnter.restart();
    }

    ClockTimer {
        id: swapEnter
        clock: root._clock
        onTriggered: {
            rowModel.clear();
            flick.contentY = 0;
            root._fill(root._target(), 0);
        }
    }

    property bool _syncQueued: false
    function _scheduleRebuild() {
        if (root._syncQueued) return;
        root._syncQueued = true;
        Qt.callLater(function () {
            root._syncQueued = false;
            root._sync();
        });
    }

    // NOT `recent`: it is republished on every track that plays, and dropping
    // the fetch caches that often would send the host back to MPD for every
    // open group all day. The other four move only when a scan lands or a
    // playlist is edited, which is exactly when what was fetched is stale.
    onAlbumsChanged: { root._scheduleRebuild(); root._scheduleInvalidate(); }
    onArtistsChanged: { root._scheduleRebuild(); root._scheduleInvalidate(); }
    onGenresChanged: { root._scheduleRebuild(); root._scheduleInvalidate(); }
    onRecentChanged: root._scheduleRebuild()
    onPlaylistsChanged: { root._scheduleRebuild(); root._scheduleInvalidate(); }
    onGroupingChanged: {
        tabRow.noteSideRole();
        root.closePage(true);
        root._beginSwap();
    }
    // The first fill is a sync into an empty model -- the same insert path,
    // the same fold, and the guard above. `_fill` is the swap's, where the
    // viewport is long since known.
    Component.onCompleted: {
        // A panel built with the fetch already out has nothing to show, so it
        // shows the silhouette -- the one case the handler cannot see,
        // because `loading` never changes.
        if (root.loading) {
            skeleton.reset();
            root._skeletonAlive = true;
        }
        root._sync();
    }

    // Opening a group. `kind` is what the host is asked for: an album's songs,
    // an artist's or a playlist's songs, or a GENRE's albums — a genre is a
    // list of albums here, so that is what it is asked for, and the host
    // answers with setAlbums(). A recently-played album carries its own songs
    // and asks for nothing.
    function _toggleGroup(rowKey, kind, dataKey) {
        const m = {};
        for (const k in root._expanded) m[k] = root._expanded[k];
        const open = !m[rowKey];
        if (open) m[rowKey] = true; else delete m[rowKey];
        root._expanded = m;
        // What each OPEN group would have to ask the host for again. `_expanded`
        // is keyed by row key alone and the request needs the kind and the data
        // key, which only this function is given -- so they are kept here, for
        // `_invalidateFetched` to re-issue after a rescan.
        const r = {};
        for (const k in root._openReq) r[k] = root._openReq[k];
        if (open) r[rowKey] = { kind: kind, dataKey: dataKey }; else delete r[rowKey];
        root._openReq = r;
        // The list follows what opened, if what opened would land off screen.
        // Held until the wave puts the tail down; a group whose songs the host
        // has yet to send starts no wave at all, and the follow waits for the
        // one that arrives with them.
        root._followKey = open ? rowKey : "";
        // Ask only for what is not already in hand: a second click on a group
        // that has been open before should not send the host back to MPD.
        if (open) {
            if (kind === "genre") {
                if (root._genreAlbums[dataKey] === undefined)
                    root.expandRequested(kind, dataKey);
            } else if (kind !== "recentAlbum"
                       && root._songs[root._cacheKey(kind, dataKey)] === undefined) {
                root.expandRequested(kind, dataKey);
            }
        }
        root._sync();
    }

    // =====================================================================
    //  THE ROW MENU
    // =====================================================================
    property var _menuTarget: null
    property var _menuRows: []
    // `t.what`: "album" | "artist" | "genre" | "playlist" | "song". Rows are FACTS (a menu's rows may hold
    // no colour: the row array is compared by value).
    function _rowsFor(t) {
        const what = t.what;
        if (what === "song") {
            const rows = [{ id: "play", label: "Play" }, { id: "next", label: "Play next" }, { id: "queue", label: "Add to queue" },
                          { separator: true }, { id: "details", label: "Song details" }];
            // On a song of an album's page, that album is what is on show.
            if (t.onPage !== "album")
                rows.push({ id: "showalbum", label: "Show album" });
            rows.push({ id: "songartist", label: "Go to artist" });
            return rows;
        }
        if (what === "album")
            return [{ id: "play", label: "Play" }, { id: "next", label: "Play next" }, { id: "queue", label: "Add to queue" },
                    { separator: true }, { id: "page", label: "Open album" }, { id: "artist", label: "Go to artist" }];
        if (what === "artist")
            return [{ id: "play", label: "Play" }, { id: "next", label: "Play next" }, { id: "queue", label: "Add to queue" },
                    { separator: true }, { id: "page", label: "Open artist" }];
        return [{ id: "play", label: "Play" }, { id: "queue", label: "Add to queue" }];
    }
    function _openRowMenu(lrow, mouse) {
        if (!root.menuOverlay) { lrow._queue(); return; }
        const what = lrow._queueKind();
        const parts = String(lrow.dataKey).split(root.keySeparator);
        const c = lrow.mapToItem(null, lrow.width / 2, (lrow.isHeader ? lrow._boxH : lrow.implicitHeight) / 2);
        const t = { what: what, uri: lrow.uri, a: what === "song" ? "" : (parts[0] || ""), b: parts[1] || "", sx: c.x, sy: c.y,
                    tile: { where: "list", key: lrow.rowKey }, first: what === "song" ? { title: lrow.primary, artist: lrow.secondary, album: "" } : null };
        const q = lrow.mapToItem(null, mouse.x, mouse.y);
        root._openMenuAt(t, q.x, q.y);
    }
    function _openMenuAt(t, sceneX, sceneY) {
        if (!root.menuOverlay) return;
        root._menuTarget = t;
        root._menuRows = root._rowsFor(t);
        const p = root.menuOverlay.mapFromItem(null, sceneX, sceneY);
        rowMenu.openAt(p.x, p.y);
    }
    function _menuPick(id) {
        const t = root._menuTarget;
        if (!t) return;
        switch (id) {
        case "play":
            if (t.what === "song") root.playSongRequested(t.uri);
            else if (t.what === "album") root.playAlbumRequested(t.a, t.b);
            else root.actionRequested("play", t.what, t.a, t.b);
            break;
        case "next":
            root.actionRequested("next", t.what, t.what === "song" ? t.uri : t.a, t.b);
            root.queuedFeedback(t.sx, t.sy, t.what);
            break;
        case "queue":
            if (t.what === "song") root.queueSongRequested(t.uri);
            else if (t.what === "album") root.queueAlbumRequested(t.a, t.b);
            else root.queueGroupRequested(t.what, t.a);
            root.queuedFeedback(t.sx, t.sy, t.what);
            break;
        case "details":
            pageStack.openPage("song", t.uri, "", t.tile, null, t.first);
            break;
        case "showalbum":
        case "songartist":
            // A song's row knows its name, not its album's: the daemon does.
            if (root.player)
                root.player.songInfo(t.uri, info => {
                    if (!info)
                        return;
                    if (id === "showalbum")
                        pageStack.openPage("album", info.song.albumArtist || info.song.artist, info.song.album, t.tile);
                    else
                        pageStack.openPage("artist", info.song.albumArtist || info.song.artist, "", t.tile);
                });
            break;
        case "page":
            pageStack.openPage(t.what === "artist" ? "artist" : "album", t.a, t.b, t.tile);
            break;
        case "artist":
            pageStack.openPage("artist", t.a, "", t.tile);
            break;
        }
    }
    FloatingMenu {
        id: rowMenu
        overlayItem: root.menuOverlay
        fontFamily: root.fontFamily
        fontPixelSize: 12
        menuWidth: 168
        rows: root._menuRows
        onTriggered: id => root._menuPick(id)
    }

    // =====================================================================
    //  THE PAGES: an album's, an artist's, a song's, over the list
    // =====================================================================
    // PlayerPageStack holds them; this file says what its rows look like on the card and answers for them. Everything floating over the list (the stack included) stands
    // above the list's dressing and never reaches the box's corners.
    property int pageMorphMs: 320
    property real swipeBackUnits: 900
    property real swipeBackSign: 1
    readonly property bool pageOpen: pageStack.pageOpen
    readonly property var pageEntry: pageStack.pageEntry
    readonly property alias pages: pageStack
    // The chrome over the box (the grouping selector, the shelf's line) and the box itself come in with a page that crossed from another panel, and leave with it.
    readonly property real _chromeF: pageStack.crossing !== "" ? pageStack.crossArrive : 1
    readonly property string crossing: pageStack.crossing
    readonly property string _listLabel: root.searching ? "Results" : root.grouping === "artists" ? "Artists" : root.grouping === "genres" ? "Genres"
        : root.grouping === "playlists" ? "Lists" : root.grouping === "recent" ? "Recent" : "Albums"
    // `t`: { where: "list", key }: a row of the list, if it is on screen.
    function _listTile(t) {
        const i = root._indexOfKey(t.key);
        const w = i >= 0 ? rowRepeater.itemAt(i) : null;
        const b = w && w.bodyLoader ? w.bodyLoader.item : null;
        if (!b)
            return null;
        const top = content.y + w.y - flick.contentY;
        const h = b.isHeader ? b._boxH : b.implicitHeight;
        if (top + h <= 0 || top >= flick.height)
            return null;
        return { item: b, w: b.width, h: h, color: b.isHeader ? root.headerBoxColor : root.listBoxColor, radius: b.isHeader ? root.containerRadius : 6,
                 facts: { kind: b.kind, grouping: b.grouping, isList: b.isList, depth: b.depth, rowKey: b.rowKey, dataKey: b.dataKey, primary: b.primary,
                          secondary: b.secondary, countText: b.countText, cover: b.cover, covers: b.covers, genre: b.genre, uri: b.uri, track: b.track,
                          numbered: b.numbered, dur: b.dur } };
    }
    // From outside (the host's "Show album" / "Go to artist"): `tile` and `ret` say what it grows out of and where back leads when that is another panel (PlayerPageStack).
    function openAlbumPage(albumArtist, album, tile, ret) { pageStack.openPage("album", albumArtist, album, tile || null, ret || null); }
    function openArtistPage(name, tile, ret) { pageStack.openPage("artist", name, "", tile || null, ret || null); }
    function showAlbumPage(albumArtist, album, info) { pageStack.showAlbumPage(albumArtist, album, info); }
    function closePage(all) { pageStack.closePage(all); }
    function pinPageMorph(t) { pageStack.pinPageMorph(t); }
    function releasePageMorph() { pageStack.releasePageMorph(); }

    // =====================================================================
    //  THE PANEL
    // =====================================================================
    implicitHeight: tabRow.height + root.padding * root._s + controlsRow.height + root.padding * root._s + content.implicitHeight

    // What this panel paints outside its own rect, in whole pixels -- the largest of its parts that
    // stand flush with it on its top, left and right: the grouping selector's carved track, the
    // list's carved box, and the raised button at the row's right end (a drop shadow `shadowWidth`
    // wide). A clip standing on the panel's edge must stand at least this far out
    // (AudioPlayerPopup's `panelHost._slack` reads it), or the band is scissored.
    readonly property real bleed: Math.ceil(Math.max(tabs.bleed, box._margin, sideButton.shadowWidth + 1))

    Item {
        id: tabRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: Math.round(root.tabRowHeight * root._s)
        opacity: root._chromeF

        // Two groupings carry a button at the right end of the row: recently
        // played can be emptied, and artists can be widened to the ones with
        // no album of their own. ONE button does both — two of them fading
        // through the same slot is the crossfade the motion rules forbid,
        // where a label swapping in place is what they ask for. One eased
        // fraction moves both its presence and the room the selector gives up
        // for it; a Behavior each would be two clocks for one motion.
        property real sideF:
            (root.grouping === "recent" || root.grouping === "artists") ? 1 : 0
        Behavior on sideF {
            NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
        }
        readonly property real sideW: Math.round(root.sideButtonWidth * root._s)

        // "clear" | "scope". Latched rather than bound: on the way to a
        // grouping that has no button the role must not change under the fade,
        // exactly as a leaving row keeps the content it was drawn with.
        property string sideRole: "clear"
        function noteSideRole() {
            if (root.grouping === "recent") tabRow.sideRole = "clear";
            else if (root.grouping === "artists") tabRow.sideRole = "scope";
        }
        Component.onCompleted: tabRow.noteSideRole()

        TabSelector {
            id: tabs
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            anchors.rightMargin: tabRow.sideF * (tabRow.sideW + root.rowGap * root._s)
            trackRadiusOverride: root.tabRadius
            // Its own defaults are eva-light literals, which is how a light
            // pill ends up on a dark card when a host does not pass them.
            trackSurfaceColor: root.surfaceColor
            trackBevelColor: root.borderColor
            trackShadowColor: root.headerBoxShadowColor
            trackBackgroundColor: root.panelColor
            pillSurfaceColor: root.panelColor
            pillBevelColor: root.accentBevelColor
            pillShadowColor: root.buttonShadowColor
            pillBackgroundColor: root.accentColor
            textColor: root.textColor
            activeTextColor: root.textOnAccentColor
            fontFamily: root.fontFamily
            fontPixelSize: root.compact ? 11 : 12
            tabs: [
                {id: "albums",    label: "Albums"},
                {id: "artists",   label: "Artists"},
                {id: "genres",    label: "Genres"},
                {id: "recent",    label: "Recent"},
                {id: "playlists", label: "Lists"}
            ]
            onTabChanged: (id) => {
                root.grouping = id;
                root.groupingChanged_(id);
                // The selector says what is under it: a page over the list goes with the list it stood on.
                root.closePage(true);
            }
        }
        // A click writes the selector's own currentTab, which would cut a plain binding for good.
        Binding {
            target: tabs
            property: "currentTab"
            value: root.grouping
        }

        RaisedButton {
            id: sideButton
            objectName: "playerLibrarySideButton"
            x: tabRow.width - sideButton.width
            y: 0
            width: tabRow.sideW
            // The selector's own height, because the two are one row.
            height: tabRow.height
            minWidth: tabRow.sideW
            horizontalPadding: 10 * root._s
            fontPixelSize: root.figureSize * root._s
            fontFamily: root.fontFamily
            text: tabRow.sideRole === "scope" ? "All" : "Clear"
            // It sits directly over the container's own top-right corner, so
            // it takes the container's radius: two curves that meet have to
            // coincide. Not scaled — containerRadius is the host's own number
            // for that corner, at the size the host draws it.
            radius: root.containerRadius
            bevelWidth: 1.5
            shadowWidth: 5
            opacity: tabRow.sideF
            visible: sideButton.opacity > 0.01
            // The scope toggle is always live; Clear has nothing to clear when
            // recently played is empty.
            enabled: tabRow.sideRole === "scope"
                     || (root.recent || []).length > 0
            // The accent is the shell's own "active fill", and it is the only
            // mark this button needs to say the wider scope is on: one fact,
            // one mark, and the label stays put.
            accent: tabRow.sideRole === "scope" && root.artistsIncludeLoose
            surfaceColor: root.surfaceColor
            plateauColor: root.buttonPlateauColor
            plateauHoverColor: root.buttonPlateauHoverColor
            bevelColor: root.buttonBevelColor
            shadowColor: root.buttonShadowColor
            textColor: root.textColor
            faintTextColor: root.faintColor
            // RaisedButton's accent trio are eva-light literals that no host
            // ever passed, which is exactly how a light pill ends up on a dark
            // card.
            accentColor: root.accentColor
            accentHoverColor: root.accentHoverColor
            accentBevelColor: root.accentBevelColor
            accentTextColor: root.textOnAccentColor
            onClicked: {
                if (tabRow.sideRole === "scope")
                    root.artistScopeToggled(!root.artistsIncludeLoose);
                else
                    root.clearRecentRequested();
            }
        }
    }

    // THE SHELF AND ITS SORT: one row under the selector. It says how much is on the shelf until something is typed, then what was
    // typed, as the notes' and the launcher's titles do (no field: the popup's keys come here). The query filters the shelf and asks
    // the daemon for songs, shown after the shelf's own matches. The label sorts it; Recent has no sort.
    Item {
        id: controlsRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: tabRow.bottom
        anchors.topMargin: root.padding * root._s
        height: Math.round(root.controlsRowHeight * root._s)
        opacity: root._chromeF

        readonly property bool sortable: root._sortModesOf(root.grouping).length > 0
        readonly property bool sortShown: controlsRow.sortable && !root.searching && !root.pageOpen

        Text {
            id: shelfLine
            objectName: "playerLibraryShelf"
            visible: !root.searching
            x: root.shelfTextInset * root._s
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, sortCtl.x - x - root.rowGap * root._s)
            elide: Text.ElideRight
            text: root._shelfText
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: root.shelfTextSize * root._s
            font.bold: true
        }
        Row {
            id: queryLine
            objectName: "playerLibraryQuery"
            visible: root.searching
            x: root.shelfTextInset * root._s
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            Text {
                id: queryGlyph
                anchors.verticalCenter: parent.verticalCenter
                text: ""
                font.family: "Symbols Nerd Font"
                font.pixelSize: 12 * root._s
                color: root.faintColor
            }
            Text {
                id: queryText
                anchors.verticalCenter: parent.verticalCenter
                // The end of what is being typed stays in view, as in the launcher's title.
                width: Math.min(implicitWidth, controlsRow.width - queryLine.x - queryGlyph.width - queryLine.spacing)
                elide: Text.ElideLeft
                text: root.query
                color: root.textColor
                font.family: root.fontFamily
                font.pixelSize: root.shelfTextSize * root._s
                font.bold: true
            }
        }
        SortControl {
            id: sortCtl
            objectName: "playerLibrarySort"
            opacity: controlsRow.sortShown ? 1 : 0
            visible: sortCtl.opacity > 0
            Behavior on opacity {
                enabled: root._chromeF >= 1
                NumberAnimation { duration: 160 }
            }
            x: parent.width - sortCtl.width
            anchors.verticalCenter: parent.verticalCenter
            width: implicitWidth
            overlayItem: root.menuOverlay
            fontFamily: root.fontFamily
            fontPixelSize: 11
            modes: root._sortModesOf(root.grouping)
            mode: root._sortOf(root.grouping).mode
            ascending: root._sortOf(root.grouping).asc
            onSortRequested: (m, a) => root._setSort(m, a)
        }
    }
    Timer {
        id: searchDebounce
        interval: root.searchDebounceMs
        repeat: false
        onTriggered: {
            const q = root.query.trim();
            if (q === "") root.songHits = [];
            root._scheduleRebuild();
            root.searchRequested(q);
        }
    }

    ShadowBox {
        id: box
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: controlsRow.bottom
        anchors.topMargin: root.padding * root._s
        anchors.bottom: parent.bottom
        baseRadius: root.containerRadius
        surfaceColor: root.surfaceColor
        bevelColor: root.bevelColor
        shadowColor: root.borderColor
        backgroundColor: root.listBoxColor
        bevelWidth: 1
        shadowWidth: 3
        opacity: root._chromeF

        Flickable {
            id: flick
            objectName: "playerLibraryFlick"
            anchors.fill: parent
            contentWidth: content.width
            // The Column is lifted by half a row's virtual spacing so the
            // first row's content starts at the top edge, and the scroll gives
            // back the other half, plus the gap a header carries under its own
            // box. The air a bare-text tail gets instead is in the Column, as
            // `footAir` below.
            contentHeight: Math.max(0, content.height - root._vSpacing - root._tailGap)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            // The page left behind: gone (and deaf) for as long as a page lies on the box. Opacity, not visible: a hidden
            // Column does not hear its rows (CLAUDE.md, A HIDDEN SUBTREE LIES ABOUT ITS HEIGHT).
            opacity: pageStack.listF
            enabled: !root.pageOpen

            onContentYChanged: root._reassess()
            onMovementStarted: followAnim.stop()

            Column {
                id: content
                objectName: "playerLibraryContent"
                y: -root._vSpacing / 2
                width: flick.width
                spacing: 0
                // Towards the row a page grows out of. On the Column, so the Flickable's own clip stands where it stands.
                transform: Scale {
                    origin.x: pageStack.focusPoint.x
                    origin.y: pageStack.focusPoint.y - content.y + flick.contentY
                    xScale: pageStack.listZoom
                    yScale: pageStack.listZoom
                }
                opacity: root.loading && root._skeletonAlive ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }   // the skeleton's own fade (ListSkeleton.fadeMs)

                Repeater {
                    id: rowRepeater
                    model: rowModel

                    delegate: AnimatedListRow {
                        id: wrap
                        required property var model

                        property var bodyLoader: rowBody
                        waveClock: root._clock
                        rowState: wrap.model.rowState
                        staggerIdx: wrap.model.staggerIdx
                        animDuration: root.rowAnimDuration
                        staggerMs: root.rowStaggerMs
                        contentHeight: root._rowH(wrap.model)
                        virtualSpacing: root._vSpacing
                        onKicked: rowBody._latched = true

                        // THE ROW'S CONTENT IS BUILT WHEN IT IS NEEDED, NOT ALL AT ONCE. The row itself is cheap and
                        // carries the list's arithmetic (its height comes from the model); the content under it is
                        // ~1.2 ms of QML per row, and fifty-three of them built in the one frame of the fill make an
                        // 85 ms frame (a long library: a second). Rows near the reader are built at once, the rest
                        // after the entrance is over, `buildChunk` a tick, in list order (`_buildCursor`). A row
                        // once built stays built.
                        Loader {
                            id: rowBody
                            anchors.left: parent.left
                            anchors.right: parent.right
                            height: rowBody.item ? rowBody.item.implicitHeight : 0
                            readonly property bool _needed: root._rowNeeded(wrap.model.index, wrap.model)
                            property bool _latched: false
                            on_NeededChanged: if (rowBody._needed) rowBody._latched = true
                            Component.onCompleted: if (rowBody._needed) rowBody._latched = true
                            active: rowBody._latched
                            sourceComponent: LibraryRow {
                                // NOTHING PAST THE VIEWPORT IS DRAWN.
                                //
                                // Qt Quick renders every node the scene holds --
                                // a clip cuts the pixels, it does not skip the
                                // work -- so a list of 240 rows is drawn 240
                                // rows deep on every frame the popup paints,
                                // with sixteen of them on screen. Measured at
                                // 60 fps: 7.6 % of a thread at 24 rows, 21.1 %
                                // at 96, 50.6 % at 240 -- 0.2 points per row,
                                // flat, whether or not the reader can see it.
                                // It is only paid while something else on the
                                // popup is moving, and while the record turns
                                // it is paid sixty times a second.
                                //
                                // The row still EXISTS off screen -- its height
                                // holds the list's extent, its state carries the
                                // wave, and it is one property away from being
                                // drawn again -- so nothing about the list's
                                // arithmetic changes. The pad either side is two
                                // rows, so a row is drawn before it can be
                                // looked at rather than in the frame it is
                                // needed.
                                visible: !root._culling
                                         || (wrap.y + wrap.height > root._cullTop
                                             && wrap.y < root._cullBottom)
                                coverNear: root._coverNearRow(wrap.model.index, wrap.model)
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.leftMargin: root._leftInset(wrap.model.kind, wrap.model.depth)
                                anchors.rightMargin: root._rightInset(wrap.model.kind)
                                kind: wrap.model.kind
                                grouping: wrap.model.grouping
                                isList: wrap.model.isList
                                depth: wrap.model.depth
                                inkAbove: wrap.model.inkAbove
                                inkBelow: wrap.model.inkBelow
                                rowKey: wrap.model.key
                                dataKey: wrap.model.dataKey
                                primary: wrap.model.primary
                                secondary: wrap.model.secondary
                                countText: wrap.model.countText
                                cover: wrap.model.cover
                                covers: wrap.model.covers
                                genre: wrap.model.genre
                                uri: wrap.model.uri
                                track: wrap.model.track
                                numbered: wrap.model.numbered
                                dur: wrap.model.dur
                                removable: wrap.model.removable
                                removeKey: wrap.model.removeKey
                            }
                        }
                    }
                }

                // THE LAST ROW'S AIR, the queue's `rowFootAir` in the queue's
                // own place: the foot of the Column, so it is the ROW's air
                // rather than padding on the box (a box padded at the foot
                // would be padded at the head too, where the first header has
                // to meet the container's corners). The queue's list can only
                // end on a song and its spacer is unconditional; this one can
                // end on a header, whose BOX is meant to meet the edge, so it
                // asks -- which is the question its own comment says a list
                // like this one would have to ask.
                Item {
                    id: footAir
                    width: content.width
                    height: root._footAir
                }
            }
        }

        // THE WHEEL, in the shell's feel (modules/common/scroll): a notch glides, a
        // touchpad follows the fingers and coasts after its lift. A MouseArea laid OVER
        // the viewport that takes no button and no hover (a WheelHandler never hears the
        // lift or a purely sideways event). `scrollSpeed` multiplies the feel's own speed.
        // The reader's hand wins: a follow the panel started for itself gets out of the
        // way the moment it is scrolled against.
        KineticScroll {
            id: scrollEngine
            flick: flick
            speed: root.scrollSpeed * ScrollFeel.speed
        }
        WheelArea {
            anchors.fill: flick
            enabled: !root.pageOpen
            turned: wheel => {
                followAnim.stop();
                scrollEngine.feed(wheel.pixelDelta.y, wheel.angleDelta.y, wheel.phase);
                wheel.accepted = true;
            }
        }

        CarvedListDressing {
            flick: flick
            boxColor: root.listBoxColor
            surfaceColor: root.surfaceColor
            bevelColor: root.bevelColor
            radius: root.containerRadius
            bevelWidth: 1
            // A page lies on the box itself: no fade may lie over its carve.
            fadeHeight: pageStack.listF > 0 ? root.listFadeHeight : 0
        }

        // The silhouette while the database query is out. Its geometry is the
        // real rows', at the same scale, so the two lists are one list
        // resolving rather than two lists swapping.
        ListSkeleton {
            id: skeleton
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            visible: root._skeletonAlive && !root.pageOpen
            listScale: root._s
            compact: root.compact
            headerPadV: root._boxPadV
            titleLineH: fmTitle.height
            subLineH: fmSub.height
            headerHeight: root._groupRowH - root._bottomGap
            headerGap: root._bottomGap
            sectionGap: root._vSpacing
            rowHeight: root._songPitch
            rowInnerTop: root.songVPad * root._s
            rowVPad: root.songVPad * root._s
            nameLineH: fmTitle.height
            versionLineH: 0
            rowInset: (root.rowInset + root.songInsetExtra) * root._s
            containerRadius: root.containerRadius
            // The silhouette's header blocks are the real header boxes, and
            // a header box's radius is the container's.
            headerRadius: root.containerRadius
            boxColor: root.headerBoxColor
            // Two tones only, and a bar is always the OTHER one: bars inside
            // a header box take the list's tone, bars lying on the list take
            // the box's.
            barColor: root.listBoxColor
            rowBarColor: root.headerBoxColor
        }

        Text {
            id: emptyLabel
            anchors.centerIn: parent
            // While the daemon itself is the fault (MpdHealth kind mpd-*), an empty list is
            // not "nothing here": say what the sound-health banner says.
            readonly property string _mpdFault: root.player && root.player.health && root.player.health.shown === true
                && String(root.player.health.kind || "").indexOf("mpd-") === 0 ? String(root.player.health.title || "") : ""
            text: emptyLabel._mpdFault !== "" ? emptyLabel._mpdFault
                : root.searching ? "No match" : root.grouping === "playlists" ? "No playlists" : "Nothing here"
            color: root.faintColor
            font.family: root.fontFamily
            font.pixelSize: root.subtitleSize * root._s
            opacity: !root.loading && !root._skeletonAlive && rowModel.count === 0 && !root.pageOpen ? 1 : 0
            visible: emptyLabel.opacity > 0
            Behavior on opacity { NumberAnimation { duration: 160 } }
        }
    }

    PlayerPageStack {
        id: pageStack
        anchors.fill: box
        player: root.player
        albums: root.albums
        artists: root.artists
        currentFile: root.currentFile
        playing: root.playing
        listTile: t => root._listTile(t)
        listLabel: root._listLabel
        rowFace: rowFace
        morphMs: root.pageMorphMs
        swipeBackUnits: root.swipeBackUnits
        swipeBackSign: root.swipeBackSign
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
        accentHoverColor: root.accentHoverColor
        accentBevelColor: root.accentBevelColor
        textOnAccentColor: root.textOnAccentColor
        buttonPlateauColor: root.buttonPlateauColor
        buttonPlateauHoverColor: root.buttonPlateauHoverColor
        buttonBevelColor: root.buttonBevelColor
        buttonShadowColor: root.buttonShadowColor
        onAlbumAsked: (albumArtist, album) => root.albumPageRequested(albumArtist, album)
        onSongClicked: uri => root.playSongRequested(uri)
        onSongMenuRequested: (uri, sx, sy) => root._openMenuAt({ what: "song", uri: uri, a: "", b: "", sx: sx, sy: sy, tile: { where: "page", kind: "song", a: uri, b: "" }, onPage: pageStack.pageEntry.kind }, sx, sy)
        onAlbumMenuRequested: (aa, al, sx, sy) => root._openMenuAt({ what: "album", uri: "", a: aa, b: al, sx: sx, sy: sy, tile: { where: "page", kind: "album", a: aa, b: al } }, sx, sy)
        onWholeRequested: (what, e, cx, cy) => root._pageWhole(what, e, cx, cy)
        onSongAction: (action, song) => root.songActionRequested(action, song)
        onReturnTaken: ret => root.returnTaken(ret)
    }
    // A list row's face on the card: the row, drawn again without its box (the card is the box).
    Component {
        id: rowFace
        LibraryRow {
            readonly property var f: pageStack.cardFacts || ({})
            interactive: false
            boxless: true
            kind: f.kind || "group"
            grouping: f.grouping || ""
            isList: f.isList === true
            depth: f.depth || 0
            rowKey: f.rowKey || ""
            dataKey: f.dataKey || ""
            primary: f.primary || ""
            secondary: f.secondary || ""
            countText: f.countText || ""
            cover: f.cover || ""
            covers: f.covers || ""
            genre: f.genre || ""
            uri: f.uri || ""
            track: f.track || 0
            numbered: f.numbered === true
            dur: f.dur || 0
        }
    }
    // Play / Play next / Add to queue for the whole page.
    function _pageWhole(what, e, cx, cy) {
        const isAlbum = e.kind === "album";
        if (what === "play") {
            if (isAlbum) root.playAlbumRequested(e.a, e.b); else root.actionRequested("play", "artist", e.a, "");
        } else if (what === "next") {
            root.actionRequested("next", isAlbum ? "album" : "artist", e.a, e.b);
        } else {
            if (isAlbum) root.queueAlbumRequested(e.a, e.b); else root.queueGroupRequested("artist", e.a);
        }
        if (what !== "play") root.queuedFeedback(cx, cy, isAlbum ? "album" : "artist");
    }

    // A REFRESH IS NOT A FIRST LOAD. The silhouette and the blank list under
    // it are for a panel that has nothing to show; a shelf being fetched
    // AGAIN -- the source changed, the daemon rescanned -- already has its
    // rows on screen, and blanking them to draw a silhouette of the very
    // rows that are standing there is a flicker. The rows stay, and the
    // fetch's answer is diffed into them.
    // OWNED BY THE HANDLER, never bound to `loading`. A binding raises the
    // silhouette for every fetch, refresh included, which is exactly what
    // the handler below is written to refuse.
    property bool _skeletonAlive: false
    onLoadingChanged: {
        if (root.loading) {
            if (rowModel.count > 0) return;
            skeleton.reset();
            root._skeletonAlive = true;
            skeletonOff.stop();
        } else {
            // The answer has landed (or there was none). Either way the list
            // is free to take a target it held off on while the fetch was
            // out -- an empty one included, which is how a source with no
            // library at all still empties the panel.
            root._scheduleRebuild();
            if (!root._skeletonAlive) return;
            skeleton.resolve(rowModel.count);
            skeletonOff.restart();
        }
    }
    Timer {
        id: skeletonOff
        interval: skeleton.fadeMs + skeleton.collapseMs + 40
        repeat: false
        onTriggered: root._skeletonAlive = false
    }

    // =====================================================================
    //  ONE ROW
    //
    //  A group:  [cover]  Album                    12 songs  [x]  v
    //                     Album artist
    //  A song:   3  Title                                  3:47  [x]
    //  A seam:   ------------------------------------------------
    //
    //  One component for all of them, because a song row is a group row with
    //  its box, its icon and its chevron taken away — and those are behind a
    //  Loader, so a song row does not pay for a ShaderEffect it never draws.
    // =====================================================================
    component LibraryRow: Item {
        id: lrow

        property string kind: "group"       // group | album | song | separator
        // The grouping this row was BUILT in — never root.grouping, which is
        // the panel's current one and has already moved on while the row is
        // leaving. Everything a row draws or means is read from here.
        property string grouping: root.grouping
        // A row of a run that came from a LIST rather than an album: the
        // header wears the list's name, its pictures and the lists tab's hue
        // and gives up its second line, and its songs carry their artists --
        // the lists tab's own row, drawn in recently played.
        property bool isList: false
        property int depth: 0
        // A separator's own geometry: what the ink above and below it leaves
        // clear inside its slot, which is what says where the line sits and
        // how tall its slot has to be. Zero on every other kind.
        property real inkAbove: 0
        property real inkBelow: 0
        property string rowKey: ""
        property string dataKey: ""
        property string primary: ""
        property string secondary: ""
        property string countText: ""
        property string cover: ""
        // WHETHER THE ROW IS NEAR THE READER (the host's answer), and the latch it feeds: a row asks
        // for its pictures from the first moment it has been near and never takes the ask back. Every
        // asynchronous Image shares ONE reader thread that reads the pictures queued last first, so
        // a list that asked for all of its fifty rows' covers at once reads the ones nobody can see
        // BEFORE the ones on screen (measured: the viewport's ten covers are the last ten of fifty-two
        // to land, 3.2 s after the open). The rows beyond a screen of the viewport ask when a scroll
        // brings them within one.
        property bool coverNear: true
        property bool _coverAsked: false
        onCoverNearChanged: if (lrow.coverNear) lrow._coverAsked = true
        Component.onCompleted: if (lrow.coverNear) lrow._coverAsked = true
        // A list's pictures, joined by the unit separator. Empty everywhere
        // else, where the row's own `cover` is the whole answer.
        property string covers: ""
        property string genre: ""
        property string uri: ""
        property int track: 0
        // Whether this song row wears a number at all. False on a standalone
        // song in recently played, which is the nth of nothing; and the slot
        // goes with the number, so nothing reserves width for a figure that
        // is never drawn.
        property bool numbered: true
        property real dur: 0
        property bool removable: false
        // What `removeRecentRequested` hands back for this row: the source's
        // own key for the entry, so the service can find the entry it named
        // rather than guess from a name it did not write.
        property string removeKey: ""
        property bool interactive: true
        // A header without its box: a morph's card is the box.
        property bool boxless: false

        readonly property bool isHeader: lrow.kind === "group" || lrow.kind === "album"
        readonly property bool isSong: lrow.kind === "song"
        // The song the player is on, wherever in the library it turns up.
        readonly property bool isCurrent:
            lrow.isSong && root.currentFile !== "" && lrow.uri === root.currentFile
        // Eased 0 -> 1 as the music starts and stops: one fraction, and the
        // two themed colours mixed with it. A Behavior on the colour itself
        // would be a second clock under the theme's.
        property real _playF: lrow.isCurrent && root.playing ? 1 : 0
        Behavior on _playF {
            NumberAnimation { duration: root.rowAnimDuration; easing.type: Easing.OutCubic }
        }
        // The places nothing else on screen says who is playing: a song in a
        // list, wherever the list is drawn -- its own tab or a run of it in
        // recently played -- and a standalone song there (depth 0). A song
        // under an ALBUM's header is not one of them: its header says it.
        readonly property bool showArtist:
            lrow.isSong && lrow.secondary.length > 0
            && (lrow.grouping === "playlists" || lrow.isList
                || (lrow.grouping === "recent" && lrow.depth === 0)
                || (lrow.depth === 0 && lrow.rowKey.indexOf("hit" + root.keySeparator) === 0))

        implicitHeight: root._rowH(lrow)

        readonly property bool _open: lrow.isHeader && root._isExpanded(lrow.rowKey)
        // What the icon slot holds. An album shows its cover wherever it
        // appears; an artist gets the same slot with a person in it when there
        // is no picture; a genre gets a mark, since it has no picture there
        // could ever be one of.
        readonly property string _icon:
              lrow.kind === "album" ? "cover"
            : lrow.kind !== "group" ? ""
            : (lrow.grouping === "albums" || lrow.grouping === "recent"
               || lrow.grouping === "artists"
               || lrow.grouping === "playlists") ? "cover"
            : lrow.grouping === "genres" ? "glyph"
            : ""
        readonly property string _fallbackGlyph:
            lrow.grouping === "artists" && lrow.kind === "group"
                ? "\uF007" : "\uF001"
        // Artists, genres and lists never have a second line -- there is
        // nothing a list could put there, and a title laid out as the first of
        // two lines with nothing under it reads as a subtitle that failed to
        // load. So their one line sits in the middle of the box.
        readonly property bool _oneLine:
            lrow.kind === "group"
            && (lrow.isList || lrow.grouping === "artists"
                || lrow.grouping === "genres" || lrow.grouping === "playlists")
        // Playlists have nothing to take a genre from and keep a hue of their
        // own; everything else wears its genre's.
        readonly property color _hue:
            (lrow.kind === "group"
             && (lrow.isList || lrow.grouping === "playlists"))
                ? root.playlistsColor : root.genreColor(lrow.genre)

        // The pictures this row's slot can show, decided ONCE: a list's own
        // (up to four, de-duplicated) or, where it has none, the single cover
        // the row carries. Empty urls and ones the memo has written off are
        // gone before the slot ever sees them, so the slot never has to ask
        // whether a picture it is showing exists.
        readonly property var coverUrls: {
            const out = [];
            const raw = lrow.covers === "" ? []
                                           : lrow.covers.split(root.keySeparator);
            for (let i = 0; i < raw.length && out.length < 4; i++) {
                const u = root._coverSource(raw[i]);
                if (u !== "" && out.indexOf(u) < 0) out.push(u);
            }
            if (out.length === 0) {
                const c = root._coverSource(lrow.cover);
                if (c !== "") out.push(c);
            }
            return out;
        }

        readonly property real _removeW:
            lrow.removable ? root._removeSlot + root.rowGap * root._s : 0
        // The queue's own arithmetic: the artist takes at most a share of the
        // row so a long one cannot squeeze the title away, and it is MEASURED
        // through FontMetrics rather than read back off the Text that draws
        // it. The gap between it and the duration's slot is already in
        // `_textRight`; this is the one between it and the title.
        readonly property real _artistW: lrow.showArtist
            ? Math.min(fmSub.advanceWidth(lrow.secondary),
                       Math.max(0, (lrow.width - lrow._textLeft
                                    - lrow._textRight) * 0.45))
            : 0
        readonly property real _artistBlock:
            lrow.showArtist ? lrow._artistW + root.rowGap * root._s : 0
        // The stripe's slot, reserved on every song row exactly as the queue
        // reserves it, and one gap before the number as there.
        readonly property real _stripeSlot:
            (root.stripeWidth + root.rowGap) * root._s
        readonly property real _numberSlot:
            lrow.numbered ? root._trackSlot + root.rowGap * root._s : 0
        readonly property real _textLeft: lrow.isHeader
            ? root._boxPad + (lrow._icon !== "" ? root._coverSize + root.rowGap * root._s : 0)
            : lrow._stripeSlot + lrow._numberSlot
        readonly property real _textRight: lrow.isHeader
            ? root._boxPad + root._countSlot + root.rowGap * root._s
              + lrow._removeW + root.chevronSize * root._s
            : root._durSlot + root.rowGap * root._s + lrow._removeW
        readonly property real _boxH: lrow.implicitHeight - root._bottomGap
        // Where the marks on a header stack up, from the right edge inwards.
        readonly property real _chevronRight: root._boxPad
        readonly property real _removeRight:
            lrow.isHeader ? lrow._chevronRight + root.chevronSize * root._s : 0

        // 0 -> 1 while the group is open, one clock for the chevron.
        property real _openF: lrow._open ? 1 : 0
        Behavior on _openF {
            NumberAnimation { duration: 200; easing.type: Easing.InOutCubic }
        }

        function _queueKind() {
            if (lrow.kind === "album") return "album";
            if (lrow.kind === "song") return "song";
            // A run from a list goes back in as the list it came from,
            // wherever the row is drawn.
            if (lrow.isList) return "playlist";
            if (lrow.grouping === "albums" || lrow.grouping === "recent") return "album";
            return root._kindOf(lrow.grouping);
        }
        // The centre of what was clicked, in scene coordinates, so the host can
        // throw its particles from the row itself.
        function _feedback(what) {
            const p = lrow.mapToItem(null, lrow.width / 2,
                (lrow.isHeader ? lrow._boxH : lrow.implicitHeight) / 2);
            root.queuedFeedback(p.x, p.y, what);
        }
        function _queue() {
            const what = lrow._queueKind();
            if (what === "song") {
                root.queueSongRequested(lrow.uri);
            } else if (what === "album") {
                const parts = lrow.dataKey.split(root.keySeparator);
                root.queueAlbumRequested(parts[0] || "", parts[1] || "");
            } else {
                root.queueGroupRequested(what, lrow.dataKey);
            }
            lrow._feedback(what);
        }

        // Left opens a group or plays a song; right opens its menu (play, play next, add to the queue, its page).
        // No hover wash: the pointing hand is the affordance, exactly as in
        // the update's list.
        //
        // DECLARED FIRST, so everything below it -- the cover in particular --
        // sits ABOVE it and is offered the press first. Sitting last, it
        // would cover the cover's own area completely and clicking the
        // picture would open the album instead of playing it.
        MouseArea {
            id: rowArea
            anchors.fill: parent
            enabled: lrow.interactive && lrow.kind !== "separator"
            hoverEnabled: lrow.removable
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            onClicked: (mouse) => {
                if (mouse.button === Qt.RightButton) {
                    root._openRowMenu(lrow, mouse);
                    return;
                }
                if (lrow.isHeader) {
                    root._toggleGroup(lrow.rowKey,
                        lrow.kind === "album" ? "album"
                        : lrow.grouping === "recent" ? "recentAlbum"
                        : root._kindOf(lrow.grouping),
                        lrow.dataKey);
                } else {
                    root.playSongRequested(lrow.uri);
                }
            }
        }

        // The seam between a run and a standalone song. Placed from the ink
        // either side of it rather than centred in its own slot -- the slot is
        // the asymmetry, not the answer. See THE SEAM at the head of the file.
        Rectangle {
            id: seam
            visible: lrow.kind === "separator"
            anchors.left: parent.left
            anchors.right: parent.right
            y: root._seamY(lrow)
            height: root._lineH
            color: root.borderColor
        }

        Loader {
            id: dress
            active: lrow.isHeader
            anchors.fill: parent
            sourceComponent: Item {
                ShadowBox {
                    id: headBox
                    visible: !lrow.boxless
                    anchors.fill: parent
                    anchors.bottomMargin: root._bottomGap
                    // The container's radius, on every corner: the ones that
                    // meet the container's have to coincide with it and the
                    // rest may not differ from those. ShadowBox multiplies
                    // every radius by sizeScale, so it is handed over
                    // pre-divided by the list scale or it is drawn that much
                    // too large -- the container's number is the host's, not
                    // the row scale's.
                    baseRadius: root.containerRadius / root._s
                    sizeScale: root._s
                    surfaceColor: root.listBoxColor
                    backgroundColor: root.headerBoxColor
                    bevelColor: root.headerBoxBevelColor
                    shadowColor: root.headerBoxShadowColor
                    bevelWidth: root.headerBevelWidth
                    shadowWidth: root.headerShadowWidth
                    // The genre's hue, as a constant sliver inside the left
                    // edge of the inset and nowhere else.
                    shadowProgress: 0
                    shadowProgressColor: lrow._hue
                    shadowProgressMinPx: root.headerGlowWidth
                    progressIdleFeatherPx: root.headerGlowFeather
                    // The mark at full strength in the header's own carve,
                    // not ShadowBox's parked hint (0.55, 7.5 px, falloff 0.9),
                    // which is for a mark that progress will take over. This
                    // one never moves.
                    progressIdleWidth: root.headerShadowWidth
                    progressIdleEdgeAlpha: 1
                    progressIdleFalloff: 1
                }

                // The cover IS the play button: nothing announces it but the
                // pointer. A glyph beside it would be a second mark for an
                // action the picture already stands for.
                Item {
                    id: coverSlot
                    // READY WITH AN EMPTY SOURCE IS NOT A COVER, and the status
                    // alone cannot say so. When the memo clears the source of
                    // an album whose first row has just failed, the rows of the
                    // same album whose request is still in flight land at
                    // Image.Ready with nothing in them: an Image that paints
                    // nothing, over a glyph that the same status has just
                    // hidden, so eleven of twelve rows sharing one missing
                    // cover end as a blank square. The slot decides once, from
                    // the source as well as the status, and both children read
                    // that one answer.
                    // FOUR PICTURES OR ONE, and never a grid with a hole in
                    // it: the count is of the urls that are usable, so three
                    // covers (or four of which one has just failed) is one
                    // picture.
                    readonly property bool _grid: lrow.coverUrls.length >= 4
                    readonly property real _half: Math.round(coverSlot.width / 2)
                    readonly property bool _hasCover:
                        coverSlot._grid
                        || (coverImage.status === Image.Ready
                            && String(coverImage.source) !== "")

                    visible: lrow._icon === "cover"
                    x: root._boxPad
                    y: (lrow._boxH - coverSlot.height) / 2
                    width: root._coverSize
                    height: root._coverSize
                    clip: true

                    Rectangle {
                        anchors.fill: parent
                        radius: root.coverRadius * root._s
                        color: root.listBoxColor
                    }
                    Image {
                        id: coverImage
                        anchors.fill: parent
                        // Never asked for a path that is empty or that has
                        // already failed once: an Image pointed at a file that
                        // is not there warns on stderr, and the same album
                        // appears in its own tab, under its genre and in
                        // recently played. `_src` is the string that was
                        // ASKED for, which is what the memo is keyed by -- an
                        // Image's own `source` comes back resolved and would
                        // never match it.
                        readonly property string _src:
                            (!coverSlot._grid && lrow.coverUrls.length > 0)
                                ? lrow.coverUrls[0] : ""
                        source: root.coversEnabled && lrow._coverAsked ? coverImage._src : ""
                        onStatusChanged: {
                            if (coverImage.status === Image.Error)
                                root._noteMissingCover(coverImage._src);
                        }
                        visible: !coverSlot._grid && coverSlot._hasCover
                        // A cover APPEARS when it is decoded, by a short fade of its presence:
                        // never a square that pops in under the pointer. One already decoded (the
                        // cache) is at 1 from its first frame.
                        opacity: coverImage.status === Image.Ready ? 1 : 0
                        Behavior on opacity {
                            NumberAnimation { duration: root.coverFadeMs; easing.type: Easing.OutCubic }
                        }
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: true
                        // twice the slot, and as much as the glass shows when that is more (constant under layout)
                        sourceSize.width: Math.round(root._coverSize * Math.max(2, dev.value))
                        sourceSize.height: Math.round(root._coverSize * Math.max(2, dev.value))
                    }
                    // The 2 x 2. Whole-pixel halves that add back up to the
                    // slot, so the four meet on one line and none of them is
                    // half a pixel short of the edge the corner is cut on.
                    Repeater {
                        model: coverSlot._grid ? 4 : 0
                        delegate: Image {
                            id: cell
                            required property int index
                            readonly property string _src:
                                lrow.coverUrls[cell.index] !== undefined
                                    ? lrow.coverUrls[cell.index] : ""
                            x: (cell.index % 2) === 0 ? 0 : coverSlot._half
                            y: cell.index < 2 ? 0 : coverSlot._half
                            width: (cell.index % 2) === 0
                                ? coverSlot._half : coverSlot.width - coverSlot._half
                            height: cell.index < 2
                                ? coverSlot._half : coverSlot.height - coverSlot._half
                            source: root.coversEnabled && lrow._coverAsked ? cell._src : ""
                            opacity: cell.status === Image.Ready ? 1 : 0
                            Behavior on opacity {
                                NumberAnimation { duration: root.coverFadeMs; easing.type: Easing.OutCubic }
                            }
                            onStatusChanged: {
                                if (cell.status === Image.Error)
                                    root._noteMissingCover(cell._src);
                            }
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            cache: true
                            // a cell is half the slot: twice the cell, and as much as the glass shows when that is more
                            sourceSize.width: Math.round(root._coverSize / 2 * Math.max(2, dev.value))
                            sourceSize.height: Math.round(root._coverSize / 2 * Math.max(2, dev.value))
                        }
                    }
                    Text {
                        anchors.centerIn: parent
                        visible: !coverSlot._hasCover
                        text: lrow._fallbackGlyph
                        font.family: "Symbols Nerd Font"
                        font.pixelSize: root._coverSize * 0.5
                        color: root.faintColor
                    }
                    // The rounded corner, cut by painting the ground back over
                    // it: the same trick the list box's dressing uses, at
                    // thumbnail scale. A Rectangle's `clip` is its bounding
                    // box, not its rounded shape.
                    Rectangle {
                        id: coverCut
                        readonly property real _cap: root.coverRadius * root._s
                        anchors.fill: parent
                        anchors.margins: -coverCut._cap
                        color: "transparent"
                        radius: root.coverRadius * root._s + coverCut._cap
                        border.width: coverCut._cap
                        border.color: root.headerBoxColor
                        antialiasing: true
                    }
                    MouseArea {
                        anchors.fill: parent
                        enabled: lrow.interactive && lrow.dataKey !== ""
                                 && lrow._queueKind() === "album"
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            const parts = lrow.dataKey.split(root.keySeparator);
                            root.playAlbumRequested(parts[0] || "", parts[1] || "");
                        }
                    }
                }

                // A genre has no cover, so its slot holds a mark instead --
                // muted ink, never the genre's own colour: that colour is
                // already in the inset, and one fact gets one mark.
                Text {
                    id: genreMark
                    visible: lrow._icon === "glyph"
                    x: root._boxPad + (root._coverSize - genreMark.width) / 2
                    y: (lrow._boxH - genreMark.height) / 2
                    text: root.genreGlyph(lrow.genre)
                    font.family: "Symbols Nerd Font"
                    font.pixelSize: root._coverSize * 0.55
                    color: root.mutedColor
                }

                Text {
                    id: countLabel
                    visible: lrow.countText.length > 0
                    x: lrow.width - lrow._removeRight - lrow._removeW
                       - root.rowGap * root._s - countLabel.width
                    width: root._countSlot
                    y: (lrow._boxH - countLabel.height) / 2
                    horizontalAlignment: Text.AlignRight
                    text: lrow.countText
                    color: root.faintColor
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize * root._s
                }

                // The chevron, on ListSectionHeader's geometry: the item is the
                // mark's own footprint rounded out to whole pixels at a
                // whole-pixel position, so both round caps take the same
                // fraction of their outer pixel and neither reads as cut.
                Item {
                    id: chevron
                    readonly property real _arm: root.chevronSize * root._s * 0.46
                    readonly property real _thick: Math.max(1.5, 2 * root._s)
                    readonly property real _reach: Math.max(0, chevron._arm - chevron._thick) * 0.7071
                    readonly property real _capReach:
                        Math.max(0, chevron._arm - chevron._thick) / 2 * 0.7071 + chevron._thick / 2
                    width: Math.ceil(chevron._reach + chevron._capReach * 2)
                    height: Math.ceil(chevron._capReach * 2)
                    x: Math.round(lrow.width - lrow._chevronRight - chevron.width)
                    y: Math.round((lrow._boxH - chevron.height) / 2)
                    transformOrigin: Item.Center
                    rotation: lrow._openF * 180

                    Rectangle {
                        id: armA
                        width: chevron._arm
                        height: chevron._thick
                        radius: armA.height / 2
                        color: root.mutedColor
                        x: chevron.width / 2 - chevron._reach / 2 - armA.width / 2
                        y: chevron.height / 2 - armA.height / 2
                        rotation: 45
                    }
                    Rectangle {
                        id: armB
                        width: chevron._arm
                        height: chevron._thick
                        radius: armB.height / 2
                        color: root.mutedColor
                        x: chevron.width / 2 + chevron._reach / 2 - armB.width / 2
                        y: chevron.height / 2 - armB.height / 2
                        rotation: -45
                    }
                }
            }
        }

        // The playing mark, and the only one: the queue's stripe, on the
        // queue's own geometry.
        Rectangle {
            id: stripe
            visible: lrow.isCurrent
            x: 0
            y: root.songVPad * root._s
            width: root.stripeWidth * root._s
            height: Math.max(0, lrow.implicitHeight - root.songVPad * 2 * root._s)
            radius: stripe.width / 2
            color: Mix.c(root._drainedStripe, root.accentColor, lrow._playF)
        }

        // The track number, on a song row only.
        Text {
            id: trackLabel
            visible: lrow.isSong && lrow.numbered && lrow.track > 0
            x: lrow._stripeSlot
            width: root._trackSlot
            y: (lrow.implicitHeight - trackLabel.height) / 2
            horizontalAlignment: Text.AlignRight
            text: String(lrow.track)
            color: root.faintColor
            font.family: root.fontFamily
            font.pixelSize: root.figureSize * root._s
        }

        Text {
            id: primaryText
            visible: lrow.kind !== "separator"
            x: lrow._textLeft
            y: lrow.isHeader
                ? (lrow._oneLine
                    ? (lrow._boxH - primaryText.height) / 2
                    : (lrow._boxH - root._groupTextH) / 2)
                : (lrow.implicitHeight - primaryText.height) / 2
            width: Math.max(0, lrow.width - lrow._textLeft - lrow._textRight
                               - lrow._artistBlock)
            elide: Text.ElideRight
            text: lrow.primary
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: root.titleSize * root._s
        }

        // The header's second line, and the song row's artist: one Text,
        // because they are one fact drawn in the one colour at the one size,
        // in the two places the row can put it.
        Text {
            id: secondaryText
            visible: lrow.secondary.length > 0
                     && ((lrow.isHeader && !lrow._oneLine) || lrow.showArtist)
            x: lrow.showArtist
                ? lrow.width - lrow._textRight - lrow._artistW
                : lrow._textLeft
            // On the title's own line, centred against it: the queue's line,
            // and Inter's subtitle size is shorter than its title size.
            y: lrow.showArtist
                ? primaryText.y + (fmTitle.height - fmSub.height) / 2
                : primaryText.y + fmTitle.height
            width: lrow.showArtist ? lrow._artistW : primaryText.width
            elide: Text.ElideRight
            text: lrow.secondary
            color: root.mutedColor
            font.family: root.fontFamily
            font.pixelSize: root.subtitleSize * root._s
        }

        Text {
            id: durLabel
            visible: lrow.isSong && lrow.dur > 0
            x: lrow.width - lrow._removeW - root._durSlot
            width: root._durSlot
            y: (lrow.implicitHeight - durLabel.height) / 2
            horizontalAlignment: Text.AlignRight
            text: Bytes.formatEta(lrow.dur)
            color: root.faintColor
            font.family: root.fontFamily
            font.pixelSize: root.figureSize * root._s
        }

        // Pruning recently played. The one glyph on the row, and it is not
        // there until the pointer is; its slot is reserved at all times, so
        // nothing shifts when it fades.
        Item {
            id: removeSlot
            visible: lrow.removable && removeSlot.opacity > 0
            x: lrow.width - lrow._removeRight - root._removeSlot
            y: lrow.isHeader ? (lrow._boxH - removeSlot.height) / 2
                             : (lrow.implicitHeight - removeSlot.height) / 2
            width: root._removeSlot
            height: root._removeSlot
            opacity: lrow.interactive && (rowArea.containsMouse || removeArea.containsMouse)
                     ? 1 : 0
            // Presence fades; nothing else about the row moves. The queue's
            // identical mark is on this same 160, and a mark that pops reads
            // as a second element appearing rather than as the row answering
            // the pointer.
            Behavior on opacity { NumberAnimation { duration: 160 } }

            Text {
                anchors.centerIn: parent
                text: "\uF00D"
                font.family: "Symbols Nerd Font"
                font.pixelSize: root.figureSize * root._s
                color: removeArea.containsMouse ? root.textColor : root.faintColor
            }
            MouseArea {
                id: removeArea
                anchors.fill: parent
                enabled: lrow.interactive && lrow.removable
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.removeRecentRequested(
                    lrow.isHeader ? "album" : "song", lrow.removeKey)
            }
        }
    }
}
