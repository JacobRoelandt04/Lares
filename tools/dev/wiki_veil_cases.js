// wiki_veil_cases.js -- modules/wiki/WikiVeilPick.js in node: the same keys the probe's QML prints as `WVP PICK`,
// as the same JSON, so tools/dev/wiki_veil_probe.sh can hold QV4 and node to one answer.
//   node tools/dev/wiki_veil_cases.js            prints one PICK line per key
const fs = require("fs");
const path = require("path");
const src = fs.readFileSync(path.join(__dirname, "../../modules/wiki/WikiVeilPick.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const Pick = new Function(src + "\nreturn { of: of, NAMES: NAMES };")();
const keys = ["", "a", "wiki.archlinux.org/Systemd", "en.wikipedia.org/Messier_87", "wiki.gentoo.org/Portage", "docs.kernel.org/scheduler",
              "en.wikipedia.org/Zürich", "x".repeat(300)];
for (const k of keys) {
    const p = Pick.of(k);
    console.log("PICK " + JSON.stringify([k, p.pattern, p.seed, p.t0]));
}
