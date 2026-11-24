#!/usr/bin/env bash
# The stocks cards, before and after (tools/dev/qml/stock_notif_sheet.qml): the real NotificationCard at a toast's 360 px on the real
# NotificationService, the four sudden-move cases (a late drop, a mid-morning jump, a jump nine minutes after the open, a thin stock with
# gaps) with the OLD body (SuddenMoveBody of 80434cc4, fed the window values it was) and the NEW (StockMoveBody), and the three alert
# kinds with the new one -- in light and dark at device scale 1 and 1.25, composed into labelled sheets by PIL.
#
#   tools/dev/stock_notif_sheet.sh [outdir]     default /tmp/lares-stk-report/graph
#   SCALES   default "1 1.25" (QT_SCALE_FACTOR: a sheet's stand-in for the shell's frame scale)   MODES  default "light dark"
#
# The last line is STOCK_NOTIF_SHEET RESULT PASS|FAIL. Offscreen, QT_QUICK_BACKEND=rhi (a software scenegraph draws no ShaderEffect).
set -u
export SANDBOX="${SANDBOX:-/tmp/lares-sbx-stkgr}"
cd "$(dirname "$0")/../.."
. tools/dev/result_lib.sh
OUT="$(realpath -m "${1:-/tmp/lares-stk-report/graph}")"
if [ -e .git ]; then
    # The old body is a revision's file: taken out here (the copy has no .git) and handed in by path.
    mkdir -p "$OUT"
    git show 80434cc4:modules/notifications/sources/SuddenMoveBody.qml > "$OUT/SuddenMoveBody.old.qml" || exit 1
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen OLD_SRC="$OUT/SuddenMoveBody.old.qml" tools/dev/stock_notif_sheet.sh "$OUT"
fi
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-rhi}" QSG_DISTANCEFIELD_ANTIALIASING=gray
HERE=$(pwd)
SCALES="${SCALES:-1 1.25}"
MODES="${MODES:-light dark}"
mkdir -p "$OUT"
# the old body goes beside the new one, in THIS copy (so its relative imports hold)
cp "$OLD_SRC" "$HERE/modules/notifications/sources/SuddenMoveBodyOld.qml"
cp "$HERE/tools/dev/qml/stock_notif_sheet.qml" "$HERE/stock_notif_sheet.qml"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/stknsheet.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0
for md in $MODES; do
    for sc in $SCALES; do
        o="$OUT/cells_${md}_${sc}"
        rm -rf "$o"; mkdir -p "$o" "$WORK/cfg_$md/theme" "$WORK/state" "$WORK/cache"
        printf '{"theme":"eva","mode":"%s"}\n' "$md" > "$WORK/cfg_$md/theme/state.json"
        log="$o/run.log"
        XDG_CONFIG_HOME="$WORK/cfg_$md" XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" OUT_DIR="$o" QT_SCALE_FACTOR="$sc" \
            CASE_DIR="$HERE/tools/dev/fixtures/stock_notif" OLD_BODY="$HERE/modules/notifications/sources/SuddenMoveBodyOld.qml" \
            timeout -k 5 120 quickshell -n -p "$HERE/stock_notif_sheet.qml" > "$log" 2>&1
        rl_result STOCK_NOTIF_SHEET "$log" "STOCK_NOTIF_SHEET RESULT .*" | sed "s/^/$md $sc: /" || fails=$((fails + 1))
        rl_clean "$log" | grep -E "WARN|ERROR|Binding|TypeError" | rl_platform_noise | grep -v "quickshell.tooling\|QT_QPA_PLATFORM\|WAYLAND_DISPLAY\|window masks" | sort -u | head -6 | sed 's/^/    /'
    done
done
python3 - "$OUT" "$MODES" "$SCALES" <<'PY' || fails=$((fails + 1))
import os, sys, subprocess
from PIL import Image, ImageDraw, ImageFont
out, modes, scales = sys.argv[1], sys.argv[2].split(), sys.argv[3].split()
try:
    font = ImageFont.truetype(subprocess.run(["fc-match", "-f", "%{file}", "Inter"], capture_output=True, text=True).stdout, 14)
except Exception:
    font = ImageFont.load_default()
sudden = ["a_drop_late", "b_jump_morning", "c_jump_after_open", "d_thin_gaps"]
alerts = ["e_above", "f_below", "g_daymove"]
for m in modes:
    for s in scales:
        d = os.path.join(out, f"cells_{m}_{s}")
        def cell(n):
            p = os.path.join(d, n + ".png")
            return Image.open(p).convert("RGB") if os.path.exists(p) else None
        rows = [(n, [("old", cell("old_" + n)), ("new", cell("new_" + n))]) for n in sudden] + [(n, [("new", cell("new_" + n))]) for n in alerts]
        cws = [im.width for _, r in rows for _, im in r if im]
        if not cws:
            continue
        cw = max(cws)
        H = 28
        rh = [max(im.height for _, im in r if im) + H for _, r in rows]
        sheet = Image.new("RGB", (cw * 2 + 8, sum(rh) + 8), (255, 255, 255))
        dr = ImageDraw.Draw(sheet)
        y = 4
        for (n, r), h in zip(rows, rh):
            for ci, (tag, im) in enumerate(r):
                if not im:
                    continue
                dr.text((ci * cw + 8, y + 4), f"{tag}  {n}  [{m} {s}x]", fill=(0, 0, 0), font=font)
                sheet.paste(im, (ci * cw, y + H))
            y += h
        sheet.save(os.path.join(out, f"sheet_{m}_{s}.png"))
        print("sheet", f"sheet_{m}_{s}.png", sheet.size)
PY
[ "$fails" = 0 ] && echo "STOCK_NOTIF_SHEET RESULT PASS" || echo "STOCK_NOTIF_SHEET RESULT FAIL"
exit "$fails"
