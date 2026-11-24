#!/usr/bin/env python3
"""make_landmask.py -- the globe's land mask, derived from Natural Earth's 1:110m land (public domain).

Downloads ne_110m_land.geojson into ~/.cache/claude-orch/aerial/natural-earth/ (never the repo), rasterises an equirectangular mask
(longitude -180..180 left to right, latitude 90..-90 top to bottom, one channel, 255 = land) at 4x and averages it down, and writes the
committed texture modules/aerial/scene/assets/landmask.png. The dots are drawn by the shader (modules/aerial/shaders/globe.frag); this is DATA, not art.
Re-running reproduces the same bytes (PIL's PNG writer stores no time; the source file is the cached copy).

    tools/aerial/make_landmask.py [--check] [--out PATH] [--cache DIR]
      --check   write nothing: rasterise and compare with the committed file (exit 1 when they differ)
"""
import argparse, hashlib, json, os, sys, urllib.request
from PIL import Image, ImageDraw

URL = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_land.geojson"
LICENCE = "Natural Earth: public domain (https://www.naturalearthdata.com/about/terms-of-use/); no permission needed, credit is courteous."
W, H, SS = 512, 256, 4
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(ROOT, "modules/aerial/scene/assets/landmask.png")


def load(cache):
    os.makedirs(cache, exist_ok=True)
    path = os.path.join(cache, "ne_110m_land.geojson")
    if not os.path.exists(path):
        req = urllib.request.Request(URL, headers={"User-Agent": "lares-aerial-landmask/1"})
        with urllib.request.urlopen(req, timeout=60) as r, open(path + ".part", "wb") as f:
            f.write(r.read())
        os.replace(path + ".part", path)
    with open(path, "rb") as f:
        raw = f.read()
    return json.loads(raw), hashlib.sha256(raw).hexdigest()


def render(gj):
    img = Image.new("L", (W * SS, H * SS), 0)
    d = ImageDraw.Draw(img)

    def px(ring):
        return [((lon + 180.0) / 360.0 * W * SS, (90.0 - lat) / 180.0 * H * SS) for lon, lat in ring]

    for ft in gj["features"]:
        g = ft["geometry"]
        polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
        for poly in polys:
            d.polygon(px(poly[0]), fill=255)
            for hole in poly[1:]:
                d.polygon(px(hole), fill=0)
    return img.resize((W, H), Image.BOX)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--cache", default=os.path.expanduser("~/.cache/claude-orch/aerial/natural-earth"))
    a = ap.parse_args()
    gj, digest = load(a.cache)
    img = render(gj)
    print("source:", URL)
    print("source sha256:", digest)
    print("licence:", LICENCE)
    tmp = a.out + ".tmp.png"
    if a.check:
        img.save(tmp, optimize=False)
        same = open(tmp, "rb").read() == open(a.out, "rb").read() if os.path.exists(a.out) else False
        os.remove(tmp)
        print("LANDMASK", "same" if same else "DIFFERS", a.out)
        return 0 if same else 1
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    img.save(a.out, optimize=False)
    hist = img.histogram(); land = sum(hist[128:]) / (W * H)
    print("wrote", a.out, "%dx%d" % (W, H), "land share %.3f" % land)
    return 0


sys.exit(main())
