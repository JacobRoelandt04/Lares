pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects

import ".."
import "../../common/theme"
import "../../common/components"
import "../cast"
import "../data/BridgeModel.js" as Model

// =============================================================================
// CastPage.qml -- the phone's screen ON the phone's display: the page the Mirror tile grows into while the popup's cast runs
// (BridgeService castStart / the one CastSession; the picture is CastView's). It fills the whole display -- the phone draws
// its own status bar and navigation, so the face's chrome steps aside -- and has NO chrome of its own at rest.
//
//   the picture   CastView: the pointer is a finger, the wheel scrolls, keys type; Left / Down / Right are Back / Home /
//                 Recents (the user's layout: three keys in a row, as Android's buttons stand)
//   the controls  Sound, Window, Stop are the POPUP's, above the phone (BridgePopup): over the picture they hid the phone's
//                 own status bar (the user's review, 2026-11-19)
//   the words     while there is no picture: "Connecting" / "Starting" / "Reconnecting" (the session ended by itself and is
//                 coming back) / "Screen off" (the phone's screen is dark: a click wakes it) / why it failed, with Try again
//   THE HOLD      something is under way (service.castHolding, castHoldWhy: "Resizing" a mirror's restart at the new size,
//                 "Reconnecting", "Unlocking"): the last frame is taken (`freeze`, asked, then the service is told:
//                 castHoldReady), shown blurred under the carved title box of a view change (CardViewCycler `held`, labelled
//                 with the why), and faded off the new stream's first frame (the user's review 2026-11-19: "Starting" was not
//                 what happened). An Unlocking hold ends with the service's own release (the unlock's answer, at the next frame)
//   THE TURN      `shown` (the host: the popup is on the glass) is what the player follows, never the page's own `visible`: that goes
//                 with the face whenever the phone's back is toward the viewer (a free look, the opening turn), and a player let go
//                 there is opened again on the way round, with "Starting" over it until the phone's next key frame. `turning` (the
//                 host: the phone is turning) is told to the service (castTurning): a new size waits for the landing
//   THE INPUT     `inputHeld` (the host: a free look at the page) or an unlock under way (service.castUnlocking): the picture
//                 sends nothing. The first press or key over a dark or locked phone is swallowed, wakes it and asks the unlock
//                 (CastView, "The unlock trigger")
//
// Back to the controls is the face's back (Escape, the two-finger swipe); the cast goes on, and the Mirror tile comes back
// here. The room it is given is reported to the service in DEVICE pixels (castWantRoom), which picks the stream's size and a
// desktop's screen.
// =============================================================================
Item {
    id: page

    property var service: null
    property var dev: null
    property string fontFamily: "Inter"
    property BridgeStyle style: BridgeStyle {}
    property Item overlayItem: null
    property color ground: Theme.listBox
    // the host holds the picture (a free look): nothing goes to the phone
    property bool inputHeld: false
    // the host is on the glass, whichever way the phone in it is turned
    property bool shown: page.visible
    // the phone is turning
    property bool turning: false

    signal back

    readonly property string _phase: page.service ? page.service.castPhase : "idle"
    readonly property bool _live: page._phase === "live" && view.hasPicture
    readonly property var _session: page.service ? page.service.castSession : null
    // a Desktop: its own display, live while the phone is locked or dark (and still when nothing on it moves: no frames)
    readonly property bool _desktop: page.service !== null && page.service.castMode === "desktop"
    readonly property bool _dark: page._phase === "live" && page._session !== null && !page._desktop
        && (page._session.lockKnown ? !page._session.awake : (page._session.flowKnown && !page._session.flowing))

    // the room in device pixels: the window's real ratio (the attached Screen's is an integer at a fractional scale)
    readonly property real _dpr: page.Window.window ? page.Window.window.devicePixelRatio : 1
    function _report(): void {
        if (page.service && page.height > 0)
            page.service.castWantRoom(page.width * page._dpr, page.height * page._dpr, page._dpr);
    }
    onWidthChanged: page._report()
    onHeightChanged: page._report()
    on_DprChanged: page._report()
    function _tellTurning(): void {
        if (page.service)
            page.service.castTurning = page.turning;
    }
    onTurningChanged: page._tellTurning()
    Component.onDestruction: {
        if (page.turning && page.service)
            page.service.castTurning = false;
    }

    // ---- the hold (under the picture, where taking it shows nothing; the blurred copy goes over it) ----------------------
    property bool _holding: false
    property bool _asked: false
    property string _holdWhy: ""
    function _endHold(): void {
        page._holding = false;
        page._asked = false;
        page._holdWhy = "";
    }
    Connections {
        target: page.service
        function onCastHoldWhyChanged(): void {
            const w = page.service.castHoldWhy;
            if (w === "") {
                // an unlock's hold ends with the service's; a resize's and a reconnect's end on the new stream's first frame
                if (page._holding && page._holdWhy === "Unlocking")
                    page._endHold();
                return;
            }
            if (page._holding) {
                page._holdWhy = w;
                return;
            }
            page._holdWhy = w;
            if (!view.hasPicture) {
                // nothing to hold: a restart goes ahead at once, the words say the rest
                page.service.castHoldReady();
                return;
            }
            page._holding = true;
            page._asked = true;
            freeze.scheduleUpdate();
        }
        function onCastPhaseChanged(): void {
            if (page._holding && (page.service.castPhase === "failed" || page.service.castPhase === "idle"))
                page._endHold();
        }
    }
    Connections {
        target: view
        // the new stream's first picture releases a resize's and a reconnect's hold (the service's own is over by then). The last
        // frame may still be asked for: a face turned away is not drawn, so it is never taken there
        function onPictureShown(): void {
            if (page._holding && page._holdWhy !== "Unlocking" && page.service && page.service.castHoldWhy === "" && page.service.castPhase === "live")
                page._endHold();
        }
    }
    ShaderEffectSource {
        id: freeze
        anchors.fill: parent
        visible: page._holding
        sourceItem: view
        live: false
        hideSource: false
        textureSize: Qt.size(Math.ceil(page.width * page._dpr), Math.ceil(page.height * page._dpr))
        // a completion nobody asked for (the first render's) is not the frame
        onScheduledUpdateCompleted: {
            if (!page._asked)
                return;
            page._asked = false;
            if (page.service)
                page.service.castHoldReady();
        }
    }

    // bridge.jsonc `cast` (null: a host with no settings, the defaults)
    readonly property var _cast: page.service && page.service.settings ? page.service.settings.cast : null
    CastView {
        id: view
        anchors.fill: parent
        session: page.service ? page.service.castSession : null
        playing: page.shown
        cover: true
        focus: true
        inputHeld: page.inputHeld || (page.service !== null && page.service.castUnlocking === true)
        // bridge.jsonc cast.unlock: "touch" in it, or a touch of a locked picture goes to the phone's lock screen as it is
        canUnlock: page.service !== null && page.dev !== null && Model.canOf(page.dev, "unlock").ok && (!page._cast || page._cast.unlock.indexOf("touch") >= 0)
        navKeys: page._cast ? page._cast.keys : ({ back: "Left", home: "Down", recents: "Right" })
        lockTrigger: !page._desktop
        // a hold keeps the last picture through the gap of a restart
        keepPicture: page._holding
        onUnlockWanted: {
            if (page.service && page.dev)
                page.service.castUnlock(page.dev.key);
        }
        // the picture woke a dark phone: it goes back to sleep when the cast ends
        onWakeAsked: {
            if (page.service)
                page.service.castWoke();
        }
    }
    // the keys go to the picture from the page's first frame
    Component.onCompleted: {
        view.forceActiveFocus();
        page._report();
        page._tellTurning();
    }

    property real _holdF: page._holding && !page._asked ? 1 : 0
    Behavior on _holdF {
        NumberAnimation {
            duration: page.style.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    MultiEffect {
        anchors.fill: parent
        source: freeze
        visible: page._holdF > 0
        opacity: page._holdF
        autoPaddingEnabled: false
        blurEnabled: true
        blur: 1
        blurMax: 40
    }
    Item {
        id: holdBox
        width: Math.min(page.width - 2 * page.style.padding, 200)
        height: 64
        x: Math.round((page.width - width) / 2)
        y: Math.round((page.height - height) / 2)
        CardViewCycler {
            anchors.fill: parent
            views: [{ id: "hold", label: page._holdWhy }]
            held: page._holding && !page._asked
            radius: page.style.boxRadius
            fontFamily: page.fontFamily
            titleSize: 16
            groundColor: page.ground
        }
    }

    // ---- while there is no picture ----------------------------------------------------------------------------------
    Column {
        anchors.centerIn: parent
        width: page.width - 2 * page.style.padding
        spacing: page.style.pageGap
        visible: !page._live && !page._holding
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: page._phase === "connecting" ? "Connecting" : (page._phase === "reconnecting" ? "Reconnecting" : (page._dark ? "Screen off"
                : (page._phase === "starting" || page._phase === "live" ? "Starting"
                : (page._phase === "failed" ? (page.service ? page.service.castReason : "") : "Stopped"))))
            color: page._phase === "failed" ? Theme.error : Theme.textMuted
            font.family: page.fontFamily
            font.pixelSize: page.style.bodySize
        }
        QuietButton {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: page._phase === "failed" || page._phase === "idle"
            text: page._phase === "failed" ? "Try again" : "Start"
            fontFamily: page.fontFamily
            fontPixelSize: page.style.bodySize
            overlayItem: page.overlayItem
            onClicked: {
                if (page.service && page.dev)
                    page.service.castStart(page.dev.key, page.service.castMode, page.service.castRecording);
            }
        }
    }
}
