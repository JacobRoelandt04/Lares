#!/usr/bin/env bash
# wiki_veil_cost.sh -- what a moving wiki veil costs in the real shell: shell.qml with mock services in tools/dev/lock_env.sh's
# nested Hyprland (a copy of the tree; nothing of the desktop is touched), the clock popup's wiki card opened the way a
# notification's click opens it, and the shell's own CPU, frames a second and frame times read while it stands there.
#
#   tools/dev/wiki_veil_cost.sh [SECONDS]        one shell per case, SECONDS (20) of sampling each:
#       closed        the shell at rest, no popup
#       photo         the wiki card on a photograph (nothing moves)
#       <pattern>     the wiki card on a veil of that pattern, at WikiVeilStyle's own fps
#   CASES="closed photo maze" ...               a subset     FPS=<n>   the veils at another frame rate
#   WVC_PATCH=<script>  an ablation: a bash script run in the copy first (cwd = the copy), e.g. a sed that turns a layer off
#   WVC_SHOT=<dir>  a screenshot of the nested output per case, before it is sampled (the real engine's picture)
#   WVC_KEEP=1 keeps the work dir (the logs). (Not KEEP: that one is lock_env's, and keeps the whole nested session.)
#
# A MEASUREMENT (exclusive tier: a quiet machine, nothing beside it): `WIKI_VEIL_COST RESULT PASS` says every case was read, not
# that the figures are fine. Read the load beside them. Per case:
#   cpu       the shell process, % of one core, all threads (utime + stime from /proc/<pid>/stat)
#   fps       frames the render thread finished a second (QSG_RENDER_TIMING's lines in the window)
#   passes    render passes a second: the window's own and one per layer or capture that was drawn again
#   render    their mean and worst render time, ms
#   first     the worst frame in the 4 s after the card was asked for: a veil's shader is compiled then (a cold cache: the
#             env's own)
#   gpu       the WHOLE GPU's busy share where nvidia-smi answers (the desktop's own drawing is in it): only the difference
#             between cases says anything
{
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SECS="${1:-20}"
SCRATCH="${SCRATCH:-/tmp}"
SANDBOX="${SANDBOX:-$SCRATCH/lares-sbx-wikicost}"
if [ -e "$HERE/.git" ] && [ -z "${WVC_INNER:-}" ]; then
    # inside a sandbox copy (a quickshell started in the tree would rewrite its .qmlls.ini); the offscreen words give the copy
    # its private runtime dir, lock_env's own session carries its own platform
    SANDBOX="$SANDBOX" SCRATCH="$SCRATCH" exec "$HERE/tools/dev/sandbox.sh" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi WVC_INNER=1 \
        CASES="${CASES:-}" FPS="${FPS:-}" WVC_SHOT="${WVC_SHOT:-}" WVC_KEEP="${WVC_KEEP:-}" WVC_PATCH="${WVC_PATCH:-}" bash tools/dev/wiki_veil_cost.sh "$SECS"
fi
cd "$HERE" || exit 1
. tools/dev/result_lib.sh
# this half patches the shell's hooks (modules/shell/ShellMain.qml) and the veil's style: only ever in a sandbox copy, never in the tree
# (a copy has no .git: started inside one -- a gate's sandbox -- this file IS the inner half)
[ -e .git ] && { echo "WIKI_VEIL_COST RESULT FAIL (the inner half was started in the git tree: start it without WVC_INNER)"; exit 1; }
# from here on this tree IS the sandbox copy (the guard above): SB names it, so no line below can mean the git tree
SB="$HERE"
E="$SB/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-wkcost}"
D="$(mktemp -d "$SCRATCH/wvc.XXXXXX")"
QPID=""
cleanup() {
    [ -n "$QPID" ] && kill "$QPID" 2> /dev/null
    "$E" down > /dev/null 2>&1
    [ -n "${WVC_KEEP:-}" ] || rm -rf "$D"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

# the hook: the wiki card asked for as a notification's click asks (the mock's scenario first)
python3 -B - <<'PY' || { echo "WIKI_VEIL_COST RESULT FAIL (the hook did not go in)"; exit 1; }
import sys
p = "modules/shell/ShellMain.qml"
s = open(p, encoding="utf-8").read()
a = '            case "secret":'
if s.count(a) != 1:
    print("hook() anchor gone"); sys.exit(1)
b = '''            case "wikiopen": {
                const w = arg.split(":");
                shellServices.wiki.scenario = w[0];
                shellServices.wiki.openRequested(w[1]);
                return "asked";
            }
'''
open(p, "w", encoding="utf-8").write(s.replace(a, b + a))
PY
# an ablation: a script run in the copy before any shell starts (cwd = the copy), to turn one thing off and read again
if [ -n "${WVC_PATCH:-}" ]; then
    bash "$WVC_PATCH" || { echo "WIKI_VEIL_COST RESULT FAIL (the ablation's patch failed: $WVC_PATCH)"; exit 1; }
    echo "WIKI_VEIL_COST ablation: $WVC_PATCH"
fi
cp modules/wiki/WikiVeilStyle.qml "$D/style.orig"
ipc() { "$E" run quickshell ipc -p "$SB/shell.qml" call shell "$@" 2> /dev/null; }
ticks() { awk '{ print $14 + $15 }' "/proc/$1/stat" 2> /dev/null; }
HZ=$(getconf CLK_TCK)
rc=0
printf 'WIKI_VEIL_COST load at the start: %s\n' "$(cut -d' ' -f1-3 /proc/loadavg)"
for c in ${CASES:-closed photo contours links ripples maze cells}; do
    cp "$D/style.orig" modules/wiki/WikiVeilStyle.qml
    case "$c" in
        closed|photo) ;;
        *) grep -q 'property string only: ""' modules/wiki/WikiVeilStyle.qml || { echo "WIKI_VEIL_COST RESULT FAIL (the style's anchor is gone)"; exit 1; }
           sed -i "s|property string only: \"\"|property string only: \"$c\"|" modules/wiki/WikiVeilStyle.qml ;;
    esac
    [ -n "${FPS:-}" ] && sed -i "s|property real fps: [0-9.]*|property real fps: $FPS|" modules/wiki/WikiVeilStyle.qml
    "$E" down > /dev/null 2>&1
    OUTPUTS=1 LOCK_REFRESH=120 "$E" up > "$D/up.log" 2>&1 || { tail -3 "$D/up.log"; echo "WIKI_VEIL_COST RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
    "$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })' > /dev/null
    LOG="$D/$c.log"
    "$E" run env SHELL_SERVICES=mock SHELL_FOCUS=live MOCKUP_REPO= QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 QSG_RENDER_TIMING=1 \
        quickshell -n -p "$SB/shell.qml" > "$LOG" 2>&1 &
    QPID=$!
    for _ in $(seq 1 600); do
        grep -aq "LARES settled" "$LOG" 2> /dev/null && break
        kill -0 "$QPID" 2> /dev/null || break
        sleep 0.3
    done
    if ! grep -aq "LARES settled" "$LOG"; then cp "$LOG" "$SCRATCH/wvc-failed-$c.log"; rl_noresult WIKI_VEIL_COST "$SCRATCH/wvc-failed-$c.log"; exit 1; fi
    sleep 3
    asked=$(wc -c < "$LOG")
    case "$c" in
        closed) ;;
        photo) ipc hook wikiopen normal:discover > /dev/null ;;
        *) ipc hook wikiopen noImage:deepen > /dev/null ;;
    esac
    sleep 4
    if [ "$c" != closed ]; then
        open=$(ipc probe | python3 -c 'import json, sys
try:
    d = json.loads(sys.stdin.read()); d = json.loads(d) if isinstance(d, str) else d
    print(json.dumps(d).count("\"wikiPopupOpen\": true"))
except Exception:
    print(0)')
        [ "${open:-0}" -ge 1 ] || { echo "WIKI_VEIL_COST $c: the wiki card did not open"; rc=1; }
    fi
    [ -n "${WVC_SHOT:-}" ] && { mkdir -p "$WVC_SHOT"; "$E" shot "$WVC_SHOT/$c.png" > /dev/null 2>&1; }
    from=$(wc -c < "$LOG"); t0=$(ticks "$QPID"); w0=$(date +%s.%N)
    gpu=""
    for _ in $(seq 1 "$SECS"); do
        sleep 1
        g=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2> /dev/null | head -1)
        [ -n "$g" ] && gpu="$gpu $g"
    done
    t1=$(ticks "$QPID"); w1=$(date +%s.%N)
    python3 -B - "$c" "$LOG" "$asked" "$from" "$t0" "$t1" "$w0" "$w1" "$HZ" "$gpu" <<'PY'
import re, sys
c, log, asked, frm, t0, t1, w0, w1, hz, gpu = sys.argv[1:]
data = open(log, "rb").read()
def renders(chunk):
    return [float(m) for m in re.findall(rb"render=(\d+(?:\.\d+)?)", chunk)]
first = renders(data[int(asked):int(frm)])
win = renders(data[int(frm):])
secs = float(w1) - float(w0)
cpu = 100.0 * (float(t1) - float(t0)) / float(hz) / secs
g = [float(x) for x in gpu.split()]
passes = len(re.findall(rb"time in renderer:", data[int(frm):]))
print("WIKI_VEIL_COST %-9s cpu %5.1f %%   fps %5.1f   passes %5.1f /s   render mean %4.1f ms worst %3.0f ms   first %3.0f ms%s"
      % (c, cpu, len(win) / secs, passes / secs, (sum(win) / len(win)) if win else 0, max(win) if win else 0, max(first) if first else 0,
         ("   gpu %2.0f %% (whole GPU)" % (sum(g) / len(g))) if g else ""))
PY
    kill "$QPID" 2> /dev/null; wait "$QPID" 2> /dev/null; QPID=""
done
printf 'WIKI_VEIL_COST load at the end: %s\n' "$(cut -d' ' -f1-3 /proc/loadavg)"
[ "$rc" = 0 ] && echo "WIKI_VEIL_COST RESULT PASS (a measurement: every case was read)" || echo "WIKI_VEIL_COST RESULT FAIL"
exit $rc
}
