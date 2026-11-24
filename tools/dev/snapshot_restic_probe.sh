#!/usr/bin/env bash
# The snapshot tool against a REAL restic, as a plain user, on a small fake tree (tools/snapshot/root/, docs/contracts/snapshots.md).
#
#   tools/dev/snapshot_restic_probe.sh                 last line: SNAPSHOT_RESTIC RESULT PASS|FAIL|SKIP (exit status follows; SKIP exits 0)
#   ARM=<name> tools/dev/snapshot_restic_probe.sh      one fault in a COPY of the tool; the run must end FAIL on the arm's own check
#   ARM=all tools/dev/snapshot_restic_probe.sh         every ARM; SNAPSHOT_RESTIC ARMS PASS when each failed as it must
#
# restic: $SNAPSHOT_RESTIC, else ~/.cache/claude-orch/snapshots/bin/restic, else /usr/bin/restic; none = RESULT SKIP.
# The tool runs with `--root <fake>` (every fixed path under it) and a restic wrapper that records the environment restic was given.
# Nothing here is root, touches /.lares-snapshots, /etc or the user's pacman, or starts a quickshell.
#
# What it checks (SRP <name> PASS|FAIL lines):
#   create        a snapshot is made, its record and the index line exist, the record holds the excludes and paths it was made with
#   excludes      the default excludes and the user's are not in the snapshot (restic ls), the ones that stay are
#   parent        a second snapshot finds the first as its parent and adds almost nothing
#   env           restic sees exactly PATH, HOME, LC_ALL and RESTIC_PASSWORD_FILE whatever the caller's environment holds
#   modes         the repository is group-readable, setgid, has no bit for the world; restic's new files take the config file's mode (0440)
#   status        the repository's size comes from state.json and equals the walk; locks held by the user do not stop a create
#   keep          keep on marks the snapshot (not a restic tag: that would change its id), delete of a kept snapshot is refused (4), after keep off it goes
#   tidy          the newest `keep` and the kept ones stay, the others are forgotten and their records go
#   reindex       with the records and the index deleted, reindex gives them back (keep from the mark in state.json)
#   lock          a restic killed in the middle leaves a lock; the next create clears it
#   space         too little free space: failed space, no snapshot
#   added         a snapshot that grows too much is stopped: failed added naming the largest new file, no snapshot, no lock left
#   prime         tidy writes a prime (tag lares-prime: no record, not in list or index), keeps the newest, drops it once a real snapshot is newer,
#                 does nothing with "prime": false; an update interrupts a running prime (preempt) and reuses what it wrote (reuse)
#   hook          `hook pre` prints only contract lines (at most 25), `hook done` fills `changed`
# ARMs (the check that must fail):
#   noexclude (excludes)   the excludes are not passed to restic      nounlock (lock)    a stale lock is not cleared
#   leakenv (env)          the caller's environment is passed on      worldread (modes)  the repository is world-readable
#   keepdelete (keep)      a kept snapshot can be deleted             nospace (space)    the free-space guard is off
#   noadded (added)        the added guard is off                     noindex (reindex)  reindex does not rebuild the index
#   norepair (prime.reuse) packs of a killed backup are not indexed   nopreempt (prime.preempt)  an update waits for the prime
#   noconfigmode (modes.restic.derives)  the config file is left 0400   createlock (create.ignores.user.locks)  a create takes `lock`
#   primetag (prime)       the prime is tagged like a real snapshot
set -u
cd "$(dirname "$0")/../.." || exit 1
NAME=SNAPSHOT_RESTIC
SRC=$PWD

if [ "${ARM:-}" = all ]; then
    bad=0
    for a in "noexclude excludes" "nounlock lock" "leakenv env" "worldread modes" "keepdelete keep" "nospace space" "noadded added" "noindex reindex" "noconfigmode modes.restic.derives" "createlock create.ignores.user.locks" "norepair prime.reuse" "nopreempt prime.preempt" "primetag prime"; do
        arm=${a% *}; chk=${a#* }
        res=$(ARM=$arm bash "$0" 2>&1)
        if printf '%s\n' "$res" | tail -1 | grep -q 'RESULT PASS'; then echo "  ARM $arm: PASSED (it must fail)"; bad=1
        elif ! printf '%s\n' "$res" | grep -qE "^SRP $chk([. ][^ ]*)? FAIL"; then echo "  ARM $arm: failed, but not on its own check ($chk)"; bad=1
        else echo "  ARM $arm: failed as it must ($chk)"; fi
    done
    [ "$bad" = 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
    echo "$NAME ARMS FAIL"; exit 1
fi
ARM=${ARM:-}

RESTIC_BIN=${SNAPSHOT_RESTIC:-}
[ -n "$RESTIC_BIN" ] || RESTIC_BIN=$HOME/.cache/claude-orch/snapshots/bin/restic
[ -x "$RESTIC_BIN" ] || RESTIC_BIN=/usr/bin/restic
[ -x "$RESTIC_BIN" ] || { echo "no restic here"; echo "$NAME RESULT SKIP (no restic)"; exit 0; }

SB=${SANDBOX:-/tmp/lares-sbx-snap-a}
mkdir -p "$SB" || exit 1
W=$(mktemp -d "$SB/srp.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT

# a COPY of the tool (the arms patch the copy, never the tree); the repo's layout keeps ../../lib/jsonc.py where the tool looks
mkdir -p "$W/tools"; cp -a tools/snapshot tools/lib "$W/tools/"; find "$W/tools" -name __pycache__ -prune -exec rm -rf {} +
TOOL=$W/tools/snapshot/root/lares-snapshot-root
patch_tool() {   # patch_tool <anchor> <replacement>
    ARMFILE=$TOOL ANCHOR=$1 REPL=$2 python3 -B - <<'PY' || { echo "ARM $ARM: anchor missing"; echo "$NAME RESULT FAIL (arm)"; exit 2; }
import os, sys
p = os.environ["ARMFILE"]; s = open(p).read(); a = os.environ["ANCHOR"]
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, os.environ["REPL"]))
PY
}
case $ARM in
    '') ;;
    noexclude) patch_tool '    for e in excludes:
        args += ["--exclude", e]' '    for e in []:
        args += ["--exclude", e]' ;;
    nounlock) patch_tool '    restic_call(ctx, ["unlock"], timeout=60)
    if read_state(ctx).get("unindexed"):' '    if read_state(ctx).get("unindexed"):' ;;
    leakenv) patch_tool '        return {"PATH": "/usr/bin:/bin", "HOME": self.state, "LC_ALL": "C", "RESTIC_PASSWORD_FILE": self.key}' '        return dict(os.environ, PATH="/usr/bin:/bin", HOME=self.state, LC_ALL="C", RESTIC_PASSWORD_FILE=self.key)' ;;
    worldread) patch_tool '[(".", 0o2750)] + [(f, 0o440) for f in filenames] + [(d, 0o2750) for d in dirnames]' '[(".", 0o755)] + [(f, 0o444) for f in filenames] + [(d, 0o755) for d in dirnames]' ;;
    keepdelete) patch_tool '    if rec["keep"]:
        print(json.dumps({"ok": False, "error": "this snapshot is kept; turn keep off first"}))
        return 4' '    pass' ;;
    nospace) patch_tool '        if free_now - need < settings["minFreeGB"] * ctx.unit:
            raise Failure' '        if False:
            raise Failure'
             patch_tool '            if free_now - need < settings["minFreeGB"] * ctx.unit:
                return Failure' '            if False:
                return Failure' ;;
    noadded) patch_tool 'if not first and added > settings["maxAddedGB"] * ctx.unit:' 'if False:' ;;
    noconfigmode) patch_tool '[(f, 0o440) for f in filenames]' '[(f, 0o440 if f != "config" else 0o400) for f in filenames]' ;;
    createlock) patch_tool '    with operation(ctx, "create", preempt=True,' '    with repo_lock(ctx), operation(ctx, "create", preempt=True,' ;;
    norepair) patch_tool '    if read_state(ctx).get("unindexed"):' '    if False:' ;;
    nopreempt) patch_tool 'if not (preempt and (preempt_tidy(ctx, fd) or wait_for_lock(fd, WAIT_OTHER, on_wait))):' 'if not (preempt and wait_for_lock(fd, 2, on_wait)):' ;;
    primetag) patch_tool 'backup_args(ctx, settings, PRIME_TAG)' 'backup_args(ctx, settings, "lares", PRIME_TAG)' ;;
    noindex) patch_tool '            write_index(ctx)
            fix_modes(ctx)
    except Busy as e:' '            fix_modes(ctx)
    except Busy as e:' ;;
    *) echo "unknown ARM $ARM"; exit 2 ;;
esac

OUT=$W/out.txt
ROOT_DIR=$W/root RESTIC_BIN=$RESTIC_BIN TOOL=$TOOL W=$W python3 -B - > "$OUT" 2>&1 <<'PY'
import json, os, pwd, shutil, signal, stat, subprocess, sys, time

W, ROOT, TOOL, RESTIC = os.environ["W"], os.environ["ROOT_DIR"], os.environ["TOOL"], os.environ["RESTIC_BIN"]
fails = []

def check(name, ok, detail=""):
    print("SRP %s %s%s" % (name, "PASS" if ok else "FAIL", "" if ok else "  " + str(detail)[:900]))
    if not ok:
        fails.append(name)

# ---- the fake machine ------------------------------------------------------------------------------------------------------
def put(path, data=b"x", mode=None):
    p = ROOT + path
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as f:
        f.write(data)

user = pwd.getpwuid(os.getuid())
CONFIG = ROOT + user.pw_dir + "/.config/quickshell/config/snapshots.jsonc"
put("/usr/bin/tool", os.urandom(300000))
put("/usr/share/doc", b"doc" * 1000)
put("/etc/hostname", b"fake\n")
put("/etc/secret.conf", b"s" * 500)
put("/opt/app/bin", b"o" * 1000)
put("/var/lib/important/db", b"db" * 1000)
put("/var/lib/ollama/model.bin", os.urandom(400000))          # a default exclude
put("/var/lib/pacman/sync/core.db", os.urandom(50000))        # a default exclude
put("/root/.cache/junk", b"j" * 5000)                         # a default exclude
put("/var/lib/mine/cache", os.urandom(300000))                # the user's exclude, set below
put("/boot/vmlinuz-linux", os.urandom(20000))
put("/boot/lares/rescue.img", b"never")                       # a directory of /boot: never covered
os.makedirs(ROOT + "/home/x", exist_ok=True)
put("/home/x/never", b"home is no part of a snapshot")
for name, ver in (("linux", "6.1-1"), ("mesa", "24.0-1"), ("htop", "3.3-1"), ("gone", "1.0-1")):
    put("/var/lib/pacman/local/%s-%s/desc" % (name, ver), b"")
os.makedirs(os.path.dirname(CONFIG), exist_ok=True)

def config(**kw):
    base = {"minFreeGB": 1, "exclude": ["/var/lib/mine"]}
    base.update(kw)
    with open(CONFIG, "w") as f:
        f.write("// the probe's own config\n" + json.dumps(base))

# a restic wrapper that records the environment it was started with (and can hold a backup, to be killed)
WRAP = W + "/restic-wrap"
with open(WRAP, "w") as f:
    f.write('#!/bin/sh\nenv | sort > "%s/restic.env"\n[ -e "%s/hold" ] && [ "$1" = -r ] && [ "$3" = backup ] && '
            '{ "%s" "$@" > /dev/null 2>&1 & p=$!; echo $p > "%s/restic.pid"; sleep 30; kill $p 2>/dev/null; exit 9; }\n'
            '[ -e "%s/slow" ] && [ "$3" = backup ] && { for a in "$@"; do set -- "$@" "$([ "$prev" = --pack-size ] && echo 4 || printf %%s "$a")"; prev=$a; shift; done; }\n'
            '[ -e "%s/slow" ] && [ "$3" = backup ] && exec "%s" --limit-upload "$(cat "%s/slow")" "$@"\n'
            'exec "%s" "$@"\n' % (W, W, RESTIC, W, W, W, RESTIC, W, RESTIC))
os.chmod(WRAP, 0o755)

BASE_ENV = dict(os.environ, LARES_SNAPSHOT_TEST_UNIT="1000000")      # one "GB" is a megabyte
def T(*args, stdin="", env=None, check_rc=None):
    e = dict(BASE_ENV); e.update(env or {})
    r = subprocess.run([sys.executable, "-B", TOOL, "--root", ROOT, "--restic", WRAP] + list(args), input=stdin,
                       capture_output=True, text=True, env=e, timeout=300)
    return r

def records():
    d = ROOT + "/.lares-snapshots/records"
    return sorted([json.load(open(d + "/" + n)) for n in os.listdir(d) if n.endswith(".json")], key=lambda r: -r["time"])

def rescic(*args):
    return subprocess.run([RESTIC, "-r", ROOT + "/.lares-snapshots/repo", "--no-cache"] + list(args), capture_output=True, text=True,
                          env={"PATH": "/usr/bin:/bin", "RESTIC_PASSWORD_FILE": ROOT + "/.lares-snapshots/key"})

def lock_files():
    d = ROOT + "/.lares-snapshots/repo/locks"
    return os.listdir(d) if os.path.isdir(d) else []

config()
r = T("init")
check("init", r.returncode == 0 and os.path.isfile(ROOT + "/.lares-snapshots/repo/config"), r.stderr + r.stdout)

# ---- create, excludes, record --------------------------------------------------------------------------------------------
r = T("create", "--note", "first", env={"CALLER_SECRET": "x", "RESTIC_REPOSITORY": "/nowhere", "RESTIC_PASSWORD": "wrong", "AWS_SECRET_ACCESS_KEY": "k"})
lines = [l for l in r.stdout.splitlines() if l]
last = json.loads(lines[-1]) if lines else {}
check("create", r.returncode == 0 and last.get("ok") is True and len(records()) == 1, r.stdout + r.stderr)
rec = records()[0] if records() else {}
check("create.record", rec.get("reason") == "manual" and rec.get("state") == "done" and len(rec.get("id", "")) == 64
      and rec.get("short") == rec.get("id", "")[:8] and rec.get("note") == "first" and rec.get("bytes", 0) > 300000, rec)
idx = open(ROOT + "/.lares-snapshots/index.tsv").read().splitlines()
check("create.index", len(idx) == 1 and idx[0].split("\t")[0] == rec.get("id") and idx[0].split("\t")[2:] == ["manual", "Manual"], idx)
envd = dict(l.split("=", 1) for l in open(W + "/restic.env").read().splitlines() if "=" in l)
want_env = {"PATH", "HOME", "LC_ALL", "RESTIC_PASSWORD_FILE", "PWD", "SHLVL", "_", "OLDPWD"}
check("env", set(envd) <= want_env and envd.get("RESTIC_PASSWORD_FILE", "").endswith("/.lares-snapshots/key") and "RESTIC_REPOSITORY" not in envd, sorted(envd))
ls = rescic("ls", rec["id"]).stdout if rec else ""
check("excludes", ROOT + "/etc/hostname" in ls and ROOT + "/var/lib/important/db" in ls and ROOT + "/boot/vmlinuz-linux" in ls
      and "ollama" not in ls and "core.db" not in ls and "/root/.cache" not in ls and "/var/lib/mine" not in ls
      and "rescue.img" not in ls and "/home/x" not in ls, ls[:400])
check("create.record.made.with", ROOT + "/var/lib/ollama" in rec.get("excludes", []) and ROOT + "/var/lib/mine" in rec.get("excludes", [])
      and ROOT + "/usr" in rec.get("paths", []) and ROOT + "/boot/vmlinuz-linux" in rec.get("paths", []), rec.get("paths"))

# ---- modes -----------------------------------------------------------------------------------------------------------------
bad = []
for dp, dn, fn in os.walk(ROOT + "/.lares-snapshots/repo"):
    for n in dn + fn + ["."]:
        p = dp if n == "." else os.path.join(dp, n)
        m = stat.S_IMODE(os.lstat(p).st_mode)
        isdir = os.path.isdir(p)
        if m & 0o007 or not m & 0o040 or (isdir and not m & 0o2000):
            bad.append((p, oct(m)))
check("modes", not bad, bad[:3])
kst = os.stat(ROOT + "/.lares-snapshots/key")
check("modes.key", stat.S_IMODE(kst.st_mode) == 0o600, oct(kst.st_mode))
check("modes.oplock", stat.S_IMODE(os.stat(ROOT + "/.lares-snapshots/oplock").st_mode) == 0o600, oct(os.stat(ROOT + "/.lares-snapshots/oplock").st_mode))

# ---- the second snapshot finds its parent ----------------------------------------------------------------------------------
time.sleep(1.1)
r = T("create")
snaps = json.loads(rescic("snapshots", "--json", "--tag", "lares").stdout or "[]")
snaps.sort(key=lambda s: s["time"])
check("parent", r.returncode == 0 and len(snaps) == 2 and snaps[1].get("parent") == snaps[0]["id"]
      and records()[0]["added"] < 20000, (r.stdout[-200:], [s.get("parent") for s in snaps], records()[0]["added"] if records() else None))

# ---- the size is kept, not walked; locks anyone can hold do not stop a create ----------------------------------------------------
import fcntl
walked = sum(os.lstat(os.path.join(dp, n)).st_size for dp, _, fn in os.walk(ROOT + "/.lares-snapshots/repo") for n in fn)
status = json.loads(T("status").stdout)
check("status.repobytes", status["repoBytes"] == walked > 0 and json.load(open(ROOT + "/.lares-snapshots/state.json"))["repoBytes"] == walked, (status["repoBytes"], walked))
held = [os.open(ROOT + "/.lares-snapshots/lock", os.O_RDONLY), os.open(ROOT + "/.lares-snapshots", os.O_RDONLY | os.O_DIRECTORY)]
for fd in held:
    fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(1.1)
r = T("create")
for fd in held:
    os.close(fd)
check("create.ignores.user.locks", r.returncode == 0 and '"ok": true' in r.stdout, (r.returncode, r.stdout[-200:]))

# ---- keep, delete, tidy ---------------------------------------------------------------------------------------------------
first = records()[-1]["short"]; second = records()[0]["short"]
r = T("keep", first, "on")
marks = json.load(open(ROOT + "/.lares-snapshots/state.json")).get("keeps", [])
check("keep", r.returncode == 0 and [x for x in records() if x["short"] == first][0]["keep"] and any(m.startswith(first) for m in marks)
      and any(s["id"].startswith(first) for s in json.loads(rescic("snapshots", "--json", "--tag", "lares").stdout)), (r.stdout, marks))
r = T("delete", first)
check("keep.delete.refused", r.returncode == 4 and any(x["short"] == first for x in records()), (r.returncode, r.stdout))
for _ in range(3):
    time.sleep(1.1)
    T("create")
config(keep=2)
r = T("tidy")
left = {x["short"] for x in records()}
in_restic = {s["id"][:8] for s in json.loads(rescic("snapshots", "--json", "--tag", "lares").stdout)}
check("tidy", r.returncode == 0 and len(left) == 3 and first in left and left == in_restic, (r.returncode, len(left), sorted(left), sorted(in_restic)))
check("tidy.index", len(open(ROOT + "/.lares-snapshots/index.tsv").read().splitlines()) == 3)
check("tidy.check", (json.load(open(ROOT + "/.lares-snapshots/state.json")).get("check") or {}).get("ok") is True)
r = T("keep", first, "off")
r = T("delete", first)
check("keep.delete", r.returncode == 0 and not any(x["short"] == first for x in records())
      and not any(s["id"].startswith(first) for s in json.loads(rescic("snapshots", "--json", "--tag", "lares").stdout)), (r.returncode, r.stdout))

# ---- reindex ---------------------------------------------------------------------------------------------------------------
keep_one = records()[0]["short"]
T("keep", keep_one, "on")
before = {x["short"]: x for x in records()}
for n in os.listdir(ROOT + "/.lares-snapshots/records"):
    os.unlink(ROOT + "/.lares-snapshots/records/" + n)
os.unlink(ROOT + "/.lares-snapshots/index.tsv")
r = T("reindex")
after = {x["short"]: x for x in records()}
check("reindex", r.returncode == 0 and set(after) == set(before) and after[keep_one]["keep"]
      and all(after[k]["reason"] == "manual" and after[k]["id"] == before[k]["id"] and after[k]["time"] == before[k]["time"]
              and ROOT + "/usr" in after[k]["paths"] and after[k]["excludes"] == before[k]["excludes"] for k in before), (r.returncode, r.stderr[-200:]))
check("reindex.index", os.path.exists(ROOT + "/.lares-snapshots/index.tsv") and len(open(ROOT + "/.lares-snapshots/index.tsv").read().splitlines()) == len(before),
      "index.tsv not rebuilt")
T("keep", keep_one, "off")

# ---- a killed restic ---------------------------------------------------------------------------------------------------------
put("/var/lib/important/more", os.urandom(200000))
open(W + "/hold", "w").close()
hold = subprocess.Popen([sys.executable, "-B", TOOL, "--root", ROOT, "--restic", WRAP, "create"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        env=BASE_ENV, text=True)
for _ in range(100):
    if os.path.exists(W + "/restic.pid") and lock_files():
        break
    time.sleep(0.1)
if not os.path.exists(W + "/restic.pid"):
    hold.kill(); check("lock", False, "the held backup never started: %s" % (hold.communicate(),)); print("SNAPSHOT_RESTIC RESULT FAIL"); sys.exit(1)
os.kill(int(open(W + "/restic.pid").read()), signal.SIGKILL)
hold.kill(); hold.wait(); os.unlink(W + "/restic.pid"); os.unlink(W + "/hold")
left_locks = lock_files()
time.sleep(0.3)
r = T("create")
check("lock", left_locks and r.returncode == 0 and lock_files() == [], (left_locks, r.returncode, lock_files()))

# ---- guards -------------------------------------------------------------------------------------------------------------------
n_before = len(records())
config(minFreeGB=500)
r = T("create", env={"LARES_SNAPSHOT_TEST_UNIT": "10000000000"})     # 500 "GB" of 10 GB each: more than any disk has
check("space", r.returncode == 1 and "failed space" in r.stdout and len(records()) == n_before, (r.returncode, r.stdout, len(records())))
config(maxAddedGB=1)
put("/var/lib/important/huge.bin", os.urandom(3000000))
for i in range(30):
    put("/var/lib/important/f%d" % i, os.urandom(60000))
open(W + "/slow", "w").write("1000")                                    # KiB a second
r = T("create", env={"LARES_SNAPSHOT_TEST_UNIT": "1000"})
os.unlink(W + "/slow")   # one "GB" is a kilobyte, restic is held to 1 MB/s
check("added", r.returncode == 1 and "failed added" in r.stdout and "largest new files: " + ROOT + "/var/lib/important/" in r.stdout and len(records()) == n_before
      and lock_files() == [], (r.returncode, r.stdout[-300:], lock_files()))
config()
os.unlink(ROOT + "/var/lib/important/huge.bin")

# ---- the hook ------------------------------------------------------------------------------------------------------------------
names = "\n".join(["linux", "mesa", "htop"] + ["pkg%d" % i for i in range(50)]) + "\n"
r = T("hook", "pre", stdin=names)
out = r.stdout.splitlines()
shown = [l for l in out if l.startswith("lares-snapshot: ")]
check("hook.lines", r.returncode == 0 and len(out) == len(shown) <= 25 and shown[0].startswith("lares-snapshot: start 53 packages: linux, mesa")
      and shown[-1].startswith("lares-snapshot: done "), out)
put("/var/lib/pacman/local/linux-6.2-1/desc", b"")
shutil.rmtree(ROOT + "/var/lib/pacman/local/linux-6.1-1")
shutil.rmtree(ROOT + "/var/lib/pacman/local/gone-1.0-1")
put("/var/lib/pacman/local/newpkg-1.0-1/desc", b"")
r = T("hook", "done", stdin=names)
rec = records()[0]
ch = {c["name"]: (c["from"], c["to"]) for c in (rec.get("changed") or [])}
check("hook.done", r.returncode == 0 and r.stdout == "" and rec["state"] == "done"
      and ch == {"linux": ("6.1-1", "6.2-1"), "gone": ("1.0-1", None), "newpkg": (None, "1.0-1")}, (r.stdout, ch, rec["state"]))
r = T("hook", "pre", stdin="htop\n")
check("hook.small", r.stdout.strip().startswith("lares-snapshot: skip small") and r.returncode == 0, r.stdout)


# ---- the prime -----------------------------------------------------------------------------------------------------------------
def tags_of(tag):
    return json.loads(rescic("snapshots", "--json", "--tag", tag).stdout or "[]")

n_real = len(records())
time.sleep(1.1)
put("/var/lib/important/after-update", os.urandom(200000))
r = T("tidy")
p1 = tags_of("lares-prime")
lst = json.loads(T("list").stdout)["records"]
check("prime", r.returncode == 0 and len(p1) == 1 and len(records()) == n_real and len(lst) == n_real
      and p1[0]["id"] not in open(ROOT + "/.lares-snapshots/index.tsv").read() and "lares" not in p1[0]["tags"],
      (r.returncode, len(p1), [x["tags"] for x in p1], len(records()), n_real))
time.sleep(1.1)
put("/var/lib/important/after-update2", os.urandom(100000))
T("tidy")
p2 = tags_of("lares-prime")
check("prime.newest.only", len(p2) == 1 and p2[0]["id"] != p1[0]["id"], [x["id"][:8] for x in p2])
time.sleep(1.1)
T("create")
T("tidy")
p3 = tags_of("lares-prime")
newest_real = json.loads(rescic("snapshots", "--json", "--tag", "lares").stdout)[-1]["time"]
check("prime.gone.after.real", len(p3) == 1 and p3[0]["id"] != p2[0]["id"] and p3[0]["time"] > newest_real, [x["id"][:8] for x in p3])
config(prime=False)
before_primes = [x["id"] for x in tags_of("lares-prime")]
put("/var/lib/important/after-update3", os.urandom(50000))
T("tidy")
check("prime.off", [x["id"] for x in tags_of("lares-prime")] == before_primes, before_primes)
config()

# a prime that an update interrupts: the update goes first, and keeps what the prime had written
config(maxAddedGB=100)
put("/var/lib/important/big.bin", os.urandom(24000000))
open(W + "/slow", "w").write("4000")
tidy = subprocess.Popen([sys.executable, "-B", TOOL, "--root", ROOT, "--restic", WRAP, "tidy"], env=BASE_ENV, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, text=True)
def repo_data():
    t = 0
    for dp, _, fn in os.walk(ROOT + "/.lares-snapshots/repo/data"):
        t += sum(os.lstat(os.path.join(dp, n)).st_size for n in fn)
    return t
base = repo_data()
for _ in range(150):
    if repo_data() - base > 4000000:
        break
    time.sleep(0.1)
written = repo_data() - base
os.unlink(W + "/slow")
n_real = len(records())
t0 = time.time()
r = T("create")
took = time.time() - t0
tidy_rc = tidy.wait(timeout=60)
rec = records()[0]
check("prime.preempt", written > 3000000 and r.returncode == 0 and len(records()) == n_real + 1 and tidy_rc == 3 and lock_files() == [],
      (written, r.returncode, r.stdout[-200:], tidy_rc, lock_files()))
check("prime.reuse", rec["added"] < 24000000 - 0.5 * written, (rec["added"], written))

# restic gives the files it makes the mode of the repository's config file, so they are group-readable at once (no waiting for the tool)
def repo_files():
    return {os.path.join(dp, n) for dp, _, fn in os.walk(ROOT + "/.lares-snapshots/repo") for n in fn}
seen = repo_files()
os.makedirs(W + "/tiny", exist_ok=True)
open(W + "/tiny/f", "w").write("tiny")
rescic("backup", "--no-cache", "-q", W + "/tiny")
fresh = repo_files() - seen
check("modes.restic.derives", fresh and all(stat.S_IMODE(os.lstat(p).st_mode) == 0o440 for p in fresh), [(os.path.basename(p)[:6], oct(os.lstat(p).st_mode)) for p in fresh])

print("SNAPSHOT_RESTIC RESULT %s%s" % ("FAIL" if fails else "PASS", " (%s)" % ", ".join(fails[:6]) if fails else ""))
sys.exit(1 if fails else 0)
PY
rc=$?
cat "$OUT" | grep -E '^SRP .* FAIL' | head -20
if ! grep -q "^$NAME RESULT" "$OUT"; then
    tail -15 "$OUT"; echo "$NAME RESULT FAIL (no result: $OUT)"; cp "$OUT" "$SB/srp-last.txt" 2> /dev/null; exit 1
fi
grep -E "^(SRP .* PASS|$NAME RESULT)" "$OUT" | tail -n 40
exit "$rc"
