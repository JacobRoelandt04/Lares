#!/usr/bin/env python3
"""dictation_probe_sources.py -- tools/stt/sttlib/sources.py on fixed cases (round 5: the window take's streams, the ask's cwd), in
seconds, with no PipeWire and no real processes: a fake /proc built here, canned pw-dump batches, and a recording stand-in for pw-link.

  python3 tools/dev/dictation_probe_sources.py            DICTSRC RESULT PASS | FAIL
  ARM=nodescend python3 tools/dev/dictation_probe_sources.py   the window's pid alone owns streams (no walk): must FAIL on
                                                              "DICTSRC FAIL P1 tree"

P1 the tree: the window's descendants and its own ancestors (never their other children, never past the compositor) own a stream
P2 terminal_cwd: one shell; two told apart by the foreground process the title names, or by the directory an idle title names;
   two that cannot be told apart, and a window with no shell, give ""
P3 StreamWatch: the window's streams linked into the capture port by channel (stereo FL/FR, mono into both), another app's not, a
   capture of another pw-record ignored, a stream that comes later linked, a stream that goes forgotten, each change told once
"""
import os
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "tools" / "stt" / "sttlib" / "sources.py"
bad = 0


def say(ok, what, detail):
    global bad
    if not ok:
        bad += 1
    print("DICTSRC %s %s: %s" % ("ok" if ok else "FAIL", what, detail))


def load(tmp):
    """sources.py from the tree (an ARM patches a copy)."""
    code = SRC.read_text(encoding="utf-8")
    if os.environ.get("ARM") == "nodescend":
        old = "            hit = p == self.root\n"
        if code.count(old) != 1:
            print("DICTSRC ARMLOST")
            sys.exit(3)
        code = code.replace(old, "            hit = False\n")
    pkg = Path(tmp) / "armlib"
    pkg.mkdir()
    (pkg / "__init__.py").write_text("")
    (pkg / "sources.py").write_text(code, encoding="utf-8")
    sys.path.insert(0, tmp)
    import armlib.sources as m  # noqa: E402

    return m


def proc(root, pid, comm, ppid, tty=0, tpgid=-1, cwd=None, argv=None):
    d = Path(root) / str(pid)
    d.mkdir(parents=True, exist_ok=True)
    (d / "stat").write_text("%d (%s) S %d %d %d %d %d 4194304 0 0\n" % (pid, comm, ppid, pid, pid, tty, tpgid))
    (d / "cmdline").write_bytes(b"\0".join(a.encode() for a in (argv or [comm])) + b"\0")
    if cwd:
        os.symlink(cwd, d / "cwd")


def main():
    tmp = tempfile.mkdtemp(prefix="dictsrc.")
    try:
        S = load(tmp)
        P = os.path.join(tmp, "proc")
        home = os.path.expanduser("~")
        # P1: systemd(1) > Hyprland(100) > sh(150) > zen(200) > forkserver(201) > content(202); sh's other child 151; kitty(300) >
        # zsh(301) > mpv(302)
        proc(P, 1, "systemd", 0)
        proc(P, 100, "Hyprland", 1)
        proc(P, 150, "sh", 100)
        proc(P, 151, "pw-play", 150)
        proc(P, 200, "zen-bin", 150)
        proc(P, 201, "forkserver", 200)
        proc(P, 202, "Isolated Web Co", 201)
        proc(P, 300, "kitty", 100)
        proc(P, 301, "zsh", 300, tty=34817, tpgid=302, cwd="/srv/a")
        proc(P, 302, "mpv", 301, tty=34817, tpgid=302)
        t = S.ProcTree(200, P)
        got = {p: t.owns(p) for p in (200, 201, 202, 150, 151, 100, 1, 300, 302, 999)}
        want = {200: True, 201: True, 202: True, 150: True, 151: False, 100: False, 1: False, 300: False, 302: False, 999: False}
        say(got == want, "P1 tree", "owns " + " ".join("%d:%s" % (p, "y" if v else "n") for p, v in sorted(got.items()))
            + "; ancestors %s" % t.ancestors)

        # P2: kitty 400 with one shell; kitty 500 with zsh 501 (git in front) and zsh 502 (idle, in ~/src); 600 no shell
        proc(P, 400, "kitty", 100)
        proc(P, 401, "zsh", 400, tty=34818, tpgid=401, cwd="/home/u/proj")
        proc(P, 500, "kitty", 100)
        proc(P, 501, "zsh", 500, tty=34819, tpgid=503, cwd="/srv/repo")
        proc(P, 503, "git", 501, tty=34819, tpgid=503, argv=["git", "log"])
        proc(P, 502, "zsh", 500, tty=34820, tpgid=502, cwd=home + "/src")
        proc(P, 600, "zen-bin", 100)
        cases = [(400, "~", "/home/u/proj"), (500, "git log --oneline", "/srv/repo"), (500, "zsh", home + "/src"),
                 (500, "~/src", home + "/src"), (500, "something else", ""), (600, "Zen", ""), (0, "", "")]
        res = [(pid, title, S.terminal_cwd(pid, title, P)) for pid, title, _ in cases]
        ok = all(r[2][0] == c[2] for r, c in zip(res, cases))
        say(ok, "P2 terminal cwd", "; ".join("%d %r -> %r (%s)" % (pid, title, cwd, why) for pid, title, (cwd, why) in res))

        # P3: the watch on canned batches
        log = os.path.join(tmp, "links")
        stub = os.path.join(tmp, "pw-link")
        Path(stub).write_text("#!/bin/sh\necho \"$1 $2\" >> %s\n" % log)
        os.chmod(stub, 0o755)
        events = []

        def links():
            return [x for x in Path(log).read_text().split("\n") if x] if os.path.exists(log) else []

        def node(i, cls, name, client, pid=None, serial=None, app=""):
            props = {"media.class": cls, "node.name": name, "client.id": client, "object.serial": serial or i, "application.name": app}
            if pid is not None:
                props["application.process.id"] = pid
            return {"id": i, "type": "PipeWire:Interface:Node", "info": {"props": props}}

        def client(i, pid):
            return {"id": i, "type": "PipeWire:Interface:Client", "info": {"props": {"application.process.id": str(pid)}}}

        def port(i, nid, direction, ch):
            return {"id": i, "type": "PipeWire:Interface:Port", "info": {"direction": direction, "props": {"node.id": nid, "audio.channel": ch}}}

        w = S.StreamWatch(200, 7777, events.append, 5, proc=P, link_cmd=[stub], dump_cmd=False)
        w.feed([client(10, 7777), node(20, "Stream/Input/Audio", S.CAPTURE_NAME, 10), port(21, 20, "input", "FL"), port(22, 20, "input", "FR"),
                client(30, 6666), node(31, "Stream/Input/Audio", S.CAPTURE_NAME, 30), port(32, 31, "input", "FL"),          # another pw-record's
                client(11, 202), node(40, "Stream/Output/Audio", "Zen", 11, app="Zen"), port(41, 40, "output", "FL"), port(42, 40, "output", "FR"),
                client(12, 302), node(50, "Stream/Output/Audio", "mpv", 12, app="mpv"), port(51, 50, "output", "MONO")])
        links1 = links()
        ev1 = [e for e in events if e["ev"] == "sources"]
        say(sorted(links1) == ["41 21", "42 22"] and len(ev1) == 1 and [s["node"] for s in ev1[0]["streams"]] == [40],
            "P3 the window's stream", "links %s; told %s" % (links1, [[s["app"] for s in e["streams"]] for e in ev1]))
        # a stream that comes later (pid on the node itself, mono) and the same picture again (no new links, no new event)
        w.feed([node(60, "Stream/Output/Audio", "Zen", 13, pid=201, app="Zen"), port(61, 60, "output", "MONO")])
        w.feed([port(61, 60, "output", "MONO")])
        links2 = links()[len(links1):]
        ev2 = [e for e in events if e["ev"] == "sources"][1:]
        say(sorted(links2) == ["61 21", "61 22"] and len(ev2) == 1 and [s["node"] for s in ev2[0]["streams"]] == [40, 60],
            "P3 a stream that comes later", "links %s; told %s" % (links2, [[s["node"] for s in e["streams"]] for e in ev2]))
        # the first stream goes
        w.feed([{"id": 40, "info": None}, {"id": 41, "info": None}, {"id": 42, "info": None}])
        ev3 = [e for e in events if e["ev"] == "sources"][2:]
        say(len(ev3) == 1 and [s["node"] for s in ev3[0]["streams"]] == [60] and [s["serial"] for s in w.seen] == [40, 60],
            "P3 a stream that goes", "told %s; seen %s" % ([[s["node"] for s in e["streams"]] for e in ev3], [s["serial"] for s in w.seen]))
        w.stop()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("DICTSRC RESULT " + ("PASS" if bad == 0 else "FAIL"))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
