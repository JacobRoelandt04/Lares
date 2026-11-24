#!/usr/bin/env bash
# The settings pipeline end to end: a mockup's Save writes the REAL implementation.
#
#   tools/dev/mockup_promote_probe.sh                  expect MOCKUP_PROMOTE_PROBE RESULT PASS (last line)
#   ARM=<name> tools/dev/mockup_promote_probe.sh       one fault put into the COPY's pipeline: must FAIL
#   ARM=all tools/dev/mockup_promote_probe.sh          every arm; MOCKUP_PROMOTE_PROBE ARMS PASS when each failed
#                                                  on the checks it names
#   OVERLAY=1 tools/dev/mockup_promote_probe.sh        run the working tree's pipeline files over the HEAD copy
#                                                  (while the work is not committed yet)
#   FAST=1                                         skip the smoke of the promoted mockups (the long part)
#   REAL_LARES_FROM=<dir>                       a directory holding the REAL lares and lares-lib.sh, for P11 (a tree
#                                                  that already has tools/shell/ at HEAD needs nothing: P11 uses its own)
#
# Everything happens in a scratch git repository made of `git archive HEAD` -- never the tree itself -- with
# a STUB tools/shell/lares (it logs its argv, commits exactly the files it is given as the real one does,
# and exits with $STUB_STATUS: 0 done, 1 failed, 2 usage, 4 committed but the
# restart refused during a package transaction); P11 swaps
# the REAL tool in where there is one.
# Every quickshell is offscreen on a private bus, private runtime dir and private XDG dirs (theme seeded).
#
#   P1  the plan: `mockup_promote.py dry --all` over all the mockups -- how many rows it would write, and
#       every REFUSAL with its reason (listed below; a binding default and a sentinel are the expected ones). The copy
#       carries ONE pending row of its own (the stocks owner's popupWidth moved off the mockup's 504: a tree whose
#       promotions are all in has nothing to write, and P2 / P4 would prove nothing), and P1 demands that exact row
#       planned as a write -- it is also the row the F2 merge made `skip` (the shell frame mounts every owner, the
#       planner read that as "shared with another module" and no Save of an owner's row reached its module)
#   P2  apply --all on the copy: only module files are written (no mockup, nothing under a protected
#       directory), each parses (qmllint: no message the HEAD file did not have), the mockups of the written
#       modules still LOAD (smoke: no warning)
#   P3  the wiring checker (--root the copy) on every mockup: UNSEEN/MISSING/DEAD/CLASH 0, and every DRIFT row left
#       says "promotion refuses" -- none says "promotion writes it" (DRIFT 0 but for what is refused)
#   P4  idempotence: apply again writes nothing, dry plans no write
#   P5  the bindings that must survive did (ClipboardBarOwner.openOverFullscreen, GooeyBar radius / thickness,
#       GooeyEngine.blendRadius): never overwritten
#   P6  a real SAVE from a mockup run from the copy (PANEL_SAVE_TEST): the module's files are written, the mockup's
#       val: too, the STUB is called with `apply --commit <module> <exactly those files>`, the commit holds just them,
#       the * marks clear
#   P7  a row of a SHARED component (the power reel's IconReelStyle): the per-module Save writes the module's use of
#       it and leaves the shared file alone; the per-row switch writes the shared declaration instead
#   P8  a refused row (a binding default) in a Save: reported, the file untouched, the mockup's val: still saved
#   P9  a mockup run from a COPY of the config (MOCKUP_REPO names the repo, as tools/dev/sandbox.sh does): the module is not
#       written, the reason is told, the mockup's val: lands in the repo as it always did
#   P10 lares's statuses reach the panel's line: 4 -> committed but NOT restarted (a package update runs), 1 -> COMMIT FAILED
#       (status 3, "redeploy not built", went with the turnover: `apply` redeploys a deployed shell now, tools/dev/lares_deploy_probe.sh `apply`)
#   P11 the REAL tools/shell/lares (the tree's own, or REAL_LARES_FROM; SKIPPED, said aloud, when neither exists):
#       a Save commits "<NAME> - tuning: <module>" (the repo's user.name) with exactly the module file + the mockup, the panel says "committed
#       <hash>" (what a deployed shell does after a Save -- the snapshot follows HEAD and the shell restarts -- needs a fake home:
#       lares_deploy_probe.sh `apply`)
#
# The arms (patched into the copy's pipeline before it is committed):
#   bindingwrite   a binding default may be overwritten            P5 (and P8)
#   sharedleak     no file is shared: a per-module Save writes the  P7
#                  shared component's own declaration
#   realargv       the panel calls `apply <module> --commit` (the     P11 (needs the real tool: skipped without)
#                  wrong order): the real tool refuses it
#   ownedskip      the stocks owner is not in the hints' `owned`      P1 (the seeded row is skipped as "shared")
#                  list: the shell frame's use of it makes it shared
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
. tools/dev/result_lib.sh
NAME=MOCKUP_PROMOTE_PROBE
SCRATCH="${SCRATCH:-$HOME/.cache/claude-shell-s}"
ARM="${ARM:-}"

declare -A MUST=( [bindingwrite]="P5" [sharedleak]="P7" [realargv]="P11" [ownedskip]="P1" )
# the real tool, if this tree (or REAL_LARES_FROM) has one: P11 and its arm need it
real_there() { { [ -f "${REAL_LARES_FROM:-/nonexistent}/lares" ] && [ -f "${REAL_LARES_FROM}/lares-lib.sh" ]; } || { git cat-file -e HEAD:tools/shell/lares 2> /dev/null && git cat-file -e HEAD:tools/shell/lares-lib.sh 2> /dev/null; }; }
if [ "$ARM" = all ]; then
    bad=0
    for a in ${ONLY_ARMS:-bindingwrite sharedleak realargv ownedskip}; do
        if [ "$a" = realargv ] && ! real_there; then
            echo "  ARM realargv: skipped -- no real tools/shell/lares in this tree and no REAL_LARES_FROM (P11 is skipped too)"; continue
        fi
        log="$SCRATCH/mockup_promote_probe-arm-$a.out"
        mkdir -p "$SCRATCH"
        ARM="$a" FAST=1 SCRATCH="$SCRATCH" "$ROOT/tools/dev/mockup_promote_probe.sh" > "$log" 2>&1
        last=$(tail -1 "$log")
        if rl_isnoresult "$last"; then
            echo "  ARM $a: the armed copy did not load -- it proves nothing: $last"; bad=1; continue
        fi
        failed=$(grep -oE "^PROBE FAIL P[0-9]+" "$log" | awk '{print $3}' | sort -u | tr '\n' ' ')
        miss=""
        for t in ${MUST[$a]}; do case " $failed" in *" $t "*) ;; *) miss="$miss $t" ;; esac; done
        if [ "$last" = "$NAME RESULT FAIL (ARM=$a)" ] && [ -z "$miss" ]; then
            echo "  ARM $a: FAIL, as it must -- red: ${failed% }"
        else
            echo "  ARM $a: NOT PROVEN -- '$last', must be red: ${MUST[$a]}, red: ${failed% }, missing:$miss ($log)"; bad=1
        fi
    done
    [ "$bad" = 0 ] && { echo "$NAME ARMS PASS (every arm failed where it must)"; exit 0; }
    echo "$NAME ARMS FAIL"; exit 1
fi

WORK="$SCRATCH/mockup_promote_probe${ARM:+-$ARM}"
REPO="$WORK/repo"
rm -rf "$WORK"; mkdir -p "$WORK" "$REPO"
git archive HEAD | tar -x -C "$REPO" || { echo "$NAME RESULT FAIL (git archive HEAD)"; exit 1; }
if [ "${OVERLAY:-}" = 1 ]; then
    rsync -a modules/common/mockup/ "$REPO/modules/common/mockup/"
    cp tools/dev/mockup_*.py tools/dev/mockup_promote_hints.json "$REPO/tools/dev/" 2> /dev/null
    rsync -a tools/dev/fixtures/mockup_promote/ "$REPO/tools/dev/fixtures/mockup_promote/"
fi
rm -f "$REPO/.qmlls.ini"          # the copy is its own root: a quickshell there makes its own
# The copy's one pending row (see P1): the module's popupWidth off the mockup's value, so the plan has something to write whatever the tree has promoted.
SEED=modules/stocks/StocksBarOwner.qml
sed -i 's/^\(    property real popupWidth: \)504$/\1500/' "$REPO/$SEED"
grep -q '^    property real popupWidth: 500$' "$REPO/$SEED" || { echo "$NAME RESULT FAIL (the seed did not take: $SEED has no 'property real popupWidth: 504' line)"; exit 1; }

# ---- the arm: a fault in the COPY's pipeline ---------------------------------------------------------------------
arm() {  # file, from, to -- exactly once
    python3 - "$1" "$2" "$3" <<'PY' || { echo "ARM $ARM: its anchor is not in $1 exactly once -- the arm is stale"; echo "$NAME RESULT FAIL (arm)"; exit 2; }
import sys
p, a, b = sys.argv[1:]
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
    echo "ARMED $ARM in $(basename "$1")"
}
case "$ARM" in
    "") ;;
    bindingwrite) arm "$REPO/tools/dev/mockup_promote.py" '        raise Refuse("binding default `%s`" % short(eff.text))' '        return' ;;
    sharedleak) arm "$REPO/tools/dev/mockup_model.py" $'    def shared(self, rel):\n        h = self.hints' $'    def shared(self, rel):\n        return False\n        h = self.hints' ;;
    realargv) arm "$REPO/tools/dev/mockup_promote.py" '[qs, "apply", "--commit", module_id] + files' '[qs, "apply", module_id, "--commit"] + files' ;;
    ownedskip) arm "$REPO/tools/dev/mockup_promote_hints.json" $'    "modules/stocks/StocksBarOwner.qml",\n' '' ;;
    *) echo "unknown ARM=$ARM"; echo "$NAME RESULT FAIL"; exit 2 ;;
esac

# ---- the stub lares ---------------------------------------------------------------------------------------------
STUBLOG="$WORK/stub.log"
REALDIR=""         # the REAL tool, for P11: REAL_LARES_FROM, else the tree's own (HEAD has it once the trial tool is merged)
if [ -f "${REAL_LARES_FROM:-/nonexistent}/lares" ] && [ -f "$REAL_LARES_FROM/lares-lib.sh" ]; then
    REALDIR=$REAL_LARES_FROM
elif [ -f "$REPO/tools/shell/lares" ] && [ -f "$REPO/tools/shell/lares-lib.sh" ]; then
    REALDIR="$WORK/real"; mkdir -p "$REALDIR"; cp "$REPO/tools/shell/lares" "$REPO/tools/shell/lares-lib.sh" "$REALDIR/"
fi
mkdir -p "$REPO/tools/shell"
cat > "$REPO/tools/shell/lares" <<'STUB'
#!/usr/bin/env bash
# STUB of tools/shell/lares: `apply --commit MODULE FILE...` as the real one behaves (stage 'F1'): commits exactly
# those files as "STUB - tuning: MODULE" (its own user.name, stub) and exits with $STUB_STATUS (0 done, 1 failed, 2 usage,
# 4 restart refused during a package transaction).
here=$(cd "$(dirname "$0")/../.." && pwd)
printf '%s\n' "$*" >> "${STUB_LOG:?}"
[ "${1:-}" = apply ] && [ "${2:-}" = --commit ] || { echo "usage: lares apply --commit MODULE FILE..." >&2; exit 2; }
module=$3; shift 3
rels=()
for f in "$@"; do
    case $f in /*) ;; *) f=$here/$f ;; esac
    rels+=("$(realpath -m --relative-to="$here" "$f")")
done
[ "${STUB_STATUS:-0}" = 2 ] && { echo "usage: stub" >&2; exit 2; }
if [ "${STUB_STATUS:-0}" = 1 ]; then echo "apply: refused (stub)" >&2; exit 1; fi
cd "$here" || exit 1
if [ -z "$(git status --porcelain -- "${rels[@]}")" ]; then echo "apply: nothing changed in ${rels[*]}: nothing committed, no restart"; exit 0; fi
git add -- "${rels[@]}" 2> /dev/null
git -c user.email=stub@qs -c user.name=stub commit -q -m "STUB - tuning: $module" -- "${rels[@]}" || exit 1
echo "apply: committed $(git rev-parse --short HEAD) \"STUB - tuning: $module\" (${#rels[@]} file(s): ${rels[*]})"
[ "${STUB_STATUS:-0}" = 4 ] && { echo "REFUSE restart: a package transaction runs (stub): committed, nothing restarted" >&2; exit 4; }
exit 0
STUB
chmod +x "$REPO/tools/shell/lares"
git -C "$REPO" init -q
git -C "$REPO" add -A > /dev/null 2>&1
git -C "$REPO" -c user.email=probe@qs -c user.name=probe commit -q -m "base" || { echo "$NAME RESULT FAIL (git commit of the copy)"; exit 1; }

# ---- the checks ------------------------------------------------------------------------------------------------------------
FAILS=0
check() {  # id, text, 0|1 (0 = ok)
    if [ "$3" = 0 ]; then echo "PROBE PASS $1 $2"; else echo "PROBE FAIL $1 $2"; FAILS=$((FAILS + 1)); fi
}
PY="python3 $REPO/tools/dev/mockup_promote.py"
cd "$REPO" || exit 1

# P1 the plan
$PY dry --all --summary > "$WORK/dry1.txt" 2>&1
sed -n '/^mockup /,$p' "$WORK/dry1.txt" | sed 's/^/    /'
W1=$(sed -n 's/^MOCKUP_PROMOTE dry run \([0-9]*\) write.*/\1/p' "$WORK/dry1.txt")
$PY dry --all > "$WORK/dry1_rows.txt" 2>&1
SEEDED=$(grep -c -E '^write +declaration +modules/stocks/StocksBarOwner\.qml:[0-9]+ +StocksBarOwner\.popupWidth ' "$WORK/dry1_rows.txt")
check P1 "the plan: ${W1:-?} rows to write over all the mockups, among them the seeded StocksBarOwner.popupWidth (an owner the shell frame mounts is its module's own: written, not 'shared'), the refusals above" "$([ -n "${W1:-}" ] && [ "$W1" -gt 0 ] && [ "$SEEDED" = 1 ] && echo 0 || echo 1)"
REFUSE1=$(sed -n '/^REFUSALS/,/^MOCKUP_PROMOTE/p' "$WORK/dry1.txt" | grep -c -E "^  [^ ]+\.qml ")

# P2 apply on the copy
$PY apply --all --summary > "$WORK/apply1.txt" 2>&1
FILES=$(grep "^FILE " "$WORK/apply1.txt" | sed 's/^FILE //' | sort -u)
NFILES=$(printf '%s\n' "$FILES" | grep -c .)
DIRTY=$(git status --porcelain | sed 's/^...//' | sort -u)
bad=0
[ "$FILES" = "$DIRTY" ] || { bad=1; echo "    written: $FILES"; echo "    dirty:   $DIRTY"; }
printf '%s\n' "$FILES" | grep -qE '^(mockups/|tools/dev/|modules/osd/Battery|modules/common/system/BatteryData)' && bad=1
check P2a "apply --all wrote $NFILES module files, exactly the files that changed, no mockup, no test, nothing protected" $bad
bad=0
lint() { /usr/lib/qt6/bin/qmllint -I . -I /usr/lib/qt6/qml "$1" 2>&1 | sed 's/[0-9]\+:[0-9]\+/L:C/g' | sort; }
for f in $FILES; do
    new=$(lint "$f")
    cp "$f" "$WORK/promoted.qml"; git show "HEAD:$f" > "$f"      # the same path at HEAD (imports are relative), in the scratch repo
    old=$(lint "$f")
    cp "$WORK/promoted.qml" "$f"
    if [ "$new" != "$old" ]; then
        bad=1; echo "    qmllint differs for $f"; diff <(printf '%s\n' "$old") <(printf '%s\n' "$new") | head -5
    fi
done
check P2b "every written file lints as it did at HEAD (nothing new)" $bad

RT=$(mktemp -d "$HOME/.cache/lsr.XXXXXX"); chmod 700 "$RT"
XDG="$WORK/xdg"; mkdir -p "$XDG/config/theme" "$XDG/state" "$XDG/data" "$XDG/cache"
printf '{"theme":"eva","mode":"light"}\n' > "$XDG/config/theme/state.json"
trap 'rm -rf "$RT"' EXIT
qs() {  # tree, mockup, extra env... -> the quickshell's output on stdout (killed at the deadline, only its own pid)
    local tree=$1 mock=$2; shift 2
    ( cd "$tree" && exec env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE XDG_RUNTIME_DIR="$RT" XDG_CONFIG_HOME="$XDG/config" \
        XDG_STATE_HOME="$XDG/state" XDG_DATA_HOME="$XDG/data" XDG_CACHE_HOME="$XDG/cache" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi \
        QS_DISABLE_FILE_WATCHER=1 QS_DISABLE_CRASH_HANDLER=1 STUB_LOG="$STUBLOG" "$@" tools/dev/notifications_bus.sh quickshell -p "$mock" ) > "$WORK/qs.out" 2>&1 &
    local pid=$! deadline=$((SECONDS + ${SECS:-90}))
    while kill -0 "$pid" 2> /dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.3; done
    if kill -0 "$pid" 2> /dev/null; then pkill -P "$pid" 2> /dev/null; kill "$pid" 2> /dev/null; echo "(killed at the deadline)" >> "$WORK/qs.out"; fi
    wait "$pid" 2> /dev/null
    rl_clean "$WORK/qs.out"
}

noload() {  # a run that printed none of its lines did not load (or never started): the no-result verdict
    if [ -z "$1" ]; then rl_noresult "$NAME" "$WORK/qs.out"; exit 1; fi
}

# P2c the mockups of the written modules still load
if [ "${FAST:-}" != 1 ]; then
    MOCKS=$(sed -n '/^mockup /,/^TOTAL/p' "$WORK/apply1.txt" | awk '$1 ~ /\.qml$/ && $NF > 0 {print $1}')
    bad=0; n=0
    for mk in $MOCKS; do
        n=$((n + 1))
        out=$(SECS=14 qs "$REPO" "$mk" QT_LOGGING_RULES="qt.qpa.services.warning=false" | grep -E "^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property" | grep -vE "quickshell.tooling|portal|WAYLAND_DISPLAY|QT_QPA_PLATFORM|LogoRelief|Cannot open: file|ReadAll|propose|archlinux" | sort | uniq -c)
        if [ -n "$out" ]; then bad=1; echo "    $mk warns:"; printf '%s\n' "$out" | head -5 | sed 's/^/      /'; fi
    done
    check P2c "the $n mockups of the written modules load (smoke: no warning)" $bad
fi

# P3 the checker on the promoted copy
bad=0
: > "$WORK/check_all.txt"
for mk in mockups/*.qml; do grep -q "MockupWindow {" "$mk" && echo "$mk"; done > "$WORK/mockups.txt"
# a check file per mockup, named by its basename (every mockup is mockups/<moduleId>.qml)
xargs -a "$WORK/mockups.txt" -P 4 -I{} sh -c "b=\$(basename {} .qml); python3 '$REPO/tools/dev/mockup_wiring_check.py' --root '$REPO' {} > '$WORK/check_'\$b.txt 2>&1; echo \$? > '$WORK/check_'\$b.rc"
FAULTS=0; DRIFTW=0; DRIFTR=0
for mk in $(cat "$WORK/mockups.txt"); do
    b=$(basename "$mk" .qml)
    f=$(grep -E "^(UNSEEN|MISSING|DEAD|CLASH) \(" "$WORK/check_$b.txt" | grep -vc " (0)")
    FAULTS=$((FAULTS + f))
    DRIFTW=$((DRIFTW + $(grep -c "promotion writes it" "$WORK/check_$b.txt")))
    DRIFTR=$((DRIFTR + $(grep -c "promotion refuses" "$WORK/check_$b.txt")))
    [ "$(cat "$WORK/check_$b.rc")" = 0 ] || { bad=1; echo "    $mk: the checker exits $(cat "$WORK/check_$b.rc")"; }
done
check P3a "the wiring checker is clean on all $(wc -l < "$WORK/mockups.txt") promoted mockups (UNSEEN / MISSING / DEAD / CLASH: $FAULTS)" "$([ "$FAULTS" = 0 ] && [ "$bad" = 0 ] && echo 0 || echo 1)"
check P3b "DRIFT is 0 but for what is refused: $DRIFTR rows left, each saying why; $DRIFTW say the promotion would still write them" "$([ "$DRIFTW" = 0 ] && echo 0 || echo 1)"
echo "    the refusals left (each is a row the module cannot take automatically):"
grep -h "promotion refuses" "$WORK"/check_*.txt | sed 's/^ */      /' | cut -c1-230

# P4 idempotence
$PY apply --all --summary > "$WORK/apply2.txt" 2>&1
$PY dry --all --summary > "$WORK/dry2.txt" 2>&1
W2=$(sed -n 's/^MOCKUP_PROMOTE dry run \([0-9]*\) write.*/\1/p' "$WORK/dry2.txt")
check P4 "idempotent: apply again writes $(grep -c '^FILE ' "$WORK/apply2.txt") files, dry plans ${W2:-?} writes" "$([ "$(grep -c '^FILE ' "$WORK/apply2.txt")" = 0 ] && [ "${W2:-1}" = 0 ] && echo 0 || echo 1)"
git add -A > /dev/null 2>&1; git -c user.email=probe@qs -c user.name=probe commit -qm "promoted" 2> /dev/null

# P5 the bindings that must survive
bad=0
grep -q 'property bool openOverFullscreen: !!owner.service' modules/clipboard/ClipboardBarOwner.qml || { bad=1; echo "    ClipboardBarOwner.openOverFullscreen lost its binding"; }
grep -qE 'property real radius: root\.engine \? root\.engine\.' modules/bar/gooey/GooeyBar.qml || { bad=1; echo "    GooeyBar.radius lost its binding"; }
grep -q 'thickness: root.engine ? root.engine.thickness' modules/bar/gooey/GooeyBar.qml || { bad=1; echo "    GooeyBar.thickness lost its binding"; }
grep -q 'blendRadius: engine.maxR' modules/bar/gooey/GooeyEngine.qml || grep -q 'blendRadius:.*engine.maxR' modules/bar/gooey/GooeyEngine.qml || { bad=1; echo "    GooeyEngine.blendRadius lost its binding"; }
check P5 "binding defaults are never overwritten (clipboard's openOverFullscreen, GooeyBar's radius and thickness, GooeyEngine's blendRadius)" $bad

# P6 a real Save from a mockup run from the copy
: > "$STUBLOG"
out=$(qs "$REPO" mockups/system_update.qml PANEL_SAVE_TEST='{"railParams":{"glowMax":2.2,"orbitRadius":9},"layoutParams":{"railGap":9}}' | grep "PANEL_SAVE_TEST")
noload "$out"
echo "$out" | cut -c1-300 | sed 's/^/    /'
args=$(cat "$STUBLOG" 2> /dev/null)
# PhaseRail is SHARED (the OSD's stops card draws one too), so its rows land at the system update's use of it, not in PhaseRail.qml
want=$(printf '%s\n' mockups/system_update.qml modules/bar/system_update/components/SystemUpdatePopup.qml)   # sorted, as `got` is
got=$(printf '%s\n' $args | sed -n '4,$p' | sed "s#^$REPO/##" | sort)
bad=0
[ -n "$out" ] || bad=1
[ "$(printf '%s\n' $args | sed -n '1,3p' | tr '\n' ' ')" = "apply --commit system_update " ] || { bad=1; echo "    the stub was called with: $args"; }
[ "$got" = "$want" ] || { bad=1; echo "    files given to lares: $got"; }
grep -qE '^ *(rail\.)?glowMax: 2\.2 *$' modules/bar/system_update/components/SystemUpdatePopup.qml && grep -q 'property int *railGap: 9\|property real railGap: 9' modules/bar/system_update/components/SystemUpdatePopup.qml || { bad=1; echo "    the module files do not hold the saved values"; }
grep -q "val: 2.2" mockups/system_update.qml || { bad=1; echo "    the mockup's val: did not take 2.2"; }
[ "$(git log -1 --format=%s)" = "STUB - tuning: system_update" ] && [ -z "$(git status --porcelain)" ] || { bad=1; echo "    commit: $(git log -1 --format=%s); dirty: $(git status --porcelain | head -3)"; }
printf '%s\n' "$out" | grep -q "after modified=0" || { bad=1; echo "    the * marks did not clear"; }
check P6 "Save writes the module + the mockup, calls lares apply --commit with exactly those files, the commit holds just them" $bad

# P7 a shared component
git -C "$REPO" log -1 --format=%H > "$WORK/p7.base"
out=$(qs "$REPO" mockups/power.qml PANEL_SAVE_TEST='{"reelGeom":{"cellPitch":38}}' | grep "PANEL_SAVE_TEST status")
echo "$out" | cut -c1-260 | sed 's/^/    /'
bad=0
git diff --quiet HEAD~1 HEAD -- modules/common/components/IconReelStyle.qml 2> /dev/null && true
changed=$(git show --name-only --format= HEAD | sort | tr '\n' ' ')
case "$changed" in *modules/common/components/IconReelStyle.qml*) bad=1; echo "    the per-module Save changed the SHARED IconReelStyle.qml ($changed)" ;; esac
grep -q 'cellPitch: 38' modules/bar/reel/ReelBarModule.qml || { bad=1; echo "    ReelBarModule.qml (the module's use of the style) does not hold cellPitch: 38"; }
check P7a "a shared component's row (IconReelStyle.cellPitch) is written at the module's use (ReelBarModule), the shared file untouched" $bad
out=$(qs "$REPO" mockups/power.qml PANEL_SAVE_TEST='{"reelGeom":{"cellPitch":39}}' PANEL_SAVE_SHARED=reelGeom.cellPitch | grep "PANEL_SAVE_TEST status")
bad=0
grep -qE 'property real cellPitch: 39' modules/common/components/IconReelStyle.qml || { bad=1; echo "    the shared switch did not write IconReelStyle.qml"; echo "$out" | cut -c1-300; }
check P7b "the per-row 'shared default' switch writes the shared declaration (IconReelStyle.cellPitch: 39)" $bad

# P8 a refused row in a Save
out=$(qs "$REPO" mockups/clipboard.qml PANEL_SAVE_TEST='{"popupParams":{"openOverFullscreen":true}}' | grep "PANEL_SAVE_TEST status")
echo "$out" | cut -c1-300 | sed 's/^/    /'
bad=0
case "$out" in *REFUSE*"binding default"*) ;; *) bad=1; echo "    the refusal is not in the report" ;; esac
grep -q 'property bool openOverFullscreen: !!owner.service' modules/clipboard/ClipboardBarOwner.qml || { bad=1; echo "    the binding was overwritten by a Save"; }
grep -qE 'val: true' mockups/clipboard.qml || { bad=1; echo "    the mockup's val: did not take the refused value"; }
check P8 "a binding default is refused in a Save (reported, the file untouched), the mockup's own val: still saved" $bad
git -C "$REPO" checkout -q -- . 2> /dev/null; git -C "$REPO" clean -fdq 2> /dev/null     # the refused Save committed nothing: its val: stays dirty

# P9 a mockup run from a COPY: the module is not written
COPY="$WORK/copy"; mkdir -p "$COPY"
rsync -a --exclude .git "$REPO/" "$COPY/"
head=$(git -C "$REPO" rev-parse HEAD)
: > "$STUBLOG"
out=$(qs "$COPY" mockups/system_update.qml MOCKUP_REPO="$REPO" PANEL_SAVE_TEST='{"railParams":{"glowMax":2.1}}' | grep "PANEL_SAVE_TEST")
echo "$out" | cut -c1-330 | sed 's/^/    /'
bad=0
[ "$(git -C "$REPO" rev-parse HEAD)" = "$head" ] || { bad=1; echo "    a commit was made"; }
dirty=$(git -C "$REPO" status --porcelain | sed 's/^...//')
[ "$dirty" = "mockups/system_update.qml" ] || { bad=1; echo "    the repo has: $dirty (only the mockup's val: may change)"; }
grep -qE '^ *(rail\.)?glowMax: 2\.2 *$' "$REPO/modules/bar/system_update/components/SystemUpdatePopup.qml" || { bad=1; echo "    SystemUpdatePopup.qml's glowMax changed from a copy"; }
[ ! -s "$STUBLOG" ] || { bad=1; echo "    lares was called from a copy"; }
printf '%s\n' "$out" | grep -q "module not written: this mockup runs from a copy" || { bad=1; echo "    the reason is not told"; }
check P9 "from a COPY of the config the module is not written (reason told, nothing committed), the mockup's val: lands in the repo" $bad
git -C "$REPO" checkout -q -- mockups/system_update.qml 2> /dev/null

# P10 lares's statuses in the panel's line
bad=0
for st in 4 1; do
    out=$(qs "$REPO" mockups/stocks.qml STUB_STATUS=$st PANEL_SAVE_TEST='{"layoutParams":{"popupWidth":'$((510 + st))'}}' | grep "PANEL_SAVE_TEST summary")
    echo "$out" | cut -c1-260 | sed 's/^/    /'
    if [ "$st" = 4 ]; then case "$out" in *"NOT restarted (a package update"*) ;; *) bad=1 ;; esac
    else case "$out" in *"COMMIT FAILED"*"[BAD]"*) ;; *) bad=1 ;; esac; fi
    git -C "$REPO" checkout -q -- . 2> /dev/null; git -C "$REPO" clean -fdq 2> /dev/null
done
check P10 "lares's status 4 (committed, restart refused during a package update) and 1 (failed) are told in the panel's line" $bad

# P11 the REAL tool: what the stub claims to be
if [ -z "$REALDIR" ]; then
    echo "PROBE SKIP P11 no real tools/shell/lares here (this tree has none and REAL_LARES_FROM is not set): P6 and P10 ran on the stub alone"
else
    cp "$REALDIR/lares" "$REALDIR/lares-lib.sh" "$REPO/tools/shell/"; chmod +x "$REPO/tools/shell/lares"
    git -C "$REPO" config user.email probe@qs; git -C "$REPO" config user.name probe     # the real tool commits without -c
    git -C "$REPO" add -A > /dev/null 2>&1; git -C "$REPO" -c user.email=probe@qs -c user.name=probe commit -qm "the real tool" 2> /dev/null
    bad=0
    head0=$(git -C "$REPO" rev-parse HEAD)
    out=$(qs "$REPO" mockups/power.qml PANEL_SAVE_TEST='{"reelGeom":{"cellPitch":41}}' | grep "PANEL_SAVE_TEST summary")   # a value the repo does not hold yet:
    echo "$out" | cut -c1-200 | sed 's/^/    /'                                                                       # a Save that changes no module file commits nothing
    subj=$(git -C "$REPO" log -1 --format=%s); files=$(git -C "$REPO" show --name-only --format= HEAD | sort | tr '\n' ' ')
    [ "$(git -C "$REPO" rev-parse HEAD)" != "$head0" ] || { bad=1; echo "    no commit was made"; }
    [ "$subj" = "PROBE - tuning: power" ] || { bad=1; echo "    the commit is '$subj'"; }
    [ "$files" = "mockups/power.qml modules/bar/reel/ReelBarModule.qml " ] || { bad=1; echo "    the commit holds: $files"; }   # sorted
    [ -z "$(git -C "$REPO" status --porcelain)" ] || { bad=1; echo "    dirty after: $(git -C "$REPO" status --porcelain | head -3 | tr '\n' ' ')"; }
    echo "$out" | grep -qE "committed [0-9a-f]{7,}$" || { bad=1; echo "    the panel's line does not say 'committed <hash>'"; }
    check P11 "the REAL lares: a Save commits just the module file + the mockup (\"PROBE - tuning: power\": the repo's user.name), the panel says committed <hash>" $bad
fi

echo
echo "refusals in the plan: $REFUSE1"
[ "${KEEP:-}" = 1 ] || { cd "$ROOT" && rm -rf "$WORK/repo" "$WORK/copy"; }
if ! grep -q "" "$WORK/dry1.txt" 2> /dev/null || [ -z "${W1:-}" ]; then
    rl_noresult "$NAME" "$WORK/dry1.txt"; exit 1
fi
if [ "$FAILS" = 0 ]; then echo "$NAME RESULT PASS${ARM:+ (ARM=$ARM)}"; exit 0; fi
echo "$NAME RESULT FAIL${ARM:+ (ARM=$ARM)}"
exit 1
