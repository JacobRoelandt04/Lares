# Weather

## What it is

A small glyph and the temperature in the top bar ("12°"). Click it and a popup shows the weather where you are: what it is now, the next
48 hours, the next 16 days and the niche numbers (pollen, UV, pressure, sun and moon). Click almost anything in it for a chart of that
number over time. The forecast comes from Open-Meteo; for Belgium the KMI app's observation, warnings, pollen note and radar are added.

## Where it lives

- Bar: centre island, left of the clock. The button draws the same weather glyph as the popup (rain, sun, cloud, night, shower) and the
  temperature, bold like the bar's other figures; a temperature that changes rolls over as the clock's minutes do. While the forecast is loading or offline with nothing cached it shows a plain cloud and `--°` at reduced strength. A KMI warning
  tints the temperature (warn colour, error colour from level 3).
- Popup: three views, switched by the tab selector in its header or a two-finger sideways swipe across the popup:
  - mini: the header and the hero card.
  - normal: header, hero, the hourly strip and the daily list in one column.
  - detailed: two columns of one height. Left: hero and daily list. Right: hourly strip and the ten tiles.
  The popup opens in the view you last used; a new shell session opens in mini (`weather.jsonc` `view`).
- Detail: a second popup that grows out of the first on the side away from the bar (`detailSide`). A view switch closes it.
- No keyboard shortcut and no IPC verb.

## What you can do

- Click the location name in the header to step to the next place (only when more than one place exists). Hover it to see why that place is
  shown: the current location from geoclue, the hometown, or the default, with the reason when there is no fix. Changing place morphs every
  card into the new place's picture.
- Hero card: the big temperature, condition, the KMI observation line, high / low / feels-like, a one-line context ("Drizzle tomorrow..."), a short
  rain nowcast bar, over a moving sky that follows the condition (sun, clouds, rain, snow, fog, wind, thunder; night). A click on the glyph opens
  today's conditions chart.
- Hourly strip (48 hours, 44 px columns): two-finger scroll sideways to move through the hours. A vertical swipe (or a mouse notch) cycles its nine
  views: Conditions, Wind, Precipitation, Humidity and dew point, UV, Pressure, Cloud cover, Visibility, Air quality; the columns morph between views.
  The dots at its edge show which view it is on.
- Daily list (16 days): its own seven views (Conditions, Feels like, Wind, Precipitation, Sunshine, UV, Air quality), cycled the same way, scrolled
  vertically.
- Tiles (detailed view): Precipitation, Wind, Air quality, Pollen, Humidity, UV, Visibility, Pressure, Sun, Moon.
- Detail chart: one metric on a timeline for a day. Move the pointer along it to read the figure at that hour. A strip of sixteen day chips below
  picks the day (also a sideways swipe over the detail); air quality has tabs per pollutant. A click on the same link again closes it.
- Hover tips explain the location name and each tab.

## What it shows and where the data comes from

| What | Source | Kept in |
|---|---|---|
| Forecast, air quality | Open-Meteo (`api.open-meteo.com`, air quality, elevation, geocoder), `curl` | `$XDG_CACHE_HOME/lares/weather/<place>-forecast.json`, `-aq.json` |
| Observation, warnings, pollen note, radar nowcast, KMI's daily text | KMI app API (`app.meteo.be`) | `kmi-<lat>_<lon>.json`, `.svg` in the same folder |
| Belgian air-quality index (`aqiIndex: "belaqi"`) | IRCEL-CELINE forecast WMS | with the forecast |
| Where you are | geoclue through the `where-am-i` client | the hometown it learns: `$XDG_STATE_HOME/lares/weather/home.json` |

- Stale first: the cached picture paints at once, then each source is refetched when its cache is older than its `refreshMinutes`. While the popup
  is open the KMI nowcast refetches every `nowcastWhileOpen` minutes. A clock jump of more than five minutes (a resume from suspend) refetches.
- Offline: the cache stays on screen and the header says "offline, from 14:05"; otherwise it says "updated 14:05". A place with no cache shows a
  skeleton of the cards.
- No fix: geoclue answers nothing until its agent has been asked and answered, so the popup falls back to the hometown (the saved location marked
  `home`, else the town the first accepted fix named, else the default location). A failure you can act on (no `where-am-i` installed, say) is
  notified once per session. Delete `home.json` to learn the hometown again.
- KMI off (`sources.kmi.enabled: false`): the observation line, warnings, pollen and radar are absent; the rest works.

## Settings

`~/.config/quickshell/config/weather.jsonc`, read hot, every key optional (a missing or invalid one takes its default and is named in the service's
`lastError`). Starting file: `.examples/weather.jsonc` (every key, with comments).

| Key | Meaning | Default |
|---|---|---|
| `locations` | saved places: `{name, lat, lon, elevation?}` or `{query}`, plus `default` (what the current location shows with no fix and no hometown) and `home` marks; with the current location off the popup starts on the first entry | Brussels |
| `currentLocation` | `enabled`, `maxAccuracyM` (refuse coarser fixes), `nearSavedKm` (a fix this near a saved place takes its name) | true, 3000, 5 |
| `units` | `temperature` c/f, `wind` bft/speed, `speed` kmh/ms/mph/kn, `pressure` hpa/mbar/mmhg/inhg, `precipitation` mm/in, `distance` km/mi, `airQuality` (one value, ugm3), `co`, `clock` 24h/12h, `date` | c, bft, kmh, hpa, mm, km, ugm3, mgm3, 24h, dd/MM |
| `view` | `start`: the view a session opens on (mini / normal / detailed); `remember`: `session` (back as you left it) or `never` (every open on `start`) | mini, session |
| `look.secondarySide` | where a day's detail opens: `end`, `start`, `far` | end |
| `aqiIndex` | `eaqi` or `belaqi` | eaqi |
| `sources.openMeteo.model` | an Open-Meteo model id | best_match |
| `sources.kmi.enabled` | use the KMI API | true |
| `refreshMinutes` | `forecast`, `airQuality`, `kmi`, `nowcastWhileOpen` | 15, 60, 15, 5 |

Look and motion (card sizes, the sky, fades, the morph's duration, swipe thresholds) are tuned in `mockups/weather_popup.qml`; Save writes the module.

## How it is built

| Path | Role |
|---|---|
| `modules/weather/WeatherBarOwner.qml` | bar side: opens the popup, remembers the last view and the strip / list views for the session, the backdrop's gate |
| `modules/weather/WeatherBarButton.qml` | glyph and temperature in the bar |
| `modules/weather/WeatherPopup.qml` | the popup: three views, the view morph, the one wheel reader, the header |
| `modules/weather/WeatherHero.qml`, `WeatherBackdrop.qml` | the hero card and its sky (`modules/weather/shaders/weather_backdrop_v2.frag`, 30 Hz while the popup is on screen) |
| `modules/weather/WeatherHourlyStrip.qml`, `WeatherDailyList.qml`, `WeatherTiles.qml`, `WeatherTile.qml` | the other three cards |
| `modules/weather/WeatherDetail.qml` | the secondary popup: the chart, day chips, blocks |
| `modules/weather/data/WeatherService.qml` | the one service: config, caches, the clock tick, locations, `model` |
| `modules/weather/data/OpenMeteoSource.qml`, `KmiSource.qml` | the two fetchers |
| `modules/weather/data/WeatherLocation.qml`, `WeatherHome.qml` | geoclue through `where-am-i`; the learned hometown |
| `modules/weather/data/WeatherConfig.qml` | `weather.jsonc` loader |
| `modules/weather/data/WeatherModel.js`, `WeatherSeries.js`, `WeatherScales.js`, `WeatherContext.js`, `PlaceBlend.js`, `PlaceMerge.js`, `Astro.js` | pure JS: normalised model, chart series, scales and bands, the context line, the place morph, merging a fix into a saved place, sun and moon |
| `modules/weather/data/WeatherMock.qml` | the same service surface with fixed data (mock shell, mockup) |

Shared components used: `WeatherGlyph` and `TimelineChart` (the weather icons, see "The icon sets", and the chart), `ShadowBox`, `TabSelector`, `CardViewCycler` and
`ViewBlend` (views on one clock), `WheelStepper`, `ScrollDressing`, `SwapCurtain`, `HoverTip`, `HoverIntent`, `SkeletonBar`, `DesktopNotifier`, `ConfigFile`.

## Limits

- The observation, warnings, pollen and radar are the Belgian KMI's; its request key is built from Europe/Brussels' date.
- A live place fix needs the geoclue agent to have answered once per session; until then the hometown stands in.
- The strip shows 48 hours and the list 16 days.

## The icon sets

`WeatherGlyph` (`modules/common/components/`) draws a condition in one of two sets; every site (bar, hero, strips, tiles, detail, lock
band) uses it and names no set.

- **ink** (the default): `WeatherGlyphInk.qml`. Solid icons at the weight of the bar's font glyphs on Material's 24-unit grid, in the
  muted ink, with ONE coloured part per icon -- the sun, the moon, the drops, the flakes or stones, the bolt (what falls is the subject:
  under a shower the sun behind the cloud is ink). In the bar the icon is 18 px and goes to the weather's hover hue with the figure.
  The icons are DRAWN by `tools/dev/weather_ink_parts.py` (shapes as distances, parts behind cut by the part in front, outlines traced)
  into the generated `WeatherInkParts.js`; `WeatherInkCompose.js` picks the composition for a condition and computes the moon by phase.
  Two fills in a `Shape`: no shader, so nothing of it depends on the GPU mode (MUX).
- **carved**: the legacy full-colour carved glyphs (`shaders/weather_glyph.frag`, `WeatherGlyphParts.js`), which the mockup's Carve
  knobs shape.

The choice is `"glyphSet": "ink" | "carved"` in `weather.jsonc`, read live (`WeatherGlyphSet`, written by `ShellServices` alone). It is
TEMPORARY: the carved set, the key and `WeatherGlyphSet` go once the flourishes are approved too.

**The flourish** (the ink set's; the carved set has none). An icon moves as what it shows.

- In the BAR, on the bar glyphs' one contract (`GlyphFlourish` in `WeatherBarButton`: once per pointer entry, never restarted mid-play,
  nothing running at rest; group `weather`, decorative, so the OLED care's random flourishes play it and `oled.flourishes.glyphs` can
  switch it off).
- In the POPUP, every glyph flourishes when the pointer comes onto its item (once per entry, once the pointer moves) or picks it: the
  hero's glyph (its back-glow and its open-state disc are gone: the hand and the motion announce the link); an hour, a day, a tile (the
  wind's arrow, the pressure's trend, the moon); in the detail a day's chip (also when the day is selected), every slot of the
  conditions strip the scrub lands on, and the sun-and-moon card's moon. EACH PLAYS TO ITS END whatever the pointer does next: a sweep
  along a row leaves a wake of flourishes. A card holds ONE clock with a run per glyph (`WeatherGlyphFlourish`: `play(tag, beats)`,
  `on(tag)`, `beatOf(tag)`; a tag already running is not restarted); a single glyph under the pointer has a `GlyphFlourish` of its
  own. These have no group, so they never play at random. The beat is `WeatherPopup.glyphFlourishMs`.

| Part | Motion | Beats |
|---|---|---|
| sun | winds back a touch, turns a quarter with an overshoot, rays reaching out; behind a cloud it only turns | 1 |
| moon | rocks on its back, dying away; its stars wink out and pop back. Behind a cloud it dips out of sight and bounces back up | 1.5 / 1.6 |
| cloud | a quick breath and a sway; two clouds part and close; a second cloud behind a raining one slides out and back | 1.8 / 1.3 |
| drops, streaks | let go (fall away shrinking), then a new one swells from its point; one after the other | ~0.9 |
| flakes | melt to a seed and grow again, a crystal: three axes shoot out one after the other; a small dip and sway | 1.2+ |
| hail | hops, lands with a squash, bounces back to where it hangs | ~1 |
| bolt | drawn up toward the cloud (shrinks to its top, never out of sight), strikes back down past its length, shivers still; rain under it starts after | 1 |
| fog | rows slide past each other and settle | 2 |
| wind | each line's straight part pulled short and shot back out; the hook rides on its end unchanged | ~1 |
| moon by phase | rocks (the whole item) | 1.5 |
| wind arrow | draws back, darts along its heading, springs home; the dot of "no direction" swells | 0.8 / 0.6 |

A beat is `WeatherBarButton.flourishMs` (900, the bar's usual flourish); an icon runs for its longest part. The motions are
`WeatherInkPose.js` (pure functions of the clock; numbers in its `DEFAULTS`). Every motion is zero at its first and last instant, so the
swap with the icon at rest shows nothing (proved to the pixel). A part that lies BEHIND another cannot simply be moved (its cut would
move with it): the generator bakes it along its motion (`FRAMES`: the sun's turn, a moon's dip, a back cloud's slide, and a storm
cloud's cut along the size of the bolt that comes out of it) and the pose picks the frame. While it plays only the moving parts are
re-tessellated. Tune it in `mockups/weather_popup.qml`, Glyphs tab: the "In the bar" strip is the real button per condition
(hover, or Play all), "beat (bar)" and "beat (popup)" the pace.

To change an icon: edit its shapes in `tools/dev/weather_ink_parts.py`, look with `--sheet <png>` (no shell needed), run it to write
the outlines, then `tools/dev/weather_ink_probe.sh` (every condition at every size draws ink and its accent, the generated file is
current, the set switches live both ways; every flourish starts and ends on the icon at rest, moves in between and never leaves the
glyph's box; the real popup's glyphs play when their item is picked, `tools/dev/qml/weather_flourish_probe.qml`; five ARMs). `tools/dev/glyph_flourish_probe.sh` holds the button to the flourish contract and
`tools/dev/flourish_pool_probe.sh` to the random pool.

## How to change it

- Place, units, source, refresh cadence: `weather.jsonc` (saved with the shell running: it takes effect at once).
- A card's size, a fade, the sky's strength, swipe thresholds: `mockups/weather_popup.qml` (`quickshell -p ~/.config/quickshell/mockups/weather_popup.qml`),
  change on the panel, Save; or the property defaults at the top of `modules/weather/WeatherPopup.qml` and the card files.
- A strip view or a list view: the `views` array at the top of `modules/weather/WeatherHourlyStrip.qml` / `modules/weather/WeatherDailyList.qml`.
- A tile: `modules/weather/WeatherTiles.qml` (one block per tile).
- Proof: `tools/dev/smoke.sh mockups/weather_popup.qml`, `tools/dev/weather_ink_probe.sh` (the icons), `tools/dev/mockup_panel_test.sh mockups/weather_popup.qml`, `tools/dev/config_loaders_probe.sh` (the loader of `weather.jsonc`),
  `tools/dev/float_probe.sh` (the ten tiles' float on the backdrop's beat), `tools/dev/sheet_check.sh` (the whole shell, picture for picture).
