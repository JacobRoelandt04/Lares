pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// IpDnsPage.qml -- the IP & DNS page of a network or a cable: automatic or manual addressing (address, prefix, gateway, the DNS
// servers), IPv6 on / off, one Apply. It edits a LOCAL copy and sends `vm.updateProfile(uuid, { ipv4: {...}, ipv6: {...} })` on
// Apply: nothing is written while a person types. Seeded from the profile (`prof.ip4method`) and the live address (`ip4`, `prefix4`,
// `gateway4`, `dns`), so the manual form opens with the numbers the network gave.
// =============================================================================
PanelPage {
    id: page

    property var vm: null
    property var prof: null               // the profile record (Profile of the contract) or null
    property string uuid: ""
    property string ip4: ""
    property int prefix4: 24
    property string gateway4: ""
    property var dns: []

    property string method: "auto"
    property bool ip6On: true

    readonly property bool canApply: page.uuid !== ""
    readonly property alias applyButton: applyBtn

    function _seed(): void {
        page.method = page.prof && page.prof.ip4method === "manual" ? "manual" : "auto";
        addr.text = page.ip4;
        prefix.text = page.prefix4 > 0 ? String(page.prefix4) : "";
        gate.text = page.gateway4;
        dnsF.text = (page.dns || []).join(", ");
    }
    onUuidChanged: page._seed()
    Component.onCompleted: page._seed()

    function _dnsList(): var {
        return dnsF.text.split(/[\s,;]+/).filter(x => x !== "");
    }
    function apply(): void {
        if (!page.vm || !page.canApply)
            return;
        const v4 = page.method === "manual"
            ? { method: "manual", address: addr.text.trim(), prefix: parseInt(prefix.text) || 24, gateway: gate.text.trim(), dns: page._dnsList() }
            : { method: "auto" };
        page.vm.updateProfile(page.uuid, { ipv4: v4, ipv6: { method: page.ip6On ? "auto" : "disabled" } });
    }

    PanelCard {
        look: page.look
        ChoiceList {
            look: page.look
            options: [{ key: "auto", label: "Automatic (DHCP)" }, { key: "manual", label: "Manual" }]
            current: page.method
            onChosen: k => page.method = k
        }
        Column {
            width: parent.width
            spacing: page.look ? page.look.rowGap : 8
            height: page.method === "manual" ? implicitHeight : 0
            visible: page.method === "manual"
            FieldBlock {
                id: addr
                look: page.look
                label: "Address"
                placeholder: "192.168.1.20"
                fieldObjectName: "ipAddress"
            }
            FieldBlock {
                id: prefix
                look: page.look
                label: "Prefix length"
                placeholder: "24"
                fieldObjectName: "ipPrefix"
                validator: IntValidator { bottom: 1; top: 32 }
            }
            FieldBlock {
                id: gate
                look: page.look
                label: "Gateway"
                placeholder: "192.168.1.1"
                fieldObjectName: "ipGateway"
            }
        }
        FieldBlock {
            id: dnsF
            look: page.look
            label: "DNS servers"
            placeholder: page.method === "manual" ? "9.9.9.9, 1.1.1.1" : "given by the network"
            fieldObjectName: "ipDns"
            shown: page.method === "manual"
        }
    }
    PanelCard {
        look: page.look
        SwitchRow {
            look: page.look
            title: "IPv6"
            hint: "Off: this network is used over IPv4 only."
            checked: page.ip6On
            onToggled: c => page.ip6On = c
        }
        PText {
            look: page.look
            tone: 1
            small: true
            width: parent.width
            shown: !page.canApply
            wrapMode: Text.WordWrap
            text: "Join the network once and its settings can be changed here."
        }
        ButtonRow {
            PanelButton {
                id: applyBtn
                objectName: "ipApply"
                look: page.look
                text: "Apply"
                accent: true
                enabled: page.canApply
                onClicked: page.apply()
            }
        }
    }
}
