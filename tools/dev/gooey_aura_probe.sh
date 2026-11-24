#!/usr/bin/env bash
# tools/dev/gooey_aura_probe.sh -- THE AURA of the real shell frame (GooeyEngine: THE AURA; gooey_field.frag: THE AURA), on the
# user's geometry: shell.jsonc's halo, aura and border on, the global scale 1.25, three top islands, catppuccin dark, a black
# wallpaper (theirs is an AMOLED black).
#
#   tools/dev/gooey_aura_probe.sh <out> [step ...]       steps as tools/dev/qml/gooey_aura_probe.qml reads them (default: the set below)
#   MODES=dark,light   the theme modes rendered (dark)
#   THEME=<name>       the theme (catppuccin; the user's today: tokyo-night dark, monokai light)
#   SCALE=<k>          the shell's global scale (1.25, the user's)
#   AU_JUDGE_ONLY=1    judge what <out> already holds (no sandbox, no render): a judge's numbers re-read without a run
#   ARM=<name>         a fault, in the sandbox copy (each must FAIL on its own needle):
#     clockjump        the release moves the envelope's clock without moving the picture's time with it (round 3's release:
#                      the hues jump at a take's end) -> `seam at the hand-over`
#     reseed           a play over a play draws a new seed (the hues jump at the take's renewal) -> `seam at the hand-over`
#     fromzero         a play over a play in its way out starts again from nothing (the old rule) -> `the level jumped`
#     cove             the inner bend's halo reads the island's side and the flare's ends as two shapes again (the old
#                      distance: a dark seam out of every cove) -> `crease out of the bend`
#     flipgrad         the cove's rest gradient read raw off the window's axes (round 4's: y the other way from the field's, so
#                      every end's weight in a pocket came out wrong) -> `crease at a junction` (a pocket past an island's end)
#     band             the loops' hand-over a fixed 20 px band again (round 4's) -> `hue seam at a junction`
#     nojoin           a loop that touches the frame keeps its own hue (no join: the mic card's seams) -> `hue phase apart across a junction`
#     groupcut         a group handed over switches at once (the rest of the frame pops in at full level) -> `seam at the hand-over`
#
# THE JUDGES.
#   seam   (seq:<tag>:<how>) every frame is a grab of a held clock written a frame at a time: the change from one frame to the
#          next (the mean over the halo's band of the largest channel's step, in levels) at the hand-over must be no larger than
#          LIMIT x the larger of the steps just before and just after it (plus a level for the rasteriser). The record of the
#          field's inputs says why: the picture's time steps by one frame, the level by no more than twice its step elsewhere,
#          the waves, the joins and the group hold, and so does the palette, but for a palette or a group handed over, which eases
#          (its first step no larger than the ease's own).
#   bend   (pose:<tag>:...:mono, off:<tag>) the halo's ink round each island's inner bends (the island's side flaring into the
#          screen's top edge): its sharpest KINK -- the largest jump of slope through a pixel, over four directions, each side fitted
#          over W px (the cove method) -- no more than KINK_RATIO x the bar joint corner's (the reference the user gave: "not present
#          in the bar joint corners").
#   joints (do:<tag>:<what> + off:<tag>_off, pose:<tag>_mono, pose:<tag>_full) round each popup of a scene (the mic card, a popup
#          from each island, the clock with its wiki card, the card beside a toast stack): the same kink at every junction a popup
#          makes (each fillet of a popup) and at each of its corners, against the joint's (a POCKET -- a junction a sky flare's end
#          is near, where a popup runs past an island's end and three walls face each other -- against POCKET_RATIO x it: a ridge
#          between facing walls is sqrt(2) sharper than a joint's at the same blend); and the HUE at every junction: the largest
#          chroma gradient (the colour's opponent axes over its brightness, per px) no more than HUE_RATIO x the halo's own 95th
#          percentile in the scene (the user, round 5: "the aura around it, especially in the corners, has some visible seams"), and the
#          hue's PHASE either side of each junction's wedge (the palette inverted at 15 and 75 degrees from a face, 30-50 px out) no more
#          than PHASE_LIMIT cycles apart: two loops that meet there with unrelated hues read a quarter to a half cycle.
# Every state runs offscreen in a tools/dev/sandbox.sh copy (SANDBOX, default /tmp/lares-sandbox-aura) on the shell's mock services, a
# private session bus and private XDG homes. Ends in GOOEY_AURA RESULT PASS|FAIL.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?usage: gooey_aura_probe.sh <out> [step ...]}"
shift
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
STEPS=("$@")
if [ ${#STEPS[@]} -eq 0 ]; then
    STEPS=("off:off" "pose:full:7.3:5000" "pose:mono:7.3:5000:mono"
           "seq:release:release" "seq:replay:replay" "seq:palette:palette" "seq:life:life" "seq:back:back" "seq:group:group")
    # the scenes: the mic card (the user's path), a popup from each island, the clock with its wiki card, the card beside a stack
    for sc in "osd:osd" "notes:open=notes" "player:open=player" "wiki:wiki" "stack:toast" "peer:osdat=topR,0.5"; do
        STEPS+=("do:${sc}")
        case "$sc" in stack:*) continue ;; esac
        t="${sc%%:*}"
        STEPS+=("off:${t}_off" "pose:${t}_mono:7.3:5000:mono" "pose:${t}_full:7.3:5000" "do:close_${t}:close")
    done
fi
JOINED=$(IFS=';'; echo "${STEPS[*]}")

if [ -z "${AU_INNER:-}" ] && [ -z "${AU_JUDGE_ONLY:-}" ]; then
    own=0
    [ -z "${SANDBOX:-}" ] && own=1
    export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-aura}"
    "$ROOT/tools/dev/sandbox.sh" -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE QT_QPA_PLATFORM=offscreen MOCKUP_REPO= AU_INNER=1 \
        tools/dev/gooey_aura_probe.sh "$OUT" "${STEPS[@]}"
    rc=$?
    [ "$own" = 1 ] && rm -rf "$SANDBOX"
    exit $rc
fi

# ---- inside the copy -------------------------------------------------------------------------------------------------
IFS=',' read -r -a MODELIST <<< "${MODES:-dark}"
if [ -z "${AU_JUDGE_ONLY:-}" ]; then
[ -e .git ] && { echo "GOOEY_AURA RESULT FAIL (the inner run stands in a work tree, not a sandbox copy)"; exit 1; }
arm_patch() {
    # $1 file, $2 the anchor (must occur once), $3 its replacement
    python3 - "$@" <<'PY' || { echo "GOOEY_AURA RESULT FAIL (ARM ${ARM}: its anchor is gone)"; exit 1; }
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    raise SystemExit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
print("ARM: " + p + " patched")
PY
}
case "${ARM:-}" in
"") ;;
clockjump)
    arm_patch modules/bar/gooey/GooeyEngine.qml "        engine._auraSkip += from - engine._auraClock;
" "" ;;
reseed)
    arm_patch modules/bar/gooey/GooeyEngine.qml "            engine._auraSkip = from - tNow;
" "            engine._auraSeed = Math.random() * 40;
" ;;
fromzero)
    arm_patch modules/bar/gooey/GooeyEngine.qml "        const from = over ? Aura.clockOfLevel(engine._auraLevel, engine.auraAttackMs) : 0;" \
        "        const from = over && engine._auraClock < engine.auraAttackMs + engine._auraLife ? Aura.clockOfLevel(engine._auraLevel, engine.auraAttackMs) : 0;" ;;
cove)
    arm_patch modules/bar/gooey/shaders/gooey_field.frag "            sh = auraInk(p, dA, sh, dAura);" "            sh = auraInk(p, d, sh, dAura);"
    tools/dev/bake_shaders.sh gooey_field > /dev/null || { echo "GOOEY_AURA RESULT FAIL (ARM cove: the bake failed)"; exit 1; } ;;
flipgrad)
    arm_patch modules/bar/gooey/shaders/gooey_field.frag "    vec2 g = vec2(dFdx(dBody) * sign(dFdx(vPos.x)), dFdy(dBody) * sign(dFdy(vPos.y)));" \
        "    vec2 g = vec2(dFdx(dBody), dFdy(dBody));"
    tools/dev/bake_shaders.sh gooey_field > /dev/null || { echo "GOOEY_AURA RESULT FAIL (ARM flipgrad: the bake failed)"; exit 1; } ;;
band)
    arm_patch modules/bar/gooey/shaders/gooey_field.frag "    return smoothstep(-0.5, 0.5, (b - a) / (a + b + AURA_HAND));" \
        "    return smoothstep(-10.0, 10.0, far - near);"
    tools/dev/bake_shaders.sh gooey_field > /dev/null || { echo "GOOEY_AURA RESULT FAIL (ARM band: the bake failed)"; exit 1; } ;;
nojoin)
    arm_patch modules/bar/gooey/GooeyAura.js "    if (!join)
        return [0, 1, 0, cycles];" "    return [0, 1, 0, cycles];" ;;
groupcut)
    arm_patch modules/bar/gooey/GooeyEngine.qml "                engine._auraGroupFrom = groupsShown;" "                engine._auraGroupFrom = null;" ;;
*) echo "GOOEY_AURA RESULT FAIL (unknown ARM ${ARM})"; exit 1 ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lares-au.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
gcc -shared -fPIC -O2 -o "$WORK/stillclock.so" tools/dev/sheet_stillclock.c -ldl || { echo "GOOEY_AURA RESULT FAIL (no still clock)"; exit 1; }
python3 -B -c "
from PIL import Image
Image.new('RGB', (2880, 1620), (0, 0, 0)).save('$WORK/wall.png')"
mkdir -p "$WORK/stubs"
for prog in nvidia-smi nvidia-modprobe systemd-run; do printf '#!/bin/sh\nexit 1\n' > "$WORK/stubs/$prog"; chmod +x "$WORK/stubs/$prog"; done
cp tools/dev/qml/gooey_aura_probe.qml mockups/zz_aura_probe.qml

for mode in "${MODELIST[@]}"; do
    d="$WORK/$mode"
    mkdir -p "$d/cfg/theme" "$d/state/lares-shell-mock/config" "$d/cache" "$d/data" "$d/rt" "$OUT/$mode"
    chmod 700 "$d/rt"
    printf '{"theme":"%s","mode":"%s"}\n' "${THEME:-catppuccin}" "$mode" > "$d/cfg/theme/state.json"
    printf '{ "shadow": { "mode": "halo", "aura": true }, "border": true }\n' > "$d/state/lares-shell-mock/config/shell.jsonc"
    rm -f "$OUT/$mode"/*.png
    env -i \
        HOME="$HOME" USER="${USER:-user}" PATH="$WORK/stubs:$PATH" DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" \
        LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TZ=Europe/Brussels \
        XDG_RUNTIME_DIR="$d/rt" XDG_CONFIG_HOME="$d/cfg" XDG_STATE_HOME="$d/state" XDG_CACHE_HOME="$d/cache" XDG_DATA_HOME="$d/data" \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_QPA_PLATFORMTHEME= QT_LOGGING_RULES=qt.qpa.services.warning=false \
        QML_DISABLE_DISTANCEFIELD=1 QT_HASH_SEED=0 QS_ICON_THEME=Papirus QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 \
        LARES_SLEEP_MONITOR=off MOCKUP_REPO= SHELL_SERVICES=mock WALL="file://$WORK/wall.png" ZOOM=1 \
        SCALE="${SCALE:-1.25}" AU_OUT="$OUT/$mode" AU_STEPS="$JOINED" \
        tools/dev/notifications_bus.sh timeout -k 5 600 env LD_PRELOAD="$WORK/stillclock.so" SHEET_NOW=1793199600 \
        quickshell -p mockups/zz_aura_probe.qml > "$OUT/$mode/log.txt" 2>&1
    echo "rendered $mode: $(grep -c 'AUPOSE \|AUFRAME ' "$OUT/$mode/log.txt") grabs, $(grep -c 'AUPROBE DONE' "$OUT/$mode/log.txt") done"
done
fi
python3 -B - "$OUT" "${MODELIST[@]}" <<'PY'
import math, os, re, sys
import numpy as np
from PIL import Image
from scipy import ndimage
out, modes = sys.argv[1], sys.argv[2:]
LIMIT, LEVEL = 2.0, 1.0          # seam: the hand-over's step against the largest before it
KINK_RATIO, KINK_FLOOR = 1.25, 1.0   # bend: a cove's sharpest kink against the joint's
POCKET_RATIO = 1.55              # joints: a pocket's (three walls, two of them facing) against the joint's (base tree 3-4, then at most 1.45;
                                 # round 8: 1.50 -- the joint radius shrank 22.5 -> 21.4 px to free a tiled window's border (HyprJoint's
                                 # overlap 2.5 -> 1.4) and a pocket's kink follows 1/radius: dark wiki 2.50 -> 2.66 measured, 2.63 predicted,
                                 # the joint's own 1.77 both times; ablated with the old overlap it reads 2.50 again)
HUE_RATIO, HUE_FLOOR = 2.75, 0.015  # joints: a junction's sharpest chroma gradient against the halo's 95th percentile (base tree 3.3-8, now at most 2.3)
JR = 60                          # joints: px round a junction or a corner the judges read
PHASE_LIMIT = 0.18               # joints: the hue's phase across a junction's wedge, cycles (base tree 0.25-0.49 between two loops, now at most 0.13)
W = 4                            # bend: the slopes either side of a pixel, fitted over W px
bad, lines = [], []

def load(p):
    return np.asarray(Image.open(p).convert("RGB")).astype(float)

def kinks(B, box):
    """The largest jump of slope (levels/px) through each pixel of box, over four directions (least squares, W px a side)."""
    x0, y0, x1, y1 = box
    best = np.zeros((y1 - y0, x1 - x0))
    s2 = sum(k * k for k in range(1, W + 1))
    for ux, uy in ((1, 0), (0, 1), (1, 1), (1, -1)):
        acc = np.zeros_like(best)
        for k in range(1, W + 1):
            acc += k * (B[y0 - k * uy:y1 - k * uy, x0 - k * ux:x1 - k * ux] + B[y0 + k * uy:y1 + k * uy, x0 + k * ux:x1 + k * ux]
                        - 2 * B[y0:y1, x0:x1])
        best = np.maximum(best, acc / s2 / np.hypot(ux, uy))
    return best

for mode in modes:
    d = os.path.join(out, mode)
    log = open(os.path.join(d, "log.txt"), encoding="utf-8", errors="replace").read()
    if "AUPROBE DONE" not in log:
        bad.append(f"{mode}: the harness did not finish ({os.path.join(d, 'log.txt')})")
        continue
    for m in re.finditer(r"AUPROBE (\S+) (play|replay|palette|group): (.*)", log):
        if not m.group(3).startswith("playing on"):
            bad.append(f"{mode} {m.group(1)}: the aura did not play ({m.group(3)})")
    bodies = {m.group(1): [float(v) for v in m.group(2).split(",")] for m in re.finditer(r"AUBODY \d+ id=(\S+) box=(\S+)", log)}

    # ---- THE SEAM: every hand-over continuous ------------------------------------------------------------------
    frames = {}
    for m in re.finditer(r"AUFRAME (\S+) (\d+) time=(\S+) level=(\S+) colors=(\S+) mode=(\S+) cycles=(\S+) joins=(\S+) png=(\S+)", log):
        tag, k = m.group(1), int(m.group(2))
        frames.setdefault(tag, {})[k] = {"time": float(m.group(3)), "level": float(m.group(4)), "colors": m.group(5),
                                         "mode": m.group(6), "cycles": m.group(7), "joins": m.group(8), "png": os.path.join(d, m.group(9))}
    for tag, fr in frames.items():
        if len(fr) < 2:
            continue
        hm = re.search(r"AUPROBE " + re.escape(tag) + r" handover after frame (\d+)", log)
        if not hm:
            continue
        h = int(hm.group(1))
        ks = sorted(fr)
        imgs = {k: load(fr[k]["png"]) for k in ks}
        steps = {}
        for a, b in zip(ks, ks[1:]):
            A, B = imgs[a], imgs[b]
            lit = (A.max(axis=2) > 8) | (B.max(axis=2) > 8)
            steps[b] = float(np.abs(A - B).max(axis=2)[lit].mean()) if lit.any() else 0.0
        # the hand-over's step against the frames either side of it (a snap is one frame out of line with both)
        before = max(steps[k] for k in ks[1:] if k <= h)
        at = steps[h + 1]
        after = [steps[k] for k in ks if k > h + 1]
        around = max(steps[h], steps[h + 2])
        dt = [fr[b]["time"] - fr[a]["time"] for a, b in zip(ks, ks[1:])]
        lines.append(f"{mode} {tag}: step at the hand-over {at:.2f} levels (the frames either side {steps[h]:.2f} / {steps[h + 2]:.2f}; largest before {before:.2f}, after {max(after):.2f}); "
                     f"time step there {fr[h + 1]['time'] - fr[h]['time']:.4f} s (frames {min(dt):.4f}..{max(dt):.4f}); "
                     f"level {fr[h]['level']:.4f} -> {fr[h + 1]['level']:.4f}")
        if at > LIMIT * around + LEVEL:
            bad.append(f"{mode} {tag}: seam at the hand-over ({at:.2f} levels against {steps[h]:.2f} the frame before it and {steps[h + 2]:.2f} after)")
        dl = {b: abs(fr[b]["level"] - fr[a]["level"]) for a, b in zip(ks, ks[1:])}
        dlo = max(v for k, v in dl.items() if k != h + 1)
        if dl[h + 1] > 2 * dlo + 0.002:
            bad.append(f"{mode} {tag}: the level jumped at the hand-over ({fr[h]['level']:.4f} -> {fr[h + 1]['level']:.4f}; "
                       f"at most {dlo:.4f} a frame elsewhere)")
        if abs((fr[h + 1]["time"] - fr[h]["time"]) - dt[0]) > 0.5 * dt[0]:
            bad.append(f"{mode} {tag}: the picture's time jumped at the hand-over ({fr[h]['time']:.4f} -> {fr[h + 1]['time']:.4f} s)")
        eased = {"palette": "colors", "group": "mode"}.get(tag)
        for key in ("mode", "cycles", "joins", "colors"):
            if key != eased and fr[h][key] != fr[h + 1][key]:
                bad.append(f"{mode} {tag}: {key} changed at the hand-over ({fr[h][key]} -> {fr[h + 1][key]})")
        if eased and after and at > max(after) + LEVEL:
            bad.append(f"{mode} {tag}: the {eased} hand-over is a step ({at:.2f} levels, its ease at most {max(after):.2f})")

    # ---- THE BEND: no crease out of a cove -----------------------------------------------------------------------
    joint_ref = None
    if os.path.exists(os.path.join(d, "mono.png")) and os.path.exists(os.path.join(d, "off.png")):
        on, off = load(os.path.join(d, "mono.png")), load(os.path.join(d, "off.png"))
        ink = (on - off).max(axis=2)
        near = ndimage.binary_dilation(off.max(axis=2) > 0, iterations=3)
        H, Wd = ink.shape
        def worst(box):
            K = kinks(ink, box)
            x0, y0, x1, y1 = box
            K[near[y0:y1, x0:x1] | (ink[y0:y1, x0:x1] <= 8)] = 0
            iy, ix = np.unravel_index(np.argmax(K), K.shape)
            return float(K.max()), (int(x0 + ix), int(y0 + iy))
        coves = []
        for bid in ("bar:topL", "bar:topC", "bar:topR"):
            b = bodies.get(bid)
            if not b:
                continue
            if b[0] > 1:
                coves.append((bid + ":left", (int(b[0]) - 100, W + 1, int(b[0]) + 20, int(b[3]) + 60)))
            if b[2] < Wd - 1:
                coves.append((bid + ":right", (int(b[2]) - 20, W + 1, int(b[2]) + 100, int(b[3]) + 60)))
        jl = bodies.get("bar:left")
        if not jl or not coves:
            bad.append(f"{mode}: the bend judge found no island end or no joint (bodies: {sorted(bodies)})")
        else:
            ref, at = worst((int(jl[2]) + 4, int(jl[1]) + 5, int(jl[2]) + 124, int(jl[1]) + 125))
            joint_ref = ref
            lines.append(f"{mode} joint (the reference): sharpest kink {ref:.2f} levels/px at {at}")
            lim = KINK_RATIO * max(ref, KINK_FLOOR)
            for name, box in coves:
                k, at = worst(box)
                lines.append(f"{mode} cove {name}: sharpest kink {k:.2f} levels/px at {at} (limit {lim:.2f})")
                if k > lim:
                    bad.append(f"{mode} cove {name}: crease out of the bend ({k:.2f} levels/px at {at}; the joint's {ref:.2f})")
    # ---- THE JOINTS: every junction and corner of a scene's popups, no crease and no hue seam ---------------------------------
    def chroma_grad(on, off):
        ink = np.clip(on - off, 0, None)
        lum = ink.sum(axis=2) / 3
        R, G, B = ink[..., 0], ink[..., 1], ink[..., 2]
        c1 = (R - G) / np.maximum(lum, 1)
        c2 = ((R + G) / 2 - B) / np.maximum(lum, 1)
        k = 2
        g = np.zeros_like(lum)
        for c in (c1, c2):
            gx = np.zeros_like(c)
            gy = np.zeros_like(c)
            gx[:, k:-k] = (c[:, 2 * k:] - c[:, :-2 * k]) / (2 * k)
            gy[k:-k, :] = (c[2 * k:, :] - c[:-2 * k, :]) / (2 * k)
            g += gx * gx + gy * gy
        g = np.sqrt(g)
        mask = (lum > 30) & ~ndimage.binary_dilation(off.max(axis=2) > 0, iterations=3)
        mask[:k + 1, :] = mask[-k - 1:, :] = False
        mask[:, :k + 1] = mask[:, -k - 1:] = False
        g[~mask] = 0
        return g
    def palette_table(cols):
        C = np.array([[int(c[1:3], 16), int(c[3:5], 16), int(c[5:7], 16)] for c in cols], float)
        xs = np.arange(0, 4, 0.005)
        w = np.abs(xs[:, None] - np.arange(4)[None, :])
        w = np.maximum(1 - np.minimum(w, 4 - w), 0)
        T = (w * w * (3 - 2 * w)) @ C
        return xs / 4.0, T / np.maximum(np.linalg.norm(T, axis=1, keepdims=True), 1e-6)
    def phase_across(full, off, v, e, table):
        # the hue's phase (the palette inverted: the cycle position whose colour points the way the ink does) either side of a junction's
        # wedge -- 15 and 75 degrees from one face, at 30, 40 and 50 px from its vertex -- the largest difference, in cycles
        ink = np.clip(full - off, 0, None)
        xs, T = table
        sx, sy = math.copysign(1, e[0] - v[0]), math.copysign(1, e[1] - v[1])
        worst, n = 0.0, 0
        for rho in (30, 40, 50):
            ph = []
            for a in (15, 75):
                t = math.radians(a)
                xi, yi = int(round(v[0] + sx * rho * math.cos(t))), int(round(v[1] + sy * rho * math.sin(t)))
                if 0 <= xi < ink.shape[1] and 0 <= yi < ink.shape[0] and ink[yi, xi].sum() / 3 > 30:
                    px = ink[yi, xi] / max(np.linalg.norm(ink[yi, xi]), 1e-6)
                    ph.append(xs[int(np.argmax(T @ px))])
            if len(ph) == 2:
                worst = max(worst, abs((ph[0] - ph[1] + 0.5) % 1.0 - 0.5))
                n += 1
        return worst, n
    scenes = sorted(set(m.group(1) for m in re.finditer(r"AUSCENE (\S+) body ", log)))
    for sc in scenes:
        paths = {v: os.path.join(d, f"{sc}_{v}.png") for v in ("off", "mono", "full")}
        if not all(os.path.exists(p) for p in paths.values()):
            continue
        off, mono, full = (load(paths[v]) for v in ("off", "mono", "full"))
        ink = (mono - off).max(axis=2)
        near = ndimage.binary_dilation(off.max(axis=2) > 0, iterations=3)
        H, Wd = ink.shape
        def worst_kink(box):
            x0, y0, x1, y1 = [int(v) for v in box]
            x0, y0, x1, y1 = max(x0, W + 1), max(y0, W + 1), min(x1, Wd - W - 1), min(y1, H - W - 1)
            if x1 <= x0 or y1 <= y0:
                return 0.0, None
            K = kinks(ink, (x0, y0, x1, y1))
            K[near[y0:y1, x0:x1] | (ink[y0:y1, x0:x1] <= 8)] = 0
            iy, ix = np.unravel_index(np.argmax(K), K.shape)
            return float(K.max()), (x0 + int(ix), y0 + int(iy))
        sb = {m.group(1): ([float(v) for v in m.group(2).split(",")], m.group(3) == "1")
              for m in re.finditer(r"AUSCENE " + re.escape(sc) + r" body \d+ id=(\S+) box=(\S+) host=\S+ parent=\S+ mobile=(\d)", log)}
        fl = [(m.group(1), [float(v) for v in m.group(2).split(",")], [float(v) for v in m.group(3).split(",")])
              for m in re.finditer(r"AUSCENE " + re.escape(sc) + r" fillet \d+ key=(\S+) v=(\S+) e=(\S+) ", log)]
        pops = {k for k, (b, mob) in sb.items() if mob}
        # a sky flare's rect (its vertex to its far corner): a junction or corner whose box meets one is a POCKET
        sky = [(min(v[0], e[0]), min(v[1], e[1]), max(v[0], e[0]), max(v[1], e[1])) for key, v, e in fl if key.startswith("sky:")]
        jl = sb.get("bar:left")
        if not pops or not jl:
            bad.append(f"{mode} {sc}: the joints judge found no popup or no joint (bodies: {sorted(sb)})")
            continue
        # the joint: the base pose's (a popup of the scene may lie over the joint's corner), else the scene's own
        ref = joint_ref if joint_ref is not None else worst_kink((jl[0][2] + 4, jl[0][1] + 5, jl[0][2] + 124, jl[0][1] + 125))[0]
        G = chroma_grad(full, off)
        pm = re.search(r"AUFRAME " + re.escape(sc) + r"_full 0 .*? colors=(\S+)", log)
        table = palette_table(pm.group(1).split(",")) if pm else None
        hue_ref = float(np.percentile(G[G > 0], 95)) if (G > 0).any() else 0.0
        hue_lim = HUE_RATIO * max(hue_ref, HUE_FLOOR)
        sites = []
        for key, v, e in fl:
            ids = key.split("|")[:2]
            if not key.startswith("sky:") and any(i in pops for i in ids):
                sites.append(("junction " + "|".join(ids), v, True))
                if table is not None and min(abs(e[0] - v[0]), abs(e[1] - v[1])) >= 1:
                    ph, n = phase_across(full, off, v, e, table)
                    if n:
                        lines.append(f"{mode} {sc} junction {'|'.join(ids)} ({v[0]:.0f},{v[1]:.0f}): the hue's phase across it {ph:.3f} cycles")
                    if ph > PHASE_LIMIT:
                        bad.append(f"{mode} {sc}: hue phase apart across a junction: {'|'.join(ids)} ({v[0]:.0f},{v[1]:.0f}) {ph:.3f} cycles, "
                                   f"limit {PHASE_LIMIT} (two loops' hues met unrelated)")
        for bid in sorted(pops):
            b = sb[bid][0]
            for cx, cy in ((b[0], b[1]), (b[2], b[1]), (b[2], b[3]), (b[0], b[3])):
                sites.append((f"corner {bid} ({cx:.0f},{cy:.0f})", [cx, cy], False))
        worst_line = (0.0, "")
        for name, v, junction in sites:
            box = (v[0] - JR, v[1] - JR, v[0] + JR, v[1] + JR)
            pocket = any(r[0] < box[2] and r[2] > box[0] and r[1] < box[3] and r[3] > box[1] for r in sky)
            lim = (POCKET_RATIO if pocket else KINK_RATIO) * max(ref, KINK_FLOOR)
            k, at = worst_kink(box)
            if k > lim:
                bad.append(f"{mode} {sc}: crease at a junction: {name}{' (a pocket)' if pocket else ''} {k:.2f} levels/px at {at}, "
                           f"limit {lim:.2f} (the joint's {ref:.2f})")
            if k / lim > worst_line[0]:
                worst_line = (k / lim, f"{name}{' (a pocket)' if pocket else ''} {k:.2f} at {at} (limit {lim:.2f})")
            if junction:
                x0, y0 = max(int(box[0]), 0), max(int(box[1]), 0)
                sub = G[y0:max(int(box[3]), 0), x0:max(int(box[2]), 0)]
                if sub.size:
                    iy, ix = np.unravel_index(np.argmax(sub), sub.shape)
                    hv = float(sub.max())
                    lines.append(f"{mode} {sc} {name}: hue {hv:.4f}/px at {(x0 + int(ix), y0 + int(iy))} (limit {hue_lim:.4f})")
                    if hv > hue_lim:
                        bad.append(f"{mode} {sc}: hue seam at a junction: {name} {hv:.4f}/px at {(x0 + int(ix), y0 + int(iy))}, "
                                   f"limit {hue_lim:.4f} (the halo's 95th percentile {hue_ref:.4f})")
        lines.append(f"{mode} {sc}: {len(sites)} sites; the joint {ref:.2f} levels/px; the closest kink to its limit: {worst_line[1]}; "
                     f"hue limit {hue_lim:.4f}/px")
for l in lines:
    print(l)
for b in bad:
    print("FAIL " + b)
print(f"GOOEY_AURA RESULT {'FAIL' if bad else 'PASS'} ({len(lines)} read, {len(bad)} faults)")
sys.exit(1 if bad else 0)
PY
