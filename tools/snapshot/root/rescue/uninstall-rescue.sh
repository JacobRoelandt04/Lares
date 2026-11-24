#!/bin/bash
# Takes the rescue away: the GRUB entry, the image and kernel in /boot/lares, the rescue's files. The snapshots themselves stay.
set -u
[ "$(id -u)" = 0 ] || { echo "uninstall-rescue.sh needs root." >&2; exit 5; }
dest=${1:-/usr/local/lib/lares/snapshot/rescue}
rm -f /etc/grub.d/45_lares_rescue
rm -f /boot/lares/rescue.img /boot/lares/rescue-vmlinuz /boot/lares/rescue.info /boot/lares/.rescue.img.new /boot/lares/.rescue-vmlinuz.new
rmdir /boot/lares 2>/dev/null || true
if command -v grub-mkconfig >/dev/null && [ -d /boot/grub ]; then
    grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 && echo "GRUB menu updated: the rescue entry is gone."
fi
# this script may live in $dest: leave it for the caller to remove with the rest of the tool
for f in rescue.sh build mkinitcpio.conf protect.list built.json install/lares_rescue hooks/lares_rescue; do rm -f "$dest/$f"; done
rmdir "$dest/install" "$dest/hooks" 2>/dev/null || true
echo "Rescue removed."
