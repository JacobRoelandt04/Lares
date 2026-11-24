#!/usr/bin/env python3
"""clip_config_cases.py -- what clipboard.jsonc does in tools/clipboard (no shell, no compositor, no clipboard).

    tools/dev/clip_config_cases.py              CLIPCONFIG RESULT PASS | FAIL (<n>/<n> checks)
    ARM=recorded tools/dev/clip_config_cases.py one fault in a copy of tools/; the checks it names must go red

  words     a value of the wrong kind, word or range is its default; the rest of the file stands
  ignored   a copy made in a window class of `ignoreApps` leaves nothing: no entry, no blob, no sealed event (a sensitive one neither)
  recorded  ... and the next one, made elsewhere, is stored as always

wl-paste and hyprctl are stubs first on PATH; the store is a temporary folder.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
checks = fails = 0


def check(ok, what):
    global checks, fails
    checks += 1
    fails += not ok
    print("CC " + ("ok   " if ok else "FAIL ") + what)


def main():
    d = tempfile.mkdtemp(prefix="clipcfg.")
    try:
        tools = os.path.join(d, "tools")
        for part in ("clipboard", "lib"):
            shutil.copytree(os.path.join(REPO, "tools", part), os.path.join(tools, part), ignore=shutil.ignore_patterns("__pycache__"))
        arm = os.environ.get("ARM", "")
        if arm == "recorded":
            f = os.path.join(tools, "clipboard", "clip.py")
            src = open(f).read()
            old = 'if secret.listed(source["cls"], cfg["ignoreApps"]):'
            if src.count(old) != 1:
                print("CLIPCONFIG RESULT FAIL (the anchor of ARM recorded is gone)")
                return 1
            open(f, "w").write(src.replace(old, "if False:"))
        elif arm:
            print("unknown ARM=" + arm)
            return 2
        binp = os.path.join(d, "bin")
        os.mkdir(binp)
        with open(os.path.join(binp, "hyprctl"), "w") as fh:
            fh.write('#!/bin/sh\nprintf \'{"class":"%s","title":"t","address":"0x1"}\\n\' "$CLS"\n')
        with open(os.path.join(binp, "wl-paste"), "w") as fh:
            fh.write('#!/bin/sh\ncase "$*" in --list-types) echo "text/plain;charset=utf-8" ;; *) printf "%s" "$TEXT" ;; esac\n')
        for n in ("hyprctl", "wl-paste"):
            os.chmod(os.path.join(binp, n), 0o755)
        cfg = os.path.join(d, "clipboard.jsonc")
        state = os.path.join(d, "state")

        def run(args, **env):
            e = dict(os.environ, PATH=binp + ":" + os.environ["PATH"], CLIP_STATE=state, CLIP_CONFIG=cfg, CLS="", TEXT="")
            e.pop("CLIPBOARD_STATE", None)
            e.update(env)
            out = subprocess.run([sys.executable, os.path.join(tools, "clipboard", "clip.py")] + args, env=e, input=e["TEXT"].encode(),
                                 stdout=subprocess.PIPE, timeout=30).stdout.decode()
            return [json.loads(x) for x in out.splitlines() if x.strip()]

        def config(text):
            with open(cfg, "w") as fh:
                fh.write(text)
            return run(["config"])[0]["config"]

        c = config('{ "enter": "eat", "openOn": 3, "undoSec": 500, "ignoreApps": ["a", 3], "joiner": ", ", "pinnedFirst": false, // x\n "copyOnClose": "no" }')
        check(c["enter"] == "paste" and c["openOn"] == "all" and c["undoSec"] == 8 and c["copyOnClose"] is True, "words: a wrong one is its default")
        check(c["ignoreApps"] == ["a"] and c["joiner"] == ", " and c["pinnedFirst"] is False, "words: the right ones stand")
        c = config("{}")
        check(c["openOverFullscreen"] is True and c["restoreAtStart"] is True and c["ignoreApps"] == [] and c["joiner"] == "\n", "words: the defaults")

        config('{ "ignoreApps": ["KeePassXC"] }')
        ev = run(["ingest"], CLS="keepassxc", TEXT="an ignored copy")
        check(ev == [{"ev": "skip", "why": "ignored"}], "ignored: the event says so and nothing else (%s)" % json.dumps(ev))
        ev = run(["ingest"], CLS="KeePassXC", TEXT="an ignored secret", CLIPBOARD_STATE="sensitive")
        check(ev == [{"ev": "skip", "why": "ignored"}], "ignored: a sensitive copy neither (%s)" % json.dumps(ev))
        index = os.path.join(state, "index.json")
        held = json.load(open(index))["entries"] if os.path.exists(index) else []
        check(held == [], "ignored: the store holds nothing (%d)" % len(held))
        ev = run(["ingest"], CLS="KeePassXC-Browser", TEXT="a copy made elsewhere")
        check(len(ev) == 1 and ev[0]["ev"] == "add", "recorded: a class that only begins like it is another (%s)" % json.dumps(ev)[:60])
        held = json.load(open(index))["entries"] if os.path.exists(index) else []
        check([e["text"] for e in held] == ["a copy made elsewhere"], "recorded: and only that one is stored")
    finally:
        shutil.rmtree(d, ignore_errors=True)
    print("CLIPCONFIG RESULT %s (%d/%d checks)" % ("FAIL" if fails else "PASS", checks - fails, checks))
    if os.environ.get("ARM"):
        print("ARM %s: %s" % (os.environ["ARM"], "failed as it must" if fails else "DID NOT FAIL"))
        return 0 if fails else 1
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
