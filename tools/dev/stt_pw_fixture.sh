#!/usr/bin/env bash
# stt_pw_fixture.sh -- a PRIVATE PipeWire with a virtual microphone that plays speech clips: the dictation's test audio, never the
# user's microphone, graph or settings (CLAUDE.md: no test drives a daemon of the user's).
#
#   stt_pw_fixture.sh up DIR        a pipewire daemon of its own (runtime DIR/rt, config DIR/cfg), no session manager; one node
X
#                                   prints PIPEWIRE_REMOTE=<abs socket> and starts the linker (below)
#   stt_pw_fixture.sh play DIR GAP WAV...   plays each clip into dict_mic, GAP s of silence after each; returns when the last ends
#   stt_pw_fixture.sh state DIR     dict_mic's mute and volume, one line: `mute=<true|false> volume=<v>`
#   stt_pw_fixture.sh down DIR      stops the linker and the daemon (by the pids it kept), removes DIR/rt
#
# THE LINKER stands in for the session manager this daemon does not have (WirePlumber would also start the hardware monitors):
# every 100 ms it configures the ports of each new stream (PortConfig dsp, mono) and links a player into dict_mic's input and
# dict_mic's capture into a recorder (the dictation helper's pw-record, node.name lares-dictation). A clip played into the
# muted mic is recorded as silence: the mute is real. An input stream that says `node.autoconnect = false` is linked by its owner
# (the dictation's window take links the focused window's streams itself), as WirePlumber leaves it: its ports are configured as
# WirePlumber configures a stereo stream's (FL, FR) and nothing is linked to it. Players stay linked into dict_mic (the "speaker"
# that drives them).
set -u
cmd=${1:-}; D=${2:-}
[ -n "$D" ] || { echo "usage: $0 up|play|state|down DIR ..."; exit 2; }
RT="$D/rt"
export PIPEWIRE_REMOTE="$RT/pipewire-0"
PORTCFG='"mode": "dsp", "format": { "mediaType": "audio", "mediaSubtype": "raw", "format": "F32P", "rate": 48000, "channels": 1, "position": [ "MONO" ] }'
PORTCFG2='"mode": "dsp", "format": { "mediaType": "audio", "mediaSubtype": "raw", "format": "F32P", "rate": 48000, "channels": 2, "position": [ "FL", "FR" ] }'

nodes() {   # id<TAB>name<TAB>class<TAB>serial for every node (PipeWire reuses ids; a serial is never reused)
    pw-cli ls Node 2> /dev/null | awk '
        function out() { if (id != "") print id "\t" name "\t" cls "\t" ser }
        /^[[:space:]]*id [0-9]+/ { out(); id = $2; sub(",", "", id); name = ""; cls = ""; ser = "" }
        /node.name = / { name = $0; sub(/.*node.name = "/, "", name); sub(/".*/, "", name) }
        /media.class = / { cls = $0; sub(/.*media.class = "/, "", cls); sub(/".*/, "", cls) }
        /object.serial = / { ser = $0; sub(/.*object.serial = "/, "", ser); sub(/".*/, "", ser) }
        END { out() }'
}

linker() {
    declare -A done_ids=() tries=()
    while :; do
        while IFS=$'\t' read -r id name cls ser; do
            [ -n "$id" ] && [ -n "$ser" ] && [ -z "${done_ids[$ser]:-}" ] || continue
            local dir from to
            case "$cls" in
                Stream/Output/Audio) dir=Output from="$name:output_MONO" to=dict_mic:playback_MONO ;;
                Stream/Input/Audio)
                    if pw-cli info "$id" 2> /dev/null | grep -q 'node.autoconnect = "false"'; then
                        pw-cli set-param "$id" PortConfig "{ \"direction\": \"Input\", $PORTCFG2 }" > /dev/null 2>&1
                        done_ids[$ser]=1
                        echo "own $name" >> "$D/linker.log"
                        continue
                    fi
                    dir=Input from=dict_mic:monitor_MONO to="$name:input_MONO" ;;
                *) continue ;;
            esac
            [ -n "${tries[$ser]:-}" ] || pw-cli set-param "$id" PortConfig "{ \"direction\": \"$dir\", $PORTCFG }" > /dev/null 2>&1
            tries[$ser]=$(( ${tries[$ser]:-0} + 1 ))
            if err=$(pw-link "$from" "$to" 2>&1) || [[ $err == *"File exists"* ]]; then
                done_ids[$ser]=1
                echo "linked $name" >> "$D/linker.log"
            elif [ "${tries[$ser]}" -ge 50 ]; then
                done_ids[$ser]=1
                echo "FAILED $name" >> "$D/linker.log"
            fi
        done < <(nodes)
        sleep 0.1
    done
}

mic_id() { nodes | awk -F'\t' '$2 == "dict_mic" { print $1; exit }'; }

case "$cmd" in
    up)
        mkdir -p "$RT" "$D/cfg/pipewire/pipewire.conf.d"; chmod 700 "$RT"
        cat > "$D/cfg/pipewire/pipewire.conf.d/10-dict.conf" <<'CONF'
context.objects = [
    { factory = metadata
        args = { metadata.name = default }
    }
    { factory = adapter
        args = { factory.name = support.null-audio-sink node.name = dict_mic node.description = "Dictation test microphone"
                 media.class = Audio/Source object.linger = true audio.position = [ MONO ] audio.rate = 48000 node.driver = true monitor.channel-volumes = true
                 adapter.auto-port-config = { mode = dsp monitor = true position = preserve } }
    }
]
CONF
        XDG_RUNTIME_DIR="$RT" PIPEWIRE_RUNTIME_DIR="$RT" XDG_CONFIG_HOME="$D/cfg" setsid pipewire > "$D/pipewire.log" 2>&1 < /dev/null &
        echo $! > "$D/pipewire.pid"
        for _ in $(seq 50); do [ -S "$PIPEWIRE_REMOTE" ] && break; sleep 0.1; done
        [ -S "$PIPEWIRE_REMOTE" ] || { echo "FAIL the private pipewire did not come up ($D/pipewire.log)"; exit 1; }
        sleep 0.3
        pw-metadata -n default 0 default.audio.source '{"name":"dict_mic"}' Spa:String:JSON > /dev/null 2>&1
        pw-metadata -n default 0 default.configured.audio.source '{"name":"dict_mic"}' Spa:String:JSON > /dev/null 2>&1
        id=$(mic_id)
        [ -n "$id" ] || { echo "FAIL no dict_mic node"; exit 1; }
        pw-cli set-param "$id" Props '{ "mute": true, "channelVolumes": [ 0.8 ] }' > /dev/null 2>&1
        linker > /dev/null 2>&1 < /dev/null &
        echo $! > "$D/linker.pid"
        echo "PIPEWIRE_REMOTE=$PIPEWIRE_REMOTE"
        ;;
    play)
        gap=${3:-1.5}; shift 3
        n=0
        for w in "$@"; do
            n=$((n + 1))
            timeout -k 1 40 pw-play -P "{ node.name = clip_player_$n }" --target 0 "$w" > /dev/null 2>&1
            sleep "$gap"
        done
        ;;
    state)
        id=$(mic_id)
        pw-cli enum-params "$id" Props 2> /dev/null | awk '
            /Prop: key Spa:Pod:Object:Param:Props:mute/ { m = 1; next }
            m == 1 && /Bool/ { mute = $2; m = 0 }
            /Prop: key Spa:Pod:Object:Param:Props:channelVolumes/ { v = 1; next }
            v == 1 && /^[[:space:]]*Float/ { vol = $2; v = 0 }
            END { print "mute=" mute " volume=" vol }'
        ;;
    down)
        for f in linker pipewire; do [ -s "$D/$f.pid" ] && kill "$(cat "$D/$f.pid")" 2> /dev/null; done
        sleep 0.2
        rm -rf "$RT"
        ;;
    *) echo "usage: $0 up|play|state|down DIR ..."; exit 2 ;;
esac
