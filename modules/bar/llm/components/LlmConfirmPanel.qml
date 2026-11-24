pragma ComponentBehavior: Bound

import QtQuick
import "../../../common/theme"
import "../../../common/components"

// =============================================================================
// LlmConfirmPanel.qml
//
// The confirmation box for an ACTING tool call: what
// the model wants to run, verbatim, and the three answers. It lives INSIDE the
// composer's groove, at its top, and the composer grows upward to make room
// -- inside the prompt input field, where it expands upwards and shows the
// requested command when attention is required.
//
// WHAT IS SHOWN IS WHAT RUNS. The detail is `req.detail` from the frozen call
// object the service built at policy time -- the command string exactly
// as the model sent it, the resolved path and the full content of a write,
// the rendered argv of a family action one element per line -- in the code
// face, in a CodeBlock. No summary ever stands in for it; the title is the
// summary as a question and the detail is the thing itself. A control
// character is drawn visibly (`^M`, `␛`) rather than swallowed, because a
// swallowed byte is a byte the user approved without seeing.
//
// THE THIRD BUTTON NAMES ITS OWN RULE: "Always allow git status …"
// prints the exact grant key it would write, so no allowance is ever a
// surprise. It is absent when the request is not grantable, and the reason
// line says why ("sudo — always asks", "no rule can describe this command").
//
// FOCUS AND KEYS. The panel takes focus the moment a request lands;
// Return / Y answer yes, Escape / N answer no, A answers always (only while
// the button exists -- otherwise it is swallowed and nothing happens). The
// composer keeps its field read-only meanwhile and forwards the field's own
// keys here, so Return never submits whichever item holds the focus.
// `handleKey` is the ONE code path for both.
//
// THE DETAIL SCROLLS INSIDE A FIXED CARVED EDGE. Past `maxLines` the box
// stops growing and the code scrolls within it (wheel + drag, no bar -- the
// bars are gone shell-wide).
//
// ON THE SHELL'S NOTCH, AND FADED. A Flickable on QT'S OWN wheel handling
// moves at `wheelScrollLines` -- a DESKTOP STYLE HINT -- times 24 px: 72.00 px per notch against the
// transcript's 120.00, eased in over ~90 ms and swallowing notches that
// arrive while it decays, so a brisk ten-notch spin travels 419 px where the
// transcript travels 1200 (measured). It has no edge band either, because a fade is not a
// property of a Flickable but two gradients a host must place: the first and last visible lines
// would be sliced in half at the clip. Both facts are ScrollDressing's, which is one object and one
// number for every box in the shell. It fades to `codeBackground`, the box's
// own fill, and NOT to the card's -- the ground a band blends into is
// whatever is actually under the text.
//
// A CodeBlock draws its own chrome, and chrome
// inside a clipping Flickable would scroll with the text -- the bevel leaving
// the top as the first line leaves. So the chrome here is this file's own
// ShadowBox at a fixed height, and the CodeBlock inside it is painted FLAT:
// its four chrome colours are all the code background, so it is a rectangle
// of the box's own fill, inset far enough (`_inset`, 6 px) that its square
// corners stay inside the arc of the rounded edge and clear of the inset
// shadow's 3 px band. The CodeBlock's padding drops by the same inset, so
// the text lands exactly where a plain CodeBlock would have put it.
//
// A SECOND REQUEST SWAPS THE TEXT INSTANTLY inside the standing card: every
// line is a binding on the latched request, and presence (opacity) is the
// only thing that fades. The latched copy (`shown`) survives the request
// going null, so the card fades out still saying what it said, never blank.
//
// FIGURES IN FIXED SLOTS. The right end of the title line -- the tool name,
// `call 1 of 2`, `34 lines` -- sits in slots measured from the widest value
// each can hold, blank when there is nothing to say, so a swap from one
// request to the next moves no other figure.
//
// SUDO'S PASSWORD IS NOT ASKED HERE. It is asked in the
// shell's authentication toast (AuthBroker); this card is the command
// confirmation and nothing else.
//
// Every colour is a property with a `Theme.<token>` default; nothing here
// animates a colour. Presence fades 160 ms; everything else is instant.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // PUBLIC API
    // ======================================================================
    // The confirmation request, or null. The host (the
    // composer) binds it straight to `service.pendingConfirm`.
    property var    request: null
    // How many lines of the detail are visible before it scrolls inside.
    property int    maxLines: 12
    property string fontFamily: "Inter"
    property string monoFamily: "Consolas"
    property int    fontPixelSize: 12
    property int    figureSize: 10
    property int    codePixelSize: 12
    property real   radius: 10
    property real   padding: 10
    property real   gap: 6
    property real   buttonHeight: 24
    property int    fadeMs: 160
    // The shell's one scroll notch (1.0 == 120 px) and its edge band, for the
    // detail box. The band is clamped to a quarter of the viewport: 34 px in
    // a twelve-line preview would be two and a half lines at each end.
    property real   scrollSpeed: 1.0
    property real   fadeHeight: 34
    // The host's floating layer, for the buttons' tips.
    property Item   overlayItem: null

    // ---- Palette ----
    property color surfaceColor: Theme.panelSunk      // the groove the card is carved into
    property color fillColor: Theme.headerBox         // the card's fill (the chips' colour)
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
    property color codeBackground: Theme.terminalBg
    property color codeText: Theme.terminalFg
    property color tipSurfaceColor: Theme.surface

    // "yes" | "no" | "always", with the request's id.
    signal answered(string id, string decision)

    // The request the card is drawing: the live one, or the last one while
    // the card fades out.
    readonly property var  shown: root._shown
    // The card has the keyboard: what the composer asks before handing the
    // focus back to its own field.
    readonly property bool holdsFocus: root.activeFocus
    readonly property bool grantable: !!root._shown && !!root._shown.grantable
    readonly property int  detailLines: root._lines
    // True when the detail is taller than `maxLines` and scrolls inside.
    readonly property bool overflowing: root._lines > root.maxLines

    // The one key path (the composer forwards its field's keys here too).
    // Returns true when the key was this panel's business.
    function handleKey(event) {
        if (!root.request)
            return false;
        const id = String(root.request.id);
        const plain = (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) === 0;
        // TAB IS SWALLOWED WHILE A REQUEST STANDS. An
        // unclaimed Tab here moves the focus off this panel onto the
        // composer's read-only field -- Qt's own focus navigation -- and breaks
        // the invariant that the panel holds the focus.
        // Claiming it and doing nothing is the whole of the interaction: a
        // confirmation has three answers and no tab order.
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)
            return true;
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.answered(id, "yes");
            return true;
        }
        if (event.key === Qt.Key_Escape) {
            root.answered(id, "no");
            return true;
        }
        if (!plain)
            return false;
        if (event.key === Qt.Key_Y) { root.answered(id, "yes"); return true; }
        if (event.key === Qt.Key_N) { root.answered(id, "no"); return true; }
        if (event.key === Qt.Key_A) {
            // Swallowed either way: with no third button the letter must
            // not land anywhere else, and nothing is answered.
            if (root.grantable)
                root.answered(id, "always");
            return true;
        }
        return false;
    }

    // ======================================================================
    // STATE
    // ======================================================================
    property var _shown: null
    onRequestChanged: {
        if (root.request) {
            root._shown = root.request;
            root.forceActiveFocus();
        }
    }
    Keys.onPressed: function (event) {
        if (root.handleKey(event))
            event.accepted = true;
    }

    function _s(key, dflt) {
        const r = root._shown;
        if (!r || r[key] === undefined || r[key] === null)
            return dflt;
        return r[key];
    }
    // Control characters drawn visibly: a byte the eye cannot see is a byte
    // the user cannot approve. Tabs and newlines are structure and stay.
    function _visible(s) {
        let out = "";
        for (let i = 0; i < s.length; i++) {
            const c = s.charCodeAt(i);
            if (c === 0x1B) out += "␛";
            else if (c === 0x0D) out += "^M";
            else if (c === 0x7F) out += "^?";
            else if (c < 0x20 && c !== 0x09 && c !== 0x0A) out += "^" + String.fromCharCode(64 + c);
            else out += s.charAt(i);
        }
        return out;
    }
    readonly property string _detailText: root._visible(String(root._s("detail", "")))
    readonly property int _lines: {
        const n = Number(root._s("detailLines", 0));
        if (n > 0)
            return n;
        const t = root._detailText;
        return t.length === 0 ? 0 : t.split("\n").length;
    }
    readonly property string _callSlot: {
        const count = Number(root._s("count", 1));
        if (!(count > 1))
            return "";
        return "call " + (Number(root._s("index", 0)) + 1) + " of " + count;
    }
    readonly property string _linesSlot: root.overflowing ? root._lines + " lines" : ""
    readonly property string _status: {
        let s = "in " + String(root._s("cwd", "~")) + " · " + String(root._s("timeoutS", 60)) + " s limit";
        const auth = Number(root._s("authS", 0));
        if (auth > 0)
            s += " · +" + (auth % 60 === 0 ? (auth / 60) + " min" : auth + " s") + " for sudo to ask";
        const pf = String(root._s("preflight", ""));
        if (pf.length > 0)
            s += " · " + pf;
        return s;
    }
    readonly property string _reason: String(root._s("reason", ""))
    // A command line of several commands asks as a whole; the panel says WHICH
    // of them needs the answer (the rest read files, or run under a
    // rule, and pass by themselves). Facts only -- no colour in a Repeater model.
    readonly property var _parts: {
        const p = root._s("parts", []);
        return p ? p : [];
    }
    // The parts that ask, as facts: { text, key } -- `key` is the rule that
    // would cover that one command (null when none may).
    readonly property var _askParts: {
        const out = [];
        for (let i = 0; i < root._parts.length; i++)
            if (root._parts[i].state === "ask")
                out.push({ text: String(root._parts[i].text).replace(/\s+/g, " "), key: root._parts[i].key ? String(root._parts[i].key) : "" });
        return out;
    }
    // A button per command, when the one for the whole line is not enough: the
    // line cannot be granted whole (a command in it asks every time) or two or
    // more of its commands each want a rule of their own.
    readonly property bool _partAlways: {
        let keyed = 0;
        for (let i = 0; i < root._askParts.length; i++) if (root._askParts[i].key.length > 0) keyed++;
        return keyed > 0 && (!root.grantable || keyed > 1);
    }
    readonly property bool _showParts: root._parts.length > 1 && root._askParts.length > 0
    readonly property int  _partsShown: Math.min(3, root._askParts.length)
    readonly property string _partsRest: {
        const free = root._parts.length - root._askParts.length;
        const more = root._askParts.length - root._partsShown;
        let t = "";
        if (more > 0) t += "+" + more + " more ask";
        if (free > 0) t += (t.length > 0 ? " · " : "") + (free === 1 ? "1 other command runs without asking" : free + " other commands run without asking");
        return t;
    }
    readonly property string _grantLabel: String(root._s("grantLabel", ""))
    readonly property string _grantKeysText: {
        const ks = root._s("grantKeys", []);
        return (ks && ks.length) ? Array.prototype.map.call(ks, k => "`" + k + "`").join(", ") : "";
    }

    // ======================================================================
    // GEOMETRY
    // ======================================================================
    // The flat CodeBlock's inset inside the carved edge -- see the header.
    readonly property real _inset: 6
    readonly property real _codePad: Math.max(0, root.padding - root._inset)
    // One logical line's pitch, from the block itself: what `maxLines` of
    // them come to is the cap.
    readonly property real _pitch: root._lines > 0
        ? (detailCode.implicitHeight - root._codePad * 2) / root._lines : monoFm.height
    readonly property real _capInner: root._codePad * 2 + Math.round(root.maxLines * root._pitch)

    implicitWidth: 0
    implicitHeight: Math.round(root.padding * 2 + column.implicitHeight)

    opacity: root.request ? 1 : 0
    visible: !!root.request || opacity > 0
    Behavior on opacity { NumberAnimation { duration: root.fadeMs; easing.type: Easing.OutCubic } }

    FontMetrics {
        id: figFm
        font.family: root.fontFamily
        font.pixelSize: root.figureSize
    }
    FontMetrics {
        id: monoFm
        font.family: root.monoFamily
        font.pixelSize: root.codePixelSize
        font.bold: true
    }
    readonly property real _nameSlotW: Math.ceil(figFm.advanceWidth("clipboard_write"))
    readonly property real _callSlotW: Math.ceil(figFm.advanceWidth("call 0 of 0"))
    readonly property real _linesSlotW: Math.ceil(figFm.advanceWidth("0000 lines"))
    readonly property real _glyphSlotW: 16
    readonly property real _asksSlotW: Math.ceil(figFm.advanceWidth("asks"))

    // ======================================================================
    // THE CARD
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

    Column {
        id: column
        x: root.padding
        y: root.padding
        width: root.width - root.padding * 2
        spacing: root.gap

        // ---- 1. Title line ------------------------------------------------
        Item {
            id: titleRow
            width: column.width
            height: Math.max(titleText.implicitHeight, glyph.implicitHeight)

            // The tool's glyph: a mark, muted, never bold. Its slot keeps its
            // width so the title starts on one column whatever the tool.
            Text {
                id: glyph
                x: 0
                anchors.verticalCenter: parent.verticalCenter
                width: root._glyphSlotW
                text: String(root._s("glyph", ""))
                color: root.mutedText
                font.family: "Symbols Nerd Font"
                font.pixelSize: root.fontPixelSize
                font.bold: false
            }
            Text {
                id: titleText
                x: root._glyphSlotW
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, figures.x - x - root.gap)
                text: String(root._s("title", ""))
                color: root.primaryText
                font.family: root.fontFamily
                font.pixelSize: root.fontPixelSize
                elide: Text.ElideRight
            }
            // The figures, right end, each in its own slot: blank slots keep
            // their width so nothing moves when a request follows another.
            Row {
                id: figures
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8
                Text {
                    width: root._nameSlotW
                    horizontalAlignment: Text.AlignRight
                    text: String(root._s("tool", ""))
                    color: root.mutedText
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                    elide: Text.ElideRight
                }
                Text {
                    width: root._callSlotW
                    horizontalAlignment: Text.AlignRight
                    text: root._callSlot
                    color: root.mutedText
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                }
                Text {
                    width: root._linesSlotW
                    horizontalAlignment: Text.AlignRight
                    text: root._linesSlot
                    color: root.mutedText
                    font.family: root.fontFamily
                    font.pixelSize: root.figureSize
                }
            }
        }

        // ---- 2. The detail, verbatim, in the code face ---------------------
        Item {
            id: detailBox
            width: column.width
            height: Math.round(root._inset * 2
                               + Math.min(detailCode.implicitHeight, root._capInner))

            ShadowBox {
                anchors.fill: parent
                baseRadius: Math.max(4, root.radius - 4)
                surfaceColor: root.fillColor
                backgroundColor: root.codeBackground
                bevelColor: root.bevelColor
                shadowColor: root.shadowColor
                bevelWidth: 1
                shadowWidth: 3
            }

            // Wheel and drag, no bar; inert when the detail fits.
            Flickable {
                id: detailFlick
                anchors.fill: parent
                anchors.margins: root._inset
                clip: true
                contentWidth: width
                contentHeight: detailCode.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                interactive: contentHeight > height + 0.5

                CodeBlock {
                    id: detailCode
                    width: detailFlick.width
                    showHeader: false
                    padding: root._codePad
                    radius: 0
                    code: root._detailText
                    lang: String(root._s("detailLang", ""))
                    monoFamily: root.monoFamily
                    fontPixelSize: root.codePixelSize
                    // Painted FLAT -- the carved edge is the box's, above.
                    surfaceColor: root.codeBackground
                    backgroundColor: root.codeBackground
                    bevelColor: root.codeBackground
                    shadowColor: root.codeBackground
                    headerColor: root.codeBackground
                    textColor: root.codeText
                    mutedColor: root.faintText
                }
            }

            // A SIBLING of the Flickable, inset to the same rectangle: a
            // child would be reparented into the content and scroll away
            // with the code it is supposed to fade.
            ScrollDressing {
                objectName: "llmConfirmDressing"
                anchors.fill: parent
                anchors.margins: root._inset
                flick: detailFlick
                scrollSpeed: root.scrollSpeed
                fadeHeight: Math.min(root.fadeHeight, detailFlick.height / 4)
                ground: root.codeBackground
            }
        }

        // ---- 2b. Which part of a chain needs the answer ---------------------
        Column {
            id: partsBox
            width: column.width
            visible: root._showParts
            height: root._showParts ? implicitHeight : 0
            spacing: 2
            Repeater {
                model: root._showParts ? root._askParts.slice(0, root._partsShown) : []
                delegate: Item {
                    id: partRow
                    required property var modelData
                    readonly property bool hasRule: root._partAlways && partRow.modelData.key.length > 0
                    width: partsBox.width
                    height: Math.max(partLabel.implicitHeight, partCmd.implicitHeight, partRow.hasRule ? partBtn.height : 0)
                    Text {
                        id: partLabel
                        anchors.verticalCenter: parent.verticalCenter
                        text: "asks"
                        color: root.mutedText
                        font.family: root.fontFamily
                        font.pixelSize: root.figureSize
                    }
                    Text {
                        id: partCmd
                        x: root._asksSlotW + 6
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(0, partRow.width - x - (partRow.hasRule ? partBtn.width + 6 : 0))
                        text: partRow.modelData.text
                        color: root.primaryText
                        font.family: root.monoFamily
                        font.pixelSize: root.figureSize + 1
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    // This command's own rule, by name: "Always allow checkupdates …".
                    RaisedButton {
                        id: partBtn
                        objectName: "llmPartAlways"
                        visible: partRow.hasRule
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        height: Math.round(root.buttonHeight * 0.8)
                        minWidth: 0
                        horizontalPadding: 8
                        text: "Always allow " + partRow.modelData.key
                        fontFamily: root.fontFamily
                        fontPixelSize: root.figureSize
                        surfaceColor: root.fillColor
                        plateauColor: root.buttonPlateau
                        plateauHoverColor: root.buttonPlateauHover
                        bevelColor: root.buttonBevel
                        shadowColor: root.buttonShadow
                        textColor: root.primaryText
                        faintTextColor: root.faintText
                        onClicked: root.answered(String(root._s("id", "")), "always:" + partRow.modelData.key)
                    }
                }
            }
            Text {
                width: partsBox.width
                visible: root._partsRest.length > 0
                height: visible ? implicitHeight : 0
                text: root._partsRest
                color: root.mutedText
                font.family: root.fontFamily
                font.pixelSize: root.figureSize
                elide: Text.ElideRight
            }
        }

        // ---- 3. Status line ----------------------------------------------
        Text {
            width: column.width
            text: root._status
            color: root.mutedText
            font.family: root.fontFamily
            font.pixelSize: root.figureSize
            elide: Text.ElideRight
        }

        // ---- 4. Reason line, only when there is one ------------------------
        Text {
            width: column.width
            visible: root._reason.length > 0
            text: root._reason
            color: root.mutedText
            font.family: root.fontFamily
            font.pixelSize: root.figureSize
            elide: Text.ElideRight
        }

        // ---- 5. The answers -------------------------------------------------
        Item {
            width: column.width
            height: root.buttonHeight

            Row {
                id: buttons
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: root.gap

                // The third answer: the rule it would write, on the button.
                RaisedButton {
                    id: alwaysBtn
                    visible: root.grantable
                    height: root.buttonHeight
                    minWidth: 0
                    horizontalPadding: 10
                    text: "Always allow " + root._grantLabel
                    fontFamily: root.fontFamily
                    fontPixelSize: root.figureSize + 1
                    surfaceColor: root.fillColor
                    plateauColor: root.buttonPlateau
                    plateauHoverColor: root.buttonPlateauHover
                    bevelColor: root.buttonBevel
                    shadowColor: root.buttonShadow
                    textColor: root.primaryText
                    faintTextColor: root.faintText
                    onClicked: root.answered(String(root._s("id", "")), "always")
                    // A HoverHandler on an item ABOVE the button: the
                    // button's own MouseArea takes hover, which would block a
                    // handler beneath it, and a handler blocks nothing.
                    Item {
                        anchors.fill: parent
                        HoverHandler { id: alwaysHover }
                    }
                }
                RaisedButton {
                    id: noBtn
                    height: root.buttonHeight
                    minWidth: 0
                    horizontalPadding: 10
                    text: "Don't run"
                    fontFamily: root.fontFamily
                    fontPixelSize: root.figureSize + 1
                    surfaceColor: root.fillColor
                    plateauColor: root.buttonPlateau
                    plateauHoverColor: root.buttonPlateauHover
                    bevelColor: root.buttonBevel
                    shadowColor: root.buttonShadow
                    textColor: root.primaryText
                    faintTextColor: root.faintText
                    onClicked: root.answered(String(root._s("id", "")), "no")
                    Item {
                        anchors.fill: parent
                        HoverHandler { id: noHover }
                    }
                }
                RaisedButton {
                    id: yesBtn
                    height: root.buttonHeight
                    minWidth: 0
                    horizontalPadding: 12
                    text: "Run"
                    accent: true
                    fontFamily: root.fontFamily
                    fontPixelSize: root.figureSize + 1
                    surfaceColor: root.fillColor
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
                    onClicked: root.answered(String(root._s("id", "")), "yes")
                    Item {
                        anchors.fill: parent
                        HoverHandler { id: yesHover }
                    }
                }
            }
        }
    }

    // ---- The buttons' tips, in the overlay --------------------------------
    HoverTip {
        show: alwaysHover.hovered && alwaysBtn.visible
        anchorItem: alwaysBtn
        overlayItem: root.overlayItem
        text: "Adds a rule for " + root._grantKeysText + "; forget it from the wrench menu,\n"
            + "the block's link or the Tools tab. Global: every conversation, incognito\n"
            + "included (an incognito conversation uses rules but never writes one)."
        fontFamily: root.fontFamily
        surfaceColor: root.tipSurfaceColor
        bevelColor: root.bevelColor
        shadowColor: root.shadowColor
        textColor: root.primaryText
    }
    HoverTip {
        show: noHover.hovered
        anchorItem: noBtn
        overlayItem: root.overlayItem
        text: "Escape · N"
        fontFamily: root.fontFamily
        surfaceColor: root.tipSurfaceColor
        bevelColor: root.bevelColor
        shadowColor: root.shadowColor
        textColor: root.primaryText
    }
    HoverTip {
        show: yesHover.hovered
        anchorItem: yesBtn
        overlayItem: root.overlayItem
        text: "Return · Y"
        fontFamily: root.fontFamily
        surfaceColor: root.tipSurfaceColor
        bevelColor: root.bevelColor
        shadowColor: root.shadowColor
        textColor: root.primaryText
    }
}
