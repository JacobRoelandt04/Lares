#!/usr/bin/env bash
# wiki_empty_probe.sh -- an empty wiki pool says what it waits for (modules/wiki/WikiPopup.qml `_emptyWords`): the real WikiPopup on a
# stub service with no card; running / waiting for the GPU / offline / blocked each say so, and an idle pool never claims to be filled.
#
#   tools/dev/wiki_empty_probe.sh              WIKIEMPTY RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=<name> tools/dev/wiki_empty_probe.sh   one fault in the sandbox copy; must fail on its own check:
#   ARM=all ...  every arm in turn: WIKIEMPTY ARMS RESULT PASS when each failed on its own check
#     always    the words are always "being filled" again   -> "WE FAIL idle: just"
#     nopending a waiting batch is not said                -> "WE FAIL pending:"
#     nooffline a down network is not said                 -> "WE FAIL offline:"
#     noblocked a blocked GPU is not said                  -> "WE FAIL blocked:"
#     order     offline outranks a running batch           -> "WE FAIL priority:"
#     nobutton  the empty pool never offers to process      -> "WE FAIL button: idle"
#     alwaysbutton the button shows while a batch runs      -> "WE FAIL button: running"
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
if [ "${ARM:-}" = all ]; then   # every arm, each in a fresh sandbox sync; PASS only when each failed on its own needle
    rc=0
    for a in always nopending nooffline noblocked order nobutton alwaysbutton; do
        out=$(ARM="$a" bash "$0" 2>&1); printf '%s\n' "$out" | grep -a '^ARM ' | tail -1
        printf '%s\n' "$out" | grep -aq "^ARM $a: failed as it must" || rc=1
    done
    [ "$rc" -eq 0 ] && echo "WIKIEMPTY ARMS RESULT PASS" || echo "WIKIEMPTY ARMS RESULT FAIL"
    exit "$rc"
fi
D="$(mktemp -d "${SCRATCH:-/tmp}/we.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
P=modules/wiki/WikiPopup.qml
ARMCMD="" NEEDLE=""
case "${ARM:-}" in
    "") ;;
    always) ARMCMD="grep -q 'if (!s) return \"No articles yet\";' $P && sed -i 's|if (!s) return \"No articles yet\";|if (true) return \"No articles yet — the pool is being filled\";|' $P"
            NEEDLE='WE FAIL idle: just' ;;
    nopending) ARMCMD="grep -q 'if (s.batchPending) return' $P && sed -i 's|if (s.batchPending) return|if (false) return|' $P"
            NEEDLE='WE FAIL pending:' ;;
    nooffline) ARMCMD="grep -q 'if (s.offline) return' $P && sed -i 's|if (s.offline) return|if (false) return|' $P"
            NEEDLE='WE FAIL offline:' ;;
    noblocked) ARMCMD="grep -q 'if (b && b.blocked) return' $P && sed -i 's|if (b \&\& b.blocked) return|if (false) return|' $P"
            NEEDLE='WE FAIL blocked:' ;;
    order) ARMCMD="grep -q 'if (b && b.running) return' $P && sed -i 's|if (b \&\& b.running) return|if (!s.offline \&\& b \&\& b.running) return|' $P"
            NEEDLE='WE FAIL priority:' ;;
    nobutton) ARMCMD="grep -q 'return !(b && b.running) && !s.batchPending && !s.offline;' $P && sed -i 's|return !(b \&\& b.running) \&\& !s.batchPending \&\& !s.offline;|return false;|' $P"
            NEEDLE='WE FAIL button: idle' ;;
    alwaysbutton) ARMCMD="grep -q 'return !(b && b.running) && !s.batchPending && !s.offline;' $P && sed -i 's|return !(b \&\& b.running) \&\& !s.batchPending \&\& !s.offline;|return true;|' $P"
            NEEDLE='WE FAIL button: running' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
mkdir -p "$D/cfg/theme" "$D/state" "$D/cache"
printf '{"theme":"eva","mode":"light"}\n' > "$D/cfg/theme/state.json"
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi PROBE=1 XDG_CONFIG_HOME='"$D/cfg"' XDG_STATE_HOME='"$D/state"' XDG_CACHE_HOME='"$D/cache"' timeout 60 quickshell -p tools/dev/qml/wiki_empty_probe.qml'
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-wikiempty}" tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'WE .*' | grep -a -v 'WE RESULT'
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -q "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if ! rl_has "$D/log" 'WE RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; KEEP=1; echo "$D/log"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result WIKIEMPTY "$D/log" 'WE RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi
printf '%s\n' "$res" | sed 's/^WE RESULT/WIKIEMPTY RESULT/'
exit $rc
