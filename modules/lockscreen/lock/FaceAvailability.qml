pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// FaceAvailability.qml -- may the lock try a face scan here at all?
//
// NEVER opens the camera: it only tests that files exist and reads howdy's
// config. `face`:
//   "absent"        no face auth on this machine (or turned off)
//   "idle"          available
//   "misconfigured" a face setup that must not run; `reason` says why
//   "pending"       the check has not answered yet (a few ms)
//
// Verdict, in order: config `face` "off" or LARES_LOCK_FACE=0 -> absent;
// LARES_LOCK_FACE=1 -> idle, ignoring everything below (a test hook and the user's
// override); then pam_howdy.so, /etc/pam.d/lares-lock-face, howdy's config.ini
// (readable, [core] workaround = off or native, [video] device_path existing)
// and the user's model file. WHY workaround may not be `input`: it is the one
// mode that injects an Enter keypress through uinput when the face matches --
// into whatever half-typed password sits in the buffer. `off` and `native` never
// type anything; they differ in what the stack does: `off` asks nothing, and
// `native` asks for the password on a second thread at once (the controller
// holds that prompt unanswered and times the scan out itself, see
// AuthController). Config "on" turns a missing piece from "absent" into
// "misconfigured" (the user asked for it, so say why it cannot work); "auto"
// stays quiet.
//
// What the controller needs from howdy's config -- `howdyWorkaround` ([core]
// workaround, as written, lower-case, "" if unreadable) and `howdyTimeoutMs`
// ([video] timeout in seconds, default 4) -- is read EVEN under LARES_LOCK_FACE=1,
// and `face` leaves "pending" only once it is known, so a scan never starts
// before the controller knows which stack it is talking to.
//
// THE KEYRING (config `keyringPassword`, default true; "Password once per boot"): the lock's password stack also opens the login keyring with the
// password typed (pam_gnome_keyring in /etc/pam.d/lares-lock), which a face unlock cannot do. So while the keyring is LOCKED no face is offered -- `absent`,
// reason `keyring` (AuthController hands it on as LockState.faceReason; the status row says why). The fact is READ, never guessed: the Secret Service's
// `org.freedesktop.Secret.Collection` `Locked` of the `login` collection on the session bus (busctl, read only), once at the lock's start. When it cannot
// be read (no session bus -- a boot lock under SDDM -- no Secret Service, no `login` collection) the rule falls back to the boot flag: a boot lock (not a
// relaunch) is password-only. LARES_LOCK_FACE=1, the user's explicit override, and `face` off / LARES_LOCK_FACE=0 come first.
//
// The paths are properties so a test copy can point them at fixtures.
// =============================================================================
Scope {
    id: root

    // "auto" | "on" | "off" (LockConfig.face)
    property string mode: "auto"
    property string envForce: Quickshell.env("LARES_LOCK_FACE") || ""
    property string user: Quickshell.env("USER") || ""
    property string pamModule: "/usr/lib/security/pam_howdy.so"
    property string pamFile: "/etc/pam.d/lares-lock-face"
    property string oldPamFile: "/etc/pam.d/qs-lock-face"   // the old name's file, which the lock asks for until pamFile is installed
    property string howdyConfig: "/etc/howdy/config.ini"
    property string modelsDir: "/etc/howdy/models"

    // the keyring rule (above): the config switch, the boot fallback (LockRoot: boot and not a relaunch), the Secret Service's answer
    property bool keyringPassword: true
    property bool bootFallback: false
    property string busctl: "busctl"
    property string keyringPath: "/org/freedesktop/secrets/collection/login"
    // "locked" | "unlocked" | "unknown" (not read, or unreadable)
    property string keyring: "unknown"

    property string face: "pending"
    property string reason: ""
    // howdy's [core] workaround ("off" | "native" | "input" | ""), lower-case.
    property string howdyWorkaround: ""
    // howdy's [video] timeout in ms: how long a scan looks for a face.
    property int howdyTimeoutMs: 4000

    // One shell script, two answer lines: "config <workaround> <timeout s>", then
    // "<verdict> <reason>".
    readonly property string _script: [
        'wa=$(sed -n \'/^\\[core\\]/,/^\\[/{s/^[[:space:]]*workaround[[:space:]]*=[[:space:]]*//p}\' "$3" 2>/dev/null | tr -d \'[:space:]\' | tr A-Z a-z | head -1)',
        'to=$(sed -n \'/^\\[video\\]/,/^\\[/{s/^[[:space:]]*timeout[[:space:]]*=[[:space:]]*//p}\' "$3" 2>/dev/null | tr -d \'[:space:]\' | head -1)',
        'echo "config $wa $to"',
        '[ -e "$1" ] || { echo "absent no pam_howdy.so"; exit 0; }',
        '[ -e "$2" ] || [ -e "$6" ] || { echo "absent no $2"; exit 0; }',
        '[ -r "$3" ] || { echo "misconfigured howdy config unreadable"; exit 0; }',
        'dev=$(sed -n \'/^\\[video\\]/,/^\\[/{s/^[[:space:]]*device_path[[:space:]]*=[[:space:]]*//p}\' "$3" | sed \'s/[[:space:]]*$//\' | head -1)',
        '[ "$wa" = off ] || [ "$wa" = native ] || { echo "misconfigured howdy workaround is \\"$wa\\", must be off or native"; exit 0; }',
        '[ -n "$dev" ] && [ -e "$dev" ] || { echo "misconfigured howdy camera device missing"; exit 0; }',
        '[ -e "$4/$5.dat" ] || { echo "absent no face model for $5"; exit 0; }',
        'echo "idle ok"'
    ].join("\n")

    function _decide(text) {
        const lines = text.split("\n");
        const cfg = (lines[0] || "").split(" ");
        root.howdyWorkaround = cfg[1] || "";
        const secs = parseFloat(cfg[2]);
        root.howdyTimeoutMs = secs > 0 ? Math.round(secs * 1000) : 4000;
        if (root.envForce === "1") {
            root.reason = "LARES_LOCK_FACE=1";
            root.face = "idle";
            return;
        }
        const line = (lines[1] || "").trim();
        const sp = line.indexOf(" ");
        let verdict = sp < 0 ? line : line.substring(0, sp);
        const why = sp < 0 ? "" : line.substring(sp + 1);
        if (verdict === "absent" && root.mode === "on")
            verdict = "misconfigured";
        if (verdict !== "absent" && verdict !== "idle" && verdict !== "misconfigured")
            verdict = "absent";
        if (root._keyringHolds()) {
            root.reason = "keyring";
            root.face = "absent";
            return;
        }
        root.reason = why;
        root.face = verdict;
    }
    // the rule is on and the keyring is locked (or cannot be read and this is a boot lock)
    function _keyringHolds() {
        return root.keyringPassword && root.envForce !== "1" && (root.keyring === "locked" || (root.keyring === "unknown" && root.bootFallback));
    }

    Process {
        id: keyringRead
        // `busctl --user get-property ... Locked` answers `b true` / `b false`; anything else (no bus, no service, no collection) is "unknown"
        command: ["sh", "-c", 'timeout 3 "$1" --user get-property org.freedesktop.secrets "$2" org.freedesktop.Secret.Collection Locked 2>/dev/null || echo ERR', "sh", root.busctl, root.keyringPath]
        stdout: StdioCollector {
            onStreamFinished: {
                const t = this.text.trim();
                root.keyring = t === "b true" ? "locked" : t === "b false" ? "unlocked" : "unknown";
                console.log("lock: the login keyring reads " + root.keyring + (root._keyringHolds() ? ": no face" : ""));
                check.running = true;
            }
        }
    }

    Process {
        id: check
        command: ["sh", "-c", root._script, "sh", root.pamModule, root.pamFile, root.howdyConfig, root.modelsDir, root.user, root.oldPamFile]
        stdout: StdioCollector {
            onStreamFinished: root._decide(this.text.trim())
        }
    }

    // Called once by LockRoot, after the config has been read (`mode`).
    function start() {
        if (root.envForce === "0" || root.mode === "off") {
            root.reason = root.envForce === "0" ? "LARES_LOCK_FACE=0" : "face is off in the config";
            root.face = "absent";
        } else if (root.keyringPassword && root.envForce !== "1") {
            keyringRead.running = true;      // its answer starts the check
        } else {
            check.running = true;
        }
    }
}
