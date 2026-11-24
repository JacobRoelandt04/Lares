pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"

// =============================================================================
// AudioCardRow.qml -- the Configuration tab's row: a card, its Profile, and its Codec when it is a Bluetooth card. Profiles the card calls unavailable carry the
// word, and `hideUnavailable` drops them: pavucontrol's own check box. A profile that does not take says so here, like everything else.
//
// pavucontrol's "lock card to this profile" is a PulseAudio message (`set-profile-sticky`) that pipewire-pulse does not have: it answers No such entity
// (measured on this machine), and pavucontrol hides the button for the same reason. So there is none here.
// =============================================================================
Item {
    id: self

    required property string rowKey
    property var service: null
    property var popup: null
    property AudioStyle style: AudioStyle {}
    property string fontFamily: "Inter"

    property var _kept: null
    readonly property var row: {
        void self.service.rowsSerial;
        const r = self.service.rowOf(self.rowKey);
        return r ? r : self._kept;
    }
    onRowChanged: {
        if (self.row)
            self._kept = self.row;
    }
    readonly property var note: {
        void self.service.notesSerial;
        return self.service.noteOf(self.rowKey);
    }
    readonly property bool hideUnavailable: self.service.settings.hideUnavailable === true

    function _openProfiles(from: Item): void {
        const r = self.row;
        const p = from.mapToItem(self.popup.overlayItem, 0, from.height + 4);
        const list = r.profiles.filter(x => !self.hideUnavailable || x.available || x.name === r.activeProfile);
        self.popup.openMenu(p.x, p.y, list.map(x => ({ id: x.name, label: x.description + (x.available ? "" : " (unavailable)"), check: "radio", checked: x.name === r.activeProfile })), id => self.service.setProfile(r, id), 420);
    }
    function _openCodecs(from: Item): void {
        const r = self.row;
        const p = from.mapToItem(self.popup.overlayItem, 0, from.height + 4);
        self.popup.openMenu(p.x, p.y, r.codecs.map(x => ({ id: x.name, label: x.description, check: "radio", checked: x.name === r.activeCodec })), id => self.service.setCodec(r, id), 200);
    }
    readonly property string _profileText: {
        const r = self.row;
        if (!r)
            return "";
        const p = r.profiles.filter(x => x.name === r.activeProfile)[0];
        return p ? p.description : r.activeProfile;
    }
    readonly property string _codecText: {
        const r = self.row;
        if (!r)
            return "";
        const c = r.codecs.filter(x => x.name === r.activeCodec)[0];
        return c ? c.description : "";
    }

    implicitHeight: Math.ceil(content.implicitHeight + 2 * self.style.rowPadding)

    Column {
        id: content
        x: self.style.rowPadding
        y: self.style.rowPadding
        width: self.width - 2 * self.style.rowPadding
        spacing: 6
        Row {
            spacing: 8
            Text {
                height: 22
                width: 20
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignHCenter
                font.family: "Symbols Nerd Font"
                font.pixelSize: self.style.glyphSize
                color: Theme.textMuted
                text: self.row && self.popup ? self.popup.glyphs.outputGlyph(self.row.type, 1, false) : ""
            }
            Text {
                height: 22
                verticalAlignment: Text.AlignVCenter
                text: self.row ? self.row.description : ""
                font.family: self.fontFamily
                font.pixelSize: self.style.titleSize
                font.bold: true
                color: Theme.textPrimary
            }
        }
        Row {
            spacing: 8
            AudioChoice {
                objectName: "profileChoice"
                label: "Profile"
                value: self._profileText
                maxWidth: content.width
                enabled: self.service.canCall
                tip: self.service.canCall ? "" : self.service.healthReason
                overlayItem: self.popup ? self.popup.overlayItem : null
                fontFamily: self.fontFamily
                ground: Theme.listBox
                onPicked: from => self._openProfiles(from)
            }
        }
        Row {
            visible: !!self.row && self.row.codecs.length > 0
            height: visible ? implicitHeight : 0
            spacing: 8
            AudioChoice {
                objectName: "codecChoice"
                label: "Codec"
                value: self._codecText
                maxWidth: 240
                enabled: self.service.canCall
                tip: self.service.canCall ? "" : self.service.healthReason
                overlayItem: self.popup ? self.popup.overlayItem : null
                fontFamily: self.fontFamily
                ground: Theme.listBox
                onPicked: from => self._openCodecs(from)
            }
        }
        Item {
            width: content.width
            visible: !!self.note
            height: visible ? noteLine.implicitHeight : 0
            Text {
                id: noteLine
                objectName: "noteLine"
                width: parent.width
                wrapMode: Text.WordWrap
                text: self.note ? self.note.text : ""
                font.family: self.fontFamily
                font.pixelSize: self.style.noteSize
                color: self.style.noteColor
            }
        }
    }
}
