import QtQuick

// =============================================================================
// OsdGlyph.qml -- one Nerd Font glyph in a square slot of its own, centred in
// it (`slot`, by default its own size). Every glyph of the OSD sits in a slot like this one so a swap of glyph
// (volume low / medium / high, play / pause) never moves what is beside it.
// =============================================================================
Text {
    id: g

    property var osd: null
    property string glyph: ""
    // The glyph's pixel size, and the square slot it is centred in.
    property real size: 22
    property real slot: g.size

    // Where the glyph's INK starts below the top of its slot (the slot is square
    // and the glyph centred in it, with room above its ink): what a layout that
    // stands the ink a given distance from an edge subtracts.
    readonly property real inkTop: {
        const f = fm.font;
        return Math.max(0, (g.slot - g.contentHeight) / 2 + fm.ascent + fm.tightBoundingRect(g.glyph).y);
    }

    FontMetrics {
        id: fm
        font.family: g.font.family
        font.pixelSize: g.size
    }

    width: g.slot
    height: g.slot
    text: g.glyph
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    font.family: g.osd ? g.osd.glyphFont : "Symbols Nerd Font"
    font.pixelSize: g.size
}
