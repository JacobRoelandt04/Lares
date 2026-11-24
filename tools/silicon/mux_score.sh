#!/usr/bin/env bash
# mux_score.sh -- a scored GPU A/B for the MUX question "when is dGPU-only worth it?".
#
# THE USER'S TOOL. It opens benchmark windows (fullscreen ones too) on the desktop, so it is run by hand, once per mode after
# a reboot, and never by an agent outside stubs. It starts no shell, writes nothing but its own result files, and touches no
# daemon: sysfs and `busctl --user get-property` reads only.
#
#   tools/silicon/mux_score.sh            run in the mode the machine is in now (Hybrid: the iGPU AND the dGPU via prime-run;
#                                         dGPU-only: natively), save the JSON, print the table
#   tools/silicon/mux_score.sh --compare  only print the table from the saved runs (no benchmark, no windows)
#
# What is run, the same every time: glmark2 (OpenGL, GLX through Xwayland, so prime-run offloads it) and vkmark (Vulkan), each
# windowed at a fixed 1280x720 and fullscreen, with each tool's DEFAULT scene set. Scores are the tools' own final line:
#   glmark2:  "                                  glmark2 Score: 1234 "    (glmark2 src/main.cpp)
#   vkmark:   "                                   vkmark Score: 1234"     (vkmark src/main.cpp)
# Results: ~/.local/share/lares/mux-score/<mode>-<gpu>-<date>.json  (<mode> hybrid|dgpu, <gpu> igpu|dgpu).
#
# The table puts the newest run of each (mode, gpu) side by side and says what dGPU-only gains over Hybrid. Fullscreen on the
# PRIME copy is where dGPU-only should win: a Hybrid dGPU frame is copied to the iGPU before it reaches the panel.
#
# Test knobs (stubs on PATH, a fake sysfs root): MUX_SCORE_SYS (prefix of /sys), MUX_SCORE_DIR (where results live),
# MUX_SCORE_TIMEOUT (seconds per tool run, default 600).
set -u

SYS="${MUX_SCORE_SYS:-}"
DIR="${MUX_SCORE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/lares/mux-score}"
TMO="${MUX_SCORE_TIMEOUT:-600}"
SIZE="1280x720"

say() { printf '%s\n' "$*"; }
die() { printf 'mux_score: %s\n' "$*" >&2; exit 1; }

read_first() { local f; for f in "$@"; do [ -r "$f" ] && { head -n1 "$f"; return 0; }; done; return 1; }

# ---- the table -------------------------------------------------------------------------------------------------------------
table() {
    python3 -I - "$DIR" <<'PY'
import glob, json, os, sys
d = sys.argv[1]
newest = {}
for p in sorted(glob.glob(os.path.join(d, "*.json"))):
    try:
        r = json.load(open(p))
        newest[(r["mode"], r["gpu"])] = (p, r)      # sorted by name: the date is last, so the later file wins
    except Exception:
        continue
cols = [("hybrid", "igpu", "Hybrid iGPU"), ("hybrid", "dgpu", "Hybrid + prime-run"), ("dgpu", "dgpu", "dGPU-only")]
if not newest:
    print("No saved runs in %s yet. Run tools/silicon/mux_score.sh once in each mode." % d)
    sys.exit(0)
keys = []
for _, r in newest.values():
    for k in r["scores"]:
        if k not in keys:
            keys.append(k)
order = lambda k: (k.split("/")[0], k.split("/")[1] != "windowed", k)
keys.sort(key=order)
def sc(col, k):
    e = newest.get((col[0], col[1]))
    v = e[1]["scores"].get(k) if e else None
    return v if isinstance(v, (int, float)) else None
def pct(a, b):
    return "%+.1f %%" % ((a / b - 1) * 100) if a is not None and b else "-"
w = max(len(k) for k in keys)
print("%-*s  %12s  %18s  %12s  %20s  %18s" % (w, "scene set", cols[0][2], cols[1][2], cols[2][2], "dGPU-only vs prime-run", "dGPU-only vs iGPU"))
for k in keys:
    a, b, c = (sc(x, k) for x in cols)
    f = lambda v: "-" if v is None else "%d" % v
    print("%-*s  %12s  %18s  %12s  %20s  %18s" % (w, k, f(a), f(b), f(c), pct(c, b), pct(c, a)))
print()
for col in cols:
    e = newest.get((col[0], col[1]))
    if e:
        r = e[1]
        print("%-20s %s  %s | %s | profile %s | %s | cardwire %s" % (col[2], r["date"], os.path.basename(e[0]), r["facts"].get("kernel", "?"),
              r["facts"].get("platformProfile", "?"), "AC" if r["facts"].get("ac") else "BATTERY", r["facts"].get("cardwireMode", "?")))
    else:
        print("%-20s (no run saved)" % col[2])
# warnings: runs not comparable
ws = []
runs = [newest[(c[0], c[1])][1] for c in cols if (c[0], c[1]) in newest]
if any(not r["facts"].get("ac") for r in runs):
    ws.append("a run was made on BATTERY: the machine may have throttled the GPU; use the charger for every run")
if len({r["facts"].get("platformProfile") for r in runs}) > 1:
    ws.append("the CPU/platform profile differs between runs (%s): the scores are not like for like" % ", ".join(sorted({str(r["facts"].get("platformProfile")) for r in runs})))
for r in runs:
    for w_ in r.get("warnings", []):
        ws.append("%s-%s: %s" % (r["mode"], r["gpu"], w_))
for w_ in ws:
    print("WARNING: " + w_)
print()
print("Reading it: higher is better. A positive percentage is dGPU-only ahead. Fullscreen on the prime-run copy is where dGPU-only")
print("should win (no copy to the iGPU); a window on a small scene is often a tie.")
print("This is not mux_bench.sh: tools/dev/mux_bench.sh measured LATENCY (key and frame to glass), this measures THROUGHPUT.")
print("In Hybrid, a program run WITHOUT prime-run is drawn by the iGPU and the dGPU stays asleep, which is why the latency bench in")
print("Hybrid never woke the card; only the prime-run rows above use it.")
PY
}

if [ "${1:-}" = "--compare" ]; then
    table
    exit 0
fi
[ $# -eq 0 ] || die "usage: mux_score.sh [--compare]"

# ---- the tools ---------------------------------------------------------------------------------------------------------------
missing=""
for t in glmark2 vkmark; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
if [ -n "$missing" ]; then
    say "Missing:$missing"
    say "sudo pacman -S --needed glmark2 vkmark"
    exit 1
fi

# ---- the wiring: which GPU drives the internal panel (the helper's rule: the eDP connector's card, by vendor) ----------------
wiring=""
for st in "$SYS"/sys/class/drm/card[0-9]*-eDP-*/status; do
    [ -r "$st" ] || continue
    [ "$(head -n1 "$st")" = connected ] || continue
    card="${st%/*}"; card="${card##*/}"; card="${card%%-*}"
    case "$(read_first "$SYS/sys/class/drm/$card/device/vendor")" in
        0x8086) wiring=hybrid ;;
        0x10de) wiring=dgpu ;;
    esac
done
[ -n "$wiring" ] || die "cannot tell the wiring (no connected eDP panel on an Intel or NVIDIA card under $SYS/sys/class/drm)"

if [ "$wiring" = hybrid ]; then
    command -v prime-run >/dev/null 2>&1 || die "Hybrid needs prime-run for the dGPU rows (Arch: nvidia-prime)"
    gpus="igpu dgpu"
else
    gpus="dgpu"
fi

# ---- machine facts -----------------------------------------------------------------------------------------------------------
kernel="$(uname -r)"
profile="$(read_first "$SYS/sys/firmware/acpi/platform_profile" || echo unknown)"
ac=false
for f in "$SYS"/sys/class/power_supply/*/online; do
    [ -r "$f" ] || continue
    case "$f" in */BAT*) continue ;; esac
    [ "$(head -n1 "$f")" = 1 ] && ac=true
done
cwmode="unknown"
if command -v busctl >/dev/null 2>&1; then
    out="$(timeout 5 busctl --user --json=short get-property org.opengamingcollective.cardwire /org/opengamingcollective/cardwire org.opengamingcollective.cardwire.Mode Mode 2>/dev/null || true)"
    case "$out" in
        *'"data":0'*) cwmode=integrated ;; *'"data":1'*) cwmode=hybrid ;; *'"data":3'*) cwmode=smart ;;
    esac
fi
pkgs="$(pacman -Q nvidia-utils nvidia-open-dkms nvidia-dkms mesa vulkan-intel glmark2 vkmark 2>/dev/null | tr '\n' ';' | sed 's/;$//')"
muxfw="$(read_first "$SYS/sys/devices/platform/asus-nb-wmi/gpu_mux_mode" || echo unknown)"

say "Wiring: $wiring (firmware gpu_mux_mode $muxfw), cardwire $cwmode, profile $profile, $([ "$ac" = true ] && echo AC || echo BATTERY), kernel $kernel"
[ "$ac" = true ] || say "WARNING: on battery. Plug in the charger and run again; every run should have the same power."
[ "$wiring" = hybrid ] && [ "$cwmode" != hybrid ] && [ "$cwmode" != unknown ] && \
    say "WARNING: cardwire is $cwmode, not Hybrid: it may keep prime-run off the dGPU (the renderer check below says so if it did)."
say "This opens benchmark windows, a few minutes in all. Do not touch the machine meanwhile."
say ""

mkdir -p "$DIR" || die "cannot make $DIR"
date_s="$(date +%Y%m%d-%H%M%S)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# one run of one tool; prints "score|renderer" ; $1 prefix command ("" or prime-run), $2 tool, $3.. its flags
run_tool() {
    local pre="$1" tool="$2"; shift 2
    local log="$tmp/out.$$.$RANDOM" score renderer
    if [ -n "$pre" ]; then
        timeout --foreground -k 5 "$TMO" "$pre" "$tool" "$@" >"$log" 2>&1
    else
        timeout --foreground -k 5 "$TMO" "$tool" "$@" >"$log" 2>&1
    fi
    score="$(sed -n -E 's/^[[:space:]]*(glmark2|vkmark) Score:[[:space:]]*([0-9]+).*/\2/p' "$log" | tail -n1)"
    renderer="$(sed -n -E 's/^[[:space:]]*(GL_RENDERER|Device Name):[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\2/p' "$log" | head -n1)"
    printf '%s|%s\n' "${score:-}" "$renderer"
}

for gpu in $gpus; do
    pre=""
    [ "$wiring" = hybrid ] && [ "$gpu" = dgpu ] && pre=prime-run
    say "== $wiring / $gpu${pre:+ ($pre)} =="
    : > "$tmp/scores"; : > "$tmp/renderers"; : > "$tmp/warnings"
    for tool in glmark2 vkmark; do
        for screen in windowed fullscreen; do
            if [ "$screen" = windowed ]; then flags=(--size "$SIZE"); else flags=(--fullscreen); fi
            if [ "$tool" = vkmark ]; then flags+=(--present-mode immediate); fi
            printf '  %s %s ... ' "$tool" "$screen"
            res="$(run_tool "$pre" "$tool" "${flags[@]}")"
            score="${res%%|*}"; renderer="${res#*|}"
            if [ -z "$score" ]; then
                say "NO SCORE"
                printf '%s no score line from %s %s\n' "$tool/$screen" "$tool" "${flags[*]}" >> "$tmp/warnings"
                continue
            fi
            say "$score  [$renderer]"
            printf '%s\t%s\n' "$tool/$screen" "$score" >> "$tmp/scores"
            printf '%s\t%s\n' "$tool/$screen" "$renderer" >> "$tmp/renderers"
            if [ "$gpu" = dgpu ] && ! printf '%s' "$renderer" | grep -qi nvidia; then
                printf '%s ran on "%s", not the NVIDIA card\n' "$tool/$screen" "$renderer" >> "$tmp/warnings"
            elif [ "$gpu" = igpu ] && printf '%s' "$renderer" | grep -qi nvidia; then
                printf '%s ran on the NVIDIA card in the iGPU row\n' "$tool/$screen" >> "$tmp/warnings"
            fi
        done
    done
    out="$DIR/$wiring-$gpu-$date_s.json"
    python3 -I - "$out" "$wiring" "$gpu" "$tmp" "$kernel" "$profile" "$ac" "$cwmode" "$muxfw" "$pkgs" "$SIZE" <<'PY'
import json, sys, datetime
out, mode, gpu, tmp, kernel, profile, ac, cw, fw, pkgs, size = sys.argv[1:]
rows = lambda f: [l.rstrip("\n").split("\t", 1) for l in open(tmp + "/" + f) if l.strip()]
json.dump({
    "mode": mode, "gpu": gpu, "date": datetime.datetime.now().isoformat(timespec="seconds"), "windowedSize": size,
    "scores": {k: int(v) for k, v in rows("scores")},
    "renderers": {k: v for k, v in rows("renderers")},
    "warnings": [l.strip() for l in open(tmp + "/warnings") if l.strip()],
    "facts": {"kernel": kernel, "platformProfile": profile, "ac": ac == "true", "cardwireMode": cw, "firmwareMuxMode": fw, "packages": pkgs},
}, open(out, "w"), indent=2)
PY
    say "  saved $out"
    say ""
done

table
