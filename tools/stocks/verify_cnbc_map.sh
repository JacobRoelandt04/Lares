#!/usr/bin/env bash
# Ask CNBC for one known symbol per Yahoo suffix the stocks module maps, and
# print which mappings answer (code 0) and which do not.
#
#   tools/stocks/verify_cnbc_map.sh
#
# The table in modules/stocks/data/Markets.js (cnbcSymbol) and in
# docs/stocks.md is THIS output, dated. Re-run it before trusting the
# map again: CNBC's symbology is undocumented and can move.
set -u
UA="Mozilla/5.0"
# yahoo  cnbc  (one real listing per exchange suffix / special form)
PAIRS="ASML.AS:ASML-NL KBC.BR:KBC-BE AIR.PA:AIR-FR SAP.DE:SAP-DE VOD.L:VOD-GB NESN.SW:NESN-CH
ENI.MI:ENI-IT SAN.MC:SAN-ES NOKIA.HE:NOKIA-FI EQNR.OL:EQNR-NO EDP.LS:EDP-PT RY.TO:RY-CA
AAPL:AAPL BRK-B:BRK.B ^GSPC:.SPX ^AEX:.AEX ^BFX:.BFX ^IXIC:.IXIC ^STOXX50E:.STOXX50E EURUSD=X:EUR=
NOVO-B.CO:NOVOB-DK VOLV-B.ST:VOLVB-SE 7203.T:7203-JP 0700.HK:0700-HK OMV.VI:OMV-AT IWDA.AS:IWDA-NL"
list=""
for p in $PAIRS; do list="$list|${p#*:}"; done
list="${list#|}"
url="https://quote.cnbc.com/quote-html-webservice/restQuote/symbolType/symbol?symbols=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$list")&requestMethod=itv&noform=1&partnerId=2&fund=1&exthrs=1&output=json"
json=$(curl -q -sS --max-time 20 -A "$UA" "$url") || { echo "VERIFY FAIL: request"; exit 1; }
PAIRS="$PAIRS" python3 - "$json" <<'PY'
import json, os, sys, datetime
q = {r.get("symbol"): r for r in json.loads(sys.argv[1])["FormattedQuoteResult"]["FormattedQuote"]}
print("CNBC map, verified", datetime.date.today().isoformat())
ok = bad = 0
for p in os.environ["PAIRS"].split():
    y, c = p.split(":", 1)
    r = q.get(c, {})
    good = r.get("code") == 0 and r.get("last") not in (None, "")
    ok += good; bad += not good
    print(f"  {'OK  ' if good else 'FAIL'} {y:12s} -> {c:12s} {r.get('exchange') or ''} {r.get('currencyCode') or ''}")
print(f"VERIFY DONE ok={ok} fail={bad}")
PY
