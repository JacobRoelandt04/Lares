#!/usr/bin/env bash
# airplay_probe.sh -- AirplayWatch and its consumers (the track OSD, the bar glyph's flourish, the lyrics' active line) on a PRIVATE PipeWire:
# a null sink carries a RAOP sink's name, an `mpd.PipeWire` stream is linked into it with pw-link, `iw` / `pkcheck` / `pkexec` / `pw-dump` are stubs
# first on PATH (the pkexec stub plays the helper: the radio's state is a file, its argv a log; `pw-dump Module` answers the bytes captured
# read-only from the real graph, tools/dev/fixtures/airplay/). Never the session's PipeWire, NetworkManager, helper or radio.
#
#   tools/dev/airplay_probe.sh                  AIRPLAY RESULT PASS | FAIL     (scenarios main, reconcile, noverb)
#   ONLY=main tools/dev/airplay_probe.sh        one scenario
#   ARM=<name> tools/dev/airplay_probe.sh       a fault in the sandbox copy; must FAIL on its needle
#     noreassert   no re-check while sending                    -> "re-asserted after a reset"
#     userowned    a power save found off is taken as ours      -> "untouched when the user had it off"
#     nograce      the grace is 1 ms                            -> "not put back before the grace"
#     noreconcile  a record from a dead shell is not honoured   -> "reconcile: a record that says ours"
#     noverbblind  "unknown command" is not recognised          -> "noverb: the helper without the verb is noticed"
#     nodelay      a natural song change shows at once          -> "osd: not shown at once"
#     keydelayed   a media key's card waits too                 -> "osd: key card immediate"
#     nodrop       a stop does not drop the pending card        -> "osd: nothing shown after a stop"
#     noflourish   the glyph's flourish ignores the delay       -> "flourish: not at once"
#     lyricslive   the lyrics follow the live position          -> "lyrics: 20.5 s"
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/aprobe.XXXXXX")"
PW=$(mktemp -d /tmp/aprobepw.XXXXXX); chmod 700 "$PW"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -z "$p" ] || kill "$p" 2> /dev/null; done; rm -rf "$PW"; [ -n "${KEEP:-}" ] || rm -rf "$D"; }
trap cleanup EXIT
ARM="${ARM:-}"; ARMCMD=""; SCEN="${ONLY:-main reconcile noverb}"
patch() { echo "grep -q '$2' $1 || { echo 'AP ARM anchor gone: $2'; exit 3; }; sed -i '$3' $1"; }
W=modules/audio/data/AirplayWatch.qml; M=modules/osd/data/sources/MpdSource.qml; B=modules/bar/player/PlayerBarButton.qml; P=modules/bar/player/components/PlayerData.qml
case "$ARM" in
    "") ;;
    noreassert) SCEN=main; ARMCMD=$(patch $W 'onTriggered: root._enqueue({ kind: "get", then: "recheck" })' 's|onTriggered: root._enqueue({ kind: "get", then: "recheck" })|onTriggered: {}|') ;;
    userowned) SCEN=main; ARMCMD=$(patch $W 'root._tell("userOff"' 's|root._tell("userOff"|root._setOurs(true); root._tell("userOff"|') ;;
    nograce) SCEN=main; ARMCMD=$(patch $W 'interval: root.config.graceSec \* 1000' 's|interval: root.config.graceSec \* 1000|interval: 1|') ;;
    noreconcile) SCEN=reconcile; ARMCMD=$(patch $W 'reconcileTimer.restart();' 's|reconcileTimer.restart();|;|') ;;
    noverbblind) SCEN=noverb; ARMCMD=$(patch $W 'if (a.missing) {' 's|if (a.missing) {|if (false) {|') ;;
    nodelay) SCEN=main; ARMCMD=$(patch $M 'root._action === "" && AirplayDelay.delayMs > 0' 's|root._action === "" \&\& AirplayDelay.delayMs > 0|false|') ;;
    keydelayed) SCEN=main; ARMCMD=$(patch $M 'root._action === "" && AirplayDelay.delayMs > 0' 's|root._action === "" \&\& AirplayDelay.delayMs > 0|AirplayDelay.delayMs > 0|') ;;
    nodrop) SCEN=main; ARMCMD="$(patch $M 'if (state === "stop")' 's|if (state === "stop")|if (false)|'); $(patch $M '&& root._state === "play")' 's|\&\& root._state === "play")|)|')" ;;
    noflourish) SCEN=main; ARMCMD=$(patch $B 'if (AirplayDelay.delayMs > 0) {' 's|if (AirplayDelay.delayMs > 0) {|if (false) {|') ;;
    lyricslive) SCEN=main; ARMCMD=$(patch $P ' - AirplayDelay.delayMs / 1000' 's| - AirplayDelay.delayMs / 1000||') ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac

# the private daemon: no session manager. A null sink under the RAOP sink's real name (its input ports are send_*), driving the graph
mkdir -p "$D/pwcfg/pipewire/pipewire.conf.d"
cat > "$D/pwcfg/pipewire/pipewire.conf.d/10-ap.conf" <<'CONF'
context.objects = [
    { factory = metadata
        args = { metadata.name = default }
    }
    { factory = adapter
        args = { factory.name = support.null-audio-sink node.name = "raop_sink.Speaker-0B01.local.192.168.0.103.7000" media.class = Audio/Sink
                 object.linger = true audio.position = [ FL FR ] audio.rate = 48000 node.driver = true node.virtual = true sess.media = raop node.network = true
                 adapter.auto-port-config = { mode = dsp monitor = true position = preserve } }
    }
]
CONF
XDG_RUNTIME_DIR="$PW" PIPEWIRE_RUNTIME_DIR="$PW" XDG_CONFIG_HOME="$D/pwcfg" setpriv --pdeathsig TERM -- pipewire > "$D/pipewire.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 50); do [ -S "$PW/pipewire-0" ] && break; sleep 0.1; done
[ -S "$PW/pipewire-0" ] || { echo "AIRPLAY RESULT FAIL (the private pipewire did not come up: $D/pipewire.log)"; KEEP=1; exit 1; }
export PIPEWIRE_REMOTE="$PW/pipewire-0"
sleep 0.4
# mpd's stream: a playback node named like mpd's own, ports configured by hand (no session manager), NOT linked: the probe links it
mkfifo "$D/feed"
(while :; do head -c 192000 /dev/zero; sleep 0.9; done > "$D/feed") &
PIDS+=($!)
setpriv --pdeathsig TERM -- pw-cat -p --raw --rate 48000 --channels 2 --format s16 -P "{ node.name = mpd.PipeWire node.autoconnect = false }" "$D/feed" > "$D/pwcat.log" 2>&1 &
PIDS+=($!)
ID=""
for _ in $(seq 50); do
    ID=$(pw-cli ls Node 2> /dev/null | awk '/^[[:space:]]*id [0-9]+/{id=$2;sub(",","",id)} /node.name = "mpd.PipeWire"/{print id}')
    [ -n "$ID" ] && break; sleep 0.1
done
[ -n "$ID" ] || { echo "AIRPLAY RESULT FAIL (no mpd.PipeWire stream: $D/pwcat.log)"; KEEP=1; exit 1; }
pw-cli set-param "$ID" PortConfig '{ "direction": "Output", "mode": "dsp", "format": { "mediaType": "audio", "mediaSubtype": "raw", "format": "F32P", "rate": 48000, "channels": 2, "position": [ "FL", "FR" ] } }' > /dev/null 2>&1
sleep 0.4

mkstubs() {   # mkstubs <dir> <old|new>
    local S=$1/stubs; mkdir -p "$S"
    printf '#!/bin/sh\nexit 0\n' > "$S/silicon-helper"
    printf '#!/bin/sh\nexit 0\n' > "$S/pkcheck"
    cat > "$S/iw" <<STUB
#!/bin/sh
if [ "\$1 \$3 \$4" = "dev get power_save" ]; then echo "Power save: \$(cat $1/iw_state)"; exit 0; fi
echo "iw \$*" >> $1/iw_forbidden.log; exit 1
STUB
    cat > "$S/pkexec" <<STUB
#!/bin/sh
echo "\$*" >> $1/calls.log
if [ "$2" = old ]; then echo '{"ok":false,"proto":1,"why":"unknown command '"'wifi-powersave'"'"}'; exit 2; fi
[ "\$2" = wifi-powersave ] && echo "\$4" > $1/iw_state
printf '{"ok":true,"proto":1,"wifi":{"iface":"%s","powerSave":"%s"}}\n' "\$3" "\$4"
STUB
    cat > "$S/pw-dump" <<STUB
#!/bin/sh
if [ "\$1" = Module ]; then cat "$PWD/tools/dev/fixtures/airplay/pw-dump-Module.json"; exit 0; fi
exec /usr/bin/pw-dump "\$@"
STUB
    chmod +x "$S"/*
}
FAILS=0
for scen in $SCEN; do
    SD="$D/$scen"; mkdir -p "$SD/config" "$SD/rt/lares" "$SD/net/wlp47s0" "$SD/net/lo" "$SD/cfg/theme" "$SD/state" "$SD/cache"
    printf '3\n' > "$SD/net/wlp47s0/ifindex"; printf '1\n' > "$SD/net/lo/ifindex"
    printf '{"theme":"eva","mode":"light"}\n' > "$SD/cfg/theme/state.json"
    echo on > "$SD/iw_state"; : > "$SD/calls.log"
    printf '// the probe'"'"'s config\n{ "delay": 700, "graceSec": 1 }\n' > "$SD/config/airplay.jsonc"
    mkstubs "$SD" "$([ "$scen" = noverb ] && echo old || echo new)"
    if [ "$scen" = reconcile ]; then echo off > "$SD/iw_state"; printf '{"ours":true,"iface":"wlp47s0"}' > "$SD/rt/lares/airplay-powersave.json"; fi
    run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY PATH='"$SD/stubs"':$PATH PIPEWIRE_REMOTE='"$PIPEWIRE_REMOTE"' AP_DIR='"$SD"' AP_SCENARIO='"$scen"' QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QSG_DISTANCEFIELD_ANTIALIASING=gray XDG_CONFIG_HOME='"$SD/cfg"' XDG_STATE_HOME='"$SD/state"' XDG_CACHE_HOME='"$SD/cache"' timeout -k 5 90 quickshell -p tools/dev/qml/airplay_probe.qml'
    # the fixture path inside the stub is this tree's; the sandbox copy has the same relative file
    tools/dev/sandbox.sh bash -c "$run" > "$SD/log" 2>&1
    rl_clean "$SD/log" | grep -a -E 'AP (ok|FAIL|RESULT|warning)|LARES airplay' | cut -c1-300
    if ! rl_clean "$SD/log" | grep -a -q 'AP RESULT'; then
        if rl_clean "$SD/log" | grep -a -q 'AP ARM anchor gone'; then echo "ARM $ARM: the anchor is gone -- re-aim the arm"; KEEP=1; exit 1; fi
        echo "AIRPLAY RESULT FAIL (no result in $scen: $SD/log)"; rl_clean "$SD/log" | grep -a -E 'ERROR|WARN|caused by' | head -8; KEEP=1; FAILS=$((FAILS + 1)); continue
    fi
    rl_clean "$SD/log" | grep -a -q 'AP RESULT PASS' || FAILS=$((FAILS + 1))
    [ -e "$SD/iw_forbidden.log" ] && { echo "AP FAIL the shell ran iw itself: $(cat "$SD/iw_forbidden.log")"; FAILS=$((FAILS + 1)); }
    rl_clean "$SD/log" | grep -a -E 'WARN|Binding loop|TypeError|ReferenceError|Unable to assign' | grep -v 'PipeWire\|pw\.\|window masks' | head -5 | sed 's/^/AP warning: /'
done
if [ -n "$ARM" ]; then
    case "$ARM" in
        noreassert) needle="re-asserted after a reset" ;; userowned) needle="untouched when the user had it off" ;; nograce) needle="not put back before the grace" ;;
        noreconcile) needle="reconcile: a record that says ours" ;; noverbblind) needle="noverb: the helper without the verb is noticed" ;;
        nodelay) needle="osd: not shown at once" ;; keydelayed) needle="osd: key card immediate" ;; nodrop) needle="osd: nothing shown after a stop" ;;
        noflourish) needle="flourish: not at once" ;; lyricslive) needle="lyrics: 20.5 s" ;;
    esac
    if grep -a -q "AP FAIL .*$needle" "$D"/*/log 2> /dev/null || rl_clean "$D/${SCEN%% *}/log" | grep -a -q "AP FAIL .*$needle"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    echo "ARM $ARM: DID NOT FAIL on its needle (or never loaded) -- the probe cannot see it"; KEEP=1; exit 1
fi
if [ "$FAILS" -eq 0 ]; then echo "AIRPLAY RESULT PASS"; exit 0; fi
KEEP=1; echo "AIRPLAY RESULT FAIL ($FAILS red: $D)"; exit 1
