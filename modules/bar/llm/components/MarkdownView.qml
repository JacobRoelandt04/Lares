pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "../../../common/theme"
import "../../../common/system"
import "../../../common/components"
import "../../../common/components/Markdown.js" as Md
import "../../../common/components/Mix.js" as Mix

// =============================================================================
// MarkdownView.qml
//
// A column of block delegates, one small document each. This shape is not a
// preference, it is the measurement:
//
//   textFormat: MarkdownText re-parses the WHOLE document on every append --
//   1.19 ms at 10 KB, 5.30 ms at 30 KB on this machine -- and ablating
//   visibility, wrap, a fixed height and the Flickable ancestor changed none
//   of it. Finished sibling documents, on the other hand, cost essentially
//   nothing: 200 finished blocks above a live one cost the same per token as
//   zero of them.
//
// So streaming here is O(tail), not O(document):
//
//   `_stableLen` is how far into `source` everything is FINAL. Each flush
//   parses only `source.substring(_stableLen)`, updates the provisional rows
//   at the end of the model, and then freezes every leading block the parser
//   promises cannot change (`complete`) AND that has source after it -- the
//   second half of that test is what keeps a frozen block's offsets identical
//   to a one-shot parse of the finished document, since a block's `end`
//   swallows the blank lines that follow it and those may not have arrived.
//   A frozen row is never written again, so its TextEdit is never re-parsed.
//
// Everything else here follows from that:
//
//   * `_queued` + `Qt.callLater`: tokens arrive far faster than frames, so
//     the model is touched once per frame, not once per token. That batching
//     is for a STREAM and only for a stream. A wholesale source change -- a
//     conversation switch, a delegate re-used for another message, a rebuild
//     -- is flushed SYNCHRONOUSLY, inside the assignment's own call stack
//     (`Md.isAppend` tells the two apart from the flushed length and its last
//     32 characters). Deferring that one would paint a switched-to
//     conversation as a column of headers with no text under them for a
//     frame: the queued call and the render request are both posted events,
//     so which of them the loop reaches first is the scheduler's business,
//     and the only way to win is to have the blocks built before returning.
//     It costs nothing: a flush parses the whole tail in one go either way,
//     so this moves the same work one frame earlier, it does not add any.
//   * Nothing happens while `!visible`; a `dirty` flag replays on show. A
//     hidden view that kept syncing is what caused this project's
//     255 ms/frame download lag.
//   * NOTHING inside an answer scrolls. A table or a code block in its own
//     horizontal Flickable would swallow the wheel on its
//     way to the transcript and hide half the content behind a scroll the
//     reader has no reason to look for. So a code block wraps
//     (with a hanging indent, see CodeBlock) and a table is laid out to the
//     width it is given, its cells wrapping, its columns fitted by
//     `Md.fitColumns` so the row always ends exactly at the container's edge.
//     Neither can overflow, so neither is ever truncated or elided.
//   * Table cell HTML and per-column MEASUREMENTS are computed in the flush,
//     not in a delegate binding: a binding that reads a Theme-derived colour
//     re-runs on every frame of the theme crossfade, which would re-parse
//     every cell 25 times per switch. The measurements are in pixels of text,
//     independent of the width, so only the cheap fit is redone on a resize.
//   * A colour that has to be written into HTML (inline-code fill, links,
//     syntax) makes that document a snapshot of the theme it was built in, so
//     the view re-bakes once per `Theme.mode` change, after the fade has
//     landed. Body text carries NO colour in its HTML -- it inherits the
//     TextEdit's `color`, which is a live Theme binding.
//   * THAT RE-BAKE OBEYS THE VIEWPORT, and it re-bakes IN PLACE. Two laws,
//     both from the same measurement. `visible` does not
//     say whether a view is on screen inside the transcript -- a turn 4000 px
//     above the fold is visible: true, because it sits in a Column and not in
//     a viewport -- so a switch would re-bake every document in the history
//     in ONE frame: 785 ms at eight turns and 1619 ms at sixteen, measured,
//     of which two documents are on screen. A view off screen latches
//     `themeDirty` and re-bakes when the reader scrolls to it, asking
//     `scrollHost` for the band (LlmTranscript publishes it) and listening to
//     its `viewportSerial` only while it is waiting.
//     And a re-bake KEEPS THE ROWS (`_rebakeAll`): the source has not changed,
//     so the parser returns the same blocks and `_put` writes only what
//     differs -- the prose and table rows take the new colours, and a code row,
//     whose model entry is source text rather than a document, notifies
//     nothing at all. Its CodeBlock then re-bakes ITSELF, on its own viewport
//     test, keeping its old document until it does. Clearing the model instead
//     (what `_rebuildAll` does) destroys every
//     CodeBlock delegate and builds new ones with empty documents: the 90 ms
//     of code that dominated the switch, plus a column that collapses to
//     nothing under the reader for a frame.
//   * No `implicitWidth` of a TextEdit is ever read (one read flips
//     QQuickTextEdit into requireImplicitWidth for good, 0.11 ms -> 200 ms per
//     append); every edit is sized from the column and reports height through
//     `contentHeight`.
//   * `font.pixelSize` is never bound to something that moves on a view
//     switch. The transcript picks one density; a change here is a full
//     rebuild, deliberately.
//   * A FLUSH NEVER NESTS, and the first one waits for the object to be
//     complete. A view created with its source AND a non-default
//     family bound (a transcript built with its turns in hand) flushes from
//     `onSourceChanged` while the family's binding is still unevaluated;
//     `_opt()` reads it, the read evaluates it, the change handler runs a
//     rebuild INSIDE the running flush, and the outer flush then adds its
//     freeze counts on top of the inner one's -- five rows for three blocks,
//     the last of them the source's final five characters. So the flush runs
//     from Component.onCompleted (still inside the creating call stack, so
//     the synchronous-build law holds) and a request that arrives while one
//     is running is replayed after it, never nested.
//   * THE FAMILY IS IN THE CSS. `bodyFontFamily` is the document's one face
//     -- headings, prose, lists, quotes, table cells -- and Markdown.js
//     writes it into every block's style, because a rich-text document does
//     not reliably inherit the edit's `font.family` across a rebuild: a block
//     whose CSS names no family renders in whatever the edit had last. Code
//     is `monoFamily`, written the same way.
//
// CROSS-BLOCK SELECTION
// -------------------------------
// Every block is its own TextEdit, so native selection dies at each block's
// edge. The fix is a drag layer over the whole column: one MouseArea (left
// button only) that maps the drag through the block list -- `positionAt` on
// the endpoint blocks, `selectAll` on everything between, `select(a, b)` per
// TextEdit -- so one drag sweeps paragraphs, lists and code blocks alike.
// Within one block the layer reproduces native behaviour through the same
// positionAt/select path, so a click-and-drag inside a paragraph reads
// exactly as native. Presses over a link or over a code block's header strip
// are NOT taken (mouse.accepted = false): the TextEdit underneath handles the
// link and the copy button keeps its click.
//
// The copy shortcuts live HERE, not on a global Shortcut that would clash
// with the composer: the layer takes focus on press, and Ctrl+C copies the
// selection as plain text (per-block selected text, blank lines between)
// while Ctrl+Shift+C copies the SOURCE of every block the selection touches
// (each row stores its absolute `srcStart`/`srcEnd` offsets, so the copy is
// the verbatim substring -- whole blocks, exactly as the model wrote them).
// Blocks with no TextEdit (tables and images) contribute their source's
// plain text to Ctrl+C and show a selection wash instead of a highlight.
// Both copies go through `Md.copyText`: a TextEdit's `selectedText` separates
// paragraphs with U+2029 and soft breaks with U+2028 (a code block is one
// paragraph per line, so a three-line selection carried two of them into the
// user's editor as "unusual line terminators"), and the normaliser is the one
// place that turns every terminator into `\n`. See Markdown.js.
//
// HOVER DOES NOT PASS THROUGH A MOUSEAREA (measured on Qt 6.11.2).
// A drag layer carrying `hoverEnabled: true` for the link cursor would rest on
// the belief that hover "still reaches HoverHandlers below". It does not: a
// legacy hover item that accepts the hover ends the sweep for every sibling
// BENEATH it, so CodeBlock's HoverHandler -- and the copy button's own
// MouseArea inside it -- would never hover, and the button, which fades in on
// hover, would never appear at all. A non-blocking HoverHandler on the layer
// starves them the same way. What does stay hovered is an ANCESTOR's handler
// (that is how LlmTurn's footer works), so the pointer is tracked by a
// HoverHandler on this view's ROOT: it reads the position for the link
// cursor, and it hands its cursor back (`undefined` resets it) over a code
// block's lid so the button's own hand shows through. The layer keeps no hover
// of its own; presses it does not want fall through.
//
// A drag that reaches the edge of the SCROLLING AREA pushes it: the layer
// hands its host (`scrollHost`, the transcript) the pointer's SCENE position
// on every move, and the host's SelectionAutoScroll ticks the viewport while
// the pointer stays past an edge -- calling back into `autoScrollReapply()`,
// which re-derives the moving end from that same scene point. The pointer is
// still; the document under it is not; so the selection grows. Without it a
// drag held below the bottom edge would select to the last VISIBLE line and
// stop there, because a pointer that is not moving sends no events and
// nothing is left to ask for more text.
//
// A RULE IS DECORATION, AND DECORATION IS NOT TEXT
// -----------------------------------------------
// A thematic break is the one block that says nothing: it is a mark between
// two things, not a thing. So it is never selected, never washed, and never
// contributes a "---" to a plain-text copy. It also must not INTERRUPT a
// sweep across it -- the endpoints are snapped off it towards the anchor
// (`_snapEnd`), so as the pointer crosses the rule the selection simply
// stands at the last real block and then continues into the next one. A press
// that lands on a rule anchors on whichever real block the point is nearer,
// at that block's near edge, so a drag can start there and still select only
// text. The markdown copy is the source span and therefore still carries the
// break between two selected paragraphs: that is the document, verbatim, and
// dropping it would rewrite it. (A setext heading's underline is not a rule
// at all -- Markdown.js folds both lines into one `head` block -- so it comes
// out whole on both paths.)
//
// TWO ORTHOGONAL LAYERS
// ----------------------------------
// `searchQuery`: a background-style highlight woven into the shown html.
// Every row stores its pre-highlight `base`; a query change re-derives shown
// html from base (string work only -- no parse, no freeze change, no scroll),
// and an empty query costs the append path one length check. `_viewScale`:
// under a zoomed stage the prose edits render at font x scale inside an
// inverse transform so colour-emoji bitmaps stay sharp; at scale 1 everything
// is identity. Both are documented at their property blocks below.
// =============================================================================
Item {
    id: root

    // ---- Content ----
    property string source: ""        // markdown; may grow by append only
    property bool   streaming: false  // the LAST block may still change

    // ---- Typography ----
    property string bodyFontFamily: "Inter"
    property string monoFamily: "Consolas"
    property int    fontPixelSize: 12
    property int    codeFontPixelSize: 12
    // The prose line pitch, as a multiple of the face's own. Qt's rich text
    // honours CSS `line-height` (proportional to the NATURAL pitch, measured:
    // Exo 2 at 13 px lays out at 16.00 px and at 115 % at 18.39 px), and a
    // TextEdit has no `lineHeight` property of its own -- `Text` does, TextEdit
    // does not -- so the only way to set it is in the document. It goes on a
    // wrapper div rather than into the per-block CSS because the per-block CSS
    // is Markdown.js's and this is the VIEW's reading measure; Qt inherits
    // line-height through nested divs (measured), so one wrapper sets every
    // block inside it. 1 emits no wrapper at all, so the default costs nothing
    // and renders the identical document. Code keeps its own pitch: a code
    // block is a listing, not prose.
    property real   lineHeight: 1.0
    readonly property string _lhOpen: root.lineHeight === 1 ? ""
        : "<div style=\"line-height:" + Math.round(root.lineHeight * 100)
          + "%; margin:0px;\">"
    readonly property string _lhClose: root.lineHeight === 1 ? "" : "</div>"
    property bool   codeBold: true
    property real   blockSpacing: 8
    property real   headingSpacing: 12    // extra space ABOVE a heading
    // How much bigger than the body a heading is, as a multiplier on the
    // per-level steps in Markdown.js (h1 +50 % ... h4 +5 %): 1 is the table
    // as written, 0 sets every heading at body size, 2 doubles the steps.
    property real   headingScale: 1.0
    // The furniture's numbers: the code box's inner padding and lid height,
    // the quote's bar and the inset of its text, a table's cell padding, and
    // the inset an image sits at inside its box.
    property real   codePadding: 10
    property real   codeHeaderHeight: 26
    property real   quoteInset: 10
    property real   quoteBarWidth: 3
    property real   tableCellPadH: 10
    property real   tableCellPadV: 6
    property real   imageInset: 6

    // ---- Palette ----
    property color textColor: Theme.textPrimary
    property color mutedColor: Theme.textMuted
    property color faintColor: Theme.textFaint
    property color linkColor: Theme.accent
    property color surfaceColor: Theme.listBox    // what the blocks sit on
    property color codeBgColor: Theme.terminalBg
    property color codeBevelColor: Theme.bevel
    property color codeShadowColor: Theme.border
    property color codeHeaderColor: Theme.headerBox
    property color quoteBarColor: Theme.accent
    property color tableLineColor: Theme.border
    property color tableHeadColor: Theme.headerBox
    property color inlineCodeBgColor: Theme.headerBox
    property real  codeRadius: 10
    property bool  showImages: true
    // Formulas (`$..$`, `$$..$$`, `\(..\)`, `\[..\]`): MathRender draws them as a mask and MathInk tints
    // it with `textColor`. The sizes are the formula's font size over the body's.
    property bool  showMath: true
    property real  mathInlineScale: 1.0
    property real  mathDisplayScale: 1.2
    property real  mathDisplayPad: 4
    // The transparent image a formula's place is held with (MathOverlays draws over it). A probe puts an
    // opaque one here to see where the placeholder really sits.
    property url   mathBlankUrl: Qt.resolvedUrl("math_blank.png")

    // ---- Extras (defaults chosen so a host that ignores them sees exactly
    //      the palette above). Everything a nested component needs is a
    //      property HERE, so the popup can pass one palette down.
    property color caretColor: Theme.accent
    property color selectionColor: Theme.terminalSelection
    property color selectionTextColor: Theme.terminalSelectionText
    property color tableBgColor: Theme.listBox
    property color tableBevelColor: Theme.bevel
    property color tableShadowColor: Theme.border
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
    property color buttonPlateauColor: Theme.buttonPlateau
    property color buttonPlateauHoverColor: Theme.buttonPlateauHover
    property color buttonBevelColor: Theme.buttonBevel
    property color buttonShadowColor: Theme.buttonShadow
    property bool  codeShowHeader: true
    property real  tableRadius: 10

    // ---- Search highlight ----
    // Case-insensitive substring, background-style, in PROSE blocks (para,
    // head, list, quote). Empty costs the streaming path nothing: `_put`
    // checks one string length per row it writes, and no binding reads the
    // query. A change re-derives every prose row's html from its stored
    // `base`, so frozen blocks stay frozen -- never re-parsed, offsets
    // untouched -- and the viewport is never moved for a match. The colour is
    // an OPAQUE mix (accent over the ground) rather than an alpha wash,
    // because it is baked into the HTML; both ends are live Theme bindings,
    // so the once-per-theme-switch rebuild re-bakes it on the new palette.
    property string searchQuery: ""
    property color  searchHighlightColor: Mix.c(root.surfaceColor, root.linkColor, 0.35)

    // ---- Render scale (emoji sharpness under a zoomed stage) ----
    // Device px per logical px at this view, measured the way HoverTip does:
    // two scene-mapped points a unit apart times the screen's ratio. When it
    // differs from 1, every prose/quote TextEdit renders its document at
    // font x scale inside an inversely scaled wrapper, so colour-emoji bitmap
    // glyphs are picked at the size they are SHOWN at instead of being
    // upscaled from the logical size. Regular text is distance-field-rendered
    // and sharp either way. At scale 1 -- the real bar -- the transform is
    // identity, the CSS sizes are the logical ones, and nothing extra runs
    // per append. Measured on completion and on show; a host whose zoom moves
    // afterwards calls `remeasureRenderScale()`.
    property real _viewScale: 1
    function remeasureRenderScale() {
        const p0 = root.mapToItem(null, 0, 0);
        const p1 = root.mapToItem(null, 1, 0);
        // times the WINDOW's pixel ratio (the attached Screen's is the integer wl_output scale at a fractional Hyprland scale)
        const win = root.Window.window;
        let s = Math.hypot(p1.x - p0.x, p1.y - p0.y) * (win && win.devicePixelRatio > 0 ? win.devicePixelRatio : 1);
        if (!isFinite(s) || s <= 0 || Math.abs(s - 1) < 0.01)
            s = 1;
        if (s !== root._viewScale)
            root._viewScale = s;           // on_ViewScaleChanged rebuilds
    }
    on_ViewScaleChanged: root._rebuildAll()

    // ---- Output ----
    signal linkActivated(string url)
    readonly property int blockCount: _blocks.count
    // How many times this view has re-baked its documents for a theme change.
    // Published because "a view off screen does
    // not re-bake until it is scrolled to" is a claim about this number, and a
    // probe cannot reach the state behind a private id.
    readonly property int bakes: _st.bakes
    // The html one block was built with, for the same reason: the family
    // law ("the font family is in the generated CSS") is a fact about this
    // string, and a probe cannot reach the model behind a private id.
    function htmlOf(i) {
        return i >= 0 && i < _blocks.count ? _blocks.get(i).html : "";
    }
    // The kind the parser gave one block, for the same reason: "the rule is
    // decoration" is a claim about a block of kind "rule", and a probe cannot
    // reach the model behind a private id to check which block that is.
    function payloadOf(i) {
        return i >= 0 && i < _blocks.count ? _blocks.get(i).payload : "";
    }
    // The delegate of block i (a probe walks it for the overlays).
    function blockItem(i) {
        return _rep.itemAt(i);
    }
    function kindOf(i) {
        return i >= 0 && i < _blocks.count ? _blocks.get(i).kind : "";
    }

    function copyText() {
        Quickshell.clipboardText = Md.copyText(Md.plainText(root.source));
    }

    // The scrolling area a selection drag may push against: anything with
    // `autoScrollBegin(owner)` / `autoScrollAt(sceneY)` / `autoScrollEnd()`.
    // Null is a view that is not inside one (a harness, a fixed-height host),
    // and it simply never scrolls. Duck-typed, so `var`: what a host IS varies
    // (the transcript here, a composer elsewhere) and only those three
    // functions are the contract. See SelectionAutoScroll.
    property var scrollHost: null

    // ---- Cross-block selection ------------------------------------------
    // `selectable` turns the whole drag layer off (a host that wants inert
    // text); `crossSelectEnabled` gates only the multi-block sweep.
    // `selLo`/`selHi` are the touched
    // block range while a selection stands (-1 otherwise) -- the delegates
    // read them for the wash on blocks that have no TextEdit to highlight.
    property bool selectable: true
    property bool crossSelectEnabled: true
    property int selLo: -1
    property int selHi: -1

    // The block index at a view-local y: the first block whose bottom edge is
    // below it, clamped to the ends -- so a drag past either edge selects to
    // the end rather than falling off the list.
    function blockAt(y) {
        for (let i = 0; i < _blocks.count; ++i) {
            const it = _rep.itemAt(i);
            if (it && y < it.y + it.height)
                return i;
        }
        return _blocks.count - 1;
    }
    // The block's rectangle in view coordinates, for probes and hosts.
    function blockRect(i) {
        const it = _rep.itemAt(i);
        return it ? Qt.rect(it.x, it.y, it.width, it.height) : null;
    }

    // ---- The rule takes no part in a selection ---------------------------
    function _isRule(i) {
        return i >= 0 && i < _blocks.count && _blocks.get(i).kind === "rule";
    }
    // The nearest block that is not a rule, walking from `b` TOWARDS `anchor`
    // -- so the moving end of a drag that is over a rule rests on the last
    // real block it passed, and the sweep continues the moment it reaches the
    // next one. -1 when there is nothing but rules that way.
    function _snapEnd(b, anchor) {
        if (b < 0 || !root._isRule(b))
            return b;
        const step = b > anchor ? -1 : 1;
        for (let i = b + step; i >= 0 && i < _blocks.count; i += step)
            if (!root._isRule(i))
                return i;
        return -1;
    }
    // A press on a rule anchors on the real block it is NEAREST, at that
    // block's near edge: above the rule's middle, the end of the block above;
    // below it, the start of the block below. Returns [block, atEnd]; block is
    // -1 when the document is nothing but rules.
    function _anchorOnRule(b, y) {
        const r = root.blockRect(b);
        const up = !!r && y < r.y + r.height / 2;
        const m = root._snapEnd(b, up ? -1 : _blocks.count);
        if (m >= 0)
            return [m, up];
        return [root._snapEnd(b, up ? _blocks.count : -1), !up];
    }
    // The position at a block's near or far edge. A block with no TextEdit
    // (a table, an image) has no positions, and -1 is the whole-block reading
    // the endpoint pair already uses for those.
    function _edgePos(e, atEnd) {
        return e ? (atEnd ? e.length : 0) : -1;
    }

    // The TextEdit inside block i, found by walking the loaded delegate: the
    // prose/quote edits and CodeBlock's body are all plain TextEdits, and
// finding them generically is what keeps this view independent of
// CodeBlock's internals. Null for a table, image or rule.
    function _findEdit(item) {
        if (!item)
            return null;
        if (item.selectByMouse !== undefined && item.readOnly !== undefined
            && typeof item.positionAt === "function")
            return item;
        for (let k = 0; k < item.children.length; ++k) {
            const e = root._findEdit(item.children[k]);
            if (e)
                return e;
        }
        return null;
    }
    // Untyped on purpose: itemAt returns a QQuickItem and the delegate's
    // extra properties are only visible through a var access.
    function _loadedOf(it) {
        const d = it;
        return d && d.loadedItem !== undefined ? d.loadedItem : null;
    }
    function _editOf(i) {
        return root._findEdit(root._loadedOf(_rep.itemAt(i)));
    }

    function clearSelection() {
        for (let i = 0; i < _blocks.count; ++i) {
            const e = root._editOf(i);
            if (e && e.selectionStart !== e.selectionEnd)
                e.deselect();
        }
        _selSt.active = false;
        _selSt.aBlock = -1;
        _selSt.bBlock = -1;
        root.selLo = -1;
        root.selHi = -1;
    }

    // Selection as TEXT: the per-block selected plain text, blank lines
    // between blocks. A block with no TextEdit contributes the plain text of
    // its source slice.
    function selectedPlainText() {
        if (!_selSt.active)
            return "";
        const lo = Math.min(_selSt.aBlock, _selSt.bBlock);
        const hi = Math.max(_selSt.aBlock, _selSt.bBlock);
        const parts = [];
        for (let i = lo; i <= hi; ++i) {
            const e = root._editOf(i);
            if (e) {
                // Paragraph and line separators to `\n`, the ZWSP of an
                // empty code line gone -- see Md.copyText.
                const t = root._withFormulas(i, e, Md.copyText(e.selectedText));
                if (t.length > 0)
                    parts.push(t);
            } else if (i >= 0 && i < _blocks.count && !root._isRule(i)) {
                // A rule is skipped, not rendered as "---": the endpoints can
                // never be one, so this only ever fires for a rule the sweep
                // passed OVER, and a break is not text the reader selected.
                const r = _blocks.get(i);
                const t = Md.plainText(root.source.substring(r.srcStart, r.srcEnd)).trim();
                if (t.length > 0)
                    parts.push(t);
            }
        }
        return parts.join("\n\n");
    }

    // A selection through a sentence with a formula carries one U+FFFC for each (the placeholder image): the
    // formula's own source goes there, `$..$`. `pre` counts the images before the selection's start.
    function _withFormulas(i, e, t) {
        if (t.indexOf("\ufffc") < 0)
            return t;
        const recs = root._payload(_blocks.get(i).payload).m || [];
        const byN = {};
        for (let k = 0; k < recs.length; k++)
            byN[recs[k].n] = recs[k].t;
        let pre = 0;
        const head = e.getText(0, Math.min(e.selectionStart, e.selectionEnd));
        for (let q = head.indexOf("\ufffc"); q >= 0; q = head.indexOf("\ufffc", q + 1))
            pre++;
        let seen = 0;
        return t.replace(/\ufffc/g, () => {
            const f = byN[pre + seen++];
            return f === undefined ? "" : "$" + f + "$";
        });
    }

    // Selection as MARKDOWN: the source substring of every block the
    // selection touches -- whole blocks, verbatim, because a block's `end`
    // swallows the blank lines after it and equals the next block's `start`.
    // Only the trailing whitespace of the last block is trimmed.
    function selectedMarkdown() {
        if (!_selSt.active)
            return "";
        const lo = Math.min(_selSt.aBlock, _selSt.bBlock);
        const hi = Math.max(_selSt.aBlock, _selSt.bBlock);
        if (lo < 0 || hi >= _blocks.count)
            return "";
        return Md.copyText(root.source.substring(_blocks.get(lo).srcStart,
                                                 _blocks.get(hi).srcEnd)).replace(/\s+$/, "");
    }

    function copySelection(asMarkdown) {
        const t = asMarkdown ? root.selectedMarkdown() : root.selectedPlainText();
        if (t.length > 0)
            Quickshell.clipboardText = t;
        return t.length > 0;
    }

    // The shortcuts live on the view and fire only while it has focus (the
    // drag layer takes focus on press), so the composer's field never sees
    // them and no global Shortcut exists to clash with it.
    Keys.onPressed: (e) => {
        if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_C && _selSt.active) {
            root.copySelection((e.modifiers & Qt.ShiftModifier) !== 0);
            e.accepted = true;
        } else if (e.key === Qt.Key_Escape && _selSt.active) {
            root.clearSelection();
            e.accepted = true;
        }
    }

    // implicitWidth stays 0: the host gives the width. Deriving it from a
    // TextEdit is the one thing that must never happen here.
    implicitHeight: _col.implicitHeight

    // =========================================================================
    // Streaming state
    // =========================================================================
    ListModel { id: _blocks }   // roles: kind, html, base, code, lang, payload,
                                //        complete, srcStart, srcEnd (absolute
                                //        source offsets). `base` is the html
                                //        BEFORE the search highlight; `html`
                                //        is what the delegate shows.

    QtObject {
        id: _st
        property int  stableLen: 0     // source is FINAL below this offset
        property int  frozen: 0        // rows [0, frozen) are never written again
        property bool queued: false
        property bool dirty: true
        property bool hlDirty: false   // the query changed while hidden
        // The theme changed while this view was off screen. Separate from
        // `dirty`, which is about the SOURCE: a source replay re-parses what
        // arrived, and with the source unchanged that is a no-op, so a theme
        // re-bake that borrowed it would simply be lost.
        property bool themeDirty: false
        property int  bakes: 0
        // Nothing is flushed before the object is complete (see the header:
        // a binding evaluated mid-flush re-entered it), and a flush never
        // nests: a request that arrives while one runs is replayed after.
        property bool completed: false
        property bool flushing: false
        property bool flushAfter: false
        property bool rebuildAfter: false
        // A re-bake deferred by a running flush stays a RE-BAKE. Borrowing
        // `rebuildAfter` for it would answer a theme change with a full
        // rebuild -- the model cleared, every CodeBlock delegate destroyed and
        // rebuilt empty -- which is the one thing `_rebakeAll` exists to
        // avoid.
        property bool rebakeAfter: false
        // The last 32 characters of the frozen region. A host that re-uses this
        // item for a different message replaces `source` wholesale; comparing
        // the boundary is O(32) per flush where comparing the whole prefix
        // would be O(document) per token.
        property string fence: ""
        // The same trick over the WHOLE flushed source, which is what tells an
        // append from a replacement (Md.isAppend) and therefore a stream from
        // a switch. Separate from `fence`, which measures the FROZEN region:
        // a document can be flushed with nothing frozen yet.
        property int    srcLen: 0
        property string srcFence: ""
    }

    // The selection's endpoints: block index + character position within that
    // block's TextEdit (-1 position = the whole block, the reading a table or
    // image endpoint gets). `a` is the anchor (where the press landed), `b`
    // the moving end.
    QtObject {
        id: _selSt
        property bool active: false
        property bool dragging: false
        property int  aBlock: -1
        property int  aPos: -1
        property int  bBlock: -1
        property int  bPos: -1
    }

    // Re-derive every block's TextEdit selection from the endpoint pair. The
    // writes are imperative -- select() is a call, not a binding -- so this
    // runs once per drag move, not once per frame.
    function _applySel() {
        const lo = Math.min(_selSt.aBlock, _selSt.bBlock);
        const hi = Math.max(_selSt.aBlock, _selSt.bBlock);
        const loPos = _selSt.aBlock <= _selSt.bBlock ? _selSt.aPos : _selSt.bPos;
        const hiPos = _selSt.aBlock <= _selSt.bBlock ? _selSt.bPos : _selSt.aPos;
        for (let i = 0; i < _blocks.count; ++i) {
            const e = root._editOf(i);
            if (!e)
                continue;
            if (!_selSt.active || i < lo || i > hi) {
                if (e.selectionStart !== e.selectionEnd)
                    e.deselect();
            } else if (lo === hi) {
                const p1 = Math.max(0, Math.min(loPos, hiPos));
                const p2 = Math.max(loPos, hiPos);
                e.select(p1, p2 < 0 ? p1 : p2);
            } else if (i === lo) {
                e.select(loPos < 0 ? 0 : loPos, e.length);
            } else if (i === hi) {
                e.select(0, hiPos < 0 ? e.length : hiPos);
            } else {
                e.selectAll();
            }
        }
        root.selLo = _selSt.active ? lo : -1;
        root.selHi = _selSt.active ? hi : -1;
    }

    onSourceChanged: root._schedule()
    onStreamingChanged: root._schedule()   // the tail can be frozen once it stops
    onVisibleChanged: {
        if (root.visible) {
            root.remeasureRenderScale();
            if (_st.dirty) root._schedule();
            if (_st.hlDirty) root._reapplyHighlight();
            if (_st.themeDirty) root._themeRebake();
        }
    }
    Component.onCompleted: {
        root.remeasureRenderScale();       // before the first flush, so the
                                           // CSS is baked at the right size
        _st.completed = true;
        root._schedule();
    }

    // Re-derive every prose row's shown html from its stored base. No parse,
    // no offsets, no freeze-state change -- string work only, and only when a
    // query exists on at least one side of the change.
    onSearchQueryChanged: root._reapplyHighlight()
    // The highlight colour is a MIX of two Theme tokens (see its property), so
    // it does not change once per switch -- it changes on EVERY FRAME of the
    // crossfade. Re-deriving every prose row's html there, in every view with
    // a query, 25 times per switch, is the same bill this file pays once at
    // the settle; so it rides the settle timer, and `_rebakeAll` re-derives
    // the highlight as it goes. A host that writes this colour for its own
    // reasons sees it land one settle later, which is a colour, not a layout.
    function _reapplyHighlight() {
        if (!root.visible) { _st.hlDirty = true; return; }
        _st.hlDirty = false;
        const q = root.searchQuery;
        const col = q.length > 0 ? root.searchHighlightColor.toString() : "";
        for (let i = 0; i < _blocks.count; ++i) {
            const r = _blocks.get(i);
            if (r.base.length === 0)
                continue;                  // code, table, image, rule
            const h = q.length > 0 ? Md.highlightHtml(r.base, q, col) : r.base;
            if (r.html !== h)
                _blocks.setProperty(i, "html", h);
        }
    }

    // A density or family change invalidates every document that was built.
    // Rare and deliberate: the law is that the transcript picks ONE density.
    onBodyFontFamilyChanged: root._rebuildAll()
    onHeadingScaleChanged: root._rebuildAll()
    onFontPixelSizeChanged: root._rebuildAll()
    onMonoFamilyChanged: root._rebuildAll()
    onCodeFontPixelSizeChanged: root._rebuildAll()
    onShowImagesChanged: root._rebuildAll()

    // ---- The theme re-bake ------------------------------------------------
    //
    // A colour that had to be written INTO the html (a link, an inline code
    // fill, a table cell) makes that document a snapshot of the theme it was
    // built in, so it is re-baked once per `Theme.mode` change, after the
    // crossfade has landed: baking at the START of the switch would freeze
    // the colours the theme is leaving.
    //
    // Once per switch, and only IF THIS VIEW IS ON SCREEN. `visible` does not
    // answer that inside the transcript -- a turn 4000 px above the fold is
    // visible: true, it is in a Column, not in a viewport -- so a
    // switch would re-bake the whole history in one frame: 727 ms at eight
    // turns, measured. A view that is off screen latches `themeDirty` and
    // re-bakes when it scrolls in (the transcript's `viewportSerial`), which
    // is the same replay `dirty` has, widened from "shown" to
    // "shown or scrolled to".
    // `settled` is Theme's word for "the tokens are final": the lerp path
    // says it when its fade lands, the snapshot path the moment the tokens
    // are written, behind its picture. Either way the bake lands once, on
    // the palette that will stay -- which a timer on fadeMs could only guess.
    Connections {
        target: Theme
        function onSettled() { root._themeRebake(); }
    }
    Connections {
        target: root.scrollHost
        // Only while this view is actually waiting: the band ticks for every
        // document in the history and most of them have nothing to do.
        enabled: _st.themeDirty
        ignoreUnknownSignals: true
        function onViewportSerialChanged() { root._themeRebake(); }
    }
    function _themeRebake() {
        if (!root.visible || !root._onScreen()) { _st.themeDirty = true; return; }
        _st.themeDirty = false;
        root._rebakeAll();
    }

    // "Is any part of me on screen", asked of the host that owns the viewport
    // (`scrollHost.viewportBand()`, scene coordinates, already grown by its
    // own margin). A view with no host -- a harness, a fixed-height panel --
    // is on screen.
    function _onScreen() {
        const h = root.scrollHost;
        if (!h || typeof h.viewportBand !== "function")
            return true;
        const b = h.viewportBand();
        if (!b || !isFinite(b.top) || !isFinite(b.bottom))
            return true;
        const p = root.mapToItem(null, 0, 0);
        if (!p || !isFinite(p.y))
            return true;
        return p.y < b.bottom && p.y + root.height > b.top;
    }

    function _reset() {
        _blocks.clear();
        _st.stableLen = 0;
        _st.frozen = 0;
        _st.fence = "";
        _st.srcLen = 0;
        _st.srcFence = "";
    }

    function _rebuildAll() {
        if (_st.flushing) { _st.rebuildAfter = true; return; }
        root._reset();
        root._schedule();
    }

    // A re-bake is a rebuild that KEEPS THE ROWS. The source has not changed,
    // so the parser hands back exactly the blocks that are already there and
    // `_put` writes only what differs: the prose and table rows get their new
    // html, and a code row -- whose model entry is the source text, not a
    // document -- is written with the same `code` and `lang` and therefore
    // notifies nothing at all. That is the whole point. `_reset()` here would
    // clear the model, destroy every CodeBlock delegate and build new ones
    // with empty documents, which costs 90 ms of code baking
    // and makes a column collapse to nothing for a frame; instead each
    // CodeBlock re-bakes ITSELF, on its own viewport test, keeping its old
    // document (and therefore its height) until it does.
    function _rebakeAll() {
        if (_st.flushing) { _st.rebakeAfter = true; return; }
        _st.bakes++;
        _st.stableLen = 0;
        _st.frozen = 0;
        _st.fence = "";
        root._schedule();
    }

    // An APPEND is the streaming path and keeps its one-flush-per-frame
    // batching. Anything else replaces this view's document and is built here
    // and now, so that no frame can be presented with the furniture of a
    // message and none of its text. See the header comment.
    function _schedule() {
        if (!root.visible || !_st.completed) { _st.dirty = true; return; }
        if (!Md.isAppend(root.source, _st.srcLen, _st.srcFence)) {
            root._flush();
            return;
        }
        if (_st.queued) return;
        _st.queued = true;
        Qt.callLater(root._flush);
    }

    // `scale` multiplies the CSS font sizes. Prose documents are built at
    // _viewScale (their TextEdit is inversely scaled -- see the delegate);
    // tables draw unscaled Text items, so their cells are built at 1.
    function _opt(scale) {
        const s = scale || 1;
        return {
            "family": root.bodyFontFamily,
            "sizePx": root.fontPixelSize * s,
            "headScale": root.headingScale,
            "linkColor": root.linkColor.toString(),
            "mutedColor": root.mutedColor.toString(),
            "codeInlineBg": root.inlineCodeBgColor.toString(),
            "monoFamily": root.monoFamily,
            "monoSizePx": root.codeFontPixelSize * s,
            "noImages": !root.showImages,
            "math": root.showMath ? root._mathHost() : null
        };
    }

    // What Markdown.js asks a formula of. `k` is the view's magnification: the html is laid out in the edit's
    // pixels (font x scale), the pictures are in logical ones.
    function _mathHost() {
        return {
            "lookup": (tex, display, px) => root._mathOf(tex, display, px),
            "blank": root.mathBlankUrl.toString(),
            "fm": (px) => root._fontParts(px),
            "k": root._viewScale
        };
    }
    // The font's own ascent and descent at `px` (whole pixels, as Qt lays a line out): what Markdown._mathHtml
    // needs to size the image that makes a line deep enough for a formula. FontMetrics is read AFTER its
    // size is set, inside the call.
    FontMetrics {
        id: _fmx
        font.family: root.bodyFontFamily
    }
    function _fontParts(px) {
        _fmx.font.pixelSize = Math.max(1, Math.round(px));
        return [Math.round(_fmx.ascent), Math.round(_fmx.descent)];
    }
    // True while a formula this view has shown as source is waiting for its picture.
    property bool _mathPending: false
    // `px`: the font size (logical) of the text the formula sits in, a heading's included; a display formula
    // is the body's size times `mathDisplayScale`.
    function _mathOf(tex, display, px) {
        const r = MathRender.lookup(tex, display,
                                    display ? root.fontPixelSize * root.mathDisplayScale
                                            : (px || root.fontPixelSize) * root.mathInlineScale,
                                    root._viewScale);
        if (r.state === "pending")
            root._mathPending = true;
        return r;
    }
    // A picture landed: every row that showed source for it is built again. The rows are KEPT (as in a re-bake):
    // the source has not changed, so `_put` writes only the rows whose html or payload differ.
    Connections {
        target: MathRender
        enabled: root._mathPending
        function onSerialChanged() {
            root._mathPending = false;
            if (_st.flushing) { _st.rebakeAfter = true; return; }
            _st.stableLen = 0;
            _st.frozen = 0;
            _st.fence = "";
            root._schedule();
        }
    }

    function _flush() {
        _st.queued = false;
        if (_st.flushing) { _st.flushAfter = true; return; }
        _st.flushing = true;
        try { root._flushInner(); } finally { _st.flushing = false; }
        if (_st.rebuildAfter) {
            _st.rebuildAfter = false; _st.rebakeAfter = false; _st.flushAfter = false;
            root._rebuildAll();
        } else if (_st.rebakeAfter) {
            _st.rebakeAfter = false; _st.flushAfter = false;
            root._rebakeAll();
        } else if (_st.flushAfter) {
            _st.flushAfter = false;
            root._schedule();
        }
    }

    function _flushInner() {
        if (!root.visible) { _st.dirty = true; return; }
        _st.dirty = false;

        const src = root.source;
        // The source shrank, or the frozen region no longer matches: this item
        // is being re-used for a different message. Same boundary test as the
        // one that chose this flush's speed, measured at the FROZEN cursor
        // rather than at the end of what was flushed.
        if (!Md.isAppend(src, _st.stableLen, _st.fence) && _st.stableLen > 0)
            root._reset();

        const tail = src.substring(_st.stableLen);
        const blocks = Md.parseBlocks(tail);
        const opt = root._opt(root._viewScale);

        // Block offsets from the parser are relative to the tail; the rows
        // store them ABSOLUTE, rebased on where the tail starts. A frozen
        // row's offsets are final by the same invariant that freezes it.
        const base = _st.stableLen;
        let row = _st.frozen;
        for (let k = 0; k < blocks.length; k++) {
            root._put(row, blocks[k], opt, base);
            row++;
        }
        // A provisional block can collapse into its neighbour (a pipe row that
        // turns out to be a table header), so the tail may get shorter.
        while (_blocks.count > row) _blocks.remove(_blocks.count - 1);

        // Freeze the leading run of blocks the parser vouches for. `end <
        // tail.length` is the second half of that promise: a block whose end
        // is the end of the source has not yet seen the blank line that its
        // `end` would swallow, so freezing it there would leave the cursor one
        // character short of where a one-shot parse puts it.
        let frozen = 0;
        let advance = 0;
        const settled = !root.streaming;
        while (frozen < blocks.length && blocks[frozen].complete
               && (settled || blocks[frozen].end < tail.length)) {
            advance = blocks[frozen].end;
            frozen++;
        }
        if (frozen > 0) {
            _st.frozen += frozen;
            _st.stableLen += advance;
            // O(32), never O(document): the boundary, not the prefix.
            _st.fence = src.substr(Math.max(0, _st.stableLen - Md.FENCE),
                                   Math.min(Md.FENCE, _st.stableLen));
        }
        // What the next change is measured against: an append leaves this
        // boundary intact, a replacement does not.
        _st.srcLen = src.length;
        _st.srcFence = Md.fenceOf(src);
    }

    // Turn one parsed block into a model row, writing only what changed: a
    // ListModel setProperty on an unchanged value still notifies the delegate.
    function _put(row, b, opt, srcBase) {
        let kind = b.kind;
        let baseHtml = "";
        let code = "";
        let lang = "";
        let payload = "";
        const s0 = srcBase + b.start;
        const s1 = srcBase + b.end;

        if (kind === "code") {
            code = b.code;
            lang = b.lang;
        } else if (kind === "math") {
            // The block's own text is its fallback: what it was written as, delimiters and all. The picture is
            // asked for only once the block is complete -- half an equation never flickers into a picture.
            code = root.source.substring(s0, s1).trim();
            if (root.showMath && (b.complete || !root.streaming))
                payload = JSON.stringify(root._mathOf(b.tex, true));
        } else if (kind === "table") {
            // Tables draw unscaled Text items and are measured unscaled, so
            // their cell CSS must be too.
            payload = JSON.stringify(root._tablePayload(b, root._opt(1)));
        } else if (kind !== "rule") {
            // A paragraph that is nothing but an image becomes a real Image:
            // QTextDocument will not fetch one, and an alt text in a box is a
            // better failure than an empty line.
            const img = root.showImages && kind === "para" ? Md.imageOf(b.text) : null;
            if (img) {
                kind = "image";
                payload = JSON.stringify(img);
            } else {
                opt.acc = { "imgs": 0, "math": [] };
                baseHtml = Md.blockHtml(b, opt);
                if (opt.acc.math.length > 0)
                    payload = JSON.stringify({ "m": opt.acc.math });
                opt.acc = null;
            }
        }

        // The live tail participates in the search highlight; with no query
        // this is one length check and the shown html IS the base.
        const html = (baseHtml.length > 0 && root.searchQuery.length > 0)
            ? Md.highlightHtml(baseHtml, root.searchQuery,
                               root.searchHighlightColor.toString())
            : baseHtml;

        if (row >= _blocks.count) {
            _blocks.append({ "kind": kind, "html": html, "base": baseHtml,
                             "code": code, "lang": lang, "payload": payload,
                             "complete": b.complete,
                             "srcStart": s0, "srcEnd": s1 });
            return;
        }
        const cur = _blocks.get(row);
        if (cur.kind !== kind) {
            _blocks.set(row, { "kind": kind, "html": html, "base": baseHtml,
                               "code": code, "lang": lang, "payload": payload,
                               "complete": b.complete,
                               "srcStart": s0, "srcEnd": s1 });
            return;
        }
        if (cur.html !== html) _blocks.setProperty(row, "html", html);
        if (cur.base !== baseHtml) _blocks.setProperty(row, "base", baseHtml);
        if (cur.code !== code) _blocks.setProperty(row, "code", code);
        if (cur.lang !== lang) _blocks.setProperty(row, "lang", lang);
        if (cur.payload !== payload) _blocks.setProperty(row, "payload", payload);
        if (cur.complete !== b.complete) _blocks.setProperty(row, "complete", b.complete);
        if (cur.srcStart !== s0) _blocks.setProperty(row, "srcStart", s0);
        if (cur.srcEnd !== s1) _blocks.setProperty(row, "srcEnd", s1);
    }

    // ---- Table measuring ----------------------------------------------------
    // Done here, once, and shipped to the delegate in the payload. Measuring
    // with TextMetrics rather than reading a Text back is the project's rule
    // against binding loops; a cell that carries code or bold is measured with
    // slack rather than a second layout pass.
    TextMetrics {
        id: _tm
        font.family: root.bodyFontFamily
        font.pixelSize: root.fontPixelSize
    }
    TextMetrics {
        id: _tmMono
        font.family: root.monoFamily
        font.pixelSize: root.codeFontPixelSize
        font.bold: root.codeBold
    }

    // Measure one string in the cell font, with the mono font as an upper
    // bound when the cell carries inline code and a bold allowance when it is
    // a header or holds bold text. TextMetrics, never a Text read back: that
    // is the project's rule against binding loops.
    function _measure(plain, mono, bold) {
        _tm.text = plain;
        let w = _tm.advanceWidth;
        if (mono) {
            _tmMono.text = plain;
            w = Math.max(w, _tmMono.advanceWidth);
        }
        return bold ? w * 1.08 : w;
    }

    // Per column we need two figures and no more:
    //   nat  the widest cell laid out on one line -- what the column wants;
    //   min  the widest single WORD -- the width below which the column starts
    //        breaking words, which is a cost, not a failure.
    // Both are pure text widths, so they survive a resize: only `fitColumns`
    // re-runs when the container moves.
    function _tablePayload(b, opt) {
        const n = b.head.length;
        const nat = [];
        const min = [];
        for (let c = 0; c < n; c++) { nat.push(0); min.push(0); }

        const rows = [b.head].concat(b.rows);
        const headHtml = [];
        const rowHtml = [];
        for (let r = 0; r < rows.length; r++) {
            const cells = [];
            for (let c = 0; c < n; c++) {
                const raw = (c < rows[r].length) ? rows[r][c] : "";
                cells.push(Md.blockHtml({ "kind": "para", "text": raw }, opt));
                const plain = Md.plainText(raw);
                const mono = raw.indexOf("`") >= 0;
                const bold = (r === 0) || raw.indexOf("**") >= 0;
                const w = root._measure(plain, mono, bold);
                if (w > nat[c]) nat[c] = w;
                const words = plain.split(/\s+/);
                for (let k = 0; k < words.length; k++) {
                    if (words[k].length === 0) continue;
                    const wordW = root._measure(words[k], mono, bold);
                    if (wordW > min[c]) min[c] = wordW;
                }
            }
            if (r === 0) { for (let i = 0; i < cells.length; i++) headHtml.push(cells[i]); }
            else rowHtml.push(cells);
        }
        for (let c = 0; c < n; c++) { nat[c] = Math.ceil(nat[c]); min[c] = Math.ceil(min[c]); }
        return { "head": headHtml, "rows": rowHtml, "align": b.align, "nat": nat, "min": min };
    }

    function _payload(s) {
        try {
            const v = JSON.parse(s);
            return (v && typeof v === "object") ? v : ({});
        } catch (e) {
            return ({});
        }
    }

    // =========================================================================
    // The column of blocks
    // =========================================================================
    Column {
        id: _col
        width: root.width
        spacing: root.blockSpacing

        Repeater {
            id: _rep
            model: _blocks

            delegate: Item {
                id: bd

                required property int index
                required property string kind
                required property string html
                required property string code
                required property string lang
                required property string payload
                required property bool complete

                // The loaded block, for the selection layer's generic
                // TextEdit walk.
                readonly property Item loadedItem: _ldr.item as Item

                width: _col.width
                // A heading gets air above it, but not at the top of a message.
                readonly property real topPad: (bd.kind === "head" && bd.index > 0) ? root.headingSpacing : 0
                // The one block whose document is still being written.
                readonly property bool live: root.streaming && bd.index === _blocks.count - 1
                implicitHeight: bd.topPad + _ldr.implicitHeight

                Loader {
                    id: _ldr
                    y: bd.topPad
                    width: bd.width
                    sourceComponent: bd.kind === "code" ? _codeC
                                   : bd.kind === "table" ? _tableC
                                   : bd.kind === "rule" ? _ruleC
                                   : bd.kind === "image" ? _imageC
                                   : bd.kind === "math" ? _mathC
                                   : bd.kind === "quote" ? _quoteC
                                   : _proseC
                }

                // The selection wash, for blocks with no TextEdit to
                // highlight: a table or an image inside the sweep says so with
                // a translucent sheet in the selection colour. NOT a rule -- a
                // rule is decoration and takes no part in a selection, so it
                // stays exactly as it draws when nothing is selected, even
                // when the sweep passes over it.
                Rectangle {
                    visible: root.selLo >= 0
                             && bd.index >= root.selLo && bd.index <= root.selHi
                             && (bd.kind === "table" || bd.kind === "image" || bd.kind === "math")
                    x: _ldr.x
                    y: _ldr.y
                    width: _ldr.width
                    height: _ldr.height
                    radius: root.tableRadius
                    color: root.selectionColor
                    opacity: 0.3
                }

                // ---- prose: para, head, list --------------------------------
                Component {
                    id: _proseC
                    Item {
                        id: _pw
                        // The edit lays out in scaled space (see the render-
                        // scale note up top); its heights divide back out. At
                        // scale 1 all of this is identity.
                        implicitHeight: _edit.contentHeight / root._viewScale
                        readonly property var maths: root._payload(bd.payload).m || []

                        TextEdit {
                            id: _edit
                            width: _pw.width * root._viewScale
                            scale: 1 / root._viewScale
                            transformOrigin: Item.TopLeft
                            readOnly: true
                            selectByMouse: true
                            textFormat: TextEdit.RichText
                            wrapMode: Text.Wrap
                            // Set once for a frozen block; only the live block
                            // ever sees this change.
                            text: root._lhOpen + bd.html + root._lhClose
                            color: root.textColor
                            font.family: root.bodyFontFamily
                            font.pixelSize: Math.round(root.fontPixelSize * root._viewScale)
                            selectionColor: root.selectionColor
                            selectedTextColor: root.selectionTextColor
                            cursorVisible: false
                            onLinkActivated: (url) => root.linkActivated(url)
                            onTextChanged: _caret.sync()
                            onWidthChanged: _caret.sync()
                        }

                        MathOverlays {
                            edit: _edit
                            records: _pw.maths
                            ink: root.textColor
                            viewScale: root._viewScale
                            family: root.bodyFontFamily
                        }

                        // The live caret. positionToRectangle is cheap and does
                        // NOT serialise the document, unlike reading `.text`.
                        Rectangle {
                            id: _caret
                            visible: bd.live
                            width: 2
                            height: Math.max(2, root.fontPixelSize)
                            color: root.caretColor
                            function sync() {
                                if (!bd.live) return;
                                const r = _edit.positionToRectangle(_edit.length);
                                _caret.x = r.x + r.width;
                                _caret.y = r.y;
                                _caret.height = Math.max(2, r.height);
                            }
                            Component.onCompleted: _caret.sync()
                        }
                        // A caret blinks; it does not fade.
                        Timer {
                            running: bd.live
                            interval: 530
                            repeat: true
                            onTriggered: _caret.opacity = _caret.opacity > 0.5 ? 0 : 1
                            onRunningChanged: if (running) { _caret.opacity = 1; _caret.sync(); }
                        }
                    }
                }

                // ---- quote --------------------------------------------------
                Component {
                    id: _quoteC
                    Item {
                        id: _qw
                        implicitHeight: _qedit.contentHeight / root._viewScale
                        readonly property var maths: root._payload(bd.payload).m || []

                        Rectangle {
                            width: root.quoteBarWidth
                            height: _qw.height
                            radius: root.quoteBarWidth / 2
                            color: root.quoteBarColor
                        }
                        TextEdit {
                            id: _qedit
                            x: root.quoteBarWidth + root.quoteInset
                            width: Math.max(0, (_qw.width - _qedit.x) * root._viewScale)
                            scale: 1 / root._viewScale
                            transformOrigin: Item.TopLeft
                            readOnly: true
                            selectByMouse: true
                            textFormat: TextEdit.RichText
                            wrapMode: Text.Wrap
                            text: root._lhOpen + bd.html + root._lhClose
                            color: root.mutedColor
                            font.family: root.bodyFontFamily
                            font.pixelSize: Math.round(root.fontPixelSize * root._viewScale)
                            selectionColor: root.selectionColor
                            selectedTextColor: root.selectionTextColor
                            cursorVisible: false
                            onLinkActivated: (url) => root.linkActivated(url)
                        }
                        MathOverlays {
                            edit: _qedit
                            records: _qw.maths
                            ink: root.mutedColor
                            viewScale: root._viewScale
                            family: root.bodyFontFamily
                        }
                    }
                }

                // ---- rule ---------------------------------------------------
                Component {
                    id: _ruleC
                    Item {
                        id: _rw
                        implicitHeight: 1 + root.blockSpacing * 2
                        Rectangle {
                            anchors.verticalCenter: _rw.verticalCenter
                            width: _rw.width
                            height: 1
                            color: root.tableLineColor
                        }
                    }
                }

                // ---- code ---------------------------------------------------
                Component {
                    id: _codeC
                    CodeBlock {
                        code: bd.code
                        lang: bd.lang
                        complete: bd.complete
                        // The same viewport this view asks: a 36 KB block far
                        // below the fold re-bakes when it is scrolled to, not
                        // in the frame the theme settles.
                        viewportHost: root.scrollHost
                        monoFamily: root.monoFamily
                        fontPixelSize: root.codeFontPixelSize
                        bold: root.codeBold
                        radius: root.codeRadius
                        padding: root.codePadding
                        headerHeight: root.codeHeaderHeight
                        showHeader: root.codeShowHeader
                        surfaceColor: root.surfaceColor
                        backgroundColor: root.codeBgColor
                        bevelColor: root.codeBevelColor
                        shadowColor: root.codeShadowColor
                        headerColor: root.codeHeaderColor
                        textColor: root.codeTextColor
                        mutedColor: root.faintColor
                        kwColor: root.codeKwColor
                        strColor: root.codeStrColor
                        numColor: root.codeNumColor
                        comColor: root.codeComColor
                        fnColor: root.codeFnColor
                        typeColor: root.codeTypeColor
                        opColor: root.codeOpColor
                        varColor: root.codeVarColor
                        puncColor: root.codePuncColor
                        selectionColor: root.selectionColor
                        selectionTextColor: root.selectionTextColor
                        buttonPlateauColor: root.buttonPlateauColor
                        buttonPlateauHoverColor: root.buttonPlateauHoverColor
                        buttonBevelColor: root.buttonBevelColor
                        buttonShadowColor: root.buttonShadowColor
                    }
                }

                // ---- table --------------------------------------------------
                // Laid out to the width it is given. No Flickable, no clip, no
                // elision: the columns are fitted to the available width and
                // the cells wrap, so there is never anything outside the box
                // and never a wheel event to swallow. Row heights follow their
                // tallest cell, and cells are top-aligned because a wrapped
                // three-line cell beside a one-line cell reads as a row only
                // if both start on the same baseline.
                Component {
                    id: _tableC
                    Item {
                        id: _tw
                        readonly property var tbl: root._payload(bd.payload)
                        readonly property var align: _tw.tbl.align || []
                        readonly property var head: _tw.tbl.head || []
                        readonly property var rows: _tw.tbl.rows || []
                        // The only thing a resize re-runs: arithmetic over two
                        // measured arrays. Nothing is re-parsed, nothing is
                        // re-measured, and the widths sum to exactly _tw.width.
                        readonly property var widths: Md.fitColumns(_tw.tbl.nat || [], _tw.tbl.min || [],
                                                                    Math.max(1, _tw.width), root.tableCellPadH)
                        implicitHeight: _grid.implicitHeight

                        ShadowBox {
                            anchors.fill: parent
                            baseRadius: root.tableRadius
                            surfaceColor: root.surfaceColor
                            backgroundColor: root.tableBgColor
                            bevelColor: root.tableBevelColor
                            shadowColor: root.tableShadowColor
                            bevelWidth: 1
                            shadowWidth: 3
                        }

                        Column {
                            id: _grid
                            width: _tw.width

                            // The header lid takes the box's top radius so the
                            // two curves coincide.
                            Rectangle {
                                width: _grid.width
                                height: _headRow.implicitHeight + root.tableCellPadV * 2
                                color: root.tableHeadColor
                                topLeftRadius: root.tableRadius
                                topRightRadius: root.tableRadius
                                Row {
                                    id: _headRow
                                    y: root.tableCellPadV
                                    Repeater {
                                        model: _tw.head
                                        delegate: Text {
                                            id: _hc
                                            required property int index
                                            required property string modelData
                                            width: _tw.widths[_hc.index] || 0
                                            leftPadding: root.tableCellPadH
                                            rightPadding: root.tableCellPadH
                                            wrapMode: Text.Wrap
                                            verticalAlignment: Text.AlignTop
                                            horizontalAlignment: _tw.align[_hc.index] === "right" ? Text.AlignRight
                                                               : _tw.align[_hc.index] === "center" ? Text.AlignHCenter
                                                               : Text.AlignLeft
                                            textFormat: Text.RichText
                                            text: _hc.modelData
                                            color: root.textColor
                                            font.family: root.bodyFontFamily
                                            font.pixelSize: root.fontPixelSize
                                            font.bold: true
                                        }
                                    }
                                }
                            }

                            Repeater {
                                model: _tw.rows.length
                                delegate: Column {
                                    id: _tr
                                    required property int index
                                    width: _grid.width
                                    Rectangle {
                                        width: _grid.width
                                        height: 1
                                        color: root.tableLineColor
                                    }
                                    Item {
                                        width: _grid.width
                                        height: _bodyRow.implicitHeight + root.tableCellPadV * 2
                                        Row {
                                            id: _bodyRow
                                            y: root.tableCellPadV
                                            Repeater {
                                                model: _tw.rows[_tr.index]
                                                delegate: Text {
                                                    id: _rc
                                                    required property int index
                                                    required property string modelData
                                                    width: _tw.widths[_rc.index] || 0
                                                    leftPadding: root.tableCellPadH
                                                    rightPadding: root.tableCellPadH
                                                    // Word boundary first, then
                                                    // anywhere: a URL in a cell
                                                    // still cannot push the
                                                    // column wider than its share.
                                                    wrapMode: Text.Wrap
                                                    verticalAlignment: Text.AlignTop
                                                    horizontalAlignment: _tw.align[_rc.index] === "right" ? Text.AlignRight
                                                                       : _tw.align[_rc.index] === "center" ? Text.AlignHCenter
                                                                       : Text.AlignLeft
                                                    textFormat: Text.RichText
                                                    text: _rc.modelData
                                                    color: root.textColor
                                                    font.family: root.bodyFontFamily
                                                    font.pixelSize: root.fontPixelSize
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ---- display math -------------------------------------------
                // The picture, centred, tinted with the text colour and never wider than the view (a long
                // formula is scaled down to fit: nothing in an answer scrolls sideways). Until the block is
                // complete, while MathRender has not answered, and when mathtext cannot read the formula,
                // the block shows what was written, in the code font, muted: a readable fallback, never
                // an error box.
                Component {
                    id: _mathC
                    Item {
                        id: _mw
                        readonly property var res: root._payload(bd.payload)
                        readonly property bool pic: _mw.res.state === "ok"
                        readonly property real fit: _mw.pic ? Math.min(1, _mw.width / Math.max(1, _mw.res.w)) : 1
                        implicitHeight: _mw.pic ? Math.ceil(_mw.res.h * _mw.fit) + root.mathDisplayPad * 2
                                                : _src.implicitHeight
                        MathInk {
                            id: _pic2
                            visible: _mw.pic
                            source: _mw.pic ? _mw.res.url : ""
                            pw: _mw.pic ? _mw.res.w : 1
                            ph: _mw.pic ? _mw.res.h : 1
                            ink: root.textColor
                            renderScale: root._viewScale
                            transformOrigin: Item.TopLeft
                            scale: _mw.fit
                            x: Math.round((_mw.width - _pic2.pw * _mw.fit) / 2 * root._viewScale) / root._viewScale
                            y: root.mathDisplayPad
                        }
                        Text {
                            id: _src
                            width: _mw.width
                            visible: !_mw.pic
                            text: bd.code
                            color: root.mutedColor
                            font.family: root.monoFamily
                            font.pixelSize: root.codeFontPixelSize
                            wrapMode: Text.Wrap
                        }
                    }
                }

                // ---- image --------------------------------------------------
                Component {
                    id: _imageC
                    Item {
                        id: _iw
                        readonly property var img: root._payload(bd.payload)
                        readonly property real inset: root.imageInset
                        readonly property real avail: Math.max(1, _iw.width - _iw.inset * 2)
                        // Natural size of an Image is safe to read; only a
                        // TextEdit's implicitWidth is poisoned.
                        readonly property real drawH: (_pic.status === Image.Ready && _pic.implicitWidth > 0)
                            ? Math.min(_pic.implicitHeight,
                                       _pic.implicitHeight * (_iw.avail / _pic.implicitWidth))
                            : 0
                        implicitHeight: _pic.status === Image.Ready
                            ? _iw.drawH + _iw.inset * 2
                            : _alt.implicitHeight + _iw.inset * 2

                        ShadowBox {
                            anchors.fill: parent
                            baseRadius: root.tableRadius
                            surfaceColor: root.surfaceColor
                            backgroundColor: root.tableBgColor
                            bevelColor: root.tableBevelColor
                            shadowColor: root.tableShadowColor
                            bevelWidth: 1
                            shadowWidth: 3
                        }
                        Image {
                            id: _pic
                            x: _iw.inset
                            y: _iw.inset
                            width: _iw.avail
                            height: Math.max(1, _iw.drawH)
                            visible: _pic.status === Image.Ready
                            source: _iw.img.src || ""
                            asynchronous: true
                            fillMode: Image.PreserveAspectFit
                        }
                        Text {
                            id: _alt
                            x: _iw.inset
                            y: _iw.inset
                            width: _iw.avail
                            visible: _pic.status !== Image.Ready
                            text: _iw.img.alt || ""
                            color: root.faintColor
                            font.family: root.bodyFontFamily
                            font.pixelSize: root.fontPixelSize
                            // Wrap, never elide: with no height cap the elide
                            // never fired anyway, and nothing in an answer is
                            // allowed to be truncated.
                            wrapMode: Text.Wrap
                        }
                    }
                }
            }
        }
    }

    // =========================================================================
    // The pointer, tracked from the ROOT (see the header: a hover accepted by
    // the layer would never reach a code block's HoverHandler beneath it, and
    // an ancestor's handler is the one that stays hovered whatever accepts
    // below). The link under the pointer drives the cursor; over a code
    // block's lid the cursor is handed back so the copy button's own shows.
    HoverHandler {
        id: _hoverTrack
        enabled: root.selectable
        cursorShape: _selLayer.overLid ? undefined
                   : _selLayer.hoverLink.length > 0 ? Qt.PointingHandCursor
                   : Qt.IBeamCursor
        onPointChanged: _selLayer.track(_hoverTrack.point.position.x,
                                        _hoverTrack.point.position.y)
        onHoveredChanged: if (!_hoverTrack.hovered) _selLayer.track(-1, -1)
    }

    // The selection drag layer -- declared after the column, so it sits over
    // every block. Left button only; a wheel passes straight through to the
    // transcript's one handler. NO hover here: `hoverEnabled: true` on this
    // MouseArea would keep every code block's copy button from ever
    // appearing (header). Presses it does not want fall through via
    // mouse.accepted = false.
    // =========================================================================
    MouseArea {
        id: _selLayer
        anchors.fill: parent
        enabled: root.selectable
        acceptedButtons: Qt.LeftButton
        hoverEnabled: false
        preventStealing: true
        property string hoverLink: ""
        // The pointer is over a code block's header strip.
        property bool overLid: false

        // The lid test the press exclusion below uses, for the hover too.
        function _onLid(lx, ly) {
            const b = root.blockAt(ly);
            if (b < 0)
                return false;
            const it = _rep.itemAt(b);
            const inner = root._loadedOf(it);
            return !!inner && inner.lidHeight !== undefined
                && (ly - it.y - inner.y) < inner.lidHeight;
        }
        // Fed by the root's HoverHandler; (-1, -1) is the pointer gone.
        function track(lx, ly) {
            if (_selSt.dragging)
                return;
            if (lx < 0 || ly < 0 || ly >= root.height) {
                _selLayer.hoverLink = "";
                _selLayer.overLid = false;
                return;
            }
            const b = root.blockAt(ly);
            _selLayer.hoverLink = b >= 0
                ? _selLayer._linkIn(root._editOf(b), lx, ly) : "";
            _selLayer.overLid = _selLayer._onLid(lx, ly);
        }

        function _posIn(edit, sx, sy) {
            const p = _selLayer.mapToItem(edit, sx, sy);
            return edit.positionAt(p.x, p.y);
        }
        function _linkIn(edit, sx, sy) {
            if (!edit || typeof edit.linkAt !== "function")
                return "";
            const p = _selLayer.mapToItem(edit, sx, sy);
            return edit.linkAt(p.x, p.y) || "";
        }

        // The pointer's last position in SCENE coordinates. The auto-scroll
        // moves the document under a pointer that is not moving, so the only
        // point that stays meaningful across a tick is the scene one; the
        // local one it maps to is different on every frame, which is exactly
        // what makes the selection grow.
        property real lastSceneX: 0
        property real lastSceneY: 0
        function _remember(lx, ly) {
            const p = _selLayer.mapToItem(null, lx, ly);
            _selLayer.lastSceneX = p.x;
            _selLayer.lastSceneY = p.y;
        }
        // Called by the host once per frame while the ground is moving.
        function autoScrollReapply() {
            if (!_selSt.dragging)
                return;
            const p = _selLayer.mapFromItem(null, _selLayer.lastSceneX,
                                            _selLayer.lastSceneY);
            _selLayer.extendTo(p.x, p.y);
        }

        // The moving end of the sweep, from a point in this layer's own
        // coordinates. Shared by the drag and by the auto-scroll, so a
        // selection that grew because the reader moved and one that grew
        // because the ground did are the same code.
        function extendTo(lx, ly) {
            // blockAt reads a clamped y so a drag past either edge selects to
            // the end; positionAt gets the REAL point -- it clamps itself, so
            // dragging below the last line lands on its last character.
            let b = root.blockAt(Math.max(0, Math.min(root.height - 1, ly)));
            if (!root.crossSelectEnabled)
                b = _selSt.aBlock;
            // Over a rule the moving end rests on the last real block towards
            // the anchor, selected to its far edge -- so the sweep neither
            // stops at the break nor swallows it, and it resumes exactly where
            // the next block begins.
            const overRule = root._isRule(b);
            const snapped = overRule ? root._snapEnd(b, _selSt.aBlock) : b;
            if (snapped < 0)
                return;                        // nothing but rules that way
            const e = snapped >= 0 ? root._editOf(snapped) : null;
            _selSt.bBlock = snapped;
            _selSt.bPos = overRule
                ? root._edgePos(e, b > _selSt.aBlock)
                : (e ? _selLayer._posIn(e, lx, ly) : -1);
            root._applySel();
        }

        onPressed: (mouse) => {
            // A press on a rule anchors on the real block beside it: the rule
            // itself can never be an endpoint.
            const b0 = root.blockAt(mouse.y);
            const onRule = root._isRule(b0) ? root._anchorOnRule(b0, mouse.y) : null;
            const b = onRule ? onRule[0] : b0;
            if (b < 0) {
                mouse.accepted = false;
                return;
            }
            // A code block's header strip keeps its own click -- the copy
            // button lives there -- so the press falls through to it.
            if (_selLayer._onLid(mouse.x, mouse.y)) {
                mouse.accepted = false;
                return;
            }
            const e = root._editOf(b);
            // A press on a link falls through to the TextEdit, which
            // activates it on release.
            if (_selLayer._linkIn(e, mouse.x, mouse.y).length > 0) {
                mouse.accepted = false;
                return;
            }
            root.forceActiveFocus();
            _selSt.aBlock = b;
            _selSt.bBlock = b;
            _selSt.aPos = onRule ? root._edgePos(e, onRule[1])
                        : (e ? _selLayer._posIn(e, mouse.x, mouse.y) : -1);
            _selSt.bPos = _selSt.aPos;
            _selSt.dragging = true;
            _selSt.active = true;
            _selLayer._remember(mouse.x, mouse.y);
            if (root.scrollHost)
                root.scrollHost.autoScrollBegin(_selLayer);
            root._applySel();
        }
        onPositionChanged: (mouse) => {
            if (!_selSt.dragging)
                return;
            _selLayer.extendTo(mouse.x, mouse.y);
            _selLayer._remember(mouse.x, mouse.y);
            if (root.scrollHost)
                root.scrollHost.autoScrollAt(_selLayer.lastSceneY);
        }
        onReleased: {
            _selSt.dragging = false;
            if (root.scrollHost)
                root.scrollHost.autoScrollEnd();
            // A click that moved nothing is a caret, not a selection.
            if (_selSt.aBlock === _selSt.bBlock && _selSt.aPos === _selSt.bPos)
                root.clearSelection();
        }
        onCanceled: {
            _selSt.dragging = false;
            if (root.scrollHost)
                root.scrollHost.autoScrollEnd();
        }
        // Double-click selects the word under the point, through the same
        // per-edit path native selection uses.
        onDoubleClicked: (mouse) => {
            const b = root.blockAt(mouse.y);
            if (root._isRule(b))
                return;                        // decoration has no word
            const e = b >= 0 ? root._editOf(b) : null;
            if (!e)
                return;
            e.cursorPosition = _selLayer._posIn(e, mouse.x, mouse.y);
            e.selectWord();
            _selSt.aBlock = b;
            _selSt.bBlock = b;
            _selSt.aPos = e.selectionStart;
            _selSt.bPos = e.selectionEnd;
            _selSt.active = true;
            root._applySel();
        }
    }
}
