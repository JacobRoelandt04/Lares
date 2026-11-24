pragma ComponentBehavior: Bound

import QtQuick

import ".."
import "../../common/theme"
import "../../common/components"
import "../data/BridgeModel.js" as Model
import "../../common/components/Mix.js" as Mix

// =============================================================================
// FilesRow.qml -- one way of reaching the phone's storage, a carved row of the Files page: the CABLE (USB, `aft-mtp-mount`)
// or Wi-Fi (KDE Connect's sftp).
//
//   which        "usb" | "wifi": which of the device's `mounts` and which `can` it reads (mountUsb / mountWifi)
//   state words  "Not mounted" / "Mounting" / "Mounted at <point>" / "Stale: left by an unplug"
//   the point    a link while mounted: a click copies it (`service.copyText`; the hand and the colour fade are the only
//                announcement, then the point reads "Copied" for a moment)
//   ONE action   whose label is what will happen now: "Mount" / "Open" (and a second, quiet "Unmount") / "Clean up" for a
//                stale endpoint. When the tool says the device cannot mount, its `why` and `hint` stand where the button would.
//   a failure    (a mount or an unmount that did not go) takes the state line's place, in the error colour, and takes NO
//                button away: a press tries again (the user's review 2026-11-19: a busy unmount left the row with nothing)
//
// The action's room is reserved (the tallest of a button and a three-line reason), so the row never changes height.
// =============================================================================
Item {
    id: row

    property string which: "usb"
    property string title: ""
    property var service: null
    property var dev: null
    property string fontFamily: "Inter"
    property BridgeStyle style: BridgeStyle {}
    property Item overlayItem: null
    property color ground: Theme.listBox

    implicitHeight: row.style.fileRowHeight

    readonly property string _ak: row.which === "usb" ? "mountUsb" : "mountWifi"
    readonly property var _mount: row.dev ? row.dev.mounts[row.which] : { point: "", state: "unmounted", mine: false }
    readonly property var _can: Model.canOf(row.dev, row._ak)
    readonly property var _act: row.service && row.service.acts && row.service.acts[row._ak] ? row.service.acts[row._ak] : ({ state: "idle", why: "", hint: "" })
    readonly property string _state: row._mount.state
    readonly property string _key: row.dev ? row.dev.key : ""

    function _words(why: string, hint: string): string {
        const w = String(why || "").replace(/[.\s]+$/, "");
        const h = String(hint || "");
        return w !== "" && h !== "" ? w + ". " + h : (w !== "" ? w : h);
    }
    // what stands in the action's place when there is nothing to press
    readonly property string _reason: row._state === "unmounted" && !row._can.ok ? row._words(row._can.why, row._can.hint) : ""
    // why the last try failed (this session's answer, else the tool's memory of it): in the state line, never instead of a button
    readonly property string _failure: row._act.state === "failed" ? row._words(row._act.why, row._act.hint)
                                                                   : (row._can.ok ? row._words(row._can.why, row._can.hint) : "")
    readonly property bool _busy: row._act.state === "busy" || row._state === "mounting"

    property bool _copied: false
    Timer {
        id: copiedHold
        interval: 1200
        onTriggered: row._copied = false
    }

    ShadowBox {
        anchors.fill: parent
        baseWidth: row.width
        baseHeight: row.height
        baseRadius: row.style.boxRadius
        surfaceColor: row.ground
        backgroundColor: Theme.panelSunk
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        bevelWidth: 1
        shadowWidth: 3
    }

    Text {
        id: titleText
        x: row.style.boxPadding
        y: row.style.boxPadding
        text: row.title
        color: Theme.textPrimary
        font.family: row.fontFamily
        font.pixelSize: row.style.bodySize
        font.bold: true
    }
    // the state in words; "Mounted at" is followed by the point, which is the link
    Row {
        id: stateLine
        x: row.style.boxPadding
        y: titleText.y + titleText.height + 3
        width: row.width - 2 * row.style.boxPadding
        height: Math.ceil(stateText.implicitHeight)
        Text {
            id: stateText
            width: row._failure !== "" ? stateLine.width : implicitWidth
            elide: Text.ElideRight
            text: row._failure !== "" ? row._failure : (row._state === "mounted" ? "Mounted at " : (row._state === "mounting" ? "Mounting" : (row._state === "stale" ? "Left behind by an unplug" : "Not mounted")))
            color: row._failure !== "" ? Theme.error : Theme.textMuted
            font.family: row.fontFamily
            font.pixelSize: row.style.noteSize
        }
        Item {
            id: pointLink
            visible: row._state === "mounted" && row._failure === ""
            width: Math.min(Math.ceil(pointText.implicitWidth), stateLine.width - stateText.width)
            height: stateText.height
            property real hoverF: pointArea.containsMouse ? 1 : 0
            Behavior on hoverF {
                NumberAnimation {
                    duration: row.style.hoverMs
                    easing.type: Easing.OutCubic
                }
            }
            Text {
                id: pointText
                width: parent.width
                elide: Text.ElideMiddle
                text: row._copied ? "Copied" : (row._mount.open || row._mount.point)
                color: Mix.c(Theme.textMuted, Theme.accent, pointLink.hoverF)
                font.family: row.fontFamily
                font.pixelSize: row.style.noteSize
                font.underline: pointLink.hoverF > 0.5
            }
            MouseArea {
                id: pointArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (row.service)
                        row.service.copyText(row._mount.open || row._mount.point);
                    row._copied = true;
                    copiedHold.restart();
                }
            }
        }
    }

    // ---- the action's room -----------------------------------------------------------------------------------
    Item {
        id: actionRoom
        x: row.style.boxPadding
        y: row.height - row.style.boxPadding - height
        width: row.width - 2 * row.style.boxPadding
        height: row.style.fileActionHeight

        Row {
            spacing: row.style.buttonGap
            visible: row._reason === ""
            ScreenButton {
                id: act
                height: row.style.smallButtonHeight
                implicitHeight: row.style.smallButtonHeight
                fontFamily: row.fontFamily
                fontPixelSize: row.style.noteSize + 1
                surfaceColor: Theme.panelSunk
                accent: row._state === "mounted" || row._state === "unmounted"
                text: row._state === "mounted" ? "Open" : (row._state === "stale" ? "Clean up" : (row._state === "mounting" ? "Mounting" : "Mount"))
                enabled: !row._busy && (row._state !== "unmounted" || row._can.ok)
                onClicked: {
                    if (!row.service)
                        return;
                    if (row._state === "mounted")
                        row.service.openFiles(row._key, row.which);
                    else if (row._state === "stale")
                        row.service.unmount(row._key, row.which);
                    else
                        row.service.mount(row._key, row.which);
                }
            }
            QuietButton {
                visible: row._state === "mounted"
                anchors.verticalCenter: parent.verticalCenter
                text: "Unmount"
                fontFamily: row.fontFamily
                fontPixelSize: row.style.noteSize + 1
                available: !row._busy
                onClicked: {
                    if (row.service)
                        row.service.unmount(row._key, row.which);
                }
            }
        }
        Text {
            visible: row._reason !== ""
            width: parent.width
            height: parent.height
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideRight
            text: row._reason
            color: Theme.textMuted
            font.family: row.fontFamily
            font.pixelSize: row.style.noteSize
        }
    }
}
