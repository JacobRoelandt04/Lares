#!/usr/bin/env bash
# Edit a screenshot in swappy, and let swappy's Save write OVER that screenshot.
#
#   tools/notifications/shot_edit.sh <file.png>
#
# The one helper behind every "Edit" of a screenshot: the OSD's capture card (a click on it), the notification
# manager's Edit button (ScreenshotNotifier). Left to itself swappy's Save button does not override the existing
# screenshot: it makes a new one stored in the desktop folder, with different naming (swappy instead of the shot
# prefix, an underscore between two numbers instead of a dash).
#
# WHY A CONFIG. `swappy -f <file>` has no output option for its Save button (`-o` is for what it prints on exit):
# Save writes to the config's save_dir under save_filename_format (a strftime pattern), by default
# ~/Desktop/swappy-%Y%m%d-%H%M%S.png. swappy reads $XDG_CONFIG_HOME/swappy/config, so this runs it with a config
# of its own whose save_dir is the shot's directory and whose format is the shot's own name -- Save then
# overwrites that very file. Nothing is written to the user's ~/.config/swappy: the config is a temporary
# XDG_CONFIG_HOME for this one process, made of the user's own entries linked in (a GTK program finds its theme,
# fonts and settings there) except `swappy`, whose config is the user's (their line size, font, mode ...) with
# those two keys replaced. A `%` in the file's name is doubled for strftime.
#
# THE DELETE BUTTON. swappy's trash-can button is "Clear Paints", not "delete the file" as its icon suggests.
# swappy has no hook for it, so swappy -- and only swappy -- is started with tools/notifications/swappy_trash.c preloaded:
# the button then runs shot_trash.sh on THIS shot (Trash, then the shell is told) and the window stays open, so Save
# writes the shot back to the same path. The shim is built on first use into the user's cache (a few hundred ms, named by
# the hash of its source) and, when it cannot be built (no cc or no GTK headers), swappy runs plain.
#
# The shot is edited in place: keep a copy first if the original matters (swappy has no undo past its own window).
set -u
file="${1:-}"
[ -n "$file" ] || { echo "usage: $0 <file.png>" >&2; exit 2; }
[ -f "$file" ] || { echo "shot_edit: no such file: $file" >&2; exit 1; }
file=$(realpath -- "$file") || exit 1
dir=$(dirname -- "$file")
base=$(basename -- "$file")
fmt=${base//%/%%}

real="${XDG_CONFIG_HOME:-$HOME/.config}"
tmp=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/lares-swappy.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

shopt -s nullglob dotglob
for e in "$real"/*; do
    n=${e##*/}
    [ "$n" = swappy ] && continue
    ln -s -- "$e" "$tmp/$n"
done
mkdir "$tmp/swappy"
{
    if [ -r "$real/swappy/config" ]; then
        awk -v dir="$dir" -v fmt="$fmt" '
            /^[[:space:]]*(save_dir|save_filename_format)[[:space:]]*=/ { next }
            { print }
            /^\[Default\][[:space:]]*$/ { print "save_dir=" dir; print "save_filename_format=" fmt; seen = 1 }
            END { if (!seen) { print "[Default]"; print "save_dir=" dir; print "save_filename_format=" fmt } }
        ' "$real/swappy/config"
    else
        printf '[Default]\nsave_dir=%s\nsave_filename_format=%s\n' "$dir" "$fmt"
    fi
} > "$tmp/swappy/config"

here=$(dirname -- "$(realpath -- "$0")")
shim=""
src="$here/swappy_trash.c"
if [ -r "$src" ] && command -v cc > /dev/null 2>&1 && command -v pkg-config > /dev/null 2>&1; then
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/lares"
    sum=$(sha256sum -- "$src" | cut -c1-12)
    shim="$cache/swappy-trash-$sum.so"
    if [ ! -f "$shim" ]; then
        mkdir -p -- "$cache" || shim=""
        if [ -n "$shim" ]; then
            part="$shim.$$"
            if cc -shared -fPIC -O1 -o "$part" "$src" $(pkg-config --cflags gtk+-3.0) -ldl 2> "$tmp/cc.log"; then
                mv -f -- "$part" "$shim"
            else
                echo "shot_edit: swappy_trash.so not built, the delete button stays swappy's own: $(head -n 3 "$tmp/cc.log" | tr '\n' ' ')" >&2
                rm -f -- "$part"
                shim=""
            fi
        fi
    fi
fi

if [ -n "$shim" ]; then
    LARES_SHOT_FILE="$file" LARES_SHOT_TRASH="$here/shot_trash.sh" LD_PRELOAD="$shim${LD_PRELOAD:+:$LD_PRELOAD}" \
        XDG_CONFIG_HOME="$tmp" swappy -f "$file"
else
    XDG_CONFIG_HOME="$tmp" swappy -f "$file"
fi
