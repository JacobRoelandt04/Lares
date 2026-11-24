#!/usr/bin/env bash
# osd_ddc_probe.sh -- the OSD's brightness keys (modules/osd/data/OsdService.qml, sources/DdcBrightnessSource.qml, OsdPointer.js).
# The keys act on the display UNDER THE POINTER (one `hyprctl -j cursorpos` per gesture, 150 ms at most, the focused screen when it
# does not answer), an external with DDC steps over DDC and the card shows its GOAL at once as `pending`, one without DDC or with a
# remembered failure gets a card that says so and the laptop is never stepped for it, no repeat is dropped, a gesture keeps its display.
# Part 1 (ODP): the service against a stub display backend and stub hyprctl programs. Part 2 (ODL): the whole path -- the service, a real
# DdcClient behind the backend contract, stub ddcutil / hyprctl / brightnessctl -- see tools/dev/qml/osd_ddc_live.qml.
#
#   tools/dev/osd_ddc_probe.sh                  OSDDDC RESULT PASS | FAIL
#   ARM=focusrule     the pointer is ignored, the focused screen decides          -> "pointer on the external, laptop focused" red
#   ARM=dropsrepeats  a repeat of a held key is dropped                            -> "none dropped" red
#   ARM=panelfallback a display without DDC steps the laptop's backlight           -> "no DDC for DP-3" red
#   ARM=nopending    the card never says pending                                  -> "pending: true" red
#   ARM=newgesture   every press asks the pointer again                           -> "a hold" red
#   ARM=notarget     osd.jsonc brightness.target is not read                       -> "target focused" red
#   ARM=mpdfirst     the first player listed has the media keys, playing or not     -> "media auto: the player that PLAYS" red
#   ARM=stealkeys    mpd paused in a song loses its keys                           -> "media auto: mpd paused" red
#   ARM=noevents     osd.jsonc kinds.<kind>.events is not read                     -> "events:" red
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/odp.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
PYARM=""; NEEDLE=""; F=modules/osd/data/OsdService.qml
case "${ARM:-}" in
    "") ;;
    focusrule)     PYARM='("const name = pt !== null ? Pointer.monitorAt(root.monitorRects, pt.x, pt.y) : \"\";", "const name = \"\";")'; NEEDLE='ODP FAIL pointer on the external' ;;
    dropsrepeats)  PYARM='("        g.at = Date.now();\n        if (!g.resolved) {", "        g.at = Date.now();\n        if (phase === \"repeat\")\n            return true;\n        if (!g.resolved) {")'; NEEDLE='ODP FAIL (3b|a hold)' ;;
    panelfallback) PYARM='("        return g.target ? ddcBrightness.adjust(g.target, dir, fine, phase) : backlight.adjust(dir, fine, phase);", "        return g.target && displayBackend.ddcState(g.target.connector) !== \"unsupported\" ? ddcBrightness.adjust(g.target, dir, fine, phase) : backlight.adjust(dir, fine, phase);")'; NEEDLE='ODP FAIL no DDC for DP-3' ;;
    nopending)     F=modules/osd/data/sources/DdcBrightnessSource.qml; PYARM='("const pending = !unavailable && b.ddcPending(n);", "const pending = false;")'; NEEDLE='ODP FAIL the card names the display' ;;
    newgesture)    PYARM='("if (g !== null && now - g.at < root.gestureKeepMs) {", "if (false) {")'; NEEDLE='ODP FAIL (3b|a hold)' ;;
    notarget)      PYARM='("const want = root._c.brightness.target;", "const want = \"pointer\";")'; NEEDLE='ODP FAIL target focused' ;;
    mpdfirst)      F=modules/osd/data/sources/MpdSource.qml; PYARM='("$1 == \"Playing\" { print $2; f = 1; exit } $1 == \"Paused\" && !q", "!q")'; NEEDLE='ODP FAIL media auto: the player that PLAYS' ;;
    stealkeys)     F=modules/osd/data/sources/MpdSource.qml; PYARM='("m.playState !== \"stop\" && !!m.current", "m.playState === \"play\"")'; NEEDLE='ODP FAIL media auto: mpd paused' ;;
    noevents)      PYARM='("const ev = kc.events ? Kinds.eventOf(r) : \"\";", "const ev = \"\";")'; NEEDLE='ODP FAIL events:' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
mkdir -p "$D/bin"
mkpt() { printf '#!/usr/bin/env bash\n%secho '"'"'{"x": %s, "y": %s}'"'"'\n' "${4:-}" "$2" "$3" > "$D/bin/$1"; chmod +x "$D/bin/$1"; }
mkpt hyprctl_a 100 100; mkpt hyprctl_b 3000 500; mkpt hyprctl_c 6500 100; mkpt hyprctl_d 8400 100; mkpt hyprctl_e 5000 100
mkpt hyprctl_slow_b 3000 500 'sleep 1; '
printf '#!/usr/bin/env bash\nexit 1\n' > "$D/bin/hyprctl_fail"; chmod +x "$D/bin/hyprctl_fail"
# playerctl: browser.2 plays, spotify is paused; `<player> <verb>` is remembered as what that player shows afterwards
cat > "$D/bin/playerctl_two" <<'STUB'
#!/usr/bin/env bash
d=$(dirname "$0"); us=$(printf '\037')
case "$*" in
    *" status") printf 'Paused spotify\nPlaying browser.2\n' ;;
    *metadata*) if [ "$(cat "$d/verb")" = "browser.2 play-pause" ]; then printf 'Paused%sA film%sSomebody%s%shttps://x/y.png\n' "$us" "$us" "$us" "$us"
                else printf 'Playing%s%s%s%s%s\n' "$us" "$(cat "$d/verb")" "$us" "$us" "$us"; fi ;;
    "-p "*) printf '%s %s' "$2" "$3" > "$d/verb" ;;
esac
STUB
printf '#!/usr/bin/env bash\necho "No players found" >&2\nexit 1\n' > "$D/bin/playerctl_none"; chmod +x "$D/bin"/playerctl_*
export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-osd-ddc}"
cat > "$D/run.sh" <<RUN_EOF
if [ -n "${ARM:-}" ]; then
python3 - <<'PY' || exit 3
import sys
a, b = $PYARM
s = open("$F").read()
if a not in s:
    print("ARMLOST"); sys.exit(1)
open("$F", "w").write(s.replace(a, b, 1))
PY
fi
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi ODP_BIN="$D/bin" timeout 90 quickshell -p tools/dev/qml/osd_ddc_probe.qml
RUN_EOF
tools/dev/sandbox.sh bash "$D/run.sh" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'ODP .*' | grep -a -v 'ODP RESULT'
if [ -n "${ARM:-}" ]; then
    if rl_has "$D/log" 'ARMLOST'; then echo "ARM $ARM: its anchor matched nothing -- it proves nothing"; exit 1; fi
    if rl_clean "$D/log" | grep -a -E -q "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    rl_has "$D/log" 'ODP RESULT' || { echo "ARM $ARM: the armed copy did not load -- it proves nothing"; exit 1; }
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result OSDDDC "$D/log" 'ODP RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi
printf '%s\n' "$res" | sed 's/^ODP RESULT/OSDDDC RESULT/'
# part 2: the whole path with a real DdcClient and stub ddcutil / hyprctl / brightnessctl, one run per stub mode
F2="tools/dev/fixtures/panorama"
for m in ok slow ignore; do
    W="$D/live_$m"; mkdir -p "$W/bin" "$W/sysbl/stub0"
    printf '120\n' > "$W/sysbl/stub0/brightness"; printf '400\n' > "$W/sysbl/stub0/max_brightness"
    cp "$D/bin/hyprctl_a" "$D/bin/hyprctl_b" "$W/bin/"
    cat > "$W/bin/ddcutil" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "\$(date +%s%3N)" "\$*" >> "$W/ddcutil.log"
bus=""; prev=""
for a in "\$@"; do [ "\$prev" = --bus ] && bus="\$a"; prev="\$a"; done
case "\$1" in
    detect) cat "$PWD/$F2/ddcutil_detect_laptop.txt"; echo; cat "$PWD/$F2/ddcutil_detect_external_synthetic.txt" ;;
    getvcp) [ "$m" = slow ] && sleep 3
            printf 'VCP 10 C %s 100\n' "\$(cat "$W/val.\$bus" 2> /dev/null || echo 50)" ;;
    setvcp) if [ "$m" = slow ]; then sleep 3; else sleep 0.2; fi
            [ "$m" = ignore ] && exit 0
            printf '%s\n' "\$3" > "$W/val.\$bus" ;;
    *) echo "stub: refused \$*" >&2; exit 99 ;;
esac
STUB
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "$(date +%%s%%3N)" "$*" >> "%s/bctl.log"\n' "$W" > "$W/bin/brightnessctl"
    chmod +x "$W/bin/"*
    cat > "$D/run2.sh" <<RUN_EOF
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi PATH="$W/bin:\$PATH" ODL_W="$W" ODL_MODE=$m timeout 120 quickshell -p tools/dev/qml/osd_ddc_live.qml
RUN_EOF
    tools/dev/sandbox.sh bash "$D/run2.sh" > "$D/log2_$m" 2>&1
    rl_clean "$D/log2_$m" | grep -a -o 'ODL .*' | grep -a -v 'ODL RESULT'
    r2=$(rl_result "OSDDDC_LIVE_$m" "$D/log2_$m" 'ODL RESULT .*'); rc2=$?
    printf '%s\n' "$r2" | sed "s/^ODL RESULT/OSDDDC_LIVE($m) RESULT/"
    [ "$rc2" = 0 ] || rc=1
done
exit $rc
