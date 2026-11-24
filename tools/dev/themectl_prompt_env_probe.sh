#!/usr/bin/env bash
# themectl_prompt_env_probe.sh -- a starship prompt ALREADY ON SCREEN follows a theme switch: the real themectl, the real kitty,
# the real starship (and yazi's starship header when the user's starship.yazi plugin is installed), nested in lock_env.sh.
#
#   tools/dev/themectl_prompt_env_probe.sh       ends in THEMECTL_PROMPT RESULT PASS|FAIL
#   ARM=hex tools/dev/...                        the prompt template prints hex colours again (as before 2026-11-21): the prompt
#                                                printed in light must keep its light colours after the switch to dark -> FAIL
#   ARM=all tools/dev/...                        THEMECTL_PROMPT ARMS RESULT PASS | FAIL
#   THPROMPT_KEEP=1                              keep the nested env up at the end
#   THPROMPT_SHOTS=<dir>                         copy the two screenshots there (light.png, dark.png)
#
# WHY. A terminal stores a hex colour in the cell, so a prompt printed under one theme kept that theme's powerline for as long as it
# stayed on screen. The template now prints palette SLOT numbers (53-56, 89-92) and kitty's theme file gives the slots their
# colours: kitty keeps the slot in the cell, and its config reload recolours every prompt already printed. A stub cannot show that.
#
# THE STEPS. themectl runs INSIDE the env (its XDG dirs are the env's; `pkill` is a stub that signals only the env's own kitty:
# the real one would signal every kitty of the user). eva light is applied, a kitty prints the prompt and stays; the screen must hold
# eva light's ramp. eva dark is applied; the SAME prompt must now hold eva dark's ramp and none of light's.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAME=THEMECTL_PROMPT
E="$ROOT/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-thprompt}"
# shellcheck source=tools/dev/result_lib.sh
. "$ROOT/tools/dev/result_lib.sh"

if [ "${ARM:-}" = all ]; then
    rc=0
    for a in hex; do
        out=$(ARM="$a" THPROMPT_KEEP= bash "$0" 2>&1)
        if printf '%s\n' "$out" | grep -aq "its anchor is gone"; then
            echo "ARM $a: NOT PROVEN (its anchor is gone)"; rc=1
        elif printf '%s\n' "$out" | grep -aq "^$NAME RESULT FAIL" && printf '%s\n' "$out" | grep -aq "^THPR FAIL S3 the prompt printed in light"; then
            echo "ARM $a: FAILED AS IT MUST ($(printf '%s\n' "$out" | grep -a '^THPR FAIL S3' | head -1 | cut -c11-150))"
        elif printf '%s\n' "$out" | grep -aq "^$NAME RESULT FAIL"; then
            echo "ARM $a: FAILED, BUT NOT AT S3: $(printf '%s\n' "$out" | grep -a 'FAIL' | head -1 | cut -c1-150)"; rc=1
        else
            echo "ARM $a: STAYED GREEN"; rc=1
        fi
    done
    [ "$rc" = 0 ] && echo "$NAME ARMS RESULT PASS" || echo "$NAME ARMS RESULT FAIL"
    exit "$rc"
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/thprompt.XXXXXX")"
cleanup() { [ -n "${THPROMPT_KEEP:-}" ] || "$E" down > /dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT
fail=0; n=0
say() { echo "THPR $*"; }
check() { n=$((n + 1)); if [ "$2" = 1 ]; then say "ok   $1"; else say "FAIL $1 ($3)"; fail=1; fi; }

# the themectl to run: a minimal tree (themectl finds its repo two levels up), armed or not
T="$W/tree"
mkdir -p "$T/tools" "$T/modules/common"
cp -r "$ROOT/tools/theme" "$ROOT/tools/lib" "$T/tools/"
cp -r "$ROOT/themes" "$T/"
cp -r "$ROOT/modules/common/theme" "$T/modules/common/"
if [ "${ARM:-}" = hex ]; then
    python3 - "$T/tools/theme/templates/starship.toml" <<'PY' || { echo "$NAME RESULT FAIL (ARM hex: its anchor is gone)"; exit 1; }
import re, sys
p = sys.argv[1]; s = open(p).read()
slots = {"53": "starshipRamp0", "54": "starshipRamp1", "55": "starshipRamp2", "56": "starshipRamp3", "89": "starshipHead", "90": "textOnAccent"}
body = s.split('format = """', 1)
if len(body) != 2 or "bg:56" not in body[1]:
    raise SystemExit(1)
out = re.sub(r"(?<![\w#])(53|54|55|56|89|90)(?!\d)", lambda m: "{{%s}}" % slots[m.group(1)], body[1])
open(p, "w").write(body[0] + 'format = """' + out)
PY
elif [ -n "${ARM:-}" ]; then
    echo "$NAME RESULT FAIL (unknown ARM $ARM)"; exit 1
fi
TC="$T/tools/theme/themectl"

"$E" down > /dev/null 2>&1
MODE=light timeout 180 "$E" up > "$W/up.log" 2>&1 || { cat "$W/up.log"; echo "$NAME RESULT FAIL (the nested env did not come up)"; exit 1; }
B="$(sed -n 's/^LOCK_ENV UP [^ ]* dir=\([^ ]*\) .*/\1/p' "$W/up.log" | tail -1)"
[ -d "$B/cfg" ] || { echo "$NAME RESULT FAIL (no env config dir)"; exit 1; }
mkdir -p "$B/cfg/kitty" "$W/stubs"
printf 'include current-theme.conf\nremember_window_size no\nconfirm_os_window_close 0\nfont_size 22\n' > "$B/cfg/kitty/kitty.conf"
# pkill, for this env only: the kitty processes that carry the env's marker
cat > "$W/stubs/pkill" <<STUB
#!/bin/sh
for p in /proc/[0-9]*; do
    [ "\$(cat \$p/comm 2>/dev/null)" = kitty ] || continue
    tr '\\0' '\\n' < \$p/environ 2>/dev/null | grep -qx "LOCK_ENV_DIR=$B" && kill -USR1 "\${p#/proc/}"
done
exit 0
STUB
chmod +x "$W/stubs/pkill"
tc() { "$E" run env PATH="$W/stubs:$PATH" python3 "$TC" set eva "$1" --only kitty,starship 2>&1 | grep -a '^\(ok\|FAIL\) *\(kitty\|starship\)' | tr '\n' ' '; }

out=$(tc light)
check "S1 themectl writes kitty's and the prompt's files" "$(case "$out" in *"ok "*kitty*"ok "*starship*|*"ok "*starship*"ok "*kitty*) echo 1 ;; esac)" "$out"
# a kitty that prints the prompt twice and stays. starship reads ~/.config/starship.toml by HOME, not by XDG_CONFIG_HOME, and HOME
# is the user's here: STARSHIP_CONFIG names the file themectl wrote in the env.
"$E" hyprctl dispatch "hl.dsp.exec_cmd('env STARSHIP_CONFIG=$B/cfg/starship.toml kitty --class thprompt --hold sh -c \"cd /usr/share; starship prompt; echo; echo; starship prompt; echo\"')" > /dev/null
YAZI=0
if [ -d "$HOME/.config/yazi/plugins/starship.yazi" ] && command -v yazi > /dev/null 2>&1; then
    mkdir -p "$B/cfg/yazi/plugins"
    cp -r "$HOME/.config/yazi/plugins/starship.yazi" "$B/cfg/yazi/plugins/"
    printf 'require("starship"):setup()\n' > "$B/cfg/yazi/init.lua"
    "$E" hyprctl dispatch "hl.dsp.exec_cmd('env STARSHIP_CONFIG=$B/cfg/starship.toml kitty --class thyazi yazi /usr/share')" > /dev/null
    YAZI=1
fi
sleep 5
"$E" shot "$W/light.png" > /dev/null 2>&1
out=$(tc dark)
sleep 2
"$E" shot "$W/dark.png" > /dev/null 2>&1

python3 - "$W" "$ROOT/themes/eva.json" "$YAZI" > "$W/judge.txt" <<'PY'
import json, re, sys
from PIL import Image
W, theme, yazi = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
t = json.load(open(theme))
def rgb(h): return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))
ramp = {m: [rgb(t[m][k]) for k in ("starshipRamp0", "starshipRamp1", "starshipRamp2", "starshipRamp3")] for m in ("light", "dark")}
def count(path):
    im = Image.open(path).convert("RGB"); w, h = im.size
    halves = {"kitty": im.crop((0, 0, w // 2, h)), "yazi": im.crop((w // 2, 0, w, h))} if yazi else {"kitty": im}
    out = {}
    for name, part in halves.items():
        cols = {}
        for n, c in part.getcolors(maxcolors=1 << 24):
            cols[c] = n
        out[name] = {m: sum(cols.get(c, 0) for c in ramp[m]) for m in ramp}
    return out
print(json.dumps({"light": count(W + "/light.png"), "dark": count(W + "/dark.png")}))
PY
J="$(cat "$W/judge.txt")"
say "pixels of each mode's ramp: $J"
val() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['$1'].get('$2',{}).get('$3',-1))" "$J"; }
check "S2 the prompt is printed in light's ramp" "$([ "$(val light kitty light)" -gt 300 ] && [ "$(val light kitty dark)" = 0 ] && echo 1)" "light $(val light kitty light) px, dark $(val light kitty dark) px"
check "S3 the prompt printed in light shows dark's ramp after the switch" "$([ "$(val dark kitty dark)" -gt 300 ] && [ "$(val dark kitty light)" = 0 ] && echo 1)" "dark $(val dark kitty dark) px, light $(val dark kitty light) px left; themectl: $out"
if [ "$YAZI" = 1 ]; then
    check "S2 yazi's header is in light's ramp" "$([ "$(val light yazi light)" -gt 100 ] && echo 1)" "light $(val light yazi light) px"
    check "S3 yazi's header shows dark's ramp after the switch" "$([ "$(val dark yazi dark)" -gt 100 ] && [ "$(val dark yazi light)" = 0 ] && echo 1)" "dark $(val dark yazi dark) px, light $(val dark yazi light) px left"
else
    say "note the user's starship.yazi plugin is not installed: yazi's header is not checked"
fi
[ -n "${THPROMPT_SHOTS:-}" ] && mkdir -p "$THPROMPT_SHOTS" && cp "$W/light.png" "$W/dark.png" "$THPROMPT_SHOTS/"
if [ "$fail" = 0 ]; then echo "$NAME RESULT PASS ($n checks)"; exit 0; fi
cp "$W/light.png" "${TMPDIR:-/tmp}/thprompt_light.png" 2> /dev/null; cp "$W/dark.png" "${TMPDIR:-/tmp}/thprompt_dark.png" 2> /dev/null
echo "$NAME RESULT FAIL (shots: ${TMPDIR:-/tmp}/thprompt_light.png, thprompt_dark.png)"; exit 1
