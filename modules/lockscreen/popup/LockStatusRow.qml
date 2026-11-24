pragma ComponentBehavior: Bound

import QtQuick

import ".."
import "../../common/theme"

// =============================================================================
// LockStatusRow.qml -- the line under the password field: what the lock has to
// say about the last attempt. (Caps Lock shows in the field's inset.)
//
//   middle  ONE message at a time, plain words: "Wrong password, 3 attempts",
//           then the face's, from its state AND its reason (say WHY
//           when howdy or the lock knows): "Password once after a restart, it opens
//           your keyring" (no face while the keyring is locked), "Face not recognised", "Too dark to
//           see you", "Camera in use or won't open", "Lid closed, no face
//           unlock", "No face enrolled", ... The password's answer outranks the
//           camera's. `busy` (the camera is still held by the last scan) says
//           nothing: the glyph is faint and that is all there is to know
//
// A RESERVED SLOT: the row keeps its height whether or not it has anything to
// say, so a message appearing never moves the field above it.
// A text swap is instant; only presence fades (160 ms) -- and the words are
// held while they fade out so they do not blank first.
// =============================================================================
Item {
    id: root

    property LockState lockState: null
    property string fontFamily: "Audiowide"
    property real rowHeight: 22
    property real textSize: 12
    property int fadeMs: 160

    implicitWidth: 560
    implicitHeight: root.rowHeight

    readonly property string auth: root.lockState ? root.lockState.auth : "idle"
    readonly property int failCount: root.lockState ? root.lockState.failCount : 0
    readonly property string face: root.lockState ? root.lockState.face : "absent"
    readonly property string faceReason: root.lockState ? root.lockState.faceReason : ""

    // The password's answer, else the camera's.
    readonly property string message: {
        if (root.auth === "failed")
            return root.failCount > 1 ? "Wrong password, " + root.failCount + " attempts" : "Wrong password";
        const why = root.faceReason;
        switch (root.face) {
        case "absent":
            // the face is not offered while the login keyring is locked: the password opens it (said while nothing else is)
            return why === "keyring" ? "Password once after a restart, it opens your keyring" : "";
        case "failed":
            // "timeout": howdy `native` says nothing when it fails, so the lock
            // ends the scan at howdy's timeout -- no match, too dark or no
            // face at all are the same silence
            return why === "stall" ? "Face scan took too long"
                 : why === "timeout" ? "Face not recognised in time"
                 : why === "error" ? "Face unlock failed (howdy error)"
                 : "Face not recognised";
        case "dark":
            return "Too dark to see you";
        case "unavailable":
            return why === "camera" ? "Camera in use or won't open"
                 : why === "lid" ? "Lid closed, no face unlock"
                 : why === "nomodel" ? "No face enrolled"
                 : "Camera unavailable";
        case "misconfigured":
            return why === "device" ? "Face unlock: camera not found"
                 : why === "config" ? "Face unlock: howdy's config is unreadable"
                 : why === "nomodel" ? "No face enrolled"
                 : why === "pam" ? "Face unlock: howdy is not set up"
                 : why === "input" ? "Face unlock asked for input; check lares-lock-face"
                 : "Face unlock needs howdy's workaround off or native";
        }
        return "";
    }
    readonly property bool _isError: root.auth === "failed"

    property string _held: ""
    onMessageChanged: {
        if (root.message !== "")
            root._held = root.message;
    }
    Component.onCompleted: root._held = root.message

    property real _msgF: root.message !== "" ? 1 : 0
    Behavior on _msgF {
        NumberAnimation {
            duration: root.fadeMs
            easing.type: Easing.OutCubic
        }
    }

    // The message is centred on the field.
    Text {
        id: msg
        width: Math.min(implicitWidth, root.width)
        x: Math.round((root.width - msg.width) / 2)
        y: Math.round((root.height - implicitHeight) / 2)
        visible: root._msgF > 0
        opacity: root._msgF
        text: root._held
        elide: Text.ElideRight
        color: root._isError ? Theme.error : Theme.textMuted
        font.family: root.fontFamily
        font.pixelSize: root.textSize
    }
}
