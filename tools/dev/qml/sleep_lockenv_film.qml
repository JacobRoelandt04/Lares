//@ pragma UseQApplication
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "modules/common/components"
import "modules/lockscreen"
import "modules/idle/sleep"

// =============================================================================
// sleep_lockenv_film.qml -- the REAL sleep fade and its REAL veil windows over a REAL lock, in tools/dev/lock_env.sh: run only by
// tools/dev/sleep_lockenv_film.sh. Nothing of the sequence is a mockup -- SleepFade, SleepVeils / SleepVeil (lares-bar Overlay windows that
// capture their output) and a LockOwner that mirrors the lock process over its socket, as the shell holds them -- only the machine is
// stood in for: a stand-in logind on the env's private bus (tools/dev/fixtures/sleep/fake_logind.py, a 5 s cap as the user's),
// systemd-inhibit and brightnessctl stubs over a fake sysfs (SLEEPFILM_DIR), a file for the guard's clocks. The env's output LOCK-1 is
// "the panel".
//
// SEVERAL SLEEPS IN ONE PROCESS (SLEEPFILM_CYCLES, default 2): the shell lives through many sleeps, and what a fade leaves behind in the
// process is only seen by the next one. Between two sleeps the runner unlocks (the PAM stub's password) and the next sleep comes once the
// lock is gone, as the user's next suspend does.
//
// The timeline, said on stdout for the runner (which starts the lock when it reads `sleep`, as hypridle's before_sleep_cmd does, films
// the output with grim throughout, and unlocks after `rest`); <i> is the sleep's number from 1:
//   SLEEPFILM held 0 <ms>        the inhibitor is held
//   SLEEPFILM sleep <i> <ms>     the stand-in logind said PrepareForSleep(true)
//   SLEEPFILM fallclock <i> <ms> <fallMs>   the fall's clock started (progress leaves 0), and how long it runs
//   SLEEPFILM asleep <i> <ms>    the fade released the inhibitor (the machine would sleep now)
//   SLEEPFILM wake <i> <ms>      1.5 s later, PrepareForSleep(false) (the stub panel was relit to 400 first, as the kernel may)
//   SLEEPFILM rise <i> <ms> <climbMs>       the climb's clock started
//   SLEEPFILM p <i> <ms> <progress>          every value of the clock while it falls or climbs
//   SLEEPFILM rest <i> <ms>      the light is back
//   SLEEPFILM unlocked <i> <ms>  the lock has gone (the next sleep follows 1 s later)
//   SLEEPFILM RESULT PASS|FAIL   with the fade's own log before it (`SLEEPFILM log ...`)
// SLEEPFILM_NOLOCK=1: no lock comes; the run ends at the first rest.
// INERT OUTSIDE THE ENV: without LOCK_ENV_DIR and the stubs' dir nothing runs -- above all no LockOwner, whose server would take the
// lock socket of the user's own shell in their runtime dir -- and it says SKIP and quits.
// =============================================================================
ShellRoot {
    id: root

    readonly property string fx: Quickshell.env("SLEEPFILM_FX") || ""
    readonly property string dir: Quickshell.env("SLEEPFILM_DIR") || ""
    readonly property int cycles: Math.max(1, parseInt(Quickshell.env("SLEEPFILM_CYCLES") || "2"))
    // no lock comes (the runner's STILL mode): the run ends at the first rest
    readonly property bool nolock: Quickshell.env("SLEEPFILM_NOLOCK") === "1"
    readonly property bool armed: (Quickshell.env("LOCK_ENV_DIR") || "") !== "" && root.fx !== "" && root.dir !== ""
    Timer {
        interval: 0
        running: !root.armed
        onTriggered: {
            console.log("SLEEPFILM not armed -- tools/dev/sleep_lockenv_film.sh runs it inside tools/dev/lock_env.sh");
            console.log("SLEEPFILM RESULT SKIP");
            Qt.quit();
        }
    }
    property bool simReady: false
    // "start" | "held" | "sleep" | "asleep" | "wake" | "rest" | "next"
    property string stage: "start"
    property int cycle: 0

    function say(what: string, extra: string): void {
        console.log("SLEEPFILM " + what + " " + root.cycle + " " + Date.now() + (extra !== "" ? " " + extra : ""));
    }

    Process {
        id: sim
        command: ["python3", root.fx + "/fake_logind.py"]
        running: root.armed
        stdinEnabled: true
        stdout: SplitParser {
            onRead: data => {
                if (String(data).indexOf("READY") >= 0)
                    root.simReady = true;
            }
        }
    }
    SleepWatcher {
        id: logindWatcher
        enabled: root.simReady
        bus: "session"
    }
    LockOwner {
        id: owner
        listen: root.armed
        onLockedChanged: {
            if (!owner.locked && root.stage === "rest") {
                root.stage = "next";
                root.say("unlocked", "");
                if (root.cycle < root.cycles)
                    goPoll.start();
                else
                    endT.start();
            }
        }
    }
    SleepFade {
        id: fade
        live: root.armed
        windows: root.armed
        watcher: logindWatcher
        lock: owner
        settings: ({ sleepFade: true, sleepFadeTimeS: parseFloat(Quickshell.env("SLEEPFILM_TIME") || "1.5"),
            sleepFadeStrength: parseFloat(Quickshell.env("SLEEPFILM_STRENGTH") || "1"), panel: "LOCK", brightnessctl: root.fx + "/brightnessctl" })
        inhibitCommand: [root.fx + "/systemd-inhibit", "--what=sleep", "--mode=delay", "--who=lares", "--why=film",
            "setpriv", "--pdeathsig", "TERM", "--", "sh", "-c", "echo held; exec sleep infinity"]
        capCommand: ["busctl", "--user", "get-property", "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "InhibitDelayMaxUSec"]
        recordFile: root.dir + "/record.json"
        campaignFile: root.dir + "/campaign.json"
        guardClock: root.dir + "/clock"
        property bool _fallSaid: false
        onProgressChanged: {
            // the clock as it really ran (a stall during the climb is taken out of it): the film reads a frame's progress here
            if (fade.phase === "falling" || fade.phase === "rising")
                console.log("SLEEPFILM p " + root.cycle + " " + Date.now() + " " + fade.progress.toFixed(4));
            if (fade.phase === "falling" && !fade._fallSaid && fade.progress > 0) {
                fade._fallSaid = true;
                root.say("fallclock", String(fade.fallMs));
            }
        }
        onPhaseChanged: {
            if (fade.phase === "falling")
                fade._fallSaid = false;
            if (fade.phase === "rising")
                root.say("rise", String(fade.climbMs));
            if (fade.phase === "asleep" && root.stage === "sleep") {
                root.stage = "asleep";
                root.say("asleep", "");
                wakeT.start();
            } else if (fade.phase === "rest" && root.stage === "wake") {
                root.stage = "rest";
                root.say("rest", "");
                if (root.nolock)
                    endT.start();
            }
        }
        onHeldChanged: {
            if (fade.held && root.stage === "start") {
                root.stage = "held";
                root.say("held", "");
                sleepT.start();
            }
        }
    }
    Process {
        id: relight
    }
    // the next sleep once the runner says its lock's supervisor is gone (SLEEPFILM_DIR/go<i>)
    Timer {
        id: goPoll
        interval: 200
        repeat: true
        onTriggered: {
            if (!goCheck.running) {
                goCheck.command = ["test", "-e", root.dir + "/go" + (root.cycle + 1)];
                goCheck.running = true;
            }
        }
    }
    Process {
        id: goCheck
        onExited: code => {
            if (code === 0 && goPoll.running) {
                goPoll.stop();
                sleepT.start();
            }
        }
    }
    Timer {
        id: sleepT
        interval: 1000
        onTriggered: {
            root.cycle++;
            root.stage = "sleep";
            sim.write("sleep\n");
            root.say("sleep", "");
        }
    }
    Timer {
        id: wakeT
        interval: 1500
        onTriggered: {
            relight.command = ["sh", "-c", "echo 400 > \"$1\"", "relight", root.dir + "/sys/intel_backlight/brightness"];
            relight.running = true;
            root.stage = "wake";
            sim.write("wake\n");
            root.say("wake", "");
        }
    }
    Timer {
        id: endT
        interval: 500
        onTriggered: {
            const ev = fade.log.map(e => e.event + (e.result !== undefined ? ":" + e.result : "")).join(" ");
            console.log("SLEEPFILM log " + ev);
            const rel = fade.log.filter(e => e.event === "release").length;
            const rest = fade.log.filter(e => e.event === "rest").length;
            console.log("SLEEPFILM RESULT " + (rel >= root.cycles && rest >= root.cycles ? "PASS" : "FAIL") + " (" + rel + " releases, " + rest + " rests)");
            sim.write("quit\n");
            quitT.start();
        }
    }
    Timer {
        id: quitT
        interval: 200
        onTriggered: Qt.quit()
    }
    Timer {
        interval: 40000 * root.cycles
        running: root.armed
        onTriggered: {
            console.log("SLEEPFILM RESULT FAIL (stuck at " + root.stage + " of sleep " + root.cycle + ", phase " + fade.phase + ")");
            Qt.quit();
        }
    }
}
