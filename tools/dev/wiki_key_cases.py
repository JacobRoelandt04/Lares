#!/usr/bin/env python3
"""wiki_key_cases.py -- where the wiki tool finds the Jev key, and that it never leaves the process (tools/wiki/lib/env.py).

    python3 tools/dev/wiki_key_cases.py                 WIKIKEY RESULT PASS | FAIL (<n>/<n> checks)
    ARM=noscrub python3 tools/dev/wiki_key_cases.py     scrub forgets the config's key: the "scrubbed" cases go red
    ARM=nohint  python3 tools/dev/wiki_key_cases.py     an old .env is not named: the "old .env" case goes red
    ARM=all     python3 tools/dev/wiki_key_cases.py     both, each in its own run: WIKIKEY ARMS RESULT PASS when each FAILS on its own check

The key is `jevKey` in config/wiki.jsonc (the shell's own config file; .env is read no more). Everything runs against a private
XDG_CONFIG_HOME holding a FAKE key; no network, no Jev.
"""
import io
import json
import os
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools", "wiki"))
ARM = os.environ.get("ARM", "")
if ARM == "all":
    import subprocess
    needles = {"noscrub": "scrubbed-event", "nohint": "old-env-named"}
    missed = []
    for a, needle in needles.items():
        r = subprocess.run([sys.executable, "-B", os.path.abspath(__file__)], env=dict(os.environ, ARM=a), capture_output=True, text=True)
        bit = r.returncode != 0 and ("WIKIKEY %s FAIL" % needle) in r.stdout
        print("WIKIKEY ARM %s: %s" % (a, "failed as it must" if bit else "DID NOT FAIL"))
        if not bit:
            missed.append(a)
    print("WIKIKEY ARMS RESULT " + ("FAIL (%s did not bite)" % ", ".join(missed) if missed else "PASS"))
    sys.exit(1 if missed else 0)
tmp = tempfile.mkdtemp(prefix="wikikey.")
for k in ("XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME"):
    os.environ[k] = os.path.join(tmp, k.lower())
os.environ.pop("JEV_API_KEY", None)
CFG = os.path.join(tmp, "xdg_config_home", "quickshell")
os.makedirs(os.path.join(CFG, "config"))
KEY = "dk-FAKEKEY0123456789abcdef"

from lib import env, judge, judge_jev, ndjson  # noqa: E402

if ARM == "noscrub":
    env._secrets = lambda: []
    env._SHAPES = ()
if ARM == "nohint":
    env.old_env_hint = lambda: ""

checks, bad = 0, []


def check(name, ok, why=""):
    global checks
    checks += 1
    print("WIKIKEY %s %s %s" % (name, "PASS" if ok else "FAIL", why))
    if not ok:
        bad.append(name)


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def judge_error():
    try:
        judge_jev.JevJudge()._headers()
    except judge.JudgeUnavailable as e:
        return str(e)
    return ""


# no config, no .env: no key, and the error names the config
check("no-key", env.jev_key() is None and "no jevKey in config/wiki.jsonc" in judge_error(), judge_error())

# an old .env with the key and no config key: still no key (the .env is not read), and the error says where it goes
write(os.path.join(CFG, ".env"), "export JEV_API_KEY='%s'\n" % KEY)
err = judge_error()
check("old-env-not-read", env.jev_key() is None, "key %r" % env.jev_key())
check("old-env-named", ".env is no longer read" in err and "jevKey" in err and KEY not in err, err)
os.unlink(os.path.join(CFG, ".env"))

# the key in config/wiki.jsonc (comments allowed, as the shell writes it)
write(os.path.join(CFG, "config", "wiki.jsonc"), '// mine\n{\n  "jev": true,\n  // the key\n  "jevKey": "%s"\n}\n' % KEY)
check("key-from-config", env.jev_key() == KEY, "key %s" % ("found" if env.jev_key() == KEY else repr(env.jev_key())))
h = judge_jev.JevJudge()._headers()
check("key-in-header", h.get("Authorization") == "Bearer " + KEY, "header set" if h.get("Authorization") else "no header")
check("key-not-in-repr", KEY not in repr(judge_jev.JevJudge()), repr(judge_jev.JevJudge()))

# it never leaves by text: scrub, an NDJSON event, a log line, a child's environment
check("scrubbed-text", KEY not in env.scrub("sent %s, Bearer %s" % (KEY, KEY)), env.scrub("sent %s" % KEY))
out = io.StringIO()
ndjson.emit({"event": "error", "text": "failed with " + KEY}, out)
check("scrubbed-event", KEY not in out.getvalue(), out.getvalue().strip())
os.environ["JEV_API_KEY"] = KEY
check("child-env", "JEV_API_KEY" not in env.child_env(), "stripped" if "JEV_API_KEY" not in env.child_env() else "inherited")
os.environ.pop("JEV_API_KEY")

# a key changed while the tool runs is the one used (the file is re-read when it changes)
write(os.path.join(CFG, "config", "wiki.jsonc"), '{ "jevKey": "dk-SECONDKEY0123456789abcd" }\n')
st = os.stat(os.path.join(CFG, "config", "wiki.jsonc"))
os.utime(os.path.join(CFG, "config", "wiki.jsonc"), ns=(st.st_atime_ns, st.st_mtime_ns + 10 ** 9))
check("key-reread", env.jev_key() == "dk-SECONDKEY0123456789abcd", "reread" if env.jev_key() == "dk-SECONDKEY0123456789abcd" else "stale")

# an empty or wrongly typed key is no key
write(os.path.join(CFG, "config", "wiki.jsonc"), '{ "jevKey": 12 }\n')
os.utime(os.path.join(CFG, "config", "wiki.jsonc"), ns=(st.st_atime_ns, st.st_mtime_ns + 2 * 10 ** 9))
check("key-wrong-type", env.jev_key() is None, repr(env.jev_key()))

import shutil  # noqa: E402
shutil.rmtree(tmp, ignore_errors=True)
print("WIKIKEY RESULT " + ("FAIL (%s)" % ", ".join(bad) if bad else "PASS (%d/%d checks)" % (checks, checks)))
sys.exit(1 if bad else 0)
