#!/usr/bin/env python3
"""Offline cases of tools/snapshot/lares-offsite against a stub `proton-drive` (tools/dev/fixtures/proton_stub): no network, no account, no
root, nothing of the user's read or written. The CLI facts the tool guesses (JSON shape, where a trashed item lands, error wording) are the
stub's guesses too: this proves the tool's logic, never the real CLI (tools/dev/proton_cli_try.sh records that).

    python3 tools/dev/snapshot_offsite_cases.py             SNAPSHOT_OFFSITE_CASES RESULT PASS | FAIL
    ARM=<name> python3 tools/dev/snapshot_offsite_cases.py  one fault in a COPY of the tool; the group named must fail
    ARM=all ...                                             every arm in turn: SNAPSHOT_OFFSITE_CASES ARMS RESULT PASS | FAIL

Groups: conditions, order, manifest, deletions, interrupted, sizes, fetch, lock, signedout, config, restic (a real repository, when
~/.cache/claude-orch/snapshots/bin/restic, or restic on PATH)

ARMs (group that must fail):
  noacwait (conditions)    battery is not a reason to wait          noorder (order)       files go in name order
  nomanifest (manifest)    the manifest is never saved              nocap (deletions)     a third of the remote may go
  noours (deletions)       any name may be trashed                  noduplicheck (deletions) /trash/<name> is deleted though two items have it
  deletefatal (deletions)  a failed delete ends the run in error    usereplace (sizes)    a file is sent with -f replace
  noemptyguard (deletions) an empty repository removes the remote   emptytrash (deletions) the trash is emptied
  noresume (interrupted)   a file already remote is sent again      nosizecheck (sizes)   a short file is believed
  nofetchverify (fetch)    a downloaded file is not checked         noshared (lock)       prune is not waited for
  signedgeneric (signedout) a signed-out CLI is a plain failure     defaulton (config)    the copy is on unless switched off
  nocause (conditions)     what it waits for is words only
"""
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
STUB = os.path.join(HERE, "fixtures", "proton_stub", "proton-drive")
RESTIC = (os.environ.get("SNAPSHOT_RESTIC") or [p for p in (os.path.expanduser("~/.cache/claude-orch/snapshots/bin/restic"),)
                                                   if os.path.exists(p)] or [shutil.which("restic") or "/usr/bin/restic"])
RESTIC = RESTIC if isinstance(RESTIC, str) else RESTIC[0]
SBX = "/tmp/lares-sbx-snap-e"
ARMS = {
    "nocause": ("conditions", "            job.say(\"waiting\", str(e), e.cause)\n", "            job.say(\"waiting\", str(e))\n"),
    "noacwait": ("conditions", "def on_ac():\n", "def on_ac():\n    return True\n"),
    "noorder": ("order", "    return TOP.index(rel.split(\"/\", 1)[0])", "    return 0"),
    "nomanifest": ("manifest", "def save_manifest(self):\n        write_json(manifest_path(), self.manifest)",
                   "def save_manifest(self):\n        pass"),
    "nocap": ("deletions", "len(removals) * 3 > known", "False"),
    "noours": ("deletions", 'return rel.split("/", 1)[0] in OURS and "/" in rel and bool(HEX64.match(rel.rsplit("/", 1)[1]))', "return True"),
    "noduplicheck": ("deletions", 'if count > 1:\n            return "ambiguous"', 'if False:\n            return "ambiguous"'),
    "deletefatal": ("deletions", 'if e.kind not in ("failed", "missing"):\n                raise\n            return', "if True:\n                raise"),
    "usereplace": ("sizes", '["fs", "upload", "-f", "skip", "-d", "skip", "-t"]', '["fs", "upload", "-f", "replace", "-d", "skip", "-t"]'),
    "noemptyguard": ("deletions", "if not snapshot_shorts(self.local):", "if False:"),
    "emptytrash": ("deletions", '        self.run(["fs", "delete", trashed_path(path)])',
                   '        self.run(["fs", "empty-trash"])'),
    "noresume": ("interrupted", "todo = [r for r in rels if listing.get(r.rsplit(\"/\", 1)[-1], {}).get(\"size\") != self.local[r]]",
                 "todo = list(rels)"),
    "nosizecheck": ("sizes", "return [r for r in rels if listing", "return [] or [r for r in rels if False and listing"),
    "nofetchverify": ("fetch", "if sha256_of(os.path.join(dirpath, name)) != name:", "if False:"),
    "noshared": ("lock", "fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)\n            return fd", "return fd"),
    "signedgeneric": ("signedout", "    if re.search(r\"need to log ?in", "    if False and re.search(r\"need to log ?in"),
    "noplace": ("places", 'return "%s/%s/%s" % (cfg["folder"], machine_name(cfg), rid) if rid else ""', 'return "%s/%s" % (cfg["folder"], machine_name(cfg)) if rid else ""'),
    "noidentity": ("places", "        here = self.cli.list(self.base).get(\"config\") if self.base_exists() else None", "        here = None"),
    "listopen": ("places", '            if e.kind == "missing":\n                return False\n            raise', "            return False"),
    "anymachine": ("places", "machine if MACHINE.match(machine) else \"\"", "machine"),
    "nokeyring": ("conditions", "    if keyring_locked():", "    if False:"),
    "encsize": ("order", '        size = rev.get("claimedSize")', '        size = e.get("totalStorageSize")'),
    "defaulton": ("config", '"enabled": block.get("enabled") is True', '"enabled": block.get("enabled") is not False'),
}

results = []   # (group, name, ok, detail)


def check(group, name, ok, detail=""):
    results.append((group, name, bool(ok), detail))
    if not ok:
        print("FAIL %s: %s %s" % (group, name, detail))


def hexname(data):
    return hashlib.sha256(data).hexdigest()


class World:
    """One test: a synthetic repository, a stub remote, a state dir, a config, a power supply, all private."""

    def __init__(self, tool, enabled=True, config_bytes=b"config-bytes", hostname="testhost", remote=None, **offsite):
        self.dir = tempfile.mkdtemp(dir=SBX)
        self.config_bytes, self.machine = config_bytes, offsite.get("machine") or hostname
        self.tool = tool
        d = self.dir
        self.snap = os.path.join(d, "snap")
        self.repo = os.path.join(self.snap, "repo")
        self.remote = remote or os.path.join(d, "remote")      # two worlds may share one Proton Drive
        self.state = os.path.join(d, "state")
        self.stubroot = self.remote
        os.makedirs(self.repo)
        open(os.path.join(self.snap, "lock"), "w").close()
        self.power = os.path.join(d, "power")
        os.makedirs(os.path.join(self.power, "AC"))
        self.setpower(True)
        block = dict(enabled=enabled, folder="/my-files/T", **offsite)
        self.config = os.path.join(d, "snapshots.jsonc")
        with open(self.config, "w") as f:
            f.write("// test\n{ \"offsite\": %s }\n" % json.dumps(block))
        self.bin = os.path.join(d, "bin")
        os.makedirs(self.bin)
        os.symlink(STUB, os.path.join(self.bin, "proton-drive"))
        # busctl: the keyring's state and the line's, never the machine's own
        with open(os.path.join(self.bin, "busctl"), "w") as f:
            f.write('#!/bin/sh\ncase "$*" in *org.freedesktop.secrets*) [ "${STUB_LOCKED:-}" = none ] && exit 1; echo "b ${STUB_LOCKED:-false}" ;; '
                    '*) echo "u ${STUB_METERED:-2}" ;; esac\n')
        os.chmod(os.path.join(self.bin, "busctl"), 0o755)
        self.xdg = os.path.join(d, "xdgstate")
        self.env = dict(os.environ, LARES_SNAPSHOT_DIR=self.snap, LARES_OFFSITE_STATE=self.state, LARES_OFFSITE_CONFIG=self.config,
                        LARES_PROTON_DRIVE=STUB, PROTON_STUB_ROOT=self.remote, LARES_POWER_SUPPLY_DIR=self.power,
                        LARES_OFFSITE_HOST=hostname, XDG_STATE_HOME=self.xdg, LARES_OFFSITE_LOCK_WAIT="1",
                        PATH=self.bin + ":" + os.environ["PATH"])
        for k in ("STUB_FAIL_UPLOAD_N", "STUB_PARTIAL_N", "STUB_SHORT_N", "STUB_SIGNED_OUT", "STUB_THROTTLED", "STUB_LIST_FAIL"):
            self.env.pop(k, None)

    def setpower(self, ac):
        with open(os.path.join(self.power, "AC", "type"), "w") as f:
            f.write("Mains\n")
        with open(os.path.join(self.power, "AC", "online"), "w") as f:
            f.write("1\n" if ac else "0\n")

    def put(self, rel, data):
        p = os.path.join(self.repo, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data)
        return p

    def pack(self, top, seed, size=300):
        data = (seed.encode() * size)[:size]
        h = hexname(data)
        rel = "%s/%s%s" % (top, h[:2] + "/" if top == "data" else "", h)
        self.put(rel, data)
        return rel

    def fill(self, packs=3):
        self.put("config", self.config_bytes)
        rels = ["config", self.pack("keys", "key"), self.pack("index", "index"), self.pack("snapshots", "snap1")]
        rels += [self.pack("data", "pack%d" % i, 200 + i) for i in range(packs)]
        return rels

    def run(self, *args, **env):
        e = dict(self.env)
        e.update({k: str(v) for k, v in env.items()})
        r = subprocess.run([sys.executable, self.tool] + list(args), env=e, capture_output=True, text=True, timeout=120)
        return r

    def calls(self):
        try:
            return [json.loads(l) for l in open(os.path.join(self.remote, "calls.log"))]
        except OSError:
            return []

    def uploads(self):
        return [c for c in self.calls() if c[:2] == ["fs", "upload"]]

    def st(self):
        try:
            return json.load(open(os.path.join(self.state, "offsite.json")))
        except (OSError, ValueError):
            return {}

    def base(self):
        """This world's place on the remote: the machine, then the repository's eight digits."""
        try:
            mine = open(os.path.join(self.repo, "config"), "rb").read()
        except OSError:
            mine = self.config_bytes
        return os.path.join(self.remote, "my-files", "T", self.machine, hexname(mine)[:8])

    def remote_files(self):
        base = os.path.join(self.base())
        out = {}
        for dp, _d, fs in os.walk(base):
            for n in fs:
                out[os.path.relpath(os.path.join(dp, n), base)] = os.path.getsize(os.path.join(dp, n))
        return out

    def local_files(self):
        out = {}
        for top in ("config", "keys", "data", "index", "snapshots"):
            p = os.path.join(self.repo, top)
            if os.path.isfile(p):
                out[top] = os.path.getsize(p)
            for dp, _d, fs in os.walk(p):
                for n in fs:
                    out[os.path.relpath(os.path.join(dp, n), self.repo)] = os.path.getsize(os.path.join(dp, n))
        return out

    def trash(self):
        return os.listdir(os.path.join(self.remote, "trash")) if os.path.isdir(os.path.join(self.remote, "trash")) else []

    def emptied_trash(self):
        return os.path.exists(os.path.join(self.remote, "EMPTY_TRASH_CALLED"))

    def done(self):
        shutil.rmtree(self.dir, ignore_errors=True)


def upload_order(w):
    """The top-level names of what each upload call carried, in call order."""
    out = []
    for c in w.uploads():
        local = c[c.index("-t") + 1:-1]
        out.append([os.path.relpath(p, w.repo).split("/")[0] for p in local])
    return out


# ---------------------------------------------------------------- groups

def g_conditions(tool):
    w = World(tool)
    w.fill()
    w.setpower(False)
    r = w.run("sync")
    check("conditions", "battery waits", r.returncode == 3 and w.st().get("state") == "waiting" and w.st().get("cause") == "battery"
          and "battery" in w.st().get("reason", ""), r.stderr + str(w.st()))
    check("conditions", "battery: no call to the CLI", not w.calls())
    w2 = World(tool, onBattery=True)
    w2.fill()
    w2.setpower(False)
    check("conditions", "onBattery goes on", w2.run("sync").returncode == 0)
    w2.done()
    w3 = World(tool)
    w3.fill()
    r = w3.run("sync", STUB_METERED=1)
    check("conditions", "metered waits", r.returncode == 3 and w3.st().get("cause") == "metered" and "metered" in w3.st().get("reason", "") and not w3.calls(), r.stderr)
    w4 = World(tool, metered=True)
    w4.fill()
    check("conditions", "metered allowed by config", w4.run("sync", STUB_METERED=1).returncode == 0)
    w6 = World(tool)
    w6.fill()
    for locked in ("true", "none"):
        r = w6.run("sync", STUB_LOCKED=locked)
        check("conditions", "a locked or absent keyring waits, and the CLI is not called (%s)" % locked,
              r.returncode == 3 and w6.st().get("state") == "waiting" and w6.st().get("cause") == "keyring" and "keyring" in w6.st().get("reason", "") and not w6.calls(), r.stderr + str(w6.st()))
    check("conditions", "an open keyring goes on, and the cause is gone", w6.run("sync").returncode == 0 and w6.st().get("cause") == "", str(w6.st()))
    w6.done()
    w4.done()
    w5 = World(tool)
    w5.fill()
    marker = os.path.join(w5.xdg, "lares", "system-update", "last-run.json")
    os.makedirs(os.path.dirname(marker))
    json.dump({"state": "running", "pid": os.getpid()}, open(marker, "w"))
    r = w5.run("sync")
    check("conditions", "a running update waits", r.returncode == 3 and w5.st().get("cause") == "update" and "update" in w5.st().get("reason", "") and not w5.calls(), r.stderr)
    dead = subprocess.Popen(["true"])
    dead.wait()
    json.dump({"state": "running", "pid": dead.pid}, open(marker, "w"))
    check("conditions", "a dead update pid does not hold it", w5.run("sync").returncode == 0)
    for x in (w, w3, w5):
        x.done()


def g_order(tool):
    w = World(tool)
    w.fill(packs=4)
    r = w.run("sync")
    order = [c[0] for c in upload_order(w)]
    check("order", "synced", r.returncode == 0 and w.remote_files() == w.local_files(), r.stderr)
    ranks = [["config", "keys", "data", "index", "snapshots"].index(t) for t in order]
    check("order", "config, keys, data, index, snapshots", ranks == sorted(ranks) and len(set(order)) == 5, str(order))
    check("order", "no parallel calls and one call per folder", len(order) == len(w.uploads()))
    check("order", "every upload names a strategy",
          all("-f" in c and "-d" in c for c in w.uploads()))
    snaps = w.st().get("snapshots")
    check("order", "state lists the snapshot", len(snaps or []) == 1 and w.st().get("state") == "idle" and w.st().get("lastOk"), str(w.st()))
    d = w.run("sync", "--dry", "--json")
    check("order", "dry run after sync has nothing to do", json.loads(d.stdout)["upload"] == [])
    w.done()
    w = World(tool)
    w.fill()
    before = w.calls()
    d = w.run("sync", "--dry", "--json")
    plan = json.loads(d.stdout)
    check("order", "dry run lists, calls nothing", len(plan["upload"]) == 7 and w.calls() == before and not os.path.exists(w.state))
    w.done()


def g_manifest(tool):
    w = World(tool)
    w.fill()
    w.run("sync")
    n = len(w.calls())
    r = w.run("sync")
    check("manifest", "a second run with nothing new calls nothing", r.returncode == 0 and len(w.calls()) == n, "%d -> %d" % (n, len(w.calls())))
    m = json.load(open(os.path.join(w.state, "offsite-manifest.json")))
    check("manifest", "manifest holds every file with its size", m["files"] == w.local_files())
    gone = next(r for r in w.remote_files() if r.startswith("data/"))
    os.remove(os.path.join(w.base(), gone))
    w.run("sync")
    check("manifest", "without --verify a remote loss is not noticed", gone not in w.remote_files())
    r = w.run("sync", "--verify")
    check("manifest", "--verify uploads what is gone remotely", r.returncode == 0 and w.remote_files() == w.local_files(), r.stderr)
    v = w.run("verify")
    check("manifest", "verify says all good", v.returncode == 0, v.stdout)
    os.remove(os.path.join(w.base(), gone))
    v = w.run("verify")
    check("manifest", "verify names a missing file and changes nothing", v.returncode == 1 and gone in v.stdout
          and gone not in w.remote_files())
    w.done()


def g_deletions(tool):
    w = World(tool)
    rels = w.fill(packs=5)
    w.run("sync")
    drop = [r for r in rels if r.startswith("data/")][:1]
    for r in drop:
        os.remove(os.path.join(w.repo, r))
    r = w.run("sync")
    check("deletions", "a pruned pack is removed remotely", r.returncode == 0 and w.remote_files() == w.local_files(), r.stderr)
    check("deletions", "trash then delete of that item only", w.trash() == [] and not w.emptied_trash(), str(w.trash()))
    calls = [c[1] for c in w.calls() if c[0] == "fs"]
    check("deletions", "never empty-trash", "empty-trash" not in calls)
    # a third
    w2 = World(tool)
    rels = w2.fill(packs=5)
    w2.run("sync")
    for r in [r for r in rels if r.startswith("data/")][:4]:
        os.remove(os.path.join(w2.repo, r))
    r = w2.run("sync")
    check("deletions", "more than a third is refused", r.returncode == 4 and w2.st().get("state") == "error"
          and "third" in w2.st().get("reason", "") and len(w2.remote_files()) == 9, r.stderr)
    r = w2.run("sync", "--allow-shrink")
    check("deletions", "--allow-shrink overrides", r.returncode == 0 and w2.remote_files() == w2.local_files(), r.stderr)
    # empty and missing repositories
    w3 = World(tool)
    w3.fill()
    w3.run("sync")
    os.remove(os.path.join(w3.repo, next(r for r in w3.local_files() if r.startswith("snapshots/"))))
    n = len(w3.remote_files())
    r = w3.run("sync", "--allow-shrink")
    check("deletions", "no local snapshots: nothing removed, even with --allow-shrink", r.returncode == 4 and len(w3.remote_files()) == n, r.stderr)
    shutil.rmtree(w3.repo)
    r = w3.run("sync", "--allow-shrink")
    check("deletions", "a missing repository: nothing removed", r.returncode in (3, 4) and len(w3.remote_files()) == n, r.stderr)
    for x in (w, w2, w3):
        x.done()
    g_removal_safety(tool)


def g_removal_safety(tool):
    """Only restic's own names are ever trashed or deleted; a failed delete is not an error; an ambiguous name is left in the trash."""
    w = World(tool)
    w.fill(packs=3)
    w.run("sync")
    base = os.path.join(w.base())
    os.makedirs(os.path.join(base, "data", "zz"))
    for rel in ("data/notes.txt", "data/zz/notes2.txt"):
        open(os.path.join(base, rel), "w").write("mine")
    m = json.load(open(os.path.join(w.state, "offsite-manifest.json")))
    m["files"]["data/zz/notes2.txt"] = 4        # a manifest that names a stranger as ours, and a leftover that does too
    m["trashed"] = ["data/notes.txt"]
    json.dump(m, open(os.path.join(w.state, "offsite-manifest.json"), "w"))
    r = w.run("sync", "--verify")
    check("deletions", "a stranger in data/ survives, named by the listing, the manifest and the leftovers",
          r.returncode == 0 and os.path.exists(os.path.join(base, "data", "notes.txt"))
          and os.path.exists(os.path.join(base, "data", "zz", "notes2.txt")), r.stderr)
    check("deletions", "and it is said", "not ours" in w.st().get("reason", "") and w.st().get("state") == "idle", str(w.st()))
    check("deletions", "no call named a stranger for removal", not any(c[:2] in (["fs", "trash"], ["fs", "delete"]) and "notes" in " ".join(c)
                                                                       for c in w.calls()))
    w.done()
    w = World(tool)
    rels = w.fill(packs=5)
    w.run("sync")
    packs = [r for r in rels if r.startswith("data/")]
    os.remove(os.path.join(w.repo, packs[0]))
    r = w.run("sync", STUB_DELETE_FAIL="1")
    m = json.load(open(os.path.join(w.state, "offsite-manifest.json")))
    check("deletions", "a failed delete after a good trash is not an error", r.returncode == 0 and w.st().get("state") == "idle"
          and "Proton's trash" in w.st().get("reason", "") and m["trashed"] == [packs[0]] and len(w.trash()) == 1, r.stderr + str(w.st()))
    n = len([c for c in w.calls() if c[:2] == ["fs", "delete"]])
    r = w.run("sync", STUB_DELETE_FAIL="1")
    check("deletions", "a leftover is tried once per sync", r.returncode == 0
          and len([c for c in w.calls() if c[:2] == ["fs", "delete"]]) == n + 1)
    r = w.run("sync")
    check("deletions", "and goes at the next good run", r.returncode == 0 and w.trash() == [] and w.st().get("reason") == ""
          and json.load(open(os.path.join(w.state, "offsite-manifest.json")))["trashed"] == [], str(w.st()))
    w.done()
    w = World(tool)
    rels = w.fill(packs=5)
    w.run("sync")
    pack = [r for r in rels if r.startswith("data/")][0]
    name = pack.rsplit("/", 1)[1]
    open(os.path.join(w.remote, "trash", name), "w").write("older item of the same name")
    os.remove(os.path.join(w.repo, pack))
    r = w.run("sync")
    check("deletions", "two items of one name in the trash: nothing is deleted, it is said", r.returncode == 0
          and len(w.trash()) == 2 and "Proton's trash" in w.st().get("reason", ""), r.stderr + str(w.st()) + str(w.trash()))
    w.done()


def g_interrupted(tool):
    w = World(tool)
    w.fill(packs=3)
    # call 1 = config, 2 = keys, 3 = the first data folder: a part is left there and the run stops
    r = w.run("sync", STUB_PARTIAL_N="3")
    check("interrupted", "a failed upload is an error with the CLI's words", r.returncode == 1 and w.st().get("state") == "error"
          and "connection" in w.st().get("reason", ""), r.stderr + str(w.st()))
    m = json.load(open(os.path.join(w.state, "offsite-manifest.json")))
    check("interrupted", "what was sent whole is in the manifest, the part is not", "config" in m["files"]
          and not any(k.startswith("data/") for k in m["files"]), str(m["files"].keys()))
    # a run that died between an upload and the manifest write: the listing shows what is already there
    os.remove(os.path.join(w.state, "offsite-manifest.json"))
    before = len(w.uploads())
    r = w.run("sync")
    check("interrupted", "the next run finishes", r.returncode == 0 and w.remote_files() == w.local_files(), r.stderr)
    later = w.uploads()[before:]
    check("interrupted", "files already remote at their size are not sent again", not any(
        os.path.join(w.repo, "config") in c or any(p.startswith(os.path.join(w.repo, "keys")) for p in c) for c in later), str(later))
    check("interrupted", "the part is trashed and deleted, then the file sent whole", any(c[:2] == ["fs", "trash"] for c in w.calls())
          and w.trash() == [])
    w.done()
    w = World(tool)
    w.fill(packs=3)
    r = w.run("sync", STUB_TERM_AT_UPLOAD="3")
    st = w.st()
    check("interrupted", "TERM ends cleanly", r.returncode == 0 and st.get("state") in ("idle", "waiting") and st.get("pid") == 0, r.stderr + str(st))
    r = w.run("sync")
    check("interrupted", "and the next run resumes", r.returncode == 0 and w.remote_files() == w.local_files())
    w.done()


def g_sizes(tool):
    w = World(tool)
    w.fill()
    r = w.run("sync", STUB_SHORT_N="3")
    check("sizes", "a short file is re-uploaded once and then right", r.returncode == 0 and w.remote_files() == w.local_files(), r.stderr)
    check("sizes", "the second try takes the short one away first", any(c[:2] == ["fs", "trash"] for c in w.calls()) and w.trash() == [])
    check("sizes", "no upload ever says replace", not any("replace" in c for c in w.uploads()))
    w2 = World(tool)
    w2.fill()
    r = w2.run("sync", STUB_SHORT_N="3,4")
    check("sizes", "short twice is an error", r.returncode == 1 and w2.st().get("state") == "error" and "size" in w2.st().get("reason", ""),
          r.stderr + str(w2.st()))
    w.done()
    w2.done()


def g_fetch(tool):
    w = World(tool)
    w.fill()
    w.run("sync")
    dest = os.path.join(w.dir, "back")
    r = w.run("fetch", dest)
    check("fetch", "fetch downloads and checks", r.returncode == 0 and "0 wrong" in r.stdout and w.local_files() == {
        os.path.relpath(os.path.join(dp, n), dest): os.path.getsize(os.path.join(dp, n)) for dp, _d, fs in os.walk(dest) for n in fs},
        r.stdout + r.stderr)
    shutil.rmtree(dest)
    victim = next(r for r in w.remote_files() if r.startswith("data/"))
    with open(os.path.join(w.base(), victim), "ab") as f:
        f.write(b"x")
    r = w.run("fetch", dest)
    check("fetch", "a changed file is named", r.returncode == 1 and victim in r.stdout, r.stdout)
    r = w.run("fetch", dest)
    check("fetch", "a folder with files in it is refused", r.returncode == 4)
    w.done()


def g_lock(tool):
    import fcntl
    w = World(tool)
    w.fill()
    fd = os.open(os.path.join(w.snap, "lock"), os.O_RDONLY)
    fcntl.flock(fd, fcntl.LOCK_EX)
    t = time.time()
    r = w.run("sync")
    check("lock", "an exclusive holder makes it wait", r.returncode == 3 and w.st().get("state") == "waiting" and w.st().get("cause") == "busy" and not w.calls()
          and time.time() - t < 20, r.stderr + str(w.st()))
    fcntl.flock(fd, fcntl.LOCK_UN)
    fcntl.flock(fd, fcntl.LOCK_SH)
    check("lock", "a shared holder does not stop it", w.run("sync").returncode == 0)
    os.close(fd)
    # a run holds the lock shared while it works: an exclusive try during the run fails (the CLI stub looks)
    probe = os.path.join(w.dir, "probe-cli")
    with open(probe, "w") as f:
        f.write("#!/usr/bin/env python3\nimport fcntl,os,sys,subprocess\nfd=os.open(%r,os.O_RDONLY)\n"
                "try:\n    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB); open(%r,'a').write('FREE\\n')\nexcept OSError:\n    open(%r,'a').write('HELD\\n')\n"
                "os.execv(%r,[%r]+sys.argv[1:])\n" % (os.path.join(w.snap, "lock"), os.path.join(w.dir, "seen"), os.path.join(w.dir, "seen"),
                                                      STUB, STUB))
    os.chmod(probe, 0o755)
    w2 = World(tool)
    w2.fill()
    with open(probe) as f:
        body = f.read().replace(w.snap, w2.snap).replace(os.path.join(w.dir, "seen"), os.path.join(w2.dir, "seen"))
    with open(os.path.join(w2.dir, "probe"), "w") as f:
        f.write(body)
    os.chmod(os.path.join(w2.dir, "probe"), 0o755)
    w2.run("sync", LARES_PROTON_DRIVE=os.path.join(w2.dir, "probe"))
    seen = open(os.path.join(w2.dir, "seen")).read().split() if os.path.exists(os.path.join(w2.dir, "seen")) else []
    check("lock", "the lock is held shared for the whole sync", seen and set(seen) == {"HELD"}, str(seen[:3]))
    # one instance
    w3 = World(tool)
    w3.fill()
    os.makedirs(w3.state)
    ifd = os.open(os.path.join(w3.state, "offsite.lock"), os.O_RDWR | os.O_CREAT)
    fcntl.flock(ifd, fcntl.LOCK_EX)
    r = w3.run("sync")
    check("lock", "a second instance does not run", r.returncode == 3 and not w3.calls(), r.stderr)
    os.close(ifd)
    for x in (w, w2, w3):
        x.done()


def g_signedout(tool):
    w = World(tool)
    w.fill()
    r = w.run("sync", STUB_SIGNED_OUT="1")
    check("signedout", "signed out is said in plain words", r.returncode == 1 and w.st().get("state") == "error"
          and "signed out" in w.st().get("reason", "") and "proton-drive auth login" in w.st().get("reason", ""), str(w.st()))
    r = w.run("sync", STUB_THROTTLED="1")
    check("signedout", "throttled waits", r.returncode == 3 and w.st().get("state") == "waiting" and w.st().get("cause") == "throttled", r.stderr + str(w.st()))
    r = w.run("sync", STUB_LIST_FAIL="1")
    check("signedout", "a failing listing is an error", r.returncode == 1 and w.st().get("state") == "error")
    s = w.run("status", "--json")
    n = len(w.calls())
    w.run("status", "--json")
    check("signedout", "status never calls the CLI", len(w.calls()) == n and json.loads(s.stdout)["state"] == "error")
    check("signedout", "and the run recovers", w.run("sync").returncode == 0 and w.st().get("state") == "idle")
    w.done()


def g_config(tool):
    w = World(tool, enabled=False)
    w.fill()
    r = w.run("sync")
    s = json.loads(w.run("status", "--json").stdout)
    check("config", "off: nothing runs and the state says off", r.returncode == 3 and not w.calls() and s["state"] == "off", r.stderr)
    w.done()
    w = World(tool)
    os.unlink(w.config)
    w.fill()
    check("config", "no config file: off", w.run("sync").returncode == 3 and not w.calls())
    w.done()
    w = World(tool)
    w.fill()
    w.run("sync")
    check("config", "the folder and the host name the remote place", "T/testhost" in " ".join(str(c) for c in w.calls())
          and os.path.isdir(os.path.join(w.base(), "keys")))
    s = json.loads(w.run("status", "--json").stdout)
    check("config", "status after a sync", s["state"] == "idle" and s["pending"] == {"files": 0, "bytes": 0}, str(s))
    w.done()


def g_places(tool):
    """Every machine and every repository has its own place on one Proton Drive, and none touches another's."""
    w = World(tool, hostname="laptop")
    w.fill(packs=3)
    r1 = w.run("sync")
    d = World(tool, hostname="desktop", config_bytes=b"desktop-config", remote=w.remote)
    d.put("config", d.config_bytes)
    for i in range(4):
        d.pack("data", "desk%d" % i, 400 + i)
    d.pack("keys", "dk")
    d.pack("index", "di")
    d.pack("snapshots", "ds")
    r2 = d.run("sync")
    top = sorted(os.listdir(os.path.join(w.remote, "my-files", "T")))
    check("places", "a laptop and a desktop have their own folders", r1.returncode == 0 and r2.returncode == 0 and top == ["desktop", "laptop"], str(top) + r2.stderr)
    check("places", "each place holds its own repository whole", w.remote_files() == w.local_files() and d.remote_files() == d.local_files())
    keep = w.remote_files()
    gone = next(r for r in d.local_files() if r.startswith("data/"))
    os.remove(os.path.join(d.repo, gone))
    r = d.run("sync")
    check("places", "what the desktop prunes is removed at the desktop's place only", r.returncode == 0 and gone not in d.remote_files() and w.remote_files() == keep, r.stderr)
    # one name on two machines
    t = World(tool, hostname="laptop", config_bytes=b"a twin of the name", remote=w.remote)
    t.put("config", t.config_bytes)
    t.pack("data", "twin")
    t.pack("snapshots", "ts")
    r = t.run("sync")
    check("places", "two machines of one name: two places, neither touched by the other", r.returncode == 0 and t.base() != w.base() and w.remote_files() == keep
          and t.remote_files() == t.local_files(), r.stderr)
    # a repository made anew on one machine
    old = d.base()
    before = {f: os.path.getsize(os.path.join(dp, f)) for dp, _x, fs in os.walk(old) for f in fs}
    d.put("config", b"made anew")
    r = d.run("sync")
    after = {f: os.path.getsize(os.path.join(dp, f)) for dp, _x, fs in os.walk(old) for f in fs}
    check("places", "a repository made anew gets a new place; the old copy stays whole", r.returncode == 0 and d.base() != old and before == after, r.stderr)
    # the second lock on the door: a place that holds another's config
    x = World(tool, hostname="laptop")
    x.fill(packs=2)
    os.makedirs(x.base())
    with open(os.path.join(x.base(), "config"), "wb") as f:
        f.write(b"other-config")
    r = x.run("sync")
    check("places", "a place that holds another repository's config is refused, and nothing is sent", r.returncode == 4 and "another repository" in x.st().get("reason", "")
          and not x.uploads() and open(os.path.join(x.base(), "config"), "rb").read() == b"other-config", r.stderr + str(x.st()))
    # (the foreign config is as long as ours: only its content tells them apart)
    y = World(tool, hostname="laptop")
    y.fill(packs=2)
    os.makedirs(y.base())
    with open(os.path.join(y.base(), "config"), "wb") as f:
        f.write(b"other-config")
    r = y.run("sync", STUB_LIST_FAIL_N=1)
    check("places", "a listing that fails once is not an empty place: nothing is sent", r.returncode == 1 and not y.uploads(), r.stderr + str(y.uploads())[:200])
    # the name in the config
    m = World(tool, machine="work-laptop")
    m.fill(packs=1)
    check("places", "offsite.machine names the folder", m.run("sync").returncode == 0 and m.remote_files() == m.local_files())
    for bad in ("../laptop", "a/b", "", ".hidden", "x" * 80):
        b = World(tool, hostname="testhost", machine=bad)
        b.machine = "testhost"
        b.fill(packs=1)
        r = b.run("sync")
        check("places", "a machine name that is no folder name is not used: %r" % bad[:12], r.returncode == 0 and b.remote_files() == b.local_files(), r.stderr)
        b.done()
    # which copy
    r = w.run("remotes")
    lines = r.stdout.splitlines()
    check("places", "remotes lists every copy and marks this machine's", r.returncode == 0 and len(lines) == 4 and sum("this machine's" in ln for ln in lines) == 1
          and any(ln.startswith("laptop/" + os.path.basename(w.base())) and "this machine's" in ln for ln in lines), r.stdout + r.stderr)
    n = World(tool, hostname="newdisk", remote=w.remote)
    dest = os.path.join(n.dir, "back")
    r = n.run("fetch", dest)
    check("places", "a new disk with several copies to choose from is asked which, and downloads nothing", r.returncode == 2 and "laptop/" in r.stderr and not os.path.exists(dest), r.stderr)
    r = n.run("fetch", dest, "--from=laptop/" + os.path.basename(w.base()))
    got = {os.path.relpath(os.path.join(dp, f), dest) for dp, _x, fs in os.walk(dest) for f in fs}
    check("places", "--from brings that copy back, checked", r.returncode == 0 and got == set(keep), r.stdout + r.stderr)
    r = n.run("fetch", os.path.join(n.dir, "back2"), "--from=../../etc")
    check("places", "--from is a place, never a path", r.returncode == 2 and not os.path.exists(os.path.join(n.dir, "back2")), r.stderr)
    check("places", "never empty-trash", not w.emptied_trash())
    for one in (w, d, t, x, y, m, n):
        one.done()


def g_restic(tool):
    if not os.path.exists(RESTIC):
        return
    w = World(tool)
    work = os.path.join(w.dir, "src")
    os.makedirs(work)
    pw = os.path.join(w.dir, "pw")
    open(pw, "w").write("test-password\n")
    env = dict(os.environ, RESTIC_REPOSITORY=w.repo, RESTIC_PASSWORD_FILE=pw)

    def restic(*a):
        return subprocess.run([RESTIC, "--no-cache", "--quiet"] + list(a), env=env, capture_output=True, text=True)
    os.rmdir(w.repo)
    init = restic("init")
    check("restic", "init", init.returncode == 0, init.stderr)
    for i in range(3):
        with open(os.path.join(work, "f%d" % i), "wb") as f:
            f.write(os.urandom(50000))
        b = restic("backup", "--host", "testhost", work)
        check("restic", "backup %d" % i, b.returncode == 0, b.stderr)
    r = w.run("sync")
    check("restic", "a real repository copies", r.returncode == 0 and w.remote_files() == w.local_files(), r.stderr)
    dest = os.path.join(w.dir, "back")
    f = w.run("fetch", dest)
    check("restic", "fetch checks keys, data, index and snapshots by name", f.returncode == 0 and "0 wrong" in f.stdout, f.stdout + f.stderr)
    f2 = restic("forget", "--keep-last", "1", "--prune")
    check("restic", "forget and prune", f2.returncode == 0, f2.stderr)
    r = w.run("sync", "--allow-shrink")
    check("restic", "the pruned repository is mirrored, deletions included", r.returncode == 0 and w.remote_files() == w.local_files(), r.stderr)
    shutil.rmtree(dest)
    f = w.run("fetch", dest)
    c = restic("check")
    check("restic", "the fetched copy is a repository restic accepts", f.returncode == 0 and subprocess.run(
        [RESTIC, "--no-cache", "--quiet", "-r", dest, "--password-file", pw, "check"], capture_output=True, text=True).returncode == 0
        and c.returncode == 0, f.stdout + c.stderr)
    w.done()


GROUPS = [("conditions", g_conditions), ("order", g_order), ("manifest", g_manifest), ("deletions", g_deletions),
          ("interrupted", g_interrupted), ("sizes", g_sizes), ("fetch", g_fetch), ("lock", g_lock), ("signedout", g_signedout),
          ("config", g_config), ("places", g_places), ("restic", g_restic)]


def run_all(tool):
    for name, fn in GROUPS:
        before = len(results)
        try:
            fn(tool)
        except Exception as e:  # a case that throws is a failed check, not a lost run
            check(name, "ran to the end", False, repr(e))
        if len(results) == before:
            check(name, "has checks", name == "restic")


def main():
    os.makedirs(SBX, exist_ok=True)
    arm = os.environ.get("ARM")
    if arm == "all":
        bad = []
        for a in ARMS:
            r = subprocess.run([sys.executable, os.path.abspath(__file__)], env=dict(os.environ, ARM=a), capture_output=True, text=True)
            line = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
            if "ARM %s RESULT PASS" % a not in line:
                bad.append(a)
            print(line)
        ok = not bad
        print("SNAPSHOT_OFFSITE_CASES ARMS RESULT %s%s" % ("PASS" if ok else "FAIL", "" if ok else " (" + ", ".join(bad) + ")"))
        return 0 if ok else 1
    tool = os.path.join(ROOT, "tools", "snapshot", "lares-offsite")
    copy = None
    if arm:
        if arm not in ARMS:
            print("unknown ARM " + arm)
            return 2
        group, anchor, patch = ARMS[arm]
        copy = tempfile.mkdtemp(dir=SBX)
        os.makedirs(os.path.join(copy, "tools", "snapshot"))
        shutil.copytree(os.path.join(ROOT, "tools", "lib"), os.path.join(copy, "tools", "lib"))
        tool = os.path.join(copy, "tools", "snapshot", "lares-offsite")
        text = open(os.path.join(ROOT, "tools", "snapshot", "lares-offsite")).read()
        if text.count(anchor) != 1:
            print("ARM %s: anchor gone (%d matches)" % (arm, text.count(anchor)))
            print("SNAPSHOT_OFFSITE_CASES ARM %s RESULT FAIL (anchor)" % arm)
            return 1
        open(tool, "w").write(text.replace(anchor, patch))
    run_all(tool)
    if copy:
        shutil.rmtree(copy, ignore_errors=True)
    for g in {g for g, *_ in results}:
        n = [r for r in results if r[0] == g]
        print("%-12s %d/%d" % (g, sum(1 for r in n if r[2]), len(n)))
    if arm:
        failed_groups = {g for g, _n, ok, _d in results if not ok}
        ok = group in failed_groups
        print("SNAPSHOT_OFFSITE_CASES ARM %s RESULT %s" % (arm, "PASS" if ok else "FAIL (group %s stayed green)" % group))
        return 0 if ok else 1
    ok = all(r[2] for r in results)
    print("SNAPSHOT_OFFSITE_CASES RESULT %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
