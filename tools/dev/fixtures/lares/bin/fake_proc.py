#!/usr/bin/python3
"""The stand-ins for the geoclue demo agent ("agent"), the package managers ("pmstub", "yaystub": the restart guard reads the
command lines of pacman / yay) and a program of the session that is none of the shell's business ("waybar": `start` must leave it
alone), for tools/dev/lares_tool_probe.sh and tools/dev/lares_deploy_probe.sh.

One file, called through symlinks: it behaves as the name it was started under (its comm is that name,
which is what the tool finds a process by -- a script run through its shebang takes the script's name).
It records START and STOP in $LARES_FAKE/stub.log and runs until TERM. The agent also owns
org.freedesktop.GeoClue2.DemoAgent, the name the real demo agent (a GApplication) takes on the session bus (the probe's PRIVATE one).

ctl/stubborn_<name> makes the process ignore TERM (only KILL ends it).
"""
import ctypes
import os
import signal
import sys
import time
import warnings

warnings.simplefilter("ignore")

W = os.environ.get("LARES_FAKE", "")
if not W or not os.path.isdir(W):
    sys.exit("fake process: refusing to run outside the lares probes (LARES_FAKE is not a directory)")
NAME = os.path.basename(sys.argv[0])
LOG = os.path.join(W, "stub.log")
# A real program's comm is its name whatever started it. A script run through `python3 <script>` (which is
# how the tool replays a command line it recorded from a script) would be "python3": set it by hand.
ctypes.CDLL(None).prctl(15, NAME.encode(), 0, 0, 0)   # PR_SET_NAME, cut at 15 characters by the kernel


def log(msg):
    with open(LOG, "a") as f:
        f.write(msg + "\n")


log("START %s pid=%d argv=%s" % (NAME, os.getpid(), " ".join(sys.argv[1:])))
stubborn = os.path.exists(os.path.join(W, "ctl", "stubborn_" + NAME))


def term(*_):
    if stubborn:
        log("IGNORED-TERM %s pid=%d" % (NAME, os.getpid()))
        return
    log("STOP %s pid=%d TERM" % (NAME, os.getpid()))
    sys.exit(0)


signal.signal(signal.SIGTERM, term)

BUS_NAMES = {"agent": "org.freedesktop.GeoClue2.DemoAgent"}
if NAME in BUS_NAMES:
    import gi
    gi.require_version("Gio", "2.0")
    from gi.repository import Gio, GLib
    loop = GLib.MainLoop()

    def stop(*_):
        if stubborn:
            return True
        log("STOP %s pid=%d TERM" % (NAME, os.getpid()))
        loop.quit()
        return False
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, stop)
    Gio.bus_own_name(Gio.BusType.SESSION, BUS_NAMES[NAME], Gio.BusNameOwnerFlags.DO_NOT_QUEUE,
                     None, lambda c, n: log("NAME %s pid=%d owns %s" % (NAME, os.getpid(), n)), None)
    loop.run()
else:
    while True:
        time.sleep(0.2)
