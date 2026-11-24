pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/RelTime.js" as Rel
import "PanelWords.js" as Words
import "SavedSearch.js" as Search

// =============================================================================
// SavedPanel.qml -- the memory chip's panel: every saved Wi-Fi profile, "Add a network" by name, and the Card page (the network card
// itself: power saving, the country the firmware chose, driver and firmware, the real MAC, what it can do).
//
//   vm   an AerialService or an AerialMock
//
// Networks: one row per profile -- its name, when it was last used (a relative time on ONE BoundaryClock: it changes only on a
// boundary somebody shows), a dot when it is in range. A tap opens the row (one at a time): autoconnect, priority (- / +), the
// password on request (shown only while asked: cleared when the row closes, after 30 s and with the panel), Forget, and "Merge N
// doubles" where the profile has doubles. The doubles are the SAME network saved twice (the finder is the data layer's).
//
// SEARCH (round 2): a field over the list filters as you type -- name and SSID, case- and accent-insensitive, every word of the query
// found (SavedSearch.js) -- and the match shows in the accent ink. The field holds the item focus while the list page is shown (the
// compositor's keys still come by `keyboardWanted`, the popup's ask); Escape clears the query FIRST (`handleEscape()` true: it took the
// key); with nothing to clear it answers false and the engine's Escape rule closes the popup, or the panel first.
// =============================================================================
PanelFrame {
    id: panel

    property var vm: null
    property string expanded: ""
    property string secretUuid: ""
    property string secretText: ""

    signal dismissed()

    readonly property var wifi: panel.vm ? panel.vm.wifi : null
    readonly property var profiles: panel.wifi ? panel.wifi.profiles.filter(p => p.ssid !== "" || p.name !== "") : []
    readonly property string query: searchField.text
    // the rows the query leaves: { p: the profile, m: its match (the spans) }
    readonly property var rows: {
        const out = [];
        const ps = panel.profiles;
        for (let i = 0; i < ps.length; i++) {
            const m = Search.match(panel.query, ps[i].name, ps[i].ssid);
            if (m !== null)
                out.push({ p: ps[i], m: m });
        }
        return out;
    }
    readonly property bool searching: Search.words(panel.query).length > 0
    readonly property bool wantsKeys: panel.page === "add" || (panel.page === "list" && panel.profiles.length > 0)
    readonly property string _accentHex: String(Theme.accent)

    title: "Saved networks"
    subtitle: panel.profiles.length === 0 ? "No network is saved yet"
        : panel.searching ? panel.rows.length + " of " + panel.profiles.length + (panel.profiles.length === 1 ? " network" : " networks")
        : panel.profiles.length + (panel.profiles.length === 1 ? " network" : " networks")
    tabs: [{ id: "list", label: "Networks" }, { id: "add", label: "Add" }, { id: "card", label: "Card" }]

    function handleEscape(): bool {
        if (searchField.text !== "") {
            searchField.clear();
            return true;
        }
        return false;
    }
    function focusSearch(): void {
        if (panel.page === "list" && panel.profiles.length > 0)
            searchField.forceFocus();
    }
    Component.onCompleted: Qt.callLater(panel.focusSearch)
    function _clearSecret(): void {
        panel.secretText = "";
        panel.secretUuid = "";
    }
    onPageChanged: {
        panel._clearSecret();
        Qt.callLater(panel.focusSearch);
    }
    onExpandedChanged: panel._clearSecret()
    Component.onDestruction: panel._clearSecret()
    Connections {
        target: panel.vm
        function onSecret(uuid: string, text: string): void {
            if (uuid === panel.secretUuid && uuid !== "")
                panel.secretText = text;
        }
    }
    Timer {
        interval: 30000
        running: panel.secretText !== ""
        onTriggered: panel._clearSecret()
    }

    BoundaryClock { id: clock }

    // =====================================================================================================================================
    PanelPage {
        look: panel.look
        pageId: "list"
        shown: panel.page === "list"

        PanelCard {
            look: panel.look
            PText {
                look: panel.look
                tone: 1
                width: parent.width
                wrapMode: Text.WordWrap
                shown: panel.profiles.length === 0
                text: "Join a network, or add one by name on the Add page."
            }
            PanelField {
                id: searchField
                objectName: "savedSearch"
                look: panel.look
                visible: panel.profiles.length > 0
                height: visible ? implicitHeight : 0
                placeholder: "Search saved networks"
                onEscaped: panel.handleEscape()
            }
            PText {
                objectName: "savedNoMatch"
                look: panel.look
                tone: 1
                width: parent.width
                wrapMode: Text.WordWrap
                shown: panel.profiles.length > 0 && panel.rows.length === 0
                text: "No saved network matches"
            }
            Repeater {
                model: panel.rows.length
                delegate: Column {
                    id: row
                    required property int index
                    readonly property var r: panel.rows[row.index] || ({ p: null, m: null })
                    readonly property var m: row.r.m || ({ nameSpan: null, ssidSpan: null })
                    readonly property var p: row.r.p || ({ uuid: "", name: "", ssid: "", security: "", autoconnect: false, priority: 0, lastUsedMs: 0, inRange: false, trusted: true, doubles: [] })
                    // the SSID is told on the second line only when the match is there and the name does not show it
                    readonly property bool ssidMatch: row.m.ssidSpan !== null && row.m.nameSpan === null && row.p.ssid !== row.p.name
                    readonly property bool open: panel.expanded === row.p.uuid
                    readonly property var rel: Rel.format(row.p.lastUsedMs, clock.now, { justNow: "just now", suffix: " ago" })
                    onRelChanged: clock.request(row.rel.nextMs)
                    Component.onCompleted: clock.request(row.rel.nextMs)
                    width: parent.width
                    spacing: 8

                    Item {
                        width: parent.width
                        height: 34
                        MouseArea {
                            objectName: "savedRow_" + row.index
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: panel.expanded = row.open ? "" : row.p.uuid
                        }
                        Rectangle {
                            id: dot
                            width: 8
                            height: 8
                            radius: 4
                            y: 6
                            color: row.p.inRange ? Theme.ok : Theme.border
                        }
                        PText {
                            look: panel.look
                            x: 16
                            y: 0
                            width: parent.width - 16 - when.implicitWidth - 8
                            elide: Text.ElideRight
                            textFormat: Text.StyledText
                            text: Search.styled(row.p.name, row.m.nameSpan, panel._accentHex)
                        }
                        PText {
                            look: panel.look
                            tone: 1
                            small: true
                            x: 16
                            y: 17
                            textFormat: row.ssidMatch ? Text.StyledText : Text.PlainText
                            text: row.ssidMatch ? Search.styled(row.p.ssid, row.m.ssidSpan, panel._accentHex) + " · " + Words.security(row.p.security) + (row.p.trusted ? "" : " · Public")
                                                : Words.security(row.p.security) + (row.p.trusted ? "" : " · Public")
                        }
                        PText {
                            id: when
                            look: panel.look
                            tone: 1
                            small: true
                            x: parent.width - implicitWidth
                            y: 2
                            text: row.p.lastUsedMs > 0 ? row.rel.text : "never"
                        }
                    }
                    Column {
                        width: parent.width
                        spacing: 8
                        visible: row.open
                        height: row.open ? implicitHeight : 0
                        SwitchRow {
                            objectName: "autoSwitch_" + row.index
                            look: panel.look
                            title: "Join automatically"
                            checked: row.p.autoconnect
                            onToggled: c => {
                                if (panel.vm)
                                    panel.vm.setAutoconnect(row.p.uuid, c);
                            }
                        }
                        Item {
                            width: parent.width
                            height: 28
                            PText {
                                look: panel.look
                                text: "Priority"
                                y: Math.round((parent.height - implicitHeight) / 2)
                            }
                            PanelButton {
                                id: lessBtn
                                objectName: "prioDown_" + row.index
                                look: panel.look
                                x: parent.width - width * 2 - 60 - 16
                                width: 28
                                horizontalPadding: 0
                                text: "\u2212"
                                onClicked: if (panel.vm) panel.vm.setPriority(row.p.uuid, row.p.priority - 1)
                            }
                            PText {
                                look: panel.look
                                x: lessBtn.x + lessBtn.width + 8
                                width: 44
                                horizontalAlignment: Text.AlignHCenter
                                y: Math.round((parent.height - implicitHeight) / 2)
                                text: String(row.p.priority)
                            }
                            PanelButton {
                                objectName: "prioUp_" + row.index
                                look: panel.look
                                x: parent.width - width
                                width: 28
                                horizontalPadding: 0
                                text: "+"
                                onClicked: if (panel.vm) panel.vm.setPriority(row.p.uuid, row.p.priority + 1)
                            }
                        }
                        PText {
                            look: panel.look
                            tone: 1
                            small: true
                            text: "Higher joins first."
                        }
                        FactRow {
                            look: panel.look
                            label: "Password"
                            value: panel.secretUuid === row.p.uuid ? panel.secretText : ""
                        }
                        ButtonRow {
                            PanelButton {
                                objectName: "revealSaved_" + row.index
                                look: panel.look
                                text: panel.secretUuid === row.p.uuid && panel.secretText !== "" ? "Hide password" : "Show password"
                                visible: Words.secured(row.p.security) && row.p.security !== "eap"
                                onClicked: {
                                    if (panel.secretUuid === row.p.uuid && panel.secretText !== "") {
                                        panel._clearSecret();
                                    } else if (panel.vm) {
                                        panel.secretUuid = row.p.uuid;
                                        panel.vm.revealSecret(row.p.uuid);
                                    }
                                }
                            }
                            PanelButton {
                                objectName: "mergeDoubles_" + row.index
                                look: panel.look
                                text: "Merge " + row.p.doubles.length + (row.p.doubles.length === 1 ? " double" : " doubles")
                                visible: row.p.doubles.length > 0
                                onClicked: if (panel.vm) panel.vm.mergeDoubles(row.p.uuid, row.p.doubles)
                            }
                            ForgetButton {
                                objectName: "forget_" + row.index
                                look: panel.look
                                live: row.open
                                onForgetRequested: {
                                    panel.expanded = "";
                                    if (panel.vm)
                                        panel.vm.forget(row.p.uuid);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // =====================================================================================================================================
    PanelPage {
        id: addPage
        look: panel.look
        pageId: "add"
        shown: panel.page === "add"

        property string security: "wpa2"
        readonly property bool needsPw: security !== "open"

        PanelCard {
            look: panel.look
            FieldBlock {
                id: addName
                look: panel.look
                label: "Network name"
                placeholder: "The name of the network"
                fieldObjectName: "addName"
                onAccepted: addPw.shown ? addPw.field.forceFocus() : addBtn.clicked()
            }
            PText { look: panel.look; text: "Security" }
            ChoiceList {
                look: panel.look
                options: [{ key: "open", label: "Open" }, { key: "wpa2", label: "WPA2" }, { key: "wpa3", label: "WPA3" }]
                current: addPage.security
                onChosen: k => addPage.security = k
            }
            FieldBlock {
                id: addPw
                look: panel.look
                label: "Password"
                placeholder: "Type the password"
                secret: true
                shown: addPage.needsPw
                fieldObjectName: "addPw"
                onAccepted: addBtn.clicked()
            }
            ButtonRow {
                PanelButton {
                    id: addBtn
                    objectName: "addNetwork"
                    look: panel.look
                    accent: true
                    text: "Add network"
                    enabled: addName.text !== "" && (!addPw.shown || addPw.text !== "")
                    onClicked: {
                        if (!enabled || !panel.vm)
                            return;
                        panel.vm.addNetwork(addName.text, addPage.security, addPw.shown ? addPw.text : "");
                        addName.field.clear();
                        addPw.field.clear();
                        panel.page = "list";
                    }
                }
            }
        }
    }

    // =====================================================================================================================================
    PanelPage {
        id: cardPage
        look: panel.look
        pageId: "card"
        shown: panel.page === "card"

        readonly property var caps: panel.wifi && panel.wifi.capabilities ? panel.wifi.capabilities
            : (panel.wifi && panel.wifi.driver === "iwlwifi" ? ["Wi-Fi 6E", "2x2", "AP"] : [])

        PanelCard {
            look: panel.look
            visible: !!panel.wifi && panel.wifi.present
            SwitchRow {
                objectName: "powersaveSwitch"
                look: panel.look
                title: "Power saving"
                hint: "On saves battery; off answers a little faster."
                checked: !!panel.wifi && panel.wifi.powersave === true
                onToggled: c => {
                    if (panel.vm)
                        panel.vm.setPowersave(c);
                }
            }
        }
        PanelCard {
            look: panel.look
            PText {
                look: panel.look
                tone: 1
                width: parent.width
                wrapMode: Text.WordWrap
                shown: !panel.wifi || !panel.wifi.present
                text: "This machine has no Wi-Fi card."
            }
            FactRow { look: panel.look; label: "Interface"; value: panel.wifi ? panel.wifi.iface : "" }
            FactRow { look: panel.look; label: "Country"; value: panel.wifi ? panel.wifi.country : "" }
            FactRow { look: panel.look; label: "Driver"; value: panel.wifi ? panel.wifi.driver : "" }
            FactRow { look: panel.look; label: "Firmware"; value: panel.wifi ? panel.wifi.firmware : "" }
            FactRow { look: panel.look; label: "Real MAC"; value: panel.wifi ? (panel.wifi.permMac || panel.wifi.mac) : "" }
            FactRow { look: panel.look; label: "Abilities"; value: cardPage.caps.join(" · ") }
        }
        PanelCard {
            look: panel.look
            visible: !!panel.wifi && !!panel.wifi.others && panel.wifi.others.length > 0
            PText { look: panel.look; text: "Other Wi-Fi devices" }
            Repeater {
                model: panel.wifi && panel.wifi.others ? panel.wifi.others.length : 0
                delegate: PText {
                    required property int index
                    look: panel.look
                    tone: 1
                    text: panel.wifi.others[index].iface + (panel.wifi.others[index].driver ? " · " + panel.wifi.others[index].driver : "")
                }
            }
        }
    }
}
