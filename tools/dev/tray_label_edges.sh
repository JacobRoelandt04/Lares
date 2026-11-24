#!/usr/bin/env bash
# tray_label_edges.sh -- the tray's name label has whole-pixel edges. The engine centres the label on its icon's middle (a whole
# pixel), so an ODD extent along the strip (29 for one 12 px line + 7 padding) put both edges, and the text, on half pixels
# (CLAUDE.md: a box's edges must be whole pixels, not its centre). Renders mockups/windowtray.qml at 1x (OPEN=top HOVER=1: icon 1's
# label, one line) offscreen and reads the label's rows down a column through it: a row is whole when it is the label's fill or the
# ground, never a mix.
#
#   tools/dev/tray_label_edges.sh       TRAYLABEL RESULT PASS | FAIL (it runs itself in a sandbox copy, theme seeded)
#   ARM=oddlabel                        the plain ceil back, in the copy -> "label edges on whole pixels"
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/traylabel.XXXXXX")"
KEEP=1   # cleared only on a pass: a failure keeps its log and grab for whoever reads the verdict
trap '[ "$KEEP" = 0 ] && rm -rf "$D"' EXIT
# The theme is SEEDED (a private XDG_CONFIG_HOME / XDG_STATE_HOME), never the user's state: the label's fill below is this
# theme's dark surface, catppuccin dark #24273A = (36, 39, 58). Every launch runs inside a sandbox copy, and an ARM patches that
# copy in the same call (the copy is re-synced on every sandbox call).
mkdir -p "$D/cfg/theme" "$D/state"
printf '{"theme":"catppuccin","mode":"dark"}\n' > "$D/cfg/theme/state.json"
case "${ARM:-}" in
    "") ARMCMD="" ;;
    oddlabel) ARMCMD="sed -i 's|labelH: root._alongIsY ? 2 \\* Math.round(root._labelTextH / 2)|labelH: root._alongIsY ? Math.ceil(root._labelTextH)|' modules/windowtray/WindowTrayOwner.qml && grep -q 'Math.ceil(root._labelTextH)' modules/windowtray/WindowTrayOwner.qml || { echo 'TRAYLABEL ARM anchor gone'; exit 3; }" ;;
    *) echo "TRAYLABEL RESULT FAIL (unknown ARM)"; exit 1 ;;
esac
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi OPEN=top HOVER=1 STAGE_GRAB='"$D/g.png"' GRAB_MS=3000 XDG_CONFIG_HOME='"$D/cfg"' XDG_STATE_HOME='"$D/state"' timeout -k 5 40 quickshell -p mockups/windowtray.qml'
tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
if grep -aq 'TRAYLABEL ARM anchor gone' "$D/log"; then echo "TRAYLABEL RESULT FAIL (ARM $ARM: the anchor is gone -- re-aim it)"; exit 1; fi
if [ ! -s "$D/g.png" ]; then
    [ -n "${ARM:-}" ] && { echo "ARM $ARM: the armed copy did not load -- it proves nothing ($D/log)"; exit 1; }
    rl_noresult TRAYLABEL "$D/log"; exit 1
fi
python3 - "$D/g.png" <<'P'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
col = [im.getpixel((240, y)) for y in range(70, 125)]
fill = (36, 39, 58)
rows = [i for i, p in enumerate(col) if p == fill]
if not rows:
    print("TRAYLABEL RESULT FAIL (no label found)"); sys.exit(1)
a, b = rows[0], rows[-1]
# the rows just outside the fill must be the plain ground: close to their own neighbour further out
ok = all(abs(col[a - 1][c] - col[a - 3][c]) < 20 and abs(col[b + 1][c] - col[b + 3][c]) < 20 for c in range(3))
print("label rows %d..%d (%d tall), edge rows %s / %s" % (70 + a, 70 + b, b - a + 1, col[a - 1], col[b + 1]))
print("TRAYLABEL check: label edges on whole pixels: %s" % ("ok" if ok else "FAIL"))
print("TRAYLABEL RESULT %s" % ("PASS" if ok else "FAIL (label edges on whole pixels)"))
sys.exit(0 if ok else 1)
P
rc=$?
[ "$rc" = 0 ] && [ -z "${ARM:-}" ] && KEEP=0
[ "$rc" != 0 ] && echo "  (kept: $D)"
exit "$rc"
