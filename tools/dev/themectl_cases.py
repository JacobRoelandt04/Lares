#!/usr/bin/env python3
"""themectl's own cases: merge, resolver, every target's render, atomic write, backup, refusals.

    python3 tools/dev/themectl_cases.py                 the cases against this tree           last line THEMECTL_CASES RESULT PASS|FAIL
    ARM=<name> python3 tools/dev/themectl_cases.py      one fault patched into a COPY of tools/theme; the check it names must FAIL
    ARM=all python3 tools/dev/themectl_cases.py         every arm in turn                       last line THEMECTL_CASES ARMS PASS|FAIL
    THEMECTL_TREE=<dir>                             run against another tree (a tools/theme + themes + Theme.qml copy)
    THEMECTL_SHAPE=post                             every group on the desktop AFTER the switch-over, to find what depends on the
                                                    desktop's shape: the FAILs are the groups sandbox() says are pinned to "pre"

Every run that touches files goes through tools/dev/themectl_sandbox.py: a HOME seeded from the FIXTURE desktop
(tools/dev/fixtures/themectl/home: the user's files as they were before the switch-over, the ones themectl owns and restores), PATH
stubs, keyfile gsettings. Nothing here reads the user's real files: a test seeded from them stops testing the day the desktop
changes shape (nine checks went red when the user ran `themectl install && migrate && apply`). The run ends with the proof that
nothing outside the sandbox changed (`THEMECTL_OUTSIDE ...`).
"""
import contextlib
import importlib.machinery
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
sys.dont_write_bytecode = True
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import themectl_sandbox as sbx  # noqa: E402

TREE = os.environ.get("THEMECTL_TREE") or REPO
THEMECTL = TREE + "/tools/theme/themectl"
SCRATCH = os.environ.get("SCRATCH") or tempfile.gettempdir()
WORK = tempfile.mkdtemp(prefix="themectl_cases.", dir=SCRATCH)

RESULTS = []
# the stock btop themes theme-switch.py pointed btop at (themes/eva.json: assets.<mode>.btopTheme)
BTOP_STOCK = {"light": "/usr/share/btop/themes/flat-remix-light.theme", "dark": "/usr/share/btop/themes/flat-remix.theme"}


def check(cid, ok, detail=""):
    RESULTS.append((cid, bool(ok), detail))
    print("%-4s %s%s" % ("ok" if ok else "FAIL", cid, ("  -- " + str(detail)) if (detail and not ok) else ""))
    return ok


def load_module():
    loader = importlib.machinery.SourceFileLoader("themectl_under_test", THEMECTL)
    spec = importlib.util.spec_from_loader("themectl_under_test", loader)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["themectl_under_test"] = mod
    loader.exec_module(mod)
    return mod


MOD = load_module()
_n = [0]


HOME_FIXTURE = REPO + "/tools/dev/fixtures/themectl/home"      # the REPO's, not TREE's: an arm tree copies only tools/theme, themes and Theme.qml


def n_targets():
    """How many targets an apply runs (one `ok` line each): the shipped targets.json's, never a literal (a new target is not a regression)."""
    return len(jl(TREE + "/tools/theme/targets.json")["targets"])


def sandbox(shape=None):
    """A sandbox HOME seeded from the fixture desktop. Every case that owns, keeps or restores a file starts from this and never from a
    copy of the user's files: those changed the day they ran `themectl install && migrate && apply`. Two shapes of the same desktop:

      "pre"   the app configs, links and colour files as they are BEFORE the switch-over (kitty's colour file as the old script wrote
              it, starship.toml and hyprlock.conf links into HyprV, no btop current.theme, no hyprlock-colors.conf), in light mode
      "post"  that desktop after the user's one-liner, run by the tool under test: `install`, `migrate`, `apply` -- the shape their real
              home has been in since 2026-10-22, and made by the tool itself so that it cannot drift from what the tool does

    A group is pinned to the shape it asserts about: C7, C7_btop, C8's refusals, C9's install pair, C15 and C16 fail on "post" (their
    first write, their absent outputs and their anchors are already gone); C17 is the one that wants it."""
    shape = shape or os.environ.get("THEMECTL_SHAPE") or "pre"
    _n[0] += 1
    root = os.path.join(WORK, "sb%d" % _n[0])
    sbx.make(root, seed=HOME_FIXTURE)
    # the machine's GTK themes are not the case's: a pair's gtkTheme list falls back to its last entry here, as on a machine with
    # none of the preferred packages (the user installing one flipped C17 and C19 on 2026-11-08); gsettings keeps its schemas, the
    # icons stay. C23 makes the themes it asks about. ctl() runs every themectl with this XDG_DATA_DIRS unless a case names its own.
    os.makedirs(root + "/sysdata")
    for d in ("glib-2.0", "icons"):
        os.symlink("/usr/share/" + d, root + "/sysdata/" + d)
    if shape == "post":
        for args in (("install",), ("migrate",), ("apply",)):
            rc, out, err = ctl(root, *args)
            if rc != 0:
                raise RuntimeError("the post-switch-over desktop could not be made: themectl %s -> %d\n%s%s" % (args[0], rc, out[-400:], err[-400:]))
    elif shape != "pre":
        raise ValueError("no desktop shape %r (pre | post)" % shape)
    return root


def ctl(root, *args, extra=None):
    """themectl in the sandbox -> (rc, stdout, stderr). XDG_DATA_DIRS is the sandbox's own (sandbox()) unless EXTRA names one."""
    env = {"XDG_DATA_DIRS": root + "/sysdata"} if os.path.isdir(root + "/sysdata") else {}
    env.update(extra or {})
    t0 = time.time()
    r = sbx.run(root, ["python3", THEMECTL] + list(args), extra=env)
    if "follow in the background" in r.stdout:
        _evince_settle(root, t0)
    return r.returncode, r.stdout, r.stderr


def _evince_settle(root, t0, secs=15.0):
    """The evince target's background half (`themectl _evince`, detached) writes after the run has returned: wait until it has said its
    word for this run (`evince-last` newer than the run's start) and holds its lock no more, so no later snapshot catches it writing."""
    import fcntl
    st = home(root) + "/.local/state/theme/"
    end = time.time() + secs
    while time.time() < end:
        try:
            if os.stat(st + "evince-last").st_mtime >= t0:
                with open(st + "evince-want.lock") as fh:
                    fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    return True
        except (OSError, BlockingIOError):
            pass
        time.sleep(0.05)
    return False


def home(root):
    return root + "/home"


def rd(p):
    try:
        with open(p, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def jl(path):
    """A JSON file, {} when it is not there (a check then fails by its own words instead of the case crashing)."""
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


@contextlib.contextmanager
def in_env(root):
    """The process itself inside the sandbox's environment (for the in-process cases that build a Paths)."""
    saved = dict(os.environ)
    os.environ.clear()
    os.environ.update(sbx.env_of(root))
    try:
        yield
    finally:
        os.environ.clear()
        os.environ.update(saved)


def write_targets(root, targets, options=None):
    d = home(root) + "/.config/theme"
    os.makedirs(d, exist_ok=True)
    with open(d + "/targets.json", "w") as f:
        json.dump({"version": 1, "options": options or {}, "targets": targets}, f)


def tree_state(root):
    """Everything under the sandbox home: path -> (kind, mtime_ns, size, link/hash) -- for 'nothing was written'. Every real run's timing
    record (~/.local/state/theme/last-run.tsv) is a log, not something the run changed: left out (and the directory it lands in)."""
    out = {}
    base = home(root)
    log = os.path.join(base, ".local/state/theme/last-run.tsv")
    for dp, dns, fns in os.walk(base):
        for n in dns + fns:
            p = os.path.join(dp, n)
            if p == log or p == os.path.dirname(log):
                continue
            st = os.lstat(p)
            out[os.path.relpath(p, base)] = (st.st_mode, st.st_mtime_ns, st.st_size, os.readlink(p) if os.path.islink(p) else None)
    return out


def content_state(root):
    """What a desktop IS, mtimes aside: path -> ("file", bytes) | ("link", target) under the sandbox home, without themectl's own
    bookkeeping (~/.config/theme: the backup, the installed themes, the lock; ~/.local/state/theme: the wallpaper bag and the list yazi's
    plugin reads) and without gsettings' keyfile (a setting is no file themectl keeps, so `restore` does not put it back). Two states are
    the same desktop when these are equal."""
    out = {}
    base = home(root)
    for dp, dns, fns in os.walk(base):
        for n in fns + [d for d in dns if os.path.islink(os.path.join(dp, d))]:
            p = os.path.join(dp, n)
            rel = os.path.relpath(p, base)
            if rel.startswith(".config/theme/") or rel.startswith(".config/glib-2.0/") or rel.startswith(".local/state/theme/"):
                continue
            if os.path.islink(p):
                out[rel] = ("link", os.readlink(p))
            else:
                with open(p, "rb") as f:
                    out[rel] = ("file", f.read())
    return out


# ================================================================================================== C1 merge, C2 resolver

def c1_c2():
    L0 = {"a": "#111111", "b": "#222222", "c": "@a"}
    v, e = MOD.resolve_all(L0, {"b": "#333333", "n": 14, "font": "Inter"}, {"a": "#444444", "d": "@b"})
    check("C1.block-over-l0", v["a"] == [68, 68, 68, 255] and not e, v.get("a"))
    check("C1.common-over-l0", v["b"] == [51, 51, 51, 255], v.get("b"))
    check("C1.alias-follows-the-merged-value", v["c"] == [68, 68, 68, 255] and v["d"] == [51, 51, 51, 255], (v.get("c"), v.get("d")))
    check("C1.non-colour-common-passes-through", v["n"] == 14 and v["font"] == "Inter")
    v, e = MOD.resolve_all(L0, {"b": "#333333"}, {"b": "#555555"})
    check("C1.block-over-common", v["b"] == [85, 85, 85, 255], v.get("b"))
    v, e = MOD.resolve_all(L0, None, None)
    check("C1.nothing-written-is-l0", v["a"] == [17, 17, 17, 255] and v["c"] == [17, 17, 17, 255] and not e)

    def one(block, key, l0=None, common=None):
        v, e = MOD.resolve_all(l0 if l0 is not None else {"t": "#000000"}, common, block)
        return v.get(key), e.get(key)
    # literals
    check("C2.rgb-short", one({"x": "#abc"}, "x")[0] == [170, 187, 204, 255])
    check("C2.rrggbb", one({"x": "#4480F4"}, "x")[0] == [68, 128, 244, 255])
    check("C2.aarrggbb-is-qmls-order", one({"x": "#80AABBCC"}, "x")[0] == [170, 187, 204, 128])
    check("C2.whitespace-trimmed", one({"x": " #abc "}, "x")[0] == [170, 187, 204, 255])
    val, err = one({"t": "#abcd"}, "t")
    check("C2.colour-token-needs-a-colour", err and "not a colour" in err and val == [0, 0, 0, 255], (val, err))
    # aliases
    v, e = MOD.resolve_all({}, None, {"x": "@y", "y": "@z", "z": "#010203"})
    check("C2.alias-chain", v["x"] == [1, 2, 3, 255] and not e, v.get("x"))
    # recipes: goldens from colorsys (an independent HLS implementation), rounding floor(x + 0.5)
    gold = [("#4480F4", "lighten", "0.06", [97, 148, 246]), ("#4480F4", "darken", "0.06", [39, 108, 242]),
            ("#EAEDF5", "darken", "0.1", [199, 207, 229]), ("#2C3037", "lighten", "0.2", [89, 97, 112]),
            ("#808080", "lighten", "0.25", [192, 192, 192]), ("#000000", "lighten", "0.5", [128, 128, 128]),
            ("#FFFFFF", "darken", "0.5", [128, 128, 128]), ("#FF0000", "lighten", "0.3", [255, 153, 153])]
    bad = []
    for base, op, n, want in gold:
        got = one({"x": "@b %s %s" % (op, n), "b": base}, "x")[0]
        if not got or got[:3] != want or got[3] != 255:
            bad.append((base, op, n, want, got))
    check("C2.lighten-darken-goldens", not bad, bad)
    check("C2.lighten-zero-is-identity", all(one({"x": "@b lighten 0", "b": c}, "x")[0][:3] == MOD.parse_colour(c)[:3] for c in ("#4480F4", "#EAEDF5", "#2C3037", "#123456", "#FEDCBA", "#7F7F80")))
    check("C2.clamped-at-white-and-black", one({"x": "@b lighten 1", "b": "#4480F4"}, "x")[0][:3] == [255, 255, 255] and one({"x": "@b darken 1", "b": "#4480F4"}, "x")[0][:3] == [0, 0, 0])
    check("C2.alpha", one({"x": "@b alpha 0.5", "b": "#4480F4"}, "x")[0] == [68, 128, 244, 128])
    # the half-way case that tells floor(x + 0.5) from Python's round(): 0.00980392156862745 * 255 is exactly 2.5
    check("C2.alpha_half", one({"x": "@b alpha 0.00980392156862745", "b": "#4480F4"}, "x")[0] == [68, 128, 244, 3], one({"x": "@b alpha 0.00980392156862745", "b": "#4480F4"}, "x"))
    check("C2.recipe-keeps-alpha", one({"x": "@b lighten 0.1", "b": "#80445566"}, "x")[0][3] == 0x80)
    check("C2.recipe-on-a-recipe", one({"x": "@m lighten 0.1", "m": "@b darken 0.1", "b": "#4480F4"}, "x")[0] is not None)
    # errors: each names the key and falls back to L0 (or is left out when there is none)
    for name, block, key, needle in [
            ("cycle", {"p": "@q", "q": "@p"}, "p", "circle"), ("self", {"s": "@s"}, "s", "circle"),
            ("unknown-target", {"x": "@nope"}, "x", "not defined"), ("bad-op", {"x": "@t brighten 0.3"}, "x", "expected"),
            ("missing-amount", {"x": "@t lighten"}, "x", "expected"), ("amount-over-1", {"x": "@t lighten 1.5"}, "x", "outside 0..1"),
            ("negative-amount", {"x": "@t lighten -0.1"}, "x", "expected"), ("amount-not-a-number", {"x": "@t lighten abc"}, "x", "expected"),
            ("extra-words", {"x": "@t lighten 0.1 0.2"}, "x", "expected"), ("empty-alias", {"x": "@"}, "x", "empty alias")]:
        try:
            val, err = one(block, key)
        except RecursionError:
            val, err = "RecursionError", "RecursionError"
        check("C2.%s" % name, err and needle in err and val is None, (val, err))
    val, err = one({"t": "@t"}, "t")
    check("C2.error-falls-back-to-l0", err and val == [0, 0, 0, 255], (val, err))
    val, err = one({"x": "@font darken 0.1"}, "x", common={"font": "Inter"})
    check("C2.recipe-on-a-non-colour", err and "not a colour" in err, (val, err))
    # the L0 chain itself
    v, e = MOD.resolve_all({"a": "#102030", "b": "@a"}, None, {"b": "@zz"})
    check("C2.fallback-follows-l0-aliases", v["b"] == [16, 32, 48, 255] and "b" in e, (v.get("b"), e))

    with in_env(sandbox()):
        P = MOD.Paths()
        l0 = MOD.l0_defaults(P)
        check("C3.l0-from-theme-qml", len(l0) >= 168 and l0.get("accent") == "#4480F4" and l0.get("netLampLink") == "@ok", len(l0))
        th = MOD.load_theme(P, "eva")
        for mode in MOD.MODES:
            v, e = th.mode_values(mode)
            check("C3.eva-%s-resolves-clean" % mode, not e and all(isinstance(v.get(k), list) for k in l0), list(e.items())[:3])
        v, _ = th.mode_values("dark")
        check("C3.eva-dark-surface", v["surface"] == [0x2C, 0x30, 0x37, 255] and v["terminalFg"] == [0xB0, 0xB7, 0xC3, 255])
        v, _ = th.mode_values("light")
        check("C3.eva-light-alias-textOnAccent", v["textOnAccent"] == v["surface"] == [0xEA, 0xED, 0xF5, 255])


# ====================================================================================================== C4 template engine

def c4():
    vals = {"x": [68, 128, 244, 255], "y": [1, 2, 3, 128], "n": 14, "s": "Inter"}
    ctx = {"theme": "eva", "mode": "dark", "assets.gtkTheme": "G"}
    r = MOD.render("{{ x }} {{x|hex}} {{ x | rgb }} {{y|hexa}} {{y}} {{theme}}/{{mode}} {{assets.gtkTheme}} {{n}} {{s}}", ctx, vals)
    check("C4.formats", r == "#4480F4 4480F4 68, 128, 244 01020380 #01020380 eva/dark G 14 Inter", r)
    for name, text, needle in [("unknown-token", "a\nb {{nope}}", "line 2"), ("format-on-context", "{{theme|hex}}", "takes no format"),
                               ("unknown-format", "{{x|wat}}", "unknown colour format"), ("format-on-non-colour", "{{s|hex}}", "not a colour")]:
        try:
            MOD.render(text, ctx, vals, "tpl")
            check("C4.%s" % name, False, "no error")
        except MOD.TemplateError as e:
            check("C4.%s" % name, needle in str(e), str(e))


# ===================================================================================================== C5 every target's render

def c5():
    root = sandbox()
    for mode in MOD.MODES:
        with in_env(root):
            P = MOD.Paths()
            th = MOD.load_theme(P, "eva")
            options, targets, _ = MOD.load_targets(P)
            ctx = MOD.Ctx(P, options, th, mode, True)
            out, links = {}, {}
            for spec in targets:
                if spec["type"] == "file":
                    tpl, _p = ctx.template(spec["template"])
                    out[spec["name"]] = ctx.render(tpl, spec["template"], {"output": "/x"})
                if spec["type"] == "link":
                    links[spec["name"]] = ctx.render(spec["target"], spec["name"] + " target")
        check("C5.%s.no-token-left" % mode, all("{{" not in t and "}}" not in t for t in out.values()), [k for k, t in out.items() if "{{" in t])
        k = {m.group(1): m.group(2) for m in re.finditer(r"^(\w+)\s+(#[0-9A-F]{6})$", out["kitty"], re.M)}
        # 23 of the terminal's own and the prompt's eight slots (53-56, 89-92: templates/starship.toml prints those numbers)
        check("C5.%s.kitty-31-colour-keys" % mode, len(k) == 31 and "color15" in k and "url_color" in k
              and all("color%d" % n in k for n in (53, 54, 55, 56, 89, 90, 91, 92)), len(k))
        stock = BTOP_STOCK[mode]
        check("C5.%s.btop-links-to-the-stock-theme-of-the-mode" % mode, links.get("btop") == stock and "theme[main_fg]" in (rd(stock) or ""), (links.get("btop"), stock))
        try:
            import tomllib
            t = tomllib.loads(out["starship"])
            check("C5.%s.starship-is-toml" % mode, "format" in t and t["character"]["success_symbol"].startswith("[\u276f]"), list(t))
        except Exception as e:
            check("C5.%s.starship-is-toml" % mode, False, e)
        lp = os.path.join(WORK, "theme_%s.lua" % mode)
        open(lp, "w").write(out["hyprland"])
        lua = shutil.which("lua5.4") or shutil.which("lua") or shutil.which("luajit")
        if lua:
            r = subprocess.run([lua, "-e", 'assert(loadfile("%s"))' % lp], capture_output=True, text=True)
            check("C5.%s.hyprland-lua-parses" % mode, r.returncode == 0, r.stderr)
        check("C5.%s.hyprland-lua-names-the-hyprglass-mode" % mode, re.findall(r'^themectl_hyprglass_theme = "(\w+)"', out["hyprland"], re.M) == [mode], mode)
        if lua:
            # run it against a stub `hl`: the plugin's default_theme is set at once when the plugin is loaded, set again by the config.reloaded handler
            # (registered ONCE however many times the file is run), and nothing is set -- no error -- when the plugin is not loaded
            stub = ('local calls, hooks = {}, {}\nlocal function cfg(t) local h = t.plugin and t.plugin.hyprglass; if h then calls[#calls + 1] = h.default_theme end end\n'
                    'local function mk(plug) return {config = cfg, on = function(ev, fn) hooks[#hooks + 1] = {ev, fn} end, plugin = plug} end\n'
                    'hl = mk({hyprglass = {}}); dofile("%s"); dofile("%s")\n'
                    'local n = #calls\nfor _, h in ipairs(hooks) do if h[1] == "config.reloaded" then h[2]() end end\n'
                    'io.write(#hooks, " ", n, " ", #calls - n, " ", tostring(calls[1]), "\\n")\n'
                    'hl = mk({}); calls = {}; hooks = {}; themectl_hyprglass_hooked = nil; dofile("%s"); io.write(#calls, " ", #hooks, "\\n")\n') % (lp, lp, lp)
            r = subprocess.run([lua, "-e", stub], capture_output=True, text=True)
            check("C5.%s.hyprglass-set-now-hooked-once-and-silent-without-the-plugin" % mode, r.stdout.split("\n")[:2] == ["1 2 1 " + mode, "0 1"], (r.stdout, r.stderr[:200]))
        locs = re.findall(r'^local (\w+) = "([0-9A-F]{6})"', out["hyprland"], re.M)
        check("C5.%s.hyprland-four-colours" % mode, [n for n, _ in locs] == ["border_active", "border_inactive", "border_group_locked", "group_tab"], locs)
        # hypr-group-tabs 0.3 draws the active tab inside the border, from the border colour to groupbar col.active: the tab is its own
        # colour (hyprGroupTab), and a locked group's border is the plain border (the lock shows in its tab)
        lv = dict(locs)
        check("C5.%s.the-group-tab-is-its-own-colour-and-the-locked-border-the-plain-one" % mode,
              re.search(r'^\s*active = +"rgb\(" \.\. group_tab \.\. "\)",$', out["hyprland"], re.M) is not None
              and re.search(r'^\s*border_locked_active = +"rgb\(" \.\. border_active \.\. "\)",$', out["hyprland"], re.M) is not None
              and lv.get("group_tab") not in (None, lv.get("border_active")), lv)
        hv = re.findall(r"^\$(\w+)\s*=\s*([0-9A-F]{6})$", out["hyprlock"], re.M)
        check("C5.%s.hyprlock-seven-variables" % mode, [n for n, _ in hv] == ["FIELD", "BORDER", "BACKGROUND", "FOREGROUND", "ACCENT", "INCORRECT", "CAPS"], hv)


# ============================================================================================== C6 atomic writes, C7 backups

def c6():
    d = os.path.join(WORK, "atomic")
    os.makedirs(d)
    p = d + "/x.conf"
    MOD.write_atomic(p, "old\n")
    check("C6.writes-and-sets-0644", rd(p) == "old\n" and (os.stat(p).st_mode & 0o777) == 0o644)
    real_replace = os.replace
    try:
        def boom(a, b):
            raise OSError("simulated crash between write and rename")
        os.replace = boom
        raised = False
        try:
            MOD.write_atomic(p, "new\n")
        except OSError:
            raised = True
    finally:
        os.replace = real_replace
    check("C6.a-failed-write-leaves-the-old-file-whole", raised and rd(p) == "old\n", rd(p))
    check("C6.a-failed-write-leaves-no-temp-file", sorted(os.listdir(d)) == ["x.conf"], os.listdir(d))
    other = d + "/other.txt"
    open(other, "w").write("untouched\n")
    link = d + "/link.conf"
    os.symlink(other, link)
    MOD.write_atomic(link, "through the link?\n")
    check("C6.replaces-a-symlink-not-its-target", not os.path.islink(link) and rd(link) == "through the link?\n" and rd(other) == "untouched\n", (os.path.islink(link), rd(other)))
    nested = d + "/a/b/c.conf"
    MOD.write_atomic(nested, "x")
    check("C6.creates-the-directories", rd(nested) == "x")


def c7():
    root = sandbox()
    h = home(root)
    kit = h + "/.config/kitty/current-theme.conf"
    orig = rd(kit)
    rc, out, _ = ctl(root, "apply")
    man = jl(h + "/.config/theme/backup/manifest.json")
    e = man.get(kit)
    check("C7.keeps-the-original-file", rc == 0 and e and e["kind"] == "file" and rd(h + "/.config/theme/backup/" + e["backup"]) == orig, (rc, e))
    e = e or {"backup": "none"}
    # the fixture's starship.toml is the old script's link into HyprV/starship (starship_evalight.toml, its light mode)
    check("C7.symlink-recorded-as-a-link", man.get(h + "/.config/starship.toml", {}).get("kind") == "symlink" and "starship_eva" in man[h + "/.config/starship.toml"].get("link", ""), man.get(h + "/.config/starship.toml"))
    check("C7.absent-recorded-as-absent", man.get(h + "/.config/btop/themes/current.theme", {}).get("kind") == "absent")
    # the second apply must not replace the kept original with themectl's own output
    open(kit, "w").write("# someone edited it\n")
    ctl(root, "apply")
    man2 = jl(h + "/.config/theme/backup/manifest.json")
    check("C7.never-overwrites-a-kept-original", man2[kit] == e and rd(h + "/.config/theme/backup/" + e["backup"]) == orig)
    # restore
    rc, out, _ = ctl(root, "restore", "--dry-run")
    check("C7.restore-dry-run-writes-nothing", rc == 0 and rd(kit) != orig and os.path.exists(h + "/.config/theme/backup/manifest.json") and "would put back" in out, out[:200])
    rc, out, _ = ctl(root, "restore", "kitty", "starship", "btop")
    star = h + "/.config/starship.toml"
    check("C7.restore-puts-back-file-link-and-absence", rc == 0 and rd(kit) == orig and os.path.islink(star) and "starship_eva" in os.readlink(star) and not os.path.lexists(h + "/.config/btop/themes/current.theme"), out[:300])
    man3 = jl(h + "/.config/theme/backup/manifest.json")
    check("C7.restored-files-are-no-longer-owned", kit not in man3 and star not in man3 and h + "/.config/hypr/hyprlock-colors.conf" in man3)
    # a backup that cannot be taken stops the write: nothing is written without the original being safe
    root = sandbox()
    h = home(root)
    os.makedirs(h + "/.config/theme/backup", exist_ok=True)
    open(h + "/.config/theme/backup/files", "w").write("not a directory\n")      # backup/files cannot be created
    kit = h + "/.config/kitty/current-theme.conf"
    orig = rd(kit)
    rc, out, _ = ctl(root, "apply")
    kline = [l for l in out.splitlines() if l.split()[1:2] == ["kitty"]]
    check("C7.no-backup-no-write", kline and kline[0].startswith("FAIL") and "cannot keep the original" in kline[0] and rd(kit) == orig, kline)


def c7_btop():
    """btop's output is a link now: whatever was at its place (a file, someone's link) is kept and put back, and the link is not
    "restored" into a file."""
    for kind in ("file", "symlink"):
        root = sandbox()
        h = home(root)
        cur = h + "/.config/btop/themes/current.theme"
        os.makedirs(os.path.dirname(cur), exist_ok=True)
        if kind == "file":
            open(cur, "w").write("# a theme of my own\ntheme[main_fg]=\"#123456\"\n")
        else:
            os.symlink("/usr/share/btop/themes/nord.theme", cur)
        mine = rd(cur)
        rc, out, _ = ctl(root, "apply", "--only", "btop")
        man = jl(h + "/.config/theme/backup/manifest.json")
        check("C7.btop-%s-is-replaced-by-the-link-and-kept" % kind, rc == 0 and os.path.islink(cur) and "flat-remix" in os.readlink(cur) and man.get(cur, {}).get("kind") == kind, (rc, man.get(cur), out[:200]))
        rc, out, _ = ctl(root, "restore", "btop")
        if kind == "file":
            back = rc == 0 and os.path.isfile(cur) and not os.path.islink(cur) and rd(cur) == mine
        else:
            back = rc == 0 and os.path.islink(cur) and os.readlink(cur) == "/usr/share/btop/themes/nord.theme"
        check("C7.btop-restore-puts-back-the-%s-and-not-the-link" % kind, back and cur not in jl(h + "/.config/theme/backup/manifest.json"), (rc, out[:200]))


# ====================================================================================== C8 failure modes, refusals, exit status

def lines_of(out):
    return {l.split()[1]: l for l in out.splitlines() if l[:2] == "ok" or l[:4] == "FAIL"}


def put_shell(root, text, name="shell.jsonc"):
    """The user's shell.jsonc in the sandbox (themectl reads its theme.wallpapers)."""
    d = home(root) + "/.config/quickshell"
    os.makedirs(d, exist_ok=True)
    with open(d + "/" + name, "w") as f:
        f.write(text)


def c8():
    # a clean apply: every target says ok, exit 0
    root = sandbox()
    rc, out, _ = ctl(root, "toggle")
    ls = lines_of(out)
    check("C8.clean-apply-every-target-prints-ok-and-exits-0", rc == 0 and len(ls) == n_targets() and all(l.startswith("ok") for l in ls.values()), (rc, out[-300:]))
    # one FAIL per cause; others carry on; the exit status counts them
    root = sandbox()
    write_targets(root, [
        {"name": "t1", "type": "file", "template": "no-such-template", "output": "${XDG_CONFIG_HOME}/x/a"},
        {"name": "t2", "type": "file", "template": "kitty-current-theme.conf", "output": "${XDG_CONFIG_HOME}/x/b", "reload": {"argv": ["hyprctl", "eval", "x"], "when": "always", "expect": "^ok"}},
        {"name": "t3", "type": "gsettings", "keys": [{"schema": "org.example.NoSuchSchema", "key": "k", "value": "v"}]},
        {"name": "t4", "type": "state"}])
    rc, out, _ = ctl(root, "apply")
    ls = lines_of(out)
    check("C8.missing-template", ls["t1"].startswith("FAIL") and "template no-such-template not found" in ls["t1"], ls["t1"])
    check("C8.gsettings-failure", ls["t3"].startswith("FAIL") and "gsettings" in ls["t3"], ls["t3"])
    check("C8.the-others-carry-on", ls["t2"].startswith("ok") and ls["t4"].startswith("ok"))
    check("C8.exit-status-counts-the-fails", rc == 2, rc)
    # a reload that fails, one that answers with an error text, a pkill that matched nothing
    for env, tgt, want, name in [({"STUB_HYPRCTL_RC": "7"}, "hyprland", "FAIL", "reload-exit-status"),
                                 ({"STUB_HYPRCTL_OUT": "lua: attempt to call a nil value"}, "hyprland", "FAIL", "reload-answer-text"),
                                 ({"STUB_PKILL_RC": "1"}, "kitty", "ok", "pkill-nothing-running-is-ok"),
                                 ({"STUB_PKILL_RC": "2"}, "kitty", "FAIL", "pkill-error-is-a-fail")]:
        root = sandbox()
        rc, out, _ = ctl(root, "toggle", extra=env)
        ln = lines_of(out)[tgt]
        check("C8.%s" % name, ln.startswith(want), ln)
        if name == "reload-answer-text":
            check("C8.reload-answer-text-is-in-the-reason", "nil value" in ln, ln)
    # an output directory that cannot be written
    root = sandbox()
    h = home(root)
    os.chmod(h + "/.config/kitty", 0o555)
    try:
        rc, out, _ = ctl(root, "toggle")
        ln = lines_of(out)["kitty"]
    finally:
        os.chmod(h + "/.config/kitty", 0o755)
    check("C8.unwritable-output", ln.startswith("FAIL") and "cannot" in ln and rc == 1, (rc, ln))
    # assets: a wallpaper file shell.jsonc names that is not there; a theme with no assets and no desktop keys (the nine-line theme)
    root = sandbox()
    h = home(root)
    put_shell(root, '{ "theme": { "wallpapers": { "eva": { "dark": "~/Pictures/nothing-here.png" } } } }')
    rc, out, _ = ctl(root, "set", "eva", "dark")
    ln = lines_of(out)["wallpaper"]
    check("C8.missing-wallpaper-file", ln.startswith("FAIL") and "not found" in ln, ln)
    root = sandbox()
    h = home(root)
    os.makedirs(h + "/.config/theme/themes", exist_ok=True)
    json.dump({"name": "bare", "light": {"accent": "#FF0000"}, "dark": {"accent": "#00FF00"}}, open(h + "/.config/theme/themes/bare.json", "w"))
    rc, out, _ = ctl(root, "set", "bare", "dark")
    ls = lines_of(out)
    # the prompt's ramp falls back to the accent (its colours are slots of kitty's file: a theme with no ramp keeps its kitty colours)
    kt = open(h + "/.config/kitty/current-theme.conf").read()
    st = open(h + "/.config/starship.toml").read()
    check("C8.a-bare-theme-colour-targets-fall-back-to-l0", ls["kitty"].startswith("ok") and ls["starship"].startswith("ok")
          and "color53 #00FF00" in kt and "color89 #00FF00" in kt, (ls["kitty"], ls["starship"], [l for l in kt.splitlines() if l.startswith("color5")]))
    # the prompt prints SLOTS, never a hex: a hex is stored in the cell and keeps the old theme on every prompt already printed
    import re as _re
    check("C8.the-prompt-prints-slots", "fg:54 bg:53" in st and "bold 91" in st
          and not _re.search(r"#[0-9A-Fa-f]{6}", "\n".join(l for l in st.splitlines() if not l.startswith("#"))),
          [l for l in st.splitlines() if "#" in l and not l.startswith("#")][:3])
    check("C8.a-bare-theme-says-what-it-lacks", ls["wallpaper"].startswith("ok") and "skipped" in ls["wallpaper"] and ls["hyprland"].startswith("FAIL") and "hyprBorderActive" in ls["hyprland"]
          and ls["btop"].startswith("FAIL") and "assets.dark.btopTheme" in ls["btop"], (ls["wallpaper"], ls["hyprland"], ls["btop"]))
    # refusals: exit 100, no target ran
    for name, args, pre in [("unknown-theme", ["set", "nosuch"], None), ("unknown-mode", ["set", "eva", "purple"], None),
                            ("unknown-only", ["apply", "--only", "nosuchtarget"], None), ("unknown-skip", ["apply", "--skip", "nosuchtarget"], None),
                            ("bad-state-json", ["apply"], ("state.json", "{not json")),
                            ("bad-theme-json", ["apply"], ("themes/eva.json", "{not json")),
                            ("no-mode-block", ["set", "eva", "dark"], ("themes/eva.json", json.dumps({"name": "eva", "light": {}}))),
                            ("bad-usage", ["frobnicate"], None)]:
        root = sandbox()
        h = home(root)
        if pre:
            p = h + "/.config/theme/" + pre[0]
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "w").write(pre[1])
        kit0 = rd(h + "/.config/kitty/current-theme.conf")
        rc, out, err = ctl(root, *args)
        check("C8.refused-%s" % name, rc == 100 and not sbx.stublog(root) and rd(h + "/.config/kitty/current-theme.conf") == kit0 and not os.path.exists(h + "/.config/theme/backup"), (rc, out[:160], err[:160]))
    # a typo in targets.json cannot scribble outside the home
    root = sandbox()
    outside = os.path.join(root, "outside")
    os.makedirs(outside)
    write_targets(root, [{"name": "evil", "type": "file", "template": "kitty-current-theme.conf", "output": outside + "/x.conf"}])
    rc, out, _ = ctl(root, "apply")
    check("C12.output-outside-home-is-refused", "FAIL" in out and "outside HOME" in out and not os.path.exists(outside + "/x.conf"), out[:200])


# ===================================================================================================== C9 the commands

def c9():
    root = sandbox()
    h = home(root)
    st = lambda: json.load(open(h + "/.config/theme/state.json"))
    ctl(root, "set", "eva", "light")
    ctl(root, "toggle")
    a = st()
    ctl(root, "toggle")
    b = st()
    check("C9.toggle-flips-and-flips-back", a["mode"] == "dark" and b["mode"] == "light" and a["theme"] == "eva", (a, b))
    ctl(root, "set", "eva", "dark")
    check("C9.set-theme-and-mode", st() == {"theme": "eva", "mode": "dark"})
    check("C9.state-file-is-theme-qml-bytes", rd(h + "/.config/theme/state.json") == '{\n  "theme": "eva",\n  "mode": "dark"\n}\n')
    rc, out, _ = ctl(root, "apply")
    check("C9.apply-twice-changes-nothing", rc == 0 and "wrote" not in out and "set " not in out.replace("set eva", ""), out[:400])
    # next: one theme says so and does nothing (the repo ships two pairs since everbox: a tree of one, as a fresh user's copy of a single pair would be)
    tree1 = tempfile.mkdtemp(prefix="themectl_one_theme.")
    shutil.copytree(TREE + "/tools/theme", tree1 + "/tools/theme")
    shutil.copytree(TREE + "/tools/lib", tree1 + "/tools/lib")
    os.makedirs(tree1 + "/modules/common/theme")
    shutil.copy(TREE + "/modules/common/theme/Theme.qml", tree1 + "/modules/common/theme/Theme.qml")
    os.makedirs(tree1 + "/themes")
    shutil.copy(TREE + "/themes/eva.json", tree1 + "/themes/eva.json")

    def next_one():
        r = sbx.run(root, ["python3", tree1 + "/tools/theme/themectl", "next"])
        return r.returncode, r.stdout, r.stderr
    sbx.clear_stublog(root)
    before = tree_state(root)
    rc, out, _ = next_one()
    after = tree_state(root)
    check("C9.next-with-one-theme", rc == 0 and "only one theme (eva)" in out and not sbx.stublog(root) and after == before,
          (out, sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))))
    # with a second theme it moves on, and round again
    os.makedirs(h + "/.config/theme/themes", exist_ok=True)
    doc = json.load(open(REPO + "/themes/eva.json"))
    doc["name"] = "zeta"
    json.dump(doc, open(h + "/.config/theme/themes/zeta.json", "w"))
    next_one()
    a = st()
    next_one()
    b = st()
    shutil.rmtree(tree1, ignore_errors=True)
    check("C9.next-cycles-through-the-themes", a["theme"] == "zeta" and b["theme"] == "eva" and a["mode"] == b["mode"] == "dark", (a, b))
    check("C9.the-repos-theme-is-used-until-the-user-has-one", MOD_theme_source(root, "eva").startswith(TREE + "/themes"), MOD_theme_source(root, "eva"))
    mine = json.load(open(TREE + "/themes/eva.json"))
    mine["light"]["accent"] = "#010203"
    json.dump(mine, open(h + "/.config/theme/themes/eva.json", "w"))
    rc, out, _ = ctl(root, "resolve", "--theme", "eva", "--mode", "light")
    check("C9.the-users-theme-dir-wins-over-the-repo", MOD_theme_source(root, "eva").startswith(h + "/.config/theme/themes") and json.loads(out)["values"]["accent"] == [1, 2, 3, 255], out[:80])
    # diff writes nothing and runs no reload
    sbx.clear_stublog(root)
    before = tree_state(root)
    rc, out, _ = ctl(root, "diff", "eva", "light")
    check("C9.diff-writes-nothing", rc == 0 and tree_state(root) == before and not sbx.stublog(root) and "--- now:" in out and "would" in out, out[:200])
    rc, out, _ = ctl(root, "list")
    check("C9.list", rc == 0 and "theme    eva" in out and "target   kitty" in out)
    # install
    root = sandbox()
    h = home(root)
    th = h + "/.config/theme/themes/eva.json"
    rc, out, _ = ctl(root, "install", "--dry-run")
    check("C9.install-dry-run-writes-nothing", rc == 0 and not os.path.exists(th) and "would copy" in out, out)
    rc, out, _ = ctl(root, "install")
    check("C9.install-copies", rc == 0 and rd(th) == rd(TREE + "/themes/eva.json"), out)
    rc, out, _ = ctl(root, "install")
    check("C9.install-twice-says-same", "same as" in out, out)
    open(th, "a").write("\n")
    os.utime(th, (time.time() + 100, time.time() + 100))              # the user's copy is edited, hence newer
    rc, out, _ = ctl(root, "install")
    check("C9.install_newer", rc == 0 and rd(th) != rd(TREE + "/themes/eva.json") and rd(th).endswith("}\n\n") and "keep" in out, out)
    os.utime(th, (1, 1))                                               # an old, different copy: replaced, the old one is kept
    rc, out, _ = ctl(root, "install")
    man = jl(h + "/.config/theme/backup/manifest.json")
    check("C9.install-replaces-an-older-copy-and-keeps-it", rc == 0 and rd(th) == rd(TREE + "/themes/eva.json") and th in man, (out, list(man)))


def MOD_theme_source(root, name):
    with in_env(root):
        return MOD.theme_files(MOD.Paths())[name]


# =========================================================================================================== C10 the lock

def c10():
    root = sandbox()
    h = home(root)
    # a known state whatever the fixture holds: the case does not depend on the fixture's mode
    open(h + "/.config/theme/state.json", "w").write('{\n  "theme": "eva",\n  "mode": "light"\n}\n')
    # a slow reload keeps the first run busy; the lock file must be HELD while it works
    slow = root + "/bin/pkill"
    open(slow, "w").write("#!/bin/sh\nsleep 1.5\nexit 0\n")
    os.chmod(slow, 0o755)
    import fcntl
    env = sbx.env_of(root)
    p = subprocess.Popen(["python3", THEMECTL, "toggle"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    held = False
    t0 = time.time()
    lock = h + "/.config/theme/.lock"
    while time.time() - t0 < 6 and p.poll() is None:
        if os.path.exists(lock):
            fd = os.open(lock, os.O_RDWR)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(fd, fcntl.LOCK_UN)
            except BlockingIOError:
                held = True
            finally:
                os.close(fd)
            if held:
                break
        time.sleep(0.05)
    # and a second toggle started now waits for it, then flips back: two clicks are two toggles
    p2 = subprocess.Popen(["python3", THEMECTL, "toggle"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    o1, _ = p.communicate(timeout=30)
    o2, _ = p2.communicate(timeout=30)
    check("C10.lock-is-held-while-it-works", held)
    check("C10.two-clicks-are-two-toggles", json.load(open(h + "/.config/theme/state.json"))["mode"] == "light" and p.returncode == 0 and p2.returncode == 0, (o1[-120:], o2[-120:]))


# ===================================================================================================== C13 retries

def c13():
    root = sandbox()
    h = home(root)
    counter = root + "/daemon.count"
    stub = root + "/bin/awww"                    # any program that needs a daemon: the retry belongs to the `command` type, not to a program
    open(stub, "w").write('#!/bin/sh\nn=$(cat "%s" 2>/dev/null || echo 0)\nn=$((n+1))\necho $n > "%s"\n[ "$n" -ge "${AWWW_OK_AT:-3}" ] || { echo "daemon not running" >&2; exit 1; }\nexit 0\n' % (counter, counter))
    os.chmod(stub, 0o755)
    wp = {"name": "wallpaper", "type": "command", "argv": ["awww", "img", "x.png"], "retries": 4, "retryDelay": 0.01}
    write_targets(root, [wp])
    rc, out, _ = ctl(root, "set", "eva", "light")
    check("C13.command-retried-until-the-daemon-is-up", rc == 0 and "(try 3)" in out, out)
    open(counter, "w").write("0\n")
    wp["retries"] = 1
    write_targets(root, [wp])
    rc, out, _ = ctl(root, "set", "eva", "dark", extra={"AWWW_OK_AT": "99"})
    check("C13.command-fails-after-its-retries-and-says-why", rc == 1 and "FAIL" in out and "daemon not running" in out and rd(counter).strip() == "2", (rc, out, rd(counter)))


# =============================================================================================== C15 btop: a link, not a file

def c15():
    """btop's current.theme is a link to the stock theme of the mode, the one theme-switch.py pointed it at (the user, 2026-10-22:
    "ignore custom btop palettes for now"). The move of the link is what btop is told about, and only when it moved."""
    root = sandbox()
    h = home(root)
    link = h + "/.config/btop/themes/current.theme"
    sigs = lambda: [c for c in sbx.stublog(root) if c[0] == "pkill"]
    rc, out, _ = ctl(root, "set", "eva", "dark", "--only", "btop")
    check("C15.dark-links-the-dark-stock-theme", rc == 0 and os.path.islink(link) and os.readlink(link) == BTOP_STOCK["dark"], (rc, out[:200], os.readlink(link) if os.path.islink(link) else None))
    check("C15.what-btop-reads-through-the-link-is-the-stock-file", rd(link) is not None and rd(link) == rd(BTOP_STOCK["dark"]), rd(link))
    check("C15.a-moved-link-signals-btop-once", sigs() == [["pkill", "-USR2", "-x", "btop"]], sigs())
    rc, out, _ = ctl(root, "set", "eva", "dark", "--only", "btop")
    check("C15.an-unchanged-link-signals-nobody", rc == 0 and "unchanged" in out and len(sigs()) == 1, (out[:200], sigs()))
    rc, out, _ = ctl(root, "set", "eva", "light", "--only", "btop")
    check("C15.light-moves-the-link-back-and-signals-again", rc == 0 and os.readlink(link) == BTOP_STOCK["light"] and len(sigs()) == 2, (out[:200], sigs()))
    # a stock theme that is not there: a FAIL that says so, nothing linked, nobody signalled, nothing taken over
    root = sandbox()
    h = home(root)
    link = h + "/.config/btop/themes/current.theme"
    os.makedirs(h + "/.config/theme/themes", exist_ok=True)
    doc = jl(TREE + "/themes/eva.json")
    doc["assets"]["dark"]["btopTheme"] = "/usr/share/btop/themes/no-such-theme.theme"
    json.dump(doc, open(h + "/.config/theme/themes/eva.json", "w"))
    rc, out, _ = ctl(root, "set", "eva", "dark", "--only", "btop")
    ln = lines_of(out)["btop"]
    check("C15.a-missing-stock-theme-is-a-fail-and-links-nothing", rc == 1 and ln.startswith("FAIL") and "would dangle" in ln and not os.path.lexists(link) and not [c for c in sbx.stublog(root) if c[0] == "pkill"]
          and link not in jl(h + "/.config/theme/backup/manifest.json"), (rc, ln))
    # diff: says what it would do, does it not
    root = sandbox()
    sbx.clear_stublog(root)
    before = tree_state(root)
    rc, out, _ = ctl(root, "diff", "eva", "dark", "--only", "btop")
    check("C15.diff-links-nothing-and-signals-nobody", rc == 0 and tree_state(root) == before and not sbx.stublog(root) and "would link" in out and "would run: pkill -USR2 -x btop" in out and "current.theme (absent)" in out, out[:400])


# ============================================================================================ C16 migrate: the one-time edits

SIG = {"HYPRLAND_INSTANCE_SIGNATURE": "x"}                 # `doctor` wants a Hyprland session for the hyprland target; the sandbox has none
MIG_NAMES = ("hyprland", "btop", "fastfetch", "hyprlock")


def c16():
    """`themectl migrate`: the edits `doctor` asks for, made once, the originals kept, nothing else touched."""
    root = sandbox()
    h = home(root)
    f = {"hyprland": h + "/.config/hypr/hyprland.lua", "btop": h + "/.config/btop/btop.conf", "fastfetch": h + "/.config/fastfetch/config.jsonc"}
    lock, hv = h + "/.config/hypr/hyprlock.conf", h + "/.config/HyprV/hyprlock/evalight.conf"
    colours = h + "/.config/hypr/hyprlock-colors.conf"
    orig = {k: rd(p) for k, p in f.items()}
    modes = {k: os.stat(p).st_mode & 0o777 for k, p in f.items()}
    orig_link, hv_orig = os.readlink(lock), rd(hv)
    rc, out, _ = ctl(root, "doctor", extra=SIG)
    fl = [l for l in out.splitlines() if l.startswith("FAIL")]
    check("C16.doctor-asks-for-exactly-the-four-edits-first", {l.split()[1] for l in fl} == set(MIG_NAMES) and all("themectl migrate" in l for l in fl), (rc, fl))
    # --dry-run: the diff, no write
    before = tree_state(root)
    rc, out, _ = ctl(root, "migrate", "--dry-run")
    check("C16.dry-run-writes-nothing-and-shows-the-diff", rc == 0 and tree_state(root) == before and out.count("would:") == 4 and '+pcall(require, "config/theme")' in out
          and '+color_theme = "current"' in out and "archlogo_current.png" in out and "+source = ~/.config/hypr/hyprlock-colors.conf" in out, (rc, out[:300]))
    # the edits
    rc, out, _ = ctl(root, "migrate")
    ln = lines_of(out)
    check("C16.migrate-says-ok-for-each-edit-and-kitty-is-done-already", rc == 0 and all(ln.get(n, "").startswith("ok") and "already done" not in ln[n] for n in MIG_NAMES) and "already done" in ln.get("kitty", ""), (rc, out[:400]))
    lines = orig["hyprland"].splitlines(keepends=True)
    i = lines.index('require("config/appearance")\n')
    want = "".join(lines[:i + 1] + ['pcall(require, "config/theme")   -- themectl (guarded: a missing theme.lua is not an error)\n'] + lines[i + 1:])
    check("C16.hyprland-gets-the-guarded-include-right-after-appearance", rd(f["hyprland"]) == want, rd(f["hyprland"]))
    check("C16.btop-names-the-link-and-nothing-else-moves", rd(f["btop"]) == orig["btop"].replace('\ncolor_theme = "/usr/share/btop/themes/flat-remix-light.theme"', '\ncolor_theme = "current"'), rd(f["btop"]))
    check("C16.fastfetch-names-the-stable-link-and-the-commented-line-stays",
          rd(f["fastfetch"]) == orig["fastfetch"].replace('    "source": "~/.config/fastfetch/archlogo_evalight.png",', '    "source": "~/.config/fastfetch/archlogo_current.png",'), rd(f["fastfetch"]))
    body = rd(lock) or ""
    check("C16.hyprlock-becomes-a-file-with-the-source-line-and-the-body-and-hyprv-is-untouched",
          not os.path.islink(lock) and body.startswith("source = ~/.config/hypr/hyprlock-colors.conf\n") and not re.search(r"^\$(FIELD|BORDER|BACKGROUND|FOREGROUND|ACCENT|INCORRECT|CAPS)\s*=", body, re.M)
          and "input-field {" in body and "rgb($FIELD)" in body and "no_fade" not in body and rd(hv) == hv_orig, body[:200])
    check("C16.file-modes-are-kept", all(os.stat(p).st_mode & 0o777 == modes[k] for k, p in f.items()), modes)
    rc, out, _ = ctl(root, "doctor", extra=SIG)
    check("C16.doctor-has-nothing-left-to-ask", rc == 0 and not [l for l in out.splitlines() if l.startswith("FAIL")], out[-400:])
    man = jl(h + "/.config/theme/backup/manifest.json")
    check("C16.the-originals-are-kept-the-way-themectl-keeps-its-own",
          all(man.get(f[k], {}).get("kind") == "file" and rd(h + "/.config/theme/backup/" + man[f[k]]["backup"]) == orig[k] for k in f)
          and man.get(lock, {}).get("kind") == "symlink" and man[lock].get("link") == orig_link, man)
    # a second run
    before = tree_state(root)
    rc, out, _ = ctl(root, "migrate")
    check("C16.a-second-run-says-already-done-and-writes-nothing", rc == 0 and out.count("already done:") == 5 and "nothing to do" in out and tree_state(root) == before, (rc, out[:300]))
    # restore migrate: the edits, not the generated outputs
    ctl(root, "apply", "--only", "hyprlock")
    before = tree_state(root)
    rc, out, _ = ctl(root, "restore", "migrate", "--dry-run")
    check("C16.restore-migrate-dry-run-writes-nothing", rc == 0 and tree_state(root) == before and out.count("would put back") == 4, (rc, out[:300]))
    rc, out, _ = ctl(root, "restore", "migrate")
    man = jl(h + "/.config/theme/backup/manifest.json")
    check("C16.restore-migrate-puts-back-every-byte-and-the-link",
          rc == 0 and all(rd(f[k]) == orig[k] for k in f) and os.path.islink(lock) and os.readlink(lock) == orig_link and not any(p in man for p in list(f.values()) + [lock]), (rc, out[:300]))
    check("C16.restore-migrate-leaves-the-generated-outputs-owned", os.path.exists(colours) and colours in man, list(man))
    ctl(root, "migrate")
    rc, out, _ = ctl(root, "restore")
    check("C16.a-plain-restore-puts-back-the-edits-with-the-rest",
          rc == 0 and all(rd(f[k]) == orig[k] for k in f) and os.path.islink(lock) and os.readlink(lock) == orig_link and not os.path.lexists(colours), out[:300])

    # a pattern it needs is not where T.md says: refused (100), the other edits not made either, NOTHING written (no lock file even)
    def lacks(label, setup, needle):
        r = sandbox()
        setup(home(r))
        before = tree_state(r)
        rc, out, _ = ctl(r, "migrate")
        fl = [l for l in out.splitlines() if l.startswith("FAIL")]
        check("C16.refuses-%s" % label, rc == 100 and tree_state(r) == before and fl and needle in " ".join(fl) and "refused" in out and "nothing written" in out, (rc, out[:400]))
    hy = lambda hh: hh + "/.config/hypr/hyprland.lua"
    lacks("a-hyprland-lua-without-the-appearance-line", lambda hh: open(hy(hh), "w").write("require(\"config/autostart\")\n"), "require(\"config/appearance\")")
    lacks("a-hyprland-lua-with-two-appearance-lines", lambda hh: open(hy(hh), "a").write("require(\"config/appearance\")\n"), "2 require(\"config/appearance\")")
    lacks("a-missing-hyprland-lua", lambda hh: os.remove(hy(hh)), "missing")
    lacks("a-btop-conf-with-only-a-commented-color-theme", lambda hh: open(hh + "/.config/btop/btop.conf", "w").write("#color_theme = \"Default\"\n"), "color_theme")
    lacks("a-fastfetch-logo-that-is-not-an-archlogo", lambda hh: open(hh + "/.config/fastfetch/config.jsonc", "w").write("{ \"logo\": {\n  \"source\": \"~/pics/logo.png\"\n} }\n"), "archlogo")

    def no_body(hh):                                        # the link is intact (to evadark.conf), the body it needs is gone
        os.remove(hh + "/.config/hypr/hyprlock.conf")
        os.symlink(hh + "/.config/HyprV/hyprlock/evadark.conf", hh + "/.config/hypr/hyprlock.conf")
        os.remove(hh + "/.config/HyprV/hyprlock/evalight.conf")
    lacks("a-hyprlock-without-evalight-conf-to-take-the-body-from", no_body, "evalight.conf is missing")

    def six_vars(hh):
        p = hh + "/.config/HyprV/hyprlock/evalight.conf"
        keep = "".join(l for l in open(p) if not l.startswith("$CAPS"))
        open(p, "w").write(keep)
    lacks("an-evalight-conf-with-six-of-the-seven-variables", six_vars, "6 of the 7")

    def a_file(hh):
        os.remove(hh + "/.config/hypr/hyprlock.conf")
        open(hh + "/.config/hypr/hyprlock.conf", "w").write("general {\n}\n")
    lacks("a-hyprlock-conf-that-is-a-hand-edited-file", a_file, "not the symlink")

    def elsewhere(hh):
        os.remove(hh + "/.config/hypr/hyprlock.conf")
        os.makedirs(hh + "/elsewhere")
        open(hh + "/elsewhere/lock.conf", "w").write("$FIELD = 000000\n")
        os.symlink(hh + "/elsewhere/lock.conf", hh + "/.config/hypr/hyprlock.conf")
    lacks("a-hyprlock-conf-that-links-outside-hyprv", elsewhere, "not into")
    # the link may name the DARK file (the desktop is in dark mode when the user migrates): the body is evalight's all the same, so the result is the light one's
    r = sandbox()
    hh = home(r)
    os.remove(hh + "/.config/hypr/hyprlock.conf")
    os.symlink(hh + "/.config/HyprV/hyprlock/evadark.conf", hh + "/.config/hypr/hyprlock.conf")
    rc, out, _ = ctl(r, "migrate")
    check("C16.a-hyprlock-linked-to-the-dark-file-gets-the-light-body-without-its-invalid-options",
          rc == 0 and rd(hh + "/.config/hypr/hyprlock.conf") == body and "no_fade" not in (rd(hh + "/.config/hypr/hyprlock.conf") or ""), (rc, out[:300]))
    # an include file outside HOME (a typo in targets.json) is never edited
    r = sandbox()
    outd = r + "/outside"
    os.makedirs(outd)
    open(outd + "/btop.conf", "w").write('color_theme = "x"\n')
    write_targets(r, [{"name": "btop", "type": "link", "needs": ["btopTheme"], "output": "${XDG_CONFIG_HOME}/btop/themes/current.theme", "target": "{{assets.btopTheme}}",
                       "include": {"file": outd + "/btop.conf", "pattern": "^\\s*color_theme\\s*=\\s*\"current\"\\s*$", "line": 'color_theme = "current"'}}])
    rc, out, _ = ctl(r, "migrate")
    check("C16.an-include-file-outside-home-is-refused", rc == 100 and rd(outd + "/btop.conf") == 'color_theme = "x"\n' and "outside HOME" in out, (rc, out[:300]))
    # an original that cannot be kept stops that write (C7's rule): the three files stay as they were, three FAILs
    r = sandbox()
    hh = home(r)
    os.makedirs(hh + "/.config/theme/backup", exist_ok=True)
    open(hh + "/.config/theme/backup/files", "w").write("not a directory\n")          # backup/files cannot be created
    fp = {k: hh + p for k, p in (("hyprland", "/.config/hypr/hyprland.lua"), ("btop", "/.config/btop/btop.conf"), ("fastfetch", "/.config/fastfetch/config.jsonc"))}
    o2 = {k: rd(p) for k, p in fp.items()}
    rc, out, _ = ctl(r, "migrate")
    ln = lines_of(out)
    check("C16.no-backup-no-write", rc == 3 and all(ln[k].startswith("FAIL") and "cannot keep the original" in ln[k] and rd(fp[k]) == o2[k] for k in fp), (rc, out[:400]))
    # a config that is a symlink (a dotfiles repo): the link is replaced by the edited file, the link's target is not written, restore puts the link back
    r = sandbox()
    hh = home(r)
    bt, real = hh + "/.config/btop/btop.conf", hh + "/dotfiles/btop.conf"
    os.makedirs(hh + "/dotfiles")
    shutil.move(bt, real)
    os.symlink(real, bt)
    mine = rd(real)
    rc, out, _ = ctl(r, "migrate")
    check("C16.a-symlinked-config-becomes-a-file-and-its-target-is-left-alone", rc == 0 and not os.path.islink(bt) and 'color_theme = "current"' in (rd(bt) or "") and rd(real) == mine, (rc, out[:300]))
    rc, out, _ = ctl(r, "restore", "migrate")
    check("C16.and-restore-puts-the-link-back", rc == 0 and os.path.islink(bt) and os.readlink(bt) == real and rd(bt) == mine, (rc, out[:300]))
    # kitty is the one target whose include the fixture already has; a kitty.conf without it gets it, last, and restore takes it away
    r = sandbox()
    kit = home(r) + "/.config/kitty/kitty.conf"
    open(kit, "w").write("font_size 12")                                                # no include, no final newline
    rc, out, _ = ctl(r, "migrate")
    ok1 = rc == 0 and rd(kit) == "font_size 12\ninclude current-theme.conf\n"
    ctl(r, "restore", "migrate")
    check("C16.a-kitty-conf-without-the-include-gets-it-appended-and-restore-removes-it", ok1 and rd(kit) == "font_size 12", (rc, rd(kit)))


# ====================================================================================== C17 the desktop after the switch-over

# What the manifest of the user's own home held after their switch-over (2026-10-22), path (below HOME) -> kind. The one-liner
# `themectl install && migrate && apply` (18:48, light) kept these ten; the first toggle (18:51) kept the eleventh, the old script's state
# file, whose bytes are themectl's own in light mode and differ only in dark. The fixture desktop must keep the same, at the same moments.
ONE_LINER_KEPT = {
    ".config/btop/btop.conf": "file", ".config/btop/themes/current.theme": "absent", ".config/fastfetch/archlogo_current.png": "absent",
    ".config/fastfetch/config.jsonc": "file", ".config/hypr/config/theme.lua": "absent", ".config/hypr/hyprland.lua": "file",
    ".config/hypr/hyprlock-colors.conf": "absent", ".config/hypr/hyprlock.conf": "symlink", ".config/kitty/current-theme.conf": "file",
    ".config/starship.toml": "symlink", ".config/gtk-4.0/gtk.css": "absent",
}
# Since 2026-11-07 the one-liner's `install` also puts the repo's btop themes and fastfetch logos in those apps' directories, each one
# owned (kept as absent): `restore` takes them away again. The old script's state file is no target any more, so the first toggle keeps
# nothing new. Since 2026-11-08 the libadwaita target owns ~/.config/gtk-4.0/gtk.css (absent in the fixture desktop).


def one_liner_kept():
    out = dict(ONE_LINER_KEPT)
    for d, rel in (("btop", ".config/btop/themes/"), ("fastfetch", ".config/fastfetch/")):
        for n in os.listdir(os.path.join(TREE, "tools/theme", d)):
            out[rel + n] = "absent"
    return out


def c17():
    """The shape the user's real home is in now: what the one-liner kept, what a further apply does there, what the first toggle adds, and the
    way back."""
    before = content_state(sandbox("pre"))
    root = sandbox("post")
    h = home(root)
    kept = lambda: {os.path.relpath(p, h): e.get("kind") for p, e in jl(h + "/.config/theme/backup/manifest.json").items()}

    def differ(got, want):
        return (sorted(set(got) ^ set(want)), [k for k in got if k in want and got[k] != want[k]])
    want = one_liner_kept()
    check("C17.the-one-liner-keeps-the-originals-the-real-one-kept", kept() == want, differ(kept(), want))
    # a further apply in the same mode: nothing is written, nobody is signalled
    sbx.clear_stublog(root)
    tree0 = tree_state(root)
    rc, out, _ = ctl(root, "apply")
    tree1 = tree_state(root)
    check("C17.a-further-apply-writes-nothing-and-signals-nobody",
          rc == 0 and tree1 == tree0 and not re.search(r"\b(wrote|linked|set) ", out) and not [c for c in sbx.stublog(root) if c[0] == "pkill"],
          (rc, sorted(k for k in set(tree0) | set(tree1) if tree0.get(k) != tree1.get(k)), [l for l in out.splitlines() if re.search(r"\b(wrote|linked|set) ", l)], sbx.stublog(root)))
    # the first toggle writes only files the one-liner already owns: nothing more is kept
    rc, out, _ = ctl(root, "toggle")
    check("C17.the-first-toggle-keeps-nothing-more", rc == 0 and kept() == want, (rc, differ(kept(), want), out[:200]))
    ctl(root, "toggle")
    # the way back: the desktop as it was before, every byte, every link, nothing left behind
    rc, out, _ = ctl(root, "restore")
    after = content_state(root)
    check("C17.restore-undoes-the-whole-switch-over", rc == 0 and before and after == before,        # `before`: two empty states are not a desktop
          (rc, sorted(set(after) ^ set(before))[:6], [k for k in before if k in after and before[k] != after[k]][:6], out[:200]))


# ============================================================================================ C21 every pair on disk, C22 shipped files

PROGRAM_TOKENS = ("hyprBorderActive", "hyprBorderInactive", "hyprBorderLocked", "hyprGroupTab", "lockBorder", "lockIncorrect",
                  "starshipRamp0", "starshipRamp1", "starshipRamp2", "starshipRamp3")
USER_LOGOS = ("archlogo_evalight.png", "archlogo_evadark.png", "archlogo_everforest.png", "archlogo_gruvbox.png")   # in the user's own fastfetch dir
BTOP_KEYS = ("main_bg main_fg title hi_fg selected_bg selected_fg inactive_fg graph_text meter_bg proc_misc cpu_box mem_box net_box proc_box div_line "
             "temp_start temp_mid temp_end cpu_start cpu_mid cpu_end free_start free_mid free_end cached_start cached_mid cached_end available_start "
             "available_mid available_end used_start used_mid used_end download_start download_mid download_end upload_start upload_mid upload_end "
             "process_start process_mid process_end").split()


def _pairgen():
    loader = importlib.machinery.SourceFileLoader("pairgen_under_test", TREE + "/tools/theme/pairgen.py")
    spec = importlib.util.spec_from_loader("pairgen_under_test", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def _vscode_themes():
    """The theme names VS Code knows here (its built-ins and the user's extensions), or None when no VS Code is installed. Read only."""
    names, found = set(), False
    for d in (os.path.expanduser("~/.vscode/extensions"), "/usr/share/code/resources/app/extensions", "/opt/visual-studio-code/resources/app/extensions"):
        if not os.path.isdir(d):
            continue
        found = True
        for e in os.listdir(d):
            pj = jl(os.path.join(d, e, "package.json"))
            for th in (pj.get("contributes") or {}).get("themes") or []:
                names.add(th.get("id") or th.get("label"))
    return names if found else None


def c21():
    """Every theme on disk, both modes, held to what makes a pair: every token it needs, legible muted text, a group tab and a locked tab that
    stand apart from the border, assets that exist on this machine or in the repo, and a clean apply and doctor in a sandbox desktop."""
    pg = _pairgen()
    names = sorted(n[:-5] for n in os.listdir(TREE + "/themes") if n.endswith(".json"))
    vsc = _vscode_themes()
    root = sandbox("post")
    h = home(root)
    for n in USER_LOGOS:                                    # the user's own logos (empty stand-ins: a link only needs the file to exist)
        if not os.path.exists(h + "/.config/fastfetch/" + n):
            open(h + "/.config/fastfetch/" + n, "w").close()
    # What a pair falls back to is what the machine it was made on has installed. A machine with fewer than half of the GTK fallbacks is another
    # one (the desktop, 2026-11-22: 2 of 16): the installed names are not judged there, `themectl doctor` says what is missing.
    gtk_dirs = ("/usr/share/themes", os.path.expanduser("~/.themes"), os.path.expanduser("~/.local/share/themes"))
    def gtk_there(v):
        v = v[-1] if isinstance(v, list) and v else v
        return any(os.path.isdir(d + "/" + str(v)) for d in gtk_dirs)
    there = [gtk_there(((jl(TREE + "/themes/%s.json" % n).get("assets") or {}).get(m) or {}).get("gtkTheme", "-")) for n in names for m in MOD.MODES]
    own = 2 * sum(there) >= len(there)
    if not own:
        print("note C21: %d of %d GTK fallbacks are installed here, so this is not the machine they were chosen on: the installed names are not judged" % (sum(there), len(there)))
    for name in names:
        doc = jl(TREE + "/themes/%s.json" % name)
        with in_env(root):
            P = MOD.Paths()
            th = MOD.load_theme(P, name, TREE + "/themes/%s.json" % name)
            options, targets, _ = MOD.load_targets(P)
        l0 = set(th.l0)
        for mode in MOD.MODES:
            block = doc.get(mode) or {}
            missing = sorted((l0 | set(PROGRAM_TOKENS)) - set(block))
            values, errors = th.mode_values(mode)
            check("C21.%s.%s.every-token-written-and-resolved" % (name, mode), not missing and not errors, (missing[:6], list(errors.items())[:3]))
            col = {k: tuple(x / 255 for x in v[:3]) for k, v in values.items() if isinstance(v, list)}
            mc = pg.contrast(col["textMuted"], col["surface"])
            check("C21.%s.%s.muted-text-reads" % (name, mode), mc >= 4.5, "textMuted %.2f:1 on the surface" % mc)
            tab, act, lock = (pg.de2000(col["hyprGroupTab"], col["hyprBorderActive"]), pg.de2000(col["hyprBorderLocked"], col["hyprBorderActive"]),
                              pg.de2000(col["hyprBorderLocked"], col["hyprGroupTab"]))
            check("C21.%s.%s.the-group-tabs-stand-apart-from-the-border" % (name, mode), tab >= 25 and act >= 20 and lock >= 20,
                  "CIEDE2000 tab/border %.1f (>= 25), locked/border %.1f (>= 20), locked/tab %.1f (>= 20)" % (tab, act, lock))
            a = (doc.get("assets") or {}).get(mode) or {}
            gtk_ok = not own or gtk_there(a.get("gtkTheme", "-"))   # a list ends with the fallback: that one must exist; the preferred ones may be missing
            icon_ok = os.path.isdir("/usr/share/icons/" + a.get("iconTheme", "-"))
            bt = a.get("btopTheme", "")
            bt_file = bt if os.path.isabs(bt) else TREE + "/tools/theme/btop/" + bt
            logo = a.get("fastfetchLogo", "")
            logo_ok = logo in USER_LOGOS or os.path.isfile(TREE + "/tools/theme/fastfetch/" + logo)
            vs_last = a.get("vscodeTheme")                     # a list ends with the fallback: that one must be installed
            vs_last = vs_last[-1] if isinstance(vs_last, list) and vs_last else vs_last
            vs_ok = not own or vsc is None or vs_last in vsc
            check("C21.%s.%s.assets-exist" % (name, mode), gtk_ok and icon_ok and os.path.isfile(bt_file) and logo_ok and vs_ok,
                  {"gtk": gtk_ok, "icons": icon_ok, "btop": bt_file if not os.path.isfile(bt_file) else True, "logo": logo_ok, "vscode": vs_ok})
            if not os.path.isabs(bt):
                kv = dict(re.findall(r'^theme\[(\w+)\]="(#[0-9A-Fa-f]{6}|)"$', rd(bt_file) or "", re.M))
                check("C21.%s.%s.its-btop-theme-has-every-key" % (name, mode), sorted(kv) == sorted(BTOP_KEYS) and kv.get("main_bg") and kv.get("main_fg"),
                      sorted(set(BTOP_KEYS) ^ set(kv))[:6])
            rc, out, _ = ctl(root, "set", name, mode)
            ls = lines_of(out)
            link = h + "/.config/btop/themes/current.theme"
            linked = os.path.realpath(link)
            want = bt if os.path.isabs(bt) else h + "/.config/btop/themes/" + bt
            check("C21.%s.%s.applies-with-every-target-ok" % (name, mode), rc == 0 and len(ls) == n_targets() and all(l.startswith("ok") for l in ls.values())
                  and linked == os.path.realpath(want) and rd(link) == rd(bt_file), (rc, [l for l in ls.values() if not l.startswith("ok")][:3], linked))
            rc, out, _ = ctl(root, "doctor", extra=SIG)
            check("C21.%s.%s.doctor-says-ok" % (name, mode), rc == 0 and "FAIL" not in out, [l for l in out.splitlines() if l.startswith("FAIL")][:3])


def c22():
    """A link target's shipped files (btop's custom themes, the logos): copied next to the link when first used and owned, so that restore takes
    them away; a copy that is there is the user's and is used as it is; `install` refreshes an older one and keeps a newer one."""
    custom = next(n for n in sorted(os.listdir(TREE + "/themes")) if n.endswith(".json")
                  and "/" not in (jl(TREE + "/themes/" + n).get("assets", {}).get("dark", {}).get("btopTheme") or "/"))
    name = custom[:-5]
    bt = jl(TREE + "/themes/" + custom)["assets"]["dark"]["btopTheme"]
    src = TREE + "/tools/theme/btop/" + bt
    root = sandbox()
    h = home(root)
    copy = h + "/.config/btop/themes/" + bt
    link = h + "/.config/btop/themes/current.theme"
    before = tree_state(root)
    rc, out, _ = ctl(root, "diff", name, "dark", "--only", "btop")
    check("C22.diff-names-the-install-and-writes-nothing", rc == 0 and tree_state(root) == before and "would install " + copy in out, out[:300])
    rc, out, _ = ctl(root, "set", name, "dark", "--only", "btop")
    man = jl(h + "/.config/theme/backup/manifest.json")
    check("C22.first-use-copies-the-shipped-theme-owns-it-and-links-it", rc == 0 and rd(copy) == rd(src) and os.readlink(link) == bt
          and man.get(copy, {}).get("kind") == "absent" and "installed " + copy in out, (rc, out[:300], man.get(copy)))
    open(copy, "a").write("# mine\n")
    rc, out, _ = ctl(root, "set", name, "light", "--only", "btop")
    rc, out, _ = ctl(root, "set", name, "dark", "--only", "btop")
    check("C22.a-copy-that-is-there-is-used-as-it-is", rc == 0 and rd(copy).endswith("# mine\n") and os.readlink(link) == bt, (rc, out[:200]))
    os.utime(copy, (time.time() + 100, time.time() + 100))
    rc, out, _ = ctl(root, "install")
    check("C22.install-keeps-a-newer-copy", rc == 0 and rd(copy).endswith("# mine\n") and "keep " + copy in out, out[-300:])
    os.utime(copy, (1, 1))
    rc, out, _ = ctl(root, "install")
    check("C22.install-refreshes-an-older-copy", rc == 0 and rd(copy) == rd(src), out[-300:])
    logo = h + "/.config/fastfetch/" + jl(TREE + "/themes/" + custom)["assets"]["light"]["fastfetchLogo"]
    check("C22.install-puts-the-logos-in-fastfetchs-directory", os.path.isfile(logo) and open(logo, "rb").read()[:8] == b"\x89PNG\r\n\x1a\n", logo)
    rc, out, _ = ctl(root, "restore", "btop")
    check("C22.restore-btop-takes-the-copies-away-and-the-link", rc == 0 and not os.path.lexists(copy) and not os.path.lexists(link)
          and not [p for p in jl(h + "/.config/theme/backup/manifest.json") if p.startswith(h + "/.config/btop/")], out[:300])
    # a bare name the repo does not ship: a FAIL that says so, nothing linked
    os.makedirs(h + "/.config/theme/themes", exist_ok=True)
    doc = jl(TREE + "/themes/" + custom)
    doc["assets"]["dark"]["btopTheme"] = "no-such.theme"
    json.dump(doc, open(h + "/.config/theme/themes/" + custom, "w"))
    rc, out, _ = ctl(root, "set", name, "dark", "--only", "btop")
    ln = lines_of(out).get("btop", "")
    check("C22.a-bare-name-nobody-ships-is-a-fail", rc == 1 and ln.startswith("FAIL") and "ships no no-such.theme" in ln and not os.path.lexists(link), ln)


# ================================================================================================== C18 VS Code's theme

def c18():
    """The `vscode` target (R3, "Vscode does not change"): `workbench.colorTheme` follows the mode, by an edit of the settings.json TEXT --
    the file has comments, a trailing comma and a same-named key inside another object, and none of that may move -- and nothing about
    the file is kept for `restore`."""
    root = sandbox()
    h = home(root)
    sj = h + "/.config/Code/User/settings.json"
    orig = rd(sj)
    check("C18.the-fixture-is-the-shape-it-claims", orig is not None and '  "workbench.colorTheme": "Eva Light Bold",' in orig and "// \"workbench.colorTheme\": \"Gruvbox Dark Medium\"," in orig, orig)
    dark = orig.replace('  "workbench.colorTheme": "Eva Light Bold",', '  "workbench.colorTheme": "Eva Dark Bold",')
    rc, out, _ = ctl(root, "set", "eva", "dark", "--only", "vscode")
    check("C18.dark-sets-the-line-and-only-the-line", rc == 0 and rd(sj) == dark and "ok    vscode" in out, (rc, out[:300], rd(sj)))
    m0 = os.stat(sj).st_mtime_ns
    time.sleep(0.02)
    rc, out, _ = ctl(root, "set", "eva", "dark", "--only", "vscode")
    check("C18.the-same-mode-again-writes-nothing", rc == 0 and os.stat(sj).st_mtime_ns == m0 and "unchanged" in out, (rc, out[:200]))
    rc, out, _ = ctl(root, "set", "eva", "light", "--only", "vscode")
    check("C18.light-puts-the-file-back-byte-for-byte", rc == 0 and rd(sj) == orig, (rc, out[:200]))
    # nothing kept: the user's long-lived file is not what `restore` puts back
    check("C18.the-file-is-not-kept-for-restore", sj not in jl(h + "/.config/theme/backup/manifest.json"), jl(h + "/.config/theme/backup/manifest.json").keys())
    rc, out, _ = ctl(root, "set", "eva", "dark", "--only", "vscode")
    rc2, out2, _ = ctl(root, "restore", "vscode")
    check("C18.restore-leaves-it-alone", rc2 == 0 and rd(sj) == dark, (rc2, out2[:200]))
    # --dry-run says what it would do and writes nothing
    rc, out, _ = ctl(root, "diff", "eva", "light", "--only", "vscode")
    check("C18.diff-shows-the-change-and-writes-nothing", rc == 0 and rd(sj) == dark and "would set" in out and 'Eva Light Bold' in out, (rc, out[:400]))
    # permission bits and a symlinked file: written through, the link stays
    root = sandbox()
    h = home(root)
    sj = h + "/.config/Code/User/settings.json"
    os.chmod(sj, 0o600)
    rc, out, _ = ctl(root, "set", "eva", "dark", "--only", "vscode")
    check("C18.the-files-permission-bits-stay", rc == 0 and (os.stat(sj).st_mode & 0o777) == 0o600, oct(os.stat(sj).st_mode))
    root = sandbox()
    h = home(root)
    sj = h + "/.config/Code/User/settings.json"
    os.makedirs(h + "/dotfiles", exist_ok=True)
    os.replace(sj, h + "/dotfiles/vscode-settings.json")
    os.symlink(h + "/dotfiles/vscode-settings.json", sj)
    rc, out, _ = ctl(root, "set", "eva", "dark", "--only", "vscode")
    check("C18.a-symlinked-settings-file-is-written-through-and-stays-a-link",
          rc == 0 and os.path.islink(sj) and '"Eva Dark Bold"' in rd(h + "/dotfiles/vscode-settings.json"), (rc, out[:200], os.path.islink(sj)))
    # a key that is not there is added, a nested key of the same name is left alone, comments stay
    root = sandbox()
    h = home(root)
    sj = h + "/.config/Code/User/settings.json"
    open(sj, "w").write('{\n  // mine\n  "editor.fontSize": 14,\n  "other": { "workbench.colorTheme": "nested" },\n}\n')
    rc, out, _ = ctl(root, "set", "eva", "dark", "--only", "vscode")
    check("C18.a-missing-key-is-added-first-and-a-nested-one-is-not-the-key",
          rc == 0 and rd(sj) == '{\n  "workbench.colorTheme": "Eva Dark Bold",\n  // mine\n  "editor.fontSize": 14,\n  "other": { "workbench.colorTheme": "nested" },\n}\n', rd(sj))
    # no file at all: no failure, nothing created
    root = sandbox()
    h = home(root)
    os.remove(h + "/.config/Code/User/settings.json")
    rc, out, _ = ctl(root, "set", "eva", "dark", "--only", "vscode")
    check("C18.no-settings-file-is-no-failure-and-none-is-made", rc == 0 and "skipped" in out and not os.path.exists(h + "/.config/Code/User/settings.json"), (rc, out[:300]))
    # a file that is not a JSON object, or whose key is not a string: a FAIL that says so, nothing written
    for name, text in (("an-array", "[1, 2]\n"), ("a-null-key", '{ "workbench.colorTheme": null }\n'), ("a-broken-file", '{ "a": \n')):
        root = sandbox()
        h = home(root)
        sj = h + "/.config/Code/User/settings.json"
        open(sj, "w").write(text)
        rc, out, _ = ctl(root, "set", "eva", "dark", "--only", "vscode")
        check("C18.%s-is-a-fail-and-the-file-is-untouched" % name, rc == 1 and "FAIL  vscode" in out and "nothing written" in out and rd(sj) == text, (rc, out[:300]))
    # the real shape of the user's file: a comment in a string-less line, a trailing comma, an apostrophe in a value
    root = sandbox()
    h = home(root)
    sj = h + "/.config/Code/User/settings.json"
    real = '{\n  "editor.fontFamily": "Consolas, \'Courier New\', monospace",\n  "files.exclude": {\n    "**/hideme": true,\n  },\n  /* block\n     comment */ "workbench.colorTheme": "Eva Dark", // trailing\n}\n'
    open(sj, "w").write(real)
    rc, out, _ = ctl(root, "set", "eva", "light", "--only", "vscode")
    check("C18.the-users-shape-comments-trailing-commas-and-all", rc == 0 and rd(sj) == real.replace('"Eva Dark"', '"Eva Light Bold"'), (rc, rd(sj)))


# ====================================================================================== C14 the sandbox's own guards

def c14():
    """The proof that nothing outside the sandbox moved must be able to fail, and the sandbox must refuse the real config."""
    d = os.path.join(WORK, "outside_proof")
    os.makedirs(d + "/watched")
    open(d + "/watched/a.conf", "w").write("one\n")
    open(d + "/watched/b.conf", "w").write("two\n")
    os.symlink("a.conf", d + "/watched/link")
    saved = (sbx.REAL_HOME, sbx.WATCH)
    try:
        sbx.REAL_HOME, sbx.WATCH = d, ["watched", "absent"]
        m0 = sbx.manifest()
        check("C14.an-untouched-tree-compares-clean", sbx.compare(m0, sbx.manifest()) == [])
        os.utime(d + "/watched/a.conf", (1, 1))
        moved = sbx.compare(m0, sbx.manifest())
        check("C14.a-touched-mtime-is-seen", any(p == "watched/a.conf" for p, _ in moved), moved)
        m0 = sbx.manifest()
        st = os.stat(d + "/watched/b.conf")
        open(d + "/watched/b.conf", "w").write("TWO\n")                    # same size, other bytes, the old mtime put back
        os.utime(d + "/watched/b.conf", ns=(st.st_atime_ns, st.st_mtime_ns))
        moved = sbx.compare(m0, sbx.manifest())
        check("C14.same-size-same-mtime-new-bytes-is-seen-by-the-hash", any(p == "watched/b.conf" and "sha1" in w for p, w in moved), moved)
        m0 = sbx.manifest()
        os.remove(d + "/watched/link")
        os.symlink("b.conf", d + "/watched/link")
        moved = sbx.compare(m0, sbx.manifest())
        check("C14.a-re-pointed-link-is-seen", any(p == "watched/link" and "link" in w for p, w in moved), moved)
        m0 = sbx.manifest()
        open(d + "/watched/new.conf", "w").write("x")
        os.mkdir(d + "/absent")
        moved = sbx.compare(m0, sbx.manifest())
        check("C14.a-new-file-and-a-new-watched-path-are-seen", any(p == "watched/new.conf" and w == "appeared" for p, w in moved) and any(p == "absent" for p, _ in moved), moved)
    finally:
        sbx.REAL_HOME, sbx.WATCH = saved
    refused = False
    try:
        sbx.make(os.path.join(sbx.REAL_HOME, ".config", "themectl-never-built-here"))
    except RuntimeError:
        refused = True
    check("C14.the-sandbox-refuses-to-be-built-in-the-real-config", refused and not os.path.exists(os.path.join(sbx.REAL_HOME, ".config", "themectl-never-built-here")))
    env = sbx.env_of(os.path.join(WORK, "x"))
    check("C14.the-sandbox-environment-has-no-desktop-in-it", all(k not in env for k in ("WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "XDG_RUNTIME_DIR", "DISPLAY")) and env["GSETTINGS_BACKEND"] == "keyfile" and env["PATH"].split(":")[0].endswith("/bin") and ".local/bin" not in env["PATH"])


# ======================================================================== C19 wallpaper (hyprpaper) and the icon theme (gsettings + settings.ini)

def c19():
    """The wallpaper is shell.jsonc's (`theme.wallpapers.<theme>.<mode>`), set through hyprpaper (0.8+: hyprctl hyprpaper wallpaper); the HyprV
    directory and the theme file's `assets.<mode>.wallpaper` are not read any more. The icon theme is written to gsettings AND to GTK 3's and
    GTK 4's settings.ini, Papirus-Light / Papirus-Dark by mode. Stubs prove the REQUEST, not the real program's answer."""
    def pics(root):
        d = home(root) + "/Pictures"
        os.makedirs(d, exist_ok=True)
        for n in ("light.png", "dark.png"):
            open(d + "/" + n, "w").write("x")
        return d

    def wp_calls(root):
        return ["\t".join(c) for c in sbx.stublog(root) if c[:3] == ["hyprctl", "hyprpaper", "wallpaper"]]
    # the request: both modes, ~ expanded, the file hyprpaper reads at its start
    root = sandbox()
    d = pics(root)
    put_shell(root, '''{
        // the user's file has comments
        "theme": { "apply": "themectl", "wallpapers": { "eva": { "light": "~/Pictures/light.png", "dark": "~/Pictures/dark.png" } } }
    }''')
    rc, out, _ = ctl(root, "set", "eva", "dark")
    ln = lines_of(out)["wallpaper"]
    conf = rd(home(root) + "/.config/hypr/hyprpaper.conf") or ""
    check("C19.dark-tells-hyprpaper-the-dark-file", rc == 0 and ln.startswith("ok") and wp_calls(root) == ["hyprctl\thyprpaper\twallpaper\t,%s/dark.png,cover" % d], (ln, wp_calls(root)))
    check("C19.the-file-hyprpaper-reads-at-its-start-has-it-too", "path = %s/dark.png" % d in conf and "fit_mode = cover" in conf and "monitor =" in conf and "splash = false" in conf, conf)
    rc, out, _ = ctl(root, "set", "eva", "light")
    conf2 = rd(home(root) + "/.config/hypr/hyprpaper.conf") or ""
    check("C19.light-follows", rc == 0 and wp_calls(root)[-1].endswith(",%s/light.png,cover" % d) and "light.png" in conf2 and "dark.png" not in conf2, (wp_calls(root), conf2))
    rc, out, _ = ctl(root, "set", "eva", "light")
    check("C19.the-same-mode-again-writes-nothing-but-still-asks-the-daemon", "unchanged" in lines_of(out)["wallpaper"] and len(wp_calls(root)) == 3, (lines_of(out)["wallpaper"], len(wp_calls(root))))
    rc, out, _ = ctl(root, "diff", "eva", "dark")
    check("C19.diff-runs-nothing", len(wp_calls(root)) == 3 and "would run" in out and "hyprpaper" in out, out[-300:])
    # THE NAMED MONITORS (2026-11-11): hyprpaper 0.8.5 lets a picture set for a NAMED monitor beat the fallback until it restarts and ignores the
    # fallback request with exit 0 (the real daemon: tools/dev/themectl_hyprpaper_env_probe.sh; the stub models it). A switch reads the screen
    # back and names only a monitor that kept another picture; one that takes nothing is a FAIL that names it.
    root = sandbox()
    d = pics(root)
    open(d + "/stray.png", "w").write("x")
    put_shell(root, '{ "theme": { "wallpapers": { "eva": { "light": "~/Pictures/light.png", "dark": "~/Pictures/dark.png" } } } }')
    ctl(root, "set", "eva", "light", "--only", "wallpaper")
    check("C19.a-plain-switch-names-no-monitor", wp_calls(root) == ["hyprctl\thyprpaper\twallpaper\t,%s/light.png,cover" % d] and _hp_shown(root) == "eDP-1: %s/light.png" % d,
          (wp_calls(root), _hp_shown(root)))
    _hp_seed(root, [("*", d + "/light.png"), ("eDP-1", d + "/stray.png")])
    rc, out, _ = ctl(root, "set", "eva", "dark", "--only", "wallpaper")
    ln = lines_of(out)["wallpaper"]
    check("C19.a-named-picture-left-by-anything-is-overridden-by-the-next-switch", rc == 0 and ln.startswith("ok") and _hp_shown(root) == "eDP-1: %s/dark.png" % d
          and wp_calls(root)[-2:] == ["hyprctl\thyprpaper\twallpaper\t,%s/dark.png,cover" % d, "hyprctl\thyprpaper\twallpaper\teDP-1,%s/dark.png,cover" % d],
          (ln, wp_calls(root), _hp_shown(root)))
    two = {"STUB_HYPRPAPER_MONITORS": "eDP-1 HDMI-A-1"}
    _hp_seed(root, [("*", d + "/dark.png"), ("HDMI-A-1", d + "/stray.png")])
    n0 = len(wp_calls(root))
    rc, out, _ = ctl(root, "set", "eva", "light", "--only", "wallpaper", extra=two)
    check("C19.only-the-monitor-that-kept-another-picture-is-named", rc == 0 and _hp_shown(root, **two) == "eDP-1: %s/light.png\nHDMI-A-1: %s/light.png" % (d, d)
          and wp_calls(root)[n0:] == ["hyprctl\thyprpaper\twallpaper\t,%s/light.png,cover" % d, "hyprctl\thyprpaper\twallpaper\tHDMI-A-1,%s/light.png,cover" % d],
          (wp_calls(root)[n0:], _hp_shown(root, **two)))
    _hp_seed(root, [("*", d + "/light.png"), ("eDP-1", d + "/stray.png")])
    rc, out, _ = ctl(root, "set", "eva", "dark", "--only", "wallpaper", extra={"STUB_HYPRPAPER_STUCK": "eDP-1"})
    ln = lines_of(out)["wallpaper"]
    check("C19.a-monitor-that-takes-nothing-is-a-fail-that-names-it", rc == 1 and ln.startswith("FAIL") and "did not take dark.png" in ln and "eDP-1 (shows stray.png)" in ln, ln)
    # no wallpaper for the theme and mode: skipped, nothing asked, nothing written
    root = sandbox()
    pics(root)
    put_shell(root, '{ "theme": { "wallpapers": { "eva": { "light": "~/Pictures/light.png" } } } }')
    rc, out, _ = ctl(root, "set", "eva", "dark")
    check("C19.no-wallpaper-for-this-mode-is-skipped", rc == 0 and "skipped" in lines_of(out)["wallpaper"] and not wp_calls(root) and not os.path.exists(home(root) + "/.config/hypr/hyprpaper.conf"), (out[-200:], wp_calls(root)))
    root = sandbox()
    rc, out, _ = ctl(root, "set", "eva", "dark")
    check("C19.no-shell-jsonc-is-skipped", rc == 0 and "skipped" in lines_of(out)["wallpaper"] and not wp_calls(root), out[-200:])
    # the old sources are gone: the HyprV directory and the theme's assets.<mode>.wallpaper
    th = jl(TREE + "/themes/eva.json")
    check("C19.the-theme-file-names-no-wallpaper", all("wallpaper" not in th["assets"][m] for m in ("light", "dark")) and "wallpaperDir" not in open(REPO + "/tools/theme/targets.json").read(), th["assets"])
    # a .json beside no .jsonc is read; the .jsonc wins when both exist
    root = sandbox()
    pics(root)
    put_shell(root, '{ "theme": { "wallpapers": { "eva": { "dark": "~/Pictures/light.png" } } } }', "shell.json")
    put_shell(root, '{ "theme": { "wallpapers": { "eva": { "dark": "~/Pictures/dark.png" } } } }')
    rc, out, _ = ctl(root, "set", "eva", "dark")
    check("C19.the-jsonc-wins-over-the-json", wp_calls(root) and wp_calls(root)[-1].endswith("dark.png,cover"), wp_calls(root))
    os.remove(home(root) + "/.config/quickshell/shell.jsonc")
    rc, out, _ = ctl(root, "set", "eva", "dark")
    check("C19.the-json-alone-is-read", wp_calls(root)[-1].endswith("light.png,cover"), wp_calls(root))
    # failures say why
    for name, block, needle in [("relative-path", '"wallpapers": { "eva": { "dark": "dark.png" } }', "not an absolute path"),
                                ("not-a-string", '"wallpapers": { "eva": { "dark": 5 } }', "must be a path"),
                                ("bad-fit", '"wallpapers": { "eva": { "dark": "~/Pictures/dark.png" } }, "wallpaperFit": "zoom"', "wallpaperFit must be one of")]:
        root = sandbox()
        pics(root)
        put_shell(root, '{ "theme": { %s } }' % block)
        rc, out, _ = ctl(root, "set", "eva", "dark")
        ln = lines_of(out)["wallpaper"]
        check("C19.%s-is-a-fail-that-says-so" % name, ln.startswith("FAIL") and needle in ln and rc == 1 and not wp_calls(root), ln)
    root = sandbox()
    pics(root)
    put_shell(root, '{ "theme": { "wallpapers": { "eva": { "dark": "~/Pictures/dark.png" } }, "wallpaperFit": "contain" } }')
    rc, out, _ = ctl(root, "set", "eva", "dark")
    check("C19.the-fit-mode-is-passed-on", wp_calls(root)[-1].endswith("dark.png,contain") and "fit_mode = contain" in (rd(home(root) + "/.config/hypr/hyprpaper.conf") or ""), wp_calls(root))
    # hyprpaper not running (hyprctl: "error: can't send: failed to connect to hyprpaper (is it running?)", exit 1) is no failure; any other error is
    down = {"STUB_HYPRPAPER_RC": "1", "STUB_HYPRPAPER_OUT": "error: can't send: failed to connect to hyprpaper (is it running?)"}
    rc, out, _ = ctl(root, "set", "eva", "dark", extra=down)
    ln = lines_of(out)["wallpaper"]
    check("C19.hyprpaper-not-running-is-ok-and-the-file-is-written", rc == 0 and ln.startswith("ok") and "not running" in ln, ln)
    rc, out, _ = ctl(root, "set", "eva", "dark", extra={"STUB_HYPRPAPER_RC": "1", "STUB_HYPRPAPER_OUT": "error: bad path: /x"})
    ln = lines_of(out)["wallpaper"]
    check("C19.any-other-hyprctl-error-is-a-fail", rc == 1 and ln.startswith("FAIL") and "bad path" in ln, ln)
    rc, out, _ = ctl(root, "set", "eva", "dark", extra={"STUB_HYPRPAPER_RC": "0", "STUB_HYPRPAPER_OUT": "error: something"})
    check("C19.an-error-text-with-exit-0-is-a-fail-too", lines_of(out)["wallpaper"].startswith("FAIL"), out[-200:])

    # the icon theme: gsettings and both settings.ini, by mode
    root = sandbox()
    for mode, want in (("dark", "Papirus-Dark"), ("light", "Papirus-Light")):
        rc, out, _ = ctl(root, "set", "eva", mode)
        ls = lines_of(out)
        gs = sbx.run(root, ["gsettings", "get", "org.gnome.desktop.interface", "icon-theme"]).stdout.strip()
        i3 = rd(home(root) + "/.config/gtk-3.0/settings.ini") or ""
        i4 = rd(home(root) + "/.config/gtk-4.0/settings.ini") or ""
        check("C19.%s-icon-theme-is-%s-in-gsettings-and-both-ini-files" % (mode, want), rc == 0 and gs == "'%s'" % want and "gtk-icon-theme-name=%s\n" % want in i3 and "gtk-icon-theme-name=%s\n" % want in i4
              and ls["gtk3-ini"].startswith("ok") and ls["gtk4-ini"].startswith("ok"), (gs, i3, i4))
    check("C19.no-theme-asset-names-an-icon-pack-that-is-not-installed", all(os.path.isdir("/usr/share/icons/" + a["iconTheme"]) for a in th["assets"].values()), th["assets"])
    # the ini is edited in place: the user's other keys, comments and order stay; a second run writes nothing
    root = sandbox()
    ini = home(root) + "/.config/gtk-3.0/settings.ini"
    os.makedirs(os.path.dirname(ini), exist_ok=True)
    os.remove(home(root) + "/.config/gtk-4.0/settings.ini")            # this one does not exist: themectl creates it
    open(ini, "w").write("# my gtk\n[Settings]\ngtk-theme-name=Old\ngtk-font-name=Adwaita Sans 11\ngtk-icon-theme-name=Papirus\n[Other]\nx=1\n")
    rc, out, _ = ctl(root, "set", "eva", "dark")
    got = rd(ini)
    check("C19.the-ini-keeps-the-users-other-keys", got == "# my gtk\n[Settings]\ngtk-theme-name=XFCE_Colour_Dark_Doder\ngtk-font-name=Adwaita Sans 11\ngtk-icon-theme-name=Papirus-Dark\n[Other]\nx=1\n", got)
    rc, out, _ = ctl(root, "set", "eva", "dark")
    check("C19.the-second-run-says-unchanged", "unchanged" in lines_of(out)["gtk3-ini"], lines_of(out)["gtk3-ini"])
    rc, out, _ = ctl(root, "restore")
    check("C19.restore-takes-a-created-ini-away-and-leaves-the-users-own", not os.path.exists(home(root) + "/.config/gtk-4.0/settings.ini") and os.path.exists(ini), out[-300:])
    # ini_set on its own
    ini_set = MOD.ini_set
    cases = [("add-to-the-section", "[Settings]\na=1\n\n[B]\nc=2\n", "[Settings]\na=1\nk=v\n\n[B]\nc=2\n"),
             ("add-the-section", "[B]\nc=2\n", "[B]\nc=2\n\n[Settings]\nk=v\n"),
             ("empty-file", "", "[Settings]\nk=v\n"),
             ("no-trailing-newline", "[Settings]\na=1", "[Settings]\na=1\nk=v\n"),
             ("replace-with-spaces", "[Settings]\nk = old\n", "[Settings]\nk=v\n"),
             ("crlf", "[Settings]\r\nk=old\r\n", "[Settings]\r\nk=v\r\n"),
             ("same-key-in-another-section", "[Other]\nk=1\n[Settings]\na=1\n", "[Other]\nk=1\n[Settings]\na=1\nk=v\n")]
    bad = [(n, ini_set(a, "Settings", "k", "v"), b) for n, a, b in cases if ini_set(a, "Settings", "k", "v") != b]
    check("C19.ini_set-cases", not bad, bad)


# ================================================================================================= C20 the Windows VM's mode file

def c20():
    """windows-vm: the word in the folder the VM's compose file shares. Optional: no VM, no volume or no folder is `ok ... skipped` and writes nothing. It works with the VM off because
    it only writes a file: nothing is started or asked (the stub log and the absence of a docker call say so)."""
    def compose(root, text):
        os.makedirs(home(root) + "/.config/windows", exist_ok=True)
        with open(home(root) + "/.config/windows/compose.yaml", "w") as f:
            f.write(text)
    def apply(root, *a):
        return ctl(root, "set", "eva", "dark", "--only", "windows-vm", *a)
    REAL = """services:
  windows:
    image: dockurr/windows
    volumes:
      - ./storage:/storage
      - ${HOME}/Documents/windows:/shared
    restart: 'no'
"""
    # no compose file: skipped, nothing made, exit 0
    root = sandbox()
    rc, out, _ = apply(root)
    ln = lines_of(out)["windows-vm"]
    check("C20.no-vm-is-skipped", rc == 0 and ln.startswith("ok") and "skipped" in ln and not os.path.exists(home(root) + "/Documents/windows"), (rc, ln))
    # a compose file with no such volume: skipped
    compose(root, REAL.replace(":/shared", ":/elsewhere"))
    rc, out, _ = apply(root)
    ln = lines_of(out)["windows-vm"]
    check("C20.no-volume-is-skipped", rc == 0 and ln.startswith("ok") and "shares nothing" in ln, (rc, ln))
    # the volume, and the folder is not there: skipped, and themectl does not make it (docker would, as root)
    compose(root, REAL)
    rc, out, _ = apply(root)
    ln = lines_of(out)["windows-vm"]
    check("C20.no-folder-is-skipped-and-not-made", rc == 0 and ln.startswith("ok") and "does not exist" in ln and not os.path.exists(home(root) + "/Documents/windows"), (rc, ln))
    # the folder: the word, exactly, whatever else the folder holds; `storage` is another volume and nothing goes there
    share = home(root) + "/Documents/windows"
    os.makedirs(share)
    with open(share + "/theirs.txt", "w") as f:
        f.write("the user's\n")
    mode_file = share + "/.theme/mode"
    rc, out, _ = apply(root)
    ln = lines_of(out)["windows-vm"]
    check("C20.writes-the-word", rc == 0 and ln.startswith("ok") and rd(mode_file) == "dark\n", (rc, ln, rd(mode_file)))
    check("C20.only-that-file", sorted(os.listdir(share)) == [".theme", "theirs.txt"] and os.listdir(share + "/.theme") == ["mode"] and not os.path.exists(home(root) + "/.config/windows/storage"), os.listdir(share))
    # with the VM off nothing is asked of anything: no program ran for this target
    calls = sbx.stublog(root)
    check("C20.starts-and-asks-nothing", not [c for c in calls if c.split("\t")[0] in ("docker", "ssh", "systemctl", "sdl-freerdp3", "windows-vm")], calls[-4:])
    # the same word again: not rewritten (a poller over SMB sees no change)
    st0 = os.stat(mode_file).st_mtime_ns
    rc, out, _ = apply(root)
    check("C20.the-same-word-is-not-rewritten", "unchanged" in lines_of(out)["windows-vm"] and os.stat(mode_file).st_mtime_ns == st0, lines_of(out)["windows-vm"])
    # the other mode changes it
    rc, out, _ = ctl(root, "set", "eva", "light", "--only", "windows-vm")
    check("C20.the-other-mode-changes-it", rd(mode_file) == "light\n", (rc, rd(mode_file)))
    # diff and doctor write nothing
    os.remove(mode_file)
    rc, out, _ = ctl(root, "diff", "eva", "dark", "--only", "windows-vm")
    check("C20.diff-writes-nothing", "would write" in out and not os.path.exists(mode_file), out[-200:])
    rc, out, _ = ctl(root, "doctor")
    check("C20.doctor-names-it-and-writes-nothing", any(l.startswith("ok") and "windows-vm" in l and "would write" in l for l in out.splitlines()) and not os.path.exists(mode_file), [l for l in out.splitlines() if "windows-vm" in l])
    # restore takes it away (themectl made it, and kept that it was absent)
    apply(root)
    rc, out, _ = ctl(root, "restore")
    check("C20.restore-takes-it-away", rc == 0 and not os.path.exists(mode_file), out[-200:])
    # a commented-out volume and another service's are not the share; a relative one is the compose file's; quotes and options are the same volume
    root = sandbox()
    os.makedirs(home(root) + "/.config/windows/share")
    compose(root, "services:\n  w:\n    volumes:\n      # - ${HOME}/Documents/old:/shared\n      - './share:/shared:rw'  # the folder\n")
    rc, out, _ = apply(root)
    check("C20.a-relative-quoted-volume-with-options", rc == 0 and rd(home(root) + "/.config/windows/share/.theme/mode") == "dark\n" and not os.path.exists(home(root) + "/Documents/old"), lines_of(out)["windows-vm"])
    # a variable nobody here can know is said, not guessed
    compose(root, "    volumes:\n      - ${SOMEWHERE}/x:/shared\n")
    rc, out, _ = apply(root)
    ln = lines_of(out)["windows-vm"]
    check("C20.an-unknown-variable-is-a-fail", rc == 1 and ln.startswith("FAIL") and "SOMEWHERE" in ln, (rc, ln))
    # a share outside HOME is refused like any output; one that cannot be written is a FAIL with the reason, and the exit status counts it
    compose(root, "    volumes:\n      - /etc:/shared\n")
    rc, out, _ = apply(root)
    ln = lines_of(out)["windows-vm"]
    check("C20.a-share-outside-home-is-refused", rc == 1 and ln.startswith("FAIL") and "outside HOME" in ln, (rc, ln))
    root = sandbox()
    share = home(root) + "/Documents/windows"
    os.makedirs(share)
    compose(root, REAL)
    with open(share + "/.theme", "w") as f:
        f.write("a file where the folder goes\n")
    rc, out, _ = apply(root)
    ln = lines_of(out)["windows-vm"]
    check("C20.an-unwritable-share-is-a-fail", rc == 1 and ln.startswith("FAIL") and "cannot write" in ln, (rc, ln))
    # the real compose file's own line, read only: what the target finds there is what the cheatsheet says
    real = os.path.expanduser("~/.config/windows/compose.yaml")
    if os.path.exists(real):
        found = MOD.compose_share(MOD.Paths(), real, "/shared")
        check("C20.the-real-compose-file-names-the-documents-folder", found == os.path.expanduser("~/Documents/windows"), found)


# ============================================================================================ C23 asset preference lists (gtkTheme ...)

def c23():
    """An asset that names an installed theme may be a list, best first: the first INSTALLED wins, none installed the LAST is applied as it always
    was; doctor names what is missing and what it falls back to; `packages` prints the install list. The fake names below exist nowhere, so the
    machine's own themes do not decide anything; real gsettings (keyfile backend) and both ini files are read back."""
    base = jl(TREE + "/themes/eva.json")

    def make(root, gtk, icon="Papirus-Dark", name="pkgtest"):
        doc = json.loads(json.dumps(base))
        doc["name"] = name
        for m in MOD.MODES:
            doc["assets"][m]["gtkTheme"] = gtk
            doc["assets"][m]["iconTheme"] = icon
        d = home(root) + "/.config/theme/themes"
        os.makedirs(d, exist_ok=True)
        with open(d + "/%s.json" % name, "w") as f:
            json.dump(doc, f)

    def gs(root, key="gtk-theme"):
        return sbx.run(root, ["gsettings", "get", "org.gnome.desktop.interface", key]).stdout.strip()

    def ini(root):
        return (rd(home(root) + "/.config/gtk-3.0/settings.ini") or "", rd(home(root) + "/.config/gtk-4.0/settings.ini") or "")

    def theme_dir(root, where, name, inside=("gtk-3.0",)):
        d = {"data": home(root) + "/.local/share/themes", "dot": home(root) + "/.themes"}[where] + "/" + name
        os.makedirs(d, exist_ok=True)
        for x in inside:
            if x == "index.theme":
                open(d + "/index.theme", "w").write("[Desktop Entry]\n")
            else:
                os.makedirs(d + "/" + x, exist_ok=True)

    LIST = ["Pkg_Best", "Pkg_Mid", "Pkg_Fallback"]
    ONLY = ["--only", "gtk,gtk3-ini,gtk4-ini"]
    # none installed: the last entry, and exactly the writes of the same theme with that name as a plain string
    a, b = sandbox(), sandbox()
    make(a, LIST)
    make(b, "Pkg_Fallback")
    ra = ctl(a, "set", "pkgtest", "dark", *ONLY)
    rb = ctl(b, "set", "pkgtest", "dark", *ONLY)
    same = (gs(a) == gs(b) == "'Pkg_Fallback'" and ini(a) == ini(b) and "gtk-theme-name=Pkg_Fallback\n" in ini(a)[0]
            and rd(home(a) + "/.config/glib-2.0/settings/keyfile") == rd(home(b) + "/.config/glib-2.0/settings/keyfile"))
    check("C23.none-installed-writes-the-last-entry-exactly-as-a-string-did", ra[0] == rb[0] == 0 and same, (ra[0], gs(a), gs(b)))
    # the second installed: it wins; a folder with no index.theme and no gtk-3.0 / gtk-4.0 inside is not a theme
    root = sandbox()
    make(root, LIST)
    theme_dir(root, "dot", "Pkg_Best", inside=())
    rc, out, _ = ctl(root, "set", "pkgtest", "dark", *ONLY)
    check("C23.an-empty-folder-is-not-an-installed-theme", rc == 0 and gs(root) == "'Pkg_Fallback'", (rc, gs(root)))
    theme_dir(root, "data", "Pkg_Mid", inside=("gtk-3.0",))
    rc, out, _ = ctl(root, "set", "pkgtest", "dark", *ONLY)
    i3, i4 = ini(root)
    check("C23.the-second-installed-wins", rc == 0 and gs(root) == "'Pkg_Mid'" and "gtk-theme-name=Pkg_Mid\n" in i3 and "gtk-theme-name=Pkg_Mid\n" in i4, (rc, gs(root), i3))
    # both installed: the FIRST of the list, not the last installed and not the alphabetically first
    theme_dir(root, "dot", "Pkg_Best", inside=("index.theme",))
    rc, out, _ = ctl(root, "set", "pkgtest", "dark", *ONLY)
    i3, i4 = ini(root)
    check("C23.both-installed-the-first-of-the-list-wins", rc == 0 and gs(root) == "'Pkg_Best'" and "gtk-theme-name=Pkg_Best\n" in i3 and "gtk-theme-name=Pkg_Best\n" in i4, (rc, gs(root), i3))
    ls = lines_of(out)
    check("C23.every-gtk-target-says-ok", all(ls.get(k, "").startswith("ok") for k in ("gtk", "gtk3-ini", "gtk4-ini")), ls)
    # an icon list is the same rule (icons: a folder with an index.theme, in the icon directories)
    root = sandbox()
    make(root, "Pkg_Fallback", icon=["Pkg_Icons", "Papirus-Dark"])
    rc, out, _ = ctl(root, "set", "pkgtest", "dark", *ONLY)
    check("C23.an-icon-list-with-none-installed-takes-the-last", rc == 0 and gs(root, "icon-theme") == "'Papirus-Dark'", (rc, gs(root, "icon-theme")))
    d = home(root) + "/.local/share/icons/Pkg_Icons"
    os.makedirs(d)
    open(d + "/index.theme", "w").write("[Icon Theme]\nName=Pkg_Icons\n")
    rc, out, _ = ctl(root, "set", "pkgtest", "dark", *ONLY)
    i3, _ = ini(root)
    check("C23.an-installed-icon-theme-wins", rc == 0 and gs(root, "icon-theme") == "'Pkg_Icons'" and "gtk-icon-theme-name=Pkg_Icons\n" in i3, (rc, gs(root, "icon-theme"), i3))
    # a list that is empty or holds a non-name is that target's FAIL with the words, nothing else's
    root = sandbox()
    make(root, [])
    rc, out, _ = ctl(root, "set", "pkgtest", "dark", *ONLY)
    ls = lines_of(out)
    check("C23.an-empty-list-is-a-fail-that-says-so", rc == 3 and all(ls.get(k, "").startswith("FAIL") and "empty" in ls.get(k, "") for k in ("gtk", "gtk3-ini", "gtk4-ini")), (rc, ls))
    # doctor: a line per pair; missing preferred is a note with the install words, never a FAIL
    root = sandbox("post")
    make(root, LIST)
    pk = {"Pkg_Best": {"repo": "aur", "pkg": "pkg-best-theme"}, "Pkg_Mid": {"repo": "extra", "pkg": "pkg-mid-theme"}}
    open(home(root) + "/.config/theme/packages.json", "w").write(json.dumps({"themes": pk}))
    ctl(root, "set", "pkgtest", "dark", "--only", "quickshell")   # the target's OLD name still selects it (TARGET_ALIASES)
    rc, out, _ = ctl(root, "set", "pkgtest", "dark", "--only", "lares")
    check("C23.the-state-target-is-lares-and-quickshell-is-its-old-name", rc == 0 and "lares" in out and "no target named" not in out, (rc, out[-200:]))
    rc, out, _ = ctl(root, "doctor", extra=SIG)
    ln = next((l for l in out.splitlines() if "pkg pkgtest" in l), "")
    check("C23.doctor-says-what-is-missing-and-the-fallback", ln.startswith("note") and "preferred Pkg_Best (yay -S pkg-best-theme); Pkg_Mid (sudo pacman -S pkg-mid-theme)" in ln
          and "falls back to Pkg_Fallback (not installed either)" in ln, ln)
    check("C23.a-missing-preferred-theme-is-no-fail", "FAIL" not in out and rc == 0, (rc, [l for l in out.splitlines() if l.startswith("FAIL")][:2]))
    theme_dir(root, "dot", "Pkg_Fallback", inside=("index.theme",))
    rc, out, _ = ctl(root, "doctor", extra=SIG)
    ln = next((l for l in out.splitlines() if "pkg pkgtest" in l), "")
    check("C23.doctor-with-the-fallback-installed-says-uses-it", ln.startswith("note") and "falls back to Pkg_Fallback" in ln and "not installed either" not in ln, ln)
    theme_dir(root, "dot", "Pkg_Best", inside=("index.theme",))
    rc, out, _ = ctl(root, "doctor", extra=SIG)
    ln = next((l for l in out.splitlines() if "pkg pkgtest" in l), "")
    check("C23.doctor-with-the-best-installed-says-ok", ln.startswith("ok") and "Pkg_Best installed" in ln and "missing" not in ln, ln)
    # the shipped pairs: doctor names each pair that has a list, with the package that installs the preferred theme
    # with no system theme directory: what is installed on the machine running the test (the user installed the AUR themes on 2026-11-08,
    # and this check flipped) is not the subject
    root = sandbox("post")
    nodata = {"XDG_DATA_DIRS": root + "/no-system-data"}
    rc, out, _ = ctl(root, "doctor", extra=dict(SIG, **nodata))
    pairs = {l.split()[2] for l in out.splitlines() if l.split()[:2] in (["note", "pkg"], ["ok", "pkg"])}
    ln = next((l for l in out.splitlines() if "pkg tokyo-night" in l), "")
    check("C23.doctor-has-a-line-for-every-pair-with-a-list", {"catppuccin", "eva", "everbox", "monokai", "night-owl", "paper", "riso", "tokyo-night"} <= pairs, sorted(pairs))
    check("C23.doctor-names-the-package-for-the-preferred-theme", "yay -S tokyonight-gtk-theme-git" in ln and "yay -S catppuccin-gtk-theme-macchiato" in ln and "Storm" not in ln, ln)
    # `packages` prints the install list and writes nothing
    before = content_state(root)
    rc, out, _ = ctl(root, "packages", extra=nodata)
    check("C23.packages-prints-the-install-command-and-writes-nothing", rc == 0 and "yay -S --needed" in out and "tokyonight-gtk-theme-git" in out and "catppuccin-gtk-theme-latte" in out
          and content_state(root) == before, (rc, out[-300:]))
    check("C23.packages-names-the-vscode-extensions", "code --install-extension a5hk.paper" in out and "code --install-extension mvllow.rose-pine" in out
          and out.count("mvllow.rose-pine") == 2, out[-400:])
    # every list in the shipped themes ends with a theme this machine has (the fallback is today's value) and every name has a package or recipe
    pkj = jl(TREE + "/tools/theme/packages.json").get("themes", {})
    gap = []
    for n in sorted(x[:-5] for x in os.listdir(TREE + "/themes") if x.endswith(".json")):
        for m, blk in (jl(TREE + "/themes/%s.json" % n).get("assets") or {}).items():
            for k in ("gtkTheme", "iconTheme", "vscodeTheme"):
                v = blk.get(k)
                if isinstance(v, list):
                    gap += [(n, m, e) for e in v[:-1] if e not in pkj]
    check("C23.every-preferred-name-has-a-package-or-a-recipe", not gap, gap)


# ======================================================================================= C24 libadwaita's accent, C25 `wallpaper set`

# what each pair's accent token maps to (CIEDE2000, lightness out), read by hand against the nine colours in themectl's GNOME_ACCENTS
ACCENT_WANT = {("catppuccin", "light"): "purple", ("catppuccin", "dark"): "purple", ("eva", "light"): "blue", ("eva", "dark"): "blue",
               ("everbox", "light"): "green", ("everbox", "dark"): "green", ("monokai", "light"): "teal", ("monokai", "dark"): "teal",
               ("night-owl", "light"): "blue", ("night-owl", "dark"): "blue", ("paper", "light"): "blue", ("paper", "dark"): "blue",
               ("riso", "light"): "pink", ("riso", "dark"): "pink", ("tokyo-night", "light"): "blue", ("tokyo-night", "dark"): "blue"}


def c24():
    """The `gnome-accent` target: gsettings org.gnome.desktop.interface accent-color = the named GNOME accent nearest (CIEDE2000, lightness taken out)
    to the pair's accent token. The REAL libadwaita reading it is tools/dev/themectl_accent_probe.py; here the arithmetic and the write."""
    for (l1, l2, want) in [((50, 2.6772, -79.7751), (50, 0, -82.7485), 2.0425), ((50, 2.5, 0), (73, 25, -18), 27.1492),
                           ((60.2574, -34.0099, 36.2677), (60.4626, -34.1751, 39.4387), 1.2644), ((50, 2.5, 0), (50, 0, -2.5), 4.3065)]:
        got = MOD.de2000_lab(l1, l2)
        check("C24.ciede2000-matches-sharma-wu-dalal-%s" % want, abs(got - want) < 5e-4, got)
    check("C24.each-of-the-nine-maps-to-itself", all(MOD.nearest_gnome_accent(h)[0] == n for n, h in MOD.GNOME_ACCENTS.items()), MOD.GNOME_ACCENTS)
    check("C24.a-pastel-mauve-is-purple-not-slate", MOD.nearest_gnome_accent("#C6A0F6")[0] == "purple", MOD.nearest_gnome_accent("#C6A0F6"))
    root = sandbox()
    h = home(root)

    def gs(r):
        return sbx.run(r, ["gsettings", "get", "org.gnome.desktop.interface", "accent-color"]).stdout.strip()
    bad = {}
    for (name, mode), want in sorted(ACCENT_WANT.items()):
        rc, out, _ = ctl(root, "set", name, mode, "--only", "gnome-accent")
        ln = lines_of(out).get("gnome-accent", "")
        if rc != 0 or gs(root) != "'%s'" % want or not ln.startswith("ok"):
            bad[(name, mode)] = (rc, gs(root), ln[:120])
    check("C24.every-pair-and-mode-writes-its-nearest-named-accent", not bad, bad)
    ctl(root, "set", "riso", "dark", "--only", "gnome-accent")
    rc, out, _ = ctl(root, "set", "riso", "dark", "--only", "gnome-accent")
    check("C24.again-says-unchanged", "unchanged" in lines_of(out)["gnome-accent"], out[-200:])
    rc, out, _ = ctl(root, "diff", "eva", "light")
    check("C24.diff-shows-the-change-and-writes-nothing", "accent-color" in out and gs(root) == "'pink'", (out[-300:], gs(root)))
    check("C24.the-target-says-what-it-chose", "accent #4480F4 -> blue" in out, out[-200:])
    root2 = sandbox()
    rc, out, _ = ctl(root2, "doctor")
    check("C24.doctor-knows-the-target", re.search(r"^ok\s+gnome-accent\s", out, re.M) is not None, out[-300:])
    # the libadwaita target's stylesheet carries the exact accent past the portal (themectl_libadwaita_probe.py): no ADW_DISABLE_PORTAL note with it
    check("C24.doctor-asks-for-no-variable-while-the-libadwaita-target-runs", re.search(r"^note\s+gnome-accent", out, re.M) is None, out[-300:])
    # a targets.json of the user's own without that target: the named accent is all libadwaita gets, and only without a portal
    doc = jl(TREE + "/tools/theme/targets.json")
    doc["targets"] = [t for t in doc["targets"] if t["name"] != "libadwaita"]
    open(home(root2) + "/.config/theme/targets.json", "w").write(json.dumps(doc))
    rc, out, _ = ctl(root2, "doctor")
    check("C24.doctor-says-what-libadwaita-needs-to-read-it", re.search(r"^note\s+gnome-accent\s.*ADW_DISABLE_PORTAL=1", out, re.M) is not None, out[-300:])
    rc, out, _ = ctl(root2, "doctor", extra={"ADW_DISABLE_PORTAL": "1"})
    check("C24.doctor-is-quiet-once-the-variable-is-set", re.search(r"^note\s+gnome-accent", out, re.M) is None, out[-300:])


# ---- C25: `themectl wallpaper set`

WP_SHELL = '''// shell.jsonc -- the user's own comments
{
    "scale": { "global": 1.25 },   // keep me
    "theme": {
        "apply": "themectl",
        /* a block comment */
        "wallpapers": {
            "eva": {
                "light": "~/Pictures/old.png",   // the old one
                "dark": "~/Pictures/dark.png"
            }
        },
        "curtainLive": true
    },
    "icons": { "overrides": { "kitty": "~/k.png" } }
}
'''


WP_NODARK = WP_SHELL.replace(',   // the old one\n                "dark": "~/Pictures/dark.png"', '   // the old one')


def _jsonc():
    spec = importlib.util.spec_from_file_location("jsonc_for_cases", REPO + "/tools/lib/jsonc.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _subseq(a, b):
    """True when every character of A appears in B in order: B is A with things INSERTED and nothing taken away or changed."""
    it = iter(b)
    return all(c in it for c in a)


def _png(path, rgb=(200, 60, 60)):
    from PIL import Image
    os.makedirs(os.path.dirname(path), exist_ok=True)
    Image.new("RGB", (8, 8), rgb).save(path)


@contextlib.contextmanager
def notif_bus(work):
    """A private session bus with a stand-in notification server (tools/dev/fixtures/themectl/dbus_standins.py): .addr, .log (the Notify calls),
    .mode (file: what it does with the next one: revert | close | nothing)."""
    class B:
        pass
    b = B()
    b.addr, b.log, b.mode, b.ready = None, os.path.join(work, "notif.log"), os.path.join(work, "notif.mode"), os.path.join(work, "notif.ready")
    open(b.mode, "w").write("nothing")
    p = subprocess.Popen([REPO + "/tools/dev/notifications_bus.sh", "python3", REPO + "/tools/dev/fixtures/themectl/dbus_standins.py", "notifications",
                          "--log", b.log, "--mode", b.mode, "--ready", b.ready], start_new_session=True, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if os.path.exists(b.ready):
                break
            time.sleep(0.1)
        b.addr = rd(b.ready)
        yield b
    finally:
        try:
            os.killpg(p.pid, 15)
        except OSError:
            pass
        p.wait(timeout=20)


def _wait(fn, secs=15.0):
    end = time.time() + secs
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(0.1)
    return fn()


def c25():
    """`themectl wallpaper set <image>` (yazi's "Set as wallpaper"): the CURRENT theme and mode's slot in shell.jsonc by a TEXT edit, applied through
    the wallpaper target, a notification with Revert. Everything in a sandbox HOME, hyprctl a stub, the notification server a stand-in on a private bus."""
    import json as _json

    def setup(root, text=WP_SHELL, state=("eva", "light")):
        h = home(root)
        for n in ("old.png", "dark.png", "new.png", "other.png"):
            _png(h + "/Pictures/" + n)
        put_shell(root, text)
        with open(h + "/.config/theme/state.json", "w") as f:
            f.write(_json.dumps({"theme": state[0], "mode": state[1]}, indent=2) + "\n")
        return h, h + "/.config/quickshell/shell.jsonc"

    def wp_calls(root):
        return ["\t".join(c) for c in sbx.stublog(root) if c[:3] == ["hyprctl", "hyprpaper", "wallpaper"]]

    # one image: APPENDED to the slot (a string slot becomes a list of the two, one a line), every other byte stays, it is shown at once
    def as_list(old, new, ind=16):
        return '[\n%s%s,\n%s"%s"\n%s]' % (" " * (ind + 4), old, " " * (ind + 4), new, " " * ind)
    root = sandbox()
    h, cfg = setup(root)
    before = rd(cfg)
    rc, out, err = ctl(root, "wallpaper", "set", "--no-notify", h + "/Pictures/new.png")
    after = rd(cfg)
    grown = as_list('"~/Pictures/old.png"', "~/Pictures/new.png")
    check("C25.one-image-is-added-to-the-slot-and-shown", rc == 0 and after == before.replace('"~/Pictures/old.png"', grown) and wp_calls(root) == ["hyprctl\thyprpaper\twallpaper\t,%s/Pictures/new.png,cover" % h]
          and "path = %s/Pictures/new.png" % h in (rd(h + "/.config/hypr/hyprpaper.conf") or ""), (rc, out[-200:], err[-200:], wp_calls(root), after))
    check("C25.comments-and-every-other-byte-survive", after is not None and "// keep me" in after and "// the old one" in after and "/* a block comment */" in after and after.count('"~/Pictures/dark.png"') == 1
          and after.replace(grown, '"~/Pictures/old.png"') == before, after)
    check("C25.the-path-is-stored-as-the-user-writes-one-under-the-home", '"~/Pictures/new.png"' in (after or ""), after)
    # again: a picture already in the list is not added twice; set of another listed picture shows it and writes nothing
    rc, out, _ = ctl(root, "wallpaper", "set", "--no-notify", h + "/Pictures/new.png")
    check("C25.the-picture-on-screen-again-changes-nothing", rc == 0 and rd(cfg) == after and "unchanged" in out and len(wp_calls(root)) == 1, (rc, out[-200:], wp_calls(root)))
    rc, out, _ = ctl(root, "wallpaper", "set", "--no-notify", h + "/Pictures/old.png")
    check("C25.a-listed-picture-is-shown-and-not-added-twice", rc == 0 and rd(cfg) == after and wp_calls(root)[-1].endswith("/Pictures/old.png,cover"), (rc, out[-200:], wp_calls(root)))
    rc, out, _ = ctl(root, "wallpaper", "set", "--no-notify", h + "/Pictures/other.png")
    check("C25.a-third-picture-joins-the-list", rc == 0 and _jsonc().loads(rd(cfg))["theme"]["wallpapers"]["eva"]["light"] == ["~/Pictures/old.png", "~/Pictures/new.png", "~/Pictures/other.png"]
          and _subseq(after, rd(cfg)), rd(cfg))
    # it follows the state: dark mode takes the dark slot
    root = sandbox()
    h, cfg = setup(root, state=("eva", "dark"))
    before = rd(cfg)
    rc, out, _ = ctl(root, "wallpaper", "set", "--no-notify", h + "/Pictures/new.png")
    check("C25.the-current-mode-is-the-slot", rc == 0 and rd(cfg) == before.replace('"~/Pictures/dark.png"', as_list('"~/Pictures/dark.png"', "~/Pictures/new.png")), rd(cfg))
    # a path outside the home is stored absolute
    root = sandbox()
    h, cfg = setup(root)
    outside = os.path.join(root, "elsewhere", "pic.png")
    _png(outside)
    rc, out, _ = ctl(root, "wallpaper", "set", "--no-notify", outside)
    check("C25.a-path-outside-the-home-is-stored-absolute", rc == 0 and '"%s"' % outside in (rd(cfg) or ""), rd(cfg))
    # refusals: several files, none, a non-image, a missing file, a folder; nothing written, nothing asked of hyprpaper, a notification says why
    root = sandbox()
    h, cfg = setup(root)
    before = rd(cfg)
    open(h + "/Pictures/notes.png", "w").write("this is text\n")
    os.makedirs(h + "/Pictures/dir.png")
    for name, argv, word in [("two-files", [h + "/Pictures/new.png", h + "/Pictures/other.png"], "exactly one"), ("none", [], "exactly one"),
                             ("not-an-image", [h + "/Pictures/notes.png"], "not an image"), ("missing", [h + "/Pictures/nothing.png"], "not a file"),
                             ("a-folder", [h + "/Pictures/dir.png"], "not a file")]:
        sbx.clear_stublog(root)
        rc, out, _ = ctl(root, "wallpaper", "set", *argv)
        notes = [c for c in sbx.stublog(root) if c[0] == "notify-send"]
        check("C25.%s-is-refused" % name, rc == 100 and rd(cfg) == before and not wp_calls(root) and word in out, (rc, out[:160], wp_calls(root)))
        check("C25.%s-says-why-in-a-notification" % name, len(notes) == 1 and any(word in a for a in notes[0]) and any("not set" in a for a in notes[0]), notes)
    # hyprpaper refuses the picture: nothing is left half set
    root = sandbox()
    h, cfg = setup(root)
    before = rd(cfg)
    rc, out, _ = ctl(root, "wallpaper", "set", "--no-notify", h + "/Pictures/new.png", extra={"STUB_HYPRPAPER_RC": "1", "STUB_HYPRPAPER_OUT": "error: no decoder"})
    check("C25.hyprpaper-refusing-puts-the-text-back", rc == 1 and rd(cfg) == before and "FAIL" in out, (rc, out[-200:], rd(cfg)))
    # the slot is not there: inserted -- seven shapes of file, in process
    J = _jsonc()
    cases = {
        "mode-missing-in-the-theme-block": (WP_NODARK, ["theme", "wallpapers", "eva", "dark"], None),
        "theme-block-missing": (WP_SHELL, ["theme", "wallpapers", "tokyo-night", "dark"], None),
        "wallpapers-missing": ('{\n    "scale": 1,\n    "theme": {\n        "apply": "themectl",\n        "curtainLive": true // last\n    }\n}\n', ["theme", "wallpapers", "eva", "light"], None),
        "theme-missing": ('{\n  "scale": { "global": 1.25 },\n  "icons": {}\n}\n', ["theme", "wallpapers", "riso", "dark"], None),
        "one-line-file": ('{ "theme": { "wallpapers": { "eva": { "light": "a" } } } }', ["theme", "wallpapers", "eva", "dark"], None),
        "trailing-commas-and-an-empty-block": ('{\n    "theme": {\n        "wallpapers": {},\n    },\n}\n', ["theme", "wallpapers", "eva", "dark"], "tc"),
        "empty-object": ('{}', ["theme", "wallpapers", "eva", "dark"], None),
    }
    for name, (text, slot, flag) in cases.items():
        try:
            out = MOD.jsonc_set_path(text, slot, "~/Pictures/x.png")
        except ValueError as e:
            check("C25.insert.%s" % name, False, e)
            continue
        if flag == "tc":                                  # the trailing-comma file does not parse as JSON; the shell's reader (strip) does not take it either
            ok = _subseq(text, out) and '"dark": "~/Pictures/x.png"' in out and out.count(",") >= text.count(",")
        else:
            want = J.loads(text)
            d = want
            for k in slot[:-1]:
                d = d.setdefault(k, {})
            d[slot[-1]] = "~/Pictures/x.png"
            ok = J.loads(out) == want and _subseq(text, out)
        check("C25.insert.%s" % name, ok, out)
    out = MOD.jsonc_set_path(WP_NODARK, ["theme", "wallpapers", "eva", "dark"], "~/Pictures/x.png")
    check("C25.insert-keeps-the-indent-and-the-trailing-comment", '"light": "~/Pictures/old.png",   // the old one\n                "dark": "~/Pictures/x.png"\n' in out, out)
    out = MOD.jsonc_set_path('{\n    "a": "x" // note\n}\n', ["b"], "y")
    check("C25.insert-puts-the-comma-before-a-trailing-comment", '"a": "x", // note\n    "b": "y"\n}' in out, out)
    refused = []
    for text, slot in [('{"theme": 5}', ["theme", "wallpapers", "eva", "dark"]), ('{"theme": {"wallpapers": []}}', ["theme", "wallpapers", "eva", "dark"]),
                       ('[1]', ["theme"]), ('{"theme": {"wallpapers": {"eva": {"dark": {"x": 1}}}}}', ["theme", "wallpapers", "eva", "dark"])]:
        try:
            MOD.jsonc_set_path(text, slot, "z")
            refused.append(text)
        except ValueError:
            pass
    check("C25.a-file-of-the-wrong-shape-is-refused-not-mangled", not refused, refused)
    # end to end: a slot that does not exist yet, and no shell.jsonc at all
    root = sandbox()
    h, cfg = setup(root, state=("tokyo-night", "dark"))
    before = rd(cfg)
    rc, out, _ = ctl(root, "wallpaper", "set", "--no-notify", h + "/Pictures/new.png")
    after = rd(cfg) or ""
    check("C25.a-missing-slot-is-inserted-end-to-end", rc == 0 and _subseq(before, after) and J.loads(after)["theme"]["wallpapers"]["tokyo-night"] == {"dark": "~/Pictures/new.png"}
          and J.loads(after)["theme"]["wallpapers"]["eva"]["light"] == "~/Pictures/old.png", (rc, out[-200:], after))
    root = sandbox()
    h = home(root)
    _png(h + "/Pictures/new.png")
    rc, out, _ = ctl(root, "wallpaper", "set", "--no-notify", h + "/Pictures/new.png")
    got = rd(h + "/.config/quickshell/config/shell.jsonc") or ""
    check("C25.no-shell-jsonc-makes-one-in-config", rc == 0 and got and J.loads(got)["theme"]["wallpapers"]["eva"]["light"] == "~/Pictures/new.png"
          and not os.path.exists(h + "/.config/quickshell/shell.jsonc"), (rc, out[-200:], got))
    # one still in the old place (not moved yet) is the one edited; once config/ has one, that one is
    root = sandbox()
    h = home(root)
    _png(h + "/Pictures/new.png")
    put_shell(root, '{ "theme": { "wallpapers": { "eva": { "light": "~/Pictures/old.png" } } } }')
    ctl(root, "wallpaper", "set", "--no-notify", h + "/Pictures/new.png")
    old_edit = "new.png" in (rd(h + "/.config/quickshell/shell.jsonc") or "") and not os.path.exists(h + "/.config/quickshell/config/shell.jsonc")
    os.makedirs(h + "/.config/quickshell/config", exist_ok=True)
    open(h + "/.config/quickshell/config/shell.jsonc", "w").write('{ "theme": { "wallpapers": { "eva": { "light": "~/Pictures/old.png" } } } }')
    ctl(root, "wallpaper", "set", "--no-notify", h + "/Pictures/new.png")
    new_edit = "new.png" in (rd(h + "/.config/quickshell/config/shell.jsonc") or "")
    check("C25.the-file-in-force-is-edited-the-old-place-until-config-has-one", old_edit and new_edit, (old_edit, new_edit))
    # the notification: the stub records the call (what the shell is asked)
    root = sandbox()
    h, cfg = setup(root)
    rc, out, _ = ctl(root, "wallpaper", "set", h + "/Pictures/new.png")
    notes = _wait(lambda: [c for c in sbx.stublog(root) if c[0] == "notify-send"])
    check("C25.the-notification-has-a-revert-action", rc == 0 and len(notes) == 1 and "--action=revert=Revert" in notes[0] and any("Wallpaper set" == a for a in notes[0]), notes)
    left = _wait(lambda: not [f for f in os.listdir(h + "/.local/state/theme") if f.startswith("wallpaper-undo")] if os.path.isdir(h + "/.local/state/theme") else True)
    check("C25.the-undo-record-goes-when-the-notification-ends", left, os.listdir(h + "/.local/state/theme") if os.path.isdir(h + "/.local/state/theme") else None)
    # Revert, through a real notify-send on a private bus with a stand-in server that clicks it
    work = os.path.join(WORK, "bus")
    os.makedirs(work)
    realbin = os.path.join(work, "realbin")
    os.makedirs(realbin)
    os.symlink("/usr/bin/notify-send", realbin + "/notify-send")
    with notif_bus(work) as bus:
        def env_of(root):
            return {"DBUS_SESSION_BUS_ADDRESS": bus.addr, "PATH": "%s:%s/bin:/usr/bin:/bin" % (realbin, root)}
        check("C25.the-private-bus-is-up", bus.addr and bus.addr.startswith("unix:"), bus.addr)
        # existing slot: Revert puts the old bytes back and the old picture
        root = sandbox()
        h, cfg = setup(root)
        before = rd(cfg)
        open(bus.mode, "w").write("revert")
        rc, out, _ = ctl(root, "wallpaper", "set", h + "/Pictures/new.png", extra=env_of(root))
        got = _wait(lambda: rd(cfg) == before and len(wp_calls(root)) >= 2)
        calls = wp_calls(root)
        _wait(lambda: len((rd(bus.log) or "").splitlines()) >= 2)
        logged = [_json.loads(l) for l in (rd(bus.log) or "").splitlines()]
        check("C25.revert-puts-back-the-old-text-byte-for-byte", rc == 0 and rd(cfg) == before, (rc, rd(cfg)))
        check("C25.revert-tells-hyprpaper-the-old-picture", got and calls[0].endswith("new.png,cover") and calls[-1].endswith("old.png,cover"), calls)
        check("C25.the-server-saw-one-card-with-the-revert-action-and-a-word-for-the-undo",
              len(logged) >= 2 and logged[0]["summary"] == "Wallpaper set" and "revert" in logged[0]["actions"] and logged[1]["summary"] == "Wallpaper put back", logged)
        # no slot before: Revert takes it away, puts hyprpaper's own file back, tells hyprpaper the picture it listed
        root = sandbox()
        h, cfg = setup(root, state=("tokyo-night", "dark"))
        before = rd(cfg)
        os.makedirs(h + "/.config/hypr", exist_ok=True)
        open(h + "/.config/hypr/hyprpaper.conf", "w").write("# before\n")
        open(bus.mode, "w").write("revert")
        _hp_seed(root, [("*", h + "/Pictures/old.png")])                 # hyprpaper shows another theme's picture (its fallback)
        nb = (rd(bus.log) or "").count("Wallpaper put back")
        rc, out, _ = ctl(root, "wallpaper", "set", h + "/Pictures/new.png", extra=env_of(root))
        got = _wait(lambda: rd(cfg) == before and (rd(h + "/.config/hypr/hyprpaper.conf") == "# before\n") and len(wp_calls(root)) >= 2)
        _wait(lambda: (rd(bus.log) or "").count("Wallpaper put back") > nb)
        calls = wp_calls(root)
        check("C25.revert-of-an-inserted-slot-removes-it-and-puts-hyprpapers-file-back", rc == 0 and got, (rc, rd(cfg), rd(h + "/.config/hypr/hyprpaper.conf")))
        check("C25.revert-of-an-inserted-slot-tells-hyprpaper-the-picture-it-listed", any(c.endswith("\t,%s/Pictures/old.png,cover" % h) for c in calls[1:])
              and _hp_shown(root) == "eDP-1: %s/Pictures/old.png" % h, (calls, _hp_shown(root)))
        # ...as the FALLBACK: a named set there (the Revert before 2026-11-11) froze every later switch -- hyprpaper ignored them while themectl
        # said "ran" -- the user's sequence: a picture set into a theme with no slot, Revert, another picture, another theme
        check("C25.revert-of-an-inserted-slot-names-no-monitor", not [c for c in calls[1:] if c.startswith("hyprctl\thyprpaper\twallpaper\teDP-1,")], calls)
        ctl(root, "wallpaper", "set", "--no-notify", h + "/Pictures/other.png", extra=env_of(root))
        then = _hp_shown(root)
        rc, out, _ = ctl(root, "set", "eva", "dark", "--only", "wallpaper", extra=env_of(root))
        check("C25.after-that-revert-a-new-picture-and-a-switch-still-show", then == "eDP-1: %s/Pictures/other.png" % h and _hp_shown(root) == "eDP-1: %s/Pictures/dark.png" % h
              and lines_of(out)["wallpaper"].startswith("ok"), (then, _hp_shown(root), out[-200:]))
        # nobody clicks: the card closes, nothing is put back
        root = sandbox()
        h, cfg = setup(root)
        before = rd(cfg)
        open(bus.mode, "w").write("close")
        n0 = len((rd(bus.log) or "").splitlines())
        rc, out, _ = ctl(root, "wallpaper", "set", h + "/Pictures/new.png", extra=env_of(root))
        _wait(lambda: len((rd(bus.log) or "").splitlines()) > n0)
        _wait(lambda: not [f for f in os.listdir(h + "/.local/state/theme") if f.startswith("wallpaper-undo")] if os.path.isdir(h + "/.local/state/theme") else False)
        check("C25.an-unclicked-card-leaves-the-new-wallpaper", rd(cfg) != before and "new.png" in (rd(cfg) or "") and len(wp_calls(root)) == 1, (rd(cfg), wp_calls(root)))
        # the file moved on: only the slot comes back (the user's edit stays); a later set makes an earlier Revert refuse
        root = sandbox()
        h, cfg = setup(root)
        before = rd(cfg)
        open(bus.mode, "w").write("nothing")
        rc, out, _ = ctl(root, "wallpaper", "set", h + "/Pictures/new.png", extra=env_of(root))
        recs = _wait(lambda: [f for f in os.listdir(h + "/.local/state/theme") if f.startswith("wallpaper-undo")] if os.path.isdir(h + "/.local/state/theme") else [])
        rec = _json.load(open(h + "/.local/state/theme/" + recs[0])) if recs else {}
        with open(cfg, "a") as f:
            f.write("// edited later\n")
        with in_env(root):
            P = MOD.Paths()
            try:
                msg = MOD.wallpaper_revert(P, rec)
            except Exception as e:                       # noqa: BLE001
                msg = "raised %r" % e
        got = rd(cfg) or ""
        check("C25.revert-after-an-edit-takes-out-only-its-picture", got.endswith("// edited later\n") and _subseq(before, got)
              and _jsonc().loads(got)["theme"]["wallpapers"]["eva"]["light"] == ["~/Pictures/old.png"], (msg, got))
        root = sandbox()
        h, cfg = setup(root)
        rc, out, _ = ctl(root, "wallpaper", "set", h + "/Pictures/new.png", extra=env_of(root))
        recs = _wait(lambda: [f for f in os.listdir(h + "/.local/state/theme") if f.startswith("wallpaper-undo")] if os.path.isdir(h + "/.local/state/theme") else [])
        rec = _json.load(open(h + "/.local/state/theme/" + recs[0])) if recs else {}
        ctl(root, "wallpaper", "set", "--no-notify", h + "/Pictures/other.png")
        n0 = len(wp_calls(root))
        with in_env(root):
            P = MOD.Paths()
            try:
                MOD.wallpaper_revert(P, rec)
                refused = False
            except MOD.Refused:
                refused = True
        check("C25.an-earlier-revert-after-a-later-set-takes-out-only-its-own-picture", not refused
              and _jsonc().loads(rd(cfg))["theme"]["wallpapers"]["eva"]["light"] == ["~/Pictures/old.png", "~/Pictures/other.png"]
              and wp_calls(root)[n0:] and wp_calls(root)[-1].endswith("/Pictures/other.png,cover"), (refused, rd(cfg), wp_calls(root)[n0:]))

# ---- C26: the libadwaita target (GTK 4's user stylesheet)

def c26():
    """The `libadwaita` target: ~/.config/gtk-4.0/gtk.css with libadwaita's CSS variables from the pair's tokens. The REAL libadwaita drawing it is
    tools/dev/themectl_libadwaita_probe.py; here the file, the ink choice, ownership and restore. Literal colours (eva and monokai as shipped)."""
    root = sandbox()
    css = home(root) + "/.config/gtk-4.0/gtk.css"
    rc, out, _ = ctl(root, "set", "eva", "light", "--only", "libadwaita")
    t = rd(css) or ""
    want = {"--window-bg-color": "#EAEDF5", "--view-bg-color": "#E5E8EF", "--sidebar-bg-color": "#E1E4EB", "--card-bg-color": "#E5E8EF",
            "--accent-bg-color": "#4480F4", "--accent-fg-color": "#EAEDF5", "--window-fg-color": "#5D5D5F"}
    got = {k: (re.search(r"^\s*%s:\s*([^;]+);" % re.escape(k), t, re.M) or [None, None])[1] for k in want}
    check("C26.writes-the-stylesheet-from-the-pairs-tokens", rc == 0 and got == want, (rc, got, out[-200:]))
    check("C26.says-what-it-is", t.startswith("/* Generated by themectl from theme eva (light)"), t[:80])
    rc, out, _ = ctl(root, "set", "monokai", "light", "--only", "libadwaita")
    t = rd(css) or ""
    # monokai light: the warning yellow reads 4.3:1 with the dark text and 3.3:1 with the light text-on-accent; the accent keeps the shell's text
    check("C26.a-status-colour-takes-the-ink-that-reads-best", "--warning-fg-color: #29242A;" in t and "--success-fg-color: #29242A;" in t, t[-900:])
    check("C26.the-accent-keeps-the-shells-text-on-accent", "--accent-fg-color: #FAF4F2;" in t, t[:900])
    rc, out, _ = ctl(root, "set", "monokai", "light", "--only", "libadwaita")
    check("C26.again-says-unchanged", "unchanged" in lines_of(out).get("libadwaita", ""), out[-200:])
    bad = {}
    for n in sorted(x[:-5] for x in os.listdir(TREE + "/themes") if x.endswith(".json")):
        for m in ("light", "dark"):
            rc, out, _ = ctl(root, "set", n, m, "--only", "libadwaita")
            vals = re.findall(r"^\s*(--[a-z-]+):\s*([^;]+);", rd(css) or "", re.M)
            if rc != 0 or len(vals) < 30 or any(not re.match(r"^#[0-9A-F]{6}$", v) for _, v in vals):
                bad[(n, m)] = (rc, len(vals), [v for _, v in vals if not re.match(r"^#[0-9A-F]{6}$", v)][:3], out[-160:])
    check("C26.every-pair-and-mode-writes-only-plain-colours", not bad, bad)
    rc, out, _ = ctl(root, "restore", "libadwaita")
    check("C26.restore-takes-away-a-file-that-was-not-there", rc == 0 and not os.path.lexists(css), (rc, out[-200:]))
    # a stylesheet of the user's own is kept and comes back byte for byte
    root2 = sandbox()
    css2 = home(root2) + "/.config/gtk-4.0/gtk.css"
    mine = "/* mine */\nwindow { margin: 1px; }\n"
    open(css2, "w").write(mine)
    ctl(root2, "set", "riso", "dark", "--only", "libadwaita")
    check("C26.replaces-the-users-own-file", "--accent-bg-color: #FF5CB8;" in (rd(css2) or ""), (rd(css2) or "")[:200])
    rc, out, _ = ctl(root2, "restore", "libadwaita")
    check("C26.restore-puts-the-users-own-file-back", rd(css2) == mine, rd(css2))
    # the shape the user's home had: a dangling link from an old install script's --libadwaita
    root3 = sandbox()
    css3 = home(root3) + "/.config/gtk-4.0/gtk.css"
    os.symlink("/usr/share/themes/No-Such-Theme/gtk-4.0/gtk.css", css3)
    rc, out, _ = ctl(root3, "set", "eva", "dark", "--only", "libadwaita")
    check("C26.a-dangling-link-becomes-a-file-themectl-owns", rc == 0 and not os.path.islink(css3) and "--window-bg-color: #2C3037;" in (rd(css3) or ""), (rc, out[-200:]))
    rc, out, _ = ctl(root3, "restore", "libadwaita")
    check("C26.restore-puts-the-link-back", os.path.islink(css3) and os.readlink(css3) == "/usr/share/themes/No-Such-Theme/gtk-4.0/gtk.css", (rc, out[-200:]))
    rc, out, _ = ctl(sandbox(), "doctor")
    check("C26.doctor-knows-the-target", re.search(r"^ok\s+libadwaita\s", out, re.M) is not None, out[-300:])



# ---- C27: several wallpapers per slot, drawn from a shuffle bag (the veils' bag ported: tools/dev/themectl_bag_parity.py holds the two together)

WP_LIST = '''{
    // the user's own comments
    "theme": {
        "wallpapers": {
            "eva": {
                "light": ["~/Pictures/a.png", "~/Pictures/b.png"],   // two
                "dark": ["~/Pictures/c.png", "~/Pictures/d.png", "~/Pictures/e.png"]
            }
        }
    }
}
'''


def _wp_root(text=WP_LIST, names=("a", "b", "c", "d", "e"), state=("eva", "light")):
    root = sandbox()
    h = home(root)
    for i, n in enumerate(names):
        _png(h + "/Pictures/%s.png" % n, rgb=(40 * i, 90, 160))
    put_shell(root, text)
    with open(h + "/.config/theme/state.json", "w") as f:
        f.write(json.dumps({"theme": state[0], "mode": state[1]}, indent=2) + "\n")
    return root, h


def _hp_shown(root, **extra):
    """What the stub's hyprpaper model lists (`hyprctl hyprpaper listactive`), as hyprpaper prints it."""
    return sbx.run(root, ["hyprctl", "hyprpaper", "listactive"], extra=extra).stdout.strip()


def _hp_seed(root, entries):
    """The stub hyprpaper's state: [(monitor or "*" for the fallback, path)]."""
    with open(root + "/hyprpaper.state", "w") as f:
        f.write("".join("%s\t%s\n" % e for e in entries))


def _shown(root):
    """The picture hyprpaper was told last (a file name), or None."""
    calls = [c for c in sbx.stublog(root) if c[:3] == ["hyprctl", "hyprpaper", "wallpaper"]]
    return os.path.basename(calls[-1][3].split(",")[1]) if calls else None


def c27():
    """A slot may hold a list: the wallpaper target draws from the slot's bag on a theme or mode switch and on a new Hyprland session, keeps
    the pick otherwise; a missing file is left out; a dry run draws nothing."""
    root, h = _wp_root()
    light = []
    for i in range(20):                                   # light, dark, light, ...: every light is a switch, so every light draws
        ctl(root, "set", "eva", "light", "--only", "wallpaper")
        light.append(_shown(root))
        ctl(root, "set", "eva", "dark", "--only", "wallpaper")
    check("C27.two-pictures-alternate-across-every-seam", all(a != b for a, b in zip(light, light[1:])) and set(light) == {"a.png", "b.png"}, light)
    root, h = _wp_root()                                 # a fresh bag: its first draw starts a round
    dark = []
    for i in range(12):
        ctl(root, "set", "eva", "light", "--only", "wallpaper")
        ctl(root, "set", "eva", "dark", "--only", "wallpaper")
        dark.append(_shown(root))
    rounds = [dark[i:i + 3] for i in range(0, 12, 3)]
    check("C27.each-round-of-three-shows-all-three", all(sorted(r) == ["c.png", "d.png", "e.png"] for r in rounds), dark)
    check("C27.no-picture-twice-in-a-row", all(a != b for a, b in zip(dark, dark[1:])), dark)
    # the same theme and mode again in the same session: kept; a new session (another HYPRLAND_INSTANCE_SIGNATURE): drawn
    root, h = _wp_root()
    s = {"HYPRLAND_INSTANCE_SIGNATURE": "sessionA"}
    ctl(root, "apply", "--only", "wallpaper", extra=s)
    first = _shown(root)
    rc, out, _ = ctl(root, "apply", "--only", "wallpaper", extra=s)
    check("C27.a-second-apply-in-the-same-session-keeps-the-picture", rc == 0 and _shown(root) == first and "[kept:" in out, (first, _shown(root), out[-160:]))
    rc, out, _ = ctl(root, "apply", "--only", "wallpaper", extra={"HYPRLAND_INSTANCE_SIGNATURE": "sessionB"})
    check("C27.a-new-session-draws", rc == 0 and _shown(root) not in (None, first) and "[drawn:" in out, (first, _shown(root), out[-160:]))
    bag = jl(h + "/.local/state/theme/wallpaper-bag.json")
    check("C27.the-bag-records-the-pick-the-slot-and-the-session", bag.get("shown") == ["eva", "light"] and bag.get("instance") == "sessionB"
          and bag.get("slots", {}).get("eva.light", {}).get("last") == h + "/Pictures/" + _shown(root), bag)
    # a dry run (diff, doctor) draws nothing and keeps nothing
    before = rd(h + "/.local/state/theme/wallpaper-bag.json")
    ctl(root, "diff", "eva", "dark")
    ctl(root, "doctor")
    check("C27.diff-and-doctor-keep-the-bag", rd(h + "/.local/state/theme/wallpaper-bag.json") == before, before)
    # a missing file is left out of the draw (and named); all missing is a FAIL
    root, h = _wp_root(names=("a",))
    rc, out, _ = ctl(root, "set", "eva", "light", "--only", "wallpaper")
    ln = lines_of(out)["wallpaper"]
    check("C27.a-missing-file-is-left-out-and-named", rc == 0 and ln.startswith("ok") and "1 not found: b.png" in ln and _shown(root) == "a.png", ln)
    rc, out, _ = ctl(root, "set", "eva", "dark", "--only", "wallpaper")
    check("C27.all-missing-is-a-fail", rc == 1 and "none of the 3 wallpaper files" in lines_of(out)["wallpaper"], out[-200:])
    # `wallpaper list`: the slot, the pick, what is still to come
    root, h = _wp_root(state=("eva", "dark"))
    ctl(root, "apply", "--only", "wallpaper")
    rc, out, _ = ctl(root, "wallpaper", "list")
    marked = [l[2:] for l in out.splitlines() if l.startswith("* ")]
    check("C27.list-marks-the-picture-on-screen", rc == 0 and marked == ["~/Pictures/%s" % _shown(root)] and "2 still to come" in out, out)


# ---- C28: `wallpaper remove`

def c28():
    """`themectl wallpaper remove <image>` (yazi's "Remove from wallpapers"): the item leaves the list by a text edit; the picture on screen is
    replaced by the next draw; the last one of a slot, and a picture not in the list, are refused with nothing written."""
    J = _jsonc()
    root, h = _wp_root(state=("eva", "dark"))
    cfg = h + "/.config/quickshell/shell.jsonc"
    ctl(root, "apply", "--only", "wallpaper")
    on = _shown(root)
    other = next(n for n in ("c.png", "d.png", "e.png") if n != on)
    before = rd(cfg)
    rc, out, _ = ctl(root, "wallpaper", "remove", "--no-notify", h + "/Pictures/" + other)
    after = rd(cfg)
    check("C28.removing-a-picture-takes-it-out-of-the-list", rc == 0 and J.loads(after)["theme"]["wallpapers"]["eva"]["dark"] == [x for x in ("~/Pictures/c.png", "~/Pictures/d.png", "~/Pictures/e.png") if not x.endswith(other)]
          and "// the user's own comments" in after and "// two" in after, (rc, out[-200:], after))
    check("C28.removing-another-picture-keeps-the-one-on-screen", _shown(root) == on, (on, _shown(root)))
    rc, out, _ = ctl(root, "wallpaper", "remove", "--no-notify", h + "/Pictures/" + on)
    check("C28.removing-the-picture-on-screen-shows-another", rc == 0 and _shown(root) not in (None, on) and "on screen now" in out, (on, _shown(root), out[-200:]))
    last = _shown(root)
    mid = rd(cfg)
    sbx.clear_stublog(root)
    rc, out, _ = ctl(root, "wallpaper", "remove", h + "/Pictures/" + last)
    notes = [c for c in sbx.stublog(root) if c[0] == "notify-send"]
    check("C28.the-last-picture-is-refused-and-nothing-written", rc == 100 and rd(cfg) == mid and "only" in out and notes and any("not removed" in a for a in notes[0]), (rc, out[-200:], notes))
    rc, out, _ = ctl(root, "wallpaper", "remove", "--no-notify", h + "/Pictures/a.png")
    check("C28.a-picture-of-another-slot-is-refused", rc == 100 and rd(cfg) == mid and "not one of the eva dark wallpapers" in out, out[-200:])
    # the yazi view follows a remove
    lst = rd(h + "/.local/state/theme/wallpapers-active.txt") or ""
    check("C28.the-list-for-yazi-follows", (h + "/Pictures/" + last) in lst and (h + "/Pictures/" + on) not in lst and (h + "/Pictures/" + other) not in lst, lst)


# ---- C29: a pair renamed in the repo (monokai-pro -> monokai) is carried over by `install`

def _git_show(rev, path):
    r = subprocess.run(["git", "-C", REPO, "show", "%s:%s" % (rev, path)], capture_output=True)
    return r.stdout if r.returncode == 0 else None


def c29():
    """`themectl install` with RENAMES: the old copy leaves (into the backup; an edited one becomes the new name's copy), state.json, shell.jsonc's
    wallpaper key, the bag and the btop / fastfetch files and links follow, the manifest forgets the old paths: no ghost pair, not even after a
    restore. A home made as the real one was on 2026-11-08 (installed and applied with the old name)."""
    old_json = _git_show("e8650ce5", "themes/monokai-pro.json")
    check("C29.the-shipped-copy-is-at-hand", old_json is not None and __import__("hashlib").sha256(old_json).hexdigest() in MOD.RENAMES[0]["shipped"], None)
    if old_json is None:
        return

    def old_home(edited=False):
        root = sandbox("post")
        h = home(root)
        th = h + "/.config/theme/themes"
        os.makedirs(th, exist_ok=True)
        if os.path.exists(th + "/monokai.json"):           # the real home was installed before the repo had the new name
            os.remove(th + "/monokai.json")
        os.makedirs(h + "/.config/theme/backup/files", exist_ok=True)
        data = old_json.replace(b'"surface": "#FAF4F2"', b'"surface": "#FAF4F3"', 1) if edited else old_json
        open(th + "/monokai-pro.json", "wb").write(data)
        for f in ("monokai-pro-light.theme", "monokai-pro.theme"):
            open(h + "/.config/btop/themes/" + f, "w").write("# old\n")
        for f in ("archlogo_monokai-pro_light.png", "archlogo_monokai-pro_dark.png"):
            open(h + "/.config/fastfetch/" + f, "wb").write(b"\x89PNG")
        for link, to in ((h + "/.config/btop/themes/current.theme", "monokai-pro.theme"), (h + "/.config/fastfetch/archlogo_current.png", "archlogo_monokai-pro_dark.png")):
            if os.path.lexists(link):
                os.remove(link)
            os.symlink(to, link)
        man = jl(h + "/.config/theme/backup/manifest.json")
        for p in (th + "/monokai-pro.json",):
            man[p] = {"kind": "file", "backup": "files/999-monokai-pro.json", "at": "2026-11-07T00:00:00"}
            open(h + "/.config/theme/backup/files/999-monokai-pro.json", "wb").write(old_json)
        for f in ("btop/themes/monokai-pro.theme", "fastfetch/archlogo_monokai-pro_dark.png"):
            man[h + "/.config/" + f] = {"kind": "absent", "at": "2026-11-07T00:00:00"}
        open(h + "/.config/theme/backup/manifest.json", "w").write(json.dumps(man, indent=2, sort_keys=True) + "\n")
        open(h + "/.config/theme/state.json", "w").write('{\n  "theme": "monokai-pro",\n  "mode": "dark"\n}\n')
        for n in ("a", "b"):
            _png(h + "/Pictures/%s.png" % n)
        put_shell(root, '{\n    "theme": {\n        "wallpapers": {\n            // mine\n            "monokai-pro": { "dark": "~/Pictures/a.png" },\n            "eva": { "light": "~/Pictures/b.png" }\n        }\n    }\n}\n')
        os.makedirs(h + "/.local/state/theme", exist_ok=True)
        open(h + "/.local/state/theme/wallpaper-bag.json", "w").write(json.dumps({"version": 1, "shown": ["monokai-pro", "dark"], "instance": "",
                                                                                  "slots": {"monokai-pro.dark": {"round": [], "remaining": [], "last": "x"}}}))
        return root, h
    root, h = old_home()
    rc, out, _ = ctl(root, "install")
    names = [x["name"] for x in json.loads(ctl(root, "list", "--json")[1])["themes"]]
    check("C29.no-ghost-pair-after-install", rc == 0 and "monokai" in names and "monokai-pro" not in names, (rc, names, out[-400:]))
    check("C29.state-follows", json.load(open(h + "/.config/theme/state.json")) == {"theme": "monokai", "mode": "dark"}, rd(h + "/.config/theme/state.json"))
    sh = rd(h + "/.config/quickshell/shell.jsonc") or ""
    check("C29.the-wallpaper-key-follows-and-the-comments-stay", '"monokai": { "dark": "~/Pictures/a.png" }' in sh and "// mine" in sh and "monokai-pro" not in sh, sh)
    bag = jl(h + "/.local/state/theme/wallpaper-bag.json")
    check("C29.the-bag-follows", "monokai.dark" in bag.get("slots", {}) and "monokai-pro.dark" not in bag.get("slots", {}) and bag.get("shown") == ["monokai", "dark"], bag)
    bt = h + "/.config/btop/themes/"
    check("C29.btop-and-fastfetch-name-the-new-files", os.readlink(bt + "current.theme") == "monokai-dark.theme" and os.path.isfile(bt + "monokai-dark.theme")
          and not os.path.lexists(bt + "monokai-pro.theme") and os.readlink(h + "/.config/fastfetch/archlogo_current.png") == "archlogo_monokai_dark.png"
          and os.path.isfile(h + "/.config/fastfetch/archlogo_monokai_dark.png"), sorted(os.listdir(bt)))
    aside = sorted(os.listdir(h + "/.config/theme/backup/renamed")) if os.path.isdir(h + "/.config/theme/backup/renamed") else []
    check("C29.the-old-files-are-kept-in-the-backup", any(x.endswith("-monokai-pro.json") for x in aside) and any(x.endswith("-monokai-pro.theme") for x in aside), aside)
    man = jl(h + "/.config/theme/backup/manifest.json")
    check("C29.the-manifest-forgets-the-old-paths", not [p for p in man if "monokai-pro" in p], [p for p in man if "monokai-pro" in p])
    rc, out, _ = ctl(root, "install")
    check("C29.a-second-install-has-nothing-to-rename", rc == 0 and "rename monokai-pro" not in out, out[-300:])
    ctl(root, "restore")
    check("C29.restore-brings-no-ghost-back", not os.path.exists(h + "/.config/theme/themes/monokai-pro.json"), sorted(os.listdir(h + "/.config/theme/themes")))
    rc, out, _ = ctl(root, "set", "monokai", "dark")
    check("C29.the-renamed-pair-applies", rc == 0, out[-300:])
    # a copy the user edited (a mockup's Save wrote into it) is carried over under the new name
    root, h = old_home(edited=True)
    rc, out, _ = ctl(root, "install")
    got = jl(h + "/.config/theme/themes/monokai.json")
    check("C29.an-edited-copy-is-carried-over-renamed-inside", rc == 0 and got.get("name") == "monokai" and got.get("light", {}).get("surface") == "#FAF4F3"
          and got.get("assets", {}).get("dark", {}).get("btopTheme") == "monokai-dark.theme" and "carry your edited" in out, (rc, got.get("name"), out[-300:]))
    # before the install, doctor says the rename is pending
    root, h = old_home()
    rc, out, _ = ctl(root, "doctor")
    check("C29.doctor-says-the-rename-waits-for-install", re.search(r"^note\s+rename\s+monokai-pro is monokai now", out, re.M) is not None, out[-600:])


# ---- C30: nwg-look kept in step

NWG_GSETTINGS = """# Generated by nwg-look, do not edit this file.
gtk-theme=XFCE_Colour_Lite_Doder
icon-theme=Papirus
font-name=Adwaita Sans 11
cursor-theme=Nordzy-cursors-white
cursor-size=36
toolbar-style=both-horiz
color-scheme=prefer-light
theme-name=freedesktop
event-sounds=true
"""
NWG_CONFIG = """{
 "export-settings-ini": true,
 "export-gtk4-symlinks": true,
 "export-nwg-hello-sound-config": true,
 "flatpak-install-current-gtk-theme": false
}"""


def c30():
    """The nwg-look target: nwg-look's stored settings (what `nwg-look -a` applies) carry the pair's gtk-theme, icon-theme and color-scheme, every
    other line as nwg-look wrote it; its config's export-gtk4-symlinks is off (the original kept for restore); no nwg-look files is skipped."""
    root = sandbox()
    h = home(root)
    gs, cf = h + "/.local/share/nwg-look/gsettings", h + "/.config/nwg-look/config"
    os.makedirs(os.path.dirname(gs))
    os.makedirs(os.path.dirname(cf))
    open(gs, "w").write(NWG_GSETTINGS)
    open(cf, "w").write(NWG_CONFIG)
    rc, out, _ = ctl(root, "set", "eva", "dark")
    got = rd(gs) or ""
    check("C30.the-stored-settings-carry-the-pair", rc == 0 and "\nicon-theme=Papirus-Dark\n" in got and "\ncolor-scheme=prefer-dark\n" in got
          and re.search(r"^gtk-theme=(.+)$", got, re.M).group(1) == sbx.run(root, ["gsettings", "get", "org.gnome.desktop.interface", "gtk-theme"]).stdout.strip().strip("'"), got)
    keep = [l for l in NWG_GSETTINGS.splitlines() if l.split("=")[0] not in ("gtk-theme", "icon-theme", "color-scheme")]
    check("C30.every-other-line-stays", [l for l in got.splitlines() if l.split("=")[0] not in ("gtk-theme", "icon-theme", "color-scheme")] == keep, got)
    cfg = rd(cf) or ""
    check("C30.export-gtk4-symlinks-is-switched-off", json.loads(cfg) == dict(json.loads(NWG_CONFIG), **{"export-gtk4-symlinks": False})
          and cfg == NWG_CONFIG.replace('"export-gtk4-symlinks": true', '"export-gtk4-symlinks": false'), cfg)
    rc, out, _ = ctl(root, "set", "eva", "dark")
    check("C30.again-changes-nothing", "unchanged" in lines_of(out).get("nwg-look", "") and "export-gtk4-symlinks off" in lines_of(out).get("nwg-look", ""), lines_of(out).get("nwg-look"))
    ctl(root, "restore", "nwg-look")
    check("C30.restore-puts-the-config-back", rd(cf) == NWG_CONFIG, rd(cf))
    root2 = sandbox()
    rc, out, _ = ctl(root2, "set", "eva", "dark")
    check("C30.no-nwg-look-is-skipped", rc == 0 and "skipped" in lines_of(out).get("nwg-look", ""), lines_of(out).get("nwg-look"))


# ---- C31: yazi's side of the wallpapers (the plugin, the opener, the generated rules)

YAZI_TOML = """[mgr]
ratio = [0, 2, 1]

[opener]
edit = [
    { run = "nano %s", block = true, orphan = true, desc = "nano" },
]
image = [
    { run = "loupe %s", block = false, orphan = true, desc = "view image" },
    { run = '/home/x/.local/state/lares/shell/current/tools/theme/themectl wallpaper set %s', block = false, orphan = true, desc = "Set as wallpaper" },
]

[open]
prepend_rules = [
    { url = "*.pdf", use = "pdf" },
    { mime = "image/*", use = "image" },
]

[input]
cursor_blink = true
"""


# ---- C32: the evince target (inverted colours by mode)

def c32():
    """The `evince` target in the sandbox: gsettings org.gnome.Evince.Default inverted-colors follows the mode (dark inverts), a second run is
    unchanged, no Evince schema is 'skipped'. The per-document copies and the open windows need GVfs and evince itself: they are proven on the
    real program in tools/dev/themectl_evince_env_probe.sh (here no session bus and no recent list: those passes find nothing)."""
    root = sandbox()

    def inv():
        return sbx.run(root, ["gsettings", "get", "org.gnome.Evince.Default", "inverted-colors"],
                       extra={"XDG_DATA_DIRS": root + "/sysdata"}).stdout.strip()
    last = home(root) + "/.local/state/theme/evince-last"

    def worker_said(word):                            # the background half (`themectl _evince`) has run and says WORD
        return _wait(lambda: word in (rd(last) or ""))
    rc, out, _ = ctl(root, "set", "eva", "dark", "--only", "evince")
    ln = lines_of(out).get("evince", "")
    check("C32.dark-inverts-the-default", rc == 0 and ln.startswith("ok") and "set inverted" in ln and "in the background" in ln
          and worker_said("set inverted: the default") and inv() == "true", (rc, ln, rd(last), inv()))
    os.remove(last)
    rc, out, _ = ctl(root, "set", "eva", "dark", "--only", "evince")
    time.sleep(1.0)
    check("C32.again-is-unchanged-and-starts-nothing", rc == 0 and "unchanged: inverted" in lines_of(out).get("evince", "") and rd(last) is None,
          (out[-200:], rd(last)))
    rc, out, _ = ctl(root, "set", "eva", "light", "--only", "evince")
    check("C32.light-puts-it-back", rc == 0 and worker_said("set not inverted: the default") and inv() == "false", (out[-200:], rd(last), inv()))
    tsv = rd(home(root) + "/.local/state/theme/last-run.tsv") or ""
    check("C32.every-real-run-records-what-each-target-cost", re.search(r"(?m)^evince\t\d+\tok$", tsv) is not None and tsv.startswith("# eva light"), tsv)
    empty = os.path.join(WORK, "noschemas")
    os.makedirs(empty, exist_ok=True)
    rc, out, _ = ctl(root, "set", "eva", "dark", "--only", "evince", extra={"XDG_DATA_DIRS": empty})        # no Evince schema XML
    check("C32.no-evince-is-skipped", rc == 0 and "skipped: evince is not installed" in lines_of(out).get("evince", ""), out[-200:])


def c33():
    """shell.jsonc's "theme": "targets" (which programs a switch touches) and "pairs" (which pairs `next` goes through, in which order)."""
    root = sandbox()
    conf = home(root) + "/.config/quickshell/config/shell.jsonc"
    os.makedirs(os.path.dirname(conf), exist_ok=True)

    def say(obj):
        with open(conf, "w") as f:
            f.write("// mine\n" + json.dumps({"theme": obj}))
    say({"targets": {"kitty": False, "lares": False, "zebra": False}})
    rc, out, _ = ctl(root, "set", "eva", "dark", "--only", "kitty,lares,btop")
    ln = lines_of(out)
    check("C33.only-runs-a-target-that-is-off", "skipped" not in ln.get("kitty", ""), out[-300:])
    rc, out, _ = ctl(root, "diff")
    ln = lines_of(out)
    check("C33.a-target-that-is-off-is-skipped-and-says-so", "skipped (off in shell.jsonc" in ln.get("kitty", "") and "skipped" not in ln.get("lares", ""), (ln.get("kitty"), ln.get("lares")))
    rc, out, _ = ctl(root, "list", "--json")
    en = {t["name"]: t["enabled"] for t in json.loads(out)["targets"]}
    check("C33.list-knows-it", en["kitty"] is False and en["lares"] is True and en["btop"] is True, en)
    say({"pairs": ["paper", "nosuch", "eva"]})
    seen = []
    for _i in range(3):
        rc, out, _ = ctl(root, "next", "--only", "lares")
        seen.append(jl(home(root) + "/.config/theme/state.json")["theme"])
    check("C33.next-follows-the-list", seen == ["paper", "eva", "paper"], seen)
    say({"pairs": ["nosuch"]})
    rc, out, _ = ctl(root, "next", "--only", "lares")
    check("C33.a-list-with-nothing-that-is-there-is-every-pair", jl(home(root) + "/.config/theme/state.json")["theme"] not in ("paper", "nosuch"), out[-200:])


def c31():
    """`install` sets yazi up once (plugin copied, the wallpaper-listed opener, the BEGIN / END marks at the top of [open] prepend_rules, the
    init.lua line; originals kept); the yazi target then keeps the rules and the plugin's list on the current slot, on every switch, set and
    remove. The plugin drawing its mark in the real yazi is tools/dev/themectl_yazi_probe.py."""
    import tomllib
    root, h = _wp_root(names=("a", "b", "c", "d", "e"))
    yd = h + "/.config/yazi"
    os.makedirs(yd)
    open(yd + "/yazi.toml", "w").write(YAZI_TOML)
    open(yd + "/init.lua", "w").write('require("git"):setup()\n')
    rc, out, _ = ctl(root, "install")
    toml = rd(yd + "/yazi.toml") or ""
    doc = tomllib.loads(toml) if toml else {}
    rules = (doc.get("open") or {}).get("prepend_rules") or []
    want = [{"url": "\\s" + h + "/Pictures/a.png", "use": "wallpaper-listed"}, {"url": "\\s" + h + "/Pictures/b.png", "use": "wallpaper-listed"}]
    check("C31.install-sets-yazi-up", rc == 0 and os.path.isfile(yd + "/plugins/wallpapers.yazi/main.lua") and "wallpaper-listed" in doc.get("opener", {})
          and 'require("wallpapers")' in (rd(yd + "/init.lua") or "") and rd(yd + "/init.lua").startswith('require("git"):setup()\n'), (rc, out[-500:]))
    check("C31.the-listed-pictures-come-first-in-the-rules", rules[:2] == want and rules[2:] == [{"url": "*.pdf", "use": "pdf"}, {"mime": "image/*", "use": "image"}], rules)
    op = doc.get("opener", {}).get("wallpaper-listed", [])
    check("C31.enter-views-and-the-second-entry-removes", len(op) == 2 and op[0].get("run") == "loupe %s" and op[1].get("desc") == "Remove from wallpapers"
          and op[1].get("run") == "/home/x/.local/state/lares/shell/current/tools/theme/themectl wallpaper remove %s", op)
    check("C31.the-rest-of-yazi-toml-is-untouched", _subseq(YAZI_TOML, toml) and doc.get("opener", {}).get("image") == tomllib.loads(YAZI_TOML)["opener"]["image"], toml)
    lst = rd(h + "/.local/state/theme/wallpapers-active.txt") or ""
    check("C31.the-plugins-list-is-the-current-slot", [l for l in lst.splitlines() if not l.startswith("#")] == [h + "/Pictures/a.png", h + "/Pictures/b.png"], lst)
    rc, out, _ = ctl(root, "install")
    check("C31.a-second-install-finds-it-done", rc == 0 and "already set up" in out and rd(yd + "/yazi.toml") == toml, out[-300:])
    rc, out, _ = ctl(root, "toggle")
    rules = tomllib.loads(rd(yd + "/yazi.toml"))["open"]["prepend_rules"]
    check("C31.the-rules-follow-a-mode-switch", [r["url"] for r in rules[:3]] == ["\\s%s/Pictures/%s.png" % (h, n) for n in ("c", "d", "e")] and rules[3] == {"url": "*.pdf", "use": "pdf"}, rules)
    # a picture with glob characters in its name is matched exactly; set and remove keep the rules on the list
    odd = h + "/Pictures/x[1]*{a}?.png"
    _png(odd)
    ctl(root, "wallpaper", "set", "--no-notify", odd)
    rules = tomllib.loads(rd(yd + "/yazi.toml"))["open"]["prepend_rules"]
    check("C31.set-adds-its-rule-with-the-glob-characters-escaped", {"url": "\\s%s/Pictures/x[[]1[]][*][{]a[}][?].png" % h, "use": "wallpaper-listed"} in rules, rules[:5])
    ctl(root, "wallpaper", "remove", "--no-notify", odd)
    rules = tomllib.loads(rd(yd + "/yazi.toml"))["open"]["prepend_rules"]
    check("C31.remove-takes-its-rule-out", not [r for r in rules if "x[[]1" in r.get("url", "")] and len(rules) == 5, rules)
    # restore puts yazi.toml and init.lua back
    ctl(root, "restore")
    check("C31.restore-puts-yazi-back", rd(yd + "/yazi.toml") == YAZI_TOML and rd(yd + "/init.lua") == 'require("git"):setup()\n'
          and not os.path.exists(yd + "/plugins/wallpapers.yazi/main.lua"), rd(yd + "/yazi.toml")[:300])
    # a prepend_rules on one line cannot take the marks: install says so and writes nothing
    root, h = _wp_root()
    yd = h + "/.config/yazi"
    os.makedirs(yd)
    one = YAZI_TOML.replace('prepend_rules = [\n    { url = "*.pdf", use = "pdf" },\n    { mime = "image/*", use = "image" },\n]', 'prepend_rules = [ { url = "*.pdf", use = "pdf" } ]')
    open(yd + "/yazi.toml", "w").write(one)
    rc, out, _ = ctl(root, "install")
    check("C31.a-one-line-rule-list-is-refused-with-nothing-written", rc != 0 and rd(yd + "/yazi.toml") == one and "one rule a line" in out and not os.path.exists(yd + "/init.lua"), (rc, out[-300:]))
    # no yazi config: install and apply say so, nothing fails
    root, h = _wp_root()
    rc, out, _ = ctl(root, "install")
    check("C31.no-yazi-is-no-failure", rc == 0 and "yazi is not set up" in out and not os.path.exists(h + "/.config/yazi"), out[-300:])


# ==================================================================================================================== arms

ARMS = {
    "inkfixed": ("|ink always gives the text on accent",
                 [('            return fmt_colour(max(inks, key=lambda c: wcag_contrast(v, c)), "")', '            return fmt_colour(inks[1], "")')],
                 ["C26.a-status-colour-takes-the-ink-that-reads-best"]),
    "nonatomic": ("write_atomic writes the file in place",
                  [('    d = os.path.dirname(path)\n    os.makedirs(d, exist_ok=True)\n    fd, tmp = tempfile.mkstemp(prefix=".themectl-", dir=d)',
                    '    d = os.path.dirname(path)\n    os.makedirs(d, exist_ok=True)\n    with open(path, "wb") as f:\n        f.write(data if isinstance(data, bytes) else data.encode("utf-8"))\n    os.chmod(path, mode if mode is not None else 0o644)\n    return\n    fd, tmp = tempfile.mkstemp(prefix=".themectl-", dir=d)')],
                  ["C6.a-failed-write-leaves-the-old-file-whole", "C6.replaces-a-symlink-not-its-target"]),
    "nobackup": ("the first write keeps no original",
                 [('    man = load_manifest(P)\n    if path in man:\n        return False\n', '    return False\n    man = load_manifest(P)\n    if path in man:\n        return False\n')],
                 ["C7.keeps-the-original-file", "C7.symlink-recorded-as-a-link", "C7.btop-file-is-replaced-by-the-link-and-kept", "C7.btop-symlink-is-replaced-by-the-link-and-kept",
                  "C17.the-one-liner-keeps-the-originals-the-real-one-kept", "C17.the-first-toggle-keeps-nothing-more",
                  "C17.restore-undoes-the-whole-switch-over"]),
    "targetson": ("shell.jsonc's theme.targets is not read",
                  [('isinstance(off, dict) and off.get(spec["name"]) is False', 'False')],
                  ["C33.a-target-that-is-off-is-skipped-and-says-so", "C33.list-knows-it"]),
    "pairsignored": ("`next` ignores shell.jsonc's theme.pairs",
                     [('    return listed or names\n', '    return names\n')],
                     ["C33.next-follows-the-list"]),
    "failhidden": ("the exit status ignores the FAILs",
                   [('    print("themectl: %s %s: %s" % (name, mode, "all ok" if fails == 0 else "%d FAIL" % fails))\n    return min(fails, 99)\n\n\ndef cmd_apply',
                     '    print("themectl: %s %s: %s" % (name, mode, "all ok" if fails == 0 else "%d FAIL" % fails))\n    return 0\n\n\ndef cmd_apply')],
                   ["C8.exit-status-counts-the-fails", "C8.unwritable-output"]),
    "roundhalfeven": ("alpha rounds half to even (Python round)",
                      [('def _rnd(x):\n    return int(math.floor(x + 0.5))', 'def _rnd(x):\n    return int(round(x))')],
                      ["C2.alpha_half"]),
    "nocycleguard": ("an alias cycle is not detected",
                     [('    if key in seen:\n        errs[0] = \'"%s" aliases in a circle\' % key\n        return None\n', '')],
                     ["C2.cycle", "C2.self"]),
    "clobber": ("install overwrites a newer file",
                [('        if os.path.getmtime(d) > os.path.getmtime(s):', '        if False:')],
                ["C9.install_newer"]),
    "outside": ("outputs outside HOME are written",
                [('    if not any(real == r or real.startswith(r + "/") for r in roots):\n        raise Refused("%s is outside HOME" % path)', '    return')],
                ["C12.output-outside-home-is-refused", "C16.an-include-file-outside-home-is-refused"]),
    "locknop": ("the lock is never taken",
                [('        fcntl.flock(fd, fcntl.LOCK_EX)\n', '')],
                ["C10.lock-is-held-while-it-works"]),
    # btop is a link to the stock theme of the mode (C5, C15)
    "btopswap": ("each mode's btopTheme names the OTHER mode's stock theme",
                 [("themes/eva.json", '"btopTheme": "/usr/share/btop/themes/flat-remix-light.theme"', '"btopTheme": "@@SWAP@@"'),
                  ("themes/eva.json", '"btopTheme": "/usr/share/btop/themes/flat-remix.theme"', '"btopTheme": "/usr/share/btop/themes/flat-remix-light.theme"'),
                  ("themes/eva.json", '"btopTheme": "@@SWAP@@"', '"btopTheme": "/usr/share/btop/themes/flat-remix.theme"')],
                 ["C5.light.btop-links-to-the-stock-theme-of-the-mode", "C5.dark.btop-links-to-the-stock-theme-of-the-mode", "C15.dark-links-the-dark-stock-theme",
                  "C15.light-moves-the-link-back-and-signals-again"]),
    "btopnosignal": ("a moved btop link signals nobody",
                     [('(("linked %s -> %s" % (out, target)) if changed else "unchanged: %s -> %s" % (out, target)) + _do_reload(spec, ctx, out, changed) + _include_note(spec, P), diff',
                       '(("linked %s -> %s" % (out, target)) if changed else "unchanged: %s -> %s" % (out, target)) + _include_note(spec, P), diff')],
                     ["C15.a-moved-link-signals-btop-once", "C15.light-moves-the-link-back-and-signals-again"]),
    "btopalways": ("btop is signalled on every apply, moved or not",
                   [("tools/theme/targets.json", '"when": "changed", "label": "pkill -USR2 btop"', '"when": "always", "label": "pkill -USR2 btop"')],
                   ["C15.an-unchanged-link-signals-nobody", "C17.a-further-apply-writes-nothing-and-signals-nobody"]),
    "btopfile": ("btop is a rendered file again, not the stock theme's link",
                 [("tools/theme/targets.json", '"type": "link",\n      "needs": ["btopTheme"],\n      "output": "${XDG_CONFIG_HOME}/btop/themes/current.theme",\n      "target": "{{assets.btopTheme}}",',
                   '"type": "file",\n      "template": "kitty-current-theme.conf",\n      "output": "${XDG_CONFIG_HOME}/btop/themes/current.theme",')],
                 ["C5.light.btop-links-to-the-stock-theme-of-the-mode", "C15.dark-links-the-dark-stock-theme", "C15.what-btop-reads-through-the-link-is-the-stock-file",
                  "C7.btop-file-is-replaced-by-the-link-and-kept"]),
    "btopdangle": ("a link to a stock theme that is not there is made anyway",
                   [('    if not installed and not os.path.exists(resolved):\n        raise Fail("%s does not exist (the link would dangle)" % resolved)\n', '')],
                   ["C15.a-missing-stock-theme-is-a-fail-and-links-nothing"]),
    "dryreload": ("a diff runs the reload it should only name",
                  [('    if ctx.dry:\n        return "; would run: " + " ".join(argv)\n', '')],
                  ["C15.diff-links-nothing-and-signals-nobody", "C9.diff-writes-nothing"]),
    "notalink": ("the diff of an output that is not there says it is not a link",
                 [('(" (a file, not a link)" if os.path.lexists(out) else " (absent)")', '" (not a link)"')],
                 ["C15.diff-links-nothing-and-signals-nobody"]),
    "btopneeds": ("the btop target does not say which asset it needs",
                  [("tools/theme/targets.json", '"type": "link",\n      "needs": ["btopTheme"],\n      "output": "${XDG_CONFIG_HOME}/btop/themes/current.theme"', '"type": "link",\n      "output": "${XDG_CONFIG_HOME}/btop/themes/current.theme"')],
                  ["C8.a-bare-theme-says-what-it-lacks"]),
    "norestorefile": ("restore takes a link away and puts a kept file back nowhere",
                      [('                    if e["kind"] == "file":\n                        os.makedirs(os.path.dirname(path), exist_ok=True)\n', '                    if False:\n                        os.makedirs(os.path.dirname(path), exist_ok=True)\n')],
                      ["C7.btop-restore-puts-back-the-file-and-not-the-link", "C7.restore-puts-back-file-link-and-absence", "C17.restore-undoes-the-whole-switch-over"]),
    "norestorelink": ("restore takes a link away and puts a kept link back nowhere",
                      [('                    elif e["kind"] == "symlink":\n', '                    elif False:\n')],
                      ["C7.btop-restore-puts-back-the-symlink-and-not-the-link", "C7.restore-puts-back-file-link-and-absence", "C17.restore-undoes-the-whole-switch-over"]),
    # the vscode target (C18)
    "vscodekept": ("the vscode target keeps the user's settings.json for restore",
                   [('    real = os.path.realpath(out)\n    try:\n        write_atomic(real, new, mode=stat.S_IMODE(os.stat(real).st_mode))', '    real = os.path.realpath(out)\n    own_file(P, real)\n    try:\n        write_atomic(real, new, mode=stat.S_IMODE(os.stat(real).st_mode))')],
                   ["C18.the-file-is-not-kept-for-restore", "C17.the-first-toggle-keeps-nothing-more"]),
    "vscodenested": ("a same-named key inside another object is taken for the key",
                     [('elif k == "s" and depth == 1 and toks[i - 1][0] in "{,":', 'elif k == "s" and toks[i - 1][0] in "{,":')],
                     ["C18.a-missing-key-is-added-first-and-a-nested-one-is-not-the-key"]),
    "vscodecomments": ("// comments are not skipped: a commented-out key is read",
                       [('        elif text.startswith("//", i):', '        elif False:')],
                       ["C18.dark-sets-the-line-and-only-the-line", "C18.the-users-shape-comments-trailing-commas-and-all"]),
    "vscoderewrite": ("the file is rewritten whole (parsed and dumped) instead of edited",
                      [('        new = jsonc_set(cur, key, want)', '        new = json.dumps(json.loads(re.sub(r",(\\s*[}\\]])", r"\\1", "\\n".join(l for l in cur.splitlines() if not l.strip().startswith("//")))), indent=4)')],
                      ["C18.light-puts-the-file-back-byte-for-byte", "C18.the-users-shape-comments-trailing-commas-and-all"]),
    # the wallpaper and the icon theme (C19)
    "wpnoipc": ("the wallpaper target writes hyprpaper's file but never tells the running daemon",
                [('    argv = [ctx.render(a, spec["name"]) for a in spec["argv"]]\n    if ctx.dry:\n        return msg + "; would run: "',
                  '    argv = [ctx.render(a, spec["name"]) for a in spec["argv"]]\n    if not ctx.dry:\n        return msg, diff\n    if ctx.dry:\n        return msg + "; would run: "')],
                ["C19.dark-tells-hyprpaper-the-dark-file"]),
    "wprunningfail": ("hyprpaper not running is a FAIL",
                      [('    if re.search(spec.get("notRunning", r"(?!x)x"), text):', '    if False:')],
                      ["C19.hyprpaper-not-running-is-ok-and-the-file-is-written"]),
    "wprelative": ("a relative wallpaper path is accepted",
                   [('        if not os.path.isabs(path):\n            raise Fail("%s: %s is not an absolute path (use ~/... or /...)" % (where, r))\n', '')],
                   ["C19.relative-path-is-a-fail-that-says-so"]),
    "wperrortext": ("an error text with exit 0 counts as success",
                    [('    if p.returncode == 0 and not re.search(r"(?i)\\berror\\b", text):', '    if p.returncode == 0:')],
                    ["C19.an-error-text-with-exit-0-is-a-fail-too"]),
    "inidup": ("a settings.ini key is appended even when the line is there",
               [('            if keyrx.match(l):\n                lines[i] = "%s=%s%s" % (key, value, nl if l.endswith("\\n") else "")\n                return "".join(lines)\n', '')],
               ["C19.the-ini-keeps-the-users-other-keys", "C19.ini_set-cases"]),
    "iniforget": ("a created settings.ini is not noted for restore",
                  [('            own_file(P, out)                        # a file themectl creates', '            pass                                    # a file themectl creates')],
                  ["C19.restore-takes-a-created-ini-away-and-leaves-the-users-own"]),
    "oldicons": ("the theme file names the icon pack that is not installed",
                 [("themes/eva.json", '"iconTheme": "Papirus-Dark"', '"iconTheme": "Colloid-Teal-Gruvbox-Dark"')],
                 ["C19.dark-icon-theme-is-Papirus-Dark-in-gsettings-and-both-ini-files", "C19.no-theme-asset-names-an-icon-pack-that-is-not-installed"]),
    # migrate (C16)
    "migratenobackup": ("migrate keeps no original of the files it edits",
                        [('own_file(P, e["path"])', 'pass')],
                        ["C16.the-originals-are-kept-the-way-themectl-keeps-its-own", "C16.restore-migrate-puts-back-every-byte-and-the-link",
                         "C17.the-one-liner-keeps-the-originals-the-real-one-kept", "C17.restore-undoes-the-whole-switch-over"]),
    "migratethroughlink": ("migrate writes through a symlink instead of replacing it",
                           [('write_atomic(e["path"], e["new"], mode)', 'open(e["path"], "w", encoding="utf-8").write(e["new"])')],
                           ["C16.hyprlock-becomes-a-file-with-the-source-line-and-the-body-and-hyprv-is-untouched", "C16.a-symlinked-config-becomes-a-file-and-its-target-is-left-alone"]),
    "migratedrywrites": ("--dry-run makes the edits",
                         [('    if args.dry_run or not todo:\n', '    if not todo:\n')],
                         ["C16.dry-run-writes-nothing-and-shows-the-diff"]),
    "migrateanchorless": ("an edit whose anchor is missing is reported and the others are made anyway",
                          [('            raise Refused("nothing written: ', '            return\n            raise Refused("nothing written: ')],
                          ["C16.refuses-a-hyprland-lua-without-the-appearance-line", "C16.refuses-a-hyprlock-conf-that-is-a-hand-edited-file"]),
    "migratenotidempotent": ("migrate does not look whether an edit is done",
                             [('        if text is not None and re.search(inc["pattern"], text, re.M):\n            e.update(state="done"', '        if False:\n            e.update(state="done"')],
                             ["C16.a-second-run-says-already-done-and-writes-nothing"]),
    "migrateunsafewrite": ("migrate writes a file whose original it could not keep",
                           [('raise Fail("cannot keep the original of %s (nothing written): %s" % (e["path"], ex))', 'pass')],
                           ["C16.no-backup-no-write"]),
    "restoremigrate": ("`restore migrate` restores nothing",
                       [('                    wanted |= migrate_paths(P)\n', '                    pass\n')],
                       ["C16.restore-migrate-puts-back-every-byte-and-the-link"]),
    "migratedarkbody": ("the hyprlock body is taken from evadark.conf",
                        [('    src = hv + "/evalight.conf"\n', '    src = hv + "/evadark.conf"\n')],
                        ["C16.hyprlock-becomes-a-file-with-the-source-line-and-the-body-and-hyprv-is-untouched", "C16.a-hyprlock-linked-to-the-dark-file-gets-the-light-body-without-its-invalid-options"]),
    "migratekittyjoin": ("the kitty include is glued to a last line with no newline",
                         [('return text + ("" if (not text or text.endswith("\\n")) else "\\n") + "include current-theme.conf\\n"', 'return text + "include current-theme.conf\\n"')],
                         ["C16.a-kitty-conf-without-the-include-gets-it-appended-and-restore-removes-it"]),
    "migratebtoploose": ("btop's recipe also takes a commented-out color_theme line",
                         [('    rx = re.compile(r\'^(\\s*color_theme\\s*=\\s*)"', '    rx = re.compile(r\'(\\s*color_theme\\s*=\\s*)"')],
                         ["C16.migrate-says-ok-for-each-edit-and-kitty-is-done-already", "C16.btop-names-the-link-and-nothing-else-moves"]),
    "migratefflose": ("fastfetch's recipe also takes a line inside a // comment",
                      [('    rx = re.compile(r\'^([ \\t]*"source"', '    rx = re.compile(r\'([ \\t]*"source"')],
                      ["C16.migrate-says-ok-for-each-edit-and-kitty-is-done-already", "C16.fastfetch-names-the-stable-link-and-the-commented-line-stays"]),
    # the shipped files (C22) and the group tab (C5, C21)
    "noship": ("a shipped btop theme is never copied next to the link",
               [('    if not os.path.exists(resolved) and spec.get("shipped") and "/" not in target:', '    if False:')],
               ["C22.first-use-copies-the-shipped-theme-owns-it-and-links-it", "C22.diff-names-the-install-and-writes-nothing"]),
    "shipclobber": ("a shipped file is copied over the user's copy on every apply",
                    [('    if not os.path.exists(resolved) and spec.get("shipped") and "/" not in target:', '    if spec.get("shipped") and "/" not in target:')],
                    ["C22.a-copy-that-is-there-is-used-as-it-is"]),
    "shipunowned": ("a shipped copy is not owned, so restore leaves it behind",
                    [('    guard_output(P, dst)\n    own_file(P, dst)\n', '    guard_output(P, dst)\n')],
                    ["C22.first-use-copies-the-shipped-theme-owns-it-and-links-it", "C22.restore-btop-takes-the-copies-away-and-the-link"]),
    "tabisborder": ("the group tab is the border colour again",
                    [("tools/theme/templates/hyprland-theme.lua", 'local group_tab = "{{hyprGroupTab|hex}}"', 'local group_tab = "{{hyprBorderActive|hex}}"')],
                    ["C5.light.the-group-tab-is-its-own-colour-and-the-locked-border-the-plain-one"]),
    "lockedisborder": ("everbox dark's locked tab is a green beside its green border",
                       [("themes/everbox.json", '"hyprBorderLocked": "@catFlatpak",\n        "hyprGroupTab": "@warn",\n        "lockBorder": "@hyprBorderInactive",\n        "lockIncorrect": "#FB4934"',
                         '"hyprBorderLocked": "#689D6A",\n        "hyprGroupTab": "@warn",\n        "lockBorder": "@hyprBorderInactive",\n        "lockIncorrect": "#FB4934"')],
                       ["C21.everbox.dark.the-group-tabs-stand-apart-from-the-border"]),
    "mutedfaint": ("catppuccin light's muted text is subtext0 again (4.37:1)",
                   [("themes/catppuccin.json", '"textMuted": "#676A81"', '"textMuted": "#6C6F85"')],
                   ["C21.catppuccin.light.muted-text-reads"]),
    "pkglastinstalled": ("an asset list takes the LAST installed entry instead of the first",
                         [("zip(v, states) if s), v[-1])", "zip(reversed(v), reversed(states)) if s), v[-1])")],
                         ["C23.both-installed-the-first-of-the-list-wins"]),
    "pkgalwaysfirst": ("an asset list takes its first entry whether it is installed or not",
                       [("zip(v, states) if s), v[-1])", "zip(v, states) if True), v[-1])")],
                       ["C23.none-installed-writes-the-last-entry-exactly-as-a-string-did", "C23.the-second-installed-wins"]),
    "pkgdoctorfail": ("doctor counts a missing preferred theme as a FAIL",
                      [('line(True, "pkg " + tname, " | ".join(parts), tag="note" if gap else "ok")', 'line(not gap, "pkg " + tname, " | ".join(parts))')],
                      ["C23.a-missing-preferred-theme-is-no-fail"]),
    # the accent (C24) and `wallpaper set` (C25)
    "accentfull": ("the accent is judged with lightness in: a pastel mauve is the grey nearest it",
                   [("lab2 = (lab1[0], lab2[1], lab2[2])", "pass")],
                   ["C24.a-pastel-mauve-is-purple-not-slate", "C24.every-pair-and-mode-writes-its-nearest-named-accent"]),
    "accentnowrite": ("the accent target says ok and writes nothing",
                      [('        if not ctx.dry:\n            q = run_cmd(["gsettings", "set", item["schema"], item["key"], want], ctx.timeout)', '        if False:\n            q = run_cmd(["gsettings", "set", item["schema"], item["key"], want], ctx.timeout)')],
                      ["C24.every-pair-and-mode-writes-its-nearest-named-accent", "C24.diff-shows-the-change-and-writes-nothing"]),
    "wpmulti": ("several selected files are accepted (the first is used)",
                [("    if len(args.paths) != 1:\n", "    if len(args.paths) < 1:\n")],
                ["C25.two-files-is-refused"]),
    "wpnoimage": ("any file is an image",
                  [("    if sniff_image(src) is None:\n", "    if False:\n")],
                  ["C25.not-an-image-is-refused"]),
    "wproundtrip": ("shell.jsonc is parsed and dumped instead of edited as text",
                    [("                after = jsonc_list_add(base, slot_path, shown)\n",
                      "                after = json.dumps(_jsonc_lib().loads(base), indent=4) + \"\\n\"\n                d = _jsonc_lib().loads(after)\n                d.setdefault('theme', {}).setdefault('wallpapers', {}).setdefault(theme.name, {})[mode] = [shown]\n                after = json.dumps(d, indent=4) + \"\\n\"\n")],
                    ["C25.comments-and-every-other-byte-survive"]),
    "wpwrongmode": ("the light slot is always the one set",
                    [("    mode = st[\"mode\"]\n    if not isinstance(theme.doc.get(mode), dict):\n        raise Refused('theme \"%s\" has no \"%s\" block' % (theme.name, mode))\n    try:\n        slot = wallpaper_slot(",
                      "    mode = \"light\"\n    if not isinstance(theme.doc.get(mode), dict):\n        raise Refused('theme \"%s\" has no \"%s\" block' % (theme.name, mode))\n    try:\n        slot = wallpaper_slot(")],
                    ["C25.the-current-mode-is-the-slot"]),
    "wpnorollback": ("a picture hyprpaper refuses stays in shell.jsonc",
                     [("        if fails:                                         # hyprpaper refused the picture: nothing half-set", "        if False:")],
                     ["C25.hyprpaper-refusing-puts-the-text-back"]),
    "wpnocomma": ("an inserted member after a last member with no comma gets none",
                  [('                if not has_comma:\n                    out = out[:last_end] + "," + out[last_end:]\n', '')],
                  ["C25.insert.mode-missing-in-the-theme-block", "C25.insert.theme-block-missing", "C25.insert.wallpapers-missing"]),
    "wprevertclobber": ("Revert puts the whole old file back whatever happened to it since",
                        [('        if now == rec["after"]:\n', '        if True:\n')],
                        ["C25.revert-after-an-edit-takes-out-only-its-picture", "C25.an-earlier-revert-after-a-later-set-takes-out-only-its-own-picture"]),
    "wprevertnoapply": ("Revert puts the text back and never tells hyprpaper",
                        [('        fails, said = _apply_wallpaper_target(P, theme, rec["mode"])\n        if fails:', '        fails, said = 0, ""\n        if fails:')],
                        ["C25.revert-tells-hyprpaper-the-old-picture"]),
    "wpnoreadback": ("the wallpaper target never reads the screen back (a named picture of anyone's shadows every switch)",
                     [("    want = os.path.realpath(path)\n\n    def off():\n", "    return []\n    want = os.path.realpath(path)\n\n    def off():\n")],
                     ["C19.a-named-picture-left-by-anything-is-overridden-by-the-next-switch", "C19.a-monitor-that-takes-nothing-is-a-fail-that-names-it"]),
    "wpnameall": ("every monitor is named on every switch (a named set of our own shadows the next fallback request of anyone else)",
                  [("    stray = off()\n    named = [hyprpaper_named(argv, mon) for mon, _ in stray]\n",
                    "    stray = _active_pictures(None)\n    named = [hyprpaper_named(argv, mon) for mon, _ in stray]\n")],
                  ["C19.a-plain-switch-names-no-monitor", "C19.only-the-monitor-that-kept-another-picture-is-named"]),
    "wprevertnamed": ("Revert of an inserted slot tells hyprpaper the old picture by monitor name (the 2026-11-11 freeze)",
                      [("                argv = [\"hyprctl\", \"hyprpaper\", \"wallpaper\", \",%s,%s\" % (pics[0], fit)]\n",
                        "                argv = [\"hyprctl\", \"hyprpaper\", \"wallpaper\", \"%s,%s,%s\" % (rec[\"pictures_before\"][0][0], pics[0], fit)]\n")],
                      ["C25.revert-of-an-inserted-slot-names-no-monitor"]),
    "wpnoaction": ("the notification has no Revert action",
                   [('actions=["revert=Revert"], wait=True)', 'actions=[], wait=True)')],
                   ["C25.the-notification-has-a-revert-action", "C25.revert-puts-back-the-old-text-byte-for-byte"]),
    # several wallpapers per slot (C27), remove (C28), the rename (C29), nwg-look (C30), yazi (C31)
    "bagseam": ("a new round may start with the picture the last one ended on",
                [("    _bag_not_first(bag, last, rnd)\n    return bag\n", "    return bag\n")],
                ["C27.two-pictures-alternate-across-every-seam"]),
    "drawalways": ("every apply draws, in the same session and the same theme and mode too",
                   [('    switched = bags["shown"] != [name, mode] or bags["instance"] != inst\n', '    switched = True\n')],
                   ["C27.a-second-apply-in-the-same-session-keeps-the-picture"]),
    "nosession": ("a new Hyprland session keeps the last pick",
                  [('    switched = bags["shown"] != [name, mode] or bags["instance"] != inst\n', '    switched = bags["shown"] != [name, mode]\n')],
                  ["C27.a-new-session-draws"]),
    "setreplaces": ("Set replaces the slot instead of adding to it",
                    [("                after = jsonc_list_add(base, slot_path, shown)\n", "                after = jsonc_set_path(base, slot_path, shown)\n")],
                    ["C25.one-image-is-added-to-the-slot-and-shown"]),
    "removekeepsshown": ("the picture on screen stays on screen after it left the list",
                         [('    if not switched and state["last"] in slot["paths"]:\n', '    if not switched and state["last"]:\n')],
                         ["C28.removing-the-picture-on-screen-shows-another"]),
    "renameghost": ("install renames nothing: the old pair stays beside the new one",
                    [("    fails = install_renames(P, args)\n", "    fails = 0\n")],
                    ["C29.no-ghost-pair-after-install", "C29.state-follows"]),
    "renamekeepsmanifest": ("the manifest keeps the renamed pair's old copy (a restore brings the ghost back)",
                            [("                    _forget(P, [oldf])\n", "")],
                            ["C29.the-manifest-forgets-the-old-paths", "C29.restore-brings-no-ghost-back"]),
    "yazinoregen": ("the yazi rules are written by install and never again",
                    [("        new = yazi_rule_block(text, rules)\n", "        new = yazi_rule_block(text, rules) if 'use = ' not in text.split(YAZI_BEGIN, 1)[-1].split(YAZI_END, 1)[0] else text\n")],
                    ["C31.the-rules-follow-a-mode-switch", "C31.set-adds-its-rule-with-the-glob-characters-escaped"]),
    "nwgexport": ("nwg-look's export-gtk4-symlinks is left on",
                  [('        flip = [k for k in spec.get("off", []) if obj.get(k) is not False]\n', '        flip = []\n')],
                  ["C30.export-gtk4-symlinks-is-switched-off"]),
    "vmnotoptional": ("a machine with no VM makes the folder and writes the file anyway",
                      [('    if not os.path.isdir(share):\n        return "skipped: the shared folder %s does not exist" % share, ""\n', '')],
                      ["C20.no-folder-is-skipped-and-not-made"]),
    "vmwrongfolder": ("the first volume in the file is the share, whatever it is mounted at",
                      [('(?::[a-z,]+)?[\'"]?\\s*(?:#.*)?$\"\"\" % re.escape(guest))', '(?::[a-z,]+)?[\'"]?\\s*(?:#.*)?$\"\"\" % r"/[a-z]+")')],
                      ["C20.only-that-file"]),
}


def make_arm_tree(arm):
    desc, patches, expect = ARMS[arm]
    tree = os.path.join(WORK, "armtree_" + arm)
    for rel in ("tools/theme", "tools/lib", "themes", "modules/common/theme"):
        shutil.copytree(os.path.join(REPO, rel), os.path.join(tree, rel), ignore=shutil.ignore_patterns("__pycache__", "*.qsb"))
    for patch in patches:                    # (old, new) in tools/theme/themectl, or (relative path, old, new) in another file of the tree
        rel, old, new = patch if len(patch) == 3 else ("tools/theme/themectl", patch[0], patch[1])
        p = os.path.join(tree, rel)
        t = open(p, encoding="utf-8").read()
        if t.count(old) != 1:
            print("THEMECTL_CASES ARM %s: the anchor is gone (%d matches in %s): %r" % (arm, t.count(old), rel, old[:60]))
            sys.exit(3)
        open(p, "w", encoding="utf-8").write(t.replace(old, new))
    return tree


def run_arm(arm):
    tree = make_arm_tree(arm)
    env = dict(os.environ)
    env["THEMECTL_TREE"] = tree
    env.pop("ARM", None)
    r = subprocess.run([sys.executable, os.path.abspath(__file__)], env=env, capture_output=True, text=True, timeout=600)
    failed = set(re.findall(r"^FAIL (\S+)", r.stdout, re.M))
    expect = set(ARMS[arm][2])
    ok = expect <= failed
    print("THEMECTL_CASES ARM %s (%s): %s" % (arm, ARMS[arm][0], ("FAILED as it must (%s)" % ", ".join(sorted(expect & failed))) if ok else "NOT PROVEN: expected %s to fail, failed: %s" % (sorted(expect), sorted(failed))))
    return ok


def main():
    arm = os.environ.get("ARM", "")
    if arm == "all":
        good = all([run_arm(a) for a in ARMS])
        shutil.rmtree(WORK, ignore_errors=True)
        print("THEMECTL_CASES ARMS %s" % ("PASS" if good else "FAIL"))
        return 0 if good else 1
    if arm:
        if arm not in ARMS:
            print("unknown arm %s (have: %s)" % (arm, ", ".join(ARMS)))
            return 2
        good = run_arm(arm)
        shutil.rmtree(WORK, ignore_errors=True)
        return 0 if good else 1
    before = sbx.manifest()
    try:
        for fn in (c1_c2, c4, c5, c6, c7, c7_btop, c8, c9, c10, c13, c14, c15, c16, c17, c18, c19, c20, c21, c22, c23, c24, c25, c26, c27, c28, c29, c30, c31, c32, c33):
            try:
                fn()
            except Exception as e:                      # a case that blew up is a FAIL with the reason, not a silent skip
                import traceback
                check("%s.raised" % fn.__name__, False, "%s: %s\n%s" % (type(e).__name__, e, traceback.format_exc()[-600:]))
    finally:
        moved = sbx.compare(before, sbx.manifest())
        shutil.rmtree(WORK, ignore_errors=True)
    for p, w in moved:
        print("MOVED  ~/%s  %s" % (p, w))
    check("OUTSIDE.nothing-outside-the-sandbox-changed", not moved, moved[:3])
    nfail = sum(1 for _, ok, _ in RESULTS if not ok)
    print("THEMECTL_CASES %d checks, %d failed" % (len(RESULTS), nfail))
    print("THEMECTL_CASES RESULT %s" % ("PASS" if nfail == 0 else "FAIL"))
    return 0 if nfail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
