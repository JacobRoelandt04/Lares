pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../parts/NotifyGlyphs.js" as G

// =============================================================================
// ManagerHeader.qml -- the manager's top row:
//
//   Notifications                 Do not disturb [o  ]  [ Clear all ]
//   No notifications                             Do not disturb [o  ]
//
// While the user types, the query REPLACES the title (the launcher's rule),
// with the magnifier in front of it, so there is no field to find: typing is
// the search.
//
// THE BUTTON IS THE MANAGER'S ONE UNDO SLOT.
// Clear all is an UndoDrainButton: after a clear it offers the undo of THE
// LATEST clear for `undoMs` -- "Undo" after Clear all, "Undo clear <Group>"
// after a group's header was swiped away -- the drain sweeping through its own
// shading, and then it is Clear all again. Its width is reserved for the
// widest of every wording it can take (`reserveWords`), so no swap ever
// moves it or what stands beside it.
//
// PRESENCE. With nothing to clear and no undo on offer (`present` false) the
// button is not there and the do-not-disturb toggle sits at the right end.
// It comes and goes on ONE clock (`buttonMs`, OutCubic): its fraction is the
// button's width (its right edge stays at the row's end), the gap before it
// -- so it pushes the toggle aside and never lies over it -- and its opacity.
// The row keeps the button's height either way, so the popup does not step.
// It eases only once the host has said what it is (`animatePresence`): a
// manager opened with notifications shows its Clear all at once, and the
// button grows in only when it COMES BACK (the first `present` of a new
// manager would animate, and the toggle slide ~95 px on every open).
//
// THE TITLE MORPHS between two wordings that differ by an INSERTION: "Notifications"
// and "No notifications" share "No" and "tifications", so the tail slides by
// the width of " no" while those letters fade in the gap it opens (or close
// it, going the other way). The pair is found, not listed: the longest common
// prefix and suffix of the old and the new title, and a change whose middle is
// empty on one side is a morph (any other change, or one while a query
// replaces the title, is an instant swap -- text swaps are
// instant, only an insertion has a motion to show). ONE CLOCK: `_u`, 0 for the
// short wording and 1 for the long one, eased over `titleMs` (the button's own
// 260 ms OutCubic, since the title changes in the very frame the button comes
// or goes); the tail's x, the gap the letters are clipped to and their opacity
// are all functions of it, and a title that turns back mid-way reverses the
// same fraction. Widths are the real layout's (hidden Texts of the same face:
// a synthesized bold, Audiowide's, is laid out wider than FontMetrics says) and
// every x is a whole pixel. At rest, and for every other change, the title is
// the one plain Text.
//
// A LEAVING BUTTON SAYS WHAT IT SAID. An undo window running out on an empty
// history takes the button away as "Undo" / "Undo clear <Group>" -- the words
// it offered on its last present frame -- never as a "Clear all" with nothing
// to clear; and it keeps its colour: leaving, it takes no click (a blocker
// over it), where a disabled RaisedButton would grey its words for one frame
// and hold them grey for the whole leave.
// =============================================================================
Item {
    id: head

    property string title: "Notifications"
    property string query: ""
    property bool dnd: false
    property bool present: true
    property string undoText: "Undo"
    // Every wording the button can take; its width is the widest.
    property var reserveWords: []
    property int undoMs: 10000
    property int buttonMs: 260
    property real buttonGap: 12
    property bool animatePresence: true
    property string fontFamily: "Inter"
    property color surfaceColor: Theme.surface
    // Type and the row's gaps (NotificationStyle; each default is the value drawn
    // when no style is given). The label's gap is to the toggle's box, which
    // is its groove (GrooveToggle has no slack): 10 keeps the label's ink 6 px
    // from the toggle's.
    property int titleSize: 16
    property int dndLabelSize: 11
    property int searchGlyphSize: 14
    property int buttonTextSize: 12
    property real buttonHeight: 30
    property real dndLabelGap: 10
    property real titleGap: 12
    property real searchGlyphGap: 6
    // The title morph's ease (see THE TITLE MORPHS).
    property int titleMs: head.buttonMs

    signal dndToggled(bool on)
    signal clearAllClicked()
    signal undoClicked()

    readonly property bool undoing: clearAll.undoing
    readonly property real buttonFraction: head._f
    readonly property Item button: clearAll
    function arm(leftMs) {
        clearAll.arm(leftMs);
    }
    function disarm() {
        if (clearAll.undoing)
            head._leaveWords = head.undoText;
        clearAll.disarm();
    }

    implicitHeight: Math.ceil(Math.max(titleText.implicitHeight, clearAll.height, toggle.implicitHeight))

    // ---- the button's presence: one clock ----------------------------------
    property real _f: head.present ? 1 : 0
    Behavior on _f {
        enabled: head.animatePresence
        NumberAnimation {
            duration: head.buttonMs
            easing.type: Easing.OutCubic
        }
    }
    // The words it leaves with: set wherever an undo ends without the button
    // coming back as Clear all (expired, disarmed, taken); a present button
    // is Clear all again.
    property string _leaveWords: "Clear all"
    onPresentChanged: {
        if (head.present)
            head._leaveWords = "Clear all";
    }
    // Whole pixels: the button's plate and the toggle land on the grid.
    readonly property real _shownW: Math.round(head._f * head._btnW)
    readonly property real _room: head._shownW + Math.round(head._f * head.buttonGap)

    // ---- the reserved width --------------------------------------------------
    FontMetrics {
        id: fm
        font.family: head.fontFamily
        font.pixelSize: clearAll.fontPixelSize
        font.bold: true
    }
    FontInfo {
        id: matched
        font: fm.font
    }
    // Reads `fm.font` first: advanceWidth() is a call, and a binding with
    // nothing else in it would keep its first answer for ever (CLAUDE.md).
    // A synthesized bold is laid out a pixel wider than its advances.
    function _advance(s) {
        const f = fm.font;
        if (!(f.pixelSize > 0))
            return 0;
        const synthetic = f.bold && !/bold|black|heavy/i.test(matched.styleName);
        return fm.advanceWidth(s) + (synthetic ? 1 : 0);
    }
    readonly property real _btnW: {
        const words = ["Clear all", "Undo", head.undoText].concat(head.reserveWords || []);
        let w = 0;
        for (const s of words)
            w = Math.max(w, head._advance(s));
        // RaisedButton: 14 px of padding each side, 64 px at least.
        return Math.ceil(Math.max(64, w + 28));
    }

    // ---- the title ---------------------------------------------------------
    Text {
        id: glyph
        visible: head.query !== ""
        anchors.verticalCenter: parent.verticalCenter
        text: G.magnify
        font.family: G.family
        font.pixelSize: head.searchGlyphSize
        color: Theme.textFaint
    }
    // The title as plain text: at rest and for every swap that is not a morph.
    Text {
        id: titleText
        x: head.query !== "" ? glyph.width + head.searchGlyphGap : 0
        width: Math.max(0, dndLabel.x - x - head.titleGap)
        anchors.verticalCenter: parent.verticalCenter
        visible: !head._morphing
        text: head.query !== "" ? head.query : head._shownTitle
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: Theme.textPrimary
        font.family: head.fontFamily
        font.pixelSize: head.titleSize
        font.bold: true
    }

    // ---- the title's morph --------------------------------------------------
    property string _shownTitle: head.title    // what titleText draws at rest
    property bool _morphing: false
    property string _a: ""                     // the short wording (u = 0) ...
    property string _b: ""                     // ... and the long one (u = 1)
    property string _pre: ""                   // what both start with
    property string _mid: ""                   // what the long one adds
    property string _tail: ""                  // what both end with
    property real _u: 0

    // [from, to] -> the pair, or null when this is not an insertion.
    function _plan(from, to) {
        if (from === to)
            return null;
        const n = Math.min(from.length, to.length);
        let p = 0;
        while (p < n && from[p] === to[p])
            p++;
        let q = 0;
        while (q < n - p && from[from.length - 1 - q] === to[to.length - 1 - q])
            q++;
        const fm = from.substring(p, from.length - q);
        const tm = to.substring(p, to.length - q);
        if ((fm !== "" && tm !== "") || p + q === 0)
            return null;
        const grows = fm === "";
        return { a: grows ? from : to, b: grows ? to : from, pre: from.substring(0, p),
                 mid: grows ? tm : fm, tail: from.substring(from.length - q), toLong: grows };
    }
    function _toward(v) {
        morph.stop();
        morph.from = head._u;
        morph.to = v;
        morph.duration = Math.max(80, Math.round(head.titleMs * Math.abs(v - head._u)));
        morph.start();
    }
    function _settle() {
        morph.stop();
        head._shownTitle = head._morphing && head._u >= 0.5 ? head._b : head._morphing ? head._a : head.title;
        head._morphing = false;
    }
    onTitleChanged: {
        if (head.query !== "") {
            head._settle();
            head._shownTitle = head.title;
            return;
        }
        if (head._morphing) {
            // The pair in flight turning back (or on): the same fraction.
            if (head.title === head._a || head.title === head._b) {
                head._toward(head.title === head._b ? 1 : 0);
                return;
            }
            head._settle();
        }
        const pl = head._plan(head._shownTitle, head.title);
        if (pl) {
            head._a = pl.a;
            head._b = pl.b;
            head._pre = pl.pre;
            head._mid = pl.mid;
            head._tail = pl.tail;
        }
        // Whole title in the room it has, else a plain swap.
        if (!pl || Math.ceil(Math.max(wA.implicitWidth, wB.implicitWidth)) > titleText.width) {
            head._shownTitle = head.title;
            return;
        }
        head._u = pl.toLong ? 0 : 1;
        head._morphing = true;
        head._toward(pl.toLong ? 1 : 0);
    }
    onQueryChanged: {
        if (head.query !== "" && head._morphing) {
            head._settle();
            head._shownTitle = head.title;
        }
    }
    NumberAnimation {
        id: morph
        target: head
        property: "_u"
        easing.type: Easing.OutCubic
        onFinished: head._settle()
    }

    component TitlePart: Text {
        textFormat: Text.PlainText
        color: Theme.textPrimary
        font.family: head.fontFamily
        font.pixelSize: head.titleSize
        font.bold: true
    }
    // WHERE THE PIECES STAND, as the plain Text lays them out (the measuring
    // Texts are hidden). A piece's start inside a wording is the advance of
    // everything before it plus its own first letter, less that letter alone:
    // the kerning between the last letter before it and its first (the "o" and
    // the "t") is then inside the answer, which the pieces' own widths would
    // miss (0.7 px, the whole tail a hair off the plain Text's on the
    // morph's last frame). So no x is rounded either: the plain Text's glyphs
    // stand at fractional x, and a whole-pixel tail would settle half a pixel
    // when the morph hands over to it.
    TitlePart { id: mA; visible: false; text: head._pre + head._tail.charAt(0) }
    TitlePart { id: mB; visible: false; text: head._pre + head._mid + head._tail.charAt(0) }
    TitlePart { id: mM; visible: false; text: head._pre + head._mid.charAt(0) }
    TitlePart { id: wT; visible: false; text: head._tail.charAt(0) }
    TitlePart { id: wM; visible: false; text: head._mid.charAt(0) }
    TitlePart { id: wA; visible: false; text: head._a }
    TitlePart { id: wB; visible: false; text: head._b }
    readonly property real _tailA: mA.implicitWidth - wT.implicitWidth
    readonly property real _tailB: mB.implicitWidth - wT.implicitWidth
    readonly property real _midX: mM.implicitWidth - wM.implicitWidth
    // The tail's x on the one clock.
    readonly property real _tailX: head._tailA + (head._tailB - head._tailA) * head._u

    TitlePart {
        x: 0
        anchors.verticalCenter: parent.verticalCenter
        visible: head._morphing
        text: head._pre
    }
    // The added letters, where the long wording has them, cut to the gap the
    // tail opens (a wipe from the left, in reading order) and fading with it.
    Item {
        x: head._midX
        width: Math.max(0, head._tailX - head._midX)
        height: head.height
        clip: true
        visible: head._morphing
        opacity: head._u

        TitlePart {
            x: 0
            anchors.verticalCenter: parent.verticalCenter
            text: head._mid
        }
    }
    TitlePart {
        x: head._tailX
        anchors.verticalCenter: parent.verticalCenter
        visible: head._morphing
        text: head._tail
    }

    // ---- do not disturb, pushed aside by the button's room -------------------
    Text {
        id: dndLabel
        x: Math.round(toggle.x - head.dndLabelGap - width)
        anchors.verticalCenter: parent.verticalCenter
        text: "Do not disturb"
        color: Theme.textMuted
        font.family: head.fontFamily
        font.pixelSize: head.dndLabelSize

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: head.dndToggled(!head.dnd)
        }
    }
    GrooveToggle {
        id: toggle
        x: Math.round(head.width - head._room - width)
        anchors.verticalCenter: parent.verticalCenter
        surfaceColor: head.surfaceColor
        checked: head.dnd
        onToggled: on => head.dndToggled(on)
    }

    UndoDrainButton {
        id: clearAll
        objectName: "managerClearAll"
        x: head.width - width
        width: head._shownW
        height: head.buttonHeight
        anchors.verticalCenter: parent.verticalCenter
        visible: head._f > 0.001
        opacity: head._f
        text: head.present ? "Clear all" : head._leaveWords
        undoText: head.undoText
        drainMs: head.undoMs
        surfaceColor: head.surfaceColor
        fontFamily: head.fontFamily
        fontPixelSize: head.buttonTextSize
        onClicked: {
            if (head.present)
                head.clearAllClicked();
        }
        onUndoClicked: {
            head._leaveWords = head.undoText;
            head.undoClicked();
        }
        onExpired: head._leaveWords = head.undoText
    }
    // Leaving, the button takes no click and no hover (and keeps its colour).
    MouseArea {
        x: clearAll.x
        y: clearAll.y
        width: clearAll.width
        height: clearAll.height
        enabled: !head.present && clearAll.visible
        hoverEnabled: true
    }
}
