pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "../../../common/theme"
import "../../../common/components"
import "../../../common/components/Markdown.js" as Md
import "../../../common/components/Mix.js" as Mix

// =============================================================================
// LlmToolBlock.qml
//
// One tool call as a SENTENCE in the conversation, folded. A read tool is
// forgettable: one collapsed line in the answer's own voice ("search ~/notes
// for "NONCE"  ·  done  0.4 s"), a chevron at its end, nothing else. An act
// that was refused, denied or failed arrives OPEN, because its reason must be
// legible without a click. Everything the model was told is in here, verbatim
// -- the arguments as they ran and the result as it was received, trailer
// included -- and nothing that is not in the stored entry is ever shown.
//
// THE ONE COLOURED FACT LIVES IN THE INSET SHADOW. The block is a carved
// ShadowBox on the header-box fill, and its inset carries the turn's own
// vocabulary: plain while queued or done; the accent as a travelling BAND
// while the call is asking or running; the error colour STATIC and over the
// WHOLE inset when the call DID NOT DELIVER -- failed, timed out, killed,
// refused, invalid or repeated. Full extent, not the idle mark: the mark is
// what a queued call shows, so a failure drawn at the mark would be the same
// sliver as "nothing has happened yet" (measured: 26 px of red on a 716 px
// box). It is the recipe the turn header parks for a failed turn --
// progress 1, tail 0. No stripe, no
// badge, no coloured status word: a failure is the inset, the same fact
// painted once.
//
// A DENIAL IS NOT A FAILURE. `denied` and `cancelled` are the user's own
// decisions and take no red at all -- the block says so in words ("denied",
// "you declined") and arrives OPEN so the reason is legible without a click.
// Painting a denial in the error colour teaches the user to read their own
// answer as a fault, and it costs the red its one meaning. The turn's
// `_toolFailedStatus` lists them, because THAT question is "which
// blocks arrive open", which is a different question.
//
// AND THE INSET'S STATE ONLY EVER CHANGES AT ZERO INK. Band, red and plain
// are three drawings of one edge, and swapping between two of them is a cut
// wherever the old one was painting: a call turning `done` would take 395 px of
// colour off in a single frame. So every swap is wrapped in a presence fade
// -- `_tintF` out over `fadeMs`, the geometry swapped on the frame where
// nothing is painted, then back in. One fraction, mixed with Mix.js, never a
// Behavior on a colour. It is this file's own clock and not the turn's,
// because a call finishes while the turn is still generating.
//
// THE BAND IS THE TURN'S, NOT THIS FILE'S. Both edges arrive as fractions --
// `sweep` is the leading one, `sweepTail` the trailing one -- computed once
// per turn from one linear clock (LlmTurn's `_wait`, shaped by Sweep.js), so
// the header two centimetres above and every block under it are the same band
// at the same instant and this file adds no animation of its own. It is not
// a FILL: one that reached the right end and was cut back to the idle mark would
// jump 420 px in one frame, once every loop, and a model reports no
// progress, so there is nothing for a fill to mean; the cut reads
// as "it started again".
//
// THE HANDLE is a fixed-height line (figureSize + 10): glyph, the registry's
// `summary` in the shell's face (present tense -- the STATUS WORD carries the
// tense), and at the right end, in fixed slots, the status word, the time and
// the chevron. The chevron is pinned to the right edge, the time sits in a
// slot measured from "88.8 s", the status word right-aligns against the
// slot, and the summary elides into what is left -- so a status flipping
// from `running…` to `done` moves nothing that is not the word itself.
// Under a grant the word is `done · by rule git status …`, and the rule is a
// LINK (its own hover fade, the hand, a tip) that forgets that rule. Hover on
// the handle is one eased fraction mixing faint to accent on the glyph and
// every word together -- Mix.js, never a colour Behavior -- and the whole
// line toggles.
//
// THE OPEN BODY is the thinking drawer's mechanism verbatim: one eased
// `_tExtent`, a clip, a SeamFade at the moving edge, `expandMs`. The clip
// carries TWO PX OF BEVEL SLACK at its top edge, and it has to: the
// arguments box's top edge IS that edge, a ShadowBox draws its bevel OUTSIDE
// its own bounds, and a clip on that line shears it off -- which would leave the
// first box of every open block with no top at all, while the result box
// below it keeps its own. LlmComposer's `_chipSlack` is the same allowance,
// and LlmTurn states the law twice. In it: the
// arguments in a CodeBlock (labelled by the tool's name; `lang: "sh"` for
// run_command so the highlighter colours the command; its copy button copies
// the arguments); the result in a second CodeBlock (labelled "result"; the
// first `maxLines` lines and then a muted "… 312 more lines" that expands in
// place -- a DISPLAY fold, the stored result is already capped; the trailer
// line stays the box's last line; its copy button copies the WHOLE stored
// result); a screenshot entry shows its picture instead, thumb-sized with the
// full picture in the tip; then a figures line in fixed slots and a muted
// decision line only when it says something ("you allowed this once",
// "allowed by git status … · revoke", "you declined" -- nothing for a free
// read).
//
// THE TEXT-RENDERING LAW HOLDS HERE. Both boxes are built once from the
// stored entry: the strings they show are derived from `entry`, and a status
// patch that leaves `argsText` and `result` unchanged changes no string, so
// no document is rebuilt. The running state has no body to build. The block
// itself is built when its id first appears and is never re-created for a
// status change -- that is the turn's id-synced model, not this file, but it
// is what this file is designed to sit in.
//
// AN ACTIVITY LINE. With `activity` set the block is not a call:
// it is the turn's "what the model is doing" line (LlmTurn's foot) --
// the same handle, box and band, the sentence where a call's summary goes,
// `activityNote` in the status slot, `activityFigure` in the time slot, the
// chevron's slot kept (invisible) so the time sits where a real block's
// does. It does not open, and so it has no hand and no hover fade: nothing
// announces an affordance that is not there.
//
// Ctrl+Shift+C with the focus inside this block copies the entry as a fenced
// JSON block (the two picture fields left out -- a screenshot is not text).
// Every colour is a property with a Theme default; the host passes its own.
// =============================================================================
Item {
    id: root

    // Device px per design px here (the nearest ScaleRoot's, else the window's).
    DeviceScale {
        id: dev
    }

    // ---- The entry, the fold, the clock ---------------
    property var    entry: null
    property bool   expanded: false
    // The activity line (see the header); "" for every real call.
    property string activity: ""
    property string activityGlyph: ""
    property string activityFigure: ""
    property string activityNote: ""
    property string activityTip: ""
    // The band's two edges, 0..1, from the turn. `sweepTail` negative is no
// band at all, and is what a parked
    // or failed block passes.
    property real   sweep: 0
    property real   sweepTail: -1
    // "call 1 of 2", for the handle's tip. The block cannot count its round's
    // siblings; the turn can, and hands it down.
    property string callLabel: ""
    property Item   overlayItem: null

    // ---- Type and measure -------------------------------------------------
    property string fontFamily: "Inter"
    property string monoFamily: "Consolas"
    property int    figureSize: 10
    property int    codePixelSize: 12
    property int    maxLines: 40

    // ---- Geometry (the turn's numbers, handed down) ----------------------
    property real   boxRadius: 10
    property real   padding: 10          // the box's inner padding, left/right/bottom
    property real   bodyGap: 6           // between the body's boxes
    property real   drawerInset: 10      // (kept for the host's uniform pass-through)
    property real   codePadding: 10
    property real   codeHeaderHeight: 26
    property real   imageInset: 6
    property real   thumbSize: 64
    property real   seamFadeHeight: 42
    property int    expandMs: 260
    property int    fadeMs: 160
    // The inset's idle mark and its feathers -- the header's own numbers, so
    // a parked block and a parked header are the same mark.
    property real   sweepIdleWidth: 12
    property real   sweepIdleFeather: 1.5
    property real   sweepActiveFeather: 12

    // ---- Palette ------------------------------------------------------------
    property color surfaceColor: Theme.listBox        // the ground the box is carved into
    property color headerBoxColor: Theme.headerBox    // the box's own fill
    property color bevelColor: Theme.bevel
    property color borderColor: Theme.border
    property color primaryText: Theme.textPrimary
    property color mutedText: Theme.textMuted
    property color faintText: Theme.textFaint
    property color accent: Theme.accent
    property color accentHover: Theme.accentHover
    property color errColor: Theme.error
    property color codeBgColor: Theme.terminalBg
    property color selectionColor: Theme.terminalSelection
    property color selectionTextColor: Theme.terminalSelectionText
    property color buttonPlateau: Theme.buttonPlateau
    property color buttonPlateauHover: Theme.buttonPlateauHover
    property color buttonBevel: Theme.buttonBevel
    property color buttonShadow: Theme.buttonShadow

    signal toggled()
    signal revokeRequested(string tool, string key)

    // ---- Derived, all from the entry --------------------------------------
    readonly property var    _e: root.entry || ({})
    readonly property string _status: String(root._e.status || "queued")
    readonly property string _decision: String(root._e.decision || "")
    readonly property string _name: String(root._e.name || "")
    readonly property string _action: String(root._e.action || "")
    readonly property bool   _isActivity: root.activity.length > 0
    readonly property string _summary: root._isActivity ? root.activity : String(root._e.summary || root._name)
    readonly property string _argsText: String(root._e.argsText || "")
    readonly property string _result: String(root._e.result || "")
    readonly property string _thumb: String(root._e.thumbB64 || "")
    readonly property string _image: String(root._e.image || "")
    readonly property bool   _isImage: root._thumb.length > 0
    readonly property bool   _isRunCommand: root._name === "run_command"
    readonly property bool   _active: root._isActivity || root._status === "asking" || root._status === "running"
    // The call did not deliver, and not by the user's hand: the inset's red.
    // `denied` and `cancelled` are deliberately NOT in here -- see the header
    // comment -- although the turn's `_toolFailedStatus` does list them,
    // because that decides which blocks arrive OPEN.
    readonly property bool   _errored: root._status === "failed"
        || root._status === "timedOut" || root._status === "flood" || root._status === "refused"
        || root._status === "invalid" || root._status === "repeated"
    // Ran under a rule, existing or created by this call's Always.
    readonly property bool   _underRule: (root._decision === "granted" || root._decision === "always")
        && root._e.grantKeys !== undefined && root._e.grantKeys !== null
        && root._e.grantKeys.length > 0
    readonly property string _ruleLabel: String(root._e.grantLabel || "")
    readonly property bool   _ran: root._status === "done" || root._status === "failed"
        || root._status === "timedOut" || root._status === "flood" || root._status === "cancelled"

    readonly property string _statusWord: {
        if (root._isActivity)
            return root.activityNote;
        switch (root._status) {
        case "queued":    return "queued";
        case "asking":    return "asking";
        case "running":   return "running…";
        case "done":      return root._underRule ? "done · by rule " : "done";
        case "denied":    return "denied";
        case "failed":    return "failed · exit " + (root._e.exitCode !== undefined ? root._e.exitCode : "?");
        case "timedOut":  return "timed out";
        case "flood":     return "killed";
        case "cancelled": return "cancelled";
        case "refused":   return "refused";
        case "invalid":   return "invalid call";
        case "repeated":  return "repeated";
        }
        return root._status;
    }
    // One decimal, the em dash while there is no time yet. The slot it sits
    // in is measured from "88.8 s" below, so a figure never moves its
    // neighbours.
    readonly property string _timeText: root._isActivity ? root.activityFigure
        : root._ran && root._e.ms > 0 ? (root._e.ms / 1000).toFixed(1) + " s" : "—"

    // Thousands grouped with a thin space.
    function _group(n) {
        const s = String(Math.max(0, Math.round(n)));
        let out = "";
        for (let i = 0; i < s.length; ++i) {
            if (i > 0 && (s.length - i) % 3 === 0)
                out += " ";
            out += s[i];
        }
        return out;
    }
    readonly property string _figures: {
        if (!root._ran)
            return "";
        const parts = [];
        if (root._e.exitCode !== undefined)
            parts.push("exit " + root._e.exitCode);
        const b = root._e.bytes || 0;
        if (root._e.truncated) {
            const kept = (root._e.keptHead || 0) + (root._e.keptTail || 0);
            parts.push(root._group(b) + " B produced · " + root._group(kept) + " B kept");
        } else {
            parts.push(root._group(b) + " B of " + root._group(b) + " B");
        }
        if (root._e.ms > 0)
            parts.push((root._e.ms / 1000).toFixed(1) + " s");
        return parts.join("  ·  ");
    }
    // Only when it carries information: a free read says nothing here.
    readonly property string _decisionText: {
        switch (root._decision) {
        case "yes":     return "you allowed this once";
        case "no":      return "you declined";
        case "auto":    return "read-only, ran without asking";
        case "granted":
        case "always":  return root._underRule ? "allowed by " + root._ruleLabel : "";
        }
        return "";
    }

    // ---- The result's display fold --------------------------------------
    // The stored result is already capped; this is a fold of what is
    // on screen. The trailer -- the result's last line -- stays the box's
    // last line, so the count of hidden lines is honest about what sits
    // between the head and it.
    property bool _resultAll: false
    readonly property var _resultLines: root._result.length > 0 ? root._result.split("\n") : []
    readonly property int _hiddenLines: !root._resultAll && root._resultLines.length > root.maxLines + 1
        ? root._resultLines.length - root.maxLines - 1 : 0
    readonly property string _resultShown: root._hiddenLines > 0
        ? root._resultLines.slice(0, root.maxLines).join("\n") + "\n"
          + root._resultLines[root._resultLines.length - 1]
        : root._result

    // ---- Copy the entry as a fenced JSON block ----------------------------
    function copyEntry() {
        const o = {};
        for (const k in root._e) {
            if (k === "image" || k === "thumbB64")
                continue;
            o[k] = root._e[k];
        }
        Quickshell.clipboardText = "```json\n" + JSON.stringify(o, null, 2) + "\n```";
    }
    Keys.onPressed: (e) => {
        if ((e.modifiers & Qt.ControlModifier) && (e.modifiers & Qt.ShiftModifier)
                && e.key === Qt.Key_C) {
            root.copyEntry();
            e.accepted = true;
        }
    }

    // ---- The fold: one eased fraction ------------------------------------
    property real _tExtent: root.expanded ? 1 : 0
    Behavior on _tExtent {
        NumberAnimation { duration: root.expandMs; easing.type: Easing.OutCubic }
    }
    readonly property real handleHeight: root.figureSize + 10
    // The bevel band the body's clip has to leave room for at its TOP edge:
    // ShadowBox's own `_margin`, i.e. a 1 px bevel plus a pixel of
    // antialiasing. The clip's top edge moves UP by it and the column inside
    // moves DOWN by it, so every child stays exactly where it was, this
    // height is unchanged, and the bevel is drawn at EVERY extent instead of
    // popping in on the last frame of the open.
    readonly property real _bevelSlack: 2
    // The body's own height. NOT `bodyClip.height`, which carries the slack:
    // the slack is drawing room, not a taller block.
    readonly property real _bodyH: (bodyCol.implicitHeight + root.padding) * root._tExtent
    implicitHeight: root.handleHeight + root._bodyH

    // ---- The inset's state, and the fade that swaps it -------------------
    //
    // `_parked` is what the ShadowBox draws from -- the turn's band while it
    // is false, red or plain while it is true -- and it changes ONLY inside
    // `swapAnim`, on the frame where `_tintF` is 0 and the inset paints
    // nothing. Both directions go through it: a call that starts mid-trip
    // would otherwise arrive with the turn's band already at its current
    // phase, whole, in one frame, and a call that ends takes its band off in
    // one frame. See the header comment.
    property bool _parked: true
    property real _tintF: 1
    on_ActiveChanged: swapAnim.restart()
    // A block born ACTIVE -- the turn's activity line, created when it is
    // shown -- starts in the band; there is no change to fade it in on.
    Component.onCompleted: if (root._active) root._parked = false
    SequentialAnimation {
        id: swapAnim
        NumberAnimation {
            target: root; property: "_tintF"; to: 0
            duration: root.fadeMs; easing.type: Easing.OutCubic
        }
        // The invisible swap. `_active` is read HERE and not latched at the
        // start, so a status that flips twice during the fade still lands on
        // the truth.
        ScriptAction { script: root._parked = !root._active }
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

    // ---- Material -----------------------------------------------------------
    ShadowBox {
        id: material
        anchors.fill: parent
        baseRadius: root.boxRadius
        surfaceColor: root.surfaceColor
        backgroundColor: root.headerBoxColor
        bevelColor: root.bevelColor
        shadowColor: root.borderColor
        bevelWidth: 1
        shadowWidth: 3
        // ONE CARVE IN EVERY STATE. ShadowBox deepens a box to 7 px while it
        // shows progress (one inset per box, so all round), and this box
        // switches between -1 and a fraction: the carve would deepen and
        // shallow on the swap's dark frame, every call. The block is a
        // card-depth box, so both progress depths are its own.
        progressIdleWidth: material.shadowWidth
        progressActiveWidth: material.shadowWidth
        // The one coloured fact, and it changes only at zero ink. Running:
        // both edges of the turn's band, same idle mark and feathers as the
        // turn's header. Parked: the WHOLE inset in the error colour for a
        // call that did not deliver, and -1 -- no colour at all -- for every
        // other resting state. `_errored` is read THROUGH `_parked` so the
        // colour and the geometry swap on the same invisible frame.
        shadowProgress: root._parked ? (root._errored ? 1 : -1) : root.sweep
        shadowProgressTail: root._parked ? (root._errored ? 0 : -1) : root.sweepTail
        shadowProgressColor: Mix.c(root.borderColor,
                                   root._parked && root._errored ? root.errColor : root.accent,
                                   root._tintF)
        shadowProgressMinPx: root.sweepIdleWidth
        progressIdleFeatherPx: root.sweepIdleFeather
        progressActiveFeatherPx: root.sweepActiveFeather
    }

    // ---- The handle ---------------------------------------------------------
    Item {
        id: handle
        width: parent.width
        height: root.handleHeight

        property real _hoverF: handleArea.containsMouse && !root._isActivity ? 1 : 0
        Behavior on _hoverF {
            NumberAnimation { duration: root.fadeMs; easing.type: Easing.OutCubic }
        }
        readonly property color _ink: Mix.c(root.faintText, root.accent, handle._hoverF)

        Text {
            id: glyph
            x: root.padding
            anchors.verticalCenter: parent.verticalCenter
            // The registry's glyph when the entry carries one; the wrench --
            // the composer's own tools mark -- otherwise. Never bold.
            text: root._isActivity ? root.activityGlyph
                  : root._e.glyph && String(root._e.glyph).length > 0
                  ? String(root._e.glyph) : ""
            font.family: "Symbols Nerd Font"
            font.pixelSize: root.figureSize + 1
            color: handle._ink
        }
        Text {
            id: summaryText
            anchors.left: glyph.right
            anchors.leftMargin: 6
            anchors.right: statusRow.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: root._summary
            elide: Text.ElideRight
            color: handle._ink
            font.family: root.fontFamily
            font.pixelSize: root.figureSize + 1
        }

        // Right end, fixed slots: status word, time, chevron. The chevron is
        // pinned; the time's slot is measured from a specimen; the word
        // right-aligns against the slot.
        FontMetrics {
            id: figureMetrics
            font.family: root.fontFamily
            font.pixelSize: root.figureSize
        }
        Row {
            id: statusRow
            anchors.right: parent.right
            anchors.rightMargin: root.padding
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6

            Row {
                spacing: 0
                anchors.verticalCenter: parent.verticalCenter
                Text {
                    text: root._statusWord
                    color: handle._ink
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                }
                // The rule, as a link: its own hover fade, the hand, a tip,
                // and it forgets exactly the keys this call ran under.
                Text {
                    id: ruleLink
                    visible: root._status === "done" && root._underRule
                    text: root._ruleLabel
                    color: Mix.c(root.faintText, root.accent, ruleLink._hoverF)
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                    property real _hoverF: ruleArea.containsMouse ? 1 : 0
                    Behavior on _hoverF {
                        NumberAnimation { duration: root.fadeMs; easing.type: Easing.OutCubic }
                    }
                    MouseArea {
                        id: ruleArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            const keys = root._e.grantKeys;
                            for (let i = 0; i < keys.length; ++i)
                                root.revokeRequested(root._name, String(keys[i]));
                        }
                    }
                    HoverTip {
                        show: ruleArea.containsMouse
                        anchorItem: ruleLink
                        overlayItem: root.overlayItem
                        text: "click to forget this rule"
                        fontFamily: root.fontFamily
                        fontPixelSize: root.figureSize
                        surfaceColor: root.surfaceColor
                        bevelColor: root.bevelColor
                        shadowColor: root.borderColor
                        textColor: root.primaryText
                    }
                }
            }
            Item {
                width: Math.ceil(figureMetrics.advanceWidth("88.8 s"))
                height: figureMetrics.height
                anchors.verticalCenter: parent.verticalCenter
                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: root._timeText
                    color: handle._ink
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.expanded ? "" : ""
                // Kept, unseen, on an activity line: the time slot then sits
                // where a real block's does.
                opacity: root._isActivity ? 0 : 1
                font.family: "Symbols Nerd Font"
                font.pixelSize: root.figureSize
                color: handle._ink
            }
        }

        // The whole line toggles. z: -1 puts this area UNDER the status row,
        // so the rule link's own area (a descendant of that row) is above it
        // and takes the hover and the click over the link; everywhere else
        // on the line the pointer falls through the texts to this one.
        MouseArea {
            id: handleArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: root._isActivity ? Qt.ArrowCursor : Qt.PointingHandCursor
            z: -1
            onClicked: if (!root._isActivity) root.toggled()
        }
        HoverTip {
            show: handleArea.containsMouse && !ruleArea.containsMouse
            anchorItem: glyph
            overlayItem: root.overlayItem
            text: root._isActivity ? root.activityTip
                  : root._name + (root._action.length > 0 ? "." + root._action : "")
                  + (root.callLabel.length > 0 ? "  ·  " + root.callLabel : "")
            fontFamily: root.fontFamily
            fontPixelSize: root.figureSize
            surfaceColor: root.surfaceColor
            bevelColor: root.bevelColor
            shadowColor: root.borderColor
            textColor: root.primaryText
        }
    }

    // ---- The body: the drawer's clip, on the fold's one clock ---------------
    Item {
        id: bodyClip
        // Up by the slack, with the column below pushed down by the same
        // amount: the bottom edge -- the one that MOVES, and the one SeamFade
        // is anchored to -- is where it always was.
        y: root.handleHeight - root._bevelSlack
        width: parent.width
        clip: true
        // Part of the visibility, not just the height: a CodeBlock builds
        // nothing while invisible, and its height is what the clip needs.
        // The fold's own fraction answers this, not the height: with the
        // slack the clip is never zero-high.
        visible: root.expanded || root._tExtent > 0
        height: root._bodyH + root._bevelSlack

        Column {
            id: bodyCol
            x: root.padding
            y: root._bevelSlack
            width: Math.max(0, bodyClip.width - root.padding * 2)
            spacing: root.bodyGap

            // (1) The arguments, as they ran.
            CodeBlock {
                width: parent.width
                visible: root._argsText.length > 0
                code: root._argsText
                lang: root._isRunCommand ? "sh" : ""
                label: root._name + (root._action.length > 0 ? "." + root._action : "")
                monoFamily: root.monoFamily
                fontPixelSize: root.codePixelSize
                radius: root.boxRadius
                padding: root.codePadding
                headerHeight: root.codeHeaderHeight
                surfaceColor: root.headerBoxColor
                backgroundColor: root.codeBgColor
                bevelColor: root.bevelColor
                shadowColor: root.borderColor
                headerColor: root.headerBoxColor
                mutedColor: root.faintText
                selectionColor: root.selectionColor
                selectionTextColor: root.selectionTextColor
                buttonPlateauColor: root.buttonPlateau
                buttonPlateauHoverColor: root.buttonPlateauHover
                buttonBevelColor: root.buttonBevel
                buttonShadowColor: root.buttonShadow
            }

            // (2) The result -- or (3) the picture.
            CodeBlock {
                id: resultBox
                width: parent.width
                visible: !root._isImage && root._result.length > 0
                code: root._resultShown
                lang: ""
                label: "result"
                monoFamily: root.monoFamily
                fontPixelSize: root.codePixelSize
                radius: root.boxRadius
                padding: root.codePadding
                headerHeight: root.codeHeaderHeight
                surfaceColor: root.headerBoxColor
                backgroundColor: root.codeBgColor
                bevelColor: root.bevelColor
                shadowColor: root.borderColor
                headerColor: root.headerBoxColor
                mutedColor: root.faintText
                selectionColor: root.selectionColor
                selectionTextColor: root.selectionTextColor
                buttonPlateauColor: root.buttonPlateau
                buttonPlateauHoverColor: root.buttonPlateauHover
                buttonBevelColor: root.buttonBevel
                buttonShadowColor: root.buttonShadow
                // The button copies the WHOLE stored result, not the fold:
                // the box put its shown text on the clipboard; replace it.
                onCopied: Quickshell.clipboardText = Md.copyText(root._result)
            }
            Item {
                id: moreLine
                visible: root._hiddenLines > 0
                width: parent.width
                height: moreText.implicitHeight + 2
                property real _hoverF: moreArea.containsMouse ? 1 : 0
                Behavior on _hoverF {
                    NumberAnimation { duration: root.fadeMs; easing.type: Easing.OutCubic }
                }
                Text {
                    id: moreText
                    x: root.codePadding
                    anchors.verticalCenter: parent.verticalCenter
                    text: "… " + root._group(root._hiddenLines) + " more lines"
                    color: Mix.c(root.mutedText, root.accent, moreLine._hoverF)
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                }
                MouseArea {
                    id: moreArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root._resultAll = true
                }
            }
            Item {
                id: shotSlot
                visible: root._isImage
                width: parent.width
                height: root.thumbSize + root.imageInset * 2

                Image {
                    id: shot
                    x: root.imageInset
                    y: root.imageInset
                    height: root.thumbSize
                    width: Math.min(shotSlot.width - root.imageInset * 2,
                                    root._e.imageW > 0 && root._e.imageH > 0
                                        ? Math.round(root.thumbSize * root._e.imageW / root._e.imageH)
                                        : root.thumbSize)
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    source: root._isImage ? "data:image/jpeg;base64," + root._thumb : ""
                    sourceSize.height: Math.round(root.thumbSize * Math.max(2, dev.value))
                    // Hover shows the full picture in the tip; a click does nothing, so no hand.
                    HoverHandler { id: shotHover }
                }
                Text {
                    anchors.left: shot.right
                    anchors.leftMargin: 10
                    anchors.verticalCenter: shot.verticalCenter
                    text: (root._e.imageW > 0 ? root._e.imageW + "×" + root._e.imageH : "")
                          + (root._image.length === 0 ? "  ·  picture no longer stored" : "")
                    color: root.faintText
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                }
                // The full picture in the tip; the thumb when the store has
                // dropped the payload.
                HoverTip {
                    show: shotHover.hovered
                    anchorItem: shot
                    overlayItem: root.overlayItem
                    side: "above"
                    fontFamily: root.fontFamily
                    fontPixelSize: root.figureSize
                    surfaceColor: root.surfaceColor
                    bevelColor: root.bevelColor
                    shadowColor: root.borderColor
                    textColor: root.primaryText
                    contentComponent: Component {
                        Image {
                            readonly property real _w: root._e.imageW > 0 ? root._e.imageW : 640
                            readonly property real _h: root._e.imageH > 0 ? root._e.imageH : 360
                            readonly property real _fit: Math.min(1, 480 / _w, 320 / _h)
                            width: Math.round(_w * _fit)
                            height: Math.round(_h * _fit)
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            source: root._image.length > 0
                                ? "data:image/png;base64," + root._image
                                : "data:image/jpeg;base64," + root._thumb
                            // its own width, at the glass's resolution (a fixed size per entry: nothing re-decodes it)
                            sourceSize.width: Math.round(width * Math.max(1, tipDev.value))
                            DeviceScale {
                                id: tipDev
                            }
                        }
                    }
                }
            }

            // (4) Figures, fixed by construction: the entry is final by the
            // time they exist.
            Text {
                visible: root._figures.length > 0
                x: root.codePadding
                width: Math.max(0, parent.width - root.codePadding)
                text: root._figures
                color: root.faintText
                font.family: root.fontFamily
                font.pixelSize: root.figureSize
                elide: Text.ElideRight
            }

            // (5) The decision, only when it says something.
            Item {
                visible: root._decisionText.length > 0
                width: parent.width
                height: decisionText.implicitHeight
                Text {
                    id: decisionText
                    x: root.codePadding
                    anchors.verticalCenter: parent.verticalCenter
                    text: root._decisionText
                    color: root.mutedText
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                }
                Text {
                    id: revokeLink
                    visible: root._underRule && root._decisionText.length > 0
                    anchors.left: decisionText.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "  ·  revoke"
                    color: Mix.c(root.mutedText, root.accent, revokeLink._hoverF)
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                    property real _hoverF: revokeArea.containsMouse ? 1 : 0
                    Behavior on _hoverF {
                        NumberAnimation { duration: root.fadeMs; easing.type: Easing.OutCubic }
                    }
                    MouseArea {
                        id: revokeArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            const keys = root._e.grantKeys;
                            for (let i = 0; i < keys.length; ++i)
                                root.revokeRequested(root._name, String(keys[i]));
                        }
                    }
                }
            }
        }

        SeamFade {
            extent: root._tExtent
            ground: root.headerBoxColor
            fadeHeight: root.seamFadeHeight
        }
    }
}
