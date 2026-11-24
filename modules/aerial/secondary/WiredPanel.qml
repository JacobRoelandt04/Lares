pragma ComponentBehavior: Bound

import QtQuick

import "PanelWords.js" as Words

// =============================================================================
// WiredPanel.qml -- the jack's panel: the cable (connect / disconnect, speed, the address it was given), the same IP & DNS and
// Privacy pages a Wi-Fi network has, and the OTHER wired links (a phone's USB tethering) listed with their own Connect / Disconnect.
//
//   vm         an AerialService or an AerialMock
//   targetKey  the interface of the link shown ("" = the first RJ45 jack, else the first link)
// =============================================================================
PanelFrame {
    id: panel

    property var vm: null
    property string targetKey: ""

    signal dismissed()

    readonly property var jacks: panel.vm ? panel.vm.wired.jacks : []
    readonly property var jack: {
        const l = panel.jacks;
        for (let i = 0; i < l.length; i++)
            if (panel.targetKey !== "" && l[i].iface === panel.targetKey)
                return l[i];
        for (let k = 0; k < l.length; k++)
            if (l[k].kind === "rj45")
                return l[k];
        return l.length > 0 ? l[0] : null;
    }
    readonly property var others: panel.jacks.filter(j => !panel.jack || j.iface !== panel.jack.iface)
    readonly property string uuid: panel.jack ? panel.jack.uuid : ""
    readonly property bool wantsKeys: panel.page === "ip"

    function _list(x): var {
        return x && x.length !== undefined ? Array.prototype.slice.call(x) : [];
    }
    function _kind(j): string {
        return j.kind === "usb" ? "USB tethering" : "Cable";
    }

    title: panel.jack ? (panel.jack.kind === "usb" ? "USB link" : "Cable") : "Cable"
    subtitle: !panel.jack ? "This machine has no wired network."
        : panel.jack.connected ? "Connected" + (panel.jack.speedMbps > 0 ? " · " + Words.rate(panel.jack.speedMbps) : "")
        : panel.jack.carrier ? "Cable in, not connected" : "No cable is plugged in"
    subtitleTone: panel.jack && panel.jack.connected ? 5 : 1

    tabs: {
        const t = [{ id: "info", label: "Info" }];
        if (panel.uuid !== "") {
            t.push({ id: "ip", label: "IP & DNS" });
            t.push({ id: "privacy", label: "Privacy" });
        }
        return t;
    }
    onTabsChanged: {
        for (let i = 0; i < panel.tabs.length; i++)
            if (panel.tabs[i].id === panel.page)
                return;
        panel.page = "info";
    }

    PanelPage {
        look: panel.look
        pageId: "info"
        shown: panel.page === "info"

        PanelCard {
            look: panel.look
            PText {
                look: panel.look
                tone: 1
                width: parent.width
                wrapMode: Text.WordWrap
                shown: !panel.jack || (!panel.jack.carrier && !panel.jack.connected)
                text: panel.jack ? "Plug a cable in, and it joins by itself." : "There is no wired network card to show."
            }
            ButtonRow {
                PanelButton {
                    objectName: "wiredConnect"
                    look: panel.look
                    accent: true
                    text: "Connect"
                    visible: !!panel.jack && panel.jack.carrier && !panel.jack.connected
                    onClicked: if (panel.vm) panel.vm.connectWired(panel.jack.iface)
                }
                PanelButton {
                    objectName: "wiredDisconnect"
                    look: panel.look
                    text: "Disconnect"
                    visible: !!panel.jack && panel.jack.connected
                    onClicked: if (panel.vm) panel.vm.disconnectWired(panel.jack.iface)
                }
            }
        }
        PanelCard {
            look: panel.look
            FactRow { look: panel.look; label: "Interface"; value: panel.jack ? panel.jack.iface : "" }
            FactRow { look: panel.look; label: "Link"; value: panel.jack ? (panel.jack.carrier ? "Cable in" : "No cable") : "" }
            FactRow { look: panel.look; label: "Speed"; value: panel.jack ? Words.rate(panel.jack.speedMbps) : "" }
            FactRow { look: panel.look; label: "IPv4"; value: panel.jack ? Words.ipLine(panel.jack.ip4, panel.jack.prefix4) : "" }
            FactRow { look: panel.look; label: "Gateway"; value: panel.jack ? panel.jack.gateway4 : "" }
            FactRow { look: panel.look; label: "DNS"; value: panel.jack ? panel._list(panel.jack.dns).join(", ") : "" }
            FactRow { look: panel.look; label: "MAC"; value: panel.jack ? panel.jack.mac : "" }
        }
        PanelCard {
            look: panel.look
            visible: panel.others.length > 0
            PText { look: panel.look; text: "Other wired links" }
            Repeater {
                model: panel.others.length
                delegate: Item {
                    id: other
                    required property int index
                    readonly property var j: panel.others[other.index] || ({ iface: "", kind: "", connected: false, carrier: false, ip4: "" })
                    width: parent.width
                    height: 34
                    PText {
                        look: panel.look
                        y: 0
                        width: parent.width - btn.width - 8
                        elide: Text.ElideRight
                        text: panel._kind(other.j) + " · " + other.j.iface
                    }
                    PText {
                        look: panel.look
                        tone: 1
                        small: true
                        y: 17
                        text: other.j.connected ? "Connected" + (other.j.ip4 ? " · " + other.j.ip4 : "") : other.j.carrier ? "Ready" : "Not connected"
                    }
                    PanelButton {
                        id: btn
                        objectName: "otherLink_" + other.index
                        look: panel.look
                        x: parent.width - width
                        text: other.j.connected ? "Disconnect" : "Connect"
                        visible: other.j.connected || other.j.carrier
                        onClicked: {
                            if (!panel.vm)
                                return;
                            if (other.j.connected)
                                panel.vm.disconnectWired(other.j.iface);
                            else
                                panel.vm.connectWired(other.j.iface);
                        }
                    }
                }
            }
        }
    }
    IpDnsPage {
        look: panel.look
        pageId: "ip"
        shown: panel.page === "ip"
        vm: panel.vm
        prof: null
        uuid: panel.uuid
        ip4: panel.jack ? panel.jack.ip4 : ""
        prefix4: panel.jack ? panel.jack.prefix4 : 24
        gateway4: panel.jack ? panel.jack.gateway4 : ""
        dns: panel.jack ? panel._list(panel.jack.dns) : []
    }
    PrivacyPage {
        look: panel.look
        pageId: "privacy"
        shown: panel.page === "privacy"
        vm: panel.vm
        prof: null
        uuid: panel.uuid
        macUsed: panel.jack ? panel.jack.mac : ""
    }
}
