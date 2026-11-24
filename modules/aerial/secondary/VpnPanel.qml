pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "PanelWords.js" as Words

// =============================================================================
// VpnPanel.qml -- the globe's panel (ProtonVPN only). WHERE: pick a country, then a city, then a server with its load -- or ask for
// the fastest, or a random one; the filters Secure Core / P2P / Tor narrow every list; a search field runs over the countries.
// PROTECTION: NetShield (off / malware only / malware, ads and trackers), the kill switch (off / standard: the CLI has no more),
// IPv6, a custom DNS server, and the auto-tunnel switch ("Tunnel on Public networks").
//
//   vm   an AerialService or an AerialMock (facts `proton`, `catalog`, `config`; intents vpnConnect, vpnDisconnect, vpnSet,
//        setAutoTunnel, refreshCatalog)
//
// Proton signed out (or not installed) is said plainly with the way out: `protonvpn signin` in a terminal. The catalogue is Proton's
// own cache, digested by the data layer: empty until it was read (said, with a Refresh button).
// =============================================================================
PanelFrame {
    id: panel

    property var vm: null
    maxHeight: 700
    property string filter: ""             // "" | "securecore" | "p2p" | "tor"
    property string selCountry: ""         // a country code once one is opened
    property string selCity: ""
    readonly property int serverCap: 60

    signal dismissed()

    readonly property var p: panel.vm ? panel.vm.proton : null
    readonly property var cat: panel.vm ? panel.vm.catalog : null
    readonly property bool installed: !!panel.p && panel.p.installed
    readonly property bool signedOut: panel.installed && panel.p.signedIn === "no"
    readonly property bool ready: panel.installed && panel.p.signedIn === "yes"
    // nothing is known of the sign-in yet, because it is in a keyring that is still locked
    readonly property bool keyringLocked: panel.installed && panel.p.signedIn === "unknown" && panel.p.locked === true
    readonly property bool tunnelUp: !!panel.p && (panel.p.state === "up" || panel.p.state === "connecting")
    readonly property bool wantsKeys: panel.page === "protection" || (panel.page === "where" && panel.selCountry === "")

    title: "ProtonVPN"
    subtitle: !panel.installed ? "ProtonVPN is not installed."
        : panel.signedOut ? "Signed out."
        : panel.keyringLocked ? "The keyring is locked."
        : panel.p.signedIn === "unknown" ? "Asking ProtonVPN."
        : panel.p.state === "up" ? "Tunnel up" + (panel.p.server ? " · " + panel.p.server.name : "")
        : panel.p.state === "connecting" ? "Connecting"
        : panel.p.state === "disconnecting" ? "Disconnecting"
        : panel.p.state === "failed" ? "The tunnel could not be raised." : "No tunnel"
    subtitleTone: !panel.installed || panel.p && panel.p.state === "failed" ? 3 : panel.p && panel.p.state === "up" ? 5 : 1
    tabs: [{ id: "where", label: "Where" }, { id: "protection", label: "Protection" }]


    // Enter in the DNS field and the "Set DNS" button do the same: set it, then clear the field
    function _applyDns(): void {
        const v = dnsBlock.text.trim();
        if (v === "")
            return;
        if (panel.vm)
            panel.vm.vpnSet("customDns", v);
        dnsBlock.field.clear();
    }

    function _passes(feats): bool {
        return panel.filter === "" || Words.hasFeature(feats, panel.filter);
    }
    readonly property var countries: {
        const all = panel.cat ? panel.cat.countries : [];
        const q = search.text.trim().toLowerCase();
        const out = all.filter(c => panel._passes(c.features) && (q === "" || c.name.toLowerCase().indexOf(q) >= 0 || c.code.toLowerCase() === q));
        out.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
        return out;
    }
    readonly property var country: {
        const all = panel.cat ? panel.cat.countries : [];
        for (let i = 0; i < all.length; i++)
            if (all[i].code === panel.selCountry)
                return all[i];
        return null;
    }
    readonly property var cities: {
        if (!panel.country)
            return [];
        const out = panel.country.cities.filter(ci => ci.servers.some(s => panel._passes(s.features)));
        out.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
        return out;
    }
    readonly property var city: {
        for (let i = 0; i < panel.cities.length; i++)
            if (panel.cities[i].name === panel.selCity)
                return panel.cities[i];
        return null;
    }
    readonly property var allServers: {
        if (!panel.city)
            return [];
        const out = panel.city.servers.filter(s => panel._passes(s.features));
        out.sort((a, b) => a.load - b.load);
        return out;
    }
    readonly property var servers: panel.allServers.slice(0, panel.serverCap)

    function _args(extra): var {
        const o = {};
        if (panel.filter !== "") {
            o.feature = panel.filter;
            o[panel.filter] = true;
        }
        return Object.assign(o, extra || {});
    }
    function connectTo(extra): void {
        if (panel.vm)
            panel.vm.vpnConnect(panel._args(extra));
    }
    onFilterChanged: {
        if (panel.selCountry !== "" && (!panel.country || (panel.selCity !== "" && !panel.city))) {
            panel.selCity = "";
            if (!panel.country)
                panel.selCountry = "";
        }
    }

    // =====================================================================================================================================
    PanelPage {
        look: panel.look
        pageId: "where"
        shown: panel.page === "where"

        PanelCard {
            look: panel.look
            PText {
                look: panel.look
                tone: panel.signedOut ? 0 : 3
                width: parent.width
                wrapMode: Text.WordWrap
                shown: !panel.ready
                text: !panel.installed ? "The ProtonVPN command line tool is not installed on this machine."
                    : panel.signedOut ? "ProtonVPN is signed out. Open a terminal and run: protonvpn signin"
                    : panel.keyringLocked ? "ProtonVPN's sign-in is in the keyring, which is locked. It opens with your password at the lock screen."
                    : "Waiting for ProtonVPN to answer."
            }
            FactRow {
                look: panel.look
                label: "Server"
                value: panel.ready && panel.p.server ? panel.p.server.name + (panel.p.server.city ? " · " + panel.p.server.city : "") + (panel.p.server.country ? ", " + panel.p.server.country : "") : ""
            }
            FactRow { look: panel.look; label: "Load"; value: panel.ready && panel.p.server && panel.p.server.load > 0 ? panel.p.server.load + " %" : "" }
            FactRow { look: panel.look; label: "Protocol"; value: panel.ready && panel.p.server ? panel.p.server.protocol : "" }
            ButtonRow {
                PanelButton {
                    objectName: "vpnFastest"
                    look: panel.look
                    accent: true
                    text: "Fastest server"
                    visible: panel.ready && !panel.tunnelUp
                    onClicked: panel.connectTo({})
                }
                PanelButton {
                    objectName: "vpnRandom"
                    look: panel.look
                    text: "Random server"
                    visible: panel.ready && !panel.tunnelUp
                    onClicked: panel.connectTo({ random: true })
                }
                PanelButton {
                    objectName: "vpnDisconnect"
                    look: panel.look
                    text: "Disconnect"
                    visible: panel.ready && panel.tunnelUp
                    onClicked: if (panel.vm) panel.vm.vpnDisconnect()
                }
            }
        }

        PanelCard {
            look: panel.look
            visible: panel.ready
            PText { look: panel.look; text: "Kind of server" }
            ChoiceList {
                look: panel.look
                rowHeight: 24
                options: [{ key: "", label: "Any" }, { key: "securecore", label: "Secure Core" }, { key: "p2p", label: "P2P" }, { key: "tor", label: "Tor" }]
                current: panel.filter
                onChosen: k => panel.filter = k
            }
        }

        PanelCard {
            look: panel.look
            visible: panel.ready
            // ---- the way back, and the fastest of what is open
            Item {
                width: parent.width
                height: panel.selCountry !== "" ? 30 : 0
                visible: panel.selCountry !== ""
                PickRow {
                    objectName: "vpnBack"
                    look: panel.look
                    title: panel.selCity !== "" ? panel.selCity : (panel.country ? panel.country.name : "")
                    figure: "Back"
                    onClicked: {
                        if (panel.selCity !== "")
                            panel.selCity = "";
                        else
                            panel.selCountry = "";
                    }
                }
            }
            ButtonRow {
                PanelButton {
                    objectName: "vpnFastestHere"
                    look: panel.look
                    text: panel.selCity !== "" ? "Fastest in " + panel.selCity : "Fastest in " + (panel.country ? panel.country.name : "")
                    visible: panel.selCountry !== ""
                    onClicked: panel.connectTo(panel.selCity !== "" ? { country: panel.selCountry, city: panel.selCity } : { country: panel.selCountry })
                }
            }
            CarvedSearchField {
                id: search
                objectName: "vpnSearch"
                width: parent.width
                height: 30
                visible: panel.selCountry === ""
                placeholder: "Search countries"
                fontFamily: panel.look.fontFamily
                surfaceColor: Theme.listBox
                onEscaped: panel.dismissed()
            }
            PText {
                look: panel.look
                tone: 1
                width: parent.width
                wrapMode: Text.WordWrap
                shown: !!panel.cat && panel.cat.countries.length === 0
                text: "Proton's server list has not been read yet."
            }
            ButtonRow {
                PanelButton {
                    objectName: "vpnRefreshList"
                    look: panel.look
                    text: "Read the server list"
                    visible: !!panel.cat && panel.cat.countries.length === 0
                    onClicked: if (panel.vm) panel.vm.refreshCatalog()
                }
            }
            // ---- level 0: countries
            Repeater {
                model: panel.selCountry === "" ? panel.countries.length : 0
                delegate: PickRow {
                    id: crow
                    required property int index
                    readonly property var c: panel.countries[crow.index] || ({ code: "", name: "", servers: 0, features: [], minLoad: 0 })
                    objectName: "vpnCountry_" + crow.c.code
                    look: panel.look
                    title: crow.c.name
                    sub: crow.c.servers + (crow.c.servers === 1 ? " server" : " servers") + (crow.c.minLoad > 0 ? " · lightest load" : "") + (Words.featureWords(crow.c.features) !== "" ? " · " + Words.featureWords(crow.c.features) : "")
                    figure: crow.c.minLoad > 0 ? crow.c.minLoad + " %" : ""
                    chevron: true
                    onClicked: {
                        panel.selCountry = crow.c.code;
                        panel.selCity = "";
                    }
                }
            }
            // ---- level 1: cities
            Repeater {
                model: panel.selCountry !== "" && panel.selCity === "" ? panel.cities.length : 0
                delegate: PickRow {
                    id: ctrow
                    required property int index
                    readonly property var ci: panel.cities[ctrow.index] || ({ name: "", servers: [] })
                    objectName: "vpnCity_" + ctrow.index
                    look: panel.look
                    title: ctrow.ci.name
                    sub: ctrow.ci.servers.length + (ctrow.ci.servers.length === 1 ? " server" : " servers")
                    figure: ""
                    chevron: true
                    onClicked: panel.selCity = ctrow.ci.name
                }
            }
            // ---- level 2: servers, lightest first
            Repeater {
                model: panel.selCity !== "" ? panel.servers.length : 0
                delegate: PickRow {
                    id: srow
                    required property int index
                    readonly property var s: panel.servers[srow.index] || ({ name: "", load: 0, features: [] })
                    objectName: "vpnServer_" + srow.index
                    look: panel.look
                    title: srow.s.name
                    sub: Words.featureWords(srow.s.features)
                    figure: srow.s.load + " %"
                    figureTone: srow.s.load >= 80 ? 3 : 1
                    selected: !!panel.p && !!panel.p.server && panel.p.server.name === srow.s.name && panel.tunnelUp
                    onClicked: panel.connectTo({ country: panel.selCountry, city: panel.selCity, server: srow.s.name })
                }
            }
            PText {
                look: panel.look
                tone: 1
                small: true
                width: parent.width
                wrapMode: Text.WordWrap
                shown: panel.selCity !== "" && panel.allServers.length > panel.serverCap
                text: "The " + panel.serverCap + " lightest of " + panel.allServers.length + " servers are listed."
            }
            PText {
                look: panel.look
                tone: 1
                width: parent.width
                wrapMode: Text.WordWrap
                shown: panel.selCountry === "" && !!panel.cat && panel.cat.countries.length > 0 && panel.countries.length === 0
                text: "No country matches"
            }
        }
    }

    // =====================================================================================================================================
    PanelPage {
        look: panel.look
        pageId: "protection"
        shown: panel.page === "protection"

        PanelCard {
            look: panel.look
            PText { look: panel.look; text: "NetShield" }
            ChoiceList {
                look: panel.look
                options: [
                    { key: "off", label: "Off" },
                    { key: "malware-only", label: "Block malware" },
                    { key: "malware-ads-trackers", label: "Block malware, ads and trackers" }
                ]
                current: panel.p ? panel.p.netshield : ""
                onChosen: k => {
                    if (panel.vm)
                        panel.vm.vpnSet("netshield", k);
                }
            }
        }
        PanelCard {
            look: panel.look
            PText { look: panel.look; text: "Kill switch" }
            ChoiceList {
                look: panel.look
                options: [{ key: "off", label: "Off" }, { key: "standard", label: "Standard: nothing leaves outside the tunnel" }]
                current: panel.p ? panel.p.killSwitch : ""
                onChosen: k => {
                    if (panel.vm)
                        panel.vm.vpnSet("killSwitch", k);
                }
            }
        }
        PanelCard {
            look: panel.look
            SwitchRow {
                objectName: "vpnIpv6"
                look: panel.look
                title: "IPv6 through the tunnel"
                checked: !!panel.p && panel.p.ipv6 === true
                onToggled: c => {
                    if (panel.vm)
                        panel.vm.vpnSet("ipv6", c);
                }
            }
            FieldBlock {
                id: dnsBlock
                look: panel.look
                label: "Custom DNS server"
                placeholder: panel.p && panel.p.customDns !== "" ? panel.p.customDns : "none: Proton's own"
                fieldObjectName: "vpnDns"
                onAccepted: panel._applyDns()
            }
            ButtonRow {
                PanelButton {
                    objectName: "vpnDnsApply"
                    look: panel.look
                    text: "Set DNS"
                    enabled: dnsBlock.text.trim() !== ""
                    onClicked: panel._applyDns()
                }
                PanelButton {
                    objectName: "vpnDnsClear"
                    look: panel.look
                    text: "Use Proton's"
                    visible: !!panel.p && panel.p.customDns !== ""
                    onClicked: if (panel.vm) panel.vm.vpnSet("customDns", "off")
                }
            }
        }
        PanelCard {
            look: panel.look
            SwitchRow {
                objectName: "autoTunnelSwitch"
                look: panel.look
                title: "Tunnel on Public networks"
                hint: "Joining a network that is not Trusted raises the tunnel by itself, after a login page if there is one."
                checked: !!panel.vm && !!panel.vm.config && panel.vm.config.autoTunnel === true
                onToggled: c => {
                    if (panel.vm)
                        panel.vm.setAutoTunnel(c);
                }
            }
        }
    }
}
