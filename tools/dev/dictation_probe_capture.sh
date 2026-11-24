#!/usr/bin/env bash
# dictation_probe_capture.sh -- the dictation probe's capture rig (tools/dev/dictation_probe.sh step K): speech that starts ONSET ms
# after the press, timed against the press, on the probe's private PipeWire (tools/dev/stt_pw_fixture.sh), inside lock_env.
#
#   dictation_probe_capture.sh PWDIR WAV LEAD_MS ONSET_MS
#     WAV       LEAD_MS of silence, then speech from its first sample (the runner cuts it so)
#     plays WAV into the fixture's mic, links the player itself (the fixture's linker polls every 100 ms: too coarse to time a
#     press by), and presses fn+F10 -- Hyprland's global lares:dictate -- at (player linked) + LEAD_MS - ONSET_MS, so the speech
#     begins ONSET_MS after the press; then links the dictation's recorder (node lares-dictation) the moment it appears, as
#     WirePlumber would. Prints `CAPRIG <what> <ms from the press>` lines (player, press, recorder, linked), `CAPRIG end` when the
#     clip has played.
set -u
PWDIR=$1 WAV=$2 LEAD=$3 ONSET=$4
export PIPEWIRE_REMOTE="$PWDIR/rt/pipewire-0"
PORTCFG='"mode": "dsp", "format": { "mediaType": "audio", "mediaSubtype": "raw", "format": "F32P", "rate": 48000, "channels": 1, "position": [ "MONO" ] }'
now() { date +%s%3N; }
node_id() { pw-cli ls Node 2> /dev/null | awk -v n="$1" '/^[[:space:]]*id [0-9]+/ { id = $2; sub(",", "", id) } $0 ~ "node.name = \"" n "\"" { print id; exit }'; }
link() {   # NODE DIRECTION FROM TO: configure the node's port, link; true once the link exists (made here or by the fixture's linker)
    local id err
    id=$(node_id "$1"); [ -n "$id" ] || return 1
    pw-cli set-param "$id" PortConfig "{ \"direction\": \"$2\", $PORTCFG }" > /dev/null 2>&1
    err=$(pw-link "$3" "$4" 2>&1) || [[ $err == *"File exists"* ]]
}
timeout -k 1 60 pw-play -P '{ node.name = clip_capture }' --target 0 "$WAV" > /dev/null 2>&1 &
PLAYER=$!
for _ in $(seq 400); do link clip_capture Output clip_capture:output_MONO dict_mic:playback_MONO && break; sleep 0.01; done
T0=$(now)
PRESS=$(( T0 + LEAD - ONSET ))
while [ "$(now)" -lt "$PRESS" ]; do sleep 0.005; done
TP=$(now)
hyprctl dispatch 'hl.dsp.global("lares:dictate")' > /dev/null 2>&1
echo "CAPRIG player $(( T0 - TP ))"
echo "CAPRIG press 0"
seen=""
for _ in $(seq 600); do
    if [ -z "$seen" ] && [ -n "$(node_id lares-dictation)" ]; then seen=$(now); echo "CAPRIG recorder $(( seen - TP ))"; fi
    if [ -n "$seen" ] && link lares-dictation Input dict_mic:monitor_MONO lares-dictation:input_MONO; then
        echo "CAPRIG linked $(( $(now) - TP ))"; break
    fi
    sleep 0.01
done
wait "$PLAYER"
echo "CAPRIG end $(( $(now) - TP ))"
