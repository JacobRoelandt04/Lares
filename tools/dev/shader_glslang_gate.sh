#!/usr/bin/env bash
# shader_glslang_gate.sh -- every GLSL variant of every shader pack, validated by glslang for its own stage and version: a variant a driver
# refuses for its LANGUAGE (an array constructor or a constant array in GLSL ES 1.00, an integer clamp / min / max in GLSL 1.20 or ES 1.00)
# fails here, with no GPU and no quickshell.
#
#   tools/dev/shader_glslang_gate.sh                  every pack under modules/ (each GLSL variant `qsb --dump` lists: 100 es, 120, 150, 300 es)
#   tools/dev/shader_glslang_gate.sh <pack.qsb ...>   these packs (tools/dev/bake_shaders.sh runs it over its own)
#   ARM=arrayctor tools/dev/shader_glslang_gate.sh    in a sandbox copy, the vinyl's ES 1.00 table guard taken out (its constant array is back in
#                                                     the 100 es variant): the copy's bake and this gate must both FAIL naming the pack and line
#   ARM=intclamp ...                                  in a copy, the network glyph's integer clamp put back (refused by GLSL 1.20 AND ES 1.00)
#   ARM=instname ...                                  in a copy, the vinyl's ES branch given constants of its own (the SPIR-V ids shift): its 100 es variant names its
#                                                     uniform struct by another id than the reflection does -- the bake and the gate must FAIL
#   ARM=all ...                                       all three; every ARM run ends in SHADER_GLSLANG ARMS RESULT PASS|FAIL
#   ends in SHADER_GLSLANG RESULT PASS|FAIL, and the exit status follows it
#
# WHY. In dGPU-only mode (2026-11-04, 2026-11-10) NVIDIA's OpenGL ES 3.2 context refused five packs (the silicon board, the vinyl, the
# weather glyphs, the weather backdrop, the network glyph): C7516 / C7553 (a constant array: "array assignments require #version 120") and
# C7011 (an integer clamp / min, which GLSL ES 1.00 does not have). Every refused source was the 100 es variant: Qt 6.12 links a pipeline
# at the highest GLSL ES version EVERY stage has, and a ShaderEffect with no vertex shader of its own takes Qt Quick's, which carries 100 es,
# 120 and 150 only -- so on any ES context such an effect runs 100 es, whatever its fragment pack holds (tools/dev/bake_shaders.sh). Mesa
# accepted the same sources, so no gate on the Intel GPU saw it; glslang reports all six offline at the very lines NVIDIA named (the sixth,
# the gooey field's vertex array constructor, NVIDIA never compiled: that pipeline links at 300 es). The desktop variants are judged too:
# GLSL 1.20 (the offscreen context) has no integer clamp either.
set -u
cd "$(dirname "$0")/../.." || exit 2
ROOT=$(pwd)
NAME=SHADER_GLSLANG
QSB=/usr/lib/qt6/bin/qsb

# ---- the arms: the fault goes into a sandbox copy (re-synced on every sandbox.sh call), and the copy runs its own bake and its own gate
if [ -n "${ARM:-}" ] && [ -z "${_GLSLANG_ARM_COPY:-}" ]; then
    case "$ARM" in all) arms=(arrayctor intclamp instname) ;; arrayctor|intclamp|instname) arms=("$ARM") ;; *) echo "unknown ARM=$ARM (arrayctor|intclamp|instname|all)"; exit 2 ;; esac
    export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-shaderglslang-$$}"
    own_sb=0; [ -e "$SANDBOX" ] || own_sb=1
    bad=0
    for a in "${arms[@]}"; do
        out=$(tools/dev/sandbox.sh env _GLSLANG_ARM_COPY=1 ARM="$a" bash tools/dev/shader_glslang_gate.sh 2>&1)
        printf '%s\n' "$out" | sed "s/^/  [$a] /"
        if printf '%s\n' "$out" | grep -q "^ARM $a: FAILED AS IT MUST"; then echo "ARM $a: FAILED AS IT MUST"
        else echo "ARM $a: DID NOT FAIL AS IT MUST"; bad=$((bad + 1)); fi
    done
    [ "$own_sb" = 1 ] && rm -rf "$SANDBOX"
    [ "$bad" = 0 ] && { echo "$NAME ARMS RESULT PASS (${arms[*]} failed as they must)"; exit 0; }
    echo "$NAME ARMS RESULT FAIL ($bad of ${#arms[@]} did not fail as they must)"; exit 1
fi
if [ -n "${_GLSLANG_ARM_COPY:-}" ]; then
    # inside the copy: never the tree (a copy has no .git)
    [ -e .git ] && { echo "ARM $ARM: refused, this is a git tree, not a sandbox copy"; exit 2; }
    case "$ARM" in
        arrayctor) src=modules/common/components/shaders/vinyl_disc.frag; pack=vinyl_disc; needle="vinyl_disc.frag.qsb glsl 100 es: 0:[0-9]+: 'arrayed constructor'"
                   py='import sys
p = sys.argv[1]; s = open(p).read()
g = "#if defined(QSHADER_GLSL_ES) && QSHADER_GLSL_VERSION < 300"
if s.count(g) != 2: sys.exit("anchor: %d guards, wanted 2" % s.count(g))
open(p, "w").write(s.replace(g, "#if 0"))' ;;
        instname)  src=modules/common/components/shaders/vinyl_disc.frag; pack=vinyl_disc; needle="vinyl_disc.frag.qsb glsl 100 es: uniform instance _[0-9]+ is not the reflection's _[0-9]+"
                   py='import sys
p = sys.argv[1]; s = open(p).read()
a = "vec2 SUBS[8];\n#else"; b = "    SUBS[4] = SUB4;"
if s.count(a) != 1 or s.count(b) != 1: sys.exit("anchor: %d %d, wanted 1 1" % (s.count(a), s.count(b)))
s = s.replace(a, "vec2 SUBS[8];\nconst float ARM_A = 0.1234; const float ARM_B = 0.2345; const float ARM_C = 0.3456; const float ARM_D = 0.4567;\nfloat armPad(float x) { return x * ARM_A + ARM_B * ARM_C - ARM_D; }\n#else")
s = s.replace(b, "    SUBS[0].x += armPad(0.0) * 0.0;\n" + b)
open(p, "w").write(s)' ;;
        intclamp)  src=modules/common/components/shaders/net_glyph.frag; pack=net_glyph; needle="net_glyph.frag.qsb glsl 120: 0:[0-9]+: "
                   py='import sys
p = sys.argv[1]; s = open(p).read()
a = "int n = int(clamp(partCount + 0.5, 0.0, 8.0));"
if s.count(a) != 1: sys.exit("anchor: %d, wanted 1" % s.count(a))
open(p, "w").write(s.replace(a, "int n = clamp(int(partCount + 0.5), 0, 8);"))' ;;
    esac
    python3 -c "$py" "$src" || { echo "ARM $ARM: the anchor is gone"; exit 1; }
    bake=$(env -u ARM -u _GLSLANG_ARM_COPY bash tools/dev/bake_shaders.sh "$pack" 2>&1); brc=$?
    printf '%s\n' "$bake" | grep -E "^(ok|FAIL|BAKE)" | head -4
    gate=$(env -u ARM -u _GLSLANG_ARM_COPY bash tools/dev/shader_glslang_gate.sh 2>&1); grc=$?
    printf '%s\n' "$gate" | grep -E "^REFUSED|RESULT" | head -4
    if [ "$brc" != 0 ] && printf '%s\n' "$bake" | grep -q -E "$needle" && [ "$grc" != 0 ] && printf '%s\n' "$gate" | grep -q -E "$needle"; then
        echo "ARM $ARM: FAILED AS IT MUST (the bake and the gate: $(printf '%s\n' "$gate" | grep -m1 -o -E "$needle"))"; exit 1
    fi
    echo "ARM $ARM: did not fail as it must (bake rc $brc, gate rc $grc, wanted /$needle/ in both)"; exit 0
fi

# ---- the gate
command -v glslangValidator > /dev/null || { echo "$NAME RESULT FAIL (glslangValidator missing: pacman -S glslang)"; exit 1; }
[ -x "$QSB" ] || { echo "$NAME RESULT FAIL ($QSB missing: pacman -S qt6-shadertools)"; exit 1; }
if [ $# -gt 0 ]; then packs=("$@"); else mapfile -t packs < <(find modules -name '*.qsb' | sort); fi
[ ${#packs[@]} -gt 0 ] || { echo "$NAME RESULT FAIL (no packs found)"; exit 1; }
python3 -B - "$QSB" "${packs[@]}" <<'PY'
import concurrent.futures, json, os, re, subprocess, sys, tempfile
qsb, packs = sys.argv[1], sys.argv[2:]
STAGES = {"vert": "vert", "frag": "frag", "comp": "comp", "geom": "geom", "tesc": "tesc", "tese": "tese"}
work = tempfile.mkdtemp(prefix="lares-glslang-")


def variants(pack):
    """The GLSL entries `qsb --dump` lists: (version as qsb names it, batchable)."""
    r = subprocess.run([qsb, "--dump", pack], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    out = []
    for m in re.finditer(r"^\s*Shader \d+: GLSL (\d+)( es)? \[(\w+)\]", r.stdout, re.M):
        out.append((m.group(1) + ("es" if m.group(2) else ""), m.group(3) == "Batchable"))
    return sorted(set(out))


# A GLSL variant without uniform buffers (120, ES 1.00) names its uniform block's INSTANCE `_<id>` -- a SPIR-V id -- and Qt finds every member by the name the
# pack's REFLECTION gives (`structName`, from the first target's SPIR-V). A per-target bake (qsb -p) whose source differs between targets numbers the ids
# differently, the two names part, Qt finds no uniform and the effect draws with every one at 0 and no warning (the silicon board's 100 es variant, 2026-11-11:
# the glows drew, the board did not). A variant that no pipeline can reach is exempt, with its reason.
UNREACHABLE = {
    # gooey_field.vert has a 300 es variant and so has its fragment pack: the field's pipeline always links there
    ("gooey_field.vert.qsb", "100es"): "the gooey field links at 300 es (its own vertex shader)",
}
reflected = {}


def reflection_names(pack):
    if pack not in reflected:
        names = set()
        r = subprocess.run([qsb, "--dump", pack], capture_output=True, text=True).stdout
        try:
            i = r.index("Reflection info:")
            j = r.index("\n}\n", i)
            for blk in json.loads(r[i + len("Reflection info:"):j + 3]).get("uniformBlocks", []):
                if blk.get("structName"):
                    names.add(blk["structName"])
        except ValueError:
            pass
        reflected[pack] = names
    return reflected[pack]


def check(job):
    pack, ver, batch, stage, i = job
    label = "%s glsl %s%s" % (pack, ver.replace("es", " es"), " batchable" if batch else "")
    f = os.path.join(work, "%d.%s" % (i, stage))
    r = subprocess.run([qsb] + (["-b"] if batch else []) + ["-x", "glsl," + ver, "-o", f, pack], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(f):
        return label, ["could not extract: " + (r.stderr.strip().splitlines() or ["?"])[0]]
    v = subprocess.run(["glslangValidator", "-S", stage, f], capture_output=True, text=True)
    if v.returncode == 0:
        if ver in ("100es", "120") and (os.path.basename(pack), ver) not in UNREACHABLE:
            text = open(f, encoding="utf-8", errors="replace").read()
            inst = {x for x in re.findall(r"^uniform \w+ (_\w+);", text, re.M)}
            want = reflection_names(pack)
            if inst and not inst <= want:
                return label, ["uniform instance %s is not the reflection's %s: Qt finds no uniform by that name and every one reads 0"
                               % (",".join(sorted(inst)), ",".join(sorted(want)) or "(none)")]
        return label, []
    src = open(f, encoding="utf-8", errors="replace").read().splitlines()
    errs = []
    for line in (v.stdout + v.stderr).splitlines():
        m = re.match(r"ERROR: 0:(\d+): (.*)", line)
        if m and "compilation terminated" not in m.group(2):
            n = int(m.group(1))
            text = src[n - 1].strip() if 0 < n <= len(src) else ""
            errs.append("0:%d: %s | %s" % (n, m.group(2).strip(), text[:110]))
    return label, errs or ["glslang refused it: " + " ".join((v.stdout + v.stderr).split())[:200]]


jobs, bad, nopack = [], [], []
for pack in packs:
    base = os.path.basename(pack)
    m = re.match(r".*\.(\w+)\.qsb$", base)
    stage = STAGES.get(m.group(1)) if m else None
    vs = variants(pack) if stage else None
    if not stage:
        nopack.append("%s: no stage in its name (<name>.<vert|frag|...>.qsb)" % pack)
    elif vs is None:
        nopack.append("%s: qsb --dump could not read it" % pack)
    elif not vs:
        nopack.append("%s: no GLSL variant at all" % pack)
    else:
        jobs += [(pack, ver, batch, stage, len(jobs) + k) for k, (ver, batch) in enumerate(vs)]
with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
    results = list(ex.map(check, jobs))
for label, errs in results:
    for e in errs[:3]:
        print("REFUSED %s: %s" % (label, e))
    if errs:
        bad.append(label)
for n in nopack:
    print("BAD", n)
subprocess.run(["rm", "-rf", work])
if bad or nopack:
    print("SHADER_GLSLANG RESULT FAIL (%d of %d variants refused, %d packs unreadable: %s)"
          % (len(bad), len(results), len(nopack), ", ".join(sorted({os.path.basename(b.split(" glsl ")[0]) for b in bad}))[:300]))
    sys.exit(1)
print("SHADER_GLSLANG RESULT PASS (%d packs, %d GLSL variants valid for their stage and version)" % (len(packs), len(results)))
PY
