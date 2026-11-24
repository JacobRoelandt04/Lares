#!/usr/bin/env bash
# picker_probe.sh -- the emoji / symbol / Nerd Fonts picker: a pick pastes the right bytes with the ORIGIN window's paste key, the tray is
# pasted joined, Escape pastes nothing, the one skin tone applies everywhere and is remembered, digits on Symbols jump to an alt code; the
# Nerd tab's list is fetched once for the installed font's version, Enter pastes the glyph and Ctrl+Enter the name, a failed fetch is one
# plain line; and the fetch tool's own unit check (tools/dev/picker_nerd_check.py: the coverage filter, the version read from the font).
#
#   tools/dev/picker_probe.sh                 PICKER RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=nopaste|wrongtone|nodigitjump|nameonenter|ctrlglyph|reask|refetch|nofilter|nofailline|nomissing|clearalltabs|copypastes tools/dev/picker_probe.sh
#
# The REAL PickerPopup + PickerService + ClipboardService (no watcher) in a hidden window; wl-copy, hyprctl and curl are STUBS first on PATH
# (tools/dev/qml/picker_probe.qml has the checks; the curl stub serves tools/dev/fixtures/glyphnames-3.5.1.json, the bytes
# raw.githubusercontent.com answered, or fails as `curl_mode` says), a private state folder and cache folder, offscreen. Nothing touches the
# clipboard, a window or the network. The font read is the machine's (read only).
# The verdict is the probe's own RESULT line (tools/dev/result_lib.sh); an ARM runs in the sandbox copy and must fail on its own needle:
#   nopaste      the service never hands the text to the clipboard service      -> `PK FAIL pasted bytes`
#   wrongtone    a pick's text ignores the tone                                 -> `PK FAIL the tone applies to the paste`
#   nodigitjump  a digit query is a plain name search                           -> `PK FAIL '23' lists exactly`
#   nameonenter  a Nerd item always pastes its name                             -> `PK FAIL Enter on the Nerd tab picks the GLYPH`
#   ctrlglyph    Ctrl+Enter picks the glyph like Enter                          -> `PK FAIL Ctrl+Enter picks the NAME`
#   reask        ensureNerd() runs the tool at every ask                        -> `PK FAIL asking again for a list that is there runs nothing`
#   refetch      the tool ignores its cache (fetches at every run)              -> `PK FAIL a second session finds the cache current`
#   nofilter     the tool keeps code points the font lacks                      -> `NC FAIL a code point the font lacks is dropped`
#   nofailline   a failed fetch shows no line on the page                       -> `PK FAIL the failure line`
#   nomissing    a missing data file says nothing (error stays empty)           -> `PKM FAIL missing data: the service says what happened`
#   clearalltabs Clear takes every tab's records out, not only this tab's       -> `PK FAIL Clear empties only this tab's recents`
#   copypastes   picker.jsonc's "copy" sends the paste key all the same         -> `PK FAIL config: pick 'copy': no paste key`
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/pk.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
S=modules/picker/data/PickerService.qml
P=modules/picker/PickerPopup.qml
T=tools/picker/nerd_fetch.py
ARMCMD="" NEEDLE=""
case "${ARM:-}" in
    "") ;;
    nopaste) ARMCMD="grep -q 'if (root.live && root.clipboard) {' $S && sed -i 's|if (root.live [&][&] root.clipboard) {|if (false) {|' $S && grep -q 'if (false) {' $S"
             NEEDLE='PK FAIL pasted bytes' ;;
    wrongtone) ARMCMD="grep -q 'return it.tonable ? Model.toned(it.ch, root.tone, root.tones) : it.ch;' $S && sed -i 's|return it.tonable ? Model.toned(it.ch, root.tone, root.tones) : it.ch;|return it.ch;|' $S"
               NEEDLE='PK FAIL the tone applies to the paste' ;;
    nodigitjump) ARMCMD="grep -q 'if (popup.digits !== \"\") {' $P && sed -i 's|if (popup.digits !== \"\") {|if (false) {|' $P"
                 NEEDLE="PK FAIL '23' lists exactly" ;;
    nameonenter) ARMCMD="grep -q 'if (it.asName === true)' $S && sed -i 's|if (it.asName === true)|if (it.asName === true \|\| it.tab === \"nerd\")|' $S && grep -q 'it.tab === \"nerd\")' $S"
                 NEEDLE='PK FAIL Enter on the Nerd tab picks the GLYPH' ;;
    ctrlglyph) ARMCMD="grep -q 'it = Model.asName(it);' $P && sed -i 's|it = Model.asName(it);|it = it;|' $P"
               NEEDLE='PK FAIL Ctrl+Enter picks the NAME' ;;
    reask) ARMCMD="grep -q 'if (root.nerdState === \"loading\" || root.nerdState === \"ready\")' $S && sed -i 's/if (root.nerdState === \"loading\" || root.nerdState === \"ready\")/if (false)/' $S && grep -q 'if (false)' $S"
           NEEDLE='PK FAIL asking again for a list that is there runs nothing' ;;
    refetch) ARMCMD="grep -q 'if have.get(\"version\") == 1 and have.get(\"nerd\") == version' $T && sed -i 's/if have.get(\"version\") == 1 and have.get(\"nerd\") == version/if False and have.get(\"nerd\") == version/; s/\"glyphnames-%s.json\" % version/\"glyphnames-%s-%d.json\" % (version, os.getpid())/' $T && grep -q 'os.getpid())' $T"
             NEEDLE='PK FAIL a second session finds the cache current' ;;
    nofilter) ARMCMD="grep -q 'if len(ch) != 1 or ord(ch) not in cmap:' $T && sed -i 's/if len(ch) != 1 or ord(ch) not in cmap:/if len(ch) != 1:/' $T"
              NEEDLE='NC FAIL a code point the font lacks is dropped' ;;
    nofailline) ARMCMD="grep -q 'No Nerd Fonts list: ' $P && sed -i 's|\"No Nerd Fonts list: \" + popup.service.nerdError + \". Leave this tab and come back to retry.\"|\"\"|' $P && grep -q 'nerdState === \"error\" ? \"\"' $P"
                NEEDLE='PK FAIL the failure line' ;;
    clearalltabs) ARMCMD="grep -q 'if (root._tabOfKey(ch) !== tab)' $S && sed -i 's|if (root._tabOfKey(ch) !== tab)|if (false)|' $S && grep -q 'if (false)' $S"
                  NEEDLE="PK FAIL Clear empties only this tab's recents" ;;
    copypastes) ARMCMD="grep -q 'mode: root.copyOnly ? ' $S && sed -i 's|mode: root.copyOnly ? \"copy\" : \"paste\"|mode: \"paste\"|' $S && grep -q 'paste(\[\], { mode: \"paste\", text' $S"
                NEEDLE="PK FAIL config: pick 'copy': no paste key" ;;
    nomissing) ARMCMD="grep -q 'root.error = \"The emoji and symbol data is missing' $S && sed -i 's|root.error = \"The emoji and symbol data is missing or out of date: tools/picker/build_data.py makes it\";|root.error = \"\";|' $S && grep -q 'root.error = \"\";' $S"
               NEEDLE="PKM FAIL missing data: the service says what happened" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
# the stubs: wl-copy keeps what it was fed, hyprctl answers the active window and records a dispatch
mkdir -p "$D/bin" "$D/stubs" "$D/cfg/theme" "$D/state"
printf '{"theme":"eva","mode":"light"}\n' > "$D/cfg/theme/state.json"
cat > "$D/bin/wl-copy" <<'STUB'
#!/bin/sh
{ printf '['; cat; printf ']\n'; } >> "$PK_STUBS/copies.log"
STUB
# the active window is the one the probe says (the file `active`, written by the harness with the origin it sets)
cat > "$D/bin/hyprctl" <<'STUB'
#!/bin/sh
case "$*" in
    "-j activewindow") printf '{"address":"%s","class":"x"}\n' "$(cat "$PK_STUBS/active" 2>/dev/null)" ;;
    dispatch*) shift; printf '%s\n' "$*" >> "$PK_STUBS/hyprctl.log"; echo ok ;;
    *) ;;
esac
STUB
# curl: logs its argv, serves the saved 3.5.1 list (what the tool's `-o <file> -w %{http_code}` expects), or fails as `curl_mode` says
cat > "$D/bin/curl" <<'STUB'
#!/bin/sh
mode=$(cat "$PK_STUBS/curl_mode" 2>/dev/null || echo ok)
printf '%s\n' "$*" >> "$PK_STUBS/curl.log"
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift ;; esac; shift; done
case "$mode" in
    offline) echo "curl: (7) Failed to connect to raw.githubusercontent.com port 443" >&2; exit 7 ;;
    404) : > "$out"; printf 404 ;;
    *) cat "$PK_FIXTURE" > "$out"; printf 200 ;;
esac
STUB
chmod +x "$D/bin/wl-copy" "$D/bin/hyprctl" "$D/bin/curl"
run='set -e; '"${ARMCMD:+$ARMCMD; }"'python3 tools/dev/picker_nerd_check.py || true; env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME='"$D/cfg"' PK_STUBS='"$D/stubs"' PK_STATE='"$D/state"' PK_FIXTURE="$PWD/tools/dev/fixtures/glyphnames-3.5.1.json" PATH='"$D/bin"':$PATH timeout 150 quickshell -p tools/dev/qml/picker_probe.qml || true; mv modules/picker/data/picker_data.json modules/picker/data/picker_data.json.gone; env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME='"$D/cfg"' PKM=1 timeout 60 quickshell -p tools/dev/qml/picker_missing_probe.qml'
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-picker}" tools/dev/sandbox.sh env QT_QPA_PLATFORM=offscreen bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o '\(PKM\|PK\|NC\) .*' | grep -a -v '\(PKM\|PK\|NC\) RESULT'
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -q "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if ! rl_has "$D/log" 'PK RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result PICKER "$D/log" 'PK RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi
# the fetch tool's own unit check ran first, in the same copy: its verdict counts
nres=$(rl_clean "$D/log" | grep -a -o 'NC RESULT .*' | tail -1)
case "$nres" in *"NC RESULT PASS"*) ;; *) rc=1; res="PK RESULT FAIL (the Nerd tool's unit check: ${nres:-no result})" ;; esac
# the missing-data harness ran last, in the same copy: its verdict counts
mres=$(rl_clean "$D/log" | grep -a -o 'PKM RESULT .*' | tail -1)
case "$mres" in *"PKM RESULT PASS"*) ;; *) rc=1; res="PK RESULT FAIL (the missing-data check: ${mres:-no result})" ;; esac
printf '%s\n' "$res" | sed 's/^PK RESULT/PICKER RESULT/'
[ -z "$nres" ] || printf '%s\n' "$nres"
exit $rc
