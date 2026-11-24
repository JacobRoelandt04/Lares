#!/usr/bin/env bash
# shell_options_probe.sh -- the hand-edited config files reach the shell (tools/dev/qml/shell_options_probe.qml): the real ShellFrame on mock
# services, with the files below in the mock's config/.
#
#   tools/dev/shell_options_probe.sh            SHELL_OPTIONS RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=items ...    the reel's items are the built in ones          -> "power.jsonc items"
#   ARM=noaway ...   no popup catches a press outside                -> "takes the whole track"
#   ARM=awayall ...  every popup does                                -> "it does not name catches nothing"
#   ARM=waits ...    the download wait is the built in 2 minutes     -> "idle.jsonc download"
#   ARM=shown ...    the workspaces' dots are the built in four      -> "workspaces.jsonc shown"
#   ARM=sounds ...   a timer sound that is not there is played anyway -> "clock.jsonc timers.sounds"
#   ARM=remember ... the player comes back as it was left           -> "player.jsonc open.remember"
#   ARM=pillhalf ... the accent goes to the first half on its tab   -> "audio.jsonc pill"
#   ARM=hide ...     the audio lists hide nothing                   -> "audio.jsonc hide"
#   ARM=weatherview  a parked weather popup keeps the view it was left on -> "weather.jsonc view.remember"
#   ARM=all          every one of them: SHELL_OPTIONS ARMS RESULT PASS | FAIL
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
ARMS="items noaway awayall shown waits sounds remember pillhalf hide weatherview"
if [ "${ARM:-}" = all ]; then
    bad=""
    for a in $ARMS; do
        out=$(ARM=$a "$0" 2>&1); rc=$?
        echo "$out" | tail -1
        [ "$rc" -eq 0 ] || bad="$bad $a"
    done
    [ -z "$bad" ] && { echo "SHELL_OPTIONS ARMS RESULT PASS"; exit 0; }
    echo "SHELL_OPTIONS ARMS RESULT FAIL ($bad)"; exit 1
fi
D="$(mktemp -d "${SCRATCH:-/tmp}/sopt.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
C="$D/state/lares-shell-mock/config"
mkdir -p "$D/config/theme" "$C"
cp "${XDG_CONFIG_HOME:-$HOME/.config}/theme/state.json" "$D/config/theme/state.json" 2> /dev/null || printf '{"theme":"eva","mode":"light"}\n' > "$D/config/theme/state.json"
cat > "$C/shell.jsonc" <<'J'
{
    "shadow": { "mode": "halo", "aura": true, "auraEvents": { "llm": 20, "update": false } },
    "clicks": { "theme": { "right": "next" }, "clock": { "middle": ["true"] } },
    "outlets": { "notes": { "bar": "top", "along": 0 }, "llm": { "bar": "right", "along": 1 } },
    "clickAway": ["weather", "theme"],
    "flourishes": { "hover": false, "key": false },
    "recorders": ["gpu-screen-recorder"]
}
J
printf '{ "items": ["reboot", "sleep"], "rest": "sleep", "commands": { "sleep": ["systemctl", "hibernate"] }, "waitForFlourish": false, "leftClickFires": true }\n' > "$C/power.jsonc"
printf '{ "shown": [1, 2, 5] }\n' > "$C/workspaces.jsonc"
printf '{ "start": "normal", "autoTell": "quiet", "download": { "minMinutes": 5, "folder": "~/Inbox" }, "packages": { "minMinutes": 0 } }\n' > "$C/idle.jsonc"
printf '{ "open": "timers", "seconds": "always", "timers": { "snoozeMin": 4, "sounds": { "countdown": "not-there.oga", "pomodoro": "none" }, "ringSec": 5, "soundUnderDnd": false, "countdownMin": 2 }, "look": { "secondarySide": "far" } }\n' > "$C/clock.jsonc"
printf '{ "open": { "view": "mini", "remember": false }, "prevRestartSec": 0, "musicSparks": false, "shuffle": { "artistGap": 1 } }\n' > "$C/player.jsonc"
printf '{ "pill": { "speakerOpens": "playback", "micOpens": "playback" }, "hide": ["alsa_output.pci-*HDMI*", "alsa_output.usb-*", "alsa_output.pci-*Speaker*"] }\n' > "$C/audio.jsonc"
printf '{ "check": { "everyMin": 0, "aur": false }, "view": "normal", "list": { "groupMin": 0, "open": ["all"] }, "run": { "flags": ["--devel"] } }\n' > "$C/system_update.jsonc"
cat > "$D/arm.py" <<'ARMPY'
import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
if s.count(a) != 1:
    print("ARM anchor gone (%d): %r" % (s.count(a), a[:80])); sys.exit(1)
open(p, "w").write(s.replace(a, b))
ARMPY
ARMCMD="" NEEDLE=""
F=modules/shell/ShellFrame.qml E=modules/bar/gooey/GooeyEngine.qml
arm() { ARMCMD="python3 $D/arm.py $1 $(printf '%q' "$2") $(printf '%q' "$3")"; NEEDLE=$4; }
case "${ARM:-}" in
    "") ;;
    items) arm $F 'items: ReelItems.powerItems(powerReel.ids)' 'items: ReelItems.POWER' 'power.jsonc items' ;;
    noaway) arm $E 'S.live && engine.clickAwayIds.indexOf(S.ownerId) >= 0' 'false' 'takes the whole track' ;;
    awayall) arm $E 'S.live && engine.clickAwayIds.indexOf(S.ownerId) >= 0' 'S.live' 'it does not name catches nothing' ;;
    shown) arm $F 'workspaceIds: frame._workspacesShown' 'workspaceIds: [1, 2, 3, 4]' 'workspaces.jsonc shown' ;;
    waits) arm modules/shell/ShellServices.qml 'minAgeMs: Math.round(idleService.checked.download.minMinutes * 60000)' 'minAgeMs: 120000' 'idle.jsonc download' ;;
    sounds) arm modules/clock/data/TimerService.qml 'plays[k] = seen[i] === "1" ? soundCheck.asked[k] : svc.defaultSounds[k];' 'plays[k] = soundCheck.asked[k];' 'clock.jsonc timers.sounds' ;;
    remember) arm modules/bar/player/PlayerBarOwner.qml 'if (!owner.openRemember) {' 'if (false) {' 'player.jsonc open.remember' ;;
    pillhalf) arm modules/audio/AudioBarOwner.qml ': owner.section === owner.halfOpens[owner._half] ? owner._half' ': owner.section === owner.halfOpens[0] ? 0' 'audio.jsonc pill' ;;
    hide) arm modules/audio/data/AudioModel.js 'const hide = o.hide || [];' 'const hide = [];' 'audio.jsonc hide' ;;
    weatherview) arm modules/weather/WeatherPopup.qml 'if (root.resetView !== "")' 'if (false)' 'weather.jsonc view.remember' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi SHELL_SERVICES=mock XDG_CONFIG_HOME='"$D"'/config XDG_STATE_HOME='"$D"'/state XDG_CACHE_HOME='"$D"'/cache timeout 150 quickshell -p tools/dev/qml/shell_options_probe.qml'
tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'SOPT FAIL.*'
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a 'SOPT FAIL' | grep -a -q -e "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if ! rl_has "$D/log" 'SOPT RESULT'; then KEEP_D=1; echo "ARM $ARM: the armed copy did not load -- it proves nothing ($D/log)"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL -- the probe cannot see it"; exit 1
fi
res=$(rl_result SHELL_OPTIONS "$D/log" 'SOPT RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP_D=1; printf '%s\n' "$res"; exit 1; fi
[ "$rc" -eq 0 ] || KEEP_D=1
printf '%s\n' "$res" | sed 's/^SOPT RESULT/SHELL_OPTIONS RESULT/'
exit $rc
