#!/usr/bin/env python3
"""The offline cases of the system snapshots: no root, no pacman, no real restic, nothing of the user's read or written.

    python3 -B tools/dev/snapshot_cases.py             SNAPSHOT_CASES RESULT PASS | FAIL
    ARM=<name> python3 -B tools/dev/snapshot_cases.py  one fault in a COPY of the tool; the group named must fail
    ARM=all ...                                        every arm in turn: SNAPSHOT_CASES ARMS RESULT PASS | FAIL

The tool runs against a FAKE ROOT (`--root` style: every fixed path under a temp dir) with a fake restic (a small script that logs its
calls and answers from a plan), so a guard can be provoked exactly. The real restic is tools/dev/snapshot_restic_probe.sh.

Groups:
  rule       tools/dev/snapshot_rule_cases.json through python (snaprules.py) AND node (SnapshotRules.js); the two default lists agree
  config     config/snapshots.jsonc as DATA: clamps, wrong types, a link, a stranger's file, a big file, forbidden excludes, the candidates
  run        the run's identity on a fake /proc (top-most package manager, comm with brackets, loops) and what `hook pre` decides from it
  record     the record, the index, `hook done` (changed, a second transaction of the run merges, the tidy is a unit of its own)
  guards     free space, `added` (not the first snapshot), `time` (the first gets 60 minutes), restic stopped and unlocked, the lines
  lines      the hook's lines: contract shape, progress only rises and not faster than one a second, at most 25, restic's output stays out
  undo       the undo plan: exact file names, cache then yay then archive (official only), missing listed, one pacman -U, never --noconfirm
  retention  what a tidy forgets, kept snapshots, delete of a kept one refused, the monthly check
  locks      user-held locks never stop a create; a create waits for another job; oplock is root's; a prune without `lock` is skipped
  prime      the prime: its own tag, no record, newest only, off by the setting, obeys the guards, an update takes the repository from it

ARMs (the group that must fail):
  ruleglob (rule)         a glob matches a name that only starts like it   jsorder (rule)      the JS lists matches in the order they come
  jsdefault (rule)        the JS default minimum is 41
  clampoff (config)       a value is not clamped                           followlink (config) a linked config is read
  ownerskip (config)      a file of another owner is read                  globok (config)    an exclude may hold a wildcard
  pacmanok (config)       pacman's own folder may be excluded
  toplevel (run)          the first manager ancestor is the run, not the top-most
  commparen (run)         a name with a bracket breaks the stat parser     norun (run)        a run that has its snapshot is not recognised
  lastfrom (record)       a second transaction takes the later `before`    tidychild (record) the tidy is not started with --no-block
  firstminutes (guards)   the first snapshot gets maxMinutes, not 60       firstadded (guards) the first snapshot is held to maxAddedGB
  noratelimit (lines)     progress is not limited to one a second          limit25 (lines)    a run may print more than 25 lines
  nounlockstop (guards)   restic is not unlocked after a stop
  loosematch (undo)       a file whose name only starts like the version   archiveall (undo)  an AUR package is looked for in the archive
  noconfirm (undo)        pacman is run with --noconfirm                   blockoff (undo)    a missing critical package does not block the undo
  nosigint (undo)         Ctrl-C kills the CLI under pacman                execundo (undo)    the CLI is replaced by sudo (the hook cannot see the undo)
  noundorun (record)      a snapshot inside an undo is an update           walkstatus (record) `status` walks the repository
  createlock (locks)      a create takes `lock`                            nowait (locks)     a create does not wait for another job
  dirlock (locks)         the job lock is a file anyone can open           nomaxunused (retention) prune without --max-unused
  yayfirst (undo)         yay's folders are looked in before the cache
  forgetkept (retention)  a kept snapshot is forgotten                     deletekept (retention) a kept snapshot may be deleted
  nomonthly (retention)   the check runs on every tidy
  primeinlist (prime)     the prime is tagged as a real snapshot           keepoldprimes (prime) every prime stays
  preemptall (prime)      an update stops any job, not only a tidy        primeoff (prime)   `prime: false` is ignored
  norepair (prime)        a killed backup's packs are not indexed          primenoguard (prime) the prime ignores the added limit
"""
import argparse
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOOL_FILE = "tools/snapshot/root/lares-snapshot-root"
ARMS = {
    "ruleglob": ("rule", "tools/snapshot/root/snaprules.py", 'or not name.endswith(last)', ""),
    "jsorder": ("rule", "modules/bar/system_update/snapshots/SnapshotRules.js",
                '    uniq.sort(function (a, b) { return a < b ? -1 : a > b ? 1 : 0 })', ''),
    "jsdefault": ("rule", "modules/bar/system_update/snapshots/SnapshotRules.js", "var DEFAULT_MIN_PACKAGES = 40", "var DEFAULT_MIN_PACKAGES = 41"),
    "clampoff": ("config", "tools/snapshot/root/snaprules.py", "                s[key] = max(lo, min(hi, v))", "                s[key] = v"),
    "followlink": ("config", "tools/snapshot/root/snaprules.py", "os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK", "os.O_RDONLY | os.O_NONBLOCK"),
    "ownerskip": ("config", "tools/snapshot/root/snaprules.py", "            if st.st_uid != uid:", "            if False:"),
    "globok": ("config", "tools/snapshot/root/snaprules.py", '    if re.search(r"[*?\\[\\]\\\\]", p):', "    if False:"),
    "pacmanok": ("config", "tools/snapshot/root/snaprules.py", '    if p == "/var/lib/pacman" or p.startswith("/var/lib/pacman/"):', "    if False:"),
    "toplevel": ("run", "tools/snapshot/root/snaprules.py", '        if comm in RUN_PROGRAMS:\n            found =',
                 '        if comm in RUN_PROGRAMS and found is None:\n            found ='),
    "commparen": ("run", "tools/snapshot/root/snaprules.py", 'left, right = raw.index("("), raw.rindex(")")', 'left, right = raw.index("("), raw.index(")")'),
    "norun": ("run", "tools/snapshot/root/lares-snapshot-root", 'if run and any(r.get("run") == run for r in read_records(ctx)):', "if False:"),
    "lastfrom": ("record", "tools/snapshot/root/lares-snapshot-root", '    rec["state"] = "done"\n    write_record(ctx, rec)\n    write_index(ctx)\n    spawn_tidy',
                 '    rec["state"] = "done"\n    rec["before"] = snaprules.installed(ctx.root)\n    write_record(ctx, rec)\n    write_index(ctx)\n    spawn_tidy'),
    "tidychild": ("record", "tools/snapshot/root/lares-snapshot-root", 'cmd = [exe, "--no-block", "--quiet",', 'cmd = [exe, "--quiet",'),
    "firstminutes": ("guards", "tools/snapshot/root/lares-snapshot-root", "FIRST_MINUTES = 60", "FIRST_MINUTES = 15"),
    "firstadded": ("guards", "tools/snapshot/root/lares-snapshot-root", 'if not first and added > settings["maxAddedGB"] * ctx.unit:', 'if added > settings["maxAddedGB"] * ctx.unit:'),
    "nounlockstop": ("guards", "tools/snapshot/root/lares-snapshot-root", '    stop_group(proc)\n    restic_call(ctx, ["unlock"], timeout=60)', '    stop_group(proc)'),
    "noratelimit": ("lines", "tools/snapshot/root/lares-snapshot-root", "if step <= self.pct or (self.last_at is not None and now - self.last_at < 1.0):", "if step <= self.pct:"),
    "limit25": ("lines", "tools/snapshot/root/lares-snapshot-root", "def __init__(self, out=None, limit=25, clock=time.monotonic):", "def __init__(self, out=None, limit=2500, clock=time.monotonic):"),
    "loosematch": ("undo", "tools/snapshot/lares-snapshot", '        if os.path.isfile(p):\n            return "pacman", p',
                   '        if glob.glob(os.path.join(CACHE_DIR, "%s-%s*" % (name, version))):\n            return "pacman", sorted(glob.glob(os.path.join(CACHE_DIR, "%s-%s*" % (name, version))))[0]'),
    "archiveall": ("undo", "tools/snapshot/lares-snapshot", "    if name in official:", "    if True:"),
    "noconfirm": ("undo", "tools/snapshot/lares-snapshot", '["pacman", "-U", "--"]', '["pacman", "-U", "--noconfirm", "--"]'),
    "blockoff": ("undo", "tools/snapshot/lares-snapshot", '    blocked = [m["name"] for m in missing if any(snaprules.glob_match(g, m["name"]) for g in critical)]', "    blocked = []"),
    "notaken": ("undo", "tools/snapshot/lares-snapshot", "    taken = taken_over(files, new, now, root)", "    taken = []"),
    "renameblocks": ("undo", "tools/snapshot/lares-snapshot", "                if f[\"name\"] in conflicts_of(owner[p], now, root):", "                if False:"),
    "nosigint": ("undo", "tools/snapshot/lares-snapshot", "    signal.signal(signal.SIGINT, signal.SIG_IGN)", "    pass"),
    "execundo": ("undo", "tools/snapshot/lares-snapshot", "    child = subprocess.Popen(cmd)", "    os.execvp(cmd[0], cmd)"),
    "noundorun": ("record", "tools/snapshot/root/snaprules.py", '            if base == "lares-snapshot" and argv[i + 1:i + 2] == ["undo"]:', "            if False:"),
    "createlock": ("locks", "tools/snapshot/root/lares-snapshot-root", '    with operation(ctx, "create", preempt=True,', '    with repo_lock(ctx), operation(ctx, "create", preempt=True,'),
    "nowait": ("locks", "tools/snapshot/root/lares-snapshot-root", "WAIT_OTHER = 120 ", "WAIT_OTHER = 0 "),
    "dirlock": ("locks", "tools/snapshot/root/lares-snapshot-root", '    fd = os.open(ctx.oplock, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)', '    fd = os.open(ctx.state, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)'),
    "walkstatus": ("record", "tools/snapshot/root/lares-snapshot-root", '"repoBytes": state.get("repoBytes", 0),', '"repoBytes": sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(ctx.repo) for f in fs),'),
    "nomaxunused": ("retention", "tools/snapshot/root/lares-snapshot-root", '["forget", "--prune", "--max-unused", "20%"]', '["forget", "--prune"]'),
    "yayfirst": ("undo", "tools/snapshot/lares-snapshot", '    for fn in file_names(name, version):\n        p = os.path.join(CACHE_DIR, fn)',
                 '    for fn in file_names(name, version):\n        hits = sorted(glob.glob(os.path.join(home, ".cache", "yay", "*", fn)))\n        if hits:\n            return "yay", hits[0]\n    for fn in file_names(name, version):\n        p = os.path.join(CACHE_DIR, fn)'),
    "forgetkept": ("retention", "tools/snapshot/root/lares-snapshot-root", "ids = [r[\"id\"] for r in recs[settings[\"keep\"]:] if not r[\"keep\"]]",
                   "ids = [r[\"id\"] for r in recs[settings[\"keep\"]:]]"),
    "deletekept": ("retention", "tools/snapshot/root/lares-snapshot-root", '    if rec["keep"]:\n        print(json.dumps({"ok": False, "error": "this snapshot is kept', '    if False:\n        print(json.dumps({"ok": False, "error": "this snapshot is kept'),
    "nomonthly": ("retention", "tools/snapshot/root/lares-snapshot-root", "if not check or time.time() - check.get(\"time\", 0) > CHECK_EVERY:", "if True:"),
    "primeinlist": ("prime", "tools/snapshot/root/lares-snapshot-root", "backup_args(ctx, settings, PRIME_TAG)", 'backup_args(ctx, settings, "lares", PRIME_TAG)'),
    "keepoldprimes": ("prime", "tools/snapshot/root/lares-snapshot-root", "    stale = primes[:-1] if primes and unix_of(primes[-1][\"time\"]) > newest_real else primes",
                      "    stale = []"),
    "preemptall": ("prime", "tools/snapshot/root/lares-snapshot-root", 'if not (state.get("preemptible") and busy_now(ctx)):', 'if not busy_now(ctx):'),
    "primeoff": ("prime", "tools/snapshot/root/lares-snapshot-root", 'if not settings["prime"] or not read_records(ctx):', "if not read_records(ctx):"),
    "norepair": ("prime", "tools/snapshot/root/lares-snapshot-root", '    if read_state(ctx).get("unindexed"):', "    if False:"),
    "primenoguard": ("prime", "tools/snapshot/root/lares-snapshot-root", "run_backup(ctx, args + paths, settings, Lines(open(os.devnull, \"w\")), 0, False, 0, settings[\"maxMinutes\"])",
                     "run_backup(ctx, args + paths, settings, Lines(open(os.devnull, \"w\")), 0, True, 0, settings[\"maxMinutes\"])"),
}


def arm_all():
    rc = 0
    for name, (group, _, _, _) in ARMS.items():
        p = subprocess.run([sys.executable, "-B", os.path.abspath(__file__)], env=dict(os.environ, ARM=name), capture_output=True, text=True)
        out = p.stdout + p.stderr
        if "anchor is gone" in out:
            print("ARM %s: NOT PROVEN (its anchor is gone)" % name)
            rc = 1
        elif "SNC FAIL %s " % group in out and "SNAPSHOT_CASES RESULT FAIL" in out:
            line = next(l for l in out.splitlines() if l.startswith("SNC FAIL %s " % group))
            print("ARM %s: FAILED AS IT MUST (%s)" % (name, line[:110]))
        elif "SNAPSHOT_CASES RESULT FAIL" in out:
            print("ARM %s: FAILED, BUT NOT IN ITS OWN GROUP (%s)" % (name, group))
            rc = 1
        elif "SNAPSHOT_CASES RESULT" not in out:
            print("ARM %s: DID NOT RUN TO A VERDICT" % name)
            rc = 1
        else:
            print("ARM %s: STAYED GREEN" % name)
            rc = 1
    print("SNAPSHOT_CASES ARMS RESULT %s" % ("PASS" if rc == 0 else "FAIL"))
    sys.exit(rc)


if os.environ.get("ARM") == "all":
    arm_all()

WORK = tempfile.mkdtemp(prefix="snapshot_cases.", dir=os.environ.get("SANDBOX") if os.path.isdir(os.environ.get("SANDBOX", "")) else None)
TREE = os.path.join(WORK, "tree")
for rel in ("tools/snapshot", "tools/lib", "modules/bar/system_update/snapshots", "tools/dev/snapshot_rule_cases.json"):
    src, dst = os.path.join(ROOT, rel), os.path.join(TREE, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    (shutil.copytree if os.path.isdir(src) else shutil.copy)(src, dst)
shutil.rmtree(os.path.join(TREE, "tools/snapshot/root/__pycache__"), ignore_errors=True)
if os.environ.get("ARM"):
    _, rel, a, b = ARMS[os.environ["ARM"]]
    path = os.path.join(TREE, rel)
    src = open(path).read()
    if src.count(a) != 1:
        print("ARM %s: anchor is gone in %s" % (os.environ["ARM"], rel))
        print("SNAPSHOT_CASES RESULT FAIL (arm)")
        shutil.rmtree(WORK, ignore_errors=True)
        sys.exit(1)
    open(path, "w").write(src.replace(a, b))

os.environ["LARES_SNAPSHOT_TEST_UNIT"] = "1"        # a "GB" is a byte: guards are provoked with a few bytes
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(TREE, "tools/snapshot/root"))
import snaprules  # noqa: E402


def load_script(rel, name):
    loader = importlib.machinery.SourceFileLoader(name, os.path.join(TREE, rel))
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


tool = load_script(TOOL_FILE, "lares_snapshot_root")
cli = load_script("tools/snapshot/lares-snapshot", "lares_snapshot_cli")
fails = []
counts = {}


def check(group, name, ok, seen=""):
    counts[group] = counts.get(group, 0) + 1
    if not ok:
        fails.append("%s %s" % (group, name))
        print("SNC FAIL %s %s: %s" % (group, name, str(seen)[:300]))


# ---- the fake world: a root, a restic that logs and answers from a plan ----------------------------------------------------------------
FAKE_RESTIC = r'''#!/usr/bin/python3
import datetime, hashlib, json, os, signal, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
if args[:1] == ["version"]:
    print("restic 0.19.1 compiled with fake")
    sys.exit(0)
repo, cmd, rest = args[1], args[2], args[3:]
with open(HERE + "/calls.log", "a") as f:
    f.write(" ".join(args[2:]) + "\n")
def load(name, default):
    try:
        return json.load(open(HERE + "/" + name))
    except OSError:
        return default
plan = load("plan.json", {})
snaps = load("snaps.json", [])
def flag(name):
    return [rest[i + 1] for i, a in enumerate(rest) if a == name and i + 1 < len(rest)]
def positional():
    out, skip = [], False
    for a in rest:
        if skip:
            skip = False
        elif a in ("--tag", "--host", "--group-by", "--keep-last", "--read-data-subset", "--repository-version"):
            skip = True
        elif not a.startswith("-"):
            out.append(a)
    return out
if cmd == "init":
    os.makedirs(repo, exist_ok=True)
    open(repo + "/config", "w").write("fake")
elif cmd == "snapshots":
    tags = flag("--tag")
    ids = positional()
    out = [s for s in snaps if all(t in s["tags"] for t in tags) and (not ids or any(s["id"].startswith(i) for i in ids))]
    print(json.dumps(out))
elif cmd == "backup":
    if plan.get("deaf"):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    else:
        signal.signal(signal.SIGTERM, lambda *a: sys.exit(143))
    for ev in plan.get("events", []):
        if "sleep" in ev:
            time.sleep(ev["sleep"])
        elif "print" in ev:
            print(ev["print"], flush=True)
            print(ev["print"], file=sys.stderr, flush=True)
        else:
            print(json.dumps(ev), flush=True)
    sid = hashlib.sha256(str(len(snaps) + time.time()).encode()).hexdigest()
    snaps.append({"id": sid, "short_id": sid[:8], "time": datetime.datetime.now().astimezone().isoformat(), "tags": flag("--tag"), "paths": [],
                  "hostname": "fake"})
    json.dump(snaps, open(HERE + "/snaps.json", "w"))
    print(json.dumps({"message_type": "summary", "snapshot_id": sid[:8], "data_added": plan.get("added", 1000), "data_added_packed": 900,
                      "total_files_processed": 10, "total_bytes_processed": 5000, "total_duration": 1.5}), flush=True)
    sys.exit(plan.get("rc", 0))
elif cmd == "forget":
    gone = positional()
    json.dump([s for s in snaps if s["id"] not in gone], open(HERE + "/snaps.json", "w"))
sys.exit(plan.get(cmd + "_rc", 0))
'''
NAMES = ["pkg%d" % i for i in range(60)]


class World:
    """A fake root with a repository, the tool's context, and the fake restic's plan and calls."""

    def __init__(self, name, **config):
        self.dir = os.path.join(WORK, name)
        self.root = self.dir + "/root"
        os.makedirs(self.root + "/usr/bin")
        os.makedirs(self.root + "/etc")
        self.restic = self.dir + "/restic"
        with open(self.restic, "w") as f:
            f.write(FAKE_RESTIC)
        os.chmod(self.restic, 0o755)
        self.ctx = tool.Ctx(self.root, self.restic)
        self.user = self.ctx.user()
        self.set_config(**config)
        with contextlib.redirect_stdout(io.StringIO()):
            tool.cmd_init(self.ctx, None)
        self.plan()

    def set_config(self, **kw):
        base = {"minFreeGB": 1}
        base.update(kw)
        cfg = self.root + self.user.pw_dir + "/.config/quickshell/config/snapshots.jsonc"
        os.makedirs(os.path.dirname(cfg), exist_ok=True)
        with open(cfg, "w") as f:
            f.write("// test\n" + json.dumps(base))

    def plan(self, **kw):
        with open(self.dir + "/plan.json", "w") as f:
            json.dump(kw, f)

    def calls(self):
        try:
            return open(self.dir + "/calls.log").read().splitlines()
        except OSError:
            return []

    def clear_calls(self):
        with contextlib.suppress(OSError):
            os.unlink(self.dir + "/calls.log")

    def snaps(self):
        try:
            return json.load(open(self.dir + "/snaps.json"))
        except OSError:
            return []

    def pkgs(self, mapping):
        base = self.root + "/var/lib/pacman/local"
        shutil.rmtree(base, ignore_errors=True)
        for n, v in mapping.items():
            os.makedirs("%s/%s-%s" % (base, n, v))
            open("%s/%s-%s/desc" % (base, n, v), "w").close()

    def fake_proc(self, chain, cmdlines=None):
        """chain = [(pid, comm, ppid), ...]; the test's own pid is added under the last one. cmdlines: {pid: [argv...]}."""
        shutil.rmtree(self.root + "/proc", ignore_errors=True)
        for pid, comm, ppid in chain + [(os.getpid(), "python3", chain[-1][0] if chain else 1)]:
            os.makedirs("%s/proc/%d" % (self.root, pid), exist_ok=True)
            fields = ["S", str(ppid)] + ["0"] * 17 + [str(1000 + pid)] + ["0"] * 10
            open("%s/proc/%d/stat" % (self.root, pid), "w").write("%d (%s) %s\n" % (pid, comm, " ".join(fields)))
            open("%s/proc/%d/cmdline" % (self.root, pid), "wb").write("\0".join((cmdlines or {}).get(pid, [comm])).encode() + b"\0")

    def hook_pre(self, names, set_proc=True):
        """`hook pre` as the tool runs it: its lines (list of text) and its status."""
        out = io.StringIO()
        old = sys.stdin
        sys.stdin = io.StringIO("\n".join(names) + "\n")
        try:
            with contextlib.redirect_stdout(out):
                rc = tool.cmd_hook_pre(self.ctx, None)
        finally:
            sys.stdin = old
        return out.getvalue().splitlines(), rc

    def hook_done(self, names=()):
        old = sys.stdin
        sys.stdin = io.StringIO("\n".join(names) + "\n")
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                return tool.cmd_hook_done(self.ctx, None)
        finally:
            sys.stdin = old

    def add_record(self, **kw):
        rec = tool.make_record(**kw)
        tool.write_record(self.ctx, rec)
        tool.write_index(self.ctx)
        return rec


def status_events(*pcts, total=1000, gap=0.0):
    out = []
    for p in pcts:
        out.append({"message_type": "status", "bytes_done": int(total * p / 100), "total_bytes": total})
        if gap:
            out.append({"sleep": gap})
    return out


def added_event(item, n):
    return {"message_type": "verbose_status", "action": "new", "item": item, "data_size": n, "data_size_in_repo": n, "metadata_size": 0, "metadata_size_in_repo": 0}


# ---- rule ------------------------------------------------------------------------------------------------------------------------
UNDO_TITLES = ["Manual", "Before the restore of 2023-11-14", "Before undoing the update of 2023-11-14", "Before an undo"]
NODE_RUNNER = r'''
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8").replace(".pragma library", "");
const lib = new Function(src + "\nreturn { wants: wants, notable: notable, title: title, matches: matches, DEFAULT_MIN_PACKAGES: DEFAULT_MIN_PACKAGES, DEFAULT_CRITICAL: DEFAULT_CRITICAL };")();
const table = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const out = table.cases.map(c => {
    const w = lib.wants(c.names, c.settings || {});
    return { want: w.want, count: w.count, critical: w.critical, notable: lib.notable(w.critical),
             title: lib.title({ reason: "update", count: w.count, critical: w.critical }) };
});
out.push({ title: [lib.title({ reason: "manual" }), lib.title({ reason: "rescue", time: 1700000000 }), lib.title({ reason: "undo", time: 1, undoneTime: 1700000000 }), lib.title({ reason: "undo", time: 1 })],
           defaults: { minPackages: lib.DEFAULT_MIN_PACKAGES, critical: lib.DEFAULT_CRITICAL } });
console.log(JSON.stringify(out));
'''


def g_rule():
    table = json.load(open(os.path.join(TREE, "tools/dev/snapshot_rule_cases.json")))
    d = snaprules.load_defaults(os.path.join(TREE, "tools/snapshot/root/defaults.json"))
    os.environ["TZ"] = "UTC"
    time.tzset()
    node = shutil.which("node")
    node_out = None
    if node:
        r = subprocess.run([node, "-e", NODE_RUNNER, os.path.join(TREE, "modules/bar/system_update/snapshots/SnapshotRules.js"),
                            os.path.join(TREE, "tools/dev/snapshot_rule_cases.json")], capture_output=True, text=True, env=dict(os.environ, TZ="UTC"))
        check("rule", "node ran", r.returncode == 0, r.stderr[-300:])
        node_out = json.loads(r.stdout) if r.returncode == 0 else None
    else:
        check("rule", "node is installed", False, "no node")
    for i, c in enumerate(table["cases"]):
        st = json.loads(json.dumps(d))
        for k, v in (c.get("settings") or {}).get("rule", {}).items():
            st["rule"][k] = v
        w = snaprules.wants(c["names"], st)
        got = {"want": w["want"], "count": w["count"], "critical": w["critical"], "notable": snaprules.notable(w["critical"]),
               "title": snaprules.title({"reason": "update", "count": w["count"], "critical": w["critical"]})}
        want = {k: c[k] for k in got}
        check("rule", "python: " + c["why"], got == want, got)
        if node_out:
            check("rule", "node: " + c["why"], node_out[i] == want, node_out[i])
        check("rule", "ascii title of at most 60: " + c["why"], got["title"].isascii() and len(got["title"]) <= 60, got["title"])
    # JS's own defaults (settings = {}) are defaults.json's
    check("rule", "defaults.json holds the contract's defaults", d["rule"]["minPackages"] == table["defaults"]["minPackages"]
          and d["rule"]["critical"] == table["defaults"]["critical"])
    if node_out:
        check("rule", "the JS default list is defaults.json's", node_out[-1]["defaults"] == {"minPackages": d["rule"]["minPackages"], "critical": d["rule"]["critical"]},
              node_out[-1]["defaults"])
        check("rule", "titles of manual, restore, undo (node)", node_out[-1]["title"] == UNDO_TITLES, node_out[-1]["title"])
    check("rule", "titles of manual, restore, undo (python)", [snaprules.title({"reason": "manual"}), snaprules.title({"reason": "rescue", "time": 1700000000}),
                                                               snaprules.title({"reason": "undo", "time": 1, "undoneTime": 1700000000}), snaprules.title({"reason": "undo", "time": 1})]
          == UNDO_TITLES)
    for g, n, want in (("a*b*c", "a-b-c", True), ("a*b*c", "ac", False), ("*", "", True), ("**", "x", True), ("ab", "ab", True), ("a*", "a", True), ("a*a", "a", False),
                       ("lib*-dev", "lib-dev", True), ("c++", "c++", True), ("a.b", "axb", False)):
        check("rule", "glob %s on %s" % (g, n), snaprules.glob_match(g, n) == want)


# ---- config ----------------------------------------------------------------------------------------------------------------------
def g_config():
    d = snaprules.load_defaults(os.path.join(TREE, "tools/snapshot/root/defaults.json"))
    sf = snaprules.settings_from
    s, p = sf(None, d)
    check("config", "no file = defaults, no problem", p == [] and s["keep"] == 5 and s["prime"] is True and s["rule"]["minPackages"] == 40, (s, p))
    check("config", "settings hold only what the user can set", "paths" not in s and "excludes" not in s)
    for key, lo, hi in (("keep", 1, 50), ("minFreeGB", 1, 500), ("maxAddedGB", 1, 500), ("maxMinutes", 1, 120)):
        s, p = sf({key: hi + 1}, d)
        check("config", key + " above the range", s[key] == hi and len(p) == 1, (s[key], p))
        s, p = sf({key: lo - 1}, d)
        check("config", key + " below the range", s[key] == lo and len(p) == 1, (s[key], p))
        s, p = sf({key: lo}, d)
        check("config", key + " at the edge is no problem", s[key] == lo and not p)
        s, p = sf({key: "5"}, d)
        check("config", key + " as text = default + problem", s[key] == d[key] and len(p) == 1, (s[key], p))
        s, p = sf({key: True}, d)
        check("config", key + " as true = default + problem", s[key] == d[key] and len(p) == 1, (s[key], p))
    s, p = sf({"rule": {"minPackages": 0}}, d)
    check("config", "minPackages 0 -> 1", s["rule"]["minPackages"] == 1 and p)
    s, p = sf({"rule": {"minPackages": 10000}}, d)
    check("config", "minPackages 10000 -> 9999", s["rule"]["minPackages"] == 9999 and p)
    s, p = sf({"enabled": "yes", "prime": 1, "onFail": "maybe", "exclude": "x", "rule": {"critical": "linux", "criticalAlso": [1]}, "offsite": {"folder": 5, "enabled": "no"}}, d)
    check("config", "wrong types = defaults, one problem each", s["enabled"] is True and s["prime"] is True and s["onFail"] == "stop" and s["exclude"] == []
          and s["rule"]["critical"] == d["rule"]["critical"] and s["rule"]["criticalAlso"] == [] and s["offsite"] == d["offsite"] and len(p) == 8, (len(p), p))
    s, p = sf([1], d)
    check("config", "a list at the top = defaults + problem", s["keep"] == 5 and len(p) == 1)
    s, p = sf({"prime": False, "onFail": "continue", "enabled": False}, d)
    check("config", "right values are taken", s["prime"] is False and s["onFail"] == "continue" and s["enabled"] is False and not p)
    # excludes
    bad = ["relative/path", "/var/lib/foo/", "/var/lib/foo/../pacman", "/var/lib/pacman", "/var/lib/pacman/local", "/var/lib", "/etc", "/usr", "/usr/share", "/home/x",
           "/var/lib/*", "/var/lib/foo?", "/var/lib/[a]", "/var/lib/a\\b", "", "/var/lib/a\nb", "/var/lib//x", "/opt", 5, None]
    good = ["/var/lib/mine", "/opt/x/y", "/srv/a", "/root/foo", "/usr/local/share/x", "/var/lib/pacman-extra"]
    for b in bad:
        check("config", "exclude refused: %r" % (b,), snaprules.exclude_problem(b) is not None, b)
    for g in good:
        check("config", "exclude accepted: %s" % g, snaprules.exclude_problem(g) is None, snaprules.exclude_problem(g))
    s, p = sf({"exclude": bad + good}, d)
    check("config", "only the good excludes stay", s["exclude"] == good and len(p) == len(bad), (s["exclude"], len(p)))
    # the file as data
    base = os.path.join(WORK, "cfg")
    os.makedirs(base + "/config")
    me = os.getuid()

    def rc(paths, uid=me):
        return snaprules.read_config(paths, uid)

    f = base + "/config/snapshots.jsonc"
    open(f, "w").write('// comment\n{ "keep": 7 /* inline */ }\n')
    raw, p = rc([f])
    check("config", "a jsonc file with comments is read", raw == {"keep": 7} and not p, (raw, p))
    raw, p = rc([base + "/config/none.jsonc"])
    check("config", "no file = no data, no problem", raw is None and p == [])
    os.symlink(f, base + "/config/link.jsonc")
    raw, p = rc([base + "/config/link.jsonc", f])
    check("config", "a link is never followed, and the next candidate is not tried", raw is None and len(p) == 1, (raw, p))
    raw, p = rc([f], uid=me + 1)
    check("config", "a file that is not yours is not read", raw is None and len(p) == 1, (raw, p))
    open(base + "/config/big.jsonc", "w").write('{"keep": 3, "x": "' + "a" * 70000 + '"}')
    raw, p = rc([base + "/config/big.jsonc"])
    check("config", "a file over 64 KB is not read", raw is None and len(p) == 1, (raw, p))
    os.makedirs(base + "/config/dir.jsonc")
    raw, p = rc([base + "/config/dir.jsonc"])
    check("config", "a directory is not read", raw is None and len(p) == 1, (raw, p))
    open(base + "/config/broken.jsonc", "w").write("{ keep: 3 ")
    raw, p = rc([base + "/config/broken.jsonc"])
    check("config", "a broken file = defaults + problem", raw is None and len(p) == 1, (raw, p))
    open(base + "/config/two.jsonc", "w").write('{"keep": 1}')
    open(base + "/config/two.json", "w").write('{"keep": 2}')
    check("config", "the .jsonc wins over the .json", rc([base + "/config/two.jsonc", base + "/config/two.json"])[0] == {"keep": 1})
    cands = snaprules.jsonc.candidates(base + "/config/snapshots.jsonc")
    check("config", "the four candidates", [os.path.relpath(c, base) for c in cands] == ["config/snapshots.jsonc", "config/snapshots.json", "snapshots.jsonc", "snapshots.json"], cands)
    # through the tool: the root's home, the user's uid
    w = World("cfg_world", keep=9, exclude=["/var/lib/mine", "/var/lib/pacman"])
    s, p = w.ctx.settings()
    check("config", "the tool reads the user's file under the root", s["keep"] == 9 and s["exclude"] == ["/var/lib/mine"] and len(p) == 1, (s["keep"], s["exclude"], p))


# ---- run -------------------------------------------------------------------------------------------------------------------------
def g_run():
    w = World("run_world")
    proc = w.root + "/proc"
    w.fake_proc([(100, "bash", 1), (200, "yay", 100), (201, "sudo", 200), (202, "pacman", 201), (203, "sh", 202)])
    rid = snaprules.run_id(os.getpid(), proc)
    check("run", "the top-most manager is the run (yay over pacman)", rid == "200:1200", rid)
    w.fake_proc([(100, "bash", 1), (202, "pacman", 100), (203, "sh", 202)])
    check("run", "a bare pacman is the run", snaprules.run_id(os.getpid(), proc) == "202:1202")
    w.fake_proc([(100, "bash", 1), (203, "sh", 100)])
    check("run", "no manager among the ancestors = no run", snaprules.run_id(os.getpid(), proc) is None)
    w.fake_proc([(100, "pamac", 1), (101, "pacman", 100), (102, "sh", 101)])
    check("run", "pamac is a manager", snaprules.run_id(os.getpid(), proc) == "100:1100")
    w.fake_proc([(100, "bash", 1), (200, "yay", 100), (202, "pacman (x) y", 200)])
    check("run", "a name with brackets and spaces is parsed", snaprules.run_id(os.getpid(), proc) == "200:1200", snaprules.run_id(os.getpid(), proc))
    w.fake_proc([(300, "pacman", 301), (301, "sh", 300)])
    check("run", "a loop of parents ends", snaprules.run_id(os.getpid(), proc) in ("300:1300", "301:1301", None))
    w.fake_proc([(200, "yay", 150), (202, "pacman", 200)])      # 150 has no /proc entry
    check("run", "an ancestor that is gone ends the walk with what was found", snaprules.run_id(os.getpid(), proc) == "200:1200")
    # a second process with the same pid but another start time is another run
    w.fake_proc([(200, "yay", 1), (202, "sh", 200)])
    a = snaprules.run_id(os.getpid(), proc)
    open("%s/200/stat" % proc, "w").write("200 (yay) S 1 " + " ".join(["0"] * 17) + " 99999 " + " ".join(["0"] * 10) + "\n")
    check("run", "the start time is part of the run", a != snaprules.run_id(os.getpid(), proc) and snaprules.run_id(os.getpid(), proc).endswith(":99999"))

    # what `hook pre` decides, from the run
    w.fake_proc([(100, "bash", 1), (200, "yay", 100), (202, "pacman", 200)])
    run = snaprules.run_id(os.getpid(), proc)
    w.add_record(short="aaaaaaaa", id="a" * 64, run=run, reason="update", state="open")
    lines, rc = w.hook_pre(NAMES)
    check("run", "a run that has its snapshot answers skip run", rc == 0 and lines and lines[-1].startswith("lares-snapshot: skip run "), lines)
    check("run", "and made no restic call", not [c for c in w.calls() if c.startswith("backup")], w.calls())
    lines, rc = w.hook_pre(["linux"])
    check("run", "skip run beats the rule (a critical package, same run)", lines[-1].startswith("lares-snapshot: skip run "), lines)
    w.fake_proc([(100, "bash", 1), (300, "yay", 100), (302, "pacman", 300)])
    lines, rc = w.hook_pre(["a", "b"])
    check("run", "another run, a small update: skip small", lines[-1].startswith("lares-snapshot: skip small "), lines)
    open(w.root + "/etc/lares/snapshot.off", "w") if os.makedirs(w.root + "/etc/lares", exist_ok=True) is None else None
    lines, rc = w.hook_pre(NAMES)
    check("run", "snapshot.off: skip off", lines[-1].startswith("lares-snapshot: skip off "), lines)
    os.unlink(w.root + "/etc/lares/snapshot.off")
    w.set_config(enabled=False)
    lines, rc = w.hook_pre(NAMES)
    check("run", "enabled false: skip off", lines[-1].startswith("lares-snapshot: skip off "), lines)
    w.set_config()
    tok = "%s/run/user/%d/lares" % (w.root, w.user.pw_uid)
    os.makedirs(tok)
    open(tok + "/snapshot-skip", "w").close()
    lines, rc = w.hook_pre(NAMES)
    check("run", "a fresh skip token: skip asked", lines[-1].startswith("lares-snapshot: skip asked "), lines)
    lines, rc = w.hook_pre(NAMES)
    check("run", "the token is not consumed", lines[-1].startswith("lares-snapshot: skip asked "), lines)
    old = time.time() - 3 * 3600
    os.utime(tok + "/snapshot-skip", (old, old))
    lines, rc = w.hook_pre(["a"])
    check("run", "a token over 2 hours old is no token", lines[-1].startswith("lares-snapshot: skip small "), lines)
    os.unlink(tok + "/snapshot-skip")
    open(tok + "/real", "w").close()
    os.symlink(tok + "/real", tok + "/snapshot-skip")
    lines, rc = w.hook_pre(["a"])
    check("run", "a token that is a link is no token", lines[-1].startswith("lares-snapshot: skip small "), lines)


# ---- record ----------------------------------------------------------------------------------------------------------------------
def g_record():
    w = World("record_world")
    w.fake_proc([(100, "bash", 1), (200, "yay", 100), (202, "pacman", 200)])
    proc = w.root + "/proc"
    run = snaprules.run_id(os.getpid(), proc)
    w.pkgs({"a": "1-1", "b": "1-1", "c": "1-1", "linux": "6.1-1"})
    keys = {"version", "id", "short", "time", "reason", "run", "count", "critical", "targets", "before", "changed", "state", "keep", "note", "added", "addedPacked", "files",
            "bytes", "seconds", "unreadable", "paths", "excludes", "kernel"}
    check("record", "a record has exactly the contract's keys", set(tool.make_record()) == keys, set(tool.make_record()) ^ keys)
    # an update with a fake restic: the record is made, and stores what it was made with
    w.plan(events=status_events(50, 100), added=4321)
    lines, rc = w.hook_pre(NAMES + ["linux"])
    recs = tool.read_records(w.ctx)
    rec = recs[0] if recs else {}
    check("record", "the update made a record", rc == 0 and len(recs) == 1 and rec.get("state") == "open" and rec.get("run") == run and rec.get("reason") == "update", (lines, rec))
    check("record", "it holds every installed package before the transaction", rec.get("before") == {"a": "1-1", "b": "1-1", "c": "1-1", "linux": "6.1-1"}, rec.get("before"))
    check("record", "it stores the excludes and paths it was made with", rec.get("excludes") and w.root + "/var/lib/ollama" in rec["excludes"] and w.root + "/root/.cache" in rec["excludes"]
          and rec.get("paths") is not None and rec.get("added") == 4321 and rec["critical"] == ["linux"] and rec["count"] == 61, (rec.get("excludes"), rec.get("paths")))
    check("record", "the index line: id, time, reason, title", open(w.ctx.index).read().splitlines() == ["%s\t%d\tupdate\tBefore 61 packages: linux" % (rec["id"], rec["time"])],
          open(w.ctx.index).read())
    check("record", "`list` carries no `before`", all("before" not in r for r in json.loads(_run(tool.cmd_list, w))["records"]))
    # the transaction runs, then `hook done`
    w.pkgs({"a": "2-1", "b": "1-1", "linux": "6.2-1", "n": "1-1"})
    w.hook_done(["a", "linux"])
    rec = tool.read_records(w.ctx)[0]
    ch = {c["name"]: (c["from"], c["to"]) for c in rec["changed"]}
    check("record", "done: what changed, from and to", ch == {"a": ("1-1", "2-1"), "c": ("1-1", None), "linux": ("6.1-1", "6.2-1"), "n": (None, "1-1")} and rec["state"] == "done", ch)
    check("record", "the changed list is sorted by name", [c["name"] for c in rec["changed"]] == sorted(c["name"] for c in rec["changed"]))
    # a second transaction of the same run: the first `from` stays, the last `to` wins
    w.pkgs({"a": "3-1", "b": "1-1", "linux": "6.2-1", "n": "1-1", "m": "1-1"})
    w.hook_done(["a"])
    rec = tool.read_records(w.ctx)[0]
    ch = {c["name"]: (c["from"], c["to"]) for c in rec["changed"]}
    check("record", "a second transaction of the run merges into the record", len(tool.read_records(w.ctx)) == 1 and ch["a"] == ("1-1", "3-1") and ch["m"] == (None, "1-1")
          and ch["linux"] == ("6.1-1", "6.2-1"), ch)
    w.pkgs({"a": "3-1", "b": "1-1", "linux": "6.2-1", "m": "1-1"})
    w.hook_done()
    ch = {c["name"]: (c["from"], c["to"]) for c in tool.read_records(w.ctx)[0]["changed"]}
    check("record", "a package installed and removed within the run is not listed", "n" not in ch, ch)
    # another run's record is not touched; no repository = nothing
    other = w.add_record(short="bbbbbbbb", id="b" * 64, run="999:1", reason="update", time=int(time.time()) + 5, state="open", before={"a": "9"})
    w.hook_done()
    check("record", "another run's record is left alone", tool.find_record(w.ctx, "bbbbbbbb")["state"] == "open" and tool.find_record(w.ctx, "bbbbbbbb")["changed"] is None)
    # the tidy is a unit of its own
    os.makedirs(w.root + "/usr/bin", exist_ok=True)
    stub = w.root + "/usr/bin/systemd-run"
    open(stub, "w").write('#!/bin/sh\necho "$@" >> "%s/spawned.log"\n' % w.dir)
    os.chmod(stub, 0o755)
    w.hook_done()
    spawned = open(w.dir + "/spawned.log").read().splitlines() if os.path.exists(w.dir + "/spawned.log") else []
    check("record", "the tidy is started with systemd-run --no-block, in idle classes", spawned and "--no-block" in spawned[-1] and "CPUSchedulingPolicy=idle" in spawned[-1]
          and "IOSchedulingClass=idle" in spawned[-1] and spawned[-1].rstrip().endswith("tidy") and "--unit=lares-snapshot-tidy" in spawned[-1], spawned)
    shutil.rmtree(w.ctx.repo)
    n = len(spawned)
    w.hook_done()
    check("record", "no repository: done does nothing", len(open(w.dir + "/spawned.log").read().splitlines()) == n)
    # the repository's size is kept in state.json by the writers and `status` reads it there (it does not walk the repository)
    w = World("record_size", minFreeGB=1)
    w.pkgs({"a": "1-1"})
    size = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(w.ctx.repo) for f in fs)
    w.plan()
    w.fake_proc([(100, "bash", 1), (801, "pacman", 100)])
    w.hook_pre(NAMES)
    check("record", "a snapshot writes the repository's size into state.json", tool.read_state(w.ctx).get("repoBytes") == sum(
        os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(w.ctx.repo) for f in fs) and tool.read_state(w.ctx)["repoBytes"] >= size, tool.read_state(w.ctx))
    open(w.ctx.repo + "/extra", "w").write("x" * 5000)
    tool.write_state(w.ctx, repoBytes=4242)
    check("record", "status reads it there, whatever the repository holds", json.loads(_run(tool.cmd_status, w))["repoBytes"] == 4242)
    check("record", "the repository is setgid, its config is group-readable only", os.stat(w.ctx.repo).st_mode & 0o7777 == 0o2750 and os.stat(w.ctx.repo + "/config").st_mode & 0o777 == 0o440,
          (oct(os.stat(w.ctx.repo).st_mode), oct(os.stat(w.ctx.repo + "/config").st_mode)))
    tool.fix_modes(w.ctx)
    check("record", "fix_modes: folders 2750, files 0440, and it counts the bytes", os.stat(w.ctx.repo + "/extra").st_mode & 0o777 == 0o440 and tool.read_state(w.ctx)["repoBytes"] >= size + 5000)
    # a snapshot inside an undo has reason undo and names what is undone
    t0 = tool.unix_of("2026-03-04T12:00:00+00:00")
    w.add_record(short="aaaa1111", id="a1" * 32, time=t0, state="done", reason="update")
    cl = {150: ["python3", "/usr/bin/lares-snapshot", "undo", "aaaa1111"]}
    w.fake_proc([(100, "bash", 1), (150, "python3", 100), (802, "pacman", 150)], cl)
    lines, rc = w.hook_pre(NAMES)
    ur = [r for r in tool.read_records(w.ctx) if r["reason"] == "undo"]
    check("record", "inside `lares-snapshot undo <short>` the snapshot is an undo's, with the short as its note", rc == 0 and len(ur) == 1 and ur[0]["note"] == "aaaa1111"
          and ur[0]["state"] == "done" and lines[0].startswith("lares-snapshot: start 60 packages"), (lines, ur))
    day = time.strftime("%Y-%m-%d", time.localtime(t0))
    idx = [l.split("\t") for l in open(w.ctx.index).read().splitlines() if "\tundo\t" in l]
    check("record", "its title is made from the undone snapshot's date", idx and idx[0][3] == "Before undoing the update of " + day, idx)
    check("record", "`list` carries the undone time", [r["undoneTime"] for r in json.loads(_run(tool.cmd_list, w))["records"] if r["reason"] == "undo"] == [t0])
    w.fake_proc([(100, "bash", 1), (151, "update-run.sh", 100), (803, "pacman", 151)], {151: ["bash", "helpers/update-run.sh", "--kind", "undo", "/run/x", "yay"]})
    w.hook_pre(NAMES)
    check("record", "inside update-run.sh --kind undo only: an undo with no name", [r["note"] for r in tool.read_records(w.ctx) if r["reason"] == "undo" and r["short"] != ur[0]["short"]] == [""])
    w.fake_proc([(100, "bash", 1), (152, "bash", 100), (804, "pacman", 152)], {152: ["bash", "-c", "echo lares-snapshot undo aaaa1111"]})
    w.hook_pre(NAMES)
    check("record", "any other command line is an update", tool.read_records(w.ctx)[0]["reason"] == "update")
    # the index: newest first, ASCII, 60 characters at most
    w2 = World("record_index")
    w2.add_record(short="11111111", id="1" * 64, time=1000, reason="manual")
    w2.add_record(short="22222222", id="2" * 64, time=3000, reason="update", count=5, critical=["linux-hardened", "linux-firmware", "qt6-declarative", "e2fsprogs"])
    w2.add_record(short="33333333", id="3" * 64, time=2000, reason="rescue")
    rows = [r.split("\t") for r in open(w2.ctx.index).read().splitlines()]
    check("record", "the index is newest first with ASCII titles of 60 at most", [r[0][0] for r in rows] == ["2", "3", "1"] and all(r[3].isascii() and len(r[3]) <= 60 for r in rows)
          and rows[0][3] == "Before 5 packages: linux-hardened, linux-firmware" and rows[2][3] == "Manual", rows)


def _run(fn, w):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        fn(w.ctx, None)
    return out.getvalue()


class Ns:
    def __init__(self, **kw):
        self.__dict__.update(kw)


# ---- guards ----------------------------------------------------------------------------------------------------------------------
def g_guards():
    w = World("guards_world", maxAddedGB=100, maxMinutes=15, minFreeGB=1)
    w.fake_proc([(100, "bash", 1), (202, "pacman", 100)])
    w.pkgs({"a": "1-1"})
    clock = lambda: time.monotonic() * 600           # one real second is ten minutes
    settings, _ = w.ctx.settings()

    def create(settings=settings, reason="update"):
        lines = tool.Lines(io.StringIO())
        try:
            tool.create_snapshot(w.ctx, settings, lines, reason, "", NAMES, None, clock)
            return None, lines
        except tool.Failure as f:
            return f, lines

    # the first snapshot (a fresh repository each time): 60 minutes, no `added` limit
    for name, plan, cfg, code in (("big", dict(events=[added_event("/f%d" % i, 5000) for i in range(3)] + [{"sleep": 3}], added=15000), dict(maxAddedGB=1), None),
                                  ("late", dict(events=[{"sleep": 7}]), {}, "time")):
        wf = World("guards_first_" + name, maxAddedGB=100, maxMinutes=15, minFreeGB=1)
        wf.pkgs({"a": "1-1"})
        wf.plan(**plan)
        st = dict(wf.ctx.settings()[0], **cfg)
        try:
            tool.create_snapshot(wf.ctx, st, tool.Lines(io.StringIO()), "update", "", NAMES, None, clock)
            f = None
        except tool.Failure as e:
            f = e
        if code is None:
            check("guards", "the first snapshot is not held to maxAddedGB and has an hour (30 minutes pass)", f is None, f and f.text)
        else:
            check("guards", "the first snapshot is stopped after 60 minutes: time", f is not None and f.code == "time" and "60 minutes" in f.text, f and (f.code, f.text))
    # a repository that has a snapshot: 15 minutes
    w.plan(events=[{"sleep": 0}])
    f, _ = create()
    check("guards", "a plain snapshot works", f is None, f and f.text)
    w.plan(events=[{"sleep": 3}])                          # 30 virtual minutes, over maxMinutes 15
    f, _ = create()
    check("guards", "after the first, maxMinutes 15 stops a 30 minute snapshot: time", f is not None and f.code == "time" and "15 minutes" in f.text, f and (f.code, f.text))
    check("guards", "restic was unlocked right after the stop", w.calls()[-1] == "unlock" and w.calls()[-2].startswith("backup"), w.calls()[-3:])
    # added: names the three largest new files seen when it trips
    pause = {"sleep": 0.4}
    w.plan(events=[added_event("/small", 10), pause, added_event("/big1", 900), pause, added_event("/big2", 800), pause, added_event("/big3", 700), pause,
                   added_event("/big4", 600), {"sleep": 2}])
    f, _ = create(dict(settings, maxAddedGB=2400))
    check("guards", "added: stops a snapshot that grows too much", f is not None and f.code == "added", f and (f.code, f.text))
    check("guards", "added: names the largest files, largest first, three at most", f is not None and f.text.index("/big1") < f.text.index("/big2") < f.text.index("/big3")
          and "/small" not in f.text and "/big4" not in f.text, f and f.text)
    f, _ = create(dict(settings, maxAddedGB=3010, maxMinutes=120))
    check("guards", "added: the limit is exceeded, not met", f is None, f and f.text)
    n = len(tool.read_records(w.ctx))
    w.plan(events=[added_event("/big", 99999), {"sleep": 2}])
    f, _ = create(dict(settings, maxAddedGB=10))
    check("guards", "a failed snapshot leaves no new record", f is not None and len(tool.read_records(w.ctx)) == n, (n, len(tool.read_records(w.ctx))))
    # restic that will not die: TERM, then KILL
    w.plan(deaf=True, events=[added_event("/big", 99999), {"sleep": 40}])
    t0 = time.time()
    f, _ = create(dict(settings, maxAddedGB=10))
    took = time.time() - t0
    check("guards", "a restic deaf to TERM is killed after ten seconds", f is not None and f.code == "added" and 9 < took < 20, (f and f.code, took))
    check("guards", "...and nothing of it is left", subprocess.run(["pgrep", "-f", w.restic], capture_output=True).returncode != 0)
    # space
    w.plan()
    s2 = dict(settings, minFreeGB=2 ** 50)
    f, _ = create(s2)
    check("guards", "space: not enough room, no restic backup was started", f is not None and f.code == "space" and not [c for c in w.calls() if c.startswith("backup")][-1:] == ["x"], f and f.text)
    w.clear_calls()
    f, _ = create(s2)
    check("guards", "space: refused before restic backup", f is not None and f.code == "space" and not any(c.startswith("backup") for c in w.calls()), (f and f.code, w.calls()))
    # the transaction's own need counts
    import tarfile
    os.makedirs(w.root + "/var/lib/pacman/sync", exist_ok=True)
    db = w.root + "/var/lib/pacman/sync/core.db"
    with tarfile.open(db, "w") as tf:
        for n, c, i in (("pkg1", 1000, 5000), ("pkg2", 200, 300)):
            data = ("%%NAME%%\n%s\n\n%%CSIZE%%\n%d\n\n%%ISIZE%%\n%d\n" % (n, c, i)).encode()
            ti = tarfile.TarInfo("%s-1.0-1/desc" % n)
            ti.size = len(data)
            tf.addfile(ti, io.BytesIO(data))
    w.pkgs({"pkg1": "0.9-1"})
    open(w.root + "/var/lib/pacman/local/pkg1-0.9-1/desc", "w").write("%SIZE%\n2000\n")
    need = tool.transaction_need(w.ctx, ["pkg1", "pkg2", "nothere"])
    check("guards", "the transaction's own need: downloads plus growth", need == 1000 + (5000 - 2000) + 200 + 300, need)
    check("guards", "a broken sync database is no need and no crash", tool.transaction_need(tool.Ctx(w.root + "/nowhere", w.restic), ["x"]) == 0)
    # the hook: failed lines, onFail
    w.plan(events=[added_event("/big", 99999), {"sleep": 2}])
    w.set_config(maxAddedGB=10, minFreeGB=1)
    lines, rc = w.hook_pre(NAMES)
    check("guards", "hook: failed added exits 1 with a notice before it", rc == 1 and lines[-1].startswith("lares-snapshot: failed added ") and any(l.startswith("lares-snapshot: notice ") for l in lines), lines)
    w.set_config(maxAddedGB=10, minFreeGB=1, onFail="continue")
    lines, rc = w.hook_pre(NAMES)
    check("guards", "hook: onFail continue still says failed but exits 0", rc == 0 and lines[-1].startswith("lares-snapshot: failed added "), (rc, lines))
    # a restic that fails by itself
    w.set_config()
    w.plan(rc=1, events=[{"print": "Fatal: wrong password"}])
    lines, rc = w.hook_pre(NAMES)
    check("guards", "hook: a restic error is failed restic with its words", rc == 1 and lines[-1].startswith("lares-snapshot: failed restic ") and "wrong password" in lines[-1], lines)
    w.plan(rc=11)
    lines, rc = w.hook_pre(NAMES)
    check("guards", "hook: restic's lock error is failed lock", rc == 1 and lines[-1].startswith("lares-snapshot: failed lock "), lines)
    w.plan(rc=3, events=[{"message_type": "error", "error": "x", "item": "/a"}])
    lines, rc = w.hook_pre(NAMES)
    check("guards", "hook: unreadable files are a notice, the snapshot stands", rc == 0 and lines[-1].startswith("lares-snapshot: done ") and any("could not be read" in l for l in lines), lines)
    # a job already running
    w.plan()
    w.fake_proc([(100, "bash", 1), (910, "pacman", 100)])
    d = os.open(w.ctx.oplock, os.O_RDWR | os.O_CREAT, 0o600)
    import fcntl
    fcntl.flock(d, fcntl.LOCK_EX)
    wait_old = tool.WAIT_OTHER
    tool.WAIT_OTHER = 1
    pid_state = w.ctx.statefile
    other = subprocess.Popen(["sleep", "60"])
    json.dump({"busy": "delete", "pid": other.pid, "preemptible": False}, open(pid_state, "w"))
    lines, rc = w.hook_pre(NAMES)
    check("guards", "hook: another job running is failed lock", rc == 1 and lines[-1].startswith("lares-snapshot: failed lock "), lines)
    tool.WAIT_OTHER = wait_old
    check("guards", "...and the other job was left alone", other.poll() is None)
    other.kill()
    other.wait()
    os.close(d)
    json.dump({}, open(pid_state, "w"))


# ---- lines -----------------------------------------------------------------------------------------------------------------------
def g_lines():
    class Clk:
        t = 0.0

        def __call__(self):
            return self.t

    clk = Clk()
    out = io.StringIO()
    ln = tool.Lines(out, clock=clk)
    for t, pct in ((0, 3), (0.1, 7), (0.5, 12), (1.2, 12), (1.3, 12), (2.5, 9), (2.6, 31), (3.8, 33), (5.0, 50), (5.1, 70), (6.2, 99), (7.4, 100)):
        clk.t = t
        ln.progress(pct)
    got = [int(l.split()[-1]) for l in out.getvalue().splitlines()]
    check("lines", "progress rises only, in steps of 5, one a second at most, never past 95", got == [5, 10, 30, 50, 95], got)
    check("lines", "the progress line's shape", all(l.startswith("lares-snapshot: progress ") for l in out.getvalue().splitlines()))
    out = io.StringIO()
    ln = tool.Lines(out)
    for i in range(100):
        ln.emit("notice", "n%d" % i)
    ln.emit("done", "x added=1 seconds=1", final=True)
    rows = out.getvalue().splitlines()
    check("lines", "at most 25 lines, and the last one still fits", len(rows) == 25 and rows[-1] == "lares-snapshot: done x added=1 seconds=1", (len(rows), rows[-1]))
    out = io.StringIO()
    tool.Lines(out).emit("failed", "restic  bad\ntext\twith   breaks", final=True)
    check("lines", "a text is one line", out.getvalue() == "lares-snapshot: failed restic bad text with breaks\n", out.getvalue())

    # a whole run through the hook, with a restic that is noisy on stdout and stderr
    w = World("lines_world", minFreeGB=1)
    w.fake_proc([(100, "bash", 1), (202, "pacman", 100)])
    w.pkgs({"a": "1-1"})
    w.plan(events=[{"print": "noise on stdout and stderr"}] + status_events(10, gap=1.1) + status_events(40, gap=1.1) + status_events(70, gap=1.1) + status_events(100)
           + [added_event("/a", 5)], added=77)
    t0 = time.time()
    lines, rc = w.hook_pre(NAMES + ["linux", "mesa", "nvidia-open"])
    import re
    shape = re.compile(r"^lares-snapshot: (start|progress|done|skip|failed|notice)( .*)?$")
    check("lines", "every line is a contract line", rc == 0 and all(shape.match(l) for l in lines), lines)
    check("lines", "restic's own output never reaches the hook's stdout", not any("noise" in l for l in lines), lines)
    check("lines", "start first, done last, exactly one end", lines[0] == "lares-snapshot: start 63 packages: linux, nvidia-open, mesa" and re.match(r"^lares-snapshot: done [0-9a-f]{8} added=77 seconds=\d+$", lines[-1])
          and sum(1 for l in lines if re.match(r"lares-snapshot: (done|skip|failed)", l)) == 1, lines)
    pr = [int(l.split()[-1]) for l in lines if " progress " in l]
    check("lines", "progress rose in steps of 5", pr == sorted(set(pr)) and len(pr) >= 3 and all(p % 5 == 0 and p <= 95 for p in pr), pr)
    check("lines", "restic's stderr went to the log", "noise on stdout and stderr" in open(w.ctx.log).read())
    w.fake_proc([(100, "bash", 1), (911, "pacman", 100)])
    l, _ = w.hook_pre(["a"])
    check("lines", "a skip line: code and words", re.match(r"^lares-snapshot: skip small \d+ packages?, nothing important$", l[-1]) is not None, l)


# ---- undo ------------------------------------------------------------------------------------------------------------------------
def g_undo():
    base = os.path.join(WORK, "undo")
    cache, home = base + "/cache", base + "/home"
    for d in (cache, home + "/.cache/yay/foo-aur", home + "/.cache/yay/other", base + "/sync"):
        os.makedirs(d)
    cli.CACHE_DIR = cache
    cli.SYNC_DIR = base + "/sync"
    cli.FAKE_ROOT = base + "/fakeroot"
    for n in ("glibc-2.40-1-x86_64.pkg.tar.zst", "tzdata-2024a-1-any.pkg.tar.xz", "old-1.0-1-x86_64.pkg.tar.gz", "alsa-1:1.6.10-1-x86_64.pkg.tar.zst",
              "foo-1.0-1-extra-x86_64.pkg.tar.zst", "both-1.0-1-x86_64.pkg.tar.zst"):
        open(os.path.join(cache, n), "w").close()
    open(home + "/.cache/yay/foo-aur/foo-aur-2.0-1-x86_64.pkg.tar.zst", "w").close()
    open(home + "/.cache/yay/other/both-1.0-1-x86_64.pkg.tar.zst", "w").close()
    import tarfile
    with tarfile.open(base + "/sync/core.db", "w") as tf:
        for n in ("glibc-2.40-1", "official-3.0-1", "tzdata-2024a-1", "alsa-1:1.6.10-1", "both-1.0-1", "foo-1.0-1", "old-1.0-1", "gone-1.0-1"):
            ti = tarfile.TarInfo(n)
            ti.type = tarfile.DIRTYPE
            tf.addfile(ti)
    official = cli.official_names()
    check("undo", "the sync databases give the official names", {"glibc", "official", "tzdata", "alsa", "both", "foo", "old", "gone"} == official, official)
    asked = []

    def head(url):
        asked.append(url)
        return url.endswith("official-3.0-1-x86_64.pkg.tar.zst") or "%3A" in url and url.endswith("x86_64.pkg.tar.zst") and "archived" in url

    before = {"glibc": "2.40-1", "tzdata": "2024a-1", "old": "1.0-1", "alsa": "1:1.6.10-1", "foo": "1.0-1", "foo-aur": "2.0-1", "both": "1.0-1", "official": "3.0-1",
              "gone": "1.0-1", "aurmissing": "1-1", "same": "1-1", "removedpkg": "1-1", "archived": "1:7-1"}
    now = {"glibc": "2.41-1", "tzdata": "2025a-1", "old": "1.1-1", "alsa": "1:1.6.11-1", "foo": "1.1-1", "foo-aur": "2.1-1", "both": "1.1-1", "official": "3.1-1",
           "gone": "1.1-1", "aurmissing": "2-1", "same": "1-1", "archived": "1:8-1", "newpkg": "1-1"}
    official = official | {"archived"}
    rec = {"short": "6a493314", "before": before}
    plan = cli.plan_undo(rec, now, home, official, head)
    files = {f["name"]: f for f in plan["files"]}
    check("undo", "the plan has the contract's keys", set(plan) == {"ok", "short", "files", "missing", "blockedBy", "takenOver", "newSince", "removedSince"} and plan["ok"] is True and plan["blockedBy"] == [] and plan["short"] == "6a493314", set(plan))
    check("undo", "a file entry has name, now, to, source, path", all(set(f) == {"name", "now", "to", "source", "path"} for f in plan["files"]))
    check("undo", "the pacman cache: zst, xz, gz; any and x86_64", files.get("glibc", {}).get("source") == "pacman" and files.get("glibc", {}).get("path", "").endswith("glibc-2.40-1-x86_64.pkg.tar.zst")
          and files.get("tzdata", {}).get("path", "").endswith("tzdata-2024a-1-any.pkg.tar.xz") and files.get("old", {}).get("path", "").endswith("old-1.0-1-x86_64.pkg.tar.gz"), files)
    check("undo", "an epoch colon is matched as it stands", files.get("alsa", {}).get("path", "").endswith("alsa-1:1.6.10-1-x86_64.pkg.tar.zst"), files.get("alsa"))
    check("undo", "a file whose name only starts alike is not the file", "foo" not in files or files["foo"]["source"] != "pacman", files.get("foo"))
    check("undo", "yay's build folders are looked in", files.get("foo-aur", {}).get("source") == "yay" and "/.cache/yay/foo-aur/" in files.get("foo-aur", {}).get("path", ""), files.get("foo-aur"))
    check("undo", "the cache comes before yay", files.get("both", {}).get("source") == "pacman", files.get("both"))
    check("undo", "the archive for an official package, as a URL", files.get("official", {}).get("source") == "archive"
          and files.get("official", {}).get("path") == "https://archive.archlinux.org/packages/o/official/official-3.0-1-x86_64.pkg.tar.zst", files.get("official"))
    check("undo", "the archive URL encodes the epoch's colon", "archived" in files and files.get("archived", {}).get("path", "").endswith("/a/archived/archived-1%3A7-1-x86_64.pkg.tar.zst"), files.get("archived"))
    check("undo", "an AUR package that is nowhere is never asked of the archive", not any("aurmissing" in u for u in asked), asked)
    check("undo", "missing ones are listed with now and to", {"name": "aurmissing", "now": "2-1", "to": "1-1"} in plan["missing"]
          and {"name": "foo", "now": "1.1-1", "to": "1.0-1"} in plan["missing"] and {"name": "gone", "now": "1.1-1", "to": "1.0-1"} in plan["missing"], plan["missing"])
    check("undo", "an unchanged package is not in the plan", "same" not in files and not any(m["name"] == "same" for m in plan["missing"]))
    check("undo", "new since", plan["newSince"] == ["newpkg"], plan["newSince"])
    check("undo", "removed since", plan["removedSince"] == [{"name": "removedpkg", "to": "1-1"}], plan["removedSince"])
    check("undo", "the plan is complete before anything runs (the HEAD requests were all made in the plan)", len(asked) >= 3)
    # a missing package that the rule calls critical blocks the undo; the others are listed and left
    plan2 = cli.plan_undo(rec, now, home, official, head, critical=["gone", "nvidia*"])
    check("undo", "a critical package with no file blocks: ok false, blockedBy names it", plan2["ok"] is False and plan2["blockedBy"] == ["gone"], (plan2["ok"], plan2["blockedBy"]))
    check("undo", "no critical package missing: ok stays true with the others left", plan["ok"] is True and len(plan["missing"]) == 4)
    check("undo", "nothing found at all: ok false, blockedBy empty", cli.plan_undo({"short": "x", "before": {"zz": "1-1"}}, {"zz": "2-1"}, home, set(), head)["ok"] is False)
    # a package installed since owns a file an old one brings (openssl-3 took libcrypto.so.3): pacman would refuse, so the plan says no
    import gzip as _gz
    import io as _io

    def build(path, paths):
        mtree = _gz.compress(("#mtree\n" + "".join("./%s time=1.0 mode=644 size=1\n" % q for q in paths) + "./usr time=1.0 type=dir\n").encode())
        with tarfile.open(path, "w:zst") as tf:
            for name, data in ((".BUILDINFO", b"x"), (".MTREE", mtree), (".PKGINFO", b"x"), ("usr/lib/x", b"x")):
                ti = tarfile.TarInfo(name)
                ti.size = len(data)
                tf.addfile(ti, _io.BytesIO(data))

    def installed_pkg(root, name, version, paths, conflicts=()):
        d = "%s/var/lib/pacman/local/%s-%s" % (root, name, version)
        os.makedirs(d)
        with open(d + "/files", "w") as f:
            f.write("%FILES%\nusr/\nusr/lib/\n" + "\n".join(paths) + "\n\n%BACKUP%\nusr/lib/notafile\n")
        with open(d + "/desc", "w") as f:
            f.write("%%NAME%%\n%s\n\n" % name + ("%CONFLICTS%\n" + "\n".join(conflicts) + "\n\n" if conflicts else ""))

    r = base + "/takenroot"
    build(cache + "/ssl-3.6-1-x86_64.pkg.tar.zst", ["usr/lib/libcrypto.so.3", r"usr/share/with\040space"])
    build(cache + "/oldname-1.0-1-x86_64.pkg.tar.zst", ["usr/bin/thing"])
    installed_pkg(r, "ssl", "4.0-1", ["usr/lib/libcrypto.so.4"])
    installed_pkg(r, "ssl-3", "3.6-1", ["usr/lib/libcrypto.so.3"])
    installed_pkg(r, "newname", "1.0-1", ["usr/bin/thing"], ["oldname>=0"])
    installed_pkg(r, "other", "1-1", ["usr/bin/other"])
    nowt = {"ssl": "4.0-1", "ssl-3": "3.6-1", "newname": "1.0-1", "other": "1-1"}
    pt = cli.plan_undo({"short": "t", "before": {"ssl": "3.6-1", "oldname": "1.0-1"}}, nowt, home, set(), head, root=r)
    check("undo", "a file taken over by a package installed since blocks, and names both", pt["ok"] is False
          and pt["takenOver"] == [{"name": "ssl", "owner": "ssl-3", "path": "/usr/lib/libcrypto.so.3"}], pt["takenOver"])
    check("undo", "a rename (the new package conflicts with the old by name) does not: pacman asks", all(t["owner"] != "newname" for t in pt["takenOver"]), pt["takenOver"])
    check("undo", "a package's paths come from .MTREE, with escapes read, folders left out", cli.package_paths(cache + "/ssl-3.6-1-x86_64.pkg.tar.zst")
          == {"usr/lib/libcrypto.so.3", "usr/share/with space"}, cli.package_paths(cache + "/ssl-3.6-1-x86_64.pkg.tar.zst"))
    pt2 = cli.plan_undo({"short": "t", "before": {"ssl": "3.6-1"}}, {"ssl": "4.0-1", "other": "1-1"}, home, set(), head, root=r)
    check("undo", "a package installed since that took nothing over does not block", pt2["ok"] is True and pt2["takenOver"] == [], pt2)
    cli.current_plan = lambda short: pt
    out = io.StringIO()
    err = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = cli.cmd_undo(argparse.Namespace(short="t", print=False))
    check("undo", "the CLI refuses it (4), says who owns what and names the rescue", rc == 4 and "ssl-3, installed since, now owns /usr/lib/libcrypto.so.3" in err.getvalue()
          and "rescue" in err.getvalue(), (rc, err.getvalue()))
    cli.current_plan = lambda short: plan2
    out = io.StringIO()
    err = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = cli.cmd_undo(Ns(short="6a493314", print=True))
    check("undo", "a blocking package refuses the undo and runs nothing", rc == 4 and out.getvalue() == "" and "gone" in err.getvalue(), (rc, out.getvalue(), err.getvalue()))
    ok_plan = plan
    cli.current_plan = lambda short: ok_plan
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = cli.cmd_undo(Ns(short="6a493314", print=True))
    rows = out.getvalue().splitlines()
    cmd = rows[-1].split()
    check("undo", "the others stay: said before the command, which is one pacman -U with every found file", rc == 0 and sum(1 for r in rows if r.startswith("stays as it is (no package file found): ")) == 4
          and cmd[:5] == ["sudo", "pacman", "-U", "--", ok_plan["files"][0]["path"]] and out.getvalue().count("pacman") == 1 and len(cmd) == 4 + len(ok_plan["files"]), out.getvalue())
    check("undo", "never --noconfirm", "--noconfirm" not in out.getvalue() and "noconfirm" not in out.getvalue())
    os.environ["SUDO_ASKPASS"] = "/x/askpass"
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        cli.cmd_undo(Ns(short="6a493314", print=True))
    del os.environ["SUDO_ASKPASS"]
    check("undo", "-A when SUDO_ASKPASS is set", out.getvalue().splitlines()[-1].split()[:3] == ["sudo", "-A", "pacman"], out.getvalue())
    cli.current_plan = lambda short: dict(plan, files=[], missing=[], ok=False)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = cli.cmd_undo(Ns(short="6a493314", print=True))
    check("undo", "nothing to undo is exit 3", rc == 3, rc)
    # the CLI itself: a fake root with one package to put back, and a `sudo` that is a script
    fr = base + "/fr"
    os.makedirs(fr + "/.lares-snapshots/records")
    os.makedirs(fr + "/var/cache/pacman/pkg")
    os.makedirs(fr + "/var/lib/pacman/local/pp-2-1")
    open(fr + "/var/lib/pacman/local/pp-2-1/desc", "w").close()
    open(fr + "/var/cache/pacman/pkg/pp-1-1-x86_64.pkg.tar.zst", "w").close()
    json.dump({"short": "aaaaaaaa", "before": {"pp": "1-1"}}, open(fr + "/.lares-snapshots/records/aaaaaaaa.json", "w"))
    sb = base + "/sbin"
    os.makedirs(sb)
    with open(sb + "/sudo", "w") as f:
        f.write('#!/bin/sh\necho "$@" > "$OUT/args"\necho "$PPID" > "$OUT/ppid"\ntrap \'echo int > "$OUT/int"; exit 130\' INT\n'
                '[ -n "$QUICK" ] && exit 7\necho ready > "$OUT/ready"\ni=0; while [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done\n')
    os.chmod(sb + "/sudo", 0o755)
    env = dict(os.environ, LARES_SNAPSHOT_ROOT=fr, HOME=home, OUT=base, PATH=sb + ":" + os.environ["PATH"])
    cliscript = os.path.join(TREE, "tools/snapshot/lares-snapshot")
    r = subprocess.run([sys.executable, "-B", cliscript, "undo", "aaaaaaaa"], env=dict(env, QUICK="1"), capture_output=True, text=True)
    check("undo", "the CLI returns the status of what it ran", r.returncode == 7 and open(base + "/args").read().split()[:3] == ["pacman", "-U", "--"], (r.returncode, r.stderr[-200:]))
    ppid = int(open(base + "/ppid").read())
    check("undo", "sudo ran as a child of the CLI, which is not replaced", ppid != 0 and ppid != os.getpid(), ppid)
    # a runner started in the background has SIGINT ignored, and an ignored signal survives exec: the child gets the terminal's default back
    p = subprocess.Popen([sys.executable, "-B", cliscript, "undo", "aaaaaaaa"], env=env, start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                         preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
    try:
        for _ in range(100):
            if os.path.exists(base + "/ready"):
                break
            time.sleep(0.1)
        check("undo", "the run's ancestor is the CLI (`lares-snapshot undo <short>` in its command line)", p.pid == int(open(base + "/ppid").read())
              and "undo\0aaaaaaaa" in open("/proc/%d/cmdline" % p.pid).read(), open(base + "/ppid").read())
        os.killpg(p.pid, signal.SIGINT)             # Ctrl-C: the terminal sends it to the whole group
        rc = p.wait(timeout=10)
        check("undo", "Ctrl-C reaches sudo and the CLI waits for it: its status 130 comes back", rc == 130 and os.path.exists(base + "/int"), (rc, p.stderr.read()[-200:]))
    finally:
        # an armed copy that leaves it running must not leave it on the machine
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    # the HEAD request itself, against a local server
    import http.server

    class H(http.server.BaseHTTPRequestHandler):
        def do_HEAD(self):
            if self.path.endswith("slow.zst"):
                time.sleep(3)
            self.send_response(200 if self.path.endswith(".zst") else 404)
            self.end_headers()

        def log_message(self, *a):
            pass

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = "http://127.0.0.1:%d" % srv.server_address[1]
    cli.HEAD_TIMEOUT = 1
    check("undo", "HEAD: 200 is yes", cli.archive_has(url + "/a/b.zst") is True)
    check("undo", "HEAD: 404 is no", cli.archive_has(url + "/a/b.xz") is False)
    t0 = time.time()
    check("undo", "HEAD: a slow server is no, within the timeout", cli.archive_has(url + "/a/slow.zst") is False and time.time() - t0 < 2.5, time.time() - t0)
    srv.shutdown()
    t0 = time.time()
    check("undo", "HEAD: a closed port is no, quickly", cli.archive_has(url + "/a/b.zst") is False and time.time() - t0 < 2)


# ---- retention -------------------------------------------------------------------------------------------------------------------
def g_retention():
    w = World("ret_world", keep=3)
    for i in range(8):
        w.add_record(short="%08d" % i, id=("%x" % i) * 64, time=1000 + i * 100, keep=i in (1, 2), reason="update", state="done")
    settings, _ = w.ctx.settings()
    w.plan()
    json.dump([], open(w.dir + "/snaps.json", "w"))
    ids = tool.tidy_ids(w.ctx, settings)
    # newest three (7, 6, 5) stay; 4, 3, 0 go; 1 and 2 are kept
    check("retention", "tidy forgets what is past the newest `keep` and not kept", sorted(ids) == sorted(("%x" % i) * 64 for i in (0, 3, 4)), sorted(i[0] for i in ids))
    check("retention", "...never a kept one", ("%x" % 1) * 64 not in ids and ("%x" % 2) * 64 not in ids)
    w.set_config(keep=8)
    check("retention", "with room for all, nothing is forgotten", tool.tidy_ids(w.ctx, w.ctx.settings()[0]) == [])
    w.set_config(keep=3)
    # delete
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = tool.cmd_delete(w.ctx, Ns(short="00000001"))
    check("retention", "delete of a kept snapshot is refused (4), restic untouched", rc == 4 and not any(c.startswith("forget") for c in w.calls()) and tool.find_record(w.ctx, "00000001"), (rc, w.calls()))
    with contextlib.redirect_stdout(io.StringIO()):
        rc = tool.cmd_keep(w.ctx, Ns(short="00000001", state="off"))
    check("retention", "keep off, then delete works", rc == 0 and not tool.find_record(w.ctx, "00000001")["keep"], rc)
    snaps = [{"id": ("%x" % i) * 64, "short_id": ("%x" % i) * 8, "time": "2026-01-01T00:00:00+00:00", "tags": ["lares", "update"], "paths": []} for i in range(8)]
    json.dump(snaps, open(w.dir + "/snaps.json", "w"))
    with contextlib.redirect_stdout(io.StringIO()):
        rc = tool.cmd_delete(w.ctx, Ns(short="00000001"))
    check("retention", "delete forgets and prunes that one id and drops its record and index line", rc == 0 and any(c == "forget --prune --max-unused 20% " + "1" * 64 for c in w.calls())
          and not tool.find_record(w.ctx, "00000001") and "1" * 64 not in open(w.ctx.index).read(), (rc, w.calls()[-3:]))
    with contextlib.redirect_stdout(io.StringIO()):
        rc = tool.cmd_delete(w.ctx, Ns(short="deadbeef"))
    check("retention", "an unknown snapshot is exit 3", rc == 3, rc)
    with contextlib.redirect_stdout(io.StringIO()):
        tool.cmd_keep(w.ctx, Ns(short="00000002", state="off"))
        tool.cmd_keep(w.ctx, Ns(short="00000002", state="on"))
    check("retention", "keep on is recorded in the record and in state.json (not a restic tag)", tool.find_record(w.ctx, "00000002")["keep"] and ("2" * 64) in tool.read_state(w.ctx)["keeps"]
          and not any(c.startswith("tag") for c in w.calls()), tool.read_state(w.ctx))
    # the monthly check
    w.clear_calls()
    json.dump(snaps, open(w.dir + "/snaps.json", "w"))
    with contextlib.redirect_stdout(io.StringIO()):
        tool.cmd_tidy(w.ctx, None)
    first = [c for c in w.calls() if c.startswith("check")]
    check("retention", "the first tidy checks 5 % of the data", first == ["check --read-data-subset=5%"] and tool.read_state(w.ctx)["check"]["ok"] is True, w.calls())
    w.clear_calls()
    json.dump(snaps, open(w.dir + "/snaps.json", "w"))
    with contextlib.redirect_stdout(io.StringIO()):
        tool.cmd_tidy(w.ctx, None)
    check("retention", "the next tidy within a month does not", not [c for c in w.calls() if c.startswith("check")], w.calls())
    tool.write_state(w.ctx, check={"time": int(time.time()) - 31 * 86400, "ok": True, "text": "old"})
    w.clear_calls()
    json.dump(snaps, open(w.dir + "/snaps.json", "w"))
    with contextlib.redirect_stdout(io.StringIO()):
        tool.cmd_tidy(w.ctx, None)
    check("retention", "a month later it does again", len([c for c in w.calls() if c.startswith("check")]) == 1, w.calls())
    w.plan(check_rc=1)
    tool.write_state(w.ctx, check=None)
    with contextlib.redirect_stdout(io.StringIO()):
        tool.cmd_tidy(w.ctx, None)
    check("retention", "a failed check is recorded as not ok", tool.read_state(w.ctx)["check"]["ok"] is False and "problem" in tool.read_state(w.ctx)["check"]["text"], tool.read_state(w.ctx))


# ---- prime -----------------------------------------------------------------------------------------------------------------------
HOLDER = r'''
import fcntl, json, os, signal, sys, time
state = sys.argv[1]
fd = os.open(state + "/oplock", os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
json.dump({"busy": sys.argv[3] if len(sys.argv) > 3 else "tidy", "pid": os.getpid(), "preemptible": sys.argv[2] == "1"}, open(state + "/state.json", "w"))
def stop(*a):
    os.close(fd)
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
print("held", flush=True)
time.sleep(float(sys.argv[4]) if len(sys.argv) > 4 else 60)
'''


def g_prime():
    w = World("prime_world", minFreeGB=1, maxAddedGB=100)
    w.fake_proc([(100, "bash", 1), (202, "pacman", 100)])
    w.pkgs({"a": "1-1"})
    settings, _ = w.ctx.settings()
    # no real snapshot yet: nothing to prepare for
    w.plan(events=[])
    tool.prime(w.ctx, settings)
    check("prime", "with no real snapshot there is no prime", not any(c.startswith("backup") for c in w.calls()), w.calls())
    w.add_record(short="aaaaaaaa", id="a" * 64, time=int(time.time()) - 3600, state="done", reason="update")
    w.clear_calls()
    tool.prime(w.ctx, settings)
    bk = [c for c in w.calls() if c.startswith("backup")]
    check("prime", "the prime is a backup tagged lares-prime and nothing else", len(bk) == 1 and "--tag lares-prime" in bk[0] and "--tag lares " not in bk[0] and "--tag update" not in bk[0], bk)
    check("prime", "the prime groups by host (the parent is found across snapshots and primes)", "--group-by host" in bk[0], bk)
    check("prime", "it makes no record and no index line", len(tool.read_records(w.ctx)) == 1 and open(w.ctx.index).read().count("\n") == 1)
    check("prime", "`list` never shows it, and the restic list the tool reads (tag lares) does not hold it", [s["tags"] for s in tool.list_snapshots(w.ctx)] == []
          and len(w.snaps()) == 1, (tool.list_snapshots(w.ctx), w.snaps()))
    check("prime", "the same paths and excludes as a snapshot", "--exclude %s/var/lib/ollama" % w.root in bk[0] and "--one-file-system" in bk[0], bk[0][:200])
    # prime: false
    w.clear_calls()
    tool.prime(w.ctx, dict(settings, prime=False))
    check("prime", "prime false: no backup", not any(c.startswith("backup") for c in w.calls()), w.calls())
    # a failing prime is one log line
    w.plan(events=[added_event("/big", 99999), {"sleep": 2}])
    before = open(w.ctx.log).read()
    try:
        tool.prime(w.ctx, dict(settings, maxAddedGB=10))
        raised = False
    except tool.Failure:
        raised = True
    check("prime", "a prime obeys maxAddedGB, and its failure is a log line, not an error", not raised and "prime failed added" in open(w.ctx.log).read()[len(before):])
    # tidy_ids: primes
    snaps = [{"id": "%064x" % i, "short_id": "%08x" % i, "time": "2026-01-0%dT00:00:00+00:00" % i, "tags": ["lares-prime"], "paths": []} for i in (1, 2, 3)]
    json.dump(snaps, open(w.dir + "/snaps.json", "w"))
    w.add_record(short="bbbbbbbb", id="b" * 64, time=tool.unix_of("2026-01-02T12:00:00+00:00"),
                 state="done", reason="update")
    for r in tool.read_records(w.ctx):
        if r["short"] == "aaaaaaaa":
            os.unlink("%s/aaaaaaaa.json" % w.ctx.records)
    ids = tool.tidy_ids(w.ctx, settings)
    check("prime", "a real snapshot newer than a prime: that prime goes, the ones before it too (none is kept)", sorted(ids) == sorted("%064x" % i for i in (1, 2, 3)) or
          sorted(ids) == sorted("%064x" % i for i in (1, 2)), ids)
    os.unlink("%s/bbbbbbbb.json" % w.ctx.records)
    w.add_record(short="cccccccc", id="c" * 64, time=tool.unix_of("2025-12-01T00:00:00+00:00"), state="done", reason="update")
    ids = tool.tidy_ids(w.ctx, settings)
    check("prime", "the real snapshot is older: every prime but the newest goes", sorted(ids) == sorted("%064x" % i for i in (1, 2)), ids)
    # an update takes the repository from a prime
    def holder(preemptible):
        p = subprocess.Popen([sys.executable, "-c", HOLDER, w.ctx.state, "1" if preemptible else "0"], stdout=subprocess.PIPE, text=True)
        p.stdout.readline()
        return p

    h = holder(True)
    t0 = time.time()
    with tool.operation(w.ctx, "create", preempt=True):
        got = tool.read_state(w.ctx)["busy"]
    check("prime", "a running tidy is told to stop (TERM) and the update goes on", got == "create" and h.wait(timeout=5) == 0 and time.time() - t0 < 5, (got, time.time() - t0))
    h = holder(False)
    wait_old = tool.WAIT_OTHER
    tool.WAIT_OTHER = 1
    try:
        with tool.operation(w.ctx, "create", preempt=True):
            took = True
    except tool.Busy:
        took = False
    tool.WAIT_OTHER = wait_old
    alive = h.poll() is None
    h.kill()
    h.wait()
    check("prime", "a job that is not a tidy is never stopped", not took and alive, (took, alive, tool.read_state(w.ctx)))
    h = holder(True)
    try:
        with tool.operation(w.ctx, "tidy"):
            took = True
    except tool.Busy:
        took = False
    alive = h.poll() is None
    h.kill()
    h.wait()
    check("prime", "without preempt even a tidy is waited for (a second tidy)", not took and alive, (took, alive))
    # the tidy told to stop: unlock, status 3, and the packs it wrote are indexed by the next backup
    json.dump([], open(w.dir + "/snaps.json", "w"))
    w.plan(events=[{"sleep": 20}])
    w.clear_calls()
    tool.write_state(w.ctx, unindexed=False)
    p = subprocess.Popen([sys.executable, "-B", os.path.join(TREE, TOOL_FILE), "--root", w.root, "--restic", w.restic, "tidy"], env=dict(os.environ), stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True)
    for _ in range(100):
        if any(c.startswith("backup") for c in w.calls()):
            break
        time.sleep(0.1)
    time.sleep(0.3)
    p.send_signal(signal.SIGTERM)
    rc = p.wait(timeout=20)
    check("prime", "a tidy told to stop ends with status 3 and unlocks", rc == 3 and w.calls()[-1] == "unlock", (rc, w.calls()[-3:], p.stderr.read()[-300:]))
    check("prime", "...and nothing of its restic is left", subprocess.run(["pgrep", "-f", w.restic], capture_output=True).returncode != 0)
    check("prime", "...and the repository is marked: packs not yet indexed", tool.read_state(w.ctx).get("unindexed") is True, tool.read_state(w.ctx))
    w.clear_calls()
    tool.ready_repo(w.ctx)
    check("prime", "the next backup indexes them first (repair index), once", w.calls() == ["unlock", "repair index"] and tool.read_state(w.ctx).get("unindexed") is False, w.calls())
    w.clear_calls()
    tool.ready_repo(w.ctx)
    check("prime", "...and not again", w.calls() == ["unlock"], w.calls())


def g_locks():
    import fcntl
    w = World("locks_world", minFreeGB=1)
    w.fake_proc([(100, "bash", 1), (202, "pacman", 100)])
    w.pkgs({"a": "1-1"})
    settings, _ = w.ctx.settings()
    check("locks", "the job lock is a file only root opens (0600)", os.stat(w.ctx.oplock).st_mode & 0o777 == 0o600, oct(os.stat(w.ctx.oplock).st_mode))

    def create(note=""):
        ln = tool.Lines(io.StringIO())
        try:
            return tool.create_snapshot(w.ctx, settings, ln, "manual", note, [], None), ln
        except tool.Busy as e:
            return e, ln

    # locks that anyone who can open the files can hold
    fds = [os.open(w.ctx.lock, os.O_RDONLY), os.open(w.ctx.state, os.O_RDONLY | os.O_DIRECTORY)]
    for fd in fds:
        fcntl.flock(fd, fcntl.LOCK_EX)
    rec, ln = create()
    check("locks", "something holding LOCK_EX on `lock` and on the state directory does not stop a create", isinstance(rec, dict) and rec.get("short"), rec)
    for fd in fds:
        os.close(fd)
    # an upload holds `lock` shared: a delete is refused, a tidy skips its prune but still primes
    up = os.open(w.ctx.lock, os.O_RDONLY)
    fcntl.flock(up, fcntl.LOCK_SH)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = tool.cmd_delete(w.ctx, Ns(short=rec["short"]))
    check("locks", "delete is refused while an upload holds `lock`", rc == 4 and tool.find_record(w.ctx, rec["short"]) and "upload" in out.getvalue(), (rc, out.getvalue()))
    w.clear_calls()
    w.add_record(short="dddddddd", id="d" * 64, time=1, state="done", reason="update")
    with contextlib.redirect_stdout(io.StringIO()):
        tool.cmd_tidy(w.ctx, None)
    calls = w.calls()
    check("locks", "a tidy that cannot take `lock` skips its prune, says so in the log, and its prime still runs",
          any(c.startswith("backup") and "lares-prime" in c for c in calls) and not any(c.startswith("forget") for c in calls) and "no prune this time" in open(w.ctx.log).read(), calls)
    os.close(up)
    # a create waits for a delete or another create
    def holder(seconds):
        p = subprocess.Popen([sys.executable, "-c", HOLDER, w.ctx.state, "0", "delete", str(seconds)], stdout=subprocess.PIPE, text=True)
        p.stdout.readline()
        return p

    h = holder(1.5)
    t0 = time.time()
    rec, ln = create()
    waited = time.time() - t0
    said = [l for l in ln.out.getvalue().splitlines() if "waiting" in l]
    check("locks", "a create waits for a delete in progress, with one notice, and then goes on", isinstance(rec, dict) and 1 < waited < 10 and len(said) == 1, (waited, said, rec))
    h.wait()
    old = tool.WAIT_OTHER
    tool.WAIT_OTHER = 1
    h = holder(8)
    t0 = time.time()
    rec, ln = create()
    check("locks", "...and gives up after the wait: busy (failed lock in the hook)", isinstance(rec, tool.Busy) and 1 <= time.time() - t0 < 5, (rec, time.time() - t0))
    h.kill()
    h.wait()
    tool.WAIT_OTHER = old


GROUPS = {"rule": g_rule, "config": g_config, "run": g_run, "record": g_record, "guards": g_guards, "lines": g_lines, "undo": g_undo,
          "retention": g_retention, "locks": g_locks, "prime": g_prime}
# an arm runs its own group alone (a sweep of 48 whole runs would be half an hour); ONLY=<group> does the same without a fault
only = ARMS[os.environ["ARM"]][0] if os.environ.get("ARM") else os.environ.get("ONLY")
try:
    for group, run_group in GROUPS.items():
        if not only or group == only:
            run_group()
except Exception as e:  # a throwing group is a failed check, never a run without a verdict
    import traceback
    traceback.print_exc()
    check("driver", "threw", False, repr(e))
finally:
    shutil.rmtree(WORK, ignore_errors=True)

print("SNC " + ", ".join("%s %d" % kv for kv in counts.items()))
print("SNAPSHOT_CASES RESULT %s%s" % ("FAIL" if fails else "PASS", " (%d: %s)" % (len(fails), "; ".join(fails[:5])) if fails else ""))
sys.exit(1 if fails else 0)
