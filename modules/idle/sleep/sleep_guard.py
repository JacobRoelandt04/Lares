#!/usr/bin/env python3
# =============================================================================
# sleep_guard.py -- the sleep fade's watchdog for a suspend that never happens (SleepFade.qml; docs/idle.md).
#
# The machine's known freeze is a hang while ENTERING suspend (the NVIDIA driver's suspend notifier): logind and user space still run,
# the kernel has switched to its suspend console, and the panel the fade put at 0 would stay black over a stuck machine. This process
# gives the light back then.
#
#   started by the shell at the FALL, before the inhibitor is released (nothing is started in the suspend-entry window)
#   reads CLOCK_BOOTTIME - CLOCK_MONOTONIC (it grows only while the machine really sleeps), says "armed <offset>"
#   waits for one line on stdin: "go" = the shell released the inhibitor; EOF = the shell is gone (the same thing: its holder died too)
#   sleeps `stuck` seconds on the MONOTONIC clock (time.sleep: it stops while the machine sleeps)
#   reads the offset again: did not grow by a second -> "stuck" (no sleep happened); grew -> "slept" (it did, and nobody killed this
#   process at the resume: the resume was missed or the shell is dead)
#   either way: the panel still reads 0 (the fade's 0) -> the saved level is written back, at once; anything else is somebody's (a key)
#   and is left alone. One line "<verdict> restored <n>" | "<verdict> kept <v>" | "<verdict> fail", then it exits.
#
# The shell kills it at every resume. It carries NO pdeathsig on purpose: a guard whose shell died still does its one check and exits.
# It writes ONE device, by name (the one the shell hands it: PanelBacklight's, the backlight of the GPU that drives the eDP -- never a
# stray nvidia_0 in Hybrid, never /proc/driver/nvidia), through the brightnessctl it is handed, once at most.
#
# Arguments, key=value: brightnessctl=<prog> device=<name> saved=<raw> stuck=<s> [clock=<file>]
#   clock=<file>   a probe's stand-in for the two clocks: the file holds the offset (boottime - monotonic, seconds), read at both ends
# =============================================================================
import subprocess
import sys
import time


def main() -> int:
    a = {}
    for arg in sys.argv[1:]:
        k, _, v = arg.partition("=")
        a[k] = v
    bctl = a.get("brightnessctl", "brightnessctl")
    dev = a.get("device", "")
    saved = int(a.get("saved", "-1"))
    stuck = float(a.get("stuck", "20"))
    clock = a.get("clock", "")
    if not dev or saved < 1:
        print("nothing", flush=True)
        return 0

    def offset() -> float:
        if clock:
            with open(clock) as f:
                return float(f.read().split()[0])
        return time.clock_gettime(time.CLOCK_BOOTTIME) - time.clock_gettime(time.CLOCK_MONOTONIC)

    o0 = offset()
    print("armed %.3f" % o0, flush=True)
    sys.stdin.readline()
    print("go", flush=True)
    time.sleep(stuck)
    verdict = "stuck" if offset() - o0 < 1.0 else "slept"
    base = [bctl, "-c", "backlight", "-d", dev]
    try:
        cur = subprocess.run(base + ["g"], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        print(verdict + " fail", flush=True)
        return 0
    if cur != "0":
        print("%s kept %s" % (verdict, cur or "?"), flush=True)
        return 0
    try:
        ok = subprocess.run(base + ["set", str(saved)], capture_output=True, timeout=5).returncode == 0
    except (OSError, subprocess.SubprocessError):
        ok = False
    print("%s restored %d" % (verdict, saved) if ok else verdict + " fail", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
