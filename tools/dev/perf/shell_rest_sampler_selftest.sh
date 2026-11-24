#!/usr/bin/env bash
# shell_rest_sampler_selftest.sh -- the sampler (tools/dev/perf/shell_rest_sampler.py) against a process whose spikes are KNOWN: two named threads, one
# burning 200 ms of CPU every 3 s and one 150 ms every 5 s, a third that FORKS a program burning 150 ms every 4 s, a main thread asleep. The
# sampler must find the two threads BY NAME, count their bursts (7 and 4 in a 21 s run) and read their periods (3 s and 5 s); find the forked
# program's CPU as "(children reaped)" with its 4 s period and the program by name; the whole process, with three interleaved trains, has no
# steady period of its own.
#
#   tools/dev/perf/shell_rest_sampler_selftest.sh            ~25 s; ends in REST_SAMPLER_SELFTEST RESULT PASS|FAIL
#   ARM=blind tools/dev/perf/shell_rest_sampler_selftest.sh  the sampler is told a spike is 10000 % of a core: nothing is one -> the run must FAIL on "restA ... bursts"
#   ARM=merged tools/dev/perf/shell_rest_sampler_selftest.sh bursts closer than 100 s are one burst: no period can be read -> FAIL on "restA ... period"
#   ARM=nokids tools/dev/perf/shell_rest_sampler_selftest.sh a copy of the sampler that does not read cutime/cstime: the forked CPU is invisible -> FAIL on "found as (children reaped)"
#   ARM=trialany tools/dev/perf/shell_rest_sampler_selftest.sh a copy of the wrapper whose --trial takes any pid in the pid file as the trial shell -> FAIL on "refuses a pid that is no quickshell"
#   ARM=all                                              all four; REST_SAMPLER_SELFTEST ARMS PASS when each failed on its own check
#
# The wrapper's --trial is checked too (3 s): no pid file -> refused (exit 3); a pid file naming a process that is no quickshell running
# shell.qml -> refused; a stand-in named quickshell with shell.qml in its command line -> sampled. Only /proc is read.
#
# Nothing but the stand-in process runs; it is found by the pid this script keeps ($!), killed by it, and reads and writes nothing.
set -u
HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$HERE/tools/dev/result_lib.sh"
NAME=REST_SAMPLER_SELFTEST
ARM="${ARM:-}"
if [ "$ARM" = all ]; then
    bad=0
    for a in blind merged nokids trialany; do
        out=$(ARM=$a "$0" 2>&1)
        case $a in blind) want="restA bursts" ;; merged) want="restA period" ;; nokids) want="found as (children reaped)" ;; trialany) want="refuses a pid that is no quickshell" ;; esac
        if printf '%s\n' "$out" | grep -q "$NAME FAIL.*$want"; then echo "  ARM $a: FAILED AS IT MUST (on '$want')"
        else echo "  ARM $a: NOT PROVEN -- $(printf '%s\n' "$out" | tail -2 | tr '\n' ' ')"; bad=1; fi
    done
    [ "$bad" = 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
    echo "$NAME ARMS FAIL"; exit 1
fi
case "$ARM" in ""|blind|merged|nokids|trialany) ;; *) echo "unknown ARM=$ARM"; exit 2 ;; esac
W=$(mktemp -d "${SCRATCH:-/tmp}/restsampler.XXXXXX") || exit 2
PID=""
cleanup() { [ -n "$PID" ] && kill "$PID" 2> /dev/null; rm -rf "$W"; }
trap cleanup EXIT

cat > "$W/stand_in.py" << 'PY'
import ctypes, subprocess, sys, threading, time
libc = ctypes.CDLL(None)
def train(name, burst, every, offset):
    libc.prctl(15, name.encode(), 0, 0, 0)      # PR_SET_NAME: the kernel's thread name, what /proc/<pid>/task/<tid>/comm shows
    time.sleep(offset)
    while True:
        t = time.monotonic()
        while time.monotonic() - t < burst:
            pass
        time.sleep(every - burst)
threading.Thread(target=train, args=("restA", 0.20, 3.0, 0.5), daemon=True).start()
threading.Thread(target=train, args=("restB", 0.15, 5.0, 1.2), daemon=True).start()
def forker(every, offset):
    libc.prctl(15, b"restC", 0, 0, 0)
    time.sleep(offset)
    while True:
        t = time.monotonic()
        subprocess.run([sys.executable, "-I", "-c", "import time\nt = time.monotonic()\nwhile time.monotonic() - t < 0.15: pass"])
        time.sleep(max(0.0, every - (time.monotonic() - t)))
threading.Thread(target=forker, args=(4.0, 0.9), daemon=True).start()
libc.prctl(15, b"restMain", 0, 0, 0)
while True:
    time.sleep(1)
PY
python3 "$W/stand_in.py" &
PID=$!
sleep 0.5
args=(--spike-pct 20 --merge-ms 300)
[ "$ARM" = blind ] && args=(--spike-pct 10000 --merge-ms 300)
[ "$ARM" = merged ] && args=(--spike-pct 20 --merge-ms 100000)
SAMPLER="$HERE/tools/dev/perf/shell_rest_sampler.py"
if [ "$ARM" = nokids ]; then
    # a copy of the sampler that reads no children's CPU: the anchor must be there, or the arm proves nothing
    python3 - "$SAMPLER" "$W/sampler_nokids.py" << 'PY' || { echo "$NAME FAIL: ARM nokids anchor is gone from the sampler"; exit 2; }
import sys
s = open(sys.argv[1]).read()
a = "return int(rest[13]) + int(rest[14])          # cutime, cstime (fields 16, 17)"
if s.count(a) != 1:
    sys.exit(1)
open(sys.argv[2], "w").write(s.replace(a, "return 0"))
PY
    SAMPLER="$W/sampler_nokids.py"
fi
python3 "$SAMPLER" "$PID" 21 "${args[@]}" --json "$W/out.json" > "$W/out.txt" 2>&1
rc=$?
cat "$W/out.txt"
[ "$rc" = 0 ] || { echo "$NAME RESULT FAIL (the sampler said FAIL: $(tail -1 "$W/out.txt"))"; exit 1; }
python3 - "$W/out.json" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
th = {t["name"]: t for t in d["threads"]}
bad = []
def chk(label, ok, detail):
    print("%s %s %s" % ("REST_SAMPLER_SELFTEST", "ok  " if ok else "FAIL", label + (" (%s)" % detail)))
    if not ok: bad.append(label)
for name, n, per in (("restA", 7, 3.0), ("restB", 4, 5.0)):
    t = th.get(name)
    chk("%s is found by name" % name, t is not None, "threads: %s" % sorted(th))
    if not t:
        continue
    chk("%s bursts: %d (+-1) of its trains in 21 s" % (name, n), abs(t["bursts"] - n) <= 1, "%d" % t["bursts"])
    chk("%s period: %.1f s (+-15 %%)" % (name, per), t["period_s"] is not None and abs(t["period_s"] - per) <= 0.15 * per, str(t["period_s"]))
    chk("%s peak: it burned a whole core in an interval" % name, t["peak"] >= 80, str(t["peak"]))
kid = th.get("(children reaped)")
chk("the forked program's CPU is found as (children reaped)", kid is not None, "threads: %s" % sorted(th))
if kid:
    chk("children bursts: 5 (+-1) of the forked program's 4 s train in 21 s", abs(kid["bursts"] - 5) <= 1, "%d" % kid["bursts"])
    chk("children period: 4.0 s (+-15 %)", kid["period_s"] is not None and abs(kid["period_s"] - 4.0) <= 0.6, str(kid["period_s"]))
seen = {k["comm"]: k for k in d.get("children_seen", [])}
chk("the forked program is named (python3) and caught at least 4 times", any(c.startswith("python") and k["seen"] >= 4 for c, k in seen.items()), str(sorted((c, k["seen"]) for c, k in seen.items())))
chk("restMain stayed quiet (no bursts)", "restMain" not in th or th["restMain"]["bursts"] == 0, str(th.get("restMain")))
chk("the process's bursts name their carrier", any("restA" in " ".join(b.get("threads", {})) for b in d["bursts"]) or not d["bursts"], "%d bursts" % len(d["bursts"]))
if bad:
    print("REST_SAMPLER_SELFTEST FAIL: " + "; ".join(bad))
    sys.exit(1)
PY
prc=$?
# ---- --trial: the pid comes from the state dir's pid file and must be a quickshell running shell.qml
RTD="$W/rt"; mkdir -p "$RTD/lares"
WRAP="$HERE/tools/dev/perf/shell_rest_sampler.sh"
if [ "$ARM" = trialany ]; then   # a copy of the wrapper (HERE follows its place) without the check of what the pid is
    mkdir -p "$W/arm/tools/dev/perf"; cp "$HERE/tools/dev/perf/shell_rest_sampler.py" "$W/arm/tools/dev/perf/"
    python3 - "$HERE/tools/dev/perf/shell_rest_sampler.sh" "$W/arm/tools/dev/perf/shell_rest_sampler.sh" << 'PY' || { echo "$NAME FAIL: ARM trialany anchor is gone from the wrapper"; exit 2; }
import sys
s = open(sys.argv[1]).read()
a = 'if [ "$comm" != quickshell ] || [[ $args != *shell.qml* ]]; then'
if s.count(a) != 1:
    sys.exit(1)
open(sys.argv[2], "w").write(s.replace(a, "if false; then"))
PY
    WRAP="$W/arm/tools/dev/perf/shell_rest_sampler.sh"
fi
trial() { XDG_RUNTIME_DIR="$RTD" bash "$WRAP" --trial 2 2>&1; }
tout=$(trial); trc=$?
tchk() { echo "REST_SAMPLER_SELFTEST $([ "$1" = 1 ] && echo 'ok  ' || echo FAIL) $2 ($3)"; [ "$1" = 1 ] || prc=1; }
if [ "$trc" = 3 ] && printf '%s\n' "$tout" | grep -q "no running shell"; then tchk 1 "--trial refuses when there is no pid file" "exit 3"; else tchk 0 "--trial refuses when there is no pid file" "exit $trc: $(printf '%s\n' "$tout" | tail -1)"; fi
sleep 30 &
DUMMY=$!
echo "$DUMMY" > "$RTD/lares/pid"
tout=$(trial); trc=$?
kill "$DUMMY" 2> /dev/null
if [ "$trc" = 3 ] && printf '%s\n' "$tout" | grep -q "is no quickshell"; then tchk 1 "--trial refuses a pid that is no quickshell" "exit 3, said so"; else tchk 0 "--trial refuses a pid that is no quickshell" "exit $trc: $(printf '%s\n' "$tout" | tail -1)"; fi
python3 -c 'import ctypes, sys, time
ctypes.CDLL(None).prctl(15, b"quickshell", 0, 0, 0)
time.sleep(30)' shell.qml &
LARES_P=$!
sleep 0.4
echo "$LARES_P" > "$RTD/lares/pid"
tout=$(trial); trc=$?
kill "$LARES_P" 2> /dev/null
if [ "$trc" = 0 ] && printf '%s\n' "$tout" | grep -q "the user's trial shell pid $LARES_P"; then tchk 1 "--trial samples a quickshell running shell.qml" "pid $LARES_P"; else tchk 0 "--trial samples a quickshell running shell.qml" "exit $trc: $(printf '%s\n' "$tout" | head -1 | cut -c1-120)"; fi
if [ "$prc" = 0 ]; then echo "$NAME RESULT PASS (two thread trains and a forked program's train read back by name, count and period; --trial refuses what is no trial shell)"; exit 0; fi
echo "$NAME RESULT FAIL (the FAIL lines above)"
exit 1
