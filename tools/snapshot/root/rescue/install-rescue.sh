#!/bin/bash
# Installs the rescue (called by the root tool's install.sh as root, from the snapshot of the tool):
#   install-rescue.sh [--dest DIR] [--no-build]
# Puts the rescue's files under DIR (default /usr/local/lib/lares/snapshot/rescue), the GRUB fragment at /etc/grub.d/45_lares_rescue, then
# builds the image into /boot/lares and regenerates grub.cfg.
set -euo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
dest=/usr/local/lib/lares/snapshot/rescue
build=1
while [ $# -gt 0 ]; do
    case $1 in
        --dest) dest=$2; shift 2 ;;
        --no-build) build=0; shift ;;
        *) echo "usage: install-rescue.sh [--dest DIR] [--no-build]" >&2; exit 2 ;;
    esac
done
[ "$(id -u)" = 0 ] || { echo "install-rescue.sh needs root." >&2; exit 5; }

install -d -m 755 "$dest" "$dest/install" "$dest/hooks"
for f in rescue.sh build mkinitcpio.conf protect.list uninstall-rescue.sh; do
    install -m "$([ "$f" = rescue.sh ] || [ "$f" = build ] || [ "$f" = uninstall-rescue.sh ] && echo 755 || echo 644)" "$here/$f" "$dest/$f"
done
install -m 755 "$here/install/lares_rescue" "$dest/install/lares_rescue"
install -m 755 "$here/hooks/lares_rescue" "$dest/hooks/lares_rescue"
# the fragment is a file of its own at the path GRUB expects; it is protected at a restore (contract section 3)
install -m 755 "$here/45_lares_rescue" /etc/grub.d/45_lares_rescue
echo "Rescue files installed in $dest."
if [ "$build" = 1 ]; then
    "$dest/build"
fi
