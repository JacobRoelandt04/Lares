pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import "../../../common/theme"
import "../../../common/components"
import "LlmPathComplete.js" as Complete

// =============================================================================
// LlmComposer.qml
//
// The chat input: one carved field that holds everything the user can do to a
// question -- attachments above, the text in the middle, the attach/tools
// buttons, the model pill and send/stop at the foot -- rather than a field with
// a toolbar bolted underneath it. That is the shape every web chat frontend
// converged on, and it is also the honest one here: the buttons act on THIS
// message, so they belong inside its groove.
//
// WHY THE MODEL PICKER LIVES HERE. Which model answers is a property of the
// question about to be asked, so the choice belongs beside the button that
// asks it: the control row reads [attach] [tools] ..... [model] [send], and
// the drop-down opens UPWARD. The picker floats its list through the host's
// `overlayItem` (painting outside an ancestor's bounds works, INPUT outside
// them does not -- a list drawn outside the composer could not be clicked),
// so the host must forward the popup's overlay down through here.
//
// WHY THE HEIGHT IS ANIMATED AND THE CONTENT IS ANCHORED TO THE EDGES.
// The field grows with the text between `minLines` and `maxLines`, and the
// growth is eased (260ms OutCubic, the shell's resize easing). Everything
// inside is therefore anchored to the box's own moving edges -- chips to the
// top, the control row to the bottom, the text between them -- so nothing is
// laid out underneath something whose height is mid-flight. Past `maxLines`
// the box stops growing and the text scrolls inside it -- with no scroll bar
// (the shell has none), so the text keeps its full width at every height.
//
// The text edit is a Controls `TextArea` handed to a `Flickable` through the
// `TextArea.flickable` attached property: that is what makes the caret stay
// visible once the text is taller than the box, without this file computing a
// scroll position. `background: null` because the ShadowBox IS the chrome.
//
// THE CONFIRMATION LIVES IN THE GROOVE. When an
// acting tool call needs the user's OK, LlmConfirmPanel appears at the TOP of
// this box and the box grows UPWARD to hold it: a third eased part
// (`_animConfirmH`) is added to the height sum, the panel's slot is anchored
// to the top edge -- the edge that moves -- the chip strip hangs off the
// slot's foot, and the text and the control row stay anchored to the bottom,
// so the prompt does not move a pixel. The slot clips with the chip strip's
// own 2 px bevel slack. While a request stands the field is READ-ONLY with
// its draft and caret untouched, the panel holds the focus, and every key the
// field still receives is forwarded to the panel's one key path -- so Return
// never submits, whichever item has the focus. A request landing closes the
// model list, the pdf menu and the wrench menu: one floating thing at a time.
//
// THE WRENCH HAS A SECOND FACE. Left-click toggles tools; when the
// current model does not even DECLARE tool calling the button is faint and
// inert and its tip says so (the latch survives a model switch -- the choice
// is the user's, the ability is the model's). Right-click opens LlmGrantsMenu
// in the overlay: the remembered allowances, each with its ×, and Revoke
// all.
//
// THE TIP NAMES THE TOOLS: a human-language listing of exactly what tools are
// present, with no explanation per tool. It reads: the verdict for this
// model in a fixed slot -- proven and how fast, declared and unmeasured, or
// failed the probe -- then every offered tool by its human label, grouped by
// WHAT THE POLICY DOES WITH IT (runs free / asks first / off), then the
// standing allowances. Grouping by policy and not by file is the one fact a
// list of tools has to carry, and it is the module's own law: read-only runs
// free, anything that acts asks. A FAMILY IS SPLIT BY ITS ACTIONS, not by
// its entry: hyprctl reads windows for free and asks before it moves one, so
// it appears in both groups with the count of actions it contributes -- the
// entry's own `kind` would call the whole of it free, which is a lie. The
// two counted fields (`freeActions`, `askActions`) come from the service; a
// row without them falls back to the entry's kind, so an old host degrades
// to the truth about single-action tools instead of to nothing.
// The picker's tools dot reads the same probe verdicts
// (`toolProof`, model → { state, ms, why }), rebuilt from the service's
// `toolProbeInfo` on every `toolProbeChanged` -- the ctxInfo pattern.
//
// A PATH COMPLETES ON TAB. A word that starts
// with "@" is a path being typed: Tab completes it when one answer is left,
// extends it to the longest common prefix when several are, and a SECOND Tab
// lists what remains in LlmCompletionList -- a FOURTH eased part of this box,
// between the chips and the text, sized like the confirmation and clipped the
// same way. The list is not a menu: the caret never leaves the prompt, typing
// narrows it, Escape closes it, and a click on a row completes that row. The
// "@" is typed, shown and SENT as typed -- the field's `text` is the message
// and the draft, so a completed path cannot be marked without turning the
// document into HTML. Tab and Backtab are always swallowed here (a literal tab
// in a prompt is worthless, and an unclaimed Backtab escapes the field to
// whatever else is focusable) -- while a confirmation stands they are
// swallowed and do NOTHING, which is what "the panel owns every key" means.
//
// EVERY SCROLLABLE BOX IN HERE IS DRESSED. The chip strip and the draft field
// hand their wheel and their edge fades to ScrollDressing, so one notch is
// 120 px in the composer exactly as it is in the transcript, and the draft
// fades at the top like every other list in the shell.
//
// Colours: every colour is a property with a `Theme.<token>` default, so the
// host can pass the popup's whole palette down. Nothing inside reads Theme
// directly, and nothing animates a colour -- hover eases a 0..1 fraction and
// `Mix.js` does the blend, because the theme is already one clock.
// =============================================================================
Item {
    id: root
    objectName: "llmComposer"

    // ======================================================================
    // PUBLIC API
    // ======================================================================

    property string placeholder: "Ask anything"
    property alias  text: area.text
    // While generating the button is stop. A second question cannot be posted
    // into a turn that is still being answered, so Return does one of two
    // things: nothing (a host with no queue) or, with `queueEnabled`, SENDS IT
    // TO THE QUEUE -- the host shows what waits (LlmQueueStrip) and runs it
    // when the model is free, so nothing is silent about it. A pending
    // confirmation still takes Return for itself.
    property bool   generating: false
    property bool   queueEnabled: false
    // NOTE: `enabled` is Item's own property, deliberately not redeclared --
    // shadowing it would give the host two switches that disagree, and the
    // built-in one already gates every MouseArea and the text edit below.
    property int    minLines: 1
    property int    maxLines: 6
    property string fontFamily: "Inter"
    // THE BODY FACE: the prompt being written -- the words the user is
    // composing -- in the same face the answer is read in. Nothing else in the
    // composer: the chips, the pill, the buttons stay on `fontFamily`. The
    // field's line height (what grows the box) is measured in this face too,
    // because it IS the field's.
    //
    // THE PLACEHOLDER IS NOT IN IT. With nothing typed and no conversation
    // open, everything on screen is the shell's display face; the body face is
    // for text the eye reads fast, and an empty field's prompt is not that --
    // it is a label. So the placeholder is drawn HERE, as this file's own Text
    // on `fontFamily`, and the control's built-in one is not used: Qt draws
    // that in the control's own font, which is the one the typing must be in,
    // and a control cannot carry two faces at once.
    property string bodyFontFamily: "Inter"
    // For the chips' text-file preview tip (the markdown highlighter renders
    // in the shell's code face).
    property string monoFamily: "Consolas"
    property int    fontPixelSize: 12
    property real   radius: 14
    property real   padding: 10
    property real   buttonSize: 28
    // ---- Tunables ----
    // The chips are rounded SQUARES (the Claude-webapp shape): silhouette
    // thumbnail on top, the filename tiny under it. One row, fixed height.
    property real   chipSize: 64
    property real   chipFadeWidth: 24       // the strip's edge fades
    // The shell's one scroll notch and its one edge band, for every box in
    // here (ScrollDressing: 1.0 == 120 px per notch).
    property real   scrollSpeed: 1.0
    property real   fadeHeight: 34
    property int    resizeMs: 260           // the shell's resize easing
    property int    chipRevealMs: 120       // the chips' control-stack reveal
    property int    chipNameFontSize: 8
    // The picker's marks, forwarded (see LlmModelPicker).
    property real   capDotSize: 5
    property real   capSlotWidth: 12
    property real   vramBarHeight: 4
    property real   vramMinStepPx: 6
    property real   vramTrackOpacity: 0.22
    property real   vramCardOpacity: 0.45
    // How long the bar's whole appearance gesture takes: the old bar's
    // retreat and the new one's growth, sequential, on one curve.
    property int    vramSwapMs: 420
    // How often the open list re-asks the service for the card, so a bar can
    // follow a model loading in.
    property int    vramLiveRefreshMs: 1000
    property real   modelRowHeight: 42
    // The loader shape: [{ path, name, mime, kind, isImage, b64, textContent,
    // images, pageCount, durationMs, peaks, pending, failed, failReason }],
    // plus `includeImages` on a pdf -- owned by the host (the
    // attachment loader builds them and patches each in place as it
    // resolves); this file only draws them (through LlmAttachmentChip) and
    // reports which one the user dismissed or re-flagged.
    property var    attachments: []
    property bool   allowAttachments: true
    property bool   toolsEnabled: false
    property bool   allowTools: true
    // The host's floating layer (LlmPopup.overlayItem), forwarded to the
    // picker's drop-down and to every HoverTip here. Null = local fallback.
    property Item   overlayItem: null

    // ---- The model picker, fed straight through ---------------------------
    // The composer owns the picker but knows nothing about models: it forwards
    // the backend's facts (and the service for the ctx row) and re-emits the
    // one signal.
    property var    models: []
    property var    loaded: ({})
    property bool   modelsBusy: false
    property bool   modelsOffline: false
    property string currentModel: ""
    // The LlmService, for the picker's ctx row (ctxInfo / setCtxMode /
    // setCtxValue / ctxInfoChanged) and its VRAM bar (vramInfo /
    // vramInfoChanged). The composer still knows nothing about
    // models -- this is a pipe. The POPUP must set it, or the ctx row stays
    // hidden and the VRAM bar is never drawn.
    property var    service: null
    // EXTRA: the drop-down's geometry, so a host that knows how much room is
    // above the composer can clamp it without reaching into the picker.
    property real   modelListWidth: 268
    property real   modelListMaxHeight: 280

    // ---- Palette ----
    property color surfaceColor: Theme.surface          // ground OUTSIDE the box
    property color fieldColor: Theme.panelSunk          // the groove's fill
    property color listBoxColor: Theme.listBox          // what the drop-down lies over
    property color headerBoxColor: Theme.headerBox      // the chips' fill
    property color bevelColor: Theme.bevel
    property color shadowColor: Theme.border
    property color primaryText: Theme.textPrimary
    property color mutedText: Theme.textMuted
    property color faintText: Theme.textFaint
    property color accent: Theme.accent
    property color accentHover: Theme.accentHover
    property color accentBevel: Theme.accentBevel
    property color textOnAccent: Theme.textOnAccent
    property color buttonPlateau: Theme.buttonPlateau
    property color buttonPlateauHover: Theme.buttonPlateauHover
    property color buttonBevel: Theme.buttonBevel
    property color buttonShadow: Theme.buttonShadow
    property color errColor: Theme.error
    // The picker's capability dots, forwarded.
    property color capVisionColor: Theme.catExtra
    property color capToolsColor: Theme.catAur
    property color capThinkColor: Theme.catFlatpak
    signal submitted(string text, var attachments)
    signal stopRequested()
    signal attachRequested()
    signal attachmentRemoved(int index)
    // A pdf chip's image toggle was clicked. `includeImages` is
    // ALREADY written on the attachment object in `attachments` -- that is
    // the shared flag the service reads at wire time -- so this is the host's
    // cue, not its instruction: the loader may now have to render pages it
    // skipped (it loads them lazily), and the popup is the only thing holding
    // both the loader and the array.
    signal attachmentImagesToggled(int index, bool includeImages)
    signal toolsToggled(bool on)
    signal modelPicked(string modelId)

    // ---- Tool calling ------------------------------------------------------
    // The confirmation request or null; the host binds
    // `service.pendingConfirm`. While it stands the panel is up, the field is
    // read-only and the focus is the panel's.
    property var    confirmRequest: null
    // (sudo's password is not asked here: it goes to the shell's
    // authentication toast, and the host says so in `placeholder`.)
    readonly property bool confirming: !!root.confirmRequest
    // Lines of the detail visible before the box scrolls inside.
    property int    confirmMaxLines: 12
    // "yes" | "no" | "always" -- the host hands it to service.answerConfirm.
    signal confirmAnswered(string id, string decision)
    // The wrench menu's rows and the registry's load rejections: the host
    // binds `service.tools.grants` / `service.tools.errors`.
    property var    grants: []
    property var    toolErrors: []
    // What THIS model would be sent: [{ name, kind, enabled, action }], the
    // host binds `service.toolsOffered(currentModel)`.
    property var    toolsOffered: []
    // The server's claim for the current model (`backend.capsOf(m).tools`):
    // false makes the wrench faint and inert.
    property bool   modelDeclaresTools: true
    // The probe's verdict for the current model: "none" | "declared" |
    // "proven" | "failed", and its time for the tip's figure.
    property string toolProbeState: "none"
    property int    toolProbeMs: 0
    // The wire price of the offered definitions (service.toolDefinitionTokens).
    property int    toolDefinitionTokens: 0
    signal grantRevoked(string tool, string key)
    signal allGrantsRevoked()
    // The wrench menu's tunables, forwarded.
    property real   grantsMenuWidth: 300
    property real   grantsMenuMaxHeight: 320
    // The tip's wrapped listing takes an EXPLICIT width: the bubble sizes
    // itself from its content, so a Text that sized itself from the bubble
    // would be the binding loop.
    property real   wrenchTipWidth: 280
    property real   notesTipGap: 6
    property real   notesTipWidth: 200
    property real   swipePixelToAngle: 2.5
    property bool   swipeToSwitchBrand: true
    // How long the model list takes to change size on a brand switch.
    property int    pickerResizeMs: 260
    // The model list's two stripes and its MoE cell.
    property real   stripeMutedSaturation: 0.22
    property real   stripeMutedLightnessMix: 0.4732
    property int    defaultStripeFadeMs: 160
    property int    stripeSelectFadeMs: 120
    property bool   showMoeColumn: true

    // ---- Path completion --------------------------------------------------
    // How tall the list may stand, in rows, and how many entries it will draw
    // at all: five thousand matches is a typing mistake, not a list.
    property int    completionMaxRows: 6
    property int    completionMaxEntries: 120
    property real   completionRadius: 10
    // True while the list is up. Nothing outside reads it; it is public so a
    // harness can see the state it is asserting.
    property bool   completing: false

    // ---- The pdf menu ------------------------------------------------------
    // Right-click on a pdf chip's pictures glyph opens LlmPdfMenu above the
    // chip. The menu edits THAT FILE's settings, not the shell's: these four
    // properties are the DEFAULTS a file with no override of its own runs
    // under (the panel edits them, a newly attached file starts from them),
    // and a settled slider emits `pdfSettingChanged(index, key, value)` where
    // `index` indexes `attachments` and `key` is the loader's own opts key --
    // "imageCap" | "imageMinArea" | "pageCap". The host's whole job is
    // `loader.setOpts(attachments[index], { [key]: Math.round(value) })`,
    // which re-extracts that one file.
    property int    pdfImageCap: 32
    property int    pdfImageMinArea: 10000
    property int    pdfPageCap: 24
    property string pdfImageMode: "embedded"      // "embedded" | "pages"
    signal pdfSettingChanged(int index, string key, real value)
    // The menu's tunables, forwarded.
    property int    pdfImageCapMax: 80
    property int    pdfImageMinAreaMax: 40000
    property int    pdfImageMinAreaStep: 500
    property int    pdfPageCapMax: 60
    property real   pdfMenuWidth: 224
    property real   pdfMenuSliderScale: 0.8
    property int    pdfMenuSettleMs: 250

    function clear() {
        // Only the text: `attachments` is the host's array, and the host
        // clears it when it has consumed the message.
        area.text = "";
        root.completing = false;
    }
    function focusField() { area.forceActiveFocus(); }
    // A prompt that ARRIVES rather than being typed (the restored draft of a conversation, of a rebuilt popup): the caret goes to
    // its END, where the writing left off -- a plain `text =` leaves it at the start, and a long draft shows its first line --
    // and the text is not typed text, so it neither turns the tools on for a path in it nor turns them off for the lack of one
    // (the wrench belongs to the conversation, `_noteText`).
    property bool _arriving: false
    function loadText(t) {
        root._arriving = true;
        area.text = t;
        root._arriving = false;
        area.cursorPosition = area.length;
    }
    // The whole prompt selected, so one Backspace or any key replaces it (a template a host pre-filled).
    function selectAllText() { area.selectAll(); }

    // ---- DICTATION (the shell route: DictationService's header, docs/dictation.md "The shell's own fields") ----------------
    // The prompt takes a take's words itself while it has the caret: Hyprland never announces the shell's own fields to the
    // input method. The PREEDIT is put into the edit under `dictationBusy` (no draft, no wrench, no completion hears it), underlined
    // by a bar per visual line that is a child of the edit (it scrolls with it), and taken out again before anything else happens
    // -- a key, the next preedit, a commit; the caret stands before it, where the commit goes. A commit is typed text.
    readonly property bool dictationActive: area.activeFocus && !area.readOnly && root.enabled && !root.confirming
    readonly property bool dictationBusy: root._dictBusy
    property var _pre: null
    property bool _dictBusy: false
    Component {
        id: preeditBar
        Rectangle {
            height: 1
            color: root.accent
        }
    }
    // The prompt as typed: the text with a preedit standing in it taken out (the draft).
    function draftText(): string {
        const p = root._pre;
        if (!p)
            return area.text;
        const at = root._preAt(p);
        return at < 0 ? area.text : area.text.substring(0, at) + area.text.substring(at + p.text.length);
    }
    // Where the shown preedit is now: its own place, or (an edit before it moved it) the nearest copy; -1: gone.
    function _preAt(p: var): int {
        if (area.getText(p.pos, p.pos + p.text.length) === p.text)
            return p.pos;
        const t = area.text;
        const back = t.lastIndexOf(p.text, p.pos), fwd = t.indexOf(p.text, p.pos);
        if (back < 0)
            return fwd;
        return fwd < 0 || p.pos - back <= fwd - p.pos ? back : fwd;
    }
    function _clearDictPreedit(): void {
        const p = root._pre;
        root._pre = null;
        if (!p)
            return;
        for (const b of p.bars)
            if (b)
                b.destroy();
        const at = root._preAt(p);
        if (at < 0)
            return;
        root._dictBusy = true;
        area.remove(at, at + p.text.length);
        area.cursorPosition = at;
        root._dictBusy = false;
    }
    function dictationPreedit(text: string): void {
        root._clearDictPreedit();
        const t = String(text || "");
        if (t === "" || !root.dictationActive)
            return;
        const col = area.cursorPosition;
        root._dictBusy = true;
        area.insert(col, t);
        area.cursorPosition = col;
        root._dictBusy = false;
        // one bar per visual line the words run over (NotesPopup's editor draws its preedit the same way)
        const bars = [];
        let y0 = null, x0 = 0, xe = 0, h = 0;
        for (let k = col; k <= col + t.length; k++) {
            const a = area.positionToRectangle(k);
            if (y0 !== null && (k === col + t.length || a.y !== y0)) {
                bars.push(preeditBar.createObject(area, { x: x0, y: y0 + h - 1, width: Math.max(1, Math.round(xe - x0)) }));
                y0 = null;
            }
            if (k === col + t.length)
                break;
            const b = area.positionToRectangle(k + 1);
            if (y0 === null) {
                y0 = a.y;
                x0 = a.x;
                h = a.height;
            }
            xe = b.y === a.y ? b.x : area.width;
        }
        root._pre = { pos: col, text: t, bars: bars };
    }
    function dictationCommit(text: string): void {
        root._clearDictPreedit();
        const t = String(text || "");
        if (t === "" || !root.dictationActive)
            return;
        const col = area.cursorPosition;
        area.insert(col, t);
        area.cursorPosition = col + t.length;
    }
    // The text before the caret on its line (the spacing of the next piece).
    function dictationBefore(): string {
        const p = root._pre;
        const t = area.text;
        const end = p ? Math.max(0, root._preAt(p)) : area.cursorPosition;
        return t.substring(t.lastIndexOf("\n", end - 1) + 1, end);
    }

    // A menu must not survive the popup being put away: `visible` is the
    // EFFECTIVE visibility, so this fires when the host hides the popup with
    // the content kept alive (the pin), and reopening lands on the pill, not
    // on an open list over a conversation the reader has not looked at yet.
    onVisibleChanged: if (!root.visible) {
        picker.open = false;
        pdfMenu.open = false;
        grantsMenu.open = false;
        root.completing = false;
    }

    // ======================================================================
    // GEOMETRY
    //
    // implicitWidth stays 0 -- the host gives width. implicitHeight is a sum
    // of eased parts: each target is recomputed instantly from the content and
    // its animated twin chases it, so a keystroke that adds a line moves the
    // whole popup on the shell's one resize easing.
    // ======================================================================
    readonly property real _gap: 6                       // the shell's text->rail gap
    readonly property real _lineH: fm.height
    // A clipping ancestor shears a ShadowBox's bevel, which is drawn OUTSIDE
    // its bounds, so the chip strip keeps this much slack inside its clip.
    readonly property real _chipSlack: 2
    // TWO EASED VALUES, SUMMED -- not one Behavior suppressed while the other
    // runs. The chips appearing and the text growing are different motions
    // that can overlap, and the box's height is their sum, so each keeps its
    // own clock and the total is always continuous.
    readonly property real _chipsTarget: root.attachments && root.attachments.length > 0
        ? root.chipSize + root._chipSlack * 2 + root._gap : 0
    readonly property real _fieldTarget: Math.round(Math.max(root.minLines * root._lineH,
                                     Math.min(root.maxLines * root._lineH, area.contentHeight)))

    // THE THIRD EASED PART: the confirmation's slot -- the panel,
    // the clip's 2 px bevel slack either side, and the gap under it.
    readonly property real _confirmTarget: root.confirming
        ? confirmPanel.implicitHeight + root._chipSlack * 2 + root._gap : 0

    // THE FOURTH: the completion list's slot, on the same
    // mechanics. Its height is LATCHED (see `_completeSlots`), so narrowing
    // the matches re-fills the rows instead of re-easing the box.
    readonly property real _completeTarget: root.completing
        ? completionList.implicitHeight + root._chipSlack * 2 + root._gap : 0

    property real _animConfirmH: root._confirmTarget
    Behavior on _animConfirmH { NumberAnimation { duration: root.resizeMs; easing.type: Easing.OutCubic } }
    property real _animChipsH: root._chipsTarget
    Behavior on _animChipsH { NumberAnimation { duration: root.resizeMs; easing.type: Easing.OutCubic } }
    property real _animFieldH: root._fieldTarget
    Behavior on _animFieldH { NumberAnimation { duration: root.resizeMs; easing.type: Easing.OutCubic } }
    property real _animCompleteH: root._completeTarget
    Behavior on _animCompleteH { NumberAnimation { duration: root.resizeMs; easing.type: Easing.OutCubic } }

    implicitWidth: 0
    // ROUNDED WHERE APPLIED, not in the easing: the eased values
    // stay smooth reals, but every geometry they reach is pinned to the pixel
    // grid. A fractional height under a bottom-anchored composer puts the
    // whole field at fractional y, and text laid out at subpixel offsets
    // shimmers for the entire 260 ms -- the glyphs re-rasterise at each
    // sub-pixel phase. The rounding lives here and on the chip strip's
    // applied height, so the sum and every internal edge move in whole
    // pixels while the motion itself keeps its easing.
    implicitHeight: Math.round(root.padding * 2 + root._animConfirmH + root._animChipsH
                    + root._animCompleteH + root._animFieldH + root._gap + root.buttonSize)

    // The same height WITHOUT the easing: where the box is going, not where it
    // is. A host that advertises its own implicitHeight to a popup engine that
    // eases it must use this one -- feeding an already-eased value to something
    // that eases it again animates twice and the host's easing chases a moving
    // target for the whole 260 ms.
    readonly property real targetHeight: root.padding * 2 + root._confirmTarget + root._chipsTarget
                    + root._completeTarget + root._fieldTarget + root._gap + root.buttonSize

    readonly property bool _hasContent: area.text.trim().length > 0
        || (root.attachments && root.attachments.length > 0)

    FontMetrics {
        id: fm
        font.family: root.bodyFontFamily
        font.pixelSize: root.fontPixelSize
    }

    // ======================================================================
    // THE GROOVE
    // ======================================================================
    ShadowBox {
        id: box
        anchors.fill: parent
        baseRadius: root.radius
        surfaceColor: root.surfaceColor
        backgroundColor: root.fieldColor
        bevelColor: root.bevelColor
        shadowColor: root.shadowColor
        bevelWidth: 1
        shadowWidth: 3
    }

    // ---- The confirmation, pinned to the top edge --------------------------
    // The slot's height is the eased value, the panel inside it is at its
    // full size from the first frame: as the box grows upward the slot's
    // foot reveals the card, and the clip keeps it off the chips and the
    // text meanwhile. Presence fades on the panel's own 160 ms.
    Item {
        id: confirmSlot
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: root.padding
        anchors.rightMargin: root.padding
        anchors.topMargin: root.padding
        height: Math.round(root._animConfirmH)
        clip: true

        LlmConfirmPanel {
            id: confirmPanel
            x: root._chipSlack
            y: root._chipSlack
            width: confirmSlot.width - root._chipSlack * 2
            height: implicitHeight
            request: root.confirmRequest
            maxLines: root.confirmMaxLines
            fontFamily: root.fontFamily
            monoFamily: root.monoFamily
            fontPixelSize: root.fontPixelSize
            codePixelSize: root.fontPixelSize
            radius: root.radius - 4
            overlayItem: root.overlayItem
            scrollSpeed: root.scrollSpeed
            fadeHeight: root.fadeHeight

            surfaceColor: root.fieldColor
            fillColor: root.headerBoxColor
            bevelColor: root.bevelColor
            shadowColor: root.shadowColor
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
            tipSurfaceColor: root.surfaceColor

            onAnswered: (id, decision) => root.confirmAnswered(id, decision)
        }
    }

    // A request landing is the one floating thing on screen: the list, the
    // pdf menu and the wrench menu go. A request leaving hands the focus back
    // to the field, which is editable again the same instant.
    //
    // THE FIELD'S READ-ONLY IS SET HERE, NOT BOUND, and the caret is put back
    // by hand. MEASURED: flipping a TextArea's `readOnly` either way moves
    // its cursor to the END of the text (the caret set at 5 read 27 after
    // `readOnly = true`, on Qt 6.11), which is exactly the "draft and caret
    // untouched" promise broken. So the position -- and a selection, if
    // there was one -- is captured before the flip and restored after it.
    // The requests themselves are read here rather than `confirming`: a
    // handler and a binding on the same property are notified in an order
    // QML does not promise, and reading the derived bool from inside the
    // handler sees the stale value.
    onConfirmRequestChanged: root._panelChanged()
    function _panelChanged() {
        const on = !!root.confirmRequest;
        const pos = area.cursorPosition, ss = area.selectionStart, se = area.selectionEnd;
        area.readOnly = on;
        if (ss !== se)
            area.select(ss, se);
        else
            area.cursorPosition = pos;
        if (on) {
            picker.open = false;
            pdfMenu.open = false;
            grantsMenu.open = false;
            root.completing = false;
        } else if (confirmPanel.holdsFocus) {
            area.forceActiveFocus();
        }
    }

    // ---- Attachment chips, pinned to the top edge -------------------------
    // One left-to-right row of rounded squares, horizontally scrollable when
    // it overflows -- no scroll bar; the flick and the wheel are the whole
    // affordance. The strip's height is the eased value, not the row's own: a
    // chip arriving must push the text down on the same clock the box grows
    // on, and the clip is what keeps the new chip from crossing the text
    // while that is happening.
    Item {
        id: chipStrip
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: confirmSlot.bottom
        anchors.leftMargin: root.padding
        anchors.rightMargin: root.padding
        // Rounded where applied (see implicitHeight): the strip's bottom is
        // the text's top, and the text must sit on the pixel grid.
        height: Math.round(root._animChipsH)
        clip: true

        Flickable {
            id: chipFlick
            anchors.fill: parent
            contentWidth: chipRow.width + root._chipSlack * 2
            contentHeight: height
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.HorizontalFlick
            interactive: contentWidth > width

            Row {
                id: chipRow
                x: root._chipSlack
                y: root._chipSlack
                spacing: root._gap

                Repeater {
                    id: chipRepeater
                    model: root.attachments
                    // Bumped on every delegate change so the menu's chip
                    // lookup re-evaluates (itemAt is not reactive).
                    property int gen: 0
                    onItemAdded: chipRepeater.gen += 1
                    onItemRemoved: chipRepeater.gen += 1

                    LlmAttachmentChip {
                        id: chip
                        required property int index
                        required property var modelData

                        att: chip.modelData
                        removable: true
                        overlayItem: root.overlayItem
                        chipSize: root.chipSize
                        fontFamily: root.fontFamily
                        monoFamily: root.monoFamily
                        nameFontSize: root.chipNameFontSize
                        controlRevealMs: root.chipRevealMs
                        menuOpen: pdfMenu.open && root._pdfMenuIndex === chip.index

                        surfaceColor: root.fieldColor
                        fillColor: root.headerBoxColor
                        bevelColor: root.bevelColor
                        shadowColor: root.shadowColor
                        primaryText: root.primaryText
                        mutedText: root.mutedText
                        faintText: root.faintText
                        accent: root.accent
                        errColor: root.errColor
                        tipSurfaceColor: root.surfaceColor

                        onRemoveRequested: root.attachmentRemoved(chip.index)
                        onMenuRequested: root._openPdfMenu(chip)
                        // THE COMPOSER WRITES THE FLAG, not the chip.
                        // MEASURED: a Repeater hands its delegate a COPY of
                        // the model object, so `chip.att` is not the host's
                        // attachment and a write to it lands nowhere; this
                        // array, a plain `var` property, holds the real
                        // objects (identity preserved -- also measured). One
                        // step from the mark, and the only step that works.
                        onImagesToggled: on => {
                            const a = root.attachments ? root.attachments[chip.index] : null;
                            if (a)
                                a.includeImages = on;
                            root.attachmentImagesToggled(chip.index, on);
                        }
                    }
                }
            }
        }

        // THE WHEEL AND THE EDGE FADES ARE ONE OBJECT. A strip
        // that scrolls must not cut a chip hard at the clip, and it must move
        // the same distance per notch as every other box in the shell; both
        // facts live in ScrollDressing, as a SIBLING of the Flickable (a
        // child is reparented into the content and scrolls away with it).
        // It blends to the groove's own fill -- the ground the chips sit on.
        ScrollDressing {
            objectName: "llmChipDressing"
            flick: chipFlick
            orientation: Qt.Horizontal
            scrollSpeed: root.scrollSpeed
            fadeHeight: root.chipFadeWidth
            ground: root.fieldColor
        }
    }

    // ---- The completion list's slot ---------------------------------------
    // The fourth eased part, on the confirmation's mechanics: the slot's
    // height is the eased value, the list inside is at its latched size from
    // the first frame, and the clip keeps it off the chips and the text while
    // the box grows. It sits between the chips and the prompt because that is
    // the line it is completing.
    Item {
        id: completeSlot
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: chipStrip.bottom
        anchors.leftMargin: root.padding
        anchors.rightMargin: root.padding
        height: Math.round(root._animCompleteH)
        clip: true

        LlmCompletionList {
            id: completionList
            objectName: "llmCompletionList"
            x: root._chipSlack
            y: root._chipSlack
            width: completeSlot.width - root._chipSlack * 2
            height: implicitHeight
            rows: root._decision ? root._decision.rows : []
            dir: root._split && !root._split.pendingSlash ? root._split.dir : ""
            rowSlots: root._completeSlots
            maxRows: root.completionMaxRows
            maxEntries: root.completionMaxEntries
            radius: root.completionRadius
            scrollSpeed: root.scrollSpeed
            fontFamily: root.fontFamily
            monoFamily: root.monoFamily
            fontPixelSize: root.fontPixelSize - 1
            fadeHeight: root.chipFadeWidth

            surfaceColor: root.fieldColor
            fillColor: root.headerBoxColor
            bevelColor: root.bevelColor
            shadowColor: root.shadowColor
            primaryText: root.primaryText
            mutedText: root.mutedText
            faintText: root.faintText
            accent: root.accent

            onChosen: (name, isDir) => root._chooseCompletion(name, isDir)
        }
    }

    // ---- The text, between the completion and the control row --------------
    Flickable {
        id: fieldFlick
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: root.padding
        anchors.rightMargin: root.padding
        anchors.top: completeSlot.bottom
        anchors.bottom: controlRow.top
        anchors.bottomMargin: root._gap
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        // MEASURED, and the reason a new line can fail to appear:
        // QQuickTextEdit builds paint nodes only for the part of its document
        // inside the Flickable's viewport, and it rebuilds them when the
        // DOCUMENT or the SCROLL POSITION changes -- not when the viewport
        // grows. This field's height is eased, so the frame that adds a line
        // lays that line out and never paints it; it appears on the next
        // keystroke. Isolated repro: an eased-height Flickable with a static
        // three-line TextArea painted line 1 only, and one write to contentY
        // painted all three. So every height change writes contentY a hair off
        // and straight back: the scroll position is unchanged (this must not
        // scroll a field the user has scrolled), and the nodes are rebuilt.
        onHeightChanged: {
            const y = fieldFlick.contentY;
            fieldFlick.contentY = y + 0.01;
            fieldFlick.contentY = y;
        }

        // The attached property is what keeps the caret visible once the text
        // is taller than the box; it also drives contentWidth/contentHeight,
        // so nothing here reads the edit's implicitWidth (which would flip
        // QQuickTextEdit into requireImplicitWidth for good).
        TextArea.flickable: TextArea {
            id: area
            Keys.forwardTo: [areaKeys]
            EditKeys {
                id: areaKeys
                target: area
                selectAll: true
            }
            // The field is addressed by name: a tree walk for "the first
            // TextEdit" finds the confirm panel's detail box first.
            objectName: "llmComposerField"
            padding: 0
            // MEASURED: `padding: 0` is not enough. Every Controls
            // style binds `leftPadding: padding + 4` on TextArea (Basic and
            // Fusion alike), and a bound leftPadding outlives the padding it
            // was derived from, so the caret and the typed text would sit 4 px
            // right of the Flickable's edge -- inside the placeholder's "A",
            // which is a sibling at the Flickable's x -- and 4 px right of
            // the control row's first button. The field's one padding is
            // `root.padding`, applied through the Flickable's margins; the
            // edit itself is flush.
            leftPadding: 0
            background: null
            // Read-only while a confirmation stands: the draft and
            // the caret stay exactly where they were, and no keystroke meant
            // for the panel can land in the prompt. Set by the request's
            // handler, not bound -- see onConfirmRequestChanged for why.
            readOnly: false
            wrapMode: TextArea.Wrap
            selectByMouse: true
            color: root.primaryText
            selectionColor: root.accent
            selectedTextColor: root.textOnAccent
            // The body face -- the typed prompt, and nothing else: the
            // placeholder is a sibling Text on the display face (see the API
            // note above), because this font would take it too.
            font.family: root.bodyFontFamily
            font.pixelSize: root.fontPixelSize
            // A BACKTICK IS A ZERO-WIDTH MARK IN EXO 2 (measured: the face's GDEF classes U+0060, the acute, the diaeresis and the
            // circumflex as marks, and HarfBuzz zeroes a mark's advance -- "a`b" lays out as wide as "ab"). Typed into the prompt the
            // backtick is drawn over its neighbour, the caret does not move past it and Backspace seems to do nothing, which reads
            // as broken editing (the notes editor is on Inter, whose backtick is a plain glyph). Without shaping the
            // glyph keeps its own advance (3.77 px at 12 px, Inter's is 3.86). Only while a backtick is in the text, so everything
            // else keeps its kerning.
            font.preferShaping: area.text.indexOf("`") < 0

            // ONE TAB EXTENDS, TWO LIST (readline's own rule).
            // The latch is armed by a Tab that left the answer ambiguous and
            // dropped by ANY edit or caret move -- including the completion's
            // own insert, which is why the arming happens after it.
            onTextChanged: {
                if (root._dictBusy)
                    return;                // a dictation preedit coming or going is not typing
                root._tabArmed = false;
                root._noteText();
            }
            onCursorPositionChanged: root._tabArmed = false

            Keys.onPressed: function (event) {
                // a dictation preedit goes before any key does anything (the key acts on the prompt as typed)
                root._clearDictPreedit();
                // THE PANEL'S KEYS, WHEREVER THE FOCUS IS: a click
                // into the read-only field must not make Return a submit;
                // the panel's one key path answers here too, and anything it
                // does not claim is left to the read-only edit (which types
                // nothing).
                if (root.confirming) {
                    // Tab included: the panel claims it and does nothing
                    // with it, so a request standing has no tab order and the
                    // focus cannot leave it.
                    if (confirmPanel.handleKey(event))
                        event.accepted = true;
                    return;
                }
                // A PATH COMPLETES ON TAB. Accepted whether or not
                // there is anything to complete: an unclaimed Tab types a
                // literal "\t" into the prompt (worthless) and an unclaimed
                // Backtab escapes the field to whatever else is focusable.
                if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                    event.accepted = true;
                    if (event.key === Qt.Key_Tab)
                        root._completeTab();
                    return;
                }
                // BACK AT THE PROMPT = DONE WITH THE LIST. Picking
                // a model does not close the drop-down -- the user compares
                // models in it -- so the moment the question is being written,
                // the list has served its purpose and goes. The event
                // is deliberately NOT accepted here: the keystroke that shuts
                // the list is also the first character of the sentence.
                // (Escape never arrives while the list is open: the picker's
                // window Shortcut takes it, which is what closes the list.)
                if (picker.open)
                    picker.open = false;
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    // Shift+Return is the only newline. Ctrl+Return submits
                    // like a bare Return does, so the habit from every other
                    // chat frontend lands here too.
                    if (event.modifiers & Qt.ShiftModifier)
                        return;
                    root._submit();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Escape) {
                    // The list first: Escape puts away what is on screen
                    // before it puts away the focus.
                    if (root.completing) {
                        root.completing = false;
                        // Put away for this "@" until the word changes: the list opens by itself, so a dismissal has to stay one.
                        root._dismissedAt = root._token ? root._token.start : -1;
                    } else
                        area.focus = false;
                    event.accepted = true;
                }
            }
        }
    }

    // The draft's wheel and its edge fades. A prompt past
    // `maxLines` scrolls inside the box; without this it would scroll on Qt's
    // own style-hint distance (72 px, a desktop setting rather than a number
    // this shell chose) and be cut hard at both edges. Anchored to the Flickable
    // rather than filling this item: it is a SIBLING, so it must be told which
    // rectangle it dresses. The band is clamped to a quarter of the viewport,
    // because 34 px of fade in a three-line field would be the field.
    ScrollDressing {
        objectName: "llmFieldDressing"
        anchors.fill: fieldFlick
        flick: fieldFlick
        scrollSpeed: root.scrollSpeed
        fadeHeight: Math.min(root.fadeHeight, fieldFlick.height / 4)
        ground: root.fieldColor
    }

    // ---- The placeholder, on the DISPLAY face ------------------------------
    // A sibling of the field, not a child of it: the Flickable clips and
    // scrolls its content, and this belongs to neither -- it exists only while
    // the document is empty, which is the one state in which nothing scrolls.
    //
    // ON THE FIRST LINE'S BASELINE, not at the field's top. The two faces have
    // different ascents, so laying both flush at y = 0 would sit the label a
    // fraction of a pixel off the line the first typed character will land on
    // -- the one place the difference is visible, because the label is
    // replaced by that character. `ascent - ascent` puts the two baselines on
    // one y and rounds it, so the text is never laid out at a subpixel offset.
    // (Inter/Exo 2/Audiowide at 12 px differ by ~0.1 px here, i.e. it rounds
    // to 0 today; the arithmetic is what keeps that true at another size.)
    FontMetrics {
        id: phFm
        font.family: root.fontFamily
        font.pixelSize: root.fontPixelSize
    }
    //
    // AT THE PEN ORIGIN, x-wise: the Flickable's edge is where the caret stands
    // (the edit's leftPadding is 0, see above), and the first glyph's own left
    // bearing starts its ink inside the caret's pixel -- exactly what the first
    // typed letter does.
    Text {
        id: placeholderLabel
        x: fieldFlick.x
        y: fieldFlick.y + Math.round(fm.ascent - phFm.ascent)
        width: fieldFlick.width
        // The document is empty AND nothing is being composed: an IME's
        // preedit is text on the line, and a label under it would collide.
        visible: area.length === 0 && area.preeditText.length === 0
        text: root.placeholder
        color: root.faintText
        font.family: root.fontFamily
        font.pixelSize: root.fontPixelSize
        elide: Text.ElideRight
    }

    // ---- The control row, pinned to the bottom edge ------------------------
    Item {
        id: controlRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: root.padding
        anchors.rightMargin: root.padding
        anchors.bottomMargin: root.padding
        height: root.buttonSize

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: root._gap

            RaisedButton {
                width: root.buttonSize
                height: root.buttonSize
                visible: root.allowAttachments
                text: "\uF0C6"
                // A Nerd Font glyph must never render bold: the synthetic
                // emboldening distorts the icon.
                bold: false
                fontFamily: "Symbols Nerd Font"
                fontPixelSize: 13
                minWidth: root.buttonSize
                horizontalPadding: 0
                surfaceColor: root.fieldColor
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
                onClicked: root.attachRequested()
                // A HoverHandler on an item ABOVE the button: its own MouseArea takes hover.
                Item {
                    anchors.fill: parent
                    HoverHandler { id: attachHover }
                }
                HoverTip {
                    show: attachHover.hovered
                    anchorItem: parent
                    overlayItem: root.overlayItem
                    text: "Attach files"
                    fontFamily: root.fontFamily
                    surfaceColor: root.surfaceColor
                    bevelColor: root.bevelColor
                    shadowColor: root.shadowColor
                    textColor: root.primaryText
                }
            }

            // Latched: the plateau stays accent while tools are on, so the
            // state is the button, not a second mark beside it. Faint and
            // inert when the model does not declare tool calling:
            // the latch is kept, the button says why it cannot act.
            Item {
                width: root.buttonSize
                height: root.buttonSize
                visible: root.allowTools

                RaisedButton {
                    id: toolsButton
                    objectName: "llmToolsButton"
                    anchors.fill: parent
                    enabled: root.modelDeclaresTools
                    text: "\uF0AD"
                    accent: root.toolsEnabled
                    bold: false
                    fontFamily: "Symbols Nerd Font"
                    fontPixelSize: 13
                    minWidth: root.buttonSize
                    horizontalPadding: 0
                    surfaceColor: root.fieldColor
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
                        root.toolsEnabled = !root.toolsEnabled;
                        root.toolsToggled(root.toolsEnabled);
                    }
                }
                // Above the button, as its SIBLING (a child would be disabled
                // with it): a right-click for the menu (a left press is not
                // accepted here, so it falls through to the button) and a
                // HoverHandler for the tip -- a handler blocks nothing, and the
                // button's MouseArea, which takes hover, would block a handler
                // beneath it. The menu is reachable even when the button is
                // inert: revoking is never gated on the model.
                Item {
                    anchors.fill: parent
                    HoverHandler { id: wrenchHover }
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.RightButton
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            picker.open = false;
                            pdfMenu.open = false;
                            grantsMenu.open = !grantsMenu.open;
                        }
                    }
                }
            }
        }

        // The right end of the row: which model, then send. One Row, so the
        // pill gives its width back to the gap when the name is short and the
        // send button never moves relative to the box's edge.
        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: root._gap

            LlmModelPicker {
                id: picker
                objectName: "llmModelPicker"
                anchors.verticalCenter: parent.verticalCenter
                pillHeight: root.buttonSize
                models: root.models
                swipeToSwitchBrand: root.swipeToSwitchBrand
                swipePixelToAngle: root.swipePixelToAngle
                notesTipWidth: root.notesTipWidth
                notesTipGap: root.notesTipGap
                resizeMs: root.pickerResizeMs
                stripeMutedSaturation: root.stripeMutedSaturation
                stripeMutedLightnessMix: root.stripeMutedLightnessMix
                defaultStripeFadeMs: root.defaultStripeFadeMs
                stripeSelectFadeMs: root.stripeSelectFadeMs
                showMoeColumn: root.showMoeColumn
                loaded: root.loaded
                busy: root.modelsBusy
                offline: root.modelsOffline
                current: root.currentModel
                service: root.service
                fontFamily: root.fontFamily
                listWidth: root.modelListWidth
                maxListHeight: root.modelListMaxHeight
                capDotSize: root.capDotSize
                capSlotWidth: root.capSlotWidth
                vramBarHeight: root.vramBarHeight
                vramMinStepPx: root.vramMinStepPx
                vramTrackOpacity: root.vramTrackOpacity
                vramCardOpacity: root.vramCardOpacity
                vramSwapMs: root.vramSwapMs
                liveRefreshMs: root.vramLiveRefreshMs
                rowHeight: root.modelRowHeight
                toolProof: root._toolProof
                toolDefinitionTokens: root.toolDefinitionTokens
                toolsOn: root.toolsEnabled
                // The popup's floating layer, straight through: the drop-down
                // must live where clicks are actually delivered.
                overlayItem: root.overlayItem

                // The pill stands on the composer's groove, not on the popup's
                // surface -- it is inside the field.
                surfaceColor: root.fieldColor
                fieldColor: root.fieldColor
                listBoxColor: root.listBoxColor
                headerBoxColor: root.headerBoxColor
                bevelColor: root.bevelColor
                shadowColor: root.shadowColor
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
                capVisionColor: root.capVisionColor
                capToolsColor: root.capToolsColor
                capThinkColor: root.capThinkColor

                onPicked: id => root.modelPicked(id)
            }

            // Send / stop. One button, two jobs: while generating the only
            // thing the user can do to this turn is end it, and a stop that
            // appears somewhere else would leave a dead send button beside it.
            RaisedButton {
                id: sendButton
                anchors.verticalCenter: parent.verticalCenter
                width: root.buttonSize
                height: root.buttonSize
                text: root.generating ? "\uF04D" : "\uF1D8"
                accent: !root.generating
                enabled: root.generating || root._hasContent
                bold: false
                fontFamily: "Symbols Nerd Font"
                fontPixelSize: 13
                minWidth: root.buttonSize
                horizontalPadding: 0
                surfaceColor: root.fieldColor
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
                onClicked: root.generating ? root.stopRequested() : root._submit()
                // A HoverHandler on an item ABOVE the button: its own MouseArea takes hover.
                Item {
                    anchors.fill: parent
                    HoverHandler { id: sendHover }
                }
                HoverTip {
                    show: sendHover.hovered && sendButton.enabled
                    anchorItem: sendButton
                    overlayItem: root.overlayItem
                    text: !root.generating ? "Send"
                          : root.queueEnabled && root._hasContent
                          ? "Stop the answer -- Return queues this message for when it is done"
                          : "Stop the answer"
                    fontFamily: root.fontFamily
                    surfaceColor: root.surfaceColor
                    bevelColor: root.bevelColor
                    shadowColor: root.shadowColor
                    textColor: root.primaryText
                }
            }
        }
    }

    // ======================================================================
    // PATH COMPLETION
    //
    // A word starting with "@" is a path being typed. Everything decidable
    // from strings is in LlmPathComplete.js; the one directory listing is
    // LlmPathCompleter's; what is left here is the gesture: which directory to ask for, when to edit the document,
    // and when the list stands.
    //
    // THE DIRECTORY IS A BINDING, THE EDIT IS NOT. `_token` -> `_split` ->
    // `_wantDir` follow the text and the caret, so at most one scan is asked
    // for per directory typed and the answer is already in hand when Tab is
    // pressed; `_decision` re-filters that cached array on every keystroke
    // (0.5 ms over five thousand names, measured). Nothing is written into
    // the document except by a Tab or a click.
    // ======================================================================
    LlmPathCompleter { id: completer }

    readonly property var _token: Complete.tokenAt(area.text, area.cursorPosition)
    readonly property var _split: root._token ? Complete.split(root._token.body, completer.home) : null
    readonly property string _wantDir: root._split && !root._split.pendingSlash ? String(root._split.dir) : ""
    // The one side effect, in a handler rather than in a binding: asking for
    // a directory. No token means the completion is over -- the listings go
    // with it, so the next "@" reads the filesystem as it is then.
    on_WantDirChanged: {
        if (root._wantDir.length === 0)
            completer.reset();
        else
            completer.dir = root._wantDir;
    }
    // "one" | "extend" | "list" | "none" from the library, plus the two
    // states only this side knows: "slash" (a bare "~", which bash answers by
    // typing the "/" for you) and "loading" (the scan has not landed yet --
    // Tab does nothing rather than answering from the wrong directory).
    readonly property var _decision: {
        if (!root._split)
            return null;
        if (root._split.pendingSlash)
            return { state: "slash", insert: "/", rows: [] };
        // A directory that is not there completes nothing, and says so at
        // once: "loading" is a state Tab WAITS in, and nothing may wait for
        // an answer that is not coming.
        if (completer.status === "nodir")
            return { state: "none", insert: "", rows: [] };
        if (completer.status !== "ready" || completer.dir !== root._wantDir)
            return { state: "loading", insert: "", rows: [] };
        return Complete.decide(completer.entries, root._split.prefix);
    }
    property bool _tabArmed: false
    // The list's height in rows, latched by the Tab that opened it -- a
    // reserved slot keeps its height while the matches narrow.
    property int _completeSlots: 0

    // The token going away, or the matches going with it, takes the list
    // down; narrowing to one match leaves it standing on that one row until
    // the next Tab completes it.
    on_DecisionChanged: {
        if (root.completing && (!root._decision || root._decision.rows.length === 0)) {
            root.completing = false;
            return;
        }
        root._autoOpen();
    }

    // THE LIST OPENS BY ITSELF, right away: as soon as the word the caret is in is an "@" path whose
    // directory can be read and holds something that matches, the matches are on screen -- no Tab, no second Tab. It keeps the keyboard in
    // the prompt, narrows as the word grows (fuzzily: LlmPathComplete) and goes with the word. Escape puts it away for that
    // "@" (`_dismissedAt`); a new "@" asks again. Not while a confirmation stands, nor in a prompt that is not being typed in.
    property int _dismissedAt: -1
    on_TokenChanged: {
        if (!root._token)
            root._dismissedAt = -1;
    }
    function _autoOpen() {
        const d = root._decision, t = root._token;
        if (!t || !d || d.rows.length === 0 || root.confirming || !root.visible || !area.activeFocus)
            return;
        if (root.completing) {
            // More matches than the list was opened for (a letter taken back): the reserved height grows, never shrinks.
            root._completeSlots = Math.max(root._completeSlots, completionList.neededRows);
            return;
        }
        if (root._dismissedAt === t.start)
            return;
        root._openCompletion();
    }

    // THE FIRST PATH WRITTEN TURNS THE TOOLS ON: the model cannot do anything with a path if tool calling is disabled, even for just
    // reading files. Once per draft: a wrench the user turns off again stays off until the draft is empty. Text that arrives without the field
    // being typed in (a restored draft, an edit) only records whether there is a path in it already.
    //
    // AND BACK OFF WHEN THE LAST PATH LEAVES THE DRAFT, for a writer who changes their mind and deletes the file reference before
    // sending. `_autoTools` remembers that the composer, and nobody else, turned the
    // tools on; the wrench's own click, the Tools tab and the host all end it (any write to `toolsEnabled` that is not ours), and so
    // does sending, a restored draft and any text that arrives unfocused -- so a toggle that was the user's is never undone.
    property bool _pathToolsDone: false
    property bool _autoTools: false
    property bool _autoWrite: false
    onToolsEnabledChanged: {
        if (!root._autoWrite)
            root._autoTools = false;
    }
    function _autoSetTools(on) {
        root._autoWrite = true;
        root.toolsEnabled = on;
        root._autoWrite = false;
        root._autoTools = on;
        root.toolsToggled(on);
    }
    function _noteText() {
        const t = area.text;
        if (!area.activeFocus || root._arriving) {
            root._autoTools = false;
            root._pathToolsDone = t.length > 0 && Complete.hasPathRef(t);
            return;
        }
        const has = t.length > 0 && Complete.hasPathRef(t);
        if (!has) {
            root._pathToolsDone = false;
            if (root._autoTools && root.toolsEnabled && !root.confirming)
                root._autoSetTools(false);
            else
                root._autoTools = false;
            return;
        }
        if (root._pathToolsDone)
            return;
        root._pathToolsDone = true;
        if (root.allowTools && !root.toolsEnabled && !root.confirming)
            root._autoSetTools(true);
    }

    function _insertCompletion(t) {
        if (!t || t.length === 0)
            return;
        area.insert(area.cursorPosition, t);
    }
    function _openCompletion() {
        // One floating thing at a time, and the list is now the one.
        picker.open = false;
        pdfMenu.open = false;
        grantsMenu.open = false;
        root._completeSlots = completionList.neededRows;
        root.completing = true;
    }
    function _completeTab() {
        const d = root._decision;
        if (!d)
            return;
        if (d.state === "loading")
            return;
        if (d.state === "none") {
            root._tabArmed = false;
            return;
        }
        if (d.state === "slash" || d.state === "one") {
            // A fuzzy match is not the typed letters' continuation: they are taken back and the whole name goes in.
            if (d.replace > 0)
                area.remove(area.cursorPosition - d.replace, area.cursorPosition);
            root._insertCompletion(d.insert);
            root._tabArmed = false;
            root.completing = false;
            return;
        }
        if (d.state === "extend") {
            root._insertCompletion(d.insert);
            // Still ambiguous: the next Tab is the one that lists.
            root._tabArmed = true;
            return;
        }
        if (root._tabArmed || root.completing)
            root._openCompletion();
        else
            root._tabArmed = true;
    }
    function _chooseCompletion(name, isDir) {
        if (!root._token || !root._split || root._split.pendingSlash)
            return;
        // What is typed of the last segment (as it stands in the text, escapes and all) gives way to the whole name: the match
        // need not begin with it any more.
        const b = String(root._token.body);
        const typed = b.length - (b.lastIndexOf("/") + 1);
        if (typed > 0)
            area.remove(area.cursorPosition - typed, area.cursorPosition);
        root._insertCompletion(Complete.escapePath(String(name)) + (isDir ? "/" : " "));
        root.completing = false;
        root._tabArmed = false;
        area.forceActiveFocus();
    }

    // ======================================================================
    // THE PDF MENU
    //
    // One menu for every chip, opened on the chip whose glyph was
    // right-clicked. It tracks its attachment by PATH: the host swaps the
    // array on every resolve and a re-extract answers with a fresh object, so
    // an index or an identity would both go stale under an open menu, while
    // the path is the loader's own key. The chip leaving (its path gone from
    // the array) closes it; so does the composer being put away.
    // ======================================================================
    property string _pdfMenuPath: ""
    readonly property int _pdfMenuIndex: {
        const atts = root.attachments || [];
        if (root._pdfMenuPath.length === 0)
            return -1;
        for (let i = 0; i < atts.length; ++i)
            if (atts[i] && String(atts[i].path) === root._pdfMenuPath)
                return i;
        return -1;
    }
    // The delegate currently drawing that attachment -- a NEW item after
    // every array swap, hence the Repeater's generation counter in the
    // dependency list.
    readonly property LlmAttachmentChip _pdfMenuChip: {
        const gen = chipRepeater.gen;
        return root._pdfMenuIndex >= 0 ? (chipRepeater.itemAt(root._pdfMenuIndex) as LlmAttachmentChip) : null;
    }
    on_PdfMenuIndexChanged: if (root._pdfMenuIndex < 0) pdfMenu.open = false
    function _openPdfMenu(chip) {
        root._pdfMenuPath = String(chip.modelData && chip.modelData.path ? chip.modelData.path : "");
        pdfMenu.open = root._pdfMenuIndex >= 0;
    }

    // The attachment the menu edits: the host's REAL object (this array holds
    // the identities the loader matches on), never the delegate's copy.
    readonly property var _pdfMenuAtt: {
        const atts = root.attachments || [];
        return root._pdfMenuIndex >= 0 ? atts[root._pdfMenuIndex] : null;
    }

    LlmPdfMenu {
        id: pdfMenu
        anchorItem: root._pdfMenuChip
        overlayItem: root.overlayItem
        att: root._pdfMenuAtt
        mode: root.pdfImageMode
        imageCap: root.pdfImageCap
        imageMinArea: root.pdfImageMinArea
        pageCap: root.pdfPageCap
        facts: root._pdfMenuChip ? root._pdfMenuChip.pdfFactFigures : ({})
        advancedLines: root._pdfMenuChip ? root._pdfMenuChip.pdfFactsAdvanced : []
        imageCapMax: root.pdfImageCapMax
        imageMinAreaMax: root.pdfImageMinAreaMax
        imageMinAreaStep: root.pdfImageMinAreaStep
        pageCapMax: root.pdfPageCapMax
        menuWidth: root.pdfMenuWidth
        sliderScale: root.pdfMenuSliderScale
        settleMs: root.pdfMenuSettleMs
        fontFamily: root.fontFamily
        // It floats over the transcript's container, like the model list.
        surfaceColor: root.listBoxColor
        fieldColor: root.fieldColor
        grooveColor: root.headerBoxColor
        bevelColor: root.bevelColor
        shadowColor: root.shadowColor
        primaryText: root.primaryText
        mutedText: root.mutedText
        faintText: root.faintText
        accent: root.accent
        tipSurfaceColor: root.surfaceColor
        onSettingChanged: (key, value) => {
            if (root._pdfMenuIndex >= 0)
                root.pdfSettingChanged(root._pdfMenuIndex, key, value);
        }
    }

    // ======================================================================
    // THE WRENCH MENU AND TIP
    // ======================================================================
    LlmGrantsMenu {
        id: grantsMenu
        objectName: "llmGrantsMenu"
        anchorItem: toolsButton
        overlayItem: root.overlayItem
        grants: root.grants
        errors: root.toolErrors
        menuWidth: root.grantsMenuWidth
        maxHeight: root.grantsMenuMaxHeight
        scrollSpeed: root.scrollSpeed
        fontFamily: root.fontFamily
        surfaceColor: root.listBoxColor
        fieldColor: root.fieldColor
        bevelColor: root.bevelColor
        shadowColor: root.shadowColor
        primaryText: root.primaryText
        mutedText: root.mutedText
        faintText: root.faintText
        accent: root.accent
        tipSurfaceColor: root.surfaceColor
        onRevoked: (tool, key) => root.grantRevoked(tool, key)
        onRevokeAll: root.allGrantsRevoked()
    }

    // THE LISTING, grouped by what the policy does with each tool. One
    // source: the tip reads it, and nothing else re-words it.
    readonly property var _toolGroups: {
        const free = [], ask = [], off = [];
        const o = root.toolsOffered || [];
        for (let i = 0; i < o.length; i++) {
            const t = o[i];
            if (!t)
                continue;
            const name = String(t.name || "");
            // A host that does not carry labels yet still reads as language.
            const label = String(t.label || name.replace(/_/g, " "));
            const fa = Math.max(0, Number(t.freeActions) || 0);
            const aa = Math.max(0, Number(t.askActions) || 0);
            if (t.enabled === false) {
                off.push(label);
            } else if (fa > 0 && aa > 0) {
                const tot = fa + aa;
                free.push(label + " (" + fa + " of " + tot + ")");
                ask.push(label + " (" + aa + " of " + tot + ")");
            } else if (fa + aa > 1) {
                (fa > 0 ? free : ask).push(label + " (" + (fa + aa) + " actions)");
            } else {
                (String(t.kind) === "read" ? free : ask).push(label);
            }
        }
        return { free: free, ask: ask, off: off };
    }
    readonly property int _grantCount: root.grants ? root.grants.length : 0
    readonly property string _toolStateWord: root.toolProbeState === "proven"
        ? "proven " + (root.toolProbeMs > 0 ? (root.toolProbeMs / 1000).toFixed(1) + " s" : "")
        : root.toolProbeState === "failed" ? "declared, failed the probe"
        : "declared, unmeasured"
    FontMetrics {
        id: tipFm
        font.family: root.fontFamily
        font.pixelSize: 10
    }
    // The state slot: the widest phrase it can hold, so the bubble is one
    // width in every state.
    readonly property real _toolStateSlotW: Math.ceil(Math.max(
        tipFm.advanceWidth("declared, failed the probe"),
        tipFm.advanceWidth("declared, unmeasured"),
        tipFm.advanceWidth("proven 00.0 s")))
    // The latch is in the first word, so the verdict keeps its column
    // whether tools are on for the next message or not.
    readonly property real _tipHeadSlotW: Math.ceil(Math.max(
        tipFm.advanceWidth("tools · "),
        tipFm.advanceWidth("tools off · ")))
    readonly property real _tipWordSlotW: 8 + Math.ceil(Math.max(
        tipFm.advanceWidth("runs free"),
        tipFm.advanceWidth("asks first"),
        tipFm.advanceWidth("off")))

    // One group of the listing: the word in its slot, the labels wrapped
    // beside it, so all three lists start on one column.
    component WrenchTipGroup: Row {
        id: grp
        property string word: ""
        property var items: []
        spacing: 0
        visible: grp.items.length > 0
        Text {
            width: root._tipWordSlotW
            text: grp.word
            color: root.mutedText
            font.family: root.fontFamily
            font.pixelSize: 10
        }
        Text {
            width: Math.max(40, root.wrenchTipWidth - root._tipWordSlotW)
            // Separated by "·", not by a comma: a label may HAVE a comma in
            // it ("Hyprland: windows, workspaces, monitors"), and a
            // comma-joined list of those reads as one long sentence with no
            // boundaries. The middot is this module's own separator.
            text: grp.items.join(" · ")
            color: root.primaryText
            font.family: root.fontFamily
            font.pixelSize: 10
            wrapMode: Text.Wrap
        }
    }

    HoverTip {
        show: wrenchHover.hovered && root.allowTools && !grantsMenu.open
        anchorItem: toolsButton
        overlayItem: root.overlayItem
        fontFamily: root.fontFamily
        surfaceColor: root.surfaceColor
        bevelColor: root.bevelColor
        shadowColor: root.shadowColor
        textColor: root.primaryText
        text: root.modelDeclaresTools ? "" : root.currentModel + " does not declare tool calling"
        contentComponent: root.modelDeclaresTools ? wrenchTipBody : null
    }
    Component {
        id: wrenchTipBody
        Column {
            spacing: 2
            Row {
                spacing: 0
                Text {
                    width: root._tipHeadSlotW
                    text: root.toolsEnabled ? "tools · " : "tools off · "
                    color: root.primaryText
                    font.family: root.fontFamily
                    font.pixelSize: 10
                }
                Text {
                    width: root._toolStateSlotW
                    text: root._toolStateWord
                    color: root.primaryText
                    font.family: root.fontFamily
                    font.pixelSize: 10
                }
            }
            WrenchTipGroup { word: "runs free";  items: root._toolGroups.free }
            WrenchTipGroup { word: "asks first"; items: root._toolGroups.ask }
            WrenchTipGroup { word: "off";        items: root._toolGroups.off }
            Text {
                text: root._grantCount + (root._grantCount === 1 ? " allowance" : " allowances")
                      + " · right-click to see and revoke"
                color: root.mutedText
                font.family: root.fontFamily
                font.pixelSize: 10
            }
        }
    }

    // ---- The picker's tools dot: the probe verdicts by model ---------------
    // A snapshot of `service.toolProbeInfo(id)` for every listed model,
    // rebuilt on every `toolProbeChanged`, on the list changing and on the
    // service arriving (the ctxInfo pattern: the function is the fact, the
    // signal says "ask again"). A service without the API leaves the map
    // empty, and the picker draws the declared ring for every claim.
    property var _toolProof: ({})
    function _refreshToolProof() {
        const svc = root.service;
        const out = {};
        if (svc && typeof svc.toolProbeInfo === "function") {
            const ms = root.models || [];
            for (let i = 0; i < ms.length; i++) {
                const id = ms[i] && ms[i].id ? String(ms[i].id) : "";
                if (id.length > 0)
                    out[id] = svc.toolProbeInfo(id);
            }
        }
        root._toolProof = out;
    }
    onServiceChanged: root._refreshToolProof()
    onModelsChanged: root._refreshToolProof()
    Component.onCompleted: root._refreshToolProof()
    Connections {
        target: root.service
        ignoreUnknownSignals: true
        function onToolProbeChanged(model) { root._refreshToolProof(); }
    }

    // ======================================================================
    // INTERNAL
    // ======================================================================
    function _submit() {
        if (!root.enabled || (root.generating && (!root.queueEnabled || root.confirming)))
            return;
        const t = area.text.trim();
        const atts = root.attachments || [];
        // Nothing to say and nothing attached: silently do nothing rather
        // than post an empty turn the model would have to answer.
        if (t.length === 0 && atts.length === 0)
            return;
        root.completing = false;
        // The tools stay on for the message that asked for them.
        root._autoTools = false;
        root.submitted(t, atts);
    }
}
