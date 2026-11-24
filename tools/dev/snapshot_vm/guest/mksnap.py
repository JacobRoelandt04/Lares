#!/usr/bin/env python3
"""Stands in for `lares-snapshot-root create` in the rescue's VM tests (stream A's tool is tested elsewhere): takes a restic snapshot of the
covered paths exactly as the contract says (docs/contracts/snapshots.md sections 3 and 5) and writes the record and the index line.
   mksnap.py [--reason update|manual|prime] [--title TEXT]"""
import glob, json, os, subprocess, sys, time

REPO = "/.lares-snapshots"
EXCL = ["/var/lib/ollama", "/var/lib/systemd/coredump", "/var/lib/docker", "/var/lib/containers", "/var/lib/containerd",
        "/var/lib/libvirt/images", "/var/lib/machines", "/var/lib/portables", "/var/lib/flatpak/repo", "/var/lib/waydroid",
        "/var/lib/pacman/sync", "/root/.cache"]
PATHS = ["/usr", "/opt", "/etc", "/srv", "/root", "/var/lib"]


def arg(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def main():
    reason, title = arg("--reason", "manual"), arg("--title", "Manual")
    os.makedirs(REPO + "/records", exist_ok=True)
    env = dict(os.environ, RESTIC_PASSWORD_FILE=REPO + "/key", RESTIC_REPOSITORY=REPO + "/repo")
    if not os.path.exists(REPO + "/key"):
        with open(REPO + "/key", "w") as f:
            f.write(os.urandom(24).hex() + "\n")
        os.chmod(REPO + "/key", 0o600)
    if not os.path.exists(REPO + "/repo/config"):
        subprocess.run(["restic", "init", "--quiet"], env=env, check=True)
    now = int(time.time())
    pkgs = subprocess.run(["pacman", "-Q"], capture_output=True, text=True).stdout.split("\n")
    before = dict(l.split(" ", 1) for l in pkgs if l)
    kernel = os.uname().release
    rec = {"version": 1, "id": "", "short": "", "time": now, "reason": reason, "run": None, "count": len(before), "critical": [],
           "targets": [], "before": before, "changed": None, "state": "done", "keep": False, "note": "", "added": 0, "addedPacked": 0,
           "files": 0, "bytes": 0, "seconds": 0, "paths": PATHS, "excludes": EXCL, "kernel": kernel}
    os.makedirs("/var/lib/lares", exist_ok=True)
    json.dump(rec, open("/var/lib/lares/snapshot-record.json", "w"))
    boot = sorted(p for p in glob.glob("/boot/*") if os.path.isfile(p))
    cmd = ["restic", "backup", "--one-file-system", "--no-cache", "--pack-size", "64", "--read-concurrency", "8", "--json",
           "--tag", "lares", "--tag", ("lares-prime" if reason == "prime" else reason), "--host", "lares-vm"]
    for e in EXCL:
        cmd += ["--exclude", e]
    t0 = time.time()
    r = subprocess.run(cmd + PATHS + boot, env=env, capture_output=True, text=True)
    if r.returncode not in (0, 3):
        print(r.stderr[-2000:]); return 1
    summ = [json.loads(l) for l in r.stdout.splitlines() if '"summary"' in l][-1]
    sid = summ["snapshot_id"]
    rec.update(id=sid, short=sid[:8], added=summ["data_added"], addedPacked=summ.get("data_added_packed", 0),
               files=summ["total_files_processed"], bytes=summ["total_bytes_processed"], seconds=int(time.time() - t0))
    if reason != "prime":
        json.dump(rec, open(f"{REPO}/records/{sid[:8]}.json", "w"))
        old = open(REPO + "/index.tsv").read() if os.path.exists(REPO + "/index.tsv") else ""
        open(REPO + "/index.tsv.new", "w").write(f"{sid}\t{now}\t{reason}\t{title}\n" + old)
        os.replace(REPO + "/index.tsv.new", REPO + "/index.tsv")
    print(f"snapshot {sid[:8]} {summ['total_bytes_processed']} bytes in {int(time.time()-t0)} s, added {summ['data_added']}")
    return 0


sys.exit(main())
