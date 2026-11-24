// node tools/dev/shell_remap_cases.js -- RemapRule.js (ShellScreen's rise watch) as a model of the watch: rises, frames, expiries.
// ARM=alwaysremap: the old behaviour (an expiry remaps) -> must FAIL "a quiet rise".
const fs = require("fs");
const vm = require("vm");
const src = fs.readFileSync(__dirname + "/../../modules/shell/RemapRule.js", "utf8").replace(".pragma library", "");
const ctx = {};
vm.runInNewContext(src + "\nthis.decide = decide;", ctx);
let decide = ctx.decide;
if (process.env.ARM === "alwaysremap") decide = () => "remap";
const COOL = 10000;
// One window's watch. rise(t, framesAfterAskMs): the rise at t; `frame` says whether a frame comes after the ask (a quiet rise) or not.
function run(rises) {
    let asked = false, last = -1e12, remaps = 0, skips = 0, asks = 0;
    for (const r of rises) {
        asked = false;
        if (r.frame === "at-once") continue;          // afterAnimating stops the watch
        let d = decide(asked, r.t - last, COOL);      // 64 ms: no frame
        if (d === "ask") { asks++; asked = true; if (r.frame === "after-ask") continue; d = decide(asked, r.t - last, COOL); }
        if (d === "remap") { remaps++; last = r.t; } else if (d === "skip") skips++;
    }
    return { remaps, skips, asks };
}
let fails = 0;
const check = (d, ok) => { console.log((ok ? "ok   " : "FAIL ") + d); if (!ok) fails++; };
let r = run([{ t: 0, frame: "at-once" }]);
check("a rise with its frame asks and remaps nothing", r.remaps === 0 && r.asks === 0);
r = run([{ t: 0, frame: "after-ask" }]);
check("a quiet rise (the frame comes when asked) does not remap", r.remaps === 0 && r.asks === 1);
r = run([{ t: 0, frame: "never" }]);
check("a window that never draws is remapped once", r.remaps === 1);
r = run([0, 1, 2, 3, 4, 5].map(i => ({ t: 1000 * i, frame: "never" })));
check("six rises in six seconds: one remap, five skipped", r.remaps === 1 && r.skips === 5);
r = run([{ t: 0, frame: "never" }, { t: 11000, frame: "never" }]);
check("after the cool-down it remaps again", r.remaps === 2);
console.log(fails ? "SHELL_REMAP RESULT FAIL" : "SHELL_REMAP RESULT PASS");
process.exit(fails ? 1 : 0);
