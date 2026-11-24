#!/usr/bin/env bash
# silicon's data layer end to end, headless, on a FAKE machine, in the sandbox.
#
#   tools/dev/silicon_service_probe.sh                 last line: SILICON-SERVICE RESULT PASS|FAIL
#   HELPER=real tools/dev/silicon_service_probe.sh     the same, against the REAL helper in test mode -- built from the
#                                                  tree (cargo build --release into a private target dir, so a
#                                                  half-edited helper is found out and a stale binary never used)
#   PHASES="nohelper" tools/dev/silicon_service_probe.sh    a subset (main hidden nohelper mock boot mux update)
#   HELPER_SRC=<dir>   build the helper from this copy instead of helpers/silicon_helper (a `git archive` of HEAD,
#                      when the tree's own is mid-edit)
#   ARM=<name>      a fault put into the SANDBOX copy of the data layer; the run must end FAIL
#   ARM=all         every ARM below; SILICON-SERVICE ARMS PASS when each one failed
#   ARM_CHECK=1 ARM=<name>   only apply the fault to the sandbox copy and say whether its anchor was found (once)
#
#     nosmigate    nvidia-smi no longer waits for a user of the dGPU (only for the card to be awake)
#                                                                -> smi-only-with-holders FAILS
#     nosettle     a profile write goes out at once, no 300 ms settle -> burst-one-write FAILS
#     silentwrite  a refused / mismatched write is not surfaced -> refused-* checks FAIL
#     noexternal   a change made outside the popup is not noticed -> external-* checks FAIL
#     statuspoll   the helper's status is asked every 2 s while the popup is open again (round 5's cadence; it reads the
#                  GPU MUX through the ASUS firmware, into the EC)                     -> status-quiet FAILS
#     freebattery  the battery is read again by a free-running timer, as before round 8 C1 -> beat-on-beat / beat-same-beat FAIL
#     noknobs      the kernel's own copies of the knobs are not read: an outside change waits for the minute's
#                  status backstop                                                     -> status-on-knob / external FAIL
#     resumeapply  every resume re-applies the old state, changed or not -> resume-nothing FAILS
#     holdstays    a manual change leaves the hold in place   -> hold-manual-wins FAILS
#     nofallback   no notification when the OSD is not there  -> external-osd-fallback FAILS
#     smiasleep    nvidia-smi runs for a holder though the card sleeps -> smi-never-asleep FAILS
#     noacsignal   the mains flag change is not signalled    -> battery-unplug FAILS
#     nostall      "Charging" with 0 W is never called stalled   -> battery-stall (the caption, the adapter) FAILS
#     stallsticks  a stall is not cleared when the flow returns -> battery-stall-clears FAILS
#     stallnow     the stall time is ignored (a dip is a stall)  -> battery-stall-not-yet / battery-stall-dip FAIL
#     cpustrand    a CPU write's end waits for EVERY pending write before it settles its target
#                                                                -> limit-no-stranded-target FAILS
#     limitflip    a limit write's end settles the switch though a newer flip waits -> limit-flip-target FAILS
#     limitown     only a lone ask is recognised when the limit lands -> limit-flip-not-news FAILS
#     resumelimit  a limit put back after a resume is announced when it lands -> resume-not-external FAILS
#     resumewindow a limit the firmware reset in a suspend is announced as external -> resume-not-external FAILS
#     fullopen     opening the popup asks cardwire for everything again (not mode, power, users) -> popup-open-light FAILS
#     silentmux    a MUX request the helper refuses (the pre-checks, the unit not running) is not surfaced -> mux-precheck FAILS
#     ignorestale  the service builds its facts without the ignored apps (the rows and gpu.ignoredApps stay as they were)
#                                                                -> gpu-ignored-facts FAILS            (phase main)
#   the MUX, end to end (phase mux), and the system update's hold under the real supervisor (phase update):
#     autokeep     showing the keep prompt also keeps the switch (no click needed) -> mux-no-click-yet FAILS
#     deafclick    the click on Keep sends nothing                   -> mux-click-keeps FAILS
#     noprompt     the prompt's two minutes never start              -> mux-prompt-two-minutes FAILS
#     twice        the seen mark is not remembered across a restart (the outcome would be told again at every login)
#                                                                -> mux-silenced FAILS
#     unmarked     the outcome is never marked seen                  -> the watcher's step (told once, marked) FAILS
#     noholdreal   a live run never takes the hold                   -> update-real-holds FAILS
#     earlyopen    a service created with its popup already open asks cardwire before its bus is set (one call to the
#                  DEFAULT bus, the system one: the guard shim refuses it) -> invariant.no-refusals FAILS
#   round 2 (R2 D5 the memory, I1 the way back from dGPU-only to every mode):
#     nomemory     the stats poll never reads /proc/meminfo                -> the stats step "the memory" FAILS (phase main)
#     noshutholders  with the popup shut nothing reads who is on the card     -> the step "something opens the card" FAILS (phase main)
#     noplug       a plug switches nothing (silicon.jsonc onPower)   -> onpower-battery FAILS            (phase main)
#     norebase     a plug during a hold changes the profile at once -> onpower-held FAILS              (phase main)
#     cardwireonly a step away from a queued dGPU-only request only sets cardwire (today's behaviour) -> mux-away-hybrid FAILS (phase main)
#     noargv       muxRebootNow ignores rebootArgv                           -> mux-argv FAILS                   (phase main)
#     noafterapply the mode asked for after the restart is never set        -> mux-after-landed FAILS            (phase mux)
#     afterguess   at login, before the helper has answered, the record is read as absent and the mode forgotten
#                                                                -> mux-after-landed FAILS            (phase mux)
#     afterlost    the mode asked for is not written to SiliconState        -> mux-after-remembered FAILS        (phase mux)
#   round 3 (T2 since last full from UPower's charge history; all phase main):
#     noupower     the service's gdbus is not there (it never reaches UPower) -> the start step (the history was asked ONCE) FAILS
#     noevent      a full event does not ask UPower again                   -> battery-full-upower FAILS
#     noresumeup   a resume does not ask UPower again                       -> resume-upower FAILS
#     leaveedge    a pack that stops being full is not the last moment it was -> battery-leave FAILS
#     upthrottle   the popup-driven asks have no gap (every unforced ask is made) -> upower-throttle FAILS
#     upsilent     a failed ask has no stated reason                        -> upower-notrunning FAILS
#     upnocheck    gdbus is started without looking for it first (a missing binary warns in the log) -> main.warnings FAILS
#   Qt 6.12 (the per-core loads vanished from the popup, found 2026-10-24; phase main):
#     rawcores     the stats' `cores` goes into the model as it came over the signal (a list wrapper, not a JS array)
#                                                                -> the stats step "the clock ... " (cores.length) / stats-core-kinds FAIL
#   round 4 (call 4: the UPower fixtures; D1 the HDMI fact, phase main):
#     upemptyweek  the stand-in answers the committed (synthetic) week with an empty history -> start-upower-moment FAILS
#     dockcounts   any card's HDMI-A / DVI-I connector counts as the HDMI fact, whoever's card it is -> display-dock FAILS
#     nomonitor    the udev monitor is never started (the fact is read at start only)                -> the display plug step FAILS
#     eventscan    every udev event is a scan of its own (no debounce)                              -> display-burst-one-scan FAILS
#     norefreshdisplay  a refresh (a resume) does not read the connectors again                      -> the display refresh step FAILS
#   round 3 (the charge glyph's delay: a power_supply udev event is a battery read now; phase main):
#     nopower      a power event reads nothing (the battery waits for the beat, as before)            -> power-unplug-one-read FAILS
#     nopgap       no gap between the reads events ask for                                            -> power-gap-waits FAILS
#     nopdebounce  every udev line is an event of its own (no debounce)                               -> power-burst-one-read FAILS
#   round 3 (the dGPU's harmless holders are silicon.json's `gpu.ignoredHolders`; phase main):
#     noignorecfg  the service never hands the file's list to the daemon's client (the built-in list always applies)
#                                                                                                     -> gpu-ignored-holders-config FAILS
#     ownsmi       the shell's own nvidia-smi query counts as a user of the dGPU (the GPU bug's loop)       -> gpu-own-smi-not-a-user FAILS
#   round 5 (W1 the busy-dGPU warning, X1 the way back, phase main / mux):
#     nosession    the session's own processes (Hyprland, Xwayland, Xorg, systemd, systemd-logind), which hold the card's nodes while it
#                  sleeps, count as users of the dGPU again                  -> gpu: "someone opens the dGPU" / gpu-session-not-users FAIL
#     afterreply   the mode asked for after the way back is written when the helper REPLIES, from the last request's own step (the old
#                  handler), not where it is asked: a late answer lands over a newer re-aim -> mux-after-last-ask-wins FAILS   (phase mux)
#     afterreplymock  the same fault in the mock                                                  -> mock-after-last-ask-wins FAILS  (phase mock)
#     nosessionlogin  the same fault, run in the MUX phase: the mode asked for after a way back from dGPU-only is refused at the
#                  next login by the holders rule (the session is "using" the card), as it was on the user's laptop
#                                                                -> mux-after-landed FAILS            (phase mux)
#   round 8 (the FAN GUARD, phase fan: FanGuard.qml; the platform profile written again after a resume and when the CPU is hot for no reason the load gives):
#     noload       the guard ignores the load (every sample reads as an idle machine)   -> fan-heavy-no-fire FAILS: 95 degrees under a heavy load fires
#     nokick       the kick writes nothing (resume's and the guard's)                   -> fan-kick-pair / fan-resume-one-kick FAIL
#     nobaseline   the guard never consults what it learned (only the extreme case)     -> the 92 degrees at a light load never fires: the kick step times out
#     kickmanual   the kick counts as a manual profile change (drops every hold)        -> fan-kick-keeps-hold FAILS
#     viashown     the kick's intermediate profile is published like any answer         -> fan-kick-never-shown FAILS
#   Q16 (the boot profile: silicon.jsonc's `defaultProfile` is STORED as the helper's boot set, never applied; phase boot):
#     noboot       the service never asks `set-boot`                -> the start step (stored) / boot-stored-once FAIL
#     bootapply    the service also APPLIES the profile when it stores it (the profile would change as the shell starts)
#                                                                -> boot-no-apply-start FAILS
#
# WHAT RUNS. A PRIVATE session bus (tools/dev/notifications_bus.sh: no service directories, so nothing is
# ever activated) with the cardwire stand-in on it (tools/dev/stubs/silicon/cardwire_stub.py); a COPY of
# tools/dev/fixtures/silicon/data (this machine's captured /sys with the volatile files added) that the
# helper stand-in (tools/dev/stubs/silicon/silicon-helper) or the real binary reads and writes in TEST MODE;
# and tools/dev/stubs/silicon/shims first on PATH: pkexec (runs ONLY the helper, ONLY with --sysfs-root,
# unprivileged), systemctl, nvidia-smi, pw-play, notify-send, and a busctl / gdbus guard that refuses
# the system bus. Every shim logs every call to $OUT/logs.
#
# THE MUX PHASE runs the service against the REAL helper (the stand-in has no shutdown or boot half) in test mode:
# request dGPU only -> queued -> "Restart now" (systemctl is a stub: the REBOOT_REQUESTED marker) -> the machine goes down
# (the shell is destroyed; the probe runs the shutdown unit's `mux-apply` through tools/dev/stubs/silicon/shims/silicon-unit)
# -> boots (a new boot id, the connectors wired as the firmware now says, `mux-guard` running as its unit would) -> a
# new shell finds the record awaiting a keep -> the prompt is shown once (two minutes from now) -> a click keeps it; and
# again with no click: the guard reverts at the deadline (the fake /proc/uptime moves past it), writes hybrid and asks
# for ONE reboot, the next shell tells the user ONCE and marks the outcome seen, and the one after that says nothing.
# The way back (with the NVIDIA stack up) and a dGPU request with the stack up (refused at shutdown, nothing written)
# are in it too. THE UPDATE PHASE drives the real helpers/update-run.sh (a `sleep` for yay, systemd-inhibit stubbed)
# against the real /proc: a run holds Performance, a manual change wins, the hold ends with the run. THE BOOT PHASE (Q16)
# runs shells against the REAL helper in test mode too: `defaultProfile` -> ONE set-boot with that profile's linked values,
# stored in the fake state dir's boot.json; a second shell writes nothing; quiet and an edit of its row write again; no key
# writes and clears nothing; a refusal is said once and not asked again; and no `apply` anywhere in it.
#
# WHAT THE RUNNER ADDS TO THE PROBE'S OWN CHECKS (it is where "nothing real was touched" is proved):
#   - the fixture, hashed before and after (the pristine tree and the sandbox's copy), unchanged;
#   - no shim wrote a REFUSED line; pkexec ran only with the fake root; the unit shim (the MUX phase's shutdown and
#     boot halves) ran only the two unit commands, only on the fake root; no pw-play call at all; no busctl/gdbus
#     call names the system bus; systemctl was only ever asked to `reboot`, and only where the probe asked for it;
#   - the shell's log has no WARN / ERROR / binding loop / unassigned property -- except the
#     SiliconConfig warnings the probe announced for the bad values it wrote, counted exactly;
#   - no process the run started is left behind.
#
# Own sandbox (tools/dev/sandbox.sh: SANDBOX=/tmp/lares-sandbox-silicon-data, or SILICON_STREAM=<name>), private
# XDG dirs with a seeded theme state, offscreen; kills only the pids it started. A run whose probe printed
# no `SILP DONE` (the QML did not load, crashed, or outlived its deadline) ends on `SILICON-SERVICE
# RESULT FAIL (no result: <log>)` (tools/dev/result_lib.sh; tools/dev/runner_noload_check.sh's pattern).
set -u
cd "$(dirname "$0")/../.." || exit 1
NAME=SILICON-SERVICE

# ---- ARM=all: every ARM, each in a sandbox copy and a run of its own ------------------------------------------
if [ "${ARM:-}" = all ] && [ -z "${SSP_INNER:-}" ]; then
    . tools/dev/result_lib.sh
    bad=0
    for a in ${ONLY_ARMS:-noplug norebase nosmigate nosettle silentwrite noexternal statuspoll freebattery noknobs resumeapply holdstays nofallback smiasleep noacsignal nostall stallsticks stallnow cpustrand limitflip limitown resumelimit resumewindow fullopen silentmux ignorestale autokeep deafclick noprompt twice unmarked earlyopen noholdreal nomemory noafterapply afterguess afterlost noupower noevent noresumeup leaveedge upthrottle upsilent upnocheck upemptyweek dockcounts nomonitor eventscan norefreshdisplay nosession nosessionlogin afterreply afterreplymock nopower nopgap nopdebounce noignorecfg ownsmi rawcores noshutholders noboot bootapply noload nokick nobaseline kickmanual viashown cardwireonly noargv}; do
        sb="/tmp/lares-sandbox-silicon-${SILICON_STREAM:-data}-arm-$a"
        case "$a" in autokeep | deafclick | noprompt | twice | unmarked | earlyopen | noafterapply | afterguess | afterlost | nosessionlogin | afterreply) ph=mux ;;
            afterreplymock) ph=mock ;; noholdreal) ph=update ;; noboot | bootapply) ph=boot ;; noload | nokick | nobaseline | kickmanual | viashown) ph=fan ;; *) ph=main ;; esac
        res=$(ARM=$a SANDBOX="$sb" SCRATCH="${SCRATCH:-}" HELPER="${HELPER:-}" PHASES="${PHASES:-$ph}" ONLY_ARMS='' bash tools/dev/silicon_service_probe.sh 2>&1)
        rm -rf "$sb"
        if rl_isnoresult "$res"; then
            echo "  ARM $a: the armed copy did not load -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | grep -q 'anchor not found exactly once'; then
            echo "  ARM $a: its anchor is not in the code (a stale ARM fails without a check going red) -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | tail -1 | grep -q 'RESULT PASS'; then
            echo "  ARM $a: PASSED (it must fail)"; bad=1
        else
            echo "  ARM $a: failed as it must ($(printf '%s\n' "$res" | grep -c ' FAIL') checks red: $(printf '%s\n' "$res" | grep ' FAIL' | head -3 | sed 's/^SILP [a-z]*: //; s/  .*//' | tr '\n' ';'))"
        fi
    done
    [ "$bad" = 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
    echo "$NAME ARMS FAIL"; exit 1
fi

# ---- level 1: into the sandbox copy of this config --------------------------------------------------
if [ -e .git ] && [ -z "${SSP_INNER:-}" ]; then
    export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-silicon-${SILICON_STREAM:-data}}"
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen SSP_INNER=1 ARM="${ARM:-}" HELPER="${HELPER:-}" HELPER_SRC="${HELPER_SRC:-}" \
        PHASES="${PHASES:-}" PROBE_QML="${PROBE_QML:-}" ONLY_ARMS="${ONLY_ARMS:-}" SCRATCH="${SCRATCH:-}" \
        bash tools/dev/silicon_service_probe.sh
fi
. tools/dev/result_lib.sh
ROOT="$(pwd)"
REAL_ROOT="${MOCKUP_REPO:-$ROOT}"
ARM="${ARM:-}"
SCR="${SCRATCH:-/tmp}"

# ---- level 2: the run's directories, the fixture copy, the ARM -----------------------------------------------
OUT="$SCR/silicon_service_probe${ARM:+-$ARM}"
STUBS="$ROOT/tools/dev/stubs/silicon"
SHIMS="$STUBS/shims"
FIXSRC="$ROOT/tools/dev/fixtures/silicon/data"
if [ "${SSP_BUS:-}" != 1 ]; then
    # one run at a time per output directory: two runs in one would share a fake machine and a log
    mkdir -p "$SCR"
    exec 9> "$OUT.lock"
    flock -n 9 || { echo "another run is using $OUT -- wait for it"; echo "$NAME RESULT FAIL (busy)"; exit 2; }
    rm -rf "$OUT"
    mkdir -p "$OUT/logs" "$OUT/oldlast"
    printf '1700000000000\n' > "$OUT/oldlast/last-full"      # the old battery module's file (hidden phase)
    [ -d "$FIXSRC/tree" ] || { echo "no fixture tree at $FIXSRC"; echo "$NAME RESULT FAIL (no fixture)"; exit 1; }
    hash_tree() {  # a directory -> one hash of every file (content + mode) and link
        (cd "$1" && { find . -type f -print0 | sort -z | xargs -0 sha256sum; find . -type l -printf '%p -> %l\n' | sort; }) | sha256sum | cut -d' ' -f1
    }
    echo "$(hash_tree "$FIXSRC") $(hash_tree "$REAL_ROOT/tools/dev/fixtures/silicon/data") $(hash_tree "$REAL_ROOT/tools/dev/fixtures/silicon/upower")" > "$OUT/hash.before"
    rsync -a "$FIXSRC/" "$OUT/fx/" || { echo "$NAME RESULT FAIL (fixture copy)"; exit 1; }

    # ---- the ARM, put into THIS sandbox copy only ------------------------------------------------------
    if [ -n "$ARM" ]; then
        [ -e .git ] && { echo "refusing to arm the real tree"; exit 2; }
        arm() {  # file from to -- the anchor must be there exactly once
            python3 - "$1" "$2" "$3" <<'PY' || { echo "ARM $ARM: anchor not found exactly once in $1"; echo "$NAME RESULT FAIL (arm)"; exit 2; }
import sys
p, a, b = sys.argv[1:]
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
            echo "ARMED $ARM in $1"
        }
        D=modules/silicon/data
        case "$ARM" in
            nosmigate) arm $D/SiliconService.qml 'active: root.popupOpen && cardwire.holders.length > 0 && root._dState === "D0"' 'active: root.popupOpen && root._dState === "D0"' ;;
            smiasleep) arm $D/SiliconService.qml 'active: root.popupOpen && cardwire.holders.length > 0 && root._dState === "D0"' 'active: root.popupOpen && cardwire.holders.length > 0' ;;
            nosettle) arm $D/HelperClient.qml 'Timer { id: applySettle; interval: root.settleMs; onTriggered: root._pump() }' 'Timer { id: applySettle; interval: 1; onTriggered: root._pump() }' ;;
            silentwrite) arm $D/SiliconService.qml '            } else {
                vm.fail("cpu", r.why, newer);
                root.writeRefused("cpu", r.why);
            }' '            }' ;;
            noexternal) arm $D/SiliconService.qml 'if (!fromWrite && prev !== null && !helperClient.pending) {' 'if (false) {' ;;
            statuspoll) arm $D/SiliconModel.js '    var statusMs = open ? 60000 : 300000;' '    var statusMs = open ? 2000 : 300000;' ;;
            freebattery) arm $D/SiliconService.qml '    ReadingBeat {
        id: beat' '    Timer { interval: 1300; repeat: true; running: true; onTriggered: poller.pollBattery() }
    ReadingBeat {
        id: beat' ;;
            noknobs) arm $D/SysfsPoller.qml '        root.pollKnobs();
' '' ;;
            resumeapply) arm $D/SiliconService.qml 'const gone = Proto.changedKnobs(root._preSleep, status);' 'const gone = ["profile", "epp"];' ;;
            holdstays) arm $D/SiliconService.qml '        PowerBus.dropAll("manual");' '        // armed: the hold stays' ;;
            nofallback) arm $D/SiliconService.qml '        if (!OsdBus.show(req))' '        if (false)' ;;
            noacsignal) arm $D/SiliconService.qml '            root.acChanged(r.acChanged);' '' ;;
            nostall) arm $D/PowerMath.js '        state.stalled = nowMs - state.stallSinceMs >= o.stallMs;' '        state.stalled = false;' ;;
            stallsticks) arm $D/PowerMath.js '        state.stallSinceMs = 0;
        state.stalled = false;
    }' '        state.stallSinceMs = 0;
    }' ;;
            stallnow) arm $D/PowerMath.js '        state.stalled = nowMs - state.stallSinceMs >= o.stallMs;' '        state.stalled = true;' ;;
            cpustrand) arm $D/SiliconService.qml '            const newer = helperClient.applyPending;' '            const newer = helperClient.pending;' ;;
            limitflip) arm $D/SiliconService.qml '                if (!newer)
                    vm.settle("battery");' '                vm.settle("battery");' ;;
            limitown) arm $D/SiliconService.qml 'const own = root._limitAsked.indexOf(s.limitPct);' 'const own = root._limitAsked.length === 1 ? root._limitAsked.indexOf(s.limitPct) : -1;' ;;
            resumelimit) arm $D/SiliconService.qml '                    root._limitAsked = root._limitAsked.concat([v.chargeLimit]);     // landing again is not news' '                    // armed: not remembered' ;;
            fullopen) arm $D/SiliconService.qml '        cardwire.refreshLive();' '        cardwire.refresh();' ;;
            resumewindow) arm $D/SiliconService.qml '            else if (!root._resuming())
                root._osd(Model.osdLimit(s.limitPct));' '            else
                root._osd(Model.osdLimit(s.limitPct));' ;;
            silentmux) arm $D/SiliconService.qml '                vm.fail("gpu", r.why);
                root.writeRefused("mux", r.why);' '                vm.fail("gpu", r.why);' ;;
            ignorestale) arm $D/SiliconService.qml '            muxOutcomeSeenAt: st.muxOutcomeSeenAt,
            ignoredApps: st.ignoredApps
' '            muxOutcomeSeenAt: st.muxOutcomeSeenAt
' ;;
            autokeep) arm $D/SiliconService.qml '    function muxPromptShown() { return helperClient.queueMux("promptShown", ""); }' '    function muxPromptShown() { helperClient.queueMux("promptShown", ""); return helperClient.queueMux("confirm", ""); }' ;;
            noprompt) arm $D/SiliconService.qml '    function muxPromptShown() { return helperClient.queueMux("promptShown", ""); }' '    function muxPromptShown() { return true; }' ;;
            deafclick) arm $D/SiliconService.qml '    function muxKeep() { return helperClient.queueMux("confirm", ""); }' '    function muxKeep() { return false; }' ;;
            unmarked) arm $D/SiliconService.qml '            st.muxOutcomeSeenAt = rec.requestedAtMs;' '            void 0;      // armed: never marked' ;;
            twice) arm $D/SiliconState.qml '        if (typeof o.muxOutcomeSeenAt === "number" && isFinite(o.muxOutcomeSeenAt) && o.muxOutcomeSeenAt >= 0)
            root.muxOutcomeSeenAt = o.muxOutcomeSeenAt;
' '' ;;
            noholdreal) arm $D/SystemUpdateHold.qml '        if (PowerBus.hold(root.source, root.profile, why))' '        if (false)' ;;
            earlyopen) arm $D/SiliconService.qml '        if (!root.popupOpen || !root._ready)' '        if (!root.popupOpen)' ;;
            rawcores) arm $D/SiliconService.qml 'Array.prototype.slice.call(s.cores)' 's.cores' ;;
            noshutholders) arm $D/SiliconService.qml '        if (!root.popupOpen && root._dState === "D0" && vm.gpu.wiring !== "dgpu")
            cardwire.refreshHolders();
' '' ;;
            nomemory) arm $D/SysfsPoller.qml '        out.memory = S.parseMeminfo(root.read(root.procRoot + "/meminfo"));' '' ;;
            noafterapply) arm $D/SiliconService.qml '            root.setGpuMode(p.step, {});' '            void 0;' ;;
            afterguess) arm $D/SiliconModel.js '    if (busy || !gpu.mux.available)' '    if (busy)' ;;
            afterlost) arm $D/SiliconState.qml '            muxOutcomeSeenAt: root.muxOutcomeSeenAt,
            afterMuxMode: root.afterMuxMode
' '            muxOutcomeSeenAt: root.muxOutcomeSeenAt
' ;;
            noupower) arm $D/SiliconService.qml '        gdbus: root.upowerGdbus
        batteryPath: root.upowerEnabled ? root._batteryPath : ""' '        gdbus: "/nonexistent/gdbus"
        batteryPath: root.upowerEnabled ? root._batteryPath : ""' ;;
            noevent) arm $D/SiliconService.qml '            if ((kind === "full" || kind === "chargeStop" || kind === "chargeDone") && root.upowerEnabled)
                upower.refreshSoon();
' '' ;;
            noresumeup) arm $D/SiliconService.qml '        poller.pollBattery();
        if (root.upowerEnabled)
            upower.refresh(true);
        if (root.popupOpen)
            poller.pollStats();
    }' '        poller.pollBattery();
        if (root.popupOpen)
            poller.pollStats();
    }' ;;
            leaveedge) arm $D/SiliconService.qml '        if (root._atTarget === true && !at)
            st.lastFullMs = Date.now();
' '' ;;
            upthrottle) arm $D/UpowerHistory.qml 'if (force !== true && root._lastAskMs > 0 && now - root._lastAskMs < root.minGapMs * 0.9)' 'if (false)' ;;
            upsilent) arm $D/UpowerHistory.qml '        root._why = ok ? "" : why;' '        root._why = "";' ;;
            upnocheck) arm $D/UpowerHistory.qml '            if (res.code !== 0) {
                root._settle(false, "gdbus is not installed' '            if (false) {
                root._settle(false, "gdbus is not installed' ;;
            upemptyweek) arm tools/dev/stubs/silicon/upower_gdbus '    ok) cat "$FIX/charge_week.txt" ;;' '    ok) cat "$FIX/charge_empty.txt" ;;' ;;
            dockcounts) arm modules/common/system/DrmRules.js 'nvidia: vendor === NVIDIA_PCI_VENDOR' 'nvidia: true' ;;
            ownsmi) arm $D/CardwireParse.js 'var IGNORED_HOLDERS = INFRA_HOLDERS.concat(SESSION_HOLDERS, ["btop", "nvidia-smi", "quickshell"]);' 'var IGNORED_HOLDERS = INFRA_HOLDERS.concat(SESSION_HOLDERS, ["btop", "quickshell"]);' ;;
            noignorecfg) arm $D/SiliconService.qml '        ignoredHolders: cfg.config.gpu.ignoredHolders' '        ignoredHolders: null' ;;
            nopower) arm $D/SiliconService.qml '        onChanged: root._onPowerEvent()' '        onChanged: void 0' ;;
            nopgap) arm $D/SiliconService.qml '    property int powerEventGapMs: 1500' '    property int powerEventGapMs: 0' ;;
            nopdebounce) arm $D/PowerEventWatcher.qml '                debounce.restart();' '                root.changed();' ;;
            nomonitor) arm modules/common/system/DrmWatch.qml '            mon.enabled = true;' '            void 0;' ;;
            eventscan) arm modules/common/system/DrmWatch.qml '        debounce.restart();
    }

    function _startMonitor' '        root.rescan();
    }

    function _startMonitor' ;;
            afterreply)
                arm $D/SiliconService.qml '        st.afterMuxMode = want === "dgpu" ? null : step;
        helperClient.queueMux("request", want);' '        root._afterAsked = want === "dgpu" ? null : step;
        helperClient.queueMux("request", want);'
                arm $D/SiliconService.qml '            // (the mode asked for after the way back is the user'"'"'s ask, written where it was made: a reply does not touch it)
            if (r.ok) {
                vm.settle("gpu");' '            if (r.ok) {
                if (r.op === "request")
                    st.afterMuxMode = r.want === "hybrid" ? root._afterAsked : null;
                vm.settle("gpu");'
                arm $D/SiliconService.qml '    property bool _changeQueued: false
' '    property bool _changeQueued: false
    property var _afterAsked: null
' ;;
            afterreplymock)
                arm $D/SiliconMock.qml '        root._afterMuxMode = want === "dgpu" ? null : step;
        return true;' '        root._afterAsked = want === "dgpu" ? null : step;
        return true;'
                arm $D/SiliconMock.qml '            root._status = st;
            vm.settle("gpu");
            root._compute();
        }
    }
    // An unkept' '            root._status = st;
            root._afterMuxMode = op.want === "hybrid" ? root._afterAsked : null;
            vm.settle("gpu");
            root._compute();
        }
    }
    // An unkept'
                arm $D/SiliconMock.qml '    property var _muxBehind: []' '    property var _afterAsked: null
    property var _muxBehind: []' ;;
            nosession | nosessionlogin) arm $D/CardwireParse.js 'var SESSION_HOLDERS = ["hyprland", "xwayland", "xorg", "systemd", "systemd-logind"];' 'var SESSION_HOLDERS = [];' ;;
            noboot) arm $D/SiliconService.qml '            helperClient.queueBoot(plan.patch);' '            void 0;      // armed: never asked' ;;
            bootapply) arm $D/SiliconService.qml '            helperClient.queueBoot(plan.patch);' '            { helperClient.queueBoot(plan.patch); helperClient.replaceApply(plan.patch); }' ;;
            noload) arm $D/FanGuard.qml '            peak = Math.max(peak, root._ring[i].idx);' '            peak = Math.max(peak, 0 * root._ring[i].idx);' ;;
            nokick) arm $D/SiliconService.qml '        if (helperClient.queueKick(cur, via)) {' '        if (false) {' ;;
            nobaseline) arm $D/FanGuardMath.js '    if (bucket < 0 || !base || !base[profile])
        return null;' '    if (true)
        return null;' ;;
            kickmanual) arm $D/SiliconService.qml '        root._kickBefore = helperClient.status;' '        root._manualProfile();
        root._kickBefore = helperClient.status;' ;;
            viashown) arm $D/HelperClient.qml '        if (parsed.status && !via) {' '        if (parsed.status) {' ;;
            norefreshdisplay) arm $D/SiliconService.qml '        poller.pollBattery();
        root._drm.rescan();
        if (root.upowerEnabled)' '        poller.pollBattery();
        if (root.upowerEnabled)' ;;
            noplug) arm $D/SiliconService.qml '    onAcChanged: on => root._onPlug(on)' '' ;;
            norebase) arm $D/SiliconService.qml ' || holds.rebase(name))' ')' ;;
            cardwireonly) arm $D/SiliconModel.js '        return { action: "cancelmux", cw: cwOfStep(step) };' '        return { action: "cardwire", cw: cwOfStep(step) };' ;;
            noargv) arm $D/SiliconService.qml 'rebootLane.run(root.rebootArgv instanceof Array && root.rebootArgv.length > 0 ? root.rebootArgv : [root.systemctl, "reboot"], function' 'rebootLane.run([root.systemctl, "reboot"], function' ;;
            *) echo "unknown ARM=$ARM"; exit 2 ;;
        esac
        # ARM_CHECK=1: only prove that the fault's anchor applies exactly once to the tree as it is now (an anchor that
        # drifted makes ARM=all report "failed as it must" for a copy that was never armed)
        [ -n "${ARM_CHECK:-}" ] && { echo "ARM $ARM: the anchor applies"; exit 0; }
    fi
    exec tools/dev/notifications_bus.sh env SSP_BUS=1 ARM="$ARM" HELPER="${HELPER:-}" HELPER_SRC="${HELPER_SRC:-}" PHASES="${PHASES:-}" PROBE_QML="${PROBE_QML:-}" SCRATCH="$SCR" \
        bash tools/dev/silicon_service_probe.sh
fi

# ---- level 3: inside the private bus: the stand-in, the shell, the verdict ---------------------------------------
LOGROOT="$OUT/logs"      # one directory per phase: a phase reads only its own stubs' logs
FX="$OUT/fx"
QML="${PROBE_QML:-tools/dev/qml/silicon_service_probe.qml}"
# The REAL helper, built from the tree into a private target dir (the sandbox copy has no helpers/, and the tree's own
# target/ is somebody else's build, maybe of another revision): the MUX phase needs it (the stand-in has no shutdown or
# boot half) and HELPER=real uses it everywhere. Built at most once per run, and only when something asks for it.
SRC_HELPER="${HELPER_SRC:-$REAL_ROOT/helpers/silicon_helper}"
REALBIN=""
build_real_helper() {
    [ -n "$REALBIN" ] && return 0
    [ -f "$SRC_HELPER/Cargo.toml" ] || { echo "SILP helper-build FAIL  no crate at $SRC_HELPER"; return 1; }
    command -v cargo > /dev/null || { echo "SILP helper-build FAIL  no cargo"; return 1; }
    local tgt="$SCR/silicon_helper_target"
    if ! ( cd "$SRC_HELPER" && CARGO_TARGET_DIR="$tgt" cargo build --release --offline --locked ) > "$OUT/helper_build.log" 2>&1; then
        echo "SILP helper-build FAIL  cargo build failed ($OUT/helper_build.log):"; grep -E '^(error|warning)' -A4 "$OUT/helper_build.log" | head -12 | sed 's/^/    /'
        return 1
    fi
    REALBIN="$tgt/release/silicon-helper"
    [ -x "$REALBIN" ] || { echo "SILP helper-build FAIL  no binary at $REALBIN"; REALBIN=""; return 1; }
    echo "SILP info helper built from $SRC_HELPER ($(cut -c1-12 <<< "$(sha256sum "$REALBIN" | cut -d' ' -f1)"))"
}
# (built when the first phase that needs it starts, not before: a run whose QML does not load must still end on its
# no-result verdict, whatever the helper's tree is doing -- tools/dev/runner_noload_check.sh runs it from a copy with no helpers/)
HELPERBIN="$STUBS/silicon-helper"
STANDIN=1
[ "${HELPER:-}" = real ] && STANDIN=0     # its binary: $REALBIN, once built
MUXBIN=""
hash_tree() { (cd "$1" && { find . -type f -print0 | sort -z | xargs -0 sha256sum; find . -type l -printf '%p -> %l\n' | sort; }) | sha256sum | cut -d' ' -f1; }
fail=0
# The update phase drives the REAL supervisor, which writes $XDG_STATE_HOME/lares/system-update/last-run.json: the
# QML's state home is private, and the user's own marker must be exactly as it was when the run ends.
REAL_MARKER="${HOME}/.local/state/lares/system-update/last-run.json"
MARKER_BEFORE="$(sha256sum "$REAL_MARKER" 2> /dev/null | cut -d' ' -f1)"
noresult_log=""   # the first phase log whose probe printed no DONE (the QML did not load, or died)
started=""   # pids this run started

stop_pid() {  # pid -- ours only: TERM, then KILL
    local p=$1 i
    kill "$p" 2> /dev/null || return 0
    for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$p" 2> /dev/null || return 0; sleep 0.2; done
    kill -9 "$p" 2> /dev/null
}

# UPOWER_REAL: the user's own captures (tools/dev/fixtures/silicon/upower_local/, gitignored). The synthetic week is replayed always; when the local folder has
# the real one, the main phase is replayed once more against it (`mainreal`: the same checks, the stand-in answering the real bytes). The stand-in's other
# answers (empty, the errors) are the committed ones, so the real folder only has to hold the two weeks.
UPSYN="$ROOT/tools/dev/fixtures/silicon/upower"
UPLOCAL="$REAL_ROOT/tools/dev/fixtures/silicon/upower_local"
UPFIX="$UPSYN"
upower_week_ms() {  # the fixture's newest point (the first tuple), in ms -- the moment the pack was last full in both weeks
    local t; t=$(head -c 200 "$1/charge_week.txt" | grep -o 'uint32 [0-9]*' | head -1 | cut -d' ' -f2); echo "${t}000"
}
run_phase() {  # name needs_cardwire [label]
    local name=$1 cw=$2 lbl=${3:-$1} cwpid="" qpid="" log LOGS XDG hb standin
    # the MUX and boot phases always run the real helper (the stand-in has no shutdown or boot half, and stores its own boot
    # set); every other phase the one the run was asked for
    if [ "$name" = mux ] || [ "$name" = boot ] || [ "${HELPER:-}" = real ]; then
        build_real_helper || { fail=1; return; }
        MUXBIN="$REALBIN"
        [ "${HELPER:-}" = real ] && HELPERBIN="$REALBIN"
    fi
    hb="$HELPERBIN"; standin="$STANDIN"
    if [ "$name" = mux ] || [ "$name" = boot ]; then hb="$MUXBIN"; standin=0; fi
    log="$OUT/$lbl.log"
    LOGS="$LOGROOT/$lbl"
    rm -rf "$LOGS"; mkdir -p "$LOGS"
    # private XDG dirs per phase (nothing of one phase's state, config or theme is another's); silicon.json
    # and the system-update marker EXIST when the service starts (a FileView cannot watch a file that is
    # not there): an empty config, and a finished run.
    XDG="$OUT/xdg/$lbl"
    rm -rf "$XDG"
    mkdir -p "$XDG/config/quickshell" "$XDG/config/theme" "$XDG/state/lares/system-update" "$XDG/cache" "$XDG/data"
    echo '{"theme":"eva","mode":"light"}' > "$XDG/config/theme/state.json"
    printf '// the probe: nothing set, every value its seed\n{}\n' > "$XDG/config/quickshell/silicon.json"
    printf '{ "runId": "run-0", "runDir": "/nonexistent/run-0", "command": "true", "pid": 1, "startedAt": 1, "state": "finished", "exit": 0, "endedAt": 2 }\n' > "$XDG/state/lares/system-update/last-run.json"
    if [ "$name" = fan ]; then
        # the thermal baseline the guard starts from (the state it would have learned): for Balanced, a light load (buckets 0-2, the load index in
        # steps of 5) reads 55-60 degrees and a heavy one (index 50, buckets 9-11) 96; nothing for Quiet
        mkdir -p "$XDG/state/lares/silicon"
        cat > "$XDG/state/lares/silicon/thermal-baseline.json" <<'JSON'
{ "version": 1, "profiles": { "balanced": {
  "0": { "n": 500, "p90": 55 }, "1": { "n": 500, "p90": 58 }, "2": { "n": 500, "p90": 60 },
  "9": { "n": 500, "p90": 96 }, "10": { "n": 500, "p90": 96 }, "11": { "n": 500, "p90": 96 } } } }
JSON
    fi
    if [ "$cw" = 1 ]; then
        CARDWIRE_STUB_LOG="$LOGS/cardwire.log" python3 "$STUBS/cardwire_stub.py" > "$OUT/cwstub.out" 2>&1 &
        cwpid=$!
        for _ in $(seq 1 50); do grep -q 'cardwire-stub ready' "$OUT/cwstub.out" 2> /dev/null && break; sleep 0.1; done
        grep -q 'cardwire-stub ready' "$OUT/cwstub.out" || { echo "SILP cardwire-stub FAIL  did not come up: $(head -3 "$OUT/cwstub.out")"; fail=1; }
    fi
    # the fake machine starts afresh for every phase
    if [ "$name" != main ] || [ "$lbl" != main ]; then
        rm -rf "$FX"; rsync -a "$FIXSRC/" "$FX/"
    fi
    if [ "$name" = update ]; then mkdir -p "$OUT/runs"; fi
    # systemd's run directory, as the helper's --run-root reads it: one `invocation:<unit>` link per ACTIVE unit. The MUX unit
    # is active, and a second unit is, so that a probe that takes the first away is not mistaken for "systemd exports no such
    # links at all" (the helper's pre-check fails open then). The links are dangling on purpose: their target is an id.
    mkdir -p "$FX/runroot/run/systemd/units"
    ln -sfn 0123456789abcdef0123456789abcdef "$FX/runroot/run/systemd/units/invocation:silicon-mux.service"
    ln -sfn fedcba9876543210fedcba9876543210 "$FX/runroot/run/systemd/units/invocation:systemd-journald.service"
    if [ "$name" = hidden ]; then
        # a kernel without these: no rc6, no coretemp, no charge limit, no max_perf_pct, no MUX file
        T="$FX/tree/sys"
        rm -f "$T/class/drm/card1/gt/gt0/rc6_residency_ms" "$T/class/hwmon/hwmon4/name" "$T/class/power_supply/BAT0/charge_control_end_threshold" \
              "$T/devices/system/cpu/intel_pstate/max_perf_pct" "$T/devices/platform/asus-nb-wmi/gpu_mux_mode"
    fi
    env -u HYPRLAND_INSTANCE_SIGNATURE \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_QPA_PLATFORMTHEME= WAYLAND_DISPLAY= \
        QT_LOGGING_RULES="qt.qpa.services.warning=false" \
        XDG_CONFIG_HOME="$XDG/config" XDG_STATE_HOME="$XDG/state" XDG_CACHE_HOME="$XDG/cache" XDG_DATA_HOME="$XDG/data" \
        LARES_SLEEP_MONITOR=off \
        SSP_PHASE="$name" SSP_OUT="$OUT" SSP_FX="$FX" SSP_LOGS="$LOGS" SSP_HELPER="$hb" SSP_STANDIN="$standin" \
        SSP_UPDATE_RUN="$REAL_ROOT/helpers/update-run.sh" SSP_UPOWER="$STUBS/upower_gdbus" SILICON_UPOWER_FIX="$UPFIX" SSP_WEEK="$(upower_week_ms "$UPFIX")" \
        PATH="$SHIMS:$PATH" SILICON_STUB_DIR="$SHIMS" SILICON_STUB_LOG_DIR="$LOGS" SILICON_STUB_HELPER="$hb" SILICON_STUB_HANG_S=4 \
        quickshell -p "$QML" > "$log" 2>&1 &
    qpid=$!
    local deadline=$((SECONDS + ${DEADLINE:-240}))
    [ "$name" = mux ] && deadline=$((SECONDS + ${DEADLINE:-600}))
    while kill -0 "$qpid" 2> /dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.5; done
    if kill -0 "$qpid" 2> /dev/null; then
        echo "(the probe outlived its deadline and was killed)" >> "$log"
        stop_pid "$qpid"
    fi
    wait "$qpid" 2> /dev/null
    if [ -n "$cwpid" ]; then
        gdbus call --session --dest org.lares.CardwireStub --object-path /org/lares/cardwire_stub \
            --method org.lares.CardwireStub.Control.Quit > /dev/null 2>&1
        for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$cwpid" 2> /dev/null || break; sleep 0.2; done
        stop_pid "$cwpid"
        wait "$cwpid" 2> /dev/null
    fi
    # the probe's lines
    rl_clean "$log" | grep -a -oE 'qml: SILP .*' | sed "s/^qml: SILP /SILP $lbl: /"
    # how many shells (SiliconService instances, each with its own gdbus monitor) the phase started: the MUX phase
    # restarts the shell with the machine
    rl_clean "$log" | grep -a -o 'SILP info instances [0-9]*' | awk '{n = $4} END {print n + 0}' > "$LOGS/instances"
    if ! rl_has "$log" "qml: SILP DONE $name (PASS|FAIL)"; then
        fail=1
        noresult_log="${noresult_log:-$log}"
        return
    fi
    rl_has "$log" "qml: SILP DONE $name PASS" || fail=1
    # the shell's own warnings: none, but the SiliconConfig ones the probe announced -- and the boot profile's refusals (Q16: one
    # line each, which the boot phase announces)
    local noise expected got bexpected bgot
    noise=$(rl_clean "$log" | grep -E '^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property|TypeError|ReferenceError' \
        | grep -v 'quickshell.tooling' | grep -v 'SiliconConfig:' | grep -v 'SiliconService: the boot profile ' | sed 's/^ *//' | sort | uniq -c | sort -rn)
    expected=$(rl_clean "$log" | grep -a -o 'SILP info config-warnings [0-9]*' | awk '{s += $4} END {print s + 0}')
    got=$(rl_clean "$log" | grep -c 'WARN.*SiliconConfig:')
    bexpected=$(rl_clean "$log" | grep -a -o 'SILP info boot-warnings [0-9]*' | awk '{s += $4} END {print s + 0}')
    bgot=$(rl_clean "$log" | grep -c 'WARN.*SiliconService: the boot profile ')
    if [ -n "$noise" ]; then
        echo "SILP $lbl.warnings FAIL"; printf '%s\n' "$noise" | sed 's/^/    /'; fail=1
    elif [ "$expected" != "$got" ]; then
        echo "SILP $lbl.config-warnings FAIL  the probe announced $expected SiliconConfig warning(s), the log has $got"; fail=1
    elif [ "$bexpected" != "$bgot" ]; then
        echo "SILP $lbl.boot-warnings FAIL  the probe announced $bexpected boot profile warning(s), the log has $bgot"; fail=1
    else
        echo "SILP $lbl.warnings PASS  (${got} announced SiliconConfig warning(s), ${bgot} boot profile warning(s), nothing else)"
    fi
}

PHASE_LIST="${PHASES:-main hidden nohelper mock boot mux update fan}"
if [ -d "$UPLOCAL" ] && [ -f "$UPLOCAL/charge_week.txt" ] && [ -f "$UPLOCAL/charge_all_oldest_first.txt" ] && [ -z "${NO_REAL_UPOWER:-}" ] && [ -z "${ARM:-}" ]; then
    case " $PHASE_LIST " in *" main "*) PHASE_LIST="${PHASE_LIST/main/main mainreal}" ;; esac
fi
for ph in $PHASE_LIST; do
    case "$ph" in
        main) UPFIX="$UPSYN"; run_phase main 1 ;;
        mainreal)
            UPFIX="$OUT/upower_real"; rm -rf "$UPFIX"; mkdir -p "$UPFIX"
            cp "$UPSYN"/* "$UPFIX"/ && cp "$UPLOCAL/charge_week.txt" "$UPLOCAL/charge_all_oldest_first.txt" "$UPFIX"/
            run_phase main 1 mainreal; UPFIX="$UPSYN" ;;
        nohelper) run_phase nohelper 0 ;;
        hidden) run_phase hidden 1 ;;
        mock) run_phase mock 0 ;;
        mux) run_phase mux 1 ;;
        update) run_phase update 0 ;;
        boot) run_phase boot 0 ;;
        fan) run_phase fan 0 ;;
        *) echo "unknown phase $ph"; fail=1 ;;
    esac
done

# ---- the invariants: nothing real was touched --------------------------------------------------------------------
inv() { if [ "$2" = ok ]; then echo "SILP invariant.$1 PASS${3:+  $3}"; else echo "SILP invariant.$1 FAIL  $(printf '%s' "$3" | cut -c1-300)"; fail=1; fi; }
logs_of() { cat "$LOGROOT"/*/"$1" 2> /dev/null; }     # one stub's log across every phase
refused=$(for f in "$LOGROOT"/*/*.log; do [ -f "$f" ] || continue; case "$(basename "$f")" in cardwire.log) continue ;; esac; grep -H REFUSED "$f"; done | head -3)
[ -z "$refused" ] && inv "no-refusals" ok || inv "no-refusals" bad "$refused"
[ -z "$(ls "$LOGROOT"/*/pw-play.log 2> /dev/null)" ] && inv "no-sound" ok || inv "no-sound" bad "$(logs_of pw-play.log | head -2)"
pk="$(logs_of pkexec.log | grep -v -E ' (HANG|DELAY)( |$)')"
if [ -n "$pk" ]; then
    if printf '%s\n' "$pk" | grep -v -- "--sysfs-root $FX/tree" | grep -q .; then
        inv "pkexec-only-on-the-fake-root" bad "$(printf '%s\n' "$pk" | grep -v -- "--sysfs-root $FX/tree" | head -2)"
    else
        inv "pkexec-only-on-the-fake-root" ok "$(printf '%s\n' "$pk" | wc -l) calls"
    fi
    if printf '%s\n' "$pk" | awk '{print $2}' | grep -vqxF -e "$HELPERBIN" -e "${MUXBIN:-/nonexistent}"; then inv "pkexec-only-the-helper" bad ""; else inv "pkexec-only-the-helper" ok; fi
fi
if { logs_of busctl.log; logs_of gdbus.log; } | grep -q -- '--system'; then inv "no-system-bus" bad "$({ logs_of busctl.log; logs_of gdbus.log; } | grep -- '--system' | head -2)"; else inv "no-system-bus" ok; fi
# cardwire is reached by exactly these calls: busctl get-property / call / set-property of ITS bus name on the
# private bus, ONE gdbus monitor per phase, and (the probe's own) the stand-in's control calls
bad_bus="$(logs_of busctl.log | grep -v -E '^[0-9]+ --user --json=short (get-property|call|set-property) org\.opengamingcollective\.cardwire /org/opengamingcollective/cardwire(/Gpu/[01])? org\.opengamingcollective\.cardwire\.' | head -2)"
[ -z "$bad_bus" ] && inv "busctl-only-cardwire-calls" ok || inv "busctl-only-cardwire-calls" bad "$bad_bus"
bad_gd="$(logs_of gdbus.log | grep -v -E '^[0-9]+ (monitor --session --dest org\.opengamingcollective\.cardwire$|call --session --dest org\.lares\.CardwireStub )' | head -2)"
# one monitor per SHELL: a phase that restarts the shell (the MUX one) announces how many it started
over=""
for d in "$LOGROOT"/*/; do
    m="$(grep -c ' monitor ' "${d}gdbus.log" 2> /dev/null)"; n="$(cat "${d}instances" 2> /dev/null)"; n="${n:-0}"; [ "$n" -ge 1 ] || n=1
    [ "${m:-0}" -le "$n" ] || over="$over $(basename "$d"): $m monitors for $n shell(s)"
done
if [ -z "$bad_gd" ] && [ -z "$over" ]; then inv "gdbus-one-monitor-only" ok "one per shell"; else inv "gdbus-one-monitor-only" bad "${bad_gd}${over}"; fi
ul="$(logs_of unit.log | grep -v REFUSED)"
if [ -n "$ul" ]; then
    if printf '%s\n' "$ul" | grep -v -- "--sysfs-root $FX/tree" | grep -q .; then inv "unit-only-on-the-fake-root" bad "$(printf '%s\n' "$ul" | grep -v -- "--sysfs-root $FX/tree" | head -2)"
    elif printf '%s\n' "$ul" | awk '{print $2}' | grep -vqE '^(mux-apply|mux-guard)$'; then inv "unit-only-the-two-commands" bad "$(printf '%s\n' "$ul" | head -2)"
    else inv "unit-only-on-the-fake-root" ok "$(printf '%s\n' "$ul" | wc -l) calls (shutdown + boot halves)"; fi
fi
sc="$(logs_of systemctl.log)"
if [ -n "$sc" ] && printf '%s\n' "$sc" | grep -vq ' reboot$'; then inv "systemctl-only-reboot" bad "$sc"; else inv "systemctl-only-reboot" ok "$(printf '%s' "$sc" | grep -c .) call(s)"; fi
[ "$(cat "$OUT/oldlast/last-full" 2> /dev/null)" = 1700000000000 ] && inv "old-battery-file-untouched" ok || inv "old-battery-file-untouched" bad "$(cat "$OUT/oldlast/last-full" 2> /dev/null)"
# udevadm is run ONLY through its stand-in, as the two monitor calls (drm, power_supply), and at most once per subsystem per shell (a watcher never polls
# and never starts a second)
ud="$(logs_of udevadm.log | grep -v REFUSED)"
if [ -n "$ud" ] && printf '%s\n' "$ud" | grep -vqE '^[0-9]+ monitor --udev --subsystem-match=(drm --subsystem-match=usb|power_supply)$'; then
    inv "udevadm-only-the-monitor" bad "$(printf '%s\n' "$ud" | head -2)"
else
    over=""
    for d in "$LOGROOT"/*/; do
        m="$(grep -c ' monitor ' "${d}udevadm.log" 2> /dev/null)"; n="$(cat "${d}instances" 2> /dev/null)"; n="${n:-0}"; [ "$n" -ge 1 ] || n=1
        [ "${m:-0}" -le "$((n * 2))" ] || over="$over $(basename "$d"): $m monitors for $n shell(s)"
    done
    [ -z "$over" ] && inv "udevadm-only-the-monitor" ok "$(printf '%s' "$ud" | grep -c .) start(s), one per subsystem per shell" || inv "udevadm-only-the-monitor" bad "$over"
fi
# UPower is asked ONLY through its stand-in (which refuses everything but the one read-only history call): every line it logged is that call, and none was refused
ul2="$(logs_of upower.log | grep -v REFUSED)"
if [ -n "$ul2" ] && printf '%s\n' "$ul2" | grep -vqE '^[0-9]+ call --system --dest org\.freedesktop\.UPower --object-path /org/freedesktop/UPower/devices/battery_[A-Za-z0-9_]+ --method org\.freedesktop\.UPower\.Device\.GetHistory charge [0-9]+ [0-9]+$'; then
    inv "upower-only-the-history-read" bad "$(printf '%s\n' "$ul2" | head -2)"
else
    inv "upower-only-the-history-read" ok "$(printf '%s' "$ul2" | grep -c .) calls, all the read"
fi
case " ${PHASES:-main} " in *" main "*) [ -n "$ul2" ] && inv "upower-was-asked" ok || inv "upower-was-asked" bad "the main phase never asked UPower" ;; esac
echo "$(hash_tree "$FIXSRC") $(hash_tree "$REAL_ROOT/tools/dev/fixtures/silicon/data") $(hash_tree "$REAL_ROOT/tools/dev/fixtures/silicon/upower")" > "$OUT/hash.after"
if cmp -s "$OUT/hash.before" "$OUT/hash.after"; then inv "fixture-unchanged" ok "$(cut -c1-12 "$OUT/hash.before")"; else inv "fixture-unchanged" bad "the pristine fixture changed"; fi
if [ "${HELPER:-}" != real ] && logs_of helper.log | grep -v -- "--sysfs-root $FX/tree" | grep -q .; then inv "helper-only-on-the-fake-root" bad "$(logs_of helper.log | grep -v -- "--sysfs-root $FX/tree" | head -2)"; fi
[ "$(sha256sum "$REAL_MARKER" 2> /dev/null | cut -d' ' -f1)" = "$MARKER_BEFORE" ] && inv "user-update-marker-untouched" ok || inv "user-update-marker-untouched" bad "$REAL_MARKER changed during the run"
# nothing of ours is left running: no process still carries this run's marker in its environment
sleep 5   # (the hung-helper case leaves a short sleep behind on purpose)
left=""
for e in /proc/[0-9]*/environ; do
    p="${e#/proc/}"; p="${p%/environ}"
    [ "$p" = "$$" ] && continue
    [ -r "$e" ] || continue
    ( tr '\0' '\n' < "$e" ) 2> /dev/null | grep -qx "SSP_OUT=$OUT" && left="$left $p"
done
if [ -n "$left" ]; then inv "no-leftovers" bad "$left"; for p in $left; do kill -9 "$p" 2> /dev/null; done; else inv "no-leftovers" ok; fi

# a run whose probe never answered ends on the library's no-result verdict (the log's load errors, then
# `RESULT FAIL (no result: <log>)`), whatever else failed
if [ -n "$noresult_log" ]; then rl_noresult "$NAME" "$noresult_log"; exit 1; fi
[ "$fail" = 0 ] && echo "$NAME RESULT PASS" || echo "$NAME RESULT FAIL"
exit "$fail"
