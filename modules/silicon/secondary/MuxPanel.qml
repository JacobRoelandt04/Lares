pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../popup/MuxFlow.js" as Flow

// =============================================================================
// MuxPanel.qml -- the restart a dGPU-only (or way-back) MUX request waits for, the content of the secondary the popup
// opens for it (SiliconSecondary kind "mux").
//
// While a request is waiting for its restart (`vm.gpu.mux.state` is `queued`) the popup keeps `muxWanted` true: it opens
// this by itself once the step that asked has settled, and a click on the GPU card or its slot opens it instead of
// the GPU panel. It says what the restart does, in the user's words, by what is waiting (MuxFlow.muxCardCopy):
//
//   dGPU only needs a restart        the screen comes back on the NVIDIA card; two minutes to keep it
//   Integrated needs a restart       the way back, and where the laptop ENDS: the mode asked for after it (`mux.afterMode`:
//   Smart ... / Hybrid ...           0 Integrated, 1 Smart, 2 or none Hybrid), nothing to confirm afterwards (no guard);
//                                    the words follow the facts live, so a step taken under the open panel re-words it
//   dGPU only cannot go ahead        the pre-checks now refuse it (`prechecks.why`): only "Cancel"
//
//                                   [ Cancel ]  [ Later ]  [ Restart now ]
//
// Restart now -> `vm.muxRebootNow()` (the service restarts the machine; the helper's unit applies the request at
// shutdown), Later -> `dismissed()` (the request stays), Cancel -> `vm.muxCancel()` (it withdraws the whole request). The popup closes the
// secondary on `dismissed()`, on a click elsewhere in the popup (its own rule) and when the request is gone.
// `applied` (written at shutdown, waiting for the boot guard) is not `wanted`: nothing is the user's to do, and the
// zone's caption already says "after the next restart".
// =============================================================================
Item {
    id: panel

    property var vm: null
    property SecondaryStyle look: SecondaryStyle {}

    signal dismissed()

    // An answer is given ONCE: the secondary fades out for a moment after the click (and may be turned round if it is asked for
    // again), and a second click on a button that is going away must not cancel a request that is already cancelled (the helper
    // would refuse it and the GPU zone would show why). Dead for 700 ms after any answer.
    property bool _answered: false
    Timer {
        id: answeredReset
        interval: 700
        onTriggered: panel._answered = false
    }
    function _answer() {
        panel._answered = true;
        answeredReset.restart();
    }

    // ---- the facts, and the words they make ----
    readonly property var _mux: panel.vm && panel.vm.gpu ? panel.vm.gpu.mux : null
    readonly property bool wanted: !!panel._mux && panel._mux.state === "queued"
    // the prompt's window, in the words of the card: the helper's constant, a fact (a root helper reads no config)
    readonly property int _keepSeconds: panel._mux ? panel._mux.promptWindowS : 0
    readonly property var copy: Flow.muxCardCopy(panel._mux, panel._keepSeconds)
    readonly property string kind: panel.copy.kind
    readonly property string title: panel.copy.title
    readonly property string body: panel.copy.body

    // ---- layout: arithmetic from the padding and the panel's own width, never from what it contains ----
    readonly property real _pad: panel.look.padding
    implicitWidth: panel.look.dialogWidth
    implicitHeight: Math.ceil(panel._buttonsY + panel._pos.h + panel._pad)

    readonly property real _gap: 8
    // (the hint's own implicit height, never `height`: a Text whose height follows its implicit height is a loop)
    readonly property real _buttonsY: Math.ceil(panel._pad + titleLabel.height + 6 + bodyLabel.height
                                                + (panel.copy.hint === "" ? 0 : 6 + hintLabel.implicitHeight) + panel.look.gap)

    // Where the buttons go: ONE row, right-aligned under the same edge as the text, in the order the sentence reads
    // (Cancel withdraws the request, Later leaves it, the default answer sits on the accent at the end). A button the
    // card does not offer takes no room, so the refused case is Cancel alone at the right edge. Cancel, Later and
    // Restart now are about 230 px of Inter's buttons at 12 px and the panel has 276 (Audiowide too: it fits the
    // panel in both faces).
    readonly property var _pos: {
        const wl = panel.copy.later ? laterBtn.implicitWidth : 0;
        const wr = panel.copy.restart ? restartBtn.implicitWidth : 0;
        const wc = panel.copy.cancel ? cancelBtn.implicitWidth : 0;
        let x = panel.width - panel._pad;
        const restartX = x - wr;
        x = restartX - (wr > 0 ? panel._gap : 0);
        const laterX = x - wl;
        x = laterX - (wl > 0 ? panel._gap : 0);
        return {
            restartX: restartX,
            laterX: laterX,
            cancelX: x - wc,
            h: wl > 0 || wr > 0 || wc > 0 ? 28 : 0
        };
    }

    Text {
        id: titleLabel
        objectName: "dialogTitle"
        x: panel._pad
        y: panel._pad
        width: panel.width - 2 * panel._pad
        text: panel.title
        color: Theme.textPrimary
        elide: Text.ElideRight
        font.family: panel.look.fontFamily
        font.pixelSize: panel.look.titleSize
        font.bold: true
    }
    Text {
        id: bodyLabel
        objectName: "dialogBody"
        x: panel._pad
        y: titleLabel.y + titleLabel.height + 6
        width: panel.width - 2 * panel._pad
        text: panel.body
        // the pre-checks' own words are the news there; elsewhere the body is the explanation
        color: panel.kind === "blocked" ? Theme.textPrimary : Theme.textMuted
        wrapMode: Text.WordWrap
        font.family: panel.look.fontFamily
        font.pixelSize: panel.kind === "blocked" ? panel.look.bodySize : panel.look.figureSize
    }
    Text {
        id: hintLabel
        x: panel._pad
        y: bodyLabel.y + bodyLabel.height + 6
        width: panel.width - 2 * panel._pad
        visible: panel.copy.hint !== ""
        text: panel.copy.hint
        color: Theme.textMuted
        wrapMode: Text.WordWrap
        font.family: panel.look.fontFamily
        font.pixelSize: panel.look.figureSize
    }

    FlowButton {
        id: cancelBtn
        objectName: "cancelRequestButton"
        x: panel._pos.cancelX
        y: panel._buttonsY
        visible: panel.copy.cancel
        text: "Cancel"
        fontFamily: panel.look.fontFamily
        fontPixelSize: panel.look.figureSize + 1
        enabled: !panel._answered
        onClicked: {
            panel._answer();
            if (panel.vm)
                panel.vm.muxCancel();
            panel.dismissed();
        }
    }
    FlowButton {
        id: laterBtn
        objectName: "laterButton"
        x: panel._pos.laterX
        y: panel._buttonsY
        visible: panel.copy.later
        text: "Later"
        fontFamily: panel.look.fontFamily
        fontPixelSize: panel.look.figureSize + 1
        enabled: !panel._answered
        onClicked: {
            panel._answer();
            panel.dismissed();
        }
    }
    FlowButton {
        id: restartBtn
        objectName: "restartButton"
        x: panel._pos.restartX
        y: panel._buttonsY
        visible: panel.copy.restart
        text: "Restart now"
        accent: true
        fontFamily: panel.look.fontFamily
        fontPixelSize: panel.look.figureSize + 1
        enabled: panel.wanted && !panel._answered
        onClicked: {
            panel._answer();
            if (panel.vm)
                panel.vm.muxRebootNow();
            panel.dismissed();
        }
    }

    // for the probes: the centres of the buttons in this panel's own coordinates
    function restartCentre() {
        return restartBtn.mapToItem(panel, restartBtn.width / 2, restartBtn.height / 2);
    }
    function laterCentre() {
        return laterBtn.mapToItem(panel, laterBtn.width / 2, laterBtn.height / 2);
    }
    function cancelCentre() {
        return cancelBtn.mapToItem(panel, cancelBtn.width / 2, cancelBtn.height / 2);
    }
}
