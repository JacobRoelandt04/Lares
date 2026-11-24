"""What a terminal is running, read from /proc (the root is a parameter: tests hand a fake tree).

For one kitty process: its children on a pts are the windows' root programs (kitty's own helpers, `kitten __atexit__`
and `__watch_conf__`, have no terminal). A root that is an interactive shell is AT ITS PROMPT when the terminal's
foreground process group (`tpgid`) is the shell's own; otherwise the foreground group is the JOB, and its "tops" (the
members whose parent is not a member) are the commands of the line: one top is a simple command, several are a pipeline.

The argv read here is the REAL one: an alias has been expanded (`lg` reads `lazygit`), so a rule that judges argv cannot
be fooled by a name. What the user typed comes from the bash hook's mark, when there is one (session-hook.bash).
"""
import json
import os

SHELLS = {"bash", "zsh", "fish", "sh", "dash", "ksh", "nu", "elvish", "xonsh"}


def _tty_minor(tty_nr):
    return (tty_nr & 0xFF) | ((tty_nr >> 12) & 0xFFF00)


def _tty_major(tty_nr):
    return (tty_nr >> 8) & 0xFFF


def is_pts(tty_nr):
    return 136 <= _tty_major(tty_nr) <= 143


class Proc:
    def __init__(self, root="/proc"):
        self.root = root
        self._by_pgrp = None

    def _read(self, pid, name, binary=False):
        try:
            with open(os.path.join(self.root, str(pid), name), "rb") as f:
                b = f.read()
        except OSError:
            return None
        return b if binary else b.decode("utf-8", "replace")

    def cmdline(self, pid):
        b = self._read(pid, "cmdline", True)
        if not b:
            return []
        parts = b.split(b"\0")
        if parts and parts[-1] == b"":
            parts.pop()
        return [p.decode("utf-8", "replace") for p in parts]

    def environ(self, pid):
        b = self._read(pid, "environ", True)
        env = {}
        for item in (b or b"").split(b"\0"):
            k, sep, v = item.partition(b"=")
            if sep:
                env[k.decode("utf-8", "replace")] = v.decode("utf-8", "replace")
        return env

    def cwd(self, pid):
        try:
            return os.readlink(os.path.join(self.root, str(pid), "cwd"))
        except OSError:
            return None

    def exe(self, pid):
        try:
            return os.readlink(os.path.join(self.root, str(pid), "exe"))
        except OSError:
            return None

    def stat(self, pid):
        """comm, state, ppid, pgrp, session, tty_nr, tpgid -- the comm may hold spaces and parentheses."""
        s = self._read(pid, "stat")
        if not s:
            return None
        lp, rp = s.find("("), s.rfind(")")
        if lp < 0 or rp < 0:
            return None
        rest = s[rp + 2:].split()
        try:
            return {"pid": int(pid), "comm": s[lp + 1:rp], "state": rest[0], "ppid": int(rest[1]),
                    "pgrp": int(rest[2]), "session": int(rest[3]), "tty_nr": int(rest[4]), "tpgid": int(rest[5])}
        except (IndexError, ValueError):
            return None

    def euid(self, pid):
        s = self._read(pid, "status") or ""
        for line in s.splitlines():
            if line.startswith("Uid:"):
                f = line.split()
                try:
                    return int(f[2])
                except (IndexError, ValueError):
                    return None
        return None

    def cgroup(self, pid):
        s = self._read(pid, "cgroup") or ""
        return s.strip().rsplit(":", 1)[-1] if s else ""

    def children(self, pid):
        s = self._read(pid, "task/%s/children" % pid)
        if s is not None:
            return [int(x) for x in s.split()]
        return [st["pid"] for st in self._all() if st["ppid"] == int(pid)]

    def _all(self):
        out = []
        try:
            names = os.listdir(self.root)
        except OSError:
            return out
        for n in names:
            if n.isdigit():
                st = self.stat(n)
                if st:
                    out.append(st)
        return out

    def group(self, pgrp):
        """Every process of a process group (one scan of the tree per Proc, kept)."""
        if self._by_pgrp is None:
            idx = {}
            for st in self._all():
                idx.setdefault(st["pgrp"], []).append(st)
            self._by_pgrp = idx
        return sorted(self._by_pgrp.get(pgrp, []), key=lambda st: st["pid"])

    def forget(self):
        self._by_pgrp = None


def _is_interactive_shell(st, argv):
    if st["comm"] not in SHELLS and os.path.basename(argv[0] if argv else "").lstrip("-") not in SHELLS:
        return False
    # `sh -c 'cmd'` is a wrapper, not a prompt.
    return not any(a == "-c" or (a.startswith("-") and not a.startswith("--") and "c" in a[1:]) for a in argv[1:])


def read_mark(runtime_dir, tty_nr):
    """The hook's record of the running line: {"kind", "alias", "text", "words": {word: {"kind", "alias"}}} or None.

    `words` names every word of the line that is a command (the hook's triples; none from a hook older than them)."""
    if not runtime_dir or not is_pts(tty_nr):
        return None
    path = os.path.join(runtime_dir, "lares-session", "tty", "pts-%d" % _tty_minor(tty_nr))
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            data = f.read()
    except OSError:
        return None
    lines = data.split("\n")
    if len(lines) < 3:
        return None
    text = "\n".join(lines[2:]).rstrip("\n")
    if not text.strip():
        return None
    head = lines[0].split("\t")
    words = {}
    for i in range(1, len(head) - 2, 3):
        if head[i] and head[i] not in words:
            words[head[i]] = {"kind": head[i + 1], "alias": head[i + 2]}
    return {"kind": head[0].strip(), "alias": lines[1], "text": text, "words": words}


def claude_session(home, pid):
    """Claude Code keeps `~/.claude/sessions/<pid>.json` for a running session: its id resumes it."""
    try:
        with open(os.path.join(home, ".claude", "sessions", "%d.json" % pid), encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return None
    sid = d.get("sessionId") if isinstance(d, dict) else None
    if isinstance(sid, str) and sid and all(c.isalnum() or c in "-_" for c in sid):
        return sid
    return None


def ancestry(proc, pid):
    """`pid` and its ancestors: the processes that are the one asking (a `lares session save` typed in a terminal
    is that terminal's foreground job, and is no part of the session)."""
    out, seen = set(), 0
    while pid and pid > 1 and seen < 64:
        out.add(pid)
        st = proc.stat(pid)
        pid = st["ppid"] if st else 0
        seen += 1
    return out


def terminal_windows(proc, term_pid, runtime_dir=None, home=None, ignore=()):
    """One record per terminal window of the process `term_pid` (kitty: one per OS window's root program).

    {"pts": N, "shell": bool, "root": {"pid", "argv", "cwd"},
     "job": None | {"tops": [{"pid", "argv", "cwd", "exe"}], "members": [{"pid", "argv", "euid"}],
                    "typed": mark | None, "root": bool, "claude": id | None}}
    """
    out = []
    for cpid in proc.children(term_pid):
        st = proc.stat(cpid)
        if not st or not is_pts(st["tty_nr"]):
            continue
        argv = proc.cmdline(cpid)
        rec = {"pts": _tty_minor(st["tty_nr"]), "shell": _is_interactive_shell(st, argv),
               "root": {"pid": cpid, "argv": argv, "cwd": proc.cwd(cpid)}, "job": None}
        if rec["shell"] and st["tpgid"] > 0 and st["tpgid"] != st["pgrp"]:
            members = proc.group(st["tpgid"])
            ids = {m["pid"] for m in members}
            tops = [m for m in members if m["ppid"] not in ids]
            if members and not ids.intersection(ignore):
                job = {"tops": [], "members": [], "typed": read_mark(runtime_dir, st["tty_nr"]),
                       "root": False, "claude": None}
                for m in members:
                    uid = proc.euid(m["pid"])
                    job["members"].append({"pid": m["pid"], "argv": proc.cmdline(m["pid"]) or [m["comm"]], "euid": uid})
                    if uid == 0:
                        job["root"] = True
                for t in tops:
                    targv = proc.cmdline(t["pid"]) or [t["comm"]]
                    job["tops"].append({"pid": t["pid"], "argv": targv, "cwd": proc.cwd(t["pid"]),
                                        "exe": proc.exe(t["pid"])})
                if home and len(job["tops"]) == 1:
                    t = job["tops"][0]
                    if os.path.basename(t["argv"][0]) == "claude":
                        job["claude"] = claude_session(home, t["pid"])
                rec["job"] = job
        out.append(rec)
    out.sort(key=lambda r: r["pts"])
    return out
