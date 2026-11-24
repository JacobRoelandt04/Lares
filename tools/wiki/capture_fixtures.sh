#!/usr/bin/env bash
# Capture the live responses the wiki module's tool, stub server and probes are built on.
#
#   tools/wiki/capture_fixtures.sh [outdir]     default tools/dev/fixtures/wiki
#
# Every request shape wiki.py sends is captured here ONCE, live, before it goes into a stub's
# expectations (CLAUDE.md: "a stubbed API only proves the request you expected"). Files are
# named by what they answer. `urls.tsv` maps each file to the exact URL it came from
# (file<TAB>http_code<TAB>url); the stub serves by it. Two URLs that answer with the same bytes
# (an alias) are two rows on one file. `captured.json` holds `capturedAtMs` (the mock pins its
# clock there) plus, per request, the status, size, time, content type and cache headers, and
# every 429 the run met.
#
# Wikimedia wants a descriptive User-Agent with CONTACT INFO THAT IS AN EMAIL OR A FULL URL, so NOT
# "Mozilla/5.0" and NOT "(+github.com/x)": a UA whose contact is not a full URL/email is treated as
# unidentified and limited to 10 requests/min (429 + Retry-After ~40 s); with "(https://github.com/x)"
# it is a compliant bot UA at 200/min (30 of 30 in a row, against a 429 at the 15th with an unidentified UA; api_notes.md).
# A 429 is waited out and retried. wikipedia/ratelimited_429.txt is a real 429 and is kept across
# captures (a capture does not provoke one).
#
# Only this script's own directories under the outdir are touched (the Jev fixtures and the
# weighted-pick cases live beside them and belong to other streams).
set -u
export LC_ALL=C
cd "$(dirname "$0")/../.." || exit 1
OUT="${1:-tools/dev/fixtures/wiki}"
UA="lares-wiki/0.1 (https://github.com/JacobRoelandt04/Lares)"
GAP="${GAP:-0.7}"          # any other host
WM_GAP="${WM_GAP:-0.7}"    # Wikimedia hosts (one shared limiter)
# a capture replaces its own directories whole (a stale file of another shape would pass for a current one)
for d in wikipedia arch gentoo kernel freedesktop wikidata feed commons pageviews; do
    [ -d "$OUT/$d" ] && find "$OUT/$d" -mindepth 1 ! -name ratelimited_429.txt -delete
done
mkdir -p "$OUT"/{wikipedia,arch,gentoo,kernel,freedesktop,wikidata,feed,commons,pageviews}
: > "$OUT/urls.tsv"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/requests.jsonl"
: > "$TMP/ratelimits.jsonl"
START_MS=$(python3 -c 'import time; print(int(time.time()*1000))')
fails=0
NREQ=0
declare -A LAST

WP="https://en.wikipedia.org/w/api.php"
ARCH="https://wiki.archlinux.org/api.php"
GENTOO="https://wiki.gentoo.org/api.php"
WD="https://www.wikidata.org/w/api.php"
COMMONS="https://commons.wikimedia.org/w/api.php"

# mkurl <base> k=v ... : one canonical URL, every value percent-encoded (%20 for space)
mkurl() { python3 - "$@" <<'PY'
import sys, urllib.parse
base, pairs = sys.argv[1], [a.split('=', 1) for a in sys.argv[2:]]
q = '&'.join('%s=%s' % (k, urllib.parse.quote(v, safe='')) for k, v in pairs)
print(base + ('?' + q if q else ''))
PY
}
slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9.-]/_/g; s/__*/_/g'; }
# jget <file> <python expr on d> : read a captured JSON
jget() { python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(eval(sys.argv[2]))
PY
}

family() { case "$1" in *wikipedia.org*|*wikimedia.org*|*wikidata.org*) echo wm ;; *) echo "$1" | sed 's#https\?://##; s#/.*##' ;; esac; }
pace() {  # pace <family> <gap>
    local last="${LAST[$1]:-0}" w
    w=$(awk -v n="$EPOCHREALTIME" -v l="$last" -v g="$2" 'BEGIN{w=l+g-n; if (w<0) w=0; print w}')
    sleep "$w"
}

# fetch <dest> <url> [curl args] : sets $code; waits out a 429 (Retry-After) up to 3 tries
fetch() {
    local dest="$1" url="$2"; shift 2
    local fam gap try=0 ra t0 t1
    fam=$(family "$url"); gap=$GAP; [ "$fam" = wm ] && gap=$WM_GAP
    while [ $try -lt 3 ]; do
        try=$((try + 1))
        pace "$fam" "$gap"
        t0=$EPOCHREALTIME
        code=$(curl -q -sS -L --compressed --max-time 20 -A "$UA" -D "$TMP/hdr" -o "$dest" -w '%{http_code}' "$@" "$url")
        t1=$EPOCHREALTIME
        LAST[$fam]=$t1
        NREQ=$((NREQ + 1))
        if [ "$code" = 429 ]; then
            ra=$(grep -i '^retry-after' "$TMP/hdr" | tail -1 | tr -dc 0-9); ra=${ra:-30}
            printf '{"atRequest":%d,"sinceStartS":%s,"host":"%s","retryAfterS":%s,"try":%d}\n' \
                "$NREQ" "$(awk -v a="$t1" -v b="$START_MS" 'BEGIN{printf "%.1f", a-b/1000}')" "$fam" "$ra" "$try" >> "$TMP/ratelimits.jsonl"
            if [ ! -e "$OUT/wikipedia/ratelimited_429.txt" ]; then
                # headers minus the client's own address, its GeoIP cookie and the reporting endpoints
                { grep -viE '^(x-client-ip|set-cookie|report-to|nel|x-request-id|server-timing):' "$TMP/hdr"; cat "$dest"; } > "$OUT/wikipedia/ratelimited_429.txt"
            fi
            echo "  429 from $fam (Retry-After $ra s), waiting" >&2
            sleep $((ra + 1))
            continue
        fi
        break
    done
    python3 - "$dest" "$code" "$TMP/hdr" "$t0" "$t1" "$try" "$url" "$OUT" >> "$TMP/requests.jsonl" <<'PY'
import json, os, sys
dest, code, hdr, t0, t1, tries, url, out = sys.argv[1:9]
last = open(hdr, errors='replace', newline='').read().split('\r\n\r\n')
blocks = [b for b in last if b.strip()]
h = {}
for line in (blocks[-1].split('\r\n') if blocks else []):
    if ':' in line:
        k, v = line.split(':', 1); h[k.strip().lower()] = v.strip()
print(json.dumps({'file': os.path.relpath(dest, out) if dest.startswith(out + '/') else None, 'url': url, 'code': int(code), 'bytes': os.path.getsize(dest) if os.path.exists(dest) else 0,
                  'ms': int((float(t1) - float(t0)) * 1000), 'tries': int(tries),
                  'contentType': h.get('content-type'), 'cacheControl': h.get('cache-control'),
                  'retryAfter': h.get('retry-after'), 'rateHeaders': {k: v for k, v in h.items() if 'ratelimit' in k or k.startswith('x-envoy')}}))
PY
}

# get <file> <url> [curl args] : fetch into $OUT/<file> and add a urls.tsv row
get() {
    local f="$1" url="$2"; shift 2
    fetch "$OUT/$f" "$url" "$@"
    printf '%s\t%s\t%s\n' "$f" "$code" "$url" >> "$OUT/urls.tsv"
    printf '%-58s %s  %s B\n' "$f" "$code" "$(wc -c < "$OUT/$f")"
    case "$code" in 200) ;; *) fails=$((fails + 1)) ;; esac
}
# alias <file> <url> : a second URL for the same answer -> one more row on <file>, or <file>.alt if it differs.
# "Same" = identical bytes, or, for JSON, the same set of key paths: the feed's two hosts serve the same service, but
# a request a few seconds apart carries other revision ids, "tid" uuids and Parsoid ids (live pages are edited between).
alias_of() {
    local f="$1" url="$2" same
    fetch "$TMP/alias" "$url"
    same=$(python3 - "$TMP/alias" "$OUT/$f" <<'PY'
import json, sys
def paths(o, p=''):
    s = set()
    if isinstance(o, dict):
        for k, v in o.items(): s |= {p + '/' + k} | paths(v, p + '/' + k)
    elif isinstance(o, list):
        for v in o: s |= paths(v, p + '[]')
    return s
a, b = open(sys.argv[1], 'rb').read(), open(sys.argv[2], 'rb').read()
if a == b: print('bytes')
else:
    try: print('keys' if paths(json.loads(a)) == paths(json.loads(b)) else '')
    except ValueError: print('')
PY
)
    if [ "$code" = 200 ] && [ -n "$same" ]; then
        printf '%s\t%s\t%s\n' "$f" "$code" "$url" >> "$OUT/urls.tsv"; echo "alias same ($same): $url"
    else
        cp "$TMP/alias" "$OUT/$f.alt"; printf '%s.alt\t%s\t%s\n' "$f" "$code" "$url" >> "$OUT/urls.tsv"
        echo "alias DIFFERS ($code): $url -> $f.alt"
    fi
}

# ---------------------------------------------------------------------------------------------
python3 -c "import json,sys; print(json.dumps({'capturedAtMs': $START_MS}))" > "$OUT/captured.json"
TODAY=$(date -u +%Y-%m-%d); Y=${TODAY:0:4}; M=${TODAY:5:2}; D=${TODAY:8:2}
YESTERDAY=$(date -u -d yesterday +%Y%m%d); PV_START=$(date -u -d '60 days ago' +%Y%m%d)

echo "== 1. Wikipedia: CirrusSearch, random Good / Featured articles by topic"
GA='articletopic:physics hastemplate:"Good article"'
FA='articletopic:physics hastemplate:"Featured article"'
SEARCH=(action=query list=search srsort=random srlimit=10 srnamespace=0 format=json formatversion=2)
get wikipedia/search_random_ga_physics.json          "$(mkurl $WP "${SEARCH[@]}" "srsearch=$GA")"
get wikipedia/search_random_fa_physics.json          "$(mkurl $WP "${SEARCH[@]}" "srsearch=$FA")"
get wikipedia/search_random_ga_physics_maxlag5.json  "$(mkurl $WP "${SEARCH[@]}" maxlag=5 "srsearch=$GA")"
# several topics of one family: articletopic:a|b|c is an OR
get wikipedia/search_random_ga_topics_or.json        "$(mkurl $WP "${SEARCH[@]}" 'srsearch=articletopic:physics|chemistry|mathematics hastemplate:"Good article"')"
# relevance order, nothing but the defaults (srqiprofile, srwhat, srsort): what the plain query answers
get wikipedia/search_defaults_ga_physics.json        "$(mkurl $WP action=query list=search srsearch="$GA" srlimit=5 srnamespace=0 srinfo=totalhits format=json formatversion=2)"
# computing, the far side. Two articletopic: keywords are an AND, so an intersection keeps the far side; a bare keyword
# ("history") is only a text match and leaks the near side (Rust, Trie, ...); a negation thins the near side but leaks too;
# deepcat: is not usable on enwiki (matches unrelated pages); one query cannot yet answer "Good OR Featured" (0 hits).
CS='articletopic:computing'
get wikipedia/search_random_ga_computing_x_history.json     "$(mkurl $WP "${SEARCH[@]}" "srsearch=$CS articletopic:history hastemplate:\"Good article\"")"
get wikipedia/search_random_fa_computing_x_history.json     "$(mkurl $WP "${SEARCH[@]}" "srsearch=$CS articletopic:history hastemplate:\"Featured article\"")"
get wikipedia/search_random_ga_computing_x_mathematics.json "$(mkurl $WP "${SEARCH[@]}" "srsearch=$CS articletopic:mathematics hastemplate:\"Good article\"")"
get wikipedia/search_random_ga_computing_x_biography.json   "$(mkurl $WP "${SEARCH[@]}" "srsearch=$CS articletopic:biography hastemplate:\"Good article\"")"
get wikipedia/search_random_ga_computing_minus_software.json "$(mkurl $WP "${SEARCH[@]}" "srsearch=$CS -articletopic:software -articletopic:internet-culture hastemplate:\"Good article\"")"
get wikipedia/search_random_ga_computing_keyword_history.json "$(mkurl $WP "${SEARCH[@]}" "srsearch=$CS history hastemplate:\"Good article\"")"
get wikipedia/search_random_ga_deepcat_history_of_computing.json "$(mkurl $WP "${SEARCH[@]}" 'srsearch=deepcat:"History of computing" hastemplate:"Good article"')"
get wikipedia/search_random_ga_or_fa_physics_zero_hits.json "$(mkurl $WP "${SEARCH[@]}" 'srsearch=articletopic:physics (hastemplate:"Good article" OR hastemplate:"Featured article")')"
# the valid articletopic: values (a flat list of the ORES taxonomy, no second level)
get wikipedia/articletopic_valid_values.txt "https://www.mediawiki.org/w/index.php?title=Help:CirrusSearch/articletopic&action=raw"
# one call for the candidates' page data: extract, images, url, Wikidata id
get wikipedia/gensearch_random_ga_physics_5.json     "$(mkurl $WP action=query generator=search "gsrsearch=$GA" gsrsort=random gsrlimit=5 gsrnamespace=0 \
    'prop=pageimages|extracts|info|pageprops' exintro=1 explaintext=1 'piprop=thumbnail|name|original' pithumbsize=960 inprop=url ppprop=wikibase_item \
    format=json formatversion=2)"
# quality of arbitrary titles (a followed link): categories, one call for the whole batch
get wikipedia/quality_categories_batch.json          "$(mkurl $WP action=query 'titles=Johann Sebastian Bach|Leonhard Euler|Marie Curie|Black hole|Hilde Levi|Ludwig van Beethoven|Mount Everest' \
    prop=categories 'clcategories=Category:Featured articles|Category:Good articles' cllimit=max format=json formatversion=2)"

echo "== 2. Wikipedia: lead section as HTML with links, plaintext lead"
PARSE=(action=parse prop='text|revid|displaytitle' section=0 format=json formatversion=2 disableeditsection=1 disabletoc=1 disablelimitreport=1 redirects=1)
for t in Johann_Sebastian_Bach Leonhard_Euler Black_hole Hilde_Levi; do
    get "wikipedia/parse_lead_$t.json" "$(mkurl $WP "${PARSE[@]}" "page=$t")"
done
get wikipedia/extracts_intro_plain_batch.json "$(mkurl $WP action=query 'titles=Johann Sebastian Bach|Leonhard Euler|Black hole|Hilde Levi' prop=extracts exintro=1 explaintext=1 exlimit=max redirects=1 format=json formatversion=2)"

echo "== 3. Images of an article, imageinfo + extmetadata, one thumb, media-list"
get wikipedia/images_Black_hole.json "$(mkurl $WP action=query titles='Black hole' prop=images imlimit=max format=json formatversion=2)"
FILES=$(python3 - "$OUT/wikipedia/images_Black_hole.json" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
t = [i['title'] for i in d['query']['pages'][0].get('images', [])]
ok = [x for x in t if re.search(r'\.(jpe?g|png)$', x, re.I) and not re.search(r'logo|icon|ambox|symbol|question|edit|commons-|wiki|portal|flag|cscr', x, re.I)]
print('|'.join(ok[:3] or t[:3]))
PY
)
echo "  files: $FILES"
get wikipedia/imageinfo_Black_hole_3.json "$(mkurl $WP action=query "titles=$FILES" prop=imageinfo 'iiprop=url|size|mime|extmetadata' iiurlwidth=960 \
    'iiextmetadatafilter=Artist|LicenseShortName|LicenseUrl|UsageTerms|ImageDescription|Credit|Attribution|Copyrighted|ObjectName|DateTimeOriginal' format=json formatversion=2)"
THUMB=$(python3 - "$OUT/wikipedia/imageinfo_Black_hole_3.json" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
for p in d['query']['pages']:
    for ii in p.get('imageinfo', []):
        if ii.get('mime') == 'image/jpeg' and '/thumb/' in ii.get('thumburl', ''):
            print(p['title'].replace('File:', '', 1) + '\t' + ii['thumburl']); raise SystemExit
for p in d['query']['pages']:      # none was scaled: any JPEG (its thumburl is then the original)
    for ii in p.get('imageinfo', []):
        if ii.get('mime') == 'image/jpeg' and ii.get('thumburl'):
            print(p['title'].replace('File:', '', 1) + '\t' + ii['thumburl']); raise SystemExit
PY
)
name=$(slug "${THUMB%%$'\t'*}"); THUMB="${THUMB#*$'\t'}"
if [ -n "$THUMB" ]; then
    fetch "$TMP/thumb" "$THUMB"
    if [ "$code" = 200 ] && [ "$(wc -c < "$TMP/thumb")" -gt 204800 ]; then   # over 200 KB: the 500 px step of the same file
        THUMB=$(echo "$THUMB" | sed 's#/[0-9]*px-#/500px-#')
        fetch "$TMP/thumb" "$THUMB"; name="500px_$name"
    fi
    cp "$TMP/thumb" "$OUT/commons/thumb_$name"
    printf 'commons/thumb_%s\t%s\t%s\n' "$name" "$code" "$THUMB" >> "$OUT/urls.tsv"
    printf '%-58s %s  %s B\n' "commons/thumb_$name" "$code" "$(wc -c < "$OUT/commons/thumb_$name")"
    [ "$code" = 200 ] || fails=$((fails + 1))
else echo "  no JPEG thumburl in imageinfo"; fails=$((fails + 1)); fi
get wikipedia/rest_media_list_Black_hole.json "https://en.wikipedia.org/api/rest_v1/page/media-list/Black_hole"

echo "== 4. Pageviews"
get pageviews/rest_per_article_Black_hole_daily.json "https://wikimedia.org/api/rest_v1/metrics/pageviews/per-article/en.wikipedia.org/all-access/user/Black_hole/daily/$PV_START/$YESTERDAY"
get pageviews/pageviewinfo_batch.json "$(mkurl $WP action=query 'titles=Black hole|Leonhard Euler|Marie Curie|Hilde Levi' prop=pageviews pvipdays=60 format=json formatversion=2)"

echo "== 5. Featured feed (tfa, mostread, image = picture of the day, onthisday) and on this day"
get feed/featured_$Y-$M-$D.json "https://api.wikimedia.org/feed/v1/wikipedia/en/featured/$Y/$M/$D"
alias_of feed/featured_$Y-$M-$D.json "https://en.wikipedia.org/api/rest_v1/feed/featured/$Y/$M/$D"
get feed/onthisday_events_$M-$D.json "https://api.wikimedia.org/feed/v1/wikipedia/en/onthisday/events/$M/$D"

echo "== 10. Wikidata logo (P154) and the Commons file"
get wikidata/enwiki_pageprops_wikibase_item.json "$(mkurl $WP action=query 'titles=Systemd|Z shell|Arch Linux|Pacman (package manager)' prop=pageprops ppprop=wikibase_item redirects=1 format=json formatversion=2)"
QID=$(jget "$OUT/wikidata/enwiki_pageprops_wikibase_item.json" "[p['pageprops']['wikibase_item'] for p in d['query']['pages'] if p['title']=='Systemd'][0]")
echo "  Systemd = $QID"
get wikidata/wbgetclaims_${QID}_P154.json "$(mkurl $WD action=wbgetclaims entity=$QID property=P154 format=json)"
LOGO=$(jget "$OUT/wikidata/wbgetclaims_${QID}_P154.json" "d['claims']['P154'][0]['mainsnak']['datavalue']['value']")
echo "  logo file: $LOGO"
get commons/imageinfo_logo.json "$(mkurl $COMMONS action=query "titles=File:$LOGO" prop=imageinfo 'iiprop=url|size|mime|extmetadata' \
    'iiextmetadatafilter=Artist|LicenseShortName|LicenseUrl|UsageTerms|ImageDescription|Credit|Copyrighted|ObjectName' format=json formatversion=2)"
SVG=$(jget "$OUT/commons/imageinfo_logo.json" "d['query']['pages'][0]['imageinfo'][0]['url']")
get "wikidata/$(slug "$LOGO")" "$SVG"
alias_of "wikidata/$(slug "$LOGO")" "https://commons.wikimedia.org/wiki/Special:FilePath/$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$LOGO")"

echo "== 6. Arch wiki: English-title index, leads, a tips section, wikitext, random"
mkdir -p "$TMP/arch"
cont=""; n=0
while :; do
    n=$((n + 1)); pf=$(printf 'allpages_p%02d.json' $n)
    if [ -z "$cont" ]; then
        url=$(mkurl $ARCH action=query list=allpages apnamespace=0 apfilterredir=nonredirects aplimit=max format=json formatversion=2)
        get "arch/$pf" "$url"; src="$OUT/arch/$pf"
    else
        url=$(mkurl $ARCH action=query list=allpages apnamespace=0 apfilterredir=nonredirects aplimit=max format=json formatversion=2 "apcontinue=$cont")
        fetch "$TMP/arch/$pf" "$url"; src="$TMP/arch/$pf"; printf '%-58s %s\n' "(arch index page $n)" "$code"
    fi
    printf '%s\t%s\t%s\n' "$pf" "$code" "$url" >> "$TMP/arch/pages.tsv"
    [ "$code" = 200 ] || { fails=$((fails + 1)); break; }
    cont=$(jget "$src" "d.get('continue',{}).get('apcontinue','')")
    [ -z "$cont" ] && break
    [ $n -ge 60 ] && { echo "  arch index: stopping at 60 pages"; fails=$((fails + 1)); break; }
done
python3 - "$OUT" "$TMP/arch" <<'PY'
import glob, json, os, re, sys, collections
out, tmp = sys.argv[1], sys.argv[2]
# the Arch wiki's own translation suffixes (its interlanguage targets that live IN the wiki; de, ja, zh-hans, ...
# are external wikis and have no pages here)
LANGS = {"Русский", "Español", "Português", "Magyar", "Français", "Polski", "Italiano", "Türkçe", "Українська", "Čeština", "Suomi",
         "العربية", "فارسی", "हिन्दी", "正體中文", "简体中文", "Bosanski", "Català", "한국어", "Lietuvių", "Lietuviškai", "Ελληνικά",
         "Latviešu", "Bahasa Indonesia", "Svenska", "עברית", "Српски", "Slovenščina", "粵語", "Română", "বাংলা", "文言文", "Dansk",
         "Slovenčina", "Български", "ไทย", "Nederlands", "Qhichwa", "Hrvatski", "Esperanto", "Norsk Bokmål", "Deutsch", "日本語", "Tiếng Việt"}
pages = []
for pf, code, url in (l.rstrip('\n').split('\t') for l in open(os.path.join(tmp, 'pages.tsv'))):
    p = os.path.join(out, 'arch', pf) if pf == 'allpages_p01.json' else os.path.join(tmp, pf)
    d = json.load(open(p))
    pages.append({'file': pf, 'url': url, 'n': len(d['query']['allpages']), 'continue': d.get('continue'), 'limits': d.get('limits')})
titles = []
for pg in pages:
    p = os.path.join(out, 'arch', pg['file']) if pg['file'] == 'allpages_p01.json' else os.path.join(tmp, pg['file'])
    titles += [x['title'] for x in json.load(open(p))['query']['allpages']]
suf = collections.Counter(); trans = []
for t in titles:
    m = re.search(r' \(([^()]+)\)$', t)
    if m:
        suf[m.group(1)] += 1
en = [t for t in titles if not ((m := re.search(r' \(([^()]+)\)$', t)) and m.group(1) in LANGS)]
json.dump({'v': 1, 'source': 'list=allpages apnamespace=0 apfilterredir=nonredirects', 'total': len(titles), 'english': len(en),
           'translations': len(titles) - len(en), 'duplicates': len(titles) - len(set(titles)), 'titles': sorted(set(en))},
          open(os.path.join(out, 'arch/titles_en.json'), 'w'), ensure_ascii=False, separators=(',', ':'))
json.dump({'pages': len(pages), 'perPage': [pg['n'] for pg in pages], 'lastContinue': [pg['continue'] for pg in pages],
           'requests': [{'url': pg['url'], 'n': pg['n']} for pg in pages], 'total': len(titles), 'english': len(en)},
          open(os.path.join(out, 'arch/index_summary.json'), 'w'), ensure_ascii=False, indent=1)
json.dump({'note': 'parenthetical suffix -> count; language=true means a translation of the page without it',
           'suffixes': {k: {'count': v, 'language': k in LANGS} for k, v in suf.most_common()}},
          open(os.path.join(out, 'arch/title_suffix_counts.json'), 'w'), ensure_ascii=False, indent=1)
print('  arch: %d pages of titles, %d total, %d english, %d translations' % (len(pages), len(titles), len(en), len(titles) - len(en)))
PY
get arch/random_10.json "$(mkurl $ARCH action=query list=random rnnamespace=0 rnlimit=10 format=json formatversion=2)"
get arch/info_pagelanguage.json "$(mkurl $ARCH action=query 'titles=Systemd|Systemd (Español)|Bottles (Русский)|Laptop' prop=info inprop=url format=json formatversion=2)"
HW=$(python3 - "$OUT/arch/titles_en.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))['titles']
for want in ('Lenovo ThinkPad T14 (AMD) Gen 3', 'Lenovo ThinkPad X1 Carbon (Gen 9)'):
    if want in t: print(want); raise SystemExit
print(next((x for x in t if x.startswith('Lenovo ThinkPad')), 'Laptop'))
PY
)
echo "  hardware page: $HW"
APARSE=(action=parse prop='text|revid|displaytitle' section=0 format=json formatversion=2 disableeditsection=1 disabletoc=1 disablelimitreport=1 redirects=1)
for t in Systemd Nginx "Uncomplicated Firewall" "$HW"; do
    get "arch/lead_$(slug "$t").json" "$(mkurl $ARCH "${APARSE[@]}" "page=$t")"
done
get arch/sections_Zsh.json "$(mkurl $ARCH action=parse page=Zsh prop=sections format=json formatversion=2)"
TIPS=$(jget "$OUT/arch/sections_Zsh.json" "[s['index'] for s in d['parse']['sections'] if s['line']=='Tips and tricks' and s['level']=='2'][0]")
INST=$(jget "$OUT/arch/sections_Zsh.json" "[s['index'] for s in d['parse']['sections'] if s['line']=='Installation' and s['level']=='2'][0]")
echo "  Zsh: Tips and tricks = section $TIPS, Installation = section $INST"
get "arch/section_Zsh_${TIPS}_tips_and_tricks.json" "$(mkurl $ARCH action=parse page=Zsh section=$TIPS prop='text|revid|displaytitle' format=json formatversion=2 disableeditsection=1 disabletoc=1 disablelimitreport=1)"
get arch/wikitext_Systemd_section0.json "$(mkurl $ARCH action=parse page=Systemd section=0 prop=wikitext format=json formatversion=2)"
get "arch/wikitext_Zsh_section${INST}_installation.json" "$(mkurl $ARCH action=parse page=Zsh section=$INST prop=wikitext format=json formatversion=2)"

echo "== 7. Gentoo wiki"
get gentoo/lead_Portage.json "$(mkurl $GENTOO "${APARSE[@]}" page=Portage)"
get gentoo/lead_Zsh.json     "$(mkurl $GENTOO "${APARSE[@]}" page=Zsh)"
get gentoo/random_10.json    "$(mkurl $GENTOO action=query list=random rnnamespace=0 rnlimit=10 format=json formatversion=2)"

echo "== 8. docs.kernel.org"
get kernel/index.html                 "https://docs.kernel.org/"
get kernel/admin-guide_index.html     "https://docs.kernel.org/admin-guide/index.html"
get kernel/admin-guide_sysrq.html     "https://docs.kernel.org/admin-guide/sysrq.html"
get kernel/admin-guide_cgroup-v2.html "https://docs.kernel.org/admin-guide/cgroup-v2.html"
# the whole-manual enumeration: searchindex.js (~20 MB) is fetched, reduced to its doc names + titles, and NOT kept
fetch "$TMP/searchindex.js" "https://docs.kernel.org/searchindex.js" --max-time 120
python3 - "$TMP/searchindex.js" "$OUT/kernel" "$code" <<'PY'
import json, os, re, sys
src, out, code = sys.argv[1:4]
raw = open(src, encoding='utf-8').read()
m = re.match(r'\s*Search\.setIndex\((.*)\)\s*;?\s*$', raw, re.S)
d = json.loads(m.group(1))
strip = lambda s: re.sub(r'^\d+(\.\d+)*\.?\s+', '', re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', '', s)).strip())
rows = [(n, strip(t)) for n, t in zip(d['docnames'], d['titles']) if not n.startswith('translations/')]
json.dump({'v': 1, 'from': 'https://docs.kernel.org/searchindex.js', 'keys': sorted(d.keys()),
           'docnames': [r[0] for r in rows], 'titles': [r[1] for r in rows]},
          open(os.path.join(out, 'docnames.json'), 'w'), ensure_ascii=False, separators=(',', ':'))
json.dump({'url': 'https://docs.kernel.org/searchindex.js', 'httpCode': int(code), 'bytes': os.path.getsize(src), 'docnamesTotal': len(d['docnames']),
           'docnamesWithoutTranslations': len(rows), 'note': 'raw file not stored; docnames.json is derived from it'},
          open(os.path.join(out, 'searchindex.meta.json'), 'w'), indent=1)
print('  searchindex.js: %d bytes, %d docs (%d without translations)' % (os.path.getsize(src), len(d['docnames']), len(rows)))
PY

echo "== 9. freedesktop specifications"
get freedesktop/index.html                "https://specifications.freedesktop.org/"
get freedesktop/basedir_latest.html       "https://specifications.freedesktop.org/basedir/latest/"
get freedesktop/idle-inhibit_latest.html  "https://specifications.freedesktop.org/idle-inhibit/latest/"
get freedesktop/desktop-entry_latest_index.html "https://specifications.freedesktop.org/desktop-entry/latest/"

# ---------------------------------------------------------------------------------------------
python3 - "$OUT/captured.json" "$START_MS" "$NREQ" "$TMP" "$UA" <<'PY'
import json, sys, os
path, start, n, tmp, ua = sys.argv[1:6]
rows = [json.loads(l) for l in open(os.path.join(tmp, 'requests.jsonl'))]
lim = [json.loads(l) for l in open(os.path.join(tmp, 'ratelimits.jsonl'))]
json.dump({'capturedAtMs': int(start), 'userAgent': ua, 'requests': int(n),
           'rateLimited': lim, 'log': rows}, open(path, 'w'), ensure_ascii=False, indent=1)
PY
echo "CAPTURE DONE requests=$NREQ failures=$fails 429s=$(wc -l < "$TMP/ratelimits.jsonl")"
