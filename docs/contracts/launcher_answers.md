# The launcher's answers child (`tools/launcher/answers.py`)

What the launcher shows above its app list when the typed text is a question with an answer (Spotlight / PowerToys Run style).
One long-lived Python 3 child per shell, standard library only, started by LauncherService through `SupervisedStream`
(`setpriv --pdeathsig TERM`), ended by stdin EOF. A runtime tool: the deploy snapshot keeps `tools/launcher/`, leaves `tools/dev/` out.
The reader is `modules/launcher/` (the answers-ui stream); this page is the fixed contract between them. Check:
`tools/dev/launcher_answers_probe.sh`.

## Protocol (fixed)

Request on stdin, one JSON object per line: `{"id": 7, "q": "<the query as typed>"}`; `{"id": 7, "cmd": "ping"}` answers
`{"id": 7, "pong": true}`. A request with no string `q` answers `[]`; a line that is not a JSON object is ignored (no reply, one
line on stderr).

Reply on stdout, one JSON line per request, the request's id (the reader drops a reply whose id is not the latest):

```
{"id": 7, "answers": [ {
    "kind":   "math" | "currency" | "base" | "time" | "unit" | "date" | "zone" | "colour" | "percent" | "ratio" | "resolution",
    "value":  "92.31 EUR",      // the main answer as shown; digits of 10 000 and up grouped with U+202F
    "copy":   "92.31",          // what Enter copies: plain, no grouping, "." decimal
    "expr":   "100 USD → EUR",  // what was understood, normalised (shown small)
    "detail": "ECB 2026-11-18 · 1 USD = 0.9231 EUR",   // small print, "" when none
    "alts":   [ {"label": "rgb", "value": "rgb(68 128 244)", "copy": "rgb(68, 128, 244)"} ],   // 0..3
    "swatch": "#4480f4",        // colour kind only, else absent
    "pending": false            // true: the value will be replaced
} ] }
```

`answers` is `[]` when the query is not an answer (most queries: application names, ordinary words, a bare number). At most 3,
best first. A `pending` answer is followed, unasked, by a second reply with the SAME id when the data lands; the child sends it only
while that id is still the newest it has seen. Errors never reach stdout as text; the child's own trouble is one line on stderr
(`lares-answers: ...`).

## Display numbers

Exact arithmetic (Fraction / big int) wherever it can be; floats only for transcendental functions. 12 significant digits;
integers exact up to 40 digits, then scientific; scientific (`1.5e-7`, `9.33262154439e157`) from 1e15 and under 1e-5.
`1/3` -> `0.333333333333` with the fraction `1/3` as an alt. `copy` never groups. Division by zero, a bare number, a lone word,
a name that is not a unit or a zone: `[]`.

## The grammars

Case-insensitive except data units (`MB` bytes, `Mb` bits, `Mbps`). The cases are `tools/dev/launcher_answers_cases.tsv` (371).

| kind | examples (value) | notes |
|---|---|---|
| math | `2+3*4` (14), `2(3+4)`, `2pi`, `1.2e3 * 2`, `10 mod 3`, `5!`, `sqrt(16)`, `sin(30°)` (0.5), `2^100`, `1,234.5*2`, `1,5 + 1` (2.5) | `+ - * x × / ÷ ^ **`, parens, unary minus (`-2^2` = -4), `mod`, `%` between operands, `!`, sqrt cbrt abs round floor ceil sin cos tan asin acos atan sinh cosh tanh ln log log2 log10 exp, constants pi π e tau phi, implicit multiplication, `° / deg` (radians otherwise). A comma followed by exactly 3 digits groups; else it is a decimal comma. Needs at least one operator or function. A hand-written tokenizer and parser, no `eval`. |
| base | `0xff` (255; alts bin, oct), `255 in hex` (0xff), `255 to bin`, `0xff in dec`, `hex 255`, `bin 42`, `255 in base 36`, `0xff + 1` (256; alts hex, bin, oct) | `0x 0b 0o` literals; `copy` of a prefixed result keeps the prefix. Integers only. |
| time | `3h20m + 45m` (4h 5m), `2:30 * 3` (7h 30m), `17:45 - 9:15`, `90 min in h` (1.5 h), `1.5h in min`, `45m * 4`, `90 min in h:mm` (1:30) | durations are `h:mm[:ss]` or `3h20m` runs; a lone `m` means minutes only in a query with no other reading; `5 m in cm` stays a unit. |
| unit | `5 ft in cm` (152.4), `5'11" in cm`, `3.2 GiB in MB`, `70 f in c`, `100 km/h in mph`, `100 mbps in MB/s` (12.5), `30 mpg in l/100km` | length, mass, temperature (exact, through kelvin), speed, area (`m2`, `sqft`, `acre`), volume, data (decimal and IEC, bits vs bytes), time, energy, power, pressure, force, frequency, angle, fuel. Needs `in / to / as / ->`; both units must share a dimension. Alts: three related units. |
| currency | `100 usd in eur` (90.98 EUR), `$100 in €`, `€20 in gbp`, `20 eur` (to USD: the home currency is EUR), `20 usd` (to EUR), `usd to gbp` (the rate), `2k usd in eur`, `100 dollars in euros` | the ECB's reference rates; symbols `$ € £ ¥ ₹ ₩ ₺ zł R$ ...`, 3-letter codes of the ECB list, a few names. 2 decimals (0 for JPY KRW IDR), 4 significant digits under 1, 5 for a rate. Home currency: `--home-currency XXX` or `LARES_HOME_CURRENCY`. |
| percent | `15% of 80` (12), `45 is what % of 60` (75 %), `what % is 45 of 60`, `80 + 21%` (96.8), `80 - 15%`, `15% off 80`, `80 to 100 in %` (+25 %), `% change 80 to 100`, `12 is 15% of what` | a bare `50%` is no answer. |
| ratio | `16:9 at 1440 wide` (1440 × 810), `16:9 1440 tall`, `21:9 of 3440` (3440 × 1474, exact in detail), `aspect 1920x1080` (16:9), `1920x1080 ratio`, `aspect 1366x768` (≈ 16:9) | |
| resolution | `1080p`, `4k` (3840 × 2160, alt DCI 4096 × 2160), `qhd wqhd uhd fhd hd wuxga 5k 8k`, `2k` (2560 × 1440, as monitors are sold; alt DCI 2048 × 1080), `1440p ultrawide` / `1440p 21:9` (3440 × 1440), `1080p 16:10` (1728 × 1080), `2560x1440` (name, ratio, MP), `27in 1440p` / `27" 4k` / `14 inch 2880x1800` (PPI; alts dot pitch, size in cm), `16:9` alone (the common resolutions of that ratio) | `copy` is `WxH`; PPI is `hypot(w, h) / diagonal`. A bare `2:30` is no ratio: only 16:9 16:10 4:3 21:9 32:9 3:2 5:4. |
| colour | `#4480f4`, `#48f`, `#4480f480`, `rgb(68,128,244)`, `rgb 68 128 244`, `rgba(68,128,244,.5)`, `hsl(220, 89%, 61%)`, `colour red` | value is the hex; alts rgb / hsl / oklch (copy in comma form); `swatch` set. CSS names only after `colour` / `color`; a bare 6-hex-digit word is not a colour. The nearest theme token is the UI's job. |
| zone | `3pm tokyo in brussels` (07:00 CET), `15:00 tokyo`, `now in new york`, `time in tokyo`, `tokyo time`, `9am pst in cet`, `3pm in tokyo`, `2026-03-15 12:00 new york in brussels` | DST-correct (zoneinfo). Places: every city of `zone1970.tab`, ~250 aliases (san francisco, mumbai, ...), abbreviations (UTC GMT CET PST EST JST IST=Kolkata AEST ...), `utc+5:30`. Home zone: `LARES_ANSWERS_TZ`, `TZ`, `/etc/localtime`. A date (`2026-03-15`, `tomorrow`) may stand anywhere. A time the clocks skip moves forward. `copy` is `HH:MM`; the day shift is in the value (`(tomorrow)`). |
| date | `days until 24 dec` (35 days), `days since 1 jan`, `days until christmas`, `days between 1 jan and 1 mar`, `+90 days`, `today + 2 weeks`, `3 weeks ago`, `2026-12-24 - today`, `24 dec + 1 week`, `week 47`, `week number`, `unix 1700000000`, `now in unix`, `what day is 24 dec 2026`, `day of year` | calendar months and years clamp the day; `copy` of a date is ISO. A lone `now`, `today`, `week`, `time` is no answer. |

Application names must stay `[]`: `tools/dev/fixtures/launcher_app_names.txt` (this machine's `Name=` lines plus tricky ones:
`2048`, `7zip`, `1password`, `4k video downloader`, `k3b`, `x11`) is checked line by line by the probe.

## Currency, cache and network

Rates: `https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml` (keyless; `<Cube time='YYYY-MM-DD'>` holding
`<Cube currency='USD' rate='1.0992'/>` per currency, euro base; measured 2026-11-19, 29 currencies). Overridable with
`LARES_ECB_URL` (a `file://` or a local server, for tests). The request carries `User-Agent: lares-launcher/0.1` and nothing
about the user; timeout 5 s.

Cache: `$XDG_CACHE_HOME/lares/launcher/ecb-rates.json` = `{"date": "<ECB date>", "fetched": <epoch>, "rates": {"USD": "1.0992", ...}}`,
written atomically. It is read at the first currency query, never at start. A fetch starts only when a currency query needs
rates and the cache is missing or older than 12 h (`LARES_ECB_STALE_S` shortens it for tests); one at a time; after a failure
none for 5 minutes (a keystroke never refetches).

While a fetch runs the answer is `pending: true`: with the cached value when there is a cache (`detail` names its date), else
`value: "…"`, `copy: ""`. When the fetch ends the child sends the second reply with the same id, `pending: false` (if that id is
still its newest). Offline with no cache: `value: "rates unavailable"`, `copy: ""`; offline with an old cache: the old rates,
`detail` ends `(offline, last known)`. A currency the ECB does not list answers `[]`.

## Speed

Measured here (Python 3.14): start to first reply 70 ms including the interpreter; 0.2 ms median, 0.5 ms p95 per query once
warm through the pipe; an idle-time prewarm after start compiles the regexes and builds the zone table, so the first typed
query is ~10 ms at worst. Queries are cut at 200 characters.

## Options (argv, from launcher.jsonc `answers`)

`--home-currency XXX`, `--currencies XXX,YYY` (the ones beside an amount, in order; the first that is not the home currency is what a home amount is
turned into), `--kinds a,b` (the families that answer: `colour resolution percent currency base zone date timearith unit math`; a name it does not
know is ignored, none at all answers nothing). The shell always passes all three; absent, the defaults stand.

## Test hooks (environment, for runners only)

`LARES_ANSWERS_NOW` (an ISO instant: "now"), `LARES_ANSWERS_TZ` (home zone), `LARES_HOME_CURRENCY`, `LARES_ECB_URL`,
`LARES_ECB_STALE_S`, `XDG_CACHE_HOME`. The probe fixes the world at 2026-11-19T12:00:00Z, Europe/Brussels, EUR and the frozen
`tools/dev/fixtures/launcher_ecb_daily.xml`; `ARM=factor|parser|nopending|ratebias|allkinds` patches a copy and must FAIL naming a case.
