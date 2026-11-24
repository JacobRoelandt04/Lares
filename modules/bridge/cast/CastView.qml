pragma ComponentBehavior: Bound

import QtQuick
import QtMultimedia
import "../../common/scroll"

// =============================================================================
// CastView.qml -- plays a CastSession's stream and turns the pointer and the keys over it into control messages (docs/contracts/
// bridge.md, "The cast"). It draws the picture and nothing else: the host draws the glass, the bezel, the state.
//
//   session       a CastSession
//   playing       false tears the player down (a hidden popup decodes nothing); true plays whenever the session is live
//   pictureRect   where the picture is drawn (the letterbox is outside it); hasPicture: a first frame has been shown
//   inputHeld     the host holds the picture (a free look, an unlock under way): NOTHING goes to the phone -- no touch, wheel, key or
//                 text -- and a finger already down gets its `up` the moment the hold starts
//   canUnlock     the host can type the phone's PIN (a PIN is kept, adb reaches it): the unlock trigger below
//   unlockWanted  the trigger fired (the host asks the unlock); wakeAsked: the screen was asked on
//   keepPicture   the host holds a picture through a gap (a reconnect): a lost stream does not clear `hasPicture`
//   pictureShown  the first frame of an open arrived (a hold's release)
//
// THE UNLOCK TRIGGER: the first pointer press or key (a modifier alone is none: Alt is the popup's free look) over the picture of a
// phone whose screen is dark (the lock events' `awake`, else the tool's `flow`) or that shows its lock screen is SWALLOWED, the screen
// is woken, and the host is told (`unlockWanted`). A locked
// phone the host cannot unlock gets its input as usual (the user types the PIN by hand); a dark one is only woken.
//
// THE PLAYER HEALS ITSELF. While the phone is sending pictures (the session's `flowing`) and none has reached the screen for
// `stuckMs` -- none since the open, or none since the last one -- or after a player error, the player is opened again: a new
// client of the tool, whose stream starts on a fresh key frame (the user's 2026-11-19: a cast started on a locked phone stood at
// "Starting" for ever once it was unlocked; the cause was not seen, so the cure is the one that holds whatever stuck the player).
// Each reopen says why on the log (`CASTVIEW reopen`); `reopens` counts them.
//
// Keys, while the view has the keyboard (the host gives it, or a click does): `navKeys` (bridge.jsonc cast.keys; Left = back, Down = home,
// Right = recents: the user's choice) are the phone's three; Return / Backspace / Delete / Tab / Escape and the arrows no nav key took are
// their keys, printable text = typed text.
// =============================================================================
Item {
    id: root

    property var session: null
    property bool playing: true
    property bool inputHeld: false
    property bool canUnlock: false
    // false: the picture is not the phone's own screen (a Desktop: Android keeps a new display usable while the phone is locked, and
    // its lock screen and power are display 0's), so a dark or locked phone is no reason to take a click
    property bool lockTrigger: true
    property bool keepPicture: false
    signal unlockWanted
    signal wakeAsked
    signal pictureShown

    readonly property bool hasPicture: root._hasPicture
    // for a probe: the player and the sink its frames land in
    readonly property alias player: player
    readonly property var videoSink: out.videoSink
    readonly property rect pictureRect: root._rect

    readonly property int _vw: root.session ? root.session.videoWidth : 0
    readonly property int _vh: root.session ? root.session.videoHeight : 0
    readonly property bool _wanted: root.playing && root.session !== null && root.session.state === "live" && root.session.url !== ""
    property bool _hasPicture: false
    // no frame yet since the player last opened the stream (a reopen included: it waits for a key frame like a first open)
    property bool _awaiting: false
    property int stuckMs: 3000
    readonly property int reopens: root._reopens
    property int _reopens: 0
    // the player is let go for one turn to open it again
    property bool _off: false
    // the last frame's and the last open's times, kept off the binding graph (a counter that bindings could read would be one)
    property var _clock: ({ frame: 0, open: 0 })
    function reopen(why: string): void {
        if (!root._wanted || root._off)
            return;
        console.log("CASTVIEW reopen (" + why + ")");
        root._reopens++;
        root._off = true;
        reopenTurn.restart();
    }
    Timer {
        id: reopenTurn
        interval: 0
        onTriggered: root._off = false
    }
    // the phone sends, the screen shows nothing new: open again
    Timer {
        interval: 1000
        repeat: true
        running: root._wanted && !root._off && (root.session.flowKnown ? root.session.flowing : true)
        onTriggered: {
            const now = Date.now();
            if (now - root._clock.open > root.stuckMs && now - root._clock.frame > root.stuckMs)
                root.reopen(root._hasPicture ? "the picture stopped" : "no picture");
        }
    }
    Timer {
        id: afterError
        interval: 1000
        onTriggered: root.reopen("player error")
    }
    // cover: the picture fills the view and its overhang is cut (the phone's display and its stream differ by a hair in shape:
    // fitted, that hair was a seam down each side); fit: the whole picture, letterboxed
    property bool cover: false
    readonly property real _scale: root._vw > 0 && root._vh > 0
        ? (root.cover ? Math.max(root.width / root._vw, root.height / root._vh) : Math.min(root.width / root._vw, root.height / root._vh)) : 0
    readonly property rect _rect: root._scale > 0
        ? Qt.rect((root.width - root._vw * root._scale) / 2, (root.height - root._vh * root._scale) / 2, root._vw * root._scale, root._vh * root._scale)
        : Qt.rect(0, 0, 0, 0)

    // The picture goes when the stream does, one turn later: the host that holds it (a reconnect) decides from the same change
    on_WantedChanged: if (!root._wanted) pictureClear.restart()
    onKeepPictureChanged: if (!root.keepPicture && !root._wanted) pictureClear.restart()
    Timer {
        id: pictureClear
        interval: 0
        onTriggered: {
            if (!root._wanted && !root.keepPicture)
                root._hasPicture = false;
        }
    }

    // ---- the unlock trigger ---------------------------------------------------------------------------------------------
    readonly property bool _screenDark: root.session !== null && (root.session.lockKnown ? !root.session.awake : (root.session.flowKnown && !root.session.flowing))
    readonly property bool _screenLocked: root.session !== null && root.session.lockKnown && root.session.keyguard
    // true = this input was taken by the trigger and goes nowhere else
    // bridge.jsonc cast.keys: { back, home, recents }, each a Qt key name ("Left", "F1", "PageUp"); "" = none
    property var navKeys: ({ back: "Left", home: "Down", recents: "Right" })
    function _navOf(k: int): string {
        for (const n of ["back", "home", "recents"]) {
            const w = root.navKeys ? String(root.navKeys[n] || "") : "";
            // qmllint disable missing-property
            if (w !== "" && Qt["Key_" + w] === k)
                return n;
        }
        return "";
    }
    function _trigger(): bool {
        if (root.session === null || root.session.state !== "live" || !root.lockTrigger)
            return false;
        if (!root._screenDark && !(root._screenLocked && root.canUnlock))
            return false;
        root.session.wake();
        root.wakeAsked();
        if (root.canUnlock)
            root.unlockWanted();
        return true;
    }
    // a finger down when the hold starts is lifted where it was
    onInputHeldChanged: {
        if (root.inputHeld && pointer.down) {
            pointer.down = false;
            if (root.session)
                root.session.touch("up", pointer.lastX, pointer.lastY);
        }
    }

    MediaPlayer {
        id: player
        source: root._wanted && !root._off ? root.session.url : ""
        videoOutput: out
        audioOutput: root._ao
        playbackOptions.playbackIntent: PlaybackOptions.PlaybackIntent.LowLatencyStreaming
        // A probe that reads more than a few frames waits for them at the phone's own rate: ~2 s for 32 KB of a small stream, 5 s of
        // silence at 100 KB. The FLV carries the codec's record, so a little is enough.
        playbackOptions.probeSize: 4096
        onSourceChanged: {
            if (player.source.toString() !== "") {
                root._clock.open = Date.now();
                root._awaiting = true;
                player.play();
            }
        }
        onErrorOccurred: (error, errorString) => {
            console.log("CASTVIEW player error: " + errorString);
            afterError.restart();
        }
    }

    // A player that has opened the stream drops the frames it probed with (low latency: no buffering of the probe) and shows nothing until
    // the next KEY frame, which a phone makes every ten seconds: ask for one the moment it is ready, and again until a picture shows.
    Timer {
        interval: 700
        repeat: true
        triggeredOnStart: true
        running: root._wanted && root._awaiting && (player.mediaStatus === MediaPlayer.BufferingMedia || player.mediaStatus === MediaPlayer.BufferedMedia)
        onTriggered: root.session.keyframe()
    }

    // The sound only while the session carries it (the sink is the user's audio device): made then, destroyed with it.
    property AudioOutput _ao: null
    readonly property bool _wantAudio: root._wanted && root.session.audio
    on_WantAudioChanged: {
        if (root._wantAudio && root._ao === null) {
            root._ao = aoComp.createObject(root);
        } else if (!root._wantAudio && root._ao !== null) {
            const o = root._ao;
            root._ao = null;
            o.destroy();
        }
    }
    Component {
        id: aoComp
        AudioOutput {}
    }

    VideoOutput {
        id: out
        anchors.fill: parent
        fillMode: root.cover ? VideoOutput.PreserveAspectCrop : VideoOutput.PreserveAspectFit
    }

    Connections {
        target: out.videoSink
        function onVideoFrameChanged() {
            if (!root._wanted)
                return;
            root._clock.frame = Date.now();
            const first = root._awaiting;
            root._awaiting = false;
            root._hasPicture = true;
            if (first)
                root.pictureShown();
        }
    }

    // ---- the pointer ------------------------------------------------------------------------------------------------
    function _vx(x: real): real {
        return Math.max(0, Math.min(root._vw - 1, (x - root._rect.x) / root._scale));
    }
    function _vy(y: real): real {
        return Math.max(0, Math.min(root._vh - 1, (y - root._rect.y) / root._scale));
    }
    function _inside(x: real, y: real): bool {
        return root._scale > 0 && x >= root._rect.x && y >= root._rect.y && x < root._rect.x + root._rect.width && y < root._rect.y + root._rect.height;
    }

    WheelArea {
        id: pointer
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        property bool down: false
        // where the finger was last sent (a hold lifts it there)
        property real lastX: 0
        property real lastY: 0
        onPressed: mouse => {
            root.forceActiveFocus();
            if (!root.session || root.session.state !== "live" || !root._inside(mouse.x, mouse.y)) {
                mouse.accepted = false;
                return;
            }
            if (root.inputHeld || root._trigger())
                return;
            pointer.down = true;
            pointer.lastX = root._vx(mouse.x);
            pointer.lastY = root._vy(mouse.y);
            root.session.touch("down", pointer.lastX, pointer.lastY);
        }
        onPositionChanged: mouse => {
            if (pointer.down && !root.inputHeld) {
                pointer.lastX = root._vx(mouse.x);
                pointer.lastY = root._vy(mouse.y);
                root.session.touch("move", pointer.lastX, pointer.lastY);
            }
        }
        onReleased: mouse => {
            if (!pointer.down)
                return;
            pointer.down = false;
            root.session.touch("up", root._vx(mouse.x), root._vy(mouse.y));
        }
        onCanceled: {
            if (pointer.down) {
                pointer.down = false;
                root.session.touch("up", pointer.lastX, pointer.lastY);
            }
        }
        turned: wheel => {
            wheel.accepted = false;
            if (root.inputHeld || !root.session || root.session.state !== "live" || !root._inside(wheel.x, wheel.y))
                return;
            root.session.scroll(root._vx(wheel.x), root._vy(wheel.y), wheel.angleDelta.x / 120, wheel.angleDelta.y / 120);
            wheel.accepted = true;
        }
    }

    // ---- the keys ---------------------------------------------------------------------------------------------------
    Keys.onPressed: event => {
        if (!root.session || root.session.state !== "live")
            return;
        const k = event.key;
        if ([Qt.Key_Alt, Qt.Key_AltGr, Qt.Key_Shift, Qt.Key_Control, Qt.Key_Meta, Qt.Key_Super_L, Qt.Key_Super_R].indexOf(k) >= 0)
            return;
        if (root.inputHeld || root._trigger()) {
            event.accepted = true;
            return;
        }
        let name = root._navOf(k);
        if (name !== "")
            ;
        else if (k === Qt.Key_Return || k === Qt.Key_Enter)
            name = "enter";
        else if (k === Qt.Key_Backspace)
            name = "backspace";
        else if (k === Qt.Key_Delete)
            name = "del";
        else if (k === Qt.Key_Tab)
            name = "tab";
        else if (k === Qt.Key_Escape)
            name = "escape";
        else if (k === Qt.Key_Up)
            name = "up";
        else if (k === Qt.Key_Down)
            name = "down";
        else if (k === Qt.Key_Left)
            name = "left";
        else if (k === Qt.Key_Right)
            name = "right";
        if (name !== "") {
            root.session.key(name);
            event.accepted = true;
            return;
        }
        const t = event.text;
        if (t !== "" && t.charCodeAt(0) >= 32 && t.charCodeAt(0) !== 127 && (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) === 0) {
            root.session.text(t);
            event.accepted = true;
        }
    }
}
