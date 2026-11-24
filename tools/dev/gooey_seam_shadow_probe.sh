#!/usr/bin/env bash
# gooey_seam_shadow_probe.sh -- the shell's halo under the seam of a popup and its flush secondary (feedback/general.md "Secondary popup
# shadow issue at seam"): the plain smooth-min of the shadow's union swelled the two bodies where their distances agree, which under
# two feet on one line is all the way down -- a spot 12 levels darker under the seam. gooey_field.frag fillets the shadow's union only
# where it is concave (sminFaces). The real engine, offscreen, in a sandbox copy (tools/dev/qml/gooey_seam_shadow_probe.qml).
#
#   tools/dev/gooey_seam_shadow_probe.sh            GOOEY_SEAM RESULT PASS|FAIL
#   ARM=plainsmin tools/dev/gooey_seam_shadow_probe.sh   the shadow tile's union back on the plain smin (the copy rebaked): must FAIL
#                                                        ("a flat foot")
#   KEEP=1                                           keep the work dir (the PNGs)
#
# THE JUDGE. Rows 1..8 px under the union's foot, across its span less 40 px at each end: every row one level of ink, no spot -- the
# largest difference between a row's median and any pixel of it at most 2 levels (the old shader: 12). Two states: the secondary as
# tall as the popup (the feet on one line), and 200 px tall on the popup's foot (a concave corner at its top, which keeps its fillet).
# Nothing touches the desktop: offscreen, a private config / cache / state home.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
NAME=GOOEY_SEAM
D="$(mktemp -d "${SCRATCH:-/tmp}/gooeyseam.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
mkdir -p "$D/cfg/theme" "$D/cache" "$D/state"
printf '{"theme":"eva","mode":"%s"}\n' "${MODE:-light}" > "$D/cfg/theme/state.json"
ARMCMD=""
case "${ARM:-}" in
    "") ;;
    plainsmin) ARMCMD="python3 -c \"import sys; p='modules/bar/gooey/shaders/gooey_field.frag'; s=open(p).read(); a='ds = sminFaces(ds, gds, e, b, p, smoothK);'; n=s.count(a); print('ARM anchor', n); sys.exit(1) if n != 1 else open(p,'w').write(s.replace(a, 'ds = smin(ds, e, smoothK);'))\" && tools/dev/bake_shaders.sh gooey_field > /dev/null" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
run='set -e; '"${ARMCMD:+$ARMCMD; }"'for h in 320 200; do env -u WAYLAND_DISPLAY XDG_CONFIG_HOME="'"$D/cfg"'" XDG_CACHE_HOME="'"$D/cache"'" XDG_STATE_HOME="'"$D/state"'" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi OUT="'"$D"'/seam_$h.png" CHILD_H=$h timeout 60 quickshell -p tools/dev/qml/gooey_seam_shadow_probe.qml > "'"$D"'/log_$h" 2>&1 || true; done'
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-gooey-seam}" tools/dev/sandbox.sh bash -c "$run" > "$D/run.log" 2>&1
python3 - "$D" <<'PY'
import re, statistics, sys
from PIL import Image
d = sys.argv[1]
fails = 0
for h in (320, 200):
    try:
        log = open(f"{d}/log_{h}", errors="replace").read()
        m = re.search(r"SEAM box (\d+) (\d+) (\d+) (\d+)", log)
        im = Image.open(f"{d}/seam_{h}.png").convert("RGBA")
    except Exception as e:
        print(f"GOOEY_SEAM FAIL state {h}: no picture or no boxes ({e})"); fails += 1; continue
    if not m:
        print(f"GOOEY_SEAM FAIL state {h}: no boxes in the log"); fails += 1; continue
    x0, x1, foot, seam = map(int, m.groups())
    g = Image.new("RGBA", im.size, (228, 231, 238, 255)); g.alpha_composite(im); g = g.convert("L")
    worst, at = 0, None
    for dy in range(1, 9):
        row = [g.getpixel((x, foot + dy)) for x in range(x0 + 40, x1 - 40)]
        med = statistics.median(row)
        for i, v in enumerate(row):
            if med - v > worst:
                worst, at = med - v, (x0 + 40 + i, foot + dy)
    ok = worst <= 2
    fails += 0 if ok else 1
    print(f"GOOEY_SEAM {'ok  ' if ok else 'FAIL'} state {h}: a flat foot under the seam at x {seam}: the darkest pixel {worst:.0f} levels under its row's median (at {at}; at most 2)")
print(f"GOOEY_SEAM RESULT {'PASS' if fails == 0 else 'FAIL'}")
sys.exit(0 if fails == 0 else 1)
PY
res=$?
if [ -n "${ARM:-}" ]; then
    if grep -q "ARM anchor 0" "$D/run.log"; then echo "ARM $ARM: the anchor is gone -- it proves nothing"; exit 1; fi
    [ "$res" = 0 ] && { echo "ARM $ARM: DID NOT FAIL -- the judge cannot see it"; exit 1; } || { echo "ARM $ARM: failed as it must"; exit 0; }
fi
exit $res
