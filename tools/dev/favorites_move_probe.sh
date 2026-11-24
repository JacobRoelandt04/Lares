#!/usr/bin/env bash
# favorites_move_probe.sh -- the favourites leave the repo: FavoritesStore copies a file from its legacyPath (the repo's root, where
# system_update_favorites.json / launcher_favorites.json lived until 2026-11-23) to its path under $XDG_STATE_HOME/lares/<module>/ once,
# leaves the old file as it was, and a new file always wins (tools/dev/qml/favorites_move_probe.qml says what is checked).
#
#   tools/dev/favorites_move_probe.sh               FAVMOVE RESULT PASS | FAIL (...)
#   ARM=nomigrate tools/dev/favorites_move_probe.sh the store never moves the old file: "moved: the new file holds the old list" must go red
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/favm.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
mkdir -p "$D/moved" "$D/kept/new" "$D/none"
printf '{\n  "favorites": [\n    "yay",\n    "linux"\n  ]\n}\n' > "$D/moved/old.json"
printf '{ "favorites": ["old-one"] }\n' > "$D/kept/old.json"
printf '{ "favorites": ["mine"] }\n' > "$D/kept/new/favorites.json"
cp "$D/moved/old.json" "$D/moved/old.ref"; cp "$D/kept/old.json" "$D/kept/old.ref"
P=modules/common/components/FavoritesStore.qml
ARMCMD=""; NEEDLE=""
case "${ARM:-}" in
    "") ;;
    nomigrate) NEEDLE="moved: the new file holds the old list"
               ARMCMD="sed -i 's|        if (!store.path \\|\\| !store.legacyPath \\|\\| store.legacyPath === store.path)|        if (true)|' $P; grep -q '        if (true)\$' $P" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QML_XHR_ALLOW_FILE_READ=1 FAV_DIR='"$D"' XDG_CONFIG_HOME='"$D"'/cfg XDG_STATE_HOME='"$D"'/state XDG_CACHE_HOME='"$D"'/cache timeout 60 quickshell -p tools/dev/qml/favorites_move_probe.qml'
tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'FAVM .*' | grep -a -v 'FAVM RESULT'
rl_clean "$D/log" | grep -a -o 'LARES favorites moved.*' | sed "s|$D|<dir>|g"
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a "FAVM FAIL" | grep -a -q "$NEEDLE"; then echo "ARM $ARM: failed as it must ($NEEDLE)"; exit 0; fi
    if ! rl_has "$D/log" 'FAVM RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE'"; exit 1
fi
if ! rl_clean "$D/log" | grep -a -q 'LARES favorites moved .*/moved/old.json -> .*/moved/new/favorites.json'; then
    echo "FAVM FAIL the move is not logged (LARES favorites moved <old> -> <new>)"; echo "FAVMOVE RESULT FAIL (no move line)"; exit 1
fi
if [ "$(rl_clean "$D/log" | grep -a -c 'LARES favorites moved')" != 1 ]; then
    echo "FAVM FAIL a move is logged where none was due"; echo "FAVMOVE RESULT FAIL (extra move line)"; exit 1
fi
res=$(rl_result FAVMOVE "$D/log" 'FAVM RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi
printf '%s\n' "$res" | sed 's/^FAVM RESULT/FAVMOVE RESULT/'
exit $rc
