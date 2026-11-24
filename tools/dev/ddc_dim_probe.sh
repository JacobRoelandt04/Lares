#!/usr/bin/env bash
# ddc_dim_probe.sh -- the idle dimming of EXTERNAL displays over DDC (modules/idle/DdcDim.qml, DdcDimRules.js): DdcDim on a real DdcClient and a
# stub ddcutil whose answers and times are the ones measured on the user's 34-inch monitor (2026-11-22: a read 0.27 s, a write 0.28 s, the figure
# read back right at once). Nothing of the machine is touched. tools/dev/qml/ddc_dim_probe.qml has the steps.
#
#   tools/dev/ddc_dim_probe.sh             DDCDIM RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=<name> tools/dev/ddc_dim_probe.sh  the fault patched into the sandbox copy; passes when the check it aims at FAILS:
#     latesave    the display is written before its own figure is saved     -> "saved before the write"
#     nofresh     the figure the client remembers is the one to give back   -> "and gives back 80"
#     keylost     the give-back ignores the key's step                      -> "80 + 5"
#     noretry     a failed give-back is left for later                      -> "tried again until it has it"
#     byconnector a display is known by its connector                       -> "it comes back on DP-2"
#     nostate     the state file is not read at the start                   -> "a new shell gives it back"
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/ddp.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
F=modules/idle/DdcDim.qml A="" B="" NEEDLE=""
case "${ARM:-}" in
    "") ;;
    latesave)    A='                root._save(key, { full: r.full, wrote: r.value, level: root.want });
                root._note({ act: r.act, name: n, value: r.value, full: r.full });
                b.ddcSet(n, r.value);'
                 B='                b.ddcSet(n, r.value);
                late.key = key; late.entry = { full: r.full, wrote: r.value, level: root.want }; late.start();'
                 NEEDLE='saved before the write' ;;
    nofresh)     A='if (!f.fresh)'; B='if (false)'; F=modules/idle/DdcDimRules.js; NEEDLE='and gives back 80|dim reads it fresh' ;;
    keylost)     A='goal - entry.wrote : 0;'; B='0 : 0;'; F=modules/idle/DdcDimRules.js; NEEDLE='80 \+ 5' ;;
    noretry)     A='                    b.ddcForgive(n);'; B='                    ;'; NEEDLE='tried again until it has it' ;;
    byconnector) A='const n = names[i], key = b.ddcKey(n);'; B='const n = names[i], key = n;'; NEEDLE='it comes back on DP-2' ;;
    nostate)     A='root._saved = Rules.parseState(file.text());'; B='root._saved = ({});'; NEEDLE='a new shell gives it back' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-ddc-dim}"
mkdir -p "$D/bin" "$D/state"
echo 100 > "$D/val.5"
cat > "$D/bin/ddcutil" <<STUB
#!/usr/bin/env bash
W="$D"
printf '%s %s\n' "\$(date +%s%3N)" "\$*" >> "\$W/ddcutil.log"
case "\$1" in
    detect) sleep 0.3
            c=card1-DP-1; [ -e "\$W/on_dp2" ] && c=card1-DP-2
            printf 'Display 1\n   I2C bus:          /dev/i2c-5\n   DRM connector:    %s\n   Monitor:          DEL:DELL U2723QE:7ZQ4PX3\n\n' "\$c" ;;
    getvcp) sleep 0.27; printf 'VCP 10 C %s 100\n' "\$(cat "\$W/val.5")" ;;
    setvcp) n=\$(cat "\$W/fail_sets" 2> /dev/null || echo 0)
            if [ "\$n" -gt 0 ]; then echo \$((n - 1)) > "\$W/fail_sets"; sleep 0.28; echo "DDC communication failed" >&2; exit 1; fi
            cp "\$W/state/ddc-dim.json" "\$W/saved_at_set" 2> /dev/null || : > "\$W/saved_at_set"
            sleep 0.28; printf '%s\n' "\$3" > "\$W/val.5" ;;
    *) echo "stub: refused \$*" >&2; exit 99 ;;
esac
STUB
chmod +x "$D/bin/ddcutil"
printf '%s' "$A" > "$D/a"; printf '%s' "$B" > "$D/b"
cat > "$D/run.sh" <<RUN_EOF
if [ -n "${ARM:-}" ]; then
python3 - <<'PY' || exit 3
a, b = open("$D/a").read(), open("$D/b").read()
s = open("$F").read()
if s.count(a) != 1:
    print("ARMLOST"); raise SystemExit(1)
s = s.replace(a, b)
if "${ARM:-}" == "latesave":
    s = s.replace("    Timer {\n        id: again\n", "    Timer {\n        id: late\n        property string key: ''\n        property var entry: null\n        interval: 100\n        onTriggered: root._save(late.key, late.entry)\n    }\n    Timer {\n        id: again\n", 1)
open("$F", "w").write(s)
PY
fi
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi DDP_W="$D" DDP_PROGRAM="$D/bin/ddcutil" timeout 150 quickshell -p tools/dev/qml/ddc_dim_probe.qml
RUN_EOF
tools/dev/sandbox.sh bash "$D/run.sh" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'DDP .*' | grep -a -v 'DDP RESULT'
if [ -n "${ARM:-}" ]; then
    if rl_has "$D/log" 'ARMLOST'; then echo "ARM $ARM: its anchor matched nothing -- it proves nothing"; exit 1; fi
    if rl_clean "$D/log" | grep -a -E -q "DDP FAIL .*($NEEDLE)"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    rl_has "$D/log" 'DDP RESULT' || { echo "ARM $ARM: the armed copy did not load -- it proves nothing"; exit 1; }
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result DDCDIM "$D/log" 'DDP RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi
if rl_clean "$D/log" | grep -a -E -q 'TypeError|ReferenceError|Binding loop|Unable to assign'; then rl_clean "$D/log" | grep -a -E 'TypeError|ReferenceError|Binding loop|Unable to assign' | head -5; echo "DDCDIM RESULT FAIL (warnings)"; exit 1; fi
printf '%s\n' "$res" | sed 's/^DDP RESULT/DDCDIM RESULT/'
exit $rc
