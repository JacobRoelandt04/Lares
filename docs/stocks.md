# Stocks

## What it is

Your portfolio at a glance. The bar shows a tiny line of today's portfolio value and the day's change in percent while a market you hold is
open. Click it for a popup with the total value, the day's and total gain, a value-against-invested chart, a strip of market indices, and
your holdings and watchlist; click a stock for its chart, figures and every transaction. Money never appears on the bar.

## Where it lives

- Bar: centre island, right of the clock. While any held market is open the button shows a 22 x 12 sparkline and the day's percent in the
  gain or loss colour; a percentage that changes rolls over as the clock's minutes do. When every held market is closed it wears the skeleton of that face (the same line and percent slot as quiet
  placeholders) in the accent blue: nothing is going up or down. On a side bar the face runs along the bar.
  Its flourish (a hover, or the OLED care's random turn; group `stocks`): a ripple runs left to right along the line, a 2 px bulge on a green day and a
  dip on a red one, and flicks a faint triangle up or down off the line's tip; closed, a neutral wave runs through the skeleton and the three dots hop in
  turn, no arrow. The percent never moves and the button's width never changes. `flourishStyle` (`both` / `ripple` / `arrow`) and its numbers are on the
  mockup's Bar tab.
- Popup: one layout, 504 px wide: summary card, a tab row (Holdings | Watchlist) with a search field beside it, and the list card. The list is
  six rows tall whatever it holds, so a tab switch or a search never resizes the popup.
- Detail: the stock's own popup, the engine's secondary, grown beside the popup (`look.secondarySide`). It comes back with the popup for the shell's session,
  while it was on screen less than 10 minutes ago (`detailMemoryMin`; `SecondaryMemory` keeps whether it was open and on which stock, per
  screen, in memory: a restart or a boot forgets it).
- No keyboard shortcut and no IPC verb. An alert notification's "Open" button opens the popup with that stock's detail out.

## What you can do

Summary card
- Read total value, the day's change and total gain (amount and percent). Beside "Portfolio" a faint note says when the figures on show
  were fetched ("updated 11:02"); when they cannot be trusted it says why instead, in the warning colour ("offline, from 08:02", "stale,
  from 10:40", "rate limited, retry 11:06"). It changes when new figures are shown, never between. Hover the total gain: every gain figure in the popup and the detail
  flips to its real (inflation-adjusted) value, "Total gain" becomes "Real gain", and a pale pill flashes behind each figure that changed. The
  hover also shows how the total is made up.
- The chart plots value over invested; range chips 1D, 5D, 1M, 6M, YTD, 1Y, 5Y, ALL (a sideways swipe over the chips or the chart steps the range,
  remembered). Move the pointer over the chart to scrub: a hairline and dots, and the title line reads the date, the value and the invested amount.
- The indices strip shows three of your indices at a time, rolling through them every four seconds; rest the pointer on it and the cells snap to the biggest
  movers among the indices (held until a moment after you leave). A click on an index opens its detail.

List
- Holdings and Watchlist tabs (a two-finger sideways swipe over the tab row switches). Type in the search field to look up a symbol on Yahoo
  (the list is replaced by results; Esc clears).
- A holding row: logo, symbol, a day sparkline, the price in the stock's own currency, the day percent; second line: name, shares, value in EUR,
  total gain. A watchlist row: price, day percent, name and exchange. Outside regular hours a US listing shows its pre / post-market move.
- The sort control in the list header picks Value, Day, Total or Name and the direction (remembered). Fully sold positions sit under a collapsed
  "Closed" header (open or shut is remembered).
- Click a row for its detail; a second click on the same row closes it.

Detail
- Header: the logo (a link to Yahoo's quote page), name, exchange, currency, market state, price and day change, the star that puts the stock on
  or takes it off the watchlist.
- Range chips 1D, 5D, 1M, 6M, YTD, 1Y, 5Y, MAX; the chart marks your buys and sells, a dashed average-cost line, the previous close on 1D and
  faint volume. Scrub to read a point. The next stock you click morphs the chart instead of blanking.
- Twelve figures (open, high, low, previous close, volume, average volume, market cap, P/E, EPS, dividend yield, beta, 52-week range with
  a groove showing where the price stands); a missing one reads "—".
- For stocks you hold or held: the position and every transaction, newest first, three rows visible then scroll.

## What it shows and where the data comes from

| What | Source | Kept in |
|---|---|---|
| Prices, sparklines, charts, history, FX, search | Yahoo Finance (keyless, by `curl`) | `$XDG_CACHE_HOME/lares/stocks/` (`spark.json`, `history/`, `fx/`, `charts/`) |
| Market cap, P/E, EPS, yield, beta, average volume | CNBC | in the detail's cache |
| Inflation for the real figures | Eurostat HICP, monthly, for `inflation.geo` | `hicp-<geo>.json`, refetched at most daily |
| Logos | fetched by `tools/stocks/stock_logo.py` and baked to a relief texture and a monogram | `logos/` under the cache |
| Watchlist, sort, tab, ranges, the Closed fold, alert latches | the shell | `$XDG_STATE_HOME/lares/stocks/state.json` |

- Cache first: the cached picture paints at once and `stale` stays on until a fetch lands. Polling follows the markets: a minute with the popup
  open and any market open, five minutes closed; all markets closed: one fetch two minutes after the last close, then idle until the next open.
  A late tick (a suspend) refreshes. Opening the popup over a cache older than 30 minutes fetches at once.
- Rate limited (429): the service backs off from two minutes up to an hour and keeps the cache on screen.
- Offline: the cache stays and the popup says so (the summary card's note). A mistake in `stocks.jsonc` keeps the last good portfolio and says so: "stocks.jsonc has an error" in the summary card's note, and the error's line and column in place of the empty list's text when there is no portfolio yet.
- No holdings: the list is empty and says why.
- Alerts: a desktop notification once per crossing of an `alerts` rule, re-armed when the price has moved back by `alertHysteresis`. A sudden move
  (`sudden`) notifies once per direction per day while its market is open. Whether the shell speaks and for which stocks is
  `notifications.jsonc`, `sources.stocks` (`enabled`, `sudden`, `scope`).
- Every stocks card carries one graph (`modules/notifications/sources/StockMoveBody.qml`): the day so far by TIME (open to now, at least an hour of axis),
  the previous close dashed, the height standing for at least twice the rule's percent so a small move looks small. A sudden move draws the day faint and
  the move's span strong over a soft fill, with the span's start and now under it; above / below add their level as a dashed accent line. The card is born
  from the day's 5-minute bars in memory; a sudden card then asks once for 1-minute bars (`StocksService.fineSpark`, its own lane, never retried, a 429 of
  it never touches the polling's backoff) and the span is sharpened in place. Alerts stay at 5 minutes.

## Settings

`~/.config/quickshell/config/stocks.jsonc` (your portfolio: read hot, comments allowed, kept out of git). Starting file: `.examples/stocks.jsonc`, every
key with its default and a sample holding.

| Key | Meaning | Default |
|---|---|---|
| `currency` | totals' currency (only `EUR`); stocks are shown in their own | EUR |
| `inflation.geo` | Eurostat country for the real figures | BE |
| `dividendWithholding` | share of each dividend kept back as tax, from 0 up to (not including) 1 (dividends are found automatically) | 0.30 |
| `indices` | index cells: Yahoo symbols as strings or `{symbol, alias}` | BEL 20, AEX, Euro Stoxx 50, S&P 500, Nasdaq, EUR/USD |
| `detailMemoryMin` | the detail comes back with the popup when it was on screen less than this many minutes ago; 0 never | 10 |
| `refreshSec` | quotes while a market is open: `open` with the popup open (30 .. 3600), `closed` with it shut (60 .. 86400); the 1D / 5D chart and the extended move follow | 60, 300 |
| `extendedHours` | pre- and post-market prices shown (and the 1D chart asked with them) | true |
| `quoteUrl` | the page a stock's link opens, `{symbol}` its Yahoo symbol | Yahoo's quote page |
| `look.secondarySide` | where the detail opens: `end`, `start`, `far` | end |
| `alertHysteresis` | fraction a price must retreat before an alert re-arms | 0.005 |
| `alerts` | `{symbol ("*" = every stock), above, below, dayMove}` | none |
| `sudden` | `{pct, minutes, bySymbol}` (a symbol's value may be `false`) | 3 % in 30 min |
| `holdings` | per stock: `symbol`, optional `alias`, `image`, `isin`, `cnbc`, and `actions` (`type` buy or sell, `date`, `shares` before any later split, `price` in the quote currency, `fees`, `comment`) | none |

London quotes in pence: 93.30 means 93.30 p. Look and motion (popup width, row height, list rows, the strip's cycle, chart heights, where the detail opens) are
tuned in `mockups/stocks.qml`; Save writes the module.

## How it is built

| Path | Role |
|---|---|
| `modules/stocks/StocksBarOwner.qml`, `StocksBarButton.qml` | bar side: toggle, `openSymbol`, the button's two faces |
| `modules/stocks/StocksPopup.qml` | the popup and the engine's secondary contract (where the detail opens, which links) |
| `modules/stocks/StocksSummaryCard.qml`, `StocksIndexStrip.qml`, `RollingCells.qml`, `GainFlash.qml` | the summary, the rolling index cells, the real-figure flash |
| `modules/stocks/StocksList.qml`, `StockRow.qml` | the carved list and a row |
| `modules/stocks/StockDetail.qml`, `StockDetailHeader.qml`, `StockRangeChips.qml`, `StockStatsGrid.qml`, `StockPosition.qml` | the detail |
| `modules/stocks/SecondaryMemory.qml` | whether the detail was open and on what |
| `modules/stocks/parts/StocksPose.js` | the bar flourish's motion (pure: the ripple's displacement, the dots' hop, the arrow) |
| `modules/stocks/data/StocksService.qml` | the one service: cadence, caches, snapshots |
| `modules/stocks/data/YahooSource.qml`, `CnbcSource.qml`, `HicpSource.qml`, `StocksFetch.qml` | the fetchers (a foreground and a background `curl` lane) |
| `modules/stocks/data/StocksConfig.qml`, `StocksState.qml`, `StockLogos.qml` | `stocks.jsonc` loader; state file; the logo cache and its one worker |
| `modules/stocks/data/Markets.js`, `Portfolio.js`, `StockSeries.js`, `StocksFormat.js` | pure JS: URLs and parsing, market hours, money (lots, splits, dividends, real values), chart specs, number formats |
| `modules/stocks/data/StocksViewModel.qml`, `StocksMock.qml` | the rows the popup reads; the same service surface on captured data (`modules/stocks/data/fixtures/`) |

Shared components used: `ShadowBox`, `TabSelector`, `SortControl`, `ListSectionHeader`, `CarvedSearchField`, `ScrollDressing`, `SwapCurtain`,
`TimelineChart` (chart and its morph), `Sparkline`, `LogoRelief`, `WheelStepper`, `HoverTip`, `SkeletonBar`, `DesktopNotifier`, `ConfigFile`.

## Limits

- Only EUR totals; a stock in another currency is converted with its FX history.
- The data is keyless and unofficial; Yahoo wants a browser User-Agent and rate-limits, CNBC's symbol is derived from Yahoo's unless `cnbc` is set.
- A stock outside Yahoo's and CNBC's coverage shows "—" for what is missing.
- The detail is a fixed height per kind of stock; only a screen too short for it scrolls its body.

## How to change it

- Holdings, alerts, indices, withholding: `stocks.jsonc` (saved: it applies at once).
- Which stocks notify and whether sudden moves speak: `notifications.jsonc`, `sources.stocks`.
- Row height, list rows, popup width, chart height, strip timing: `mockups/stocks.qml` (`quickshell -p ~/.config/quickshell/mockups/stocks.qml`), change
  on the panel, Save.
- The sort modes or ranges: `sortKeys`, `summaryRanges`, `detailRanges` at the top of `modules/stocks/data/StocksState.qml`.
- Proof: `tools/dev/smoke.sh mockups/stocks.qml`, `tools/dev/mockup_panel_test.sh mockups/stocks.qml`, `tools/dev/config_loaders_probe.sh` (`stocks.jsonc`),
  `tools/dev/sheet_check.sh`, `tools/dev/stocks_note_probe.sh` (the summary card's note), `tools/dev/stock_notif_probe.sh` (the cards' graph; `ARM=all`), `tools/dev/stock_notif_sheet.sh`
  (old against new cards), `tools/dev/glyph_flourish_probe.sh` (the bar flourish; ARMs stocksclosedarrow, stockswrongway, stocksrestwarp, stocksmodelive), `SITES=stocks tools/dev/fade_edges_probe.sh` (the list's
  fades cover what its clip lets through, at every device-pixel phase of the 1.25 shell).
