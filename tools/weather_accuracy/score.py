#!/usr/bin/env python3
"""Score the logged forecasts against the logged observations.

Joins forecasts-*.jsonl to observations-*.jsonl on valid_time (one station) and prints, per
source/model x variable x lead bucket (0-6, 6-12, 12-24, 24-48, 48+ h):
    temp, humidity, pressure, wind, gust:  MAE / bias (forecast - observed), N
    wind, gust:                            + Beaufort-class agreement (bands of WeatherScales.js)
    precip:                                MAE, hit rate and false-alarm ratio for >= 0.1 mm/h, N
    precip_prob:                           Brier score against precip >= 0.1 mm/h, N
cloud, wcode and kmi_ww have no station observation and are not scored.

--backfill DAYS adds the Open-Meteo Previous Runs API (previous_day1..7 = the value predicted
24..168 h before valid time, so lead_h = 24*N) for the past DAYS days, plus the station's
observations for the same span, so the Open-Meteo models get a ranking on day one. KMI cannot be
backfilled: it has no archive; its rows accumulate one fetch per hour from the first collect.

--kmi-precip-shift H compares KMI's hourly precipitation with the observation H hours later
(KMI does not say whether its "19 h" amount is the hour before or after 19:00; 0 by default).

    score.py [--backfill DAYS] [--json] [--station CODE] [--kmi-precip-shift H] [--var NAME ...]
"""
import argparse
import datetime as dt
import glob
import json
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C          # noqa: E402
import observe as O         # noqa: E402

PREVIOUS_RUNS_URL = "https://previous-runs-api.open-meteo.com/v1/forecast"
PREVIOUS_DAYS = 7
BUCKETS = [("0-6h", 0, 6), ("6-12h", 6, 12), ("12-24h", 12, 24), ("24-48h", 24, 48), ("48h+", 48, 10 ** 9)]
SCORED = ["temp", "precip", "precip_prob", "wind", "gust", "humidity", "pressure"]
EVENT_MM = 0.1


def bucket_of(lead_h):
    for name, lo, hi in BUCKETS:
        if lo <= lead_h < hi:
            return name
    return None


# ---------------------------------------------------------------------------- backfill

def previous_runs_url(loc, model, days):
    hourly = [f"{v}_previous_day{n}" for v in C.OPENMETEO_VARS if v != "precipitation_probability"
              for n in range(1, PREVIOUS_DAYS + 1)]
    q = {"latitude": f"{loc['lat']:.4f}", "longitude": f"{loc['lon']:.4f}", "models": model,
         "hourly": ",".join(hourly), "past_days": days, "forecast_days": 1,
         "timezone": "UTC", "timeformat": "iso8601"}
    return PREVIOUS_RUNS_URL + "?" + urllib.parse.urlencode(q)


def parse_previous_runs(resp, fallback_model="best_match"):
    """Rows {source: openmeteo, model, fetched_at: None, valid_time, lead_h: 24*N, values,
    backfill: True} from a Previous Runs response; keys are <var>_previous_day<N>[_<model>]."""
    hourly = resp.get("hourly") or {}
    times = hourly.get("time") or []
    offset = dt.timedelta(seconds=int(resp.get("utc_offset_seconds") or 0))
    per = {}
    for key, series in hourly.items():
        if key == "time" or "_previous_day" not in key:
            continue
        omvar, rest = key.split("_previous_day", 1)
        name = C.OPENMETEO_VARS.get(omvar)
        if name is None:
            continue
        digits = ""
        while rest and rest[0].isdigit():
            digits, rest = digits + rest[0], rest[1:]
        if not digits:
            continue
        model = rest[1:] if rest.startswith("_") else fallback_model
        per.setdefault((model, int(digits)), {})[name] = series
    rows = []
    for (model, n), series_by_var in per.items():
        for i, t in enumerate(times):
            values = {name: s[i] for name, s in series_by_var.items() if i < len(s) and s[i] is not None}
            if not values:
                continue
            valid = dt.datetime.fromisoformat(t).replace(tzinfo=C.UTC) - offset
            rows.append({"source": "openmeteo", "model": model, "fetched_at": None,
                         "valid_time": C.iso_z(valid), "lead_h": 24 * n, "values": values,
                         "backfill": True})
    return rows


def backfill_rows(loc, days):
    rows, notes = [], []
    if C.fixtures_dir():
        data, _ = C.fetch_json("", "openmeteo_previous_runs.json")
        rows = parse_previous_runs(data)
        notes.append("fixture openmeteo_previous_runs.json")
        return rows, notes
    for model in C.OPENMETEO_MODELS:
        try:
            data, _ = C.fetch_json(previous_runs_url(loc, model, days), "")
            got = parse_previous_runs(data, fallback_model=model)
            rows += got
            days_seen = sorted({r["lead_h"] // 24 for r in got})
            notes.append(f"{model}: {len(got)} rows, previous_day {days_seen}" if got else f"{model}: nothing")
        except C.FetchError as e:
            notes.append(f"{model}: {e}")
    return rows, notes


# ---------------------------------------------------------------------------- loading

def load_forecasts():
    rows = []
    for path in sorted(glob.glob(os.path.join(C.data_dir(), "forecasts-*.jsonl"))):
        rows += list(C.iter_rows(path))
    return rows


def load_observations():
    rows = []
    for path in sorted(glob.glob(os.path.join(C.data_dir(), "observations-*.jsonl"))):
        rows += list(C.iter_rows(path))
    return rows


def pick_station(obs_rows, code=None):
    if code is not None:
        return code
    counts = {}
    for r in obs_rows:
        counts[r["station"]] = counts.get(r["station"], 0) + 1
    return max(counts, key=counts.get) if counts else None


# ---------------------------------------------------------------------------- scoring

class Cell:
    __slots__ = ("n", "abs_err", "err", "hits", "misses", "false_alarms", "brier", "bft_agree")

    def __init__(self):
        self.n = self.hits = self.misses = self.false_alarms = self.bft_agree = 0
        self.abs_err = self.err = self.brier = 0.0

    def add(self, var, f, o):
        self.n += 1
        if var == "precip_prob":
            p = f / 100.0
            self.brier += (p - (1.0 if o >= EVENT_MM else 0.0)) ** 2
            return
        self.abs_err += abs(f - o)
        self.err += f - o
        if var == "precip":
            fe, oe = f >= EVENT_MM, o >= EVENT_MM
            if fe and oe:
                self.hits += 1
            elif oe:
                self.misses += 1
            elif fe:
                self.false_alarms += 1
        elif var in ("wind", "gust") and C.beaufort(f) == C.beaufort(o):
            self.bft_agree += 1

    def result(self, var):
        r = {"n": self.n}
        if self.n == 0:
            return r
        if var == "precip_prob":
            r["brier"] = round(self.brier / self.n, 4)
            return r
        r["mae"] = round(self.abs_err / self.n, 3)
        r["bias"] = round(self.err / self.n, 3)
        if var == "precip":
            events = self.hits + self.misses
            alarms = self.hits + self.false_alarms
            r["events"] = events
            r["hit_rate"] = round(self.hits / events, 3) if events else None
            r["false_alarm_ratio"] = round(self.false_alarms / alarms, 3) if alarms else None
        elif var in ("wind", "gust"):
            r["beaufort_agreement"] = round(self.bft_agree / self.n, 3)
        return r


def label_of(row):
    return row["model"] if row["source"] == "kmi" else f"{row['source']}/{row['model']}"


def score(forecasts, obs_by_time, kmi_precip_shift=0):
    """-> tables[var][label][bucket] = Cell, plus the count of forecast rows that found an
    observation."""
    tables = {v: {} for v in SCORED}
    joined = 0
    for row in forecasts:
        bucket = bucket_of(row["lead_h"])
        o = obs_by_time.get(row["valid_time"])
        if bucket is None or o is None:
            continue
        joined += 1
        label = label_of(row)
        for var, f in row["values"].items():
            if var not in tables or not isinstance(f, (int, float)):
                continue
            target = o
            if var in ("precip", "precip_prob") and row["source"] == "kmi" and kmi_precip_shift:
                shifted = C.parse_iso(row["valid_time"]) + dt.timedelta(hours=kmi_precip_shift)
                target = obs_by_time.get(C.iso_z(shifted))
                if target is None:
                    continue
            ov = target.get("precip" if var == "precip_prob" else var)
            if not isinstance(ov, (int, float)):
                continue
            tables[var].setdefault(label, {}).setdefault(bucket, Cell()).add(var, f, ov)
    return tables, joined


def results_of(tables):
    out = {}
    for var, by_label in tables.items():
        out[var] = {label: {b: cell.result(var) for b, cell in cells.items()}
                    for label, cells in by_label.items()}
    return out


def ranking(tables, max_lead=48):
    """Per variable: labels sorted by N-weighted MAE (Brier for precip_prob) over leads < max_lead."""
    out = {}
    for var, by_label in tables.items():
        scores = []
        for label, cells in by_label.items():
            n = tot = 0.0
            for bname, lo, hi in BUCKETS:
                if hi > max_lead:
                    continue
                c = cells.get(bname)
                if c and c.n:
                    n += c.n
                    tot += c.brier if var == "precip_prob" else c.abs_err
            if n:
                scores.append((round(tot / n, 3), int(n), label))
        scores.sort()
        out[var] = [{"label": l, "score": s, "n": n} for s, n, l in scores]
    return out


# ---------------------------------------------------------------------------- output

def fmt_cell(var, r):
    if not r or not r.get("n"):
        return "-"
    n = r["n"]
    if var == "precip_prob":
        return f"{r['brier']:.3f} ({n})"
    if var == "precip":
        hr = "-" if r["hit_rate"] is None else f"{r['hit_rate']:.2f}"
        far = "-" if r["false_alarm_ratio"] is None else f"{r['false_alarm_ratio']:.2f}"
        return f"{r['mae']:.2f} {hr}/{far} ({n})"
    if var in ("wind", "gust"):
        return f"{r['mae']:.1f}/{r['bias']:+.1f} {r['beaufort_agreement']:.0%} ({n})"
    return f"{r['mae']:.2f}/{r['bias']:+.2f} ({n})"


HEADINGS = {
    "temp": "temp (degC): MAE / bias (N)",
    "humidity": "humidity (%): MAE / bias (N)",
    "pressure": "pressure, sea level (hPa): MAE / bias (N)",
    "wind": "wind (km/h): MAE / bias, Beaufort-class agreement (N)",
    "gust": "gust (km/h): MAE / bias, Beaufort-class agreement (N)",
    "precip": f"precip (mm/h): MAE, hit rate / false-alarm ratio at >= {EVENT_MM} mm (N)",
    "precip_prob": f"precip_prob: Brier score against precip >= {EVENT_MM} mm (N; 0 is perfect, 0.25 is a coin)",
}


def print_text(report):
    print(f"Forecast accuracy -- {report['location']['name']} "
          f"({report['location']['lat']:.2f}, {report['location']['lon']:.2f}); "
          f"station {report['station']}")
    print(f"forecast rows {report['forecast_rows']} ({report['forecast_rows_joined']} joined), "
          f"observation hours {report['observation_hours']}")
    for line in report["notes"]:
        print(f"  {line}")
    labels_w = max([len(l) for t in report["tables"].values() for l in t] + [12])
    col_w = 23
    for var in report["vars"]:
        table = report["tables"].get(var) or {}
        print()
        print(HEADINGS[var])
        print("".ljust(labels_w) + "".join(b[0].rjust(col_w) for b in BUCKETS))
        if not table:
            print("  (no joined rows)")
            continue
        for label in sorted(table):
            print(label.ljust(labels_w) + "".join(fmt_cell(var, table[label].get(b[0])).rjust(col_w) for b in BUCKETS))
    print()
    print("Ranking, leads 0-48 h (N-weighted MAE; Brier for precip_prob), best first:")
    for var in report["vars"]:
        r = report["ranking"].get(var) or []
        line = "  ".join(f"{e['label']} {e['score']} ({e['n']})" for e in r) or "(nothing scored)"
        print(f"  {var:<12}{line}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--backfill", type=int, metavar="DAYS", help="add Open-Meteo previous runs for the past DAYS days")
    ap.add_argument("--json", action="store_true", help="print the report as JSON")
    ap.add_argument("--station", type=int, help="AWS station code (default: the one with most observations)")
    ap.add_argument("--kmi-precip-shift", type=int, default=0, metavar="H")
    ap.add_argument("--var", action="append", choices=SCORED, help="only these variables")
    args = ap.parse_args(argv)

    loc, _ = C.load_location()
    now = C.now_utc()
    forecasts = load_forecasts()
    observations = load_observations()
    notes = []
    if args.backfill:
        days = max(1, min(args.backfill, 92))
        bf, bnotes = backfill_rows(loc, days)
        forecasts += bf
        notes.append(f"backfill {days} d, Open-Meteo previous runs: {len(bf)} rows (lead_h = 24*N)")
        notes += [f"  {n}" for n in bnotes]
        notes.append("KMI cannot be backfilled (no archive); its rows start at the first collect run")
        try:
            station, obs = O.observation_rows(loc, days * 24 + 48, args.station, now=now)
            have = {(r["station"], r["valid_time"]) for r in observations}
            fresh = [r for r in obs if (r["station"], r["valid_time"]) not in have]
            observations += fresh
            notes.append(f"observations fetched for the backfill span: {len(obs)} h ({len(fresh)} not yet logged)")
        except (C.FetchError, OSError, ValueError) as e:
            notes.append(f"observations for the backfill span: {e}")
    code = pick_station(observations, args.station)
    obs_by_time = {r["valid_time"]: r["values"] for r in observations if r["station"] == code}
    names = {r["station"]: r.get("station_name", "?") for r in observations}
    tables, joined = score(forecasts, obs_by_time, args.kmi_precip_shift)
    vars_ = args.var or SCORED
    report = {
        "generated_at": C.iso_z(now),
        "location": loc,
        "station": f"{names.get(code, '?')} ({code})" if code is not None else "none",
        "buckets": [b[0] for b in BUCKETS],
        "vars": vars_,
        "forecast_rows": len(forecasts),
        "forecast_rows_joined": joined,
        "observation_hours": len(obs_by_time),
        "notes": notes,
        "tables": {v: t for v, t in results_of(tables).items() if v in vars_},
        "ranking": {v: r for v, r in ranking(tables).items() if v in vars_},
    }
    if args.json:
        print(json.dumps(report, indent=1))
    else:
        print_text(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
