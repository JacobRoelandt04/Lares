#!/usr/bin/env bash
# configfile_probe.sh -- ConfigFile (modules/common/components): a hand-edited config is `<name>.jsonc` first, then `<name>.json`.
#
#   tools/dev/configfile_probe.sh                CONFIGFILE RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=nojsonc tools/dev/configfile_probe.sh    the .jsonc is never looked at (the old behaviour): the .jsonc cases go red
#   ARM=jsonwins tools/dev/configfile_probe.sh   the .json wins when both exist: the "both present" case goes red
#   ARM=lateflags tools/dev/configfile_probe.sh   which file exists is learnt in ConfigFile's own onCompleted (after its host's): the
#                                             "host's own onCompleted" case goes red
#   ARM=noold    the old places are never read (a config not moved yet is lost): the f / g cases go red
#   ARM=oldwins  the old place wins over config/: the h case goes red
#   ARM=nomkdir  a first write does not make config/ first: the k write case goes red
#
# Files in a private directory: a.json alone (a comment in it), b with both, c with neither, d named .jsonc with only the .json
# there, plain.txt (no JSON name). Then a .jsonc created beside a.json, removed again, and writes with neither / only a .json.
# The verdict is the probe's own RESULT line (tools/dev/result_lib.sh).
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/cf.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT     # KEEP=1, or a run with no result, keeps the dir (the verdict names a log in it)
printf '// from a.json\n{ "from": "a.json" }\n' > "$D/a.json"
printf '{"from":"b.json"}' > "$D/b.json"
printf '// b: the comment a .jsonc may have\n{"from":"b.jsonc"}\n' > "$D/b.jsonc"
printf '{"from":"d.json"}' > "$D/d.json"
printf 'plain\n' > "$D/plain.txt"
# the config/ folder: f only in the old place (.jsonc), g only in the old place (.json), h in both; fresh/ has no config/ yet
mkdir -p "$D/config" "$D/fresh"
printf '{"from":"old f.jsonc"}' > "$D/f.jsonc"
printf '{"from":"old g.json"}' > "$D/g.json"
printf '{"from":"old h.jsonc"}' > "$D/h.jsonc"
printf '// the new place\n{"from":"config/h.jsonc"}\n' > "$D/config/h.jsonc"
# An ARM is an exact anchor in ConfigFile (patched in the sandbox copy); a missing anchor stops the run (it would prove nothing).
cat > "$D/arm.py" <<'ARMPY'
import sys
p, a, b = sys.argv[1], open(sys.argv[2]).read(), open(sys.argv[3]).read()
s = open(p).read()
if s.count(a) != 1:
    print("ARM anchor gone (%d): %r" % (s.count(a), a[:80])); sys.exit(1)
open(p, "w").write(s.replace(a, b))
ARMPY
arm() { printf '%s' "$1" > "$D/arm.from"; printf '%s' "$2" > "$D/arm.to"; ARMCMD="python3 $D/arm.py modules/common/components/ConfigFile.qml $D/arm.from $D/arm.to"; }
# the armed copy lives in the sandbox like the real one; the arm patches ConfigFile there
ARMCMD=""
case "${ARM:-}" in
    "") ;;
    nojsonc)  arm '    readonly property bool jsoncExists: jsoncView.loaded' '    readonly property bool jsoncExists: false' ;;
    jsonwins) arm 'JsonComments.pickFile(root.jsoncExists, root.jsonExists, root.oldJsoncExists, root.oldJsonExists)' \
                  'JsonComments.pickFile(root.jsoncExists && !root.jsonExists, root.jsonExists, root.oldJsoncExists, root.oldJsonExists)' ;;
    noold)    arm 'JsonComments.pickFile(root.jsoncExists, root.jsonExists, root.oldJsoncExists, root.oldJsonExists)' \
                  'JsonComments.pickFile(root.jsoncExists, root.jsonExists, false, false)' ;;
    oldwins)  arm 'JsonComments.pickFile(root.jsoncExists, root.jsonExists, root.oldJsoncExists, root.oldJsonExists)' \
                  'JsonComments.pickFile(root.oldJsoncExists || (root.jsoncExists && !root.oldJsoncExists), root.jsonExists, false, root.oldJsonExists)' ;;
    nomkdir)  arm '        firstWrite.running = true;' '        jsoncView.setText(t);' ;;
    lateflags) ARMCMD="sed -i -e 's|^    readonly property bool jsoncExists: jsoncView.loaded|    property bool jsoncExists: false|' -e 's|^    readonly property bool jsonExists: .*|    property bool jsonExists: false|' -e 's|^        root._was = root.active;|        root.jsoncExists = jsoncView.loaded; root.jsonExists = root.jsonPath.length > 0 \&\& jsonView.loaded; root._was = root.active;|' modules/common/components/ConfigFile.qml" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi CF_DIR='"$D"' timeout 60 quickshell -p tools/dev/qml/configfile_probe.qml'
tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a '^CF ' | grep -a -v 'CF RESULT'
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -q 'CF FAIL'; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if ! rl_has "$D/log" 'CF RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL -- the probe cannot see it"; exit 1
fi
res=$(rl_result CONFIGFILE "$D/log" 'CF RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP_D=1; [ -n "${ARM:-}" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing"; printf '%s\n' "$res"; exit 1; fi
printf '%s\n' "$res" | sed 's/^CF RESULT/CONFIGFILE RESULT/'
exit $rc
