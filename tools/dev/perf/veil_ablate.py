#!/usr/bin/env python3
"""veil_ablate.py -- what one term of a veil costs: a copy of this tree with ONE term turned off (or one rewrite in), its
shaders re-baked in the copy, measured by tools/dev/perf/veil_perf.sh --ab against this tree IN THE SAME PROCESS (phases of
A and B alternate, A B then B A, and the reader pairs them round by round): two separate runs do not compare on this machine,
where the driver moves the GPU's clock 524-1837 MHz with other sessions' load between them.

    tools/dev/perf/veil_ablate.py SPEC.json OUTDIR [--res 2880x1620] [--only name,name]
    ABL_ROUNDS=6 ABL_PHASE_MS=1500 ABL_GUI_N=400 (veil_perf.sh's ROUNDS / PHASE_MS / GUI_N)

SPEC.json: {"<ablation>": {"veil": "relief", "edits": [["modules/lockscreen/veil/VeilRelief.qml" or
".../shaders/veil_relief.frag", "<old>", "<new>"], ...]}}. Only the veil's own directory and its shaders are B's
(veil_perf.sh --ab), so an edit elsewhere is refused. Every <old> must occur exactly once (an anchor that moved is a FAIL,
not a silent no-op); an edited .frag / .vert is re-baked. Prints per ablation veil_perf.py's A/B line: the veil's own GPU
time (less the round's floor) of A and B, B - A with its spread over the rounds, the same in GPU cycles, the binding share
of a tick and the cold first frame of each. A difference that the spread spans is no difference. Ends in
VEIL_ABLATE RESULT PASS|FAIL.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
OWN = ("modules/lockscreen/veil/", "modules/lockscreen/shaders/")


def build(dst, edits):
    os.makedirs(dst, exist_ok=True)
    for d in ("modules", "themes", "tools"):
        subprocess.run(["rsync", "-a", "--exclude", ".qmlls.ini", os.path.join(HERE, d), dst], check=True)
    baked = set()
    for f, old, new in edits:
        if not f.startswith(OWN):
            raise SystemExit("VEIL_ABLATE RESULT FAIL (%s is not a veil's own file: B takes only those)" % f)
        p = os.path.join(dst, f)
        s = open(p).read()
        if s.count(old) != 1:
            raise SystemExit("VEIL_ABLATE RESULT FAIL (%d occurrences of the anchor in %s: %r)" % (s.count(old), f, old[:80]))
        open(p, "w").write(s.replace(old, new))
        if f.endswith((".frag", ".vert")):
            baked.add(os.path.splitext(os.path.basename(f))[0])
    for pack in sorted(baked):
        r = subprocess.run(["bash", os.path.join(dst, "tools/dev/bake_shaders.sh"), pack], capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit("VEIL_ABLATE RESULT FAIL (the bake of %s in the copy failed:\n%s)" % (pack, (r.stdout + r.stderr)[-2000:]))


def main():
    args = sys.argv[1:]
    res, only = "2880x1620", None
    for flag in ("--res", "--only"):
        if flag in args:
            i = args.index(flag)
            v = args[i + 1]
            del args[i:i + 2]
            if flag == "--res":
                res = v
            else:
                only = v.split(",")
    if len(args) != 2:
        print(__doc__)
        return 2
    spec = json.load(open(args[0]))
    outdir = os.path.abspath(args[1])
    os.makedirs(outdir, exist_ok=True)
    work = tempfile.mkdtemp(prefix="lrvab.", dir="/tmp")
    try:
        for n in [n for n in spec if not only or n in only]:
            veil = spec[n]["veil"]
            tree = os.path.join(work, n)
            build(tree, spec[n].get("edits", []))
            env = dict(os.environ)
            env.update({"RES": res, "VEILS": "none,%s,b:%s" % (veil, veil), "ROUNDS": env.get("ABL_ROUNDS", "6"),
                        "PHASE_MS": env.get("ABL_PHASE_MS", "1500"), "GUI_N": env.get("ABL_GUI_N", "400"), "KEEP_ENV": "1"})
            out = os.path.join(outdir, n)
            r = subprocess.run([os.path.join(HERE, "tools/dev/perf/veil_perf.sh"), out, "--ab", tree], capture_output=True, text=True, env=env)
            line = [ln for ln in r.stdout.splitlines() if ln.strip().startswith("A/B")]
            if r.returncode != 0 or not line:
                print("VEIL_ABLATE RESULT FAIL (%s did not measure: %s)" % (n, r.stdout[-1500:]))
                return 1
            print("  %-24s %s" % (n, line[0].strip()), flush=True)
            shutil.rmtree(tree, ignore_errors=True)
        print("VEIL_ABLATE RESULT PASS")
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
