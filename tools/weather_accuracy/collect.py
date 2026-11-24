#!/usr/bin/env python3
"""Log the forecasts that are being made now, so they can be scored against what happens.

One Open-Meteo request (five models, 48 h) and one KMI app request (49 h), appended to
forecasts-YYYY-MM.jsonl as

    {"source": "openmeteo"|"kmi", "model": ..., "fetched_at": UTC hour, "valid_time": UTC hour,
     "lead_h": int, "values": {"temp": degC, "precip": mm, "precip_prob": %, "wind": km/h,
     "gust": km/h, "humidity": %, "pressure": hPa (sea level), "cloud": %, "wcode": WMO,
     KMI only: "kmi_ww": KMI icon code, "wind_dir": degrees the wind blows FROM}}

Idempotent per (source, model, fetched_at): a second run in the same hour appends nothing.
Exit 0 when at least one source was logged this run (or was already logged this hour), 1 when
neither could be fetched. Errors are kept in status.json.

    collect.py [--save-raw DIR] [--dry-run]
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C  # noqa: E402

OPENMETEO_URL = "https://api.open-meteo.com/v1/forecast"
KMI_URL = "https://app.meteo.be/services/appv4/"
KMI_SALT = "r9EnW374jkJ9acc"
FORECAST_HOURS = 48


# ---------------------------------------------------------------------------- Open-Meteo

def openmeteo_url(loc):
    q = {
        "latitude": f"{loc['lat']:.4f}", "longitude": f"{loc['lon']:.4f}",
        "models": ",".join(C.OPENMETEO_MODELS),
        "hourly": ",".join(C.OPENMETEO_VARS.keys()),
        "forecast_hours": FORECAST_HOURS,
        "timezone": "UTC", "timeformat": "iso8601",
    }
    return OPENMETEO_URL + "?" + urllib.parse.urlencode(q)


def split_openmeteo_key(key):
    """'temperature_2m_icon_d2' -> ('temp', 'icon_d2'); unsuffixed -> best_match."""
    for omvar, name in C.OPENMETEO_VARS.items():
        if key == omvar:
            return name, "best_match"
        if key.startswith(omvar + "_"):
            return name, key[len(omvar) + 1:]
    return None, None


def parse_openmeteo(resp, fetched_at):
    """Rows per (model, valid_time) from a multi-model hourly response. Nulls are omitted;
    a row with no values at all is dropped (a model whose window has not reached that hour)."""
    hourly = resp.get("hourly") or {}
    times = hourly.get("time") or []
    offset = dt.timedelta(seconds=int(resp.get("utc_offset_seconds") or 0))
    per_model = {}
    for key, series in hourly.items():
        if key == "time":
            continue
        name, model = split_openmeteo_key(key)
        if name is None:
            continue
        per_model.setdefault(model, {})[name] = series
    rows = []
    for model, series_by_var in per_model.items():
        for i, t in enumerate(times):
            valid = (dt.datetime.fromisoformat(t).replace(tzinfo=C.UTC) - offset)
            lead = round((valid - fetched_at).total_seconds() / 3600)
            if lead < 0:
                continue
            values = {}
            for name, series in series_by_var.items():
                v = series[i] if i < len(series) else None
                if v is not None:
                    values[name] = v
            if values:
                rows.append({"source": "openmeteo", "model": model,
                             "fetched_at": C.iso_z(fetched_at), "valid_time": C.iso_z(valid),
                             "lead_h": lead, "values": values})
    return rows


# ---------------------------------------------------------------------------- KMI

def kmi_key(date_local):
    return hashlib.md5(f"{KMI_SALT};getForecasts;{date_local.strftime('%d/%m/%Y')}".encode()).hexdigest()


def kmi_url(loc, date_local):
    q = {"s": "getForecasts", "k": kmi_key(date_local),
         "lat": f"{loc['lat']:.4f}", "long": f"{loc['lon']:.4f}"}
    return KMI_URL + "?" + urllib.parse.urlencode(q)


def fetch_kmi(loc, now):
    """The key is an md5 over today's date; around midnight the server's day and ours can
    differ, so the local date is tried first, then UTC's, then the neighbours."""
    local_today = now.astimezone(C.LOCAL_TZ).date()
    candidates = [local_today, now.date(), local_today - dt.timedelta(days=1),
                  local_today + dt.timedelta(days=1)]
    seen, last_err = [], None
    for d in candidates:
        if d in seen:
            continue
        seen.append(d)
        try:
            data, raw = C.fetch_json(kmi_url(loc, d), "kmi_forecasts.json",
                                     headers={"Accept": "application/json"})
        except C.FetchError as e:
            last_err = e
            continue
        if isinstance(data, dict) and isinstance(data.get("for"), dict):
            return data, raw
        last_err = C.FetchError(f"KMI answered without a forecast for key date {d}")
        if C.fixtures_dir():
            break
    raise last_err or C.FetchError("KMI: no key date accepted")


def _num(v):
    """KMI sends most figures as strings ("20", "15"); keep integers integral."""
    if v is None or v == "":
        return None
    if isinstance(v, (int, float)):
        return v
    try:
        f = float(v)
    except ValueError:
        return None
    return int(f) if f == int(f) else f


def kmi_hour_times(hourly, now):
    """UTC datetime of every KMI hourly entry. Entries carry a local 'hour' ("19") and a
    'dateShow' ("17/09") on the entries that start a new day; the first dateShow anchors the
    sequence and the rest is contiguous hours (stepped in UTC so a DST night stays right)."""
    if not hourly:
        return []
    local_now = now.astimezone(C.LOCAL_TZ)
    anchor = next((i for i, h in enumerate(hourly) if h.get("dateShow")), None)
    if anchor is None:
        anchor_date, anchor_hour = local_now.date(), int(hourly[0].get("hour", local_now.hour))
        anchor = 0
    else:
        day, month = (int(x) for x in hourly[anchor]["dateShow"].split("/")[:2])
        year = local_now.year
        if month - local_now.month > 6:
            year -= 1
        elif local_now.month - month > 6:
            year += 1
        anchor_date, anchor_hour = dt.date(year, month, day), int(hourly[anchor]["hour"])
    anchor_utc = dt.datetime.combine(anchor_date, dt.time(anchor_hour), tzinfo=C.LOCAL_TZ).astimezone(C.UTC)
    times = []
    for i, h in enumerate(hourly):
        t = anchor_utc + dt.timedelta(hours=i - anchor)
        if int(h.get("hour", -1)) != t.astimezone(C.LOCAL_TZ).hour:
            C.log(f"KMI hourly[{i}] says hour {h.get('hour')} where {t.astimezone(C.LOCAL_TZ):%H} was expected; "
                  "the sequence is not contiguous, stopping there")
            break
        times.append(t)
    return times


def parse_kmi(resp, fetched_at, now):
    hourly = (resp.get("for") or {}).get("hourly") or []
    rows = []
    for h, valid in zip(hourly, kmi_hour_times(hourly, now)):
        lead = round((valid - fetched_at).total_seconds() / 3600)
        if lead < 0:
            continue
        values = {}
        for src, name in (("temp", "temp"), ("precipQuantity", "precip"), ("precipChance", "precip_prob"),
                          ("windSpeedKm", "wind"), ("windPeakSpeedKm", "gust"), ("pressure", "pressure"),
                          ("ww", "kmi_ww")):
            v = _num(h.get(src))
            if v is not None:
                values[name] = v
        wd = _num(h.get("windDirection"))
        if wd is not None:
            values["wind_dir"] = (wd + 180) % 360      # KMI gives where the wind blows TO
        if values:
            rows.append({"source": "kmi", "model": "kmi", "fetched_at": C.iso_z(fetched_at),
                         "valid_time": C.iso_z(valid), "lead_h": lead, "values": values})
    return rows


# ---------------------------------------------------------------------------- main

def write_forecasts(rows, fetched_at):
    """Append rows whose (source, model, fetched_at) is not in the month file yet."""
    path = C.month_path("forecasts", fetched_at)
    needle = f'"fetched_at":"{C.iso_z(fetched_at)}"'
    with C.Lock():
        have = C.existing_keys(path, [needle], lambda r: (r["source"], r["model"], r["fetched_at"]))
        fresh = [r for r in rows if (r["source"], r["model"], r["fetched_at"]) not in have]
        n = C.append_rows(path, fresh)
    return n, len(rows) - n, path


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--save-raw", metavar="DIR", help="also save the raw responses there")
    ap.add_argument("--dry-run", action="store_true", help="parse and count, write nothing")
    args = ap.parse_args(argv)

    loc, origin = C.load_location()
    now = C.now_utc()
    fetched_at = C.floor_hour(now)
    print(f"location {loc['name']} {loc['lat']:.3f},{loc['lon']:.3f} ({origin}); fetched_at {C.iso_z(fetched_at)}")

    rows, ok, errors = [], 0, {}
    try:
        data, raw = C.fetch_json(openmeteo_url(loc), "accuracy_openmeteo_models.json")
        C.save_raw(args.save_raw, "accuracy_openmeteo_models.json", raw)
        om = parse_openmeteo(data, fetched_at)
        models = sorted({r["model"] for r in om})
        missing = [m for m in C.OPENMETEO_MODELS if m not in models]
        print(f"openmeteo: {len(om)} rows, models {', '.join(models)}"
              + (f"; NO DATA for {', '.join(missing)}" if missing else ""))
        rows += om
        ok += 1
    except C.FetchError as e:
        errors["openmeteo"] = str(e)
        C.log(f"openmeteo failed: {e}")
    try:
        data, raw = fetch_kmi(loc, now)
        C.save_raw(args.save_raw, "kmi_forecasts.json", raw)
        km = parse_kmi(data, fetched_at, now)
        print(f"kmi: {len(km)} rows for {data.get('cityName', '?')}")
        rows += km
        ok += 1
    except C.FetchError as e:
        errors["kmi"] = str(e)
        C.log(f"kmi failed: {e}")

    if args.dry_run:
        for r in rows[:3]:
            print(json.dumps(r, separators=(",", ":")))
        return 0 if ok else 1
    n, skipped, path = write_forecasts(rows, fetched_at)
    print(f"appended {n} rows to {path}" + (f", {skipped} already logged for this hour" if skipped else ""))
    status = {"collect_last_run": C.iso_z(now), "collect_errors": errors}
    if ok:
        status["collect_last_ok"] = C.iso_z(now)
    C.update_status(**status)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
