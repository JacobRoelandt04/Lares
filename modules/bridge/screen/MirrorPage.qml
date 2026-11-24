pragma ComponentBehavior: Bound

import QtQuick

import ".."
import "../../common/theme"
import "../../common/components"
import "../data/BridgeModel.js" as Model

// =============================================================================
// MirrorPage.qml -- the Mirror page, the page that grows out of the Mirror tile: how the phone's screen is shown on this
// computer, and the one button that starts or stops it.
//
//   MODE       Mirror / Desktop / Camera / Audio: a TabSelector of four icons, each named by its tip
//   TOGGLES    "Screen off" (the phone's own screen while it is mirrored) and "Record" (to the config's folder)
//   TRANSPORT  one line: "Over USB" / "Over Wi-Fi" when it can; the tool's `why` and `hint` when it cannot; while a mirror
//              runs, its phase ("Starting", "Running over USB")
//   BUTTON     "Start" (the default answer) or, while a mirror of this device runs, "Stop"
//
// The mode and the toggles are the device's `prefs`, written through `service.setPref` and read back from `dev.prefs`
// (PrefWish: a write that did not take shows the old value again). The page decides nothing about availability: Start is
// enabled by `can.mirror.ok` and the line says why when it is not.
//
// The page chrome (back chevron and title) belongs to the page. Laid out once at the size it asks for.
// =============================================================================
Item {
    id: page

    property var service: null
    property var dev: null
    property string fontFamily: "Inter"
    property BridgeStyle style: BridgeStyle {}
    property Item overlayItem: null
    property color ground: Theme.listBox

    signal back
    // Mirror and Desktop run on the phone's own screen in the popup: the face starts the cast (in this mode, recording when Record
    // is on) and opens its page
    signal castRequested(string mode, bool record)

    readonly property string _key: page.dev ? page.dev.key : ""
    readonly property var _can: Model.canOf(page.dev, "mirror")
    readonly property var _job: page.service && page.dev ? page.service.job(page.dev.key, "mirror") : null
    readonly property var _act: page.service && page.service.acts && page.service.acts.mirror ? page.service.acts.mirror : ({ state: "idle" })
    readonly property real _innerW: page.width - 2 * page.style.padding
    readonly property bool _casting: page.service !== null && page.service.casting && page.service.castKey === page._key
    // Mirror and Desktop run in the popup, Record or not (lares-cast writes the file: the same unlock and hold as without it); Camera
    // and Audio are scrcpy's own (its window records them)
    readonly property bool _castMode: page._mode === "mirror" || page._mode === "desktop"
    readonly property bool _record: wish.value("record") === true
    readonly property string _mode: String(wish.value("mode") || "mirror")

    readonly property var _modes: [
        { id: "mirror", label: "Mirror", icon: "\u{F011C}", tip: "Mirror: the phone's screen, here on the phone" },
        { id: "desktop", label: "Desktop", icon: "\u{F0379}", tip: "Desktop: a second screen of the phone's, here on the phone" },
        { id: "camera", label: "Camera", icon: "\u{F0100}", tip: "Camera: the phone's camera, in a window" },
        { id: "audio", label: "Audio", icon: "\u{F057E}", tip: "Audio: the phone's sound, no picture" }
    ]

    function _via(via: string): string {
        return via === "usb" || via === "mtp" ? "USB" : (via === "tcp" ? "Wi-Fi" : "");
    }
    // the line under the toggles
    readonly property string _transport: {
        if (page._job !== null) {
            if (page._job.phase === "starting")
                return "Starting";
            const v = page._via(page._job.via);
            return v !== "" ? "Running over " + v : "Running";
        }
        if (page._act.state === "failed")
            return page._words(page._act.why, page._act.hint);
        if (page._can.ok && page._can.why === "") {
            const w = page._via(page._can.via);
            return w !== "" ? "Over " + w : "";
        }
        return page._words(page._can.why, page._can.hint);
    }
    function _words(why: string, hint: string): string {
        const w = String(why || "").replace(/[.\s]+$/, "");
        const h = String(hint || "");
        return w !== "" && h !== "" ? w + ". " + h : (w !== "" ? w : h);
    }

    PrefWish {
        id: wish
        service: page.service
        deviceKey: page._key
        prefs: page.dev ? page.dev.prefs : null
    }

    PageHeader {
        id: header
        x: page.style.padding
        y: 0
        width: page._innerW
        title: "Mirror"
        fontFamily: page.fontFamily
        style: page.style
        onBack: page.back()
    }

    // ---- the mode ---------------------------------------------------------------------------------------------------
    TabSelector {
        id: modes
        x: page.style.padding
        y: header.y + header.height + page.style.pageGap
        width: page._innerW
        height: page.style.modeHeight
        tabs: page._modes
        fontFamily: page.fontFamily
        iconFontFamily: "Symbols Nerd Font"
        iconSize: page.style.modeIconSize
        slotPaddingAlong: 6
        slotPaddingAcross: 4
        labelsVisible: false
        swipeEnabled: false
        overlayItem: page.overlayItem
        trackSurfaceColor: page.ground
        trackRadiusOverride: page.style.boxRadius
        pillRadiusOverride: Math.max(0, page.style.boxRadius - 3)
        // The device's mode is the truth: a click is a wish, shown at once and put back by PrefWish when it did not take.
        onTabChanged: id => {
            if (id !== page._mode)
                wish.set("mode", id);
        }
    }
    Binding {
        target: modes
        property: "currentTab"
        value: page._mode
    }

    // ---- the toggles ------------------------------------------------------------------------------------------------
    ShadowBox {
        id: toggles
        x: page.style.padding
        y: modes.y + modes.height + page.style.pageGap
        width: page._innerW
        height: 2 * page.style.toggleRowHeight
        baseWidth: width
        baseHeight: height
        baseRadius: page.style.boxRadius
        surfaceColor: page.ground
        backgroundColor: Theme.panelSunk
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        bevelWidth: 1
        shadowWidth: 3

        Repeater {
            model: [
                { pref: "screenOff", label: "Screen off", tip: "The phone's own screen goes dark; the mirror stays" },
                { pref: "record", label: "Record", tip: "Saves a video (mirror.recordDir)" }
            ]
            Item {
                id: row
                required property int index
                required property var modelData
                y: row.index * page.style.toggleRowHeight
                width: toggles.width
                height: page.style.toggleRowHeight
                Text {
                    x: page.style.boxPadding
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.modelData.label
                    color: Theme.textPrimary
                    font.family: page.fontFamily
                    font.pixelSize: page.style.bodySize
                }
                GrooveToggle {
                    x: row.width - page.style.boxPadding - width
                    anchors.verticalCenter: parent.verticalCenter
                    surfaceColor: Theme.panelSunk
                    grooveColor: Theme.headerBox
                    checked: wish.value(row.modelData.pref) === true
                    onToggled: c => wish.set(row.modelData.pref, c)
                }
                // the whole row explains itself; the toggle is the control
                MouseArea {
                    id: rowArea
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                    cursorShape: undefined   // a hover area for the tip: the cursor is what lies under it (a MouseArea owns an Arrow)
                }
                HoverTip {
                    anchorItem: row
                    overlayItem: page.overlayItem
                    text: row.modelData.tip
                    show: rowArea.containsMouse
                    side: "below"
                }
            }
        }
        // the hairline between the two rows
        Rectangle {
            x: page.style.boxPadding
            y: page.style.toggleRowHeight
            width: toggles.width - 2 * page.style.boxPadding
            height: 1
            color: Theme.border
        }
    }

    // ---- the transport ----------------------------------------------------------------------------------------------
    Text {
        id: transport
        x: page.style.padding
        y: toggles.y + toggles.height + page.style.pageGap
        width: page._innerW
        height: Math.ceil(page.style.noteLines * (page.style.bodySize + 3))
        wrapMode: Text.WordWrap
        maximumLineCount: page.style.noteLines
        elide: Text.ElideRight
        text: page._transport
        color: page._job !== null || page._can.ok ? Theme.textPrimary : Theme.textMuted
        font.family: page.fontFamily
        font.pixelSize: page.style.bodySize
    }

    // ---- the button -------------------------------------------------------------------------------------------------
    ScreenButton {
        id: go
        x: page.style.padding
        y: page.height - height - page.style.pageBottomPad
        width: page._innerW
        implicitHeight: page.style.buttonHeight
        height: page.style.buttonHeight
        fontFamily: page.fontFamily
        fontPixelSize: page.style.bodySize + 1
        surfaceColor: page.ground
        accent: page._job === null
        // the cast that runs in this mode and with this Record is shown; another one is started over it
        text: page._job !== null ? "Stop" : (page._castMode && page._casting && page.service.castMode === page._mode && page.service.castRecording === page._record ? "Show" : "Start")
        enabled: page._job !== null || page._casting || (page._can.ok && page._act.state !== "busy")
        onClicked: {
            if (!page.service)
                return;
            if (page._job !== null)
                page.service.stopJob(page._job.id);
            else if (page._castMode)
                page.castRequested(page._mode, page._record);
            else
                page.service.mirror(page._key, { mode: page._mode, screenOff: wish.value("screenOff") === true, record: page._record });
        }
    }
}
