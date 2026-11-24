pragma ComponentBehavior: Bound

import QtQuick
import "../../common/components"
import "../../common/system"

// =============================================================================
// AerialSounds.qml -- the popup's mechanical sounds (no downloaded audio: tools/aerial/make_sounds.py synthesises the six files in
// assets/sounds/aerial/), played through the shell's SoundPlayer with silicon's rules (SiliconSounds): the volume is read when the sound is made, 0 is silent
// (no process at all), only while `active` (the popup shown and not parked), a moment repeated within `debounceMs` of the last one that PLAYED plays once,
// never in a harness (the offscreen platform's default player is silent; a probe points `pwPlay` at its stub).
//
// THE MOMENTS come from the things themselves, as they reach the point, so a sound is never ahead of what is drawn:
//   screw      one tick each `screwTurn` of the screw's lift (the scene's `airplaneT` while the screw rises or sinks)
//   card_up    the card leaves its slot (the airplane lift reaches the end of the screw's share going up)
//   card_seat  the card seats again (airplaneT back to 0)
//   dip        a lever crosses the middle of its travel (the scene's two DIP poses), either way
//   thunk      a hologram docks: the controller's docking flight lands (phase docking -> not docking)
//   pop        a hologram is pulled off: the controller sends a disconnect, a stop, a forget or the tunnel down
//
//   audition(name)   the sound NOW at its volume, popup shown or not (a mockup's own "play")
// =============================================================================
Item {
    id: root

    property var scene: null              // AerialScene
    property var drag: null               // DragController
    property bool active: false
    // THE VOLUMES, 0 .. 1 (0 silent), the module's constants, tuned on the mockup's Sounds tab
    property real screwVolume: 0.2
    property real cardVolume: 0.2
    property real dipVolume: 0.2
    property real thunkVolume: 0.25
    property real popVolume: 0.2
    // how far the screw's lift (0..1 of airplaneT's share) moves between two ticks of the ratchet
    property real screwTurn: 0.17
    property string pwPlay: "pw-play"
    property string soundDir: RepoRoot.dir + "/assets/sounds/aerial/"
    property int debounceMs: 80
    readonly property bool _harness: Qt.platform.pluginName === "offscreen" && root.pwPlay === "pw-play"
    // the sounds each moment makes, in the order the log (a probe reads it) gets them
    property var log: []
    visible: false

    readonly property var _volumeOf: ({ screw: "screwVolume", card_up: "cardVolume", card_seat: "cardVolume", dip: "dipVolume", thunk: "thunkVolume", pop: "popVolume" })
    property var _last: ({})

    function _volume(name: string): real {
        const v = root[root._volumeOf[name]];
        return typeof v === "number" && isFinite(v) ? Math.max(0, Math.min(1, v)) : 0;
    }
    function _start(name: string, volume: real): void {
        player.play(name === "card_up" || name === "card_seat" ? "card" : name, root.soundDir + name + ".wav", { volume: volume });
    }
    function _moment(name: string): void {
        if (!root.active)
            return;
        // the log is the moments heard by a player that is silent (a harness), not what played
        root.log.push(name);
        if (root._harness)
            return;
        const volume = root._volume(name);
        if (!(volume > 0))
            return;
        const now = Date.now();
        const gap = now - (root._last[name] === undefined ? -Infinity : root._last[name]);
        if (name !== "screw" && gap >= 0 && gap < root.debounceMs)
            return;
        root._last[name] = now;
        root._start(name, volume);
    }
    function audition(name: string): void {
        const volume = root._volume(name);
        if (!root._harness && volume > 0 && root._volumeOf[name] !== undefined)
            root._start(name, volume);
    }

    SoundPlayer {
        id: player
        pwPlay: root.pwPlay
        keys: ["screw", "card", "dip", "thunk", "pop"]
    }

    // ---- the screw: a tick per turn of the lift, either way ----
    readonly property real _share: root.scene ? root.scene.screwShare : 0.35
    readonly property real _lift: root.scene ? Math.min(1, root.scene.airplaneT / root._share) : 0
    property int _turns: 0
    readonly property int _turnsNow: Math.floor(root._lift / Math.max(0.02, root.screwTurn) + 1e-6)
    on_TurnsNowChanged: {
        if (root._turnsNow !== root._turns)
            root._moment("screw");
        root._turns = root._turnsNow;
    }
    // the card: up when the tilt starts, seated when the airplane pose is back to 0
    readonly property real _air: root.scene ? root.scene.airplaneT : 0
    property bool _cardUp: false
    on_AirChanged: {
        if (!root._cardUp && root._air >= root._share + 0.02) {
            root._cardUp = true;
            root._moment("card_up");
        } else if (root._cardUp && root._air <= 0.001) {
            root._cardUp = false;
            root._moment("card_seat");
        }
    }
    // the DIPs
    property bool _dwOn: false
    property bool _dbOn: false
    readonly property real _dw: root.scene ? root.scene.dipWifiPose : 0
    readonly property real _db: root.scene ? root.scene.dipBtPose : 0
    on_DwChanged: {
        const on = root._dw >= 0.5;
        if (on !== root._dwOn) {
            root._dwOn = on;
            root._moment("dip");
        }
    }
    on_DbChanged: {
        const on = root._db >= 0.5;
        if (on !== root._dbOn) {
            root._dbOn = on;
            root._moment("dip");
        }
    }
    // the holograms
    property bool _docking: false
    readonly property string _phase: root.drag ? root.drag.phase : ""
    on_PhaseChanged: {
        if (root._docking && root._phase !== "docking")
            root._moment("thunk");
        root._docking = root._phase === "docking";
    }
    Connections {
        target: root.drag
        ignoreUnknownSignals: true
        function onIntent(name: string, args: var): void {
            if (name === "disconnect" || name === "stopHotspot" || name === "vpnDisconnect" || name === "btDisconnect" || name === "btForget")
                root._moment("pop");
        }
    }
    // a state that is already there when the popup comes up is no moment: the poses are re-read, not played
    function resync(): void {
        root._turns = root._turnsNow;
        root._cardUp = root._air >= root._share + 0.02;
        root._dwOn = root._dw >= 0.5;
        root._dbOn = root._db >= 0.5;
        root._docking = root._phase === "docking";
    }
    Component.onCompleted: root.resync()
}
