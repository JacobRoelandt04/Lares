#!/usr/bin/env bash
# qt_gc_attach_probe.sh -- Qt's collector loses live QML objects when a GC cycle STARTS inside a component's build and the new root gets
# its parent before the cycle resumes (tools/dev/qt_gc_attach/probe.cpp has the mechanism); and the shell's cure holds.
#
#   tools/dev/qt_gc_attach_probe.sh            builds the probe against Qt's private headers and runs it offscreen (no quickshell, no window):
#                                                fault    the cycle's first slice inside the build, the rest after setParent: objects DIE on a Qt that
#                                                         has the fault (said as a NOTE; a Qt that lost it prints "Qt no longer has the fault")
#                                                whole    the whole cycle inside the build: nobody dies
#                                                none     no cycle inside the build: nobody dies
#                                                cure     the fault's run with gc() in the root's Component.onCompleted: nobody dies
#                                                product  modules/shell/ShellScreen.qml calls gc() in its Component.onCompleted, behind the
#                                                         switch (shell.jsonc "workarounds": { "gcAtScreenBuild": false } turns it off)
#   ARM=nocure tools/dev/qt_gc_attach_probe.sh the cure check run WITHOUT the cure: it must fail with "cure: <n> dead"
#   ends in QT_GC_ATTACH RESULT PASS|FAIL, and the exit status follows it
#
# WHY. 2026-11-14: the user's bar came up with 171 dead helpers (idle reel stuck open, flourishes blank, toasts mis-sized), two starts in a row.
# Run it after every Qt update: when `fault` reports 0 dead, Qt fixed it and the cure (one full collection per screen build) can go.
set -u
cd "$(dirname "$0")/../.." || exit 2
ROOT=$(pwd)
NAME=QT_GC_ATTACH
SRC="$ROOT/tools/dev/qt_gc_attach"
W=$(mktemp -d "${SCRATCH:-/tmp}/qt-gc-attach.XXXXXX") || exit 2
trap 'rm -rf "$W"' EXIT
fails=0
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
ok() { echo "  ok   $1"; }

QV=$(pkg-config --modversion Qt6Qml 2> /dev/null)
Q=/usr/include/qt6
if [ -z "$QV" ] || [ ! -f "$Q/QtQml/$QV/QtQml/private/qv4mm_p.h" ]; then
    echo "$NAME RESULT FAIL (no Qt private headers for Qt6Qml '$QV' under $Q)"; exit 1
fi
cp "$SRC"/*.qml "$SRC/probe.cpp" "$W/" || { echo "$NAME RESULT FAIL (fixtures)"; exit 1; }
if ! (cd "$W" && /usr/lib/qt6/moc probe.cpp -o probe.moc \
    && g++ -std=c++20 -O1 -fPIC -o probe probe.cpp -I. -I$Q -I$Q/QtCore -I$Q/QtGui -I$Q/QtQml \
        -I$Q/QtCore/$QV -I$Q/QtCore/$QV/QtCore -I$Q/QtQml/$QV -I$Q/QtQml/$QV/QtQml -lQt6Qml -lQt6Gui -lQt6Core) > "$W/build.log" 2>&1; then
    grep -m5 -E "error" "$W/build.log"
    echo "$NAME RESULT FAIL (the probe does not build against Qt $QV: its private API moved)"; exit 1
fi

# run <mode> [CURE=1]: D = the dead count ("" when the probe said nothing), LAST = its log. No subshell: the EXIT trap is this shell's.
N=0
run() {
    local mode=$1; shift
    N=$((N + 1)); LAST="$W/run-$N.log"
    (cd "$W" && env "$@" QT_QPA_PLATFORM=offscreen QML_DISABLE_DISK_CACHE=1 timeout 60 ./probe "$mode") > "$LAST" 2>&1
    D=$(sed -n 's/^GCATTACH mode=.* dead=\([0-9]*\) .*/\1/p' "$LAST" | tail -1)
}

echo "Qt $QV"
run 0
if [ -z "$D" ]; then fail "fault: the probe gave no result: $(tail -2 "$LAST" | tr '\n' ' ')"
elif [ "$D" -gt 0 ]; then ok "fault: $D objects die when the first slice of a cycle falls inside the build (Qt $QV has the fault)"; grep "dead " "$LAST" | sed 's/^GCATTACH/      /'
else echo "  NOTE fault: 0 dead -- Qt $QV no longer has the fault: shell.jsonc \"workarounds\": { \"gcAtScreenBuild\": false } turns the cure off"; fi
have_fault=${D:-0}

run 1; [ "$D" = 0 ] && ok "whole: the whole cycle inside the build, 0 dead" || fail "whole: ${D:-no result} dead"
run 2; [ "$D" = 0 ] && ok "none: no cycle inside the build, 0 dead" || fail "none: ${D:-no result} dead"

if [ "${ARM:-}" = nocure ]; then run 0; echo "  ARMED nocure: the cure check runs without the cure"
else run 0 CURE=1; fi
[ "$D" = 0 ] && ok "cure: gc() in the root's Component.onCompleted, 0 dead" || fail "cure: ${D:-no result} dead"

# the product: the collection is in ShellScreen's Component.onCompleted, behind ShellConfig's switch, which is on unless exactly false
blk=$(grep -A8 -E '^\s*Component\.onCompleted: \{' modules/shell/ShellScreen.qml)
if printf '%s\n' "$blk" | grep -qE 'const collect = win\.services\.shellConfig\.gcAtScreenBuild\(\);' && printf '%s\n' "$blk" | grep -A1 -E '^\s*if \(collect\)$' | grep -qE '^\s*gc\(\);' \
    && grep -qE 'function gcAtScreenBuild\(\): bool' modules/shell/ShellConfig.qml && grep -qE 'workarounds\.gcAtScreenBuild === false\)' modules/shell/ShellConfig.qml; then
    ok "product: ShellScreen.qml collects in its Component.onCompleted unless shell.jsonc workarounds.gcAtScreenBuild is false"
else fail "product: modules/shell/ShellScreen.qml / ShellConfig.qml: the collection or its switch is gone"; fi

if [ "$fails" = 0 ]; then echo "$NAME RESULT PASS (Qt $QV, fault $([ "$have_fault" -gt 0 ] && echo present || echo gone))"; exit 0; fi
echo "$NAME RESULT FAIL ($fails)"; exit 1
