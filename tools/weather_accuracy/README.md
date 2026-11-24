# Weather forecast accuracy logger

Which forecast source is most accurate here? This logs, every hour, what five Open-Meteo
models and the KMI app forecast for the next 48 h, and what the nearest RMI weather station
then measured, and scores one against the other. Python 3 stdlib only; nothing here touches
the shell.

## What it records, and where

Data dir: `~/.local/share/lares/weather-accuracy/` (`$WEATHER_ACCURACY_DATA` to move it).

| file | one line per | contents |
|---|---|---|
| `forecasts-YYYY-MM.jsonl` | (source, model, fetched_at, valid_time) | `lead_h` and `values`: `temp` degC, `precip` mm (hour ending at valid_time), `precip_prob` %, `wind` and `gust` km/h, `humidity` %, `pressure` hPa sea level, `cloud` %, `wcode` WMO; KMI also `kmi_ww` (KMI icon code) and `wind_dir` (degrees the wind comes FROM; KMI's own figure is where it blows to, +180 applied) |
| `observations-YYYY-MM.jsonl` | (station, valid_time) | `values`: `temp`, `precip`, `wind`, `gust`, `humidity`, `pressure_station` (as measured), `pressure` (reduced to sea level) |
| `stations.json` | | cached RMI station list, used when the WFS is down |
| `status.json` | | last run / last success / last error per step, the station in use |

Times are UTC ISO with a `Z`, floored to the hour. `fetched_at` is the hour the forecast was
taken; `lead_h = valid_time - fetched_at`. Each hourly run appends 287 lines (5 models x 48 h
minus a model's not-yet-available first hours, plus KMI's 49 h) and about one observation
line. Both appends are idempotent: a second run inside the same hour adds nothing.

Sources:

- **Open-Meteo** (`api.open-meteo.com`), one request with
  `models=best_match,knmi_harmonie_arome_netherlands,icon_d2,meteofrance_arome_france_hd,ecmwf_ifs025`,
  `forecast_hours=48`, all five accepted (verified 2026-09-16). At the test point `best_match` IS
  KNMI Harmonie; the two rows are identical. Not every model has every variable:
  KNMI and Meteo-France have no `pressure_msl`, Meteo-France no `cloud_cover` / `weather_code`,
  KNMI and Meteo-France no `precipitation_probability`; a missing value is simply absent.
- **KMI** (`app.meteo.be/services/appv4/?s=getForecasts`), the phone app's endpoint, keyed with
  `md5("r9EnW374jkJ9acc;getForecasts;dd/mm/yyyy")` for today's date (local first, then UTC and
  the neighbouring days around midnight). 49 hourly entries carrying a local `hour` and a
  `dateShow` on each new day; the first `dateShow` anchors the sequence and the rest is
  contiguous hours stepped in UTC.
- **RMI observations** (`opendata.meteo.be/service/aws/wfs`, `aws:aws_1hour`): the active
  station nearest the location by haversine (`aws:aws_station`), the last 48 h.

The location is the `default` entry of `~/.config/quickshell/weather.jsonc`
(`{"locations":[{"name","lat","lon","elevation","default":true}]}`), else Brussels 50.85/4.35.

## Enable (the user does this; the tool never enables itself)

    systemctl --user link ~/.config/quickshell/tools/weather_accuracy/weather-accuracy.service
    systemctl --user enable --now ~/.config/quickshell/tools/weather_accuracy/weather-accuracy.timer
    systemctl --user list-timers weather-accuracy.timer      # next run at :05
    journalctl --user -u weather-accuracy.service -n 20      # what the last run said

The timer fires hourly at :05 and, being `Persistent`, once at boot when hours were missed
(that catch-up run logs one forecast, not the missed ones; observations cover the last 48 h so
gaps up to two days are filled). The service exits 1 only when nothing could be fetched;
a single failing source is recorded in `status.json` and the run still logs the other.

## Reading score.py

    python3 tools/weather_accuracy/score.py                # what has been logged
    python3 tools/weather_accuracy/score.py --backfill 7   # + Open-Meteo previous runs for the past 7 days
    python3 tools/weather_accuracy/score.py --json         # the same as JSON, for the popup

One table per variable, rows = source/model, columns = lead buckets 0-6, 6-12, 12-24, 24-48
and 48+ h. A cell is:

- temp, humidity, pressure: `MAE/bias (N)`; bias = forecast - observed, so `+` is too warm,
  too humid, too high.
- wind, gust: `MAE/bias agreement% (N)`; agreement = share of hours forecast in the same
  Beaufort class as observed (the km/h bands of `modules/weather/data/WeatherScales.js`).
- precip: `MAE hit/FAR (N)`; hit rate = observed wet hours (>= 0.1 mm) that were forecast wet,
  false-alarm ratio = forecast wet hours that stayed dry; `-` when there was no such hour.
- precip_prob: the Brier score of the forecast probability against the observed wet/dry
  outcome; 0 is perfect, 0.25 is a coin, a constant "0 %" scores the wet-hour fraction.

`Ranking` at the foot sorts the models per variable by N-weighted MAE over leads 0-48 h.
Trust it in proportion to N: KMI has N = 1 after the first hour and about 48 per lead bucket
after two days. `cloud`, `wcode`, `kmi_ww` and `wind_dir` are logged but not scored -- the
hourly station data carry no cloud cover or wind direction.

`--backfill DAYS` fetches the Open-Meteo Previous Runs API (`previous_day1..7` = the value
predicted 24..168 h before valid time, so `lead_h` is exactly 24*N) for each model, plus the
station's observations for the same span, in memory -- nothing is written. The three
short-range models (KNMI, ICON-D2, AROME) only have `previous_day1`, so they rank at 24-48 h
only; ECMWF has no gusts and no weather code there. **KMI cannot be backfilled**: there is no
archive, so its rows start with the first collect run and the comparison is fair only where
every source has N.

`--kmi-precip-shift 1` compares KMI's hourly rain amount with the observation an hour later
(see caveats). `--station CODE` picks another AWS station.

## Disk use

Measured on the real run of 2026-09-16: 287 forecast lines = 69.5 KB per hour, 49 observation
lines = 9.8 KB per 48 h window of which one line (~200 B) is new each hour. Per month:
about **50 MB** of forecasts and 0.15 MB of observations. One line per (model, hour) with a
`values` object is what keeps it there; the naive one-line-per-variable layout, rebuilt from the
same run's rows, measures 5.0x that (347 KB/hour, 250 MB/month). Delete or `xz` old month files when done with them; score.py reads only
`forecasts-*.jsonl` / `observations-*.jsonl`.

## Caveats, all real

- **KMI's API is unofficial.** It is the phone app's endpoint with the app's key scheme;
  it can change or vanish without notice. Every request sends a User-Agent.
- **Station vs point.** Observations are the nearest AWS, not the forecast point: the test point is
  scored against the nearest station, 10 km away at 15 m. Every source pays the same distance, so
  the ranking is fair, but the absolute errors include it. Uccle (6447) is 6 km from Brussels.
- **Sea-level reduction.** RMI publishes station-level pressure (its documentation says so);
  forecasts give sea level. `pressure` in the observations is the hypsometric reduction with
  the station altitude and that hour's temperature; `pressure_station` is the raw value.
  The reduction is 1.8 hPa at that station -- a systematic 0.1-0.3 hPa either way is possible.
- **Wind unit.** RMI documents `WIND_SPEED_10M` and `WIND_GUSTS_SPEED` as m/s
  (opendata.meteo.be/documentation/?dataset=aws), and the data agree: against Open-Meteo's
  previous-day forecast at that station the MAE is 2.5 km/h with x3.6 and 8.6 km/h without.
  Converted here, x3.6.
- **Hour convention.** RMI's hourly value at H aggregates (H-1):10 .. H:00 -- the hour ending
  at H, which is how Open-Meteo defines its precipitation sum and gust maximum. Temperature and
  humidity are an hour's mean against the models' instantaneous value at H; that smooths
  the observation by a few tenths of a degree around sunrise and sunset, equally for every
  source. KMI does not say whether its "19 h" rain amount is the hour before or after 19:00;
  it is logged as-is and `--kmi-precip-shift` tests the alternative once there is data.
- **Observations are QC'd later.** The WFS rows arrive with `validated: false`; a corrected
  value does not replace a row already logged.
- **Backfill leads are nominal.** `previous_dayN` is Open-Meteo's fixed 24*N h offset;
  the live rows carry the exact lead.

## Test

Fixture mode: `WEATHER_ACCURACY_FIXTURES=<dir>` makes every fetch read the captured response
of that name in `<dir>` (`accuracy_openmeteo_models.json`, `kmi_forecasts.json`,
`rmi_aws_stations.json`, `accuracy_rmi_aws_1hour.json`, `openmeteo_previous_runs.json`) and
`WEATHER_ACCURACY_NOW` pins the clock. `--save-raw DIR` keeps the raw responses under those
names, which is how such a directory is made. `--dry-run` on collect.py / observe.py prints
rows without writing.
