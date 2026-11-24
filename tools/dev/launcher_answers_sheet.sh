#!/usr/bin/env bash
# launcher_answers_sheet.sh -- the quick answers' rows, one per kind (and the pending / long / Copied states), at rest and highlighted, light
# and dark, at 1x and 1.25 (QT_SCALE_FACTOR). PNGs into ${OUT:-~/.cache/claude-orch/r13/answers-ui}. Offscreen, private homes, no desktop window.
#   tools/dev/launcher_answers_sheet.sh            writes answers_<light|dark>_<1|1.25>.png
#   LAS_CHILD=real ...                             the rows from the REAL child (tools/launcher/answers.py, the ECB fixture, a private
#                                                  cache): answers_real_<light|dark>_<1|1.25>.png
set -u
cd "$(dirname "$0")/../.."
export SANDBOX="${SANDBOX:-/tmp/lares-sbx-r13-answers-ui}"
OUT="${OUT:-$HOME/.cache/claude-orch/r13/answers-ui}"
mkdir -p "$OUT"
D="$(mktemp -d "${SCRATCH:-/tmp}/las.XXXXXX")"
trap 'rm -rf "$D"' EXIT
LAS_CHILD="${LAS_CHILD:-stub}"
python3 - "$D/data.json" "$LAS_CHILD" "$D" <<'PY'
import json, os, subprocess, sys
real = sys.argv[2] == "real"
stub = "tools/launcher/answers.py" if real else "tools/dev/fixtures/launcher_answers_stub.py"
qs = [("math", "2+2"), ("math, long", "12345678901234567890 * 98765432109876543210 * 3"), ("currency", "100 usd in eur"), ("base", "0xff"), ("time", "9:30 + 1h45"),
      ("unit", "5 mi in km"), ("date", "days until 2027-01-01"), ("zone", "time in tokyo"), ("colour", "#4480f4"), ("percent", "15% of 80"),
      ("ratio", "16:9 to 1080"), ("resolution", "4k")]
if real:
    qs = [("math", "sqrt(2) * pi"), ("math, long", "2^100"), ("currency", "100 usd in eur"), ("base", "255 in hex"), ("time", "3h20m + 45m"),
          ("unit", "5'11\" in cm"), ("date", "days until christmas"), ("zone", "3pm tokyo in brussels"), ("colour", "#4480f4"),
          ("percent", "80 + 21%"), ("ratio", "16:9 at 1440 wide"), ("resolution", "27in 1440p")]
env = {"STUB_DELAY_MS": "1", "PATH": "/usr/bin"}
if real:
    env = {"PATH": "/usr/bin", "XDG_CACHE_HOME": sys.argv[3] + "/childcache", "LARES_ANSWERS_TZ": "Europe/Brussels",
           "LARES_ECB_URL": "file://" + os.path.abspath("tools/dev/fixtures/launcher_ecb_daily.xml")}
inp = "".join(json.dumps({"id": i + 1, "q": q}) + "\n" for i, (_, q) in enumerate(qs))
if real:
    # The child pushes a currency answer's landed value later; the sheet closes its stdin at once, so warm the rate cache first.
    import time
    w = subprocess.Popen(["python3", stub], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
    w.stdin.write(json.dumps({"id": 1, "q": "1 usd in eur"}) + "\n"); w.stdin.flush()
    for _ in range(2):
        w.stdout.readline()
    w.stdin.close(); w.wait(timeout=10)
out = subprocess.run(["python3", stub], input=inp, capture_output=True, text=True, env=env, timeout=30).stdout
byid = {}
for l in out.splitlines():
    o = json.loads(l)
    byid[o["id"]] = o["answers"]            # a pending reply is replaced by its landed one: the last wins
data = []
for i, (label, q) in enumerate(qs):
    if byid.get(i + 1):
        data.append({"label": label, "answer": byid[i + 1][0]})
pend = dict(byid[3][0]); pend["pending"] = True; pend["detail"] = "fetching rates ..."
data.append({"label": "pending", "answer": pend})
data.append({"label": "math, Copied", "answer": byid[1][0], "copied": True})
json.dump(data, open(sys.argv[1], "w"))
PY
mkdir -p "$D/home" "$D/state" "$D/cache" "$D/data"
for mode in light dark; do
    mkdir -p "$D/cfg-$mode/theme"
    echo "{\"mode\":\"$mode\",\"theme\":\"eva\"}" > "$D/cfg-$mode/theme/state.json"
    for sc in 1 1.25; do
        tools/dev/sandbox.sh env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QML_DISABLE_DISTANCEFIELD=1 QT_SCALE_FACTOR=$sc \
            HOME="$D/home" XDG_CONFIG_HOME="$D/cfg-$mode" XDG_STATE_HOME="$D/state" XDG_CACHE_HOME="$D/cache" XDG_DATA_HOME="$D/data" \
            LAS_DATA="$D/data.json" LAS_OUT="$OUT/answers_$([ "$LAS_CHILD" = real ] && echo real_)${mode}_${sc}.png" LAS_FONT="${LAS_FONT:-Audiowide}" \
            timeout 60 quickshell -p tools/dev/qml/launcher_answers_sheet.qml 2>&1 | sed -r 's/\x1b\[[0-9;]*m//g' | grep -a "LAS \|ERROR\|WARN" | head -5
    done
done
ls -la "$OUT"
