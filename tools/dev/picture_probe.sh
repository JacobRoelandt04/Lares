#!/usr/bin/env bash
# picture_probe.sh -- PictureProbe (modules/common/components), the check behind every capture that feeds a picture (the sleep veil, the
# lock's S0): offscreen (QT_QUICK_BACKEND=rhi: the software scene graph draws no ShaderEffect), in a sandbox copy,
# tools/dev/qml/picture_probe.qml judges seven scenes copied as the captures copy (bright, dark, a patch, black, clear, faint, no source) and a
# copy judged twice (`held`).
#
#   tools/dev/picture_probe.sh             PICTURE_PROBE RESULT PASS | FAIL
#   ARM=noground   the black ground under the sample is taken away: a transparent copy is grabbed over nothing and reads as ink
#                  (the grab-of-a-transparent-item lie): the `faint` case must FAIL
#   ARM=anyink     every sample counts as ink (the threshold gone): `black` and `clear` must FAIL
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/pp.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
ARMCMD=""
case "${ARM:-}" in
    "") ;;
    noground) ARMCMD="python3 -c 'import sys; p=\"modules/common/components/PictureProbe.qml\"; s=open(p).read(); a=\"        color: \\\"black\\\"\n\"; assert s.count(a)==1, \"ANCHOR\"; open(p,\"w\").write(s.replace(a, \"        color: \\\"transparent\\\"\n\"))'" ;;
    anyink) ARMCMD="python3 -c 'import sys; p=\"modules/common/components/PictureProbe.qml\"; s=open(p).read(); a=\"> root.inkLevel;\"; assert s.count(a)==1, \"ANCHOR\"; open(p,\"w\").write(s.replace(a, \">= 0;\"))'" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi PP_DIR='"$D"' timeout 60 quickshell -p tools/dev/qml/picture_probe.qml'
tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'PP .*' | grep -a -v 'PP RESULT'
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -qE 'PP (clear|black|faint) .* FAIL'; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if ! rl_has "$D/log" 'PP RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL -- the probe cannot see it"; exit 1
fi
res=$(rl_result PICTURE_PROBE "$D/log" 'PP RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP_D=1; printf '%s\n' "$res"; exit 1; fi
printf '%s\n' "$res" | sed 's/^PP RESULT/PICTURE_PROBE RESULT/'
exit $rc
