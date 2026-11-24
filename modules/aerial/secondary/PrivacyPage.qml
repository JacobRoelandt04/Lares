pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// PrivacyPage.qml -- the Privacy page of a network: which MAC address it sees (the real one, a random one each time, one that is
// stable for this network) and whether it counts as metered (a metered network is one the shell's big jobs leave alone). Each choice
// is written at once (`updateProfile(uuid, { mac })` / `{ metered }`); the ball follows the FACT, so a refused write leaves it where
// it was. `prof` is the profile record; none (a network not joined yet) says so and offers nothing to write.
// =============================================================================
PanelPage {
    id: page

    property var vm: null
    property var prof: null
    property string uuid: ""
    property string macUsed: ""

    // The profile record may not carry these two (the contract's Profile lists neither): the ball then follows the last choice made here.
    property string _chosenMac: ""
    property string _chosenMetered: ""
    readonly property string _mac: page.prof && page.prof.macPolicy !== undefined ? String(page.prof.macPolicy) : page._chosenMac
    readonly property string _metered: page.prof && page.prof.metered !== undefined ? String(page.prof.metered) : page._chosenMetered

    PanelCard {
        look: page.look
        PText {
            look: page.look
            strong: false
            text: "Address this network sees"
        }
        ChoiceList {
            look: page.look
            options: [
                { key: "permanent", label: "Real address" },
                { key: "random", label: "Random each time" },
                { key: "stable", label: "Stable for this network" }
            ]
            current: ["permanent", "random", "stable"].indexOf(page._mac) >= 0 ? page._mac : ""
            onChosen: k => {
                if (page.vm && page.uuid !== "") {
                    page._chosenMac = k;
                    page.vm.updateProfile(page.uuid, { mac: k });
                }
            }
        }
        PText {
            look: page.look
            tone: 1
            small: true
            width: parent.width
            wrapMode: Text.WordWrap
            shown: text !== ""
            text: page.uuid === "" ? "Join the network once and this can be changed."
                : ["permanent", "random", "stable"].indexOf(page._mac) < 0 ? "Now: the system's default." : ""
        }
        FactRow {
            look: page.look
            label: "In use"
            value: page.macUsed
        }
    }
    PanelCard {
        look: page.look
        PText {
            look: page.look
            text: "Data use"
        }
        ChoiceList {
            look: page.look
            options: [
                { key: "unknown", label: "Let the system decide" },
                { key: "yes", label: "Metered: limited data" },
                { key: "no", label: "Not metered" }
            ]
            current: ["unknown", "yes", "no"].indexOf(page._metered) >= 0 ? page._metered : ""
            onChosen: k => {
                if (page.vm && page.uuid !== "") {
                    page._chosenMetered = k;
                    page.vm.updateProfile(page.uuid, { metered: k });
                }
            }
        }
    }
}
