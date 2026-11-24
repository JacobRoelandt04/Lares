#!/usr/bin/env bash
# osd_pill_open_probe.sh -- the fullscreen OSD pill's open (modules/osd/OsdPill.qml): tools/dev/qml/osd_pill_open_probe.qml offscreen
# (QT_QUICK_BACKEND=rhi) in a sandbox copy, a real present() of every kind sampled each animation frame, judged from the log and the
# ink pngs (tools/dev/osd_pill_open_judge.py).
#
#   tools/dev/osd_pill_open_probe.sh [OUT_DIR]       OSDPILLOPEN RESULT PASS | FAIL
#   KINDS=volume,track ...                           only these kinds
#   FILM=1 K=1.25 ...                                also grab every frame (OUT_DIR/film/<kind>/<n>_<ms>.png), no judging of the ink needed at 1.25
#   ARM=slowfade     the content fades in only at the end of the widening (pillFadeAt 1.0): "content readable by 260 ms" red
#   ARM=early        the fade starts at the first frame (pillFadeAt 0): "the capsule covers the ink" red
#   ARM=nooverlap    the widening starts only when the growth is done (pillOpenLeadMs 400): "one motion" red
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
mkdir -p "${SCRATCH:-/tmp}"
D="$(mktemp -d "${SCRATCH:-/tmp}/opo.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
OUT="${1:-$D/out}"
mkdir -p "$OUT" "$D/config/theme" "$D/state" "$D/cache"
printf '{"theme":"eva","mode":"%s"}\n' "${MODE:-light}" > "$D/config/theme/state.json"
if [ "${FILM:-0}" = 1 ]; then
    [ -n "${KINDS:-}" ] || { echo "FILM=1 needs KINDS=<kind,...>"; exit 2; }
    for k in ${KINDS//,/ }; do mkdir -p "$OUT/film/$k"; done
fi
F=modules/osd/OsdStyle.qml
case "${ARM:-}" in
    "") ARMCMD=true ;;
    slowfade) ARMCMD="sed -i 's|property real pillFadeAt: [0-9.]*|property real pillFadeAt: 1.0|' $F" ;;
    early)    ARMCMD="sed -i 's|property real pillFadeAt: [0-9.]*|property real pillFadeAt: 0.0|' $F" ;;
    nooverlap) ARMCMD="sed -i 's|property int pillOpenLeadMs: [0-9]*|property int pillOpenLeadMs: 400|' $F" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-osd-open}"
cat > "$D/run.sh" <<RUN_EOF
cp $F $D/orig.qml
$ARMCMD
if [ -n "${ARM:-}" ] && cmp -s $F $D/orig.qml; then echo ARMLOST; exit 3; fi
env XDG_CONFIG_HOME=$D/config XDG_STATE_HOME=$D/state XDG_CACHE_HOME=$D/cache QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi \
    QML_DISABLE_DISTANCEFIELD=1 WAYLAND_DISPLAY= HYPRLAND_INSTANCE_SIGNATURE= LARES_SLEEP_MONITOR=off OUT_DIR=$OUT K=${K:-1} FILM=${FILM:-0} KINDS=${KINDS:-} \
    timeout 180 quickshell -p tools/dev/qml/osd_pill_open_probe.qml
RUN_EOF
tools/dev/sandbox.sh bash "$D/run.sh" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'OPO .*' > "$OUT/opo.log"
if ! grep -aq 'OPO done' "$OUT/opo.log"; then
    cp "$D/log" "$OUT/raw.log"; echo "OSDPILLOPEN RESULT FAIL (no result: $OUT/raw.log)"; exit 1
fi
if [ "${FILM:-0}" = 1 ]; then echo "OSDPILLOPEN RESULT PASS (film in $OUT)"; exit 0; fi
python3 tools/dev/osd_pill_open_judge.py "$OUT" "${K:-1}" "${ARM:-}"
