pragma ComponentBehavior: Bound

import QtQuick
import "../OsdKinds.js" as Kinds

// =============================================================================
// BacklightSource.qml -- the display's brightness, changed by the shell's own
// keys and by nothing else.
//
//   adjust(dir, fine, phase)   a key step: dir +1 | -1, fine = the Shift step,
//                              phase "press" | "repeat" | "release"
//   setValue(frac)             a drag on the OSD's slider, 0..1 (no request)
//   signal request(var req)    one partial CONTRACT section 1 request
//
// THE LADDER, AND WHAT THE CARD SHOWS. A key climbs a ladder of rungs along the perceptual curve (twenty at
// 5 %: OsdKinds.brightnessRungs) and the request's `value` is the RUNG over the count -- 5 points per press,
// the ball and the figure agreeing -- not raw / max (the accurate
// percentage is not needed). The bottom rung is the true minimum level (floorRaw, 1); a held key stops there, and a FRESH
// press down that begins there goes to true 0 (the screen off), as volume's boost gate does downwards: the
// gesture's gate is decided at the press and kept for its repeats. One press up leaves 0.
// A drag on the slider maps back through the same ladder and never blacks the screen.
//
// NOTHING WATCHES THE BACKLIGHT. The OSD answers a key, so hypridle's dimming
// and any other program writing the file are invisible for free -- there is no
// "ignore the idle dim" rule to keep right.
//
// READ AT ACTION TIME. A fresh press reads /sys/class/backlight/<device>/
// brightness and max_brightness (the file is the truth: the user, a script or
// hypridle may have moved it since), steps on the ladder (OsdKinds.brightnessStep:
// from anywhere between two rungs it lands on the next one) and writes through
// SysfsLevel. During a held key the target is kept in memory (repeats do not re-read).
//
// `live: false` reads and writes nothing: the value and its maximum are
// whatever simulateSet() said, and a key step moves them and emits the same
// request.
// =============================================================================
Item {
    id: root

    property bool live: true
    // the backlight's name (OsdService: the config's, else PanelBacklight's; "" = none found: the keys do nothing)
    property string device: ""
    // Where the device's directory is (a probe points it at a fake sysfs).
    property string sysfsRoot: "/sys/class/backlight"
    property real stepFrac: 0.05
    property real fineStepFrac: 0.01
    property real gamma: 2.0
    property int floorRaw: 1
    // Raw 0 turns the panel black. False (nvidia_0: its 0 is not black, and some drivers read it as the brightest) closes the zero gate:
    // a key never writes 0 there, the bottom rung (floorRaw) is the end.
    property bool zeroOpens: true
    // The ladder's numbers as the pure functions read them (OsdKinds.brightness*).
    readonly property var _ladder: ({ gamma: root.gamma, step: root.stepFrac, fineStep: root.fineStepFrac, floorRaw: root.floorRaw })
    // The gesture's zero gate: true 0 is open for the key gesture that began at the last press.
    property bool _zero: false

    signal request(var req)

    readonly property int raw: level.raw
    readonly property int max: level.max
    // A write of ours is running or waiting (the file is behind the target then).
    readonly property bool pending: level.pending

    // The device has been read (or seeded): raw and max mean something.
    readonly property bool known: level.known

    // The figure the card shows now, 0..1 (the ladder's rung over its count).
    function levelNow() {
        return Kinds.brightnessLevel(level.raw, level.max, root._ladder);
    }

    // Read the device now (a read only; adjust() does it itself on a press).
    function refresh() {
        level.read();
    }

    function simulateSet(raw, max) {
        level.seed(raw, max);
    }

    function adjust(dir, fine, phase) {
        if (phase === "release")
            return true;
        if (phase === "press")
            level.read();
        if (!level.known)
            return false;
        // decided once, at the press: a repeat that reaches the bottom must not decide again
        if (phase === "press")
            root._zero = root.zeroOpens && Kinds.brightnessZeroOpens(level.raw, level.max, dir, root._ladder);
        level.write(Kinds.brightnessStep(level.raw, level.max, dir, fine, root._ladder, root._zero));
        root._emit("key");
        return true;
    }

    function setValue(frac) {
        level.read();
        if (!level.known)
            return;
        level.write(Kinds.brightnessFromLevel(frac, level.max, root._ladder));
    }

    function _emit(source) {
        root.request({
            kind: "brightness",
            key: "brightness",
            source: source,
            value: Kinds.brightnessLevel(level.raw, level.max, root._ladder),
            max: 1,
            muted: false,
            boost: false,
            device: { type: "display", name: root.device }
        });
    }

    SysfsLevel {
        id: level
        live: root.live
        device: root.device
        sysfsRoot: root.sysfsRoot
    }
}
