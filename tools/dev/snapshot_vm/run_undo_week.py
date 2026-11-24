#!/usr/bin/env python3
"""The Undo the user will really meet: a week-long update (no split packages, 40+ packages, a kernel), the pacman cache kept, then
`lares-snapshot undo <short>` as the user. Tries the dates in order until one whose plan has no `takenOver` and >= 40 files incl. a kernel.

    run_undo_week.py [--dates 2026/10/25,2026/10/27,...]      SNAPSHOT_UNDOWEEK <step> RESULT PASS|FAIL lines and a final one
Saves the real transcripts: tools/system_update/fixtures/undo-week.log (+ snapshot-week-update.log).
"""
import json, os, re, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import vmlib as L
import run_pacman as P

DATES = ["2026/10/25", "2026/10/27", "2026/10/29", "2026/11/01", "2026/11/05"]
STEPS = []
MIN = int(sys.argv[sys.argv.index("--min") + 1]) if "--min" in sys.argv else 40   # the archive has no kernel week of 40+ packages without a split (see the report)


def step(name, ok, detail=""):
    STEPS.append((name, bool(ok)))
    print(f"SNAPSHOT_UNDOWEEK {name} RESULT {'PASS' if ok else 'FAIL'} {'' if ok else detail}".rstrip(), flush=True)


def attempt(date, start=None):
    """-> "retry" (this date does not fit the case) or "done"."""
    url = f"https://archive.archlinux.org/repos/{date}"
    disk = L.new_overlay(os.path.join(L.DISKS, "base.qcow2"), "undoweek")
    vm = L.VM("undoweek", disk, ssh_port=2222)
    vm.start()
    try:
        vm.wait_ssh(300)
        tar = subprocess.run(["tar", "-C", P.REPO, "-c", "tools/snapshot", "tools/lib"], capture_output=True, check=True).stdout
        subprocess.run(vm.ssh_args() + [f"mkdir -p {P.QS} && tar -x -C {P.QS}"], input=tar, check=True, capture_output=True)
        vm.ssh("mkdir -p /home/vmuser/.config/quickshell/config && chown -R vmuser:vmuser /home/vmuser/.config /home/vmuser/qs")
        P.mirror(vm, P.OLD)
        vm.ssh("pacman -Sy --noconfirm polkit 2>&1 | tail -1", check=False, timeout=900)
        if start:   # the base image is of 2026/10/20 and the openssl split lies after it: first move the machine to `start` with no hook installed yet
            P.mirror(vm, f"https://archive.archlinux.org/repos/{start}")
            rc, out = vm.ssh("pacman -Syyu --noconfirm --disable-download-timeout 2>&1 | tail -3; pacman -Q linux-lts", check=False, timeout=3000)
            print(f"  moved to {start}: {out.strip()[-200:]}", flush=True)
            vm.ssh("grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1; sync")
            P.mirror(vm, P.OLD)
            vm.ssh("systemctl reboot", check=False)   # run the kernel it has now: the reboot after the undo is judged against it
            time.sleep(8)
            vm.wait_ssh(400)
        rc, out = vm.ssh(f"cd {P.QS}/tools/snapshot/root && printf 'yes\\n' | SUDO_USER=vmuser bash install.sh", check=False, timeout=900)
        step(f"{date} install", rc == 0 and "Installed." in out, out[-400:])
        vm.ssh("printf '{\"minFreeGB\": 1}\\n' > /home/vmuser/.config/quickshell/config/snapshots.jsonc; chown vmuser:vmuser /home/vmuser/.config/quickshell/config/snapshots.jsonc")
        _, kernel0 = vm.ssh("uname -r")
        _, ltsq = vm.ssh("pacman -Q linux-lts")
        P.mirror(vm, url)
        rc, text = P.transcript(vm, "pacman -Syyu --noconfirm --disable-download-timeout", "snapshot-week-update.log")
        m = re.search(r"lares-snapshot: done (\w+) added=(\d+) seconds=(\d+)", text)
        if not m or rc != 0:
            step(f"{date} update", False, text[-500:])
            return "retry"
        short = m.group(1)
        P.save("snapshot-week-update.log", text)
        _, js = vm.ssh(f"sudo -u vmuser python3 {P.QS}/tools/snapshot/lares-snapshot undo-plan {short} --json", check=False)
        try:
            plan = json.loads(js)
        except ValueError:
            step(f"{date} undo_plan_json", False, js[-400:])
            return "retry"
        names = [f["name"] for f in plan.get("files", [])]
        print(f"  {date}: plan has {len(names)} files, takenOver={plan.get('takenOver')}, missing={plan.get('missing')}, newSince={plan.get('newSince')}", flush=True)
        if plan.get("takenOver") or len(names) < MIN or not ({"linux", "linux-lts"} & set(names)):
            print(f"  {date} does not fit (takenOver / < 40 packages / no kernel): next date", flush=True)
            return "retry"
        P.INFO["week_date"] = date
        P.INFO["week_packages"] = len(names)
        # the undo, as the user, on a pty at 200 columns
        _, before_q = vm.ssh("pacman -Q")
        rc, text = P.transcript(vm, f"python3 {P.QS}/tools/snapshot/lares-snapshot undo {short}", "undo-week.log", user="vmuser", stdin="y\\ny\\ny\\n")
        P.save("undo-week.log", text)
        _, rec = vm.ssh(f"cat /.lares-snapshots/records/{short}.json")
        before = json.loads(rec)["before"]
        _, after_q = vm.ssh("pacman -Q")
        now = dict(l.split(" ", 1) for l in after_q.strip().splitlines() if " " in l)
        wrong = [n for n in names if now.get(n) != before.get(n)]
        step(f"{date} undo_exit_zero", rc == 0, text[-800:])
        step(f"{date} every_package_of_the_plan_is_as_before", rc == 0 and not wrong, f"{len(wrong)} differ, e.g. {wrong[:5]}")
        # the snapshot taken inside the undo
        _, idx = vm.ssh("head -n3 /.lares-snapshots/index.tsv")
        _, recs = vm.ssh("for f in /.lares-snapshots/records/*.json; do python3 -c \"import json,sys;r=json.load(open(sys.argv[1]));print(r['short'],r['reason'],repr(r['note']),r['state'])\" $f; done")
        print("  index head:", idx.replace("\n", " | "), "\n  records:", recs.replace("\n", " | "), flush=True)
        undo_rows = [l for l in recs.splitlines() if " undo " in l]
        step(f"{date} undo_snapshot_reason_and_note", bool(undo_rows) and "''" not in undo_rows[0], recs)
        step(f"{date} undo_snapshot_title_in_index", any("\tundo\t" in l for l in idx.splitlines()), idx)
        # the old kernel after a reboot
        vm.ssh("systemctl reboot", check=False)
        time.sleep(5)
        vm.wait_ssh(400)
        _, kernel1 = vm.ssh("uname -r")
        step(f"{date} reboots_into_the_old_kernel", kernel1.strip() == kernel0.strip() and bool(ltsq), f"{kernel0.strip()} -> {kernel1.strip()}")
        return "done"
    finally:
        vm.kill()
        for f in os.listdir(L.DISKS):
            if f.startswith("overlay-undoweek"):
                os.unlink(os.path.join(L.DISKS, f))


def main():
    dates = DATES
    if "--dates" in sys.argv:
        dates = sys.argv[sys.argv.index("--dates") + 1].split(",")
    subprocess.run([sys.executable, os.path.join(HERE, "build_base.py")], check=True)
    L.stop_leftovers()
    start = sys.argv[sys.argv.index("--start") + 1] if "--start" in sys.argv else None
    for d in dates:
        STEPS.clear()
        if attempt(d, start) == "done":
            break
    else:
        step("a_date_that_fits", False, f"none of {dates}")
    bad = [n for n, ok in STEPS if not ok]
    print("INFO", P.INFO)
    print(f"SNAPSHOT_UNDOWEEK RESULT {'PASS' if not bad else 'FAIL'} {', '.join(bad)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
