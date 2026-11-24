#!/usr/bin/env bash
# dictation_probe_caption.sh -- the dictation's caption card (modules/osd/kinds/OsdCaption.qml) in its states and themes, one sheet:
# tools/dev/qml/dictation_probe_caption.qml grabbed offscreen (QT_QUICK_BACKEND=rhi) in a sandbox copy, once per theme, with a private
# XDG_CONFIG_HOME whose theme state is seeded here (never the user's), the grabs side by side with a label per column.
#
#   tools/dev/dictation_probe_caption.sh [OUT.png [theme:mode ...]]   DICTCAP RESULT PASS | FAIL (OUT: $SCRATCH/dictation_caption_sheet.png)
#     default themes: eva:light eva:dark monokai:light tokyo-night:dark
# A grab whose card is not at the style's extent, a warning in a log, or a missing grab fails.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
OUT=${1:-${SCRATCH:-/tmp}/dictation_caption_sheet.png}
[ $# -gt 0 ] && shift
THEMES=("$@")
[ ${#THEMES[@]} -gt 0 ] || THEMES=(eva:light eva:dark monokai:light tokyo-night:dark)
W="$(mktemp -d "${SCRATCH:-/tmp}/dictcap.XXXXXX")"
export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-dictcap}"
trap 'rm -rf "$W"' EXIT
rc=0
noresult=""
pngs=()
for tm in "${THEMES[@]}"; do
    t=${tm%%:*} m=${tm##*:}
    x="$W/$t-$m"
    mkdir -p "$x/config/theme" "$x/state" "$x/cache"
    printf '{"theme":"%s","mode":"%s"}\n' "$t" "$m" > "$x/config/theme/state.json"
    tools/dev/sandbox.sh XDG_CONFIG_HOME="$x/config" XDG_STATE_HOME="$x/state" XDG_CACHE_HOME="$x/cache" QT_QPA_PLATFORM=offscreen \
        QT_QUICK_BACKEND=rhi WAYLAND_DISPLAY= HYPRLAND_INSTANCE_SIGNATURE= LARES_SLEEP_MONITOR=off DICTCAP_GRAB="$x/grab.png" \
        timeout 60 quickshell -p tools/dev/qml/dictation_probe_caption.qml > "$x/log" 2>&1
    res=$(rl_result DICTCAP "$x/log" 'DICTCAP RESULT .*')
    echo "$tm: $res"
    # the log a no-result verdict names must outlive the run ($W is removed at exit): keep the first one beside the sheet
    if rl_isnoresult "$res" && [ -z "$noresult" ]; then
        cp -f -- "$x/log" "$OUT.noload.log" 2> /dev/null
        noresult="DICTCAP RESULT FAIL (no result: $OUT.noload.log)"
    fi
    rl_clean "$x/log" | grep -a 'DICTCAP size' | sed "s/^/  /"
    warn=$(rl_clean "$x/log" | grep -a -E 'WARN|ERROR|Unable to assign|Binding loop|non-existent|TypeError|ReferenceError' | grep -v 'quickshell.tooling\|outside of the config folder\|does not support setting window masks' | head -5)
    [ -z "$warn" ] || { echo "  warnings: $warn"; rc=1; }
    case $res in *PASS*) ;; *) rc=1 ;; esac
    [ -s "$x/grab.png" ] && pngs+=("$x/grab.png|$tm") || rc=1
done
python3 - "$OUT" "${pngs[@]}" <<'PY'
import sys
from PIL import Image, ImageDraw
out, cells = sys.argv[1], [c.split("|") for c in sys.argv[2:]]
ims = [(Image.open(p).convert("RGB"), label) for p, label in cells]
if not ims:
    sys.exit(0)
w = sum(i.width for i, _ in ims) + 8 * (len(ims) - 1)
h = max(i.height for i, _ in ims) + 18
sheet = Image.new("RGB", (w, h), (255, 255, 255))
d = ImageDraw.Draw(sheet)
x = 0
for im, label in ims:
    sheet.paste(im, (x, 18))
    d.text((x + 4, 3), label, fill=(0, 0, 0))
    x += im.width + 8
sheet.save(out)
PY
echo "SHEET $OUT"
# a run that did not load says so in the verdict (tools/dev/result_lib.sh)
if [ -n "$noresult" ]; then echo "$noresult"; exit 1; fi
echo "DICTCAP RESULT $([ $rc = 0 ] && echo PASS || echo FAIL)"
exit $rc
