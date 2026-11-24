#!/usr/bin/env bash
# tools/dev/panorama_import_probe.sh -- `lares panorama-import` (tools/panorama/panorama-import.py) and the binds rows, on a FAKE home.
#
#   tools/dev/panorama_import_probe.sh          ends in PANORAMA_IMPORT RESULT PASS|FAIL
#   ARM=typedno | nobackup | norefuse           the fault in a COPY of the tool; the run must FAIL on its own check
#
# The fake home is built from tools/dev/fixtures/panorama/hypr/ (shaped like the user's files, never the user's own), with a
# stub hyprctl that answers `-j monitors all` from the laptop's capture and records every eval. Nothing outside the run's dir
# is read or written: HYPR_DIR / LARES_STATE / HYPRCTL / XDG_CONFIG_HOME point the tool and `lares binds` at it.
#
# Checks:
#   dry       --dry-run writes nothing (a hash of the whole fake home before and after) and shows the plan
#   typedno   any answer but `yes` writes nothing
#   yes       `yes` writes setups.json (the panel bound to its live description, DVI-I-1 a port: placeholder, the HDMI mirror and
#             the workspace rule dropped), panorama.lua (generated: the header, the data, the engine), the swapped require line,
#             monitors.lua as a note naming the backup, the backup itself, and one `eval dofile(...)`
#   again     a second run has nothing to do and writes nothing
#   refuse    a file changed while the plan was shown refuses the whole run, nothing written
#   binds     `lares binds`: MISSING before the import, ok after
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tools/dev/result_lib.sh"
TOOL="$ROOT/tools/panorama/panorama-import.py"
W=$(mktemp -d /tmp/pnimp.XXXXXX)
trap 'rm -rf "$W"' EXIT
fails=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails + 1)); }

case "${ARM:-}" in
    "") ;;
    typedno|nobackup|norefuse)
        mkdir -p "$W/tool"; cp -r "$ROOT/tools/panorama/." "$W/tool/"; TOOL="$W/tool/panorama-import.py"
        python3 - "$TOOL" "$ARM" <<'PY' || { echo "PANORAMA_IMPORT RESULT FAIL (ARM ${ARM}: its anchor is gone)"; exit 1; }
import sys
p, arm = sys.argv[1], sys.argv[2]
s = open(p).read()
a = {"typedno": ('    if answer != "yes":\n', '    if False:\n'),
     "nobackup": ('    shutil.copy2(p["hl"], os.path.join(bdir, "hyprland.lua"))\n', '    pass\n'),
     "norefuse": ('        if sha(now) != sha(before):\n', '        if False:\n')}[arm]
if s.count(a[0]) != 1:
    raise SystemExit(1)
open(p, "w").write(s.replace(a[0], a[1]))
PY
        echo "ARMED a copy of the tool: $ARM" ;;
    *) echo "PANORAMA_IMPORT RESULT FAIL (unknown ARM $ARM)"; exit 1 ;;
esac

fresh() {   # a new fake home
    rm -rf "$W/home"; mkdir -p "$W/home/xdg" "$W/home/state" "$W/home/bin"
    cp -r "$ROOT/tools/dev/fixtures/panorama/hypr" "$W/home/xdg/hypr"
    cat > "$W/home/bin/hyprctl" <<EOF
#!/bin/sh
case "\$*" in
  "-j monitors all") cat "$ROOT/tools/dev/fixtures/panorama/monitors_all_laptop.json" ;;
  *) printf '%s\n' "\$*" >> "$W/home/hyprctl.log"; echo ok ;;
esac
EOF
    chmod +x "$W/home/bin/hyprctl"
}
run() {   # run <answer|-> [args...]: the tool against the fake home
    local ans=$1; shift
    if [ "$ans" = - ]; then
        HYPR_DIR="$W/home/xdg/hypr" LARES_STATE="$W/home/state" HYPRCTL="$W/home/bin/hyprctl" python3 "$TOOL" "$@" < /dev/null
    else
        printf '%s\n' "$ans" | HYPR_DIR="$W/home/xdg/hypr" LARES_STATE="$W/home/state" HYPRCTL="$W/home/bin/hyprctl" python3 "$TOOL" "$@"
    fi
}
tree_hash() { (cd "$W/home" && find . -type f -print0 | sort -z | xargs -0 sha256sum) | sha256sum | cut -c1-16; }
binds_row() {   # the Panorama row's status word from `lares binds`
    XDG_CONFIG_HOME="$W/home/xdg" "$ROOT/tools/shell/lares" binds 2>&1 | sed -n '/displays -- Panorama/,/^$/p' | awk '$2 == "panorama" {print $1; exit}'
}

echo "PANORAMA_IMPORT probe ${ARM:+(ARM $ARM)}"

# dry
fresh; h0=$(tree_hash); out=$(run - --dry-run 2>&1); h1=$(tree_hash)
if [ "$h0" = "$h1" ] && grep -q "KEEP  eDP-1" <<< "$out" && grep -q "DROP  HDMI-A-1: mirrors" <<< "$out" && grep -q "nothing was changed" <<< "$out"
then ok "dry: the plan shown, nothing written"; else bad "dry: hash $h0 -> $h1, or the plan is not as expected"; fi

# binds before
[ "$(binds_row)" = MISSING ] && ok "binds: MISSING before the import" || bad "binds: before the import the row reads '$(binds_row)', not MISSING"

# typedno
fresh; h0=$(tree_hash); out=$(run no 2>&1); h1=$(tree_hash)
if [ "$h0" = "$h1" ] && grep -q "nothing was written" <<< "$out"; then ok "typedno: 'no' writes nothing"
else bad "typedno: an answer of 'no' changed the fake home ($h0 -> $h1)"; fi

# yes
fresh; out=$(run yes 2>&1); rc=$?
S="$W/home/state/panorama/setups.json"; L="$W/home/xdg/hypr/config/panorama.lua"; H="$W/home/xdg/hypr/hyprland.lua"; M="$W/home/xdg/hypr/config/monitors.lua"
if [ "$rc" = 0 ] && [ -f "$S" ] && python3 - "$S" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ids = set(d["displays"])
assert "Samsung Display Corp. 0x4180" in ids and d["displays"]["Samsung Display Corp. 0x4180"]["internal"], ids
assert d["displays"]["port:DVI-I-1"]["placeholder"] is True, d["displays"]
assert not any("HDMI" in k for k in ids), ids
k = "Samsung Display Corp. 0x4180 + port:DVI-I-1"
assert d["setups"][k]["outputs"]["port:DVI-I-1"]["position"] == [-280, -1440], d["setups"]
assert d["setups"]["Samsung Display Corp. 0x4180"]["outputs"]["Samsung Display Corp. 0x4180"]["bitdepth"] == 10
assert d["split"] == {}, d["split"]
PY
then ok "yes: setups.json holds the panel (bound), the DVI-I-1 placeholder, no HDMI, no workspace rule"
else bad "yes: setups.json is missing or wrong (rc $rc): $(tail -3 <<< "$out")"; fi
if [ -f "$L" ] && head -3 "$L" | grep -qi "generated" && grep -q "PANORAMA_DATA_JSON" "$L"; then ok "yes: panorama.lua generated"
else bad "yes: panorama.lua is missing or not the generated file"; fi
if grep -q '^pcall(require, "config/panorama")' "$H" && ! grep -q 'config/monitors' "$H"; then ok "yes: hyprland.lua requires config/panorama, not config/monitors"
else bad "yes: hyprland.lua's require line was not swapped"; fi
if ! grep -q 'hl.monitor' "$M" && grep -q 'import-' "$M"; then ok "yes: monitors.lua is a note naming the backup"
else bad "yes: monitors.lua still sets monitors, or names no backup"; fi
b=$(ls -d "$W/home/state/panorama"/import-* 2> /dev/null | head -1)
if [ -n "$b" ] && cmp -s "$b/hyprland.lua" "$ROOT/tools/dev/fixtures/panorama/hypr/hyprland.lua" && cmp -s "$b/monitors.lua" "$ROOT/tools/dev/fixtures/panorama/hypr/config/monitors.lua"
then ok "yes: the backup holds both files as they were"; else bad "yes: the backup is missing or not the original files"; fi
if [ "$(grep -c '^eval dofile' "$W/home/hyprctl.log" 2> /dev/null)" = 1 ]; then ok "yes: one eval dofile(panorama.lua)"
else bad "yes: the engine was not loaded once ($(cat "$W/home/hyprctl.log" 2> /dev/null | tr '\n' ';'))"; fi

# binds after
[ "$(binds_row)" = ok ] && ok "binds: ok after the import" || bad "binds: after the import the row reads '$(binds_row)', not ok"

# again
h0=$(tree_hash); out=$(run yes 2>&1); h1=$(tree_hash)
if [ "$h0" = "$h1" ] && grep -q "nothing to import" <<< "$out"; then ok "again: a second run has nothing to do"
else bad "again: a second run changed the fake home or did not say so"; fi

# refuse: the file changes between the plan and the yes
fresh; mkfifo "$W/in"
( HYPR_DIR="$W/home/xdg/hypr" LARES_STATE="$W/home/state" HYPRCTL="$W/home/bin/hyprctl" python3 "$TOOL" < "$W/in" > "$W/refuse.out" 2>&1 ) &
pid=$!
exec 7> "$W/in"
for _ in $(seq 1 50); do grep -q "Type yes" "$W/refuse.out" 2> /dev/null && break; sleep 0.1; done
printf '\n-- an edit made while the plan was shown\n' >> "$W/home/xdg/hypr/hyprland.lua"
h0=$(tree_hash)
echo yes >&7; exec 7>&-
wait "$pid"
h1=$(tree_hash)
if [ "$h0" = "$h1" ] && grep -q "REFUSED: .* changed while the plan was shown" "$W/refuse.out"; then ok "refuse: a file changed under the plan refuses the run"
else bad "refuse: the run went on over a changed file ($h0 -> $h1): $(tail -2 "$W/refuse.out")"; fi

if [ "$fails" -gt 0 ]; then echo "PANORAMA_IMPORT RESULT FAIL ($fails checks)"; exit 1; fi
echo "PANORAMA_IMPORT RESULT PASS"
