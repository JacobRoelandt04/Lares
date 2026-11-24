#!/usr/bin/env bash
# aerial_tunnel_probe.sh -- the tunnel's transition judged on the REAL popup (round 4): the mock service brings the tunnel up and takes it down, and the label must WIPE
# (many drawn frames between paper and chrome, no jump), not flip, with no script error in the log. Round 3 proved the wipe on the label alone (aerial_r3_label.sh) and it
# never played on the desktop: the engine builds a popup asynchronously, the label's rows then arrive over several turns (the last one first), the first placement read rows
# that were not there and threw inside the label's completion, and the label stayed "being built" (every motion snapped) for its whole life.
#   tools/dev/aerial_tunnel_probe.sh [outdir]      FAMILY=0|1   THEME=eva MODE=light|dark   THEMES_FROM=<dir>   FILM=1 also grabs five stills of the wipe into <outdir>/film
#   BUILD=sync  the popup built in one go; the default is the ENGINE's build (incubated asynchronously, parked, then opened); BUILD=force FORCE_MS=<n> completes the
#               incubation by force after n ms (a click while the hover's build is in the air)
#   WAYLAND=1   the same harness as a client of the nested Hyprland (tools/dev/lock_env.sh: a Wayland GL context, the compositor's frames)
#   ARM=snap       the wipe's gate says "being built" for ever (the fault's effect on the desktop) -- must FAIL (no wipe)
#   ARM=lastfirst  round 3's placement, run as soon as the last row is there -- must FAIL (script error in the log)
#   ARM=builtlast  that, with the "built" flag set after the placement -- must FAIL (script error)
#   ARM=viaquick   the "via" line opens on its own 260 ms while the wipe runs -- must FAIL (via line)
#   ARM=viastale   the via line's handler reads the `_vpn` binding instead of the facts -- must FAIL (via line)
#   ARM=quick      the wipe takes round 3's 750 ms -- must FAIL (a quick wipe)
#   ARM=nolead     the pointer is never told to the room in the chrome -- must FAIL (the room in the chrome)
#   ARM=notilt     the plate never hears of the card's tilt -- must FAIL (the plate does not hold)
#   ARM=all        every arm must fail by its own check: AERIAL_TUNNEL ARMS RESULT PASS|FAIL
#   ends in AERIAL_TUNNEL RESULT PASS|FAIL
{
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
OUT=${1:-/tmp/lares-aerial-tunnel}
SBX="${SANDBOX:-/tmp/lares-sbx-aerial-tunnel}"
if [ "${ARM:-}" = all ]; then
    rc=0
    for a in snap lastfirst builtlast viaquick viastale quick nolead notilt; do
        out=$(ARM="$a" SANDBOX="$SBX-$a" bash "$0" "$OUT/arm-$a" 2>&1)
        rm -rf "$SBX-$a" "$SBX-$a.lrrt"
        need="script error"; [ "$a" = snap ] && need="no wipe"; [ "${a#via}" != "$a" ] && need="via line"
        [ "$a" = quick ] && need="a quick wipe"; [ "$a" = nolead ] && need="the room in the chrome"; [ "$a" = notilt ] && need="the plate does not hold"
        last=$(printf '%s\n' "$out" | tail -1 | cut -c1-130)
        if rl_isnoresult "$out" || printf '%s\n' "$out" | grep -aq "anchor gone"; then
            echo "ARM $a: NOT PROVEN ($last)"; rc=1
        elif printf '%s\n' "$out" | grep -aq "^AERIAL_TUNNEL RESULT FAIL.*$need"; then
            echo "ARM $a: failed as it must ($last)"
        else
            echo "ARM $a: DID NOT FAIL BY ITS CHECK ($last)"; rc=1
        fi
    done
    [ $rc = 0 ] && { echo "AERIAL_TUNNEL ARMS RESULT PASS"; exit 0; }
    echo "AERIAL_TUNNEL ARMS RESULT FAIL"; exit 1
fi
if [ -e .git ] && [ -z "${ATP_INNER:-}" ]; then
    mkdir -p "$OUT"
    exec env SANDBOX="$SBX" MOCKUP_REPO= tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen ATP_INNER=1 ARM="${ARM:-}" FAMILY="${FAMILY:-}" FILM="${FILM:-}" THEME="${THEME:-}" MODE="${MODE:-}" \
        THEMES_FROM="${THEMES_FROM:-}" BUILD="${BUILD:-}" FORCE_MS="${FORCE_MS:-}" WAYLAND="${WAYLAND:-}" LOCK_ENV="${LOCK_ENV:-}" bash tools/dev/aerial_tunnel_probe.sh "$@"
fi
mkdir -p "$OUT/cfg/theme" "$OUT/cache" "$OUT/state" "$OUT/film" "$OUT/shots"; rm -f "$OUT"/shots/*.png
printf '{"theme":"%s","mode":"%s"}\n' "${THEME:-eva}" "${MODE:-light}" > "$OUT/cfg/theme/state.json"
# THEMES_FROM=<dir>: a theme folder to judge with instead of the repo's (the user's installed copies, which shadow the repo's and may lack a token a round added)
[ -n "${THEMES_FROM:-}" ] && { rm -rf "$OUT/cfg/theme/themes"; cp -r "$THEMES_FROM" "$OUT/cfg/theme/themes"; }
LOG="$OUT/tunnel.log"
if [ -n "${ARM:-}" ]; then
    python3 tools/dev/aerial_tunnel_arm.py "$ARM" || { echo "AERIAL_TUNNEL RESULT FAIL (ARM ${ARM}: anchor gone)"; exit 1; }
fi
film=""; [ -n "${FILM:-}" ] && film="$OUT/film"
if [ -n "${WAYLAND:-}" ]; then
    export LOCK_ENV="${LOCK_ENV:-aertun}"
    E="$PWD/tools/dev/lock_env.sh"
    "$E" down > /dev/null 2>&1
    OUTPUTS=1 "$E" up > "$OUT/up.log" 2>&1 || { tail -3 "$OUT/up.log"; echo "AERIAL_TUNNEL RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
    trap '"$E" down > /dev/null 2>&1' EXIT
    "$E" run env XDG_CONFIG_HOME="$OUT/cfg" XDG_CACHE_HOME="$OUT/cache" XDG_STATE_HOME="$OUT/state" QS_DISABLE_CRASH_HANDLER=1 \
        AT_RUN=1 SHOTS="$OUT/shots" BUILD="${BUILD:-}" FORCE_MS="${FORCE_MS:-}" FAMILY="${FAMILY:-0}" FILM="$film" quickshell -n -p "$PWD/tools/dev/qml/aerial_tunnel_probe.qml" > "$LOG" 2>&1 &
else
    env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$OUT/cfg" XDG_CACHE_HOME="$OUT/cache" XDG_STATE_HOME="$OUT/state" \
        AT_RUN=1 SHOTS="$OUT/shots" BUILD="${BUILD:-}" FORCE_MS="${FORCE_MS:-}" FAMILY="${FAMILY:-0}" FILM="$film" quickshell -n -p tools/dev/qml/aerial_tunnel_probe.qml > "$LOG" 2>&1 &
fi
pid=$!
for _ in $(seq 1 240); do kill -0 $pid 2>/dev/null || break; sleep 0.25; done
kill -0 $pid 2>/dev/null && { kill $pid; sleep 0.5; kill -9 $pid 2>/dev/null; }
wait $pid 2>/dev/null
rl_clean "$LOG" | grep -a 'TUNNEL ' | grep -v RESULT | sed 's/^.*TUNNEL /  TUNNEL /'
warn=$(rl_clean "$LOG" | rl_platform_noise | grep -a -c -E 'TypeError|ReferenceError|Unable to assign|[Bb]inding loop|non-existent property')
if [ "$warn" != 0 ]; then
    rl_clean "$LOG" | grep -a -E 'TypeError|ReferenceError|Unable to assign|[Bb]inding loop|non-existent property' | head -3 | sed 's/^ */  log: /'
    rl_result AERIAL_TUNNEL "$LOG" > /dev/null
    echo "AERIAL_TUNNEL RESULT FAIL (script error in the log, $warn line(s): the label's first placement threw)"; exit 1
fi
# THE ROOM IN THE CHROME, by pixels (round 5): the pointer rested at two far places with everything else held still. On chrome the label's middle must have changed (the
# room is led by the pointer); on paper not a pixel may (paper is still, and nothing of the room's runs under it). A family whose plate is drafted (Blueprint) has no room.
if rl_clean "$LOG" | grep -aq "AERIAL_TUNNEL RESULT PASS" && [ "${FAMILY:-0}" = 0 ]; then
    rect=$(rl_clean "$LOG" | grep -a 'TUNNEL shots ' | tail -1 | sed 's/^.*TUNNEL shots //')
    verdict=$(python3 -B -W ignore - "$OUT/shots" $rect <<'PY' 2>&1
import sys
from PIL import Image, ImageChops
d, x, y, w, h = sys.argv[1], *[int(float(v)) for v in sys.argv[2:6]]
def moved(tag):
    a = Image.open("%s/%s_a.png" % (d, tag)).convert("RGB").crop((x, y, x + w, y + h))
    b = Image.open("%s/%s_b.png" % (d, tag)).convert("RGB").crop((x, y, x + w, y + h))
    px = list(ImageChops.difference(a, b).getdata())
    return sum(1 for p in px if max(p) > 6) / float(len(px)), a
c, ca = moved("chrome")
p, pa = moved("paper")
ink = len(set(ca.getdata())) > 8
print("chrome moved %.1f %% of the label's middle, paper %.2f %%" % (100 * c, 100 * p))
bad = []
if not ink:
    bad.append("the grab holds no picture")
if c < 0.08:
    bad.append("the room in the chrome does not follow the pointer (%.1f %% of the label's middle changed)" % (100 * c))
if p > 0:
    bad.append("the paper moved under the pointer (%.2f %%)" % (100 * p))
print("BAD " + " | ".join(bad) if bad else "OK")
PY
)
    echo "$verdict" | head -1 | sed 's/^/  TUNNEL lead: /'
    if ! echo "$verdict" | grep -q '^OK$'; then
        echo "AERIAL_TUNNEL RESULT FAIL ($(echo "$verdict" | grep '^BAD ' | sed 's/^BAD //' | head -1)$(echo "$verdict" | grep -q '^BAD ' || echo "the shots could not be judged: $(echo "$verdict" | tail -1 | cut -c1-120)"))"; exit 1
    fi
fi
rl_result AERIAL_TUNNEL "$LOG"
exit $?
}
