#!/usr/bin/env bash
# tools/dev/gooey_overshoot_poses.sh -- THE REST FRAME and THE OVERSHOOT'S BIAS (GooeyEngine): popups of the real shell frame
# held at points of their open, grabbed, and judged; opens measured frame by frame; the open's curve swept.
#
#   tools/dev/gooey_overshoot_poses.sh <out> [spec ...]       specs as tools/dev/qml/gooey_overshoot_poses.qml reads them
#                                                              (default: the round's set, below)
#   MODES=light,dark   the theme modes rendered (light)
#   TREE=<dir>         render ANOTHER tree (an old revision: `git archive <rev> | tar -x -C <dir>`): the harness and this
#                      runner are laid into a copy of it, nothing else of this tree
#   SCALE= BAR_RATIO= POPUP_RATIO=   the shell's global scale and ratios (mockups/shell.qml reads them; 1 by default)
#   ARM=noframe        the fault, in the copy: the engine never frames a content (GooeyEngine `_restFrameOf` answers null),
#                      which is the old engine's behaviour; the judge must FAIL on `content moved`
#   ARM=twophase       the fault, in the copy: the open's OutBack is made of two motions -- the growth to the rest box on an
#                      OutCubic over 60 % of the clock, then the overshoot as a bump of its own -- the seam the user warned of;
#                      the judge must FAIL on `velocity step`
#   ARM=nobias         the fault, in the copy: every open runs openOvershoot whatever its travel (GooeyGeometry
#                      `biasedOvershoot` answers s0); the judge must FAIL on `peak off its bias`
#   ARM=nowidth        the fault, in the copy: an open's run ignores its extent across the motion (`biasedOvershoot` hands
#                      `biasedPeakPx` no cross and no area: round 2's rule) while the engine's own swell keeps it; the judge
#                      must FAIL on `peak off its bias` for a wide popup (the clipboard, the launcher)
#   ARM=tight          the fault, in the copy: the area budget far too tight (GooeyEngine `openOvershootArea` 1500), which crushes
#                      the tray menus the user likes; the judge must FAIL on `liked swell moved`
#
# Every state runs offscreen in a tools/dev/sandbox.sh copy (SANDBOX, default /tmp/lares-sandbox-overshoot), on the shell's mock
# services, a private session bus, private XDG homes with the theme state seeded, the still wall clock and the fixed
# gradient wallpaper of tools/dev/sheet_render.py. <out>/<mode>/<tag>_t<t>.png are the stage (2880 x 1620), log.txt the
# harness's OSPOSE lines.
#
# THE JUDGE (per spec with a rest grab, t=1): the content must stand still while the open overshoots -- the stage inside
# the REST box, inset by `INSET` px (the corners' radius and the surface's antialiased rim), is compared between each
# posed t past the curve's crossing of 1 and the rest grab (rendered through the same clip layer): `content moved` when
# more than SHARE of it differs by more than LEVEL in any channel. And the open must overshoot (`no overshoot`): the box
# at the peak t (`@p`: the open's own) reaches past the rest box by at least 1 px.
# THE BIAS (per `peak:` spec): the open must have come to rest (`MISSED`), and its edges' swell past the rest box, sampled on
# every frame, must be the engine's own swell of the run (openOvershootPxFor: its travel and its extent across the motion)
# within max(1 px, 4 %) (`peak off its bias`). A spec ending in `~<px>` (`pkpower=peak:power~8.96`) names a swell the user
# LIKES as it is (the reels, the tray's menus, the theme popup: the frame px they approved in round 2, at this run's geometry):
# the measured swell must stay within max(1 px, 10 %) of it (`liked swell moved`), whatever the bias is retuned to.
# THE ONE MOTION (per `sweep:` spec): the clock written t = k/400 and laid out; the edge that travels furthest must move with a
# continuous speed: no step between two samples larger than 1.5 x what the smooth curve's steepest acceleration allows,
# travel x (4 s + 6) / 400 (`velocity step`), and the sweep's run must not have been re-aimed under it (`DISTURBED`).
# Ends in GOOEY_OVERSHOOT RESULT PASS|FAIL.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?usage: gooey_overshoot_poses.sh <out> [spec ...]}"
shift
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
SPECS=("$@")
if [ ${#SPECS[@]} -eq 0 ]; then
    SPECS=("llm=llm@0.25,0.5,p,0.8,1" "llmhist=llm+history@0.25,p,1" "player=player@0.25,0.5,p,0.8,1"
           "mini=player+mini@0.25,p,1" "browse=player+browse@0.25,p,1" "manager=notifications@p,1"
           "managerposts=notifications+post3@0.25,p,1" "weather=weather@p,1" "clock=clock@p,1"
           "clockwiki=clock+wiki@p,1" "wikichild=child:clock:wiki@p,1"
           "pkpower=peak:power~8.96" "pktheme=peak:theme~31.22" "pktray1=peak:tray:1~17.56" "pktray2=peak:tray:2~12.40"
           "pkclipboard=peak:clipboard"
           "pklauncher=peak:launcher" "pkmanager=peak:notifications+post3" "pkwiki=peak:child:clock:wiki"
           "swpower=sweep:power" "swtheme=sweep:theme" "swlauncher=sweep:launcher" "swtray2=sweep:tray:2"
           "foldllm=act:llm:history@0.5,1" "tomini=act:player:mini@0.5,1" "toplayer=act:player:player+mini@0.5,1"
           "browseact=act:player:browse@0.5,1" "closeplayer=close:player@0.15,0.3" "closeclock=close:clock@0.15,0.3")
fi
# a liked swell (`~<px>`) is the judge's, not the harness's
LIKED=""
for i in "${!SPECS[@]}"; do
    case "${SPECS[$i]}" in
    *"~"*) LIKED="$LIKED${SPECS[$i]%%=*}:${SPECS[$i]##*~};"; SPECS[$i]="${SPECS[$i]%~*}" ;;
    esac
done
export OSP_LIKED="${OSP_LIKED:-$LIKED}"
JOINED=$(IFS=';'; echo "${SPECS[*]}")

if [ -n "${TREE:-}" ] && [ -z "${OSP_TREE_DONE:-}" ]; then
    T="$(cd "$TREE" && pwd)"
    mkdir -p "$T/tools/dev/qml"
    cp "$ROOT/tools/dev/gooey_overshoot_poses.sh" "$T/tools/dev/"
    cp "$ROOT/tools/dev/qml/gooey_overshoot_poses.qml" "$T/tools/dev/qml/"
    exec env OSP_TREE_DONE=1 TREE= "$T/tools/dev/gooey_overshoot_poses.sh" "$OUT" "${SPECS[@]}"
fi

if [ -z "${OSP_INNER:-}" ]; then
    own=0
    [ -z "${SANDBOX:-}" ] && own=1          # a copy the caller named (shell_gates' tree sandbox) is the caller's to remove
    export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-overshoot}"
    "$ROOT/tools/dev/sandbox.sh" -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE QT_QPA_PLATFORM=offscreen MOCKUP_REPO= OSP_INNER=1 \
        tools/dev/gooey_overshoot_poses.sh "$OUT" "${SPECS[@]}"
    rc=$?
    [ "$own" = 1 ] && rm -rf "$SANDBOX"
    exit $rc
fi

# ---- inside the copy -------------------------------------------------------------------------------------------------
[ -e .git ] && { echo "GOOEY_OVERSHOOT RESULT FAIL (the inner run stands in a work tree, not a sandbox copy)"; exit 1; }
if [ "${ARM:-}" = noframe ]; then
    python3 - <<'PY' || { echo "GOOEY_OVERSHOOT RESULT FAIL (ARM noframe: its anchor is gone)"; exit 1; }
p = "modules/bar/gooey/GooeyEngine.qml"
s = open(p, encoding="utf-8").read()
a = "    function _restFrameOf(S, b) {\n"
if s.count(a) != 1:
    raise SystemExit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, a + "        return null;\n"))
print("ARM noframe: the engine frames nothing")
PY
fi
if [ "${ARM:-}" = twophase ]; then
    python3 - <<'PY' || { echo "GOOEY_OVERSHOOT RESULT FAIL (ARM twophase: its anchor is gone)"; exit 1; }
p = "modules/bar/gooey/GooeyGeometry.js"
s = open(p, encoding="utf-8").read()
a = "        const u = t - 1;\n        return u * u * ((s + 1) * u + s) + 1;\n"
if s.count(a) != 1:
    raise SystemExit(1)
b = ("        if (t < 0.6)\n            return 1 - Math.pow(1 - t / 0.6, 3);\n"
     "        return 1 + backPeak(s) * Math.sin(Math.PI * (t - 0.6) / 0.4);\n")
open(p, "w", encoding="utf-8").write(s.replace(a, b))
print("ARM twophase: the open grows to rest, then bounces on a curve of its own")
PY
fi
if [ "${ARM:-}" = nobias ]; then
    python3 - <<'PY' || { echo "GOOEY_OVERSHOOT RESULT FAIL (ARM nobias: its anchor is gone)"; exit 1; }
p = "modules/bar/gooey/GooeyGeometry.js"
s = open(p, encoding="utf-8").read()
a = "function biasedOvershoot(travel, s0, cap, bend, cross, area) {\n"
if s.count(a) != 1:
    raise SystemExit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, a + "    return s0;\n"))
print("ARM nobias: every open runs s0")
PY
fi
if [ "${ARM:-}" = nowidth ]; then
    python3 - <<'PY' || { echo "GOOEY_OVERSHOOT RESULT FAIL (ARM nowidth: its anchor is gone)"; exit 1; }
p = "modules/bar/gooey/GooeyGeometry.js"
s = open(p, encoding="utf-8").read()
a = "backForPeak(biasedPeakPx(travel, s0, cap, bend, cross, area) / travel, s0)"
if s.count(a) != 1:
    raise SystemExit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, "backForPeak(biasedPeakPx(travel, s0, cap, bend, 0, 0) / travel, s0)"))
print("ARM nowidth: every run ignores its extent across the motion")
PY
fi
if [ "${ARM:-}" = tight ]; then
    python3 - <<'PY' || { echo "GOOEY_OVERSHOOT RESULT FAIL (ARM tight: its anchor is gone)"; exit 1; }
import re
p = "modules/bar/gooey/GooeyEngine.qml"
s = open(p, encoding="utf-8").read()
s2, n = re.subn(r"(?m)^    property real openOvershootArea: [0-9.]+$", "    property real openOvershootArea: 1500", s)
if n != 1:
    raise SystemExit(1)
open(p, "w", encoding="utf-8").write(s2)
print("ARM tight: the area budget 1500")
PY
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lares-os.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
gcc -shared -fPIC -O2 -o "$WORK/stillclock.so" tools/dev/sheet_stillclock.c -ldl || { echo "GOOEY_OVERSHOOT RESULT FAIL (no still clock)"; exit 1; }
python3 -B -c "import sys; sys.path.insert(0, 'tools/dev'); import sheet_render; sheet_render.png_gradient(sys.argv[1])" "$WORK/wall.png"
mkdir -p "$WORK/stubs"
for prog in nvidia-smi nvidia-modprobe systemd-run; do printf '#!/bin/sh\nexit 1\n' > "$WORK/stubs/$prog"; chmod +x "$WORK/stubs/$prog"; done

# the harness beside the shell mockup it builds (quickshell serves nothing outside the run file's directory); in the copy only
cp tools/dev/qml/gooey_overshoot_poses.qml mockups/zz_overshoot_poses.qml
IFS=',' read -r -a MODELIST <<< "${MODES:-light}"
for mode in "${MODELIST[@]}"; do
    d="$WORK/$mode"
    mkdir -p "$d/cfg/theme" "$d/state/lares-shell-mock/config" "$d/cache" "$d/data" "$d/rt" "$OUT/$mode"
    chmod 700 "$d/rt"
    printf '{"theme":"eva","mode":"%s"}\n' "$mode" > "$d/cfg/theme/state.json"
    rm -f "$OUT/$mode"/*.png
    # (the environment emptied BEFORE the private bus: dbus-run-session hands its own address to the command)
    env -i \
        HOME="$HOME" USER="${USER:-user}" PATH="$WORK/stubs:$PATH" DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" \
        LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TZ=Europe/Brussels \
        XDG_RUNTIME_DIR="$d/rt" XDG_CONFIG_HOME="$d/cfg" XDG_STATE_HOME="$d/state" XDG_CACHE_HOME="$d/cache" XDG_DATA_HOME="$d/data" \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_QPA_PLATFORMTHEME= QT_LOGGING_RULES=qt.qpa.services.warning=false \
        QML_DISABLE_DISTANCEFIELD=1 QT_HASH_SEED=0 QS_ICON_THEME=Papirus QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 \
        LARES_SLEEP_MONITOR=off MOCKUP_REPO= SHELL_SERVICES=mock WALL="file://$WORK/wall.png" ZOOM=1 \
        SCALE="${SCALE:-1}" BAR_RATIO="${BAR_RATIO:-1}" POPUP_RATIO="${POPUP_RATIO:-1}" \
        OS_OUT="$OUT/$mode" OS_SPECS="$JOINED" \
        tools/dev/notifications_bus.sh timeout -k 5 600 env LD_PRELOAD="$WORK/stillclock.so" SHEET_NOW=1793199600 \
        quickshell -p mockups/zz_overshoot_poses.qml > "$OUT/$mode/log.txt" 2>&1
    echo "rendered $mode: $(grep -c '^.*OSPOSE ' "$OUT/$mode/log.txt") poses, $(grep -c 'OSPOSES DONE' "$OUT/$mode/log.txt") done"
done

python3 -B - "$OUT" "${MODELIST[@]}" <<'PY'
import os, re, sys
from PIL import Image, ImageChops
out, modes = sys.argv[1], sys.argv[2:]
INSET, LEVEL, SHARE = 16, 12, 0.002
LIKED = {k: float(v) for k, v in (e.split(":", 1) for e in os.environ.get("OSP_LIKED", "").split(";") if ":" in e)}
bad, lines = [], []
for mode in modes:
    log = open(os.path.join(out, mode, "log.txt"), encoding="utf-8", errors="replace").read()
    if "OSPOSES DONE" not in log:
        bad.append(f"{mode}: the harness did not finish ({os.path.join(out, mode, 'log.txt')})")
    poses = {}
    for m in re.finditer(r"OSPOSE (\S+) (\S+) kind=(\S+) .*?e=(\S+) box=(\S+) rest=(\S+) framed=(\d)[^\n]*?png=(\S+)", log):
        tag, t, kind, e, box, rest, framed, png = m.groups()
        if kind in ("act", "close"):
            continue        # a fold, a view switch, a close: pictures to look at, not the open's rule
        bx = [float(v) for v in box.split(",")] if box != "-" else None
        poses.setdefault(tag, []).append({"t": float(t), "e": float(e), "box": bx, "framed": framed, "png": os.path.join(out, mode, png),
                                          "peak": "peakpose=1" in m.group(0)})
    # THE BIAS: each open's swell against the engine's own function of its travel
    for m in re.finditer(r"OSPEAK (\S+) ([^\n]*)", log):
        tag, rest_ = m.groups()
        if rest_.startswith("MISSED"):
            bad.append(f"{mode} {tag}: MISSED -- {rest_}")
            continue
        f = dict(kv.split("=", 1) for kv in rest_.split() if "=" in kv)
        peak, want = float(f["peak"]), f.get("want", "-")
        lines.append(f"{mode} {tag}: travel {f['travel']} (leg {f['leg']}), s {f['s']}, swell {peak:.2f} px (stage {f['stage']}), want {want}, {f['frames']} frames"
                     + (f", liked {LIKED[tag]:.2f}" if tag in LIKED else ""))
        if want != "-":
            w = float(want)
            if abs(peak - w) > max(1.0, 0.04 * w):
                bad.append(f"{mode} {tag}: peak off its bias ({peak:.2f} px against {w:.2f} for a travel of {f['leg']} px)")
        if tag in LIKED and abs(peak - LIKED[tag]) > max(1.0, 0.10 * LIKED[tag]):
            bad.append(f"{mode} {tag}: liked swell moved ({peak:.2f} px against the {LIKED[tag]:.2f} the user likes; max(1 px, 10 %))")
    # THE ONE MOTION: the swept curve's speed has no step
    for m in re.finditer(r"OSSWEEP (\S+) ([^\n]*)", log):
        tag, rest_ = m.groups()
        f = dict(kv.split("=", 1) for kv in rest_.split() if "=" in kv)
        if "DISTURBED" in rest_:
            bad.append(f"{mode} {tag}: DISTURBED (the run was re-aimed under the sweep)")
            continue
        d = [float(v) for v in f["d"].split(",")]
        n, s_, tr = int(f["n"]), float(f["s"]), float(f["travel"])
        dt = 1.0 / n
        v = [(d[k + 1] - d[k]) / dt for k in range(n)]
        dv = [abs(v[k + 1] - v[k]) for k in range(n - 1)]
        bound = 1.5 * tr * (4 * s_ + 6) * dt + 0.5
        k = max(range(len(dv)), key=lambda i: dv[i])
        lines.append(f"{mode} {tag}: swept s {s_}, travel {tr:.1f} px, top speed {max(v):.0f} px/clock, largest speed step {dv[k]:.1f} at t={(k + 1) * dt:.3f} (bound {bound:.1f})")
        if dv[k] > bound:
            bad.append(f"{mode} {tag}: velocity step of {dv[k]:.1f} px/clock at t={(k + 1) * dt:.3f} (bound {bound:.1f}: the open is not one motion)")
    for tag, ps in poses.items():
        rest = [p for p in ps if p["t"] >= 1]
        if not rest or not rest[0]["box"] or not os.path.exists(rest[0]["png"]):
            lines.append(f"{mode} {tag}: no rest grab, not judged")
            continue
        rb = rest[0]["box"]
        ri = Image.open(rest[0]["png"]).convert("RGB")
        x0, y0, x1, y1 = int(rb[0]) + INSET, int(rb[1]) + INSET, int(rb[2]) - INSET, int(rb[3]) - INSET
        for p in ps:
            if p["t"] >= 1 or not p["box"] or not os.path.exists(p["png"]):
                continue
            b = p["box"]
            over = max(rb[0] - b[0], rb[1] - b[1], b[2] - rb[2], b[3] - rb[3])
            if over < 0.5:
                lines.append(f"{mode} {tag} t={p['t']}: inside its rest box (reach {over:+.1f} px), not judged")
                if p["peak"]:
                    bad.append(f"{mode} {tag}: no overshoot (the box at t={p['t']} reaches {over:+.1f} px past its rest box)")
                continue
            pi = Image.open(p["png"]).convert("RGB")
            d = ImageChops.difference(ri.crop((x0, y0, x1, y1)), pi.crop((x0, y0, x1, y1)))
            px = d.load()
            w, h = d.size
            n = sum(1 for yy in range(h) for xx in range(w) if max(px[xx, yy]) > LEVEL)
            share = n / max(1, w * h)
            lines.append(f"{mode} {tag} t={p['t']} e={p['e']}: overshoot {over:.1f} px, framed={p['framed']}, content {n} px of {w * h} differ ({100 * share:.3f} %)")
            if share > SHARE:
                bad.append(f"{mode} {tag} t={p['t']}: content moved ({100 * share:.3f} % of the rest box differs)")
for l in lines:
    print(l)
for b in bad:
    print("FAIL " + b)
print(f"GOOEY_OVERSHOOT RESULT {'FAIL' if bad else 'PASS'} ({len(lines)} poses read, {len(bad)} faults)")
sys.exit(1 if bad else 0)
PY
