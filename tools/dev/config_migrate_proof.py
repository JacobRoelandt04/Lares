#!/usr/bin/env python3
"""config_migrate_proof.py -- proves tools/dev/config_migrate.py on a COPY of the live configs: what the code makes of them before the
cleanup and after it, key by key.

    python3 tools/dev/config_migrate_proof.py <live dir> [--before <rev>]      (default rev: main, the code the user runs)

The live dir is only READ: the names config_migrate.py knows are copied into a scratch dir ($SCRATCH, default /tmp/lares-cleanup), never
calendars or .env. Then:
  BEFORE  a `git archive` of <rev>, with this tree's dev kit (tools/dev/, config_effective.py and the sandbox it runs) put in it, prints the effective values of the copy
  AFTER   the copy is migrated (config_migrate.py --write, on the copy), and this tree's config_effective.py prints its values
and every key must agree, except the migration's own table:
  moved      the value in its new place is the old one (shell.config.llmStore -> llm.store)
  constant   the key is gone from the config; the constant's default (the QML property, read from this tree) is the old value
  no reader  a key nothing read (shell.playerProps): gone, nothing to compare
  now in     a fact the code keeps elsewhere now: the LLM's size, the old `scale.llm` ratio before, `scale.popups.llm` after
  new        a key only the tree after has, AT ITS DEFAULT (config_effective's [default]: what the same code answers for an empty
             directory): a new setting nobody's file sets yet, which loses nothing (Q16: silicon.config.defaultProfile = null). The
             same key SET by the file, or a key only the tree before has, still differs.
The file's own text (`shell.raw.*`, `idle.raw.*`) is not compared: what the file SAYS changes on purpose. The shell keys only read
from that text by a reader config_effective does not ask (theme, icons, geoclueAgent, debug) are compared as the file's value, or the
example's default where the file has none, on both sides.
Ends in one CONFIG_MIGRATE_PROOF RESULT PASS|FAIL line; the scratch dir is removed unless KEEP=1.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools", "dev"))
sys.path.insert(0, os.path.join(ROOT, "tools", "lib"))
import config_migrate as CM  # noqa: E402
import jsonc  # noqa: E402

# before-only effective keys -> what they are now
MOVED = {"shell.config.llmStore": "llm.store"}
# after-only effective keys -> the before key that held the same fact (the LLM's size was the old scale.llm ratio, it is the popups' map now)
NOW_IN = {"scale.parsed.popups.llm": "scale.llmRatio"}
NO_READER = {"shell.playerProps": "the props' switch: nothing reads it since C2"}
# before-only effective keys that became constants -> the table's config path
CONSTANT_KEYS = {
    "notifications.config.images.avatarMax": "notifications.images.avatarMax",
    "notifications.config.images.pictureMaxHeight": "notifications.images.pictureMaxHeight",
    "notifications.config.toasts.staggerMs": "notifications.toasts.staggerMs",
    "osd.config.minShowMs": "osd.minShowMs",
    "silicon.config.idle.calmAfterMs": "silicon.idle.calmAfterMs",
    "silicon.config.idle.haltAfterMs": "silicon.idle.haltAfterMs",
    "silicon.config.idle.statsHaltedMs": "silicon.idle.statsHaltedMs",
    "silicon.config.idle.batteryHaltedMs": "silicon.idle.batteryHaltedMs",
    "silicon.config.sounds.latch": "silicon.sounds.latch",
    "silicon.config.sounds.dip": "silicon.sounds.dip",
    "silicon.config.sounds.plug": "silicon.sounds.plug",
    "silicon.config.sounds.variant.latch": "silicon.sounds.variant.latch",
    "silicon.config.sounds.variant.dip": "silicon.sounds.variant.dip",
    "silicon.config.sounds.variant.plug": "silicon.sounds.variant.plug",
    "silicon.config.sounds.variant.plug_out": "silicon.sounds.variant.plug_out",
    "silicon.config.look.scale": "silicon.look.scale",
}
# after-only effective keys: ShellConfig's constants, printed as its properties (their effect is shell.config.*, compared above)
NEW_CONSTANT_PROPS = {"shell." + CM.CONSTANTS[k][1] for k in CM.CONSTANTS if k.startswith("shell.")}
RAW_ONLY = ("theme", "icons", "geoclueAgent", "debug")
TEXT = re.compile(r"^(shell|idle)\.raw(\.|$)")


def parse(path, marks=None):
    out = {}
    for line in open(path, encoding="utf-8"):
        m = re.match(r"^(\S.*?) = (.*)  \[(set|default)\]$", line.rstrip("\n"))
        if not m:
            continue
        v = m.group(2)
        if v.startswith("(absent; default"):
            continue
        out[m.group(1)] = json.loads(v)
        if marks is not None:
            marks[m.group(1)] = m.group(3)
    return out


def flat(prefix, v, out):
    if isinstance(v, dict) and v:
        for k in v:
            flat(prefix + "." + k if prefix else k, v[k], out)
    else:
        out[prefix] = v
    return out


def effective(tree, cfgdir, scratch, tag):
    env = dict(os.environ, SCRATCH=scratch, SANDBOX=os.path.join(scratch, "sb-" + tag))
    out = os.path.join(scratch, tag + ".txt")
    with open(out, "w") as f:
        rc = subprocess.run(["python3", "-B", os.path.join(tree, "tools", "dev", "config_effective.py"), cfgdir], cwd=tree, env=env,
                            stdout=f, stderr=subprocess.PIPE, text=True)
    if rc.returncode != 0:
        sys.stderr.write(rc.stderr[-2000:])
        raise SystemExit("config_migrate_proof: config_effective.py failed in %s (%s)" % (tree, tag))
    return out


def main(argv):
    if not argv or not os.path.isdir(argv[0]):
        print(__doc__)
        return 2
    live = os.path.abspath(argv[0])
    rev = argv[argv.index("--before") + 1] if "--before" in argv else "main"
    scratch_root = os.environ.get("SCRATCH", "/tmp/lares-cleanup")
    os.makedirs(scratch_root, exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="cmproof.", dir=scratch_root)
    try:
        before_dir, after_dir, tree = (os.path.join(scratch, x) for x in ("before", "after", "tree"))
        for d in (before_dir, after_dir, tree):
            os.makedirs(d)
        copied = []
        for n in CM.NAMES:
            for ext in (".jsonc", ".json"):
                p = os.path.join(live, n + ext)
                if os.path.isfile(p):
                    shutil.copy(p, os.path.join(before_dir, n + ext))
                    shutil.copy(p, os.path.join(after_dir, n + ext))
                    copied.append(n + ext)
                    break
        print("copied: " + " ".join(copied))
        arch = subprocess.run("git -C %s archive %s | tar -x -C %s" % (ROOT, rev, tree), shell=True)
        if arch.returncode != 0:
            raise SystemExit("config_migrate_proof: git archive of %s failed" % rev)
        # this tree's kit over the old one: config_effective.py and what it runs (the sandbox, its runtime dirs, the private bus)
        shutil.copytree(os.path.join(ROOT, "tools", "dev"), os.path.join(tree, "tools", "dev"), dirs_exist_ok=True, symlinks=True,
                        ignore=shutil.ignore_patterns("__pycache__"))
        b = parse(effective(tree, before_dir, scratch, "before"))
        mig = subprocess.run(["python3", "-B", os.path.join(ROOT, "tools", "dev", "config_migrate.py"), after_dir, "--write"],
                             capture_output=True, text=True)
        print(mig.stdout.strip().splitlines()[-1] if mig.stdout.strip() else mig.stderr[-500:])
        if mig.returncode != 0:
            print(mig.stdout[-3000:])
            print("CONFIG_MIGRATE_PROOF RESULT FAIL (the migration refused on the copy)")
            return 1
        a_marks = {}
        a = parse(effective(ROOT, after_dir, scratch, "after"), a_marks)
        fails, n_eq, n_mv, n_const, n_raw, n_new = [], 0, 0, 0, 0, 0
        for k in sorted(set(b) | set(a)):
            if TEXT.match(k):
                continue
            if k in MOVED:
                if k in b:
                    ok = CM.same(b[k], a.get(MOVED[k]))
                    print("moved     %s = %s -> %s = %s  %s" % (k, json.dumps(b[k]), MOVED[k], json.dumps(a.get(MOVED[k])), "ok" if ok else "FAIL"))
                    n_mv += 1
                    if not ok:
                        fails.append(k)
                continue
            if k in NO_READER:
                print("no reader %s = %s: %s" % (k, json.dumps(b.get(k)), NO_READER[k]))
                continue
            if k in CONSTANT_KEYS and k not in a:
                typ, prop, _ = CM.CONSTANTS[CONSTANT_KEYS[k]]
                want, where = CM.qml_default(typ, prop)
                ok = CM.same(b[k], want)
                print("constant  %s = %s -> %s.%s (%s) = %s  %s" % (k, json.dumps(b[k]), typ, prop, where, json.dumps(want), "ok" if ok else "FAIL"))
                n_const += 1
                if not ok:
                    fails.append(k)
                continue
            if k in NOW_IN and k not in b:
                ok = CM.same(a[k], b.get(NOW_IN[k]))
                print("now in    %s = %s <- before %s = %s  %s" % (k, json.dumps(a[k]), NOW_IN[k], json.dumps(b.get(NOW_IN[k])), "ok" if ok else "FAIL"))
                n_mv += 1
                if not ok:
                    fails.append(k)
                continue
            if k in NEW_CONSTANT_PROPS and k not in b:
                n_const += 1
                continue
            if k not in b and a_marks.get(k) == "default":
                print("new       %s = %s  (a key only the tree after has, at its default)" % (k, json.dumps(a[k])))
                n_new += 1
                continue
            if k not in b or k not in a or not CM.same(b[k], a[k]):
                fails.append(k)
                print("DIFFER    %s: before %s, after %s" % (k, json.dumps(b.get(k, "(absent)")), json.dumps(a.get(k, "(absent)"))))
                continue
            n_eq += 1
        # the shell keys only their own readers read: the file's value, or the example's default
        ex = flat("", jsonc.load(os.path.join(ROOT, ".examples", "shell.jsonc")), {})
        rb, ra = {}, {}
        for src, dst in ((b, rb), (a, ra)):
            for k, v in src.items():
                if k.startswith("shell.raw."):
                    dst[k[len("shell.raw."):]] = v
        for k in sorted(set(rb) | set(ra) | set(ex)):
            if not k.split(".")[0] in RAW_ONLY:
                continue
            vb, va = rb.get(k, ex.get(k, "(absent)")), ra.get(k, ex.get(k, "(absent)"))
            n_raw += 1
            if not CM.same(vb, va):
                fails.append("shell.raw." + k)
                print("DIFFER    shell %s (read by its own reader): before %s, after %s" % (k, json.dumps(vb), json.dumps(va)))
        print("CONFIG_MIGRATE_PROOF RESULT %s (%d keys equal, %d moved, %d constants, %d raw-only shell keys, %d new at their default; %s)"
              % ("PASS" if not fails else "FAIL", n_eq, n_mv, n_const, n_raw, n_new,
                 ("%d differ: %s" % (len(fails), ", ".join(fails[:8]))) if fails else "before: " + rev))
        return 0 if not fails else 1
    finally:
        if os.environ.get("KEEP") != "1":
            shutil.rmtree(scratch, ignore_errors=True)
        else:
            print("kept: " + scratch)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
