"""What is installed on this machine, and which Arch wiki pages are about it (Deepen's "yours" and "new").

    snapshot()                      -> {pkgs, repo, units, asOf}   read ONCE per batch (three short commands)
    match_installed(title, snap)    -> {flag: True, pkg, unit, asOf} | None     the page is about something installed
    match_discovery(title, snap)    -> {flag: False, pkg, unit: None, asOf} | None   software in the repos, not installed
    by_templates(title, snap, ...)  -> the same two answers from the page's own {{Pkg}} / {{AUR}} templates

The commands, argv lists with the secret-free environment (env.child_env), never a shell:
    pacman -Qq                                              every installed package (explicit and dependencies)
    pacman -Slq                                             every package the sync databases offer (about 15 000 names)
    systemctl list-unit-files --state=enabled --no-legend --no-pager           the system's enabled units
    systemctl --user list-unit-files --state=enabled --no-legend --no-pager    and the user's

A page maps to a package by its TITLE first (offline, exact: `Nginx` -> nginx, `Z shell`-like titles do not),
then by the packages the page names in its `{{Pkg}}` / `{{AUR}}` templates (arch.pkg_templates: two requests
per page, so callers spend a small budget of them). The title's first path segment is what counts, so the
subpage `Systemd/Timers` is about systemd. A unit `nginx.service` is about `Nginx` the same way (the suffix and a
template `@` are dropped).

A machine with no pacman (or a probe's PATH without one) gives an empty snapshot; nothing here raises.
"""
import re
import shutil
import subprocess
import time

from . import env

_UNIT_SUFFIX = re.compile(r"\.(service|socket|timer|path|target|mount|automount|swap|slice|scope)$")


def _run(argv, timeout=30):
    """stdout of `argv` as text, or None when the program is missing, fails or hangs."""
    exe = shutil.which(argv[0])
    if not exe:
        return None
    try:
        r = subprocess.run([exe] + list(argv[1:]), capture_output=True, text=True, timeout=timeout,
                           env=env.child_env(), stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def norm(name):
    """A package, unit or page name in one comparable form: lower case, runs of space / underscore as "-"."""
    return re.sub(r"[\s_]+", "-", (name or "").strip().lower())


def _lines(text):
    return [l.strip() for l in (text or "").splitlines() if l.strip()]


def packages():
    """{name} of every installed package."""
    return {norm(n) for n in _lines(_run(["pacman", "-Qq"]))}


def repo_packages():
    """{name} of every package the sync databases offer."""
    return {norm(n) for n in _lines(_run(["pacman", "-Slq"], timeout=60))}


def enabled_units(user=False):
    """{base name: full unit name} of the enabled units (`nginx.service enabled disabled` -> nginx)."""
    argv = ["systemctl"] + (["--user"] if user else []) + ["list-unit-files", "--state=enabled", "--no-legend",
                                                            "--no-pager"]
    out = {}
    for line in _lines(_run(argv)):
        unit = line.split()[0]
        base = _UNIT_SUFFIX.sub("", unit)
        base = norm(base.split("@")[0])
        if base:
            out.setdefault(base, unit)
    return out


def snapshot():
    units = enabled_units(False)
    for k, v in enabled_units(True).items():
        units.setdefault(k, v)
    return {"pkgs": packages(), "repo": repo_packages(), "units": units, "asOf": int(time.time() * 1000)}


def _keys(title):
    """The names a page title may stand for: the first path segment, as is and without its separators."""
    base = norm((title or "").split("/")[0])
    out = [base]
    flat = base.replace("-", "")
    if flat != base:
        out.append(flat)
    return [k for k in out if k]


def match_installed(title, snap):
    """The page is about an installed package or an enabled unit -> {flag: True, pkg, unit, asOf}."""
    for k in _keys(title):
        pkg = k if k in snap["pkgs"] else None
        unit = snap["units"].get(k)
        if pkg or unit:
            return {"flag": True, "pkg": pkg, "unit": unit, "asOf": snap["asOf"]}
    return None


def match_discovery(title, snap):
    """The page is about software the repositories offer and that is NOT installed."""
    if match_installed(title, snap):
        return None
    for k in _keys(title):
        if k in snap["repo"]:
            return {"flag": False, "pkg": k, "unit": None, "asOf": snap["asOf"]}
    return None


def by_templates(title, snap, names):
    """The same answers from the package names a page's templates give (`names`, arch.pkg_templates()):
    any of them installed -> installed; else named at all -> a package that is not installed; else None."""
    norms = [norm(n) for n in names]
    for n in norms:
        if n in snap["pkgs"]:
            return {"flag": True, "pkg": n, "unit": snap["units"].get(n), "asOf": snap["asOf"]}
    if norms:
        return {"flag": False, "pkg": norms[0], "unit": None, "asOf": snap["asOf"]}
    return None
