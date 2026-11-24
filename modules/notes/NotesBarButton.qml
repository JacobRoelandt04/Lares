pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/glyphs"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "parts/NotePeelPose.js" as Pose

// =============================================================================
// NotesBarButton.qml -- the notes glyph in the bar.
//
// A click toggles the popup. A FILE dragged onto the glyph and held there for
// `springMs` opens it (spring-loading), so a note can be
// dragged from a file manager straight into a closed popup: the drag carries
// on down into it and drops there.
//
// The glyph is a glyph button's: the muted ink at rest, its own hover hue (BarHues
// `notesHover`) under the pointer, a held file and while the popup is ours, on the
// bar's one hover clock (GlyphHoverEase).
//
// THE FLOURISH (feedback/notes.md "Bar icon flourish"): the top sheet is PEELED off
// the block by its folded corner, snaps free and flies off up and to the left,
// shrinking as it goes back; the next sheet rose in behind it when the peel began
// and folds its own corner as the old one vanishes (NotePeelPose.js). It plays when
// the pointer comes onto the glyph (GlyphFlourish: once per entry) and in the OLED
// care's random turns (group `notes`, decorative: it says nothing happened).
// =============================================================================
Item {
    id: btn

    property var owner: null
    property real size: 18
    property int springMs: 500
    readonly property bool active: btn.owner ? btn.owner.popupMine : false

    implicitWidth: btn.size + 10
    implicitHeight: btn.size + 10

    property real hoverF: area.containsMouse || drop.containsDrag || btn.active ? 1 : 0
    Behavior on hoverF {
        GlyphHoverEase {}
    }

    // ---- the flourish ----
    property bool flourishEnabled: true
    // the whole run, ms: the peel, the flight, the new note's fold
    property int flourishMs: 1250
    readonly property alias flourish: peel
    readonly property alias glyphItem: glyph
    GlyphFlourish {
        id: peel
        group: "notes"
        decorative: true
        armed: btn.flourishEnabled
        ms: btn.flourishMs
        // a run is one sheet leaving: a second ask while it plays is ignored (a restart would put the sheet back)
        overlap: "ignore"
        hoverArea: area
    }

    PosedGlyph {
        id: glyph
        anchors.centerIn: parent
        text: "\uF249"
        pixelSize: btn.size
        color: Mix.c(Theme.textMuted, BarHues.notesHover, btn.hoverF)
        posing: peel.playing
        readonly property var pose: peel.playing ? Pose.frame(peel.t, peel.ms, null, glyph.pixelSize, glyph.origin.x, glyph.origin.y) : null
        parts: glyph.pose ? glyph.pose.parts : []
        shades: glyph.pose ? glyph.pose.shades : []
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            if (btn.owner)
                btn.owner.toggle();
        }
    }

    DropArea {
        id: drop
        anchors.fill: parent
        keys: []
        onEntered: drag => {
            drag.accepted = drag.hasUrls;
            if (drag.hasUrls)
                spring.restart();
        }
        onExited: spring.stop()
        onDropped: d => {
            spring.stop();
            // Dropped on the glyph itself: open, and hand the files over.
            if (!btn.owner || !d.hasUrls)
                return;
            const paths = [];
            for (let i = 0; i < d.urls.length; i++) {
                const u = d.urls[i].toString();
                if (u.indexOf("file://") === 0)
                    paths.push(decodeURIComponent(u.substring(7)));
            }
            if (paths.length) {
                d.accept();
                btn.owner.open();
                btn.owner.activeStore.dropFiles(paths);
            }
        }
    }
    Timer {
        id: spring
        interval: btn.springMs
        onTriggered: {
            if (btn.owner && drop.containsDrag)
                btn.owner.springLoad();
        }
    }
}
