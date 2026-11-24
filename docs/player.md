# player -- the music player

## What it is
A record player for the music mpd plays: the bar shows a small disc, the popup shows the current album's record turning on a platter at the
speed of the music, a scrub bar whose ball is the playhead, the transport and, beside it, the queue, the library and the track's own data.
It is a front end for mpd, the daemon that keeps the queue and plays the sound; the popup can come and go and the music goes on.

## Where it lives
- Bar: the right island of the top bar, module id `player` (first). The icon is an album disc: its own colour (magenta) while playing,
  the muted ink otherwise. When a new track starts during playback, and when the pointer comes onto it, the disc winds up and spins out once with a few faint
  motion lines. Click opens and
  closes the popup; a right click plays or pauses, with no popup (the bar's quick action, as the theme's mode and the bell's do not
  disturb are theirs).
- Popup: two views and a sidebar. `mini` (480 px wide, the record small beside the title, the scrub bar under it) and `player` (560 px, the
  record at full size) with the sidebar out (400 px more) showing the queue, the library or the data. The view and the sidebar's panel are
  remembered between opens. The popup asks for the keyboard only while the pointer, having moved onto it, is over it.
- No global shortcut and no IPC verb. The now-playing card the OSD shows and the lock screen's media strip read the same player.

## What you can do
- Transport row: shuffle, previous, play or pause, next, repeat (off, all, one); the burger at the right opens the sidebar (from `mini` it
  opens the full player with the sidebar); the toggle at the left switches `mini` and `player`.
- Scrub: drag the ball on the groove to seek; the record winds with the hand. Sparks follow the music's loudness.
  Opening the popup on a playing track throws no sparks: the open's own corrections of the position (the clock's catch-up, the status read's
  re-seat) are a grace in the scrub bar (`openGraceMs`, `openGraceQuietMs`, `openGraceMaxMs`), not seeks. Check: `tools/dev/viewfinder_open_probe.sh`.
- Space plays or pauses while the pointer is over the popup. Typing anywhere in the popup searches the library (the first letter brings
  the library out); Backspace edits and Enter opens the first hit.
- Queue panel: the songs in order, the playing one marked; click plays a song; drag a row to move it; the cross at a row's end removes it;
  right click: Play now, Play next, Remove from queue, Song details, Show album, Go to artist; "Clear" empties the queue.
- Library panel: one list with five groupings, Albums, Artists, Genres, Recent and Lists (playlists), each sortable (artist, title, year,
  length, songs and so on, in either direction). A click on a header (an album, an artist, a genre, a list) opens it in place to its songs
  and a click on a song plays it. Right click a row for Play, Play next, Add to queue, Open album / artist and Song details; "Open" brings
  the album's or artist's page (cover, title, "<year> · <genre>", songs and length, the files' format, Play / Play next / Add to queue, the
  songs by disc and track) out of the row like a note; a two-finger sideways swipe goes back, and a click on the cover shows it large. "Lists" are `~/Music/Tracks` shown as "Favorites" and one list per directory of `~/Music/Playlists`. Artists has a
  switch for counting the loose songs in; Recent has "Clear" and a cross per row.
- Data panel: what the file says about the playing track (or the head of the queue): identity, figures, the lyrics (followed line by line
  when the file carries timed lyrics, and a click on a line seeks to it; shown as a block when untimed; one sentence when there are none) and the other tags (BPM, key,
  release type...).
- Song details sheet: everything known about one song, from the daemon, from the file (the average bitrate, size, path) and from its tags.
- The record is put on the platter per album: a new album slides in out of its sleeve, the same album does not animate between songs, the
  record flips at the middle of an album, and at the end it is flung back into its sleeve. A play pressed on a stopped player waits until
  the record is down.
- A chip in the title block reads the file's format (`24-BIT 96kHZ FLAC`, `320kBPS 44.1kHZ AAC`), inked by its quality tier.

## What it shows and where the data comes from
| Part | Source |
|---|---|
| Queue, status, current song, the library, playlists, when each song was last played (an mpd sticker) | mpd, over the per-user socket `$XDG_RUNTIME_DIR/mpd/socket` (two connections: commands and `idle`); nothing is polled, `idle` pushes |
| Elapsed time | interpolated locally from the last status read, so the record does not jerk; the clock runs only while something shows the time |
| Covers | `cover.jpg`, `cover.png` or `cover.webp` in the song's directory under `~/Music`; a directory of loose songs reads the cover out of the file |
| Lyrics, tags, bitrate | one `ffprobe` per track, only while the Data panel or the song sheet is open |
| Loudness for the sparks | a PipeWire recorder on mpd's own stream, only while the popup is open and music plays |
| The sound's health | mpd's status and `tools/player/audio_diagnose.py` (read-only), only while the popup is open and a problem is shown |
When the sound stops without mpd saying so (a locked USB DAC is the case it names), a strip over the head of the card names the
broken layer in words ("mpd is not running", "No audio output", "Playback failed", "Nothing is playing"), with one button where a button
can help (restart mpd, restart the audio session or server, try again, reopen the output) and "Check again" / "Hide". Nothing is restarted
by looking. A click on the bar opens nothing when the shell has no player service.

## Settings
`~/.config/quickshell/config/player.jsonc` (read hot, the popup's keys at its next open; every key with its words in `.examples/player.jsonc`;
the AirPlay delay is `config/airplay.jsonc`, `docs/audio.md` "Airplay"):

| Key | Meaning | Default |
|---|---|---|
| `open.view` / `sidebar` / `panel` | how the popup first opens: `player` or `mini`, the sidebar out, `queue` / `library` / `data` | `player`, false, `queue` |
| `open.remember` | after the first open the popup comes back as you left it; false: every open is the three above | true |
| `library.grouping` | the library's grouping as the popup opens | `albums` |
| `library.sort` | each grouping's sort as the popup opens (albums `artist`, artists and genres `name`, playlists `order`) | as said |
| `library.ascending` | false: every sort from its far end (the playlists' own order is never turned) | true |
| `library.looseArtists` | the artists shelf lists artists with loose songs only too (put back at each open) | false |
| `autoplay` | something put in an empty queue starts by itself | true |
| `holdForRecord` | an album started on a silence waits for the record to come down | true |
| `prevRestartSec` | Previous this far into a song restarts it; 0: always the song before (the bar's and the media key's too) | 3 |
| `musicSparks` | the viewfinder's sparks follow the music (a recorder while open and playing) | true |
| `shuffle.artistGap` / `albumGap` | the least songs between two of one artist / album | 3 / 2 |
| `paths.*` | read at start: `music` (`~/Music`), its `albums` / `tracks` / `playlists` folders, the `favorites` list's name, the `covers` file names, mpd's `socket` (a local socket; "" `$XDG_RUNTIME_DIR/mpd/socket`) | as said |

`shell.jsonc` `workarounds.mpdResumeSeek` (true) puts the song back where it paused after mpd 0.24's skip on resume (`MpdService.losslessResume`).
`shell.jsonc` places the button and sizes the popup
(`scale.popups.player`). Looks and motion (the vinyl, the sleeve, the particles, the view sizes) are tuned in `mockups/audio_player.qml`
(`quickshell -p ~/.config/quickshell/mockups/audio_player.qml`; Save writes the module); its Run tab drives a mock player with no daemon.

## How it is built
| Path | Role |
|---|---|
| `modules/bar/player/PlayerBarButton.qml`, `PlayerBarOwner.qml` | the disc and its flourish; the bar-side owner (view, sidebar, panel remembered; the popup's open flag) |
| `components/AudioPlayerPopup.qml` | the popup: composition, the two views, the sidebar, the keys, when the record is put on and taken off |
| `components/VinylStage.qml`, `Turntable.qml`, `VinylSleeve.qml`, `VinylParticles.qml`, `ShadowBoxLobe.qml` + `shaders/` | the record, platter, sleeve and their motions; the record's angle is the playback position |
| `components/PlayerViewfinder.qml`, `PlayerLevelTap.qml`, `PlayerTrackInfo.qml`, `PlayerTransport.qml`, `PlayerFidelityChip.qml` | the scrub bar, the loudness reader, title and time slots, the buttons, the format chip |
| `components/PlayerQueue.qml`, `PlayerLibrary.qml`, `PlayerLibraryPage.qml`, `PlayerSongSheet.qml`, `PlayerData.qml`, `PlayerPageStack.qml`, `AudioTags.qml` | the sidebar's panels, the pages that open inside them and the file's tags |
| `components/PlayerHealthBanner.qml`, `PlayerTickHold.qml`, `ClockTimer.qml`, `StaggerClock.qml`, `PlayerFormat.js` | the health strip, the hold on the elapsed clock, the stagger clock, number formats |
| `modules/common/components/MpdService.qml`, `MpdClient.qml`, `MpdHealth.qml`, `MpdHealth.js`, `MpdShuffle.js`, `MpdFidelity.js` | the model and its commands, the two-socket transport, the health reader and its rules, the spread-out shuffle, the fidelity tiers |
| `modules/common/components/PlayerMockRun.qml` | a player with no daemon, seeded from the real library's covers, for mockups and mock shells |
| `tools/player/audio_diagnose.py` | the read-only look at the kernel's process states and `pw-dump` |
Shared parts used: `ShadowBox`, `RaisedButton`, `GrooveTrack`, `SquishItem`, `CarvedListDressing`, `ScrollDressing`/`KineticScroll`,
`AnimatedListRow`, `ListSkeleton`, `MorphCard`/`MorphClock` (the page's open), `SwipeScrub` (back), `TabSelector`, `FloatingMenu`,
`HoverTip`, `AudioArt`, `AudioBitrate`. The service is built once per shell (`ShellServices`: mpd live or the mock) and handed to the
owner, the OSD and the lock.

## Limits
- While mpd plays into an AirPlay speaker the sound lags mpd's facts by the sink's buffer (seconds). Three displays wait for it (`AirplayDelay.delayMs`):
  the track OSD card for a song change that came by itself (a media key's card is the key's own feedback and shows at once), the bar glyph's new-song
  flourish, and the lyrics' active line (`PlayerData`: position minus the delay). The popup's playhead, the vinyl and the scrub stay live: syncing them
  would fight every seek. `docs/audio.md` "Airplay".
- mpd is a user service and must run; the player never starts it. mpd's filter language has no OR, so a library search runs one search per
  tag and merges.
- mpd reports `elapsed` in decoder chunks and skips about 0.8 s of music on every resume; the player re-seats a resume onto the position
  it paused at.
- Cover art is never pulled through the mpd protocol (binary data does not survive Quickshell's line parser): it is derived from the file's
  directory.
- Lyrics are shown only where the file carries them (timed or not): there is no lyrics service and no invented sync.

## How to change it
- The view widths: `miniWidth`, `playerWidth`, `browsePanelWidth` in `AudioPlayerPopup.qml`; the vinyl's look and motion in the mockup's
  tabs (Save).
- Where the music lives or how an album is told from a loose song: `player.jsonc` `paths` (MpdService's `musicDir`, `albumsSubdir`,
  `tracksSubdir`, `playlistsSubdir`, `favoritesName`, `coverNames`).
- The bar disc's flourish (windup, coast, turns): `PlayerBarButton.qml` (`windupMs`, `coastMs`, `turns`).
- A row's right-click menu: the `rows` lists in `AudioPlayerPopup.qml` (queue) and `PlayerLibrary.qml` (library).
- The queue shuffle's spread: `player.jsonc` `shuffle`.
Gate: `tools/dev/smoke.sh mockups/audio_player.qml`, then `tools/dev/smoke.sh shell.qml`.
