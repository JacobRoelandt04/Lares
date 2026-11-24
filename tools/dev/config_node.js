// config_node.js -- the config specs and their checker under node: { Check, specs: { <name>: SPEC }, ROOT, exampleText(name), locate }.
// (modules/common/config/ConfigCheck.js and specs/*.js are `.pragma library` files of plain JS.)
var fs = require("fs"), path = require("path");
var ROOT = process.env.CONFIG_ROOT || path.join(__dirname, "../..");
function lib(rel, names) {
    var src = fs.readFileSync(path.join(ROOT, rel), "utf8").replace(/^\.pragma library/m, "");
    return new Function(src + "\nreturn {" + names.map(function (n) { return n + ": " + n; }).join(", ") + "};")();
}
var Check = lib("modules/common/config/ConfigCheck.js",
    ["defaults", "defaultOf", "read", "check", "parse", "mistakes", "schema", "wants", "maybe", "strip", "places", "pathWords", "isGroup", "isNode", "opts"]);
var locate = lib("modules/common/components/JsonComments.js", ["locate"]).locate;
var dir = path.join(ROOT, "modules/common/config/specs");
var specs = {};
fs.readdirSync(dir).filter(function (f) { return /\.js$/.test(f); }).sort().forEach(function (f) {
    specs[f.replace(/\.js$/, "")] = lib("modules/common/config/specs/" + f, ["SPEC"]).SPEC;
});
module.exports = {
    ROOT: ROOT, Check: Check, specs: specs, locate: locate,
    exampleText: function (name) { return fs.readFileSync(path.join(ROOT, ".examples", name + ".jsonc"), "utf8"); }
};
