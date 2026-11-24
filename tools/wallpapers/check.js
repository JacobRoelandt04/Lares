#!/usr/bin/env node
// check.js -- the page's engine, lifted out of bauhaus_wallpapers.html and judged in node. No browser, no window.
//   nice -n 19 node tools/wallpapers/check.js            all checks; exit status 1 on any FAIL
// ARM=shift  moves the dark picture one pixel, so the light/dark check must fail: a check that cannot fail proves nothing.
const fs = require("fs"), path = require("path");
const here = __dirname, html = fs.readFileSync(path.join(here, "bauhaus_wallpapers.html"), "utf8");
const m = html.match(/<script id="wp-core">([\s\S]*?)<\/script>/);
const WP = new Function(m[1] + "\nreturn WP;")();
const eva = JSON.parse(fs.readFileSync(path.join(here, "../../themes/eva.json"), "utf8"));
let fails = 0;
const say = (ok, name, detail) => { if (!ok) fails++; console.log((ok ? "ok   " : "FAIL ") + name + (detail ? "  " + detail : "")); };
const SEEDS = Array.from({ length: 20 }, (_, i) => 1 + i * 137);
const gens = WP.GEN.map(g => g.id);
const hex = (c) => "#" + c.map(v => v.toString(16).padStart(2, "0")).join("").toUpperCase();
const noDim = { night: 0 };

// 1. every token is the file's
{
    const bad = [];
    for (const mode of ["light", "dark"]) for (const k in WP.EVA[mode]) if ((eva[mode][k] || "").toUpperCase() !== WP.EVA[mode][k].toUpperCase()) bad.push(mode + "." + k);
    say(!bad.length, "eva tokens equal themes/eva.json", bad.join(" "));
    const missing = WP.ROLES.filter(r => !WP.EVA.light[r.light] || !WP.EVA.dark[r.dark]).map(r => r.id);
    say(!missing.length, "every role names a token", missing.join(" "));
}
// 2. the file stands alone
{
    const body = html.replace(/https?:\/\/[^\s"']*w3\.org[^\s"']*/g, "");
    say(!/Math\.random/.test(html), "no Math.random in the file");
    say(!/(src|href)\s*=\s*["']?https?:|@import|url\(\s*["']?http|fetch\(|XMLHttpRequest|https?:\/\//.test(body), "no network reference in the file");
    say(!/\bdataset\.tip\b\s*=\s*undefined/.test(html) && WP.COMMON.concat(...WP.GEN.map(g => g.params)).every(p => p.tip && p.group), "every parameter has a tip and a group");
}
(async () => {
    // 3. same seed, same bytes
    {
        const bad = [];
        for (const g of gens) {
            const a = WP.renderBytes(WP.build(g, 4242, {}, 960, 540), WP.palette("light"), 960, 540);
            const b = WP.renderBytes(WP.build(g, 4242, {}, 960, 540), WP.palette("light"), 960, 540);
            if (Buffer.compare(Buffer.from(a), Buffer.from(b))) bad.push(g);
        }
        say(!bad.length, "same seed gives identical bytes", bad.join(" "));
    }
    // 4. light and dark share every edge. Pixels flat in a 3 x 3 are flat in both, and light colour -> dark colour is a function on them.
    {
        const W = 960, H = 540, arm = process.env.ARM === "shift", bad = [];
        for (const g of gens) for (const seed of SEEDS.slice(0, 6)) {
            const scene = WP.build(g, seed, { material: "flat" }, W, H), L = WP.renderBytes(scene, WP.palette("light"), W, H), D0 = WP.renderBytes(scene, WP.palette("dark"), W, H);
            let D = D0;
            if (arm) { D = new Uint8ClampedArray(D0.length); for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) for (let c = 0; c < 3; c++) D[(y * W + x) * 3 + c] = D0[(y * W + Math.min(W - 1, x + 1)) * 3 + c]; }
            // Range of the 3 x 3 round a pixel. Two inks can sit a few levels apart in one mode and far apart in the other, so an edge is judged where it can be seen.
            const span = (B, i) => { let s = 0; for (const o of [1, W, W + 1, -1, -W, -W - 1, W - 1, -W + 1]) for (let c = 0; c < 3; c++) { const d = Math.abs(B[(i + o) * 3 + c] - B[i * 3 + c]); if (d > s) s = d; } return s; };
            let diff = 0; const map = new Map();
            for (let y = 1; y < H - 1; y++) for (let x = 1; x < W - 1; x++) {
                const i = y * W + x, sl = span(L, i), sd = span(D, i);
                if ((sl === 0 && sd > 16) || (sd === 0 && sl > 16)) { diff++; continue; }
                if (sl === 0 && sd === 0) {
                    const kl = L[i * 3] << 16 | L[i * 3 + 1] << 8 | L[i * 3 + 2], kd = D[i * 3] << 16 | D[i * 3 + 1] << 8 | D[i * 3 + 2];
                    if (!map.has(kl)) map.set(kl, kd); else if (map.get(kl) !== kd) diff++;
                }
            }
            if (diff) bad.push(g + ":" + seed + "=" + diff);
        }
        say(!bad.length, "light and dark share every edge", bad.slice(0, 6).join(" "));
    }
    // 5. twenty seeds: nothing blank, nothing broken, the band under the top edge empty, a ground that is the exact token
    {
        const W = 640, H = 360;
        for (const g of gens) {
            const shares = [], bad = [];
            for (const seed of SEEDS) for (const mode of ["light", "dark"]) {
                const scene = WP.build(g, seed, {}, W, H), pal = WP.palette(mode), ra = new WP.Raster(W, H), rgb = WP.renderBytes(scene, pal, W, H, ra), gr = pal.ground, clear = WP.defaults(WP.GEN.find(x => x.id === g)).clear;
                let nan = 0; for (let i = 0; i < ra.F.length; i++) if (!(ra.F[i] >= 0 && ra.F[i] <= 255.001)) nan++;
                if (nan) bad.push(seed + " nan " + nan);
                let ground = 0, top = 0;
                const rows = Math.floor(clear * H);
                for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
                    const i = (y * W + x) * 3, same = rgb[i] === gr[0] && rgb[i + 1] === gr[1] && rgb[i + 2] === gr[2];
                    if (same) ground++; else if (y < rows) top++;
                }
                const share = ground / (W * H);
                if (mode === "light") shares.push(share);
                if (share < 0.2 || share > 0.97) bad.push(seed + " " + mode + " ground " + share.toFixed(2));
                if (top) bad.push(seed + " " + mode + " ink in the clear band: " + top);
            }
            shares.sort((a, b) => a - b);
            say(!bad.length, g + ": 20 seeds, both modes", "ground share median " + shares[10].toFixed(2) + " (" + shares[0].toFixed(2) + " .. " + shares[19].toFixed(2) + ")  " + bad.slice(0, 4).join("; "));
        }
    }
    // 5b. any slider, any end of its range: nothing throws, nothing is NaN, the clear band stays clear
    {
        const W = 320, H = 180, r = WP.rngFor(99, "fuzz"), bad = [];
        for (const g of WP.GEN) for (let n = 0; n < 40; n++) {
            const p = {};
            for (const d of WP.COMMON.concat(g.params)) {
                if (d.type === "range") { const e = r.pick(["lo", "hi", "mid"]), v = e === "lo" ? d.min : e === "hi" ? d.max : d.min + (d.max - d.min) * r.f(); p[d.key] = v; }
                else p[d.key] = String(r.pick(d.options)[0]);
            }
            const seed = r.int(1, 99999);
            try {
                const ra = new WP.Raster(W, H), pal = WP.palette("light", null, p.night), rgb = WP.renderBytes(WP.build(g.id, seed, p, W, H), pal, W, H, ra);
                let nan = 0, top = 0;
                for (let i = 0; i < ra.F.length; i++) if (!(ra.F[i] >= 0 && ra.F[i] <= 255.001)) nan++;
                const rows = Math.floor(p.clear * H);
                for (let y = 0; y < rows; y++) for (let x = 0; x < W; x++) { const i = (y * W + x) * 3; if (Math.abs(rgb[i] - pal.ground[0]) > 2) top++; }
                if (nan) bad.push(g.id + " nan");
                if (top) bad.push(g.id + " seed " + seed + " clear " + p.clear.toFixed(2) + " top " + top + " " + JSON.stringify(p));
            } catch (e) { bad.push(g.id + " threw " + e.message); }
        }
        say(!bad.length, "40 random settings per generator", bad.length + " bad: " + bad.slice(0, 8).map(b => b.slice(0, 60)).join(" | "));
    }
    // 6. a resolution changes the pixels, not the picture: 4K halved against 1080p
    {
        const bad = [];
        const res = [];
        for (const g of gens) {
            const s = 1 + 137 * 3;
            const a = WP.renderBytes(WP.build(g, s, {}, 3840, 2160), WP.palette("light"), 3840, 2160), b = WP.renderBytes(WP.build(g, s, {}, 1920, 1080), WP.palette("light"), 1920, 1080);
            let sum = 0, big = 0;
            for (let y = 0; y < 1080; y++) for (let x = 0; x < 1920; x++) for (let c = 0; c < 3; c++) {
                const q = (a[((y * 2) * 3840 + x * 2) * 3 + c] + a[((y * 2) * 3840 + x * 2 + 1) * 3 + c] + a[((y * 2 + 1) * 3840 + x * 2) * 3 + c] + a[((y * 2 + 1) * 3840 + x * 2 + 1) * 3 + c]) / 4;
                const d = Math.abs(q - b[(y * 1920 + x) * 3 + c]);
                sum += d; if (d > 64) big++;
            }
            const mean = sum / (1920 * 1080 * 3), bigShare = big / (1920 * 1080 * 3);
            res.push(g + " " + mean.toFixed(2));
            if (mean > 1.5 || bigShare > 0.004) bad.push(g + " mean " + mean.toFixed(2) + " big " + (bigShare * 100).toFixed(2) + "%");
        }
        say(!bad.length, "4K and 1080p are one picture", res.join(", ") + "  " + bad.join("; "));
    }
    // 7. a 4K export, render and PNG, per generator
    {
        const ra = new WP.Raster(3840, 2160), out = [];
        let worst = 0;
        for (const g of gens) {
            const t = Date.now(), rgb = WP.renderBytes(WP.build(g, 7, {}, 3840, 2160), WP.palette("dark"), 3840, 2160, ra);
            const blob = await WP.encodePng(rgb, 3840, 2160, "check");
            const ms = Date.now() - t; worst = Math.max(worst, ms);
            out.push(g + " " + ms + " ms " + (blob.size >> 10) + " KiB");
        }
        say(worst < 5000, "4K export under 5 s", out.join(", "));
    }
    console.log(fails ? "CHECK RESULT FAIL (" + fails + ")" : "CHECK RESULT PASS");
    process.exit(fails ? 1 : 0);
})();
