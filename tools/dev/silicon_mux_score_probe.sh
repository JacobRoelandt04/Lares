#!/usr/bin/env bash
# silicon_mux_score_probe.sh -- tools/silicon/mux_score.sh against STUB glmark2 / vkmark / prime-run and a fake sysfs. No
# benchmark runs, no window opens, nothing outside the scratch dir is read or written.
# The display is taken away from every run (no WAYLAND_DISPLAY, no DISPLAY): a real benchmark that slipped past the stubs fails to
# open its window instead of drawing on the user's desktop. The "no tools" case gets a PATH of its own -- every program of /usr/bin
# but the benchmarks -- never the system's: on 2026-11-19 the user had installed glmark2 and vkmark, and that case, run with
# PATH=/usr/bin:/bin, started the REAL benchmarks (windowed, then fullscreen through prime-run) on the desktop during two gate runs.
#   ARM=<name>   a fault put into a COPY of the script; the run must end FAIL
#     nopct      the comparison percentage is not printed                 -> table-percent FAILS
#     nomissing  the missing-tools check is skipped                       -> missing-tools FAILS
#     ownpath    the stub tools' score lines are not parsed               -> scores-saved FAILS
# Verdict: "SILICON-MUX-SCORE RESULT PASS|FAIL".
set -u
unset WAYLAND_DISPLAY DISPLAY
NAME=SILICON-MUX-SCORE
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/r12mux.XXXXXX")"; trap 'rm -rf "$W"' EXIT
fail=0
ck() { if [ "$2" = ok ]; then echo "  ok   $1"; else echo "  FAIL $1 ${3:-}"; fail=1; fi; }
S="$W/mux_score.sh"; cp "$ROOT/tools/silicon/mux_score.sh" "$S"
case "${ARM:-}" in
    nopct) sed -i 's/return "%+.1f %%" % ((a \/ b - 1) \* 100) if a is not None and b else "-"/return "-"/' "$S" ;;
    nomissing) sed -i 's/^if \[ -n "\$missing" \]; then/if false; then/' "$S" ;;
    ownpath) sed -i 's/(glmark2|vkmark) Score:/(nothing) Score:/' "$S" ;;
    "") ;;
    *) echo "unknown ARM"; exit 2 ;;
esac
mkdir -p "$W/bin" "$W/sys/class/drm/card0-eDP-1" "$W/sys/class/drm/card0/device" "$W/sys/firmware/acpi" "$W/sys/class/power_supply/AC0"
echo connected > "$W/sys/class/drm/card0-eDP-1/status"; echo 0x8086 > "$W/sys/class/drm/card0/device/vendor"
echo quiet > "$W/sys/firmware/acpi/platform_profile"; echo 1 > "$W/sys/class/power_supply/AC0/online"
for t in glmark2 vkmark; do
  cat > "$W/bin/$t" <<EOT
#!/usr/bin/env bash
echo "\$0 \$*" >> "$W/calls.log"
if [ -n "\${__NV_PRIME_RENDER_OFFLOAD:-}" ] || [ -f "$W/dgpuonly" ]; then r="NVIDIA GeForce RTX 4060"; base=\${STUB_DGPU:-9000}; else r="Mesa Intel(R) Graphics (ADL GT2)"; base=\${STUB_IGPU:-3000}; fi
[ "$t" = vkmark ] && lab="Device Name:     " || lab="GL_RENDERER:     "
printf '=======================================================\n    $t 2023.01\n=======================================================\n    %s%s\n=======================================================\n' "\$lab" "\$r"
if [ "$t" = glmark2 ]; then printf '                                  glmark2 Score: %s \n' "\$base"; else printf '                                   vkmark Score: %s\n' "\$base"; fi
EOT
  chmod +x "$W/bin/$t"
done
printf '#!/usr/bin/env bash\necho "prime-run $*" >> "%s/calls.log"\n__NV_PRIME_RENDER_OFFLOAD=1 exec "$@"\n' "$W" > "$W/bin/prime-run"; chmod +x "$W/bin/prime-run"
export MUX_SCORE_SYS="$W" MUX_SCORE_DIR="$W/out" PATH="$W/bin:$PATH"

# no tools: only the one pacman line. A PATH of every /usr/bin program but the benchmarks (and prime-run), whatever is installed.
mkdir -p "$W/nobench"
for f in /usr/bin/*; do
  case "${f##*/}" in glmark2*|vkmark*|prime-run) continue ;; esac
  ln -s "$f" "$W/nobench/${f##*/}" 2>/dev/null
done
out="$(PATH="$W/nobench" MUX_SCORE_SYS="$W" MUX_SCORE_DIR="$W/out0" bash "$S" 2>&1 | tr -d '\r')"
[ "$out" = "$(printf 'Missing: glmark2 vkmark\nsudo pacman -S --needed glmark2 vkmark')" ] && ck missing-tools ok || ck missing-tools bad "$out"

# Hybrid: iGPU and prime-run
bash "$S" > "$W/hy.txt" 2>&1; rc=$?
[ $rc = 0 ] && ck hybrid-exit ok || ck hybrid-exit bad "rc=$rc $(tail -3 "$W/hy.txt")"
n=$(ls "$W/out" 2>/dev/null | grep -c '^hybrid-.*json$')
[ "$n" = 2 ] && ck hybrid-two-files ok || ck hybrid-two-files bad "$n"
ig=$(ls "$W/out"/hybrid-igpu-*.json 2>/dev/null | head -1); dg=$(ls "$W/out"/hybrid-dgpu-*.json 2>/dev/null | head -1)
python3 -I - "$ig" "$dg" <<'PY' && ck scores-saved ok || ck scores-saved bad
import json, sys
i = json.load(open(sys.argv[1])); d = json.load(open(sys.argv[2]))
assert set(i["scores"]) == {"glmark2/windowed", "glmark2/fullscreen", "vkmark/windowed", "vkmark/fullscreen"}, i["scores"]
assert i["scores"]["glmark2/windowed"] == 3000 and d["scores"]["vkmark/fullscreen"] == 9000, (i, d)
assert d["warnings"] == [] and i["warnings"] == [] and i["facts"]["ac"] is True and i["facts"]["platformProfile"] == "quiet"
PY
grep -q '^prime-run glmark2 --fullscreen' "$W/calls.log" && grep -q 'glmark2 --size 1280x720' "$W/calls.log" && grep -q 'vkmark --fullscreen --present-mode immediate' "$W/calls.log" && ck fixed-flags ok || ck fixed-flags bad "$(cat "$W/calls.log" | head -4)"

# dGPU-only (the panel on the NVIDIA card), natively, newer than the hybrid runs
echo 0x10de > "$W/sys/class/drm/card0/device/vendor"; touch "$W/dgpuonly"; sleep 1.1
STUB_DGPU=11000 bash "$S" > "$W/dg.txt" 2>&1
ls "$W/out"/dgpu-dgpu-*.json >/dev/null 2>&1 && ck dgpu-file ok || ck dgpu-file bad
grep -c prime-run "$W/calls.log" | grep -qx 4 && ck dgpu-native ok || ck dgpu-native bad "prime-run calls: $(grep -c prime-run "$W/calls.log")"
grep -q 'vkmark/fullscreen .*11000 .*+22.2 %' <(tr -s ' ' < "$W/dg.txt" | sed 's/ \+/ /g') && ck table-percent ok || { grep -q '+22.2 %' "$W/dg.txt" && ck table-percent ok || ck table-percent bad "$(tail -14 "$W/dg.txt")"; }
bash "$S" --compare > "$W/cmp.txt" 2>&1; echo "rc=$?" >> "$W/cmp.txt"
grep -q 'mux_bench.sh' "$W/cmp.txt" && grep -qi 'without prime-run' "$W/cmp.txt" && ck compare-notes ok || ck compare-notes bad "$(head -5 "$W/cmp.txt")"
echo 0x8086 > "$W/sys/class/drm/card0/device/vendor"; rm "$W/dgpuonly"
echo 0 > "$W/sys/class/power_supply/AC0/online"
bash "$S" 2>&1 | grep -q 'WARNING: on battery' && ck battery-warning ok || ck battery-warning bad
[ $fail = 0 ] && { echo "$NAME RESULT PASS"; exit 0; } || { echo "$NAME RESULT FAIL"; exit 1; }
