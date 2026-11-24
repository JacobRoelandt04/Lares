#!/usr/bin/env bash
# Capture the live responses the stocks mock and its test stubs are built on.
#
#   tools/stocks/capture_fixtures.sh [outdir]     default modules/stocks/data/fixtures
#
# Every request shape the service sends is captured here ONCE, live, before it
# goes into a stub's expectations (CLAUDE.md: "a stubbed API only proves the
# request you expected"). The files are named by what they answer; `urls.tsv`
# maps each file to the exact URL it came from, which is what a fake curl
# serves by. `captured.json` holds the capture
# time: the mock pins its clock there rather than shifting every timestamp.
#
# Yahoo answers curl's own User-Agent with HTTP 429; "Mozilla/5.0" is enough.
# Requests are spaced 0.7 s apart so a capture is not itself a burst.
set -u
cd "$(dirname "$0")/../.."
OUT="${1:-modules/stocks/data/fixtures}"
mkdir -p "$OUT/logos"
: > "$OUT/urls.tsv"
UA="Mozilla/5.0"
fails=0

get() {  # get <file> <url>
    local f="$1" url="$2" code
    code=$(curl -q -sS -L --compressed --max-time 20 -A "$UA" -o "$OUT/$f" -w '%{http_code}' "$url")
    printf '%s\t%s\t%s\n' "$f" "$code" "$url" >> "$OUT/urls.tsv"
    printf '%-40s %s\n' "$f" "$code"
    case "$code" in 200) ;; *) fails=$((fails + 1)) ;; esac
    sleep 0.7
}
enc() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9.-]/_/g'; }

Y1="https://query1.finance.yahoo.com"
Y2="https://query2.finance.yahoo.com"
HOLD="ASML.AS KBC.BR AAPL NVDA VOD.L IWDA.AS UCB.BR"
WATCH="MSFT ABI.BR"
IDX="^BFX ^AEX ^STOXX50E ^GSPC ^IXIC EURUSD=X"
FX="USDEUR=X GBPEUR=X"

python3 -c 'import json,time; print(json.dumps({"capturedAtMs": int(time.time()*1000)}))' > "$OUT/captured.json"

# spark: one call, every symbol (<= 20)
syms=""
for s in $HOLD $WATCH $IDX $FX; do syms="$syms,$(enc "$s")"; done
get spark.json "$Y1/v7/finance/spark?symbols=${syms#,}&range=1d&interval=5m"

# the portfolio's 5-day intraday (summary chart 5D): held symbols + their FX
syms5=""
for s in ASML.AS KBC.BR AAPL NVDA VOD.L IWDA.AS $FX; do syms5="$syms5,$(enc "$s")"; done
get spark_5d.json "$Y1/v7/finance/spark?symbols=${syms5#,}&range=5d&interval=15m"

# daily history + events per holding, from a week before its first action
declare -A FIRST=( [ASML.AS]=2023-03-08 [KBC.BR]=2022-05-03 [AAPL]=2021-01-25 [NVDA]=2022-09-26
                   [VOD.L]=2023-01-09 [IWDA.AS]=2021-06-01 [UCB.BR]=2021-03-01 )
for s in $HOLD; do
    p1=$(date -u -d "${FIRST[$s]}" +%s)
    get "history_$(slug "$s").json" "$Y1/v8/finance/chart/$(enc "$s")?period1=$p1&period2=$(date -u +%s)&interval=1d&events=div%2Csplit"
done
for s in $FX; do
    p1=$(date -u -d 2021-01-18 +%s)
    get "fx_$(slug "$s").json" "$Y1/v8/finance/chart/$(enc "$s")?period1=$p1&period2=$(date -u +%s)&interval=1d"
done

# detail charts: every range for one stock, a few for the others
for ri in 1D:1d:5m 5D:5d:15m 1M:1mo:60m 6M:6mo:1d YTD:ytd:1d 1Y:1y:1d 5Y:5y:1wk MAX:max:1mo; do
    IFS=: read -r name range interval <<< "$ri"
    get "chart_ASML.AS_$name.json" "$Y1/v8/finance/chart/ASML.AS?range=$range&interval=$interval&events=div%2Csplit"
done
get "chart_AAPL_1D.json"   "$Y1/v8/finance/chart/AAPL?range=1d&interval=5m&events=div%2Csplit"
get "chart_AAPL_1Y.json"   "$Y1/v8/finance/chart/AAPL?range=1y&interval=1d&events=div%2Csplit"
get "chart_VOD.L_1Y.json"  "$Y1/v8/finance/chart/VOD.L?range=1y&interval=1d&events=div%2Csplit"
get "chart__GSPC_1D.json"  "$Y1/v8/finance/chart/%5EGSPC?range=1d&interval=5m&events=div%2Csplit"

# search (+ the spark for its results is covered by spark.json's shape)
get search_asml.json "$Y2/v1/finance/search?q=asml&quotesCount=8&newsCount=0"
get search_kbc.json  "$Y2/v1/finance/search?q=kbc&quotesCount=8&newsCount=0"

# CNBC stats, the mapped symbols
get cnbc.json "https://quote.cnbc.com/quote-html-webservice/restQuote/symbolType/symbol?symbols=ASML-NL%7CKBC-BE%7CAAPL%7CNVDA%7CVOD-GB%7CUCB-BE%7CMSFT%7CABI-BE%7C.SPX&requestMethod=itv&noform=1&partnerId=2&fund=1&exthrs=1&output=json"

# HICP, Belgium, the ECOICOP v2 dataset
get hicp_BE.json "https://ec.europa.eu/eurostat/api/dissemination/statistics/1.0/data/prc_hicp_minr?format=JSON&geo=BE&coicop18=TOTAL&unit=I15&sinceTimePeriod=1996-01"

# logos: SVG tiles (a mark on a brand-colour rect), a PNG-only tile, an ISIN
# wordmark tile, a TRANSPARENT word-mark (^GSPC: no tile, alpha is the mark)
# and an unknown symbol (404, empty body)
get logos/ASML.AS.svg  "https://assets.parqet.com/logos/symbol/ASML.AS?format=svg"
get logos/AAPL.svg     "https://assets.parqet.com/logos/symbol/AAPL?format=svg"
get logos/KBC.BR.png   "https://assets.parqet.com/logos/symbol/KBC.BR?format=png&size=512"
get logos/IE00B4L5Y983.svg "https://assets.parqet.com/logos/isin/IE00B4L5Y983?format=svg"
get logos/_GSPC.svg    "https://assets.parqet.com/logos/symbol/%5EGSPC?format=svg"
get logos/NOPE_XYZ123.404 "https://assets.parqet.com/logos/symbol/NOPE_XYZ123?format=svg"

echo "CAPTURE DONE failures=$fails (NOPE_XYZ123 is an expected 404)"
