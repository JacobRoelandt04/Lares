#!/usr/bin/env bash
# ONE RESOLVER, TWICE: the shell's Theme.qml (through ThemeResolve.js) and themectl (Python) resolve the same fixture theme and agree
# token by token. A theme file is read by both the shell and the desktop's programs; if the two read it differently the desktop
# comes up in colours the shell never drew.
#
#   tools/dev/themectl_resolver_parity.sh              last line THEMECTL_PARITY RESULT PASS|FAIL
#   ARM=<name> tools/dev/themectl_resolver_parity.sh   one fault in a SANDBOX COPY; must FAIL
#   ARM=all tools/dev/themectl_resolver_parity.sh      every arm; THEMECTL_PARITY ARMS PASS only when each failed where it must
#
# The fixture (tools/dev/fixtures/themectl/parity.json + a seeded sweep: 162 colours x lighten/darken x 6 amounts, in each mode) has
# every op, the three colour forms, an alias chain through undeclared keys, a recipe on a recipe, `common` over L0 and the block over
# `common`, cycles (two, a self-alias, a three-key one), an unknown target, a bad op, a missing / negative / over-range / non-numeric
# amount, a recipe on a number, a non-colour for a colour token, null, a list, and `alpha 0.00980392156862745` (2.5 exactly: the
# half-way case that tells floor(x + 0.5) from Python's round()).
#   P1  L0 (the defaults object of Theme.qml) read by themectl is the one Theme.qml has
#   P2  every key of every mode resolves to the same value
#   P3  the same keys are errors
#   P4  the Theme singleton itself (baseOf, through its own integration) answers as the library does, for every declared token
#   P5  the fixture really holds what it claims (goldens from an independent HLS implementation, the bad inputs ARE errors)
# Arms:  jsround   darken rounds down in ThemeResolve.js (the sandbox copy)        -> P2
#        pyround   Python's round() (half to even) in a copy of tools/theme          -> P2
#        jsalpha   alpha rounds to nearest-even-ish: Math.round in ThemeResolve.js  -> P2 (the half case)
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
. tools/dev/result_lib.sh
NAME=THEMECTL_PARITY
SCRATCH="${SCRATCH:-/tmp}"
ARM="${ARM:-}"

if [ "$ARM" = all ]; then
    bad=0
    for a in ${ONLY_ARMS:-jsround pyround jsalpha}; do
        log="$SCRATCH/themectl_parity-arm-$a.out"
        mkdir -p "$SCRATCH"
        ARM="$a" SCRATCH="$SCRATCH" "$ROOT/tools/dev/themectl_resolver_parity.sh" > "$log" 2>&1
        last=$(tail -1 "$log")
        if rl_isnoresult "$last"; then echo "  ARM $a: the armed copy did not load -- it proves nothing: $last"; bad=1; continue; fi
        failed=$(grep -oE "^FAIL +P[0-9]" "$log" | awk '{print $2}' | sort -u | tr '\n' ' ')
        if [ "$last" = "$NAME RESULT FAIL (ARM=$a)" ] && case " $failed" in *" P2 "*) true ;; *) false ;; esac; then
            echo "  ARM $a: FAIL, as it must -- red: ${failed% }"
        else
            echo "  ARM $a: NOT PROVEN -- '$last', must be red: P2, red: ${failed% } ($log)"
            bad=1
        fi
    done
    [ "$bad" = 0 ] && { echo "$NAME ARMS PASS (every arm failed where it must)"; exit 0; }
    echo "$NAME ARMS FAIL"
    exit 1
fi
case "$ARM" in ""|jsround|pyround|jsalpha) ;; *) echo "unknown ARM=$ARM"; echo "$NAME RESULT FAIL"; exit 2 ;; esac

OUT="$SCRATCH/themectl_parity${ARM:+-$ARM}"
rm -rf "$OUT"
mkdir -p "$OUT/cfg/theme/themes"
SB="$OUT/tree"
SANDBOX="$SB" tools/dev/sandbox.sh > /dev/null || { echo "$NAME RESULT FAIL (no sandbox)"; exit 1; }
cleanup() { rm -rf "$SB" "$OUT/pytree"; }
trap cleanup EXIT

PYCTL="$SB/tools/theme/themectl"
if [ -n "$ARM" ]; then
    python3 - "$SB" "$ARM" "$OUT/pytree" <<'PY' || { echo "ARM $ARM: anchor not found exactly once"; echo "$NAME RESULT FAIL (arm)"; exit 2; }
import shutil, sys
root, arm, pytree = sys.argv[1:4]
js = root + "/modules/common/theme/ThemeResolve.js"
py = root + "/tools/theme/themectl"
if arm == "jsround":
    p, a, b = js, "    return [_rnd(rgb[0] * 255), _rnd(rgb[1] * 255), _rnd(rgb[2] * 255), c[3]];", "    return [Math.floor(rgb[0] * 255), _rnd(rgb[1] * 255), _rnd(rgb[2] * 255), c[3]];"
    # lighten and darken share this return: only the red channel's rounding moves, for both ops
elif arm == "jsalpha":
    p, a, b = js, '        return [c[0], c[1], c[2], _rnd(n * 255)];', '        return [c[0], c[1], c[2], Math.round(n * 255 - 1e-9)];'
elif arm == "pyround":
    p, a, b = py, "def _rnd(x):\n    return int(math.floor(x + 0.5))", "def _rnd(x):\n    return int(round(x))"
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PY
    echo "ARMED $ARM in the sandbox copy" >&2
fi

python3 -B tools/dev/themectl_resolver_parity.py gen "$OUT/parity.json"
cp "$OUT/parity.json" "$OUT/cfg/theme/themes/parity.json"
printf '{"theme":"parity","mode":"light"}\n' > "$OUT/cfg/theme/state.json"

for m in light dark; do
    python3 -B "$PYCTL" resolve --file "$OUT/parity.json" --l0 "$SB/modules/common/theme/Theme.qml" --mode "$m" > "$OUT/py_$m.json" 2> "$OUT/py_$m.err" \
        || { echo "themectl resolve ($m) failed: $(cat "$OUT/py_$m.err")"; echo "$NAME RESULT FAIL (no result: $OUT/py_$m.err)"; exit 1; }
done

log="$OUT/run.log"
( cd "$SB" && exec env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi \
    QS_DISABLE_FILE_WATCHER=1 QS_DISABLE_CRASH_HANDLER=1 XDG_CONFIG_HOME="$OUT/cfg" THR_FIXTURE="$OUT/parity.json" THR_OUT="$OUT/qml.json" \
    quickshell -p "$SB/tools/dev/qml/themectl_resolver_probe.qml" ) > "$log" 2>&1 &
pid=$!
i=0
while kill -0 "$pid" 2> /dev/null && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
kill -0 "$pid" 2> /dev/null && kill "$pid" 2> /dev/null
wait "$pid" 2> /dev/null
if ! rl_has "$log" "THR RESULT done" || [ ! -s "$OUT/qml.json" ]; then
    [ -n "$ARM" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing"
    rl_noresult "$NAME" "$log"
    exit 1
fi
rl_clean "$log" | grep -a -E "WARN|ERROR" | grep -v -E "quickshell.tooling|QT_QPA_PLATFORM" | head -5

if python3 -B tools/dev/themectl_resolver_parity.py compare "$OUT/py_light.json" "$OUT/py_dark.json" "$OUT/qml.json"; then
    echo "$NAME RESULT PASS"
    exit 0
fi
echo "$NAME RESULT FAIL${ARM:+ (ARM=$ARM)}"
exit 1
