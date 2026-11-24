#!/usr/bin/env bash
# A screenshot for the OSD: grim (+ slurp) -> a file, wl-copy, then the shell's
# `capture` IPC so the card shows its thumbnail.
#
#   tools/osd/shot.sh region     pick an area with slurp (the default)
#   tools/osd/shot.sh screen     every output, in one picture
#
# The folder (made when it is not there), the name and whether it is copied are osd.jsonc's
# (`capture`: dir, name, copy), read at each shot; a missing file or a bad value is the
# default, ~/Pictures/Screenshots/shot-<date>.png, copied. $OSD_SHOT_DIR wins over dir.
# "copied" is true only because this script copies it: `quickshell ipc call osd
# capture shot <path> copied`. A cancelled selection (slurp exits non-zero) ends
# quietly: nothing was captured, so nothing is shown.
set -u
mode="${1:-region}"
here=$(dirname -- "$(realpath -- "$0")")
conf="${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/config/osd.jsonc"
cfg=()
mapfile -d '' -t cfg < <(python3 -I - "$here/../lib" "$conf" 2> /dev/null << 'PY'
import os, re, sys
sys.path.insert(0, sys.argv[1])
import jsonc
try:
    c = jsonc.load(sys.argv[2]).get("capture")
except (OSError, ValueError, AttributeError):
    c = None
c = c if isinstance(c, dict) else {}
d, n, copy = c.get("dir"), c.get("name"), c.get("copy")
d = os.path.expanduser(d) if isinstance(d, str) and d else ""
n = n if isinstance(n, str) and re.fullmatch(r"[^/\0]+\.png", n) else ""
sys.stdout.write("\0".join([d if d.startswith("/") else "", n, "no" if copy is False else "yes"]) + "\0")
PY
)
dir="${OSD_SHOT_DIR:-${cfg[0]:-$HOME/Pictures/Screenshots}}"
name="${cfg[1]:-shot-%Y%m%d-%H%M%S.png}"
mkdir -p -- "$dir" || exit 1
file="$dir/$(date "+$name")"
# a name that is taken (one with no seconds in it) never writes over an earlier shot
base="${file%.png}" n=2
while [ -e "$file" ]; do
    file="$base-$n.png"
    n=$((n + 1))
done

case "$mode" in
    region)
        geom=$(slurp) || exit 0
        grim -g "$geom" "$file" || exit 1
        ;;
    screen)
        grim "$file" || exit 1
        ;;
    *)
        echo "usage: $0 [region|screen]" >&2
        exit 2
        ;;
esac

copied=plain
if [ "${cfg[2]:-yes}" = yes ] && command -v wl-copy > /dev/null 2>&1 && wl-copy < "$file"; then
    copied=copied
fi
quickshell ipc call osd capture shot "$file" "$copied" > /dev/null 2>&1 || true
