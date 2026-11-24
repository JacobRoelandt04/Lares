#!/usr/bin/env python3
"""privacy_check_cases.py -- the leak check (tools/publish/privacy_check.py) finds what it must and lets the stand-ins through.

    python3 -B tools/dev/privacy_check_cases.py             PRIVACY_CASES RESULT PASS | FAIL
    ARM=<arm> python3 -B tools/dev/privacy_check_cases.py   the check is weakened (PRIVACY_ARM): the aimed case goes red
    ARM=all python3 -B tools/dev/privacy_check_cases.py     every arm in its own run: PRIVACY_CASES ARMS RESULT PASS when each
                                                            fails on its own case
        termverbatim  a private value matched only as written        -> case "termsep"
        v6naive       the aerial scrubber's old IPv6 pattern          -> case "v6colon" (`IP6.ADDRESS[1]:2a..`, the real miss)
        noeui64       link-local addresses never judged               -> case "eui64"
        noemail       no e-mail rule                                  -> case "email"
        nohome        no home-directory rule                          -> case "home"
        noexif        image metadata not read                         -> case "gps"
        noexclude     an excluded path in a built export passes       -> case "excluded"
        noidentity    the export commit's e-mail is not judged        -> case "identity"

Every case is a throwaway git repository with a clean tree, one planted fault and a private list of INVENTED values. No real
value is in this file: the values that would trip the check on this very file are put together at run time.
"""
import os
import random
import shutil
import string
import subprocess
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
CHECK = os.path.join(ROOT, "tools", "publish", "privacy_check.py")
ARM = os.environ.get("ARM", "")
AIM = {"termverbatim": "termsep", "v6naive": "v6colon", "noeui64": "eui64", "noemail": "email", "nohome": "home",
       "noexif": "gps", "noexclude": "excluded", "noidentity": "identity"}

if ARM == "all":
    missed = []
    for a, case in AIM.items():
        r = subprocess.run([sys.executable, "-B", os.path.abspath(__file__)], env=dict(os.environ, ARM=a), capture_output=True, text=True)
        bit = r.returncode != 0 and ("PRIVACY_CASES FAIL %s:" % case) in r.stdout
        print("PRIVACY_CASES ARM %-12s %s" % (a, "failed as it must" if bit else "DID NOT FAIL"))
        if not bit:
            missed.append(a)
    print("PRIVACY_CASES ARMS RESULT " + ("PASS" if not missed else "FAIL (%s did not bite)" % ", ".join(missed)))
    sys.exit(1 if missed else 0)

C = ":"
MAC = C.join(["4c", "1d", "96", "0a", "7e", "3b"])                 # invented
TERM = "Zorblax-Home-Net"                                         # invented
RND = random.Random(7)
WORK = tempfile.mkdtemp(prefix="privacy-cases-")
LIST = os.path.join(WORK, "privacy.jsonc")
with open(LIST, "w") as f:
    f.write('// invented values\n{ "replace": { "%s": "HomeNet" }, "forbid": ["%s", "Quuxville"] }\n' % (TERM, MAC))

CLEAN = {
    "README.md": "A stand-in MAC 02:AE:00:00:00:01, user@example.com, git@github.com, 2001:db8::1, fe80::1, ::1, /home/user/x,\n"
                 "192.168.0.10, 1.1.1.1, 1.2.3.4, pkg-26.0.2.1, ghp_" + "X" * 36 + ", std::round, user@1000.service, icon@2x.png\n",
    "art/logo.svg": '<svg><path d="M1.92.96.96 2 2"/></svg>\n',
    "upstream.txt": "Author: someone@" + "upstream.org\n",
    "tools/publish/exclude.txt": "private/\n",
    "tools/publish/privacy_allow.txt": "email\tupstream.txt\tsomeone" + "@" + "upstream.org\n",
    "private/notes.md": "Quuxville " + TERM + "\n",            # excluded: never judged, only refused inside an export
}
CASES = {
    "term": ("src/a.qml", "// the " + TERM.lower() + " network\n"),
    "termsep": ("src/b.txt", "bssid " + MAC.replace(":", "").upper() + " and nmcli " + MAC.replace(":", "\\:") + "\n"
                         "printf 'yes:" + MAC.upper().replace(":", "\\\\:") + "\\n'\n"),          # a stub's printf: two backslashes
    "termspace": ("src/c.txt", "zorblax home net\n"),
    "v6colon": ("fx/nm.txt", "IP6.ADDRESS[1]:2a0c" + ":5a00:1:2:3:4:5:6/64\n"),
    "eui64": ("fx/gw.txt", "IP6.GATEWAY:fe80::4e1d" + ":96ff:fe0a:7e3b\n"),
    "stablell": ("fx/ll.txt", "addr fe80::1a2b" + ":3c4d:5e6f:7081\n"),
    "email": ("src/m.js", 'var me = "zorblax' + "@" + 'gmail.com";\n'),
    "home": ("src/h.sh", "cd /home/" + "zorblax/projects\n"),
    "mediahome": ("src/u.js", "// Mounted at /run/media/" + "zorblax/USB\n"),
    "ipv4": ("src/n.txt", "speaker at 81.82." + "83.84\n"),
    "mac": ("src/bt.qml", "// dev_" + "_".join(["5e", "71", "a0", "33", "c2", "19"]) + "\n"),
    "macesc": ("fx/nmcli", "printf 'no:" + "\\\\:".join(["5E", "71", "A0", "33", "C2", "19"]) + "\\n'\n"),
    "privkey": ("keys/id", "-----BEGIN OPENSSH " + "PRIVATE KEY-----\n"),
    "token": ("src/t.py", "TOKEN = 'ghp_" + "".join(RND.choice(string.ascii_letters + string.digits) for _ in range(36)) + "'\n"),
    "artifact": ("docs/x.md", "see https://claude." + "ai/artifact/AbCdEf123456\n"),
    "pathterm": ("fixtures/quuxville/a.txt", "nothing inside\n"),
}
results = []


def run(*args, env=None):
    return subprocess.run(["git"] + list(args), capture_output=True, text=True, env=env)


def repo(planted=None, with_private=False):
    d = tempfile.mkdtemp(dir=WORK)
    files = dict(CLEAN)
    if planted:
        files[planted[0]] = planted[1]
    for p, body in files.items():
        full = os.path.join(d, p)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb" if isinstance(body, bytes) else "w") as f:
            f.write(body)
    run("-C", d, "init", "-q")
    run("-C", d, "add", "-A")
    run("-C", d, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "x")
    return d


def check(d, *extra, listed=True):
    env = dict(os.environ, LARES_PRIVACY_FILE=LIST if listed else os.path.join(WORK, "none.jsonc"))
    env.pop("PRIVACY_ARM", None)
    if ARM:
        env["PRIVACY_ARM"] = ARM
    r = subprocess.run([sys.executable, "-B", CHECK, "--repo", d, "--show"] + list(extra), capture_output=True, text=True, env=env)
    return r.returncode, r.stdout + r.stderr


def expect(name, ok, out):
    results.append(ok)
    print("PRIVACY_CASES %s %s%s" % ("ok  " if ok else "FAIL", name, "" if ok else ":\n" + "\n".join("    " + l for l in out.splitlines()[-8:])))


try:
    code, out = check(repo())
    expect("clean", code == 0 and "PRIVACY RESULT PASS" in out, out)
    code, out = check(repo(), listed=False)
    expect("nolist", code == 0 and "the term rule is off" in out, out)

    rule_of = {"term": "term", "termsep": "term", "termspace": "term", "v6colon": "ipv6", "eui64": "ipv6", "stablell": "ipv6",
               "email": "email", "home": "home", "mediahome": "home", "ipv4": "ipv4", "mac": "mac", "privkey": "key",
               "token": "key", "artifact": "artifact", "pathterm": "term", "macesc": "mac"}
    for name, planted in CASES.items():
        code, out = check(repo(planted))
        want = "PRIVACY %-8s %s" % (rule_of[name], planted[0])
        hits = sum(1 for l in out.splitlines() if l.startswith(want))
        need = 3 if name == "termsep" else 1
        expect(name, code == 1 and hits >= need, out)

    # an image with a GPS position: exiftool writes it, exiftool must read it back through the check
    if shutil.which("exiftool"):
        from PIL import Image
        img = os.path.join(WORK, "gps.jpg")
        Image.new("RGB", (8, 8), (40, 90, 160)).save(img)
        subprocess.run(["exiftool", "-q", "-overwrite_original", "-GPSLatitude=50.5", "-GPSLatitudeRef=N",
                        "-GPSLongitude=4.5", "-GPSLongitudeRef=E", img], check=True)
        with open(img, "rb") as f:
            code, out = check(repo(("assets/photo.jpg", f.read())))
        expect("gps", code == 1 and "PRIVACY image    assets/photo.jpg" in out, out)
        Image.new("RGB", (8, 8), (40, 90, 160)).save(img)
        with open(img, "rb") as f:
            code, out = check(repo(("assets/photo.jpg", f.read())))
        expect("nogps", code == 0, out)
    else:
        print("PRIVACY_CASES NOTE exiftool is not installed: the image cases are skipped")

    # a BUILT export: the excluded path inside it is refused, and the commit's identity is judged
    d = repo()
    tree = run("-C", d, "rev-parse", "HEAD^{tree}").stdout.strip()
    code, out = check(d, "--tree", tree, "--export")
    expect("excluded", code == 1 and "PRIVACY excluded private/notes.md" in out, out)
    run("-C", d, "rm", "-rq", "--cached", "private")
    run("-C", d, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "drop")
    tree = run("-C", d, "rev-parse", "HEAD^{tree}").stdout.strip()
    env = dict(os.environ, GIT_AUTHOR_NAME="Someone", GIT_AUTHOR_EMAIL="zorblax" + "@gmail.com",
               GIT_COMMITTER_NAME="Someone", GIT_COMMITTER_EMAIL="zorblax" + "@gmail.com")
    bad = run("-C", d, "commit-tree", tree, "-m", "export", env=env).stdout.strip()
    code, out = check(d, "--tree", tree, "--export", "--commit", bad)
    expect("identity", code == 1 and "PRIVACY identity" in out, out)
    env.update(GIT_AUTHOR_EMAIL="1+someone@users.noreply.github.com", GIT_COMMITTER_EMAIL="1+someone@users.noreply.github.com")
    good = run("-C", d, "commit-tree", tree, "-m", "export", env=env).stdout.strip()
    code, out = check(d, "--tree", tree, "--export", "--commit", good)
    expect("goodexport", code == 0 and "PRIVACY RESULT PASS" in out, out)
finally:
    shutil.rmtree(WORK, ignore_errors=True)

n, bad = len(results), results.count(False)
print("PRIVACY_CASES RESULT " + ("PASS (%d cases)" % n if not bad else "FAIL (%d of %d cases)" % (bad, n)))
sys.exit(1 if bad else 0)
