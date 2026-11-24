#!/usr/bin/env bash
# tools/dev/cast_service_probe.sh -- the real CastService (live) on a STUB tool (tools/dev/fixtures/cast/cast_stub_tool) and CastMock, offscreen in a
# sandbox copy, private homes (tools/dev/qml/cast_service_probe.qml has the checks). Nothing here reaches fluxcast, Hyprland or NetworkManager.
#
#   tools/dev/cast_service_probe.sh          ends in CAST_SERVICE RESULT PASS|FAIL
#   ARM=doubleended | scanwhilecast | restarts | nostopstate | alwayspublish | statsinmodel     the fault in the copy; the run must FAIL on its own check
#     doubleended   `ended` is emitted for every end line (no latch)        -> "s10 two `ended` lines make ONE ended signal"
#     scanwhilecast a scan is accepted while casting                        -> "s3 a scan while casting is refused"
#     restarts      a tool that exits without a word is started again       -> "step 7 finishes in time" (the start is repeated for ever)
#     nostopstate   stop() does not say stopping at once                    -> "s3 stop: stopping at once"
#     alwayspublish the figures are published with nobody looking            -> "s3 nobody shows the figures"
#     statsinmodel  a beat goes through the cast's model too                 -> "s3 every beat is published while held"
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
export SANDBOX="${SANDBOX:-/tmp/lares-sbx-pano-c1}"
D="$(mktemp -d "${SCRATCH:-/tmp}/csvc.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
mkdir -p "$D/cfg/theme" "$D/state" "$D/cache"
printf '{"theme":"eva","mode":"light"}\n' > "$D/cfg/theme/state.json"
f=modules/panorama/data/CastService.qml
case "${ARM:-}" in
    "") from=""; to="" ;;
    doubleended) from='        if (next.ended !== "" && !root._endedSent) {'; to='        if (next.ended !== "") {' ;;
    scanwhilecast) from='        if (!root.live || !root.enabled || root._scanning || CP.active(root._m))
            return false;
        root._scanning = true;'; to='        if (!root.live || !root.enabled || root._scanning)
            return false;
        root._scanning = true;' ;;
    restarts) from='                root._finish({ event: "ended", code: root._exitCode });'; to='                { root._finish({ event: "ended", code: root._exitCode }); root.start(root._m.device, root._m.monitor, {}); }' ;;
    alwayspublish) f=modules/panorama/data/CastStats.qml; from='        root._value = root._holds > 0 ? root._known.figures : null;'; to='        root._value = root._known.figures;' ;;
    statsinmodel) from='        if (ev.event === "stats")
            return;'; to='' ;;
    nostopstate) from='        root._m = CP.requestStop(root._m);
        if (root._castProc !== null'; to='        if (root._castProc !== null' ;;
    *) echo "CAST_SERVICE RESULT FAIL (unknown ARM $ARM)"; exit 1 ;;
esac
printf '%s' "$from" > "$D/from"; printf '%s' "$to" > "$D/to"
arm='python3 -c "import sys; p=sys.argv[1]; a=open(sys.argv[2]).read(); b=open(sys.argv[3]).read(); s=open(p).read(); sys.exit(\"ARM anchor gone\") if s.count(a)!=1 else open(p,\"w\").write(s.replace(a,b))" '"$f $D/from $D/to"
run='set -e; '"${ARM:+$arm; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi CAST_STUB="$PWD/tools/dev/fixtures/cast/cast_stub_tool" XDG_CONFIG_HOME='"$D"'/cfg XDG_STATE_HOME='"$D"'/state XDG_CACHE_HOME='"$D"'/cache timeout 120 quickshell -p tools/dev/qml/cast_service_probe.qml'
tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a '^ *DEBUG qml: CS ' | sed 's/^ *DEBUG qml: //' | grep -v 'CS RESULT'
rl_clean "$D/log" | grep -a -E '^\s*(WARN|ERROR)' | grep -a -v -E 'QT_QPA_PLATFORM|window masks|WAYLAND_DISPLAY|actually running' | head -5
if [ -n "${ARM:-}" ]; then
    rl_has "$D/log" 'ARM anchor gone' && { echo "CAST_SERVICE RESULT FAIL (ARM $ARM: its anchor is gone)"; exit 1; }
    if rl_has "$D/log" 'CS FAIL'; then echo "ARM $ARM: failed as it must"; echo "CAST_SERVICE RESULT FAIL (armed $ARM)"; exit 1; fi
    echo "ARM $ARM: STILL PASSES"; echo "CAST_SERVICE RESULT PASS (armed $ARM: the arm did not bite)"; exit 0
fi
res=$(rl_clean "$D/log" | grep -a -o 'CS RESULT .*' | tail -1)
[ -z "$res" ] && { KEEP=1; rl_noresult CAST_SERVICE "$D/log"; exit 1; }
echo "CAST_SERVICE ${res#CS }"
case "$res" in "CS RESULT PASS"*) exit 0 ;; *) exit 1 ;; esac
