pragma Singleton

import QtQuick

// =============================================================================
// BarText.qml -- the ink bar TEXT rests in: the glyphs' own shade, Theme.textMuted, always (the clock, the focused title, the
// weather digits, the update percent, the battery's charge digits, the idle reel's reason). One ink for glyphs and text.
// =============================================================================
QtObject {
    id: root

    readonly property color ink: Theme.textMuted
}
