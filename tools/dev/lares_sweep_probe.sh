#!/usr/bin/env bash
# The retention sweep (tools/shell/lares-sweep) and the system-update run prune (helpers/update-run.sh prune_runs), on a FAKE HOME only.
#
#   tools/dev/lares_sweep_probe.sh                 ends in LARES_SWEEP RESULT PASS|FAIL
#   ARM=<name> tools/dev/lares_sweep_probe.sh      a fault in a COPY of the tool; the run must FAIL on the check named after the arm
#   ARM=all                                     every ARM; LARES_SWEEP ARMS PASS when each failed as it must
#     noage        lares-sweep ignores how old a unit is           -> "a young generation stays" / "a young file stays"
#     nopath       lares-sweep's path assertion removed            -> "a path that resolves outside the rule directory is refused"
#     noindex      a removed logo keeps its index row           -> "a removed logo takes its index row with it"
#     noatime      "used" goes by mtime alone                   -> "a generation read last week stays although it was written long ago"
#     norunning    the prune removes a run that is still alive  -> "a run that is still alive is never pruned"
#
# THE WORLD. A temp dir holds a HOME, XDG_CACHE_HOME and XDG_STATE_HOME; every command runs under `env -i` with those, so the sweep can
# only see the fake files (the real home is never named). Ages are set with touch (mtime) and touch -a (atime) on the tmpfs.
# Never run lares-sweep itself on the real home from here: this probe only reads the tool and runs a COPY or the tool on the fake HOME.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
# shellcheck source=result_lib.sh
. "$HERE/result_lib.sh"
NAME=LARES_SWEEP

if [ "${ARM:-}" = all ]; then
    fails=0
    for a in noage nopath noindex noatime norunning; do
        out=$(ARM=$a "$0" 2>&1)
        if rl_isnoresult "$out"; then echo "ARM $a: did not load (proves nothing)"; fails=$((fails + 1)); continue; fi
        if printf '%s\n' "$out" | grep -q "FAIL check: .*"; then echo "ARM $a: failed as it must ($(printf '%s\n' "$out" | grep -m1 'FAIL check:' | cut -c1-110))"
        else echo "ARM $a: DID NOT FAIL"; fails=$((fails + 1)); fi
    done
    [ "$fails" -eq 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
    echo "$NAME ARMS FAIL ($fails)"; exit 1
fi

W=$(mktemp -d "${TMPDIR:-/tmp}/lares-sweep-probe.XXXXXX") || exit 2
case "$W" in /tmp/*|"${TMPDIR:-/tmp}"/*) ;; *) echo "$NAME RESULT FAIL (odd work dir $W)"; exit 1 ;; esac
LIVEPID=""
cleanup() { [ -n "$LIVEPID" ] && kill "$LIVEPID" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT

H=$W/home
CACHE=$H/.cache
STATE=$H/.local/state
OUTSIDE=$W/outside            # nothing here may ever change
mkdir -p "$H" "$CACHE" "$STATE" "$OUTSIDE"

TOOL=$ROOT/tools/shell/lares-sweep
UPD=$ROOT/helpers/update-run.sh
ARM=${ARM:-}
case $ARM in
    noage)
        cp "$TOOL" "$W/lares-sweep"
        python3 - "$W/lares-sweep" <<'E' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
a = "return used is not None and self.r[\"days\"] is not None and self.now - used > self.r[\"days\"] * DAY"
assert a in s; open(p, "w").write(s.replace(a, "return used is not None and self.r[\"days\"] is not None"))
E
        TOOL=$W/lares-sweep ;;
    nopath)
        cp "$TOOL" "$W/lares-sweep"
        python3 - "$W/lares-sweep" <<'E' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
a = "    if not (parent == base_real or parent.startswith(base_real + os.sep)):\n        raise Refused"
assert a in s; open(p, "w").write(s.replace(a, "    if False:\n        raise Refused"))
E
        TOOL=$W/lares-sweep ;;
    noindex)
        cp "$TOOL" "$W/lares-sweep"
        python3 - "$W/lares-sweep" <<'E' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
a = "    if gone and not ctx.dry and os.path.isfile(idx)"
assert a in s; open(p, "w").write(s.replace(a, "    if False and gone and not ctx.dry and os.path.isfile(idx)"))
E
        TOOL=$W/lares-sweep ;;
    noatime)
        cp "$TOOL" "$W/lares-sweep"
        python3 - "$W/lares-sweep" <<'E' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
a = "return max(st.st_atime, st.st_mtime) if how == \"atime+mtime\" else st.st_mtime"
assert a in s; open(p, "w").write(s.replace(a, "return st.st_mtime"))
E
        TOOL=$W/lares-sweep ;;
    norunning)
        mkdir -p "$W/helpers"
        python3 - "$UPD" "$W/helpers/update-run.sh" <<'E' || exit 2
import sys
s = open(sys.argv[1]).read()
a = '[ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null || continue'
assert a in s; open(sys.argv[2], "w").write(s.replace(a, ":"))
E
        mkdir -p "$W/llm_tools"; UPD=$W/helpers/update-run.sh ;;
    "") ;;
    *) echo "unknown ARM $ARM"; exit 2 ;;
esac

# sweep <args...>: the tool on the fake HOME, nothing of the desktop's environment
sweep() { env -i PATH="$PATH" HOME="$H" XDG_CACHE_HOME="$CACHE" XDG_STATE_HOME="$STATE" "$@" ; }
run_sweep() { sweep python3 "$TOOL" "$@"; }

FAILS=0
check() {   # check <name> <command...>: passes when the command succeeds
    local n=$1; shift
    if "$@" >/dev/null 2>&1; then echo "ok   $n"; else echo "FAIL check: $n"; FAILS=$((FAILS + 1)); fi
}
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
present() { [ -e "$1" ] || [ -L "$1" ]; }

# mk <path> <days since written> <days since read> [bytes]
mk() {
    mkdir -p "$(dirname "$1")"
    head -c "${4:-100}" /dev/zero > "$1"
    touch -m -d "$2 days ago" "$1"
    touch -a -d "$3 days ago" "$1"
}
# mkdir_aged <dir> <days>: a directory's own times (rmtree does not care; the unit's age is its files')

# ---- the fixture ------------------------------------------------------------------------------------------------------------------
# 1. launcher icons: current (old, kept by the link), an old generation, one read last week, a young one, a symlink out
L=$CACHE/lares/launcher/icons/Papirus
mk "$L/pcur/index.json" 300 300; mk "$L/pcur/cells/a.png" 300 300
mk "$L/pold/index.json" 200 200; mk "$L/pold/cells/a.png" 200 200
mk "$L/pread/index.json" 200 200; mk "$L/pread/cells/a.png" 200 5          # written long ago, read last week
mk "$L/pnew/index.json" 3 3
mk "$OUTSIDE/victim.png" 500 500; ln -s "$OUTSIDE" "$L/pold/escape"           # a link out of an old generation: the link goes, the target stays
ln -s pcur "$L/current"
mkdir -p "$CACHE/lares/launcher/icons/Colloid"; mk "$CACHE/lares/launcher/icons/Colloid/pzzz/index.json" 400 400   # a theme with no `current`

# 2. stocks logos (slugs): an old one with every file, one old png but read yesterday, a boundary pair, the index
G=$CACHE/lares/stocks/logos
mk "$G/OLD.png" 120 120; mk "$G/OLD.mono.png" 120 120; mk "$G/OLD.none" 120 120
mk "$G/READ.png" 400 1; mk "$G/READ.mono.png" 400 400
mk "$G/EDGE91.png" 91 91; mk "$G/EDGE89.png" 89 89
mk "$G/BPOST.BR.png" 200 200; mk "$G/BPOST.BR.mono.png" 200 200               # a dot in the slug
cat > "$G/index.json" <<'E'
{"OLD": {"src": "x"}, "READ": {"src": "x"}, "EDGE91": {"src": "x"}, "EDGE89": {"src": "x"}, "BPOST.BR": {"src": "x"}, "NOFILES": {"src": "x"}}
E
touch -m -d "400 days ago" "$G/index.json"; touch -a -d "400 days ago" "$G/index.json"

# 3. stocks charts: old, young, written long ago but read, a non-json, a symlink to an old file outside, an old subdirectory
C=$CACHE/lares/stocks/charts
mk "$C/AAA_1Y.json" 100 100; mk "$C/BBB_1Y.json" 100 2; mk "$C/CCC_1Y.json" 5 5; mk "$C/note.txt" 400 400
mk "$OUTSIDE/chart_real.json" 400 400; ln -s "$OUTSIDE/chart_real.json" "$C/LNK_1Y.json"

# 4. wiki images: referenced by an entry, referenced by a live page, an old orphan, a young orphan; the pool = entries + live
WS=$STATE/lares/wiki; WC=$CACHE/lares/wiki
mk "$WS/img/ent.jpg" 300 300; mk "$WS/img/ent-thumb.jpg" 300 300; mk "$WS/img/live.jpg" 300 300
mk "$WS/img/orphan_old.jpg" 200 200; mk "$WS/img/orphan_old-thumb.jpg" 200 200; mk "$WS/img/orphan_new.jpg" 10 10
mk "$WS/img/orphan_read.jpg" 200 3
mk "$WS/img/Catedral_é,_(x).jpg" 200 200     # a name with a comma, a bracket and an accent, referenced through JSON escapes
mkdir -p "$WS/entries/deepen" "$WC/live" "$WC/daily"
cat > "$WS/entries/deepen/e.json" <<'E'
{"id": "e", "images": [{"file": "img/ent.jpg", "thumb": "img/ent-thumb.jpg"}], "logo": "img/Catedral_é,_(x).jpg"}
E
printf '{"v": 1, "files": ["img/live.jpg"]}\n' > "$WC/live/p.json"
printf '{"day": "2026-01-01"}\n' > "$WC/daily/d.json"

# 5. crash dumps: 13 dirs, mtime i days ago (1 = newest)
K=$CACHE/quickshell/crashes
for i in $(seq 1 13); do mk "$K/crash$(printf %02d "$i")/report.txt" "$i" "$i"; done

# a sentinel tree outside every rule: its listing + checksums must not change
mk "$OUTSIDE/other/keep.txt" 900 900
mk "$CACHE/lares/stocks/history/AMD.json" 900 900      # beside the charts, not in any rule
mk "$CACHE/lares/audio-art/x.png" 900 900
snap() { (cd "$W" && find outside home/.cache/lares/stocks/history home/.cache/lares/audio-art -printf '%p %s %T@\n' | sort; md5sum "$OUTSIDE"/victim.png "$OUTSIDE"/chart_real.json "$OUTSIDE"/other/keep.txt); }
BEFORE_OUT=$(snap)

# ---- dry run ------------------------------------------------------------------------------------------------------------------------
tree() { (cd "$H" && { find . -type f ! -name '*.json' -printf '%p %s %T@ %A@\n'; find . -type f -name '*.json' -printf '%p %s %T@\n'; } | sort | md5sum); }
T0=$(tree)
DRY=$(run_sweep --dry-run 2>&1)
check "a dry run names what it would remove (pold, OLD, AAA_1Y, orphan_old, crash13)" bash -c "echo '$DRY' | grep -q 'pold' && echo '$DRY' | grep -q 'OLD.png' && echo '$DRY' | grep -q 'AAA_1Y' && echo '$DRY' | grep -q 'orphan_old.jpg' && echo '$DRY' | grep -q 'crash13'"
check "a dry run changes nothing under HOME (files, sizes, mtimes, atimes)" test "$T0" = "$(tree)"
check "a dry run writes no log and no stamp" bash -c "[ ! -e '$STATE/lares/tool/lares.log' ] && [ ! -e '$STATE/lares/tool/sweep.stamp' ]"

# ---- the real run ----------------------------------------------------------------------------------------------------------------------
OUT=$(run_sweep 2>&1); RC=$?
check "the run exits 0" test "$RC" -eq 0

check "launcher: the generation current names stays, however old" present "$L/pcur/index.json"
check "launcher: an unused old generation goes" absent "$L/pold"
check "launcher: a generation read last week stays although it was written long ago" present "$L/pread/cells/a.png"
check "launcher: a young generation stays" present "$L/pnew/index.json"
check "launcher: the current link itself stays" test -L "$L/current"
check "launcher: a theme with no current link loses its unused generation" absent "$CACHE/lares/launcher/icons/Colloid/pzzz"

check "logos: an unused slug loses all its files" bash -c "[ ! -e '$G/OLD.png' ] && [ ! -e '$G/OLD.mono.png' ] && [ ! -e '$G/OLD.none' ]"
check "logos: a slug whose png was read yesterday keeps ALL its files" bash -c "[ -e '$G/READ.png' ] && [ -e '$G/READ.mono.png' ]"
check "logos: 91 days unused goes" absent "$G/EDGE91.png"
check "logos: 89 days unused stays" present "$G/EDGE89.png"
check "logos: a slug with a dot (BPOST.BR) is one slug and goes whole" bash -c "[ ! -e '$G/BPOST.BR.png' ] && [ ! -e '$G/BPOST.BR.mono.png' ]"
check "logos: a removed logo takes its index row with it" bash -c "python3 -c \"
import json,sys
d=json.load(open('$G/index.json'))
sys.exit(0 if not any(k in d for k in ('OLD','EDGE91','BPOST.BR')) else 1)\""
check "logos: the index keeps the rows of what stays (and an unknown row)" bash -c "python3 -c \"
import json,sys
d=json.load(open('$G/index.json'))
sys.exit(0 if all(k in d for k in ('READ','EDGE89','NOFILES')) else 1)\""
check "logos: index.json itself is never a unit" present "$G/index.json"

check "charts: an unused file older than 90 days goes" absent "$C/AAA_1Y.json"
check "charts: a file read last week stays although it was written long ago" present "$C/BBB_1Y.json"
check "charts: a young file stays" present "$C/CCC_1Y.json"
check "charts: a file that is not .json is left" present "$C/note.txt"
check "charts: a symlink to an old file outside is left, and so is its target" bash -c "[ -L '$C/LNK_1Y.json' ] && [ -e '$OUTSIDE/chart_real.json' ]"

check "wiki: an image an entry names stays (thumb too, and a name needing JSON escapes)" bash -c "[ -e '$WS/img/ent.jpg' ] && [ -e '$WS/img/ent-thumb.jpg' ] && [ -e '$WS/img/Catedral_é,_(x).jpg' ]"
check "wiki: an image only a live page names stays" present "$WS/img/live.jpg"
check "wiki: an orphan unused for 200 days goes" bash -c "[ ! -e '$WS/img/orphan_old.jpg' ] && [ ! -e '$WS/img/orphan_old-thumb.jpg' ]"
check "wiki: a young orphan stays" present "$WS/img/orphan_new.jpg"
check "wiki: an orphan read last week stays" present "$WS/img/orphan_read.jpg"

check "crashes: the newest 10 stay" bash -c "for i in 01 02 03 04 05 06 07 08 09 10; do [ -d '$K/crash'\$i ] || exit 1; done"
check "crashes: the 11th, 12th and 13th go" bash -c "[ ! -e '$K/crash11' ] && [ ! -e '$K/crash12' ] && [ ! -e '$K/crash13' ]"

check "nothing outside the rules changed (history/, audio-art/, the outside tree, link targets)" test "$BEFORE_OUT" = "$(snap)"

LOGF=$STATE/lares/tool/lares.log
check "the log has one lares-sweep line per rule (7)" test "$(grep -c ' lares-sweep: ' "$LOGF" 2>/dev/null)" -eq 7
check "the log line says what was removed" grep -q 'crash-dumps (newest 10): removed 3,' "$LOGF"
check "the sweep stamp is written" present "$STATE/lares/tool/sweep.stamp"

# a second run finds nothing more to do
OUT2=$(run_sweep 2>&1)
check "a second run removes nothing" bash -c "! echo '$OUT2' | grep -E 'removed [1-9]'"

# ---- --daily -----------------------------------------------------------------------------------------------------------------------
n0=$(grep -c ' lares-sweep: ' "$LOGF")
run_sweep --daily >/dev/null 2>&1
check "--daily right after a sweep does nothing (no new log lines)" test "$(grep -c ' lares-sweep: ' "$LOGF")" -eq "$n0"
touch -m -d "21 hours ago" "$STATE/lares/tool/sweep.stamp"
run_sweep --daily >/dev/null 2>&1
check "--daily after 21 hours sweeps again (7 new lines)" test "$(grep -c ' lares-sweep: ' "$LOGF")" -eq $((n0 + 7))

# ---- the edges ----------------------------------------------------------------------------------------------------------------------
# crash dumps at exactly 10: nothing goes
rm -rf "$K"; for i in $(seq 1 10); do mk "$K/c$i/r" "$((i * 30))" "$((i * 30))"; done
run_sweep --rule crash-dumps >/dev/null 2>&1
check "crashes: exactly 10 (all old) are all kept" test "$(ls "$K" | wc -l)" -eq 10
mk "$K/c11/r" 400 400
run_sweep --rule crash-dumps >/dev/null 2>&1
check "crashes: 11 -> the oldest goes, the rest stay" bash -c "[ ! -e '$K/c11' ] && [ \$(ls '$K' | wc -l) -eq 10 ]"

# a rule directory that is itself a symlink: skipped whole, the target untouched
mk "$OUTSIDE/linked_charts/Z_1Y.json" 500 500
rm -rf "$C"; ln -s "$OUTSIDE/linked_charts" "$C"
SK=$(run_sweep --rule stocks-charts 2>&1)
check "a rule directory that is a symlink is skipped and its target kept" bash -c "echo '$SK' | grep -q 'SKIPPED' && [ -e '$OUTSIDE/linked_charts/Z_1Y.json' ]"
rm -f "$C"

# the pool unknown: no JSON at all, or a broken one -> no image is removed
rm -rf "$WS/entries" "$WC/live" "$WC/daily"
mk "$WS/img/orphan_old.jpg" 200 200
run_sweep --rule wiki-images >/dev/null 2>&1
check "wiki: with no entry file found nothing is removed" present "$WS/img/orphan_old.jpg"
mkdir -p "$WS/entries/deepen"; printf '{"id": ' > "$WS/entries/deepen/broken.json"
run_sweep --rule wiki-images >/dev/null 2>&1
check "wiki: with an unreadable entry file nothing is removed" present "$WS/img/ent.jpg"

# noatime: a rule that goes by atime is skipped; crash-dumps (mtime) still runs
mkdir -p "$C"; mk "$C/OLD_1Y.json" 300 300
printf '36 25 8:1 / / rw,noatime - ext4 /dev/x rw\n' > "$W/mountinfo"
NA=$(env -i PATH="$PATH" HOME="$H" XDG_CACHE_HOME="$CACHE" XDG_STATE_HOME="$STATE" LARES_SWEEP_MOUNTINFO="$W/mountinfo" python3 "$TOOL" --rule stocks-charts --rule crash-dumps 2>&1)
check "noatime: the atime rule is skipped with a line saying so" bash -c "echo '$NA' | grep -q 'stocks-charts.*SKIPPED.*noatime'"
check "noatime: nothing the atime rule would have removed is removed" present "$C/OLD_1Y.json"
check "noatime: a rule that goes by mtime still runs" bash -c "echo '$NA' | grep -q 'crash-dumps (newest 10): removed'"

# ---- the path assertion, called directly -----------------------------------------------------------------------------------------------
mk "$OUTSIDE/direct_victim" 500 500
PA=$(env -i PATH="$PATH" HOME="$H" XDG_CACHE_HOME="$CACHE" XDG_STATE_HOME="$STATE" python3 - "$TOOL" "$CACHE/lares/stocks/charts" "$OUTSIDE" <<'E' 2>&1
import importlib.machinery, importlib.util, os, sys
tool, base, outside = sys.argv[1:4]
loader = importlib.machinery.SourceFileLoader("lrsweep", tool)
spec = importlib.util.spec_from_loader("lrsweep", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
base_real = os.path.realpath(base)
os.makedirs(base, exist_ok=True)
try:
    m.remove(os.path.join(base, "..", "..", "..", "..", "..", os.path.relpath(outside, "/"), "direct_victim"), base_real)
    print("REMOVED")
except m.Refused as e:
    print("REFUSED")
E
)
check "a path that resolves outside the rule directory is refused (and the file survives)" bash -c "[ '$PA' = REFUSED ] && [ -e '$OUTSIDE/direct_victim' ]"

# ---- the system-update prune ---------------------------------------------------------------------------------------------------------
RUNS=$H/.local/share/system-update-logs/runs
mkdir -p "$RUNS" "$W/stubs" "$W/llm_tools"
cat > "$W/stubs/systemd-inhibit" <<'E'
#!/bin/sh
exit 0
E
chmod +x "$W/stubs/systemd-inhibit"
for i in $(seq 1 34); do d=$(printf '2026-09-%02d_10-00-00' "$i"); [ "$i" -gt 30 ] && d=$(printf '2026-10-%02d_10-00-00' "$((i - 30))"); mkdir -p "$RUNS/$d"; : > "$RUNS/$d/exit"; done
sleep 600 & LIVEPID=$!
mkdir -p "$RUNS/2026-08-01_09-00-00"
printf '{ "runId": "x",\n  "pid": %s,\n  "command": "yay",\n  "startedAt": 1 }\n' "$LIVEPID" > "$RUNS/2026-08-01_09-00-00/run.json"      # alive, no exit file
mkdir -p "$RUNS/2026-08-02_09-00-00"
printf '{ "runId": "y",\n  "pid": 999999,\n  "startedAt": 1 }\n' > "$RUNS/2026-08-02_09-00-00/run.json"             # dead pid, no exit file: an old run
mkdir -p "$RUNS/notarun" "$RUNS/2026-08-03_09-00-00-extra"; ln -s "$OUTSIDE" "$RUNS/2026-08-04_09-00-00"
NEWRUN=$RUNS/2026-11-08_12-00-00
( cd "$W" && env -i PATH="$W/stubs:$PATH" HOME="$H" XDG_STATE_HOME="$STATE" XDG_RUNTIME_DIR="$W/rt" sh "$UPD" "$NEWRUN" true >/dev/null 2>&1 )
count_runs() { find "$RUNS" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]-[0-9][0-9]' | wc -l; }
check "update-run: the new run's dir exists and its run finished (exit file)" present "$NEWRUN/exit"
check "update-run: a run that is still alive is never pruned" present "$RUNS/2026-08-01_09-00-00"
check "update-run: an old finished run is pruned" absent "$RUNS/2026-09-01_10-00-00"
check "update-run: an old run with a dead pid and no exit file is pruned" absent "$RUNS/2026-08-02_09-00-00"
check "update-run: 30 runs stay by run time (new + 29 newest) plus the live one" test "$(count_runs)" -eq 31
check "update-run: the oldest of the kept 30 stays" present "$RUNS/2026-09-06_10-00-00"
check "update-run: the one just outside the 30 is gone" absent "$RUNS/2026-09-05_10-00-00"
check "update-run: a dir that is not named like a run is left" bash -c "[ -d '$RUNS/notarun' ] && [ -d '$RUNS/2026-08-03_09-00-00-extra' ]"
check "update-run: a symlink named like a run is left and its target kept" bash -c "[ -L '$RUNS/2026-08-04_09-00-00' ] && [ -e '$OUTSIDE/victim.png' ]"
# exactly 30 + the new = nothing more goes on a repeat with a fresh run id
N2=$RUNS/2026-11-08_12-00-01
( cd "$W" && env -i PATH="$W/stubs:$PATH" HOME="$H" XDG_STATE_HOME="$STATE" XDG_RUNTIME_DIR="$W/rt" sh "$UPD" "$N2" true >/dev/null 2>&1 )
check "update-run: the next run pushes exactly one more out" bash -c "[ ! -e '$RUNS/2026-09-06_10-00-00' ] && [ -d '$RUNS/2026-09-07_10-00-00' ]"
# a run dir outside a directory named `runs` is never pruned from
mkdir -p "$W/other/2026-01-01_00-00-00" "$W/other/2026-11-09_00-00-00"
( cd "$W" && env -i PATH="$W/stubs:$PATH" HOME="$H" XDG_STATE_HOME="$STATE" XDG_RUNTIME_DIR="$W/rt" LARES_UPDATE_KEEP_RUNS=1 sh "$UPD" "$W/other/2026-11-09_00-00-00" true >/dev/null 2>&1 )
check "update-run: a parent not called runs is not pruned" present "$W/other/2026-01-01_00-00-00"
check "the prune never touched the outside tree" bash -c "[ -e '$OUTSIDE/victim.png' ] && [ -e '$OUTSIDE/other/keep.txt' ]"

echo
if [ "$FAILS" -eq 0 ]; then echo "$NAME RESULT PASS"; exit 0; fi
echo "$NAME RESULT FAIL ($FAILS checks)"; exit 1
