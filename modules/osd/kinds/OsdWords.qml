import QtQuick

// =============================================================================
// OsdWords.qml -- how wide a vertical card's longest word is.
//
// A vertical card never breaks a word: its width grows to fit the longest word
// of what it says (up to OsdStyle.cardMaxW), and a word that is longer than the
// room is not wrapped at all -- the line elides. The cards ask `title(s)` for a
// bold line at the title size and `detail(s)` for a plain one at the detail
// size; the answer is the advance of the longest space-separated word, whole
// pixels, and one more for the bold a face with no bold synthesises.
//
// The metrics' own font is read INSIDE the helper: an advanceWidth() call alone
// captures nothing, and a binding on it would keep its first answer.
// =============================================================================
Item {
    id: w

    property string family: "Inter"
    property real titlePx: 14
    property real detailPx: 11

    visible: false
    width: 0
    height: 0

    FontMetrics {
        id: ft
        font.family: w.family
        font.pixelSize: w.titlePx
        font.bold: true
    }
    FontMetrics {
        id: fd
        font.family: w.family
        font.pixelSize: w.detailPx
    }

    function _longest(fm: FontMetrics, s: string): real {
        const f = fm.font;
        let m = 0;
        const words = String(s || "").split(/\s+/);
        for (let i = 0; i < words.length; i++)
            m = Math.max(m, fm.advanceWidth(words[i]));
        return Math.ceil(m) + 1;
    }
    function title(s: string): real {
        return w._longest(ft, s);
    }
    function detail(s: string): real {
        return w._longest(fd, s);
    }
    // The whole of a bold line at the title size (a card that is as wide as its one-line title).
    function titleLine(s: string): real {
        const f = ft.font;
        return Math.ceil(ft.advanceWidth(String(s || ""))) + 1;
    }
    // The whole of a plain line at the detail size (a card that is as wide as its one-line name).
    function detailLine(s: string): real {
        const f = fd.font;
        return Math.ceil(fd.advanceWidth(String(s || ""))) + 1;
    }
}
