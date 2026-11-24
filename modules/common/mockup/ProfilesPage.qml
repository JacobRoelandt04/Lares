pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// =============================================================================
// ProfilesPage -- the framework's own tab, appended after the mockup's.
//
// Profiles: every tweakable value as one JSON file, saved, loaded,
// overwritten and deleted here, above the derived `default` profile that
// mirrors the mockup's val: entries. File defaults: "Save to mockup" and
// "Reset everything", with the save script's report underneath.
// =============================================================================
MockupPage {
    id: profilesPage

    property MockupRegistry registry: null
    property MockupStore store: null

    readonly property int modifiedTotal: profilesPage.registry ? profilesPage.registry.modifiedCount(profilesPage.registry.defaultsRev, profilesPage.registry.listIds, null) : 0
    readonly property int saveableTotal: profilesPage.registry ? profilesPage.registry.modifiedCount(profilesPage.registry.defaultsRev, profilesPage.registry.savedIds(), null) : 0

    Label {
        Layout.fillWidth: true
        text: "A profile is every tweakable value as one JSON file under " + (profilesPage.store ? profilesPage.store.profileDir : "") + ". Load applies it in one go; the * marks then show what differs from the mockup's defaults."
        color: "#8A8A8C"
        font.family: "Audiowide"
        font.pixelSize: 13
        wrapMode: Text.Wrap
    }

    TipRow {
        tip: "Saves the current values as <name>.json. Letters, digits, space, dot, dash and underscore only, and not \"default\" — that one is the derived file-default profile."
        TextField {
            id: profileName
            // The reserved name is refused here as well as in the store and
            // the script, so the button never offers a save that cannot work.
            readonly property bool nameOk: profilesPage.store && profilesPage.store.validProfileName(profileName.text) && !profilesPage.store.isDefaultProfile(profileName.text)
            Layout.fillWidth: true
            placeholderText: "profile name"
            font.family: "Audiowide"
            font.pixelSize: 14
            selectByMouse: true
            onAccepted: if (profileName.nameOk)
                profilesPage.store.saveProfile(text.trim())
        }
        Button {
            text: "Save as"
            enabled: profileName.nameOk && !profilesPage.store.profileBusy
            onClicked: profilesPage.store.saveProfile(profileName.text.trim())
        }
    }

    TipGroup {
        title: "Default profile"
        blurb: "The mockup's val: entries, rewritten to default.json at every launch — the file a deployed module reads instead of this QML."
    }

    TipRow {
        tip: "Load puts every value back to the mockup's file defaults, the same set Reset everything restores. Save-over and Delete are refused: the file is regenerated at every launch, so anything kept here would go without a word."
        Label {
            id: defaultRow
            readonly property bool isCurrent: profilesPage.store && profilesPage.store.currentProfile === profilesPage.store.defaultProfileName
            text: (profilesPage.store ? profilesPage.store.defaultProfileName : "default") + (defaultRow.isCurrent ? "  ●" : "")
            color: defaultRow.isCurrent ? "#4480F4" : "#5D5D5F"
            font.family: "Audiowide"
            font.pixelSize: 14
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
        Button {
            text: "Load"
            font.pixelSize: 13
            padding: 5
            enabled: profilesPage.store && profilesPage.store.profileNames.indexOf(profilesPage.store.defaultProfileName) >= 0
            onClicked: profilesPage.store.loadProfile(profilesPage.store.defaultProfileName)
        }
    }

    TipGroup {
        title: "Saved profiles"
        blurb: !profilesPage.store || profilesPage.store.savedProfileNames.length === 0 ? "None yet." : ""
    }

    Repeater {
        model: profilesPage.store ? profilesPage.store.savedProfileNames : []
        delegate: RowLayout {
            id: profileRow
            required property string modelData
            readonly property bool isCurrent: profilesPage.store && profilesPage.store.currentProfile === profileRow.modelData
            // Delete arms on the first click and fires on the second within
            // three seconds, so a tuning set is not lost to one stray click.
            property bool armed: false
            Layout.fillWidth: true
            spacing: 6
            Timer {
                id: disarm
                interval: 3000
                onTriggered: profileRow.armed = false
            }
            Label {
                text: profileRow.modelData + (profileRow.isCurrent ? "  ●" : "")
                color: profileRow.isCurrent ? "#4480F4" : "#5D5D5F"
                font.family: "Audiowide"
                font.pixelSize: 14
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
            Button {
                text: "Load"
                font.pixelSize: 13
                padding: 5
                onClicked: profilesPage.store.loadProfile(profileRow.modelData)
            }
            Button {
                text: "Overwrite"
                font.pixelSize: 13
                padding: 5
                enabled: !profilesPage.store.profileBusy
                onClicked: profilesPage.store.saveProfile(profileRow.modelData)
            }
            Button {
                text: profileRow.armed ? "Sure?" : "Delete"
                font.pixelSize: 13
                padding: 5
                enabled: !profilesPage.store.profileBusy
                palette.buttonText: profileRow.armed ? "#EC0000" : "#5D5D5F"
                onClicked: {
                    if (profileRow.armed) {
                        profileRow.armed = false;
                        profilesPage.store.deleteProfile(profileRow.modelData);
                    } else {
                        profileRow.armed = true;
                        disarm.restart();
                    }
                }
            }
        }
    }

    Label {
        visible: profilesPage.store && profilesPage.store.profileStatus.length > 0
        Layout.fillWidth: true
        text: profilesPage.store ? profilesPage.store.profileStatus : ""
        color: "#8A8A8C"
        font.family: "Audiowide"
        font.pixelSize: 13
        wrapMode: Text.Wrap
    }

    TipGroup {
        title: "File defaults"
        blurb: "The val: entries in " + (profilesPage.store ? profilesPage.store.mockupFile.replace(/^.*\//, "") : "the mockup") + ", which Reset and the * marks compare against."
    }

    TipRow {
        tip: "Same as the button in the strip above: writes every * value of the mockup's own lists (not a themed or a file-backed one) into the module that ships it and into the mockup's val: entries, and reports each one below."
        Button {
            text: profilesPage.store && profilesPage.store.saving ? "Saving…" : "Save to mockup"
            enabled: profilesPage.store && !profilesPage.store.saving && profilesPage.saveableTotal > 0
            onClicked: profilesPage.store.saveToMockup()
        }
        Button {
            text: "Reset everything"
            enabled: profilesPage.modifiedTotal > 0
            onClicked: {
                profilesPage.registry.applyDefaults(profilesPage.registry.listIds);
                profilesPage.store.currentProfile = "";
            }
        }
        Item {
            Layout.fillWidth: true
        }
    }

    Label {
        visible: profilesPage.store && profilesPage.store.saveStatus.length > 0
        Layout.fillWidth: true
        text: profilesPage.store ? profilesPage.store.saveStatus : ""
        color: "#5D5D5F"
        font.family: "Consolas"
        font.pixelSize: 12
        wrapMode: Text.Wrap
    }
}
