#!/usr/bin/env bash
# themectl_hyprpaper_env_probe.sh -- themectl's wallpaper target against the REAL hyprpaper (0.8+) in the nested Hyprland of lock_env.sh.
#
#   tools/dev/themectl_hyprpaper_env_probe.sh              ends in THEMECTL_HYPRPAPER RESULT PASS|FAIL
#   ARM=noname tools/dev/...                               hyprpaper_show() does nothing in a copy (the fallback request alone, as before
#                                                          2026-11-11): S3 must FAIL with the stray picture still on screen
#   ARM=all tools/dev/...                                  every arm in turn: THEMECTL_HYPRPAPER ARMS RESULT PASS | FAIL
#   BASE=<rev> tools/dev/...                               run another revision's themectl (git show <rev>:tools/theme/themectl) -- the
#                                                          user's fault before the fix: S3 FAILs
#   THPAPER_KEEP=1                                         keep the nested env up at the end
#
# WHY (2026-11-11). hyprpaper 0.8.5 lets a wallpaper set for a NAMED monitor beat the fallback until it restarts, and a fallback request it then
# ignores answers exit 0 and nothing. themectl's Revert of an inserted slot told hyprpaper the old picture BY MONITOR NAME, so every later
# switch (each a fallback request) was ignored while the target said "ran": the user's wallpaper froze. A stub hyprctl cannot see that; only the
# real daemon can (CLAUDE.md: A TARGET'S ok COUNTS ONLY IF THE REAL PROGRAM REACTS).
#
# THE STEPS. A private hyprpaper (its own config, fallback a.png) in lock_env; themectl run INSIDE the env (its XDG dirs are the env's: the
# shell.jsonc, theme state, bag and hyprpaper.conf it reads and writes are private; nothing of the user's), `--only wallpaper`:
#   S1  themectl set eva light            -> the fallback request; LOCK-1 shows b.png, the target says ok
#   S2  hyprctl hyprpaper wallpaper LOCK-1,d.png   (what the old Revert sent: a named wallpaper)
#   S3  themectl set eva dark             -> LOCK-1 shows c.png (before the fix: d.png stayed and the target said "ran")
#   S4  themectl set eva light            -> b.png again (a switch after the named pass is not stuck on the named one either)
# Each step reads `hyprctl hyprpaper listactive` and the target's own line.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAME=THEMECTL_HYPRPAPER
E="$ROOT/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-thpaper}"

# ARM=all: every arm in turn, each must fail its own check (S3) -> THEMECTL_HYPRPAPER ARMS RESULT PASS | FAIL
if [ "${ARM:-}" = all ]; then
    rc=0
    for a in noname; do
        out=$(ARM="$a" THPAPER_KEEP= bash "$0" 2>&1)
        if printf '%s\n' "$out" | grep -aq "its anchor is gone"; then
            echo "ARM $a: NOT PROVEN (its anchor is gone)"; rc=1
        elif printf '%s\n' "$out" | grep -aq "^$NAME RESULT FAIL" && printf '%s\n' "$out" | grep -aq "^THP FAIL S3 the next switch shows its picture over a named one"; then
            echo "ARM $a: FAILED AS IT MUST ($(printf '%s\n' "$out" | grep -a '^THP FAIL S3' | head -1 | cut -c10-150))"
        elif printf '%s\n' "$out" | grep -aq "^$NAME RESULT FAIL"; then
            echo "ARM $a: FAILED, BUT NOT AT S3: $(printf '%s\n' "$out" | grep -a 'FAIL' | head -1 | cut -c1-150)"; rc=1
        else
            echo "ARM $a: STAYED GREEN"; rc=1
        fi
    done
    [ "$rc" = 0 ] && echo "$NAME ARMS RESULT PASS" || echo "$NAME ARMS RESULT FAIL"
    exit "$rc"
fi
W="$(mktemp -d "${TMPDIR:-/tmp}/thpaper.XXXXXX")"
cleanup() { [ -n "${THPAPER_KEEP:-}" ] || "$E" down > /dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT
fail=0
say() { echo "THP $*"; }
check() { if [ "$2" = 1 ]; then say "ok   $1"; else say "FAIL $1 ($3)"; fail=1; fi; }

# the themectl to run: today's, another revision's, or an armed copy (a minimal tree: themectl finds its repo two levels up)
T="$ROOT"
if [ -n "${BASE:-}" ] || [ -n "${ARM:-}" ]; then
    T="$W/tree"
    mkdir -p "$T/tools" "$T/modules/common"
    cp -r "$ROOT/tools/theme" "$ROOT/tools/lib" "$T/tools/"
    cp -r "$ROOT/themes" "$T/"
    cp -r "$ROOT/modules/common/theme" "$T/modules/common/"
    if [ -n "${BASE:-}" ]; then
        git -C "$ROOT" show "$BASE:tools/theme/themectl" > "$T/tools/theme/themectl" || { echo "$NAME RESULT FAIL (no themectl at $BASE)"; exit 1; }
    fi
    case "${ARM:-}" in
        "") ;;
        noname) python3 - "$T/tools/theme/themectl" <<'PY' || { echo "$NAME RESULT FAIL (ARM noname: its anchor is gone)"; exit 1; }
import sys
p = sys.argv[1]; s = open(p).read()
a = "    want = os.path.realpath(path)\n\n    def off():\n"
if s.count(a) != 1:
    raise SystemExit(1)
open(p, "w").write(s.replace(a, "    return []\n" + a))
PY
        ;;
        *) echo "$NAME RESULT FAIL (unknown ARM ${ARM})"; exit 1 ;;
    esac
fi
TC="$T/tools/theme/themectl"

# four pictures hyprpaper can draw, distinct colours
python3 - "$W" <<'PY' || { echo "$NAME RESULT FAIL (PIL)"; exit 1; }
import sys
from PIL import Image
for n, c in (("a", (200, 40, 40)), ("b", (40, 200, 40)), ("c", (40, 40, 200)), ("d", (200, 200, 40))):
    Image.new("RGB", (320, 180), c).save("%s/%s.png" % (sys.argv[1], n))
PY
printf 'splash = false\nipc = true\nwallpaper {\n    monitor =\n    path = %s\n    fit_mode = cover\n}\n' "$W/a.png" > "$W/hyprpaper.conf"

MODE=light AUTOSTART="hyprpaper -c $W/hyprpaper.conf" timeout 180 "$E" up > "$W/up.log" 2>&1 \
    || { cat "$W/up.log"; echo "$NAME RESULT FAIL (the nested env did not come up)"; exit 1; }
B="$(sed -n 's/^LOCK_ENV UP [^ ]* dir=\([^ ]*\) .*/\1/p' "$W/up.log" | tail -1)"
[ -d "$B/cfg" ] || { echo "$NAME RESULT FAIL (no env config dir in: $(tail -1 "$W/up.log"))"; exit 1; }
active() { "$E" hyprctl hyprpaper listactive 2>/dev/null | sed -n 's/^LOCK-1: //p' | tail -1; }
for _ in $(seq 1 40); do [ "$(active)" = "$W/a.png" ] && break; sleep 0.25; done
check "S0 the private hyprpaper shows its fallback" "$([ "$(active)" = "$W/a.png" ] && echo 1)" "$(active)"

# the env's own shell.jsonc: eva light / dark, absolute paths; the theme state starts on eva light
mkdir -p "$B/cfg/quickshell" "$B/cfg/theme"
printf '{\n    "theme": { "wallpapers": { "eva": { "light": "%s", "dark": "%s" } } }\n}\n' "$W/b.png" "$W/c.png" > "$B/cfg/quickshell/shell.jsonc"
tc() { "$E" run python3 "$TC" set "$1" "$2" --only wallpaper 2>&1 | grep -a '^\(ok\|FAIL\) *wallpaper' | tail -1; }

out=$(tc eva light)
check "S1 a switch shows its picture" "$([ "$(active)" = "$W/b.png" ] && echo 1)" "shows $(active); themectl: $out"
"$E" hyprctl hyprpaper wallpaper "LOCK-1,$W/d.png,cover" > /dev/null 2>&1
check "S2 a named wallpaper is on screen (what the old Revert left)" "$([ "$(active)" = "$W/d.png" ] && echo 1)" "shows $(active)"
out=$(tc eva dark)
check "S3 the next switch shows its picture over a named one" "$([ "$(active)" = "$W/c.png" ] && echo 1)" "shows $(active); themectl: $out"
check "S3 the target's word matches the screen" "$(case "$out" in ok*) [ "$(active)" = "$W/c.png" ] && echo 1 ;; FAIL*) [ "$(active)" != "$W/c.png" ] && echo 1 ;; esac)" "themectl: $out; shows $(active)"
out=$(tc eva light)
check "S4 a later switch is not stuck either" "$([ "$(active)" = "$W/b.png" ] && echo 1)" "shows $(active); themectl: $out"

if [ "$fail" = 0 ]; then echo "$NAME RESULT PASS (6 checks)"; exit 0; fi
echo "$NAME RESULT FAIL"; exit 1
