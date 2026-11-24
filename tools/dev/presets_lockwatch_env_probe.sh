#!/usr/bin/env bash
# presets_lockwatch_env_probe.sh -- the presets' lock watch (modules/presets/data/PresetLockWatch.js) in a real compositor: a nested Hyprland
# (tools/dev/lock_env.sh) with two kitties in one group, the watch's own expressions dispatched as the shell dispatches them
# (`Hyprland.dispatch(expr)` is `hl.dispatch(expr)`), socket2 read with socat. Hyprland announces a group's lock nowhere (no socket2 event,
# no `hl.on` hook: 0.57.2), so the watch is the only way the save card hears it.
#
#   tools/dev/presets_lockwatch_env_probe.sh              PRESETS_LOCKWATCH RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=<name> tools/dev/presets_lockwatch_env_probe.sh   passes when the check it aims at FAILS (ARM=all: every one):
#     blind      the look reads no lock                         -> "a lock toggled while watched is told"
#     nolease    the lease never runs out                        -> "the lease runs out"
#     nostop     stop() changes nothing                          -> "a stopped watch is silent"
#     rebase     a start while one runs takes a new baseline     -> "a renewal right after a lock loses nothing"
#
# Every case reads the JS with node (the file the shell imports), in a scratch copy for an ARM. Nothing of the user's is touched.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
if [ "${ARM:-}" = all ]; then
    rc=0
    for a in blind nolease nostop rebase; do o=$(ARM=$a "$0" | tail -1); echo "$o"; case "$o" in *"failed as it must") ;; *) rc=1 ;; esac; done
    [ $rc = 0 ] && echo "PRESETS_LOCKWATCH ARMS PASS" || echo "PRESETS_LOCKWATCH ARMS FAIL"; exit $rc
fi
mkdir -p "${SCRATCH:-/tmp}"
D="$(mktemp -d "${SCRATCH:-/tmp}/plw.XXXXXX")"
export LOCK_ENV="${LOCK_ENV:-presetlw}"
cleanup() { tools/dev/lock_env.sh down > /dev/null 2>&1; [ -n "${KEEP:-}" ] || rm -rf "$D"; }
trap cleanup EXIT
JS="$D/PresetLockWatch.js"
cp modules/presets/data/PresetLockWatch.js "$JS"
A="" B="" NEEDLE=""
case "${ARM:-}" in
    "") ;;
    blind)     A='(g.locked and \"1\" or \"0\")'; B='\"0\"'; NEEDLE="a lock toggled while watched is told" ;;
    nolease)   A='"W.left = W.left - 1 " +'; B='"W.left = W.left " +'; NEEDLE="the lease runs out" ;;
    nostop)    A='LARES_PRESET_LOCKS.left = 0'; B='LARES_PRESET_LOCKS.left = LARES_PRESET_LOCKS.left'; NEEDLE="a stopped watch is silent" ;;
    rebase)    A='"if W.alive then return hl.dsp.no_op() end " +'; B='"" +'; NEEDLE="a renewal right after a lock loses nothing" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
if [ -n "${ARM:-}" ]; then
    printf '%s' "$A" > "$D/a"; printf '%s' "$B" > "$D/b"
    python3 - "$JS" "$D/a" "$D/b" <<'PY' || { echo "ARM $ARM: its anchor is gone -- it proves nothing"; exit 1; }
import sys
p, a, b = sys.argv[1], open(sys.argv[2]).read(), open(sys.argv[3]).read()
s = open(p).read()
if s.count(a) != 1:
    raise SystemExit(1)
open(p, "w").write(s.replace(a, b))
PY
fi
# the expressions, as the shell builds them; a short lease for the lease case (the real one is 120 s)
cat > "$D/expr.js" <<'JS_EOF'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8").replace(".pragma library", "");
const m = {};
new Function("exports", src + "\nexports.start = start; exports.stop = stop; exports.EVENT = EVENT; exports.setLease = function (n) { LEASE = n; };")(m);
if (process.argv[4]) m.setLease(Number(process.argv[4]));
console.log(process.argv[3] === "stop" ? m.stop() : process.argv[3] === "event" ? m.EVENT : m.start());
JS_EOF
START=$(node "$D/expr.js" "$JS" start) && STOP=$(node "$D/expr.js" "$JS" stop) && SHORT=$(node "$D/expr.js" "$JS" start 4) \
    && EVENT=$(node "$D/expr.js" "$JS" event) || { echo "PRESETS_LOCKWATCH RESULT FAIL (node could not read PresetLockWatch.js)"; exit 1; }

OUTPUTS=1 tools/dev/lock_env.sh up > "$D/up.log" 2>&1 || { cat "$D/up.log"; echo "PRESETS_LOCKWATCH RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
H() { tools/dev/lock_env.sh hyprctl "$@"; }
EV="$D/ev.log"; : > "$EV"
tools/dev/lock_env.sh run sh -c 'exec socat -u UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock -' > "$EV" 2>&1 &
for i in 1 2; do tools/dev/lock_env.sh run kitty -o remember_window_size=no > /dev/null 2>&1 & sleep 0.8; done
addrs=""
for i in $(seq 1 50); do
    addrs=$(H -j clients 2> /dev/null | python3 -c 'import json,sys; print(" ".join(c["address"] for c in json.load(sys.stdin) if c["class"] == "kitty"))' 2> /dev/null)
    [ "$(printf '%s\n' $addrs | grep -c .)" -ge 2 ] && break; sleep 0.2
done
set -- $addrs
[ $# -ge 2 ] || { echo "PRESETS_LOCKWATCH RESULT FAIL (two kitties did not come up: $addrs)"; exit 1; }
WA=$1 WB=$2
H dispatch "hl.dsp.group.toggle({ window = \"address:$WA\" })" > /dev/null
H eval "hl.get_window(\"address:$WA\").group:add(hl.get_window(\"address:$WB\"))" > /dev/null
sleep 0.5

pass=0 total=0
OUT="$D/out"; : > "$OUT"
check() { total=$((total + 1)); if [ "$1" = 0 ]; then pass=$((pass + 1)); echo "PLW ok $2" | tee -a "$OUT"; else echo "PLW FAIL $2" | tee -a "$OUT"; fi; }
# A window of the event stream is cut by a MARK sent through socket2 itself (`custom>>plw-mark-<k>`), never by the wall clock: the nested
# compositor answers hyprctl between its frames and its timers run late, so a sleep cuts the stream in the wrong place.
k=0
mark() { k=$((k + 1)); H dispatch "hl.dsp.event(\"plw-mark-$k\")" > /dev/null
    for i in $(seq 1 100); do grep -a -q "^custom>>plw-mark-$k\$" "$EV" && return 0; sleep 0.05; done; return 1; }
# the watch's words between the last mark and a new one, sent after `settle` s (a few of the watch's 500 ms ticks)
since() { local from=$k; C=99; sleep "$1"; mark || return 0
    sed -n "/^custom>>plw-mark-$from\$/,/^custom>>plw-mark-$k\$/p" "$EV" > "$D/win.$total"
    [ "$from" = 0 ] && sed -n "1,/^custom>>plw-mark-$k\$/p" "$EV" > "$D/win.$total"
    C=$(grep -a -c "^custom>>$EVENT\$" "$D/win.$total"); }
lock() { H dispatch "hl.dsp.group.lock({ window = \"address:$WA\", action = \"toggle\" })" > /dev/null; }
grouped=$(H -j clients | python3 -c 'import json,sys; print(max(len(c["grouped"]) for c in json.load(sys.stdin)))')
check "$([ "$grouped" = 2 ] && echo 0 || echo 1)" "setup: the two kitties are one group ($grouped)"

mark
lock; since 1.2; c=$C
check "$([ "$c" = 0 ] && echo 0 || echo 1)" "an unwatched lock is told nowhere: Hyprland itself sends nothing ($c)"
H dispatch "$START" > /dev/null; since 1.2; c=$C
check "$([ "$c" = 0 ] && echo 0 || echo 1)" "a start alone tells nothing: its first look is the baseline ($c)"
lock; since 1.4; c=$C
check "$([ "$c" = 1 ] && echo 0 || echo 1)" "a lock toggled while watched is told, once ($c)"
# the lock and the renewal in ONE chunk, so no tick of the watch falls between them
H eval "hl.dispatch(hl.dsp.group.lock({ window = \"address:$WA\", action = \"toggle\" })) hl.dispatch($START)" > /dev/null; since 1.4; c=$C
check "$([ "$c" = 1 ] && echo 0 || echo 1)" "a renewal right after a lock loses nothing: one lock, one word ($c)"
H dispatch "hl.dsp.group.toggle({ window = \"address:$WB\" })" > /dev/null; since 1.4; c=$C
check "$([ "$c" -ge 1 ] && echo 0 || echo 1)" "a group broken up is told too ($c)"
H dispatch "hl.dsp.group.toggle({ window = \"address:$WA\" })" > /dev/null
H eval "hl.get_window(\"address:$WA\").group:add(hl.get_window(\"address:$WB\"))" > /dev/null; sleep 0.3
H dispatch "$STOP" > /dev/null; sleep 1; mark
lock; since 1.4; c=$C
check "$([ "$c" = 0 ] && echo 0 || echo 1)" "a stopped watch is silent ($c)"
H dispatch "$SHORT" > /dev/null; sleep 3.5; mark
lock; since 1.4; c=$C
check "$([ "$c" = 0 ] && echo 0 || echo 1)" "the lease runs out: a watch nobody renews goes quiet ($c)"
H dispatch "$START" > /dev/null; sleep 0.8; lock; since 1.4; c=$C
check "$([ "$c" = 1 ] && echo 0 || echo 1)" "a watch started again after its lease ran out tells again ($c)"
H dispatch "$STOP" > /dev/null

res="PRESETS_LOCKWATCH RESULT $([ "$pass" = "$total" ] && echo PASS || echo FAIL) ($pass/$total checks)"
if [ -n "${ARM:-}" ]; then
    if grep -a -q "^PLW FAIL $NEEDLE" "$OUT"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it ($res)"; exit 1
fi
echo "$res"
[ "$pass" = "$total" ]
