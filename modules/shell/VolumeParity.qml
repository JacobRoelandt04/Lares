pragma ComponentBehavior: Bound

import QtQuick

import "../common/components"
import "../bar/audio"

// =============================================================================
// VolumeParity.qml -- waybar's volume, as the bar's AudioBarButton (PLAN.md answer 15, 34): ONE pill with two halves.
//
//   the speaker half     left click: the audio popup on Outputs (`mixerRequested(0)`)   right click: mute   wheel: volume
//   the microphone half  left click: the audio popup on Inputs (`mixerRequested(1)`)    right click: mute   wheel: gain
//
// Over the LOCK no popup can open (the lock's is the primary), so there BOTH buttons mute, left and right alike.
//
// The button draws (the device's glyph by type and level, faint when muted); this does what waybar's module did. The
// MUTE goes through the OSD's service -- `osd.volume("mute")` / `osd.mic("mute")` -- so the mute shows its card;
// without an OSD service (nothing to ask) it reaches the audio service's own helper instead.
//
// THE WHEEL steps by 1 % (more granular control than the keys' steps: DeploymentNotes),
// counted by the shell's detent (WheelStepper) and written to the audio service itself:
// the OSD's verbs step by ITS config (2 % on the speaker, 5 % on the microphone -- the keys'
// step) and take no amount, so they cannot do 1 %. The OSD still shows its card: it watches the
// node and reports a change it did not make. A mouse notch is exactly one step; a touchpad counts
// `touchpadUnits` of angle (dozens of small events make a step or two, a flick no longer races)
// and the fingers' lift drops the remainder. The direction is the HAND's: the wheel rolled away
// or the fingers moved up raises the volume, whatever natural scrolling does to the deltas
// (AudioBarButton reads `inverted`). Two rules of the OSD's pipeline are kept because the
// wheel is the easiest way to break them: a raise unmutes, and the wheel never carries a level
// past 100 % (above is the keys' deliberate boost gate); a level already boosted is not pulled
// down by an up-step.
//
// THE WHEEL COUNTS FROM WHERE THE HAND HAS TAKEN THE LEVEL, never from the node's own figure while a
// gesture runs. A node that sits on a device (every real source and sink) answers a write LATER than
// the next wheel event arrives, and quickshell (PwNodeBoundAudio, device path) keeps one write in
// flight, remembers only the newest of the rest, and puts the device's older figure back into
// `audio.volume` when the answer comes: a step counted from that figure starts again from a stale
// number. Against a device that answers in 60 ms, 60 notches
// up from 60 % end at 78 % and 60 notches down from 100 % at 89 % (the OSD's 5 % key steps do no better: a
// hard push from 60 % ends at 85 % and 90 %, the microphone "stuck below 100 %"). The goal is dropped 400 ms after the last write, or when the node shows a figure no
// write of this gesture produced (somebody else moved it, once the answers to ours are in).
//
// `pipewire` is PipewireService (live) or PipewireMock; it supplies the state the halves dim by
// (a muted half is drawn faint).
// =============================================================================
Item {
    id: root

    property var pipewire: null
    property var osd: null
    // A left click on a half (not while locked): the host opens the audio popup on that half's tab (AudioBarOwner.show). 0 the speaker, 1 the microphone.
    signal mixerRequested(int half)
    // A compositor to ask for the natural-scroll settings (the host's `!!frame.window`; false in a mock run and in a probe).
    property bool live: false
    // The session is locked: the wheel stays (the audio is controlled with keybinds anyway, so scrolling the bar icons is
    // allowed too, mic and audio) and so do both buttons, which MUTE -- no popup opens over the lock (the pill is in the locked window's
    // input region; ShellScreen).
    property bool locked: false
    // The wheel's step as a fraction of the range, and its units: angle for one step with a mouse (a notch is 120,
    // so a notch is exactly one step) and with a touchpad (the shell's 2.5 angle units a pixel make 100 about 40 px
    // of finger travel: a 300 px stroke is 7 steps). Constants of this
    // control, not of the config: the OSD's step (osd.jsonc) belongs to the keys.
    readonly property real stepFraction: 0.01
    readonly property real notchUnits: 120
    readonly property real touchpadUnits: 100

    readonly property alias button: ph
    readonly property alias naturalScroll: nat
    implicitWidth: ph.implicitWidth
    implicitHeight: ph.implicitHeight

    readonly property var _sink: root.pipewire ? root.pipewire.defaultSink : null
    readonly property var _source: root.pipewire ? root.pipewire.defaultSource : null
    readonly property bool sinkMuted: !!root._sink && !!root._sink.audio && root._sink.audio.muted === true
    readonly property bool sourceMuted: !!root._source && !!root._source.audio && root._source.audio.muted === true

    // The chip the wheel is counting for (a gesture that crosses to the other chip starts that chip's count clean).
    property int _wheelIndex: -1
    WheelStepper {
        id: stepper
        notchThreshold: root.notchUnits
        pixelThreshold: root.touchpadUnits
        stepCooldownMs: 0
    }
    // A device that never sends the lift (a mouse wheel) ends its count by silence.
    Timer {
        id: idle
        interval: 300
        onTriggered: stepper.end()
    }

    // Where the hand has taken the level: { name (the node it is for), v, ceiling, seen (every figure this gesture
    // wrote: the device's late answer to a write is one of them, a stranger's change is not) }.
    property var _goal: null
    Timer {
        id: goalHold
        interval: 400
        onTriggered: root._goal = null
    }

    NaturalScroll {
        id: nat
        live: root.live
    }

    AudioBarButton {
        id: ph
        anchors.fill: parent
        touchpadNatural: nat.touchpad
        mouseNatural: nat.mouse
        outputDeviceType: ph.glyphs.deviceType(root._sink)
        outputVolume: root._sink && root._sink.audio ? root._sink.audio.volume : 0
        outputMuted: root.sinkMuted
        inputVolume: root._source && root._source.audio ? root._source.audio.volume : 0
        inputMuted: root.sourceMuted
        onHalfClicked: (index, button) => root.click(index, button)
        onWheeled: (index, units, fromPixels) => root.wheel(index, units, fromPixels)
        onWheelEnded: {
            stepper.end();
            idle.stop();
        }
    }

    // Which half a point of this item is on.
    function halfAt(x: real, y: real): int {
        const p = root.mapToItem(ph, x, y);
        return ph.halfAt(p.x, p.y);
    }

    function click(index: int, button: int): void {
        if (button !== Qt.LeftButton && button !== Qt.RightButton)
            return;
        // left opens the audio popup, right mutes; over the lock there is no popup to open, so either button mutes
        if (button === Qt.LeftButton && !root.locked) {
            root.mixerRequested(index);
            return;
        }
        if (root.osd) {
            if (index === 0)
                root.osd.volume("mute");
            else
                root.osd.mic("mute");
        } else if (root.pipewire) {
            root.pipewire.toggleMute(index === 0 ? root._sink : root._source);
        }
    }

    // One wheel event's units (positive = up, the hand's sense) counted into whole steps and written.
    function wheel(index: int, units: real, fromPixels: bool): void {
        if (index !== root._wheelIndex) {
            stepper.end();
            root._wheelIndex = index;
        }
        idle.restart();
        const steps = stepper.feed(units, fromPixels);
        if (steps !== 0)
            root.step(index, steps);
    }

    // The goal for `node` (a new one, from the node's figure, when there is none, it is another node's, or the node
    // shows a figure nothing of this gesture wrote).
    function _goalFor(node: var, a: var): var {
        const g = root._goal;
        if (g !== null && g.name === node.name) {
            for (let i = 0; i < g.seen.length; i++)
                if (Math.abs(g.seen[i] - a.volume) < 0.002)
                    return g;
        }
        return { name: node.name, v: a.volume, ceiling: Math.max(1, a.volume), seen: [] };
    }

    // `steps` whole steps (signed) on the speaker (0) or the microphone (1).
    function step(index: int, steps: int): void {
        root.stepNode(index === 0 ? root._sink : root._source, steps);
    }

    // `steps` whole steps on ANY node: the one place a volume step comes from. The audio popup's rows step through this, so a wheel over a
    // device-backed row counts from the goal too. One hand, one goal: a gesture on another node starts that node's count.
    function stepNode(node: var, steps: int): void {
        const a = node ? node.audio : null;
        if (!root.pipewire || !a)
            return;
        const g = root._goalFor(node, a);
        // The figure is whole thousandths (the OSD's own rounding): no float dust from a long climb.
        const v = Math.round(Math.max(0, Math.min(g.ceiling, g.v + steps * root.stepFraction)) * 1000) / 1000;
        root._goal = { name: g.name, v: v, ceiling: g.ceiling, seen: g.seen.indexOf(v) >= 0 ? g.seen : g.seen.concat([v]) };
        goalHold.restart();
        root.pipewire.setVolume(node, v);
        if (steps > 0 && a.muted === true)
            root.pipewire.setMuted(node, false);
    }

    // Where the hand has taken this node (what a read-back compares with), -1 when no gesture is on it.
    function goalOf(node: var): real {
        return root._goal !== null && !!node && root._goal.name === node.name ? root._goal.v : -1;
    }
}
