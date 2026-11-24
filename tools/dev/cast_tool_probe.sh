#!/usr/bin/env bash
# The REAL tools/panorama/lares-cast against STUB fluxcast / xrandr / nmcli / ffmpeg in a private world -- never the real fluxcast, the
# desktop's Hyprland, NetworkManager or a TV (checks: tools/dev/fixtures/cast/tool_harness.py).
#
#   tools/dev/cast_tool_probe.sh                 ends in CAST_TOOL RESULT PASS|FAIL
#   ARM=<name> tools/dev/cast_tool_probe.sh      a fault in a COPY of tools/panorama; must FAIL on its needle
#   ARM=all                                      every ARM; CAST_TOOL ARMS RESULT PASS when each failed as it must
#     noretrycap   an activation timeout is retried every time     -> "c: twice a timeout makes one retry only"
#     noshim       the shim is never made                          -> "d: with the shim (fluxcast 0.3.0) it streams"
#     orphan       what fluxcast left in its session is not reaped -> "e: (INT ends it) the tool ends with ended, and no recorded child"
#     nowaitwifi   the retry does not wait for the Wi-Fi device    -> "b: the retry waits for the Wi-Fi device"
#     nounbuffered fluxcast is not run unbuffered (a pipe buffers) -> "a: figures arrive live"
#     nokill       a fluxcast deaf to INT is never killed          -> "e: (deaf to INT"
#     nomonitorchk the monitor is not checked                      -> "f: an unknown --monitor is refused"
#     nolinkwatch  a group that goes is not noticed                -> "i: a link that dies is noticed"
#     nostall      a stream that sends nothing is not noticed      -> "i: nothing sent while the link stands"
#     relink       a dead link is made again for ever              -> "i: a link that dies twice"
#     nohold       the Wi-Fi profile is not held                   -> "j: held before fluxcast runs"
#     ondisk       the lock is written to the profile's file       -> "j: no change was written to disk"
#     nogive       the profile is not given back                   -> "j: given back after the stop"
#     upwithgroup  the hold reconnects whatever group is up        -> "j: with a group up already"
#     stealhold    restore takes a live cast's hold                -> "j: restore leaves a live"
#     dropshold    a restart's stop gives the hold back            -> "j: a restart's stop keeps the hold"
#     notakeover   the next start does not make the record its own -> "j: the next start takes the hold over"
#     handoverstays  restore --now leaves a handed-over hold       -> "j: restore --now gives back"
#     nomonitorwait the tool does not wait for xrandr to list a just-created output -> "f: an output xrandr lists only on its 5th look"
#     noprogress   the sender is not asked for its progress -> "k: the sender"
#     early        figures before the stream is up -> "k: none before the stream is up"
#     zerototals   a reconnect starts the totals again -> "k: the totals run over the reconnect"
#     carried      the last link's samples stand in the next one's rates -> "k: a live figure is not carried"
#     nobehind     how far behind is measured against the last look, not the best -> "k: an encoder that cannot keep up"
#     allkeys      a figure with no source is there all the same -> "k: a figure with no source has no key"
#     everybeat    the radio is asked at every beat -> "k: the radio is asked less often"
#     echoforever  a TV that answers no echo is asked for ever -> "k: a TV that never answers"
#     nolost       a lost link is not said before the retry -> "k: a stream that was up is said lost"
#     everyline    every set goes into the transcript -> "k: the transcript has a set now and then"
#     noaverage    the transcript has no averages -> "k: the transcript has the cast"
#   The clean run hands the tool's real lines (a whole cast with its figures) to the shell's own reader: node tools/dev/cast_parse_cases.js --lines.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
NAME=CAST_TOOL
. tools/dev/result_lib.sh

arm_needle() {
    case "$1" in
        noretrycap) echo 'c: twice a timeout makes one retry only' ;;
        noshim) echo 'd: with the shim \(fluxcast 0.3.0\) it streams' ;;
        orphan) echo 'e: \(INT ends it\) the tool ends with ended' ;;
        nowaitwifi) echo 'b: the retry waits for the Wi-Fi device' ;;
        nounbuffered) echo 'a: figures arrive live' ;;
        nokill) echo 'e: \(deaf to INT' ;;
        nomonitorchk) echo 'f: an unknown --monitor is refused' ;;
        nolinkwatch) echo 'i: a link that dies is noticed' ;;
        nostall) echo 'i: nothing sent while the link stands' ;;
        relink) echo 'i: a link that dies twice' ;;
        nohold) echo 'j: held before fluxcast runs' ;;
        ondisk) echo 'j: no change was written to disk' ;;
        nogive) echo 'j: given back after the stop' ;;
        upwithgroup) echo 'j: with a group up already' ;;
        stealhold) echo 'j: restore leaves a live' ;;
        dropshold) echo "j: a restart's stop keeps the hold" ;;
        notakeover) echo 'j: the next start takes the hold over' ;;
        handoverstays) echo 'j: restore --now gives back' ;;
        nomonitorwait) echo 'f: an output xrandr lists only on its 5th look' ;;
        noprogress) echo 'k: the sender' ;;
        early) echo 'k: none before the stream is up' ;;
        zerototals) echo 'k: the totals run over the reconnect' ;;
        carried) echo 'k: a live figure is not carried' ;;
        nobehind) echo 'k: an encoder that cannot keep up' ;;
        allkeys) echo 'k: a figure with no source has no key' ;;
        everybeat) echo 'k: the radio is asked less often' ;;
        echoforever) echo 'k: a TV that never answers' ;;
        nolost) echo 'k: a stream that was up is said lost' ;;
        everyline) echo 'k: the transcript has a set now and then' ;;
        noaverage) echo 'k: the transcript has the cast' ;;
    esac
}

run_one() { # run_one <arm|""> -> prints the harness log, returns its status
    local arm=$1 T tool
    T=$(mktemp -d /tmp/lrct.XXXXXX) || return 1
    cp -r tools/panorama "$T/panorama"
    tool=$T/panorama/lares-cast
    patch() { python3 - "$tool" "$1" "$2" <<'PY'
import sys
p, a, b = sys.argv[1:]
s = open(p).read()
if s.count(a) != 1:
    sys.exit("ARM anchor gone: " + a)
open(p, "w").write(s.replace(a, b))
PY
    }
    case "$arm" in
        "") ;;
        noretrycap) patch 'RETRIES = {"activation": 1, "link": 1}' 'RETRIES = {"activation": 9, "link": 1}' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        noshim) patch '    return tuple(int(x) for x in version.split(".")) <= (0, 3, 0)' '    return False' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        orphan) patch '    """Whatever fluxcast left in its session (a recorder, an ffmpeg) goes with it."""' '    return' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        nowaitwifi) patch ' and wifi_back(fenv("LARES_CAST_WIFI_WAIT", 20)):' ':' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        nounbuffered) patch 'env = dict(os.environ, PYTHONUNBUFFERED="1", LARES_CAST_DROP' 'env = dict(os.environ, LARES_CAST_DROP' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        nokill) patch '            os.killpg(ch.pid, signal.SIGKILL)' '            pass' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        nomonitorchk) patch '    if not wait_monitor(mon):' '    if False:' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        nomonitorwait) patch '    end = time.time() + fenv("LARES_CAST_MONITOR_WAIT", 3)' '    end = 0' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        nolinkwatch) patch 'if streamed and gone_at is not None and now - gone_at >= grace:' 'if False:' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        nostall) patch 'if streamed and now - sent_at >= stall:' 'if False:' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        relink) patch 'RETRIES = {"activation": 1, "link": 1}' 'RETRIES = {"activation": 1, "link": 9}' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        nohold) patch '            why = hold_take()' '            why = "off"' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        ondisk) patch '"modify", "--temporary", "uuid"' '"modify", "uuid"' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        nogive) patch '        if KEEP_HOLD[0]:
            hold_pass()
        else:
            hold_give()' '        if KEEP_HOLD[0]:
            hold_pass()' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        dropshold) patch '        if KEEP_HOLD[0]:
            hold_pass()
        else:
            hold_give()' '        hold_give()' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        notakeover) patch '            if not record_write(dict(r, pid=os.getpid(), handover=0)):
                return "no record"' '            pass' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        handoverstays) patch '    if not now and 0 <= age < HANDOVER_S:
        return' '    if 0 <= age < HANDOVER_S:
        return' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        upwithgroup) patch '    if not wait_no_group():
        return' '    if False:
        return' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        stealhold) patch '    if not r or cast_alive(r.get("pid")):
        return' '    if not r:
        return' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        noprogress) patch '            env["LARES_CAST_PROGRESS"] = os.path.join(tmp, "progress")' '            pass' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        early) patch '        elif "P2P link is activated" in text:
' '        elif "P2P link is activated" in text:
            fig.came_up(time.monotonic())
' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        zerototals) patch '            self.done[k] += self.run[k]
' '' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        carried) patch '        self.samples = []
        self.next_sender()' '        self.samples = getattr(self, "samples", [])
        self.next_sender()' && patch '        self.samples = [x for x in self.samples if now - x[0] <= (WINDOW + 0.5) * BEAT] +' '        self.samples = self.samples +' && patch '            self.net, self.samples, self.tx0 = net, [], None' '            self.net, self.tx0 = net, None' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        nobehind) patch '            self.off = off if self.off is None else min(self.off, off)' '            self.off = off' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        allkeys) patch '            if k in self.known:
' '            if True:
' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        everybeat) patch 'IW_EVERY = 5 ' 'IW_EVERY = 1 ' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        echoforever) patch '        if self.sum["asked"] >= ECHO_TRIES and self.sum["rtt_n"] == 0:' '        if False:' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        nolost) patch '                emit({"event": "lost"})  ' '                pass  ' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        everyline) patch '            emit(ev, keep=False)' '            emit(ev)' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        noaverage) patch '                log(ctx.fig.summary())' '                pass' || { echo "ARM anchor gone"; rm -rf "$T"; return 3; } ;;
        *) echo "unknown ARM $arm"; rm -rf "$T"; return 3 ;;
    esac
    TOOLDIR=$T/panorama STUBS=$ROOT/tools/dev/fixtures/cast CT_SEAM=$T/lines timeout 300 python3 -I "$ROOT/tools/dev/fixtures/cast/tool_harness.py" > "$T/log" 2>&1
    local rc=$?
    cat "$T/log"
    # the seam: the tool's own lines through CastParse.js
    if [ -z "$arm" ]; then node tools/dev/cast_parse_cases.js --lines "$T/lines" || rc=1; fi
    rm -rf "$T"
    return $rc
}

if [ "${ARM:-}" = all ]; then
    bad=0
    for a in noretrycap noshim orphan nowaitwifi nounbuffered nokill nomonitorchk nomonitorwait nolinkwatch nostall relink nohold ondisk nogive upwithgroup stealhold dropshold notakeover handoverstays \
             noprogress early zerototals carried nobehind allkeys everybeat echoforever nolost everyline noaverage; do
        out=$(ARM=$a "$0" 2>&1); needle=$(arm_needle "$a")
        if echo "$out" | grep -a -q "ARM anchor gone"; then echo "ARM $a: anchor gone"; bad=1
        elif echo "$out" | grep -a -E -q "^CT FAIL $needle"; then echo "ARM $a: failed as it must"
        else echo "ARM $a: DID NOT BITE ON ITS NEEDLE"; echo "$out" | grep -a 'CT FAIL' | head -3; bad=1; fi
    done
    [ $bad = 0 ] && { echo "CAST_TOOL ARMS RESULT PASS"; exit 0; }
    echo "CAST_TOOL ARMS RESULT FAIL"; exit 1
fi

log=$(mktemp /tmp/lrctlog.XXXXXX)
run_one "${ARM:-}" > "$log" 2>&1
rc=$?
cat "$log"
if [ -n "${ARM:-}" ]; then
    rm -f "$log"
    [ $rc = 3 ] && { echo "CAST_TOOL RESULT FAIL (ARM $ARM: anchor gone)"; exit 1; }
    echo "CAST_TOOL RESULT FAIL (armed $ARM)"; exit 1
fi
if ! grep -a -q '^CT RESULT' "$log"; then
    echo "CAST_TOOL RESULT FAIL (no result: $log)"; exit 1
fi
rm -f "$log"
[ $rc = 0 ] && { echo "CAST_TOOL RESULT PASS"; exit 0; }
echo "CAST_TOOL RESULT FAIL"; exit 1
