#!/usr/bin/env bash
# tools/dev/panorama_service_probe.sh -- the real PanoramaService (not live) on fake outputs and DRM facts, the engine's answers written
# into its EngineLink (tools/dev/qml/panorama_service_probe.qml has the checks). Offscreen, in a sandbox copy, private homes.
#
#   tools/dev/panorama_service_probe.sh          ends in PANORAMA_SERVICE RESULT PASS|FAIL
#   ARM=<arm>   the fault in the copy; the run must FAIL on its own check:
#     rerelate     the relations are re-read after a size change    oldrelayout  only the changed tile is dropped again (zero-net edits drift)
#     norelayout   a size change no longer re-lays the staged layout out     keepstaged  a revert keeps the staged edit (before round 2)
#     nofallback   an external without DDC takes no keys                     oldsplit    stage() seeds the store's partial split, not the resolved one
#     lastchip     a display's last workspace chip comes off (a fifth workspace)
#     nostamp      the countdown is never started                           fullsplit   a kept edit stores the whole split, not only what differs
#     nogone       an output absent from one read is told at once (no 400 ms hold)
#     mockkeep     the MOCK keeps the staged edit after a revert            mockrename  the mock's rename to "" keeps the name "custom"
#   The cast glue (modules/panorama/data/CastKeeper.qml, tools/dev/qml/panorama_cast_probe.qml) runs as a second harness after the first, in
#   the clean run; its ARMs run that harness alone:
#     closeearly   the output is closed when Stop is pressed AND when the stream ends (two closes)
#     startearly   the stream starts when the output is listed, before the resolved setup has landed
#     scanalways   a scan on every open of the view (no 30 s throttle)
#     (no arm for "never a scan while casting": CastService / CastMock refuse it too, so the keeper's own check cannot be seen alone)
#     castoffleak  the keeper is armed whatever the config says (cast false still scans and casts)
#     noclosefail  a failed cast leaves its output (it closes only after a stop)
#     mirrortarget the stream never follows a mirror switched on while it runs
#     mirroroutput a cast of a TV stored as a mirror still makes its output (born to be switched off: the 2026-11-23 crash)
#     silentrefuse a refused start leaves no notice (a click that does nothing)
#     scanswallows a Cast click during the popup's scan is dropped
#     nokeepsync   the engine is not told at the shell's start that no cast is live
#     castdefault  a TV's first stream takes the built in quality, not panorama.jsonc castQuality
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
export SANDBOX="${SANDBOX:-/tmp/lares-sbx-pano-svc}"
D="$(mktemp -d "${SCRATCH:-/tmp}/psvc.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
mkdir -p "$D/cfg/theme" "$D/state" "$D/cache"
printf '{"theme":"eva","mode":"light"}\n' > "$D/cfg/theme/state.json"
SVC=modules/panorama/data/PanoramaService.qml
KEEP=modules/panorama/data/CastKeeper.qml
HARNESS=panorama_service_probe.qml
MOCK=modules/panorama/data/PanoramaMock.qml
STG=modules/panorama/data/PanoramaStaging.js
file=$SVC
case "${ARM:-}" in
    "") from=""; to="" ;;
    # a size change no longer re-lays the staged layout out
    norelayout) file=$STG; from='    if (sizes) _place(s, outs, relations);'; to='    if (false) _place(s, outs, relations);' ;;
    # the relations are read again after the size change: an undo has nothing to go back to
    # the old call: the changed tile alone is dropped again where it stands (no relations)
    oldrelayout) file=$STG; from='    if (sizes) _place(s, outs, relations);'; to='    if (sizes) {
        var old = L.relayout(_rects(s, outs), name, internal);
        for (var oi = 0; oi < old.length; oi++) s[old[oi].name].position = [old[oi].x, old[oi].y];
    }' ;;
    # the relations are read again after each size change: a turn and its undo drift
    rerelate) file=$STG; from='    if (sizes) _place(s, outs, relations);'; to='    if (sizes) _place(s, outs, L.relationsOf(_rects(s, outs), internalName(outs)));' ;;
    # an external without DDC takes no keys (the laptop's backlight does not follow)
    nofallback) from='        return { kind: "panel", connector: "", label: "" };
    }
    function ddcDetect'; to='        return { kind: "none", connector: "", label: "" };
    }
    function ddcDetect' ;;
    # the countdown is never started
    nostamp) from='        t.deadlineMs = Date.now() + total;'; to='        t.deadlineMs = 0;' ;;
    # every revert keeps the staged edit
    keepstaged) from='        root._pending = null;
        root._staged = null;
        root._stagedSplit = null;
        root._relations = null;
        root._phase = "idle";'; to='        root._pending = null;
        root._phase = root._staged !== null ? "staged" : "idle";' ;;
    # stage() seeds the store's split (partial), as before round 2
    oldsplit) from='        root._stagedSplit = Staging.splitIdents(root._plan);
        root._relations = Staging.relationsOf(root._staged, root._outputs);
        if (root._phase === "idle")'; to='        root._stagedSplit = JSON.parse(JSON.stringify(root.store.doc.split || {}));
        root._relations = Staging.relationsOf(root._staged, root._outputs);
        if (root._phase === "idle")' ;;
    # the whole split is stored
    lastchip) file=$STG; from='        for (var id in had) if (!has[id]) return before;'; to='' ;;
    fullsplit) from='        d.split = Staging.splitForStore(d.split, root._staged, root._stagedSplit, root._outputs);'; to='        d.split = Object.assign({}, root._stagedSplit);' ;;
    # no hold before "disconnected"
    nogone) from='        id: goneCheck
        interval: 400'; to='        id: goneCheck
        interval: 1' ;;
    mockkeep) file=$MOCK; from='        // as the service: the staged edit goes with every revert and the picture is the one in force
        root._drop();'; to='        // (armed)' ;;
    mockrename) file=$MOCK; from='        st.custom = n !== "";'; to='        st.custom = true;' ;;
    closeearly) file=$KEEP; HARNESS=panorama_cast_probe.qml; from='        root._phase = "stopping";
        root.cast.stop(false);'; to='        root._phase = "stopping";
        root.closeOutput(root._name);
        root.cast.stop(false);' ;;
    startearly) file=$KEEP; HARNESS=panorama_cast_probe.qml; from='        if (!out || !sp || Model.liveDiff(out, sp) !== "")
            return;'; to='        if (!out || !sp)
            return;' ;;
    scanalways) file=$KEEP; HARNESS=panorama_cast_probe.qml; from='        if (root._lastScan > 0 && now - root._lastScan < root.scanEveryMs)
            return false;'; to='' ;;
    castoffleak) file=$SVC; HARNESS=panorama_cast_probe.qml; from='        armed: root.castEnabled'; to='        armed: root.cast !== null' ;;
    noclosefail) file=$KEEP; HARNESS=panorama_cast_probe.qml; from='        if (reason !== "stopped")
            root._setNotice(root._noticeText(root.cast.failure, reason));
        root._finish();'; to='        if (reason !== "stopped") {
            root._setNotice(root._noticeText(root.cast.failure, reason));
            root._phase = "idle";
            return;
        }
        root._finish();' ;;
    mirrortarget) file=$KEEP; HARNESS=panorama_cast_probe.qml; from='        if (root._phase === "streaming" && root._wantMirror() !== root._virtual)'; to='        if (false)' ;;
    mirroroutput) file=$KEEP; HARNESS=panorama_cast_probe.qml; from='        root._held = false;
        if (root._wantMirror()) {'; to='        root._held = false;
        if (false) {' ;;
    silentrefuse) file=$KEEP; HARNESS=panorama_cast_probe.qml; from='        root._notice = { device: deviceId, text: text };
        noticeTimer.interval = root.noticeMs;
        noticeTimer.restart();
        return false;'; to='        return false;' ;;
    scanswallows) file=$KEEP; HARNESS=panorama_cast_probe.qml; from='        if (root.cast.scanning) {
            root._held = true;
            return;
        }'; to='        if (root.cast.scanning) {
            root._finish();
            return;
        }' ;;
    nokeepsync) file=$KEEP; HARNESS=panorama_cast_probe.qml; from='        root.sync();
        if (root.popupOpen)'; to='        if (root.popupOpen)' ;;
    castdefault) file=$SVC; HARNESS=panorama_cast_probe.qml; from='        defaultQuality: root.settings.castQuality'; to='        defaultQuality: Staging.CAST_QUALITY' ;;
    *) echo "PANORAMA_SERVICE RESULT FAIL (unknown ARM $ARM)"; exit 1 ;;
esac
printf '%s' "$from" > "$D/from"; printf '%s' "$to" > "$D/to"
arm='python3 -c "import sys; p=sys.argv[1]; a=open(sys.argv[2]).read(); b=open(sys.argv[3]).read(); s=open(p).read(); sys.exit(\"ARM anchor gone\") if s.count(a)!=1 else open(p,\"w\").write(s.replace(a,b))" '"$file $D/from $D/to"
run='set -e; '"${ARM:+$arm; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME='"$D"'/cfg XDG_STATE_HOME='"$D"'/state XDG_CACHE_HOME='"$D"'/cache timeout 60 quickshell -p tools/dev/qml/'"$HARNESS"
tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a '^ *DEBUG qml: PS ' | sed 's/^ *DEBUG qml: //' | grep -v 'PS RESULT'
rl_clean "$D/log" | grep -a -E '^\s*(WARN|ERROR)' | grep -a -v -E 'QT_QPA_PLATFORM|window masks|WAYLAND_DISPLAY|actually running' | head -5
if [ -n "${ARM:-}" ]; then
    rl_has "$D/log" 'ARM anchor gone' && { echo "PANORAMA_SERVICE RESULT FAIL (ARM $ARM: its anchor is gone)"; exit 1; }
    if rl_has "$D/log" 'PS FAIL'; then echo "ARM $ARM: failed as it must"; echo "PANORAMA_SERVICE RESULT FAIL (armed $ARM)"; exit 1; fi
    echo "ARM $ARM: STILL PASSES"; echo "PANORAMA_SERVICE RESULT PASS (armed $ARM: the arm did not bite)"; exit 0
fi
res=$(rl_clean "$D/log" | grep -a -o 'PS RESULT .*' | tail -1)
[ -z "$res" ] && { KEEP=1; rl_noresult PANORAMA_SERVICE "$D/log"; exit 1; }
echo "PANORAMA_SERVICE ${res#PS }"
case "$res" in "PS RESULT PASS"*) ;; *) exit 1 ;; esac
# the cast glue's harness, the same sandbox call shape, its own result line
HARNESS=panorama_cast_probe.qml
run='set -e; env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME='"$D"'/cfg XDG_STATE_HOME='"$D"'/state XDG_CACHE_HOME='"$D"'/cache timeout 120 quickshell -p tools/dev/qml/'"$HARNESS"
tools/dev/sandbox.sh bash -c "$run" > "$D/log2" 2>&1
rl_clean "$D/log2" | grep -a '^ *DEBUG qml: PS ' | sed 's/^ *DEBUG qml: //' | grep -v 'PS RESULT'
rl_clean "$D/log2" | grep -a -E '^\s*(WARN|ERROR)' | grep -a -v -E 'QT_QPA_PLATFORM|window masks|WAYLAND_DISPLAY|actually running' | head -5
res=$(rl_clean "$D/log2" | grep -a -o 'PS RESULT .*' | tail -1)
[ -z "$res" ] && { KEEP=1; rl_noresult PANORAMA_SERVICE_CAST "$D/log2"; exit 1; }
echo "PANORAMA_SERVICE_CAST ${res#PS }"
case "$res" in "PS RESULT PASS"*) exit 0 ;; *) exit 1 ;; esac
