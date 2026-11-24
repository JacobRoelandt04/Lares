#!/usr/bin/env bash
# bridge_cast_probe.sh -- the bridge's cast (tools/bridge/lares-cast + castlib, modules/bridge/cast/CastSession.qml + CastView.qml;
# docs/contracts/bridge.md "The cast") against a FAKE PHONE: a stub `adb` (this runner's own) whose `shell` execs
# tools/dev/stubs/bridge/fake_scrcpy_server.py, which speaks scrcpy 5.0.1's server protocol with real x264 / AAC. Offscreen, in a sandbox
# copy, private bus / state / config / cache; no phone, no real adb (the stub is first on PATH and refuses nothing else), no window, no
# audio device (the QML side casts without sound; the sound is proved on the tool alone, with ffmpeg as the player).
#
#   tools/dev/bridge_cast_probe.sh              BRIDGE_CAST RESULT PASS | FAIL
#   ARM=<name> tools/dev/bridge_cast_probe.sh   fails on the arm's own check (prints `ARM <name>: failed as it must`)
#   ARM=all tools/dev/bridge_cast_probe.sh      every arm; `BRIDGE_CAST ARMS PASS | FAIL`
#
# What is checked (BCP lines): the QML side (tools/dev/qml/bridge_cast_probe.qml: a live session, a first frame, the picture's rect, a rotation,
# the close and reopen within 2 s, stop) and, from the fake phone's log, what it RECEIVED (p1 the exact 32 touch bytes of a tap, none for a
# click on the letterbox; p2 the same after the rotation with the NEW screen size; p3 Left / Down / Right are BACK / HOME / APP_SWITCH and
# never arrows, Return, a typed letter, Up; p4 the wheel; p5 RESET_VIDEO for every player that connects (the view asks again once its player is ready: a player drops what it probed with); p6 the jar pushed, the forward made
# and removed; p7 the server's argv), the picture from the grabs (p8 not blank, moving, continuing after the rotation and the reopen; p9
# glass-to-glass latency, printed), p10 what is left once the parent is gone, and t1-t6 the tool alone with sound (ffprobe sees h264 + aac,
# ffmpeg decodes it clean, EOF on stdin ends it with exit 0 and nothing left). ARMs (each patches the sandbox COPY; the named check must fail):
#   noreset    lares-cast never asks RESET_VIDEO when a player connects        -> t6
#   wrongsize  a touch carries the first size, not the current one             -> p2
#   arrows     Left is sent as the arrow, not BACK                             -> p3
#   avcc       the NALUs are left Annex-B in the FLV                           -> t7 (Qt decodes Annex-B in an FLV anyway: only the bytes tell)
#   timed      the picture keeps the phone's timestamps without sound (Qt schedules it: ~460 ms) -> p9
#   nowatchdog the view never opens a stuck player again                        -> j1
#   stalekey   a reopened player asks no key frame (it was gated on "no picture yet") -> j1
#   reopendark the view reopens while the tool says no picture comes            -> i1
#   nohold     the page takes no frame and lets the restart go at once       -> h2
#   heldleaks  a held picture (inputHeld / an unlock out) still sends the press -> l1
#   keysmix    a held picture still types its keys                              -> l2
#   touchnounlock  the press on a dark / locked picture is not swallowed        -> l3
#   bareprobe  the harness starts the cast when smoked bare (no runner)         -> bare (the stub adb is called)
#   deskclick  a Desktop's picture swallows a click on a locked / dark phone    -> u5
#   turnstops  the player follows the page's own `visible` (hidden whenever the phone's back shows) -> v1
#   lookresize a size asked for while the phone turns restarts the stream at once -> v4
#   hiddenhold a hold taken while the back shows waits for a frame that is never taken -> v7
#   altwakes   Alt alone (the free look's key) wakes a dark phone             -> l9
#   recordlate the session drops the tool's `record` event once it has asked it to quit -> g2
# (g2 / p13: a recording session -- CastSession.record on the real lares-cast --record -- says where its file went after stop(), and the file
# is an mp4 of the picture)
# (v0-v8: the whole BridgePopup over a live BridgeService, its tool a stub and its session the real lares-cast on the fake phone: a free
# look, a resize and a lost stream during one, the popup's opening turn)
# (l1-l9, u1-u4: the input gate and the unlock trigger on a spy session; r1-r3: the Reconnecting hold; bare: a bare smoke starts nothing)
# (also h1-h3 / p12 the cast page holds its last frame blurred through a resize's restart, i1 a dark screen is told and left alone, j1 a stuck player is opened again, k1 / p11 a Desktop is a new display at 240 dpi)
set -u
{
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${BCP_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-bridge-cast}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-/tmp/lares-sbx-cast}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi BCP_INNER=1 ARM="${ARM:-}" bash tools/dev/bridge_cast_probe.sh "$@"
fi
. tools/dev/result_lib.sh
SCRATCH="${SCRATCH:-/tmp}"
NAME="BRIDGE_CAST"

arm() {
    python3 - "$@" <<'PY'
import sys
p, a, b = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    print("ARM anchor found %d times in %s: %r" % (s.count(a), p, a[:80])); sys.exit(2)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PY
}

run_once() {
    local tree log out rc w port port2
    tree=$(mktemp -d "$SCRATCH/bcp.XXXXXX") || return 1
    rsync -a --exclude .git --exclude .qmlls.ini --exclude Screenshots ./ "$tree/" || return 1
    case "$1" in
        "") ;;
        noreset) arm "$tree/tools/bridge/lares-cast" '            emit(event="client", connected=True)
            self.send(proto.reset_video())
' '            emit(event="client", connected=True)
' || return 3 ;;
        wrongsize) arm "$tree/tools/bridge/lares-cast" 'm["x"], m["y"], self.vw, self.vh)' 'm["x"], m["y"], 192, 384)' || return 3 ;;
        arrows) arm "$tree/modules/bridge/cast/CastView.qml" '                return n;' '                return "";' || return 3 ;;
        unlocktouch) arm "$tree/modules/bridge/screen/CastPage.qml" ' && (!page._cast || page._cast.unlock.indexOf("touch") >= 0)' '' || return 3 ;;
        navkeys) arm "$tree/modules/bridge/cast/CastView.qml" 'const w = root.navKeys ? String(root.navKeys[n] || "") : "";' 'const w = ({ back: "Left", home: "Down", recents: "Right" })[n];' || return 3 ;;
        avcc) arm "$tree/tools/bridge/lares-cast" 'proto.annexb_to_avcc(data)' 'data' || return 3 ;;
        nohold) arm "$tree/modules/bridge/screen/CastPage.qml" '            page._holding = true;
            page._asked = true;
            freeze.scheduleUpdate();' '            page.service.castHoldReady();' || return 3 ;;
        nowatchdog) arm "$tree/modules/bridge/cast/CastView.qml" 'running: root._wanted && !root._off && (root.session.flowKnown ? root.session.flowing : true)' 'running: false' || return 3 ;;
        heldleaks) arm "$tree/modules/bridge/cast/CastView.qml" '            if (root.inputHeld || root._trigger())
                return;' '            if (root._trigger())
                return;' || return 3 ;;
        keysmix) arm "$tree/modules/bridge/cast/CastView.qml" '        if (root.inputHeld || root._trigger()) {
            event.accepted = true;' '        if (root._trigger()) {
            event.accepted = true;' || return 3 ;;
        touchnounlock) arm "$tree/modules/bridge/cast/CastView.qml" '            if (root.inputHeld || root._trigger())
                return;' '            if (root.inputHeld)
                return;
            root._trigger();' || return 3 ;;
        deskclick) arm "$tree/modules/bridge/screen/CastPage.qml" '        lockTrigger: !page._desktop' '        lockTrigger: true' || return 3 ;;
        bareprobe) arm "$tree/tools/dev/qml/bridge_cast_probe.qml" '        if (probe.work === "") {' '        if (false) {' || return 3 ;;
        stalekey) arm "$tree/modules/bridge/cast/CastView.qml" 'running: root._wanted && root._awaiting && (player.mediaStatus' 'running: root._wanted && !root._hasPicture && (player.mediaStatus' || return 3 ;;
        reopendark) arm "$tree/modules/bridge/cast/CastView.qml" '(root.session.flowKnown ? root.session.flowing : true)' 'true' || return 3 ;;
        turnstops) arm "$tree/modules/bridge/screen/CastPage.qml" '        playing: page.shown' '        playing: page.visible' || return 3 ;;
        lookresize) arm "$tree/modules/bridge/data/BridgeService.qml" '            if (root.castTurning)
                return;
' '' || return 3 ;;
        hiddenhold) arm "$tree/modules/bridge/screen/CastPage.qml" 'if (page._holding && page._holdWhy !== "Unlocking"' 'if (page._holding && !page._asked && page._holdWhy !== "Unlocking"' || return 3 ;;
        altwakes) arm "$tree/modules/bridge/cast/CastView.qml" 'Qt.Key_Super_R].indexOf(k) >= 0)' 'Qt.Key_Super_R].indexOf(k) >= 99)' || return 3 ;;
        timed) arm "$tree/tools/bridge/lares-cast" '("pts" if self.cast.audio else "zero")' '"pts"' || return 3 ;;
        recordlate) arm "$tree/modules/bridge/cast/CastSession.qml" '        if (ev && ev.event === "record") {' '        if (ev && ev.event === "record" && !root._quitSent) {' || return 3 ;;
        *) echo "unknown ARM $1"; return 3 ;;
    esac
    w=$(mktemp -d "$SCRATCH/bcw.XXXXXX") || return 1
    mkdir -p "$w/bin" "$w/grabs" "$tree/xdg/config/theme" "$tree/xdg/state" "$tree/xdg/cache" "$tree/home"
    printf '{"theme":"eva","mode":"light"}\n' > "$tree/xdg/config/theme/state.json"
    port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
    port2=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
    # the stub adb: logs every call; push / forward / forward --remove answer; `shell` becomes the fake phone (exec: the adb shell child IS it)
    cat > "$w/bin/adb" <<'PY'
#!/usr/bin/env python3
import os, sys
W = os.environ["CAST_W"]
a = sys.argv[1:]
open(W + "/adb.log", "a").write(" ".join(a) + "\n")
if a[:1] == ["-s"]:
    a = a[2:]
if a[0] == "push":
    print("1 file pushed")
elif a[0] == "forward" and a[1] == "--remove":
    open(W + "/forwards", "w").write("")
elif a[0] == "forward":
    open(W + "/forwards", "a").write(os.environ["CAST_PORT"] + "\n")
    print(os.environ["CAST_PORT"])
elif a[0] == "shell" and "app_process" not in a and any("wm size" in x for x in a):
    # the phone's screen, for a Desktop's dpi (the user's phone's own figures)
    print("Physical size: 1216x2688")
    print("Physical density: 480")
elif a[0] == "shell":
    i = a.index("com.genymobile.scrcpy.Server") if "com.genymobile.scrcpy.Server" in a else len(a) - 1
    cmd = [sys.executable, os.environ["CAST_FAKE"], "--port", os.environ["CAST_PORT"], "--log", os.environ.get("CAST_LOG", W + "/fake.log"), "--control-dir", W,
           "--server-args", " ".join(a[i + 2:])]
    if "audio=true" in a:
        cmd.append("--audio")
    os.execvp(cmd[0], cmd)
PY
    chmod +x "$w/bin/adb"
    # the bridge tool's stand-in for the live BridgeService (V): `watch` prints watch.in and stays, castprep answers the fake phone's serial
    cat > "$w/lares-bridge" <<'PY'
#!/usr/bin/env python3
import json, os, sys, time
W = os.environ["CAST_W"]
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
if cmd == "watch":
    sys.stdout.write(open(W + "/watch.in").read())
    sys.stdout.flush()
    while True:
        time.sleep(1)
print(json.dumps({"ok": True, "serial": os.environ["BCP_SERIAL"], "bitRate": "8M", "maxFps": 30, "maxSize": 0}), flush=True)
PY
    # the leftover scan: prints how many processes carry the serial, or the fake's log of this work dir
    cat > "$w/scan.py" <<'PY'
import os, sys
n = 0
me = os.getpid()
for p in os.listdir("/proc"):
    if p.isdigit() and int(p) != me:
        try:
            c = open("/proc/%s/cmdline" % p, "rb").read().replace(b"\0", b" ").decode("utf-8", "replace")
        except OSError:
            continue
        if ("lares-cast" in c and sys.argv[1] in c) or ("fake_scrcpy_server" in c and os.path.dirname(os.path.abspath(sys.argv[0])) in c):
            n += 1
print(n)
PY
    : > "$w/forwards"
    log="$tree/run.log"
    ( cd "$tree" && env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$tree/xdg/config" XDG_STATE_HOME="$tree/xdg/state" XDG_CACHE_HOME="$tree/xdg/cache" HOME="$tree/home" \
        PATH="$w/bin:$PATH" CAST_W="$w" CAST_PORT="$port" CAST_FAKE="$tree/tools/dev/stubs/bridge/fake_scrcpy_server.py" LARES_CAST_JAR=/etc/hostname \
        BCP_WORK="$w" BCP_SERIAL="CAST-$(basename "$w")" \
        tools/dev/notifications_bus.sh timeout -k 2 200 quickshell -n -p tools/dev/qml/bridge_cast_probe.qml > "$log" 2>&1 )
    out=$(rl_result "$NAME" "$log" "BCP RESULT .*")
    rc=$?
    qml_res=$out
    printf '%s\n' "$qml_res" | grep -q "RESULT PASS" || rc=1
    rl_clean "$log" | rl_platform_noise | grep -a "BCP FAIL" | head -12
    [ -n "${BCP_VERBOSE:-}" ] && rl_clean "$log" | rl_platform_noise | grep -a -E "BCP |WARN|ERROR"
    if ! rl_isnoresult "$out"; then
        # what the fake phone received, the picture, what is left, the tool with sound
        rl_clean "$log" > "$w/qml.log"
        env PATH="$w/bin:$PATH" CAST_W="$w" CAST_PORT="$port2" CAST_FAKE="$tree/tools/dev/stubs/bridge/fake_scrcpy_server.py" LARES_CAST_JAR=/etc/hostname \
            CAST_LOG="$w/fake_a.log" LARES_CAST="$tree/tools/bridge/lares-cast" CAST_MAINPORT="$port" python3 - "$w" <<'PY' || rc=1
import json, os, re, statistics, struct, subprocess, sys, time
W = sys.argv[1]
SER = "CAST-" + os.path.basename(W)
fails = []
n = 0


def check(i, ok, what):
    global n
    n += 1
    print("BCP %s %s: %s" % ("ok  " if ok else "FAIL", i, what))
    if not ok:
        fails.append(i)


def lines(p):
    try:
        return open(p, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return []


fl = lines(W + "/fake.log")
C = [(float(l.split()[1]), bytes.fromhex(l.split()[2])) for l in fl if l.startswith("C ")]
E = [l for l in fl if l.startswith("E ")]
S = {}
for l in fl:
    if l.startswith("S "):
        _, k, t = l.split()
        S.setdefault(int(k), float(t))      # (the first session's: the later ones count their frames from 0 again)
qml = lines(W + "/qml.log")
marks = {}
for l in qml:
    m = re.search(r"BCP MARK (\S+) (\d+)", l)
    if m:
        marks[m.group(1)] = int(m.group(2)) / 1000.0
players = 0
for l in qml:
    m = re.search(r"BCP INFO reopen_ms=(\d+) players=(\d+)", l)
    if m:
        players = int(m.group(2))
# ---- p1 / p2: touch bytes, by hand
touch = [m for _, m in C if m[0] == 2]
def tb(action, x, y, w, h, pr):
    return bytes([2, action]) + bytes.fromhex("fffffffffffffffe") + x.to_bytes(4, "big") + y.to_bytes(4, "big") + w.to_bytes(2, "big") + h.to_bytes(2, "big") + pr.to_bytes(2, "big") + bytes(8)
want1 = [tb(0, 96, 192, 192, 384, 0xFFFF), tb(1, 96, 192, 192, 384, 0)]
want2 = [tb(0, 192, 96, 384, 192, 0xFFFF), tb(1, 192, 96, 384, 192, 0)]
check("p1", touch[:2] == want1 and len(touch) == 4, "a tap on the picture is exactly 2 touch messages (32 bytes each, video pixels 96,192 on a 192x384 screen) and the click on the letterbox none: %d touch messages, first pair %s" % (len(touch), "exact" if touch[:2] == want1 else [m.hex() for m in touch[:2]]))
check("p2", touch[2:4] == want2, "after the rotation a tap is 192,96 on a 384x192 screen: %s" % ("exact" if touch[2:4] == want2 else [m.hex() for m in touch[2:4]]))
# ---- p3 keys, text
seq = []
for _, m in C:
    if m[0] == 0:
        seq.append(("k", m[1], int.from_bytes(m[2:6], "big")))
    elif m[0] == 1:
        seq.append(("t", m[5:].decode()))
wk = [("k", 0, 4), ("k", 1, 4), ("k", 0, 3), ("k", 1, 3), ("k", 0, 187), ("k", 1, 187), ("k", 0, 66), ("k", 1, 66), ("t", "a"), ("k", 0, 19), ("k", 1, 19)]
check("p3", seq == wk, "Left / Down / Right are BACK / HOME / APP_SWITCH (down, up), then ENTER, the text 'a', then DPAD_UP, and no arrow: %s" % (seq if seq != wk else "exact"))
# ---- p4 wheel
sc = [m for _, m in C if m[0] == 3]
ws = bytes.fromhex("03" "00000060" "000000c0" "00c0" "0180" "0000" "0800" "00000000")
check("p4", sc == [ws], "one notch of the wheel is one scroll message, vscroll 0x0800 at 96,192: %s" % ("exact" if sc == [ws] else [m.hex() for m in sc]))
# ---- p5 reset
resets = len([e for e in E if e.endswith(" reset")])
check("p5", players >= 2 and resets >= players, "RESET_VIDEO for every player that connects: %d players, %d resets" % (players, resets))
# ---- p6 / p7 adb
al = lines(W + "/adb.log")
check("p6", any(l.startswith("-s CAST-") and " push " in l and "/data/local/tmp/scrcpy-server.jar" in l for l in al)
      and any(" forward tcp:0 localabstract:scrcpy_" in l for l in al) and any(" forward --remove tcp:" in l for l in al),
      "the jar is pushed, the forward made and taken away")
sh = [l for l in al if " shell " in l]
need = ["CLASSPATH=/data/local/tmp/scrcpy-server.jar", "app_process", "com.genymobile.scrcpy.Server", " 5.0.1 ", "scid=", "tunnel_forward=true", "video_codec=h264", "audio=false", "control=true", "cleanup=true"]
# never scrcpy's stay_awake: its restore dies with adbd and left the user's phone on for good (the hold is castprep --hold / castend)
check("p7", bool(sh) and all(x in sh[0] + " " for x in need) and "stay_awake" not in sh[0],
      "the server is started with its arguments, no stay_awake: %s" % (sh[0][:200] if sh else "no shell call"))
# ---- p8 / p9 the picture
from PIL import Image
G = []
for l in qml:
    m = re.search(r"BCP GRAB (\d+) (\S+) (\S+) (\S+) (\S+) (\d+) (\d+)", l)
    if m:
        t = int(m.group(1))
        G.append((t / 1000.0, float(m.group(2)), float(m.group(3)), float(m.group(4)), float(m.group(5)), int(m.group(6)), int(m.group(7)), t))
# p8 / p9 judge the picture up to the dark screen (i1): after it the fake sends nothing for a while, a player is stuck on purpose (j1)
# and a Desktop has another size (k1)
G = [g for g in G if g[0] < marks.get("dark", 1e18)]
dec = []
blank = 0
for t, x, y, w, h, vw, vh, ms in G:
    p = "%s/grabs/g%d.png" % (W, ms)
    if not os.path.exists(p) or w < 20 or vw <= 0:
        continue
    try:
        im = Image.open(p).convert("L")
    except OSError:
        continue
    sc_ = w / vw
    if x + w > im.width + 1 or y + h > im.height + 1:
        continue
    vals, ok = [], True
    for i in range(16):
        cx = x + (i + 0.5) * (vw / 16.0) * sc_
        cy = y + 12 * sc_
        px = [im.getpixel((int(cx) + dx, int(cy) + dy)) for dx in (-1, 0, 1) for dy in (-1, 0, 1)]
        v = sum(px) / 9.0
        if 70 < v < 180:
            ok = False
        vals.append(1 if v >= 128 else 0)
    crop = im.crop((int(x), int(y) + 30, int(x + w), int(y + h)))
    px = list(crop.getdata())
    mean = sum(px) / len(px)
    sd = (sum((q - mean) ** 2 for q in px) / len(px)) ** 0.5
    if sd < 8:
        blank += 1
    if ok:
        dec.append((t, sum(b << i for i, b in enumerate(vals)), vw))
dec.sort()
ns = [d[1] for d in dec]
check("p8a", len(dec) >= 20 and blank == 0, "the picture is not blank and its frame counter reads in %d of %d grabs (blank: %d)" % (len(dec), len(G), blank))
check("p8b", len(set(ns)) >= 15 and all(b >= a for a, b in zip(ns, ns[1:])), "it moves: %d distinct frame numbers, never backwards" % len(set(ns)))
rot = marks.get("rotated", 1e18)
after = [d for d in dec if d[0] > rot and d[2] == 384]
check("p8c", len({d[1] for d in after}) >= 5, "the picture continues after the rotation (%d distinct frames at 384 wide)" % len({d[1] for d in after}))
ro = marks.get("reopen", 1e18)
after2 = [d for d in dec if d[0] > ro]
check("p8d", len({d[1] for d in after2}) >= 3, "the picture continues after the popup closed and opened (%d distinct frames)" % len({d[1] for d in after2}))
lat = [(d[0] - S[d[1]]) * 1000 for d in dec if d[1] in S]
if lat:
    print("BCP LATENCY glass-to-glass on the fake (frame sent -> seen in a grab requested after it): median %.0f ms, min %.0f ms, p90 %.0f ms, n=%d (a grab lands 1-2 frames after its request, so this is an upper bound)"
          % (statistics.median(lat), min(lat), sorted(lat)[int(len(lat) * 0.9)], len(lat)))
# the picture without sound shows each frame as it is decoded (all timestamps 0): ~25 ms on the fake; with the phone's own times
# it was ~460 (the user: "quite a bit of latency"). 150 ms leaves the grab's own frames of slack and fails the scheduled player.
check("p9", bool(lat) and 0 < statistics.median(lat) < 150, "the latency is under 150 ms (median %.0f): frames shown as they come" % (statistics.median(lat) if lat else -1))
# ---- p10 what is left once the parent is gone
def left(extra):
    r = subprocess.run(["python3", W + "/scan.py", SER], capture_output=True, text=True).stdout.strip()
    return int(r or 0)
t0 = time.time()
while time.time() - t0 < 5 and left(0) != 0:
    time.sleep(0.2)
# ---- p11: a Desktop is a new display at the room's size, laid out like the phone (480 dpi at 1216 px wide), no max_size
P = [json.loads(l.split(" ", 2)[2]) for l in fl if l.startswith("P ")]
nd = [x for x in P if x.get("new_display")]
check("p11", len(nd) == 1 and nd[0]["new_display"] == "608x1344/240" and "max_size" not in nd[0] and nd[0].get("vd_destroy_content") == "false",
      "a Desktop cast starts a new display 608x1344 at 240 dpi, keeps its apps when it ends, and no max_size: %s" % (nd[:1],))
# ---- p12: the cast page's hold is a picture (the last frame, blurred), not a flat ground with words
try:
    hi = Image.open(W + "/held.png").convert("L").crop((40, 150, 260, 450))
    hp = list(hi.getdata())
    hm = sum(hp) / len(hp)
    hsd = (sum((q - hm) ** 2 for q in hp) / len(hp)) ** 0.5
except OSError:
    hsd = -1
check("p12", hsd > 6, "the page's hold through a restart shows the last frame (grey spread %.1f in the middle; a flat ground is ~0)" % hsd)
# ---- p13: the recording session's file (G2) is an mp4 of the picture
pr = subprocess.run(["ffprobe", "-v", "error", "-count_frames", "-select_streams", "v", "-show_entries", "stream=codec_name,nb_read_frames", "-of", "csv=p=0",
                     W + "/rec/cast.mp4"], capture_output=True, text=True)
vf = pr.stdout.strip().split(",")
check("p13", len(vf) == 2 and vf[0] == "h264" and int(vf[1] or 0) > 30 and not os.path.exists(W + "/rec/cast.mp4.part.flv"),
      "the recording session's file is an mp4 of the picture, its part gone: %s %s" % (pr.stdout.strip(), pr.stderr.strip()[-200:]))
fw = open(W + "/forwards").read().strip()
check("p10", left(0) == 0 and fw == "", "with the shell gone no lares-cast, no fake phone and no forward is left (processes %d, forwards '%s')" % (left(0), fw))
# ---- t: the tool alone, with sound
env = dict(os.environ)
env["CAST_PORT"] = os.environ["CAST_PORT"]
ser2 = "CAST-AUD-" + os.path.basename(W)
p = subprocess.Popen([os.environ["LARES_CAST"], ser2, "--audio", "--max-size", "400", "--bit-rate", "8M", "--max-fps", "30"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
ready = None
t0 = time.time()
evs = []
while time.time() - t0 < 15:
    l = p.stdout.readline()
    if not l:
        break
    evs.append(json.loads(l))
    if evs[-1]["event"] == "ready" or evs[-1]["event"] == "error":
        ready = evs[-1]
        break
check("t1", bool(ready) and ready["event"] == "ready", "the tool with --audio comes ready: %s" % ready)
if ready and ready["event"] == "ready":
    time.sleep(1.2)     # past the first key frame: this player joins mid-stream
    t6 = time.time()
    f1 = subprocess.run(["ffmpeg", "-v", "error", "-probesize", "4096", "-analyzeduration", "0", "-i", ready["url"], "-frames:v", "1", "-f", "null", "-"], capture_output=True, text=True, timeout=20)
    t6 = time.time() - t6
    check("t6", f1.returncode == 0 and t6 < 2.0, "a player that connects mid-stream gets a picture at once, not at the phone's next key frame (8 s): %.2f s" % t6)
    # t7: the FLV's own bytes: the first tags are the header, onMetaData, the AVC sequence header, then key frame NAL units with 4-byte lengths
    import socket
    hp = ready["url"].rsplit(":", 1)[1]
    so = socket.create_connection(("127.0.0.1", int(hp)), timeout=5)
    raw = b""
    t0_ = time.time()
    while len(raw) < 20000 and time.time() - t0_ < 5:
        try:
            c = so.recv(65536)
        except OSError:
            break
        if not c:
            break
        raw += c
    so.close()
    kinds, avcc_ok, i = [], None, 13
    while i + 11 <= len(raw):
        ln = int.from_bytes(raw[i + 1:i + 4], "big")
        if i + 11 + ln + 4 > len(raw):
            break
        d = raw[i + 11:i + 11 + ln]
        if raw[i] == 9 and d[1] == 1 and avcc_ok is None:
            j = 5
            while j + 4 <= len(d):
                j += 4 + int.from_bytes(d[j:j + 4], "big")
            avcc_ok = j == len(d)
            kinds.append("avc frame key=%s" % (d[0] >> 4 == 1))
        elif raw[i] == 9 and d[1] == 0:
            kinds.append("avc seq")
        elif raw[i] == 18:
            kinds.append("meta")
        elif raw[i] == 8 and d[1] == 0:
            kinds.append("aac seq")
        i += 11 + ln + 4
    check("t7", raw[:9] == b"FLV\x01\x05\x00\x00\x00\x09" and avcc_ok is True and kinds[:1] == ["meta"] and "avc seq" in kinds and "aac seq" in kinds and "avc frame key=True" in kinds,
          "the FLV starts with its header (video + audio), onMetaData, the AVC and AAC sequence headers, and key frame NAL units whose 4-byte lengths add up to the tag: %s, lengths %s" % (kinds[:6], avcc_ok))
    pr = json.loads(subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-of", "json", ready["url"]], capture_output=True, text=True).stdout or "{}")
    ss = {s["codec_type"]: s for s in pr.get("streams", [])}
    check("t2", "video" in ss and "audio" in ss and ss["video"]["codec_name"] == "h264" and (ss["video"]["width"], ss["video"]["height"]) == (192, 384)
          and ss["audio"]["codec_name"] == "aac" and ss["audio"]["channels"] == 2 and ss["audio"]["sample_rate"] == "48000", "ffprobe on the url sees h264 192x384 and aac stereo 48000: %s" % {k: (v["codec_name"]) for k, v in ss.items()})
    d = subprocess.run(["ffmpeg", "-v", "error", "-i", ready["url"], "-t", "2", "-f", "null", "-"], capture_output=True, text=True)
    check("t2b", d.returncode == 0 and d.stderr.strip() == "", "ffmpeg decodes 2 s of video and sound from the url clean: %s" % d.stderr.strip()[:200])
    p.stdin.close()
    try:
        rc = p.wait(timeout=8)
    except subprocess.TimeoutExpired:
        p.kill()
        rc = "timeout"
    rest = [json.loads(x) for x in p.stdout.read().decode().splitlines() if x.strip()]
    check("t3", rc == 0 and any(e["event"] == "ended" for e in rest), "EOF on stdin ends the tool: exit %s, events %s" % (rc, [e["event"] for e in rest]))
    al2 = lines(W + "/adb.log")
    sh2 = [l for l in al2 if " shell " in l and ser2 in l]
    check("t4", bool(sh2) and all(x in sh2[0] for x in ("audio=true", "audio_codec=aac", "max_size=400", "video_bit_rate=8000000", "max_fps=30")), "the options reach the server: %s" % (sh2[0][-160:] if sh2 else "no call"))
else:
    p.kill()
    print("t1 stderr: " + p.stderr.read().decode()[-300:])
t0 = time.time()
while time.time() - t0 < 4 and subprocess.run(["python3", W + "/scan.py", ser2], capture_output=True, text=True).stdout.strip() != "0":
    time.sleep(0.2)
check("t5", subprocess.run(["python3", W + "/scan.py", ser2], capture_output=True, text=True).stdout.strip() == "0" and open(W + "/forwards").read().strip() == "",
      "after the tool ended no process and no forward is left")
print("BCP PY %d checks, failed: %s" % (n, ", ".join(fails) or "none"))
sys.exit(1 if fails else 0)
PY
        # bare: the harness smoked with no runner starts NOTHING (it once started the user's real adb server). A stub adb leads PATH and logs
        # every call; the guard prints `BCP skipped (no runner)` and quits, an unguarded probe calls the stub at once.
        mkdir -p "$w/barebin"
        printf '#!/bin/sh\necho "$@" >> "%s/bare_adb.log"\nexit 1\n' "$w" > "$w/barebin/adb"
        chmod +x "$w/barebin/adb"
        ( cd "$tree" && env -u WAYLAND_DISPLAY -u BCP_WORK QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$tree/xdg/config" XDG_STATE_HOME="$tree/xdg/state" XDG_CACHE_HOME="$tree/xdg/cache" HOME="$tree/home" \
            PATH="$w/barebin:$PATH" timeout -k 2 25 quickshell -n -p tools/dev/qml/bridge_cast_probe.qml > "$w/bare.log" 2>&1 )
        if grep -aq "BCP skipped (no runner)" "$w/bare.log" && [ ! -s "$w/bare_adb.log" ]; then
            echo "BCP ok   bare: smoked with no runner the probe starts nothing and says so"
        else
            echo "BCP FAIL bare: smoked with no runner the probe must start nothing (adb calls: $(wc -l < "$w/bare_adb.log" 2>/dev/null || echo 0); log: $(grep -a 'BCP' "$w/bare.log" | head -2 | tr '\n' ';'))"
            rc=1
        fi
        # a warning that names this module, a binding loop, or an assignment of undefined is a failure of its own
        bad=$(rl_clean "$log" | rl_platform_noise | grep -a -E "WARN|ERROR|CASTVIEW" \
            | grep -a -E "modules/bridge/cast|bridge_cast_probe|CastView|CastSession|Binding loop|Unable to assign|non-existent|is not a type|ReferenceError|TypeError|Cannot (read|assign|call)|CASTVIEW player error" | head -6)
        if [ -n "$bad" ]; then
            echo "BCP FAIL h: the log holds a warning that names the cast (or a loop / an undefined):"
            printf '%s\n' "$bad" | sed 's/^/    /'
            rc=1
        fi
        rl_isnoresult "$out" || { [ -z "${BCP_KEEP:-}" ] && rm -rf "$tree" "$w"; }
    fi
    printf '%s\n' "$qml_res" >/dev/null
    return $rc
}

if [ "${ARM:-}" = all ]; then
    bad=0
    declare -A NEED=([noreset]="t6" [wrongsize]="p2" [arrows]="p3" [avcc]="t7" [timed]="p9" [nowatchdog]="j1" [stalekey]="j1" [reopendark]="i1" [nohold]="h2" [heldleaks]="l1" [keysmix]="l2" [touchnounlock]="l3" [bareprobe]="bare" [deskclick]="u5" [turnstops]="v1" [lookresize]="v4" [hiddenhold]="v7" [altwakes]="l9" [unlocktouch]="u6" [navkeys]="k1" [recordlate]="g2")
    for a in ${ONLY_ARMS:-noreset wrongsize arrows avcc timed nowatchdog stalekey reopendark nohold heldleaks keysmix touchnounlock bareprobe deskclick turnstops lookresize hiddenhold altwakes unlocktouch navkeys recordlate}; do
        o=$(run_once "$a" 2>&1); rc=$?
        if printf '%s\n' "$o" | grep -aq "RESULT FAIL (no result: "; then echo "ARM $a: did not load (proves nothing)"; bad=1
        elif printf '%s\n' "$o" | grep -aqE "BCP FAIL ${NEED[$a]}:"; then echo "ARM $a: failed as it must (${NEED[$a]})"
        elif [ "$rc" = 0 ]; then echo "ARM $a: still PASSES (toothless)"; bad=1
        else echo "ARM $a: failed, but not at its own check (${NEED[$a]}): $(printf '%s\n' "$o" | grep -a 'BCP FAIL' | head -2 | tr '\n' ';')"; bad=1; fi
    done
    echo "$NAME ARMS $([ "$bad" = 0 ] && echo PASS || echo FAIL)"
    exit $bad
fi
out=$(run_once "${ARM:-}" 2>&1); rc=$?
printf '%s\n' "$out"
if printf '%s\n' "$out" | grep -aq "RESULT FAIL (no result: "; then
    [ -n "${ARM:-}" ] && echo "ARM ${ARM}: the armed copy did not load -- it proves nothing"
    exit 1
fi
echo "$NAME RESULT $([ "$rc" = 0 ] && echo PASS || echo FAIL)"
exit $rc
}
