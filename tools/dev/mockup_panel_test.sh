#!/usr/bin/env bash
# Exercises a mockup's control panel end to end, against scratch copies so
# nothing real is touched: nudges a value in each of its first and last
# numeric and colour lists, checks the * marks and the per-tab counts, saves
# and reloads a profile, saves the tweaks into a COPY of the mockup file and
# checks the defaults were adopted, then deletes the profile.
#
#   tools/dev/sandbox.sh tools/dev/mockup_panel_test.sh <mockup.qml>    from a sandbox copy
#   tools/dev/mockup_panel_test.sh <mockup.qml>                     from the config itself
#
# The sandbox names the real config (MOCKUP_REPO). Run from a copy that does
# not know it (MOCKUP_REPO empty, or a copy made some other way), the TARGET
# check below fails: that configuration's saves land in the copy (see there).
#
# Prints the mockup's own PANEL_TEST lines; the last is PANEL_TEST RESULT
# PASS or FAIL. Save writes the REAL implementation now (tools/dev/mockup_promote.py):
# the module's files as well as the mockup's `val:`. So the test's rule is two
# rules: the COPY of the mockup file differs from the original in nothing but
# `val:` lines (the diff below), AND no module file of the tree moved -- the
# self-test plans the module and writes none of it (`git status` of the tree's
# module files is the same before and after, and the run's report says "module
# not written" from a copy or "(dry run)" from the config itself).
set -u
# A probe's window never reaches the user's desktop (the user, 2026-10-24: "Can you not have qs tests appear on my desktop"):
# offscreen, RHI so a ShaderEffect still draws. LARES_SHOW=1 shows it, for a person watching.
[ "${LARES_SHOW:-}" = 1 ] || export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-rhi}"
cd "$(dirname "$0")/../.."
QML="${1:?usage: mockup_panel_test.sh <mockup.qml>}"
[ -f "$QML" ] || { echo "no mockup at $QML"; exit 1; }

# The module files before: a self-test must not move one (it is a test; Save would commit them).
REPO_NOW="$(git rev-parse --show-toplevel 2> /dev/null || true)"
modules_state() { [ -n "$REPO_NOW" ] && git -C "$REPO_NOW" status --porcelain=v1 --untracked-files=no -- modules 2> /dev/null | md5sum; }
MODULES_BEFORE="$(modules_state)"

WORK="${SCRATCH:-/tmp}/mockup_panel_test"
rm -rf "$WORK"; mkdir -p "$WORK/profiles"
COPY="$WORK/$(basename "$QML")"
cp "$QML" "$COPY"

LOG="$WORK/run.log"
PANEL_TEST=1 PANEL_MOCKUP_PATH="$COPY" PANEL_PROFILE_DIR="$WORK/profiles" \
    timeout 60 quickshell -p "$QML" > "$LOG" 2>&1
sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E "PANEL_TEST|rror"

# WHERE THE BUTTON WOULD WRITE WITHOUT THIS TEST'S OVERRIDE. The run above
# points PANEL_MOCKUP_PATH at a copy, which is what makes the save safe -- and
# is also why this test passed for a year while three mockups saved into a
# path that does not exist. `mockupFile` defaults to mockups/<moduleId>.qml, so a
# mockup whose filename differs must declare its own. The self-test prints the
# UNOVERRIDDEN value; it has to be a real file.
#
# AND IT HAS TO BE THE REAL ONE. Run from a copy of the config
# (tools/dev/sandbox.sh rsyncs the tree, minus .git, with --delete on every call),
# the default target is the COPY's file, which the next launch's sync puts
# back: the save reports success and is gone (R2E P1.1). tools/dev/sandbox.sh
# hands the framework the real tree (MOCKUP_REPO); the test tells the two
# apart by what a copy never has -- a git work tree.
DEFAULT_TARGET=$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -oE 'PANEL_TEST mockupFile=.*' | head -1 | cut -d= -f2-)
PROFILE_TARGET=$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -oE 'PANEL_TEST profileDir=.*' | head -1 | cut -d= -f2-)
# in_tree <path>: the path (or its nearest existing ancestor) is inside a git work tree.
in_tree() {
    local p=$1
    while [ -n "$p" ] && [ "$p" != "/" ] && [ ! -d "$p" ]; do p=$(dirname "$p"); done
    git -C "$p" rev-parse --is-inside-work-tree > /dev/null 2>&1
}
if [ -z "$DEFAULT_TARGET" ] || [ -z "$PROFILE_TARGET" ]; then
    echo "PANEL_TEST TARGET: the mockup printed no mockupFile / profileDir line: FAIL"
    exit 1
elif [ ! -f "$DEFAULT_TARGET" ]; then
    echo "PANEL_TEST TARGET: Save to mockup would write into $DEFAULT_TARGET, which does not exist: FAIL"
    echo "  (give the mockup an explicit mockupFile beside its moduleId)"
    exit 1
elif ! in_tree "$DEFAULT_TARGET" || ! in_tree "$PROFILE_TARGET"; then
    echo "PANEL_TEST TARGET: saves would land in $DEFAULT_TARGET and profiles in $PROFILE_TARGET -- not a git work tree, so a COPY (tools/dev/sandbox.sh): FAIL"
    echo "  (MOCKUP_REPO names the real config: tools/dev/sandbox.sh exports it unless the caller set it, here to '${MOCKUP_REPO-}')"
    exit 1
else
    echo "PANEL_TEST TARGET: saves would land in $DEFAULT_TARGET, profiles in $PROFILE_TARGET (the real tree): ok"
fi

echo "--- diff of the copy against the original (expect only val: lines)"
diff "$QML" "$COPY"
if [ -n "$REPO_NOW" ]; then
    if [ "$(modules_state)" = "$MODULES_BEFORE" ]; then
        echo "PANEL_TEST MODULES: no module file moved while the self-test saved: ok"
    else
        echo "PANEL_TEST MODULES: the self-test CHANGED module files (git status of modules/ differs): FAIL"
        exit 1
    fi
fi
# The save's own report: the module was planned (dry run) or refused with its reason, never written -- no
# FILE line without "(would be written)", no commit.
if sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E 'PANEL_TEST save:' | tr '|' '\n' | sed 's/^ *//' \
        | grep -E '^(FILE |commit:)' | grep -qv 'would be written'; then
    echo "PANEL_TEST MODULES: the self-test's save reports module files written or committed: FAIL"
    exit 1
fi
# The self-test's own verdict is the exit status (it printed FAIL and exited 0, so a caller that reads the status read a pass).
sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -q "PANEL_TEST RESULT PASS" || exit 1
