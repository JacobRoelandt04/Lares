#!/usr/bin/env python3
"""Cases for tools/dev/mockup_promote.py -- the settings pipeline's writer -- over a fixture tree.

    python3 tools/dev/mockup_promote_cases.py              ends in  MOCKUP_PROMOTE_CASES RESULT PASS|FAIL
    ARM=<name> python3 tools/dev/mockup_promote_cases.py   a fault put into a COPY of the pipeline: must FAIL
    ARM=all    python3 tools/dev/mockup_promote_cases.py   every arm; ends in MOCKUP_PROMOTE_CASES ARMS PASS

The tree is tools/dev/fixtures/mockup_promote/tree: a miniature repo (modules/ with a content root AlphaPopup,
components two modules share, one only alpha uses, a base type, a singleton, a protected module, a mock
service) and test_alpha.qml, whose lists exercise every road a row can take. Every case runs on a COPY of it
in a scratch directory; nothing under tools/dev/fixtures is ever written.

The arms break the PIPELINE, not the fixtures (a source patch of tools/dev/mockup_promote.py / mockup_model.py,
applied to copies in a scratch directory and imported instead), so a case that cannot fail shows it:

  bindingwrite   a binding default may be overwritten            C17
  sharedleak     no file is shared: a per-module save writes the   C02 C08 C10
                 shared component's own declaration
  sentinel       a -1 default may be pinned                        C18
  hexoverwrite   a hex may replace a token-bound colour            C21b
  nonatomic      a failed write leaves the files it did write      C26
  noprotect      the protected module is written                   C15
"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ARM = os.environ.get("ARM", "")
FIX = os.path.join(HERE, "fixtures", "mockup_promote", "tree")
SCRATCH_ROOT = os.environ.get("SCRATCH") or tempfile.gettempdir()

ARMS = {
    "bindingwrite": [("mockup_promote.py", '        raise Refuse("binding default `%s`" % short(eff.text))', '        return')],
    "sharedleak": [("mockup_model.py", "    def shared(self, rel):\n        h = self.hints", "    def shared(self, rel):\n        return False\n        h = self.hints")],
    "sentinel": [("mockup_promote.py", '    if lit_kind == "num" and float(eff.value) == -1.0 and float(canon) != -1.0 and not hint.get("allowSentinel"):', "    if False:")],
    "hexoverwrite": [("mockup_promote.py", '        if k == "token":\n            raise Refuse("the default follows the theme', '        if False:\n            raise Refuse("the default follows the theme')],
    "nonatomic": [("mockup_promote.py", "        except Exception:\n            for rel in done:\n                with open(self.repo.abspath(rel), \"w\", encoding=\"utf-8\", newline=\"\") as f:\n                    f.write(old[rel])\n            raise", "        except Exception:\n            raise")],
    "noprotect": [("mockup_model.py", "    def protected(self, rel):\n        return any(", "    def protected(self, rel):\n        return False and any(")],
}
MUST = {"bindingwrite": "C17", "sharedleak": "C02 C08 C10", "sentinel": "C18", "hexoverwrite": "C21b", "nonatomic": "C26", "noprotect": "C15"}

LIB = HERE
if ARM and ARM != "all":
    if ARM not in ARMS:
        raise SystemExit("unknown ARM=%s (%s)" % (ARM, ", ".join(sorted(ARMS))))
    LIB = tempfile.mkdtemp(prefix="promote-arm-lib-", dir=SCRATCH_ROOT)
    for f in ("mockup_qmlscan.py", "mockup_model.py", "mockup_promote.py", "mockup_save_defaults.py"):
        shutil.copy(os.path.join(HERE, f), os.path.join(LIB, f))
    for fname, a, b in ARMS[ARM]:
        path = os.path.join(LIB, fname)
        src = open(path, encoding="utf-8").read()
        if src.count(a) != 1:
            raise SystemExit("ARM=%s: its anchor is not in %s exactly once -- the arm is stale" % (ARM, fname))
        open(path, "w", encoding="utf-8").write(src.replace(a, b))
sys.path.insert(0, LIB)
import mockup_model as mm                      # noqa: E402
import mockup_promote as mp                    # noqa: E402

results = []


def case(cid, what, ok, detail=""):
    results.append((cid, what, bool(ok), detail))
    print("CASE %s %s %s%s" % ("PASS" if ok else "FAIL", cid, what, (" -- " + str(detail)) if (detail and not ok) else ""))


class Tree:
    """A scratch copy of the fixture tree."""

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="promote-cases-", dir=SCRATCH_ROOT)
        self.root = os.path.join(self.dir, "tree")
        shutil.copytree(FIX, self.root)

    def path(self, rel):
        return os.path.join(self.root, rel)

    def read(self, rel):
        with open(self.path(rel), encoding="utf-8") as f:
            return f.read()

    def sub(self, rel, a, b):
        s = self.read(rel)
        assert s.count(a) == 1, (rel, a)
        with open(self.path(rel), "w", encoding="utf-8") as f:
            f.write(s.replace(a, b))

    def repo(self):
        return mm.Repo(self.root)

    def clean(self):
        shutil.rmtree(self.dir, ignore_errors=True)


def plans_of(tree, mockup="test_alpha.qml", shared=(), phase="rows", changes=None):
    repo = tree.repo()
    m = mm.Mockup(repo, mockup)
    pl = mp.Planner(repo, m, shared=shared, phase=phase)
    return repo, m, pl, pl.plan_all(changes)


def by_key(plans):
    return {rp.row.key: rp for rp in plans}


def only_part(rp):
    return rp.parts[0] if rp.parts else None


def files_of(repo, plans):
    es = mp.build_edits(repo, plans)
    return es, sorted({e.rel for e in es.edits()}), es.files()


def run_cli(args, env=None, cwd=None):
    e = dict(os.environ)
    e.update(env or {})
    p = subprocess.run([sys.executable, os.path.join(LIB, "mockup_promote.py")] + args, capture_output=True, text=True, env=e, cwd=cwd)
    return p.returncode, p.stdout, p.stderr


def main():
    if ARM == "all":
        return run_arms()
    tree = Tree()
    try:
        run_cases(tree)
    finally:
        tree.clean()
        if LIB != HERE:
            shutil.rmtree(LIB, ignore_errors=True)
    bad = [r for r in results if not r[2]]
    print("MOCKUP_PROMOTE_CASES %d cases, %d failed" % (len(results), len(bad)))
    print("MOCKUP_PROMOTE_CASES RESULT %s%s" % ("FAIL" if bad else "PASS", " (ARM=%s)" % ARM if ARM else ""))
    return 1 if bad else 0


def run_arms():
    bad = 0
    for name in ARMS:
        e = dict(os.environ)
        e["ARM"] = name
        p = subprocess.run([sys.executable, os.path.abspath(__file__)], capture_output=True, text=True, env=e)
        failed = [l.split()[2] for l in p.stdout.splitlines() if l.startswith("CASE FAIL")]
        missing = [c for c in MUST[name].split() if c not in failed]
        last = p.stdout.strip().splitlines()[-1] if p.stdout.strip() else p.stderr.strip()[-200:]
        if last == "MOCKUP_PROMOTE_CASES RESULT FAIL (ARM=%s)" % name and not missing:
            print("  ARM %s: FAIL, as it must -- red: %s" % (name, " ".join(failed)))
        else:
            print("  ARM %s: NOT PROVEN -- '%s', must be red: %s, red: %s, missing: %s" % (name, last, MUST[name], " ".join(failed), " ".join(missing)))
            bad = 1
    print("MOCKUP_PROMOTE_CASES ARMS %s" % ("FAIL" if bad else "PASS"))
    return bad


def run_cases(tree):
    repo, m, pl, plans = plans_of(tree)
    k = by_key(plans)
    es, files, new = files_of(repo, plans)
    alpha = new.get("modules/alpha/AlphaPopup.qml", "")

    # ---- where a row lands -------------------------------------------------------------------------------------
    p = only_part(k["popupParams.width0"])
    case("C01", "a property the module declares: its default is rewritten in place (100 -> 120)",
         p.status == "write" and p.mode == "declaration" and "property real width0: 120" in alpha and "SharedBox.qml" not in " ".join(files[:0]))
    p = only_part(k["boxAParams.gap"])
    case("C02", "a SHARED component's row lands at the module's use of it, and the shared file is not touched",
         p.status == "write" and p.mode == "use-site" and "modules/common/components/SharedBox.qml" not in files
         and "gap: 9" in alpha, (p.mode, files))
    repo2, m2, pl2, plans2 = plans_of(tree, shared={"boxAParams.gap"})
    p2 = only_part(by_key(plans2)["boxAParams.gap"])
    es2, files2, new2 = files_of(repo2, plans2)
    case("C03", "the per-row 'shared default' switch writes the shared declaration instead (and not the use site)",
         p2.status == "write" and p2.mode == "shared-declaration" and "property real gap: 9" in new2.get("modules/common/components/SharedBox.qml", "")
         and "gap: 9" not in new2.get("modules/alpha/AlphaPopup.qml", ""), (p2.mode, files2))
    p = only_part(k["boxBParams.gap"])
    case("C04", "a literal already sitting at the module's use site IS the default: it is rewritten there (7 -> 8)",
         p.status == "write" and p.mode == "use-site" and "        gap: 8\n" in alpha and "gap: 7" not in alpha, p.mode)
    case("C05", "a value the module already ships is 'same' (label, radius), and writes nothing",
         only_part(k["boxBParams.label"]).status == "same" and only_part(k["boxAParams.radiusPx"]).status == "same")
    p = only_part(k["partParams.size"])
    part_src = new.get("modules/common/components/OwnedPart.qml", "")
    case("C06", "a component only this module uses (through it) is its own: the declaration is rewritten",
         p.status == "write" and p.mode == "declaration" and "property real size: 12" in part_src, p.mode)
    p = only_part(k["partParams.thickness"])
    case("C07", "a property inherited from a SHARED base becomes a root line of the module's own type; the base stays",
         p.status == "write" and p.mode == "override" and "    thickness: 44\n" in part_src
         and "modules/common/components/BaseShape.qml" not in files, (p.mode, files))
    p = only_part(k["holderParams.gap"])
    case("C08", "a shared component behind another shared one: a dotted alias line at the module's object (`inner.gap`)",
         p.status == "write" and p.mode == "use-site" and "        inner.gap: 11\n" in alpha, (p.mode, p.reason))
    p = only_part(k["fieldParams.size"])
    p_t = only_part(k["fieldParams.thickness"])
    case("C09", "an inline component's body is the type's default: rewritten (size 4 -> 6) and extended (thickness)",
         p.status == "write" and "        size: 6\n" in alpha and "        thickness: 33\n" in alpha and p_t.mode == "override", (p.mode, p_t.mode))
    p = only_part(k["styleParams.tick"])
    case("C10", "an object the mockup made and handed over lands where the module CREATES it (the typed property's default object)",
         p.status == "write" and "property SharedStyle style: SharedStyle {\n        tick: 8\n    }" in alpha
         and "modules/common/components/SharedStyle.qml" not in files, (p.mode, p.where))
    gamma = new.get("modules/gamma/GammaPopup.qml", "")
    p = only_part(k["knobs.padding"])
    case("C11", "a mockup-local knob follows the binding that feeds the module (pad: tun.padding)",
         p.status == "write" and "property real pad: 20" in gamma, (p.status, p.reason))
    p = only_part(k["knobs.dress"])
    case("C12", "a toggle behind `tun.dress ? \"Audiowide\" : \"Inter\"` writes the face of its state",
         p.status == "write" and 'property string fontFamily: "Audiowide"' in gamma, (p.status, p.reason))
    rp_off = pl.plan_row(m.row("knobs.dress"), False)
    case("C12b", "... and its OFF state is the module's own face: 'same'", only_part(rp_off).status == "same", only_part(rp_off).status)
    case("C13", "a hint can skip a row (with its reason) or map it onto a named property",
         k["knobs.skipMe"].status == "skip" and "stage placement" in k["knobs.skipMe"].reason
         and only_part(k["knobs.sideIndex"]).status == "write" and only_part(k["knobs.sideIndex"]).label == "AlphaPopup.fontFamily")
    case("C14", "a mock service's scenario knobs are no shipped setting", k["mockParams.machinePct"].status == "skip" and "mock data" in k["mockParams.machinePct"].reason)
    case("C15", "a protected module (the hints) is refused with the reason",
         k["batParams.iconSize"].status == "refuse" and "protected" in k["batParams.iconSize"].reason)
    p = only_part(k["feelParams.speed"])
    case("C16", "a singleton (the shell-wide feel) is written at its declaration; a value it already has is 'same'",
         p.status == "write" and p.mode == "singleton" and "property real speed: 1.5" in new.get("modules/common/components/FeelSingleton.qml", "")
         and only_part(k["feelParams.notchMs"]).status == "same")

    # ---- what it refuses ------------------------------------------------------------------------------------------
    r = k["boxAParams.ratio"]
    case("C17", "a BINDING default is never overwritten (neither at a declaration nor as a use-site line)",
         r.status == "refuse" and "binding default" in r.reason and "ratio" not in alpha, (r.status, r.reason))
    r = k["boxAParams.auto"]
    case("C18", "a sentinel (-1: the config decides) is not pinned; -1 itself is 'same'",
         r.status == "refuse" and "sentinel" in r.reason and only_part(pl.plan_row(m.row("boxAParams.auto"), -1)).status == "same", (r.status, r.reason))
    r1 = k["boxAParams.tintCount"]
    r2 = pl.plan_row(m.row("boxAParams.radiusPx"), True)
    r3 = pl.plan_row(m.row("boxAParams.radiusPx"), "wide")
    case("C19", "a value of the wrong type is refused: 2.5 onto an int, a switch onto a real, text onto a real",
         r1.status == "refuse" and "int" in r1.reason and r2.status == "refuse" and r3.status == "refuse", (r1.reason, r2.reason, r3.reason))
    case("C20", "a readonly property is refused", k["boxAParams.fixed"].status == "refuse" and "readonly" in k["boxAParams.fixed"].reason)

    # ---- colours -------------------------------------------------------------------------------------------------------------
    acc = k["boxAColors.accent"]
    case("C21a", "a colour row '@error' over a token-bound default writes the BINDING `Theme.error`",
         only_part(acc).status == "write" and "        accent: Theme.error\n" in alpha, (acc.status, acc.reason))
    hx = k["boxAHex.accent"]
    case("C21b", "a hex over a token-bound default is refused (it would pin one theme's colour into dark mode)",
         hx.status == "refuse" and "dark mode" in hx.reason, (hx.status, hx.reason))
    case("C21c", "a hex over a hex literal is rewritten", only_part(k["boxAColors.fill"]).status == "write" and '        fill: "#112233"\n' in alpha)
    row = m.row("boxAColors.accent")
    same = pl.plan_row(row, "@accent")
    alias = pl.plan_row(row, "@warnStrong")
    unknown = pl.plan_row(row, "@nonesuch")
    case("C21d", "'@accent' over Theme.accent is 'same'; an alias token resolves to its property; an unknown token is refused",
         only_part(same).status == "same" and only_part(alias).literal == "Theme.error" and unknown.status == "refuse",
         (only_part(same).status, only_part(alias).literal, unknown.status))
    t_nt = Tree()
    try:
        t_nt.sub("modules/alpha/AlphaPopup.qml", 'import "../common/theme"\n', "")
        _, _, _, plans_nt = plans_of(t_nt)
        nt = by_key(plans_nt)["boxAColors.accent"]
        case("C21e", "a token is not written into a file that does not import Theme (it would be an unresolved name)",
             nt.status == "refuse" and "does not import Theme" in nt.reason, (nt.status, nt.reason))
    finally:
        t_nt.clean()
    case("C22", "themed and file-backed lists are not Save's",
         k["themedColors.accent"].status == "skip" and "themed" in k["themedColors.accent"].reason
         and k["fileParams.width0"].status == "skip" and "alpha.json" in k["fileParams.width0"].reason)

    # ---- JSON rows and choice rows -------------------------------------------------------------------------------------------------
    jr = only_part(k["jsonParams.rules"])
    jt = only_part(k["jsonParams.rulesText"])
    case("C22b", "a JSON row onto a `var` writes the object itself as a multi-line literal; onto a string it writes the text",
         jr.status == "write" and '    property var rules: ({\n        "a": 2,\n        "b": [\n            1,\n            2\n        ]\n    })' in alpha
         and jt.status == "write" and 'property string rulesText: "{\\"x\\":1}"' in alpha, (jr.status, jr.reason, jt.status, jt.reason))
    case("C22c", "a choice row (an index) writes the property's real type: the NAME onto a string whose default is one of the names, the number onto an int",
         'property string side: "end"' in alpha and "property int mode: 1" in alpha, k["jsonParams.side"].reason)
    case("C22d", "... and is refused onto a string whose default is not one of the names", k["jsonParams.weird"].status == "refuse" and "promote" in k["jsonParams.weird"].reason)

    # ---- the whole run -----------------------------------------------------------------------------------------------------------
    case("C23", "two rows that write one place differently collide: the later is refused, nothing is written twice",
         collision_case(tree))
    case("C24", "applied twice, nothing more changes; a re-plan finds every written row 'same'", idempotence_case(tree))
    case("C25", "the files it writes still scan, and the effective default of every written row is the row's value", effective_case(tree))
    case("C26", "all the files or none: a failure while writing puts the first file back", atomic_case(tree))
    case("C26b", "a bug in planning one row refuses THAT row (reported), the others are planned as ever", internal_error_case(tree))
    insert_cases(tree)
    cli_cases(tree)


def collision_case(tree):
    repo, m, pl, plans = plans_of(tree)
    row_a = m.row("popupParams.fontFamily")
    pa = pl.plan_row(row_a, "Audiowide")
    pb = pl.plan_row(m.row("knobs.sideIndex"), 2)      # maps to "Exo 2" onto the same property
    es = mp.EditSet(repo)
    okA = es.add(only_part(pa), "popupParams.fontFamily")
    okB = es.add(only_part(pb), "knobs.sideIndex")
    return okA and not okB and only_part(pb).status == "refuse" and "collides" in only_part(pb).reason


def idempotence_case(tree):
    t = Tree()
    try:
        repo, m, pl, plans = plans_of(t)
        es = mp.build_edits(repo, plans)
        written = es.write()
        before = {r: t.read(r) for r in written}
        repo, m, pl, plans = plans_of(t)
        left = [rp.row.key for rp in plans if rp.status == "write"]
        es = mp.build_edits(repo, plans)
        again = es.write() if es.edits() else []
        after = {r: t.read(r) for r in written}
        return bool(written) and not left and not again and before == after
    finally:
        t.clean()


def effective_case(tree):
    t = Tree()
    try:
        repo, m, pl, plans = plans_of(t)
        wrote = [(rp.row, only_part(rp)) for rp in plans if rp.status == "write" and rp.row.list_id != "(dressing)"]
        mp.build_edits(repo, plans).write()
        repo, m, pl, plans = plans_of(t)
        again = by_key(plans)
        bad = [row.key for row, _ in wrote if only_part(again[row.key]).status != "same"]
        # every written file still has a root and every id resolves
        for rel in ("modules/alpha/AlphaPopup.qml", "modules/common/components/OwnedPart.qml", "modules/gamma/GammaPopup.qml"):
            if repo.qml(rel).root() is None:
                bad.append(rel)
        if repo.qml("modules/alpha/AlphaPopup.qml").by_id("firstBox") is None:
            bad.append("firstBox")
        return not bad and len(wrote) > 15
    finally:
        t.clean()


def atomic_case(tree):
    t = Tree()
    try:
        repo, m, pl, plans = plans_of(t)
        es = mp.build_edits(repo, plans)
        files = sorted(es.files())
        before = {r: t.read(r) for r in files}
        real = os.replace
        calls = {"n": 0}

        def boom(a, b):
            calls["n"] += 1
            if calls["n"] == 2:
                raise OSError("disk says no")
            return real(a, b)
        os.replace = boom
        try:
            try:
                es.write()
                return False
            except OSError:
                pass
        finally:
            os.replace = real
        return all(t.read(r) == before[r] for r in files) and not any(os.path.exists(t.path(r) + ".promote.tmp") for r in files)
    finally:
        t.clean()


def internal_error_case(tree):
    import contextlib
    import io
    repo, m, pl, plans = plans_of(tree)
    orig = pl._plan_row

    def boom(row, value=mp.UNSET):
        if row.key == "popupParams.width0":
            raise KeyError("planted")
        return orig(row, value)
    pl._plan_row = boom
    with contextlib.redirect_stderr(io.StringIO()):
        bad = pl.plan_row(m.row("popupParams.width0"))
        fine = pl.plan_row(m.row("popupParams.fontFamily"))
    return bad.status == "refuse" and "internal error" in bad.reason and fine.status == "write"


def insert_cases(tree):
    repo = tree.repo()
    q = repo.qml("modules/gamma/GammaPopup.qml")
    tight = q.by_id("tight")
    empties = [o for o in q.objects_of_type("SharedBox") if o.id is None][0]
    ins = lambda ob, *names: mp.render_insert([mp.Insert("modules/gamma/GammaPopup.qml", q, ob, n, "1") for n in names])

    def applied(ob, *names):
        e = ins(ob, *names)
        return q.text[:e.start] + e.text + q.text[e.end:]
    t1 = applied(tight, "gap")
    t2 = applied(empties, "gap", "bevel")
    case("C27a", "a one-line object `SharedBox { id: tight }` is written out over lines, its id kept",
         "    SharedBox {\n        id: tight\n        gap: 1\n    }\n" in t1, t1.split("SharedBox")[1:2])
    case("C27b", "an empty object `SharedBox {}` is written out over lines, the new lines sorted",
         "    SharedBox {\n        bevel: 1\n        gap: 1\n    }\n" in t2)
    q2 = repo.qml("modules/alpha/AlphaPopup.qml")
    sec = q2.by_id("secondBox")
    e = mp.render_insert([mp.Insert("modules/alpha/AlphaPopup.qml", q2, sec, "radiusPx", "3")])
    out = q2.text[:e.start] + e.text + q2.text[e.end:]
    case("C27c", "in a body with properties the new line follows the last property, at their indent",
         '        gap: 7\n        label: "second"\n        radiusPx: 3\n' in out, out[out.find("id: secondBox") - 10:out.find("id: secondBox") + 120])


def cli_cases(tree):
    t = Tree()
    stub = os.path.join(t.root, "tools", "shell")
    os.makedirs(stub)
    log = os.path.join(t.dir, "lares.log")
    with open(os.path.join(stub, "lares"), "w") as f:
        f.write('#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s"\necho "apply: stub says ${STUB_SAYS:-done}"\nexit ${STUB_STATUS:-0}\n' % log)
    os.chmod(os.path.join(stub, "lares"), os.stat(os.path.join(stub, "lares")).st_mode | stat.S_IXUSR)
    subprocess.run(["git", "init", "-q", t.root], check=True)
    subprocess.run(["git", "-C", t.root, "add", "-A"], check=True)
    subprocess.run(["git", "-C", t.root, "-c", "user.email=a@b", "-c", "user.name=t", "commit", "-qm", "base"], check=True)
    try:
        changes = json.dumps({"popupParams": {"width0": 130, "titleSize": 18}, "boxAParams": {"gap": 10, "ratio": 99}})
        # the dry run writes nothing
        rc, out, err = run_cli(["save", "test_alpha.qml", changes, "--root", t.root, "--dry-run"])
        case("C28a", "save --dry-run plans the module and the mockup's val: and writes neither",
             "AlphaPopup.qml" in out and "(dry run)" in out and "width0: 100" in t.read("modules/alpha/AlphaPopup.qml")
             and "val: 120" in t.read("test_alpha.qml"), out[-300:])
        # --no-module: only the mockup's own val:, with the reason
        rc, out, err = run_cli(["save", "test_alpha.qml", json.dumps({"popupParams": {"width0": 130}}), "--root", t.root, "--no-module", "runs from a copy"])
        case("C28b", "--no-module writes only the mockup's val: lines (the report keeps today's shape) and says why",
             "module not written: runs from a copy" in out and "set  popupParams.width0: val: 120 -> 130" in out and "1 changed, 0 skipped" in out
             and "width0: 100" in t.read("modules/alpha/AlphaPopup.qml") and not os.path.exists(log), out)
        # the real thing: module + val: + the commit through the (stub) lares
        rc, out, err = run_cli(["save", "test_alpha.qml", changes, "--root", t.root, "--lares", os.path.join(stub, "lares")])
        args = open(log).read().split() if os.path.exists(log) else []
        src = t.read("modules/alpha/AlphaPopup.qml")
        case("C28c", "save writes the module and the mockup, then runs `lares apply --commit <module> <files>` on exactly those files",
             rc == 0 and "property real width0: 130" in src and "property real titleSize: 18" in src and "gap: 10" in src
             and args[:3] == ["apply", "--commit", "alpha"] and set(os.path.relpath(a, t.root) for a in args[3:]) == {"modules/alpha/AlphaPopup.qml", "test_alpha.qml"},
             (rc, args, out[-400:], err[-300:]))
        case("C28d", "the binding row was refused in the same save; the host's override and the stale comment are told",
             "binding default" in out and "sets `titleSize: 14` itself" in out and "quotes the old value 16" in out, out)
        case("C28e", "the mockup's own val: took every saved value, the refused one included (the * clears)",
             "val: 130" in t.read("test_alpha.qml") and "val: 18" in t.read("test_alpha.qml"))
        # lares's four statuses (3, "redeploy not built", went with the turnover's deploy: 4 is the restart refused by the package guard)
        meanings = {}
        for status in (0, 1, 2, 4):
            tt = Tree()
            try:
                os.makedirs(os.path.join(tt.root, "tools", "shell"))
                sp = os.path.join(tt.root, "tools", "shell", "lares")
                with open(sp, "w") as f:
                    f.write('#!/usr/bin/env bash\necho "apply: stub"\nexit %d\n' % status)
                os.chmod(sp, 0o755)
                subprocess.run(["git", "init", "-q", tt.root], check=True)
                rc, out, err = run_cli(["save", "test_alpha.qml", json.dumps({"popupParams": {"width0": 140}}), "--root", tt.root, "--lares", sp])
                meanings[status] = (rc, out, err)
            finally:
                tt.clean()
        ok = (meanings[0][0] == 0 and "done" in meanings[0][1]
              and meanings[1][0] == 1 and "FAILED" in meanings[1][1] and "commit failed" in meanings[1][2]
              and meanings[2][0] == 1 and "usage" in meanings[2][1]
              and meanings[4][0] == 0 and "NOT restarted" in meanings[4][1])
        case("C29", "lares's statuses are told: 0 done, 1 failed, 2 usage (both exit 1), 4 committed but not restarted (exit 0)", ok, {k: v[:2] for k, v in meanings.items()})
        # a missing lares is told, not an error
        tt = Tree()
        try:
            subprocess.run(["git", "init", "-q", tt.root], check=True)
            rc, out, err = run_cli(["save", "test_alpha.qml", json.dumps({"popupParams": {"width0": 140}}), "--root", tt.root])
            case("C30", "without tools/shell/lares the files are written and the panel is told nothing is committed",
                 rc == 0 and "nothing is committed" in out, out[-200:])
        finally:
            tt.clean()
        tn = Tree()                       # not a git work tree at all: nothing could be committed or undone
        try:
            rc, out, err = run_cli(["save", "test_alpha.qml", json.dumps({"popupParams": {"width0": 141}}), "--root", tn.root])
            case("C30b", "outside a git work tree the module is not written (reason told), the mockup's val: still is",
                 "module not written" in out and "not the top of a git work tree" in out and "width0: 100" in tn.read("modules/alpha/AlphaPopup.qml")
                 and "val: 141" in tn.read("test_alpha.qml"), out[-300:])
        finally:
            tn.clean()
        # the panel's per-row view
        rc, out, err = run_cli(["plan", "test_alpha.qml", "--root", t.root])
        pj = json.loads(out)
        r = pj["rows"]
        case("C31", "plan: per row the status, the file it would write, whether a shared declaration is the alternative",
             pj["moduleId"] == "alpha" and r["boxAParams.gap"]["shared"] is True and r["boxAParams.gap"]["mode"] in ("use-site", "same")
             and r["partParams.size"]["shared"] is False and r["boxAParams.ratio"]["status"] == "refuse"
             and r["themedColors.accent"]["status"] == "skip", {k: r[k] for k in ("boxAParams.gap", "partParams.size")})
        # the set command
        rc, out, err = run_cli(["set", "AlphaPopup.fontFamily=Exo 2", "AlphaPopup.nonesuch=1", "NoType.x=1", "--root", t.root, "--apply"])
        case("C32", "set Type.prop=value writes by name; a typo and an unknown type are refused (exit 1)",
             rc == 1 and 'property string fontFamily: "Exo 2"' in t.read("modules/alpha/AlphaPopup.qml") and "no property `nonesuch`" in out and "no type `NoType`" in out, out[-400:])
        # the fonts phase
        rc, out, err = run_cli(["dry", "test_alpha.qml", "--root", t.root, "--phase", "fonts"])
        case("C33", "the fonts phase forces the dressed branch of a ternary (the shell's face) and only that",
             "GammaPopup.fontFamily" in out and "font dressing" in out and "width0" not in out, out[-400:])
    finally:
        t.clean()


if __name__ == "__main__":
    sys.exit(main())
