pragma ComponentBehavior: Bound

import QtQuick

import "PanelWords.js" as Words

// =============================================================================
// BtDevicePanel.qml -- one Bluetooth device (a figure of the rings): the basics (connect, pair / cancel, trust, block, forget,
// rename, address, kind, signal), the battery in detail (left / right / case, charging) and the audio profile (A2DP hi-fi against
// the headset profile, the codec in use).
//
//   vm         an AerialService or an AerialMock
//   targetKey  the device's address
//
// THE PAIRING PROMPT. While `vm.bt.prompt` is THIS device's, a card heads the Device page and the panel says what BlueZ asks:
// confirm ("Does 482 913 match?" -> Yes / No), pin and passkey (a field to type it into; Enter answers), display (the code to type
// on the other device; only Cancel), authorize (Allow / Deny). Every answer is `vm.btAnswer(rid, accept, value)`; the value is typed
// into the field and held nowhere else.
// =============================================================================
PanelFrame {
    id: panel

    property var vm: null
    property string targetKey: ""

    signal dismissed()

    readonly property var bt: panel.vm ? panel.vm.bt : null
    onDevChanged: btForgetButton.disarm()   // the arm belongs to one device
    readonly property var dev: {
        const l = panel.bt ? panel.bt.devices : [];
        for (let i = 0; i < l.length; i++)
            if (l[i].address === panel.targetKey)
                return l[i];
        return null;
    }
    readonly property var prompt: panel.bt && panel.bt.prompt && panel.dev && panel.bt.prompt.address === panel.dev.address ? panel.bt.prompt : null
    readonly property string promptKind: panel.prompt ? panel.prompt.kind : ""
    readonly property bool typing: panel.promptKind === "pin" || panel.promptKind === "passkey"
    readonly property bool wantsKeys: panel.typing
    readonly property bool hasBattery: !!panel.dev && (panel.dev.battery >= 0 || !!panel.dev.parts)

    title: panel.dev ? (panel.dev.name !== "" ? panel.dev.name : panel.dev.address) : "Bluetooth device"
    subtitle: !panel.dev ? "This device is not around any more."
        : panel.dev.pairing ? "Pairing"
        : panel.dev.blocked ? "Blocked"
        : panel.dev.connected ? "Connected" + (panel.dev.battery >= 0 ? " · " + panel.dev.battery + " %" : "")
        : panel.dev.paired ? "Paired, not connected" : "Heard nearby"
    subtitleTone: !panel.dev ? 3 : panel.dev.connected ? 5 : 1

    tabs: {
        const t = [{ id: "device", label: "Device" }];
        if (panel.hasBattery)
            t.push({ id: "battery", label: "Battery" });
        if (panel.dev && panel.dev.profile)
            t.push({ id: "audio", label: "Audio" });
        return t;
    }
    onTabsChanged: {
        for (let i = 0; i < panel.tabs.length; i++)
            if (panel.tabs[i].id === panel.page)
                return;
        panel.page = "device";
    }
    onPromptChanged: {
        if (panel.prompt)
            panel.page = "device";
        pinTimer.restart();
    }
    Timer {
        id: pinTimer
        interval: 0
        onTriggered: {
            if (panel.typing)
                pinBlock.field.forceFocus();
        }
    }
    Component.onCompleted: pinTimer.restart()
    function answer(accept: bool): void {
        if (!panel.vm || !panel.prompt)
            return;
        panel.vm.btAnswer(panel.prompt.rid, accept, accept && panel.typing ? pinBlock.text : "");
        pinBlock.field.clear();
    }

    PanelPage {
        look: panel.look
        pageId: "device"
        shown: panel.page === "device"

        // ---- the pairing prompt
        PanelCard {
            look: panel.look
            visible: !!panel.prompt
            PText {
                look: panel.look
                strong: true
                width: parent.width
                wrapMode: Text.WordWrap
                text: panel.promptKind === "confirm" ? "Does " + Words.code3(panel.prompt ? panel.prompt.code : "") + " match?"
                    : panel.promptKind === "display" ? "Type " + Words.code3(panel.prompt ? panel.prompt.code : "") + " on " + (panel.dev ? panel.dev.name : "the device")
                    : panel.promptKind === "authorize" ? "Allow " + (panel.dev ? panel.dev.name : "this device") + " to connect?"
                    : panel.promptKind === "passkey" ? "Type the passkey"
                    : "Type the PIN"
            }
            PText {
                look: panel.look
                tone: 1
                small: true
                width: parent.width
                wrapMode: Text.WordWrap
                text: panel.promptKind === "confirm" ? "Compare it with the number " + (panel.dev ? panel.dev.name : "the device") + " shows."
                    : panel.promptKind === "display" ? "Pairing finishes when it has been typed there."
                    : panel.typing ? "The device shows it, or its manual says: often 0000." : ""
                shown: text !== ""
            }
            FieldBlock {
                id: pinBlock
                look: panel.look
                label: panel.promptKind === "passkey" ? "Passkey" : "PIN"
                shown: panel.typing
                fieldObjectName: "pinField"
                inputMethodHints: Qt.ImhDigitsOnly
                onAccepted: panel.answer(true)
                Connections {
                    target: pinBlock.field
                    function onEscaped(): void {
                        panel.dismissed();
                    }
                }
            }
            ButtonRow {
                PanelButton {
                    objectName: "promptYes"
                    look: panel.look
                    accent: true
                    text: panel.promptKind === "confirm" ? "Yes" : panel.promptKind === "authorize" ? "Allow" : "OK"
                    visible: panel.promptKind !== "display"
                    enabled: !panel.typing || pinBlock.text !== ""
                    onClicked: panel.answer(true)
                }
                PanelButton {
                    objectName: "promptNo"
                    look: panel.look
                    text: panel.promptKind === "confirm" ? "No" : panel.promptKind === "authorize" ? "Deny" : "Cancel"
                    onClicked: {
                        if (panel.promptKind === "display" || panel.typing) {
                            if (panel.vm && panel.dev)
                                panel.vm.btCancelPair(panel.dev.address);
                        } else {
                            panel.answer(false);
                        }
                    }
                }
            }
        }

        // ---- connect, pair, forget
        PanelCard {
            look: panel.look
            ButtonRow {
                PanelButton {
                    objectName: "btConnect"
                    look: panel.look
                    accent: true
                    text: "Connect"
                    visible: !!panel.dev && panel.dev.paired && !panel.dev.connected && !panel.dev.blocked
                    onClicked: if (panel.vm) panel.vm.btConnect(panel.dev.address)
                }
                PanelButton {
                    objectName: "btDisconnect"
                    look: panel.look
                    text: "Disconnect"
                    visible: !!panel.dev && panel.dev.connected
                    onClicked: if (panel.vm) panel.vm.btDisconnect(panel.dev.address)
                }
                PanelButton {
                    objectName: "btPair"
                    look: panel.look
                    accent: true
                    text: "Pair"
                    visible: !!panel.dev && !panel.dev.paired && !panel.dev.pairing && !panel.dev.blocked
                    onClicked: if (panel.vm) panel.vm.btPair(panel.dev.address)
                }
                PanelButton {
                    objectName: "btCancelPair"
                    look: panel.look
                    text: "Cancel pairing"
                    visible: !!panel.dev && panel.dev.pairing && !panel.prompt
                    onClicked: if (panel.vm) panel.vm.btCancelPair(panel.dev.address)
                }
                ForgetButton {
                    id: btForgetButton
                    objectName: "btForget"
                    look: panel.look
                    live: !!panel.dev
                    visible: !!panel.dev && panel.dev.paired
                    onForgetRequested: if (panel.vm) panel.vm.btForget(panel.dev.address)
                }
            }
            SwitchRow {
                objectName: "btTrust"
                look: panel.look
                title: "Trusted"
                hint: "A trusted device connects by itself."
                checked: !!panel.dev && panel.dev.trusted
                onToggled: c => {
                    if (panel.vm && panel.dev)
                        panel.vm.btTrust(panel.dev.address, c);
                }
            }
            SwitchRow {
                objectName: "btBlock"
                look: panel.look
                title: "Blocked"
                hint: "A blocked device cannot connect or pair."
                checked: !!panel.dev && panel.dev.blocked
                onToggled: c => {
                    if (panel.vm && panel.dev)
                        panel.vm.btBlock(panel.dev.address, c);
                }
            }
        }
        PanelCard {
            look: panel.look
            visible: !!panel.dev && panel.dev.paired
            FieldBlock {
                id: nameBlock
                look: panel.look
                label: "Name"
                placeholder: panel.dev ? panel.dev.name : ""
                fieldObjectName: "btName"
                onAccepted: panel.rename()
            }
            ButtonRow {
                PanelButton {
                    objectName: "btRename"
                    look: panel.look
                    text: "Rename"
                    enabled: nameBlock.text.trim() !== ""
                    onClicked: panel.rename()
                }
            }
        }
        PanelCard {
            look: panel.look
            FactRow { look: panel.look; label: "Address"; value: panel.dev ? panel.dev.address : "" }
            FactRow { look: panel.look; label: "Kind"; value: panel.dev ? Words.btKind(panel.dev.kind) : "" }
            FactRow { look: panel.look; label: "Status"; value: panel.dev ? Words.btRing(panel.dev.ring) : "" }
            FactRow { look: panel.look; label: "Signal"; value: panel.dev ? Words.dbm(panel.dev.rssi) : "" }
        }
    }
    function rename(): void {
        const t = nameBlock.text.trim();
        if (t === "" || !panel.vm || !panel.dev)
            return;
        panel.vm.btRename(panel.dev.address, t);
        nameBlock.field.clear();
    }

    PanelPage {
        look: panel.look
        pageId: "battery"
        shown: panel.page === "battery"

        PanelCard {
            look: panel.look
            FactRow { look: panel.look; label: "Battery"; value: panel.dev && !panel.dev.parts && panel.dev.battery >= 0 ? panel.dev.battery + " %" : "" }
            FactRow {
                look: panel.look
                label: "Left earbud"
                value: panel.dev && panel.dev.parts && panel.dev.parts.left >= 0 ? panel.dev.parts.left + " %" : ""
            }
            FactRow {
                look: panel.look
                label: "Right earbud"
                value: panel.dev && panel.dev.parts && panel.dev.parts.right >= 0 ? panel.dev.parts.right + " %" : ""
            }
            FactRow {
                look: panel.look
                label: "Case"
                value: panel.dev && panel.dev.parts && panel.dev.parts.case >= 0 ? panel.dev.parts.case + " %" : ""
            }
            FactRow {
                look: panel.look
                label: "Charging"
                value: panel.dev && panel.dev.parts ? (panel.dev.parts.charging ? "Yes" : "No") : ""
            }
        }
    }

    PanelPage {
        look: panel.look
        pageId: "audio"
        shown: panel.page === "audio"

        PanelCard {
            look: panel.look
            PText { look: panel.look; text: "Audio profile" }
            ChoiceList {
                look: panel.look
                options: panel.dev && panel.dev.profile ? panel.dev.profile.available.map(k => ({ key: k, label: panel._profileLabel(k) })) : []
                current: panel.dev && panel.dev.profile ? panel.dev.profile.active : ""
                onChosen: k => {
                    if (panel.vm && panel.dev)
                        panel.vm.btSetProfile(panel.dev.address, k);
                }
            }
            PText {
                look: panel.look
                tone: 1
                small: true
                width: parent.width
                wrapMode: Text.WordWrap
                text: "High fidelity sounds best; the headset profile turns the microphone on and sounds worse."
            }
            FactRow { look: panel.look; label: "Codec"; value: panel.dev && panel.dev.profile ? String(panel.dev.profile.codec).toUpperCase() : "" }
        }
    }
    function _profileLabel(k: string): string {
        if (k === "a2dp-sink" || k.indexOf("a2dp") === 0)
            return "High fidelity (A2DP)";
        if (k.indexOf("headset") === 0 || k.indexOf("hfp") >= 0 || k.indexOf("hsp") >= 0)
            return "Headset (microphone on)";
        return k;
    }
}
