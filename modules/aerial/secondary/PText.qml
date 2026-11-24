import QtQuick

import "../../common/theme"

// =============================================================================
// PText.qml -- the panels' one text: Inter (or the mockup's face) at the body size in primary ink; `tone` 1 muted, 2 faint, 3 the
// warning ink, 4 the error ink, 5 the ok ink; `strong` the title (16 bold); `small` the figure size. Plain text, word-wrapped by the
// host's width where it sets one.
// =============================================================================
Text {
    id: t

    property PanelStyle look: null
    property int tone: 0
    property bool strong: false
    property bool small: false
    // `shown` collapses the text BY GEOMETRY as well as by `visible`: a Column hears nothing from a child whose `visible` flips under a hidden ancestor
    property bool shown: true

    visible: t.shown
    height: t.shown ? Math.ceil(t.contentHeight) : 0
    color: t.tone === 1 ? Theme.textMuted : t.tone === 2 ? Theme.textFaint : t.tone === 3 ? Theme.warn : t.tone === 4 ? Theme.error : t.tone === 5 ? Theme.ok : Theme.textPrimary
    textFormat: Text.PlainText
    font.family: t.look ? t.look.fontFamily : "Inter"
    font.pixelSize: t.strong ? (t.look ? t.look.titleSize : 16) : t.small ? (t.look ? t.look.figureSize : 11) : (t.look ? t.look.bodySize : 12)
    font.bold: t.strong
}
