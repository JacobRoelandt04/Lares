pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../data/SiliconFormat.js" as Fmt

// =============================================================================
// ConfirmPanel.qml -- "apps are using the dGPU": the question a GPU step that would block the card asks first, the
// content of the secondary the popup opens for it (SiliconSecondary kind "confirm").
//
// Integrated and Smart stop NEW apps from opening the dGPU (cardwire blocks only new opens, so the apps already on
// it keep running). The service refuses such a step while apps hold the card unless it is confirmed; the popup asks
// here, naming the apps:
//
//   Apps are using the dGPU
//   In use: steam, proton
//   Integrated stops new apps from using it. The ones running keep it until they exit.
//                                                      [ Cancel ]  [ Switch to Integrated ]
//
// What holds the card is what would keep it awake: the session's own processes (Hyprland, Xwayland, Xorg, systemd,
// systemd-logind) are not in the list (CardwireParse.SESSION_HOLDERS).
//
// The accent button ("Switch to <mode>") -> `confirmed()`, Cancel -> `cancelled()`; the popup decides what they do (setGpuMode with
// confirmHolders / nothing) and closes the secondary on both, as it does on a click elsewhere in the popup and when
// the apps have gone.
// =============================================================================
Item {
    id: panel

    property SecondaryStyle look: SecondaryStyle {}
    property var holders: []
    property int step: 0                      // the GPU step it is asked for (0 Integrated, 1 Smart)

    signal confirmed()
    signal cancelled()

    // An answer is given ONCE (the secondary fades out for a moment after the click, and a second click on a button that is going away
    // must not answer again): dead for 700 ms after either.
    property bool _answered: false
    Timer {
        id: answeredReset
        interval: 700
        onTriggered: panel._answered = false
    }

    readonly property string modeName: Fmt.gpuStepLabel(panel.step)
    readonly property string appsText: {
        const h = panel.holders || [];
        if (h.length === 0)
            return "";
        if (h.length <= 4)
            return "In use: " + h.join(", ");
        return "In use: " + h.slice(0, 3).join(", ") + " and " + (h.length - 3) + " more";
    }

    readonly property real _pad: panel.look.padding
    implicitWidth: panel.look.dialogWidth
    implicitHeight: Math.ceil(panel._pad + titleText.height + 6 + appsLabel.height + 6 + hint.height + panel.look.gap + buttons.height + panel._pad)

    Text {
        id: titleText
        objectName: "dialogTitle"
        x: panel._pad
        y: panel._pad
        width: panel.width - 2 * panel._pad
        text: "Apps are using the dGPU"
        color: Theme.textPrimary
        elide: Text.ElideRight
        font.family: panel.look.fontFamily
        font.pixelSize: panel.look.titleSize
        font.bold: true
    }
    Text {
        id: appsLabel
        objectName: "confirmApps"
        x: panel._pad
        y: titleText.y + titleText.height + 6
        width: panel.width - 2 * panel._pad
        text: panel.appsText
        color: Theme.textPrimary
        elide: Text.ElideRight
        font.family: panel.look.fontFamily
        font.pixelSize: panel.look.bodySize
    }
    Text {
        id: hint
        objectName: "dialogBody"
        x: panel._pad
        y: appsLabel.y + appsLabel.height + 6
        width: panel.width - 2 * panel._pad
        text: panel.modeName + " stops new apps from using it. The ones running keep it until they exit."
        color: Theme.textMuted
        wrapMode: Text.WordWrap
        font.family: panel.look.fontFamily
        font.pixelSize: panel.look.figureSize
    }
    Row {
        id: buttons
        x: panel.width - panel._pad - width
        y: hint.y + hint.height + panel.look.gap
        spacing: 8
        FlowButton {
            id: cancelBtn
            objectName: "cancelButton"
            text: "Cancel"
            fontFamily: panel.look.fontFamily
            fontPixelSize: panel.look.figureSize + 1
            enabled: !panel._answered
            onClicked: {
                panel._answered = true;
                answeredReset.restart();
                panel.cancelled();
            }
        }
        FlowButton {
            id: confirmBtn
            objectName: "confirmButton"
            text: "Switch to " + panel.modeName
            accent: true
            fontFamily: panel.look.fontFamily
            fontPixelSize: panel.look.figureSize + 1
            enabled: !panel._answered
            onClicked: {
                panel._answered = true;
                answeredReset.restart();
                panel.confirmed();
            }
        }
    }

    // for the probes: the centres of the two buttons in this panel's own coordinates
    function confirmCentre() {
        return confirmBtn.mapToItem(panel, confirmBtn.width / 2, confirmBtn.height / 2);
    }
    function cancelCentre() {
        return cancelBtn.mapToItem(panel, cancelBtn.width / 2, cancelBtn.height / 2);
    }
}
