pragma ComponentBehavior: Bound

import QtQuick

import "PanelWords.js" as Words
import "QrCode.js" as Qr

// =============================================================================
// HotspotPanel.qml -- your own network: its name, password and band, the join QR code, the devices that joined, and Start / Stop.
// The warning when there is nothing to share (no uplink) and the plain words for what is missing (`missing`: "dnsmasq" is a program
// the sharing needs, "device" a Wi-Fi card that can host a network).
//
//   vm   an AerialService or an AerialMock
//
// The password field starts empty (a saved password is never read back into the panel: `hasPassword` says there is one); typing a new
// one and Apply writes it. "Show the code" asks `revealSecret` for the saved one -- held here only while shown (30 s, cleared on
// Hide and on destruction). A password the person just typed is what the code carries until Apply is pressed.
// =============================================================================
PanelFrame {
    id: panel

    property var vm: null
    property string secretText: ""
    property string band: "bg"

    signal dismissed()

    readonly property var hs: panel.vm ? panel.vm.hotspot : null
    readonly property bool active: !!panel.hs && panel.hs.active
    readonly property string missing: panel.hs ? panel.hs.missing : "device"
    readonly property bool wantsKeys: panel.page === "setup"
    readonly property string _shownPw: pwBlock.text !== "" ? pwBlock.text : panel.secretText
    readonly property string joinText: panel.hs && panel.hs.ssid !== "" && panel._shownPw !== ""
        ? Qr.wifiString(nameBlock.text !== "" ? nameBlock.text : panel.hs.ssid, panel._shownPw, "wpa2", false) : ""

    title: "Hotspot"
    subtitle: panel.missing === "dnsmasq" ? "Sharing needs dnsmasq."
        : panel.missing === "device" ? "No Wi-Fi card here can host a network."
        : panel.active ? "On" + (panel.hs.clients.length > 0 ? " · " + panel.hs.clients.length + (panel.hs.clients.length === 1 ? " device" : " devices") : "")
        : panel.hs && panel.hs.state === "connecting" ? "Starting" : "Off"
    subtitleTone: panel.missing !== "" ? 3 : panel.active ? 5 : 1
    tabs: [{ id: "setup", label: "Setup" }, { id: "devices", label: "Devices" }]

    function _clearSecret(): void {
        panel.secretText = "";
    }
    onPageChanged: panel._clearSecret()
    Component.onDestruction: panel._clearSecret()
    Connections {
        target: panel.vm
        function onSecret(uuid: string, text: string): void {
            if (panel.hs && uuid === panel.hs.uuid && uuid !== "")
                panel.secretText = text;
        }
    }
    Timer {
        interval: 30000
        running: panel.secretText !== ""
        onTriggered: panel._clearSecret()
    }
    function _seed(): void {
        if (!panel.hs)
            return;
        nameBlock.text = panel.hs.ssid;
        panel.band = panel.hs.band !== "" ? panel.hs.band : "bg";
    }
    Component.onCompleted: {
        panel._seed();
        if (panel.noPassword) {
            panel.suggested = panel.generate();
            pwBlock.text = panel.suggested;
        }
    }

    // ---- a hotspot with no password would be OPEN: never silently. The panel offers a generated one (14 letters and digits, none that
    // look alike: no 0 O 1 l I) and configures it BEFORE the hotspot starts; open only by the explicit, labelled button.
    readonly property bool noPassword: !!panel.hs && panel.hs.hasPassword === false && panel.missing === ""
    property bool _pendingStart: false
    property string suggested: ""
    function generate(): string {
        const a = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
        let out = "";
        for (let i = 0; i < 14; i++)
            out += a.charAt(Math.floor(Math.random() * a.length));
        return out;
    }
    onNoPasswordChanged: {
        if (panel.noPassword && pwBlock.text === "") {
            panel.suggested = panel.generate();
            pwBlock.text = panel.suggested;
        }
        if (!panel.noPassword && panel._pendingStart) {
            panel._pendingStart = false;
            if (panel.vm)
                panel.vm.startHotspot();
        }
    }
    function startNow(): void {
        if (!panel.vm)
            return;
        if (!panel.noPassword) {
            panel.vm.startHotspot();
            return;
        }
        const pw = pwBlock.text.length >= 8 ? pwBlock.text : (panel.suggested !== "" ? panel.suggested : panel.generate());
        pwBlock.text = pw;
        panel._pendingStart = true;
        panel.vm.configureHotspot({ ssid: nameBlock.text !== "" ? nameBlock.text : panel.hs.ssid, band: panel.band, password: pw });
    }
    function apply(): void {
        if (!panel.vm)
            return;
        const o = { ssid: nameBlock.text, band: panel.band };
        if (pwBlock.text !== "")
            o.password = pwBlock.text;
        panel.vm.configureHotspot(o);
    }

    PanelPage {
        look: panel.look
        pageId: "setup"
        shown: panel.page === "setup"

        PanelCard {
            look: panel.look
            PText {
                look: panel.look
                tone: 3
                width: parent.width
                wrapMode: Text.WordWrap
                shown: panel.missing !== ""
                text: panel.missing === "dnsmasq"
                    ? "Sharing needs dnsmasq, which is not installed. Install it with: sudo pacman -S dnsmasq"
                    : "This machine has no Wi-Fi card that can host a network."
            }
            PText {
                look: panel.look
                tone: 3
                width: parent.width
                wrapMode: Text.WordWrap
                shown: panel.noPassword
                text: "This hotspot has no password: anyone nearby could join. A password has been made for it; start with it, or choose it yourself below."
            }
            PText {
                look: panel.look
                tone: 3
                width: parent.width
                wrapMode: Text.WordWrap
                shown: panel.missing === "" && !!panel.hs && panel.hs.uplink === "none"
                text: "Nothing to share: plug a cable in, or the devices that join will have no internet."
            }
            ButtonRow {
                PanelButton {
                    objectName: "hotspotStart"
                    look: panel.look
                    accent: true
                    text: panel.noPassword ? "Set a password and start" : "Start hotspot"
                    visible: panel.missing === "" && !panel.active
                    enabled: !!panel.hs && panel.hs.state !== "connecting" && !panel._pendingStart
                    onClicked: panel.startNow()
                }
                PanelButton {
                    objectName: "hotspotStartOpen"
                    look: panel.look
                    text: "Start without a password (open)"
                    visible: panel.noPassword && !panel.active
                    onClicked: if (panel.vm) panel.vm.startHotspot()
                }
                PanelButton {
                    objectName: "hotspotStop"
                    look: panel.look
                    text: "Stop hotspot"
                    visible: panel.active
                    onClicked: if (panel.vm) panel.vm.stopHotspot()
                }
            }
        }
        PanelCard {
            look: panel.look
            FieldBlock {
                id: nameBlock
                look: panel.look
                label: "Network name"
                placeholder: "laptop"
                fieldObjectName: "hsName"
                onAccepted: pwBlock.field.forceFocus()
            }
            FieldBlock {
                id: pwBlock
                look: panel.look
                label: "Password"
                placeholder: panel.hs && panel.hs.hasPassword ? "unchanged" : "At least 8 characters"
                secret: true
                revealed: panel.noPassword
                fieldObjectName: "hsPassword"
                onAccepted: panel.apply()
            }
            PText { look: panel.look; text: "Band" }
            ChoiceList {
                look: panel.look
                options: [{ key: "bg", label: "2.4 GHz: reaches further" }, { key: "a", label: "5 GHz: faster" }]
                current: panel.band
                onChosen: k => panel.band = k
            }
            ButtonRow {
                PanelButton {
                    objectName: "hotspotApply"
                    look: panel.look
                    text: "Apply"
                    enabled: nameBlock.text !== "" && (pwBlock.text === "" || pwBlock.text.length >= 8)
                    onClicked: panel.apply()
                }
            }
            PText {
                look: panel.look
                tone: 1
                small: true
                width: parent.width
                // Its line is reserved (a blank one while Apply can act), so the panel never moves under the typing.
                text: nameBlock.text === "" ? "Name needed"
                    : pwBlock.text !== "" && pwBlock.text.length < 8 ? "The password needs 8 characters" : "\u00a0"
            }
        }
        PanelCard {
            look: panel.look
            PText { look: panel.look; text: "Join code" }
            ButtonRow {
                PanelButton {
                    objectName: "hotspotReveal"
                    look: panel.look
                    text: "Show the code"
                    visible: panel.secretText === "" && pwBlock.text === ""
                    enabled: !!panel.hs && panel.hs.hasPassword
                    onClicked: if (panel.vm && panel.hs) panel.vm.revealSecret(panel.hs.uuid)
                }
                PanelButton {
                    look: panel.look
                    text: "Hide"
                    visible: panel.secretText !== ""
                    onClicked: panel._clearSecret()
                }
            }
            PText {
                look: panel.look
                tone: 1
                small: true
                width: parent.width
                // Reserved while no password is saved, so typing one does not move the panel; it goes once one is saved.
                shown: !(panel.hs && panel.hs.hasPassword)
                text: panel.secretText === "" && pwBlock.text === "" ? "Save a password first" : "\u00a0"
            }
            Item {
                width: parent.width
                height: qr.visible ? qr.implicitHeight : 0
                visible: qr.visible
                QrView {
                    id: qr
                    objectName: "hotspotQr"
                    x: Math.round((parent.width - width) / 2)
                    text: panel.joinText
                    maxSize: 188
                }
            }
        }
    }

    PanelPage {
        look: panel.look
        pageId: "devices"
        shown: panel.page === "devices"

        PanelCard {
            look: panel.look
            PText {
                look: panel.look
                tone: 1
                width: parent.width
                wrapMode: Text.WordWrap
                shown: !panel.active || !panel.hs || panel.hs.clients.length === 0
                text: panel.active ? "No device has joined yet" : "Start the hotspot and the devices that join are listed here."
            }
            Repeater {
                model: panel.active && panel.hs ? panel.hs.clients.length : 0
                delegate: Item {
                    id: cl
                    required property int index
                    readonly property var c: (panel.hs ? panel.hs.clients[cl.index] : null) || ({ name: "", mac: "", ip: "", dbm: 0 })
                    width: parent.width
                    height: 34
                    PText {
                        look: panel.look
                        width: parent.width - sig.implicitWidth - 8
                        elide: Text.ElideRight
                        text: cl.c.name !== "" ? cl.c.name : cl.c.mac
                    }
                    PText {
                        look: panel.look
                        tone: 1
                        small: true
                        y: 17
                        text: cl.c.ip + " · " + cl.c.mac
                    }
                    PText {
                        id: sig
                        look: panel.look
                        tone: 1
                        small: true
                        x: parent.width - implicitWidth
                        text: Words.dbm(cl.c.dbm)
                    }
                }
            }
        }
    }
}
