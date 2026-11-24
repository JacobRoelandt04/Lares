pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../../common/theme"
import "PanelWords.js" as Words
import "QrCode.js" as Qr

// =============================================================================
// NetworkPanel.qml -- the detail panel of ONE Wi-Fi network (a hologram of the dome, or the one docked on the label): what the
// network is, Connect / Disconnect (no drag is ever required), the password, Trusted / Public, and the advanced pages.
//
//   vm         an AerialService or an AerialMock; the panel READS facts and CALLS intents, nothing else
//   targetKey  the network's `key` ("" = the docked one); a `hidden:<bssid>` key is a hidden access point and asks its name first
//
// Pages (tabs, only the ones that mean something for this network): Info (state, password, the facts, Trusted), Login (an
// enterprise network: PEAP / TTLS form; EAP-TLS opens nm-connection-editor), IP & DNS, Privacy, Radio (every access point of the
// name: lock to a band or one of them), Share (the password on request and the join QR code). A network not joined yet has Info and
// Radio only: the rest are the profile's, and the profile does not exist yet.
//
// SECRETS. The password field is focused when the network `needsSecret` (Enter connects; a password the network refuses shakes the
// field and KEEPS it; Escape gives up -> `dismissed()`). A revealed password (`secretText`, from `vm.secret`) lives in this panel
// only, is cleared when the page is left, after 30 s and when the panel is destroyed, and is never written anywhere else.
// =============================================================================
PanelFrame {
    id: panel

    property var vm: null
    property string targetKey: ""
    // the file picker and the connection editor are programs: probes put stand-ins here
    property var pickerCommand: ["zenity", "--file-selection", "--title=CA certificate", "--file-filter=Certificates | *.pem *.crt *.cer *.der"]
    property var editorCommand: ["nm-connection-editor"]
    property int editorOpened: 0

    signal dismissed()

    // ---- the facts ----------------------------------------------------------------------------------------------------------------
    readonly property var wifi: panel.vm ? panel.vm.wifi : null
    readonly property string key: panel.targetKey !== "" ? panel.targetKey : (panel.wifi && panel.wifi.active ? panel.wifi.active.key : "")
    readonly property var net: {
        const l = panel.wifi ? panel.wifi.networks : [];
        for (let i = 0; i < l.length; i++)
            if (l[i].key === panel.key)
                return l[i];
        return null;
    }
    readonly property var profiles: {
        const out = [];
        if (!panel.net || !panel.wifi)
            return out;
        const l = panel.wifi.profiles;
        for (let i = 0; i < l.length; i++)
            if (panel.net.profileUuids.indexOf(l[i].uuid) >= 0)
                out.push(l[i]);
        return out;
    }
    readonly property var prof: panel.profiles.length > 0 ? panel.profiles[0] : null
    readonly property string uuid: panel.prof ? panel.prof.uuid : ""
    // the profile's band / access-point lock: the record may not carry them (the contract's Profile lists neither), so the panel keeps the last choice
    property string localBand: ""
    property string localBssid: ""
    readonly property string bandLock: panel.prof && panel.prof.band !== undefined ? String(panel.prof.band) : panel.localBand
    readonly property string bssidLock: panel.prof && panel.prof.bssid !== undefined ? String(panel.prof.bssid) : panel.localBssid
    onKeyChanged: {
        panel.localBand = "";
        panel.localBssid = "";
    }
    readonly property var active: panel.net && panel.net.connected && panel.wifi ? panel.wifi.active : null
    readonly property string security: panel.net ? panel.net.security : ""
    readonly property bool eap: panel.security === "eap"
    readonly property bool secured: Words.secured(panel.security)
    readonly property string netState: panel.net ? panel.net.state : ""
    readonly property bool unnamed: !!panel.net && panel.net.hidden && panel.net.ssid === "" && panel.uuid === ""
    readonly property bool known: !!panel.net && panel.net.known
    readonly property bool needsPassword: !!panel.net && panel.secured && !panel.eap && panel.netState !== "connected" && panel.netState !== "connecting"
                                          && (panel.netState === "needsSecret" || !panel.known)
    readonly property bool busy: panel.netState === "connecting" || panel.netState === "disconnecting"
    readonly property var bestAp: {
        if (!panel.net)
            return null;
        let best = null;
        for (let i = 0; i < panel.net.aps.length; i++) {
            const a = panel.net.aps[i];
            if (panel.active && a.bssid === panel.active.bssid)
                return a;
            if (!best || a.signal > best.signal)
                best = a;
        }
        return best;
    }

    // what a host reads: this panel has a field that wants the keys
    readonly property bool wantsKeys: panel.page === "info" ? (panel.needsPassword || panel.unnamed) : (panel.page === "login" || panel.page === "ip")

    // ---- the head and the pages ----------------------------------------------------------------------------------------------------
    title: panel.net ? (panel.net.ssid !== "" ? panel.net.ssid : "Hidden network") : "Network"
    subtitle: {
        if (!panel.net)
            return "This network is not in range any more.";
        if (panel.netState === "connected" && panel.active)
            return "Connected" + (panel.active.band ? " · " + Words.band(panel.active.band) : "") + (panel.active.standard !== "" ? " · " + panel.active.standard : "");
        const w = Words.netState(panel.netState);
        return panel.net.failReason !== "" && (panel.netState === "failed" || panel.netState === "needsSecret") ? w + ": " + panel.net.failReason : w;
    }
    subtitleTone: !panel.net || panel.netState === "failed" ? 3 : panel.netState === "connected" ? 5 : 1

    tabs: {
        const t = [{ id: "info", label: "Info" }];
        if (panel.eap)
            t.push({ id: "login", label: "Login" });
        if (panel.uuid !== "") {
            t.push({ id: "ip", label: "IP & DNS" });
            t.push({ id: "privacy", label: "Privacy" });
        }
        if (panel.net)
            t.push({ id: "radio", label: "Radio" });
        if (panel.uuid !== "" && !panel.eap || (panel.net && !panel.secured))
            t.push({ id: "share", label: "Share" });
        return t;
    }
    onTabsChanged: {
        for (let i = 0; i < panel.tabs.length; i++)
            if (panel.tabs[i].id === panel.page)
                return;
        panel.page = "info";
    }

    // ---- the password ---------------------------------------------------------------------------------------------------------------
    property bool _pwSent: false
    property string _prevState: ""
    onNetStateChanged: {
        if (panel._pwSent && panel._prevState !== panel.netState && (panel.netState === "needsSecret" || panel.netState === "failed")) {
            // the network refused what was typed: the field shakes and keeps it, selected, ready for another try
            pwBlock.field.shake();
        }
        if (panel.netState === "connected")
            panel._pwSent = false;
        panel._prevState = panel.netState;
    }
    // a refusal the service reports (a failed intent) while a typed password is out: the same shake, whatever state the network passes through
    Connections {
        target: panel.vm
        function onFailed(id: string, text: string): void {
            if (panel._pwSent && id.indexOf("connect:") === 0 && pwBlock.shown)
                pwBlock.field.shake();
        }
    }
    onNeedsPasswordChanged: panel._askFocus()
    onUnnamedChanged: panel._askFocus()
    onPageChanged: {
        if (panel.page !== "share")
            panel.secretText = "";
        panel._askFocus();
    }
    Component.onCompleted: {
        panel._prevState = panel.netState;
        panel._seedEap();
        panel._askFocus();
    }
    // asked one turn later by a Timer OF THIS PANEL (a Qt.callLater outlives a panel that closed in between)
    Timer {
        id: focusTimer
        interval: 0
        onTriggered: {
            if (panel.page !== "info")
                return;
            if (panel.unnamed)
                nameBlock.field.forceFocus();
            else if (panel.needsPassword)
                pwBlock.field.forceFocus();
        }
    }
    function _askFocus(): void {
        focusTimer.restart();
    }

    function connectNow(): void {
        if (!panel.vm || !panel.net)
            return;
        if (panel.eap && !panel.known) {
            panel.page = "login";
            return;
        }
        const o = {};
        if (panel.uuid !== "")
            o.profileUuid = panel.uuid;
        if (panel.needsPassword && pwBlock.text !== "") {
            o.password = pwBlock.text;
            panel._pwSent = true;
        }
        if (panel.unnamed)
            o.hiddenSsid = nameBlock.text;
        panel.vm.connect(panel.net.key, o);
    }
    readonly property bool canConnect: !!panel.net && !panel.busy && (!panel.unnamed || nameBlock.text !== "") && (!panel.needsPassword || pwBlock.text !== "" || !panel.secured)

    // ---- a revealed password ---------------------------------------------------------------------------------------------------------
    property string secretText: ""
    readonly property bool _canShare: !!panel.net && (!panel.secured || panel.secretText !== "")
    readonly property string joinText: {
        if (!panel.net || panel.eap)
            return "";
        if (!panel.secured)
            return Qr.wifiString(panel.net.ssid, "", panel.security, panel.net.hidden);
        return panel.secretText !== "" ? Qr.wifiString(panel.net.ssid, panel.secretText, panel.security, panel.net.hidden) : "";
    }
    Connections {
        target: panel.vm
        function onSecret(uuid: string, text: string): void {
            if (uuid === panel.uuid && panel.page === "share")
                panel.secretText = text;
        }
    }
    Timer {
        interval: 30000
        running: panel.secretText !== ""
        onTriggered: panel.secretText = ""
    }
    Component.onDestruction: panel.secretText = ""

    // ---- the enterprise form ----------------------------------------------------------------------------------------------------------
    property string eapMethod: "peap"
    property string eapInner: "mschapv2"
    readonly property var _eapSaved: panel.prof && panel.prof.eap ? panel.prof.eap : null
    function _seedEap(): void {
        const e = panel._eapSaved;
        panel.eapMethod = e && e.method ? String(e.method) : "peap";
        panel.eapInner = e && e.phase2 ? String(e.phase2) : "mschapv2";
        eapIdentity.text = e && e.identity ? e.identity : "";
        eapAnon.text = e && e.anonymousIdentity ? e.anonymousIdentity : "";
        eapCa.text = e && e.caCert ? e.caCert : "";
        eapDomain.text = e && e.domain ? e.domain : "";
    }
    on_EapSavedChanged: panel._seedEap()
    Process {
        id: picker
        command: panel.pickerCommand
        stdout: StdioCollector {
            onStreamFinished: {
                const p = text.trim();
                if (p !== "")
                    eapCa.text = p;
            }
        }
    }
    function connectEap(): void {
        if (!panel.vm || !panel.net)
            return;
        const o = { eap: { method: panel.eapMethod, phase2: panel.eapInner, identity: eapIdentity.text, anonymousIdentity: eapAnon.text,
                           password: eapPassword.text, caCert: eapCa.text, domain: eapDomain.text } };
        if (panel.uuid !== "")
            o.profileUuid = panel.uuid;
        panel._pwSent = true;
        panel.vm.connect(panel.net.key, o);
    }
    function openEditor(): void {
        panel.editorOpened++;
        Quickshell.execDetached(panel.editorCommand);
    }

    // =====================================================================================================================================
    //  Info
    // =====================================================================================================================================
    PanelPage {
        id: infoPage
        look: panel.look
        pageId: "info"
        shown: panel.page === "info"

        PanelCard {
            look: panel.look
            FieldBlock {
                id: nameBlock
                look: panel.look
                label: "Network name"
                placeholder: "The name of the hidden network"
                shown: panel.unnamed
                fieldObjectName: "hiddenName"
                onAccepted: pwBlock.shown ? pwBlock.field.forceFocus() : panel.connectNow()
            }
            FieldBlock {
                id: pwBlock
                look: panel.look
                label: "Password"
                placeholder: "Type the password"
                secret: true
                shown: panel.needsPassword
                fieldObjectName: "pwField"
                onAccepted: if (panel.canConnect) panel.connectNow()
                Connections {
                    target: pwBlock.field
                    function onEscaped(): void {
                        panel.dismissed();
                    }
                }
            }
            PText {
                look: panel.look
                tone: 3
                small: true
                width: parent.width
                wrapMode: Text.WordWrap
                shown: !!panel.net && (panel.netState === "failed" || panel.netState === "needsSecret") && panel.net.failReason !== ""
                text: panel.net ? panel.net.failReason : ""
            }
            ButtonRow {
                PanelButton {
                    objectName: "connectButton"
                    look: panel.look
                    accent: true
                    text: panel.eap && !panel.known ? "Log in" : "Connect"
                    visible: !!panel.net && panel.netState !== "connected" && panel.netState !== "connecting" && panel.netState !== "disconnecting"
                    enabled: panel.canConnect
                    onClicked: panel.connectNow()
                }
                PanelButton {
                    objectName: "disconnectButton"
                    look: panel.look
                    text: panel.netState === "connecting" ? "Cancel" : "Disconnect"
                    visible: panel.netState === "connected" || panel.netState === "connecting"
                    onClicked: if (panel.vm) panel.vm.disconnect()
                }
            }
        }

        PanelCard {
            look: panel.look
            FactRow { look: panel.look; label: "Network"; value: panel.net ? panel.net.ssid : "" }
            FactRow { look: panel.look; label: "Security"; value: Words.security(panel.security) }
            FactRow {
                look: panel.look
                label: "Band"
                value: {
                    const a = panel.bestAp;
                    if (!a)
                        return "";
                    return Words.band(a.band) + (Words.channel(a) !== "" ? ", " + Words.channel(a) : "");
                }
            }
            FactRow { look: panel.look; label: "Standard"; value: panel.active ? panel.active.standard : "" }
            FactRow {
                look: panel.look
                label: "Signal"
                value: panel.active ? Words.dbm(panel.active.dbm) : (panel.net ? panel.net.signal + " %" : "")
            }
            FactRow { look: panel.look; label: "Link rate"; value: panel.active ? Words.rate(panel.active.rateMbps) : "" }
            FactRow { look: panel.look; label: "IPv4"; value: panel.active ? Words.ipLine(panel.active.ip4, panel.active.prefix4) : "" }
            FactRow { look: panel.look; label: "Gateway"; value: panel.active ? panel.active.gateway4 : "" }
            FactRow { look: panel.look; label: "IPv6"; value: panel.active && panel.active.ip6.length > 0 ? panel.active.ip6[0] : "" }
            FactRow { look: panel.look; label: "DNS"; value: panel.active ? panel.active.dns.join(", ") : "" }
            FactRow { look: panel.look; label: "MAC used"; value: panel.active ? panel.active.mac : "" }
        }

        PanelCard {
            look: panel.look
            visible: !!panel.net
            SwitchRow {
                objectName: "trustedSwitch"
                look: panel.look
                title: "Trusted network"
                hint: panel.net && panel.net.trusted ? "A tunnel is not raised by itself here." : "Public: a tunnel is raised by itself when you join."
                checked: !!panel.net && panel.net.trusted
                onToggled: c => {
                    if (panel.vm && panel.net)
                        panel.vm.setTrusted(panel.uuid !== "" ? panel.uuid : panel.net.key, c);
                }
            }
        }
    }

    // =====================================================================================================================================
    //  Login (enterprise)
    // =====================================================================================================================================
    PanelPage {
        look: panel.look
        pageId: "login"
        shown: panel.page === "login"

        PanelCard {
            look: panel.look
            PText { look: panel.look; text: "Method" }
            ChoiceList {
                look: panel.look
                options: [{ key: "peap", label: "PEAP" }, { key: "ttls", label: "TTLS" }, { key: "tls", label: "EAP-TLS (certificate)" }]
                current: panel.eapMethod
                onChosen: k => {
                    panel.eapMethod = k;
                    if (k === "ttls" && panel.eapInner === "gtc")
                        panel.eapInner = "mschapv2";
                }
            }
        }
        PanelCard {
            look: panel.look
            visible: panel.eapMethod === "tls"
            PText {
                look: panel.look
                tone: 1
                width: parent.width
                wrapMode: Text.WordWrap
                text: "A network that wants a certificate is set up in NetworkManager's own editor."
            }
            ButtonRow {
                PanelButton {
                    objectName: "editorButton"
                    look: panel.look
                    text: "Open nm-connection-editor"
                    onClicked: panel.openEditor()
                }
            }
        }
        PanelCard {
            look: panel.look
            visible: panel.eapMethod !== "tls"
            PText { look: panel.look; text: "Inner method" }
            ChoiceList {
                look: panel.look
                options: panel.eapMethod === "peap"
                    ? [{ key: "mschapv2", label: "MSCHAPv2" }, { key: "gtc", label: "GTC" }]
                    : [{ key: "mschapv2", label: "MSCHAPv2" }, { key: "pap", label: "PAP" }]
                current: panel.eapInner
                onChosen: k => panel.eapInner = k
            }
            FieldBlock { id: eapIdentity; look: panel.look; label: "Identity"; placeholder: "name@institution.example"; fieldObjectName: "eapIdentity" }
            FieldBlock { id: eapAnon; look: panel.look; label: "Anonymous identity"; placeholder: "optional"; fieldObjectName: "eapAnon" }
            FieldBlock { id: eapPassword; look: panel.look; label: "Password"; secret: true; placeholder: "Type the password"; fieldObjectName: "eapPassword"; onAccepted: panel.connectEap() }
            FieldBlock { id: eapCa; look: panel.look; label: "CA certificate"; placeholder: "none: the server is not checked"; fieldObjectName: "eapCa" }
            ButtonRow {
                PanelButton {
                    objectName: "caBrowse"
                    look: panel.look
                    text: "Choose file"
                    onClicked: picker.running = true
                }
                PanelButton {
                    look: panel.look
                    text: "Clear"
                    visible: eapCa.text !== ""
                    onClicked: eapCa.field.clear()
                }
            }
            FieldBlock { id: eapDomain; look: panel.look; label: "Server domain"; placeholder: "radius.institution.example"; fieldObjectName: "eapDomain" }
            ButtonRow {
                PanelButton {
                    objectName: "eapConnect"
                    look: panel.look
                    accent: true
                    text: panel.netState === "connected" ? "Reconnect" : "Connect"
                    enabled: !panel.busy && eapIdentity.text !== ""
                    onClicked: panel.connectEap()
                }
            }
        }
    }

    // =====================================================================================================================================
    //  IP & DNS, Privacy
    // =====================================================================================================================================
    IpDnsPage {
        look: panel.look
        pageId: "ip"
        shown: panel.page === "ip"
        vm: panel.vm
        prof: panel.prof
        uuid: panel.uuid
        ip4: panel.active ? panel.active.ip4 : ""
        prefix4: panel.active ? panel.active.prefix4 : 24
        gateway4: panel.active ? panel.active.gateway4 : ""
        dns: panel.active ? panel.active.dns : []
    }
    PrivacyPage {
        look: panel.look
        pageId: "privacy"
        shown: panel.page === "privacy"
        vm: panel.vm
        prof: panel.prof
        uuid: panel.uuid
        macUsed: panel.active ? panel.active.mac : ""
    }

    // =====================================================================================================================================
    //  Radio
    // =====================================================================================================================================
    PanelPage {
        look: panel.look
        pageId: "radio"
        shown: panel.page === "radio"

        PanelCard {
            look: panel.look
            PText {
                look: panel.look
                text: panel.net && panel.net.aps.length > 1 ? "Access points of this name" : "Access point"
            }
            Repeater {
                model: panel.net ? panel.net.aps.length : 0
                delegate: Item {
                    id: apRow
                    required property int index
                    readonly property var ap: (panel.net ? panel.net.aps[apRow.index] : null) || ({ bssid: "", band: "", channel: 0, widthMhz: 0, signal: 0, active: false })
                    readonly property bool locked: panel.bssidLock !== "" && panel.bssidLock === apRow.ap.bssid
                    width: parent.width
                    height: 34
                    MouseArea {
                        objectName: "apRow_" + apRow.index
                        anchors.fill: parent
                        enabled: panel.uuid !== ""
                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: {
                            if (panel.vm) {
                                panel.localBssid = apRow.ap.bssid;
                                panel.vm.updateProfile(panel.uuid, { bssid: apRow.ap.bssid });
                            }
                        }
                    }
                    PText {
                        look: panel.look
                        x: 0
                        y: 2
                        text: Words.band(apRow.ap.band) + " · " + Words.channel(apRow.ap)
                    }
                    PText {
                        look: panel.look
                        tone: 1
                        small: true
                        x: 0
                        y: 18
                        text: apRow.ap.bssid + (apRow.ap.active ? " · in use" : "") + (apRow.locked ? " · locked" : "")
                    }
                    PText {
                        look: panel.look
                        tone: apRow.locked ? 0 : 1
                        x: parent.width - implicitWidth
                        y: 2
                        text: apRow.ap.signal + " %"
                    }
                }
            }
            ButtonRow {
                PanelButton {
                    objectName: "anyAp"
                    look: panel.look
                    text: "Use any access point"
                    visible: panel.bssidLock !== ""
                    onClicked: {
                        if (panel.vm) {
                            panel.localBssid = "";
                            panel.vm.updateProfile(panel.uuid, { bssid: "" });
                        }
                    }
                }
            }
        }
        PanelCard {
            look: panel.look
            PText { look: panel.look; text: "Band" }
            ChoiceList {
                look: panel.look
                options: [{ key: "", label: "Any band" }, { key: "bg", label: "2.4 GHz only" }, { key: "a", label: "5 GHz only" }, { key: "6GHz", label: "6 GHz only" }]
                current: panel.bandLock
                onChosen: k => {
                    if (panel.vm && panel.uuid !== "") {
                        panel.localBand = k;
                        panel.vm.updateProfile(panel.uuid, { band: k });
                    }
                }
            }
            PText {
                look: panel.look
                tone: 1
                small: true
                width: parent.width
                wrapMode: Text.WordWrap
                shown: panel.uuid === ""
                text: "Join the network once and its band and access point can be locked here."
            }
        }
    }

    // =====================================================================================================================================
    //  Share
    // =====================================================================================================================================
    PanelPage {
        look: panel.look
        pageId: "share"
        shown: panel.page === "share"

        PanelCard {
            look: panel.look
            PText {
                look: panel.look
                tone: 1
                width: parent.width
                wrapMode: Text.WordWrap
                text: panel.eap ? "An enterprise network has no join code."
                    : panel.secured ? "A phone joins this network by scanning the code. The password is shown only while you ask for it."
                    : "A phone joins this open network by scanning the code."
            }
            FactRow {
                look: panel.look
                label: "Password"
                value: panel.secretText
                tone: 0
            }
            ButtonRow {
                PanelButton {
                    objectName: "revealButton"
                    look: panel.look
                    text: "Show password and code"
                    visible: panel.secured && !panel.eap && panel.secretText === ""
                    enabled: panel.uuid !== ""
                    onClicked: if (panel.vm) panel.vm.revealSecret(panel.uuid)
                }
                PanelButton {
                    objectName: "hideButton"
                    look: panel.look
                    text: "Hide"
                    visible: panel.secretText !== ""
                    onClicked: panel.secretText = ""
                }
            }
        }
        Item {
            width: parent.width
            height: qr.visible ? qr.implicitHeight : 0
            visible: qr.visible
            QrView {
                id: qr
                objectName: "joinQr"
                x: Math.round((parent.width - width) / 2)
                text: panel.joinText
                maxSize: 188
            }
        }
    }
}
