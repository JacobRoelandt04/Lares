#!/usr/bin/env bash
# audio_glyph_toggle_probe.sh -- the bar's volume pill follows a mute toggle on a PRIVATE PipeWire (a null sink and source in a daemon
# of its own, never the session's): each right click flips the node's `muted` and the half's glyph between the ON hue and the muted ink.
#
#   tools/dev/audio_glyph_toggle_probe.sh          AUDIO_GLYPH_TOGGLE RESULT PASS | FAIL
#   THEME=eva MODE=light ...                       the theme (default eva light, the user's)
#   ARM=stuckmuted  the pill reads every half as muted whatever the node says (the symptom: grey for ever): must FAIL
#
# Null nodes are not device-backed (no Route): what a device-backed node does with a write is the user's session alone
# (tools/dev/audio_glyph_live_probe.sh reads it, read only). Runs in a sandbox copy; an arm patches that copy only.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/atg.XXXXXX")"
PW=$(mktemp -d /tmp/atgpw.XXXXXX); chmod 700 "$PW"
PWPID=""
cleanup() { [ -z "$PWPID" ] || kill "$PWPID" 2> /dev/null; rm -rf "$PW"; [ -n "${KEEP:-}" ] || rm -rf "$D"; }
trap cleanup EXIT
THEME="${THEME:-eva}"; MODE="${MODE:-light}"
mkdir -p "$D/cfg/theme" "$D/state" "$D/out"
printf '{"theme":"%s","mode":"%s"}\n' "$THEME" "$MODE" > "$D/cfg/theme/state.json"
ARMCMD=""
case "${ARM:-}" in
    "") ;;
    stuckmuted) ARMCMD="grep -q 'root._sink.audio.muted === true' modules/shell/VolumeParity.qml || { echo 'ATG ARM anchor gone'; exit 3; }; sed -i 's|root._sink.audio.muted === true|true|; s|root._source.audio.muted === true|true|' modules/shell/VolumeParity.qml" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
# the private daemon: no session manager. Its config (a drop-in of a private XDG_CONFIG_HOME) makes the `default` metadata, a null
# sink and a null source; the defaults are named in that metadata
mkdir -p "$D/pwcfg/pipewire/pipewire.conf.d"
cat > "$D/pwcfg/pipewire/pipewire.conf.d/10-alg.conf" <<'CONF'
context.objects = [
    { factory = metadata
        args = { metadata.name = default }
    }
    { factory = adapter
        args = { factory.name = support.null-audio-sink node.name = alg_sink media.class = Audio/Sink object.linger = true audio.position = [ FL FR ] }
    }
    { factory = adapter
        args = { factory.name = support.null-audio-sink node.name = alg_source media.class = Audio/Source object.linger = true audio.position = [ FL FR ] }
    }
]
CONF
XDG_RUNTIME_DIR="$PW" PIPEWIRE_RUNTIME_DIR="$PW" XDG_CONFIG_HOME="$D/pwcfg" setpriv --pdeathsig TERM -- pipewire > "$D/pipewire.log" 2>&1 &
PWPID=$!
for _ in $(seq 40); do [ -S "$PW/pipewire-0" ] && break; sleep 0.1; done
export PIPEWIRE_REMOTE="$PW/pipewire-0"
sleep 0.5
pw-metadata -n default 0 default.audio.sink '{"name":"alg_sink"}' Spa:String:JSON > "$D/pwcli.log" 2>&1
pw-metadata -n default 0 default.audio.source '{"name":"alg_source"}' Spa:String:JSON >> "$D/pwcli.log" 2>&1
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY PIPEWIRE_REMOTE='"$PIPEWIRE_REMOTE"' QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QSG_DISTANCEFIELD_ANTIALIASING=gray XDG_CONFIG_HOME='"$D/cfg"' XDG_STATE_HOME='"$D/state"' OUT_DIR='"$D/out"' timeout -k 5 60 quickshell -p tools/dev/qml/audio_glyph_toggle_probe.qml'
tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'ATG .*' | cut -c1-330
# A copy that never loaded prints no step: the no-result verdict (result_lib), and an arm pass on it proves nothing.
if ! rl_clean "$D/log" | grep -a -q 'ATG step'; then
    KEEP=1
    if [ -n "${ARM:-}" ]; then echo "ARM $ARM: the armed copy did not load -- it proves nothing ($D/log)"; exit 1; fi
    rl_noresult AUDIO_GLYPH_TOGGLE "$D/log"; exit 1
fi
python3 - "$D" "$THEME $MODE" > "$D/judge" <<'PY'
import re, sys, os
from PIL import Image
d, label = sys.argv[1], sys.argv[2]
log = open(d + "/log", errors="replace").read()
steps = re.findall(r"ATG step (\d) (.+?) \| sink \S+ muted (\S+) \| source \S+ muted (\S+) \| pill sinkMuted (\w+) sourceMuted (\w+) \| geom (\d+) (\d+) (\d+) (\d+) \| hues (#\w+) (#\w+) (#\w+)", log)
def rgb(h): h = h.lstrip("#")[-6:]; return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))
want_flip = {0: (False, False), 1: (True, False), 2: (True, True), 3: (False, True), 4: (False, False)}
bad = 0
if len(steps) != 5: print("ALG FAIL steps seen:", len(steps)); bad += 1
for n, what, sm, srm, psm, psrm, gx, gy, gw, gh, hs, hm, ink in steps:
    n = int(n)
    exp = want_flip[n]
    nodes_ok = (sm == "true", srm == "true") == exp
    pill_ok = (psm == "true", psrm == "true") == exp
    p = d + f"/out/step{n}.png"
    pix_ok = os.path.exists(p)
    msg = ""
    if pix_ok:
        im = Image.open(p).convert("RGB")
        gx, gy, gw, gh = int(gx), int(gy), int(gw), int(gh)
        for half, (x0, x1), m, on in (("speaker", (gx, gx + gw // 2), exp[0], hs), ("mic", (gx + gw // 2, gx + gw), exp[1], hm)):
            want = rgb(ink) if m else rgb(on)
            ground = im.getpixel((x0 + 1, gy + gh // 2))
            bd = 1e9
            for y in range(gy + 4, gy + gh - 4):
                for x in range(x0 + 4, x1 - 4):
                    px = im.getpixel((x, y))
                    if sum(abs(px[i] - ground[i]) for i in range(3)) < 120: continue
                    bd = min(bd, sum(abs(px[i] - want[i]) for i in range(3)))
            if bd > 30: pix_ok = False; msg += f" {half} ink is {bd} from {want}"
    ok = nodes_ok and pill_ok and pix_ok
    print(f"ALG {'ok' if ok else 'FAIL'} step {n} {what}: node muted (sink,source) {(sm, srm)} expected {exp}; pill {'agrees' if pill_ok else 'DISAGREES'}; pixels {'agree' if pix_ok else 'DISAGREE' + msg}")
    bad += not ok
print("ALG RESULT", "PASS" if not bad else "FAIL", f"({label})")
PY
cat "$D/judge"
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -q 'ATG ARM anchor gone'; then echo "ARM $ARM: the anchor is gone -- re-aim the arm"; exit 1; fi
    if grep -a -q 'ALG FAIL step [0-9]' "$D/judge"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    echo "ARM $ARM: DID NOT FAIL (or never loaded) -- the probe cannot see it"; exit 1
fi
case "$(grep -a 'ALG RESULT' "$D/judge")" in *PASS*) echo "AUDIO_GLYPH_TOGGLE RESULT PASS"; exit 0 ;; *) KEEP=1; echo "AUDIO_GLYPH_TOGGLE RESULT FAIL (no result or red: $D)"; exit 1 ;; esac
