// aerial_node_load.js -- loads aerial's pragma-library JS files under node with their `.import`s resolved (IsoCore, AerialCamera, AerialGeometry, GlobeMath, CloudPlace), for the pure cases
// (tools/dev/aerial_holo_cases.js). The camera is the popup's: fitNatural at the design width (760).
var fs = require("fs"), path = require("path");
var ROOT = path.join(__dirname, "../..");
function load(rel, imports) {
    var src = fs.readFileSync(path.join(ROOT, rel), "utf8").replace(/^\.pragma library/m, "").replace(/^\.import .*$/mg, "");
    var names = Object.keys(imports || {});
    return new Function(...names, src + "\nreturn this_exports();function this_exports(){var o={};" + exportsOf(src) + "return o;}").apply(null, names.map(function (n) { return imports[n]; }));
}
// every top-level function and every name a top-level `var` declares, the later names of `var a = 1, b = 2;` too (a name read as undefined is a NaN that passes
// every comparison: the dome check once judged no tag spot at all)
function exportsOf(src) {
    var names = [], re = /^function\s+([A-Za-z_]\w*)|^var\s+([^;]*)/mg, m;
    while ((m = re.exec(src))) {
        if (m[1]) { names.push(m[1]); continue; }
        var d = m[2], r2 = /(?:^|,\s*)([A-Za-z_]\w*)\s*=(?!=)/g, k;
        while ((k = r2.exec(d)))
            names.push(k[1]);
    }
    return names.map(function (x) { return "try{o['" + x + "']=" + x + ";}catch(e){}"; }).join("");
}
var Core = load("modules/common/board/IsoCore.js");
var Cam = load("modules/aerial/scene/AerialCamera.js", { Core: Core });
var Geo = load("modules/aerial/scene/AerialGeometry.js");
var G = JSON.parse(Geo.json());
var GM = load("modules/aerial/scene/GlobeMath.js", { Core: Core });
var CP = load("modules/aerial/scene/CloudPlace.js");
var fit = Cam.fitNatural(G, 760, { l: 14, r: 14, t: 12, b: 14 });
var cam = { s: fit.s, ox: fit.ox, oy: fit.oy };
module.exports = { Core: Core, Cam: Cam, Geo: Geo, G: G, GM: GM, CP: CP, cam: cam, height: fit.height, proj: function (p) { var q = Core.project(p, cam); return [q.x, q.y]; } };
