#!/usr/bin/env bash
# The aerial test bed's ONE root step. README.md beside it.
#
#   sudo ~/.config/quickshell/tools/aerial/rig/install.sh       shows every change, asks for "yes", then makes them
#
# It installs:
#   packages  hostapd (the virtual access points), dnsmasq (their DHCP / DNS -- and what NetworkManager's own hotspot needs),
#             wireless-regdb (lets the VIRTUAL radios use 5 GHz; the real AX210 is self-managed and does not read it)
#   /usr/local/lib/lares/aerial-rig/          root-owned copies of the runner, its configs and the portal (root never runs
#                                             the repo's files)
#   /etc/systemd/system/lares-aerial-rig.service    not enabled: started on demand
#   /etc/polkit-1/rules.d/49-lares-aerial-rig.rules lets YOU start / stop / restart that one unit without a password
#   /etc/NetworkManager/conf.d/90-lares-aerial-rig.conf   your NetworkManager never manages a virtual radio or the rig's veth
#                                             (loaded with `nmcli general reload conf`: no restart, no reconnect)
# uninstall.sh takes all of it back out (the packages stay; `pacman -Rns hostapd` etc. if you want them gone).
# Nothing here starts the rig. Every path below is a variable, so tools/dev/aerial_rig_install_probe.sh runs this very file on a fake root.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
USER_NAME=${SUDO_USER:-}
[ -n "$USER_NAME" ] && [ "$USER_NAME" != root ] || { echo "run through sudo from your own account" >&2; exit 1; }
[[ $USER_NAME =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "user name '$USER_NAME' is not one this script will write into a polkit rule" >&2; exit 1; }
for f in rig portal.py lares-aerial-rig.service conf/bus.conf conf/dnsmasq.conf conf/eap_users conf/hostapd-a.conf conf/hostapd-b.conf conf/nm.conf conf/phone.conf; do
    [ -f "$HERE/$f" ] || { echo "missing $HERE/$f" >&2; exit 1; }
done
LIB=/usr/local/lib/lares/aerial-rig
UNIT=/etc/systemd/system/lares-aerial-rig.service
RULE=/etc/polkit-1/rules.d/49-lares-aerial-rig.rules
NMCONF=/etc/NetworkManager/conf.d/90-lares-aerial-rig.conf

cat <<EOT
This installs the aerial test bed for user '$USER_NAME':
  pacman -S --needed hostapd dnsmasq wireless-regdb
  $LIB/  (rig, portal.py, conf/*; root:root)
  $UNIT  (not enabled)
  $RULE  (start/stop/restart of that one unit, for '$USER_NAME')
  $NMCONF  (driver:mac80211_hwsim and lrig-h unmanaged), then: nmcli general reload conf
EOT
printf 'Type yes to go on: '
read -r answer
[ "$answer" = yes ] || { echo "nothing changed"; exit 1; }

pacman -S --needed hostapd dnsmasq wireless-regdb

install -d -m 0755 -o root -g root "$LIB" "$LIB/conf"
install -m 0755 -o root -g root "$HERE/rig" "$LIB/rig"
install -m 0644 -o root -g root "$HERE/portal.py" "$LIB/portal.py"
install -m 0644 -o root -g root "$HERE"/conf/* "$LIB/conf/"
printf '%s\n' "$USER_NAME" > "$LIB/user"
chmod 0644 "$LIB/user"

install -m 0644 -o root -g root "$HERE/lares-aerial-rig.service" "$UNIT"

cat > "$RULE" <<EOT
// Lares aerial test bed (tools/aerial/rig): '$USER_NAME' may start, stop and restart this one unit without a password.
polkit.addRule(function (action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        action.lookup("unit") == "lares-aerial-rig.service" &&
        subject.user == "$USER_NAME") {
        var verb = action.lookup("verb");
        if (verb == "start" || verb == "stop" || verb == "restart")
            return polkit.Result.YES;
    }
});
EOT
chmod 0644 "$RULE"

cat > "$NMCONF" <<'EOT'
# Lares aerial test bed (tools/aerial/rig): this NetworkManager never manages a virtual radio of mac80211_hwsim, nor the veth
# (lrig-h) that carries the host's route to the rig's gateway. A device section of its own: no unmanaged-devices list of yours is replaced.
[device-lares-aerial-rig]
match-device=driver:mac80211_hwsim,interface-name:lrig-h
managed=0
EOT
chmod 0644 "$NMCONF"

systemctl daemon-reload
nmcli general reload conf || echo "(NetworkManager did not answer: it reads the line at its next start)"
echo "installed. The test bed starts only when asked (no password): systemctl start lares-aerial-rig"
echo "now tell Claude: it runs tools/dev/aerial_rig_probe.sh, which proves the safety laws first."
