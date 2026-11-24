pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/aerial/data"
import "modules/aerial/secondary"

// =============================================================================
// aerial_panels_sheet.qml -- every aerial detail panel in every state it has, one PNG per cell (tools/dev/aerial_panels_sheet.sh puts
// them on a contact sheet, in each mode). The panels are the real AerialSecondary on an AerialMock scenario, on the popup's surface.
//   OUT_DIR   where the cells go (<name>.png) -- required
//   ONLY      a comma list of cell names to render (default all)
// Prints `APS cell <name> <w>x<h>` per grab and `APS RESULT PASS|FAIL`.
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 460
        implicitHeight: 700
        visible: true
        color: Theme.surface

        readonly property string outDir: Quickshell.env("OUT_DIR") || ""
        readonly property var only: (Quickshell.env("ONLY") || "").split(",").filter(x => x !== "")
        property int step: -1
        property int fails: 0
        property string phase: "load"

        AerialMock {
            id: mock
            live: false
            scenario: "home"
        }

        // a stand-in for what a state needs of the scenario's facts: a key found by what the network IS, never by position
        function netKey(pred): string {
            const l = mock.wifi.networks;
            for (let i = 0; i < l.length; i++)
                if (pred(l[i]))
                    return l[i].key;
            return "";
        }

        readonly property var all: [
            { name: "net_home_info", scenario: "home", kind: "network", key: "Home-5G", page: "info" },
            { name: "net_home_ip", scenario: "home", kind: "network", key: "Home-5G", page: "ip" },
            { name: "net_home_ip_manual", scenario: "home", kind: "network", key: "Home-5G", page: "ip", act: p => { p.panel.page = "ip"; } },
            { name: "net_home_privacy", scenario: "home", kind: "network", key: "Home-5G", page: "privacy" },
            { name: "net_home_radio", scenario: "home", kind: "network", key: "Home-5G", page: "radio" },
            { name: "net_home_share", scenario: "home", kind: "network", key: "Home-5G", page: "share" },
            { name: "net_stranger_password", scenario: "home", kind: "network", key: "FRITZ!Box 7590", page: "info" },
            { name: "net_open_cafe", scenario: "home", kind: "network", key: "Cafe-Free", page: "info" },
            { name: "net_eap_login", scenario: "home", kind: "network", key: "eduroam", page: "login" },
            { name: "net_hidden", scenario: "crowd", kind: "network", keyOf: n => n.hidden && n.ssid === "", page: "info" },
            { name: "net_gone", scenario: "home", kind: "network", key: "nowhere", page: "info" },
            { name: "saved_list", scenario: "home", kind: "saved", page: "list", act: p => { p.panel.expanded = "u-prox"; } },
            { name: "saved_add", scenario: "home", kind: "saved", page: "add" },
            { name: "saved_card", scenario: "home", kind: "saved", page: "card" },
            { name: "wired_cable", scenario: "hotspot", kind: "wired", key: "enp46s0", page: "info" },
            { name: "wired_nocable", scenario: "home", kind: "wired", key: "enp46s0", page: "info" },
            { name: "wired_ip", scenario: "hotspot", kind: "wired", key: "enp46s0", page: "ip" },
            { name: "hotspot_setup", scenario: "hotspot", kind: "hotspot", page: "setup" },
            { name: "hotspot_devices", scenario: "hotspot", kind: "hotspot", page: "devices" },
            { name: "hotspot_off", scenario: "home", kind: "hotspot", page: "setup" },
            { name: "vpn_where_down", scenario: "home", kind: "vpn", page: "where" },
            { name: "vpn_where_up", scenario: "vpn", kind: "vpn", page: "where" },
            { name: "vpn_cities", scenario: "vpn", kind: "vpn", page: "where", act: p => { p.panel.selCountry = "NL"; } },
            { name: "vpn_servers", scenario: "vpn", kind: "vpn", page: "where", act: p => { p.panel.selCountry = "NL"; p.panel.selCity = "Amsterdam"; } },
            { name: "vpn_protection", scenario: "vpn", kind: "vpn", page: "protection" },
            { name: "vpn_signedout", scenario: "vpn", kind: "vpn", page: "where", act: p => { mock.proton = Object.assign({}, mock.proton, { signedIn: "no", state: "down", server: null }); } },
            { name: "vpn_keyring", scenario: "vpn", kind: "vpn", page: "where", act: p => { mock.proton = Object.assign({}, mock.proton, { signedIn: "unknown", locked: true, state: "down", server: null }); } },
            { name: "bt_earbuds", scenario: "earbuds", kind: "bt", key: "AA:BB:CC:00:00:01", page: "device" },
            { name: "bt_battery", scenario: "earbuds", kind: "bt", key: "AA:BB:CC:00:00:01", page: "battery" },
            { name: "bt_audio", scenario: "earbuds", kind: "bt", key: "AA:BB:CC:00:00:01", page: "audio" },
            { name: "bt_pairing", scenario: "pairing", kind: "bt", key: "AA:BB:CC:00:00:10", page: "device" },
            { name: "pad_net_portal", scenario: "portal", kind: "pad", key: "net", page: "pad" },
            { name: "pad_dns_fail", scenario: "errors", kind: "pad", key: "dns", page: "pad" },
            { name: "pad_gateway_ok", scenario: "home", kind: "pad", key: "gateway", page: "pad" },
            { name: "usage", scenario: "home", kind: "usage", page: "usage" }
        ]
        readonly property var states: win.only.length > 0 ? win.all.filter(s => win.only.indexOf(s.name) >= 0) : win.all

        Item {
            id: stage
            x: 10
            y: 10
            width: sec.implicitWidth
            height: sec.implicitHeight
            Rectangle {
                anchors.fill: parent
                color: Theme.surface
            }
            AerialSecondary {
                id: sec
                vm: mock
                kind: "network"
            }
        }

        function begin(s): void {
            if (mock.scenario !== s.scenario)
                mock.scenario = s.scenario;
            sec.kind = s.kind;
            sec.targetKey = s.keyOf ? win.netKey(s.keyOf) : (s.key || "");
        }
        function settle(s): void {
            if (sec.panel && s.page)
                sec.panel.page = s.page;
            if (s.act)
                s.act(sec);
        }

        Timer {
            id: clock
            interval: 350
            running: true
            repeat: true
            onTriggered: {
                if (win.outDir === "") {
                    stop();
                    console.log("APS RESULT FAIL (no OUT_DIR)");
                    Qt.quit();
                    return;
                }
                if (win.phase === "load") {
                    win.step++;
                    if (win.step >= win.states.length) {
                        stop();
                        console.log("APS RESULT " + (win.fails === 0 ? "PASS" : "FAIL"));
                        Qt.quit();
                        return;
                    }
                    win.begin(win.states[win.step]);
                    win.phase = "settle";
                } else if (win.phase === "settle") {
                    win.settle(win.states[win.step]);
                    win.phase = "grab";
                } else {
                    stop();
                    const nm = win.states[win.step].name;
                    stage.grabToImage(r => {
                        if (!r.saveToFile(win.outDir + "/" + nm + ".png"))
                            win.fails++;
                        console.log("APS cell " + nm + " " + stage.width + "x" + stage.height + " ph=" + (sec.panel ? sec.panel.pageHeight : -1));
                        win.phase = "load";
                        clock.start();
                    });
                }
            }
        }
    }
}
