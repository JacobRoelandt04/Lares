#!/usr/bin/env python3
"""ONE SHUFFLE BAG, TWICE: the lock's veil bag (modules/lockscreen/lock/VeilBag.js, run in node) and themectl's wallpaper bag (its Python
port: bag_draw / bag_parse in tools/theme/themectl) give the same picks and the same states for the same random numbers.

    python3 tools/dev/themectl_bag_parity.py              last line THEMECTL_BAG RESULT PASS|FAIL
    ARM=<name> python3 tools/dev/themectl_bag_parity.py   one fault in a COPY of one side; must FAIL on its needle
    ARM=all python3 tools/dev/themectl_bag_parity.py      every arm; THEMECTL_BAG ARMS PASS only when each failed where it must

  B1  the case table (tools/dev/themectl_bag_cases.json): every case's draw (or parse) gives the table's answer, in JS and in Python
  B2  a seeded sweep: 400 runs of 1-60 draws over lists that grow, shrink and change, the same rnd handed to both: the same pick and state at
      every step (and junk in a list -- repeats, empty and non-string names -- read the same way)
  B3  the guarantees themselves on the Python side: a round shows each picture once; no picture twice in a row; any 2N-1 draws in a row show
      all N; a picture put into the list mid-round shows within that round
Arms:  pyseam       the Python port lets a new round start with the last picture     -> B1, B2, B3
       pyreconcile  the Python port adds a new picture at the END of what is to come  -> B1, B2
       jsdrop       VeilBag.js keeps a picture taken out of the list in the round      -> B1, B2
"""
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
sys.dont_write_bytecode = True
import importlib.machinery
import importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
NAME = "THEMECTL_BAG"
ARM = os.environ.get("ARM", "")
SCRATCH = os.environ.get("SCRATCH") or tempfile.gettempdir()
ARMS = {
    "pyseam": ("py", "    _bag_not_first(bag, last, rnd)\n    return bag\n", "    return bag\n", ["B1", "B2", "B3"]),
    "pyreconcile": ("py", "            remaining.insert(_bag_int(rnd, len(remaining) + 1), n)\n", "            remaining.append(n)\n", ["B1", "B2"]),
    "jsdrop": ("js", "    var round = _uniq(s.round).filter(function (n) { return want.indexOf(n) >= 0; });\n", "    var round = _uniq(s.round).concat(want.filter(function (n) { return _uniq(s.round).indexOf(n) < 0; }));\n", ["B1", "B2"]),
}

# node: VeilBag.js as the lock loads it, its `.pragma library` line taken off; reads [{op, ...}] on stdin, answers one result per item
NODE = r"""
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8").replace(/^\.pragma library\s*$/m, "");
const VB = new Function(src + "\nreturn { empty: empty, parse: parse, draw: draw, serialize: serialize };")();
const items = JSON.parse(fs.readFileSync(0, "utf8"));
const out = items.map(function (it) {
    if (it.op === "parse")
        return VB.parse(it.text);
    let i = 0;
    const rnd = function () { if (i >= it.rnd.length) throw new Error("rnd ran out"); return it.rnd[i++]; };
    const r = VB.draw(it.state, it.names, rnd);
    return { name: r.name, state: r.state, used: i };
});
process.stdout.write(JSON.stringify(out));
"""

# node again, for the sweep: per plan, a chain of draws from an empty bag, each state handed to the next draw
CHAIN = r"""
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8").replace(/^\.pragma library\s*$/m, "");
const VB = new Function(src + "\nreturn { parse: parse, draw: draw };")();
const plans = JSON.parse(fs.readFileSync(0, "utf8"));
process.stdout.write(JSON.stringify(plans.map(function (plan) {
    let st = VB.parse("");
    return plan.map(function (p) { let i = 0; const r = VB.draw(st, p[0], function () { return p[1][i++]; }); st = r.state; return r; });
})));
"""

failures = []


def check(cid, ok, detail=""):
    if not ok:
        failures.append(cid)
    print("%-4s %s%s" % ("ok" if ok else "FAIL", cid, ("  -- " + str(detail)[:400]) if (detail and not ok) else ""))
    return ok


def load_themectl(path):
    loader = importlib.machinery.SourceFileLoader("themectl_bag_under_test", path)
    spec = importlib.util.spec_from_loader("themectl_bag_under_test", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def py_run(mod, items):
    out = []
    for it in items:
        if it["op"] == "parse":
            out.append(mod.bag_parse(it["text"]))
            continue
        seq = list(it["rnd"])
        used = [0]

        def rnd():
            if used[0] >= len(seq):
                raise RuntimeError("rnd ran out")
            used[0] += 1
            return seq[used[0] - 1]
        name, state = mod.bag_draw(it["state"], it["names"], rnd)
        out.append({"name": name, "state": state, "used": used[0]})
    return out


def js_run(js, items, work):
    drv = os.path.join(work, "drive.js")
    with open(drv, "w") as f:
        f.write(NODE)
    r = subprocess.run(["node", drv, js], input=json.dumps(items), capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise RuntimeError("node: %s" % r.stderr.strip()[-400:])
    return json.loads(r.stdout)


def main():
    if ARM == "all":
        bad = 0
        for a in ARMS:
            env = dict(os.environ, ARM=a)
            r = subprocess.run([sys.executable, os.path.abspath(__file__)], env=env, capture_output=True, text=True, timeout=600)
            last = (r.stdout.strip().splitlines() or [""])[-1]
            red = sorted(set(re.findall(r"^FAIL (B\d)", r.stdout, re.M)))
            want = ARMS[a][3]
            if last == "%s RESULT FAIL (ARM=%s)" % (NAME, a) and set(want) <= set(red):
                print("  ARM %s: FAIL, as it must -- red: %s" % (a, " ".join(red)))
            else:
                print("  ARM %s: NOT PROVEN -- '%s', must be red: %s, red: %s" % (a, last, " ".join(want), " ".join(red)))
                bad = 1
        print("%s ARMS %s" % (NAME, "PASS (every arm failed where it must)" if not bad else "FAIL"))
        return bad
    if ARM and ARM not in ARMS:
        print("unknown ARM=%s (have: %s)" % (ARM, ", ".join(ARMS)))
        print("%s RESULT FAIL" % NAME)
        return 2
    if shutil.which("node") is None:
        print("%s RESULT FAIL (no node on the PATH)" % NAME)
        return 1
    work = tempfile.mkdtemp(prefix="themectl_bag.", dir=SCRATCH)
    try:
        py_path, js_path = REPO + "/tools/theme/themectl", REPO + "/modules/lockscreen/lock/VeilBag.js"
        if ARM:
            side, old, new, _ = ARMS[ARM]
            src = py_path if side == "py" else js_path
            text = open(src, encoding="utf-8").read()
            if text.count(old) != 1:
                print("%s ARM %s: the anchor is gone (%d matches in %s)" % (NAME, ARM, text.count(old), src))
                print("%s RESULT FAIL (ARM=%s)" % (NAME, ARM))
                return 1
            dst = os.path.join(work, os.path.basename(src))
            with open(dst, "w", encoding="utf-8") as f:
                f.write(text.replace(old, new))
            if side == "py":
                py_path = dst
            else:
                js_path = dst
        mod = load_themectl(py_path)

        # B1 the table
        table = json.load(open(HERE + "/themectl_bag_cases.json", encoding="utf-8"))["cases"]
        items = [dict(c["in"]) for c in table]
        got_js, got_py = js_run(js_path, items, work), py_run(mod, items)
        bad = [(c["id"], c["want"], j, p) for c, j, p in zip(table, got_js, got_py) if not (j == c["want"] and p == c["want"])]
        check("B1 the case table (%d cases) gives the same answers in JS and in Python" % len(table), not bad, bad[:2])

        # B2 the sweep: lists that change under a bag in use, junk in a list, the same rnd both ways (each side runs its own chain)
        rng = random.Random(20261108)
        pool = ["/w/%s.png" % c for c in "abcdefghij"]
        plans = []
        for _ in range(400):
            cur, plan = rng.sample(pool, rng.randint(1, 6)), []
            for _ in range(rng.randint(1, 60)):
                if rng.random() < 0.15:                      # the list changes under the bag
                    cur = rng.sample(pool, rng.randint(0, 6))
                listed = list(cur)
                if rng.random() < 0.05:                      # junk both readers must drop the same way
                    listed += ["", listed[0] if listed else "", 7, None]
                plan.append([listed, [rng.random() for _ in range(16)]])
            plans.append(plan)
        drv = os.path.join(work, "chain.js")
        with open(drv, "w") as f:
            f.write(CHAIN)
        r = subprocess.run(["node", drv, js_path], input=json.dumps(plans), capture_output=True, text=True, timeout=300)
        js_out = json.loads(r.stdout) if r.returncode == 0 else None
        mism, steps = [], 0
        for run, plan in enumerate(plans):
            st = mod.bag_empty()
            for k, (listed, rnd) in enumerate(plan):
                it = iter(rnd)
                name, st = mod.bag_draw(st, listed, lambda: next(it))
                steps += 1
                if js_out is None or {"name": name, "state": st} != js_out[run][k]:
                    mism.append((run, k, listed, {"name": name, "state": st}, js_out[run][k] if js_out else r.stderr[-200:]))
                    break
        check("B2 a seeded sweep (%d runs, %d draws): the same pick and state at every step" % (len(plans), steps), not mism, mism[:1])

        # B3 the guarantees, on the Python side
        problems = []
        rng = random.Random(7)
        for n in range(1, 8):
            names = ["/p/%d.png" % i for i in range(n)]
            st, seq = mod.bag_empty(), []
            for _ in range(n * 12):
                name, st = mod.bag_draw(st, names, rng.random)
                seq.append(name)
            rounds = [seq[i:i + n] for i in range(0, len(seq), n)]
            if any(sorted(r) != sorted(names) for r in rounds):
                problems.append(("a round is not every picture once", n, rounds[:3]))
            if n > 1 and any(a == b for a, b in zip(seq, seq[1:])):
                problems.append(("a picture twice in a row", n, seq[:3 * n]))
            w = max(1, 2 * n - 1)
            if any(set(seq[i:i + w]) != set(names) for i in range(len(seq) - w + 1)):
                problems.append(("2N-1 draws miss a picture", n))
        st = mod.bag_empty()
        names = ["/p/a.png", "/p/b.png", "/p/c.png", "/p/d.png"]
        name, st = mod.bag_draw(st, names, rng.random)
        late = "/p/new.png"
        seen = []
        for _ in range(len(st["remaining"]) + 1):
            name, st = mod.bag_draw(st, names + [late], rng.random)
            seen.append(name)
        if late not in seen:
            problems.append(("a picture put in mid-round waits for the next round", seen))
        check("B3 a round shows each once, no repeat, every 2N-1 draws cover all N, a new picture joins the round", not problems, problems[:2])
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("%s RESULT %s%s" % (NAME, "PASS" if not failures else "FAIL", " (ARM=%s)" % ARM if ARM else ""))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
