#!/usr/bin/env bash
# wiki_ask_probe.sh -- the wiki's refill ask (tools/dev/qml/wiki_ask_probe.qml): the REAL WikiService on a private state dir, a recording
# notifier, a pinned clock and a stub tool. Proves the card's two buttons ("Process 30 now", "Later") and a body click:
# the body click opens the wiki and starts nothing; Later closes the ask (persisted in state.json), is not re-posted at a restart, is silent
# until 24 h and then asks again; Process starts the batch; a stale card's buttons start / change nothing. Nothing touches the desktop.
#
#   tools/dev/wiki_ask_probe.sh              WASK RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=<name> tools/dev/wiki_ask_probe.sh   the fault patched into the sandbox copy; passes when the check it aims at FAILS:
#     bodystarts   a body click starts the batch (as it did)              -> "a body click opens the wiki on the tab and starts nothing"
#     laterrepost  a restart re-posts a deferred ask                      -> "Later is not re-posted at a restart"
#     soon         a deferred ask comes back at once when evaluated       -> "the ask is silent before 24 h"
#     nolater      the latch forgets `later` in state.json                 -> "Later is in state.json"
#     stalebtn     a button of a closed ask acts as if it were open        -> "a stale card's Process starts nothing"
#     latershift   Later on a closed ask answers it anyway                 -> "Later pressed again on the deferred ask changes nothing"
#     anywhere     a card on screen anywhere makes it seen (before 11-12) -> "a card on screen elsewhere never makes its article seen"
#     families     a subject switched off stays in the picks' config     -> "wiki.jsonc families"
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/wask.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
ARMCMD="" NEEDLE=""
S=modules/wiki/data/WikiService.qml
case "${ARM:-}" in
    "") ;;
    bodystarts) NEEDLE="a body click opens the wiki on the tab and starts nothing"
                ARMCMD="sed -i 's|            if (id !== \"process\" \&\& id !== \"later\") {|            if (id === \"never\") {|; s|            if (id === \"later\") {\$|            if (id === \"later\") {|' $S" ;;
    laterrepost) NEEDLE="Later is not re-posted at a restart"
                ARMCMD="sed -i 's| \&\& !a.later \&\& n <= cfg.config.askAt| \&\& n <= cfg.config.askAt|' $S" ;;
    soon)       NEEDLE="the ask is silent before 24 h"
                ARMCMD="sed -i 's|        return now - keep.at >= c.reaskMs ? { ask: true, latch: fresh } : { ask: false, latch: keep };|        return { ask: true, latch: fresh };|' modules/wiki/data/WikiPool.js" ;;
    nolater)    NEEDLE="Later is in state.json"
                ARMCMD="sed -i 's|, later: latch.later === true };|, later: false };|' modules/wiki/data/WikiState.qml" ;;
    stalebtn)   NEEDLE="a stale card's Process starts nothing"
                ARMCMD="sed -i 's| \&\& a.later !== true \&\& !batcher.running;| \&\& a.later !== true;|' $S" ;;
    latershift) NEEDLE="Later pressed again on the deferred ask changes nothing"
                ARMCMD="sed -i 's| \&\& a.later !== true \&\& !batcher.running;| \&\& !batcher.running;|' $S" ;;
    anywhere)   NEEDLE="a card on screen elsewhere never makes its article seen"
                ARMCMD="sed -i 's|        if (!(root._visible\[id\] >= visibleMs)) root._visible\[id\] = visibleMs;|&\\n        if (!st.seen[id] \&\& Pool.seenDue(visibleMs, { seenMs: cfg.config.seenMs })) root._markSeen(tab, id, visibleMs, true);|' $S" ;;
    families)   NEEDLE="wiki.jsonc families"
                ARMCMD="sed -i 's|return on(f) [&][&] off\[f.id\] !== false;|return on(f);|' $S" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
mkdir -p "$D/w" "$D/cfg/theme" "$D/state" "$D/cache"
# a subject switched off (the rest of the file is the defaults: the 24 h of the steps below are askAgainHours' default)
printf '{ "families": { "people": false } }\n' > "$D/w/wiki.jsonc"
cp "${XDG_CONFIG_HOME:-$HOME/.config}/theme/state.json" "$D/cfg/theme/state.json" 2> /dev/null || printf '{"theme":"eva","mode":"light"}\n' > "$D/cfg/theme/state.json"
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QML_XHR_ALLOW_FILE_READ=1 XDG_CONFIG_HOME="$D_CFG" XDG_STATE_HOME="$D_STATE" XDG_CACHE_HOME="$D_CACHE" WASK_DIR="$D_W" timeout 100 quickshell -p tools/dev/qml/wiki_ask_probe.qml'
D_CFG="$D/cfg" D_STATE="$D/state" D_CACHE="$D/cache" D_W="$D/w" SANDBOX="${SANDBOX:-/tmp/lares-sandbox-wiki-ask}" tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a 'WASK \(ok\|FAIL\) ' | sed 's/^.*WASK /WASK /'
warn=$(rl_clean "$D/log" | grep -aiE "binding loop|Cannot assign|Unable to assign|TypeError|ReferenceError|is not a function|unqualified" | rl_platform_noise | head -5)
[ -n "$warn" ] && printf 'WARN %s\n' "$warn"
if [ -n "${ARM:-}" ]; then
    if ! rl_has "$D/log" 'WASK RESULT'; then KEEP_D=1; echo "ARM $ARM: the armed copy did not load -- it proves nothing ($D/log)"; exit 1; fi
    if rl_clean "$D/log" | grep -a 'WASK FAIL' | grep -aqF -- "$NEEDLE"; then echo "ARM $ARM: failed as it must ('$NEEDLE')"; exit 0; fi
    KEEP_D=1; echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it ($D/log)"; exit 1
fi
res=$(rl_result WASK "$D/log" 'WASK RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP_D=1; fi
[ -n "$warn" ] && [ "$rc" = 0 ] && { res="WASK RESULT FAIL (warnings in the log: $D/log)"; rc=1; KEEP_D=1; }
printf '%s\n' "$res"
exit $rc
