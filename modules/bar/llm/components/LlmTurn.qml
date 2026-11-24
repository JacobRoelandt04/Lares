pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"
import "../../../common/components"
import "../../../common/components/Markdown.js" as Md
import "../../../common/components/Mix.js" as Mix
import "../../../common/components/RelTime.js" as RelTime
import "../../../common/components/Sweep.js" as Sweep

// =============================================================================
// LlmTurn.qml
//
// One exchange in a conversation: the question, an optional thinking drawer,
// the answer as rendered markdown, and a footer of four actions. The whole
// thing hangs off a ListSectionHeader, which is what makes "collapse every
// answer and scan the past questions" a layout rather than a feature: a
// collapsed turn IS its header, so a conversation reads as a list of sections.
//
// THE HEADER IS THE CATEGORY, THE GLYPH IS THE TOPIC
// --------------------------------------------------
// The model files every answer under one of six categories, and the header
// box's inset shadow carries that category's colour. The glyph in the icon
// slot is the message's TOPIC icon when the service resolved one (a python
// logo for a python question) and the category's glyph only as the fallback
// -- exactly the rule the sidebar's history row draws by, so the row and the
// header of the same exchange never show two different marks. The glyph stays
// muted: a coloured glyph beside a coloured inset would be the same fact
// painted twice, which is the rule this shell keeps. The hover tip names the
// CATEGORY either way; the icon narrows the subject, the colour and the label
// stay the category's.
//
// TWO FACES. `bodyFontFamily` is the reading face -- the sent question, the
// answer's document and the thinking drawer -- and `fontFamily` is the
// shell's: the header title and subtitle, the figures, the note rule, the
// error strip, the drawer's handle. The document's family goes INTO the
// generated CSS (MarkdownView's law), so a rich-text block can never fall
// back to the edit's default face. It has its own MEASURE too:
// `bodyPixelSize` 13 and `bodyLineHeight` 1.15, which puts Exo 2 on an 18.4 px
// pitch, 1.41 x its size. The shell's 12 px is a figure size and the face's
// own 16 px pitch is a UI label's; this is the one surface in the shell that
// is set as prose, and it is set as prose.
//
// THE SENT QUESTION SELECTS THROUGH A LAYER, NOT THROUGH `selectByMouse`.
// A native selection drag is Qt's own grab inside QQuickTextEdit and there is
// no way to be told about it, so a drag held past the transcript's bottom
// edge could not scroll. The question has the same MouseArea shape
// MarkdownView's cross-block layer has, and pushes against the same
// `scrollHost`.
//
// While the title is still being written the header shows NO text at all --
// not the question, not the model, not a live state word. A placeholder is a
// claim, and it is wrong twice: once while it stands and once when it is
// replaced. What stands instead is a SILHOUETTE of exactly what will arrive:
// an icon-sized square in the icon slot, a bar at title size, a bar at
// subtitle size, each taking its geometry from the real thing it holds space
// for, so the title resolves in place. The sweep in the header's inset is
// what says "working" -- it needs no words beside it.
//
// WHY THE HEADER CARRIES THE MOTION, AND WHY IT IS A BAND
// -------------------------------------------------------
// A generating turn runs a BAND of the category's colour through that inset --
// the material the system update uses for a step under way, so "work is
// happening here" is said in the shell's existing vocabulary rather than with
// a spinner. It grows out of the parked idle mark at the left, crosses, and
// closes up at the right, over `waitPeriodMs`; then it starts again from the
// mark.
//
// It is a band and not a FILL: a fill is a claim this module can never
// support. A model reports no progress, so there is nothing for "this far" to
// mean, and at the end of every loop a fill's boundary would be cut from off
// the right end back to the 12 px mark in ONE frame -- 420 px of travel in
// 16 ms, which reads as "it started over". The band is the classic
// indeterminate bar and says only what is true: still working.
//
// ONE CLOCK. `_wait` is a single LINEAR fraction 0 -> 1, looping; both edges
// are functions of it through Sweep.js (`lead`, `trail`), and every consumer
// -- this header, every tool block below it -- reads the same two numbers.
// The shaping is per EDGE and not on the clock, because an easing on the clock
// would shape both edges alike and the band could never stretch or close. The
// clock stops dead when the item is not visible.
//
// A failed turn parks that inset at full extent in the error colour, so a
// collapsed failure is still legible as one without a second mark.
//
// THE MARK IS THE RESTING STATE, AND A RUNNING BAND WITHDRAWS IT
// --------------------------------------------------------------
// `sweepIdleWidth` is a FLOOR under the leading edge, and a floor under a
// band that is under way is a wave born part-grown: at every wrap the lead
// would go from off the right end to the 26 px mark in ONE frame -- 26 px of
// colour in 16 ms -- and then STAND STILL there for the first 224 ms of the
// trip, until the sweep itself catches up with the floor: a new wave appearing
// partially instant to the left.
//
// So the mark belongs to the RESTING state and to the FIRST trip, which
// grows out of it the way it is meant to. It is withdrawn at the first wrap
// and comes back when the turn parks. The WRAP is the instant to do it at,
// not a timer and not a threshold: there the lead is at fraction 0 and the
// tail is already outside the left edge, so withdrawing the floor moves the
// lead from the mark to one half-feather outside the box with ZERO INK on
// both sides of the change, at any box width.
//
// AND THAT IS THE LAW: THE BAND'S GEOMETRY MAY ONLY BE SWAPPED ON A FRAME
// WHERE NOTHING IS PAINTED. The other two swaps cannot be timed to a zero of
// their own -- the stop (401 px of colour down to the 26 px mark in one
// frame) and a failure (the band to a full error inset, colour included)
// happen when the answer happens. So the ink is taken to zero for them:
// `_tintF`, ONE eased fraction, mixed with Mix.js from the box's own shadow
// colour to the category's (and to the error colour, so the two never swap
// while either is visible), out over `fadeMs`, the state swapped at 0, back
// in. Nothing MOVES while it fades -- the clock has already stopped -- so
// this is presence, which is the only thing this shell fades.
//
// AND WHEN NOTHING IS ARRIVING AT ALL
// -----------------------------------
// While a model writes a tool call, ollama sends NOTHING: measured on this
// machine, zero bytes for 46 to 77 seconds and then one frame carrying the
// whole call. A byte count, a token count and a live word are therefore all
// impossible, and a subtitle reading "answering…" for a minute is a lie about
// which of the two is happening. The service reads the silence from facts
// about the round (`activity`: reading the results, thinking, writing a tool
// call -- LlmService.liveActivity says how) and times it (`activityMs`).
// The subtitle says it, and the elapsed time sits in the header's own fixed
// figure slot so it cannot move the words beside it.
//
// AND THE SAME WORDS WHERE THE READER IS. The header is at the
// TOP of a turn, and a tool loop's turn is taller than the viewport long
// before the model is done: a reader looking at the foot, where the
// thinking drawer's label says "thought" and nothing moves for minutes,
// would read it as frozen. So the foot of the live turn carries the activity
// as a line of its own -- a tool block's handle, the same carved box and the
// same travelling band, the words, the context the round was sent with and
// the elapsed time in the block's own slots -- and when the call it
// announces lands, the real block takes its place on the same line.
//
// THE FOLD IS CAPPED AT THE VIEWPORT  (the one that matters)
// ----------------------------------------------------------
// Folding a 4000 px answer by animating its true height throws everything
// below it up the screen at 15 px/ms, while a 300 px answer folds sedately:
// the same gesture reads as two different things depending on how long the
// answer happens to be. The rule is ANIMATE ONLY WHAT IS ON SCREEN.
//
//   height = settled ? full : min(full, viewportHeight + capMargin) * extent
//
// One eased fraction, and the height it is measured against is the viewport
// plus a margin. `settled` is `extent >= 1`, which a NumberAnimation to 1 hits
// exactly -- so the true height is in force whenever the turn is at rest open,
// and the swap to and from the cap happens on the first and last frame of the
// motion, when the difference lies past the bottom edge and cannot be seen.
// A 100-line and a 1000-line answer then fold identically. The margin is what
// keeps the swap off screen rather than one pixel below the edge.
//
// This is also why the height is not a property the file assigns: a fraction
// with the cap in its mapping tracks a STREAMING answer for free (the content
// grows, `full` grows, the height follows), where a state machine writing a
// height would have to be told.
//
// A LONG QUESTION COLLAPSES
// -------------------------
// The question is right-aligned and hugs its text up to `questionMaxWidth` of
// the body -- a sent message, in the shape a messaging app gives it. Past
// `questionMaxLines` it arrives folded, with a chevron in a strip along the
// bottom of its box: the box is the record of what was asked, not the thing
// being read now. Its width comes from a TextMetrics of the question, never
// from reading the Text back into what sizes it.
//
// NOTHING IN HERE READS THE WHEEL. The one Flickable in this subtree is the
// attachments' chip strip, which only drags sideways (no WheelHandler, no
// ScrollDressing: a dressing takes EVERY wheel over its box, so one here would
// trap the conversation's wheel over the strip). MarkdownView and CodeBlock
// have no Flickable either: the transcript's wheel handler is the only reader,
// so a wheel over a code block, a table or the strip scrolls the conversation.
//
// ONE DENSITY. There is no `compact` / `listScale` view scalar. A font size bound to a
// per-view scalar re-shapes every QTextDocument on screen at once -- the
// cascade that cost the system update 26 of its 37 ms per view switch -- and
// there is only one view here to switch to.
// =============================================================================
Item {
    id: root

    // ---- Content ---------------------------------------------------------
    property string question: ""
    property string answer: ""            // markdown; grows while streaming
    property string thinking: ""
    property string model: ""
    property real   at: 0                 // ms epoch of the question
    property bool   streaming: false
    property bool   thinkingLive: false
    property bool   expanded: true
    property bool   thinkingExpanded: false
    property bool   failed: false
    property string errorText: ""
    property var    stats: null           // { evalTokens, tokensPerSecond, totalMs }
    property var    images: []            // [b64] attached to the question (legacy)
    // Attachment metadata for the question's chips, the loader's shape:
    // { path, name, mime, kind, isImage, b64, textContent, images, pageCount,
    //   durationMs, peaks, pending, failed, failReason }. The question text
    // itself is the TYPED text alone -- the service inlines file content at
    // wire time, never into the stored message -- so the chips are the only
    // trace an attachment leaves here.
    property var    attachments: []
    property bool   isNote: false         // a "switched model" marker, not a turn
    property string noteText: ""
    // WHERE THIS TURN'S HEADER SITS RELATIVE TO THE CONTAINER'S TOP EDGE, in
    // px: 0 is flush with it, positive is below it, negative is scrolled off
    // it. It exists for ONE reason -- the corner. The container's top corners
    // are rounded and carved, and the header that comes to rest against that
    // edge has to present THAT corner, or its own smaller radius leaves a
    // crescent of the container's inset shadow showing outside its own, and
    // the two gradients mash. Which header that is is a POSITION, not an
    // index: a conversation opened at its last answer pins that answer's
    // header there, and it must look exactly like turn 0 scrolled to the top.
    // The transcript clamps this to [-1, containerRadius] so it stops changing
    // for every turn that is nowhere near the edge.
    property real   topOffset: 1e9

    // ---- The category ----------------------------------------------------
    // Resolved by the transcript from the service's taxonomy and handed down
    // already split, so this file never has to know the table. `title` is the
    // model's own six-word naming of the exchange; empty falls back to the
    // question's own first words.
    property string title: ""
    property bool   titlePending: false
    property string categoryGlyph: ""
    // The message's own topic icon, "" when the service resolved none. The
    // header draws it when present and `categoryGlyph` otherwise -- see the
    // header comment. `headerGlyph` is what is actually drawn, readable so a
    // host or a probe can hold it against the sidebar row's mark.
    property string topicIcon: ""
    readonly property string headerGlyph: root.topicIcon.length > 0 ? root.topicIcon
                                                                     : root.categoryGlyph
    property color  categoryColor: Theme.textFaint
    // The category's label, for the icon's hover tip ("System", "Code"). The
    // tip always names the CATEGORY even when the glyph is a per-topic icon:
    // the icon narrows the subject, the label and colour stay the category's.
    property string categoryLabel: ""

    // The popup's floating layer for the hover tip. Null falls back to local
    // parenting, which a harness may live with (the tip would clip in a list).
    property Item   overlayItem: null

    // The scrolling area a selection drag inside this turn pushes against --
    // the transcript. Duck-typed on `autoScrollBegin/At/End`; null is a turn
    // that is not inside a scroller and simply never scrolls one. Handed on
    // to both documents and used by the sent question's own drag layer.
    property var    scrollHost: null

    // The transcript's search text, highlight only. Matches in the answer,
    // the thinking drawer and the question take a background wash -- an
    // OPAQUE accent-over-ground mix (Mix.js), because the colour is baked
    // into rich text and an alpha there would be a literal the theme cannot
    // move. Both mixes ride live Theme-bound properties, so a theme switch
    // re-bakes them through MarkdownView's settle rebuild. Empty = no work.
    property string searchQuery: ""
    readonly property color _hlOnList: Mix.c(root.surfaceColor, root.accent, 0.35)
    readonly property color _hlOnBox: Mix.c(root.headerBoxColor, root.accent, 0.35)

    // Extras, all defaulted so a host that ignores them sees nothing new:
    //   waiting     the request is away and no token has arrived. The answer
    //               slot holds three pulsing bars instead of an empty gap, so
    //               a 40 s cold model load is a state and not a stall.
    //   thinkingMs  how long the model thought, for the drawer's label. 0 ->
    //               the drawer just says "thought".
    //   clock       the BoundaryClock the relative time is read against (see
    //               "When it was asked"): the transcript hands down its one,
    //               and only a turn on its own builds a private one.
    property bool waiting: false
    // What the wait is for when it is not the model's load (LlmService.waitSay: the GPU being got ready), "" = loading the model.
    property string waitSay: ""
    property real thinkingMs: 0
    property var clock: root._ownClock

    // ---- What the model is doing while nothing arrives -------------------
    // The service's reading of the silence -- "reading" | "thinking" |
    // "writing" | "working" | "" (LlmService.liveActivity) -- how long it has
    // been at it, and whether it has lasted long enough to be said at all.
    // `contextTokens` / `contextLimit`: the round's prompt as the service
    // estimated it, against the turn's num_ctx -- the answer to "has it run
    // out of context?" while the model is silent.
    property string activity: ""
    property int    activityMs: 0
    property bool   activityShown: false
    property int    contextTokens: 0
    property int    contextLimit: 0

    // ---- Tool calls ------------------------------------------------------
    // The committed entries in call order across rounds; the live turn
    // gets the service's `liveToolCalls`, a NEW array on every state change.
    // Each entry becomes an LlmToolBlock in the body, preceded by its own
    // `preface` -- the text the model streamed in the round that produced it
    // -- as a frozen MarkdownView of its own. The blocks are a ListModel
    // synced BY ID (see `_syncTools`): an entry's status changing patches
    // what its block reads and never re-creates the block or the preface view
    // above it, which is the text-rendering law applied to a call.
    property var    toolCalls: []
    property string toolProgress: ""       // the running tool's word: "searching files"
    property bool   awaitingConfirm: false // a confirmation is pending on this turn
    property string toolNote: ""           // "stopped after 6 tool rounds" | "cancelled by you"
    // id -> bool, kept by the transcript like its `_thinkOpen`. An id absent
    // from the map takes the default: collapsed, unless the call's status is
    // one whose reason must be legible without a click.
    property var    toolExpanded: ({})
    property bool   toolBlockCollapsed: true
    property int    toolBlockMaxLines: 40
    signal toolToggled(string id)
    signal grantRevokeRequested(string tool, string key)

    // ---- Geometry --------------------------------------------------------
    property real   containerRadius: 14
    property real   rowInset: 6
    property string fontFamily: "Inter"
    // The reading face: the sent question, the answer, the thinking. Nothing
    // else in this file draws with it.
    property string bodyFontFamily: "Inter"
    property string monoFamily: "Consolas"
    // The one density the transcript picked. Set ONCE; never bind to a view.
    // 13, not 12: this is the face the answer is READ in, and the shell's
    // 12 px body is a figure size, not a reading size. With the pitch below it
    // is the only place in the shell that is set as prose rather than as UI.
    property int    bodyPixelSize: 13
    // The reading pitch, a multiple of the face's own line height, applied to
    // the answer, the thinking drawer and the sent question -- everything the
    // reading face draws. Exo 2's natural pitch at 13 px is 16.00 px, i.e.
    // 1.23 x the size, which is a UI label's measure; 1.15 puts it at 18.39 px,
    // 1.41 x the size, which is a paragraph's. See MarkdownView.lineHeight for
    // how it reaches the document (a wrapper div: a TextEdit has no
    // `lineHeight`).
    property real   bodyLineHeight: 1.15
    property int    codePixelSize: 12
    property int    figureSize: 10
    property int    headerTitleSize: 15
    property int    headerSubtitleSize: 11
    // The header box's radius, and it is the CONTAINER's -- not a smaller
    // number of its own. A turn's header box runs to the container's left and
    // right edges, so its corners and the container's are the same corners;
    // two radii there is two arcs where the eye expects one, which reads as a
    // mismatch the moment a header comes to rest against the
    // top edge. 14 = containerRadius, and the pair moves together.
    property real   headerRadius: 14
    // The header's top corners, eased between the container's radius (flush
    // with the container's top edge, and anywhere above it) and the header's
    // own (a container radius below it and further down). One expression, no
    // branch, no animation: the clock is the scroll itself, so the arc cannot
    // lag the edge it is meant to sit on. See `topOffset`. At the defaults the
    // two radii are equal and this ease is the identity -- which is the point:
    // the rule stays stated, so a host that DOES give the header a radius of
    // its own still gets a quiet crossing instead of a step.
    readonly property real _cornerT: Math.max(0, Math.min(1,
        root.topOffset / Math.max(1, root.containerRadius)))
    readonly property real _headerTopRadius:
        root.containerRadius + (root.headerRadius - root.containerRadius) * root._cornerT
    property real   boxRadius: 10
    property real   blockGap: 8
    // How the rendered answer is set. Separate from `blockGap`, which is the
    // space between the parts of an exchange: this is the space INSIDE the
    // answer, between one markdown block and the next.
    property real   mdBlockSpacing: 8
    property real   mdHeadingSpacing: 12
    property real   mdCodeRadius: 10
    // The question's box may take this fraction of the body's width, and no
    // more; below that it hugs its own text. Past `questionMaxLines` rendered
    // lines it arrives folded.
    property real   questionMaxWidth: 0.78
    property int    questionMaxLines: 4
    property real   questionPadding: 10
    // Whether a folded question is currently open. Public and settable, so a
    // host (or a render harness) can put a turn into that state without having
    // to reach through the delegate and click something.
    property bool   questionExpanded: false
    // Left inset of the thinking drawer's prose, matching the text inset a
    // blockquote takes inside MarkdownView.
    property real   drawerInset: 10
    property real   thumbSize: 64
    property int    expandMs: 260
    property int    fadeMs: 160
    // ONE TRIP of the wait band: the head crosses, then the tail follows it
    // out -- two traversals per period.
    property int    waitPeriodMs: 2000
    // The fraction of a trip each edge is IN MOTION for. The head moves over
    // [0, head]; the tail over [1 - tail, 1]. `head + tail - 1` is the overlap
    // -- the part of the trip where both move and the band travels at its full
    // width -- and what is left over is the beat where the band is closed up
    // at the far edge before the next trip starts from the mark.
    property real   waitHeadSpan: 0.62
    property real   waitTailSpan: 0.62

    // ---- Tunables ------------------------------------------------------
    // Every literal a designer would reach for, as a property, so the host
    // can put it on a control panel. Defaults are the tuned values.
    //
    // The header box: its text clearance, the gap under it, the icon slot.
    property real   headerPaddingH: 11
    property real   headerPaddingV: 8
    property real   headerBottomGap: 6
    property int    headerIconSize: root.headerTitleSize + 3
    property real   headerIconGap: 8
    // The header's inset -- the category's colour at the box's left. Idle it
    // is a parked sliver `sweepIdleWidth` wide with a tight crossover into
    // the plain shadow; under way the sweep runs it rightward with a wide
    // feather so the moving boundary reads as a wash and not a seam. Depth,
    // strength and falloff are exposed as idle/active pairs, blended on the
    // sweep's own fraction (ShadowBox documents each control).
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
    // The question box.
    property real   questionRadius: root.boxRadius
    property real   questionChevronStrip: 8   // added to figureSize for the chevron's strip
    property real   chipGap: 6
    // The thinking drawer: handle-to-prose gap and the prose's own spacing.
    property real   drawerGap: 6
    property real   drawerBlockSpacing: 6
    property real   drawerHeadingSpacing: 8
    // The answer's document, beyond the spacings above.
    property real   mdHeadingScale: 1.0
    property real   mdCodePadding: 10
    property real   mdCodeHeaderHeight: 26
    property real   mdQuoteInset: 10
    property real   mdQuoteBarWidth: 3
    property real   mdTableRadius: 10
    property real   mdTableCellPadH: 10
    property real   mdTableCellPadV: 6
    property real   mdImageInset: 6
    // The footer row.
    property real   footerButtonGap: 6
    property real   footerButtonHeight: 24
    property real   footerButtonMinWidth: 26
    property real   footerFigureMargin: 6
    // The error strip's inner padding, the fold seam's band, the waiting bars.
    property real   errorPadding: 10
    property real   seamFadeHeight: 42
    property real   waitBarGap: 6
    // The waiting bars' breath, in PIXELS each end travels -- not a fraction:
    // see SkeletonBar. 8 is what a fraction gives the SHORTEST of the three
    // (7.86 px per end on a 449 px bar), so equalising costs no line any
    // calm: the long ones come down to the quiet one rather than the quiet one
    // being wound up.
    property real   waitBarTravel: 8
    // ...and the wave down the column. One beat is a ninth of the half-breath,
    // enough to read as top-to-bottom rather than as one block blinking, small
    // beside the 900 ms it is a phase of.
    property int    waitBarStaggerMs: 100

    // The transcript's viewport height, and the slack past it. Together they
    // are the cap the fold is animated against; see the header comment. 0
    // means "not known yet", which uncaps -- the honest reading of a turn that
    // has not been laid out into a viewport.
    property real viewportHeight: 0
    property real capMargin: 48

    // ---- Palette ---------------------------------------------------------
    // Every colour anything inside this turn draws with is a property here,
    // including the ones that only exist to be handed to MarkdownView and
    // CodeBlock: the host cannot reach into a nested item, so a colour that
    // is not on this list is a colour the theme cannot move.
    //
    // `surfaceColor` is the ground the turn is drawn ON -- the transcript's
    // carved fill -- which is what every ShadowBox in here needs as its
    // surface, not the popup's surface.
    property color surfaceColor: Theme.listBox
    property color headerBoxColor: Theme.headerBox
    property color headerBoxBevelColor: Theme.headerBoxBevel
    property color headerBoxShadowColor: Theme.headerBoxShadow
    property color bevelColor: Theme.bevel
    property color borderColor: Theme.border
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
    property color selectionColor: Theme.terminalSelection
    property color selectionTextColor: Theme.terminalSelectionText
    property color buttonPlateau: Theme.buttonPlateau
    property color buttonPlateauHover: Theme.buttonPlateauHover
    property color buttonBevel: Theme.buttonBevel
    property color buttonShadow: Theme.buttonShadow

    signal toggled()
    signal thinkingToggled()
    signal copyRequested()
    signal regenerateRequested()
    signal editRequested()
    signal deleteRequested()
    signal linkActivated(string url)

    implicitWidth: 0
    implicitHeight: root.isNote ? noteRow.implicitHeight
                                : header.implicitHeight + bodyClip.height

    // OFF SCREEN, THIS TURN IS NOT DRAWN. The transcript sets it for a turn
    // more than a viewport away from the reader, and it is OPACITY, never
    // `visible`: an invisible turn's documents defer every build until it is
    // shown again (their own law), so a font change or a search re-derive
    // would land on the turn as it scrolled in -- at a new height, moving
    // the column under the reader when it came from above. At opacity 0 the
    // nodes stay in the scene graph and everything builds as usual; the
    // renderer just skips the subtree. Measured (eight 48 KB
    // answers, scrolling): render 2.7 -> 1.5 ms a frame, CPU -24 %; the
    // 3 ms of sync a frame is the graph's size and stays.
    property bool culled: false
    opacity: root.culled ? 0 : 1

    // ---- Derived ---------------------------------------------------------
    // The question box's chips: the attachments metadata when the message
    // carries it, else legacy bare-b64 images dressed as image attachments,
    // so old conversations keep their thumbnails through the same one chip.
    readonly property var _chips: {
        const a = root.attachments;
        if (a && a.length > 0)
            return a;
        const im = root.images;
        if (im && im.length > 0) {
            const out = [];
            for (let i = 0; i < im.length; ++i)
                out.push({ name: "image", kind: "image", isImage: true, b64: im[i] });
            return out;
        }
        return [];
    }
    readonly property bool _hasThinking: root.thinking.length > 0 || root.thinkingLive

    // ---- The tool blocks' model, synced by id ---------------------------
    // The entries by id, re-derived on every `toolCalls` change: a block's
    // delegate reads its entry through this, so a status patch reaches it as
    // a new object for the same id, and nothing is re-created.
    readonly property var _toolById: {
        const m = ({});
        const arr = root.toolCalls || [];
        for (let i = 0; i < arr.length; ++i)
            if (arr[i] && arr[i].id !== undefined)
                m[String(arr[i].id)] = arr[i];
        return m;
    }
    // "call 1 of 2": position within the entry's round, counted here because
    // a block cannot see its siblings.
    function _toolCallLabel(e) {
        if (!e)
            return "";
        const arr = root.toolCalls || [];
        let n = 0, at = 0;
        for (let i = 0; i < arr.length; ++i) {
            if (!arr[i] || arr[i].round !== e.round)
                continue;
            n++;
            if (arr[i].id === e.id)
                at = n;
        }
        return n > 1 ? "call " + at + " of " + n : "";
    }
    function _toolFailedStatus(st) {
        return st === "denied" || st === "failed" || st === "timedOut" || st === "flood"
            || st === "refused" || st === "invalid" || st === "repeated";
    }
    // Open or folded, for one block: the transcript's map first, the default
    // otherwise. Published so the transcript's toggle can flip the truth.
    function toolOpen(id) {
        const m = root.toolExpanded;
        if (m && m[id] !== undefined)
            return !!m[id];
        const e = root._toolById[id];
        return !root.toolBlockCollapsed || (!!e && root._toolFailedStatus(String(e.status || "")));
    }
    // The model holds ids only. A change that EXTENDS the id sequence appends;
    // anything else (a delegate re-used for another message, a shorter array)
    // rebuilds -- so a block is created once per id and lives through every
    // status change of its entry.
    function _syncTools() {
        const arr = root.toolCalls || [];
        let prefix = arr.length >= toolModel.count;
        for (let i = 0; prefix && i < toolModel.count; ++i)
            if (!arr[i] || toolModel.get(i).callId !== String(arr[i].id))
                prefix = false;
        if (!prefix)
            toolModel.clear();
        for (let i = toolModel.count; i < arr.length; ++i)
            if (arr[i] && arr[i].id !== undefined)
                toolModel.append({ callId: String(arr[i].id) });
    }
    onToolCallsChanged: root._syncTools()
    Component.onCompleted: {
        root._syncTools();
        // A turn built already generating is not parked; one built finished
        // is, and takes the resting mark with no ceremony.
        root._parked = !root._running;
        root._ownClockIfNone();
        root._askClock();
    }
    ListModel { id: toolModel }
    // The footer is for a finished turn: while tokens are arriving there is
    // nothing to copy yet and nothing to regenerate.
    // The copy button shows a check for a moment after a click.
    property bool _copied: false
    Timer {
        id: copiedTimer
        interval: 1200
        onTriggered: root._copied = false
    }
    readonly property bool _showFooter: !root.streaming && !root.waiting

    // ---- What the footer's figures say -----------------------------------
    //
    // "loaded in 8.3 s  ·  940 tok  ·  42.4 tok/s", chronological, in the
    // one right-pinned line. Nothing here can jitter: the footer exists only
    // for a FINISHED turn and `stats` is written once, at commit.
    // Published as a property so a probe can read the line without reaching
    // through a delegate.
    //
    // THE LOAD FIGURE IS ollama's OWN `load_duration`, AND THAT IS WHAT
    // DECIDES WHETHER IT APPEARS. It is the weights load and nothing else:
    // measured on this machine a warm model reports 0.9-1.2 ms across two
    // models and three context sizes, a cold load 1.6-95.7 s, and a model
    // that IS resident but was asked at a different `num_ctx` reports
    // 2.25-2.33 s -- which is a real load of the weights, and is why the
    // module's own live guesses cannot answer this: `waitingForModel` is
    // "generating and no byte yet", which is a buffered tool
    // call as often as a load, and a residency read (/api/ps) calls that
    // num_ctx reload resident. 84 stored turns hold no value at all
    // between 25.6 ms and 2956.5 ms, so the floor is a gap and not a guess.
    //
    // The figure is therefore absent exactly when the model was already
    // loaded -- and when nobody measured a load at all: the OpenAI surface
    // reports none, and a turn cancelled DURING one never receives the done
    // frame the number lives in. Saying nothing is the honest answer there.
    property real loadFloorMs: 250
    function _loadText(ms) {
        // The header's own m:ss past a minute: the store has loads up to
        // 95.7 s, and "95.7 s" is not a figure anybody reads.
        return ms < 60000 ? (ms / 1000).toFixed(1) + " s" : root._mmss(ms);
    }
    readonly property string footerFigures: {
        const s = root.stats;
        if (!s)
            return "";
        const parts = [];
        if (s.loadMs > root.loadFloorMs)
            parts.push("loaded in " + root._loadText(s.loadMs));
        if (s.evalTokens > 0)
            parts.push(s.evalTokens + " tok");
        if (s.tokensPerSecond > 0)
            parts.push(s.tokensPerSecond.toFixed(1) + " tok/s");
        return parts.join("  ·  ");
    }

    // ---- When it was asked --------------------------------------------------
    // "just now" / "4 min ago" / "3 h ago" / "24 Sep 15:05" (RelTime with the
    // turn's words), coarse on purpose: the exact second a question was asked
    // is never the thing being looked for, and a figure that ticks is a figure
    // that jitters. `clock` is asked for the instant the words change, and
    // only while they are on the line: a turn saying "answering…", a note
    // row, a hidden transcript ask for nothing, so nothing ticks for them.
    // A PRIVATE CLOCK ONLY FOR A TURN ON ITS OWN. A host that hands `clock`
    // down (the transcript's one) has replaced the default binding before
    // this runs, so no turn in a transcript builds a clock at all -- one each
    // would be a Timer and a Sleep hook per exchange in a delegate whose build
    // cost is measured. The private one
    // is the turn's child, so like every BoundaryClock it runs only while the
    // turn is shown: hidden, a boundary asked for before the hide does not
    // wake it.
    property var _ownClock: null
    Component {
        id: ownClockC
        BoundaryClock {}
    }
    function _ownClockIfNone() {
        if (!root.clock && !root._ownClock)
            root._ownClock = ownClockC.createObject(root);
    }
    readonly property bool _relAsking: root.visible && !root.isNote && !root.titlePending
        && root._stateWord.length === 0 && root.at > 0
    // NEVER A CLOCK OLDER THAN THE READING. `now` moves only on a boundary
    // somebody asked for, so a turn built later (a conversation switched to)
    // or one whose time comes back on the line (shown again, done answering)
    // would read the last boundary's instant -- and a boundary of its own
    // already behind the wall is one no timer will ever wake it for. So the
    // reading is the later of the clock's `now` and the wall: `now` is what
    // re-reads it on every boundary, the wall is what makes a first read (or
    // a read after the words come back on the line) true; a pinned clock
    // (a probe's) reads its pin when that is the later.
    // ONE READ, AND A HANDLER THAT ONLY ASKS. Whether the words are on the
    // line rides in the reading itself (`asking`): bindings are evaluated
    // when READ, so a handler that consulted a second property -- or wrote a
    // floor from it -- would run inside `_rel`'s own update and loop on every
    // turn the transcript builds.
    readonly property var _rel: {
        if (!(root.at > 0))
            return null;
        const r = RelTime.format(root.at, Math.max(root.clock ? root.clock.now : 0, Date.now()),
                                 { justNow: "just now", suffix: " ago", weekday: false, year: false });
        r.asking = root._relAsking;
        return r;
    }
    on_RelChanged: root._askClock()
    // -1 is final ("24 Sep 15:05"): nothing to ask for. A boundary that
    // passed while the turn was being built wakes the clock at once.
    function _askClock() {
        const r = root._rel;
        if (r && r.asking && r.nextMs > 0 && root.clock)
            root.clock.request(Math.max(r.nextMs, Date.now() + 1));
    }

    // What the turn is doing, in a word, or "" at rest -- when the subtitle
    // says when it was asked instead.
    readonly property string _stateWord: {
        if (root.failed)
            return "failed";
        if (root.waiting)
            return root.waitSay !== "" ? root.waitSay + "…" : "loading model…";
        if (root.awaitingConfirm)
            return "waiting for your OK";
        if (root.toolProgress.length > 0)
            return root.toolProgress + "…";
        // ABOVE `thinkingLive` on purpose: once said, the activity is the
        // more exact word ("writing a tool call…" after the thinking ends).
        if (root._activityOn)
            return root._activityWords + "…";
        if (root.thinkingLive)
            return "thinking…";
        if (root.streaming)
            return "answering…";
        return "";
    }

    // Model first, state second: the model is who answered and must not move,
    // so the live word is appended to it rather than replacing the whole line
    // and shifting what is left.
    readonly property string _subtitle: {
        const t = root.model.length > 0 ? root.model : "";
        const s = root._stateWord.length > 0 ? root._stateWord : (root._rel ? root._rel.text : "");
        if (t.length === 0)
            return s;
        return s.length > 0 ? t + "  ·  " + s : t;
    }

    // The activity, once it has lasted long enough to say: one derived fact,
    // read by the subtitle, the figure and the line at the foot.
    readonly property bool _activityOn: root.activityShown && root._activityWords.length > 0
    readonly property string _activityWords: {
        switch (root.activity) {
        case "reading":  return toolModel.count > 0 ? "reading the tool results" : "reading the conversation";
        case "thinking": return "thinking";
        case "writing":  return "writing a tool call";
        case "working":  return "working";
        }
        return "";
    }
    readonly property string _activityGlyph: {
        switch (root.activity) {
        case "reading":  return "\uf02d";     // book
        case "thinking": return "\uf0eb";     // lightbulb, the drawer's own
        case "writing":  return "\uf0ad";     // wrench, a tool call's own
        }
        return "\uf017";                        // clock
    }
    readonly property string _activityTip: {
        switch (root.activity) {
        case "reading":  return "nothing comes back until the model has read the whole prompt";
        case "thinking": return "its reasoning is in the drawer above";
        case "writing":  return "a tool call is sent whole; nothing arrives while it is written";
        }
        return "nothing has arrived since its last word";
    }
    // "~41 k of 64 k context": an estimate (the service prices characters),
    // so it says so.
    function _k(n) { return n >= 1000 ? Math.round(n / 1000) + " k" : String(n); }
    readonly property string _contextText: root.contextTokens > 0 && root.contextLimit > 0
        ? "~" + root._k(root.contextTokens) + " of " + root._k(root.contextLimit) + " context" : ""
    // m:ss. Seconds floor rather than round, so the figure never shows a
    // second that has not fully passed.
    function _mmss(ms) {
        const t = Math.max(0, Math.floor(ms / 1000));
        const ss = t % 60;
        return Math.floor(t / 60) + ":" + (ss < 10 ? "0" : "") + ss;
    }

    // ---- The wait band ---------------------------------------------------
    // ONE fraction, LINEAR, looping: the phase of the trip. The two edges are
    // derived from it (see the header comment and Sweep.js) and handed to the
    // header and to every tool block, so a Behavior per consumer -- which this
    // project bans -- cannot arise.
    property real _wait: 0
    NumberAnimation on _wait {
        from: 0; to: 1
        duration: root.waitPeriodMs
        easing.type: Easing.Linear
        loops: Animation.Infinite
        // Off-screen it is a uniform update per frame that nobody sees.
        // `waiting` runs it too: a 40 s cold model load is the state that most
        // needs to say "this is working", and it is the one with no tokens.
        running: (root.streaming || root.waiting) && root.visible
    }
    readonly property real _waitLead:  Sweep.lead(root._wait, root.waitHeadSpan)
    readonly property real _waitTrail: Sweep.trail(root._wait, root.waitTailSpan)
    readonly property bool _running: root.streaming || root.waiting

    // THE PARKED MARK IS WITHDRAWN AT THE FIRST WRAP. See the header comment:
    // the floor under the leading edge is a resting-state element, and under
    // a running band it makes every trip after the first start 26 px wide.
    // The wrap is the one instant where taking it away paints nothing --
    // there the lead is at fraction 0 and the tail is already outside the
    // left edge -- and it needs no clock of its own: `_wait` going backwards
    // IS the wrap.
    property real _lastWait: 0
    property bool _markHeld: true
    on_WaitChanged: {
        if (root._wait < root._lastWait)
            root._markHeld = false;
        root._lastWait = root._wait;
    }
    readonly property bool _markLive: root._markHeld || root._parked

    // THE BAND'S STATE, AND THE FADE THAT SWAPS IT. `_parked` is what the
    // header (and, through `_markLive`, every block's mark) actually draws
    // from; it changes only inside `swapAnim`, on the frame where `_tintF` is
    // 0 and the inset paints nothing. Starting a run needs no fade at all --
    // the head grows out of the mark that is already there -- so that
    // direction is set outright and the animation is explicit rather than a
    // Behavior racing its own `enabled`.
    property bool _parked: true
    property real _tintF: 1
    on_RunningChanged: {
        swapAnim.stop();
        if (!root._running) {
            swapAnim.start();
            return;
        }
        // The clock is about to restart from 0; setting it here keeps the band
        // off the phase it froze at for the frame in between.
        root._wait = 0;
        root._lastWait = 0;
        root._markHeld = true;
        // REST -> RUN is the one swap that needs no fade, and it is the one
        // that happens at the start of every answer: at fraction 0 both edges
        // are exactly where the parked mark already is, so the two drawings
        // are the same pixels. A FAILED turn's full inset is not, and neither
        // is a park still fading, so those go through the fade like the rest.
        if (root.failed || root._tintF < 1)
            swapAnim.start();
        else
            root._parked = false;
    }
    SequentialAnimation {
        id: swapAnim
        NumberAnimation {
            target: root; property: "_tintF"; to: 0
            duration: root.fadeMs; easing.type: Easing.OutCubic
        }
        // The invisible swap. The state is read HERE rather than latched at
        // the start, so a run that stops and restarts inside one fade still
        // lands on the truth.
        ScriptAction { script: root._parked = !root._running }
        // TWO FRAMES DARK. The swap is invisible at instant granularity by
        // construction; the pause makes it invisible at FRAME granularity too,
        // which is the only granularity a probe (or an eye) can see -- without
        // it the first step of the fade back in lands on the same frame as the
        // new geometry.
        PauseAnimation { duration: 32 }
        NumberAnimation {
            target: root; property: "_tintF"; to: 1
            duration: root.fadeMs; easing.type: Easing.OutCubic
        }
    }

    // ---- The fold --------------------------------------------------------
    // The single clock for opening and closing this turn. The header's chevron
    // runs on the same duration, so the two halves of "this section is
    // opening" move together.
    property real _extent: root.expanded ? 1 : 0
    Behavior on _extent {
        NumberAnimation { duration: root.expandMs; easing.type: Easing.OutCubic }
    }

    // The bevel band a clip inside this turn has to leave room for at an
    // edge a carved box sits on: ShadowBox's own `_margin` -- a 1 px bevel
    // plus a pixel of antialiasing -- because a ShadowBox draws OUTSIDE its
    // own bounds and a clip on that line shears it off. The turn's body clips
    // only while it is MOVING, so it needs none; the thinking drawer's clip
    // is permanent and its first block can be a fenced code block, which is a
    // carved box whose top edge IS that clip's top edge.
    readonly property real _bevelSlack: 2

    // The body's true height, and the height the MOTION is measured against.
    // See the header comment: past the cap the content is below the viewport's
    // bottom edge, so swapping between the two is invisible, and every answer
    // folds on the same curve however long it is.
    readonly property real _bodyFull: bodyCol.implicitHeight
    readonly property real _bodyCap: root.viewportHeight > 0
        ? Math.min(root._bodyFull, root.viewportHeight + root.capMargin)
        : root._bodyFull
    readonly property real _bodyH: root._extent >= 1
        ? root._bodyFull
        : root._bodyCap * root._extent

    // Hover reveals the footer's glyph buttons. A fraction, eased, mixed --
    // never a colour animation.
    property real _hoverF: hoverProbe.hovered ? 1 : 0
    Behavior on _hoverF {
        NumberAnimation { duration: root.fadeMs; easing.type: Easing.OutCubic }
    }
    HoverHandler { id: hoverProbe }

    // =====================================================================
    // NOTE TURNS
    //
    // "switched to gemma4:26b" is not an exchange and must not look like one:
    // no header, no box, no chevron -- a rule, the words, a rule. It says why
    // the answers below it came from somewhere else and then gets out of the
    // way.
    // =====================================================================
    Item {
        id: noteRow
        visible: root.isNote
        width: root.width
        implicitHeight: noteText.implicitHeight + 16

        Rectangle {
            id: noteRuleL
            anchors.verticalCenter: parent.verticalCenter
            x: root.rowInset
            width: Math.max(0, (parent.width - root.rowInset * 2 - noteText.width - 20) / 2)
            height: 1
            color: root.borderColor
        }
        Text {
            id: noteText
            anchors.centerIn: parent
            text: root.noteText
            color: root.faintText
            font.family: root.fontFamily
            font.pixelSize: root.figureSize
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            x: parent.width - root.rowInset - width
            width: noteRuleL.width
            height: 1
            color: root.borderColor
        }
    }

    // =====================================================================
    // HEADER
    // =====================================================================
    ListSectionHeader {
        id: header
        visible: !root.isNote
        width: root.width
        // No word ever stands in for a title that has not been written; the
        // silhouette below covers every slot instead. The single SPACES are
        // load-bearing: the header drops an empty subtitle line and a
        // zero-length glyph slot entirely, and a space keeps each at its real
        // size with nothing drawn in it -- so the silhouette holds the
        // geometry of what will arrive and the swap resolves in place.
        title: root.titlePending ? ""
             : (root.title.length > 0 ? root.title
                                      : Md.firstHeadingOrWords(root.question, 7))
        subtitle: root.titlePending ? " " : root._subtitle
        // The category's colour, and the error colour, through the band's
        // one presence fraction: at `_tintF` 0 both ARE the box's own shadow
        // colour, which is what makes the state swap under them invisible.
        // Mix.js on a fraction, never a Behavior on a colour.
        accentColor: Mix.c(root.headerBoxShadowColor, root.categoryColor, root._tintF)
        errorColor: Mix.c(root.headerBoxShadowColor, root.errColor, root._tintF)
        expanded: root.expanded
        expandable: true
        animDuration: root.expandMs

        // The topic's glyph (the category's as the fallback), left of
        // everything, centred on the box. Muted, not tinted: the colour of
        // the category is already in the inset below.
        iconGlyph: root.titlePending ? " " : root.headerGlyph
        iconColor: root.mutedText
        iconSize: root.headerIconSize
        iconGap: root.headerIconGap
        boxPadding: root.headerPaddingH
        boxPaddingV: root.headerPaddingV
        bottomGap: root.headerBottomGap

        textColor: root.primaryText
        mutedColor: root.mutedText
        faintColor: root.faintText
        fontFamily: root.fontFamily
        titleSize: root.headerTitleSize
        subtitleSize: root.headerSubtitleSize

        // The elapsed silence, in the header's own fixed figure slot: it can
        // tick without moving the model's name beside it, and it holds its
        // last reading while it fades out rather than blanking to 0:00. No
        // figure while the title is still a silhouette -- a silhouette means
        // there is nothing to say yet.
        figureText: root._activityOn && !root.titlePending ? root._mmss(root.activityMs) : ""
        figureTemplate: "8:88"
        figureFadeMs: root.fadeMs

        // The band while generating; a parked full-extent error inset when the
        // turn failed, so a collapsed failure still reads as one; the plain
        // idle mark otherwise -- which is the band CLOSED UP at zero, and not
        // `-1`. Two reasons, and the second is the load-bearing one:
        //
        //   - at rest the pixels are the same either way: a header with no
        //     progress already parks its inset at the idle mark, which is
        //     exactly what a band of zero extent draws.
        //   - the header only smooths a fraction handed to it WITHOUT a tail
        //     (a determinate list's steps arrive a few times a second and
        //     should slide). Handing -1 here would put that 320 ms smoothing
        //     back at the very moment the band ends, so the band would become
        //     a FILL and drain away over a third of a second -- a report of
        //     progress that was never made. With a tail always supplied the
        //     mark parks the instant the answer does, the way a finished tool
        //     block's inset goes plain.
        //
        // All three read `_parked` and not `streaming || waiting`, because the
        // band is still the drawing while it fades out: the state swaps on the
        // one frame where nothing is painted, colour included -- which is why
        // `progressFailed` is gated on it too, or a turn that fails would turn
        // its live band red in place.
        progress: root._parked ? (root.failed ? 1 : 0) : root._waitLead
        progressTail: root._parked ? 0 : root._waitTrail
        progressFailed: root._parked && root.failed
        // The mark, while it is the resting state's or the first trip's. See
        // the header comment: 0 is not a new sentinel, ShadowBox already reads
        // `> 0` and falls back to one half-feather outside the box.
        idleWidthPx: root._markLive ? root.sweepIdleWidth : 0
        boxIdleFeatherPx: root.sweepIdleFeather
        boxActiveFeatherPx: root.sweepActiveFeather
        boxShadowWidth: root.sweepIdleDepth
        boxProgressShadowWidth: root.sweepActiveDepth
        boxIdleEdgeAlpha: root.sweepIdleStrength
        boxActiveEdgeAlpha: root.sweepActiveStrength
        boxIdleFalloff: root.sweepIdleFalloff
        boxActiveFalloff: root.sweepActiveFalloff
        progressBlendEnd: root.sweepBlendEnd

        boxRadius: root.headerRadius
        boxColor: root.headerBoxColor
        boxSurfaceColor: root.surfaceColor
        boxBevelColor: root.headerBoxBevelColor
        boxShadowColor: root.headerBoxShadowColor
        // The corner, as one continuous function of where the header is.
        // At the edge it IS the container's corner; a container radius below
        // it, it is back to its own; in between it eases from one to the
        // other, so a header crossing the corner band during a scroll never
        // steps its arc. Above the edge the arcs are off-screen and the value
        // only has to stay still, which the clamp guarantees.
        topCornerRadius: root._headerTopRadius
        containerRadius: root.containerRadius

        onToggled: root.toggled()
    }

    // A title of the length the classifier is asked for, and the subtitle the
    // turn already knows it will get, measured but never drawn: the skeleton
    // takes THEIR geometry, so each bar sits where the words will sit and the
    // swap resolves in place instead of jumping.
    TextMetrics {
        id: titleSpecimen
        font.family: root.fontFamily
        font.pixelSize: root.headerTitleSize
        font.bold: true
        text: "Six word answer title here"
    }
    TextMetrics {
        id: subtitleSpecimen
        font.family: root.fontFamily
        font.pixelSize: root.headerSubtitleSize
        // The model IS known from ask time, so the bar is as wide as the
        // line it holds space for; "just now" is the state it settles into.
        text: root.model.length > 0 ? root.model + "  ·  just now" : "just now"
    }

    // ---- The header's silhouette, while the title is being written --------
    // Icon square, title bar, subtitle bar: the shape of exactly what will
    // arrive, and nothing else. All three lie on the header box, so they take
    // the list's lighter tone and read as holes in it -- the inversion
    // ListSkeleton documents.
    SkeletonBar {
        id: iconSkeleton
        visible: !root.isNote && root.titlePending
        x: header.boxPadding
        // Centred on the BOX, the way the real glyph's slot is -- the
        // header's bottomGap is outside the box and would sit the mark low.
        y: Math.round((header.height - header.bottomGap - height) / 2)
        width: header.iconSize
        height: header.iconSize
        barColor: root.surfaceColor
        groundColor: root.headerBoxColor
    }
    SkeletonBar {
        id: titleSkeleton
        objectName: "llmTitleSkeleton"
        visible: !root.isNote && root.titlePending
        // The header's own text origin, computed from its public padding
        // rather than read out of it: box padding, then the icon slot (always
        // reserved while pending -- the space glyph above holds it open).
        x: header.boxPadding + header.iconSize + header.iconGap
        y: header.boxPaddingV + Math.round((titleSpecimen.height - height) / 2)
        width: Math.max(24, Math.min(titleSpecimen.advanceWidth,
                                     header.width - x - header.boxPadding - 24))
        height: Math.max(6, Math.round(titleSpecimen.tightBoundingRect.height))
        barColor: root.surfaceColor
        groundColor: root.headerBoxColor
    }
    SkeletonBar {
        id: subtitleSkeleton
        visible: !root.isNote && root.titlePending
        x: titleSkeleton.x
        // The second line of the header's text column: title line height,
        // then the column's -1 spacing, centred on the subtitle's line.
        y: header.boxPaddingV + titleSpecimen.height - 1
           + Math.round((subtitleSpecimen.height - height) / 2)
        width: Math.max(24, Math.min(subtitleSpecimen.advanceWidth,
                                     header.width - x - header.boxPadding - 24))
        height: Math.max(5, Math.round(subtitleSpecimen.tightBoundingRect.height))
        barColor: root.surfaceColor
        groundColor: root.headerBoxColor
    }

    // The icon is a mark, and a mark that cannot be read may explain itself
    // on hover: the tip names the category. A HoverHandler, not a MouseArea:
    // it takes no input at all, so the header's own click-to-fold passes
    // straight through it, and it keeps the header's hand cursor so the
    // pointer tells one story.
    Item {
        id: iconTipAnchor
        visible: !root.isNote && !root.titlePending
                 && root.headerGlyph.length > 0 && root.categoryLabel.length > 0
        x: header.boxPadding
        y: Math.round((header.height - header.bottomGap - height) / 2)
        width: header.iconSize
        height: header.iconSize
        HoverHandler {
            id: iconHover
            cursorShape: Qt.PointingHandCursor
        }
    }
    HoverTip {
        show: iconHover.hovered
        anchorItem: iconTipAnchor
        overlayItem: root.overlayItem
        text: root.categoryLabel
        fontFamily: root.fontFamily
        fontPixelSize: root.figureSize
        surfaceColor: root.surfaceColor
        bevelColor: root.bevelColor
        shadowColor: root.borderColor
        textColor: root.primaryText
    }

    // The elapsed figure is a mark too, and the one question it raises -- why
    // is nothing arriving? -- has an answer per activity.
    HoverTip {
        show: header.figureHovered && root._activityOn
        anchorItem: header.figureAnchor
        overlayItem: root.overlayItem
        text: root._activityTip
        fontFamily: root.fontFamily
        fontPixelSize: root.figureSize
        surfaceColor: root.surfaceColor
        bevelColor: root.bevelColor
        shadowColor: root.borderColor
        textColor: root.primaryText
    }

    // The fold seam's fade is SeamFade (its own component: the tool
    // block folds on the same band). One clock per fold, the fold's own extent.

    // =====================================================================
    // BODY
    //
    // Clipped at the turn's own bounds -- but only while the fold is MOVING:
    // the clip exists so the collapse cuts the content and not the header
    // box's bevel, and at rest it has nothing to cut. Clipping at rest would
    // shear the footer buttons' raised shadows, which ShadowBox draws
    // OUTSIDE their bounds (the same fact behind LlmComposer._chipSlack);
    // with the clip off between folds the shadows fall on the surface the
    // way every other raised thing's do. Mid-fold the seam fade below covers
    // the cut edge.
    // =====================================================================
    Item {
        id: bodyClip
        visible: !root.isNote && height > 0.5
        anchors.top: header.bottom
        width: root.width
        clip: root._extent > 0 && root._extent < 1
        height: root._bodyH

        Column {
            id: bodyCol
            // Rows are inset; the header above is not -- its box is meant to
            // meet the container's edges.
            x: root.rowInset
            width: Math.max(0, parent.width - root.rowInset * 2)
            spacing: root.blockGap

            // ---- The question's attachments ------------------------------
            //
            // OUTSIDE the question's box: a LEFT-aligned strip, its own row level with the
            // question container, showing every attachment as the same chip
            // the composer's strip does -- minus the remove, because a sent
            // message's files are a record, not an editable list. The strip
            // drags sideways when it overflows (no wheel handler: the
            // transcript's is the only one), and each end dissolves into the
            // ground instead of hard-clipping -- but only while there IS
            // content hidden past that end, the same statement of distance
            // the transcript's vertical fades make.
            Item {
                id: chipStrip
                visible: root._chips.length > 0
                width: parent.width
                height: root._chips.length > 0
                        ? chipQRow.height + chipStrip._slack * 2 : 0

                // A ShadowBox paints outside its bounds; the slack keeps the
                // chips' bevels inside the strip's clip when it engages.
                readonly property real _slack: 2
                readonly property real _fadeW: 24

                Flickable {
                    id: chipQStrip
                    anchors.fill: parent
                    contentWidth: chipQRow.width + chipStrip._slack * 2
                    contentHeight: height
                    boundsBehavior: Flickable.StopAtBounds
                    flickableDirection: Flickable.HorizontalFlick
                    interactive: contentWidth > width
                    clip: contentWidth > width

                    Row {
                        id: chipQRow
                        x: chipStrip._slack
                        y: chipStrip._slack
                        spacing: root.chipGap
                        Repeater {
                            model: root._chips
                            delegate: LlmAttachmentChip {
                                required property var modelData
                                att: modelData
                                removable: false
                                overlayItem: root.overlayItem
                                chipSize: root.thumbSize
                                fontFamily: root.fontFamily
                                monoFamily: root.monoFamily
                                radius: root.boxRadius
                                // On the transcript's list fill, dressed the
                                // way the composer dresses its chips: the
                                // chip's own fill takes the header tone.
                                surfaceColor: root.surfaceColor
                                fillColor: root.headerBoxColor
                                bevelColor: root.bevelColor
                                shadowColor: root.borderColor
                                primaryText: root.primaryText
                                mutedText: root.mutedText
                                faintText: root.faintText
                                accent: root.accent
                                errColor: root.errColor
                                tipSurfaceColor: root.surfaceColor
                                codeBgColor: root.codeBgColor
                            }
                        }
                    }
                }

                // The end fades. Opacity IS the hidden distance in fade
                // widths, so each exists exactly while that side hides
                // something and can never dim a strip that fits.
                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: chipStrip._fadeW
                    opacity: Math.max(0, Math.min(1,
                        chipQStrip.contentX / chipStrip._fadeW))
                    visible: opacity > 0.001
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: root.surfaceColor }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                }
                Rectangle {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: chipStrip._fadeW
                    opacity: Math.max(0, Math.min(1,
                        (chipQStrip.contentWidth - chipQStrip.width
                         - chipQStrip.contentX) / chipStrip._fadeW))
                    visible: opacity > 0.001
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 1.0; color: root.surfaceColor }
                    }
                }
            }

            // ---- The question -------------------------------------------
            //
            // Right-aligned and hugging its text: the box is as wide as the
            // question needs, up to `questionMaxWidth` of the body, and its
            // right edge is the body's right edge. Nothing about it is a
            // coloured bubble -- it is the same carved box as everything else,
            // placed where a sent message goes.
            Item {
                id: questionSlot
                width: parent.width
                height: questionBox.height
                visible: root.question.length > 0

                // Width from a metrics object, never from reading the Text
                // back into what sizes it: one such read is a binding loop,
                // and the ban is in CLAUDE.md for a reason.
                TextMetrics {
                    id: qMetrics
                    font.family: root.bodyFontFamily
                    font.pixelSize: root.bodyPixelSize
                    // The same switch as the drawn text's (see there): measure what is drawn.
                    font.preferShaping: root.question.indexOf("`") < 0
                    text: root.question
                }

                readonly property real _pad: root.questionPadding
                readonly property real _maxW: Math.max(120, questionSlot.width * root.questionMaxWidth)
                readonly property real _natW: qMetrics.advanceWidth + questionSlot._pad * 2
                readonly property real _boxW: Math.min(questionSlot._maxW,
                                                       Math.max(80, questionSlot._natW))
                // `lineCount` is a reading of the laid-out text, not an input
                // to the width -- the width came from the metrics above -- so
                // there is no cycle here.
                // ONE line's height, not the whole question's: `qMetrics`
                // measures `root.question`, so on a question with a newline in
                // it its `height` is that question's several lines and the
                // folded height would be that many times too tall. And the pitch
                // the box has to fold on is the RENDERED one, which carries
                // `bodyLineHeight`.
                TextMetrics {
                    id: qLineMetrics
                    font.family: root.bodyFontFamily
                    font.pixelSize: root.bodyPixelSize
                    text: "Ag"
                }
                readonly property bool _collapsible: questionText.lineCount > root.questionMaxLines
                readonly property real _lineH: qLineMetrics.height * root.bodyLineHeight
                readonly property real _fullH: questionText.implicitHeight
                readonly property real _foldedH: questionSlot._lineH * root.questionMaxLines
                // The chevron's strip, along the bottom of the box, so the
                // mark never sits over the last line of the question.
                readonly property real _chevH: questionSlot._collapsible
                    ? root.figureSize + root.questionChevronStrip : 0

                // One eased fraction, 260 ms OutCubic, the same clock the
                // status card in the system update folds on.
                property real _qExtent: root.questionExpanded ? 1 : 0
                Behavior on _qExtent {
                    NumberAnimation { duration: root.expandMs; easing.type: Easing.OutCubic }
                }
                readonly property real _textH: questionSlot._collapsible
                    ? questionSlot._foldedH
                      + (questionSlot._fullH - questionSlot._foldedH) * questionSlot._qExtent
                    : questionSlot._fullH

                ShadowBox {
                    id: questionBox
                    x: Math.max(0, questionSlot.width - width)
                    width: questionSlot._boxW
                    height: questionSlot._textH
                            + questionSlot._pad * 2 + questionSlot._chevH
                    baseRadius: root.questionRadius
                    surfaceColor: root.surfaceColor
                    bevelColor: root.bevelColor
                    shadowColor: root.borderColor
                    backgroundColor: root.headerBoxColor
                    bevelWidth: 1
                    shadowWidth: 3
                }

                // The clip is at the TEXT, not at the box: a ShadowBox draws
                // outside its own bounds and any clip above it shears the
                // bevel off.
                Item {
                    id: questionClip
                    x: questionBox.x + questionSlot._pad
                    y: questionSlot._pad
                    width: Math.max(0, questionBox.width - questionSlot._pad * 2)
                    height: questionSlot._textH
                    clip: true

                    // A read-only TextEdit, not a Text: the committed
                    // question is selectable like everything else that was
                    // said. Width is bound to the clip -- its implicitWidth
                    // is never read (the law), and the box's width still
                    // comes from the TextMetrics above.
                    //
                    // Plain text unless the document has to carry something a
                    // plain string cannot: a search highlight (a background
                    // span) or the reading pitch (CSS line-height -- a TextEdit
                    // has no `lineHeight` property). Either one flips it to
                    // rich text, and neither pays anything when it is off: the
                    // question is parsed once, when it is committed, not per
                    // token like an answer.
                    TextEdit {
                        id: questionText
                        width: parent.width
                        readonly property bool _rich:
                            root.searchQuery.length > 0 || root.bodyLineHeight !== 1
                        readonly property string _inner: root.searchQuery.length > 0
                            ? Md.highlightHtml(
                                  Md.escapeHtml(root.question).replace(/\n/g, "<br>"),
                                  root.searchQuery, root._hlOnBox.toString())
                            : Md.escapeHtml(root.question).replace(/\n/g, "<br>")
                        text: questionText._rich
                            ? (root.bodyLineHeight === 1
                               ? questionText._inner
                               : "<div style=\"line-height:"
                                 + Math.round(root.bodyLineHeight * 100)
                                 + "%; margin:0px;\">" + questionText._inner + "</div>")
                            : root.question
                        readOnly: true
                        selectByMouse: false
                        textFormat: questionText._rich
                                    ? TextEdit.RichText : TextEdit.PlainText
                        color: root.primaryText
                        font.family: root.bodyFontFamily
                        font.pixelSize: root.bodyPixelSize
                        // Exo 2 draws a backtick as a zero-width mark over its neighbour (LlmComposer's field says why): the
                        // sent question keeps its own advance while one is in it.
                        font.preferShaping: root.question.indexOf("`") < 0
                        wrapMode: Text.Wrap
                        selectionColor: root.selectionColor
                        selectedTextColor: root.selectionTextColor
                        cursorVisible: false
                    }

                    // The question's selection, driven from here rather than
                    // by the edit's own `selectByMouse`.
                    //
                    // Not a preference: a native selection drag is Qt's own
                    // mouse grab inside QQuickTextEdit, and there is no way to
                    // be told about it -- so a drag held past the transcript's
                    // bottom edge would select to the last VISIBLE line and stop
                    // there, in the one place where a reader most wants the
                    // ground to move. Driving it through a MouseArea is what
                    // gives the gesture a beginning, a position and an end to
                    // hand to the host's auto-scroll, and it is the same shape
                    // MarkdownView's cross-block layer has, so the
                    // question and the answer select by one mechanism.
                    // Ctrl+C still comes from the edit itself (the press moves
                    // the focus there); `selectByMouse` is off because a second
                    // path into the same selection is exactly the kind of thing
                    // that gets one of the two forgotten.
                    MouseArea {
                        id: questionSel
                        objectName: "llmQuestionSel"
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        preventStealing: true
                        cursorShape: Qt.IBeamCursor

                        property real lastSceneX: 0
                        property real lastSceneY: 0
                        property int  anchorPos: -1

                        function _posAt(lx, ly) {
                            const p = questionSel.mapToItem(questionText, lx, ly);
                            return questionText.positionAt(p.x, p.y);
                        }
                        function _remember(lx, ly) {
                            const p = questionSel.mapToItem(null, lx, ly);
                            questionSel.lastSceneX = p.x;
                            questionSel.lastSceneY = p.y;
                        }
                        function extendTo(lx, ly) {
                            if (questionSel.anchorPos < 0)
                                return;
                            questionText.select(questionSel.anchorPos,
                                                questionSel._posAt(lx, ly));
                        }
                        // Once per frame while the ground is moving: the scene
                        // point is still, the text under it is not.
                        function autoScrollReapply() {
                            if (questionSel.anchorPos < 0)
                                return;
                            const p = questionSel.mapFromItem(null,
                                          questionSel.lastSceneX,
                                          questionSel.lastSceneY);
                            questionSel.extendTo(p.x, p.y);
                        }

                        onPressed: (mouse) => {
                            questionText.forceActiveFocus();
                            questionSel.anchorPos = questionSel._posAt(mouse.x, mouse.y);
                            questionText.select(questionSel.anchorPos,
                                                questionSel.anchorPos);
                            questionSel._remember(mouse.x, mouse.y);
                            if (root.scrollHost)
                                root.scrollHost.autoScrollBegin(questionSel);
                        }
                        onPositionChanged: (mouse) => {
                            if (!questionSel.pressed)
                                return;
                            questionSel.extendTo(mouse.x, mouse.y);
                            questionSel._remember(mouse.x, mouse.y);
                            if (root.scrollHost)
                                root.scrollHost.autoScrollAt(questionSel.lastSceneY);
                        }
                        onReleased: {
                            if (root.scrollHost)
                                root.scrollHost.autoScrollEnd();
                            // A click that moved nothing is a caret, not a
                            // selection.
                            if (questionText.selectionStart === questionText.selectionEnd)
                                questionText.deselect();
                            questionSel.anchorPos = -1;
                        }
                        onCanceled: {
                            if (root.scrollHost)
                                root.scrollHost.autoScrollEnd();
                            questionSel.anchorPos = -1;
                        }
                        onDoubleClicked: (mouse) => {
                            questionText.cursorPosition =
                                questionSel._posAt(mouse.x, mouse.y);
                            questionText.selectWord();
                            questionSel.anchorPos = -1;
                        }
                    }

                    // The question's own fold seam, on its own clock.
                    SeamFade {
                        extent: questionSlot._qExtent
                        ground: root.headerBoxColor
                        fadeHeight: root.seamFadeHeight
                    }
                }

                // Chevron down to open, up to fold again. A swap, not a
                // rotation: a glyph turned about its text box's centre sweeps
                // rather than turning in place, and text swaps are instant.
                // Hover is a short colour fade on one eased fraction, mixed --
                // never a colour swap and never a Behavior on a colour.
                property real _qHoverF: questionArea.containsMouse ? 1 : 0
                Behavior on _qHoverF {
                    NumberAnimation { duration: root.fadeMs; easing.type: Easing.OutCubic }
                }
                Text {
                    id: questionChevron
                    visible: questionSlot._collapsible
                    text: root.questionExpanded ? "" : ""
                    font.family: "Symbols Nerd Font"
                    font.pixelSize: root.figureSize
                    color: Mix.c(root.faintText, root.accent, questionSlot._qHoverF)
                    x: questionBox.x + questionBox.width - questionSlot._pad - width
                    y: questionBox.height - questionSlot._pad - height
                }

                // Only the chevron's strip toggles the fold: the text
                // above it is selectable, and a whole-box click target
                // would swallow every selection drag.
                MouseArea {
                    id: questionArea
                    visible: questionSlot._collapsible
                    enabled: questionSlot._collapsible
                    x: questionBox.x
                    y: questionBox.height - questionSlot._chevH
                    width: questionBox.width
                    height: questionSlot._chevH
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.questionExpanded = !root.questionExpanded
                }
            }

            // ---- Thinking drawer ----------------------------------------
            //
            // Collapsed by default and slim when collapsed: reasoning is
            // worth being able to read and not worth being shown by default.
            Column {
                id: thinkDrawer
                visible: root._hasThinking
                width: parent.width
                // The gap gives up the clip's bevel slack and the clip's
                // content takes it back below, so the prose sits exactly
                // where `drawerGap` puts it and the drawer's height is
                // unchanged -- see `_bevelSlack`.
                spacing: root.drawerGap - root._bevelSlack

                Item {
                    id: thinkHandle
                    width: parent.width
                    height: thinkLabel.implicitHeight + 4

                    // The whole line is the target, and hover is a short
                    // colour fade riding one eased fraction -- glyph and
                    // label together, mixed, never a colour swap.
                    property real _hoverF: thinkArea.containsMouse ? 1 : 0
                    Behavior on _hoverF {
                        NumberAnimation { duration: root.fadeMs; easing.type: Easing.OutCubic }
                    }

                    Text {
                        id: thinkGlyph
                        anchors.verticalCenter: parent.verticalCenter
                        text: ""                      // lightbulb
                        font.family: "Symbols Nerd Font"
                        font.pixelSize: root.figureSize + 1
                        color: Mix.c(root.faintText, root.accent, thinkHandle._hoverF)
                    }
                    Text {
                        id: thinkLabel
                        anchors.left: thinkGlyph.right
                        anchors.leftMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.thinkingLive ? "thinking…"
                            : root.thinkingMs > 0
                              ? "thought for " + (root.thinkingMs < 60000
                                                   ? (root.thinkingMs / 1000).toFixed(1) + "s"
                                                   : root._mmss(root.thinkingMs))
                              : "thought"
                        color: Mix.c(root.faintText, root.accent, thinkHandle._hoverF)
                        font.family: root.fontFamily
                        font.pixelSize: root.figureSize
                    }
                    MouseArea {
                        id: thinkArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.thinkingToggled()
                    }
                }

                // The drawer's own clip. Same easing as the turn's body, so
                // opening a drawer inside an opening turn is one motion.
                Item {
                    id: thinkClip
                    width: thinkDrawer.width
                    clip: true
                    // `thinkingExpanded` is part of the visibility, not just
                    // the height: MarkdownView builds NOTHING while invisible
                    // (dirty flag, replays on show), so gating on height
                    // alone would deadlock -- the height needs the view's
                    // implicitHeight, which the view only produces once
                    // visible. The drawer would open and show nothing, ever.
                    // The fold's own fraction answers this, not the height:
                    // with the bevel slack the clip is never zero-high.
                    visible: root.thinkingExpanded || thinkDrawer._tExtent > 0
                    height: thinkView.implicitHeight * thinkDrawer._tExtent
                            + root._bevelSlack

                    MarkdownView {
                        id: thinkView
                        // Down by the clip's bevel slack, which the drawer's
                        // spacing gave up above: a thinking passage that opens
                        // with a fenced code block or a table puts a carved
                        // box's top edge on the clip's, and a clip there cuts
                        // the bevel that is the only ink separating that box's
                        // lid from the ground.
                        y: root._bevelSlack
                        // Inset to the same 10 px a blockquote's text takes,
                        // so the drawer's prose reads as subordinate to the
                        // handle above it rather than as more answer: muted
                        // ink alone would put it at the answer's own left edge
                        // and the two columns would line up as one.
                        x: root.drawerInset
                        width: Math.max(0, thinkClip.width - root.drawerInset)
                        source: root.thinking
                        streaming: root.thinkingLive
                        bodyFontFamily: root.bodyFontFamily
                        monoFamily: root.monoFamily
                        fontPixelSize: root.bodyPixelSize - 1
                        lineHeight: root.bodyLineHeight
                        scrollHost: root.scrollHost
                        codeFontPixelSize: root.codePixelSize - 1
                        blockSpacing: root.drawerBlockSpacing
                        headingSpacing: root.drawerHeadingSpacing
                        headingScale: root.mdHeadingScale
                        codePadding: root.mdCodePadding
                        codeHeaderHeight: root.mdCodeHeaderHeight
                        quoteInset: root.mdQuoteInset
                        quoteBarWidth: root.mdQuoteBarWidth
                        tableRadius: root.mdTableRadius
                        tableCellPadH: root.mdTableCellPadH
                        tableCellPadV: root.mdTableCellPadV
                        imageInset: root.mdImageInset
                        // Muted throughout: the drawer is an aside, and the
                        // answer under it must stay the thing with contrast.
                        textColor: root.mutedText
                        mutedColor: root.mutedText
                        faintColor: root.faintText
                        linkColor: root.accent
                        surfaceColor: root.surfaceColor
                        codeBgColor: root.codeBgColor
                        codeBevelColor: root.bevelColor
                        codeShadowColor: root.borderColor
                        codeHeaderColor: root.headerBoxColor
                        quoteBarColor: root.accent
                        tableLineColor: root.borderColor
                        tableHeadColor: root.headerBoxColor
                        inlineCodeBgColor: root.headerBoxColor
                        selectionColor: root.selectionColor
                        selectionTextColor: root.selectionTextColor
                        codeRadius: root.boxRadius
                        searchQuery: root.searchQuery
                        searchHighlightColor: root._hlOnList
                        onLinkActivated: (url) => root.linkActivated(url)
                    }

                    // The drawer's fold seam, on the drawer's own clock.
                    SeamFade {
                        extent: thinkDrawer._tExtent
                        ground: root.surfaceColor
                        fadeHeight: root.seamFadeHeight
                    }
                }

                property real _tExtent: root.thinkingExpanded ? 1 : 0
                Behavior on _tExtent {
                    NumberAnimation { duration: root.expandMs; easing.type: Easing.OutCubic }
                }
            }

            // ---- Tool calls ---------------------------------------------
            //
            // For each entry, in order: the model's preface for that round
            // (its own frozen document, never streaming -- the round is
            // over), then the block. The Repeater rides `toolModel`, a list
            // of IDS the turn appends to; the raw array is never its model,
            // so a status patch rebuilds nothing here. The answer view below
            // is the trailing segment and the only view that streams.
            Repeater {
                model: toolModel
                delegate: Column {
                    id: toolRow
                    required property string callId
                    readonly property var entry: root._toolById[toolRow.callId] || null
                    readonly property string preface: toolRow.entry && toolRow.entry.preface
                                                      ? String(toolRow.entry.preface) : ""
                    width: bodyCol.width
                    spacing: root.blockGap

                    MarkdownView {
                        visible: toolRow.preface.length > 0
                        width: bodyCol.width
                        source: toolRow.preface
                        streaming: false
                        bodyFontFamily: root.bodyFontFamily
                        monoFamily: root.monoFamily
                        fontPixelSize: root.bodyPixelSize
                        lineHeight: root.bodyLineHeight
                        scrollHost: root.scrollHost
                        codeFontPixelSize: root.codePixelSize
                        blockSpacing: root.mdBlockSpacing
                        headingSpacing: root.mdHeadingSpacing
                        headingScale: root.mdHeadingScale
                        codePadding: root.mdCodePadding
                        codeHeaderHeight: root.mdCodeHeaderHeight
                        quoteInset: root.mdQuoteInset
                        quoteBarWidth: root.mdQuoteBarWidth
                        tableRadius: root.mdTableRadius
                        tableCellPadH: root.mdTableCellPadH
                        tableCellPadV: root.mdTableCellPadV
                        imageInset: root.mdImageInset
                        textColor: root.primaryText
                        mutedColor: root.mutedText
                        faintColor: root.faintText
                        linkColor: root.accent
                        surfaceColor: root.surfaceColor
                        codeBgColor: root.codeBgColor
                        codeBevelColor: root.bevelColor
                        codeShadowColor: root.borderColor
                        codeHeaderColor: root.headerBoxColor
                        quoteBarColor: root.accent
                        tableLineColor: root.borderColor
                        tableHeadColor: root.headerBoxColor
                        inlineCodeBgColor: root.headerBoxColor
                        selectionColor: root.selectionColor
                        selectionTextColor: root.selectionTextColor
                        codeRadius: root.mdCodeRadius
                        searchQuery: root.searchQuery
                        searchHighlightColor: root._hlOnList
                        onLinkActivated: (url) => root.linkActivated(url)
                    }

                    LlmToolBlock {
                        width: bodyCol.width
                        entry: toolRow.entry
                        expanded: root.toolOpen(toolRow.callId)
                        sweep: root._waitLead
                        sweepTail: root._waitTrail
                        callLabel: root._toolCallLabel(toolRow.entry)
                        overlayItem: root.overlayItem
                        fontFamily: root.fontFamily
                        monoFamily: root.monoFamily
                        figureSize: root.figureSize
                        codePixelSize: root.codePixelSize
                        maxLines: root.toolBlockMaxLines
                        boxRadius: root.boxRadius
                        drawerInset: root.drawerInset
                        codePadding: root.mdCodePadding
                        codeHeaderHeight: root.mdCodeHeaderHeight
                        imageInset: root.mdImageInset
                        thumbSize: root.thumbSize
                        seamFadeHeight: root.seamFadeHeight
                        expandMs: root.expandMs
                        fadeMs: root.fadeMs
                        // The same withdrawal as the header's: one band, one
                        // mark, one latch.
                        sweepIdleWidth: root._markLive ? root.sweepIdleWidth : 0
                        sweepIdleFeather: root.sweepIdleFeather
                        sweepActiveFeather: root.sweepActiveFeather
                        surfaceColor: root.surfaceColor
                        headerBoxColor: root.headerBoxColor
                        bevelColor: root.bevelColor
                        borderColor: root.borderColor
                        primaryText: root.primaryText
                        mutedText: root.mutedText
                        faintText: root.faintText
                        accent: root.accent
                        accentHover: root.accentHover
                        errColor: root.errColor
                        codeBgColor: root.codeBgColor
                        selectionColor: root.selectionColor
                        selectionTextColor: root.selectionTextColor
                        buttonPlateau: root.buttonPlateau
                        buttonPlateauHover: root.buttonPlateauHover
                        buttonBevel: root.buttonBevel
                        buttonShadow: root.buttonShadow
                        onToggled: root.toolToggled(toolRow.callId)
                        onRevokeRequested: (tool, key) => root.grantRevokeRequested(tool, key)
                    }
                }
            }

            // ---- What the model is doing --------------------------------
            // See the header: the foot of the live turn says what the
            // silence is. Thinking with nothing below the drawer is left to
            // the drawer's own label, which is then the last line anyway.
            // Presence fades in; it goes in one frame, because whatever
            // replaces it -- the call it announced, the answer -- lands on
            // the same line in that same frame. A Loader, so a turn that is
            // not being answered carries no block at all (a tool block holds
            // two CodeBlocks even folded).
            Loader {
                width: bodyCol.width
                active: root._activityOn && (root.activity !== "thinking" || toolModel.count > 0)
                sourceComponent: activityComponent
            }
            Component {
                id: activityComponent
                LlmToolBlock {
                    id: activityBlock
                    objectName: "llmActivityBlock"
                    opacity: 0
                    Component.onCompleted: activityIn.start()
                    NumberAnimation {
                        id: activityIn
                        target: activityBlock; property: "opacity"
                        from: 0; to: 1
                        duration: root.fadeMs; easing.type: Easing.OutCubic
                    }
                    activity: root._activityWords
                    activityGlyph: root._activityGlyph
                    activityFigure: root._mmss(root.activityMs)
                    activityNote: root._contextText
                    activityTip: root._activityTip
                    expanded: false
                    sweep: root._waitLead
                    sweepTail: root._waitTrail
                    sweepIdleWidth: root._markLive ? root.sweepIdleWidth : 0
                    sweepIdleFeather: root.sweepIdleFeather
                    sweepActiveFeather: root.sweepActiveFeather
                    overlayItem: root.overlayItem
                    fontFamily: root.fontFamily
                    monoFamily: root.monoFamily
                    figureSize: root.figureSize
                    boxRadius: root.boxRadius
                    fadeMs: root.fadeMs
                    surfaceColor: root.surfaceColor
                    headerBoxColor: root.headerBoxColor
                    bevelColor: root.bevelColor
                    borderColor: root.borderColor
                    primaryText: root.primaryText
                    mutedText: root.mutedText
                    faintText: root.faintText
                    accent: root.accent
                    accentHover: root.accentHover
                    errColor: root.errColor
            }
            }

            // ---- The answer ---------------------------------------------
            MarkdownView {
                id: answerView
                visible: !root.waiting
                width: bodyCol.width
                source: root.answer
                streaming: root.streaming
                bodyFontFamily: root.bodyFontFamily
                monoFamily: root.monoFamily
                fontPixelSize: root.bodyPixelSize
                lineHeight: root.bodyLineHeight
                scrollHost: root.scrollHost
                codeFontPixelSize: root.codePixelSize
                blockSpacing: root.mdBlockSpacing
                headingSpacing: root.mdHeadingSpacing
                headingScale: root.mdHeadingScale
                codePadding: root.mdCodePadding
                codeHeaderHeight: root.mdCodeHeaderHeight
                quoteInset: root.mdQuoteInset
                quoteBarWidth: root.mdQuoteBarWidth
                tableRadius: root.mdTableRadius
                tableCellPadH: root.mdTableCellPadH
                tableCellPadV: root.mdTableCellPadV
                imageInset: root.mdImageInset
                textColor: root.primaryText
                mutedColor: root.mutedText
                faintColor: root.faintText
                linkColor: root.accent
                surfaceColor: root.surfaceColor
                codeBgColor: root.codeBgColor
                codeBevelColor: root.bevelColor
                codeShadowColor: root.borderColor
                codeHeaderColor: root.headerBoxColor
                quoteBarColor: root.accent
                tableLineColor: root.borderColor
                tableHeadColor: root.headerBoxColor
                inlineCodeBgColor: root.headerBoxColor
                selectionColor: root.selectionColor
                selectionTextColor: root.selectionTextColor
                codeRadius: root.mdCodeRadius
                searchQuery: root.searchQuery
                searchHighlightColor: root._hlOnList
                onLinkActivated: (url) => root.linkActivated(url)
            }

            // ---- The tool note ------------------------------------------
            // "stopped after 6 tool rounds" / "cancelled by you": one faint
            // line under the answer, in the shell's face, at figure size.
            Text {
                visible: root.toolNote.length > 0
                width: parent.width
                text: root.toolNote
                color: root.faintText
                font.family: root.fontFamily
                font.pixelSize: root.figureSize
                wrapMode: Text.Wrap
            }

            // ---- Waiting -------------------------------------------------
            //
            // Three bars at the answer's own line height, holding the space an
            // answer will take. NOT ListSkeleton: its geometry model is header
            // boxes with rows inside them, and prose has neither -- feeding it
            // a fake header to get three bars would be a lie about what is
            // coming. But the BAR is `SkeletonBar`, the shell's one silhouette
            // bar, and that is not a convenience: it is what keeps the pulse
            // from reading as jittery.
            //
            // Hand-rolled Rectangles under one eased opacity (0.35 -> 0.70 on
            // a `headerBox` fill lying on the `listBox` ground) would stutter.
            // Those two colours are NINE 8-bit levels apart, so the
            // whole breath spans 9 * 0.35 = 3.15 levels: measured, the
            // entire pulse rendered as FIVE distinct pictures (the bar's
            // interior is flat, and it took the values 221..225), each held
            // ~124 ms and switching wherever the eased fraction happened to
            // cross a 1/255 boundary -- which InOutQuad does unevenly. The
            // animated fraction was perfectly smooth (201 distinct values over
            // 201 frames, no repeat); it was the RENDER that had five states.
            // In the dark theme the same arithmetic gives 5 levels of
            // difference and 1.75 of travel, i.e. a two-state blink.
            //
            // `SkeletonBar` breathes on GEOMETRY at full opacity instead --
            // antialiased, and therefore continuous at sub-pixel resolution
            // however little contrast the fill has -- on the same 900 ms
            // InOutSine clock the header's title and subtitle skeletons use.
            // Those are on screen at this exact moment (a waiting turn has no
            // title yet), and bars on another period would drift in and out
            // of phase beside them across the same 300 px. One clock, one
            // material, one component.
            //
            // The geometry is a DISTANCE, not a scale. A scale is a
            // multiplier: measured on scale 0.965, the ends of the 724, 681
            // and 449 px bars travel 25.3, 23.8 and 15.7 px, so the top line
            // pulses 61 % harder than the bottom one and the column reads as
            // uneven -- which is what `pulseTravel` fixes. Every bar travels
            // the same 8 px at each end whatever it is long, and the wave is
            // the STAGGER: one clock, one period, each line a beat behind the
            // line above it.
            Column {
                id: waitBars
                visible: root.waiting
                width: parent.width
                spacing: root.waitBarGap

                Repeater {
                    model: [1.0, 0.94, 0.62]
                    delegate: SkeletonBar {
                        required property var modelData
                        required property int index
                        objectName: "llmWaitBar"
                        width: waitBars.width * modelData
                        height: Math.round(root.bodyPixelSize * 1.15)
                        radius: height / 2
                        barColor: root.headerBoxColor
                        groundColor: root.surfaceColor
                        pulse: root.waiting && root.expanded
                        pulseTravel: root.waitBarTravel
                        pulsePhaseMs: index * root.waitBarStaggerMs
                    }
                }
            }

            // ---- Error strip ---------------------------------------------
            Item {
                id: errorSlot
                visible: root.failed && root.errorText.length > 0
                width: parent.width
                height: errorLabel.implicitHeight + root.errorPadding * 2

                ShadowBox {
                    anchors.fill: parent
                    baseRadius: root.boxRadius
                    surfaceColor: root.surfaceColor
                    bevelColor: root.bevelColor
                    shadowColor: root.borderColor
                    backgroundColor: root.errTint
                    bevelWidth: 1
                    shadowWidth: 3
                }
                Text {
                    id: errorLabel
                    x: root.errorPadding
                    y: root.errorPadding
                    width: Math.max(0, parent.width - root.errorPadding * 2)
                    text: root.errorText
                    color: root.errColor
                    font.family: root.fontFamily
                    font.pixelSize: root.bodyPixelSize
                    wrapMode: Text.Wrap
                }
            }

            // ---- Footer --------------------------------------------------
            //
            // Four actions: copy, regenerate, edit, delete. They are there the
            // whole time and only their opacity follows the pointer: nothing
            // announces the affordance but the hand cursor and a short fade.
            // The figures on the right do not fade -- they are a reading, not
            // a control.
            Item {
                id: footer
                visible: root._showFooter
                width: parent.width
                height: Math.max(copyBtn.implicitHeight, statsText.implicitHeight)

                Row {
                    id: actions
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: root.footerButtonGap
                    opacity: root._hoverF
                    // Invisible below the threshold, so a turn nobody is
                    // pointing at has no hit targets either.
                    visible: opacity > 0.02

                    RaisedButton {
                        id: copyBtn
                        // The copy mark, and for 1.2 s after a click the check
                        // (CodeBlock's feedback): one glyph for another in one
                        // face at one size, so nothing moves.
                        text: root._copied ? "\uF00C" : "\uF0C5"
                        fontFamily: "Symbols Nerd Font"
                        // A nerd-font glyph must never render bold: the
                        // synthetic emboldening distorts the icon.
                        bold: false
                        minWidth: root.footerButtonMinWidth
                        horizontalPadding: 6
                        implicitHeight: root.footerButtonHeight
                        surfaceColor: root.surfaceColor
                        plateauColor: root.buttonPlateau
                        plateauHoverColor: root.buttonPlateauHover
                        bevelColor: root.buttonBevel
                        shadowColor: root.buttonShadow
                        textColor: root.mutedText
                        faintTextColor: root.faintText
                        accentColor: root.accent
                        accentHoverColor: root.accentHover
                        accentBevelColor: root.accentBevel
                        accentTextColor: root.textOnAccent
                        onClicked: {
                            root._copied = true;
                            copiedTimer.restart();
                            root.copyRequested();
                        }
                        // A HoverHandler on an item ABOVE the button: its own MouseArea takes hover.
                        Item {
                            anchors.fill: parent
                            HoverHandler { id: copyHover }
                        }
                        HoverTip {
                            show: copyHover.hovered
                            anchorItem: parent
                            overlayItem: root.overlayItem
                            text: "Copy the answer"
                            fontFamily: root.fontFamily
                            fontPixelSize: root.figureSize
                            surfaceColor: root.surfaceColor
                            bevelColor: root.bevelColor
                            shadowColor: root.borderColor
                            textColor: root.primaryText
                        }
                    }
                    RaisedButton {
                        text: ""                      // regenerate
                        fontFamily: "Symbols Nerd Font"
                        // A nerd-font glyph must never render bold: the
                        // synthetic emboldening distorts the icon.
                        bold: false
                        minWidth: root.footerButtonMinWidth
                        horizontalPadding: 6
                        implicitHeight: root.footerButtonHeight
                        surfaceColor: root.surfaceColor
                        plateauColor: root.buttonPlateau
                        plateauHoverColor: root.buttonPlateauHover
                        bevelColor: root.buttonBevel
                        shadowColor: root.buttonShadow
                        textColor: root.mutedText
                        faintTextColor: root.faintText
                        accentColor: root.accent
                        accentHoverColor: root.accentHover
                        accentBevelColor: root.accentBevel
                        accentTextColor: root.textOnAccent
                        onClicked: root.regenerateRequested()
                        // A HoverHandler on an item ABOVE the button: its own MouseArea takes hover.
                        Item {
                            anchors.fill: parent
                            HoverHandler { id: regenHover }
                        }
                        HoverTip {
                            show: regenHover.hovered
                            anchorItem: parent
                            overlayItem: root.overlayItem
                            text: "Regenerate the last answer"
                            fontFamily: root.fontFamily
                            fontPixelSize: root.figureSize
                            surfaceColor: root.surfaceColor
                            bevelColor: root.bevelColor
                            shadowColor: root.borderColor
                            textColor: root.primaryText
                        }
                    }
                    RaisedButton {
                        text: ""                      // pencil / edit
                        fontFamily: "Symbols Nerd Font"
                        // A nerd-font glyph must never render bold: the
                        // synthetic emboldening distorts the icon.
                        bold: false
                        minWidth: root.footerButtonMinWidth
                        horizontalPadding: 6
                        implicitHeight: root.footerButtonHeight
                        surfaceColor: root.surfaceColor
                        plateauColor: root.buttonPlateau
                        plateauHoverColor: root.buttonPlateauHover
                        bevelColor: root.buttonBevel
                        shadowColor: root.buttonShadow
                        textColor: root.mutedText
                        faintTextColor: root.faintText
                        accentColor: root.accent
                        accentHoverColor: root.accentHover
                        accentBevelColor: root.accentBevel
                        accentTextColor: root.textOnAccent
                        onClicked: root.editRequested()
                        // A HoverHandler on an item ABOVE the button: its own MouseArea takes hover.
                        Item {
                            anchors.fill: parent
                            HoverHandler { id: editHover }
                        }
                        HoverTip {
                            show: editHover.hovered
                            anchorItem: parent
                            overlayItem: root.overlayItem
                            text: "Edit this question and send it again; the exchanges after it are dropped"
                            fontFamily: root.fontFamily
                            fontPixelSize: root.figureSize
                            surfaceColor: root.surfaceColor
                            bevelColor: root.bevelColor
                            shadowColor: root.borderColor
                            textColor: root.primaryText
                        }
                    }
                    // Delete drops this exchange, question and answer, and
                    // leaves every other one standing. Its glyph is the error
                    // colour rather than the muted one: it is the only button
                    // here that destroys something, and the plateau it sits on
                    // is the same as the others -- one mark, not a red button.
                    RaisedButton {
                        text: ""                      // trash
                        fontFamily: "Symbols Nerd Font"
                        // A nerd-font glyph must never render bold: the
                        // synthetic emboldening distorts the icon.
                        bold: false
                        minWidth: root.footerButtonMinWidth
                        horizontalPadding: 6
                        implicitHeight: root.footerButtonHeight
                        surfaceColor: root.surfaceColor
                        plateauColor: root.buttonPlateau
                        plateauHoverColor: root.buttonPlateauHover
                        bevelColor: root.buttonBevel
                        shadowColor: root.buttonShadow
                        textColor: root.errColor
                        faintTextColor: root.faintText
                        accentColor: root.accent
                        accentHoverColor: root.accentHover
                        accentBevelColor: root.accentBevel
                        accentTextColor: root.textOnAccent
                        onClicked: root.deleteRequested()
                        // A HoverHandler on an item ABOVE the button: its own MouseArea takes hover.
                        Item {
                            anchors.fill: parent
                            HoverHandler { id: deleteHover }
                        }
                        HoverTip {
                            show: deleteHover.hovered
                            anchorItem: parent
                            overlayItem: root.overlayItem
                            text: "Delete this exchange"
                            fontFamily: root.fontFamily
                            fontPixelSize: root.figureSize
                            surfaceColor: root.surfaceColor
                            bevelColor: root.bevelColor
                            shadowColor: root.borderColor
                            textColor: root.primaryText
                        }
                    }
                }

                // "loaded in 8.3 s · 535 tok · 35.3 tok/s" -- `footerFigures`
                // is where the words and the load figure's rule are.
                // Right-pinned, so the token count growing a digit moves the
                // count and not the rate. Centred
                // on the footer row -- the same line the buttons ride -- and
                // inset a rowInset from the footer's own edge, so the figures
                // sit 12 px from the container's right wall (row inset 6 +
                // margin 6, the card-padding number) and clear of the corner
                // radius, rather than hugging the floor and the curve.
                Text {
                    id: statsText
                    anchors.right: parent.right
                    anchors.rightMargin: root.footerFigureMargin
                    anchors.verticalCenter: parent.verticalCenter
                    visible: text.length > 0
                    text: root.footerFigures
                    color: root.faintText
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                }
            }
        }

        // The body's fold seam, riding the fold's one clock. Declared after
        // the column so it paints over the content at the moving edge.
        SeamFade {
            extent: root._extent
            ground: root.surfaceColor
            fadeHeight: root.seamFadeHeight
        }
    }
}
