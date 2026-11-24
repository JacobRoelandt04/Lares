#!/usr/bin/env bash
# bar_hues_table.sh -- the bar's hue table (modules/common/glyphs/BarHues.js) resolved on EVERY theme on disk, light and dark:
# per role the token it lands on, the colour, its contrast on the surface and its margin from what it must be told from.
#
#   tools/dev/bar_hues_table.sh            BAR_HUES RESULT PASS | FAIL
#   THEMES="eva" tools/dev/bar_hues_table.sh
#   ARM=flat tools/dev/bar_hues_table.sh   a theme whose twelve hue slots are one colour joins the list: it must FAIL
#
# PASS: in every theme and mode every role found a slot that qualifies (far enough from its own state colours, warn, error and
# its pair partner; enough contrast) and every reel's options are distinct. A theme added later is held to the same rule: a FAIL
# names the theme, the role and how close it came. The resolver is the one the shell runs (node evaluates the same file); the
# palettes are themectl's resolver's (tools/theme/themectl resolve, read only, in a private HOME).
set -u
cd "$(dirname "$0")/../.." || exit 1
THEMES="${THEMES:-$(for f in themes/*.json; do basename "$f" .json; done)}"
D="$(mktemp -d "${SCRATCH:-/tmp}/barhues.XXXXXX")"
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/home"
case "${ARM:-}" in
    "") ;;
    flat)
        # eva with every ansi hue slot the accent's blue: no role can be told from anything, no reel option from another
        python3 - "$D/flat.json" <<'PY'
import json, re, sys
d = json.loads(re.sub(r"(?m)^\s*//.*$", "", open("themes/eva.json").read()))
for m in ("light", "dark"):
    for k in list(d[m]):
        if k.startswith("ansi") and k not in ("ansiBlack", "ansiWhite", "ansiBrightBlack", "ansiBrightWhite"):
            d[m][k] = "#4480F4"
json.dump(d, open(sys.argv[1], "w"))
PY
        THEMES="$THEMES flat" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
for t in $THEMES; do
    f="themes/$t.json"; [ "$t" = flat ] && f="$D/flat.json"
    for m in light dark; do
        if ! HOME="$D/home" XDG_CONFIG_HOME="$D/home/.config" python3 tools/theme/themectl resolve --file "$f" --mode "$m" \
            --l0 modules/common/theme/Theme.qml > "$D/pal_${t}_${m}.json" 2> "$D/err"; then
            echo "BAR_HUES RESULT FAIL (themectl could not resolve $t $m: $(head -c 200 "$D/err"))"
            exit 1
        fi
    done
done
node - "$D" "$THEMES" <<'JS'
const fs = require("fs");
const [dir, themes] = [process.argv[2], process.argv[3].split(/\s+/).filter(Boolean)];
const src = fs.readFileSync("modules/common/glyphs/BarHues.js", "utf8").replace(/^\.pragma library/m, "");
const H = new Function(src + "; return { resolveVerbose, tokens, contrast, lab, de2000, TABLE, T_GROUP };")();
const hx = c => "#" + c.map(v => Math.round(v * 255).toString(16).padStart(2, "0")).join("").toUpperCase();
let bad = 0;
for (const t of themes) for (const m of ["light", "dark"]) {
    const v = JSON.parse(fs.readFileSync(`${dir}/pal_${t}_${m}.json`)).values;
    const pal = {};
    for (const n of H.tokens())
        if (v[n]) pal[n] = v[n].slice(0, 3).map(x => x / 255);
    const r = H.resolveVerbose(pal);
    console.log(`== ${t} ${m}  (surface ${hx(pal.surface)})`);
    for (const e of H.TABLE) {
        const n = r.choice[e.role];
        const fb = r.fallback.indexOf(e.role) >= 0;
        const mg = r.margin[e.role] >= 1e8 ? "free" : r.margin[e.role].toFixed(2);
        console.log(`  ${e.role.padEnd(16)} ${n.padEnd(18)} ${hx(pal[n])}  contrast ${H.contrast(pal[n], pal.surface).toFixed(2)}  margin ${mg}${fb ? "   NO QUALIFYING SLOT" : ""}`);
    }
    for (const g of ["power", "idle"]) {
        const roles = H.TABLE.filter(e => e.group === g).map(e => e.role);
        let min = 1e9, pair = "";
        for (let i = 0; i < roles.length; i++)
            for (let j = i + 1; j < roles.length; j++) {
                const d = H.de2000(H.lab(pal[r.choice[roles[i]]]), H.lab(pal[r.choice[roles[j]]]));
                if (d < min) { min = d; pair = roles[i] + " / " + roles[j]; }
            }
        console.log(`  reel ${g}: nearest two ${pair} ${min.toFixed(1)} CIEDE2000${min < H.T_GROUP ? "   TOO CLOSE" : ""}`);
        if (min < H.T_GROUP) bad++;
    }
    bad += r.fallback.length;
}
console.log(`BAR_HUES RESULT ${bad === 0 ? "PASS" : "FAIL"} (${themes.length} themes x 2 modes${bad ? ", " + bad + " roles without a qualifying slot or reels too close" : ""})`);
process.exit(bad === 0 ? 0 : 1);
JS
