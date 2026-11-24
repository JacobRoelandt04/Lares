pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"
import "../../../common/components"

// =============================================================================
// LlmTranscript.qml
//
// The chat body: one carved container holding a column of LlmTurns. The
// container is the same material as the system update's list box -- carved
// fill, viewport filling the box exactly, rows inset and headers running to
// the edges -- so a conversation and a package list read as the same object.
//
// AUTO-FOLLOW IS A BAND, NOT A BOOLEAN
// ------------------------------------
// "Stick to the bottom while generating" cannot be a flag set when generation
// starts: the user scrolls up to re-read a paragraph mid-answer, and a flag
// yanks them back on the next token. The rule is a distance -- if the viewport
// is within `followBand` px of the foot, it is following -- re-armed on every
// contentY change, so scrolling up disarms it and scrolling back down arms it
// again without either being a mode. It is re-pinned on height and
// contentHeight changes as well, because a popup resize otherwise strands the
// newest tokens under the bottom edge, which is exactly when they matter.
//
// The band is re-measured on SCROLLING, never on growth. Qt emits
// contentYChanged from its own fixup as the content grows, and that
// notification arrives with contentHeight ALREADY at its new value and
// contentY still at the old one -- so measuring the band there sees a huge gap
// and disarms the follow at the exact moment an answer grew past the viewport,
// which is the moment it exists for. Measured there: ch 900 -> 1420 with cy
// still 305 turned the follow off for good; the transcript then sat in
// the middle of the second answer while the sixth streamed in below. A
// contentY change that arrives on a content height not yet seen is growth, not
// a scroll, and is not measured.
//
// THE VIEWPORT IS PUBLISHED AS A BAND, BECAUSE `visible` LIES IN A COLUMN
// ----------------------------------------------------------------------
// Every turn in this Column is `visible: true`, including the one 4000 px
// above the fold, so a surface inside a turn cannot tell whether it is on
// screen. Anything whose work is worth deferring -- the theme re-bake of a
// document that baked colours into its html -- asks `viewportBand()` (scene
// coordinates, grown by `viewportRebakeMargin`) and replays on
// `viewportSerial`. (A block also KEEPS the document the theme left and bakes
// the other mode's ahead at rest, so a switch is usually a swap -- CodeBlock's
// header has that story; this file only tells it where the viewport is.)
//
// THE LIVE TURN IS NOT WRITTEN INTO THE ARRAY
// -------------------------------------------
// `turns[liveIndex]`'s answer is overridden at the delegate by `liveText`.
// Copying the growing answer into the model array would rebuild the whole
// Repeater per token; the override is one property assignment into one
// already-built delegate, which is what makes streaming cost the same at turn
// 40 as at turn 1.
//
// A SELECTION DRAG AT AN EDGE SCROLLS, AND THE TRANSCRIPT IS WHO DOES IT
// ----------------------------------------------------------------------
// A text surface inside a scroller does not know where the scroller's edges
// are, and Qt's own selection stops at whatever is on screen when the pointer
// stops moving. So the surfaces (each answer's document, each thinking
// drawer, each sent question) push against three functions here --
// `autoScrollBegin` / `autoScrollAt(sceneY)` / `autoScrollEnd` -- and
// `SelectionAutoScroll` holds the law: a dead zone past the edge, a speed
// that grows linearly with the overshoot to a cap, a clamp at both ends of
// the content, and nothing that outlives the gesture. A drag that actually
// moves the ground counts as a user scroll: it ends the virgin pin and it
// moves the sticky anchor when it lets go.
//
// SCROLLING AND THE TWO EDGE FADES ARE ScrollDressing, AND IT IS THE ONLY ONE
// ---------------------------------------------------------------------------
// The wheel and the fades are the shell's, not this file's: one notch is 120
// px everywhere, and a fade is how far the content is from that end. Both come
// from ScrollDressing, declared as a SIBLING of the Flickable (a child would
// be reparented into contentItem and scroll away with the text).
//
// Nothing BELOW it scrolls: a code block or table in a Flickable of its own
// would swallow the wheel, and a wheel over a code block would do nothing at
// all. There is no Flickable and no second wheel handler anywhere in the
// subtree.
//
// What this file keeps is its own bookkeeping AFTER a wheel -- the follow band
// re-measured, the sticky anchor re-seated, the virgin pin ended -- which
// arrives as `onWheeled` (at the event) and again when the glide or the coast
// ENDS (`onMovingChanged`): a notch glides, so where the reader ended up is
// known only then. Until then the follow's pin holds off, or the next token
// of a streaming answer would pull a notch up from the foot straight back.
//
// COLLAPSE-ALL HOLDS THE READER'S PLACE; EXPAND-ALL RETURNS TO A STICKY ANCHOR
// ----------------------------------------------------------------------------
// Folding every answer at once moves every turn below the reader. Without an
// anchor the viewport keeps its contentY and therefore shows something else
// entirely -- usually the very bottom, because the content just got shorter
// than the scroll offset. Collapse-all: record the turn whose header is
// topmost in the viewport and its offset from the top BEFORE the toggle, then
// re-apply that offset on every frame of the fold (the fold changes
// contentHeight every frame, which is the tick this rides), clamped so the
// viewport can never end up past the end of the content and show nothing.
//
// Expand-all does NOT re-derive its anchor from whatever happens to sit at
// the scroll position -- scrolling a collapsed list is scanning headers, not
// moving one's place in the conversation. The anchor is "the turn I was last
// looking at", a STICKY pair (turn timestamp, offset) that changes in exactly
// two ways: the user toggles a specific turn (that turn becomes the anchor),
// or the user scrolls while every turn is open (the topmost visible turn
// becomes the anchor, live). Scrolling while collapsed moves nothing, so
// collapse-all / scroll / expand-all lands back on the turn the reader left.
//
// A QUESTION FOLD PINS ITS OWN TOP. Expanding a folded question grows the
// content, and if the viewport was following the foot the growth would
// drag the view down with the question's bottom edge. The same hold
// machinery covers it: the turn whose question is folding becomes the hold
// anchor at its current offset for the duration of the fold, so the question
// stays put and the content below is pushed DOWN.
//
// THE FADES ARE STATEMENTS OF DISTANCE
// ------------------------------------
// A fade's opacity is how far the viewport is from that end, in fade-heights
// (ScrollDressing's rule, shared with the sidebar). At rest-bottom it is
// exactly OFF -- so it can never dim the footer buttons -- and anywhere above
// that it says "there is more below",
// which is then true. The top fade is the same statement about the top, with
// one exception, which is the ONE thing this file suppresses: a conversation
// OPENED at its last turn hides it until the first user scroll
// (`_virginTop` -> `headSuppressed`) -- the reader was put there, the content
// above is history they did not scroll past, and the fade would claim they
// did. Any user scroll afterwards shows it again, even back at the same
// pixel: from then on the scroll position is theirs.
//
// OPEN AT THE LAST RESPONSE: `openAtLastTurn()` pins the LAST turn's header
// to the viewport top -- as if the conversation had just reached this turn
// and nothing above existed. It rides the same hold machinery as the folds
// (the header must stay pinned while MarkdownView builds the content above,
// which grows contentHeight for many frames), plus `_openPad`: when what
// remains below the last header is shorter than the viewport, the content is
// extended so the header can sit exactly at the top rather than as far as
// the clamp allows. The pad lives only until the first user scroll.
//
// The pin outranks a fold's hold and STOPS its timer. The popup calls
// `expandAll()` one line before `openAtLastTurn()` on every switch, and
// expandAll arms `holdTimer` for the length of a fold -- which would drop
// the open-at-last pin about 320 ms in, while a long conversation is still
// laying out, and leave the reader part way up it. Two holds cannot both own
// the viewport; the newer one takes it whole, timer included.
//
// AND THE PIN OUTRANKS THE STICKY ANCHOR.
// Expand-all's anchor is the sticky pair, keyed on a turn's timestamp, and on
// a conversation being RE-ENTERED that timestamp still matches: the anchor is
// the turn the reader had scrolled to before they left. An expand-all that ran
// after the pin, and after the new turns have landed, would take `_holdIndex`
// off the pin and put them back on that turn -- "it returns to the answer I
// was last looking at" -- and arm holdTimer, which then drops the pin entirely
// 320 ms later. The sticky anchor is right for an expand-all WITHIN a conversation
// and wrong for an open, so it is the virgin state that decides: while
// `_virginTop` stands the viewport belongs to the pin, and both folds change
// the map without touching the anchor. Nothing about expand-all/collapse-all
// after the reader has scrolled changes at all.
//
// The pin is not a moment, it is a STATE: it stands for as long as the virgin
// state does, so anything that arrives late and grows the content above the
// newest answer is corrected instead of shoving the reader down the
// conversation. The first user scroll ends the pin and the virgin state
// together; a submit ends both through scrollToBottom, which is what hands the
// foot back to the follow band while an answer streams.
//
// The call is an INTENT, not an action on the current array. The popup calls
// it from its conversation-switch path, which runs while `turns` still holds
// the PREVIOUS conversation (or nothing at all on a first open) -- the store
// hands the new turns over one assignment later. So the virgin state itself
// is the latch: as long as it stands, every wholesale `turns` change re-pins
// the (new) last turn, so bailing on an empty array, or holding a stale index
// into an array that was swapped underneath, cannot happen. The first user
// scroll ends it.
//
// And `_openPad` is a BINDING -- not a value anyone writes. A value frozen at
// settle would inflate contentHeight by a stale number on every later growth
// (late block heights, image decodes, the fold cap's final-frame swap), and
// the reader could drag the real content almost off screen. Re-deriving it off
// the change dispatch through Qt.callLater is always one event-loop turn late
// -- and that turn is a presented frame with the header sitting short of the
// top. Writing it inside onContentHeightChanged is not the alternative:
// contentHeight is bound to the pad, so that is a binding loop. What removes
// the whole problem is that the pad never needs contentHeight. A Column's last child sits at `implicitHeight - height`, so
// what stands below the last header is exactly that turn's own height plus
// the bottom pad -- and `_lastTurnH`, pushed up by the one delegate that is
// last, is the only geometry the pad reads. No loop, no callLater, and it
// settles inside the same polish pass that produced the height.
//
// ONE DENSITY. There is no `compact` / `listScale` view scalar and no
// per-model hue (the category owns the colour, in one place -- the header's
// inset). A font size bound to a per-view scalar re-shapes every QTextDocument
// on screen at once, which cost the system update 26 of its 37 ms per switch.
// =============================================================================
Item {
    id: root

    // ---- Content ---------------------------------------------------------
    property var    turns: []            // [{ question, answer, thinking, model, at,
                                         //    failed, errorText, stats, images,
                                         //    isNote, noteText, thinkingMs,
                                         //    title, category, titlePending }]
    property int    liveIndex: -1        // which turn is streaming (-1 = none)
    property string liveText: ""         // that turn's answer so far
    property string liveThinking: ""
    property bool   waiting: false       // request sent, no token yet
    property string waitSay: ""          // ... or not sent yet: what it waits for (the GPU), "" = the model is loading
    property bool   thinkingLive: false
    // Tool calling: the live turn's entries, a NEW array
    // on every state change of the service; the running tool's word; and
    // whether a confirmation is pending. Committed turns carry their own
    // `toolCalls` / `toolNote` in the array, copied by the popup's
    // `_buildTurns`. Fold state per block is per-turn UI state kept on the
    // delegate (`_toolOpen`), the way the thinking drawer's is.
    property var    liveToolCalls: []
    property string liveToolProgress: ""
    property bool   awaitingConfirm: false
    property bool   toolBlockCollapsed: true
    property int    toolBlockMaxLines: 40
    // index -> bool. State this item OWNS: it flips entries itself so it works
    // with no host logic at all, and reports every flip through `toggled` so a
    // host that wants to persist them can. A host may ASSIGN a whole map; it
    // must not bind one, or the first toggle would fight the binding.
    property var    expandedMap: ({})

    // ---- The taxonomy ----------------------------------------------------
    // Straight from LlmService: `categories` is the table (key, label, glyph,
    // colourToken, hint) and `categoryColors` is the host's resolved
    // key -> colour map, because the service is headless and a colour read
    // there could not follow a theme switch. Split here and handed to the turn
    // already resolved, so no delegate has to know the table.
    property var    categories: []
    property var    categoryColors: ({})

    // ---- Geometry --------------------------------------------------------
    property real   containerRadius: 14
    property real   rowInset: 6
    // The container's own inner padding. The turns are deliberately NOT inset
    // by it -- a header box is meant to meet the container's edges, the way
    // the update list's headers do -- so what it actually sets is the one
    // place inside this box that is not a turn: the empty state's text column.
    property real   padding: 12
    property real   scrollSpeed: 1.0
    property string fontFamily: "Inter"
    // The reading face, handed to every turn: the sent question, the answer,
    // the thinking. Headers, figures and the empty state stay on fontFamily.
    property string bodyFontFamily: "Inter"
    property string monoFamily: "Consolas"
    property real   fadeHeight: 34       // both edge fades measure with this

    // Extras, defaulted so a host that ignores them sees no change:
    //   model        named in the empty state ("Ask something." + the model)
    //   bodyPixelSize / codePixelSize  ONE density for every document in the
    //                transcript. Never bind these to a view-mode scalar.
    property string model: ""
    // ---- The empty state's logo -----------------------------------------
    // The mark of the SELECTED model, carved into the container above the two
    // lines. `logoModel` defaults to the same string the second line names, so
    // a host that already sets `model` gets the right logo for nothing; a
    // mark we do not have resolves to no logo and the two lines close back up
    // on their own (see LlmModelLogos and LogoRelief). A change of model
    // after creation animates: the lines translate and the image fades on
    // LogoRelief's one presence clock, `logoPresenceMs` long.
    property var    modelLogos: _defaultModelLogos
    property string logoModel: root.model
    property real   logoSize: 170
    // Space between the mark and "Ask something.". The container's own
    // padding, because that is the one spacing number this box has.
    property real   logoGap: root.padding
    property int    logoPresenceMs: 260
    // Pass-through for the carve's shape, so the panel can tune it. Defaults
    // are LogoRelief's own; see that file for what each one means.
    property real   logoDepthScale: 1.0
    property real   logoBevelWidth: 0.15
    property real   logoFalloff: 1.0
    property real   logoAmbient: 0.42
    property real   logoHighlightGain: 0.85
    property real   logoLightAngle: 0
    property int    bodyPixelSize: 13
    // The reading pitch, as a multiple of the face's own line height. See
    // LlmTurn.bodyLineHeight for the numbers.
    property real   bodyLineHeight: 1.15
    // Below this a turn's load_duration is the runner lookup rather than
    // the weights, so no load figure is shown.
    property real   loadFloorMs: 250
    property int    codePixelSize: 12
    property int    figureSize: 10
    property int    headerTitleSize: 15
    property int    headerSubtitleSize: 11
    property real   turnSpacing: 6
    // Radius of the boxes INSIDE a turn (header box, question box, code, the
    // error strip). A box that does not meet the container's corner has no
    // reason to follow the container's radius.
    property real   boxRadius: 10
    // The header box meets the container's left and right edges, so it takes
    // the container's corner and not one of its own -- see LlmTurn.
    property real   headerRadius: root.containerRadius
    // Room under the last answer, inside the Flickable's content. Bound to
    // the row inset ON PURPOSE: at max scroll the gap under the footer's
    // buttons must equal the gap between the leftmost button and the
    // container's left edge, and that left gap IS the row inset. One number,
    // measured twice.
    property real   bottomPad: root.rowInset
    // Passed straight through to every turn, so the host tunes one exchange
    // from one place rather than reaching into the delegate.
    property real   questionMaxWidth: 0.78
    property int    questionMaxLines: 4
    property real   blockGap: 8
    property real   drawerInset: 10
    property real   thumbSize: 64
    property int    expandMs: 260
    // The wait band's trip and the span each of its edges moves for; see
    // LlmTurn and Sweep.js.
    property int    waitPeriodMs: 2000
    property real   waitHeadSpan: 0.62
    property real   waitTailSpan: 0.62
    // What the model is doing while nothing arrives, and the live turn's
    // thinking time and context (LlmService.liveActivity and its
    // kin). The live turn is the only one any of them can be true of.
    property string activity: ""
    property int    activityMs: 0
    property bool   activityShown: false
    property real   liveThinkingMs: 0
    property int    contextTokens: 0
    property int    contextLimit: 0
    property real   mdBlockSpacing: 8
    property real   mdHeadingSpacing: 12
    property real   mdCodeRadius: 10
    property real   followBand: 60
    // THE BAND AFTER THE STREAM. 60 px is how far above the foot a reader may be and still have an answer that is being written
    // carry them down with it; once nothing is being written there is nothing to follow, and a small scroll up from the foot that
    // ends inside the band would be pinned straight back at the end of the glide.
    // At rest the transcript follows only a reader who is AT the foot (a resize, the last layout of the answer).
    property real   restBand: 2
    // Slack past the viewport that a fold is animated against. See LlmTurn:
    // the cap is what makes a 100-line and a 1000-line answer fold alike, and
    // the margin is what keeps the swap between capped and true height below
    // the bottom edge rather than one pixel above it.
    property real   foldCapMargin: 48

    // ---- Tunables, passed straight through to every turn --------------
    // See LlmTurn for what each one is; the defaults are the turn's.
    property real   headerPaddingH: 11
    property real   headerPaddingV: 8
    property real   headerBottomGap: 6
    property int    headerIconSize: root.headerTitleSize + 3
    property real   headerIconGap: 8
    property real   sweepIdleWidth: 26
    property real   sweepIdleFeather: 12
    property real   sweepActiveFeather: 12
    property real   sweepIdleDepth: 7.5
    property real   sweepActiveDepth: 7.5
    property real   sweepIdleStrength: 0.65
    property real   sweepActiveStrength: 0.65
    property real   sweepIdleFalloff: 0.9
    property real   sweepActiveFalloff: 0.9
    property real   sweepBlendEnd: 0.32
    property real   questionPadding: 10
    property real   questionRadius: root.boxRadius
    property real   questionChevronStrip: 8
    property real   chipGap: 6
    property real   drawerGap: 6
    property real   drawerBlockSpacing: 6
    property real   drawerHeadingSpacing: 8
    property real   mdHeadingScale: 1.0
    property real   mdCodePadding: 10
    property real   mdCodeHeaderHeight: 26
    property real   mdQuoteInset: 10
    property real   mdQuoteBarWidth: 3
    property real   mdTableRadius: 10
    property real   mdTableCellPadH: 10
    property real   mdTableCellPadV: 6
    property real   mdImageInset: 6
    property real   footerButtonGap: 6
    property real   footerButtonHeight: 24
    property real   footerButtonMinWidth: 26
    property real   footerFigureMargin: 6
    property real   errorPadding: 10
    property real   seamFadeHeight: 42
    property real   waitBarGap: 6
    // How far each END of a waiting bar travels, in pixels. A distance, not a
    // fraction, so a long line and a short one breathe by the same visible
    // amount; 8 is what the shortest of the three already did.
    property real   waitBarTravel: 8
    // The beat between one waiting bar's breath and the next one's, so the
    // column waves top to bottom instead of blinking as one block.
    property int    waitBarStaggerMs: 100

    // The popup's floating layer, for the turns' hover tips. Null falls back
    // to local parenting, which a harness is allowed to live with.
    property Item   overlayItem: null

    // The sidebar's live search text, for highlight ONLY: matches in the
    // questions and answers get a background wash, and the viewport is never
    // moved for one. Empty costs the streaming path nothing (the guard lives
    // in MarkdownView). The popup binds this to the sidebar's `query`.
    property string searchQuery: ""

    // ---- Palette ---------------------------------------------------------
    // Everything LlmTurn needs, plus the container's own three. `surfaceColor`
    // is the popup's ground OUTSIDE the carved box; `listBoxColor` is the fill
    // inside it, which is what the turns are drawn on.
    property color surfaceColor: Theme.surface
    property color listBoxColor: Theme.listBox
    property color bevelColor: Theme.bevel
    property color borderColor: Theme.border
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
    property color errColor: Theme.error
    property color errTint: Theme.errorTint
    property color codeBgColor: Theme.terminalBg
    property color buttonPlateau: Theme.buttonPlateau
    property color buttonPlateauHover: Theme.buttonPlateauHover
    property color buttonBevel: Theme.buttonBevel
    property color buttonShadow: Theme.buttonShadow

    signal toggled(int index)
    signal copyRequested(int index)
    signal regenerateRequested(int index)
    signal editRequested(int index)
    signal deleteRequested(int index)
    signal linkActivated(string url)
    // A tool block's rule link: the host forgets the grant (`tools.forget`).
    signal grantRevokeRequested(string tool, string key)

    readonly property int turnCount: root.turns ? root.turns.length : 0

    // The viewport, published: the turns need it to cap their fold, and the
    // fold probe needs it to know what "on screen" means.
    readonly property real viewportHeight: transcriptFlick.height
    readonly property real scrollY: transcriptFlick.contentY

    // ---- The viewport as a BAND, for the documents inside it -------------
    //
    // `visible` cannot answer "am I on screen" here. A turn 4000 px above the
    // fold sits in a Column, not in a viewport, so it is `visible: true` like
    // every other turn -- and without the band a light/dark switch re-bakes
    // EVERY MarkdownView and CodeBlock in the conversation in ONE frame.
    // Measured on this machine, one 36 KB code block per answer: 269 ms at two turns, 785 at eight, 1619 ms at
    // sixteen, each of them a SINGLE frame, and nine tenths of it inside the
    // code blocks -- a 36 KB block expands to 347 KB of HTML that
    // QTextDocument then has to parse. With the band: 104, 102, 168.
    //
    // So a surface that is about to do that work asks HERE instead. Three
    // things this band is, on purpose:
    //   * SCENE coordinates, so a surface asks with its own `mapToItem(null)`
    //     and needs to know nothing about who is between it and this file;
    //   * the FLICKABLE's rect, not the window's -- a popup behind another
    //     window is still on screen, and a document that skipped its re-bake
    //     for that reason would come back in the old theme's colours;
    //   * grown by `viewportRebakeMargin` on both sides, so the document just
    //     past the edge is already baked when it is scrolled to.
    // Duck-typed through `scrollHost`, which the turns already hand to every
    // surface they build (see LlmTurn): a host that does not publish a band
    // means "on screen".
    property real viewportRebakeMargin: 240
    function viewportBand() {
        const p = transcriptFlick.mapToItem(null, 0, 0);
        const m = root.viewportRebakeMargin;
        return { "top": p.y - m, "bottom": p.y + transcriptFlick.height + m };
    }

    // ...and the tick that says the band may have moved, so a surface that
    // deferred its work replays when it scrolls in. It is COALESCED -- at most
    // one tick per `interval` while the viewport moves, plus one after it
    // stops -- because the alternative is notifying every document in the
    // history on every frame of every scroll, which is a bill this file
    // exists to avoid. The surfaces listen only while they are actually
    // waiting (`Connections.enabled`), so a scroll with nothing pending costs
    // one integer.
    property int viewportSerial: 0
    Timer {
        id: bandTick
        interval: 120
        onTriggered: root.viewportSerial++
    }
    function _bandMoved() {
        if (!bandTick.running)
            bandTick.start();
    }

    // ---- The taxonomy, split ---------------------------------------------
    function categoryGlyph(key) {
        const c = root.categories;
        if (c)
            for (let i = 0; i < c.length; ++i)
                if (c[i].key === key)
                    return c[i].glyph || "";
        return "";
    }
    function categoryColor(key) {
        const m = root.categoryColors;
        if (m) {
            if (m[key] !== undefined)
                return m[key];
            if (m["other"] !== undefined)
                return m["other"];
        }
        return root.faintText;
    }
    function categoryLabel(key) {
        const c = root.categories;
        if (c)
            for (let i = 0; i < c.length; ++i)
                if (c[i].key === key)
                    return c[i].label || "";
        return "";
    }

    // ---- Expansion -------------------------------------------------------
    function _isExpanded(i) {
        const v = root.expandedMap ? root.expandedMap[i] : undefined;
        return v === undefined ? true : !!v;   // a new answer arrives open
    }
    function _setAll(v) {
        const m = {};
        for (let i = 0; i < root.turnCount; ++i)
            m[i] = v;
        root.expandedMap = m;                  // one assignment, one re-evaluation
        root._applyHold();
    }
    // Collapse-all anchors on whatever the reader is looking at right now --
    // the place is recorded BEFORE the map changes, because the moment it
    // changes every turn below the anchor starts moving. Expand-all anchors
    // on the STICKY anchor instead (see the header): the turn the reader last
    // engaged with is the one that expands back into view, wherever the
    // collapsed list was scrolled to in between.
    function collapseAll() {
        if (root._virginTop) { root._foldAllUnderPin(false); return; }
        root._beginHold();
        root._setAll(false);
    }
    function expandAll() {
        if (root._virginTop) { root._foldAllUnderPin(true); return; }
        const idx = root._stickyIndexNow();
        if (idx >= 0) {
            root._holdIndex = idx;
            root._holdOffset = root._stickyOffset;
            holdTimer.restart();
            root._setAll(true);
        } else {
            // No living sticky anchor (a fresh or switched conversation):
            // hold whatever the reader is looking at, like collapse-all does.
            root._beginHold();
            root._setAll(true);
        }
    }

    // A fold-all while the conversation is still as it was OPENED: the map
    // changes and the pin keeps the viewport. See the header comment -- this
    // is the OPEN path, and on it `openAtLastTurn()` is the only thing allowed
    // to say where the reader is. Re-pinning after the map change rather than
    // relying on `_setAll`'s own `_applyHold` is deliberate: the fold may have
    // changed which turn is last-and-open, and _pinLast re-arms the settle so
    // the heights this fold is about to produce are followed.
    function _foldAllUnderPin(v) {
        root._setAll(v);
        root._pinLast();
    }

    function _toggle(i) {
        // The toggled turn is the one the reader is engaging with, which is
        // the first of the two ways the sticky anchor moves. Recorded before
        // the map changes, while the turn is still where the reader sees it.
        root._rememberSticky(i);
        // Copy-then-assign: mutating in place would not notify, and a var
        // property only re-evaluates its readers on assignment.
        const m = {};
        const src = root.expandedMap || {};
        for (const k in src)
            m[k] = src[k];
        m[i] = !root._isExpanded(i);
        root.expandedMap = m;
        root.toggled(i);
    }

    // Put the viewport at an absolute offset, clamped, and drop any hold.
    // The pin in the sidebar exists so a closed popup comes back where it was
    // left, which means the scroll position has to be settable from outside.
    function scrollTo(y) {
        root._endVirgin();
        root._holdIndex = -1;
        dressing.stopMotion();
        transcriptFlick.contentY = Math.max(0, Math.min(Math.max(0, transcriptFlick.contentHeight - transcriptFlick.height), y));
    }

    function scrollToBottom() {
        root._endVirgin();
        root._holdIndex = -1;
        root._follow = true;
        dressing.stopMotion();
        transcriptFlick.contentY = Math.max(0, transcriptFlick.contentHeight - transcriptFlick.height);
    }

    // ---- Selection auto-scroll -------------------------------------------
    //
    // The transcript is the scrolling area every text surface inside it sits
    // in, so it is the transcript that owns the edge scroll -- not the turn,
    // not the document, neither of which knows where the viewport's edges
    // are. A turn hands each of its selectable surfaces `scrollHost: root`
    // and they push against these three functions; SelectionAutoScroll has
    // the law (dead zone, linear ramp, cap, clamp at the ends) and the tick.
    //
    // A drag that actually MOVES the ground is a user scroll in every sense
    // the rest of this file uses: it ends the virgin pin (so the top fade may
    // speak again) and it moves the sticky anchor when it lets go. A drag
    // that only selects what is already on screen is not, which is why
    // `_userTouch` is called from `autoScrollAt` and only once the overshoot
    // has actually armed the tick -- pressing inside a question must not
    // silently end the state the reader was put in.
    property real autoScrollDeadZone: 12
    property real autoScrollRamp: 140
    property real autoScrollMaxSpeed: 1100

    SelectionAutoScroll {
        id: selScroll
        flickable: transcriptFlick
        deadZone: root.autoScrollDeadZone
        rampDistance: root.autoScrollRamp
        maxSpeed: root.autoScrollMaxSpeed
        onScrolled: root._measureFollow()
    }

    function autoScrollBegin(owner) {
        selScroll.begin(owner);
    }
    function autoScrollAt(sceneY) {
        selScroll.at(sceneY);
        if (selScroll.active)
            root._userTouch();
    }
    function autoScrollEnd() {
        const wasScrolling = selScroll.active;
        selScroll.end();
        if (wasScrolling)
            root._trackSticky();
    }

    // The turn's top edge in the VIEWPORT's coordinates: 0 is the top edge,
    // negative means its header has scrolled off it. Public because the
    // place-holding below and the fold probe both need it, and neither should
    // be reaching into the Repeater to get it.
    function turnViewportY(index) {
        const it = turnRepeater.itemAt(index);
        return it ? (it.y - transcriptFlick.contentY) : NaN;
    }

    // ---- Holding the reader's place --------------------------------------
    //
    // The anchor is the first turn whose header is actually inside the
    // viewport. If none is -- the viewport top is deep inside one answer --
    // the anchor is the turn we are inside, at offset 0, which is the place
    // that answer's header will be at once everything folds.
    function _anchor() {
        let containing = -1;
        for (let i = 0; i < root.turnCount; ++i) {
            const it = turnRepeater.itemAt(i);
            if (!it)
                continue;
            const off = it.y - transcriptFlick.contentY;
            if (off >= -0.5) {
                if (off < transcriptFlick.height)
                    return { index: i, offset: Math.max(0, off) };
                break;                          // the rest are below the foot
            }
            containing = i;
        }
        return { index: containing, offset: 0 };
    }

    property int  _holdIndex: -1
    property real _holdOffset: 0
    Timer {
        id: holdTimer
        interval: root.expandMs + 60            // the fold, plus a frame or two
        onTriggered: root._holdIndex = -1
    }

    function _beginHold() {
        const a = root._anchor();
        root._holdIndex = a.index;
        root._holdOffset = a.offset;
        if (a.index >= 0)
            holdTimer.restart();
    }

    // A question fold's hold: pin the folding turn's top at its current
    // offset for the duration, so the growth goes DOWN and the auto-follow
    // cannot chase the question's bottom edge (the hold outranks the pin in
    // onContentHeightChanged). The offset is deliberately not clamped: a turn
    // whose header sits above the viewport still holds its question steady.
    function _holdTurn(i) {
        const it = turnRepeater.itemAt(i);
        if (!it)
            return;
        root._holdIndex = i;
        root._holdOffset = it.y - transcriptFlick.contentY;
        holdTimer.restart();
    }

    // ---- The sticky anchor -----------------------------------------------
    // "The turn I was last looking at." Moved by exactly two things: a manual
    // toggle (in _toggle), and a user scroll while every turn is open (below,
    // in the wheel handler). Never by scrolling a collapsed list, never by a
    // hold or a follow writing contentY.
    //
    // Keyed on the turn's `at` timestamp, not its index: deleting a turn
    // above the anchor shifts every index, and the popup swaps the whole
    // array on a conversation switch -- an index would then point at some
    // OTHER conversation's turn and expand-all would jump there. A stale
    // timestamp simply matches nothing and expand-all falls back to holding
    // the current view.
    property real _stickyAt: 0
    property real _stickyOffset: 0

    function _rememberSticky(i) {
        const t = root.turns;
        if (!t || i < 0 || i >= t.length || !t[i])
            return;
        root._stickyAt = t[i].at || 0;
        root._stickyOffset = Math.max(0, root.turnViewportY(i) || 0);
    }
    function _stickyIndexNow() {
        const t = root.turns;
        if (!t || !(root._stickyAt > 0))
            return -1;
        for (let i = 0; i < t.length; ++i)
            if (t[i] && t[i].at === root._stickyAt)
                return i;
        return -1;
    }

    readonly property bool _allExpanded: {
        for (let i = 0; i < root.turnCount; ++i)
            if (!root._isExpanded(i))
                return false;
        return root.turnCount > 0;
    }

    function _trackSticky() {
        if (!root._allExpanded || root._holdIndex >= 0)
            return;
        const a = root._anchor();
        if (a.index >= 0)
            root._rememberSticky(a.index);
    }

    // Re-applied on every contentHeight change, which during a fold is every
    // frame -- and, on a wholesale turns change, inside the polish pass that
    // first lays the new delegates out, which is what lands the pin before
    // the frame rather than a settle tick later. The clamp is the "never
    // empty" rule: contentY may not exceed the last scroll position that
    // still fills the viewport. This function writes contentY and NOTHING
    // contentHeight depends on.
    function _applyHold() {
        if (root._holdIndex < 0)
            return;
        const it = turnRepeater.itemAt(root._holdIndex);
        if (!it)
            return;
        const maxY = Math.max(0, transcriptFlick.contentHeight - transcriptFlick.height);
        transcriptFlick.contentY = Math.max(0, Math.min(maxY, it.y - root._holdOffset));
    }

    // ---- Open at the last response ---------------------------------------
    // See the header comment. The hold pins the last turn's header at offset
    // 0 and STAYS pinned for as long as `_virginTop` stands -- which also
    // hides the top fade and keeps `_openPad` alive -- so the first user
    // scroll is the one thing that ends any of it.
    property bool _virginTop: false

    // The last turn's height, pushed up by the delegate that IS the last turn:
    // a Repeater's items are not addressable as bindable geometry, and this is
    // the one number outside them that needs one.
    property real _lastTurnH: 0

    // The pad: the viewport minus what stands below the last turn's header,
    // which in a Column is that turn's own height plus the bottom pad. A pure
    // binding on things contentHeight does not feed, so there is no loop and
    // nothing to recompute later -- see the header comment.
    readonly property real _openPad:
        root._virginTop && root.turnCount > 0 && root._lastTurnH > 0
            ? Math.max(0, transcriptFlick.height - root._lastTurnH - root.bottomPad)
            : 0

    // Open-at-last is an intent latched by `_virginTop`; `onTurnsChanged`
    // below re-pins while it stands, which is what makes the intent survive
    // turns that arrive (or are swapped wholesale) after the call.
    function openAtLastTurn() {
        root._virginTop = true;
        root._follow = false;
        root._pinLast();
    }

    // ---- The Repeater's model is a mirror of `turns`, never `turns` ---------
    // A JS array handed to a Repeater is rebuilt WHOLE every time the
    // property is assigned, and the popup assigns it on every change to the
    // message list: the ask, the answer's commit, every title that lands.
    // Measured (eight turns): each one destroyed every code block
    // and every document of every turn and built them again -- the 36 KB
    // block's 90 ms bake three times per question -- and threw away what the
    // blocks had kept for the theme. A ListModel takes rows one at a time,
    // so an ask is ONE appended delegate and a commit is one row's record.
    //
    // A row holds one QtObject whose `d` is the turn as the popup built it,
    // nested arrays and all: a ListModel turns an array VALUE into a
    // sub-model, which nothing reading `toolCalls.length` could use, but an
    // object it keeps by pointer. Every row's `d` is re-assigned on every
    // change -- the bindings that read it re-evaluate to what they already
    // held and emit nothing, which is what makes this cheap -- and only a
    // turn that is really new gets a delegate.
    ListModel { id: turnRows }
    Component {
        id: turnRecord
        QtObject { property var d: ({}) }
    }
    function _syncTurns() {
        const t = root.turns || [];
        while (turnRows.count > t.length) {
            turnRows.get(turnRows.count - 1).rec.destroy();
            turnRows.remove(turnRows.count - 1);
        }
        for (let i = 0; i < t.length; i++) {
            if (i < turnRows.count)
                turnRows.get(i).rec.d = t[i];
            else
                turnRows.append({ "rec": turnRecord.createObject(root, { "d": t[i] }) });
        }
    }
    Component.onCompleted: root._syncTurns()
    onTurnsChanged: {
        root._syncTurns();
        if (root._virginTop)
            root._pinLast();
    }

    // Reads `turns.length` DIRECTLY, never `turnCount`: inside the
    // onTurnsChanged dispatch a dependent binding still holds the PREVIOUS
    // array's length (its re-evaluation rides the same notify, in connection
    // order), and a stale count here would either latch a populated transcript
    // as empty or pin an index into an array that no longer has it.
    function _pinLast() {
        const n = root.turns ? root.turns.length : 0;
        if (n <= 0)
            return;                        // latched: the next turns re-pin
        root._holdIndex = n - 1;
        root._holdOffset = 0;
        // This pin is governed by openSettle, not by holdTimer. The popup
        // calls expandAll() one line before openAtLastTurn(), and the fold's
        // timer would otherwise drop the pin one fold later -- see the header.
        holdTimer.stop();
        openSettle.lastCH = -1;
        openSettle.stable = 0;
        openSettle.restart();
        root._applyHold();
    }

    // The settle timer is a safety net for growth that announces itself to
    // nothing this file listens to; it stops once the content has been still
    // for four ticks. It does NOT release the pin. The pin belongs to the
    // virgin state and lasts exactly as long as it does: content that arrives
    // late -- an image decoding, a font landing, a document laid out a beat
    // after the rest -- would push the newest answer down the screen with
    // nothing left to pull it back. The first
    // user scroll ends both, together.
    Timer {
        id: openSettle
        interval: 120
        repeat: true
        property real lastCH: -1
        property int  stable: 0
        onTriggered: {
            root._applyHold();
            if (transcriptFlick.contentHeight === openSettle.lastCH) {
                if (++openSettle.stable >= 4)
                    openSettle.stop();
            } else {
                openSettle.lastCH = transcriptFlick.contentHeight;
                openSettle.stable = 0;
            }
        }
    }

    function _endVirgin() {
        if (!root._virginTop)
            return;
        openSettle.stop();
        root._holdIndex = -1;
        root._virginTop = false;   // the pad's binding follows it to zero
    }

    // A USER scroll -- wheel or touch drag, never a programmatic write --
    // ends the virgin state: from here on the scroll position is the
    // reader's own and the top fade may speak again.
    function _userTouch() {
        if (root._virginTop)
            root._endVirgin();
    }

    // ---- Auto-follow -----------------------------------------------------
    property bool _follow: true
    // The content height the band was last measured against. See the header.
    property real _seenCH: -1
    function _measureFollow() {
        if (transcriptFlick.contentHeight !== root._seenCH) {
            root._seenCH = transcriptFlick.contentHeight;   // growth, not a scroll
            return;
        }
        root._follow =
            (transcriptFlick.contentHeight - transcriptFlick.height - transcriptFlick.contentY) <= (root.liveIndex >= 0 ? root.followBand : root.restBand);
    }
    // Not while the wheel's glide or coast is running: a notch up from the foot starts
    // inside the follow band and the answer streaming in would pull the list back to the
    // foot on its next token, cancelling the reader's scroll. The glide's end measures the
    // band afresh and pins.
    function _pin() {
        if (!root._follow || dressing.moving)
            return;
        const y = Math.max(0, transcriptFlick.contentHeight - transcriptFlick.height);
        if (Math.abs(transcriptFlick.contentY - y) > 0.5) {
            dressing.stopMotion();
            transcriptFlick.contentY = y;
        }
    }

    // One clock for every relative time in the transcript: each turn asks it
    // for the instant its own words change ("just now" -> "1 min ago"), and
    // only while they are on screen, so it wakes on those instants alone and
    // a hidden transcript asks for nothing (LlmTurn, "When it was asked").
    // Like every BoundaryClock it runs only while the item it is declared in
    // is shown: a boundary asked for before a hide is dropped with it, so a
    // hidden transcript wakes for nothing either; shown again, the
    // clock publishes the wall once and every turn asks afresh.
    BoundaryClock {
        id: relClock
    }

    // =====================================================================
    // The carved container
    // =====================================================================
    ShadowBox {
        id: box
        anchors.fill: parent
        baseRadius: root.containerRadius
        surfaceColor: root.surfaceColor
        bevelColor: root.bevelColor
        shadowColor: root.borderColor
        backgroundColor: root.listBoxColor
        bevelWidth: 1
        shadowWidth: 3

        // The viewport fills the box EXACTLY: a turn's header box is meant to
        // meet the container's edges and share its top corner. The rows carry
        // the inset, not the viewport.
        Flickable {
            id: transcriptFlick
            objectName: "llmTranscriptFlick"      // the scroll probe wheels it
            anchors.fill: parent
            clip: true
            contentWidth: width
            contentHeight: turnCol.implicitHeight + root.bottomPad + root._openPad
            boundsBehavior: Flickable.StopAtBounds

            onContentYChanged: { root._measureFollow(); root._bandMoved(); }
            // A hold outranks the follow band: while one is running the
            // reader's anchor is the only thing allowed to write contentY.
            // The pad needs no refresh here: it is a binding on the last
            // turn's height, which this dispatch has already seen.
            onContentHeightChanged: {
                root._seenCH = transcriptFlick.contentHeight;
                if (root._holdIndex >= 0)
                    root._applyHold();
                else
                    root._pin();
            }
            onHeightChanged: { root._pin(); root._bandMoved(); }

            // A touch drag is a user scroll too.
            onMovementStarted: root._userTouch()
            onMovementEnded: root._trackSticky()

            Column {
                id: turnCol
                width: transcriptFlick.width
                spacing: root.turnSpacing

                Repeater {
                    id: turnRepeater
                    model: turnRows

                    delegate: LlmTurn {
                        id: turn
                        required property int index
                        required property var rec    // the row's record; `rec.d` is the turn

                        width: turnCol.width

                        question: turn.rec.d.question || ""
                        // The live turn's answer comes from the property, not
                        // from the array: see the header comment.
                        answer: turn.index === root.liveIndex
                                ? root.liveText : (turn.rec.d.answer || "")
                        thinking: turn.index === root.liveIndex
                                  ? root.liveThinking : (turn.rec.d.thinking || "")
                        model: turn.rec.d.model || ""
                        at: turn.rec.d.at || 0
                        clock: relClock
                        streaming: turn.index === root.liveIndex && !root.waiting
                        waiting: turn.index === root.liveIndex && root.waiting
                        waitSay: turn.index === root.liveIndex ? root.waitSay : ""
                        thinkingLive: turn.index === root.liveIndex && root.thinkingLive
                        failed: !!turn.rec.d.failed
                        errorText: turn.rec.d.errorText || ""
                        stats: turn.rec.d.stats || null
                        images: turn.rec.d.images || []
                        attachments: turn.rec.d.attachments || []
                        // The live turn's comes from the service: the pending
                        // message has none until it commits, and the drawer
                        // should say "thought for" the moment a round ends.
                        thinkingMs: turn.index === root.liveIndex ? root.liveThinkingMs
                                                                  : (turn.rec.d.thinkingMs || 0)
                        toolCalls: turn.index === root.liveIndex
                                   ? root.liveToolCalls : (turn.rec.d.toolCalls || [])
                        toolProgress: turn.index === root.liveIndex ? root.liveToolProgress : ""
                        awaitingConfirm: turn.index === root.liveIndex && root.awaitingConfirm
                        toolNote: turn.rec.d.toolNote || ""
                        toolExpanded: turn._toolOpen
                        toolBlockCollapsed: root.toolBlockCollapsed
                        toolBlockMaxLines: root.toolBlockMaxLines
                        isNote: !!turn.rec.d.isNote
                        noteText: turn.rec.d.noteText || ""

                        title: turn.rec.d.title || ""
                        titlePending: !!turn.rec.d.titlePending
                        // The service stores a per-message topic icon; the
                        // turn draws it and falls back to the category's
                        // glyph for messages that predate it -- the sidebar
                        // row's rule, applied where the header is drawn. The
                        // tip names the CATEGORY either way: the icon narrows
                        // the topic, the colour and the label stay the
                        // category's.
                        topicIcon: turn.rec.d.isNote ? "" : (turn.rec.d.icon || "")
                        categoryGlyph: turn.rec.d.isNote ? ""
                            : root.categoryGlyph(turn.rec.d.category || "other")
                        categoryColor: root.categoryColor(turn.rec.d.category || "other")
                        categoryLabel: turn.rec.d.isNote ? ""
                            : root.categoryLabel(turn.rec.d.category || "other")
                        overlayItem: root.overlayItem
                        searchQuery: root.searchQuery

                        // The open-at-last pad reads the LAST turn's height;
                        // the delegate that is last is the one that has it.
                        readonly property bool isLast: turn.index === root.turnCount - 1
                        onIsLastChanged: if (turn.isLast) root._lastTurnH = turn.height
                        onHeightChanged: if (turn.isLast) root._lastTurnH = turn.height
                        Component.onCompleted: if (turn.isLast) root._lastTurnH = turn.height

                        // THE ANCHOR SAYS WHEN IT MOVED. A hold is "keep this
                        // turn at this offset", so the moment the turn moves is
                        // the moment to re-seat the viewport -- and on a
                        // wholesale turns change that moment is the Column's
                        // polish, which no contentHeight change need announce:
                        // swap a conversation for one of the same total height
                        // and contentHeight never moves, while every delegate
                        // in it is new and starts at y = 0. Measured without
                        // it: seven frames at the TOP of the new conversation
                        // before the settle timer's first tick dragged it to
                        // the newest answer.
                        onYChanged: if (root._holdIndex === turn.index) root._applyHold()

                        expanded: root._isExpanded(turn.index)
                        // The drawer is per-turn UI state with no host
                        // meaning, so it lives here rather than in a second
                        // map the host would have to carry.
                        thinkingExpanded: turn._thinkOpen
                        property bool _thinkOpen: false
                        // id -> open, for the tool blocks; a toggle flips
                        // what the turn currently shows (its default for an
                        // id the map does not have yet).
                        property var _toolOpen: ({})

                        // WHICH HEADER SHARES THE CONTAINER'S CORNER IS A
                        // POSITION, NOT AN INDEX. `index === 0` is right only
                        // while the reader is at the top:
                        // open a conversation at its last answer and THAT
                        // header is pinned flush to the container's rounded,
                        // inset-shadowed edge with its own smaller radius, so
                        // a crescent of the container's shadow shows outside
                        // the header's and the two gradients mash. The turn
                        // gets its distance to the edge instead and derives
                        // the corner from it, so the header at the top always
                        // presents the container's corner, whichever it is.
                        //
                        // CLAMPED so it is not a per-frame write for every
                        // delegate in a long conversation: outside
                        // [-1, containerRadius] the corner is settled, so the
                        // value is pinned to the end of the range it left and
                        // nothing downstream is notified.
                        topOffset: Math.max(-1, Math.min(root.containerRadius,
                                                         turn.y - transcriptFlick.contentY))
                        // A viewport away in either direction and the turn
                        // is not drawn (LlmTurn.culled -- opacity, so its
                        // documents still build; the comment there says why).
                        culled: turn.y + turn.height < transcriptFlick.contentY - transcriptFlick.height
                                || turn.y > transcriptFlick.contentY + 2 * transcriptFlick.height
                        containerRadius: root.containerRadius
                        rowInset: root.rowInset
                        fontFamily: root.fontFamily
                        bodyFontFamily: root.bodyFontFamily
                        monoFamily: root.monoFamily
                        bodyPixelSize: root.bodyPixelSize
                        bodyLineHeight: root.bodyLineHeight
                        loadFloorMs: root.loadFloorMs
                        codePixelSize: root.codePixelSize
                        figureSize: root.figureSize
                        headerTitleSize: root.headerTitleSize
                        headerSubtitleSize: root.headerSubtitleSize
                        headerRadius: root.headerRadius
                        boxRadius: root.boxRadius
                        questionMaxWidth: root.questionMaxWidth
                        questionMaxLines: root.questionMaxLines
                        blockGap: root.blockGap
                        drawerInset: root.drawerInset
                        thumbSize: root.thumbSize
                        expandMs: root.expandMs
                        waitPeriodMs: root.waitPeriodMs
                        waitHeadSpan: root.waitHeadSpan
                        waitTailSpan: root.waitTailSpan
                        activity: turn.index === root.liveIndex ? root.activity : ""
                        activityMs: turn.index === root.liveIndex ? root.activityMs : 0
                        activityShown: turn.index === root.liveIndex && root.activityShown
                        contextTokens: turn.index === root.liveIndex ? root.contextTokens : 0
                        contextLimit: turn.index === root.liveIndex ? root.contextLimit : 0
                        mdBlockSpacing: root.mdBlockSpacing
                        mdHeadingSpacing: root.mdHeadingSpacing
                        mdCodeRadius: root.mdCodeRadius
                        headerPaddingH: root.headerPaddingH
                        headerPaddingV: root.headerPaddingV
                        headerBottomGap: root.headerBottomGap
                        headerIconSize: root.headerIconSize
                        headerIconGap: root.headerIconGap
                        sweepIdleWidth: root.sweepIdleWidth
                        sweepIdleFeather: root.sweepIdleFeather
                        sweepActiveFeather: root.sweepActiveFeather
                        sweepIdleDepth: root.sweepIdleDepth
                        sweepActiveDepth: root.sweepActiveDepth
                        sweepIdleStrength: root.sweepIdleStrength
                        sweepActiveStrength: root.sweepActiveStrength
                        sweepIdleFalloff: root.sweepIdleFalloff
                        sweepActiveFalloff: root.sweepActiveFalloff
                        sweepBlendEnd: root.sweepBlendEnd
                        questionPadding: root.questionPadding
                        questionRadius: root.questionRadius
                        questionChevronStrip: root.questionChevronStrip
                        chipGap: root.chipGap
                        drawerGap: root.drawerGap
                        drawerBlockSpacing: root.drawerBlockSpacing
                        drawerHeadingSpacing: root.drawerHeadingSpacing
                        mdHeadingScale: root.mdHeadingScale
                        mdCodePadding: root.mdCodePadding
                        mdCodeHeaderHeight: root.mdCodeHeaderHeight
                        mdQuoteInset: root.mdQuoteInset
                        mdQuoteBarWidth: root.mdQuoteBarWidth
                        mdTableRadius: root.mdTableRadius
                        mdTableCellPadH: root.mdTableCellPadH
                        mdTableCellPadV: root.mdTableCellPadV
                        mdImageInset: root.mdImageInset
                        footerButtonGap: root.footerButtonGap
                        footerButtonHeight: root.footerButtonHeight
                        footerButtonMinWidth: root.footerButtonMinWidth
                        footerFigureMargin: root.footerFigureMargin
                        errorPadding: root.errorPadding
                        seamFadeHeight: root.seamFadeHeight
                        waitBarGap: root.waitBarGap
                        waitBarTravel: root.waitBarTravel
                        waitBarStaggerMs: root.waitBarStaggerMs
                        // The scrolling area a selection drag pushes against.
                        scrollHost: root
                        // What "on screen" means, for the capped fold.
                        viewportHeight: transcriptFlick.height
                        capMargin: root.foldCapMargin

                        surfaceColor: root.listBoxColor
                        headerBoxColor: root.headerBoxColor
                        headerBoxBevelColor: root.headerBoxBevelColor
                        headerBoxShadowColor: root.headerBoxShadowColor
                        bevelColor: root.bevelColor
                        borderColor: root.borderColor
                        primaryText: root.primaryText
                        mutedText: root.mutedText
                        faintText: root.faintText
                        accent: root.accent
                        accentHover: root.accentHover
                        accentBevel: root.accentBevel
                        textOnAccent: root.textOnAccent
                        errColor: root.errColor
                        errTint: root.errTint
                        codeBgColor: root.codeBgColor
                        buttonPlateau: root.buttonPlateau
                        buttonPlateauHover: root.buttonPlateauHover
                        buttonBevel: root.buttonBevel
                        buttonShadow: root.buttonShadow

                        onToggled: root._toggle(turn.index)
                        onThinkingToggled: turn._thinkOpen = !turn._thinkOpen
                        onToolToggled: (id) => {
                            const m = Object.assign({}, turn._toolOpen);
                            m[id] = !turn.toolOpen(id);
                            turn._toolOpen = m;
                        }
                        onGrantRevokeRequested: (tool, key) => root.grantRevokeRequested(tool, key)
                        // A question fold pins the turn's top so the growth
                        // pushes content DOWN -- see the header comment.
                        onQuestionExpandedChanged: root._holdTurn(turn.index)
                        onCopyRequested: root.copyRequested(turn.index)
                        onRegenerateRequested: root.regenerateRequested(turn.index)
                        onEditRequested: root.editRequested(turn.index)
                        onDeleteRequested: root.deleteRequested(turn.index)
                        onLinkActivated: (url) => root.linkActivated(url)
                    }
                }
            }
        }

        // ---- Empty state --------------------------------------------------
        //
        // The mark on top, the two lines under it, the whole group centred.
        // Centring the GROUP puts the text lower than centring the lines
        // alone would -- the mark takes the middle of the box and pushes
        // the lines down, rather than the lines holding their place and the
        // mark being squeezed in above them.
        //
        // The mark's presence is LogoRelief's ONE clock (0..1). The lines' y
        // is a function of it and so is the image's opacity, so when the
        // selected model changes to one with a mark, or to one without, the
        // two lines TRANSLATE between "centred alone" and "under the mark"
        // while the image FADES where it stands: the mark sits at its resting
        // place out of the flow, so it does not drift with the group's
        // recentring. At presence 0 the lines are centred alone.
        Item {
            id: emptyState
            anchors.fill: parent
            visible: root.turnCount === 0
            // What the mark takes out of the group's height when present.
            // A size of 0 is "no mark" and takes nothing, not a bare gap.
            readonly property real slot: root.logoSize > 0 ? root.logoSize + root.logoGap : 0

            LogoRelief {
                id: logo
                anchors.horizontalCenter: parent.horizontalCenter
                // The top of the centred group WITH the mark -- fixed, so the
                // fade happens in place.
                y: Math.round((emptyState.height - (emptyState.slot + lines.height)) / 2)
                source: root.modelLogos ? root.modelLogos.assetFor(root.logoModel) : ""
                logoSize: root.logoSize
                presenceMs: root.logoPresenceMs
                // Carved into the container's own fill, which is the ground
                // this box actually is.
                surfaceColor: root.listBoxColor
                bevelColor: root.bevelColor
                shadowColor: root.borderColor
                bodyColor: root.headerBoxColor
                depthScale: root.logoDepthScale
                bevelWidth: root.logoBevelWidth
                falloff: root.logoFalloff
                ambient: root.logoAmbient
                highlightGain: root.logoHighlightGain
                lightAngle: root.logoLightAngle
            }

            Column {
                id: lines
                anchors.horizontalCenter: parent.horizontalCenter
                // From centred alone (presence 0) to under the mark (1), on
                // the mark's own clock. Whole pixels: text never sits on a
                // half.
                y: Math.round((emptyState.height - lines.height) / 2
                              + logo.presence * emptyState.slot / 2)
                spacing: 4

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Ask something."
                    color: root.faintText
                    font.family: root.fontFamily
                    font.pixelSize: root.bodyPixelSize
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.model.length > 0
                    text: root.model
                    color: root.faintText
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                }
            }
        }

        // The registry behind `modelLogos`, so the transcript works standalone.
        LlmModelLogos { id: _defaultModelLogos }

        // ---- The wheel and the two edges ------------------------------------
        //
        // A SIBLING of the Flickable, never a child, and declared here so its
        // bands paint over the content and under the corner re-cut below. The one
        // exception this file asks for is the virgin top; everything else
        // about a notch and a fade is ScrollDressing's to say.
        ScrollDressing {
            id: dressing
            objectName: "llmTranscriptDressing"     // the glide probe waits on its `moving`
            anchors.fill: parent
            flick: transcriptFlick
            scrollSpeed: root.scrollSpeed
            // The wheel's bookkeeping, again, where the motion ENDED: a notch glides and a lift
            // coasts, so what the sticky anchor should remember and whether the list is still
            // following is known only when it stops (onWheeled runs at the event, at the start).
            onMovingChanged: {
                if (dressing.moving)
                    return;
                root._measureFollow();
                root._trackSticky();
                root._pin();
            }
            // The fade is into the container's own fill, not the surface
            // outside it.
            ground: root.listBoxColor
            fadeHeight: root.fadeHeight
            headSuppressed: root._virginTop
            onWheeled: {
                // The virgin state ends FIRST in intent -- dropping _openPad
                // shrinks the content -- but the scroll has already landed by
                // the time this arrives, clamped against the bounds the pad
                // was still in. So end it, then re-clamp against the bounds
                // that leaves.
                root._userTouch();
                const maxY = Math.max(0, transcriptFlick.contentHeight - transcriptFlick.height);
                if (transcriptFlick.contentY > maxY)
                    transcriptFlick.contentY = maxY;
                root._measureFollow();
                // A wheel is a USER scroll -- the one scroll that may move
                // the sticky anchor, and only with everything open.
                root._trackSticky();
            }
        }

        // The box's rounded corners, re-cut over the scrolling content. A
        // Flickable clips to a RECTANGLE, and with the viewport filling the
        // box a header scrolled to the top edge would show its square corner
        // in the sliver where the box's corner curves away.
        //
        // Two borders, clipped to the box grown by its bevel. The outer one is
        // grown by a radius on every side with a radius that much larger and
        // drawn as a border exactly that wide, so its inner edge is a rounded
        // path sitting on the bevel's OUTER edge: it paints only the sliver
        // outside the bevel and never the bevel itself. The inner one redraws
        // the bevel arc on top, which the content would otherwise cover as it
        // scrolls past. Along the straight edges both fall outside the clip
        // and paint nothing.
        Item {
            readonly property real _bevel: 1
            anchors.fill: parent
            anchors.margins: -_bevel
            clip: true

            Rectangle {
                readonly property real _capW: root.containerRadius + parent._bevel
                anchors.fill: parent
                anchors.margins: -_capW
                color: "transparent"
                radius: root.containerRadius + parent._bevel + _capW
                border.width: _capW
                border.color: root.surfaceColor
                antialiasing: true
            }
            Rectangle {
                anchors.fill: parent
                color: "transparent"
                radius: root.containerRadius + parent._bevel
                border.width: parent._bevel
                border.color: root.bevelColor
                antialiasing: true
            }
        }
    }
}
