#!/usr/bin/env python3
"""shader_ubo_match.py -- every vertex shader's uniform block equals its fragment shader's.

    tools/dev/shader_ubo_match.py [dir ...]      default: the shell's shader directories

Qt requires the `buf` uniform block (std140, binding 0) to be the SAME in both
stages of a ShaderEffect. Nothing checks it: when a member is added to the
.frag and not the .vert, every later member sits at another offset in one
stage, and the shader reads garbage with no warning. The gooey veil's blobs
stopped merging that way (round 3: `pourFeather` added after `presence` in
veil_gooey.frag only, so the vertex stage read `smoothK` from the wrong place).

A pair is X.vert with X.frag, or X.vert with every X_*.frag / X.frag that the
same ShaderEffect may load; here simply: X.vert against X.frag. Blocks are
compared member by member (type and name, in order), comments and whitespace
ignored. Prints SHADER_UBO RESULT PASS|FAIL.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DIRS = ["modules/common/components/shaders", "modules/lockscreen/shaders", "modules/silicon/shaders", "modules/aerial/shaders", "modules/notifications/shaders", "modules/bridge/shaders", "modules/theme/shaders",
        "modules/bar/player/components/shaders", "modules/weather/shaders", "modules/idle/sleep/shaders", "modules/bar/gooey/shaders", "modules/wiki/shaders"]


def block(path):
    src = open(path, encoding="utf-8", errors="replace").read()
    src = re.sub(r"//[^\n]*", "", src)
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    m = re.search(r"uniform\s+buf\s*\{(.*?)\}", src, flags=re.S)
    if not m:
        return None
    members = []
    for decl in m.group(1).split(";"):
        decl = " ".join(decl.split())
        if decl:
            members.append(decl)
    return members


def main(argv):
    dirs = argv or [os.path.join(ROOT, d) for d in DIRS]
    bad = 0
    pairs = 0
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if not name.endswith(".vert"):
                continue
            vert = os.path.join(d, name)
            frag = vert[:-5] + ".frag"
            if not os.path.exists(frag):
                print(f"SHADER_UBO {name}: no {os.path.basename(frag)} to compare with")
                continue
            vb, fb = block(vert), block(frag)
            pairs += 1
            if vb is None or fb is None:
                print(f"SHADER_UBO {name}: no `uniform buf` block in {'vert' if vb is None else 'frag'}")
                bad += 1
                continue
            if vb != fb:
                bad += 1
                n = min(len(vb), len(fb))
                i = next((k for k in range(n) if vb[k] != fb[k]), n)
                print(f"SHADER_UBO {name}: blocks differ at member {i}: "
                      f"vert '{vb[i] if i < len(vb) else '(end)'}' vs frag '{fb[i] if i < len(fb) else '(end)'}' "
                      f"({len(vb)} vs {len(fb)} members)")
    print(f"SHADER_UBO RESULT {'PASS' if bad == 0 else 'FAIL'} ({pairs} pair(s), {bad} mismatched)")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
