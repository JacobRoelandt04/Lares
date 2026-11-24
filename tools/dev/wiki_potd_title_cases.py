#!/usr/bin/env python3
"""wiki_potd_title_cases.py -- the picture of the day's card title (tools/wiki/lib/title.py, daily.weekly_entry).

    python3 tools/dev/wiki_potd_title_cases.py            WIKITITLE RESULT PASS | FAIL (<n>/<n> checks)
    ARM=nocheck python3 tools/dev/wiki_potd_title_cases.py   the model's answer is trusted unchecked: the "recital" cases go red
    ARM=nocleanup python3 tools/dev/wiki_potd_title_cases.py the deterministic cleanup is off: the "Pez ballesta" case goes red

No network, no Ollama: the model is a stub `chat`, the entry is made in a private state dir (XDG_STATE_HOME / XDG_CACHE_HOME).
The feed's picture is shaped like commons._potd's output (the user's file, 2026-11: "Pez ballesta ondulado ...").
The Jev key is never involved: the title is not a judge's question (it writes text; Jev answers probabilities)."""
import os
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools", "wiki"))
ARM = os.environ.get("ARM", "")
tmp = tempfile.mkdtemp(prefix="wikititle.")
os.environ["XDG_STATE_HOME"] = os.path.join(tmp, "state")
os.environ["XDG_CACHE_HOME"] = os.path.join(tmp, "cache")
os.environ["XDG_CONFIG_HOME"] = os.path.join(tmp, "config")

from lib import daily, entry, generate, judge, paths, title as T  # noqa: E402

if ARM == "nocheck":
    T.title_problem = lambda text, file_title, description: None
if ARM == "nocleanup":
    _orig_clean = T.clean
    T.clean = lambda ft: T.file_name(ft)

checks = fails = 0


def check(name, ok, detail=""):
    global checks, fails
    checks += 1
    if not ok:
        fails += 1
    print("WT %s %s%s" % ("ok  " if ok else "FAIL", name, "" if ok else "  [%s]" % detail))


PEZ = "File:Pez_ballesta_ondulado_(Balistapus_undulatus),_mar_Rojo,_Egipto,_2023-04-15,_DD_45.jpg"
PEZ_DESC = ("The clown triggerfish, Balistapus undulatus, a colourful reef fish photographed in the Red Sea off Egypt in April 2023, "
            "hovering over coral and defending its nest against divers who come too close, as triggerfish are known to do "
            "during the breeding season.")

# 1. the deterministic cleanup
cases = [
    (PEZ, "Pez ballesta ondulado"),
    ("File:Split_Cathedral_Bell_Tower_From_The_Vestibule_-_Split.jpg", "Split Cathedral Bell Tower From The Vestibule"),
    ("File:Sunset over Lake Tahoe 20230415 DSC_1234.jpg", "Sunset over Lake Tahoe"),
    ("File:Mont Blanc, 15 April 2023, IMG_0042 (cropped).jpg", "Mont Blanc"),
    ("File:Bell tower, Split, Croatia.jpg", "Bell tower, Split"),
    ("File:Gran Canaria, Roque Nublo (2).jpg", "Gran Canaria, Roque Nublo"),
    ("File:Balistapus undulatus.jpg", "Balistapus undulatus"),
    ("File:A view of the jet and shadow of M87’s black hole (eso2305a).jpg", "A view of the jet and shadow of M87’s black hole"),
    ("File:Vue de la Tour, 3 mars 2021, photo par Jean.jpg", "Vue de la Tour"),
]
for ft, want in cases:
    got = T.clean(ft)
    check("clean %s" % ft[5:40], got == want, "%r != %r" % (got, want))
check("the user's case fits with no model", T.short_title(PEZ, PEZ_DESC) == ("Pez ballesta ondulado", "cleaned"), str(T.short_title(PEZ, PEZ_DESC)))
long_ft = "File:Bayeux Tapestry scene51 Battle of Hastings Norman knights and archers in the second row.jpg"
t, how = T.short_title(long_ft, "")
check("too long, no model: cut at a word, with an ellipsis", how == "cut" and len(t) <= T.LIMIT and t.endswith(T.ELLIPSIS) and not t[:-1].endswith(" "), repr((t, how)))

# 2. the model's short title is checked by code
desc = "Norman knights and archers in the Battle of Hastings, scene 51 of the Bayeux Tapestry."
good = lambda msgs: "Norman knights and archers"
t, how = T.short_title(long_ft, desc, good)
check("a clean answer is used", (t, how) == ("Norman knights and archers", "model"), repr((t, how)))
check("quotes and a full stop are tidied", T.short_title(long_ft, desc, lambda m: '"Norman knights and archers."')[0] == "Norman knights and archers")
bad = {
    "a recital of the rules": "Short title of at most 6 words: Norman knights",
    "a single letter": "x",
    "meta about the picture": "This image shows Norman knights",
    "an invented word": "Norman knights storming Jerusalem",
    "too long": "Norman knights and archers at the Battle of Hastings in 1066, scene fifty one",
    "empty": "",
}
for why, reply in bad.items():
    calls = []

    def chat(msgs, reply=reply, calls=calls):
        calls.append(msgs)
        return reply
    t, how = T.short_title(long_ft, desc, chat)
    check("%s is refused, the cut title stands" % why, how == "cut" and len(t) <= T.LIMIT and len(calls) == 2, repr((t, how, len(calls))))
    check("%s: the retry is told why" % why, len(calls) == 2 and "That title" in calls[1][-1]["content"], "")
# a preamble and a second line are tidied away, not refused
check("a preamble is stripped", T.short_title(long_ft, desc, lambda m: "Here is a short title: Norman knights and archers")[0] == "Norman knights and archers")
check("a title wrapped over two lines is one line", T.short_title(long_ft, desc, lambda m: "Norman knights\nand archers")[0] == "Norman knights and archers")
# the retry can recover
seq = iter(["Norman knights storming Jerusalem", "Norman knights and archers"])
t, how = T.short_title(long_ft, desc, lambda m: next(seq))
check("a second try may recover", (t, how) == ("Norman knights and archers", "model"), repr((t, how)))
# an unreachable model is the cut title, not an error
def down(msgs):
    raise judge.JudgeUnavailable("Ollama is not reachable")
t, how = T.short_title(long_ft, desc, down)
check("model down: the cut title", how == "cut", how)

# 3. the request the model gets: both texts, no key anywhere
seen = []
T.short_title(long_ft, desc, lambda m: seen.append(m) or "Norman knights")
body = " ".join(x["content"] for x in seen[0])
check("the model sees the file name and the English description", "Bayeux Tapestry scene51" in body and "Norman knights and archers in the Battle" in body, body[:200])
check("no key or env value in the prompt", "JEV" not in body.upper() and "KEY" not in body.upper().replace("KEEP", ""), "")

# 4. end to end: the entry's title is short, its link is the original
paths_dirs = (paths.state_dir(), os.path.join(paths.state_dir(), "img"))
for d in paths_dirs:
    os.makedirs(d, exist_ok=True)
for rel in ("img/potd-2026-11-06.jpg", "img/potd-2026-11-06-thumb.jpg"):
    with open(os.path.join(paths.state_dir(), rel), "wb") as f:
        f.write(b"\xff\xd8\xff\xd9")
feed = {"fileTitle": PEZ, "file_page": "https://commons.wikimedia.org/wiki/" + PEZ[5:], "license": "CC BY-SA 4.0",
        "description": PEZ_DESC, "artist": "X", "thumb_url": "https://example.invalid/t.jpg"}
potd = {"fileTitle": PEZ, "file": "img/potd-2026-11-06.jpg", "thumb": "img/potd-2026-11-06-thumb.jpg", "credit": "X, CC BY-SA 4.0",
        "license": "CC BY-SA 4.0", "description": PEZ_DESC[:300], "relatesTo": None, "entryId": None, "w": 640, "h": 360,
        "aspect": 1.78, "focusY": 0.5}
logs = []
ident = daily.weekly_entry("2026-11-06", feed, potd, deny=(), log=logs.append)
import json
e = json.load(open(paths.entry_path("discover", ident)))
check("the entry exists", bool(ident), str(logs))
check("its card title is the short one", e.get("title") == "Pez ballesta ondulado", repr(e.get("title")))
check("its source keeps the file's own title and the link", e["source"]["title"] == PEZ and PEZ[5:] in e["source"]["url"], str(e["source"]))
print("WT RESULT %s (%d/%d checks)" % ("PASS" if fails == 0 else "FAIL", checks - fails, checks))
sys.exit(1 if fails else 0)
