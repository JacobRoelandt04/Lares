pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import "../../../common/theme"
import "../../../common/scroll"
import "../../../common/components"

// =============================================================================
// TerminalView.qml
//
// Default visual for a TerminalBackend. Renders the backend's styled line
// buffer in a virtualised ListView, tracks auto-scroll-to-tail when the user
// is pinned near the bottom, and provides an input row whose TextField masks
// itself when the backend flags a password prompt.
//
// This is deliberately the "batteries-included" view so consumers only have
// to drop one element into their popup. It does not style the surrounding
// container — set `color`, `border.color`, `radius` on the root Rectangle
// (or wrap in a ShadowBox) via property overrides.
//
// Text selection: each line is a TextEdit (readOnly, selectByMouse) so users
// can drag-select inside a line and Ctrl+C to copy. Cross-line selection
// doesn't span multiple delegates in a ListView — use the exposed `copyAll`
// method (or the UI's "Copy all" button when shown) to pull the full
// scrollback as plain text.
// =============================================================================
Rectangle {
    id: root

    // Required: pass the TerminalBackend instance this view observes.
    property var backend: null

    // Visual defaults — override freely. Themed rather than eva-light
    // literals: the view is a window onto another program's output and the
    // theme dresses that program's palette too (TerminalBackend.ansi), so
    // the two must come from the same place or the box switches and the ink
    // inside it does not.
    color: Theme.terminalBg
    radius: 8
    border.color: Theme.border
    border.width: 1

    // A BACKDROP THE HOST DRAWS BEHIND THE OUTPUT. Declared before the
    // content and at the back of the stack, so text renders over whatever is
    // put here and the element stays visible as the buffer fills -- it is a
    // ground, not an empty state. The shell uses it for the carved Arch mark
    // in verbose view.
    default property alias backdrop: _backdrop.data

    // Selection, and the chrome of the optional input row / prompt banner.
    property color textColor: Theme.terminalFg
    property color selectionColor: Theme.terminalSelection
    property color selectedTextColor: Theme.terminalSelectionText
    property color inputFieldColor: Theme.surface
    property color inputBorderColor: Theme.border
    property color inputFocusBorderColor: Theme.accent
    property color promptBannerColor: Theme.panelSunk
    property color passwordBannerColor: Theme.errorTint

    // Layout tunables.
    property real contentMargin: 8
    property int fontPixelSize: 13
    // Bold, as in kitty (Consolas Bold). RichText spans without
    // an explicit weight inherit the edit's font, so this reaches every line.
    property bool fontBold: true
    // Monospace font. QML `font.family` is a SINGLE family name — comma
    // stacks aren't parsed like CSS. If the named family isn't installed,
    // Qt picks a system default which is often proportional, silently
    // breaking terminal column alignment. Default to Consolas (widely
    // installed). Bind to backend.fontFamily so the in-HTML CSS and the
    // TextEdit.font agree.
    property string monoFamily: root.backend ? root.backend.fontFamily : "Consolas"

    // UI toggles.
    property bool showInputRow: true
    property bool showPromptBanner: true
    property bool showYesNoShortcuts: true
    property bool showCopyAllButton: true

    // A mouse notch moves this many of the shell's notches (ScrollFeel.notchPx
    // each). Default 3.0 — one notch is one delegate row on a stock view,
    // which feels glacial on densely-packed terminal output; 3x brings it
    // closer to native terminal scroll feel. A touchpad follows the fingers 1:1
    // (x ScrollFeel.speed) and is not scaled by this.
    property real wheelStepMultiplier: 3.0

    // Wrap long lines instead of letting them run off the right edge. When
    // off, the view scrolls horizontally (two-finger swipe, or a tilt wheel)
    // and shows no horizontal scrollbar.
    property bool wrapLines: false
    // Append an explicit end-of-run marker when the process exits.

    // True when content is actually running off the right edge, i.e. a
    // horizontal swipe here has somewhere to go. False whenever wrapping is on,
    // because then nothing is ever cut off. Hosts use this to decide whether a
    // horizontal gesture belongs to the terminal or to them.
    readonly property bool horizontallyScrollable:
        !root.wrapLines && _scroller.contentWidth > _scroller.width + 1
    // The same for a sideways notch (a tilt wheel); fingers are 1:1 x ScrollFeel.hSpeed.
    property real hWheelStepMultiplier: 6.0

    // ONE MOTION, ONE AXIS.
    //
    // Fingers on a touchpad never move on one axis alone: a vertical read
    // arrives with a few degrees of x on most of its events, and unwrapped
    // output drifts sideways while it is being read. So a motion picks an
    // axis and keeps it for as long as the fingers are down -- whichever side
    // is ahead once it is clearly ahead (`wheelAxisRatio`). Until then the
    // larger half of each event moves and the smaller one waits, so nothing
    // feels dead and at most one event's worth can creep the other way.
    //
    // A wheel event that is zero on BOTH axes is the fingers leaving the
    // surface, which is what ends a motion (`docs/contracts/gestures.md`).
    // `wheelIdleMs` ends one that never sends that event -- a mouse wheel
    // sends none, and its notches are separate motions anyway.
    property real wheelAxisRatio: 1.4
    property int wheelIdleMs: 140
    // 0 undecided, 1 vertical, 2 horizontal.
    property int _wheelAxis: 0
    property real _wheelSumX: 0
    property real _wheelSumY: 0
    Timer {
        id: _wheelIdle
        interval: root.wheelIdleMs
        onTriggered: root._endWheelMotion()
    }
    // Set by the HOST while a gesture that belongs to IT is in flight -- the
    // popup's two-finger view switch. A swipe is a wheel, so its events reach
    // this view too, and the switch drops the terminal under the pointer part
    // way through the motion: the rest of the swipe would then drag the text
    // sideways (measured: from 100 to 0), once per switch. The host decides ownership once, when a
    // gesture begins (one that starts over cut-off text is the terminal's,
    // all of it), so honouring it here costs a deliberate sideways scroll
    // nothing. Only the horizontal axis is refused: the host raises this on
    // the first wheel of ANY motion, vertical included.
    property bool externalGesture: false

    function _endWheelMotion() {
        _wheelIdle.stop();
        root._wheelAxis = 0;
        root._wheelSumX = 0;
        root._wheelSumY = 0;
        root._settleAway();
    }

    // THE MOTION, one KineticScroll per axis (modules/common/scroll): a notch
    // glides, fingers follow, a lift while they move coasts, fingers put back
    // catch it -- the shell's one feel. The reader below keeps the axis lock and
    // hands the engine of the axis it chose each event's component, the lift
    // included (that event is what starts the coast).
    KineticScroll {
        id: _vk
        flick: _scroller
        axis: Qt.Vertical
    }
    KineticScroll {
        id: _hk
        flick: _scroller
        axis: Qt.Horizontal
    }
    // The user is scrolling OFF the tail. A glide (or fingers) start inside the
    // follow band (60 px) and a flush of output arrives within it: without this
    // the follower would pull the view back to the tail and cancel the motion.
    // Held while the motion lasts, then `_follow` is read afresh from where it
    // stopped.
    property bool _away: false
    function _settleAway() {
        if (!root._away || _vk.moving)
            return;
        root._away = false;
        root._follow = (_scroller.contentHeight - _scroller.height - _scroller.contentY) <= root._tailBand;
    }
    Connections {
        target: _vk
        function onMovingChanged() {
            if (!_vk.moving && !_wheelIdle.running)
                root._settleAway();
        }
    }
    onExternalGestureChanged: if (root.externalGesture) _hk.stop()


    // The scrolling viewport, for probes that check contentY against the tail.
    readonly property alias _viewport: _scroller

    // Copy the entire scrollback (plain text, no ANSI) to the system clipboard.
    function copyAll() {
        if (!root.backend) return;
        const lm = root.backend.linesModel;
        let out = "";
        for (let i = 0; i < lm.count; i++) {
            out += lm.get(i).raw;
            if (i < lm.count - 1) out += "\n";
        }
        _clipboardHelper.text = out;
        _clipboardHelper.selectAll();
        _clipboardHelper.copy();
        _clipboardHelper.deselect();
    }


    // Focus the input field. Call this from hosts after start() so users can
    // type immediately without clicking.
    function focusInput() {
        _inputField.forceActiveFocus();
    }

    // ---- Output plumbing ------------------------------------------------
    //
    // Two documents. The FROZEN history holds every line that can no longer
    // change -- anything further from the end than `liveTailRows` -- and is
    // only ever appended to, one paragraph per line. The LIVE tail holds the
    // last `liveTailRows` committed lines plus the uncommitted preview, and
    // is rebuilt whole whenever the model changes; that is O(tail), never
    // O(scrollback).
    //
    // Treating any drop in the committed count as "the scrollback was trimmed"
    // and rebuilding the entire history document would be far too costly: pacman
    // redraws its parallel download bars by moving the cursor up and
    // rewriting rows, so the count drops and rises thousands of times a
    // minute (a recorded run rebuilt the document 13,000 times and
    // re-inserted 8.7 million lines: the download-phase lag, paid even with the
    // view hidden in the normal layout). A hidden view does
    // nothing at all until it is shown, and syncs are coalesced to one per
    // frame.
    //
    // Cursor addressing only ever reaches back a screen's worth of rows, so
    // rows older than the tail are genuinely final. A trim from the front
    // removes the same lines from the front of the history document; only a
    // rewrite behind the tail (dataChanged on a frozen row) rebuilds it.
    property int liveTailRows: 64

    QtObject {
        id: _out
        // Lines appended to the frozen document, counted from the backend's
        // first-ever line: model index = this - backend.trimmedLines.
        property int  frozenLines: 0
        // First-ever line still held by the history document, and one
        // {lines, chars} record per append batch, so lines the backend trims
        // from the front can be removed from the front of the document
        // instead of rebuilding it.
        property int  historyStart: 0
        property var  batches: []
        // Last HTML handed to _tailEdit. `_tailEdit.text` cannot be compared
        // against: on a RichText TextEdit it reads back as the serialised
        // document, never the string that was set.
        property string tailHtml: ""
        property bool dirty: false
        property bool needsRebuild: false
        property bool queued: false
    }
    function _rebuildOutput() {
        _out.needsRebuild = true;
        _syncOutput();
    }
    function _syncOutput() {
        if (!root.visible) { _out.dirty = true; return; }
        if (_out.queued) return;
        _out.queued = true;
        Qt.callLater(root._flushOutput);
    }
    onVisibleChanged: if (visible && _out.dirty) _syncOutput()

    function _flushOutput() {
        _out.queued = false;
        _out.dirty = false;
        const lm = root.backend ? root.backend.linesModel : null;
        if (!lm) {
            _historyEdit.text = ""; _tailEdit.text = ""; _out.tailHtml = "";
            _out.frozenLines = 0; _out.historyStart = 0; _out.batches = [];
            return;
        }
        const trimmed = root.backend.trimmedLines || 0;
        const n = lm.count;
        // Model rows [0, frozenModel) are already in the history document.
        let frozenModel = _out.frozenLines - trimmed;
        if (_out.needsRebuild || frozenModel < 0 || frozenModel > n) {
            _out.needsRebuild = false;
            _historyEdit.text = "";
            _out.frozenLines = trimmed;
            _out.historyStart = trimmed;
            _out.batches = [];
            frozenModel = 0;
        }
        // Drop what the backend has trimmed from the front: whole append
        // batches, once every line in them is gone. One remove() per batch,
        // never a rebuild.
        const batches = _out.batches;
        while (batches.length > 0 && trimmed - _out.historyStart >= batches[0].lines) {
            let chars = batches[0].chars;
            // The separator before the next batch goes too (it only exists
            // when the document was non-empty at that append).
            if (chars > 0 && batches.length > 1) { chars += 1; batches[1].chars -= 1; }
            _historyEdit.remove(0, Math.min(chars, _historyEdit.length));
            _out.historyStart += batches[0].lines;
            batches.shift();
        }
        // Freeze what is now safely behind the tail -- as ONE append per
        // flush, not one per line: QQuickTextEdit re-lays out the whole
        // document on every content change, so the cost is per call. A view
        // shown after a thousand hidden lines took 5.8s line by line, 38ms
        // in one call.
        const previewing = root.backend._previewing === true;
        const committed = previewing ? n - 1 : n;
        const frozenTarget = Math.max(0, committed - root.liveTailRows);
        if (frozenTarget > frozenModel) {
            let add = "";
            for (let i = frozenModel; i < frozenTarget; i++)
                add += (i > frozenModel ? "<br>" : "") + lm.get(i).html;
            const before = _historyEdit.length;
            _historyEdit.append(add);
            batches.push({lines: frozenTarget - frozenModel, chars: _historyEdit.length - before});
            _out.frozenLines += frozenTarget - frozenModel;
            frozenModel = frozenTarget;
        }
        // The live tail, preview included, as one small document.
        let tail = "";
        for (let i = frozenModel; i < n; i++)
            tail += (i > frozenModel ? "<br>" : "") + lm.get(i).html;
        if (_out.tailHtml !== tail) { _out.tailHtml = tail; _tailEdit.text = tail; }
        Qt.callLater(root._toTail);
    }
    // Pin the view to the tail, IF IT IS STILL FOLLOWING -- asked here, when the pin happens, and
    // not only by whoever asked for it. A flush hands this to Qt.callLater, so a call queued while
    // the reader sat at the tail runs after they have left it: the last flush of a stream would take a
    // reader who had just jumped to the top and start a glide down to the foot and cancel the
    // glide (measured: a notch's 360 settled at 6613, two runs in five).
    function _toTail() {
        if (!root._follow || root._away)
            return;
        _vk.stop();
        _scroller.contentY = Math.max(0, _scroller.contentHeight - _scroller.height);
    }
    function _clampScroll() {
        const maxX = Math.max(0, _scroller.contentWidth - _scroller.width);
        const maxY = Math.max(0, _scroller.contentHeight - _scroller.height);
        _scroller.contentX = Math.max(0, Math.min(maxX, _scroller.contentX));
        _scroller.contentY = Math.max(0, Math.min(maxY, _scroller.contentY));
    }

    // Auto-follow the tail while the view is near the bottom. The band
    // re-arms follow when the user scrolls back down, so a live stream
    // whose tail keeps moving cannot strand the flag in the off position.
    property bool _follow: true
    property real _tailBand: 60
    Connections {
        target: _scroller
        function onContentYChanged() {
            const tail = _scroller.contentHeight - _scroller.height;
            root._follow = !root._away && (tail - _scroller.contentY) <= root._tailBand;
        }
    }

    Connections {
        target: root.backend ? root.backend.linesModel : null
        ignoreUnknownSignals: true
        function onCountChanged() {
            // An emptied model (clear(), a restart) invalidates every frozen
            // line. Record it now: a hidden view only remembers `dirty`, and
            // by the time it is shown the model may already be large enough
            // that the stale frozenLines looks like a valid index.
            if (root.backend && root.backend.linesModel.count === 0) _out.needsRebuild = true;
            root._syncOutput();
        }
        function onDataChanged(topLeft, bottomRight, roles) {
            // A rewrite behind the tail: the frozen document is stale.
            const frozenModel = _out.frozenLines - (root.backend.trimmedLines || 0);
            if (topLeft && topLeft.row !== undefined && topLeft.row < frozenModel)
                _out.needsRebuild = true;
            root._syncOutput();
        }
    }
    Connections {
        target: root.backend
        ignoreUnknownSignals: true
        function onPreviewUpdated() { root._syncOutput() }
        function onStarted()        { root._rebuildOutput() }
    }
    // A different backend has a different model; nothing frozen carries over.
    onBackendChanged: _rebuildOutput()
    Component.onCompleted: _rebuildOutput()

    // NOT a negative z. An item with negative z is drawn BEHIND ITS PARENT --
    // and this parent is the opaque Rectangle that is the terminal's ground,
    // so `z: -1` would hide the backdrop completely and in silence. Declaration
    // order is what puts it under the output: first child, same z, drawn
    // first.
    Item {
        id: _backdrop
        anchors.fill: parent
    }

    // THE WHEEL, READ ONCE, ON BOTH AXES -- a MouseArea, not a WheelHandler.
    //
    // A WheelHandler listens to ONE orientation (`Qt.Vertical` unless told
    // otherwise) and never hears an event whose delta on that axis is zero, so
    // a sideways swipe with no vertical drift at all goes nowhere. It would pass
    // unnoticed while the Flickable underneath is interactive, because the
    // Flickable scrolls sideways on its own; with it passive (one reader,
    // below) sideways scrolling is left to a handler that cannot hear it.
    // Measured: 60 of 60
    // pure-x motions lost, every one with a few degrees of y delivered. This
    // is the idiom `docs/contracts/gestures.md` already prescribes.
    //
    // It sits UNDER the output, so it takes no press, no hover and no cursor
    // from the text above it: a wheel the text and the passive Flickable
    // decline falls through to it. It covers the whole terminal, so the empty
    // part of a short buffer scrolls too.
    //
    // One motion moves on one axis: see `wheelAxisRatio` above.
    WheelArea {
        id: _wheelArea
        anchors.fill: parent
        turned: wheel => {
            const ax = wheel.angleDelta.x, ay = wheel.angleDelta.y;
            const px = wheel.pixelDelta.x, py = wheel.pixelDelta.y;
            if (ax === 0 && ay === 0 && px === 0 && py === 0) {
                // The fingers lifting (or put back: ScrollBegin): both engines
                // hear it, and the one that was fed starts the coast.
                _vk.feed(0, 0, wheel.phase);
                _hk.feed(0, 0, wheel.phase);
                root._endWheelMotion();
                wheel.accepted = false;
                return;
            }
            _wheelIdle.restart();
            // A touchpad on Wayland sends both; the axis lock reads either.
            const gx = ax !== 0 ? ax : px, gy = ay !== 0 ? ay : py;
            root._wheelSumX += Math.abs(gx);
            root._wheelSumY += Math.abs(gy);
            if (root._wheelAxis === 0) {
                if (root._wheelSumY > root._wheelSumX * root.wheelAxisRatio)
                    root._wheelAxis = 1;
                else if (root._wheelSumX > root._wheelSumY * root.wheelAxisRatio)
                    root._wheelAxis = 2;
            }
            // Undecided: this event's own larger half moves.
            const axis = root._wheelAxis !== 0 ? root._wheelAxis
                       : (Math.abs(gy) >= Math.abs(gx) ? 1 : 2);
            if (axis === 1 && gy !== 0) {
                root._away = gy > 0;
                _vk.feed(py, ay * root.wheelStepMultiplier, wheel.phase);
            } else if (axis === 2 && gx !== 0 && !root.wrapLines && !root.externalGesture) {
                _hk.feed(px, ax * root.hWheelStepMultiplier, wheel.phase);
            }
            wheel.accepted = true;
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: root.contentMargin
        spacing: 6

        // Two TextEdits rather than a delegate per line: per-line delegates
        // could only ever select within one line. The frozen history selects
        // across the whole scrollback the way a terminal does; the live tail
        // underneath is the part that is still being redrawn.
        Flickable {
            id: _scroller
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            // THE WHEEL IS READ ONCE, by `_wheelArea` under the output. A
            // Flickable reads the wheel itself whenever it is `interactive`,
            // so the view would have two readers of one event: the terminal's own,
            // which knows the axis lock and the step, and the Flickable, which
            // knows neither and moves the text anyway (68 px of a swipe that
            // belongs to the view switcher, measured). Its dragging is no
            // loss either -- the output is two TextEdits that select on drag,
            // which is what a terminal does with one.
            interactive: false
            contentWidth: root.wrapLines ? width : Math.max(width, _outputCol.implicitWidth)
            contentHeight: _outputCol.implicitHeight

            // No horizontal bar even when horizontally scrollable — the
            // gesture is the affordance.
            ScrollBar.vertical: ScrollBar {
                id: termBar
                policy: ScrollBar.AsNeeded
                // A position cue only (the wheel and fingers move the text through
                // KineticScroll): a thin rounded handle in the faint ink, no track.
                implicitWidth: 6
                padding: 1
                background: null
                // A custom handle drops the style's own "only when there is something to scroll" (Basic hides it in
                // its contentItem): it shows only while the text is longer than the view.
                contentItem: Rectangle {
                    implicitWidth: 4
                    radius: 2
                    color: Theme.textFaint
                    opacity: 0.7
                    visible: termBar.size < 1.0
                }
            }

            // Keep the tail pinned through a resize of the VIEW, not only
            // through new output. The host's status card grows above this
            // view (verbose mode) and shrinks back, so the viewport gets
            // shorter and taller. Flickable clamps contentY back into range
            // on its own when the viewport grows, but when it shrinks
            // contentY simply stays put and the newest lines slide under the
            // bottom edge -- and nothing re-pinned them until the next flush.
            //
            // Both handlers fire before Flickable's own clamp (heightChanged
            // is emitted inside QQuickItem::geometryChange, ahead of the
            // fixup) and read live values, so when height and contentHeight
            // move in the same frame each lands on the tail as it stands at
            // that moment and the last one wins. `_follow` is the authority
            // -- never "was it at the bottom" derived after the fact: a
            // reader who scrolled up keeps their top-anchored place through
            // the resize; only the follower re-pins (`_toTail` asks it).
            onHeightChanged: root._toTail()
            onContentHeightChanged: root._toTail()
            // A Flickable that is not interactive does not run its own fixup
            // either, so nothing puts the content back in range when the view
            // grows or the text narrows -- the scrollback would sit past its
            // own end, showing ground. Both axes are clamped by hand, which
            // is also what KEEPS the horizontal position across a view
            // switch: clamping only ever pulls a position that is out of
            // range, so one that is still valid comes back untouched.
            onWidthChanged: root._clampScroll()
            onContentWidthChanged: root._clampScroll()

            Column {
                id: _outputCol
                width: root.wrapLines ? _scroller.width : Math.max(_scroller.width, implicitWidth)

                TextEdit {
                    id: _historyEdit
                    // contentWidth, not implicitWidth: the implicit-width path re-lays
                    // out the whole document on every content change.
                    width: root.wrapLines ? _outputCol.width : contentWidth
                    readOnly: true
                    selectByMouse: true
                    persistentSelection: true
                    activeFocusOnPress: true
                    textFormat: TextEdit.RichText
                    wrapMode: root.wrapLines ? TextEdit.Wrap : TextEdit.NoWrap
                    font.family: root.monoFamily
                    font.pixelSize: root.fontPixelSize
                    font.bold: root.fontBold
                    color: root.backend ? root.backend.defaultFg : root.textColor
                    selectionColor: root.selectionColor
                    selectedTextColor: root.selectedTextColor
                    cursorVisible: false
                }

                TextEdit {
                    id: _tailEdit
                    // contentWidth, not implicitWidth: the implicit-width path re-lays
                    // out the whole document on every content change.
                    width: root.wrapLines ? _outputCol.width : contentWidth
                    visible: text.length > 0
                    readOnly: true
                    selectByMouse: true
                    textFormat: TextEdit.RichText
                    wrapMode: root.wrapLines ? TextEdit.Wrap : TextEdit.NoWrap
                    font.family: root.monoFamily
                    font.pixelSize: root.fontPixelSize
                    font.bold: root.fontBold
                    color: root.backend ? root.backend.defaultFg : root.textColor
                    selectionColor: root.selectionColor
                    selectedTextColor: root.selectedTextColor
                    cursorVisible: false
                }
            }

        }

        Rectangle {
            Layout.fillWidth: true
            visible: root.showPromptBanner && root.backend && root.backend.awaitingInput
            color: root.backend && root.backend.passwordPrompt
                ? root.passwordBannerColor : root.promptBannerColor
            radius: 4
            implicitHeight: _promptLabel.implicitHeight + 10

            Text {
                id: _promptLabel
                anchors.fill: parent
                anchors.margins: 5
                text: (root.backend && root.backend.passwordPrompt ? "[password] " : "[prompt] ")
                    + (root.backend ? root.backend.lastPrompt : "")
                color: root.textColor
                wrapMode: Text.Wrap
                font.pixelSize: 11
            }
        }

        RowLayout {
            Layout.fillWidth: true
            visible: root.showInputRow
            spacing: 6

            TextField {
                id: _inputField
                Keys.forwardTo: [inputFieldKeys]
                EditKeys {
                    id: inputFieldKeys
                    target: _inputField
                }
                Layout.fillWidth: true
                // Always enabled. When the backend isn't running, submit is
                // a no-op — users can still type ahead and move on to the
                // next command with a ready line.
                enabled: true
                echoMode: (root.backend && root.backend.passwordPrompt)
                    ? TextInput.Password
                    : TextInput.Normal
                placeholderText: root.backend && root.backend.awaitingInput
                    ? (root.backend.passwordPrompt ? "Password…" : "Reply…")
                    : (root.backend && root.backend.running
                        ? "Type to send to child stdin"
                        : "(no process running)")
                color: root.textColor
                placeholderTextColor: Theme.textFaint
                font.family: root.monoFamily
                background: Rectangle {
                    color: root.inputFieldColor
                    border.color: _inputField.activeFocus
                        ? root.inputFocusBorderColor : root.inputBorderColor
                    border.width: 1
                    radius: 4
                }
                onAccepted: {
                    if (root.backend && root.backend.running) root.backend.submit(text);
                    text = "";
                }
                Keys.onReturnPressed: (event) => {
                    if (root.backend && root.backend.running) root.backend.submit(text);
                    text = "";
                    event.accepted = true;
                }
            }

            RaisedButton {
                text: "Send"
                surfaceColor: root.color
                fontPixelSize: 11
                horizontalPadding: 10
                minWidth: 0
                radius: 4
                shadowWidth: 3
                bevelWidth: 1
                onClicked: {
                    if (root.backend && root.backend.running) root.backend.submit(_inputField.text);
                    _inputField.text = "";
                }
            }

            RaisedButton {
                visible: root.showYesNoShortcuts
                text: "y"
                surfaceColor: root.color
                fontPixelSize: 11
                horizontalPadding: 10
                minWidth: 0
                radius: 4
                shadowWidth: 3
                bevelWidth: 1
                onClicked: { if (root.backend && root.backend.running) root.backend.submit("y"); }
            }
            RaisedButton {
                visible: root.showYesNoShortcuts
                text: "n"
                surfaceColor: root.color
                fontPixelSize: 11
                horizontalPadding: 10
                minWidth: 0
                radius: 4
                shadowWidth: 3
                bevelWidth: 1
                onClicked: { if (root.backend && root.backend.running) root.backend.submit("n"); }
            }

            RaisedButton {
                visible: root.showCopyAllButton
                text: "⧉"
                surfaceColor: root.color
                fontPixelSize: 11
                horizontalPadding: 10
                minWidth: 0
                radius: 4
                shadowWidth: 3
                bevelWidth: 1
                onClicked: root.copyAll()
            }
        }
    }

    // Invisible helper for clipboard integration. QML has no direct clipboard
    // API on Wayland-only builds, but TextEdit.copy() works with a brief
    // select-all round-trip through a hidden widget.
    TextEdit {
        id: _clipboardHelper
        visible: false
        width: 0
        height: 0
    }
}
