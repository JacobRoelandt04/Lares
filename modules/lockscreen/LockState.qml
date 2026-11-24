import QtQuick

// =============================================================================
// LockState.qml -- what the lock knows, as facts (contract section 2).
//
// The lock process owns the only writable one (AuthController, KeyState,
// AwakeClock and the choreography write it); the shell holds a mirror that
// LockOwner fills from the socket with LockProtocol.applyState. The popup and
// the fallback card read either one the same way.
//
// Facts only: no colour and no display string lives here. `authMessage` and
// `faceMessage` are PAM's raw words; the popup decides what to say.
// =============================================================================
QtObject {
    // "locking" | "locked" | "unlocking"
    property string phase: "locking"
    // started by Hyprland --locked-cmd: nothing is behind the lock
    property bool boot: false
    // ms since epoch when the lock was confirmed (secure); 0 before
    property real lockedAt: 0

    // characters in the password buffer (0..512); the password itself never
    // leaves AuthController
    property int dots: 0
    property bool caps: false

    // "idle" | "checking" | "failed" | "ok"
    property string auth: "idle"
    property int failCount: 0
    property string authMessage: ""

    // "absent" | "idle" | "scanning" | "ok" | "failed" | "dark" | "busy"
    // | "unavailable" | "misconfigured"
    property string face: "absent"
    property string faceMessage: ""
    // WHY, as a fact the lock read off howdy's words, its result and the lid:
    // "" | "nomatch" | "dark" | "camera" (would not open: in use or
    // gone) | "lid" (closed: howdy skips) | "nomodel" | "error" (howdy's own) |
    // "stall" (the scan hung) | "timeout" (a native-workaround scan that never
    // said anything: howdy's own timeout ran out) | "input" (the stack asked for a response) |
    // "workaround" | "device" | "config" | "pam" (FaceAvailability's causes)
    property string faceReason: ""

    // input within idleSeconds; false = everything eases to still
    property bool awake: true

    // ms since epoch when the veil had risen on every surface (presence 0.97); 0 locked and not yet; -1 not said (a lock older than
    // the field, or none). The sleep fade of the shell waits for it.
    property real veilAt: -1
}
