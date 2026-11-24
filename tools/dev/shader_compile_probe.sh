#!/usr/bin/env bash
# shader_compile_probe.sh -- every shader pack of the shell, compiled by a real driver: one window draws each .qsb once (a .frag
# with its .vert, or a lone .vert), which makes Qt build every pipeline, and the log is read for the driver's refusals.
#
#   tools/dev/shader_compile_probe.sh [outdir]        offscreen (QT_QPA_PLATFORM=offscreen + RHI: the desktop GL the gates use)
#   WAYLAND=1 tools/dev/shader_compile_probe.sh       the user's own session's context: on the Intel GPU desktop GL 4.6 (the 150
#                                                 variants), in dGPU-only mode NVIDIA's OpenGL ES 3.2 (the 300 es ones). The window
#                                                 opens where Hyprland puts new windows; it need not be shown, the first frame
#                                                 renders anyway. Nothing else of the session is touched (a private XDG_CONFIG_HOME).
#   ARM=novariant tools/dev/shader_compile_probe.sh   one pack (the gooey field's vertex shader) re-baked with ONLY a GLSL 100 es
#                                                 variant into the outdir: no context but GLES 2 can use it, so the run must FAIL
#   ATTRIBUTE=<probe.log> [PAIRS_JSON=<pairs.json>] tools/dev/shader_compile_probe.sh
#                                                 no run: name the packs behind an earlier log's refusals (the packs of
#                                                 PAIRS_JSON, default the pairs.json beside the log)
#   ends in SHADER_COMPILE RESULT PASS|FAIL
#
# A REFUSAL NAMES ITS PACK. Qt prints the source it handed the driver after "Source was:", and that is one GLSL variant of one
# pack byte for byte; each refusal is matched against every variant of every pack drawn and printed as
#   REFUSED <pack> (GLSL <version>) x<times>: <the driver's first error line>
# -- so a dGPU-only run says which packs and which variant (on NVIDIA's ES context: 100 es for an effect with Qt's own vertex
# shader, 300 es for one with its own; tools/dev/bake_shaders.sh), not only how many.
#
# WHY. In dGPU-only mode (2026-10-11) Qt got an OpenGL ES 3.2 context from NVIDIA where the Intel GPU gives it desktop GL, and
# with no 300 es variant in the packs it took the 100 es one, which NVIDIA's compiler refused (an array constructor: error
# C7553) -- the gooey field drew nothing, so the bar and every popup's surface were gone. Mesa accepts the same source, so no
# gate on the Intel GPU could see it. tools/dev/bake_shaders.sh now bakes 300 es and checks every pack has it; this probe is the
# proof on the driver itself: run it with WAYLAND=1 in dGPU-only mode, and after a driver or Qt update.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
. "$ROOT/tools/dev/result_lib.sh"
NAME=SHADER_COMPILE
# attribute <log> <pairs.json>: every "Failed to compile shader" of the log, named by the pack variant whose text is the source printed
attribute() {
    python3 -B - "$1" "$2" <<'PY'
import collections, json, os, re, subprocess, sys, tempfile
qsb = "/usr/lib/qt6/bin/qsb"
norm = lambda text: "\n".join(l.rstrip() for l in text.strip("\n").splitlines()).strip()
index, work = {}, tempfile.mkdtemp(prefix="lares-sc-attr-")
packs = []
for p in json.load(open(sys.argv[2])):
    for k in ("frag", "vert"):
        if p.get(k):
            packs.append(p[k][len("file://"):] if p[k].startswith("file://") else p[k])
for pack in sorted(set(packs)):
    dump = subprocess.run([qsb, "--dump", pack], capture_output=True, text=True).stdout
    for m in re.finditer(r"^\s*Shader \d+: GLSL (\d+)( es)? \[(\w+)\]", dump, re.M):
        ver = m.group(1) + ("es" if m.group(2) else "")
        f = os.path.join(work, "v")
        subprocess.run([qsb] + (["-b"] if m.group(3) == "Batchable" else []) + ["-x", "glsl," + ver, "-o", f, pack], capture_output=True)
        if os.path.exists(f):
            index[norm(open(f, encoding="utf-8", errors="replace").read())] = "%s (GLSL %s)" % (os.path.basename(pack), ver.replace("es", " es"))
subprocess.run(["rm", "-rf", work])
lines = re.sub(r"\x1b\[[0-9;]*m", "", open(sys.argv[1], encoding="utf-8", errors="replace").read()).splitlines()
logline = re.compile(r"^\s*(WARN|DEBUG|INFO|ERROR|FATAL|CRITICAL)\b")
seen = collections.Counter()
i = 0
while i < len(lines):
    if "Failed to compile shader:" not in lines[i]:
        i += 1
        continue
    err = lines[i].split("Failed to compile shader:", 1)[1].strip()
    j = i + 1
    while j < len(lines) and lines[j].strip() != "Source was:" and not logline.match(lines[j]):
        j += 1
    src = []
    if j < len(lines) and lines[j].strip() == "Source was:":
        j += 1
        while j < len(lines) and not logline.match(lines[j]):
            src.append(lines[j])
            j += 1
    seen[(index.get(norm("\n".join(src)), "a source none of these packs holds (Qt's own shader, or another bake)"), err)] += 1
    i = j
for (who, err), n in sorted(seen.items()):
    print("  REFUSED %s x%d: %s" % (who, n, err))
PY
}
if [ -n "${ATTRIBUTE:-}" ]; then
    pj="${PAIRS_JSON:-$(dirname "$ATTRIBUTE")/pairs.json}"
    [ -f "$pj" ] || { echo "$NAME RESULT FAIL (no pairs.json beside $ATTRIBUTE: name one with PAIRS_JSON)"; exit 1; }
    n=$(rl_clean "$ATTRIBUTE" | grep -a -c "Failed to compile shader")
    attribute "$ATTRIBUTE" "$pj"
    [ "$n" -gt 0 ] && { echo "$NAME RESULT FAIL ($n refusals in $ATTRIBUTE)"; exit 1; }
    echo "$NAME RESULT PASS (no refusal in $ATTRIBUTE)"; exit 0
fi
OUT="${1:-${SCRATCH:-/tmp}/shader-compile}"
mkdir -p "$OUT/cfg/theme"
printf '{"theme":"eva","mode":"light"}\n' > "$OUT/cfg/theme/state.json"
python3 - "$ROOT" "$OUT" "${ARM:-}" > "$OUT/pairs.json" <<'PY' || { echo "$NAME RESULT FAIL (packs)"; exit 1; }
import glob, json, os, re, subprocess, sys
root, out, arm = sys.argv[1], sys.argv[2], sys.argv[3]
dirs = ["modules/common/components/shaders", "modules/lockscreen/shaders", "modules/silicon/shaders", "modules/aerial/shaders", "modules/theme/shaders", "modules/bar/player/components/shaders", "modules/notifications/shaders", "modules/bridge/shaders",
        "modules/weather/shaders", "modules/idle/sleep/shaders", "modules/bar/gooey/shaders", "modules/wiki/shaders"]
url = lambda p: "file://" + p
pairs = []
for d in dirs:
    # a VARIANT pack (tools/dev/bake_shaders.sh: `// QSB-VARIANT: <name> <MACRO>` in <base>.frag bakes <name>.frag.qsb) is the same
    # source drawn with its base's vertex shader: paired with Qt's own it would be refused for what it is not (the gooey field's REEL_PASS)
    base_of = {}
    for src in glob.glob(f"{root}/{d}/*.frag"):
        for m in re.finditer(r"(?m)^// QSB-VARIANT: *([A-Za-z0-9_]+) +[A-Za-z0-9_]+ *$", open(src, encoding="utf-8", errors="replace").read()):
            base_of[m.group(1)] = src[:-len(".frag")]
    for f in sorted(glob.glob(f"{root}/{d}/*.frag.qsb")):
        v = f[:-len(".frag.qsb")] + ".vert.qsb"
        name = os.path.basename(f)[:-len(".frag.qsb")]
        if not os.path.exists(v) and name in base_of:
            v = base_of[name] + ".vert.qsb"
        pairs.append({"frag": url(f), "vert": url(v) if os.path.exists(v) else ""})
    for v in sorted(glob.glob(f"{root}/{d}/*.vert.qsb")):
        if not os.path.exists(v[:-len(".vert.qsb")] + ".frag.qsb"):
            pairs.append({"frag": "", "vert": url(v)})
if arm == "novariant":
    src = f"{root}/modules/bar/gooey/shaders/gooey_field.vert"
    dst = f"{out}/gooey_field.vert.qsb"
    subprocess.check_call(["/usr/lib/qt6/bin/qsb", "--glsl", "100 es", "-o", dst, src])
    for p in pairs:
        if p["vert"].endswith("/gooey_field.vert.qsb"):
            p["vert"] = url(dst)
elif arm:
    sys.exit(f"unknown ARM {arm}")
print(json.dumps(pairs))
PY
n=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$OUT/pairs.json")
log="$OUT/probe.log"
if [ -n "${WAYLAND:-}" ]; then
    PAIRS="$(cat "$OUT/pairs.json")" XDG_CONFIG_HOME="$OUT/cfg" QSG_INFO=1 timeout 60 quickshell -p tools/dev/qml/shader_compile_probe.qml > "$log" 2>&1
else
    env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QSG_INFO=1 PAIRS="$(cat "$OUT/pairs.json")" XDG_CONFIG_HOME="$OUT/cfg" \
        tools/dev/sandbox.sh timeout 60 quickshell -p tools/dev/qml/shader_compile_probe.qml > "$log" 2>&1
fi
rl_has "$log" "SHADER_COMPILE drew $n packs" || { rl_noresult "$NAME" "$log"; exit 1; }
ctx=$(rl_clean "$log" | grep -a -o "OpenGL VENDOR: .*" | head -1)
bad=$(rl_clean "$log" | grep -a -c -E "Failed to compile shader|Failed to build graphics pipeline|shader preparation failed|No shader found|Failed to link")
echo "  $n packs on: ${ctx:-(no GL context named)}"
if [ "$bad" -gt 0 ]; then
    attribute "$log" "$OUT/pairs.json"
    rl_clean "$log" | grep -a -E "No shader found|Failed to link" | sort | uniq -c | head -5
    echo "$NAME RESULT FAIL ($bad refusals: $log)"; exit 1
fi
echo "$NAME RESULT PASS ($n packs, none refused)"
