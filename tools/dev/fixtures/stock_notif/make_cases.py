#!/usr/bin/env python3
"""Writes the stock-card cases next to this file (deterministic). Each case is a quote as StocksNotifier sees it, in
MINUTES FROM THE SESSION'S OPEN, so a probe places it against the real clock: { name, symbol, label, currency, priceHint,
prevClose, nowMin, bars: [[min, close]...] (the 5-minute spark, gaps kept), live (the price now, at nowMin), kind, level }.
Shapes mirror what the user's quotes look like: a late-session drop after a quiet day, a mid-morning jump, a jump nine
minutes after the open (3 points), a thin stock with gaps up to 35 minutes, and one alert of each kind."""
import json, math, os, random

HERE = os.path.dirname(os.path.abspath(__file__))


def walk(seed, start, mins, sigma, drift=0.0):
    r = random.Random(seed)
    v, out = start, []
    for m in mins:
        v *= 1 + drift + r.gauss(0, sigma)
        out.append([m, round(v, 3)])
    return out


def case(name, **kw):
    kw["name"] = name
    json.dump(kw, open(os.path.join(HERE, name + ".json"), "w"), indent=1)
    kw["_n"] = len(kw["bars"])
    print(name, len(kw["bars"]), "bars")


# (a) a drop late in the session: ~58 bars of a quiet day, then 103.4 -> 100.1 in the last 30 minutes
mins = list(range(0, 291, 5))
bars = walk(11, 100.0, mins, 0.0012, 0.00008)
bars = [[m, c] for m, c in bars]
for i, (m, c) in enumerate(bars):
    if m >= 265:
        bars[i][1] = round(103.4 - (103.4 - 100.3) * (m - 265) / 25.0, 3)
bars[[m for m, _ in bars].index(260)][1] = 103.2
case("a_drop_late", symbol="NVDA", label="NVDA", currency="USD", priceHint=2, prevClose=101.2, nowMin=292, bars=bars,
     live=100.1, kind="sudden", level=None, pct=3, minutes=30)

# (b) a jump mid-morning: 6 bars in the window
mins = list(range(0, 116, 5))
bars = walk(5, 200.0, mins, 0.0006)
for i, (m, c) in enumerate(bars):
    if m <= 85:
        bars[i][1] = round(200.0 + 0.6 * math.sin(m / 9.0), 3)
    elif m == 90:
        bars[i][1] = 201.0
    else:
        bars[i][1] = round(201.0 + (m - 90) * 0.2 + 0.25 * math.sin(m), 3)
case("b_jump_morning", symbol="ASML", label="ASML", currency="EUR", priceHint=2, prevClose=199.4, nowMin=118, bars=bars,
     live=209.5, kind="sudden", level=None, pct=3, minutes=30)

# (c) a jump nine minutes after the open: three points
case("c_jump_after_open", symbol="UCB", label="UCB", currency="EUR", priceHint=2, prevClose=50.0, nowMin=9,
     bars=[[0, 50.2], [5, 50.6]], live=51.95, kind="sudden", level=None, pct=3, minutes=30)

# (d) a thin stock: gaps up to 35 minutes
gaps = [0, 5, 20, 25, 60, 65, 70, 105, 110, 145, 150, 175, 180, 200]
vals = [12.38, 12.40, 12.31, 12.33, 12.36, 12.30, 12.34, 12.41, 12.37, 12.39, 12.43, 12.45, 12.46, 12.52]
case("d_thin_gaps", symbol="KBC.BR", label="KBC", currency="EUR", priceHint=2, prevClose=12.40, nowMin=205,
     bars=[[m, v] for m, v in zip(gaps, vals)], live=12.97, kind="sudden", level=None, pct=3, minutes=30)

# alerts: one of each kind
mins = list(range(0, 211, 5))
b = walk(21, 100.0, mins, 0.0010, 0.0001)
b = [[m, round(c + (m / 210.0) * 3.2, 3)] for m, c in b]
case("e_above", symbol="AAPL", label="AAPL", currency="USD", priceHint=2, prevClose=100.0, nowMin=212, bars=b,
     live=105.4, kind="above", level=105.0)
b = [[m, round(200 - (m / 210.0) * 7.0 + 0.9 * math.sin(m / 11.0), 3)] for m in mins]
case("f_below", symbol="MSFT", label="MSFT", currency="USD", priceHint=2, prevClose=200.0, nowMin=212, bars=b,
     live=192.1, kind="below", level=193.0)
b = [[m, round(48.0 + (m / 210.0) * 1.2 + 0.25 * math.sin(m / 7.0), 3)] for m in mins]
case("g_daymove", symbol="VOD.L", label="Vodafone", currency="GBp", priceHint=2, prevClose=48.0, nowMin=212, bars=b,
     live=49.3, kind="dayMove", level=2.0)
