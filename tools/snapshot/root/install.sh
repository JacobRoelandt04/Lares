#!/usr/bin/env bash
# The system snapshots' ONE root step (docs/snapshots.md, docs/contracts/snapshots.md).
#
#   sudo ~/.config/quickshell/tools/snapshot/root/install.sh     shows every change, asks for "yes", then makes them
#
# The order is the safety: the tool first, the repository next, the hooks LAST. A pacman run that starts half way through finds no
# hook yet, and a hook never finds a tool that is not there. Nothing here takes a snapshot; the first one is `lares-snapshot create`
# (about 9 minutes for 12 GB on this laptop's disk) or the first big update.
# uninstall.sh takes the hooks out FIRST and keeps your snapshots. Every path below is a variable, so
# tools/dev/snapshot_install_probe.sh runs this very file on a fake root.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LIBSRC=$(cd "$HERE/../../lib" && pwd)
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
USER_NAME=${SUDO_USER:-}
[ -n "$USER_NAME" ] && [ "$USER_NAME" != root ] || { echo "run through sudo from your own account" >&2; exit 1; }
[[ $USER_NAME =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "user name '$USER_NAME' is not one this script will write into a polkit rule" >&2; exit 1; }
for f in lares-snapshot-root snaprules.py defaults.json hook 00-lares-snapshot.hook zz-lares-snapshot-done.hook org.lares.snapshot.policy \
         50-lares-snapshot.rules.in; do
    [ -f "$HERE/$f" ] || { echo "missing $HERE/$f" >&2; exit 1; }
done
[ -f "$LIBSRC/jsonc.py" ] || { echo "missing $LIBSRC/jsonc.py" >&2; exit 1; }
[ -d /etc/polkit-1/rules.d ] && [ -d /usr/share/polkit-1/actions ] || { echo "polkit is not installed (no /etc/polkit-1/rules.d): install it first" >&2; exit 1; }

LIB=/usr/local/lib/lares/snapshot
ETCLARES=/etc/lares
PYTHON=/usr/bin/python3
HOOKDIR=/etc/pacman.d/hooks
POLICY=/usr/share/polkit-1/actions/org.lares.snapshot.policy
RULE=/etc/polkit-1/rules.d/50-lares-snapshot.rules
STATE=/.lares-snapshots
RESCUE_INSTALL=$HERE/rescue/install-rescue.sh

cat <<EOT
This installs the system snapshots for user '$USER_NAME', in this order:
  1. pacman -S --needed restic
  2. $LIB/  (the tool, its rules, its defaults, the hook wrapper, your name; root:root) and the folder $ETCLARES/
     (where the file that switches the hook off is made, if you ever need it)
  3. $POLICY and $RULE
     (you may make a snapshot and keep one without a password; deleting one asks)
  4. $STATE/  (the repository and its password; readable by you in encrypted form only), made by 'lares-snapshot-root init'
EOT
[ -f "$RESCUE_INSTALL" ] && echo "  5. the rescue image, by $RESCUE_INSTALL"
cat <<EOT
  last: $HOOKDIR/zz-lares-snapshot-done.hook, then $HOOKDIR/00-lares-snapshot.hook
        (from then on pacman makes a snapshot before a large or important update; a broken tool never blocks pacman)
Nothing of /home is ever in a snapshot.
EOT
printf 'Type yes to go on: '
read -r answer
[ "$answer" = yes ] || { echo "nothing changed"; exit 1; }

pacman -S --needed restic

install -d -m 0755 -o root -g root "$LIB" "$ETCLARES"
install -m 0755 -o root -g root "$HERE/lares-snapshot-root" "$LIB/lares-snapshot-root"
install -m 0755 -o root -g root "$HERE/hook" "$LIB/hook"
install -m 0644 -o root -g root "$HERE/snaprules.py" "$LIB/snaprules.py"
install -m 0644 -o root -g root "$LIBSRC/jsonc.py" "$LIB/jsonc.py"
install -m 0644 -o root -g root "$HERE/defaults.json" "$LIB/defaults.json"
printf '%s\n' "$USER_NAME" > "$LIB/user"
chmod 0644 "$LIB/user"

install -m 0644 -o root -g root "$HERE/org.lares.snapshot.policy" "$POLICY"
sed "s/@USER@/$USER_NAME/g" "$HERE/50-lares-snapshot.rules.in" > "$RULE"
chmod 0644 "$RULE"

"$PYTHON" -I "$LIB/lares-snapshot-root" init
[ -f "$RESCUE_INSTALL" ] && bash "$RESCUE_INSTALL"

install -d -m 0755 -o root -g root "$HOOKDIR"
install -m 0644 -o root -g root "$HERE/zz-lares-snapshot-done.hook" "$HOOKDIR/zz-lares-snapshot-done.hook"
install -m 0644 -o root -g root "$HERE/00-lares-snapshot.hook" "$HOOKDIR/00-lares-snapshot.hook"

cat <<EOT

Installed. The hooks are in place: the next large or important update makes a snapshot first.
Make the first one now if you like (the first is the slow one): lares-snapshot create

THE REPOSITORY PASSWORD. Without it the snapshots cannot be read from another machine or after the disk is lost. It is shown once,
here. Put it in your password manager now:

    $(cat "$STATE/key")

(Later, as root: $PYTHON -I $LIB/lares-snapshot-root password)
EOT
