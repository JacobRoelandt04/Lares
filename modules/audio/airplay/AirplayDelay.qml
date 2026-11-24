pragma Singleton

import QtQuick

// =============================================================================
// AirplayDelay.qml -- how long the SOUND lags the player's own facts, in ms: the shell's one number for it.
//
// While mpd's stream goes into an AirPlay (RAOP) sink the speaker plays what mpd decoded a few seconds ago (the sink's buffer,
// `raop.latency.ms`), so a song change mpd reports, a track card, the bar glyph's new-song flourish and a lyric line would all come
// that much BEFORE what is heard. Whatever should arrive WITH the sound waits this long; whatever the user drives live (the
// popup's playhead, a scrub, the queue) stays live.
//
// Written by ONE writer: ShellServices binds it to the AirplayWatch's `delayMs` (0 unless mpd is playing into a RAOP sink).
// Anything else leaves it at 0, so a mockup or a probe without the shell is exactly the player as it was. A singleton, not an
// injected property, because its readers are three displays in three modules (the OSD's track source, a bar button, the player's
// lyrics) that each have another owner; the value is one fact of the process, like the theme.
// =============================================================================
QtObject {
    property int delayMs: 0
}
