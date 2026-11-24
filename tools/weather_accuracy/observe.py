#!/usr/bin/env python3
"""Log what actually happened: hourly observations of the RMI automatic weather station
nearest the configured location (WFS aws:aws_1hour on opendata.meteo.be).

Appended to observations-YYYY-MM.jsonl as

    {"station": code, "station_name": ..., "valid_time": UTC hour, "values": {"temp": degC,
     "precip": mm, "wind": km/h, "gust": km/h, "humidity": %, "pressure_station": hPa,
     "pressure": hPa reduced to sea level}}

RMI documents the units (opendata.meteo.be/documentation/?dataset=aws): WIND_SPEED_10M and
WIND_GUSTS_SPEED are m/s (converted here, x3.6), PRESSURE is station level (reduced here with
the station altitude and the hour's temperature; both kept). The hourly value at timestamp H
aggregates the 10-min values (H-1):10 .. H:00, i.e. the hour ENDING at H -- the same convention
Open-Meteo uses for precipitation and gusts.

Idempotent per (station, valid_time). Exit 1 when nothing could be fetched.

    observe.py [--hours N] [--station CODE] [--save-raw DIR] [--dry-run]
"""
import argparse
import datetime as dt
import json
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C  # noqa: E402

WFS_URL = "https://opendata.meteo.be/service/aws/wfs"
DEFAULT_HOURS = 48

AWS_VARS = (  # WFS property -> (canonical name, factor)
    ("temp_dry_shelter_avg", "temp", 1.0),
    ("precip_quantity", "precip", 1.0),
    ("wind_speed_10m", "wind", 3.6),
    ("wind_gusts_speed", "gust", 3.6),
    ("humidity_rel_shelter_avg", "humidity", 1.0),
    ("pressure", "pressure_station", 1.0),
)


def wfs_url(type_name, cql=None, sort_by=None):
    q = {"service": "WFS", "version": "2.0.0", "request": "GetFeature",
         "typeName": type_name, "outputFormat": "json"}
    if cql:
        q["CQL_FILTER"] = cql
    if sort_by:
        q["sortBy"] = sort_by
    return WFS_URL + "?" + urllib.parse.urlencode(q)


# ---------------------------------------------------------------------------- stations

def load_stations():
    """Active stations [{code, name, lat, lon, altitude}], from the WFS (cached to
    stations.json) or the cache when the WFS is down."""
    cache = os.path.join(C.data_dir(), "stations.json")
    try:
        data, raw = C.fetch_json(wfs_url("aws:aws_station"), "rmi_aws_stations.json")
        stations = parse_stations(data)
        if stations:
            tmp = cache + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(stations, f)
            os.replace(tmp, cache)
            return stations, raw
    except C.FetchError as e:
        C.log(f"station list: {e}; using the cache")
    with open(cache, encoding="utf-8") as f:
        return json.load(f), None


def parse_stations(data):
    out = []
    for feat in data.get("features") or []:
        p = feat.get("properties") or {}
        g = (feat.get("geometry") or {}).get("coordinates") or [None, None]
        if p.get("date_end") or p.get("code") is None or g[0] is None:
            continue
        out.append({"code": int(p["code"]), "name": p.get("name", "?"),
                    "lat": float(g[1]), "lon": float(g[0]), "altitude": float(p.get("altitude") or 0)})
    return out


def nearest_station(stations, loc, code=None):
    if code is not None:
        match = [s for s in stations if s["code"] == code]
        if not match:
            raise SystemExit(f"no station with code {code}")
        s = match[0]
    else:
        s = min(stations, key=lambda s: C.haversine_km(loc["lat"], loc["lon"], s["lat"], s["lon"]))
    return dict(s, distance_km=round(C.haversine_km(loc["lat"], loc["lon"], s["lat"], s["lon"]), 1))


# ---------------------------------------------------------------------------- observations

def parse_aws_1hour(data, station, t0=None, t1=None):
    rows = []
    for feat in data.get("features") or []:
        p = feat.get("properties") or {}
        if int(p.get("code", -1)) != station["code"] or not p.get("timestamp"):
            continue
        valid = C.floor_hour(C.parse_iso(p["timestamp"]))
        if (t0 and valid < t0) or (t1 and valid > t1):
            continue
        values = {}
        for prop, name, factor in AWS_VARS:
            v = p.get(prop)
            if isinstance(v, (int, float)):
                values[name] = round(v * factor, 3) if factor != 1.0 else v
        if "pressure_station" in values:
            msl = C.sea_level_pressure(values["pressure_station"], station["altitude"], values.get("temp"))
            values["pressure"] = round(msl, 2)
        if values:
            rows.append({"station": station["code"], "station_name": station["name"],
                         "valid_time": C.iso_z(valid), "values": values})
    rows.sort(key=lambda r: r["valid_time"])
    return rows


def fetch_observations(station, t0, t1, save_raw_dir=None):
    cql = (f"code={station['code']} AND timestamp DURING "
           f"{t0.strftime('%Y-%m-%dT%H:%M:%SZ')}/{t1.strftime('%Y-%m-%dT%H:%M:%SZ')}")
    data, raw = C.fetch_json(wfs_url("aws:aws_1hour", cql, "timestamp"), "accuracy_rmi_aws_1hour.json")
    C.save_raw(save_raw_dir, "accuracy_rmi_aws_1hour.json", raw)
    return parse_aws_1hour(data, station, t0, t1)


def observation_rows(loc, hours, code=None, save_raw_dir=None, now=None):
    """Everything score.py --backfill needs in memory: (station, rows) for the last `hours`."""
    now = now or C.now_utc()
    stations, raw = load_stations()
    C.save_raw(save_raw_dir, "rmi_aws_stations.json", raw) if raw else None
    station = nearest_station(stations, loc, code)
    t1 = C.floor_hour(now)
    t0 = t1 - dt.timedelta(hours=hours)
    return station, fetch_observations(station, t0, t1, save_raw_dir)


def write_observations(rows):
    """Append rows whose (station, valid_time) is not in their month file yet."""
    appended, skipped = 0, 0
    with C.Lock():
        for month, group in C.group_rows_by_month(rows, "valid_time").items():
            path = os.path.join(C.data_dir(), f"observations-{month}.jsonl")
            needles = [f'"valid_time":"{r["valid_time"]}"' for r in group]
            have = C.existing_keys(path, needles, lambda r: (r["station"], r["valid_time"]))
            fresh = [r for r in group if (r["station"], r["valid_time"]) not in have]
            appended += C.append_rows(path, fresh)
            skipped += len(group) - len(fresh)
    return appended, skipped


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--hours", type=int, default=DEFAULT_HOURS, help=f"window before now (default {DEFAULT_HOURS})")
    ap.add_argument("--station", type=int, help="AWS station code instead of the nearest")
    ap.add_argument("--save-raw", metavar="DIR", help="also save the raw responses there")
    ap.add_argument("--dry-run", action="store_true", help="parse and count, write nothing")
    args = ap.parse_args(argv)

    loc, origin = C.load_location()
    now = C.now_utc()
    try:
        station, rows = observation_rows(loc, args.hours, args.station, args.save_raw, now)
    except (C.FetchError, OSError, ValueError) as e:
        C.log(f"observe failed: {e}")
        C.update_status(observe_last_run=C.iso_z(now), observe_error=str(e))
        return 1
    print(f"location {loc['name']} ({origin}); station {station['name']} ({station['code']}, "
          f"{station['distance_km']:.1f} km, alt {station['altitude']:.0f} m); "
          f"{len(rows)} hours in the last {args.hours} h")
    if args.dry_run:
        for r in rows[-3:]:
            print(json.dumps(r, separators=(",", ":")))
        return 0
    n, skipped = write_observations(rows)
    print(f"appended {n} rows" + (f", {skipped} already logged" if skipped else ""))
    C.update_status(observe_last_run=C.iso_z(now), observe_last_ok=C.iso_z(now), observe_error="",
                    station={k: station[k] for k in ("code", "name", "altitude", "distance_km")},
                    observation_hours_last_run=len(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
