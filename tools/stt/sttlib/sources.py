"""The focused window's processes (round 5, the two new takes): whose audio a window take records, and where a voice ask runs.

THE WINDOW TAKE (fn+Ctrl+F10). The shell names the window that had the focus at the press (its pid, from `hyprctl -j activewindow`);
a browser, an Electron app or a player plays its sound from that process, a child of it (Chromium's audio service, Firefox's content
processes) or now and then a parent. `ProcTree` says which pids belong to the window: the window's pid, every DESCENDANT of it (asked
per pid by walking its parents: a process started after the press counts), and the window's own ANCESTORS -- their own pids only,
never their other children (a terminal that started the app holds every other shell), up to the first one that is the session's
(the compositor, systemd, init, a display manager, the shell itself; at most `ANCESTORS` of them).

`StreamWatch` follows PipeWire through ONE `pw-dump -m` child for the take (the whole graph, then each change as it happens) and links
every OUTPUT stream (`Stream/Output/Audio`) whose process belongs to the window into the take's capture -- a pw-record of its own with
`node.autoconnect = false`, so nothing else ever links it -- with `pw-link`, port to port by channel (FL -> FL, FR -> FR; mono and the
centre into both; the rear and the surround to their side; LFE nowhere). A stream that appears during the take is linked when it
appears, one that goes is forgotten (its links go with its ports). Nothing else is linked, no stream's target, volume or the default
nodes are touched, and the links end with the capture. A stream's process is `application.process.id` on the node, else on its
client (a native client says it there), else the client's `pipewire.sec.pid` (the socket's own; for a pulse client that is
pipewire-pulse's, which is never a window's). What it links is told as `sources` events: every change of the matched set.

THE VOICE ASK (Alt+fn+F10). `terminal_cwd(pid, title)`: when the window is a terminal (kitty, foot, alacritty: its children are
shells on ttys), the directory of the shell under it -- the only one, or the one whose tty's foreground process the window's title
names (kitty titles a window by what runs in it). Shells it cannot tell apart give "" (the ask then runs in the home directory).

Everything here reads /proc (or a fake root, the probe's) and starts only `pw-dump` and `pw-link`; nothing heavy is imported.
"""
import json
import os
import signal
import subprocess
import threading

# A process the window's ancestry stops at: the session's own, whose other children are every app
STOP_COMMS = {"systemd", "init", "Hyprland", "start-hyprland", "uwsm", "sddm", "sddm-helper", "login", "gdm", "greetd",
              "dbus-daemon", "dbus-broker", "quickshell", "qs", "kwin_wayland", "sway", "mutter", "gnome-shell"}
ANCESTORS = 4
SHELLS = {"bash", "zsh", "fish", "sh", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "xonsh", "elvish", "ion", "oil", "osh", "ysh"}
CAPTURE_NAME = "lares-dictation-window"
# a stream's channel -> the capture's channels it goes into (a stereo capture, downmixed to mono by the helper)
CHANNEL_MAP = {"MONO": ("FL", "FR"), "FC": ("FL", "FR"), "FL": ("FL",), "FR": ("FR",), "RL": ("FL",), "RR": ("FR",),
               "SL": ("FL",), "SR": ("FR",), "FLC": ("FL",), "FRC": ("FR",), "RC": ("FL", "FR"), "LFE": ()}


def _pdeathsig():
    import ctypes

    ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, signal.SIGTERM)       # PR_SET_PDEATHSIG


class ProcTree:
    """Which pids belong to the window whose process is `root` (a fake `proc` root for the probe)."""

    def __init__(self, root_pid, proc="/proc"):
        self.proc = proc
        self.root = int(root_pid or 0)
        self.ancestors = self._ancestors()
        self._cache = {}

    def stat(self, pid):
        """(comm, ppid, tty_nr, tpgid) from /proc/<pid>/stat, or None."""
        try:
            with open("%s/%d/stat" % (self.proc, pid), "rb") as f:
                s = f.read().decode("utf-8", "replace")
        except (OSError, ValueError):
            return None
        a, b = s.find("("), s.rfind(")")
        if a < 0 or b < a:
            return None
        rest = s[b + 2:].split()
        try:
            return s[a + 1: b], int(rest[1]), int(rest[4]), int(rest[5])
        except (IndexError, ValueError):
            return None

    def _ancestors(self):
        out, pid = [], self.root
        for _ in range(ANCESTORS):
            st = self.stat(pid)
            if st is None or st[1] <= 1:
                break
            pst = self.stat(st[1])
            if pst is None or pst[0] in STOP_COMMS:
                break
            pid = st[1]
            out.append(pid)
        return out

    def owns(self, pid):
        """The pid is the window's: the window itself, one of its descendants, or one of its own ancestors."""
        pid = int(pid or 0)
        if pid <= 0 or self.root <= 0:
            return False
        if pid in self._cache:
            return self._cache[pid]
        hit = pid == self.root or pid in self.ancestors
        p = pid
        for _ in range(64):
            if hit:
                break
            st = self.stat(p)
            if st is None or st[1] <= 1:
                break
            p = st[1]
            hit = p == self.root
        self._cache[pid] = hit
        return hit

    def children(self, pid):
        out = []
        try:
            names = os.listdir(self.proc)
        except OSError:
            return out
        for n in names:
            if n.isdigit():
                st = self.stat(int(n))
                if st is not None and st[1] == pid:
                    out.append(int(n))
        return sorted(out)


def _cmdline(proc, pid):
    try:
        with open("%s/%d/cmdline" % (proc, pid), "rb") as f:
            return [x.decode("utf-8", "replace") for x in f.read().split(b"\0") if x]
    except OSError:
        return []


def _readlink(proc, pid):
    try:
        return os.readlink("%s/%d/cwd" % (proc, pid))
    except OSError:
        return ""


def terminal_cwd(pid, title="", proc="/proc"):
    """(cwd, why): the directory of the shell under a terminal window, or "" and why not."""
    t = ProcTree(pid, proc)
    if t.root <= 0:
        return "", "no window"
    shells = []
    for c in t.children(t.root):
        st = t.stat(c)
        if st is not None and st[0] in SHELLS and st[2] != 0:
            shells.append((c, st))
    if not shells:
        return "", "not a terminal"
    if len(shells) > 1:
        # kitty titles a window by what runs in it: the shell whose tty's foreground process the title names
        words = set((title or "").lower().replace("/", " ").split())
        named = []
        for c, st in shells:
            fg = t.stat(st[3]) if st[3] > 0 else None
            argv = _cmdline(proc, st[3]) if st[3] > 0 else []
            names = {fg[0].lower()} if fg else set()
            if argv:
                names.add(os.path.basename(argv[0]).lower())
            if names & words:
                named.append((c, st))
        if len(named) != 1:
            # kitty's shell integration titles an idle window by its directory ("~", "~/src/x", "/etc")
            home = os.path.expanduser("~")
            want = (title or "").strip()
            want = home + want[1:] if want.startswith("~") else want
            if not named and want.startswith("/"):
                named = [(c, st) for c, st in shells if _readlink(proc, c) == (want.rstrip("/") or "/")]
        if len(named) != 1:
            return "", "%d shells, the title names %d" % (len(shells), len(named))
        shells = named
    try:
        return os.readlink("%s/%d/cwd" % (proc, shells[0][0])), "shell %d" % shells[0][0]
    except OSError as e:
        return "", "cwd unreadable: %s" % e.strerror


class StreamWatch:
    """Links the window's output streams into the capture whose pw-record runs as `capture_pid`, for as long as it runs."""

    def __init__(self, window_pid, capture_pid, emit, take, proc="/proc", link_cmd=None, dump_cmd=None, match_all=False):
        self.tree = ProcTree(window_pid, proc)
        self.capture_pid = int(capture_pid or 0)
        self.emit = emit
        self.take = take
        self.link_cmd = link_cmd or ["pw-link"]
        self.match_all = match_all            # the probe's ARM linkall: every output stream (a fault)
        self.objs = {}                        # id -> the object as pw-dump last gave it
        self.linked = set()                   # (out port id, in port id) asked for
        self.matched = {}                     # stream node id -> its record
        self.seen = []                        # every stream ever matched this take (the take log), by serial, in order
        self.errors = []
        self._told = False                    # the first picture is told even when it holds no stream ("no sound yet")
        self._lock = threading.Lock()
        self._p = None
        self._stopped = False
        if dump_cmd is not False:
            self._p = subprocess.Popen(dump_cmd or ["pw-dump", "-m", "-N"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                       stdin=subprocess.DEVNULL, preexec_fn=_pdeathsig)
            self._t = threading.Thread(target=self._reader, daemon=True)
            self._t.start()

    # ---- pw-dump -m: a JSON array per batch of changes; an object with "info": null is gone -------------------------------------
    def _reader(self):
        dec = json.JSONDecoder()
        buf = ""
        fd = self._p.stdout.fileno()
        while True:
            try:
                b = os.read(fd, 65536)
            except OSError:
                break
            if not b:
                break
            buf += b.decode("utf-8", "replace")
            while True:
                i = 0
                while i < len(buf) and buf[i].isspace():
                    i += 1
                if i >= len(buf):
                    buf = ""
                    break
                try:
                    batch, end = dec.raw_decode(buf, i)
                except ValueError:
                    if len(buf) > 32 << 20:
                        buf = ""                  # never a runaway buffer: the next batch starts afresh
                    break
                buf = buf[end:]
                if isinstance(batch, list):
                    self.feed(batch)

    def feed(self, batch):
        """One batch of pw-dump objects (the probe feeds canned ones)."""
        with self._lock:
            if self._stopped:
                return
            for o in batch:
                if not isinstance(o, dict) or "id" not in o:
                    continue
                if o.get("info") is None:
                    self.objs.pop(o["id"], None)
                else:
                    self.objs[o["id"]] = o
            self._reconcile()

    @staticmethod
    def _kind(o):
        return (o.get("type") or "").rsplit(":", 1)[-1]

    @staticmethod
    def _props(o):
        return ((o or {}).get("info") or {}).get("props") or {}

    def _pids(self, node):
        """Every pid a node's stream may be told by: its own, its client's claim, the client's socket."""
        p = self._props(node)
        out = []
        if p.get("application.process.id") is not None:
            out.append(p.get("application.process.id"))
        cl = self.objs.get(p.get("client.id"))
        cp = self._props(cl)
        for k in ("application.process.id", "pipewire.sec.pid"):
            if cp.get(k) is not None:
                out.append(cp.get(k))
        res = []
        for v in out:
            try:
                res.append(int(v))
            except (TypeError, ValueError):
                pass
        return res

    def _reconcile(self):
        nodes = {i: o for i, o in self.objs.items() if self._kind(o) == "Node"}
        cap = None
        for i, o in nodes.items():
            p = self._props(o)
            if p.get("media.class") == "Stream/Input/Audio" and p.get("node.name") == CAPTURE_NAME and self.capture_pid in self._pids(o):
                cap = i
        ports = [o for o in self.objs.values() if self._kind(o) == "Port"]
        cap_in = {}
        for o in ports:
            p = self._props(o)
            if cap is not None and p.get("node.id") == cap and (o.get("info") or {}).get("direction") == "input":
                cap_in[str(p.get("audio.channel") or "MONO")] = o["id"]
        matched = {}
        for i, o in nodes.items():
            p = self._props(o)
            if p.get("media.class") != "Stream/Output/Audio" or str(p.get("node.name", "")).startswith("lares-"):
                continue
            pids = self._pids(o)
            if not (self.match_all or any(self.tree.owns(x) for x in pids)):
                continue
            matched[i] = {"node": i, "serial": p.get("object.serial"), "app": str(p.get("application.name") or ""),
                          "media": str(p.get("media.name") or ""), "pid": pids[0] if pids else 0}
        # the links: every output port of a matched stream into the capture's ports for its channel
        existing = set()
        for o in self.objs.values():
            if self._kind(o) == "Link":
                inf = o.get("info") or {}
                existing.add((inf.get("output-port-id"), inf.get("input-port-id")))
        want = []
        if cap_in:
            for o in ports:
                p = self._props(o)
                if p.get("node.id") in matched and (o.get("info") or {}).get("direction") == "output":
                    ch = str(p.get("audio.channel") or "MONO")
                    targets = CHANNEL_MAP.get(ch, ("FL", "FR"))
                    if "MONO" in cap_in:                  # a mono capture (no session manager configured it stereo)
                        targets = ("MONO",) if targets else ()
                    for t in targets:
                        if t in cap_in:
                            want.append((o["id"], cap_in[t]))
        for pair in want:
            if pair in existing or pair in self.linked:
                continue
            self.linked.add(pair)
            r = subprocess.run(self.link_cmd + [str(pair[0]), str(pair[1])], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.PIPE, timeout=5)
            if r.returncode != 0 and b"File exists" not in r.stderr:
                self.errors.append(r.stderr.decode("utf-8", "replace").strip()[:120])
        # forget the links of ports that are gone (a port id may come back as another port)
        alive = {o["id"] for o in ports}
        self.linked = {pr for pr in self.linked if pr[0] in alive and pr[1] in alive}
        if set(matched) != set(self.matched) or not self._told:
            self._told = True
            self.matched = matched
            for m in matched.values():
                if m["serial"] not in [s["serial"] for s in self.seen]:
                    self.seen.append(dict(m))
            self.emit({"ev": "sources", "take": self.take, "streams": sorted(matched.values(), key=lambda m: m["node"]),
                       "capture": cap is not None, "ports": len(cap_in)})

    def stop(self):
        with self._lock:
            self._stopped = True
        if self._p is not None and self._p.poll() is None:
            self._p.terminate()
            try:
                self._p.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self._p.kill()
