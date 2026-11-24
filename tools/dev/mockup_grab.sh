#!/usr/bin/env bash
# Renders a mockup's control panel to PNG, one file per tab, for looking at
# the panel without opening it.
#
#   tools/dev/mockup_grab.sh <mockup.qml> [outdir] [tab ...]
#   tools/dev/mockup_grab.sh --keys < log      the keys of a PANEL_TABS line (the parse alone)
#
# A tab is the index the panel shows it at; "3.1" is tab 3's second sub-tab.
# `tools/dev/mockup_grab.sh <mockup.qml> --list` prints what a mockup has. With
# no tabs given, every tab and sub-tab is rendered.
#
# Each grab is the whole window (mockup_<tab>.png); where PIL is installed a
# crop of the panel alone is written beside it (mockup_<tab>_panel.png), cut
# at the panel's own left edge (the window prints it with the grab).
# GRAB_MS (default 1500) is how long the mockup settles before the grab.
#
# A tab's NAME may hold spaces ("3.2=Manager/Pin flight"): the keys are the
# `<n>=` / `<n>.<m>=` tokens of the PANEL_TABS line, never its words -- split
# on spaces, "flight", "fades" and "spot" were grabbed as tabs of their own
# (copies of tab 0; R2E P1.8). `tabkeys` below is that parse.
set -u
# A probe's window never reaches the user's desktop (the user, 2026-10-24: "Can you not have qs tests appear on my desktop"):
# offscreen, RHI so a ShaderEffect still draws. LARES_SHOW=1 shows it, for a person watching.
[ "${LARES_SHOW:-}" = 1 ] || export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-rhi}"
cd "$(dirname "$0")/../.."
# PANEL_TABS line on stdin -> one key per line.
tabkeys() {
    grep -o "PANEL_TABS.*" | sed 's/^PANEL_TABS//' \
        | grep -oE '(^|[[:space:]])[0-9]+(\.[0-9]+)?=' | tr -d ' ='
}
if [ "${1:-}" = "--keys" ]; then       # `mockup_grab.sh --keys < log`: the parse alone, testable
    tabkeys
    exit 0
fi

QML="${1:?usage: mockup_grab.sh <mockup.qml> [outdir] [tab ...]}"; shift
[ -f "$QML" ] || { echo "no mockup at $QML"; exit 1; }

if [ "${1:-}" = "--list" ]; then
    PANEL_LIST_TABS=1 timeout 20 quickshell -p "$QML" 2>&1 \
        | sed 's/\x1b\[[0-9;]*m//g' | grep -o "PANEL_TABS.*"
    exit 0
fi

OUT="${1:-${SCRATCH:-/tmp}/mockup_grabs}"; shift || true
mkdir -p "$OUT"
GRAB_MS="${GRAB_MS:-1500}"

TABS=("$@")
if [ ${#TABS[@]} -eq 0 ]; then
    # Ask the mockup itself which tabs it has, so this works for any module.
    mapfile -t TABS < <(PANEL_LIST_TABS=1 timeout 20 quickshell -p "$QML" 2>&1 \
        | sed 's/\x1b\[[0-9;]*m//g' | tabkeys)
fi
[ ${#TABS[@]} -eq 0 ] && { echo "no tabs reported by $QML"; exit 1; }

for t in "${TABS[@]}"; do
    tab=${t%%.*}; sub=0; [[ "$t" == *.* ]] && sub=${t#*.}
    f="$OUT/mockup_${t}.png"
    out=$(GRAB="$f" GRAB_MS="$GRAB_MS" PANEL_TAB="$tab" PANEL_SUBTAB="$sub" \
        timeout 40 quickshell -p "$QML" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
    printf '%s\n' "$out" | grep -iE "error|GRAB saved" | sed "s/^/[$t] /"
    px=$(printf '%s\n' "$out" | grep -o "GRAB saved .* panel=[0-9]*" | tail -1 | sed 's/.*panel=//')
    python3 - "$f" "${px:-}" <<'PY' 2>/dev/null || true
import sys
from PIL import Image
p = sys.argv[1]
im = Image.open(p)
w, h = im.size
# The panel's left edge as the window reported it (a few px of its margin
# kept); a window that did not say falls back to the old share of the width.
x = max(0, int(sys.argv[2]) - 6) if len(sys.argv) > 2 and sys.argv[2] else int(w * 0.62)
im.crop((x, 0, w, h)).save(p.replace(".png", "_panel.png"))
PY
done
ls -la "$OUT"
