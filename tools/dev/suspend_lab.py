#!/usr/bin/env python3
"""suspend_lab.py -- does this machine suspend, and does everything come back? THE USER runs its tests, in a terminal of his; an agent reads
the records and never runs one (the tests refuse without a terminal).

    tools/dev/suspend_lab.py check                          what this machine can do and what is known to be in the way; reads only
    tools/dev/suspend_lab.py stage <name> [--without MOD]   one rehearsal by the kernel itself (/sys/power/pm_test): it goes as far as <name>,
                                                            waits 5 s and comes back; the machine never really sleeps
                                                            freezer < devices < platform < processors < core
    tools/dev/suspend_lab.py ladder [--without MOD]         those five in that order, ending at the first that fails
    tools/dev/suspend_lab.py sleep [SECONDS] [--without MOD]  the real thing: `systemctl suspend` (the lock, the hooks), woken by the
                                                            computer's clock after SECONDS (60; 30 .. 900)
    tools/dev/suspend_lab.py report [N]                     the last N records (10)
    tools/dev/suspend_lab.py history [DAYS]                 every suspend the journal holds (60 days)

--without MOD   the kernel module MOD is unloaded for the test and loaded again after it (a driver that refuses to suspend).

Root is asked for by `sudo` in that terminal: the kernel's test switch, its sleep file, the clock's alarm and the modules. The test switch is
put back whatever happens (left on, every later suspend would be a rehearsal). Every test is one directory,
~/.local/state/lares/suspend-lab/<time>-<test>/: before.json, after.json, kernel.log, system.log, result.json. A test that never came back has
no result; the next command finds it, files the kernel's last lines of that boot with it and says so.

Exit status: 0 the test passed (or a reading command), 1 it did not, 2 refused or bad arguments.
LARES_LAB_SYS (a fake /sys) and LARES_LAB_BIN (the only directory programs are taken from) are a test's: tools/dev/suspend_lab_cases.py.
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

SYS = os.environ.get("LARES_LAB_SYS", "/sys")
BIN = os.environ.get("LARES_LAB_BIN", "")
STAGES = ["freezer", "devices", "platform", "processors", "core"]
STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "lares", "suspend-lab")
SLEEP_LOG = ["systemd", "systemd-sleep", "systemd-logind", "nvidia-sleep.sh", "NetworkManager", "hypridle", "bluetoothd", "rtkit-daemon"]


# ---------------------------------------------------------------------------------------------------------------- reading
def read(path, default=""):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return default


def sysf(path):
    return read(os.path.join(SYS, path))


def program(name):
    return (os.path.join(BIN, name) if os.access(os.path.join(BIN, name), os.X_OK) else None) if BIN else shutil.which(name)


def run(*argv, timeout=20):
    """-> stdout ("" when the program is not there, fails to start or takes too long)"""
    p = program(argv[0])
    if not p:
        return ""
    try:
        return subprocess.run([p] + list(argv[1:]), stdin=subprocess.DEVNULL, capture_output=True, text=True, errors="replace", timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def jload(text):
    try:
        return json.loads(text)
    except ValueError:
        return None


def boot_id():
    return os.environ.get("LARES_LAB_BOOT") or read("/proc/sys/kernel/random/boot_id")


def asleep_clock():
    """Seconds this boot has spent asleep: CLOCK_BOOTTIME counts them, CLOCK_MONOTONIC does not."""
    return time.clock_gettime(time.CLOCK_BOOTTIME) - time.clock_gettime(time.CLOCK_MONOTONIC)


def wake_sources():
    out = {}
    for d in glob.glob(os.path.join(SYS, "class/wakeup/wakeup*")):
        dev = os.path.basename(os.path.realpath(os.path.join(d, "device")))
        key = "%s (%s)" % (read(os.path.join(d, "name")), dev)
        out[key] = out.get(key, 0) + int(read(os.path.join(d, "event_count"), "0") or 0)
    return out


def spd_bound():
    return sorted(os.path.basename(p) for p in glob.glob(os.path.join(SYS, "bus/i2c/drivers/spd5118/[0-9]*")))


def snapshot():
    stats = {k: sysf("power/suspend_stats/" + k) for k in ("success", "fail", "last_failed_dev", "last_failed_errno", "last_failed_step")}
    mons = jload(run("hyprctl", "-j", "monitors")) or []
    routes = jload(run("ip", "-j", "route", "show", "default")) or []
    failed = []
    for scope in ([], ["--user"]):
        failed += [l.split()[0] for l in run("systemctl", *scope, "--failed", "--plain", "--no-legend").splitlines() if l.strip()]
    return {
        "time": time.time(), "boot": boot_id(), "asleep": asleep_clock(), "kernel": os.uname().release,
        "mem_sleep": sysf("power/mem_sleep"), "pm_test": sysf("power/pm_test"), "stats": stats, "wake": wake_sources(),
        "spd5118": spd_bound(), "openrgb": bool(run("pgrep", "-x", "openrgb").strip()),
        "gpu": run("nvidia-smi", "--query-gpu=driver_version,pstate,power.draw,memory.used", "--format=csv,noheader").strip(),
        "outputs": [{k: m.get(k) for k in ("name", "width", "height", "refreshRate", "dpmsStatus")} for m in mons if isinstance(m, dict)],
        "routes": sorted(r.get("dev", "") for r in routes if isinstance(r, dict)),
        "sink": next((l.split('"')[1] for l in run("wpctl", "inspect", "@DEFAULT_AUDIO_SINK@").splitlines() if "node.name" in l and '"' in l), ""),
        "usb": sorted(filter(None, (read(p) for p in glob.glob(os.path.join(SYS, "bus/usb/devices/*/product"))))),
        "failed": sorted(failed),
        "shell": run("lares", "status").strip()[:2000],
    }


def kernel_since(t, boot=""):
    return run("journalctl", "--no-pager", "-o", "short-precise", *(["-b", boot] if boot else ["-b"]), "_TRANSPORT=kernel",
               "--since", "@%d" % int(t), timeout=60)


# ---------------------------------------------------------------------------------------------------------------- the verdict
def judge(lines, test, rc=0, asleep=0.0):
    """What the kernel's lines say about one test. lines: text; test: a stage's name or "sleep"; rc: the write into /sys/power/state
    (None where nobody knows); asleep: seconds the machine was really asleep. -> {verdict, ok, why, refused, resume, nvidia, slow, next}"""
    L = lines.splitlines()
    entry = any("PM: suspend entry" in x for x in L)
    left = any("PM: suspend exit" in x for x in L)
    s3 = next((m.group(1) for x in L for m in [re.search(r"Waking up from system sleep state (S\d)", x)] if m), "")
    refused, resume, slow = [], [], []
    for x in L:
        m = re.search(r"(\S+): PM: failed to (suspend|resume)[a-z ]*: error (-?\d+)", x)
        if m:
            (refused if m.group(2) == "suspend" else resume).append("%s (error %s)" % (m.group(1), m.group(3)))
        m = re.search(r"PM: (\S+?)(?:\+\S+)? (?:\[\S+\] )?returned (-?\d+) after (\d+) usecs", x)
        if m and int(m.group(3)) >= 300000:
            slow.append((int(m.group(3)) // 1000, (re.search(r"kernel: (?:\S+ )?(\S+): PM: ", x) or re.match("()", "")).group(1) + " " + m.group(1)))
    calls = sorted({m.group(1) for x in L for m in [re.search(r"dpm_run_callback\(\): (\S+?)(?:\+\S+)? (?:\[\S+\] )?returns -\d+", x)] if m})
    frozen = next((x.split("kernel: ", 1)[-1] for x in L if re.search(r"Freezing (user space|remaining)[^:]*failed", x)), "")
    nvidia = [x.split("kernel: ", 1)[-1] for x in L if re.search(r"NVRM:.*(Xid|fail|error|timeout|assert)|nvidia-modeset: (ERROR|WARNING)|\[drm:nv_drm.*\*ERROR", x, re.I)]
    r = {"test": test, "refused": sorted(set(refused)), "resume": sorted(set(resume)), "calls": calls, "nvidia": nvidia[:12],
         "slow": ["%s ms %s" % s for s in sorted(slow, reverse=True)[:6]], "asleep": round(asleep, 1), "state": s3, "rc": rc, "next": ""}
    blocked = refused or frozen or any("PM: Some devices failed to suspend" in x for x in L) or (test in STAGES and rc not in (0, None))

    def say(verdict, ok, why):
        r.update(verdict=verdict, ok=ok, why=why)
        return r
    if not entry:
        return say("NOT TRIED", False, "the kernel logged no suspend" + (" (the write was refused, status %s)" % rc if rc else ""))
    if blocked:
        if r["refused"] and all(re.match(r"\d+-00[0-9a-f]{2} ", d) for d in r["refused"]) and any("spd5118" in c for c in calls + [lines]):
            r["next"] = "the memory's temperature sensors (spd5118) refused: the same test with --without spd5118"
        return say("REFUSED", False, "refused by " + ", ".join(r["refused"]) if r["refused"] else (frozen or "the kernel gave up (status %s)" % rc))
    if not left:
        return say("NO END", False, "it went in and the kernel never logged that it came out")
    if test == "sleep" and not s3 and asleep < 5:
        return say("DID NOT SLEEP", False, "it went in and came out at once (asleep %.1f s): something woke it, or a test switch is on" % asleep)
    if resume or nvidia:
        return say("BACK WITH ERRORS", False, "; ".join((["did not resume: " + ", ".join(r["resume"])] if resume else []) +
                                                       (["the NVIDIA driver complained %d times" % len(nvidia)] if nvidia else [])))
    return say("PASS", True, "asleep %.0f s in %s and back, no driver complained" % (asleep, s3 or "?") if test == "sleep" else "it got that far and came back, no driver complained")


def changes(a, b):
    """What is not as it was: [sentence]"""
    out = []
    if a.get("boot") != b.get("boot"):
        out.append("another boot")
    for k, what in (("outputs", "the displays"), ("routes", "the network's way out"), ("sink", "the sound output"), ("failed", "the failed units"), ("usb", "the USB devices")):
        if a.get(k) != b.get(k):
            out.append("%s: %s -> %s" % (what, json.dumps(a.get(k)), json.dumps(b.get(k))))
    return out


def woke(a, b):
    return sorted((k for k, n in b.get("wake", {}).items() if n > a.get("wake", {}).get(k, 0)), key=lambda k: a.get("wake", {}).get(k, 0) - b["wake"][k])


# ---------------------------------------------------------------------------------------------------------------- the records
def save(d, name, data):
    path = os.path.join(d, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(data if isinstance(data, str) else json.dumps(data, indent=1, sort_keys=True) + "\n")
        f.flush()
        os.fsync(f.fileno())


def records():
    return sorted(d for d in glob.glob(os.path.join(STATE, "*-*")) if os.path.isfile(os.path.join(d, "before.json")))


def settle():
    """A test with no result: the machine never came back from it (another boot since), or it was cut short. Said once, filed for ever."""
    for d in records():
        if os.path.exists(os.path.join(d, "result.json")):
            continue
        a = jload(read(os.path.join(d, "before.json"))) or {}
        if a.get("boot") == boot_id():
            pid = read(os.path.join(d, "pid"))
            if pid.isdigit() and os.path.exists("/proc/" + pid):
                continue
            save(d, "result.json", {"test": a.get("test", "?"), "verdict": "CUT SHORT", "ok": False, "why": "the lab was stopped before the test ended"})
        else:
            log = kernel_since(a.get("time", 0), a.get("boot", "").replace("-", ""))
            save(d, "kernel.log", log)
            last = log.strip().splitlines()[-1].split("kernel: ", 1)[-1] if log.strip() else "nothing"
            save(d, "result.json", {"test": a.get("test", "?"), "verdict": "NEVER CAME BACK", "ok": False,
                                    "why": "the machine was started anew; the kernel's last line of that boot: " + last})
        r = jload(read(os.path.join(d, "result.json")))
        print("  ! %s: %s (%s)" % (os.path.basename(d), r["verdict"], r["why"]))


# ---------------------------------------------------------------------------------------------------------------- the tests
def refuse(why):
    print("suspend_lab: " + why, file=sys.stderr)
    return 2


def in_the_way():
    out = []
    if os.path.exists(os.environ.get("LARES_LAB_PACMAN", "/var/lib/pacman/db.lck")):
        out.append("a package transaction holds pacman's lock")
    for i in jload(run("systemd-inhibit", "--list", "--json=short")) or []:
        if i.get("mode") == "block" and "sleep" in i.get("what", "").split(":"):
            out.append("%s blocks sleep (%s): the idle mode `hard`, or a system update" % (i.get("who"), i.get("why")))
    return out


def sh(path):
    return "'" + path.replace("'", "'\\''") + "'"


def root_script(body, without):
    """The shell script sudo runs. It puts back the test switch, the kernel's log switches and the modules on ANY way out."""
    P = os.path.join(SYS, "power")
    keep = ["pm_test", "pm_print_times", "pm_debug_messages"]
    s = ["set -u", "restore() {", "  trap - EXIT INT TERM HUP",
         "  echo none > %s" % sh(P + "/pm_test")]
    s += ["  echo 0 > %s" % sh(P + "/" + k) for k in keep[1:]]
    s += ["  modprobe %s" % m for m in reversed(without)]
    s += ["}", "trap restore EXIT", "trap 'exit 130' INT TERM HUP"]
    s += ["modprobe -r %s || exit 41" % m for m in without]
    s += ["echo 1 > %s" % sh(P + "/" + k) for k in keep[1:]]
    return "\n".join(s + body) + "\n"


def loaded(mods):
    """Of these modules the ones that are in the kernel: only those are taken out, and only those are put back."""
    return [m for m in mods if os.path.isdir(os.path.join(SYS, "module", m.replace("-", "_")))]


def sudo(script):
    p = program("sudo")
    if not p:
        return 127
    return subprocess.run([p, "sh", "-c", script]).returncode


def begin(test, without):
    d = os.path.join(STATE, time.strftime("%Y%m%d-%H%M%S") + "-" + test + ("".join("-no-" + m for m in without)))
    os.makedirs(d)
    a = snapshot()
    a.update(test=test, without=without)
    save(d, "pid", str(os.getpid()))
    save(d, "before.json", a)
    os.sync()
    return d, a


def finish(d, a, test, rc):
    time.sleep(0 if BIN else 4)      # what the resume brings back a moment later (the network, USB) is part of it
    b = snapshot()
    asleep = b["asleep"] - a["asleep"]
    log = kernel_since(a["time"] - 1)
    save(d, "kernel.log", log)
    save(d, "system.log", run("journalctl", "--no-pager", "-o", "short-precise", "-b", "--since", "@%d" % int(a["time"] - 1),
                              *[x for i in SLEEP_LOG for x in ("-t", i)], timeout=60))
    save(d, "after.json", b)
    r = judge(log, test, rc, asleep)
    r.update(changes=changes(a, b), woke=woke(a, b), without=a["without"], kernel=a["kernel"], took=round(b["time"] - a["time"], 1))
    return r


def ask(d, r):
    try:
        r["note"] = input("  Anything odd (picture, sound, keyboard, mouse, network)? Enter for no, else a few words: ").strip()
    except (EOFError, KeyboardInterrupt):
        r["note"] = "(not answered)"
    save(d, "result.json", r)


def show(r, d):
    print("  %s: %s" % (r["verdict"], r["why"]))
    for k, what in (("calls", "refusing calls"), ("slow", "slow"), ("nvidia", "NVIDIA"), ("woke", "woken by"), ("changes", "not as it was")):
        for x in r.get(k) or []:
            print("    %s: %s" % (what, x))
    if r.get("next"):
        print("  next: " + r["next"])
    print("  record: " + d)


def rehearse(stage, without):
    print("\n%s%s: the screen may go black for some seconds; the machine does not sleep." % (stage, " without " + ", ".join(without) if without else ""))
    d, a = begin(stage, without)
    P = os.path.join(SYS, "power")
    rc = sudo(root_script(["echo %s > %s || exit 42" % (stage, sh(P + "/pm_test")), "sync", "echo mem > %s" % sh(P + "/state")], loaded(without)))
    r = finish(d, a, stage, rc)
    if rc == 41:
        r.update(verdict="NOT TRIED", ok=False, why="a module of --without could not be unloaded")
    elif rc == 42:
        r.update(verdict="NOT TRIED", ok=False, why="this kernel has no such rehearsal (%s)" % sysf("power/pm_test"))
    show(r, d)
    ask(d, r)
    return r["ok"]


def sleep(seconds, without):
    print("\nThe real thing: the machine locks, sleeps, and its clock wakes it after %d s. If it does not wake: the keyboard, then the power button "
          "(a short press). If nothing answers after a minute, hold the power button; the next `check` files what the kernel last said." % seconds)
    d, a = begin("sleep", without)
    without = loaded(without)
    alarm = os.path.join(SYS, "class/rtc/rtc0/wakealarm")
    # the modules stay out until the machine is back: the root half is two scripts, so the first must not put anything back
    pre = ["modprobe -r %s || exit 41" % m for m in without] + ["echo none > %s" % sh(SYS + "/power/pm_test"),
           "echo 1 > %s" % sh(SYS + "/power/pm_print_times"), "echo 1 > %s" % sh(SYS + "/power/pm_debug_messages"), "sync",
           "echo 0 > %s" % sh(alarm), "echo +%d > %s || exit 43" % (seconds, sh(alarm))]
    rc = sudo("set -u\n" + "\n".join(pre) + "\n")
    if rc == 0:
        subprocess.run([program("systemctl") or "systemctl", "suspend"], stdin=subprocess.DEVNULL)
        end = time.monotonic() + (3 if BIN else 180)
        while time.monotonic() < end:
            time.sleep(1)
            if "Operation 'suspend' finished" in run("journalctl", "--no-pager", "-b", "-o", "cat", "-t", "systemd-logind", "--since", "@%d" % int(a["time"])):
                break
    r = finish(d, a, "sleep", None)
    if rc:
        r.update(verdict="NOT TRIED", ok=False, why={41: "a module of --without could not be unloaded", 43: "the clock took no alarm"}.get(rc, "sudo ended with %d" % rc))
    show(r, d)
    print("  Putting the switches%s back (sudo may ask again)." % (" and the modules" if without else ""))
    sudo("\n".join(["echo 0 > %s" % sh(alarm), "echo none > %s" % sh(SYS + "/power/pm_test"), "echo 0 > %s" % sh(SYS + "/power/pm_print_times"),
                    "echo 0 > %s" % sh(SYS + "/power/pm_debug_messages")] + ["modprobe %s" % m for m in reversed(without)]) + "\n")
    ask(d, r)
    return r["ok"]


# ---------------------------------------------------------------------------------------------------------------- the commands
def check():
    print("sleep states   %s   (mem is: %s)" % (sysf("power/state") or "?", sysf("power/mem_sleep") or "?"))
    print("systemd        CanSuspend %s, CanHibernate %s" % tuple(
        (run("busctl", "call", "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", m).split() or ["?"])[-1].strip('"')
        for m in ("CanSuspend", "CanHibernate")))
    print("rehearsals     %s" % (sysf("power/pm_test") or "this kernel has none (no CONFIG_PM_DEBUG)"))
    if sysf("power/pm_test") and "[none]" not in sysf("power/pm_test"):
        print("  ! the test switch is ON: every suspend is a rehearsal. `echo none | sudo tee /sys/power/pm_test`")
    s = {k: sysf("power/suspend_stats/" + k) for k in ("success", "fail", "last_failed_dev", "last_failed_step")}
    print("this boot      %s worked, %s failed%s" % (s["success"], s["fail"], " (last: %s at %s)" % (s["last_failed_dev"], s["last_failed_step"]) if s["last_failed_dev"] else ""))
    spd = spd_bound()
    if spd:
        print("  ! spd5118 holds the memory's temperature sensors (%s): on some boards it refuses every suspend. Test with --without spd5118" % ", ".join(spd))
    nv = read("/proc/driver/nvidia/params") if not BIN else ""
    if nv:
        want = ("PreserveVideoMemoryAllocations", "UseKernelSuspendNotifiers", "TemporaryFilePath")
        print("NVIDIA         " + ", ".join(l for l in nv.splitlines() if l.split(":")[0] in want))
    armed = [os.path.basename(os.path.dirname(os.path.dirname(p))) for p in glob.glob(os.path.join(SYS, "bus/usb/devices/*/power/wakeup")) if read(p) == "enabled"]
    names = [read(os.path.join(SYS, "bus/usb/devices", a, "product")) or a for a in sorted(armed)]
    print("USB can wake it  " + (", ".join(n for n in names if "ontroller" not in n) or "none"))
    for w in in_the_way():
        print("  ! " + w)
    settle()
    print("\nThe order: `stage devices`, then `ladder` (with --without for what refused), then `sleep`.")
    return 0


def report(n):
    settle()
    for d in records()[-n:]:
        r = jload(read(os.path.join(d, "result.json"))) or {}
        print("%-44s %-16s %s%s" % (os.path.basename(d), r.get("verdict", "running"), r.get("why", ""), "  [%s]" % r["note"] if r.get("note") else ""))
    if not records():
        print("no test yet (%s)" % STATE)
    return 0


def history(days):
    ev = []
    for l in run("journalctl", "--no-pager", "-o", "json", "_TRANSPORT=kernel", "--since", "-%dd" % days, "--output-fields=MESSAGE,_BOOT_ID",
                 "--grep", r"PM: suspend (entry|exit)|PM: failed to (suspend|resume)|Waking up from system sleep state", timeout=300).splitlines():
        m = jload(l)
        if m and isinstance(m.get("MESSAGE"), str):
            ev.append((int(m["__REALTIME_TIMESTAMP"]) / 1e6, m["_BOOT_ID"], m["MESSAGE"]))
    cur, n = None, 0

    def out():
        nonlocal n
        n += 1
        r = judge("\n".join(cur["l"]), "sleep", None, 0)
        print("%s  %-8s %-14s %s" % (time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(cur["t"])), cur["l"][0].split("(")[-1].strip(")"),
                                     "SLEPT" if r["state"] and not r["resume"] else "SLEPT, ERRORS" if r["state"] else r["verdict"], ", ".join(r["refused"] + r["resume"])))
    for t, b, m in ev:
        if "suspend entry" in m:
            if cur:
                out()
            cur = {"t": t, "b": b, "l": [m]}
        elif cur and cur["b"] == b:
            cur["l"].append(m)
            if "suspend exit" in m:
                out()
                cur = None
    if cur:
        out()
    print("%d in %d days" % (n, days))
    return 0


def main(argv):
    without, args, i = [], [], 0
    while i < len(argv):
        if argv[i] == "--without":
            if i + 1 >= len(argv) or not re.fullmatch(r"[A-Za-z0-9_-]+", argv[i + 1]):
                return refuse("--without names a kernel module")
            without.append(argv[i + 1])
            i += 1
        else:
            args.append(argv[i])
        i += 1
    cmd, rest = (args[0] if args else ""), args[1:]
    num = int(rest[0]) if rest and rest[0].isdigit() else None
    if cmd == "check" and not rest:
        return check()
    if cmd == "report" and (not rest or num):
        return report(num or 10)
    if cmd == "history" and (not rest or num):
        return history(num or 60)
    ok = (cmd == "stage" and len(rest) == 1 and rest[0] in STAGES) or (cmd == "ladder" and not rest) or (cmd == "sleep" and (not rest or (num and 30 <= num <= 900)))
    if not ok:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        return refuse("a test is started by a person, from a terminal")
    if os.geteuid() == 0:
        return refuse("run it as yourself; it asks for root where it needs it")
    way = in_the_way()
    if way:
        return refuse("not now: " + "; ".join(way))
    if "mem" not in sysf("power/state").split():
        return refuse("this kernel offers no suspend (%s)" % (sysf("power/state") or "nothing"))
    os.makedirs(STATE, exist_ok=True)
    settle()
    if cmd == "sleep":
        return 0 if sleep(num or 60, without) else 1
    for s in ([rest[0]] if cmd == "stage" else STAGES):
        if not rehearse(s, without):
            return 1
    if cmd == "ladder":
        print("\nAll five passed. Next: `suspend_lab.py sleep%s`" % "".join(" --without " + m for m in without))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        print()
        sys.exit(130)
