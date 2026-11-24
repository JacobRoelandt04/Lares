#!/usr/bin/env bash
# start_split.sh -- how long the shell takes to START, split into phases: the mock shell (shell.qml, mock services) in
# tools/dev/lock_env.sh's nested Hyprland, started N times in one session with --log-times, each run killed once it said `LARES ready`.
#
#   tools/dev/perf/start_split.sh <outdir>
#   SPECS="new:warm new:cold new:off"   the runs of ONE round, interleaved; ROUNDS=5 rounds. A spec is <tree>:<cache>[:qs]
#       tree   new = the tree this runner stands in (its sandbox copy); any other name = TREE_<name>=<dir> (a copy of another
#              revision: `git archive <rev> | tar -x -C <dir>`)
#       cache  warm = one QML disk cache per tree kept across the runs (primed by one unreported run first)
#              cold = an empty cache dir every run;  off = QML_DISABLE_DISK_CACHE=1
#       -<m>   shell.jsonc `"modules": { "<m>": false }` for that run (an ablation: what the module costs at start)
#       qs     LARES_FILE_ROOT=0 for that run (shell.jsonc `"workarounds": { "fileRoot": false }` as lares-supervise passes it:
#              the stub loads the body on qs: as before, after Quickshell's scan of the whole tree)
#   SHELL_JSONC_FILE  the shell's config (a copy; the user's for the laptop's conditions)   SCALE=1.25
#
# Phases per run (whole ms of quickshell's --log-times): launch (the process's start, the runner's clock) -> `Launching config` ->
# the first `qml:` line (the files are loaded and compiled: everything before it is the type loader) -> `LARES shown` (the first
# window whole) -> `LARES ready`. Also counted per run: the disk cache's refusals (`File has to be a local file`, with
# qt.qml.diskcache.debug on: COUNT_DISKCACHE=1 -- a debug category costs time, so off for timing). LOG_RULES=<rules> adds
# quickshell --log-rules (a look, not a timing); SS_ENV="A=1 B=2" more environment for every run (QSG_RENDER_TIMING=1 ...);
# SS_PATCH=<script> is run in the sandbox copy (cwd) before the runs: an ablation of the new tree. Ends in one table (median and
# min-max per spec and phase) and `START_SPLIT RESULT PASS|FAIL` (PASS: every run said ready).
#
# A TIMING: run it under the bench lock (flock ~/.cache/claude-orch/perf2/bench.lock ...), on a quiet machine.
set -u
HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${1:-}"; [ -n "$OUT" ] || { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
SCRATCH="${SCRATCH:-/tmp}"
SANDBOX="${SANDBOX:-$SCRATCH/lares-sbx-perf-ss}"
if [ -z "${SS_INNER:-}" ]; then
    mkdir -p "$OUT" || exit 1
    OUT="$(cd "$OUT" && pwd)"
    tv=()
    for v in $(env | grep -o '^TREE_[A-Za-z0-9_]*'); do tv+=("$v=${!v}"); done
    SANDBOX="$SANDBOX" SCRATCH="$SCRATCH" exec "$HERE/tools/dev/sandbox.sh" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi SS_INNER=1 \
        SPECS="${SPECS:-new:warm new:cold new:off}" ROUNDS="${ROUNDS:-5}" SCALE="${SCALE:-1}" REFRESH="${REFRESH:-120}" \
        SHELL_JSONC_FILE="${SHELL_JSONC_FILE:-}" COUNT_DISKCACHE="${COUNT_DISKCACHE:-}" LOG_RULES="${LOG_RULES:-}" SS_ENV="${SS_ENV:-}" SS_PATCH="${SS_PATCH:-}" READY_S="${READY_S:-120}" "${tv[@]}" \
        bash tools/dev/perf/start_split.sh "$OUT"
fi
cd "$HERE" || exit 1
. tools/dev/result_lib.sh
E="$HERE/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-ss0}"
QPID=""
cleanup() {
    [ -n "$QPID" ] && kill "$QPID" 2> /dev/null
    "$E" down > /dev/null 2>&1
    wait 2> /dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

# SS_PATCH: a script run in the run's own sandbox copy before any start (an ablation; never the tree)
if [ -n "${SS_PATCH:-}" ]; then
    [ ! -e .git ] || { echo "START_SPLIT RESULT FAIL (SS_PATCH outside a sandbox copy)"; exit 1; }
    bash "$SS_PATCH" || { echo "START_SPLIT RESULT FAIL (SS_PATCH failed: $SS_PATCH)"; exit 1; }
fi
"$E" down > /dev/null 2>&1
OUTPUTS=1 LOCK_REFRESH="${REFRESH:-120}" "$E" up > /dev/null || { echo "START_SPLIT RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
"$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })' > /dev/null
[ "${SCALE:-1}" = 1 ] || "$E" hyprctl eval 'hl.monitor({ output = "LOCK-1", scale = '"$SCALE"' })' > /dev/null
CFGDIR="/tmp/lrlk-$LOCK_ENV/state/lares-shell-mock/config"
mkdir -p "$CFGDIR"
BASECFG="$OUT/shell.base.jsonc"
if [ -n "${SHELL_JSONC_FILE:-}" ]; then cp "$SHELL_JSONC_FILE" "$BASECFG" || { echo "START_SPLIT RESULT FAIL (SHELL_JSONC_FILE)"; exit 1; }
else echo '{}' > "$BASECFG"; fi
CACHES="$OUT/caches"; rm -rf "$CACHES"; mkdir -p "$CACHES"
RES="$OUT/runs.tsv"; : > "$RES"


fail=0
one() {     # one <spec> <tag>: one start; appends a row to runs.tsv unless tag is "prime"
    local spec=$1 tag=$2 tree cache mode root log env_cache=() rules=""
    IFS=: read -r tree cache mode <<< "$spec"
    if [ "$tree" = new ]; then root="$HERE"; else local v="TREE_$tree"; root="${!v:-}"; fi
    [ -n "$root" ] && [ -f "$root/shell.qml" ] || { echo "START_SPLIT no tree for $spec"; fail=1; return; }
    case $cache in
        warm) mkdir -p "$CACHES/$tree.warm"; env_cache=(QML_DISK_CACHE_PATH="$CACHES/$tree.warm") ;;
        cold) local d="$CACHES/cold.$tag.${spec//:/_}"; rm -rf "$d"; mkdir -p "$d"; env_cache=(QML_DISK_CACHE_PATH="$d") ;;
        off) env_cache=(QML_DISABLE_DISK_CACHE=1) ;;
        *) echo "START_SPLIT unknown cache $cache"; fail=1; return ;;
    esac
    [ "${mode:-}" = qs ] && env_cache+=(LARES_FILE_ROOT=0)
    if [ "${mode:-}" != "${mode#-}" ]; then     # -<module>: shell.jsonc's `modules` says that one is off (an ablation that prices it)
        python3 - "$BASECFG" "$CFGDIR/shell.jsonc" "${mode#-}" << 'PYOFF' || { echo "START_SPLIT could not write the config for $spec"; fail=1; return; }
import json, sys
sys.path.insert(0, "tools/lib")
from jsonc import strip
raw = json.loads(strip(open(sys.argv[1]).read()) or "{}")
raw.setdefault("modules", {})[sys.argv[3]] = False
open(sys.argv[2], "w").write(json.dumps(raw, indent=2))
PYOFF
    else
        cp "$BASECFG" "$CFGDIR/shell.jsonc"
    fi
    [ -z "${COUNT_DISKCACHE:-}" ] || rules="qt.qml.diskcache.debug=true"
    [ -z "${LOG_RULES:-}" ] || rules="${rules:+$rules;}$LOG_RULES"
    log="$OUT/run.${spec//:/_}.$tag.log"
    local t0; t0=$(date +%s%3N)
    "$E" run env SHELL_SERVICES=mock MOCKUP_REPO= QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 "${env_cache[@]}" \
        ${SS_ENV:-} quickshell --log-times ${rules:+--log-rules "$rules"} -n -p "$root/shell.qml" > "$log" 2>&1 &
    QPID=$!
    local deadline=$(( $(date +%s) + ${READY_S:-120} ))
    until grep -aq "LARES ready" "$log" 2> /dev/null; do
        if ! kill -0 "$QPID" 2> /dev/null || [ "$(date +%s)" -ge "$deadline" ]; then
            echo "START_SPLIT $spec $tag: no ready ($log)"; fail=1; kill "$QPID" 2> /dev/null; wait "$QPID" 2> /dev/null; QPID=""; return
        fi
        sleep 0.05
    done
    sleep 0.3
    kill "$QPID" 2> /dev/null; wait "$QPID" 2> /dev/null; QPID=""
    [ "$tag" = prime ] && return
    # the log's clock is the wall's (local "YYYY-MM-DD hh:mm:ss.mmm", in colour); the launch is the runner's own epoch ms
    python3 - "$log" "$spec" "$tag" "$t0" >> "$RES" << 'PY2'
import re, sys, datetime
log, spec, tag, t0 = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
txt = re.sub(r"\x1b\[[0-9;]*m", "", open(log, errors="replace").read())
def at(pat):
    m = re.search(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}).*" + pat, txt, re.M)
    if not m:
        return -1
    return int(datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp() * 1000)
L, F, S, R = at("Launching config"), at(r" qml: (?!LARES (root|start) )"), at("LARES shown"), at("LARES ready")
refused = txt.count("File has to be a local file")
m = re.search(r"LARES start (root=\d+ (?:load=\d+ )?services=\d+[^\n]*)", txt)
r = re.search(r"LARES root (\w+)", txt)
print("\t".join(str(x) for x in (spec, tag, L - t0, L, F, S, R, refused, (r.group(1) + " " if r else "") + (m.group(1) if m else ""))))
PY2
}

primed=" "
for spec in ${SPECS:-new:warm}; do
    case $spec in *:warm*) case $primed in *" ${spec%%:*} "*) ;; *) one "$spec" prime; primed="$primed${spec%%:*} " ;; esac ;; esac
done
for r in $(seq 1 "${ROUNDS:-5}"); do
    for spec in ${SPECS:-new:warm}; do one "$spec" "r$r"; done
done
python3 - "$RES" << 'PY'
import sys, statistics as st
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
by = {}
for r in rows:
    spec, tag, la, L, F, S, R, refused, start = r
    L, F, S, R = int(L), int(F), int(S), int(R)
    d = by.setdefault(spec, {"launch->config": [], "config->firstqml": [], "firstqml->shown": [], "shown->ready": [], "config->ready": [], "refused": [], "start": []})
    d["launch->config"].append(int(la)); d["config->firstqml"].append(F - L); d["firstqml->shown"].append(S - F)
    d["shown->ready"].append(R - S); d["config->ready"].append(R - L); d["refused"].append(int(refused)); d["start"].append(start)
for spec, d in by.items():
    print(f"START_SPLIT {spec}  n={len(d['refused'])}")
    for k in ("launch->config", "config->firstqml", "firstqml->shown", "shown->ready", "config->ready", "refused"):
        v = d[k]
        print(f"    {k:18s} median {st.median(v):7.0f}   min {min(v):6d}   max {max(v):6d}   all {' '.join(str(x) for x in v)}")
    if any(d["start"]):
        print(f"    start lines        {' | '.join(d['start'])}")
PY
[ -s "$RES" ] || fail=1
if [ "$fail" = 0 ]; then echo "START_SPLIT RESULT PASS"; else echo "START_SPLIT RESULT FAIL (a run did not say ready: $OUT)"; exit 1; fi
