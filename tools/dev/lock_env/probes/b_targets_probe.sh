#!/usr/bin/env bash
# b_targets_probe.sh -- LockOwner's `targets` message on TWO outputs, against grabs.
#
#   tools/dev/lock_env/probes/b_targets_probe.sh        ends in B_TARGETS RESULT PASS|FAIL
#
# An isolated Hyprland with two outputs (tools/dev/lock_env.sh, LOCK_ENV r2b_tg: no lock
# is ever started -- nothing here instantiates a session lock), the stand-in shell
# (tools/dev/qml/lock_shell.qml, a COPY of the tree) and the fake lock (b_fake_lock.py) as
# the lock's end of the wire. The last `targets` of each screen is checked against
# a grab of that output: the carved field's first ink column/row lies within 3 px
# of the rect's left/right/top/bottom (the bevel is outside the rect). FAULT=shift moves every reported rect 20 px
# right (the check must FAIL).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
export LOCK_ENV=r2b_tg
E="$ROOT/tools/dev/lock_env.sh"
W="${SCRATCH:-/tmp}/r2b_tg"; T="$W/tree"
rm -rf "$W"; mkdir -p "$T"
trap '"$E" down > /dev/null 2>&1' EXIT
rsync -a --exclude '.git/' "$ROOT/modules" "$ROOT/themes" "$ROOT/tools/dev/qml/lock_shell.qml" "$ROOT/.examples" "$T/" || exit 1
"$E" down > /dev/null 2>&1
OUTPUTS=2 MODE=light "$E" up > /dev/null || { echo "B_TARGETS RESULT FAIL (env up)"; exit 1; }
SOCK="$("$E" dir)/rt/lares-lock/wayland-1.sock"
( "$E" run quickshell -p "$T/lock_shell.qml" > "$W/shell.log" 2>&1 & )
sleep 4
script() { # face then grab (the fake holds the connection while the grabs are taken)
    local tag="$1" face="$2"
    python3 "$ROOT/tools/dev/lock_env/probes/b_fake_lock.py" --sock "$SOCK" \
        "state face=$face; sleep 3; wait-targets 2 8; dump-targets $W/$tag.json; sleep 5" > "$W/$tag.fake.log" 2>&1 &
    local fp=$!
    sleep 5
    "$E" shot "$W/$tag-1.png" LOCK-1 2> /dev/null
    "$E" shot "$W/$tag-2.png" LOCK-2 2> /dev/null
    wait "$fp"
    sleep 1
}
script failed failed
python3 - "$W" "${FAULT:-}" <<'PY'
import json, sys
from PIL import Image
W, fault = sys.argv[1], sys.argv[2]
bad = 0
def ink(im, xy, vertical, rect_edge, direction):
    pass
for tag in ("failed",):
    try:
        T = json.load(open("%s/%s.json" % (W, tag)))
    except Exception as e:
        print("FAIL  %s: no targets (%s)" % (tag, e)); bad += 1; continue
    for k, scr in ((1, "LOCK-1"), (2, "LOCK-2")):
        t = T.get(scr)
        if not t or not t["field"]:
            print("FAIL  %s/%s: no field rect" % (tag, scr)); bad += 1; continue
        im = Image.open("%s/%s-%d.png" % (W, tag, k)).convert("RGB")
        x, y, w, h = t["field"]
        if fault == "shift":
            x += 20
        # the popup's surface colour is sampled just above the field
        surf = im.getpixel((x + w // 2, y - 4))
        def differs(p): return max(abs(p[i] - surf[i]) for i in range(3)) > 6
        ym = y + h // 2
        # first column from the left of the rect-minus-8 that is not surface
        left = next((cx for cx in range(x - 8, x + 40) if differs(im.getpixel((cx, ym)))), None)
        right = next((cx for cx in range(x + w + 8, x + w - 40, -1) if differs(im.getpixel((cx, ym)))), None)
        xm = x + w // 3
        top = next((cy for cy in range(y - 8, y + 30) if differs(im.getpixel((xm, cy)))), None)
        bottom = next((cy for cy in range(y + h + 8, y + h - 30, -1) if differs(im.getpixel((xm, cy)))), None)
        d = [None if v is None else v - e for v, e in ((left, x), (right, x + w - 1), (top, y), (bottom, y + h - 1))]
        ok = all(v is not None and abs(v) <= 3 for v in d)
        print("%s  %s/%s field=%s edges off by L,R,T,B=%s" % ("ok  " if ok else "FAIL", tag, scr, t["field"], d))
        bad += 0 if ok else 1
print("B_TARGETS RESULT " + ("FAIL" if bad else "PASS"))
sys.exit(1 if bad else 0)
PY
