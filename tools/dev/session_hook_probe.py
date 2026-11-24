#!/usr/bin/env python3
"""The driver of tools/dev/session_hook_probe.sh: tools/session/session-hook.bash in a real interactive bash on a pty.

The harness is the terminal: it answers a status query (ESC [ 5 n) with ESC [ 0 n, as kitty does, unless told not to.
HOME, XDG_RUNTIME_DIR and the history file are private; nothing of the user's is read.
"""
import os
import pty
import select
import shlex
import sys
import time

HOOK = sys.argv[1]
W = sys.argv[2]
fails = []


def check(name, ok, seen=""):
    if ok:
        print("SHP ok %s" % name, flush=True)
    else:
        print("SHP FAIL %s: %s" % (name, seen), flush=True)
        fails.append(name)


class Term:
    """bash -i on a pty; `answer` = reply to status queries."""

    def __init__(self, name, token=None, answer=True, rc_extra=""):
        self.home = os.path.join(W, name, "home")
        self.rt = os.path.join(W, "rt")
        os.makedirs(self.home, exist_ok=True)
        os.makedirs(self.rt, exist_ok=True)
        with open(os.path.join(self.home, ".bashrc"), "w") as f:
            f.write("PS1='PROMPT> '\n%s\n. %s\n" % (rc_extra, shlex.quote(HOOK)))
        env = {"HOME": self.home, "XDG_RUNTIME_DIR": self.rt, "TERM": "xterm-256color", "PATH": os.environ["PATH"],
               "HISTFILE": os.path.join(self.home, ".bash_history"), "LANG": "C.UTF-8"}
        if token:
            env["LARES_SESSION_TOKEN"] = token
        self.answer = answer
        self.out = b""
        self.queries = 0
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            # A runner started as a background job hands down SIGINT IGNORED, and an ignored signal survives exec: the
            # programs of this terminal would then be deaf to its Ctrl+C (the gate runner found it; a terminal never is).
            import signal
            for sig in (signal.SIGINT, signal.SIGQUIT, signal.SIGTSTP):
                signal.signal(sig, signal.SIG_DFL)
            os.chdir(self.home)
            os.execvpe("bash", ["bash", "--noprofile", "-i"], env)

    def pump(self, seconds=0.3):
        end = time.monotonic() + seconds
        while True:
            left = end - time.monotonic()
            if left <= 0:
                return
            r, _, _ = select.select([self.fd], [], [], left)
            if not r:
                return
            try:
                b = os.read(self.fd, 65536)
            except OSError:
                return
            if not b:
                return
            self.out += b
            n = b.count(b"\x1b[5n")
            self.queries += n
            if self.answer:
                for _ in range(n):
                    os.write(self.fd, b"\x1b[0n")

    def wait_for(self, needle, seconds=6.0):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if needle in self.out:
                return True
            self.pump(0.1)
        return needle in self.out

    def send(self, text):
        os.write(self.fd, text.encode())
        self.pump(0.4)

    def close(self):
        try:
            os.write(self.fd, b"\x03\x04")
            os.close(self.fd)
        except OSError:
            pass
        try:
            os.kill(self.pid, 9)
            os.waitpid(self.pid, 0)
        except OSError:
            pass


def pending(token, mode, cmd):
    d = os.path.join(W, "rt", "lares-session", "pending")
    os.makedirs(d, mode=0o700, exist_ok=True)
    with open(os.path.join(d, token), "w") as f:
        f.write("%s\n%s\n" % (mode, cmd))
    return os.path.join(d, token)


def exists_soon(path, seconds=3.0):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if os.path.exists(path):
            return True
        time.sleep(0.05)
    return os.path.exists(path)


def parsed(mark):
    """A mark as (kind of the first word, {word: (kind, alias)}, the first word's alias, the line) -- None when empty."""
    if not mark:
        return None
    lines = mark.split("\n")
    head = lines[0].split("\t")
    words = {head[i]: (head[i + 1], head[i + 2]) for i in range(1, len(head) - 2, 3)}
    return (head[0], words, lines[1], "\n".join(lines[2:]).rstrip("\n"))


def marks():
    d = os.path.join(W, "rt", "lares-session", "tty")
    out = {}
    try:
        for n in os.listdir(d):
            out[n] = open(os.path.join(d, n)).read()
    except OSError:
        pass
    return out


def main():
    # H1  type: the line is at the prompt, not run; Enter runs exactly it
    m = os.path.join(W, "typed-ran")
    pf = pending("tokT", "type", "touch %s" % shlex.quote(m))
    t = Term("h1", "tokT")
    check("H1 the prompt came", t.wait_for(b"PROMPT> "), t.out[-200:])
    t.pump(1.0)
    check("H1 the command is claimed", not os.path.exists(pf), os.listdir(os.path.dirname(pf)))
    check("H1 the line shows at the prompt", b"touch " in t.out.split(b"PROMPT> ")[-1], t.out[-200:])
    check("H1 nothing ran", not os.path.exists(m), "it ran")
    check("H1 the status query stops (no ping-pong)", 1 <= t.queries <= 4, t.queries)
    q = t.queries
    t.pump(1.0)
    check("H1 no query at rest", t.queries == q, t.queries - q)
    t.send("\r")
    check("H1 Enter runs exactly the line", exists_soon(m) and os.listdir(W).count("typed-ran") == 1
          and not [n for n in os.listdir(W) if n.startswith("typed-ran") and n != "typed-ran"], sorted(os.listdir(W)))
    t.close()

    # H2  run: evaluated in the shell, once; the history has it; the mark stands while it runs
    cnt = os.path.join(W, "count")
    pending("tokR", "run", "echo x >> %s; sleep 30" % shlex.quote(cnt))
    t = Term("h2", "tokR")
    check("H2 it ran by itself", exists_soon(cnt), t.out[-200:])
    time.sleep(0.3)
    mk = [v for v in marks().values() if "sleep 30" in v]
    pm = parsed(mk[0]) if len(mk) == 1 else None
    check("H2 the mark stands while it runs", pm is not None and pm[0] == "builtin" and pm[3].startswith("echo x >> ")
          and pm[1].get("sleep") == ("file", "") and pm[1].get("echo") == ("builtin", ""), marks())
    t.send("\x03")
    t.wait_for(b"PROMPT> ")
    t.pump(0.5)
    check("H2 the mark is emptied at the prompt", not [v for v in marks().values() if "sleep 30" in v], marks())
    t.send("history | tail -2\r")
    check("H2 the history has it", b"  1  echo x >> " in t.out, t.out[-300:])
    # a nested shell does not claim again (the token is gone from this shell's environment)
    t.send("bash --noprofile -i\r")
    t.pump(1.0)
    t.send("exit\r")
    check("H2 a nested shell runs nothing", open(cnt).read().count("x") == 1, open(cnt).read())
    t.close()

    # H3  one claim: a second shell with the SAME token finds nothing
    c3 = os.path.join(W, "count3")
    pending("tokO", "run", "echo x >> %s" % shlex.quote(c3))
    a = Term("h3a", "tokO")
    a.wait_for(b"PROMPT> ")
    exists_soon(c3)
    b = Term("h3b", "tokO")
    b.wait_for(b"PROMPT> ")
    b.pump(0.8)
    check("H3 one shell claims", os.path.exists(c3) and open(c3).read().count("x") == 1, open(c3).read() if os.path.exists(c3) else "none")
    a.close()
    b.close()

    # H4  the mark of a typed line: its kind, an alias's value, emptied when it ends; an ignored line leaves none
    t = Term("h4", None, rc_extra="alias zz='sleep 20'\nfn() { sleep 20; }\nHISTCONTROL=ignorespace")
    t.wait_for(b"PROMPT> ")
    t.send("sleep 20\r")
    mine = [k for k in marks() if marks()[k].endswith("\nsleep 20\n")]
    check("H4 a program", len(mine) == 1 and parsed(marks()[mine[0]]) == ("file", {"sleep": ("file", "")}, "", "sleep 20"), marks())
    key = mine[0] if mine else None
    t.send("\x03")
    t.pump(0.4)
    check("H4 emptied", key is not None and marks().get(key) == "", marks().get(key))
    t.send("zz\r")
    check("H4 an alias", parsed(marks().get(key)) == ("alias", {"zz": ("alias", "sleep 20")}, "sleep 20", "zz"), marks().get(key))
    t.send("\x03")
    t.send("fn\r")
    check("H4 a function", parsed(marks().get(key)) == ("function", {"fn": ("function", "")}, "", "fn"), marks().get(key))
    t.send("\x03")
    t.send("FOO=1 sleep 20\r")
    check("H4 an assignment has no kind", parsed(marks().get(key)) == ("", {"sleep": ("file", "")}, "", "FOO=1 sleep 20"),
          repr(marks().get(key)))
    t.send("\x03")
    # a chain: every command word is named, so the restore can tell which one runs (`cd` is done, `zz` is the alias running)
    t.send("cd /tmp; zz\r")
    check("H4 a chain names its command words", parsed(marks().get(key)) == (
        "builtin", {"cd": ("builtin", ""), "zz": ("alias", "sleep 20")}, "", "cd /tmp; zz"), repr(marks().get(key)))
    t.send("\x03")
    t.send("cd - > /dev/null && sleep 20 | cat\r")
    pm = parsed(marks().get(key)) or ("", {}, "", "")
    check("H4 separators and pipes split the words", pm[1].get("cd") == ("builtin", "") and pm[1].get("sleep") == ("file", "")
          and pm[1].get("cat") == ("file", "") and "&&" not in pm[1] and "|" not in pm[1], repr(marks().get(key)))
    t.send("\x03")
    t.send(" sleep 20\r")
    check("H4 a line bash did not keep leaves no mark", marks().get(key) == "", repr(marks().get(key)))
    t.send("\x03")
    check("H4 mode 0600", key is not None and oct(os.stat(os.path.join(W, "rt", "lares-session", "tty", key)).st_mode & 0o777) == "0o600",
          key)
    t.close()

    # H5  a terminal that never answers: nothing typed, nothing run, the command one Up away
    m5 = os.path.join(W, "silent-ran")
    pending("tokS", "type", "touch %s" % shlex.quote(m5))
    t = Term("h5", "tokS", answer=False)
    t.wait_for(b"PROMPT> ")
    t.pump(1.0)
    check("H5 nothing ran", not os.path.exists(m5), "it ran")
    t.send("\x1b[A")
    t.send("\r")
    check("H5 Up, Enter runs it", exists_soon(m5), t.out[-200:])
    t.close()

    # H6  a PROMPT_COMMAND that was there stays, and still runs
    m6 = os.path.join(W, "pc-ran")
    t = Term("h6", None, rc_extra="PROMPT_COMMAND='touch %s'" % shlex.quote(m6))
    t.wait_for(b"PROMPT> ")
    check("H6 the user's PROMPT_COMMAND still runs", exists_soon(m6), t.out[-200:])
    t.close()

    # H7  no token: no pending directory is touched, nothing is typed
    t = Term("h7", None)
    t.wait_for(b"PROMPT> ")
    t.pump(0.6)
    check("H7 no token, no query", t.queries == 0, t.queries)
    t.close()


try:
    main()
except Exception as e:  # a throwing step is a failed check
    import traceback
    traceback.print_exc()
    check("driver", False, repr(e))
print("SESSION_HOOK RESULT %s%s" % ("FAIL" if fails else "PASS", " (%d: %s)" % (len(fails), "; ".join(fails[:5])) if fails else ""))
sys.exit(1 if fails else 0)
