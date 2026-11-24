pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "../common/theme"
import "../common/components"
import "../common/glyphs"
import "../common/icons"
import "../common/components/Mix.js" as Mix
import "data/AudioModel.js" as Model

// =============================================================================
// AudioRow.qml -- one row of the Playback, Recording, Outputs or Inputs tab: pavucontrol's stream widget and device widget, in one material.
//
//   a stream     app : title | state | mute | lock channels. Its device is the patch line's to say (a chip only with the lines off)
//   a device     name : card | state | test tone | mute | lock channels | port | advanced (latency offset, formats). A click on the row makes it the default
//   right click  the devices to move to and Terminate Playback / Recording, or Set as default / Rename device / Test tone
//   sliders      one for all channels; unlocked, one per channel, with pavucontrol's percent AND dB figure in a fixed slot
//
// A ROW IS FLAT ON THE LIST'S BOX, as the network's and the launcher's are: a wash under the pointer, the tools there while the pointer is, the well under the one
// that is selected (the list's: it glides). Under sound the row carves itself in, in the accent.
//
// ONE CLOCK. Nothing here animates the row's height. Each part that comes and goes is an AudioReveal, the row is the sum of them, and the list follows it in the same frame.
//
// EVERY CONTROL WRITES THROUGH THE SERVICE, and the row reads what the node holds, never what it asked for: the slider follows the node except while
// the hand is on it. The note under the row is the service's read-back: a change that did not take says so here and stays until it is true.
//
// THE WHEEL over a slider is one step through VolumeParity (the popup routes it): every step in the shell counts from the same goal.
//
// THE METER. `meterWanted` opens a capture stream (AudioPeak), so it is on only where it wakes nothing: a stream that is running, a device that something
// is already playing to or recording from, and the Inputs tab's own rows while that tab is open, the one place the level is the point of looking
// (pavucontrol holds every microphone open for as long as its window is up; here it is that tab, and only while the popup is open).
// =============================================================================
Item {
    id: self

    required property string rowKey
    property var service: null
    property var parity: null
    property var popup: null                     // AudioPopup: openMenu(), overlayItem
    property AudioStyle style: AudioStyle {}
    property string fontFamily: "Inter"
    property bool shown: false                   // its tab is on screen
    property bool metersOn: true
    property real renderScale: 1
    property bool selected: false                // the default: the list's well is under this row
    property int armedChannel: -2                // the slider the wheel belongs to now (AudioPopup): its channel, -1 one for all, -2 none

    // The last row the service had: a row that vanishes under the hand keeps its face for the fade out.
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
    readonly property bool isDevice: !!self.row && (self.row.kind === "sink" || self.row.kind === "source")
    readonly property bool isStream: !!self.row && (self.row.kind === "playback" || self.row.kind === "recording")
    readonly property bool isRole: !!self.row && self.row.kind === "role"
    readonly property bool selectable: self.isDevice && !self.row.isMonitor && !self.selected && self.service.canCall

    readonly property var note: {
        void self.service.notesSerial;
        return self.service.noteOf(self.rowKey);
    }

    // ---- what the node holds ---------------------------------------------------------------------------------------------------
    readonly property var volumes: self.row ? self.service.volumesOf(self.row) : []
    readonly property bool muted: self.row ? self.service.mutedOf(self.row) : false
    readonly property int channelCount: self.volumes ? self.volumes.length : 0
    readonly property real average: Model.average(self.volumes)

    property bool lockChannels: true
    property bool advancedOpen: false
    property bool boost: false
    onAverageChanged: {
        if (self.average > 1)
            self.boost = true;
    }

    // ---- the level -------------------------------------------------------------------------------------------------------------
    readonly property bool meterWanted: self.metersOn && self.shown && !!self.row && !self.isRole && self.style.glowEnabled
        && (self.isStream ? !self.row.corked
            : self.row.kind === "source" ? !self.row.isMonitor
            : self.row.streams > 0)
    property real glow: 0
    readonly property real level: self.glow
    // What the patch line carries: the same sound, unstepped, that rises and falls softly, so the line's depth tapers along it instead of ending in a step.
    property real flow: 0
    AudioPeak {
        id: peak
        node: self.row ? self.row.node : null
        active: self.meterWanted
        world: self.service.machine
    }
    // One beat for the whole popup (Figures change together). Whole steps, so a level that barely moves costs no frame.
    function beat(): void {
        const raw = peak.read();
        const shaped = raw < self.style.levelFloor ? 0 : Math.pow(Math.min(1, raw), self.style.glowCurve);
        const next = Math.max(shaped, self.glow * self.style.levelDecay);
        // down to the step: rounding would hold the last step for ever (it decays back to itself)
        const stepped = Math.floor(next * self.style.levelSteps) / self.style.levelSteps;
        if (stepped !== self.glow)
            self.glow = stepped;
        const toward = shaped > self.flow ? self.flow + (shaped - self.flow) * self.style.lineRise : self.flow * self.style.lineDecay;
        self.flow = toward < 0.02 ? 0 : toward;
    }
    // A stream that stops falls away on the beat, as any peak does (the patch line carries the fall down the line). Off the screen nothing is beating.
    onShownChanged: {
        if (!self.shown)
            self.glow = self.flow = 0;
    }
    onMetersOnChanged: {
        if (!self.metersOn)
            self.glow = self.flow = 0;
    }

    // ---- writing -----------------------------------------------------------------------------------------------------------------
    function setAll(v: real): void {
        const n = Math.max(1, self.channelCount);
        const a = [];
        for (let i = 0; i < n; i++)
            a.push(v);
        self.service.setVolumes(self.row, a);
    }
    function setChannel(ch: int, v: real): void {
        const a = [];
        for (let i = 0; i < self.channelCount; i++)
            a.push(i === ch ? v : self.volumes[i]);
        self.service.setVolumes(self.row, a);
    }
    // One whole step from the popup's wheel reader (`ch` -1: all channels).
    function wheelStep(steps: int, ch: int): void {
        const n = self.row ? self.row.node : null;
        if (ch < 0 && n && n.audio && self.parity) {
            self.parity.stepNode(n, steps);
            self.service.expectVolume(self.row, self.parity.goalOf(n));
            return;
        }
        const f = 0.01 * steps;
        if (ch < 0)
            self.setAll(Math.max(0, Math.min(self.boost ? 1.53 : 1, self.average + f)));
        else
            self.setChannel(ch, Math.max(0, Math.min(self.boost ? 1.53 : 1, self.volumes[ch] + f)));
    }
    function gestureEnded(): void {
        self.service.tick(self.row);
    }
    // Which slider stands at this point of the row: its channel, -1 when one slider serves them all, -2 for none.
    function channelAt(x: real, y: real): int {
        for (let i = 0; i < sliders.count; i++) {
            const slot = sliders.itemAt(i);
            const it = slot ? slot.line : null;
            if (!it || !slot.shown)
                continue;
            const p = it.mapFromItem(self, x, y);
            if (p.x >= 0 && p.y >= 0 && p.x <= it.width && p.y <= it.height)
                return (it as AudioChannel).channel;
        }
        return -2;
    }

    function openContext(x: real, y: real): void {
        if (!self.row)
            return;
        const p = self.mapToItem(self.popup.overlayItem, x, y);
        const boostRow = { id: "boost", label: self.boost ? "Cap at 100 %" : "Allow up to 153 %" };
        const rows = [];
        if (self.isStream) {
            for (const d of self._deviceChoices())
                rows.push({ id: "to:" + d.name, label: d.shortName, check: "radio", checked: d.name === self.row.device });
            rows.push({ separator: true });
        }
        if (self.isDevice) {
            rows.push({ id: "default", label: "Set as default", disabled: self.row.isDefault || self.row.isMonitor });
            rows.push({ id: "rename", label: "Rename device…" });
            if (self.row.kind === "sink")
                rows.push({ id: "tone", label: self.service.toneKey === self.rowKey ? "Stop test tone" : "Test tone" });
        }
        rows.push(boostRow);
        if (self.isStream)
            rows.push({ id: "kill", label: self.row.kind === "playback" ? "Terminate Playback" : "Terminate Recording", danger: true });
        self.popup.openMenu(p.x, p.y, rows, id => {
            if (id.indexOf("to:") === 0)
                self.service.moveStream(self.row, id.slice(3));
            else if (id === "kill")
                self.service.terminate(self.row);
            else if (id === "default")
                self.service.setDefault(self.row);
            else if (id === "rename")
                self.popup.beginRename(self.rowKey);
            else if (id === "tone")
                self.service.playTone(self.row);
            else if (id === "boost")
                self.boost = !self.boost;
        });
    }
    function _deviceChoices(): var {
        return self.row.kind === "playback" ? self.service.rows.sinks : self.service.rows.sources.filter(s => !s.isMonitor || s.name === self.row.device);
    }
    function openDeviceChoice(from: Item): void {
        const p = from.mapToItem(self.popup.overlayItem, 0, from.height + 4);
        self.popup.openMenu(p.x, p.y, self._deviceChoices().map(d => ({ id: d.name, label: d.shortName, check: "radio", checked: d.name === self.row.device })), id => self.service.moveStream(self.row, id), 240);
    }
    function openPortChoice(from: Item): void {
        const p = from.mapToItem(self.popup.overlayItem, 0, from.height + 4);
        self.popup.openMenu(p.x, p.y, self.row.ports.map(d => ({ id: d.name, label: d.description + (d.available === false ? " (unplugged)" : ""), check: "radio", checked: d.name === self.row.activePort })), id => self.service.setPort(self.row, id), 260);
    }

    readonly property string _stateText: {
        const r = self.row;
        if (!r)
            return "";
        if (self.isStream)
            return r.corked ? "paused" : "";
        if (!self.isDevice)
            return "";
        if (r.state === "error")
            return "error";
        const port = r.ports.filter(p => p.name === r.activePort)[0];
        if (port && port.available === false)
            return "unplugged";
        return r.state === "running" ? "playing" : "";
    }
    readonly property string _subtitle: {
        const r = self.row;
        if (!r)
            return "";
        if (self.isStream)
            return r.title;
        return self.isDevice ? r.subtitle : "";
    }
    // A note that is not a change's: what the device itself is in.
    readonly property string _stateNote: {
        const r = self.row;
        if (r && self.isDevice && r.state === "error")
            return "This device has failed" + (r.error !== "" ? ": " + r.error : "") + ". Unplug it or restart the audio stack.";
        return "";
    }
    readonly property string _noteText: self.note ? self.note.text : self._stateNote
    // The words stay up while their slot closes.
    property string _noteShown: ""
    on_NoteTextChanged: {
        if (self._noteText !== "")
            self._noteShown = self._noteText;
    }

    // ---- the pointer on the row -----------------------------------------------------------------------------------------------------
    // On the root: an ancestor of every control in the row, so it takes no hover from them (CLAUDE.md, "A HOVER HANDLER ON AN ITEM STACKED OVER A LINK").
    HoverHandler {
        id: rowHover
    }
    readonly property bool hovered: rowHover.hovered
    property real _hoverF: self.hovered ? 1 : 0
    Behavior on _hoverF {
        NumberAnimation {
            duration: 120
            easing.type: Easing.OutCubic
        }
    }
    property real _mutedF: self.muted ? 1 : 0
    Behavior on _mutedF {
        NumberAnimation {
            duration: self.style.fadeMs
        }
    }
    // What the row's carved parts sit on: the list's box, the wash, or the well.
    property real _groundF: self.hovered || self.selected ? 1 : 0
    Behavior on _groundF {
        NumberAnimation {
            duration: 120
            easing.type: Easing.OutCubic
        }
    }
    readonly property color ground: Mix.c(Theme.listBox, Theme.panelSunk, self._groundF)

    implicitWidth: 300
    implicitHeight: Math.ceil(content.implicitHeight + 2 * self.style.rowPadding)

    // The row's own ground. Under everything: what is not a control is the row, and a click on it selects a device. A slider, a button or a chip takes its own.
    MouseArea {
        anchors.fill: parent
        objectName: "rowGround"
        enabled: self.selectable
        cursorShape: Qt.PointingHandCursor
        onClicked: self.service.setDefault(self.row)
    }
    Rectangle {
        id: wash
        anchors.fill: parent
        radius: self.style.rowRadius
        visible: self._hoverF > 0.001 && !self.selected
        color: Mix.c(Theme.listBox, Theme.panelSunk, self._hoverF)
    }
    // The level: the row carves itself in under the sound, in the accent. Silent, it is flat and draws nothing.
    ShadowBox {
        anchors.fill: parent
        visible: self.glow > 0
        baseRadius: self.style.rowRadius
        surfaceColor: "transparent"
        backgroundColor: "transparent"
        bevelColor: Theme.bevel
        shadowColor: Mix.c(Theme.border, self.style.glowColor, self.glow * self.style.glowMax)
        bevelWidth: 1
        shadowWidth: 3
    }

    Column {
        id: content
        x: self.style.rowPadding
        y: self.style.rowPadding
        width: self.width - 2 * self.style.rowPadding

        // ---- the head ----------------------------------------------------------------------------------------------------------
        Item {
            id: head
            width: parent.width
            height: 24

            // A device's or a role's glyph; an app's own icon when the theme has one.
            Item {
                id: mark
                width: 20
                height: 24
                readonly property string iconPath: self.isStream && self.row.icon !== "" ? AppIcons.checkedPath(self.row.icon) : ""
                DeviceScale {
                    id: dev
                }
                Image {
                    anchors.centerIn: parent
                    width: 18
                    height: 18
                    sourceSize: dev.size(18, 18)
                    source: mark.iconPath
                    visible: mark.iconPath !== ""
                }
                Text {
                    anchors.centerIn: parent
                    visible: mark.iconPath === ""
                    font.family: "Symbols Nerd Font"
                    font.pixelSize: self.style.glyphSize
                    color: self.muted ? Theme.textFaint : Theme.textMuted
                    text: {
                        if (!self.row)
                            return "";
                        if (self.isRole)
                            return "\u{F009A}";
                        if (self.isStream)
                            return self.row.kind === "playback" ? "\u{F075A}" : "\u{F036C}";
                        return self.row.kind === "sink" ? self.popup.glyphs.outputGlyph(self.row.type, 1, false) : self.popup.glyphs.inputGlyph(false);
                    }
                }
            }

            Item {
                id: titles
                x: mark.width + 6
                width: tools.x - x - 8
                height: 24
                clip: true

                Text {
                    id: titleText
                    objectName: "rowTitle"
                    visible: !self.popup || self.popup.renaming !== self.rowKey
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth + 1, parent.width)
                    elide: Text.ElideRight
                    text: !self.row ? "" : self.isDevice ? self.row.shortName : self.row.app
                    font.family: self.fontFamily
                    font.pixelSize: self.style.titleSize
                    // the selected device speaks up, as the connected network does; a stream's name is always the row's head
                    font.bold: !self.isDevice || self.selected
                    color: Mix.c(Theme.textPrimary, Theme.textMuted, self._mutedF)
                }
                Text {
                    visible: titleText.visible && self._subtitle !== "" && x < parent.width - 24
                    x: titleText.x + titleText.width + 8
                    width: parent.width - x
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: self._subtitle
                    font.family: self.fontFamily
                    font.pixelSize: self.style.subtitleSize
                    color: Theme.textMuted
                }
                Loader {
                    id: renameLoader
                    active: !!self.popup && self.popup.renaming === self.rowKey
                    anchors.fill: parent
                    sourceComponent: AudioRenameField {
                        text: self.row ? self.row.description : ""
                        fontFamily: self.fontFamily
                        fontSize: self.style.titleSize
                        onAccepted: t => {
                            self.service.setLabel(self.row, t);
                            self.popup.endRename();
                        }
                        onCancelled: self.popup.endRename()
                    }
                }
            }

            Row {
                id: tools
                x: parent.width - width
                height: 24
                spacing: 2

                Text {
                    visible: self._stateText !== ""
                    rightPadding: 6
                    height: 24
                    verticalAlignment: Text.AlignVCenter
                    text: self._stateText
                    font.family: self.fontFamily
                    font.pixelSize: self.style.subtitleSize
                    color: self._stateText === "error" ? self.style.noteColor : self._stateText === "playing" ? Theme.accent : Theme.textFaint
                }
                // A stream's device, when no line says it.
                AudioChoice {
                    visible: self.isStream && !self.style.linesEnabled
                    y: 0
                    label: self.row && self.row.kind === "recording" ? "from" : "on"
                    value: !self.isStream ? "" : self.row.deviceDescription !== "" ? self.row.deviceDescription : self.row.kind === "playback" ? "Unknown output" : "Unknown input"
                    maxWidth: 190
                    enabled: self.service.canCall
                    tip: self.service.canCall ? "" : self.service.healthReason
                    overlayItem: self.popup ? self.popup.overlayItem : null
                    fontFamily: self.fontFamily
                    ground: self.ground
                    onPicked: from => self.openDeviceChoice(from)
                }
                AudioGlyphButton {
                    id: toneButton
                    objectName: "toneButton"
                    visible: self.isDevice && self.row.kind === "sink"
                    glyph: self.service.toneKey === self.rowKey ? "\u{F04DB}" : "\u{F0387}"
                    on: self.service.toneKey === self.rowKey
                    tip: toneButton.on ? "Stop test tone" : "Test tone"
                    overlayItem: self.popup ? self.popup.overlayItem : null
                    fontFamily: self.fontFamily
                    onClicked: self.service.playTone(self.row)
                }
                AudioGlyphButton {
                    id: muteButton
                    objectName: "muteButton"
                    glyph: !self.row ? "" : self.isDevice && self.row.kind === "source" || self.row.kind === "recording"
                        ? (self.muted ? "\u{F036D}" : "\u{F036C}") : (self.muted ? "\u{F0581}" : "\u{F057E}")
                    on: self.muted
                    tip: !self.row ? "" : self.row.kind === "source"
                        ? (self.muted ? "Unmute microphone" : "Mute microphone") : (self.muted ? "Unmute" : "Mute")
                    overlayItem: self.popup ? self.popup.overlayItem : null
                    fontFamily: self.fontFamily
                    onClicked: self.service.setMuted(self.row, !self.muted)
                }
                AudioGlyphButton {
                    id: lockButton
                    objectName: "lockButton"
                    visible: self.channelCount > 1
                    glyph: self.lockChannels ? "\u{F033E}" : "\u{F0FC6}"
                    on: !self.lockChannels
                    enabled: !self.muted
                    tip: self.lockChannels ? "Unlock channels" : "Lock channels"
                    overlayItem: self.popup ? self.popup.overlayItem : null
                    fontFamily: self.fontFamily
                    onClicked: self.lockChannels = !self.lockChannels
                }
                Item {
                    id: advancedButton
                    objectName: "advancedButton"
                    visible: self.isDevice && (self.row.ports.length > 0 || self.row.digital)
                    width: 24
                    height: 24
                    Chevron {
                        anchors.centerIn: parent
                        size: 11
                        thickness: 1.6
                        rotation: 180 * advancedSlot.f
                        color: Mix.c(self.advancedOpen ? Theme.accent : Theme.textMuted, BarHues.audioHover, advancedButton.advancedHoverF)
                    }
                    property real advancedHoverF: advancedArea.containsMouse ? 1 : 0
                    Behavior on advancedHoverF {
                        GlyphHoverEase {}
                    }
                    MouseArea {
                        id: advancedArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: self.advancedOpen = !self.advancedOpen
                    }
                }
            }
        }

        // ---- the port ----------------------------------------------------------------------------------------------------------
        AudioReveal {
            shown: self.isDevice && self.row.ports.length > 1
            width: parent.width
            naturalHeight: 4 + 24
            durationMs: self.style.resizeMs
            Row {
                y: 4
                spacing: 8
                AudioChoice {
                    id: portChoice
                    objectName: "portChoice"
                    label: "Port"
                    value: {
                        const r = self.row;
                        if (!r || !self.isDevice)
                            return "";
                        const p = r.ports.filter(x => x.name === r.activePort)[0];
                        return p ? p.description : r.activePort;
                    }
                    maxWidth: 280
                    enabled: self.service.canCall
                    tip: self.service.canCall ? "" : self.service.healthReason
                    overlayItem: self.popup ? self.popup.overlayItem : null
                    fontFamily: self.fontFamily
                    ground: self.ground
                    onPicked: from => self.openPortChoice(from)
                }
                Text {
                    visible: !!self.row && self.isDevice && self.row.baseVolume < 0.995
                    height: 24
                    verticalAlignment: Text.AlignVCenter
                    text: self.row ? "Base " + Model.percentText(self.row.baseVolume) : ""
                    font.family: self.fontFamily
                    font.pixelSize: self.style.subtitleSize
                    color: Theme.textFaint
                }
            }
        }

        // ---- the sliders -------------------------------------------------------------------------------------------------------
        // One line for the channels together; unlocked, the others open under it. Built when first opened: most rows never are.
        Repeater {
            id: sliders
            model: Math.max(1, self.channelCount)
            delegate: AudioReveal {
                id: chan
                required property int index
                readonly property var line: lineLoader.item
                readonly property bool together: self.lockChannels || self.channelCount < 2
                shown: chan.index === 0 || !chan.together
                width: content.width
                naturalHeight: 4 + lineLoader.height
                durationMs: self.style.resizeMs
                Loader {
                    id: lineLoader
                    y: 4
                    width: parent.width
                    active: chan.index === 0 || chan.shown || chan.f > 0
                    sourceComponent: AudioChannel {
                        objectName: "channel"
                        channel: chan.together ? -1 : chan.index
                        label: chan.together || !self.row ? "" : Model.channelLabel((self.row.channels || [])[chan.index] || "")
                        value: chan.together ? self.average : (self.volumes[chan.index] || 0)
                        muted: self.muted
                        mutedF: self._mutedF
                        boost: self.boost
                        armed: self.armedChannel === channel
                        ground: self.ground
                        style: self.style
                        fontFamily: self.fontFamily
                        renderScale: self.renderScale
                        decibels: !self.isDevice || self.row.canDecibel
                        onMoved: v => {
                            if (channel < 0)
                                self.setAll(v);
                            else
                                self.setChannel(channel, v);
                        }
                        onHeldChanged: {
                            self.service.heldKey = held ? self.rowKey : "";
                            if (!held)
                                self.gestureEnded();
                        }
                    }
                }
            }
        }

        // ---- advanced ---------------------------------------------------------------------------------------------------------
        AudioReveal {
            id: advancedSlot
            shown: self.advancedOpen && self.isDevice
            width: parent.width
            naturalHeight: advancedLoader.height
            durationMs: self.style.resizeMs
            Loader {
                id: advancedLoader
                active: advancedSlot.shown || advancedSlot.f > 0
                width: parent.width
                sourceComponent: AudioAdvanced {
                    row: self.row
                    service: self.service
                    style: self.style
                    fontFamily: self.fontFamily
                    overlayItem: self.popup ? self.popup.overlayItem : null
                    ground: self.ground
                }
            }
        }

        // ---- what did not take ---------------------------------------------------------------------------------------------------
        AudioReveal {
            shown: self._noteText !== ""
            width: parent.width
            naturalHeight: 4 + noteLine.implicitHeight
            durationMs: self.style.resizeMs
            Text {
                id: noteLine
                objectName: "noteLine"
                y: 4
                width: parent.width
                wrapMode: Text.WordWrap
                text: self._noteShown
                font.family: self.fontFamily
                font.pixelSize: self.style.noteSize
                color: self.style.noteColor
            }
        }
    }

    // The right click, over everything: a slider takes every button, and a row answers it wherever it lands. Left and wheel pass through.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        cursorShape: undefined   // the left button passes through: the cursor is what lies under it (a MouseArea owns an Arrow)
        onClicked: mouse => self.openContext(mouse.x, mouse.y)
    }
}
