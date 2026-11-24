"""The one-shots: each returns (answer dict, exit status). Exit: 0 done, 1 failed, 2 usage, 3 not available, 4 refused.

A one-shot gathers the facts once (the same model the watcher keeps), decides with caps / resolve / argv, acts and answers ONE
JSON object. It never reads the watcher's memory of failed tries: a deliberate call is always allowed to try again.
"""
import contextlib
import fcntl
import json
import os
import subprocess
import sys
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import GLib  # noqa: E402

from . import usb as usblib  # noqa: E402
from . import adbctl, adbsock, argv as argvlib, caps, doctor, jobs, kdc as kdclib, keyring, merge, model, mounts, parse, resolve, trace  # noqa: E402
from . import state as st  # noqa: E402

OK, FAILED, USAGE, UNAVAILABLE, REFUSED = 0, 1, 2, 3, 4


class Stop(Exception):
    def __init__(self, code, reason, hint=""):
        self.code, self.reason, self.hint = code, reason, hint


def done(**kw):
    d = {"ok": True}
    d.update(kw)
    return d, OK


def fail(code, reason, hint=""):
    return {"ok": False, "reason": reason, "hint": hint}, code


class Ctx:
    def __init__(self, paths, cfg, tool):
        self.paths, self.cfg, self.tool = paths, cfg, tool
        self._world = None
        self._line = None
        self._kdc = None

    # ---- the facts -----------------------------------------------------------------------------------------------------
    def kdc(self):
        if self._kdc is None:
            try:
                self._kdc = kdclib.Kdc(kdclib.session_bus(), sync=True)
            except GLib.Error:
                self._kdc = False
        return self._kdc or None

    def refresh(self):
        w = model.World(self.paths, self.cfg)
        model.gather_local(w)
        kd = self.kdc()
        if not doctor.kdc_installed():
            w.kdc_state = "missing"
        elif kd and kd.has_owner():
            w.kdc_state = "running"
            kd.read_all(lambda recs, err: setattr(w, "kdc", recs))
            w.stale = model.stale_points(w)
        devs, _ = adbsock.devices_sync()
        w.adb = devs or []
        w.adb_up = devs is not None
        self._world = w
        self._line, _ = model.build(w)
        return self._line

    def line(self):
        return self._line or self.refresh()

    def world(self):
        self.line()
        return self._world

    def device(self, key):
        for d in self.line()["devices"]:
            if d["key"] == key:
                return d
        raise Stop(UNAVAILABLE, "no such device: %s" % key, "Run `lares-bridge state` for the keys")

    def kdc_id(self, key):
        """The KDE Connect id behind a device key (or a pairing entry's key)."""
        if key.startswith("kdc:"):
            return key[4:]
        d = self.device(key)
        if not d["kdc"]:
            raise Stop(UNAVAILABLE, "KDE Connect does not know this phone", "Pair it from KDE Connect on the phone")
        return d["kdc"]["id"]

    def need_kdc(self):
        k = self.kdc()
        st_ = self.world().kdc_state
        if st_ == "missing":
            raise Stop(UNAVAILABLE, "KDE Connect is not installed", "sudo pacman -S kdeconnect")
        if st_ != "running" or not k:
            raise Stop(UNAVAILABLE, "KDE Connect is not running", "Start kdeconnectd (it starts with the session)")
        return k

    def refuse_if(self, dev, action):
        c = dev["can"][action]
        if not c["ok"]:
            raise Stop(UNAVAILABLE, c["why"], c["hint"])
        return c

    # ---- the state file ------------------------------------------------------------------------------------------------
    @contextlib.contextmanager
    def state_lock(self):
        self.paths.ensure()
        fd = os.open(os.path.join(self.paths.state, "lock"), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)


# ---- transport ----------------------------------------------------------------------------------------------------------
def _exec(args, timeout=8):
    t0 = time.time()
    try:
        r = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
        rc, out = r.returncode, (r.stdout or "") + (r.stderr or "")
    except subprocess.TimeoutExpired:
        rc, out = 124, "timed out"
    except OSError as e:
        rc, out = 127, str(e)
    trace.ran(args, rc, t0, out)
    return rc, out


def _wait_transport(serial, tries=6):
    for _ in range(tries):
        devs, _e = adbsock.devices_sync()
        for t in devs or []:
            if t["serial"] == serial and t["state"] == "device":
                return t
        time.sleep(0.4)
    return None


def resolve_transport(ctx, dev, action):
    """Walks the ladder -> (serial, via). Records why in tries and raises Stop when no step reaches the phone."""
    up, err = adbctl.need(ctx.paths, ctx.cfg, ctx.tool)
    if not up:
        raise Stop(UNAVAILABLE, "adb could not start: %s" % err, "Run `adb start-server` to see why")
    devs, _e = adbsock.devices_sync()
    ctx.world().adb = devs or []
    d = merge.merge({"kdc": ctx.world().kdc, "adb": ctx.world().adb, "usb": ctx.world().usb}, ctx.world().state, ctx.cfg,
                    time.time())
    cur = next((x for x in d["devices"] if x["key"] == dev["key"]), dev)
    port = ctx.cfg["adb"]["port"]
    steps = resolve.ladder(cur, port)
    if not steps or steps[0]["step"] not in ("usb", "tcp"):
        rc, out = _exec(argvlib.adb("mdns", "services"), 6)
        steps = resolve.ladder(cur, port, parse.parse_mdns(out) if rc == 0 else [])
    last = ""
    for s in steps:
        if s["step"] in ("usb", "tcp"):
            return s["serial"], s["step"]
        rc, out = _exec(argvlib.adb_connect(s["address"]), 8)
        okc, text = parse.parse_connect(out)
        if okc and _wait_transport(s["address"]):
            return s["address"], "tcp"
        last = text or out.strip()
    reason, hint = _reach_reason(cur, last, bool(steps))
    jobs.record_try(ctx.paths, dev["key"], action, reason, hint, time.time())
    raise Stop(FAILED, reason, hint)


def _reach_reason(dev, last, tried):
    """Why adb did not reach the phone over Wi-Fi, and the ONE step that fixes it (refused = adb is not listening: the phone
    restarted, or was never armed)."""
    paired = bool((dev.get("prefs") or {}).get("wifiDebug"))
    step = "Turn on Wireless debugging on the phone, or plug it in" if paired else \
        "Plug it in once, or pair it for Wireless debugging (Details)"
    if tried:
        if "refused" in last or "failed to connect" in last or "cannot connect" in last:
            return "adb is off on the phone's Wi-Fi", step
        if "timed out" in last:
            return "The phone did not answer", "Check it is awake and on this network"
        return "Could not reach the phone: %s" % (last or "no answer"), step
    return "adb is not connected", step


# ---- jobs ---------------------------------------------------------------------------------------------------------------
def _live_job(ctx, key, kind):
    return next((r for r in jobs.read_all(ctx.paths) if r["device"] == key and r["kind"] == kind and r["phase"] not in jobs.ENDED), None)


def _start(ctx, rec, argv, settle=("running", "done", "failed"), wait=3.0):
    now = time.time()
    ok, err = jobs.start(ctx.paths, rec, argv, ctx.tool, now)
    if not ok:
        jobs.remove(ctx.paths, rec["id"])
        raise Stop(FAILED, "could not start the job: %s" % err)
    return jobs.wait_phase(ctx.paths, rec["id"], settle, wait) or rec


def cmd_mirror(ctx, args):
    key, opts = _positional(args, 1, {"--mode": 1, "--screen-off": 0, "--record": 0})
    dev = ctx.device(key[0])
    mode = opts.get("--mode", dev["prefs"]["mode"])
    if mode not in st.MODES:
        return fail(USAGE, "mode is one of %s" % ", ".join(st.MODES))
    screen_off = "--screen-off" in opts or dev["prefs"]["screenOff"]
    record = "--record" in opts or dev["prefs"]["record"]
    ctx.refuse_if(dev, "mirror")
    if _live_job(ctx, dev["key"], "mirror"):
        return fail(REFUSED, "Already mirroring this phone", "Stop the running mirror first")
    serial, via = resolve_transport(ctx, dev, "mirror")
    rec_path = _record_path(ctx, mode) if record else ""
    cmd = argvlib.scrcpy(ctx.cfg, mode, serial, via, argvlib.safe_title(dev["name"]), screen_off, rec_path)
    rec = jobs.blank("mirror", dev["key"], mode, via, time.time(), id=jobs.next_id(ctx.paths, "mirror"))
    r = _start(ctx, rec, cmd)
    if r["phase"] == "failed":
        reason = r.get("reason") or "scrcpy stopped at once"
        jobs.remove(ctx.paths, rec["id"])
        jobs.record_try(ctx.paths, dev["key"], "mirror", reason, "", time.time())
        return fail(FAILED, reason, "Check the phone is unlocked and allows USB debugging")
    return done(job=rec["id"], via=via)


def _record_path(ctx, mode):
    """Where a recording goes: `mirror.recordDir` (made when missing), named by argv.record_name -- scrcpy's window and the popup's cast
    alike (the cast passes it to lares-cast --record, which takes `-2`, `-3` when a restart finds it taken)."""
    d = ctx.paths.expand(ctx.cfg["mirror"]["recordDir"])
    try:
        os.makedirs(d, exist_ok=True)
    except OSError as e:
        raise Stop(FAILED, "Could not make the recording folder: %s" % (e.strerror or e), "Check mirror.recordDir in bridge.jsonc")
    return os.path.join(d, argvlib.record_name(mode, time.strftime("%Y%m%d-%H%M%S")))


def cmd_castprep(ctx, args):
    """Before the popup's cast (tools/bridge/lares-cast, owned by the shell): the transport the cast will use, walked like a
    mirror's (the cable first, then Wi-Fi: an adb TCP transport up, Wireless debugging by mDNS, the armed port), and that
    link's quality from the config (`mirror.usb` / `mirror.wifi`). -> {serial, via, maxSize, bitRate, maxFps, asleep, held[, unlock][, record]}

    `--hold` (a Mirror) keeps the phone's screen on while the cast runs (THE HOLD, below); without it a hold left for the phone is put
    back (a Desktop needs none: its virtual screen runs with the phone dark and locked). `asleep`: the phone's screen was off when this
    castprep began (read before anything woke it) -- the shell puts such a phone back to sleep when the cast ends.

    `--unlock` (with a PIN kept for the phone) runs the unlock first, as `unlock --auto` does, under the same one-at-a-time lock: a running
    unlock is waited for up to 5 s (never two typings), and the answer gains `unlock` {ok, already, why}. It never fails castprep.

    `--record` (the Mirror page's Record): the answer gains `record`, the file the cast writes (`_record_path`: the folder is made here;
    a cast is never camera or audio, so the name is a Mirror's .mp4)."""
    dev_args, opts = _positional(args, 1, {"--unlock": 0, "--hold": 0, "--record": 0})
    dev = ctx.device(dev_args[0])
    ctx.refuse_if(dev, "mirror")
    serial, via = resolve_transport(ctx, dev, "mirror")
    ls = _lockstate(serial)
    asleep = ls is not None and not ls["awake"]
    held = _hold_on(ctx, dev, serial) if "--hold" in opts else not _hold_off(ctx, dev, serial)
    unlock = _castprep_unlock(ctx, dev) if "--unlock" in opts and dev["pin"] == "set" else None
    q = ctx.cfg["mirror"]["usb" if via == "usb" else "wifi"]
    extra = {} if unlock is None else {"unlock": unlock}
    if "--record" in opts:
        extra["record"] = _record_path(ctx, "mirror")
    return done(serial=serial, via=via, maxSize=q["maxSize"], bitRate=q["bitRate"], maxFps=q["maxFps"], asleep=asleep, held=held, **extra)


# ---- THE HOLD: the phone's screen on while a Mirror cast runs -------------------------------------------------------------
# scrcpy's own `stay_awake` sets `stay_on_while_plugged_in` for its server's life and puts back what it READ at its start, from a cleanup
# process on the phone. Every lock and unlock of a phone whose USB default is File transfer restarted adbd, which killed server and cleanup
# together, and the next cast read the 7 it had left as the phone's own value: the user's phone stayed on whenever it charged, cast or no
# cast (found 2026-11-21: "it usually does not go to sleep when I am done"). So the hold is OURS and kept on THIS computer: the phone's
# own screen timeout is recorded ONCE per phone (`hold.json` in the state dir; a record already there is never overwritten, so a
# reconnect or a mode switch cannot record the raised value), raised for the cast, and put back by `castend` -- only if it still reads
# the value we wrote (a timeout the user changed meanwhile is theirs). A record a crash left behind is put back by `castend --all`, which
# the shell runs at its start; and the raised value is a timeout, not "never": at worst the screen goes off HOLD_MS after the last touch.
HOLD_SETTING = ("system", "screen_off_timeout")
HOLD_MS = 30 * 60 * 1000


def _hold_path(ctx):
    return os.path.join(ctx.paths.state, "hold.json")


def _holds(ctx):
    h = st.read_json(_hold_path(ctx), {})
    return h if isinstance(h, dict) else {}


def _hold_read(serial):
    rc, out = _exec(argvlib.adb_setting_get(serial, *HOLD_SETTING), 10)
    try:
        return int(out.strip().splitlines()[-1]) if rc == 0 else None
    except (ValueError, IndexError):
        return None


def _hold_ms(ctx):
    """bridge.jsonc cast.holdMin, in ms (30 minutes when the file says nothing)."""
    try:
        return int(round(float(ctx.cfg["cast"]["holdMin"]) * 60000))
    except (KeyError, TypeError, ValueError):
        return HOLD_MS


def _hold_on(ctx, dev, serial):
    """Records the phone's own timeout (once) and raises it. -> True when the hold is in force."""
    key = dev["key"]
    with ctx.state_lock():
        rec = _holds(ctx).get(key)
    if not isinstance(rec, dict):
        was = _hold_read(serial)
        if was is None:
            trace.write(None, "hold", device=key, step="on", answer=None)
            return False
        with ctx.state_lock():
            h = _holds(ctx)
            if not isinstance(h.get(key), dict):
                h[key] = {"was": was, "set": _hold_ms(ctx), "at": int(time.time())}
                st.write_private(_hold_path(ctx), h)
    with ctx.state_lock():
        rec = _holds(ctx).get(key)
    ms = int(rec.get("set", HOLD_MS)) if isinstance(rec, dict) else _hold_ms(ctx)
    rc, _out = _exec(argvlib.adb_setting_put(serial, HOLD_SETTING[0], HOLD_SETTING[1], ms), 10)
    trace.write(None, "hold", device=key, step="on", rc=rc)
    return rc == 0


def _hold_off(ctx, dev, serial):
    """Puts the phone's own timeout back when a record says we raised it, and drops the record. -> True when no hold is left (none was
    there, or it was put back, or the user changed the timeout meanwhile); False when the phone did not answer (the record stays)."""
    key = dev["key"]
    with ctx.state_lock():
        rec = _holds(ctx).get(key)
    if not isinstance(rec, dict):
        return True
    now = _hold_read(serial)
    if now is None:
        trace.write(None, "hold", device=key, step="off", answer=None)
        return False
    rc = 0
    if now == int(rec.get("set", HOLD_MS)):
        rc, _out = _exec(argvlib.adb_setting_put(serial, HOLD_SETTING[0], HOLD_SETTING[1], int(rec.get("was", 60000))), 10)
    trace.write(None, "hold", device=key, step="off", rc=rc, was=rec.get("was"), found=now)
    if rc != 0:
        return False
    with ctx.state_lock():
        h = _holds(ctx)
        h.pop(key, None)
        st.write_private(_hold_path(ctx), h)
    return True


def cmd_castend(ctx, args):
    """castend <dev> [--sleep] | castend --all. The popup's cast has ended: the hold is put back, and with `--sleep` (the phone was dark when
    the cast began, or the cast's picture woke it) an awake phone is put to sleep (KEYCODE_SLEEP; a dark one is left alone). `--all` puts
    back every hold a record names (the shell's start: no cast runs then) and sleeps nothing. -> {released[, slept]}; an unreachable phone
    fails and keeps its record for the next try."""
    if args == ["--all"]:
        out = []
        for key in sorted(_holds(ctx)):
            try:
                dev = ctx.device(key)
                serial, _via = resolve_transport(ctx, dev, "key")
            except Stop:
                continue
            if _hold_off(ctx, dev, serial):
                out.append(key)
        return done(released=out)
    dev_args, opts = _positional(args, 1, {"--sleep": 0})
    dev = ctx.device(dev_args[0])
    ctx.refuse_if(dev, "key")
    serial, _via = resolve_transport(ctx, dev, "key")
    released = _hold_off(ctx, dev, serial)
    slept = False
    if "--sleep" in opts:
        ls = _lockstate(serial)
        if ls is not None and ls["awake"]:
            rc, _out = _exec(argvlib.adb_key(serial, "KEYCODE_SLEEP"), 8)
            slept = rc == 0
        trace.write(None, "hold", device=dev["key"], step="sleep", slept=slept, awake=None if ls is None else ls["awake"])
    if not released:
        return fail(FAILED, "the phone did not answer", "It puts its screen timeout back at the next cast")
    return done(released=[dev["key"]], slept=slept)


def _castprep_unlock(ctx, dev, wait=5.0):
    """The unlock castprep asks for -> {ok, already, why}. Waits up to `wait` s for a running unlock; the PIN's state is read again once
    the lock is ours (the one we waited for may have failed it)."""
    end = time.time() + wait
    while True:
        with _one_unlock(ctx) as got:
            if got:
                if st.pin_of(st.load_state(ctx.paths), dev["key"]) != "set":
                    return {"ok": False, "already": False, "why": "The PIN failed last time"}
                try:
                    ans, _code = _unlock(ctx, dev, True)
                except Stop as s:
                    ans = {"ok": False, "reason": s.reason}
                return {"ok": bool(ans.get("ok")), "already": bool(ans.get("already")), "why": "" if ans.get("ok") else ans.get("reason", "")}
        if time.time() >= end:
            return {"ok": False, "already": False, "why": "Already unlocking"}
        time.sleep(0.25)


def cmd_stop(ctx, args):
    if len(args) != 1:
        return fail(USAGE, "usage: stop <job id>")
    r = jobs.read(ctx.paths, args[0])
    if not r:
        return fail(UNAVAILABLE, "no such job: %s" % args[0])
    jobs.stop(ctx.paths, args[0])
    return done()


def cmd_ack(ctx, args):
    if len(args) != 1:
        return fail(USAGE, "usage: ack <job id>")
    res = jobs.ack(ctx.paths, args[0])
    if res == "live":
        return fail(REFUSED, "That job is still running", "Stop it first")
    if res == "none":
        return fail(UNAVAILABLE, "no such job: %s" % args[0])
    return done()


# ---- mounts -------------------------------------------------------------------------------------------------------------
def cmd_mount(ctx, args):
    if len(args) != 2 or args[1] not in ("usb", "wifi"):
        return fail(USAGE, "usage: mount <dev> usb|wifi")
    dev = ctx.device(args[0])
    which = args[1]
    now = time.time()
    if which == "usb":
        ctx.refuse_if(dev, "mountUsb")
        m = dev["mounts"]["usb"]
        if m["state"] == "mounted":
            return done(point=m["point"], job="")
        if m["state"] == "stale":
            return fail(REFUSED, "The old mount is stale", "Unmount it first")
        if m["state"] == "mounting":
            return fail(REFUSED, "Already mounting")
        point = m["point"]
        _ask_mtp(ctx, dev)
        rec = jobs.blank("mount", dev["key"], "", "mtp", now, id=jobs.next_id(ctx.paths, "mount"), point=point)
        mounts.add_mine(ctx.paths, point, dev["key"], now)
        r = _start(ctx, rec, argvlib.aft_mount(point), settle=("running", "done", "failed"), wait=4.0)
        if r["phase"] == "failed":
            jobs.remove(ctx.paths, rec["id"])
            mounts.drop_mine(ctx.paths, point)
            reason = r.get("reason") or "aft-mtp-mount stopped at once"
            jobs.record_try(ctx.paths, dev["key"], "mountUsb", reason, "", time.time())
            return fail(FAILED, reason, "Set the phone's USB mode to File transfer and unlock it")
        return done(point=point, job=rec["id"])
    if not ctx.world().have.get("sshfs"):
        return fail(UNAVAILABLE, "sshfs is missing", "sudo pacman -S sshfs")
    ctx.refuse_if(dev, "mountWifi")
    kd = ctx.need_kdc()
    kid = dev["kdc"]["id"]
    out = {}
    kd.act(kid, "mountAndWait", "sftp", None, "(b)", lambda v, e: out.update(v=v, e=e))
    if out.get("e") or not out.get("v") or not out["v"][0]:
        why = {}
        kd.act(kid, "getMountError", "sftp", None, "(s)", lambda v, e: why.update(v=v))
        reason = (why.get("v") or ("",))[0] or out.get("e") or "KDE Connect could not mount the phone"
        jobs.record_try(ctx.paths, dev["key"], "mountWifi", reason, "", time.time())
        return fail(FAILED, reason, "Check the phone is awake and KDE Connect's file browsing is on")
    pt = {}
    kd.act(kid, "mountPoint", "sftp", None, "(s)", lambda v, e: pt.update(v=v))
    point = (pt.get("v") or ("",))[0] or dev["mounts"]["wifi"]["point"]
    mounts.add_mine(ctx.paths, point, dev["key"], now)
    return done(point=point)


def _ask_mtp(ctx, dev, wait=4.0):
    """A phone on adb whose USB functions lack MTP is asked for File transfer (`svc usb setFunctions mtp`) before the mount, and given up to
    `wait` s to show an MTP interface on the cable (adbd restarts at the switch: the cable's adb transport bounces once, which is expected)."""
    t = next((x for x in dev.get("_adbs", []) if x["state"] == "device" and x["transport"] == "usb"), None) or \
        next((x for x in dev.get("_adbs", []) if x["state"] == "device"), None)
    if t is None:
        return
    rc, out = _exec(argvlib.adb_usb_functions(t["serial"]), 8)
    if rc != 0 or "mtp" in out.lower():
        return
    _exec(argvlib.adb_usb_set_functions(t["serial"], "mtp"), 10)
    serial = (dev.get("usb") or {}).get("serial")
    end = time.time() + wait
    while serial and time.time() < end:
        if any(u["serial"] == serial and u["mtpIface"] for u in usblib.scan(ctx.paths.sys_root)):
            return
        time.sleep(0.25)


def cmd_unmount(ctx, args):
    if len(args) != 2 or args[1] not in ("usb", "wifi"):
        return fail(USAGE, "usage: unmount <dev> usb|wifi")
    dev = ctx.device(args[0])
    which = args[1]
    m = dev["mounts"][which]
    if m["state"] == "unmounted":
        return done(point=m["point"])
    if which == "wifi":
        kd = ctx.need_kdc()
        out = {}
        kd.act(dev["kdc"]["id"], "unmount", "sftp", None, "()", lambda v, e: out.update(e=e))
        if out.get("e"):
            return fail(FAILED, out["e"])
        # KDE Connect ends its sshfs and leaves the FUSE mount in the table: it read "mounted" for 42 s and then "stale" (the
        # user's trace, 2026-11-19). Gone within a moment, or this unmounts it itself (lazily: its server is gone)
        for _ in range(10):
            if not any(x["point"] == m["point"] for x in mounts.read(ctx.paths.mountinfo)):
                break
            time.sleep(0.1)
        else:
            rc, outp = _exec(argvlib.fusermount(m["point"], lazy=True), 15)
            if rc != 0 and any(x["point"] == m["point"] for x in mounts.read(ctx.paths.mountinfo)):
                return fail(FAILED, parse.last_error_line(outp) or "fusermount3 failed")
        mounts.drop_mine(ctx.paths, m["point"])
        return done(point=m["point"])
    if m["state"] == "stale" and not m["mine"]:
        return fail(REFUSED, "That mount is not ours", "Unmount it yourself: fusermount3 -uz %s" % m["point"])
    live = _live_job(ctx, dev["key"], "mount")
    if live:
        jobs.stop(ctx.paths, live["id"])
    rc, out = _exec(argvlib.fusermount(m["point"], lazy=m["state"] == "stale"), 15)
    if rc != 0:
        busy = "busy" in out
        return fail(FAILED, "The phone is busy: something is using it" if busy else parse.last_error_line(out) or "fusermount3 failed",
                    "Close whatever has files open there and try again" if busy else "")
    mounts.drop_mine(ctx.paths, m["point"])
    return done(point=m["point"])


# ---- sending, a shot, a key ---------------------------------------------------------------------------------------------
def _items(paths_in, dest):
    """[{remote, size}] for every file a push will carry (a folder is walked)."""
    items = []
    for p in paths_in:
        base = os.path.basename(p.rstrip("/"))
        if os.path.isdir(p):
            for root, _d, files in os.walk(p):
                for f in sorted(files):
                    full = os.path.join(root, f)
                    rel = os.path.relpath(full, os.path.dirname(p.rstrip("/")))
                    items.append({"remote": dest.rstrip("/") + "/" + rel, "size": _size(full)})
        else:
            items.append({"remote": dest.rstrip("/") + "/" + base, "size": _size(p)})
    return items


def _size(p):
    try:
        return os.path.getsize(p)
    except OSError:
        return 0


def cmd_send(ctx, args):
    args = list(args)
    via = ""
    if "--via" in args:
        i = args.index("--via")
        via = args[i + 1] if i + 1 < len(args) else ""
        del args[i:i + 2]
        if via not in ("adb", "kdeconnect"):
            return fail(USAGE, "--via is adb or kdeconnect")
    if len(args) < 2:
        return fail(USAGE, "usage: send <dev> [--via adb|kdeconnect] <path>...")
    dev = ctx.device(args[0])
    files = [os.path.abspath(p) for p in args[1:]]
    for p in files:
        if not os.path.exists(p):
            return fail(FAILED, "%s does not exist" % p)
    c = ctx.refuse_if(dev, "send")
    via = via or c["via"]
    if via == "kdeconnect":
        kd = ctx.need_kdc()
        if not dev["kdc"] or not dev["kdc"]["reachable"] or "share" not in dev["kdc"]["plugins"]:
            return fail(UNAVAILABLE, "Out of reach", "Same Wi-Fi as this computer")
        out = {}
        kd.act(dev["kdc"]["id"], "shareUrls", "share", GLib.Variant("(as)", (argvlib.share_urls(files),)), None,
               lambda v, e: out.update(e=e))
        if out.get("e"):
            return fail(FAILED, out["e"])
        return done(via="kdeconnect", job="")
    if not dev["adb"] and not dev["usb"] and not (dev["kdc"] and dev["kdc"]["reachable"]):
        return fail(UNAVAILABLE, "adb is not connected", caps.HINT_PLUG)
    serial, tvia = resolve_transport(ctx, dev, "send")
    dest = ctx.cfg["files"]["sendDir"]
    items = _items(files, dest)
    rec = jobs.blank("send", dev["key"], "", "adb", time.time(), id=jobs.next_id(ctx.paths, "send"), items=items, files=len(items),
                     total=sum(i["size"] for i in items), name=os.path.basename(items[0]["remote"]) if items else "")
    r = _start(ctx, rec, argvlib.adb_push(serial, files, dest), settle=("running", "done", "failed"), wait=3.0)
    if r["phase"] == "failed":
        jobs.remove(ctx.paths, rec["id"])
        return fail(FAILED, r.get("reason") or "adb push failed")
    return done(job=rec["id"], via="adb")


def cmd_shot(ctx, args):
    if len(args) != 1:
        return fail(USAGE, "usage: shot <dev>")
    dev = ctx.device(args[0])
    ctx.refuse_if(dev, "shot")
    serial, _via = resolve_transport(ctx, dev, "shot")
    t0 = time.time()
    try:
        r = subprocess.run(argvlib.adb_screencap(serial), stdin=subprocess.DEVNULL, capture_output=True, timeout=25)
    except (OSError, subprocess.TimeoutExpired) as e:
        trace.ran(argvlib.adb_screencap(serial), None, t0, str(e))
        return fail(FAILED, "screencap failed: %s" % e)
    trace.ran(argvlib.adb_screencap(serial), r.returncode, t0, "%d bytes; %s" % (len(r.stdout), r.stderr.decode("utf-8", "replace")))
    if r.returncode != 0 or not r.stdout.startswith(b"\x89PNG\r\n\x1a\n"):
        return fail(FAILED, parse.last_error_line(r.stderr.decode("utf-8", "replace")) or "the phone did not send a picture",
                    "Unlock the phone and try again (some apps block screenshots)")
    d = ctx.paths.expand(ctx.cfg["shots"]["dir"])
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, argvlib.shot_name(time.strftime("%Y%m%d-%H%M%S")))
    with open(path + ".part", "wb") as f:
        f.write(r.stdout)
    os.replace(path + ".part", path)
    return done(path=path)


def cmd_key(ctx, args):
    if len(args) != 2 or args[1] not in argvlib.KEYCODES:
        return fail(USAGE, "usage: key <dev> power|volup|voldown")
    dev = ctx.device(args[0])
    ctx.refuse_if(dev, "key")
    serial, _via = resolve_transport(ctx, dev, "key")
    rc, out = _exec(argvlib.adb_keyevent(serial, args[1]), 8)
    if rc != 0:
        return fail(FAILED, parse.last_error_line(out) or "the key did not go through")
    return done()


# ---- unlock: the PIN kept in the login keyring, typed over adb ------------------------------------------------------------
def _lockstate(serial):
    """The phone's lock state (parse.parse_lockstate), or None when it did not answer. One adb shell; what it prints is no secret."""
    rc, out = _exec(argvlib.adb_lockstate(serial, parse.LOCK_SCRIPT), 10)
    return parse.parse_lockstate(out) if rc == 0 and out.strip() else None


def cmd_lockstate(ctx, args):
    if len(args) != 1:
        return fail(USAGE, "usage: lockstate <dev>")
    dev = ctx.device(args[0])
    ctx.refuse_if(dev, "key")
    serial, _via = resolve_transport(ctx, dev, "key")
    ls = _lockstate(serial)
    if ls is None:
        return fail(FAILED, "the phone did not answer")
    return done(**ls)


def _pin_device(dev):
    """The keyring's `device` attribute: the KDE Connect id, else the device key."""
    return dev["kdc"]["id"] if dev["kdc"] else dev["key"]


def _set_pin_state(ctx, key, value):
    with ctx.state_lock():
        s = st.load_state(ctx.paths)
        if value == "none":
            s["pins"].pop(key, None)
        else:
            s["pins"][key] = value
        st.save_state(ctx.paths, s)


def _keyring_gate():
    """None when the keyring can be used, else the refusal. A locked keyring is never unlocked here (no prompt, ever)."""
    k = keyring.locked()
    if k is None:
        return fail(UNAVAILABLE, "No keyring is running", "Start the login keyring (gnome-keyring)")
    if k:
        return fail(UNAVAILABLE, "The keyring is locked", "It opens with your password at the lock screen")
    return None


def cmd_pin(ctx, args):
    """pin <dev> set (the PIN as ONE line on stdin) | pin <dev> forget. No answer carries the PIN."""
    if len(args) != 2 or args[1] not in ("set", "forget"):
        return fail(USAGE, "usage: pin <dev> set|forget  (set reads the PIN as one line on stdin)")
    dev = ctx.device(args[0])
    pin = ""
    if args[1] == "set":
        pin = sys.stdin.readline().rstrip("\r\n")
        if not keyring.valid(pin):
            return fail(USAGE, "a PIN is 4 to 16 letters or digits", "Nothing was stored")
    gate = _keyring_gate()
    if gate:
        return gate
    if args[1] == "set":
        if not keyring.store(_pin_device(dev), dev["name"], pin):
            return fail(FAILED, "The keyring would not keep the PIN")
        _set_pin_state(ctx, dev["key"], "set")
        jobs.clear_try(ctx.paths, dev["key"], "unlock")
    else:
        keyring.clear(_pin_device(dev))
        _set_pin_state(ctx, dev["key"], "none")
    return done()


@contextlib.contextmanager
def _one_unlock(ctx):
    """A non-blocking flock: a second unlock while one runs is refused, never queued (two would type the PIN twice)."""
    ctx.paths.ensure()
    fd = os.open(os.path.join(ctx.paths.state, "unlock.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            yield False
            return
        yield True
    finally:
        os.close(fd)


def _utrace(**kw):
    trace.write(None, "unlock", **kw)


def cmd_unlock(ctx, args):
    """Wake the phone, bring up its PIN pad and type the kept PIN over adb -- only into the lock screen, and a PIN that failed is never
    typed again until it is set again (Android throttles and escalates wrong attempts). `--auto` only marks the trace."""
    key, opts = _positional(args, 1, {"--auto": 0})
    dev = ctx.device(key[0])
    ctx.refuse_if(dev, "unlock")
    with _one_unlock(ctx) as got:
        if not got:
            return fail(REFUSED, "Already unlocking")
        return _unlock(ctx, dev, "--auto" in opts)


def _dismiss(serial, ls):
    """The phone says it is unlocked (trust: Smart Lock, a trusted place) while its lock screen still shows -- a swipe-only lock screen. Wake it
    and ask for the keyguard to go (`wm dismiss-keyguard`): no PIN, no keyring. Done when a read says it is gone."""
    _utrace(step="dismiss")
    _exec(argvlib.adb_key(serial, "KEYCODE_WAKEUP"), 8)
    _exec(argvlib.adb_dismiss_keyguard(serial), 8)
    for _ in range(6):
        time.sleep(0.4)
        ls = _lockstate(serial)
        _utrace(step="lockstate", after="dismiss", **(ls or {"answer": None}))
        if ls is not None and not ls["keyguard"] and not ls["locked"]:
            return done(unlocked=True, dismissed=True)
    return fail(FAILED, "The lock screen did not go away", "Swipe it on the phone")


def _unlock(ctx, dev, auto):
    serial, via = resolve_transport(ctx, dev, "unlock")
    _utrace(step="start", auto=auto, via=via)
    ls = _lockstate(serial)
    _utrace(step="lockstate", **(ls or {"answer": None}))
    if ls is None:
        return fail(FAILED, "the phone did not answer")
    if not ls["locked"]:
        if not ls["keyguard"]:
            return done(unlocked=True, already=True)
        return _dismiss(serial, ls)
    gate = _keyring_gate()
    if gate:
        _utrace(step="keyring", refused=gate[0]["reason"])
        return gate
    pin = keyring.lookup(_pin_device(dev))
    if pin is None:
        _set_pin_state(ctx, dev["key"], "none")
        _utrace(step="nopin")
        return fail(UNAVAILABLE, "No PIN kept", "Set it on the Details page")
    _exec(argvlib.adb_key(serial, "KEYCODE_WAKEUP"), 8)
    _exec(argvlib.adb_dismiss_keyguard(serial), 8)
    time.sleep(0.5)
    ls = _lockstate(serial)
    _utrace(step="lockstate", after="wake", **(ls or {"answer": None}))
    if ls is not None and not ls["locked"]:
        return done(unlocked=True)
    if ls is None or ls["focus"] != "keyguard" or not ls["awake"]:
        # never type into an app, or into a phone that is not awake
        _utrace(step="refused", why="the lock screen is not in front")
        reason = "The lock screen did not take the keys" if ls and ls["awake"] else "The phone did not wake"
        jobs.record_try(ctx.paths, dev["key"], "unlock", reason, "Wake the phone and try again", time.time())
        return fail(FAILED, reason, "Wake the phone and try again")
    # the PIN goes on a pipe into the phone's shell: no argv, no trace of it, its output is not read
    t0 = time.time()
    try:
        rc = subprocess.run(argvlib.adb_shell_stdin(serial), input="input text %s\n" % pin, capture_output=True, text=True,
                            timeout=10).returncode
    except (subprocess.TimeoutExpired, OSError):
        rc = 124
    pin = None
    _utrace(step="typed", rc=rc, ms=int((time.time() - t0) * 1000))
    if rc != 0:
        return fail(FAILED, "The phone did not take the PIN", "Try again")
    time.sleep(0.6)
    ls = _lockstate(serial)
    answered = ls is not None
    _utrace(step="lockstate", after="typed", **(ls or {"answer": None}))
    if ls is not None and ls["locked"] and ls["focus"] == "keyguard":
        _exec(argvlib.adb_key(serial, "KEYCODE_ENTER"), 8)     # a PIN pad without auto-confirm waits for it; one with it needs none
        _utrace(step="enter")
    end = time.time() + 2.5
    while True:
        if ls is not None and not ls["locked"]:
            _utrace(step="unlocked")
            return done(unlocked=True)
        if time.time() >= end:
            break
        time.sleep(0.35)
        ls = _lockstate(serial)
        answered = answered or ls is not None
    if not answered:
        return fail(FAILED, "the phone did not answer", "Check the link and look at the phone")
    # still locked: this PIN is never typed again until it is set again
    _set_pin_state(ctx, dev["key"], "failed")
    _utrace(step="failed")
    return fail(FAILED, "The PIN did not unlock the phone", "Set it again on the Details page")


# ---- KDE Connect ---------------------------------------------------------------------------------------------------------
def _kdc_do(ctx, args, name, method, plugin=None, action=None, paired_only=False):
    """One KDE Connect method for a device key (a pairing entry's `kdc:<id>` works too); `can.<action>` gates it when the device is
    listed, and `paired_only` refuses a device that is only in the pairing list."""
    if len(args) != 1:
        raise Stop(USAGE, "usage: %s <dev>" % name)
    key = args[0]
    listed = next((d for d in ctx.line()["devices"] if d["key"] == key), None)
    if listed and action:
        ctx.refuse_if(listed, action)
    if not listed and paired_only:
        raise Stop(UNAVAILABLE, "The phone is not paired", "Pair it first")
    kd = ctx.need_kdc()
    out = {}
    kd.act(ctx.kdc_id(key), method, plugin, None, None, lambda v, e: out.update(e=e))
    return fail(FAILED, out["e"]) if out.get("e") else done()


def cmd_ring(ctx, args):
    return _kdc_do(ctx, args, "ring", "ring", "findmyphone", "ring", True)


def cmd_clip(ctx, args):
    return _kdc_do(ctx, args, "clip", "sendClipboard", "clipboard", "clip", True)


def cmd_pair(ctx, args):
    return _kdc_do(ctx, args, "pair", "requestPairing", None, "pair")


def cmd_accept(ctx, args):
    return _kdc_do(ctx, args, "accept", "acceptPairing")


def cmd_reject(ctx, args):
    return _kdc_do(ctx, args, "reject", "cancelPairing")


def cmd_unpair(ctx, args):
    return _kdc_do(ctx, args, "unpair", "unpair", None, "unpair", True)


def cmd_refresh(ctx, args):
    kd = ctx.need_kdc()
    out = {}
    kd.refresh(lambda v, e: out.update(e=e))
    return fail(FAILED, out["e"]) if out.get("e") else done()


# ---- arming, prefs, selection, facts ------------------------------------------------------------------------------------
def cmd_arm(ctx, args):
    if len(args) != 1:
        return fail(USAGE, "usage: arm <dev>")
    dev = ctx.device(args[0])
    ctx.refuse_if(dev, "arm")
    serial = _usb_serial(ctx, dev)
    port = ctx.cfg["adb"]["port"]
    # ARMED ALREADY? `adb tcpip` restarts adbd, which re-enumerates the phone on the bus: to the watcher that is a NEW plug-in,
    # whose arming restarted adbd again -- an endless replug every ~1.3 s (the user's phone, 2026-11-19: 166 disconnects in
    # 97 minutes). The phone says whether adb listens on the port; a phone that does is left alone.
    rc, out = _exec(argvlib.adb("shell", "getprop service.adb.tcp.port", serial=serial), 8)
    if rc == 0 and out.strip() == str(port):
        return done(port=port, already=True)
    # paired for Wireless debugging: switch it on too while the cable is there (after a restart it is the quick tile's)
    if dev["prefs"].get("wifiDebug"):
        _exec(argvlib.adb("shell", "settings put global adb_wifi_enabled 1", serial=serial), 8)
    rc, out = _exec(argvlib.adb_tcpip(serial, port), 10)
    if rc != 0:
        return fail(FAILED, parse.last_error_line(out) or "adb tcpip failed")
    return done(port=port)


PAIR_WAIT_S = 150


def cmd_wifipair(ctx, args):
    """Starts a Wireless debugging pairing: a QR code (wifipair.png) for the phone's "Pair device with QR code", and a detached
    `_pairwait` that finds the phone's pairing service by the code's name and runs `adb pair`. Its progress is wifipair.json
    (the watcher's `wifiPair`). The password lives in the QR code and the helper's environment, never in a file."""
    if len(args) not in (1, 2) or (len(args) == 2 and args[1] != "cancel"):
        return fail(USAGE, "usage: wifipair <dev> [cancel]")
    dev = ctx.device(args[0])
    if len(args) == 2:
        for f in (ctx.paths.wifipair, ctx.paths.wifipair_png):
            try:
                os.unlink(f)
            except OSError:
                pass
        return done()
    up, err = adbctl.need(ctx.paths, ctx.cfg, ctx.tool)
    if not up:
        return fail(UNAVAILABLE, "adb could not start: %s" % err)
    import secrets
    from . import qr
    name = "lares-%06x" % secrets.randbelow(1 << 24)
    pw = "%010d" % secrets.randbelow(10 ** 10)
    ctx.paths.ensure()
    qr.png("WIFI:T:ADB;S:%s;P:%s;;" % (name, pw), ctx.paths.wifipair_png)
    rec = {"key": dev["key"], "name": name, "state": "waiting", "reason": "", "png": ctx.paths.wifipair_png, "at": int(time.time())}
    st.write_private(ctx.paths.wifipair, rec)
    subprocess.Popen([ctx.tool, "_pairwait", dev["key"], name], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True, env=dict(os.environ, LARES_PAIR_PW=pw))
    return done(name=name, png=ctx.paths.wifipair_png)


def pair_wait(paths, cfg, tool, key, name, pw, sleep=time.sleep):
    """`_pairwait`: until the phone shows the pairing service the QR code named, then `adb pair`. Ends at once when another
    pairing took the file over (a newer QR code) or after PAIR_WAIT_S."""
    def mine():
        r = st.read_json(paths.wifipair, {})
        return r if r.get("name") == name else None

    def finish(state, reason=""):
        r = mine()
        if r is not None:
            r.update(state=state, reason=reason, at=int(time.time()))
            st.write_private(paths.wifipair, r)
    end = time.time() + PAIR_WAIT_S
    while time.time() < end:
        if mine() is None:
            return 0
        rc, out = _exec(argvlib.adb("mdns", "services"), 6)
        hit = next((m for m in parse.parse_mdns_pairing(out) if m["instance"] == name), None) if rc == 0 else None
        if hit:
            rc, out = _exec(argvlib.adb("pair", "%s:%d" % (hit["ip"], hit["port"]), pw), 20)
            if rc == 0 and "Successfully paired" in out:
                ctx = Ctx(paths, cfg, tool)
                with ctx.state_lock():
                    s = st.load_state(paths)
                    s["prefs"].setdefault(key, {})["wifiDebug"] = True
                    st.save_state(paths, s)
                finish("paired")
                return 0
            finish("failed", parse.last_error_line(out) or "adb pair failed")
            return 1
        sleep(1.0)
    finish("expired", "The phone did not show up")
    return 1


def cmd_disarm(ctx, args):
    if len(args) != 1:
        return fail(USAGE, "usage: disarm <dev>")
    dev = ctx.device(args[0])
    serial, _v = resolve_transport(ctx, dev, "arm")
    rc, out = _exec(argvlib.adb("usb", serial=serial), 10)
    if rc != 0:
        return fail(FAILED, parse.last_error_line(out) or "adb usb failed")
    return done()


def _usb_serial(ctx, dev):
    adbusb = next((t["serial"] for t in dev.get("_adbs", []) if t["transport"] == "usb" and t["state"] == "device"), None)
    if not adbusb:
        raise Stop(UNAVAILABLE, "The phone is not plugged in", "Plug it in with a cable (arming needs it once)")
    up, err = adbctl.need(ctx.paths, ctx.cfg, ctx.tool)
    if not up:
        raise Stop(UNAVAILABLE, "adb could not start: %s" % err)
    return adbusb


def cmd_usbcalm(ctx, args):
    """usbcalm <dev> [off|on] (default off). Android's "Default USB configuration = File transfer" makes the phone switch its USB functions at
    every lock (-> adb) and unlock (-> mtp,adb), and each switch restarts adbd: every adb link drops for ~300 ms, Wi-Fi included, and a cast
    dies. off = `svc usb setScreenUnlockedFunctions` with no function; on = `mtp`, the phone's way back. The choice is kept in the device's
    prefs (`usbUnlockMtp` = on) and read back from the phone. -> {usbUnlocked: "none" | "mtp" | ...}"""
    if len(args) not in (1, 2) or (len(args) == 2 and args[1] not in ("off", "on")):
        return fail(USAGE, "usage: usbcalm <dev> [off|on]")
    on = len(args) == 2 and args[1] == "on"
    dev = ctx.device(args[0])
    ctx.refuse_if(dev, "key")
    serial, _via = resolve_transport(ctx, dev, "key")
    rc, out = _exec(argvlib.adb_usb_calm(serial, on), 15)
    if rc != 0:
        return fail(FAILED, parse.last_error_line(out) or "the phone did not take it")
    with ctx.state_lock():
        s = st.load_state(ctx.paths)
        s["prefs"].setdefault(dev["key"], {})["usbUnlockMtp"] = on
        st.save_state(ctx.paths, s)
    rc, out = _exec(argvlib.adb_usb_unlocked(serial), 10)
    if rc != 0:
        return fail(FAILED, parse.last_error_line(out) or "the phone did not answer")
    return done(usbUnlocked=parse.parse_usb_unlocked(out))


def cmd_set(ctx, args):
    if len(args) != 3:
        return fail(USAGE, "usage: set <dev> <pref> <json value>")
    key, name, raw = args
    try:
        value = json.loads(raw)
    except ValueError:
        return fail(USAGE, "the value must be JSON (true, false, \"mirror\")")
    good, why = st.check_pref(name, value)
    if not good:
        return fail(USAGE, why)
    ctx.device(key)
    with ctx.state_lock():
        s = st.load_state(ctx.paths)
        s["prefs"].setdefault(key, {})[name] = value
        st.save_state(ctx.paths, s)
    return done()


def cmd_select(ctx, args):
    if len(args) != 1:
        return fail(USAGE, "usage: select <dev>")
    ctx.device(args[0])
    with ctx.state_lock():
        s = st.load_state(ctx.paths)
        s["current"] = args[0]
        st.save_state(ctx.paths, s)
    return done()


def cmd_facts(ctx, args):
    if len(args) != 1:
        return fail(USAGE, "usage: facts <dev>")
    dev = ctx.device(args[0])
    ctx.refuse_if(dev, "facts")
    serial, _via = resolve_transport(ctx, dev, "facts")
    rc, out = _exec(argvlib.adb_facts(serial, parse.FACTS_SCRIPT), 20)
    if rc != 0:
        return fail(FAILED, parse.last_error_line(out) or "the phone did not answer")
    f = parse.parse_facts_blob(out)
    if not f:
        return fail(FAILED, "the phone's answer could not be read")
    f["at"] = int(time.time())
    with ctx.state_lock():
        s = st.load_state(ctx.paths)
        s["facts"][dev["key"]] = f
        st.save_state(ctx.paths, s)
    return done(facts=f)


def cmd_doctor(ctx, args):
    w = ctx.world()
    rows = doctor.rows(ctx.paths, ctx.cfg, model.env_of(w))
    return {"ok": all(r["ok"] for r in rows), "rows": rows}, OK


def _positional(args, n, flags):
    """(positionals, {flag: value}) -- a tiny parser; raises Stop(USAGE) on a stranger."""
    pos, opts, i = [], {}, 0
    while i < len(args):
        a = args[i]
        if a in flags:
            if flags[a]:
                if i + 1 >= len(args):
                    raise Stop(USAGE, "%s needs a value" % a)
                opts[a] = args[i + 1]
                i += 1
            else:
                opts[a] = True
        elif a.startswith("--"):
            raise Stop(USAGE, "unknown option %s" % a)
        else:
            pos.append(a)
        i += 1
    if len(pos) != n:
        raise Stop(USAGE, "expected %d device argument(s)" % n)
    return pos, opts


COMMANDS = {
    "mirror": cmd_mirror, "stop": cmd_stop, "mount": cmd_mount, "unmount": cmd_unmount, "send": cmd_send, "shot": cmd_shot,
    "ring": cmd_ring, "clip": cmd_clip, "key": cmd_key, "pair": cmd_pair, "accept": cmd_accept, "reject": cmd_reject,
    "unpair": cmd_unpair, "refresh": cmd_refresh, "arm": cmd_arm, "disarm": cmd_disarm, "set": cmd_set, "select": cmd_select,
    "facts": cmd_facts, "ack": cmd_ack, "doctor": cmd_doctor, "wifipair": cmd_wifipair, "castprep": cmd_castprep, "castend": cmd_castend,
    "lockstate": cmd_lockstate, "pin": cmd_pin, "unlock": cmd_unlock, "usbcalm": cmd_usbcalm,
}
