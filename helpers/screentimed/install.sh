#!/usr/bin/env bash
# install.sh -- install (or remove) the screentime daemon for the CURRENT USER. No root, no systemctl.
#
#   cargo build --release            (this script never runs cargo)
#   ./install.sh                     install
#   ./install.sh --uninstall         remove exactly what install put there; the data is never deleted
#   ./install.sh --dry-run           say what would happen, change nothing (works with --uninstall too)
#   HOME=/some/dir ./install.sh      everything lands under that HOME (how the tests run it)
#
# What it touches (the whole list):
#   $HOME/.local/bin/screentimed                          the binary, 0755, copied atomically (tmp + rename)
#   $HOME/.config/systemd/user/screentimed.service        the unit (units/screentimed.service)
#   $HOME/.local/share/lares/screentime/             the data dir, created 0700 if missing (the unit's
#                                                         ProtectHome=read-only could not create it)
# It does NOT start anything. Afterwards, by hand:
#   systemctl --user daemon-reload && systemctl --user enable --now screentimed
set -euo pipefail
export LC_ALL=C

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BIN_SRC="${BIN_SRC:-$HERE/target/release/screentimed}"
UNIT_SRC="$HERE/units/screentimed.service"
H="${HOME:?HOME is not set}"
BIN_DST="$H/.local/bin/screentimed"
UNIT_DST="$H/.config/systemd/user/screentimed.service"
DATA_DIR="$H/.local/share/lares/screentime"

DRY=0
UNINSTALL=0
say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) die "unknown argument: $a (try --help)" ;;
    esac
done
run() { if [ "$DRY" = 1 ]; then say "would: $*"; else "$@"; fi; }

if [ "$UNINSTALL" = 1 ]; then
    for f in "$BIN_DST" "$UNIT_DST"; do
        if [ -e "$f" ]; then run rm -f -- "$f"; say "removed $f"; else say "not installed: $f"; fi
    done
    say "kept the data: $DATA_DIR"
    say "if it ran: systemctl --user disable --now screentimed; systemctl --user daemon-reload"
    exit 0
fi

[ -x "$BIN_SRC" ] || die "no binary at $BIN_SRC (cargo build --release first)"
[ -f "$UNIT_SRC" ] || die "no unit at $UNIT_SRC"
run mkdir -p -- "$(dirname "$BIN_DST")" "$(dirname "$UNIT_DST")"
# The data moved with the project's name (lares migrate-name): while it is still under the old one, a new empty dir here would be a second copy
# the migration then refuses ("both exist").
OLD_DATA="$H/.local/share/quickshell/screentime"
if [ -d "$OLD_DATA" ] && [ ! -L "$OLD_DATA" ] && [ ! -e "$DATA_DIR" ]; then
    die "the data still lives in $OLD_DATA: run \`lares migrate-name\` first (it moves it to $DATA_DIR and leaves a symlink)"
fi
run install -d -m 0700 -- "$DATA_DIR"
if [ "$DRY" = 1 ]; then
    say "would: copy $BIN_SRC -> $BIN_DST (0755, tmp + rename)"
    say "would: copy $UNIT_SRC -> $UNIT_DST (0644, tmp + rename)"
else
    tmp="$(mktemp "$BIN_DST.XXXXXX")"
    trap 'rm -f -- "$tmp"' EXIT
    install -m 0755 -- "$BIN_SRC" "$tmp"
    mv -f -- "$tmp" "$BIN_DST"
    tmp="$(mktemp "$UNIT_DST.XXXXXX")"
    install -m 0644 -- "$UNIT_SRC" "$tmp"
    mv -f -- "$tmp" "$UNIT_DST"
    say "installed $BIN_DST and $UNIT_DST"
fi
say "next, by hand: systemctl --user daemon-reload && systemctl --user enable --now screentimed"
