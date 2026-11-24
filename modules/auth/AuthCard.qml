pragma ComponentBehavior: Bound

import QtQuick

import "../common/components"
import "../common/theme"
import "../lockscreen"
import "../lockscreen/popup"

// =============================================================================
// AuthCard.qml -- one authentication request, as a card: the rich body of the
// auth toast, and the content of the pill that stands in for it over a
// fullscreen window.
//
//   [title / body]      only with `showHeader` (the pill; in a toast the
//                       notification card's own summary and body say them)
//   user . action id    faint
//   [ carved field ... face ]     the lockscreen's LockField
//   Wrong password, 2 attempts    the lockscreen's LockStatusRow
//                     [ Cancel ] [ Authenticate ]
//
// It draws what AuthBroker's record says (`broker.record(requestId)`) through
// a LockState of its own, so failure speaks the lockscreen's language: the
// field's inset flushes to the error colour, the words stand under it until
// the next key. The password is typed as raw keys into a PasswordBuffer (the
// owner's, so a card that moves between the toast and the pill keeps what was
// typed; its own when none is handed) and leaves it only through
// broker.submit.
//
// THE KEYBOARD. A card that APPEARS under a resting pointer takes nothing; the
// pointer must MOVE onto it (HoverArm). Armed, it asks for
// the keyboard (`keyboardRequest` "exclusive") and takes active focus; the
// first key latches it (`sticky`) so the keys stay here with the pointer gone,
// until Enter, Escape or a click elsewhere. While sticky with the pointer off
// the card, `catchAll` asks the host's input mask to grow over the whole
// output so that click lands on the shell (under an Exclusive keyboard it
// reaches nobody otherwise). Keys that arrive while not armed are not read.
//   Enter      answers (an empty buffer answers nothing) and lets go
//   Escape     clears and lets go, and the next arming needs a new motion
//   Cancel     broker.cancel
// In a toast, both outputs are pushed to `service.setInteraction(token, ..)`
// and withdrawn when the card goes away; the pill's window reads them itself.
//
// DROP-IN. Sized through implicitHeight at the width it is given (implicitWidth
// 340 when it is given none); needs no host id. `armTarget` names what the
// pointer must be over to arm (the card itself; the pill hands its own box).
// `ground` is the fill the card stands on (a toast's card, Theme.listBox; the
// pill's surface): its buttons are raised from it and its field is carved
// into it.
// =============================================================================
Item {
    id: root

    // ---- what it is about ------------------------------------------------------
    property var broker: null
    property string requestId: ""
    // In a toast: the notification service and this card's interaction token.
    property var service: null
    property string token: ""
    // The typed secret, owned by the host; a card with none keeps its own.
    property PasswordBuffer buffer: null

    // ---- look ------------------------------------------------------------------
    property bool showHeader: false
    // Anything with a `sharing` bool (the owner): a screen is shared, so what
    // the request says is not shown. Read live -- a toast's bodyProps are
    // copied onto the card once.
    property var privacy: null
    property Item armTarget: null
    // Set by NotificationCard when the card is a toast's rich body: the whole
    // toast is what the pointer must be over. The pill hands `armTarget` instead.
    property Item hostCard: null
    property color ground: Theme.listBox
    property string fontFamily: "Inter"
    // Sizes: the card's own, or `look`'s while a host hands one (a mockup's
    // panel writes into it and every card follows).
    property var look: null
    property real titleSize: root.look ? root.look.titleSize : 16
    property real bodySize: root.look ? root.look.bodySize : 12
    property real detailSize: root.look ? root.look.detailSize : 10
    property real gap: root.look ? root.look.gap : 8
    property real fieldHeight: root.look ? root.look.fieldHeight : 40
    property real fieldRadius: root.look ? root.look.fieldRadius : 20
    property real dotSize: root.look ? root.look.dotSize : 8
    property real dotGap: root.look ? root.look.dotGap : 5
    property real glyphSize: root.look ? root.look.glyphSize : 24
    property real statusHeight: root.look ? root.look.statusHeight : 20
    property real statusTextSize: root.look ? root.look.statusTextSize : 11
    property real buttonHeight: root.look ? root.look.buttonHeight : 30
    property real buttonGap: root.look ? root.look.buttonGap : 8
    property real buttonRadius: root.look ? root.look.buttonRadius : 7

    // ---- what it asks of its host ----------------------------------------------
    readonly property string keyboardRequest: arm.armed ? "exclusive" : "none"
    readonly property bool catchAll: arm.sticky && !arm.hovered
    readonly property alias lockState: ls
    readonly property var record: root._find(root.broker ? root.broker.requests : null, root.requestId)
    readonly property bool live: root.record !== null && root.record.state !== "ok" && root.record.state !== "cancelled"
    readonly property bool _hide: root.privacy ? !!root.privacy.sharing : false
    // The host's buffer is destroyed with its request, which can be while this
    // card is still leaving: `typed` may read null for that moment.
    readonly property PasswordBuffer typed: root.buffer ? root.buffer : ownBuffer

    implicitWidth: 340
    implicitHeight: Math.ceil(col.implicitHeight)

    // First, so every binding below finds it.
    PasswordBuffer {
        id: ownBuffer
    }

    function _find(list, id) {
        if (!list)
            return null;
        for (let i = 0; i < list.length; i++)
            if (list[i].id === id)
                return list[i];
        return null;
    }

    // Enter and Authenticate: what was typed goes to the broker, once.
    function submit() {
        const rec = root.record;
        if (!root.broker || !rec || !root.typed || root.typed.length === 0)
            return;
        root.broker.submit(rec.id, root.typed.take());
        arm.release(false);
    }
    function cancel() {
        if (root.broker && root.record)
            root.broker.cancel(root.record.id);
        arm.release(false);
    }

    // ---- the keyboard --------------------------------------------------------------
    HoverArm {
        id: arm
        target: root.armTarget ? root.armTarget : (root.hostCard ? root.hostCard : root)
        active: root.visible && root.live
    }

    Item {
        id: sink
        Keys.onPressed: event => {
            if (!arm.armed) {
                event.accepted = false;
                return;
            }
            const ending = event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Escape;
            if (ending && event.isAutoRepeat) {
                event.accepted = true;
                return;
            }
            const used = root.typed ? root.typed.handleKey(event) : false;
            event.accepted = used;
            if (used && !ending)
                arm.latch();
        }
    }
    Connections {
        target: root.typed
        function onEnterPressed(empty) {
            if (empty)
                arm.release(false);
            else
                root.submit();
        }
        function onEscapePressed() {
            arm.release(true);
        }
        function onEdited() {
            // The next key after a failure takes the words away.
            if (root.typed && root.typed.length > 0 && root.record)
                root._failAck = root.record.failCount;
        }
    }
    Connections {
        target: arm
        function onArmedChanged() {
            if (arm.armed)
                sink.forceActiveFocus();
            else if (sink.activeFocus)
                sink.focus = false;
        }
    }

    // ---- the toast's interaction -------------------------------------------------------
    function _push() {
        if (root.service && root.token !== "")
            root.service.setInteraction(root.token, { keyboard: root.keyboardRequest, catchAll: root.catchAll });
    }
    onKeyboardRequestChanged: root._push()
    onCatchAllChanged: root._push()
    onServiceChanged: root._push()
    onTokenChanged: root._push()
    Component.onCompleted: root._push()
    Component.onDestruction: {
        if (root.service && root.token !== "")
            root.service.clearInteraction(root.token);
    }

    // ---- the record, as the lockscreen's facts ---------------------------------------
    property int _failAck: 0
    // howdy `native` says nothing when a face fails: the line drops from
    // scanning (with the prompt already open) to none. That silence is a
    // failed scan, not a skipped one (off: the prompt opens AFTER the scan).
    property bool _scanHadPrompt: false
    readonly property string _rawFace: root.record ? root.record.face : "none"
    on_RawFaceChanged: {
        if (root._rawFace === "scanning")
            root._scanHadPrompt = root.record !== null && root.record.prompt.length > 0;
    }
    readonly property bool _silentFail: root._rawFace === "none" && root._scanHadPrompt
    readonly property bool _failShown: root.record !== null && root.record.state === "failed"
        && root._failAck < root.record.failCount

    LockState {
        id: ls
        dots: root.typed ? root.typed.length : 0
        failCount: root.record ? root.record.failCount : 0
        auth: {
            const r = root.record;
            if (!r)
                return "idle";
            if (r.held || r.state === "checking")
                return "checking";
            if (r.state === "ok")
                return "ok";
            if (r.state === "failed" && root._failShown)
                return "failed";
            return "idle";
        }
        authMessage: root.record ? root.record.message : ""
        face: {
            const r = root.record;
            if (!r)
                return "absent";
            switch (r.face) {
            case "scanning":
                // answered: the scan is over for this session
                return r.state === "checking" && !r.held ? "idle" : "scanning";
            case "ok":
                return "ok";
            case "failed":
                return /too dark/i.test(r.message) ? "dark" : "failed";
            }
            return root._silentFail ? "failed" : "absent";
        }
        faceReason: root._silentFail && ls.face === "failed" ? "timeout" : ""
    }

    // ---- the card ------------------------------------------------------------------------
    Column {
        id: col
        width: root.width
        spacing: root.gap

        Column {
            width: col.width
            spacing: 4
            visible: root.showHeader
            height: root.showHeader ? implicitHeight : 0

            Text {
                width: parent.width
                text: root.record ? root.record.title : ""
                elide: Text.ElideRight
                maximumLineCount: 1
                color: Theme.textPrimary
                font.family: root.fontFamily
                font.pixelSize: root.titleSize
                font.bold: true
            }
            Text {
                width: parent.width
                visible: text !== ""
                text: root.record && !root._hide ? root.record.body : ""
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
                color: Theme.textMuted
                font.family: root.fontFamily
                font.pixelSize: root.bodySize
            }
        }

        Item {
            width: col.width
            visible: detail.text !== ""
            height: detail.text !== "" ? detail.implicitHeight : 0

            Text {
                id: detail
                readonly property string _who: root.record ? root.record.user : ""
                readonly property string _what: root.record && !root._hide ? root.record.detail : ""
                width: parent.width
                text: detail._who !== "" && detail._what !== "" ? detail._who + " \u00B7 " + detail._what : detail._who + detail._what
                elide: Text.ElideRight
                maximumLineCount: 1
                color: Theme.textFaint
                font.family: root.fontFamily
                font.pixelSize: root.detailSize
            }
        }

        LockField {
            id: field
            width: col.width
            lockState: ls
            surfaceColor: root.ground
            fieldHeight: root.fieldHeight
            radius: root.fieldRadius
            dotSize: root.dotSize
            dotGap: root.dotGap
            glyphSize: root.glyphSize
            placeholderGlyph: true
        }

        LockStatusRow {
            id: status
            width: col.width
            lockState: ls
            fontFamily: root.fontFamily
            rowHeight: root.statusHeight
            textSize: root.statusTextSize
        }

        Item {
            width: col.width
            height: root.buttonHeight

            Row {
                anchors.right: parent.right
                spacing: root.buttonGap

                AuthButton {
                    id: cancelBtn
                    text: "Cancel"
                    enabled: root.live
                    onClicked: root.cancel()
                }
                AuthButton {
                    id: authBtn
                    text: "Authenticate"
                    accent: true
                    enabled: root.live && !!root.typed && root.typed.length > 0
                    onClicked: root.submit()
                }
            }
        }
    }

    // A raised button dressed from the theme, standing on the card's ground.
    component AuthButton: RaisedButton {
        width: Math.ceil(implicitWidth)
        implicitHeight: root.buttonHeight
        fontFamily: root.fontFamily
        fontPixelSize: 12
        bold: false
        horizontalPadding: 12
        minWidth: 56
        radius: root.buttonRadius
        shadowWidth: 4
        surfaceColor: root.ground
        plateauColor: Theme.buttonPlateau
        plateauHoverColor: Theme.buttonPlateauHover
        bevelColor: Theme.buttonBevel
        shadowColor: Theme.buttonShadow
        accentColor: Theme.accent
        accentHoverColor: Theme.accentHover
        accentBevelColor: Theme.accentBevel
        shadowToAlpha: true
    }
}
