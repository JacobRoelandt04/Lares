#!/usr/bin/env bash
# panorama_enginelink_probe.sh -- EngineLink (modules/panorama/data) against a STUB hyprctl and files in a private directory.
#
#   tools/dev/panorama_enginelink_probe.sh               ENGINELINK RESULT PASS | FAIL
#   ARM=nosession tools/dev/panorama_enginelink_probe.sh  another session's state file counts as an answer: the "another session" check goes red
#   ARM=noerror   tools/dev/panorama_enginelink_probe.sh  the text of an eval is not read (exit 0 = ok): the "error: boom" check goes red
#   ARM=nowarn    tools/dev/panorama_enginelink_probe.sh  a Lua warning is an error again: the "a Lua warning is no error" check goes red
#   ARM=noserial  tools/dev/panorama_enginelink_probe.sh  a newer state does not let a failure go: the "engine speaks after a failure" check goes red
#   ARM=nofresh   tools/dev/panorama_enginelink_probe.sh  a config that loads a file which is not there is the user's step again: the "fresh" check goes red
#   ARM=bracket   tools/dev/panorama_enginelink_probe.sh  a text that ends in "]" closes its own brackets: the cast_keep checks and "every call is Lua" go red
#
# After the run every chunk the stub was handed is compiled by the real `luac -p`: "every call is Lua". The stub records `eval <lua>` lines and answers `ok` (or `error: boom` while <dir>/fail exists, or a Lua warning while <dir>/warn does). Never the real hyprctl, never a session.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
export SANDBOX="${SANDBOX:-/tmp/lares-sbx-pano-engine}"
D="$(mktemp -d "${SCRATCH:-/tmp}/el.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
mkdir -p "$D/bin" "$D/rt/lares" "$D/hypr/config"
rmdir "$D/hypr/config"
cat > "$D/bin/hyprctl" <<STUB
#!/bin/sh
echo "\$1 \$2" >> "$D/hyprctl.log"
if [ -e "$D/fail" ]; then echo "error: boom"; elif [ -e "$D/warn" ]; then echo "warning: =[C]:-1: Monitor not found"; else echo ok; fi
exit 0
STUB
chmod +x "$D/bin/hyprctl"
arm() { printf '%s' "$1" > "$D/arm.from"; printf '%s' "$2" > "$D/arm.to"
        ARMCMD="python3 -c 'import sys; p=sys.argv[1]; a=open(sys.argv[2]).read(); b=open(sys.argv[3]).read(); s=open(p).read(); sys.exit(\"ARM anchor gone\") if s.count(a)!=1 else open(p,\"w\").write(s.replace(a,b))' modules/panorama/data/EngineLink.qml $D/arm.from $D/arm.to"; }
ARMCMD=""
case "${ARM:-}" in
    "") ;;
    nosession) arm 'parsed.session !== root._session' 'false' ;;
    noerror)   arm 'code !== 0 || (out.indexOf("ok") !== 0 && !warned)' 'code !== 0' ;;
    nowarn)    arm 'const warned = code === 0 && out !== ""' 'const warned = false && out !== ""' ;;
    noserial)  arm '(parsed.serial || 0) > root._errorSerial' 'false' ;;
    nofresh)   arm '[ $line -eq 0 ] && exit 4; exit 3' 'exit 3' ;;
    bracket)   arm '(text + "]").indexOf(' 'text.indexOf('; ARMCMD="${ARMCMD/EngineLink.qml/EngineGenerate.js}" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi HYPRLAND_INSTANCE_SIGNATURE=testsig EL_DIR='"$D"' EL_ENGINE="$PWD/tools/panorama/engine.lua" XDG_CONFIG_HOME='"$D"'/cfg XDG_CACHE_HOME='"$D"'/cache timeout 90 quickshell -p tools/dev/qml/panorama_enginelink_probe.qml'
mkdir -p "$D/cfg/theme"; printf '{"theme":"eva","mode":"light"}\n' > "$D/cfg/theme/state.json"
tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o -E 'EL (ok|FAIL) .*'
rl_clean "$D/log" | grep -a -E 'WARN|ERROR' | grep -a -v -i 'hyprland' | grep -a -v 'LARES panorama engine: error: \(boom\|.*not found\)' | grep -a -v 'LARES panorama engine warned: warning: =\[C\]:-1: Monitor not found' | head -5
# the stub answers `ok` to anything: a chunk that is no Lua is caught here, by the compiler Hyprland's library comes with
badlua=0; chunks=0
while IFS= read -r l; do
    chunks=$((chunks + 1))
    printf '%s' "${l#eval }" | luac -p - 2> "$D/luac.err" || { badlua=1; echo "EL FAIL every call is Lua: $(cat "$D/luac.err")  [${l#eval }]"; }
done < <(grep -a '^eval ' "$D/hyprctl.log" 2> /dev/null)
[ "$chunks" -ge 10 ] || { badlua=1; echo "EL FAIL every call is Lua: only $chunks calls were recorded"; }
[ "$badlua" = 0 ] && echo "EL ok   every call is Lua ($chunks chunks compiled)"
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -q 'EL FAIL'; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if ! rl_has "$D/log" 'EL RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; KEEP=1; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL -- the probe cannot see it"; exit 1
fi
res=$(rl_result ENGINELINK "$D/log" 'EL RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi
if [ "$badlua" != 0 ]; then echo "ENGINELINK RESULT FAIL (a call is not Lua)"; exit 1; fi
printf '%s\n' "$res" | sed 's/^EL RESULT/ENGINELINK RESULT/'
exit $rc
