#!/usr/bin/env bash
# proton_cli_try.sh -- the USER runs this once, in a terminal, to record what the real `proton-drive` CLI does where its --help is silent.
#
#   tools/dev/proton_cli_try.sh
#
# It works only inside ONE new folder, /my-files/lares-cli-try-<date>, with small random files (one of 60 MB for the interrupted upload), and
# removes that folder at the end by trash + delete of that folder only (never `empty-trash`). Each step prints one line here; everything the
# CLI said goes to a file under ~/.local/state/lares/snapshots/proton-try/, with e-mail addresses blanked and the trash listing cut to the
# names made here (the trash holds other things of yours). Send that file back: lares-offsite's guesses (its ASSUMPTION functions) are
# fixed from it.
set -u
if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "proton_cli_try.sh: run it in a terminal; it refuses without one" >&2
    exit 2
fi
command -v proton-drive >/dev/null || { echo "proton_cli_try.sh: proton-drive is not installed" >&2; exit 2; }
command -v python3 >/dev/null || { echo "proton_cli_try.sh: python3 is needed" >&2; exit 2; }

stamp=$(date +%Y-%m-%d-%H%M%S)
folder="lares-cli-try-$stamp"
remote="/my-files/$folder"
outdir="$HOME/.local/state/lares/snapshots/proton-try"
record="$outdir/try-$stamp.txt"
work=$(mktemp -d "${TMPDIR:-/tmp}/lares-cli-try.XXXXXX")
mkdir -p "$outdir"
trap 'rm -rf "$work"' EXIT

echo "This tries the proton-drive CLI in ONE new folder of your Drive, $remote, and removes it again."
echo "The record goes to $record"
read -r -p "Go on? [y/N] " yn
[ "$yn" = y ] || [ "$yn" = Y ] || { echo "Nothing done."; exit 0; }

: > "$record"
n=0
# Everything printed to the record is cleaned: e-mail addresses out; and a listing of /trash keeps only entries made here.
clean() {
    python3 -I -c '
import json, re, sys
text = sys.stdin.read()
mark = sys.argv[1]
if sys.argv[2] == "trash":
    try:
        data = json.loads(text)
        if isinstance(data, dict):
            data = next((v for v in data.values() if isinstance(v, list)), [])
        text = json.dumps([e for e in data if mark in json.dumps(e)], indent=1)
    except ValueError:
        text = "".join(l for l in text.splitlines(True) if mark in l)
sys.stdout.write(re.sub(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", "<email>", text))
' "lares-try" "$1"
}
# step <label> [--trash] -- <command...>: runs it, records the command, its exit status, stdout and stderr, prints one line.
step() {
    local label=$1 kind=other
    shift
    if [ "$1" = --trash ]; then kind=trash; shift; fi
    shift   # the --
    n=$((n + 1))
    local out="$work/out" err="$work/err" rc
    "$@" >"$out" 2>"$err"
    rc=$?
    {
        echo "=== step $n: $label"
        echo "command: $*" | clean other
        echo "exit: $rc"
        echo "--- stdout"
        clean "$kind" <"$out"
        echo
        echo "--- stderr"
        clean "$kind" <"$err"
        echo
    } >>"$record"
    printf '%2d  %-52s exit %d\n' "$n" "$label" "$rc"
    return $rc
}

mkdir -p "$work/src/nested/deeper" "$work/dl"
head -c 20000 /dev/urandom >"$work/src/lares-try-a.bin"
head -c 30000 /dev/urandom >"$work/src/lares-try-b.bin"
head -c 15000 /dev/urandom >"$work/src/nested/lares-try-c.bin"
head -c 10000 /dev/urandom >"$work/src/nested/deeper/lares-try-d.bin"
head -c 62914560 /dev/urandom >"$work/lares-try-big.bin"
P=proton-drive

step "create the test folder" -- $P fs create-folder /my-files "$folder"
step "upload two files" -- $P fs upload -f skip -d skip -t "$work/src/lares-try-a.bin" "$work/src/lares-try-b.bin" "$remote"
step "upload the same two again (skipped?)" -- $P fs upload -f skip -d skip -t "$work/src/lares-try-a.bin" "$work/src/lares-try-b.bin" "$remote"
step "upload a nested folder, -d merge" -- $P fs upload -f skip -d merge -t "$work/src/nested" "$remote"
step "list as JSON" -- $P fs list -j "$remote"
step "list the nested folder as JSON" -- $P fs list -j "$remote/nested"
step "info as JSON" -- $P fs info -j "$remote/lares-try-a.bin"
step "size as JSON" -- $P fs size -j "$remote"

# An upload cut off half way: a 60 MB file, TERM after a few seconds (LARES_TRY_KILL_AFTER, default 4).
n=$((n + 1))
$P fs upload -f skip -d skip -t "$work/lares-try-big.bin" "$remote" >"$work/out" 2>"$work/err" &
pid=$!
sleep "${LARES_TRY_KILL_AFTER:-4}"
if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid"; wait "$pid"; rc=$?; cut="killed after ${LARES_TRY_KILL_AFTER:-4} s"
else
    wait "$pid"; rc=$?; cut="had finished before the kill (try LARES_TRY_KILL_AFTER=1)"
fi
{ echo "=== step $n: upload cut off"; echo "exit: $rc ($cut)"; echo "--- stdout"; clean other <"$work/out"; echo; echo "--- stderr"; clean other <"$work/err"; echo; } >>"$record"
printf '%2d  %-52s exit %d (%s)\n' "$n" "upload cut off" "$rc" "$cut"
step "list after the cut (is a part there?)" -- $P fs list -j "$remote"
step "upload the big file again, -f skip" -- $P fs upload -f skip -d skip -t "$work/lares-try-big.bin" "$remote"
step "list after the retry with skip" -- $P fs list -j "$remote"
step "upload the big file again, -f replace" -- $P fs upload -f replace -d skip -t "$work/lares-try-big.bin" "$remote"
step "list after the retry with replace" -- $P fs list -j "$remote"
step "look at /trash after a replace (old copy there?)" --trash -- $P fs list -j /trash

step "trash one file" -- $P fs trash "$remote/lares-try-b.bin"
step "list /trash (only names made here)" --trash -- $P fs list -j /trash
step "delete it as /trash/<name>" -- $P fs delete /trash/lares-try-b.bin
step "list /trash again" --trash -- $P fs list -j /trash

step "download everything" -- $P fs download -f skip -d merge "$remote" "$work/dl"
{
    echo "=== compare: SHA-256 of what was uploaded and what came back"
    for f in src/lares-try-a.bin lares-try-big.bin src/nested/lares-try-c.bin src/nested/deeper/lares-try-d.bin; do
        up=$(sha256sum <"$work/$f" | cut -c1-64)
        down=$(find "$work/dl" -name "$(basename "$f")" -exec sha256sum {} \; 2>/dev/null | head -1 | cut -c1-64)
        if [ -n "$down" ] && [ "$up" = "$down" ]; then echo "same: $(basename "$f")"; else echo "DIFFERENT or missing: $(basename "$f")"; fi
    done
    echo "layout of the download:"
    (cd "$work/dl" && find . | sort)
} >>"$record"
printf '    %-52s see the record\n' "compare the downloaded files"

# Remove the test folder: that folder only, by trash + delete.
step "trash the test folder" -- $P fs trash "$remote"
step "delete the test folder from the trash" -- $P fs delete "/trash/$folder"
step "is the test folder gone?" -- $P fs info -j "$remote"

echo
echo "Done. Send back: $record"
echo "If a step above failed, the folder $remote may still be in your Drive or its trash: remove it by hand."
