#!/usr/bin/env bash
# themectl_evince_env_probe.sh -- themectl's `evince` target against the REAL evince (48) in the nested Hyprland of lock_env.sh.
#
#   tools/dev/themectl_evince_env_probe.sh       ends in THEMECTL_EVINCE RESULT PASS|FAIL
#   ARM=nodocs    the per-document pass does nothing (a copy): E3 / E7 must FAIL (the document opened before keeps its copy)
#   ARM=nowindows the window pass does nothing (a copy): E4 / E5 must FAIL (the open window stays as it was)
#   ARM=inline    the work done inside the run again (before 2026-11-12): E8 must FAIL (the curtain waits for it)
#   ARM=all       all three in turn: THEMECTL_EVINCE ARMS RESULT PASS | FAIL
#   THEVINCE_KEEP=1 keeps the nested env up at the end
#
# WHY (2026-11-12, feedback/themectl.md "Evince support"). Evince keeps "inverted colours" in three places: the gsettings default,
# a COPY of it in each document's GVfs metadata made at the document's first open (which wins ever after: the user's "when I open a
# pdf document again that was inverted, it is still inverted"), and the state of an open window. A stub proves only the request;
# this is evince itself (CLAUDE.md: A TARGET'S ok COUNTS ONLY IF THE REAL PROGRAM REACTS).
#
# THE SCENE. lock_env (private runtime, bus, XDG homes), a private gvfsd-metadata on its bus (evince's per-document store), the
# keyfile gsettings backend (no dconf service there). Document A is opened and closed (its copy says "0"), document B stays open.
#   E1 A's first open wrote its copy "0"; B's window is up and not inverted (and A's is gone: one window)
#   E2 themectl set eva dark --only evince: the target says ok
#   E3 A's copy now "1" (a document opened before inverts at its next open)
#   E4 B's window action state true, E5 its page drawn dark (mean of the page area in a grim shot)
#   E6 the default is true (a document never opened inverts at its first open)
#   E7 themectl set eva light: A "0", B's window false and its page light again, the default false
#   E8 the target costs the switch next to nothing: its own line in last-run.tsv under 60 ms (the work runs in the background,
#      `themectl _evince`, and the shell's curtain waits for themectl to exit)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAME=THEMECTL_EVINCE
E="$ROOT/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-thevince}"

if [ "${ARM:-}" = all ]; then
    rc=0
    for a in nodocs nowindows inline; do
        out=$(ARM="$a" THEVINCE_KEEP= bash "$0" 2>&1)
        case "$a" in nodocs) need="^THE FAIL E3 " ;; nowindows) need="^THE FAIL E4 " ;; inline) need="^THE FAIL E8 " ;; esac
        if printf '%s\n' "$out" | grep -aq "its anchor is gone"; then
            echo "ARM $a: NOT PROVEN (its anchor is gone)"; rc=1
        elif printf '%s\n' "$out" | grep -aq "^$NAME RESULT FAIL" && printf '%s\n' "$out" | grep -aqE "$need"; then
            echo "ARM $a: FAILED AS IT MUST ($(printf '%s\n' "$out" | grep -aE "$need" | head -1 | cut -c10-140))"
        elif printf '%s\n' "$out" | grep -aq "^$NAME RESULT FAIL"; then
            echo "ARM $a: FAILED, BUT NOT ON ITS CHECK: $(printf '%s\n' "$out" | grep -a 'FAIL' | head -1 | cut -c1-150)"; rc=1
        else
            echo "ARM $a: STAYED GREEN"; rc=1
        fi
    done
    [ "$rc" = 0 ] && echo "$NAME ARMS RESULT PASS" || echo "$NAME ARMS RESULT FAIL"
    exit "$rc"
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/thevince.XXXXXX")"
cleanup() { [ -n "${THEVINCE_KEEP:-}" ] || { "$E" down > /dev/null 2>&1; rm -rf "$W"; }; }
trap cleanup EXIT
fail=0
say() { echo "THE $*"; }
check() { if [ "$2" = 1 ]; then say "ok   $1"; else say "FAIL $1 ($3)"; fail=1; fi; }

# the themectl to run: today's, or an armed copy of a minimal tree (themectl finds its repo two levels up)
T="$ROOT"
if [ -n "${ARM:-}" ]; then
    T="$W/tree"
    mkdir -p "$T/tools" "$T/modules/common"
    cp -r "$ROOT/tools/theme" "$ROOT/tools/lib" "$T/tools/"
    cp -r "$ROOT/themes" "$T/"
    cp -r "$ROOT/modules/common/theme" "$T/modules/common/"
    case "$ARM" in
        nodocs)    a='    docs, held = _evince_doc_pass(P, "1" if want else "0", dry)'; b='    docs, held = 0, 0' ;;
        nowindows) a='    wins, nwin = _evince_window_pass(want, dry)'; b='    wins, nwin = 0, 0' ;;
        inline)    a='    if ctx.dry:
        did, lines, held, nwin = _evince_apply(spec, want, ctx.P, True, ctx.timeout)'; b='    if True:
        did, lines, held, nwin = _evince_apply(spec, want, ctx.P, ctx.dry, ctx.timeout)' ;;
        *) echo "$NAME RESULT FAIL (unknown ARM $ARM)"; exit 1 ;;
    esac
    python3 - "$T/tools/theme/themectl" "$a" "$b" <<'PY' || { echo "$NAME RESULT FAIL (ARM $ARM: its anchor is gone)"; exit 1; }
import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
if s.count(a) != 1:
    raise SystemExit(1)
open(p, "w").write(s.replace(a, b))
PY
fi
TC="$T/tools/theme/themectl"

# two one-page documents: a white page with a black band (evince draws it inverted as a black page with a white band)
python3 - "$W" <<'PY' || { echo "$NAME RESULT FAIL (PIL)"; exit 1; }
import sys
from PIL import Image, ImageDraw
for n in ("a", "b"):
    im = Image.new("RGB", (595, 842), (255, 255, 255))
    ImageDraw.Draw(im).rectangle((60, 380, 535, 460), fill=(0, 0, 0))
    im.save("%s/%s.pdf" % (sys.argv[1], n), "PDF", resolution=72)
PY

MODE=light timeout 180 "$E" up > "$W/up.log" 2>&1 || { cat "$W/up.log"; echo "$NAME RESULT FAIL (the nested env did not come up)"; exit 1; }
B="$(sed -n 's/^LOCK_ENV UP [^ ]* dir=\([^ ]*\) .*/\1/p' "$W/up.log" | tail -1)"
[ -d "$B/cfg" ] || { echo "$NAME RESULT FAIL (no env dir)"; exit 1; }
# evince keeps NO metadata for a file under its temp dir (TMPDIR, else /tmp: the documents here), so its TMPDIR is elsewhere
mkdir -p "$B/evtmp"
run() { "$E" run env GSETTINGS_BACKEND=keyfile NO_AT_BRIDGE=1 "$@"; }
# GIO uses the GVfs client (and with it the metadata store) only while the main gvfsd answers on the bus
"$E" run /usr/lib/gvfsd --no-fuse > "$W/gvfsd.log" 2>&1 &
"$E" run /usr/lib/gvfsd-metadata > "$W/gvfsd-metadata.log" 2>&1 &
"$E" run /usr/lib/evinced > "$W/evinced.log" 2>&1 &             # evince registers its documents with it, as on the desktop
owned() { "$E" run gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
            --method org.freedesktop.DBus.NameHasOwner "$1" 2>/dev/null | grep -c true; }
for _ in $(seq 1 40); do [ "$(owned org.gtk.vfs.Daemon)" = 1 ] && [ "$(owned org.gtk.vfs.Metadata)" = 1 ] && break; sleep 0.25; done
[ "$(owned org.gtk.vfs.Metadata)" = 1 ] || { echo "$NAME RESULT FAIL (gvfsd / gvfsd-metadata did not come up on the env's bus)"; exit 1; }

meta() { run gio info -a metadata::evince::inverted-colors "$1" 2>/dev/null | sed -n 's/^ *metadata::evince::inverted-colors: //p'; }
# B's window: the state of its inverted-colors action ("true" / "false"; "" when no evince window answers)
cat > "$W/win.py" <<'PY'
import sys, gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
names = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames", None, GLib.VariantType("(as)"), 0, 2000, None).unpack()[0]
for n in names:
    if not n.startswith(":"):
        continue
    try:
        d = bus.call_sync(n, "/org/gnome/Evince/window/1", "org.gtk.Actions", "Describe", GLib.Variant("(s)", ("inverted-colors",)),
                          GLib.VariantType("((bgav))"), 0, 1000, None).unpack()[0]
        print("true" if d[2][0] else "false")
        sys.exit(0)
    except Exception:
        pass
PY
winstate() { run python3 -I "$W/win.py" 2>/dev/null | tail -1; }
# the mean brightness of the middle of LOCK-1 (where the page is drawn)
page() {
    "$E" shot "$W/shot.png" LOCK-1 > /dev/null 2>&1 || { echo "-1"; return; }
    python3 - "$W/shot.png" <<'PY'
import sys
from PIL import Image, ImageStat
im = Image.open(sys.argv[1]).convert("L")
w, h = im.size
print(round(ImageStat.Stat(im.crop((int(w * 0.35), int(h * 0.3), int(w * 0.65), int(h * 0.42)))).mean[0]))
PY
}
waitfor() {  # tries cmd want
    local i v=""
    for i in $(seq 1 "$1"); do v=$($2); [ "$v" = "$3" ] && break; sleep 0.25; done
    printf '%s' "$v"
}

# A: opened once, then closed (its first open writes the copy)
"$E" run env GSETTINGS_BACKEND=keyfile NO_AT_BRIDGE=1 TMPDIR="$B/evtmp" evince "$W/a.pdf" > "$W/evince-a.log" 2>&1 &   # lock_env execs: $! is evince
EA=$!
A0=$(waitfor 80 "meta $W/a.pdf" 0)
# GTK's recent list names A with evince as its application (evince writes it itself, a moment after the load); then A closes the way
# a user closes it (its window's own `close` action), not by a signal
for _ in $(seq 1 40); do grep -q "a.pdf" "$B/data/recently-used.xbel" 2> /dev/null && break; sleep 0.25; done
grep -q "a.pdf" "$B/data/recently-used.xbel" 2> /dev/null || say "note: evince wrote no recent entry for A"
cat > "$W/close.py" <<'CLOSE'
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
for n in bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames", None, GLib.VariantType("(as)"), 0, 2000, None).unpack()[0]:
    if n.startswith(":"):
        try:
            bus.call_sync(n, "/org/gnome/Evince/window/1", "org.gtk.Actions", "Activate", GLib.Variant("(sava{sv})", ("close", [], {})), None, 0, 1000, None)
        except Exception:
            pass
CLOSE
run python3 -I "$W/close.py" 2> /dev/null
for _ in $(seq 1 40); do kill -0 "$EA" 2> /dev/null || break; sleep 0.25; done
kill "$EA" 2> /dev/null; wait "$EA" 2> /dev/null
# B: stays open
"$E" run env GSETTINGS_BACKEND=keyfile NO_AT_BRIDGE=1 TMPDIR="$B/evtmp" evince "$W/b.pdf" > "$W/evince-b.log" 2>&1 &
W0=$(waitfor 80 winstate false)
sleep 1
P0=$(page)
check "E1 A's first open wrote its copy 0; B's window is up, not inverted" "$([ "$A0" = 0 ] && [ "$W0" = false ] && echo 1)" "A=$A0 window=$W0"

out=$(run python3 "$TC" set eva dark --only evince 2>&1 | grep -a '^\(ok\|FAIL\|skip\) *evince' | tail -1)
check "E2 set eva dark: the target says ok" "$(case "$out" in ok*) echo 1 ;; esac)" "$out"
A1=$(waitfor 40 "meta $W/a.pdf" 1)
check "E3 the document opened before now holds 1" "$([ "$A1" = 1 ] && echo 1)" "A=$A1; $out"
W1=$(waitfor 20 winstate true)
check "E4 the open window's inverted-colors is true" "$([ "$W1" = true ] && echo 1)" "window=$W1; $out"
sleep 1
P1=$(page)
check "E5 its page is drawn dark (mean $P0 -> $P1)" "$([ "$P0" -gt 0 ] 2>/dev/null && [ "$P1" -ge 0 ] && [ $((P1 * 2)) -lt "$P0" ] && echo 1)" "mean $P0 -> $P1"
D1=$(waitfor 40 "run gsettings get org.gnome.Evince.Default inverted-colors" true)
check "E6 the default is true" "$([ "$D1" = true ] && echo 1)" "$D1"

out=$(run python3 "$TC" set eva light --only evince 2>&1 | grep -a '^\(ok\|FAIL\|skip\) *evince' | tail -1)
A2=$(waitfor 40 "meta $W/a.pdf" 0); W2=$(waitfor 20 winstate false); sleep 1; P2=$(page); D2=$(waitfor 40 "run gsettings get org.gnome.Evince.Default inverted-colors" false)
check "E7 set eva light puts all three back (A 0, window false and light again, default false)" \
      "$(case "$out" in ok*) [ "$A2" = 0 ] && [ "$W2" = false ] && [ "$D2" = false ] && [ $((P2 * 2)) -gt "$P0" ] && echo 1 ;; esac)" \
      "$out; A=$A2 window=$W2 default=$D2 mean $P2"

T8=$(awk -F'\t' '$1 == "evince" {print $2}' "$B/state/theme/last-run.tsv" 2> /dev/null)
check "E8 the evince target costs the switch ${T8:-?} ms (last-run.tsv; under 60)" "$([ -n "$T8" ] && [ "$T8" -lt 60 ] && echo 1)" "last-run: $(tr '\n' ' ' < "$B/state/theme/last-run.tsv" 2>/dev/null | cut -c1-200); worker: $(cat "$B/state/theme/evince-last" 2>/dev/null)"
if [ "$fail" = 0 ]; then echo "$NAME RESULT PASS (8 checks)"; exit 0; fi
echo "$NAME RESULT FAIL"; exit 1
