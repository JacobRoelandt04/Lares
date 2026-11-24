pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import "../../../common/theme"
import "../../../common/components"
import "../../../common/components/Mix.js" as Mix
import "../../../common/components/Markdown.js" as Md

// =============================================================================
// LlmAttachmentChip.qml
//
// One attached file, as a chip: the carved rounded square that sits in the
// composer's strip and, `removable: false`, above a committed question in the
// transcript. One component for both places, so an attachment looks the same
// before and after it is sent.
//
// THE FACE IS A SILHOUETTE, DELIBERATELY -- two stacked rounded bars reading
// as a tiny document, text and paragraphs, not a real thumbnail. The real
// preview lives in the HOVER TIP, where it can afford to be big; the chip
// itself stays one material for every file type. The bars sit low-left so the
// ×-remove in the top-right corner never touches them. The filename runs
// under the bars at 8 px with a MIDDLE elide -- tiny, but a middle-elided 8 px
// name shows both the stem and the extension, which is more of the name than a
// 9 px right-elide would show.
//
// THE TIP IS THE PREVIEW, per kind:
//   image  the picture, rounded and capped;
//   pdf    the FIRST PAGE, captioned "page 1 of N". `images[0]` is page 1 only
//          while the pipeline renders pages -- in embedded mode it is the first
//          extracted PICTURE, so a 74-page deck would preview whatever logo
//          sits on page 2: a pdf previews page 1 or nothing;
//   text   the first ~40 lines through the markdown highlighter, in the same
//          rounded frame a code block gets;
//   video  the first frame the model sees, captioned with the length and,
//          while the frames are still on the object, how many were sent;
//   audio  the WAVEFORM -- mirrored vertical bars from `peaks` -- plus the
//          length. Audio cannot reach the model today (measured: the wire
//          silently drops it), so the chip is failed, but the waveform still
//          shows: the tip describes the file, not the wire.
//
// ONE PICTURE FOR THE THREE PICTORIAL KINDS: `thumbB64`, the small JPEG the
// loader produces at load for an image, a pdf's page 1 and a video's first
// sent frame, and the ONE payload the store keeps whatever its caps strip --
// so a chip above a SENT prompt previews exactly what the composer's chip
// previewed before the send, in the transcript and after a restart alike. The
// load-time `pageThumbB64` is built to be thrown away (27-87 KB of PNG per
// pdf, kept out of the store on purpose), and an image's own `b64` goes the
// moment the payload cap needs the room. `_shot` is the one rule: `thumbB64`
// when the object carries it, else the load-time source an older message
// still has -- its own `b64`, the page render, the first frame -- else
// nothing, and the tip is the label. The data URL says jpeg for the thumb
// and the source's own type otherwise; Qt sniffs the bytes either way
// (measured by the loader).
//
// While `pending` (the loader is still reading the file) the tip is just the
// name; the preview data does not exist yet. The tip's content component only
// instantiates while the tip arms, so none of this costs anything unhovered.
//
// The attachment object is the loader shape:
//   { path, name, mime, kind, isImage, b64, thumbB64, textContent, images,
//     pageCount, durationMs, peaks, pending, failed, failReason }
// plus, on a pdf, `includeImages`. Older shapes (no `kind`) still draw:
// `isImage` maps to "image", everything else to "other", and a missing field
// just means no preview.
//
// THE ONE THING A CHIP CAN CHANGE: a pdf's pictures ride to the model or they
// do not. The glyph that carries that state lives UNDER THE ×, as the second
// item of one vertical stack in the top-right corner, and it comes and goes
// WITH the ×: two marks in two different corners read as two unrelated
// things, and a chip at rest should be a document, not a control panel. So
// the corner holds one stack of controls, revealed together by the pointer,
// and the resting chip is the silhouette and its name. The stack is right of
// the silhouette by a clear margin, never over it.
//
// The mark is accent when the pictures ride and faint when the model gets the
// text only; clicking it emits `imagesToggled(on)`, which the composer turns
// into `includeImages` on the real attachment object (see the note on the
// toggle: a Repeater's `modelData` is a copy, so the chip cannot write it) and
// the host turns into the extraction the loader put off. While those pictures
// are missing the glyph breathes on the skeleton's own clock, so a lit icon
// never claims images that are not there.
//
// THE GLYPH HAS NO TIP OF ITS OWN. The loader's figures are in the pdf menu,
// a right-click away, beside the settings that produce them -- and two places
// saying one thing is one place too many, especially when one of them opens
// under the pointer on the way to the other. The glyph has its cursor, its
// colour states and its pulse; what it MEANS is in the menu.
//
// WHAT THE MENU SHOWS is `pdfFactFigures` / `pdfFactsAdvanced`, built here
// because the wording is the chip's. The two are split by KIND: the figures
// (how many ride, from how many pages, duplicates dropped, the token
// estimate) plus one word for the state -- images, text only, reading, none
// -- are numbers, and the menu prints them as a fixed table that never
// changes shape as a slider moves; the loader's REASONS (what was cut and
// why, mask-drawn figures, why a duplicate rides once) are prose, and stay
// prose in a tip beside the panel.
//
// THE REASONS ARE LINES, NOT A LINE. The loader's sentences run to 130
// characters, and past about 48 a line stops reading. So they are broken
// where the MEANING breaks -- each statement of the loader's note on its own,
// and a statement still wider than the measured limit cut at its last clause
// boundary that fits -- never inside a figure. See `_tipLines`.
//
// Every colour is a property with a `Theme.<token>` default; the code-token
// colours follow MarkdownView's precedent (Theme-defaulted, hosts need not
// forward them). Nothing animates a colour -- hover eases a fraction and
// Mix.js blends.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // PUBLIC API
    // ======================================================================
    // The attachment object (shape above). The host owns it and patches it in
    // place as the loader resolves; this chip only draws it.
    property var    att: null
    // false hides the ×: a chip above a committed question is a record, not a
    // control.
    property bool   removable: true
    // The host's floating layer (LlmPopup.overlayItem) for the tip. Null =
    // local parenting (harnesses).
    property Item   overlayItem: null

    property string fontFamily: "Inter"
    property string monoFamily: "Consolas"
    property real   chipSize: 64
    property real   radius: 10
    // ---- Tunables ----
    property int    nameFontSize: 8         // the filename under the bars
    property int    controlRevealMs: 120    // the stack's reveal, and its hover fades
    property real   controlCell: 14         // one control's cell, glyph centred
    property real   controlGap: 5           // between the × and the toggle
    property real   silhouetteLeft: 10
    property real   silhouetteTop: 14
    property int    pulseMs: 900            // one half-breath of the pending pulse
    property real   previewMaxWidth: 280    // the pictorial preview's fit box
    property real   previewMaxHeight: 200
    property real   textPreviewWidth: 340   // the text preview's frame
    property real   textPreviewMaxHeight: 260

    // ---- Palette ----
    property color surfaceColor: Theme.panelSunk     // ground the chip sits on
    property color fillColor: Theme.headerBox        // the chip's own fill
    property color bevelColor: Theme.bevel
    property color shadowColor: Theme.border
    property color primaryText: Theme.textPrimary
    property color mutedText: Theme.textMuted
    property color faintText: Theme.textFaint
    property color accent: Theme.accent              // the waveform's ink
    property color accentHover: Theme.accentHover
    property color errColor: Theme.error
    property color tipSurfaceColor: Theme.surface    // the tip bubble's fill
    // The text preview's frame and inks -- the same mapping CodeBlock uses.
    property color codeBgColor: Theme.terminalBg
    property color codeTextColor: Theme.terminalFg
    property color codeKwColor: Theme.ansiBrightMagenta
    property color codeStrColor: Theme.ansiGreen
    property color codeNumColor: Theme.ansiYellow
    property color codeComColor: Theme.textFaint
    property color codeFnColor: Theme.ansiBlue
    property color codeTypeColor: Theme.ansiCyan
    property color codeOpColor: Theme.textMuted
    property color codeVarColor: Theme.ansiBrightCyan
    property color codePuncColor: Theme.textMuted

    signal removeRequested()
    // The pdf image toggle was clicked; `on` is the value already written to
    // `att.includeImages`. The host's cue to make the pages exist (the loader
    // renders them lazily) -- see the header.
    signal imagesToggled(bool on)
    // Right-click on the pictures glyph: the host opens the pdf menu
    // (LlmPdfMenu) above this chip. Only a live pdf chip emits it.
    signal menuRequested()
    // The host's pdf menu is open on THIS chip: the control stack stays
    // revealed while the pointer is over the menu, so the glyph that opened
    // it does not vanish under it.
    property bool   menuOpen: false

    implicitWidth: root.chipSize
    implicitHeight: root.chipSize

    // ======================================================================
    // DERIVATIONS
    // ======================================================================
    readonly property var  _a: root.att || ({})
    readonly property bool _pending: !!root._a.pending
    readonly property bool _failed: !!root._a.failed
    readonly property string _name: root._a.name || root._a.path || "file"
    readonly property string _kind: root._a.kind
        ? String(root._a.kind)
        : (root._a.isImage ? "image" : "other")
    readonly property var _pages: root._a.images && root._a.images.length ? root._a.images : []
    // The persisted preview (header) and, for a message from before it, the
    // load-time page render.
    readonly property string _thumb: String(root._a.thumbB64 || "")
    readonly property string _pageThumb: String(root._a.pageThumbB64 || "")
    readonly property var _peaks: root._a.peaks && root._a.peaks.length ? root._a.peaks : []
    // THE TIP'S PICTURE, as a data URL -- one rule for image, pdf and video
    // (header). Empty is "no picture".
    readonly property string _shot: {
        if (root._thumb.length > 0)
            return "data:image/jpeg;base64," + root._thumb;
        switch (root._kind) {
        case "image": return root._a.b64
            ? "data:" + (root._a.mime || "image/png") + ";base64," + root._a.b64 : "";
        case "pdf":   return root._pageThumb.length > 0
            ? "data:image/png;base64," + root._pageThumb : "";
        case "video": return root._pages.length > 0
            ? "data:image/png;base64," + root._pages[0] : "";
        default:      return "";
        }
    }

    // ---- What the loader found in the pdf ----------------------------------
    // The five fields the loader publishes once it has inventoried the
    // document: how many pictures ride after dedup and filtering, which page
    // each came from (in the order they are sent), what they cost, how many
    // placements were dropped as duplicates, and the honest sentence when
    // something had to be cut.
    //
    // THE GATE IS `imagesRendered`, NOT the presence of the fields. They are
    // initialised to zero on EVERY attachment the moment it is queued, so
    // "imageCount === 0" is the state of a pdf nobody has looked inside yet
    // as often as it is the answer for a deck of vector art -- and a chip
    // that announced "no pictures" while the loader was still reading would
    // be wrong twice: it would say a false thing, and it would stop the pulse
    // that says work is happening. `imagesRendered` is the loader's own "I
    // have looked"; `pending` covers the frames while it looks again. An
    // older loader has neither, and gets the sentence that quotes no number.
    readonly property bool _hasImgFacts: !root._pending && !!root._a.imagesRendered
    readonly property int  _imgCount: Math.max(0, Number(root._a.imageCount) || 0)
    readonly property var  _imgPages: root._a.imagePages && root._a.imagePages.length
        ? root._a.imagePages : []
    readonly property int  _imgTokens: Math.max(0, Number(root._a.imageTokens) || 0)
    readonly property int  _imgDupes: Math.max(0, Number(root._a.imageDupes) || 0)
    readonly property string _imgNote: String(root._a.imageNote || "")
    // Pictures come from PAGES, and one page can carry several: the honest
    // second figure is how many DISTINCT pages are represented, not the
    // length of the list.
    readonly property int _imgPageSpan: {
        const seen = ({});
        let n = 0;
        for (let i = 0; i < root._imgPages.length; ++i) {
            const k = String(root._imgPages[i]);
            if (!seen[k]) { seen[k] = true; n += 1; }
        }
        return n;
    }

    // ---- The pdf image toggle ---------------------------------------------
    // A pdf reaches the model two ways at once: its extractable text, and its
    // pages as pictures. The pictures are what let it read a slide, and they
    // cost about 256 tokens a page, so whether they ride is a decision the
    // user has to be able to see and make -- `includeImages` on the
    // attachment object, which the loader defaults to true and the service
    // honours at wire time.
    //
    // Only on a LIVE chip: `removable` already means "this chip is a control,
    // not a record", and a record above a committed question cannot change
    // what was already sent. Not on a failed one either -- nothing rides from
    // a file that could not be read, and a live-looking switch on a dead chip
    // is a lie the ⚠ beside it already contradicts.
    readonly property bool _canToggleImages: root.removable && root._kind === "pdf"
        && !root._failed
    // WHY THIS CHIP DOES NOT WRITE THE FLAG ITSELF. MEASURED: a Repeater over
    // a JS array hands each delegate a COPY of the object -- `modelData === theHostsObject` is false and a
    // write to it lands nowhere -- while a plain `var` property preserves the
    // identity, so the COMPOSER, which holds the real array, is the nearest
    // thing to the chip that can write `includeImages` on the real
    // attachment. The chip owns the mark and the click and reports them; the
    // composer writes. Until the host hands the array back (which rebuilds
    // this delegate around a fresh copy), the click's own answer comes from
    // this override. -1 = follow the object.
    property int _includeOverride: -1
    onAttChanged: {
        root._includeOverride = -1;
        root._askedImages = false;
    }
    readonly property bool _includeImages: root._includeOverride >= 0
        ? root._includeOverride === 1
        : (root._a.includeImages !== false)
    // Toggled ON while there were no pages yet: the loader has to render them
    // now, and until it says otherwise the chip is waiting. It ends the
    // moment the host answers -- with a new object here (onAttChanged) or, in
    // the composer, with a new array, which rebuilds this delegate false.
    property bool _askedImages: false
    // Waiting for pages that are meant to ride -- the loader's own `pending`
    // covers a lazy render it has already started, `_askedImages` covers the
    // frames between the click and the host reacting. Never a dead icon.
    // ... and once the loader has answered "none", there is nothing to wait
    // for: a document of vector art would otherwise breathe for ever.
    readonly property bool _imagesPending: root._canToggleImages && root._includeImages
        && !(root._hasImgFacts && root._imgCount === 0)
        && (root._pending || (root._askedImages && root._pages.length === 0))

    function _toggleImages() {
        const on = !root._includeImages;
        root._includeOverride = on ? 1 : 0;
        root._askedImages = on && root._pages.length === 0;
        root.imagesToggled(on);
    }

    // 7772 -> 7800: a token estimate this soft should not pretend to four
    // significant digits, so it is published already rounded and the menu
    // only groups its digits.
    function _tokensSoft(n) {
        const v = Math.max(0, Number(n) || 0);
        return v >= 1000 ? Math.round(v / 100) * 100 : v;
    }
    function _plural(n, word) { return n + " " + word + (n === 1 ? "" : "s"); }
    // ---- The tip's lines --------------------------------------------------
    // THE LIMIT IS MEASURED, NOT COUNTED: the advance of 48 characters of
    // running prose in the tip's own font -- a line of the loader's own words
    // is the reference -- so it holds in Inter (242 px) and in Audiowide
    // (279 px) alike, and a tip never runs wider than a tip should.
    // Referencing `font` is what makes the width follow a font change.
    FontMetrics {
        id: tipMetrics
        font.family: root.fontFamily
        font.pixelSize: chipTip.fontPixelSize
    }
    readonly property string _tipRefLine: "and could not be extracted — page mode can send"
    readonly property real _tipMaxWidth: {
        const f = tipMetrics.font;
        return tipMetrics.advanceWidth(root._tipRefLine);
    }
    readonly property string _nbsp: "\u00a0"
    // FIGURES NEVER SPLIT. A count and its noun ("13 pages"), "page 73",
    // "21 of 32", and a whole list of pages ("41, 44, 51 and 54") are glued
    // with no-break spaces before a cut is looked for; cuts happen only at
    // word spaces, so a figure can neither end a line without its noun nor
    // scatter its pages over two.
    function _glueFigures(text) {
        const nb = root._nbsp;
        let t = String(text);
        t = t.replace(/\b(pages?) (\d+(?:, \d+)*(?: and (?:\d+ more|\d+))?)/g,
                      m => m.replace(/ /g, nb));
        t = t.replace(/(\d) of (\d)/g, "$1" + nb + "of" + nb + "$2");
        t = t.replace(/(\d) (pictures?|pages?|images?|duplicates?|tokens?|placements?|later|more)\b/g,
                      "$1" + nb + "$2");
        return t;
    }
    // Where a line may be cut, in reading order of preference: after a
    // comma, before "and", after a dash, before the middle dot. `cut` is how
    // many of the separator's characters stay on the line, `resume` where
    // the next line starts.
    readonly property var _tipClauseSeps: [
        { sep: ", ", cut: 1, resume: 2 },
        { sep: " and ", cut: 0, resume: 1 },
        { sep: " — ", cut: 2, resume: 3 },
        { sep: " -- ", cut: 3, resume: 4 },
        { sep: " · ", cut: 0, resume: 1 }
    ]
    // One statement onto lines no wider than `_tipMaxWidth`: the LAST clause
    // boundary that fits, else the last word gap that fits, else the run as
    // it is (one unbreakable figure is still one line).
    function _breakLine(text) {
        const maxW = root._tipMaxWidth;
        const fits = t => tipMetrics.advanceWidth(t) <= maxW;
        const out = [];
        let rest = String(text).trim();
        while (rest.length > 0) {
            if (fits(rest)) { out.push(rest); break; }
            let cut = -1, resume = -1;
            const seps = root._tipClauseSeps;
            for (let k = 0; k < seps.length; ++k) {
                let i = rest.indexOf(seps[k].sep);
                while (i >= 0) {
                    const c = i + seps[k].cut;
                    if (c > cut && c > 0 && fits(rest.substring(0, c))) {
                        cut = c; resume = i + seps[k].resume;
                    }
                    i = rest.indexOf(seps[k].sep, i + 1);
                }
            }
            if (cut < 0) {
                let i = rest.indexOf(" ");
                while (i > 0 && fits(rest.substring(0, i))) {
                    cut = i; resume = i + 1;
                    i = rest.indexOf(" ", i + 1);
                }
            }
            if (cut < 0) { out.push(rest); break; }
            out.push(rest.substring(0, cut).trim());
            rest = rest.substring(resume).trim();
        }
        return out;
    }
    // A sentence or a note onto lines: every semicolon-joined statement is
    // its own line (that is where the loader's meaning breaks), each broken
    // further only if it must.
    function _tipLines(text) {
        const parts = root._glueFigures(text).split("; ");
        let out = [];
        for (let i = 0; i < parts.length; ++i)
            out = out.concat(root._breakLine(parts[i]));
        return out;
    }

    // ---- The pdf menu's facts ---------------------------------------------
    // What will ride, in the chip's own words. The chip publishes the FIGURES
    // (this property) and one WORD for the state, the menu lays them out as a
    // fixed table (LlmPdfMenu `facts`), and the ADVANCED lines -- duplicates
    // explained, mask-drawn figures, a truncation and why -- stay prose in a
    // tip beside it, because a reason is not a figure. Published as prose
    // ("12 pictures from 13 pages", "about 3 100 tokens") the panel would
    // change shape every time a slider moved a value: a sentence that gains a
    // digit reflows, and one that becomes "text only" collapses two lines into
    // one.
    //
    // -1 means "not known", which is not the same as 0: a pdf nobody has
    // looked inside yet has an unknown picture count, a pdf of vector art has
    // zero. The menu prints an em dash for the first and 0 for the second.
    // `state` is the one word that says which of those the reader is looking
    // at, so the zeros below it are never read as a failure.
    readonly property string _imgMode: String(root._a.imageMode || "embedded")
    readonly property var pdfFactFigures: {
        const unknown = ({ state: "", count: -1, pageSpan: -1,
                           pageCount: Math.max(0, Number(root._a.pageCount) || 0),
                           dupes: -1, tokens: -1 });
        if (!root._includeImages)
            return Object.assign(unknown, { state: "text only" });
        if (root._imagesPending || root._pending)
            return Object.assign(unknown, { state: "reading…" });
        if (!root._hasImgFacts)
            return Object.assign(unknown, { state: "not read" });
        return ({ state: root._imgCount === 0 ? "none"
                       : (root._imgMode === "pages" ? "pages" : "images"),
                  count: root._imgCount,
                  pageSpan: root._imgMode === "pages" ? root._imgCount : root._imgPageSpan,
                  pageCount: Math.max(0, Number(root._a.pageCount) || 0),
                  dupes: root._imgDupes,
                  tokens: root._tokensSoft(root._imgTokens) });
    }
    // The loader's REASONS, as lines, the zero case among them: "why does
    // nothing ride?" is a reason, not a figure, and the figures table can
    // only say 0. When the loader explains it, its own sentence is
    // what the user reads; when it does not, this file's fallback is the only
    // honest thing that can be said about a pdf whose figures are vector art.
    readonly property var pdfFactsAdvanced: {
        if (!root._includeImages || root._pending || !root._hasImgFacts)
            return [];
        if (root._imgCount === 0 && root._imgNote.length === 0)
            return root._tipLines("no images to send — this pdf draws its figures "
                                + "as vector art, which reaches the model as text");
        let lines = [];
        if (root._imgDupes > 0)
            lines = lines.concat(root._tipLines(root._plural(root._imgDupes, "duplicate") + " dropped"));
        if (root._imgNote.length > 0)
            lines = lines.concat(root._tipLines(root._imgNote));
        return lines;
    }

    function _mmss(ms) {
        const s = Math.max(0, Math.round((Number(ms) || 0) / 1000));
        const m = Math.floor(s / 60);
        const r = s % 60;
        return m + ":" + (r < 10 ? "0" : "") + r;
    }
    function _ext() {
        const n = root._name;
        const i = n.lastIndexOf(".");
        return i >= 0 ? n.substring(i + 1).toLowerCase() : "";
    }
    function _previewText() {
        const t = String(root._a.textContent || "");
        const lines = t.split("\n");
        return lines.length > 40 ? lines.slice(0, 40).join("\n") + "\n…"
                                 : t;
    }
    function _codePalette() {
        return {
            "kw": root.codeKwColor.toString(),
            "str": root.codeStrColor.toString(),
            "num": root.codeNumColor.toString(),
            "com": root.codeComColor.toString(),
            "fn": root.codeFnColor.toString(),
            "type": root.codeTypeColor.toString(),
            "op": root.codeOpColor.toString(),
            "var": root.codeVarColor.toString(),
            "punc": root.codePuncColor.toString()
        };
    }

    // Which rich preview this chip can offer. Null while pending or when the
    // data is not there (a loader that failed before producing anything): the
    // tip then falls back to its plain label.
    readonly property Component _tipContent: {
        if (root._pending)
            return null;
        switch (root._kind) {
        // The three pictorial kinds preview `_shot` or nothing (header). A
        // pdf never falls back to `images[0]`: that picture is page 1 only by
        // accident, and captioning it "page 1" would mislabel it.
        case "image": return root._shot.length > 0 ? imageTip : null;
        case "pdf":   return root._shot.length > 0 ? pdfTip : null;
        case "video": return root._shot.length > 0 ? videoTip : null;
        case "text":  return (root._a.textContent && root._a.textContent.length > 0) ? textTip : null;
        case "audio": return root._peaks.length > 0 ? audioTip : null;
        default:      return null;
        }
    }

    // ======================================================================
    // THE CHIP
    // ======================================================================
    ShadowBox {
        anchors.fill: parent
        baseRadius: root.radius
        surfaceColor: root.surfaceColor
        backgroundColor: root.fillColor
        bevelColor: root.bevelColor
        shadowColor: root.shadowColor
        bevelWidth: 1
        shadowWidth: 3
    }

    // The document silhouette: two left-aligned bars, the second shorter --
    // a paragraph and its last line. Low-left, so the × in the top-right
    // corner has the whole corner to itself.
    Column {
        id: silhouette
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.leftMargin: root.silhouetteLeft
        anchors.topMargin: root.silhouetteTop
        spacing: 4

        SkeletonBar {
            width: 26; height: 6
            radius: 3
            barColor: root.shadowColor
            groundColor: root.fillColor
            pulse: root._pending && !root._failed
        }
        SkeletonBar {
            width: 17; height: 6
            radius: 3
            barColor: root.shadowColor
            groundColor: root.fillColor
            pulse: root._pending && !root._failed
        }
    }

    // The failure is a mark BESIDE the silhouette, not a dialog: on top of it
    // the glyph would smother both bars; beside them the document stays
    // readable and the mark reads as its status. The chip
    // stays, the tip says why, the × is how it leaves.
    Text {
        anchors.left: silhouette.right
        anchors.leftMargin: 7
        anchors.verticalCenter: silhouette.verticalCenter
        visible: root._failed
        text: "\uF071"
        font.family: "Symbols Nerd Font"
        font.pixelSize: 13
        color: root.errColor
    }

    Text {
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 7
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width - 10
        text: root._name
        // Middle, not right: the extension is the one part of a long filename
        // that says what the thing is.
        elide: Text.ElideMiddle
        horizontalAlignment: Text.AlignHCenter
        color: root.mutedText
        font.family: root.fontFamily
        font.pixelSize: root.nameFontSize
    }

    MouseArea {
        id: chipHover
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        cursorShape: undefined   // clicks pass through: the cursor is what lies under it (a MouseArea owns an Arrow)
    }

    HoverTip {
        id: chipTip
        show: chipHover.containsMouse
        anchorItem: root
        overlayItem: root.overlayItem
        contentComponent: root._tipContent
        // The plain-label fallback: while pending the name; failed with no
        // preview, the reason.
        text: root._failed && !root._pending && root._tipContent === null
              ? (root._a.failReason || "cannot be attached")
              : root._name
        fontFamily: root.fontFamily
        surfaceColor: root.tipSurfaceColor
        bevelColor: root.bevelColor
        shadowColor: root.shadowColor
        textColor: root.primaryText
    }

    // ---- The control stack, top-right --------------------------------------
    // Remove on top, the picture toggle under it -- one column of controls,
    // revealed by the pointer and gone with it, so a chip at rest is a
    // document. Both marks share one reveal fraction (`_controlsF`): one
    // clock, and the two can never be caught half in and half out.
    //
    // BOTH MARKS SIT IN THE SAME 14x14 CELL, glyph centred. Anchoring two
    // Text items by their boxes would align the boxes and NOT the ink -- the
    // × and the picture glyph have different side bearings, and the pair
    // would come out 3.5 px off axis (measured). A fixed cell with the glyph
    // centred in it puts both inks on one vertical line.
    //
    // The stack's targets ABUT, they do not overlap: 4 px of horizontal slack
    // each side (a 10 px glyph is a small thing to hit), 2 px vertical, and a
    // 5 px gap between the two cells so the ×'s target ends before the
    // toggle's begins. An overlapping pair would hand half of one control's
    // area to the other, silently.
    readonly property bool _controlsShown: chipHover.containsMouse
        || closeArea.containsMouse || imageArea.containsMouse || root.menuOpen
    property real _controlsF: root._controlsShown ? 1 : 0
    Behavior on _controlsF { NumberAnimation { duration: root.controlRevealMs; easing.type: Easing.OutCubic } }

    Text {
        id: chipClose
        visible: root.removable
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 4
        anchors.rightMargin: 4
        width: root.controlCell
        height: root.controlCell
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: "\uF00D"
        font.family: "Symbols Nerd Font"
        font.pixelSize: 10
        color: Mix.c(root.faintText, root.errColor, chipClose._hoverF)
        property real _hoverF: closeArea.containsMouse ? 1 : 0
        Behavior on _hoverF { NumberAnimation { duration: root.controlRevealMs; easing.type: Easing.OutCubic } }
        opacity: root._controlsF

        MouseArea {
            id: closeArea
            anchors.fill: parent
            anchors.leftMargin: -4
            anchors.rightMargin: -4
            anchors.topMargin: -2
            anchors.bottomMargin: -2
            enabled: root.removable && chipClose.opacity > 0
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.removeRequested()
        }
    }

    // The pdf picture toggle: the stack's second item. Accent when the
    // pictures ride, faint when the model gets the text only. It pulses on
    // the skeleton's own 900 ms breath while the pictures it promises are
    // still being read out of the document, so a lit icon never claims
    // images that are not there.
    Text {
        id: imageToggle
        visible: root._canToggleImages
        anchors.top: chipClose.bottom
        anchors.topMargin: root.controlGap
        anchors.right: chipClose.right
        width: root.controlCell
        height: root.controlCell
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: "\uF03E"
        font.family: "Symbols Nerd Font"
        font.pixelSize: 10
        color: Mix.c(Mix.c(root.faintText, root.mutedText, imageToggle._hoverF),
                     Mix.c(root.accent, root.accentHover, imageToggle._hoverF),
                     imageToggle._onF)
        opacity: root._controlsF

        property real _hoverF: imageArea.containsMouse ? 1 : 0
        Behavior on _hoverF { NumberAnimation { duration: root.controlRevealMs; easing.type: Easing.OutCubic } }
        property real _onF: root._includeImages ? 1 : 0
        Behavior on _onF { NumberAnimation { duration: root.controlRevealMs; easing.type: Easing.OutCubic } }

        SequentialAnimation on scale {
            running: root._imagesPending && imageToggle.visible
            loops: Animation.Infinite
            NumberAnimation { to: 0.86; duration: root.pulseMs; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1.0; duration: root.pulseMs; easing.type: Easing.InOutSine }
        }

        MouseArea {
            id: imageArea
            anchors.fill: parent
            anchors.leftMargin: -4
            anchors.rightMargin: -4
            anchors.topMargin: -2
            anchors.bottomMargin: -2
            enabled: root._canToggleImages && imageToggle.opacity > 0
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            // Left flips the pictures; right opens their settings. One
            // glyph, both things it can do to the pictures.
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton)
                    root.menuRequested();
                else
                    root._toggleImages();
            }
        }

    }

    // ======================================================================
    // TIP CONTENT -- instantiated only while the tip arms (HoverTip's Loader)
    // ======================================================================

    // One rounded frame for every pictorial preview, fitted into 280×200.
    // `sourceSize` is the DECODE cap that keeps a huge photo from ballooning
    // memory. MEASURED: under PreserveAspectFit Qt decodes to the size that
    // COVERS the box -- and that is an UPSCALE for anything smaller than it,
    // so the loader's 240x135 thumb comes back as 356x200 and is then
    // "fitted" to 280x157, blurred by 17%. Under
    // Stretch the same cap only ever scales DOWN (240x135 stays 240x135, a
    // 1000x700 png becomes 280x196), so the fill mode is Stretch and the
    // aspect is kept by this item's own size, which is the decoded size
    // min-scaled into the box and never past 1 -- a 240 px thumb shows at
    // 240 px, 1:1, and a photo from an older message still fits.
    component TipShot: Item {
        id: shot
        property alias source: pic.source
        // Device px per logical px at the tip: everything
        // here that RASTERISES -- the decode, the mask layer, the item's own
        // layer -- multiplies its size by this, so the preview is sharp under
        // the mockup stage's zoom and on HiDPI. The LOGICAL fit stays 280x200.
        readonly property real _rs: Math.max(1, chipTip.renderScale)
        // The DISPLAY math is untouched by _rs on purpose: a capped decode
        // grows by _rs and the 280/200 fit shrinks it right back to the same
        // logical size, while a small image keeps fit 1 and its natural
        // logical size: only the decode resolution scales.
        readonly property real _fit: (pic.status === Image.Ready && pic.implicitWidth > 0 && pic.implicitHeight > 0)
            ? Math.min(1, root.previewMaxWidth / pic.implicitWidth, root.previewMaxHeight / pic.implicitHeight) : 0
        implicitWidth: pic.status === Image.Ready ? Math.round(pic.implicitWidth * shot._fit) : 96
        implicitHeight: pic.status === Image.Ready ? Math.round(pic.implicitHeight * shot._fit) : 64

        Image {
            id: pic
            anchors.fill: parent
            // Stretch, not PreserveAspectFit: see the component's note. The
            // item is already the picture's shape, so nothing stretches.
            fillMode: Image.Stretch
            sourceSize: Qt.size(root.previewMaxWidth * shot._rs, root.previewMaxHeight * shot._rs)
            asynchronous: true
            cache: false
        }
        // Rounded corners: the image is masked by a rounded rectangle
        // (radius 6 inside the tip's 8, so the two curves nest). Both layers
        // rasterise at renderScale-scaled resolution, so the corner curve is
        // cut in DEVICE pixels under any stage zoom (cut at logical resolution
        // and then scaled, it staircases).
        // MEASURED: MultiEffect's threshold is
        // a hard cut on this Qt -- maskSpreadAtMin only SHIFTS the cut, it
        // never softens it -- so the defaults stay and the resolution is the
        // whole fix.
        layer.enabled: true
        layer.smooth: true
        layer.textureSize: Qt.size(Math.max(1, Math.ceil(shot.width * shot._rs)),
                                   Math.max(1, Math.ceil(shot.height * shot._rs)))
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: shotMask
        }
        Rectangle {
            id: shotMask
            visible: false
            antialiasing: true
            layer.enabled: true
            layer.smooth: true
            layer.textureSize: Qt.size(Math.max(1, Math.ceil(shot.width * shot._rs)),
                                       Math.max(1, Math.ceil(shot.height * shot._rs)))
            anchors.fill: parent
            radius: 6
            color: "white"
        }
    }

    component TipCaption: Text {
        color: root.mutedText
        font.family: root.fontFamily
        font.pixelSize: 9
    }

    Component {
        id: imageTip
        TipShot { source: root._shot }
    }

    Component {
        id: pdfTip
        Column {
            spacing: 4
            // THE FIRST PAGE, always: the loader renders it for
            // every pdf, with the pictures on and with them off, so the
            // preview is the document rather than whichever picture happens
            // to be first in the payload.
            TipShot { source: root._shot }
            TipCaption {
                text: Number(root._a.pageCount) > 0
                      ? "page 1 of " + root._a.pageCount : "page 1"
            }
        }
    }

    Component {
        id: videoTip
        Column {
            spacing: 4
            TipShot { source: root._shot }
            // The frame count is said only while the frames are on the
            // object: the store may have stripped them from a sent message,
            // and "0 frames sent" would then be a non-fact under a preview
            // that plainly was sent.
            TipCaption {
                text: "video · "
                      + (root._pages.length > 0
                         ? root._pages.length + " frame"
                           + (root._pages.length === 1 ? "" : "s") + " sent · "
                         : "")
                      + root._mmss(root._a.durationMs)
            }
        }
    }

    Component {
        id: textTip
        Rectangle {
            implicitWidth: root.textPreviewWidth + 12
            implicitHeight: Math.min(root.textPreviewMaxHeight, codePreview.contentHeight + 12)
            radius: 6
            color: root.codeBgColor
            clip: true

            TextEdit {
                id: codePreview
                x: 6; y: 6
                width: root.textPreviewWidth
                readOnly: true
                enabled: false           // the tip takes no input
                textFormat: TextEdit.RichText
                wrapMode: TextEdit.Wrap
                color: root.codeTextColor
                font.family: root.monoFamily
                font.pixelSize: 10
                // Assigned, never bound: the preview is a snapshot of the
                // file and of the theme it was hovered in, and the tip dies
                // with the hover -- the next hover rebuilds it fresh.
                Component.onCompleted: {
                    codePreview.text = Md.codeHtml(root._previewText(), root._ext(),
                                                   root._codePalette(), root.monoFamily,
                                                   10, false, {});
                }
            }
        }
    }

    Component {
        id: audioTip
        Column {
            spacing: 4
            // The waveform: one bar per peak, mirrored around the midline --
            // each bar is centred vertically, so amplitude reads up AND down
            // the way every audio editor draws it.
            Item {
                id: wave
                implicitWidth: 200
                implicitHeight: 48
                Repeater {
                    model: root._peaks
                    Rectangle {
                        required property int index
                        required property var modelData
                        readonly property real _amp: Math.max(0, Math.min(1, Number(modelData) || 0))
                        x: wave.width * index / root._peaks.length
                        width: Math.max(1, wave.width / root._peaks.length - 1)
                        height: Math.max(2, _amp * (wave.height - 2))
                        anchors.verticalCenter: parent.verticalCenter
                        radius: width / 2
                        color: root.accent
                    }
                }
            }
            TipCaption {
                text: root._mmss(root._a.durationMs)
                      + (root._failed ? " · " + (root._a.failReason || "cannot be attached") : "")
            }
        }
    }
}
