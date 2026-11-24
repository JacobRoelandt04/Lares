# Wiki module — live API notes (stage 0A)

(The gates, probes and fixtures this contract names without a directory went with the cleanup: tag `pre-cleanup` has them. What a change is proved with now is in `tools/dev/`, [tools.md](../tools.md).)

Captured 2026-09-30 by `tools/wiki/capture_fixtures.sh` into `fixtures/wiki/`: 66 requests, 0 failures,
0 rate limits, 71 s. `urls.tsv` is `file<TAB>http_code<TAB>url` (57 rows on 55 files: the two feed URLs share
one file, and so do the two logo URLs). `captured.json` holds `capturedAtMs`, the User-Agent, and one row per
request (`url`, `code`, `bytes`, `ms`, `contentType`, `cacheControl`, `rateHeaders`). Files that are derived,
not raw, are not in `urls.tsv`: `arch/titles_en.json`, `arch/index_summary.json`,
`arch/title_suffix_counts.json`, `kernel/docnames.json`, `kernel/searchindex.meta.json`, and
`wikipedia/ratelimited_429.txt`.

"[explored]" marks a fact seen in an exploratory request during this stage that is not a fixture.
Everything else is in a fixture and was read from it.

## Read this first (these change the plan or the contract)

1. **The contract's User-Agent gets rate limited to 10 requests/min. Use a full URL or an email as contact.**
   - `quickshell-wiki/0.1 (+github.com/<user>)` (no scheme) is treated as "unidentified" [explored, two full
     captures and a control run]: 429 with `Retry-After` 31-50 s (once 10 s) after 6-14 requests in a row. A
     61-request capture under it met four 429s and took 4 min 52 s; a 70-request one met four more.
     Sustained: ~10 requests/min.
   - `quickshell-wiki/0.1 (https://github.com/JacobRoelandt04/Lares)` [explored]: 30 of 30 requests at ~0.45 s
     spacing all 200. The same request with the old UA gave 200 x14, then 429 at the 15th and 18th.
   - `mediawiki.org/wiki/Wikimedia_APIs/Rate_limits` [explored] says: unidentified (no identifying
     characteristics beyond IP) 10/min; "unauthenticated bot requests with a compliant User-Agent" 200/min;
     "compliant" = "contact information such as an email or full URL". Concurrent requests: 3 or fewer.
     The limits are "new in 2026 and subject to change".
   - The full capture (66 requests, 35 of them to Wikimedia hosts) ran in 71 s at 0.7 s spacing, with
     the compliant UA and no 429. `wiki.md` (the contract) still says the old UA (line 151); the plan's "200 req/min"
     only holds for the compliant one. The Arch, Gentoo, kernel and freedesktop hosts never limited.
   - A 429 is `text/plain`, header `x-envoy-ratelimited: true`, `Retry-After` in seconds (31-50, once 10). Body: "You are making too many requests to the API." See `wikipedia/ratelimited_429.txt`
     (headers sanitised: client IP, cookies, reporting endpoints removed). The docs say: with no
     `Retry-After`, wait at least 5 s or back off exponentially.
   - `upload.wikimedia.org` / `thumb.wikimedia.org` answered with `x-ratelimit-limit: 600000, 600000;w=60`.
     `api.php`, the REST endpoints and the feed carry no rate headers on a 200.
2. **`articletopic:` is a flat list of 64 values, not a two-level tree** (`articletopic_valid_values.txt`).
   - `a|b|c` is an OR, and two separate `articletopic:` keywords are an AND (docs; and the fixtures:
     computing AND mathematics answers 8).
   - So the plan's "fine topic is the second level" means one of the 64 values inside a family. Values
     include `computing`, `software`, `internet-culture`, `history`, `military-and-warfare`, `stem`,
     `technology`, `libraries-and-information`, `video-games`, `women`, and the regions.
3. **The far side of computing cannot be got by a keyword or a negation. Intersect two topics.**
   - `articletopic:computing history hastemplate:"Good article"` gives 112 hits and the sample is Binary
     search tree, Windows 8.1, Windows 3.0, Red team: "history" is only a text match.
   - `articletopic:computing -articletopic:software -articletopic:internet-culture` gives 73 and still
     samples Qualcomm Snapdragon, DOSBox, Digital forensics.
   - `articletopic:computing articletopic:X hastemplate:"Good article"`: history 1 (Jean Bartik),
     mathematics 8 (X + Y sorting, Widest path problem, BIT predicate, Yao's principle, ...),
     biography 6 (Richard Hamming, Tom Kilburn, Jean Bartik, Douglas Engelbart, Ronald Fedkiw,
     Nicholas Carlini). Featured x history: 0.
   - The intersections are small (about 15 Good articles), so the far side needs the plan's title allow/deny
     post-filter as well, and the computing share is a handful of articles, not a pool.
   - `deepcat:"History of computing"` is unusable: 2696 hits, all video games. `incategory:"History of
     computing"` works but is direct members only (2: Bill Gates, History of computing in the Soviet
     Union) [explored].
4. **Good OR Featured in one query returned 0 hits in every form tried.** `(hastemplate:"Good article" OR
   hastemplate:"Featured article")` is the fixture (`..._or_fa_physics_zero_hits.json`); `hastemplate:"A"|"B"`,
   `incategory:"Good articles"|"Featured articles"` and `(incategory:.. OR incategory:..)` also gave 0
   [explored]. Run one query per quality (physics: Good 97, Featured 28) and pick the quality first.
5. **Arch: 4363 titles in namespace 0 without redirects, 2161 English, 2202 translations (50.5 %).** Nine
   `list=allpages` requests of 500. Details in section 6.
6. **A "first `<p>`" locator is wrong on the Arch wiki.** The real intro of Systemd and Uncomplicated
   Firewall is a `<dl><dd>` quote, introduced by a `<p>` ending in ":" ("From the project web page:"), after a
   "Related articles" box. On Wikipedia the first `<p>` is an empty `<p class="mw-empty-elt">`.
7. **Pageviews:** the batch `prop=pageviews` on enwiki works and matches the REST per-article numbers
   day for day (59 of 59 non-null days identical), 4 titles per request. Its last day (yesterday) is
   `null`; the REST endpoint already had it.
8. **Wikipedia's featured feed works on both hosts.** `api.wikimedia.org/feed/v1/...` and
   `en.wikipedia.org/api/rest_v1/feed/featured/...` answer with the same 223 key paths and the same tfa,
   image and mostread (bytes differ by random `tid` and Parsoid `id="mw.."` values and live revision ids).
   Neither is marked deprecated. It is 380 KB.

## Conventions that held for every MediaWiki call

- `format=json&formatversion=2` everywhere: booleans are real, `pages` is an array (formatversion 1 keys it by
  pageid). Errors would come as `{"error":..}`; none met.
- `maxlag=5` appended to a search is accepted and changes nothing in the answer
  (`search_random_ga_physics_maxlag5.json`).
- Responses are gzip (Wikimedia) or brotli (Arch); `curl --compressed`.
- `api.php` answers: `cache-control: private, must-revalidate, max-age=0`, `content-type: application/json;
  charset=utf-8`. Timings: search 0.27-0.55 s, `action=parse` of a lead 0.3-1.75 s (Euler 1.75), first feed
  request 4.2 s, then 0.14-0.17 s.
- Cached endpoints: REST pageviews `s-maxage=14400`, feed `s-maxage=300, max-age=60`, media-list
  `s-maxage=1209600`, freedesktop `max-age=600`.
- Titles in `titles=` are separated by `|` and encoded `%7C`; `mkurl` in the script encodes every value with
  `%20` for space (so `urls.tsv` URLs are canonical: the stub can match them as strings).
- A random `srsort` search answers a `continue: {sroffset: N, continue: "-||"}`. Whether a second page of a
  random order continues the same order was not tested; fetch fresh and dedupe.

## 1. CirrusSearch: random quality articles by topic

URL template (`https://en.wikipedia.org/w/api.php`):

    action=query&list=search&srsearch=<q>&srsort=random&srlimit=10&srnamespace=0&format=json&formatversion=2
    q = articletopic:physics hastemplate:"Good article"        (or "Featured article")

Fixtures and what they answer:

| file | `totalhits` | note |
|---|---|---|
| `search_random_ga_physics.json` | 97 | 10 hits |
| `search_random_fa_physics.json` | 28 | `hastemplate:"Featured article"` is the right template; `incategory:"Featured articles"` gave the same 28 [explored] |
| `search_random_ga_topics_or.json` | 417 | `articletopic:physics\|chemistry\|mathematics` (a family as an OR) |
| `search_defaults_ga_physics.json` | 97 | no `srsort`, no `srqiprofile`, no `srwhat`: relevance order (Albert Einstein, Marie Curie, Quantum mechanics, Universe, Kilogram). `srwhat=text` and `srqiprofile=classic` gave the same 97 hits [explored] |
| `search_random_ga_computing_*` | 1 / 0 / 8 / 6 / 73 / 112 | see "read this first" 3 |
| `search_random_ga_deepcat_history_of_computing.json` | 2696 | a trap: video games |
| `search_random_ga_or_fa_physics_zero_hits.json` | 0 | a trap: no error, no warning, `search: []` |

JSON paths: `query.searchinfo.totalhits`; `query.search[].{title,pageid,ns,size,wordcount,timestamp,snippet}`;
`continue.sroffset`. `snippet` is HTML-escaped plain text (`&quot;`), not markup. An empty result is
`{"batchcomplete":true,"query":{"searchinfo":{"totalhits":0},"search":[]}}` (73 bytes), no `continue`.

`GET ... generator=search` for the page data in one call (`gensearch_random_ga_physics_5.json`):

    action=query&generator=search&gsrsearch=<q>&gsrsort=random&gsrlimit=5&gsrnamespace=0
      &prop=pageimages|extracts|info|pageprops&exintro=1&explaintext=1&piprop=thumbnail|name|original
      &pithumbsize=960&inprop=url&ppprop=wikibase_item&format=json&formatversion=2

- **`extracts` works with a generator for more than one page.** All 5 pages carried `extract` without an
  `exlimit`; the batch fixture shows `limits: {extracts: 20}` (the cap with `exintro`).
- `query.pages` is **not in rank order**: read `pages[].index` (1-based rank) and sort by it.
- Per page: `pageid,title,index,extract,fullurl,canonicalurl,length,lastrevid,touched,pagelanguage,
  pageprops.wikibase_item,pageimage (file name),thumbnail.{source,width,height},original.{source,width,height}`.
  A page with no lead image has neither `thumbnail` nor `original` nor `pageimage`.
- `thumbnail.width` is the smaller of 960 and the original (485 stays 485), so `thumbnail.source` is then
  the original file (`utm_content=thumbnail_unscaled` on `upload.wikimedia.org`).
- `continue: {gsroffset: 5, continue: "gsroffset||"}`.

Quality of arbitrary titles, for a followed link (`quality_categories_batch.json`):

    action=query&titles=A|B|C&prop=categories&clcategories=Category:Featured articles|Category:Good articles&cllimit=max

One request for the batch; `pages[].categories[].title` is `Category:Featured articles` or
`Category:Good articles`, absent for neither (Ludwig van Beethoven and Mount Everest: none; Black hole,
Leonhard Euler: Featured; Bach, Marie Curie, Hilde Levi: Good).

## 2. Lead section with links; plaintext lead

Template (`parse_lead_<Title>.json`, four articles: Bach (Good), Euler (Featured), Black hole (Featured),
Hilde Levi (Good, short)):

    action=parse&page=<Title>&prop=text|revid|displaytitle&section=0&format=json&formatversion=2
      &disableeditsection=1&disabletoc=1&disablelimitreport=1&redirects=1

- Paths: `parse.text` (HTML string), `parse.revid`, `parse.title`, `parse.pageid`, `parse.displaytitle`
  (HTML span), `parse.redirects` (list; `[]` here). 9-43 KB of JSON for a lead.
- `disablelimitreport=1` drops the `<!-- NewPP limit report -->` comment; no `<!-- -->` remained except
  `<!-- π -->` in Euler.
- **What comes before the lead paragraph, in order:** `div.shortdescription`, `div.hatnote` (Bach, Euler,
  Black hole), `<p class="mw-empty-elt">` (empty, in all four), `table.infobox` (Bach, Euler, Hilde Levi), then
  the paragraph that starts `<p><b>Title</b>`. Take the first `<p>` that has text.
- Clutter in Bach: `<sup class="reference">` footnote marks ("n 1"), a date span `<span class="nowrap">31
  March</span> [<a>O.S.</a> 21 March] 1685 – 28 July 1750`, 17 links in the first paragraph.
  Euler: an IPA block `span.IPA` (with a `Help:IPA/English` link), a respelling `<i title="English
  pronunciation respelling">OY-lər</i>` linked to `Help:Pronunciation_respelling_key`, four `sup.reference`
  and MathJax spans in later paragraphs. Hilde Levi: dates in parentheses with `&#160;–`.
- Links: internal `href="/wiki/Title"` (relative, no host), `class="mw-redirect"` for redirects,
  **`class="new"` for red links (Hilde Levi has 2): drop them**, `class="external text"`/`extiw` for
  outside links, `href="#cite_note-.."` for footnotes.

Plaintext lead, one call for a batch (`extracts_intro_plain_batch.json`):

    action=query&titles=A|B|C|D&prop=extracts&exintro=1&explaintext=1&exlimit=max&redirects=1&format=json&formatversion=2

- Path `query.pages[].extract`; `limits.extracts` is 20. Whole lead, paragraphs separated by `\n`,
  1.8-3.9 KB.
- It removes IPA but **leaves the pronunciation respelling and the date parenthesis**: Euler comes back as
  "Leonhard Euler ( OY-lər; 15 April 1707 – 18 September 1783) was ..." (note the space after "("). The
  cleanup pass is still needed. Footnote marks and `[n 1]` are gone.

## 3. Images, imageinfo, thumbnail

- `images_Black_hole.json` (`prop=images&imlimit=max`): 39 files in **alphabetical** order, mixing photos
  with icons and media (`Commons-logo.svg`, `Cscr-featured.svg`, `OOjs UI icon edit-ltr-progressive.svg`,
  `Semi-protection-shackle.svg`, `.ogg`, `.webm`, `.tif`). Not usable to choose a hero without a filter.
- **`wikipedia/rest_media_list_Black_hole.json`** (`https://en.wikipedia.org/api/rest_v1/page/media-list/Black_hole`)
  is better and is **not deprecated** (200, profile `MediaList/1.1.0`): 45 items in page order, 40 `image` +
  5 `video`. `items[].{title (null when it is not a File), leadImage (true on the lead), section_id, type,
  showInGallery, caption.{html,text}, srcset[].{src,scale}}`. `showInGallery` is false for the 18
  icon-like items. `srcset[].src` is protocol-relative (`//thumb.wikimedia.org/...500px-...`). Use
  `type=="image" && showInGallery && title`.
- `imageinfo_Black_hole_3.json`:

      action=query&titles=File:A|File:B|File:C&prop=imageinfo&iiprop=url|size|mime|extmetadata&iiurlwidth=960
        &iiextmetadatafilter=Artist|LicenseShortName|LicenseUrl|UsageTerms|ImageDescription|Credit|Attribution
        |Copyrighted|ObjectName|DateTimeOriginal&format=json&formatversion=2

  Paths: `query.pages[].imageinfo[0].{url,thumburl,thumbwidth,thumbheight,width,height,size,mime,
  descriptionurl,extmetadata.<Key>.value}`. Gotchas:
  - `extmetadata.*.value` are HTML strings: `Artist` may be `<a href="//commons.wikimedia.org/wiki/User:..">`
    (protocol-relative) or plain text; `Credit` may be a whole `<table>`; `LicenseShortName` ("CC BY-SA 4.0",
    "Public domain") is plain; `Copyrighted` is the string "True"/"False".
  - **`thumbwidth`/`thumbheight` echo the request (960) even when the file is smaller.** BH-JPL-A&A1979.jpg
    is 700x346 (186,579 B) yet reports thumbwidth 960 thumbheight 475, and its `thumburl` is the original
    (`.../commons/2/26/...jpg?...thumbnail_unscaled`). Trust `width`/`height`, or `/thumb/` in `thumburl`.
  - `BH LMC.png`: `size` 9,362,445 B, 2560x2048. Never fetch `url` for a hero; `thumburl` (`960px-`) is the
    file to load. `responsiveUrls['2']` is the 1920 px variant.
  - The three fixture files were chosen by a filter over `prop=images` (jpg/png, no logos/icons): first
    three in alphabetical order, not the lead image.
- **Thumbnail download** `commons/thumb_A_view_of_the_jet_and_shadow_of_M87_s_black_hole_eso2305a_.jpg`:
  `thumb.wikimedia.org/.../960px-....jpg`, 28,318 B, 960x742 RGB (the script falls back to the 500 px step
  when the 960 exceeds 200 KB). Non-standard thumb widths are not tested. The `?utm_source=...` query is
  part of the URL the API returns; the script kept it verbatim.

## 4. Pageviews

- REST, one article, 60 days (`pageviews/rest_per_article_Black_hole_daily.json`):
  `https://wikimedia.org/api/rest_v1/metrics/pageviews/per-article/en.wikipedia.org/all-access/user/Black_hole/daily/YYYYMMDD/YYYYMMDD`
  (start = today-60, end = yesterday, UTC). `items[].{article,timestamp "YYYYMMDD00",views}`; 60 items; the
  end day (yesterday) was present. `cache-control: s-maxage=14400`. The article is underscore-form.
- **`prop=pageviews` (PageViewInfo) exists on enwiki** (`pageviews/pageviewinfo_batch.json`):

      action=query&titles=A|B|C|D&prop=pageviews&pvipdays=60&format=json&formatversion=2

  `query.pages[].pageviews` is an object `{ "YYYY-MM-DD": views|null }` with 60 keys ending yesterday; the
  **last key is always `null`** (not yet published). Sum with `v or 0`. Black hole: 362,529 over the 59
  days vs REST 370,927 over 60 (REST adds yesterday: 8,398); all 59 shared days are equal.
  One request covers a batch of titles; no `continue` for 4 titles.

## 5. Featured feed, on this day

- `https://api.wikimedia.org/feed/v1/wikipedia/en/featured/2026/09/30` (`feed/featured_2026-09-30.json`,
  380,231 B). The identical path on `https://en.wikipedia.org/api/rest_v1/feed/featured/2026/09/30` is the
  same service (`content-type` profile `aggregated-feed/0.5.0`, `s-maxage=300`); the script records it as a
  second row on the same file. Date is UTC year/month/day.
- Top-level keys: `tfa, mostread, image, news, onthisday, dyk`.
  - `tfa`: page summary of today's featured article (Dam): `title, displaytitle, wikibase_item, pageid,
    thumbnail, originalimage, extract, extract_html, description, content_urls.desktop.page, revision, timestamp`.
  - `image` (**Picture of the day**): `title` ("File:..."), `thumbnail.{source,width,height}`,
    `image.{source,width,height}` (original, 6000x4000 here), `file_page`, `artist.{text,html,name}`,
    `credit.text`, `license.{type,code,url}`, `description.{text,html}`, `wb_entity_id`. Note
    `thumbnail.source` names a `960px-` file but `thumbnail.width` says 640.
  - `onthisday`: **20 entries** `{year, text, pages[]}`, each page a summary (`title, extract, thumbnail,
    content_urls`) with underscored `title` ("Martín_Vizcarra"). It equals `onthisday/selected/MM/DD` in
    content [explored].
  - `mostread`: `{date: "2026-09-29Z", articles[44]}` with `views, rank, view_history`.
  - `news` (4) and `dyk` (9) exist; unused.
- `onthisday/events/09/30` (`feed/onthisday_events_09-30.json`, 271 KB, `{events:[52]}`), `onthisday/all/09/30`
  is 1.4 MB [explored]; the featured feed's 20 entries are enough.

## 6. Arch wiki (`https://wiki.archlinux.org/api.php`, MediaWiki, Vector-less HTML)

- English-title index (`arch/allpages_p01.json`, raw page 1 of 9):

      action=query&list=allpages&apnamespace=0&apfilterredir=nonredirects&aplimit=max&format=json&formatversion=2
      &apcontinue=<continue.apcontinue>          (page 2 onwards)

  - `aplimit=max` = 500 (`limits.allpages: 500`). `continue: {apcontinue: "Bottles_(Русский)", continue:
    "-||"}`; the token has underscores and raw Unicode, percent-encode it. Continue tokens of the 9 pages:
    `arch/index_summary.json.lastContinue`. Pages: 8 x 500, then 363.
  - **Total 4363 titles, 2161 English, 2202 translations** (`arch/titles_en.json`: `{v,source,total,english,
    translations,duplicates,titles[sorted 2161]}`; 36.8 KB).
  - A translation is a title ending ` (<Language>)`. 40 suffixes are languages (`arch/title_suffix_counts.json`):
    Русский 478, Español 450, Português 348, Magyar 289, Français 166, Polski 90, Italiano 64, Türkçe 52,
    Українська 41, Čeština 23, Suomi 20, العربية 20, ... down to Qhichwa 2. No ` (Deutsch)`, ` (日本語)` or
    ` (简体中文)` title exists in this namespace although the wikitext has `[[de:..]]`, `[[ja:..]]`,
    `[[zh-hans:..]]` links.
  - **127 English titles also contain a parenthesis and are not translations**: laptop models ` (AMD)`,
    ` (Intel)`, ` (Gen 3)`, ` (2020)`, ` (16IRU9)`, `Afatech AF9035`, `Edgar`. Use the language set, not "ends
    in a parenthesis". `NaïveProxy` is the one non-ASCII English title.
  - `prop=info` carries `pagelanguage` (`arch/info_pagelanguage.json`: Systemd `en`, Systemd (Español)
    `es`, Bottles (Русский) `ru`, Laptop `en`), an independent check per title.
  - Subpages are ordinary English titles: `Pacman/Tips and tricks`, `Pacman/Package signing`, `Systemd/Timers`.
- Random (`arch/random_10.json`, `list=random&rnnamespace=0&rnlimit=10`): 7 of the 10 titles in the sample
  are translations (Polkit (Русский), Install Arch Linux on a removable medium (Español), GnuPG (Русский),
  DNSSEC (Magyar), LLVM (Русский), ...); the index says 50.5 % overall, so a batch of picks from `list=random`
  needs a retry per translation. The response carries a `continue.rncontinue` token.
- Lead parse (same template as Wikipedia's, `arch/lead_<Title>.json`): Systemd, Nginx, Uncomplicated Firewall,
  `Lenovo ThinkPad T14 (AMD) Gen 3`. The hardware title is picked from the index at run time.
  - Systemd: `<p><span> </span> </p>` (empty), the **Related articles box**
    (`div.archwiki-template-meta-related-articles > p "Related articles" + ul`), `<p>From the <a>project web
    page</a>: </p>`, then **`<dl><dd>` with the actual intro**, then `<p>Historically, ...`.
  - Uncomplicated Firewall: the same shape (box, "From the project home page:" lead-in, `<dl><dd>` intro), then
    a `div.archwiki-template-box-note` with `span.archwiki-template-pkg` links to
    `https://archlinux.org/packages/?name=<pkg>`.
  - Nginx: two clean `<p>` (one has "(pronounced "engine X")"), no box. Best case.
  - Hardware page: a `noprint archwiki-template-message` "does not follow the Laptop page guidelines"
    (`<p>` with an image), then a two-sentence description with a model number, then a "see Laptop" line, then a
    `table.archwiki-table-laptop`. The message paragraph is the first `<p>`.
  - Links: internal `href="/title/Web_server"` (path prefix **`/title/`**), `href="#FastCGI"` in-page,
    Wikipedia `href="https://en.wikipedia.org/wiki/nginx" class="extiw"`, `class="mw-redirect"`.
    Hence the entry URL is `https://wiki.archlinux.org/title/<Title>`.
- Sections (`arch/sections_Zsh.json`): `action=parse&page=Zsh&prop=sections` gives `parse.sections[]` with
  `{toclevel,level,line,number,index,byteoffset,anchor}` (51 sections). "Tips and tricks" is `index "22"`,
  `level "2"`, `anchor Tips_and_tricks`. Sudo and Sway also have a level-2 "Tips and tricks" [explored].
- Tips section (`arch/section_Zsh_22_tips_and_tricks.json`): `action=parse&page=Zsh&section=22&prop=text|revid|
  displaytitle&...`: the HTML starts `<div class="mw-heading mw-heading2"><h2 id="Tips_and_tricks">`; the
  section **includes all of its subsections** (24.7 KB: `h3`/`h4` blocks, `<pre>` code). Cut it at the
  first `h3` or the first paragraph after it for an entry.
- Wikitext (`arch/wikitext_Systemd_section0.json`, `.../wikitext_Zsh_section1_installation.json`):
  `action=parse&page=X&section=N&prop=wikitext` gives `parse.wikitext`.
  - Systemd section 0: `{{Lowercase title}}`, `[[Category:Init]]`, 11 `[[de:Systemd]]`-style interlanguage
    lines, then `{{Related articles start}}`, `{{Related|systemd/User}} ...` (9 entries), `{{Related articles
    end}}`, prose with `[[D-Bus]]` and `[[Wikipedia:Daemon (computing)|daemon]]`.
  - Zsh section 1: `[[Install]] the {{Pkg|zsh}} package. For additional completion definitions, install the
    {{pkg|zsh-completions}} package` — **the template name is case-insensitive at the first letter (`Pkg`,
    `pkg`)**, and `{{ic|...}}`, `{{Note|..}}`, `{{Tip|..}}` are inline. `{{AUR|name}}` is the AUR form (not
    in these two fixtures). `{{Pkg}}` sits in Installation, not in section 0.

## 7. Gentoo wiki (`https://wiki.gentoo.org/api.php`)

- Reachable, JSON, no anti-bot page, 200 (`gentoo/lead_Portage.json`, `gentoo/lead_Zsh.json`, same parse
  template as above; 0.8 s per lead).
- **Translate extension noise:** Portage's lead begins with `div.mw-pt-languages` (a language bar) and a literal
  `<p>&lt;translate&gt; </p>` (the raw tag shows up as text), then a `div.alert.gw-box` navigation box and an
  `#infobox-stack` list (Font Awesome `span.fa`) before `<p><b>Portage</b> is the official package manager ...`.
  Zsh has no language bar; its first `<p>` is the intro (`<span class="tripleclick-separator">zsh</span> (<b>Z sh</b>ell) is
  an interactive login shell ...`), a `list-group` infobox precedes it.
- Translations are `/xx` subpages (`gentoo/random_10.json`: Monit/ru, Bugzilla/Bug report guide/zh-cn,
  Xfce/Guide/ja, `/srv`); `list=random` has the same language problem as Arch, with a different suffix.

## 8. docs.kernel.org (Sphinx)

- `kernel/admin-guide_cgroup-v2.html` (173 KB), `kernel/admin-guide_sysrq.html` (35 KB), `kernel/index.html`,
  `kernel/admin-guide_index.html`. `text/html`, no cache headers.
- Structure: `div.document > div.body[role=main] > section#<slug> > h1 + ...`. Nested `section` per heading
  (`h2`, `h3`). **What precedes the first paragraph varies:** cgroup-v2 has a `dl.field-list` (Date, Author) then
  the `<p>` intro; sysrq has a `div.language-selection` (English / Chinese links), then `<p>Documentation for
  sysrq.c</p>` (a subtitle), and the first real text is the next section's `<p>`. So "first `<p>` of the first
  `<section>`" is not always an intro.
- Enumeration: `https://docs.kernel.org/searchindex.js` (19,867,969 B; `Search.setIndex({...})` JSON) has
  `docnames` (4074, 3504 without `translations/`) and `titles` (HTML `<span class="section-number">..` prefix),
  plus `terms, objects, alltitles, indexentries`. It is fetched and reduced to `kernel/docnames.json`
  (`docnames[]`, `titles[]` cleaned), 207 KB; the 20 MB file is not stored (`kernel/searchindex.meta.json`).
  Top folders: userspace-api 459, admin-guide 399, driver-api 360, hwmon 291, networking 263, arch 240,
  filesystems 148, gpu 128 (counts from `docnames.json`, translations excluded).
  - A doc's URL is `https://docs.kernel.org/<docname>.html`.
  - The root index `kernel/index.html` has a `toctree-l1` list (`process/`, `core-api/`, `driver-api/`, ...);
    `admin-guide/index.html` lists its children. `genindex.html` exists (1.87 MB) [explored], not needed.

## 9. freedesktop specifications

- `freedesktop/index.html` (27 KB): `<h4>` per spec (33: appstream, autostart, basedir, clipboard, dbus,
  desktop-entry, icon-naming, idle-inhibit, mime-apps, notification, polkit, secret-service,
  status-notifier-item, systemtray, thumbnail, trash, xsettings, ...), each with `href="<name>/latest"` (or
  `latest-single`, or an external link for appstream/dbus/polkit) and dated versions.
- `freedesktop/basedir_latest.html` (`/basedir/latest/`; `/basedir/latest` redirects to it [explored]): a
  DAPS/DocBook page. Structure: `div.article#index > div.titlepage` (title, authors) >
  `div.toc` > `div.sect1#introduction` with `<h2 class="title"><span class="number">1</span><span
  class="name">Introduction</span>` then `<p>`. The `<meta name="description">` holds the first ~300 characters of
  text. The page is short (one screen).
- Multi-page specs: `desktop-entry/latest/` is a TOC page (`class="toc"`, links to `index.html`,
  `file-naming.html`, ...); `idle-inhibit/latest/` is `class="chapter"` on one page. The index also links `latest-single`
  for desktop-entry, fhs, menu, mime-apps, notification and secret-service (not fetched).

## 10. Wikidata logo (P154) and Commons

Chain, all captured:

1. `wikidata/enwiki_pageprops_wikibase_item.json`: `action=query&titles=Systemd|Z shell|Arch Linux|Pacman
   (package manager)&prop=pageprops&ppprop=wikibase_item&redirects=1`. `query.pages[].pageprops.wikibase_item`
   (Systemd Q286124, Z shell Q227308, Arch Linux Q185576). `query.redirects[]` shows `Pacman (package manager)
   -> Arch Linux` with `tofragment: "Pacman"`: with `redirects=1` the item is the target page's, never the
   section's, and the requested title is not among `pages[].title`.
2. `wikidata/wbgetclaims_Q286124_P154.json`: `https://www.wikidata.org/w/api.php?action=wbgetclaims&entity=Q286124
   &property=P154&format=json` (no formatversion; `claims.P154[].mainsnak.datavalue.value` is the file name
   `Systemd-logo.svg`; `rank` normal). One claim here; a page with several should take the `preferred` rank.
3. `commons/imageinfo_logo.json`: `commons.wikimedia.org/w/api.php?action=query&titles=File:Systemd-logo.svg&prop=imageinfo
   &iiprop=url|size|mime|extmetadata...`: `url` `https://upload.wikimedia.org/wikipedia/commons/3/33/Systemd-logo.svg?utm_...`,
   `mime image/svg+xml`, 220x49, 5,985 B, `LicenseShortName` "Public domain", `Artist` "Tobias Bernard".
4. `wikidata/Systemd-logo.svg` is that URL's bytes (5,985 B). **`https://commons.wikimedia.org/wiki/Special:FilePath/Systemd-logo.svg`
   answers with the same bytes**, so the file name alone is enough: no imageinfo call needed when the
   license is not shown.

## Not covered (stated so nobody assumes it)

- Paging of `srsort=random` by `sroffset`, `articletopic:x^2.0` boosts (MW 1.45+), `exlimit` above 20.
- REST `page/summary`, `prop=revisions`, a POST request, `maxlag` under load, a 503.
- A non-standard `pithumbsize` or thumb width; SVG rasterisation.
- Gentoo `list=allpages` (only `list=random` was looked at), Arch pages in other namespaces (Help:, Category:).
- Wikidata rank handling with several claims.
- Rate limits of the Arch, Gentoo, kernel and freedesktop hosts: none met at 0.7 s spacing.
