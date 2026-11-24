pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "../../../common/theme"
import "../../../common/components"
import "../../../common/components/Markdown.js" as Md

// =============================================================================
// CodeBlock.qml
//
// One fenced code block: a carved box with a header lid (language on the left,
// copy button on the right) and a body that WRAPS.
//
// Nothing inside an answer scrolls. A code block in its own
// horizontal Flickable would swallow the wheel on its way to the transcript
// and hide the right-hand end of every long line behind a scroll the reader has
// no reason to expect. There is no scroll area here at all: a long line
// wraps, and a line that has been wrapped is marked as such by a HANGING
// INDENT -- its continuations sit two characters past the line's own
// indentation, so a wrap reads as a wrap and not as the next statement.
// Markdown.js builds that as one <p> per source line; see `codeHtml`.
//
// A single unbreakable token -- a base64 blob, a 200-character path -- is
// still not allowed to push the box wider than its container: `wrapMode:
// TextEdit.Wrap` breaks at a word boundary when there is one and ANYWHERE when
// there is not. Character-level breaking is the right answer in code, where a
// token has no spaces to give.
//
// The body is ONE `TextEdit { textFormat: RichText }` whose HTML is built by
// Markdown.js and assigned, never bound. The reasons, all measured
// in this repo:
//
//   * `textFormat: MarkdownText` re-parses the whole document per append
//     (5.3 ms at 30 KB), so nothing here ever hands markdown to Qt.
//   * The syntax colours have to be written INTO the HTML -- a rich-text
//     document cannot inherit a per-token colour from a QML property. That
//     makes the document a snapshot of the theme it was built in, so it is
//     rebuilt once per light/dark switch, AFTER the crossfade has landed:
//     rebuilding on every colour frame would re-parse the document 25 times
//     per switch, and rebuilding at the START of the switch would bake the
//     colours the theme is leaving, not the ones it is going to.
//   * The build has TWO SPEEDS, the same two MarkdownView has and told apart
//     by the same pure function (`Md.isAppend`, over the built length and its
//     last 32 characters). While a fence is still open the code grows per
//     token, so that rebuild is coalesced to one per frame with a `queued`
//     flag + `Qt.callLater`. Anything else -- a delegate re-used for another
//     message, a conversation switched to, a rebuild -- REPLACES this block's
//     document and is built inside the assignment's own call stack. Deferring
//     that one would put a code block a frame behind the answer around
//     it: the prose blocks land in the caller's frame, so on a
//     switch the box, its lid and its language would already be there while the
//     body was still empty and one line tall, and the whole column below it
//     would jump when the text landed. `Qt.callLater` and the render request are
//     both posted events, so which one the loop reaches first is the
//     scheduler's business; the only way to win is to have the document built
//     before returning. It costs nothing -- the same parse, one frame earlier.
//   * Either speed is skipped entirely while the block is not visible (a
//     hidden view that keeps syncing is what caused this project's
//     255 ms/frame download lag); the pending change replays on show, and it
//     replays at the speed it was classified at.
//   * ...and the THEME re-bake is skipped while the block is not ON SCREEN,
//     which is a different question and `visible` cannot answer it: inside the
//     transcript every block of every turn is visible: true, because they sit
//     in a Column and not in a viewport. A light/dark switch would
//     therefore re-bake every block of every answer in ONE frame -- 785 ms
//     at eight turns, 1619 ms at sixteen, measured -- for a conversation of
//     which two documents are on screen. So the block asks `viewportHost`
//     for the band it must intersect, latches `themeDirty` on a miss, and
//     re-bakes when the reader scrolls to it (the host's `viewportSerial`).
//     It keeps its old document, and therefore its height, until then: the
//     alternative -- clearing it and building empty -- would collapse the
//     column under the reader. The only cost of the delay is that a block
//     nobody is looking at wears the old theme's colours for as long as that
//     stays true.
//   * THE DOCUMENT THE THEME LEAVES IS KEPT. There are two bodies
//     and one is shown. A re-bake bakes into the OTHER one and shows it; the
//     one the theme just left stays, hidden, tagged with the key of the
//     palette it holds, and the next switch back finds it by key and swaps
//     in one frame -- no JS, no QTextDocument, only the glyph nodes of a
//     document that already has its layout. And AT REST (`restMs` after the
//     last code change, viewport move or stream) a complete block on screen
//     bakes the other mode's palette ahead, asking Theme what each of its own
//     colours becomes (`Theme.counterpart`), one block per frame
//     (`Theme.claimIdleSlot`), so even the first switch is a swap. RAM for
//     CPU, which is the shell's rule: a 36 KB block is 347 KB of html and
//     ~90 ms to bake (measured: without the bake-ahead a theme switch's whole
//     freeze is this one block), and the same block held twice is a megabyte or two.
//     Only the shown body follows the box's width, so a resize lays out one
//     document, and the kept one re-wraps once if it is ever shown at a new
//     width. Any change to the code drops it.
//
// `implicitWidth` stays 0: the host gives the width. The body's TextEdit takes
// its width from its anchors, NEVER from `implicitWidth` -- one read of a
// TextEdit's implicitWidth permanently flips it into requireImplicitWidth and
// turns 0.11 ms/append into 200 ms/append.
//
// THE COPY BUTTON copies the block's SOURCE -- `code`, the text
// between the fences exactly as the model wrote it, never the rendered
// document -- as plain text with `\n` line endings, through `Md.copyText`:
// the one normaliser every copy path in the module shares (a CR or CRLF the
// model may have emitted becomes `\n`; the U+2028/U+2029 a TextEdit's
// `selectedText` carries and the ZWSP `codeHtml` writes into an empty line
// are not in `code`, but the same function answers for every path, so
// nothing has to remember which path is safe). Its feedback is a glyph swap
// IN PLACE -- the copy mark becomes a check for 1.2 s, at the same width, so
// nothing moves and there is no toast. The glyph is never bold. The button
// fades in with the block's hover, and that hover is this block's own
// HoverHandler -- which only ever sees the pointer because the view's drag
// layer above it takes no hover of its own (MarkdownView's header: a
// MouseArea with `hoverEnabled: true` ends the hover sweep for everything
// beneath it, and that would keep this button from
// ever appearing).
// =============================================================================
Item {
    id: root

    // ---- Content ----
    property string code: ""
    property string lang: ""
    // What the lid says. Empty falls back to `lang`, which is what every fenced
    // block shows; a tool block labels its boxes by the tool's name while
    // `lang` still picks the highlighter ("sh" colours a command line).
    property string label: ""
    // false = the fence is still open. The box simply grows; there is no
    // special mark on its bottom edge, because "still arriving" is already
    // said by the caret and the header of the turn.
    property bool   complete: true

    // ---- Type ----
    property string monoFamily: "Consolas"
    property int    fontPixelSize: 12
    property bool   bold: true
    property real   radius: 10
    property real   padding: 10
    property bool   showHeader: true
    // The lid's height and the size of the language label on it.
    property real   headerHeight: 26
    property int    labelPixelSize: 10
    // How far a wrapped line's continuation sits past the line's own
    // indentation, in characters. Two is enough to read as a continuation and
    // small enough to leave a narrow block usable.
    property int    wrapIndentChars: 2

    // ---- Palette ----
    property color surfaceColor: Theme.listBox       // the ground OUTSIDE the box
    property color backgroundColor: Theme.terminalBg
    property color bevelColor: Theme.bevel
    property color shadowColor: Theme.border
    property color headerColor: Theme.headerBox
    property color textColor: Theme.terminalFg
    property color mutedColor: Theme.textFaint
    // Token colours map onto the ANSI tokens, so the code follows the same
    // palette the terminal view does.
    property color kwColor: Theme.ansiBrightMagenta
    property color strColor: Theme.ansiGreen
    property color numColor: Theme.ansiYellow
    property color comColor: Theme.textFaint
    property color fnColor: Theme.ansiBlue
    property color typeColor: Theme.ansiCyan
    property color opColor: Theme.textMuted
    // Extras: Markdown.js also emits `var` (shell variables, config keys) and
    // `punc`. `punc` defaults to the operator colour, so a host that does not
    // know about it sees exactly the seven classes above.
    property color varColor: Theme.ansiBrightCyan
    property color puncColor: Theme.textMuted
    // The tokens the nine roles above default to, by name, for baking the
    // other mode ahead: a value alone cannot be followed to the other mode
    // when two tokens share it, and three of these do (Theme.counterpart).
    readonly property var paletteTokens: ({
        "kw": "ansiBrightMagenta", "str": "ansiGreen", "num": "ansiYellow",
        "com": "textFaint", "fn": "ansiBlue", "type": "ansiCyan",
        "op": "textMuted", "var": "ansiBrightCyan", "punc": "textMuted"
    })
    // Selection, and the button palette for the copy button. All defaulted to
    // Theme so a host that passes nothing still follows the theme.
    property color selectionColor: Theme.terminalSelection
    property color selectionTextColor: Theme.terminalSelectionText
    property color buttonPlateauColor: Theme.buttonPlateau
    property color buttonPlateauHoverColor: Theme.buttonPlateauHover
    property color buttonBevelColor: Theme.buttonBevel
    property color buttonShadowColor: Theme.buttonShadow

    signal copied()

    // How many documents this block has built. Published so that whether a
    // theme switch re-baked THIS block is a readable fact rather than
    // something behind a private id: the law that a block off screen
    // does not re-bake until it is scrolled to is exactly a claim about
    // this number. (A binding READS it; only the build writes it, so it is not
    // a self-triggering counter.)
    readonly property int builds: _st.builds

    // ---- The viewport that owns this block ---------------------------------
    // Duck-typed, `var`: anything publishing `viewportBand()` (scene
    // coordinates) and a `viewportSerial` that ticks when the band moves --
    // LlmTranscript is the one that does. It is what makes the theme re-bake
    // affordable: this block's document is a snapshot of the theme it was
    // built in, and re-baking one is expensive in proportion to its SIZE (a
    // 36 KB block expands to 347 KB of html: 38 ms of JS in `Md.codeHtml`
    // plus 34 ms for QTextDocument to parse it, measured), so a block far
    // below the fold waits until it is scrolled to instead of paying that in
    // the frame the theme settles. `visible` cannot answer this -- inside the
    // transcript every block of every turn is visible: true, because they sit
    // in a Column and not in a viewport. Null (a harness, a tool block, a
    // confirmation preview) means "on screen".
    property var viewportHost: null
    // How long after the last thing that happened to it -- its code changing,
    // the viewport moving, an answer streaming -- a block counts as at rest
    // and bakes the other palette ahead. Long enough that a reader who is
    // scrolling never lands on the bake.
    property int restMs: 2000

    // ---- Geometry ----
    // implicitWidth deliberately left at 0: the host owns the width, and the
    // body wraps into it, so there is no width this block wants.
    // The lid as drawn -- 0 without a header. Published because the view's
    // drag layer hands presses and hover in this strip back to the block
    // (the copy button lives there), and `headerHeight` alone would claim a
    // strip a headerless block does not have.
    readonly property real lidHeight: root.showHeader ? root.headerHeight : 0
    implicitHeight: root.lidHeight + root.padding * 2 + Math.max(root._body.contentHeight, _fm.height)

    FontMetrics {
        id: _fm
        font.family: root.monoFamily
        font.pixelSize: root.fontPixelSize
        font.bold: root.bold
    }

    // ---- HTML build ---------------------------------------------------------
    QtObject {
        id: _st
        property bool queued: false
        property bool dirty: true
        // The boundary the two speeds are told apart at: how much of `code`
        // the document holds and the last Md.FENCE characters of it.
        property int    builtLen: 0
        property string builtFence: ""
        // Latched by _schedule, cleared by the build that honours it, so a
        // wholesale change that arrives while the block is hidden is still a
        // wholesale change when it replays on show.
        property bool   wholesale: false
        // No build before the object is complete: a build reads every type
        // property, and a binding evaluated by that read mid-construction
        // fires its change handler into a second build (MarkdownView's
        // header has the measurement). onCompleted is still inside the
        // creating call stack, so the synchronous-build law holds.
        property bool   completed: false
        // The theme changed while this block was off screen. Not `dirty`,
        // which is about the CODE: replaying that one with the code unchanged
        // builds nothing, so a theme re-bake that borrowed it would be lost.
        property bool   themeDirty: false
        // The other body has been settled for this code: it holds a palette,
        // or the other mode was found to colour code the same. Cleared by
        // every build of the shown body, because that is a change of code.
        property bool   ahead: false
        property int    builds: 0
    }

    function _palette() {
        return {
            "kw": root.kwColor.toString(),
            "str": root.strColor.toString(),
            "num": root.numColor.toString(),
            "com": root.comColor.toString(),
            "fn": root.fnColor.toString(),
            "type": root.typeColor.toString(),
            "op": root.opColor.toString(),
            "var": root.varColor.toString(),
            "punc": root.puncColor.toString()
        };
    }

    // Two speeds, one test -- see the header comment. An APPEND is the
    // streaming path and keeps its one-build-per-frame batching; anything else
    // replaces the document and is built here and now, so no frame can be
    // presented with a code block's lid and none of its code.
    function _schedule() {
        if (!Md.isAppend(root.code, _st.builtLen, _st.builtFence))
            _st.wholesale = true;
        if (!root.visible || !_st.completed) { _st.dirty = true; return; }
        if (_st.wholesale) { root._build(); return; }
        if (_st.queued) return;
        _st.queued = true;
        Qt.callLater(root._build);
    }

    function _keyOf(p) {
        return p.kw + p.str + p.num + p.com + p.fn + p.type + p.op + p["var"] + p.punc;
    }

    // The one place html is made: `root.code` in `palette`, into `doc`.
    // Assigned, not bound: a binding would re-run on every colour frame of a
    // theme crossfade, and `.text` on a RichText edit cannot be read back to
    // compare against anyway (it returns the serialised document). The
    // hanging indent is a pixel figure, so the font's own advance has to come
    // from here: Markdown.js never sees a font. The family is monospace, so
    // one character's advance describes every column.
    function _bake(doc, palette) {
        // A hidden body has no side anchors (header comment), so it is given
        // the shown one's width by hand before it lays out: at width 0 a
        // document wraps every character onto its own line (measured: 270 ms
        // for two blocks, against 90 for the bigger of them at its width).
        if (!doc.shown)
            doc.width = root._body.width;
        doc.text = Md.codeHtml(root.code, root.lang, palette,
                               root.monoFamily, root.fontPixelSize, root.bold,
                               { "charPx": _fm.advanceWidth("0"),
                                 "hangChars": root.wrapIndentChars });
        doc.key = root._keyOf(palette);
        _st.builds++;
    }

    // The CODE changed (or the type): the shown body, now.
    function _build() {
        _st.queued = false;
        if (!root.visible) { _st.dirty = true; return; }
        _st.dirty = false;
        _st.wholesale = false;
        root._bake(root._body, root._palette());
        _st.builtLen = root.code.length;
        _st.builtFence = Md.fenceOf(root.code);
        // A change of code makes the other body's document stale: drop it.
        _st.ahead = false;
        if (root._other.key !== "") {
            root._other.key = "";
            root._other.text = "";
        }
        root._restLater(root.restMs);
    }

    onCodeChanged: root._schedule()
    onLangChanged: root._schedule()
    onMonoFamilyChanged: root._schedule()
    onFontPixelSizeChanged: root._schedule()
    onBoldChanged: root._schedule()
    onWrapIndentCharsChanged: root._schedule()
    onVisibleChanged: {
        if (!root.visible)
            return;
        if (_st.dirty) root._schedule();
        if (_st.themeDirty) root._themeRebake();
    }
    Component.onCompleted: { _st.completed = true; root._schedule(); }

    // One rebuild per theme switch, once the crossfade has settled on the new
    // colours -- see the header comment -- and only if this block is on
    // screen. Off screen it latches and re-bakes when it is scrolled to,
    // keeping the document it has (and therefore its height) until then, so
    // nothing under it moves and the only cost of the delay is that a block
    // nobody is looking at carries the old theme's syntax colours for as long
    // as nobody is looking at it.
    // `settled` is Theme's word for "the tokens are final": the lerp path
    // says it when its fade lands, the snapshot path the moment the tokens
    // are written, behind its picture. Either way the bake lands once, on
    // the palette that will stay -- which a timer on fadeMs could only guess.
    Connections {
        target: Theme
        function onSettled() { root._themeRebake(); }
    }
    Connections {
        target: root.viewportHost
        // Only while there is something to do -- a re-bake waiting for the
        // block to come on screen, or a bake-ahead still owed: the band ticks
        // for every block in the history and most of them have neither.
        enabled: _st.themeDirty || (root.complete && !_st.ahead)
        ignoreUnknownSignals: true
        function onViewportSerialChanged() {
            if (_st.themeDirty)
                root._themeRebake();
            root._restLater(root.restMs);
        }
        function onLiveIndexChanged() { root._restLater(root.restMs); }
    }
    // The PALETTE changed: swap to the body that holds it, baking it first
    // only if neither does. The body the theme left stays for the way back.
    function _themeRebake() {
        if (!root.visible || !root._onScreen()) { _st.themeDirty = true; return; }
        _st.themeDirty = false;
        const p = root._palette();
        const key = root._keyOf(p);
        if (root._body.key === key)
            return;
        if (root._other.key !== key)
            root._bake(root._other, p);
        root._body = root._other;
        _st.ahead = true;
        root._restLater(root.restMs);
    }

    // ---- The other palette, baked at rest -----------------------------------
    // See the header. Every event that means "not at rest" restarts the
    // clock; when it runs out, a complete block on screen with nothing kept
    // in its other body bakes the other mode's colours into it.
    Timer {
        id: _rest
        onTriggered: root._bakeAhead()
    }
    function _restLater(ms) {
        _rest.interval = ms;
        _rest.restart();
    }
    function _bakeAhead() {
        if (_st.ahead || !root.complete || !root.visible || _st.dirty || _st.themeDirty)
            return;
        if (!root._onScreen())
            return;                       // asked again when the viewport moves
        const h = root.viewportHost;
        if (h && h.liveIndex !== undefined && h.liveIndex >= 0)
            return;                       // an answer is streaming: not rest
        if (!Theme.claimIdleSlot()) {
            root._restLater(16);          // another surface has this frame
            return;
        }
        const p = root._palette();
        const alt = {};
        let differs = false;
        for (const k in p) {
            alt[k] = Theme.counterpart(p[k], root.paletteTokens[k]);
            if (alt[k] !== p[k])
                differs = true;
        }
        _st.ahead = true;
        if (differs)
            root._bake(root._other, alt);
    }
    onCompleteChanged: if (root.complete) root._restLater(root.restMs)

    // "Is any part of me on screen", asked of `viewportHost` in scene
    // coordinates (its band is already grown by its own margin). No host, or
    // one that publishes no band, is on screen.
    function _onScreen() {
        const h = root.viewportHost;
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

    // ---- Copy ---------------------------------------------------------------
    property bool _copied: false
    Timer {
        id: _copiedTimer
        interval: 1200
        onTriggered: root._copied = false
    }
    function copy() {
        Quickshell.clipboardText = Md.copyText(root.code);
        root._copied = true;
        _copiedTimer.restart();
        root.copied();
    }

    // Nothing announces the affordance but the pointer: the copy button fades
    // in on hover of the block, over the standard presence fade.
    property real _hoverF: _hover.hovered ? 1 : 0
    Behavior on _hoverF { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

    // ---- Material -----------------------------------------------------------
    ShadowBox {
        anchors.fill: parent
        baseRadius: root.radius
        surfaceColor: root.surfaceColor
        backgroundColor: root.backgroundColor
        bevelColor: root.bevelColor
        shadowColor: root.shadowColor
        bevelWidth: 1
        shadowWidth: 3
    }

    // The lid. Its top corners take the box's radius so the two curves
    // coincide, which is the same rule the popup's header boxes follow.
    Rectangle {
        id: _header
        visible: root.showHeader
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.lidHeight
        color: root.headerColor
        topLeftRadius: root.radius
        topRightRadius: root.radius

        Text {
            anchors.left: parent.left
            anchors.leftMargin: root.padding
            anchors.verticalCenter: parent.verticalCenter
            text: root.label.length > 0 ? root.label : root.lang
            color: root.mutedColor
            font.family: root.monoFamily
            font.pixelSize: root.labelPixelSize
        }

        // Inset from the right by the same `padding` the label is inset from
        // the left, so the two are equidistant from the block's edges. Its
        // shadow falls to TRANSPARENT (shadowToAlpha): a raised box's shadow
        // otherwise carries an opaque band of its ground colour to the spread's
        // full width, and with 3 px of lid above the button that band painted
        // a header-coloured tab 3 px past the block's top edge and over its
        // right bevel on every hover (measured). Blended to alpha the tail is
        // at most 1 level outside the lid (measured on grabs).
        RaisedButton {
            id: _copyBtn
            anchors.right: parent.right
            anchors.rightMargin: root.padding
            anchors.verticalCenter: parent.verticalCenter
            height: 20
            minWidth: 26
            horizontalPadding: 6
            shadowToAlpha: true
            // The copy mark, and for a moment after a click the check: one
            // glyph for another at one size in one face, so the button keeps
            // its width and nothing around it moves.
            text: root._copied ? "\uF00C" : "\uF0C5"
            fontFamily: "Symbols Nerd Font"
            fontPixelSize: 12
            bold: false
            opacity: root._hoverF
            enabled: root._hoverF > 0.01
            surfaceColor: root.headerColor
            plateauColor: root.buttonPlateauColor
            plateauHoverColor: root.buttonPlateauHoverColor
            bevelColor: root.buttonBevelColor
            shadowColor: root.buttonShadowColor
            textColor: root.mutedColor
            onClicked: root.copy()
        }
    }

    // ---- Body ---------------------------------------------------------------
    // No Flickable, no WheelHandler, no horizontal axis: the block cannot
    // scroll, so it cannot swallow a wheel event on its way to the transcript.
    // Only top/left/right are anchored -- the box's height comes from the
    // wrapped content, so anchoring the bottom as well would be a loop.
    //
    // TWO of them, one shown (see the header). `key` is the palette a
    // body's document was baked with, "" while it holds nothing current.
    // Only the shown body follows the width: the two side anchors change on
    // one flag, and there is no `width:` binding here for the two-sided
    // instant to destroy (CLAUDE.md, the opposing-anchors law).
    component Body: TextEdit {
        id: doc
        property string key: ""
        readonly property bool shown: root._body === doc
        visible: doc.shown
        anchors.top: root.showHeader ? _header.bottom : doc.parent.top
        anchors.left: doc.shown ? doc.parent.left : undefined
        anchors.right: doc.shown ? doc.parent.right : undefined
        anchors.margins: root.padding
        // The anchors give the width, so nothing here ever reads
        // implicitWidth -- one read flips QQuickTextEdit into
        // requireImplicitWidth for good and 0.11 ms/append becomes 200 ms.
        readOnly: true
        selectByMouse: true
        activeFocusOnPress: true
        textFormat: TextEdit.RichText
        // Word boundary first, anywhere as the fallback: that fallback is what
        // keeps an unbreakable 400-character token inside the box.
        wrapMode: TextEdit.Wrap
        font.family: root.monoFamily
        font.pixelSize: root.fontPixelSize
        font.bold: root.bold
        color: root.textColor
        selectionColor: root.selectionColor
        selectedTextColor: root.selectionTextColor
        cursorVisible: false
    }
    Body { id: _docA }
    Body { id: _docB }
    property Body _body: _docA
    readonly property Body _other: root._body === _docA ? _docB : _docA

    HoverHandler { id: _hover }
}
