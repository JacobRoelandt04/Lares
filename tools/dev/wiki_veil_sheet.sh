#!/usr/bin/env bash
# wiki_veil_sheet.sh -- every wiki veil (modules/wiki/WikiVeil.qml) at the full card's well and as a thumbnail, light and dark.
# Offscreen, in the sandbox, private homes; no desktop window.
#   tools/dev/wiki_veil_sheet.sh [OUTDIR]          veils_<light|dark>.png  (default ~/.cache/claude-wiki/veils)
#   T=<s>            veil seconds after each article's start (0: the thumbnail's frame)
#   PATTERNS=a,b     only these patterns        KEYS=<n>   article columns (3)
#   PLATE=1          with the logo plate        ZOOM=<n>   magnified (nearest)       MODES="light dark"
#   STRIP=<s>,<s>,.. a filmstrip instead: one PNG per time, veils_<mode>_t<s>.png
# Ends on WIKI_VEIL_SHEET RESULT PASS|FAIL (a PNG per mode and no warning).
{
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
export SANDBOX="${SANDBOX:-/tmp/lares-sbx-wiki}"
OUT="${1:-$HOME/.cache/claude-wiki/veils}"
mkdir -p "$OUT"
D="$(mktemp -d "${SCRATCH:-/tmp}/wvs.XXXXXX")"
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/home" "$D/state" "$D/cache" "$D/data"
rc=0
times="${STRIP:-${T:-0}}"
for mode in ${MODES:-light dark}; do
    mkdir -p "$D/cfg-$mode/theme"
    echo "{\"mode\":\"$mode\",\"theme\":\"eva\"}" > "$D/cfg-$mode/theme/state.json"
    for t in ${times//,/ }; do
        png="$OUT/veils_$mode$([ -n "${STRIP:-}" ] && echo "_t$t").png"
        log="$D/$mode-$t.log"
        rm -f "$png"
        tools/dev/sandbox.sh env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi \
            HOME="$D/home" XDG_CONFIG_HOME="$D/cfg-$mode" XDG_STATE_HOME="$D/state" XDG_CACHE_HOME="$D/cache" XDG_DATA_HOME="$D/data" \
            WVS_OUT="$png" WVS_T="$t" WVS_PATTERNS="${PATTERNS:-}" WVS_KEYS="${KEYS:-3}" WVS_PLATE="${PLATE:-}" WVS_ZOOM="${ZOOM:-1}" \
            timeout 60 quickshell -p tools/dev/qml/wiki_veil_sheet.qml > "$log" 2>&1
        if [ ! -s "$png" ]; then
            cp "$log" "$OUT/failed-$mode-$t.log"
            # the verdict is the LAST line: a sheet that does not load ends here
            rl_noresult WIKI_VEIL_SHEET "$OUT/failed-$mode-$t.log"
            exit 1
        fi
        w=$(rl_clean "$log" | rl_platform_noise | grep -a -E "^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent|TypeError|ReferenceError|is not a type|ShaderEffect" | sort | uniq -c | head -10)
        if [ -n "$w" ]; then
            printf '%s\n' "$w"
            rc=1
        fi
        echo "PNG $png"
    done
done
[ "$rc" = 0 ] && echo "WIKI_VEIL_SHEET RESULT PASS" || echo "WIKI_VEIL_SHEET RESULT FAIL"
exit $rc
}
