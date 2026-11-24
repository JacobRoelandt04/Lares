#!/usr/bin/env bash
# Takes the aerial test bed back out. The packages stay: `pacman -Rns hostapd wireless-regdb` if you want them gone (keep dnsmasq while
# you want NetworkManager's hotspot).
#
#   sudo ~/.config/quickshell/tools/aerial/rig/uninstall.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
systemctl stop lares-aerial-rig.service 2> /dev/null || true
rm -f /etc/systemd/system/lares-aerial-rig.service
rm -f /etc/polkit-1/rules.d/49-lares-aerial-rig.rules
rm -f /etc/NetworkManager/conf.d/90-lares-aerial-rig.conf
rm -rf /usr/local/lib/lares/aerial-rig
rmdir /usr/local/lib/lares 2> /dev/null || true
systemctl daemon-reload
nmcli general reload conf || echo "(NetworkManager did not answer: it reads its files at its next start)"
echo "the aerial test bed is gone"
