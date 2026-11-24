#!/usr/bin/env python3
"""Send one System One (Jev) request through the Defapi reseller and record the answer.

    jev_probe.py REQUEST.json [--out RESPONSE.json] [--base URL] [--path PATH]
                 [--auth-style bearer|x-api-key] [--model NAME] [--timeout S]
                 [--dry-run]

REQUEST.json holds {"state": ..., "questions": {...}} (a "model" key is used when --model is not
given). The key is `jevKey` of config/wiki.jsonc, read the way the tool reads it (lib/env.jev_key,
XDG_CONFIG_HOME honoured): it never appears on the command line, in the printed request (--dry-run
redacts it), in an error message or in the saved response (every output is scrubbed of it).
Redirects are NOT followed, so the key can never travel to another host.

Defaults are what Defapi really serves (docs/contracts/wiki_jev_api.md): POST
https://api.defapi.org/api/v1/decisions, Authorization: Bearer <key>, model typesafe/jev-1.13.
The path on Defapi's model page and in TypeSafe's own docs (/v1/systemone) answers 404 there.

Exit: 0 got a 2xx, 1 HTTP error status, 2 usage / setup, 3 network failure.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from lib import env as wenv, paths as wpaths  # noqa: E402  (the wiki tool's own reader of the key)
DEFAULT_BASE = "https://api.defapi.org"
DEFAULT_PATH = "/api/v1/decisions"
DEFAULT_MODEL = "typesafe/jev-1.13"
UA = "lares-wiki/0.1 (+https://github.com/JacobRoelandt04/Lares)"


class Scrub:
    """Removes the secret (and its Bearer form) from any text before it leaves the process."""

    def __init__(self, secret):
        self.secret = secret

    def __call__(self, text):
        if self.secret and text:
            text = text.replace(self.secret, "<redacted>")
        return text


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def build_headers(style, key):
    h = {"Content-Type": "application/json", "Accept": "application/json", "User-Agent": UA}
    if style == "bearer":
        h["Authorization"] = "Bearer " + key
    else:
        h["x-api-key"] = key
    return h


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("request", help="JSON file with {state, questions}")
    ap.add_argument("--out", help="save the response body here (scrubbed)")
    ap.add_argument("--base", default=DEFAULT_BASE)
    ap.add_argument("--path", default=DEFAULT_PATH)
    ap.add_argument("--auth-style", choices=["bearer", "x-api-key"], default="bearer")
    ap.add_argument("--model", default=None)
    ap.add_argument("--timeout", type=float, default=30.0)
    ap.add_argument("--dry-run", action="store_true", help="print the request with the key redacted; send nothing")
    args = ap.parse_args()

    key = wenv.jev_key()
    scrub = Scrub(key)
    try:
        with open(args.request, encoding="utf-8") as f:
            req = json.load(f)
    except (OSError, ValueError) as e:
        print("cannot read request file: %s" % scrub(str(e)), file=sys.stderr)
        return 2
    if not isinstance(req, dict) or "state" not in req or "questions" not in req:
        print("request file needs top-level 'state' and 'questions'", file=sys.stderr)
        return 2

    body = {"model": args.model or req.get("model") or DEFAULT_MODEL,
            "state": req["state"], "questions": req["questions"]}
    raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
    url = args.base.rstrip("/") + "/" + args.path.lstrip("/")

    if not key and not args.dry_run:
        print(wenv.old_env_hint() or "no jevKey in %s" % wpaths.config_path(), file=sys.stderr)
        return 2

    headers = build_headers(args.auth_style, key or "<missing>")
    if args.dry_run:
        shown = dict(headers)
        for h in ("Authorization", "x-api-key"):
            if h in shown:
                shown[h] = "Bearer <redacted>" if h == "Authorization" else "<redacted>"
        print("POST %s" % url)
        for k, v in shown.items():
            print("%s: %s" % (k, v))
        print("key present in %s: %s" % (wpaths.config_path(), "yes" if key else "NO"))
        print("body bytes: %d" % len(raw))
        print(json.dumps(body, ensure_ascii=False, indent=2))
        return 0

    opener = urllib.request.build_opener(NoRedirect)
    request = urllib.request.Request(url, data=raw, headers=headers, method="POST")
    t0 = time.monotonic()
    status, text, hdrs, err = None, "", {}, None
    try:
        with opener.open(request, timeout=args.timeout) as resp:
            status, text, hdrs = resp.status, resp.read().decode("utf-8", "replace"), dict(resp.headers)
    except urllib.error.HTTPError as e:
        status, hdrs = e.code, dict(e.headers)
        try:
            text = e.read().decode("utf-8", "replace")
        except Exception:
            text = ""
    except Exception as e:  # URLError, timeout, TLS: text only, scrubbed
        err = "%s: %s" % (type(e).__name__, scrub(str(e)))
    ms = (time.monotonic() - t0) * 1000.0

    if err:
        print("NETWORK FAILURE after %.0f ms: %s" % (ms, err), file=sys.stderr)
        return 3

    text = scrub(text)
    print("POST %s" % url)
    print("HTTP %d in %.0f ms" % (status, ms))
    for h in ("content-type", "retry-after", "x-request-id", "x-ratelimit-remaining", "location", "server"):
        for k, v in hdrs.items():
            if k.lower() == h:
                print("%s: %s" % (k, scrub(v)))
    try:
        shown = json.dumps(json.loads(text), ensure_ascii=False, indent=2)
    except ValueError:
        shown = text
    print(shown)
    if args.out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(shown + "\n")
        print("saved -> %s" % args.out)
    return 0 if 200 <= status < 300 else 1


if __name__ == "__main__":
    sys.exit(main())
