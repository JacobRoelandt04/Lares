#!/usr/bin/env bash
# Takes the system snapshots back out. The hooks go FIRST, so pacman never calls a tool that is half gone. Your snapshots stay.
#
#   sudo ~/.config/quickshell/tools/snapshot/root/uninstall.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
LIB=/usr/local/lib/lares/snapshot
ETCLARES=/etc/lares
HOOKDIR=/etc/pacman.d/hooks
POLICY=/usr/share/polkit-1/actions/org.lares.snapshot.policy
RULE=/etc/polkit-1/rules.d/50-lares-snapshot.rules
STATE=/.lares-snapshots
RESCUE_UNINSTALL=$HERE/rescue/uninstall-rescue.sh

rm -f "$HOOKDIR/00-lares-snapshot.hook" "$HOOKDIR/zz-lares-snapshot-done.hook"
[ -f "$RESCUE_UNINSTALL" ] && bash "$RESCUE_UNINSTALL"
rm -f "$RULE" "$POLICY"
rm -rf "$LIB"
rmdir /usr/local/lib/lares 2> /dev/null || true
rmdir "$ETCLARES" 2> /dev/null || true      # only while empty: a snapshot.off in it stays
echo "the snapshot hooks and tool are gone; pacman works as before"
if [ -d "$STATE" ]; then
    echo "Your snapshots are still in $STATE (and restic stays installed). To delete them for good:"
    echo "    sudo rm -rf $STATE"
fi
