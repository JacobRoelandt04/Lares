pragma ComponentBehavior: Bound

import QtQuick

import ".."
import "../../common/theme"
import "../../common/components"
import "../data/BridgeModel.js" as Model

// =============================================================================
// DeviceSheet.qml -- the device's sheet: what the phone says about itself, and the controls you rarely want. The content
// of the Details page (DevicePage), on the display's ground, in the theme's inks.
//
//   THE SHEET   the model (the tool's `facts.model`, else the name), Android version, the free storage ("311 of 512 GiB", a thin gauge),
//               battery (charge; health and temperature when the facts have them), the link and the address
//               (`kdc.addresses[0]`) and the KDE Connect verification key. A fact the device does not have is left out
//               -- never a row of dashes.
//   CONTROLS    "Keep wireless ready" (a switch over `prefs.keepWireless`, ON by default: every plug-in arms adb's TCP port,
//               which leaves adb listening on the LAN until the phone restarts; switched on with the cable in, it arms at once),
//               "Wireless debugging" (Pair: a QR code for the phone's "Pair device with QR code"; once paired, a plug-in also
//               switches Wireless debugging on, and after a restart its quick tile is all it takes), "Unlock PIN" (Set /
//               Change / Forget: the phone's PIN, kept in the login keyring, typed into its lock screen at every popup open; a
//               masked field takes it, and it goes to the service on Save and is dropped from the field at once), and
//               "Unpair" (asks again: two clicks, the second within 3 s)
//   HINTS       what the tool says each action needs (`can.<x>.why` and `.hint`), the same sentence once, with the actions it
//               stops: "Mirror, Shot: adb is not connected -- Plug the phone in ..."
//
// It was the phone's BACK face until the user's review of round 2 ("the flip is purely a fidget, nothing functional"): the
// back is the phone's own back now, and this sits behind "Details" in the device menu.
//
// The sheet decides nothing: `service` and `dev` are the facts, the switch is enabled by `can.arm.ok`. Its height is its
// rows' (`implicitHeight`).
// =============================================================================
Item {
    id: sheet

    property var service: null
    // the current device's record (BridgeModel's <device>); the page hands the screen's
    property var dev: null
    property string fontFamily: "Inter"
    property BridgeStyle style: BridgeStyle {}
    property Item overlayItem: null
    // the ground the controls stand on (the display's)
    property color ground: Theme.listBox

    // ---- the inks: the theme's, by role (no colour is animated: a fraction is, where one moves) ----------------------------
    readonly property color inkPrimary: Theme.textPrimary
    readonly property color inkMuted: Theme.textMuted
    readonly property color inkRule: Theme.border
    readonly property color inkDanger: Theme.error

    implicitHeight: col.implicitHeight
    // the PIN field is open: the popup asks for the keys while it is (BridgePopup keyboardFocusRequest)
    readonly property bool editing: pinRow.editing
    // Escape: a field that is open closes first; true when it did
    function cancelEdit(): bool {
        if (!pinRow.editing)
            return false;
        pinRow.close();
        return true;
    }

    readonly property var _facts: sheet.dev ? sheet.dev.facts : null
    readonly property var _can: sheet.dev ? sheet.dev.can : null
    readonly property string _key: sheet.dev ? sheet.dev.key : ""

    function _bytes(n: real): string {
        return Model.bytesWords(n);
    }
    // "311 of 512 GiB": the free figure and the total, the unit said once when it is the same
    readonly property string _storage: {
        const f = sheet._facts;
        if (!f || f.storageTotal <= 0)
            return "";
        const free = sheet._bytes(f.storageFree), total = sheet._bytes(f.storageTotal);
        const fu = free.split(" ")[1], tu = total.split(" ")[1];
        return (fu === tu ? free.split(" ")[0] : free) + " of " + total;
    }
    // "Good  31.5 °C" from whatever of the two the facts carry
    readonly property string _health: {
        const f = sheet._facts;
        if (!f)
            return "";
        const parts = [];
        if (f.batteryHealth !== "" && f.batteryHealth !== null)
            parts.push(String(f.batteryHealth));
        if (f.batteryTempC !== null && f.batteryTempC !== undefined)
            parts.push(f.batteryTempC.toFixed(1) + " °C");
        return parts.join("  ·  ");
    }
    readonly property string _charge: {
        const b = sheet.dev ? sheet.dev.battery : null;
        return b ? b.charge + "%" + (b.charging ? "  ·  charging" : "") : "";
    }

    // what each action is called in a hint
    readonly property var _names: ({ mirror: "Mirror", mountUsb: "Cable files", mountWifi: "Wi-Fi files", send: "Send", shot: "Shot",
        ring: "Ring", clip: "Clipboard", key: "Keys", arm: "Keep wireless ready", facts: "Details", usbcalm: "File transfer" })
    // The reasons the tool gave, once each: [{ names, text }]. An action with no hint has nothing to do about it, so it has none.
    readonly property var _hints: {
        const out = [];
        const can = sheet._can;
        if (!can)
            return out;
        const at = {};
        for (const ak in sheet._names) {
            const c = can[ak];
            if (!c || c.ok || c.hint === "")
                continue;
            const text = (c.why !== "" ? String(c.why).replace(/[.\s]+$/, "") + " — " : "") + c.hint;
            if (at[text] === undefined) {
                at[text] = out.length;
                out.push({ names: [sheet._names[ak]], text: text });
            } else {
                out[at[text]].names.push(sheet._names[ak]);
            }
        }
        return out;
    }

    PrefWish {
        id: wish
        service: sheet.service
        deviceKey: sheet._key
        prefs: sheet.dev ? sheet.dev.prefs : null
    }

    Column {
        id: col
        width: sheet.width
        spacing: sheet.style.backRowGap

        // the model: the sheet's heading
        Text {
            width: col.width
            elide: Text.ElideRight
            visible: sheet.dev !== null
            text: sheet._facts && sheet._facts.model !== "" ? sheet._facts.model : (sheet.dev ? sheet.dev.name : "")
            color: sheet.inkPrimary
            font.family: sheet.fontFamily
            font.pixelSize: sheet.style.backFigureSize + 2
            font.bold: true
        }
        Rectangle {
            width: col.width
            height: 1
            color: sheet.inkRule
        }
        SheetRow {
            label: "Android"
            value: sheet._facts ? sheet._facts.android : ""
            shown: sheet._facts !== null && sheet._facts.android !== ""
            fontFamily: sheet.fontFamily
            style: sheet.style
            labelInk: sheet.inkMuted
            valueInk: sheet.inkPrimary
        }
        SheetRow {
            label: "Free"
            value: sheet._storage
            shown: sheet._facts !== null && sheet._facts.storageTotal > 0
            gauge: sheet._facts && sheet._facts.storageTotal > 0 ? sheet._facts.storageFree / sheet._facts.storageTotal : -1
            fontFamily: sheet.fontFamily
            style: sheet.style
            labelInk: sheet.inkMuted
            valueInk: sheet.inkPrimary
            gaugeInk: sheet.inkRule
            gaugeFill: sheet.inkMuted
        }
        SheetRow {
            label: "Battery"
            value: sheet._charge
            shown: sheet._charge !== ""
            fontFamily: sheet.fontFamily
            style: sheet.style
            labelInk: sheet.inkMuted
            valueInk: sheet.inkPrimary
        }
        SheetRow {
            label: "Health"
            value: sheet._health
            shown: sheet._health !== ""
            fontFamily: sheet.fontFamily
            style: sheet.style
            labelInk: sheet.inkMuted
            valueInk: sheet.inkPrimary
        }
        SheetRow {
            label: "Link"
            value: sheet.dev ? Model.linkWords(sheet.dev) : ""
            shown: sheet.dev !== null
            fontFamily: sheet.fontFamily
            style: sheet.style
            labelInk: sheet.inkMuted
            valueInk: sheet.inkPrimary
        }
        SheetRow {
            label: "Address"
            value: sheet.dev && sheet.dev.kdc && sheet.dev.kdc.addresses.length > 0 ? sheet.dev.kdc.addresses[0] : ""
            shown: sheet.dev !== null && sheet.dev.kdc !== null && sheet.dev.kdc.addresses.length > 0
            fontFamily: sheet.fontFamily
            style: sheet.style
            labelInk: sheet.inkMuted
            valueInk: sheet.inkPrimary
        }
        SheetRow {
            label: "Key"
            value: sheet.dev && sheet.dev.kdc ? sheet.dev.kdc.verificationKey : ""
            shown: sheet.dev !== null && sheet.dev.kdc !== null && sheet.dev.kdc.verificationKey !== ""
            fontFamily: sheet.fontFamily
            style: sheet.style
            labelInk: sheet.inkMuted
            valueInk: sheet.inkPrimary
        }
        Rectangle {
            width: col.width
            height: 1
            color: sheet.inkRule
            visible: sheet.dev !== null
        }

        // ---- the controls ------------------------------------------------------------------------------------------
        Item {
            id: keep
            width: col.width
            height: sheet.dev ? 26 : 0
            visible: sheet.dev !== null
            readonly property var can: sheet._can ? sheet._can.arm : ({ ok: false, why: "", hint: "" })
            readonly property bool on: wish.value("keepWireless") === true
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Keep wireless ready"
                color: sheet.inkMuted
                font.family: sheet.fontFamily
                font.pixelSize: sheet.style.backLabelSize
                font.capitalization: Font.AllUppercase
                font.letterSpacing: 0.6
            }
            GrooveToggle {
                id: toggle
                x: keep.width - width
                anchors.verticalCenter: parent.verticalCenter
                checked: keep.on
                surfaceColor: sheet.ground
                // a wish, any time: it acts at the next plug-in, and at once when the cable is in now
                onToggled: c => {
                    wish.set("keepWireless", c);
                    if (c && keep.can.ok && sheet.service)
                        sheet.service.arm(sheet._key);
                }
            }
            MouseArea {
                id: keepArea
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
                cursorShape: undefined   // a hover area for the tip: the cursor is what lies under it (a MouseArea owns an Arrow)
            }
            HoverTip {
                anchorItem: keep
                overlayItem: sheet.overlayItem
                show: keepArea.containsMouse
                side: "left"
                text: "Every plug-in opens adb on Wi-Fi until the phone restarts."
            }
        }
        // ---- Wireless debugging: pair once by QR code ------------------------------------------------------------------
        Item {
            id: wdbg
            width: col.width
            visible: sheet.dev !== null
            readonly property var rec: sheet.service && sheet.service.wifiPair && sheet.service.wifiPair.key === sheet._key ? sheet.service.wifiPair : null
            readonly property bool waiting: wdbg.rec !== null && wdbg.rec.state === "waiting"
            readonly property bool paired: sheet.dev !== null && sheet.dev.prefs.wifiDebug === true
            readonly property string note: wdbg.rec === null ? "" : (wdbg.rec.state === "paired" ? "Paired" : (wdbg.rec.state === "waiting" ? "" : (wdbg.rec.reason !== "" ? wdbg.rec.reason : "Did not pair")))
            readonly property real qrSide: Math.min(col.width, 168)
            height: !sheet.dev ? 0 : 26 + (wdbg.waiting ? wdbg.qrSide + 8 + qrNote.height + 4 : 0)
            Text {
                y: 13 - height / 2
                text: "Wireless debugging"
                color: sheet.inkMuted
                font.family: sheet.fontFamily
                font.pixelSize: sheet.style.backLabelSize
                font.capitalization: Font.AllUppercase
                font.letterSpacing: 0.6
            }
            Row {
                anchors.right: parent.right
                y: 13 - height / 2
                spacing: 10
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: text !== ""
                    text: wdbg.note !== "" ? wdbg.note : (wdbg.paired && !wdbg.waiting ? "Paired" : "")
                    color: wdbg.rec !== null && (wdbg.rec.state === "failed" || wdbg.rec.state === "expired") ? sheet.inkDanger : sheet.inkMuted
                    font.family: sheet.fontFamily
                    font.pixelSize: sheet.style.backLabelSize + 1
                }
                QuietButton {
                    anchors.verticalCenter: parent.verticalCenter
                    text: wdbg.waiting ? "Cancel" : (wdbg.paired ? "Pair again" : "Pair")
                    fontFamily: sheet.fontFamily
                    fontPixelSize: sheet.style.backFigureSize
                    inkColor: sheet.inkMuted
                    hoverColor: sheet.inkPrimary
                    faintColor: sheet.inkRule
                    overlayItem: sheet.overlayItem
                    tip: wdbg.waiting ? "" : "Pair once; after a phone restart, its Wireless debugging tile is all it takes"
                    onClicked: {
                        if (!sheet.service)
                            return;
                        if (wdbg.waiting)
                            sheet.service.wifiPairCancel();
                        else
                            sheet.service.wifiPair(sheet._key);
                    }
                }
            }
            // the code, black on white (what a scanner wants), while the phone has not come yet
            Rectangle {
                id: qrCard
                visible: wdbg.waiting
                x: Math.round((col.width - wdbg.qrSide) / 2)
                y: 26 + 4
                width: wdbg.qrSide
                height: wdbg.qrSide
                radius: 6
                color: "#FFFFFF"
                Image {
                    anchors.fill: parent
                    anchors.margins: 4
                    fillMode: Image.PreserveAspectFit
                    smooth: false
                    cache: false
                    source: wdbg.waiting && wdbg.rec.png !== "" ? "file://" + wdbg.rec.png + "?" + wdbg.rec.name : ""
                }
            }
            Text {
                id: qrNote
                visible: wdbg.waiting
                y: qrCard.y + qrCard.height + 6
                width: col.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: "Scan it: Wireless debugging › Pair device with QR code"
                color: sheet.inkMuted
                font.family: sheet.fontFamily
                font.pixelSize: sheet.style.backLabelSize + 1
            }
        }
        // ---- the unlock PIN: kept in the keyring, typed into the lock screen at the popup's open ------------------------------
        Item {
            id: pinRow
            width: col.width
            visible: sheet.dev !== null
            property bool editing: false
            readonly property string pinState: sheet.dev ? sheet.dev.pin : "none"
            readonly property var act: sheet.service && sheet.service.acts && sheet.service.acts.unlock ? sheet.service.acts.unlock : ({ state: "idle", why: "" })
            // what the row says beside its buttons: the last try's failure, or what is kept
            readonly property string note: pinRow.act.state === "failed" && pinRow.act.why !== "" ? pinRow.act.why
                : (pinRow.act.state === "busy" ? "Unlocking" : (pinRow.pinState === "failed" ? "Failed" : (pinRow.pinState === "set" ? "Kept" : "")))
            readonly property bool bad: (pinRow.act.state === "failed" && pinRow.act.why !== "") || pinRow.pinState === "failed"
            readonly property bool fits: /^[0-9A-Za-z]{4,16}$/.test(field.text)
            height: !sheet.dev ? 0 : 26 + (pinRow.editing ? 8 + 30 : 0)
            function open(): void {
                field.text = "";
                pinRow.editing = true;
                field.forceActiveFocus();
            }
            function close(): void {
                field.text = "";
                pinRow.editing = false;
            }
            function save(): void {
                if (!pinRow.fits || !sheet.service)
                    return;
                const pin = field.text;
                field.text = "";
                pinRow.editing = false;
                sheet.service.setPin(sheet._key, pin);
            }
            Text {
                id: pinLabel
                y: 13 - height / 2
                text: "Unlock PIN"
                color: sheet.inkMuted
                font.family: sheet.fontFamily
                font.pixelSize: sheet.style.backLabelSize
                font.capitalization: Font.AllUppercase
                font.letterSpacing: 0.6
            }
            MouseArea {
                id: pinArea
                width: pinLabel.width
                height: 26
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
                cursorShape: undefined   // a hover area for the tip: the cursor is what lies under it (a MouseArea owns an Arrow)
            }
            HoverTip {
                anchorItem: pinLabel
                overlayItem: sheet.overlayItem
                show: pinArea.containsMouse
                side: "left"
                text: "Typed into the phone's lock screen when this popup opens. Kept in your login keyring."
            }
            Row {
                anchors.right: parent.right
                y: 13 - height / 2
                spacing: 10
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: text !== "" && !pinRow.editing
                    width: Math.min(implicitWidth, col.width - pinLabel.width - 110)
                    elide: Text.ElideRight
                    text: pinRow.note
                    color: pinRow.bad ? sheet.inkDanger : sheet.inkMuted
                    font.family: sheet.fontFamily
                    font.pixelSize: sheet.style.backLabelSize + 1
                }
                QuietButton {
                    anchors.verticalCenter: parent.verticalCenter
                    text: pinRow.editing ? "Cancel" : (pinRow.pinState === "none" ? "Set" : "Change")
                    fontFamily: sheet.fontFamily
                    fontPixelSize: sheet.style.backFigureSize
                    inkColor: sheet.inkMuted
                    hoverColor: sheet.inkPrimary
                    faintColor: sheet.inkRule
                    overlayItem: sheet.overlayItem
                    onClicked: pinRow.editing ? pinRow.close() : pinRow.open()
                }
                QuietButton {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !pinRow.editing && pinRow.pinState !== "none"
                    text: "Forget"
                    fontFamily: sheet.fontFamily
                    fontPixelSize: sheet.style.backFigureSize
                    inkColor: sheet.inkMuted
                    hoverColor: sheet.inkPrimary
                    faintColor: sheet.inkRule
                    overlayItem: sheet.overlayItem
                    onClicked: {
                        if (sheet.service)
                            sheet.service.forgetPin(sheet._key);
                    }
                }
            }
            // the field: carved, masked, digits and letters only; Return saves, the popup's Escape closes it
            ShadowBox {
                id: pinField
                visible: pinRow.editing
                y: 26 + 8
                width: col.width - saveBtn.width - 10
                height: 30
                baseWidth: width
                baseHeight: height
                baseRadius: sheet.style.boxRadius
                surfaceColor: sheet.ground
                backgroundColor: Theme.panelSunk
                bevelColor: Theme.bevel
                shadowColor: Theme.border
                bevelWidth: 1
                shadowWidth: 3
                TextInput {
                    id: field
                    x: 10
                    width: pinField.width - 20
                    anchors.verticalCenter: parent.verticalCenter
                    echoMode: TextInput.Password
                    passwordCharacter: "\u2022"
                    maximumLength: 16
                    validator: RegularExpressionValidator {
                        regularExpression: /[0-9A-Za-z]{0,16}/
                    }
                    // a secret: no prediction, no dictation (the dictation's secret-field rule reads these hints)
                    inputMethodHints: Qt.ImhHiddenText | Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
                    color: sheet.inkPrimary
                    selectionColor: Theme.accent
                    font.family: sheet.fontFamily
                    font.pixelSize: sheet.style.backFigureSize + 1
                    font.letterSpacing: 2
                    clip: true
                    onAccepted: pinRow.save()
                }
                Text {
                    x: field.x
                    anchors.verticalCenter: parent.verticalCenter
                    visible: field.text === ""
                    text: "4 to 16 digits or letters"
                    color: Theme.textFaint
                    font.family: sheet.fontFamily
                    font.pixelSize: sheet.style.backFigureSize
                }
            }
            QuietButton {
                id: saveBtn
                visible: pinRow.editing
                x: col.width - width
                y: pinField.y + (pinField.height - height) / 2
                text: "Save"
                fontFamily: sheet.fontFamily
                fontPixelSize: sheet.style.backFigureSize
                available: pinRow.fits
                inkColor: sheet.inkMuted
                hoverColor: Theme.accent
                faintColor: sheet.inkRule
                overlayItem: sheet.overlayItem
                onClicked: pinRow.save()
            }
        }
        // ---- the phone's USB at an unlock: Android's "File transfer" default switches it at every lock and unlock, which drops every
        // adb connection for a moment (a cast ends). The bridge turns it off itself at the popup's open; this is the way back
        Item {
            id: usbRow
            width: col.width
            // facts say what the phone does now ("" = not read yet)
            readonly property string mode: sheet._facts ? sheet._facts.usbUnlocked : ""
            readonly property bool on: usbRow.mode !== "" && usbRow.mode !== "none"
            readonly property var act: sheet.service && sheet.service.acts && sheet.service.acts.usbcalm ? sheet.service.acts.usbcalm : ({ state: "idle", why: "" })
            readonly property bool busy: usbRow.act.state === "busy"
            readonly property bool can: sheet._can !== null && sheet._can.facts !== undefined && sheet._can.facts.ok
            // the condition, never the flag: `visible` is false under a hidden ancestor and the sheet's column would hear a 0 (CLAUDE.md)
            readonly property bool shown: sheet.dev !== null && usbRow.mode !== ""
            visible: usbRow.shown
            height: usbRow.shown ? 26 : 0
            Text {
                id: usbLabel
                y: 13 - height / 2
                text: "File transfer at unlock"
                color: sheet.inkMuted
                font.family: sheet.fontFamily
                font.pixelSize: sheet.style.backLabelSize
                font.capitalization: Font.AllUppercase
                font.letterSpacing: 0.6
            }
            MouseArea {
                id: usbArea
                width: usbLabel.width
                height: 26
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
                cursorShape: undefined   // a hover area for the tip: the cursor is what lies under it (a MouseArea owns an Arrow)
            }
            HoverTip {
                anchorItem: usbLabel
                overlayItem: sheet.overlayItem
                show: usbArea.containsMouse
                side: "left"
                text: "Android switches the phone's USB at every lock and unlock, which drops every connection to it for a moment and ends a cast. The bridge turns that off; On gives the phone its File transfer back."
            }
            Row {
                anchors.right: parent.right
                y: 13 - height / 2
                spacing: 10
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: usbRow.busy ? "Changing" : (usbRow.act.state === "failed" && usbRow.act.why !== "" ? usbRow.act.why : (usbRow.on ? "On" : "Off"))
                    width: Math.min(implicitWidth, col.width - usbLabel.width - 110)
                    elide: Text.ElideRight
                    color: usbRow.act.state === "failed" ? sheet.inkDanger : sheet.inkMuted
                    font.family: sheet.fontFamily
                    font.pixelSize: sheet.style.backLabelSize + 1
                }
                QuietButton {
                    anchors.verticalCenter: parent.verticalCenter
                    text: usbRow.on ? "Turn off" : "Turn on"
                    fontFamily: sheet.fontFamily
                    fontPixelSize: sheet.style.backFigureSize
                    inkColor: sheet.inkMuted
                    hoverColor: sheet.inkPrimary
                    faintColor: sheet.inkRule
                    available: usbRow.can && !usbRow.busy
                    overlayItem: sheet.overlayItem
                    tip: usbRow.can ? "" : (sheet._can && sheet._can.facts ? sheet._can.facts.why : "")
                    onClicked: {
                        if (sheet.service)
                            sheet.service.usbCalm(sheet._key, !usbRow.on);
                    }
                }
            }
        }
        QuietButton {
            id: unpair
            width: col.width
            visible: sheet.dev !== null && sheet.dev.kdc !== null && sheet.dev.kdc.paired
            height: visible ? implicitHeight : 0
            property bool armed: false
            text: unpair.armed ? "Click again to unpair" : "Unpair"
            fontFamily: sheet.fontFamily
            fontPixelSize: sheet.style.backFigureSize
            inkColor: unpair.armed ? sheet.inkDanger : sheet.inkMuted
            hoverColor: unpair.armed ? sheet.inkDanger : sheet.inkPrimary
            faintColor: sheet.inkRule
            available: sheet._can !== null && sheet._can.unpair.ok
            overlayItem: sheet.overlayItem
            tip: unpair.available ? "" : (sheet._can ? sheet._can.unpair.why : "")
            onClicked: {
                if (!unpair.armed) {
                    unpair.armed = true;
                    disarm.restart();
                } else {
                    unpair.armed = false;
                    disarm.stop();
                    if (sheet.service)
                        sheet.service.unpair(sheet._key);
                }
            }
            Timer {
                id: disarm
                interval: 3000
                onTriggered: unpair.armed = false
            }
        }

        // ---- what the tool says is missing ------------------------------------------------------------------------------
        Repeater {
            model: Math.min(sheet._hints.length, sheet.style.backHintGroups)
            Text {
                id: hint
                required property int index
                readonly property var rec: sheet._hints[hint.index]
                width: col.width
                wrapMode: Text.WordWrap
                maximumLineCount: sheet.style.backHintLines
                elide: Text.ElideRight
                text: hint.rec ? hint.rec.names.join(", ") + ": " + hint.rec.text : ""
                color: sheet.inkMuted
                font.family: sheet.fontFamily
                font.pixelSize: sheet.style.backLabelSize + 1
            }
        }
    }
    // a device that goes away takes an armed Unpair and an open PIN field with it
    onDevChanged: {
        unpair.armed = false;
        pinRow.close();
    }
}
