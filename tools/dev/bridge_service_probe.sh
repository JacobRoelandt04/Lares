#!/usr/bin/env bash
# bridge_service_probe.sh -- modules/bridge/data/ (BridgeService, ActionRunner, BridgeConfig; docs/contracts/bridge.md sections 3-7),
# offscreen in a sandbox copy, on a STUB of tools/bridge/lares-bridge (a script that prints scripted `watch` lines from a file and
# answers the one-shots with scripted JSON, logging its argv and times). No phone, no adb, no KDE Connect, no notification daemon:
# the toasts go to a stub bus, the OSD to a stub service, the file picker and the clipboard are stubs.
#
#   tools/dev/bridge_service_probe.sh        BRIDGE_SERVICE RESULT PASS | FAIL
#   ARM=<name> ...   ARM=all ...             BRIDGE_SERVICE ARMS PASS | FAIL
#
# ARMs (each patches the sandbox copy; the check named must fail):
#   twotoasts       an ended job is told again each line it is carried  -> "d: exactly one closing toast and one ack per job"
#   progressstays   the progress toast is not taken away at the end     -> "d: the progress toast goes with the closing toast (post, then withdraw)"
#   alwayswatch     the watcher exists (and runs) whether live or not   -> "a: no Process of any kind exists, and nothing ran"
#   seriallate      `serial` is written before the jobs, pairing, env   -> "b: serial is written last (a handler on serialChanged sees the new devices, jobs, pairing and env)"
#   openunlock      the popup's open asks for an unlock (round 5's rule)  -> "u1: ..."
#   nohold          a Mirror's castprep does not hold the screen on          -> "c1: ..."
#   nosleep         a cast's end never puts the phone it woke back to sleep  -> "c6b: ..."
#   pinargv         the PIN rides in `calls` beside stdin                -> "u4: ..."
#   oldended        an "ended" cast is "starting" again, nothing brings it back -> "k: reconnected (waited 8000 ms)"
#   noreconnect     the ended cast is told "reconnecting" and never restarted    -> "k: reconnected (waited 8000 ms)"
#   usbagain        the USB switch is asked at every line of an open            -> "c7b: ..."
#   deskrestart     a desktop's resize restarts the stream (a mirror's rule)    -> "c12: ..."
#   reconnectpin    a reconnect types the PIN (castprep --unlock) though nobody asked -> "c2: ..."
#   flapforever     every live session gives the tries back at once (a session that dies a second in reconnects for ever) -> "c3: ..."
#   deskunlock      a Desktop cast types the PIN at its start (Android keeps the new display usable while locked; the lock screen's focus is
#                   display 0's, so the tool refuses and toasts)                -> "c11b: ..."
#   recordprep      a recording cast's castprep is not asked for the file (no --record) -> "c16: ..."
#   recordlost      the file castprep named never reaches lares-cast                    -> "c16: ..."
#   recordreload    a recording mirror restarts for a new size (two files)              -> "c17: ..."
#   recordquiet     the end of a recording says nothing                                 -> "c18: ..."
# (c: the cast on a stub lares-bridge and a stub lares-cast put in the copy of tools/bridge/: reconnect, the hold, the unlock the page
# asks, the USB at the popup's open, the desktop's screen; no real adb is on its PATH)
set -u
{
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${BSP_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-bridge-service}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi BSP_INNER=1 ARM="${ARM:-}" bash tools/dev/bridge_service_probe.sh "$@"
fi
. tools/dev/result_lib.sh
SCRATCH="${SCRATCH:-/tmp}"
NAME="BRIDGE_SERVICE"

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

# stub <dir> <answers json> : the tool's stand-in, its scripted answers, an empty feed
stub() {
    mkdir -p "$1"
    printf '%s\n' "$2" > "$1/answers.json"
    : > "$1/watch.in"
    cat > "$1/lares-bridge" <<'PY'
#!/usr/bin/env python3
# The stand-in for tools/bridge/lares-bridge: `watch` prints the lines of watch.in as they are appended (existing ones first); a
# one-shot logs its argv at its start and its end and answers what answers.json says for its verb ("_sleep" seconds first,
# "_exit" its status, "_raw" a non-JSON answer).
import json, os, sys, time
d = os.path.dirname(os.path.abspath(__file__))
argv = sys.argv[1:]
cmd = argv[0] if argv else ""
def log(ev, **more):
    rec = {"t": time.time(), "ev": ev, "argv": argv}
    rec.update(more)
    with open(os.path.join(d, "calls.log"), "a") as f:
        f.write(json.dumps(rec) + "\n")
if cmd == "watch":
    log("watch")
    pos = 0
    buf = ""
    while True:
        try:
            with open(os.path.join(d, "watch.in")) as f:
                f.seek(pos)
                chunk = f.read()
                pos = f.tell()
        except OSError:
            chunk = ""
        buf += chunk
        while "\n" in buf:
            line, buf = buf.split("\n", 1)
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
        time.sleep(0.02)
log("start")
# `pin set` reads the PIN on stdin (the only one-shot that reads anything): what arrived is logged for the probe
if argv[:1] == ["pin"] and argv[2:3] == ["set"]:
    log("stdin", data=sys.stdin.read())
try:
    answers = json.load(open(os.path.join(d, "answers.json")))
except Exception:
    answers = {}
spec = dict(answers.get(cmd, {"ok": True}))
time.sleep(float(spec.pop("_sleep", 0)))
code = int(spec.pop("_exit", 0 if spec.get("ok", True) else 1))
raw = spec.pop("_raw", None)
log("end")
print(raw if raw is not None else json.dumps(spec), flush=True)
sys.exit(code)
PY
    chmod +x "$1/lares-bridge"
}

# cast_stub <path> : the stand-in for tools/bridge/lares-cast IN THE COPY (never the real tool: it would run adb). It logs its argv and every
# command on stdin to $BSP_WORK/c/cast.log, prints `ready` (or, by c/cast_plan.json {"from": N, "mode": "ended"}, an `ended` at once for every
# start from the Nth on) and then the lines the probe appends to c/cast.out; an `ended` line ends it, as the real tool does; `quit` ends it,
# and a start with `--record PATH` then says `record` as the real tool does at its end ({"path": PATH}, or by cast_plan.json {"record":
# "error"} {"error", "kept": PATH.part.flv}).
cast_stub() {
    cat > "$1" <<'PY'
#!/usr/bin/env python3
import json, os, sys, threading, time
d = os.path.join(os.environ["BSP_WORK"], "c")
def log(**kw):
    kw["t"] = time.time()
    with open(d + "/cast.log", "a") as f:
        f.write(json.dumps(kw) + "\n")
def emit(o):
    sys.stdout.write(json.dumps(o) + "\n")
    sys.stdout.flush()
n = 1
try:
    n = 1 + sum(1 for l in open(d + "/cast.log") if '"ev": "start"' in l)
except OSError:
    pass
log(ev="start", n=n, argv=sys.argv[1:])
try:
    plan = json.load(open(d + "/cast_plan.json"))
except Exception:
    plan = {}
if plan.get("mode") == "ended" and n >= plan.get("from", 1):
    emit({"event": "ended", "reason": "the phone closed the stream"})
    os._exit(0)
emit({"event": "ready", "url": "tcp://127.0.0.1:1", "width": 192, "height": 384, "name": "Stub"})
try:
    pos = os.path.getsize(d + "/cast.out")
except OSError:
    pos = 0
def reader():
    for line in sys.stdin:
        log(ev="in", line=line.strip())
        if '"quit"' in line:
            emit({"event": "ended", "reason": "stopped"})
            a = sys.argv[1:]
            if "--record" in a:
                p = a[a.index("--record") + 1]
                emit({"event": "record", "error": "boom: no muxer", "kept": p + ".part.flv"} if plan.get("record") == "error" else {"event": "record", "path": p})
            os._exit(0)
    os._exit(0)
threading.Thread(target=reader, daemon=True).start()
buf = ""
while True:
    try:
        with open(d + "/cast.out") as f:
            f.seek(pos)
            chunk = f.read()
            pos = f.tell()
    except OSError:
        chunk = ""
    buf += chunk
    while "\n" in buf:
        line, buf = buf.split("\n", 1)
        sys.stdout.write(line + "\n")
        sys.stdout.flush()
        if '"ended"' in line:
            os._exit(0)
    time.sleep(0.02)
PY
    chmod +x "$1"
}

run_once() {
    local tree log out rc S=modules/bridge/data/BridgeService.qml
    tree=$(mktemp -d "$SCRATCH/bsp.XXXXXX") || return 1
    rsync -a --exclude .git --exclude .qmlls.ini --exclude Screenshots ./ "$tree/" || return 1
    case "$1" in
        "") ;;
        twotoasts)     arm "$tree/$S" '            if (root._handled[j.id] === true)
                continue;
' '' || return 3 ;;
        progressstays) arm "$tree/$S" '                    root.notifier.withdraw("send-" + j.id);
                }
            } else if' '                }
            } else if' || return 3 ;;
        alwayswatch)   arm "$tree/$S" '        model: root.live ? 1 : 0
        delegate: SupervisedStream {' '        model: 1
        delegate: SupervisedStream {' || return 3
                       arm "$tree/$S" '            enabled: root.live && root._haveTool' '            enabled: root._haveTool' || return 3 ;;
        seriallate)    arm "$tree/$S" '        root._ready = true;
        root._serial++;' '        root._ready = true;' || return 3
                       arm "$tree/$S" '        root._syncRows(line.devices);
        root._currentKey = line.current;' '        root._syncRows(line.devices);
        root._serial++;
        root._currentKey = line.current;' || return 3 ;;
        openunlock)    arm "$tree/$S" '            root._usbDue = true;
            root._usbAsk();' '            root._ask("unlock", root._currentKey, { auto: true });
            root._usbDue = true;
            root._usbAsk();' || return 3 ;;
        nohold)        arm "$tree/$S" 'hold: root._castMode === "mirror", record: root._castRecord }' 'hold: false, record: root._castRecord }' || return 3 ;;
        nosleep)       arm "$tree/$S" '        root._castEnd(k, root._castSleepOwed);' '        root._castEnd(k, false);' || return 3 ;;
        pinargv)       arm "$tree/$S" 'return root._ask("pin", key, { op: "set" }, p + "\n");' 'return root._ask("pin", key, { op: "set", pin: p }, p + "\n");' || return 3 ;;
        oldended)      arm "$tree/$S" '            if (st === "ended" || root._castWasLive || root._castReconnecting)' '            if (false)' || return 3
                       arm "$tree/$S" ': (root._csState === "ended" ? "reconnecting" : "starting")))))' ': "starting"))))' || return 3 ;;
        noreconnect)   arm "$tree/$S" '        root._castTries++;
        castReconnect.restart();' '        root._castTries++;' || return 3 ;;
        deskunlock)    arm "$tree/$S" 'root._castPrepRun(key, m === "mirror" && d.pin === "set" && ' 'root._castPrepRun(key, d.pin === "set" && ' || return 3 ;;
        unlockstart)   arm "$tree/$S" ' && root.settings.cast.unlock.indexOf("start") >= 0);' ');' || return 3 ;;
        sleepkept)     arm "$tree/$S" '{ sleep: sleep && root.settings.cast.sleepAtEnd !== false }' '{ sleep: sleep }' || return 3 ;;
        pickhome)      arm "$tree/$S" 'root.launcher.concat([root.pickerPath, from, ' 'root.launcher.concat([root.pickerPath, home, ' || return 3 ;;
        reconnectpin)  arm "$tree/$S" 'root._castPrepRun(root._castKey, false);' 'root._castPrepRun(root._castKey, true);' || return 3 ;;
        flapforever)   arm "$tree/$S" '            root._castWasLive = true;
            castStable.restart();' '            root._castWasLive = true;
            root._castTries = 0;' || return 3 ;;
        usbagain)      arm "$tree/$S" '        root._usbDue = false;
        root._ask("usbcalm"' '        root._ask("usbcalm"' || return 3 ;;
        deskrestart)   arm "$tree/$S" 'root._castMode === "mirror" && root.settings.cast.reloadOnResize === true' 'root.settings.cast.reloadOnResize === true' || return 3
                       arm "$tree/$S" '            if (root._deskResizeWanted()) {
                const t = root._deskSize();' '            if (false) {
                const t = root._deskSize();' || return 3 ;;
        recordprep)    arm "$tree/$S" 'hold: root._castMode === "mirror", record: root._castRecord }' 'hold: root._castMode === "mirror" }' || return 3 ;;
        recordlost)    arm "$tree/$S" '        cs.record = root._castRecord ? String(a.record || "") : "";' '        cs.record = "";' || return 3 ;;
        recordreload)  arm "$tree/$S" '            && !root._castRecord && root._castSize() !== cs.maxSize;' '            && root._castSize() !== cs.maxSize;' || return 3 ;;
        recordquiet)   arm "$tree/$S" '                onRecorded: ev => root._castRecorded(ev)
' '' || return 3 ;;
        *) echo "unknown ARM $1"; return 3 ;;
    esac
    mkdir -p "$tree/xdg/config/theme" "$tree/xdg/state" "$tree/xdg/cache" "$tree/home" "$tree/work"
    printf '{"theme":"eva","mode":"light"}\n' > "$tree/xdg/config/theme/state.json"
    local w="$tree/work"
    # a: the not-live service is given a tool that would log if it were ever run
    stub "$w/a" '{}'
    # b: the live service. ring fails, clip is slow, unpair never answers in time, mount fails, refresh answers no JSON
    stub "$w/b" '{
      "ring":    {"ok": false, "reason": "the phone is not on KDE Connect", "hint": "Open KDE Connect on the phone", "_exit": 1},
      "clip":    {"ok": true, "_sleep": 0.35},
      "unpair":  {"ok": true, "_sleep": 6},
      "mount":   {"ok": false, "reason": "aft-mtp-mount: no MTP device", "hint": "Set USB to File transfer", "_exit": 1},
      "refresh": {"_raw": "hello, I am not JSON"},
      "shot":    {"ok": true, "path": "/tmp/bsp-shot.png"},
      "mirror":  {"ok": true, "job": "m-1", "via": "usb"},
      "send":    {"ok": true, "job": "s-1", "via": "adb"}
    }'
    stub "$w/e" '{}'
    # c: the cast. castprep answers a serial and the link's figures, unlock takes half a second, usbcalm fails until the probe says otherwise
    stub "$w/c" '{
      "castprep": {"ok": true, "serial": "CS1", "bitRate": "8M", "maxFps": 30, "maxSize": 0},
      "unlock":   {"ok": true, "_sleep": 0.5},
      "usbcalm":  {"ok": false, "reason": "adb is not connected", "_exit": 1}
    }'
    mkdir -p "$w/pathbin"
    printf '#!/bin/sh\necho "$@" >> "%s/adb_called.log"\nexit 1\n' "$w" > "$w/pathbin/adb"
    chmod +x "$w/pathbin/adb"
    cast_stub "$tree/tools/bridge/lares-cast"
    mkdir -p "$w/b/cfg" "$w/cfg"
    printf '{ // the user'"'"'s\n  "files": { "open": ["echo", "open", "{path}"], "pickDir": "~/Inbox" }\n}\n' > "$w/b/cfg/bridge.jsonc"
    printf '#!/bin/sh\nprintf "/p/a.png\\000/p/b c.txt\\000"\n' > "$w/b/pick_ok.sh"
    printf '#!/bin/sh\nexit 1\n' > "$w/b/pick_cancel.sh"
    printf '#!/bin/sh\necho "no portal" >&2\nexit 2\n' > "$w/b/pick_fail.sh"
    chmod +x "$w/b"/pick_*.sh
    # g: configs
    printf '{\n  // wrong kinds and out-of-range numbers\n  "mirror": { "wifi": { "maxSize": -5, "bitRate": 7, "maxFps": 1000000000 }, "usb": { "maxSize": 99999 } },\n  "adb": { "start": "sometimes", "port": 99999, "idleKillS": -1 },\n  "files": { "open": "yazi", "usbMount": "/mnt/phone" },\n  "relight": "yes", "devices": { "Pixel 6 Pro": { "skin": "generic", "hidden": true }, "x": 5 }\n}\n' > "$w/cfg/bad.jsonc"
    printf '{ "files": { "usbMount": \n' > "$w/cfg/broken.jsonc"
    log="$tree/run.log"
    ( cd "$tree" && env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$tree/xdg/config" XDG_STATE_HOME="$tree/xdg/state" XDG_CACHE_HOME="$tree/xdg/cache" HOME="$tree/home" BSP_WORK="$w" PATH="$w/pathbin:$PATH" \
        tools/dev/notifications_bus.sh timeout -k 2 120 quickshell -n -p tools/dev/qml/bridge_service_probe.qml > "$log" 2>&1 )
    out=$(rl_result "$NAME" "$log" "BRIDGE_SERVICE RESULT .*")
    rc=$?
    printf '%s\n' "$out"
    rl_clean "$log" | grep -a "BSP .*FAIL" | head -8
    # BSP_VERBOSE=1: every check's line
    [ -n "${BSP_VERBOSE:-}" ] && rl_clean "$log" | grep -a -i -E "BSP |WARN|ERROR"
    # a warning that names this module is a failure of its own (binding loops, undefined assignments)
    if rl_clean "$log" | grep -a -E "WARN|ERROR" | grep -a -E "BridgeService|BridgeConfig|ActionRunner|BridgeModel|bridge_service_probe|BridgeScenarios" | grep -a -v -E "a line was refused|the tool is missing|the previous settings are kept" | head -5 | grep -a .; then rc=1; fi
    # the cast probe never reached a real adb
    if [ -s "$w/adb_called.log" ]; then echo "BSP c: adb was called on the probe's PATH: $(head -c 200 "$w/adb_called.log")"; rc=1; fi
    # the not-live service's stub tool was never run
    if [ -e "$w/a/calls.log" ]; then echo "BSP a: the stub of a not-live service ran: $(head -c 200 "$w/a/calls.log")"; rc=1; fi
    rl_isnoresult "$out" || rm -rf "$tree"
    return $rc
}

if [ "${ARM:-}" = all ]; then
    bad=0
    declare -A NEED=([alwayswatch]="a: no Process of any kind exists, and nothing ran" [twotoasts]="d: exactly one closing toast and one ack per job" [progressstays]="d: the progress toast goes with the closing toast (post, then withdraw)" [seriallate]="b: serial is written last (a handler on serialChanged sees the new devices, jobs, pairing and env)" [openunlock]="u1: the popup opening asks no unlock though a PIN is kept (only a cast lights the phone)" [nohold]="c1: a Mirror started on a phone with a PIN kept walks the transport with --unlock and --hold (the screen held on), then connects -> starts -> goes live, never reconnecting" [nosleep]="c6b: a cast whose picture woke the phone puts it back to sleep at its end (castend --sleep)" [pinargv]="u4: pin set takes the PIN on stdin and nowhere else (not argv, not calls)" [oldended]="k: reconnected (waited 8000 ms)" [noreconnect]="k: reconnected (waited 8000 ms)" [usbagain]="c7b: not again in the same open, a failure included" [reconnectpin]="c2: a cast that ends by itself reconnects (castprep again, WITHOUT --unlock: nobody asked, a phone locked meanwhile stays locked; then a new session after the waits 0.5, 1, 2, 4 s), says 'reconnecting' and holds 'Reconnecting', never 'starting'; live again" [flapforever]="c3: the four tries are shared until a session stays live 10 s: three more (castprep and a session each), then 'failed' with the reason (Try again); no hold left; 'starting' never shown in between" [unlockstart]="c14: bridge.jsonc cast.unlock \"touch\": a Mirror on a phone with a PIN kept starts without --unlock (it still holds the screen)" [sleepkept]="c15: bridge.jsonc cast.sleepAtEnd false: a phone the picture woke is not put back to sleep" [pickhome]="x: bridge.jsonc files.pickDir: the chooser starts in it (~ is the home)" [deskunlock]="c11b: a Desktop cast never unlocks the phone nor holds its screen: castprep without --unlock or --hold though a PIN is kept" [deskrestart]="c12: a settled room change resizes the desktop's screen by the start's factor (resize 1280x2328) and restarts nothing: no new session, no hold, still live" [recordprep]="c16: a recording Mirror (Record on) is the same cast: castprep --unlock --hold --record, and lares-cast --record with the file castprep named; no earlier start recorded" [recordlost]="c16: a recording Mirror (Record on) is the same cast: castprep --unlock --hold --record, and lares-cast --record with the file castprep named; no earlier start recorded" [recordreload]="c17: a recording mirror is not restarted for a new size (a restart would cut the file in two): no new session, no Resizing hold" [recordquiet]="c18: the recording's end is one toast saying where the file went")
    for a in ${ONLY_ARMS:-twotoasts progressstays seriallate alwayswatch openunlock nohold nosleep pinargv oldended noreconnect reconnectpin flapforever usbagain deskrestart deskunlock unlockstart sleepkept pickhome recordprep recordlost recordreload recordquiet}; do
        o=$(run_once "$a"); rc=$?
        if rl_isnoresult "$o"; then echo "ARM $a: did not load (proves nothing)"; bad=1
        elif printf '%s\n' "$o" | grep -aqF "BSP ${NEED[$a]}: FAIL"; then echo "ARM $a: failed as it must (${NEED[$a]})"
        elif [ "$rc" = 0 ]; then echo "ARM $a: still PASSES (toothless)"; bad=1
        else echo "ARM $a: failed, but not at its own check (${NEED[$a]}): $(printf '%s\n' "$o" | grep -a 'BSP .*FAIL' | head -2 | tr '\n' ';')"; bad=1; fi
    done
    echo "$NAME ARMS $([ "$bad" = 0 ] && echo PASS || echo FAIL)"
    exit $bad
fi
out=$(run_once "${ARM:-}"); rc=$?
printf '%s\n' "$out"
if rl_isnoresult "$out"; then
    [ -n "${ARM:-}" ] && echo "ARM ${ARM}: the armed copy did not load -- it proves nothing"
    exit 1
fi
echo "$NAME RESULT $([ "$rc" = 0 ] && echo PASS || echo FAIL)"
exit $rc
}
