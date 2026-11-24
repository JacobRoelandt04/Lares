#!/usr/bin/env bash
# lock_start_split.sh -- how long the LOCK takes to start, split into phases: the real supervisor (tools/lockscreen/lares-lock) and lock
# (lock/shell.qml) from a TREE COPY in tools/dev/lock_env.sh's nested Hyprland, the PAM directory the scripted stub's (tools/dev/lock_a1_lib.sh;
# checked before every lock), started N times in one session, each unlocked with the stub's password and waited out.
#
#   tools/dev/perf/lock_start_split.sh <outdir>
#   SPECS="warm cold off"   the runs of ONE round, interleaved; ROUNDS=5. A spec is <cache>[:qs]
#       cache  warm = one QML disk cache kept across the runs of that spec (primed by one unreported run first)
#              cold = an empty cache dir every run;  off = QML_DISABLE_DISK_CACHE=1
#       qs     LARES_FILE_ROOT=0 for that run (for a tree whose lock/shell.qml is a file: stub; today's lock is on qs: in every spec)
#   BOOT=1 (default) the boot path (`lares-lock --boot`: the cover first, as at login); BOOT=0 a plain lock
#
# Phases per run (whole ms of quickshell's --log-times, which the COPY's supervisor passes): launch (the runner's clock) ->
# `Launching config` -> the first `qml:` line -> `LARESLOCK secure` (the session lock holds) -> the veil and the desktop layer loaded (their
# Loaders, after `locked`: the COPY logs `LSS veil loaded` / `LSS desk loaded`). launch->veil is the later of the two.
# Ends in one table (median and min-max per spec and phase) and `LOCK_START_SPLIT RESULT PASS|FAIL` (PASS: every run said secure and
# unlocked). A TIMING: under the bench lock (flock ~/.cache/claude-orch/perf2/bench.lock ...), on a quiet machine.
#
# MEASURED 2026-11-23 (5 rounds, nested, boot path): the lock on qs: launch->secure 469 ms, ->veil 537, of which Quickshell's start is
# ~160 and its type loader ~210 (cache on or off: the same). A file: stub of lock/shell.qml (as the shell's) took 43 ms off secure and 41
# off the veil with a warm cache (429 / 493), none cold: the rest is the lock's own protocol (cover, xray, the session lock). Not taken.
set -u
HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${1:-}"; [ -n "$OUT" ] || { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
mkdir -p "$OUT" && OUT="$(cd "$OUT" && pwd)" || exit 1
# shellcheck source=../lock_a1_lib.sh
. "$HERE/tools/dev/lock_a1_lib.sh"
a1_init "${LSS_ENV:-stlk}"
# the lock is started only through the library's nested session, never on the desktop
[ "${E:-}" = "$HERE/tools/dev/lock_env.sh" ] || { echo "LOCK_START_SPLIT RESULT FAIL (lock_a1_lib.sh did not name tools/dev/lock_env.sh)"; exit 1; }
QPID=""
finish() { a1_kill_lock > /dev/null 2>&1; a1_down; }
trap finish EXIT
trap 'finish; exit 130' INT TERM HUP

a1_build_pam || { echo "LOCK_START_SPLIT RESULT FAIL (the PAM stub did not build)"; exit 1; }
a1_tree || { echo "LOCK_START_SPLIT RESULT FAIL (the tree copy)"; exit 1; }
a1_patch tools/lockscreen/lares-lock 'quickshell -p "$ROOT/lock/shell.qml"' 'quickshell --log-times -p "$ROOT/lock/shell.qml"' \
    || { echo "LOCK_START_SPLIT RESULT FAIL (the supervisor's launch line moved)"; exit 1; }
# the copy says when the surface's two layers are built (the veil, the desktop layer: loaded by URL after `locked`)
a1_patch modules/lockscreen/lock/LockSurface.qml '            id: veilLoader
' '            id: veilLoader
            onLoaded: console.log("LSS veil loaded")
' && a1_patch modules/lockscreen/lock/LockSurface.qml '            id: deskLoader
' '            id: deskLoader
            onLoaded: console.log("LSS desk loaded")
' || { echo "LOCK_START_SPLIT RESULT FAIL (the loaders' anchors moved)"; exit 1; }
a1_up MODE=light || { echo "LOCK_START_SPLIT RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
RT="$B/rt"
CACHES="$OUT/caches"; rm -rf "$CACHES"; mkdir -p "$CACHES"
RES="$OUT/runs.tsv"; : > "$RES"
ARGS=(); [ "${BOOT:-1}" = 1 ] && ARGS=(--boot)
fail=0

one() {     # one <spec> <tag>
    local spec=$1 tag=$2 cache mode envs=() log t0
    IFS=: read -r cache mode <<< "$spec"
    case $cache in
        warm) mkdir -p "$CACHES/${spec//:/_}"; envs=(QML_DISK_CACHE_PATH="$CACHES/${spec//:/_}") ;;
        cold) local d="$CACHES/cold.$tag.${spec//:/_}"; rm -rf "$d"; mkdir -p "$d"; envs=(QML_DISK_CACHE_PATH="$d") ;;
        off) envs=(QML_DISABLE_DISK_CACHE=1) ;;
        *) echo "LOCK_START_SPLIT unknown cache $cache"; fail=1; return ;;
    esac
    [ "${mode:-}" = qs ] && envs+=(LARES_FILE_ROOT=0)
    a1_pam_guard || { echo "LOCK_START_SPLIT RESULT FAIL (pamDirectory is not the stub's: no lock was started)"; exit 1; }
    : > "$RT/lares-lock.log"
    t0=$(date +%s%3N)
    A1_LOCK_ARGS="${ARGS[*]}" a1_lock "${envs[@]}" LARES_LOCK_FACE=0 LARES_LOCK_PAM_DIR="$W/pam.d"
    if ! a1_wait_log 'LARESLOCK secure' 30; then
        echo "LOCK_START_SPLIT $spec $tag: never secure"; fail=1; a1_kill_lock; return
    fi
    sleep 2.5
    cp "$RT/lares-lock.log" "$OUT/run.${spec//:/_}.$tag.log"
    "$E" type hunter2; sleep 0.3; "$E" key Return
    if ! a1_wait_log 'LARESLOCK unlocked' 15; then echo "LOCK_START_SPLIT $spec $tag: did not unlock"; fail=1; a1_kill_lock; return; fi
    local i; for i in $(seq 1 100); do kill -0 "$SUP" 2> /dev/null || break; sleep 0.1; done
    a1_kill_lock
    [ "$tag" = prime ] && return
    python3 - "$OUT/run.${spec//:/_}.$tag.log" "$spec" "$tag" "$t0" >> "$RES" << 'PYEND'
import re, sys, datetime
log, spec, tag, t0 = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
txt = re.sub(r"\x1b\[[0-9;]*m", "", open(log, errors="replace").read())
def at(pat):
    m = re.search(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}).*" + pat, txt, re.M)
    return int(datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp() * 1000) if m else -1
L, F, S, V, D = at("Launching config"), at(r" qml: (?!LARES (root|start) |LARESLOCK fact root: )"), at("LARESLOCK secure"), at("LSS veil loaded"), at("LSS desk loaded")
r = re.search(r"LARESLOCK fact root: (\w+)", txt)
print("\t".join(str(x) for x in (spec, tag, L - t0, L, F, S, V, D, txt.count("File has to be a local file"), r.group(1) if r else "")))
PYEND
}

for spec in ${SPECS:-warm cold off}; do case $spec in warm*) one "$spec" prime ;; esac; done
for r in $(seq 1 "${ROUNDS:-5}"); do
    for spec in ${SPECS:-warm cold off}; do one "$spec" "r$r"; done
done
python3 - "$RES" << 'PYEND'
import sys, statistics as st
by = {}
for l in open(sys.argv[1]):
    if not l.strip():
        continue
    spec, tag, la, L, F, S, V, D, refused, root = l.rstrip("\n").split("\t")
    L, F, S, V, D = int(L), int(F), int(S), int(V), int(D)
    d = by.setdefault(spec, {k: [] for k in ("launch->config", "config->firstqml", "firstqml->secure", "secure->veil", "secure->desk", "launch->secure", "launch->veil", "root")})
    d["launch->config"].append(int(la)); d["config->firstqml"].append(F - L); d["firstqml->secure"].append(S - F)
    d["secure->veil"].append(V - S); d["secure->desk"].append(D - S); d["launch->secure"].append(S - L + int(la))
    d["launch->veil"].append(max(V, D) - L + int(la)); d["root"].append(root or "-")
for spec, d in by.items():
    print(f"LOCK_START_SPLIT {spec}  n={len(d['root'])}  root={','.join(sorted(set(d['root'])))}")
    for k in ("launch->config", "config->firstqml", "firstqml->secure", "secure->veil", "secure->desk", "launch->secure", "launch->veil"):
        v = d[k]
        print(f"    {k:18s} median {st.median(v):7.0f}   min {min(v):6d}   max {max(v):6d}   all {' '.join(str(x) for x in v)}")
PYEND
rm -rf "$CACHES"
[ -s "$RES" ] || fail=1
if [ "$fail" = 0 ]; then echo "LOCK_START_SPLIT RESULT PASS"; else echo "LOCK_START_SPLIT RESULT FAIL ($OUT)"; exit 1; fi
