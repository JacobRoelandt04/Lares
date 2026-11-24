#!/usr/bin/env bash
# side_swipe_env_probe.sh -- what a real compositor hands a layer window from a mouse's wheel and from a touchpad's fingers, read by WheelArea, and a
# side-button swipe with its hidden pointer kept in place by Hyprland (SideSwipe, HeldPointer.js): tools/dev/qml/side_swipe_env.qml in a nested
# Hyprland (tools/dev/lock_env.sh), its pointer driven (`notch`, `finger`, `lift`, `side`, `rel`).
#
#   tools/dev/side_swipe_env_probe.sh              SIDESWIPE_ENV RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=<name> tools/dev/side_swipe_env_probe.sh   passes when the check it aims at FAILS (ARM=all: every one):
#     pixels      a pixel delta means fingers, as before Qt 6.12          -> "a notch is a wheel's"
#     nohome      the pointer is never put back                           -> "back at its start"
#     countjump   the jump home is counted as the hand's                  -> "counted once"
#     coverblind  the cursor cover does not hear of the swipe             -> "the client hides the pointer"
#     noanchor    the pointer is kept at the press whatever the edge      -> "up from 12 px under the screen's edge"
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
if [ "${ARM:-}" = all ]; then
    rc=0
    for a in pixels nohome countjump coverblind noanchor; do o=$(ARM=$a "$0" | tail -1); echo "$o"; case "$o" in *"failed as it must") ;; *) rc=1 ;; esac; done
    [ $rc = 0 ] && echo "SIDESWIPE_ENV ARMS PASS" || echo "SIDESWIPE_ENV ARMS FAIL"; exit $rc
fi
mkdir -p "${SCRATCH:-/tmp}"
D="$(mktemp -d "${SCRATCH:-/tmp}/sse.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
F="" A="" B="" NEEDLE=""
case "${ARM:-}" in
    "") ;;
    pixels)     F=modules/common/scroll/WheelHub.qml; A='            : pd.x !== 0 || pd.y !== 0 ? !hub._continuous(ad.x, pd.x) && !hub._continuous(ad.y, pd.y) && (ad.x !== 0 || ad.y !== 0)'; B='            : pd.x !== 0 || pd.y !== 0 ? false'; NEEDLE="a notch is a wheel's" ;;
    nohome)     F=tools/dev/qml/side_swipe_env.qml; A='                Hyprland.dispatch(Held.expr(what, dx, dy));'; B='                ;'; NEEDLE="back at its start" ;;
    countjump)  F=modules/common/scroll/SideSwipe.qml; A='if (ss._homeDue && Math.hypot('; B='if (false && Math.hypot('; NEEDLE="counted once" ;;
    coverblind) F=tools/dev/qml/side_swipe_env.qml; A='            hidden: side.hiding'; B='            hidden: false'; NEEDLE="the client hides the pointer" ;;
    noanchor)   F=modules/common/scroll/SideSwipe.qml; A='        ss._anchor = near ? '; B='        ss._anchor = false ? '; NEEDLE="up from 12 px under the screen's edge" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-side-swipe-env}"
export LOCK_ENV="${LOCK_ENV:-sideswipe}"
OUTPUTS=1 tools/dev/lock_env.sh up > "$D/up.log" 2>&1 || { cat "$D/up.log"; echo "SIDESWIPE_ENV RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
printf '%s' "$A" > "$D/a"; printf '%s' "$B" > "$D/b"
LL="$D/live.log"; : > "$LL"
cat > "$D/live.sh" <<LIVE_EOF
if [ -n "${ARM:-}" ]; then
python3 - <<'PY' || exit 3
a, b = open("$D/a").read(), open("$D/b").read()
s = open("$F").read()
if s.count(a) != 1:
    print("ARMLOST"); raise SystemExit(1)
open("$F", "w").write(s.replace(a, b))
PY
fi
tools/dev/lock_env.sh run env WAYLAND_DEBUG=client quickshell -p tools/dev/qml/side_swipe_env.qml >> $LL 2>&1 &
QP=\$!
pt() { tools/dev/lock_env.sh point "\$@"; }
pos() { tools/dev/lock_env.sh hyprctl cursorpos | tr -d ' '; }
waitfor() { for i in \$(seq 1 \$2); do grep -aq "\$1" $LL && return 0; sleep 0.1; done; return 1; }
mark() { echo "SSE mark \$1" >> $LL; }
waitfor "SSE ready" 300 || { kill \$QP; exit 0; }
pt "abs 340 390 2880 1620" "sleep 100" "abs 350 400 2880 1620" "sleep 300"
sleep 0.6
mark notch; pt "notch 1" "sleep 120" "notch 1" "sleep 120" "notch -1" "sleep 200"; sleep 0.8
mark finger; pt "finger 3 -20" "sleep 20" "finger 0 -14" "sleep 20" "finger 2 -7" "sleep 20" "lift" "sleep 200"; sleep 0.8
mark drag; pos > $D/pos.start
pt "side back down" "sleep 60"
for i in \$(seq 1 40); do pt "rel -10 0" "sleep 20"; done
sleep 0.5
pos > $D/pos.during
pt "side back up" "sleep 100"
sleep 0.8
pos > $D/pos.end
mark click; pt "side fwd down" "sleep 60" "side fwd up" "sleep 200"; sleep 0.6
mark turn; pt "side back down" "sleep 60" "notch 1" "sleep 60" "notch 1" "sleep 60" "side back up" "sleep 200"; sleep 0.6
mark edge; pt "abs 340 18 2880 1620" "sleep 100" "abs 350 12 2880 1620" "sleep 300"; sleep 0.6; pos > $D/pos.estart
pt "side back down" "sleep 60"
for i in \$(seq 1 40); do pt "rel 0 -10" "sleep 20"; done
sleep 0.3
pt "side back up" "sleep 100"
sleep 0.8
pos > $D/pos.eend
mark end
kill \$QP; wait \$QP 2> /dev/null; true
LIVE_EOF
tools/dev/sandbox.sh bash "$D/live.sh" > "$D/live.run" 2>&1
tools/dev/lock_env.sh down > /dev/null 2>&1
if grep -q ARMLOST "$D/live.run"; then echo "ARM $ARM: its anchor matched nothing -- it proves nothing"; exit 1; fi
cat > "$D/judge.py" <<'PY'
import re, sys
d = sys.argv[1]
txt = re.sub(r"\x1b\[[0-9;]*m", "", open(d + "/live.log", errors="replace").read())
n = [0, 0]
def say(ok, name, detail=""):
    n[1] += 1; n[0] += 1 if ok else 0
    print("SSE %s %s%s" % ("ok  " if ok else "FAIL", name, "" if ok else "  [%s]" % (detail,)))
def part(a, b):
    i = txt.find("SSE mark " + a); j = txt.find("SSE mark " + b)
    return txt[i:j] if i >= 0 and j > i else ""
def evs(t):
    out = []
    for m in re.finditer(r"SSE ev (\w+) ax=(-?[\d.]+) ay=(-?[\d.]+) px=(-?[\d.]+) py=(-?[\d.]+) phase=(\d+) steps=(-?\d+) click=(\w+)", t):
        out.append(dict(dev=m[1], ax=float(m[2]), ay=float(m[3]), px=float(m[4]), py=float(m[5]), phase=int(m[6]), steps=int(m[7]), click=m[8] == "true"))
    return out
def pos(f):
    try:
        x, y = open(d + "/" + f).read().strip().split(",")
        return int(x), int(y)
    except Exception:
        return None
e = evs(part("notch", "finger"))
say(len(e) == 3 and all(v["dev"] == "wheel" and v["py"] == 0 for v in e), "a notch is a wheel's, its pixels nothing", e)
say([v["steps"] for v in e] == [1, 1, -1], "down is the next, up the previous", [v["steps"] for v in e])
e = evs(part("finger", "drag"))
up = [v for v in e if v["phase"] == 2]
say(len(e) > 4 and all(v["dev"] == "touch" for v in e) and abs(sum(v["py"] for v in up) - 41) <= 1, "fingers are fingers, pixel for pixel", e)
say(e and e[0]["phase"] == 1 and e[-1]["phase"] == 3, "they begin and they lift", [v["phase"] for v in e])
say(all(v["px"] != 0 or v["py"] != 0 for v in up), "no update says nothing (a zero is the fingers put down or lifted)", up)
t = part("drag", "click")
e = evs(t)
way = sum(v["px"] for v in e)
say(len(e) > 10 and all(v["dev"] == "swipe" for v in e) and abs(way + 400) <= 12, "the hand's 400 px are counted once (%d)" % way, way)
say(e and e[0]["phase"] == 1 and e[-1]["phase"] == 3, "begun and lifted", [v["phase"] for v in e][-3:] if e else "")
s, m, x = pos("pos.start"), pos("pos.during"), pos("pos.end")
say(s and m and abs(m[0] - s[0]) < 260, "the pointer was kept by its start during it", (s, m))
say(s and x and abs(x[0] - s[0]) <= 1 and abs(x[1] - s[1]) <= 1, "let go, it is back at its start", (s, x))
h = t.find("SSE hiding true"); g = t.find("SSE hiding false")
nil = [i for i in (mm.start() for mm in re.finditer(r"wl_pointer#\d+\.set_cursor\(\d+, nil", t))]
say(h >= 0 and any(h - 200 < i < g for i in nil), "the client hides the pointer while it swipes", (h, g, nil[:3]))
shape = [mm.start() for mm in re.finditer(r"set_shape\(\d+, 1\)", t)]
say(any(i > g - 400 for i in shape), "and shows the arrow again after", (g, shape[-2:]))
e = evs(part("click", "turn"))
say(len(e) == 1 and e[0]["dev"] == "wheel" and e[0]["steps"] == 1 and e[0]["click"], "a click of the forward button is one step on", e)
e = evs(part("edge", "end"))
way = sum(v["py"] for v in e)
say(abs(way + 400) <= 16, "up from 12 px under the screen's edge: the hand's 400 px all the same (%d)" % way, way)
s, x = pos("pos.estart"), pos("pos.eend")
say(s and x and abs(x[0] - s[0]) <= 1 and abs(x[1] - s[1]) <= 1, "and back at its start under the edge", (s, x))
e = evs(part("turn", "edge"))
say(len(e) == 2 and all(v["steps"] == 1 and v["ax"] == -120 and v["ay"] == 0 and not v["click"] for v in e), "held + the wheel: one step sideways a notch, and no click", e)
warn = [l for l in txt.splitlines() if re.search(r"TypeError|ReferenceError|Binding loop|syntax error|WARN.*dispatch", l)]
say(not warn, "no warnings", warn[:2])
print("SSE RESULT %s (%d/%d checks)" % ("PASS" if n[0] == n[1] else "FAIL", n[0], n[1]))
PY
if ! grep -aq 'SSE ready' "$LL"; then KEEP=1; [ -n "${ARM:-}" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing"; rl_noresult SIDESWIPE_ENV "$LL"; exit 1; fi
python3 "$D/judge.py" "$D" > "$D/verdict" 2>&1
cat "$D/verdict" | grep -v 'SSE RESULT'
if [ -n "${ARM:-}" ]; then
    if grep 'SSE FAIL' "$D/verdict" | grep -q -F -- "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
r=$(grep -a 'SSE RESULT' "$D/verdict" | tail -1)
echo "${r/SSE RESULT/SIDESWIPE_ENV RESULT}"
case "$r" in *PASS*) exit 0 ;; *) exit 1 ;; esac
