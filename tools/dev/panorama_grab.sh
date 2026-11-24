#!/usr/bin/env bash
# tools/dev/panorama_grab.sh -- the Panorama mockup's STAGE as a PNG per scenario, offscreen (never a window on the desktop), a private
# state / config / cache home.
#
#   tools/dev/panorama_grab.sh <outdir> [scene[:select[:stage]] ...]      e.g.  desk  desk:DVI-I-1  desk:DVI-I-1:move  projector
# no argument: laptop desk desk:DVI-I-1 desk:DVI-I-1:move projector three onlyExternal mirror integrated dlNoService modeFails connectedOff notImported
set -u
cd "$(dirname "$0")/../.." || exit 1
OUT="${1:?usage: panorama_grab.sh <outdir> [scene[:select[:stage]] ...]}"; shift
OUT="$(realpath -m "$OUT")"
# Never in the tree itself (a quickshell rewrites .qmlls.ini where it starts): a tree with a git dir is the config, a copy has none.
if [ -e .git ]; then
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen MODE="${MODE:-light}" GRAB_MS="${GRAB_MS:-2500}" tools/dev/panorama_grab.sh "$OUT" "$@"
fi
mkdir -p "$OUT"
[ $# -gt 0 ] || set -- laptop desk desk:DVI-I-1 desk:DVI-I-1:move projector three onlyExternal mirror integrated dlNoService modeFails connectedOff notImported
PRIV=$(mktemp -d /tmp/pano-grab.XXXXXX); trap 'rm -rf "$PRIV"' EXIT
rc=0
for spec in "$@"; do
    IFS=: read -r scene sel stage <<< "$spec"
    rm -rf "$PRIV"/*; mkdir -p "$PRIV/config/theme" "$PRIV/state" "$PRIV/cache" "$PRIV/rt"; chmod 700 "$PRIV/rt"
    printf '{"theme":"eva","mode":"%s"}\n' "${MODE:-light}" > "$PRIV/config/theme/state.json"
    f="$OUT/${spec//:/_}.png"
    env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QML_DISABLE_DISTANCEFIELD=1 \
        XDG_CONFIG_HOME="$PRIV/config" XDG_STATE_HOME="$PRIV/state" XDG_CACHE_HOME="$PRIV/cache" XDG_RUNTIME_DIR="$PRIV/rt" \
        SCENE="$scene" SELECT="${sel:-}" STAGE="${stage:-}" SHEET_GRAB="$f" GRAB_MS="${GRAB_MS:-2500}" \
        tools/dev/notifications_bus.sh timeout 40 quickshell -p mockups/panorama.qml > "$PRIV/log" 2>&1
    sed 's/\x1b\[[0-9;]*m//g' "$PRIV/log" | grep -v "portal" | grep -E "WARN|ERROR|Unable to assign|Binding loop|non-existent" | sort | uniq -c | head -8
    [ -s "$f" ] && echo "$f" || { echo "NO GRAB for $spec"; rc=1; tail -5 "$PRIV/log"; }
done
exit $rc
