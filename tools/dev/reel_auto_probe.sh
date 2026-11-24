#!/usr/bin/env bash
# reel_auto_probe.sh -- the power reel's flourishes and actions, and the idle reel's auto layer, on MOCKS (tools/dev/qml/reel_auto_probe.qml: a
# real GooeyEngine and the reels, a mock IdleService, recording stand-ins for the commands and the OSD; offscreen, a sandbox copy).
#
#   tools/dev/reel_auto_probe.sh                    REEL_AUTO RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=<name> tools/dev/reel_auto_probe.sh         the fault patched into the sandbox copy; passes when the check it aims at FAILS:
#     nodebounce   a holder counts at once                                  -> "flaps for 100 ms asks nothing"
#     shortway     the cinematic takes the short way                         -> "the LONG way (3 cells back"
#     noopen       the strip never comes out by itself                       -> "the strip came out by itself"
#     noreason     the reason never comes out                                -> "the reason popped out beside the strip"
#     wronglevel   the reason level with the last icon, not the 3rd          -> "at the level of its 3rd icon"
#     subtitle     the mode back under the cause, a second line               -> "the reason is the cause alone"
#     halfpixel    the reason one line and its padding tall, odd: on half px  -> "its edges on whole pixels"
#     shortread    no reading pause                                          -> "it held the reading pause"
#     nohoverhold  the pointer on the words does not hold the pause          -> "the reading pause holds while the pointer"
#     nohoverreason a hover with auto active shows no reason                 -> "a hover with auto active shows the reason again"
#     manualreason a mode the user picked shows a reason                     -> "a mode the user picked shows no reason"
#     nochildfirst the strip does not hold for its reason (the engine)       -> "it folded first, the strip holding for it"
#     notint       the colour is not kept while held                         -> "keeps its colour with the pointer away"
#     nolock       the ring ignores the floor (turns; the service refuses)     -> "the refusal shakes the icon"
#     noctrl       Ctrl does not get past the floor                          -> "Ctrl+scroll picks a mode"
#     noshake      a refusal does not shake the icon                         -> "the refusal shakes the icon"
#     noreasonrefuse a refusal tells no cause                                -> "still tells it beside the strip"
#     stickyover   an override never ends                                    -> "a holder the override did not set aside ends it"
#     noreturn     the way back is a plain step                              -> "travels back to the user's soft, the long way"
#     nowait       poweroff runs at the click                                -> "poweroff runs when its flourish has played"
#     lockwaits    lock waits for its flourish                               -> "lock runs at once"
#     noautolock   a lock nobody clicked for plays nothing                   -> "a lock nobody clicked for"
#     hoverfires   hover fires the item                                      -> "hover plays the selected item's flourish"
#     nokey        the lock key does nothing                                 -> "the lares:lock key"
#     nomotion     an entry alone plays (no motion asked)                    -> "a pointer that comes onto the cell without moving"
#     arrivefires  an icon scrolled into the cell FIRES instead of playing   -> "a scroll plays the flourish of the icon it brings"
#     hoverrestart a hover starts the flourish over (stop, then play)        -> "a fresh hover during a flourish does not restart it"
#     pile         every step of a turn plays (no coalescing to the landing) -> "a turn that commits several steps"
#     stuckaway    an icon turned out of the cell freezes mid-flourish       -> "every flourish has ended by itself"
#     nostriphover the strip's icons do not play on a hover                  -> "a motion onto an icon of the open strip plays"
#     quietcinema  autoTell "quiet" still plays the cinematic                 -> "autoTell quiet: the cell turns"
# Nothing touches the desktop: offscreen, a private copy of this config, nothing live.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/reelauto.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
ARMCMD="" NEEDLE=""
case "${ARM:-}" in
    "") ;;
    nodebounce) NEEDLE="flaps for 100 ms asks nothing"
                ARMCMD="sed -i 's|            h._timer.interval = h.on ? h.onMs : h.offMs;|            h._timer.interval = h.on ? 1 : h.offMs;|' modules/idle/IdleAuto.qml" ;;
    shortway)   NEEDLE="the LONG way (3 cells back"
                ARMCMD="sed -i 's|reel.turnTo(follow._pendingIndex, true, follow.travelMs)|reel.turnTo(follow._pendingIndex, false, follow.travelMs)|' modules/bar/reel/ReelFollow.qml" ;;
    noopen)     NEEDLE="the strip came out by itself"
                ARMCMD="sed -i 's|        const open = follow.module.canAutoOpen();|        const open = false;|' modules/bar/reel/ReelFollow.qml" ;;
    noreason)   NEEDLE="the reason popped out beside the strip"
                ARMCMD="sed -i 's|^        e.openChild(m.ownerId, follow.reasonId, .*|        return;|' modules/bar/reel/ReelFollow.qml" ;;
    wronglevel) NEEDLE="at the level of its 3rd icon"
                ARMCMD="sed -i 's|m.sideAnchor(m.reel.count - 2)|m.sideAnchor(m.reel.count - 1)|' modules/bar/reel/ReelFollow.qml" ;;
    shortread)  NEEDLE="it held the reading pause"
                ARMCMD="sed -i 's|        follow._readT.interval = follow.readMs;|        follow._readT.interval = 1;|' modules/bar/reel/ReelFollow.qml" ;;
    nohoverhold) NEEDLE="the reading pause holds while the pointer"
                ARMCMD="sed -i 's|            follow._readT.stop();       // the pause holds under the pointer|            void 0;|' modules/bar/reel/ReelFollow.qml" ;;
    nohoverreason) NEEDLE="a hover with auto active shows the reason again"
                ARMCMD="sed -i 's|m.reelOpen \&\& (follow._phase === \"read\" \|\| follow._phase === \"\")|m.reelOpen \&\& follow._phase === \"read\"|' modules/bar/reel/ReelFollow.qml" ;;
    manualreason) NEEDLE="a mode the user picked shows no reason"
                ARMCMD="sed -i 's|follow.automatic \&\& follow.reason !== \"\" ? follow.reason : \"\"|follow.target !== \"\" ? follow.target : \"\"|' modules/bar/reel/ReelFollow.qml" ;;
    subtitle)   NEEDLE="the reason is the cause alone"
                ARMCMD="sed -i 's|^    implicitHeight: 2 \* Math.round(tip.padY + causeLine.height / 2)\$|&+ 14|; \$ s|^}\$|    Text { y: 21; x: tip.padX; text: \"Normal: no idle actions\"; font.pixelSize: 11 }\n}|' modules/bar/reel/ReelReason.qml" ;;
    halfpixel)  NEEDLE="its edges on whole pixels"
                ARMCMD="sed -i 's|^    implicitHeight: 2 \* Math.round(tip.padY + causeLine.height / 2)\$|    implicitHeight: Math.ceil(2 * tip.padY + causeLine.height)|' modules/bar/reel/ReelReason.qml" ;;
    nochildfirst) NEEDLE="it folded first, the strip holding for it"
                ARMCMD="sed -i 's|        if (childOut \&\& engine._waitsForChild(R)) {|        if (false) {|' modules/bar/gooey/GooeyEngine.qml" ;;
    notint)     NEEDLE="keeps its colour with the pointer away"
                ARMCMD="sed -i 's/(view.reel.pointerOnBarCell || view.reel.open || view.reel.autoHeld)/(view.reel.pointerOnBarCell || view.reel.open)/' modules/bar/reel/IconReelView.qml" ;;
    nolock)     NEEDLE="the refusal shakes the icon"
                ARMCMD="sed -i 's/        if (!root.floorActive || root.inputCtrl || root.count <= 0)/        if (true)/' modules/bar/reel/IconReel.qml" ;;
    noctrl)     NEEDLE="Ctrl+scroll picks a mode"
                ARMCMD="sed -i 's/        if (!root.floorActive || root.inputCtrl || root.count <= 0)/        if (!root.floorActive || root.count <= 0)/' modules/bar/reel/IconReel.qml" ;;
    noshake)    NEEDLE="the refusal shakes the icon"
                ARMCMD="sed -i 's/        shakeAnim.restart();/        void 0;/' modules/bar/reel/IconReel.qml" ;;
    noreasonrefuse) NEEDLE="still tells it beside the strip"
                ARMCMD="sed -i 's/            follow._refusalOn = true;/            follow._refusalOn = false;/' modules/bar/reel/ReelFollow.qml" ;;
    stickyover) NEEDLE="a holder the override did not set aside ends it"
                ARMCMD="sed -i 's|        if (!Rules.overrideStands(keys, root._suppressed))|        if (false)|; s|    if (overrideStands(keys, suppressed))|    if (suppressed \&\& suppressed.length > 0)|' modules/idle/IdleAuto.qml modules/idle/IdleAutoRules.js" ;;
    noreturn)   NEEDLE="travels back to the user's soft, the long way"
                ARMCMD="sed -i 's|        const auto = follow.automatic \|\| follow._lastAuto;|        const auto = follow.automatic;|' modules/bar/reel/ReelFollow.qml" ;;
    nowait)     NEEDLE="poweroff runs when its flourish has played"
                ARMCMD="sed -i 's|var WAITS = { poweroff: true, reboot: true, logout: true, hibernate: true };|var WAITS = { reboot: true, logout: true, hibernate: true };|' modules/bar/reel/ReelFlourish.js" ;;
    lockwaits)  NEEDLE="lock runs at once"
                ARMCMD="sed -i 's|var WAITS = { poweroff: true, reboot: true, logout: true, hibernate: true };|var WAITS = { poweroff: true, reboot: true, logout: true, hibernate: true, lock: true };|' modules/bar/reel/ReelFlourish.js" ;;
    noautolock) NEEDLE="a lock nobody clicked for"
                ARMCMD="sed -i 's|            set._engage();\$|            void 0;|' modules/bar/reel/ReelFlourishes.qml" ;;
    hoverfires) NEEDLE="hover plays the selected item's flourish"
                ARMCMD="sed -i 's|                reelState.flourishes.hover(reelState.selectedItem.id);|                reelState.activate();|' modules/bar/reel/ReelBarModule.qml" ;;
    nokey)      NEEDLE="the lares:lock key"
                ARMCMD="sed -i 's|                root.services.reelActions.firePower(\"lock\");|                void 0;|' modules/shell/ShortcutRouter.qml" ;;
    nomotion)   NEEDLE="a pointer that comes onto the cell without moving"
                ARMCMD="sed -i 's|            view._entryArmed = pick.containsMouse;|            view._entryArmed = pick.containsMouse; if (pick.containsMouse) view.pointerArrived();|' modules/bar/reel/IconReelView.qml" ;;
    arrivefires) NEEDLE="a scroll plays the flourish of the icon it brings"
                ARMCMD="sed -i 's|            reelState.flourishes.arrive(reelState.selectedItem.id);|            reelState.activate();|' modules/bar/reel/ReelBarModule.qml" ;;
    hoverrestart) NEEDLE="a fresh hover during a flourish does not restart it"
                ARMCMD="sed -i 's|        set._demo(id, \"hover\");|        if (set.clockOf(id)) set.clockOf(id).stop(); set._demo(id, \"hover\");|' modules/bar/reel/ReelFlourishes.qml" ;;
    pile)       NEEDLE="a turn that commits several steps"
                ARMCMD="sed -i 's|                Qt.callLater(mod._arrive);|                mod._arrive();|' modules/bar/reel/ReelBarModule.qml" ;;
    stuckaway)  NEEDLE="every flourish has ended by itself"
                ARMCMD="sed -i 's|^        if (reelState.flourishes \&\& reelState.selectedItem)\$|        for (const it of reelState.items) { const fc = reelState.flourishes ? reelState.flourishes.clockOf(it.id) : null; if (fc \&\& fc.playing \&\& reelState.selectedItem \&\& it.id !== reelState.selectedItem.id) fc._anim.pause(); }\n        if (reelState.flourishes \&\& reelState.selectedItem)|' modules/bar/reel/ReelBarModule.qml" ;;
    nostriphover) NEEDLE="a motion onto an icon of the open strip plays"
                ARMCMD="sed -i 's|                    reelState.flourishes.hover(reelState.items\[index\].id);|                    void 0;|' modules/bar/reel/ReelBarModule.qml" ;;
    quietcinema) NEEDLE="autoTell quiet: the cell turns"
                ARMCMD="sed -i 's|        const auto = follow.cinematic \&\& (|        const auto = (|' modules/bar/reel/ReelFollow.qml" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
# A private config home with the theme seeded (THEME / MODE, default eva light: CLAUDE.md, a quickshell without one reads -- and a
# mode switch would write -- the user's theme state), and a private state home.
mkdir -p "$D/cfg/theme" "$D/state"
printf '{"theme":"%s","mode":"%s"}\n' "${THEME:-eva}" "${MODE:-light}" > "$D/cfg/theme/state.json"
# GRAB_DIR=<dir>: the window with the reason out beside the strip, as <dir>/reason.png (the sheet)
GRAB="${GRAB_DIR:+$(realpath -m "$GRAB_DIR")}"
[ -n "$GRAB" ] && mkdir -p "$GRAB"
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY XDG_CONFIG_HOME="'"$D/cfg"'" XDG_STATE_HOME="'"$D/state"'" GRAB_DIR="'"$GRAB"'" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi timeout 150 quickshell -p tools/dev/qml/reel_auto_probe.qml'
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-reel-auto}" tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a 'REELAUTO \(ok\|FAIL\|play\|grab\|reason\) ' | sed 's/^.*REELAUTO /REELAUTO /'
warn=$(rl_clean "$D/log" | grep -aiE "binding loop|Cannot assign|Unable to assign|TypeError|ReferenceError|is not a function|unqualified" | rl_platform_noise | head -5)
[ -n "$warn" ] && printf 'WARN %s\n' "$warn"
if [ -n "${ARM:-}" ]; then
    if ! rl_has "$D/log" 'REELAUTO RESULT'; then KEEP_D=1; echo "ARM $ARM: the armed copy did not load -- it proves nothing ($D/log)"; exit 1; fi
    if rl_clean "$D/log" | grep -a 'REELAUTO FAIL' | grep -aqF -- "$NEEDLE"; then echo "ARM $ARM: failed as it must ('$NEEDLE')"; exit 0; fi
    KEEP_D=1; echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it ($D/log)"; exit 1
fi
res=$(rl_result REEL_AUTO "$D/log" 'REELAUTO RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP_D=1; fi
[ -n "$warn" ] && [ "$rc" = 0 ] && { res="REEL_AUTO RESULT FAIL (warnings in the log: $D/log)"; rc=1; KEEP_D=1; }
printf '%s\n' "$res" | sed 's/^REELAUTO RESULT/REEL_AUTO RESULT/'
exit $rc
