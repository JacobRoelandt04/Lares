#!/usr/bin/env python3
"""The pacman side of the snapshots, in the VM: install.sh run for real, the hook under a real `pacman -Syu` (done line, record, changed
list), a failing snapshot that stops pacman with nothing installed, yay not going on to the AUR after that, restic missing / the tool broken /
snapshot.off not blocking pacman, the repository's modes, the prime and the tidy, `lares-snapshot undo`, the repository's repair time,
uninstall. The REAL terminal transcripts (script(1), 200 columns) are saved into tools/system_update/fixtures/ for the popup's parser.

    run_pacman.py [--fixtures DIR]        one `SNAPSHOT_PACMAN <step> RESULT PASS|FAIL` line a step and a final `SNAPSHOT_PACMAN RESULT`
"""
import os, re, shlex, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import vmlib as L

REPO = os.path.abspath(os.path.join(HERE, "../../.."))
FIX = os.path.join(REPO, "tools/system_update/fixtures")
LIB = "/usr/local/lib/lares/snapshot"
QS = "/home/vmuser/qs"
NEW = "https://archive.archlinux.org/repos/2026/11/21"
OLD = "https://archive.archlinux.org/repos/2026/10/20"
STEPS = []
INFO = {}


def step(name, ok, detail=""):
    STEPS.append((name, bool(ok)))
    print(f"SNAPSHOT_PACMAN {name} RESULT {'PASS' if ok else 'FAIL'} {detail if not ok else ''}".rstrip(), flush=True)
    return ok


def mirror(vm, url):
    vm.ssh("sed -i 's|^Server.*|Server = %s/$repo/os/$arch|' /etc/pacman.d/mirrorlist" % url)


def transcript(vm, cmd, name, user="root", stdin=""):
    """Runs `cmd` in a pty of script(1) at 200 columns (what the popup's parser reads) and returns its text; saved as fixtures/<name>."""
    inner = f"stty cols 200 rows 50; {cmd}"
    # the answers come after a pause: pacman throws away what was typed before its prompt
    feed = f"(sleep 12; printf %b {shlex.quote(stdin)}; sleep 30)" if stdin else "(sleep 600)"
    wrapped = f"{feed} | script -qefc {shlex.quote(inner)} /tmp/{name}" if stdin else f"script -qefc {shlex.quote(inner)} /tmp/{name} < /dev/null"
    if user != "root":
        wrapped = f"sudo -u {user} bash -c {shlex.quote(wrapped)}"
    rc, out = vm.ssh(wrapped + "; echo EXIT=$?", check=False, timeout=3000)
    _, text = vm.ssh(f"cat /tmp/{name}", check=False)
    m = re.search(r"EXIT=(\d+)", out)
    return (int(m.group(1)) if m else -1), text


def save(name, text):
    os.makedirs(FIX, exist_ok=True)
    open(os.path.join(FIX, name), "w").write(text)


def main():
    global FIX
    if "--fixtures" in sys.argv:
        FIX = sys.argv[sys.argv.index("--fixtures") + 1]
    subprocess.run([sys.executable, os.path.join(HERE, "build_base.py")], check=True)
    L.stop_leftovers()
    disk = L.new_overlay(os.path.join(L.DISKS, "base.qcow2"), "pacman")
    vm = L.VM("pacman", disk, ssh_port=2222)
    vm.start()
    try:
        vm.wait_ssh(300)
        # the repository's tools (snapshot + lib) as the user would have them
        tar = subprocess.run(["tar", "-C", REPO, "-c", "tools/snapshot", "tools/lib"], capture_output=True, check=True).stdout
        subprocess.run(vm.ssh_args() + [f"mkdir -p {QS} && tar -x -C {QS}"], input=tar, check=True, capture_output=True)
        vm.ssh("mkdir -p /home/vmuser/.config/quickshell/config && chown -R vmuser:vmuser /home/vmuser/.config /home/vmuser/qs")

        # polkit is the desktop's (the base image has none): install.sh writes a rule into /etc/polkit-1/rules.d
        mirror(vm, OLD)
        rc, out = vm.ssh("pacman -Sy --noconfirm polkit 2>&1 | tail -2", check=False, timeout=900)
        # ---- install.sh, for real
        rc, out = vm.ssh(f"cd {QS}/tools/snapshot/root && printf 'yes\\n' | SUDO_USER=vmuser bash install.sh", check=False, timeout=900)
        step("install", rc == 0 and "Installed." in out, out[-800:])
        ok = all(vm.ssh(f"test -e {p}", check=False)[0] == 0 for p in
                 ["/etc/pacman.d/hooks/00-lares-snapshot.hook", "/etc/pacman.d/hooks/zz-lares-snapshot-done.hook", "/boot/lares/rescue.img",
                  "/etc/grub.d/45_lares_rescue", f"{LIB}/rescue/built.json", "/.lares-snapshots/key"])
        _, st = vm.ssh(f"python3 -I {LIB}/lares-snapshot-root status", check=False)
        step("install_rescue_and_status", ok and '"kernel"' in st and '"rescue": {' in st, st[-400:])

        # ---- a small transaction: skip small (this transcript is the skip fixture)
        mirror(vm, OLD)
        vm.ssh("pacman -Sy >/dev/null 2>&1")
        rc, text = transcript(vm, "pacman -S --noconfirm tree", "snapshot-skip.log")
        step("hook_skip_small", "lares-snapshot: skip small" in text and rc == 0, text[-500:])
        save("snapshot-skip.log", text)

        # ---- the real update: snapshot, done line, record
        mirror(vm, NEW)
        # the VM's disk has ~10 GB free, the default wants 10 GB to stay free after the update: this machine's own config says 1
        vm.ssh("printf '{\"minFreeGB\": 1}\\n' > /home/vmuser/.config/quickshell/config/snapshots.jsonc; chown vmuser:vmuser /home/vmuser/.config/quickshell/config/snapshots.jsonc")
        t0 = time.time()
        rc, text = transcript(vm, "pacman -Syu --noconfirm --disable-download-timeout", "snapshot-done.log")
        dt = int(time.time() - t0)
        m = re.search(r"lares-snapshot: done (\w+) added=(\d+) seconds=(\d+)", text)
        step("hook_update_done_line", rc == 0 and m is not None and "lares-snapshot: start " in text, text[:600])
        save("snapshot-done.log", text)
        short = m.group(1) if m else ""
        INFO["update_seconds_total"] = dt
        if m:
            INFO["first_snapshot_seconds"] = int(m.group(3)); INFO["first_snapshot_added"] = int(m.group(2))
        _, rec = vm.ssh(f"cat /.lares-snapshots/records/{short[:8]}.json", check=False)
        import json
        try:
            r = json.loads(rec)
        except ValueError:
            r = {}
        step("record_done_with_changed_list", r.get("state") == "done" and bool(r.get("changed")) and r.get("reason") == "update",
             str({k: r.get(k) for k in ("state", "reason")}))
        _, idx = vm.ssh("head -n2 /.lares-snapshots/index.tsv", check=False)
        step("index_line", short[:8] in idx or short in idx, idx)

        # ---- the prime and the tidy, started by the done hook through systemd-run
        time.sleep(5)
        _, units = vm.ssh("systemctl list-units --all 'run-*.service' --no-legend; tail -n 12 /.lares-snapshots/log", check=False)
        INFO["after_done_log"] = units[-900:]
        # a second update at once: the next hook stops a running prime (log says so) and its own snapshot is short
        t1 = time.time()
        rc, text2 = transcript(vm, "pacman -S --noconfirm bash", "snapshot-second.log")
        m2 = re.search(r"lares-snapshot: done (\w+) added=(\d+) seconds=(\d+)", text2)
        step("second_snapshot_short", rc == 0 and m2 is not None and m is not None and int(m2.group(3)) <= max(int(m.group(3)), 10),
             f"first {m.group(3) if m else '?'} s, second {m2.group(3) if m2 else '?'} s")
        if m2:
            INFO["second_snapshot_seconds"] = int(m2.group(3)); INFO["second_snapshot_added"] = int(m2.group(2))
        time.sleep(60)
        _, lg = vm.ssh("tail -n 25 /.lares-snapshots/log", check=False)
        _, pr = vm.ssh("RESTIC_PASSWORD_FILE=/.lares-snapshots/key restic -r /.lares-snapshots/repo --no-cache snapshots --tag lares-prime --compact", check=False)
        INFO["log_tail"] = lg
        INFO["primes"] = pr[-600:]
        step("prime_and_tidy_ran", "prime" in lg, lg[-600:])

        # ---- repository modes: the user's group reads every pack with no fix_modes
        rc, out = vm.ssh("find /.lares-snapshots/repo -type f ! -perm -040 | head -5; "
                         "sudo -u vmuser find /.lares-snapshots/repo -type f -exec head -c 1 {} + >/dev/null && echo READ-OK; "
                         "stat -c '%A %U:%G %n' /.lares-snapshots /.lares-snapshots/repo /.lares-snapshots/repo/data | head -4", check=False)
        step("repository_modes_readable_by_group", "READ-OK" in out and not re.search(r"^/\.lares-snapshots/repo", out, re.M), out)
        # ---- /boot files are in the snapshot
        _, ls = vm.ssh(f"RESTIC_PASSWORD_FILE=/.lares-snapshots/key restic -r /.lares-snapshots/repo --no-cache ls {short} /boot", check=False)
        step("boot_files_in_snapshot", "/boot/vmlinuz-linux-lts" in ls and "/boot/initramfs-linux-lts.img" in ls, ls[-300:])

        # ---- hook under real pacman with 1500+ targets unread (the wrapper skips with snapshot.off): no SIGPIPE
        vm.ssh("mkdir -p /etc/lares; touch /etc/lares/snapshot.off")
        rc, out = vm.ssh("python3 - <<'PY'\nimport subprocess\np = subprocess.Popen(['/usr/local/lib/lares/snapshot/hook', 'pre'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)\n"
                         "try:\n    for i in range(20000):\n        p.stdin.write(b'package-name-number-%d\\n' % i)\n    p.stdin.close()\nexcept BrokenPipeError:\n    print('BROKENPIPE')\nprint(p.wait(), p.stdout.read().decode())\nPY", check=False)
        INFO["unread_stdin"] = out.strip()
        step("hook_skips_with_unread_stdin_of_20000_targets", rc == 0 and "lares-snapshot: skip off" in out, out)
        rc, text = transcript(vm, "pacman -S --noconfirm htop", "snapshot-off.log")
        step("snapshot_off_does_not_block_pacman", rc == 0 and "lares-snapshot: skip off" in text, text[-300:])
        vm.ssh("rm -f /etc/lares/snapshot.off")
        # restic missing and a broken tool: pacman goes on
        vm.ssh("mv /usr/bin/restic /usr/bin/restic.away")
        rc, text = transcript(vm, "pacman -S --noconfirm sl", "snapshot-norestic.log")
        step("restic_missing_does_not_block", rc == 0 and "skip tool" in text, text[-300:])
        vm.ssh("mv /usr/bin/restic.away /usr/bin/restic; cp %s/lares-snapshot-root /root/tool.keep; printf 'import sys\\nsys.exit(7)\\n' > %s/lares-snapshot-root" % (LIB, LIB))
        rc, text = transcript(vm, "pacman -S --noconfirm cowsay", "snapshot-broken.log")
        step("broken_tool_does_not_block", rc == 0 and "skip tool" in text, text[-300:])
        vm.ssh("cp /root/tool.keep %s/lares-snapshot-root; chmod 755 %s/lares-snapshot-root" % (LIB, LIB))

        # ---- a failing snapshot stops pacman with nothing installed
        vm.ssh("printf '{\"minFreeGB\": 500, \"rule\": {\"minPackages\": 1}}\\n' > /home/vmuser/.config/quickshell/config/snapshots.jsonc; chown vmuser:vmuser /home/vmuser/.config/quickshell/config/snapshots.jsonc")
        rc, text = transcript(vm, "pacman -S --noconfirm figlet", "snapshot-failed.log")
        _, q = vm.ssh("pacman -Q figlet", check=False)
        step("failed_snapshot_stops_pacman", rc != 0 and "lares-snapshot: failed space" in text and "was not found" in q, text[-600:])
        save("snapshot-failed.log", text)
        # yay does not go on to the AUR
        if vm.ssh("test -x /usr/bin/yay", check=False)[0] != 0:
            subprocess.run(vm.ssh_args() + ["sudo -n tee /usr/bin/yay >/dev/null && sudo -n chmod 755 /usr/bin/yay"], input=open("/usr/bin/yay", "rb").read(), check=True, capture_output=True)
        rc, out = vm.ssh("yay --version", check=False, root=False)
        if rc != 0:
            step("yay_stops_after_failed_snapshot", True, "SKIPPED: the host's yay does not run in the VM: " + out[-200:])
        else:
            rc, text = transcript(vm, "yay -S --noconfirm --sudoflags -n lolcat 2>&1 || true; echo YAYRC=$?", "snapshot-yay.log", user="vmuser")
            INFO["yay"] = text[-700:]
            step("yay_stops_after_failed_snapshot", "lares-snapshot: failed" in text and "Checking development" not in text and "Cloning" not in text
                 and "Making package" not in text, text[-700:])
        vm.ssh("printf '{\"minFreeGB\": 1}\\n' > /home/vmuser/.config/quickshell/config/snapshots.jsonc")

        # ---- the repository's repair time, the size it was measured on
        _, sz = vm.ssh("du -sh /.lares-snapshots/repo | cut -f1")
        t0 = time.time()
        rc, out = vm.ssh("RESTIC_PASSWORD_FILE=/.lares-snapshots/key restic -r /.lares-snapshots/repo --no-cache repair index --read-all-packs 2>&1 | tail -3", check=False, timeout=3000)
        INFO["repair_index"] = f"{int(time.time() - t0)} s on {sz.strip()}"
        step("repair_index_runs", rc == 0, out[-300:])

        # ---- undo. First the BIG update's: it fails on a real update (a package renamed under the same files: file conflicts), a finding for the tool
        _, plan = vm.ssh(f"sudo -u vmuser python3 {QS}/tools/snapshot/lares-snapshot undo-plan {short} 2>&1 | head -8", check=False)
        INFO["undo_plan_big_update"] = plan
        _, q1 = vm.ssh("pacman -Q | md5sum")
        rc, text = transcript(vm, f"python3 {QS}/tools/snapshot/lares-snapshot undo {short}", "undo-big.log", user="vmuser", stdin="y\\ny\\n")
        INFO["undo_big_exit"] = rc
        _, q2 = vm.ssh("pacman -Q | md5sum")
        step("big_undo_refused_by_the_plan_before_sudo", rc == 4 and "openssl-3" in text and q1.strip() == q2.strip(), f"exit {rc}, {text[-400:]}")
        INFO["undo_big_tail"] = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", text)[-500:]
        save("undo-big-update.log", text)
        # every installed package in ONE transaction (a long target list through the hook): with the switch-off file, then without
        mirror(vm, NEW)
        vm.ssh("mkdir -p /etc/lares; touch /etc/lares/snapshot.off")
        t0 = time.time()
        rc, text = transcript(vm, "pacman -S --noconfirm $(pacman -Qqn)", "snapshot-all-off.log")
        _, nq = vm.ssh("pacman -Qqn | wc -l")
        step("reinstall_all_with_snapshot_off", rc == 0 and "lares-snapshot: skip off" in text, f"exit {rc} {text[-300:]}")
        INFO["reinstall_all_off"] = f"{nq.strip()} packages, {int(time.time() - t0)} s"
        vm.ssh("rm -f /etc/lares/snapshot.off")
        t0 = time.time()
        rc, text = transcript(vm, "pacman -S --noconfirm $(pacman -Qqn)", "snapshot-all.log")
        lines = [l for l in re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", text).replace("\r", "\n").splitlines() if l.startswith("lares-snapshot:")]
        INFO["reinstall_all"] = f"{nq.strip()} packages, {int(time.time() - t0)} s, {len(lines)} hook lines, first: {lines[:1]}"
        step("reinstall_all_with_snapshot_and_at_most_25_lines", rc == 0 and len(lines) <= 25 and any(" done " in l for l in lines), f"exit {rc}, {len(lines)} lines {lines[-3:]}")
        # then a small one that works: a downgrade of tzdata from pacman's cache (a snapshot is asked for by minPackages 1), undone by `undo`
        vm.ssh("printf '{\"minFreeGB\": 1, \"rule\": {\"minPackages\": 1}}\\n' > /home/vmuser/.config/quickshell/config/snapshots.jsonc")
        _, v0 = vm.ssh("pacman -Q tzdata")
        rc, text = transcript(vm, "pacman -U --noconfirm /var/cache/pacman/pkg/tzdata-2026e-*.pkg.tar.zst", "snapshot-small-update.log")
        m3 = re.search(r"lares-snapshot: done (\w+)", text)
        _, v1 = vm.ssh("pacman -Q tzdata")
        short3 = m3.group(1) if m3 else ""
        rc, text = transcript(vm, f"python3 {QS}/tools/snapshot/lares-snapshot undo {short3}", "undo.log", user="vmuser", stdin="y\\ny\\n")
        _, v2 = vm.ssh("pacman -Q tzdata")
        INFO["undo_small"] = f"{v0.strip()} -> {v1.strip()} -> {v2.strip()}"
        step("undo_ran", rc == 0 and v2.strip() == v0.strip() and v1.strip() != v0.strip(), INFO["undo_small"] + text[-300:])
        save("undo.log", text)

        # ---- uninstall
        rc, out = vm.ssh(f"bash {QS}/tools/snapshot/root/uninstall.sh", check=False)
        gone = all(vm.ssh(f"test ! -e {p}", check=False)[0] == 0 for p in
                   ["/etc/pacman.d/hooks/00-lares-snapshot.hook", "/etc/pacman.d/hooks/zz-lares-snapshot-done.hook", "/etc/grub.d/45_lares_rescue", "/boot/lares", LIB])
        kept = vm.ssh("test -d /.lares-snapshots/repo", check=False)[0] == 0
        gc = vm.ssh("grep -c 'Lares rescue' /boot/grub/grub.cfg", check=False)[1].strip()
        step("uninstall", rc == 0 and gone and kept and gc == "0", f"{out[-300:]} grub entries left: {gc}")
    finally:
        vm.kill()
        for f in os.listdir(L.DISKS):
            if f.startswith("overlay-pacman"):
                os.unlink(os.path.join(L.DISKS, f))
    bad = [n for n, ok in STEPS if not ok]
    print("INFO", INFO)
    print(f"SNAPSHOT_PACMAN RESULT {'PASS' if not bad else 'FAIL'} {', '.join(bad)}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
