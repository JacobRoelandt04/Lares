#!/usr/bin/env python3
"""Builds the cached base image of the rescue's VM tests: an Arch install laid out like the laptop (GPT: FAT ESP at /boot, swap, ext4 root,
GRUB with --removable), from the Arch archive of 2026/10/20, with a user + ssh key, decoy /home and /var/lib/ollama files, and the packages
of 2026/11/21 already in pacman's cache (break B runs a real `pacman -Syu` offline of the network, from the cache).

    build_base.py [--force]      -> $VM/disks/base.qcow2 (a finished image is never rebuilt without --force)

The installer is the Arch ISO's own kernel on a serial console; nothing is installed on the host.
"""
import os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vmlib as L

BASE = os.path.join(L.DISKS, "base.qcow2")
ARCHIVE_OLD = "https://archive.archlinux.org/repos/2026/10/20"
ARCHIVE_NEW = "https://archive.archlinux.org/repos/2026/11/21"
PACKAGES = "base linux linux-lts grub efibootmgr restic python sudo openssh nano dosfstools e2fsprogs acl attr libcap which diffutils"

SETUP = r"""
set -e
sfdisk /dev/vda <<'EOF'
label: gpt
size=512M, type=U
size=1G, type=S
type=L
EOF
mkfs.fat -F32 /dev/vda1
mkswap /dev/vda2
mkfs.ext4 -q -F /dev/vda3
mount /dev/vda3 /mnt
mkdir -p /mnt/boot
mount /dev/vda1 /mnt/boot
echo 'Server = %(old)s/$repo/os/$arch' > /etc/pacman.d/mirrorlist
sed -i 's/^\[options\]/[options]\nDisableDownloadTimeout/' /etc/pacman.conf
for i in 1 2 3 4 5 6; do pacstrap -K /mnt %(pkgs)s && break; echo retry $i; done
[ -f /mnt/etc/os-release ]
genfstab -U /mnt > /mnt/etc/fstab
"""

CHROOT = r"""
set -e
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo en_US.UTF-8 UTF-8 > /etc/locale.gen; locale-gen >/dev/null
echo LANG=en_US.UTF-8 > /etc/locale.conf
echo lares-vm > /etc/hostname
echo 'root:root' | chpasswd
useradd -m -G wheel vmuser
echo 'vmuser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/vmuser
install -d -m 700 -o vmuser -g vmuser /home/vmuser/.ssh
echo '%(pub)s' > /home/vmuser/.ssh/authorized_keys
chown vmuser:vmuser /home/vmuser/.ssh/authorized_keys; chmod 600 /home/vmuser/.ssh/authorized_keys
cat > /etc/systemd/network/20-wired.network <<'EOF'
[Match]
Name=en*
[Network]
DHCP=yes
EOF
systemctl enable sshd systemd-networkd systemd-resolved
# the laptop's GRUB settings (GRUB_DEFAULT=saved, 1 s timeout) plus a serial console for the harness
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/; s/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
cat >> /etc/default/grub <<'EOF'
GRUB_TIMEOUT_STYLE=menu
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200"
GRUB_DISABLE_OS_PROBER=true
EOF
grub-install --target=x86_64-efi --efi-directory=/boot --removable >/dev/null
grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tail -3
# decoys: a fake /home and a fake ollama store that no snapshot may take or restore
mkdir -p /home/vmuser/Documents /var/lib/ollama/models /var/lib/docker/overlay2
head -c 30000000 /dev/urandom > /var/lib/ollama/models/huge.gguf
head -c 5000000 /dev/urandom > /var/lib/docker/overlay2/layer
echo "my thesis" > /home/vmuser/Documents/thesis.txt
head -c 20000000 /dev/urandom > /home/vmuser/Documents/video.bin
chown -R vmuser:vmuser /home/vmuser
echo "# Server = %(new)s/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist.new
"""

PREFETCH = r"""
set -e
echo 'Server = %(new)s/$repo/os/$arch' > /etc/pacman.d/mirrorlist
for i in 1 2 3 4 5 6; do pacman -Syuw --noconfirm && break; done
# the base itself stays at 2026/10/20: only the cache holds the newer packages
"""


def main():
    force = "--force" in sys.argv
    if os.path.exists(BASE) and not force:
        L.log("base image exists:", BASE)
        return 0
    os.makedirs(L.DISKS, exist_ok=True)
    work = os.path.join(L.DISKS, "base-build.qcow2")
    if os.path.exists(work):
        os.unlink(work)
    L.qemu_img("create", "-f", "qcow2", work, "14G")
    pub = open(L.SSH_KEY + ".pub").read().strip()
    vm = L.VM("build", work, boot_iso=True, graphics=False)
    vm.start()
    try:
        vm.expect(r"archiso login: ", 300)
        vm.send("root\n")
        vm.expect(r"archiso.{0,60}# ", 60)
        vm.send("unsetopt zle\n")
        time.sleep(1)
        vm.sh("systemctl is-system-running --wait || true", timeout=120, check=False)
        L.log("live system up; waiting for the network")
        for _ in range(60):
            if vm.sh("curl -sfI %s/core/os/x86_64/core.db >/dev/null" % ARCHIVE_OLD, check=False, timeout=30)[0] == 0:
                break
            time.sleep(3)
        else:
            raise RuntimeError("no network in the live system")
        vm.put_text("/root/setup.sh", SETUP % dict(old=ARCHIVE_OLD, pkgs=PACKAGES))
        L.log("pacstrap ...")
        vm.sh("bash /root/setup.sh > /root/setup.log 2>&1; r=$?; tail -5 /root/setup.log; (exit $r)", timeout=3000)
        vm.put_text("/mnt/root/chroot.sh", CHROOT % dict(pub=pub, new=ARCHIVE_NEW))
        vm.sh("arch-chroot /mnt bash /root/chroot.sh > /root/chroot.log 2>&1; r=$?; tail -8 /root/chroot.log; (exit $r)", timeout=900)
        vm.put_text("/mnt/root/prefetch.sh", PREFETCH % dict(new=ARCHIVE_NEW))
        vm.sh("ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf")
        L.log("prefetching the 2026/11/21 packages ...")
        vm.sh("cp /etc/pacman.d/mirrorlist /root/ml.keep; arch-chroot /mnt bash /root/prefetch.sh > /root/prefetch.log 2>&1; r=$?; tail -5 /root/prefetch.log; (exit $r)", timeout=3000)
        # put the 10/20 mirrorlist back (the break-B test points it at 11/21 itself) and the sync dbs of 10/20 are refreshed on use
        vm.sh("echo 'Server = %s/$repo/os/$arch' > /mnt/etc/pacman.d/mirrorlist" % ARCHIVE_OLD)
        vm.sh("rm -f /mnt/root/*.sh /mnt/etc/pacman.d/mirrorlist.new; sync; umount -R /mnt")
        vm.send("poweroff\n")
        vm.poweroff_wait(90)
    finally:
        vm.kill()
    os.replace(work, BASE)
    L.log("base image ready:", BASE, os.path.getsize(BASE) // 2**20, "MiB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
