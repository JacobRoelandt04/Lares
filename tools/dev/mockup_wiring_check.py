#!/usr/bin/env python3
"""Check a mockup's control panel against the components it drives.

    tools/dev/mockup_wiring_check.py <mockup.qml> [--root DIR] [--drift-fails]

Every entry of every value list names a `prop` on a target object. This
reads the mockup, resolves each target to the component file behind it, and
reports the five ways that wiring goes wrong:

  UNSEEN    the control is wired to a real property but its `group:` is not
            one any tab shows, so it is on no page of the panel at all. A tab
            that lists `groups:` shows only those, and a group misspelled by
            one letter -- "Headers" for "Header" -- vanishes silently. Round 10
            added four header controls that way and none of them appeared.
  MISSING   the target has no such property -- the control writes nothing.
  DEAD      the property exists but nothing reads it, so moving the control
            changes nothing on screen. "Nothing" means the component's own
            file, a quoted `"prop"` read by name anywhere under modules/ (the
            launcher's confirm knobs are asked for by name) and -- for a data
            object whose whole job is to hold numbers for other components, a
            style or a settings object -- any file under modules/ that names
            its type.
  CLASH     the property is also BOUND by whoever hosts the component, so the
            control fights that binding (or silently destroys it). A literal
            the host writes is no clash: it is the effective default.
  DRIFT     the mockup's `val:` differs from what the module ships, so the
            mockup does not show what the module ships. Not a fault -- it is
            what "Save to mockup" left behind before Save wrote the module too
            -- but worth seeing before a module is called finished. What the
            module ships is read where Save writes it (tools/dev/mockup_promote.py):
            a literal at the module's USE of a shared component wins over the
            declaration it sits on, and a knob of an object the mockup builds
            (`tun.popupWidth`) is read through the binding that feeds the
            module. Each drifted row says what the promotion would do with it:
            write it, or refuse it and why (a binding default, a sentinel).

A list named in the mockup's `themedLists` is checked differently, because
it has no target: its values ARE theme tokens, written through Theme.setToken
and read back through Theme.tokenOf. Its `prop` is resolved against
modules/common/theme/Theme.qml instead:

  MISSING   no such token (nor alias) -- the control writes nothing.
  DEAD      the token exists but no .qml in the repo reads `Theme.<token>`
            (or `Theme["prefix" + ...]`, which reads every token with that
            prefix), so nothing on screen is wearing it.

Exit code is 1 when anything UNSEEN, MISSING, DEAD or CLASH was found; DRIFT
alone exits 0, unless --drift-fails (after a promotion, DRIFT 0 is a gate).
--root checks another tree (a scratch copy the promotion was applied to).
"""
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mockup_model as mm                                   # noqa: E402
import mockup_promote as mp                                 # noqa: E402
from mockup_qmlscan import literal, parse_js_value, JsParseError   # noqa: E402


# ---- the theme --------------------------------------------------------------------
def theme_readers(repo):
    """Every token something reads: `Theme.<name>` anywhere in the tree, `root.<name>` inside Theme.qml itself
    (the ANSI slots are read there to build the arrays TerminalBackend indexes), and the prefixes of
    `Theme["note" + key]` -- a dynamic read of every token that starts with the string."""
    seen = set()
    prefixes = set()
    kit = os.path.join(repo.root, "tools", "dev")       # the dev kit's harnesses and fixtures read tokens of their own
    for dirpath, dirs, files in os.walk(repo.root):
        dirs[:] = [d for d in dirs if not d.startswith(".") and os.path.join(dirpath, d) != kit]
        for f in files:
            if not f.endswith(".qml"):
                continue
            with open(os.path.join(dirpath, f), encoding="utf-8") as fh:
                src = fh.read()
            seen |= set(re.findall(r"\bTheme\.(\w+)", src))
            # a read by NAME through Theme.tokenOf("x") -- or a file's own one-line wrapper of it called with a literal (SiliconStyle's
            # `_t("x")`, which answers the old palette for a theme island's ghost and Theme.tokenOf otherwise, 2026-10-25)
            if "Theme.tokenOf(" in src:
                seen |= set(re.findall(r"\b(?:Theme\.tokenOf|_t)\(\s*[\"']([A-Za-z]\w*)[\"']\s*\)", src))
            if f == "Theme.qml":
                seen |= set(re.findall(r"\broot\.(\w+)", src))
            if "Theme[" in src:
                # a string literal added to something, in a file that indexes Theme by a computed key
                prefixes |= {p for p in re.findall(r"[\"']([a-z][A-Za-z]{2,})[\"']\s*\+", src)}
    return seen, prefixes


def read_by_name(repo, prop, cache={}):
    """A module file (not the mockup) that names the property as a quoted string -- `fl._t("confirmGrowIcon")`."""
    key = (repo.root, prop)
    if key not in cache:
        pat = re.compile(r"[\"']%s[\"']" % re.escape(prop))
        hit = False
        for rel in repo.types.values():
            if pat.search(repo.raw(rel)):
                hit = True
                break
        cache[key] = hit
    return cache[key]


def external_readers(repo, prop, typefile):
    """Files under modules/ that read `.prop` off something and either name the type or sit in the same module
    directory: what keeps a shared style or settings object out of the DEAD list (nothing in such a file reads
    its own properties), whether the readers hold it as a typed property or as a plain `var style`. A module's
    .js counts too: a style handed to a library is read there (modules/common/float/FloatMotion.js, beside FloatStyle), comments aside: a
    module's own .js, or for a shared component under modules/common/<dir>/ the .js of that directory."""
    typename = os.path.basename(typefile)[:-4]
    mod = repo.module_dir(typefile)
    jsdir = ("modules/" + mod) if mod is not None else (os.path.dirname(typefile) if typefile.startswith("modules/common/") and typefile.count("/") >= 3 else None)
    hits = []
    pat = re.compile(r"\.%s\b" % re.escape(prop))
    for rel in repo.types.values():
        if rel == typefile:
            continue
        src = repo.raw(rel)
        if (typename in src or (mod is not None and repo.module_dir(rel) == mod)) and pat.search(src):
            hits.append(rel)
    if jsdir is not None:
        for js in glob.glob(os.path.join(repo.abspath(jsdir), "**", "*.js"), recursive=True):
            code = re.sub(r"//[^\n]*|/\*.*?\*/", "", open(js, encoding="utf-8").read(), flags=re.S)
            if pat.search(code):
                hits.append(repo.relpath(js))
    return hits


def own_reads(src, rootid, prop):
    """Reads of `prop` in the component's own source: through its root id, or unqualified (not as `prop:`,
    which is an assignment to a CHILD's property of the same name). The property's own DECLARATION is stripped:
    a shader-backed component reads every uniform through a same-named property on its ShaderEffect, and
    dropping that line drops the only read there is."""
    decl = re.compile(r"^\s*(readonly\s+)?property\s+\w+\s+%s\s*:" % re.escape(prop))
    body = "\n".join((lambda m, l: l[m.end():] if m else l)(decl.match(l), l) for l in src.split("\n"))
    reads = len(re.findall(r"\b%s\.%s\b" % (re.escape(rootid), re.escape(prop)), body)) if rootid else 0
    reads += len(re.findall(r"(?<![.\w])%s\b(?!\s*:)" % re.escape(prop), body))
    return reads


# ---- the panel's tabs --------------------------------------------------------------
def shown_groups(mockup):
    """{list id: set of groups some tab shows, or None for "all"}. A tab (or sub-tab) naming `lists:` alone shows
    every group of them; one that names `groups:` too shows only those."""
    shown = {}
    st = mockup.win.member("tabDefs", ("assign", "decl"))
    if st is None:
        return shown
    try:
        defs, _ = parse_js_value(mockup.q.value_text(st))
    except (JsParseError, IndexError):
        return shown
    tabs = []
    for t in defs if isinstance(defs, list) else []:
        if isinstance(t, dict):
            tabs.append(t)
            tabs.extend(s for s in (t.get("subs") or []) if isinstance(s, dict))
    for t in tabs:
        ids = [x for x in (t.get("lists") or []) if isinstance(x, str)]
        groups = t.get("groups")
        gset = set(g for g in groups if isinstance(g, str)) if isinstance(groups, list) else None
        for lid in ids:
            if lid not in shown:
                shown[lid] = set() if gset is not None else None
            if shown[lid] is None or gset is None:
                shown[lid] = None
            else:
                shown[lid] |= gset
    return shown


# ---- one mockup -----------------------------------------------------------------------
def check(repo, rel, out=print):
    m = mm.Mockup(repo, rel)
    resolver = mm.Resolver(m)
    planner = mp.Planner(repo, m)
    tokens, aliases = repo.theme()
    readers, prefixes = theme_readers(repo)
    shown = shown_groups(m)
    faults, drift = [], []

    plans = {}
    for row in m.rows():
        if not row.themed:
            plans[row.key] = planner.plan_row(row)

    n_entries = 0
    for lid in m.list_ids:
        entries = m.entries(lid)
        if entries is None:
            faults.append(("MISSING", lid, "(the whole list)", "registered but no such array in the mockup"))
            continue
        n_entries += len(entries)
        sh = shown.get(lid)
        if sh is not None:
            for e in entries:
                g = e.get("group") or ""
                if g and g not in sh:
                    faults.append(("UNSEEN", lid, e.get("prop", ""), "group %r is on no tab (tabs show: %s)" % (g, ", ".join(sorted(sh)) or "none")))
        # a themed list writes the theme, never the target: check the token instead
        if lid in m.themed:
            for e in entries:
                prop = e.get("prop", "")
                key = prop if prop in tokens else aliases.get(prop)
                if not key:
                    faults.append(("MISSING", lid, prop, "no such theme token or alias"))
                elif key not in readers and not any(key.startswith(p) and key != p for p in prefixes):
                    faults.append(("DEAD", lid, prop, "nothing reads Theme.%s" % key))
            continue
        expr = m.targets.get(lid) or m.target
        chain = resolver.resolve(expr) if expr else mm.Chain("unresolved", error="no target")
        if chain.kind == "unresolved":
            faults.append(("MISSING", lid, "(target)", "cannot resolve %s to a component (%s)" % (expr, chain.error)))
            continue
        last = chain.last
        local = chain.kind == "local"
        creation = mm.creation_sites(m, chain.head_obj) if (chain.kind == "component" and not chain.content and chain.head_obj is not None) else []
        sites = [] if chain.kind == "singleton" else mm.fill_root_sites(repo, mm.use_sites(chain, creation)) if not local else []
        typename = last.type
        for e in entries:
            prop = e.get("prop", "")
            if local:
                ob = chain.head_obj
                st = ob.member(prop, ("decl",))
                if st is None:
                    faults.append(("MISSING", lid, prop, "no such property on " + typename))
                    continue
                reads = own_reads(m.q.text, ob.id, prop)
                if reads == 0:
                    faults.append(("DEAD", lid, prop, "nothing in %s reads it" % os.path.basename(m.rel)))
                continue
            info = mm.lookup(repo, last.file, prop, last.inline, last.holder_rel, last.holder_q) if (last.file or last.inline) else mm.PropInfo()
            if info.decl is None:
                faults.append(("MISSING", lid, prop, "no such property on " + typename))
                continue
            decl_rel, decl_q, _ = info.decl
            base = None if decl_rel == (last.file or last.holder_rel) else decl_rel
            # DEAD: read in the component's own file, by name anywhere, or off an instance elsewhere
            own_rel = last.file or last.holder_rel
            own_q = repo.qml(own_rel)
            rootid = own_q.root().id if own_q.root() is not None else None
            reads = own_reads(own_q.text, rootid, prop)
            if reads == 0 and base is not None:
                bq = repo.qml(base)
                reads = own_reads(bq.text, bq.root().id if bq.root() is not None else None, prop)
            if reads == 0 and read_by_name(repo, prop):
                reads = 1
            if reads == 0 and last.file and external_readers(repo, prop, last.file):
                reads = 1
            if reads == 0 and base is not None and external_readers(repo, prop, base):
                reads = 1
            if reads == 0:
                faults.append(("DEAD", lid, prop, "nothing in %s, nor in anything that names it, reads it" % typename))
            # CLASH: bound (not given a literal) by whoever hosts it
            for hrel, hq, hob, prefix in sites:
                if hob is None:
                    continue
                st = hob.member(prefix + prop, ("assign",))
                if st is not None:
                    k, _, t = literal(hq.value_text(st))
                    if k == "expr":
                        faults.append(("CLASH", lid, prop, "the host binds it to " + t.strip()[:48]))
                        break
            if chain.hops and chain.hops[0].holder_obj is not None and chain.kind == "component":
                # the mockup's own instance of the first hop (`popup`), when the property is on the first hop itself
                if len(chain.hops) == 1:
                    st = chain.hops[0].holder_obj.member(prop, ("assign",))
                    if st is not None and literal(m.q.value_text(st))[0] == "expr" and not any(f[0] == "CLASH" and f[1] == lid and f[2] == prop for f in faults):
                        faults.append(("CLASH", lid, prop, "the host binds it to " + m.q.value_text(st).strip()[:48]))
        # DRIFT: what Save would change, row by row, from the planner
        for row in m.rows():
            if row.list_id != lid or row.themed:
                continue
            rp = plans.get(row.key)
            if rp is None or rp.status not in ("write", "refuse"):
                continue
            part = next((p for p in rp.parts if p.status == rp.status), None)
            now = part.eff.text if part is not None and part.eff is not None and part.eff.text else "(none)"
            why = ("promotion writes it" if rp.status == "write" else "promotion refuses: " + rp.reason)
            drift.append((lid, row.prop, now, "" if row.val is None else str(row.val), why))

    out("%s: %d entries in %d lists" % (os.path.basename(rel), n_entries, len(m.list_ids)))
    for kind in ("UNSEEN", "MISSING", "DEAD", "CLASH"):
        rows = [f for f in faults if f[0] == kind]
        out("\n%s (%d)" % (kind, len(rows)))
        for _, lid, prop, why in rows:
            out("   %-14s %-26s %s" % (lid, prop, why))
        if not rows:
            out("   none")
    out("\nDRIFT (%d) -- mockup default vs the component's own" % len(drift))
    for lid, prop, d, v, why in sorted(drift):
        out("   %-14s %-26s component=%-10s mockup=%-10s %s" % (lid, prop, d, v, why))
    if not drift:
        out("   none")
    return faults, drift


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    flags = [a for a in argv[1:] if a.startswith("--")]
    root = None
    if "--root" in flags:
        i = argv.index("--root")
        root = argv[i + 1]
        args = [a for a in args if a != root]
    if len(args) != 1:
        print(__doc__)
        return 2
    repo = mm.Repo(root)
    path = args[0]
    rel = path if not os.path.isabs(path) else repo.relpath(path)
    if not os.path.exists(repo.abspath(rel)):
        rel = os.path.basename(path)
    faults, drift = check(repo, rel)
    if faults:
        return 1
    return 1 if (drift and "--drift-fails" in flags) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
