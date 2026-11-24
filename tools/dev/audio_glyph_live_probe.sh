#!/usr/bin/env bash
# audio_glyph_live_probe.sh -- the bar's speaker / microphone pill shows its ON hue when its node is unmuted, on the REAL PipeWire graph.
#
#   tools/dev/audio_glyph_live_probe.sh            AUDIO_GLYPH_LIVE RESULT PASS | FAIL
#   THEME=eva MODE=light ...                       the theme the glyphs are drawn in (default: eva light, the user's)
#
# READ ONLY: SANDBOX_LINK=pipewire links the session's PipeWire socket for a reader that binds nodes and writes nothing
# (tools/dev/qml/audio_glyph_live_probe.qml: two VolumeParity pills, A on the session's default sink / source, B on the first
# UNMUTED device-backed sink and source). Each half's glyph PIXELS are read (the pixel furthest from the pill's ground) and held to
# what the node says: unmuted = BarHues' ON hue, muted = the muted ink. A graph with no unmuted device sink / source skips pill B
# and says so. Runs in a sandbox copy (tools/dev/sandbox.sh); an arm patches that copy only.
#
#   ARM=stuckoff   the half never takes its ON hue (the cause the user's report names): the unmuted halves must FAIL
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/alg.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
THEME="${THEME:-eva}"; MODE="${MODE:-light}"
mkdir -p "$D/cfg/theme" "$D/state" "$D/out"
printf '{"theme":"%s","mode":"%s"}\n' "$THEME" "$MODE" > "$D/cfg/theme/state.json"
ARMCMD=""
case "${ARM:-}" in
    "") ;;
    stuckoff) ARMCMD="grep -q 'property real _onOut: root.outputMuted ? 0 : 1' modules/bar/audio/AudioBarButton.qml || { echo 'ALG ARM anchor gone'; exit 3; }; sed -i 's|property real _onOut: root.outputMuted ? 0 : 1|property real _onOut: 0|; s|property real _onIn: root.inputMuted ? 0 : 1|property real _onIn: 0|' modules/bar/audio/AudioBarButton.qml" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY SANDBOX_LINK=pipewire QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QSG_DISTANCEFIELD_ANTIALIASING=gray XDG_CONFIG_HOME='"$D/cfg"' XDG_STATE_HOME='"$D/state"' OUT_DIR='"$D/out"' timeout -k 5 60 quickshell -p tools/dev/qml/audio_glyph_live_probe.qml'
tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'ALG .*' | grep -a -v 'ALG half' | cut -c1-240
python3 - "$D" "$THEME $MODE" > "$D/judge" <<'PY'
import re, sys
from PIL import Image
d, label = sys.argv[1], sys.argv[2]
log = open(d + "/log", errors="replace").read()
rows = re.findall(r"ALG half (\w) (\w+) (\d+) (\d+) (\d+) (\d+) (\d) (#\w+) (#\w+)", log)
def rgb(h): h = h.lstrip("#")[-6:]; return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))
if not rows or not __import__("os").path.exists(d + "/out/pills.png"):
    print("ALG FAIL no grab"); sys.exit()
im = Image.open(d + "/out/pills.png").convert("RGB")
bad = 0
for pill, half, x0, x1, y0, y1, muted, on, ink in rows:
    x0, x1, y0, y1 = int(x0), int(x1), int(y0), int(y1)
    want = rgb(ink) if muted == "1" else rgb(on)
    # the glyph ink: the pixel of the half nearest to the wanted colour among those far from the ground (pill ground = the corner's)
    ground = im.getpixel((x0 + 1, y0 + (y1 - y0) // 2))
    best, bd = None, 1e9
    for y in range(y0 + 4, y1 - 4):
        for x in range(x0 + 4, x1 - 4):
            p = im.getpixel((x, y))
            if sum(abs(p[i] - ground[i]) for i in range(3)) < 120: continue
            dd = sum(abs(p[i] - want[i]) for i in range(3))
            if dd < bd: bd, best = dd, p
    ok = best is not None and bd <= 30
    print(f"ALG {'ok' if ok else 'FAIL'} pill {pill} {half}: node says {'muted' if muted == '1' else 'on'}, wants {want}, nearest ink {best} (distance {bd if best else 'none'})")
    bad += not ok
print("ALG RESULT", "PASS" if not bad else "FAIL", f"({label})")
PY
cat "$D/judge"
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -q 'ALG ARM anchor gone'; then echo "ARM $ARM: the anchor is gone -- re-aim the arm"; exit 1; fi
    if grep -a -q 'ALG FAIL pill B speaker' "$D/judge"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    echo "ARM $ARM: DID NOT FAIL -- the probe cannot see it"; exit 1
fi
res=$(grep -a 'ALG RESULT' "$D/judge")
case "$res" in *PASS*) echo "AUDIO_GLYPH_LIVE RESULT PASS"; exit 0 ;; *) KEEP=1; echo "AUDIO_GLYPH_LIVE RESULT FAIL (no result or red: $D)"; exit 1 ;; esac
