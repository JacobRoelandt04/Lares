"""Shared pieces of the weather accuracy logger (Python 3 stdlib only).

Data directory (override with $WEATHER_ACCURACY_DATA):
    ~/.local/share/lares/weather-accuracy/
        forecasts-YYYY-MM.jsonl     one line per (source, model, fetched_at, valid_time)
        observations-YYYY-MM.jsonl  one line per (station, valid_time)
        stations.json               cached RMI station list (refreshed on every successful fetch)
        status.json                 last success / last error per step, for the popup
        .lock                       flock held while a file is appended

Every timestamp is UTC ISO-8601 with a trailing Z, floored to the hour.
Canonical units: degC, mm, %, km/h, hPa.

Environment:
    WEATHER_ACCURACY_DATA      data directory
    WEATHER_ACCURACY_CONFIG    weather.jsonc path (default ~/.config/quickshell/config/weather.jsonc; a weather.json beside it is read when there is no .jsonc)
    WEATHER_ACCURACY_FIXTURES  a directory: read captured responses from it instead of the network
    WEATHER_ACCURACY_NOW       "now" as UTC ISO (tests pin it so lead_h is reproducible)
"""
import datetime as dt
import fcntl
import json
import math
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import jsonc as _jsonc  # noqa: E402  (tools/lib/jsonc.py: `.jsonc` first, comments allowed)

UTC = dt.timezone.utc
LOCAL_TZ = ZoneInfo("Europe/Brussels")
USER_AGENT = "lares-weather-accuracy/1.0"

DEFAULT_LOCATION = {"name": "Brussels", "lat": 50.85, "lon": 4.35, "elevation": 25}

# Canonical variable -> unit. Forecast rows carry a subset; observation rows the same names
# so score.py joins by name. pressure is always sea level; pressure_station is the raw AWS value.
UNITS = {
    "temp": "degC", "precip": "mm", "precip_prob": "%", "wind": "km/h", "gust": "km/h",
    "humidity": "%", "pressure": "hPa", "pressure_station": "hPa", "cloud": "%",
    "wcode": "wmo", "kmi_ww": "kmi", "wind_dir": "deg",
}

# Open-Meteo hourly variable -> canonical name. Longest names first so "precipitation_probability"
# is matched before "precipitation" when a model suffix is stripped.
OPENMETEO_VARS = {
    "precipitation_probability": "precip_prob",
    "relative_humidity_2m": "humidity",
    "temperature_2m": "temp",
    "wind_gusts_10m": "gust",
    "wind_speed_10m": "wind",
    "precipitation": "precip",
    "pressure_msl": "pressure",
    "weather_code": "wcode",
    "cloud_cover": "cloud",
}
OPENMETEO_MODELS = [
    "best_match",
    "knmi_harmonie_arome_netherlands",
    "icon_d2",
    "meteofrance_arome_france_hd",
    "ecmwf_ifs025",
]

# Beaufort bands in km/h, exclusive upper bounds -- the same numbers as
# modules/weather/data/WeatherScales.js `beaufort` (the selftest compares them).
BEAUFORT_HI = [1, 6, 12, 20, 29, 39, 50, 62, 75, 89, 103, 118]


# ---------------------------------------------------------------------------- environment

def data_dir():
    d = os.environ.get("WEATHER_ACCURACY_DATA") or os.path.join(
        os.path.expanduser("~"), ".local", "share", "lares", "weather-accuracy")
    os.makedirs(d, exist_ok=True)
    return d


def fixtures_dir():
    return os.environ.get("WEATHER_ACCURACY_FIXTURES") or None


def now_utc():
    pinned = os.environ.get("WEATHER_ACCURACY_NOW")
    if pinned:
        return parse_iso(pinned)
    return dt.datetime.now(UTC)


def floor_hour(t):
    return t.replace(minute=0, second=0, microsecond=0)


def load_location():
    """The default location from weather.jsonc (or weather.json), else Brussels. Returns (location, origin)."""
    path = os.environ.get("WEATHER_ACCURACY_CONFIG") or os.path.join(
        os.path.expanduser("~"), ".config", "quickshell", "config", "weather.jsonc")
    try:
        with open(_jsonc.resolve(path), encoding="utf-8") as f:
            cfg = _jsonc.loads(f.read())
        locs = cfg.get("locations") or []
        chosen = next((l for l in locs if l.get("default")), locs[0] if locs else None)
        if chosen and "lat" in chosen and "lon" in chosen:
            return ({"name": chosen.get("name", "?"), "lat": float(chosen["lat"]),
                     "lon": float(chosen["lon"]),
                     "elevation": float(chosen.get("elevation", 0))}, path)
    except FileNotFoundError:
        pass
    except (ValueError, KeyError, TypeError) as e:
        log(f"weather.jsonc unreadable ({e}); using {DEFAULT_LOCATION['name']}")
    return (dict(DEFAULT_LOCATION), "builtin default")


def log(msg):
    print(msg, file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------- time

def parse_iso(s):
    """'2026-09-16T17:00:00Z' | '+02:00' | naive (taken as UTC) -> aware datetime."""
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    t = dt.datetime.fromisoformat(s)
    if t.tzinfo is None:
        t = t.replace(tzinfo=UTC)
    return t.astimezone(UTC)


def iso_z(t):
    return t.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def month_of(t):
    return t.astimezone(UTC).strftime("%Y-%m")


# ---------------------------------------------------------------------------- network / fixtures

class FetchError(Exception):
    pass


def fetch_bytes(url, fixture_name, headers=None, timeout=60):
    """GET url, or read <fixtures>/<fixture_name> when fixture mode is on."""
    fx = fixtures_dir()
    if fx:
        path = os.path.join(fx, fixture_name)
        with open(path, "rb") as f:
            return f.read()
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        body = e.read()[:300].decode("utf-8", "replace")
        raise FetchError(f"HTTP {e.code} for {url.split('?')[0]}: {body}") from None
    except (urllib.error.URLError, OSError) as e:
        raise FetchError(f"{url.split('?')[0]}: {e}") from None


def fetch_json(url, fixture_name, headers=None, timeout=60):
    raw = fetch_bytes(url, fixture_name, headers, timeout)
    try:
        return json.loads(raw), raw
    except ValueError as e:
        raise FetchError(f"{url.split('?')[0]}: not JSON ({e}); starts {raw[:80]!r}") from None


def save_raw(directory, name, raw):
    if not directory:
        return
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, name), "wb") as f:
        f.write(raw)


# ---------------------------------------------------------------------------- geometry / physics

def haversine_km(lat1, lon1, lat2, lon2):
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def sea_level_pressure(p_station_hpa, altitude_m, temp_c):
    """Station pressure -> mean sea level, hypsometric reduction with the standard lapse rate
    (0.0065 K/m, exponent 5.257). Within 0.1 hPa of the ISA-based formula below 500 m."""
    if p_station_hpa is None or altitude_m is None:
        return None
    t = 15.0 if temp_c is None else temp_c
    lapse = 0.0065 * altitude_m
    return p_station_hpa * (1.0 - lapse / (t + lapse + 273.15)) ** -5.257


def beaufort(kmh):
    if kmh is None:
        return None
    for i, hi in enumerate(BEAUFORT_HI):
        if kmh < hi:
            return i
    return len(BEAUFORT_HI)


# ---------------------------------------------------------------------------- jsonl files

def month_path(kind, when):
    return os.path.join(data_dir(), f"{kind}-{month_of(when)}.jsonl")


def iter_rows(path):
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        yield json.loads(line)
                    except ValueError:
                        continue
    except FileNotFoundError:
        return


def existing_keys(path, needles, keyfn):
    """Keys of the rows already in path whose line contains one of the needles (a cheap
    substring gate, so a month file is scanned without parsing every line)."""
    keys = set()
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if any(n in line for n in needles):
                    try:
                        keys.add(keyfn(json.loads(line)))
                    except ValueError:
                        pass
    except FileNotFoundError:
        pass
    return keys


class Lock:
    def __init__(self):
        self.path = os.path.join(data_dir(), ".lock")
        self.fd = None

    def __enter__(self):
        self.fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o644)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)
        self.fd = None


def append_rows(path, rows):
    """Append rows as one write + fsync. Call under Lock()."""
    if not rows:
        return 0
    blob = "".join(json.dumps(r, separators=(",", ":"), ensure_ascii=False) + "\n" for r in rows)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        data = blob.encode("utf-8")
        while data:
            n = os.write(fd, data)
            data = data[n:]
        os.fsync(fd)
    finally:
        os.close(fd)
    return len(rows)


def update_status(**fields):
    path = os.path.join(data_dir(), "status.json")
    try:
        with open(path, encoding="utf-8") as f:
            status = json.load(f)
    except (FileNotFoundError, ValueError):
        status = {}
    status.update(fields)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(status, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def group_rows_by_month(rows, timefield):
    out = {}
    for r in rows:
        out.setdefault(r[timefield][:7], []).append(r)
    return out
