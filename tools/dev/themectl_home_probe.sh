#!/usr/bin/env bash
# THE THEMES' HOME, seen from the shell (theme.md L1: themectl, the shell, the lock and the mockups read ONE file per theme, so a
# mockup's theme edit reaches the deployed shell).
#
#   tools/dev/themectl_home_probe.sh               the scenarios below; last line THEMECTL_HOME RESULT PASS|FAIL
#   ARM=<name> tools/dev/themectl_home_probe.sh    one fault in the SANDBOX COPY of Theme.qml; must FAIL where it says
#   ARM=all tools/dev/themectl_home_probe.sh       every arm in turn; THEMECTL_HOME ARMS PASS only when each failed where it must
#
# tools/dev/qml/themectl_home_probe.qml runs a script of steps against the real Theme singleton, in a sandbox copy of the tree (its themes/ is
# "the repo's") with a PRIVATE XDG_CONFIG_HOME (its theme/themes/ is "the user's"; the state is seeded, never the real one):
#   H1 home-wins        the user's eva.json differs from the repo's in one token: the shell reads the user's (path, directory, colour)
#   H2 repo-fallback    no user's copy: the repo's answers, as before
#   H3 save-to-home     a themed row's Save (Theme.setToken) lands in the user's file, ALL its other keys intact (the desktop keys
#                       and the assets block that only themectl reads), and the repo's copy is not touched
#   H4 save-to-repo     with no user's copy a Save lands in the repo's file, as it always did, and no user's copy is made
#   H5 union + switch   the pairs are the names in both directories once each; a pair that lives in the user's directory loads; switching
#                       eva -> zeta -> eva reads each file's OWN bytes (a FileView repointed to a second path hands back the first's)
#   H6 appears-later    the user's copy appears while the repo's is in use (themectl install, shell running): informational -- it
#                       reports whether the shell switches without a restart, and does not fail the run either way
#   H7 follows themectl the REAL themectl (`toggle --only lares`, a HOME of its own, nothing else is written) flips state.json under a
#                       running shell: Theme follows it by itself (the button in "themectl" mode relies on exactly this)
# Arms:  repofirst  the repo's file is looked at before the user's      -> H1
#        writerepo  a Save always lands in the repo's file             -> H3
#        nounion    the pairs of the user's directory only             -> H5
#        repoint    ONE FileView, repointed per theme file             -> H5 (the stale-bytes law)
#        nofollow   the state file is not re-read when it changes      -> H7
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
. tools/dev/result_lib.sh
NAME=THEMECTL_HOME
SCRATCH="${SCRATCH:-/tmp}"
ARM="${ARM:-}"

if [ "$ARM" = all ]; then
    declare -A MUST=( [repofirst]="H1" [writerepo]="H3" [nounion]="H5" [repoint]="H5" [nofollow]="H7" )
    bad=0
    for a in ${ONLY_ARMS:-repofirst writerepo nounion repoint nofollow}; do
        log="$SCRATCH/themectl_home-arm-$a.out"
        mkdir -p "$SCRATCH"
        ARM="$a" SCRATCH="$SCRATCH" "$ROOT/tools/dev/themectl_home_probe.sh" > "$log" 2>&1
        last=$(tail -1 "$log")
        if rl_isnoresult "$last"; then echo "  ARM $a: the armed copy did not load -- it proves nothing: $last"; bad=1; continue; fi
        failed=$(grep -oE "^FAIL +H[0-9]" "$log" | awk '{print $2}' | sort -u | tr '\n' ' ')
        case " $failed" in *" ${MUST[$a]} "*) ok=1 ;; *) ok=0 ;; esac
        if [ "$last" = "$NAME RESULT FAIL (ARM=$a)" ] && [ "$ok" = 1 ]; then
            echo "  ARM $a: FAIL, as it must -- red: ${failed% }"
        else
            echo "  ARM $a: NOT PROVEN -- '$last', must be red: ${MUST[$a]}, red: ${failed% } ($log)"
            bad=1
        fi
    done
    [ "$bad" = 0 ] && { echo "$NAME ARMS PASS (every arm failed where it must)"; exit 0; }
    echo "$NAME ARMS FAIL"
    exit 1
fi
case "$ARM" in ""|repofirst|writerepo|nounion|repoint|nofollow) ;; *) echo "unknown ARM=$ARM"; echo "$NAME RESULT FAIL"; exit 2 ;; esac

OUT="$SCRATCH/themectl_home${ARM:+-$ARM}"
rm -rf "$OUT"
mkdir -p "$OUT"
SB="$OUT/tree"
SANDBOX="$SB" tools/dev/sandbox.sh > /dev/null || { echo "$NAME RESULT FAIL (no sandbox)"; exit 1; }
# the sandbox copy of the tree is the bulk (and goes); the scenarios' logs stay, a verdict line names one
cleanup() { rm -rf "$SB"; }
trap cleanup EXIT

if [ -n "$ARM" ]; then
    python3 - "$SB" "$ARM" <<'PY' || { echo "ARM $ARM: anchor not found exactly once"; echo "$NAME RESULT FAIL (arm)"; exit 2; }
import sys
root, arm = sys.argv[1:]
p = root + "/modules/common/theme/Theme.qml"
s = open(p, encoding="utf-8").read()
if arm == "repofirst":
    a = '''        let view = root._viewFor(root.homeThemesDir + "/" + file);
        let txt = view.text();
        if (!txt || txt.length === 0) {
            view = root._viewFor(root.repoThemesDir + "/" + file);
            txt = view.text();
        }'''
    b = '''        let view = root._viewFor(root.repoThemesDir + "/" + file);
        let txt = view.text();
        if (!txt || txt.length === 0) {
            view = root._viewFor(root.homeThemesDir + "/" + file);
            txt = view.text();
        }'''
elif arm == "writerepo":
    a = '''        const view = root._themeView ? root._themeView : root._viewFor(root.homeThemesDir + "/" + root._themeName + ".json");'''
    b = '''        const view = root._viewFor(root.repoThemesDir + "/" + root._themeName + ".json");'''
elif arm == "nounion":
    a = '''            root._onPairs(m.home + "\\n" + m.repo);'''
    b = '''            root._onPairs(m.home);'''
elif arm == "nofollow":
    a = '''        onFileChanged: stateFile.reload()'''
    b = '''        onFileChanged: { }'''
elif arm == "repoint":
    a = '''    function _viewFor(path) {
        let v = root._views[path];
        if (!v) {
            v = themeViewComp.createObject(root, { "path": path });
            root._views[path] = v;
        }
        return v;
    }'''
    b = '''    function _viewFor(path) {
        let v = root._views["one"];
        if (!v) {
            v = themeViewComp.createObject(root, { "path": path });
            root._views["one"] = v;
        }
        v.path = path;
        return v;
    }'''
if s.count(a) != 1:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PY
    echo "ARMED $ARM in the sandbox copy of Theme.qml" >&2
fi

# run_qml <dir> <steps> [live-seconds]: the probe once with the dir's cfg as XDG_CONFIG_HOME; prints the THP lines
run_qml() {
    local d=$1 steps=$2 log pid i=0
    log="$d/run.log"
    ( cd "$SB" && exec env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi \
        QS_DISABLE_FILE_WATCHER=1 QS_DISABLE_CRASH_HANDLER=1 XDG_CONFIG_HOME="$d/cfg" THP_STEPS="$steps" \
        quickshell -p "$SB/tools/dev/qml/themectl_home_probe.qml" ) > "$log" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2> /dev/null && [ $i -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
    kill -0 "$pid" 2> /dev/null && kill "$pid" 2> /dev/null
    wait "$pid" 2> /dev/null
    if ! rl_has "$log" "THP RESULT done"; then
        [ -n "$ARM" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing" >&2
        rl_noresult "$NAME" "$log" >&2
        return 1
    fi
    rl_clean "$log" | grep -a -o "THP .*" | sed 's/^THP //'
}

seed() {  # seed <dir> [state-theme] [state-mode]: a private config home with the theme state
    mkdir -p "$1/cfg/theme"
    printf '{"theme":"%s","mode":"%s"}\n' "${2:-eva}" "${3:-light}" > "$1/cfg/theme/state.json"
}

home_theme() {  # home_theme <dir> <name> <light-accent>: the user's copy: the repo's eva.json under another name/accent
    mkdir -p "$1/cfg/theme/themes"
    python3 - "$SB/themes/eva.json" "$1/cfg/theme/themes/$2.json" "$2" "$3" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["name"] = sys.argv[3]
doc["light"]["accent"] = sys.argv[4]
json.dump(doc, open(sys.argv[2], "w"), indent=2)
PY
}

fails=0
verdict() {  # verdict <id> <ok:0|1> <what> [detail]
    if [ "$2" = 1 ]; then echo "ok   $1 $3"; else echo "FAIL $1 $3${4:+ -- $4}"; fails=$((fails + 1)); fi
}
field() {  # field <line> <key> -> value (up to the next space; path/dir have none)
    printf '%s\n' "$1" | grep -a -o "$2=[^ ]*" | head -1 | sed "s/^$2=//"
}
REPO_SHA=$(sha1sum "$SB/themes/eva.json" | cut -d' ' -f1)

# H1 home-wins
d="$OUT/h1"; seed "$d"; home_theme "$d" eva "#123456"
out=$(run_qml "$d" "print;quit") || exit 1; l=$(printf '%s\n' "$out" | grep -a '^print#' | tail -1)
verdict H1 $([ "$(field "$l" accent)" = "#123456" ] && [ "$(field "$l" path)" = "$d/cfg/theme/themes/eva.json" ] && [ "$(field "$l" dir)" = "$d/cfg/theme/themes" ] && echo 1 || echo 0) \
    "the user's copy is the file the shell reads" "$l"

# H2 repo-fallback
d="$OUT/h2"; seed "$d"
out=$(run_qml "$d" "print;quit") || exit 1; l=$(printf '%s\n' "$out" | grep -a '^print#' | tail -1)
verdict H2 $([ "$(field "$l" accent)" = "#4480F4" ] && [ "$(field "$l" path)" = "$SB/themes/eva.json" ] && echo 1 || echo 0) "without one, the repo's copy answers" "$l"

# H3 save-to-home
d="$OUT/h3"; seed "$d"; home_theme "$d" eva "#123456"
out=$(run_qml "$d" "print;set accent #ABCDEF;wait 700;print;quit") || exit 1; l=$(printf '%s\n' "$out" | grep -a '^print#' | tail -1)
python3 - "$d/cfg/theme/themes/eva.json" "$SB/themes/eva.json" > "$d/judge" <<'PY'
import json, sys
mine, repo = (json.load(open(p)) for p in sys.argv[1:3])
ok_edit = mine["light"]["accent"] == "#ABCDEF"
ok_keep = all(k in mine["light"] for k in ("hyprBorderActive", "starshipRamp0", "lockIncorrect")) and "assets" in mine and mine["assets"] == repo["assets"] \
    and mine["dark"] == repo["dark"]
print("edit=%d keep=%d" % (ok_edit, ok_keep))
PY
verdict H3 $([ "$(field "$l" accent)" = "#ABCDEF" ] && [ "$(cat "$d/judge")" = "edit=1 keep=1" ] && [ "$(sha1sum "$SB/themes/eva.json" | cut -d' ' -f1)" = "$REPO_SHA" ] && echo 1 || echo 0) \
    "a Save lands in the user's file, every other key intact, the repo's copy untouched" "$(cat "$d/judge") $l"

# H4 save-to-repo
d="$OUT/h4"; seed "$d"
out=$(run_qml "$d" "print;set accent #ABCDEF;wait 700;print;quit") || exit 1
python3 - "$SB/themes/eva.json" > "$d/judge" <<'PY'
import json, sys
print("edit=%d" % (json.load(open(sys.argv[1]))["light"]["accent"] == "#ABCDEF"))
PY
verdict H4 $([ "$(cat "$d/judge")" = "edit=1" ] && [ ! -e "$d/cfg/theme/themes/eva.json" ] && echo 1 || echo 0) "with no user's copy a Save lands in the repo's file and makes none" "$(cat "$d/judge") home:$(ls "$d/cfg/theme/themes" 2>&1 | head -1)"
cp "$SB/themes/eva.json" "$OUT/eva-edited.json"
# put the repo's copy back for the scenarios below (a sandbox copy: the tree itself was never touched)
cp "$ROOT/themes/eva.json" "$SB/themes/eva.json"
REPO_SHA=$(sha1sum "$SB/themes/eva.json" | cut -d' ' -f1)

# H5 union + switch
d="$OUT/h5"; seed "$d" zeta light; home_theme "$d" zeta "#00FF00"
out=$(run_qml "$d" "print;theme eva;wait 200;print;theme zeta;wait 200;print;quit") || exit 1
l1=$(printf '%s\n' "$out" | grep -a '^print#1' | head -1); l2=$(printf '%s\n' "$out" | grep -a '^print#4' | head -1); l3=$(printf '%s\n' "$out" | grep -a '^print#7' | head -1)
# every pair the repo ships, and zeta from the user's directory, once each and sorted (the repo's list grows: read it, never write it out)
want_pairs=$(python3 -c 'import json, os, sys; print(json.dumps(sorted({f[:-5] for f in os.listdir(sys.argv[1]) if f.endswith(".json")} | {"zeta"}), separators=(",", ":")))' "$SB/themes")
verdict H5 $([ "$(field "$l1" pairs)" = "$want_pairs" ] && [ "$(field "$l1" accent)" = "#00FF00" ] && [ "$(field "$l1" path)" = "$d/cfg/theme/themes/zeta.json" ] \
    && [ "$(field "$l2" accent)" = "#4480F4" ] && [ "$(field "$l2" path)" = "$SB/themes/eva.json" ] && [ "$(field "$l3" accent)" = "#00FF00" ] && echo 1 || echo 0) \
    "the pairs are both directories' names once; zeta loads from the user's, eva from the repo's, zeta again its own bytes" "$l1 | $l2 | $l3"

# H6 appears-later (informational)
if [ -z "$ARM" ]; then
    d="$OUT/h6"; seed "$d"; mkdir -p "$d/cfg/theme/themes"
    ( sleep 1.0; home_theme "$d" eva "#123456" ) &
    out=$(run_qml "$d" "print;wait 1500;print;set accent #ABCDEF;wait 700;print;quit") || exit 1; wait
    l2=$(printf '%s\n' "$out" | grep -a '^print#3' | head -1)
    if [ "$(field "$l2" accent)" = "#123456" ]; then echo "info H6 the user's copy that appears while the shell runs IS picked up (no restart needed)"
    else echo "info H6 the user's copy that appears while the shell runs is NOT picked up until the shell restarts (themectl install is run at the cutover, with a restart): $l2"; fi
fi

# H7 follows themectl: the real themectl flips state.json under a running shell (the stub-free half of the button's "themectl" mode)
d="$OUT/h7"; seed "$d"; mkdir -p "$d/home"
( sleep 1.2; env -i HOME="$d/home" XDG_CONFIG_HOME="$d/cfg" PATH=/usr/bin:/bin python3 -B "$ROOT/tools/theme/themectl" toggle --only lares > "$d/themectl.out" 2>&1 ) &
out=$(run_qml "$d" "print;wait 2200;print;quit") || exit 1; wait
l1=$(printf '%s\n' "$out" | grep -a '^print#1' | head -1); l2=$(printf '%s\n' "$out" | grep -a '^print#3' | head -1)
verdict H7 $([ "$(field "$l1" mode)" = light ] && [ "$(field "$l2" mode)" = dark ] && [ "$(field "$l1" accent)" != "$(field "$l2" accent)" ] && grep -q '^ok    lares ' "$d/themectl.out" && echo 1 || echo 0) \
    "themectl's state.json write is followed by the running shell (light -> dark, by itself)" "$l1 | $l2 | $(head -c 160 "$d/themectl.out")"

if [ "$fails" = 0 ]; then
    echo "$NAME RESULT PASS"
    exit 0
fi
echo "$NAME RESULT FAIL${ARM:+ (ARM=$ARM)}"
exit 1
