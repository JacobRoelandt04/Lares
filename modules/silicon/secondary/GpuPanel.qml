pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "TuningModel.js" as TM

// =============================================================================
// GpuPanel.qml -- cardwire's settings, the content of the secondary a click on the card opens
// (SiliconSecondary kind "gpu").
//
//   Switching   what cardwire does by itself: Integrated on battery (and the mode it returns to on
//               the charger), Hybrid while an external display is on a port wired to the dGPU,
//               the experimental NVIDIA block -- every switch writes through
//               `vm.setCardwireConfig(key, value)` and is bound to the FACT, so a refused write
//               leaves it where it was and the caption says why
//   Smart apps  the list cardwire keeps for Smart mode (AppPolicyList): allowed or blocked, and
//               "Never ask again" for a blocked one
//
// The words of each hint are cardwire's own documentation (opengamingcollective.github.io/cardwire,
// "Configuration"): battery auto switch "switches to integrated mode on battery and
// back to a configurable mode when on AC power" (so the mode setting is the CHARGER's mode, not the
// battery's); external display auto switch "temporarily switch Integrated and Smart modes to Hybrid"
// while a display is on a port wired directly to the dGPU; the experimental NVIDIA block blocks
// "specific Nvidia files, such as /dev/nvidiactl" and "only works reliably on systems with exactly two
// GPUs". The external-display switch may not work upstream (PLAN.md).
// =============================================================================
Item {
    id: panel

    property var vm: null
    property SecondaryStyle look: SecondaryStyle {}
    property Item overlay: null
    property real panelWidth: 400

    readonly property var _noGpu: ({
        present: false, why: "", modes: [],
        config: { batteryAutoSwitch: false, batteryAutoSwitchMode: 0, externalDisplayAutoSwitch: false, nvidiaBlock: false }
    })
    readonly property var gpu: panel.vm && panel.vm.gpu ? panel.vm.gpu : panel._noGpu
    readonly property var cfg: panel.gpu.config

    // The modes the daemon offers, as a key string: a TabSelector regenerates its tabs when `tabs`
    // is reassigned, and `vm.gpu` is a new object every second.
    readonly property string _modeKey: panel.gpu.modes.join("|") + "#" + panel.cfg.batteryAutoSwitchMode
    readonly property var _modeTabs: {
        const parts = panel._modeKey.split("#");
        const modes = parts[0] === "" ? [] : parts[0].split("|").map(Number);
        return TM.modeTabs(modes, Number(parts[1]));
    }

    // Returns whether the service took it; a refusal has already put its words in the caption.
    function config(key, value) {
        return panel.vm ? panel.vm.setCardwireConfig(key, value) === true : false;
    }

    FontMetrics {
        id: bodyMetrics
        font.family: panel.look.fontFamily
        font.pixelSize: panel.look.bodySize
    }
    readonly property real _lineH: Math.ceil(bodyMetrics.height) + 2
    // the air between a line of text and the control it names (CLAUDE.md "gap text to rail")
    readonly property real gapText: 6

    implicitWidth: panel.panelWidth
    implicitHeight: Math.ceil(column.implicitHeight + 2 * panel.look.padding)

    Column {
        id: column
        x: panel.look.padding
        y: panel.look.padding
        width: panel.panelWidth - 2 * panel.look.padding
        spacing: panel.look.gap

        Item {
            id: header
            width: column.width
            height: 30
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "GPU settings"
                color: Theme.textPrimary
                font.family: panel.look.fontFamily
                font.pixelSize: panel.look.titleSize
                font.bold: true
            }
        }

        // ---- no cardwire: the one sentence that says why ------------------------------------------------
        PanelCard {
            id: absent
            objectName: "gpuAbsent"
            look: panel.look
            width: column.width
            visible: !panel.gpu.present
            height: visible ? implicitHeight : 0
            Text {
                width: parent.width
                visible: absent.visible
                text: panel.gpu.why !== "" ? "GPU settings need cardwire: " + panel.gpu.why : "GPU settings need cardwire"
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: Theme.textMuted
                font.family: panel.look.fontFamily
                font.pixelSize: panel.look.bodySize
            }
        }

        // ---- the switches -------------------------------------------------------------------------------------
        PanelCard {
            id: switching
            objectName: "switchCard"
            look: panel.look
            width: column.width
            visible: panel.gpu.present
            height: visible ? implicitHeight : 0

            Item {
                id: batteryBlock
                width: parent.width
                height: batteryRow.height + (modes.visible ? panel.gapText + modes.height : 0)

                SwitchRow {
                    id: batteryRow
                    objectName: "rowBattery"
                    look: panel.look
                    overlay: panel.overlay
                    width: batteryBlock.width
                    title: "Integrated on battery"
                    tip: "When the charger is unplugged cardwire\n"
                        + "switches to Integrated, and back to the\n"
                        + "mode below when it returns."
                    hint: panel.cfg.batteryAutoSwitch ? "Back on the charger it returns to:" : "Turn this on to choose the mode"
                    checked: panel.cfg.batteryAutoSwitch
                    onToggled: c => panel.config("batteryAutoSwitch", c)
                }
                PanelTabs {
                    id: modes
                    objectName: "modeTabs"
                    look: panel.look
                    y: batteryRow.height + panel.gapText
                    width: batteryBlock.width
                    // nothing to choose from (the daemon listed no mode): no empty track
                    visible: panel._modeTabs.length > 0
                    height: visible ? 30 : 0
                    tabs: panel._modeTabs
                    // Locked, not removed, while the switch is off: the block keeps its height.
                    locked: !panel.cfg.batteryAutoSwitch
                    fontPixelSize: panel.look.bodySize
                    trackRadiusOverride: 10
                    onTabChanged: id => {
                        if (Number(id) !== panel.cfg.batteryAutoSwitchMode && !panel.config("batteryAutoSwitchMode", Number(id)))
                            modes.currentTab = String(panel.cfg.batteryAutoSwitchMode);
                    }
                }
                // TabSelector assigns its own `currentTab` on a click: bound with a Binding.
                Binding {
                    target: modes
                    property: "currentTab"
                    value: String(panel.cfg.batteryAutoSwitchMode)
                }
            }

            SwitchRow {
                id: externalRow
                objectName: "rowExternal"
                look: panel.look
                overlay: panel.overlay
                width: parent.width
                title: "Hybrid with an external display"
                tip: "While a monitor is plugged into a port\n"
                    + "wired straight to the dGPU, cardwire\n"
                    + "switches Integrated and Smart to Hybrid,\n"
                    + "and restores the mode when it goes."
                hint: "Upstream's detection is unfinished, so it may not work."
                checked: panel.cfg.externalDisplayAutoSwitch
                onToggled: c => panel.config("externalDisplayAutoSwitch", c)
            }

            SwitchRow {
                id: nvidiaRow
                objectName: "rowNvidia"
                look: panel.look
                overlay: panel.overlay
                width: parent.width
                title: "NVIDIA block (experimental)"
                tip: "Also blocks the NVIDIA files the two GPUs\n"
                    + "share, such as /dev/nvidiactl, which nvtop\n"
                    + "and Vulkan apps open without using the card.\n"
                    + "Reliable only with exactly one integrated\n"
                    + "and one NVIDIA GPU."
                hint: "Keeps nvtop and Vulkan apps from waking the card."
                checked: panel.cfg.nvidiaBlock
                onToggled: c => panel.config("nvidiaBlock", c)
            }
        }

        // ---- Smart mode's apps ---------------------------------------------------------------------------------
        Item {
            id: appsBlock
            objectName: "appsBlock"
            width: column.width
            visible: panel.gpu.present
            height: visible ? panel._lineH + panel.gapText + apps.implicitHeight : 0

            TipLabel {
                look: panel.look
                overlay: panel.overlay
                text: "Smart mode apps"
                tip: "Smart mode keeps the dGPU blocked for every\n"
                    + "app except the ones allowed here. \"Never ask\n"
                    + "again\" stops the notice that offers to allow\n"
                    + "a blocked app."
                maxWidth: appsBlock.width
                anchors.verticalCenter: appsHead.verticalCenter
            }
            Item {
                id: appsHead
                width: appsBlock.width
                height: panel._lineH
            }
            AppPolicyList {
                id: apps
                objectName: "appPolicies"
                y: panel._lineH + panel.gapText
                width: appsBlock.width
                height: implicitHeight
                vm: panel.vm
                look: panel.look
                overlay: panel.overlay
            }
        }
    }
}
