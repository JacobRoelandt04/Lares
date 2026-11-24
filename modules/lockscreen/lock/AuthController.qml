pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam

import "../"
import "../../common/components"
import "../../common/system"

// =============================================================================
// AuthController.qml -- the ONLY way this lock ever opens.
//
// Two PamContexts: "lares-lock" (the password stack) and "lares-lock-face" (howdy) -- "qs-lock" / "qs-lock-face" until those files are installed,
// and the machine's own "login" for the password where neither name's file is there (a fresh machine: THE PAM SERVICES below).
// Whichever completes with PamResult.Success first wins; the other is aborted
// (abort SIGKILLs its PAM child). Nothing else -- no message from the shell, no
// timer, no error path -- emits `succeeded`, and LockRoot releases the session
// only from that signal.
//
// STRICT SUCCESS. PamResult.Success is 0, so `if (result)` is true for every
// FAILURE and false for success: a hole in one direction or the other. Both
// handlers compare `result === PamResult.Success` and nothing else. Failed,
// Error, MaxTries, an aborted context and an error() signal never unlock.
//
// THE PASSWORD. There is no text field anywhere in the lock: keys arrive as
// events (handleKey) and go into one PasswordBuffer (the key handling the auth
// toast shares), capped at 512 characters. `dots` is its length; the text never
// leaves this object. Enter answers the password prompt with it (take() empties
// the buffer).
//
// FACE. Started only after the lock is secure (never before: a scan that wins
// before the session is locked would "unlock" nothing, and the camera would be
// on for a lock that does not exist yet). howdy talks through PAM messages
// (byte-exact): TEXT_INFO "Identified face as <user>"; ERROR_MSG "Failure,
// timeout reached", "Face detection image too dark"; a closed lid or an ssh
// session makes the module return AUTHINFO_UNAVAIL with NO message. Mapping:
//   scanning   the scan runs
//   ok         it won
//   failed     it ended with a message (timeout / no match)
//   dark       "too dark"
//   unavailable  an ERROR result with no message (AUTHINFO_UNAVAIL surfaces as
//              PamResult.Error), or a second Failed with no message in a row
//   busy       a Failed with NO message the first time: an aborted scan's
//              compare.py holds the camera for up to howdy's 4 s timeout after
//              its PAM child was killed, so wait faceRearmCooldownMs and retry
//              ONCE (a real no-match always says something)
//   misconfigured  the face context asked for a RESPONSE (and howdy's workaround
//              is not `native`), or FaceAvailability said so. A face stack that
//              asks for input is one that would type into the password: it is
//              aborted and NEVER answered.
// NATIVE (howdy `workaround = native`). The
// face stack PROMPTS for the password at ~0 ms: howdy asks on a second thread
// while the scan runs, and cancels that thread itself when the face wins (the
// stack then completes with Success). So under native a prompt is expected: it is
// held UNANSWERED (answering it kills the scan), never `misconfigured`. A face
// that FAILS sends no message and the stack then waits for the password for
// ever, so the controller ends the scan itself: howdyTimeoutMs ([video] timeout)
// plus nativeMarginMs (the camera's start) after the scan began it aborts the
// stack (the reap included) and the state reads failed / "timeout". The dark,
// camera and lid reasons cannot be known there. Under `off` nothing changes: a
// face stack that prompts IS a misconfiguration.
// WHY: beside the state the lock sets `faceReason`, a fact the popup
// turns into words. From howdy's message: "timeout reached" nomatch, "too dark"
// dark, "not possible to open camera" camera (unavailable at once, no busy
// retry; the next typed first character tries again -- a call may have let it
// go), "no face model known" nomodel, "unknown error" / "general abort" error.
// An unavailable stack with nothing said reads the lid (howdy skips a closed
// lid without a word): closed = lid. The stall watchdog says stall, a stack that
// asks for input says input, and FaceAvailability's reason text maps to
// workaround / device / config / nomodel / pam.
// WHEN IT STARTS. A DELIBERATE lock never scans at once: the user is
// in front of the screen and howdy would unlock it that instant. The face
// context starts only when (a) the lock is a boot lock (`faceAtStart`: nobody
// chose it, nobody is necessarily there), (b) the machine resumed from sleep
// (`resumed()`), (c) the first input arrives after the lock has RESTED
// (AwakeClock idle -> awake: the user came back), or (d) the user asks:
// Enter on an empty buffer, or the first character typed into an empty field.
// Once any of these has happened the face is "armed" for the rest of the lock.
// Re-arm: after a scan that did not win, the next wake or an Enter on an empty
// buffer starts ONE scan, at least faceRearmCooldownMs after the last one ended.
//
// WATCHDOGS. A face scan running > 30 s is aborted (face "failed"); a password
// context that was answered and has not completed in 30 s is aborted and
// restarted. A password context that has not PROMPTED within promptTimeoutMs of
// its start is restarted too, keeping the typed buffer and a held Enter: under
// Quickshell 0.3.1 the first prompt now and then never arrives (1 start in ~30
// in lock/unlock cycles), and an Enter held for it waits for ever --
// "checking" with no way to unlock but the face. Each miss in a row doubles the
// wait, so a slow machine is not restarted in a loop. A password context that fails instantly (no such service, PAM
// error) restarts only after 1 s: never a tight loop.
// =============================================================================
Scope {
    id: root

    // ---- wiring (set by LockRoot) ------------------------------------------------
    property LockState lockState: null
    property QtObject awake: null
    // FaceAvailability's verdict: "pending" | "absent" | "idle" | "misconfigured"
    property string faceAvailability: "pending"
    property string faceReason: ""
    property int faceRearmCooldownMs: 5000
    // THE CAMERA AFTER A RESUME. The first scan after a resume often meets a camera the kernel has not brought back ("Failed to
    // read camera specified in the 'device_path' config option": the face scan times out and the password
    // works). The scan that a resume starts, if it does not win, is tried ONCE more this long after it ended -- whatever the
    // cooldown says (the cooldown is for scans the user asked for). Never a counted attempt: a face that does not match costs
    // nothing here, and the password is never touched.
    property int resumeRetryMs: 2000
    // howdy's [core] workaround and [video] timeout (FaceAvailability). Under
    // "native" the face stack's prompt is held and the scan is timed out here.
    property string howdyWorkaround: ""
    property int howdyTimeoutMs: 4000
    // The camera's start, on top of howdy's own timeout, before a native scan
    // with no word from the stack is called failed.
    property int nativeMarginMs: 1500
    // A boot lock (not a relaunch, not a deliberate lock): scan as soon as secure.
    property bool faceAtStart: false
    // The first input after the lock rested starts a scan (lockscreen.jsonc faceWhen "return").
    property bool faceOnReturn: true
    // The session is locked for real (WlSessionLock.secure).
    property bool secure: false
    // Where PAM's service files live. Production is /etc/pam.d, always: there
    // is no environment override (a probe patches a scratch COPY of this file).
    property string pamDirectory: "/etc/pam.d"
    // THE PAM SERVICES. The project became Lares and the PAM files of the old name stay installed beside the new ones until
    // `lares cleanup-old-name`: the password context asks for "lares-lock" and the face context for "lares-lock-face" once that file is in
    // pamDirectory (root step R2 of `lares setup` makes them as copies of the old), and for "qs-lock" / "qs-lock-face" until then. Read once,
    // when the controller is built (a stack is never swapped under a lock that is up); an empty or missing file counts as absent.
    // A FRESH MACHINE has neither name's file: a service that is not installed denies everything, and a lock nobody can open is worse than any
    // stack, so the password context then asks "login" -- the stack the machine's own TTY asks, always there -- until R2 has been done.
    // A PamContext takes its `config` when it is STARTED: _startPassword / _startFace assign it from these, which `_readServices` reads once.
    property string passwordService: "qs-lock"
    property string faceService: "qs-lock-face"
    FileView {
        id: pamPasswordFile
        path: root.pamDirectory + "/lares-lock"
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }
    FileView {
        id: pamOldPasswordFile
        path: root.pamDirectory + "/qs-lock"
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }
    FileView {
        id: pamFaceFile
        path: root.pamDirectory + "/lares-lock-face"
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }
    // A PARENT'S Component.onCompleted RUNS BEFORE ITS CHILDREN'S: LockRoot calls begin() from its own, before this object's, so the services are
    // read by an idempotent function that every start calls first (the FileViews above are complete by then: children complete before any handler).
    property bool _servicesRead: false
    function _readServices() {
        if (root._servicesRead)
            return;
        root._servicesRead = true;
        if (pamPasswordFile.text() !== "")
            root.passwordService = "lares-lock";
        else if (pamOldPasswordFile.text() === "")
            root.passwordService = "login";
        if (pamFaceFile.text() !== "")
            root.faceService = "lares-lock-face";
        console.log("LARESLOCK pam services: password " + root.passwordService + ", face " + root.faceService);
    }
    property int stallMs: 30000
    property int promptTimeoutMs: 2000
    // Where the lid's state is read when a face stack is unavailable without a
    // word (the same files howdy reads). A probe patches its scratch copy.
    property string lidGlob: "/proc/acpi/button/lid/*/state"

    // The win: "password" or "face". LockRoot's unlock sequence starts here.
    signal succeeded(string by)

    // ---- private state -----------------------------------------------------------
    property bool _won: false
    property bool _pending: false       // answered Enter before the prompt arrived
    property bool _pwPrompted: false
    property real _pwStartedAt: 0
    property int _promptMisses: 0
    property bool _faceMisconf: false
    property bool _faceCut: false       // the controller ended this scan (stall / native timeout)
    property bool _faceMessaged: false
    property bool _faceDark: false
    property string _faceKind: ""       // the last howdy message, as a reason
    property bool _busyRetried: false
    property real _faceEndedAt: 0
    // The policy above has let the face start (latched for this lock).
    property bool _faceArmed: false

    // ---- keys ------------------------------------------------------------------------
    readonly property int maxLength: 512

    PasswordBuffer {
        id: buffer
        maxLength: root.maxLength
        onEdited: {
            if (root.lockState)
                root.lockState.dots = buffer.length;
        }
        onFirstCharacter: root._typingFace()
        onEnterPressed: empty => root._submit(empty)
    }

    // One key event from any lock surface (they all share this one buffer).
    function handleKey(event) {
        if (root._won || !root.lockState)
            return;
        if (root.lockState.auth === "failed") {
            root.lockState.auth = "idle";
            root.lockState.authMessage = "";
        }
        buffer.handleKey(event);
    }

    function _submit(empty) {
        if (empty) {
            root.requestFace(true);
            return;
        }
        root.lockState.auth = "checking";
        root.lockState.authMessage = "";
        if (pw.responseRequired) {
            root._answer();
        } else {
            // The context is between attempts: answer when its prompt arrives.
            root._pending = true;
        }
    }
    function _answer() {
        pw.respond(buffer.take());
        stall.restart();
    }

    // ---- password context ---------------------------------------------------------------
    function _startPassword() {
        if (root._won || pw.active)
            return;
        root._pwPrompted = false;
        root._pwStartedAt = Date.now();
        root._readServices();
        pw.config = root.passwordService;
        pw.start();
        promptWatch.restart();
    }
    function _pwFailed(counted) {
        stall.stop();
        promptWatch.stop();
        if (counted && root.lockState) {
            root.lockState.auth = "failed";
            root.lockState.failCount++;
        } else if (root.lockState && root.lockState.auth === "checking") {
            root.lockState.auth = "idle";
        }
        root._pending = false;
        restart.interval = (root._pwPrompted && Date.now() - root._pwStartedAt > 500) ? 30 : 1000;
        restart.restart();
    }

    PamContext {
        id: pw
        configDirectory: root.pamDirectory
        config: "lares-lock"   // assigned from passwordService at every start (_startPassword)
        onPamMessage: {
            if (root._won)
                return;
            if (pw.responseRequired) {
                root._pwPrompted = true;
                root._promptMisses = 0;
                promptWatch.stop();
                if (root._pending) {
                    root._pending = false;
                    root._answer();
                }
            } else if (pw.message !== "" && root.lockState) {
                root.lockState.authMessage = pw.message;
            }
        }
        onCompleted: result => {
            console.log("lock: password stack completed: " + PamResult.toString(result));
            if (root._won)
                return;
            if (result === PamResult.Success) {
                root._win("password");
            } else {
                // Failed, Error, MaxTries: never an unlock.
                root._pwFailed(root.lockState && root.lockState.auth === "checking");
            }
        }
        onError: error => {
            if (root._won)
                return;
            root._pwFailed(root.lockState && root.lockState.auth === "checking");
        }
    }
    Timer {
        id: restart
        onTriggered: {
            if (pw.active)
                restart.restart();
            else
                root._startPassword();
        }
    }
    Timer {
        id: promptWatch
        interval: root.promptTimeoutMs * Math.pow(2, Math.min(root._promptMisses, 4))
        onTriggered: {
            if (root._won || !pw.active || root._pwPrompted)
                return;
            root._promptMisses++;
            console.log("lock: password stack never prompted, restarted (" + root._promptMisses + ")");
            // abort() only deactivates (no completed / error): the buffer and a
            // held Enter stay, and the new stack's prompt answers them.
            pw.abort();
            root._startPassword();
        }
    }
    Timer {
        id: stall
        interval: root.stallMs
        onTriggered: {
            if (!pw.active)
                return;
            pw.abort();
            root._pwFailed(false);
        }
    }

    // ---- face context ------------------------------------------------------------------------
    // Is a scan possible at all right now?
    // A FUNCTION, not a binding: it is asked from the change handlers of its own
    // inputs, where a derived property would still hold the old answer.
    function _reasonOf(msg) {
        if (/too dark/i.test(msg))
            return "dark";
        if (/open camera/i.test(msg))
            return "camera";
        if (/no face model/i.test(msg))
            return "nomodel";
        if (/timeout reached/i.test(msg))
            return "nomatch";
        if (/unknown error|general abort/i.test(msg))
            return "error";
        return "";
    }
    function _reasonOfAvailability(why) {
        if (/workaround/i.test(why))
            return "workaround";
        if (/device/i.test(why))
            return "device";
        if (/unreadable/i.test(why))
            return "config";
        if (/face model/i.test(why))
            return "nomodel";
        if (/pam/i.test(why))
            return "pam";
        return "";
    }
    function _setFace(state, reason) {
        root.lockState.faceReason = reason;
        root.lockState.face = state;
        if (root._resumeRetry && (state === "failed" || state === "unavailable")) {
            root._resumeRetry = false;
            console.log("lock: the scan after the resume did not win: once more in " + root.resumeRetryMs + " ms");
            resumeRetryTimer.restart();
        }
    }
    // the scan a resume started has not ended yet: if it fails, it is tried once more (resumeRetryMs)
    property bool _resumeRetry: false
    Timer {
        id: resumeRetryTimer
        interval: root.resumeRetryMs
        onTriggered: root._startFace()
    }
    // Unavailable with nothing said: is the lid shut? (howdy's abort_if_lid_closed
    // skips without a message). The answer lands a few ms later and only names a
    // state that is still the one it explains.
    Process {
        id: lid
        command: ["sh", "-c", "cat " + root.lidGlob + " 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (/closed/.test(this.text) && root.lockState && root.lockState.face === "unavailable" && root.lockState.faceReason === "")
                    root.lockState.faceReason = "lid";
            }
        }
    }
    function _unavailableSilent() {
        root._setFace("unavailable", "");
        lid.running = true;
    }

    function _faceUsable() {
        return root.faceAvailability === "idle" && !root._faceMisconf && root.secure && !root._won;
    }

    // A scan wanted: `user` is a deliberate request (Enter, a wake) and forgives
    // an earlier "busy". Respects the cooldown since the last scan ended.
    function requestFace(user) {
        if (user)
            root._faceArmed = true;
        else if (!root._faceArmed)
            return;
        if (!root._faceUsable() || face.active)
            return;
        if (user)
            root._busyRetried = false;
        const wait = root.faceRearmCooldownMs - (Date.now() - root._faceEndedAt);
        if (wait > 0) {
            faceTimer.interval = Math.max(1, Math.round(wait));
            faceTimer.restart();
            return;
        }
        root._startFace();
    }
    function _startFace() {
        if (!root._faceUsable() || face.active)
            return;
        root._faceMessaged = false;
        root._faceDark = false;
        root._faceKind = "";
        root._faceCut = false;
        root._setFace("scanning", "");
        root.lockState.faceMessage = "";
        root._readServices();
        face.config = root.faceService;
        face.start();
        faceStall.restart();
        if (root.howdyWorkaround === "native")
            nativeTimeout.restart();
    }
    function _faceEnded() {
        faceStall.stop();
        nativeTimeout.stop();
        root._faceEndedAt = Date.now();
    }

    PamContext {
        id: face
        configDirectory: root.pamDirectory
        config: "lares-lock-face"   // assigned from faceService at every start (_startFace)
        onPamMessage: {
            if (root._won || root._faceMisconf)
                return;
            if (face.responseRequired) {
                // Native: howdy's own second thread asks for the password while
                // it scans. Answering it ends the scan, and nothing else is to be
                // done with it: hold it, the timer below ends a scan that fails.
                if (root.howdyWorkaround === "native") {
                    console.log("lock: native face prompt held, not answered");
                    return;
                }
                // Otherwise a face stack never asks for input. One that does would
                // be answered with a password's worth of keystrokes: never answer.
                root._faceMisconf = true;
                root._abortFace();
                root._faceEnded();
                root.lockState.faceMessage = face.message;
                root._setFace("misconfigured", "input");
                return;
            }
            if (face.message === "")
                return;
            root._faceMessaged = true;
            root.lockState.faceMessage = face.message;
            const kind = root._reasonOf(face.message);
            if (kind !== "")
                root._faceKind = kind;
            if (face.messageIsError && kind === "dark")
                root._faceDark = true;
        }
        onCompleted: result => {
            console.log("lock: face stack completed: " + PamResult.toString(result));
            if (root._won || root._faceMisconf || root._faceCut)
                return;
            root._faceEnded();
            if (result === PamResult.Success) {
                root._win("face");
                return;
            }
            // Anything else: the scan is over and did not win.
            if (root._faceDark) {
                root._setFace("dark", "dark");
            } else if (root._faceKind === "camera" || root._faceKind === "nomodel") {
                // howdy could not look at all: no busy retry, nothing to recognise
                root._setFace("unavailable", root._faceKind);
            } else if (root._faceMessaged) {
                root._busyRetried = false;
                root._setFace("failed", root._faceKind !== "" ? root._faceKind : "nomatch");
            } else if (result === PamResult.Error) {
                root._unavailableSilent();
            } else if (!root._busyRetried) {
                // Failed with nothing said: the camera may still be held.
                root._busyRetried = true;
                root._setFace("busy", "");
                root.requestFace(false);
            } else {
                root._unavailableSilent();
            }
        }
        onError: error => {
            if (root._won || root._faceMisconf)
                return;
            root._faceEnded();
            root._setFace("unavailable", "");
        }
    }
    // ABORTING A SCAN. abort() SIGKILLs the PAM child, and howdy's compare.py,
    // which pam_howdy spawned from it, outlives the dead child until its own
    // timeout, holding the camera and the IR emitter. So howdy-reap ends the
    // compare.py in THIS process's tree first (never anyone else's), and the
    // stack is aborted when it exits; the timer makes the abort late by 300 ms
    // at most.
    property string reapPath: RepoRoot.dir + "/tools/lockscreen/howdy-reap"
    function _abortFace() {
        if (!face.active || reap.running)
            return;
        reap.running = true;
        reapLate.restart();
    }
    function _abortFaceNow() {
        reapLate.stop();
        if (face.active)
            face.abort();
    }
    Process {
        id: reap
        command: [root.reapPath]
    }
    Connections {
        target: reap
        function onExited() {
            root._abortFaceNow();
        }
    }
    Timer {
        id: reapLate
        interval: 300
        onTriggered: root._abortFaceNow()
    }
    Timer {
        id: faceTimer
        onTriggered: root._startFace()
    }
    Timer {
        id: faceStall
        interval: root.stallMs
        onTriggered: {
            if (!face.active)
                return;
            root._faceCut = true;
            root._abortFace();
            root._faceEnded();
            root._setFace("failed", "stall");
        }
    }
    // A native scan that did not find a face says nothing and the stack waits for
    // the password for ever: the scan is over when howdy's own timeout is, plus
    // the camera's start. Nothing else says "timeout" here.
    Timer {
        id: nativeTimeout
        interval: root.howdyTimeoutMs + root.nativeMarginMs
        onTriggered: {
            if (!face.active || root._won)
                return;
            console.log("lock: native face scan timed out, aborted");
            root._faceCut = true;
            root._abortFace();
            root._faceEnded();
            root._busyRetried = false;
            root._setFace("failed", "timeout");
        }
    }

    // ---- the win ----------------------------------------------------------------------------------------
    function _win(by) {
        if (root._won)
            return;
        root._won = true;
        stall.stop();
        promptWatch.stop();
        restart.stop();
        faceTimer.stop();
        faceStall.stop();
        // The loser dies with its PAM child.
        if (by !== "password" && pw.active)
            pw.abort();
        if (by !== "face" && face.active)
            root._abortFace();
        buffer.clear();
        root._pending = false;
        root.lockState.dots = 0;
        root.lockState.auth = "ok";
        if (by === "face")
            root._setFace("ok", "");
        root.succeeded(by);
    }

    // ---- what the lock state says about the face, and when to look ---------------------------------
    function _syncAvailability() {
        if (root._faceMisconf || !root.lockState)
            return;
        const a = root.faceAvailability;
        if (a === "absent" || a === "misconfigured") {
            root._setFace(a, a === "misconfigured" ? root._reasonOfAvailability(root.faceReason) : (a === "absent" && root.faceReason === "keyring" ? "keyring" : ""));
            console.log("lock: face is " + a + (root.faceReason !== "" ? " (" + root.faceReason + ")" : ""));
        } else if (a === "idle" && (root.lockState.face === "absent" || root.lockState.face === "misconfigured")) {
            root._setFace("idle", "");
        }
        root.requestFace(false);
    }
    onFaceAvailabilityChanged: root._syncAvailability()
    onSecureChanged: root._syncAvailability()

    // The first character into an empty field: someone is at the keyboard, which
    // is the lock's best sign that they want to unlock. Scan when the face is
    // waiting (never started, failed, too dark, camera busy); nothing while it
    // scans, has won, or is not there.
    function _typingFace() {
        const f = root.lockState ? root.lockState.face : "";
        if (f === "idle" || f === "failed" || f === "dark" || f === "busy"
            || (f === "unavailable" && root.lockState.faceReason === "camera"))
            root.requestFace(true);
    }
    // The machine is back from sleep: whoever is there now is not who locked it.
    function resumed() {
        root._resumeRetry = true;
        root.requestFace(true);
        // no scan started or is on its way (the face is not usable now): nothing is waited for
        if (!face.active && !faceTimer.running)
            root._resumeRetry = false;
    }

    Connections {
        target: root.awake
        function onWoke() {
            if (!root.faceOnReturn)
                return;
            // The first input after the lock rested starts the face; later ones
            // re-arm a scan that did not win.
            const f = root.lockState ? root.lockState.face : "";
            if (!root._faceArmed || f === "failed" || f === "dark" || f === "unavailable")
                root.requestFace(true);
        }
    }

    // Start listening for the password at once: Enter always has a prompt.
    function begin() {
        if (root.faceAtStart)
            root._faceArmed = true;
        root._syncAvailability();
        root._startPassword();
    }
}
