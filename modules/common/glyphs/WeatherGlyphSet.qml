pragma Singleton

import QtQuick

// =============================================================================
// WeatherGlyphSet.qml -- which weather icon set WeatherGlyph draws, for the whole process.
//
//   "ink"      the drawn set (WeatherGlyphInk): solid Material-weight icons in the bar's muted ink with ONE accent part
//   "carved"   the legacy set (the carved, full-colour SDF glyphs)
//
// TEMPORARY: the legacy set stays only until the user has approved the new one; then this file, the `glyphSet` key of
// weather.jsonc and the carved half of WeatherGlyph go together.
//
// ONE writer per process: the shell's ShellServices binds it to the weather config's `glyphSet`; a mockup's panel writes it
// for its own process. Anything else only reads.
// =============================================================================
QtObject {
    property string set: "ink"
    readonly property bool carved: set === "carved"
}
