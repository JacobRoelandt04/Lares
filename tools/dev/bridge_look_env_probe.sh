#!/usr/bin/env bash
# bridge_look_env_probe.sh -- the bridge popup's FREE LOOK on a real compositor: what an offscreen run cannot show.
# tools/dev/qml/bridge_look_env.qml (the real BridgePopup over the mock service, in a layer window) in the nested Hyprland
# of tools/dev/lock_env.sh (LOCK_ENV=brlook), from a sandbox copy. The runner moves the env's pointer onto the phone, holds
# Alt (wtype), moves the pointer 400 px to the right as a mouse does (relative steps), and lets go.
#
#   tools/dev/bridge_look_env_probe.sh          BRIDGE_LOOK_ENV RESULT PASS | FAIL
#   ARM=nowarp      the harness never asks Hyprland: "the pointer was kept by its start" and "back at its start" red
#   ARM=countjump   the stage counts the jump home as the hand's motion: "the hand's way is counted once" red
#   ARM=scrubcursor the popup's SwipeScrub keeps the Arrow cursor Qt 6.12 gives every MouseArea: "held, the client hides the pointer" red
#                   (the topmost item with a cursor decides the window's; the user saw the pointer during a look, 2026-11-21)
#   ARM=handover    the engine's gesture layer keeps its Arrow cursor: "in the shell, held, the pointer is hidden" red (the user still
#                   saw the pointer after the SwipeScrub cure: in the real shell this window-wide layer decided every cursor)
#   ARM=nocover     the cursor cover never shows: "with hoverCursor off the pointer is the arrow everywhere" red
#   ARM=coverblind  the bar window's cover does not hear of the free look: "with hoverCursor off, held, the pointer is hidden" red
#   ARM=alwayscover the cover shows whatever the setting: "in the shell a button's hand shows" red
#   ARM=all         all seven
#
# THE THIRD PHASE, `hoverCursor` OFF (shell.jsonc; its default): the same running shell, its file rewritten to false (so it is read hot),
# the same motions again. Judged by the requests (WAYLAND_DEBUG=client): no shape but the arrow over the same glyph and tiles that showed a
# hand a moment before, the pointer hidden while Alt is held, shown again after.
#
# THE SECOND PHASE, THE REAL SHELL (tools/dev/bridge_look_shell.py): shell.qml on its mock services in the same env, `hoverCursor` true, with
# Qt's `qt.quick.hover.cursor` log on; the bridge popup opened from its glyph, the pointer onto the phone, Alt held while it moves. Judged
# from what Qt says it sets: no engine layer ever decides the cursor, a hand shows (the glyph, a tile), the pointer is hidden while held
# and shown again after. A harness that hosts the popup alone could not see the engine's layers (it passed while the desktop failed).
#
# JUDGED (the quickshell runs with WAYLAND_DEBUG=client, so its log holds every request it makes): the popup asks for the keyboard once the pointer moved onto it; Alt reaches it (a layer surface, on demand) and
# holds the look; the owner's two Lua expressions are taken by Hyprland (the pointer never strays far while the hand goes
# 400 px, and is back at its start to the pixel when Alt is let go); the 400 px turn the phone by 400 / lookTurnPx, neither
# lost to the put-backs nor doubled by them; let go, the phone rests on the face it showed; held, the client hides the pointer
# (wl_pointer.set_cursor with no surface) and shows it again after. BLE_PATCH='<shell command>' patches the sandbox copy first (an
# ablation, not an arm).
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
if [ "${ARM:-}" = all ]; then
    bad=0
    for a in nowarp countjump scrubcursor handover nocover coverblind alwayscover; do
        o=$(ARM=$a bash tools/dev/bridge_look_env_probe.sh 2>&1)
        case "$a" in nowarp) need="BLE FAIL the pointer was kept by its start" ;; scrubcursor) need="BLE FAIL held, the client hides the pointer" ;;
                     handover) need="BLE FAIL in the shell, held, the pointer is hidden" ;;
                     nocover) need="BLE FAIL with hoverCursor off the pointer is the arrow everywhere" ;;
                     coverblind) need="BLE FAIL with hoverCursor off, held, the pointer is hidden" ;;
                     alwayscover) need="BLE FAIL in the shell a button's hand shows" ;;
                     *) need="BLE FAIL the hand's way is counted once" ;; esac
        if printf '%s\n' "$o" | grep -aq "(no result"; then echo "ARM $a: did not load (proves nothing)"; bad=1
        elif printf '%s\n' "$o" | grep -aq "$need"; then echo "ARM $a: failed as it must"
        else echo "ARM $a: its own check did not fail: $(printf '%s\n' "$o" | tail -3 | tr '\n' ';')"; bad=1; fi
    done
    echo "BRIDGE_LOOK_ENV ARMS $([ "$bad" = 0 ] && echo PASS || echo FAIL)"
    exit $bad
fi
mkdir -p "${SCRATCH:-/tmp}"
D="$(mktemp -d "${SCRATCH:-/tmp}/ble.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
ARMCMD=""
case "${ARM:-}" in
    "") ARMCMD="${BLE_PATCH:-}" ;;
    nowarp)    ARMCMD="sed -i '/Hyprland.dispatch(Look.expr(what));/d' tools/dev/qml/bridge_look_env.qml" ;;
    handover) ARMCMD="sed -i 's|^                id: handOver\$|                id: handOver\n                cursorShape: Qt.ArrowCursor|' modules/bar/gooey/GooeyEngine.qml" ;;
    nocover) ARMCMD="sed -i 's|^    visible: !ShellCursor.hover\$|    visible: false|' modules/shell/cursor/CursorCover.qml" ;;
    coverblind) ARMCMD="sed -i 's/^        hidden: screenFrame.engine.pointerHidden || sideSwipe.hiding\$/        hidden: sideSwipe.hiding/' modules/shell/ShellScreen.qml" ;;
    alwayscover) ARMCMD="sed -i 's|^    visible: !ShellCursor.hover\$|    visible: true|' modules/shell/cursor/CursorCover.qml" ;;
    scrubcursor) ARMCMD="sed -i 's|^    id: sc\$|    id: sc\n    cursorShape: Qt.ArrowCursor|' modules/common/components/SwipeScrub.qml" ;;
    countjump) ARMCMD="sed -i 's|if (stage._lookWarpDue \&\& Math.hypot(pt.x - ax, pt.y - ay) < 0.4 \* stage.lookStrayPx) {|if (false) {|' modules/bridge/body/PhoneStage.qml" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-bridge-look}"
export LOCK_ENV="${LOCK_ENV:-brlook}"
OUTPUTS=1 tools/dev/lock_env.sh up > "$D/up.log" 2>&1 || { cat "$D/up.log"; echo "BRIDGE_LOOK_ENV RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
LL="$D/live.log"
SL="$D/shell.log"
cat > "$D/live.sh" <<LIVE_EOF
ARMED="tools/dev/qml/bridge_look_env.qml modules/bridge/body/PhoneStage.qml modules/common/components/SwipeScrub.qml modules/bar/gooey/GooeyEngine.qml modules/shell/cursor/CursorCover.qml modules/shell/ShellScreen.qml"
before=\$(cat \$ARMED | md5sum)
${ARMCMD:-true}
if [ -n "${ARM:-}" ] && [ "\$(cat \$ARMED | md5sum)" = "\$before" ]; then echo ARMLOST; exit 3; fi
tools/dev/lock_env.sh run env WAYLAND_DEBUG=client quickshell -p tools/dev/qml/bridge_look_env.qml > $LL 2>&1 &
QP=\$!
pt() { tools/dev/lock_env.sh point "\$@"; }
pos() { tools/dev/lock_env.sh hyprctl cursorpos | tr -d ' '; }
waitfor() { for i in \$(seq 1 \$2); do grep -aq "\$1" $LL && return 0; sleep 0.1; done; return 1; }
waitfor "BLE ready" 300 || { kill \$QP; exit 0; }
read cx cy <<< "\$(grep -a -o 'BLE ready .*' $LL | head -1 | sed 's/BLE ready //')"
pt "abs \$((cx - 12)) \$((cy - 8)) 2880 1620"
sleep 0.2
pt "abs \$((cx - 6)) \$((cy - 4)) 2880 1620" "sleep 60" "abs \$cx \$cy 2880 1620"
waitfor "BLE keys onDemand" 30
sleep 0.3
# (the keyboard comes to a layer surface with a pointer MOTION after it asked)
pt "abs \$((cx + 1)) \$cy 2880 1620" "sleep 60" "abs \$cx \$cy 2880 1620"
sleep 0.4
pos > $D/pos.start
# Alt held for 6 s by a keyboard of its own: the modifier and the key, as a real keyboard sends both
tools/dev/lock_env.sh run wtype -M alt -P Alt_L -s 6000 -p Alt_L -m alt > $D/wtype.log 2>&1 &
WT=\$!
waitfor "BLE held" 30
sleep 0.5
for i in \$(seq 1 40); do pt "rel 10 0" "sleep 20"; done
sleep 0.3
pos > $D/pos.during
wait \$WT
waitfor "BLE rest" 40
sleep 0.3
pos > $D/pos.end
kill \$QP; wait \$QP 2> /dev/null
# ---- the second phase: the real shell
tools/dev/lock_env.sh hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar\$" }, no_anim = true })' > /dev/null
mkdir -p $D/state/lares-shell-mock/config
printf '{ "hoverCursor": true }\n' > $D/state/lares-shell-mock/config/shell.jsonc
tools/dev/lock_env.sh run env XDG_STATE_HOME=$D/state WAYLAND_DEBUG=client SHELL_SERVICES=mock QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 QT_LOGGING_RULES="qt.quick.hover.cursor.debug=true" quickshell -n -p \$PWD/shell.qml > $SL 2>&1 &
SP=\$!
for _ in \$(seq 1 400); do grep -aq "LARES settled" $SL && break; kill -0 \$SP 2> /dev/null || break; sleep 0.3; done
grep -aq "LARES settled" $SL && timeout 150 python3 tools/dev/bridge_look_shell.py "\$PWD" "\$PWD/shell.qml" > $D/drive.log 2>&1
# ---- the third phase: hoverCursor off, hot, in the same shell
wc -c < $SL > $D/shell.split
printf '{ "hoverCursor": false }\n' > $D/state/lares-shell-mock/config/shell.jsonc
sleep 2
grep -aq "DRV done" $D/drive.log && timeout 150 python3 tools/dev/bridge_look_shell.py "\$PWD" "\$PWD/shell.qml" > $D/drive3.log 2>&1
kill \$SP; wait \$SP 2> /dev/null; true
LIVE_EOF
tools/dev/sandbox.sh bash "$D/live.sh" > "$D/live.run" 2>&1
tools/dev/lock_env.sh down > /dev/null 2>&1
grep -aq ARMLOST "$D/live.run" && { echo "BRIDGE_LOOK_ENV RESULT FAIL (the ARM's anchor is gone)"; exit 1; }
rl_has "$LL" 'BLE ready' || { cp "$LL" "${SCRATCH:-/tmp}/bridge_look_env.log" 2> /dev/null; echo "BRIDGE_LOOK_ENV RESULT FAIL (no result: ${SCRATCH:-/tmp}/bridge_look_env.log)"; exit 1; }
python3 -B - "$D" "$LL" "$SL" <<'PY'
import re, sys
d, log, slog = sys.argv[1], sys.argv[2], sys.argv[3]
txt = re.sub(r"\x1b\[[0-9;]*m", "", open(log, errors="replace").read())
def pos(name):
    try:
        x, y = open("%s/pos.%s" % (d, name)).read().strip().split(",")
        return float(x), float(y)
    except Exception:
        return None
fails = 0
def say(ok, what):
    global fails
    fails += 0 if ok else 1
    print("BLE %s %s" % ("ok  " if ok else "FAIL", what))
s, m, e = pos("start"), pos("during"), pos("end")
say("BLE keys onDemand" in txt, "the popup asks for the keyboard once the pointer moved onto it")
say("BLE held" in txt, "Alt, held, reaches the layer surface and holds the look")
say(txt.count("BLE ask hold") == 1 and txt.count("BLE ask home") >= 3, "the owner is asked to hold the place once and to put the pointer back as it strays (%d hold, %d home)" % (txt.count("BLE ask hold"), txt.count("BLE ask home")))
far = None if not (s and m) else ((m[0] - s[0]) ** 2 + (m[1] - s[1]) ** 2) ** 0.5
say(far is not None and far < 120, "the pointer was kept by its start while the hand went 400 px (start %s, then %s)" % (s, m))
let = re.search(r"BLE let yaw=(-?[0-9.]+) pitch=(-?[0-9.]+)", txt)
yaw = float(let.group(1)) if let else None
say(yaw is not None and abs(yaw + 400 / 520.0) < 0.08 and abs(float(let.group(2))) < 3, "the hand's way is counted once: 400 px right is %.3f turns (let go at %s)" % (-400 / 520.0, yaw))
say(s is not None and e is not None and abs(e[0] - s[0]) <= 1 and abs(e[1] - s[1]) <= 1, "let go, the pointer is back at its start to the pixel (start %s, end %s)" % (s, e))
say("BLE rest face=front ex=1" in txt, "and the phone rests on the face it showed")
# THE POINTER ITSELF, as the client tells the compositor (WAYLAND_DEBUG=client): a nested Hyprland's screen copy carries no cursor (its
# host draws it), so the hide is judged by the request that makes it -- wl_pointer.set_cursor with no surface -- after the hold, and a
# shape put back after the let-go
held_at = txt.find("BLE held")
let_at = txt.find("BLE let ")
during = txt[held_at:let_at] if held_at >= 0 and let_at > held_at else ""
after = txt[let_at:] if let_at >= 0 else ""
hid = re.search(r"wl_pointer#\d+\.set_cursor\(\d+, nil", during)
back = re.search(r"(cursor_shape_device_v1#\d+\.set_shape|wl_pointer#\d+\.set_cursor\(\d+, wl_surface)", after)
say(hid is not None, "held, the client hides the pointer (wl_pointer.set_cursor with no surface)")
say(back is not None, "let go, it shows it again")
warn = [l for l in txt.splitlines() if re.search(r"WARN|ERROR", l) and re.search(r"modules/bridge|bridge_look_env|Binding loop|Unable to assign|non-existent|TypeError|ReferenceError|Lua|syntax", l)]
say(not warn, "no warning names the bridge or the Lua" + ("" if not warn else ": " + warn[0][:160]))
# the second phase: what Qt says it sets as the real shell's cursor
try:
    sraw = open(slog, "rb").read()
    split = int(open("%s/shell.split" % d).read())
except (OSError, ValueError):
    sraw, split = b"", 0
clean = lambda b: re.sub(r"\x1b\[[0-9;]*m", "", b.decode(errors="replace"))
stxt, stxt3 = clean(sraw[:split]), clean(sraw[split:])
try:
    drv = open("%s/drive.log" % d, errors="replace").read()
except OSError:
    drv = ""
sets = re.findall(r"setting cursor QCursor\(Qt::CursorShape\(Qt::(\w+)\)\) from .*?(?:id=\"(\w+)\")?, (?:parent|geometry)", stxt)
shapes = [s for s, _ in sets]
say("LARES settled" in stxt and '"owner": "bridge"' in drv and "DRV done" in drv,
    "in the shell (mock services) the bridge popup opened from its glyph and the look was driven (%s)" % (drv.strip().splitlines()[-1][:80] if drv.strip() else "no driver output"))
engine = [i for _, i in sets if i in ("handOver", "gestureLayer")]
say(not engine, "in the shell no engine layer decides the cursor (%d settings by %s)" % (len(engine), sorted(set(engine))))
say("PointingHandCursor" in shapes, "in the shell a button's hand shows (cursors set: %s)" % shapes)
last_blank = max([i for i, s in enumerate(shapes) if s == "BlankCursor"], default=-1)
say(last_blank >= 0, "in the shell, held, the pointer is hidden")
say(last_blank >= 0 and any(s != "BlankCursor" for s in shapes[last_blank + 1:]), "in the shell, let go, it shows again")
# the third phase, as the client tells the compositor: 1 is the default arrow (cursor-shape-v1), nil the hidden pointer
try:
    drv3 = open("%s/drive3.log" % d, errors="replace").read()
except OSError:
    drv3 = ""
REQ = r"cursor_shape_device_v1#\d+\.set_shape\(\d+, (\d+)\)|wl_pointer#\d+\.set_cursor\(\d+, (nil|wl_surface)"
req2 = [a or b for a, b in re.findall(REQ, stxt)]
req3 = [a or b for a, b in re.findall(REQ, stxt3)]
say("DRV done" in drv3 and '"owner": "bridge"' in drv3, "with hoverCursor off (the file rewritten under the running shell) the same motions were driven")
say("4" in req2, "with hoverCursor on the client asked for the hand over these same places (asked: %s)" % req2)
say(len(req3) > 0 and all(r in ("1", "nil") for r in req3), "with hoverCursor off the pointer is the arrow everywhere (asked: %s)" % req3)
last_nil = max([i for i, r in enumerate(req3) if r == "nil"], default=-1)
say(last_nil >= 0, "with hoverCursor off, held, the pointer is hidden")
say(last_nil >= 0 and "1" in req3[last_nil + 1:], "with hoverCursor off, let go, it shows again")
warn3 = [l for l in (stxt + stxt3).splitlines() if re.search(r"WARN|ERROR", l) and re.search(r"CursorCover|ShellCursor|hoverCursor|pointerHidden", l)]
say(not warn3, "no warning names the cursor setting" + ("" if not warn3 else ": " + warn3[0][:160]))
print("BRIDGE_LOOK_ENV RESULT %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
sys.exit(1 if fails else 0)
PY
rc=$?
[ "$rc" = 0 ] || cp "$LL" "${SCRATCH:-/tmp}/bridge_look_env.log" 2> /dev/null
exit $rc
