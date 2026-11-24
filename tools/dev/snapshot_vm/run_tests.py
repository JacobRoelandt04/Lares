#!/usr/bin/env python3
"""The rescue's VM tests (driven by tools/dev/snapshot_vm.sh). Each test ends in one `SNAPSHOT_VM <name> RESULT PASS|FAIL` line.

    run_tests.py [--rescue DIR] [--tests a,b,c,hib,cut] [--arm NAME] [--keep]

--rescue DIR  the rescue directory to test (default: tools/snapshot/root/rescue of this tree; an ARM test passes a patched COPY)
--arm NAME    an arm: the named check of the named test must FAIL (the runner patches a copy, see ARMS)
"""
import hashlib, json, os, re, shutil, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import vmlib as L

REPO = os.path.abspath(os.path.join(HERE, "../../.."))
RESCUE_SRC = os.path.join(REPO, "tools/snapshot/root/rescue")
PREPARED = os.path.join(L.DISKS, "prepared.qcow2")
GUEST = os.path.join(HERE, "guest")
DEFAULTS = os.path.join(REPO, "tools/snapshot/root/defaults.json")
SSH_PORT = 2222
PROTECTED = ["/usr/local/lib/lares/snapshot/lares-snapshot-root", "/etc/pacman.d/hooks/00-lares-snapshot.hook",
             "/etc/pacman.d/hooks/zz-lares-snapshot-done.hook", "/etc/lares/marker",
             "/usr/share/polkit-1/actions/org.lares.snapshot.policy", "/etc/polkit-1/rules.d/50-lares-snapshot.rules", "/etc/crypttab"]
ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b[()][A-Z0-9]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)")
STATS = {}


def strip(s):
    return ANSI.sub("", s).replace("\r", "")


def tree_hash(d):
    h = hashlib.sha256()
    for root, _, files in sorted(os.walk(d)):
        for f in sorted(files):
            h.update(open(os.path.join(root, f), "rb").read())
    return h.hexdigest()[:16]


class Results:
    def __init__(self, name):
        self.name, self.checks, self.t0 = name, [], time.time()

    def check(self, label, ok, detail=""):
        self.checks.append((label, bool(ok)))
        print(f"  CHECK {label} {'ok' if ok else 'FAIL'} {detail if not ok else ''}".rstrip(), flush=True)
        return ok

    def failed(self):
        return [l for l, ok in self.checks if not ok]


# ----------------------------------------------------------------------------------------------------------------- VM flows
def boot(name, disk, fresh=True, drive_opts=""):
    vm = L.VM(name, disk, ssh_port=SSH_PORT, drive_opts=drive_opts)
    vm.start()
    vm.wait_ssh(300)
    return vm


SERIALIZE = ("sed -i \"/menuentry 'Lares rescue'/,/^}/ s|ro console=tty0|ro console=tty0 console=ttyS0,115200 lares.serial=ttyS0|\" /boot/grub/grub.cfg; "
             "grep -c lares.serial=ttyS0 /boot/grub/grub.cfg")


def serialize_entry(vm):
    """The installed entry has the screen only; the test machine adds a serial console to ITS copy of grub.cfg so a script can drive the menu."""
    rc, out = vm.ssh(SERIALIZE, check=False)
    if "1" not in out:
        raise RuntimeError("could not add the serial console to the rescue entry: " + out)


def restart(vm):
    """Start the same disk again after a power cut or a poweroff (the OVMF vars file stays)."""
    vm.kill()
    vm.start()


def grub_choose(vm, since, downs=40):
    """What a person does at the GRUB menu: the menu waits 1 s, so the first key goes in the moment it is drawn. Down is pressed until
    the highlight (a * on the serial console) is on "Lares rescue", then Enter."""
    vm.expect(r"The highlighted entry will be executed automatically", 180, since=since)
    L.log("GRUB menu is up; choosing Lares rescue")
    for _ in range(downs):
        m0 = vm.mark()
        vm.send("\x1b[B")
        time.sleep(0.25)
        if re.search(r"\*Lares rescue", strip(vm.text_since(m0))):
            break
    else:
        raise RuntimeError("the GRUB menu never highlighted Lares rescue")
    vm.send("\r")


def frame(vm, since=0):
    """The last full screen of the rescue (everything after its last clear), without escape codes."""
    t = vm.text_since(since)
    i = t.rfind("\x1b[2J")
    return strip(t[i:] if i >= 0 else t)


def menu_rows(fr):
    rows = []
    for l in fr.split("\n"):
        if re.match(r"^\s{2}\d\d \w{3} \d{4} \d\d:\d\d ", l):
            rows.append(l.strip())
    return rows


def rescue_select(vm, since, needle):
    """Wait for the menu, move to the row that contains `needle`, press Enter. Returns the rows seen."""
    vm.expect(r"Restore the system from a snapshot", 240, since=since)
    time.sleep(1.5)
    fr = frame(vm, since)
    rows = menu_rows(fr)
    idx = next((i for i, r in enumerate(rows) if needle in r), None)
    if idx is None:
        raise RuntimeError(f"no row with {needle!r} in {rows}")
    vm.send("\x1b[B" * idx + "\r")
    return rows


def confirm_restore(vm, since, answer="yes"):
    m = vm.expect(r"Type yes to restore this snapshot|REFUSED", 600, since=since)
    plan = strip(vm.text_since(since))
    if "REFUSED" in m.group(0):
        return "refused", plan
    time.sleep(0.5)
    vm.send(answer + "\r")
    return "asked", plan


def wait_done(vm, since, timeout=2400):
    m = vm.expect(r"Press Enter to reboot|REFUSED|The restore stopped|could not be restored|safety snapshot failed", timeout, since=since)
    return m.group(0)


def ssh_ok(vm, cmd, root=True):
    rc, out = vm.ssh(cmd, check=False, root=root)
    return rc == 0, out.strip()


def snapshot_checks(vm, res, protected_new=True, ollama=True, boot=True):
    """What every successful restore must show on the normal system afterwards."""
    ok, _ = ssh_ok(vm, "ldd --version >/dev/null && test -e /usr/lib/modules/$(uname -r)/kernel && pacman -Q glibc >/dev/null")
    res.check("system_boots_and_has_glibc", ok)
    if protected_new:
        ok0, _ = ssh_ok(vm, "test -f /etc/lares/after-only && test -f /usr/local/lib/lares/snapshot/after-only")
        res.check("protected_dirs_keep_files_the_snapshot_lacks", ok0)
        bad = [p for p in PROTECTED if not ssh_ok(vm, f"grep -q v2 {p}")[0]]
        res.check("protected_files_kept", not bad, str(bad))
    if ollama:
        ok1, _ = ssh_ok(vm, "test $(stat -c %s /var/lib/ollama/models/huge.gguf) = 30000000 && test -f /var/lib/ollama/models/new-after-snapshot")
        res.check("excluded_ollama_untouched", ok1)
    if boot:
        ok2, out = ssh_ok(vm, "cd /boot && sha256sum lares/* grub/grub.cfg 2>&1 | sort > /tmp/b1; diff <(sed 's/ .*boot\\// /' /m0-boot-lares.txt | sort) <(sed 's/ / /' /tmp/b1 | sort) >/dev/null; "
                              "test ! -e /boot/.initramfs-linux.img.lares-new; ls /boot/EFI/BOOT/BOOTX64.EFI /boot/grub/grub.cfg /boot/lares/rescue.img >/dev/null")
        res.check("boot_other_files_present", ok2, out)
        ok3, out3 = ssh_ok(vm, "cd /boot && for f in lares/rescue.img lares/rescue-vmlinuz; do grep \" $f\\$\" /m0-boot-lares.txt; done | sha256sum -c --quiet")
        res.check("boot_rescue_untouched", ok3, out3)
        ok4, out4 = ssh_ok(vm, "cd /boot && sha256sum -c --quiet /m0-boot-main.txt")
        res.check("boot_files_restored", ok4, out4)
    # the manifest of the good state against now (the protected files differ on purpose, their lines are cut out)
    ok5, out5 = ssh_ok(vm, "/vmtools/manifest.sh /m1.txt >/dev/null; cut_p() { grep -v -P '^(/usr|/etc|/etc/lares|/etc/pacman\\.d/hooks|/etc/polkit-1/rules\\.d|/usr/share/polkit-1/actions|/usr/local/lib/lares(/snapshot)?)\\t' \"$1\" | grep -v -F -e /etc/.updated -e /usr/local/lib/lares/snapshot -e /etc/pacman.d/hooks/ -e /etc/lares/ -e polkit -e /etc/crypttab -e /usr/lib/modules/ -e /usr/lib/initcpio -e /etc/grub.d -e /etc/mkinitcpio -e /var/lib/pacman/local -e /etc/pacman.d/gnupg -e /usr/share/polkit-1; }; "
                         "diff <(cut_p /m0.txt) <(cut_p /m1.txt) | head -40; diff -q <(cut_p /m0.txt) <(cut_p /m1.txt) >/dev/null")
    res.check("manifest_identical", ok5, out5[:1500])


def finish_restore_and_reboot(vm, since, res):
    m = wait_done(vm, since)
    done = "Press Enter to reboot" in m
    res.check("restore_completes", done, m)
    if not done:
        return False
    txt = strip(vm.text_since(since))
    w = re.search(r"RESCUE-DONE written=(\d+)", txt)
    t = re.search(r"in (\d+) s; ([\d.]+ \w+) written", txt)
    sm = re.search(r"is saved \(it is in the list now\) in (\d+) s", txt)
    STATS[res.name] = {"safety_seconds": int(sm.group(1)) if sm else None, "written_bytes": int(w.group(1)) if w else None, "restore_seconds": int(t.group(1)) if t else None}
    res.check("restored_message", re.search(r"Restored \d\d \w{3} \d{4}", txt) is not None)
    vm.send("\r")
    return True


# ----------------------------------------------------------------------------------------------------------------- preparing
def prepare(rescue_dir, force=False):
    stamp = PREPARED + ".stamp"
    want = tree_hash(rescue_dir) + tree_hash(GUEST) + hashlib.sha256(open(DEFAULTS, "rb").read()).hexdigest()[:8]
    if not force and os.path.exists(PREPARED) and os.path.exists(stamp) and open(stamp).read() == want:
        return
    L.log("preparing the test image (rescue installed, fixtures planted, the base snapshot taken) ...")
    disk = L.new_overlay(os.path.join(L.DISKS, "base.qcow2"), "prep")
    vm = boot("prep", disk)
    try:
        vm.ssh("mkdir -p /usr/local/lib/lares/snapshot")
        vm.put(DEFAULTS, "/usr/local/lib/lares/snapshot/defaults.json")  # the root tool's file: the image carries it
        vm.put_dir(rescue_dir, "/root/rescue-src")
        vm.put_dir(GUEST, "/vmtools")
        vm.ssh("chmod +x /vmtools/*; bash /root/rescue-src/install-rescue.sh 2>&1 | tail -5; rm -rf /root/rescue-src")
        serialize_entry(vm)
        vm.ssh("/vmtools/plant.sh")
        # the rescue entry is in grub.cfg, the fixtures are planted: now the good state
        ok, out = ssh_ok(vm, "grep -c \"menuentry 'Lares rescue'\" /boot/grub/grub.cfg")
        L.log("rescue entries in grub.cfg:", out)
        vm.ssh("sync")
        _, out = vm.ssh("python3 /vmtools/mksnap.py --reason update --title 'Rescue test base'", timeout=1800)
        L.log(out.strip())
        vm.ssh("/vmtools/manifest.sh /m0.txt")
        vm.ssh("cd /boot && sha256sum lares/* grub/grub.cfg > /m0-boot-lares.txt; sha256sum *.img vmlinuz-* > /m0-boot-main.txt; "
               "blkid -s UUID -o value $(blkid -t TYPE=swap -o device) > /m0-swap.txt; blkid -s LABEL -o value $(blkid -t TYPE=swap -o device) >> /m0-swap.txt || true; "
               "ls -la /.lares-snapshots > /dev/null; du -sh /.lares-snapshots/repo | tee /m0-repo-size.txt; ls -la /boot/lares")
        vm.ssh("sync; systemctl poweroff", check=False)
        vm.poweroff_wait(90)
    finally:
        vm.kill()
    os.replace(disk, PREPARED)
    open(stamp, "w").write(want)


def overlay(name):
    return L.new_overlay(PREPARED, name)


def change_after_snapshot(vm):
    """The state the restore must NOT take back: protected files edited after the snapshot, a new file in an excluded tree."""
    for p in PROTECTED:
        vm.ssh(f"sed -i s/v1/v2/ {p}")
    # files the snapshot does not hold at all, under protected directories: they stay
    vm.ssh("echo kept > /var/lib/ollama/models/new-after-snapshot; echo x > /etc/lares/after-only; echo x > /usr/local/lib/lares/snapshot/after-only; sync")


# ----------------------------------------------------------------------------------------------------------------- the tests
BREAK_A = r"""
rm -rf /usr/lib/modules /usr/lib/initcpio /boot/initramfs-linux.img /boot/initramfs-linux-lts.img
python3 - <<'PY'
import os, subprocess
files = subprocess.run(["pacman", "-Ql", "glibc"], capture_output=True, text=True).stdout.split("\n")
for l in files:
    if l and not l.endswith("/"):
        try: os.unlink(l.split(" ", 1)[1])
        except OSError: pass
os.sync()
open("/proc/sys/kernel/sysrq", "w").write("1"); open("/proc/sysrq-trigger", "w").write("b")
PY
"""


def run_break_and_reboot(vm, script, bg=True):
    vm.ssh("grub-reboot lares-rescue; sync")
    since = vm.mark()
    vm.ssh("nohup bash -c %s >/dev/null 2>&1 &" % __import__("shlex").quote(script), check=False)
    return since


def t_a(rdir, name="a", expect_fail=None):
    res = Results(name)
    vm = boot(name, overlay(name))
    try:
        change_after_snapshot(vm)
        # wrong bytes with the same size and mtime (a restore that skips "unchanged" files would never repair it; the hardlink shares the inode)
        vm.ssh("printf 'HELLX\\n' | dd of=/usr/local/share/lares-test/plain conv=notrunc 2>/dev/null; touch -d '2020-02-02 02:02:02' /usr/local/share/lares-test/plain; sync")
        since = run_break_and_reboot(vm, BREAK_A)
        rows = rescue_select(vm, since, "Rescue test base")
        res.check("list_shows_snapshot", len(rows) >= 1, str(rows))
        kind, plan = confirm_restore(vm, since)
        res.check("dry_run_summary", "files to write" in plan and "files to delete" in plan)
        if kind != "asked":
            res.check("restore_completes", False, "refused")
        if kind == "asked" and finish_restore_and_reboot(vm, since, res):
            try:
                vm.wait_ssh(120)
            except Exception as e:   # a /boot that lost GRUB does not boot: the boot checks fail
                res.check("boot_other_files_present", False, "the machine did not boot: %s" % e)
                return res
            snapshot_checks(vm, res)
            ok, out = ssh_ok(vm, "tail -n1 /.lares-snapshots/index.tsv | head -c 0; head -n1 /.lares-snapshots/index.tsv; ls /.lares-snapshots/records | wc -l")
            res.check("safety_snapshot_in_index", "\trescue\t" in out, out)
    finally:
        vm.kill()
    return res


def t_b(rdir, name="b"):
    res = Results(name)
    vm = boot(name, overlay(name))
    try:
        change_after_snapshot(vm)
        vm.ssh("grub-reboot lares-rescue; sync")
        vm.ssh("sed -i 's|^Server.*|Server = https://archive.archlinux.org/repos/2026/11/21/$repo/os/$arch|' /etc/pacman.d/mirrorlist; "
               "nohup pacman -Syu --noconfirm --disable-download-timeout > /var/log/b-update.log 2>&1 &")
        n, t0 = 0, time.time()
        while time.time() - t0 < 900:
            _, out = vm.ssh("grep -c '\\[ALPM\\] upgraded' /var/log/pacman.log", check=False)
            try:
                n = int(out.strip().splitlines()[-1])
            except (ValueError, IndexError):
                n = 0
            if n >= 25:
                break
            time.sleep(0.5)
        res.check("update_half_done", 25 <= n, f"upgraded so far: {n}")
        since = vm.mark()
        vm.kill()  # the power cut in the middle of `pacman -Syu`
        vm.start()
        rescue_select(vm, since, "Rescue test base")
        kind, plan = confirm_restore(vm, since)
        if kind != "asked":
            res.check("restore_completes", False, "refused")
        if kind == "asked" and finish_restore_and_reboot(vm, since, res):
            vm.wait_ssh(400)
            snapshot_checks(vm, res)
            ok, out = ssh_ok(vm, "test ! -e /var/lib/pacman/db.lck && pacman -Q linux linux-lts glibc systemd | head -4 && pacman -Qk glibc systemd linux linux-lts coreutils bash 2>&1 | grep -v ' 0 missing' | head -3; true")
            res.check("pacman_db_back_to_snapshot", ok and "missing" not in out.replace("0 missing", ""), out)
    finally:
        vm.kill()
    return res


def t_c(rdir, name="c"):
    res = Results(name)
    vm = boot(name, overlay(name))
    try:
        change_after_snapshot(vm)
        vm.ssh("python3 /vmtools/mksnap.py --reason prime --title prime")  # a warm-up snapshot: no restore point
        vm.ssh("rm -rf /.lares-snapshots/index.tsv /.lares-snapshots/records")
        script = "rm -rf /usr/lib/modules; rm -f /boot/initramfs-linux-lts.img; sync; echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger"
        since = run_break_and_reboot(vm, script)
        rows = rescue_select(vm, since, "no index")
        res.check("fallback_list_hides_prime", len(rows) == 1, str(rows))
        kind, plan = confirm_restore(vm, since)
        res.check("record_read_from_snapshot", "the snapshot's record" in strip(vm.text_since(since)))
        if kind != "asked":
            res.check("restore_completes", False, "refused")
        if kind == "asked" and finish_restore_and_reboot(vm, since, res):
            vm.wait_ssh(400)
            snapshot_checks(vm, res)
    finally:
        vm.kill()
    return res


def t_hib(rdir, name="hib"):
    res = Results(name)
    vm = boot(name, overlay(name))
    try:
        change_after_snapshot(vm)
        _, sw = vm.ssh("blkid -t TYPE=swap -o device")
        sw = sw.strip()
        _, before = vm.ssh(f"blkid -s UUID -o value {sw}")
        vm.ssh(f"swapoff -a; printf S1SUSPEND | dd of={sw} bs=1 seek=4086 conv=notrunc 2>/dev/null; sync; rm -f /etc/lares-test/plain /opt/lares-test/plain")
        script = "sync; echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger"
        since = run_break_and_reboot(vm, script)
        rescue_select(vm, since, "Rescue test base")
        try:
            vm.expect(r"Type discard", 120, since=since)   # the refusal screen (the menu itself only names the image)
            res.check("hibernation_refused", True)
        except TimeoutError:
            res.check("hibernation_refused", False, "no refusal: the restore went on under the hibernation image")
            return res
        time.sleep(1)
        s2 = vm.mark()
        vm.send("\r")  # back to the menu: nothing written
        rescue_select(vm, s2, "Rescue test base")
        vm.expect(r"Type discard", 60, since=s2)
        vm.send("discard\r")
        kind, plan = confirm_restore(vm, s2)
        if kind != "asked":
            res.check("restore_completes", False, "refused")
        if kind == "asked" and finish_restore_and_reboot(vm, s2, res):
            vm.wait_ssh(400)
            snapshot_checks(vm, res)
            _, after = vm.ssh(f"blkid -s UUID -o value {sw}; blkid -s TYPE -o value {sw}")
            res.check("swap_made_again_same_uuid", before.strip() in after and "swap" in after, after)
            ok, _ = ssh_ok(vm, "test -f /etc/lares-test/plain && test -f /opt/lares-test/plain")
            res.check("files_back_after_discard", ok)
    finally:
        vm.kill()
    return res


def t_cut(rdir, name="cut"):
    res = Results(name)
    # writes at 25 MB/s (the laptop's SSD does ~30 once its cache is full): the restore takes long enough to be cut
    vm = boot(name, overlay(name), drive_opts=",throttling.bps-write=25000000")
    try:
        change_after_snapshot(vm)
        script = "rm -rf /usr/share/man /usr/share/doc /usr/share/locale /usr/lib/modules /usr/lib/python3* /usr/lib/gcc /usr/lib/systemd/boot; rm -f /boot/initramfs-linux.img /boot/initramfs-linux-lts.img; sync; echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger"
        vm.ssh("sync")
        since = vm.mark()
        vm.ssh("nohup bash -c %s >/dev/null 2>&1 &" % __import__("shlex").quote(script), check=False)
        grub_choose(vm, since)  # the real way: the menu, Down until the last entry, Enter
        rescue_select(vm, since, "Rescue test base")
        kind, plan = confirm_restore(vm, since)
        # the cut: as soon as the trees are being written
        vm.expect(r"/usr \(1/\d\)\s+[3-6]\d%", 300, since=since)
        res.check("cut_in_the_middle", "Press Enter to reboot" not in strip(vm.text_since(since)))
        vm.kill()
        since = vm.mark()
        vm.drive_opts = ""
        vm.start()
        grub_choose(vm, since)
        res.check("rescue_entry_usable_after_cut", True)
        rows = rescue_select(vm, since, "Rescue test base")
        res.check("safety_snapshot_survived", any("rescue" in r for r in rows), str(rows))
        kind, plan = confirm_restore(vm, since)
        if kind != "asked":
            res.check("restore_completes", False, "refused")
        if kind == "asked" and finish_restore_and_reboot(vm, since, res):
            vm.wait_ssh(400)
            snapshot_checks(vm, res)
    finally:
        vm.kill()
    return res


def t_resc(rdir, name="resc"):
    """A restore FROM a rescue snapshot (taken by the rescue itself): its record carries the lists, the ollama decoy survives."""
    res = Results(name)
    vm = boot(name, overlay(name))
    try:
        change_after_snapshot(vm)
        since = run_break_and_reboot(vm, "rm -rf /usr/share/man /usr/share/doc /etc/lares-test; sync; echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger")
        rescue_select(vm, since, "Rescue test base")
        kind, plan = confirm_restore(vm, since)
        if not (kind == "asked" and finish_restore_and_reboot(vm, since, res)):
            return res
        vm.wait_ssh(400)
        _, rec = vm.ssh("cat /.lares-snapshots/records/*.json | python3 -c \"import sys,json;[print(json.dumps(r['excludes']), r['reason'], len(r['paths'])) for r in map(json.loads, sys.stdin.read().replace('}{','}\\n{').splitlines()) if r['reason']=='rescue']\"", check=False)
        res.check("rescue_record_has_excludes_and_paths", "/var/lib/ollama" in rec and "rescue" in rec and rec.split()[-1] != "0", rec)
        # the second break: new decoy data in an excluded tree, then a restore from the RESCUE snapshot
        vm.ssh("echo again > /var/lib/ollama/models/second-decoy; sync")
        since = run_break_and_reboot(vm, "rm -rf /usr/share/locale; sync; echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger")
        rows = rescue_select(vm, since, "Before the restore of")
        res.check("rescue_snapshot_in_list", len(rows) >= 2, str(rows))
        kind, plan = confirm_restore(vm, since)
        if kind != "asked":
            res.check("restore_completes", False, "refused")
        if kind == "asked" and finish_restore_and_reboot(vm, since, res):
            vm.wait_ssh(400)
            ok, out = ssh_ok(vm, "test $(stat -c %s /var/lib/ollama/models/huge.gguf) = 30000000 && test -f /var/lib/ollama/models/second-decoy && test -f /var/lib/ollama/models/new-after-snapshot")
            res.check("decoy_survives_rescue_snapshot", ok, out)
            ok, _ = ssh_ok(vm, "ldd --version >/dev/null && test ! -d /usr/share/man && test -d /usr/lib/modules/$(uname -r) && test ! -d /usr/share/locale || test -d /usr/share/locale")
            res.check("system_boots_after_second_restore", ok)
    finally:
        vm.kill()
    return res



SHOTS = os.path.join(L.VM_ROOT, "shots")


def part_hash(disk):
    """sha256 of the root partition (p3) of a qcow2, as the guest sees it: the disk converted to a sparse raw copy and read at the partition's place."""
    raw = disk + ".raw"
    L.qemu_img("convert", "-f", "qcow2", "-O", "raw", "-S", "4096", disk, raw)
    # sectors of /dev/vda3, as the base image was laid out (sfdisk: ESP 512M, swap 1G, root the rest, first LBA 2048)
    start, size = (2048 + (512 + 1024) * 2048) * 512, None
    h = hashlib.sha256()
    with open(raw, "rb") as f:
        f.seek(start)
        while True:
            b = f.read(8 << 20)
            if not b:
                break
            h.update(b)
    os.unlink(raw)
    return h.hexdigest()


def t_hibdisk(rdir, name="hibdisk"):
    """With a hibernation image present, looking at the list and choosing Reboot writes NOTHING to the root partition (not even a journal replay)."""
    res = Results(name)
    disk = overlay(name)
    vm = boot(name, disk)
    try:
        _, sw = vm.ssh("blkid -t TYPE=swap -o device")
        vm.ssh(f"swapoff -a; printf S1SUSPEND | dd of={sw.strip()} bs=1 seek=4086 conv=notrunc 2>/dev/null; grub-reboot lares-rescue; sync")
        # a dirty journal: metadata committed to the journal, then a hard reset before it is checkpointed
        vm.ssh("for i in 1 2 3 4 5 6 7 8; do echo $i > /etc/lares-test/dirty$i; done; echo 1 > /proc/sys/kernel/sysrq; (sleep 1; echo b > /proc/sysrq-trigger) >/dev/null 2>&1 &", check=False)
        since = vm.mark()
        vm.expect(r"The highlighted entry will be executed automatically", 120, since=since)
        vm.kill()                                   # at the menu, before the rescue ran: the disk as it is
        h0 = part_hash(disk)
        since = vm.mark()
        vm.start()
        grub_choose(vm, since)   # GRUB spent the one-shot entry before the menu: choose by the keys
        vm.expect(r"Restore the system from a snapshot", 240, since=since)
        time.sleep(2)
        fr = frame(vm, since)
        res.check("menu_says_hibernation_image", "hibernation image is stored on" in fr, fr[-300:])
        rows = menu_rows(fr)
        vm.send("\x1b[B" * (len(rows) + 0) + "\r")  # Reboot
        vm.expect(r"The highlighted entry will be executed automatically", 120, since=since)
        vm.kill()
        h1 = part_hash(disk)
        res.check("root_partition_untouched_by_list_and_reboot", h0 == h1, f"{h0[:12]} != {h1[:12]}")
    finally:
        vm.kill()
        for f in (disk + ".raw",):
            if os.path.exists(f):
                os.unlink(f)
    return res


def set_boot_uuid(vm, how):
    """The test machine's copy of the entry names another lares.boot: the root's own UUID (no separate /boot) or the swap's (cannot be mounted)."""
    u = {"same": "blkid -s UUID -o value $(findmnt -no SOURCE /)", "bad": "blkid -s UUID -o value $(blkid -t TYPE=swap -o device)"}[how]
    vm.ssh(f"U=$({u}); sed -i \"/menuentry 'Lares rescue'/,/^}}/ s|lares.boot=UUID=[^ ]*|lares.boot=UUID=$U|\" /boot/grub/grub.cfg; grep -c \"lares.boot=UUID=$U\" /boot/grub/grub.cfg")


def t_sameboot(rdir, name="sameboot"):
    """/boot on the root file system: the files go to the root's own /boot directory and the ESP is not touched."""
    res = Results(name)
    vm = boot(name, overlay(name))
    try:
        change_after_snapshot(vm)
        set_boot_uuid(vm, "same")
        since = run_break_and_reboot(vm, "rm -rf /usr/lib/modules; sync; echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger")
        rescue_select(vm, since, "Rescue test base")
        kind, plan = confirm_restore(vm, since)
        if kind != "asked":
            res.check("restore_completes", False, "refused")
        if kind == "asked" and finish_restore_and_reboot(vm, since, res):
            vm.wait_ssh(400)
            ok, out = ssh_ok(vm, "mkdir -p /mnt2 && mount --bind / /mnt2 && ls /mnt2/boot | tr '\\n' ' '; umount /mnt2")
            res.check("files_written_to_the_roots_own_boot_dir", "vmlinuz-linux-lts" in out and "initramfs-linux-lts.img" in out, out)
            ok, out = ssh_ok(vm, "cd /boot && sha256sum -c --quiet /m0-boot-main.txt && ! ls /boot | grep -q lares-new")
            res.check("esp_not_touched", ok, out)
    finally:
        vm.kill()
    return res


def t_badesp(rdir, name="badesp"):
    """A boot partition that cannot be mounted: the restore refuses before it writes anything."""
    res = Results(name)
    vm = boot(name, overlay(name))
    try:
        set_boot_uuid(vm, "bad")
        since = run_break_and_reboot(vm, "rm -f /etc/lares-test/plain; sync; echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger")
        rescue_select(vm, since, "Rescue test base")
        m = vm.expect(r"REFUSED: the boot partition .* could not be mounted|Type yes to restore", 300, since=since)
        res.check("refused_before_writing", "REFUSED" in m.group(0), m.group(0))
        vm.expect(r"Press Enter to continue", 30, since=since)
        vm.send("\r")
        time.sleep(1)
        fr = frame(vm, since)
        vm.send("\x1b[B" * (len(menu_rows(fr))) + "\r")   # Reboot: nothing was written
        vm.wait_ssh(400)
        ok, _ = ssh_ok(vm, "test ! -e /etc/lares-test/plain")
        res.check("nothing_restored", ok)
    finally:
        vm.kill()
    return res


def t_lock(rdir, name="lock"):
    """The machine died while a repair held an exclusive repository lock: the rescue restores and takes its safety snapshot anyway."""
    res = Results(name)
    vm = boot(name, overlay(name))
    try:
        change_after_snapshot(vm)
        # an exclusive lock the way a dying `repair index` leaves it: slowed down (a spinner on its CPU) until its lock is complete, then stopped
        vm.ssh("export RESTIC_PASSWORD_FILE=/.lares-snapshots/key; taskset -c 0 yes >/dev/null & Y=$!; "
               "taskset -c 0 nice -n 19 restic -r /.lares-snapshots/repo --no-cache repair index --read-all-packs >/dev/null 2>&1 & P=$!; "
               "while [ -z \"$(ls /.lares-snapshots/repo/locks 2>/dev/null | grep -v tmp)\" ]; do :; done; kill -STOP $P; kill $Y")
        _, n = vm.ssh("ls /.lares-snapshots/repo/locks | wc -l")
        res.check("exclusive_lock_planted", int(n.strip() or 0) >= 1, n)
        since = run_break_and_reboot(vm, BREAK_A)
        rescue_select(vm, since, "Rescue test base")
        kind, plan = confirm_restore(vm, since)
        if kind != "asked":
            res.check("restore_completes", False, "refused")
        if kind == "asked" and finish_restore_and_reboot(vm, since, res):
            vm.wait_ssh(400)
            snapshot_checks(vm, res)
            ok, out = ssh_ok(vm, "head -n1 /.lares-snapshots/index.tsv")
            res.check("safety_snapshot_taken_despite_lock", "\trescue\t" in out, out)
    finally:
        vm.kill()
    return res


def t_screen(rdir, name="screen", size=None):
    """The INSTALLED entry (no serial at all): the menu, the plan and the finished restore on the framebuffer, as PNGs driven by sendkey."""
    res = Results(name)
    os.makedirs(SHOTS, exist_ok=True)
    tag = size or "default"
    vm = L.VM(name, overlay(name), ssh_port=SSH_PORT, vga_dev=("virtio-vga,edid=on,xres=%s,yres=%s" % tuple(size.split("x"))) if size else None)
    vm.start(); vm.wait_ssh(300)
    def shot(label):
        ppm = os.path.join(vm.dir, "shot.ppm")
        if os.path.exists(ppm):
            os.unlink(ppm)
        vm.monitor("screendump " + ppm)
        time.sleep(1)
        from PIL import Image
        im = Image.open(ppm)
        out = os.path.join(SHOTS, f"{tag}-{label}.png")
        im.save(out)
        return out, im.size, im
    def keys(*k):
        for x in k:
            vm.monitor("sendkey " + x); time.sleep(0.4)
    try:
        change_after_snapshot(vm)
        # the entry exactly as grub-mkconfig makes it: no serial words at all
        vm.ssh("grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1; grub-reboot lares-rescue")
        _, cfg = vm.ssh("grep -c 'ttyS0' /boot/grub/grub.cfg | head -c 2; sed -n \"/menuentry 'Lares rescue'/,/^}/p\" /boot/grub/grub.cfg | grep -c ttyS0", check=False)
        res.check("installed_entry_has_no_serial", cfg.strip().endswith("0"), cfg)
        vm.ssh("rm -rf /usr/lib/modules; sync; echo 1 > /proc/sys/kernel/sysrq; (sleep 1; echo b > /proc/sysrq-trigger) >/dev/null 2>&1 &", check=False)
        time.sleep(45)
        p, sz, im = shot("1-menu")
        res.check("menu_drawn_on_the_screen", im.getbbox() is not None and sz[0] > 0, str(sz))
        keys("ret")
        time.sleep(25)
        shot("2-plan")
        keys("y", "e", "s", "ret")
        time.sleep(60)
        shot("3-done")
        keys("ret")
        vm.wait_ssh(400)
        ok, _ = ssh_ok(vm, "test -d /usr/lib/modules/$(uname -r)")
        res.check("restore_finished_on_the_screen_driven_keys", ok)
        res.check("screens_saved", True, "")
        print("  SHOTS", SHOTS, tag, sz)
    finally:
        vm.kill()
    return res


TESTS = {"hibdisk": t_hibdisk, "sameboot": t_sameboot, "badesp": t_badesp, "lock": t_lock, "screen": t_screen, "resc": t_resc, "a": t_a, "b": t_b, "c": t_c, "hib": t_hib, "cut": t_cut}

# ARMs: a patched COPY of the rescue; the named check of the named test must fail with it.
ARMS = {
    "noexclude": ("a", "restore_completes",
                  [("rescue.sh", "case $p in \"$pre\"*) printf", "case $p in \"$pre\"*) [ \"$p\" = /etc/lares ] && continue; printf")]),
    "noprotect": ("a", "protected_files_kept", [("rescue.sh", "grep '^/' $LDIR/protect.list > $T/prot", ": > $T/prot")]),
    "bootdelete": ("a", "boot_other_files_present",
                   [("rescue.sh", "if ! do_boot \"$id\"; then", "RESTIC restore \"$id:/boot\" --target $ESP --delete --overwrite if-changed >/dev/null 2>&1; if ! true; then")]),
    "recordonly": ("resc", "decoy_survives_rescue_snapshot",
                   [("rescue.sh", "cat $T/excl.rec $T/excl.def | sort -u > $T/excl", "cp $T/excl.rec $T/excl"),
                    ("rescue.sh", "JEXC=$(jarr $T/excl)", "JEXC=")]),
    "hibfirst": ("hibdisk", "root_partition_untouched_by_list_and_reboot",
                 [("rescue.sh", "if [ -n \"$HIB\" ]; then   # ARM:hibfirst", "if false; then")]),
    "nounlock": ("lock", "restore_completes", [("rescue.sh", "    RESTIC unlock --remove-all >/dev/null 2>&1\n", "")]),
    "ifchanged": ("a", "manifest_identical", [("rescue.sh", "--overwrite always --sparse", "--overwrite if-changed --sparse")]),
    "nohib": ("hib", "hibernation_refused", [("rescue.sh", "    hib_check || return\n", "")]),
}


def make_arm_copy(arm):
    test, check, edits = ARMS[arm]
    d = os.path.join(L.WORK, "arm-" + arm)
    if os.path.exists(d):
        shutil.rmtree(d)
    shutil.copytree(RESCUE_SRC, d)
    for fname, old, new in edits:
        p = os.path.join(d, fname)
        s = open(p).read()
        if old not in s:
            raise RuntimeError(f"ARM {arm}: anchor not found: {old!r}")
        open(p, "w").write(s.replace(old, new, 1))
    return d, test, check


def run_arm(arm):
    d, test, check = make_arm_copy(arm)
    # the arm's image: the normal prepared disk, then the patched rescue is installed and built inside the overlay
    L.log(f"ARM {arm}: the {test} test with a patched rescue; check {check} must fail")
    base_fn = TESTS[test]

    def armed(rdir, name):
        # patch inside the overlay: run the test's own boot, but first swap the rescue in
        orig_boot = globals()["boot"]

        def boot2(n, disk, fresh=True):
            vm = orig_boot(n, disk)
            vm.put_dir(d, "/root/rescue-src")
            vm.ssh("bash /root/rescue-src/install-rescue.sh 2>&1 | tail -3; rm -rf /root/rescue-src; sync")
            serialize_entry(vm)
            return vm
        globals()["boot"] = boot2
        try:
            return base_fn(rdir, name)
        finally:
            globals()["boot"] = orig_boot
    res = armed(d, "arm-" + arm)
    return res, check


# ----------------------------------------------------------------------------------------------------------------- main
def main():
    import signal
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(143))  # atexit then kills the guest this run started
    args = sys.argv[1:]
    rdir = RESCUE_SRC
    tests = ["a", "b", "c", "hib", "cut", "resc", "hibdisk", "sameboot", "badesp", "lock"]
    arms = []
    keep = "--keep" in args
    if "--rescue" in args:
        rdir = args[args.index("--rescue") + 1]
    if "--tests" in args:
        tests = args[args.index("--tests") + 1].split(",")
    if "--arm" in args:
        arms = args[args.index("--arm") + 1].split(",")
        tests = []
    subprocess.run([sys.executable, os.path.join(HERE, "build_base.py")], check=True)
    prepare(rdir)
    verdict, lines = True, []
    for t in tests:
        try:
            res = TESTS[t](rdir, t)
            bad = res.failed()
        except Exception as e:  # a crashed test is a failed test with its reason
            res, bad = Results(t), [f"exception: {e}"]
            print(f"  EXCEPTION {e}", flush=True)
        ok = not bad
        verdict &= ok
        print(f"SNAPSHOT_VM {t} RESULT {'PASS' if ok else 'FAIL'} ({int(time.time() - res.t0)} s){'' if ok else ' failed: ' + ', '.join(bad)}", flush=True)
        if not keep:
            for f in os.listdir(L.DISKS):
                if f.startswith("overlay-"):
                    os.unlink(os.path.join(L.DISKS, f))
    for a in arms:
        try:
            res, check = run_arm(a)
            bad = res.failed()
            ok = check in bad or any(b.startswith("exception") for b in bad) and False
        except Exception as e:
            print(f"  EXCEPTION {e}", flush=True)
            bad, check, ok = [f"exception: {e}"], "?", False
        verdict &= ok
        print(f"SNAPSHOT_VM arm {a} RESULT {'PASS' if ok else 'FAIL'} (its check {check} {'failed as it must' if ok else 'did NOT fail; failed: ' + ', '.join(bad)})", flush=True)
        for f in os.listdir(L.DISKS):
            if f.startswith("overlay-") and not keep:
                os.unlink(os.path.join(L.DISKS, f))
    print("STATS", json.dumps(STATS))
    print(f"SNAPSHOT_VM RESULT {'PASS' if verdict else 'FAIL'}")
    return 0 if verdict else 1


if __name__ == "__main__":
    sys.exit(main())
