#!/usr/bin/env bash
# What tools/dev/snapshot_vm.sh needs, fetched into its work folder; nothing is installed and nothing needs root. What is there already stays.
#   tools/dev/snapshot_vm/prepare.sh
# QEMU and its libraries as Arch packages (each checked against the local sync database's SHA-256, unpacked, never installed), the Arch image
# the guest is made from (the 2026-11-01 one, checked against the sum below) and restic. About 1.6 GB; the guest's base disk is built by the
# first run (`snapshot_vm.sh --build-base`), about 3 GB more.
set -eu
ROOT=${SNAPSHOT_WORK:-$HOME/.cache/claude-orch/snapshots}
VM=$ROOT/vm
ISO_DATE=2026.11.01
ISO_SUM=01bcdcf01af2f7d58f2794899c834770d25c9bfc945bd092b32bb66672a4a216
PKGS="qemu-system-x86 qemu-common qemu-system-x86-firmware qemu-img seabios edk2-ovmf capstone libaio libslirp libxdp ndctl rdma-core vde2 dtc"
mkdir -p "$VM/qemu/dl" "$VM/qemu/root" "$VM/iso" "$ROOT/bin" "$ROOT/pkgs"
server=$(grep -m1 '^Server' /etc/pacman.d/mirrorlist | sed 's/^Server *= *//')

fetch() {   # fetch <download dir> <unpack dir> <package>
    local repo entry desc file sum url
    for repo in core extra; do
        entry=$(bsdtar -tf "/var/lib/pacman/sync/$repo.db" | grep -E "^$3-[^-]+-[^-]+/desc$" | head -1) || true
        [ -n "$entry" ] || continue
        desc=$(bsdtar -xOf "/var/lib/pacman/sync/$repo.db" "$entry")
        file=$(printf '%s\n' "$desc" | awk '/%FILENAME%/{getline;print}')
        sum=$(printf '%s\n' "$desc" | awk '/%SHA256SUM%/{getline;print}')
        url=$(printf '%s' "$server" | sed "s/\$repo/$repo/; s/\$arch/x86_64/")/$file
        [ -f "$1/$file" ] || curl -sfL --max-time 600 -o "$1/$file" "$url"
        [ "$(sha256sum "$1/$file" | cut -d' ' -f1)" = "$sum" ] || { echo "the sum of $file is wrong" >&2; exit 1; }
        bsdtar -xf "$1/$file" -C "$2" --exclude '.*'
        echo "ok $file"
        return 0
    done
    echo "no package $3 in core or extra (is the sync database fresh?)" >&2
    exit 1
}

if [ -x "$VM/qemu/root/usr/bin/qemu-system-x86_64" ]; then echo "qemu: there"; else for p in $PKGS; do fetch "$VM/qemu/dl" "$VM/qemu/root" "$p"; done; fi
if [ -f "$VM/iso/arch.iso" ] && [ "$(sha256sum "$VM/iso/arch.iso" | cut -d' ' -f1)" = "$ISO_SUM" ]; then
    echo "image: there"
else
    curl -fL --max-time 1800 -o "$VM/iso/arch.iso" "https://archive.archlinux.org/iso/$ISO_DATE/archlinux-$ISO_DATE-x86_64.iso"
    [ "$(sha256sum "$VM/iso/arch.iso" | cut -d' ' -f1)" = "$ISO_SUM" ] || { echo "the sum of the image is wrong" >&2; exit 1; }
fi
if [ -x "$ROOT/bin/restic" ]; then
    echo "restic: there"
else
    mkdir -p "$ROOT/pkgs/restic/x"
    fetch "$ROOT/pkgs/restic" "$ROOT/pkgs/restic/x" restic
    ln -sfn ../pkgs/restic/x/usr/bin/restic "$ROOT/bin/restic"
fi
echo "ready: $ROOT"
