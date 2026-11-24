#!/usr/bin/env bash
# aerial's own QR encoder, PROVED BY DECODING: tools/dev/qml/aerial_qr_probe.qml draws a corpus through the real QrView (ASCII, UTF-8 names,
# every escape of the Wi-Fi join string, every version 1-10) and OpenCV's QRCodeDetector reads each picture back (python3 -I, cv2).
# The Wi-Fi strings are ALSO built here, independently in python, and compared with what QrCode.js built (the standard's escaping).
#
#   tools/dev/aerial_qr_probe.sh                 last line: AERIAL_QR RESULT PASS|FAIL
#   ARM=nomask tools/dev/aerial_qr_probe.sh      the masking pass is skipped in the SANDBOX copy; the run must end FAIL
#   ARM=noescape ...                             the join string stops escaping ; , : " \  ; must FAIL (the string check)
#   ARM=all                                      both arms; AERIAL_QR ARMS PASS when each failed
set -u
cd "$(dirname "$0")/../.." || exit 1
NAME=AERIAL_QR
if [ "${ARM:-}" = all ] && [ -z "${AQ_INNER:-}" ]; then
    bad=0
    for a in nomask noescape; do
        res=$(ARM=$a SANDBOX="/tmp/lares-sbx-aerial-p-qr-$a" SCRATCH="${SCRATCH:-}" bash tools/dev/aerial_qr_probe.sh 2>&1)
        rm -rf "/tmp/lares-sbx-aerial-p-qr-$a"
        if printf '%s\n' "$res" | grep -q 'anchor not found exactly once'; then echo "  ARM $a: its anchor is not in the code"; bad=1
        elif printf '%s\n' "$res" | tail -1 | grep -q 'RESULT PASS'; then echo "  ARM $a: PASSED (it must fail)"; bad=1
        else echo "  ARM $a: failed as it must ($(printf '%s\n' "$res" | grep -c ' FAIL') red)"; fi
    done
    [ "$bad" = 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
    echo "$NAME ARMS FAIL"; exit 1
fi
if [ -e .git ] && [ -z "${AQ_INNER:-}" ]; then
    export SANDBOX="${SANDBOX:-/tmp/lares-sbx-aerial-p}"
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen AQ_INNER=1 ARM="${ARM:-}" SCRATCH="${SCRATCH:-}" bash tools/dev/aerial_qr_probe.sh
fi
. tools/dev/result_lib.sh
ARM="${ARM:-}"
SCR="${SCRATCH:-/tmp}"
WORK=$(mktemp -d "$SCR/aerial_qr.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
if [ -n "$ARM" ]; then
    [ -e .git ] && { echo "refusing to arm the real tree"; exit 2; }
    arm() { python3 - "$1" "$2" "$3" <<'PY' || { echo "ARM $ARM: anchor not found exactly once in $1"; echo "$NAME RESULT FAIL (arm)"; exit 2; }
import sys
p, a, b = sys.argv[1:]
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
    }
    case "$ARM" in
        nomask) arm modules/aerial/secondary/QrCode.js '        applyMask(g, mask);' '        /* armed: no mask applied */' ;;
        noescape) arm modules/aerial/secondary/QrCode.js '        out += (c === bs || c === ";"' '        out += (false && c === ";"' ;;
        *) echo "unknown ARM $ARM"; exit 2 ;;
    esac
fi

# ---- the corpus: raw texts of every version, UTF-8, and the join strings with every escape
python3 -I - "$WORK/corpus.json" <<'PY'
import json, sys
caps = [14, 26, 42, 62, 84, 106, 122, 152, 180, 213]   # byte capacity at ECC M, versions 1..10
out = []
for v, c in enumerate(caps, 1):
    base = "WIFI:T:WPA;S:version-%d-" % v
    text = (base + "abcdefghijklmnopqrstuvwxyz0123456789" * 12)[:c]
    out.append({"name": "v%02d_full" % v, "kind": "raw", "text": text})
    out.append({"name": "v%02d_short" % v, "kind": "raw", "text": ("Aerial %d" % v) * 1 if v == 1 else (text[: max(1, caps[v - 2] + 1)])})
out += [
    {"name": "ascii", "kind": "raw", "text": "Hello, world"},
    {"name": "utf8_latin", "kind": "raw", "text": "Café Über Straße àèì"},
    {"name": "utf8_cjk", "kind": "raw", "text": "名前 ネットワーク 한글"},
    {"name": "utf8_emoji", "kind": "raw", "text": "Home \U0001F3E0 5G ☃"},
]
def esc(s):
    for ch in chr(92) + ';,:"':
        s = s.replace(ch, chr(92) + ch)
    return s
def val(s):
    e = esc(s)
    return '"%s"' % e if s != "" and all(c in "0123456789abcdefABCDEF" for c in s) else e
cases = [
    ("wifi_plain", "Home-5G", "correct horse", "wpa2", False),
    ("wifi_semicolon", "a;b", "p;w", "wpa2", False),
    ("wifi_comma_colon", "net,work:1", "pa,ss:word", "wpa3", True),
    ("wifi_quote_backslash", 'my "home" \\ net', 'q"uote\\back', "wpa2", False),
    ("wifi_hexlike", "DEADBEEF", "0123456789", "wpa2", False),
    ("wifi_utf8", "Küche ☕", "grüße名", "wpa2/3", False),
    ("wifi_open", "Cafe-Free", "", "open", False),
    ("wifi_wep", "OldNet", "12345", "wep", False),
    ("wifi_longpsk", "LongPass", "x" * 63, "wpa2", False),
]
exp = {}
for name, ssid, psk, sec, hid in cases:
    out.append({"name": name, "kind": "wifi", "text": {"ssid": ssid, "psk": psk, "security": sec, "hidden": hid}})
    t = "nopass" if sec in ("open", "owe") else ("WEP" if sec == "wep" else "WPA")
    s = "WIFI:T:%s;S:%s;" % (t, val(ssid))
    if t != "nopass":
        s += "P:%s;" % val(psk)
    exp[name] = s + "H:%s;;" % ("true" if hid else "false")
for e in out:
    if e["kind"] == "raw":
        exp[e["name"]] = e["text"]
json.dump(out, open(sys.argv[1], "w"))
json.dump(exp, open(sys.argv[1] + ".exp", "w"))
PY
mkdir -p "$WORK/cells" "$WORK/cfg/theme" "$WORK/state" "$WORK/cache"
echo '{"theme":"eva","mode":"light"}' > "$WORK/cfg/theme/state.json"
log="$WORK/run.log"
XDG_CONFIG_HOME="$WORK/cfg" XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" OUT_DIR="$WORK/cells" QR_CORPUS="$WORK/corpus.json" \
    env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_QPA_PLATFORMTHEME= timeout -k 5 150 quickshell -n -p "$(pwd)/tools/dev/qml/aerial_qr_probe.qml" > "$log" 2>&1
rl_has "$log" 'qml: AQR RESULT (PASS|FAIL)' || { rl_noresult "$NAME" "$log"; exit 1; }
fail=0
rl_has "$log" 'qml: AQR RESULT PASS' || fail=1
python3 -I - "$WORK/cells" "$WORK/corpus.json.exp" <<'PY' || fail=1
import json, os, sys
import cv2
cells, expf = sys.argv[1:]
exp = json.load(open(expf))
bad = 0
det = cv2.QRCodeDetector()
arud = cv2.QRCodeDetectorAruco()
classic = 0
for name in sorted(exp):
    p = os.path.join(cells, name + ".png")
    if not os.path.exists(p):
        print("AQR %s FAIL  no picture" % name); bad += 1; continue
    made = open(os.path.join(cells, name + ".txt"), encoding="utf-8").read()
    img = cv2.imread(p)
    # the picture a phone sees: the grab, scaled up a little (the detector wants some pixels per module)
    dec, _, _ = det.detectAndDecode(img)
    via = "classic"
    if dec != exp[name]:
        # the classic detector misses some valid codes (version 3, mask 2 at 8 px per module); the Aruco-based one is a second reader
        dec, _, _ = arud.detectAndDecode(img)
        via = "aruco"
    if made != exp[name]:
        print("AQR %s FAIL  string: made %r, standard %r" % (name, made, exp[name])); bad += 1
    elif dec != exp[name]:
        print("AQR %s FAIL  decoded %r, wanted %r" % (name, dec[:60], exp[name][:60])); bad += 1
    else:
        classic += via == "classic"
        print("AQR %s PASS (%s)" % (name, via))
print("AQR decoded %d of %d (%d by the classic detector, the rest by the Aruco one)" % (len(exp) - bad, len(exp), classic))
sys.exit(1 if bad else 0)
PY
[ "$fail" = 0 ] && echo "$NAME RESULT PASS" || echo "$NAME RESULT FAIL"
exit "$fail"
