#!/usr/bin/env bash
# break_sheet.sh -- a before/after strip of the break fill's eased moves from the workspaces mockup: the reveal (out of the hidden zone), a
# beat's step and an idle rewind, light and dark. PNGs (the stage alone) into the output dir, then one sheet.
#
#   tools/dev/break_sheet.sh [outdir]        default ~/.cache/lares/break_sheet
#
# Offscreen in the sandbox copy with a private config / state / cache home (the theme mode is seeded per cell, the user's is never touched).
set -u
cd "$(dirname "$0")/../.." || exit 1
OUT="${1:-$HOME/.cache/lares/break_sheet}"
mkdir -p "$OUT"
K="${BREAKS_K:-1.25}"
for mode in light dark; do
    for cell in "reveal 700" "reveal 1000" "reveal 1500" "step 1850" "step 2250" "rewind 1850" "rewind 2250" "rewind 2800"; do
        set -- $cell
        st="$1"; ms="$2"
        tools/dev/sandbox.sh bash -c "P=\$(mktemp -d /tmp/brks.XXXXXX); mkdir -p \$P/config/theme \$P/state \$P/cache
            printf '{\"theme\":\"eva\",\"mode\":\"$mode\"}\n' > \$P/config/theme/state.json
            env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME=\$P/config XDG_STATE_HOME=\$P/state XDG_CACHE_HOME=\$P/cache \
                BREAKS_STATE=$st BREAKS_K=$K SHEET_GRAB=$OUT/${mode}_${st}_${ms}.png GRAB_MS=$ms timeout 60 quickshell -p mockups/workspaces.qml > /dev/null 2>&1
            rm -rf \$P; true" > /dev/null 2>&1
        ls "$OUT/${mode}_${st}_${ms}.png" > /dev/null 2>&1 || echo "no grab: $mode $st $ms"
    done
done
python3 - "$OUT" <<'PY'
import sys, glob, os
from PIL import Image, ImageDraw
out = sys.argv[1]
cells = ["reveal_700", "reveal_1000", "reveal_1500", "step_1850", "step_2250", "rewind_1850", "rewind_2250", "rewind_2800"]
rows = []
for mode in ("light", "dark"):
    for c in cells:
        p = f"{out}/{mode}_{c}.png"
        if os.path.exists(p):
            rows.append((mode, c, Image.open(p).convert("RGB")))
if rows:
    w = max(i.width for _, _, i in rows); h = max(i.height for _, _, i in rows)
    cols = len(cells)
    sheet = Image.new("RGB", (cols * w, 2 * (h + 16)), "white")
    d = ImageDraw.Draw(sheet)
    for n, (mode, c, im) in enumerate(rows):
        x = (n % cols) * w; y = (n // cols) * (h + 16)
        d.text((x + 4, y + 2), f"{mode} {c}", fill="black")
        sheet.paste(im, (x, y + 16))
    sheet.save(f"{out}/sheet.png")
    print("sheet", f"{out}/sheet.png", sheet.size)
PY
