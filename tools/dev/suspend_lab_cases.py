#!/usr/bin/env python3
"""suspend_lab_cases.py -- the suspend lab (tools/dev/suspend_lab.py) on captured kernel lines and on a fake /sys with stub programs. Nothing here
can reach the machine: the lab runs in a copy, takes programs from the stubs' directory only (LARES_LAB_BIN) and writes under a fake /sys
(LARES_LAB_SYS).

    python3 -B tools/dev/suspend_lab_cases.py          must end SUSPEND_LAB RESULT PASS
    ARM=all python3 -B tools/dev/suspend_lab_cases.py  every ARM must turn its own check red -> SUSPEND_LAB ARMS PASS
      notty        a test is started without a terminal
      norestore    the kernel's test switch is left on after a test
      noreload     a module taken out for a test is not loaded again
      anyload      a module that was not in the kernel is loaded after the test
      blindrefuse  a driver's refusal is not seen
      nopending    a test the machine never came back from is not filed
      noinhibit    an inhibitor that blocks sleep is not looked at

The fixtures (tools/dev/fixtures/suspend/) are the desktop's own journal; a rehearsal's lines are the kernel's source (kernel/power/suspend.c),
no capture of one exists yet.
"""
import json
import os
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "suspend_lab.py")
FIX = os.path.join(HERE, "fixtures", "suspend")

ARMS = {
    "notty": [("    if not (sys.stdin.isatty() and sys.stdout.isatty()):\n", "    if False:\n")],
    "norestore": [('"trap restore EXIT", ', "")],
    "noreload": [('    s += ["  modprobe %s" % m for m in reversed(without)]\n', "")],
    "anyload": [('    return [m for m in mods if os.path.isdir(os.path.join(SYS, "module", m.replace("-", "_")))]\n', "    return list(mods)\n")],
    "blindrefuse": [(r"PM: failed to (suspend|resume)[a-z ]*: error", r"PM: gave up (suspend|resume)[a-z ]*: error"),
                    ('any("PM: Some devices failed to suspend" in x for x in L)', "False"), ("rc not in (0, None)", "False")],
    "nopending": [("        if os.path.exists(os.path.join(d, \"result.json\")):\n            continue\n", "        continue\n")],
    "noinhibit": [('i.get("mode") == "block" and', "False and")],
}
NEEDLE = {"notty": "without a terminal", "norestore": "test switch is off", "noreload": "loaded again", "anyload": "not in the kernel", "blindrefuse": "refused",
          "nopending": "never came back", "noinhibit": "blocks sleep"}
REHEARSED = """Nov 22 19:00:00.000000 host kernel: PM: suspend entry (deep)
Nov 22 19:00:00.100000 host kernel: Freezing user space processes completed (elapsed 0.001 seconds)
Nov 22 19:00:00.400000 host kernel: PM: suspend debug: Waiting for 5 second(s).
Nov 22 19:00:05.900000 host kernel: nvidia 0000:01:00.0: PM: pci_pm_suspend+0x0/0x1b0 returned 0 after 612345 usecs
Nov 22 19:00:06.000000 host kernel: PM: suspend exit
"""


def fixture(name):
    return open(os.path.join(FIX, name), encoding="utf-8").read()


def run(arm=""):
    fails, n = [], 0

    def check(name, ok, detail=""):
        nonlocal n
        n += 1
        if not ok:
            fails.append(name)
            print("FAIL %s  [%s]" % (name, str(detail)[-500:]))

    W = tempfile.mkdtemp(prefix="suspend-lab.")
    try:
        src = open(TOOL, encoding="utf-8").read()
        for a, b in ARMS.get(arm, []):
            if src.count(a) != 1:
                print("ARM %s: anchor gone (%s)" % (arm, a))
                return ["anchor gone"], 0
            src = src.replace(a, b)
        tool = os.path.join(W, "suspend_lab.py")
        open(tool, "w", encoding="utf-8").write(src)
        ns = {"__name__": "lab", "__file__": tool, "__doc__": ""}
        exec(compile(src, tool, "exec"), ns)
        judge, changes, woke = ns["judge"], ns["changes"], ns["woke"]

        # ---- the verdict, on what this kernel really printed
        r = judge(fixture("refused.log"), "devices", 1)
        check("a driver that says no: refused, and both sensors are named", r["verdict"] == "REFUSED" and not r["ok"] and len(r["refused"]) == 2
              and "12-0051" in " ".join(r["refused"]), r)
        check("refused by the memory's sensors: the next test is named", "--without spd5118" in r["next"], r)
        check("the refusing call is named", any("spd5118_suspend" in c for c in r["calls"]), r)
        r = judge(fixture("refused.log").replace("spd5118 12-005", "nvidia 0000:0").replace("spd5118", "nvidia"), "devices", 1)
        check("another driver's refusal does not blame the sensors", r["verdict"] == "REFUSED" and r["next"] == "", r)
        r = judge(fixture("errors.log"), "sleep", None, 2000)
        check("it slept, and a driver did not come back", r["verdict"] == "BACK WITH ERRORS" and not r["ok"] and len(r["resume"]) == 2 and r["state"] == "S3", r)
        r = judge(fixture("clean.log"), "sleep", None, 150)
        check("it slept and came back", r["verdict"] == "PASS" and r["ok"] and r["state"] == "S3", r)
        r = judge(REHEARSED, "devices", 0)
        check("a rehearsal passes", r["verdict"] == "PASS" and r["ok"], r)
        check("a slow device is named", any("612 ms" in s and "pci_pm_suspend" in s and "0000:01:00.0" in s for s in r["slow"]), r)
        check("the same rehearsal, and the write into the kernel failed: refused", judge(REHEARSED, "devices", 1)["verdict"] == "REFUSED")
        check("a rehearsal's lines are no sleep", judge(REHEARSED, "sleep", None, 0)["verdict"] == "DID NOT SLEEP")
        check("no suspend in the log", judge("Nov 22 host kernel: usb 1-1: new device\n", "devices", 0)["verdict"] == "NOT TRIED")
        check("it went in and the log ends", judge("\n".join(fixture("clean.log").splitlines()[:8]), "sleep", None, 0)["verdict"] == "NO END")
        r = judge(fixture("clean.log") + "Dec 12 17:31:16 host kernel: NVRM: Xid (PCI:0000:01:00): 79, GPU has fallen off the bus.\n", "sleep", None, 150)
        check("a complaint of the NVIDIA driver is no pass", r["verdict"] == "BACK WITH ERRORS" and r["nvidia"], r)
        a, b = {"wake": {"xhci (a)": 1, "rtc_cmos (b)": 0}, "outputs": [1], "usb": ["k"]}, {"wake": {"xhci (a)": 1, "rtc_cmos (b)": 2}, "outputs": [], "usb": ["k"]}
        check("what woke it, and what is not as it was", woke(a, b) == ["rtc_cmos (b)"] and len(changes(a, b)) == 1 and "displays" in changes(a, b)[0], (woke(a, b), changes(a, b)))

        # ---- the lab itself, with stubs
        def env(d, **more):
            e = {"PATH": "/usr/bin:/bin", "HOME": d, "XDG_STATE_HOME": d + "/state", "LARES_LAB_SYS": d + "/sys", "LARES_LAB_BIN": d + "/bin",
                 "LARES_LAB_PACMAN": d + "/db.lck", "LARES_LAB_BOOT": "boot-now", "TERM": "dumb"}
            e.update(more)
            return e

        def machine(refuses=False, inhibit=False):
            d = tempfile.mkdtemp(dir=W)
            for x in ("sys/power/suspend_stats", "sys/class/rtc/rtc0", "sys/module/spd5118", "bin"):
                os.makedirs(os.path.join(d, x))
            for f, t in (("state", "freeze mem disk"), ("pm_test", "[none] core processors platform devices freezer"), ("mem_sleep", "s2idle [deep]"),
                         ("pm_print_times", "0"), ("pm_debug_messages", "0")):
                open(os.path.join(d, "sys/power", f), "w").write(t + "\n")
            open(os.path.join(d, "sys/class/rtc/rtc0/wakealarm"), "w").close()
            if refuses:     # a write into it fails, as a refusing kernel's does -- and "mem" must still be offered
                os.chmod(os.path.join(d, "sys/power/state"), 0o444)
            open(os.path.join(d, "kernel.log"), "w").write(fixture("refused.log") if refuses else REHEARSED)
            stubs = {
                "sudo": '#!/bin/sh\necho "sudo" >> %s/calls\nPATH=%s/bin:/usr/bin:/bin exec "$@"\n' % (d, d),
                "modprobe": '#!/bin/sh\necho "modprobe $*; pm_test=$(cat %s/sys/power/pm_test)" >> %s/calls\n' % (d, d),
                "systemctl": '#!/bin/sh\ncase "$*" in suspend) echo "suspend; pm_test=$(cat %s/sys/power/pm_test) alarm=$(cat %s/sys/class/rtc/rtc0/wakealarm)" >> %s/calls ;; esac\n' % (d, d, d),
                "journalctl": '#!/bin/sh\ncase "$*" in *logind*) echo "Operation \'suspend\' finished." ;; *_TRANSPORT=kernel*) cat %s/kernel.log ;; esac\n' % d,
                "systemd-inhibit": "#!/bin/sh\necho '%s'\n" % json.dumps([{"who": "lares", "what": "handle-lid-switch:sleep:idle", "why": "hard", "mode": "block"}] if inhibit else
                                                                         [{"who": "hypridle", "what": "sleep", "why": "x", "mode": "delay"}]),
            }
            for k, t in stubs.items():
                p = os.path.join(d, "bin", k)
                open(p, "w").write(t)
                os.chmod(p, 0o755)
            return d

        def on_tty(d, *args, answer="the picture came back a second late\n", timeout=40):
            """-> (status, everything it printed)"""
            pid, fd = pty.fork()
            if pid == 0:
                os.execvpe(sys.executable, [sys.executable, "-B", tool] + list(args), env(d))
            out, end, answered = b"", time.time() + timeout, False
            while time.time() < end:
                if not select.select([fd], [], [], 0.2)[0]:
                    continue
                try:
                    c = os.read(fd, 65536)
                except OSError:
                    break
                if not c:
                    break
                out += c
                if b"Anything odd" in out[-400:] and not answered:
                    os.write(fd, answer.encode())
                    answered = True
                    out += b"\n"
                elif answered and b"Anything odd" not in out[-60:]:
                    answered = False
            else:
                os.kill(pid, 9)
            _, st = os.waitpid(pid, 0)
            os.close(fd)
            return os.waitstatus_to_exitcode(st), out.decode(errors="replace")

        def calls(d):
            p = os.path.join(d, "calls")
            return open(p).read().splitlines() if os.path.exists(p) else []

        def result(d):
            base = os.path.join(d, "state/lares/suspend-lab")
            rs = sorted(os.listdir(base)) if os.path.isdir(base) else []
            return [json.load(open(os.path.join(base, x, "result.json"))) if os.path.exists(os.path.join(base, x, "result.json")) else {} for x in rs], [os.path.join(base, x) for x in rs]

        pm = lambda d: open(os.path.join(d, "sys/power/pm_test")).read().split()
        d = machine()
        p = subprocess.run([sys.executable, "-B", tool, "stage", "devices"], env=env(d), stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
        check("a test without a terminal is refused and asks for no root", p.returncode == 2 and calls(d) == [] and "terminal" in p.stderr, (p.returncode, calls(d), p.stderr))
        d = machine()
        rc, out = on_tty(d, "stage", "devices", "--without", "spd5118")
        c = calls(d)
        rs, dirs = result(d)
        check("a rehearsal that passes ends 0", rc == 0 and rs and rs[0].get("verdict") == "PASS", (rc, out, rs))
        check("the module is out before the kernel is asked, and loaded again after", len(c) == 3 and c[1].startswith("modprobe -r spd5118") and c[2].startswith("modprobe spd5118"), c)
        check("the module is loaded again only once the test switch is off", len(c) == 3 and c[2].endswith("pm_test=none"), c)
        check("the test switch is off after a test", pm(d) == ["none"], pm(d))
        check("the kernel was asked for mem, its log switches are back", open(d + "/sys/power/state").read().split() == ["mem"] and open(d + "/sys/power/pm_print_times").read().split() == ["0"])
        check("what the person said is in the record", rs and rs[0].get("note") == "the picture came back a second late", rs)
        check("the record holds the kernel's lines and both pictures", dirs and all(os.path.exists(os.path.join(dirs[0], f)) for f in ("before.json", "after.json", "kernel.log", "system.log")), dirs)
        d = machine()
        os.rmdir(os.path.join(d, "sys/module/spd5118"))
        rc, out = on_tty(d, "stage", "devices", "--without", "spd5118")
        check("a module that is not in the kernel is not put into it either", rc == 0 and calls(d) == ["sudo"], (rc, calls(d)))
        if os.geteuid() != 0:
            d = machine(refuses=True)
            rc, out = on_tty(d, "ladder")
            rs, dirs = result(d)
            check("the ladder ends at the first that fails", rc == 1 and len(rs) == 1 and rs[0].get("verdict") == "REFUSED" and "freezer" in dirs[0], (rc, out, rs))
            check("a refused test leaves the test switch is off too", pm(d) == ["none"], pm(d))
        d = machine()
        rc, out = on_tty(d, "ladder")
        order = [x.split(":")[0] for x in out.replace("\r", "").splitlines() if x.endswith("does not sleep.")]
        check("the ladder goes through all five in their order", rc == 0 and order == ["freezer", "devices", "platform", "processors", "core"] and len(result(d)[0]) == 5, (rc, order, out[-300:]))
        d = machine()
        open(os.path.join(d, "kernel.log"), "w").write(fixture("clean.log"))
        rc, out = on_tty(d, "sleep", "45", "--without", "spd5118")
        c = calls(d)
        rs, dirs = result(d)
        check("the real sleep: the alarm is set and the module out before systemd is asked, both undone after",
              [x.split(";")[0] for x in c] == ["sudo", "modprobe -r spd5118", "suspend", "sudo", "modprobe spd5118"] and "alarm=+45" in c[2] and "pm_test=none" in c[2]
              and open(d + "/sys/class/rtc/rtc0/wakealarm").read().split() == ["0"], (c, out[-400:]))
        check("the real sleep's verdict", rc == 0 and rs and rs[0].get("verdict") == "PASS", (rc, rs))
        d = machine(inhibit=True)
        rc, out = on_tty(d, "sleep")
        check("something that blocks sleep stops the lab before it starts", rc == 2 and calls(d) == [] and "blocks sleep" in out, (rc, out, calls(d)))
        d = machine()
        open(d + "/db.lck", "w").close()
        rc, out = on_tty(d, "stage", "devices")
        check("no test while packages are being installed", rc == 2 and calls(d) == [], (rc, out))
        d = machine()
        rc, out = on_tty(d, "sleep", "5")
        check("five seconds is no sleep", rc == 2 and calls(d) == [], (rc, out))
        rc, out = on_tty(d, "stage", "devices", "--without", "a;reboot")
        check("a module's name is a name", rc == 2 and calls(d) == [], (rc, out))
        # a machine that never came back: a record with no result, and another boot since
        d = machine()
        open(os.path.join(d, "kernel.log"), "w").write("\n".join(fixture("clean.log").splitlines()[1:10]) + "\n")
        rec = os.path.join(d, "state/lares/suspend-lab/20261122-190000-sleep")
        os.makedirs(rec)
        json.dump({"boot": "boot-before", "time": 1, "test": "sleep"}, open(os.path.join(rec, "before.json"), "w"))
        p = subprocess.run([sys.executable, "-B", tool, "check"], env=env(d), stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
        rs, dirs = result(d)
        check("a test the machine never came back from is filed, with the kernel's last line", rs and rs[0].get("verdict") == "NEVER CAME BACK" and "Saving platform NVS" in rs[0]["why"]
              and "NEVER CAME BACK" in p.stdout, (rs, p.stdout, p.stderr))
        p = subprocess.run([sys.executable, "-B", tool, "check"], env=env(d), stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
        check("it is said once", p.returncode == 0 and "NEVER CAME BACK" not in p.stdout, p.stdout)
        d = machine()
        rec = os.path.join(d, "state/lares/suspend-lab/20261122-190000-devices")
        os.makedirs(rec)
        json.dump({"boot": "boot-now", "time": 1, "test": "devices"}, open(os.path.join(rec, "before.json"), "w"))
        open(os.path.join(rec, "pid"), "w").write(str(os.getpid()))
        subprocess.run([sys.executable, "-B", tool, "report"], env=env(d), stdin=subprocess.DEVNULL, capture_output=True, timeout=60)
        check("a test that is running is left alone", result(d)[0] == [{}], result(d)[0])
        check("a fake machine's check reads a fake machine", "CanSuspend ?" in p.stdout and calls(d) == [], p.stdout)
    finally:
        shutil.rmtree(W, ignore_errors=True)
    return fails, n


if os.environ.get("ARM") == "all":
    bad = 0
    for a in ARMS:
        sys.stdout = open(os.devnull, "w")
        f, _ = run(a)
        sys.stdout = sys.__stdout__
        ok = any(NEEDLE[a] in x for x in f)
        print("ARM %s: %s" % (a, "fails as it must" if ok else "DID NOT FAIL (%s)" % f))
        bad += 0 if ok else 1
    print("SUSPEND_LAB ARMS " + ("FAIL" if bad else "PASS"))
    sys.exit(1 if bad else 0)
f, n = run(os.environ.get("ARM", ""))
print("SUSPEND_LAB RESULT %s (%d of %d)" % ("FAIL" if f or not n else "PASS", n - len(f), n))
sys.exit(1 if f or not n else 0)
