"""`watch`: ONE GLib main loop, event-driven. No polling timer at rest and no fork at rest.

Sources: KDE Connect's signals (one subscription) and its name owner, adb's track-devices socket, the USB bus (GUdev), the mount table
(POLLPRI on mountinfo), the job records (a file monitor and a pidfd per live wrapper), the state file, the runtime dir and the config.
A phone that comes onto the cable with adb up and no stored link is asked, once, for its addresses and its device name
(parse.IDENT_SCRIPT through one `adb shell`, asynchronous), which tells which KDE Connect phone it is (merge rule 6); asked again
only when the addresses KDE Connect reaches its phones on change while it is still unlinked.
Every source marks the model dirty; a single-shot 50 ms timer coalesces them into one line, printed only when something changed
(job figures at most every 500 ms). Timers that exist: that coalescing one, the start-up deadline and, while a job record has no
wrapper yet, one single-shot for its grace.
"""
import os
import signal
import subprocess
import sys
import time
import traceback

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

from . import adbsock, argv as argvlib, jobs, kdc as kdclib, mounts, model, parse, trace, usb as usblib  # noqa: E402
from . import state as st  # noqa: E402
from . import merge  # noqa: E402

COALESCE_MS = 50
FIGURE_GAP_S = 0.5
START_DEADLINE_MS = 1500
IDENT_TIMEOUT_MS = 8000


class Watch:
    def __init__(self, paths, tool):
        self.paths = paths
        self.tool = tool
        self.cfg, self.cfg_error = st.load_config(paths)
        self.w = model.World(paths, self.cfg)
        self.loop = GLib.MainLoop()
        self.serial = 0
        self.last = None            # the last printed line (without serial)
        self.last_at = 0.0
        self.timer = 0
        self.first = False
        self.pending = {"kdc", "adb"}
        self.rc = 0
        self.kd = None
        self.tracker = None
        self.pidfds = {}
        self.grace = 0
        self.prev_present = None
        self.prev_sig = {}
        self.prev_plug = None
        self.monitors = []
        self.kdc_timer = 0
        self.ident_busy = set()
        self.ident_sig = {}

    # ---- the plumbing ---------------------------------------------------------------------------------------------------
    def guard(self, fn):
        def run(*a, **k):
            try:
                return fn(*a, **k)
            except Exception as e:  # noqa: BLE001 -- the contract: a fault is one error line and a non-zero exit
                self.fatal("%s: %s" % (type(e).__name__, e))
        return run

    def fatal(self, text):
        traceback.print_exc()
        try:
            sys.stdout.write(st.dumps({"v": 1, "error": text}) + "\n")
            sys.stdout.flush()
        finally:
            os._exit(1)

    def say(self, line):
        try:
            sys.stdout.write(st.dumps(line) + "\n")
            sys.stdout.flush()
        except (BrokenPipeError, ValueError):
            self.loop.quit()

    def dirty(self):
        if not self.timer:
            self.timer = GLib.timeout_add(COALESCE_MS, self.guard(self._tick))

    def _tick(self):
        self.timer = 0
        if self.pending and not self.first:
            return GLib.SOURCE_REMOVE
        self.flush()
        return GLib.SOURCE_REMOVE

    def resolved(self, what):
        self.pending.discard(what)
        if not self.pending:
            self.dirty()

    # ---- building and printing ------------------------------------------------------------------------------------------
    def flush(self):
        w = self.w
        w.now = time.time()
        w.have = model.doctor.have()
        w.usb_mount_ok = model.doctor.usb_mount_ok(self.paths, self.cfg)
        line, merged = model.build(w)
        self._memory(line)
        self._persist(line, merged)
        self._plug(line)
        pub = model.public(line, 0)
        del pub["serial"]
        if self.last is not None and pub == self.last:
            return
        now = time.time()
        if self.last is not None and model.without_figures(pub) == model.without_figures(self.last) \
                and now - self.last_at < FIGURE_GAP_S:
            self.timer = GLib.timeout_add(int((FIGURE_GAP_S - (now - self.last_at)) * 1000) + 5, self.guard(self._tick))
            return
        self.serial += 1
        out = {"v": pub["v"], "serial": self.serial, **{k: v for k, v in pub.items() if k != "v"}}
        self.last, self.last_at = pub, now
        self.first = True
        trace.write(self.paths, "watch", line=out)
        self.say(out)

    def _memory(self, line):
        """When a device's links change, what a failed try said no longer holds (it is dropped from `can` by w.changed_at)."""
        now = time.time()
        sigs = {d["key"]: model.link_sig(d) for d in line["devices"]}
        for k, s in sigs.items():
            if k not in self.prev_sig:
                self.w.changed_at.setdefault(k, 0)
            elif self.prev_sig[k] != s:
                self.w.changed_at[k] = now
        self.prev_sig = sigs

    def _persist(self, line, merged):
        """lastSeen when someone arrives or leaves, and the KDE Connect id -> USB serial links this merge found."""
        s = self.w.state
        changed = False
        present = merged["present"]
        if self.prev_present is not None:
            table, ch = merge.seen_update(s, self.prev_present, present, time.time())
            if ch:
                s["lastSeen"] = table
                changed = True
        self.prev_present = list(present)
        for kid, serial in merged["links"].items():
            if s["links"].get(kid) != serial:
                s["links"][kid] = serial
                changed = True
                if st.adopt(s, "adb:" + serial, "kdc:" + kid):
                    trace.write(self.paths, "adopt", old="adb:" + serial, new="kdc:" + kid)
                    self.w.tries.pop("adb:" + serial, None)
        if changed:
            st.save_state(self.paths, s)

    def _plug(self, line):
        """A phone with an adb interface that just came onto the cable: the server (adb.start onPlug) and Keep wireless ready."""
        cur = {d["usb"]["serial"] for d in line["devices"] if d["usb"] and d["usb"]["adbIface"]}
        if self.prev_plug is not None:
            for d in line["devices"]:
                u = d["usb"]
                if u and u["adbIface"] and u["serial"] not in self.prev_plug \
                        and (d["prefs"]["keepWireless"] or self.cfg["adb"]["start"] == "onPlug"):
                    self.spawn([self.tool, "_plug", d["key"]])
        self.prev_plug = cur

    def spawn(self, argv):
        """A detached helper (the tool's own `_plug`); GLib reaps it when it ends."""
        try:
            p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True, close_fds=True)
        except OSError:
            return
        GLib.child_watch_add(GLib.PRIORITY_DEFAULT, p.pid, lambda pid, status: None)

    # ---- the sources ----------------------------------------------------------------------------------------------------
    def start(self):
        self.paths.ensure()
        jobs.sweep(self.paths, time.time())
        model.gather_local(self.w)
        self.w.jobs = jobs.read_all(self.paths)
        self.w.tries = jobs.load_tries(self.paths)
        self.start_usb()
        self.start_mounts()
        self.start_files()
        self.start_kdc()
        self.start_adb()
        self.sync_jobs()
        for sig in (signal.SIGTERM, signal.SIGINT):
            GLib.unix_signal_add(GLib.PRIORITY_HIGH, sig, lambda: (self.loop.quit(), GLib.SOURCE_REMOVE)[1])
        GLib.timeout_add(START_DEADLINE_MS, self.guard(self._deadline))
        self.loop.run()
        return self.rc

    def _deadline(self):
        if not self.first:
            self.pending.clear()
            self.dirty()
        return GLib.SOURCE_REMOVE

    # USB
    def start_usb(self):
        def changed():
            self.w.usb = usblib.scan(self.paths.sys_root)
            self.kick_adb()
            self.dirty()
        self.usb = usblib.Watcher(self.paths.sys_root, self.guard(changed))
        self.usb.start()

    # mounts
    def start_mounts(self):
        def changed():
            self.w.mounts = mounts.read(self.paths.mountinfo)
            self.w.mine = mounts.load_mine(self.paths)
            self.w.stale = model.stale_points(self.w)
            self.dirty()
        self.mnt = mounts.Watcher(self.paths.mountinfo, self.guard(changed))
        self.mnt.start()

    # files: state, runtime dir, jobs, config
    def watch_path(self, path, handler, directory=True):
        f = Gio.File.new_for_path(path)
        try:
            m = f.monitor_directory(Gio.FileMonitorFlags.NONE, None) if directory else f.monitor_file(Gio.FileMonitorFlags.NONE, None)
        except GLib.Error:
            return
        m.connect("changed", lambda mon, a, b, ev: self.guard(handler)(a.get_basename() if a else ""))
        self.monitors.append(m)

    def start_files(self):
        def state_changed(name):
            if name.endswith(".part") or name.endswith(".tmp") or name == "lock":
                return
            self.w.state = st.load_state(self.paths)
            self.dirty()

        def runtime_changed(name):
            if name.endswith(".part"):
                return
            if name == "tries.json":
                self.w.tries = jobs.load_tries(self.paths)
            elif name == "mine.json":
                self.w.mine = mounts.load_mine(self.paths)
            elif name == "adb-started":
                self.kick_adb()
            elif name == "wifipair.json":
                self.w.wifipair = model.read_wifipair(self.paths)
            self.dirty()

        def jobs_changed(name):
            if name.endswith(".part") or name.startswith("."):
                return
            self.w.jobs = jobs.read_all(self.paths)
            self.sync_jobs()
            self.kick_adb()
            self.dirty()

        def config_changed(name):
            self.cfg, self.cfg_error = st.load_config(self.paths)
            self.w.cfg = self.cfg
            self.w.usb_mount_ok = model.doctor.usb_mount_ok(self.paths, self.cfg)
            self.dirty()
        self.watch_path(self.paths.state, state_changed)
        self.watch_path(self.paths.runtime, runtime_changed)
        self.watch_path(self.paths.jobs, jobs_changed)
        # the config in force is the first of its four candidates that exists (tools/lib/jsonc.py): each of their
        # folders is watched for exactly those names, so a file that appears, goes or moves is followed
        by_dir = {}
        for c in st.jsonc.candidates(self.paths.config):
            by_dir.setdefault(os.path.dirname(c), set()).add(os.path.basename(c))
        for cdir, names in by_dir.items():
            if os.path.isdir(cdir):
                self.watch_path(cdir, lambda n, names=names: config_changed(n) if n in names else None)

    # jobs: a pidfd per live wrapper
    def sync_jobs(self):
        live = {}
        due = None
        now = time.time()
        for r in self.w.jobs:
            if r["phase"] in jobs.ENDED:
                continue
            if r.get("pid") and jobs.wrapper_alive(r):
                live[r["id"]] = r
            elif r.get("pid"):
                jobs.end_dead(self.paths, r, now)
                self.w.jobs = jobs.read_all(self.paths)
            else:
                d = r.get("started", now) + jobs.START_GRACE_S
                due = d if due is None else min(due, d)
        for jid in list(self.pidfds):
            if jid not in live:
                self.drop_pidfd(jid)
        for jid, r in live.items():
            if jid not in self.pidfds:
                fd = jobs.open_pidfd(r["pid"])
                if fd >= 0:
                    src = GLib.unix_fd_add_full(GLib.PRIORITY_DEFAULT, fd, GLib.IOCondition.IN, self.guard(self._pid_gone), jid)
                    self.pidfds[jid] = (fd, src)
        if self.grace:
            GLib.source_remove(self.grace)
            self.grace = 0
        if due is not None:
            self.grace = GLib.timeout_add(max(50, int((due - now) * 1000) + 50), self.guard(self._grace))

    def drop_pidfd(self, jid):
        fd, src = self.pidfds.pop(jid)
        GLib.source_remove(src)
        os.close(fd)

    def _pid_gone(self, fd, cond, jid):
        r = jobs.read(self.paths, jid)
        if r and r["phase"] not in jobs.ENDED:
            jobs.end_dead(self.paths, r, time.time())
        self.w.jobs = jobs.read_all(self.paths)
        if jid in self.pidfds:
            self.drop_pidfd(jid)
        self.dirty()
        return GLib.SOURCE_REMOVE

    def _grace(self):
        self.grace = 0
        jobs.sweep(self.paths, time.time())
        self.w.jobs = jobs.read_all(self.paths)
        self.sync_jobs()
        self.dirty()
        return GLib.SOURCE_REMOVE

    # KDE Connect
    def start_kdc(self):
        if not model.doctor.kdc_installed():
            self.w.kdc_state = "missing"
            self.resolved("kdc")
            return
        try:
            conn = kdclib.session_bus()
        except GLib.Error:
            self.w.kdc_state = "down"
            self.resolved("kdc")
            return
        self.kd = kdclib.Kdc(conn)
        self.kd.subscribe(self.guard(self.on_kdc_signal))
        self.kd.watch_owner(self.guard(self.kdc_up), self.guard(self.kdc_down))

    def kdc_up(self):
        self.w.kdc_state = "running"
        self.read_kdc()

    def kdc_down(self):
        self.w.kdc_state = "down"
        self.w.kdc = {}
        self.resolved("kdc")
        self.dirty()

    def read_kdc(self):
        def got(recs, err):
            if self.w.kdc_state != "running":
                return
            self.w.kdc = recs
            self.w.stale = model.stale_points(self.w)
            self.ask_ident()
            self.resolved("kdc")
            self.dirty()
        self.kd.read_all(self.guard(got))

    def on_kdc_signal(self, path, iface, member, params):
        if self.w.kdc_state != "running" or iface.startswith("org.freedesktop.DBus"):
            return
        if not self.kdc_timer:
            def go():
                self.kdc_timer = 0
                self.read_kdc()
                self.kick_adb()
                return GLib.SOURCE_REMOVE
            self.kdc_timer = GLib.timeout_add(COALESCE_MS, self.guard(go))

    # adb
    def start_adb(self):
        self.tracker = adbsock.Tracker(adbsock.server_port(), self.guard(self.on_adb), self.guard(self.on_adb_down))
        self.tracker.kick()

    def kick_adb(self):
        if self.tracker:
            self.tracker.kick()

    def on_adb(self, devices):
        self.w.adb, self.w.adb_up = devices, True
        self.ask_ident()
        self.resolved("adb")
        self.dirty()

    # the phone over the cable: which KDE Connect phone is it?
    def _kdc_sig(self):
        return tuple(sorted(a for d in self.w.kdc.values() if d.get("reachable") for a in d.get("addresses") or []))

    def ask_ident(self):
        here = {t["serial"] for t in self.w.adb if t["transport"] == "usb" and t["state"] == "device"}
        for s in list(self.w.ident):
            if s not in here:
                del self.w.ident[s]
                self.ident_sig.pop(s, None)
        linked = set(self.w.state.get("links", {}).values())
        sig = self._kdc_sig()
        for s in here:
            if s in linked or s in self.ident_busy:
                continue
            if s in self.w.ident and self.ident_sig.get(s) == sig:
                continue
            self._ident(s, sig)

    def _ident(self, serial, sig):
        argv = argvlib.adb_facts(serial, parse.IDENT_SCRIPT)
        try:
            p = Gio.Subprocess.new(argv, Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_MERGE)
        except GLib.Error as e:
            trace.write(self.paths, "ident", serial=serial, error=str(e))
            return
        self.ident_busy.add(serial)
        self.ident_sig[serial] = sig
        timer = {"id": 0}

        def expire():
            timer["id"] = 0
            p.force_exit()
            return GLib.SOURCE_REMOVE
        timer["id"] = GLib.timeout_add(IDENT_TIMEOUT_MS, expire)

        def done(proc, res):
            if timer["id"]:
                GLib.source_remove(timer["id"])
                timer["id"] = 0
            self.ident_busy.discard(serial)
            out = ""
            try:
                _ok, out, _err = proc.communicate_utf8_finish(res)
            except GLib.Error as e:
                trace.write(self.paths, "ident", serial=serial, error=str(e))
            exited = proc.get_if_exited()
            got = parse.parse_ident(out or "") if exited and proc.get_exit_status() == 0 else {"addresses": [], "name": ""}
            trace.write(self.paths, "ident", serial=serial, status=proc.get_exit_status() if exited else None, got=got,
                        out=(out or "")[-400:])
            if any(t["serial"] == serial for t in self.w.adb):
                self.w.ident[serial] = got
                self.dirty()
        p.communicate_utf8_async(None, None, self.guard(done))

    def on_adb_down(self):
        self.w.adb, self.w.adb_up = [], False
        self.resolved("adb")
        self.dirty()


def run(paths, tool):
    wt = Watch(paths, tool)
    try:
        return wt.start()
    except BrokenPipeError:
        return 0
