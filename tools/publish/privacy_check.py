#!/usr/bin/env python3
"""privacy_check.py -- what an export of this repository would publish holds no secret and nothing that points at its owner.

    python3 -B tools/publish/privacy_check.py                  the tracked files of the working tree, as an export would take them
    python3 -B tools/publish/privacy_check.py --rev <rev>      the same of a commit
    python3 -B tools/publish/privacy_check.py --tree <sha> --export [--commit <sha>]
                                                               a BUILT export (lares publish): no excluded path may be in it, the
                                                               commit's name and e-mail are judged too, and exiftool must be there
    --repo <dir>   judge another repository (the cases)        --show   print the values whole (default: masked)

THE VIEW. The export leaves out every path of tools/publish/exclude.txt (the agents' notes, the feedback); this judges what
is left, file contents (binary too, for the private terms) and paths.

THE RULES, each a word in the finding line:
  term      a value of the private list -- config/privacy.jsonc (`replace` keys and `forbid`; never tracked) or the file
            $LARES_PRIVACY_FILE names -- case-insensitive, at word edges (in a binary file only values of 6 characters or more); a space, `-` or `_` in it matches any of them or
            none, and a MAC in it matches in every spelling (`:`, `-`, `_`, nmcli's `\\:` with any number of
            backslashes -- a stub's printf writes two --, no separator). Without the list
            the rule is off and the run says so: the rules below still run.
  email     an e-mail address off the example / test domains.
  mac       a MAC address (`:` / `-` / `\\:` separated, BlueZ's `dev_XX_..`) outside the placeholders the fixtures use.
  ipv4      a public IPv4 address (the well-known public resolvers excepted).
  ipv6      a global IPv6 address outside 2001:db8::/32 (the resolvers excepted), or a link-local one whose interface id is
            not a small number (a stable per-device id, or EUI-64: a MAC inside). Found by taking every run of hex digits and
            colons and trying it at each colon, so `IP6.ADDRESS[1]:2a02:...` is no hiding place (the aerial scrubber's miss).
  home      a home directory's name (/home/<n>, /Users/<n>, /run/media/<n>) that is not one of the stand-ins.
  key       a private key block, or a token of a known shape (GitHub, Anthropic, OpenAI, AWS, Google, Slack) that is not
            an obvious fake (its characters carry less than 3 bits each).
  artifact  a claude.ai artifact / share link (an account's own page).
  image     image metadata through exiftool: GPS, a serial number, an owner, artist, author or creator.
  excluded  (--export) an excluded path inside the built tree.
  identity  (--export --commit) the commit's author or committer is a private value (unless it is the list's own `publish`
            name or e-mail) or an e-mail address that is not GitHub's no-reply one.

ALLOWED. tools/publish/privacy_allow.txt: `rule<TAB>path glob<TAB>value` lines, the value as found (case-insensitive);
`*` for any rule. Every line says why above it.

One `PRIVACY RESULT PASS|FAIL` line; the exit status follows it (0 / 1; 2 = could not run). PRIVACY_ARM=<arm> weakens one
rule for tools/dev/privacy_check_cases.py, which must then fail: termverbatim, v6naive, noeui64, noemail, nohome, noexif,
noexclude, noidentity.
"""
import argparse
import fnmatch
import ipaddress
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import jsonc  # noqa: E402

ARM = os.environ.get("PRIVACY_ARM", "")
ALLOW_FILE = "tools/publish/privacy_allow.txt"     # its own lines name what they allow
LIMIT = 400

# ---------------------------------------------------------------------------------------------------------------- the view

def git(repo, *args, binary=False):
    r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True)
    if r.returncode != 0:
        raise RuntimeError("git %s: %s" % (" ".join(args), r.stderr.decode(errors="replace").strip()))
    return r.stdout if binary else r.stdout.decode("utf-8", "surrogateescape")


def patterns(path):
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    out.append(line.lstrip("/"))
    except OSError:
        pass
    return out


def excluded(path, pats):
    for p in pats:
        if p.endswith("/"):
            if path.startswith(p):
                return True
        elif path == p or fnmatch.fnmatchcase(path, p):
            return True
    return False


def worktree_files(repo):
    """(path, bytes) of every tracked file as it is on disk; a symlink is its target's text."""
    for path in git(repo, "ls-files", "-z").split("\0"):
        if not path:
            continue
        full = os.path.join(repo, path)
        if os.path.islink(full):
            yield path, os.readlink(full).encode("utf-8", "surrogateescape")
        elif os.path.isfile(full):
            with open(full, "rb") as f:
                yield path, f.read()


def tree_files(repo, rev):
    """(path, bytes) of every blob of a commit or tree, through one `git cat-file --batch`."""
    entries = []
    for rec in git(repo, "ls-tree", "-r", "-z", rev).split("\0"):
        if not rec:
            continue
        meta, path = rec.split("\t", 1)
        mode, kind, sha = meta.split()
        if kind == "blob":
            entries.append((path, sha))
    p = subprocess.Popen(["git", "-C", repo, "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        for path, sha in entries:
            p.stdin.write(sha.encode() + b"\n")
            p.stdin.flush()
            head = p.stdout.readline().split()
            size = int(head[2])
            data = p.stdout.read(size)
            p.stdout.read(1)
            yield path, data
    finally:
        p.stdin.close()
        p.wait()

# ---------------------------------------------------------------------------------------------------------------- the private list

PUBLISH = set()     # the export's own identity (`publish` name and e-mail): public by the owner's choice, never a term hit


def private_list(repo):
    """The terms (deduplicated, case-insensitive) and where they came from; ([], None) without a list."""
    path = os.environ.get("LARES_PRIVACY_FILE") or jsonc.resolve(os.path.join(repo, "config", "privacy.jsonc"))
    if not os.path.exists(path):
        return [], None
    try:
        data = jsonc.load(path)
    except ValueError as e:
        raise RuntimeError("%s does not parse: %s" % (path, e))
    pub = data.get("publish") or {}
    PUBLISH.update(str(pub.get(k) or "").strip() for k in ("name", "email"))
    PUBLISH.discard("")
    terms = list((data.get("replace") or {}).keys()) + list(data.get("forbid") or [])
    seen, out = set(), []
    for t in terms:
        t = str(t).strip()
        if len(t) >= 3 and t.lower() not in seen:
            seen.add(t.lower())
            out.append(t)
    return out, path


MAC_TERM = re.compile(r"^[0-9A-Fa-f]{2}(?:[:\-_]?[0-9A-Fa-f]{2}){5}$")


def term_pattern(t):
    if ARM == "termverbatim":
        return re.escape(t)
    if MAC_TERM.match(t):
        pairs = re.findall(r"[0-9A-Fa-f]{2}", t)
        return r"(?<![0-9A-Fa-f])" + r"(?:\\*:|[-_])?".join(pairs) + r"(?![0-9A-Fa-f])"
    body = r"[ _-]?".join(re.escape(w) for w in re.split(r"[ _-]+", t))
    head = r"(?<![A-Za-z0-9])" if t[0].isalnum() else ""
    tail = r"(?![A-Za-z0-9])" if t[-1].isalnum() else ""
    return head + body + tail


def term_regex(terms):
    if not terms:
        return None
    return re.compile("|".join("(?:%s)" % term_pattern(t) for t in sorted(terms, key=len, reverse=True)), re.I)

# ---------------------------------------------------------------------------------------------------------------- the generic rules

EMAIL_RE = re.compile(r"(?<![\w.+%-])[A-Za-z0-9._%+-]+@((?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,})(?![\w-])")
EMAIL_OK = ("example.com", "example.org", "example.net", "users.noreply.github.com", "github.com", "anthropic.com", "localhost")
EMAIL_OK_TLD = ("example", "test", "invalid", "localhost")
NOT_TLD = {"service", "slice", "scope", "socket", "target", "timer", "mount", "path", "device", "swap",
           "png", "svg", "jpg", "jpeg", "webp", "gif", "qml", "js", "mjs", "json", "jsonc", "py", "sh", "txt", "md", "so", "conf",
           "log", "toml", "lua", "rs", "cpp", "hpp", "h", "c", "frag", "vert", "qsb", "glsl", "desktop", "wav", "ogg", "html",
           "css", "xml", "yaml", "yml", "ini", "ico", "ttf", "otf", "pdf", "rules", "in", "local"}

# a MAC may follow a `:` (nmcli -t: `no:90\\:5C..`), only not a longer run of hex pairs
MAC_RE = re.compile(r"(?<![0-9A-Fa-f\\])(?<![0-9A-Fa-f][:\-])(?<![0-9A-Fa-f]\\:)([0-9A-Fa-f]{2})(:|-|\\+:)(?:[0-9A-Fa-f]{2}\2){4}[0-9A-Fa-f]{2}(?![0-9A-Fa-f])(?!(?::|-|\\+:)[0-9A-Fa-f])"
                    r"|(?<![0-9A-Za-z])dev_(?:[0-9A-Fa-f]{2}_){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f])")
# The placeholders the fixtures and mocks use on purpose (locally administered 02:..., the AA:BB:CC family, all-same bytes).
MAC_OK = ("02:AE:", "02:00:", "AA:BB:CC:", "AA:00:00:", "00:00:00:", "FF:FF:FF:", "11:22:33:", "12:34:56:", "DE:AD:BE:",
          "02:11:22:", "6E:11:22:", "AA:BB:CC", "01:02:AE:")


def mac_ok(norm):
    if norm.startswith(MAC_OK):
        return True
    b = norm.split(":")
    return b[0] == b[1] == b[2] or max(b.count(x) for x in b) >= 4      # AA:AA:AA:.., FD:00:00:00:00:00: a pattern, not a vendor


IPV4_RE = re.compile(r"(?<![\w.=-])(\d{1,3}(?:\.\d{1,3}){3})(?![\w]|\.\d)")
IPV4_OK = {"1.2.3.4", "1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112", "208.67.222.222", "208.67.220.220"}

V6_RUN = re.compile(r"[0-9A-Fa-f:]*:[0-9A-Fa-f:]*:[0-9A-Fa-f:]*")
V6_NAIVE = re.compile(r"(?<![0-9A-Fa-f:])((?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4})(?![0-9A-Fa-f:])")
V6_DOC = ipaddress.ip_network("2001:db8::/32")
V6_GLOBAL = ipaddress.ip_network("2000::/3")
V6_OK = {ipaddress.ip_address(a) for a in ("2606:4700:4700::1111", "2606:4700:4700::1001", "2001:4860:4860::8888",
                                           "2001:4860:4860::8844", "2620:fe::fe", "2620:fe::9")}


def v6_candidates(text):
    """(offset, address) of every IPv6 address (v6_spans)."""
    for a, b, addr in v6_spans(text):
        yield a, addr


def v6_spans(text):
    """(start, end, address) of every IPv6 address: each run of hex and colons, tried at every colon it holds (the longest
    address wins). tools/aerial/make_fixtures.py replaces by these spans."""
    if ARM == "v6naive":
        for m in V6_NAIVE.finditer(text):
            try:
                yield m.start(1), m.end(1), ipaddress.IPv6Address(m.group(1))
            except ValueError:
                pass
        return
    for m in V6_RUN.finditer(text):
        run = m.group(0)
        if run.count(":") < 2 or len(run) > 45:
            continue
        cuts = [i for i, c in enumerate(run) if c == ":"]
        starts = [0] + [i + 1 for i in cuts]
        ends = [len(run)] + cuts
        best = None
        for a in starts:
            for b in ends:
                if b - a < 3 or (best and b - a <= best[1] - best[0]):
                    continue
                s = run[a:b]
                if s.count(":") < 2:
                    continue
                try:
                    addr = ipaddress.IPv6Address(s)
                except ValueError:
                    continue
                best = (a, b, addr)
        if best:
            yield m.start() + best[0], m.start() + best[1], best[2]


def v6_bad(addr):
    if addr in V6_OK or addr in V6_DOC:
        return False
    if addr in V6_GLOBAL:
        return True
    if addr.is_link_local:
        iid = int(addr) & ((1 << 64) - 1)
        eui = ((iid >> 24) & 0xFFFF) == 0xFFFE
        if ARM == "noeui64":
            return False
        return eui or iid > 0xFFFF
    return False


HOME_RE = re.compile(r"(?<![\w$}./-])/(?:home|Users|run/media)/([A-Za-z][A-Za-z0-9._-]*)")
HOME_OK = {"user", "users", "demo", "vmuser", "u", "x", "you", "alice", "bob", "test", "tester", "someone", "me", "name",
           "username", "guest", "foo", "linuxbrew"}

KEY_RE = re.compile(r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----")
TOKEN_RE = re.compile(r"(?<![A-Za-z0-9])(?:gh[pousr]_([A-Za-z0-9]{30,})|github_pat_([A-Za-z0-9_]{40,})|sk-ant-([A-Za-z0-9_-]{20,})"
                      r"|sk-([A-Za-z0-9]{32,})|AKIA([0-9A-Z]{16})|AIza([0-9A-Za-z_-]{35})|xox[abprs]-([A-Za-z0-9-]{10,}))")


def entropy(s):
    if not s:
        return 0.0
    n = len(s)
    return -sum(c / n * math.log2(c / n) for c in (s.count(ch) for ch in set(s)))


ARTIFACT_RE = re.compile(r"claude\.ai/(?:code/)?(?:artifact|artifacts|share|chat|public/artifacts)/[A-Za-z0-9_-]{6,}")

IMAGE_EXT = (".png", ".jpg", ".jpeg", ".webp", ".gif", ".tif", ".tiff", ".heic", ".avif")
IMAGE_TAGS = ["-GPSLatitude", "-GPSLongitude", "-GPSPosition", "-SerialNumber", "-InternalSerialNumber", "-OwnerName",
              "-CameraOwnerName", "-Artist", "-Author", "-Creator", "-XMP:Creator", "-By-line"]

# ---------------------------------------------------------------------------------------------------------------- judging

class Judge:
    def __init__(self, terms, allow):
        self.term_re = term_regex(terms)
        self.term_bin = term_regex([t for t in terms if len(t) >= 6])     # in a picture's bytes a short word is chance
        self.allow = allow
        self.findings = []

    def allowed(self, rule, path, value):
        v = value.lower()
        for r, glob, val in self.allow:
            if (r == "*" or r == rule) and (fnmatch.fnmatchcase(path, glob) or path == ALLOW_FILE) and val.lower() == v:
                return True
        return False

    def add(self, rule, path, text, offset, value):
        if self.allowed(rule, path, value):
            return
        line = text.count("\n", 0, offset) + 1 if text is not None and offset is not None else 0
        self.findings.append((rule, path, line, value))

    def path(self, path):
        if self.term_re:
            for m in self.term_re.finditer(path):
                self.add("term", path, None, None, m.group(0))

    def content(self, path, data):
        binary = b"\0" in data[:8192]
        text = data.decode("latin-1") if binary else data.decode("utf-8", "replace")
        tre = self.term_bin if binary else self.term_re
        if tre:
            for m in tre.finditer(text):
                self.add("term", path, text, m.start(), m.group(0))
        if binary:
            return
        if ARM != "noemail":
            for m in EMAIL_RE.finditer(text):
                dom = m.group(1).lower()
                tld = dom.rsplit(".", 1)[-1]
                if tld in NOT_TLD or dom in EMAIL_OK or tld in EMAIL_OK_TLD or any(dom.endswith("." + d) for d in EMAIL_OK):
                    continue
                self.add("email", path, text, m.start(), m.group(0))
        for m in MAC_RE.finditer(text):
            raw = m.group(0)
            norm = ":".join(re.findall(r"[0-9A-Fa-f]{2}", raw[4:] if raw.startswith("dev_") else raw)).upper()
            if not mac_ok(norm):
                self.add("mac", path, text, m.start(), raw)
        for m in (() if path.endswith(".svg") else IPV4_RE.finditer(text)):      # an svg's path data is numbers
            s = m.group(1)
            try:
                a = ipaddress.IPv4Address(s)
            except ValueError:
                continue
            if a.is_global and s not in IPV4_OK:
                self.add("ipv4", path, text, m.start(1), s)
        for off, addr in v6_candidates(text):
            if v6_bad(addr):
                self.add("ipv6", path, text, off, str(addr))
        if ARM != "nohome":
            for m in HOME_RE.finditer(text):
                if m.group(1).lower() not in HOME_OK:
                    self.add("home", path, text, m.start(), m.group(0))
        for m in KEY_RE.finditer(text):
            self.add("key", path, text, m.start(), m.group(0))
        for m in TOKEN_RE.finditer(text):
            body = next(g for g in m.groups() if g)
            if entropy(body) >= 3.0:
                self.add("key", path, text, m.start(), m.group(0))
        for m in ARTIFACT_RE.finditer(text):
            self.add("artifact", path, text, m.start(), m.group(0))

    def images(self, items, need_tool):
        """items: [(path, bytes)] of images. Returns a note, or None."""
        if ARM == "noexif" or not items:
            return None
        tool = shutil.which("exiftool")
        if not tool:
            if need_tool:
                self.findings.append(("image", "(exiftool)", 0, "exiftool is not installed: an export is not judged without it"))
            return "exiftool is not installed: image metadata not checked"
        with tempfile.TemporaryDirectory(prefix="privacy-img-") as tmp:
            names = {}
            for i, (path, data) in enumerate(items):
                f = os.path.join(tmp, "%05d%s" % (i, os.path.splitext(path)[1].lower()))
                with open(f, "wb") as out:
                    out.write(data)
                names[f] = path
            r = subprocess.run([tool, "-j", "-q", "-q", "-n"] + IMAGE_TAGS + list(names), capture_output=True, text=True)
            try:
                rows = json.loads(r.stdout or "[]")
            except ValueError:
                rows = []
            for row in rows:
                path = names.get(row.get("SourceFile"), row.get("SourceFile"))
                for k, v in row.items():
                    if k != "SourceFile" and str(v).strip():
                        self.add("image", path, None, None, "%s=%s" % (k, v))
        return None


def mask(v, show):
    if show or len(v) <= 4:
        return v
    return v[:3] + "...(%d)" % len(v)


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--repo", default=os.path.normpath(os.path.join(HERE, "..", "..")))
    ap.add_argument("--rev")
    ap.add_argument("--tree")
    ap.add_argument("--export", action="store_true")
    ap.add_argument("--commit")
    ap.add_argument("--show", action="store_true")
    a = ap.parse_args()
    repo = os.path.abspath(a.repo)
    try:
        pats = patterns(os.path.join(repo, "tools", "publish", "exclude.txt"))
        allow = []
        for line in patterns(os.path.join(repo, ALLOW_FILE)):
            f = line.split("\t")
            if len(f) == 3:
                allow.append((f[0], f[1], f[2]))
        terms, listed = private_list(repo)
        judge = Judge(terms, allow)
        source = tree_files(repo, a.tree or a.rev) if (a.tree or a.rev) else worktree_files(repo)
        files = images = 0
        imgs = []
        for path, data in source:
            if excluded(path, pats):
                if a.export and ARM != "noexclude":
                    judge.add("excluded", path, None, None, path)
                continue
            files += 1
            judge.path(path)
            judge.content(path, data)
            if path.lower().endswith(IMAGE_EXT):
                imgs.append((path, data))
        images = len(imgs)
        note_img = judge.images(imgs, a.export)
        if a.export and a.commit and ARM != "noidentity":
            ident = git(repo, "log", "-1", "--format=%an%n%ae%n%cn%n%ce", a.commit).splitlines()
            for v in ident:
                if judge.term_re and v not in PUBLISH and judge.term_re.search(v):
                    judge.add("identity", "(commit %s)" % a.commit[:12], None, None, v)
                m = EMAIL_RE.fullmatch(v) if "@" in v else None
                if m and not (m.group(1).lower() == "users.noreply.github.com" or m.group(1).lower().endswith(".example")):
                    judge.add("identity", "(commit %s)" % a.commit[:12], None, None, v)
    except RuntimeError as e:
        print("PRIVACY RESULT FAIL (could not run: %s)" % e)
        return 2
    if listed is None:
        print("PRIVACY NOTE no private list (config/privacy.jsonc, or $LARES_PRIVACY_FILE): the term rule is off")
    if note_img:
        print("PRIVACY NOTE " + note_img)
    f = judge.findings
    for rule, path, line, value in f[:LIMIT]:
        print("PRIVACY %-8s %s%s  %s" % (rule, path, ":%d" % line if line else "", mask(value, a.show)))
    if len(f) > LIMIT:
        print("PRIVACY ... %d more" % (len(f) - LIMIT))
    print("PRIVACY judged %d files (%d images), %d private terms" % (files, images, len(terms)))
    if f:
        counts = {}
        for rule, *_ in f:
            counts[rule] = counts.get(rule, 0) + 1
        print("PRIVACY RESULT FAIL (%d findings: %s)" % (len(f), ", ".join("%s %d" % kv for kv in sorted(counts.items()))))
        return 1
    print("PRIVACY RESULT PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
