#!/usr/bin/env bash
# boost_client_probe.sh -- BoostClient (modules/silicon/data): the shell's side of the interaction boost, against a STUB of
# `silicon-helper boost-serve` (tools/dev/fixtures/boost/stub_server.py: a unix socket in a private directory that answers
# `ok <ms>` and logs each line). Nothing of the machine is touched: no /run, no sysfs, no root service.
#
#   tools/dev/boost_client_probe.sh               BOOST_CLIENT RESULT PASS | FAIL
#   ARM=norate tools/dev/boost_client_probe.sh    every kick is written (no rate limit): the "write nothing" check and the
#                                                 stub's log go red
#   ARM=noclose                                   the key going off leaves the connection open: "the key off closes the
#                                                 connection" goes red (the stub has seen no close while the shell runs)
#
# Checks: the lazy connection carries the first ask; asks a boost already asked would outlast write nothing; a longer one
# is written; a missing socket and a key that is off write nothing; the key going off closes the connection. Then the
# stub's log must hold exactly `boost 300`, `boost 800`, CLOSE, and the shell's log one `LARES boost` line per client
# state (on, absent, off twice: the third client and the first one's key going off) and no socket error.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/bc.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
ARMCMD=""
case "${ARM:-}" in
    "") ;;
    norate) ARMCMD="grep -q '        if (now + want <= root._until)' modules/silicon/data/BoostClient.qml && sed -i 's|        if (now + want <= root._until)|        if (false)|' modules/silicon/data/BoostClient.qml" ;;
    noclose) ARMCMD="grep -q '            root._close();  // the server puts' modules/silicon/data/BoostClient.qml && sed -i 's|            root._close();  // the server puts|            root._pending = 0;  // ARM|' modules/silicon/data/BoostClient.qml" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
run='set -e; '"${ARMCMD:+$ARMCMD; }"'python3 tools/dev/fixtures/boost/stub_server.py '"$D/sock $D/stub.log"' & sp=$!; trap "kill $sp 2>/dev/null" EXIT
for i in $(seq 100); do [ -S '"$D/sock"' ] && break; sleep 0.05; done
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi BC_SOCK='"$D/sock"' BC_LOG='"$D/stub.log"' timeout 60 quickshell -p tools/dev/qml/boost_client_probe.qml
sleep 0.3'
tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'BC .*' | grep -a -v 'BC RESULT'
fails=0
stub=$(tr '\n' '|' < "$D/stub.log" 2> /dev/null)
# (that the close came from the key going off, not from quickshell's exit, is the QML's own check: it reads this log live)
if [ "$stub" = "boost 300|boost 800|CLOSE|" ]; then echo "BC ok   the stub got exactly: boost 300, boost 800, then the close"
else echo "BC FAIL the stub got: ${stub:-nothing} (want boost 300|boost 800|CLOSE|)"; fails=$((fails + 1)); fi
# each client says its state once (live: on, then off when its key goes off; missing: absent; off: off), never per kick
for want in on:1 absent:1 off:2; do
    s=${want%:*} k=${want#*:}
    n=$(rl_clean "$D/log" | grep -a -c "LARES boost $s\$")
    if [ "$n" -eq "$k" ]; then echo "BC ok   $k 'LARES boost $s' line(s)"; else echo "BC FAIL $n 'LARES boost $s' lines (want $k)"; fails=$((fails + 1)); fi
done
if rl_clean "$D/log" | grep -a -i -E "socket.*error|QLocalSocket|ServerNotFound|PeerClosed" > "$D/errs"; then
    echo "BC FAIL socket errors in the log:"; sed 's/^/    /' "$D/errs"; fails=$((fails + 1))
else echo "BC ok   no socket error in the log"; fi
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -q 'BC FAIL' || [ "$fails" -gt 0 ]; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if ! rl_has "$D/log" 'BC RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL -- the probe cannot see it"; exit 1
fi
res=$(rl_result BOOST_CLIENT "$D/log" 'BC RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP_D=1; printf '%s\n' "$res"; exit 1; fi
if [ "$fails" -gt 0 ] || [ "$rc" -ne 0 ]; then
    echo "BOOST_CLIENT RESULT FAIL (${res#BC RESULT }; $fails runner check(s) red)"; exit 1
fi
printf '%s\n' "$res" | sed 's/^BC RESULT/BOOST_CLIENT RESULT/'
exit 0
