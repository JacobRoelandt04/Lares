pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import Quickshell

import "../../../common/theme"
import "../../../common/components"
import "../../../common/components/Markdown.js" as Md

// =============================================================================
// LlmPopup.qml
//
// Drop-in popup content for the local-LLM module: the web-shaped chat
// interface -- history on the left, the open conversation in the middle, the
// composer under it -- rendered in this shell's carved/raised material.
//
// NO DATA OWNERSHIP. Everything that must outlive a close -- the conversation
// store, the HTTP request in flight, the tokens still arriving -- lives in the
// `LlmService` (and its backend) the enclosing module creates and hands in.
// That is not a style choice: Ollama cancels a generation the instant its
// HTTP client disconnects (measured with curl: GPU 96% -> 0% in under a
// second, `srv stop: cancel task` in the journal), so the request has to be
// owned by something the popup's own lifetime cannot reach. Closing the popup
// is `visible: false`, never a destroyed request.
//
// THAT IS LITERAL. The requests that can run long are curl children of the
// backend (Qt's XHR cannot close a socket, so a stop through it would only
// make the module stop listening while the server generated on): the stop
// button kills one and ollama ends the answer within a millisecond of it, or
// abandons a load 30-150 ms after it with the card free inside half a second
// -- and a backend destroyed with this item would do the same to an answer
// nobody stopped.
//
// What DOES die with this item is view state: the scroll offset, which answers
// are folded, the half-typed question. `keepAlive` is the user's switch that
// forbids even that -- while the pin in the sidebar's header is lit the host
// must keep this item alive across a close, so reopening lands exactly where it
// was left. When it is dark the host may tear the content down and a reopen
// rebuilds it from the service, which never stopped.
//
// ONE VIEW. The quiet/verbose/normal trio is a system-update idea and does
// not apply here: a conversation is not a thing you look at three ways. There is
// no mode selector, no swipe and no strip above the content -- the model picker
// sits beside the send button, where the choice is made.
//
// ONE TOP ROW, and the session's controls live in it: [burger][pin][incognito]
// [New chat] at the left, the conversation's name and its answer count to their
// right. They are POPUP furniture, not sidebar furniture, and that is the point
// of the fold: the burger sends the history away entirely -- not to a vertical
// rail of the same buttons beside a narrowed conversation -- and the
// conversation takes the whole width with the same margin on both sides. The
// only thing that changes across a fold is New chat's width, from the panel's
// column to two slots; the row's total width is constant within each state, so
// incognito appearing never nudges the title.
//
// Drop-in contract, as SystemUpdatePopup has it:
//   - the content paints NO background; the host paints the surface.
//   - `implicitWidth` / `implicitHeight` carry no Behavior of their own -- the
//     host eases them (260 ms OutCubic).
// =============================================================================
FocusScope {
    id: root

    // =====================================================================
    //  REQUIRED INPUT
    // =====================================================================

    // LlmService: owns the backend, the conversation store and every message.
    // Created by the module OUTSIDE this item so a generation survives a close.
    property var service: null

    // =====================================================================
    //  HOST CONTRACT
    // =====================================================================

    // The user's "do not kill this session" switch, lit from the pin in the
    // sidebar's header. It lives on the service, not here, because the answer
    // to "may the host unload the popup?" has to survive the popup.
    readonly property bool keepAlive: !!root.service && root.service.sessionPinned

    // THE PARKED CONTENT (GooeyEngine). The engine builds this popup AHEAD of the click -- the pointer has rested
    // on the button for ~80 ms: LlmBarOwner's HoverIntent -- and holds it hidden until the click adopts it, so that the ~3 600 items
    // of a history are not built in the click's frame (182 ms of a 241 ms warm open). It says so with `parked`, as an
    // INITIAL property and then by writing it: while it is true this popup does what a built-but-hidden popup may -- its data and its
    // size are right (the rows, the transcript, the picker are built, laid out at the size they asked for) -- and NOTHING that is a
    // consequence of being SHOWN: it asks no service for anything (the model list is refreshed when it appears, `_onShown`), takes no
    // key, runs no timer or animation, and its history panel does not follow the store (it is brought up to date the moment the
    // content is shown). Never written here. A content built unparked (a notification's Open, a harness) shows at completion.
    //
    // NOT `recycle()`: a closed chat is not kept parked for the next open. The service keeps answering with the popup shut, and a kept
    // transcript would render that stream into a hidden item for as long as it is kept (two minutes, then a rebuild); the drafts and the
    // fold maps are a session's, and the hover build already covers the open that follows a pointer.
    property bool parked: false
    onParkedChanged: {
        if (root.parked)
            root.giveBackKeys();
        else if (root.visible)
            root._onShown();
    }

    // THE KEYS GO BACK WITH THE POPUP. The root is a FocusScope for this: whatever inside takes the focus (the composer, the title
    // edit, a history row's rename, a confirmation) makes the scope the window's focus item, and one write lets go of all of them.
    // A popup that is going away -- its owner calls this the moment it stops being up (`LlmBarOwner`: the close has begun, the
    // content is still on screen shrinking) -- must not keep them: the compositor hands the layer surface its keyboard back in the
    // middle of the close, Qt hands the keys to the composer of a popup that is nearly gone, and a text input is enabled on it
    // (qtwayland logs "Trying to enable <surface> but <surface> has focus"). And a PARKED popup must never hold them at all: the
    // engine reparents a closed content into its hidden park place with the focus flag still set -- Qt moves a focus item with its
    // tree -- and at the next activation of the window Qt hands the keys to it THERE (the same warning, once per screen in every
    // shell_probe run; the first keys typed over the bar would have gone into a hidden draft). Three ways in, three closed: the
    // owner's call at the start of the close, `onParkedChanged` (the content is parked WITH the focus), and `onFocusChanged`
    // (something asks for the focus while parked: a confirmation arriving).
    function giveBackKeys() {
        root.focus = false;
    }
    onFocusChanged: {
        if (root.focus && root.parked)
            root.giveBackKeys();
    }

    // Host actions. Everything the SERVICE owns the popup calls directly
    // (ask, stop, open, rename, remove, switchModel); only what belongs to the
    // desktop rather than to the module is signalled out.
    signal attachRequested()                        // the host runs the file chooser
    // What the chooser's dialog is called: the host passes it on when it opens the chooser (the shell's owner gives it to the portal
    // helper as the dialog's title), so the attach button's dialog says what it is for, not the name of the module whose helper it is.
    property string attachTitle: "Attach files"
    signal linkActivated(string url)                // the host opens the URL

    // ---- Keys on a layer surface -------------------------------------------------------------------
    //
    // This popup is typed in, and a layer surface has the keyboard only when its window asks for it. The request is
    // "onDemand" -- a click inside gives the keys, a click elsewhere takes them away -- and EXCLUSIVE for 120 ms when
    // the popup appears and whenever the pointer comes back onto it: a pointer already resting on the surface when
    // the mode flips gets nothing from OnDemand, and the pulse is what hands it the keys at once (the notes popup's
    // idiom, NotesPopup.qml). Skipped while the window already has the keys. The host
    // maps the engine's `popupKeyboard` onto its layer surface; a plain window ignores all of this.
    // `grabKeyboard: false` turns the pulse off.
    property bool grabKeyboard: true
    property bool _focusPulse: false
    readonly property string keyboardFocusRequest: root._focusPulse ? "exclusive" : "onDemand"
    function pulseKeyboard() {
        if (!root.grabKeyboard || root.Window.active)
            return;
        root._focusPulse = true;
        focusPulse.restart();
    }
    Timer {
        id: focusPulse
        interval: 120
        onTriggered: root._focusPulse = false
    }
    HoverHandler {
        onHoveredChanged: {
            if (hovered)
                root.pulseKeyboard();
        }
    }

    // THE OVERLAY LAYER. Qt Quick prunes pointer delivery at ancestor bounds
    // (measured: the model list painted over the transcript but a click on it
    // landed on the transcript underneath), and a clipping list clips any tip
    // near its edge. So everything that floats -- the model list, a HoverTip
    // -- is reparented into this one layer at the popup's root, above
    // everything, inside nothing.
    readonly property alias overlayItem: overlayLayer

    // The host (or a drop) hands a file path in; it comes back as a chip on
    // the composer and is resolved by the LlmAttachmentLoader below -- probe,
    // per-kind extraction (pdf pages, video frames, audio peaks), all through
    // one queued Process at a time. The popup only forwards chips.
    function attachFile(path) {
        attachLoader.load(path);
    }

    // What is currently clipped to the composer, for a host that drives an ask
    // from outside the composer (the mockup's Run page, a headless probe).
    function composerAttachments() {
        return composer.attachments || [];
    }
    function clearAttachments() {
        composer.attachments = [];
    }
    // The prompt, focused and entirely selected: what a host that pre-filled it wants ("Send to LLM"'s template --
    // one Backspace or any typing replaces it).
    function selectPrompt() {
        composer.focusField();
        composer.selectAllText();
    }

    // DICTATION INTO THE PROMPT (DictationService's shell route; the composer does the work): the prompt has the caret, and the
    // take's words go there -- never to the app under the popup.
    readonly property bool dictationActive: !root.parked && composer.dictationActive
    function dictationPreedit(text: string): void {
        composer.dictationPreedit(text);
    }
    function dictationCommit(text: string): void {
        composer.dictationCommit(text);
    }
    function dictationBefore(): string {
        return composer.dictationBefore();
    }

    LlmAttachmentLoader {
        id: attachLoader
        // What the model gets to LOOK at inside a pdf. EMBEDDED is the
        // default and the honest one: the pictures the document actually
        // contains, deduplicated, each tagged with the page it came from --
        // measured on a 74-page deck, 21 pictures for 1500 tokens against
        // 6432 for rendering the first 24 pages, which also missed every
        // figure past page 24. PAGES mode renders whole pages instead and is
        // the fallback for a document whose figures are vector art, where
        // there is nothing embedded to extract.
        imageMode: root.pdfImageMode
        // How big a text file may be follows the model (the service's
        // `textCapFor`: its context window, the num_ctx the module asks for).
        attachTextCapBytes: root.service ? root.service.textCapBytes : 49152
        pdfImageCap: root.pdfImageCap
        pdfImageMinArea: root.pdfImageMinArea
        // Pages mode only.
        pdfPageCap: root.pdfPageCap
        pdfDpi: root.pdfDpi
        onQueued: att => {
            composer.attachments = composer.attachments.concat([att]);
        }
        onResolved: att => {
            // Matched by the loader's own key, not by path: the same file can
            // be attached twice with different picture settings, and a
            // path match would hand one chip's result to the other -- leaving
            // the real one pending for ever. The loader keeps the passes
            // apart by object identity; `attachKey` is that identity carried
            // across the fresh object it resolves with.
            const list = composer.attachments.slice();
            for (let i = 0; i < list.length; i++) {
                const same = (list[i].attachKey !== undefined && att.attachKey !== undefined)
                           ? list[i].attachKey === att.attachKey
                           : (list[i].path === att.path && list[i].pending);
                if (same) {
                    list[i] = att;
                    break;
                }
            }
            composer.attachments = list;
        }
    }

    // =====================================================================
    //  OPTIONS
    // =====================================================================

    property string fontFamily: "Inter"
    // The reading face: the prompt being written (and its placeholder), the
    // sent prompt, the answer, the thinking. Everything else -- titles,
    // headers, figures, buttons, the history -- stays on `fontFamily`.
    property string bodyFontFamily: "Inter"
    property string monoFamily: "Consolas"

    // The popup's width with the history OUT (the history and the conversation); folded it is the history's footprint less.
    property int minWidth: 900
    property int minHeight: 640

    // ---- Layout ------------------------------------------------------------
    // ONE number. The gap outside a container and the gap inside it are the
    // same, so a row's inset from the popup's edge is the same on the left of
    // the history as on the right of the conversation, and the two containers'
    // feet land on one line.
    property real padding: 12
    property real containerRadius: 14
    property real rowInset: 6
    property int containerResizeMs: 260
    property real titleRowHeight: 24
    // "embedded" (the pictures in the document) or "pages" (whole pages
    // rendered), for a pdf whose figures are drawn as vector art.
    property string pdfImageMode: "embedded"
    property int pdfImageCap: 32
    // The smallest embedded picture that still counts as a figure (px^2);
    // 10 000 = 100x100. Decoration is caught by density, not by this.
    property int pdfImageMinArea: 10000
    property int pdfPageCap: 24
    property int pdfDpi: 110
    property real buttonHeight: 30
    property real buttonGap: 8

    // ---- Composer, chips, picker, pdf menu (forwarded to the composer) ----
    property int chipSize: 64
    property int chipFadeWidth: 24
    property int composerResizeMs: 260
    property int chipRevealMs: 120
    property int chipNameFontSize: 8
    property int capDotSize: 5
    property int capSlotWidth: 12
    property int vramBarHeight: 4
    property int vramMinStepPx: 6
    property real vramTrackOpacity: 0.22
    property real vramCardOpacity: 0.45
    property int modelRowHeight: 42
    property int pdfMenuWidth: 224
    property int vramSwapMs: 420
    property int vramLiveRefreshMs: 1000
    property bool pickerSwipeToSwitchBrand: true
    property real pickerSwipePixelToAngle: 2.5
    property real pickerNotesTipWidth: 200
    property real pickerNotesTipGap: 6
    property real grantsMenuWidth: 300
    property real grantsMenuMaxHeight: 320
    property real wrenchTipWidth: 280
    // The @-path completion: how many rows stand before the list
    // scrolls inside itself, how many matches are drawn at all, and the
    // carved corner it shares with the confirmation.
    property int  completionMaxRows: 6
    property int  completionMaxEntries: 120
    property real completionRadius: 10
    // How long the model list takes to change size on a brand switch.
    property int  pickerResizeMs: 260
    property real pickerStripeMutedSaturation: 0.22
    property real pickerStripeMutedLightnessMix: 0.4732
    property int  pickerDefaultStripeFadeMs: 160
    property int  pickerStripeSelectFadeMs: 120
    property bool pickerShowMoeColumn: true
    // ---- Tool calling ------------------------------------------------------
    // Lines of a confirmation's detail visible before its box scrolls inside.
    property int  confirmMaxLines: 12
    // The wrench's starting state. The latch itself is the SERVICE's (so it
    // survives a rebuilt popup); this only switches it on once, when the popup
    // is first given a service, so a shell that wants tools offered without
    // a click can say so. Off by default: a model hears about tools when the
    // user asks for them.
    property bool toolsDefaultOn: false
    // A finished tool block's result lines before it folds, and whether a
    // block opens folded (the handle line alone).
    property int  toolBlockMaxLines: 40
    property bool toolBlockCollapsed: true
    property real pdfMenuSliderScale: 0.8
    property int pdfMenuSettleMs: 250
    property int pdfImageCapMax: 80
    property int pdfImageMinAreaMax: 40000
    property int pdfImageMinAreaStep: 500
    property int pdfPageCapMax: 60

    // ---- Sidebar ----
    // The conversation history OPENS FOLDED: the expected use of this popup is to ask a question, and only seldom to browse
    // conversations. The burger opens it, and it stays as the user left it for as
    // long as this content lives. The list is built behind the fold all the same (the rows fill in without being watched).
    property bool sidebarOpen: false
    property real sidebarOpenWidth: 268
    property real sidebarRowGap: 6

    property int sidebarTitleSize: 12
    property int sidebarTimeSize: 10
    property int sidebarAnimMs: 240
    property real sidebarWaveConcurrency: 6.0

    // ---- One exchange, in detail (forwarded to the transcript) ----
    property int turnHeaderPaddingH: 11
    property int turnHeaderPaddingV: 8
    property int turnHeaderBottomGap: 6
    property int turnHeaderIconSize: 18
    property int turnHeaderIconGap: 8
    property real turnSweepIdleWidth: 26
    property real turnSweepIdleFeather: 12
    property int turnSweepActiveFeather: 12
    // real, as LlmTranscript takes them: an int here would truncate the mockup's
    // 7.5 to 7 and leave the two rows permanently marked modified.
    property real turnSweepIdleDepth: 7.5
    property real turnSweepActiveDepth: 7.5
    property real turnSweepIdleStrength: 0.65
    property real turnSweepActiveStrength: 0.65
    property real turnSweepIdleFalloff: 0.9
    property real turnSweepActiveFalloff: 0.9
    property real turnSweepBlendEnd: 0.32
    property int turnQuestionPadding: 10
    property int turnQuestionRadius: 10
    property int turnQuestionChevronStrip: 8
    property int turnChipGap: 6
    property int turnDrawerGap: 6
    property int turnDrawerBlockSpacing: 6
    property int turnDrawerHeadingSpacing: 8
    property real mdHeadingScale: 1.0
    property int mdCodePadding: 10
    property int mdCodeHeaderHeight: 26
    property int mdQuoteInset: 10
    property int mdQuoteBarWidth: 3
    property int mdTableRadius: 10
    property int mdTableCellPadH: 10
    property int mdTableCellPadV: 6
    property int mdImageInset: 6
    property int turnFooterButtonGap: 6
    property int turnFooterButtonHeight: 24
    property int turnFooterButtonMinWidth: 26
    property int turnFooterFigureMargin: 6
    property int turnErrorPadding: 10
    property int turnSeamFadeHeight: 42
    property int turnWaitBarGap: 6
    property real turnWaitBarTravel: 8
    property int turnWaitBarStaggerMs: 100

    // ---- Transcript ----
    property real logoSize: 170
    property real logoDepthScale: 1.0
    property real logoBevelWidth: 0.15
    property real logoFalloff: 1.0
    property real logoAmbient: 0.42
    property real logoHighlightGain: 0.85
    property real logoLightAngle: 0
    // How long the mark takes to arrive or leave when the selected model
    // changes: the lines translate and the image fades on this one clock.
    property int logoPresenceMs: 260
    property real scrollSpeed: 1.0
    // ONE band for every scrolling box in this popup: the sidebar, the
    // transcript, the draft, the chip strip, the confirmation's preview and
    // the allowances panel all fade their edges by the same distance, and
    // `scrollSpeed` above moves them all the same 120 px per notch.
    property real listFadeHeight: 34
    property real turnSpacing: 6
    property real followBand: 60
    property int bodyPixelSize: 13
    // The reading face's line pitch, as a multiple of its size. 1.15 puts
    // Exo 2 at 18.4 px on a 13 px body -- a paragraph's measure (1.41x the
    // size) rather than a UI label's (1.25x). Only the answer, the thinking
    // and the sent prompt take it: an editable field has no line pitch.
    property real bodyLineHeight: 1.15
    // Selection auto-scroll at the container's edges.
    property real autoScrollDeadZone: 12
    property real autoScrollRamp: 140
    property real autoScrollMaxSpeed: 1100
    property int codePixelSize: 12
    property int figureSize: 10

    // ---- One exchange ----
    property real turnQuestionMaxWidth: 0.78
    property real turnBlockGap: 8
    property real turnHeaderRadius: 14
    property real turnBoxRadius: 10
    property real turnDrawerInset: 10
    property real turnThumbSize: 64
    property int turnExpandMs: 260
    // The wait band's one trip: the head crosses, then the tail follows it
    // out. A language model reports no progress, so it loops rather than
    // fills -- it says "working", not "this far".
    property int turnWaitPeriodMs: 2000
    property real turnLoadFloorMs: 250
    property real turnWaitHeadSpan: 0.62
    property real turnWaitTailSpan: 0.62
    property real turnFoldCapMargin: 48
    property int turnTitleSize: 15
    property int turnSubtitleSize: 11
    property int turnQuestionMaxLines: 4

    // ---- Markdown ----
    property real mdBlockSpacing: 8
    property real mdHeadingSpacing: 12
    property real mdCodeRadius: 10

    // ---- Composer ----
    property int composerMinLines: 1
    property int composerMaxLines: 6
    property real composerPadding: 10
    property real composerButtonSize: 28

    // =====================================================================
    //  PALETTE
    //
    // Plain (not readonly) properties defaulting to a Theme token, so a host
    // that assigns one still wins and the mockup's panel edits the THEME rather
    // than these. Every shared component below is handed its colours from here:
    // ShadowBox, RaisedButton, ListSectionHeader and the rest ship eva-light
    // hex literals and are themed only by their caller.
    // =====================================================================
    property color surfaceColor: Theme.surface
    property color panelColor: Theme.panelSunk
    property color bevelColor: Theme.bevel
    property color borderColor: Theme.border
    property color shadowDeepColor: Theme.shadowDeep
    property color listBoxColor: Theme.listBox
    property color headerBoxColor: Theme.headerBox
    property color headerBoxBevelColor: Theme.headerBoxBevel
    property color headerBoxShadowColor: Theme.headerBoxShadow
    property color primaryText: Theme.textPrimary
    property color mutedText: Theme.textMuted
    property color faintText: Theme.textFaint
    property color accent: Theme.accent
    property color accentHover: Theme.accentHover
    property color accentBevel: Theme.accentBevel
    property color textOnAccent: Theme.textOnAccent
    property color okColor: Theme.ok
    property color errColor: Theme.error
    property color errStrongColor: Theme.errorStrong
    property color errTint: Theme.errorTint
    property color buttonPlateau: Theme.buttonPlateau
    property color buttonPlateauHover: Theme.buttonPlateauHover
    property color buttonBevel: Theme.buttonBevel
    property color buttonShadow: Theme.buttonShadow
    property color codeBgColor: Theme.terminalBg

    // One colour per category, in the order the service publishes them. The hue
    // lives in the inset shadow of a turn's header and in its icon, and nowhere
    // else -- the same rule the update's repo colours follow.
    // The module's OWN six hues (Theme.llm*), not the package repos': "code"
    // borrowing catAur, which IS the accent, would make a code conversation
    // indistinguishable from one with no category at all.
    property color catCodeColor: Theme.llmCode
    property color catSystemColor: Theme.llmSystem
    property color catExplainColor: Theme.llmExplain
    property color catWriteColor: Theme.llmWrite
    property color catDataColor: Theme.llmData
    property color catOtherColor: Theme.llmOther

    function categoryColor(key) {
        switch (key) {
        case "code":
            return root.catCodeColor;
        case "system":
            return root.catSystemColor;
        case "explain":
            return root.catExplainColor;
        case "write":
            return root.catWriteColor;
        case "data":
            return root.catDataColor;
        }
        return root.catOtherColor;
    }

    // =====================================================================
    //  DERIVED STATE
    // =====================================================================

    readonly property bool _generating: !!root.service && root.service.generating
    // The stream is only live HERE when the conversation being generated into
    // is the one on screen. Without this, opening another conversation while an
    // answer streams would paint that answer over the other conversation's last
    // turn -- not persisted, but exactly the kind of spill a conversation must
    // never show.
    readonly property bool _streamIsHere: !!root.service && root.service.generating && root.service.generatingId === root.service.activeId
    readonly property bool _waiting: root._streamIsHere && root.service.waitingForModel
    readonly property var _messages: root.service ? root.service.messages : []
    readonly property string _model: root.service ? root.service.model : ""

    // What the wrench shows for the current model: the tools this model would
    // be sent and the probe's verdict. Both are FUNCTION results on the
    // service, so they are re-read by hand -- on a model change, when a probe
    // lands, when the registry loads or a tool is toggled -- not bound: a
    // binding cannot see inside the service's caches.
    property var _toolsOffered: []
    property var _toolProbe: ({ state: "none", ms: 0, why: "" })
    function _refreshTools() {
        const s = root.service;
        if (!s || typeof s.toolsOffered !== "function") {
            root._toolsOffered = [];
            root._toolProbe = { state: "none", ms: 0, why: "" };
            return;
        }
        root._toolsOffered = s.toolsOffered(root._model);
        root._toolProbe = s.toolProbeInfo(root._model);
    }
    on_ModelChanged: root._refreshTools()
    onServiceChanged: {
        if (root.service && root.toolsDefaultOn && !root._toolsSeeded) {
            root._toolsSeeded = true;
            root.service.toolsEnabled = true;
        }
        root._refreshTools();
    }
    property bool _toolsSeeded: false
    Connections {
        target: root.service
        ignoreUnknownSignals: true
        function onToolProbeChanged(model) { root._refreshTools(); }
        function onToolsChanged() { root._refreshTools(); }
        // The wrench's latch is the service's. The composer toggles its own
        // copy on a click (its standalone contract), which breaks a binding,
        // so the service's value is WRITTEN into it whenever it changes --
        // the Tools tab's switch and a rebuilt popup both land this way.
        function onToolsEnabledChanged() {
            composer.toolsEnabled = !!root.service.toolsEnabled;
            root._refreshTools();
        }
    }
    // The capabilities behind `toolsOffered` arrive with the model list.
    Connections {
        target: root.service ? root.service.backend : null
        ignoreUnknownSignals: true
        function onModelsChanged() { root._refreshTools(); }
    }
    Connections {
        target: root.service && root.service.tools ? root.service.tools : null
        ignoreUnknownSignals: true
        function onLoaded() { root._refreshTools(); }
        function onEntriesChanged() { root._refreshTools(); }
        function onDisabledChanged() { root._refreshTools(); }
        function onGrantsChanged() { root._refreshTools(); }
    }
    readonly property bool _incognito: !!root.service && root.service.incognito

    // messages -> turns. A turn is one question and the answer to it; a "note"
    // message (a mid-conversation model switch) becomes a turn of its own that
    // renders as a rule with a line of text, because the reader needs to see
    // why the ink changed colour.
    // Which MESSAGE an open edit-and-resend is rewriting, -1 for none. The
    // composer's placeholder says so while it stands, because a mode the
    // reader cannot see is a mode they will send the wrong thing into.
    property int _editingMessage: -1

    // The queue strip's rows: facts only (a Repeater's model may hold no theme
    // token). `where` names the conversation a waiting message joins when it is
    // not the one in front of the user.
    readonly property var _queueRows: {
        const q = root.service ? root.service.queue : [];
        const act = root.service ? root.service.activeId : "";
        const out = [];
        for (let i = 0; i < q.length; i++) {
            const e = q[i];
            let where = "";
            if (e.convId !== act) {
                if (e.convId === "") where = "new chat";
                else {
                    const m = (root.service && root.service.store && root.service.store.meta) ? root.service.store.meta(e.convId) : null;
                    where = "in " + ((m && m.title) ? m.title : "another chat");
                }
            }
            out.push({ id: e.id, text: e.text !== "" ? e.text : ((e.attachments && e.attachments.length > 0) ? String(e.attachments[0].name || "a file") : ""),
                       model: e.model, where: where });
        }
        return out;
    }

    // The approval this popup's panel shows. A SPOKEN ask's approval is the panel of ITS conversation only: a chat open on another
    // one must not grow a Run button for a command the user never saw asked (Return or Y would answer it); the ask's toast
    // (LlmAttention) carries it there, and "Open chat" opens the conversation whose panel it is.
    readonly property var _confirmHere: {
        const pc = root.service ? root.service.pendingConfirm : null;
        return (pc && pc.spoken && pc.convId !== root.service.activeId) ? null : pc;
    }

    // A waiting message back in the composer: its text, its files and the model
    // it was queued under, to be edited and sent again.
    function _takeBackQueued(id) {
        if (!root.service) return;
        const e = root.service.takeBack(id);
        if (!e) return;
        composer.text = e.text;
        composer.attachments = e.attachments || [];
        if (e.model !== "" && e.model !== root.service.model) root.service.switchModel(e.model);
        composer.focusField();
    }

    readonly property var _turns: root._buildTurns(root._messages)
    readonly property int _liveIndex: root._streamIsHere && root._turns.length > 0 ? root._turns.length - 1 : -1

    function _buildTurns(msgs) {
        const out = [];
        if (!msgs)
            return out;
        for (let i = 0; i < msgs.length; i++) {
            const m = msgs[i];
            if (!m)
                continue;
            if (m.role === "note") {
                out.push({
                    isNote: true,
                    noteText: m.content || "",
                    at: m.at || 0
                });
                continue;
            }
            if (m.role === "user") {
                const t = root._blankTurn(m);
                // Which MESSAGE this row's question is. Edit-and-resend works
                // on messages; the footer button knows only its row, and a
                // row is not a message (a note is a row of its own).
                t.qIndex = i;
                out.push(t);
                continue;
            }
            if (m.role === "assistant") {
                // An answer with no question in front of it (a resumed
                // conversation whose first entry is a system reply) still needs
                // a row rather than being dropped on the floor.
                if (out.length === 0 || out[out.length - 1].isNote || out[out.length - 1].answer.length > 0)
                    out.push(root._blankTurn(null));
                const t = out[out.length - 1];
                t.answer = m.content || "";
                t.thinking = m.thinking || "";
                t.model = m.model || "";
                t.failed = !!m.error;
                t.errorText = m.error || "";
                t.stats = m.stats || null;
                t.thinkingMs = m.thinkingMs || 0;
                t.title = m.title || "";
                // The topic icon the classifier chose (a python glyph for a
                // python question). The header falls back to the category's
                // glyph without it.
                t.icon = m.icon || "";
                t.category = m.category || "other";
                // The tool calls the answer made, in order, and the loop's
                // closing note ("stopped after 6 tool rounds").
                t.toolCalls = m.toolCalls || [];
                t.toolNote = m.toolNote || "";
                t.titlePending = !!m.titlePending;
            }
        }
        return out;
    }

    function _blankTurn(m) {
        return {
            isNote: false,
            noteText: "",
            question: m ? (m.content || "") : "",
            images: m ? (m.images || []) : [],
            attachments: m ? (m.attachments || []) : [],
            answer: "",
            thinking: "",
            thinkingMs: 0,
            model: m ? (m.model || "") : "",
            at: m ? (m.at || 0) : 0,
            failed: false,
            errorText: "",
            stats: null,
            title: "",
            category: "other",
            titlePending: false,
            toolCalls: [],
            toolNote: ""
        };
    }

    readonly property int _answerCount: {
        let n = 0;
        for (let i = 0; i < root._turns.length; i++)
            if (!root._turns[i].isNote)
                n++;
        return n;
    }

    readonly property string _title: {
        if (!root.service || !root.service.store || root.service.activeId === "")
            return "";
        const c = root.service.store.conversations;
        for (let i = 0; i < c.count; i++) {
            const row = c.get(i);
            if (row.convId === root.service.activeId)
                // One line whatever the store holds: a title written before the
                // sanitiser existed, or hand-edited on disk, must still not
                // wrap the header.
                return (row.title || "").replace(/\s+/g, " ").trim();
        }
        return "";
    }

    // The conversation is brand new and has nothing in it: the only moment
    // making it incognito means anything, because there is nothing to hide yet.
    // That includes the chat that does not exist yet (a fresh shell, activeId ""):
    // the choice waits in the service (`incognito`) and the first send creates the
    // conversation with it, so the button is there from the first frame.
    readonly property bool _incognitoOffered: !!root.service && root._messages.length === 0

    // The title of the first answer is still being written, so the header has
    // nothing true to say. A skeleton stands in for it rather than a word.
    // A conversation that HAS something in it but no name yet is waiting on the
    // model; "New chat" is only honest for one that is genuinely empty. No word
    // ever stands in for a title being written -- the skeleton does.
    readonly property bool _titlePending: {
        if (!root.service || root.service.activeId === "" || root._title !== "")
            return false;
        return root._turns.length > 0 || root.service.titling;
    }

    // ---- The history WIDENS THE POPUP, as ONE fraction read off the width ----
    // (the player's `_sidebarF`: "the conversation is a constant width, it just gets nudged aside, expanding the popup")
    //
    // The conversation is `_chatWidth` wide in every state, and `_chatWidth` is what is left of `minWidth` (the popup's
    // width with the history out, 900) when the history is out: history + conversation = `minWidth`, and closing the
    // history keeps the conversation's width and just shrinks the popup. The
    // history is what opens and closes, and it takes ITS room from the popup: `implicitWidth` is `minWidth` while the
    // history is out and `minWidth` less the history's footprint when it is folded, the HOST eases the width (260 ms, the
    // only clock there is), and everything
    // the history moves reads how far the width has got: the panel's width, the gap it leaves behind, the
    // session row's right edge, the conversation's left edge. A Behavior of this popup's own on top of the
    // host's would ease twice, and a conversation whose width followed the box would re-wrap every paragraph
    // 15 times a fold (the transcript's text width is constant).
    //
    // In layout units (the body's), so the draw scale divides out: at rest folded the body is `_chatWidth`
    // wide, out it is `_chatWidth + _sidebarRoom` (= `minWidth` less the two paddings).
    readonly property real _sidebarRoom: root.sidebarOpenWidth + root.padding
    readonly property real _chatWidth: root.minWidth - root.padding * 2 - root._sidebarRoom
    //
    // A FOLD, NOT AN OPEN. The width also moves when the HOST opens the popup -- from nothing, on every open -- and read off it
    // then, the history slid in under every open with the history out, and the open's overshoot opened the folded history's
    // slot (the conversation box stepped aside and came back, New chat grew). So the width is read only while the history comes
    // or goes (`_folding`, from the burger to the box arriving at its new width); otherwise the fraction is read off the width
    // the popup ASKED for -- or the host's, where it gives more (a resizable stage) -- and the growing box reveals a layout
    // that holds still. (The engine keeps the content at its rest size through the open's overshoot anyway: GooeyEngine,
    // THE REST FRAME.)
    property bool _folding: false
    onSidebarOpenChanged: root._folding = true
    readonly property real _askedBodyWidth: root.implicitWidth - root.padding * 2
    readonly property real _foldWidth: root._folding ? body.width : Math.max(body.width, root._askedBodyWidth)
    readonly property real _openF: Math.max(0, Math.min(1, (root._foldWidth - root._chatWidth) / Math.max(1, root._sidebarRoom)))
    // What a host gives beyond the conversation AND the whole history (a resizable stage), snapped. Read off
    // the body's width ALONE, never as `width - slot - chat`: the slot is itself a binding on that width, and
    // one binding that reads two others sees them from different generations -- for a frame the new width and
    // the old slot, a conversation 51 px wider than it is, and every paragraph in it laid out twice
    // (measured: 28 `widthChanged` of the transcript in one opening, against 0 with this form). Float noise is a width change too.
    readonly property real _chatExtra: {
        const extra = body.width - root._chatWidth - root._sidebarRoom;
        return extra > 0.01 ? extra : 0;
    }
    // 0 when folded: the history does not become a rail, it LEAVES, and the
    // conversation keeps its width with the same margin on both sides.
    readonly property real _sidebarWidth: root.sidebarOpenWidth * root._openF
    // The panel's footprint including the gap to the conversation -- so the
    // gap fades out with the panel instead of surviving it as a 12 px dent.
    readonly property real _sidebarSlot: root._sidebarRoom * root._openF

    // The incognito button's presence: its slot opens and closes on this, and
    // New chat's width absorbs exactly that slot, so the row's total width --
    // and with it the title's left edge -- never moves.
    property real _incogF: root._incognitoOffered ? 1 : 0
    Behavior on _incogF {
        NumberAnimation {
            duration: root.sidebarAnimMs
            easing.type: Easing.OutCubic
        }
    }

    readonly property real _slot: root.buttonHeight + root.buttonGap
    // Folded, the row is burger + pin + incognito's reserved slot + ONE button:
    // New chat then measures two units across (button + gap + button) while
    // incognito is away, and exactly one unit when incognito takes its slot
    // back. Open, the row is the panel's width, so the title starts where the
    // conversation container does. Constant within each state either way --
    // that is what keeps the title still.
    readonly property real _sessionRowWidth: root.sidebarOpenWidth * root._openF
        + (3 * root._slot + root.buttonHeight) * (1 - root._openF)

    // Fold every answer away, or open them all. Public because a host may want
    // it on a key as well as on the title row's chevron -- a long conversation
    // folded down to a list of titles is how you find the answer you want.
    function collapseAllAnswers() {
        transcript.collapseAll();
    }
    function expandAllAnswers() {
        transcript.expandAll();
    }

    readonly property bool _anyExpanded: {
        const m = transcript.expandedMap;
        for (let i = 0; i < root._turns.length; i++) {
            const v = m[i];
            if (v === undefined || v)
                return true;
        }
        return false;
    }

    // =====================================================================
    //  SIZE
    //
    // No Behavior here: the host eases these (MockupStage and thePopup both do,
    // 260 ms OutCubic). An already-eased implicit size fed to a host that eases
    // it again animates twice.
    // =====================================================================
    // (to a hundredth: a box is asked for what it means, not for a float's noise)
    // `minWidth` with the history out (the conversation beside it), less the history's footprint when it is folded.
    implicitWidth: Math.round((root.minWidth - (root.sidebarOpen ? 0 : root._sidebarRoom)) * 100) / 100
    implicitHeight: Math.round(root.minHeight * 100) / 100

    // =====================================================================
    //  CONTENT
    //
    // One top row, then the containers: history beside the conversation while
    // the history is open, the conversation alone across the full width when
    // it is folded away. One gap everywhere -- above the row, under it, and
    // between the containers.
    //
    // The layout is written out rather than laid out by a RowLayout: the
    // folded state needs the panel's width AND the gap it leaves to go to
    // zero together, which a layout's fixed spacing cannot do.
    // =====================================================================
    Item {
        id: body
        anchors.fill: parent
        anchors.margins: root.padding
        // A fold has arrived when the box is the width the popup now asks for (`_folding`, above). (A handler of the width,
        // not of a binding on it: `_foldWidth` reads the flag and the width, and nothing it reads is written here but the flag.)
        onWidthChanged: {
            if (root._folding && Math.abs(body.width - root._askedBodyWidth) < 0.5)
                root._folding = false;
        }

        // -----------------------------------------------------------------
        // THE TOP ROW: the session's controls, and the conversation's name.
        //
        //     [burger][pin][(incognito)][ New chat ] | title ... n answers
        //
        // These four are POPUP furniture, not sidebar furniture. Folding the
        // history away must not fold the controls into a vertical rail
        // beside a narrowed conversation -- they stay exactly where they
        // are, horizontal, and the conversation takes the width the list
        // gave up. Across a fold the ONLY thing that changes here is New
        // chat's width; burger, pin and incognito do not move by a pixel.
        // -----------------------------------------------------------------
        Item {
            id: sessionRow
            // Named so a probe can sample how much these controls move
            // across a fold.
            objectName: "llmSessionRow"
            x: 0
            y: 0
            width: root._sessionRowWidth
            height: root.buttonHeight

            RaisedButton {
                id: burgerBtn
                x: 0
                width: root.buttonHeight
                height: parent.height
                minWidth: 0
                horizontalPadding: 6
                bold: false
                // The drop shadow blends to transparent rather than to the
                // surface colour: at rest the two are identical, but the
                // accent plateau of New chat passes close to this button
                // while the row resizes, and an opaque apron read as a plate.
                shadowToAlpha: true
                text: "\uf0c9"
                fontFamily: "Symbols Nerd Font"
                fontPixelSize: root.sidebarTitleSize
                surfaceColor: root.surfaceColor
                plateauColor: root.buttonPlateau
                plateauHoverColor: root.buttonPlateauHover
                bevelColor: root.buttonBevel
                shadowColor: root.buttonShadow
                accentColor: root.accent
                accentHoverColor: root.accentHover
                accentBevelColor: root.accentBevel
                textColor: root.mutedText
                faintTextColor: root.faintText
                accentTextColor: root.textOnAccent
                onClicked: root.sidebarOpen = !root.sidebarOpen
            }

            RaisedButton {
                id: pinBtn
                x: root._slot
                width: root.buttonHeight
                height: parent.height
                minWidth: 0
                horizontalPadding: 6
                bold: false
                text: "\uf08d"
                accent: root.keepAlive
                fontFamily: "Symbols Nerd Font"
                fontPixelSize: root.sidebarTitleSize
                surfaceColor: root.surfaceColor
                plateauColor: root.buttonPlateau
                plateauHoverColor: root.buttonPlateauHover
                bevelColor: root.buttonBevel
                shadowColor: root.buttonShadow
                accentColor: root.accent
                accentHoverColor: root.accentHover
                accentBevelColor: root.accentBevel
                textColor: root.mutedText
                faintTextColor: root.faintText
                accentTextColor: root.textOnAccent
                onClicked: {
                    if (root.service)
                        root.service.sessionPinned = !root.service.sessionPinned;
                }
            }

            RaisedButton {
                id: incogBtn
                x: root._slot * 2
                width: root.buttonHeight
                height: parent.height
                minWidth: 0
                horizontalPadding: 6
                bold: false
                opacity: root._incogF
                visible: opacity > 0.01
                enabled: root._incognitoOffered
                text: "\uf070"
                accent: root._incognito
                fontFamily: "Symbols Nerd Font"
                fontPixelSize: root.sidebarTitleSize
                surfaceColor: root.surfaceColor
                plateauColor: root.buttonPlateau
                plateauHoverColor: root.buttonPlateauHover
                bevelColor: root.buttonBevel
                shadowColor: root.buttonShadow
                accentColor: root.accent
                accentHoverColor: root.accentHover
                accentBevelColor: root.accentBevel
                textColor: root.mutedText
                faintTextColor: root.faintText
                accentTextColor: root.textOnAccent
                onClicked: {
                    if (root.service)
                        root.service.setIncognito(!root.service.incognito);
                }
            }

            RaisedButton {
                id: newChatBtn
                // Starts where incognito's slot ends -- that button's own
                // left edge when there is no incognito button -- and runs to
                // the row's right edge, which is the panel's edge when the
                // history is open and two slots when it is folded.
                x: root._slot * 2 + root._slot * root._incogF
                width: Math.max(0, sessionRow.width - x)
                height: parent.height
                minWidth: 0
                horizontalPadding: 0
                text: ""
                accent: true
                surfaceColor: root.surfaceColor
                plateauColor: root.buttonPlateau
                plateauHoverColor: root.buttonPlateauHover
                bevelColor: root.buttonBevel
                shadowColor: root.buttonShadow
                accentColor: root.accent
                accentHoverColor: root.accentHover
                accentBevelColor: root.accentBevel
                textColor: root.primaryText
                faintTextColor: root.faintText
                accentTextColor: root.textOnAccent
                onClicked: {
                    // Just the service: switching conversation runs
                    // `_restoreConvUi`, which sets the fold map (or expands)
                    // and then pins the newest answer. Expanding again HERE
                    // would run after that pin and hand the viewport back to
                    // the sticky anchor.
                    if (root.service)
                        root.service.newChat();
                }

                // The label and the glyph are drawn here rather than through
                // RaisedButton's own label because the button carries both
                // and they behave differently across a fold: the word fades
                // (presence, never a crossfade of two layouts) while the
                // glyph slides from the label's left to the button's centre
                // on the SAME fraction the width rides. The button reads as
                // shrinking around its own icon.
                // Two halves of ONE clock, so the word and the mark never
                // occupy the same pixels: the label fades out over the first
                // half of the fold (openF 1 -> 0.5) and the glyph only starts
                // its walk to the centre once the label is already gone
                // (openF 0.5 -> 0). Unfolding replays it in reverse. A plain
                // crossfade would let the "+" slide through the word.
                readonly property real _labelF: Math.max(0, Math.min(1, (root._openF - 0.5) * 2))
                readonly property real _glyphF: Math.max(0, Math.min(1, root._openF * 2))

                Text {
                    id: newChatGlyph
                    x: newChatBtn._glyphF * 10
                       + (1 - newChatBtn._glyphF) * Math.round((newChatBtn.width - width) / 2)
                    anchors.verticalCenter: parent.verticalCenter
                    text: "\uf067"
                    font.family: "Symbols Nerd Font"
                    // ONE size in both states, so the glyph never changes
                    // size across a toggle.
                    font.pixelSize: root.sidebarTitleSize
                    color: root.textOnAccent
                }
                Text {
                    anchors.centerIn: parent
                    opacity: newChatBtn._labelF
                    visible: opacity > 0.01
                    text: "New chat"
                    font.family: root.fontFamily
                    font.pixelSize: root.sidebarTitleSize
                    font.bold: true
                    color: root.textOnAccent
                }
            }
        }

        // ----- Title row: what this conversation is called, and the one
        //       control that acts on every answer at once. Its right edge
        //       is the transcript container's right edge; nothing is inset
        //       from it.
        Item {
            id: titleRow
            objectName: "llmTitleRow"
            // Beside the session's controls, on their line: one top row for
            // "which chat is this" and "what can I do to it".
            x: sessionRow.width + root.padding
            y: 0
            width: Math.max(0, body.width - x)
            height: root.buttonHeight

            Text {
                id: titleText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: turnCount.left
                anchors.rightMargin: 8
                visible: !titleEdit.visible && !titleSkeleton.visible
                // An empty conversation is not a titled thing yet; the
                // placeholder says so in the faint ink and the real name
                // replaces it the moment the first answer is titled.
                text: root._title.length > 0 ? root._title : "New conversation"
                color: root._title.length > 0 ? root.primaryText : root.faintText
                font.family: root.fontFamily
                font.pixelSize: 13
                font.bold: true
                elide: Text.ElideRight
                maximumLineCount: 1

                // The title is the affordance; nothing announces it but the
                // pointer.
                HoverHandler {
                    cursorShape: Qt.IBeamCursor
                }
                TapHandler {
                    onDoubleTapped: {
                        titleEdit.convId = root.service ? root.service.activeId : "";
                        titleEdit.text = root._title;
                        titleEdit.visible = true;
                        titleEdit.forceActiveFocus();
                        titleEdit.selectAll();
                    }
                }
            }

            // No word stands in for a title that has not been written yet.
            SkeletonBar {
                id: titleSkeleton
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                visible: root._titlePending && !titleEdit.visible
                width: Math.min(200, titleRow.width * 0.5)
                height: Math.round(root.titleRowHeight * 0.52)
                barColor: root.headerBoxColor
                groundColor: root.surfaceColor
            }

            TextInput {
                id: titleEdit
                Keys.forwardTo: [titleEditKeys]
                EditKeys {
                    id: titleEditKeys
                    target: titleEdit
                    selectAll: true
                }
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: turnCount.left
                anchors.rightMargin: 8
                visible: false
                color: root.accent
                selectionColor: root.accent
                selectedTextColor: root.textOnAccent
                font.family: root.fontFamily
                font.pixelSize: 13
                font.bold: true
                clip: true
                // The conversation this edit belongs to, captured when it
                // opens. Renaming `activeId` at Enter-time would rename whatever
                // is open THEN: start an edit, switch conversation, press
                // Enter, and the new conversation would take the old one's name.
                property string convId: ""
                onAccepted: {
                    if (root.service && titleEdit.convId !== "")
                        root.service.rename(titleEdit.convId, titleEdit.text);
                    titleEdit.visible = false;
                }
                Keys.onEscapePressed: titleEdit.visible = false
                onActiveFocusChanged: if (!activeFocus)
                    titleEdit.visible = false
            }

            Text {
                id: turnCount
                anchors.right: collapseAll.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                // Notes (a model switch) are rows, not answers.
                // Once the button is gone (the first send), the faint word is
                // what still says this chat is never saved.
                readonly property string _count: root._answerCount === 0 ? "" : root._answerCount === 1 ? "1 answer" : root._answerCount + " answers"
                readonly property bool _marked: root._incognito && !root._incognitoOffered
                text: turnCount._marked ? (turnCount._count === "" ? "Incognito" : "Incognito \u00b7 " + turnCount._count) : turnCount._count
                color: root.faintText
                font.family: root.fontFamily
                font.pixelSize: root.figureSize
            }

            RaisedButton {
                id: collapseAll
                // A square, the burger's mirror at the row's far end: same size,
                // same y, same glyph size.
                anchors.right: parent.right
                y: 0
                width: root.buttonHeight
                height: root.buttonHeight
                bold: false
                // chevron-up / chevron-down: fold every answer away, or open
                // them all again. \u escapes, not pasted private-use
                // characters -- a pasted one does not survive every editor
                // and renders as an empty box.
                text: root._anyExpanded ? "\uf077" : "\uf078"
                fontFamily: "Symbols Nerd Font"
                fontPixelSize: root.sidebarTitleSize
                minWidth: 0
                horizontalPadding: 0
                enabled: root._turns.length > 0
                surfaceColor: root.surfaceColor
                plateauColor: root.buttonPlateau
                plateauHoverColor: root.buttonPlateauHover
                bevelColor: root.buttonBevel
                shadowColor: root.buttonShadow
                accentColor: root.accent
                accentHoverColor: root.accentHover
                accentBevelColor: root.accentBevel
                textColor: root.primaryText
                faintTextColor: root.faintText
                accentTextColor: root.textOnAccent
                onClicked: {
                    if (root._anyExpanded)
                        root.collapseAllAnswers();
                    else
                        root.expandAllAnswers();
                }
            }
            HoverTip {
                show: collapseAll._hovered
                anchorItem: collapseAll
                overlayItem: root.overlayItem
                text: root._anyExpanded ? "Fold every answer" : "Open every answer"
                fontFamily: root.fontFamily
                surfaceColor: root.surfaceColor
                bevelColor: root.bevelColor
                shadowColor: root.borderColor
                textColor: root.primaryText
            }
        }

        LlmSidebar {
            id: sidebar
            objectName: "llmSidebar"       // the owner probe reads its width
            x: 0
            y: sessionRow.height + root.padding
            width: root._sidebarWidth
            height: Math.max(0, body.height - y)

            store: root.service ? root.service.store : null
            parked: root.parked
            activeId: root.service ? root.service.activeId : ""
            open: root.sidebarOpen
            openWidth: root.sidebarOpenWidth
            titlePending: root._titlePending

            fontFamily: root.fontFamily
            containerRadius: root.containerRadius
            rowInset: root.rowInset
            padding: root.padding
            resizeMs: root.containerResizeMs
            scrollSpeed: root.scrollSpeed
            rowGap: root.sidebarRowGap
            fadeHeight: root.listFadeHeight
            buttonHeight: root.buttonHeight
            titleSize: root.sidebarTitleSize
            timeSize: root.sidebarTimeSize
            animDuration: root.sidebarAnimMs
            waveConcurrency: root.sidebarWaveConcurrency
            categories: root.service ? root.service.categories : []
            overlayItem: root.overlayItem

            surfaceColor: root.surfaceColor
            listBoxColor: root.listBoxColor
            panelColor: root.panelColor
            bevelColor: root.bevelColor
            borderColor: root.borderColor
            headerBoxColor: root.headerBoxColor
            headerBoxBevelColor: root.headerBoxBevelColor
            headerBoxShadowColor: root.headerBoxShadowColor
            primaryText: root.primaryText
            mutedText: root.mutedText
            faintText: root.faintText
            accent: root.accent
            accentHover: root.accentHover
            accentBevel: root.accentBevel
            textOnAccent: root.textOnAccent
            okColor: root.okColor
            errColor: root.errColor
            catCodeColor: root.catCodeColor
            catSystemColor: root.catSystemColor
            catExplainColor: root.catExplainColor
            catWriteColor: root.catWriteColor
            catDataColor: root.catDataColor
            buttonPlateau: root.buttonPlateau
            buttonPlateauHover: root.buttonPlateauHover
            buttonBevel: root.buttonBevel
            buttonShadow: root.buttonShadow

            onSelected: id => {
                // The restore that `activeIdChanged` triggers owns the fold
                // map and the pin; a second expand here would undo
                // it. See the New chat button above.
                if (root.service)
                    root.service.open(id);
            }
            onRenameRequested: (id, title) => {
                if (root.service)
                    root.service.rename(id, title);
            }
            onRemoveRequested: id => {
                if (root.service)
                    root.service.remove(id);
            }
        }

        ColumnLayout {
            id: chatCol
            objectName: "llmChatColumn"
            x: root._sidebarSlot
            y: sessionRow.height + root.padding
            // CONSTANT while the history comes and goes: the box's width minus the slot IS `_chatWidth` all the
            // way (the slot is read off that width), so the text never re-wraps. A host that gives MORE than
            // was asked (a resizable stage) is filled; while the popup is still opening (the box narrower than
            // the conversation) the conversation keeps its width and the engine's clip reveals it.
            width: root._chatWidth + root._chatExtra
            height: Math.max(0, body.height - y)
            spacing: root.padding

            LlmTranscript {
                id: transcript
                Layout.fillWidth: true
                Layout.fillHeight: true

                turns: root._turns
                liveIndex: root._liveIndex
                liveText: root._streamIsHere ? root.service.liveText : ""
                liveThinking: root._streamIsHere ? root.service.liveThinking : ""
                waiting: root._waiting
                waitSay: root._streamIsHere ? root.service.waitSay : ""
                // Thinking is what is ARRIVING -- not "some thinking and no
                // answer yet", which would stay true through the silence after
                // the thinking ended while a tool call is written.
                thinkingLive: root._streamIsHere && root.service.liveActivity === "thinking"
                // One search: the sidebar's field filters the history AND
                // lights up matches in the open conversation. Highlight only
                // -- the viewport never moves for a match.
                searchQuery: sidebar.query
                bodyFontFamily: root.bodyFontFamily
                logoSize: root.logoSize
                logoDepthScale: root.logoDepthScale
                logoBevelWidth: root.logoBevelWidth
                logoFalloff: root.logoFalloff
                logoAmbient: root.logoAmbient
                logoHighlightGain: root.logoHighlightGain
                logoLightAngle: root.logoLightAngle
                logoPresenceMs: root.logoPresenceMs
                // The live turn's tool calls: the service's array
                // while the stream is here, nothing otherwise.
                liveToolCalls: root._streamIsHere && root.service.liveToolCalls ? root.service.liveToolCalls : []
                liveToolProgress: root._streamIsHere ? String(root.service.liveToolProgress || "") : ""
                // What the silence is: the service reads it from
                // the round's own facts -- ollama sends nothing while a model
                // writes a tool call, so the view never invents a figure.
                activity: root._streamIsHere ? root.service.liveActivity : ""
                activityMs: root._streamIsHere ? root.service.liveActivityMs : 0
                activityShown: root._streamIsHere && root.service.liveActivityShown
                liveThinkingMs: root._streamIsHere ? root.service.liveThinkingMs : 0
                contextTokens: root._streamIsHere ? root.service.roundPromptTokens : 0
                contextLimit: root._streamIsHere ? root.service.turnCtx : 0
                awaitingConfirm: root._streamIsHere && root.service.toolPhase === "confirm"
                toolBlockCollapsed: root.toolBlockCollapsed
                toolBlockMaxLines: root.toolBlockMaxLines
                onGrantRevokeRequested: (tool, key) => { if (root.service && root.service.tools) root.service.tools.forget(tool, key); }
                bodyLineHeight: root.bodyLineHeight
                loadFloorMs: root.turnLoadFloorMs
                autoScrollDeadZone: root.autoScrollDeadZone
                autoScrollRamp: root.autoScrollRamp
                autoScrollMaxSpeed: root.autoScrollMaxSpeed
                headerPaddingH: root.turnHeaderPaddingH
                headerPaddingV: root.turnHeaderPaddingV
                headerBottomGap: root.turnHeaderBottomGap
                headerIconSize: root.turnHeaderIconSize
                headerIconGap: root.turnHeaderIconGap
                sweepIdleWidth: root.turnSweepIdleWidth
                sweepIdleFeather: root.turnSweepIdleFeather
                sweepActiveFeather: root.turnSweepActiveFeather
                sweepIdleDepth: root.turnSweepIdleDepth
                sweepActiveDepth: root.turnSweepActiveDepth
                sweepIdleStrength: root.turnSweepIdleStrength
                sweepActiveStrength: root.turnSweepActiveStrength
                sweepIdleFalloff: root.turnSweepIdleFalloff
                sweepActiveFalloff: root.turnSweepActiveFalloff
                sweepBlendEnd: root.turnSweepBlendEnd
                questionPadding: root.turnQuestionPadding
                questionRadius: root.turnQuestionRadius
                questionChevronStrip: root.turnQuestionChevronStrip
                chipGap: root.turnChipGap
                drawerGap: root.turnDrawerGap
                drawerBlockSpacing: root.turnDrawerBlockSpacing
                drawerHeadingSpacing: root.turnDrawerHeadingSpacing
                mdHeadingScale: root.mdHeadingScale
                mdCodePadding: root.mdCodePadding
                mdCodeHeaderHeight: root.mdCodeHeaderHeight
                mdQuoteInset: root.mdQuoteInset
                mdQuoteBarWidth: root.mdQuoteBarWidth
                mdTableRadius: root.mdTableRadius
                mdTableCellPadH: root.mdTableCellPadH
                mdTableCellPadV: root.mdTableCellPadV
                mdImageInset: root.mdImageInset
                footerButtonGap: root.turnFooterButtonGap
                footerButtonHeight: root.turnFooterButtonHeight
                footerButtonMinWidth: root.turnFooterButtonMinWidth
                footerFigureMargin: root.turnFooterFigureMargin
                errorPadding: root.turnErrorPadding
                seamFadeHeight: root.turnSeamFadeHeight
                waitBarGap: root.turnWaitBarGap
                waitBarTravel: root.turnWaitBarTravel
                waitBarStaggerMs: root.turnWaitBarStaggerMs

                containerRadius: root.containerRadius
                rowInset: root.rowInset
                padding: root.padding
                scrollSpeed: root.scrollSpeed
                fontFamily: root.fontFamily
                monoFamily: root.monoFamily
                fadeHeight: root.listFadeHeight
                model: root._model
                turnSpacing: root.turnSpacing
                followBand: root.followBand
                bodyPixelSize: root.bodyPixelSize
                codePixelSize: root.codePixelSize
                figureSize: root.figureSize
                questionMaxWidth: root.turnQuestionMaxWidth
                questionMaxLines: root.turnQuestionMaxLines
                blockGap: root.turnBlockGap
                headerRadius: root.turnHeaderRadius
                boxRadius: root.turnBoxRadius
                drawerInset: root.turnDrawerInset
                thumbSize: root.turnThumbSize
                expandMs: root.turnExpandMs
                waitPeriodMs: root.turnWaitPeriodMs
                waitHeadSpan: root.turnWaitHeadSpan
                waitTailSpan: root.turnWaitTailSpan
                foldCapMargin: root.turnFoldCapMargin
                headerTitleSize: root.turnTitleSize
                headerSubtitleSize: root.turnSubtitleSize
                mdBlockSpacing: root.mdBlockSpacing
                mdHeadingSpacing: root.mdHeadingSpacing
                mdCodeRadius: root.mdCodeRadius
                overlayItem: root.overlayItem
                categories: root.service ? root.service.categories : []
                categoryColors: ({
                        code: root.catCodeColor,
                        system: root.catSystemColor,
                        explain: root.catExplainColor,
                        write: root.catWriteColor,
                        data: root.catDataColor,
                        other: root.catOtherColor
                    })

                surfaceColor: root.surfaceColor
                listBoxColor: root.listBoxColor
                bevelColor: root.bevelColor
                borderColor: root.borderColor
                headerBoxColor: root.headerBoxColor
                headerBoxBevelColor: root.headerBoxBevelColor
                headerBoxShadowColor: root.headerBoxShadowColor
                primaryText: root.primaryText
                mutedText: root.mutedText
                faintText: root.faintText
                accent: root.accent
                accentHover: root.accentHover
                accentBevel: root.accentBevel
                textOnAccent: root.textOnAccent
                errColor: root.errColor
                errTint: root.errTint
                buttonPlateau: root.buttonPlateau
                buttonPlateauHover: root.buttonPlateauHover
                buttonBevel: root.buttonBevel
                buttonShadow: root.buttonShadow
                codeBgColor: root.codeBgColor

                onCopyRequested: index => {
                    const t = root._turns[index];
                    if (t)
                        Quickshell.clipboardText = Md.copyText(t.answer);
                }
                onRegenerateRequested: index => {
                    if (root.service)
                        root.service.regenerate();
                    // Same order, same reason as a submitted question: the
                    // request first, then the scroll that ends the
                    // open-at-newest latch and hands the foot to the follow
                    // band. Without it the regenerated answer would rewrite
                    // itself under a header pinned at the top, and a long one
                    // would stream off the bottom of the viewport unseen.
                    transcript.scrollToBottom();
                }
                // Edit and resend: the question is rewritten IN PLACE and
                // everything after it is thrown away, which is what the
                // service's `editAndResend` does.
                onEditRequested: index => {
                    const t = root._turns[index];
                    if (!t || t.qIndex === undefined)
                        return;
                    root._editingMessage = t.qIndex;
                    composer.text = t.question;
                    composer.focusField();
                }
                onDeleteRequested: index => {
                    if (root.service)
                        root.service.removeTurn(index);
                }
                onLinkActivated: url => root.linkActivated(url)
            }

            // WHAT WAITS: the messages sent while the model was busy,
            // between the transcript and the composer. Absent when none waits;
            // its gap to the composer grows with its height, so the composer
            // is not jumped by a message being queued.
            LlmQueueStrip {
                id: queueStrip
                Layout.fillWidth: true
                Layout.preferredHeight: queueStrip.implicitHeight
                Layout.topMargin: -root.padding * (1 - queueStrip.presence)
                entries: root._queueRows
                fontFamily: root.fontFamily
                overlayItem: root.overlayItem
                surfaceColor: root.surfaceColor
                boxColor: root.listBoxColor
                bevelColor: root.bevelColor
                shadowColor: root.borderColor
                primaryText: root.primaryText
                mutedText: root.mutedText
                faintText: root.faintText
                accent: root.accent
                tipSurfaceColor: root.surfaceColor
                onRemoveRequested: id => { if (root.service) root.service.removeQueued(id); }
                onPromoteRequested: id => { if (root.service) root.service.moveQueued(id, 0); }
                onTakeBackRequested: id => root._takeBackQueued(id)
            }

            LlmComposer {
                id: composer
                Layout.fillWidth: true
                // The picker's ctx row talks to the service directly (ctxInfo/
                // setCtxMode/setCtxValue); the composer only pipes it through.
                service: root.service
                bodyFontFamily: root.bodyFontFamily
                swipeToSwitchBrand: root.pickerSwipeToSwitchBrand
                swipePixelToAngle: root.pickerSwipePixelToAngle
                notesTipWidth: root.pickerNotesTipWidth
                notesTipGap: root.pickerNotesTipGap
                grantsMenuWidth: root.grantsMenuWidth
                grantsMenuMaxHeight: root.grantsMenuMaxHeight
                wrenchTipWidth: root.wrenchTipWidth
                completionMaxRows: root.completionMaxRows
                completionMaxEntries: root.completionMaxEntries
                completionRadius: root.completionRadius
                scrollSpeed: root.scrollSpeed
                fadeHeight: root.listFadeHeight
                // Tool calling. The wrench's latch is
                // the SERVICE's: this binding seeds a rebuilt popup, the
                // click writes back through the signal, and the Connections
                // above keeps the two equal after the click has broken it.
                toolsEnabled: root.service ? !!root.service.toolsEnabled : false
                onToolsToggled: on => { if (root.service) root.service.toolsEnabled = on; }
                confirmRequest: root._confirmHere
                confirmMaxLines: root.confirmMaxLines
                onConfirmAnswered: (id, decision) => { if (root.service) root.service.answerConfirm(id, decision); }
                grants: root.service && root.service.tools ? root.service.tools.grants : []
                toolErrors: root.service && root.service.tools ? root.service.tools.errors : []
                toolsOffered: root._toolsOffered
                modelDeclaresTools: root.service && root.service.backend ? !!root.service.backend.capsOf(root._model).tools : true
                toolProbeState: root._toolProbe.state
                toolProbeMs: root._toolProbe.ms
                toolDefinitionTokens: root.service ? (root.service.toolDefinitionTokens || 0) : 0
                onGrantRevoked: (tool, key) => { if (root.service && root.service.tools) root.service.tools.forget(tool, key); }
                onAllGrantsRevoked: () => { if (root.service && root.service.tools) root.service.tools.forgetAll(); }
                vramSwapMs: root.vramSwapMs
                vramLiveRefreshMs: root.vramLiveRefreshMs
                chipSize: root.chipSize
                chipFadeWidth: root.chipFadeWidth
                resizeMs: root.composerResizeMs
                pickerResizeMs: root.pickerResizeMs
                stripeMutedSaturation: root.pickerStripeMutedSaturation
                stripeMutedLightnessMix: root.pickerStripeMutedLightnessMix
                defaultStripeFadeMs: root.pickerDefaultStripeFadeMs
                stripeSelectFadeMs: root.pickerStripeSelectFadeMs
                showMoeColumn: root.pickerShowMoeColumn
                chipRevealMs: root.chipRevealMs
                chipNameFontSize: root.chipNameFontSize
                capDotSize: root.capDotSize
                capSlotWidth: root.capSlotWidth
                vramBarHeight: root.vramBarHeight
                vramMinStepPx: root.vramMinStepPx
                vramTrackOpacity: root.vramTrackOpacity
                vramCardOpacity: root.vramCardOpacity
                modelRowHeight: root.modelRowHeight
                pdfMenuWidth: root.pdfMenuWidth
                pdfMenuSliderScale: root.pdfMenuSliderScale
                pdfMenuSettleMs: root.pdfMenuSettleMs
                pdfImageCapMax: root.pdfImageCapMax
                pdfImageMinAreaMax: root.pdfImageMinAreaMax
                pdfImageMinAreaStep: root.pdfImageMinAreaStep
                pdfPageCapMax: root.pdfPageCapMax
                // The pdf menu (right-click on a pdf chip's pictures glyph)
                // edits the module's own picture settings. It shows the
                // popup's values and asks for changes through one signal;
                // the popup writes the value back and re-extracts every pdf
                // chip under the new caps, so the chips' figures follow.
                pdfImageMode: root.pdfImageMode
                pdfImageCap: root.pdfImageCap
                pdfImageMinArea: root.pdfImageMinArea
                pdfPageCap: root.pdfPageCap
                // Per FILE, not per session: the menu names the chip it was
                // opened on and one opts key ("imageCap" | "imageMinArea" |
                // "pageCap"), and the loader re-extracts that attachment
                // alone under its own settings. The popup's properties above
                // stay what a NEWLY attached file starts from -- which is
                // what the control panel edits.
                onPdfSettingChanged: (index, key, value) => {
                    const list = composer.attachments;
                    if (index < 0 || index >= list.length)
                        return;
                    const att = list[index];
                    if (!att || att.kind !== "pdf")
                        return;
                    const o = {};
                    o[key] = Math.round(value);
                    attachLoader.setOpts(att, o);
                }
                generating: root._generating
                queueEnabled: !!root.service && typeof root.service.enqueue === "function"
                placeholder: root._editingMessage >= 0
                             ? "Rewrite the question -- this replaces it, and everything after it"
                             : (root.service && root.service.authAsked
                                ? "sudo is asking for your password in the authentication toast"
                                : (root._generating && composer.queueEnabled
                                   ? "Queue a message for " + (root._model === "" ? "the next free turn" : root._model)
                                   : (root._model === "" ? "Ask anything" : "Ask " + root._model)))
                minLines: root.composerMinLines
                maxLines: root.composerMaxLines
                radius: root.containerRadius
                padding: root.composerPadding
                buttonSize: root.composerButtonSize
                fontFamily: root.fontFamily
                monoFamily: root.monoFamily
                fontPixelSize: root.bodyPixelSize
                allowAttachments: true
                allowTools: true
                overlayItem: root.overlayItem

                // The model picker lives here, beside send: the choice is made
                // where the question is asked, not in a strip at the top.
                models: root.service && root.service.backend ? root.service.backend.models : []
                loaded: root.service && root.service.backend ? root.service.backend.loaded : ({})
                modelsBusy: root.service && root.service.backend ? root.service.backend.modelsLoading : false
                modelsOffline: root.service && root.service.backend ? root.service.backend.online === false : false
                currentModel: root._model

                surfaceColor: root.surfaceColor
                fieldColor: root.panelColor
                bevelColor: root.bevelColor
                shadowColor: root.borderColor
                listBoxColor: root.listBoxColor
                headerBoxColor: root.headerBoxColor
                primaryText: root.primaryText
                mutedText: root.mutedText
                faintText: root.faintText
                accent: root.accent
                accentHover: root.accentHover
                accentBevel: root.accentBevel
                textOnAccent: root.textOnAccent
                buttonPlateau: root.buttonPlateau
                buttonPlateauHover: root.buttonPlateauHover
                buttonBevel: root.buttonBevel
                buttonShadow: root.buttonShadow
                errColor: root.errColor

                onSubmitted: (text, attachments) => {
                    if (!root.service)
                        return;
                    // An edit-and-resend rewrites a finished turn: nothing to do while one is running.
                    if (root._editingMessage >= 0 && root.service.generating)
                        return;
                    if (root._editingMessage >= 0) {
                        const at = root._editingMessage;
                        root._editingMessage = -1;
                        root.service.editAndResend(at, text);
                        composer.clear();
                        composer.attachments = [];
                        transcript.scrollToBottom();
                        return;
                    }
                    // A turn is running (here or in another conversation): the
                    // message waits its turn, with the model the picker is on.
                    if (root.service.generating) {
                        if (root.service.enqueue(text, attachments) === "")
                            return;
                    } else {
                        root.service.ask(text, attachments);
                    }
                    composer.clear();
                    // The chips went with the message; leaving them would send
                    // the same files again on the next ask.
                    composer.attachments = [];
                    transcript.scrollToBottom();
                }
                onStopRequested: {
                    if (root.service)
                        root.service.stop();
                }
                onAttachRequested: root.attachRequested()
                // The chip owns the CHOICE, the loader owns the WORK: turning
                // a pdf's pictures on for the first time has to render its
                // pages, which is the loader's job and nobody else's. The
                // flag is already written on the real attachment object by
                // the time this fires; `onResolved` above swaps the patched
                // object back in when the render lands, which is what stops
                // the chip pulsing.
                onAttachmentImagesToggled: (index, on) => {
                    const a = composer.attachments[index];
                    if (a)
                        attachLoader.setIncludeImages(a, on);
                }
                onAttachmentRemoved: index => {
                    const list = composer.attachments.slice();
                    if (index >= 0 && index < list.length) {
                        list.splice(index, 1);
                        composer.attachments = list;
                    }
                }
                onModelPicked: id => {
                    if (root.service)
                        root.service.switchModel(id);
                }
            }
        }
    }

    // The one layer everything floating lives in (see `overlayItem`). Declared
    // after the content, so it stacks above it; z is belt and braces.
    Item {
        id: overlayLayer
        anchors.fill: parent
        z: 1000
    }

    // =====================================================================
    //  DRAG AND DROP
    //
    // The valid target is the union of the transcript and the composer,
    // bridging the gap between them: one conversation, one place to put a
    // file. While a file hovers it, a carved square grows out of the centre
    // -- fill translucent, bevel and inset shadow at full strength, so what
    // appears is an EDGE drawn onto the conversation rather than a card over
    // it -- with the drop glyph in the middle casting its shadow down through
    // the box onto the content below.
    //
    // Geometry is computed from the layout items' own x/y (reactive), never
    // mapToItem (not reactive). It lives above the overlay's own content so a
    // drag is legible even with the model list open.
    // =====================================================================
    DropArea {
        id: dropZone
        parent: overlayLayer
        x: body.x + chatCol.x + transcript.x
        y: body.y + chatCol.y + transcript.y
        width: transcript.width
        height: composer.y + composer.height - transcript.y
        keys: []

        onEntered: drag => {
            drag.accepted = drag.hasUrls;
        }
        onDropped: drop => {
            if (!drop.hasUrls)
                return;
            drop.accept();
            for (let i = 0; i < drop.urls.length; i++) {
                const u = drop.urls[i].toString();
                if (u.indexOf("file://") === 0)
                    root.attachFile(decodeURIComponent(u.substring(7)));
            }
        }

        // Presence is one eased fraction driving scale and opacity together:
        // the square grows out of the centre, quickly, and leaves the same
        // way. 0.86 as the starting scale is small enough to read as "growing
        // out" and large enough that the edge never travels far.
        property real _dragF: dropZone.containsDrag ? 1 : 0
        Behavior on _dragF {
            NumberAnimation {
                duration: 140
                easing.type: Easing.OutCubic
            }
        }

        // The shared drop affordance (FileDropOverlay, also the notes
        // popup's): the square, its glyph and the glyph's shadow.
        FileDropOverlay {
            anchors.fill: parent
            presence: dropZone._dragF
            radius: root.containerRadius
            surfaceColor: root.surfaceColor
            bevelColor: root.bevelColor
            shadowColor: root.borderColor
            glyphColor: root.primaryText
            glyphShadowColor: root.shadowDeepColor
        }
    }

    // =====================================================================
    //  LIFECYCLE
    //
    // Nothing here stops work: the service keeps generating with the popup
    // closed, which is the whole point of the module. What the popup does on
    // becoming visible is catch up -- refresh the model list, and land on the
    // newest answer, which is what a reader who closed the popup mid-answer
    // comes back for -- and take the keyboard.
    //
    // Nothing happens on leaving. Putting an empty conversation away and
    // letting go of the GPU belong to whoever knows the popup is GONE, and
    // `visible` is no witness to that: an item a Loader makes announces
    // `visible: false` as it is BUILT (measured: a handler here released the
    // model at every open) and again on close, about 200 ms
    // before it is destroyed, and a second screen's popup is invisible to it.
    // LlmResidency does both, once, when no popup of the
    // chat is open on any screen.
    // =====================================================================
    onVisibleChanged: {
        if (root.visible)
            root._onShown();
    }

    Component.onCompleted: {
        // The history's state handed over at the build (the owner's binding) is where it stands, not a fold: the change handler
        // runs for it during the build.
        root._folding = false;
        root._loadDraft();
        // onVisibleChanged never fires for an item created already visible (a
        // host that builds the content on open), so ask here as well.
        if (root.visible)
            root._onShown();
    }

    function _onShown() {
        // Shown means shown AND taken: a parked content that the engine has hosted but not yet released announces `visible` first, and
        // `onParkedChanged` comes back here once it has.
        if (root.parked)
            return;
        root._loadDraft();
        // Reopening IS the refresh -- which is why the model list has no
        // refresh button of its own.
        if (root.service && root.service.backend)
            root.service.backend.refreshModels();
        // The same latched pin as a conversation switch, NOT scrollToBottom:
        // on the first show the turns may not have landed yet (the store
        // loads async), and a scroll on empty content is a no-op that leaves
        // the viewport at the OLDEST turn once they arrive. The pin waits
        // for them, lands the newest answer's header at the top, and hides
        // the top fade until the reader scrolls -- opening always means the
        // most recent answer.
        transcript.openAtLastTurn();
        // Typing starts in the composer, and the layer surface is asked for the keys. (A turn later, so the popup may have been put
        // away again by then: a content parked in between must not take them.)
        Qt.callLater(() => {
            if (!root.parked)
                composer.focusField();
        });
        root.pulseKeyboard();
    }

    // =====================================================================
    //  PER-CONVERSATION UI STATE
    //
    // The draft, the chips and the fold map belong to a conversation, not to
    // the popup: switching away stashes them, switching back restores them.
    // Nothing else may travel: a draft's chips must never follow the user
    // into another conversation.
    // =====================================================================
    property var _convUi: ({})
    property string _uiConvId: ""

    function _stashConvUi() {
        if (root._uiConvId === "")
            return;
        const m = Object.assign({}, root._convUi);
        m[root._uiConvId] = {
            attachments: composer.attachments,
            expanded: transcript.expandedMap
        };
        root._convUi = m;
    }

    function _restoreConvUi(id) {
        const u = root._convUi[id];
        // The prompt is the service's (it outlives this popup); the key moves first, so the text written below lands on this chat.
        root._uiConvId = id;
        composer.loadText(root.service ? root.service.draftOf(id) : "");
        composer.attachments = u ? (u.attachments || []) : [];
        if (u && u.expanded !== undefined)
            transcript.expandedMap = u.expanded;
        else
            transcript.expandAll();
        // A conversation opens AT its newest answer, header at the top, as if
        // scrolling up were not an option -- and only that virgin state hides
        // the top fade.
        transcript.openAtLastTurn();
    }

    // THE PROMPT FOLLOWS THE TEXT, and survives the popup: every change is written to the service's store (in memory at once, to disk
    // after a pause), and a popup that is built -- or shown again after being parked while another screen's popup typed -- takes it back.
    function _loadDraft() {
        if (!root.service)
            return;
        root._uiConvId = root.service.activeId;
        const t = root.service.draftOf(root._uiConvId);
        if (composer.text !== t)
            composer.loadText(t);
    }
    Connections {
        target: composer
        function onTextChanged() {
            // a dictation preedit coming or going is not the prompt (LlmComposer DICTATION)
            if (root.service && !composer.dictationBusy)
                root.service.setDraft(root._uiConvId, composer.draftText());
        }
    }
    Component.onDestruction: {
        if (root.service)
            root.service.flushDrafts();
    }

    Connections {
        target: root.service
        function onActiveIdChanged() {
            // A half-typed rename belongs to the conversation it was started
            // on; leaving that conversation abandons it rather than letting
            // it land somewhere else.
            titleEdit.visible = false;
            root._editingMessage = -1;
            root._stashConvUi();
            root._restoreConvUi(root.service ? root.service.activeId : "");
        }
    }
}
