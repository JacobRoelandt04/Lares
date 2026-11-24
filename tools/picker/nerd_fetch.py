#!/usr/bin/env python3
"""nerd_fetch.py -- the picker's Nerd Fonts list: the names of the icons the INSTALLED Nerd Font draws.

    tools/picker/nerd_fetch.py ensure  [--cache-dir <dir>] [--font <ttf>] [--url-base <url>] [--timeout <s>]
    tools/picker/nerd_fetch.py version [--font <ttf>]

Nerd Fonts publishes the cheat sheet's own data, `glyphnames.json` ({"md-home": {"char": "...", "code": "f02dc"}, ...,
"METADATA": {"version": "3.5.1"}}), per release tag: <url-base>/v<version>/glyphnames.json (default url-base
https://raw.githubusercontent.com/ryanoasis/nerd-fonts). The library changes from release to release, so the list is fetched FOR THE
INSTALLED VERSION, which is read from the font itself (its name table: "Version 001.000;Nerd Fonts 3.5.1", else "Nerd Fonts 3.5.1" in
the full name, else the family's own "Version x.y.z"), never from the package manager, so it holds on any distro.

`ensure` is the whole run, one JSON line on stdout (a failure is a stated reason, never a trace):
    {"status": "current" | "built" | "fetched" | "error", "nerd": "3.5.1", "family": "Symbols Nerd Font", "font": "<path>",
     "count": n, "dropped": n, "asset": "<path>", "fetched": true|false, "read": "<what the version was read from>", "reason": "..."}
  current  the asset in the cache dir is for this version and this font file (nothing fetched, nothing read but the name table)
  built    the version's glyphnames.json was already cached; the asset was filtered again (another font file)
  fetched  the version's glyphnames.json was fetched (curl, a generic User-Agent, a timeout) and the asset written
  error    `reason` says why (no Nerd Font installed, offline, no list for that version, fontTools missing ...)
The cache dir (default $XDG_CACHE_HOME/lares/picker) holds `glyphnames-<version>.json` (the list as fetched) and `nerd.json` (the asset
the shell reads). The asset keeps ONLY the code points the font draws (fontTools cmap; the font's count is `count`, the list's rest
`dropped`): a tile of a glyph the font lacks would draw a box. Written atomically.

The asset (compact): {"version": 1, "nerd": "3.5.1", "family", "font": {"path", "size", "mtime"}, "dropped": n,
    "sets": [{"id", "label", "glyph"}], "rows": [[char, name, set index, "<code hex>", "<other names, space-joined>"]]}
`name` is the full name (`nf-md-lightbulb_on`, the prefix `nf-` added where the list has none). Names that share one character are ONE row (320
of 10995 in 3.5.1): the name of the first group wins, the others are `other names` (searched, never drawn twice).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

DEFAULT_BASE = "https://raw.githubusercontent.com/ryanoasis/nerd-fonts"
USER_AGENT = "lares-picker/1 (nerd fonts list)"

# The picker's groups, in the order of its category bar: (id, label, name prefixes, a name whose glyph stands for the group).
GROUPS = [
    ("md", "Material Design", ["md"], "md-home"),
    ("fa", "Font Awesome", ["fa", "fae"], "fa-flag"),
    ("cod", "Codicons", ["cod"], "cod-bug"),
    ("dev", "Devicons", ["dev"], "dev-git_branch"),
    ("oct", "Octicons", ["oct"], "oct-rocket"),
    ("seti", "Seti-UI", ["seti"], "seti-config"),
    ("weather", "Weather", ["weather"], "weather-day_sunny"),
    ("pl", "Powerline", ["pl", "ple"], "pl-branch"),
    ("linux", "Linux logos", ["linux"], "linux-tux"),
    ("custom", "Custom", ["custom"], "custom-neovim"),
    ("other", "Other", ["pom", "iec", "extra", "indent", "indentation"], "pom-pomodoro_done"),
]


def fail(reason, **more):
    out = {"status": "error", "reason": reason}
    out.update(more)
    print(json.dumps(out, ensure_ascii=False))
    sys.exit(0)


def load_ttfont(path):
    try:
        from fontTools.ttLib import TTFont
    except ImportError:
        fail("python fontTools is missing (pacman -S python-fonttools)")
    try:
        return TTFont(path, lazy=True)
    except Exception as e:
        fail("cannot read %s: %s" % (path, e))


def find_font(explicit):
    """The font to read: --font, $NERD_FONT, else fontconfig's Symbols Nerd Font, else any installed Nerd Font (a patched text font draws the same glyphs)."""
    if explicit:
        return explicit if os.path.isfile(explicit) else None
    env = os.environ.get("NERD_FONT")
    if env:
        return env if os.path.isfile(env) else None
    for pattern in (":family=Symbols Nerd Font", ":family=Symbols Nerd Font Mono", ":fontformat=TrueType"):
        try:
            out = subprocess.run(["fc-list", "-f", "%{file}\\t%{family}\\t%{style}\\n", pattern], capture_output=True, text=True, timeout=20).stdout
        except (OSError, subprocess.SubprocessError):
            return None
        rows = [l.split("\t") for l in out.splitlines() if l.count("\t") == 2]
        if pattern.endswith("TrueType"):
            rows = [r for r in rows if "Nerd Font" in r[1] and r[2].split(",")[0] == "Regular" and "Propo" not in r[1]]
        rows = [r for r in rows if os.path.isfile(r[0])]
        if rows:
            rows.sort(key=lambda r: (len(r[1]), r[0]))
            return rows[0][0]
    return None


def name_of(font, ids):
    for i in ids:
        for rec in font["name"].names:
            if rec.nameID == i and rec.platformID in (3, 0, 1):
                try:
                    s = rec.toUnicode().strip()
                except Exception:
                    continue
                if s:
                    return s
    return ""


def read_version(font):
    """(version, where it was read from) or (None, why not)."""
    pats = [(5, r"Nerd Fonts?\s+v?(\d+\.\d+(?:\.\d+)?)"), (3, r"(\d+\.\d+\.\d+)\s*$"), (4, r"Nerd Fonts?\s+v?(\d+\.\d+(?:\.\d+)?)"),
            (0, r"Nerd Fonts?\s+v?(\d+\.\d+(?:\.\d+)?)")]
    for nid, pat in pats:
        s = name_of(font, [nid])
        m = re.search(pat, s)
        if m:
            return m.group(1), "name table id %d: %s" % (nid, s)
    s = name_of(font, [5])
    m = re.search(r"Version\s+(\d+\.\d+(?:\.\d+)?)", s)
    if m and float(m.group(1).split(".")[0]) >= 2 and "Nerd" in name_of(font, [1, 4, 16]):
        return m.group(1), "name table id 5: %s" % s
    return None, "its name table says no Nerd Fonts version (%s)" % (s or "empty")


def group_of(prefix):
    for gi, g in enumerate(GROUPS):
        if prefix in g[2]:
            return gi
    return len(GROUPS) - 1


def build_asset(raw, cmap, version, family, fontinfo):
    """The asset from the list `raw` and the set of code points `cmap` the font draws. Pure: the check calls it with a made-up font."""
    entries = []
    for key, v in raw.items():
        if key == "METADATA" or not isinstance(v, dict) or not v.get("char"):
            continue
        key = key[3:] if key.startswith("nf-") else key
        entries.append((key, v["char"], str(v.get("code", ""))))
    kept = {}
    order = []
    dropped = 0
    for key, ch, code in entries:
        if len(ch) != 1 or ord(ch) not in cmap:
            dropped += 1
            continue
        gi = group_of(key.split("-", 1)[0])
        if ch not in kept:
            kept[ch] = [gi, key, code, []]
            order.append(ch)
        else:
            row = kept[ch]
            if gi < row[0]:
                row[3].append(row[1])
                row[0], row[1] = gi, key
            else:
                row[3].append(key)
    rows_by_group = [[] for _ in GROUPS]
    for ch in order:
        gi, key, code, others = kept[ch]
        rows_by_group[gi].append((key, ch, code, others))
    sets = []
    rows = []
    for gi, g in enumerate(GROUPS):
        items = rows_by_group[gi]
        if not items:
            continue
        items.sort(key=lambda r: r[0])
        glyph = next((r[1] for r in items if r[0] == g[3]), items[0][1])
        si = len(sets)
        sets.append({"id": g[0], "label": g[1], "glyph": glyph})
        for key, ch, code, others in items:
            rows.append([ch, "nf-" + key, si, code, " ".join("nf-" + o for o in others)])
    return {"version": 1, "nerd": version, "family": family, "font": fontinfo, "dropped": dropped, "sets": sets, "rows": rows}


def write_atomic(path, text):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".nerd.", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def fetch(url, dest, timeout):
    """curl the list to `dest`; returns "" or the reason it failed."""
    if shutil.which("curl") is None:
        return "curl is not installed"
    d = os.path.dirname(dest)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".glyphnames.", dir=d)
    os.close(fd)
    try:
        p = subprocess.run(["curl", "-sS", "-L", "--max-time", str(timeout), "--connect-timeout", str(min(10, timeout)), "-A", USER_AGENT,
                            "-o", tmp, "-w", "%{http_code}", url], capture_output=True, text=True, timeout=timeout + 15)
        code = p.stdout.strip()
        host = re.sub(r"^https?://([^/]+).*$", r"\1", url)
        if p.returncode in (6, 7, 28, 35, 52, 56):
            return "offline: cannot reach %s (curl %d)" % (host, p.returncode)
        if p.returncode != 0:
            return "the fetch failed (curl %d: %s)" % (p.returncode, p.stderr.strip()[:120])
        if code != "200":
            return "no glyphnames.json at %s (HTTP %s)" % (url, code)
        try:
            with open(tmp, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            return "%s answered something that is not JSON" % host
        if not isinstance(data, dict) or not isinstance(data.get("METADATA"), dict) or len(data) < 100:
            return "%s answered a list of another shape (no METADATA)" % host
        os.replace(tmp, dest)
        return ""
    except subprocess.TimeoutExpired:
        return "offline: the fetch timed out after %d s" % timeout
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def default_cache():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "lares", "picker")


def cmd_version(args):
    path = find_font(args.font)
    if not path:
        fail("no Nerd Font is installed (Symbols Nerd Font: pacman -S ttf-nerd-fonts-symbols)")
    font = load_ttfont(path)
    version, read = read_version(font)
    print(json.dumps({"status": "ok" if version else "error", "nerd": version, "read": read, "font": path,
                      "family": name_of(font, [16, 1])}, ensure_ascii=False))


def cmd_ensure(args):
    path = find_font(args.font)
    if not path:
        fail("no Nerd Font is installed (Symbols Nerd Font: pacman -S ttf-nerd-fonts-symbols)")
    font = load_ttfont(path)
    version, read = read_version(font)
    if not version:
        fail("cannot tell which Nerd Fonts version %s is: %s" % (path, read), font=path)
    family = name_of(font, [16, 1]) or "Symbols Nerd Font"
    st = os.stat(path)
    fontinfo = {"path": path, "size": st.st_size, "mtime": int(st.st_mtime)}
    cache = args.cache_dir or default_cache()
    asset = os.path.join(cache, "nerd.json")
    base = {"nerd": version, "family": family, "font": path, "asset": asset, "read": read}
    try:
        with open(asset, encoding="utf-8") as f:
            have = json.load(f)
        if have.get("version") == 1 and have.get("nerd") == version and have.get("font") == fontinfo and have.get("family") == family:
            print(json.dumps(dict(base, status="current", fetched=False, count=len(have["rows"]), dropped=have.get("dropped", 0)), ensure_ascii=False))
            return
    except (OSError, ValueError, AttributeError):
        pass
    raw_path = os.path.join(cache, "glyphnames-%s.json" % version)
    fetched = False
    raw = None
    try:
        with open(raw_path, encoding="utf-8") as f:
            raw = json.load(f)
    except (OSError, ValueError):
        raw = None
    if raw is None:
        url = "%s/v%s/glyphnames.json" % (args.url_base.rstrip("/"), version)
        why = fetch(url, raw_path, args.timeout)
        if why:
            fail(why, **base)
        fetched = True
        with open(raw_path, encoding="utf-8") as f:
            raw = json.load(f)
    cmap = set(font.getBestCmap().keys())
    out = build_asset(raw, cmap, version, family, fontinfo)
    if not out["rows"]:
        fail("the font %s draws none of the %d names in the list for v%s" % (path, len(raw) - 1, version), **base)
    write_atomic(asset, json.dumps(out, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(json.dumps(dict(base, status="fetched" if fetched else "built", fetched=fetched, count=len(out["rows"]), dropped=out["dropped"]), ensure_ascii=False))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("ensure", "version"):
        p = sub.add_parser(name)
        p.add_argument("--font", default="")
        p.add_argument("--cache-dir", default="")
        p.add_argument("--url-base", default=DEFAULT_BASE)
        p.add_argument("--timeout", type=int, default=30)
    args = ap.parse_args()
    {"ensure": cmd_ensure, "version": cmd_version}[args.cmd](args)


if __name__ == "__main__":
    main()
