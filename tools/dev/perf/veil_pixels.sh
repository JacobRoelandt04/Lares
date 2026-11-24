#!/usr/bin/env bash
# veil_pixels.sh -- the pixel proof of a veil change that must leave every pixel as it was: the same jobs (every veil,
# several held times, both modes, both resolutions, with and without the popup, at rest, rising, with keys alive and after
# they died, a fail, an accepted password, a boot) rendered on the BASE tree twice and on the changed tree once, composited
# on black, and the pixels that differ in any channel counted. The base must repeat to 0 first: a scene that does not
# repeat proves nothing.
#
#   tools/dev/perf/veil_pixels.sh OUTDIR --base DIR [--tree DIR] [--veils "relief gooey ..."]
#   RES="3440x1440 2880x1620"   MODES="light dark"   PLATFORM=offscreen (GLSL 120 on this machine's GL) | env (a client of
#   tools/dev/lock_env.sh's nested Hyprland: NVIDIA's GLES here, the lock's own variants; LOCK_ENV=pfv1)
# Renders run with QML_DISABLE_DISTANCEFIELD=1 and VEIL_HOUR=10.5 (the relief is lit by the real sky otherwise), from private
# copies with private XDG homes. A base tree is `git archive <rev> | tar -x -C DIR`. Ends in VEIL_PIXELS RESULT PASS|FAIL
# (FAIL: the base did not repeat, or the change moved a pixel; the counts per veil are printed).
set -u
HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$HERE/tools/dev/result_lib.sh"
OUT="" BASE="" TREE="$HERE" VEILS="relief gooey dimples paper louvres keycaps dials"
while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE="$(realpath "$2")"; shift 2 ;;
        --tree) TREE="$(realpath "$2")"; shift 2 ;;
        --veils) VEILS="$2"; shift 2 ;;
        *) OUT="$1"; shift ;;
    esac
done
[ -n "$OUT" ] && [ -n "$BASE" ] || { sed -n '2,15p' "$0"; exit 2; }
mkdir -p "$OUT"; OUT="$(realpath "$OUT")"
PLATFORM="${PLATFORM:-offscreen}"
export LOCK_ENV="${LOCK_ENV:-pfv1}"
E="$HERE/tools/dev/lock_env.sh"
W=$(mktemp -d /tmp/lrvpx.XXXXXX) || exit 1
started=0
cleanup() { [ "$started" = 1 ] && [ -z "${KEEP_ENV:-}" ] && "$E" down > /dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT
if [ "$PLATFORM" = env ] && ! "$E" status 2> /dev/null | grep -q " up:"; then
    LOCK_REFRESH=120 "$E" up > "$W/up.log" 2>&1 || { cat "$W/up.log"; echo "VEIL_PIXELS RESULT FAIL (lock_env up)"; exit 1; }
    started=1
fi

# ---- the jobs: per veil, the states a change must not touch ----------------------------------------------------------------
python3 - "$W/jobs.json" $VEILS <<'PY'
import json, sys
out, veils = sys.argv[1], sys.argv[2:]
fx, fy = 1440, 450          # near the stand-in popup's field (VeilStage.fieldPoint at 2880 x 1620)
jobs = []
for v in veils:
    J = lambda name, **k: jobs.append(dict(name="%s-%s" % (v, name), veil=v, **k))
    J("rest-t0.5", t=0.5)
    J("rest-t7.3", t=7.3)
    J("rest-t31.7", t=31.7)
    J("nopopup-t12.1", t=12.1, popup=False)
    J("rise-p0.35", t=0.6, presence=0.35)
    J("rise-p0.8", t=0.9, presence=0.8)
    J("boot-t4.2", t=4.2, boot=True)
    J("boot-rise-p0.3", t=0.4, boot=True, presence=0.3)
    keys = [dict(kind="key", x=fx, y=fy, t=9.0 + 0.12 * i) for i in range(6)]
    J("keys-alive", t=9.9, pulses=keys)
    J("keys-many", t=9.0 + 0.05 * 36, pulses=[dict(kind="key", x=fx + 7 * i, y=fy, t=9.0 + 0.05 * i) for i in range(36)])
    # the same keys, long dead: the slots empty again after they were filled (the clock walked through them)
    J("keys-dead", t=24.0, pulses=keys, steps=[9.5, 10.0, 12.0, 18.0])
    J("fail", t=15.25, pulses=[dict(kind="fail", x=fx, y=fy, t=15.0)])
    J("wake", t=20.6, pulses=[dict(kind="wake", x=fx, y=fy, t=20.0)])
    J("ok-0.3", t=30.3, pulses=keys[:2] + [dict(kind="ok", x=fx, y=fy, t=30.0)], steps=[29.0, 30.1])
    J("ok-0.8", t=30.8, pulses=keys[:2] + [dict(kind="ok", x=fx, y=fy, t=30.0)], steps=[29.0, 30.1, 30.5])
json.dump(jobs, open(out, "w"))
print(len(jobs), "jobs")
PY

render() {  # tree label mode res
    local tree=$1 label=$2 mode=$3 res=$4 w h d
    w=${res%x*}; h=${res#*x}
    d="$W/r/$label/$mode-$res"
    mkdir -p "$d" "$W/c-$label-$mode/t/tools/dev/qml" "$W/c-$label-$mode/t/mockups" "$W/c-$label-$mode/cfg/theme" "$W/c-$label-$mode/state" \
        "$W/c-$label-$mode/cache" "$W/c-$label-$mode/rt"
    chmod 700 "$W/c-$label-$mode/rt"
    local c="$W/c-$label-$mode"
    rsync -a --delete --exclude '.qmlls.ini' "$tree/modules" "$tree/themes" "$c/t/" || return 1
    rsync -a "$tree/mockups/fixtures" "$c/t/mockups/" 2> /dev/null
    cp "$HERE/tools/dev/qml/veil_perf_pixels.qml" "$c/t/tools/dev/qml/"
    ln -sfn ../../../modules "$c/t/tools/dev/qml/modules"
    printf '{"theme":"eva","mode":"%s"}\n' "$mode" > "$c/cfg/theme/state.json"
    local envv=(XDG_CONFIG_HOME="$c/cfg" XDG_STATE_HOME="$c/state" XDG_CACHE_HOME="$c/cache" QS_DISABLE_CRASH_HANDLER=1
                QML_DISABLE_DISTANCEFIELD=1 VEIL_HOUR=10.5 JOBS="$W/jobs.json" OUT="$d" W="$w" H="$h")
    if [ "$PLATFORM" = env ]; then
        "$E" run env "${envv[@]}" timeout -k 5 600 quickshell -n -p "$c/t/tools/dev/qml/veil_perf_pixels.qml" > "$d.log" 2>&1
    else
        env -u WAYLAND_DISPLAY XDG_RUNTIME_DIR="$c/rt" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi "${envv[@]}" \
            timeout -k 5 600 quickshell -n -p "$c/t/tools/dev/qml/veil_perf_pixels.qml" > "$d.log" 2>&1
    fi
    rl_clean "$d.log" | grep -aq "VP_PIXELS RESULT PASS" || { echo "  the render of $label $mode $res did not finish ($d.log):"; rl_clean "$d.log" | tail -5; return 1; }
}

fail=0
for mode in ${MODES:-light dark}; do
    for res in ${RES:-3440x1440 2880x1620}; do
        render "$BASE" base "$mode" "$res" && render "$BASE" base2 "$mode" "$res" && render "$TREE" tree "$mode" "$res" || { fail=1; continue; }
        python3 - "$W/r/base/$mode-$res" "$W/r/base2/$mode-$res" "$W/r/tree/$mode-$res" "$mode $res" "$OUT" <<'PY' || fail=1
import os, sys
import numpy as np
from PIL import Image
a, a2, b, label, out = sys.argv[1:6]
def load(p):
    im = Image.open(p).convert("RGBA")
    bg = Image.new("RGBA", im.size, (0, 0, 0, 255))
    return np.asarray(Image.alpha_composite(bg, im).convert("RGB"), dtype=np.int16)
names = sorted(f for f in os.listdir(a) if f.endswith(".png"))
per = {}
bad = 0
for n in names:
    x, x2, y = load(os.path.join(a, n)), load(os.path.join(a2, n)), load(os.path.join(b, n))
    rep = int(np.any(x != x2, axis=2).sum())
    d = np.any(x != y, axis=2)
    diff = int(d.sum())
    worst = int(np.abs(x - y).max())
    v = n.split("-")[0]
    s = per.setdefault(v, [0, 0, 0, 0])
    s[0] += 1; s[1] += rep; s[2] += diff; s[3] = max(s[3], worst)
    if rep or diff:
        bad += 1
        print("    %-28s base-again %7d px   changed %7d px (worst %d levels)" % (n[:-4], rep, diff, worst))
        if diff:
            m = (d * 255).astype(np.uint8)
            Image.fromarray(m).save(os.path.join(out, "diff-%s-%s" % (label.replace(" ", "-"), n)))
for v, s in per.items():
    print("  %-11s %-8s %3d renders: base repeats %s, changed tree %s" % (label, v, s[0], "to 0 px" if s[1] == 0 else "NO (%d px)" % s[1],
          "0 px" if s[2] == 0 else "%d px (worst %d levels)" % (s[2], s[3])))
sys.exit(1 if bad else 0)
PY
    done
done
echo "VEIL_PIXELS RESULT $([ "$fail" = 0 ] && echo PASS || echo FAIL)"
exit "$fail"
