#!/usr/bin/env python3
"""publish_cases.py -- `lares publish` (tools/publish/lares-publish) builds the public copy it promises, and nothing else.

    python3 -B tools/dev/publish_cases.py             PUBLISH_CASES RESULT PASS | FAIL
    ARM=<arm> python3 -B tools/dev/publish_cases.py   the tool is weakened (PUBLISH_ARM): the aimed case goes red
    ARM=all ...                                       each arm in its own run: PUBLISH_CASES ARMS RESULT PASS when each bites
        keepall   nothing is left out of the export      -> case "first"
        localtz   the commit carries the local zone      -> case "utc" (the run pins TZ=Europe/Brussels)

A throwaway repository with a private folder, an invented private list and identity; nothing of the real repository is used
but the tool itself and its leak check.
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
TOOL = os.path.join(ROOT, "tools", "publish", "lares-publish")
ARM = os.environ.get("ARM", "")
AIM = {"keepall": "first", "localtz": "utc"}

if ARM == "all":
    missed = []
    for a, case in AIM.items():
        r = subprocess.run([sys.executable, "-B", os.path.abspath(__file__)], env=dict(os.environ, ARM=a), capture_output=True, text=True)
        bit = r.returncode != 0 and ("PUBLISH_CASES FAIL %s:" % case) in r.stdout
        print("PUBLISH_CASES ARM %-8s %s" % (a, "failed as it must" if bit else "DID NOT FAIL"))
        if not bit:
            missed.append(a)
    print("PUBLISH_CASES ARMS RESULT " + ("PASS" if not missed else "FAIL (%s did not bite)" % ", ".join(missed)))
    sys.exit(1 if missed else 0)

WORK = tempfile.mkdtemp(prefix="publish-cases-")
REPO = os.path.join(WORK, "repo")
LIST = os.path.join(WORK, "privacy.jsonc")
NOID = os.path.join(WORK, "noid.jsonc")
with open(LIST, "w") as f:
    f.write('{ "replace": { "Zorblax-Home": "HomeNet" }, "forbid": [], "publish": { "name": "Some One", "email": "1+someone@users.noreply.github.com" } }\n')
with open(NOID, "w") as f:
    f.write('{ "replace": { "Zorblax-Home": "HomeNet" } }\n')
results = []


def git(*a, env=None):
    return subprocess.run(["git", "-C", REPO] + list(a), capture_output=True, text=True, env=env).stdout.strip()


def put(path, body):
    full = os.path.join(REPO, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        f.write(body)


def commit(msg):
    git("add", "-A")
    git("-c", "user.name=Dev", "-c", "user.email=dev@example.com", "commit", "-q", "-m", msg)


def tool(*a, lst=LIST):
    env = dict(os.environ, LARES_PRIVACY_FILE=lst)
    env.pop("PUBLISH_ARM", None)
    if ARM:
        env["PUBLISH_ARM"] = ARM
    if ARM == "localtz":
        env["TZ"] = "Europe/Brussels"
    r = subprocess.run([sys.executable, "-B", TOOL] + list(a) + ["--repo", REPO], capture_output=True, text=True, env=env)
    return r.returncode, r.stdout + r.stderr


def expect(name, ok, out=""):
    results.append(ok)
    print("PUBLISH_CASES %s %s%s" % ("ok  " if ok else "FAIL", name, "" if ok else ":\n" + "\n".join("    " + l for l in out.splitlines()[-8:])))


try:
    os.makedirs(REPO)
    git("init", "-q", "-b", "main")
    put("README.md", "A shell.\n")
    put("src/a.qml", "Item {}\n")
    put("private/notes.md", "the Zorblax-Home network\n")          # private: must never reach `public`
    put("tools/publish/exclude.txt", "private/\n")
    commit("one")
    secret_blob = git("rev-parse", "HEAD:private/notes.md")
    put("src/staged.qml", "Item { }\n")
    git("add", "src/staged.qml")                                   # someone's staged change: the export must not touch the index
    index_before = git("diff", "--cached", "--name-only")

    code, out = tool("check")
    expect("check", code == 0 and "the leak check passed" in out, out)
    code, out = tool("build", lst=NOID)
    expect("noidentity", code != 0 and "no `publish` name" in out and not git("rev-parse", "--verify", "-q", "refs/heads/public"), out)

    code, out = tool("build")
    pub = git("rev-parse", "--verify", "-q", "refs/heads/public")
    files = git("ls-tree", "-r", "--name-only", "public").splitlines() if pub else []
    expect("first", code == 0 and pub != "" and "private/notes.md" not in files and "src/a.qml" in files
           and git("rev-list", "--count", "public") == "1", out)
    objs = git("rev-list", "--objects", "public") if pub else ""
    expect("unreachable", pub != "" and secret_blob not in objs, "the private blob is reachable from public" if pub else out)
    who = git("log", "-1", "--format=%an <%ae>|%cn <%ce>", "public") if pub else ""
    expect("identity", who == "Some One <1+someone@users.noreply.github.com>|Some One <1+someone@users.noreply.github.com>", who)
    dates = git("log", "-1", "--format=%ai|%ci", "public") if pub else ""
    expect("utc", dates.count("+0000") == 2, dates)
    expect("index", git("diff", "--cached", "--name-only") == index_before, git("status", "--short"))

    code, out = tool("build")
    expect("nothingnew", code == 0 and "nothing new" in out and git("rev-parse", "public") == pub, out)

    git("reset", "-q")
    put("src/b.qml", "Item { id: b }\n")
    commit("two")
    code, out = tool("build")
    pub2 = git("rev-parse", "public")
    expect("second", code == 0 and pub2 != pub and git("rev-parse", "public^") == pub and "src/b.qml" in git("ls-tree", "-r", "--name-only", "public"), out)

    put("src/leak.js", "// near the zorblax home\n")
    commit("three")
    code, out = tool("build")
    expect("leak", code == 1 and "FAILED" in out and git("rev-parse", "public") == pub2, out)
    code, out = tool("check")
    expect("checkleak", code == 1 and "PRIVACY term" in out, out)
finally:
    shutil.rmtree(WORK, ignore_errors=True)

n, bad = len(results), results.count(False)
print("PUBLISH_CASES RESULT " + ("PASS (%d cases)" % n if not bad else "FAIL (%d of %d cases)" % (bad, n)))
sys.exit(1 if bad else 0)
